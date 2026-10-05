import SwiftUI
import AppKit
import MemoryCore

// The status line at the top of Settings (spec §6.2, plan §5 A5; declutter): the recording state in
// one line, the orange line for an issue the state doesn't already say, and at most one button, the one
// that acts on what the line says: Start Recording (Off), Resume Recording (Paused), Allow… (Needs
// Permission: the Permissions page with DayDream's drag cards, as the menu bar's Allow…; never System
// Settings on its own, and never a permission request), or what fixes an issue (Open Apps to remember,
// Open Applications Folder, Try Again…). While recording with nothing to act on, the overview draws no
// card at all: the menu bar and the toolbar already say Recording. Pausing and stopping stay in the
// toolbar capsule and the menu bar, and today's moments live in the main window. Values only:
// `MemorySettings` builds the snapshot from the app model, renders and checks build it from fixtures.
// Nothing here reads the store, the clock or the system, and nothing runs until the button is pressed.

// MARK: - Snapshot

/// Everything the status line and the overview rows show. Optional parts hide when nil.
public struct SettingsStatusSnapshot: Equatable {
    public var state: RecordingState
    /// `CapturePresentation.issue` (operational issue or blocker). Drawn as an orange line unless
    /// the state line already says it.
    public var issue: String?
    /// Last permission reads; nil = not read (no accessory on the Permissions row).
    public var permissions: PermissionSnapshot?
    public var summaries: SummaryAvailability
    public var exclusions: ExclusionSummary
    /// The Connections row's status label; nil = not set up.
    public var connections: String?
    /// `CapturePresentation.canResume`: nothing blocks a start, so Off offers Start Recording and Paused
    /// offers Resume Recording.
    public var canResume: Bool
    /// chromeask-1005: Chrome pages aren't being saved (`BrowserHistoryLine.needsAccess`): one calm line with Fix.
    public var chromeOff: Bool
    /// chromeask-1005: refused, so the line's button is Ask again (else Fix).
    public var chromeAskAgain: Bool

    public init(state: RecordingState, issue: String? = nil, permissions: PermissionSnapshot? = nil,
                summaries: SummaryAvailability = SummaryAvailability(provider: .off, busy: false),
                exclusions: ExclusionSummary = ExclusionSummary(alwaysPrivate: [], excludedByYou: []),
                connections: String? = nil, canResume: Bool = true, chromeOff: Bool = false, chromeAskAgain: Bool = false) {
        self.state = state; self.issue = issue
        self.permissions = permissions; self.summaries = summaries; self.exclusions = exclusions
        self.connections = connections; self.canResume = canResume; self.chromeOff = chromeOff; self.chromeAskAgain = chromeAskAgain
    }
}

extension SettingsStatusSnapshot {
    public static let storeFiles = ["memory.sqlite", "memory.sqlite-wal", "memory.sqlite-shm"]

    /// Size of the memory store in `home` (Settings no longer shows it, and Report a Problem's email doesn't hold it):
    /// memory.sqlite plus its -wal and -shm files, each read with one attributes call (never a directory
    /// walk). nil when memory.sqlite is missing, a file is not a regular file, or any read fails, so a
    /// failure leaves the size out instead of reporting a wrong one.
    public static func storeBytes(home: URL, fileManager: FileManager = .default) -> Int64? {
        var total: Int64 = 0
        for (index, name) in storeFiles.enumerated() {
            let path = home.appendingPathComponent(name, isDirectory: false).path
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                if index == 0 { return nil }
                continue   // no -wal or -shm: the store is checkpointed or closed
            }
            guard !isDirectory.boolValue,
                  let attributes = try? fileManager.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value, size >= 0 else { return nil }
            total += size
        }
        return total
    }
}

// MARK: - Presentation

