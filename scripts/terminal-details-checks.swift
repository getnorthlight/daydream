import Foundation
@testable import MemoryCore
@testable import MemoryUI

/// claude/terminal-details-1003 (owner 10/03): a Claude Code session in Ghostty showed "Captured wording unavailable" on
/// every row, called sent prompts "Typed a draft" / "Ran a command", and interleaved "Worked in Ghostty" rows.
/// Fictional fixtures only: a temporary store with an in-memory key, fake titles and fake words. No app, window,
/// capture, model or owner data.
private var passed = 0, failed = 0
private func check(_ ok: Bool, _ label: String, _ got: @autoclosure () -> String = "") {
    print("\(ok ? "PASS" : "FAIL") \(label)\(ok ? "" : " :: " + got())")
    if ok { passed += 1 } else { failed += 1 }
}
private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private let ghostty = "com.mitchellh.ghostty", terminal = "com.apple.Terminal"
private let topic = "Fixture parser review"

/// A typed piece, sealed by `seal` ("submit" when Return ended it), in a terminal tab titled `title`.
private func piece(_ id: String, _ words: String, _ s: Double, title: String, run: String? = nil, part: Int = 1,
                   seal: String = "pointer", bundle: String = ghostty, app: String = "Ghostty", withheld: Int = 0) -> Evidence {
    let at = iso(epoch.addingTimeInterval(s))
    var e = Evidence(id: id, at: at, kind: "keyboard.text_input", app: app, bundle: bundle, title: title, text: words, synthetic: true)
    let submit = seal == "submit"
    let unit = TypedUnitProvenance(runID: run ?? id, part: part, sealReason: seal, startedAt: at, keys: nil, edits: nil,
        withheld: withheld, surface: "code", field: "textArea", send: submit ? "detected" : "none", sendBy: submit ? "return" : nil, to: nil)
    e.captureProvenance = NativeCaptureProvenance(policyRevision: "synthetic", classifierVersion: "sensitive-typing/v2",
        windowID: "fixture-window-\(id)", focusID: "fixture-focus-\(id)", checkedAt: at, generation: 3, unit: unit)
    return e
}
private func event(_ id: String, _ kind: String, _ s: Double, title: String = "", bundle: String = ghostty, app: String = "Ghostty") -> Evidence {
    Evidence(id: id, at: iso(epoch.addingTimeInterval(s)), kind: kind, app: app, bundle: bundle, title: title, text: "", synthetic: true)
}

