// DD-RECIPE: APP
// "DayDream Preview" (`--preview-sample`) on the real launch path and MemoryViewModel:
//   A. the launch session makes the sample in the temporary folder, points MAC_MEM_HOME there and opens the
//      Development Trial's isolated model: no Coordinator, nothing records, no permission actions, no setup;
//   B. Start does nothing, the recording state is Off with the preview line, and the Focus List shows that line;
//   C. the day read carries the levels (day note, blocks, week) and Recall finds notes at every level;
//   D. sources: the preview files call no permission request, capture or Keychain API;
//   E. offscreen PNGs of Today, a past day, Search (Recent, results, a note) and Settings › Backup and restore
//      (DD_CHECK_OUT/preview-shots), no window ordered on screen;
//   F. Search has three ways out: Esc, a click on the dimmed day, and its ✕.
// Never launches the app, never requests a permission, never touches Application Support or the Keychain.
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

@main struct PreviewAppChecks {
    @MainActor static func main() throws {
        guard let out = ProcessInfo.processInfo.environment["DD_CHECK_OUT"], !out.isEmpty else { fail("DD_CHECK_OUT is required") }
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // The checks' HOME is a scratch folder (runner): nothing here may reach a real Application Support.
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil else { fail("CFFIXED_USER_HOME must point at a scratch folder") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { fail("timed out") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        // A. Requested by the argument, the environment or the preview bundle's Info.plist key; nothing else.
        expect(PreviewLaunch.requested(arguments: ["DayDream", "--preview-sample"], environment: [:], infoValue: nil), "the argument asks for the preview")
        expect(PreviewLaunch.requested(arguments: ["DayDream"], environment: ["DAYDREAM_PREVIEW_SAMPLE": "1"], infoValue: nil), "the environment asks for the preview")
        expect(PreviewLaunch.requested(arguments: ["DayDream"], environment: [:], infoValue: true), "the preview bundle's Info.plist key asks for the preview")
        expect(!PreviewLaunch.requested(arguments: ["DayDream"], environment: [:], infoValue: nil), "a plain launch is not the preview")
        expect(ProcessInfo.processInfo.environment["MAC_MEM_HOME"] == nil, "MAC_MEM_HOME is unset before the preview launch")

        let started = Date()
        let session = DaydreamLaunchSession(arguments: ["DayDream", "--preview-sample"])
        expect(session.preview && session.development, "the preview launch is the isolated development model")
        expect(session.model == nil && session.preparing, "the preview seeds off the main thread while the window says Getting ready")
        // While it gets ready, MAC_MEM_HOME already points at the preview folder (set on the main thread, before seeding),
        // and Report a Problem… (no model yet) reads no history at all: its email says unknown.
        let earlyHome = ProcessInfo.processInfo.environment["MAC_MEM_HOME"] ?? ""
        expect(earlyHome == PreviewLaunch.memory().path, "MAC_MEM_HOME points at the preview folder before seeding finishes (\(earlyHome))")
        expect(MemPaths.home().standardizedFileURL.path == PreviewLaunch.memory().standardizedFileURL.path, "MemPaths.home() is the preview folder while getting ready")
        let earlyReport = ReportProblemMail.facts(app: nil)
        expect(earlyReport.recording == .unknown && earlyReport.connectedApps.isEmpty && earlyReport.momentsToday == nil && earlyReport.summariesWaiting == nil,
               "Report a Problem reads no history in the preview before its model exists")
        let earlySource = try String(contentsOfFile: "Sources/MacMemApp/DaydreamLaunchSession.swift", encoding: .utf8)
        if let point = earlySource.range(of: "PreviewLaunch.pointHome("), let queue = earlySource.range(of: "Self.preparationQueue.async { [weak self] in\n                let trial") {
            expect(point.lowerBound < queue.lowerBound, "the preview launch points MAC_MEM_HOME before it dispatches the seed")
        } else { fail("preview launch branch: pointHome or the seed dispatch not found") }
        wait(240) { !session.preparing }
        print("preview launch ready in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        guard let model = session.model else { fail("preview model missing: \(session.failure ?? "no failure")") }
        let memoryHome = ProcessInfo.processInfo.environment["MAC_MEM_HOME"] ?? ""
        let resolvedHome = URL(fileURLWithPath: memoryHome).standardizedFileURL.resolvingSymlinksInPath().path
        expect(resolvedHome.hasPrefix(temp.path + "/") && memoryHome.contains("DayDream Preview Sample"), "MAC_MEM_HOME is the preview folder in the temporary folder (\(memoryHome))")
        expect(MemPaths.home().standardizedFileURL.path == URL(fileURLWithPath: memoryHome).standardizedFileURL.path, "MemPaths.home() is the preview folder")
        expect(!memoryHome.contains("Application Support") && !memoryHome.hasPrefix(home + "/Library"), "the preview history is not in Library or Application Support")
        expect(!memoryHome.hasPrefix("/private/tmp/daydream-") && !memoryHome.hasPrefix("/tmp/daydream-"), "the preview history is not /private/tmp/daydream-*")
        expect(model.development?.preview == true, "the model is the preview's development model")
        expect(model.coordinator == nil, "the preview model has no Coordinator (nothing can record)")
        expect(model.permissionRequests == nil, "the preview model offers no permission request")
        expect(!model.openAtLoginAvailable, "the preview never registers a login item")
        expect(!model.recording, "the preview is not recording")

        // B. Start does nothing; the state says Off with the preview line everywhere it shows.
        model.requestStart(openSetup: { fail("the preview opened setup") })
        pump(0.3)
        expect(!model.recording && model.coordinator == nil, "Start does nothing in the preview")
        let state = model.recordingState
        if case .off(_, let reason) = state { expect(reason == PreviewSample.line, "the recording state is Off with the preview line") }
        else { fail("the preview's recording state is \(state), not Off") }
        expect(RecordingCopy.previewSample == PreviewSample.line, "the UI's preview line is the core's")
        expect(model.activity.previewLine == PreviewSample.line, "the Focus List shows the preview line")

        // C. The day read carries the levels; Recall finds notes at every level.
        let browser = model.activity
        let reportURL = URL(fileURLWithPath: memoryHome).deletingLastPathComponent().appendingPathComponent("seed-report.json")
        guard let report = try? JSONDecoder().decode(PreviewSample.Report.self, from: Data(contentsOf: reportURL)) else { fail("no seed report") }
        print("seed: \(report.ingested) rows, \(report.refused) refused, \(report.moments) moments (\(report.modelNotes) model notes, \(report.codeNotes) code notes), levels \(report.levels.sorted { $0.key < $1.key }), fitted today \(report.fittedToday), moved back a day \(report.movedBackADay)")
        let reader = try MemoryStore(home: URL(fileURLWithPath: memoryHome))
        let lastDay = report.days.last ?? ""
        let todayKeyNow = try DayScope.key(Date(), timezone: browser.calendar.timeZone.identifier)
        // Threads/Preview 4 seeding: before about 6:45 AM the week moves back a day (never squeezed), so the sample ends
        // yesterday and Today is empty; otherwise it ends today.
        expect(report.movedBackADay ? lastDay != todayKeyNow : lastDay == todayKeyNow, "the sample's last day (\(lastDay)) is today, or yesterday when it moved back a day")
        let lastLevels = try reader.dayLevels(day: lastDay, timezone: browser.calendar.timeZone.identifier)
        expect(lastLevels.day != nil && !lastLevels.blocks.isEmpty, "the sample's last day (\(lastDay)) has its day note and blocks")
        // Moved back a day: the sample ends yesterday (its last day); the row checks read it.
        let busiestDay = lastDay
        if report.movedBackADay { print("LIMIT: seeded before about 6:45 AM, so the sample ends yesterday (\(busiestDay)) and Today is empty"); browser.focusedDay = lastDay }
        var pastSnap: TodaySnapshot?
        if report.movedBackADay {
            Task { @MainActor in
                if let day = try? await browser.dayCache.day(busiestDay) {
                    pastSnap = TodaySnapshot.make(day: day, summaries: browser.summaries, calendar: browser.calendar, now: Date())
                }
            }
            wait(30) { pastSnap != nil }
        } else {
            wait(30) { browser.today.snapshot?.levels != nil }
        }
        guard let snap = report.movedBackADay ? pastSnap : browser.today.snapshot else { fail("the day never loaded") }
        expect(snap.levels?.dayTitle?.isEmpty == false, "today's day note is the summary card's headline")
        expect((snap.levels?.blocks.count ?? 0) >= 3, "today's blocks are read")
        let sections = FocusListLayout.sections(snap.moments, blocks: snap.levels?.blocks ?? [], calendar: browser.calendar)
        expect(sections.contains { $0.block != nil }, "blocks head the Focus List sections")
        let ready = snap.moments.filter { $0.summary.isReady && !$0.bullets.isEmpty }
        expect(!ready.isEmpty && ready.allSatisfy { MomentSubtitle.text(for: $0) == LevelWords.intentLine($0.bullets).map(MenuBarMenu.sentence) }, "every summarized row's second line is its intent line")
        expect(ready.contains { m in ["Asked ", "Emailed ", "Texted ", "Messaged "].contains { (LevelWords.intentLine(m.bullets) ?? "").hasPrefix($0) } }, "sent and asked lines lead rows" + (ready.isEmpty ? "" : " (rows: \(ready.compactMap { LevelWords.intentLine($0.bullets) }.prefix(8)))"))

        // E. Offscreen renders (no window is ordered on screen).
        let shots = URL(fileURLWithPath: out).appendingPathComponent("preview-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AnyView(MemoryWindow(model: model, chrome: .inline)))
        window.contentView = host
        func render(_ name: String, settle: Double = 1.0) throws {
            window.setContentSize(NSSize(width: 1180, height: 800)); host.frame = NSRect(x: 0, y: 0, width: 1180, height: 800)
            pump(settle); host.layoutSubtreeIfNeeded(); pump(0.2)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fail("no bitmap for \(name)") }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = shots.appendingPathComponent(name + ".png")
            try rep.representation(using: .png, properties: [:])!.write(to: url)
            expect((try? Data(contentsOf: url).count) ?? 0 > 20_000, "rendered \(name).png")
        }
        if !report.movedBackADay {
            wait(30) { browser.today.snapshot?.moments.isEmpty == false }
            expect(browser.today.snapshot?.moments.isEmpty == false, "Today shows sample moments (\(browser.today.snapshot?.moments.count ?? 0))")
        }
        try render("today", settle: 2.0)
        // A past day (three days back): its week line sits above its day note.
        var cal = browser.calendar
        cal.timeZone = browser.calendar.timeZone
        let pastDate = cal.date(byAdding: .day, value: -3, to: Date())!
        let pastKey = try DayScope.key(pastDate, timezone: cal.timeZone.identifier)
        browser.focusedDay = pastKey
        try render("past-day", settle: 2.5)
        // The busiest day's card: the ribbon fits the day's hours; an open moment lights its span (the others dim).
        browser.focusedDay = busiestDay == todayKeyNow ? nil : busiestDay
        try render("busiest-day", settle: 2.5)
        browser.focusedDay = nil
        // The day card alone with one moment lit (as when its row is hovered or open): its span stands out on the ribbon.
        if let lit = snap.moments.first(where: { $0.title.lowercased().contains("pricing") }) ?? snap.moments.first {
            let card = FocusListSummaryCard(snapshot: snap, day: .yesterday, dayNote: .unknown, isToday: false, state: nil, narrow: false,
                                            calendar: browser.calendar, linked: lit.id, sample: true)
            host.rootView = AnyView(card.frame(width: 900).padding(24).background(Color(nsColor: .windowBackgroundColor)))
            window.setContentSize(NSSize(width: 948, height: 330)); host.frame = NSRect(x: 0, y: 0, width: 948, height: 330)
            pump(1.0); host.layoutSubtreeIfNeeded(); pump(0.2)
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: shots.appendingPathComponent("day-card-linked.png"))
            }
            print("day card lit moment: \(lit.title)")
            host.rootView = AnyView(MemoryWindow(model: model, chrome: .inline))
        }

        // Search with nothing typed: Recent lists today's last sample moments (it said "Recent moments from today
        // appear here." in Preview 2 just after midnight).
        browser.query = ""
        browser.recallPresented = true
        let recall = browser.recallModel
        if !report.movedBackADay {
            wait(20) { !recall.displayRows.isEmpty }
            expect(recall.showsRecents && !recall.displayRows.isEmpty, "Search's Recent shows today's sample moments (\(recall.displayRows.count))")
        }
        try render("search-recent", settle: 1.5)
        // F. Three ways out: Esc with nothing typed, a click on the dimmed day (its tap runs close()), and the ✕.
        recall.cancel(); pump(0.3)
        expect(!browser.recallVisible, "Esc closes Search when nothing is typed")
        browser.recallPresented = true; browser.query = "pricing"; pump(0.3)
        recall.cancel(); pump(0.2)
        expect(browser.recallPresented && browser.query.isEmpty, "Esc with a query clears it first")
        recall.cancel(); pump(0.2)
        expect(!browser.recallVisible, "a second Esc closes Search")
        let panelSource = (try? String(contentsOfFile: "Sources/MemoryUI/RecallPanel.swift", encoding: .utf8)) ?? ""
        let hostSource = (try? String(contentsOfFile: "Sources/MemoryUI/RecallHost.swift", encoding: .utf8)) ?? ""
        expect(panelSource.contains("Button { model.close() } label: {\n            Image(systemName: \"xmark\")") && panelSource.contains("if detail == nil { closeButton.padding(.trailing, 12) }"),
               "the header's ✕ closes Search in one click")
        expect(hostSource.contains(".onTapGesture { model.close() }"), "a click on the dimmed day closes Search")
        // Search: a word found in notes. Search is flat (owner, 9/30): every row is one moment or one hit, never a block,
        // day or week note and never a timeline session; no typing or Chrome cues.
        browser.recallPresented = true
        var word = ""
        for q in ["pricing", "export", "tallybird", "email", "beta"] {
            browser.query = ""; pump(0.3)
            browser.query = q
            wait(20) { !recall.noteHits.isEmpty && !recall.sections.isEmpty && !recall.busy }
            print("search note levels for \"\(q)\": \(Set(recall.noteHits.map(\.level)).sorted()) in \(recall.sections.count) sections")
            word = q
            if !recall.noteHits.isEmpty { break }
        }
        expect(recall.noteHits.allSatisfy { RecallModel.momentNoteLevels.contains($0.level) },
               "search keeps only a moment's lines and notes (\"\(word)\")")
        expect(!recall.displayRows.isEmpty && recall.displayRows.allSatisfy { $0.moment != nil || $0.kind == .action },
               "every search row is one moment or one hit")
        expect(recall.sections.first?.best == true || !recall.displayRows.contains { $0.note != nil }, "Recall shows a Best match")
        try render("search", settle: 2.0)
        // A moment row: its preview is the title, the time and the note's lines (no "Summary" label, no Cloud chip),
        // then Show in Context.
        if let row = recall.displayRows.first(where: { $0.moment != nil }) {
            recall.select(row.id)
            try render("search-moment-preview", settle: 1.0)
        }
        // A word that is in titles: only the title's match is marked (search-highlight.png).
        browser.query = ""; pump(0.3); browser.query = "investor"
        wait(20) { !recall.sections.isEmpty && !recall.busy }
        try render("search-highlight", settle: 1.5)
        browser.query = ""; pump(0.3); browser.query = word
        wait(20) { !recall.sections.isEmpty && !recall.busy }
        // Show in Context on a moment from another day: that day opens with the moment selected and open.
        let todayKey = try DayScope.key(Date(), timezone: browser.calendar.timeZone.identifier)
        if let row = recall.displayRows.first(where: { $0.moment != nil && $0.dayKey != todayKey }) {
            recall.select(row.id)
            try render("search-context-preview", settle: 1.0)
            expect(!recall.menuItems.contains { $0.id == .findRelated }, "a search moment offers no Find Related Moments")
            recall.showInDay()
            pump(0.5)
            expect(browser.focusedDay == row.dayKey && browser.selectedMomentID == row.id && browser.expandedMomentID == row.id,
                   "Show in Context opens \(row.dayKey) with the moment selected")
        }
        browser.query = ""; browser.recallPresented = false; browser.focusedDay = nil

        // The jump-to-date popover's calendar: one click per day, dots on days with moments, no days after today.
        let recordedDays = Set(report.days)
        let cal2 = browser.calendar
        let jump = AnyView(JumpCalendar(focused: todayKey, now: Date(), calendar: cal2, recorded: recordedDays, onPick: { _ in })
            .daydreamNoInitialFocusRing().background(Color(nsColor: .windowBackgroundColor)))
        // Settings › Backup and restore: grouped rows, and a sheet only as tall as they are (owner, Preview 2).
        func shoot(_ name: String, _ view: AnyView, width: CGFloat, dark: Bool = false) throws -> NSSize {
            host.rootView = AnyView(view.environment(\.colorScheme, dark ? .dark : .light))
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            pump(0.3)
            let fit = host.fittingSize
            let size = NSSize(width: width, height: max(80, ceil(fit.height)))
            window.setContentSize(size); host.frame = NSRect(origin: .zero, size: size)
            pump(0.5); host.layoutSubtreeIfNeeded(); pump(0.2)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fail("no bitmap for \(name)") }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: shots.appendingPathComponent(name + ".png"))
            return size
        }
        let backupHome = FileManager.default.temporaryDirectory.appendingPathComponent("preview-backup-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: backupHome, withIntermediateDirectories: true)
        // A stand-in helper path that exists, so the buttons draw as they do in the app (nothing is run: no button is pressed).
        let backups = BackupSettingsModel(home: backupHome, helper: URL(fileURLWithPath: "/usr/bin/true"))
        func backupSheet(_ m: BackupSettingsModel) -> AnyView {
            AnyView(DaydreamSettingsFrame(title: DaydreamSettingsPage.backup.title, back: {}, close: {}) { BackupSettingsView(model: m) }
                .frame(width: DaydreamSettingsLayout.width).fixedSize(horizontal: false, vertical: true)
                .font(.system(size: 14)).buttonStyle(ReferenceButtonStyle()))
        }
        _ = try shoot("jump-calendar", jump, width: 262)
        let backupSize = try shoot("backup", backupSheet(backups), width: DaydreamSettingsLayout.width)
        _ = try shoot("backup-dark", backupSheet(backups), width: DaydreamSettingsLayout.width, dark: true)
        backups.busy = true
        _ = try shoot("backup-busy", backupSheet(backups), width: DaydreamSettingsLayout.width)
        backups.busy = false; backups.status = "Backup saved."
        _ = try shoot("backup-saved", backupSheet(backups), width: DaydreamSettingsLayout.width)
        print("backup sheet: \(Int(backupSize.width))×\(Int(backupSize.height)) (full pages: \(Int(DaydreamSettingsLayout.maxHeight)))")
        expect(backupSize.height < DaydreamSettingsLayout.minHeight, "Backup and restore fits its rows (\(Int(backupSize.height)) pt, not a full sheet)")
        // The app's own Settings sheet on that page: MemorySettings sizes itself to the rows too.
        model.settingsSection = "Backup"
        let appSheet = AnyView(MemorySettings(model: model, height: DaydreamSettingsLayout.maxHeight).font(.system(size: 14)).buttonStyle(ReferenceButtonStyle()))
        let appSize = try shoot("backup-app-sheet", appSheet, width: DaydreamSettingsLayout.width)
        expect(appSize.height < DaydreamSettingsLayout.minHeight, "the app's Settings sheet on Backup and restore is \(Int(appSize.height)) pt tall")
        model.settingsSection = "General"
        try? FileManager.default.removeItem(at: backupHome)
        host.rootView = AnyView(MemoryWindow(model: model, chrome: .inline)); window.appearance = NSAppearance(named: .aqua)

        // Setup to click through (opt-out, owner 9/27): both switches on with their one line; nothing saves or asks.
        let setup = DaydreamOnboarding(model: model)
        host.rootView = AnyView(setup.frame(width: 660, height: 600))
        window.setContentSize(NSSize(width: 660, height: 600)); host.frame = NSRect(x: 0, y: 0, width: 660, height: 600)
        pump(1.0)
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: shots.appendingPathComponent("setup-first-page.png"))
        }
        var typedOn = true, pagesOn = true
        let appsPage = DaydreamAppsContent(apps: [], excluded: [], query: .constant(""), chromePages: Binding(get: { pagesOn }, set: { pagesOn = $0 }),
                                           typedText: Binding(get: { typedOn }, set: { typedOn = $0 }), loaded: true, enabled: true, toggle: { _ in })
        host.rootView = AnyView(appsPage.padding(28).frame(width: 660, height: 600, alignment: .top).background(Color.white))
        pump(0.8)
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: shots.appendingPathComponent("setup-switches.png"))
        }
        expect(DaydreamOnboardingTyping.initialSwitch(savedConsent: false, explicitlyOff: false)
               && DaydreamOnboardingChromePages.initialSwitch(saved: false, explicitlyOff: false, available: true), "a first setup shows Typing and Web pages in Chrome on")
        let onboardingSource = (try? String(contentsOfFile: "Sources/MacMemApp/DaydreamOnboarding.swift", encoding: .utf8)) ?? ""
        expect(onboardingSource.contains("if preview {\n            // Click-through only: no download, no save, no permission, no recording."),
               "preview setup only moves between pages: no save, download, permission or recording")
        let commands = (try? String(contentsOfFile: "Sources/MacMemApp/AppCommands.swift", encoding: .utf8)) ?? ""
        expect(commands.contains("model?.development?.preview != true"), "File › Set Up DayDream… opens setup in the preview")
        expect(!model.recording && model.coordinator == nil, "still nothing records after setup was shown")
        window.contentView = nil

        // Level notes the level writer commits drop the cached days they show on (a past day's page is final otherwise).
        do {
            let saved = model.dayData
            var dropped: [String] = [], droppedAll = 0, todayRefreshes = 0
            model.dayData.invalidate = { dropped.append($0) }
            model.dayData.invalidateAll = { droppedAll += 1 }
            model.dayData.refreshToday = { _ in todayRefreshes += 1 }
            let zone = browser.calendar.timeZone.identifier
            let notes = try reader.allLevelNotes().filter { $0.timezone == zone }
            if let block = notes.first(where: { $0.level == .block }), let week = notes.first(where: { $0.level == .week }) {
                model.levelCommitted(block)
                expect(dropped == [block.period] && droppedAll == 0 && todayRefreshes == 1, "a committed block note drops its day (\(block.period))")
                dropped = []; todayRefreshes = 0
                model.levelCommitted(week)
                let days = MemoryStore.days(week: week.period, timezone: zone)
                expect(days.count == 7 && dropped == days && droppedAll == 0 && todayRefreshes == 1, "a committed week note drops its seven days (\(week.period))")
            } else { fail("the sample has no block or week note") }
            model.dayData = saved
            let writerSource = try String(contentsOfFile: "Sources/MacMemApp/WriterIntegration.swift", encoding: .utf8)
            expect(writerSource.contains("guard let step=try? await levelRunner.step(levels,timezone:zone,now:now,codeOnly:codeOnly,momentWillBeWritten:willBeWritten) else {break}")
                   && writerSource.contains("} else {counters.codeLevels+=1}\n                    onLevelCommitted?(step.note)\n                }"),
                   "the writer reports each committed level note")
            let appSource = try String(contentsOfFile: "Sources/MacMemApp/MacMemApp.swift", encoding: .utf8)
            expect(appSource.contains("noteWriter.onLevelCommitted={ [weak self] note in self?.levelCommitted(note) }"), "the app hears every committed level note")
        }

        // D. Sources: the preview code asks for nothing and starts nothing.
        let files = ["Sources/MemoryCore/PreviewSample.swift", "Sources/MacMemApp/PreviewLaunch.swift", "Sources/MemoryUI/LevelSlices.swift", "Sources/MemoryCore/LevelDayView.swift"]
        let banned = ["AXIsProcessTrustedWithOptions", "CGRequestListenEventAccess", "CGRequestPostEventAccess", "askForChromeAccess", "allowChromeAccess",
                      "requestAuthorization", "SMAppService", "SecItem", "KeychainTypedKeyStore", "CaptureSession(", "Coordinator(", "startCapture", "NSWorkspace"]
        for f in files {
            guard let text = try? String(contentsOfFile: f, encoding: .utf8) else { fail("missing source \(f)") }
            for word in banned where text.contains(word) { fail("\(f) mentions \(word)") }
        }
        expect(true, "the preview sources call no permission request, capture, login item or Keychain API")
        let launch = (try? String(contentsOfFile: "Sources/MacMemApp/DaydreamLaunchSession.swift", encoding: .utf8)) ?? ""
        guard let p = launch.range(of: "if preview {"), let d = launch.range(of: "if development {") else { fail("launch branches not found") }
        expect(p.lowerBound < d.lowerBound, "the preview branch comes before the development and normal launch branches")
        print("Preview app checks: offscreen only. No app launched, no permission requested, nothing recorded.")
        exit(0)
    }
}
