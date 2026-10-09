// DD-RECIPE: APP
// setup-upgrade-checks (fix/setup-status, owner 9/28): setup is forced and proper, and an upgrade from test 4/5 gets a
// one-time what's-new. Drives the REAL setup window (`DaydreamOnboarding(model:)`) for a production-mode MemoryViewModel
// on scratch histories (MAC_MEM_HOME) with HOME and CFFIXED_USER_HOME in scratch, offscreen:
//   fresh     : setup opens on Apps once both permissions are allowed (no summaries page, claude/setup-local-summaries):
//               summaries on this Mac are asked for by default as setup leaves Permissions, once; typing and Web pages in
//               Chrome ON; the last page (Connect your AI) has no Summaries row in any state
//   upgrade   : setup finished in an older build (completedV1, no setup version) and a store as test 4/5 left it (typing
//               saved Off, no Chrome switch): what's-new opens once at launch, while recording; its Apps page shows both
//               ON; Done writes version 2 and SetupChoices on/on, leaves captureText and browserPages on, asks Chrome
//               once, and it never opens by itself again
//   explicit  : SetupChoices typing .off keeps typing OFF on what's-new
//   close     : closing setup mid-download never turns summaries off (the engine turns them on when verified; with the
//               shim only the default was asked for)
//   cloud     : setup never shows a key field or a Summaries row, also on a Mac that can't run the model; an OpenRouter
//               upgrader's what's-new never asks for the default
//   finished  : setup opened again after it was finished (File menu) never asks for the default
// Nothing records (`startCapture` refuses and counts in check builds), downloads, reads the Keychain or goes online: the
// summary controls are the check build's recording fakes (`SummaryControls.recording`), the typing key is in memory, and
// Chrome access is a fake environment. Never orders a window on screen or asks for a permission.
import AppKit
import SwiftUI
import MemoryCore
import MemoryUI
// Collect, then report: a failed check prints FAIL and the run goes on; the process exits 1 at the end if any failed
// (an atexit handler, so every return path of main reports). stdout is line-buffered so FAIL lines survive a crash.
var ddFailures = 0
func ddFail(_ label: String) { ddFailures += 1; print("FAIL " + label) }
func ddReportAtExit() {
    setvbuf(stdout, nil, _IOLBF, 0)
    atexit { if ddFailures > 0 { print("\(ddFailures) failed"); fflush(stdout); _exit(1) } }
}

/// The path with every symlink resolved, also for a tail that doesn't exist yet (/var/tmp/x and /private/var/tmp/x
/// are one folder), so a scratch HOME is accepted whichever spelling the work folder was given.
func resolvedPath(_ path: String) -> String {
    var url = URL(fileURLWithPath: path).standardizedFileURL
    var rest: [String] = []
    while access(url.path, F_OK) != 0, url.path != "/" { rest.insert(url.lastPathComponent, at: 0); url.deleteLastPathComponent() }
    guard let real = realpath(url.path, nil) else { return path }
    defer { free(real) }
    let head = String(cString: real)
    return rest.isEmpty ? head : (head == "/" ? "" : head) + "/" + rest.joined(separator: "/")
}

func fail(_ m: String) -> Never { fflush(stdout); FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }
var passed = 0
@MainActor func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS: \(label)") } else { ddFail("\(label) \(detail())") }
}
@MainActor func pump(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
@MainActor @discardableResult func wait(_ t: Double, _ done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(t); while !done() && Date() < end { pump(0.05) }; return done()
}
@MainActor func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
}
@MainActor func labels(_ root: Any, depth: Int = 0, into out: inout [String]) {
    guard depth < 48, let element = root as? NSAccessibilityProtocol else { return }
    if let l = element.accessibilityLabel(), !l.isEmpty {
        let v = (element.accessibilityValue() as? CustomStringConvertible)?.description ?? ""
        out.append(l + (v.isEmpty ? "" : " = " + v))
    }
    for child in (element.accessibilityChildren() ?? []) { labels(child, depth: depth + 1, into: &out) }
}
@MainActor func texts(_ root: NSView) -> [String] { var out: [String] = []; labels(root, into: &out); return out }
/// The page's pixels (offscreen SwiftUI text has no accessibility tree): equal pixels across summary states means the
/// page draws nothing that depends on them.
@MainActor func pixels(_ view: NSView) -> Data? {
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerPlane * max(rep.numberOfPlanes, 1)) }
}

