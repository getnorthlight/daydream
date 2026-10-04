import SwiftUI
import AppKit
import MemoryUI
import MemoryCore
import WriterBackend

private actor SettingsFixtureKeys: WriterSecureKeyStore {
    private(set) var calls = 0
    func readSecret() async throws -> String { calls += 1; throw WriterFailure.denied }
    func saveSecret(_ value: String) async throws { calls += 1; throw WriterFailure.denied }
    func removeSecret() async throws { calls += 1; throw WriterFailure.denied }
}

/// Connections as an empty scratch Mac sees it: no AI app is found, running or opened, and nothing is copied.
private struct InertAIAppControl: AIAppControlling {
    func location(_ app: AIApp, env: AIAppConnectEnvironment) -> URL? { nil }
    @MainActor func running(_ app: AIApp) -> RunningAIApp? { nil }
    func handler(for url: URL) -> String? { nil }
    func lastChange(_ app: AIApp) -> Date? { nil }
    func recordChange(_ app: AIApp, at date: Date) {}
    @MainActor func quit(_ running: RunningAIApp, force: Bool, timeout: TimeInterval) async -> Bool { false }
    @MainActor func reopen(_ url: URL) async -> Bool { false }
    @MainActor func open(_ url: URL) -> Bool { false }
    @MainActor func copy(_ text: String) {}
    @MainActor func observe(_ changed: @escaping @MainActor () -> Void) -> [NSObjectProtocol] { [] }
    @MainActor func stopObserving(_ tokens: [NSObjectProtocol]) {}
}

/// Status-line fixtures: Tuesday 2026-09-22 4:21 PM in Los Angeles. ux/declutter: the status line is the
/// recording state, the orange issue line and, for Needs Permission, one button; today's numbers, the week
/// and the store size are gone from Settings. The later cases are the states that grow the line (an issue,
/// both or unknown missing permissions, a long issue): the rows must not move for any.
enum StatusFixture: String, CaseIterable {
    case everyday, permission, pending, writerOff = "writer-off", noData = "nodata"
    case recordingIssue = "recording-issue", offIssue = "off-issue", needsBoth = "needs-both", needsUnknown = "needs-unknown"
    case needsIssue = "needs-issue", longIssue = "long-issue"

    static let zone = TimeZone(identifier: "America/Los_Angeles")!
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c }
    static func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }
    static let now = at(22, 16, 21)
    var snapshot: SettingsStatusSnapshot {
        let local = SummaryAvailability(provider: .local, busy: false)
        let summaries: SummaryAvailability
        switch self {
        // fix/day-card: a download is the phase (SummaryPhase), with summaries not on yet.
        case .pending: summaries = SummaryAvailability(provider: .off, busy: true, phase: .downloading(received: 1_134_000_000, total: 2_700_000_000))
        case .writerOff: summaries = SummaryAvailability(provider: .off, busy: false)
        default: summaries = local
        }
        let state: RecordingState
        switch self {
        case .permission, .needsIssue: state = .needsPermission(missing: [.inputMonitoring])
        case .needsBoth: state = .needsPermission(missing: [.accessibility, .inputMonitoring])
        case .needsUnknown: state = .needsPermission(missing: [])
        case .noData: state = .off(since: nil, reason: nil)
        case .offIssue: state = .off(since: nil, reason: "Finish setup to start recording.")
        default: state = .recording(since: Self.at(22, 8, 40))
        }
        let issue: String?
        switch self {
        case .permission: issue = "Permissions required"
        case .recordingIssue, .offIssue, .needsIssue: issue = "Summaries could not be saved."
        case .longIssue: issue = String(repeating: "The summary writer stopped and needs attention before it can continue. ", count: 3)
        default: issue = nil
        }
        let permissions: PermissionSnapshot?
        switch self {
        case .permission, .needsIssue: permissions = PermissionSnapshot(accessibility: true, inputMonitoring: false)
        case .needsBoth: permissions = PermissionSnapshot(accessibility: false, inputMonitoring: false)
        case .needsUnknown: permissions = nil
        default: permissions = PermissionSnapshot(accessibility: true, inputMonitoring: true)
        }
        return SettingsStatusSnapshot(state: state, issue: issue, permissions: permissions, summaries: summaries,
            exclusions: ExclusionSummary(alwaysPrivate: ["com.1password.1password", "com.apple.Passwords", "com.apple.keychainaccess",
                                                         "com.bitwarden.desktop", "com.lastpass.LastPass"],
                                         excludedByYou: ["com.spotify.client", "com.apple.Music", "com.valvesoftware.steam"]),
            connections: nil)
    }
}

