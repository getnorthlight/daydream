import Foundation
import CryptoKit
import Darwin
@testable import WriterBackend

// fix/model-download: the real transfer (URLSession through AssetDownload) and the real partial file (PersistentModelCache)
// against a tiny HTTP server on 127.0.0.1 that drops, stalls, answers 503/429/404, ignores Range, sends a wrong range or a
// damaged file. No outside network: the server serves a few synthetic megabytes from this process.

/// What the fake server does with one request.
enum FakeReply {
    /// The file from the asked-for offset (206) or all of it (200 when `range` is false or nothing was asked).
    /// `cut`: close the connection after that many body bytes. `stall`: then wait this long first. `damage`: flip bytes.
    case serve(range: Bool = true, cut: Int? = nil, stall: TimeInterval = 0, damage: Bool = false, wrongRange: Bool = false)
    case status(Int, retryAfter: String? = nil)
    case redirect(String)
}

final class FakeServer: @unchecked Sendable {
    let payload: Data
    private(set) var port: UInt16 = 0
    private let listener: Int32
    private let lock = NSLock()
    private var requests: [(path: String, start: Int?)] = []
    private var plan: (_ path: String, _ index: Int, _ start: Int?) -> FakeReply = { _, _, _ in .serve() }

    init(payload: Data) throws {
        self.payload = payload
        listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1; setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(listener, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        port = UInt16(bigEndian: address.sin_port)
        let thread = Thread { [unowned self] in self.acceptLoop() }; thread.start()
    }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(path)")! }
    func use(_ plan: @escaping (_ path: String, _ index: Int, _ start: Int?) -> FakeReply) { lock.lock(); self.plan = plan; requests = []; lock.unlock() }
    var log: [(path: String, start: Int?)] { lock.lock(); defer { lock.unlock() }; return requests }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            var noSigPipe: Int32 = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            Thread { [unowned self] in self.handle(client) }.start()
        }
    }
    private func handle(_ client: Int32) {
        // Closed the way a dropped server does it: no more bytes, then the socket goes away.
        defer { shutdown(client, SHUT_WR); var sink = [UInt8](repeating: 0, count: 1024); var quiet = timeval(tv_sec: 0, tv_usec: 200_000)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &quiet, socklen_t(MemoryLayout<timeval>.size)); while read(client, &sink, sink.count) > 0 {}; close(client) }
        var head = Data(); var byte = [UInt8](repeating: 0, count: 4096)
        while !head.contains(Data("\r\n\r\n".utf8)) {
            let n = read(client, &byte, byte.count); if n <= 0 { return }; head.append(contentsOf: byte[0..<n])
        }
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let path = String(lines.first?.split(separator: " ").dropFirst().first?.dropFirst() ?? "")
        var start: Int?
        for line in lines where line.lowercased().hasPrefix("range: bytes=") {
            start = Int(line.dropFirst("range: bytes=".count).split(separator: "-").first ?? "")
        }
        lock.lock(); let index = requests.filter { $0.path == path }.count; requests.append((path, start)); let reply = plan(path, index, start); lock.unlock()
        switch reply {
        case .status(let code, let retryAfter):
            send(client, "HTTP/1.1 \(code) Nope\r\nContent-Length: 0\r\n\(retryAfter.map { "Retry-After: \($0)\r\n" } ?? "")Connection: close\r\n\r\n")
        case .redirect(let target):
            send(client, "HTTP/1.1 302 Found\r\nLocation: \(target)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        case .serve(let range, let cut, let stall, let damage, let wrongRange):
            let from = range ? (start ?? 0) : 0
            var body = payload.subdata(in: from..<payload.count)
            if damage { body = Data(body.map { $0 ^ 0x5a }) }
            let total = payload.count
            if range && start != nil {
                let shown = wrongRange ? from + 1 : from
                send(client, "HTTP/1.1 206 Partial Content\r\nContent-Length: \(body.count)\r\nContent-Range: bytes \(shown)-\(total - 1)/\(total)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n")
            } else {
                send(client, "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\(range ? "Accept-Ranges: bytes\r\n" : "")Connection: close\r\n\r\n")
            }
            let first = cut.map { min($0, body.count) } ?? body.count
            write(client, body.prefix(first))
            // A cut alone closes the connection early; a cut with a stall goes quiet, then sends the rest.
            if stall > 0 { Thread.sleep(forTimeInterval: stall); write(client, body.dropFirst(first)) }
        }
    }
    private func send(_ client: Int32, _ text: String) { write(client, Data(text.utf8)) }
    private func write(_ client: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count { let n = Darwin.write(client, raw.baseAddress! + offset, raw.count - offset); if n <= 0 { return }; offset += n }
        }
    }
}

private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func require(_ ok: Bool, _ what: String) { if !ok { print("FAIL \(what)"); exit(1) }; print("PASS \(what)") }

