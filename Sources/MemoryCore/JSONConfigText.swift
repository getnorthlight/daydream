import Foundation

/// Exact text edits of an AI app's JSON settings file (claude/connect-fix-1003).
///
/// Connect used to parse the whole file, set the entry and print the whole file again. That changed every byte
/// (key order, spacing, `\/`, number spelling), and some numbers don't survive a print-and-read: a long decimal such
/// as 0.1234567890123456789 reads back as a slightly different number. The value-by-value check then failed and
/// Claude Code (whose ~/.claude.json is large and full of such numbers) could never be connected.
///
/// This editor never prints the file again. It finds the byte ranges of the servers object and of the "daydream"
/// member, and inserts, replaces or removes only that member's text. Every other byte stays exactly as it was. The
/// new member copies the file's own indentation and `": "` spelling. Insert and remove are exact inverses: removing
/// a member DayDream inserted gives back the original bytes.
///
/// The caller still parses the result and compares it with the original plus (or minus) the one entry.
struct JSONConfigText {
    enum Failure: Error { case syntax, duplicate, shape }

    struct Member { let keyStart: Int; let keyEnd: Int; let valueStart: Int; let valueEnd: Int; let key: String }
    /// `open` is the index of `{`, `close` the index of the matching `}`.
    struct Object { let open: Int; let close: Int; let members: [Member] }

    /// A value DayDream writes, in the order it is written.
    indirect enum Value {
        case string(String)
        case array([Value])
        case object([(String, Value)])
    }

    let bytes: [UInt8]
    let root: Object

    init(data: Data) throws {
        bytes = [UInt8](data)
        var start = 0
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { start = 3 }
        start = Self.skipSpace(bytes, start)
        guard start < bytes.count, bytes[start] == UInt8(ascii: "{") else { throw Failure.syntax }
        let (object, end) = try Self.scanObject(bytes, start, depth: 0)
        guard Self.skipSpace(bytes, end) == bytes.count else { throw Failure.syntax }
        root = object
    }

    // MARK: Scanning (the file already parsed as JSON; this only finds where things are)

