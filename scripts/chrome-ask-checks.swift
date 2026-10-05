// DD-RECIPE: APP
// chrome-ask-checks (chromeask-1005, owner 10/5): macOS's Automation question for Google Chrome ("DayDream wants to
// control Google Chrome") made impossible to get wrong.
//   A. the words: the primer before the press (typing on, typing off, Chrome closed), the refused row, the calm line
//      and its Fix, the Automation usage string; no bold, one short line each;
//   B. the real setup window (`DaydreamOnboarding`) on a production-mode MemoryViewModel (scratch history), with a fake
//      ChromeAccessEnvironment standing in for Chrome, macOS and the reset: Allow; Don't Allow, then Ask again (the
//      reset of DayDream's own AppleEvents answer, then the question again, from the press); the fallback guide beside
//      System Settings when the reset fails, when macOS answers with no question, or in a build that isn't DayDream's
//      own (the switch turned on is picked up with no restart, the guide shows its check); Chrome not running at setup
//      (Allow opens it in the background, then asks); Chrome not installed and Chrome excluded (no row); typing off.
//      Each state is rendered light and dark into $DD_CHROME_SHOTS (default $DD_CHECK_OUT/chrome-ask-shots);
//   C. after setup: "Chrome pages aren't being saved." with Ask again (refused) or Fix (never asked) in the menu bar
//      panel (the app's own panel), the Settings status card and the toolbar's status popover; the one reminder when
//      Chrome is used while refused, once ever, with Ask again; the last answer kept while Chrome is closed;
//   D. sources: the only question is `allowChromeAccess`'s, reached from a press; nothing asks after setup or when
//      Chrome next comes forward; Chrome opens only from setup's Allow (and Ask again, which goes through it);
//   F. Settings › Apps to remember › Web pages in Chrome: the same states (Allow by setup's path, "Chrome pages aren't
//      being saved." with Ask again, Allowed), no Allow… or Open System Settings, each rendered light and dark;
//   E. the reset: only `/usr/bin/tccutil reset AppleEvents com.getnorthlight.daydream`, never another app's id or
//      another service, no shell; the live runner refuses everything else before a process starts.
// Nothing records (`startCapture` refuses in check builds), opens an app or System Settings, asks macOS for anything,
// resets any permission, runs tccutil or sends an Apple Event: the fake stands in for every Chrome, pane and reset call,
// and the live environment is never used.
import AppKit
import Carbon
import SwiftUI
import MemoryCore
import MemoryUI

var passed = 0
var failed = 0
@MainActor func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS: \(label)") } else { failed += 1; print("FAIL: \(label) \(detail())") }
    fflush(stdout)
}
func fatal(_ m: String) -> Never { fflush(stdout); FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }
@MainActor func pump(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
@MainActor @discardableResult func wait(_ t: Double, _ done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(t); while !done() && Date() < end { pump(0.05) }; return done()
}
func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
/// The text of the first `{…}` block after `signature` (brace counting).
func body(of signature: String, in text: String) -> String {
    guard let start = text.range(of: signature), let open = text[start.lowerBound...].firstIndex(of: "{") else { return "" }
    var depth = 0, index = open
    while index < text.endIndex {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1; if depth == 0 { return String(text[open...index]) } }
        index = text.index(after: index)
    }
    return ""
}

/// Stands in for Chrome and macOS: counts every call. `ask` can be held (macOS's question on screen) until released.
final class FakeChrome: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "checks.chrome-ask")
    private var _pid: pid_t? = 4242, _status: OSStatus = -1744, _answer: OSStatus = 0, _clock: TimeInterval = 1000
    private var _installed = true, _opensAs: pid_t? = 4343
    private var counts: [String: Int] = [:]
    private var activations: [() -> Void] = []
    private var gate: DispatchSemaphore?
    private var _resetExit: Int32 = 0, _quick = false, _ownID: String? = "com.getnorthlight.daydream"
    private var _resets: [[String]] = []
    private var _order: [String] = []
    func locked<T>(_ work: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return work() }
    func set(pid: pid_t? = 4242, status: OSStatus = -1744, answer: OSStatus = 0, installed: Bool = true, opensAs: pid_t? = 4343) {
        locked { _pid = pid; _status = status; _answer = answer; _installed = installed; _opensAs = opensAs }
    }
    func setStatus(_ status: OSStatus) { locked { _status = status } }
    func setPid(_ pid: pid_t?) { locked { _pid = pid } }
    func reset() { locked { counts = [:]; activations = []; _resets = []; _order = [] } }
    /// What the next reset returns (0: DayDream's answer is cleared, and macOS has none now), whether the next answer
    /// comes at once with no question (a managed Mac), and the running app's bundle id.
    func setReset(exit: Int32 = 0, quick: Bool = false, ownID: String? = "com.getnorthlight.daydream") {
        locked { _resetExit = exit; _quick = quick; _ownID = ownID }
    }
    var resets: [[String]] { locked { _resets } }
    var order: [String] { locked { _order } }
    func count(_ name: String) -> Int { locked { counts[name] ?? 0 } }
    var waitingActivations: Int { locked { activations.count } }
    private func note(_ name: String) { locked { counts[name, default: 0] += 1; _order.append(name) } }
    /// The next question stays on screen until `release()`.
    func hold() { locked { gate = DispatchSemaphore(value: 0) } }
    func release() { let g = locked { () -> DispatchSemaphore? in let g = gate; gate = nil; return g }; g?.signal() }
    func environment(setupFinished: @escaping () -> Bool) -> ChromeAccessEnvironment {
        ChromeAccessEnvironment(
            running: { [self] in note("running"); return locked { _pid } },
            verify: { [self] _ in note("verify"); return true },
            setupFinished: setupFinished,
            cardShown: { true },
            status: { [self] _ in note("status"); return locked { _status } },
            ask: { [self] _ in
                note("ask")
                locked { gate }?.wait()
                // A person answering takes seconds (an answer at once is macOS refusing with no question).
                return locked { _clock += _quick ? 0.1 : 5; _status = _answer; return _answer }
            },
            background: { [queue] work in queue.async(execute: work) },
            main: { work in DispatchQueue.main.async(execute: work) },
            onNextChromeActivation: { [self] action in locked { activations.append(action) } },
            uptime: { [self] in locked { _clock } },
            installed: { [self] in locked { _installed } },
            openChrome: { [self] done in
                note("openChrome")
                let opened = locked { () -> Bool in if let pid = _opensAs { _pid = pid; return true }; return false }
                DispatchQueue.main.async { done(opened) }
            },
            openPane: { [self] in note("openPane") },
            ownBundleID: { [self] in locked { _ownID } },
            resetAutomation: { [self] arguments in
                note("reset")
                return locked { _resets.append(arguments); if _resetExit == 0 { _status = -1744 }; return _resetExit }
            })
    }
}

/// Drawn as the front window, 4000 points off every screen (as onboarding-screen-checks' window).
final class KeyWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}
final class Elements { var frames: [String: CGRect] = [:] }

