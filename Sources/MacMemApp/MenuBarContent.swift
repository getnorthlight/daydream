import SwiftUI
import AppKit
import Combine
import MemoryUI

// The menu bar extra (plan §5 A4, architecture §9): the mark-A glyph label and the panel (`MenuBarMenu`, a plain
// macOS menu: status line, one switch, Pause ›, today's line and the usual items), wired to the app model. Outside
// `#if !DEVELOPMENT_SOURCE_CHECKS`, so the app-source checks compile it; nothing here is `@main`.
//
// Scene (MacMemApp.swift, pasted once by I1 in place of today's `MenuBarExtra("DayDream", systemImage:…)`):
//
//     MenuBarExtra {
//         if let model = session.model { DaydreamMenuBarPanel(model: model) }
//         else { DaydreamMenuBarIsolatedPanel() }
//     } label: {
//         if let model = session.model { DaydreamMenuBarLabel(model: model) }
//         else { DaydreamMenuBarIsolatedLabel() }
//     }
//     .menuBarExtraStyle(.window)
//
// The label is its own observing view: the App body observes only `session`, so a label built
// there from `session.model?.recording` goes stale (architecture R2).

/// The menu bar label: F1's template mark for the live recording state, with one VoiceOver
/// label ("DayDream: Recording", "DayDream: Paused until 4:36 PM", "DayDream: Off",
/// "DayDream: Needs Permission"). While recording is off until something is done (the panel's status line is orange,
/// with or without a fix button: Finish Setup…, Open Applications, Review…, or none while another copy is open) the
/// mark draws its "!" too, and the label says what is missing. The typing dot shows exactly while
/// `TypingIndicatorState.showsDot` ("DayDream is recording what you type"), the hollow ring while typing is paused.
struct DaydreamMenuBarLabel: View {
    /// Read, not observed (perf-1002): observing the whole app model re-rendered the status item on every one of its
    /// changes (a heartbeat, a search line, a key), each a fenced update shared with the menu bar's host process.
    /// `feed` is the only subscription and publishes only a label that changed.
    let model: MemoryViewModel
    @ObservedObject private var feed: MenuBarLabelFeed
    init(model: MemoryViewModel) {
        self.model = model
        _feed = ObservedObject(wrappedValue: MenuBarLabelFeed.shared(for: model))
    }
    var body: some View { Self.image(model: model) }
    /// What the label draws for `model` now.
    @MainActor static func image(model: MemoryViewModel) -> DaydreamMenuBarLabelImage {
        // The browser's calendar: the zone the Focus List and today's snapshot use.
        let zone = model.activity.calendar.timeZone, now = model.activity.now()
        return DaydreamMenuBarLabelImage(state: model.recordingState, now: now, timeZone: zone, typing: model.typing.indicator,
                                         setup: DaydreamMenuBarPanel.setupLine(model: model, now: now, timeZone: zone))
    }
}

/// perf-1002: what the menu bar label draws and says. The label publishes only when this changes.
struct MenuBarLabelDrawn: Equatable {
    let state: DaydreamCaptureState; let badge: DaydreamTypingBadge; let label: String
    init(_ image: DaydreamMenuBarLabelImage) { state = image.drawnState; badge = image.badge; label = image.label }
}
typealias MenuBarLabelFeed = DedupedFeed<MenuBarLabelDrawn>
extension DedupedFeed where Value == MenuBarLabelDrawn {
    /// One feed per model, so re-creating the label view never subscribes again. Its sources: the app model and the
    /// typing model (the label's two inputs before), plus a minute timer for a label that changes with the clock alone.
    static func shared(for model: MemoryViewModel) -> MenuBarLabelFeed {
        let key = ObjectIdentifier(model)
        if let known = MenuBarLabelFeeds.feeds[key], known.model === model { return known.feed }
        let feed = MenuBarLabelFeed(changes: [model.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                                              model.typing.objectWillChange.map { _ in () }.eraseToAnyPublisher()],
                                    refresh: 60,
                                    compute: { [weak model] in model.map { MenuBarLabelDrawn(DaydreamMenuBarLabel.image(model: $0)) } })
        MenuBarLabelFeeds.feeds[key] = MenuBarLabelFeeds.Entry(model: model, feed: feed)
        return feed
    }
}
@MainActor enum MenuBarLabelFeeds {
    struct Entry { weak var model: MemoryViewModel?; let feed: MenuBarLabelFeed }
    static var feeds: [ObjectIdentifier: Entry] = [:]
}

/// The isolated preview's label: the Off mark (nothing records without a model).
struct DaydreamMenuBarIsolatedLabel: View {
    var body: some View {
        DaydreamMenuBarLabelImage(state: DaydreamCaptureState.off, label: DaydreamMark.accessibilityDescription(.off))
    }
}

/// Where the panel's actions lead. The defaults are the app's; the checks inject recorders.
struct DaydreamMenuBarRoutes {
    var openWindow: (String) -> Void
    var activate: () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    var openURL: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    var terminate: () -> Void = { AppQuit.quit() }
    var reportProblem: @MainActor (MemoryViewModel) -> Void = { ReportProblemMail.compose(app: $0) }
}

