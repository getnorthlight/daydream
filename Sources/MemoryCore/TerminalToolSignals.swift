import Foundation
import PrivacyPolicy

/// claude/cc-label-1003 (owner, 10/03 2:24–2:35 PM, a Claude Code session in a Ghostty tab): every prompt read "Ran a
/// command". Claude Code names itself in the tab title only by a status glyph ("✳ <topic>" waiting, "◐ / ◑ <topic>" or a
/// braille frame working), the glyph is dropped at capture (title-spinner-1003), and a prompt typed while the title was
/// a bare spinner or plain named no tool at all. These are the signals that say a terminal line went to an AI tool:
/// - `TerminalToolMemory`: a window title that ever showed the tool's own glyph or name keeps that tool while its
///   cleaned title stays the same (capture process only, metadata only).
/// - `PromptShape`: natural-language text sent with Return is very unlikely to be a shell command.
/// The writer keeps the same prompt rule (`CanonicalGrounding.promptShaped`; summary-terminal holds the two to one list).

/// Whether typed terminal text reads as a request in words, not a command: several words that are nearly all plain
/// words, two sentences or one long one (or a question), no shell operators, and at most one path or flag. Code only;
/// the words are never stored or shown by this.
public enum PromptShape {
    /// Programs a command line starts with. A line starting with one is a command unless it is clearly sentences.
    public static let commandWords: Set<String> = [
        "git", "ls", "cd", "pwd", "npm", "npx", "yarn", "pnpm", "bun", "node", "deno", "swift", "swiftc", "xcodebuild", "xcrun", "python",
        "python3", "pip", "pip3", "uv", "make", "cmake", "brew", "cargo", "go", "rustc", "docker", "kubectl", "ssh", "scp", "rsync", "cat",
        "echo", "rm", "mv", "cp", "mkdir", "rmdir", "touch", "vim", "nvim", "vi", "nano", "emacs", "code", "open", "curl", "wget", "grep", "rg",
        "find", "fd", "sed", "awk", "sudo", "export", "source", "gh", "tail", "head", "less", "more", "man", "ps", "kill", "killall", "top",
        "htop", "chmod", "chown", "ln", "tar", "zip", "unzip", "bash", "zsh", "sh", "fish", "exit", "clear", "history", "which", "env", "jq",
        "claude", "codex", "gemini", "aider", "tmux", "screen", "defaults", "launchctl", "diskutil", "codesign", "security", "plutil",
    ]
    static let operators: Set<String> = ["|", "||", "&&", ";", ">", ">>", "<", "<<", "2>&1", "&", "$(", "`"]

    public static func natural(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 4 else { return false }
        var shellish = 0, wordish = 0
        for t in tokens {
            if operators.contains(t) || t.hasPrefix("$") || t.contains("`") { return false }
            let flag = t.count > 1 && t.hasPrefix("-") && !t.hasPrefix("--") || (t.hasPrefix("--") && t.count > 2)
            let path = t.contains("/") || t.hasPrefix("~") || t.hasPrefix("./") || t.contains("\\")
            let assign = t.contains("=") && !t.hasPrefix("=")
            if flag || path || assign { shellish += 1 }
            if t.range(of: #"^["'“‘(]*\p{L}[\p{L}\p{N}'’-]*[.,!?:;)"'”’…]*$"#, options: .regularExpression) != nil { wordish += 1 }
        }
        guard shellish <= (tokens.count >= 8 ? 1 : 0), Double(wordish) >= 0.7 * Double(tokens.count) else { return false }
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?")).filter {
            $0.split(whereSeparator: \.isWhitespace).count >= 2
        }.count
        let first = (tokens[0] as NSString).lastPathComponent.lowercased()
        if commandWords.contains(first), sentences < 2, tokens.count < 8 { return false }
        return sentences >= 2 || tokens.count >= 8 || text.hasSuffix("?")
    }
}

/// The AI tool a terminal window runs, remembered from its titles (capture process only; nothing here is stored except
/// as `Evidence.titleTool` on the rows capture writes). A raw title that names the tool or shows its glyph ("✳ <topic>",
/// a braille frame, "harborline — claude") marks that window's cleaned title as the tool's; while the cleaned title
/// stays the same (a spinner frame, or the plain title), the tool stays. A different cleaned title (a shell prompt, a
/// renamed session) has to show its own glyph or name again. Entries last `lifetime` after the last title naming the tool.
public final class TerminalToolMemory: @unchecked Sendable {
    public static let shared = TerminalToolMemory()
    public static let lifetime: TimeInterval = 6 * 3600
    static let capacity = 64
    private let lock = NSLock()
    private var tools: [String: (tool: String, at: Date)] = [:]
    public init() {}

    /// Terminal bundles whose titles a shell or a tool sets (`SendRules.terminal`).
    public static func applies(bundle: String) -> Bool { SendRules.terminal(bundle: bundle) }

    static func key(bundle: String, title: String) -> String? {
        let clean = TitleClean.statusless(title).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return clean.isEmpty ? nil : bundle + "\u{1F}" + clean
    }

    /// What a title says on its own: the tool it names or whose glyph it shows; "" for a busy spinner that names no
    /// tool ("◐ <topic>"); nil for anything else.
    public static func titleTool(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tool = TitleClean.terminalTool(t) { return tool }
        if let g = t.unicodeScalars.first, TitleClean.spinnerGlyphs.contains(g.value), TitleClean.statusless(t) != t { return "" }
        return nil
    }

    /// Records `title` (raw, with its glyph) of a terminal window and returns the tool that window runs: its own title's
    /// tool, else the one this cleaned title was last seen with, else "" for a bare spinner, else nil.
    @discardableResult public func observe(bundle: String, title: String, now: Date = Date()) -> String? {
        guard Self.applies(bundle: bundle), let key = Self.key(bundle: bundle, title: title) else { return nil }
        let own = Self.titleTool(title)
        lock.lock(); defer { lock.unlock() }
        if let own, !own.isEmpty {
            tools[key] = (own, now)
            if tools.count > Self.capacity, let oldest = tools.min(by: { $0.value.at < $1.value.at })?.key { tools[oldest] = nil }
            return own
        }
        if let kept = tools[key] {
            if now.timeIntervalSince(kept.at) <= Self.lifetime { return kept.tool }
            tools[key] = nil
        }
        return own
    }

    /// For checks: forget everything.
    public func reset() { lock.lock(); tools = [:]; lock.unlock() }
}
