import SwiftUI
import MemoryCore
import AppKit
import ApplicationServices
import CoreGraphics

public struct RecordingPermissionSetup: View {
    @Environment(\.openWindow) private var openWindow
    let enabled: Bool
    let onRefresh: () -> Void
    @State private var granted = false

    public init(enabled: Bool = true, onRefresh: @escaping () -> Void = {}) {
        self.enabled = enabled
        self.onRefresh = onRefresh
    }

    public var body: some View {
        HStack(spacing: 14) {
            Image(systemName: granted ? "checkmark.shield" : "lock.shield")
                .font(.system(size: 24)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("macOS permissions").font(.headline)
                Text(!enabled ? "Unavailable in this preview" : granted ? "Accessibility and Input Monitoring allowed" : "Accessibility and Input Monitoring required")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(granted ? "Review permissions" : "Grant permissions") { openWindow(id: "permissions") }
                .disabled(!enabled).fixedSize()
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        guard enabled else { return }
        granted = AXIsProcessTrusted() && CGPreflightListenEventAccess()
        onRefresh()
    }
}

enum DaydreamPermission: String, CaseIterable, Identifiable {
    case accessibility, inputMonitoring
    var id: String { rawValue }
    var title: String { self == .accessibility ? "Accessibility" : "Input Monitoring" }
    var purpose: String {
        // True with typed text on or off: while it's off, key presses are ignored (EventCapture).
        self == .accessibility ? "Read activity in supported apps and windows." : Self.inputMonitoringPurpose
    }
    // Public builds type only in build 4's two apps; the owner build types in more apps and on websites.
    #if DAYDREAM_OWNER_TYPING
    static let inputMonitoringPurpose = "Notice clicks while recording, and typing in the apps and websites you turn typing on for."
    static let inputMonitoringDetail = "Notices clicks and what you type."
    #else
    static let inputMonitoringPurpose = "Notice clicks while recording, and typing in Notes and TextEdit only if you turn typed text on."
    static let inputMonitoringDetail = "Notices clicks, and typing in Notes and TextEdit."
    #endif
    var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?" + (self == .accessibility ? "Privacy_Accessibility" : "Privacy_ListenEvent"))!
    }
    /// The one short line under the card's title (owner, 9/28: "Notices clicks and what you type."). The longer
    /// `purpose` is the card's VoiceOver hint.
    var detail: String {
        self == .accessibility ? "Reads app names, window titles and text." : Self.inputMonitoringDetail
    }
    /// SF Symbols 5 `accessibility` (DayDream needs macOS 15).
    var tileSymbol: String { self == .accessibility ? "accessibility" : "keyboard" }
}

/// What the permission page can ask the app to do (SPEC 6.3 R2), handed to `PermissionGrantView` through the
/// environment (`\.daydreamPermissionRequests`). Without it (previews, renders, the checks) the page offers no
/// Quit & Reopen. DayDream never shows a macOS permission prompt: each card opens its own System Settings pane
/// and is dragged into that pane's list (the owner's drag-card helper).
public struct PermissionRequestActions {
    /// Quits DayDream and opens the same app again; nil where DayDream can't reopen itself (a development binary).
    public var quitAndReopen: (() -> Void)?
    /// Input Monitoring as DayDream read it when it opened; nil when unknown. macOS applies Input Monitoring that
    /// was turned on while DayDream was open only after DayDream reopens.
    public var inputMonitoringAtLaunch: Bool?
    /// Non-nil while DayDream runs from the download window: the cards then open and drag nothing.
    public var moveWarning: String?
    public var moveDetail: String?
    /// Opens the Applications folder in Finder.
    public var openApplications: () -> Void
    /// perm-1004 (owner 10/3: one click): a surface that said `Turn on Accessibility` (or Input Monitoring) was pressed.
    /// The page opens that permission's System Settings pane once, as its card's button would (the window floats with
    /// the drag card), then calls `paneRequestHandled`. A `DaydreamPermission.rawValue`; nil: nothing asked.
    public var paneRequest: String?
    public var paneRequestHandled: () -> Void
    /// perm-1004: Input Monitoring was turned on after DayDream opened and both permissions read on: DayDream restarts
    /// by itself (`PermissionRelaunch.autoText`), so the page shows that one line instead of a Quit & Reopen step.
    public var autoRelaunch: Bool

    public init(quitAndReopen: (() -> Void)?, inputMonitoringAtLaunch: Bool? = nil, moveWarning: String? = nil,
                moveDetail: String? = nil, openApplications: @escaping () -> Void = {}, paneRequest: String? = nil,
                paneRequestHandled: @escaping () -> Void = {}, autoRelaunch: Bool = false) {
        self.quitAndReopen = quitAndReopen
        self.inputMonitoringAtLaunch = inputMonitoringAtLaunch
        self.moveWarning = moveWarning
        self.moveDetail = moveDetail
        self.openApplications = openApplications
        self.paneRequest = paneRequest
        self.paneRequestHandled = paneRequestHandled
        self.autoRelaunch = autoRelaunch
    }

    public static let quitAndReopenTitle = "Quit & Reopen"
    public static let openApplicationsTitle = "Open Applications Folder"
}

private struct PermissionRequestActionsKey: EnvironmentKey {
    static let defaultValue: PermissionRequestActions? = nil
}

public extension EnvironmentValues {
    /// The app's permission actions; nil offers no Quit & Reopen.
    var daydreamPermissionRequests: PermissionRequestActions? {
        get { self[PermissionRequestActionsKey.self] }
        set { self[PermissionRequestActionsKey.self] = newValue }
    }
}

/// Kept for the callers' signatures: setup, the permissions window and Settings all draw the same two cards.
/// `.settings` is always embedded (no header).
public enum PermissionGrantStyle: Sendable {
    case cards, settings
}

/// What a card carries when it's dragged: the app bundle's file URL, which System Settings' privacy lists accept.
/// Empty from the download window and for anything that isn't an app bundle.
public enum PermissionDragPayload {
    public static func provider(appURL: URL, enabled: Bool) -> NSItemProvider {
        guard enabled, appURL.isFileURL, appURL.pathExtension == "app" else { return NSItemProvider() }
        return NSItemProvider(object: appURL as NSURL)
    }
}

/// Where the page drew its buttons and cards (global frames), for the checks' clicks: `quitAndReopen`,
/// `recovery`, `open.<permission>` and `card.<permission>` (`accessibility`, `inputMonitoring`), and the drag hint's room:
/// `dragHint` while it shows, `dragHint.hidden` while it is kept empty.
public struct PermissionPageElements: PreferenceKey {
    public static var defaultValue: [String: CGRect] { [:] }
    public static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    fileprivate func permissionElement(_ key: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: PermissionPageElements.self, value: [key: proxy.frame(in: .global)])
        })
    }
}

