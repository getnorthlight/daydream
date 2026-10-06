// DD-RECIPE: APP
// setup-upgrade-checks (fix/setup-status, owner 9/28): setup is forced and proper, and an upgrade from test 4/5 gets a
// one-time what's-new. Drives the REAL setup window (`DaydreamOnboarding(model:)`) for a production-mode MemoryViewModel
// on scratch histories (MAC_MEM_HOME) with HOME and CFFIXED_USER_HOME in scratch, offscreen:
//   fresh     : setup opens; Summaries on this Mac ON by default; one Continue starts it and moves to Apps; typing and
//               Web pages in Chrome ON; the last page (Connect your AI) says the download live, and Summaries Off with its button
//   upgrade   : setup finished in an older build (completedV1, no setup version) and a store as test 4/5 left it (typing
//               saved Off, no Chrome switch): what's-new opens once at launch, while recording; its Apps page shows both
//               ON; Done writes version 2 and SetupChoices on/on, leaves captureText and browserPages on, asks Chrome
//               once, and it never opens by itself again
//   explicit  : SetupChoices typing .off keeps typing OFF on what's-new
//   close     : closing setup mid-download never turns summaries off (the engine turns them on when verified; with the
//               shim only that chooseLocal was called)
//   cloud     : a wrong key at Continue shows the problem line with one Change Key button, the page stays, nothing is on
// Nothing records (`startCapture` refuses and counts in check builds), downloads, reads the Keychain or goes online: the
// summary controls are the check build's recording fakes (`SummaryControls.recording`), the typing key is in memory, and
// Chrome access is a fake environment. Never orders a window on screen or asks for a permission.
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
@MainActor func labels(_ root: Any, depth: Int = 0, into out: inout [String]) {
    guard depth < 48, let element = root as? NSAccessibilityProtocol else { return }
    if let l = element.accessibilityLabel(), !l.isEmpty {
        let v = (element.accessibilityValue() as? CustomStringConvertible)?.description ?? ""
        out.append(l + (v.isEmpty ? "" : " = " + v))
    }
    for child in (element.accessibilityChildren() ?? []) { labels(child, depth: depth + 1, into: &out) }
}
@MainActor func texts(_ root: NSView) -> [String] { var out: [String] = []; labels(root, into: &out); return out }

