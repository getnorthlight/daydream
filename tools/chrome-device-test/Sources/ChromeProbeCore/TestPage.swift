import Foundation

/// Request -> response rules of the local test-page server
/// (chrome-device-test-serve), kept pure so the selftest can check them.
/// No sockets and no file system here: the server target does the I/O and
/// hands in a lookup for one file name.
///
/// It mirrors testpage/serve.py (Python's SimpleHTTPRequestHandler plus
/// "Cache-Control: no-store") for everything the page needs: same status
/// codes, same Content-Type, byte-identical bodies, HTTP/1.0 with the
/// connection closed after each reply. It is stricter where serve.py would
/// touch other files: only regular files directly inside the page folder
/// are served; subfolders, dotfiles, directory listings and redirects are
/// never produced (see README, "Running on a MacBook with the kit").
public enum TestPage {
    public static let port: UInt16 = 8765
    /// The server refuses to start without these.
    public static let requiredFiles = ["index.html", "frame.html"]
    /// Longest request head read before the reply is an error.
    public static let maxRequestBytes = 65_536
    public static let serverName = "chrome-device-test-serve"

    public struct File {
        public var bytes: [UInt8]
        public var modified: Date
        public init(bytes: [UInt8], modified: Date) { self.bytes = bytes; self.modified = modified }
    }

    public struct Header: Equatable {
        public var name: String
        public var value: String
        public init(_ name: String, _ value: String) { self.name = name; self.value = value }
    }

    public struct Response: Equatable {
        public var status: Int
        public var reason: String
        /// Every header except Cache-Control, which serialize() always adds last.
        public var headers: [Header]
        /// What goes on the wire after the head (empty for HEAD and 304).
        public var body: [UInt8]
        /// False only where Python answers an HTTP/0.9-style request: body only.
        public var statusLine = true

        public func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    // MARK: request head

    /// Index just past the blank line that ends the request head, or nil.
    public static func headEnd(_ b: [UInt8]) -> Int? {
        var i = 0
        while i < b.count {
            if b[i] == 10 {
                if i + 1 < b.count, b[i + 1] == 10 { return i + 2 }
                if i + 2 < b.count, b[i + 1] == 13, b[i + 2] == 10 { return i + 3 }
            }
            i += 1
        }
        return nil
    }