@MainActor @main struct SettingsHubChecks {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label)
        checks += 1
    }

    static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
    /// Every scroll view, nested ones too (the Apps page scrolls as a whole around the app list).
    static func allScrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { allScrollViews(in: $0) }
    }

    static func main() async throws {
        let legacy: [(String, DaydreamSettingsPage)] = [
            ("General", .overview), ("Permissions", .permissions), ("Memory", .summaries),
            ("Writer", .summaries), ("Recording", .apps), ("Connections", .connections),
            ("Connection", .connections), ("Privacy", .advanced), ("Updates", .updates),
            ("History", .history), ("Backup", .backup), ("Setup", .overview), ("Details", .advanced), ("Advanced", .advanced)
        ]
        for (section, expected) in legacy {
            var route = DaydreamSettingsNavigation(section: section)
            check(route.page == expected, "Existing settings deep links retain their destination")
            route.back()
            check(route.page == .overview, "Direct detail Back returns to the overview")
        }
        for page in DaydreamSettingsPage.allCases {
            var route = DaydreamSettingsNavigation()
            route.show(.advanced)
            route.show(page)
            route.show(page)
            if page != .advanced {
                route.back()
                check(route.page == .advanced, "Detail Back preserves its parent and ignores duplicate selection")
            }
            route.back()
            check(route.page == .overview, "Advanced Back returns to the overview")
        }

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: "/private/tmp/daydream-settings-hub-renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let modelRoot = output.appendingPathComponent("unused-models-" + UUID().uuidString)
        let keys = SettingsFixtureKeys()
        var networkCalls = 0
        let writer = WriterIntegration(modelRoot: modelRoot, keyStore: keys, send: { _ in
            await MainActor.run { networkCalls += 1 }
            throw WriterFailure.denied
        })
        let fixtures = [
            LocalApp(id: "com.apple.Notes", name: "Notes", path: "/System/Applications/Notes.app"),
            LocalApp(id: "com.apple.TextEdit", name: "TextEdit", path: "/System/Applications/TextEdit.app"),
            LocalApp(id: "com.apple.iCal", name: "Calendar", path: "/System/Applications/Calendar.app"),
            LocalApp(id: "com.apple.Passwords", name: "Passwords", path: "/System/Applications/Passwords.app")
        ] + (0..<8).map { LocalApp(id: "com.example.\($0)", name: "Example app \($0 + 1)") }
        let appURL = URL(fileURLWithPath: "/Users/someone/Applications/DayDream.app")
        // The sheet's largest size (720×540) and its smallest (600 wide, as a narrow window allows, by 400).
        let full = NSSize(width: DaydreamSettingsLayout.width, height: DaydreamSettingsLayout.maxHeight)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: full.width, height: full.height),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        defer { window.contentView = nil; window.orderOut(nil) }
        var renders = 0
        let screens = ["overview", "permissions", "permissions-allowed", "permissions-recovery", "summaries", "apps", "apps-empty", "apps-error", "connections", "advanced"]
            + StatusFixture.allCases.map { "overview-" + $0.rawValue }
            + ["permissions-settings", "permissions-settings-allowed", "permissions-settings-disabled", "apps-grouped", "apps-grouped-error", "apps-chrome"]
        let browsers = [LocalApp(id: "com.google.Chrome", name: "Google Chrome"), LocalApp(id: "com.apple.Safari", name: "Safari"),
                        LocalApp(id: "org.mozilla.firefox", name: "Firefox")]
        for dark in [false, true] { for size in [full, NSSize(width: 600, height: DaydreamSettingsLayout.minHeight)] {
            for screen in screens {
                var selections = 0
                var closes = 0
                var backs = 0
                var learnMoreCalls = 0
                var statusButtonCalls = 0
                var rowFrames: (viewport: CGRect, rows: [CGRect])?
                var chromeCardShown = 0, accessChecks = 0, chromeActions = 0
                let title = screen.hasPrefix("permissions") ? "Permissions" : screen.hasPrefix("apps") ? "Apps to remember" : screen.hasPrefix("connections") ? "Connections" : screen == "summaries" ? "Summaries" : screen == "advanced" ? "Advanced" : "Settings"
                let content: AnyView
                switch screen {
                case "overview": content = AnyView(DaydreamSettingsOverview(summaries: "Not set up", select: { _ in selections += 1 }))
                case _ where screen.hasPrefix("overview-"):
                    let status = StatusFixture(rawValue: String(screen.dropFirst("overview-".count)))!.snapshot
                    content = AnyView(DaydreamSettingsOverview(status: status, rows: SettingsRowsSnapshot(status), calendar: StatusFixture.calendar,
                        select: { _ in selections += 1 }, act: { _ in statusButtonCalls += 1 },
                        learnMore: { learnMoreCalls += 1 })
                        .reportingRowFrames { viewport, rows in rowFrames = (viewport, rows) }
                        .environment(\.daydreamNow, StatusFixture.now))
                case "permissions-settings", "permissions-settings-allowed", "permissions-settings-disabled":
                    // As the app shows it: the settings page scroll (room for shadows, a bottom fade).
                    content = AnyView(DaydreamSettingsScroll {
                        PermissionGrantView(enabled: screen != "permissions-settings-disabled", appURL: appURL,
                            readAccessibility: { true }, readInputMonitoring: { screen == "permissions-settings-allowed" },
                            embedded: true, style: .settings)
                    })
                case "apps-grouped", "apps-grouped-error": content = AnyView(VStack(alignment: .leading, spacing: 14) {
                    if screen == "apps-grouped-error" {
                        // As DaydreamAppSettings shows a change that didn't save: one sentence, one button.
                        ChoiceProblemLine(text: "Your app choices changed in another window, so this change didn't save.", buttonTitle: "Use saved choices") {}
                    }
                    SettingsAppsContent(apps: fixtures, excluded: ["com.apple.iCal", "com.example.2"], query: .constant(""),
                        typedText: .constant(false), loaded: true, enabled: true, toggle: { _ in selections += 1 })
                }.padding(4))
                case "apps-chrome":
                    // As DaydreamAppSettings shows it with Web pages in Chrome on: one page scroll (DaydreamSettings wraps
                    // the page in DaydreamSettingsScroll) holding the fixed-height list, then the Chrome card below it.
                    let card = ChromePagesCard(on: .constant(true), savedOn: true, access: .notAsked, sites: ["example.com"], enabled: true,
                        add: { _ in chromeActions += 1 }, remove: { _ in chromeActions += 1 }, allow: { chromeActions += 1 },
                        openSystemSettings: { chromeActions += 1 }, checkAccess: { accessChecks += 1 })
                        .onAppear { chromeCardShown += 1 }
                    content = AnyView(DaydreamSettingsScroll {
                        VStack(alignment: .leading, spacing: 14) {
                            SettingsAppsContent(apps: fixtures + browsers, excluded: ["com.apple.iCal"], query: .constant(""),
                                typedText: .constant(false), loaded: true, enabled: true, browserPages: true, chromePages: AnyView(card),
                                toggle: { _ in selections += 1 })
                        }.padding(4)
                    })
                case "permissions", "permissions-allowed", "permissions-recovery":
                    content = AnyView(ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 20) {
                            PermissionGrantView(appURL: appURL, readAccessibility: { screen == "permissions-allowed" },
                                readInputMonitoring: { screen == "permissions-allowed" }, embedded: true,
                                recoveryExpandedInitially: screen == "permissions-recovery")
                        }.padding(4)
                    })
                case "summaries": content = AnyView(WriterPreferences(writer: writer, initialMode: "On this Mac", available: true))
                case "apps", "apps-empty", "apps-error": content = AnyView(VStack(alignment: .leading, spacing: 14) {
                    if screen == "apps-error" {
                        ChoiceProblemLine(text: "Your app choices didn't save.", buttonTitle: "Save again") {}
                    }
                    DaydreamAppsContent(apps: fixtures, excluded: [], query: .constant(screen == "apps-empty" ? "No such app" : ""),
                        typedText: .constant(false), loaded: true, enabled: true, fillsAvailableHeight: true,
                        toggle: { _ in selections += 1 })
                }.padding(4))
                case "connections":
                    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("settings-hub-connections", isDirectory: true)
                    content = AnyView(ConnectionSettings(model: ConnectionSettingsModel(
                        environment: AIAppConnectEnvironment(userHome: scratch, applicationFolders: []), home: scratch.appendingPathComponent("history"),
                        pinnedHome: nil, control: InertAIAppControl())))
                default: content = AnyView(SettingsSurface("Advanced") {
                    SettingsCard {
                        ForEach(["Privacy and retention", "Import existing history", "Backup and restore", "Recording requirements", "App updates", "Diagnostics"], id: \.self) { text in
                            HStack { Text(text); Spacer(); Image(systemName: "chevron.right") }.frame(height: 30)
                        }
                    }
                })
                }
                let view = DaydreamSettingsFrame(title: title, appURL: appURL,
                    back: screen.hasPrefix("overview") ? nil : { backs += 1 },
                    advanced: screen.hasPrefix("overview") ? { selections += 1 } : nil, close: { closes += 1 }) { content }
                    .frame(width: size.width, height: size.height)
                    .environment(\.controlActiveState, .active).transaction { $0.disablesAnimations = true }
                let host = NSHostingView(rootView: view)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.setContentSize(size)
                host.frame = NSRect(origin: .zero, size: size)
                try await Task.sleep(nanoseconds: 180_000_000)
                host.layoutSubtreeIfNeeded()
                check(host.fittingSize == size, "Overview and details retain the requested window size")
                check(selections == 0 && closes == 0 && backs == 0 && !window.isVisible, "Showing settings does not activate controls or show a test window")
                check(learnMoreCalls == 0 && statusButtonCalls == 0, "Rendering the status line never opens Learn more or runs its button")
                if screen.hasPrefix("overview-") {
                    guard let frames = rowFrames else { fatalError("\(screen): the overview reported no row frames") }
                    check(frames.rows.count == 4, "The overview reports its four grouped area rows")
                    if size == full {
                        // Fully visible means above the scroll's bottom fade too.
                        let fade = DaydreamSettingsScroll<EmptyView>.fadeHeight
                        let visible = CGRect(x: frames.viewport.minX, y: frames.viewport.minY, width: frames.viewport.width,
                                             height: frames.viewport.height - fade).insetBy(dx: -0.5, dy: -0.5)
                        let clipped = frames.rows.filter { !visible.contains($0) }
                        if !clipped.isEmpty { FileHandle.standardError.write(Data("rows \(screen) \(dark ? "dark" : "light"): viewport \(frames.viewport), rows \(frames.rows)\n".utf8)) }
                        check(clipped.isEmpty, "All four grouped rows are fully visible without scrolling at 720x540")
                        check(frames.rows.allSatisfy { $0.maxY <= frames.viewport.maxY - fade + 0.5 }, "The grouped rows end above the scroll fade at 720x540")
                        // The page ends with the Connections row (no footer below it), inside the 540-high sheet.
                        check(frames.rows.count == 4 && frames.rows[3].maxY <= frames.viewport.maxY + 0.5,
                              "The Connections row ends inside the 540-high viewport at 720x540 (\(screen))")
                    }
                }
                let scrollers = scrollViews(in: host)
                if screen == "apps" || screen == "apps-error" || screen == "apps-grouped" || screen == "apps-grouped-error" {
                    check(scrollers.count == 1, "Apps has exactly one scroll view, including recovery states")
                    let scroll = scrollers[0]
                    let before = scroll.contentView.bounds.origin
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: 80))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    check(scroll.contentView.bounds.origin.y > before.y, "App list still scrolls with indicators hidden")
                    scroll.contentView.scroll(to: before)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                if screen == "apps-chrome" {
                    // Owner test (2026-09-25): the list had shrunk to about three rows because it shared the height with the
                    // card area's own scroll. Now the page scrolls as a whole and the list keeps about eight rows.
                    let every = allScrollViews(in: host)
                    check(scrollers.count == 1 && every.count == 2, "Apps with the Chrome card: one page scroll holding the app list's own scroll")
                    // The list's scroll is the one inside the page scroll (at the 400pt minimum window the page's own
                    // viewport is shorter than the list, so the shorter scroll view is not the list).
                    let list = every.first { $0 !== scrollers[0] } ?? every[0]
                    check(abs(list.frame.height - SettingsAppsContent.listHeight) < 1, "Apps with the Chrome card: the app list keeps its full height (about eight rows)")
                    let page = scrollers[0], top = page.contentView.bounds.origin
                    page.contentView.scroll(to: NSPoint(x: 0, y: 200))
                    page.reflectScrolledClipView(page.contentView)
                    check(page.contentView.bounds.origin.y > top.y, "Apps with the Chrome card: the page scrolls to the card and typing below the list")
                    page.contentView.scroll(to: top)
                    page.reflectScrolledClipView(page.contentView)
                    check(chromeCardShown > 0, "The Web pages in Chrome card is on Apps to remember")
                    check(accessChecks > 0, "The card reads Chrome access when the saved switch is on (a read, never a prompt)")
                    check(chromeActions == 0, "Showing the Chrome card never asks macOS, opens System Settings, or changes the site list")
                } else {
                    check(chromeCardShown == 0 && accessChecks == 0, "Only the Chrome screen shows the Chrome card")
                }
                let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                check(window.performKeyEquivalent(with: enter) && closes == 1, "Done dismisses from every overview and detail state")
                check(selections == 0 && backs == 0, "Done does not navigate or change settings")
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Settings did not render") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(screen)-\(Int(size.width))-\(dark ? "dark" : "light").png"))
                renders += 1
            }
        }}
        try await appsGroupedButtons(window: window)
        let keyCalls = await keys.calls
        check(keyCalls == 0 && networkCalls == 0 && !writer.busy && writer.provider == "off", "Rendering never reads keys, sends network requests, or activates summaries")
        check(!FileManager.default.fileExists(atPath: modelRoot.path), "No model setup was started")
        print("PASS: \(checks) settings navigation and dismissal checks; \(renders) hidden light/dark compact/standard renders; no production settings, recording, keys, or network actions")
    }

    static func buttons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
    }

    /// The grouped apps list's native exclusion buttons, laid out tall enough that every row exists:
    /// an always-private app and DayDream itself have none, each other app has exactly one ("Include
    /// {App} in recording"), a press toggles that app once, and a disabled list presses nothing. The
    /// list's groups agree with the overview's counts.
    static func appsGroupedButtons(window: NSWindow) async throws {
        let apps = [
            LocalApp(id: "com.apple.Notes", name: "Notes", path: "/System/Applications/Notes.app"),
            LocalApp(id: "com.apple.TextEdit", name: "TextEdit", path: "/System/Applications/TextEdit.app"),
            LocalApp(id: "com.apple.iCal", name: "Calendar", path: "/System/Applications/Calendar.app"),
            LocalApp(id: "com.apple.Passwords", name: "Passwords", path: "/System/Applications/Passwords.app"),
            LocalApp(id: "com.1password.1password", name: "1Password"),
            LocalApp(id: "com.getnorthlight.daydream", name: "DayDream"),
            LocalApp(id: "com.example.2", name: "Example app 3"),
        ]
        let excluded: Set<String> = ["com.apple.iCal", "com.example.2"]
        let groups = SettingsAppsContent.grouped(apps, excluded: excluded)
        check(!groups.flatMap(\.apps).contains { $0.id == "com.getnorthlight.daydream" }, "The apps page never lists DayDream itself")
        let summary = ExclusionSummary.make(blockedApps: Array(excluded), installed: { id in apps.contains { $0.id == id } })
        check(groups.first { $0.group == .alwaysPrivate }?.apps.count == summary.alwaysPrivate.count,
              "The apps page's always-private group matches the overview's count")
        check(groups.first { $0.group == .excludedByYou }?.apps.count == summary.excludedByYou.count,
              "The apps page's excluded group matches the overview's count")
        check(groups.map(\.group.rawValue) == ["Excluded by you", "Always private", "Included in recording"], "The apps page's groups, in order")

        // Browsers (Chrome page history): other browsers are never "Included in recording"; Google Chrome is included only
        // while Web pages in Chrome is on, and then reads "Page titles and sites".
        // Honesty track (H1): the group is "Web browsers" and each row says what really happens: Chrome reads "Off"
        // while its switch is off, every other browser "Not recorded in this version".
        check(SettingsAppsContent.AppGroup.allCases.map(\.rawValue) == ["Excluded by you", "Always private", "Web browsers", "Included in recording"],
              "The apps page has four groups, in order")
        let browserApps = apps + [LocalApp(id: "com.google.Chrome", name: "Google Chrome"), LocalApp(id: "com.apple.Safari", name: "Safari"),
                                  LocalApp(id: "org.mozilla.firefox", name: "Firefox"), LocalApp(id: "com.microsoft.edgemac", name: "Microsoft Edge"),
                                  LocalApp(id: "com.google.Chrome.beta", name: "Google Chrome Beta")]
        for pages in [false, true] {
            let g = SettingsAppsContent.grouped(browserApps, excluded: excluded, browserPages: pages)
            func ids(_ group: SettingsAppsContent.AppGroup) -> Set<String> { Set(g.first { $0.group == group }?.apps.map(\.id) ?? []) }
            check(g.map(\.group.rawValue) == ["Excluded by you", "Always private", "Web browsers", "Included in recording"],
                  "With browsers installed the apps page shows all four groups, in order")
            check(ids(.notRecorded).isSuperset(of: ["com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac"]),
                  "Browsers other than Chrome are listed as Not recorded in this version")
            check(ids(.notRecorded).contains("com.google.Chrome.beta"), "Chrome Beta is another browser: Not recorded in this version")
            check(!ids(.included).contains { CaptureSession.excludedBrowsers.contains($0) && $0 != "com.google.Chrome" },
                  "No browser other than Chrome is ever Included in recording")
            check(ids(.included).contains("com.google.Chrome") == pages && ids(.notRecorded).contains("com.google.Chrome") == !pages,
                  "Google Chrome is Included in recording only while Web pages in Chrome is on")
            check(ids(.included).isSuperset(of: ["com.apple.Notes", "com.apple.TextEdit"]), "Other apps keep their group with browsers listed")
        }
        let chromeExcluded = SettingsAppsContent.grouped(browserApps, excluded: excluded.union(["com.google.Chrome"]), browserPages: true)
        check(chromeExcluded.first { $0.group == .excludedByYou }?.apps.contains { $0.id == "com.google.Chrome" } == true,
              "An excluded Google Chrome stays Excluded by you, even with Web pages in Chrome on")
        check(SettingsAppsContent.chromeSubtitle == "Page titles and sites" && SettingsAppsContent.notRecordedLabel == "Not recorded in this version",
              "Chrome's row reads Page titles and sites; other browsers read Not recorded in this version")
        check(SettingsAppsContent.browserLabel("com.google.Chrome") == (ReleaseFeatures.chromePageHistory ? "Off" : "Not recorded in this version")
              && ["com.apple.Safari", "org.mozilla.firefox", "com.google.Chrome.beta"].allSatisfy { SettingsAppsContent.browserLabel($0) == "Not recorded in this version" },
              "A Web browsers row says what happens: Chrome is Off (its switch), other browsers are Not recorded in this version")
        check(SettingsAppsContent.subtitle("com.google.Chrome", group: .included) == (ReleaseFeatures.chromePageHistory ? "Page titles and sites" : nil)
              && SettingsAppsContent.subtitle("com.google.Chrome", group: .notRecorded)
                 == (ReleaseFeatures.chromePageHistory ? "Page titles and sites, only when Web pages in Chrome is on" : nil)
              && SettingsAppsContent.subtitle("com.apple.Safari", group: .notRecorded) == nil
              && SettingsAppsContent.subtitle("com.apple.Safari", group: .included) == nil,
              "Only Google Chrome carries a page history subtitle, and it says when pages are saved")
        // H8: a browser DayDream doesn't know by name is found by its Info.plist (it opens web links) and listed with the browsers.
        let fakeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("hub-fake-apps-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fakeRoot) }
        func fakeApp(_ name: String, _ schemes: [String]) -> String {
            let contents = fakeRoot.appendingPathComponent(name + ".app/Contents")
            try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleName": name, "CFBundleURLTypes": [["CFBundleURLSchemes": schemes]]]
            try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            return fakeRoot.appendingPathComponent(name + ".app").path
        }
        let madeUp = LocalApp(id: "com.example.madeupbrowser", name: "Made Up Browser", path: fakeApp("Made Up Browser", ["https", "http"]))
        let madeUpNotes = LocalApp(id: "com.example.madeupnotes", name: "Made Up Notes", path: fakeApp("Made Up Notes", ["madeupnotes"]))
        let withMadeUp = SettingsAppsContent.grouped(apps + [madeUp, madeUpNotes], excluded: excluded, browserPages: true)
        check(withMadeUp.first { $0.group == .notRecorded }?.apps.map(\.id) == ["com.example.madeupbrowser"]
              && withMadeUp.first { $0.group == .included }?.apps.contains { $0.id == "com.example.madeupnotes" } == true
              && SettingsAppsContent.browserLabel("com.example.madeupbrowser") == "Not recorded in this version",
              "A made-up browser (opens web links) is listed as a web browser, Not recorded in this version; a made-up non-browser stays Included")
        let hubSettings = (try? String(contentsOfFile: "Sources/MacMemApp/DaydreamSettings.swift", encoding: .utf8)) ?? ""
        // Honesty track (H7): the card is passed only in a release with Chrome page history (ReleaseFeatures).
        // Owner decision 2026-10-03 (after faec835): the card is back under the app list, a title row that opens its settings.
        check(hubSettings.contains("browserPages: model.browserPagesSaved, chromePages: ReleaseFeatures.chromePageHistory ? AnyView(chromePages) : nil"),
              "Settings › Apps to remember passes the saved switch and the Web pages in Chrome card")

        for enabled in [true, false] {
            var toggled: [String] = []
            let size = NSSize(width: 760, height: 1100)
            let host = NSHostingView(rootView: SettingsAppsContent(apps: apps, excluded: excluded, query: .constant(""), typedText: .constant(false),
                                                                   loaded: true, enabled: enabled, toggle: { toggled.append($0) })
                .frame(width: size.width, height: size.height).environment(\.controlActiveState, .active))
            window.contentView = host
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            try await Task.sleep(nanoseconds: 180_000_000)
            host.layoutSubtreeIfNeeded()
            let exclusion = buttons(in: host).filter { ($0.accessibilityLabel() ?? "").hasPrefix("Include ") }
            let labels = exclusion.compactMap { $0.accessibilityLabel() }
            check(!labels.contains { $0.contains("Passwords") || $0.contains("1Password") }, "Always-private apps have no exclusion button")
            check(!labels.contains { $0.contains("DayDream") }, "DayDream itself has no exclusion button")
            check(labels.count == 4 && Set(labels).count == 4, "Each other listed app has exactly one exclusion button")
            check(labels.contains("Include Notes in recording"), "The exclusion button names the app and recording")
            guard let notes = exclusion.first(where: { $0.accessibilityLabel() == "Include Notes in recording" }) else { fatalError("no Notes button") }
            check(notes.accessibilityValue() as? String == "Selected", "An included app's button reads Selected")
            check(notes.frame.width > 450, "The whole app row is the exclusion button")
            let calendar = exclusion.first { $0.accessibilityLabel() == "Include Calendar in recording" }
            check(calendar?.accessibilityValue() as? String == "Not selected", "An excluded app's button reads Not selected")
            if enabled {
                check(exclusion.allSatisfy(\.isEnabled), "An enabled list's exclusion buttons are enabled")
                check(notes.accessibilityPerformPress() && toggled == ["com.apple.Notes"], "Pressing Include Notes toggles Notes exactly once")
            } else {
                check(exclusion.allSatisfy { !$0.isEnabled }, "A list that can't save disables every exclusion button")
                check(!notes.accessibilityPerformPress() && toggled.isEmpty, "Pressing a disabled exclusion button changes nothing")
            }
            window.contentView = nil
        }
    }
}