/// What the status line's one button does. The card calls it only on a press.
public enum SettingsStatusAction: Equatable {
    /// Off: start recording (the app's one start call, as the toolbar's Start Recording).
    case start
    /// Paused: resume recording (the same start call).
    case resume
    /// An issue a Settings page fixes, or Needs Permission (Permissions: DayDream's drag cards). The overview
    /// navigates there.
    case open(DaydreamSettingsPage)
    /// The download-window blocker: the Applications folder, to move DayDream there.
    case openApplications
    /// Try Again beside a job that didn't work (the history upkeep, a deletion): runs it again now
    /// (the same retry as the orange line's Try Again in the menu bar). It also runs again by itself.
    case retry
    /// chromeask-1005: Ask again or Fix beside "Chrome pages aren't being saved." (the app's `fixChromeAccess`).
    case fixChrome
}

/// The status line's button: its title and what it does.
public struct SettingsStatusButton: Equatable {
    public let title: String
    public let action: SettingsStatusAction
    public init(_ title: String, _ action: SettingsStatusAction) { self.title = title; self.action = action }
}

/// The status line's text and parts, derived from a snapshot. The card draws exactly these strings, so
/// the checks read them here instead of through an accessibility tree that is not published offscreen.
public struct SettingsStatusCardModel: Equatable {
    /// App names as other surfaces draw them: a bundle ID is never presented as a name.
    public enum Usage {
        public static let unknownApp = "Unknown app"
        public static func displayName(_ app: AppTally) -> String { app.nameResolved ? app.name : unknownApp }
    }

    public static let openPauseDetail = "Until you resume"
    public static let startTitle = "Start Recording"
    public static let resumeTitle = "Resume Recording"
    /// Needs Permission: the Permissions page, where the drag cards allow what's missing (the menu bar's Allow…
    /// opens the same cards).
    public static let permissionsTitle = "Allow…"

    public let stateTitle: String
    public let stateDetail: String?
    /// Needs Permission: the state word is drawn orange.
    public let stateNeedsAttention: Bool
    /// The orange line for an operational issue or blocker the state line doesn't already say.
    public let attention: String?
    /// chromeask-1005: "Chrome pages aren't being saved.", calm (not orange), with its own Fix; nil when they are.
    public let chromeLine: String?
    /// The line's button: Ask again (refused) or Fix (never asked).
    public let chromeFixTitle: String
    /// The card's one button, or nil when nothing here can act on the line (a blocker without a fix,
    /// Recording without an issue).
    public let button: SettingsStatusButton?
    /// Recording with no issue: nothing to say that the menu bar and toolbar don't, and nothing to do, so
    /// the overview draws no card.
    public let quiet: Bool

    /// "Paused · Until 3:00 PM", "Recording".
    public var stateLine: String { [stateTitle, stateDetail].compactMap { $0 }.joined(separator: " · ") }
    /// The card's VoiceOver label.
    public var accessibilityLabel: String {
        (["DayDream, " + stateLine] + [attention, chromeLine].compactMap { $0 }).joined(separator: ". ")
    }

    public init(_ s: SettingsStatusSnapshot, calendar: Calendar, now: Date) {
        let zone = calendar.timeZone
        stateTitle = s.state.title
        stateDetail = Self.detail(s.state, zone)
        attention = s.state.attentionLine(issue: s.issue, now: now, timeZone: zone)
        if case .needsPermission = s.state { stateNeedsAttention = true } else { stateNeedsAttention = false }
        button = Self.button(s)
        chromeLine = s.chromeOff ? ChromeAccessNotice.line : nil
        chromeFixTitle = ChromeAccessNotice.title(askAgain: s.chromeAskAgain)
        if case .recording = s.state { quiet = attention == nil && chromeLine == nil } else { quiet = false }
    }

    /// The one button: Needs Permission's Allow… (the Permissions page); else an issue's own fix; else the state's
    /// action (Start Recording while Off, Resume Recording while Paused), only when nothing blocks a start.
    static func button(_ s: SettingsStatusSnapshot) -> SettingsStatusButton? {
        if case .needsPermission = s.state { return SettingsStatusButton(permissionsTitle, .open(.permissions)) }
        if let fix = fix(for: s.issue) { return fix }
        guard s.canResume else { return nil }
        switch s.state {
        case .off(_, let reason): return reason == nil ? SettingsStatusButton(startTitle, .start) : nil
        case .paused: return SettingsStatusButton(resumeTitle, .resume)
        case .recording, .needsPermission: return nil
        }
    }