    /// The reply to one request head (bytes up to and including the blank
    /// line, or everything received before the client closed). nil means an
    /// empty request line: close without a reply, as serve.py does.
    public static func respond(head: [UInt8], now: Date, file: (String) -> File?) -> Response? {
        let text = String(head.map { Character(Unicode.Scalar($0)) })
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let requestLine = lines.isEmpty ? "" : lines.removeFirst()
        let words = requestLine.split(whereSeparator: { pythonSpace.contains($0) }).map(String.init)
        guard !words.isEmpty else { return nil }

        var version = "HTTP/0.9"
        if words.count >= 3 {
            let v = words[words.count - 1]
            guard v.hasPrefix("HTTP/") else {
                return error(400, "Bad request version (\(pyRepr(v)))", command: nil, version: version, now: now)
            }
            let base = String(v.dropFirst(5))
            let parts = base.components(separatedBy: ".")
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.count <= 10 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
                  let major = Int(parts[0]), let minor = Int(parts[1]) else {
                return error(400, "Bad request version (\(pyRepr(v)))", command: nil, version: version, now: now)
            }
            if (major, minor) >= (2, 0) {
                return error(505, "Invalid HTTP version (\(base))", command: nil, version: version, now: now)
            }
            version = v
        }
        guard (2...3).contains(words.count) else {
            return error(400, "Bad request syntax (\(pyRepr(requestLine)))", command: nil, version: version, now: now)
        }
        let command = words[0]
        var path = words[1]
        if words.count == 2, command != "GET" {
            return error(400, "Bad HTTP/0.9 request type (\(pyRepr(command)))", command: nil, version: version, now: now)
        }
        if path.hasPrefix("//") { path = "/" + String(path.drop { $0 == "/" }) }

        var headers: [(String, String)] = []
        if words.count == 3 {
            for line in lines {
                if line.isEmpty { break }
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers.append((String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
            }
        }
        func header(_ name: String) -> String? {
            headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
        }

        guard command == "GET" || command == "HEAD" else {
            return error(501, "Unsupported method (\(pyRepr(command)))", command: command, version: version, now: now)
        }
        guard let name = fileName(forPath: path), let f = file(name) else {
            return error(404, "File not found", command: command, version: version, now: now)
        }
        let base = [Header("Server", serverName), Header("Date", httpDate(now))]
        if let ims = header("If-Modified-Since"), header("If-None-Match") == nil, let since = parseHTTPDate(ims),
           f.modified.timeIntervalSince1970.rounded(.down) <= since.timeIntervalSince1970 {
            return Response(status: 304, reason: "Not Modified", headers: base, body: [], statusLine: version != "HTTP/0.9")
        }
        return Response(status: 200, reason: "OK",
                        headers: base + [Header("Content-Type", contentType(name)), Header("Content-Length", String(f.bytes.count)),
                                         Header("Last-Modified", httpDate(f.modified))],
                        body: command == "HEAD" ? [] : f.bytes, statusLine: version != "HTTP/0.9")
    }

    /// Reply when the client sent more than maxRequestBytes without ending
    /// the request head (serve.py: 414 for a long request line, 431 for
    /// long headers).
    public static func tooLarge(_ received: [UInt8], now: Date) -> Response {
        received.contains(10)
            ? error(431, "Line too long", command: nil, version: "HTTP/1.0", now: now)
            : error(414, nil, command: "", version: "", now: now)
    }

    // MARK: paths

    /// The single file name a request path maps to, or nil (404).
    /// Like serve.py: query and fragment dropped, percent-decoded, "." and
    /// ".." resolved without ever leaving the page folder, "/" -> index.html,
    /// a trailing slash on a file is 404. Stricter: exactly one component,
    /// no dotfiles, no control characters.
    public static func fileName(forPath target: String) -> String? {
        var p = target
        if let i = p.firstIndex(of: "#") { p = String(p[..<i]) }
        if let i = p.firstIndex(of: "?") { p = String(p[..<i]) }
        let decoded = percentDecode(p)
        let trailingSlash = decoded.hasSuffix("/")
        var stack: [String] = []
        for part in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(String(part))
            }
        }
        if stack.isEmpty { return "index.html" }
        guard stack.count == 1, !trailingSlash else { return nil }
        let name = stack[0]
        guard !name.hasPrefix("."),
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        return name
    }

