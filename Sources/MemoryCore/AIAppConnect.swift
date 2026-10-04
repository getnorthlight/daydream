import Foundation
import CryptoKit

// Connect an AI app to DayDream in one step (Settings › Connections, or `mac-mem connect <app>`).
//
// Connecting writes one entry, named "daydream", into the AI app's own MCP settings file. The entry starts
// `mac-mem mcp` with a private access key that DayDream makes at that moment, so nobody copies a key by hand.
// Disconnecting removes that entry and turns the key off.
//
// Rules this file keeps (scripts/connect-config-checks.swift checks each one):
// - Only the "daydream" entry changes. Every other byte of the file is kept exactly: JSON and TOML are edited as
//   text (JSONConfigText, MCPConfigTOML), never printed again. The result is also parsed and compared value by
//   value with the original plus (or minus) the one entry before anything is written; a difference stops the write.
// - The file as it was just before DayDream's change is copied to "<file>.daydream-backup" (owner-only).
// - Connecting twice changes nothing the second time. Disconnecting something not connected changes nothing.
//   Disconnect is the exact inverse of Connect: the bytes DayDream added are the bytes it removes.
// - A linked file, a file owned by someone else, JSON with comments, or unsupported TOML is left alone, with a
//   plain reason and what to do. A review covers what it showed (the file being there, and DayDream's own entry);
//   if that changed, nothing is written. The app saving the rest of its file meanwhile (Claude Code rewrites
//   ~/.claude.json all the time) is expected: DayDream reads the file again and retries (claude/connect-fix-1003).
// - ChatGPT uses local MCP TOML, an intact managed block and exact byte/existence restoration on disconnect.
// - An entry DayDream didn't write (one added by hand) is never replaced or removed.
// - The write is atomic (a temporary file in the same folder, then a rename) and keeps the file's permissions.
// Nothing here reads history, sends anything, or starts an AI app.

/// One AI app DayDream knows how to connect.
public struct AIApp: Equatable, Identifiable, Sendable {
    public enum EntryStyle: Equatable, Sendable {
        /// `{"command", "args", "env"}`.
        case plain
        /// The same, plus `"type": "stdio"`.
        case typedStdio
        /// Comment-preserving local MCP TOML (ChatGPT desktop / Codex).
        case toml
    }
    /// Short, stable name used by `mac-mem connect <id>` and as the connection's client label.
    public let id: String
    /// The app's name as people know it.
    public let name: String
    /// The MCP settings file, relative to the person's home folder.
    public let configPath: String
    /// The JSON key or TOML table in that file that holds the servers.
    public let serversKey: String
    public let style: EntryStyle
    /// Paths (relative to the home folder) whose presence means the app is on this Mac.
    public let markers: [String]
    /// App bundles (looked for in /Applications and ~/Applications) that mean the app is on this Mac.
    public let bundles: [String]
    /// The app's bundle identifiers, read from its Info.plist. Only verified ones are listed: Settings finds the app
    /// (wherever it is installed) and sees whether it is running by these. Empty for an app without a Mac app bundle,
    /// or one whose identifier isn't verified yet (Settings then looks for `bundles` by name).
    public let bundleIDs: [String]
    /// The start of the app's documented link that opens a new chat with a prompt typed in (not sent); the prompt
    /// goes after it, percent-encoded. Nil when the app has no such link.
    public let newChatLinkPrefix: String?
    /// The app rewrites its settings file on its own, often (Claude Code's ~/.claude.json holds its history and caches).
    /// DayDream then waits out the app's own lock (`<file>.lock`, a folder Claude Code holds while it saves) and,
    /// after writing, checks a moment later that the entry is still there.
    public let rewritesOwnFile: Bool

    init(id: String, name: String, configPath: String, serversKey: String, style: EntryStyle, markers: [String], bundles: [String],
         bundleIDs: [String] = [], newChatLinkPrefix: String? = nil, rewritesOwnFile: Bool = false) {
        self.id = id; self.name = name; self.configPath = configPath; self.serversKey = serversKey; self.style = style
        self.markers = markers; self.bundles = bundles; self.bundleIDs = bundleIDs; self.newChatLinkPrefix = newChatLinkPrefix
        self.rewritesOwnFile = rewritesOwnFile
    }

    /// What the person does after connecting so the app picks the change up (the command-line tool says this).
    public var restartHint: String { "Quit and reopen \(name) to use DayDream there." }

    /// The longest new-chat link DayDream opens (fix/welcome-prompt). No app documents a limit; 2,000 characters is
    /// the conservative length links are kept under everywhere. A longer link is never opened: Settings copies the
    /// prompt instead, as for an app with no link.
    public static let newChatLinkMaxLength = 2000

    /// The link that opens a new chat in this app with `prompt` typed in but not sent, or nil when there is none
    /// (or it would be longer than `newChatLinkMaxLength`).
    /// Every character but letters, digits and `-._~` is percent-encoded, so the prompt can't add to the link.
    public func newChatLink(_ prompt: String) -> URL? {
        guard let newChatLinkPrefix else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = prompt.addingPercentEncoding(withAllowedCharacters: allowed),
              (newChatLinkPrefix + encoded).utf8.count <= Self.newChatLinkMaxLength else { return nil }
        return URL(string: newChatLinkPrefix + encoded)
    }
}

/// Why a connection needs the person's attention.
public enum AIAppAttention: Equatable, Sendable {
    /// A "daydream" entry someone added by hand. DayDream leaves it alone.
    case addedByHand
    /// DayDream's entry starts another copy of DayDream (moved, or an older copy).
    case otherCopy
    /// DayDream's entry has a key that no longer works (turned off, or the history was replaced).
    case keyStopped
    /// The settings file can't be read or changed safely; the text says why.
    case unreadable(String)

