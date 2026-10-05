import Foundation
import Darwin

// agent-tools v2, WP-A (plan §4, §6.3; ownership.md "Local-owner preview").
//
// Where typed words come from for the agent tools:
// - `AgentBridgeSource`: the client of the app's private local socket (`AssistantTypedBridge`), used by `mac-mem`
//   (MCP server and `--local agent-preview`). The words it returns already went through `AgentSharePolicy.shareable`
//   inside the app (`MemoryStore.agentTypedText`); this process never holds the typing key.
// - `AgentStoreTypedSource`: the same answers in-process, for a store that holds the key (the app itself, or a check's
//   synthetic store with a test vault). Same gates, same policy.
// - `AgentOwnerPreview.permits` and `AgentBridgePeer`: the app-side gate for the local-owner preview.

/// Why a typed-words request got no words. `description` is the plain line a reply may show.
public enum AgentBridgeError: Error, Equatable, CustomStringConvertible {
    /// DayDream is closed, the setting is off, or typing is locked.
    case unavailable(AgentSharePolicy.TypedWordsOff)
    /// The app refused this caller (its AI app key doesn't verify, or an owner preview the gate refused).
    case denied

    public var description: String {
        switch self {
        case .unavailable(let off): return AgentSharePolicy(typedWords: false, typedWordsOff: off).typedWordsLine
        case .denied: return "Typed words: this connection can't read them. Reconnecting the AI app in DayDream Settings › Connections fixes it."
        }
    }
    /// A bridge reply's `status` as an error; nil for "ok".
    static func from(status: String?) -> AgentBridgeError? {
        switch status {
        case "ok": return nil
        case "off": return .unavailable(.settingOff)
        case "locked": return .unavailable(.locked)
        case "denied": return .denied
        default: return .unavailable(.appClosed)
        }
    }
}

extension AgentBridgeRequest {
    /// The socket's JSON object. `owner` appears only when true.
    public var bridgeObject: [String: Any] {
        var o: [String: Any] = ["op": op.rawValue, "client": client, "recipient": recipient, "capability": capability]
        if !ids.isEmpty { o["ids"] = ids }
        if let query { o["query"] = query }
        if let start { o["start"] = iso(start) }
        if let end { o["end"] = iso(end) }
        if let limit { o["limit"] = limit }
        if ownerPreview { o[AgentOwnerPreview.requestKey] = true }
        return o
    }
    /// One socket request; nil for an op this build doesn't know.
    public init?(bridge o: [String: Any]) {
        guard let op = (o["op"] as? String).flatMap(AgentBridgeOp.init(rawValue:)) else { return nil }
        self.init(op: op, ids: (o["ids"] as? [String] ?? []).filter { !$0.isEmpty }, query: o["query"] as? String,
                  start: (o["start"] as? String).flatMap(timestamp), end: (o["end"] as? String).flatMap(timestamp),
                  limit: (o["limit"] as? NSNumber)?.intValue,
                  client: o["client"] as? String ?? "", recipient: o["recipient"] as? String ?? "", capability: o["capability"] as? String ?? "",
                  ownerPreview: (o[AgentOwnerPreview.requestKey] as? NSNumber)?.boolValue == true)
    }
}

/// The client of the app's bridge. Every call is one short socket request; no answer reads as "DayDream is closed".
public struct AgentBridgeSource: AgentTypedSource {
    /// Typed ids per `words` request (the app answers at most this many, and says which it left for the next request).
    public static let wordsPerRequest = 400
    /// Bytes of ids per request, under the socket's 64 KB request limit.
    static let idBytesPerRequest = 48_000

    /// The history folder whose app to ask (the store's `home`): never assumed, so a check's scratch history never asks
    /// the DayDream running on this Mac.
    public var home: URL
    public var reader: TypedReader
    /// Set only by `mac-mem --local agent-preview` when the owner passed `AgentOwnerPreview.cliFlag`.
    public var ownerPreview: Bool

    public init(home: URL, client: String = "", recipient: String = "", capability: String = "", ownerPreview: Bool = false) {
        self.home = home
        self.reader = TypedReader(client: client, recipient: recipient, capability: capability)
        self.ownerPreview = ownerPreview
    }

