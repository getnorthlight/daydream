import AppKit
import SwiftUI
import MemoryCore
import MemoryUI

// rc-018 RC3 (package A: lifecycle, restart, focus). The owner's night of 10/8-10/9: the restart raced macOS's own
// "Quit & Reopen / Later" sheet, setup came back behind System Settings (macOS's own Quit & Reopen relaunched DayDream at
// 00:49:31, not DayDream's helper), recording stayed off after a restart, and a System Settings left open filed the drop
// under an old copy. The rules every fix here follows (FIX-PLAN.md, "focus and activation policy"):
// 1. While setup is unfinished, setup is the only visible DayDream window (`SetupFocus.holdMemory`).
// 2. DayDream activates itself only on a press in DayDream, an open, or a hand-back (`SetupFocus.handBack`,
//    `SetupFocus.bringSetupForward` after a relaunch it caused).
// 3. Every activation targets setup: activate, then setup's window key and front. Never every window.
// 4. A restart waits while System Settings shows a sheet (`SelfRestartGate`), with its context saved first
//    (`SetupRelaunchContext`); a background restart opens with `open -g` and shows no window.
// 5. After a setup relaunch, setup opens directly, key and in front, at the saved frame and on the saved page.
// 8. A read that activation triggers applies only after mouse-up, or 300 ms (`SetupFocus.afterMouseUp`).
// 9. Nothing activates, moves or restarts during a press, a drag, a Chrome question or a password prompt.

/// What DayDream saves just before it quits to restart, so the copy that opens next puts the person back where they were
/// (rule 5): setup's page, its frame and screen, and whether recording was wanted. Read once at launch and removed;
/// older than `maxAge`, it is ignored (an ordinary launch later never jumps into setup). Saved by DayDream's own restart
/// and by any quit while setup is open and unfinished (macOS's own Quit & Reopen relaunches DayDream too).
struct SetupRelaunchContext: Codable, Equatable {
    enum Reason: String, Codable {
        /// Setup was open: the next launch opens setup directly (no memory window, no "Getting ready…").
        case setup
        /// "Keys not arriving" while recording: the next launch shows no window (`open -g`).
        case background
        /// A restart from a permission page outside setup (the permissions window, Settings › Permissions): an ordinary
        /// launch, recording again when it was wanted.
        case window
    }
    var reason: Reason
    /// `DaydreamOnboardingPage.rawValue`; nil outside setup.
    var page: Int?
    /// Setup's window frame and its screen's frame (AppKit global coordinates: x, y, width, height).
    var frame: [Double]?
    var screen: [Double]?
    /// Recording was on or wanted (or a permission comeback was armed): the next launch records again.
    var recording: Bool
    /// When it was saved (seconds since 1970).
    var savedAt: Double

    static let key = "DaydreamRelaunchContextV1"
    /// Younger than this, it is the relaunch's; older, an ordinary launch.
    static let maxAge: TimeInterval = 60

    var setupPage: DaydreamOnboardingPage? { page.flatMap(DaydreamOnboardingPage.init(rawValue:)) }
    var setupFrame: CGRect? { Self.rect(frame) }
    var screenFrame: CGRect? { Self.rect(screen) }