    /// Connect fixes it (and Disconnect is offered too).
    public var reconnects: Bool { self == .otherCopy || self == .keyStopped }
    public func reason(_ app: AIApp) -> String {
        switch self {
        case .addedByHand: return "\(app.name) has a DayDream entry that was added by hand. DayDream leaves it as it is."
        case .otherCopy: return "\(app.name) starts another copy of DayDream. Connect again to use this one."
        case .keyStopped: return "\(app.name)'s key no longer works. Connect again."
        case .unreadable(let text): return text
        }
    }
}

public enum AIAppConnectionState: Equatable, Sendable {
    /// The app isn't on this Mac.
    case notInstalled
    case notConnected
    case connected
    /// Something needs a fresh Connect, or a look.
    case needsAttention(AIAppAttention)

    public var label: String {
        switch self {
        case .notInstalled: return "Not on this Mac"
        case .notConnected: return "Not connected"
        case .connected: return "Connected"
        case .needsAttention: return "Needs attention"
        }
    }
}

public enum AIAppConnectAction: String, Codable, Sendable { case connect, disconnect }

public enum AIAppConnectError: Error, Equatable, CustomStringConvertible {
    case unknownApp(String)
    case notInstalled(String)
    case linkedFile(String)
    case notYours(String)
    case notAFile(String)
    case tooLarge(String)
    case notPlainJSON(String)
    case notEditableTOML(String)
    case unexpectedShape(String)
    case changedSinceReview
    case notOurs
    case unsafeCommand(String)
    case storeMissing
    case writeFailed(String)
    /// The edit didn't pass the value-by-value check. (file shown)
    case keptOtherSettingsCheckFailed(String)
    /// Another program kept rewriting the file while DayDream wrote. (app name, file shown)
    case keptChanging(String, String)

    public var description: String {
        switch self {
        case .unknownApp(let id): return "DayDream doesn't know an AI app called \"\(id)\". Known apps: \(AIAppConnect.apps.map(\.id).joined(separator: ", "))."
        case .notInstalled(let name): return "\(name) isn't on this Mac. Install it and open it once, then connect again."
        case .linkedFile(let path): return "\(path) is a link to another file. DayDream doesn't change linked files. Change it by hand, or replace the link with the file."
        case .notYours(let path): return "\(path) belongs to another user. DayDream left it alone."
        case .notAFile(let path): return "\(path) isn't a normal file. DayDream left it alone."
        case .tooLarge(let path): return "\(path) is too large to change safely. DayDream left it alone."
        case .notPlainJSON(let path): return "\(path) isn't plain JSON (it may have comments). DayDream left it alone. Fix the file, or add DayDream by hand."
        case .notEditableTOML(let path): return "\(path) uses TOML that DayDream cannot edit safely (a multi-line string, an [[array of tables]], or mcp_servers written inline or with dotted keys). Nothing was changed. Add DayDream by hand, or rewrite that part as ordinary [tables] first."
        case .unexpectedShape(let path): return "\(path) isn't laid out the way DayDream expects: its MCP servers aren't one set of named entries (or one is listed twice). DayDream left it alone. Fix that part of the file, or add DayDream by hand."
        case .changedSinceReview: return "The settings file changed after you reviewed it. Nothing was written. Review it again."
        case .notOurs: return "The \"daydream\" entry in this file was added by hand, so DayDream left it alone. To let DayDream manage it, remove that entry by hand first."
        case .unsafeCommand(let reason): return reason
        case .storeMissing: return "DayDream has no history folder yet. Open DayDream and finish setup first."
        case .writeFailed(let reason): return "The settings file wasn't changed: \(reason)"
        case .keptOtherSettingsCheckFailed(let path):
            return "DayDream checks that only its own entry changes, and its edit of \(path) didn't pass that check, so the file was left exactly as it was. Add DayDream by hand (the install guide's \"Connect an AI app by hand\"), and send a report from Help › Report a Problem so this gets fixed."
        case .keptChanging(let name, let path):
            return "\(name) kept rewriting \(path) while DayDream was adding its entry, so nothing was written. Connect again in a moment. If it keeps happening, quit \(name) first."
        }
    }
}

/// Where the settings files are looked for. The app and the CLI use `.live`; checks pass a scratch folder.
public struct AIAppConnectEnvironment: Sendable {
    public var userHome: URL
    public var applicationFolders: [URL]
    public init(userHome: URL, applicationFolders: [URL]? = nil) {
        self.userHome = userHome
        self.applicationFolders = applicationFolders ?? [URL(fileURLWithPath: "/Applications", isDirectory: true),
                                                         userHome.appendingPathComponent("Applications", isDirectory: true)]
    }
    public static var live: AIAppConnectEnvironment { AIAppConnectEnvironment(userHome: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) }
}

/// What a Connect or Disconnect will do, shown before anything is written.
public struct AIAppConnectPlan: Equatable, Sendable {
    public enum Outcome: String, Equatable, Sendable {
        /// Connect adds the entry.
        case add
        /// Connect replaces DayDream's own earlier entry (another copy of DayDream, or a key that stopped working).
        case replace
        /// Already connected the same way: nothing will be written.
        case alreadyConnected
        /// Disconnect removes DayDream's entry.
        case remove
        /// Disconnect: there is no entry. Only the access key is turned off.
        case nothingToRemove
    }
    public let app: AIApp
    public let action: AIAppConnectAction
    public let outcome: Outcome
    /// The settings file.
    public let file: URL
    /// Whether the file exists now.
    public let fileExists: Bool
    /// Where the copy of the current file goes (only when something is written and the file exists).
    public let backup: URL?
    /// The review's pin: SHA-256 of what the review showed (the file being there, DayDream's own entry), "absent"
    /// when there is no file. Apply refuses if that changed; the rest of the file may change meanwhile and is kept.
    public let reviewedSHA256: String
    /// The entry as it will be written, with the private key shown as a placeholder. Nil for a disconnect.
    public let entryPreview: String?
    /// Plain sentences for the review.
    public let notes: [String]

