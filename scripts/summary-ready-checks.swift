// claude/ready-1002: release-readiness fixtures from the installed 0.1.4 build's own day (titles and bullets only).
// 1. Code's fallback note (every model answer failed) wrote one identical line per typing run: six "Typed a draft in
//    TextEdit." bullets, eight in Ghostty. One line now cites every run it stands for.
// 2. Terminal titles came through as the tool's status or the bare shell: "✳ Tallybird app design review", "◐ ...",
//    "🔔 ~", "~", "Terminal in cd", "claude --resume", "Terminal in login". The status glyph goes, a tool's command is the
//    tool, and a bare shell names nothing (the place names the moment). The writer and TitleClean keep one rule.
// 3. (owner) Bullets cover writing, not reading: with anything typed, sent or told, things only read (text on screen,
//    search results, an app's report) get no bullet; a moment with nothing written still says what was read.
// 4. (owner) Long moments get summaries: over 400 actions, the moment is written in segments of about 150 (cut where
//    the conversation changes, never inside a typing run) and merged into one card.
// Synthetic requests only: no model, no store, no capture, no network.
import Foundation
import MemoryCore
import WriterBackend

var failures = 0, passes = 0
func check(_ ok: Bool, _ name: String) {
    if ok { passes += 1; print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
func request(_ id: String, _ actions: [[String: Any]]) throws -> CanonicalNoteRequest {
    var rows = [[String: Any]]()
    for (i, a) in actions.enumerated() {
        var row: [String: Any] = ["id": "\(id)-\(i + 1)", "at": String(format: "2026-09-24T16:%02d:00Z", 10 + i), "site": "", "revision": "r1", "state": "observed"]
        for (k, v) in a { row[k] = v }
        rows.append(row)
    }
    let json: [String: Any] = ["id": id, "schemaVersion": 1, "targetKind": "activity", "targetID": id, "day": "2026-09-24", "timezone": "UTC",
                               "inputRevision": id, "policyRevision": "p", "expiresAt": "2099-01-01T00:00:00Z", "actions": rows, "actionCount": rows.count]
    return try JSONDecoder().decode(CanonicalNoteRequest.self, from: JSONSerialization.data(withJSONObject: json))
}
/// One typing run with its own (fictional) words: each is its own item in the view, as on the owner's Mac.
func run(_ app: String, _ title: String, _ i: Int, state: String = "draft", sendBy: String? = nil) -> [String: Any] {
    var a: [String: Any] = ["kind": "keyboard.text_input", "app": app, "title": title, "surface": "writing",
                            "description": "Typed a draft in \(app). Fictional grocery list item \(i) for the weekend",
                            "state": state, "send": sendBy == nil ? "unknown" : "detected", "runID": "run-\(app)-\(i)"]
    if let sendBy { a["sendBy"] = sendBy }
    return a
}
func window(_ app: String, _ title: String, site: String = "") -> [String: Any] {
    ["kind": "window.changed", "app": app, "title": title, "site": site, "description": "Observed \(title) in \(app); reading is not established."]
}

@main struct SummaryReadyChecks {
    static func main() async throws {
        try fallbackLines()
        try terminalTitles()
        try controls()
        try catchupPolish()
        try writingNotReading()
        try await longMoments()
        print("summary-ready: \(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func fallbackLines() throws {
        // Six runs in one TextEdit window (the 06:02 moment): one line citing all six.
        for (app, n) in [("TextEdit", 6), ("Ghostty", 8), ("Messages", 4)] {
            let r = try request("fb-\(app)", (0..<n).map { run(app, app == "Messages" ? "Fictional Friend" : "Untitled 12", $0) })
            let v = try ModelView(request: r, actions: r.actions, appNames: [:])
            check(v.items.filter { $0.kind == .typed }.count == n, "fallback \(app): fixture has \(n) separate typing runs")
            do {
                let f = try CanonicalGrounding.fallbackNote(r, view: v)
                let texts = f.bullets.map(\.text)
                check(Set(texts).count == texts.count, "fallback \(app): no repeated line (got \(texts))")
                check(texts.count == 1 && f.bullets[0].actionIDs.count == n, "fallback \(app): one line cites all \(n) runs (got \(texts.count) lines)")
                check(f.bullets[0].assertion == "draft", "fallback \(app): drafts stay drafts (got \(f.bullets[0].assertion))")
                check((try? CanonicalGrounding.check(f, request: r, view: v)) == f, "fallback \(app): check accepts code's own note")
            } catch { check(false, "fallback \(app): fallback note written (threw \(error))") }
        }
        // Drafts and sends in one place stay two lines: a send is never folded into a draft or the other way round.
        let mixed = try request("fb-mixed", [run("ChatGPT", "ChatGPT", 1), run("ChatGPT", "ChatGPT", 2, state: "submitted", sendBy: "return"),
                                             run("ChatGPT", "ChatGPT", 3), run("ChatGPT", "ChatGPT", 4, state: "submitted", sendBy: "return")])
        let mv = try ModelView(request: mixed, actions: mixed.actions, appNames: [:])
        if let f = try? CanonicalGrounding.fallbackNote(mixed, view: mv) {
            let byText = Dictionary(grouping: f.bullets, by: \.text)
            check(byText.count == f.bullets.count, "fallback mixed: no repeated line (got \(f.bullets.map(\.text)))")
            let sends = f.bullets.filter { $0.text.hasPrefix("Used the send key") }
            let drafts = f.bullets.filter { $0.text.hasPrefix("Typed a draft") }
            check(sends.count == 1 && sends[0].assertion == "submitted" && sends[0].actionIDs.count == 2, "fallback mixed: both sends in one submitted line")
            check(drafts.count == 1 && drafts[0].assertion == "draft" && drafts[0].actionIDs.count == 2, "fallback mixed: both drafts in one draft line")
            check(f.bullets.allSatisfy { b in CanonicalGrounding.coreClaimProblem(f.title, b, mixed.actions.filter { b.actionIDs.contains($0.id) }) == nil },
                  "fallback mixed: core's claim rule accepts every line")
            check((try? CanonicalGrounding.check(f, request: mixed, view: mv)) == f, "fallback mixed: check accepts code's own note")
        } else { check(false, "fallback mixed: fallback note written") }
    }

    static func terminalTitles() throws {
        let cases: [(String, String)] = [
            ("✳ Tallybird app design review", "Tallybird app design review"), ("◐ Tallybird app design review", "Tallybird app design review"),
            ("◑ Tallybird app design review", "Tallybird app design review"), ("⠋ Fixing the sync test", "Fixing the sync test"),
            ("claude --resume", "Claude Code"), ("claude · resume", "Claude Code"), ("claude --resume recent", "Claude Code"), ("codex", "Codex"),
            ("🔔 ~", ""), ("~", ""), ("cd", ""), ("-zsh", ""), ("login — 120×30", ""), ("sam — -zsh — 80×24", "sam"),
        ]
        for (raw, want) in cases {
            check(TitleClean.terminalName(raw) == want, "TitleClean.terminalName \"\(raw)\" -> \"\(want)\" (got \"\(TitleClean.terminalName(raw))\")")
            let ui = TitleClean.clean(raw, app: "Ghostty")
            check(want.isEmpty ? ui == "Ghostty" : !ui.contains("✳") && !ui.contains("◐") && !ui.contains("⠋") && !ui.isEmpty,
                  "TitleClean.clean in Ghostty \"\(raw)\": no glyph or bare shell (got \"\(ui)\")")
            for app in ["Ghostty", "Terminal"] {
                let r = try request("t", [window(app, raw)])
                let v = try ModelView(request: r, actions: r.actions, appNames: [:])
                guard let n = try? CanonicalGrounding.codeNote(r, view: v) else { check(false, "code note \(app) \"\(raw)\" written"); continue }
                let bad = ["✳", "◐", "◑", "⠋", "🔔", "--resume", "· resume", "×"].contains { n.title.contains($0) }
                    || ["~", "cd", "-zsh", "Terminal in cd", "Terminal in login"].contains(n.title)
                check(!bad, "code note \(app) \"\(raw)\": title \"\(n.title)\" is a name, not the tool status or the shell")
                if !want.isEmpty && want != "sam" { check(n.title == want, "code note \(app) \"\(raw)\" -> \"\(want)\" (got \"\(n.title)\")") }
                check((try? CanonicalGrounding.check(n, request: r, view: v)) == n, "code note \(app) \"\(raw)\": check accepts it")
            }
        }
    }

    static func controls() throws {
        // Unchanged: a terminal in a project, a path, and a page on X.
        for (title, want) in [("harborline — zsh", "Terminal in harborline"), ("~/code/tallybird", "Terminal in tallybird")] {
            let r = try request("c", [window("Terminal", title)])
            let v = try ModelView(request: r, actions: r.actions, appNames: [:])
            let n = try? CanonicalGrounding.codeNote(r, view: v)
            check(n?.title == want, "control: \"\(title)\" -> \"\(want)\" (got \"\(n?.title ?? "nil")\")")
        }
        let x = try request("x", (0..<4).map { _ in window("Google Chrome", "Home / X", site: "https://x.com") })
        let xv = try ModelView(request: x, actions: x.actions, appNames: [:])
        let xn = try? CanonicalGrounding.codeNote(x, view: xv)
        check(xn != nil && (try? CanonicalGrounding.check(xn!, request: x, view: xv)) == xn, "control: four views of Home / X get a code note")
        check(TitleClean.clean("Weekly summaries export by riley · Pull Request #418 · daydream/daydream", app: "Google Chrome", site: "https://github.com")
              == "PR #418: Weekly summaries export", "control: TitleClean outside a terminal is unchanged")
        // claude/title-spinner-1003 (audit B1/S4): a status glyph at either end is dropped in every app, not only terminals.
        check(TitleClean.clean("✳ Launch notes", app: "Notes") == "Launch notes", "control: a status glyph outside a terminal is dropped too (title-spinner-1003)")
        check(TitleClean.clean("Plan ★ v2", app: "Notes") == "Plan ★ v2", "control: a glyph inside a title is left as written")
    }

    /// claude/catchup-1003 (audit P1-P3): Siri's "Maybe:" prefix, the home folder as the account name, a person's name as a topic.
    static func catchupPolish() throws {
        func note(_ id: String, _ actions: [[String: Any]]) throws -> (CanonicalNoteOutput?, CanonicalNoteRequest, ModelView) {
            let r = try request(id, actions)
            let v = try ModelView(request: r, actions: r.actions, appNames: [:])
            return (try? CanonicalGrounding.codeNote(r, view: v), r, v)
        }
        let (texts, tr, tv) = try note("maybe", [window("Messages", "Maybe: Maya Chen")])
        check(texts.map { !$0.title.contains("Maybe") && !$0.bullets.contains { $0.text.contains("Maybe") } } == true,
              "Messages \"Maybe: <name>\": no \"Maybe:\" in the code note (title \(texts?.title ?? "nil"), \(texts?.bullets.map(\.text) ?? []))")
        check(texts.map { (try? CanonicalGrounding.check($0, request: tr, view: tv)) == $0 } == true, "Messages \"Maybe:\": check accepts the code note")
        // The account's own name is the home folder (NSUserName at run time; never printed by a check).
        let home = NSUserName()
        for app in ["Terminal", "Ghostty"] {
            let (n, r, v) = try note("home-\(app)", [window(app, home + " \u{2014} -zsh \u{2014} 80\u{00D7}24")])
            check(n.map { !$0.title.contains(home) && !$0.bullets.contains { $0.text.contains(home) } } == true,
                  "\(app) at the home folder: the account name is not a folder in the code note")
            check(n.map { (try? CanonicalGrounding.check($0, request: r, view: v)) == $0 } == true, "\(app) at the home folder: check accepts the code note")
        }
        let (proj, _, _) = try note("proj", [window("Terminal", "harborline \u{2014} -zsh \u{2014} 80\u{00D7}24")])
        check(proj?.title == "Terminal in harborline", "control: a project folder still names the terminal (got \(proj?.title ?? "nil"))")
        // A person's name a page is about keeps its capital ("Looked at Sam Lee.", never "sam Lee").
        let (page, _, _) = try note("person", (0..<2).map { _ in window("Google Chrome", "Sam Lee", site: "https://example.org/profile") })
        let lines = (page?.bullets.map(\.text) ?? []) + [page?.title ?? ""]
        check(!lines.contains { $0.contains("sam Lee") }, "a person's name as a topic keeps its capital (\(lines))")
        check(CanonicalGrounding.siriSuggestion("Maybe: Sam") == "Sam" && CanonicalGrounding.siriSuggestion("Maybelline") == "Maybelline",
              "siriSuggestion drops only the \"Maybe:\" prefix")
    }

    static func searched(_ q: String) -> [String: Any] {
        ["kind": "page.viewed", "app": "Google Chrome", "title": "\(q) - Google Search", "site": "https://www.google.com",
         "description": "Viewed search results for \"\(q)\"."]
    }
    static func reported(_ app: String) -> [String: Any] {
        ["kind": "ai.reply", "app": app, "title": app, "state": "reported", "description": "\(app) reported: the fictional export test passes on the sample file."]
    }
    static func writingNotReading() throws {
        let rule = "Bullets say what was WRITTEN, SENT or DRAFTED"
        check(CanonicalGrounding.instruction.contains(rule), "writing rule: the model's instruction says bullets cover writing")
        check(CanonicalGrounding.instruction.contains("Things only read (text on screen, search results, REPORT) get a bullet only if nothing was."),
              "writing rule: the instruction leaves out things only read when something was written")
        check(!CanonicalGrounding.instruction.contains("a quote, SENT or a tag (REPORT,"), "writing rule: REPORT and quotes are no longer required in a bullet")
        // The local template refuses an instruction over 8,192 bytes (QwenNoThinkingTemplate): every note would fail.
        check(CanonicalGrounding.instruction.utf8.count <= 8192, "writing rule: the instruction fits the local template (\(CanonicalGrounding.instruction.utf8.count) bytes)")
        // A draft plus a search and an AI app's report: the fallback note says only the draft.
        let r = try request("wr", [run("Notes", "Weekend list", 1), searched("cabins near sintra"), reported("ChatGPT")])
        let v = try ModelView(request: r, actions: r.actions, appNames: [:])
        for (name, view) in [("writing", v)] + (try ["unnamed text": ModelView(request: request("un", [["kind": "keyboard.text_input", "app": "Messages", "title": "Messages", "surface": "text",
                "description": "Typed a draft in Messages. running late", "state": "submitted", "send": "detected", "sendBy": "return", "runID": "u1"]]), actions: request("un", [["kind": "keyboard.text_input", "app": "Messages", "title": "Messages", "surface": "text",
                "description": "Typed a draft in Messages. running late", "state": "submitted", "send": "detected", "sendBy": "return", "runID": "u1"]]).actions, appNames: [:])].map { ($0.key, $0.value) }) {
            let n = CanonicalGrounding.instruction(for: view).utf8.count
            check(n <= 8192, "writing rule: the \(name) instruction fits the local template (\(n) bytes)")
        }
        let kinds = Set(v.items.map(\.kind))
        check(kinds.contains(.typed) && kinds.contains(.search) && kinds.contains(.report), "writing rule: fixture has a draft, a search and a report (got \(kinds))")
        if let f = try? CanonicalGrounding.fallbackNote(r, view: v) {
            let texts = f.bullets.map(\.text)
            check(texts == ["Typed a draft in Notes."], "writing rule fallback: only the draft line (got \(texts))")
            check(!texts.contains { $0.contains("search results") || $0.contains("reported") }, "writing rule fallback: no reading line")
            check((try? CanonicalGrounding.check(f, request: r, view: v)) == f, "writing rule fallback: check accepts it without citing what was read")
        } else { check(false, "writing rule fallback: note written") }
        // A model answer that also gave the search its own bullet: that bullet is left out, the draft's stays.
        let typed = v.items.first { $0.kind == .typed }!.alias, search = v.items.first { $0.kind == .search }!.alias
        let raw = #"{"title":"Weekend list","bullets":[{"ids":["\#(typed)"],"text":"Wrote a weekend list in Notes."},{"ids":["\#(search)"],"text":"Searched results for cabins near sintra on Google."}]}"#
        do {
            let out = try CanonicalGrounding.validate(raw, request: r, view: v, provider: "local/qwen3.5-4b-q4_k_m")
            check(out.bullets.count == 1 && out.bullets[0].text.hasPrefix("Wrote"), "writing rule model: the reading bullet is left out (got \(out.bullets.map(\.text)))")
            check((try? CanonicalGrounding.check(out, request: r, view: v)) == out, "writing rule model: check accepts the writing-only note")
        } catch { check(false, "writing rule model: the writing-only answer validates (threw \(error))") }
        // An answer with only the draft's bullet is complete: the search and the report needn't be cited.
        let only = #"{"title":"Weekend list","bullets":[{"ids":["\#(typed)"],"text":"Wrote a weekend list in Notes."}]}"#
        check((try? CanonicalGrounding.validate(only, request: r, view: v, provider: "local/qwen3.5-4b-q4_k_m")) != nil, "writing rule model: a writing-only answer covers the moment")
        // Nothing written: what was read is still said, and must be cited.
        let rr = try request("rd", [searched("cabins near sintra"), reported("ChatGPT")])
        let rv = try ModelView(request: rr, actions: rr.actions, appNames: [:])
        if let f = try? CanonicalGrounding.fallbackNote(rr, view: rv) {
            check(f.bullets.contains { $0.text.contains("search results") } && f.bullets.contains { $0.text.contains("reported") },
                  "writing rule fallback: with nothing written, the reading is said (got \(f.bullets.map(\.text)))")
        } else { check(false, "writing rule fallback: reading-only note written") }
        let none = #"{"title":"Cabins","bullets":[{"ids":["i1"],"text":"Searched Google for cabins near sintra."}]}"#
        check((try? CanonicalGrounding.validate(none, request: rr, view: rv, provider: "local/qwen3.5-4b-q4_k_m")) == nil,
              "writing rule model: with nothing written, leaving the report out is still a coverage problem")
    }

    struct Replay: LocalInference {
        let text: String
        func load() async throws {}
        func generate(instruction: String, evidence: String, maxTokens: Int) async throws -> Data { Data(text.utf8) }
        func unload() async {}
    }
    actor Commits { var outputs: [CanonicalNoteOutput] = []; func add(_ o: CanonicalNoteOutput) { outputs.append(o) } }
    /// A long moment: `ghostty` rows in a terminal, then `chat` rows in ChatGPT; word-less typing runs of 10 rows each
    /// with their windows between (one run item per app in a view, as on the owner's Mac).
    static func long(_ id: String, ghostty: Int, chat: Int) throws -> CanonicalNoteRequest {
        var rows: [[String: Any]] = []
        for i in 0..<(ghostty + chat) {
            let terminal = i < ghostty
            let app = terminal ? "Ghostty" : "ChatGPT", title = terminal ? "harborline — zsh" : "ChatGPT"
            let at = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_790_000_000 + Double(i) * 6))
            var row: [String: Any] = ["id": String(format: "\(id)-%04d", i), "at": at, "app": app, "title": title, "site": "", "revision": "r1"]
            if i % 2 == 0 {
                row["kind"] = "window.changed"; row["state"] = "observed"; row["description"] = "Observed \(title) in \(app); reading is not established."
            } else {
                row["kind"] = "keyboard.text_input"; row["state"] = "draft"; row["description"] = "Typed a draft in \(app)."
                row["surface"] = terminal ? "terminal" : "ai"; row["send"] = "unknown"; row["runID"] = "\(app)-run-\(i / 20)"
            }
            rows.append(row)
        }
        let json: [String: Any] = ["id": id, "schemaVersion": 1, "targetKind": "activity", "targetID": id, "day": "2026-09-21", "timezone": "UTC",
                                   "inputRevision": id, "policyRevision": "p", "expiresAt": "2099-01-01T00:00:00Z", "actions": rows, "actionCount": rows.count]
        return try JSONDecoder().decode(CanonicalNoteRequest.self, from: JSONSerialization.data(withJSONObject: json))
    }
    static func longMoments() async throws {
        let r = try long("lm", ghostty: 260, chat: 240)
        check(r.actions.count == 500 && r.actions.count > CanonicalGrounding.maxActions, "long: the fixture is over one view's 400 actions")
        check((try? ModelView(request: r, actions: r.actions, appNames: [:])) == nil, "long: one ITEMS view refuses it (capacity), as before")
        guard let chunks = try CanonicalGrounding.chunks(r, actions: r.actions) else { check(false, "long: written in segments"); return }
        let sizes = chunks.map(\.actions.count)
        check(chunks.count >= 2 && chunks.count <= CanonicalGrounding.maxChunks * 2 && sizes.allSatisfy { $0 <= CanonicalGrounding.maxActions },
              "long: \(chunks.count) segments, each one view (sizes \(sizes))")
        check(sizes.allSatisfy { $0 <= CanonicalGrounding.chunkActions + 50 }, "long: segments of about \(CanonicalGrounding.chunkActions) actions (sizes \(sizes))")
        let ordered = r.actions.sorted { ($0.at, $0.id) < ($1.at, $1.id) }.map(\.id)
        check(chunks.flatMap { $0.actions.map(\.id) } == ordered, "long: the segments hold every action once, in order")
        var ends = 0, splitRuns = 0
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            if let last = a.actions.last, let first = b.actions.first {
                ends += 1
                if let x = last.runID, x == first.runID { splitRuns += 1 }
            }
        }
        check(splitRuns == 0 && ends == chunks.count - 1, "long: no segment boundary falls inside a typing run")
        check(chunks.contains { $0.actions.last?.app == "Ghostty" && $0.actions.count > 0 } && chunks.contains { $0.actions.first?.app == "ChatGPT" && $0.actions.first?.id == "lm-0260" },
              "long: a segment ends where the terminal conversation ends and the ChatGPT one starts")
        // Merged from each segment's note: one card, every line once, every typed row cited.
        let notes = try chunks.map { try CanonicalGrounding.fallbackNote(r, view: $0.view) }
        do {
            let merged = try CanonicalGrounding.mergeChunks(r, notes: notes, chunks: chunks)
            let texts = merged.bullets.map(\.text)
            // claude/summary-1003 (owner): word-less terminal typing is a command ("Typed a command in harborline."), never
            // "Typed a draft in Ghostty.".
            check(Set(texts).count == texts.count && texts.contains("Typed a command in harborline.") && texts.contains("Typed a draft in ChatGPT."),
                  "long merge: each line once across segments (got \(texts))")
            let typed = Set(r.actions.filter { $0.kind == "keyboard.text_input" }.map(\.id))
            check(typed.isSubset(of: Set(merged.bullets.flatMap(\.actionIDs))), "long merge: every typed row is cited")
            check(merged.generator == CanonicalGrounding.fallbackProvider && merged.generatorVersion == CanonicalGrounding.fallbackVersion
                  && merged.bullets.allSatisfy { !["sent", "submitted"].contains($0.assertion) }, "long merge: code's fallback pair; drafts are never called sent")
            check(merged.title == "Terminal in harborline" || merged.title == "ChatGPT" || !merged.title.isEmpty, "long merge: titled by its largest segment (\(merged.title))")
            check((try? CanonicalGrounding.checkChunked(merged, request: r, chunks: chunks)) == merged, "long merge: the final check accepts it")
            var dropped = merged; dropped.bullets.removeLast()
            check((try? CanonicalGrounding.checkChunked(dropped, request: r, chunks: chunks)) == nil, "long merge: a note missing a segment's writing is refused (coverage)")
            var claimed = merged; claimed.bullets[0].assertion = "sent"
            check((try? CanonicalGrounding.checkChunked(claimed, request: r, chunks: chunks)) == nil, "long merge: a label not derived from the actions is refused")
        } catch { check(false, "long merge: merged (threw \(error))") }
        // The local writer end to end through the adapter: committed once, never pending as too long.
        let commits = Commits()
        let port = CoreWriterPort(prepare: { _ in r }, page: { _, _ in WriterActionPage(actions: [], next: nil, actionCount: r.actionCount) },
                                  commit: { out in await commits.add(out); return WriterCommitReceipt(id: "lm", version: 1, inputRevision: "lm", status: "generated_unverified", output: out) },
                                  cancel: { _ in }, permitted: { _, _ in true })
        let writer = CanonicalLocalWriter(runtime: Replay(text: "not json"), policy: { _, _ in true })
        let adapter = CoreWriterAdapter(core: port, generate: { rq, acts in try await writer.generate(rq, completeActions: acts) })
        var outcome = "threw"
        do {
            switch try await adapter.process(WriterTarget(kind: .activity, day: "2026-09-21", timezone: "UTC", activityID: "lm"), lastActivity: .distantPast) {
            case .committed(let rc): outcome = "committed \(rc.output.bullets.count)"
            case .pending(let p): outcome = "pending(\(p.reason.rawValue))"
            }
        } catch { outcome = "threw \(error)" }
        let saved = await commits.outputs
        check(outcome.hasPrefix("committed") && saved.count == 1, "long adapter: a 500-action moment is committed once (got \(outcome))")
        check(saved.first.map { Set($0.bullets.map(\.text)).count == $0.bullets.count } ?? false, "long adapter: its card repeats no line")
        // Over the segment bound: still pending as too long, never truncated.
        let huge = try long("lh", ghostty: 1100, chat: 901)
        var hugeThrew = false
        do { _ = try CanonicalGrounding.chunks(huge, actions: huge.actions) } catch { hugeThrew = true }
        check(hugeThrew && huge.actions.count > CanonicalGrounding.maxChunkedActions,
              "long: over \(CanonicalGrounding.maxChunkedActions) actions is still too long (capacity)")
        let hugePort = CoreWriterPort(prepare: { _ in huge }, page: { _, _ in WriterActionPage(actions: [], next: nil, actionCount: huge.actionCount) },
                                      commit: { out in WriterCommitReceipt(id: "lh", version: 1, inputRevision: "lh", status: "generated_unverified", output: out) },
                                      cancel: { _ in }, permitted: { _, _ in true })
        let hugeAdapter = CoreWriterAdapter(core: hugePort, generate: { rq, acts in try await writer.generate(rq, completeActions: acts) })
        var hugeOutcome = "threw"
        if case .pending(let p)? = try? await hugeAdapter.process(WriterTarget(kind: .activity, day: "2026-09-21", timezone: "UTC", activityID: "lh"), lastActivity: .distantPast) {
            hugeOutcome = p.reason.rawValue
        }
        check(hugeOutcome == "capacity", "long adapter: over the bound it stays pending (capacity) with every action (got \(hugeOutcome))")
        // A short moment is one view, as before.
        let short = try long("ls", ghostty: 40, chat: 40)
        let shortChunks = try CanonicalGrounding.chunks(short, actions: short.actions)
        check(shortChunks == nil, "long: a short moment is one view, no segments")
        check(CanonicalGrounding.maxChunkedActions == 2000, "long: the Today page's too-long bound (DaydreamSummaryLimit.actions) is the writer's segment bound")
    }
}
