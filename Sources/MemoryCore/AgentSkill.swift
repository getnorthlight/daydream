import Foundation
import CryptoKit

/// claude/rel-017c: DayDream's Agent Skill (skills/daydream) for ChatGPT. ChatGPT (com.openai.codex) reads skills from
/// ~/.codex/skills, next to the ~/.codex/config.toml Connect writes, and without the skill it rarely knows when to use
/// DayDream. Connect writes it, Disconnect removes it, and a DayDream with a newer skill refreshes it at launch while
/// ChatGPT stays connected. A folder DayDream didn't write, or one the person edited after DayDream wrote it, is left
/// exactly as it is. A record of what DayDream wrote (each file's SHA-256) sits beside the files.
public enum AgentSkill {
    public enum Outcome: String, Equatable, Sendable {
        /// Written now.
        case installed
        /// An older copy DayDream wrote was replaced.
        case updated
        /// Already the copy this DayDream has.
        case current
        /// The folder isn't DayDream's, or the person changed it: left alone.
        case keptTheirs
        /// DayDream's copy was removed.
        case removed
        /// Nothing to do: no ChatGPT settings folder, or no skill folder.
        case absent
    }

    static let recordName = ".daydream-skill.json"

    public static func folder(_ env: AIAppConnectEnvironment) -> URL {
        env.userHome.appendingPathComponent(".codex/skills/daydream", isDirectory: true)
    }

    /// Each shipped file's SHA-256, by its path inside the folder.
    static var shipped: [String: String] {
        Dictionary(uniqueKeysWithValues: AgentSkillFiles.files.map { ($0.path, sha256(Data($0.text.utf8))) })
    }

    /// Writes the skill, or refreshes DayDream's older copy. Needs ChatGPT's settings folder (~/.codex) to exist.
    @discardableResult
    public static func install(_ env: AIAppConnectEnvironment) throws -> Outcome {
        let codex = env.userHome.appendingPathComponent(".codex", isDirectory: true)
        guard isFolder(codex) else { return .absent }
        let skills = codex.appendingPathComponent("skills", isDirectory: true)
        let dir = folder(env)
        if exists(skills) && !isFolder(skills) { return .keptTheirs }
        if exists(dir) {
            guard let recorded = ours(dir) else { return .keptTheirs }
            if recorded == shipped { return .current }
            try write(dir)
            return .updated
        }
        try write(dir)
        return .installed
    }

    /// Removes DayDream's copy: only the files DayDream wrote, and the folders once they're empty.
    @discardableResult
    public static func remove(_ env: AIAppConnectEnvironment) throws -> Outcome {
        let dir = folder(env)
        guard exists(dir) else { return .absent }
        guard let recorded = ours(dir) else { return .keptTheirs }
        let fm = FileManager.default
        for path in recorded.keys { try fm.removeItem(at: dir.appendingPathComponent(path)) }
        try fm.removeItem(at: dir.appendingPathComponent(recordName))
        for sub in Set(recorded.keys.compactMap { $0.contains("/") ? String($0.split(separator: "/")[0]) : nil }) {
            let url = dir.appendingPathComponent(sub, isDirectory: true)
            if (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true { try fm.removeItem(at: url) }
        }
        if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try fm.removeItem(at: dir) }
        return .removed
    }

    /// At launch: refreshes the skill when ChatGPT has DayDream's entry. Never throws, never writes otherwise.
    @discardableResult
    public static func refresh(_ env: AIAppConnectEnvironment) -> Outcome {
        guard let app = try? AIAppConnect.app("chatgpt"), AIAppConnect.entryCommand(app, env: env) != nil else { return .absent }
        return (try? install(env)) ?? .keptTheirs
    }

    /// What DayDream recorded writing, when every recorded file is still exactly as written (and nothing is a link);
    /// nil for a folder that isn't DayDream's or that the person changed.
    static func ours(_ dir: URL) -> [String: String]? {
        guard isFolder(dir) else { return nil }
        let record = dir.appendingPathComponent(recordName)
        guard isFile(record), let data = try? Data(contentsOf: record),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = root["files"] as? [String: String], !files.isEmpty else { return nil }
        for (path, hash) in files {
            let parts = path.split(separator: "/").map(String.init)
            guard !path.hasPrefix("/"), !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
            var parent = dir
            for part in parts.dropLast() {
                parent = parent.appendingPathComponent(part, isDirectory: true)
                guard isFolder(parent) else { return nil }
            }
            let url = dir.appendingPathComponent(path)
            guard isFile(url), let bytes = try? Data(contentsOf: url), sha256(bytes) == hash else { return nil }
        }
        return files
    }

    static func write(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        // Files from an older skill that this one dropped (all DayDream's: `ours` checked them).
        if let old = ours(dir) {
            for path in old.keys where shipped[path] == nil { try? fm.removeItem(at: dir.appendingPathComponent(path)) }
        }
        for file in AgentSkillFiles.files {
            let url = dir.appendingPathComponent(file.path)
            let parent = url.deletingLastPathComponent()
            if exists(parent) && !isFolder(parent) { throw CocoaError(.fileWriteFileExists) }
            try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            if exists(url) && !isFile(url) { throw CocoaError(.fileWriteFileExists) }
            try Data(file.text.utf8).write(to: url, options: .atomic)
        }
        let record = try JSONSerialization.data(withJSONObject: ["files": shipped, "by": "DayDream"], options: [.sortedKeys, .prettyPrinted])
        try record.write(to: dir.appendingPathComponent(recordName), options: .atomic)
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// lstat: links count as neither files nor folders, so DayDream never writes through one.
    static func kind(_ url: URL) -> mode_t? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & S_IFMT : nil
    }
    static func exists(_ url: URL) -> Bool { kind(url) != nil }
    static func isFolder(_ url: URL) -> Bool { kind(url) == S_IFDIR }
    static func isFile(_ url: URL) -> Bool { kind(url) == S_IFREG }
}
