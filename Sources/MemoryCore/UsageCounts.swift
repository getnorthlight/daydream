import Foundation

/// Anonymous usage counts (Settings › Advanced › "Share anonymous usage counts"): the vocabulary shared by the DayDream app
/// (which sends, `UsageSender` in MacMemApp) and `mac-mem mcp` (which never sends; it only appends `ai_used` lines to
/// `UsageInbox`). Counts and settings only: every event name, property key and text value is one of the fixed words
/// below, never a title, a typed word, a site, a search, a path, a name or anything else from the person's history.
/// Nothing in this file touches the network.
public enum UsageCounts {
    public static let events: Set<String> = ["installed", "setup_step", "daily_check", "summaries_result", "ai_used", "app_opened", "app_search"]
    /// Added to every event by the sender.
    public static let commonKeys: Set<String> = ["$geoip_disable", "$ip", "$lib", "app_version"]
    /// summaries_result's counts: `<mode>_<outcome>`, plus `problem` (the summaries state's problem, if any).
    public static let summaryModes = ["local", "openrouter"]
    public static let summaryOutcomes = ["ok", "fallback", "failed_key", "failed_credits", "failed_offline", "failed_host", "failed_other"]
    public static let summaryKeys: Set<String> = Set(summaryModes.flatMap { mode in summaryOutcomes.map { "\(mode)_\($0)" } })
    /// The only property keys each event may carry (besides `commonKeys`).
    public static let keys: [String: Set<String>] = [
        "installed": ["macos_version", "chip"],
        "setup_step": ["step", "summaries", "ai_app"],
        "daily_check": ["recording", "accessibility_ok", "input_monitoring_ok", "hours_recorded_bucket", "summaries", "connected_ai_apps", "chrome_pages"],
        "summaries_result": summaryKeys.union(["problem"]),
        "ai_used": ["ai_app", "tool", "result_count", "empty", "latency_ms"],
        "app_opened": ["how"],
        "app_search": ["result_count"],
    ]
    /// The only text values a property may hold (keys missing here hold numbers or booleans only).
    public static let words: [String: Set<String>] = [
        "chip": ["apple_silicon", "intel"],
        "step": ["accessibility_allowed", "input_monitoring_allowed", "summaries_chosen", "ai_connected", "setup_done"],
        "summaries": ["local", "openrouter", "off"],
        "ai_app": Set(aiApps),
        "connected_ai_apps": Set(aiApps),
        "recording": ["on", "paused", "off"],
        "hours_recorded_bucket": ["0", "lt1", "1_3", "3_6", "6plus"],
        "tool": Set(tools),
        "how": ["menu_bar", "dock", "link", "other"],
        "problem": ["none", "key", "credits", "offline", "host", "other"],
        // macOS's own version number ("15.6.1"), checked by shape in `allowed`.
        "macos_version": [],
    ]
    public static let aiApps = ["claude", "claude_code", "cursor", "chatgpt", "windsurf", "other"]
    /// DayDream's MCP tool names (`current-context` is sent as current_context; v2's timeline and details are listed too).
    public static let tools = ["status", "context", "current_context", "search", "read", "open", "recall", "recap", "moment_details", "timeline", "details", "other"]

