import SwiftUI
import AppKit
import Combine
import MemoryUI

// The app menus (plan §7, keyboard ownership). Every modifier shortcut of the app is bound here and
// nowhere else (scripts/check_shortcuts.py); each (key, modifiers) pair appears once
// (scripts/dd-app-menu-checks.swift walks the installed NSApp.mainMenu for duplicates).
//
// - Menu commands reach the surfaces through `ActivityBrowser.send(_:)`: the Focus List handles them
//   while Recall is hidden, Recall while it is visible. Titles and enabled states read
//   `ActivityBrowser.commandContext`, which the visible surface writes. With no memory shell mounted
//   (`ShellPresence`: the window is closed) nothing receives them, so Go, View and Moment are disabled
//   and ⌘K / ⌘F open the window.
// - Plain keys (↑ ↓ Return Esc, ⌘C in the Focus List, ⌥Return in Recall) stay with the key router and
//   the Recall field: nothing here binds them.
// - Start, Resume and Stop Recording have no key equivalents; ⌘P (Pause for ▸ 15 Minutes) is the only one
//   in the Recording menu and is enabled only while recording.
//
// `AppCommands` (the scene's `.commands`) is inside `#if !DEVELOPMENT_SOURCE_CHECKS` with the scenes.
// The menu content (`DaydreamCommands` and its views) is outside it on purpose: the APP-recipe check
// installs exactly these menus in a check app and walks the real main menu. None of it is `@main`.

#if !DEVELOPMENT_SOURCE_CHECKS
/// The memory scene's commands.
struct AppCommands: Commands {
    @ObservedObject var session: DaydreamLaunchSession
    var body: some Commands {
        // Starts DayDream's own log for Report a Problem once the app model exists (idempotent; memory only).
        let _ = ReportProblemLog.attach(session.model)
        // The Dock's Quit, log out, restart, shut down and Sparkle's installer quit through AppQuit too, so they
        // work while Settings is open (idempotent; installed once launching has finished).
        let _ = AppQuit.installQuitEventHandler()
        DaydreamCommands(model: session.model)
    }
}
#endif

/// Every menu the app adds or replaces. `model` is nil in the isolated preview and the signed-writer
/// acceptance mode: the same menus then show, disabled.
struct DaydreamCommands: Commands {
    let model: MemoryViewModel?

    var body: some Commands {
        // Keeps View ▸ Refresh (Option) and Go ▸ Find… out of sight; their keys still work (DaydreamMenuTidy).
        let _ = DaydreamMenuTidy.install()
        CommandGroup(after: .appInfo) {
            if let model { UpdateMenu(updates: model.updates) }
        }
        DaydreamAppMenuCommands(model: model)
        // File: no New Window (⌘N is removed) and no Print / Page Setup (⌘P is Pause for ▸ 15 Minutes).
        CommandGroup(replacing: .newItem) { DaydreamSetupCommand(model: model) }
        CommandGroup(replacing: .printItem) {}
        CommandGroup(after: .toolbar) { DaydreamViewCommands(model: model, browser: model?.activity ?? DaydreamCommands.inert) }
        CommandMenu("Go") { DaydreamGoCommands(model: model, browser: model?.activity ?? DaydreamCommands.inert) }
        CommandMenu("Moment") { DaydreamMomentCommands(browser: model?.activity ?? DaydreamCommands.inert) }
        CommandMenu("Recording") { DaydreamRecordingCommands(model: model) }
        CommandGroup(before: .windowList) { DaydreamOpenCommand(available: model != nil) }
        CommandGroup(replacing: .help) { DaydreamReportProblemCommand(model: model) }
    }

    /// Stands in for the browser when there is no model: nothing selected, no search, every command off.
    @MainActor static let inert = ActivityBrowser(phase: .ready)
}

/// The DayDream menu's own items: Settings… and Quit (a builder holds at most ten groups, so they are one here).
struct DaydreamAppMenuCommands: Commands {
    let model: MemoryViewModel?
    var body: some Commands {
        CommandGroup(replacing: .appSettings) { DaydreamSettingsCommand(model: model) }
        // AppKit's own Quit does nothing while a sheet (Settings) is open: this one closes it and quits.
        CommandGroup(replacing: .appTermination) { DaydreamQuitCommand(model: model) }
    }
}

