// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// Portions of this file are derived from open-codex-computer-history
// (https://github.com/hqhq1025/open-codex-computer-history),
// Copyright (c) 2026 Open Codex Computer History contributors, used under the
// MIT License. The full MIT notice is in THIRD-PARTY-NOTICES.md.

import Foundation

/// Length-prefixed message framing: a 4-byte little-endian unsigned length,
/// then that many bytes of UTF-8 JSON.
public enum Frame {
    /// Hard cap on a single frame (8 MiB). Guards a reader against a bogus
    /// length triggering a huge allocation.
    public static let maxFrameBytes = 8 * 1024 * 1024

    public enum FrameError: Error, Equatable {
        case frameTooLarge(Int)
    }

    /// Wrap a JSON payload as `[len:LE32][payload]`.
    public static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        var out = Data(capacity: 4 + payload.count)
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Incremental parser. Feed it whatever bytes arrive from `read()`; it yields
    /// zero or more complete payloads and retains any partial tail for next time.
    /// A value type, so each reader keeps its own partial-frame buffer.
    public struct Parser {
        private var buffer = Data()

        public init() {}

        public mutating func push(_ bytes: Data) throws -> [Data] {
            buffer.append(bytes)
            var payloads: [Data] = []
            while true {
                guard buffer.count >= 4 else { break }
                // Read the 4-byte little-endian length (index-safe against a sliced Data).
                let base = buffer.startIndex
                let len = Int(buffer[base])
                    | Int(buffer[base + 1]) << 8
                    | Int(buffer[base + 2]) << 16
                    | Int(buffer[base + 3]) << 24
                guard len <= maxFrameBytes else { throw FrameError.frameTooLarge(len) }
                guard buffer.count >= 4 + len else { break }
                let start = base + 4
                let payload = buffer.subdata(in: start ..< start + len)
                payloads.append(payload)
                buffer.removeSubrange(base ..< start + len)
            }
            return payloads
        }
    }
}
