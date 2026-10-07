import Foundation
import MemoryCore
import notify

// Deliberately separate from tool/MCP dispatch. Exact native app-owned local
// supervisor protocol; no default home, credential arguments or shell command.
if CommandLine.arguments.dropFirst().first == "search-supervise" {
    let raw=Array(CommandLine.arguments.dropFirst(2))
    func required(_ key:String)->String?{guard let n=raw.firstIndex(of:key),n+1<raw.count else{return nil};return raw[n+1]}
    guard raw.count==8,let home=required("--home"),home.hasPrefix("/"),
          let server=required("--server"),server.hasPrefix("/"),let hash=required("--server-sha256"),
          let budget=required("--startup-budget").flatMap(Double.init) else{exit(64)}
    exit(LocalSearchSupervisor.run(home:URL(fileURLWithPath:home),server:URL(fileURLWithPath:server),sha256:hash,startupBudget:budget))
}

// All identity comes from process configuration, never MCP tool arguments.
var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i+1]; args.removeSubrange(i...i+1); return value
}
let homeArgument = option("--home")
// connect/disconnect/connections only: the folder the AI apps' settings files are under (checks use a scratch folder).
let userHomeArgument = option("--user-home")
let expectedConfigSHA256 = option("--expect-sha256")
let eventCursor = option("--after")
let searchApp = option("--app")
let searchSite = option("--site")
let searchStart = option("--start")
let searchEnd = option("--end")
let actionDay = option("--day")
let actionTimezone = option("--timezone")
let migrationSnapshot = option("--snapshot")
let migrationHash = option("--snapshot-sha256")
let migrationPolicyHash = option("--policy-sha256")
let migrationPolicyFile = option("--policy-file")
let migrationStage = option("--staging-home")
let migrationImportID = option("--import-id")
let confirmMigration = args.contains("--confirm-import"); args.removeAll { $0 == "--confirm-import" }
let migrationBatchLimit = option("--batch-limit").flatMap(Int.init) ?? 100
let acceptMigrationExclusions = args.contains("--accept-exclusions"); args.removeAll { $0 == "--accept-exclusions" }
let searchReport = args.contains("--search-report"); args.removeAll { $0 == "--search-report" }
// agent-tools v2: `agent-preview` only (local owner preview, plan §6.3): the owner's explicit flag, and a fixed "now".
let ownerPreview = args.contains(AgentOwnerPreview.cliFlag); args.removeAll { $0 == AgentOwnerPreview.cliFlag }
let previewNow = option("--now")
let includeEventText = args.contains("--include-text"); args.removeAll { $0 == "--include-text" }
let home = homeArgument.map { URL(fileURLWithPath:$0, isDirectory:true) } ?? MemPaths.home()
let client = option("--client") ?? "", recipient = option("--recipient") ?? ""
let local = args.contains("--local"); args.removeAll { $0 == "--local" }
let capability = ProcessInfo.processInfo.environment["MAC_MEM_CAPABILITY"] ?? ""
let command = args.first ?? "help"
let companionExecutable = URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
let companionIdentity = Result { try CompanionIdentity(executable:companionExecutable) }
func output<T: Encodable>(_ value: T) throws { print(try json(value)) }
/// claude/catchup-1003: `status` and `doctor` say how many moments wait for a note (today and the 7 days before it), not
/// the record-summary count, which read 0 while past days showed "Summarizing…". The old count stays as
/// `records_pending`. Counts only, never a title or a word.
func withNoteBacklog(_ store: MemoryStore, now: Date = Date()) throws -> [String: String] {
    var health = try store.status()
    health["records_pending"] = health["pending"] ?? "0"
    guard let backlog = try? store.noteBacklog(now: now) else { health["pending"] = "unknown"; return health }
    health["pending"] = String(backlog.pending)
    health["notes_waiting"] = String(backlog.waiting)
    health["notes_updating"] = String(backlog.updating)
    health["notes_too_long"] = String(backlog.tooLong)
    health["notes_pending_by_day"] = backlog.byDay.keys.sorted().map { "\($0): \(backlog.byDay[$0]!)" }.joined(separator: ", ")
    if backlog.partialDays > 0 { health["notes_partial_days"] = String(backlog.partialDays) }
    return health
}
func authorize(_ store: MemoryStore, _ scope: String, mcp: Bool = false) throws {
    if local && !mcp { return }
    try store.authorize(client:client, recipient:recipient, capability:capability, scope:scope)
}
func searchQuery(_ text: String, app: String? = nil, start: String? = nil, end: String? = nil, site:String?=nil, after:String?=nil) throws -> MemorySearchQuery {
    guard start == nil || timestamp(start!) != nil, end == nil || timestamp(end!) != nil else { throw MemError.invalid("Search times must be ISO-8601") }
    let query=MemorySearchQuery(text,app:app,start:start.flatMap(timestamp),end:end.flatMap(timestamp),site:site,after:after)
    guard query.start == nil || query.end == nil || query.start! < query.end! else { throw MemError.invalid("Search end must follow start") }
    return query
}
/// An AI app starts `mac-mem mcp` once and keeps it for its whole session. When DayDream is updated (or reinstalled
/// with a different build) meanwhile, this process carries on as the updated copy: the same process, arguments,
/// environment (its access key) and stdin/stdout, so the AI app's DayDream tools keep working without restarting the
/// AI app. Old code never answers once the bundle has changed. Nothing about a request goes into the arguments or the
/// environment; the server keeps no state between requests except what it decided itself and carries across a renewal
/// in its environment (`ToolListState`): the protocol revision agreed at initialize and the tool list it gave the AI app.
enum ServerRenewal {
    /// How often an idle server looks whether DayDream was updated (milliseconds).
    static let idleCheck: Int32 = 2000
    /// How long a waiting request gives an update in progress to finish.
    static let updateWait: TimeInterval = 10
    /// Renewals one AI app session may make in a row: an update that keeps changing can never loop.
    static let limit = 20
    static let counter = "DAYDREAM_MCP_RENEWALS"
    /// claude/rel-017c: renewals further apart than this are ordinary updates, not a loop, so the count starts again.
    /// Without it an AI app kept open across 20 updates (ChatGPT's helpers on the owner's Mac were at 8-10 after four
    /// days) would answer "being updated" until it restarted.
    static let loopWindow: TimeInterval = 10 * 60
    static let renewedAt = "DAYDREAM_MCP_RENEWED_AT"

