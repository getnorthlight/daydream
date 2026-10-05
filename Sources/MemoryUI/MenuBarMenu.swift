import SwiftUI
import AppKit

// The menu bar panel, drawn as a plain macOS menu (the owner's choice, option A "Native menu", Sep 2026):
//
//     DayDream                                   [ switch ]
//     ● Recording since 8:38 AM
//     ⌨ Recording what you type in Notes          (only while typing is on)
//     ──────────────────────────────────────────────
//     Pause                                            ›   For 5 / 15 (⌘P) / 30 Minutes, 2 Hours, Pause Typing ⌃⌥⌘T
//     ──────────────────────────────────────────────
//     4 moments remembered today               [][][]
//     ──────────────────────────────────────────────
//     Search…
//     Open DayDream                                   ⌘O
//     DayDream Settings…                              ⌘,
//     ──────────────────────────────────────────────
//     Report a Problem…
//     Restart to Update                                  (only while a downloaded update waits)
//     Quit DayDream                                   ⌘Q
//
// One signal per job: the status line says what is happening, the one switch turns DayDream on (recording or
// paused) and off (stopped), `Pause ›` holds every pause length, and when recording can't start one button in the
// switch's place fixes it. The rows are the same in every state, so nothing jumps.
//
// Value-driven, like the card it replaces: the host passes the presentation, today's snapshot, the typing rows and
// the actions; nothing here reads a store, the system or the clock beyond `KitClock` (which `\.daydreamNow` pins).
// Rendering, measuring and hovering call no action. The host (`MenuBarExtra(.window)`) supplies the window and its
// material, so the panel draws no background of its own.

/// The menu bar panel. `presentation == nil` is the isolated preview: the status line and `Quit DayDream`.
/// Always `MenuBarMenu.width` wide: long copy wraps, it never widens the panel.
public struct MenuBarMenu: View {
    public static let width: CGFloat = 320
    public static let identifier = "menubar-menu"
    public static let isolatedLine = "Isolated preview · Recording is off"
    /// The status line while launch prepares the history before the app opens it (gold r2-store-perf): the window says
    /// the same, and nothing records.
    public static let preparingLine = "Getting ready…"
    public static let emptyTodayLine = "Nothing recorded yet today"
    /// ⌘P: pauses for 15 minutes while recording, resumes while paused (the panel is its own key window).
    public static let pauseKey = KeyboardShortcut("p", modifiers: .command)
    public static let pauseKeys = "⌘P"
    /// The length ⌘P pauses for (`For 15 Minutes`).
    public static let pauseKeyMinutes = 15
    /// The least space between the header's words and its switch or button.
    public static let controlGap: CGFloat = 12

    // MARK: - Model (the checks read the same values the view draws)

    /// The line under `DayDream`: a coloured glyph and a few plain words.
    public struct Status: Equatable, Sendable {
        public enum Tone: Equatable, Sendable {
            /// Red dot: recording.
            case recording
            /// Indigo pause: paused.
            case paused
            /// Grey ring: not recording.
            case off
            /// Orange "!": recording can't start until something is done (orange words).
            case attention
        }
        public var tone: Tone
        public var text: String
        /// The whole sentence when `text` is its shorter menu form (the tooltip and the VoiceOver hint); nil otherwise.
        public var detail: String?
        public init(tone: Tone, text: String, detail: String? = nil) { self.tone = tone; self.text = text; self.detail = detail }
    }

    /// What the one button in the switch's place does when recording can't start.
    public enum Fix: Equatable, Sendable {
        /// DayDream's guided setup (the host opens it at the first step still missing: permissions come first).
        case setUp
        /// Setup is finished and only a permission is off: the DayDream permissions window (the drag cards and
        /// Done), so allowing it never walks the person through setup again.
        case permissions
        /// No setup window here (for example without a host route): System Settings at that permission's pane
        /// (nil: Privacy & Security). Opening System Settings never requests a permission.
        case systemSettings(PermissionKind?)
        /// Finder at Applications, while DayDream runs from the download window.
        case applications
        /// A Settings section (`DaydreamSettingsPage(section:)`; "Setup" is the overview, whose status line says what
        /// stops recording).
        case settings(String)
    }

    /// The header's right-hand control.
    public enum Control: Equatable, Sendable {
        /// The one switch: on while recording or paused, off while stopped.
        case toggle(on: Bool, enabled: Bool)
        /// A small blue button that fixes what keeps recording off.
        case fix(title: String, fix: Fix)
        /// The isolated preview.
        case none
    }

    /// The row under the header.
    public enum StateRow: Equatable, Sendable {
        /// `Pause ›`, a submenu of lengths. Disabled unless recording.
        case pause(enabled: Bool)
        /// `Resume Now ⌘P` while paused.
        case resume(enabled: Bool)
    }

    public struct Header: Equatable, Sendable {
        public var status: Status
        /// The operational issue (`CapturePresentation.attentionLine`), a second orange line; nil for none.
        public var attention: String?
        public var control: Control
        /// nil only in the isolated preview.
        public var stateRow: StateRow?
        /// The menu bar icon draws its "!" exactly while the status line is orange: recording can't start until
        /// something is done, whether or not a button here can do it (another copy open, say).
        public var needsSetup: Bool { status.tone == .attention }
        public init(status: Status, attention: String?, control: Control, stateRow: StateRow?) {
            self.status = status; self.attention = attention; self.control = control; self.stateRow = stateRow
        }
    }