// MARK: - Menu tidy

/// Two items stay out of sight but keep their keys (declutter): Go ▸ Find… ⌘F repeats Search… ⌘K and is never
/// shown; View ▸ Refresh ⇧⌘R is a maintenance command, shown only while Option is held as the menu opens. A
/// hidden item still answers its key equivalent (`allowsKeyEquivalentWhenHidden`). SwiftUI owns and may rebuild
/// and update the items, so this runs when a menu of the menu bar starts tracking and again whenever an item is
/// added or changed.
@MainActor enum DaydreamMenuTidy {
    /// (menu, item) pairs never shown.
    static let hidden: [(menu: String, title: String)] = [("Go", "Find…")]
    /// (menu, item) pairs shown only with Option held.
    static let optionOnly: [(menu: String, title: String)] = [("View", "Refresh")]
    private static var observers: [NSObjectProtocol] = []
    /// Whether Option was held when the menu bar last began tracking (or what `apply` was last given).
    private static var option = false
    private static var applying = false

    static func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // queue nil: the block runs on the posting thread, before the menu draws.
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { apply(option: NSEvent.modifierFlags.contains(.option)) }
        })
        // SwiftUI adds or updates its items when a menu opens, after tracking began: hide them again.
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated { apply(option: option) }
            })
        }
    }

    /// Hides the items in `main` (the app's main menu by default); `option` shows the Option-only ones.
    static func apply(option: Bool, main: NSMenu? = nil) {
        self.option = option
        // Setting isHidden posts didChangeItem, which calls back here.
        guard !applying, let main = main ?? NSApp.mainMenu else { return }
        applying = true
        defer { applying = false }
        for top in main.items {
            guard let menu = top.submenu else { continue }
            for item in menu.items {
                if hidden.contains(where: { $0.menu == top.title && $0.title == item.title }) {
                    if !item.allowsKeyEquivalentWhenHidden { item.allowsKeyEquivalentWhenHidden = true }
                    if !item.isHidden { item.isHidden = true }
                } else if optionOnly.contains(where: { $0.menu == top.title && $0.title == item.title }) {
                    if !item.allowsKeyEquivalentWhenHidden { item.allowsKeyEquivalentWhenHidden = true }
                    if item.isHidden == option { item.isHidden = !option }
                }
            }
        }
    }
}

// MARK: - Main window

/// Brings the memory window forward, opening one only when none is open (a WindowGroup's `openWindow(id:)`
/// always adds another window), then activates the app.
@MainActor enum DaydreamMainWindow {
    static let id = "memory"
    /// SwiftUI names a WindowGroup's windows `<id>-AppWindow-<n>`.
    static func isMain(_ window: NSWindow) -> Bool {
        (window.identifier?.rawValue.hasPrefix(id + "-") ?? false) && (window.isVisible || window.isMiniaturized)
    }
    static func show(_ openWindow: OpenWindowAction) {
        if let window = NSApp.windows.first(where: isMain) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: id)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    /// The menu bar panel's routes in the app: its Search…, Open DayDream, DayDream Settings… and today line bring the
    /// memory window forward through `show` (never a second window over the same browser, where every menu
    /// command would run once per window); other windows (onboarding) open by id.
    static func menuBarRoutes(_ openWindow: OpenWindowAction) -> DaydreamMenuBarRoutes {
        DaydreamMenuBarRoutes(openWindow: { target in
            if target == id { UsageReport.opened("menu_bar"); show(openWindow) } else { openWindow(id: target) }
        })
    }
}

// MARK: - Sheets