/// Drawn as the front window (switches and buttons in their active colors), 4000 points off every screen.
final class KeyWindow: NSWindow {
    /// Stays offscreen (a titled window is otherwise moved onto a screen), as dd-recall-checks' window does.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    /// rc-018 RC3: macOS 26 already moves a window made at -4000 onto the screen in `init` (480,160 on the owner's Mac,
    /// probe 10/9), before `constrainFrameRect` is ever asked: put it straight back where it was asked for.
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        setFrameOrigin(contentRect.minX <= -1000 && contentRect.minY <= -1000 ? contentRect.origin : NSPoint(x: -5000, y: -5000))
    }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// One setup window: the real `DaydreamOnboarding`, 660x600, offscreen.
@MainActor final class Setup {
    let window: NSWindow
    let host: NSHostingView<AnyView>
    let model: MemoryViewModel
    init(_ model: MemoryViewModel) {
        self.model = model
        window = KeyWindow(contentRect: NSRect(x: -4000, y: -4000, width: 660, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        host = NSHostingView(rootView: AnyView(DaydreamOnboarding(model: model)
            .environment(\.daydreamPermissionRequests, model.permissionRequests).frame(width: 660, height: 600)))
        host.frame = NSRect(x: 0, y: 0, width: 660, height: 600)
        window.contentView = host
        window.orderFrontRegardless()
        if NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) { ddFail("rc-018 RC3: the check's window stays off every screen \(window.frame)") }
        settle(1.2)
    }
    func settle(_ s: Double = 0.6) { pump(s); host.layoutSubtreeIfNeeded(); pump(0.15) }
    /// What the page drew (its check-build report: offscreen SwiftUI text has no accessibility tree) and any labels.
    var drawn: DaydreamOnboarding.Drawn? { DaydreamOnboarding.drawnForChecks }
    var all: [String] {
        var out = texts(host)
        if let d = drawn {
            out += [d.title, d.button] + (d.back ? ["Back"] : [])
        }
        return out
    }
    var onApps: Bool { drawn?.page == .apps && switches.count >= 2 }
    func shows(_ text: String) -> Bool { all.contains { $0 == text || $0.hasPrefix(text + " = ") } }
    var switches: [NSSwitch] { views(NSSwitch.self, in: host) }
    /// Return: the page's main button (`.keyboardShortcut(.defaultAction)`).
    func pressReturn() {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                       isARepeat: false, keyCode: 36) else { fail("no Return event") }
        _ = window.performKeyEquivalent(with: e)
        settle(0.8)
    }
    /// Types into the key field the way a person does (the field editor), so the page's binding sees it.
    func typeKey(_ text: String) {
        guard let field = views(NSSecureTextField.self, in: host).first else { fail("no key field") }
        window.makeFirstResponder(field)
        guard let editor = window.fieldEditor(true, for: field) as? NSTextView else { fail("no field editor") }
        editor.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        settle(0.3)
    }
    func shoot(_ dir: URL?, _ name: String) {
        guard let dir else { return }
        settle(1.2)
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fail("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name + ".png"))
    }
    func close() { window.contentView = nil; window.close(); pump(0.3) }
}

@main struct SetupUpgradeChecks {
    static var root: URL!
    static var shots: URL?
    static var chromeAsks = 0