    public var writes: Bool { outcome == .add || outcome == .replace || outcome == .remove }
}

public struct AIAppConnectResult: Equatable, Sendable {
    public let plan: AIAppConnectPlan
    /// True when the settings file was changed.
    public let wrote: Bool
    /// The backup that was written, if any.
    public let backup: URL?
    public let message: String
}

public enum AIAppConnect {
    /// The entry's name in every app's settings file.
    public static let entryName = "daydream"
    /// The connection's recipient label in DayDream's store. The client label is the app's id.
    public static let recipient = "daydream-connect"
    /// Shown in place of the private key in every review.
    public static let keyPlaceholder = "<private key, made when you connect>"
    public static let backupSuffix = ".daydream-backup"
    static let maxBytes = 32 << 20

    public static let apps: [AIApp] = [
        // ChatGPT desktop (com.openai.codex) shares local MCP config with Codex CLI/IDE.
        // https://learn.chatgpt.com/docs/extend/mcp?surface=cli
        // No documented desktop new-chat prompt link: Connections uses its existing copied starter flow.
        AIApp(id: "chatgpt", name: "ChatGPT",
              configPath: ".codex/config.toml", serversKey: "mcp_servers", style: .toml,
              markers: [".codex"], bundles: ["ChatGPT.app", "Codex.app"], bundleIDs: ["com.openai.codex"]),
        // com.anthropic.claudefordesktop: Claude.app's Info.plist. The claude://claude.ai/new?q= link is documented by
        // Anthropic ("Open Claude Desktop with a link"): it opens a new chat with the text typed in, not sent.
        AIApp(id: "claude-desktop", name: "Claude Desktop",
              configPath: "Library/Application Support/Claude/claude_desktop_config.json", serversKey: "mcpServers", style: .plain,
              markers: ["Library/Application Support/Claude"], bundles: ["Claude.app"],
              bundleIDs: ["com.anthropic.claudefordesktop"], newChatLinkPrefix: "claude://claude.ai/new?q="),
        AIApp(id: "claude-code", name: "Claude Code",
              configPath: ".claude.json", serversKey: "mcpServers", style: .typedStdio,
              markers: [".claude.json", ".claude"], bundles: [], rewritesOwnFile: true),
        AIApp(id: "cursor", name: "Cursor",
              configPath: ".cursor/mcp.json", serversKey: "mcpServers", style: .plain,
              markers: [".cursor"], bundles: ["Cursor.app"], bundleIDs: ["com.todesktop.230313mzl4w4u92"]),
        AIApp(id: "windsurf", name: "Windsurf",
              configPath: ".codeium/windsurf/mcp_config.json", serversKey: "mcpServers", style: .plain,
              markers: [".codeium/windsurf"], bundles: ["Windsurf.app"]),
    ]

    public static func app(_ id: String) throws -> AIApp {
        guard let app = apps.first(where: { $0.id == id.lowercased() }) else { throw AIAppConnectError.unknownApp(id) }
        return app
    }