/// When the page offers Quit & Reopen as a step, and what it says. Only when macOS needs it: Input Monitoring
/// turned on while DayDream was open. Anything else ("still off?") is the quiet "Already turned on in System
/// Settings?" disclosure, which has its own Quit & Reopen link: coming back to DayDream to drag a card is the
/// normal path, not a sign that DayDream must reopen.
public enum PermissionRelaunch: Equatable, Sendable {
    /// Input Monitoring was off when DayDream opened and reads as on now. macOS says so itself when it is turned
    /// on: DayDream can't use it until it quits and reopens.
    case inputMonitoringTurnedOn

    public static func reason(inputMonitoringAtLaunch: Bool?, accessibility: Bool, inputMonitoring: Bool) -> PermissionRelaunch? {
        inputMonitoring && inputMonitoringAtLaunch == false ? .inputMonitoringTurnedOn : nil
    }

    public var text: String { "Input Monitoring starts working after DayDream reopens." }

    /// perm-1004 (owner: no manual restart): the one line while DayDream restarts itself to use Input Monitoring.
    public static let autoText = "Input Monitoring is on. DayDream restarts by itself to use it."
    /// How long the line shows before DayDream restarts.
    public static let autoDelay: TimeInterval = 1.5
    /// A restart this soon after the last automatic one is not made again (no restart loop): the page offers
    /// Quit & Reopen instead.
    public static let autoCooldown: TimeInterval = 120

    /// Whether DayDream restarts by itself now: Input Monitoring needs the reopen (`reason`), both permissions read
    /// on, nothing records, DayDream can reopen itself, and the last automatic restart was not within `autoCooldown`.
    public static func restartsByItself(inputMonitoringAtLaunch: Bool?, launchReadSettled: Bool, accessibility: Bool?,
                                        inputMonitoring: Bool?, recording: Bool, canReopen: Bool,
                                        lastAutoRestart: Date?, now: Date) -> Bool {
        guard accessibility == true, inputMonitoring == true, launchReadSettled, !recording, canReopen,
              reason(inputMonitoringAtLaunch: inputMonitoringAtLaunch, accessibility: true, inputMonitoring: true) != nil else { return false }
        guard let last = lastAutoRestart else { return true }
        return now < last || now.timeIntervalSince(last) >= autoCooldown
    }
}

/// perm-1004 (owner 10/3: "about 4 DayDreams everywhere"): what the permission page says about System Settings' rows.
/// System Settings lists each copy of DayDream by its name, and a row left from another copy (an old build, a test copy,
/// or the same name signed differently) can be on while this copy still reads off. Pure, apart from `appName` and
/// `lookAlikes`, which read this Mac's Launch Services; DayDream never reads or changes the privacy lists themselves.
public enum PermissionRowHelp {
    /// Bundle IDs DayDream copies have used (normal, test, preview, development, Mac Mem) and their ad-hoc forms.
    public static let knownBundleIDs: [String] = {
        let base = DaydreamIdentity.bundleID
        let ids = [base] + ["livetest", "qa", "preview", "development"].map { base + "." + $0 }
        return ids + ids.map { $0 + ".adhoc" } + [DaydreamIdentity.legacyBundleID]
    }()

    /// The name System Settings shows for this app: its display name, else its bundle name, else the file name.
    public static func appName(appURL: URL) -> String {
        let info = Bundle(url: appURL)?.infoDictionary
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        }
        let file = appURL.deletingPathExtension().lastPathComponent
        return file.isEmpty ? "DayDream" : file
    }

    /// Other DayDream copies on this Mac that System Settings may list beside this one. `copies` stands in Launch
    /// Services in the checks.
    public static func lookAlikes(appURL: URL, ids: [String] = knownBundleIDs,
                                  copies: (String) -> [URL] = { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }) -> [URL] {
        let own = appURL.standardizedFileURL.resolvingSymlinksInPath().path
        var seen = Set<String>(), out: [URL] = []
        for id in ids {
            for url in copies(id) {
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                guard path != own, seen.insert(path).inserted else { continue }
                out.append(url)
            }
        }
        return out
    }

    /// Under the cards while a permission is missing and other copies exist: which row to turn on, and that old rows
    /// can go. nil with no other copy (nothing to confuse it with).
    public static func rowLine(appName: String, otherCopies: Int) -> String? {
        otherCopies > 0 ? "Turn on the row named exactly \u{201C}\(appName)\u{201D}. You can remove old DayDream rows with the minus (\u{2212}) button." : nil
    }

    /// The step for a row that is on in System Settings while this copy still reads off. tccd (10/3, the Live Test copy):
    /// the row keeps the code requirement of the copy that made it (an old ad-hoc build), says "Failed to match existing
    /// code requirement", and answers off. Switching it on, or dragging the app onto it again, changes nothing (the drop
    /// lands on the existing row); only removing the row and adding the app again does, in that order. Shown first once
    /// the person came back from System Settings twice with both still off (`PermissionReturns`).
    public static func reAddStep(appName: String) -> String {
        "Still off? In System Settings, select \u{201C}\(appName)\u{201D} and remove it with the minus (\u{2212}) button first. Then drag the card into the list again and turn it on."
    }

    /// "Drag the card into the list" with this copy's own name, and the one exception: an existing row is removed first,
    /// because a card dropped onto a row already there changes nothing.
    public static func dragHint(appName: String) -> String {
        "Drag the card into the list, then turn on \u{201C}\(appName)\u{201D}. Already listed but off here? Remove it with the minus (\u{2212}) button first."
    }

    /// The card's tooltip (`.help`).
    public static func cardHelp(appName: String, permission: String) -> String {
        "Drag this card into the \(permission) list in System Settings, or use the + button there. If \u{201C}\(appName)\u{201D} is already listed but stays off here, remove it with the minus (\u{2212}) button first: dropping the card onto it changes nothing."
    }
}

/// perm-1004 (coordinator 10/3): the person opened a pane from the page and came back to DayDream. Twice back with both
/// permissions still off means the row they turned on is not this copy's: the page then shows the remove-and-add-again
/// step first (`PermissionRowHelp.reAddStep`). Pure, so the checks pin it.
public struct PermissionReturns: Equatable, Sendable {
    public static let threshold = 2
    public private(set) var count = 0
    public init(count: Int = 0) { self.count = count }
    /// DayDream became active again; `paneOpened`: a pane was opened from this page in this visit.
    public mutating func returned(paneOpened: Bool) { if paneOpened { count += 1 } }
    /// A permission read on: the count starts over.
    public mutating func reset() { count = 0 }
    public func showsReAddFirst(accessibility: Bool, inputMonitoring: Bool) -> Bool {
        count >= Self.threshold && !accessibility && !inputMonitoring
    }
}

