import Foundation

/// Safe typing C, terminals: keys typed at a password prompt are dropped
/// before they become a typed unit. Pure state for one focus. Wired:
/// `TypingSession` (owned by the capture binding, under its lock) feeds every
/// key of an app that needs the latch through it in `admit`, before any
/// character is read, with the window title from the key's proof
/// (`FocusProof.place`), every unit that ends without Return (`split`,
/// `unseen`), and every Return with the text it submits.
///
/// - The line: what the shell runs is the whole line since the last Return,
///   not one typed unit. The latch keeps the text capture saw typed into it
///   across idle and size splits, and remembers when the line changed in a
///   way capture can't see (history recall, a caret jump, paste, undo, a key
///   it couldn't read, and Tab completion unless the command word is already
///   typed, complete and not privileged).
/// - Arms on `submit` (Return) when the line is a privileged command (`sudo`,
///   `ssh`, `passwd`, `docker login`, ...), or when the line was changed in a
///   way capture can't see (fail closed: the next line may be a password).
///   A line that was only interrupted (focus left the terminal, or a click,
///   and came back: `interrupted`) arms only when it could still be a
///   privileged command: a word of any piece typed between interruptions,
///   or two pieces joined in another order, is one (owner live test
///   2026-10-02: every Cmd-Tab and click used to drop the next line, and the
///   tab with it). While armed every
///   key is dropped, including the next Return, which disarms it. Control-C
///   (`interrupt`, fed by `TypingSession.eraseLine` since 2026-10-02) ends
///   the prompt too. If neither comes, keys are dropped until the focus
///   changes. Control-U (`cleared`) never ends an arm.
/// - Arms while the window title shows such a process ("sudo", "ssh"): every
///   key is dropped until a title without one is seen or the focus changes.
/// - Remote sessions: once `ssh` (or `sshpass`, `telnet`) is seen as the
///   submitted command or in the window title, nothing more is recorded in
///   that focus until the focus changes (another tab, window or field). A
///   remote shell can set its own title, so a title without `ssh` doesn't end
///   it. After a Return that ran a line capture couldn't fully see (a
///   recalled `ssh`), a title change counts as a remote session only when the
///   new title shows a sensitive process (above) or a `user@host` the old
///   title didn't: a title change alone (a new directory, the command's own
///   name) no longer keeps the tab dropped (owner live test 2026-10-02). The
///   command arm still drops the next line and ends with its Return.
///
/// The command rule is the same as `TypedSecretScrubber`'s in MemoryCore
/// (a check compares the lists and a table of lines). Descriptions never
/// contain text. Honest misses: `read -s` in scripts, prompts that echo,
/// and custom prompts; the store-side scrubber still runs on what is kept.
public struct TerminalPromptLatch: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public enum Arm: String, Sendable { case command, title }
    public enum Key: Equatable, Sendable, CustomStringConvertible {
        /// Any key that edits the line.
        case text
        /// Return. `line`: the rebuilt text of the unit it ends (nil when there is none).
        case submit(line: String?)
        /// Control-C: the prompt ends without a submitted line.
        case interrupt
        /// Control-U: the line before the caret is erased. Only a line capture
        /// saw completely (caret at its end) is then empty.
        case cleared
        /// A unit in this focus ended without Return; the shell line goes on.
        /// `typed`: the unit's text. `completion`: it ended with Tab, and the
        /// shell may have inserted text capture can't see.
        case split(typed: String, completion: Bool)
        /// The line changed in a way capture can't see (history recall, a caret
        /// jump, paste, undo, a key it couldn't read). `typed`: the text of the
        /// unit that ended with it.
        case unseen(typed: String)
        /// Capture stopped watching this focus (another app or window, a
        /// click) and the shell line goes on; no key it missed reached the
        /// line, but the caret may have moved. `typed`: the unit's text.
        case interrupted(typed: String)
        public var description: String {
            switch self {
            case .text: return "text"
            case .submit(let l): return l == nil ? "submit(unknown)" : "submit(redacted)"
            case .interrupt: return "interrupt"
            case .cleared: return "cleared"
            case .split(_, let completion): return completion ? "split(completion, redacted)" : "split(redacted)"
            case .unseen: return "unseen(redacted)"
            case .interrupted: return "interrupted(redacted)"
            }
        }
    }
    public enum Decision: String, Sendable { case record, drop }
    /// True only once capture feeds every key of a Code-category app through
    /// the latch. Until then `TypingCategories.releaseAllows` refuses every
    /// app that needs it (terminals and editors with a built-in terminal),
    /// whatever the release gate says: at a real prompt the password is a
    /// separate unit that only the latch can drop. Wired in typing-all W0:
    /// `TypingSession.admit` (every insert and edit, before the read),
    /// `commitLive`/`seal` on Return, and the title from each key's proof.
    /// `scripts/typing-release-gate-checks.py` and the PrivacyPolicy checks
    /// fail if this is true while the session does not drop the keys.
    public static let wired = true

    public private(set) var arm: Arm?
    public private(set) var focusID: String?
    /// A remote session (`ssh`) was seen in this focus: nothing is recorded
    /// until the focus changes.
    public private(set) var remote = false
    /// The text capture saw typed into the line since the last Return, before
    /// the current unit. Never described or mirrored.
    private var seen = ""
    /// Something was typed into the line since the last Return.
    private var touched = false
    /// The line changed in a way capture couldn't see since the last Return.
    private var unseenChange = false
    /// The text typed between interruptions since the last Return, in typing
    /// order (`seen` split where capture stopped watching). Never described.
    private var pieces: [String] = [""]
    /// Capture stopped watching this line at least once since the last Return.
    private var interrupted = false
    /// The last window title read in this focus, and the title at a Return
    /// that ran an unseen line (compared once, at the next title read).
    private var lastTitle: String?
    private var titleAtUnseenReturn: String?
    public init() {}
    /// Keys in this focus are dropped now (a prompt arm or a remote session).
    public var armed: Bool { arm != nil || remote }
    public var description: String { "TerminalPromptLatch(\(arm?.rawValue ?? (remote ? "remote" : "idle")))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// Focus moved (another window or field). Every arm and the line end.
    public mutating func focusChanged(to focusID: String?) {
        if focusID != self.focusID {
            arm = nil; remote = false; resetLine(); lastTitle = nil; titleAtUnseenReturn = nil; self.focusID = focusID
        }
    }
    /// The window title was read for this focus.
    public mutating func titleObserved(_ title: String, focusID: String) {
        focusChanged(to: focusID)
        if let before = titleAtUnseenReturn {
            titleAtUnseenReturn = nil
            // Only a title that shows a remote host it didn't show before;
            // a sensitive process is handled just below.
            if before != title && !Self.newRemoteHosts(title, before: before).isEmpty { remote = true }
        }
        lastTitle = title
        if let process = Self.titleProcess(title) {
            arm = .title
            if Self.remoteCommands.contains(process) { remote = true }
        } else if arm == .title { arm = nil }
    }
    /// One key in this focus: record it or drop it.
    public mutating func key(_ key: Key, focusID: String) -> Decision {
        focusChanged(to: focusID)
        if remote || arm != nil {
            // The prompt's Return (or an interrupt) ends a command arm; a title
            // arm and a remote session go on.
            switch key {
            case .submit, .interrupt: if arm == .command { arm = nil }; resetLine()
            case .text, .split, .unseen, .interrupted, .cleared: break
            }
            return .drop
        }
        switch key {
        case .text:
            touched = true
        case .interrupt:
            resetLine()
        case .cleared:
            // A click (`interrupted`) or an unseen change may have moved the
            // caret: the rest of the line stays unknown.
            if !unseenChange && !interrupted { resetLine() }
        case .split(let typed, let completion):
            append(typed)
            if completion && !Self.completionKeepsCommand(seen) { unseenChange = true }
        case .unseen(let typed):
            append(typed)
            touched = true; unseenChange = true
        case .interrupted(let typed):
            append(typed)
            if !(pieces.last ?? "").isEmpty { pieces.append("") }
            interrupted = true
        case .submit(let line):
            append(line ?? "")
            if Self.isPrivilegedCommandLine(seen) || line.map(Self.isPrivilegedCommandLine) == true {
                arm = .command
                if Self.isRemoteCommandLine(seen) || line.map(Self.isRemoteCommandLine) == true { remote = true }
            } else if (unseenChange && touched) || (interrupted && Self.piecesCouldBePrivileged(pieces)) {
                // Fail closed: the shell ran a line capture couldn't fully see.
                // The next line is dropped; a title change by then means it
                // is still running (a recalled ssh) and ends recording here.
                arm = .command
                titleAtUnseenReturn = lastTitle
            }
            resetLine()
        }
        return .record
    }
    private mutating func append(_ typed: String) {
        guard !typed.isEmpty else { return }
        touched = true
        // A newline inside a unit starts a new shell line.
        if let last = typed.lastIndex(of: "\n") {
            seen = String(typed[typed.index(after: last)...]); pieces = [seen]
        } else {
            seen += typed; pieces[pieces.count - 1] += typed
        }
        if seen.count > 4096 { seen = String(seen.suffix(4096)); pieces = [seen] }
    }
    private mutating func resetLine() { seen = ""; touched = false; unseenChange = false; pieces = [""]; interrupted = false }

    /// An interrupted line could still run a privileged command: one piece is
    /// one, or a word of a piece is a privileged command (or the first word of
    /// a privileged phrase), or two pieces joined in either order make one,
    /// as when the caret was moved by a click and the pieces were typed out of
    /// order. A word split across a click inside it is an honest miss.
    public static func piecesCouldBePrivileged(_ pieces: [String]) -> Bool {
        let parts = pieces.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return false }
        let heads = Set(privilegedCommands).union(privilegedPhrases.map { $0[0] })
        func risky(_ word: Substring) -> Bool {
            let w = word.drop(while: { !$0.isLetter && !$0.isNumber && $0 != "/" })
            return heads.contains(commandName(w).lowercased())
        }
        for p in parts {
            if isPrivilegedCommandLine(p) || plain(p).split(separator: " ").contains(where: risky) { return true }
        }
        for a in parts.indices { for b in parts.indices where a != b {
            if isPrivilegedCommandLine(parts[a] + parts[b]) { return true }
            // The last word of one piece and the first word of another, joined.
            let x = plain(parts[a]), y = plain(parts[b])
            guard parts[a].last.map({ !$0.isWhitespace }) == true, parts[b].first.map({ !$0.isWhitespace }) == true,
                  let tail = x.split(separator: " ").last, let head = y.split(separator: " ").first else { continue }
            if risky(Substring(tail + head)) { return true }
        } }
        return false
    }
    /// `user@host` hosts in `title` that `before` doesn't show (lowercased).
    static func newRemoteHosts(_ title: String, before: String) -> Set<String> {
        func hosts(_ t: String) -> Set<String> {
            let ns = t as NSString
            return Set(remoteHostRegex.matches(in: t, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)).lowercased() })
        }
        return hosts(title).subtracting(hosts(before))
    }
    static let remoteHostRegex = try! NSRegularExpression(pattern: #"[A-Za-z0-9_.-]+@([A-Za-z0-9][A-Za-z0-9.-]*)"#)

    // MARK: - The command rule (kept identical to TypedSecretScrubber)

    public static let privilegedCommands = ["sudo", "su", "doas", "ssh", "scp", "sftp", "sshpass", "passwd", "login", "security", "gpg", "ssh-add", "kinit", "mysql", "mysqldump", "mysqladmin", "mariadb", "psql", "pinentry", "redis-cli", "mongosh", "htpasswd", "ftp", "telnet"]
    public static let privilegedPhrases = [["docker", "login"], ["podman", "login"], ["npm", "login"], ["npm", "adduser"], ["gh", "auth", "login"], ["op", "signin"], ["vault", "login"], ["security", "unlock-keychain"]]
    static let proseAmbiguous: Set<String> = ["su", "login", "security"]
    static let securitySubcommands: Set<String> = ["unlock-keychain", "find-generic-password", "find-internet-password", "add-generic-password", "add-internet-password", "delete-generic-password", "delete-internet-password", "dump-keychain", "create-keychain", "set-keychain-password", "import", "export"]
    static let wrappers: Set<String> = ["$", "%", ">", "env", "time", "nohup", "exec", "command", "builtin", "noglob", "caffeinate"]
    static let trustedBinDirs = ["/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/", "/usr/local/bin/", "/opt/homebrew/bin/"]
    /// A title process that is only the login shell wrapper is not a prompt.
    static let titleIgnored: Set<String> = ["login", "su", "security"]

    static func isAssignmentWord(_ w: Substring) -> Bool {
        w.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil
    }
    static func commandName(_ w: Substring) -> String {
        if w.contains("/") {
            guard let dir = trustedBinDirs.first(where: { w.hasPrefix($0) }) else { return "" }
            return String(w.dropFirst(dir.count))
        }
        return String(w)
    }
    static func privilegedCommand(_ words: [Substring], chained: Bool = false) -> (start: Int, length: Int)? {
        var i = 0, afterEnv = false
        while i < words.count {
            let w = words[i]
            if wrappers.contains(String(w)) { afterEnv = afterEnv || w == "env"; i += 1; continue }
            if isAssignmentWord(w) || (afterEnv && w.hasPrefix("-")) { i += 1; continue }
            break
        }
        guard i < words.count else { return nil }
        let name = commandName(words[i]), lower = name.lowercased()
        guard !name.isEmpty else { return nil }
        for phrase in privilegedPhrases where phrase[0] == lower && words.count >= i + phrase.count {
            if zip(phrase.dropFirst(), words[(i + 1)...]).allSatisfy({ $0.0 == $0.1.lowercased() }) { return (i, phrase.count) }
        }
        guard privilegedCommands.contains(lower) else { return nil }
        if proseAmbiguous.contains(lower) {
            guard name == lower else { return nil }
            let rest = words[(i + 1)...]
            if lower == "security" {
                guard let sub = rest.first, securitySubcommands.contains(String(sub)) else { return nil }
            } else if chained {
                guard rest.isEmpty || rest.first!.hasPrefix("-") else { return nil }
            } else {
                guard rest.count <= 2, rest.allSatisfy({ $0.hasPrefix("-") || $0.range(of: "^[a-z_][a-z0-9_.@-]*$", options: .regularExpression) != nil }) else { return nil }
            }
        }
        return (i, 1)
    }
    static let separatorRegex = try! NSRegularExpression(pattern: #"\s*(&&|\|\||;|\|)\s*"#)
    static func segments(_ line: String) -> [[Substring]] {
        let ns = line as NSString
        var out: [[Substring]] = [], start = 0
        for m in separatorRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)).split(separator: " "))
            start = m.range.location + m.range.length
        }
        out.append(ns.substring(from: start).split(separator: " "))
        return out
    }
    /// Whitespace made plain and single, as the scrubber's normalising does.
    static func plain(_ line: String) -> String {
        let s = line.precomposedStringWithCompatibilityMapping
        let scalars = s.unicodeScalars.filter { ![0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x00AD].contains($0.value) }
            .map { $0.properties.isWhitespace ? " " : Character($0) }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }
    /// True when any shell segment of the line starts with a privileged command.
    public static func isPrivilegedCommandLine(_ line: String) -> Bool {
        segments(plain(line)).enumerated().contains { privilegedCommand($0.element, chained: $0.offset > 0) != nil }
    }
    /// Commands that open a remote session.
    public static let remoteCommands: Set<String> = ["ssh", "sshpass", "telnet"]
    /// True when any shell segment of the line runs a remote session command.
    public static func isRemoteCommandLine(_ line: String) -> Bool {
        segments(plain(line)).enumerated().contains { i, words in
            guard let hit = privilegedCommand(words, chained: i > 0) else { return false }
            return remoteCommands.contains(commandName(words[hit.start]).lowercased())
        }
    }
    /// Tab completion is safe to ignore only when, in the last shell segment
    /// of what was typed before it, the command word is already typed and
    /// complete (a later word is being completed) and cannot become
    /// privileged: not a privileged command, not the first word of a
    /// privileged phrase, not a wrapper. Anything else (completing the command
    /// word itself, `docker lo<Tab>`) makes the line unknown.
    public static func completionKeepsCommand(_ before: String) -> Bool {
        let ns = before as NSString
        let last = separatorRegex.matches(in: before, range: NSRange(location: 0, length: ns.length)).last
        let segment = last.map { ns.substring(from: $0.range.location + $0.range.length) } ?? before
        let text = plain(segment)
        let open = !(segment.last?.isWhitespace ?? false)
        let words = text.split(separator: " ")
        var i = 0, afterEnv = false
        while i < words.count {
            let w = words[i]
            if wrappers.contains(String(w)) { afterEnv = afterEnv || w == "env"; i += 1; continue }
            if isAssignmentWord(w) || (afterEnv && w.hasPrefix("-")) { i += 1; continue }
            break
        }
        // The command word must be followed by more text (or a space).
        guard i < words.count, i < words.count - 1 || !open else { return false }
        let name = commandName(words[i]).lowercased()
        guard !name.isEmpty, !privilegedCommands.contains(name), !privilegedPhrases.contains(where: { $0[0] == name }) else { return false }
        return true
    }

    /// The privileged process a terminal title shows, or nil. Titles are
    /// split at " — ", " - ", ":", "|", "(" and ")"; each part's first word
    /// is compared (after leading symbols), so "user — sudo apt update — 80×24"
    /// and "ssh me@host" arm. A directory like "~/src/security" does not.
    /// The per-terminal title format is UNCONFIRMED on a device.
    public static func titleProcess(_ title: String) -> String? {
        let parts = plain(title).components(separatedBy: CharacterSet(charactersIn: "—–|():")).flatMap { $0.components(separatedBy: " - ") }
        for part in parts {
            let words = part.split(separator: " ").map { $0.drop(while: { !$0.isLetter && !$0.isNumber && $0 != "/" && $0 != "-" }) }
            guard let first = words.first(where: { !$0.isEmpty }) else { continue }
            let w = first.hasPrefix("-") ? first.dropFirst() : first   // "-zsh" style login shells
            let name = commandName(w).lowercased()
            guard !name.isEmpty, !titleIgnored.contains(name) else { continue }
            if privilegedCommands.contains(name) || privilegedPhrases.contains(where: { $0[0] == name && words.count > 1 && $0[1] == words[1].lowercased() }) { return name }
        }
        return nil
    }
}
