import Foundation

/// Deliberately small TOML editor: tables, dotted keys, strings, arrays (also across lines), inline tables, and
/// numbers, booleans and dates in any spelling. Multi-line strings and arrays of tables are refused rather than guessed. Original bytes, comments and order never change.
/// Managed delimiters carry the original file's existence and the one newline added before our block.
struct MCPConfigTOML {
    static let begin = "# DayDream managed MCP v1; original="
    static let end = "# End DayDream managed MCP v1\n"
    let text: String
    let root: [String: Any]
    let managedRange: Range<String.Index>?
    let originallyAbsent: Bool
    let prefixNewline: Bool
    /// `mcp_servers` was made by a dotted key or an inline table: a `[mcp_servers.daydream]` table can't be added.
    let serversClosed: Bool

    init(data: Data, shown: String) throws {
        // Control characters are refused anywhere (TOML allows none outside escapes), except tab, newline, and a
        // carriage return that ends a line (CRLF files).
        guard let text = String(data: data, encoding: .utf8) else { throw AIAppConnectError.notEditableTOML(shown) }
        let scalars = Array(text.unicodeScalars)
        for (i, c) in scalars.enumerated() where !(c.value == 9 || c.value == 10 || (c.value >= 0x20 && c.value != 0x7f)) {
            guard c.value == 13, i + 1 < scalars.count, scalars[i + 1].value == 10 else { throw AIAppConnectError.notEditableTOML(shown) }
        }
        self.text = text
        // claude/connect-fix-1003: the whole file is scanned as one stream, so arrays may span lines (with comments),
        // keys may be dotted, values may be inline tables, and numbers and dates may use any TOML spelling. Still
        // refused: multi-line strings and arrays of tables (`[[...]]`), which DayDream doesn't need to read.
        var root: [String: Any] = [:], table: [String] = [], tables = Set<String>(), keys = Set<String>(), closed = Set<String>()
        do {
            var scanner = Scanner(scalars)
            while !scanner.finished {
                scanner.space()
                if scanner.finished { break }
                if scanner.peek == "#" || scanner.peek == "\n" || scanner.peek == "\r" { try scanner.lineEnd(); continue }
                if scanner.take("[") {
                    guard !scanner.take("[") else { throw Invalid.syntax }
                    table = try scanner.path()
                    scanner.space()
                    guard scanner.take("]"), !table.isEmpty else { throw Invalid.syntax }
                    try scanner.lineEnd()
                    let identity = table.joined(separator: "\u{1f}")
                    guard tables.insert(identity).inserted, !closed.contains(identity) else { throw Invalid.syntax }
                    try Self.insert([String: Any](), at: table, into: &root, table: true)
                } else {
                    let key = try scanner.path()
                    scanner.space()
                    guard scanner.take("=") else { throw Invalid.syntax }
                    scanner.space()
                    var inline = Set<[String]>()
                    let value = try scanner.value(inline: &inline)
                    try scanner.lineEnd()
                    let path = table + key, identity = path.joined(separator: "\u{1f}")
                    guard keys.insert(identity).inserted else { throw Invalid.syntax }
                    // Tables made by dotted keys or inline tables are closed: no `[header]` may add to them.
                    for n in (table.count + 1)..<path.count { closed.insert(path[..<n].joined(separator: "\u{1f}")) }
                    for sub in inline { closed.insert((path + sub).joined(separator: "\u{1f}")) }
                    try Self.insert(value, at: path, into: &root, table: false)
                }
            }
        } catch { throw AIAppConnectError.notEditableTOML(shown) }
        serversClosed = closed.contains("mcp_servers") || closed.contains("mcp_servers\u{1f}daydream")
        self.root = root
        let starts = text.ranges(of: Self.begin), ends = text.ranges(of: Self.end)
        if starts.isEmpty && ends.isEmpty {
            managedRange = nil; originallyAbsent = false; prefixNewline = false
        } else {
            guard starts.count == 1, ends.count == 1, let start = starts.first, let end = ends.first,
                  start.lowerBound < end.lowerBound,
                  start.lowerBound == text.startIndex || text.unicodeScalars[text.unicodeScalars.index(before: start.lowerBound)] == "\n",
                  let headerEnd = text[start.lowerBound...].firstIndex(of: "\n") else {
                throw AIAppConnectError.notEditableTOML(shown)
            }
            let header = String(text[start.lowerBound..<headerEnd])
            let absent: Bool, newline: Bool
            switch header {
            case Self.begin + "absent; prefix-newline=0": absent = true; newline = false
            case Self.begin + "absent; prefix-newline=1": absent = true; newline = true
            case Self.begin + "present; prefix-newline=0": absent = false; newline = false
            case Self.begin + "present; prefix-newline=1": absent = false; newline = true
            default: throw AIAppConnectError.notEditableTOML(shown)
            }
            var lower = start.lowerBound
            if newline {
                guard lower > text.startIndex else { throw AIAppConnectError.notEditableTOML(shown) }
                lower = text.unicodeScalars.index(before: lower)
            }
            managedRange = lower..<end.upperBound; originallyAbsent = absent; prefixNewline = newline
            // Ownership requires an intact generated block, not just familiar command-line flags.
            let entry = (root["mcp_servers"] as? [String: Any])?["daydream"] as? [String: Any]
            guard let entry, Set(entry.keys) == Set(["command", "args", "env"]),
                  let command = entry["command"] as? String, let args = entry["args"] as? [String],
                  let env = entry["env"] as? [String: Any], Set(env.keys) == Set(["MAC_MEM_CAPABILITY"]),
                  let key = env["MAC_MEM_CAPABILITY"] as? String,
                  String(text[start.lowerBound..<end.upperBound]) == Self.block(command: command, args: args, key: key, absent: absent, newline: newline) else {
                throw AIAppConnectError.notEditableTOML(shown)
            }
        }
    }