/// Input Monitoring read off while DayDream runs. macOS applies it turned back on only once DayDream reopens, the same
/// as one turned on after launch, so the app then counts it as off at launch and the page offers Quit & Reopen
/// (`PermissionRelaunch`). One read is not enough: an off read counts once a read `confirmAfter` later is still off
/// (a read can come back off for a moment). Reads while the Mac sleeps, is locked or shows another user don't count,
/// and neither do reads in the first `afterWake` seconds after that ends (gold r3: the privacy service can answer "not
/// allowed" for a while right after an unlock or wake; a 1.6 s answer then used to count as Input Monitoring turned off
/// and on, for the rest of the run). Keys arriving through the input tap prove it works, whatever the reads said.
public struct InputMonitoringWatch: Equatable, Sendable {
    public static let confirmAfter: TimeInterval = 1.5
    /// After a wake, an unlock or a switch back, reads for this long don't count (the caller passes `counts` false).
    public static let afterWake: TimeInterval = 10
    /// Read off, and still off `confirmAfter` later, in this run.
    public private(set) var seenOff = false
    private var offSince: Date?
    public init() {}
    /// Keys reached DayDream through its input tap: Input Monitoring works in this run. Forgets any off read.
    public mutating func provedOn() { seenOff = false; offSince = nil }
    /// A sleep, lock or user switch began or ended: an off read before it confirms nothing after it.
    public mutating func interrupted() { offSince = nil }
    /// A read. True when a read `confirmAfter` from now should confirm this off read (the first one of a run).
    @discardableResult public mutating func read(inputMonitoring: Bool, at now: Date, counts: Bool) -> Bool {
        guard counts, !seenOff else { return false }
        guard !inputMonitoring else { offSince = nil; return false }
        guard let since = offSince, now >= since else { offSince = now; return true }
        if now.timeIntervalSince(since) >= Self.confirmAfter { seenOff = true }
        return false
    }
}

/// What the surfaces SHOW of one permission's reads (claude/permflash-015; owner's laptop 10/04: "the permission screen
/// flash for like 2 frames even though everything was enabled"). macOS's privacy service can answer "not allowed" for a
/// moment (2 ms to about a second at any time, up to 3 s right after a wake or an unlock: permission-blip-checks), and
/// every surface used to draw each read as it came. Now a read that says allowed shows at once, and one that says not
/// allowed shows only once the reads have stayed that way for `settle` (a later read, at least that long after the
/// first, still says so; any read that says allowed in between ends it). Until then what showed before still shows; a
/// permission nothing is known about yet shows as neither (`shown` nil), never as off. Only what is shown waits:
/// recording has its own rule (`SettledPermission`), and the person's own Start takes its read as it is (`take`).
public struct PermissionSettle: Equatable, Sendable {
    /// Longer than the 1.2 s "not allowed" the checks model away from a wake, and three of the recorder's 0.5 s
    /// heartbeats; a permission really turned off in System Settings shows about this long after its first off read.
    public static let settle: TimeInterval = 1.5
    /// In the first `InputMonitoringWatch.afterWake` after a wake, an unlock or a switch back the answer can stay wrong
    /// for up to 3 s (permission-blip-checks H and I); a start that reads it off then gives up after this long too
    /// (`MemoryViewModel.permissionHoldQuiet`), and says so.
    public static let settleAfterWake: TimeInterval = 4
    /// What shows: true allowed, false not allowed, nil not known yet.
    public private(set) var shown: Bool?
    /// The first of the off reads now waiting to hold.
    private var offSince: Date?
    /// It was allowed before (setup was finished once, or a read said so). Until then there is nothing to flash away
    /// from, so the first off read is the answer at once (a new install's Permissions page).
    private var allowedBefore: Bool

    public init(shown: Bool? = nil, allowedBefore: Bool = true) {
        self.shown = shown
        self.allowedBefore = allowedBefore || shown == true
    }
    /// An off read is waiting to hold: read again once `settle` has passed.
    public var unsettled: Bool { offSince != nil }
    /// A read. `counts` false (asleep, locked, another user on screen): an off read says nothing, as for
    /// `InputMonitoringWatch`. Returns what shows now.
    @discardableResult public mutating func read(_ allowed: Bool, at now: Date, settle: TimeInterval = PermissionSettle.settle,
                                                 counts: Bool = true) -> Bool? {
        if allowed { shown = true; offSince = nil; allowedBefore = true; return shown }
        guard counts else { offSince = nil; return shown }
        guard shown != false else { offSince = nil; return shown }
        guard allowedBefore else { shown = false; return shown }
        guard let since = offSince, now >= since else { offSince = now; return shown }
        if now.timeIntervalSince(since) >= settle { shown = false; offSince = nil }
        return shown
    }
    /// The person's own Start read it: that read is the answer at once.
    public mutating func take(_ allowed: Bool) {
        shown = allowed; offSince = nil
        if allowed { allowedBefore = true }
    }
    /// A sleep, lock or user switch began or ended: an off read before it holds nothing after it.
    public mutating func interrupted() { offSince = nil }
}

/// Both recording permissions as the surfaces show them (`PermissionSettle` for each).
public struct ShownPermissions: Equatable, Sendable {
    public private(set) var accessibility: PermissionSettle
    public private(set) var inputMonitoring: PermissionSettle

    /// `known`: what showed last (another surface's settled reads), so a page that opens starts from it.
    public init(known: PermissionSnapshot = PermissionSnapshot(), allowedBefore: Bool = true) {
        accessibility = PermissionSettle(shown: known.accessibility, allowedBefore: allowedBefore)
        inputMonitoring = PermissionSettle(shown: known.inputMonitoring, allowedBefore: allowedBefore)
    }
    /// What shows now.
    public var snapshot: PermissionSnapshot {
        PermissionSnapshot(accessibility: accessibility.shown, inputMonitoring: inputMonitoring.shown)
    }
    public var unsettled: Bool { accessibility.unsettled || inputMonitoring.unsettled }
    /// A read of both (a nil read leaves that permission as it shows). Returns what shows now.
    @discardableResult public mutating func read(_ read: PermissionSnapshot, at now: Date, settle: TimeInterval = PermissionSettle.settle,
                                                 counts: Bool = true) -> PermissionSnapshot {
        if let on = read.accessibility { accessibility.read(on, at: now, settle: settle, counts: counts) }
        if let on = read.inputMonitoring { inputMonitoring.read(on, at: now, settle: settle, counts: counts) }
        return snapshot
    }
    @discardableResult public mutating func take(_ read: PermissionSnapshot) -> PermissionSnapshot {
        if let on = read.accessibility { accessibility.take(on) }
        if let on = read.inputMonitoring { inputMonitoring.take(on) }
        return snapshot
    }
    public mutating func interrupted() { accessibility.interrupted(); inputMonitoring.interrupted() }
}

/// When the page says "Drag the card into the list" (owner, 9/28: "once you open system settings and it is not enabled it
/// will say drag the card into the list"). Hidden until a card's Open System Settings opened its pane; shown once a read
/// at least `delay` after that still finds the permission missing (the page's reads: every 2 seconds and on coming back
/// to DayDream); hidden again once it is allowed. Permissions are named by `DaydreamPermission.rawValue`
/// ("accessibility", "inputMonitoring"). Pure, so the checks pin it.
public struct PermissionDragHint: Equatable, Sendable {
    /// How long after the pane opens before a still-missing permission shows the hint.
    public static let delay: TimeInterval = 1.5
    /// Panes opened from this page whose permission is still missing, and when.
    public private(set) var opened: [String: Date]
    /// Permissions whose pane was opened and that a later read still found missing.
    public private(set) var waiting: Set<String> = []
    public init(opened: [String: Date] = [:]) { self.opened = opened }
    /// The hint shows.
    public var shows: Bool { !waiting.isEmpty }
    /// A card's Open System Settings opened its pane.
    public mutating func paneOpened(_ permission: String, at now: Date) {
        if opened[permission] == nil { opened[permission] = now }
    }
    /// A read of both permissions (`allowed`: permission name to allowed).
    public mutating func read(_ allowed: [String: Bool], at now: Date) {
        for (permission, since) in opened {
            if allowed[permission] == true {
                opened[permission] = nil
                waiting.remove(permission)
            } else if now.timeIntervalSince(since) >= Self.delay {
                waiting.insert(permission)
            }
        }
    }
}

