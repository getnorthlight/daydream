import Foundation

enum RuntimeManifestReader {
    static func read(_ data: Data) throws -> SignedRuntimeManifest {
        guard !data.isEmpty, data.count <= 32_768 else { throw WriterFailure.integrity }
        var parser = Scanner(bytes: Array(data))
        try parser.value(depth: 0); parser.space()
        guard parser.index == parser.bytes.count else { throw WriterFailure.integrity }
        return try JSONDecoder().decode(SignedRuntimeManifest.self, from: data)
    }
    private struct Scanner {
        let bytes: [UInt8]; var index = 0
        mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte: UInt8) -> Bool { space(); if index < bytes.count && bytes[index] == byte { index += 1; return true }; return false }
        mutating func string() throws -> String {
            space(); let start = index
            guard take(34) else { throw WriterFailure.integrity }
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                if byte == 92 { guard index < bytes.count else { throw WriterFailure.integrity }; index += 1 }
            }
            throw WriterFailure.integrity
        }
        mutating func value(depth: Int) throws {
            guard depth <= 8 else { throw WriterFailure.integrity }; space()
            guard index < bytes.count else { throw WriterFailure.integrity }
            if take(123) {
                var keys = Set<String>(); if take(125) { return }
                repeat {
                    let key = try string()
                    guard keys.insert(key).inserted, take(58) else { throw WriterFailure.integrity }
                    try value(depth: depth + 1)
                    if take(125) { return }
                    guard take(44) else { throw WriterFailure.integrity }
                } while true
            }
            if take(91) {
                if take(93) { return }
                repeat { try value(depth: depth + 1); if take(93) { return }; guard take(44) else { throw WriterFailure.integrity } } while true
            }
            if bytes[index] == 34 { _ = try string(); return }
            let start = index
            while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw WriterFailure.integrity }
            _ = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed])
        }
    }
}
