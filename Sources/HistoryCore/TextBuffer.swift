// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// Portions of this file are derived from open-codex-computer-history
// (https://github.com/hqhq1025/open-codex-computer-history),
// Copyright (c) 2026 Open Codex Computer History contributors, used under the
// MIT License. The full MIT notice is in THIRD-PARTY-NOTICES.md.

import Foundation

/// Coalesces a run of keystrokes into a single typing burst, and — critically —
/// is the one place that decides whether a character is allowed to become text.
///
/// The secure-field guarantee lives here, at capture time: when `secureInput` is
/// true (or the user disabled text capture) the characters are never appended to
/// `text`, they simply do not enter memory as text. `hadInput` still flips true
/// so a metadata-only burst ("typing happened here") remains observable.
public struct TextBuffer: Equatable, Sendable {
    private(set) public var text: String = ""
    /// Whether any keystroke landed in this burst, regardless of capture.
    private(set) public var hadInput: Bool = false

    public init() {}

    public var isEmpty: Bool { !hadInput }

    /// Append one keystroke's characters. `secureInput` and `captureText` gate
    /// whether the characters are retained; either falsy path keeps only the
    /// fact that a keystroke occurred.
    public mutating func append(characters: String, secureInput: Bool, captureText: Bool) {
        guard !characters.isEmpty else { return }
        hadInput = true
        guard captureText, !secureInput else { return }
        text.append(characters)
    }

    /// Empty the buffer and return what should be emitted: the coalesced text
    /// (nil when nothing was retained) and whether a burst occurred at all.
    public mutating func drain() -> (text: String?, hadInput: Bool) {
        let result = (text.isEmpty ? nil : text, hadInput)
        text = ""
        hadInput = false
        return result
    }
}