    /// The owner preview is asked for only with no AI app's grant and never from a `mac-mem mcp` process.
    var sendsOwnerPreview: Bool {
        ownerPreview && reader.client.isEmpty && reader.recipient.isEmpty && reader.capability.isEmpty
            && !AgentBridgePeer.isMCPServer(arguments: CommandLine.arguments)
    }
    func request(_ op: AgentBridgeOp) -> [String: Any] {
        let owner = sendsOwnerPreview
        var o = AgentBridgeRequest(op: op, client: owner ? "" : reader.client, recipient: owner ? "" : reader.recipient,
                                   capability: owner ? "" : reader.capability, ownerPreview: owner).bridgeObject
        // The app checks this process is the owner's preview command (`AgentBridgePeer.fromMCPServer`).
        if owner { o["pid"] = Int(getpid()) }
        return o
    }
    func answer(_ request: [String: Any], timeout: Int) throws -> [String: Any] {
        guard let reply = AssistantTypedBridge.call(home: home, request, timeout: timeout) else { throw AgentBridgeError.unavailable(.appClosed) }
        if let error = AgentBridgeError.from(status: reply["status"] as? String) { throw error }
        return reply
    }

    public func policy() -> AgentBridgePolicy {
        guard let reply = try? answer(request(.policy), timeout: 2), let typed = (reply["typedWords"] as? NSNumber)?.boolValue else { return .unreachable }
        return AgentBridgePolicy(reachable: true, typedWords: typed, vault: AgentVaultState(rawValue: reply["vault"] as? String ?? "") ?? .unavailable)
    }

    /// The shareable words of these typed actions, by id; ids with nothing to share are left out. Throws
    /// `AgentBridgeError` when the app can't answer (closed, setting off, locked, or this caller refused).
    public func words(_ ids: [String]) throws -> [String: String] {
        var seen = Set<String>()
        var pending = ids.filter { !$0.isEmpty && $0.utf8.count <= 200 && seen.insert($0).inserted }
        var out: [String: String] = [:]
        while !pending.isEmpty {
            var batch: [String] = [], bytes = 0
            for id in pending {
                guard batch.count < Self.wordsPerRequest, bytes + id.utf8.count + 4 <= Self.idBytesPerRequest else { break }
                batch.append(id); bytes += id.utf8.count + 4
            }
            var r = request(.words); r["ids"] = batch
            let reply = try answer(r, timeout: 8)
            for (id, text) in reply["words"] as? [String: String] ?? [:] where seen.contains(id) { out[id] = text }
            let more = Set(reply["more"] as? [String] ?? []).intersection(batch)
            guard more.count < batch.count else { break }   // no progress: stop rather than loop
            pending = batch.filter(more.contains) + pending.dropFirst(batch.count)
        }
        return out
    }

    /// Typed rows whose shareable words hold every query word, newest first, within `start..<end`.
    public func search(_ query: String, start: Date?, end: Date?, limit: Int?) throws -> AgentTypedSearchResult {
        var r = request(.search)
        r["query"] = query
        if let start { r["start"] = iso(start) }
        if let end { r["end"] = iso(end) }
        if let limit { r["limit"] = limit }
        return AgentTypedSearchResult(bridgeReply: try answer(r, timeout: 10))
    }
}

extension AgentTypedSearchResult {
    /// The `search` op's reply fields as a result.
    init(bridgeReply reply: [String: Any]) {
        let hits = (reply["hits"] as? [[String: String]] ?? []).compactMap { h -> AgentTypedHit? in
            guard let id = h["id"], let at = h["at"], let snippet = h["snippet"] else { return nil }
            return AgentTypedHit(id: id, at: at, snippet: snippet)
        }
        self.init(hits: hits, total: (reply["total"] as? NSNumber)?.intValue ?? hits.count,
                  complete: (reply["complete"] as? NSNumber)?.boolValue ?? true, oldestScanned: reply["oldestScanned"] as? String)
    }
    /// The reply fields for these results.
    var bridgeReply: [String: Any] {
        var o: [String: Any] = ["status": "ok", "hits": hits.map { ["id": $0.id, "at": $0.at, "snippet": $0.snippet] }, "total": total, "complete": complete]
        if let oldestScanned { o["oldestScanned"] = oldestScanned }
        return o
    }
}

