import Foundation
import SwiftUI
@testable import MemoryCore
@testable import MemoryUI
import PrivacyPolicy

// claude/summary-fail-1003 (owner 10/3, installed 20261003140001). A pending Ghostty card (a Claude Code session, two long
// prompts quoted under "Summary pending") showed "Couldn't summarize. Check Summaries in Settings." while Settings and
// the writer were fine: the click had waited a minute behind a background rewrite batch and every failure got the same
// Settings banner. Its footer had only Forget This Moment… (code's "Asked Claude Code" line hid Summarize Now), and the
// day card read "Texts, ~8 min" over "Texts with Q7 and Jamie Lin, ~1 min".
// 1. A failed Summarize Now: Settings only when summaries are off or broken, saying what is wrong; a one-off is quiet,
//    keeps Summarize Now, and is tried again once by itself.
// 2. The owner-approved Summarize Now states (summary-v2): pending → working (greyed out, one sweep) → done; working →
//    failed → pending again.
// 3. The pending card's footer: Copy Summary under the icon, Summarize Now beside it, for a Claude Code card too.
// 4. The day card: one entry per conversation, no bare "Texts, ~8 min" beside a real Texts line.
// Fictional fixtures only (no owner words), temp stores, no windows, no model, no network.
@main @MainActor enum SummaryFailChecks {
    static var passes = 0, failures = 0
    static func check(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        if ok { passes += 1; print("PASS \(name)") } else { failures += 1; print("FAIL \(name) \(got())") }
    }
    static let tz = TimeZone(identifier: "America/Chicago")!
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c }
    static func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: h, minute: m, second: s))!
    }
    static func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    static func main() async {
        banner()
        stateMachine()
        await browserFlow()
        claudeCodeFooter()
        finalCardLines()
        screenshotCards017()
        sweepAndSources()
        dayLines()
        dayLinesLive()
        print("summary-fail: \(passes) passed, \(failures) failed; fictional fixtures, no windows")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: 1. Which failures name Settings

    static func banner() {
        let on = SummaryAvailability(provider: .local, busy: false, phase: .on(.local))
        let once = SummarizeNowFailure.once("writer-busy")
        check(SummarizeNowNotice.banner(for: once, summaries: on) == nil, "one-off (writer busy) with summaries on: no banner")
        check(SummarizeNowNotice.banner(for: MemError.missing, summaries: on) == nil, "any other error with summaries on: no banner (history busy, a moment changed)")
        check(SummarizeNowNotice.banner(for: MemError.invalid("Activity unavailable or incomplete"), summaries: on) == nil, "a moment that changed: no banner")
        check(SummarizeNowNotice.banner(for: once, summaries: SummaryAvailability(provider: .local, busy: false, phase: .downloading(received: 1, total: 2))) == nil,
              "the model still downloading is not broken: no banner")
        check(SummarizeNowNotice.banner(for: once, summaries: SummaryAvailability(provider: .local, busy: false, phase: .checking)) == nil, "the model check running: no banner")
        let off = SummarizeNowNotice.banner(for: once, summaries: SummaryAvailability(provider: .off, busy: false))
        check(off == "Summaries are off. Turn them on in Settings.", "summaries off: says so and names Settings", off ?? "nil")
        let broken = SummarizeNowNotice.banner(for: once, summaries: SummaryAvailability(provider: .local, busy: false, phase: .failed(.modelWontStart)))
        check(broken == "The model couldn't start. Fix it in Summaries in Settings.", "model broken: says exactly what", broken ?? "nil")
        let key = SummarizeNowNotice.banner(for: once, summaries: SummaryAvailability(provider: .cloud, busy: false, phase: .failed(.cloudKey)))
        check(key == "OpenRouter didn't accept this key. Fix it in Summaries in Settings.", "cloud key refused: says exactly what", key ?? "nil")
        let setup = SummarizeNowNotice.banner(for: SummarizeNowFailure.setup("Summaries are off."), summaries: on)
        check(setup == SummarizeNowNotice.summariesOff, "the writer saying summaries are off wins over a stale phase", setup ?? "nil")
        for text in [off, broken, key, setup].compactMap({ $0 }) {
            check(!text.contains("Check Summaries in Settings") && !text.hasPrefix("Couldn't summarize."), "no generic Settings line: \(text)")
        }
        check(SummarizeNowNotice.quietLine == "Couldn't summarize this one. Try again.", "the quiet line's words")
    }

    // MARK: 2. The state machine

    static func stateMachine() {
        var flow = CardSummaryFlow()
        check(flow.state == .pending && flow.state.summarizeEnabled && !flow.state.copyEnabled && !flow.state.sweeps && flow.state.quietLine == nil,
              "pending: Summarize Now enabled, Copy Summary dimmed, no sweep, no quiet line")
        check(flow.state.label("Summary pending") == "Summary pending" && CardSummaryState.violet("Summary pending"), "pending: violet \"Summary pending\"")
        check(flow.click() && flow.state == .working, "click: pending → working")
        check(!flow.state.summarizeEnabled && !flow.state.copyEnabled, "working: Summarize Now and Copy Summary greyed out")
        check(!flow.click() && flow.state == .working, "working: a second click does nothing")
        check(flow.state.label("Summary pending") == "Summarizing\u{2026}" && CardSummaryState.violet("Summarizing\u{2026}"), "working: violet \"Summarizing…\"")
        check(flow.state.label("What you wrote") == "Summarizing\u{2026}", "working from \"What you wrote\": \"Summarizing…\" too")
        check(flow.state.sweeps, "working: the quotes sweep")
        flow.finish(wrote: true)
        check(flow.state == .done && flow.state.label("Summary pending") == "Summary" && !CardSummaryState.violet("Summary"),
              "done: \"Summary\" in grey")
        check(flow.state.copyEnabled && !flow.state.summarizeEnabled && !flow.state.sweeps, "done: Copy Summary enabled, no sweep")
        flow.finish(wrote: false)
        check(flow.state == .done, "done stays done")

        var fail = CardSummaryFlow()
        fail.click(); fail.finish(wrote: false)
        check(fail.state == .failed && fail.state.label("Summary pending") == "Summary pending" && fail.state.summarizeEnabled,
              "working → failed: back to \"Summary pending\" with Summarize Now enabled")
        check(fail.state.quietLine == SummarizeNowNotice.quietLine && !fail.state.sweeps, "failed: the quiet line, no sweep")
        check(fail.click() && fail.state == .working, "failed → working on the next click")
        fail.finish(wrote: true)
        check(fail.state == .done, "… → done")

        // The card derives the same states from what it reads.
        check(CardSummaryState.of(bullets: false, running: false, missed: false) == .pending, "derive: nothing running, nothing missed → pending")
        check(CardSummaryState.of(bullets: false, running: true, missed: true) == .working, "derive: running (the retry too) → working")
        check(CardSummaryState.of(bullets: false, running: false, missed: true) == .failed, "derive: a one-off → failed")
        check(CardSummaryState.of(bullets: true, running: false, missed: true) == .done, "derive: a summary → done")
    }

    // MARK: The browser runs the flow (misses, the one automatic retry)

    static func browserFlow() async {
        let browser = ActivityBrowser(calendar: cal)
        browser.summaries = SummaryAvailability(provider: .local, busy: false, phase: .on(.local))
        browser.summarizeRetryDelay = 0.2
        var calls = 0, failNext = 1
        browser.generateCanonicalNote = { _, _, _, _ in
            calls += 1
            try await Task.sleep(nanoseconds: 50_000_000)
            if failNext > 0 { failNext -= 1; throw SummarizeNowFailure.once("writer-busy") }
        }
        let task = Task { @MainActor in try await browser.summarizeNow(day: "2026-10-03", timeZone: tz.identifier, id: "m1", end: at(13, 45)) }
        await Task.yield()
        check(browser.updatingMoments.contains("m1") && CardSummaryState.of(bullets: false, running: true, missed: false) == .working,
              "browser: while it runs the moment is updating (working)")
        var threw = false
        do { try await task.value } catch { threw = SummarizeNowNotice.banner(for: error, summaries: browser.summaries) == nil }
        check(threw && browser.summarizeMisses == ["m1"] && browser.updatingMoments.isEmpty,
              "browser: a one-off marks the moment missed (failed), no banner, no longer updating")
        check(CardSummaryState.of(bullets: false, running: false, missed: browser.summarizeMisses.contains("m1")) == .failed, "browser: the card reads failed")
        for _ in 0..<60 where calls < 2 || !browser.updatingMoments.isEmpty { try? await Task.sleep(nanoseconds: 25_000_000) }
        check(calls == 2 && browser.summarizeMisses.isEmpty, "browser: tried again once by itself, and a written note clears the miss", "calls \(calls)")

        // Always failing: the automatic retry happens once, never more.
        let stuck = ActivityBrowser(calendar: cal)
        stuck.summaries = browser.summaries
        stuck.summarizeRetryDelay = 0.1
        var stuckCalls = 0
        stuck.generateCanonicalNote = { _, _, _, _ in stuckCalls += 1; throw SummarizeNowFailure.once("writer-busy") }
        try? await stuck.summarizeNow(day: "2026-10-03", timeZone: tz.identifier, id: "m2", end: at(13, 45))
        try? await Task.sleep(nanoseconds: 700_000_000)
        check(stuckCalls == 2 && stuck.summarizeMisses == ["m2"], "browser: one automatic retry only; the button and quiet line stay", "calls \(stuckCalls)")

        // Summaries off: the error names it; the moment is not marked missed (the banner says what is wrong).
        let off = ActivityBrowser(calendar: cal)
        off.summaries = SummaryAvailability(provider: .local, busy: false, phase: .on(.local))
        off.generateCanonicalNote = { _, _, _, _ in throw SummarizeNowFailure.setup("Summaries are off.") }
        var text: String?
        do { try await off.summarizeNow(day: "2026-10-03", timeZone: tz.identifier, id: "m3", end: at(13, 45)) }
        catch { text = SummarizeNowNotice.banner(for: error, summaries: off.summaries) }
        check(text == SummarizeNowNotice.summariesOff && off.summarizeMisses.isEmpty, "browser: summaries off is a setup notice, not a quiet miss")
    }

    // MARK: 3. The pending Claude Code card's footer

    static func claudeCodeFooter() {
        let ghostty = "com.mitchellh.ghostty"
        // Fictional long prompts, shaped like the moment (two submitted, about 1,100 characters each).
        let p1 = String(repeating: "make the pending card clearer so the label and the quotes read as one state, ", count: 14)
        let p2 = String(repeating: "keep a failed summary calm with a quiet line instead of a banner, ", count: 17)
        func preview(_ id: String, _ when: Date, _ words: String) -> OwnerSourcePreview {
            OwnerSourcePreview(id: id, actionIDs: [id], at: iso(when), runID: "run-" + id,
                parts: [OwnerSourcePart(actionID: id, text: words, state: "submitted")], state: "submitted",
                lead: "Submitted text to Claude Code in Ghostty", readAt: at(14, 25), disclosureRevision: "fixture", expiresAt: nil)
        }
        let previews = [preview("cc-1", at(13, 37, 8), p1), preview("cc-2", at(13, 38, 0), p2)]
        var m = MomentSlice(id: "activity_cc", dayKey: "2026-10-03", start: at(13, 33), end: at(13, 45), title: "Tallybird app design review",
                            subject: "Tallybird app design review", firstBullet: nil, bullets: [], apps: ["Ghostty"], primaryBundle: ghostty,
                            bundles: [ghostty], sites: [], actionIDs: ["cc-1", "cc-2"], actionCount: 17, clusters: [], summary: .pending,
                            hasCorrection: false, primaryApp: "Ghostty")
        // Code's send line for the session: the line that hid Summarize Now.
        m.live = LiveMoment(label: "Tallybird app design review", kind: "ai", sends: ["Asked Claude Code"], seconds: 720, idle: false, communication: true)
        check(!m.lines.isEmpty, "fixture: the pending moment has code's \"Asked Claude Code\" line")
        let column = FocusAppCard.leftColumn([m], previews: previews, pending: true)
        // claude/notesfix-015 (owner 10/05, 0.1.6): a card's lines are final, never "Summary pending". claude/int-017 (owner
        // 10/06, 0.1.7): "Summary" over code's own lines.
        check(column.header == "Summary" && column.bullets.isEmpty && column.quotes.count == 2,
              "Claude Code card: \"Summary\" over its 2 prompts (never \"Summary pending\")", "\(column.header ?? "nil") \(column.quotes.count)")
        // Before: the button rebuilt the header from every line, code's included, so it read "Summary" and hid.
        let oldBullets = !FocusAppCard.bullets([m]).isEmpty
        check(oldBullets && !FocusAppCard.offersSummarizeNow(bullets: oldBullets, header: "Summary", targets: 1, running: false),
              "regression: the old computation hid Summarize Now here")
        let browser = ActivityBrowser(calendar: cal)
        browser.generateCanonicalNote = { _, _, _, _ in }
        browser.previewCanonicalDelete = { _ in throw MemError.missing }
        browser.confirmCanonicalDelete = { _ in }
        browser.summaries = SummaryAvailability(provider: .local, busy: false, phase: .on(.local))
        let caps = MomentActions.Capabilities(browser: browser)
        let targets = FocusAppCard.summarizeTargets([m], caps: caps)
        check(targets.map(\.id) == ["activity_cc"], "Claude Code card: the pending moment is a Summarize Now target despite code's line")
        // claude/notesfix-015 (owner 10/05, 0.1.6): no model writes a moment, so a card never offers Summarize Now.
        check(!FocusAppCard.offersSummarizeNow(column, targets: targets.count, running: false), "Claude Code card: no Summarize Now (its lines are final)")
        check(!FocusAppCard.offersSummarizeNow(column, targets: targets.count, running: true), "Claude Code card: no Summarize Now while anything runs either")
        let items = MomentActions.items(for: m, context: .focusList, browser: caps)
        let bar = FocusListExpanded.footerItems(items, moment: m)
        check(bar.first?.id == .copySummary && bar.first?.enabled == false && bar.contains { $0.id == .forget } && !bar.contains { $0.id == .summarizeNow },
              "footer: Copy Summary first (dimmed until there is a summary), Forget on the right, Summarize Now beside Copy (its own button)",
              "\(bar.map { "\($0.title)/\($0.enabled)" })")
        let working = FocusListExpanded.footerItems(items, moment: m, working: true)
        check(working.first?.id == .copySummary && working.first?.enabled == false, "footer while working: Copy Summary greyed out")
        // A written card: Copy Summary enabled, greyed out only while a Summarize Now runs on it.
        let written = MomentSlice(id: "w", dayKey: "2026-10-03", start: at(13, 0), end: at(13, 5), title: "Fixture", subject: "Fixture", firstBullet: "Asked Claude Code to tidy the card.",
                                  bullets: [MomentBullet(text: "Asked Claude Code to tidy the card.")], apps: ["Ghostty"], primaryBundle: ghostty, bundles: [ghostty],
                                  sites: [], actionIDs: ["w1"], actionCount: 1, clusters: [], summary: .ready(generatedAt: nil, local: true), hasCorrection: false,
                                  primaryApp: "Ghostty")
        let wItems = MomentActions.items(for: written, context: .focusList, browser: caps)
        check(FocusListExpanded.footerItems(wItems, moment: written).first.map { $0.id == .copySummary && $0.enabled } == true, "written card: Copy Summary enabled")
        check(FocusListExpanded.footerItems(wItems, moment: written, working: true).first.map { $0.id == .copySummary && !$0.enabled } == true,
              "written card being rewritten: Copy Summary greyed out")
    }

    // MARK: claude/notesfix-015 golden: a card's own lines are final (owner 10/05, 0.1.6)

    /// The owner pressed the summary button on an X reply: the card's quoted reply (what was written) gave way to code's
    /// note "Replied to @… on X." with no content. A written note may never take the card's grounded lines away: the
    /// quotes stay, under "What you wrote", with no "Summary pending", "Updating…" or "Writing the summary…" left hanging
    /// and no Summarize Now. Fictional handle and words.
    static func finalCardLines() {
        let chrome = "com.google.Chrome"
        let words = "agreed, smaller tools win for weekend projects and the docs matter more than the framework"
        let preview = OwnerSourcePreview(id: "xr-1", actionIDs: ["xr-1"], at: iso(at(15, 2)), runID: "run-xr-1",
            parts: [OwnerSourcePart(actionID: "xr-1", text: words, state: "submitted")], state: "submitted",
            lead: "Submitted text to x.com in Google Chrome", readAt: at(15, 10), disclosureRevision: "fixture", expiresAt: nil)
        func slice(_ summary: MomentSummaryState, bullets: [MomentBullet]) -> MomentSlice {
            var m = MomentSlice(id: "activity_xr", dayKey: "2026-10-05", start: at(15, 0), end: at(15, 5), title: "Reply on X", subject: "Reply on X",
                                firstBullet: bullets.first?.text, bullets: bullets, apps: ["Google Chrome"], primaryBundle: chrome, bundles: [chrome],
                                sites: ["x.com"], actionIDs: ["xr-1"], actionCount: 3, clusters: [], summary: summary, hasCorrection: false,
                                primaryApp: "Google Chrome")
            m.live = LiveMoment(label: "Reply on X", kind: "social", sends: ["Replied to @fixturehandle on X"], seconds: 300, idle: false, communication: true)
            return m
        }
        let pendingCard = FocusAppCard.leftColumn([slice(.pending, bullets: [])], previews: [preview], pending: true)
        var written = slice(.ready(generatedAt: nil, local: true), bullets: [MomentBullet(text: "Replied to @fixturehandle on X.")])
        written.byCode = true
        let writtenCard = FocusAppCard.leftColumn([written], previews: [preview], pending: false)
        check(pendingCard.quotes.count == 1 && pendingCard.quotes[0].contains("smaller tools"), "golden: the pending X reply card quotes what was replied",
              "\(pendingCard.quotes.count)")
        // The golden: the written card carries at least the pending card's grounded content.
        check(writtenCard.quotes == pendingCard.quotes, "golden: after the note is written, the X reply card still says what was replied",
              "\(writtenCard.header ?? "nil") quotes \(writtenCard.quotes.count) bullets \(writtenCard.bullets.map(\.text))")
        // claude/int-017 (owner 10/06, 0.1.7): "Summary" before and after (code's own lines; was "What you wrote" in notesfix-015).
        check(writtenCard.header == "Summary" && pendingCard.header == "Summary", "golden: one header before and after, never \"Summary pending\"",
              "\(pendingCard.header ?? "nil") / \(writtenCard.header ?? "nil")")
        check([true, false].allSatisfy { b in [true, false].allSatisfy { q in [true, false].allSatisfy {
                  let h = FocusAppCard.header(bullets: b, quotes: q, pending: $0); return h == nil || h == "Summary" } } },
              "golden: a card never says \"Summary pending\" or \"What you wrote\"")
        check(!FocusAppCard.offersSummarizeNow(pendingCard, targets: 1, running: false) && !FocusAppCard.offersSummarizeNow(writtenCard, targets: 1, running: false),
              "golden: no Summarize Now on a card")
        check(written.previousSummaryStatus(phase: .on(.local), queue: nil) == nil, "golden: no \"Updating…\" on a card")
        var stale = slice(.pending, bullets: [MomentBullet(text: "Replied to @fixturehandle on X.")]); stale.stale = true
        check(stale.previousSummaryStatus(phase: .on(.local), queue: SummaryQueue(writing: ["activity_xr"], lookedAt: at(15, 6))) == nil,
              "golden: a stale card being rewritten says no \"Updating…\" either")
        let queued = SummaryQueue(writing: ["activity_xr"], lookedAt: at(15, 6))
        var bare = slice(.pending, bullets: []); bare.live = nil
        check(MomentDetailBody.summaryStatus(bare, phase: .on(.local), queue: queued) == "", "golden: a pending moment draws no \"Writing the summary…\" line",
              MomentDetailBody.summaryStatus(bare, phase: .on(.local), queue: queued) ?? "nil")
        // claude/int-017 (owner 10/06): an ask stays on the collapsed row over code's note; on X, as in 0.1.6, code's note
        // line still wins (patch 6's X lead shows before a note).
        var ask = written; ask.prompt = "fixture ask about the export"
        check(MomentSubtitle.shownPrompt(ask) == "fixture ask about the export", "golden: an ask stays over code's note")
        var xAsk = ask; xAsk.promptLead = "Replied"
        check(MomentSubtitle.shownPrompt(xAsk) == nil, "golden: an X row as in 0.1.6 (code's note line wins)")
        ask.byCode = false
        check(MomentSubtitle.shownPrompt(ask) == nil, "golden: a model's note still wins over the ask")
    }

    // MARK: claude/int-017 golden: the owner's two 0.1.6 screenshots (owner 10/06, 0.1.7)

    /// The owner's 0.1.6 screenshots of expanded cards:
    /// (1) a ChatGPT card read "Summary", "Updating…", "• Used the send key in ChatGPT.", then What happened with the
    ///     "Asked ChatGPT" rows and the questions: "the summary is junk and makes no sense"; its collapsed row read
    ///     "Used the send key in ChatGPT." too;
    /// (2) a Messages card read "Summary", the contact's name, the quoted text, then "Wrote a text in Messages.":
    ///     "confusing and redundant".
    /// Owner 10/06: "Summary" stays, filled with code's lines that condense the rows: one "Asked ChatGPT “…”." per
    /// question (the first sentence or about 80 characters, a repeat merged "(2×)", about 5 then "+N more"), one
    /// "Texted <name>: “…”" per person (their latest text; "Wrote to <name>: “…”" when its send wasn't seen); never "Updating…", "Used the send key in <App>.", "Typed in
    /// <App>." or a line that only names the app, key or action; one bullet style. The collapsed AI row says what was
    /// asked: "Asked “…”" or "Asked 5 questions · latest “…”". Both fail on 6852390 (0.1.6: "Summary" over "Used the send
    /// key in ChatGPT." with "Updating…"; "Wrote a text in Messages." under the texts). Fictional names and words.
    static func screenshotCards017() {
        let none = ["Summary pending", "What you wrote", "Updating\u{2026}", "Writing the summary\u{2026}", "Summarizing\u{2026}"]
        func clean(_ lines: [String], _ name: String) {
            check(!lines.contains { none.contains($0) }, "\(name): no waiting line", "\(lines)")
            check(!lines.contains { $0.lowercased().contains("draft") }, "\(name): never \"draft\"", "\(lines)")
            check(!lines.contains { $0.lowercased().contains("send key") }, "\(name): never \"send key\"", "\(lines)")
            check(!lines.contains(where: FocusAppCard.restatesRows), "\(name): no line that only names the app, key or action", "\(lines)")
        }

        // (1) ChatGPT: five asks sent (compose "asked", a send recorded), one of them the same question twice; code's note
        // "Used the send key in ChatGPT.", kept while a newer one was due (the "Updating…" state).
        let chatgpt = "com.openai.chat"
        let asks: [(String, Int, String)] = [
            ("g1", 1, "what is a good way to keep a timeline readable when it has hundreds of fixture rows and many apps in them"),
            ("g2", 2, "status of everything?"),
            ("g3", 3, "how do I group the rows by app? I also want the newest one first."),
            ("g4", 4, "status of everything?"),
            ("g5", 5, "can you write the release notes for the fixture build.")]
        func ask(_ id: String, _ when: Date, _ words: String, state: String = "submitted") -> OwnerSourcePreview {
            OwnerSourcePreview(id: id, actionIDs: [id], at: iso(when), runID: "run-" + id,
                parts: [OwnerSourcePart(actionID: id, text: words, state: state)], state: state,
                lead: (state == "submitted" ? "Submitted text" : "Drafted text") + " in ChatGPT", readAt: at(16, 10),
                disclosureRevision: "fixture", expiresAt: nil)
        }
        let asked = ComposeLine(ComposeOutcome(kind: .asked, destination: ComposeDestination(service: "ChatGPT")))
        let ids = asks.map(\.0)
        var gpt = MomentSlice(id: "activity_gpt", dayKey: "2026-10-06", start: at(16, 0), end: at(16, 6), title: "ChatGPT", subject: "ChatGPT",
                              firstBullet: "Used the send key in ChatGPT.", bullets: [MomentBullet(text: "Used the send key in ChatGPT.", actionIDs: ids)],
                              apps: ["ChatGPT"], primaryBundle: chatgpt, bundles: [chatgpt], sites: [], actionIDs: ids, actionCount: 12,
                              clusters: [], summary: .ready(generatedAt: nil, local: true), hasCorrection: false, primaryApp: "ChatGPT", stale: true)
        gpt.byCode = true
        gpt.currentSummary = .pending
        gpt.live = LiveMoment(label: "ChatGPT", kind: "ai", sends: ["Asked ChatGPT"], seconds: 360, idle: false, communication: true)
        let compose = Dictionary(uniqueKeysWithValues: ids.map { ($0, asked) })
        let gptCard = FocusAppCard.leftColumn([gpt], previews: asks.map { ask($0.0, at(16, $0.1), $0.2) }, pending: true, compose: compose)
        let gptLines = FocusAppCard.summaryLines(gptCard)
        let wantGPT = ["Asked ChatGPT \u{201C}can you write the release notes for the fixture build\u{201D}.",
                       "Asked ChatGPT \u{201C}status of everything?\u{201D} (2\u{00D7}).",
                       "Asked ChatGPT \u{201C}how do I group the rows by app?\u{201D}.",
                       "Asked ChatGPT \u{201C}what is a good way to keep a timeline readable when it has hundreds of fixture\u{2026}\u{201D}."]
        check(gptCard.header == "Summary" && gptLines == wantGPT, "golden (1) ChatGPT: \"Summary\" over one line per question, the repeat merged (2×)",
              "\(gptCard.header ?? "nil") \(gptLines)")
        check(gpt.previousSummaryStatus(phase: .on(.local), queue: SummaryQueue(writing: ["activity_gpt"], lookedAt: at(16, 7))) == nil,
              "golden (1) ChatGPT: no \"Updating…\" while a newer note is due")
        clean(gptLines, "golden (1) ChatGPT")
        // Many questions: about 5, then "+N more" (opened inline).
        let many = (1...8).map { ("m\($0)", $0, "fixture question number \($0) about the export") }
        let manyCard = FocusAppCard.leftColumn([gpt], previews: many.map { ask($0.0, at(16, $0.1), $0.2) }, pending: true,
                                               compose: Dictionary(uniqueKeysWithValues: many.map { ($0.0, asked) }))
        let manyLines = FocusAppCard.summaryLines(manyCard)
        check(manyLines.count == 8 && FocusAppCard.visibleSummary(manyLines, expanded: false).count == 5 && FocusAppCard.summaryMore(manyLines) == "+3 more"
              && FocusAppCard.visibleSummary(manyLines, expanded: true).count == 8, "golden (1) ChatGPT: 5 lines, then \"+3 more\"", "\(manyLines.count)")
        // The words couldn't be opened (no previews): code's line alone is filler, so no Summary lines at all.
        let noWords = FocusAppCard.leftColumn([gpt], previews: [], pending: true, compose: compose)
        check(FocusAppCard.summaryLines(noWords).isEmpty, "golden (1) ChatGPT without words: no \"Used the send key in ChatGPT.\"",
              "\(FocusAppCard.summaryLines(noWords))")
        // A question typed and never sent: the bare quote, never "Asked" (no send claimed without a recorded one).
        let unsent = FocusAppCard.summaryLines(FocusAppCard.leftColumn([gpt], previews: [ask("g9", at(16, 5), "maybe also the fixture import", state: "draft")], pending: true))
        check(unsent == ["\u{201C}maybe also the fixture import\u{201D}"], "golden (1) ChatGPT: an unsent question is the bare quote", "\(unsent)")
        // The collapsed row: what was asked, never code's "Used the send key in ChatGPT.".
        var row = gpt; row.prompt = "can you write the release notes for the fixture build."; row.promptAsks = 5
        let collapsed = FocusAppCard.collapsedLine([row])
        check(collapsed == "Asked 5 questions \u{00B7} latest \u{201C}can you write the release notes for the fixture build\u{201D}",
              "golden (1) ChatGPT collapsed: \"Asked 5 questions · latest “…”\"", collapsed)
        var one = row; one.promptAsks = 1
        check(FocusAppCard.collapsedLine([one]) == "Asked \u{201C}can you write the release notes for the fixture build\u{201D}",
              "golden (1) ChatGPT collapsed, one question: \"Asked “…”\"", FocusAppCard.collapsedLine([one]))
        var bare = row; bare.promptAsks = nil
        check(FocusAppCard.collapsedLine([bare]) == "\u{201C}can you write the release notes for the fixture build.\u{201D}",
              "golden (1) ChatGPT collapsed, an ask not seen sent: the bare quote as in 0.1.6", FocusAppCard.collapsedLine([bare]))
        var typingOff = gpt; typingOff.prompt = nil
        let offLine = FocusAppCard.collapsedLine([typingOff])
        check(!offLine.lowercased().contains("send key"), "golden (1) ChatGPT collapsed with typing off: never \"Used the send key in ChatGPT.\"", offLine)
        check(MomentPromptText.split(MomentPromptText.asked(count: 5, words: "w")) == MomentPromptText.Value(words: "w", lead: nil, at: nil, asks: 5)
              && MomentPromptText.split("w").asks == nil && MomentPromptText.split(MomentPromptText.sent(lead: "Posted", at: "t", words: "w")).lead == "Posted",
              "the prompt value carries the sent-ask count; plain and X values as before")

        // (2) Messages: texts to two people (recorded sends), code's note "Texted Sam Rivera." and "Wrote a text in
        // Messages." for a piece the conversations don't show.
        let sms = "com.apple.MobileSMS"
        let samOld = "are we still on for the fixture review"
        let samNew = "BTW i did implement the export fix last night and the fixture tests all pass now, so we can ship it"
        let jordan = "running ten minutes late, save me a seat"
        func text(_ id: String, _ when: Date, _ words: String, to name: String) -> OwnerSourcePreview {
            OwnerSourcePreview(id: id, actionIDs: [id], at: iso(when), runID: "run-" + id,
                parts: [OwnerSourcePart(actionID: id, text: words, state: "submitted")], state: "submitted",
                lead: "Submitted text to \(name) in Messages", readAt: at(17, 10), disclosureRevision: "fixture", expiresAt: nil)
        }
        func unit(_ id: String, _ when: Date, _ name: String) -> CanonicalAction {
            ActionProjection.make(Evidence(id: id, at: iso(when), kind: "keyboard.text_input", app: "Messages", bundle: sms, title: name, text: "", synthetic: true))
        }
        func to(_ name: String) -> ComposeLine { ComposeLine(title: "Sent to " + name, sent: true, kind: "texted", name: name, sealedByReturn: true) }
        var smsMoment = MomentSlice(id: "activity_sms", dayKey: "2026-10-06", start: at(17, 0), end: at(17, 4), title: "Texts", subject: "Texts",
            firstBullet: "Texted Sam Rivera.", bullets: [MomentBullet(text: "Texted Sam Rivera.", actionIDs: ["t1", "t3"]),
                                                          MomentBullet(text: "Wrote a text in Messages.", actionIDs: ["t4"])],
            apps: ["Messages"], primaryBundle: sms, bundles: [sms], sites: [], actionIDs: ["t1", "t2", "t3", "t4"], actionCount: 8, clusters: [],
            summary: .ready(generatedAt: nil, local: true), hasCorrection: false, primaryApp: "Messages")
        smsMoment.byCode = true
        let smsCard = FocusAppCard.leftColumn([smsMoment], previews: [text("t1", at(17, 1), samOld, to: "Sam Rivera"), text("t2", at(17, 2), jordan, to: "Jordan Lane"),
                                                                     text("t3", at(17, 3), samNew, to: "Sam Rivera")],
                                              pending: false, compose: ["t1": to("Sam Rivera"), "t2": to("Jordan Lane"), "t3": to("Sam Rivera")],
                                              actions: [unit("t1", at(17, 1), "Sam Rivera"), unit("t2", at(17, 2), "Jordan Lane"),
                                                        unit("t3", at(17, 3), "Sam Rivera"), unit("t4", at(17, 3, 30), "Sam Rivera")])
        let smsLines = FocusAppCard.summaryLines(smsCard)
        // claude/rel-017c (owner 10/06): "Texted <name>: “…”" when the send was seen, as the collapsed row's "Texted Sam Rivera.".
        let wantSMS = ["Texted Sam Rivera: \u{201C}BTW i did implement the export fix last night and the fixture tests all pass\u{2026}\u{201D}",
                       "Texted Jordan Lane: \u{201C}running ten minutes late, save me a seat\u{201D}"]
        check(smsCard.header == "Summary" && smsLines == wantSMS, "golden (2) Messages: \"Summary\" over one line per person, their latest text",
              "\(smsCard.header ?? "nil") \(smsLines)")
        check(!smsLines.contains { $0.hasPrefix("To ") }, "golden (2) Messages: never \"To <name>:\"", "\(smsLines)")
        // A text code didn't see sent (no send signal on its compose line; a Return alone isn't one): "Wrote to", never "draft".
        let unseen = ComposeLine(title: "Typed to Jordan Lane", sent: false, kind: "texted", name: "Jordan Lane", sealedByReturn: true)
        let unseenLines = FocusAppCard.summaryLines(FocusAppCard.leftColumn([smsMoment], previews: [text("t2", at(17, 2), jordan, to: "Jordan Lane")],
                                                                              pending: false, compose: ["t2": unseen], actions: [unit("t2", at(17, 2), "Jordan Lane")]))
        check(unseenLines == ["Wrote to Jordan Lane: \u{201C}running ten minutes late, save me a seat\u{201D}"],
              "golden (2) Messages: a text not seen sent is \"Wrote to <name>: “…”\"", "\(unseenLines)")
        check(!unseenLines.joined().lowercased().contains("draft"), "golden (2) Messages: never \"draft\"", "\(unseenLines)")
        clean(smsLines, "golden (2) Messages")
        // Many people: about 5, then "+N more".
        let people = (1...7).map { ("p\($0)", $0, "Person \($0)") }
        let crowd = FocusAppCard.leftColumn([smsMoment], previews: people.map { text($0.0, at(17, $0.1), "fixture hello \($0.1)", to: $0.2) }, pending: false,
                                            compose: Dictionary(uniqueKeysWithValues: people.map { ($0.0, to($0.2)) }),
                                            actions: people.map { unit($0.0, at(17, $0.1), $0.2) })
        let crowdLines = FocusAppCard.summaryLines(crowd)
        check(crowdLines.count == 7 && FocusAppCard.summaryMore(crowdLines) == "+2 more" && crowdLines.first == "Texted Person 7: \u{201C}fixture hello 7\u{201D}",
              "golden (2) Messages: one line per person, 5 then \"+2 more\"", "\(crowdLines)")
        // A line that adds something stays: a text whose words couldn't be opened, to someone the conversations don't show.
        var withMaya = smsMoment
        withMaya = MomentSlice(id: withMaya.id, dayKey: withMaya.dayKey, start: withMaya.start, end: withMaya.end, title: "Texts", subject: "Texts",
            firstBullet: nil, bullets: [MomentBullet(text: "Texted Maya about the train.", actionIDs: ["t4"]), MomentBullet(text: "Wrote a text in Messages.", actionIDs: ["t4"])],
            apps: ["Messages"], primaryBundle: sms, bundles: [sms], sites: [], actionIDs: withMaya.actionIDs, actionCount: 8, clusters: [],
            summary: .ready(generatedAt: nil, local: true), hasCorrection: false, primaryApp: "Messages")
        let mayaLines = FocusAppCard.summaryLines(FocusAppCard.leftColumn([withMaya], previews: [text("t3", at(17, 3), samNew, to: "Sam Rivera")], pending: false,
            compose: ["t3": to("Sam Rivera")], actions: [unit("t3", at(17, 3), "Sam Rivera"), unit("t4", at(17, 3, 30), "Maya")]))
        check(mayaLines.count == 2 && mayaLines.last == "Texted Maya about the train.", "golden (2) Messages: a line with a name stays; the filler beside it goes",
              "\(mayaLines)")

        // The filler rule: restating lines go, lines that add information stay.
        for line in ["Used the send key in ChatGPT.", "Wrote a text in Messages.", "Drafted a text in Messages.", "Typed in ChatGPT.", "Typed in Notes.",
                     "Asked ChatGPT.", "Hit send in X.", "Typed in ChatGPT and used the send key.", "Texted someone in Messages.", "Wrote a prompt for Claude Code.",
                     "Typed prompts for Claude Code."] {
            check(FocusAppCard.restatesRows(line), "filler on a card: \(line)")
        }
        for line in ["Texted Sam.", "Posted on X.", "Replied to @fixturehandle on X.", "On X for 25 minutes.", "Asked Claude Code to tidy the card.",
                     "Texted Sam about Friday.", "Viewed @ada's post.", "Worked in Terminal for 52 minutes."] {
            check(!FocusAppCard.restatesRows(line), "kept on a card: \(line)")
        }
        check(DisplayWords.sendKeyOnly("Used the send key in ChatGPT.") && DisplayWords.sendKeyOnly("Hit send in X.") && !DisplayWords.sendKeyOnly("Texted Sam."),
              "a gesture-only line is recognised")
        check(DisplayWords.undraft("Typed in ChatGPT, then used its send key") == "Typed in ChatGPT"
              && DisplayWords.undraft("Typed in Notes and used the send key.") == "Typed in Notes."
              && DisplayWords.undraft("Asked “why the send key sticks”") == "Asked “why the send key sticks”",
              "the send key never shows outside the person's own quoted words",
              DisplayWords.undraft("Typed in ChatGPT, then used its send key") + " | " + DisplayWords.undraft("Typed in Notes and used the send key."))
        // Every stored form that names the key (TypedTextStore, Models, AssistantView, TypedAccess) reads without it on a card.
        for stored in ["Typed in ChatGPT, then used its send key (a sentence).", "Typed in Notes, then used its send key, a few words.",
                       "Typed in Claude, then used its send key, a sentence (exact words not shared with AI apps)", "Used the send key in Messages."] {
            let shown = DisplayWords.undraft(stored)
            check(DisplayWords.sendKeyOnly(shown) || !shown.lowercased().contains("send key"), "no card text says \"send key\": \(stored)", shown)
        }
        check(FocusAppCard.plainSentences(["Typed in ChatGPT.", "Worked in Terminal for 52 minutes.", "Used the send key in ChatGPT."]) == ["Worked in Terminal for 52 minutes."],
              "What happened as sentences: no filler either")
        check(FocusAppCard.shortQuoteWords("Fix the parser. Then rerun the tests.") == "Fix the parser" && FocusAppCard.shortQuoteWords("is it on? yes it is") == "is it on?",
              "short quotes: the first sentence")

        // The views: "Summary" over code's lines, one grey dot, no "Updating…", no Summarize Now.
        let card = source("Sources/MemoryUI/FocusListExpanded.swift")
        if let a = card.range(of: "    private var summary: some View {"), let b = card.range(of: "    /// The card's Summarize Now state") {
            let body = String(card[a.lowerBound..<b.lowerBound])
            check(body.contains("FocusAppCard.summaryLines(column)") && body.contains("Text(\"Summary\")") && !body.contains("Bullet(")
                  && body.contains("CardLine(") && body.contains("FocusAppCard.summaryMore(shown)") && body.contains("FocusAppCard.plainSentences(")
                  && !body.contains("previousSummaryStatus"),
                  "expanded card: \"Summary\" over summaryLines (or filtered sentences), CardLine dots, \"+N more\"")
        } else { check(false, "expanded card: its summary body is found") }
        let kit = source("Sources/MemoryUI/DaydreamKitMoments.swift")
        if let a = kit.range(of: "    @ViewBuilder private var summary: some View {"), let b = kit.range(of: "    private var happened: some View {") {
            let body = String(kit[a.lowerBound..<b.lowerBound])
            check(body.contains("FocusAppCard.summaryLines(column)") && !body.contains("previousSummaryStatus") && !body.contains("summaryStatus(")
                  && !body.contains("No summary yet") && !body.contains("Bullet(") && body.contains("CardLine("),
                  "details page: \"Summary\" over the same lines; no \"Updating…\", status or \"No summary yet\" line; one grey dot")
        } else { check(false, "details page: its summary body is found") }
        check(card.contains("Text(\"\\u{2022}\").foregroundStyle(.tertiary)") && card.contains("struct CardLine: View"), "CardLine draws a grey dot")
        let caps = MomentActions.Capabilities(browser: { let b = ActivityBrowser(calendar: cal); b.generateCanonicalNote = { _, _, _, _ in }
            b.summaries = SummaryAvailability(provider: .local, busy: false, phase: .on(.local)); return b }())
        check(!MomentActions.items(for: gpt, context: .focusList, browser: caps).contains { $0.id == .summarizeNow }
              && !FocusAppCard.offersSummarizeNow(gptCard, targets: 1, running: false), "no Summarize Now on a card or in its menu")
    }

    // MARK: The sweep and the sources

    static func sweepAndSources() {
        check(SummarySweep.period == 4.5, "sweep: about 4.5 s a pass")
        check(SummarySweep.offset(phase: 0) == -2 && SummarySweep.offset(phase: 1) == 0 && SummarySweep.offset(phase: 0.5) == -1,
              "sweep: the 3-wide strip slides from left of the block to right of it (band at -0.5 → 1.5 widths)")
        check(SummarySweep.stops == [0.35, 0.5, 0.65], "sweep: summary-v2's 35/50/65 band")
        let card = source("Sources/MemoryUI/FocusListExpanded.swift")
        // claude/int-017 (owner 10/06): no Summarize Now on a card, so the card's summary never sweeps, dims or fades in;
        // the sweep itself stays defined (above) for anything that still runs it.
        check(!card.contains(".modifier(QuoteSweep(active: state.sweeps") && !card.contains("state.label(column.header")
              && !card.contains("CardSummaryState.violet(header)") && !card.contains(".opacity.combined(with: .offset(y: 3))"),
              "the card's summary: no sweep, no violet label, no fade-in (no Summarize Now)")
        let timeline = source("Sources/MemoryUI/CanonicalTimeline.swift")
        check(!timeline.contains("Check Summaries in Settings") && timeline.contains("SummarizeNowNotice.banner(for: error, summaries: browser.summaries)"),
              "timeline: no blanket Settings banner; only SummarizeNowNotice.banner")
        let writer = source("Sources/MacMemApp/WriterIntegration.swift")
        check(writer.contains("throw SummarizeNowFailure.once(\"writer-busy\")") && writer.contains("throw SummarizeNowFailure.setup(\"Summaries are off.\")")
              && !writer.contains("Enable a ready writer first"), "writer: typed failures (setup only when off)")
        check(writer.contains("!automatic || clicksWaiting==0") && writer.contains("clicksWaiting==0,codeOnly"), "writer: a background batch stops for a waiting click")
    }

    // MARK: 4. The day card

    static func dayLines() {
        let shot = ["Texts, ~8 min", "Texts with Q7 and Jamie Lin, ~1 min", "Asked Claude to summarize the launch notes"]
        check(DayLineFiller.keep(shot) == [false, true, true], "day card: the bare \"Texts, ~8 min\" goes beside a real Texts line", "\(DayLineFiller.keep(shot))")
        check(DayLineFiller.keep(["Texts, ~8 min", "Texted Sam about dinner"]) == [false, true], "day card: a send line counts as the real Texts line")
        check(DayLineFiller.keep(["Texts, ~8 min", "Fixture plan, ~20 min"]) == [true, true], "day card: a bare line with nothing better stays")
        check(DayLineFiller.keep(["Email, ~5 min", "Texts with Sam, ~3 min"]) == [true, true], "day card: another channel's line doesn't remove it")
        check(DayLineFiller.keep(["Email, ~5 min", "Emailed Sam — 'Fixture'"]) == [false, true], "day card: email too")
        check(MemoryStore.bareLine("Ghostty, ~20 min", apps: ["ghostty"]) && !MemoryStore.bareLine("Tallybird app design review, ~20 min", apps: ["ghostty"]),
              "day card: an app name with minutes is bare; a named thread is not")
        let slice = LevelWords.oneEntryPerConversation(shot.map { LevelBullet(text: $0, moments: []) }).map(\.text)
        check(slice == Array(shot.dropFirst()), "day card: the page drops it from stored day notes too", "\(slice)")
    }

    /// The live day lines from a temp store: an anonymous Messages stretch (code knows no one) and a named conversation.
    static func dayLinesLive() {
        do {
            let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("summary-fail-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
            let sms = "com.apple.MobileSMS"
            var n = 0
            func put(_ when: Date, _ app: String, _ bundle: String, _ title: String, kind: String = "window.changed") throws {
                n += 1
                _ = try store.ingest(Evidence(id: "e\(n)", at: iso(when), kind: kind, app: app, bundle: bundle, title: title, synthetic: true), now: when)
            }
            // 13:00–13:08 Messages with no conversation code can name; 13:10 Xcode; 13:20 "Q7" for a minute; 13:22 Xcode.
            for s in stride(from: 0, through: 480, by: 30) { try put(at(13, 0).addingTimeInterval(TimeInterval(s)), "Messages", sms, "Messages") }
            for s in stride(from: 0, through: 540, by: 60) { try put(at(13, 10).addingTimeInterval(TimeInterval(s)), "Xcode", "com.apple.dt.Xcode", "ExportView.swift — harborline") }
            for s in stride(from: 0, through: 60, by: 20) { try put(at(13, 20).addingTimeInterval(TimeInterval(s)), "Messages", sms, "Q7") }
            for s in stride(from: 0, through: 300, by: 60) { try put(at(13, 22).addingTimeInterval(TimeInterval(s)), "Xcode", "com.apple.dt.Xcode", "ExportView.swift — harborline") }
            let levels = try store.dayLevels(day: "2026-10-03", timezone: tz.identifier, now: at(14, 0))
            guard let live = levels.live else { check(false, "live day: threads built"); return }
            let lines = [live.mainTitle] + live.lines.map(\.text)
            let texts = lines.filter { DayLineFiller.channel($0) == "texts" }
            print("  live day (fictional): \(lines)")
            if ProcessInfo.processInfo.environment["SF_DEBUG"] != nil {
                for (k, v) in live.moments { print("   moment", k.prefix(14), v.label, v.kind, v.seconds, v.idle) }
                for b in live.blocks { print("   block", b.label, b.side) }
            }
            // 8cfa725 read ["Harborline code", "Texts, ~10 min", "Texts with Q7, ~2 min"] here (the owner's screenshot shape).
            check(texts.count == 1 && lines.contains("Texts with Q7, ~2 min") && !lines.contains("Texts, ~10 min"),
                  "live day: one Texts entry, never a bare \"Texts, ~N min\" beside a named one", "\(lines)")
            check(!live.blocks.flatMap(\.side).contains("Texts, ~10 min") && live.blocks.flatMap(\.side).contains("Texts with Q7, ~2 min"),
                  "live day: a block's side threads too", "\(live.blocks.map(\.side))")
            check(!live.lines.contains { MemoryStore.bareLine($0.text, apps: ["messages"]) && lines.contains(where: { $0.hasPrefix("Texts with ") || $0.hasPrefix("Texted ") }) },
                  "live day: no bare Texts line beside a real one", "\(lines)")
        } catch { check(false, "live day: fixture store", "\(error)") }
    }
}