    /// The header for `p` (nil: the isolated preview, or `offLine`'s state with no model yet).
    /// - `canSetUp`: the host can open DayDream's guided setup (outside the Development Trial).
    /// - `canOpenApplications`: the host can open the Applications folder (only from the download window).
    /// - `canOpenPermissions`: setup is finished and the host can open the DayDream permissions window, so a missing
    ///   permission is allowed there rather than in setup.
    public static func header(_ p: CapturePresentation?, now: Date, timeZone: TimeZone, canSetUp: Bool,
                              canOpenApplications: Bool, canOpenPermissions: Bool = false, offLine: String = isolatedLine) -> Header {
        guard let p else {
            return Header(status: Status(tone: .off, text: offLine), attention: nil, control: .none, stateRow: nil)
        }
        let attention = p.attentionLine(now: now, timeZone: timeZone).map { attentionWords[$0] ?? $0 }
        switch p.state {
        case .recording(let since):
            return Header(status: Status(tone: .recording, text: since.map { "Recording since " + DaydreamFormat.time($0, timeZone) } ?? "Recording"),
                          attention: attention, control: .toggle(on: true, enabled: p.canStop), stateRow: .pause(enabled: true))
        case .paused(let until, _, let reason):
            let status: Status
            if let until, until > now {
                status = Status(tone: .paused, text: "Paused · resumes " + DaydreamFormat.time(until, timeZone))
            } else if let reason {
                status = line(.paused, reason, short: pausedWords[reason])
            } else {
                status = Status(tone: .paused, text: until == nil ? "Paused until you resume" : "Paused")
            }
            return Header(status: status, attention: attention,
                          control: .toggle(on: true, enabled: p.canStop), stateRow: .resume(enabled: p.canResume))
        case .needsPermission(let missing):
            // perm-1004: the button says what it turns on (`Turn on Accessibility`, Accessibility first). int-015: the line
            // beside it doesn't name it again (`Input Monitoring is off` beside `Turn on Input Monitoring` wrapped the
            // header to two lines and the panel grew): `Not recording`, or `2 permissions are off` while both are.
            let next = PermissionKind.next(missing)
            let fix: Fix = canOpenPermissions ? .permissions : canSetUp ? .setUp : .systemSettings(next)
            return Header(status: Status(tone: .attention, text: permissionLine(missing)), attention: attention,
                          control: .fix(title: next?.turnOnTitle ?? permissionsFixTitle, fix: fix), stateRow: .pause(enabled: false))
        case .off(_, let reason):
            let row = StateRow.pause(enabled: false)
            guard !p.canResume, let reason else {
                // Startable (or stopped with nothing to say): the switch, off.
                let text = p.canResume ? (reason.map(sentence) ?? "Not recording") : "Not recording"
                return Header(status: Status(tone: .off, text: text), attention: attention,
                              control: .toggle(on: false, enabled: p.canResume), stateRow: row)
            }
            let blocked = blocker(reason, canSetUp: canSetUp, canOpenApplications: canOpenApplications)
            return Header(status: blocked.status, attention: attention,
                          control: blocked.fix.map { .fix(title: $0.title, fix: $0.fix) } ?? .toggle(on: false, enabled: false),
                          stateRow: row)
        }
    }

    /// The status for `reason` (RecordingCopy's words): its shorter menu form when it has one, keeping the whole
    /// sentence as the detail; else the sentence without its final period.
    static func line(_ tone: Status.Tone, _ reason: String, short: String?) -> Status {
        guard let short else { return Status(tone: tone, text: sentence(reason)) }
        return Status(tone: tone, text: short, detail: reason)
    }

    /// Pause reasons (RecordingCopy's words) that are too long for one line beside the switch, in the menu's words.
    /// Every one is under 200 pt at 11.5 pt; the switch leaves about 225 pt.
    static let pausedWords: [String: String] = [
        "Paused while your Mac slept or you switched users.": "Paused while you were away",
        "Your pause ended. Resume when you're ready.": "Paused · didn't resume on its own",
        "Your pause ended because something changed. Review Settings.": "Paused · something changed",
        "Keyboard and mouse input was interrupted. Resume when you're ready.": "Paused · input was interrupted",
        RecordingCopy.storageAttention: "Paused · storage needs attention",
        RecordingCopy.savingRetry: "Paused · trying to save again",
        RecordingCopy.savingRetryPersistent: "Paused · can't save right now",
        RecordingCopy.savingRetryFull: "Paused · Mac is out of space",
        RecordingCopy.savingFailed: "Paused · couldn't save",
        RecordingCopy.notResumed: "Paused · didn't resume on its own",
        RecordingCopy.waitingForOperation: "Paused · import or backup running",
        RecordingCopy.inputUnreachable: "Paused · can't see keys or clicks",
        RecordingCopy.interrupted: "Paused · recording was interrupted",
        RecordingCopy.replacementReview: "Paused · replacement needs review",
        RecordingCopy.permissionsRequired: "Paused · a permission is off",
        "Nothing is recorded until you start again.": "Paused until you resume",
    ]
    /// The operational issue in fewer words, where the full line would not leave room for its chevron.
    static let attentionWords: [String: String] = [
        "Keyboard and mouse recording needs attention": "Keyboard and mouse need attention",
    ]

    /// The line after a launch repaired a damaged history and some of it couldn't be read (the app's StoreIntegrity,
    /// gold G45). It leads to Backup and restore, where Restore is and the damaged file can be deleted.
    public static let historySetAsideLine = "Some history couldn't be read"
    /// Where the orange attention line (its words, in full or in the menu's) leads: the Settings page that fixes it.
    /// - a history set aside at launch (`historySetAsideLine`): Backup and restore;
    /// - app choices that didn't save: the Apps page, which shows the problem and its one button;
    /// - a history, backup or replacement operation: Advanced (Import history, Backup and the replacement controls);
    /// - anything else, keyboard and mouse included: the overview ("General"), whose status line says what stops
    ///   recording and holds the one button that fixes it (Resume there goes to Quit & Reopen when keyboard and mouse
    ///   can't reach DayDream). Never Advanced for a problem it can't fix.
    /// A line whose fix is to run the job again (`RecordingCopy.retriedIssues`) opens no page: `attentionAction`.
    public static func attentionSection(_ line: String?) -> String {
        switch line {
        case historySetAsideLine?: return "Backup"
        case RecordingCopy.choicesUnsaved?: return DaydreamSettingsPage.apps.title
        case "Finish history operation before recording"?, RecordingCopy.replacementReview?: return "Advanced"
        default: return "General"
        }
    }

    /// What pressing the orange attention line does: open the Settings page that fixes it, or run the job that didn't
    /// work again (the history upkeep, a deletion), which is the one thing that fixes those. The menu bar panel and the
    /// toolbar's status popover draw the same line and do the same; the Settings card's one button matches it.
    public enum AttentionAction: Equatable, Sendable {
        /// A Settings section (`DaydreamSettingsPage(section:)`); the line ends in a chevron.
        case open(String)
        /// `CaptureActions.retryIssue`; the line ends in Try Again.
        case retry
    }
    public static func attentionAction(_ line: String?) -> AttentionAction {
        if let line, RecordingCopy.retriedIssues.contains(line) { return .retry }
        return .open(attentionSection(line))
    }
    /// VoiceOver's hint for a line that ends in Try Again.
    public static let retryHint = "Tries again now"