    func save(_ defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
    /// The saved context, removed as it is read; nil when there is none, it can't be read, or it is older than `maxAge`
    /// (or more than 5 s in the future: a clock that moved).
    static func consume(_ defaults: UserDefaults, now: Date = Date()) -> SetupRelaunchContext? {
        guard let data = defaults.object(forKey: key) as? Data else { defaults.removeObject(forKey: key); return nil }
        defaults.removeObject(forKey: key)
        guard let context = try? JSONDecoder().decode(SetupRelaunchContext.self, from: data) else { return nil }
        let age = now.timeIntervalSince1970 - context.savedAt
        return age >= -5 && age <= maxAge ? context : nil
    }
    static func clear(_ defaults: UserDefaults) { defaults.removeObject(forKey: key) }

    static func values(_ rect: CGRect?) -> [Double]? {
        rect.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
    }
    static func rect(_ values: [Double]?) -> CGRect? {
        guard let v = values, v.count == 4, v[2] > 0, v[3] > 0 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    /// Where setup's window goes on today's screens (`screens`: each screen's frame and visible frame): the saved frame
    /// when it still fits on a screen's visible frame, else moved onto the saved screen (or the screen holding most of
    /// it, else the first) and kept inside its visible frame. The size is the window's own (`size`); setup never resizes.
    static func placed(saved: CGRect, size: CGSize, savedScreen: CGRect?, screens: [(frame: CGRect, visible: CGRect)]) -> CGRect {
        var rect = CGRect(origin: saved.origin, size: size)
        guard !screens.isEmpty else { return rect }
        if screens.contains(where: { $0.visible.contains(rect) }) { return rect }
        let target = screens.first { savedScreen != nil && $0.frame == savedScreen! }
            ?? screens.max { $0.visible.intersection(rect).area < $1.visible.intersection(rect).area }
            ?? screens[0]
        let room = target.visible
        rect.origin.x = min(max(rect.minX, room.minX), max(room.minX, room.maxX - rect.width))
        rect.origin.y = min(max(rect.minY, room.minY), max(room.minY, room.maxY - rect.height))
        return rect
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

/// A1/A2: when DayDream's own restart may go now. While System Settings shows a sheet (macOS's "Quit & Reopen / Later")
/// it waits: macOS's Quit & Reopen, if pressed, is the restart; Later lets it go. It never goes during a press, a drag,
/// a Chrome question or a password window (rule 9). Pure, so the checks pin it.
/// rc-018 RC3 review (FIX-PLAN A1, "after the sheet is gone or after about 10 s"): macOS shows its sheet for every
/// running app whose Input Monitoring is turned on, but it belongs to System Settings' privacy extension
/// (SecurityPrivacyExtension relaunched DayDream at 00:49:31), so it may never read as System Settings' own sheet. A sheet
/// never seen is not "no sheet": the restart then waits `limit`, as for one that can't be read. A sheet left up waits
/// `limit` too (the line says DayDream restarts by itself; a later Quit & Reopen lands on setup through `willQuit`).
enum SelfRestartGate {
    enum Decision: Equatable { case now, wait }
    struct Inputs: Equatable {
        /// A sheet over System Settings (or the window server's alert of its privacy extension): true, false, or nil when
        /// it can't be read (Accessibility not allowed and nothing on screen).
        var sheetUp: Bool?
        var authOnScreen = false
        /// The left button is down, or a card drag runs.
        var pressing = false
        var dragging = false
        /// Chrome's question is in flight (asking, opening Chrome to ask, clearing the answer to ask again).
        var chromeAsking = false
        /// Since the restart was decided.
        var waited: TimeInterval = 0
        /// A sheet was seen since then (it went: the person chose Later).
        var sheetSeen = false
    }
    /// The restart goes after about this long whatever the sheet reads (up, never seen, or unreadable).
    static let limit: TimeInterval = 10

    static func decide(_ i: Inputs) -> Decision {
        if i.pressing || i.dragging || i.chromeAsking || i.authOnScreen { return .wait }
        // The sheet came and went (Later, or macOS's Quit & Reopen already quitting DayDream): now.
        if i.sheetUp == false && i.sheetSeen { return .now }
        // Up, never seen (it may be one this read can't see) or unreadable: about 10 s after the restart was decided.
        return i.waited >= limit ? .now : .wait
    }
}

/// A6: DayDream restarts itself at most `limit` times in `window` (any reason). Past that, setup and the permission pages
/// offer Quit & Reopen instead, and a recorder whose keys don't arrive stops with its reason (Start goes to Quit &
/// Reopen). Kept in UserDefaults: a restart loop across launches is still a loop.
enum SelfRestartBudget {
    static let key = "DaydreamSelfRestartsV1"
    static let limit = 2
    static let window: TimeInterval = 1800
    static func recent(_ defaults: UserDefaults, now: Date) -> [Double] {
        let all = (defaults.object(forKey: key) as? [Double]) ?? []
        let t = now.timeIntervalSince1970
        return all.filter { t - $0 >= -5 && t - $0 < window }
    }
    static func allowed(_ defaults: UserDefaults, now: Date = Date()) -> Bool { recent(defaults, now: now).count < limit }
    static func note(_ defaults: UserDefaults, now: Date = Date()) {
        defaults.set(recent(defaults, now: now) + [now.timeIntervalSince1970], forKey: key)
    }
}

/// A8: System Settings opened before this copy of DayDream was installed (or replaced) keeps what it read of the old copy,
/// and files a card dropped now under that old copy. Setup then says so, with a Quit that the person presses.
enum SystemSettingsAge {
    static let line = "Quit System Settings and open it again."
    static let quitTitle = "Quit"
    /// `bundleDates`: when this app was added to its folder, made, and last changed (any may be unknown).
    static func stale(settingsLaunched: Date?, bundleDates: [Date?]) -> Bool {
        guard let launched = settingsLaunched, let installed = bundleDates.compactMap({ $0 }).max() else { return false }
        return launched < installed
    }
    static func bundleDates(_ url: URL) -> [Date?] {
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey])
        return [values?.addedToDirectoryDate, values?.creationDate, values?.contentModificationDate]
    }
}

/// A9: rel-018's leftovers. SwiftUI's old card drag (0.1.7) copied the whole app into
/// ~/Library/Caches/com.apple.SwiftUI.Drag-<UUID>/DayDream.app on every drag. At launch, off the main thread, DayDream
/// removes those folders, and only those: a folder named that way whose only item is an app with DayDream's bundle ID.
enum DragCopyLeftovers {
    static let prefix = "com.apple.SwiftUI.Drag-"
    /// The folders `clean` would remove under `caches`.
    static func found(caches: URL, fileManager: FileManager = .default) -> [URL] {
        guard let folders = try? fileManager.contentsOfDirectory(at: caches, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return [] }
        return folders.filter { folder in
            guard folder.lastPathComponent.hasPrefix(prefix),
                  let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let items = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return false }
            let real = items.filter { $0.lastPathComponent != ".DS_Store" }
            guard real.count == 1, let app = real.first, app.pathExtension == "app",
                  (try? app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let id = Bundle(url: app)?.bundleIdentifier else { return false }
            return id == DaydreamIdentity.bundleID || id.hasPrefix(DaydreamIdentity.bundleID + ".")
        }
    }
    /// Removes them; returns how many went.
    @discardableResult static func clean(caches: URL, fileManager: FileManager = .default) -> Int {
        var removed = 0
        for folder in found(caches: caches, fileManager: fileManager) where (try? fileManager.removeItem(at: folder)) != nil { removed += 1 }
        return removed
    }
    /// At launch, once, off the main thread.
    static func cleanAtLaunch() {
        let caches = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        DispatchQueue.global(qos: .utility).async {
            let removed = clean(caches: caches)
            if removed > 0 { RecordingLog.note("Removed \(removed) leftover drag copy folder(s) of DayDream.") }
        }
    }
}

/// Setup's window and the memory window, as the focus policy needs them. One per app (`shared`); the checks reset it and
/// stand in its seams (`activate`, the reads), so nothing here ever activates or reads System Settings in a check.
@MainActor final class SetupFocus {
    static let shared = SetupFocus()

    /// Setup's window while it is open, its page, and whether this setup is unfinished (a first setup).
    weak var setupWindow: NSWindow?
    private(set) var page: DaydreamOnboardingPage?
    private(set) var unfinished = false
    /// The permissions window ("DayDream permissions") is open, or Settings › Permissions shows.
    var permissionsWindowShowing = 0
    /// The permissions window itself while it is open: after setup, "Turn on…" opens it beside System Settings (B9), so a
    /// grant made from it hands back to it (`handBack`), as one made from setup hands back to setup.
    weak var permissionsWindow: NSWindow?
    /// The relaunch this launch is (`DaydreamLaunchSession` consumed it), and whether its setup placement ran.
    var relaunch: SetupRelaunchContext?
    private var relaunchPlaced = false
    /// The memory window held hidden while setup is unfinished (rule 1), and whether the next one is held as it appears.
    private weak var heldMemory: NSWindow?
    private(set) var holdsMemory = false
    /// DayDream is quitting: nothing is revealed or activated any more.
    var quitting = false
    /// Permissions handed back already (each once per run).
    private var handedBack: Set<String> = []

    // Seams (the checks stand in their own; nothing in a check activates or reads another app: check builds start quiet).
    #if DEVELOPMENT_SOURCE_CHECKS
    var activate: () -> Void = {}
    /// Orders a window in: `key` true makes it key too.
    var front: (NSWindow, _ key: Bool) -> Void = { _, _ in }
    var mouseDown: () -> Bool = { false }
    var dragging: () -> Bool = { PermissionCardDrag.shared.dragging }
    var settingsFrontmost: () -> Bool = { false }
    var settingsSheetUp: () -> Bool? = { false }
    var authOnScreen: () -> Bool = { false }
    #else
    var activate: () -> Void = { NSApp.activate() }
    var front: (NSWindow, _ key: Bool) -> Void = { window, key in
        if key {
            window.makeKeyAndOrderFront(nil)
            // macOS can turn the activation down while another app is in front: setup is in front all the same.
            window.orderFrontRegardless()
        } else { window.orderFront(nil) }
    }
    var mouseDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    var dragging: () -> Bool = { PermissionCardDrag.shared.dragging }
    var settingsFrontmost: () -> Bool = { SystemSettingsRead.frontmost() }
    var settingsSheetUp: () -> Bool? = { SystemSettingsRead.sheetUp() }
    var authOnScreen: () -> Bool = { SystemSettingsRead.authOnScreen() }
    #endif
    /// Chrome's question is in flight (the app model sets it).
    var chromeAsking: () -> Bool = { false }
    /// Every activation made (the checks count them): its reason.
    private(set) var activations: [String] = []

    init() {}

    // MARK: Setup's window

    /// Setup's window appeared (or its page changed).
    func setupShown(_ window: NSWindow?, page: DaydreamOnboardingPage, unfinished: Bool) {
        if let window { setupWindow = window }
        self.page = page
        self.unfinished = unfinished
    }
    /// Setup's window closed: an unfinished setup closed is "later", and the memory window shows again (nothing vanishes).
    func setupClosed() {
        page = nil
        setupWindow = nil
        if !quitting { revealMemory(activate: false) }
    }
    /// Setup finished (Start Recording, Done): the memory window appears (rule 1), in front.
    func setupFinished() {
        unfinished = false
        revealMemory(activate: true)
    }
    /// A permission page shows: setup's Permissions page, the permissions window, or Settings › Permissions.
    var permissionPageShowing: Bool { page == .permissions || permissionsWindowShowing > 0 }

    // MARK: The memory window (rule 1)

    /// From launch: the memory window is held hidden as it appears (a setup relaunch, a first setup, a background
    /// restart), until `revealMemory`.
    func holdMemoryAtLaunch() { holdsMemory = true }
    /// The memory window appeared while held: out of sight (never drawn on screen).
    func memoryWindowAppeared(_ window: NSWindow) {
        guard holdsMemory, heldMemory !== window else { return }
        heldMemory = window
        window.alphaValue = 0
        DispatchQueue.main.async { [weak window] in
            MainActor.assumeIsolated {
                guard let window, SetupFocus.shared.holdsMemory, SetupFocus.shared.heldMemory === window else { return }
                window.orderOut(nil)
                window.alphaValue = 1
            }
        }
    }
    /// Shows the held memory window (setup finished or closed, an open from the Dock or the menu bar, nothing to set up).
    /// True when there was one to show.
    @discardableResult func revealMemory(activate: Bool) -> Bool {
        guard holdsMemory else { return false }
        holdsMemory = false
        guard let window = heldMemory else { return false }
        heldMemory = nil
        window.alphaValue = 1
        if activate {
            activations.append("memory")
            self.activate()
        }
        front(window, true)
        return true
    }
    /// A background restart (`SetupRelaunchContext.Reason.background`): no window shows until the person opens one.
    var quietLaunch: Bool { relaunch?.reason == .background }
    /// An open from the Dock while the memory window is held: setup comes forward while it is open, else the memory
    /// window shows. True when it was handled here.
    func reopenFromDock() -> Bool { reopen("dock") }
    /// Rule 1 and 3 for every open (review 10/9: Open DayDream in the menu bar showed the held memory window over an
    /// unfinished setup): the Dock, the menu bar panel and the app menu bring setup forward while the memory window is
    /// held and setup is open; else the held memory window shows. True when it was handled here.
    func reopen(_ reason: String) -> Bool {
        guard holdsMemory else { return false }
        if setupWindow != nil { bringSetupForward(reason); return true }
        return revealMemory(activate: true)
    }
    /// The memory window held hidden now (the checks read it).
    var heldMemoryWindow: NSWindow? { heldMemory }

    // MARK: Activation (rules 2, 3, 9)

    /// Rule 3: DayDream comes forward with setup as its key window; never every window. Waits while the person presses,
    /// drags, Chrome asks or a password window is up (rule 9), up to `maxWait`, then gives up.
    func bringSetupForward(_ reason: String, maxWait: TimeInterval = 5) {
        bringForward(reason, maxWait: maxWait) { [weak self] in self?.setupWindow }
    }
    /// Rule 3 for the window `target` reads at each attempt (setup's, or after setup the permissions window).
    private func bringForward(_ reason: String, maxWait: TimeInterval, target: @escaping () -> NSWindow?) {
        let until = Date().addingTimeInterval(maxWait)
        func attempt() {
            guard !quitting, let window = target() else { return }
            if mouseDown() || dragging() || chromeAsking() || authOnScreen() {
                guard Date() < until else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { attempt() } }
                return
            }
            activations.append(reason)
            activate()
            front(window, true)
        }
        attempt()
    }

    /// A5: a card's permission read Allowed while System Settings is in front with no sheet and no password window:
    /// setup comes forward as key, once per permission, however the drag guide ended. Not when that permission needs
    /// DayDream to reopen (macOS shows its Quit & Reopen sheet; the restart brings setup forward). True when it did.
    /// After setup (setup closed), the permissions window is the one handed back to (B9's "Turn on…"), once per
    /// permission too; with neither open, nothing comes forward.
    /// Review 10/9: the read that turns a permission Allowed may land while the password window is still closing, System
    /// Settings' sheet is still up or System Settings isn't in front yet. The hand-back then waits for that to clear (read
    /// again every 0.1 s, up to `retryFor`) while the permission still reads Allowed (`stillAllowed`), instead of never
    /// coming (the owner's "setup wasn't in front"). One wait per permission.
    @discardableResult func handBack(_ permission: String, needsReopen: Bool, stillAllowed: @escaping () -> Bool = { true },
                                     retryFor: TimeInterval = 5) -> Bool {
        let until = Date().addingTimeInterval(retryFor), generation = handBackGeneration
        func attempt() -> HandBackAttempt {
            guard generation == handBackGeneration, !quitting else { return .gone }
            let toSetup = setupWindow != nil
            let key = (toSetup ? "" : "window.") + permission
            guard !needsReopen, toSetup || (permissionsWindowShowing > 0 && permissionsWindow != nil), !handedBack.contains(key) else { return .gone }
            guard settingsFrontmost(), settingsSheetUp() == false, !authOnScreen() else { return .blocked }
            handBackNow(permission, key: key, toSetup: toSetup)
            return .done
        }
        func retry() {
            guard generation == handBackGeneration else { return }
            guard Date() < until, stillAllowed(), attempt() == .blocked else { handBackWaiting.remove(permission); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { retry() } }
        }
        let result = attempt()
        if result == .blocked, handBackWaiting.insert(permission).inserted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { retry() } }
        }
        return result == .done
    }
    private enum HandBackAttempt { case done, gone, blocked }
    /// Permissions whose hand-back waits for System Settings to be in front with no sheet or password window.
    private var handBackWaiting: Set<String> = []
    private var handBackGeneration = 0
    private func handBackNow(_ permission: String, key: String, toSetup: Bool) {
        handedBack.insert(key)
        if toSetup { bringSetupForward("handBack." + permission); return }
        bringForward("handBack.window." + permission, maxWait: 5) { [weak self] in
            guard let self, self.permissionsWindowShowing > 0 else { return nil }
            return self.permissionsWindow
        }
    }
    /// The permissions window read a new snapshot: Accessibility turned from off to Allowed hands back to it (`handBack`;
    /// `needsReopen`: DayDream must reopen now, as setup's `relaunchPending`). Input Monitoring never does: macOS answers
    /// that grant with its Quit & Reopen sheet, and the restart (or the person's Later) follows it.
    func permissionsWindowRead(from old: PermissionSnapshot, to new: PermissionSnapshot, needsReopen: Bool,
                               stillAllowed: @escaping () -> Bool = { true }) {
        if old.accessibility == false && new.accessibility == true { handBack("accessibility", needsReopen: needsReopen, stillAllowed: stillAllowed) }
    }

    /// Rule 5: the page a setup relaunch goes back to, once.
    private var relaunchPageTaken = false
    func takeRelaunchPage() -> DaydreamOnboardingPage? {
        guard !relaunchPageTaken, let context = relaunch, context.reason == .setup else { return nil }
        relaunchPageTaken = true
        return context.setupPage
    }
    /// Rule 5: a setup relaunch puts setup's window where it was (frame and screen) and brings it forward, once.
    func placeAfterRelaunch(_ window: NSWindow, screens: [(frame: CGRect, visible: CGRect)] = NSScreen.screens.map { ($0.frame, $0.visibleFrame) }) {
        setupWindow = window
        guard !relaunchPlaced, let context = relaunch, context.reason == .setup else { return }
        relaunchPlaced = true
        if let saved = context.setupFrame {
            let frame = SetupRelaunchContext.placed(saved: saved, size: window.frame.size, savedScreen: context.screenFrame, screens: screens)
            window.setFrameOrigin(frame.origin)
        }
        bringSetupForward("relaunch")
    }

    /// Rule 8: a read that activation triggered runs once the left button is up (at most `limit` later), so a press that
    /// brought DayDream forward never lands on a control that changed under it.
    func afterMouseUp(limit: TimeInterval = 0.3, _ work: @escaping () -> Void) {
        let until = Date().addingTimeInterval(limit)
        func attempt() {
            if mouseDown() && Date() < until {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { MainActor.assumeIsolated { attempt() } }
                return
            }
            work()
        }
        attempt()
    }

    /// The context a setup restart saves (`SetupRelaunchContext`), from setup's window as it is now; nil when setup isn't
    /// open and unfinished.
    func setupContext(recording: Bool, now: Date = Date()) -> SetupRelaunchContext? {
        guard unfinished, let page, let window = setupWindow else { return nil }
        return SetupRelaunchContext(reason: .setup, page: page.rawValue, frame: SetupRelaunchContext.values(window.frame),
                                    screen: SetupRelaunchContext.values(window.screen?.frame), recording: recording,
                                    savedAt: now.timeIntervalSince1970)
    }

    /// No titled DayDream window is on screen (the menu bar's panel and the status item don't count).
    static func noWindowOpen(_ given: [NSWindow]? = nil) -> Bool {
        let windows = given ?? NSApp?.windows ?? []
        return !windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) && $0.alphaValue > 0 }
    }

    /// The checks: a fresh state with quiet seams.
    func resetForChecks() {
        setupWindow = nil; page = nil; unfinished = false; permissionsWindowShowing = 0; permissionsWindow = nil; relaunch = nil; relaunchPlaced = false
        heldMemory = nil; holdsMemory = false; quitting = false; handedBack = []; activations = []; relaunchPageTaken = false
        handBackWaiting = []; handBackGeneration += 1
        activate = {}; front = { _, _ in }; mouseDown = { false }; dragging = { false }; settingsFrontmost = { false }; settingsSheetUp = { false }
        authOnScreen = { false }; chromeAsking = { false }
    }
}