    static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0a || byte == 0x0d || byte == 0x09 }
    static func skipSpace(_ b: [UInt8], _ index: Int) -> Int {
        var i = index
        while i < b.count, isSpace(b[i]) { i += 1 }
        return i
    }
    /// `index` is at the opening quote; returns the index just after the closing quote.
    static func skipString(_ b: [UInt8], _ index: Int) throws -> Int {
        guard index < b.count, b[index] == UInt8(ascii: "\"") else { throw Failure.syntax }
        var i = index + 1
        while i < b.count {
            switch b[i] {
            case UInt8(ascii: "\\"): i += 2
            case UInt8(ascii: "\""): return i + 1
            default: i += 1
            }
        }
        throw Failure.syntax
    }
    static func skipValue(_ b: [UInt8], _ index: Int, depth: Int) throws -> Int {
        guard depth < 512, index < b.count else { throw Failure.syntax }
        switch b[index] {
        case UInt8(ascii: "{"): return try scanObject(b, index, depth: depth + 1).1
        case UInt8(ascii: "["):
            var i = skipSpace(b, index + 1)
            guard i < b.count else { throw Failure.syntax }
            if b[i] == UInt8(ascii: "]") { return i + 1 }
            while true {
                i = skipSpace(b, try skipValue(b, i, depth: depth + 1))
                guard i < b.count else { throw Failure.syntax }
                if b[i] == UInt8(ascii: "]") { return i + 1 }
                guard b[i] == UInt8(ascii: ",") else { throw Failure.syntax }
                i = skipSpace(b, i + 1)
            }
        case UInt8(ascii: "\""): return try skipString(b, index)
        default:
            var i = index
            while i < b.count, !isSpace(b[i]), b[i] != UInt8(ascii: ","), b[i] != UInt8(ascii: "}"), b[i] != UInt8(ascii: "]") { i += 1 }
            guard i > index else { throw Failure.syntax }
            return i
        }
    }
    static func scanObject(_ b: [UInt8], _ index: Int, depth: Int) throws -> (Object, Int) {
        guard depth < 512, index < b.count, b[index] == UInt8(ascii: "{") else { throw Failure.syntax }
        var members: [Member] = []
        var i = skipSpace(b, index + 1)
        guard i < b.count else { throw Failure.syntax }
        if b[i] == UInt8(ascii: "}") { return (Object(open: index, close: i, members: []), i + 1) }
        while true {
            let keyStart = i, keyEnd = try skipString(b, i)
            i = skipSpace(b, keyEnd)
            guard i < b.count, b[i] == UInt8(ascii: ":") else { throw Failure.syntax }
            let valueStart = skipSpace(b, i + 1)
            let valueEnd = try skipValue(b, valueStart, depth: depth + 1)
            members.append(Member(keyStart: keyStart, keyEnd: keyEnd, valueStart: valueStart, valueEnd: valueEnd,
                                  key: try decodeKey(b, keyStart, keyEnd)))
            i = skipSpace(b, valueEnd)
            guard i < b.count else { throw Failure.syntax }
            if b[i] == UInt8(ascii: "}") { return (Object(open: index, close: i, members: members), i + 1) }
            guard b[i] == UInt8(ascii: ",") else { throw Failure.syntax }
            i = skipSpace(b, i + 1)
        }
    }
    static func decodeKey(_ b: [UInt8], _ start: Int, _ end: Int) throws -> String {
        let inner = b[(start + 1)..<(end - 1)]
        if !inner.contains(UInt8(ascii: "\\")) { return String(decoding: inner, as: UTF8.self) }
        guard let key = try? JSONSerialization.jsonObject(with: Data(b[start..<end]), options: .fragmentsAllowed) as? String else { throw Failure.syntax }
        return key
    }

    func object(at index: Int) throws -> Object {
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { throw Failure.shape }
        return try Self.scanObject(bytes, index, depth: 1).0
    }
    /// The one member called `key`, nil when there is none. Two members with the same name are refused: which one an
    /// app reads isn't certain, so DayDream doesn't guess.
    func member(_ key: String, in object: Object) throws -> (index: Int, member: Member)? {
        let found = object.members.enumerated().filter { $0.element.key == key }
        guard found.count <= 1 else { throw Failure.duplicate }
        return found.first.map { ($0.offset, $0.element) }
    }

    // MARK: The file's own layout

    func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
    /// The spaces and tabs that start the line `index` is on.
    func lineIndent(_ index: Int) -> String {
        var start = index
        while start > 0, bytes[start - 1] != 0x0a { start -= 1 }
        var end = start
        while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        return text(start..<end)
    }
    /// One member per line (the usual pretty-printed file), or all on one line.
    func multiline(_ object: Object) -> Bool {
        if let first = object.members.first { return bytes[(object.open + 1)..<first.keyStart].contains(0x0a) }
        if let first = root.members.first { return bytes[(root.open + 1)..<first.keyStart].contains(0x0a) }
        return true
    }
    /// One level of indentation, read from the top-level object (two spaces when it can't be read).
    var unit: String {
        guard let first = root.members.first, multiline(root) else { return "  " }
        let member = indentBefore(first.keyStart), outer = lineIndent(root.open)
        guard member.hasPrefix(outer), member.count > outer.count else { return "  " }
        return String(member.dropFirst(outer.count))
    }
    /// What separates a key from its value (`": "` when the file has no member to copy from).
    var colon: String {
        guard let first = root.members.first else { return ": " }
        let between = text(first.keyEnd..<first.valueStart)
        return between.contains("\n") || between.contains("\r") ? ": " : between
    }
    /// The file's line break: "\r\n" when its first line ends that way, else "\n".
    var newline: String {
        guard let first = bytes.firstIndex(of: 0x0a), first > 0, bytes[first - 1] == 0x0d else { return "\n" }
        return "\r\n"
    }
    /// What follows a comma between members on one line.
    func afterComma(_ object: Object) -> String {
        guard object.members.count >= 2 else { return " " }
        var i = object.members[1].keyStart
        while i > 0, Self.isSpace(bytes[i - 1]) { i -= 1 }
        return text(i..<object.members[1].keyStart)
    }
    /// The whitespace just before `index`, after the last line break.
    func indentBefore(_ index: Int) -> String {
        var start = index
        while start > 0, bytes[start - 1] == 0x20 || bytes[start - 1] == 0x09 { start -= 1 }
        return text(start..<index)
    }
    func memberIndent(_ object: Object) -> String {
        if let first = object.members.first { return indentBefore(first.keyStart) }
        return lineIndent(object.open) + unit
    }

    // MARK: Writing values

    static func quote(_ string: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8),
               as: UTF8.self)
    }
    func render(_ value: Value, indent: String, multiline: Bool) -> String {
        switch value {
        case .string(let string): return Self.quote(string)
        case .array(let items):
            if items.isEmpty { return "[]" }
            if !multiline { return "[" + items.map { render($0, indent: indent, multiline: false) }.joined(separator: "," + afterCommaInline) + "]" }
            let inner = indent + unit
            return "[" + newline + items.map { inner + render($0, indent: inner, multiline: true) }.joined(separator: "," + newline) + newline + indent + "]"
        case .object(let members):
            if members.isEmpty { return "{}" }
            if !multiline {
                return "{" + members.map { Self.quote($0.0) + colon + render($0.1, indent: indent, multiline: false) }.joined(separator: "," + afterCommaInline) + "}"
            }
            let inner = indent + unit
            return "{" + newline + members.map { inner + Self.quote($0.0) + colon + render($0.1, indent: inner, multiline: true) }.joined(separator: "," + newline)
                + newline + indent + "}"
        }
    }
    private var afterCommaInline: String { afterComma(root).contains("\n") ? " " : afterComma(root) }

    func replacing(_ range: Range<Int>, with text: String) -> Data {
        var out = Data(capacity: bytes.count + text.utf8.count)
        out.append(contentsOf: bytes[0..<range.lowerBound])
        out.append(contentsOf: Array(text.utf8))
        out.append(contentsOf: bytes[range.upperBound..<bytes.count])
        return out
    }

    /// Adds `key: value` as the last member of `object`, in the object's own layout.
    func inserting(_ key: String, _ value: Value, into object: Object) -> Data {
        let lines = multiline(object)
        if object.members.isEmpty {
            // `{}` becomes `{ member }` on its own lines; removing the member gives `{}` back.
            let indent = memberIndent(object)
            let member = Self.quote(key) + colon + render(value, indent: indent, multiline: lines)
            return replacing((object.open + 1)..<object.close, with: lines ? newline + indent + member + newline + lineIndent(object.open) : member)
        }
        let last = object.members[object.members.count - 1]
        var gap = last.keyStart
        while gap > 0, Self.isSpace(bytes[gap - 1]) { gap -= 1 }
        let lead = text(gap..<last.keyStart)
        let indent = lines ? indentBefore(last.keyStart) : ""
        let member = Self.quote(key) + colon + render(value, indent: indent, multiline: lines)
        return replacing(last.valueEnd..<last.valueEnd, with: "," + (lines ? lead : afterComma(object)) + member)
    }
    /// Removes member `index` of `object`: the exact inverse of `inserting`.
    func removing(_ index: Int, of object: Object) -> Data {
        let members = object.members
        if members.count == 1 { return replacing((object.open + 1)..<object.close, with: "") }
        if index > 0 { return replacing(members[index - 1].valueEnd..<members[index].valueEnd, with: "") }
        return replacing(members[0].keyStart..<members[1].keyStart, with: "")
    }

    // MARK: The edits Connect and Disconnect make

    /// Sets `servers[name]` to `value`: replaces only the old value's text, or adds the member (and the servers
    /// object when there is none).
    func setting(servers serversKey: String, name: String, value: Value) throws -> Data {
        guard let servers = try member(serversKey, in: root) else {
            return inserting(serversKey, .object([(name, value)]), into: root)
        }
        let object = try self.object(at: servers.member.valueStart)
        if let entry = try member(name, in: object) {
            let indent = multiline(object) ? indentBefore(entry.member.keyStart) : ""
            return replacing(entry.member.valueStart..<entry.member.valueEnd, with: render(value, indent: indent, multiline: multiline(object)))
        }
        return inserting(name, value, into: object)
    }

    /// Removes `servers[name]`. With `dropEmptyServers`, a servers object left empty goes too (DayDream added it).
    /// Nil when there is no such member.
    func removingEntry(servers serversKey: String, name: String, dropEmptyServers: Bool) throws -> (data: Data, droppedServers: Bool)? {
        guard let servers = try member(serversKey, in: root) else { return nil }
        let object = try self.object(at: servers.member.valueStart)
        guard let entry = try member(name, in: object) else { return nil }
        if dropEmptyServers && object.members.count == 1 { return (removing(servers.index, of: root), true) }
        return (removing(entry.index, of: object), false)
    }

    /// The text of a file DayDream makes from nothing.
    static func fresh(servers serversKey: String, name: String, value: Value) -> Data {
        let empty = try! JSONConfigText(data: Data("{}".utf8))
        var data = empty.inserting(serversKey, .object([(name, value)]), into: empty.root)
        data.append(0x0a)
        return data
    }
}