    /// VoiceOver's hint for a line or button that opens `section`: the page it really opens ("Opens DayDream Settings"
    /// for the overview, which is the Settings window itself).
    public static func settingsHint(_ section: String) -> String {
        let page = DaydreamSettingsPage(section: section)
        return page == .overview ? "Opens DayDream Settings" : "Opens \(page.title) in DayDream Settings"
    }

    /// The fix button while which permission is missing isn't known.
    public static let permissionsFixTitle = "Allow…"

    /// The status line beside the permission button, one line: `Not recording` beside `Turn on Accessibility` (or
    /// `Turn on Input Monitoring`), `2 permissions are off` beside `Turn on Accessibility` while both are (the second is
    /// named once the first is on; Settings' line names both), and `A permission is off` beside `Allow…` while which
    /// one isn't known.
    public static func permissionLine(_ missing: Set<PermissionKind>) -> String {
        switch PermissionKind.allCases.filter(missing.contains).count {
        case 1: return "Not recording"
        case 0: return "A permission is off"
        default: return "2 permissions are off"
        }
    }

    /// What keeps recording off, in plain words, and the one button that fixes it (nil: nothing here can).
    static func blocker(_ reason: String, canSetUp: Bool, canOpenApplications: Bool) -> (status: Status, fix: (title: String, fix: Fix)?) {
        let review = (title: "Review…", fix: Fix.settings("Setup"))
        switch reason {
        case RecordingCopy.developmentTrial:
            return (Status(tone: .off, text: "Recording is off in this trial"), nil)
        case RecordingCopy.previewSample:
            return (Status(tone: .off, text: RecordingCopy.previewSample), nil)
        case RecordingCopy.moveToApplications:
            // Under the `DayDream` title, so the line need not name it again (one line beside `Open Applications`).
            return (Status(tone: .attention, text: "Move to Applications first"),
                    canOpenApplications ? (title: "Open Applications", fix: .applications) : nil)
        case RecordingCopy.blocker("Setup required"):
            return (Status(tone: .attention, text: "Setup isn't finished"), canSetUp ? (title: "Finish Setup…", fix: .setUp) : review)
        case RecordingCopy.anotherCopy:
            // Nothing in this copy can fix it, and it clears itself once the other copy lets go: one line, no button.
            return (Status(tone: .attention, text: sentence(reason)), nil)
        case RecordingCopy.blocker("Resume after waking"):
            return (Status(tone: .off, text: sentence(reason)), nil)
        case RecordingCopy.blocker("Storage needs attention"):
            return (Status(tone: .attention, text: "Storage needs attention"), review)
        case RecordingCopy.blocker("Review replacement"):
            // Review… opens Advanced, where the replacement controls are.
            return (Status(tone: .attention, text: "Replacement needs review"), (title: "Review…", fix: .settings("Advanced")))
        case RecordingCopy.operationRunning:
            // It ends by itself: nothing to press.
            return (Status(tone: .off, text: "Import or backup running", detail: reason), nil)
        case RecordingCopy.restorePending:
            return (Status(tone: .attention, text: "Restore needs review", detail: reason), (title: "Review…", fix: .settings("Backup")))
        default:
            return (Status(tone: .attention, text: sentence(reason)), review)
        }
    }