    static func freshness() -> CompanionIdentity.Freshness {
        CompanionIdentity.freshness(executable:companionExecutable, loaded:try? companionIdentity.get())
    }
    /// Replaces this process with `executable`. Returns only when it couldn't (the caller answers "being updated").
    static func renew(as executable: URL) {
        let now = Date().timeIntervalSince1970
        let last = getenv(renewedAt).flatMap { Double(String(cString:$0)) }
        let recent = last.map { now - $0 < loopWindow && now >= $0 } ?? false
        let count = recent ? getenv(counter).flatMap { Int(String(cString:$0)) } ?? 0 : 0
        guard count < limit else { return }
        setenv(counter, String(count + 1), 1)
        setenv(renewedAt, String(Int(now)), 1)
        fflush(stdout)
        // Only stdin, stdout and stderr carry over: the history file this process had open closes with it.
        let open = min(getdtablesize(), 65536)
        if open > 3 { for fd in 3..<open { let flags = fcntl(fd, F_GETFD); if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) } } }
        var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) } + [nil]
        execv(executable.path, &argv)
        for pointer in argv { free(pointer) }
    }
    /// Waits for the next request. While idle it takes up an update as soon as it is complete, so the next request is
    /// answered by the updated copy. Nothing of the request is read here.
    static func awaitRequest() {
        var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        while true {
            let ready = poll(&input, 1, idleCheck)
            if ready > 0 || (ready < 0 && errno != EINTR) { return }
            if case .replaced(let executable) = freshness() { renew(as: executable) }
        }
    }
    /// A request is waiting (not yet read): answer it as the DayDream now on disk. True when this copy may answer it.
    static func settle() -> Bool {
        let deadline = Date().addingTimeInterval(updateWait)
        while true {
            switch freshness() {
            case .current: return true
            case .replaced(let executable): renew(as: executable); return false
            case .updating:
                if Date() >= deadline { return false }
                usleep(200_000)
            }
        }
    }
}
/// claude/recall-1004: AI apps keep the tool list `mac-mem mcp` gave them when the chat started. After a renewal the
/// updated copy answers, but the AI app's list is still the older copy's, so a Next line could name a tool the AI app
/// doesn't have (a laptop chat begun on an older build was told to use `recap` and `moment_details` it never saw).
/// This server (1) says it may change its tool list (initialize `capabilities.tools.listChanged`), (2) after a renewal
/// whose list differs from the one the AI app was given, sends `notifications/tools/list_changed` once, so an AI app
/// that supports it fetches the new list, and (3) until the AI app fetches it, starts every tool reply with a note
/// that names the tools it lacks and how to get them (`AssistantCatalog.staleToolsNotice`). Only values this server
/// made cross a renewal, in its environment: the agreed protocol revision, and the fingerprint and names of the list
/// it gave (never a request's content, never the access key's value).
enum ToolListState {
    static let listedKey = "DAYDREAM_MCP_LISTED"
    static let protocolKey = "DAYDREAM_MCP_PROTOCOL"
    /// agent-tools v2: the toolset this server lists (`DAYDREAM_MCP_TOOLSET`: v2 by default, legacy, or both). Its
    /// fingerprint is part of what was listed, so a renewal into another toolset sends list_changed.
    static let toolset = ToolsetMode.current()
    /// Nothing was listed yet in this AI app session (a process from before this change leaves the key unset).
    static let nothingListed = "-"
    /// This process is a renewal: an earlier copy of DayDream started it.
    static let renewed = (getenv(ServerRenewal.counter).flatMap { Int(String(cString:$0)) } ?? 0) > 0
    /// What the AI app was last given by tools/list in this session: `fingerprint:name,name,...`, `-`, or nil when an
    /// earlier copy that doesn't record it renewed into this one.
    static var listed: String? = getenv(listedKey).map { String(cString:$0) }
    /// The revision agreed at initialize by this process or the copy it carried on from.
    static var agreed: String? = getenv(protocolKey).map { String(cString:$0) }.flatMap { AssistantCatalog.protocolVersions.contains($0) ? $0 : nil }

