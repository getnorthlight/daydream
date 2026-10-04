// claude/summary-1003 (owner, 10/3): terminal and AI-tool summaries. On the installed 0.1.4 build a Ghostty card (a Claude
// Code session, window "✳ Tallybird app design review") read "Typed a draft in Ghostty. / Used the send key in Ghostty. /
// Requested the option to summarize immediately. / Wrote code in Ghostty. / Noted that the current summary is
// confusing. / Wrote code in Ghostty." It should read "Asked Claude Code to add a Summarize Now option. / Told Claude
// Code the current summary is confusing."
// 1. AI coding tools: a line typed in a terminal whose window shows Claude Code, Codex, Gemini CLI or Aider (the writer
//    and TitleClean keep one rule), or that follows a line starting one, is a prompt to it ("Asked/Told Claude Code").
// 2. Shell commands are said by purpose in one line, never "Wrote code in Ghostty" or "Edited <project>".
// 3. Never filler beside real lines; each line once; about 4 at most (SummaryLines, every surface).
// 4. Why lines were mixed: salvage wrote one code line per item with no dedupe ("Wrote code in Ghostty." twice), a
//    whole path read as a secret so a script was never a command, and the card joined members' notes as they were.
// Synthetic actions and a scripted model only: no store, no capture, no network, no typed words printed.
import Foundation
import MemoryCore
import WriterBackend