    /// A one-sentence line without its final period (`Paused while your Mac slept`); longer text is kept whole.
    public static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasSuffix("."), !t.dropLast().contains(". ") else { return t }
        return String(t.dropLast())
    }

    /// One item of the Pause submenu.
    public struct PauseItem: Equatable, Sendable, Identifiable {
        public enum Action: Equatable, Sendable { case pause(minutes: Int), typing(TypingMenuRows.Action) }
        public let title: String
        /// The shortcut drawn beside it ("⌘P", "⌃⌥⌘T"); nil draws none.
        public let keys: String?
        public let action: Action
        /// A separator above this item.
        public let separatorBefore: Bool
        public var id: String { title }
        public init(title: String, keys: String?, action: Action, separatorBefore: Bool) {
            self.title = title; self.keys = keys; self.action = action; self.separatorBefore = separatorBefore
        }
    }

    /// `For 5 Minutes`, `For 15 Minutes ⌘P`, `For 30 Minutes`, `For 2 Hours`, then, while typing can be paused,
    /// `Pause Typing for 10 Minutes ⌃⌥⌘T` (the shortcut only while it is registered). Pause › only pauses: while typing
    /// is paused, its line under the status carries Resume.
    public static func pauseItems(typing: TypingMenuRows?) -> [PauseItem] {
        var items = RecordingState.pausePresets.map {
            PauseItem(title: "For " + MenuBarRecordingMenu.presetTitle($0), keys: $0 == pauseKeyMinutes ? pauseKeys : nil,
                      action: .pause(minutes: $0), separatorBefore: false)
        }
        if let t = typing?.menuItem {
            items.append(PauseItem(title: t.title, keys: t.keys, action: .typing(t.action), separatorBefore: true))
        }
        return items
    }

    /// One plain row under the today line, as data.
    public struct Row: Identifiable, Equatable, Sendable {
        public enum Action: Equatable, Sendable { case search, open, settings, setUp, reportProblem, update, quit }
        public let action: Action
        public let title: String
        /// The shortcut the row shows and installs (with ⌘); nil shows none.
        public let key: Character?
        public var id: String { title }
        /// "⌘O", or nil.
        public var keys: String? { key.map { "⌘" + String($0).uppercased() } }
    }

    /// The plain rows, in order; a separator precedes the last group (`Report a Problem…` when offered,
    /// `Restart to Update` while an update waits, and `Quit DayDream`).
    /// - `Set Up DayDream…` only while setup isn't finished, outside the Development Trial, when the host can open
    ///   setup, and when the header isn't already offering it (`Finish Setup…` / `Allow…`).
    /// - `Report a Problem…` (no shortcut) above Quit when the host can open the email (`canReport`); while an
    ///   update waits, its row sits between the two.
    /// - `update`: the title of a waiting update's one action (`Restart to Update`, or `Update DayDream…`), right above
    ///   `Quit DayDream`; nil (no update waiting) shows nothing. It never appears by itself anywhere else.
    /// - Isolated preview: `Quit DayDream` only.
    public static func rows(isolated: Bool, onboardingComplete: Bool, development: Bool, canSetUp: Bool = true,
                            headerOffersSetUp: Bool = false, canReport: Bool = false, update: String? = nil) -> [Row] {
        let quit = Row(action: .quit, title: "Quit DayDream", key: "q")
        guard !isolated else { return [quit] }
        var rows = [Row(action: .search, title: "Search…", key: nil),
                    Row(action: .open, title: "Open DayDream", key: "o"),
                    Row(action: .settings, title: "DayDream Settings…", key: ",")]
        if !onboardingComplete && !development && canSetUp && !headerOffersSetUp {
            rows.append(Row(action: .setUp, title: "Set Up DayDream…", key: nil))
        }
        if canReport { rows.append(Row(action: .reportProblem, title: reportProblemTitle, key: nil)) }
        if let update, !update.isEmpty { rows.append(Row(action: .update, title: update, key: nil)) }
        return rows + [quit]
    }
    /// The menu bar's Report a Problem row; Help has the same item.
    public static let reportProblemTitle = "Report a Problem…"

    /// A waiting update's one action, as the host offers it: its title and what it runs.
    public struct UpdateAction {
        public let title: String
        public let run: () -> Void
        public init(title: String, run: @escaping () -> Void) { self.title = title; self.run = run }
    }

    /// `4 moments remembered today`, `24+ moments remembered today` on a partial day, or `Nothing recorded yet today`.
    public static func todayLine(_ s: TodaySnapshot) -> String {
        DaydreamFormat.momentsRemembered(s.momentCount, complete: !s.partial) ?? emptyTodayLine
    }

    /// The Chrome pages line, exactly while the presentation has one: "Browser history on (Google Chrome)" while
    /// Chrome pages are being saved, "Chrome pages aren't being saved." (with Fix) while they would be but can't.
    /// It is the only live notice that pages are saved, so it is never dropped; one click opens Settings ▸ Apps to
    /// remember, where the switch is.
    public static func chromeLine(_ p: CapturePresentation?) -> String? { p?.browserHistory.text }
    /// Where the Chrome line leads: Settings ▸ Apps to remember (Web pages in Chrome and Chrome access).
    public static let chromeSection = "Recording"
    /// chromeask-1005: the line is "Chrome pages aren't being saved." and ends in Ask again (refused) or Fix (never
    /// asked) (`CaptureActions.fixChrome`) instead of a chevron to Settings.
    public static func chromeFixes(_ p: CapturePresentation?) -> Bool { p?.browserHistory == .needsAccess }
    public static func chromeFixTitle(_ p: CapturePresentation?) -> String { ChromeAccessNotice.title(askAgain: p?.chromeAskAgain == true) }

    /// Up to three of today's top apps with a known bundle (icons only).
    public static func todayApps(_ s: TodaySnapshot) -> [AppTally] {
        Array(s.topApps.filter { $0.bundle != nil }.prefix(3))
    }

    // MARK: - Pause submenu placement (pure, so the checks pin it)

    /// Which side of the panel the Pause submenu opens on.
    public enum SubmenuSide: Equatable, Sendable { case right, left }

    /// Right of the panel, overlapping its edge by 4 pt, as a macOS submenu opens; left of it when the right side
    /// would run past the screen's edge and the left has room (a menu bar icon near the right of the menu bar),
    /// the way a native submenu flips. `row` and `visible` are in screen coordinates; nil `visible`: right.
    public static func submenuSide(row: CGRect, menuWidth: CGFloat, visible: CGRect?) -> SubmenuSide {
        guard let visible else { return .right }
        let rightFits = row.maxX - 4 + menuWidth <= visible.maxX
        let leftFits = row.minX + 4 - menuWidth >= visible.minX
        return !rightFits && leftFits ? .left : .right
    }

    /// Where the submenu's top-left corner goes, in `row`'s own coordinates (`flipped`: y grows downward): 4 pt over
    /// the panel's edge on `side`, its first item level with the row (the menu's top one menu padding above it).
    public static func submenuPoint(side: SubmenuSide, row: CGRect, menuWidth: CGFloat, flipped: Bool) -> CGPoint {
        CGPoint(x: side == .right ? row.maxX - 4 : row.minX + 4 - menuWidth, y: flipped ? row.minY - 5 : row.maxY + 5)
    }

    /// The pointer and its left button, in screen coordinates. The panel reads `NSEvent`; the checks stand in.
    public struct Pointer: Equatable, Sendable {
        public var location: CGPoint
        public var leftButtonDown: Bool
        public init(location: CGPoint, leftButtonDown: Bool) { self.location = location; self.leftButtonDown = leftButtonDown }
        @MainActor public static var system: Pointer {
            Pointer(location: NSEvent.mouseLocation, leftButtonDown: NSEvent.pressedMouseButtons & 1 != 0)
        }
    }

    /// While the submenu tracks: the pointer counts as resting elsewhere only when it is on the panel, off the Pause
    /// row, off the submenu itself and on none of its items. Resting there 0.2 s closes the submenu.
    public static func pointerIsAway(_ p: CGPoint, panel: CGRect, row: CGRect, menu: CGRect, onItem: Bool) -> Bool {
        panel.contains(p) && !row.contains(p) && !menu.contains(p) && !onItem
    }

    /// The submenu closed without a choice because of a click on its own Pause row (the button still down there):
    /// show it again, as clicking a submenu's parent item keeps a macOS submenu open.
    public static func clickReopens(_ pointer: Pointer, row: CGRect) -> Bool {
        pointer.leftButtonDown && row.contains(pointer.location)
    }

    /// The submenu's frame on screen once AppKit keeps it on `visible`: `topLeft` and `size` from the pop-up.
    public static func submenuFrame(topLeft: CGPoint, size: CGSize, visible: CGRect?) -> CGRect {
        var f = CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        guard let v = visible else { return f }
        if f.maxX > v.maxX { f.origin.x = v.maxX - f.width }
        if f.minX < v.minX { f.origin.x = v.minX }
        if f.minY < v.minY { f.origin.y = v.minY }
        if f.maxY > v.maxY { f.origin.y = v.maxY - f.height }
        return f
    }

    // MARK: - Inputs

    let presentation: CapturePresentation?
    let actions: CaptureActions
    let snapshot: TodaySnapshot?
    let onboardingComplete: Bool
    let development: Bool
    let now: Date?
    let calendar: Calendar
    let openToday: (() -> Void)?
    let openSetUp: (() -> Void)?
    let openPermissions: (() -> Void)?
    let typing: TypingMenuRows?
    let typingActions: TypingMenuActions
    let presentSubmenu: ((NSMenu, NSView, NSPoint) -> Void)?
    let pointer: (() -> Pointer)?
    let update: UpdateAction?
    let dismiss: () -> Void
    /// The status line with no presentation (`isolatedLine`, or `preparingLine`).
    let offLine: String
    /// The hovered row (its id); renders pass one to draw the highlight.
    @State private var hovered: String?
    /// The Pause submenu is open (its row stays highlighted).
    @State private var submenuOpen: Bool
    /// One per installed panel. A `@State` default here was built once with the struct, so every hosting of the same
    /// `MenuBarMenu` value (a sizing pass, a second NSHostingView) shared one submenu, and whichever hosting redrew
    /// last took its anchor: a windowless copy redrawing later (icons landing off the main thread) left Pause › with
    /// no window to open beside. `@StateObject` builds it when the view is installed, so each hosting has its own.
    @StateObject private var submenu = MenuBarSubmenu()
    @State private var hoverOpen: DispatchWorkItem?
    @Environment(\.displayScale) private var displayScale

    /// - `state`: the state to draw; nil draws `presentation.state`.
    /// - `presentation`: nil is the isolated preview (no model).
    /// - `snapshot`: today's snapshot; nil hides the today line.
    /// - `now`: pins the clock (renders and checks); nil follows `\.daydreamNow`, else the live clock.
    /// - `calendar`: the calendar the snapshot was built with (the browser's), for the times.
    /// - `openToday`: opens the main window on today; nil opens the main window.
    /// - `openSetUp`: opens DayDream's guided setup; nil hides `Set Up DayDream…` and makes `Allow…` open System Settings.
    /// - `openPermissions`: opens the DayDream permissions window; once setup is finished `Allow…` opens it (nil: setup).
    /// - `typing`, `typingActions`: the typing line under the status and the typing item of the Pause submenu.
    /// - `highlighted`: a row id drawn highlighted at first draw (renders); `submenuOpen` draws the Pause row
    ///   as it looks while its submenu is open.
    /// - `presentSubmenu`: shows the Pause submenu (the checks record it); nil pops it up beside its row.
    /// - `pointer`: the pointer the submenu reads when it closes (the checks stand in); nil reads `NSEvent`.
    /// - `update`: a waiting update's one action (`Restart to Update`); nil hides the row.
    /// - `dismiss`: closes the panel; every row calls it after its action. The switch keeps the panel open.
    public init(state: RecordingState? = nil, presentation: CapturePresentation?, actions: CaptureActions,
                snapshot: TodaySnapshot?, onboardingComplete: Bool = true, development: Bool = false,
                now: Date? = nil, calendar: Calendar = .current, openToday: (() -> Void)? = nil,
                openSetUp: (() -> Void)? = nil, openPermissions: (() -> Void)? = nil,
                typing: TypingMenuRows? = nil, typingActions: TypingMenuActions = TypingMenuActions(),
                highlighted: String? = nil, submenuOpen: Bool = false,
                presentSubmenu: ((NSMenu, NSView, NSPoint) -> Void)? = nil, pointer: (() -> Pointer)? = nil,
                update: UpdateAction? = nil,
                dismiss: @escaping () -> Void = {}, offLine: String = MenuBarMenu.isolatedLine) {
        var p = presentation
        if let state { p?.state = state }
        self.presentation = p; self.actions = actions; self.snapshot = snapshot
        self.onboardingComplete = onboardingComplete; self.development = development
        self.now = now; self.calendar = calendar; self.openToday = openToday; self.openSetUp = openSetUp
        self.openPermissions = openPermissions
        self.typing = typing; self.typingActions = typingActions
        self.presentSubmenu = presentSubmenu; self.pointer = pointer
        self.update = update
        self.dismiss = dismiss
        self.offLine = offLine
        _hovered = State(initialValue: highlighted)
        _submenuOpen = State(initialValue: submenuOpen)
    }

    private var zone: TimeZone { calendar.timeZone }
    private var hairline: CGFloat { 1 / max(1, displayScale) }

    /// The header for this panel's inputs, at `now`.
    public func header(now: Date) -> Header {
        Self.header(presentation, now: now, timeZone: zone, canSetUp: openSetUp != nil, canOpenApplications: actions.openApplications != nil,
                    canOpenPermissions: openPermissions != nil && onboardingComplete, offLine: offLine)
    }

    public var body: some View {
        KitClock { now in
            let h = header(now: now)
            VStack(alignment: .leading, spacing: 0) {
                headerView(h)
                if presentation != nil {
                    separator
                    if let row = h.stateRow { stateRow(row) }
                    if let snapshot {
                        separator
                        todayRow(snapshot)
                    }
                }
                separator
                let shown = rows(h)
                // The last group: Report a Problem… (when offered), a waiting update's row, and Quit DayDream.
                let lastGroup = shown.first { $0.action == .reportProblem || $0.action == .update || $0.action == .quit }?.id
                ForEach(shown) { row in
                    if row.id == lastGroup && presentation != nil { separator }
                    plainRow(row)
                }
            }
            .padding(.vertical, 5)
            .frame(width: Self.width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .transformEnvironment(\.daydreamNow) { if let now = self.now { $0 = now } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.identifier)
    }

    private func rows(_ h: Header) -> [Row] {
        var offersSetUp = false
        if case .fix(_, .setUp) = h.control { offersSetUp = true }
        return Self.rows(isolated: presentation == nil, onboardingComplete: onboardingComplete, development: development,
                         canSetUp: openSetUp != nil, headerOffersSetUp: offersSetUp, canReport: actions.reportProblem != nil,
                         update: update?.title)
    }

    // MARK: - Header

    private func headerView(_ h: Header) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // At least 12 pt between the words and the control: a longer line wraps, it never pushes the control.
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DayDream").font(.system(size: 13, weight: .bold))
                    statusLine(h.status)
                }
                .accessibilityElement(children: .combine)
                .modifier(MenuBarStatusDetail(detail: h.status.detail))
                .accessibilityIdentifier("menubar-status")
                Spacer(minLength: Self.controlGap)
                control(h.control, tone: h.status.tone)
            }
            if let line = h.attention {
                switch Self.attentionAction(line) {
                case .open(let section):
                    lineButton(hint: Self.settingsHint(section), id: "menubar-attention",
                               run: { actions.openSettingsSection(section) }) {
                        attentionLine(line)
                    }
                case .retry:
                    lineButton(hint: Self.retryHint, id: "menubar-attention", trailing: RecordingCopy.retryTitle,
                               run: { actions.retryIssue() }) {
                        attentionLine(line)
                    }
                }
            }
            if let typing, typing.shown { typingLine(typing) }
            if let line = Self.chromeLine(presentation) {
                if Self.chromeFixes(presentation) {
                    // chromeask-1005: one calm line, and Ask again (refused) or Fix (setup's Chrome row).
                    lineButton(hint: ChromeAccessNotice.hint(askAgain: presentation?.chromeAskAgain == true), id: "menubar-browser-history",
                               trailing: Self.chromeFixTitle(presentation),
                               run: { actions.fixChrome() }) {
                        quietLine(line, symbol: BrowserHistoryLine.symbol)
                    }
                } else {
                    lineButton(hint: Self.settingsHint(Self.chromeSection), id: "menubar-browser-history",
                               run: { actions.openSettingsSection(Self.chromeSection) }) {
                        quietLine(line, symbol: BrowserHistoryLine.symbol)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 7)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusLine(_ s: Status) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            MenuBarStatusGlyph(tone: s.tone).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(s.text)
                .font(.system(size: 11.5, weight: s.tone == .attention ? .medium : .regular))
                .foregroundStyle(s.tone == .attention ? AnyShapeStyle(MenuBarMenuPalette.orangeText) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A line under the status that acts: the whole line is one click (its chevron says so, or `trailing` in the accent
    /// colour, as the typing line's Resume); it runs `run`, then closes the panel.
    private func lineButton<Label: View>(hint: String, id: String, trailing: String? = nil, run: @escaping () -> Void,
                                         @ViewBuilder label: () -> Label) -> some View {
        Button { run(); dismiss() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                label()
                if let trailing {
                    Spacer(minLength: 8)
                    Text(trailing).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(hint)
        .accessibilityIdentifier(id)
    }

    /// The operational issue: orange, wraps, never widens the panel.
    private func attentionLine(_ line: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9, weight: .semibold))
                .frame(width: 12).accessibilityHidden(true)
            Text(line).font(.system(size: 11.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(MenuBarMenuPalette.orangeText)
    }

    private func quietLine(_ line: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).frame(width: 12).accessibilityHidden(true)
            Text(line).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
    }

    /// "Recording what you type in Notes" (a filled keyboard) and "Not recording typing in this app" only say what
    /// happens; "Typing paused until 3:42 PM" ends in Resume and resumes typing; a locked line opens Settings ▸ Apps to
    /// remember.
    @ViewBuilder private func typingLine(_ rows: TypingMenuRows) -> some View {
        if let line = rows.line {
            let label = HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: rows.symbol).font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(rows.state.showsDot ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 12).accessibilityHidden(true)
                Text(line).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let title = rows.lineActionTitle {
                    Spacer(minLength: 8)
                    Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                } else if rows.lineAction != nil {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            if let action = rows.lineAction {
                Button { typingActions.perform(action); dismiss() } label: {
                    label.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel(line)
                    .accessibilityHint(rows.lineActionHint ?? "")
                    .accessibilityIdentifier("menubar-typing-line")
            } else {
                label.accessibilityElement(children: .combine).accessibilityIdentifier("menubar-typing-line")
            }
        }
    }

    /// What VoiceOver reads for the switch: the state it stands for, never "on" while nothing is recorded.
    public static func switchValue(on: Bool, tone: Status.Tone) -> String {
        guard on else { return "Off" }
        return tone == .paused ? "Paused" : "Recording"
    }
    public static func switchHint(on: Bool, tone: Status.Tone) -> String {
        guard on else { return "Turn on to start recording" }
        return tone == .paused ? "Turn off to stop DayDream" : "Turn off to stop recording"
    }

    @ViewBuilder private func control(_ c: Control, tone: Status.Tone) -> some View {
        switch c {
        case .toggle(let on, let enabled):
            Toggle("DayDream", isOn: Binding(get: { on }, set: { requested in
                guard enabled, requested != on else { return }
                // On starts (or resumes) recording; off stops it, from Recording or from a pause.
                if requested { actions.resume() } else { actions.stop() }
            }))
            .toggleStyle(.switch)
            // Mini: the size of the switches in the system's own menus (Wi-Fi, Bluetooth, Focus).
            .controlSize(.mini)
            .labelsHidden()
            .disabled(!enabled)
            // On while paused (DayDream is on, taking a break), so the spoken value is the state, not "on".
            .accessibilityLabel("DayDream")
            .accessibilityValue(Self.switchValue(on: on, tone: tone))
            .accessibilityHint(Self.switchHint(on: on, tone: tone))
            .accessibilityIdentifier("menubar-switch")
        case .fix(let title, let fix):
            Button(title) { run(fix) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .modifier(MenuBarCapsuleButton())
                .accessibilityHint(Self.fixHint(fix))
                .accessibilityIdentifier("menubar-fix")
        case .none:
            EmptyView()
        }
    }

    public static func fixHint(_ fix: Fix) -> String {
        switch fix {
        case .setUp: return "Opens DayDream setup at the step that's missing"
        case .permissions: return "Opens System Settings at the permission, with DayDream's card to drag into its list"
        case .systemSettings: return "Opens System Settings at the permission"
        case .applications: return "Opens Applications in Finder. Drag DayDream there, then open it from Applications."
        case .settings(let section): return settingsHint(section)
        }
    }

    private func run(_ fix: Fix) {
        switch fix {
        case .setUp: openSetUp?()
        case .permissions: openPermissions?()
        case .systemSettings(let kind): actions.openSystemSettings(kind)
        case .applications: actions.openApplications?()
        case .settings(let section): actions.openSettingsSection(section)
        }
        dismiss()
    }

    // MARK: - Rows

    private var separator: some View {
        Rectangle().fill(MenuBarMenuPalette.separator).frame(height: hairline)
            .padding(.horizontal, 14).padding(.vertical, 5)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func stateRow(_ row: StateRow) -> some View {
        switch row {
        case .pause(let enabled):
            let id = "Pause"
            let open = submenuOpen
            Button { openPause() } label: {
                MenuBarMenuRowLabel(title: "Pause", submenu: true, enabled: enabled, highlighted: enabled && (open || hovered == id))
                    .background(MenuBarSubmenuAnchor(submenu: submenu))
            }
            .buttonStyle(MenuBarMenuRowStyle())
            .disabled(!enabled)
            .onHover { inside in
                guard enabled else { return }
                hover(id, inside)
                hoverOpen?.cancel(); hoverOpen = nil
                if inside {
                    let work = DispatchWorkItem { openPause() }
                    hoverOpen = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
                }
            }
            .background {
                // ⌘P pauses for 15 minutes while recording, as `For 15 Minutes ⌘P` in the submenu says.
                if enabled {
                    Button("Pause for 15 Minutes") { actions.pause(Self.pauseKeyMinutes); dismiss() }
                        .keyboardShortcut(Self.pauseKey)
                        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .accessibilityLabel("Pause")
            .accessibilityHint("Shows how long to pause recording")
            .accessibilityIdentifier("menubar-pause")
        case .resume(let enabled):
            let id = "Resume Now"
            Button { actions.resume(); dismiss() } label: {
                MenuBarMenuRowLabel(title: id, keys: Self.pauseKeys, enabled: enabled, highlighted: enabled && hovered == id)
            }
            .buttonStyle(MenuBarMenuRowStyle())
            .keyboardShortcut(enabled ? Self.pauseKey : nil)
            .disabled(!enabled)
            .onHover { hover(id, $0) }
            .accessibilityLabel(id)
            .accessibilityIdentifier("menubar-resume")
        }
    }

    private func todayRow(_ s: TodaySnapshot) -> some View {
        let id = "today", line = Self.todayLine(s), apps = Self.todayApps(s)
        return Button { (openToday ?? actions.openMain)(); dismiss() } label: {
            MenuBarMenuRowLabel(title: line, enabled: true, highlighted: hovered == id) {
                HStack(spacing: 3) {
                    ForEach(apps) { app in
                        // An unresolved name is only the bundle ID: the icon falls back to its own monogram.
                        AppIcon(bundle: app.bundle, name: app.nameResolved ? app.name : "", size: 17)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .buttonStyle(MenuBarMenuRowStyle())
        .onHover { hover(id, $0) }
        .accessibilityLabel(line)
        .accessibilityValue(apps.map { SettingsStatusCardModel.Usage.displayName($0) }.joined(separator: ", "))
        .accessibilityHint("Opens DayDream at today")
        .accessibilityIdentifier("menubar-today")
    }

    private func plainRow(_ row: Row) -> some View {
        Button { perform(row) } label: {
            MenuBarMenuRowLabel(title: row.title, keys: row.keys, enabled: true, highlighted: hovered == row.id)
        }
        .buttonStyle(MenuBarMenuRowStyle())
        .keyboardShortcut(row.key.map { KeyboardShortcut(KeyEquivalent($0), modifiers: .command) })
        .onHover { hover(row.id, $0) }
        .accessibilityLabel(row.title)
    }

    private func hover(_ id: String, _ inside: Bool) {
        if inside { hovered = id } else if hovered == id { hovered = nil }
    }

    private func perform(_ row: Row) {
        switch row.action {
        case .search: actions.openRecall()
        case .open: actions.openMain()
        case .settings: actions.settings()
        case .setUp: openSetUp?()
        case .reportProblem: actions.reportProblem?()
        case .update: update?.run()
        case .quit: actions.quit()
        }
        dismiss()
    }

    // MARK: - Pause submenu

    private func openPause() {
        hoverOpen?.cancel(); hoverOpen = nil
        guard !submenuOpen, !submenu.isOpen, case .pause(enabled: true)? = header(now: now ?? Date()).stateRow else { return }
        submenuOpen = true
        let items = Self.pauseItems(typing: typing)
        // Next turn: the row draws highlighted before the menu's tracking loop starts.
        DispatchQueue.main.async {
            submenu.present(items, run: { item in
                switch item.action {
                case .pause(let minutes): actions.pause(minutes)
                case .typing(let action): typingActions.perform(action)
                }
                dismiss()
            }, using: presentSubmenu, pointer: pointer ?? { Pointer.system }) { pointerInRow in
                submenuOpen = false
                // No hover event arrives while a menu tracks: the row the pointer left is no longer hovered.
                if pointerInRow { hovered = "Pause" } else if hovered == "Pause" { hovered = nil }
            }
        }
    }
}

// MARK: - Pieces

enum MenuBarMenuPalette {
    /// The system menu separator, a touch lighter than a table rule.
    static let separator = KitPalette.dynamic(NSColor(white: 0, alpha: 0.10), NSColor(white: 1, alpha: 0.12))
    /// Orange for small text: systemOrange is about 2:1 on a light menu, so light mode darkens it to about 4.5:1.
    static let orangeText = KitPalette.dynamic(NSColor(srgbRed: 0.74, green: 0.35, blue: 0, alpha: 1), .systemOrange)
    static let redHalo = KitPalette.dynamic(NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 0.18), NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 0.30))
}

/// The glyph before the status line: red dot (Recording), indigo pause (Paused), grey ring (Off), orange "!".
public struct MenuBarStatusGlyph: View {
    let tone: MenuBarMenu.Status.Tone
    public init(tone: MenuBarMenu.Status.Tone) { self.tone = tone }
    public var body: some View {
        Group {
            switch tone {
            case .recording:
                ZStack {
                    Circle().fill(MenuBarMenuPalette.redHalo).frame(width: 12, height: 12)
                    Circle().fill(LinearGradient(colors: [Color(.sRGB, red: 1, green: 0.42, blue: 0.38, opacity: 1),
                                                          Color(.sRGB, red: 0.94, green: 0.16, blue: 0.16, opacity: 1)],
                                                 startPoint: .top, endPoint: .bottom))
                        .frame(width: 7, height: 7)
                }
            case .paused:
                Image(systemName: "pause.circle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(DaydreamStyle.paused)
            case .off:
                Circle().strokeBorder(Color.secondary, lineWidth: 1.2).frame(width: 8, height: 8)
            case .attention:
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(KitPalette.orange)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

/// A menu row: 13 pt title, an optional trailing accessory, a shortcut or the submenu chevron. Highlighted rows
/// take the accent colour with white text, as a macOS menu does.
public struct MenuBarMenuRowLabel<Trailing: View>: View {
    let title: String
    let keys: String?
    let submenu: Bool
    let enabled: Bool
    let highlighted: Bool
    let trailing: Trailing

    public init(title: String, keys: String? = nil, submenu: Bool = false, enabled: Bool = true, highlighted: Bool = false,
                @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.keys = keys; self.submenu = submenu; self.enabled = enabled; self.highlighted = highlighted
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13)).lineLimit(1)
                .foregroundStyle(highlighted ? AnyShapeStyle(Color.white) : enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            Spacer(minLength: 8)
            trailing
            if let keys {
                Text(keys).font(.system(size: 13))
                    .foregroundStyle(highlighted ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            }
            if submenu {
                Image(systemName: "chevron.right").font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(highlighted ? AnyShapeStyle(Color.white) : enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .background(highlighted ? Color(nsColor: .controlAccentColor) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .padding(.horizontal, 5)
    }
}

extension MenuBarMenuRowLabel where Trailing == EmptyView {
    public init(title: String, keys: String? = nil, submenu: Bool = false, enabled: Bool = true, highlighted: Bool = false) {
        self.init(title: title, keys: keys, submenu: submenu, enabled: enabled, highlighted: highlighted) { EmptyView() }
    }
}

/// The fix button as a capsule, like the switch it replaces.
struct MenuBarCapsuleButton: ViewModifier {
    func body(content: Content) -> some View { content.buttonBorderShape(.capsule) }
}

/// The whole sentence behind a shortened status line: its tooltip and its VoiceOver hint.
struct MenuBarStatusDetail: ViewModifier {
    let detail: String?
    func body(content: Content) -> some View {
        if let detail { content.help(detail).accessibilityHint(detail) } else { content }
    }
}

/// Rows draw their own highlight: no press tint, no focus ring.
struct MenuBarMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

// MARK: - The Pause submenu (a real NSMenu)

/// Hands the Pause row's NSView to the submenu, which pops up beside it.
struct MenuBarSubmenuAnchor: NSViewRepresentable {
    let submenu: MenuBarSubmenu
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        submenu.anchor = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { submenu.anchor = view }
}

/// Shows the Pause submenu as a real NSMenu beside its row, the way a macOS submenu opens: system material,
/// highlight, key equivalents and VoiceOver come from AppKit. It opens left of the panel when the right side has no
/// room, stays open when its own Pause row is clicked, and closes when a choice is made, on a click elsewhere, or
/// when the pointer rests on another row of the panel.
@MainActor final class MenuBarSubmenu: NSObject, ObservableObject {
    weak var anchor: NSView?
    private(set) var isOpen = false
    private var runs: [() -> Void] = []
    private var chosen = false
    private var watch: Timer?
    private var away: TimeInterval = 0

    /// The NSMenu for `items`: each item runs `choose(_:)` with its index as the tag.
    static func menu(_ items: [MenuBarMenu.PauseItem], target: AnyObject?) -> NSMenu {
        let menu = NSMenu(title: "Pause")
        menu.autoenablesItems = false
        for (i, item) in items.enumerated() {
            if item.separatorBefore { menu.addItem(.separator()) }
            let entry = NSMenuItem(title: item.title, action: #selector(choose(_:)), keyEquivalent: "")
            entry.target = target
            entry.tag = i
            if let keys = item.keys, let last = keys.last {
                entry.keyEquivalent = String(last).lowercased()
                var mask: NSEvent.ModifierFlags = []
                if keys.contains("⌃") { mask.insert(.control) }
                if keys.contains("⌥") { mask.insert(.option) }
                if keys.contains("⇧") { mask.insert(.shift) }
                if keys.contains("⌘") { mask.insert(.command) }
                entry.keyEquivalentModifierMask = mask
            }
            menu.addItem(entry)
        }
        return menu
    }

    /// The screen the panel is on (the menu bar's), for the side the submenu opens on.
    private static func visibleFrame(_ window: NSWindow, row: CGRect) -> CGRect? {
        (window.screen ?? NSScreen.screens.first { $0.frame.minX <= row.midX && row.midX < $0.frame.maxX } ?? NSScreen.main)?.visibleFrame
    }

    /// Shows `items`; `run` gets the chosen item. `present` stands in for the pop-up (checks); `pointer` is read when
    /// the menu closes; `closed` runs once the menu is gone, with whether the pointer is on the Pause row.
    func present(_ items: [MenuBarMenu.PauseItem], run: @escaping (MenuBarMenu.PauseItem) -> Void,
                 using present: ((NSMenu, NSView, NSPoint) -> Void)?, pointer: @escaping () -> MenuBarMenu.Pointer,
                 closed: @escaping (Bool) -> Void) {
        guard !isOpen, let anchor, let window = anchor.window else { closed(false); return }
        runs = items.map { item in { [weak self] in self?.chosen = true; run(item) } }
        let menu = Self.menu(items, target: self)
        let row = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = Self.visibleFrame(window, row: row)
        let side = MenuBarMenu.submenuSide(row: row, menuWidth: menu.size.width, visible: visible)
        let point = MenuBarMenu.submenuPoint(side: side, row: anchor.bounds, menuWidth: menu.size.width, flipped: anchor.isFlipped)
        let frame = MenuBarMenu.submenuFrame(topLeft: window.convertPoint(toScreen: anchor.convert(point, to: nil)),
                                             size: menu.size, visible: visible)
        isOpen = true
        // A click on the Pause row ends the menu's tracking (and AppKit keeps that click): show it again, as clicking
        // a submenu's parent keeps it open. Bounded, so a held button can never loop.
        var shown = 0
        repeat {
            chosen = false
            shown += 1
            if let present {
                present(menu, anchor, point)
            } else {
                startWatch(menu, row: row, frame: frame)
                if menu.popUp(positioning: nil, at: point, in: anchor) { chosen = true }
                watch?.invalidate(); watch = nil
            }
        } while !chosen && shown < 8 && anchor.window != nil && MenuBarMenu.clickReopens(pointer(), row: row)
        isOpen = false
        closed(row.contains(pointer().location))
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard runs.indices.contains(sender.tag) else { return }
        runs[sender.tag]()
    }

    /// While the menu tracks: when the pointer rests on another part of the panel for 0.2 s, close it, as moving
    /// to another item of a menu closes its open submenu. The Pause row, the submenu and its items never count.
    private func startWatch(_ menu: NSMenu, row: CGRect, frame: CGRect) {
        away = 0
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self, weak menu] _ in
            MainActor.assumeIsolated {
                guard let self, let menu, let window = self.anchor?.window else { return }
                let away = MenuBarMenu.pointerIsAway(NSEvent.mouseLocation, panel: window.frame, row: row, menu: frame,
                                                     onItem: menu.highlightedItem != nil)
                self.away = away ? self.away + 0.05 : 0
                if self.away >= 0.2 { menu.cancelTracking() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }
}
