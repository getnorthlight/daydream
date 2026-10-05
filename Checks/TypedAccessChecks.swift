import Foundation
import MemoryCore

/// Safe typing G (access slice): AI apps, the CLI and remote readers are
/// summary-only by default; exact words need a separate, MAC-signed
/// `typed-exact` grant and a process holding the key; the writer on this Mac
/// reads words while typing is on, a cloud writer never does.
///
/// Drives the real `mac-mem` binary built next to this checker (MCP over
/// stdin and CLI verbs) and scans every serialized reply for the fixture
/// words. Forged grants are written with /usr/bin/sqlite3, the way another
/// process on this Mac would. In-memory keys only; never the real Keychain.
/// Uses the real clock, because the MCP child reads with it.
func runTypedAccessChecks(home: URL) throws {
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("mac-mem")
    try check(FileManager.default.isExecutableFile(atPath: binary.path), "the mac-mem CLI/MCP binary is built next to the checks")
    let sqlite = "/usr/bin/sqlite3"
    try check(FileManager.default.isExecutableFile(atPath: sqlite), "sqlite3 is available to forge grants like another process would")
    let database = home.appendingPathComponent("memory.sqlite").path
    func refused(_ work: () throws -> Any) -> Bool { do { _ = try work(); return false } catch { return true } }

    func run(_ path: String, _ args: [String], capability: String = "", input: Data? = nil, toolset: ToolsetMode = .legacy) throws -> (status: Int32, output: String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = args
        var env = ProcessInfo.processInfo.environment; env["MAC_MEM_CAPABILITY"] = capability.isEmpty ? nil : capability
        // agent-tools v2: the summary-only scan below pins the 0.1.4 tools' replies; the v2 tools get their own scan.
        env[ToolsetMode.environmentKey] = toolset.rawValue
        process.environment = env
        let out = Pipe(), stdin = Pipe(); process.standardOutput = out; process.standardError = out; process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(input) }
        try stdin.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    func sql(_ statement: String) throws -> String {
        let result = try run(sqlite, [database, statement])
        guard result.status == 0 else { throw MemError.invalid("FAILED: sqlite3: \(result.output)") }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Fixture: sealed drafts, a build 4 plain-text row, a window title control

    let now = Date()
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    let keys = try attachTestVault(store)
    var consent = try store.policy(); consent.captureText = true; try store.updatePolicy(consent, now: now)
    let words = ["t-draft": "pricing page ships Friday quokkamarmalade", "t-second": "zebrafjord standup notes for Priya today"]
    let legacyWords = "legacyplumtart build four plain words"
    let secrets = ["quokkamarmalade", "zebrafjord", "legacyplumtart", "ships Friday", "standup notes for Priya"]
    let control = "titlecontrolword"
    func typed(_ id: String, _ seconds: Double) -> Evidence {
        Evidence(id: id, at: iso(now.addingTimeInterval(-seconds)), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes", title: "Pricing", text: words[id] ?? "", synthetic: true)
    }
    try check(try store.ingest(Evidence(id: "w-control", at: iso(now.addingTimeInterval(-6)), kind: "window.changed", app: "Notes", bundle: "com.apple.Notes", title: "Notes \(control)", synthetic: true), now: now)
              && store.ingest(typed("t-draft", 4), now: now) && store.ingest(typed("t-second", 3), now: now), "fixture: two sealed drafts and a window")
    // A build 4 row that still holds its words in plain text (waiting for the upgrade).
    let legacy = Evidence(id: "legacy-1", at: iso(now.addingTimeInterval(-5)), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes", title: "Pricing", text: legacyWords, synthetic: true)
    let legacyBody = try json(legacy)
    try check(!legacyBody.contains("'"), "fixture body is safe to quote for sqlite3")
    _ = try sql("INSERT INTO records VALUES('legacy-1','\(legacyBody)','\(fingerprint(legacyBody))')")
    try check(try store.hydrateTypedText("t-draft", disclosure: .owner, now: now) == words["t-draft"], "control: the owner opens the sealed words in the app process")
    let day = try DayScope.key(now, timezone: "UTC")

    // MARK: Grants: the CLI grant never includes exact words

    try check(refused { try store.grant(client: "x", recipient: "local", scopes: [MemoryStore.typedExactScope]) }
              && refused { try store.grant(client: "x", recipient: "local", scopes: ["context", "search", "detail", "typed-exact"]) }, "grant never issues typed-exact")
    let cliGrant = try run(binary.path, ["--home", home.path, "--client", "claude-code", "--recipient", "local", "grant"])
    let token = ((try? JSONSerialization.jsonObject(with: Data(cliGrant.output.utf8))) as? [String: String])?["capability"] ?? ""
    try check(cliGrant.status == 0 && !token.isEmpty && (try store.grantScopes(client: "claude-code", recipient: "local")) == ["context", "search", "detail"], "CLI grant issues context, search and detail only")
    let reader = TypedReader(client: "claude-code", recipient: "local", capability: token)
    try check(try store.typedDisclosure(for: reader) == .summary && store.typedWordsAccess(for: reader) == .summaryOnly && store.typedDisclosure(for: nil) == .summary, "every connected app starts summary-only")
    try check(try store.hydrateTypedText("t-draft", disclosure: .exact, reader: reader, now: now) == nil && store.hydrateTypedText("t-draft", disclosure: .exact, now: now) == nil, "exact without a signed grant opens nothing")
    try check(refused { try store.authorize(client: "claude-code", recipient: "local", capability: token, scope: MemoryStore.typedExactScope) }, "the typed-exact scope doesn't authorize without a grant")

    // MARK: MCP and CLI replies are summary-only (scan every serialized reply)

    func mcp(_ capability: String, client: String = "claude-code") throws -> String {
        func call(_ id: Int, _ name: String, _ arguments: [String: String] = [:]) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
        }
        func resource(_ id: Int, _ uri: String) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "method": "resources/read", "params": ["uri": uri]] }
        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            call(3, "status"), call(4, "context"), call(5, "current-context"),
            call(6, "search", ["query": ""]), call(7, "search", ["query": "", "app": "com.apple.Notes"]), call(8, "search", ["query": "quokkamarmalade"]),
            call(9, "read", ["id": "t-draft"]), call(10, "read", ["id": "t-second"]), call(11, "read", ["id": "legacy-1"]),
            call(12, "open", ["uri": "macmem://days/today.json"]), call(13, "open", ["uri": "macmem://days/\(day).json?timezone=UTC"]),
            call(14, "open", ["uri": ActionResources.actionURI("t-draft")]), call(15, "open", ["uri": ActionResources.actionURI("legacy-1")]),
            resource(16, "macmem://context/current"), resource(17, "macmem://current-context"), resource(18, "macmem://status"),
            call(19, "recap", ["when": "past 2 days"]), call(20, "recap", ["when": day]),
            // claude/summary-1003 (owner decision 2026-10-03): moment_details is the gated path for typed words. With no
            // DayDream app answering (this fixture runs none), it must carry no word either, only a typing_note.
            // claude/mcp-prompts-1003: 21 asks for the JSON (detailed); 22 is the concise default, which says the same in words.
            call(21, "moment_details", ["id": "t-draft", "response_format": "detailed"]), call(22, "moment_details", ["id": "t-draft"])]
        let input = try requests.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try store.setCaptureState("recording", reason: "synthetic access fixture", now: Date())
        let result = try run(binary.path, ["--home", home.path, "--client", client, "--recipient", "local", "mcp"], capability: capability, input: Data(input.utf8))
        try check(result.status == 0 && result.output.split(separator: "\n").count == requests.count && !result.output.contains("\"error\""), "MCP answered every request without an error (\(client))")
        return result.output
    }
    func leaked(_ text: String) -> [String] { (secrets + [legacyWords]).filter { text.contains($0) } }

    let summaryMCP = try mcp(token)
    // agent-tools v2: the same fixture through the v2 tools (no DayDream app answers, so no typed words can be shared).
    // A search's own query is echoed back, so the scan looks at every reply except that echo.
    do {
        func call(_ id: Int, _ name: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
        }
        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            call(3, "status"), call(4, "timeline"), call(5, "timeline", ["detail": "full", "format": "json"]),
            call(6, "search", ["query": "pricing"]), call(7, "search", ["query": "Notes", "format": "json"]),
            call(8, "search", ["query": "quokkamarmalade"]), call(9, "search", ["query": "", "when": "today"])]
        let input = try requests.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try store.setCaptureState("recording", reason: "synthetic access fixture", now: Date())
        let result = try run(binary.path, ["--home", home.path, "--client", "claude-code", "--recipient", "local", "mcp"], capability: token, input: Data(input.utf8), toolset: .v2)
        let lines = result.output.split(separator: "\n").map(String.init)
        try check(result.status == 0 && lines.count == requests.count && !result.output.contains("\"error\""), "v2 MCP answered every request without an error")
        let scanned = lines.filter { !$0.contains("\"id\":8,") && !$0.contains("\"id\":8}") }.joined()
        try check(scanned.contains(control), "control: v2 replies carry real content (a window title)")
        try check(leaked(scanned).isEmpty && !(lines.first { $0.contains("\"id\":8,") || $0.contains("\"id\":8}") } ?? "").contains("standup"),
                  "no v2 reply (status, timeline, search) carries a typed word without the DayDream app")
        try check(lines.contains { ($0.contains("\"id\":8,") || $0.contains("\"id\":8}")) && $0.contains("Typed words: unavailable while DayDream is closed.") },
                  "v2 search without the DayDream app says typed words weren't searched, never a bare no-match")
    }
    try check(summaryMCP.contains(control) && summaryMCP.contains("Typed in Notes"), "control: MCP replies carry real content (a window title and typed-draft lines)")
    try check(leaked(summaryMCP).isEmpty, "no MCP reply (status, context, current-context, search, read, open, recap, resources) carries a typed word")
    // owner decision 2026-10-03: tools/list (id 2) names moment_details' typing_note field, and moment_details (id 21)
    // gives one (no app answered); every other reply still says nothing about a permission.
    let replyLines = summaryMCP.split(separator: "\n").map(String.init)
    let others = replyLines.filter { !$0.contains("\"id\":2,") && !$0.contains("\"id\":21,") && !$0.contains("\"id\":2}") && !$0.contains("\"id\":21}") }
    try check(summaryMCP.contains("exact words not shared with AI apps") && !others.joined().contains("typing_note") && others.count == replyLines.count - 2,
              "MCP says where and how much was typed, and nothing about a permission this app lacks")
    try check(replyLines.contains { ($0.contains("\"id\":21,") || $0.contains("\"id\":21}")) && $0.contains("typing_note") }, "moment_details without the DayDream app: no words, a plain typing_note")
    try check(replyLines.contains { ($0.contains("\"id\":22,") || $0.contains("\"id\":22}")) && $0.contains("isn't open") && $0.contains("Typed in Notes") },
              "concise moment_details without the DayDream app: where and how much, and why there are no words")

    func cli(_ args: [String]) throws -> String {
        try store.setCaptureState("recording", reason: "synthetic access fixture", now: Date())
        let result = try run(binary.path, ["--home", home.path, "--client", "claude-code", "--recipient", "local"] + args, capability: token)
        try check(result.status == 0, "CLI \(args.first ?? "") succeeds")
        return result.output
    }
    var cliOutput = ""
    for args in [["status"], ["context"], ["current-context"], ["search", "--search-report", "--app", "com.apple.Notes"], ["search", "quokkamarmalade"],
                 ["read", "t-draft"], ["read", "legacy-1"], ["actions"], ["day", "--day", day, "--timezone", "UTC"],
                 ["open", "macmem://days/\(day).json?timezone=UTC"], ["open", ActionResources.actionURI("t-second")], ["open", ActionResources.actionURI("legacy-1")],
                 ["history-events", "--include-text"], ["history-events"], ["validate"]] {
        cliOutput += try cli(args) + "\n"
    }
    try check(cliOutput.contains(control) && cliOutput.contains("legacy-1") && cliOutput.contains("t-draft"), "control: CLI replies carry real content")
    try check(leaked(cliOutput).isEmpty, "no CLI reply (status, context, current-context, search, read, actions, day, open, history-events --include-text) carries a typed word")
    try check(cliOutput.contains("\"typed\":\"Typed in Notes, a sentence (exact words not shared with AI apps)\""), "history-events --include-text gives a word-count line instead of the words")
    let cliRead = try cli(["read", "legacy-1"])
    try check(cliRead.contains("\"text\":\"\"") && cliRead.contains("Typed in Notes, a sentence"), "CLI read of a build 4 plain-text row shows no words")

    // MARK: A separate owner action for exact words, signed with the key

    try check(refused { try store.grantTypedWords(client: "nobody", recipient: "local") }, "exact words need an existing connection first")
    let request = try cli(["grant-typed-words"])
    try check(request.contains("pending_app_confirmation") && (try store.typedWordsRequests().map(\.client)) == ["claude-code"], "CLI grant-typed-words only records a request for the app")
    try check(try store.typedDisclosure(for: reader) == .summary && (store.grantScopes(client: "claude-code", recipient: "local") ?? []).contains(MemoryStore.typedExactScope) == false, "a pending request grants nothing")
    let keyless = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    try check(refused { try keyless.confirmTypedWords(client: "claude-code", recipient: "local") } && keyless.typedVaultState == .unavailable, "only the DayDream app (with the key) can confirm it")
    let revisionBefore = try store.disclosureRevision()
    try store.confirmTypedWords(client: "claude-code", recipient: "local")
    try check(try store.typedWordsRequests().isEmpty && (store.grantScopes(client: "claude-code", recipient: "local") ?? []).contains(MemoryStore.typedExactScope) && store.disclosureRevision() != revisionBefore, "the app confirms: the grant gains typed-exact and readers see a new disclosure revision")
    try check(try store.typedWordsAccess(for: reader) == .exact && store.typedDisclosure(for: reader) == .exact, "the allowed app verifies in the app process")
    try check(try store.hydrateTypedText("t-draft", disclosure: .exact, reader: reader, now: now) == words["t-draft"], "exact opens the words for that app, in the app process")
    try store.authorize(client: "claude-code", recipient: "local", capability: token, scope: MemoryStore.typedExactScope)
    try check(true, "the signed typed-exact scope authorizes where the key is")
    let appItem = try store.assistantItem("t-draft", now: now, reader: reader)
    try check(appItem?["text"] == words["t-draft"] && appItem?["text_is"] == TypedAccessText.exactTextIs && appItem?["snippet"]?.contains("quokkamarmalade") == true, "read in the app process gives the allowed app the exact words")
    try check(try store.assistantItem("legacy-1", now: now, reader: reader)?["text"] == nil, "build 4 plain text is never shown, even to an allowed app")
    let other = try store.grant(client: "codex", recipient: "local", scopes: ["context", "search", "detail"])
    let otherReader = TypedReader(client: "codex", recipient: "local", capability: other)
    try check(try store.assistantItem("t-draft", now: now, reader: otherReader)?["text"] == nil && store.hydrateTypedText("t-draft", disclosure: .exact, reader: otherReader, now: now) == nil, "exact words are per app: another app stays summary-only")
    try check(try store.hydrateTypedText("t-draft", disclosure: .exact, reader: TypedReader(client: "claude-code", recipient: "local", capability: "wrong-token"), now: now) == nil, "a wrong token never opens words")

    // Where there is no key (MCP, CLI), even the allowed app gets a summary.
    let reading = try MemoryStore(home: home)
    try check(reading.typedVaultState == .unavailable && reading.typedWordsAccess(for: reader) == .appOnly && reading.typedDisclosure(for: reader) == .summary, "a reader process can't verify or use the permission")
    try check(refused { try reading.authorize(client: "claude-code", recipient: "local", capability: token, scope: MemoryStore.typedExactScope) }, "typed-exact never authorizes in a process without the key")
    let allowedMCP = try mcp(token)
    try check(leaked(allowedMCP).isEmpty, "MCP replies to the allowed app still carry no typed word (no key in that process)")
    try check(allowedMCP.contains(TypedAccessText.appOnly), "read tells the allowed app the exact words are only in the DayDream app")
    try check(leaked(try cli(["read", "t-draft"])).isEmpty, "CLI read for the allowed app carries no typed word")

    // MARK: Forged scopes are ignored

    let forgerToken = try store.grant(client: "forger", recipient: "local", scopes: ["context", "search", "detail"])
    let forger = TypedReader(client: "forger", recipient: "local", capability: forgerToken)
    let forgerWhere = "json_extract(body,'$.client')='forger'"
    let validMAC = try sql("SELECT json_extract(body,'$.mac') FROM grants WHERE json_extract(body,'$.client')='claude-code'")
    try check(!validMAC.isEmpty, "the signed grant carries a MAC")
    func forgedDenied(_ label: String) throws {
        try check(try store.typedWordsAccess(for: forger) == .summaryOnly && store.typedDisclosure(for: forger) == .summary
                  && store.hydrateTypedText("t-draft", disclosure: .exact, reader: forger, now: now) == nil
                  && store.assistantItem("t-draft", now: now, reader: forger)?["text"] == nil
                  && refused { try store.authorize(client: "forger", recipient: "local", capability: forgerToken, scope: MemoryStore.typedExactScope) }, label)
        try store.authorize(client: "forger", recipient: "local", capability: forgerToken, scope: "detail")
    }
    _ = try sql("UPDATE grants SET body=json_set(body,'$.scopes',json('[\"context\",\"detail\",\"search\",\"typed-exact\"]')) WHERE \(forgerWhere)")
    try forgedDenied("a typed-exact scope written straight into SQL is ignored (other scopes still work)")
    _ = try sql("UPDATE grants SET body=json_set(body,'$.mac','\(Data(repeating: 7, count: 32).base64EncodedString())') WHERE \(forgerWhere)")
    try forgedDenied("a made-up MAC is ignored")
    _ = try sql("UPDATE grants SET body=json_set(body,'$.mac','\(validMAC)') WHERE \(forgerWhere)")
    try forgedDenied("a MAC copied from another app's grant is ignored")
    // Taking over the signed grant with a token the attacker knows breaks its MAC.
    let signedBody = try sql("SELECT body FROM grants WHERE json_extract(body,'$.client')='claude-code'")
    _ = try sql("UPDATE grants SET body=json_set(body,'$.capabilityHash','\(fingerprint(forgerToken))') WHERE json_extract(body,'$.client')='claude-code'")
    let hijack = TypedReader(client: "claude-code", recipient: "local", capability: forgerToken)
    try check(try store.typedDisclosure(for: hijack) == .summary && store.hydrateTypedText("t-draft", disclosure: .exact, reader: hijack, now: now) == nil, "swapping the token hash on a signed grant voids its exact-words scope")
    _ = try sql("UPDATE grants SET body='\(signedBody)' WHERE json_extract(body,'$.client')='claude-code'")
    try check(try store.typedDisclosure(for: reader) == .exact, "the untouched signed grant still verifies")
    _ = try sql("UPDATE grants SET body=json_set(body,'$.scopes',json('[\"context\",\"detail\",\"search\",\"typed-exact\"]')) WHERE json_extract(body,'$.client')='codex'")
    try check(try (keyless.grantScopes(client: "codex", recipient: "local") ?? []).contains("typed-exact") && store.typedDisclosure(for: otherReader) == .summary, "a scope added by a process without the key never verifies")

    // MARK: Remote reads: none left (owner/v1 merge)
    // sat/v1 removed the SSH remote responder (`MemoryStore.remoteRead` and the CLI's `remote-read`),
    // so no remote path exists that could carry typed words. The typing-safe checks here tested that
    // path refused typed-exact and carried no typed word; they now pin that the path is gone: the
    // packaged CLI refuses `remote-read` for an app allowed exact words, and prints no typed word.
    try store.setCaptureState("recording", reason: "synthetic access fixture", now: Date())
    for body: [String: Any] in [["access": "typed-exact", "operation": "state"],
                                ["access": "detail", "operation": "read", "resource": ActionResources.actionURI("t-second")]] {
        let remoteCLI = try run(binary.path, ["--home", home.path, "--client", "claude-code", "--recipient", "local", "remote-read"], capability: token,
                                input: try JSONSerialization.data(withJSONObject: body))
        try check(remoteCLI.status != 0 && !remoteCLI.output.contains("Typed a draft") && leaked(remoteCLI.output).isEmpty,
                  "the remote responder is gone: the CLI refuses remote-read (\(body["access"]!)) and prints no typed word")
    }
    let cliSource = (try? String(contentsOfFile: "Sources/MacMemCLI/main.swift", encoding: .utf8)) ?? ""
    let coreSources = ((try? FileManager.default.contentsOfDirectory(atPath: "Sources/MemoryCore")) ?? []).filter { $0.hasSuffix(".swift") }
        .map { (try? String(contentsOfFile: "Sources/MemoryCore/" + $0, encoding: .utf8)) ?? "" }.joined()
    try check(!cliSource.isEmpty && !coreSources.isEmpty && !cliSource.contains("\"remote-read\"") && !coreSources.contains("func remoteRead("),
              "no remote read entry point is left in the CLI or the store")

    // MARK: Writers: summaries on this Mac read the words while typing is on; cloud summaries only while Cloud is chosen

    // writer/v2: the "Let summaries read what you type" picker is gone; the saved value is ignored.
    try check(try store.typedTextPolicy().shareWithSummaries == .off && store.typedTextPolicy().consented && store.policy().captureText
              && store.hydrateTypedText("t-draft", disclosure: .localWriter, now: now) == words["t-draft"]
              && store.hydrateTypedText("t-draft", disclosure: .cloudWriter, now: now) == nil, "typing on, no writer chosen: the writer on this Mac reads the words (saved sharing Off is ignored), the cloud writer nothing")
    // summaries/v3 (owner 2026-09-27, decision 8 reversed): the cloud writer reads the words only while Cloud is the chosen
    // writer (the app saves "cloud" only after the v2 notice); This Mac only and off give it nothing.
    try store.setSummaryWriter("cloud")
    try check(try store.hydrateTypedText("t-draft", disclosure: .cloudWriter, now: now) == words["t-draft"], "Cloud chosen, typing on: the cloud writer reads the words")
    try store.setSummaryWriter("local")
    try check(try store.hydrateTypedText("t-draft", disclosure: .cloudWriter, now: now) == nil && store.hydrateTypedText("t-draft", disclosure: .localWriter, now: now) == words["t-draft"], "This Mac only: the cloud writer reads nothing")
    try store.setSummaryWriter("off")
    try check(try store.hydrateTypedText("t-draft", disclosure: .cloudWriter, now: now) == nil, "summaries off: the cloud writer reads nothing")
    try check(TypedWriterKind.local.disclosure == .localWriter && TypedWriterKind.cloud.disclosure == .cloudWriter, "writer kinds map to their disclosures")
    let pending = try store.prepareNote(kind: "day", day: day, timezone: "UTC", now: now)
    let revisions = Dictionary(uniqueKeysWithValues: pending.actions.map { ($0.id, $0.revision) })
    try check(pending.actionCount == pending.actions.count && !refused { try store.validatePreparedNote(pending.id, revisions: revisions, now: now) }, "control: a prepared writer request validates")
    try check(pending.actions.filter { $0.kind == "keyboard.text_input" }.allSatisfy { !$0.description.contains("quokkamarmalade") && !$0.description.contains("zebrafjord") }, "stored writer input holds word counts, never words")
    var policy = try store.typedTextPolicy(); policy.shareWithSummaries = .localAndCloud
    try check(refused { try store.updateTypedTextPolicy(policy, now: now) } && refused { try store.updateTypedTextPolicy(policy, confirmed: true, now: now) }
              && (try store.typedTextPolicy().shareWithSummaries) == .off, "saving the removed This Mac and cloud value is refused, confirmed or not")
    policy.shareWithSummaries = .localOnly; try store.updateTypedTextPolicy(policy, now: now)
    try check(try store.hydrateTypedText("t-draft", disclosure: .cloudWriter, now: now) == nil, "an old This Mac only value never lets the cloud writer read")
    policy.shareWithSummaries = .off; try store.updateTypedTextPolicy(policy, now: now)
    try check(try keyless.hydrateTypedText("t-draft", disclosure: .cloudWriter, now: now) == nil && keyless.hydrateTypedText("t-draft", disclosure: .localWriter, now: now) == nil, "never outside the app process")
    keys.locked = true; _ = try store.reconcileTypedVault(now: now)
    try check(try store.hydrateTypedText("t-draft", disclosure: .cloudWriter, now: now) == nil && store.hydrateTypedText("t-draft", disclosure: .localWriter, now: now) == nil, "a locked Keychain gives writers nothing")
    keys.locked = false; _ = try store.reconcileTypedVault(now: now)
    var typingOff = try store.policy(); typingOff.captureText = false; try store.updatePolicy(typingOff, now: now)
    try store.setSummaryWriter("cloud")
    try check(try store.hydrateTypedText("t-draft", disclosure: .localWriter, now: now) == nil && store.hydrateTypedText("t-draft", disclosure: .cloudWriter, now: now) == nil,
              "typing switched off: neither writer reads anything, Cloud chosen or not")
    try store.setSummaryWriter("off")
    typingOff.captureText = true; try store.updatePolicy(typingOff, now: now)
    try check(try store.hydrateTypedText("t-draft", disclosure: .localWriter, now: now) == words["t-draft"], "typing on again: it reads again")

    // MARK: Revoke, re-grant, Forget

    try store.revokeTypedWords(client: "claude-code", recipient: "local")
    try check(try store.typedDisclosure(for: reader) == .summary && !(store.grantScopes(client: "claude-code", recipient: "local") ?? []).contains("typed-exact")
              && store.grantScopes(client: "claude-code", recipient: "local") == ["context", "detail", "search"], "turning exact words off keeps the connection, summary-only")
    try check(try keyless.grantTypedWords(client: "claude-code", recipient: "local", now: now) == .pendingAppConfirmation, "a new request from a keyless process")
    let renewed = try store.grant(client: "claude-code", recipient: "local", scopes: ["context", "search", "detail"])
    try check(refused { try store.confirmTypedWords(client: "claude-code", recipient: "local") } && (try store.typedWordsRequests()).isEmpty, "a new token voids the old request")
    try check(try store.grantTypedWords(client: "claude-code", recipient: "local", now: now) == .granted, "in the app the owner action signs at once")
    try check(try store.typedDisclosure(for: TypedReader(client: "claude-code", recipient: "local", capability: renewed)) == .exact, "the renewed connection is allowed")
    let signed = try sql("SELECT body FROM grants WHERE json_extract(body,'$.client')='claude-code'")
    try store.forgetTypedText(confirmed: true, now: now)
    try check(!((try store.grantScopes(client: "claude-code", recipient: "local")) ?? []).contains("typed-exact"), "Forget removes exact-word permissions")
    try store.setUpTypedVault(now: now)
    _ = try sql("UPDATE grants SET body='\(signed)' WHERE json_extract(body,'$.client')='claude-code'")
    try check(try store.typedDisclosure(for: TypedReader(client: "claude-code", recipient: "local", capability: renewed)) == .summary, "a grant signed under the old keyring never verifies again")
    try store.revoke(client: "claude-code", recipient: "local")
    try check(try store.grantScopes(client: "claude-code", recipient: "local") == nil, "revoke removes the connection")

    // MARK: Catalog wording and the one-sentence answer

    let read = AssistantCatalog.tools.first { $0.name == "read" }?.description ?? ""
    // Typing-all decision 4 superseded by owner decision 2026-10-03: the exact words reach AI apps only through
    // moment_details (and search's typed hits), from the running app, while "Let AI apps read what you typed" is on.
    // read still gives only a short description, and points at moment_details; it never offers a per-app permission.
    try check(read.contains("only a short description of where and about how much the person typed") && read.contains("for the typed words use moment_details")
              && !read.contains("allowed this app") && !read.contains("exact words") && !read.contains("when they allowed typing capture"), "read tool: a short description of typing; the words only through moment_details")
    let details = AssistantCatalog.tools.first { $0.name == "moment_details" }?.description ?? ""
    try check(AssistantCatalog.instructions.contains("(the words only if allowed)") && AssistantCatalog.instructions.contains("moment_details") && !AssistantCatalog.instructions.contains("allowed this app")
              && details.contains("when they allowed AI apps to read them") && details.contains("Passwords, secrets, private windows, excluded apps, blocked sites and expired words are never returned")
              && AssistantCatalog.instructions.count <= 2200, "instructions: AI apps get the words only if the person allows it, through moment_details")
    try check(TypedClaim.sentence.contains("password fields and private browser windows are skipped") && TypedClaim.sentence.contains("after 7 days unless you choose otherwise")
              && TypedClaim.sentence.contains("AI apps never get the exact words") && TypedClaim.sentence.contains("cloud summaries do only if you choose them") && !TypedClaim.short.contains("cloud summaries never") && !TypedClaim.sentence.contains("unless you let an AI app")
              && !TypedClaim.short.contains("unless you turn that on") && !TypedClaim.sentence.lowercased().contains("skips passwords")
              && TypedClaim.sentence.contains("open source") == TypedClaim.openSourcePublished, "the one-sentence answer names only what holds")
    try check(TypedRetention.default == .days7 && TypedTextPolicy().consentVersion == 0 && !PrivacySettings().captureText && TypedTextPolicy().shareWithSummaries == .off,
              "the facts behind the sentence: off by default (so no summary reads typing), 7 days")
    try store.setCaptureState("off", reason: "fixture done")
}
