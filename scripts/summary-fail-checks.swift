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
        check(column.header == "Summary pending" && column.bullets.isEmpty && column.quotes.count == 2,
              "Claude Code card: violet \"Summary pending\" over its 2 quoted prompts", "\(column.header ?? "nil") \(column.quotes.count)")
        // Before: the button rebuilt the header from every line, code's included, so it read "Summary" and hid.
        let oldBullets = !FocusAppCard.bullets([m]).isEmpty
        check(oldBullets && !FocusAppCard.offersSummarizeNow(bullets: oldBullets, header: FocusAppCard.header(bullets: oldBullets, quotes: true, pending: true),
                                                              targets: 1, running: false), "regression: the old computation hid Summarize Now here")
        let browser = ActivityBrowser(calendar: cal)
        browser.generateCanonicalNote = { _, _, _, _ in }
        browser.previewCanonicalDelete = { _ in throw MemError.missing }
        browser.confirmCanonicalDelete = { _ in }
        browser.summaries = SummaryAvailability(provider: .local, busy: false, phase: .on(.local))
        let caps = MomentActions.Capabilities(browser: browser)
        let targets = FocusAppCard.summarizeTargets([m], caps: caps)
        check(targets.map(\.id) == ["activity_cc"], "Claude Code card: the pending moment is a Summarize Now target despite code's line")
        check(FocusAppCard.offersSummarizeNow(column, targets: targets.count, running: false), "Claude Code card: Summarize Now shows while pending")
        check(FocusAppCard.offersSummarizeNow(column, targets: targets.count, running: true), "Claude Code card: it stays (greyed out) while working")
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

    // MARK: The sweep and the sources

    static func sweepAndSources() {
        check(SummarySweep.period == 4.5, "sweep: about 4.5 s a pass")
        check(SummarySweep.offset(phase: 0) == -2 && SummarySweep.offset(phase: 1) == 0 && SummarySweep.offset(phase: 0.5) == -1,
              "sweep: the 3-wide strip slides from left of the block to right of it (band at -0.5 → 1.5 widths)")
        check(SummarySweep.stops == [0.35, 0.5, 0.65], "sweep: summary-v2's 35/50/65 band")
        let card = source("Sources/MemoryUI/FocusListExpanded.swift")
        check(card.components(separatedBy: ".modifier(QuoteSweep(").count == 2, "sweep: applied once, to the whole quote block")
        if let quotes = card.range(of: "} else if !messages.isEmpty {"), let sweep = card.range(of: ".modifier(QuoteSweep("),
           let tap = card.range(of: ".accessibilityIdentifier(\"card-captured-messages\")") {
            let block = String(card[quotes.lowerBound..<sweep.lowerBound])
            check(sweep.lowerBound > quotes.lowerBound && sweep.lowerBound < tap.lowerBound && !block.contains("QuoteSweep") && !block.contains("SweepBand"),
                  "sweep: on the quotes VStack (after its ForEach), never on a Text")
        } else { check(false, "sweep: the quote block and its sweep are found") }
        check(card.contains("content.overlay(SweepBand().mask(content)") && card.contains("@State private var phase: Double = 0")
              && card.contains(".easeInOut(duration: SummarySweep.period).repeatForever(autoreverses: false)"),
              "sweep: one band masked to the block's glyphs, one phase, ease-in-out, looping")
        check(card.contains("QuoteSweep(active: state.sweeps && !reduceMotion)") && card.contains("state.sweeps && reduceMotion ? AnyShapeStyle(.tertiary)"),
              "Reduce Motion: no sweep, muted quotes")
        check(card.contains(".disabled(!state.summarizeEnabled)") && card.contains("working: summarizing"), "footer: Summarize Now and Copy Summary grey out while working")
        check(card.contains(".transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 3)))") && card.contains(".animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: state)"),
              "done: the bullets fade in")
        check(card.contains("let header = state.label(column.header)") && card.contains("CardSummaryState.violet(header)"), "the label follows the state")
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