    static func percentDecode(_ s: String) -> String {
        let u = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(u.count)
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var i = 0
        while i < u.count {
            if u[i] == 37, i + 2 < u.count, let h = hex(u[i + 1]), let l = hex(u[i + 2]) {
                out.append(h << 4 | l); i += 3
            } else {
                out.append(u[i]); i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Same answers as Python's mimetypes for the files a test page could hold.
    public static func contentType(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "text/html"
        case "py": return "text/x-python"
        case "txt": return "text/plain"
        case "md": return "text/markdown"
        case "css": return "text/css"
        case "js": return "text/javascript"
        case "json": return "application/json"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        case "ico": return "image/vnd.microsoft.icon"
        default: return "application/octet-stream"
        }
    }

    // MARK: replies

    static let phrases: [Int: (String, String)] = [
        304: ("Not Modified", "Document has not changed since given time"),
        400: ("Bad Request", "Bad request syntax or unsupported method"),
        404: ("Not Found", "Nothing matches the given URI"),
        414: ("URI Too Long", "URI is too long"),
        431: ("Request Header Fields Too Large", "The server is unwilling to process the request because its header fields are too large"),
        501: ("Not Implemented", "Server does not support this operation"),
        505: ("HTTP Version Not Supported", "Cannot fulfill request"),
    ]

    /// Python's send_error: status, "Connection: close", an HTML page, and
    /// no body for HEAD. Before the version is known the reply is body only.
    static func error(_ code: Int, _ message: String?, command: String?, version: String, now: Date) -> Response {
        let (short, long) = phrases[code] ?? ("???", "???")
        let msg = message ?? short
        var r = Response(status: code, reason: msg,
                         headers: [Header("Server", serverName), Header("Date", httpDate(now)), Header("Connection", "close")],
                         body: [], statusLine: version != "HTTP/0.9")
        let page = errorBody(code: code, message: msg, explain: long)
        r.headers += [Header("Content-Type", "text/html;charset=utf-8"), Header("Content-Length", String(page.count))]
        if command != "HEAD" { r.body = page }
        return r
    }

    /// Python 3.14's http.server error page, byte for byte.
    public static func errorBody(code: Int, message: String, explain: String) -> [UInt8] {
        let page = """
        <!DOCTYPE HTML>
        <html lang="en">
            <head>
                <meta charset="utf-8">
                <style type="text/css">
                    :root {
                        color-scheme: light dark;
                    }
                </style>
                <title>Error response</title>
            </head>
            <body>
                <h1>Error response</h1>
                <p>Error code: \(code)</p>
                <p>Message: \(htmlEscape(message)).</p>
                <p>Error code explanation: \(code) - \(htmlEscape(explain)).</p>
            </body>
        </html>

        """
        return Array(page.utf8)
    }

    /// The bytes sent for a reply. Every reply that has a head carries
    /// "Cache-Control: no-store", so Chrome never shows a stale page.
    public static func serialize(_ r: Response) -> [UInt8] {
        guard r.statusLine else { return r.body }
        var head = "HTTP/1.0 \(r.status) \(r.reason)\r\n"
        for h in r.headers { head += "\(h.name): \(h.value)\r\n" }
        head += "Cache-Control: no-store\r\n\r\n"
        return head.unicodeScalars.map { $0.value <= 0xFF ? UInt8($0.value) : 63 } + r.body
    }

    // MARK: helpers

    static let pythonSpace: Set<Character> = [" ", "\t", "\n", "\u{0B}", "\u{0C}", "\r", "\u{1C}", "\u{1D}", "\u{1E}", "\u{1F}", "\u{85}", "\u{A0}"]

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Python's repr() of a short string, as serve.py puts it in error messages.
    static func pyRepr(_ s: String) -> String {
        let quote: Character = s.contains("'") && !s.contains("\"") ? "\"" : "'"
        var out = String(quote)
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default:
                if Character(u) == quote { out += "\\" + String(quote) }
                else if u.value < 0x20 || (0x7F...0xA0).contains(u.value) || u.value == 0xAD {
                    out += "\\x" + (u.value < 16 ? "0" : "") + String(u.value, radix: 16)
                } else { out.unicodeScalars.append(u) }
            }
        }
        return out + String(quote)
    }

    static let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static var gmt: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    /// RFC 1123 date, e.g. "Thu, 24 Sep 2026 12:00:00 GMT" (whole seconds).
    public static func httpDate(_ d: Date) -> String {
        let t = Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down))
        let c = gmt.dateComponents([.weekday, .day, .month, .year, .hour, .minute, .second], from: t)
        func two(_ n: Int?) -> String { let v = n ?? 0; return v < 10 ? "0\(v)" : "\(v)" }
        return "\(days[(c.weekday ?? 1) - 1]), \(two(c.day)) \(months[(c.month ?? 1) - 1]) \(c.year ?? 1970) \(two(c.hour)):\(two(c.minute)):\(two(c.second)) GMT"
    }

    /// Parses an RFC 1123 date in UTC; anything else is ignored (nil), as
    /// serve.py ignores dates it cannot compare.
    public static func parseHTTPDate(_ s: String) -> Date? {
        let f = s.split(separator: " ").map(String.init)
        guard f.count == 6, f[0].hasSuffix(","), let day = Int(f[1]), let mon = months.firstIndex(of: f[2]),
              let year = Int(f[3]), ["GMT", "UTC", "UT", "Z", "+0000", "-0000"].contains(f[5]) else { return nil }
        let hms = f[4].split(separator: ":").compactMap { Int($0) }
        guard hms.count == 3 else { return nil }
        var dc = DateComponents()
        dc.year = year; dc.month = mon + 1; dc.day = day; dc.hour = hms[0]; dc.minute = hms[1]; dc.second = hms[2]
        return gmt.date(from: dc)
    }
}
