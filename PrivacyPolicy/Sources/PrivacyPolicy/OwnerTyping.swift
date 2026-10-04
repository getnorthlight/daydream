import Foundation

/// The owner build switch (typing-all SPEC-LATER §3). One compile flag,
/// `DAYDREAM_OWNER_TYPING`, passed only by `scripts/package.sh` when
/// `DAYDREAM_OWNER_TYPING=1` is in its environment, together with the
/// private Chrome typing flag (`Sources/MemoryCore/OwnerTypingGuard.swift`
/// makes the owner flag alone a compile error).
///
/// In the owner build `TypingRelease.open` is true: expanded typing (table
/// rows beyond Notes and TextEdit that pass their proof) and website typing.
/// It never opens `alwaysBlocked`, private windows, secure input, rows with
/// an unconfirmed signer, or terminals before `TerminalPromptLatch.wired`.
///
/// Every release stage defines it (developer-id-release.py OWNER_SWIFT_FLAGS, owner
/// decision 2026-09-25): the public DMG and the owner copy type the same. Only an
/// unflagged local build leaves it out; there `enabled` is false and the legal gate
/// (`TypingRelease.expandedApproved`) alone decides.
public enum OwnerTyping {
#if DAYDREAM_OWNER_TYPING
    public static let enabled = true
    /// Field words refused in an app's web content (`CaptureGate.sensitiveField`): a terminal or code
    /// editor there (ChatGPT's xterm.js terminal, a Monaco editor) is an ordinary editable text area, and
    /// the terminal prompt latch covers native terminals only. The Chrome join refuses these words too,
    /// but judges "editor content" in labels only (Draft.js names every editor `public-DraftEditor-content`);
    /// here it is judged in the class list as well, which is stricter.
    static let webTerminalWords = ["xterm", "terminal", "inputarea", "monaco", "editor content"]
#else
    public static let enabled = false
    /// Builds without the switch read no app web content (`CaptureGate.webContentApps` is empty).
    static let webTerminalWords: [String] = []
#endif
}
