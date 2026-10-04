// DD-RECIPE: APP
// Threads (Preview 4) in the app, offscreen: the preview sample on the real launch path (as preview-app-checks), then
// the multitasking sample day (headline "Q3 investor update") on the Today page, rendered to PNGs in
// DD_CHECK_OUT/threads-shots: the day card with its side-thread bullets, and the block headers with their side-thread
// lines. Checks the page shows the thread names (not window titles). Never launches the app, never orders a window on
// screen, never requests a permission, never touches Application Support or the Keychain.
import AppKit
import SwiftUI
import MemoryCore
import MemoryUI

func fail(_ message: String) -> Never {
    fflush(stdout)
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}
@MainActor func expect(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { fail(message()) } else { print("PASS: \(message())"); fflush(stdout) } }
@MainActor func pump(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
@MainActor @discardableResult func wait(_ timeout: Double, _ done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { pump(0.05) }
    return done()
}

@main struct ThreadsRender {
    @MainActor static func main() throws {
        guard let out = ProcessInfo.processInfo.environment["DD_CHECK_OUT"], !out.isEmpty else { fail("DD_CHECK_OUT is required") }
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil else { fail("CFFIXED_USER_HOME must point at a scratch folder") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { fail("timed out") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let session = DaydreamLaunchSession(arguments: ["DayDream", "--preview-sample", "--preview-reseed"])
        wait(240) { !session.preparing }
        guard let model = session.model else { fail("preview model missing: \(session.failure ?? "no failure")") }
        let memoryHome = ProcessInfo.processInfo.environment["MAC_MEM_HOME"] ?? ""
        expect(memoryHome.contains("DayDream Preview Sample") && !memoryHome.contains("Application Support"), "the sample is the preview folder in the temporary folder")
        let browser = model.activity
        let zone = browser.calendar.timeZone.identifier
        let reader = try MemoryStore(home: URL(fileURLWithPath: memoryHome))
        let reportURL = URL(fileURLWithPath: memoryHome).deletingLastPathComponent().appendingPathComponent("seed-report.json")
        guard let report = try? JSONDecoder().decode(PreviewSample.Report.self, from: Data(contentsOf: reportURL)) else { fail("no seed report") }
        // The multitasking day: today, or yesterday when the sample was seeded just after midnight.
        guard let day = try report.days.reversed().first(where: { try reader.dayLevels(day: $0, timezone: zone).day?.title == "Q3 investor update" }) else {
            fail("the multitasking day has no \"Q3 investor update\" day note")
        }
        let today = try DayScope.key(Date(), timezone: zone)
        browser.focusedDay = day == today ? nil : day
        var snap: TodaySnapshot?
        Task { @MainActor in
            if let d = try? await browser.dayCache.day(day) { snap = TodaySnapshot.make(day: d, summaries: browser.summaries, calendar: browser.calendar, now: Date()) }
        }
        wait(30) { snap?.levels != nil }
        guard let levels = snap?.levels else { fail("the day never loaded") }
        print("THREADS day \(day): \(levels.dayTitle ?? "-")")
        for b in levels.dayBullets { print("THREADS   • \(b.text)  [\(b.moments.count) moments]") }
        for b in levels.blocks { print("THREADS block \(b.name) | \(FocusListLayout.sideThreadsLine(b))") }
        expect(levels.dayTitle == "Q3 investor update", "the day card's headline is the main thread")
        expect(levels.headlineDuration?.hasPrefix("~2 hr") == true && !levels.dayBullets.contains { $0.text.hasPrefix("Q3 investor update") },
               "the headline carries the main thread's time and is not a bullet too")
        // Code notes merge the texts ("Texts with Maya and Sam"); a model's intent lines give each person their own bullet.
        let texted = levels.dayBullets.filter { !$0.moments.isEmpty }.map(\.text)
        expect(texted.contains { $0.hasPrefix("Texts with Maya and Sam") }
               || (texted.contains { $0.hasPrefix("Texted Maya") } && texted.contains { $0.hasPrefix("Texted Sam") }),
               "a bullet names the people texted, with its moments")
        expect(levels.blocks.contains { $0.sideThreads.contains { $0.hasPrefix("Texts with") } }, "a block header carries its side threads")
        let all = [levels.dayTitle ?? ""] + levels.dayLines + levels.blocks.flatMap { [$0.name] + $0.sideThreads }
        expect(!all.contains { $0.contains("@") || $0.range(of: "\\(\\d+\\)", options: .regularExpression) != nil }, "no window-title noise on the page")

        let shots = URL(fileURLWithPath: out).appendingPathComponent("threads-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AnyView(MemoryWindow(model: model, chrome: .inline)))
        window.contentView = host
        func scrolls(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
        func render(_ name: String, width: CGFloat, height: CGFloat, dark: Bool = false, scrollTo y: CGFloat? = 0, settle: Double = 1.5) throws {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: width, height: height)); host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            pump(settle); host.layoutSubtreeIfNeeded(); pump(0.2)
            if let y, let scroll = scrolls(host).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) {
                let top = (scroll.documentView?.isFlipped ?? true) ? y : max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height - y)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: top)); scroll.reflectScrolledClipView(scroll.contentView); pump(0.4)
            }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fail("no bitmap for \(name)") }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = shots.appendingPathComponent(name + ".png")
            try rep.representation(using: .png, properties: [:])!.write(to: url)
            expect((try? Data(contentsOf: url).count) ?? 0 > 20_000, "rendered \(name).png")
        }
        try render("threads-day-card", width: 1180, height: 820, settle: 2.5)
        try render("threads-day-card-dark", width: 1180, height: 820, dark: true)
        try render("threads-blocks", width: 1180, height: 1500, scrollTo: 330)
        try render("threads-blocks-lower", width: 1180, height: 1500, scrollTo: 1700)
        try render("threads-narrow", width: 720, height: 1100)

        // Click-to-reference: before, after a line (the texts bullet), after a span (the Xcode span: its thread, the PR).
        let state = MomentReferenceState()
        guard let texts = levels.dayBullets.firstIndex(where: { $0.text.hasPrefix("Texts with Maya and Sam") || $0.text.hasPrefix("Texted Sam") }),
              let bullet = MomentReference.bullet(texts, day: day, levels: levels) else { fail("no texts bullet reference") }
        let textIDs = Set(snap!.moments.filter { $0.title.contains("in Messages") || $0.apps.contains("Messages") }.map(\.id))
        expect(!bullet.moments.isEmpty && Set(bullet.moments).isSubset(of: textIDs), "the texts line lights only Messages moments (membership, \(bullet.moments.count))")
        let order = snap!.moments.map(\.id)
        expect(bullet.resolved(in: levels, order: order).first == order.first { bullet.moments.contains($0) }, "the first lit moment is the day's first of them")
        guard let xcode = snap!.moments.first(where: { $0.title.contains("WeeklySummaryExport") }) else { fail("no Xcode moment") }
        let span = MomentReference.span(xcode.id, day: day, levels: levels)
        let pr = levels.blocks.first { $0.name.hasPrefix("PR #418") || $0.name.hasPrefix("GitHub PR #418") }
        expect(pr != nil && Set(span.moments) == Set(pr!.mainMoments) && span.moments.contains(xcode.id), "a span lights its thread (the PR block's main thread)")
        expect(MomentReference.headline(day: day, levels: levels)?.moments == levels.headlineMoments && !levels.headlineMoments.isEmpty, "the headline lights the main thread")
        // Clearing rules.
        let set1 = state.click(bullet, current: nil)
        expect(set1 == bullet && state.click(bullet, current: set1) == nil, "clicking the same line again clears it")
        let cleared = state.cleared(set1, byMouseDown: true)
        expect(cleared == nil && state.click(bullet, current: cleared) == nil, "a click on the lit line clears it (mouse-down clears, mouse-up doesn't set it again)")
        expect(state.cleared(set1, byMouseDown: false) == nil && state.click(span, current: nil) == span, "a scroll or Esc clears; another line sets")
        try render("reference-before", width: 1180, height: 1100)
        browser.reference = state.click(bullet, current: nil); pump(0.6)
        try render("reference-bullet", width: 1180, height: 1100, scrollTo: nil, settle: 1.0)
        try render("reference-bullet-card", width: 1180, height: 820)
        browser.reference = state.click(span, current: browser.reference); pump(0.6)
        try render("reference-span", width: 1180, height: 1100, scrollTo: nil, settle: 1.0)
        browser.focusedDay = report.days.first; pump(0.5)
        expect(browser.reference == nil, "another day drops the highlight")
        print("Threads renders use the preview sample only. Nothing records; no window was shown.")
    }
}