/// The owner's drag-card helper (the one permission view: setup, the permissions window and Settings). A card
/// per permission, with its status read live (every 2 seconds and whenever DayDream becomes active). A missing
/// permission's card opens that permission's own System Settings pane; the card itself drags DayDream straight
/// into the pane's list. While a pane is open and a permission is still missing, DayDream's window floats above
/// System Settings (`PermissionWindowLevel`), so the card stays in reach. Quit & Reopen shows only when macOS
/// needs DayDream to reopen (`PermissionRelaunch`); setup draws it as its own main button instead
/// (`showsRelaunchRow: false`).
public struct PermissionGrantView: View {
    let enabled: Bool
    let appURL: URL
    let readAccessibility: () -> Bool
    let readInputMonitoring: () -> Bool
    let embedded: Bool
    let onStatusChange: (Bool, Bool) -> Void
    /// claude/permflash-015: what the cards show of the page's reads (`PermissionSettle`): a moment's "not allowed" from
    /// macOS never turns an Allowed card back into its button. A permission nothing is known about yet draws no state.
    @State private var shown: ShownPermissions
    @State private var read: Bool
    /// A read is set to run once the off reads now waiting have had time to hold.
    @State private var settleReadSet = false
    @State private var openError: String?
    @State private var recoveryExpanded: Bool
    /// A card's System Settings pane was opened from this page and a permission is still missing: the window floats.
    @State private var floating = false
    /// The permission whose pane the window floats for: once it is allowed, the window goes back.
    @State private var floatingFor: DaydreamPermission?
    @State private var window = PermissionWindowLevel()
    /// "Drag the card into the list": only after a pane was opened and its permission is still missing.
    @State private var dragHint: PermissionDragHint
    private let showsRelaunchRow: Bool
    /// Setup's Google Chrome row (owner, 10/2): drawn under the two permission cards, in their style, when setup passes one.
    private let chromeRow: PermissionChromeRow?
    /// Setup's "Let AI apps read what you typed" toggle (owner 10/3), directly under the Google Chrome row.
    private let showsAIReadsToggle: Bool
    @AppStorage(AIReadsTypedSetting.key) private var aiReadsTyped = AIReadsTypedSetting.defaultValue
    /// perm-1004: comings back from a pane opened here with both still off (`PermissionReturns`).
    @State private var returns = PermissionReturns()
    /// A pane was opened from this page since DayDream was last active.
    @State private var paneOpenedThisVisit = false
    /// Other DayDream copies on this Mac (`PermissionRowHelp.lookAlikes`), read as the page appears.
    @State private var otherCopies = 0
    @Environment(\.daydreamPermissionRequests) private var requests
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    public init(enabled: Bool = true, appURL: URL = Bundle.main.bundleURL,
                readAccessibility: @escaping () -> Bool = { AXIsProcessTrusted() },
                readInputMonitoring: @escaping () -> Bool = { CGPreflightListenEventAccess() },
                embedded: Bool = false,
                style: PermissionGrantStyle = .cards,
                recoveryExpandedInitially: Bool = false,
                showsRelaunchRow: Bool = true,
                dragHint: PermissionDragHint = PermissionDragHint(),
                known: PermissionSnapshot = PermissionSnapshot(),
                allowedBefore: Bool = false,
                chromeRow: PermissionChromeRow? = nil,
                showsAIReadsToggle: Bool = false,
                onStatusChange: @escaping (Bool, Bool) -> Void = { _, _ in }) {
        // `known`: what the app last showed of the permissions, so the page opens on it (an Allowed card from its first
        // frame). `allowedBefore`: setup was finished once, so a first read that says off must hold before it shows;
        // false (a first setup, the renders) shows it at once.
        _shown = State(initialValue: ShownPermissions(known: known, allowedBefore: allowedBefore))
        _read = State(initialValue: known.accessibility != nil || known.inputMonitoring != nil)
        self.enabled = enabled
        self.appURL = appURL
        self.readAccessibility = readAccessibility
        self.readInputMonitoring = readInputMonitoring
        self.embedded = embedded || style == .settings
        _recoveryExpanded = State(initialValue: recoveryExpandedInitially)
        _dragHint = State(initialValue: dragHint)
        self.showsRelaunchRow = showsRelaunchRow
        self.chromeRow = chromeRow
        self.showsAIReadsToggle = showsAIReadsToggle
        self.onStatusChange = onStatusChange
    }

