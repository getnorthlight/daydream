import Foundation
import Darwin
import ChromeProbeCore

// chrome-device-test-serve: serves the device-test page (testpage/) on this
// Mac only, for the MacBook kit where Python is not installed. It replaces
// `python3 testpage/serve.py`, which stays for developers.
//
// Loopback only: it binds 127.0.0.1 and ::1 (never a wildcard address), so
// nothing on the network can reach it. GET and HEAD only; the request rules
// are ChromeProbeCore/TestPage.swift. It talks to no other app: no Apple
// Events, no Accessibility, and it starts no other program.

let usage = """
chrome-device-test-serve: serves the Chrome device-test page on this Mac only.

USAGE
  chrome-device-test-serve [--root DIR] [--port N]

  --root DIR   the folder with index.html and frame.html (default: the
               testpage folder next to this program, or next to its bin folder)
  --port N     the port (default 8765). It listens on 127.0.0.1 and ::1 only.

Press Ctrl+C to stop it.
"""

/// Exit codes: 0 stopped normally, 1 could not listen, 2 no test page,
/// 3 the port is already in use, 64 bad arguments.
func stop(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

// A closed browser tab must not kill the server.
signal(SIGPIPE, SIG_IGN)

var rootArg: String?
var port = TestPage.port
var argv = Array(CommandLine.arguments.dropFirst())[...]
while let a = argv.popFirst() {
    switch a {
    case "--root":
        guard let v = argv.popFirst() else { stop("error: --root needs a folder\n\n" + usage, 64) }
        rootArg = v
    case "--port":
        guard let v = argv.popFirst(), let p = UInt16(v), p > 0 else { stop("error: --port needs a number from 1 to 65535\n\n" + usage, 64) }
        port = p
    case "--help", "-h":
        print(usage)
        exit(0)
    default:
        stop("error: unknown argument \(a)\n\n" + usage, 64)
    }
}

// MARK: - the page folder

func realPath(_ p: String) -> String? {
    guard let r = realpath(p, nil) else { return nil }
    defer { free(r) }
    return String(cString: r)
}

func executableFolder() -> String? {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buf, &size) == 0, let exe = realPath(String(cString: buf)) else { return nil }
    return (exe as NSString).deletingLastPathComponent
}

func isRegularFile(_ path: String) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
}

func hasPage(_ dir: String) -> Bool { TestPage.requiredFiles.allSatisfy { isRegularFile(dir + "/" + $0) } }

let candidates: [String] = rootArg.map { [$0] } ?? executableFolder().map { [$0 + "/testpage", $0 + "/../testpage"] } ?? []
guard let root = candidates.compactMap(realPath).first(where: hasPage) else {
    stop("error: no test page found (looked in: \(candidates.joined(separator: ", "))).\n"
         + "The folder must hold index.html and frame.html. Pass it with --root.", 2)
}

/// One file directly inside the page folder, never through a symlink.
func readPageFile(_ name: String) -> TestPage.File? {
    let fd = open(root + "/" + name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(Int(st.st_size))
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n < 0 { if errno == EINTR { continue }; return nil }
        if n == 0 { break }
        bytes += chunk[0..<n]
    }
    let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
    return TestPage.File(bytes: bytes, modified: modified)
}

// MARK: - loopback sockets

func loopbackV4(_ port: UInt16) -> sockaddr_in {
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    _ = inet_pton(AF_INET, "127.0.0.1", &a.sin_addr)
    return a
}

func loopbackV6(_ port: UInt16) -> sockaddr_in6 {
    var a = sockaddr_in6()
    a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    a.sin6_family = sa_family_t(AF_INET6)
    a.sin6_port = port.bigEndian
    _ = inet_pton(AF_INET6, "::1", &a.sin6_addr)
    return a
}

func withSockaddr<T, R>(_ address: T, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
    var a = address
    return withUnsafePointer(to: &a) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<T>.size)) }
    }
}

func setOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) {
    var v = value
    _ = setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size))
}

