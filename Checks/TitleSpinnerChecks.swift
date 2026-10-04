import Foundation
import CSQLite
import MemoryCore
import PrivacyPolicy

/// claude/title-spinner-1003 (issue audit 10/03, B1 and S4): Claude Code animates its terminal tab title ("✳ / ◐ / ◑
/// <session>") about once a second. An earlier build saved every tick as a title row (7,301 of 8,163 rows one night), each
/// session became two interleaved moments (one per glyph) that never went quiet, and past 2,000 rows a moment could
/// never be summarized. The glyph also showed in `read`, search and AI apps.
/// - `TitleClean.statusless`: only whole runs of status glyphs at either end go, for any app.
/// - A save stores the title without the glyph; `read`, actions, search and the AI-app lines never show it.
/// - An earlier build's flood (planted straight to disk, thousands of rows, two alternating glyphs) reads as ONE moment,
///   counted by what was done (title ticks don't count), ending at the last thing done (so it closes when the person
///   stops), under the writer's limits. The stored rows stay byte for byte (backups keep them).
/// - A real title change, and rows without a glyph (two identical "Budget" rows), are kept as before.
/// Synthetic store only (fake titles); no capture, provider, index or model.
func runTitleSpinnerChecks(home: URL) throws {
    // MARK: statusless (pure)
    let cases: [(String, String)] = [
        ("✳ Fake session alpha", "Fake session alpha"), ("◐ Fake session alpha", "Fake session alpha"), ("◑ Fake session alpha", "Fake session alpha"),
        ("⠋ Building target", "Building target"), ("⠙⠹ Building", "Building"), ("main.swift ●", "main.swift"), ("● main.swift — Editor", "main.swift — Editor"),
        ("🔔 ~", "~"), ("◐◑ Fake ✳", "Fake"), ("✳", ""), ("  ✶  Plan  ", "Plan"), ("⏳ Waiting", "Waiting"), ("🟢 Online", "Online"),
        ("~", "~"), ("#eng", "#eng"), ("a → b", "a → b"), ("Plan ★ v2", "Plan ★ v2"), ("🎉 Launch", "🎉 Launch"), ("Untitled", "Untitled"),
        ("(3) Inbox", "(3) Inbox"), ("\"Quoted\"", "\"Quoted\""), ("  padded  ", "  padded  "), ("", ""),
    ]
    for (raw, want) in cases {
        try check(TitleClean.statusless(raw) == want, "statusless: “\(raw)” is “\(want)” (got “\(TitleClean.statusless(raw))”)")
    }
    try check(TitleClean.clean("◐ Fake session alpha", app: "Ghostty") == "Fake session alpha" && TitleClean.clean("Notes ●") == "Notes",
              "TitleClean.clean drops the glyph too (terminal and any app)")

    // MARK: store
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    let zone = "UTC"
    let ghostty = "com.mitchellh.ghostty"
    let start = now.addingTimeInterval(-3 * 3600)
    let day = try DayScope.key(start, timezone: zone)
    func at(_ seconds: Double) -> String { isoPrecise(start.addingTimeInterval(seconds)) }
    func row(_ id: String, _ seconds: Double, kind: String = "window.changed", app: String = "Ghostty", bundle: String = ghostty, title: String) -> Evidence {
        Evidence(id: id, at: at(seconds), kind: kind, app: app, bundle: bundle, title: title, synthetic: true)
    }

    // A save stores no glyph, and its read says none.
    _ = try store.ingest(row("saved-tick", -600, title: "◐ Fake saved session"), now: now)
    let saved = try store.read("saved-tick", now: now)
    try check(saved?.evidence.title == "Fake saved session" && saved?.summary.contains("◐") == false && saved?.summary.contains("Fake saved session") == true,
              "a save stores the title without the status glyph: \(saved?.evidence.title ?? "nil") / \(saved?.summary ?? "nil")")

    // An earlier build's flood, written straight to disk with its glyphs: 70 minutes of ticks every 1.5 s alternating
    // ◐/◑ (the first "✳"), a Return every 30 s for the first 60 minutes (the person working), then 10 more minutes of
    // ticks with the person gone (the tool still running). Then a real title change in Terminal and two identical
    // glyph-free rows in TextEdit.
    var planted: [Evidence] = []
    let tickEvery = 1.5, tickMinutes = 70.0, workMinutes = 60.0
    var t = 0.0, n = 0
    while t < tickMinutes * 60 {
        let glyph = n == 0 ? "✳" : (n % 2 == 1 ? "◐" : "◑")
        planted.append(row("tick-\(n)", t, title: "\(glyph) Fake session alpha"))
        t += tickEvery; n += 1
    }
    let ticks = n
    var work: [String] = []
    var s = 15.0
    while s < workMinutes * 60 {
        let id = "work-\(work.count)"
        planted.append(row(id, s, kind: "keyboard.submit", title: work.count % 2 == 0 ? "◐ Fake session alpha" : "◑ Fake session alpha"))
        work.append(id); s += 30
    }
    planted.append(row("term-1", tickMinutes * 60 + 300, app: "Terminal", bundle: "com.apple.Terminal", title: "Fake build log"))
    planted.append(row("te-1", tickMinutes * 60 + 360, app: "TextEdit", bundle: "com.apple.TextEdit", title: "Budget"))
    planted.append(row("te-2", tickMinutes * 60 + 362, app: "TextEdit", bundle: "com.apple.TextEdit", title: "Budget"))
    try plantRows(store, planted)

    let ghosttyRows = planted.filter { $0.bundle == ghostty }.count
    let layers = try store.dayLayers(day: day, timezone: zone, now: now)
    let alpha = layers.activities.filter { $0.actionIDs.contains { $0.hasPrefix("tick-") || $0.hasPrefix("work-") } }
    try check(alpha.count == 1, "the flood is ONE Ghostty moment, not two interleaved ones: \(alpha.map { ($0.subject, $0.actionIDs.count) })")
    guard let moment = alpha.first else { return }
    try check(moment.subject == "Fake session alpha", "the moment's name has no glyph: \(moment.subject)")
    try check(moment.actionIDs == ["tick-0"] + work,
              "the moment holds what was done (\(work.count) Returns) and the first title row; \(ticks - 1) ticks don't count: \(moment.actionIDs.count) members")
    try check(moment.actionIDs.count <= 400 && moment.actionIDs.count <= 2000,
              "the moment fits one writer request (400) and is far under the 2,000 limit (was \(ghosttyRows) rows, split ~\(ghosttyRows / 2) per glyph)")
    try check(moment.end == at(Double(work.count - 1) * 30 + 15),
              "the moment ends at the person's last Return, not the tool's last tick 10 minutes later, so it closes 5 minutes after they stop: \(moment.end)")
    try check(moment.status == "pending" && moment.clusters.count == moment.actionIDs.count, "the moment waits for its summary like any other (status \(moment.status))")
    try check(layers.activities.allSatisfy { !$0.subject.unicodeScalars.contains(where: { "◐◑✳".unicodeScalars.contains($0) }) }, "no moment name keeps a glyph")
    let terminal = layers.activities.filter { $0.apps == ["Terminal"] }
    try check(terminal.count == 1 && terminal[0].subject == "Fake build log" && terminal[0].actionIDs == ["term-1"], "a real title change is kept: \(terminal.map(\.subject))")
    let textEdit = layers.activities.filter { $0.apps == ["TextEdit"] }
    try check(textEdit.flatMap(\.actionIDs) == ["te-1", "te-2"], "rows without a glyph are never dropped (two identical Budget rows stay): \(textEdit.map(\.actionIDs))")
    try check(layers.summary.actionCount == work.count + 1 + 3 + 1, "the day counts what was done: \(layers.summary.actionCount) of \(planted.count + 1) stored rows")

    // Perf note (the fixture): rows a minute while the tool runs, stored by the earlier build vs read now.
    let before = Double(ghosttyRows) / tickMinutes, after = Double(moment.actionIDs.count) / tickMinutes
    print(String(format: "PERF title-spinner fixture: %d Ghostty rows in %.0f min = %.1f rows/min stored by the earlier build; %d read as the moment = %.1f rows/min (%d ticks dropped)",
                 ghosttyRows, tickMinutes, before, moment.actionIDs.count, after, ticks - 1))

    // Reads, search and AI-app lines never show the glyph; the stored row keeps it (backups copy it as it is).
    let tick = try store.read("tick-1", now: now)
    try check(tick?.summary == "Viewed Fake session alpha in Ghostty." && tick?.evidence.title == "Fake session alpha",
              "`read` of an earlier build's tick: no glyph: \(tick?.summary ?? "nil")")
    let action = try store.action("tick-2", now: now)
    try check(action?.title == "Fake session alpha" && action?.description.contains("◑") == false && action.map { AssistantView.line($0) } == "Ghostty window “Fake session alpha”",
              "actions and the AI-app line: no glyph: \(action.map { AssistantView.line($0) } ?? "nil")")
    let page = try store.actions(start: start, end: start.addingTimeInterval(600), limit: 50, now: now)
    try check(!page.actions.isEmpty && page.actions.allSatisfy { !$0.title.contains("◐") && !$0.title.contains("◑") && !$0.title.contains("✳") }, "an actions page: no glyph")
    let hits = try store.searchResult(MemorySearchQuery("Fake session alpha", limit: 20), now: now).items
    try check(!hits.isEmpty && hits.allSatisfy { !$0.summary.contains("◐") && !$0.summary.contains("◑") && !$0.evidence.title.contains("◐") && !$0.evidence.title.contains("◑") },
              "search snippets: no glyph (\(hits.count) hits)")
    let settings = try store.policy()
    let raw = planted[1]
    try check(Privacy.sanitized(raw, settings: settings, now: now, presenting: false) == raw && Privacy.sanitized(raw, settings: settings, now: now)?.title == "Fake session alpha",
              "the stored row is unchanged for a backup (presenting: false) and shown without its glyph")
    // claude/int-1003: the AI tool a glyph named outlives the glyph (terminal-details' "Asked Claude Code", summary-1003's
    // prompts to it); a busy spinner names a tool but not which; other apps and plain titles carry none.
    func shown(_ title: String, app: String = "Ghostty") -> Evidence? {
        var e = raw; e.title = title; e.app = app; return Privacy.sanitized(e, settings: settings, now: now)
    }
    let claude = shown("\u{2733} Fake session alpha"), busy = shown("\u{25D0} Fake session alpha"), plain = shown("Fake session alpha")
    try check(claude?.title == "Fake session alpha" && claude?.titleTool == "Claude Code" && claude.map { ActionProjection.make($0).tool } == "Claude Code"
              && busy?.title == "Fake session alpha" && busy?.titleTool == "" && plain?.titleTool == nil
              && shown("Notes \u{25CF}", app: "Notes")?.titleTool == nil && shown("harborline \u{2014} claude")?.titleTool == nil
              && Privacy.sanitized(claude!, settings: settings, now: now)?.titleTool == "Claude Code",
              "the glyph's AI tool is kept on the row and its action once the glyph is dropped (\(claude?.titleTool ?? "nil"), \(busy?.titleTool ?? "nil"))")
    try ccLabelChecks(now: now, ghostty: ghostty)
    print("Title spinner checks use a synthetic store only (fake titles). No capture, provider, index or model.")
}