@main @MainActor struct TerminalDetailsChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let store = try MemoryStore(home: root, writable: true, automaticallySyncSearch: false)
        var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1
        try store.updatePolicy(policy, now: epoch)
        try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore()), now: epoch)
        try store.setUpTypedVault(now: epoch); try store.acceptSafeTyping(now: epoch)

        // The owner's shape: Claude Code's title ticks between "✳", "◐" and "◑" every couple of seconds (hundreds of
        // window rows), each prompt is typed in 2-3 pieces cut by a click or an app switch, the last piece carries the
        // Return, and a bare Return row with no title follows at the same second.
        let star = "\u{2733} " + topic, half1 = "\u{25D0} " + topic, half2 = "\u{25D1} " + topic
        var evidence: [Evidence] = []
        for n in 0..<560 { evidence.append(event("tick-\(n)", "window.changed", Double(n) * 2 + 1, title: n % 2 == 0 ? half1 : half2)) }
        evidence += [
            piece("p1a", "Explain how the fixture ", 30, title: star),
            piece("p1b", "parser handles empty input.", 60, title: half1),
            event("msg-switch", "app.activated", 70, title: "Fixture chat", bundle: "com.apple.MobileSMS", app: "Messages"),
            piece("p1c", " Keep it short.", 90, title: half2, seal: "submit"),
            event("p1-return", "keyboard.submit", 90),
            event("click", "mouse.click", 200, title: half1),
            piece("p2a", "Now list the tests that cover it.", 300, title: half2, seal: "idle"),
            event("p2-return", "keyboard.submit", 317),
        ]
        let long = String(repeating: "Walk through the fixture parser branch by branch. ", count: 14)   // ~700 characters
        evidence.append(piece("p4", long, 1000, title: star, seal: "submit"))
        evidence.append(event("p4-return", "keyboard.submit", 1000))
        // Typed last and never sent (text left in a terminal's input is part of the next line sent, so it comes last).
        evidence.append(piece("p3a", "And one more question I have not sent", 1050, title: half1))
        var saved = Set<String>()
        for e in evidence where try store.ingest(e, now: epoch.addingTimeInterval(1100)) { saved.insert(e.id) }
        // Only builds that save terminal typing (the owner lane) can run the store sections.
        if saved.contains("p1a") { try storeSections(store, evidence: evidence, long: long, star: star) }
        else { print("NOTE store sections skipped: this build saves no terminal typing (run the owner lane)") }
        projectionSections(star: star)
        ccLabelSections()
        print("terminal-details: \(passed) passed, \(failed) failed; fictional fixtures, no windows")
        if failed > 0 { exit(1) }
    }

    static func storeSections(_ store: MemoryStore, evidence: [Evidence], long: String, star: String) throws {
        let ids = evidence.map(\.id)
        check(ids.count > MomentTypedText.rowLimit, "fixture: the moment has more actions than the typed row limit", "\(ids.count)")

        // 1. Root cause: the 400 cap counted every action of the moment, so a long Claude Code session opened no words.
        let previews = try store.ownerSourceMomentPreviewsForActions(ids, now: epoch.addingTimeInterval(1101))
        let quoted = Set(previews.flatMap(\.parts).map(\.actionID))
        check(quoted.isSuperset(of: ["p1a", "p1b", "p1c", "p2a", "p3a", "p4"]),
              "a 560-title-tick moment still opens every typed piece's words (owner detail)", "\(quoted.sorted())")
        check(previews.flatMap(\.parts).first { $0.actionID == "p4" }?.text == long,
              "a long prompt (over 400 characters) is quoted whole in the detail")
        check(OwnerSourceMomentProjection.standIn(previews).allSatisfy { $0.text.count <= 160 } &&
              !OwnerSourceMomentProjection.standIn(previews).contains { $0.id == "p4" },
              "summary stand-ins still quote short sources only")
        check(try store.ownerSourcePreviews(["p4"], now: epoch.addingTimeInterval(1101)).isEmpty &&
              (try store.ownerSourcePreviews(["p1a"], now: epoch.addingTimeInterval(1101), characterLimit: 401)).isEmpty,
              "the public short-source API keeps its 400 bound")
        var state = OwnerSourceDetailState()
        let ticket = state.begin(scope: "fixture|ghostty", actionIDs: ids)
        let revision = try store.ownerSourcePreviewRevision(now: epoch.addingTimeInterval(1101))
        check(state.accept(previews, ticket: ticket, revision: revision, now: epoch.addingTimeInterval(1101)) && state.previews.count == previews.count,
              "the detail session accepts the moment's previews")

        // 2. What happened.
        let actions = try ids.compactMap { try store.action($0, now: epoch.addingTimeInterval(1101)) }
        check(actions.count == ids.count, "fixture: every action projects", "missing \(Set(ids).subtracting(actions.map(\.id)).sorted())")
        let lines = MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(actions, previews: state.previews),
                                                actions: actions, timeZone: TimeZone(identifier: "America/Chicago")!)
        let text = lines.map { $0.title + " | " + $0.detail + " | " + $0.sends.joined(separator: ",") }
        let prompts = lines.filter { $0.bundle == ghostty }
        if ProcessInfo.processInfo.environment["TD_DEBUG"] != nil {
            for l in lines { print("DEBUG", l.title, "|", l.detail, "|", l.actionIDs.filter { !$0.hasPrefix("tick") }, l.actionIDs.count, l.typed.map(\.text.count)) }
        }
        check(prompts.count == 4, "four Ghostty lines: three prompts and one unsent line, nothing else", "\(text)")
        check(!lines.contains { $0.title.hasPrefix("Worked in Ghostty") }, "no \"Worked in Ghostty\" rows between typed rows", "\(text)")
        check(!lines.contains { $0.detail.contains(TypedWords.ranCommandLabel) || $0.detail.contains("Typed a draft") || $0.detail.contains("Pressed Return") },
              "a Claude Code prompt is never \"Ran a command\", \"Typed a draft\" or a separate Return row", "\(text)")
        let p1 = prompts.first { $0.actionIDs.contains("p1a") }
        check(p1?.detail == "Ghostty · Asked Claude Code" && p1?.title == topic,
              "pieces across a click, an app switch and spinner title changes are ONE sent prompt: \"Asked Claude Code\"", p1.map { $0.title + " | " + $0.detail } ?? "nil")
        check(p1?.typed.map(\.text) == ["Explain how the fixture parser handles empty input. Keep it short."],
              "its exact wording, the pieces in order, one quote", "\(p1?.typed.map(\.text) ?? [])")
        check(p1.map { Set(["p1a", "p1b", "p1c", "p1-return"]).isSubset(of: Set($0.actionIDs)) } == true,
              "the prompt line stands for its pieces and its Return")
        let p2 = prompts.first { $0.actionIDs.contains("p2a") }
        check(p2?.detail == "Ghostty · Asked Claude Code" && p2?.actionIDs.contains("p2-return") == true,
              "a piece sealed before its Return (17 s later) is sent by that Return", p2?.detail ?? "nil")
        let p3 = prompts.first { $0.actionIDs.contains("p3a") }
        check(p3?.detail == "Ghostty · Typed" && p3?.typed.first?.text == "And one more question I have not sent",
              "a line never followed by Return reads \"Typed\" with its words, never not sent", p3?.detail ?? "nil")
        let p4 = prompts.first { $0.actionIDs.contains("p4") }
        check(p4?.typed.first?.text == long.trimmingCharacters(in: .whitespaces) && p4?.actionIDs.contains("p4-return") == true,
              "the long prompt shows whole, with its Return folded in")
        check(!lines.contains { $0.capturedWordingUnavailable } && !lines.contains { $0.withheldReason != nil },
              "no unavailable line when nothing was withheld")
        check(prompts.allSatisfy { $0.typed.allSatisfy { $0.send == nil } }, "no \"Drafted text\" / \"Submission observed\" caption on a prompt quote")
        let reach = lines.flatMap(\.actionIDs)
        check(Set(reach) == Set(ids) && reach.count == ids.count, "every action stays behind exactly one line",
              "\(reach.count) vs \(ids.count)")
        check(lines.contains { $0.bundle == "com.apple.MobileSMS" }, "the other app between pieces keeps its own line")

        // 4. Withheld words say why, only for a privacy reason.
        let secret = piece("secret", "export API_TOKEN=sk-live-synthetic-abcdefghijklmnopqrstuvwxyz0123456789", 1200, title: star, seal: "submit")
        let scrubbed = piece("scrubbed", "Visible remainder", 1210, title: star, seal: "submit", withheld: 1)
        for e in [secret, scrubbed] { _ = try store.ingest(e, now: epoch.addingTimeInterval(1300)) }
        let hidden = try store.ownerSourceMomentPreviewsForActions(["secret", "scrubbed"], now: epoch.addingTimeInterval(1301))
        check(hidden.allSatisfy { $0.parts.isEmpty } && hidden.compactMap(\.withheldReason) == [OwnerSourcePreview.hiddenSecret, OwnerSourcePreview.hiddenSecret],
              "scrubbed rows give no words, only the reason \"\(OwnerSourcePreview.hiddenSecret)\"", "\(hidden.compactMap(\.withheldReason))")
        check(String(describing: hidden.first as Any).contains("redacted") || hidden.isEmpty, "a withheld marker prints redacted")
        var hiddenState = OwnerSourceDetailState()
        let ht = hiddenState.begin(scope: "fixture|hidden", actionIDs: ["secret", "scrubbed"])
        check(hiddenState.accept(hidden, ticket: ht, revision: try store.ownerSourcePreviewRevision(now: epoch.addingTimeInterval(1301)), now: epoch.addingTimeInterval(1301)),
              "the detail session accepts withheld markers (no words)")
        let hiddenActions = try ["secret", "scrubbed"].compactMap { try store.action($0, now: epoch.addingTimeInterval(1301)) }
        let hl = MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(hiddenActions, previews: hiddenState.previews),
                                             actions: hiddenActions, timeZone: .current)
        check(!hl.isEmpty && hl.allSatisfy { $0.withheldReason == OwnerSourcePreview.hiddenSecret && $0.capturedWordingUnavailable && $0.typed.isEmpty },
              "the detail shows the short reason in place of the words", "\(hl.map { ($0.withheldReason ?? "nil") + " " + $0.detail })")
        check(OwnerSourceMomentProjection.standIn(hidden).isEmpty, "a withheld marker is never a stand-in")
        // No words and no privacy reason (a locked key, a refused run): no line at all, never a default.
        let bare = OwnerSourceMomentProjection.history([ActionProjection.make(piece("bare", "x", 0, title: star, seal: "submit"))], previews: [])
        check(bare.allSatisfy { !$0.capturedWordingUnavailable && $0.withheldReason == nil }, "missing words without a privacy reason show no unavailable line")
        let section = (try? String(contentsOfFile: "Sources/MemoryUI/MomentTypedSection.swift", encoding: .utf8)) ?? ""
        check(!section.isEmpty && !section.contains("\"Captured wording unavailable\""), "the detail has no default \"Captured wording unavailable\" text")

    }

    /// claude/cc-label-1003 (owner 10/03, 2:24-2:35 PM): a Claude Code session in a Ghostty tab, the owner typing prompts
    /// and pressing Return. Every row read "Ran a command" (the terminal rows' compose line, surface "code", came first and
    /// named no tool), and each row showed its time twice. The tab title alternates "✳", "◐"/"◑" and the plain topic while
    /// the five prompts are typed (two of them in two pieces cut by an app switch or a pause); one real shell command runs
    /// in Terminal. Rows are read as the store shows them (`Privacy.sanitized`: no glyph, the tool kept as `titleTool`) and
    /// the host's compose lines are passed, as the app does. Fake prompts only.
    static func ccLabelSections() {
        let topic = "Fixture card review", star = "\u{2733} " + topic, spin1 = "\u{25D0} " + topic, spin2 = "\u{25D1} " + topic
        let shellTitle = "fixture-user \u{2014} -zsh \u{2014} ~/Projects/tally"
        func read(_ e: Evidence) -> CanonicalAction {
            ActionProjection.make(Privacy.sanitized(e, settings: PrivacySettings(), now: epoch.addingTimeInterval(100_000)) ?? e)
        }
        let words: [String: String] = [
            "q1a": "Show the Summarize Now flow as a preview. ", "q1b": "Grey button first, then the sweep over the quotes.",
            "q2": "Fix the fixture card so the settings and the behaviour agree, and make the chart easier to read.",
            "q3": "Why does the summary say drafted when the prompt was sent with Return?",
            "q4a": "Make the button grey while it works. ", "q4b": "Then show Summarizing in the footer until the note is ready.",
            "q5": "Please explain what the sweep animation does and when it stops.",
            "sh": "swift build",
        ]
        var rows: [Evidence] = []
        for n in 0..<40 { rows.append(event("cc-tick-\(n)", "window.changed", 2000 + Double(n) * 9, title: [star, spin1, topic, spin2][n % 4])) }
        rows += [
            piece("q1a", words["q1a"]!, 2010, title: star, seal: "pointer"),
            event("cc-switch", "app.activated", 2020, title: "Fixture chat", bundle: "com.apple.MobileSMS", app: "Messages"),
            event("cc-back", "app.activated", 2030, title: spin1),
            piece("q1b", words["q1b"]!, 2040, title: spin1, seal: "submit"), event("q1-return", "keyboard.submit", 2040),
            piece("q2", words["q2"]!, 2100, title: topic, seal: "submit"), event("q2-return", "keyboard.submit", 2100),
            piece("q3", words["q3"]!, 2160, title: spin2, seal: "submit"), event("q3-return", "keyboard.submit", 2160),
            piece("q4a", words["q4a"]!, 2200, title: topic, seal: "idle"),
            piece("q4b", words["q4b"]!, 2380, title: spin1, seal: "submit"), event("q4-return", "keyboard.submit", 2380),
            piece("q5", words["q5"]!, 2400, title: star, seal: "submit"), event("q5-return", "keyboard.submit", 2400),
            piece("sh", words["sh"]!, 2410, title: shellTitle, seal: "submit", bundle: terminal, app: "Terminal"),
            event("sh-return", "keyboard.submit", 2410, title: shellTitle, bundle: terminal, app: "Terminal"),
        ]
        let actions = rows.map(read)
        let typedIDs = Set(words.keys)
        let blocks = rows.filter { typedIDs.contains($0.id) }.map {
            MomentTypedBlock(id: $0.id, at: $0.at, app: $0.app, bundle: $0.bundle, host: "", title: TitleClean.statusless($0.title), text: words[$0.id]!, send: nil)
        }
        let compose = ComposeLine.lines(rows)
        check(compose["q2"]?.title == TypedWords.ranCommandLabel, "fixture: the host's compose line for a terminal row is \"Ran a command\" (the live bug's input)",
              compose["q2"]?.title ?? "nil")
        let zone = TimeZone(identifier: "America/Chicago")!
        let lines = MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(actions, previews: [], typed: MomentTypedLoad(blocks: blocks)),
                                                actions: actions, timeZone: zone, compose: compose)
        let text = lines.map { $0.title + " | " + $0.detail }
        let asked = lines.filter { $0.detail == "Ghostty \u{00B7} Asked Claude Code" }
        let ran = lines.filter { $0.detail.hasSuffix(TypedWords.ranCommandLabel) }
        check(asked.count == 5, "cc-label: five prompts typed under \"✳\", spinner and plain titles read \"Asked Claude Code\"", "\(text)")
        check(ran.count == 1 && ran[0].bundle == terminal && ran[0].typed.map(\.text) == ["swift build"],
              "cc-label: the one real shell command stays \"Ran a command\"", "\(text)")
        check(!lines.contains { $0.bundle == ghostty && ($0.detail.contains("Draft") || $0.detail.contains("not sent") || $0.message != nil) },
              "cc-label: no Ghostty row is a compose line, a draft or \"Typed, not sent\"", "\(text)")
        let q1 = asked.first { $0.actionIDs.contains("q1a") }, q4 = asked.first { $0.actionIDs.contains("q4a") }
        check(q1?.typed.map(\.text) == [words["q1a"]! + words["q1b"]!].map { $0.trimmingCharacters(in: .whitespaces) }
              && q1?.actionIDs.contains("q1-return") == true && q4?.typed.count == 1 && q4?.actionIDs.contains("q4b") == true,
              "cc-label: a prompt typed in two pieces (an app switch, a pause) is one row, one quote, with its Return",
              "\(q1?.typed.map(\.text.count) ?? []) \(q4?.actionIDs ?? [])")
        // The time shows once: the row's own time, never again above a single quote.
        check(lines.filter { !$0.typed.isEmpty }.allSatisfy { e in e.typed.allSatisfy { !MomentDetailEntryView.blockShowsTime($0, in: e, timeZone: zone) } }
              && MomentTypedBlockView.caption(blocks[0], timeZone: zone, showsTime: false).isEmpty,
              "cc-label: a row's time is shown once (no time above its quote)")
        check(q4.flatMap(\.first) == epoch.addingTimeInterval(2380),
              "cc-label: a prompt started at one minute and sent at another shows the send's time", "\(q4?.first.map { $0.timeIntervalSince(epoch) } ?? -1)")
        let two = MomentDetailEntry(id: "two", bundle: ghostty, app: "Ghostty", host: "", title: topic, detail: "", first: epoch.addingTimeInterval(2010),
                                    last: epoch.addingTimeInterval(2400), actionIDs: [], openActionID: nil, sends: [], typed: [blocks[0], blocks.last!])
        check(MomentDetailEntryView.blockShowsTime(blocks.last!, in: two, timeZone: zone) && !MomentDetailEntryView.blockShowsTime(blocks[0], in: two, timeZone: zone),
              "cc-label: of several quotes in one row, only one typed at another minute shows its time")

        // A session where the title only ever spun (no "✳" in the moment): a tool, though not which one. A plain title with
        // no glyph anywhere: a prompt-shaped line is a prompt, a command is a command. A shell tab in the same app: a command.
        let spinOnly = [piece("s1", "x", 3000, title: spin1, seal: "submit"), event("s1-return", "keyboard.submit", 3000)].map(read)
        let plain = [piece("p1", "x", 3100, title: "Untitled fixture", seal: "submit"), piece("p2", "x", 3200, title: "Untitled fixture", seal: "submit")].map(read)
        let shellTab = [piece("t0", "x", 3300, title: star, seal: "submit"), piece("t1", "x", 3400, title: "~/Projects/tally", seal: "submit")].map(read)
        func label(_ acts: [CanonicalAction], _ text: [String: String]) -> [String] {
            let b = acts.filter { $0.kind == "keyboard.text_input" }.map {
                MomentTypedBlock(id: $0.id, at: $0.at, app: $0.app, bundle: $0.bundle, host: "", title: $0.title, text: text[$0.id] ?? "", send: nil)
            }
            return MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(acts, previews: [], typed: MomentTypedLoad(blocks: b)),
                                               actions: acts, timeZone: zone).filter { !$0.typed.isEmpty }.map(\.detail)
        }
        let spun = label(spinOnly, ["s1": "yes"])
        check(spun == ["Ghostty \u{00B7} Sent a prompt"], "cc-label: under a spinner only, a line is \"Sent a prompt\"", "\(spun)")
        let mixed = label(plain, ["p1": words["q2"]!, "p2": "git status"])
        check(mixed == ["Ghostty \u{00B7} Sent a prompt", "Ghostty \u{00B7} " + TypedWords.ranCommandLabel],
              "cc-label: with no glyph anywhere, a prompt-shaped line is \"Sent a prompt\" and a command is \"Ran a command\"", "\(mixed)")
        let tabs = label(shellTab, ["t0": words["q3"]!, "t1": "ls -la"])
        check(tabs.count == 2 && tabs[0] == "Ghostty \u{00B7} Asked Claude Code" && tabs[1].hasSuffix(TypedWords.ranCommandLabel),
              "cc-label: a shell tab of the same app keeps \"Ran a command\" beside a Claude Code tab", "\(tabs)")
    }

    static func projectionSections(star: String) {
        // A title change that renames the tab mid-prompt still joins (joining never depends on titles).
        let renamed = [piece("r1", "first half ", 0, title: "\u{2733} Old topic"), piece("r2", "second half", 20, title: "\u{2733} New topic", seal: "submit")]
        let renamedActions = renamed.map(ActionProjection.make)
        let renamedPreviews = [OwnerSourcePreview]()
        let rl = MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(renamedActions, previews: renamedPreviews,
                    typed: MomentTypedLoad(blocks: renamed.map { MomentTypedBlock(id: $0.id, at: $0.at, app: "Ghostty", bundle: ghostty, host: "", title: $0.title, text: $0.text, send: nil) })),
                    actions: renamedActions, timeZone: .current)
        check(rl.count == 1 && rl[0].typed.map(\.text) == ["first half second half"] && rl[0].detail.hasSuffix("Asked Claude Code") && rl[0].title == "New topic",
              "a renamed tab mid-prompt is still one prompt, titled by its latest title", "\(rl.map { $0.title + " | " + $0.detail })")

        // 3. A real shell command stays "Ran a command", with the command.
        let shellTitle = "fixture-user \u{2014} -zsh \u{2014} ~/Projects/tally \u{2014} 120\u{00D7}30"
        let shell = [piece("ls", "ls -la", 0, title: shellTitle, seal: "submit", bundle: terminal, app: "Terminal"),
                     event("ls-return", "keyboard.submit", 0, title: shellTitle, bundle: terminal, app: "Terminal"),
                     event("ls-view", "window.changed", 5, title: shellTitle, bundle: terminal, app: "Terminal")]
        let shellActions = shell.map(ActionProjection.make)
        let sl = MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(shellActions, previews: [],
                    typed: MomentTypedLoad(blocks: [MomentTypedBlock(id: "ls", at: shell[0].at, app: "Terminal", bundle: terminal, host: "", title: shellTitle, text: "ls -la", send: nil)])),
                    actions: shellActions, timeZone: .current)
        check(sl.count == 1 && sl[0].detail == "Terminal · " + TypedWords.ranCommandLabel && sl[0].typed.map(\.text) == ["ls -la"],
              "a shell line run with Return: \"Ran a command\" and the command, Return and views folded", "\(sl.map { $0.title + " | " + $0.detail })")

        // 5. Generalised condense: ChatGPT's views/clicks fold into the ask; its Return is the ask's send.
        let app = "ChatGPT", bundle = "com.openai.chat"
        let chat = [event("c0", "app.activated", 0, title: app, bundle: bundle, app: app), event("c1", "window.changed", 5, title: app, bundle: bundle, app: app),
                    event("c2", "mouse.click", 10, title: app, bundle: bundle, app: app),
                    Evidence(id: "c3", at: iso(epoch.addingTimeInterval(20)), kind: "keyboard.text_input", app: app, bundle: bundle, title: app, text: "Fictional question", synthetic: true),
                    event("c4", "keyboard.submit", 21, title: app, bundle: bundle, app: app), event("c5", "window.changed", 60, title: app, bundle: bundle, app: app)]
        let chatActions = chat.map(ActionProjection.make)
        let cl = MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(chatActions, previews: [],
                    typed: MomentTypedLoad(sends: ["c3": "Asked ChatGPT"], blocks: [MomentTypedBlock(id: "c3", at: chat[3].at, app: app, bundle: bundle, host: "", title: app, text: "Fictional question", send: "Asked ChatGPT")])),
                    actions: chatActions, timeZone: .current)
        check(cl.count == 1 && cl[0].sends == ["Asked ChatGPT"] && cl[0].actionIDs.count == chat.count && cl[0].first == epoch.addingTimeInterval(20),
              "ChatGPT: one line, the ask at its own time, with the views, clicks and Return behind it", "\(cl.map { $0.title + " | " + $0.detail })")
        let noise = (0..<5).map { event("n\($0)", "window.changed", Double($0) * 30, title: "~", bundle: terminal, app: "Terminal") }.map(ActionProjection.make)
        let nl = MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(noise, previews: []), actions: noise, timeZone: .current)
        check(nl.count == 1 && nl[0].quiet && nl[0].title == "Worked in Terminal", "a noise-only card is still its one quiet line")

    }
}