/// Whether a sheet (Settings, the correction sheet, a Forget or Exclude confirmation) is attached to the memory
/// window. The key router already ignores keys then (DaydreamKeyRouter: `attachedSheet == nil`); the menus read
/// this so ⌘K, ⌘[ ⌘] ⌘T, ⌘↩, ⇧⌘C, ⌘R and ⇧⌘R don't act on the window behind the sheet either. Settings… and
/// Open DayDream stay available.
@MainActor final class DaydreamSheetWatch: ObservableObject {
    static let shared = DaydreamSheetWatch()
    @Published private(set) var onMainWindow = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willBeginSheetNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                // The sheet is not attached yet when this posts: the window it begins on is the answer.
                if let window = note.object as? NSWindow, DaydreamMainWindow.isMain(window) { DaydreamSheetWatch.shared.set(true) }
            }
        })
        // A sheet that ends is still attached while this posts, and a window closed with its sheet attached posts
        // no didEndSheet at all: re-read on the next turn after either, so the flag never outlives the sheet.
        for name in [NSWindow.didEndSheetNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { DaydreamSheetWatch.shared.recompute() } }
            })
        }
    }

    /// Re-reads the open memory windows' attached sheets.
    func recompute() {
        set(NSApp.windows.contains {
            DaydreamMainWindow.isMain($0) && $0.attachedSheet != nil && ($0.isVisible || $0.isMiniaturized)
        })
    }
    private func set(_ value: Bool) { if onMainWindow != value { onMainWindow = value } }
}

// MARK: - App and File

/// DayDream ▸ Check for Updates…, or, while an update waits, its one action (Restart to Update) in the same place.
struct UpdateMenu: View {
    @ObservedObject var updates: Updates
    var body: some View {
        if let waiting = updates.waiting { Button(waiting.title) { updates.actOnWaiting() } }
        else { Button("Check for Updates…") { updates.check() }.disabled(!updates.canCheck) }
    }
}

/// DayDream ▸ Settings… ⌘, opens the settings sheet on General.
struct DaydreamSettingsCommand: View {
    let model: MemoryViewModel?
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Settings…") {
            guard let model else { return }
            model.openSettings("General")
            DaydreamMainWindow.show(openWindow)
        }
        .keyboardShortcut(",", modifiers: .command)
        .disabled(model == nil)
    }
}

/// DayDream ▸ Quit DayDream ⌘Q, in place of AppKit's: through `AppQuit`, as the menu bar's Quit, so it quits with
/// Settings or another sheet open (AppKit's `terminate:` just returns then). A timed pause is kept for the next launch
/// (gold r3, gate item 4: `LaunchResume`), as the menu bar's Quit and a logout keep it.
struct DaydreamQuitCommand: View {
    let model: MemoryViewModel?
    /// The checks pass a recorder; the app quits.
    var quit: () -> Void = { AppQuit.quit() }
    var body: some View {
        Button("Quit DayDream") { Self.run(model: model, quit: quit) }
            .keyboardShortcut("q", modifiers: .command)
    }
    /// The button's action (launch-state-checks G runs it): it quits, and leaves the person's timed pause for the next
    /// launch (the quit itself pauses as DayDream's own, `willTerminate`). It used to end the pause first.
    static func run(model: MemoryViewModel?, quit: () -> Void) { quit() }
}

/// File ▸ Set Up DayDream… (in place of New Window). Not in the Development Trial; in DayDream Preview it opens setup
/// to click through (nothing there saves, asks for a permission or records).
struct DaydreamSetupCommand: View {
    let model: MemoryViewModel?
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Set Up DayDream…") { openWindow(id: "onboarding"); NSApp.activate(ignoringOtherApps: true) }
            .disabled(model == nil || (model?.development != nil && model?.development?.preview != true))
    }
}

/// Window ▸ Open DayDream ⌘O.
struct DaydreamOpenCommand: View {
    let available: Bool
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open DayDream") { DaydreamMainWindow.show(openWindow) }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!available)
    }
}

/// Help ▸ Report a Problem… opens a new email to support in the person's mail app (ReportProblem.swift), the same as
/// the menu bar's item. No key equivalent. Available in every mode: the email says what it can read.
struct DaydreamReportProblemCommand: View {
    let model: MemoryViewModel?
    var body: some View {
        Button(MenuBarMenu.reportProblemTitle) { ReportProblemMail.compose(app: model) }
    }
}

// MARK: - View