/// claude/cc-label-1003 (owner 10/03, a Claude Code session in a Ghostty tab, every prompt "Ran a command"): Claude Code
/// shows its glyph only some of the time ("✳ <topic>" waiting, "◐ / ◑" or a braille frame working, sometimes the plain
/// topic), so a prompt typed under a spinner or the plain title named no tool. Capture now remembers the tool per window
/// title (`TerminalToolMemory`), and a prompt-shaped line (`PromptShape`) agrees with the tool's process. Fake titles and
/// fake prompts only.
func ccLabelChecks(now: Date, ghostty: String) throws {
    let memory = TerminalToolMemory()
    let topic = "Fixture card review"
    let seen = ["\u{2733} " + topic, "\u{25D0} " + topic, topic, "\u{25D1} " + topic, topic].map { memory.observe(bundle: ghostty, title: $0, now: now) }
    try check(seen == ["Claude Code", "Claude Code", "Claude Code", "Claude Code", "Claude Code"],
              "cc-label: a window whose title showed Claude Code's glyph keeps the tool through spinner and plain titles (\(seen))")
    try check(memory.observe(bundle: ghostty, title: "\u{25D0} Another fixture topic", now: now) == ""
              && memory.observe(bundle: ghostty, title: "Another fixture topic", now: now) == nil
              && memory.observe(bundle: ghostty, title: "~", now: now) == nil
              && memory.observe(bundle: ghostty, title: "fixture-user \u{2014} -zsh \u{2014} ~/Projects/tally", now: now) == nil,
              "cc-label: another title is not the tool's until it shows a glyph (a bare spinner is a tool, not which one); a shell title is none")
    try check(memory.observe(bundle: "com.apple.Safari", title: "\u{2733} " + topic, now: now) == nil
              && memory.observe(bundle: ghostty, title: topic, now: now.addingTimeInterval(TerminalToolMemory.lifetime + 60)) == nil,
              "cc-label: only terminal apps, and only for a while after the tool's glyph was last seen")
    let other = TerminalToolMemory()
    try check(other.observe(bundle: ghostty, title: "harborline \u{2014} codex", now: now) == "Codex" && other.observe(bundle: ghostty, title: "harborline \u{2014} codex", now: now) == "Codex",
              "cc-label: a title naming another tool is that tool's")
    // The unit's send facts: a prompt in that window is asked of the tool, a shell line stays a command.
    let asked = SendRules.facts(bundle: ghostty, title: topic, field: "textArea", seal: .submit, terminalTool: "Claude Code")
    let ran = SendRules.facts(bundle: ghostty, title: "~", field: "textArea", seal: .submit)
    try check(asked.surface == "aiTool" && asked.to == "Claude Code" && asked.send == "detected"
              && ran.surface == "code" && ran.send == "detected" && SendRules.facts(bundle: ghostty, title: topic, field: "textArea", seal: .submit, terminalTool: "").surface == "code",
              "cc-label: a prompt in a Claude Code window is an ask to Claude Code (aiTool); a shell line or an unknown tool stays a command")
    let outcome = ComposeSend.outcome(surface: asked.surface, field: asked.field, send: asked.send, sendBy: asked.sendBy, to: asked.to)
    try check(ComposeSend.line(outcome) == "Asked Claude Code", "cc-label: its compose line is \"Asked Claude Code\" (got \(ComposeSend.line(outcome)))")
    // Prompt shape: fake prompts, real commands.
    let prompts = ["Show the Summarize Now flow as a preview. Grey button first, then the sweep over the quotes.",
                   "Fix the fixture card so the settings and the behaviour agree, and make the chart easier to read",
                   "Why does the summary say drafted when the prompt was sent?",
                   "make the button grey while it works. then show Summarizing in the footer.",
                   "Please look at Sources/MemoryUI/FixtureCard.swift and tell me what the sweep animation does there"]
    let commands = ["swift build", "git status", "ls -la", "yes do that", "cd ~/Projects && make", "swift run MacMemChecks --filter TitleSpinner",
                    "./scripts/run-checks.sh summary", "export FIXTURE_TOKEN=abc", "npm run build -- --watch", "grep -rn titleTool Sources | head"]
    try check(prompts.allSatisfy(PromptShape.natural), "cc-label: natural-language prompts are prompt-shaped (\(prompts.filter { !PromptShape.natural($0) }))")
    try check(!commands.contains(where: PromptShape.natural), "cc-label: shell commands are not (\(commands.filter(PromptShape.natural)))")
}

/// Rows written straight to disk in one transaction, as an earlier build left them.
private func plantRows(_ store: MemoryStore, _ rows: [Evidence]) throws {
    var db: OpaquePointer?
    guard sqlite3_open(store.home.appendingPathComponent("memory.sqlite").path, &db) == SQLITE_OK else { throw MemError.database("fixture open") }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw MemError.database("fixture begin") }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO records VALUES(?,?,?)", -1, &stmt, nil) == SQLITE_OK else { throw MemError.database("fixture statement") }
    for e in rows {
        let body = try json(e)
        sqlite3_reset(stmt)
        for (i, value) in [e.id, body, fingerprint(body)].enumerated() {
            _ = value.withCString { sqlite3_bind_text(stmt, Int32(i + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { sqlite3_finalize(stmt); throw MemError.database("fixture write") }
    }
    sqlite3_finalize(stmt)
    guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw MemError.database("fixture commit") }
}