/// Every progress report of one acquisition.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock(); private var states: [InstallState] = []
    func add(_ s: InstallState) { lock.lock(); states.append(s); lock.unlock() }
    var all: [InstallState] { lock.lock(); defer { lock.unlock() }; return states }
    var failedShown: Bool { all.contains(.failed) }
}

/// A child process that downloads into `root` until it's killed (the quit/relaunch check).
func downloadQuitProbe(root: URL, port: UInt16, bytes: Int64, hash: String) async throws {
    let asset = PinnedAsset(url: URL(string: "http://127.0.0.1:\(port)/quit")!, bytes: bytes, sha256: hash)
    _ = try await PersistentModelCache.acquire(asset: asset, root: root, priorRoots: [],
        chunks: { url, offset in try await AssetDownload.transfer(from: url, offset: offset, total: bytes, stall: 30) })
}

func downloadServerChecks() async throws {
    // The pure rules first.
    for error: Error in [URLError(.networkConnectionLost), URLError(.timedOut), URLError(.notConnectedToInternet), URLError(.cannotConnectToHost),
                         URLError(.dnsLookupFailed), URLError(.secureConnectionFailed), URLError(.dataNotAllowed), URLError(.cannotFindHost),
                         DownloadInterruption.status(503, retryAfter: nil), DownloadInterruption.status(500, retryAfter: nil),
                         DownloadInterruption.status(429, retryAfter: 5), DownloadInterruption.status(408, retryAfter: nil),
                         DownloadInterruption.shortBody, DownloadInterruption.rangeIgnored, DownloadInterruption.wrongRange,
                         NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))] {
        precondition(AssetDownload.isTransient(error), "transient: \(error)")
    }
    for error: Error in [DownloadInterruption.status(404, retryAfter: nil), DownloadInterruption.status(403, retryAfter: nil),
                         DownloadInterruption.status(302, retryAfter: nil), URLError(.badURL), URLError(.appTransportSecurityRequiresSecureConnection),
                         WriterFailure.capacity, WriterFailure.integrity, WriterFailure.denied, DownloadDamaged(), CancellationError(),
                         NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))] {
        precondition(!AssetDownload.isTransient(error), "not transient: \(error)")
    }
    print("PASS drops, timeouts, Wi-Fi/DNS/TLS hiccups, 408/429/5xx and cut bodies are retried; 4xx, refused redirects, disk, hash and cancel are not")
    let full = PersistentModelCache.writeFailure(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
    let posixFull = PersistentModelCache.writeFailure(NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))]))
    guard case WriterFailure.capacity = full, case WriterFailure.capacity = posixFull else { fatalError("disk full is the no-space problem") }
    print("PASS a full disk during the download is the no-space problem, not a stopped download")
    let source = WriterCandidates.recommended!.asset.url
    for host in ["https://us.aws.cdn.hf.co/a", "https://eu.aws.cdn.hf.co/a", "https://cas-bridge.xethub.hf.co/a", "https://cdn-lfs.huggingface.co/a", "https://cdn-lfs-us-1.hf.co/a"] {
        precondition(AssetDownload.redirectAllowed(from: source, to: URL(string: host)!), host)
    }
    for host in ["https://evilhf.co/a", "https://hf.co.evil.invalid/a", "http://eu.aws.cdn.hf.co/a", "https://x.hf.co:8443/a", "https://u:p@eu.aws.cdn.hf.co/a", "https://huggingface.com/a"] {
        precondition(!AssetDownload.redirectAllowed(from: source, to: URL(string: host)!), host)
    }
    precondition(!AssetDownload.redirectAllowed(from: WriterCandidates.llamaARM64.url, to: URL(string: "https://eu.aws.cdn.hf.co/a")!))
    print("PASS the model may be handed to any HTTPS host of Hugging Face (hf.co, huggingface.co); nothing else, and not for the runtime")

    // The fake server: 2.5 MB of synthetic bytes, so pieces, cuts and ranges fall in the middle of 1 MB chunks.
    let payload = Data((0..<2_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })
    let hash = hex(payload), bytes = Int64(payload.count)
    let server = try FakeServer(payload: payload)
    let fm = FileManager.default
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("download-server-check-" + UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: base) }
    let quick = DownloadPatience(firstWait: 0.01, maximumWait: 0.05, giveUpAfter: 5)
    func chunks(stall: TimeInterval = 5) -> ModelRangeChunks { { url, offset in try await AssetDownload.transfer(from: url, offset: offset, total: bytes, stall: stall) } }
    func root(_ name: String) throws -> URL { let u = base.appendingPathComponent(name); try fm.createDirectory(at: u, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return u }
    func run(_ name: String, patience: DownloadPatience = quick, stall: TimeInterval = 5, _ plan: @escaping (Int, Int?) -> FakeReply) async throws -> (Result<URL, Error>, [(path: String, start: Int?)], ProgressLog, URL) {
        server.use { _, index, start in plan(index, start) }
        let dir = try root(name), progress = ProgressLog()
        let asset = PinnedAsset(url: server.url(name), bytes: bytes, sha256: hash)
        let result: Result<URL, Error>
        do { result = .success(try await PersistentModelCache.acquire(asset: asset, root: dir, priorRoots: [], chunks: chunks(stall: stall), patience: patience, progress: progress.add)) }
        catch { result = .failure(error) }
        return (result, server.log, progress, dir)
    }
    func finished(_ result: Result<URL, Error>) -> Bool {
        guard case .success(let file) = result, let data = try? Data(contentsOf: file) else { return false }
        return data == payload && file.lastPathComponent == hash + ".model"
    }

    // 1. The network drops twice mid-body: resumed from the partial file each time, never shown as stopped.
    var (result, log, progress, dir) = try await run("drop") { index, _ in index < 2 ? .serve(cut: 700_000) : .serve() }
    // (A cut connection can lose bytes still in flight: each try resumes from what the partial file holds.)
    let dropStarts = log.map { $0.start ?? 0 }
    require(finished(result) && log.count == 3 && log[0].start == nil && dropStarts == dropStarts.sorted() && dropStarts[2] > 0 && !progress.failedShown,
            "two network drops: each resumed with Range where the partial file ended, finished, never shown stopped (\(dropStarts))")
    let seen = progress.all.compactMap { if case .downloading(let r, _) = $0 { return r }; return nil }
    require(seen == seen.sorted(), "progress only moves forward across drops")
    // 2. A busy server: 503 three times (one with Retry-After), then the file.
    (result, log, progress, dir) = try await run("busy") { index, _ in index < 3 ? .status(503, retryAfter: index == 1 ? "0" : nil) : .serve() }
    require(finished(result) && log.count == 4 && !progress.failedShown, "503 three times, then the file: finished by itself")
    // 3. Rate limited: 429 then the file.
    (result, log, _, _) = try await run("limited") { index, _ in index == 0 ? .status(429, retryAfter: "0") : .serve() }
    require(finished(result) && log.count == 2, "429 with Retry-After, then the file: finished by itself")
    // 4. A stall longer than the stall limit (1 s here, 60 s in the app) after 500,000 bytes: timed out, resumed there.
    (result, log, progress, _) = try await run("stall", stall: 1) { index, _ in index == 0 ? .serve(cut: 500_000, stall: 4) : .serve() }
    require(finished(result) && log.map(\.start) == [nil, 500_000] && !progress.failedShown, "a stalled transfer times out and resumes at 500,000 (\(log.map(\.start)))")
    // 5. A server that ignores Range (200 with the whole file): the partial file starts over and the file is right.
    (result, log, _, _) = try await run("norange") { index, _ in index == 0 ? .serve(cut: 600_000) : .serve(range: false) }
    require(finished(result) && log.count == 3 && log[0].start == nil && (log[1].start ?? 0) > 0 && log[2].start == nil,
            "a server without Range: the partial starts over once, the file is right (\(log.map(\.start)))")
    // 6. A 206 with the wrong Content-Range is never appended: tried again, then right.
    (result, log, _, _) = try await run("wrongrange") { index, _ in index == 0 ? .serve(cut: 300_000) : index == 1 ? .serve(wrongRange: true) : .serve() }
    require(finished(result) && log.count == 3 && (log[1].start ?? 0) > 0 && log[1].start == log[2].start, "a wrong Content-Range is refused and tried again (\(log.map(\.start)))")
    // 7. A damaged file once: deleted and downloaded once more from the start, by itself.
    (result, log, progress, _) = try await run("damagedonce") { index, _ in .serve(damage: index == 0) }
    require(finished(result) && log.map(\.start) == [nil, nil] && !progress.failedShown, "a damaged file is downloaded once more from the start by itself")
    // 8. Damaged every time: DownloadDamaged after the second full try, and no partial file left.
    (result, log, progress, dir) = try await run("damaged") { _, _ in .serve(damage: true) }
    if case .failure(let e) = result, e is DownloadDamaged {} else { require(false, "damaged twice fails as damaged: \(result)") }
    require(log.count == 2 && progress.failedShown && !fm.fileExists(atPath: dir.appendingPathComponent(hash + ".partial").path),
            "damaged twice: the download was damaged (Try Again starts over), no partial kept, two tries only")
    // 9. 404: stops at once (no retrying a missing file), partial kept.
    (result, log, progress, dir) = try await run("gone") { _, _ in .status(404) }
    if case .failure(DownloadInterruption.status(404, _)) = result {} else { require(false, "404 stops: \(result)") }
    require(log.count == 1 && progress.failedShown, "404 stops at once with one request")
    // 10. A redirect to a host that isn't allowed stops at once (the 302 surfaces), one request.
    (result, log, _, _) = try await run("redirect") { _, _ in .redirect("https://evil.invalid/model") }
    if case .failure(DownloadInterruption.status(302, _)) = result {} else { require(false, "a refused redirect stops: \(result)") }
    require(log.count == 1, "a refused redirect stops at once")
    // 11. Out of patience: 503 forever, stopped after the patience ran out, with the bytes already here kept for Try Again.
    let short = DownloadPatience(firstWait: 0.01, maximumWait: 0.05, giveUpAfter: 0.4)
    (result, log, progress, dir) = try await run("down", patience: short) { index, _ in index == 0 ? .serve(cut: 800_000) : .status(503) }
    let kept = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(hash + ".partial").path)[.size] as? NSNumber)?.intValue
    if case .failure(DownloadInterruption.status(503, _)) = result {} else { require(false, "503 forever stops: \(result)") }
    require(log.count > 3 && (kept ?? 0) > 0 && progress.failedShown, "503 forever: tried \(log.count) times, then stopped with \(kept ?? 0) bytes kept")
    // 12. Try Again (a new acquire) resumes that partial file, not from zero.
    server.use { _, _, _ in .serve() }
    let again = try await PersistentModelCache.acquire(asset: PinnedAsset(url: server.url("down"), bytes: bytes, sha256: hash), root: dir, priorRoots: [], chunks: chunks(), patience: quick)
    require(finished(.success(again)) && server.log.map(\.start) == [kept], "Try Again resumes where it stopped, not from zero (\(server.log.map(\.start)))")
    // 13. Offline the whole time: the patience is spent in waits that grow, and nothing is downloaded twice.
    let clock = FakeClock()
    let offline = DownloadPatience(firstWait: 1, maximumWait: 30, giveUpAfter: 15 * 60, now: { clock.now }, sleep: { clock.advance($0) })
    let offlineRoot = try root("offline")
    do {
        _ = try await PersistentModelCache.acquire(asset: PinnedAsset(url: server.url("offline"), bytes: bytes, sha256: hash), root: offlineRoot, priorRoots: [],
            chunks: { _, _ in throw URLError(.notConnectedToInternet) }, patience: offline)
        require(false, "offline forever stops")
    } catch { require((error as? URLError)?.code == .notConnectedToInternet, "offline for 15 minutes: it stops only then") }
    require(clock.waits.prefix(6) == [1, 2, 4, 8, 16, 30] && clock.waits.allSatisfy { $0 <= 30 } && abs(clock.now - 900) < 0.001,
            "waits grow 1, 2, 4, 8, 16, then every 30 s, for 15 minutes (\(clock.waits.count) tries)")

    // 14. Quit mid-download (the process is killed) and relaunch: the next launch resumes the partial file. Pieces reach
    // the file 1 MB at a time, so 1,500,000 bytes sent leave 1,048,576 on disk.
    server.use { _, index, _ in index == 0 ? .serve(cut: 1_500_000, stall: 60) : .serve() }
    let quitRoot = try root("quit")
    var pathSize: UInt32 = 4096; var path = [CChar](repeating: 0, count: Int(pathSize))
    precondition(_NSGetExecutablePath(&path, &pathSize) == 0)
    let child = Process(); child.executableURL = URL(fileURLWithPath: String(cString: path))
    child.arguments = ["--download-quit-probe", quitRoot.path, String(server.port), String(bytes), hash]
    try child.run()
    let partial = quitRoot.appendingPathComponent(hash + ".partial")
    var size = 0
    for _ in 0..<1000 {
        size = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.intValue ?? 0
        if size >= 1_048_576 { break }; try await Task.sleep(nanoseconds: 10_000_000)
    }
    kill(child.processIdentifier, SIGKILL); child.waitUntilExit()
    require(size == 1_048_576 && child.terminationReason == .uncaughtSignal, "quit mid-download: 1,048,576 bytes are on disk when the app is killed (\(size))")
    let resumed = try await PersistentModelCache.acquire(asset: PinnedAsset(url: server.url("quit"), bytes: bytes, sha256: hash), root: quitRoot, priorRoots: [], chunks: chunks(), patience: quick)
    require(finished(.success(resumed)) && server.log.map(\.start) == [nil, 1_048_576], "relaunch: the download resumes at 1,048,576 and finishes (\(server.log.map(\.start)))")
    print("PASS download server: drops, 503, 429, stall, no Range, wrong range, damaged once/twice, 404, refused redirect, out of patience, Try Again, offline, quit and relaunch")
}

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock(); private var time: TimeInterval = 0; private var slept: [TimeInterval] = []
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    var waits: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return slept }
    func advance(_ by: TimeInterval) { lock.lock(); time += by; slept.append(by); lock.unlock() }
}