    public var body: some View {
        content
        .onAppear {
            refresh()
            if enabled { otherCopies = PermissionRowHelp.lookAlikes(appURL: appURL).count }
            followPaneRequest()
        }
        .onChange(of: requests?.paneRequest) { _ in followPaneRequest() }
        .onReceive(timer) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            returns.returned(paneOpened: paneOpenedThisVisit)
            paneOpenedThisVisit = false
            refresh()
        }
        // The window floats only beside System Settings: another app in front, or System Settings quitting, puts it
        // back, so a half-finished grant never leaves DayDream above Safari, Mail and everything else.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { note in
            guard floating, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  !PermissionWindowFloat.keepsFloating(frontBundle: app.bundleIdentifier, frontPID: app.processIdentifier) else { return }
            floating = false; window.set(floating: false)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { note in
            guard floating, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == PermissionWindowFloat.systemSettingsBundle else { return }
            floating = false; window.set(floating: false)
        }
        .onDisappear { floating = false; window.set(floating: false) }
        .alert("System Settings could not open", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button("OK", role: .cancel) { openError = nil }
        } message: { Text(openError ?? "") }
    }

    /// Missing permissions after the first read; empty before it and in a disabled preview. One whose reads haven't
    /// settled yet (`known` false) is neither missing nor allowed.
    private var missing: [DaydreamPermission] {
        guard enabled, read else { return [] }
        return DaydreamPermission.allCases.filter { known($0) && !allowed($0) }
    }

    private var accessibility: Bool { shown.snapshot.accessibility == true }
    private var inputMonitoring: Bool { shown.snapshot.inputMonitoring == true }

    private func allowed(_ permission: DaydreamPermission) -> Bool {
        permission == .accessibility ? accessibility : inputMonitoring
    }

    private func known(_ permission: DaydreamPermission) -> Bool {
        (permission == .accessibility ? shown.snapshot.accessibility : shown.snapshot.inputMonitoring) != nil
    }

    private var relaunch: PermissionRelaunch? {
        guard enabled, read, requests?.quitAndReopen != nil else { return nil }
        return PermissionRelaunch.reason(inputMonitoringAtLaunch: requests?.inputMonitoringAtLaunch, accessibility: accessibility,
                                         inputMonitoring: inputMonitoring)
    }

    /// This copy's name as System Settings lists it ("DayDream", "DayDream Live Test").
    private var appName: String { PermissionRowHelp.appName(appURL: appURL) }

    /// Back twice from System Settings with both still off: the remove-and-add-again step comes first.
    private var showsReAddFirst: Bool {
        enabled && read && moveWarning == nil && missing.count == DaydreamPermission.allCases.count
            && returns.showsReAddFirst(accessibility: accessibility, inputMonitoring: inputMonitoring)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !embedded { header }
            if let move = moveWarning { moveBanner(move) }
            if showsReAddFirst { reAddBanner }
            ForEach(DaydreamPermission.allCases) { permission in permissionCard(permission) }
            if let chromeRow { chromeCard(chromeRow) }
            if showsAIReadsToggle { aiReadsCard }
            // Its room is kept while a permission is missing, so nothing moves when it appears (owner: controls never shift).
            if !missing.isEmpty && moveWarning == nil {
                Label(PermissionRowHelp.dragHint(appName: appName), systemImage: "hand.point.up.left")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4).padding(.top, 2)
                    .opacity(dragHint.shows ? 1 : 0)
                    .accessibilityHidden(!dragHint.shows)
                    .permissionElement(dragHint.shows ? "dragHint" : "dragHint.hidden")
                // perm-1004: other DayDream copies can be listed too; say which row is this one.
                if let line = PermissionRowHelp.rowLine(appName: appName, otherCopies: otherCopies) {
                    Text(line).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .permissionElement("rowLine")
                }
            }
            // Quit & Reopen, or (when reopening isn't the next step) the recovery steps: never both. Setup shows
            // Quit & Reopen as its main button, so it draws no row here.
            if relaunch != nil, requests?.autoRelaunch == true {
                // perm-1004: DayDream restarts by itself; one line, no button (setup too).
                autoRelaunchRow
            } else if let relaunch, let quitAndReopen = requests?.quitAndReopen {
                if showsRelaunchRow { relaunchRow(relaunch, quitAndReopen) }
            } else if !missing.isEmpty { recovery }
        }
        .padding(.horizontal, embedded ? 0 : 36).padding(.top, embedded ? 0 : 28).padding(.bottom, embedded ? 0 : 34)
        .frame(width: embedded ? nil : 660).background(embedded ? Color.clear : Self.windowColor)
    }

    /// "Already turned on in System Settings?" (coordinator 10/3: a row left from a copy signed differently reads on
    /// there and off here; removing it and adding it again is the fix).
    public static func recoveryText(appName: String) -> String {
        "If \u{201C}\(appName)\u{201D} is on in System Settings but still off here, that row belongs to an older copy. Select it, remove it with the minus (\u{2212}) button first, then drag the card in again and turn it on. Switching the old row on or dragging onto it changes nothing."
    }

    /// Under the cards once a card's pane was opened and its permission is still missing (`PermissionDragHint`). Dragging
    /// is the step: DayDream never asks macOS for a permission, so it is never in either list until its card is dragged
    /// in (or added with the + button).
    public static let dragHint = "Drag the card into the list, then turn DayDream on."

    private var header: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable().interpolation(.high).frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text("Grant DayDream Permissions")
                .font(.system(size: 26, weight: .bold)).foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    private func permissionCard(_ permission: DaydreamPermission) -> some View {
        let isAllowed = allowed(permission)
        let draggable = enabled && moveWarning == nil
        return HStack(spacing: 14) {
            permissionIcon(permission)
            VStack(alignment: .leading, spacing: 3) {
                Text(permission.title).font(.system(size: 15, weight: .semibold))
                Text(permission.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if !enabled {
                    Text("Unavailable in this preview").font(.system(size: 12)).foregroundStyle(.secondary)
                } else if !read || !known(permission) {
                    EmptyView()
                } else if isAllowed {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Self.green)
                        Text("Allowed").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                } else {
                    Button { open(permission) } label: { OpenSystemSettingsLabel() }
                        .buttonStyle(PermissionButtonStyle(prominent: true)).disabled(!draggable)
                        .accessibilityLabel("Open \(permission.title) in System Settings")
                        .permissionElement("open." + permission.rawValue)
                }
            }
            .fixedSize()
        }
        .padding(.leading, 26).padding(.trailing, 16).padding(.vertical, 12).frame(minHeight: 74)
        // The grip, in the card's left margin, says the card itself is what gets dragged (only while it can be).
        .overlay(alignment: .leading) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary).padding(.leading, 9)
                .opacity(draggable && !isAllowed && read && known(permission) ? 1 : 0)
                .accessibilityHidden(true)
        }
        .background(Self.cardColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)
        .permissionElement("card." + permission.rawValue)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onDrag { PermissionDragPayload.provider(appURL: appURL, enabled: draggable) }
        .contextMenu {
            Button("Show DayDream in Finder") { NSWorkspace.shared.activateFileViewerSelecting([appURL]) }.disabled(!enabled)
            Button("Open \(permission.title) in System Settings") { open(permission) }.disabled(!draggable)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(permission.title + " permission")
        .accessibilityValue(!enabled ? "Unavailable in this preview" : !read || !known(permission) ? "Not checked" : isAllowed ? "Allowed" : "Not allowed")
        .accessibilityHint(permission.purpose)
        .help(PermissionRowHelp.cardHelp(appName: appName, permission: permission.title))
    }

    /// "Let AI apps read what you typed": a toggle card in the permission cards' style, under the Google Chrome row.
    private var aiReadsCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "text.bubble").font(.system(size: 24)).foregroundStyle(.secondary)
                .frame(width: 44, height: 44).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(AIReadsTypedSetting.title).font(.system(size: 15, weight: .semibold))
                Text(AIReadsTypedSetting.line).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: $aiReadsTyped).toggleStyle(.switch).labelsHidden().disabled(!enabled)
                .accessibilityLabel(AIReadsTypedSetting.title)
                .permissionElement("toggle.aiReadsTyped")
        }
        .padding(.leading, 26).padding(.trailing, 16).padding(.vertical, 12).frame(minHeight: 74)
        .background(Self.cardColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)
        .permissionElement("card.aiReadsTyped")
        .accessibilityElement(children: .contain)
    }

    /// Setup's Google Chrome row: the same card as Accessibility and Input Monitoring (icon, name, one line, one button).
    /// Its Allow asks macOS (the caller's `allow`, the app's one ask path) only on the person's press; an answered or
    /// allowed access shows its state like the other rows. It never gates Continue.
    /// chromeask-1005 (owner 10/5): before the press its line says what macOS will ask and why, beside a small drawing of
    /// that question with Allow ringed; refused, "Chrome pages are off." with Ask again (the caller's `askAgain`: macOS
    /// asks again). Nothing here asks macOS or opens Chrome.
    private func chromeCard(_ row: PermissionChromeRow) -> some View {
        let trailing = PermissionChromeRow.trailing(access: row.access, pagesOn: row.pagesOn, canTurnOn: row.turnOn != nil)
        let subtitle = PermissionChromeRow.subtitle(access: row.access, typing: row.typing, opensChrome: row.opensChrome)
        let art = PermissionChromeRow.illustration(access: row.access)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                // The drawing takes the icon's place (it names Chrome itself), so the card grows little and the page
                // still fits: macOS's question, before the press and while it asks.
                Group {
                    switch art {
                    case .ask?:
                        ChromeAskDrawing(chromeIcon: row.icon).permissionElement("chrome.drawing.ask")
                    case nil:
                        Group {
                            if let icon = row.icon { Image(nsImage: icon).resizable().interpolation(.high) }
                            else { Image(systemName: "globe").font(.system(size: 28)).foregroundStyle(.secondary) }
                        }
                        .frame(width: 44, height: 44).accessibilityHidden(true)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(PermissionChromeRow.title).font(.system(size: 15, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .permissionElement("chrome.line")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    switch trailing {
                    case .progress: ProgressView().controlSize(.small)
                    case .allowed:
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Self.green)
                            Text(ChromeAccessState.allowed.value).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    case .refused:
                        if let askAgain = row.askAgain {
                            Button(PermissionChromeRow.askAgainTitle) { askAgain() }
                                .buttonStyle(PermissionButtonStyle(prominent: true)).disabled(!enabled)
                                .accessibilityHint(ChromeAccessNotice.askAgainHint)
                                .permissionElement("askagain.chrome")
                        } else {
                            Button { row.openSettings() } label: { OpenSystemSettingsLabel() }
                                .buttonStyle(PermissionButtonStyle(prominent: true)).disabled(!enabled)
                                .accessibilityLabel("Open Automation in System Settings")
                                .accessibilityHint(subtitle)
                                .permissionElement("open.chrome")
                        }
                    case .turnOn:
                        Button(PermissionChromeRow.turnOnTitle) { row.turnOn?() }
                            .buttonStyle(PermissionButtonStyle(prominent: true)).disabled(!enabled)
                            .accessibilityLabel("Turn on saving web pages in Google Chrome")
                            .permissionElement("pages.chrome")
                    case .allow:
                        Button(PermissionChromeRow.allowTitle) { row.allow() }
                            .buttonStyle(PermissionButtonStyle(prominent: true)).disabled(!enabled)
                            .accessibilityLabel("Allow Google Chrome")
                            .accessibilityHint(subtitle)
                            .permissionElement("allow.chrome")
                    }
                }
                .fixedSize()
            }
            .padding(.leading, art == nil ? 26 : 14).padding(.trailing, 16).padding(.vertical, art == nil ? 12 : 10).frame(minHeight: 74)
            .background(Self.cardColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)
            .permissionElement("card.chrome")
            .accessibilityElement(children: .contain)
            .accessibilityLabel(PermissionChromeRow.title)
            .accessibilityValue(row.access.value)
            if let line = PermissionChromeRow.line(access: row.access, asked: row.asked, pagesOn: row.pagesOn, settings: row.settings) {
                Text(line).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                    .permissionElement("chrome.below")
            }
        }
    }

    @ViewBuilder private func permissionIcon(_ permission: DaydreamPermission) -> some View {
        if permission == .accessibility,
           let icon = NSImage(contentsOfFile: "/System/Library/PreferencePanes/UniversalAccessPref.prefPane/Contents/Resources/UniversalAccessPref.icns") {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 44, height: 44).accessibilityHidden(true)
        } else {
            PermissionTile(permission: permission, size: 44)
        }
    }

    /// perm-1004: a `Turn on …` press elsewhere asked for this permission's pane: open it once, as its card's button
    /// would, if it is still missing. A request for an allowed permission is dropped.
    private func followPaneRequest() {
        guard let raw = requests?.paneRequest else { return }
        requests?.paneRequestHandled()
        guard enabled, moveWarning == nil, let permission = DaydreamPermission(rawValue: raw) else { return }
        refresh()
        guard !allowed(permission) else { return }
        // On the next turn, once this page's window is in front and key (the floating level follows the key window).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { open(permission) }
    }

    /// Opens the permission's pane. Only ever runs on a press (a card's button, or a `Turn on …` press elsewhere).
    private func open(_ permission: DaydreamPermission) {
        guard enabled, moveWarning == nil else { return }
        // The press came from this page's window, so it is the key window now (a sheet's parent floats with it).
        let pressed = NSApp.keyWindow
        if NSWorkspace.shared.open(permission.settingsURL) {
            paneOpenedThisVisit = true
            // System Settings comes to the front: keep this window (and its cards) above it until this permission is
            // allowed (or both are), another app comes to the front, or System Settings quits.
            floating = true
            floatingFor = permission
            window.window = pressed
            window.set(floating: true)
            dragHint.paneOpened(permission.rawValue, at: Date())
        } else {
            openError = "Open System Settings from the Apple menu, then choose Privacy & Security > \(permission.title)."
        }
    }

    /// DayDream runs from the download window (the app's `LaunchLocation`): granting now would go to a copy.
    private var moveWarning: String? { enabled ? requests?.moveWarning : nil }

    /// One line and the button, only when macOS needs DayDream to reopen.
    private func relaunchRow(_ reason: PermissionRelaunch, _ quitAndReopen: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor).accessibilityHidden(true)
            Text(reason.text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(PermissionRequestActions.quitAndReopenTitle, action: quitAndReopen)
                .buttonStyle(PermissionButtonStyle(prominent: true)).fixedSize()
                .permissionElement("quitAndReopen")
                .help("Quits DayDream and opens it again.")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// perm-1004: back twice from System Settings with both still off. The row turned on there is not this copy's (an
    /// older copy's row, or this name signed differently): the one step that fixes it, first.
    private var reAddBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "minus.circle").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Self.orange).accessibilityHidden(true)
            Text(PermissionRowHelp.reAddStep(appName: appName)).font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Self.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Self.orange.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .permissionElement("reAdd")
    }

    /// perm-1004: DayDream restarts by itself to use Input Monitoring (`PermissionRelaunch.autoText`).
    private var autoRelaunchRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(PermissionRelaunch.autoText).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .permissionElement("autoRelaunch")
    }

    /// Collapsed: what to do when a permission is on in System Settings but DayDream still reads it as off.
    private var recovery: some View {
        DisclosureGroup(isExpanded: $recoveryExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.recoveryText(appName: appName))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    // The first step as a button, where DayDream can reopen itself.
                    if enabled, moveWarning == nil, let quitAndReopen = requests?.quitAndReopen {
                        Button(action: quitAndReopen) {
                            Label(PermissionRequestActions.quitAndReopenTitle, systemImage: "arrow.triangle.2.circlepath")
                        }.buttonStyle(.link).font(.system(size: 11.5))
                        .permissionElement("recovery.quitAndReopen")
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([appURL])
                    } label: {
                        Label("Show DayDream in Finder", systemImage: "folder")
                    }.buttonStyle(.link).font(.system(size: 11.5)).disabled(!enabled)
                }
            }.padding(.top, 6)
        } label: {
            Text("Already turned on in System Settings?").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .permissionElement("recovery")
    }

    /// "Move DayDream to Applications first." with the reason and a button that opens Applications.
    private func moveBanner(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Self.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(warning).font(.system(size: 13, weight: .semibold))
                if let detail = requests?.moveDetail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(PermissionRequestActions.openApplicationsTitle) { requests?.openApplications() }
                .buttonStyle(PermissionButtonStyle(prominent: true)).fixedSize()
        }
        .padding(12)
        .background(Self.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Self.orange.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func refresh() {
        guard enabled else { return }
        var next = shown
        next.read(PermissionSnapshot(accessibility: readAccessibility(), inputMonitoring: readInputMonitoring()), at: Date())
        if next != shown { shown = next }
        if !read { read = true }
        // An off read waiting to hold is read again once it has had the time (the page's own timer is 2 s).
        if next.unsettled, !settleReadSet {
            settleReadSet = true
            DispatchQueue.main.asyncAfter(deadline: .now() + PermissionSettle.settle + 0.1) { settleReadSet = false; refresh() }
        }
        let accessibility = next.snapshot.accessibility == true, inputMonitoring = next.snapshot.inputMonitoring == true
        if (accessibility || inputMonitoring) && returns.count > 0 { returns.reset() }
        // Set only when it changes (an unchanged hint never redraws the page).
        var hint = dragHint
        hint.read([DaydreamPermission.accessibility.rawValue: accessibility, DaydreamPermission.inputMonitoring.rawValue: inputMonitoring],
                  at: Date())
        if hint != dragHint { dragHint = hint }
        if floating && accessibility && inputMonitoring { floating = false; window.set(floating: false) }
        // The pane's own permission is allowed (macOS may now show its Quit & Reopen sheet there: never cover it), or
        // another app is in front (a notice that was missed).
        if floating, PermissionWindowFloat.lowers(allowedNow: floatingFor.map { $0 == .accessibility ? accessibility : inputMonitoring } ?? false,
                                                  frontBundle: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                                  frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) {
            floating = false; window.set(floating: false)
        }
        onStatusChange(accessibility, inputMonitoring)
    }

    // Local tokens: this file compiles on its own (permission-window and permission-refresh checks),
    // so it mirrors the DayDream style values instead of importing them.
    private static let orange = Color(nsColor: .systemOrange)
    private static let green = Color(nsColor: .systemGreen)
    private static let windowColor = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.14, alpha: 1) : NSColor(srgbRed: 0.92, green: 0.93, blue: 0.945, alpha: 1)
    })
    private static let cardColor = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.21, alpha: 1) : NSColor(srgbRed: 0.97, green: 0.975, blue: 0.985, alpha: 1)
    })
}

