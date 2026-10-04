// The README pictures (docs/images/readme): the app's own SwiftUI views, wired the way the app wires them, over a
// made-up day (Seed.swift). Nothing here reads your history, your Keychain or the network: the store is a new folder
// in a temporary place, and typed words use an in-memory key. Run it with scripts/readme-pictures/render.sh.
//
// `readme-render <output folder> <picture> [light|dark]` writes <picture>-<light|dark>.png. One picture per run, so no
// window state carries from one picture to the next.
import AppKit
import SwiftUI
@testable import MemoryCore
@testable import MemoryUI

/// Answers "active": the detail opens typed words only while the app is active (rendering only; this process never
/// activates or takes focus).
final class RenderApp: NSApplication { override var isActive: Bool { true } }

final class KeyLookingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// The pictures, each in light and dark. The docs checks hold docs/images/readme to exactly these files.
enum ReadmePictures {
    static let names = ["today", "day", "moment", "search", "recent", "ai", "settings", "setup", "menu"]
}

@MainActor enum R {
    static func pump(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    @discardableResult static func wait(_ t: Double, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(t); while !done() && Date() < end { pump(0.03) }; return done()
    }
    static var window: KeyLookingWindow!
    static var out: URL!

    static func snap(_ view: AnyView, _ name: String, size: NSSize, dark: Bool, settle: Double = 1.0) throws -> NSBitmapImageRep {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        var size = size
        if size.height == 0 {
            window.setContentSize(NSSize(width: size.width, height: 400)); host.frame = NSRect(x: 0, y: 0, width: size.width, height: 400)
            pump(settle); let fit = host.fittingSize; size = NSSize(width: size.width > 1 ? size.width : fit.width, height: fit.height)
        }
        window.setContentSize(size); host.frame = NSRect(origin: .zero, size: size)
        pump(settle); host.layoutSubtreeIfNeeded(); pump(0.3)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}

@main @MainActor enum ReadmeRender {
    static func main() throws {
        setbuf(stdout, nil)
        R.out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: R.out, withIntermediateDirectories: true)
        _ = RenderApp.shared; NSApp.setActivationPolicy(.prohibited)
        DispatchQueue.global().asyncAfter(deadline: .now() + 240) { FileHandle.standardError.write(Data("timed out\n".utf8)); exit(2) }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("readme-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try SampleDay.seed(home: home)
        let zone = SampleDay.zone, clock = SampleDay.clock
        for r in try store.reviewClauseWork(timezone: zone, now: clock, limit: 20) {
            print("CLAUSE-REQ key=\(r.key) lead=\(r.lead) name=\(r.name) colon=\(r.colon) notes=\(r.notes)")
            // What a writer model would answer for this thread (made up here), checked and saved like the writer's.
            let answers = ["code:tallybird": "the export tests, the CSV export date fix and a site build"]
            guard let raw = answers[r.key] else { continue }
            do { let text = try DayReviewClauses.validate("{\"clause\":\"\(raw)\"}", request: r); _ = try store.commitReviewClause(r, text: text, now: clock); print("CLAUSE \(r.key): \(text)") }
            catch { print("CLAUSE REFUSED \(r.key): \(error)") }
        }

        if var facts = try store.dayLevels(day: SampleDay.dayKey, timezone: zone, now: clock).review {
            facts.quotes = (try? store.ownerReviewQuotes(facts.quoteIDs, now: clock)) ?? [:]
            for t in facts.threads { print("THREAD \(t.key) kind=\(t.kind) cat=\(t.rankCategory) score=\(Int(t.score)) items=\(t.items.map { $0.lead + " " + ($0.tail ?? "") })") }
            for g in DayReview.assemble(facts) { for b in g.bullets { print("BULLET[\(g.id)] \(b.text)") } }
        }
        if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "mcp" {
            print("RECAP:\n" + (try store.assistantRecap(when: "today", timezone: zone, now: clock)))
            exit(0)
        }
        if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "facts" { exit(0) }
        func makeBrowser() -> ActivityBrowser {
        let browser = ActivityBrowser(calendar: SampleDay.cal)
        browser.now = { clock }
        browser.summaries = SummaryAvailability(provider: .local, busy: false)
        browser.loadCanonicalDay = { day, cursor in
            var read = try store.dayLayers(day: day, timezone: zone, after: cursor, limit: 200, now: clock)
            read.levels = try? store.dayLevels(day: day, timezone: zone, now: clock)
            if let ids = read.levels?.review?.quoteIDs, !ids.isEmpty { read.levels?.review?.quotes = (try? store.ownerReviewQuotes(ids, now: clock)) ?? [:] }
            return read
        }
        browser.loadDayReview = { day in
            var review = (try? store.cachedDayReview(day: day, timezone: zone)) ?? nil
            if let ids = review?.quoteIDs, !ids.isEmpty { review?.quotes = (try? store.ownerReviewQuotes(ids, now: clock)) ?? [:] }
            return review
        }
        browser.loadRecordedDays = { z in try store.recordedDays(timezone: z) }
        browser.loadMemberActions = { day, ids in try store.memberActions(day: day, timezone: zone, ids: ids) }
        browser.loadMomentPrompts = { requests in
            guard let asks = try? store.momentPromptRows(requests), !asks.isEmpty else { return [:] }
            return (try? store.ownerMomentPrompts(asks, now: clock)) ?? [:]
        }
        browser.loadMomentTyped = { ids, label in
            let rows = (try? store.momentTypedRows(ids, label: label)) ?? []
            var sends = [String: String]()
            for row in rows where row.send != nil { sends[row.id] = "Submission observed" }
            return MomentTypedLoad(sends: sends)
        }
        browser.loadComposeLines = { ids in ((try? store.composeOutcomes(ids, now: clock)) ?? [:]).mapValues(ComposeLine.init) }
        browser.loadOwnerSourcePreviews = { ids in (try? store.ownerSourceMomentPreviewsForActions(ids, now: clock)) ?? [] }
        browser.ownerSourcePreviewRevision = { d in (try? store.ownerSourcePreviewRevision(expiresAt: d, now: clock)) ?? nil }
        browser.searchCanonical = { q, c in try store.searchResult(MemorySearchQuery(q, limit: 50, after: c), now: clock) }
        browser.searchCanonicalQuery = { q in try store.searchResult(q, now: clock) }
        browser.searchOwnerTyped = { q in try store.ownerTypedSearch(q, now: clock) }
        browser.searchNotes = { q in try store.noteSearch(q, timezone: zone, now: clock) }
        browser.openApp = { _ in }
        return browser
        }

        R.window = KeyLookingWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1180, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        R.window.orderFrontRegardless()
        let state = CapturePresentation(state: .recording(since: SampleDay.at(8, 50)), canResume: true, canStop: true)
        func shell(_ b: ActivityBrowser) -> AnyView {
            AnyView(MemoryShell(browser: b, state: state, actions: CaptureActions(), toolbarLeadingInset: 72)
                .environment(\.daydreamNow, clock).environment(\.daydreamStatic, true))
        }
        let only = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
        guard ReadmePictures.names.contains(only) else { FileHandle.standardError.write(Data("unknown picture \(only)\n".utf8)); exit(1) }
        func want(_ n: String) -> Bool { only == n }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["README_ROOT"] ?? FileManager.default.currentDirectoryPath)
        func save(_ rep: NSBitmapImageRep, _ name: String, frame: Compose.Frame, dark: Bool) throws {
            let url = R.out.appendingPathComponent(name + ".png")
            try Palette.write(Compose.make(rep, frame: frame, dark: dark), to: url)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("PNG \(name).png \(bytes / 1024) KB")
        }
        func moments(_ b: ActivityBrowser) -> [MomentSlice] {
            R.wait(10) { (b.today.snapshot?.moments.count ?? 0) >= 5 }
            return b.today.snapshot?.moments ?? []
        }
        let width: CGFloat = 1000

        // Each picture in light and dark (README <picture> pairs). One shot per process run (`readme-render <out> <shot> [dark]`),
        // so no window state carries from one picture to the next.
        let dark = CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "dark"
        func file(_ name: String) -> String { name + (dark ? "-dark" : "-light") }
        func shot(_ name: String, _ make: () throws -> (NSBitmapImageRep, Compose.Frame)) throws {
            guard want(name) else { return }
            let (rep, frame) = try make()
            try save(rep, file(name), frame: frame, dark: dark)
        }
        func browserShot(_ name: String, height: CGFloat, settle: Double = 3, _ prepare: (ActivityBrowser) -> Void = { _ in }) throws {
            try shot(name) {
                let b = makeBrowser(); let v = shell(b)
                R.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                R.window.contentView = NSHostingView(rootView: v)
                _ = moments(b)
                prepare(b)
                return (try R.snap(v, file(name), size: NSSize(width: width, height: height), dark: dark, settle: settle), .window)
            }
        }
        let icon = NSImage(contentsOf: root.appendingPathComponent("packaging/Daydream.icns"))!

        // Today: the card, its notes and the day's strip.
        try browserShot("today", height: 525, settle: 2.5)
        // The day's moments, one opened.
        try browserShot("day", height: 530) { b in
            if let m = b.today.snapshot?.moments.first(where: { $0.title == "Export tests in Terminal" }) { b.selectedMomentID = m.id; b.expandedMomentID = m.id }
        }
        // A moment's details: the summary and What happened, with what was asked.
        try browserShot("moment", height: 470, settle: 5) { b in
            if let m = b.today.snapshot?.moments.first(where: { $0.primaryBundle == "com.anthropic.claudefordesktop" && $0.start < SampleDay.at(12, 0) }) {
                b.selectedCanonicalActivity = m.id
            }
        }
        // Search, with what matched on the right.
        try browserShot("search", height: 560) { b in
            b.query = "pricing"
            let model = b.recallModel
            b.recallPresented = true
            R.wait(8) { !model.busy && !model.displayRows.isEmpty }
            if let row = model.displayRows.first { model.select(row.id) }
        }
        // Search with nothing typed: the day's last moments, the one you were in last selected, with its words.
        try browserShot("recent", height: 560) { b in
            let model = b.recallModel
            b.recallPresented = true
            R.wait(8) { !model.displayRows.isEmpty }
            if let row = model.displayRows.first(where: { $0.moment?.primaryBundle == "com.apple.Pages" }) ?? model.displayRows.first { model.select(row.id) }
        }
        // The menu bar panel, under its icon.
        try shot("menu") {
            let b = makeBrowser()
            R.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            R.window.contentView = NSHostingView(rootView: shell(b))
            _ = moments(b)
            guard let today = b.today.snapshot else { print("no snapshot"); exit(1) }
            let panel = MenuBarMenu(presentation: state, actions: CaptureActions(), snapshot: today, now: clock, calendar: SampleDay.cal, openToday: {}, openSetUp: {})
                .environment(\.daydreamNow, clock).environment(\.daydreamStatic, true).environment(\.controlActiveState, .key)
            let f = DateFormatter(); f.timeZone = SampleDay.tz; f.dateFormat = "EEE MMM d  h:mm a"
            let wall = dark ? [Color(red: 0.16, green: 0.18, blue: 0.24), Color(red: 0.22, green: 0.18, blue: 0.26)]
                            : [Color(red: 0.86, green: 0.89, blue: 0.95), Color(red: 0.93, green: 0.90, blue: 0.95)]
            let scene = VStack(spacing: 0) {
                HStack(spacing: 18) {
                    Spacer()
                    Image(nsImage: DaydreamMenuBarMark.image(for: .recording)).renderingMode(.template).foregroundStyle(.primary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.12)))
                    Text(f.string(from: clock)).font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 16).frame(height: 26)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                HStack(alignment: .top) {
                    Spacer()
                    panel.frame(width: 300)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                        .padding(.trailing, 10)
                }
                .padding(.top, 6).padding(.bottom, 34)
            }
            .frame(width: 520)
            .background(LinearGradient(colors: wall, startPoint: .topLeading, endPoint: .bottomTrailing))
            R.window.makeKey()
            return (try R.snap(AnyView(scene), file("menu"), size: NSSize(width: 520, height: 0), dark: dark, settle: 1.5), .panel)
        }
        // Setup's permission cards: one button each, or drag the card into the list.
        try shot("setup") {
            let holder = FileManager.default.temporaryDirectory.appendingPathComponent("DayDream", isDirectory: true)
            try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
            _ = NSWorkspace.shared.setIcon(icon, forFile: holder.path, options: [])
            let view = DaydreamOnboardingShell(title: "Grant DayDream Permissions", appURL: holder, canContinue: false, continueAction: {}) {
                PermissionGrantView(enabled: true, appURL: holder, readAccessibility: { false }, readInputMonitoring: { false }, embedded: true)
                    .environment(\.daydreamPermissionRequests, PermissionRequestActions(quitAndReopen: {}))
            }.environment(\.daydreamStatic, true)
            let full = try R.snap(AnyView(view), file("setup"), size: NSSize(width: 660, height: 520), dark: dark, settle: 1.5)
            // The title and the two cards: the hint lines under them depend on what else is installed on the Mac.
            let keep: CGFloat = 246
            let cropped = NSBitmapImageRep(cgImage: full.cgImage!.cropping(to: CGRect(x: 0, y: 0, width: full.pixelsWide, height: Int(keep * 2)))!)
            cropped.size = NSSize(width: 660, height: keep)
            return (cropped, .window)
        }
        // Settings: where your history is kept, what runs where, and the one honest privacy line.
        try shot("settings") {
            let holder = FileManager.default.temporaryDirectory.appendingPathComponent("DayDream", isDirectory: true)
            try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
            _ = NSWorkspace.shared.setIcon(icon, forFile: holder.path, options: [])
            let rows = SettingsRowsSnapshot(permissions: PermissionSnapshot(accessibility: true, inputMonitoring: true), summaries: "On this Mac",
                                            exclusions: ExclusionSummary(alwaysPrivate: ["1Password"], excludedByYou: ["Banking"]), connections: "Claude")
            let view = DaydreamSettingsFrame(title: "Settings", appURL: holder, advanced: {}, close: {}) {
                DaydreamSettingsOverview(status: nil, rows: rows, calendar: SampleDay.cal, select: { _ in }, fileVaultOn: true)
            }
            .frame(width: 620)
            .environment(\.daydreamNow, clock).environment(\.daydreamStatic, true)
            // Settings opens as a sheet over the main window: drawn as a panel, without window buttons.
            return (try R.snap(AnyView(view), file("settings"), size: NSSize(width: 620, height: 0), dark: dark, settle: 1.5), .panel)
        }
        // An AI app answering from DayDream (MCP). The chat frame is a plain stand-in; the facts in the answer are
        // what DayDream's `recap` tool returns for this sample day.
        try shot("ai") {
            let recap = try store.assistantRecap(when: "today", timezone: zone, now: clock)
            print("RECAP " + recap)
            func bullet(_ when: String, _ text: String) -> some View {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    (Text(when) + Text(" " + text)).fixedSize(horizontal: false, vertical: true)
                }
            }
            let chat = VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 40)
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Spacer()
                        Text("What did I get done today?").padding(.horizontal, 14).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.07)))
                    }
                    HStack(spacing: 7) {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        Text("Looked in DayDream").foregroundStyle(.secondary).font(.system(size: 12.5))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Most of today went to the Tallybird pricing page.")
                        Text("Tue, Sep 29").fontWeight(.medium).padding(.top, 4)
                        bullet("Morning:", "asked Claude to tighten the pricing page intro, then wrote the draft in Pages.")
                        bullet("12:20 PM:", "texted Maya about lunch.")
                        bullet("1:30 PM:", "asked Claude for three FAQ answers, added them to the draft and built the site.")
                    }.font(.system(size: 14)).lineSpacing(2)
                    Spacer(minLength: 8)
                    HStack {
                        Text("Reply…").foregroundStyle(.tertiary)
                        Spacer()
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.14), lineWidth: 1))
                }
                .font(.system(size: 14)).padding(.horizontal, 30).padding(.bottom, 22)
            }
            .frame(width: 720, height: 400)
            .background(Color(nsColor: .textBackgroundColor))
            return (try R.snap(AnyView(chat), file("ai"), size: NSSize(width: 720, height: 400), dark: dark, settle: 0.8), .window)
        }
        exit(0)
    }
}