    /// The page, folder or retry that fixes an issue, from the core string (`CapturePresentation.issue`) or its
    /// copy; nil when nothing in Settings fixes it (the line then stands alone).
    public static func fix(for issue: String?) -> SettingsStatusButton? {
        guard let raw = issue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let line = RecordingCopy.issue(raw)
        if raw == "Move DayDream to Applications first" || line == RecordingCopy.moveToApplications {
            return SettingsStatusButton("Open Applications Folder", .openApplications)
        }
        if raw == "Review replacement" || raw == "Replacement in progress" {
            return SettingsStatusButton("Open Advanced", .open(.advanced))
        }
        // Start was refused over app choices that didn't save (the app model's own words): Apps to remember shows the
        // problem and the one button that fixes it.
        if raw == RecordingCopy.choicesUnsaved {
            return SettingsStatusButton("Open " + DaydreamSettingsPage.apps.title, .open(.apps))
        }
        // The history upkeep or a deletion that didn't work: running it again is the fix (Settings › Summaries, where the
        // old "Summary writer" line led, can't mend the upkeep). The same action as the orange line's (`attentionAction`).
        if RecordingCopy.retriedIssues.contains(line) {
            return SettingsStatusButton(RecordingCopy.retryTitle, .retry)
        }
        // History set aside at launch: Backup and restore, where Restore is (the menu bar's line opens the same page).
        if raw == MenuBarMenu.historySetAsideLine {
            return SettingsStatusButton("Open " + DaydreamSettingsPage.backup.title, .open(.backup))
        }
        return nil
    }

    /// The card's detail for a state: only what tells you what to do. Recording has none (its start
    /// time is trivia); a timed pause shows its end without a countdown the card doesn't tick; a plain Off
    /// has none (its button says what to do); Needs Permission says what is missing, beside its button.
    static func detail(_ state: RecordingState, _ zone: TimeZone) -> String? {
        switch state {
        case .recording:
            return nil
        case .paused(let until?, _, _):
            return "Until " + DaydreamFormat.time(until, zone)
        case .paused(nil, _, let reason):
            // One line reads "Paused · …". The person's own pause has no end but their Resume; a "Paused while …"
            // reason drops its own "Paused " so it isn't said twice ("Paused · While your Mac slept."). Every other
            // reason is a whole sentence of its own, never a fragment such as "By you" or "For an update.".
            guard let reason, !reason.isEmpty, reason != RecordingCopy.pausedByYou else { return openPauseDetail }
            // gold/int: lifecycle's wait for an import or backup ("Paused until your import or backup finishes.")
            // reads the same way: "Paused · Until your import or backup finishes.", like "Paused · Until you resume".
            guard reason.hasPrefix("Paused while ") || reason.hasPrefix("Paused until ") else { return reason }
            let rest = reason.dropFirst(7)
            return rest.prefix(1).uppercased() + rest.dropFirst()
        case .off(_, let reason):
            return reason
        case .needsPermission(let missing):
            // perm-1004: the title already says `Turn on Accessibility`; the detail names only what else is off.
            switch missing {
            case [.inputMonitoring], [.accessibility]: return nil
            case []: return "Accessibility and Input Monitoring are required"
            default: return "Input Monitoring is off too"
            }
        }
    }
}

// MARK: - Laid-out elements

/// One element the card actually laid out: its text and its frame in global space.
public struct SettingsStatusCardElement: Equatable {
    public let text: String
    public let frame: CGRect
}