/// View ▸ Refresh ⇧⌘R reloads the focused day (the Focus List), or the legacy list without one. Shown only with
/// Option held (DaydreamMenuTidy); ⇧⌘R always works.
struct DaydreamViewCommands: View {
    let model: MemoryViewModel?
    @ObservedObject var browser: ActivityBrowser
    @ObservedObject private var shells = ShellPresence.shared
    @ObservedObject private var sheets = DaydreamSheetWatch.shared
    var body: some View {
        Button("Refresh") {
            guard let model, !sheets.onMainWindow else { return }
            if browser.loadCanonicalDay != nil { browser.send(.refresh) } else { model.refresh() }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(model == nil || browser.recallVisible || !shells.isMounted(browser) || sheets.onMainWindow)
    }
}

// MARK: - Go

/// Go ▸ Search… ⌘K, Find… ⌘F (hidden: DaydreamMenuTidy; the key works), Previous Day ⌘[, Next Day ⌘], Today ⌘T.
struct DaydreamGoCommands: View {
    let model: MemoryViewModel?
    @ObservedObject var browser: ActivityBrowser
    @ObservedObject private var shells = ShellPresence.shared
    @ObservedObject private var sheets = DaydreamSheetWatch.shared
    @Environment(\.openWindow) private var openWindow

    /// Go ▸ Today's title and command: `Show in <Day>` (Recall's selection) while Recall shows one, else `Today`,
    /// which has nothing to do while the Focus List already shows today (`onToday`, the day stepper's rule).
    static func todayItem(_ context: DaydreamCommandContext, recallVisible: Bool, onToday: Bool = false) -> (title: String, command: DaydreamCommand, enabled: Bool) {
        if recallVisible {
            guard context.hasSelection, let day = context.selectionDayTitle else { return ("Today", .today, false) }
            return ("Show in " + day, .showInToday, true)
        }
        return ("Today", .today, !onToday)
    }

    var body: some View {
        let available = model != nil
        let recall = browser.recallVisible
        // Day paging and Today act on the mounted Focus List (or Recall); none with the window closed, and none
        // while a sheet covers the window.
        let mounted = shells.isMounted(browser) && !sheets.onMainWindow
        // As the toolbar's day stepper: on today there is no next day, and Today would do nothing.
        let onToday = DayStepper.isOnToday(browser)
        let today = Self.todayItem(browser.commandContext, recallVisible: recall, onToday: onToday)
        Button("Search…") { summon(visible: .toggleActions) }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!available || !browser.canSearch || sheets.onMainWindow)
        Button("Find…") { summon(visible: .find) }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!available || !browser.canSearch || sheets.onMainWindow)
        Divider()
        // Day paging belongs to the Focus List; Recall covers it while visible.
        Button("Previous Day") { browser.send(.previousDay) }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!available || !mounted || recall || browser.loadCanonicalDay == nil || DayStepper.target(browser, direction: -1) == nil)
        Button("Next Day") { browser.send(.nextDay) }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!available || !mounted || recall || browser.loadCanonicalDay == nil || onToday)
        Button(today.title) { browser.send(today.command) }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(!available || !mounted || !today.enabled || (!recall && browser.loadCanonicalDay == nil))
    }

    /// ⌘K / ⌘F: while Recall is visible in a mounted shell it handles the command (Actions menu, field focus);
    /// otherwise they open Recall in the main window, which focuses its field. With the window closed (Recall
    /// may have been left open in it) the window opens with Recall, instead of messaging no one.
    private func summon(visible command: DaydreamCommand) {
        guard model != nil, browser.canSearch, !sheets.onMainWindow else { return }
        if browser.recallVisible && shells.isMounted(browser) { browser.send(command); return }
        browser.recallPresented = true
        DaydreamMainWindow.show(openWindow)
    }
}

// MARK: - Moment

