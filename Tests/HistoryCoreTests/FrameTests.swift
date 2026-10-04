// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// Portions of this file are derived from open-codex-computer-history
// (https://github.com/hqhq1025/open-codex-computer-history),
// Copyright (c) 2026 Open Codex Computer History contributors, used under the
// MIT License. The full MIT notice is in THIRD-PARTY-NOTICES.md.

import Testing
import Foundation
@testable import HistoryCore

@Suite struct FrameTests {
    @Test func encodeProducesLittleEndianLengthPrefix() {
        let framed = Frame.encode(Data([0xAA, 0xBB, 0xCC]))
        #expect(Array(framed.prefix(4)) == [3, 0, 0, 0])
        #expect(Array(framed.suffix(3)) == [0xAA, 0xBB, 0xCC])
    }

    @Test func parserRoundTripsSingleFrame() throws {
        var parser = Frame.Parser()
        let payload = Data("hello".utf8)
        #expect(try parser.push(Frame.encode(payload)) == [payload])
    }

    @Test func parserHandlesMultipleFramesInOneChunk() throws {
        var parser = Frame.Parser()
        var chunk = Data()
        chunk.append(Frame.encode(Data("one".utf8)))
        chunk.append(Frame.encode(Data("two".utf8)))
        let out = try parser.push(chunk)
        #expect(out.map { String(decoding: $0, as: UTF8.self) } == ["one", "two"])
    }

    @Test func parserReassemblesFragmentedFrame() throws {
        var parser = Frame.Parser()
        let framed = Frame.encode(Data("fragmented".utf8))
        #expect(try parser.push(framed.prefix(3)) == [])              // only part of the length
        #expect(try parser.push(framed.dropFirst(3).prefix(4)) == []) // partial body
        let out = try parser.push(framed.dropFirst(7))                // remainder
        #expect(out.map { String(decoding: $0, as: UTF8.self) } == ["fragmented"])
    }

    @Test func parserRejectsOversizeFrame() {
        var parser = Frame.Parser()
        var header = Data()
        var big = UInt32(Frame.maxFrameBytes + 1).littleEndian
        withUnsafeBytes(of: &big) { header.append(contentsOf: $0) }
        #expect(throws: (any Error).self) { try parser.push(header) }
    }
}
