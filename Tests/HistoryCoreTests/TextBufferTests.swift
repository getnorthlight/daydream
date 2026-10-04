// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// Portions of this file are derived from open-codex-computer-history
// (https://github.com/hqhq1025/open-codex-computer-history),
// Copyright (c) 2026 Open Codex Computer History contributors, used under the
// MIT License. The full MIT notice is in THIRD-PARTY-NOTICES.md.

import Testing
@testable import HistoryCore

/// The secure-field guarantee, at its source: characters typed into a secure
/// element must never become retained text, though the fact of typing survives.
@Suite struct TextBufferTests {
    @Test func normalTypingIsRetained() {
        var buffer = TextBuffer()
        buffer.append(characters: "he", secureInput: false, captureText: true)
        buffer.append(characters: "llo", secureInput: false, captureText: true)
        let (text, hadInput) = buffer.drain()
        #expect(text == "hello")
        #expect(hadInput)
    }

    @Test func secureInputNeverRetainsCharactersButRecordsTheBurst() {
        var buffer = TextBuffer()
        buffer.append(characters: "hunter2", secureInput: true, captureText: true)
        let (text, hadInput) = buffer.drain()
        #expect(text == nil, "secure characters must never be retained as text")
        #expect(hadInput, "the metadata-only fact of typing should still be observable")
    }

    @Test func captureDisabledDropsCharactersButKeepsTheBurst() {
        var buffer = TextBuffer()
        buffer.append(characters: "secret note", secureInput: false, captureText: false)
        let (text, hadInput) = buffer.drain()
        #expect(text == nil)
        #expect(hadInput)
    }

    @Test func drainResetsState() {
        var buffer = TextBuffer()
        buffer.append(characters: "x", secureInput: false, captureText: true)
        _ = buffer.drain()
        #expect(buffer.isEmpty)
        let (text, hadInput) = buffer.drain()
        #expect(text == nil)
        #expect(!hadInput)
    }
}
