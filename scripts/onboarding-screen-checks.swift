// DD-RECIPE: APP
// onboarding-screen-checks (fix/setup-status): renders the REAL setup window (`DaydreamOnboarding(model:)`, the view the
// "Set up DayDream" scene shows) for a production-mode MemoryViewModel on scratch histories (MAC_MEM_HOME) with HOME and
// CFFIXED_USER_HOME in scratch, page by page, light and dark, into $DD_CHECK_OUT/onboarding-renders. Checks that every
// page keeps the 660x600 footprint, that the last page fits above its buttons, and setup's source rules (no typing
// sheet, no Set up later or Cancel download, no sparkle).
// Nothing records (`startCapture` refuses in check builds), downloads, reads the Keychain, goes online or asks for a
// permission: summary controls are the check build's recording fakes and permissions are a stand-in read.
import AppKit
import SwiftUI
import MemoryCore
import MemoryUI

func fail(_ m: String) -> Never { fflush(stdout); FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }
var passed = 0
@MainActor func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS: \(label)") } else { fail("\(label) \(detail())") }
}
@MainActor func pump(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
@MainActor @discardableResult func wait(_ t: Double, _ done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(t); while !done() && Date() < end { pump(0.05) }; return done()
}
@MainActor func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
}

/// Drawn as the front window, 4000 points off every screen (as dd-recall-checks' window).
final class KeyWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// The bottom edge of a marker at the end of a setup page's content, in window coordinates (top-left origin).
struct ContentBottom: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
final class Box<T> { var value: T; init(_ value: T) { self.value = value } }