/// Moment ▸ Open Original ⌘↩, Copy Summary ⇧⌘C, Find Related Moments ⌘R, then Edit Correction…,
/// Forget This Moment…, Exclude <App> from Recording… and Don't Record <site>… (no key equivalents). The selection is the
/// visible surface's (Focus List or Recall), as are the titles.
struct DaydreamMomentCommands: View {
    @ObservedObject var browser: ActivityBrowser
    @ObservedObject private var shells = ShellPresence.shared
    @ObservedObject private var sheets = DaydreamSheetWatch.shared
    var body: some View {
        let c = browser.commandContext
        // The selection lives in a mounted shell; the context is reset when the last one closes (ShellPresence).
        // A sheet over the window (Settings, a correction, a confirmation) owns the keys until it closes.
        let selected = c.hasSelection && shells.isMounted(browser) && !sheets.onMainWindow
        Button(c.openTitle ?? "Open Original") { browser.send(.openOriginal) }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!selected || !c.canOpenOriginal)
        Button("Copy Summary") { browser.send(.copySummary) }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!selected || !c.hasSummary)
        if c.canFindRelated {
            Button("Find Related Moments") { browser.send(.findRelated) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!selected)
        }
        Divider()
        Button("Edit Correction…") { browser.send(.editCorrection) }
            .disabled(!selected || !c.canEditCorrection)
        Button("Forget This Moment…") { browser.send(.forget) }
            .disabled(!selected || !c.canForget)
        // The whole range, not the selection: open while the window shows (no sheet over it).
        if browser.canForgetRange {
            Button(ForgetRangeText.menuTitle) { browser.forgetRangePresented = true }
                .disabled(!shells.isMounted(browser) || sheets.onMainWindow)
        }
        if let app = c.excludeAppName {
            Button("Exclude \(app) from Recording…") { browser.send(.exclude) }
                .disabled(!selected)
        }
        // A Google Chrome moment's first site (Chrome page history); no key equivalent.
        if let site = c.excludeSite {
            Button(ExcludeSiteRequest(site: site).menuTitle) { browser.send(.excludeSite) }
                .disabled(!selected)
        }
    }
}

// MARK: - Recording

/// Recording ▸ Pause for ▸ (15 Minutes carries ⌘P; enabled only while recording), Start/Resume and Stop
/// Recording (A4's rows, no other key equivalents).
struct DaydreamRecordingCommands: View {
    let model: MemoryViewModel?
    var body: some View {
        if let model { DaydreamRecordingRows(model: model) }
        else {
            MenuBarRecordingMenu(state: .off(since: nil, reason: nil), canResume: false, canStop: false, actions: CaptureActions(),
                                 pauseShortcut: DaydreamRecordingRows.pauseShortcut)
        }
    }
}

struct DaydreamRecordingRows: View {
    /// The only ⌘P.
    static let pauseShortcut = KeyboardShortcut("p", modifiers: .command)
    /// Read, not observed (perf-1002): observing the whole app model rebuilt the main menu's Recording rows on every
    /// one of its changes (about 100 a minute while recording). `rows` publishes only when the rows' inputs change.
    let model: MemoryViewModel
    @ObservedObject private var rows: DedupedFeed<RecordingRowsInputs>
    @Environment(\.openWindow) private var openWindow
    init(model: MemoryViewModel) {
        self.model = model
        _rows = ObservedObject(wrappedValue: RecordingRowsInputs.feed(for: model))
    }
    var body: some View {
        // Start goes through setup when something there must be done first: the setup window opens at that step.
        MenuBarRecordingMenu(presentation: model.presentation,
                             actions: CaptureActions(pause: model.pauseFor,
                                                     resume: { [model, openWindow] in model.requestStart { openWindow(id: "onboarding"); NSApp.activate(ignoringOtherApps: true) } },
                                                     stop: model.stopCapture),
                             pauseShortcut: Self.pauseShortcut)
    }
}

/// perf-1002: what the Recording rows show (`MenuBarRecordingMenu(presentation:)` reads these three). One feed per model.
struct RecordingRowsInputs: Equatable {
    let state: RecordingState; let canResume: Bool; let canStop: Bool
    @MainActor static func feed(for model: MemoryViewModel) -> DedupedFeed<RecordingRowsInputs> {
        let key = ObjectIdentifier(model)
        if let known = feeds[key], known.model === model { return known.feed }
        let feed = DedupedFeed<RecordingRowsInputs>(changes: [model.objectWillChange.map { _ in () }.eraseToAnyPublisher()], refresh: 60,
                                                    compute: { [weak model] in model.map { p in
                                                        let presentation = p.presentation
                                                        return RecordingRowsInputs(state: presentation.state, canResume: presentation.canResume,
                                                                                   canStop: presentation.canStop) } })
        feeds[key] = Entry(model: model, feed: feed)
        return feed
    }
    private struct Entry { weak var model: MemoryViewModel?; let feed: DedupedFeed<RecordingRowsInputs> }
    @MainActor private static var feeds: [ObjectIdentifier: Entry] = [:]
}