/// What the status card and the overview laid out, keyed by element: `state`, `attention`,
/// `action` (the one button), the overview rows' accessories `row.permissions`, `row.summaries`, `row.apps`,
/// `row.connections`, and the footer's `footer` and `footer.learn-more`. An element that is hidden is
/// absent, and a `ViewThatFits` reports only the branch it draws. Checks read it with
/// `onPreferenceChange` from any ancestor, including the app's settings window.
public struct SettingsStatusCardElements: PreferenceKey {
    public static var defaultValue: [String: SettingsStatusCardElement] { [:] }
    public static func reduce(value: inout [String: SettingsStatusCardElement], nextValue: () -> [String: SettingsStatusCardElement]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Reports this view's frame and drawn text under `key` in `SettingsStatusCardElements`.
    func settingsElement(_ key: String, _ text: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: SettingsStatusCardElements.self,
                                   value: [key: SettingsStatusCardElement(text: text, frame: proxy.frame(in: .global))])
        })
    }
}

// MARK: - Card

/// The status card: one state line, the orange issue line when there is one, and at most one button
/// (`SettingsStatusCardModel.button`).
public struct SettingsStatusCard: View {
    let snapshot: SettingsStatusSnapshot
    let calendar: Calendar
    let act: (SettingsStatusAction) -> Void
    @Environment(\.daydreamNow) private var fixedNow

    /// `act` runs the one button (start, resume, a page, the Applications folder), only on a press.
    public init(_ snapshot: SettingsStatusSnapshot, calendar: Calendar = .current,
                act: @escaping (SettingsStatusAction) -> Void = { _ in }) {
        self.snapshot = snapshot; self.calendar = calendar; self.act = act
    }

    public var body: some View {
        let model = SettingsStatusCardModel(snapshot, calendar: calendar, now: fixedNow ?? Date())
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(snapshot.state.tint).frame(width: 8, height: 8)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    (Text(model.stateTitle).fontWeight(.semibold)
                        .foregroundColor(model.stateNeedsAttention ? KitPalette.orange : .primary)
                     + Text(model.stateDetail.map { " · " + $0 } ?? "").foregroundColor(.secondary))
                        .font(.system(size: 13))
                        .lineLimit(2).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(model.stateLine)
                }
                .settingsElement("state", model.stateLine)
                if let attention = model.attention {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .semibold))
                        Text(attention).font(.system(size: 12)).lineLimit(2).truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(KitPalette.orange)
                    .padding(.leading, 15)
                    .help(attention)
                    .settingsElement("attention", attention)
                }
                if let chromeLine = model.chromeLine {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: ChromeAccessNotice.symbol).font(.system(size: 10)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(chromeLine).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(model.chromeFixTitle) { act(.fixChrome) }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                            .accessibilityHint(ChromeAccessNotice.hint(askAgain: model.chromeFixTitle == ChromeAccessNotice.askAgainTitle))
                            .settingsElement("chrome.fix", model.chromeFixTitle)
                    }
                    .padding(.leading, 15)
                    .settingsElement("chrome", chromeLine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilityLabel)
            // The line's button, for VoiceOver (the combined element hides the button inside it).
            .accessibilityAction(named: Text(model.chromeFixTitle)) { if model.chromeLine != nil { act(.fixChrome) } }
            if let button = model.button { actionButton(button) }
        }
        .padding(.horizontal, StatusCardMetrics.horizontalPadding).padding(.vertical, StatusCardMetrics.padding)
        .frame(minHeight: StatusCardMetrics.minHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .daydreamCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-status-card")
    }

    /// The card's one control, reported as `action`.
    private func actionButton(_ button: SettingsStatusButton) -> some View {
        let external: Bool = { if case .openApplications = button.action { return true }; return false }()
        return Button { act(button.action) } label: {
            HStack(spacing: 4) {
                Text(button.title)
                if external { Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold)) }
            }
        }
        .buttonStyle(KitCapsuleButtonStyle(prominent: true))
        .fixedSize()
        .help(button.action == .open(.permissions) ? "Opens Permissions, where you allow what's missing" : button.title)
        .accessibilityLabel(button.title)
        .settingsElement("action", button.title)
    }
}

/// Card metrics.
enum StatusCardMetrics {
    static let padding: CGFloat = 12
    static let horizontalPadding: CGFloat = 16
    /// One line with the button beside it.
    static let minHeight: CGFloat = 52
}