    /// At start. A fresh server records that nothing is listed yet; a renewal keeps what the earlier copy recorded.
    /// True when the AI app should be told the list changed.
    static func start() -> Bool {
        if listed == nil && !renewed { record(nothingListed) }
        guard renewed, agreed != nil || listed == nil else { return false }
        guard let listed else { return true }
        return listed != nothingListed && !listed.hasPrefix(AssistantCatalog.toolListFingerprint(toolset) + ":")
    }
    /// tools/list answered with this build's list.
    static func gaveList() { record(AssistantCatalog.toolListFingerprint(toolset) + ":" + AssistantCatalog.toolNames(toolset).joined(separator:",")) }
    static func initialized(_ revision: String) { agreed = revision; setenv(protocolKey, revision, 1) }
    private static func record(_ value: String) { listed = value; setenv(listedKey, value, 1) }
    /// This build's tools the AI app doesn't have: [] when its list is current or nothing was listed yet, nil when not known.
    static var missing: [String]? {
        guard let listed else { return renewed ? nil : [] }
        guard listed != nothingListed, !listed.hasPrefix(AssistantCatalog.toolListFingerprint(toolset) + ":") else { return [] }
        let names = Set((listed.split(separator:":", maxSplits:1).dropFirst().first ?? "").split(separator:",").map(String.init))
        return AssistantCatalog.toolNames(toolset).filter { !names.contains($0) }
    }
    /// The note every tool reply starts with while the AI app's list lacks tools; nil when it doesn't.
    static var notice: String? {
        let lacking = missing
        if let lacking, lacking.isEmpty { return nil }
        return AssistantCatalog.staleToolsNotice(client:client, missing:lacking, mode:toolset)
    }
}
/// The history file as it is on disk now (device and inode); nil when there is none.
func historyFile(_ home: URL) -> String? {
    var info = stat()
    guard stat(home.appendingPathComponent("memory.sqlite").path, &info) == 0 else { return nil }
    return "\(info.st_dev):\(info.st_ino)"
}
/// The server's history, held only here: when DayDream repairs a damaged history (a new file takes its place), the loop
/// swaps in the new one and the old file is closed (nothing else in the process keeps it open).
final class ServedHistory {
    var store: MemoryStore
    init(home: URL) throws {
        store = try MemoryStore(home: home)
        // Safe typing: the CLI and MCP never attach a typing vault, so typed words can't be opened here.
        guard store.typedVaultState == .unavailable else { throw MemError.denied }
    }
}
/// claude/summary-1003 (owner decision 2026-10-03): typed words for AI apps come only from the running DayDream app
/// (`AssistantTypedBridge`), which checks this AI app's key and the setting "Let AI apps see your typed words" itself.
enum AssistantTypedAccess {
    static var reader: [String:Any] { ["client":client,"recipient":recipient,"capability":capability] }
    static let typedCoverage = "Matches app names, window and document titles, website names, the person's own corrections and, in typed, the words the person typed (the person allowed AI apps to read them). Pass a typed hit's id to moment_details for the whole moment."
    static let offNote = "Exact typed words aren't shared: \"\(AIReadsTypedSetting.title)\" is off in DayDream. Each typed action says where and about how much was typed."
    static let closedNote = "Exact typed words come from the DayDream app, which isn't open (or typing is locked). Each typed action says where and about how much was typed."
    /// The words of these typed actions, and a note when there are none to give.
    static func words(_ store: MemoryStore, ids: [String]) -> ([String:String], String?) {
        guard !ids.isEmpty else { return ([:], nil) }
        guard let reply = AssistantTypedBridge.call(home:store.home, reader.merging(["op":"words","ids":ids]) { $1 }) else { return ([:], closedNote) }
        switch reply["status"] as? String {
        case "ok": return ((reply["words"] as? [String:String]) ?? [:], nil)
        case "off": return ([:], offNote)
        default: return ([:], closedNote)
        }
    }
    /// Typed hits for a query (newest first): local time, app, excerpt, the action id and its moment. nil: as before.
    static func search(_ store: MemoryStore, query: String) -> [[String:String]]? {
        guard let reply = AssistantTypedBridge.call(home:store.home, reader.merging(["op":"search","query":query]) { $1 }),
              reply["status"] as? String == "ok", let hits = reply["hits"] as? [[String:String]] else { return nil }
        var out: [[String:String]] = []
        for hit in hits {
            guard let id = hit["id"], let action = try? store.action(id) else { continue }
            var row = ["id":id,"when":AssistantView.when(action.at),"app":AppNames.display(app:action.app,bundle:action.bundle),"snippet":hit["snippet"] ?? "","state":AssistantView.shownState(action.state)]
            if !action.title.isEmpty { row["window"] = action.title }
            out.append(row)
        }
        return out
    }
}
/// fix/sx-engine-battery: summaries are written in batches, so the last hour may not have notes yet. Before an AI app's
/// request that covers today or the last two hours, this process asks the running app (while summaries are on) to
/// write what's there, and waits until it says it's done, at most 5 seconds, then answers from what is saved (a slower
/// batch's notes land for the next call). The app writes at most once every 5 minutes this way and always answers, also
/// when it skips. fix/sx-all round 1: when the app didn't answer in time (a long batch, or the app quit without saying
/// summaries are off), this server doesn't ask again for 5 minutes, so an AI app is never held up on every call.
enum WriterFreshen {
    /// Checks name their own request (scripts/mcp-update-checks.py), so a test never wakes a DayDream running on the Mac.
    static let request = ProcessInfo.processInfo.environment["DAYDREAM_TEST_FRESHEN_REQUEST"] ?? "com.getnorthlight.daydream.writer.recent"
    static let done = request + ".done"
    static let wait: TimeInterval = 5
    static let quietAfterTimeout: TimeInterval = 5 * 60
    /// When the last ask went unanswered (this process only).
    static var unansweredAt: Date?
    /// Whether this tool call reads today or the last two hours.
    static func covers(_ tool: String, _ input: [String:Any], now: Date = Date()) -> Bool {
        // agent-tools v2: timeline and search reach today when their when does (no when: the whole history, today too).
        if AssistantCatalog.answersV2(tool, ToolListState.toolset) {
            return AgentTools.coversRecent(name: tool, arguments: input, now: now, timezone: TimeZone.current.identifier)
        }
        let format = DateFormatter(); format.locale = Locale(identifier:"en_US_POSIX"); format.timeZone = .current; format.dateFormat = "yyyy-MM-dd"
        let today = format.string(from:now)
        switch tool {
        case "current-context": return true
        case "search":
            guard let end = (input["end"] as? String).flatMap(timestamp) else { return true }
            return end >= now.addingTimeInterval(-2 * 3600)
        case "recall":
            if let query = input["query"] as? String, !query.trimmingCharacters(in:.whitespaces).isEmpty { return true }
            if let open = input["open"] as? String, !open.isEmpty { return open.contains(today) }
            let when = (input["when"] as? String ?? "").lowercased()
            return when.isEmpty || when.contains("today") || when.contains("now") || when.hasPrefix("this") || when.contains(today)
        case "recap":
            // Only a recap that reaches today waits for today's notes.
            let when = (input["when"] as? String ?? "").lowercased()
            if when.contains("yesterday") && !when.contains("today") { return false }
            if when.contains("last week") { return false }
            if when.range(of:"^\\d{4}-\\d{2}-\\d{2}$",options:.regularExpression) != nil { return when == today }
            return true
        default: return false
        }
    }
    /// Asks the app and waits for its answer. Nothing to wait for while summaries are off (the app isn't writing).
    static func ask(_ store: MemoryStore, now: Date = Date()) {
        guard let mode = try? store.summaryWriter()?.mode, mode == "local" || mode == "cloud" else { return }
        guard shouldAsk(now: now) else { return }
        var token: Int32 = 0
        guard notify_register_check(done, &token) == NOTIFY_STATUS_OK else { return }
        defer { notify_cancel(token) }
        var changed: Int32 = 0
        _ = notify_check(token, &changed)   // the first check always reports a change
        notify_post(request)
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            usleep(100_000)
            if notify_check(token, &changed) == NOTIFY_STATUS_OK, changed != 0 { unansweredAt = nil; return }
        }
        unansweredAt = Date()
    }
    /// No ask within 5 minutes of one that went unanswered.
    static func shouldAsk(now: Date = Date()) -> Bool {
        guard let last = unansweredAt else { return true }
        return now.timeIntervalSince(last) >= quietAfterTimeout
    }
}
/// agent-tools v2: what a v2 tool call runs against. Typed words come only from the running DayDream app, through
/// WP-A's bridge client (`AgentBridgeSource`), never from this process (it holds no typing key). `ownerPreview` is set
/// only by `mac-mem --local agent-preview --owner-preview`, never by the MCP server.
/// The owner preview carries no AI app's grant (WP-A's gate refuses one that does); an AI app's call carries its grant.
func agentContext(_ store: MemoryStore, owner: Bool = false, now: Date = Date(), timezone: String = TimeZone.current.identifier) -> AgentToolContext {
    let source = owner ? AgentBridgeSource(home: store.home, ownerPreview: true)
        : AgentBridgeSource(home: store.home, client: client, recipient: recipient, capability: capability, ownerPreview: false)
    return AgentToolContext(store: store, typed: source, headlines: store as? DayReviewHeadlineSource, timezone: timezone, now: now)
}
/// claude/mcp-prompts-1003: a JSON-RPC protocol error (an unknown tool or method), as opposed to a tool that ran and
/// failed, which answers as a tool result with isError so the AI app's model reads what to do next.
struct MCPProtocolError: Error { let code: Int; let message: String }
/// Usage counts (Settings › Advanced › Share anonymous usage counts): one `ai_used` line per tool call (which AI app, the
/// tool's name, how many results, how long it took), appended to `UsageInbox`'s file in DayDream's folder only while it
/// exists, which is while sharing is on (the app makes and removes it). The DayDream app reads the file and sends the
/// counts. This process never sends anything and opens no connection; the line holds no query, title or word.
enum MCPUsage {
    /// The name the AI app gave at initialize (a renewal forgets it; `--client` stands in then).
    static var clientName: String?
    static func record(home: URL, tool: String, startedAt: TimeInterval, resultCount: Int?) {
        let ms = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        UsageInbox.appendAIUse(home: home, aiApp: UsageCounts.aiApp(clientName: clientName, connection: client), tool: tool, resultCount: resultCount, latencyMs: ms)
    }
}
func mcp(_ served: ServedHistory) {
    var store: MemoryStore { served.store }
    var file = historyFile(served.store.home)
    // The revision the client agreed in initialize; structuredContent is offered from 2025-06-18 on.
    // claude/recall-1004: a renewal keeps the revision the earlier copy agreed (it was reset to the oldest before).
    var negotiated = ToolListState.agreed ?? AssistantCatalog.protocolVersions.last!
    // Unbuffered: nothing past the request being read sits in this process, so a renewal loses no queued request.
    setvbuf(stdin, nil, _IONBF, 0)
    if ToolListState.start() {
        print(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#)
        fflush(stdout)
    }
    while true {
        ServerRenewal.awaitRequest()
        let current = ServerRenewal.settle()
        guard let line = readLine() else { break }
        let startedAt = ProcessInfo.processInfo.systemUptime
        // A tool call to count once answered (MCPUsage): its name and, for search, how many hits.
        var usage: (tool: String, count: Int?)?
        var id: Any = NSNull()
        do {
            guard line.utf8.count <= 65536, let request = try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any], let method = request["method"] as? String else { throw MemError.invalid("Invalid request") }
            guard let requestID = request["id"] else { continue }; id = requestID
            // Old code never answers once the bundle changed (never a raw file error either: it would name paths).
            guard current, let identity = try? companionIdentity.get(), (try? identity.validate()) != nil else {
                throw MemError.invalid(CompanionIdentity.updatingMessage)
            }
            // "Today" and "now" follow the Mac's time zone as it is now, not as it was when the AI app started this server.
            NSTimeZone.resetSystemTimeZone()
            // DayDream repaired a damaged history and a new file took its place (StoreIntegrity, G45): read the new one
            // from now on, never the damaged file. (A read-only open: no typing vault, as at start.)
            if let now = historyFile(store.home), now != file, let reopened = try? ServedHistory(home: store.home) {
                served.store = reopened.store; file = now
            }
            let params = request["params"] as? [String:Any] ?? [:]
            var result: Any
            switch method {
            // Instructions and tool text are prompts to the client's model: see
            // MemoryCore/AssistantCatalog.swift. Tools stay read-only.
            case "initialize":
                negotiated = AssistantCatalog.negotiatedVersion(params["protocolVersion"])
                MCPUsage.clientName = (params["clientInfo"] as? [String:Any])?["name"] as? String
                ToolListState.initialized(negotiated)
                result = ["protocolVersion":negotiated,"capabilities":["tools":["listChanged":true],"resources":[:]],"serverInfo":["name":"DayDream","title":"DayDream","version":try companionIdentity.get().version],"instructions":AssistantCatalog.serverInstructions(ToolListState.toolset)] as [String:Any]
            case "ping": result = [:] as [String:String]
            case "tools/list": result = ["tools":AssistantCatalog.toolList(ToolListState.toolset)]; ToolListState.gaveList()
            case "resources/list": result = ["resources":AssistantCatalog.resources]
            case "resources/templates/list": result = ["resourceTemplates":AssistantCatalog.resourceTemplates]
            case "tools/call", "resources/read":
                let resource = params["uri"] as? String
                let name = resource == "macmem://status" ? "status" : resource == "macmem://context/current" ? "context" : resource == "macmem://current-context" ? "current-context" : resource != nil ? "open" : params["name"] as? String ?? ""
                let input = params["arguments"] as? [String:Any] ?? [:]
                if resource == nil, !AssistantCatalog.answers(name, ToolListState.toolset) {
                    throw MCPProtocolError(code: -32602, message: AssistantCatalog.unknownToolMessage(name, mode: ToolListState.toolset))
                }
                // agent-tools v2 (docs/agent-tools/plan.md §2): timeline, search, details and status. The seven 0.1.4 names
                // still answer below, unlisted, so chats begun on 0.1.4 keep working.
                if resource == nil, AssistantCatalog.answersV2(name, ToolListState.toolset) {
                    do {
                        if WriterFreshen.covers(name, input) { WriterFreshen.ask(store) }
                        let scope: String? = name == "status" ? nil : name == "search" ? "search" : "detail"
                        if let scope { try authorize(store, scope, mcp: true) }
                        let access = name == "status" ? store.assistantAccess(client:client,recipient:recipient,capability:capability) : nil
                        let output = AgentTools.run(name: name, arguments: input, context: agentContext(store), access: access)
                        usage = (name, output.isError ? nil : output.resultCount)
                        // Access is checked again after reading: a connection turned off meanwhile gets nothing.
                        if let scope { try authorize(store, scope, mcp: true) }
                        var reply: [String:Any] = ["content":[["type":"text","text":output.text]]]
                        if output.isError { reply["isError"] = true }
                        else if negotiated >= "2025-06-18", (try? AgentTools.format(input)) == .json,
                                let object = try? JSONSerialization.jsonObject(with: Data(output.text.utf8)) as? [String:Any] { reply["structuredContent"] = object }
                        result = reply
                    } catch let failure where !(failure is MCPProtocolError) {
                        result = ["content":[["type":"text","text":AssistantCatalog.errorMessage(failure)]],"isError":true]
                        usage = (name, nil)
                    }
                    if let notice = ToolListState.notice, var reply = result as? [String:Any], let content = reply["content"] as? [[String:Any]] {
                        reply["content"] = [["type":"text","text":notice]] + content
                        result = reply
                    }
                    let reply: [String:Any] = ["jsonrpc":"2.0","id":id,"result":result]
                    print(String(decoding:try JSONSerialization.data(withJSONObject:reply,options:[.sortedKeys]),as:UTF8.self))
                    fflush(stdout)
                    if let usage { MCPUsage.record(home: store.home, tool: usage.tool, startedAt: startedAt, resultCount: usage.count) }
                    continue
                }
                // claude/mcp-prompts-1003: tools answer in concise Markdown unless response_format is "detailed" (the JSON
                // as before). Resources always answer JSON. AssistantMarkdown reads only the detailed reply.
                let format = resource == nil ? AssistantMarkdown.format(input["response_format"]) : .detailed
                var zone = TimeZone.current
                do {
                guard let format else { throw MemError.invalid(AssistantCatalog.formatMessage) }
                if resource == nil { usage = (name, nil) }
                var body: String
                if WriterFreshen.covers(name, input) { WriterFreshen.ask(store) }
                // MCP replies use the assistant presentation (local times, app
                // names, plain words). CLI verbs below keep their JSON contracts.
                switch name {
                // fix/welcome-prompt: status works without a grant (so a broken connection can be explained), and says whether
                // this AI app's own connection works, checked with its key the way every other tool is.
                case "status": body = try json(store.assistantStatus(access:store.assistantAccess(client:client,recipient:recipient,capability:capability)))
                case "context": try authorize(store,"context",mcp:true); body = try store.assistantContext(); try authorize(store,"context",mcp:true)
                case "current-context": try authorize(store,"context",mcp:true); body = try store.assistantCurrentActions(after:input["after"] as? String); try authorize(store,"context",mcp:true)
                case "open":
                    try authorize(store,"detail",mcp:true)
                    let uri=resource ?? input["uri"] as? String ?? ""
                    zone=AssistantView.zone(forURI:uri)
                    body=AssistantView.decorate(try store.openActionResource(uri,assistant:true),zone:AssistantView.zone(forURI:uri),slim:true,typed:store.typedStatusLookup())
                    try authorize(store,"detail",mcp:true)
                case "search":
                    try authorize(store,"search",mcp:true)
                    body = try json(store.searchReport(searchQuery(input["query"] as? String ?? "",app:input["app"] as? String,start:input["start"] as? String,end:input["end"] as? String,site:input["site"] as? String,after:input["after"] as? String)))
                    // N12: DayDream's notes match too ("email Sam" finds "Emailed Sam about ..."), on the first page only.
                    if let q = input["query"] as? String, !q.isEmpty, input["after"] == nil, var report = try JSONSerialization.jsonObject(with:Data(body.utf8)) as? [String:Any] {
                        let notes = try store.noteHits(query:q)
                        if !notes.isEmpty { report["notes"] = notes; body = String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self) }
                    }
                    // claude/summary-1003 (owner decision 2026-10-03): with "Let AI apps see your typed words" on, typed and
                    // sent words match too, through the running app (only it holds the key). Off or no app: as before.
                    if let q = input["query"] as? String, !q.trimmingCharacters(in:.whitespaces).isEmpty, input["after"] == nil,
                       let typed = AssistantTypedAccess.search(store, query:q), var report = try JSONSerialization.jsonObject(with:Data(body.utf8)) as? [String:Any] {
                        report["typed"] = typed
                        report["coverage"] = AssistantTypedAccess.typedCoverage
                        body = String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self)
                    }
                    try authorize(store,"search",mcp:true)
                    if resource == nil, let report = try? JSONSerialization.jsonObject(with:Data(body.utf8)) as? [String:Any] {
                        usage = (name, (report["hits"] as? [Any])?.count)
                    }
                case "recall":
                    try authorize(store,"detail",mcp:true)
                    body = try store.assistantRecall(level:input["level"] as? String,when:input["when"] as? String,open:input["open"] as? String,query:input["query"] as? String)
                    try authorize(store,"detail",mcp:true)
                // mcp-recap-1002: a few days at a glance, pre-grouped (notes and thread names only, as recall).
                case "recap":
                    try authorize(store,"detail",mcp:true)
                    body = try store.assistantRecap(when:input["when"] as? String)
                    try authorize(store,"detail",mcp:true)
                // claude/summary-1003 (owner decision 2026-10-03): one moment's real actions, with the exact typed and sent
                // words from the running app while "Let AI apps see your typed words" is on; otherwise where and how much.
                case "moment_details":
                    try authorize(store,"detail",mcp:true)
                    guard let page = try store.assistantMomentPage(id:input["id"] as? String,uri:input["moment"] as? String,day:input["day"] as? String,after:input["after"] as? String) else {
                        throw MemError.invalid(AssistantCatalog.momentNotFound)
                    }
                    let (words, note) = AssistantTypedAccess.words(store, ids:page.typedIDs)
                    body = try store.assistantMomentDetails(page, words:words, wordsNote:note)
                    try authorize(store,"detail",mcp:true)
                // Typed words: this process has no key, so read is a summary (with a
                // note when the person allowed exact words, which the app holds).
                case "read": try authorize(store,"detail",mcp:true); body = try json(store.assistantItem(input["id"] as? String ?? "",reader:TypedReader(client:client,recipient:recipient,capability:capability))); try authorize(store,"detail",mcp:true)
                default: throw MCPProtocolError(code: -32602, message: AssistantCatalog.unknownToolMessage(name))
                }
                // agent-tools v2: the 0.1.4 tools never say whether a message was sent or is a draft either.
                body = AgentLegacyFilter.clean(body)
                if let resource {
                    result = ["contents":[["uri":resource,"mimeType":name == "context" ? "text/plain" : "application/json","text":body]]]
                } else if format == .concise, AssistantMarkdown.tools.contains(name) {
                    result = ["content":[["type":"text","text":AssistantMarkdown.render(tool:name,body:body,zone:zone)]]]
                } else {
                    var reply: [String:Any] = ["content":[["type":"text","text":body]]]
                    // Detailed: the same JSON also as structuredContent, for clients on 2025-06-18 or later.
                    if negotiated >= "2025-06-18", let object = try? JSONSerialization.jsonObject(with:Data(body.utf8)) as? [String:Any] { reply["structuredContent"] = object }
                    result = reply
                }
                } catch let failure where resource == nil && !(failure is MCPProtocolError) {
                    // A tool that ran and failed: the model reads why and what to do next (MCP: isError tool results).
                    result = ["content":[["type":"text","text":AssistantCatalog.toolErrorMessage(failure,tool:name)]],"isError":true]
                }
                // claude/recall-1004: the AI app's tool list is older than this copy: the note comes first.
                if resource == nil, let notice = ToolListState.notice, var reply = result as? [String:Any], let content = reply["content"] as? [[String:Any]] {
                    reply["content"] = [["type":"text","text":notice]] + content
                    result = reply
                }
            default: throw MCPProtocolError(code: -32601, message: "Unsupported method")
            }
            let reply: [String:Any] = ["jsonrpc":"2.0","id":id,"result":result]
            print(String(decoding:try JSONSerialization.data(withJSONObject:reply,options:[.sortedKeys]),as:UTF8.self))
            if let usage { fflush(stdout); MCPUsage.record(home: store.home, tool: usage.tool, startedAt: startedAt, resultCount: usage.count) }
        } catch {
            let reply: [String:Any] = ["jsonrpc":"2.0","id":id,"error":(error as? MCPProtocolError).map { ["code":$0.code,"message":$0.message] as [String:Any] } ?? ["code":-32000,"message":AssistantCatalog.errorMessage(error)]]
            if let data = try? JSONSerialization.data(withJSONObject:reply) { print(String(decoding:data,as:UTF8.self)) }
        }
        fflush(stdout)
    }
}
/// `mac-mem connect <app>`, `mac-mem disconnect <app>` and `mac-mem connections` (Settings › Connections runs
/// the first two). Shows what will be written, and where, before writing; asks unless --yes. Never prints a key.
func connectCommand() throws -> Int32 {
    var rest = Array(args.dropFirst())
    let yes = rest.contains("--yes"); rest.removeAll { $0 == "--yes" }
    let asJSON = rest.contains("--json"); rest.removeAll { $0 == "--json" }
    let dryRun = rest.contains("--dry-run"); rest.removeAll { $0 == "--dry-run" }
    // --user-home (for checks) replaces the whole world: settings files under it, and apps only in its Applications.
    let env = userHomeArgument.map { value -> AIAppConnectEnvironment in
        let user = URL(fileURLWithPath: value, isDirectory: true)
        return AIAppConnectEnvironment(userHome: user, applicationFolders: [user.appendingPathComponent("Applications", isDirectory: true)])
    } ?? .live
    // AI apps start mac-mem without DayDream's environment: an unusual history folder is written as --home.
    let pinned = (homeArgument ?? ProcessInfo.processInfo.environment["MAC_MEM_HOME"].flatMap { $0.isEmpty ? nil : $0 })
        .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).standardizedFileURL.resolvingSymlinksInPath()
    let reader = try? MemoryStore(home: home)
    func writableStore() throws -> MemoryStore {
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent("memory.sqlite").path) else { throw AIAppConnectError.storeMissing }
        return try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    }
    func emit(_ value: [String: Any]) throws {
        print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
    }
    if command == "connections" {
        guard rest.isEmpty else { throw MemError.invalid("Use: mac-mem connections [--json]") }
        let rows = AIAppConnect.apps.map { app -> [String: Any] in
            let state = AIAppConnect.status(app, env: env, command: executable, home: pinned) { key in reader?.connectKeyWorks(app, key: key) }
            var row: [String: Any] = ["app": app.id, "name": app.name, "state": state.label, "file": AIAppConnect.display(AIAppConnect.file(app, env), env)]
            if case .needsAttention(let attention) = state { row["reason"] = attention.reason(app) }
            return row
        }
        if asJSON { try emit(["apps": rows]) } else {
            for row in rows { print("\(row["name"]!): \(row["state"]!)" + (row["reason"].map { " (\($0))" } ?? "") + "\n  \(row["file"]!)") }
        }
        return 0
    }
    guard rest.count == 1 else { throw MemError.invalid("Use: mac-mem \(command) <app> [--yes] [--json] [--dry-run]. Apps: \(AIAppConnect.apps.map(\.id).joined(separator: ", "))") }
    let app = try AIAppConnect.app(rest[0])
    let action: AIAppConnectAction = command == "connect" ? .connect : .disconnect
    let plan = try AIAppConnect.plan(action, app, env: env, command: executable, home: pinned) { key in reader?.connectKeyWorks(app, key: key) }
    let file = AIAppConnect.display(plan.file, env)
    if dryRun || (!asJSON && plan.writes) {
        if asJSON {
            var value: [String: Any] = ["app": app.id, "action": action.rawValue, "outcome": plan.outcome.rawValue, "file": file,
                                        "fileExists": plan.fileExists, "reviewedSHA256": plan.reviewedSHA256, "notes": plan.notes]
            if let backup = plan.backup { value["backup"] = AIAppConnect.display(backup, env) }
            if let preview = plan.entryPreview { value["entry"] = preview }
            try emit(value)
        } else {
            print("\(action == .connect ? "Connect" : "Disconnect") \(app.name)\nFile: \(file)")
            for note in plan.notes { print("- " + note) }
            if let preview = plan.entryPreview, plan.writes { print("It writes:\n" + preview) }
        }
        if dryRun { return 0 }
    }
    // The file must still be the one just shown (or, from Settings, the one reviewed there).
    let expected = expectedConfigSHA256 ?? plan.reviewedSHA256
    if plan.writes && !yes {
        guard isatty(STDIN_FILENO) == 1 else {
            print("Nothing was written. Run again with --yes to write it.")
            return 2
        }
        print("Write this? Type yes to continue: ", terminator: "")
        fflush(stdout)
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(), ["yes", "y"].contains(answer) else {
            print("Nothing was written.")
            return 3
        }
    }
    let result: AIAppConnectResult
    switch action {
    case .connect:
        result = try AIAppConnect.connect(app, env: env, command: executable, home: pinned, expectedSHA256: expected,
            verify: { key in reader?.connectKeyWorks(app, key: key) },
            grant: { try writableStore().connectGrant(app) }, revoke: { try writableStore().connectRevoke(app) })
    case .disconnect:
        result = try AIAppConnect.disconnect(app, env: env, command: executable, home: pinned, expectedSHA256: expected,
            revoke: { if FileManager.default.fileExists(atPath: home.appendingPathComponent("memory.sqlite").path) { try writableStore().connectRevoke(app) } })
    }
    // claude/rel-017c: ChatGPT also gets DayDream's skill (~/.codex/skills/daydream) and loses it again on Disconnect. A
    // skill that can't be written never undoes the connection; one the person changed is left alone.
    var skill: AgentSkill.Outcome?
    if app.id == "chatgpt" {
        skill = (try? (action == .connect ? AgentSkill.install(env) : AgentSkill.remove(env))) ?? .keptTheirs
    }
    if asJSON {
        var value: [String: Any] = ["app": app.id, "action": action.rawValue, "outcome": result.plan.outcome.rawValue, "wrote": result.wrote,
                                    "file": file, "message": result.message]
        if let skill { value["skill"] = skill.rawValue }
        if let backup = result.backup { value["backup"] = AIAppConnect.display(backup, env) }
        try emit(value)
    } else {
        print(result.message + (result.backup.map { "\nBackup: " + AIAppConnect.display($0, env) } ?? ""))
    }
    return 0
}