@main struct OnboardingScreenChecks {
    static var root: URL!
    static var output: URL!
    static var rendered = 0

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let env = ProcessInfo.processInfo.environment
        guard let out = env["DD_CHECK_OUT"], !out.hasPrefix("/private/tmp/daydream-"), !out.hasPrefix("/tmp/") else { fail("DD_CHECK_OUT must be a scratch folder") }
        guard let home = env["CFFIXED_USER_HOME"], env["HOME"] == home, !home.hasPrefix("/Users/") else {
            fail("HOME and CFFIXED_USER_HOME must be the same scratch folder")
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        guard appSupport.hasPrefix(home) else { fail("REFUSING: Application Support resolves to \(appSupport)") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 400) { fail("timed out") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        output = URL(fileURLWithPath: env["DD_ONBOARDING_RENDERS"] ?? (out + "/onboarding-renders"), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: out).appendingPathComponent("onboarding-screens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The last page draws the icon of the folder this binary is in (the app's bundle, in the app): that scratch
        // folder wears DayDream's icon.
        if let icon = NSImage(contentsOfFile: "packaging/Daydream.icns"), ProcessInfo.processInfo.environment["DD_RENDER_ICON"] == "1" {
            NSWorkspace.shared.setIcon(icon, forFile: Bundle.main.bundleURL.path, options: [])
        }
        MemoryViewModel.refuseCaptureForChecks = true
        MemoryViewModel.permissionsGranted = { true }
        SummaryControls.current = .recording
        UserDefaults.standard.removeObject(forKey: MemoryViewModel.setupCompletedKey)
        UserDefaults.standard.removeObject(forKey: DaydreamSetupVersion.key)

        // fix/setup-tweaks: the drag hint and the refused typing key first (renderAll stops at its first failure).
        dragHint()
        try keychainFailure()
        try firstContinue()
        for dark in [false, true] { try renderAll(dark: dark) }
        print("PASS: \(rendered) setup renders (the real setup window), light and dark, at 660x600 in \(output.path)")
        try await fits()
        sources()
        check(MemoryViewModel.refusedCaptureStarts == 0, "nothing tried to start recording")
        try? FileManager.default.removeItem(at: root)
        print("\(passed) onboarding screen checks passed.")
        exit(0)
    }

    // MARK: Renders

    @MainActor static func makeModel(_ name: String) throws -> MemoryViewModel {
        let memory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        setenv("MAC_MEM_HOME", memory.path, 1)
        SummaryControls.calls = []
        SummaryControls.phaseForChecks = nil
        SummaryControls.cloudAnswer = nil
        let model = MemoryViewModel()
        guard wait(20, { model.preferencesAvailable && !model.historyOpening }) else { fail("\(name): history did not open: \(model.status)") }
        _ = wait(20, { !model.noteWriter.busy })
        model.chromeAccessEnvironment = ChromeAccessEnvironment(running: { nil }, verify: { _ in false }, status: { _ in 0 }, ask: { _ in 0 },
                                                                background: { $0() }, main: { $0() }, onNextChromeActivation: { _ in })
        return model
    }

    @MainActor final class Page {
        let window: KeyWindow
        let host: NSHostingView<AnyView>
        init(_ model: MemoryViewModel, dark: Bool) {
            window = KeyWindow(contentRect: NSRect(x: -4000, y: -4000, width: 660, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host = NSHostingView(rootView: AnyView(DaydreamOnboarding(model: model)
                .environment(\.daydreamPermissionRequests, model.permissionRequests).frame(width: 660, height: 600)))
            host.frame = NSRect(x: 0, y: 0, width: 660, height: 600)
            window.contentView = host
            window.orderFrontRegardless()
            settle(1.2)
        }
        func settle(_ s: Double = 0.6) { pump(s); host.layoutSubtreeIfNeeded(); pump(0.15) }
        var drawn: DaydreamOnboarding.Drawn? { DaydreamOnboarding.drawnForChecks }
        func pressReturn() {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                           isARepeat: false, keyCode: 36) else { fail("no Return event") }
            _ = window.performKeyEquivalent(with: e)
            settle(0.8)
        }
        func shoot(_ name: String, dark: Bool) {
            settle(1.0)
            check(host.fittingSize == NSSize(width: 660, height: 600), "\(name): the setup window keeps its 660x600 footprint", "\(host.fittingSize)")
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fail("no bitmap") }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
            do { try rep.representation(using: .png, properties: [:])!.write(to: url) } catch { fail("\(url.path): \(error)") }
            rendered += 1
        }
        func close() { window.contentView = nil; window.close(); pump(0.3) }
    }

    static let downloading = SummaryPhase.downloading(received: 1_200_000_000, total: 2_740_937_888)

    @MainActor static func setPhase(_ model: MemoryViewModel, _ phase: SummaryPhase?) {
        SummaryControls.phaseForChecks = phase
        model.noteWriter.objectWillChange.send()
    }

    @MainActor static func renderAll(dark: Bool) throws {
        let model = try makeModel("screens-\(dark ? "dark" : "light")")
        defer { DaydreamOnboarding.readPermissions = { (true, true) }; DaydreamOnboarding.qualifiesForChecks = nil }

        // Permissions, before either is allowed.
        DaydreamOnboarding.readPermissions = { (false, false) }
        let permissions = Page(model, dark: dark)
        check(permissions.drawn?.page == .permissions, "setup opens on Permissions until both are allowed")
        permissions.shoot("permissions", dark: dark)
        permissions.close()
        // fix/setup-tweaks: the same page once Accessibility's pane was opened and it is still missing: the drag hint shows.
        DaydreamOnboarding.dragHintForChecks = PermissionDragHint(opened: ["accessibility": Date().addingTimeInterval(-5)])
        let hinted = Page(model, dark: dark)
        check(hinted.drawn?.page == .permissions, "the Permissions page with the drag hint showing")
        hinted.shoot("permissions-drag-hint", dark: dark)
        hinted.close()
        DaydreamOnboarding.dragHintForChecks = nil
        DaydreamOnboarding.readPermissions = { (true, true) }

        // Summaries on a Mac that runs the model; then while it downloads; then a Mac that can't (OpenRouter by default).
        DaydreamOnboarding.qualifiesForChecks = true
        let summaries = Page(model, dark: dark)
        check(summaries.drawn?.page == .summaries, "with both allowed, setup opens on Summaries")
        summaries.shoot("summaries", dark: dark)
        summaries.close()
        setPhase(model, downloading)
        let download = Page(model, dark: dark)
        check(download.drawn?.localLine == "Downloading 1.2 of 2.7 GB", "the local row says the download itself", download.drawn?.localLine ?? "-")
        download.shoot("summaries-download", dark: dark)
        download.close()
        setPhase(model, nil)
        DaydreamOnboarding.qualifiesForChecks = false
        let cloud = Page(model, dark: dark)
        cloud.shoot("summaries-cloud", dark: dark)
        DaydreamOnboarding.qualifiesForChecks = true
        cloud.close()

        // Apps, then the last page (downloading: all set; Off: almost ready, Add Key / Turn On).
        let flow = Page(model, dark: dark)
        flow.pressReturn()
        _ = wait(20) { flow.drawn?.page == .apps && views(NSSwitch.self, in: flow.host).count == 2 }
        flow.shoot("apps", dark: dark)
        setPhase(model, downloading)
        flow.pressReturn()
        _ = wait(10) { flow.drawn?.page == .review }
        check(flow.drawn?.title == DaydreamOnboarding.connectTitle && flow.drawn?.rows.first?.title == "Summaries",
              "the last page: Connect your AI, with the summaries download as its status row",
              "\(flow.drawn.map { "\($0.page) | \($0.title) | \($0.error ?? "no line")" } ?? "-")")
        flow.shoot("review", dark: dark)
        setPhase(model, .off)
        flow.settle(0.4)
        check(flow.drawn?.title == DaydreamOnboarding.connectTitle && flow.drawn?.rows.first?.value == "Off",
              "the last page: Connect your AI, with Summaries Off as its status row")
        flow.shoot("review-summaries-off", dark: dark)
        setPhase(model, .failed(.downloadStopped))
        flow.settle(0.4)
        flow.shoot("review-download-stopped", dark: dark)
        setPhase(model, nil)
        flow.close()

        // What's-new while recording (setup finished in an older build).
        UserDefaults.standard.set(true, forKey: MemoryViewModel.setupCompletedKey)
        model.recordingForChecks = true
        let whatsNew = Page(model, dark: dark)
        check(whatsNew.drawn?.title == DaydreamOnboarding.whatsNewTitle && whatsNew.drawn?.back == false, "what's-new: its own title, no Back")
        whatsNew.shoot("whatsnew-summaries", dark: dark)
        whatsNew.close()
        model.recordingForChecks = nil
        UserDefaults.standard.removeObject(forKey: MemoryViewModel.setupCompletedKey)
        UserDefaults.standard.removeObject(forKey: DaydreamSetupVersion.key)
        UserDefaults.standard.removeObject(forKey: DaydreamSetupVersion.whatsNewShownKey)
    }

    // MARK: Drag hint

    /// fix/setup-tweaks (owner, 9/28): "Drag the card into the list" shows only once a card's System Settings pane was
    /// opened and that permission is still missing (after `PermissionDragHint.delay`, at the page's next read), and goes
    /// once it is allowed; its room is kept, so nothing on the page moves. Nothing opens System Settings here: the
    /// opened pane is the hint's own starting state (a card's button records the same `paneOpened`).
    @MainActor static func dragHint() {
        // The rule itself.
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var hint = PermissionDragHint()
        hint.read(["accessibility": false, "inputMonitoring": false], at: t0)
        check(!hint.shows, "drag hint: hidden before System Settings is opened")
        hint.paneOpened("accessibility", at: t0)
        hint.read(["accessibility": false, "inputMonitoring": false], at: t0.addingTimeInterval(0.5))
        check(!hint.shows, "drag hint: still hidden right after the pane opens (a short delay first)")
        hint.read(["accessibility": false, "inputMonitoring": false], at: t0.addingTimeInterval(PermissionDragHint.delay + 0.5))
        check(hint.shows && hint.waiting == ["accessibility"], "drag hint: shown once a later read finds the opened permission still missing")
        hint.read(["accessibility": true, "inputMonitoring": false], at: t0.addingTimeInterval(4))
        check(!hint.shows && hint.opened.isEmpty, "drag hint: hidden once that permission is allowed (the other missing one was never opened)")
        hint.read(["accessibility": false, "inputMonitoring": false], at: t0.addingTimeInterval(6))
        check(!hint.shows, "drag hint: stays hidden after that until a pane is opened again")
        hint.paneOpened("inputMonitoring", at: t0.addingTimeInterval(7))
        hint.read(["accessibility": true, "inputMonitoring": true], at: t0.addingTimeInterval(10))
        check(!hint.shows, "drag hint: a pane whose permission is allowed by the next read never shows it")

        // The page (the setup cards' own view, embedded as setup draws it).
        final class Reads { var accessibility = false; var inputMonitoring = false; var elements: [String: CGRect] = [:] }
        func page(_ reads: Reads, _ hint: PermissionDragHint) -> (KeyWindow, NSHostingView<AnyView>) {
            let window = KeyWindow(contentRect: NSRect(x: -4000, y: -4000, width: 660, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: AnyView(PermissionGrantView(appURL: URL(fileURLWithPath: "/Applications/DayDream.app"),
                    readAccessibility: { reads.accessibility }, readInputMonitoring: { reads.inputMonitoring }, embedded: true,
                    showsRelaunchRow: false, dragHint: hint)
                .onPreferenceChange(PermissionPageElements.self) { reads.elements = $0 }
                .padding(.horizontal, 36).frame(width: 660, height: 600, alignment: .top)))
            host.frame = NSRect(x: 0, y: 0, width: 660, height: 600)
            window.contentView = host
            window.orderFrontRegardless()
            pump(0.4); host.layoutSubtreeIfNeeded(); pump(0.2)
            return (window, host)
        }
        func frames(_ e: [String: CGRect]) -> [CGRect?] {
            [e["card.accessibility"], e["card.inputMonitoring"], e["dragHint"] ?? e["dragHint.hidden"], e["recovery"]]
        }
        let fresh = Reads()
        let (w1, _) = page(fresh, PermissionDragHint())
        check(fresh.elements["dragHint.hidden"] != nil && fresh.elements["dragHint"] == nil,
              "drag hint on the page: hidden (its room kept) before System Settings is opened", "\(fresh.elements.keys.sorted())")
        let hiddenFrames = frames(fresh.elements)
        w1.contentView = nil; w1.close()

        let opened = Reads()
        let (w2, _) = page(opened, PermissionDragHint(opened: ["accessibility": Date().addingTimeInterval(-5)]))
        check(opened.elements["dragHint"] != nil && opened.elements["dragHint.hidden"] == nil,
              "drag hint on the page: shown after Accessibility's pane was opened while it is still missing", "\(opened.elements.keys.sorted())")
        check(frames(opened.elements) == hiddenFrames && !hiddenFrames.contains { $0 == nil },
              "drag hint on the page: showing it moves nothing (cards, hint and recovery keep their frames)", "\(frames(opened.elements)) vs \(hiddenFrames)")
        // Allowed in System Settings: the page's next read (here, DayDream becoming active) hides it; Input Monitoring's
        // pane was never opened, so nothing shows for it.
        opened.accessibility = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        pump(0.4)
        check(opened.elements["dragHint"] == nil && opened.elements["dragHint.hidden"] != nil,
              "drag hint on the page: hidden once that permission is allowed", "\(opened.elements.keys.sorted())")
        check(opened.elements["dragHint.hidden"] == hiddenFrames[2], "drag hint on the page: hiding it moves nothing either")
        w2.contentView = nil; w2.close()

        // Just opened: the first read comes before the delay; the 2-second poll shows it.
        let waiting = Reads()
        let (w3, _) = page(waiting, PermissionDragHint(opened: ["inputMonitoring": Date()]))
        check(waiting.elements["dragHint"] == nil, "drag hint on the page: not at the read right after the pane opens")
        check(wait(6) { waiting.elements["dragHint"] != nil }, "drag hint on the page: shown by the page's own poll while Input Monitoring is still missing")
        waiting.inputMonitoring = true
        check(wait(4) { waiting.elements["dragHint"] == nil && waiting.elements["dragHint.hidden"] != nil },
              "drag hint on the page: the poll hides it once Input Monitoring is allowed")
        w3.contentView = nil; w3.close()
    }

    // MARK: Keychain

    /// fix/setup-tweaks: Continue on Apps with typing on, and the typing key can't be saved (an in-memory key store that
    /// refuses saves, never the Keychain): the line says typing stays off and the switch turns off with it. Continue
    /// again moves on with typing Off.
    @MainActor static func keychainFailure() throws {
        let keys = MemoryViewModel.typedKeyStore
        var refusing: InMemoryTypedKeyStore?
        MemoryViewModel.typedKeyStore = { _ in
            if let refusing { return refusing }
            let made = InMemoryTypedKeyStore(); made.failSaves = true; refusing = made; return made
        }
        let model = try makeModel("keychain-refuses")
        MemoryViewModel.typedKeyStore = keys
        DaydreamOnboarding.readPermissions = { (true, true) }
        DaydreamOnboarding.qualifiesForChecks = true
        defer { DaydreamOnboarding.qualifiesForChecks = nil }
        check(refusing != nil && !model.typing.setUp, "keychain: the check's history has the refusing in-memory key store and no typing key yet")
        let page = Page(model, dark: false)
        page.pressReturn()
        check(wait(20) { page.drawn?.page == .apps && views(NSSwitch.self, in: page.host).count == 2 }, "keychain: on the Apps page")
        check(page.drawn?.typedText == true && views(NSSwitch.self, in: page.host).first?.state == .on, "keychain: the typing switch starts on")
        page.pressReturn()
        check(wait(10) { page.drawn?.error == TypingSettingsText.keyError }, "keychain: Continue shows the typing key line", page.drawn?.error ?? "-")
        page.settle(0.4)
        check(page.drawn?.page == .apps && page.drawn?.typedText == false && views(NSSwitch.self, in: page.host).first?.state == .off,
              "keychain: the typing switch turns off to match \"typing stays off\"", "\(page.drawn?.typedText as Any)")
        check(!model.captureText && !model.typing.setUp, "keychain: typing really is off")
        page.shoot("apps-keychain-error", dark: false)
        page.pressReturn()
        check(wait(10) { page.drawn?.page == .review }, "keychain: Continue again moves on")
        // Owner 10/5: the last page has no Typed text row; the switch it carries forward is off, and so is typing.
        check(page.drawn?.typedText == false && !page.drawn!.rows.contains { $0.title == "Typed text" } && !model.captureText,
              "keychain: typing reaches the last page off")
        page.close()
    }

    /// fix/setup-tweaks: a fresh setup with typing on moves from Apps to the last page on the FIRST Continue (turning typing
    /// on used to leave its switch waiting in the preference autosave, so that Continue stopped on Apps with no line).
    @MainActor static func firstContinue() throws {
        let model = try makeModel("first-continue")
        DaydreamOnboarding.readPermissions = { (true, true) }
        DaydreamOnboarding.qualifiesForChecks = true
        defer { DaydreamOnboarding.qualifiesForChecks = nil }
        let page = Page(model, dark: false)
        page.pressReturn()
        check(wait(20) { page.drawn?.page == .apps && views(NSSwitch.self, in: page.host).count == 2 }, "first Continue: on the Apps page")
        check(page.drawn?.typedText == true && !model.captureText && !model.typing.setUp, "first Continue: a fresh setup, typing switch on, typing not set up yet")
        page.pressReturn()
        check(wait(3) { page.drawn?.page == .review }, "first Continue: one Continue on Apps with typing on moves to the last page",
              "\(page.drawn.map { "\($0.page) | \($0.error ?? "no line")" } ?? "-")")
        check(model.captureText && model.typing.setUp && !model.preferencesUnresolved, "first Continue: typing is on and saved")
        check(page.drawn?.typedText == true && model.captureText, "first Continue: typing reaches the last page on")
        page.close()
    }

    // MARK: Fit

    /// The last page at 660x600, with its three rows (one carrying a button) and the FileVault line: its content ends above
    /// the button row (30 bottom padding, 36 buttons, 22 spacing).
    @MainActor static func fits() async throws {
        let window = KeyWindow(contentRect: NSRect(x: -4000, y: -4000, width: 660, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        // The Apps page, alone and with a problem line above it (its list is then shorter): both switches stay above the buttons.
        // Drawn as setup draws it: no icon over the title (`showsIcon: page == .permissions`).
        let apps = (0..<12).map { LocalApp(id: "com.example.app\($0)", name: "Example app \($0)") }
        for problem in [false, true] {
            let bottom = Box<CGFloat>(0)
            let host = NSHostingView(rootView: DaydreamOnboardingShell(title: "Apps to remember", back: {}, showsIcon: false, continueAction: {}) {
                if problem { ChoiceProblemLine(text: "Your app choices changed in another window, so this change didn't save.", buttonTitle: "Use saved choices") {} }
                DaydreamAppsContent(apps: apps, excluded: [], query: .constant(""), chromePages: .constant(true), typedText: .constant(true),
                                    loaded: true, enabled: true, compact: problem, toggle: { _ in })
                Color.clear.frame(height: 1).background(GeometryReader { proxy in
                    // fix/setup-2switch: measured in the page's own space (`.global` added the window's title bar).
                    Color.clear.preference(key: ContentBottom.self, value: proxy.frame(in: .named("setup-page")).maxY)
                })
            }.coordinateSpace(name: "setup-page").onPreferenceChange(ContentBottom.self) { bottom.value = $0 })
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 660, height: 600)
            try await Task.sleep(nanoseconds: 200_000_000)
            host.layoutSubtreeIfNeeded()
            let limit: CGFloat = 600 - 30 - 36 - 22
            check(bottom.value > 300 && bottom.value <= limit + 0.5, "the Apps page fits at 660x600\(problem ? " with a problem line" : "") (bottom \(bottom.value), limit \(limit))")
            // Two switches (typing, Web pages in Chrome; no Messages and email row), both drawn above the buttons.
            let switches = views(NSSwitch.self, in: host).map { host.convert($0.bounds, from: $0) }
            check(switches.count == 2 && host.isFlipped && switches.allSatisfy { $0.maxY <= limit + 0.5 },
                  "the Apps page has two switches, both above the buttons\(problem ? " with a problem line" : "")", "\(switches)")
            // fix/sx-all round 2: the Chrome switch starts on, so its one line (what it saves, who gets it) sits under it.
            // Offscreen SwiftUI text has no accessibility tree: the line is found by the room it takes. Two one-line
            // rows sit about 26 points apart; the Chrome row with its line under the title is taller.
            let pair = views(NSSwitch.self, in: host).map { $0.convert($0.bounds, to: nil) }.sorted { $0.midY > $1.midY }
            let gap = pair.count == 2 ? pair[0].midY - pair[1].midY : 0
            // fix/sx-all round 3: exactly one line (two lines put the switches about 51 pt apart).
            check(pair.count == 2 && gap > 34 && gap < 44, "the Apps page shows the Chrome switch's one line under its title\(problem ? " with a problem line" : "") (switches \(gap) pt apart)")
            if !problem, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("apps-page-chrome-line-light.png"))
            }
        }
        for message in [nil, "Finish the current history, backup, or replacement operation first."] {
            let bottom = Box<CGFloat>(0)
            let content = DaydreamReviewContent(rows: [
                DaydreamReviewRow(id: "summaries", title: "Summaries", value: "Off", systemImage: "text.alignleft", button: ("Add Key", {}))
            ], message: message, fileVaultOff: true, comeBack: true, aiReads: true)
            let host = NSHostingView(rootView: DaydreamOnboardingShell(title: DaydreamOnboarding.connectTitle, subtitle: DaydreamOnboarding.connectSubtitle,
                                                                       back: {}, showsIcon: false, continueAction: {}) {
                DaydreamNoAIApps(getApp: {}, otherApp: {})
                content
                Color.clear.frame(height: 1).background(GeometryReader { proxy in
                    Color.clear.preference(key: ContentBottom.self, value: proxy.frame(in: .global).maxY)
                })
            }.onPreferenceChange(ContentBottom.self) { bottom.value = $0 })
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 660, height: 600)
            try await Task.sleep(nanoseconds: 200_000_000)
            host.layoutSubtreeIfNeeded()
            let limit: CGFloat = 600 - 30 - 36 - 22
            check(bottom.value > 200 && bottom.value <= limit + 0.5, "the last page fits at 660x600\(message == nil ? "" : " with its one sentence") (bottom \(bottom.value), limit \(limit))")
        }
    }

    // MARK: Source rules

    @MainActor static func sources() {
        let onboarding = (try? String(contentsOfFile: "Sources/MacMemApp/DaydreamOnboarding.swift", encoding: .utf8)) ?? ""
        let screens = (try? String(contentsOfFile: "Sources/MemoryUI/OnboardingScreens.swift", encoding: .utf8)) ?? ""
        guard !onboarding.isEmpty, !screens.isEmpty else { fail("run from the source tree") }
        // Opt-out setup (owner, 9/27-9/28): no sheet over the Apps page at all; the switch and its line are the choice,
        // and Continue sets typing up.
        check(!onboarding.contains("typingSetupPending") && !onboarding.contains(".sheet(")
              && onboarding.contains("let ready = typing.turnOn() && typing.setUp") && onboarding.contains("guard ready else { error = TypingSettingsText.keyError; return }"),
              "setup has no typing sheet; Continue sets typing up")
        // fix/setup-tweaks (owner, 9/28): no footnote under the Apps page's list.
        check(!screens.contains("New apps are recorded") && !screens.contains("appsFootnote"), "the Apps page has no footnote (New apps are recorded unless you uncheck them.)")
        check(!onboarding.contains("\"Set up later\"") && !onboarding.contains("\"Cancel download\"") && !onboarding.contains("Wait for summary setup"),
              "setup has no Set up later, no Cancel download and never waits for summaries")
        check(!(onboarding + screens).contains("sparkle"), "setup draws no sparkle")
        // fix/sx-all round 2: the Chrome switch starts on, so its one line (what it saves, who gets it) sits under it.
        check(screens.contains("line: ChromePagesCard.setupLine"), "setup's Chrome switch carries ChromePagesCard.setupLine")
        // fix/sx-all round 3 (P2): that line is one line; who gets the pages is in Learn more (the card's explanation).
        check(ChromePagesCard.setupLine == "Saves the title and site of the Chrome tab in front. Skips Incognito."
              && ChromePagesCard.explanation.contains { $0.contains("AI apps you connect can read them") && $0.contains("Cloud summaries") },
              "setup's Chrome line is one line; who gets the pages is in Learn more")
    }
}