@main struct ChromeAskChecks {
    static var shots: URL!
    static var root: URL!
    static var rendered: [String] = []
    static let fake = FakeChrome()
    static var reminders = 0, reminderDismissals = 0
    static var reminderFix: (() -> Void)?
    static var setupOpened = 0
    static var guideShows = 0, guideDones = 0

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let env = ProcessInfo.processInfo.environment
        guard let out = env["DD_CHECK_OUT"], !out.hasPrefix("/private/tmp/daydream-"), !out.hasPrefix("/tmp/") else { fatal("DD_CHECK_OUT must be a scratch folder") }
        guard let home = env["CFFIXED_USER_HOME"], env["HOME"] == home, !home.hasPrefix("/Users/") else {
            fatal("HOME and CFFIXED_USER_HOME must be the same scratch folder")
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        guard appSupport.hasPrefix(home) else { fatal("REFUSING: Application Support resolves to \(appSupport)") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 500) { fatal("chrome-ask-checks timed out") }
        _ = NSApplication.shared
        // Accessory (no Dock icon, no menu bar), as the checks that click SwiftUI buttons run: a prohibited app's
        // windows get no clicks.
        NSApp.setActivationPolicy(.accessory)
        // The drawings show DayDream's own icon, as the app does.
        if let icon = NSImage(contentsOfFile: "packaging/Daydream.icns") { NSApp.applicationIconImage = icon }
        shots = URL(fileURLWithPath: env["DD_CHROME_SHOTS"] ?? (out + "/chrome-ask-shots"), isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: out).appendingPathComponent("chrome-ask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        MemoryViewModel.refuseCaptureForChecks = true
        MemoryViewModel.permissionsGranted = { true }
        SummaryControls.current = .recording
        DaydreamOnboarding.qualifiesForChecks = true
        // Both permissions allowed: the Chrome row is what the Permissions page waits on.
        DaydreamOnboarding.readPermissions = { (true, true) }

        words()
        sources()
        resetSafety()
        for dark in [false, true] {
            try allowPath(dark: dark)
            try deniedPath(dark: dark)
            try fallbackPath(dark: dark)
            try notRunningPath(dark: dark)
            try noRowPaths(dark: dark)
            try typingOffPath(dark: dark)
            try afterSetup(dark: dark)
            try settingsCard(dark: dark)
        }
        check(MemoryViewModel.refusedCaptureStarts == 0, "nothing tried to start recording")
        try? FileManager.default.removeItem(at: root)
        print("RENDERED \(rendered.count) shots in \(shots.path)")
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: A. Words

    @MainActor static func words() {
        typealias Row = PermissionChromeRow
        check(Row.primer == "macOS will ask once. Click Allow so DayDream knows which page you're typing on.", "A1 primer: the owner's words")
        check(Row.offLine == "Chrome pages are off." && Row.askAgainTitle == "Ask again", "A2 refused: \"Chrome pages are off.\" with Ask again")
        check(ChromeAccessNotice.line == "Chrome pages aren't being saved." && ChromeAccessNotice.askAgainTitle == "Ask again"
              && ChromeAccessNotice.fixTitle == "Fix", "A3 the calm line, Ask again (refused) and Fix (never asked)")
        check(ChromeAccessNotice.guideLine == "Turn this on." && ChromeAccessNotice.guideDone == "Chrome pages are on.", "A3 the guide's two lines")
        check(BrowserHistoryLine.needsAccess.text == ChromeAccessNotice.line, "A3 the menu bar's access-off line is the calm line")
        for access in [ChromeAccessState.notAsked, .unknown, .chromeNotRunning, .checking] {
            check(Row.subtitle(access: access, typing: true, opensChrome: false) == Row.primer && Row.illustration(access: access) == .ask,
                  "A4 \(access): the primer, over the drawing of macOS's question")
            check(Row.subtitle(access: access, typing: false, opensChrome: false) == Row.primerTypingOff, "A4 \(access), typing off: the other primer")
        }
        check(Row.subtitle(access: .notAsked, typing: true, opensChrome: true) == Row.primer + " " + Row.opensChromeLine
              && Row.subtitle(access: .checking, typing: true, opensChrome: true) == Row.primer,
              "A5 Chrome closed: the primer says Allow opens it in the background (not while macOS asks)")
        for access in [ChromeAccessState.denied, .askFailed] {
            check(Row.subtitle(access: access, typing: true, opensChrome: false) == Row.offLine && Row.illustration(access: access) == nil
                  && Row.trailing(access: access) == .refused && Row.line(access: access, asked: true) == nil
                  && Row.line(access: access, asked: true, pagesOn: true, settings: true) == nil,
                  "A6 \(access): \"Chrome pages are off.\" with Ask again, no Settings path, no drawing")
        }
        check(Row.subtitle(access: .allowed, typing: true, opensChrome: false) == Row.reason && Row.illustration(access: .allowed) == nil
              && Row.trailing(access: .allowed) == .allowed, "A7 allowed: what Chrome pages save, no drawing")
        check(Row.line(access: .chromeNotRunning, asked: true) == ChromeAccessState.chromeNotRunning.helper
              && Row.line(access: .notAsked, asked: false) == nil && Row.line(access: .chromeNotRunning, asked: false) == nil
              && !(Row.line(access: .chromeNotRunning, asked: true) ?? "").contains("will ask"),
              "A8 a press Chrome couldn't answer says to open Chrome and press Allow (never 'macOS will ask later')")
        let all = [Row.primer, Row.primerTypingOff, Row.opensChromeLine, Row.offLine, ChromeAccessNotice.line, ChromeAccessNotice.fixTitle,
                   ChromeAccessNotice.askAgainTitle, ChromeAccessNotice.guideLine, ChromeAccessNotice.guideDone]
        check(all.allSatisfy { !$0.contains("**") && !$0.contains("Allow…") }, "A9 no bold markup, and never the old Allow…")
        check(all.allSatisfy { $0.count <= 110 }, "A9 each line is short", all.map { "\($0.count)" }.joined(separator: ","))
        let views = source("Sources/MemoryUI/ChromeAccessNotice.swift")
        let reminder = body(of: "public struct ChromeReminderView", in: views)
        check(!views.contains(".bold") && !views.contains("weight: .bold") && !reminder.contains("weight: .semibold"),
              "A9 the calm line, its button and the reminder draw no bold")
        check(!all.contains { $0.contains("Privacy & Security") || $0.contains("→") }, "A9 no long Settings path anywhere")
        let plist = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "packaging/Info.plist")), format: nil)) as? [String: Any]
        check(plist?["NSAppleEventsUsageDescription"] as? String == "DayDream remembers which Chrome page you were on and what you wrote there, so you can find it later. It skips Incognito windows and never changes anything in Chrome.",
              "A10 macOS's question carries the owner's friendlier words")
        check(ChromeAccessMemory.fix(lineAccess: .denied) == .askAgain && ChromeAccessMemory.fix(lineAccess: .askFailed) == .askAgain
              && ChromeAccessMemory.fix(lineAccess: .notAsked) == .chromeCard, "A11 refused: Ask again; not asked: Fix opens setup's Chrome row")
        check(ChromeAccessState.systemSettingsURL.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
              "A12 the guide's pane is Privacy & Security › Automation")
        var p = CapturePresentation(state: .recording(since: Date()), canResume: true, canStop: true)
        p.browserHistory = .needsAccess
        check(MenuBarMenu.chromeFixTitle(p) == "Fix", "A13 the line's button: Fix while never asked")
        p.chromeAskAgain = true
        check(MenuBarMenu.chromeFixTitle(p) == "Ask again", "A13 the line's button: Ask again once refused")
        // The guide sits beside System Settings, inside the screen.
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 875), guide = NSSize(width: 264, height: 140)
        let right = ChromeGuidePlacement.origin(guide: guide, settings: NSRect(x: 300, y: 200, width: 700, height: 600), screen: screen)
        check(right.x == 1012 && right.y == 800 - 64 - 140, "A14 the guide goes right of System Settings, near its top", "\(right)")
        let left = ChromeGuidePlacement.origin(guide: guide, settings: NSRect(x: 700, y: 200, width: 700, height: 600), screen: screen)
        check(left.x == 700 - 12 - 264, "A14 ...or left of it when the right has no room", "\(left)")
        let none = ChromeGuidePlacement.origin(guide: guide, settings: nil, screen: screen)
        check(none.x == 1440 - 264 - 16 && none.y + guide.height <= screen.maxY, "A14 ...or top right without its window", "\(none)")
        let off = ChromeGuidePlacement.origin(guide: guide, settings: NSRect(x: -50, y: -400, width: 2000, height: 500), screen: screen)
        check(off.x >= 8 && off.y >= 8 && off.x + guide.width <= screen.maxX && off.y + guide.height <= screen.maxY, "A14 always on screen", "\(off)")
    }

    // MARK: D. Sources

    @MainActor static func sources() {
        let app = source("Sources/MacMemApp/MacMemApp.swift")
        let onboarding = source("Sources/MacMemApp/DaydreamOnboarding.swift")
        let finish = body(of: "private func finish()", in: onboarding)
        check(!app.contains("func askChromeAccessAfterSetup") && !onboarding.contains("askChromeAccessAfterSetup") && !finish.contains("Chrome"),
              "D1 finishing setup asks nothing about Chrome, now or later")
        check(!app.contains("chromeAccessAskWaiting"), "D1 nothing waits for Chrome to come forward to ask")
        // The one question: allowChromeAccess, reached only from askChromeAccessInSetup and Settings' presses.
        check(app.components(separatedBy: "ChromeEventSender.askForChromeAccess(").count == 2
              && body(of: "func allowChromeAccess(", in: app).contains("ChromeEventSender.askForChromeAccess(pid:pid)"),
              "D2 the one question to macOS is inside allowChromeAccess")
        // Code lines only (doc comments name it): inside MacMemApp.swift, only askChromeAccessInSetup calls it.
        let setupAsk = body(of: "func askChromeAccessInSetup()", in: app)
        let code = app.replacingOccurrences(of: setupAsk, with: "").components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        let callers = code.components(separatedBy: "allowChromeAccess()").count - 1
        check(callers == 0 && setupAsk.contains("allowChromeAccess()"),
              "D2 inside the app model, only setup's Allow (askChromeAccessInSetup) reaches it", "\(callers)")
        for name in ["func checkChromeAccess()", "private func rereadChromeAccessQuietly()", "private func watchChromeRecovery()", "func fixChromeAccess(",
                     "private func remindChromeOff(", "private func chromeAccessAnswered(", "func chromeAccessFromPages("] {
            let b = body(of: name, in: app)
            check(!b.isEmpty && !b.contains("allowChromeAccess") && !b.contains("askForChromeAccess") && !b.contains("ask?(") && !b.contains("env.openChrome")
                  && !b.contains("askChromeAccessInSetup"),
                  "D3 \(name) only reads (never asks macOS, never opens Chrome)")
        }
        check(app.components(separatedBy: "env.openChrome").count == 2 && body(of: "func askChromeAccessInSetup()", in: app).contains("env.openChrome"),
              "D4 Chrome opens only from setup's Allow press, in the background")
        check(onboarding.contains("allow: { chromeRowLatched = true; chromeAsked = true; model.askChromeAccessInSetup() }")
              && onboarding.components(separatedBy: "askChromeAccessInSetup").count == 2,
              "D5 setup's only question is the Chrome row's Allow")
        let settings = source("Sources/MacMemApp/DaydreamSettings.swift")
        check(settings.contains("case .fixChrome: model.fixChromeAccess()") && source("Sources/MacMemApp/MenuBarContent.swift").contains("actions.fixChrome = {")
              && source("Sources/MemoryUI/DaydreamToolbar.swift").contains("out.fixChrome = { dismiss(); base.fixChrome() }"),
              "D6 Fix is wired in Settings, the menu bar and the toolbar's popover")
    }

    // MARK: B. Setup

    @MainActor static func makeModel(_ name: String, finished: Bool = false) throws -> MemoryViewModel {
        let memory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        setenv("MAC_MEM_HOME", memory.path, 1)
        for key in [MemoryViewModel.setupCompletedKey, DaydreamSetupVersion.key, ChromeAccessMemory.answerKey, ChromeAccessMemory.reminderKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if finished { UserDefaults.standard.set(true, forKey: MemoryViewModel.setupCompletedKey) }
        let model = MemoryViewModel()
        guard wait(20, { model.preferencesAvailable && !model.historyOpening }) else { fatal("\(name): history did not open: \(model.status)") }
        _ = wait(20, { !model.noteWriter.busy })
        model.chromeAccessEnvironment = fake.environment(setupFinished: { UserDefaults.standard.bool(forKey: MemoryViewModel.setupCompletedKey) })
        model.chromeReminder = ChromeAccessReminder(show: { fix in reminders += 1; reminderFix = fix }, dismiss: { reminderDismissals += 1 })
        model.openSetupWindow = { setupOpened += 1 }
        model.chromeGuide = ChromeAccessGuide(show: { guideShows += 1 }, done: { guideDones += 1 }, hide: {})
        fake.reset(); fake.setReset()
        return model
    }

    @MainActor final class Page {
        let window: KeyWindow
        let host: NSHostingView<AnyView>
        let elements = Elements()
        let dark: Bool
        init(_ model: MemoryViewModel, dark: Bool) {
            self.dark = dark
            window = KeyWindow(contentRect: NSRect(x: -4000, y: -4000, width: 660, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.colorSpace = .sRGB
            let elements = self.elements
            host = NSHostingView(rootView: AnyView(DaydreamOnboarding(model: model)
                .environment(\.daydreamPermissionRequests, model.permissionRequests).frame(width: 660, height: 600)
                .onPreferenceChange(PermissionPageElements.self) { elements.frames = $0 }))
            host.frame = NSRect(x: 0, y: 0, width: 660, height: 600)
            window.contentView = host
            window.orderFrontRegardless()
            settle(1.2)
        }
        func settle(_ s: Double = 0.4) { pump(s); host.layoutSubtreeIfNeeded(); pump(0.1) }
        var page: DaydreamOnboardingPage? { DaydreamOnboarding.drawnForChecks?.page }
        func has(_ key: String) -> Bool { elements.frames[key] != nil }
        /// The Chrome row as setup drew it last.
        var row: PermissionChromeRow? { DaydreamOnboarding.drawnForChecks?.chromeRow }
        /// Presses the row's drawn button (`allow.chrome` or `open.chrome`): its own closure, as the button runs it.
        /// (A synthesized click doesn't reach a SwiftUI button in a window off every screen.)
        func click(_ key: String) -> Bool {
            guard has(key), let row else { return false }
            switch key {
            case "allow.chrome": row.allow()
            case "open.chrome": row.openSettings()
            case "askagain.chrome": guard let askAgain = row.askAgain else { return false }; askAgain()
            default: return false
            }
            settle(0.3)
            return true
        }
        func shoot(_ name: String, settleFirst: Double = 0.6) {
            if settleFirst > 0 { settle(settleFirst) }
            save(retina(host), name, dark: dark)
        }
        /// Everything the Permissions page drew fits above the window's bottom edge (nothing clipped by the new drawing).
        func fits(_ name: String) {
            let bottom = elements.frames.values.map(\.maxY).max() ?? 0
            check(bottom <= 600 - 60, "\(name): the Permissions page fits above setup's buttons", "\(bottom)")
        }
        func close() { window.contentView = nil; window.close(); pump(0.3) }
    }

    /// The view drawn at 2x (a window off every screen draws at 1x): the drawings are vector, so they stay sharp.
    @MainActor static func retina(_ view: NSView) -> NSBitmapImageRep {
        let b = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { fatal("no bitmap") }
        rep.size = b.size
        view.cacheDisplay(in: b, to: rep)
        return rep
    }
    @MainActor static func save(_ rep: NSBitmapImageRep, _ name: String, dark: Bool) {
        let file = "\(name)-\(dark ? "dark" : "light").png"
        do { try rep.representation(using: .png, properties: [:])!.write(to: shots.appendingPathComponent(file)) } catch { fatal("\(file): \(error)") }
        rendered.append(file)
    }

    /// 1. Allow: Chrome running, not asked. The primer and the drawing; Allow asks once; macOS's question on screen
    /// (the row waits, the drawing stays); Allowed; then the page moves on by itself.
    @MainActor static func allowPath(dark: Bool) throws {
        let model = try makeModel("allow-\(dark)")
        fake.set(pid: 4242, status: -1744, answer: 0)
        let page = Page(model, dark: dark)
        check(page.page == .permissions && page.has("card.chrome") && page.has("allow.chrome") && page.has("chrome.drawing.ask") && !page.has("chrome.below"),
              "B1 Allow (\(dark ? "dark" : "light")): the row primes the question: Allow, the drawing, nothing under it",
              page.elements.frames.keys.sorted().joined(separator: ","))
        check(model.chromeRowAccess == .notAsked && fake.count("ask") == 0, "B1 nothing asked before the press")
        page.fits("B1 primer")
        page.shoot("1-allow-before")
        page.settle(2.3)
        check(page.page == .permissions, "B1 with both permissions allowed, the page waits for the Chrome row (Continue still moves on)")
        fake.hold()
        check(page.click("allow.chrome"), "B1 the row's Allow is pressed (a real click)")
        check(wait(3) { fake.count("ask") == 1 }, "B1 the press asks macOS once", "\(fake.count("ask"))")
        page.settle(0.3)
        check(model.chromeAccess == .checking && page.has("chrome.drawing.ask") && !page.has("allow.chrome"),
              "B1 while macOS asks: a spinner, and the drawing still shows which button to press")
        page.shoot("2-allow-asking", settleFirst: 0)
        fake.release()
        check(wait(3) { model.chromeAccess == .allowed }, "B1 Allow in macOS's question: Allowed", "\(model.chromeAccess)")
        page.settle(0.2)
        check(page.page == .permissions && !page.has("chrome.drawing.ask"), "B1 the row shows Allowed (no drawing) before the page moves on")
        page.shoot("3-allow-allowed", settleFirst: 0)
        check(wait(4) { page.page == .summaries }, "B1 allowed: the page moves on by itself")
        check(fake.count("ask") == 1 && fake.count("openChrome") == 0 && fake.count("openPane") == 0 && fake.waitingActivations == 0,
              "B1 one question, Chrome not opened, nothing waiting to ask later")
        page.close()
    }

    static let ownReset = ["reset", "AppleEvents", "com.getnorthlight.daydream"]

    /// 2. Don't Allow, then Ask again: the row says "Chrome pages are off." with Ask again; the page stays; Ask again
    /// clears DayDream's own AppleEvents answer (exactly that command) and asks again at once, from the press; Allow.
    @MainActor static func deniedPath(dark: Bool) throws {
        let model = try makeModel("deny-\(dark)")
        guideShows = 0; guideDones = 0
        fake.set(pid: 4242, status: -1744, answer: -1743)
        let page = Page(model, dark: dark)
        check(page.click("allow.chrome"), "B2 the row's Allow is pressed")
        check(wait(3) { model.chromeAccess == .denied }, "B2 Don't Allow: refused", "\(model.chromeAccess)")
        page.settle(0.4)
        check(page.has("askagain.chrome") && !page.has("chrome.drawing.ask") && !page.has("open.chrome") && !page.has("allow.chrome")
              && !page.has("chrome.below"),
              "B2 refused (\(dark ? "dark" : "light")): \"Chrome pages are off.\" with Ask again, nothing else",
              page.elements.frames.keys.sorted().joined(separator: ","))
        page.fits("B2 refused")
        page.shoot("4-deny-refused")
        page.settle(2.3)
        check(page.page == .permissions, "B2 refused: the page stays, so Ask again stays in view (Continue still moves on)")
        // Chrome quits: macOS can't be read, and the row still says Chrome pages are off (never "macOS will ask once").
        fake.setPid(nil)
        model.checkChromeAccess()
        page.settle(0.3)
        check(model.chromeAccess == .chromeNotRunning && model.chromeRowAccess == .denied && page.has("askagain.chrome"),
              "B2 Chrome closed: the row keeps the refusal", "\(model.chromeRowAccess)")
        fake.setPid(4242)
        fake.reset(); fake.set(pid: 4242, status: -1743, answer: 0); fake.setReset(exit: 0)
        fake.hold()
        check(page.click("askagain.chrome"), "B2 Ask again is pressed")
        check(wait(3) { fake.count("ask") == 1 }, "B2 Ask again: macOS asks again, once", "\(fake.order)")
        check(fake.resets == [ownReset], "B2 the reset is exactly tccutil's reset AppleEvents com.getnorthlight.daydream, once", "\(fake.resets)")
        check(fake.order.firstIndex(of: "reset").map { r in fake.order.firstIndex(of: "ask").map { r < $0 } ?? false } ?? false,
              "B2 the reset comes first, then the question", "\(fake.order)")
        page.settle(0.3)
        check(model.chromeRowAccess == .checking && page.has("chrome.drawing.ask") && !page.has("askagain.chrome"),
              "B2 while macOS asks again: a spinner, and the drawing shows which button to press")
        page.shoot("5-askagain-asking", settleFirst: 0)
        fake.release()
        check(wait(3) { model.chromeAccess == .allowed }, "B2 Allow: allowed, with no restart", "\(model.chromeAccess)")
        page.settle(0.2)
        check(page.page == .permissions && !page.has("askagain.chrome"), "B2 the row shows Allowed before the page moves on")
        page.shoot("5b-askagain-allowed", settleFirst: 0)
        check(wait(4) { page.page == .summaries }, "B2 allowed: the page moves on by itself")
        check(fake.count("openPane") == 0 && guideShows == 0 && fake.count("openChrome") == 0, "B2 no guide, no pane, Chrome not opened")
        page.close()
    }

    /// 2b. The fallback guide, only when Ask again can't bring the question back: the reset fails; macOS answers at
    /// once with no question (a managed Mac, an older macOS); a build that isn't DayDream's own (no reset at all). The
    /// pane opens with the guide beside it; the switch turned on there is picked up within seconds, no restart, and the
    /// guide shows its check.
    @MainActor static func fallbackPath(dark: Bool) throws {
        for (label, exit, quick, ownID) in [("the reset fails", Int32(1), false, Optional("com.getnorthlight.daydream")),
                                            ("macOS answers with no question", Int32(0), true, Optional("com.getnorthlight.daydream")),
                                            ("not DayDream's own build", Int32(0), false, Optional("com.getnorthlight.daydream.development"))] {
            let model = try makeModel("fallback-\(dark)-\(exit)-\(quick)")
            fake.set(pid: 4242, status: -1744, answer: -1743)
            let page = Page(model, dark: dark)
            _ = page.click("allow.chrome")
            check(wait(3) { model.chromeAccess == .denied }, "B7 \(label): Don't Allow in setup's row: refused")
            page.settle(0.3)
            guideShows = 0; guideDones = 0
            fake.reset(); fake.setReset(exit: exit, quick: quick, ownID: ownID)
            check(page.click("askagain.chrome"), "B7 \(label): Ask again is pressed")
            check(wait(3) { guideShows == 1 && fake.count("openPane") == 1 }, "B7 \(label): the pane opens with the guide beside it",
                  "shows=\(guideShows) panes=\(fake.count("openPane")) \(fake.order)")
            let resets = ownID == "com.getnorthlight.daydream" ? [ownReset] : []
            check(fake.resets == resets, "B7 \(label): resets \(resets.isEmpty ? "nothing" : "only DayDream's own AppleEvents answer")", "\(fake.resets)")
            check(fake.count("ask") == (exit == 0 && ownID == "com.getnorthlight.daydream" ? 1 : 0),
                  "B7 \(label): \(exit == 0 && ownID == "com.getnorthlight.daydream" ? "the one question came back at once, with nothing shown" : "no question")")
            page.settle(0.3)
            check(page.has("askagain.chrome") && model.chromeRowAccess != .allowed, "B7 \(label): the row still says Chrome pages are off")
            if exit == 1 { page.shoot("4b-guide-row") }
            // A second press goes straight to the guide when the reset already failed.
            if exit == 1 {
                fake.reset()
                _ = page.click("askagain.chrome")
                pump(0.3)
                check(fake.resets.isEmpty && guideShows == 2, "B7 the reset failed once: Ask again shows the guide again, no second reset")
            }
            fake.setStatus(0)   // the person turns DayDream › Google Chrome on in System Settings
            check(wait(6) { model.chromeAccess == .allowed }, "B7 \(label): the switch turned on is picked up within seconds, no restart",
                  "\(model.chromeAccess)")
            check(guideDones >= 1, "B7 \(label): the guide shows its check, closes and brings DayDream back")
            page.close()
        }
        // The guide, as the app hosts it: the switch flipping (both frames) and the check.
        let appIcon = NSApp.applicationIconImage
        renderView(ChromeGuideView(step: .turnOn, chromeIcon: nil, appIcon: appIcon, held: false, close: {})
            .background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).padding(14),
                   width: ChromeGuideView.width + 28, name: "14-guide-switch-off", dark: dark)
        renderView(ChromeGuideView(step: .turnOn, chromeIcon: nil, appIcon: appIcon, held: true, close: {})
            .background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).padding(14),
                   width: ChromeGuideView.width + 28, name: "14b-guide-switch-on", dark: dark)
        renderView(ChromeGuideView(step: .done, chromeIcon: nil, appIcon: appIcon, close: {})
            .background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).padding(14),
                   width: ChromeGuideView.width + 28, name: "15-guide-done", dark: dark)
    }

    // MARK: F. Settings › Apps to remember

    /// The Chrome card in Settings matches setup's row and the menu bar (owner 10/5): never asked, Allow (setup's path:
    /// a closed Chrome opens in the background, then macOS asks); refused, "Chrome pages aren't being saved." with Ask
    /// again (the same reset and question); allowed, the Allowed line.
    @MainActor static func settingsCard(dark: Bool) throws {
        typealias C = ChromePagesCard
        check(C.accessButton(.notAsked) == .allow && C.accessButton(.chromeNotRunning) == .allow
              && C.accessButton(.denied) == .askAgain && C.accessButton(.askFailed) == .askAgain
              && C.accessButton(.allowed) == nil && C.accessButton(.checking) == nil && C.accessButton(.unverified) == .tryAgain,
              "F1 the card's button: Allow never asked, Ask again refused, none allowed")
        check(C.accessButtonTitle(.allow) == "Allow" && C.accessButtonTitle(.askAgain) == "Ask again", "F1 its words: Allow, Ask again (never Allow…)")
        check(C.accessText(.denied) == ChromeAccessNotice.line && C.accessText(.askFailed) == ChromeAccessNotice.line
              && C.accessText(.notAsked) == ChromeAccessNotice.line && C.accessText(.allowed) == C.accessLabel,
              "F2 access off: \"Chrome pages aren't being saved.\"; allowed: Chrome access, Allowed")
        check(C.accessHelper(.notAsked) == PermissionChromeRow.primerTypingOff
              && C.accessHelper(.chromeNotRunning) == PermissionChromeRow.primerTypingOff + " " + PermissionChromeRow.opensChromeLine
              && C.accessHelper(.denied) == nil && C.accessHelper(.askFailed) == nil && C.accessHelper(.allowed) == nil,
              "F2 before macOS asks, setup's primer under it; refused or allowed, nothing more")
        let card = source("Sources/MemoryUI/ChromePagesSettings.swift")
        let row = body(of: "private var accessRow: some View", in: card)
        check(!row.contains("Allow…") && !row.contains("offersSystemSettings") && !row.contains("access.buttonTitle"),
              "F3 the card draws no Allow… and no second Open System Settings")
        let settings = source("Sources/MacMemApp/DaydreamSettings.swift")
        let host = body(of: "private var chromePages: some View", in: settings)
        check(host.contains("access: model.chromeRowAccess") && host.contains("allow: { model.askChromeAccessInSetup() }")
              && host.contains("askAgain: { model.askChromeAgain() }"),
              "F4 Settings wires the card to setup's Allow path, the same Ask again, and the row's access (the refusal kept while Chrome is closed)")
        // Behaviour, after setup: the card's Allow with Chrome closed opens Chrome in the background and asks once; its
        // Ask again resets DayDream's own answer, then asks.
        let model = try makeModel("settings-card-\(dark)", finished: true)
        model.setBrowserPages(true)
        check(wait(10) { model.browserPagesSaved && !model.preferencesUnresolved }, "F5 Web pages in Chrome saved on")
        fake.set(pid: nil, status: -1744, answer: -1743, installed: true, opensAs: 4343)
        fake.reset()
        model.askChromeAccessInSetup()
        check(wait(3) { model.chromeAccess == .denied } && fake.count("openChrome") == 1 && fake.count("ask") == 1 && fake.resets.isEmpty,
              "F5 the card's Allow (Chrome closed): Chrome opens in the background, macOS asks once; Don't Allow", "\(fake.order)")
        fake.reset(); fake.set(pid: 4242, status: -1743, answer: 0); fake.setReset()
        model.askChromeAgain()
        check(wait(3) { model.chromeAccess == .allowed } && fake.resets == [ownReset] && fake.count("ask") == 1,
              "F5 the card's Ask again: DayDream's own answer reset, asked again, allowed", "\(fake.order)")
        // Each state, light and dark, with the row open (closed, Allowed hides; a click that's needed shows either way).
        var allows = 0, askAgains = 0, opens = 0
        for (name, access) in [("16-settings-card-notasked", ChromeAccessState.notAsked), ("16b-settings-card-chrome-closed", .chromeNotRunning),
                               ("17-settings-card-refused", .denied), ("18-settings-card-allowed", .allowed)] {
            renderView(ChromePagesCard(on: .constant(true), savedOn: true, access: access, sites: [], enabled: true,
                                       emailSubjects: .constant(true), expanded: .constant(true),
                                       add: { _ in }, remove: { _ in }, allow: { allows += 1 }, openSystemSettings: { opens += 1 },
                                       askAgain: { askAgains += 1 }, checkAccess: {}).frame(width: 560).padding(16),
                       width: 592, name: name, dark: dark)
        }
        check(allows == 0 && askAgains == 0 && opens == 0, "F6 drawing the card asks, resets and opens nothing")
    }

    // MARK: E. The reset

    @MainActor static func resetSafety() {
        typealias R = ChromeAutomationReset
        check(R.tool == "/usr/bin/tccutil" && R.service == "AppleEvents", "E1 the tool is /usr/bin/tccutil, the service AppleEvents only")
        check(R.arguments(ownBundleID: "com.getnorthlight.daydream") == ownReset, "E1 DayDream's own id: reset AppleEvents com.getnorthlight.daydream")
        for other in [nil, "", "com.google.Chrome", "com.apple.Terminal", "com.macmem.app", "com.getnorthlight.daydream.development",
                      "com.getnorthlight.daydream.adhoc", "com.getnorthlight.daydream ", "com.getnorthlight.daydream;rm -rf ~",
                      "COM.GETNORTHLIGHT.DAYDREAM", "com.getnorthlight.daydream\n"] as [String?] {
            check(R.arguments(ownBundleID: other) == nil, "E2 never another app's id: \(String(describing: other))")
        }
        for service in ["Accessibility", "ListenEvent", "All", "ScreenCapture", "SystemPolicyAllFiles", "appleevents"] {
            check(!R.isOwnReset(["reset", service, "com.getnorthlight.daydream"], running: "com.getnorthlight.daydream"),
                  "E3 never another service: \(service)")
        }
        check(R.isOwnReset(ownReset, running: "com.getnorthlight.daydream"), "E4 the live runner accepts exactly the own reset")
        check(!R.isOwnReset(ownReset, running: "com.google.Chrome") && !R.isOwnReset(ownReset, running: nil),
              "E4 ...only while the running app is DayDream itself")
        check(!R.isOwnReset(ownReset + ["com.google.Chrome"], running: "com.getnorthlight.daydream")
              && !R.isOwnReset(["reset", "AppleEvents"], running: "com.getnorthlight.daydream")
              && !R.isOwnReset(["reset", "AppleEvents", "com.google.Chrome"], running: "com.getnorthlight.daydream"),
              "E4 no extra or missing arguments, no other id")
        // This check process isn't DayDream: the live runner refuses before any process starts (tccutil never runs).
        if Bundle.main.bundleIdentifier != "com.getnorthlight.daydream" {
            check(R.runLive(ownReset) == -3, "E5 outside DayDream itself, the live runner refuses the command before starting anything")
        }
        let recovery = source("Sources/MacMemApp/ChromeAccessRecovery.swift")
        let runLive = body(of: "static func runLive(", in: recovery)
        check(runLive.contains("guard isOwnReset(arguments, running: Bundle.main.bundleIdentifier) else { return -3 }")
              && runLive.contains("process.executableURL = URL(fileURLWithPath: tool)") && runLive.contains("process.arguments = arguments")
              && !runLive.contains("/bin/sh") && !runLive.contains("bash"),
              "E5 the live runner checks the command first, runs tccutil directly (no shell)")
        var appCode = ""
        for file in (try? FileManager.default.contentsOfDirectory(atPath: "Sources/MacMemApp")) ?? [] where file.hasSuffix(".swift") {
            let text = source("Sources/MacMemApp/" + file).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            if text.contains("tccutil") { appCode += file + " " }
        }
        check(appCode == "ChromeAccessRecovery.swift ", "E6 the app names tccutil in one file only", appCode)
        let app = source("Sources/MacMemApp/MacMemApp.swift")
        check(app.contains("resetAutomation:{ChromeAutomationReset.runLive($0)}") && app.components(separatedBy: "resetAutomation(").count == 2,
              "E6 the live environment's reset is runLive, called from one place")
        let ask = body(of: "func askChromeAgain()", in: app)
        check(ask.contains("ChromeAutomationReset.arguments(ownBundleID:env.ownBundleID())") && ask.contains("env.resetAutomation(arguments)")
              && ask.range(of: "env.resetAutomation(arguments)")!.lowerBound < ask.range(of: "self.askChromeAccessInSetup()")!.lowerBound,
              "E7 Ask again resets DayDream's own answer first, then asks through setup's Allow path")
    }

    /// 3. Chrome not running at setup: the primer says Allow opens Chrome in the background; Chrome opens only on the
    /// press, then macOS asks right there. Without a press, nothing opens or asks, now or when Chrome comes forward.
    @MainActor static func notRunningPath(dark: Bool) throws {
        let model = try makeModel("closed-\(dark)")
        fake.set(pid: nil, status: -1744, answer: 0, installed: true, opensAs: 4343)
        let page = Page(model, dark: dark)
        check(page.has("allow.chrome") && page.has("chrome.drawing.ask") && model.chromeAccess == .chromeNotRunning,
              "B3 Chrome closed (\(dark ? "dark" : "light")): the row is there with Allow", "\(model.chromeAccess)")
        check(PermissionChromeRow.subtitle(access: model.chromeRowAccess, typing: true, opensChrome: !model.chromeRunning).hasSuffix(PermissionChromeRow.opensChromeLine),
              "B3 its line says Allow opens Chrome in the background to ask")
        page.fits("B3 Chrome closed")
        page.shoot("6-chrome-closed-before")
        page.settle(1.0)
        check(fake.count("openChrome") == 0 && fake.count("ask") == 0 && fake.waitingActivations == 0,
              "B3 nothing opens Chrome or asks before the press, and nothing waits for Chrome to come forward")
        check(page.click("allow.chrome"), "B3 Allow is pressed")
        check(wait(3) { model.chromeAccess == .allowed } && fake.count("openChrome") == 1 && fake.count("ask") == 1,
              "B3 the press opens Chrome in the background once, then macOS asks once, from the press",
              "\(model.chromeAccess) opens=\(fake.count("openChrome")) asks=\(fake.count("ask"))")
        page.close()
        // Chrome that doesn't open: the row says to open it, and nothing asks later.
        let model2 = try makeModel("closed2-\(dark)")
        fake.set(pid: nil, status: -1744, answer: 0, installed: true, opensAs: nil)
        let page2 = Page(model2, dark: dark)
        check(page2.click("allow.chrome"), "B3 Allow is pressed (Chrome won't open)")
        page2.settle(0.5)
        check(model2.chromeAccess == .chromeNotRunning && page2.has("chrome.below") && fake.count("ask") == 0,
              "B3 Chrome didn't open: the line under the row says to open it, then press Allow")
        check(page2.row.map { !PermissionChromeRow.subtitle(access: $0.access, typing: $0.typing, opensChrome: $0.opensChrome).contains(PermissionChromeRow.opensChromeLine) } ?? false,
              "B3 ...and the row no longer says Chrome opens in the background")
        page2.shoot("6b-chrome-didnt-open")
        page2.close()
        fake.setPid(4242)
        check(fake.waitingActivations == 0 && fake.count("ask") == 0, "B3 and when Chrome next comes forward, nothing asks")
    }

    /// 4, 5. Chrome not installed, and Chrome excluded: no row, nothing read or asked.
    @MainActor static func noRowPaths(dark: Bool) throws {
        // No row holds the page here, so both permissions read missing: the Permissions page as a first setup shows it.
        DaydreamOnboarding.readPermissions = { (false, false) }
        defer { DaydreamOnboarding.readPermissions = { (true, true) } }
        let model = try makeModel("none-\(dark)")
        fake.set(pid: nil, status: -1744, installed: false)
        let page = Page(model, dark: dark)
        check(!page.has("card.chrome") && page.page == .permissions, "B4 Chrome not installed (\(dark ? "dark" : "light")): no Chrome row")
        page.shoot("7-chrome-not-installed")
        check(fake.count("ask") == 0 && fake.count("openChrome") == 0 && fake.count("status") == 0, "B4 nothing read, opened or asked")
        page.close()

        let excluded = try makeModel("excluded-\(dark)")
        fake.set(pid: 4242, status: -1744)
        excluded.exclusionPreference.wrappedValue = ChromePageTarget.bundleID
        check(wait(10) { excluded.chromeExcluded && !excluded.preferencesUnresolved }, "B5 Google Chrome excluded (saved)")
        fake.reset()
        let page2 = Page(excluded, dark: dark)
        check(!page2.has("card.chrome"), "B5 Chrome excluded (\(dark ? "dark" : "light")): no Chrome row")
        page2.shoot("8-chrome-excluded")
        check(fake.count("ask") == 0 && fake.count("openChrome") == 0, "B5 nothing opened or asked")
        reminders = 0
        excluded.chromeAccessFromPages(.status(-1743))
        check(reminders == 0 && BrowserHistoryLine.make(recording: true, pagesOn: true, access: .denied, chromeExcluded: true) == .off,
              "B5 excluded: no reminder and no line (nothing is saved from Chrome anyway)")
        page2.close()
    }

    /// 6. Typing off: the primer's other words (the page is still what DayDream needs).
    @MainActor static func typingOffPath(dark: Bool) throws {
        let model = try makeModel("typing-off-\(dark)")
        model.recordSetupChoices(typing: false, chromePages: true)
        fake.set(pid: 4242, status: -1744)
        let page = Page(model, dark: dark)
        check(DaydreamOnboarding.drawnForChecks?.typedText == false && page.has("allow.chrome"),
              "B6 typing off (\(dark ? "dark" : "light")): setup's typing switch is off and the row is there")
        page.shoot("9-typing-off")
        page.close()
    }

    // MARK: C. After setup

    @MainActor static func afterSetup(dark: Bool) throws {
        let model = try makeModel("after-\(dark)", finished: true)
        model.recordSetupChoices(typing: true, chromePages: true)
        model.setBrowserPages(true)
        check(wait(10) { model.browserPagesSaved && !model.preferencesUnresolved }, "C0 Web pages in Chrome saved on")
        model.recordingForChecks = true
        fake.set(pid: 4242, status: -1743)
        model.checkChromeAccess()
        check(wait(3) { model.chromeAccess == .denied }, "C0 a read finds Chrome access refused")
        check(model.presentation.browserHistory == .needsAccess && MenuBarMenu.chromeFixes(model.presentation)
              && MenuBarMenu.chromeFixTitle(model.presentation) == "Ask again",
              "C1 recording, pages on, refused: the menu bar line is \"\(ChromeAccessNotice.line)\" with Ask again")
        // The menu bar panel, as the app hosts it (no window opens: the routes are counters).
        var opened: [String] = []
        let routes = DaydreamMenuBarRoutes(openWindow: { opened.append($0) }, activate: {}, openURL: { _ in }, terminate: {}, reportProblem: { _ in })
        renderView(DaydreamMenuBarPanel(model: model, routes: routes).frame(width: MenuBarMenu.width), width: MenuBarMenu.width, name: "10-menubar-fix", dark: dark)
        let actions = DaydreamMenuBarPanel.actions(model: model, routes: routes)
        // Settings' status card and the toolbar's popover say the same, with the same Ask again.
        let snap = SettingsStatusSnapshot(state: model.presentation.state, issue: model.presentation.issue, canResume: true,
                                          chromeOff: model.presentation.browserHistory == .needsAccess, chromeAskAgain: model.presentation.chromeAskAgain)
        let card = SettingsStatusCardModel(snap, calendar: .current, now: Date())
        check(card.chromeLine == ChromeAccessNotice.line && card.chromeFixTitle == "Ask again" && !card.quiet,
              "C3 Settings: the status card shows the calm line with Ask again (not orange, not quiet)")
        var cardActs: [SettingsStatusAction] = []
        renderView(SettingsStatusCard(snap, act: { cardActs.append($0) }).frame(width: 560).padding(16), width: 592, name: "11-settings-status-fix", dark: dark)
        // Shot with both permissions granted (this check's process has neither), as the person sees it.
        var shown = model.presentation; shown.permissions = PermissionSnapshot(accessibility: true, inputMonitoring: true)
        check(MenuBarMenu.chromeFixes(shown) && MenuBarMenu.chromeFixTitle(shown) == "Ask again", "C3 popover: the same line and Ask again")
        renderView(StatusPopover(state: shown.state, presentation: shown, actions: actions, now: Date()),
                   width: StatusPopover.width, name: "12-popover-fix", dark: dark)
        // The one reminder: the first page read in Chrome while refused, once ever.
        reminders = 0
        model.chromeAccessFromPages(.status(-1743))
        model.chromeAccessFromPages(.status(-1743))
        check(reminders == 1 && ChromeAccessMemory.reminded(), "C4 Chrome used while refused: one reminder, once", "\(reminders)")
        renderView(ChromeReminderView(chromeIcon: nil, fix: {}, close: {}).background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).padding(14), width: ChromeReminderView.width + 28, name: "13-reminder", dark: dark)
        // The reminder's Ask again: the reset, then the question; the person says Don't Allow again: still refused, no
        // guide (they answered), and nothing more asks.
        fake.reset(); fake.set(pid: 4242, status: -1743, answer: -1743); fake.setReset()
        guideShows = 0
        reminderFix?()
        check(wait(3) { fake.count("ask") == 1 && model.chromeAccess == .denied } && fake.resets == [ownReset] && reminderDismissals > 0,
              "C4 the reminder's Ask again resets DayDream's own answer, asks once, and closes", "\(fake.order) \(model.chromeAccess)")
        check(guideShows == 0 && fake.count("openPane") == 0 && model.presentation.browserHistory == .needsAccess,
              "C4 Don't Allow again: still refused, no guide, the line stays")
        check(opened.isEmpty, "C4 nothing opened a window")
        // A new model (a relaunch) with Chrome closed: the refusal is kept, and the line stays.
        let relaunched = try reopen(model, name: "after-\(dark)")
        check(relaunched.chromeLastAnswer == .denied && relaunched.chromeLineAccess == .denied && relaunched.presentation.browserHistory == .needsAccess,
              "C5 relaunched with Chrome closed: the last refusal is kept and the line stays", "\(String(describing: relaunched.chromeLastAnswer))")
        relaunched.chromeAccessFromPages(.status(-1743))
        check(reminders == 1, "C5 the reminder never shows again")
        // The menu bar's Ask again with Chrome closed: the reset, Chrome opens in the background (the press asked for it),
        // macOS asks, Allow: the line goes, with no restart.
        fake.reset(); fake.set(pid: nil, status: -1743, answer: 0, installed: true, opensAs: 4343); fake.setReset()
        DaydreamMenuBarPanel.actions(model: relaunched, routes: routes).fixChrome()
        check(wait(3) { relaunched.chromeAccess == .allowed } && fake.resets == [ownReset] && fake.count("openChrome") == 1 && fake.count("ask") == 1,
              "C6 the menu bar's Ask again (Chrome closed): reset, Chrome opens in the background, one question, allowed",
              "\(relaunched.chromeAccess) \(fake.order)")
        check(relaunched.presentation.browserHistory == .on && !MenuBarMenu.chromeFixes(relaunched.presentation),
              "C6 allowed: the line goes, with no restart")
        // Not asked yet (setup's row skipped): Fix opens setup's Chrome row, never the question itself.
        fake.reset(); fake.set(pid: 4242, status: -1744)
        relaunched.checkChromeAccess()
        check(wait(3) { relaunched.chromeAccess == .notAsked } && relaunched.presentation.browserHistory == .needsAccess
              && MenuBarMenu.chromeFixTitle(relaunched.presentation) == "Fix",
              "C7 not asked: the same calm line, with Fix")
        setupOpened = 0
        relaunched.fixChromeAccess()
        check(relaunched.chromeCardRequested && setupOpened == 1 && fake.count("ask") == 0 && fake.count("openPane") == 0 && fake.resets.isEmpty,
              "C7 Fix (not asked) opens setup's Chrome row, where Allow asks; nothing asks or resets from Fix")
        relaunched.chromeCardRequested = false
        // Typing off, pages on: still said (pages aren't saved); pages off: nothing.
        check(BrowserHistoryLine.make(recording: true, pagesOn: true, access: .denied) == .needsAccess
              && BrowserHistoryLine.make(recording: true, pagesOn: false, access: .denied) == .off
              && BrowserHistoryLine.make(recording: false, pagesOn: true, access: .denied) == .off,
              "C8 the line shows only while recording with Web pages in Chrome on")
        relaunched.recordingForChecks = nil
        model.recordingForChecks = nil
    }

    /// A relaunch: a new app model reading the same app defaults (where the last answer is kept). Its history is a new
    /// scratch one (the first model still holds its own), with Web pages in Chrome saved on again.
    @MainActor static func reopen(_ model: MemoryViewModel, name: String) throws -> MemoryViewModel {
        let memory = root.appendingPathComponent(name + "-relaunch", isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        setenv("MAC_MEM_HOME", memory.path, 1)
        let next = MemoryViewModel()
        guard wait(20, { next.preferencesAvailable && !next.historyOpening }) else { fatal("reopen: history did not open: \(next.status)") }
        next.setBrowserPages(true)
        guard wait(10, { next.browserPagesSaved && !next.preferencesUnresolved }) else { fatal("reopen: pages did not save") }
        fake.set(pid: nil, status: -1743)
        next.chromeAccessEnvironment = fake.environment(setupFinished: { true })
        next.chromeReminder = ChromeAccessReminder(show: { fix in reminders += 1; reminderFix = fix }, dismiss: { reminderDismissals += 1 })
        next.openSetupWindow = { setupOpened += 1 }
        next.chromeGuide = ChromeAccessGuide(show: { guideShows += 1 }, done: { guideDones += 1 }, hide: {})
        fake.setReset()
        next.recordingForChecks = true
        next.checkChromeAccess()
        pump(0.3)
        return next
    }

    @MainActor static func renderView<V: View>(_ view: V, width: CGFloat, name: String, dark: Bool) {
        let window = KeyWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.colorSpace = .sRGB
        let background = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1) })
        let host = NSHostingView(rootView: AnyView(view.background(background).environment(\.colorScheme, dark ? .dark : .light)))
        let size = host.fittingSize
        host.frame = NSRect(x: 0, y: 0, width: width, height: max(size.height, 20))
        window.setContentSize(host.frame.size)
        window.contentView = host
        window.orderFrontRegardless()
        pump(0.5); host.layoutSubtreeIfNeeded(); pump(0.2)
        save(retina(host), name, dark: dark)
        window.contentView = nil; window.close(); pump(0.1)
    }
}