    public static func file(_ app: AIApp, _ env: AIAppConnectEnvironment) -> URL {
        env.userHome.appendingPathComponent(app.configPath, isDirectory: false)
    }
    public static func backupFile(_ app: AIApp, _ env: AIAppConnectEnvironment) -> URL {
        let url = file(app, env)
        return url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + backupSuffix, isDirectory: false)
    }

    public static func installed(_ app: AIApp, _ env: AIAppConnectEnvironment) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: file(app, env).path) { return true }
        if app.markers.contains(where: { fm.fileExists(atPath: env.userHome.appendingPathComponent($0).path) }) { return true }
        return env.applicationFolders.contains { folder in app.bundles.contains { fm.fileExists(atPath: folder.appendingPathComponent($0).path) } }
    }

    /// The command DayDream's own "daydream" entry starts, or nil when there is no such entry (read only).
    public static func entryCommand(_ app: AIApp, env: AIAppConnectEnvironment) -> String? {
        let url = file(app, env)
        guard let current = try? read(url, env, app: app), let entry = (try? servers(current.root, app, display(url, env)))?[entryName] as? [String: Any],
              isOurs(entry, app) else { return nil }
        return entry["command"] as? String
    }

    /// The path with the home folder shortened to "~", for people to read.
    public static func display(_ url: URL, _ env: AIAppConnectEnvironment) -> String {
        let home = env.userHome.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: The entry

    /// The arguments `mac-mem` gets. `home` is set only when DayDream's history isn't in the usual place.
    public static func arguments(_ app: AIApp, home: URL?) -> [String] {
        (home.map { ["--home", $0.path] } ?? []) + ["--client", app.id, "--recipient", recipient, "mcp"]
    }
    static func entry(_ app: AIApp, command: URL, home: URL?, key: String) -> [String: Any] {
        var value: [String: Any] = ["command": command.path, "args": arguments(app, home: home), "env": ["MAC_MEM_CAPABILITY": key]]
        if app.style == .typedStdio { value["type"] = "stdio" }
        return value
    }
    /// The entry as text, for the review. The key is always the placeholder.
    public static func preview(_ app: AIApp, command: URL, home: URL?) -> String {
        if app.style == .toml {
            return MCPConfigTOML.block(command: command.path, args: arguments(app, home: home), key: keyPlaceholder, absent: false, newline: false)
        }
        // The same text Connect writes into the file (in the file's own indentation there).
        let value = entryValue(app, command: command.path, args: arguments(app, home: home), key: keyPlaceholder)
        return String(decoding: JSONConfigText.fresh(servers: app.serversKey, name: entryName, value: value).dropLast(), as: UTF8.self)
    }

    /// Whether an existing "daydream" entry was written by Connect for this app (its client and recipient labels).
    static func isOurs(_ entry: [String: Any], _ app: AIApp) -> Bool {
        guard let args = entry["args"] as? [String] else { return false }
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        return value(after: "--client") == app.id && value(after: "--recipient") == recipient && args.last == "mcp"
    }
    static func key(in entry: [String: Any]) -> String? {
        guard let env = entry["env"] as? [String: Any], let key = env["MAC_MEM_CAPABILITY"] as? String, !key.isEmpty else { return nil }
        return key
    }
    /// The entry starts exactly this `mac-mem` with exactly these arguments (and the right type).
    static func matches(_ entry: [String: Any], _ app: AIApp, command: URL, home: URL?) -> Bool {
        guard entry["command"] as? String == command.path, entry["args"] as? [String] == arguments(app, home: home) else { return false }
        if app.style == .typedStdio && entry["type"] as? String != "stdio" { return false }
        return true
    }

    /// Why this `mac-mem` must not be written into an AI app's settings, or nil when it's fine.
    /// A copy on the mounted disk image (a read-only volume) or in a translocated folder goes away; AI apps
    /// would lose DayDream. `readOnlyVolume` is replaceable for checks.
    public static func commandProblem(_ command: URL, readOnlyVolume: (URL) -> Bool = AIAppConnect.onReadOnlyVolume) -> String? {
        let path = command.standardizedFileURL.path
        if !path.hasPrefix("/") { return "DayDream couldn't find its own command-line tool." }
        if path.contains("/AppTranslocation/") || readOnlyVolume(command) {
            return "DayDream is running from the download window. Move DayDream to Applications, open it from there, then connect again."
        }
        guard FileManager.default.isExecutableFile(atPath: path) else { return "DayDream's command-line tool is missing from this copy of the app." }
        return nil
    }
    public static func onReadOnlyVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }

    // MARK: Reading the file

    struct Current {
        let exists: Bool
        let data: Data
        let root: [String: Any]
        let mode: mode_t
        var sha256: String { exists ? AIAppConnect.sha256(data) : "absent" }
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Reads the settings file without following links. Absent is fine (an empty settings object).
    /// TOML lives in a single .codex folder; refuse linked folders as well as linked leaf files.
    static func checkTOMLFolder(_ url: URL, _ env: AIAppConnectEnvironment) throws {
        for folder in [env.userHome, url.deletingLastPathComponent()] {
            var info = stat()
            if lstat(folder.path, &info) != 0 {
                guard errno == ENOENT else { throw AIAppConnectError.notAFile(display(folder, env)) }
                continue
            }
            guard (info.st_mode & S_IFMT) != S_IFLNK else { throw AIAppConnectError.linkedFile(display(folder, env)) }
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw AIAppConnectError.notAFile(display(folder, env)) }
            guard info.st_uid == getuid() else { throw AIAppConnectError.notYours(display(folder, env)) }
        }
    }

    /// Reads the settings file without following links. Absent is fine (an empty settings object).
    /// For an app that rewrites its own file, a read that finds it empty or half-written is tried again a few
    /// times (about 0.1 s) before it counts: the app may be in the middle of saving it.
    static func read(_ url: URL, _ env: AIAppConnectEnvironment, app: AIApp) throws -> Current {
        guard app.rewritesOwnFile else { return try readOnce(url, env, app: app) }
        var attempt = 0
        while true {
            do {
                let current = try readOnce(url, env, app: app)
                if current.exists, isBlank(current.data), attempt < 4 { attempt += 1; usleep(30_000); continue }
                return current
            } catch AIAppConnectError.notPlainJSON(_) where attempt < 4 {
                attempt += 1; usleep(30_000)
            }
        }
    }
    static func readOnce(_ url: URL, _ env: AIAppConnectEnvironment, app: AIApp) throws -> Current {
        let shown = display(url, env)
        if app.style == .toml { try checkTOMLFolder(url, env) }
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw AIAppConnectError.notAFile(shown) }
            return Current(exists: false, data: Data(), root: [:], mode: 0o600)
        }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: throw AIAppConnectError.linkedFile(shown)
        case S_IFREG: break
        default: throw AIAppConnectError.notAFile(shown)
        }
        guard info.st_uid == getuid() else { throw AIAppConnectError.notYours(shown) }
        guard info.st_size <= maxBytes else { throw AIAppConnectError.tooLarge(shown) }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AIAppConnectError.notAFile(shown) }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 { throw AIAppConnectError.notAFile(shown) }
            if n == 0 { break }
            data.append(buffer, count: n)
            guard data.count <= maxBytes else { throw AIAppConnectError.tooLarge(shown) }
        }
        let mode = info.st_mode & 0o777
        if app.style == .toml {
            let toml = try MCPConfigTOML(data: data, shown: shown)
            return Current(exists: true, data: data, root: toml.root, mode: mode)
        }
        if data.allSatisfy({ [0x20, 0x0a, 0x0d, 0x09].contains($0) }) {
            return Current(exists: true, data: data, root: [:], mode: mode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any] else {
            throw AIAppConnectError.notPlainJSON(shown)
        }
        return Current(exists: true, data: data, root: root, mode: mode)
    }

    static func servers(_ root: [String: Any], _ app: AIApp, _ shown: String) throws -> [String: Any]? {
        guard let value = root[app.serversKey] else { return nil }
        guard let servers = value as? [String: Any] else { throw AIAppConnectError.unexpectedShape(shown) }
        return servers
    }

    // MARK: Status

    /// What Settings shows for one app. `verify` answers whether a key still opens DayDream (nil: couldn't tell).
    public static func status(_ app: AIApp, env: AIAppConnectEnvironment, command: URL?, home: URL?,
                              verify: (String) -> Bool?) -> AIAppConnectionState {
        let url = file(app, env)
        let current: Current
        do { current = try read(url, env, app: app) }
        catch { return installed(app, env) ? .needsAttention(.unreadable((error as? AIAppConnectError)?.description ?? "Its settings file can't be read.")) : .notInstalled }
        guard current.exists || installed(app, env) else { return .notInstalled }
        let servers: [String: Any]?
        do { servers = try self.servers(current.root, app, display(url, env)) }
        catch { return .needsAttention(.unreadable((error as? AIAppConnectError)?.description ?? "Its settings file can't be read.")) }
        guard let value = servers?[entryName] else { return .notConnected }
        if app.style == .toml, (try? MCPConfigTOML(data: current.data, shown: display(url, env)).managedRange) == nil { return .needsAttention(.addedByHand) }
        guard let entry = value as? [String: Any], isOurs(entry, app) else { return .needsAttention(.addedByHand) }
        if let command, !matches(entry, app, command: command, home: home) { return .needsAttention(.otherCopy) }
        guard let key = key(in: entry), verify(key) != false else { return .needsAttention(.keyStopped) }
        return .connected
    }

    // MARK: Review

    public static func plan(_ action: AIAppConnectAction, _ app: AIApp, env: AIAppConnectEnvironment, command: URL, home: URL?,
                            verify: (String) -> Bool?) throws -> AIAppConnectPlan {
        let url = file(app, env), shown = display(url, env)
        if action == .connect, let problem = commandProblem(command) { throw AIAppConnectError.unsafeCommand(problem) }
        let current = try read(url, env, app: app)
        guard current.exists || installed(app, env) else { throw AIAppConnectError.notInstalled(app.name) }
        let existing = try servers(current.root, app, shown)?[entryName]
        if app.style == .toml, existing != nil, try MCPConfigTOML(data: current.data, shown: shown).managedRange == nil { throw AIAppConnectError.notOurs }
        let backup = display(backupFile(app, env), env)
        var notes: [String] = []
        let outcome: AIAppConnectPlan.Outcome
        switch action {
        case .connect:
            if let entry = existing as? [String: Any], isOurs(entry, app), matches(entry, app, command: command, home: home),
               let key = key(in: entry), verify(key) == true {
                outcome = .alreadyConnected
                notes.append("\(app.name) is already connected. Nothing will change.")
            } else {
                if let entry = existing {
                    guard let entry = entry as? [String: Any], isOurs(entry, app) else { throw AIAppConnectError.notOurs }
                }
                outcome = existing == nil ? .add : .replace
                notes.append(existing == nil
                             ? "DayDream adds one entry, \"\(entryName)\", to \(shown)."
                             : "DayDream replaces its earlier \"\(entryName)\" entry in \(shown).")
                notes.append("Nothing else in the file changes.")
                notes.append(current.exists ? "A copy of the file as it is now is saved to \(backup)." : "The file doesn't exist yet, so DayDream creates it.")
                notes.append("The private key is made when you connect. \(app.name) keeps it in this file; you never copy it.")
                notes.append("\(app.name) can then read your DayDream history. It can't change or delete anything. What it reads may be sent to its own online service.")
                // claude/summary-1003 (owner decision 2026-10-03): the connect review names the typed-words setting.
                notes.append("While \"\(AIReadsTypedSetting.title)\" is on in Settings › Connections, it can also read the words you typed and sent.")
            }
        case .disconnect:
            if let entry = existing as? [String: Any] {
                guard isOurs(entry, app) else { throw AIAppConnectError.notOurs }
                outcome = .remove
                notes.append("DayDream removes its \"\(entryName)\" entry from \(shown) and turns its key off.")
                notes.append("Nothing else in the file changes. A copy of the file as it is now is saved to \(backup).")
            } else if existing != nil {
                throw AIAppConnectError.unexpectedShape(shown)
            } else {
                outcome = .nothingToRemove
                notes.append("\(app.name) has no DayDream entry. DayDream only makes sure its key is off.")
            }
        }
        let writes = outcome == .add || outcome == .replace || outcome == .remove
        return AIAppConnectPlan(app: app, action: action, outcome: outcome, file: url, fileExists: current.exists,
                                backup: writes && current.exists ? backupFile(app, env) : nil, reviewedSHA256: try reviewBasis(current, app, shown),
                                entryPreview: action == .connect ? preview(app, command: command, home: home) : nil, notes: notes)
    }

    // MARK: Apply

    /// How many times Connect or Disconnect reads the file again and retries when another program saved it meanwhile.
    static let writeAttempts = 8
    /// How long after writing DayDream looks again at a file its app rewrites on its own (microseconds).
    static let settleDelay: useconds_t = 250_000

    /// What a review covers: the file being there, and DayDream's own entry as it was ("absent": no file). The rest of
    /// the file isn't part of it: it is kept byte for byte whatever it holds, so an app saving its own settings
    /// between the review and the write (Claude Code does, all the time) doesn't make the review wrong.
    static func reviewBasis(_ current: Current, _ app: AIApp, _ shown: String) throws -> String {
        guard current.exists else { return "absent" }
        var basis = "daydream-review-v2\u{1f}" + app.id + "\u{1f}"
        if let entry = try servers(current.root, app, shown)?[entryName] {
            basis += canonical(entry)
            if app.style == .toml {
                let editor = try MCPConfigTOML(data: current.data, shown: shown)
                basis += "\u{1f}" + (editor.managedRange.map { String(editor.text[$0]) } ?? "by-hand")
            }
        } else {
            basis += "none"
        }
        return sha256(Data(basis.utf8))
    }
    static func canonical(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }
    /// The review pin (`AIAppConnectPlan.reviewedSHA256`) of the file as it is now; nil when it can't be read.
    public static func reviewedSHA256(_ app: AIApp, env: AIAppConnectEnvironment) -> String? {
        let url = file(app, env)
        guard let current = try? read(url, env, app: app) else { return nil }
        return try? reviewBasis(current, app, display(url, env))
    }

    /// Connects `app`. `grant` makes (or replaces) the access key in DayDream's store; `revoke` turns it off
    /// again if the file can't be written. `expectedSHA256` is the review's pin (nil: no review).
    public static func connect(_ app: AIApp, env: AIAppConnectEnvironment, command: URL, home: URL?, expectedSHA256: String?,
                               verify: (String) -> Bool?, grant: () throws -> String, revoke: () throws -> Void) throws -> AIAppConnectResult {
        let reviewed = try plan(.connect, app, env: env, command: command, home: home, verify: verify)
        if let expectedSHA256, expectedSHA256 != reviewed.reviewedSHA256 { throw AIAppConnectError.changedSinceReview }
        if reviewed.outcome == .alreadyConnected {
            return AIAppConnectResult(plan: reviewed, wrote: false, backup: nil, message: "\(app.name) is already connected. Nothing changed.")
        }
        let url = reviewed.file, shown = display(url, env)
        // Refuse a file DayDream can't edit before a key is made (the placeholder stands in for the key).
        _ = try connectedEdit(try read(url, env, app: app), app, command: command, home: home, key: keyPlaceholder, shown: shown)
        let key = try grant()
        do {
            let target = entry(app, command: command, home: home, key: key)
            let done: (Current) -> Bool = { current in
                guard let found = (try? servers(current.root, app, shown))?[entryName] as? [String: Any],
                      NSDictionary(dictionary: found).isEqual(to: target) else { return false }
                return app.style != .toml || (try? MCPConfigTOML(data: current.data, shown: shown))?.managedRange != nil
            }
            let outcome = try apply(app, env: env, url: url, reviewed: reviewed.reviewedSHA256, done: done) { current in
                try connectedEdit(current, app, command: command, home: home, key: key, shown: shown)
            }
            return AIAppConnectResult(plan: reviewed, wrote: outcome.wrote, backup: outcome.backup,
                                      message: "\(app.name) is connected. \(app.restartHint)")
        } catch {
            try? revoke()
            throw error
        }
    }

    /// Disconnects `app`: removes DayDream's entry (never someone else's) and turns the key off.
    public static func disconnect(_ app: AIApp, env: AIAppConnectEnvironment, command: URL, home: URL?, expectedSHA256: String?,
                                  revoke: () throws -> Void) throws -> AIAppConnectResult {
        let reviewed = try plan(.disconnect, app, env: env, command: command, home: home, verify: { _ in nil })
        if let expectedSHA256, expectedSHA256 != reviewed.reviewedSHA256 { throw AIAppConnectError.changedSinceReview }
        guard reviewed.outcome == .remove else {
            try revoke()
            return AIAppConnectResult(plan: reviewed, wrote: false, backup: nil, message: "\(app.name) wasn't connected. Nothing changed in its settings.")
        }
        let url = reviewed.file, shown = display(url, env)
        // Refuse a file DayDream can't edit before access is turned off.
        _ = try disconnectedEdit(try read(url, env, app: app), app, env: env, shown: shown)
        // Stop access before hiding the connection. A failed revocation keeps its settings entry visible;
        // a failed settings write leaves the old entry in place with its access already turned off.
        try revoke()
        let outcome = try apply(app, env: env, url: url, reviewed: reviewed.reviewedSHA256,
                                done: { current in
            do { return try servers(current.root, app, shown)?[entryName] == nil } catch { return false }
        }) { current in
            try disconnectedEdit(current, app, env: env, shown: shown)
        }
        return AIAppConnectResult(plan: reviewed, wrote: outcome.wrote, backup: outcome.backup,
                                  message: "\(app.name) is disconnected. Quit and reopen \(app.name) to finish.")
    }

    /// One change to the settings file.
    enum Edit: Equatable { case write(Data), remove }
    /// Another program saved the file while DayDream wrote it (internal: the attempt is repeated).
    enum Race: Error { case beforeRename, afterRename(URL?) }

    /// Reads the file, edits it and writes it, again (up to `writeAttempts` times) whenever another program saved it
    /// in between. `done` says the file already is as wanted (another attempt's write survived). Refuses with
    /// `changedSinceReview` only when what the review showed changed: the file appearing or going, or DayDream's
    /// own entry.
    static func apply(_ app: AIApp, env: AIAppConnectEnvironment, url: URL, reviewed: String, done: (Current) -> Bool,
                      edit: (Current) throws -> Edit) throws -> (wrote: Bool, backup: URL?) {
        let shown = display(url, env)
        var wrote = false, backup: URL?
        for attempt in 0..<writeAttempts {
            if attempt > 0 { usleep(useconds_t(20_000 * attempt)) }
            waitForAppLock(app, url)
            let current = try read(url, env, app: app)
            if done(current) { return (wrote, backup) }
            guard try reviewBasis(current, app, shown) == reviewed else { throw AIAppConnectError.changedSinceReview }
            let change = try edit(current)
            do {
                backup = try write(change, to: url, current: current, app: app, env: env)
                wrote = true
            } catch Race.beforeRename {
                continue
            } catch Race.afterRename(let saved) {
                wrote = true; backup = saved
                continue
            }
            guard app.rewritesOwnFile else { return (true, backup) }
            // The app may have read the file just before DayDream's write and save its copy just after it.
            usleep(settleDelay)
            if let now = try? read(url, env, app: app), done(now) { return (true, backup) }
        }
        throw AIAppConnectError.keptChanging(app.name, shown)
    }

    /// Claude Code holds `<file>.lock` (a folder) while it saves ~/.claude.json. DayDream waits for it to go, at most
    /// about two seconds, and never makes, changes or removes it. A lock untouched for 10 s is stale.
    static func waitForAppLock(_ app: AIApp, _ url: URL) {
        guard app.rewritesOwnFile else { return }
        let lock = url.path + ".lock"
        for _ in 0..<80 {
            var info = stat()
            guard lstat(lock, &info) == 0 else { return }
            if Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) > 10 { return }
            usleep(25_000)
        }
    }

    // MARK: The edits

    /// DayDream's entry as text, in the order it is written (`claude mcp add` writes the same order).
    static func entryValue(_ app: AIApp, command: String, args: [String], key: String) -> JSONConfigText.Value {
        var members: [(String, JSONConfigText.Value)] = []
        if app.style == .typedStdio { members.append(("type", .string("stdio"))) }
        members += [("command", .string(command)), ("args", .array(args.map { .string($0) })),
                    ("env", .object([("MAC_MEM_CAPABILITY", .string(key))]))]
        return .object(members)
    }
    /// The entry found in a file, as DayDream writes it; nil when it has anything DayDream doesn't write.
    static func entryValue(found entry: [String: Any], _ app: AIApp) -> JSONConfigText.Value? {
        guard isOurs(entry, app), let command = entry["command"] as? String, let args = entry["args"] as? [String],
              let env = entry["env"] as? [String: Any], env.count == 1, let key = key(in: entry),
              Set(entry.keys) == Set(app.style == .typedStdio ? ["type", "command", "args", "env"] : ["command", "args", "env"]),
              app.style != .typedStdio || entry["type"] as? String == "stdio" else { return nil }
        return entryValue(app, command: command, args: args, key: key)
    }

    static func document(_ data: Data, _ shown: String) throws -> JSONConfigText {
        do { return try JSONConfigText(data: data) }
        catch JSONConfigText.Failure.syntax { throw AIAppConnectError.notPlainJSON(shown) }
        catch { throw AIAppConnectError.unexpectedShape(shown) }
    }
    static func isBlank(_ data: Data) -> Bool { data.allSatisfy(JSONConfigText.isSpace) }

    /// The file with DayDream's entry set: only the entry's own bytes change (or a new file is made).
    static func connectedEdit(_ current: Current, _ app: AIApp, command: URL, home: URL?, key: String, shown: String) throws -> Edit {
        if app.style == .toml {
            let editor = try MCPConfigTOML(data: current.data, shown: shown)
            // `mcp_servers` made by a dotted key or an inline table can't take a `[mcp_servers.daydream]` table.
            guard !editor.serversClosed else { throw AIAppConnectError.notEditableTOML(shown) }
            let data = editor.settingEntry(command: command.path, args: arguments(app, home: home), key: key, fileExists: current.exists)
            let updated = try MCPConfigTOML(data: data, shown: shown)
            guard updated.removingEntry() == editor.removingEntry() else { throw AIAppConnectError.keptOtherSettingsCheckFailed(shown) }
            return .write(data)
        }
        let value = entryValue(app, command: command.path, args: arguments(app, home: home), key: key)
        let data: Data
        if !current.exists || isBlank(current.data) {
            data = JSONConfigText.fresh(servers: app.serversKey, name: entryName, value: value)
        } else {
            do { data = try document(current.data, shown).setting(servers: app.serversKey, name: entryName, value: value) }
            catch let error as AIAppConnectError { throw error }
            catch { throw AIAppConnectError.unexpectedShape(shown) }
        }
        try keepsEverythingElse(original: current.root, updated: data, app: app, entry: entry(app, command: command, home: home, key: key),
                                droppedServers: false, shown: shown)
        return .write(data)
    }

    /// The file with DayDream's entry removed: the exact inverse of `connectedEdit`. The servers object goes too
    /// when DayDream added it (its backup, the file before DayDream's last change, had none), and a file DayDream
    /// made from nothing goes back to nothing (or to the blank file it was).
    static func disconnectedEdit(_ current: Current, _ app: AIApp, env: AIAppConnectEnvironment, shown: String) throws -> Edit {
        if app.style == .toml {
            let editor = try MCPConfigTOML(data: current.data, shown: shown)
            let data = editor.removingEntry()
            _ = try MCPConfigTOML(data: data, shown: shown)
            return editor.originallyAbsent && data.isEmpty ? .remove : .write(data)
        }
        let hint = backupHint(app, env)
        if let found = (try servers(current.root, app, shown))?[entryName] as? [String: Any], let value = entryValue(found: found, app),
           current.data == JSONConfigText.fresh(servers: app.serversKey, name: entryName, value: value) {
            switch hint {
            case .none: return .remove
            case .blank(let data): return .write(data)
            default: break
            }
        }
        let dropServers: Bool
        switch hint { case .none, .blank: dropServers = true; case .servers(let had): dropServers = !had; case .unknown: dropServers = false }
        let removed: (data: Data, droppedServers: Bool)?
        do { removed = try document(current.data, shown).removingEntry(servers: app.serversKey, name: entryName, dropEmptyServers: dropServers) }
        catch let error as AIAppConnectError { throw error }
        catch { throw AIAppConnectError.unexpectedShape(shown) }
        guard let removed else { return .write(current.data) }
        try keepsEverythingElse(original: current.root, updated: removed.data, app: app, entry: nil, droppedServers: removed.droppedServers, shown: shown)
        return .write(removed.data)
    }

    /// What DayDream's backup (the file just before its last change) says about the servers object: `.servers(false)`
    /// when DayDream added it. (After a reconnect the backup holds DayDream's earlier entry, so an empty servers
    /// object DayDream added then stays as `{}`: the same settings, one empty object more.)
    enum BackupHint { case none, blank(Data), servers(Bool), unknown }
    static func backupHint(_ app: AIApp, _ env: AIAppConnectEnvironment) -> BackupHint {
        let url = backupFile(app, env)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT ? .none : .unknown }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_size <= maxBytes,
              let data = try? Data(contentsOf: url) else { return .unknown }
        if isBlank(data) { return .blank(data) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unknown }
        return .servers(root[app.serversKey] != nil)
    }

    /// Parses the new text back and compares it, value by value, with the original plus (or minus) DayDream's entry.
    static func keepsEverythingElse(original: [String: Any], updated: Data, app: AIApp, entry: [String: Any]?, droppedServers: Bool,
                                    shown: String) throws {
        guard let reparsed = (try? JSONSerialization.jsonObject(with: updated)) as? [String: Any] else {
            throw AIAppConnectError.keptOtherSettingsCheckFailed(shown)
        }
        var expected = original
        if droppedServers {
            guard let servers = original[app.serversKey] as? [String: Any], servers.count == 1, servers[entryName] != nil else {
                throw AIAppConnectError.keptOtherSettingsCheckFailed(shown)
            }
            expected.removeValue(forKey: app.serversKey)
        } else {
            var servers = original[app.serversKey] as? [String: Any] ?? [:]
            if let entry { servers[entryName] = entry } else { servers.removeValue(forKey: entryName) }
            expected[app.serversKey] = servers
        }
        guard NSDictionary(dictionary: expected).isEqual(to: reparsed) else { throw AIAppConnectError.keptOtherSettingsCheckFailed(shown) }
    }

    /// Backs up the current file (when there is one), then replaces it atomically. Returns the backup.
    static func write(_ change: Edit, to url: URL, current: Current, app: AIApp, env: AIAppConnectEnvironment) throws -> URL? {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if !fm.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            do { try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw AIAppConnectError.writeFailed("its folder couldn't be made.") }
        } else if !isDirectory.boolValue {
            throw AIAppConnectError.notAFile(display(folder, env))
        }
        var backup: URL?
        if current.exists {
            let target = backupFile(app, env)
            var info = stat()
            if lstat(target.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFREG else { throw AIAppConnectError.notAFile(display(target, env)) }
                guard info.st_uid == getuid() else { throw AIAppConnectError.notYours(display(target, env)) }
            }
            try atomicWrite(current.data, to: target, mode: 0o600, env: env)
            backup = target
        }
        // The last moment to notice another program's change before the rename: read again and retry.
        guard try read(url, env, app: app).sha256 == current.sha256 else { throw Race.beforeRename }
        switch change {
        case .remove:
            guard unlink(url.path) == 0 else { throw AIAppConnectError.writeFailed("the created settings file couldn't be removed.") }
        case .write(let data):
            try atomicWrite(data, to: url, mode: current.exists ? current.mode : 0o600, env: env)
            guard let written = try? read(url, env, app: app) else { throw AIAppConnectError.writeFailed("it couldn't be read back.") }
            // Saved over again just after the rename: the next attempt sees whether DayDream's change survived.
            guard written.data == data else { throw Race.afterRename(backup) }
        }
        return backup
    }

    static func atomicWrite(_ data: Data, to url: URL, mode: mode_t, env: AIAppConnectEnvironment) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).daydream-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw AIAppConnectError.writeFailed("a temporary file couldn't be made next to \(display(url, env)).") }
        var ok = fchmod(fd, mode) == 0
        if ok {
            ok = data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
        }
        ok = ok && fsync(fd) == 0
        close(fd)
        guard ok, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw AIAppConnectError.writeFailed("\(display(url, env)) couldn't be written.")
        }
    }
}

extension MemoryStore {
    /// Makes (or replaces) the access key of a Connect connection. Same scopes as `grant`.
    public func connectGrant(_ app: AIApp) throws -> String {
        try grant(client: app.id, recipient: AIAppConnect.recipient, scopes: ["context", "search", "detail"])
    }
    /// Turns a Connect connection's key off. Unlike `revoke`, summaries are kept: removing an AI app must not
    /// throw away (and pay again for) the person's summaries. Prepared snapshots are still invalidated.
    public func connectRevoke(_ app: AIApp) throws {
        try transaction {
            try exec("DELETE FROM grants WHERE id=?", [app.id + "\u{1f}" + AIAppConnect.recipient])
            try invalidateDisclosure()
        }
    }
    /// Whether `key` still opens this store for `app` (a read; no write).
    public func connectKeyWorks(_ app: AIApp, key: String) -> Bool {
        (try? authorize(client: app.id, recipient: AIAppConnect.recipient, capability: key, scope: "context")) != nil
    }
}