/// When the permission window stops floating (`PermissionGrantView`): it floats only while System Settings, where the
/// card is dragged, or DayDream itself (a card being dragged) is in front, and only until the permission whose pane it
/// opened is allowed. Pure, so the checks pin it; only the frontmost app's bundle ID and process ID are compared, in
/// memory.
public enum PermissionWindowFloat {
    /// System Settings (and System Preferences before it).
    public static let systemSettingsBundle = "com.apple.systempreferences"

    /// Whether the window keeps floating while this app is in front.
    public static func keepsFloating(frontBundle: String?, frontPID: pid_t?,
                                     ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> Bool {
        frontPID == ownPID || frontBundle == systemSettingsBundle
    }

    /// Whether a floating window goes back now: its permission is allowed, or another app is in front (an unknown
    /// front app, as while apps switch, changes nothing).
    public static func lowers(allowedNow: Bool, frontBundle: String?, frontPID: pid_t?,
                              ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> Bool {
        if allowedNow { return true }
        guard frontPID != nil || frontBundle != nil else { return false }
        return !keepsFloating(frontBundle: frontBundle, frontPID: frontPID, ownPID: ownPID)
    }
}

/// The window a permission page is in (the key window when a card's button was pressed), and the sheet's parent
/// when the page is in a sheet (Settings), raised to `.floating` while System Settings is open for a missing
/// permission and put back afterwards (both allowed, or the page closed). Only DayDream's own windows change level;
/// nothing about System Settings is touched.
final class PermissionWindowLevel {
    weak var window: NSWindow?
    private var raised: [(window: NSWindow, level: NSWindow.Level)] = []

    func set(floating: Bool) {
        if floating {
            guard raised.isEmpty, let window else { return }
            for w in [window, window.sheetParent].compactMap({ $0 }) where w.level.rawValue < NSWindow.Level.floating.rawValue {
                raised.append((w, w.level))
                w.level = .floating
            }
        } else {
            for (w, level) in raised where w.level == .floating { w.level = level }
            raised = []
        }
    }
}

/// Grey capsule; `prominent` is blue.
private struct PermissionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.white : Color.primary).padding(.horizontal, 13).frame(height: 28)
            .background(prominent ? Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1)
                        : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08), in: Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
    }
}