/// Reads the window a view is in, as it moves into it (setup's window, the memory window).
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void
    final class Reader: NSView {
        var found: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { found?(window) } }
    }
    func makeNSView(context: Context) -> Reader { let view = Reader(); view.found = found; return view }
    func updateNSView(_ view: Reader, context: Context) { view.found = found }
}

/// The Live Test copy's menu bar mark (owner 10/9: the real DayDream was quit instead of the Live Test because their
/// menu bar icons were the same): "TEST" beside the icon, only in a Live Test copy (Info.plist `DaydreamLiveTest`, or a
/// build with `DAYDREAM_LIVETEST`). Every other build draws the icon alone, as before.
enum LiveTestMark {
    static let text = "TEST"
    static func shown(info: [String: Any]? = Bundle.main.infoDictionary) -> Bool {
        #if DAYDREAM_LIVETEST
        return true
        #else
        return info?["DaydreamLiveTest"] as? Bool == true
        #endif
    }
    static let current = shown()
    /// The mark with "TEST" to its right, one template image (18 pt high), cached per mark.
    @MainActor static func compose(_ mark: NSImage) -> NSImage {
        let key = ObjectIdentifier(mark)
        if let cached = composed[key] { return cached }
        let font = NSFont.systemFont(ofSize: 9, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let text = NSAttributedString(string: Self.text, attributes: attributes)
        let size = text.size()
        let width = ceil(mark.size.width + 3 + size.width)
        let image = NSImage(size: NSSize(width: width, height: mark.size.height), flipped: false) { _ in
            mark.draw(in: NSRect(origin: .zero, size: mark.size))
            text.draw(at: NSPoint(x: mark.size.width + 3, y: ((mark.size.height - size.height) / 2).rounded()))
            return true
        }
        image.isTemplate = true
        composed[key] = image
        return image
    }
    @MainActor private static var composed: [ObjectIdentifier: NSImage] = [:]
}

/// A1/A6: what DayDream's own restart reads before it goes. `.live` reads System Settings (Accessibility, only once it is
/// allowed), the window server, the mouse and the open windows; check builds read nothing (no sheet, nothing pressed,
/// every window allows it) unless a check stands in its own.
@MainActor struct SelfRestartReads {
    var sheetUp: () -> Bool?
    var authOnScreen: () -> Bool
    var pressing: () -> Bool
    var dragging: () -> Bool
    /// A permission page shows (setup's Permissions page, the permissions window, Settings › Permissions), or no window
    /// is open at all.
    var windowsAllow: (MemoryViewModel) -> Bool

    static var live: SelfRestartReads {
        #if DEVELOPMENT_SOURCE_CHECKS
        SelfRestartReads(sheetUp: { false }, authOnScreen: { false }, pressing: { false }, dragging: { PermissionCardDrag.shared.dragging },
                         windowsAllow: { _ in true })
        #else
        SelfRestartReads(sheetUp: { SystemSettingsRead.sheetUp() }, authOnScreen: { SystemSettingsRead.authOnScreen() },
                         pressing: { NSEvent.pressedMouseButtons & 1 != 0 }, dragging: { PermissionCardDrag.shared.dragging },
                         windowsAllow: { model in
                             SetupFocus.shared.permissionPageShowing || (model.settingsPresented && model.settingsSection == "Permissions")
                                 || SetupFocus.noWindowOpen()
                         })
        #endif
    }
}
