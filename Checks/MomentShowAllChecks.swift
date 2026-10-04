import Foundation
import MemoryCore
import PrivacyPolicy

/// fix/show-all: a moment's full view shows what was typed and sent in it (on this Mac only), and a Chrome page keeps its
/// own link (on this Mac only) so Open Original opens that page.
/// - `MomentTypedText.clean`: readable text (lines kept, controls gone, one blank line at most), cut with "…".
/// - `momentTypedRows`: metadata only, time order, secure rows never listed, the send line by code (who only).
/// - `ownerMomentTyped`: the words only through `hydrateTypedText(.owner)`: typing on, a ready key in this process, not
///   hidden, excluded or forgotten; blocks per place; it writes nothing.
/// - `BrowserSites.pageLink` and `Evidence.page`: a plain link without query, fragment or token; `readerItem` drops it;
///   Open Original opens it.
/// - Privacy: the MCP and CLI (`mac-mem`, no key, no MemoryUI) print no typed word and no page path, before and after the
///   app opened them; the store is byte-identical after the app opens them (so no AI app, writer or cloud request, which
///   all read the store, can gain them); only the app and MemoryUI call it.
/// In-memory keys only; never the real Keychain.
func runMomentShowAllChecks(home: URL) throws {
    // MARK: Readable text

    try check(MomentTypedText.clean("  Hi Sam,\r\n\r\n\r\nSee you   at\t6.\u{2028}Thanks\u{0}!  ") == "Hi Sam,\n\nSee you at 6.\nThanks!",
              "typed text: line breaks kept (one blank line at most), spaces and tabs collapse, control characters go")
    try check(MomentTypedText.clean(" \n\t\n ") == "", "typed text: nothing but whitespace is empty")
    let long = String(repeating: "word ", count: 2000)
    let cut = MomentTypedText.clean(long)
    try check(cut.count == MomentTypedText.blockLimit && cut.hasSuffix("…"), "typed text: a long block is cut at \(MomentTypedText.blockLimit) characters with …")
    try check(MomentTypedText.clean("fix 👩‍💻 bug") == "fix 👩‍💻 bug", "typed text: an emoji with a joiner stays whole")

    // MARK: Blocks (pure)

    func row(_ id: String, _ at: String, bundle: String = "com.anthropic.claudefordesktop", host: String = "", title: String = "Claude",
             run: String = "r", part: Int = 1, send: String? = nil) -> MomentTypedRow {
        MomentTypedRow(id: id, at: at, app: "Claude", bundle: bundle, host: host, title: title, run: run, part: part, send: send)
    }
    let rows = [row("b", "2026-09-29T00:05:00Z", send: "Asked Claude"), row("a", "2026-09-29T00:01:00Z"),
                row("c", "2026-09-29T00:07:00Z", bundle: "com.apple.MobileSMS", title: "Q7", send: "Texted Q7"),
                row("d", "2026-09-29T00:09:00Z")]
    let blocks = MomentTypedText.blocks(rows, words: ["a": "first ask", "b": "second ask", "c": "on my way", "d": "   "])
    try check(blocks.map(\.id) == ["a", "c"] && blocks[0].text == "first ask\nsecond ask" && blocks[0].send == "Asked Claude"
              && blocks[1].text == "on my way" && blocks[1].send == "Texted Q7",
              "blocks: time order, consecutive rows in one place are one block (each on its own line), its send kept; empty words leave no block (\(blocks))")
    try check(MomentTypedText.blocks(rows, words: [:]).isEmpty, "blocks: nothing opened, nothing shown")

    // MARK: Page links

    try check(BrowserSites.pageLink("https://x.com/fixtureuser/status/1839123456789012344?s=20&t=abc#reply") == "https://x.com/fixtureuser/status/1839123456789012344",
              "page link: an X post keeps its path, never its query or fragment")
    try check(BrowserSites.pageLink("https://x.com/") == nil && BrowserSites.pageLink("https://x.com") == nil, "page link: a front page has none (the origin says it)")
    try check(BrowserSites.pageLink("https://user:pw@example.com/a/b") == nil, "page link: never a login")
    try check(BrowserSites.pageLink("https://example.com/reset/Zx81kPq0aB7mNc2Lw9Rt4yUv") == nil, "page link: a token-like part (reset links, share keys) is refused")
    try check(BrowserSites.pageLink("https://shop.example.com/pay/4111111111111111") == nil, "page link: a card number in the path is refused")
    try check(BrowserSites.pageLink("https://example.com/files/sk-live_abcdefghijklmnop") == nil, "page link: a secret-looking part is refused")
    try check(BrowserSites.pageLink("ftp://example.com/a") == nil && BrowserSites.pageLink("file:///Users/x/a.pdf") == nil, "page link: web links only")
    try check(BrowserSites.pageLink("https://github.com/apple/swift/pull/418") == "https://github.com/apple/swift/pull/418", "page link: an ordinary page keeps its path")

    // MARK: Fixture: typing on, a ready in-memory key

    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let now = Date()
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try store.updatePolicy(policy, now: now)
    let keys = try attachTestVault(store)
    let askWords = "how do I fix the export crash quokkashowall?\n\nit happens on save"
    let textWords = "running late zebrashowall"
    let secrets = ["quokkashowall", "zebrashowall", "the export crash", "running late", "status/1839123456789012344", "narwhalpath"]
    func typed(_ id: String, _ text: String, _ seconds: Double, app: String, bundle: String, title: String, surface: String?, send: String?,
               run: String, to: String? = nil) -> Evidence {
        var e = Evidence(id: id, at: iso(now.addingTimeInterval(-seconds)), kind: "keyboard.text_input", app: app, bundle: bundle,
                         title: title, text: text, synthetic: true)
        var unit = TypedUnitProvenance(runID: run, part: 1, sealReason: send == "detected" ? "submit" : "idle", startedAt: iso(now.addingTimeInterval(-seconds - 5)),
                                       keys: 40, edits: 0, withheld: 0)
        unit.surface = surface; unit.send = send; unit.to = to; unit.version = TypedUnitProvenance.sendFactsVersion
        e.captureProvenance = NativeCaptureProvenance(policyRevision: "r", classifierVersion: "sensitive-typing/v2+typed-scrub/v1", windowID: "w", focusID: "f",
                                                      checkedAt: iso(now), generation: 1, unit: unit)
        return e
    }
    // Public builds type in Notes and TextEdit only: rows carry their bundles with the send facts (the facts make them sends).
    try check(try store.ingest(Evidence(id: "s-window", at: iso(now.addingTimeInterval(-60)), kind: "window.changed", app: "Notes", bundle: "com.apple.Notes", title: "ChatGPT", synthetic: true), now: now)
              && store.ingest(typed("s-ask", askWords, 50, app: "Notes", bundle: "com.apple.Notes", title: "ChatGPT", surface: "ai", send: "detected", run: "run-ask"), now: now)
              && store.ingest(typed("s-text", textWords, 30, app: "TextEdit", bundle: "com.apple.TextEdit", title: "Q7", surface: "text", send: "detected", run: "run-text", to: "Q7"), now: now),
              "fixture: an ask in one app, a text in another")
    var secure = typed("s-secure", "hunter2 secureshowall", 20, app: "Notes", bundle: "com.apple.Notes", title: "ChatGPT", surface: "ai", send: "detected", run: "run-secure")
    secure.secure = true
    try check(!(try store.ingest(secure, now: now)), "secure field: a typed row flagged secure is never saved")
    // A Chrome page with its own link, on this Mac only.
    var page = Evidence(id: "s-page", at: iso(now.addingTimeInterval(-10)), kind: "window.changed", app: "Google Chrome", bundle: "com.google.Chrome",
                        title: "fixtureuser on X: sonnet narwhalpath", url: "https://x.com", synthetic: true)
    page.page = "https://x.com/fixtureuser/status/1839123456789012344?s=20#narwhalpath"
    try check(try store.ingest(page, now: now), "fixture: a Chrome page with its own link")
    try check(try store.read("s-page", now: now)?.evidence.page == "https://x.com/fixtureuser/status/1839123456789012344",
              "page link: kept without its query or fragment (\(String(describing: try store.read("s-page", now: now)?.evidence.page)))")
    var foreign = Evidence(id: "s-foreign", at: iso(now.addingTimeInterval(-9)), kind: "window.changed", app: "Google Chrome", bundle: "com.google.Chrome",
                           title: "Other", url: "https://x.com", synthetic: true)
    foreign.page = "https://evil.example/x.com/phish"
    try check(try store.ingest(foreign, now: now) && store.read("s-foreign", now: now)?.evidence.page == nil, "page link: never a link to another site than the row's")
    try check(try store.readerItem("s-page", now: now).map { $0.evidence.page == nil && $0.evidence.url == "https://x.com" } == true,
              "page link: the CLI's read (readerItem) names the site only")
    struct Verifier: OriginalSourceVerifier {
        func verify(url: String, deadline: Date) throws -> OriginalSourceCheck { OriginalSourceCheck(url: url, exists: true, readOnly: true) }
    }
    try check(try store.originalSourceLink(actionID: "s-page", verifier: Verifier(), now: now).url == "https://x.com/fixtureuser/status/1839123456789012344",
              "Open Original: a Chrome page opens its own link")
    try check(try store.originalSourceLink(actionID: "s-foreign", verifier: Verifier(), now: now).url == "https://x.com",
              "Open Original: without a link, its site")

    let ids = ["s-window", "s-ask", "s-text", "s-secure", "s-page"]

    // MARK: Which rows were typed and sent (metadata only)

    let meta = try store.momentTypedRows(ids, label: "Texts with Q7")
    try check(meta.map(\.id) == ["s-ask", "s-text"], "rows: the typed rows in time order, never a window, a page or a secure row (\(meta.map(\.id)))")
    try check(meta.first?.send == "Asked ChatGPT" || meta.first?.send?.hasPrefix("Asked ") == true, "rows: an ask's send line names the AI (\(String(describing: meta.first?.send)))")
    try check(meta.last?.send == "Texted Q7", "rows: a text's send line names who (\(String(describing: meta.last?.send)))")
    try check(try store.momentTypedRows([]).isEmpty, "rows: no actions, no work")

    // MARK: The words, in the app process only

    let before = try showAllStoreDigest(home)
    let revision = try store.disclosureRevision()
    let shown = try store.ownerMomentTyped(meta, now: now)
    try check(shown.map(\.id) == ["s-ask", "s-text"] && shown[0].text == "how do I fix the export crash quokkashowall? it happens on save"
              && shown[1].text == textWords && shown[1].send == "Texted Q7", "owner: the app opens each place's words as kept (the store keeps one line per row) (\(shown))")
    try check(try showAllStoreDigest(home) == before && store.disclosureRevision() == revision, "owner: opening the words writes nothing")
    policy.captureText = false; try store.updatePolicy(policy, now: now)
    try check(try store.ownerMomentTyped(meta, now: now).isEmpty, "typing off: no word opens")
    policy.captureText = true; try store.updatePolicy(policy, now: now)
    keys.locked = true; _ = try store.reconcileTypedVault(now: now)
    try check(try store.ownerMomentTyped(meta, now: now).isEmpty, "a locked Keychain (no ready key): no word opens")
    keys.locked = false; _ = try store.reconcileTypedVault(now: now)
    try check(try store.ownerMomentTyped(meta, now: now).count == 2, "control: unlocked, the words open")
    let reader = try MemoryStore(home: home)
    try check(reader.typedVaultState == .unavailable && (try reader.momentTypedRows(ids, label: "")).count == 2
              && (try reader.ownerMomentTyped(meta, now: now)).isEmpty, "a process without the key (MCP, CLI, a reader) opens no word")
    policy.blockedApps = ["com.apple.Notes"]; try store.updatePolicy(policy, now: now)
    try check(try store.ownerMomentTyped(meta, now: now).map(\.id) == ["s-text"], "an excluded app's words are hidden")
    policy.blockedApps = []; try store.updatePolicy(policy, now: now)

    // MARK: Nothing that leaves the app gains the words or the page's path

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
            call(2, "status"), call(3, "context"), call(4, "current-context"), call(5, "search", ["query": ""]), call(6, "search", ["query": "quokkashowall"]),
            call(7, "search", ["query": "narwhalpath"]), call(8, "read", ["id": "s-ask"]), call(9, "read", ["id": "s-page"]),
            call(10, "open", ["uri": "macmem://days/\(day).json?timezone=UTC"]), call(11, "open", ["uri": ActionResources.actionURI("s-page")]),
            ["jsonrpc": "2.0", "id": 12, "method": "resources/read", "params": ["uri": "macmem://current-context"]]]
        let input = try requests.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try store.setCaptureState("recording", reason: "synthetic show-all fixture", now: Date())
        var out = try run(["mcp"], capability: token, input: Data(input.utf8))
        for args in [["context"], ["search", "quokkashowall"], ["read", "s-ask"], ["read", "s-page"], ["actions"], ["day", "--day", day, "--timezone", "UTC"],
                     ["history-events", "--include-text"]] {
            try store.setCaptureState("recording", reason: "synthetic show-all fixture", now: Date())
            out += "\n" + (try run(args, capability: token))
        }
        return out
    }
    // The page's title names it ("fixtureuser on X: sonnet narwhalpath"): only its path and the typed words must stay home.
    func leaked(_ text: String) -> [String] { secrets.filter { $0 != "narwhalpath" && text.contains($0) } }
    let beforeOpen = try everything()
    try check(beforeOpen.contains("s-ask") && beforeOpen.contains("s-page") && beforeOpen.contains("x.com"),
              "control: the MCP and CLI replies carry the typed rows (as a count) and the page (by its site)")
    try check(leaked(beforeOpen).isEmpty, "MCP and CLI (status, context, search, read, open, day, actions, history-events --include-text): no typed word, no page path (\(leaked(beforeOpen)))")
    let beforeSecond = try showAllStoreDigest(home)
    _ = try store.ownerMomentTyped(meta, now: now)
    _ = try store.originalSourceLink(actionID: "s-page", verifier: Verifier(), now: now)
    try check(try showAllStoreDigest(home) == beforeSecond, "the store is unchanged by the app opening the words and the page, so no AI app, writer or cloud request can gain them")
    let afterOpen = try everything()
    try check(leaked(afterOpen).isEmpty, "after the app opened them: still no typed word or page path in any MCP or CLI reply")

    // MARK: Forget clears what the view shows

    try store.delete("s-text")
    try check(try store.ownerMomentTyped(try store.momentTypedRows(ids + ["s-text"], label: ""), now: now).map(\.id) == ["s-ask"],
              "forget: a forgotten row's words are gone from the view's next read")
    try store.delete("s-page")
    try check((try? store.originalSourceLink(actionID: "s-page", verifier: Verifier(), now: now)) == nil, "forget: a forgotten page has no link")

    // MARK: Who may call it (source)

    func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    let callers = ["Sources/MacMemCLI/main.swift", "Sources/MemoryCore/AssistantView.swift", "Sources/MemoryCore/ActionResources.swift",
                   "Sources/MemoryCore/Access.swift", "Sources/MemoryCore/LegacyReader.swift", "Sources/MemoryCore/SearchIndexer.swift",
                   "adapters/CoreWriterBinding.swift", "adapters/CoreCaptureBinding.swift"]
    try check(callers.allSatisfy { !source($0).isEmpty }, "source: the MCP, CLI, search and writer adapter files are readable from the checkout")
    try check(callers.allSatisfy { !source($0).contains("ownerMomentTyped") && !source($0).contains("MomentTyped") && !source($0).contains("evidence.page") },
              "source: the MCP, CLI, search and writer adapters never ask for typed words or a page link")
    let appFiles = ((try? FileManager.default.contentsOfDirectory(atPath: "Sources/MacMemApp")) ?? []).filter { $0.hasSuffix(".swift") }
    let appCallers = appFiles.filter { source("Sources/MacMemApp/" + $0).contains("ownerMomentTyped") }
    // 4e43b7fb: detail uses the verified short-run source projection, not the
    // legacy typed-block owner API. Keep both the removal and new one-caller boundary pinned.
    try check(appCallers.isEmpty, "source: the legacy typed-block owner API has no app callers (\(appCallers))")
    let previewCallers=appFiles.filter {source("Sources/MacMemApp/"+$0).contains("ownerSourceMomentPreviewsForActions")}
    try check(appFiles.allSatisfy { !source("Sources/MacMemApp/"+$0).contains("ownerSourcePreviewsForActions") } && previewCallers == ["MacMemApp.swift"] && source("Sources/MacMemApp/MacMemApp.swift").contains("activity.loadOwnerSourcePreviews ="), "source: the verified source projection has only the detail loader caller")
    let writerFiles = (FileManager.default.enumerator(atPath: "WriterBackend/Sources")?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".swift") }
    try check(!writerFiles.isEmpty && writerFiles.allSatisfy { !source("WriterBackend/Sources/" + $0).contains("MomentTyped") && !source("WriterBackend/Sources/" + $0).contains("evidence.page") },
              "source: the writers (local and cloud) never read typed blocks or a page link")
    let code = source("Sources/MemoryUI/MomentTypedSection.swift") + source("Sources/MemoryCore/MomentTyped.swift")
    try check(!code.isEmpty && ["print(", "NSLog", "os_log", "Logger(", "RecordingLog", "DiagnosticsLog", "UserDefaults", "write(to", "FileManager"].allSatisfy { !code.contains($0) },
              "source: the show-all code logs nothing and writes no file or default")
    print("PASS fix/show-all: readable typed blocks by place, owner-only words, page links on this Mac only, nothing leaves the app.")
}

/// Every table's rows (the store's whole content), hashed.
func showAllStoreDigest(_ home: URL) throws -> String {
    func sql(_ statement: String) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [home.appendingPathComponent("memory.sqlite").path, statement]
        let out = Pipe(); process.standardOutput = out; process.standardError = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MemError.invalid("FAILED: sqlite3: " + String(decoding: data, as: UTF8.self)) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let tables = try sql("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").split(separator: "\n").map(String.init)
    var all = ""
    for t in tables { all += t + "\n" + (try sql("SELECT * FROM \"\(t)\" ORDER BY 1")) + "\n" }
    return fingerprint(all)
}