    @MainActor static func main() async throws {
        ddReportAtExit()
        setbuf(stdout, nil)
        let env = ProcessInfo.processInfo.environment
        guard let out = env["DD_CHECK_OUT"], !out.hasPrefix("/private/tmp/daydream-"), !out.hasPrefix("/tmp/") else { fail("DD_CHECK_OUT must be a scratch folder") }
        // Any scratch HOME but the person's real one, a folder above it or its Library. The runner keeps it in the work
        // folder, which lives under ~/DaydreamReleases (uninstall-plan refuses /var and /tmp), so not "/Users/" in general.
        let realHome = URL(fileURLWithPath: getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "/Users/" + NSUserName()).resolvingSymlinksInPath().path
        guard let home = env["CFFIXED_USER_HOME"], env["HOME"] == home, home.hasPrefix("/"),
              case let scratch = URL(fileURLWithPath: home).resolvingSymlinksInPath().path, scratch != "/",
              !(realHome + "/").hasPrefix(scratch + "/"), !(scratch + "/").hasPrefix(realHome + "/Library/") else {
            fail("HOME and CFFIXED_USER_HOME must be the same scratch folder, not your own home")
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        // Resolved on both sides: FileManager spells /private/var/tmp/... as /var/tmp/...; either is the same scratch HOME.
        guard resolvedPath(appSupport).hasPrefix(resolvedPath(home) + "/") else { fail("REFUSING: Application Support resolves to \(appSupport)") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { fail("timed out") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        root = URL(fileURLWithPath: out).appendingPathComponent("setup-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let dir = env["DD_SETUP_SHOTS"] {
            shots = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
            // Renders only: the review draws the icon of the folder this binary is in (the app's bundle, in the app),
            // so that scratch folder wears DayDream's icon.
            if let icon = NSImage(contentsOfFile: "packaging/Daydream.icns"), ProcessInfo.processInfo.environment["DD_RENDER_ICON"] == "1" {
                NSWorkspace.shared.setIcon(icon, forFile: Bundle.main.bundleURL.path, options: [])
            }
        }
        // Nothing records, downloads or asks: the seams every scenario uses.
        MemoryViewModel.refuseCaptureForChecks = true
        MemoryViewModel.permissionsGranted = { true }
        DaydreamOnboarding.readPermissions = { (true, true) }
        SummaryControls.current = .recording

        try fresh()
        try upgrade()
        try explicitOff()
        try closeMidDownload()
        try cloudKey()
        try cloudResuming()
        try finishedSetupAgain()
        // fix/bugs7: the row follows the writer's own phase: a problem says its line, never On this Mac, OpenRouter or Off.
        check(SettingsRowsSnapshot.summariesLabel(SummaryAvailability(provider: .local, busy: false, phase: .failed(.modelWontStart))) == SummaryProblem.modelWontStart.line
              && SettingsRowsSnapshot.summariesLabel(SummaryAvailability(provider: .cloud, busy: false, phase: .failed(.cloudKey))) == SummaryProblem.cloudKey.line
              && SettingsRowsSnapshot.summariesLabel(SummaryAvailability(provider: .off, busy: false, phase: .failed(.downloadStopped))) == SummaryProblem.downloadStopped.line
              && SettingsRowsSnapshot.summariesLabel(SummaryAvailability(provider: .cloud, busy: false, phase: .on(.cloud))) == SettingsRowsSnapshot.cloud
              && SettingsRowsSnapshot.summariesLabel(SummaryAvailability(provider: .off, busy: false, phase: .off)) == SettingsRowsSnapshot.off,
              "the overview's Summaries row says the writer's problem (never On this Mac, OpenRouter or Off over one)")
        try settingsRenders()
        check(MemoryViewModel.refusedCaptureStarts == 0, "no scenario tried to start recording", "\(MemoryViewModel.refusedCaptureStarts)")
        try? FileManager.default.removeItem(at: root)
        print("\(passed) setup and upgrade checks passed. Scratch histories only; nothing recorded, downloaded, sent or asked.")
        exit(0)
    }

    // MARK: Scenarios

    enum Defaults { case fresh, finishedBeforeV2 }
    @MainActor static func setDefaults(_ kind: Defaults) {
        let d = UserDefaults.standard
        d.removeObject(forKey: DaydreamSetupVersion.key)
        d.removeObject(forKey: DaydreamSetupVersion.whatsNewShownKey)
        d.set(kind == .finishedBeforeV2, forKey: MemoryViewModel.setupCompletedKey)
    }

    /// A production model on its own scratch history. `prepare` writes to the store first (as an older build left it).
    @MainActor static func makeModel(_ name: String, prepare: ((MemoryStore) throws -> Void)? = nil) throws -> MemoryViewModel {
        let memory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        setenv("MAC_MEM_HOME", memory.path, 1)
        if let prepare {
            let store = try MemoryStore(home: memory, writable: true, automaticallySyncSearch: false)
            try prepare(store)
        }
        SummaryControls.calls = []
        SummaryControls.phaseForChecks = nil
        SummaryControls.cloudAnswer = nil
        SummaryControls.defaultAnswer = .started
        let model = MemoryViewModel()
        guard wait(20, { model.preferencesAvailable && !model.historyOpening }) else { fail("\(name): history did not open: \(model.status)") }
        _ = wait(20, { !model.noteWriter.busy })
        // Chrome's Automation question is a fake: it is only counted (the next-activation hook is an access read, never a
        // question, so it counts nothing).
        model.chromeAccessEnvironment = ChromeAccessEnvironment(running: { nil }, verify: { _ in false }, status: { _ in 0 }, ask: { _ in chromeAsks += 1; return 0 },
                                                                background: { $0() }, main: { $0() },
                                                                onNextChromeActivation: { _ in })
        // The screen reads unlocked and on console whatever this Mac's own session is: run behind a locked screen, a
        // save's restart waits behind that lock (pauseBehindSuspension) and never reaches startCapture.
        model.wakeSystem = WakeSystem(screenLocked: { false }, onConsole: { true }, after: WakeSystem.live.after, now: WakeSystem.live.now)
        return model
    }

    /// The store test 4 / the test 5 preview left: setup's apps page saved typing at that build's Off default, with no
    /// Chrome switch (store-states.swift, case B). That page showed the typing switch, so its save answered setup's
    /// typing question (`typingChoiceShown`, fix/typing-e2e L3 68bc8a4; before L3 every save answered it): the history
    /// has no native-typing-choice-pending-v1 marker. A history still pending is livefix-1004 (d)'s case (f1daeed): the
    /// full setup opens, never what's-new (onboarding-flow-checks).
    static func olderBuild(_ store: MemoryStore) throws {
        let p = try store.policy()
        _ = try store.savePreferences(MemoryPreferences(blockedApps: p.blockedApps, nativeTyping: false, typingChoiceShown: true), expectedRevision: p.revision)
        guard try !store.nativeTypingChoicePending() else { fail("olderBuild: the older build's setup save left the typing question pending") }
    }

    @MainActor static func setPhase(_ model: MemoryViewModel, _ phase: SummaryPhase?) {
        SummaryControls.phaseForChecks = phase
        model.noteWriter.objectWillChange.send()
    }

    static let downloading = SummaryPhase.downloading(received: 1_200_000_000, total: 2_740_937_888)

    @MainActor static func fresh() throws {
        setDefaults(.fresh)
        let model = try makeModel("fresh")
        check(model.setupLaunch(counting: false) == .setup, "fresh: setup opens by itself at the first launch")
        let setup = Setup(model)
        check(DaydreamOnboardingPage.allCases == [.permissions, .apps, .review], "fresh: setup has no summaries page (Permissions, Apps, Connect)")
        check(setup.drawn?.page == .apps && setup.shows("Apps to remember") && !setup.all.contains { $0.contains("Set up summaries") },
              "fresh: with both permissions allowed, setup goes straight to Apps", setup.all.prefix(12).joined(separator: " | "))
        check(SummaryControls.calls == ["default-local"], "fresh: leaving Permissions asks for summaries on this Mac by default, once (silently)", "\(SummaryControls.calls)")
        check(views(NSSecureTextField.self, in: setup.host).isEmpty && !setup.shows(CloudSummariesText.title),
              "fresh: no OpenRouter row or key field in setup (Settings › Summarizer only)")
        _ = wait(20) { setup.onApps }
        let apps = setup.switches
        check(apps.count >= 2 && apps.allSatisfy { $0.state == .on && $0.isEnabled }, "fresh: Apps shows typing and Web pages in Chrome ON", "\(apps.map(\.state.rawValue))")
        check(DaydreamAppsContent.typingSwitchTitle == "Remember what you type (skips password fields)" && ChromePagesCard.title == "Web pages in Chrome",
              "fresh: one line each: 'Remember what you type (skips password fields)', 'Web pages in Chrome'")
        setup.shoot(shots, "04-apps-both-on")
        setPhase(model, downloading)
        setup.pressReturn()
        _ = wait(10) { setup.shows(DaydreamOnboarding.connectTitle) }
        check(SummaryControls.calls == ["default-local"], "fresh: the default was asked for once in the whole setup", "\(SummaryControls.calls)")
        check(setup.shows(DaydreamOnboarding.connectTitle) && setup.shows("Start Recording"), "fresh: Connect your AI while downloading; Start Recording (never waits for summaries)")
        check(!setup.shows("Typed text = On") && !setup.shows("You're all set"),
              "fresh: the last page has no Typed text row (chosen on the page before)", setup.all.joined(separator: " | "))
        check(model.captureText && model.typing.setUp, "fresh: Continue turned typing on (captureText, key ready)")
        check(!ReleaseFeatures.chromePageHistory || model.browserPagesSaved, "fresh: Web pages in Chrome saved on")
        let choices = model.setupChoicesRead()
        check(choices.typing == .on && choices.chromePages == (ReleaseFeatures.chromePageHistory ? .on : .off), "fresh: SetupChoices on/on", "\(choices)")
        setup.shoot(shots, "05-review-downloading")
        // claude/setup-local-summaries (owner 10/7): the Connect page has no Summaries row in any state (downloading, on,
        // off, a problem): the page is the same, pixel for pixel, whatever the summaries are doing.
        let downloadingPixels = pixels(setup.host)
        for (name, phase) in [("on", SummaryPhase.on(.local)), ("off", SummaryPhase.off), ("problem", SummaryPhase.failed(.downloadStopped))] {
            setPhase(model, phase)
            setup.settle(0.4)
            check(setup.drawn?.page == .review && downloadingPixels != nil && pixels(setup.host) == downloadingPixels
                  && !setup.all.contains { $0.hasPrefix("Summaries") || $0.contains("Turn On") || $0.contains("Add Key") },
                  "fresh: Connect your AI (\(name)) draws the same page as while downloading: no Summaries row")
        }
        setup.close()
    }

    @MainActor static func upgrade() throws {
        setDefaults(.finishedBeforeV2)
        let model = try makeModel("upgrade", prepare: olderBuild)
        check(!model.captureText && !model.browserPagesSaved, "upgrade: the older build left typing and Chrome pages off")
        check(model.setupLaunch(counting: true) == .whatsNew && UserDefaults.standard.integer(forKey: DaydreamSetupVersion.whatsNewShownKey) == 1,
              "upgrade: what's-new opens by itself at launch (counted once)")
        model.recordingForChecks = true
        check(model.recording, "upgrade: recording (drawn only)")
        let setup = Setup(model)
        _ = wait(20) { setup.onApps }
        check(setup.drawn?.page == .apps && setup.shows(DaydreamOnboarding.whatsNewTitle) && !setup.shows("Back"),
              "upgrade: what's-new opens on Apps while recording, titled What's new, no Back", setup.all.prefix(12).joined(separator: " | "))
        check(SummaryControls.calls.isEmpty, "upgrade: what's-new never changes summaries (no summaries choice, no default)", "\(SummaryControls.calls)")
        check(!setup.all.contains { $0.contains("Stop recording") }, "upgrade: no 'stop recording first' line")
        let apps = setup.switches
        check(apps.count >= 2 && apps.allSatisfy { $0.state == .on && $0.isEnabled }, "upgrade: Apps shows typing ON and Chrome ON (never chosen), usable while recording",
              "\(apps.map(\.state.rawValue)) \(apps.map(\.isEnabled))")
        setup.shoot(shots, "whatsnew-2-apps")
        setPhase(model, .on(.local))
        setup.pressReturn()
        _ = wait(10) { setup.shows(DaydreamOnboarding.doneTitle) }
        check(setup.shows(DaydreamOnboarding.doneTitle) && !setup.shows("Start Recording"), "upgrade: the review's button is Done (no Start Recording while recording)")
        check(setup.shows(DaydreamOnboarding.connectTitle) && !setup.all.contains { $0.hasPrefix("Summaries") }, "upgrade: last page: Connect your AI, no summaries row")
        setup.shoot(shots, "whatsnew-3-done")
        chromeAsks = 0
        // fix/sx-all: the Apps save set recording down and started it again, as every save while recording does (the
        // check build refuses and counts that start). Done itself starts nothing.
        let restartsAfterSave = MemoryViewModel.refusedCaptureStarts
        setup.pressReturn()
        let d = UserDefaults.standard
        check(d.integer(forKey: DaydreamSetupVersion.key) == DaydreamSetupVersion.current && d.bool(forKey: MemoryViewModel.setupCompletedKey),
              "upgrade: Done writes DaydreamSetupVersion 2")
        check(model.captureText && model.typing.setUp && (!ReleaseFeatures.chromePageHistory || (model.browserPages && model.browserPagesSaved)),
              "upgrade: Done leaves captureText true and browserPages true")
        let choices = model.setupChoicesRead()
        check(choices.typing == .on && choices.chromePages == (ReleaseFeatures.chromePageHistory ? .on : .off), "upgrade: SetupChoices on/on", "\(choices)")
        // chromeask-1005 (d79f26e): the question only ever comes from the press on setup's Chrome row; the after-setup
        // follow-up and the wait for Chrome to come forward are gone, so Done asks nothing.
        check(chromeAsks == 0, "upgrade: Done asks no Chrome Automation question (only setup's Chrome row asks)", "\(chromeAsks)")
        check(model.setupLaunch(counting: false) == .none, "upgrade: what's-new never opens by itself again")
        check(MemoryViewModel.refusedCaptureStarts == restartsAfterSave, "upgrade: Done never starts recording",
              "\(MemoryViewModel.refusedCaptureStarts - restartsAfterSave)")
        check(restartsAfterSave == 1, "upgrade: the Apps save resumes the recording it set down, once", "\(restartsAfterSave)")
        MemoryViewModel.refusedCaptureStarts = 0
        model.recordingForChecks = nil
        setup.close()

        // Closed unfinished: it opens again at the next launches, at most three times in all.
        setDefaults(.finishedBeforeV2)
        let opens = (0..<5).map { _ in model.setupLaunch(counting: true) }
        check(opens == [.whatsNew, .whatsNew, .whatsNew, .none, .none], "upgrade: closed unfinished, what's-new opens again at most 2 more times", "\(opens)")
    }

    @MainActor static func explicitOff() throws {
        setDefaults(.finishedBeforeV2)
        let model = try makeModel("explicit-off") { store in
            try olderBuild(store)
            try store.saveSetupChoices(SetupChoices(typing: .off, at: "2026-09-28T00:00:00Z"))
        }
        let setup = Setup(model)
        _ = wait(20) { setup.onApps }
        let apps = setup.switches
        check(apps.count == 2 && apps[0].state == .off && apps[1].state == .on, "explicit: SetupChoices typing .off shows typing OFF (Chrome still ON)",
              "\(apps.map(\.state.rawValue))")
        setup.close()
    }

    @MainActor static func closeMidDownload() throws {
        setDefaults(.fresh)
        let model = try makeModel("close-mid-download")
        let setup = Setup(model)
        setPhase(model, downloading)
        setup.close()
        check(SummaryControls.calls == ["default-local"], "close: closing setup mid-download leaves summaries on this Mac chosen (never turned off)", "\(SummaryControls.calls)")
        setPhase(model, nil)
    }

    /// Settings › Summarizer in each state, and the Settings overview's Summaries row during a download (renders only,
    /// with DD_SETUP_SHOTS): the real Settings sheet (`MemorySettings(model:)`), the state stood in.
    @MainActor static func settingsRenders() throws {
        // A fresh install's defaults: the renders are about Settings, not a launch. Left on the last scenario's finished
        // setup, the model wants recording at launch, and with every start refused (check build) the permission watch's
        // comeback start tried again on each tick while a sheet was open (7 counted starts, none of them a scenario's).
        setDefaults(.fresh)
        let model = try makeModel("settings")
        func sheet(_ section: String, _ name: String, height: CGFloat = 560, inspect: ((NSView) -> Void)? = nil) {
            model.settingsSection = section
            let window = KeyWindow(contentRect: NSRect(x: -4000, y: -4000, width: 720, height: height), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            let host = NSHostingView(rootView: AnyView(MemorySettings(model: model, height: height)))
            host.frame = NSRect(x: 0, y: 0, width: 720, height: height)
            window.contentView = host
            window.orderFrontRegardless()
            pump(1.2); host.layoutSubtreeIfNeeded(); pump(0.3)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fail("no bitmap") }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let shots { try? rep.representation(using: .png, properties: [:])!.write(to: shots.appendingPathComponent(name + ".png")) }
            inspect?(host)
            window.contentView = nil; window.close(); pump(0.2)
        }
        let states: [(String, SummaryPhase)] = [
            ("off", .off), ("downloading", downloading), ("checking", .checking), ("on-local", .on(.local)), ("on-cloud", .on(.cloud)),
            ("failed-download-stopped", .failed(.downloadStopped)), ("failed-cloud-key", .failed(.cloudKey))
        ]
        var cloudFrames: [String: NSRect] = [:]
        for (name, phase) in states {
            setPhase(model, phase)
            sheet("Summaries", "settings-summarizer-\(name)") { host in
                // fix/sx-all round 2: the switches are drawn from what runs, one on at a time; a problem's one button sits on
                // its switch's line (the rows below never move).
                let switches = views(NSSwitch.self, in: host).sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
                let on = switches.filter { $0.state == .on }.count
                check(switches.count == 2 && on <= 1, "Settings › Summarizer (\(name)): two switches, at most one drawn on", "\(switches.map(\.state))")
                let expected: [NSControl.StateValue] = SummaryPhaseReading.cloudOn(phase) ? [.off, .on] : SummaryPhaseReading.localOn(phase) ? [.on, .off] : [.off, .off]
                check(switches.map(\.state) == expected, "Settings › Summarizer (\(name)): the switch drawn on is the one that runs", "\(switches.map(\.state))")
                // The OpenRouter switch's place, per state: a problem's button beside its switch never pushes it down.
                if let cloud = switches.last { cloudFrames[name] = cloud.convert(cloud.bounds, to: nil) }
            }
        }
        // fix/sx-all round 2: Try Again sits on the switch's line (the rows below never move): the OpenRouter switch is
        // where it is while the download runs (a one-line state too).
        check(cloudFrames["failed-download-stopped"] != nil && cloudFrames["failed-download-stopped"] == cloudFrames["downloading"],
              "Settings › Summarizer: a problem's button sits on its switch's line; the row below doesn't move", "\(cloudFrames)")
        // fix/sx-all round 3 (P2): the local row keeps its one-line slot in every state: the OpenRouter switch is in the same
        // place whether the local line says "Checking the model", "Downloading ..." or nothing (it moved about 14 pt).
        check(Set(cloudFrames.values.map { "\(Int($0.minY.rounded()))" }).count == 1 && cloudFrames.count == states.count,
              "Settings › Summarizer: the OpenRouter switch never moves between states (off, downloading, checking, on, a problem)", "\(cloudFrames.mapValues { Int($0.minY.rounded()) })")
        check(downloading.line == "Downloading 1.2 of 2.7 GB" && SummaryPhase.checking.line == "Checking the model"
              && SummaryPhase.off.line == nil && SummaryPhase.on(.local).line == nil,
              "Settings › Summarizer's one line is the state's own (none when off or on)")
        check(SummaryProblem.downloadStopped.button == "Try Again" && SummaryProblem.cloudKey.button == "Change Key" && SummaryProblem.cloudCredits.button == "Add Credits",
              "each problem has its one button: Try Again, Change Key, Add Credits")
        setPhase(model, nil)
        // The overview's Summaries row while the model downloads (the writer's own busy and progress; nothing downloads).
        let writer = model.noteWriter
        writer.busy = true; writer.progress = 0.44
        _ = wait(5) { model.activity.summaries.busy }
        sheet("General", "settings-hub-downloading", height: 520)
        check(SettingsRowsSnapshot.summariesLabel(SummaryAvailability(provider: .off, busy: true, downloadProgress: 0.44)) == "Downloading…",
              "the overview's Summaries row says Downloading… (never Not set up) while the model downloads")
        writer.busy = false; writer.progress = nil
    }

    /// fix/bugs7: an upgrade whose OpenRouter switch was on. At launch the writer says Checking until the cloud is back on,
    /// and what's-new opens meanwhile: it never asks for summaries on this Mac (no switch away from OpenRouter, no 2.7 GB
    /// download), and the last page shows no summaries row once OpenRouter is on.
    @MainActor static func cloudResuming() throws {
        setDefaults(.finishedBeforeV2)
        let model = try makeModel("cloud-resuming", prepare: olderBuild)
        DaydreamOnboarding.qualifiesForChecks = true
        defer { DaydreamOnboarding.qualifiesForChecks = nil }
        model.recordingForChecks = true
        defer { model.recordingForChecks = nil }
        setPhase(model, .checking)
        let setup = Setup(model)
        _ = wait(20) { setup.onApps }
        check(setup.shows(DaydreamOnboarding.whatsNewTitle) && setup.drawn?.page == .apps, "cloud resuming: what's-new opens on Apps while the writer checks",
              setup.all.prefix(8).joined(separator: " | "))
        setPhase(model, .on(.cloud))
        setup.pressReturn()
        _ = wait(10) { setup.shows(DaydreamOnboarding.connectTitle) }
        check(SummaryControls.calls.isEmpty && !setup.all.contains { $0.hasPrefix("Summaries") },
              "cloud resuming: OpenRouter stays on (no switch to this Mac, no download, no summaries row)", "\(SummaryControls.calls) \(setup.all.joined(separator: " | "))")
        // The Apps save while recording sets recording down and starts it again once (the check build refuses and counts it).
        check(MemoryViewModel.refusedCaptureStarts <= 1, "cloud resuming: the Apps save resumes recording at most once", "\(MemoryViewModel.refusedCaptureStarts)")
        MemoryViewModel.refusedCaptureStarts = 0
        setup.close()
        setPhase(model, nil)
    }

    /// claude/setup-local-summaries: setup opened again after it was finished (File › Set Up DayDream…) changes nothing
    /// about summaries: an earlier choice (off, too) is kept.
    @MainActor static func finishedSetupAgain() throws {
        setDefaults(.finishedBeforeV2)
        UserDefaults.standard.set(DaydreamSetupVersion.current, forKey: DaydreamSetupVersion.key)
        defer { setDefaults(.fresh) }
        let model = try makeModel("finished-again")
        DaydreamOnboarding.qualifiesForChecks = true
        defer { DaydreamOnboarding.qualifiesForChecks = nil }
        setPhase(model, .off)
        let setup = Setup(model)
        _ = wait(20) { setup.onApps }
        check(setup.drawn?.page == .apps && SummaryControls.calls.isEmpty, "finished: setup opened again never asks for the default (summaries off stays off)",
              "\(SummaryControls.calls)")
        setup.close()
        setPhase(model, nil)
    }

    @MainActor static func cloudKey() throws {
        setDefaults(.fresh)
        let model = try makeModel("cloud-key")
        // A Mac that can't run the model (Intel, or under 8 GB): setup asks the writer anyway (it says no), and never shows a
        // key field, and the last page says nothing about summaries (Settings › Summaries has the switches).
        DaydreamOnboarding.qualifiesForChecks = false
        defer { DaydreamOnboarding.qualifiesForChecks = nil }
        SummaryControls.defaultAnswer = .unavailable
        defer { SummaryControls.defaultAnswer = .started }
        setPhase(model, .off)
        let review = Setup(model)
        _ = wait(20) { review.onApps }
        check(views(NSSecureTextField.self, in: review.host).isEmpty, "cloud: setup has no key field on a Mac that can't run the model")
        review.pressReturn()
        _ = wait(10) { review.shows(DaydreamOnboarding.connectTitle) }
        let offPixels = pixels(review.host)
        setPhase(model, .failed(.downloadStopped))
        review.settle(0.4)
        check(review.drawn?.page == .review && offPixels != nil && pixels(review.host) == offPixels
              && !review.all.contains { $0.hasPrefix("Summaries") || $0.contains("Add Key") || $0.contains("Turn On") },
              "cloud: the last page has no Summaries row (no Add Key, no Turn On): the same page whatever summaries do")
        setPhase(model, .off)
        check(!SummaryControls.calls.contains("local") && !SummaryControls.calls.contains(where: { $0.hasPrefix("cloud") }),
              "cloud: nothing is turned on", "\(SummaryControls.calls)")
        review.shoot(shots, "07-review-off")
        review.close()
        check(CloudSummariesText.line == "From now on, window titles, page titles and what you type go to OpenRouter. Zero-retention hosts requested.",
              "cloud: Settings' OpenRouter row keeps its one honest line (typed words are sent; zero-retention hosts requested)")
        setPhase(model, nil)
    }
}