/// The panel for the app model: presentation, today's snapshot, the typing line and the actions.
struct DaydreamMenuBarPanel: View {
    @ObservedObject var model: MemoryViewModel
    @ObservedObject private var today: TodayDigest
    @ObservedObject private var typing: TypingModel
    /// Only for a waiting update's row (Restart to Update), right above Quit.
    @ObservedObject private var updates: Updates
    @Environment(\.openWindow) private var openWindow
    @AppStorage("DaydreamOnboardingCompletedV1") private var onboardingCompleted = false
    @State private var host = DaydreamMenuBarHost()
    private let routeOverride: DaydreamMenuBarRoutes?

    /// `routes`: nil uses the app's (`openWindow`, activate, System Settings, terminate).
    init(model: MemoryViewModel, routes: DaydreamMenuBarRoutes? = nil) {
        self.model = model
        _today = ObservedObject(wrappedValue: model.activity.today)
        _typing = ObservedObject(wrappedValue: model.typing)
        _updates = ObservedObject(wrappedValue: model.updates)
        routeOverride = routes
    }

    var body: some View {
        let routes = routeOverride ?? DaydreamMenuBarRoutes(openWindow: { openWindow(id: $0) })
        MenuBarMenu(presentation: model.presentation, actions: Self.actions(model: model, routes: routes),
                    snapshot: today.snapshot, onboardingComplete: onboardingCompleted,
                    development: model.development != nil,
                    // The calendar today's snapshot was built with, so the times and the day match the Focus List (plan L18).
                    calendar: model.activity.calendar,
                    openToday: { Self.openToday(model: model, routes: routes) },
                    openSetUp: Self.openSetUp(model: model, routes: routes),
                    openPermissions: Self.openPermissions(model: model, routes: routes),
                    typing: Self.typingRows(typing, timeZone: model.activity.calendar.timeZone),
                    typingActions: Self.typingActions(model: model, routes: routes),
                    update: updates.waiting.map { waiting in
                        MenuBarMenu.UpdateAction(title: waiting.title) { [updates] in updates.actOnWaiting() } },
                    dismiss: { host.dismiss() })
            .background(DaydreamMenuBarWindowReader(host: host))
            // The panel appears each time it opens: today's data may be minutes old by then, and a permission may
            // have been allowed in System Settings since (a read only, as Check Again did: it never prompts).
            .onAppear {
                model.dayData.refreshTodayIfStale(10); typing.refresh()
                if model.recordingState.kind == .needsPermission { model.checkPermissions() }
            }
    }

    /// DayDream's guided setup (it opens at the first step still missing); nil in the Development Trial.
    static func openSetUp(model: MemoryViewModel, routes: DaydreamMenuBarRoutes) -> (() -> Void)? {
        model.development == nil ? { routes.openWindow("onboarding"); routes.activate() } : nil
    }
    /// The DayDream permissions window (the drag cards and Done): Allow… once setup is finished, so a permission
    /// turned off later is allowed without walking through setup again. nil in the Development Trial.
    static func openPermissions(model: MemoryViewModel, routes: DaydreamMenuBarRoutes) -> (() -> Void)? {
        // perm-1004: the window opens the pane of the permission to turn on next, once (one click).
        model.development == nil ? {
            if let next = model.recordingState.nextPermission { model.permissionPaneRequest = next }
            routes.openWindow("permissions"); routes.activate()
        } : nil
    }

    /// The orange line the panel shows while recording can't start until something is done (the menu bar mark
    /// draws its "!" then, exactly while the panel's status is orange); nil otherwise. Same inputs as the panel's header.
    static func setupLine(model: MemoryViewModel, now: Date, timeZone: TimeZone) -> String? {
        let header = MenuBarMenu.header(model.presentation, now: now, timeZone: timeZone, canSetUp: model.development == nil,
                                        canOpenApplications: model.openApplicationsAction != nil)
        return header.needsSetup ? header.status.text : nil
    }

    /// The typing line and item for the app in front. The shortcut is shown only while it is registered.
    static func typingRows(_ typing: TypingModel, timeZone: TimeZone) -> TypingMenuRows {
        TypingMenuRows(state: typing.indicator, shortcut: typing.hotkey.activeDisplay, timeZone: timeZone)
    }
    /// Pause and resume act on typing only (the recording pause is separate); a locked line opens
    /// Settings ▸ Apps to remember, where typing is turned on.
    static func typingActions(model: MemoryViewModel, routes: DaydreamMenuBarRoutes) -> TypingMenuActions {
        let typing = model.typing
        return TypingMenuActions(pause: { _ = try? typing.snooze(frontmostBundle: typing.frontmostBundle()) },
                                 resume: { try? typing.resume(frontmostBundle: typing.frontmostBundle()) },
                                 openSettings: { routes.openWindow("memory"); routes.activate(); model.openSettings("Recording") })
    }