    func removingEntry() -> Data {
        guard let managedRange else { return Data(text.utf8) }
        var remainder = text; remainder.removeSubrange(managedRange)
        return Data(remainder.utf8)
    }

    func settingEntry(command: String, args: [String], key: String, fileExists: Bool) -> Data {
        let remainder = String(decoding: removingEntry(), as: UTF8.self)
        let newline = !remainder.isEmpty && remainder.unicodeScalars.last != "\n"
        let absent = managedRange == nil ? !fileExists : originallyAbsent
        return Data((remainder + (newline ? "\n" : "") + Self.block(command: command, args: args, key: key, absent: absent, newline: newline)).utf8)
    }

    static func quote(_ value: String) -> String {
        // JSON basic string escaping is valid TOML for these strings (forward slashes aren't escaped).
        String(decoding: try! JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]), as: UTF8.self).dropFirst().dropLast().description
    }
    static func block(command: String, args: [String], key: String, absent: Bool, newline: Bool) -> String {
        begin + (absent ? "absent" : "present") + "; prefix-newline=\(newline ? 1 : 0)\n" +
        "[mcp_servers.daydream]\ncommand = \(quote(command))\nargs = [\(args.map(quote).joined(separator: ", "))]\n" +
        "[mcp_servers.daydream.env]\nMAC_MEM_CAPABILITY = \(quote(key))\n" + end
    }

    private static func insert(_ value: Any, at path: [String], into root: inout [String: Any], table: Bool) throws {
        guard let first = path.first else { throw Invalid.syntax }
        if path.count == 1 {
            if table {
                if let current = root[first] { guard current is [String: Any] else { throw Invalid.syntax } }
                else { root[first] = value }
            } else {
                guard root[first] == nil else { throw Invalid.syntax }
                root[first] = value
            }
        } else {
            var child: [String: Any]
            if let existing = root[first] {
                guard let dictionary = existing as? [String: Any] else { throw Invalid.syntax }; child = dictionary
            } else { child = [:] }
            try insert(value, at: Array(path.dropFirst()), into: &child, table: table)
            root[first] = child
        }
    }
    private enum Invalid: Error { case syntax }
    private struct Scanner {
        let chars: [Unicode.Scalar]
        var i = 0
        init(_ scalars: [Unicode.Scalar]) { chars = scalars }
        var finished: Bool { i == chars.count }
        var peek: Unicode.Scalar? { finished ? nil : chars[i] }
        func peek(_ offset: Int) -> Unicode.Scalar? { i + offset < chars.count ? chars[i + offset] : nil }
        mutating func take(_ c: Unicode.Scalar) -> Bool { guard peek == c else { return false }; i += 1; return true }
        mutating func space() { while peek == " " || peek == "\t" { i += 1 } }
        mutating func comment() { if peek == "#" { while let c = peek, c != "\n", !(c == "\r" && peek(1) == "\n") { i += 1 } } }
        /// Spaces, an optional comment, then the end of the line (or of the file).
        mutating func lineEnd() throws {
            space(); comment()
            if finished { return }
            if take("\r") { guard take("\n") else { throw Invalid.syntax }; return }
            guard take("\n") else { throw Invalid.syntax }
        }
        /// Inside an array: spaces, comments and line breaks.
        mutating func blank() throws {
            while true {
                space(); comment()
                if take("\n") { continue }
                if peek == "\r" { i += 1; guard take("\n") else { throw Invalid.syntax }; continue }
                return
            }
        }
        mutating func key() throws -> String {
            if peek == "\"" || peek == "'" {
                let result = try string()
                guard result.utf8.count <= 1024, !result.contains("\u{1f}") else { throw Invalid.syntax }
                return result
            }
            let start = i
            while let c = peek, c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "_" || c == "-") { i += 1 }
            guard i > start, i - start <= 1024 else { throw Invalid.syntax }
            return String(String.UnicodeScalarView(chars[start..<i]))
        }
        mutating func path() throws -> [String] {
            space(); var result = [try key()]; space()
            while take(".") {
                guard result.count < 16 else { throw Invalid.syntax }
                space(); result.append(try key()); space()
            }
            // Separator used for duplicate detection must never occur inside a key.
            guard result.allSatisfy({ !$0.contains("\u{1f}") }) else { throw Invalid.syntax }
            return result
        }
        mutating func string() throws -> String {
            guard let quote = peek else { throw Invalid.syntax }
            // Multi-line strings aren't read.
            guard !(peek(1) == quote && peek(2) == quote) else { throw Invalid.syntax }
            i += 1
            var result = String.UnicodeScalarView()
            while let c = peek {
                i += 1
                if c == quote { return String(result) }
                if c == "\n" || c == "\r" { throw Invalid.syntax }
                if c == "\\" && quote == "\"" {
                    guard let escaped = peek else { throw Invalid.syntax }; i += 1
                    switch escaped {
                    case "b": result.append("\u{8}")
                    case "t": result.append("\t")
                    case "n": result.append("\n")
                    case "f": result.append("\u{c}")
                    case "r": result.append("\r")
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "u", "U":
                        let count = escaped == "u" ? 4 : 8
                        guard i + count <= chars.count, let scalar = UInt32(String(String.UnicodeScalarView(chars[i..<i+count])), radix: 16),
                              let unicode = Unicode.Scalar(scalar) else { throw Invalid.syntax }
                        i += count; result.append(unicode)
                    default: throw Invalid.syntax
                    }
                } else {
                    guard c.value >= 0x20 || c.value == 9, c.value != 0x7f else { throw Invalid.syntax }
                    result.append(c)
                }
            }
            throw Invalid.syntax
        }
        /// `inline` collects the paths (relative to this value) of the inline tables in it.
        mutating func value(depth: Int = 0, inline: inout Set<[String]>, at here: [String] = []) throws -> Any {
            guard depth < 16 else { throw Invalid.syntax }
            if peek == "\"" || peek == "'" { return try string() }
            if take("[") {
                var values: [Any] = []
                try blank()
                if take("]") { return values }
                while true {
                    var ignored = Set<[String]>()
                    values.append(try value(depth: depth + 1, inline: &ignored)); try blank()
                    if take("]") { return values }
                    guard take(",") else { throw Invalid.syntax }; try blank()
                    if take("]") { return values }
                }
            }
            if take("{") {
                // An inline table: one line, `key = value` pairs, no trailing comma.
                inline.insert(here)
                var table: [String: Any] = [:], seen = Set<String>()
                space()
                if take("}") { return table }
                while true {
                    let key = try path(); space()
                    guard take("=") else { throw Invalid.syntax }; space()
                    let item = try value(depth: depth + 1, inline: &inline, at: here + key)
                    guard seen.insert(key.joined(separator: "\u{1f}")).inserted else { throw Invalid.syntax }
                    for n in 1..<max(key.count, 1) { inline.insert(here + key[..<n]) }
                    try MCPConfigTOML.insert(item, at: key, into: &table, table: false)
                    space()
                    if take("}") { return table }
                    guard take(",") else { throw Invalid.syntax }; space()
                }
            }
            let start = i
            while let c = peek, c != " " && c != "\t" && c != "#" && c != "," && c != "]" && c != "}" && c != "\n" && c != "\r" { i += 1 }
            var token = String(String.UnicodeScalarView(chars[start..<i]))
            // A date and a time may be separated by one space.
            if token.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil, peek == " ",
               let a = peek(1), let b = peek(2), peek(3) == ":", CharacterSet.decimalDigits.contains(a), CharacterSet.decimalDigits.contains(b) {
                i += 1
                let more = i
                while let c = peek, c != " " && c != "\t" && c != "#" && c != "," && c != "]" && c != "}" && c != "\n" && c != "\r" { i += 1 }
                token += " " + String(String.UnicodeScalarView(chars[more..<i]))
            }
            if token == "true" { return true }; if token == "false" { return false }
            if token.range(of: #"^[+-]?(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil, let value = Int64(token) { return value }
            if token.range(of: #"^[+-]?(0|[1-9][0-9]*)\.[0-9]+([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil, let value = Double(token), value.isFinite { return value }
            // Other TOML spellings are kept as their text (DayDream never reads these values).
            let spellings = [
                #"^[+-]?(0|[1-9](_?[0-9])*)$"#,                                           // 1_000
                #"^0x[0-9A-Fa-f](_?[0-9A-Fa-f])*$"#, #"^0o[0-7](_?[0-7])*$"#, #"^0b[01](_?[01])*$"#,
                #"^[+-]?(0|[1-9](_?[0-9])*)(\.[0-9](_?[0-9])*)?([eE][+-]?[0-9](_?[0-9])*)?$"#, // 1e6, 3.141_592
                #"^[+-]?(inf|nan)$"#,
                #"^\d{4}-\d{2}-\d{2}([Tt ]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})?)?$"#,
                #"^\d{2}:\d{2}:\d{2}(\.\d+)?$"#,
            ]
            if spellings.contains(where: { token.range(of: $0, options: .regularExpression) != nil }) { return token }
            throw Invalid.syntax
        }
    }
}

private extension String {
    func ranges(of needle: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = [], start = startIndex
        while start < endIndex, let range = range(of: needle, range: start..<endIndex) { result.append(range); start = range.upperBound }
        return result
    }
}
