import Foundation
import Darwin

/// claude/summary-1003 (owner decision 2026-10-03): the private local socket that carries typed words from the DayDream
/// app (which holds the typing key) to `mac-mem mcp` (which never does), for "Let AI apps read what you typed".
///
/// - The socket lives next to the history (`<home>/ai-read.sock`), or, when that path is too long for a socket, in a
///   folder only this user can open (`/private/tmp/daydream-ai-<uid>/<hash>.sock`, mode 0700). The socket is 0600.
/// - The app answers only a peer running as the same user (`getpeereid`), one JSON request per connection, at most
///   64 KB, and only for a caller whose client, recipient and key the store authorizes (`assistantBridgeAnswer`).
/// - The app reads the setting for every request: off answers `off`, and the MCP tools behave as before.
/// - Nothing here logs or prints a request or an answer.
public enum AssistantTypedBridge {
    public static let fileName = "ai-read.sock"
    static let requestLimit = 65_536
    static let replyLimit = 1_048_576

    public static func socketPath(home: URL) -> String {
        let direct = home.appendingPathComponent(fileName).path
        if direct.utf8.count < 100 { return direct }
        return fallbackFolder() + "/" + String(fingerprint(home.standardizedFileURL.path).prefix(16)) + ".sock"
    }
    static func fallbackFolder() -> String { "/private/tmp/daydream-ai-\(getuid())" }
    /// The fallback folder exists, is a real folder (not a link), belongs to this user and only this user can open it.
    static func privateFolder(_ path: String, create: Bool) -> Bool {
        if create { _ = mkdir(path, 0o700) }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else { return false }
        return true
    }
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }
    static func timeouts(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    static func readAll(_ fd: Int32, limit: Int, line: Bool) -> Data? {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= limit {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { return n == 0 || !data.isEmpty ? data : nil }
            data.append(contentsOf: buffer[0..<n])
            if line, let nl = data.firstIndex(of: 10) { return data.prefix(upTo: nl) }
        }
        return nil
    }
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// MCP side: one request to the running app. nil when no app answers (not running, or an older version).
    public static func call(home: URL, _ request: [String: Any], timeout: Int = 4) -> [String: Any]? {
        let path = socketPath(home: home)
        if path.hasPrefix(fallbackFolder() + "/"), !privateFolder(fallbackFolder(), create: false) { return nil }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid(),
              var addr = address(path), let payload = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        timeouts(fd, seconds: timeout)
        let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0, writeAll(fd, payload + Data([10])) else { return nil }
        shutdown(fd, SHUT_WR)
        guard let reply = readAll(fd, limit: replyLimit, line: false), !reply.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
    }
}

/// App side: the listener. `answer` runs for each request on the bridge's own thread.
public final class AssistantTypedBridgeServer: @unchecked Sendable {
    public let path: String
    private let answer: ([String: Any]) -> [String: Any]
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var thread: Thread?

    public init(home: URL, answer: @escaping ([String: Any]) -> [String: Any]) {
        path = AssistantTypedBridge.socketPath(home: home)
        self.answer = answer
    }
    /// Starts listening. False when the socket can't be made (another DayDream already listens there, or the folder
    /// isn't private); the MCP tools then behave as when the setting is off.
    @discardableResult public func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard fd < 0 else { return true }
        let folder = (path as NSString).deletingLastPathComponent
        if folder == AssistantTypedBridge.fallbackFolder(), !AssistantTypedBridge.privateFolder(folder, create: true) { return false }
        // A live listener (another copy of DayDream) keeps its socket; a stale one is replaced. Never a non-socket file.
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else { return false }
            if Self.live(path) { return false }
            unlink(path)
        }
        guard var addr = AssistantTypedBridge.address(path) else { return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        let old = umask(0o177)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        umask(old)
        guard bound == 0, chmod(path, 0o600) == 0, listen(s, 8) == 0 else { close(s); return false }
        fd = s
        let t = Thread { [weak self] in self?.loop(s) }
        t.name = "DayDream AI read bridge"
        t.qualityOfService = .utility
        thread = t
        t.start()
        return true
    }
    static func live(_ path: String) -> Bool {
        guard var addr = AssistantTypedBridge.address(path) else { return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { return }
        let s = fd; fd = -1
        shutdown(s, SHUT_RDWR); close(s)
        var info = stat()
        if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK { unlink(path) }
    }
    private func loop(_ s: Int32) {
        while true {
            let c = accept(s, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                return
            }
            handle(c)
            close(c)
        }
    }
    private func handle(_ c: Int32) {
        AssistantTypedBridge.timeouts(c, seconds: 3)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { return }
        guard let line = AssistantTypedBridge.readAll(c, limit: AssistantTypedBridge.requestLimit, line: true),
              var request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if request.isEmpty { return reply(c, ["status": "ok"]) }
        // The owner-preview gate checks the process on the other end of this socket, as the kernel reports it
        // (`LOCAL_PEERPID`). A `pid` the client wrote into the request is never trusted: it is replaced, or removed when
        // the kernel can't say (the gate then fails closed).
        request["pid"] = AgentBridgePeer.peerPID(c).map { Int($0) }
        reply(c, answer(request))
    }
    private func reply(_ c: Int32, _ reply: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: reply) else { return }
        _ = AssistantTypedBridge.writeAll(c, data)
    }
}