    /// The panel's actions. Each runs exactly one model call or route (Start: `requestStart`, which may open setup). Quit
    /// leaves a timed pause alone (gold r3, gate item 4): quitting pauses as DayDream's own and keeps the person's pause as
    /// the launch intent (`LaunchResume`), so the next launch picks it up until the same time, as after a logout.
    static func actions(model: MemoryViewModel, routes: DaydreamMenuBarRoutes) -> CaptureActions {
        let openMain = { routes.openWindow("memory"); routes.activate() }
        // Start goes through setup when something there must be done first (setup never finished, a permission
        // missing, app choices that didn't save): the setup window opens at that step.
        var actions = CaptureActions(pause: { model.pauseFor(minutes: $0) },
                                     resume: { model.requestStart { routes.openWindow("onboarding"); routes.activate() } },
                                     stop: { model.stopCapture() },
                                     settings: { openMain(); model.openSettings("General") })
        actions.openMain = openMain
        // Recall only where search works (MemoryShell shows it only then); in the storage-failure
        // (legacy) mode Search… opens the window, whose inline filter stands in.
        actions.openRecall = {
            openMain()
            if model.activity.canSearch { model.activity.recallPresented = true }
        }
        actions.openSettingsSection = { openMain(); model.openSettings($0) }
        // Try Again beside the orange line: the job it is about, now (the history upkeep, a deletion). Nothing opens.
        actions.retryIssue = { model.retryIssue() }
        // chromeask-1005: Fix beside "Chrome pages aren't being saved." (the Automation pane, or setup's Chrome row).
        actions.fixChrome = { model.fixChromeAccess(openSetup: { routes.openWindow("onboarding"); routes.activate() }) }
        actions.checkPermissions = { model.checkPermissions() }
        // Allow Permissions: DayDream's drag cards (setup, or Settings › Permissions once setup is finished).
        actions.openSystemSettings = { kind in model.showPermissionCards(kind, openSetup: { routes.openWindow("onboarding"); routes.activate() },
                                                                         openMain: openMain) }
        actions.quit = { routes.terminate() }
        // Report a Problem…: a new email in the person's mail app (ReportProblem.swift); DayDream sends nothing.
        actions.reportProblem = { routes.reportProblem(model) }
        // Only while DayDream runs from the download window: the panel offers Open Applications.
        actions.openApplications = model.openApplicationsAction
        return actions
    }

    /// The today line: the main window on today's Focus List (Recall closed, so it can't cover the list; no moment
    /// expanded).
    static func openToday(model: MemoryViewModel, routes: DaydreamMenuBarRoutes) {
        model.activity.recallPresented = false
        model.activity.query = ""
        model.activity.focusedDay = nil
        model.activity.expandedMomentID = nil
        routes.openWindow("memory"); routes.activate()
    }
}

/// The panel with no model: the isolated preview's (`Isolated preview · Recording is off`), or launch's while it prepares
/// the history (`Getting ready…`, DaydreamLaunchSession.preparing); then `Quit DayDream`.
struct DaydreamMenuBarIsolatedPanel: View {
    let terminate: () -> Void
    let line: String
    @State private var host = DaydreamMenuBarHost()
    /// `terminate`: the app's `AppQuit.terminate`; the checks inject a recorder.
    init(line: String = MenuBarMenu.isolatedLine, terminate: @escaping () -> Void = { AppQuit.quit() }) { self.line = line; self.terminate = terminate }
    var body: some View {
        MenuBarMenu(presentation: nil, actions: actions, snapshot: nil, dismiss: { host.dismiss() }, offLine: line)
            .background(DaydreamMenuBarWindowReader(host: host))
    }
    private var actions: CaptureActions {
        var actions = CaptureActions()
        actions.quit = terminate
        return actions
    }
}

// MARK: - Dismissal

/// The panel's window. `MenuBarExtra(.window)` has no dismiss API on macOS 13, so the panel closes
/// its host window: public AppKit only (`NSView.window`, `orderOut(_:)`), no private class names.
final class DaydreamMenuBarHost {
    weak var window: NSWindow?
    func dismiss() { window?.orderOut(nil) }
}

/// A zero-size view that hands its window to `host`.
struct DaydreamMenuBarWindowReader: NSViewRepresentable {
    let host: DaydreamMenuBarHost
    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView(frame: .zero)
        view.host = host
        return view
    }
    func updateNSView(_ view: ReaderView, context: Context) {
        view.host = host
        if let window = view.window { host.window = window }
    }
    final class ReaderView: NSView {
        weak var host: DaydreamMenuBarHost?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            host?.window = window
        }
    }
}

// MARK: - System Settings (private helper)

/// PRIVATE HELPER (A4), pending a public MemoryUI helper (contract request): the same panes as
/// MemoryUI's internal `DaydreamPermission.settingsURL`. Opens System Settings only; it never
/// requests a permission.
enum MenuBarSystemSettings {
    static func url(_ kind: PermissionKind?) -> URL {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch kind {
        case .accessibility?: return URL(string: base + "Privacy_Accessibility")!
        case .inputMonitoring?: return URL(string: base + "Privacy_ListenEvent")!
        case nil: return URL(string: base + "Privacy")!
        }
    }
}