var failures = 0, passes = 0
func check(_ ok: Bool, _ name: String) {
    if ok { passes += 1; print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
struct Row { var app = "Ghostty"; var title: String; var text: String? = nil; var sent = true; var tool: String? = nil; var kind: String? = nil
    init(app: String = "Ghostty", title: String, text: String? = nil, sent: Bool = true, tool: String? = nil, kind: String? = nil) { self.app = app; self.title = title; self.text = text; self.sent = sent; self.tool = tool; self.kind = kind } }
func request(_ id: String, _ specs: [Row]) throws -> CanonicalNoteRequest {
    var out = [[String: Any]]()
    for (i, s) in specs.enumerated() {
        var row: [String: Any] = ["id": "\(id)-\(i + 1)", "at": String(format: "2026-10-02T21:%02d:00Z", 10 + i), "app": s.app, "title": s.title, "site": "", "revision": "r1"]
        if let tool = s.tool { row["tool"] = tool }
        if let text = s.text {
            row["kind"] = "keyboard.text_input"; row["state"] = s.sent ? "submitted" : "draft"
            row["description"] = "Typed a draft in \(s.app). " + text
            row["surface"] = "code"; row["send"] = s.sent ? "detected" : "unknown"; row["runID"] = "\(id)-run-\(i)"
            if s.sent { row["sendBy"] = "return" }
        } else if let kind = s.kind {
            // claude/summary-fail-1003: the other rows a real session holds (Return, a click, a shortcut, the app coming forward);
            // cc-label-1003's wording for Return and an activation.
            row["kind"] = kind; row["state"] = kind == "keyboard.submit" ? "draft" : "observed"
            if kind == "keyboard.submit" { row["title"] = "" }
            row["description"] = ["keyboard.submit": "Pressed Return in \(s.app); submission and reading are not established.", "mouse.click": "Clicked in \(s.app).",
                                  "keyboard.shortcut": "Used a keyboard shortcut in \(s.app).", "app.activated": "Recorded an app activation in \(s.app)."][kind] ?? "Observed \(s.app)."
        } else {
            row["kind"] = "window.changed"; row["state"] = "observed"; row["description"] = "Observed \(s.title) in \(s.app); reading is not established."
        }
        out.append(row)
    }
    let json: [String: Any] = ["id": id, "schemaVersion": 1, "targetKind": "activity", "targetID": id, "day": "2026-10-02", "timezone": "UTC",
                               "inputRevision": id, "policyRevision": "p", "expiresAt": "2099-01-01T00:00:00Z", "actions": out, "actionCount": out.count]
    return try JSONDecoder().decode(CanonicalNoteRequest.self, from: JSONSerialization.data(withJSONObject: json))
}
let cc = "✳ Tallybird app design review", busy = "⠐ Tallybird app design review", shell = "harborline — zsh"
// Fictional prompts (not the owner's words).
let ask = "add an option to summarize a moment right now, a Summarize Now button on the card"
let tell = "the current summary is confusing, it mixes filler lines with the real ones"
let yes = "yes do that"
let generic = ["Typed a draft in", "Used the send key in", "Wrote code in", "Pressed Return", "Edited harborline", "Ran a command in"]

/// Answers from the ITEMS view: one bullet per request when the view names the tool, else the owner's model's words.
struct Scripted: LocalInference {
    func load() async throws {}
    func unload() async {}
    func generate(instruction: String, evidence: String, maxTokens: Int) async throws -> Data {
        var bullets: [[String: Any]] = []
        for line in evidence.split(separator: "\n").map(String.init) {
            guard let r = line.range(of: #"^i\d+\."#, options: .regularExpression) else { continue }
            let id = String(line[r].dropLast())
            if line.contains("Own captured requests") {
                bullets.append(["ids": [id], "text": "Asked Claude Code to add a Summarize Now option to the card."])
                bullets.append(["ids": [id], "text": "Told Claude Code the summary is confusing."])
            } else if line.contains("Start with: Asked Claude Code") {
                bullets.append(["ids": [id], "text": line.contains("confusing") ? "Told Claude Code the summary is confusing." : "Asked Claude Code to add a Summarize Now option to the card."])
            } else if line.contains("typed") {
                bullets.append(["ids": [id], "text": "Wrote code in Ghostty."])
            }
        }
        return try JSONSerialization.data(withJSONObject: ["title": "Summarize Now option", "bullets": bullets])
    }
}
struct Garbage: LocalInference {
    func load() async throws {}
    func unload() async {}
    func generate(instruction: String, evidence: String, maxTokens: Int) async throws -> Data { Data("not json".utf8) }
}
func write(_ r: CanonicalNoteRequest, _ runtime: any LocalInference) async -> CanonicalNoteOutput? {
    try? await CanonicalLocalWriter(runtime: runtime, policy: { _, _ in true }).generate(r, completeActions: r.actions)
}
func noGeneric(_ texts: [String]) -> Bool { !texts.contains { t in generic.contains { t.hasPrefix($0) } } }

@main struct SummaryTerminalChecks {
    static func main() async throws {
        toolDetection()
        try await claudeSession()
        try await twoLongPrompts()
        try await shellSession()
        try await mixedSession()
        try salvageRepeats()
        try await liveSession()
        summaryLines()
        print("summary-terminal: \(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func toolDetection() {
        let cases: [(String, String?)] = [
            ("✳ Tallybird app design review", "Claude Code"), ("⠐ Tallybird app design review", "Claude Code"), ("⠋ Fixing the sync test", "Claude Code"),
            ("✶ Working", "Claude Code"), ("harborline — claude", "Claude Code"), ("claude --resume", "Claude Code"), ("Claude Code — harborline", "Claude Code"),
            ("codex", "Codex"), ("harborline — codex", "Codex"), ("codex: fix the flaky test", "Codex"), ("◇  Ready (harborline)", "Gemini CLI"),
            ("✦  Working… (harborline)", "Gemini CLI"), ("aider --model sonnet", "Aider"),
            ("harborline — zsh", nil), ("~", nil), ("🔔 ~", nil), ("◐ Tallybird app design review", nil), ("sam — -zsh — 80×24", nil),
            ("Codexes and manuscripts", nil), ("claudette's notes", nil), ("", nil),
        ]
        for (title, want) in cases {
            let writer = CanonicalGrounding.terminalTool(title: title), ui = TitleClean.terminalTool(title)
            check(writer == want && ui == want, "tool: \"\(title)\" -> \(want ?? "none") (writer \(writer ?? "none"), TitleClean \(ui ?? "none"))")
        }
    }

    static func claudeSession() async throws {
        let r = try request("cc", [Row(title: cc), Row(title: cc, text: ask), Row(title: busy, text: tell), Row(title: cc, text: yes)])
        let local = try ModelView(request: r, actions: r.actions, appNames: [:], localIntentSessions: true)
        check(local.text.contains("Ghostty (AI tool)") && local.text.contains("to \"Claude Code\"") && local.text.contains("Start with: Asked Claude Code, Told Claude Code"),
              "claude: the local view says the prompts went to Claude Code and how a line may start")
        check(local.items.filter { $0.kind == .typed }.count == 1 && local.text.contains("Request 3:"),
              "claude: three prompts (one window, its status glyph changing) are one session item with three requests")
        check(CanonicalGrounding.instruction(for: local).contains("one short bullet for each distinct request"), "claude: the local instruction asks one bullet per request")
        check((try? QwenNoThinkingTemplate.render(instruction: CanonicalGrounding.instruction(for: local), evidence: local.text, prefill: CanonicalGrounding.prefill)) != nil,
              "claude: the session instruction fits the local template's 8,192 bytes (the model is never handed an input it refuses)")
        // claude/int-1003: reads drop the glyph (title-spinner-1003); core keeps the tool it named on the action.
        let plain = try request("cc-plain", [Row(title: "Fixture parser review", text: ask, tool: "Claude Code"),
                                             Row(title: "Fixture parser review", text: tell, tool: "")])
        let plainView = try ModelView(request: plain, actions: plain.actions, appNames: [:])
        check(plainView.text.contains("to \"Claude Code\"") && !plainView.text.contains("Ran a command"),
              "claude: a title whose glyph reads dropped is still Claude Code's (the action's tool)")
        let cloud = try ModelView(request: r, actions: r.actions, appNames: [:])
        check(cloud.items.filter { $0.kind == .typed }.count == 3 && cloud.text.components(separatedBy: "Start with: Asked Claude Code").count == 4,
              "claude: the cloud view keeps three prompts, each to Claude Code")
        guard let note = await write(r, Scripted()) else { check(false, "claude: a note is written"); return }
        let texts = note.bullets.map(\.text)
        print("  claude session -> \(texts)")
        check(texts == ["Asked Claude Code to add a Summarize Now option to the card.", "Told Claude Code the summary is confusing."],
              "claude: Asked/Told Claude Code, one line per request, no filler (got \(texts))")
        check(note.bullets.allSatisfy { $0.assertion == "submitted" } && note.generatorVersion == CanonicalGrounding.localVersion, "claude: submitted lines from the model")
        check((try? CanonicalGrounding.check(note, request: r, view: local)) == note, "claude: the final check accepts two bullets citing one session")
        // The owner's model line ("Requested ...") with no tool named is refused as a lead now: a send must say who.
        let vague = #"{"title":"Summarize Now option","bullets":[{"ids":["i1"],"text":"Requested the option to summarize immediately."}]}"#
        check((try? CanonicalGrounding.validate(vague, request: r, view: local, provider: "local/qwen3.5-4b-q4_k_m")) == nil, "claude: a line that doesn't say it was asked of Claude Code is refused")
        // Every model answer fails: code's fallback asks the tool, never "Used the send key in Ghostty".
        guard let fallback = await write(r, Garbage()) else { check(false, "claude: fallback written"); return }
        print("  claude session, no model answer -> \(fallback.bullets.map(\.text))")
        // claude/cc-label-1003 (owner 10/03): never a bare "Asked Claude Code."; code says what about (the session title).
        check(fallback.bullets.map(\.text) == ["Asked Claude Code about \u{201C}Tallybird app design review\u{201D} (3 prompts)."] && fallback.generatorVersion == CanonicalGrounding.fallbackVersion,
              "claude: code's fallback says what the prompts were about (got \(fallback.bullets.map(\.text)))")
        check(fallback.bullets.allSatisfy { b in CanonicalGrounding.coreClaimProblem(fallback.title, b, r.actions.filter { b.actionIDs.contains($0.id) }) == nil },
              "claude: core's claim rule accepts the fallback")
        // A tool started by a typed line in a plain shell window: the lines after it are prompts, until a shell command.
        let started = try request("st", [Row(title: "~", text: "claude"), Row(title: "~", text: ask), Row(title: "~", text: "swift build")])
        let sv = try ModelView(request: started, actions: started.actions, appNames: [:])
        check(sv.text.contains("Start with: Asked Claude Code") && sv.text.components(separatedBy: "(AI tool)").count == 2,
              "claude: after \"claude\" is typed, the next line is a prompt; the start line and a later build stay commands")
    }

    /// claude/summary-fail-1003 (owner 10/3): the moment behind "Couldn't summarize" was a Claude Code session in Ghostty
    /// (tab "Tallybird app design review"): its window, a draft, then two long submitted prompts with their Returns, and
    /// the tab's spinner retitling the window. The writer path holds for it: one session item, the instruction plus the
    /// evidence inside the local template's 8,192-byte bound, the validator taking Asked/Told lines, and code's fallback
    /// asking the tool. (The failure was the click's wait behind a background batch, not this path; see writer-state.)
    /// Fictional prompts, about 1,100 characters each; never the owner's words.
    static func twoLongPrompts() async throws {
        let long1 = String(repeating: "make the pending summary card clearer so the label, the quotes and the button read as one state, ", count: 11)
        let long2 = String(repeating: "and when summarizing fails keep the card calm with a quiet line instead of a banner that points at settings, ", count: 10)
        check(long1.count > 1000 && long2.count > 1000, "two-long: fixture prompts are long (\(long1.count), \(long2.count) characters)")
        // The real moment's shape (kinds and order only; title-spinner drops the tab's spinner ticks before the writer).
        let rows = [Row(title: cc, kind: "app.activated"), Row(title: cc), Row(title: cc, text: "a draft that was never sent", sent: false),
                    Row(title: cc, kind: "app.activated"), Row(title: cc), Row(title: "", kind: "keyboard.submit"),
                    Row(title: cc, kind: "mouse.click"), Row(title: "", kind: "keyboard.shortcut"), Row(title: "", kind: "keyboard.shortcut"),
                    Row(title: cc, kind: "mouse.click"), Row(title: cc, text: long1), Row(title: "", kind: "keyboard.submit"),
                    Row(title: cc, text: long2), Row(title: "", kind: "keyboard.submit"), Row(title: cc),
                    Row(title: "", kind: "keyboard.shortcut"), Row(title: cc, kind: "mouse.click")]
        let r = try request("cc-long", rows)
        let local = try ModelView(request: r, actions: r.actions, appNames: [:], localIntentSessions: true)
        let instruction = CanonicalGrounding.instruction(for: local)
        let typed = local.items.filter { $0.kind == .typed }
        print("  two-long: \(typed.count) typed item(s), session \(typed.contains { $0.requestSession }), instruction \(instruction.utf8.count) B, evidence \(local.text.utf8.count) B")
        check(local.text.contains("to \"Claude Code\"") && local.text.contains("Start with: Asked Claude Code"),
              "two-long: the prompts are to Claude Code, each line may start \"Asked Claude Code\"")
        let rendered = try? QwenNoThinkingTemplate.render(instruction: instruction, evidence: local.text, prefill: CanonicalGrounding.prefill)
        check(rendered != nil, "two-long: instruction (\(instruction.utf8.count) bytes) and evidence (\(local.text.utf8.count) bytes) fit the local template")
        check(instruction.utf8.count <= 8192, "two-long: the session instruction is within 8,192 bytes (\(instruction.utf8.count))")
        guard let note = await write(r, Scripted()) else { check(false, "two-long: a note is written"); return }
        print("  two-long -> \(note.bullets.map(\.text)) \(note.generatorVersion)")
        let asked = note.bullets.map(\.text).filter { $0.hasPrefix("Asked Claude Code") || $0.hasPrefix("Told Claude Code") }
        check(asked.count == 2 && note.generatorVersion == CanonicalGrounding.localVersion && note.generator == CanonicalLocalWriter.provider,
              "two-long: the validator takes an Asked and a Told line for the two prompts (the model's note, no fallback)")
        check((try? CanonicalGrounding.check(note, request: r, view: local)) == note, "two-long: the final check accepts the note")
        guard let fallback = await write(r, Garbage()) else { check(false, "two-long: fallback written"); return }
        print("  two-long, no model answer -> \(fallback.bullets.map(\.text))")
        // int-1003: cc-label-1003's fallback7 (owner 10/03) says what the prompts were about, never a bare "Asked Claude Code.".
        check(fallback.bullets.map(\.text).contains { $0.hasPrefix("Asked Claude Code about ") && $0.hasSuffix("(2 prompts).") }
                && !fallback.bullets.map(\.text).contains("Asked Claude Code.") && noGeneric(fallback.bullets.map(\.text)),
              "two-long: with no model answer, code's fallback still asks the tool, no generic terminal line")
    }

    static func shellSession() async throws {
        let r = try request("sh", [Row(title: shell), Row(title: shell, text: "swift build"), Row(title: shell, text: "swift run MacMemChecks"),
                                   Row(title: shell, text: "./scripts/run-checks.sh summary"), Row(title: shell, text: "git status"), Row(title: shell, text: "cd ..")])
        let v = try ModelView(request: r, actions: r.actions, appNames: [:], localIntentSessions: true)
        check(CanonicalGrounding.codeWrites(v), "shell: every line is a command code can say, so no model is loaded")
        guard let note = await write(r, Scripted()) else { check(false, "shell: a note is written"); return }
        let texts = note.bullets.map(\.text)
        print("  shell session -> \(texts)")
        check(texts.count == 1 && texts[0].hasPrefix("Entered commands to build the Swift package, run MacMemChecks") && texts[0].hasSuffix(" in harborline."),
              "shell: one line by purpose (got \(texts))")
        check(noGeneric(texts) && !texts[0].contains("git status") && !texts[0].contains("scripts/"), "shell: no filler, no typed command or path repeated")
        check(Set(note.bullets.flatMap(\.actionIDs)).isSuperset(of: r.actions.filter { $0.kind == "keyboard.text_input" }.map(\.id)), "shell: the line cites every command")
        check(note.generator == "code/moment-notes" && (try? CanonicalGrounding.check(note, request: r, view: v)) == note, "shell: code's note, accepted by the final check")
        // One command keeps its own line.
        let one = try request("s1", [Row(title: shell, text: "swift test")])
        let o = try ModelView(request: one, actions: one.actions, appNames: [:])
        check((try? CanonicalGrounding.codeNote(one, view: o))?.bullets.map(\.text) == ["Entered a command to run the Swift tests in harborline."], "shell: one command, its own line as before")
        // A cloud note: the model's lines for commands are never kept; code's one line stands.
        let fb = try CanonicalGrounding.fallbackNote(r, view: v)
        check(fb.bullets.count == 1 && noGeneric(fb.bullets.map(\.text)), "shell: the fallback note is the same one line (got \(fb.bullets.map(\.text)))")
    }

    static func mixedSession() async throws {
        let r = try request("mx", [Row(title: cc, text: ask), Row(title: busy, text: tell), Row(title: shell, text: "swift build"),
                                   Row(title: shell, text: "./scripts/run-checks.sh summary"), Row(title: shell, text: "git status")])
        let v = try ModelView(request: r, actions: r.actions, appNames: [:], localIntentSessions: true)
        guard let note = await write(r, Scripted()) else { check(false, "mixed: a note is written"); return }
        let texts = note.bullets.map(\.text)
        print("  mixed session -> \(texts)")
        check(texts.count == 3 && texts[0].hasPrefix("Asked Claude Code") && texts[1].hasPrefix("Told Claude Code") && texts[2].hasPrefix("Entered commands to build the Swift package"),
              "mixed: the prompts by gist, then the commands by purpose (got \(texts))")
        check(noGeneric(texts) && Set(texts).count == texts.count, "mixed: no filler and no repeated line")
        check((try? CanonicalGrounding.check(note, request: r, view: v)) == note, "mixed: the final check accepts it")
        guard let fallback = await write(r, Garbage()) else { check(false, "mixed: fallback written"); return }
        print("  mixed session, no model answer -> \(fallback.bullets.map(\.text))")
        check(fallback.bullets.count == 2 && fallback.bullets[0].text.hasPrefix("Asked Claude Code about \u{201C}Tallybird app design review\u{201D}") && fallback.bullets[1].text.hasPrefix("Entered commands to"),
              "mixed: code's fallback asks the tool and says the commands by purpose")
    }

    /// claude/cc-label-1003 (owner 10/03, 2:24-2:35 PM): a Claude Code tab whose title alternated "✳", a spinner and the
    /// plain topic while five prompts were typed and sent with Return (two of them in two pieces cut by an app switch or a
    /// pause), and one real shell command. Reads drop the glyph: the rows' tools are "Claude Code" (✳), "" (spinner) or
    /// none (plain). The card read "Asked Claude Code. / <one gist> / Drafted a message to Claude Code.". Fake prompts.
    static func liveSession() async throws {
        let topic = "Fixture card review"
        let prompts = ["Show the Summarize Now flow as a preview. ", "Grey button first, then the sweep over the quotes.",
                       "Fix the fixture card so the settings and the behaviour agree, and make the chart easier to read.",
                       "Why does the summary say drafted when the prompt was sent with Return?",
                       "Make the button grey while it works. ", "Then show Summarizing in the footer until the note is ready.",
                       "Please explain what the sweep animation does and when it stops."]
        // The shell command comes first: code typed after the last send is what the person did next (prompt7's NEXT).
        let rows = [Row(title: shell), Row(title: shell, text: "swift build"), Row(title: topic, tool: "Claude Code"),
                    Row(title: topic, text: prompts[0], sent: false, tool: "Claude Code"), Row(app: "Ghostty", title: topic, tool: "", kind: "app.activated"),
                    Row(title: topic, text: prompts[1], tool: ""), Row(title: "", kind: "keyboard.submit"),
                    Row(title: topic, text: prompts[2]), Row(title: "", kind: "keyboard.submit"),
                    Row(title: topic, text: prompts[3], tool: ""), Row(title: "", kind: "keyboard.submit"),
                    Row(title: topic, text: prompts[4], sent: false), Row(title: topic, tool: ""),
                    Row(title: topic, text: prompts[5], tool: ""), Row(title: "", kind: "keyboard.submit"),
                    Row(title: topic, text: prompts[6], tool: "Claude Code"), Row(title: "", kind: "keyboard.submit")]
        let r = try request("live", rows)
        let local = try ModelView(request: r, actions: r.actions, appNames: [:], localIntentSessions: true)
        let typed = local.items.filter { $0.kind == .typed }
        check(typed.count == 2 && local.text.contains("Request 5:") && !local.text.contains("Request 6:") && local.text.contains("to \"Claude Code\""),
              "live: five prompts (two typed in pieces) are one Claude Code session of five requests, beside the shell command (\(typed.count) typed items)")
        check(!local.text.contains("sending unknown") && !local.text.contains("Start with: Drafted"), "live: no prompt sent with Return reads as a draft")
        let cloud = try ModelView(request: r, actions: r.actions, appNames: [:])
        check(cloud.text.components(separatedBy: "Start with: Asked Claude Code").count == 6,
              "live: the cloud view asks Claude Code five times (spinner and plain titles included)")
        check((try? QwenNoThinkingTemplate.render(instruction: CanonicalGrounding.instruction(for: local), evidence: local.text, prefill: CanonicalGrounding.prefill)) != nil
              && CanonicalGrounding.instruction(for: local).contains("never a bare \"Asked <tool>\""),
              "live: the session instruction asks for specifics, never a bare line, within 8,192 bytes (\(CanonicalGrounding.instruction(for: local).utf8.count) bytes)")
        // A model that writes one bullet per request, with substance.
        struct Rich: LocalInference {
            func load() async throws {}
            func unload() async {}
            func generate(instruction: String, evidence: String, maxTokens: Int) async throws -> Data {
                let id = evidence.split(separator: "\n").first { $0.contains("Own captured requests") }.flatMap { $0.split(separator: ".").first }.map(String.init) ?? "i1"
                return try JSONSerialization.data(withJSONObject: ["title": "Summarize Now preview", "bullets": [
                    ["ids": [id], "text": "Asked Claude Code for a preview of how Summarize Now looks: greyed button, then a sweep."],
                    ["ids": [id], "text": "Asked Claude Code to align the card's settings with how it behaves and tidy the artifact."],
                    ["ids": [id], "text": "Asked Claude Code to grey out the button during work and show progress until the note exists."],
                    ["ids": [id], "text": "Asked Claude Code what the sweep animation is for and when it ends."]]])
            }
        }
        guard let note = await write(r, Rich()) else { check(false, "live: a note is written"); return }
        let texts = note.bullets.map(\.text)
        print("  live session -> \(texts)")
        let asked = texts.filter { $0.hasPrefix("Asked Claude Code ") }
        check(texts.count == 5 && asked.count == 4 && asked.allSatisfy { !$0.contains(" about \u{201C}") } && texts.contains { $0.hasPrefix("Entered a command") },
              "live: one substantive bullet per request, then the command (got \(texts))")
        check(!texts.contains("Asked Claude Code.") && !texts.contains { $0.hasPrefix("Drafted") } && SummaryLines.tidy(texts).count == 4 && SummaryLines.tidy(texts).filter { $0.hasPrefix("Asked Claude Code ") }.count >= 3,
              "live: no bare \"Asked Claude Code.\", no \"Drafted\" line, at most 4 on the card")
        check((try? CanonicalGrounding.check(note, request: r, view: local)) == note, "live: the final check accepts it")
        // No model answer: code's line says what the prompts were about, never bare, never drafted.
        guard let fallback = await write(r, Garbage()) else { check(false, "live: fallback written"); return }
        let fb = fallback.bullets.map(\.text)
        print("  live session, no model answer -> \(fb)")
        check(fb.contains("Asked Claude Code about \u{201C}Fixture card review\u{201D} (5 prompts).") && fb.count == 2 && !fb.contains { $0.hasPrefix("Drafted") },
              "live: code's fallback says what the five prompts were about (got \(fb))")
        // A model answer salvage keeps partly: the prompts it left out get code's line, never a bare one or "Drafted".
        let vague = #"{"title":"Card fixes","bullets":[{"ids":["i9"],"text":"Fixed the card."}]}"#
        if let out = try? CanonicalGrounding.salvage(vague, request: r, view: local, provider: "local/qwen3.5-4b-q4_k_m") {
            let st = out.bullets.map(\.text)
            print("  live session, salvaged -> \(st)")
            check(!st.contains("Asked Claude Code.") && !st.contains { $0.hasPrefix("Drafted") } && st.contains { $0.hasPrefix("Asked Claude Code about \u{201C}Fixture card review\u{201D}") },
                  "live: salvage's line for the prompts says what about (got \(st))")
        } else { check(false, "live: salvage writes a note") }
        // Prompt shape: the writer and core keep one rule.
        let shapes = prompts + ["swift build", "git status", "ls -la", "yes do that", "cd ~/Projects && make", "grep -rn titleTool Sources | head",
                                "make the button grey while it works. then show Summarizing in the footer."]
        check(shapes.allSatisfy { CanonicalGrounding.promptShaped($0) == PromptShape.natural($0) }, "live: the writer's prompt rule is core's (\(shapes.filter { CanonicalGrounding.promptShaped($0) != PromptShape.natural($0) }))")
    }

    static func salvageRepeats() throws {
        // Two lines code can't name in a plain shell, and a model answer that fails: salvage writes their line once.
        let r = try request("sv", [Row(title: shell, text: "frobnicate the widgets now"), Row(title: shell, text: "quux everything again please")])
        let v = try ModelView(request: r, actions: r.actions, appNames: [:])
        let bad = #"{"title":"Widgets","bullets":[{"ids":["i1","i2"],"text":"Fixed the widgets."}]}"#
        if let out = try? CanonicalGrounding.salvage(bad, request: r, view: v, provider: "local/qwen3.5-4b-q4_k_m") {
            let texts = out.bullets.map(\.text)
            check(Set(texts.map { $0.lowercased() }).count == texts.count, "salvage: no line twice (got \(texts))")
            check(!texts.contains { $0.hasPrefix("Wrote code in") || $0.hasPrefix("Edited ") }, "salvage: a shell line is a command, never \"Wrote code\" (got \(texts))")
            check((try? CanonicalGrounding.check(out, request: r, view: v)) == out, "salvage: the final check accepts the merged line")
        } else { check(false, "salvage: written") }
        let fb = try CanonicalGrounding.fallbackNote(r, view: v)
        check(fb.bullets.map(\.text) == ["Entered a command in harborline."], "fallback: shell lines code can't name are one command line (got \(fb.bullets.map(\.text)))")
    }

    static func summaryLines() {
        let owner = ["Typed a draft in Ghostty.", "Used the send key in Ghostty.", "Requested the option to summarize immediately.", "Wrote code in Ghostty.",
                     "Noted that the current summary is confusing.", "Wrote code in Ghostty."]
        let tidy = SummaryLines.tidy(owner)
        print("  the owner's card -> \(tidy)")
        check(tidy == ["Requested the option to summarize immediately.", "Noted that the current summary is confusing."], "lines: the owner's card drops filler and repeats (got \(tidy))")
        check(SummaryLines.tidy(["Typed a draft in TextEdit.", "Used the send key in ChatGPT.", "Typed a draft in TextEdit"]) == ["Typed a draft in TextEdit.", "Used the send key in ChatGPT."],
              "lines: a note of only code's lines keeps them, each once")
        check(SummaryLines.tidy(["Asked Claude Code.", "Asked Claude Code to add a Summarize Now option."]) == ["Asked Claude Code to add a Summarize Now option."],
              "lines: a bare line beside a fuller one with the same start goes")
        check(SummaryLines.tidy(["Asked Claude Code to add a Summarize Now option.", "Asked Claude Code to add the Summarize Now option."]).count == 1, "lines: near-identical lines once")
        let many = ["Texted Sam about dinner.", "Wrote in harborline notes.", "Asked Claude Code to fix the flaky export test.", "Emailed Priya the crash logs request.",
                    "Told Codex the build is slow.", "Drafted a reply to Maya about Friday."]
        let capped = SummaryLines.tidy(many)
        check(capped.count == 4 && capped == many.filter { capped.contains($0) } && capped.contains("Asked Claude Code to fix the flaky export test."),
              "lines: at most 4, the most informative, in order (got \(capped))")
        for g in ["Typed a draft in Ghostty.", "Used the send key in Ghostty.", "Wrote code in Ghostty.", "Pressed Return in Slack; sending is not established.",
                  "Ran a command in Terminal.", "Entered a command in harborline.", "Typed in Notes, a sentence (exact words not shared with AI apps)."] {
            check(SummaryLines.isGeneric(g), "lines: \"\(g)\" is generic")
        }
        for real in ["Entered commands to build the Swift package in harborline.", "Texted Sam about dinner.", "Typed prompts for Claude Code and used the send key.",
                     "Asked Claude Code about \u{201C}Fixture card review\u{201D} (5 prompts).", "Asked Claude why the export fails."] {
            check(!SummaryLines.isGeneric(real), "lines: \"\(real)\" says something")
        }
        // claude/cc-label-1003 (owner 10/03): "Asked Claude Code." beside a line that says what was asked is filler.
        let live = ["Asked Claude Code.", "Requested to fix the fixture settings and clarify the button state.", "Drafted a message to Claude Code."]
        check(SummaryLines.isGeneric("Asked Claude Code.") && SummaryLines.tidy(live) == Array(live.dropFirst()) && SummaryLines.tidy(["Asked Claude Code."]) == ["Asked Claude Code."],
              "lines: a bare \"Asked Claude Code.\" is shown only when nothing says more (got \(SummaryLines.tidy(live)))")
    }
}