/// `Open System Settings ↗`.
private struct OpenSystemSettingsLabel: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Open System Settings")
            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
        }
    }
}

/// A System Settings pane tile: SF `accessibility` on blue, `keyboard` on grey.
private struct PermissionTile: View {
    let permission: DaydreamPermission
    let size: CGFloat
    var body: some View {
        let colors = permission == .accessibility
            ? [Color(.sRGB, red: 0.35, green: 0.66, blue: 1, opacity: 1), Color(.sRGB, red: 0.12, green: 0.40, blue: 0.94, opacity: 1)]
            : [Color(.sRGB, red: 0.56, green: 0.58, blue: 0.62, opacity: 1), Color(.sRGB, red: 0.31, green: 0.32, blue: 0.36, opacity: 1)]
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay {
                Image(systemName: permission.tileSymbol)
                    .font(.system(size: size * (permission == .accessibility ? 0.52 : 0.44), weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
            .accessibilityHidden(true)
    }
}

/// Setup's Google Chrome row on the Permissions card (owner, 10/2): shown while Chrome is installed and its access isn't
/// decided (the app decides: `DaydreamOnboardingChromeRow`). `allow` is the app's one ask path, called only on a press.
/// chromeask-1005 (owner 10/5): macOS asks once and never again after Don't Allow, so the row primes the question before
/// the press (`primer`, with `ChromeAskDrawing`) and, once refused, says so (`offLine`) beside Ask again (`askAgain`:
/// the app clears its own Automation answer and macOS asks again, in context).
public struct PermissionChromeRow {
    public let icon: NSImage?
    public let access: ChromeAccessState
    /// Allow was pressed on this card (a press macOS couldn't answer says why under the row).
    public let asked: Bool
    public let allow: () -> Void
    public let openSettings: () -> Void
    /// Settings › Permissions (owner, 10/2): the row is always there while Chrome is installed. "Save web pages in Google
    /// Chrome" as saved now, and the one click that turns it on when access is allowed but recording Chrome is off.
    public let pagesOn: Bool
    public let turnOn: (() -> Void)?
    /// Settings' row: a refusal says where to allow it without a press on this page.
    public let settings: Bool
    /// Typing is on (setup's switch, or the saved one): the primer says the page is what you're typing on.
    public let typing: Bool
    /// Setup's Allow opens a closed Chrome in the background first (`askChromeAccessInSetup`), and the primer says so.
    public let opensChrome: Bool
    /// Refused: the app's Ask again (`askChromeAgain`). nil keeps Open System Settings (`openSettings`).
    public let askAgain: (() -> Void)?

    public init(icon: NSImage?, access: ChromeAccessState, asked: Bool, allow: @escaping () -> Void, openSettings: @escaping () -> Void,
                pagesOn: Bool = true, turnOn: (() -> Void)? = nil, settings: Bool = false, typing: Bool = true, opensChrome: Bool = false,
                askAgain: (() -> Void)? = nil) {
        self.icon = icon; self.access = access; self.asked = asked; self.allow = allow; self.openSettings = openSettings
        self.pagesOn = pagesOn; self.turnOn = turnOn; self.settings = settings; self.typing = typing; self.opensChrome = opensChrome
        self.askAgain = askAgain
    }

    public static let title = "Google Chrome"
    public static let reason = ChromePagesCard.setupLine
    public static let allowTitle = "Allow"
    /// Before the press (owner 10/5): what macOS will ask, and why, in one breath.
    public static let primer = "macOS will ask once. Click Allow so DayDream knows which page you're typing on."
    /// The same with typing off: the page is still what DayDream reads, just not for typing.
    public static let primerTypingOff = "macOS will ask once. Click Allow so DayDream knows which Chrome page you're on."
    /// Setup with Chrome closed: Allow opens it in the background so macOS can ask now, from this press, never later.
    public static let opensChromeLine = "Chrome opens in the background to ask."
    /// Refused (owner 10/5): short, beside Ask again (DayDream clears its own answer, and macOS asks again).
    public static let offLine = "Chrome pages are off."
    public static let askAgainTitle = ChromeAccessNotice.askAgainTitle

    public enum Trailing: Equatable, Sendable { case progress, allowed, refused, allow, turnOn }
    /// The drawing in the icon's place: macOS's question with Allow ringed (before and while it asks).
    public enum Illustration: Equatable, Sendable { case ask }
    public static let turnOnTitle = "Turn On"
    public static let pagesOffLine = "Chrome access is allowed, but saving web pages in Chrome is off."

    /// The line under the title: the primer until macOS answered, "Chrome pages are off." once refused, else what
    /// Chrome pages save.
    public static func subtitle(access: ChromeAccessState, typing: Bool, opensChrome: Bool) -> String {
        switch access {
        case .unknown, .notAsked, .chromeNotRunning, .checking:
            let primer = typing ? primer : primerTypingOff
            return opensChrome && access != .checking ? primer + " " + opensChromeLine : primer
        case .denied, .askFailed: return offLine
        case .allowed, .unverified, .twoCopies: return reason
        }
    }
    public static func illustration(access: ChromeAccessState) -> Illustration? {
        switch access {
        case .unknown, .notAsked, .chromeNotRunning, .checking: return .ask
        case .denied, .askFailed, .allowed, .unverified, .twoCopies: return nil
        }
    }
    /// Settings' row: Allowed with recording Chrome off offers Turn On (one click); everything else as setup's row.
    public static func trailing(access: ChromeAccessState, pagesOn: Bool, canTurnOn: Bool) -> Trailing {
        access == .allowed && !pagesOn && canTurnOn ? .turnOn : trailing(access: access)
    }
    public static func line(access: ChromeAccessState, asked: Bool, pagesOn: Bool, settings: Bool) -> String? {
        if access == .allowed && !pagesOn { return pagesOffLine }
        guard settings else { return line(access: access, asked: asked) }
        switch access {
        case .unverified, .twoCopies, .chromeNotRunning: return access.helper
        case .denied, .askFailed, .checking, .allowed, .notAsked, .unknown: return nil
        }
    }
    /// The row's one control: a spinner while macOS asks or a read runs, Allowed, Ask again once refused, else Allow.
    /// Every state has its way on, and none of them holds Continue.
    public static func trailing(access: ChromeAccessState) -> Trailing {
        switch access {
        case .checking: return .progress
        case .allowed: return .allowed
        case .denied, .askFailed: return .refused
        case .unknown, .notAsked, .chromeNotRunning, .unverified, .twoCopies: return .allow
        }
    }
    /// The one line under the row: nothing before the press, and nothing once refused (the row's own line says so,
    /// beside Ask again); after a press macOS couldn't answer, why (Chrome didn't open, can't be verified, two copies).
    public static func line(access: ChromeAccessState, asked: Bool) -> String? {
        guard asked else { return nil }
        switch access {
        case .chromeNotRunning, .unverified, .twoCopies: return access.helper
        case .unknown, .notAsked, .checking, .allowed, .denied, .askFailed: return nil
        }
    }
}

// MARK: - Chrome drawings (chromeask-1005)

/// The two small drawings on the Chrome row, drawn rather than pictured so they stay sharp at every scale and follow
/// light and dark. Nothing in them is a control: they only show what macOS shows.
private enum ChromeDrawingStyle {
    /// macOS's alert and Settings panels.
    static let panel = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 1, alpha: 1)
    })
    static let quietButton = Color.primary.opacity(0.09)
    static let textBar = Color.primary.opacity(0.13)
    static let ring = Color.accentColor.opacity(0.45)

