import Foundation
import MemoryCore
import PrivacyPolicy

/// fix/prompt-row: an AI-app moment's row shows the start of what was typed, on this Mac only.
/// - `MomentPromptText.clean`: one line (whitespace and newlines collapse), cut with "…".
/// - `momentPromptRows`: metadata only; the ask typed in the moment's main app, a sent run first, its first part.
/// - `ownerMomentPrompts`: the words only through `hydrateTypedText(.owner)`: typing on, a ready key in this process,
///   not hidden or forgotten; it writes nothing.
/// - Privacy: a secure row is never stored or picked; the MCP and CLI (`mac-mem`, no key, no MemoryUI) print no
///   prompt word before or after the app opened it; the store is byte-identical after the app opens it (so no AI app,
///   writer or cloud request, which all read the store, can gain it); only the app and MemoryUI call it.
/// In-memory keys only; never the real Keychain.
func runMomentPromptChecks(home: URL) throws {
    // MARK: One line

    try check(MomentPromptText.clean("  how do I\n\nfix   the export\tcrash?\r\n ") == "how do I fix the export crash?", "prompt: spaces, tabs and newlines collapse to single spaces, trimmed")
    try check(MomentPromptText.clean("line one\u{2028}line two\u{2029}three\u{0B}four\u{0}five") == "line one line two three four five", "prompt: line and paragraph separators and control characters are spaces too")
    try check(MomentPromptText.clean(" \n\t ") == "" && MomentPromptText.clean("") == "", "prompt: nothing but whitespace is empty")
    let long = String(repeating: "word ", count: 120)
    let cut = MomentPromptText.clean(long)
    try check(cut.count == MomentPromptText.limit && cut.hasSuffix("…") && !cut.contains("\n") && !cut.contains("  "), "prompt: a long ask is cut at \(MomentPromptText.limit) characters with …")
    let exact = String(repeating: "a", count: MomentPromptText.limit)
    try check(MomentPromptText.clean(exact) == exact, "prompt: exactly the limit is not cut")
    let paste = "start " + String(repeating: " ", count: 5000) + "end"
    try check(MomentPromptText.clean(paste) == "start…" || MomentPromptText.clean(paste).hasPrefix("start"), "prompt: a huge whitespace run costs no more than its start")
    try check(MomentPromptText.clean("fix 👩‍💻 bug") == "fix 👩‍💻 bug" && MomentPromptText.clean(String(repeating: "👩‍💻", count: 300)).count == MomentPromptText.limit,
              "prompt: the cut counts characters, never splitting an emoji")

    // MARK: Fixture: typing on, a ready in-memory key

    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let now = Date()
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try store.updatePolicy(policy, now: now)
    let keys = try attachTestVault(store)
    let askWords = "  how do I\nfix the export   crash quokkaprompt in the Swift build?\n\n"
    let draftWords = "draft zebraprompt never sent"
    let noteWords = "grocery list marmaladeprompt"
    let secrets = ["quokkaprompt", "zebraprompt", "marmaladeprompt", "the export crash", "grocery list"]
    // Public builds type in Notes and TextEdit only: the ask rows carry Notes' bundle with the AI send facts, as
    // TypedSendFactsChecks does (the facts, not the bundle, make them asks).
    func typed(_ id: String, _ text: String, _ seconds: Double, surface: String?, send: String?, run: String, part: Int = 1, url: String = "") -> Evidence {
        var e = Evidence(id: id, at: iso(now.addingTimeInterval(-seconds)), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes",
                         title: "ChatGPT", url: url, text: text, synthetic: true)
        var unit = TypedUnitProvenance(runID: run, part: part, sealReason: send == "detected" ? "submit" : "idle", startedAt: iso(now.addingTimeInterval(-seconds - 5)),
                                       keys: 40, edits: 0, withheld: 0)
        unit.surface = surface; unit.send = send; unit.version = TypedUnitProvenance.sendFactsVersion
        e.captureProvenance = NativeCaptureProvenance(policyRevision: "r", classifierVersion: "sensitive-typing/v2+typed-scrub/v1", windowID: "w", focusID: "f",
                                                      checkedAt: iso(now), generation: 1, unit: unit)
        return e
    }
    try check(try store.ingest(Evidence(id: "p-window", at: iso(now.addingTimeInterval(-40)), kind: "window.changed", app: "Notes", bundle: "com.apple.Notes", title: "ChatGPT", synthetic: true), now: now)
              && store.ingest(typed("p-draft", draftWords, 30, surface: "ai", send: "unknown", run: "run-draft"), now: now)
              && store.ingest(typed("p-ask-2", "part two of the ask", 19, surface: "ai", send: "detected", run: "run-ask", part: 2), now: now)
              && store.ingest(typed("p-ask-1", askWords, 20, surface: "ai", send: "none", run: "run-ask", part: 1), now: now)
              && store.ingest(typed("p-note", noteWords, 10, surface: "writing", send: "none", run: "run-note"), now: now),
              "fixture: a draft ask, a sent ask in two parts, a Notes note (surface writing)")
    // A typed row flagged secure (a password field) is refused at the store: never saved, never sealed, never an ask.
    var secure = typed("p-secure", "hunter2 secureprompt", 5, surface: "ai", send: "detected", run: "run-secure"); secure.secure = true
    try check(!(try store.ingest(secure, now: now)) && store.read("p-secure", now: now) == nil
              && sql(home, "SELECT id FROM typed_text WHERE id='p-secure'").isEmpty, "secure field: a typed row flagged secure is never saved or sealed")
    try check(try sql(home, "SELECT id FROM records WHERE body LIKE '%quokkaprompt%' OR body LIKE '%zebraprompt%'").isEmpty, "fixture: the words are sealed, never in a record body")

    let ids = ["p-window", "p-draft", "p-ask-2", "p-ask-1", "p-note", "p-secure"]
    let chat = MomentPromptRequest(momentID: "m-chat", actionIDs: ids, primaryBundle: "com.apple.Notes", site: nil)

    // MARK: Which row is the ask (metadata only)

    let asks = try store.momentPromptRows([chat])
    try check(asks["m-chat"] == ["p-ask-1", "p-draft"], "pick: the sent run first, by its first part (the start of the ask), then the draft run; never the Notes note or a secure row (\(asks))")
    try check(try store.momentPromptRows([MomentPromptRequest(momentID: "m-other", actionIDs: ids, primaryBundle: "com.apple.TextEdit", site: nil)]).isEmpty,
              "pick: an ask typed in another app than the moment's main app is not this moment's")
    try check(try store.momentPromptRows([MomentPromptRequest(momentID: "m-none", actionIDs: ["p-window", "p-note"], primaryBundle: "com.apple.Notes", site: nil)]).isEmpty,
              "pick: a moment without an AI ask has none (today's text stays)")
    try check(try store.momentPromptRows([]).isEmpty && store.momentPromptRows([MomentPromptRequest(momentID: "e", actionIDs: [], primaryBundle: nil, site: nil)]).isEmpty,
              "pick: no moments, no work")
    // claude/livefix-1004 (owner, live test 10/3): a moment without a note yet (one Ghostty window of Claude Code stays one
    // moment for an hour) shows its NEWEST ask; a moment with a note keeps the first.
    try check(try store.ingest(typed("p-ask-new", "newest ask of the hour", 4, surface: "ai", send: "detected", run: "run-new"), now: now),
              "fixture: a newer sent ask in the same moment")
    let hour = ids + ["p-ask-new"]
    try check(try store.momentPromptRows([MomentPromptRequest(momentID: "m-open", actionIDs: hour, primaryBundle: "com.apple.Notes", site: nil,
                                                               newestFirst: true)])["m-open"] == ["p-ask-new", "p-ask-1", "p-draft"],
              "pick, no note yet: the newest sent ask first, then older sent asks, then the draft")
    try check(try store.momentPromptRows([MomentPromptRequest(momentID: "m-done", actionIDs: hour, primaryBundle: "com.apple.Notes", site: nil)])["m-done"]
              == ["p-ask-1", "p-ask-new", "p-draft"], "pick, default: the first sent ask first (unchanged)")

    // MARK: The words, in the app process only

    let before = try storeDigest(home)
    let revision = try store.disclosureRevision()
    let shown = try store.ownerMomentPrompts(asks, now: now)
    try check(shown == ["m-chat": "how do I fix the export crash quokkaprompt in the Swift build?"], "owner: the app opens the ask, one line (\(shown))")
    try check(try storeDigest(home) == before && store.disclosureRevision() == revision, "owner: opening the ask writes nothing (records, typed, notes, requests, metadata unchanged)")
    try check(try store.ownerMomentPrompts(["m-draft": ["p-draft"]], now: now) == ["m-draft": draftWords], "owner: a draft ask opens too (no send claimed)")
    try check(try store.ownerMomentPrompts(["m-x": ["missing-row", "p-ask-1"]], now: now)["m-x"]?.hasPrefix("how do I fix") == true, "owner: a candidate that doesn't open gives way to the next")
    try check(try store.ownerMomentPrompts(["m-note": ["p-note"]], now: now)["m-note"] == noteWords, "control: the owner disclosure opens any kept row it is handed (the pick decides what is an ask)")

    // Typing off: nothing opens; on again: it does.
    policy.captureText = false; try store.updatePolicy(policy, now: now)
    try check(try store.ownerMomentPrompts(asks, now: now).isEmpty, "typing off: no ask opens (the row keeps today's text)")
    policy.captureText = true; try store.updatePolicy(policy, now: now)
    try check(try store.ownerMomentPrompts(asks, now: now)["m-chat"] != nil, "control: typing on again, the ask opens")
    // A locked Keychain (the key not ready) opens nothing.
    keys.locked = true; _ = try store.reconcileTypedVault(now: now)
    try check(try store.ownerMomentPrompts(asks, now: now).isEmpty, "a locked Keychain: no ask opens")
    keys.locked = false; _ = try store.reconcileTypedVault(now: now)
    try check(try store.ownerMomentPrompts(asks, now: now)["m-chat"] != nil, "control: unlocked, the ask opens")
    // Another process (no key: every MCP and CLI process) picks the row but never opens it.
    let reader = try MemoryStore(home: home)
    try check(reader.typedVaultState == .unavailable && (try reader.momentPromptRows([chat]))["m-chat"] == ["p-ask-1", "p-draft"]
              && (try reader.ownerMomentPrompts(asks, now: now)).isEmpty, "a process without the key (MCP, CLI, a reader) opens no ask")
    // An app the person excludes hides its rows: the ask goes.
    policy.blockedApps = ["com.apple.Notes"]; try store.updatePolicy(policy, now: now)
    try check(try store.ownerMomentPrompts(asks, now: now).isEmpty, "an excluded app's ask is hidden")
    policy.blockedApps = []; try store.updatePolicy(policy, now: now)

    // MARK: Nothing that leaves the app gains the words

    let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("mac-mem")
    try check(FileManager.default.isExecutableFile(atPath: binary.path), "the mac-mem CLI/MCP binary is built next to the checks")
    func run(_ args: [String], capability: String = "", input: Data? = nil) throws -> String {
        let process = Process(); process.executableURL = binary; process.arguments = ["--home", home.path, "--client", "claude-code", "--recipient", "local"] + args
        var env = ProcessInfo.processInfo.environment; env["MAC_MEM_CAPABILITY"] = capability.isEmpty ? nil : capability
        process.environment = env
        let out = Pipe(), stdin = Pipe(); process.standardOutput = out; process.standardError = out; process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(input) }
        try stdin.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
    let token = ((try? JSONSerialization.jsonObject(with: Data(try run(["grant"]).utf8))) as? [String: String])?["capability"] ?? ""
    try check(!token.isEmpty, "fixture: an AI app connected (context, search, detail)")
    let day = try DayScope.key(now, timezone: "UTC")
    func everything() throws -> String {
        func call(_ id: Int, _ name: String, _ arguments: [String: String] = [:]) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
        }
        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]],
            call(2, "status"), call(3, "context"), call(4, "current-context"), call(5, "search", ["query": ""]), call(6, "search", ["query": "quokkaprompt"]),
            call(7, "read", ["id": "p-ask-1"]), call(8, "read", ["id": "p-draft"]), call(9, "open", ["uri": "macmem://days/\(day).json?timezone=UTC"]),
            call(10, "open", ["uri": ActionResources.actionURI("p-ask-1")]), ["jsonrpc": "2.0", "id": 11, "method": "resources/read", "params": ["uri": "macmem://current-context"]]]
        let input = try requests.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try store.setCaptureState("recording", reason: "synthetic prompt-row fixture", now: Date())
        var out = try run(["mcp"], capability: token, input: Data(input.utf8))
        for args in [["context"], ["search", "quokkaprompt"], ["read", "p-ask-1"], ["actions"], ["day", "--day", day, "--timezone", "UTC"], ["history-events", "--include-text"]] {
            try store.setCaptureState("recording", reason: "synthetic prompt-row fixture", now: Date())
            out += "\n" + (try run(args, capability: token))
        }
        return out
    }
    func leaked(_ text: String) -> [String] { secrets.filter { text.contains($0) } }
    let beforeOpen = try everything()
    try check(beforeOpen.contains("p-ask-1") && beforeOpen.contains("Typed in Notes"), "control: the MCP and CLI replies carry the typed rows (as a count, never words)")
    try check(leaked(beforeOpen).isEmpty, "MCP and CLI (status, context, search, read, open, day, actions, history-events --include-text): no prompt word")
    let beforeSecondOpen = try storeDigest(home)
    _ = try store.ownerMomentPrompts(asks, now: now)
    try check(try storeDigest(home) == beforeSecondOpen, "the store is unchanged by the app opening the ask, so no AI app, writer or cloud request (all read the store) can gain it")
    let afterOpen = try everything()
    try check(leaked(afterOpen).isEmpty, "after the app opened the ask for its row: still no prompt word in any MCP or CLI reply")
    try check(try sql(home, "SELECT id FROM records WHERE body LIKE '%quokkaprompt%'").isEmpty
              && sql(home, "SELECT id FROM metadata WHERE body LIKE '%quokkaprompt%'").isEmpty, "the ask is never written back (records, metadata)")

    // MARK: Who may call it (source)

    func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    let callers = ["Sources/MacMemCLI/main.swift", "Sources/MemoryCore/AssistantView.swift", "Sources/MemoryCore/ActionResources.swift",
                   "adapters/CoreWriterBinding.swift", "adapters/CoreCaptureBinding.swift"]
    try check(callers.allSatisfy { !source($0).isEmpty }, "source: the MCP, CLI and writer adapter files are readable from the checkout")
    try check(callers.allSatisfy { !source($0).contains("ownerMomentPrompts") && !source($0).contains("MomentPrompt") }, "source: the MCP, CLI and writer adapters never ask for a prompt")
    let appFiles = ((try? FileManager.default.contentsOfDirectory(atPath: "Sources/MacMemApp")) ?? []).filter { $0.hasSuffix(".swift") }
    let appCallers = appFiles.filter { source("Sources/MacMemApp/" + $0).contains("ownerMomentPrompts") }
    try check(appCallers == ["MacMemApp.swift"], "source: the app's one caller is the timeline loader (\(appCallers))")
    let writerFiles = (FileManager.default.enumerator(atPath: "WriterBackend/Sources")?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".swift") }
    try check(!writerFiles.isEmpty && writerFiles.allSatisfy { !source("WriterBackend/Sources/" + $0).contains("MomentPrompt") },
              "source: the writers (local and cloud) never read a timeline prompt")
    let package = source("Package.swift")
    let cli = package.components(separatedBy: "\n").first { $0.contains("name: \"MacMemCLI\"") } ?? ""
    try check(!cli.isEmpty && !cli.contains("MemoryUI"), "source: mac-mem (MCP and CLI) doesn't link MemoryUI, where the prompts are held")
    let cache = source("Sources/MemoryUI/MomentPromptCache.swift") + source("Sources/MemoryCore/MomentPrompts.swift")
    try check(!cache.isEmpty && ["print(", "NSLog", "os_log", "Logger(", "RecordingLog", "DiagnosticsLog", "UserDefaults", "write(to", "FileManager"].allSatisfy { !cache.contains($0) },
              "source: the prompt code logs nothing and writes no file or default")
    print("PASS fix/prompt-row: one line, the ask by code, owner-only words, nothing leaves the app.")
}

/// A read of the history with /usr/bin/sqlite3, the way another process on this Mac reads it.
private func sql(_ home: URL, _ statement: String) throws -> String {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [home.appendingPathComponent("memory.sqlite").path, statement]
    let out = Pipe(); process.standardOutput = out; process.standardError = out
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw MemError.invalid("FAILED: sqlite3: " + String(decoding: data, as: UTF8.self)) }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Every table's rows (the store's whole content), hashed.
private func storeDigest(_ home: URL) throws -> String {
    let tables = try sql(home, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").split(separator: "\n").map(String.init)
    var all = ""
    for t in tables { all += t + "\n" + (try sql(home, "SELECT * FROM \"\(t)\" ORDER BY 1")) + "\n" }
    return fingerprint(all)
}