/// The same answers in-process, for a store that holds the typing key: the app itself, or a check's synthetic store
/// with a test vault (WP-D's fixture). `enabled` is the app's setting; the reader's grant is checked as on the socket.
public struct AgentStoreTypedSource: AgentTypedSource {
    public var store: MemoryStore
    public var reader: TypedReader
    public var enabled: Bool
    /// The clock for expiry; nil reads the real clock.
    public var now: Date?
    public init(store: MemoryStore, reader: TypedReader, enabled: Bool, now: Date? = nil) {
        self.store = store; self.reader = reader; self.enabled = enabled; self.now = now
    }
    func mapped<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch AssistantTypedReadError.off { throw AgentBridgeError.unavailable(.settingOff) }
        catch AssistantTypedReadError.locked { throw AgentBridgeError.unavailable(.locked) }
        catch MemError.denied { throw AgentBridgeError.denied }
    }
    public func policy() -> AgentBridgePolicy {
        AgentBridgePolicy(reachable: true, typedWords: enabled, vault: store.agentVaultState)
    }
    public func words(_ ids: [String]) throws -> [String: String] {
        try mapped { try store.assistantTypedWords(ids, reader: reader, enabled: enabled, now: now ?? Date()) }
    }
    public func search(_ query: String, start: Date?, end: Date?, limit: Int?) throws -> AgentTypedSearchResult {
        try mapped { try store.assistantTypedSearch(query, start: start, end: end, limit: limit, reader: reader, enabled: enabled, now: now ?? Date()) }
    }
}

// MARK: - The local-owner preview gate (app side)

extension AgentOwnerPreview {
    /// All must hold: the owner asked for it, the peer is this user, it isn't `mac-mem mcp`, the setting is on, and no
    /// AI app's grant field is set. The caller answers only over the local socket.
    public static func permits(_ request: AgentBridgeRequest, sameUser: Bool, fromMCPServer: Bool, typedWordsSetting: Bool) -> Bool {
        request.ownerPreview && sameUser && !fromMCPServer && typedWordsSetting
            && request.client.isEmpty && request.recipient.isEmpty && request.capability.isEmpty
    }
}

/// What the app can learn about the process on the other end of the socket. Every answer fails closed.
public enum AgentBridgePeer {
    /// The `mac-mem` subcommand that serves AI apps.
    public static let mcpVerb = "mcp"
    /// The local preview command the owner runs.
    public static let previewVerb = "agent-preview"
    public static let executableName = "mac-mem"

    /// True when these process arguments are a `mac-mem mcp` server: `mcp` as any argument after the program.
    public static func isMCPServer(arguments: [String]) -> Bool { arguments.dropFirst().contains(mcpVerb) }

    /// The owner's preview command: `mac-mem [options] agent-preview --owner-preview ...`, and never `mcp`.
    public static func isOwnerPreviewCommand(executable: String, arguments: [String]) -> Bool {
        let names = [executable, arguments.first ?? ""].map { URL(fileURLWithPath: $0).lastPathComponent }
        let rest = arguments.dropFirst()
        return names.contains(executableName) && !rest.contains(mcpVerb) && rest.contains(previewVerb) && rest.contains(AgentOwnerPreview.cliFlag)
    }

    /// For the gate: false only when `pid` is a process of this user running the owner's preview command. No pid, another
    /// user's process, unreadable arguments or any other command reads as "from the MCP server" (refused).
    public static func fromMCPServer(pid: pid_t?) -> Bool {
        guard let pid, pid > 0, owner(pid) == getuid(), let process = command(pid) else { return true }
        return !isOwnerPreviewCommand(executable: process.executable, arguments: process.arguments)
    }

    /// The socket peer's process id (`LOCAL_PEERPID`), for the bridge server to pass to `assistantBridgeAnswer`.
    public static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
    }

    /// The user a process runs as.
    static func owner(_ pid: pid_t) -> uid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info.kp_eproc.e_ucred.cr_uid
    }

    /// A process's executable path and arguments (`KERN_PROCARGS2`). Only the arguments are read; the environment that
    /// follows them in the buffer (it can hold an AI app's DayDream key) is wiped before the buffer is freed.
    static func command(_ pid: pid_t) -> (executable: String, arguments: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX], limit: Int32 = 0, length = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &limit, &length, nil, 0) == 0, limit > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(limit))
        defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count < 4096 else { return nil }
        var index = MemoryLayout<Int32>.size
        let pathStart = index
        while index < size && buffer[index] != 0 { index += 1 }
        let executable = String(decoding: buffer[pathStart..<index], as: UTF8.self)
        while index < size && buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(count) && index < size {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == Int(count) ? (executable, arguments) : nil
    }
}