/// True if something already answers on this loopback address and port.
func somethingListens<T>(_ family: Int32, _ address: T) -> Bool {
    let fd = socket(family, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    setOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
    return withSockaddr(address) { connect(fd, $0, $1) } == 0
}

enum Listen { case ok(Int32), inUse, failed(Int32) }

func listenV4(_ port: UInt16) -> Listen {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return .failed(errno) }
    setOption(fd, SOL_SOCKET, SO_REUSEADDR, 1)
    guard withSockaddr(loopbackV4(port), { Darwin.bind(fd, $0, $1) }) == 0, Darwin.listen(fd, 64) == 0 else {
        let e = errno; close(fd); return e == EADDRINUSE ? .inUse : .failed(e)
    }
    return .ok(fd)
}

func listenV6(_ port: UInt16) -> Listen {
    let fd = socket(AF_INET6, SOCK_STREAM, 0)
    guard fd >= 0 else { return .failed(errno) }
    setOption(fd, IPPROTO_IPV6, IPV6_V6ONLY, 1)
    setOption(fd, SOL_SOCKET, SO_REUSEADDR, 1)
    guard withSockaddr(loopbackV6(port), { Darwin.bind(fd, $0, $1) }) == 0, Darwin.listen(fd, 64) == 0 else {
        let e = errno; close(fd); return e == EADDRINUSE ? .inUse : .failed(e)
    }
    return .ok(fd)
}

let portInUse = """
error: port \(port) is already in use on this Mac, so the test page cannot start.
Another program (or an earlier test page that is still running) is using it.
Quit that program, then try again.
"""

if somethingListens(AF_INET, loopbackV4(port)) || somethingListens(AF_INET6, loopbackV6(port)) {
    stop(portInUse, 3)
}

var listeners: [Int32] = []
switch listenV4(port) {
case .ok(let fd): listeners.append(fd)
case .inUse: stop(portInUse, 3)
case .failed(let e): stop("error: could not listen on 127.0.0.1:\(port): \(String(cString: strerror(e)))", 1)
}
switch listenV6(port) {
case .ok(let fd): listeners.append(fd)
case .inUse: stop(portInUse, 3)
case .failed: print("note: IPv6 loopback unavailable; http://localhost may still work via 127.0.0.1")
}

// MARK: - connections

func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
    var sent = 0
    while sent < bytes.count {
        let n = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return }
        sent += n
    }
}

/// One connection: read one request head, reply, close (HTTP/1.0). Chrome
/// opens spare connections that never send anything; they time out after
/// 30 seconds on their own thread and block nobody.
func serve(_ c: Int32) {
    defer { close(c) }
    setOption(c, SOL_SOCKET, SO_NOSIGPIPE, 1)
    var timeout = timeval(tv_sec: 30, tv_usec: 0)
    _ = setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var received: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 8192)
    var reply: TestPage.Response?
    while true {
        let n = read(c, &chunk, chunk.count)
        if n < 0 && errno == EINTR { continue }
        if n < 0 { return }                      // timed out or reset: no reply
        if n == 0 {                              // client finished sending
            if !received.isEmpty { reply = TestPage.respond(head: received, now: Date(), file: readPageFile) }
            break
        }
        received += chunk[0..<n]
        if let end = TestPage.headEnd(received) {
            reply = TestPage.respond(head: Array(received[0..<end]), now: Date(), file: readPageFile)
            break
        }
        if received.count > TestPage.maxRequestBytes {
            reply = TestPage.tooLarge(received, now: Date())
            break
        }
    }
    guard let reply else { return }
    writeAll(c, TestPage.serialize(reply))
    shutdown(c, SHUT_WR)
}

func acceptLoop(_ fd: Int32) {
    while true {
        let c = accept(fd, nil, nil)
        if c < 0 {
            if errno != EINTR && errno != ECONNABORTED { usleep(20_000) }
            continue
        }
        let t = Thread { serve(c) }
        t.stackSize = 1 << 20
        t.start()
    }
}

for fd in listeners {
    let t = Thread { acceptLoop(fd) }
    t.start()
}

// Ctrl+C, a closed Terminal window or the kit's clean-up: close and exit 0.
var signalSources: [DispatchSourceSignal] = []
for s in [SIGINT, SIGTERM, SIGHUP] {
    signal(s, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
    src.setEventHandler {
        for fd in listeners { close(fd) }
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}
print("Serving \(root) at http://127.0.0.1:\(port)/ (loopback only). Ctrl+C to stop.")
fflush(stdout)
dispatchMain()