    /// The AI app an MCP call came from: the client name the AI app sent at initialize, else the connection's own id
    /// (`--client`, written by Settings › Connections). Anything else is "other"; the name itself is never kept.
    public static func aiApp(clientName: String?, connection: String?) -> String {
        if let connection, let id = ["claude-desktop": "claude", "claude-code": "claude_code", "cursor": "cursor", "chatgpt": "chatgpt", "windsurf": "windsurf"][connection.lowercased()] { return id }
        let name = (clientName ?? "").lowercased()
        if name.contains("claude-code") || name.contains("claude code") || name.contains("claude_code") { return "claude_code" }
        if name.contains("claude") { return "claude" }
        if name.contains("cursor") { return "cursor" }
        if name.contains("windsurf") || name.contains("codeium") { return "windsurf" }
        if name.contains("chatgpt") || name.contains("openai") || name.contains("codex") { return "chatgpt" }
        return "other"
    }
    public static func tool(_ name: String) -> String {
        let id = name.replacingOccurrences(of: "-", with: "_")
        return tools.contains(id) ? id : "other"
    }
    /// Recorded time for a day, in buckets: 0, under an hour, 1–3, 3–6, 6 or more hours.
    public static func hoursBucket(seconds: Int) -> String {
        switch seconds {
        case ..<1: return "0"
        case ..<3600: return "lt1"
        case ..<(3 * 3600): return "1_3"
        case ..<(6 * 3600): return "3_6"
        default: return "6plus"
        }
    }
    /// The event is one of ours and every property is an allowed key holding an allowed value.
    public static func allowed(_ event: UsageEvent) -> Bool {
        guard let permitted = keys[event.name] else { return false }
        for (key, value) in event.properties {
            guard permitted.contains(key) else { return false }
            switch value {
            case .bool: continue
            case .int(let n): guard n >= 0 else { return false }
            case .text(let text):
                if key == "macos_version" { guard text.range(of: #"^\d{1,3}(\.\d{1,3}){0,2}$"#, options: .regularExpression) != nil else { return false }; continue }
                guard words[key]?.contains(text) == true else { return false }
            case .list(let list): guard let ok = words[key], list.allSatisfy(ok.contains) else { return false }
            }
        }
        return true
    }
}

/// One property value: only numbers, booleans and the fixed words in `UsageCounts.words`.
public enum UsageValue: Codable, Equatable, Sendable {
    case bool(Bool), int(Int), text(String), list([String])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(String.self) { self = .text(v) }
        else { self = .list(try c.decode([String].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .text(let v): try c.encode(v)
        case .list(let v): try c.encode(v)
        }
    }
    public var json: Any {
        switch self { case .bool(let v): return v; case .int(let v): return v; case .text(let v): return v; case .list(let v): return v }
    }
}

public struct UsageEvent: Codable, Equatable, Sendable {
    public var name: String
    /// ISO 8601, UTC.
    public var at: String
    public var properties: [String: UsageValue]
    public init(_ name: String, at: Date = Date(), _ properties: [String: UsageValue] = [:]) {
        self.name = name; self.at = UsageEvent.stamp(at); self.properties = properties
    }
    public static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

/// `mac-mem mcp`'s hand-off to the app: a small append-only file in DayDream's folder (`<home>/usage-inbox.jsonl`),
/// one `ai_used` line per tool call. The app makes the file while sharing is on and deletes it when sharing is turned
/// off, so the helper never creates it: no file, no line. The app reads and empties it, keeping only lines that pass
/// `UsageCounts.allowed`. Capped at `maxBytes`, after which lines are dropped until the app reads it.
public enum UsageInbox {
    public static let fileName = "usage-inbox.jsonl"
    public static let maxBytes = 64 * 1024

    public static func url(_ home: URL) -> URL { home.appendingPathComponent(fileName, isDirectory: false) }

    /// The helper's only write. Opens the file only if it already exists (no O_CREAT), never through a link.
    @discardableResult
    public static func appendAIUse(home: URL, aiApp: String, tool: String, resultCount: Int?, latencyMs: Int, now: Date = Date()) -> Bool {
        var properties: [String: UsageValue] = ["ai_app": .text(aiApp), "tool": .text(UsageCounts.tool(tool)), "latency_ms": .int(max(0, latencyMs))]
        if let resultCount { properties["result_count"] = .int(max(0, resultCount)); properties["empty"] = .bool(resultCount == 0) }
        let event = UsageEvent("ai_used", at: now, properties)
        guard UsageCounts.allowed(event), var line = try? JSONEncoder().encode(event) else { return false }
        line.append(0x0A)
        let fd = Darwin.open(url(home).path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) + line.count <= maxBytes else { return false }
        return line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, line.count) == line.count }
    }

    /// The app: sharing is on, so AI apps' calls may be counted (an empty file, owner-only).
    public static func create(home: URL) {
        let path = url(home).path
        guard !FileManager.default.fileExists(atPath: path) else { return }
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    /// The app: sharing is off. The file goes, so the helper writes nothing.
    public static func remove(home: URL) { try? FileManager.default.removeItem(at: url(home)) }

    /// The app: takes the waiting lines and leaves an empty file. Lines that aren't an allowed `ai_used` are dropped.
    public static func drain(home: URL) -> [UsageEvent] {
        let file = url(home), taken = home.appendingPathComponent(fileName + ".reading", isDirectory: false)
        try? FileManager.default.removeItem(at: taken)
        guard (try? FileManager.default.moveItem(at: file, to: taken)) != nil else { return [] }
        create(home: home)
        defer { try? FileManager.default.removeItem(at: taken) }
        guard let data = try? Data(contentsOf: taken), data.count <= maxBytes * 2 else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(UsageEvent.self, from: Data($0)) }
            .filter { $0.name == "ai_used" && UsageCounts.allowed($0) }
    }
}

extension MemoryStore {
    /// daily_check's recorded time: the 10-minute slots between `start` and `end` with at least one saved action, in
    /// seconds (one indexed range read of the times; nothing else is read). Deleted and forgotten actions don't count.
    public func recordedSeconds(start: Date, end: Date) throws -> Int {
        let at = "julianday(json_extract(body,'$.at'))"
        let slots = try rows("SELECT count(DISTINCT CAST((\(at) - julianday(?)) * 144 AS INTEGER)) FROM records WHERE \(at) >= julianday(?) AND \(at) < julianday(?) AND id NOT IN (SELECT id FROM tombstones)",
                             [iso(start), iso(start), iso(end)]).first?.first.flatMap { Int($0) } ?? 0
        return slots * 600
    }
}
