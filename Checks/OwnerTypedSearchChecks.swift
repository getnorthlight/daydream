import Foundation
import MemoryCore

/// fix/search-1003: in-app search finds what the person typed (owner, 2026-09-29: typed words are visible and searchable
/// on this Mac, in their own app), and nothing else gains the words.
/// - `ownerTypedSearch`: a typed Messages row is found by a word, its case variants, a prefix, a typo and its
///   conversation's name; a row typed a moment ago is found at once (no index involved); every query word is required.
/// - The metadata search (`searchResult`, the index and the direct scan, shared with the MCP and CLI) still never
///   matches typed words; a note (summary) still matches through `noteSearch` only.
/// - Privacy: words the scrubber withheld, a secret-looking token and a secure field never match; typing off, a locked
///   key, a process without the key (MCP, CLI), an excluded app and an expired kept period find nothing; the search
///   writes nothing; the MCP and CLI search reply carries neither the typed row nor its words.
/// Synthetic data, in-memory keys only; never the real Keychain.
func runOwnerTypedSearchChecks(home: URL) throws {
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let now = Date()
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try store.updatePolicy(policy, now: now)
    let keys = try attachTestVault(store)
    var typedPolicy = try store.typedTextPolicy(); typedPolicy.retention = .days7
    try store.updateTypedTextPolicy(typedPolicy, confirmed: true, now: now)

    func typed(_ id: String, _ text: String, _ seconds: Double, app: String, bundle: String, title: String, surface: String?, field: String?,
               send: String?, to: String? = nil) -> Evidence {
        var e = Evidence(id: id, at: iso(now.addingTimeInterval(-seconds)), kind: "keyboard.text_input", app: app, bundle: bundle,
                         title: title, text: text, synthetic: true)
        var unit = TypedUnitProvenance(runID: "run-" + id, part: 1, sealReason: send == "detected" ? "submit" : "idle",
                                       startedAt: iso(now.addingTimeInterval(-seconds - 5)), keys: 40, edits: 0, withheld: 0)
        unit.surface = surface; unit.field = field; unit.send = send; unit.to = to; unit.version = TypedUnitProvenance.sendFactsVersion
        e.captureProvenance = NativeCaptureProvenance(policyRevision: "r", classifierVersion: "sensitive-typing/v2+typed-scrub/v1", windowID: "w-" + id,
                                                      focusID: "f-" + id, checkedAt: iso(now), generation: 1, unit: unit)
        return e
    }
    // The owner's bug, synthetically: a short all-caps word sent in Messages ("ZUX" stands in for it), plus a longer word
    // with a possessive. Public builds may not type in Messages: the same row in TextEdit then stands in (same facts).
    let words = "me and my pals are going to ZUX tmrw for the quokkafest's opening zebrafinch"
    var place = (app: "Messages", bundle: "com.apple.MobileSMS")
    if !(try store.ingest(typed("t-msg", words, 3 * 3600, app: place.app, bundle: place.bundle, title: "Messages", surface: "text", field: "message",
                                send: "detected", to: "Pat Quill"), now: now)) {
        place = (app: "TextEdit", bundle: "com.apple.TextEdit")
        try check(try store.ingest(typed("t-msg", words, 3 * 3600, app: place.app, bundle: place.bundle, title: "Untitled", surface: "text", field: "message",
                                         send: "detected", to: "Pat Quill"), now: now), "fixture: a sent text (in TextEdit: this build types in no Messages)")
    }
    print("owner typed search fixture: typed row in \(place.app)")
    try check(try store.read("t-msg", now: now)?.evidence.text == "", "fixture: the typed row's record keeps no words (sealed)")

    func found(_ q: String, start: Date? = nil, at: Date = now, in s: MemoryStore? = nil) throws -> [String] {
        try (s ?? store).ownerTypedSearch(MemorySearchQuery(q, start: start, limit: 50), now: at).items.map(\.id)
    }
    // MARK: Word, case variants, prefix, typo, every word required
    for q in ["ZUX", "Zux", "zux", "zUx"] { try check(try found(q) == ["t-msg"], "typed: found by a short word in any case (\(q.count) letters)") }
    try check(try found("Zu") == ["t-msg"], "typed: found by a prefix")
    for q in ["quokkafest", "QUOKKAFEST", "Quokka", "quokkafest's"] {
        try check(try found(q) == ["t-msg"], "typed: a longer word's case variants, prefix and possessive")
    }
    try check(try found("quokkafset") == ["t-msg"], "typed: a typo in a long word (the direct scan's bounded typo tier)")
    try check(try found("zux tmrw") == ["t-msg"] && found("zux nowhereword").isEmpty, "typed: every query word is required")
    try check(try found("Pat Quill") == ["t-msg"], "typed: found by the conversation's name")
    try check(try found("Zux", start: now.addingTimeInterval(-30 * 86400)) == ["t-msg"], "typed: inside a Past 30 Days range")
    try check(try found("Zux", start: now.addingTimeInterval(-3600)).isEmpty, "typed: a range that starts after the row leaves it out")
    let result = try store.ownerTypedSearch(MemorySearchQuery("zux"), now: now)
    let snippet = result.snippets["t-msg"] ?? ""
    try check(snippet.localizedCaseInsensitiveContains("zux") && snippet.count <= 2 * OwnerTypedSearchText.radius + 8 && !snippet.contains("\n"),
              "typed: one short single-line snippet around the match")
    try check(result.places["t-msg"]?.line == "Texts \u{00B7} Pat Quill", "typed: the match carries its context, metadata only (\(result.places["t-msg"]?.line ?? "none"))")
    try check(result.items.first?.summary.localizedCaseInsensitiveContains("zux") == false, "typed: the item's own summary stays a word-free description")

    // MARK: The metadata search (shared with the MCP and CLI) is unchanged
    try check(try store.searchResult(MemorySearchQuery("quokkafest"), now: now).items.isEmpty
              && store.searchResult(MemorySearchQuery("zux"), now: now).items.isEmpty, "metadata search: typed words never match (index and direct scan)")
    try check(try store.directSearchPreview(MemorySearchQuery("zux"), now: now).items.isEmpty, "direct preview: typed words never match")
    try check(try store.search(query: "zux").isEmpty, "Access.search: typed words never match")

    // MARK: A fresh row is found at once
    try check(try store.ingest(typed("t-fresh", "ok see you at narwhalpier soon", 2, app: place.app, bundle: place.bundle, title: "Messages",
                                     surface: "text", field: "message", send: "detected", to: "Pat Quill"), now: now), "fixture: a row typed seconds ago")
    try check(try found("narwhalpier") == ["t-fresh"], "fresh: found before any index has seen it")
    try check(try found("pat quill") == ["t-fresh", "t-msg"], "fresh: newest first")

    // MARK: A summary-only match goes through the notes, not the typed pass
    let zone = "UTC"
    for (i, m) in [0, 2].enumerated() {
        _ = try store.ingest(Evidence(id: "n\(i)", at: iso(now.addingTimeInterval(Double(-5 * 3600 + m * 60))), kind: "window.changed", app: "Notes",
                                      bundle: "com.apple.Notes", title: "Picnic plan", synthetic: true), now: now)
    }
    let day = try DayScope.key(now.addingTimeInterval(-5 * 3600), timezone: zone)
    if let moment = try store.dayLayers(day: day, timezone: zone, now: now).activities.first(where: { $0.actionIDs.contains("n0") }) {
        let request = try store.prepareNote(kind: "activity", day: day, timezone: zone, activityID: moment.id, now: now)
        _ = try store.commitNote(NoteWriterOutput(requestID: request.id, title: "Picnic plan",
                                                  bullets: [NoteBullet(text: "Planned the walrusgala picnic in Notes.", actionIDs: request.actions.map(\.id), assertion: "observed")],
                                                  generator: "local/synthetic", generatorVersion: "1"), now: now)
    }
    try check(try store.noteSearch("walrusgala", timezone: zone, now: now).contains { $0.level == "line" || $0.level == "moment" },
              "summary: a word only in a moment's note is found by the note search")
    try check(try found("walrusgala").isEmpty && store.searchResult(MemorySearchQuery("walrusgala"), now: now).items.isEmpty,
              "summary: the typed pass and the metadata search don't claim it")

    // MARK: Secrets and secure fields never match
    try check(try store.ingest(typed("t-secret", "the key is sk-live_Qw7Er9Ty2Ui4Op6As8 and Zq9!xT4mPa ok gannetcove", 60, app: place.app, bundle: place.bundle,
                                     title: "Messages", surface: "text", field: "message", send: "detected", to: "Pat Quill"), now: now), "fixture: a text with secrets")
    try check(try found("gannetcove") == ["t-secret"], "secret: control, the row's ordinary word matches")
    for q in ["sk-live_Qw7Er9Ty2Ui4Op6As8", "Qw7Er9Ty2Ui4Op6As8", "Zq9!xT4mPa", "withheld"] {
        try check(try found(q).isEmpty, "secret: a withheld or secret-looking token never matches (\(q.count) chars)")
    }
    try check(!(try store.ownerTypedSearch(MemorySearchQuery("gannetcove"), now: now).snippets["t-secret"] ?? "").contains("Zq9!"),
              "secret: the snippet never shows a secret-looking token")
    var secure = typed("t-secure", "hunter2 puffinsecure", 30, app: place.app, bundle: place.bundle, title: "Messages", surface: "text", field: "message", send: nil)
    secure.secure = true
    _ = try? store.ingest(secure, now: now)
    try check(try found("puffinsecure").isEmpty, "secure field: never matches")

    // MARK: Gates
    let before = try showAllStoreDigest(home), revision = try store.disclosureRevision()
    _ = try found("zux"); _ = try found("pat quill")
    try check(try showAllStoreDigest(home) == before && store.disclosureRevision() == revision, "the typed search writes nothing")
    let reader = try MemoryStore(home: home)
    try check(reader.typedVaultState != .ready && (try found("zux", in: reader)).isEmpty, "a process without the key (MCP, CLI, a reader) finds no typed word")
    policy.captureText = false; try store.updatePolicy(policy, now: now)
    try check(try found("zux").isEmpty, "typing off: no typed word matches")
    policy.captureText = true; try store.updatePolicy(policy, now: now)
    keys.locked = true; _ = try store.reconcileTypedVault(now: now)
    try check(try found("zux").isEmpty, "a locked key: no typed word matches")
    keys.locked = false; _ = try store.reconcileTypedVault(now: now)
    try check(try found("zux") == ["t-msg"], "control: unlocked, it matches again")
    policy.blockedApps = [place.bundle]; try store.updatePolicy(policy, now: now)
    try check(try found("zux").isEmpty, "an excluded app's typed words never match")
    policy.blockedApps = []; try store.updatePolicy(policy, now: now)

    // MARK: MCP and CLI search unchanged
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
    try check(!token.isEmpty, "fixture: an AI app connected")
    var replies = ""
    let requests: [[String: Any]] = [["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]]]
        + ["zux", "quokkafest", "narwhalpier", "zebrafinch"].enumerated().map { i, q in
            ["jsonrpc": "2.0", "id": i + 2, "method": "tools/call", "params": ["name": "search", "arguments": ["query": q]]] }
    let input = try requests.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
    try store.setCaptureState("recording", reason: "synthetic typed search fixture", now: Date())
    replies += try run(["mcp"], capability: token, input: Data(input.utf8))
    for q in ["zux", "quokkafest", "narwhalpier"] {
        try store.setCaptureState("recording", reason: "synthetic typed search fixture", now: Date())
        replies += "\n" + (try run(["search", q], capability: token))
    }
    try check(replies.contains("\"id\":5") || replies.contains("\"id\": 5"), "control: the MCP answered every search")
    try check(!replies.contains("t-msg") && !replies.contains("t-fresh"), "MCP and CLI search: the typed rows are not hits for their words")
    try check(!["tmrw", "opening", "see you at", "quokkafest's"].contains { replies.contains($0) }, "MCP and CLI search: no typed word in any reply")

    // MARK: Source: one caller, in the app
    func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    let outside = ["Sources/MacMemCLI/main.swift", "Sources/MemoryCore/AssistantView.swift", "Sources/MemoryCore/Access.swift",
                   "Sources/MemoryCore/MemorySearch.swift", "Sources/MemoryCore/SearchIndexer.swift", "Sources/MemoryCore/LevelRecall.swift",
                   "adapters/CoreWriterBinding.swift"]
    try check(outside.allSatisfy { !source($0).isEmpty && !source($0).contains("ownerTypedSearch") }, "source: the MCP, CLI, index and writers never call the typed search")
    let appFiles = ((try? FileManager.default.contentsOfDirectory(atPath: "Sources/MacMemApp")) ?? []).filter { $0.hasSuffix(".swift") }
    try check(appFiles.filter { source("Sources/MacMemApp/" + $0).contains("ownerTypedSearch") } == ["MacMemApp.swift"]
              && source("Sources/MacMemApp/MacMemApp.swift").contains("activity.searchOwnerTyped ="), "source: the app's search is its one caller")
    let code = source("Sources/MemoryCore/OwnerTypedSearch.swift")
    try check(!code.isEmpty && ["print(", "NSLog", "os_log", "Logger(", "RecordingLog", "DiagnosticsLog", "UserDefaults", "write(to", "FileManager", "exec(", "INSERT", "UPDATE "].allSatisfy { !code.contains($0) },
              "source: the typed search logs nothing and writes no row, file or default")

    // MARK: Retention (last: it moves the typed clock forward)
    try check(try found("zux", at: now.addingTimeInterval(86400)) == ["t-msg"], "retention: inside the kept period it matches")
    try check(try found("zux", at: now.addingTimeInterval(8 * 86400)).isEmpty && found("narwhalpier", at: now.addingTimeInterval(8 * 86400)).isEmpty,
              "retention: once the 7-day period is over the words never match, even before the expiry job runs")
    print("PASS fix/search-1003: in-app search matches the person's own typed words on this Mac only; MCP, CLI and the index unchanged.")
}