    static func icon(_ image: NSImage?, fallback: String, size: CGFloat) -> some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high) }
            else { Image(systemName: fallback).resizable().scaledToFit().foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size)
    }
    static var appIcon: NSImage? { NSApp?.applicationIconImage }
}

/// macOS's Automation question as it will appear, small: DayDream's icon (Chrome's on it), the question, and Don't
/// Allow beside Allow, with Allow ringed (the button to press).
struct ChromeAskDrawing: View {
    let chromeIcon: NSImage?
    static let width: CGFloat = 140

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                ChromeDrawingStyle.icon(ChromeDrawingStyle.appIcon, fallback: "app.fill", size: 16)
                ChromeDrawingStyle.icon(chromeIcon, fallback: "globe", size: 8).offset(x: 3, y: 2)
            }
            Text("\u{201C}DayDream\u{201D} wants access to control \u{201C}Google Chrome\u{201D}.")
                .font(.system(size: 6.8, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                Text("Don\u{2019}t Allow").font(.system(size: 6.5)).frame(maxWidth: .infinity).frame(height: 13)
                    .background(ChromeDrawingStyle.quietButton, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text("Allow").font(.system(size: 6.5, weight: .semibold)).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 13)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(ChromeDrawingStyle.ring, lineWidth: 2).padding(-3))
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 9).padding(.top, 7).padding(.bottom, 8)
        .frame(width: Self.width)
        .background(ChromeDrawingStyle.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("macOS will show: DayDream wants access to control Google Chrome. Click Allow.")
    }
}