/// Drawn as the front window (switches and buttons in their active colors), 4000 points off every screen.
final class KeyWindow: NSWindow {
    /// Stays offscreen (a titled window is otherwise moved onto a screen), as dd-recall-checks' window does.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
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
        settle(1.2)
    }
    func settle(_ s: Double = 0.6) { pump(s); host.layoutSubtreeIfNeeded(); pump(0.15) }
    /// What the page drew (its check-build report: offscreen SwiftUI text has no accessibility tree) and any labels.
    var drawn: DaydreamOnboarding.Drawn? { DaydreamOnboarding.drawnForChecks }
    var all: [String] {
        var out = texts(host)
        if let d = drawn {
            out += [d.title, d.button, d.localLine] + (d.back ? ["Back"] : [])
            if let p = d.cloudProblem { out += [p.line, p.button] }
            for row in d.rows { out.append("\(row.title) = \(row.value)"); if let b = row.button { out.append(b) } }
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
        setbuf(stdout, nil)
        let env = ProcessInfo.processInfo.environment
        guard let out = env["DD_CHECK_OUT"], !out.hasPrefix("/private/tmp/daydream-"), !out.hasPrefix("/tmp/") else { fail("DD_CHECK_OUT must be a scratch folder") }
        guard let home = env["CFFIXED_USER_HOME"], env["HOME"] == home, !home.hasPrefix("/Users/") else {
            fail("HOME and CFFIXED_USER_HOME must be the same scratch folder")
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        guard appSupport.hasPrefix(home) else { fail("REFUSING: Application Support resolves to \(appSupport)") }
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
        let model = MemoryViewModel()
        guard wait(20, { model.preferencesAvailable && !model.historyOpening }) else { fail("\(name): history did not open: \(model.status)") }
        _ = wait(20, { !model.noteWriter.busy })
        // Chrome's Automation question is a fake: it is only counted.
        model.chromeAccessEnvironment = ChromeAccessEnvironment(running: { nil }, verify: { _ in false }, status: { _ in 0 }, ask: { _ in 0 },
                                                                background: { $0() }, main: { $0() },
                                                                onNextChromeActivation: { _ in chromeAsks += 1 })
        // The screen reads unlocked and on console whatever this Mac's own session is: run behind a locked screen, a
        // save's restart waits behind that lock (pauseBehindSuspension) and never reaches startCapture.
        model.wakeSystem = WakeSystem(screenLocked: { false }, onConsole: { true }, after: WakeSystem.live.after, now: WakeSystem.live.now)
        return model
    }

    /// The store test 4 / the test 5 preview left: setup's apps page saved typing at that build's Off default, with no
    /// Chrome switch (store-states.swift, case B).
    static func olderBuild(_ store: MemoryStore) throws {
        let p = try store.policy()
        _ = try store.savePreferences(MemoryPreferences(blockedApps: p.blockedApps, nativeTyping: false), expectedRevision: p.revision)
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
        check(setup.shows("Set up summaries"), "fresh: setup opens on Summaries once both permissions are allowed", setup.all.prefix(12).joined(separator: " | "))
        let s = setup.switches
        check(s.count == 2, "fresh: two summaries switches", "\(s.count)")
        check(s[0].state == (DaydreamOnboarding.macQualifies ? .on : .off) && s[1].state == (DaydreamOnboarding.macQualifies ? .off : .on),
              "fresh: Summaries on this Mac is ON by default (this Mac qualifies: \(DaydreamOnboarding.macQualifies)), the OpenRouter row off",
              "\(s.map(\.state.rawValue))")
        check(DaydreamSummariesContent.localTitle == "Summaries on this Mac" && setup.drawn?.localLine == "Downloads 2.7 GB once. Runs on this Mac.",
              "fresh: row 1 'Summaries on this Mac' says the size once and where it runs", setup.drawn?.localLine ?? "-")
        check(s.allSatisfy(\.isEnabled), "fresh: both summaries switches usable")
        check(!setup.shows("Set up later") && !setup.shows("Cancel download"), "fresh: no Set up later, no Cancel download")
        setup.shoot(shots, "01-summaries-local-on")
        setup.pressReturn()
        check(SummaryControls.calls == ["local"], "fresh: one Continue starts summaries on this Mac (the download runs in the background)", "\(SummaryControls.calls)")
        check(setup.drawn?.page == .apps, "fresh: …and moves to Apps at once, without waiting for the download")
        _ = wait(20) { setup.onApps }
        let apps = setup.switches
        check(apps.count >= 2 && apps.allSatisfy { $0.state == .on && $0.isEnabled }, "fresh: Apps shows typing and Web pages in Chrome ON", "\(apps.map(\.state.rawValue))")
        check(DaydreamAppsContent.typingSwitchTitle == "Remember what you type (skips password fields)" && ChromePagesCard.title == "Web pages in Chrome",
              "fresh: one line each: 'Remember what you type (skips password fields)', 'Web pages in Chrome'")
        setup.shoot(shots, "04-apps-both-on")
        setPhase(model, downloading)
        setup.pressReturn()
        _ = wait(10) { setup.shows(DaydreamOnboarding.connectTitle) }
        check(setup.shows("Summaries = Downloading 1.2 of 2.7 GB"), "fresh: the last page says the download live", setup.all.joined(separator: " | "))
        check(setup.shows(DaydreamOnboarding.connectTitle) && setup.shows("Start Recording"), "fresh: Connect your AI while downloading; Start Recording (never waits for summaries)")
        check(!setup.shows("Typed text = On") && !setup.shows("You're all set"),
              "fresh: the last page has no Typed text row (chosen on the page before)", setup.all.joined(separator: " | "))
        check(model.captureText && model.typing.setUp, "fresh: Continue turned typing on (captureText, key ready)")
        check(!ReleaseFeatures.chromePageHistory || model.browserPagesSaved, "fresh: Web pages in Chrome saved on")
        let choices = model.setupChoicesRead()
        check(choices.typing == .on && choices.chromePages == (ReleaseFeatures.chromePageHistory ? .on : .off), "fresh: SetupChoices on/on", "\(choices)")
        setup.shoot(shots, "05-review-downloading")
        setPhase(model, .on(.local))
        setup.settle(0.4)
        check(!setup.all.contains { $0.hasPrefix("Summaries =") } && setup.shows(DaydreamOnboarding.connectTitle), "fresh: once on, no summaries row", setup.all.joined(separator: " | "))
        setup.shoot(shots, "06-review-on")
        // Summaries off (or failed): the row says so and carries its one button.
        setPhase(model, .off)
        setup.settle(0.4)
        check(setup.shows("Summaries = Off") && setup.shows("Turn On"),
              "fresh: Summaries Off: its row and one Turn On button", setup.all.joined(separator: " | "))
        setPhase(model, .failed(.downloadStopped))
        setup.settle(0.4)
        check(setup.shows("Summaries = The download stopped.") && setup.shows("Try Again"),
              "fresh: a stopped download: its line and Try Again", setup.all.joined(separator: " | "))
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
        check(setup.shows(DaydreamOnboarding.whatsNewTitle) && !setup.shows("Back"), "upgrade: what's-new opens on Summaries while recording, titled What's new, no Back",
              setup.all.prefix(12).joined(separator: " | "))
        let s = setup.switches
        check(s.count == 2 && s[0].state == .on && s.allSatisfy(\.isEnabled), "upgrade: Summaries on this Mac ON and usable while recording", "\(s.map(\.state.rawValue))")
        check(!setup.all.contains { $0.contains("Stop recording") }, "upgrade: no 'stop recording first' line")
        setup.shoot(shots, "whatsnew-1-summaries")
        setup.pressReturn()
        check(SummaryControls.calls == ["local"] && setup.drawn?.page == .apps, "upgrade: Continue starts summaries and moves to Apps while recording", "\(SummaryControls.calls)")
        _ = wait(20) { setup.onApps }
        let apps = setup.switches
        check(apps.count >= 2 && apps.allSatisfy { $0.state == .on && $0.isEnabled }, "upgrade: Apps shows typing ON and Chrome ON (never chosen), usable while recording",
              "\(apps.map(\.state.rawValue)) \(apps.map(\.isEnabled))")
        setup.shoot(shots, "whatsnew-2-apps")
        setPhase(model, .on(.local))
        setup.pressReturn()
        _ = wait(10) { setup.shows(DaydreamOnboarding.doneTitle) }
        check(setup.shows(DaydreamOnboarding.doneTitle) && !setup.shows("Start Recording"), "upgrade: the review's button is Done (no Start Recording while recording)")
        check(setup.shows(DaydreamOnboarding.connectTitle) && !setup.all.contains { $0.hasPrefix("Summaries =") }, "upgrade: last page: Connect your AI, summaries on (no row)")
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
        check(!ReleaseFeatures.chromePageHistory || chromeAsks == 1, "upgrade: Chrome's Automation question is asked once after Done", "\(chromeAsks)")
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
        setup.pressReturn()
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
        setup.pressReturn()
        setPhase(model, downloading)
        setup.close()
        check(SummaryControls.calls == ["local"], "close: closing setup mid-download leaves summaries on this Mac chosen (never turned off)", "\(SummaryControls.calls)")
        setPhase(model, nil)
    }

    /// Settings › Summarizer in each state, and the Settings overview's Summaries row during a download (renders only,
    /// with DD_SETUP_SHOTS): the real Settings sheet (`MemorySettings(model:)`), the state stood in.
    @MainActor static func settingsRenders() throws {
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
    /// and what's-new opens meanwhile: once the cloud is on, the page shows the OpenRouter row and Continue keeps it (it
    /// never turns OpenRouter off for summaries on this Mac and a 2.7 GB download).
    @MainActor static func cloudResuming() throws {
        setDefaults(.finishedBeforeV2)
        let model = try makeModel("cloud-resuming", prepare: olderBuild)
        DaydreamOnboarding.qualifiesForChecks = true
        defer { DaydreamOnboarding.qualifiesForChecks = nil }
        model.recordingForChecks = true
        defer { model.recordingForChecks = nil }
        setPhase(model, .checking)
        let setup = Setup(model)
        check(setup.shows(DaydreamOnboarding.whatsNewTitle), "cloud resuming: what's-new opens on Summaries while the writer checks", setup.all.prefix(8).joined(separator: " | "))
        setPhase(model, .on(.cloud))
        setup.settle(0.5)
        check(setup.switches.count == 2 && setup.switches[1].state == .on, "cloud resuming: once OpenRouter is back on, its row is the one on",
              "\(setup.switches.map(\.state.rawValue))")
        setup.pressReturn()
        check(SummaryControls.calls.isEmpty && setup.drawn?.page == .apps, "cloud resuming: Continue keeps OpenRouter on (no switch to this Mac, no download)",
              "\(SummaryControls.calls)")
        setup.close()
        setPhase(model, nil)
    }

    @MainActor static func cloudKey() throws {
        setDefaults(.fresh)
        let model = try makeModel("cloud-key")
        DaydreamOnboarding.qualifiesForChecks = true
        let setup = Setup(model)
        setup.switches[1].performClick(nil)
        setup.settle(0.5)
        check(setup.switches.map(\.state) == [.off, .on] && views(NSSecureTextField.self, in: setup.host).count == 1,
              "cloud: the OpenRouter switch turns this Mac off and shows the key field")
        setup.switches[0].performClick(nil)
        setup.settle(0.5)
        check(setup.switches.map(\.state) == [.on, .off] && views(NSSecureTextField.self, in: setup.host).isEmpty,
              "cloud: …and this Mac's switch turns the OpenRouter row off again (one at a time)")
        setup.close()
        // A Mac that can't run the model (Intel, or under 8 GB): the OpenRouter row is the default, its key field open.
        // (Switches drawn in their first state: a switch's knob animation never runs offscreen.)
        DaydreamOnboarding.qualifiesForChecks = false
        defer { DaydreamOnboarding.qualifiesForChecks = nil }
        let first = Setup(model)
        check(first.switches.map(\.state) == [.off, .on] && views(NSSecureTextField.self, in: first.host).count == 1,
              "cloud: on a Mac that can't run the model, the OpenRouter row is the default")
        check(CloudSummariesText.line == "From now on, window titles, page titles and what you type go to OpenRouter. Zero-retention hosts requested.",
              "cloud: its one honest line (typed words are sent; zero-retention hosts requested)")
        first.shoot(shots, "02-cloud-key-field")
        // fix/sx-all round 1: the switch on with an empty key is one state (the key field is the question): Continue
        // does nothing until a key is pasted or the switch is turned off. Before, it moved on and the review said Off.
        first.pressReturn()
        first.settle(0.5)
        check(SummaryControls.calls.isEmpty && first.drawn?.page != .apps && first.switches.map(\.state) == [.off, .on],
              "cloud: Continue with the switch on and an empty key sends nothing and stays on the key", "\(SummaryControls.calls) \(String(describing: first.drawn?.page))")
        first.switches[1].performClick(nil)
        first.settle(0.5)
        first.pressReturn()
        _ = wait(20) { first.onApps }
        check(SummaryControls.calls.isEmpty && first.onApps, "cloud: with the switch turned off, Continue sends nothing and moves on", "\(SummaryControls.calls)")
        first.close()
        let again = Setup(model)
        again.typeKey("sk-or-wrong")
        SummaryControls.cloudAnswer = .cloudKey
        again.pressReturn()
        _ = wait(5) { again.shows(SummaryProblem.cloudKey.line) }
        check(SummaryControls.calls == ["cloud:11"], "cloud: Continue tries the pasted key", "\(SummaryControls.calls)")
        check(again.shows("Set up summaries") && again.all.contains { $0.contains("OpenRouter didn't accept this key.") } && again.shows("Change Key"),
              "cloud: a wrong key shows 'OpenRouter didn't accept this key.' with one Change Key button, and the page stays", again.all.joined(separator: " | "))
        check(!SummaryControls.calls.contains("local"), "cloud: summaries are not turned on")
        again.shoot(shots, "03-cloud-key-error")
        again.close()
        // The last page with no key (the OpenRouter switch turned off): Off with Add Key.
        let review = Setup(model)
        review.switches[1].performClick(nil)
        review.settle(0.5)
        review.pressReturn()
        _ = wait(20) { review.onApps }
        review.pressReturn()
        _ = wait(10) { review.shows(DaydreamOnboarding.connectTitle) }
        check(review.shows("Summaries = Off") && review.shows(DaydreamOnboarding.addKeyTitle),
              "cloud: no key: the last page says Summaries Off with one Add Key button", review.all.joined(separator: " | "))
        review.shoot(shots, "07-review-off-add-key")
        review.close()
        // fix/sx-all round 2: OpenRouter chosen with a saved key (after an update, or while the key is checked at launch):
        // setup starts on the OpenRouter row, the field says it uses the saved key, and Continue tries that key.
        check(DaydreamOnboarding.initialChoice(phase: .off, localOffered: true, qualifies: true, cloudChosen: true) == .cloud
              && DaydreamOnboarding.initialChoice(phase: .checking, localOffered: true, qualifies: true, cloudChosen: true) == .cloud
              && DaydreamOnboarding.initialChoice(phase: .off, localOffered: true, qualifies: true, cloudChosen: false) == .local
              && DaydreamOnboarding.initialChoice(phase: .on(.local), localOffered: true, qualifies: true, cloudChosen: true) == .local,
              "cloud: a saved OpenRouter choice starts setup on the OpenRouter row (unless this Mac's summaries are on now)")
        DaydreamOnboarding.qualifiesForChecks = true
        DaydreamOnboarding.cloudChosenForChecks = true
        SummaryControls.phaseForChecks = .checking
        defer { DaydreamOnboarding.cloudChosenForChecks = nil; SummaryControls.phaseForChecks = nil }
        SummaryControls.calls = []; SummaryControls.cloudAnswer = nil
        let kept = Setup(model)
        let field = views(NSSecureTextField.self, in: kept.host).first
        check(kept.switches.map(\.state) == [.off, .on] && field?.placeholderString == CloudSummariesText.savedKeyPlaceholder,
              "cloud: with a saved key, setup starts with the OpenRouter row on and the field says Saved key", "\(kept.switches.map(\.state)) \(field?.placeholderString ?? "no field")")
        check(!kept.shows(SummaryPhase.checking.line ?? "Checking the model"), "cloud: the key's check at launch is never drawn as this Mac's model check", kept.all.joined(separator: " | "))
        kept.shoot(shots, "02b-cloud-saved-key")
        kept.pressReturn()
        _ = wait(10) { kept.onApps }
        check(SummaryControls.calls == ["cloud:0"] && kept.onApps, "cloud: Continue with the field empty tries the saved key and moves on", "\(SummaryControls.calls)")
        kept.close()
    }
}