do {
    try companionIdentity.get().validate()
    if ["connect", "disconnect", "connections"].contains(command) { exit(try connectCommand()) }
    if command == "help" { print("Canonical reads: actions [--start ISO --end ISO --app NAME --after CURSOR --batch-limit N], day --day YYYY-MM-DD --timezone IANA, current-context, open macmem://RESOURCE. These use existing detail/context grants or explicit local-owner mode.") }
    if command.hasPrefix("migration-") {
        guard let exactHome=homeArgument, exactHome.hasPrefix("/") else { throw MemError.invalid("Migration requires an exact absolute --home destination") }
        if command == "migration-init" {
            guard local, !FileManager.default.fileExists(atPath:home.path) else { throw MemError.invalid("Migration init requires --local and a NEW isolated destination") }
            let requestedPolicy=try migrationPolicyFile.map {
                guard $0.hasPrefix("/") else { throw MemError.invalid("Exact absolute policy file required") }
                return try JSONDecoder().decode(PrivacySettings.self,from:LegacyMigration.file(URL(fileURLWithPath:$0),limit:65536))
            }
            let target=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
            try target.initializeMigrationDestination()
            if let requestedPolicy {
                // This command requires --local, an exact supplied policy file,
                // and a NEW empty destination. It cannot shorten existing data.
                if requestedPolicy.retention.isShorter(than:try target.policy().retention) {
                    let review=try target.prepareRetentionChange(requestedPolicy.retention)
                    guard review.affectedActionCount==0,review.affectedOriginalCount==0 else {throw MemError.denied}
                    _=try target.confirmRetentionChange(review.id,confirmed:true)
                }
                try target.updatePolicy(requestedPolicy)
            }
            try output(["status":"isolated_destination_initialized","policySHA256":fingerprint(try json(target.policy()))]); exit(0)
        }
        guard FileManager.default.fileExists(atPath:home.appendingPathComponent("memory.sqlite").path) else { throw MemError.missing }
        if command.hasPrefix("migration-stage-") || command.hasPrefix("migration-adoption-") {
            guard local,FilePaths.unlinked(home),
                  !FilePaths.same(home,MemPaths.home()) else {
                throw MemError.invalid("Staged CLI import requires --local and a separate physical trial destination, not the default store")
            }
            let readOnly = command == "migration-stage-status"
            let target=try MemoryStore(home:home,writable:!readOnly,automaticallySyncSearch:false)
            // Uses the existing canonical staging lifecycle, not a second store
            // schema. Every write rechecks OFF, scope, revisions and source pins.
            if command == "migration-stage-prepare" {
                guard let path=migrationSnapshot,path.hasPrefix("/"),let hash=migrationHash,
                      let stage=migrationStage,stage.hasPrefix("/") else {throw MemError.invalid("Exact snapshot, hash and NEW sibling staging home required")}
                try output(target.prepareStagedOnboardingImport(snapshotURL:URL(fileURLWithPath:path),expectedHash:hash,stagingURL:URL(fileURLWithPath:stage)))
            } else {
                guard let id=migrationImportID else {throw MemError.invalid("Exact --import-id required")}
                switch command {
                case "migration-stage-status": try output(target.stagedOnboardingImport(id:id))
                case "migration-stage-step": try output(target.stageOnboardingImport(id:id,confirmed:confirmMigration,acceptPolicyExclusions:acceptMigrationExclusions,limit:migrationBatchLimit))
                case "migration-stage-cancel":
                    try target.cancelStagedOnboardingImport(id:id)
                    try output(["status":"cancelled","effect":"destination history unchanged; stage and export retained"])
                case "migration-adoption-review": try output(target.prepareOnboardingAdoption(id:id))
                case "migration-adoption-confirm": try output(target.confirmOnboardingAdoption(id:id,confirmed:confirmMigration))
                default: throw MemError.invalid("Unknown staged migration command")
                }
            }
            exit(0)
        }
        if ["migration-dry-run","migration-import"].contains(command) {
            guard local, let path=migrationSnapshot, path.hasPrefix("/"), let hash=migrationHash else { throw MemError.invalid("Requires --local, exact --snapshot and --snapshot-sha256") }
            let snapshotURL=URL(fileURLWithPath:path)
            let snapshot=try LegacyMigration.load(snapshotURL,expected:hash)
            let target=try MemoryStore(home:home,writable:command == "migration-import",automaticallySyncSearch:false)
            let manifest=try target.migrationDryRun(snapshot:snapshot,hash:hash,root:snapshotURL.deletingLastPathComponent())
            if command == "migration-dry-run" { try output(manifest) }
            else {
                guard let policyHash=migrationPolicyHash else { throw MemError.invalid("Pin --policy-sha256 from the dry run") }
                guard acceptMigrationExclusions || !manifest.counts.keys.contains(where: { $0.hasPrefix("excluded") }) else { throw MemError.invalid("Dry run has excluded records; review and explicitly --accept-exclusions before import") }
                try output(target.importMigration(snapshot:snapshot,hash:hash,policyHash:policyHash,root:snapshotURL.deletingLastPathComponent(),limit:migrationBatchLimit))
            }
            exit(0)
        }
        let target=try MemoryStore(home:home)
        try authorize(target,"detail")
        if command == "migration-original", args.count == 2 {
            let result=try target.migrationOriginal(args[1]); try authorize(target,"detail"); try output(result)
        } else if command == "migration-period", let start=searchStart.flatMap(timestamp), let end=searchEnd.flatMap(timestamp), start < end {
            let result=try target.migratedPeriod(start:start,end:end,app:searchApp,after:eventCursor,limit:migrationBatchLimit)
            try authorize(target,"detail"); try output(result)
        } else { throw MemError.invalid("Unknown migration command or missing period bounds") }
        exit(0)
    }
    if command == "version" { try output(["name":"DayDream","version":companionIdentity.get().version,"distribution":companionIdentity.get().manifest == nil ? "standalone development binary; not Sparkle-managed" : "app-bundled CLI/MCP"]); exit(0) }
    if command == "search-config" {
        guard local, homeArgument != nil else { throw MemError.denied }
        try output(TypesenseConfiguration(home:home,port:8108,searchKeyFile:home.appendingPathComponent("search.key").path,syncKeyFile:home.appendingPathComponent("sync.key").path))
        exit(0)
    }
    if command == "verify-update-signature" {
        guard args.count == 4, let signature=Data(base64Encoded:args[2]), let key=Data(base64Encoded:args[3]),
              UpdateConfiguration.verifies(data:try Data(contentsOf:URL(fileURLWithPath:args[1])),signature:signature,publicKey:key) else { throw MemError.invalid("Update signature rejected") }
        print("Update archive signature verified"); exit(0)
    }
    if command == "help" { print("DayDream command-line tool\nmac-mem [--home DIR] [--local | --client ID --recipient ID] status|doctor|context|search TEXT|read ID|demo|writer|grant|revoke|grant-typed-words|revoke-typed-words|delete ID|mcp\nTyped text: every CLI and MCP reply says where and about how much was typed, never the words. grant-typed-words records a request to let one AI app see exact words. This version of the DayDream app has no screen to confirm it, so the AI app keeps seeing only where and about how much was typed.\nSearch: --app NAME_OR_BUNDLE --start ISO8601 --end ISO8601 --search-report\nLocal owner with explicit --home: search-config (disabled template), search-sync (one bounded page), search-rebuild (derived index only). No command installs or starts Typesense.\nMigration: --local --home NEW_DIR migration-init [--policy-file FILE]; migration-dry-run --snapshot FILE --snapshot-sha256 HASH; migration-import additionally requires --policy-sha256 HASH, accepts --batch-limit 1..500 and --accept-exclusions. Isolated destinations only. Detail reads: migration-period --start ISO8601 --end ISO8601 [--app APP --after CURSOR]; migration-original ID.\nAI apps: connections [--json]; connect APP and disconnect APP [--yes] [--json] [--dry-run]. APP is one of \(AIAppConnect.apps.map(\.id).joined(separator: ", ")). Shows what it writes to the AI app's settings file, and where, then asks. Keeps a copy of the file. Never prints the key. --user-home DIR looks under DIR instead of your home folder (for testing).\nWebsite typing: --local web-typing-refusals shows how often each outcome began (counts only).\nStart capture only from the DayDream app. No CLI command requests OS permissions or switches a legacy collector."); exit(0) }
    if command == "doctor" {
        let present = FileManager.default.fileExists(atPath:home.appendingPathComponent("memory.sqlite").path)
        var health = present ? try withNoteBacklog(MemoryStore(home:home)) : ["capture":"off","reason":"Memory has not been initialized; no capture started."]
        health["memory_home"] = home.path
        health["database"] = present ? "present" : "absent"
        health["automatic_host"] = "MCP and the before-turn host adapter are available; each requires explicit host configuration and a recipient grant"
        health["legacy_replacement"] = "requires explicit launcher manifest and reader configuration; no automatic switchover"
        health["os_permissions"] = "not queried by CLI"
        try output(health); exit(0)
    }
    // fix/chrome-root: the app's always-on website typing tally (owner build): how often each outcome began, never a
    // key, word, length, site or window. Local owner only; read-only (the app's own defaults).
    if command == "web-typing-refusals" {
        guard local else { throw MemError.denied }
        let read = WebTypingRefusals.read()
        let value: [String: Any] = ["counts": read?.counts ?? [:], "since": read?.since ?? "never",
                                    "note": "Episodes, not keys: each count is how many times that outcome began; a new typing session (burst: Chrome keys after 3 s without one) counts every outcome again. join.privacy covers Incognito or Guest windows, sensitive fields and blocked sites without saying which."]
        print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        exit(0)
    }
    let writes = ["demo","writer","grant","revoke","grant-typed-words","revoke-typed-words","delete","search-sync","search-rebuild"].contains(command)
    if ["search-sync","search-rebuild"].contains(command) && !local { throw MemError.denied }
    if writes && homeArgument == nil { throw MemError.invalid("This acceptance build requires an explicit --home DIR for writes") }
    // An AI app's server holds its history only in the loop (ServedHistory), never here for the whole process.
    if command == "mcp" { mcp(try ServedHistory(home:home)); exit(0) }
    let store = try MemoryStore(home:home,writable:writes)
    // Safe typing: the CLI and MCP never attach a typing vault, so typed words
    // can't be opened here; every reply is summary-only by construction.
    guard store.typedVaultState == .unavailable else { throw MemError.denied }
    switch command {
    case "status", "doctor": try output(withNoteBacklog(store))
    case "actions":
        try authorize(store,"detail")
        let bounds=try searchQuery("",app:searchApp,start:searchStart,end:searchEnd)
        let result=try store.actions(start:bounds.start,end:bounds.end,app:bounds.app,after:eventCursor,limit:migrationBatchLimit)
        try authorize(store,"detail"); try output(result)
    case "day":
        try authorize(store,"detail")
        guard let day=actionDay, let timezone=actionTimezone else { throw MemError.invalid("Use --day YYYY-MM-DD --timezone IANA") }
        let result=try store.dayLayers(day:day,timezone:timezone,after:eventCursor,limit:migrationBatchLimit)
        try authorize(store,"detail"); try output(result)
    case "open":
        try authorize(store,"detail"); guard args.count == 2 else { throw MemError.invalid("Expected macmem resource URI") }
        let body=try store.openActionResource(args[1]); try authorize(store,"detail"); print(body)
    case "current-context":
        try authorize(store,"context"); let result=try store.currentActions(after:eventCursor); try authorize(store,"context"); try output(result)
    case "history-events":
        try authorize(store,includeEventText ? "detail" : "search")
        try output(store.legacyPage(after:eventCursor,includeText:includeEventText))
    case "history-validate":
        try authorize(store,includeEventText ? "detail" : "search")
        try output(["disclosureRevision":store.disclosureRevision(),"capture":store.captureStatus()["state"] ?? "off"])
    case "demo":
        for e in SyntheticActivity.records() { _ = try store.ingest(e) }
        let wait = DispatchSemaphore(value:0)
        var outcome: Result<Int,Error>?
        let worker = SummaryWorker(store:store); worker.schedule { outcome = $0; wait.signal() }; wait.wait()
        try output(["synthetic_records":3,"summaries":try outcome!.get()])
    case "writer": try output(["written":store.writePending()])
    case "grant": try output(["capability":store.grant(client:client,recipient:recipient,scopes:["context","search","detail"])])
    case "grant-typed-words":
        // Owner at the terminal. Exact typed words are never part of `grant`;
        // without the app's key this is only a request the DayDream app confirms.
        guard !client.isEmpty, !recipient.isEmpty else { throw MemError.invalid("Use --client ID --recipient ID") }
        let result=try store.grantTypedWords(client:client,recipient:recipient)
        try output(["status":result.rawValue,"note":result == .granted ? TypedAccessText.granted : TypedAccessText.pending])
    case "revoke-typed-words": try store.revokeTypedWords(client:client,recipient:recipient); try output(["exact_words":"off"])
    case "revoke": try store.revoke(client:client,recipient:recipient); try output(["revoked":true])
    case "delete": guard args.count == 2 else { throw MemError.invalid("Expected source ID") }; try store.delete(args[1]); try output(["deleted":true])
    case "context": try authorize(store,"context"); let result=try store.context(); try authorize(store,"context"); try output(result)
    case "validate": try authorize(store,"context"); try output(["policyRevision":store.policy().revision,"disclosureRevision":store.disclosureRevision(),"capture":store.captureStatus()["state"] ?? "off"])
    case "search":
        try authorize(store,"search")
        let report=try store.searchReport(searchQuery(args.dropFirst().joined(separator:" "),app:searchApp,start:searchStart,end:searchEnd,site:searchSite,after:eventCursor),forReader:false)
        try authorize(store,"search")
        if searchReport { try output(report) } else {
            // Keep the original stdout array contract. State is separate, never a fake hit.
            FileHandle.standardError.write(Data(("Search: \(report.backend), \(report.status), partial=\(report.partial)\n").utf8))
            try output(report.hits)
        }
    case "search-sync", "search-rebuild":
        guard local else { throw MemError.denied }
        try output(store.syncSearchIndex(rebuild:command == "search-rebuild"))
    case "read": try authorize(store,"detail"); guard args.count == 2 else { throw MemError.invalid("Expected source ID") }; try output(store.readerItem(args[1]))
    // agent-tools v2 (plan §6.3): the four tools as an AI app would read them, for the owner and the evals. Local owner
    // only and read-only: `mac-mem --local [--home DIR] [--timezone IANA] [--now ISO] agent-preview [--owner-preview]
    // <tool> ['<json arguments>']`. Typed words come from the running app's bridge only with --owner-preview.
    case "agent-preview":
        guard local else { throw MemError.denied }
        guard (2...3).contains(args.count) else { throw MemError.invalid("Use: mac-mem --local agent-preview [--owner-preview] <timeline|search|details|status> ['<json arguments>']") }
        let input = try args.count == 3 ? (JSONSerialization.jsonObject(with: Data(args[2].utf8)) as? [String:Any]).map { $0 } ?? { throw MemError.invalid("Arguments must be a JSON object") }() : [:]
        guard previewNow == nil || timestamp(previewNow!) != nil else { throw MemError.invalid("--now must be ISO-8601") }
        if let zone = actionTimezone, TimeZone(identifier: zone) == nil { throw MemError.invalid("--timezone must be an IANA time zone") }
        let started = Date()
        let output = AgentTools.run(name: args[1], arguments: input,
                                    context: agentContext(store, owner: ownerPreview, now: previewNow.flatMap(timestamp) ?? Date(), timezone: actionTimezone ?? TimeZone.current.identifier),
                                    access: nil)
        print(output.text)
        if ProcessInfo.processInfo.environment["DAYDREAM_AGENT_TIMING"] == "1" {
            FileHandle.standardError.write(Data(String(format: "agent-preview %@ %.1f ms\n", args[1], Date().timeIntervalSince(started) * 1000).utf8))
        }
        if output.isError { exit(1) }
    default: throw MemError.invalid("Unknown command. Use help.")
    }
} catch { FileHandle.standardError.write(Data((String(describing:error)+"\n").utf8)); exit(1) }
