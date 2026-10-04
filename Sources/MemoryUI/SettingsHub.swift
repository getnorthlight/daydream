import SwiftUI
import AppKit

public enum DaydreamSettingsPage: String, CaseIterable {
    case overview, permissions, summaries, apps, connections, advanced, updates, history, backup

    /// Old section names keep a destination: "Privacy" and "Details" were pages of their own and now open
    /// Advanced, which holds what was left of them (Uninstall, the move notice, the retention line). "Setup"
    /// opens the overview, whose status line says what still stops recording.
    public init(section: String) {
        switch section {
        case "Permissions": self = .permissions
        case "Memory", "Writer", "Summaries": self = .summaries
        case "Recording", "Apps to remember": self = .apps
        case "Connection", "Connections": self = .connections
        case "Advanced", "Privacy", "Details": self = .advanced
        case "Updates": self = .updates
        case "History": self = .history
        case "Backup": self = .backup
        default: self = .overview
        }
    }

    public var title: String {
        switch self {
        case .overview: return "Settings"
        case .permissions: return "Permissions"
        case .summaries: return "Summaries"
        case .apps: return "Apps to remember"
        case .connections: return "Connections"
        case .advanced: return "Advanced"
        case .updates: return "App updates"
        case .history: return "Import history"
        case .backup: return "Backup and restore"
        }
    }

    /// Pages the Settings sheet fits to their content instead of its full height (they have no scroll view): Backup
    /// and restore is two rows, and a full-height sheet around it was mostly empty (owner, Preview 2).
    public var fitsContent: Bool { self == .backup }
}

public struct DaydreamSettingsNavigation {
    public private(set) var page: DaydreamSettingsPage
    private var history: [DaydreamSettingsPage] = []

    public init(section: String = "General") { page = DaydreamSettingsPage(section: section) }

    public mutating func show(_ next: DaydreamSettingsPage) {
        guard next != page else { return }
        history.append(page)
        page = next
    }

    public mutating func back() { page = history.popLast() ?? .overview }
}

private struct DaydreamSettingsDetailKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var daydreamSettingsDetail: Bool {
        get { self[DaydreamSettingsDetailKey.self] }
        set { self[DaydreamSettingsDetailKey.self] = newValue }
    }
}

/// The Settings sheet's size. It fits a 13-inch MacBook Air with room to spare, is never taller than the window it
/// opens over (so it doesn't hang past that window's bottom edge), and long pages scroll inside it.
public enum DaydreamSettingsLayout {
    public static let width: CGFloat = 720
    /// The tallest the sheet gets.
    public static let maxHeight: CGFloat = 540
    /// The shortest. Below the main window's own minimum the sheet may hang a little past that window.
    public static let minHeight: CGFloat = 400
    /// The frame around every page: side, top and bottom margins, the header row and the gap under it.
    public static let horizontalPadding: CGFloat = 24
    public static let topPadding: CGFloat = 18
    public static let bottomPadding: CGFloat = 20
    public static let headerHeight: CGFloat = 34
    public static let headerGap: CGFloat = 14
    /// The page's viewport height inside a sheet of `height`.
    public static func viewport(_ height: CGFloat) -> CGFloat { height - topPadding - headerHeight - headerGap - bottomPadding }

    /// The sheet's height over a window whose content is `windowContentHeight` tall, on a screen whose visible
    /// area is `screenHeight` tall. Unknown values don't limit it.
    public static func height(windowContentHeight: CGFloat?, screenHeight: CGFloat? = NSScreen.main?.visibleFrame.height) -> CGFloat {
        var height = maxHeight
        if let window = windowContentHeight, window.isFinite, window > 0 { height = min(height, window - 12) }
        if let screen = screenHeight, screen.isFinite, screen > 0 { height = min(height, screen - 120) }
        return max(minHeight, height.rounded(.down))
    }
}

public struct DaydreamSettingsFrame<Content: View>: View {
    private let title: String
    private let back: (() -> Void)?
    private let advanced: (() -> Void)?
    private let close: () -> Void
    private let content: Content
    private let appURL: URL

    /// One header row: Back (sub-pages), the title, `Advanced…` (the overview passes it) and Done. Return is Done;
    /// ⌘[ goes back on a sub-page. sat5: Esc closes Settings from every page, and so does a click on the window
    /// behind the sheet (`SettingsSheetOutsideClick`), like a popover.
    public init(title: String, appURL: URL = Bundle.main.bundleURL, back: (() -> Void)? = nil, advanced: (() -> Void)? = nil,
                close: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.back = back
        self.advanced = advanced
        self.close = close
        self.content = content()
        self.appURL = appURL
    }

    public var body: some View {
        VStack(spacing: DaydreamSettingsLayout.headerGap) {
            HStack(alignment: .center, spacing: 8) {
                if let back { SettingsBackButton(action: back).settingsElement("frame.back", "Back") }
                Text(title).font(.system(size: 22, weight: .bold)).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let advanced {
                    Button(action: advanced) {
                        HStack(spacing: 5) {
                            Image(systemName: "gearshape").font(.system(size: 12, weight: .medium))
                            Text("Advanced…")
                        }
                    }
                    .buttonStyle(KitCapsuleButtonStyle())
                    .help("Import, backup, updates and uninstall")
                    .accessibilityLabel("Advanced settings")
                    .settingsElement("frame.advanced", "Advanced…")
                }
                Button("Done", action: close).buttonStyle(KitCapsuleButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .settingsElement("frame.done", "Done")
            }.frame(height: DaydreamSettingsLayout.headerHeight)
            content
                .environment(\.daydreamSettingsDetail, true)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, DaydreamSettingsLayout.horizontalPadding)
        .padding(.top, DaydreamSettingsLayout.topPadding).padding(.bottom, DaydreamSettingsLayout.bottomPadding)
        .background(DaydreamOnboardingTheme.window)
        .scrollIndicators(.hidden)
        .onExitCommand(perform: close)
        .background(SettingsSheetOutsideClick(close: close))
        .daydreamNoInitialFocusRing()
    }
}

/// A click on the window behind the Settings sheet closes the sheet (sat5: the owner expected it to behave like a
/// popover). A local mouse-down monitor, live while the frame is in a window, acts only when:
/// - the frame's window is a sheet and the click landed on the window it hangs from, and
/// - that window's attached sheet is this one, and nothing is attached to the sheet itself (a question such as the
///   cloud consent sheet stays up until it is answered).
/// The click is used up: the window behind never also acts on it (a toolbar Start doesn't start recording).
/// Clicks inside the sheet, in menus and in other windows pass through untouched. Nothing else is watched.
struct SettingsSheetOutsideClick: NSViewRepresentable {
    let close: () -> Void

    func makeNSView(context: Context) -> Watcher { Watcher(close: close) }
    func updateNSView(_ view: Watcher, context: Context) { view.close = close }
    static func dismantleNSView(_ view: Watcher, coordinator: ()) { view.stop() }

    final class Watcher: NSView {
        var close: () -> Void
        private var monitor: Any?
        init(close: @escaping () -> Void) { self.close = close; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let sheet = self.window, SettingsSheetClick.closes(sheet: sheet, clicked: event.window) else { return event }
                self.close()
                return nil
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// The rule `SettingsSheetOutsideClick` applies (public for settings-hub-checks).
public enum SettingsSheetClick {
    /// Whether a click on `clicked` closes the sheet `sheet`: it landed on the window the sheet hangs from, the
    /// sheet is that window's attached sheet, and nothing is attached to the sheet.
    public static func closes(sheet: NSWindow, clicked: NSWindow?) -> Bool {
        guard let parent = sheet.sheetParent, let clicked, clicked === parent else { return false }
        return parent.attachedSheet === sheet && sheet.attachedSheet == nil
    }
}

/// A sub-page's Back: a 34 pt square that answers a click anywhere inside it (`contentShape`; a plain button
/// otherwise answers only on the chevron's drawn pixels), with a hover fill. ⌘[ presses it too.
struct SettingsBackButton: View {
    let action: () -> Void
    @State private var hovered = false
    static let size: CGFloat = 34

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: Self.size, height: Self.size)
                .background(Color.primary.opacity(hovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .keyboardShortcut("[", modifiers: .command)
        .help("Back")
        .accessibilityLabel("Back")
    }
}

/// A settings page's scroll view (indicators hidden). The viewport reaches a little past the
/// page's content box, into the frame's margins, and the content is inset by the same amount: the
/// cards stay where they were, but their shadows are no longer cut to a hard rectangle. A short
/// fade at the bottom edge shows that the page continues below.
public struct DaydreamSettingsScroll<Content: View>: View {
    /// How far the viewport reaches past the content box on each side.
    public static var horizontalRoom: CGFloat { 10 }
    public static var topRoom: CGFloat { 6 }
    public static var bottomRoom: CGFloat { 12 }
    /// The bottom fade's height. Content that must read as fully visible ends above it.
    public static var fadeHeight: CGFloat { 12 }

    private let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        ScrollView(showsIndicators: false) {
            content
                .padding(.horizontal, Self.horizontalRoom)
                .padding(.top, Self.topRoom)
                .padding(.bottom, Self.fadeHeight)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [DaydreamOnboardingTheme.window.opacity(0), DaydreamOnboardingTheme.window],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: Self.fadeHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // The viewport, for the overview's rows-visible report (`reportingRowFrames`).
        .background(GeometryReader { proxy in
            Color.clear.preference(key: SettingsRowFrames.self, value: ["viewport": proxy.frame(in: .global)])
        })
        .padding(.horizontal, -Self.horizontalRoom)
        .padding(.top, -Self.topRoom)
        .padding(.bottom, -Self.bottomRoom)
    }
}


// MARK: - Overview (spec §6.2: settings-A grouped list under the live status line)

/// The accessories on the overview's area rows. nil draws no accessory: an unread permission or an
/// unknown value is never shown as a state.
public struct SettingsRowsSnapshot: Equatable {
    public var permissions: PermissionSnapshot?
    public var summaries: String?
    public var exclusions: ExclusionSummary?
    public var connections: String?

    public init(permissions: PermissionSnapshot? = nil, summaries: String? = nil, exclusions: ExclusionSummary? = nil,
                connections: String? = nil) {
        self.permissions = permissions; self.summaries = summaries; self.exclusions = exclusions; self.connections = connections
    }

    /// The rows for a status snapshot: its permission reads, summary provider, exclusions and
    /// connection status (`Not set up` when there is none).
    public init(_ status: SettingsStatusSnapshot) {
        self.init(permissions: status.permissions, summaries: Self.summariesLabel(status.summaries),
                  exclusions: status.exclusions, connections: status.connections ?? Self.notSetUp)
    }

    public static let notSetUp = "Not set up"
    /// The Connections accessory when no AI app is connected but one needs a fresh Connect.
    public static let reconnectNeeded = "Reconnect needed"
    /// The Summaries row's word for cloud summaries (owner 9/28: the service's name, as everywhere else).
    public static let cloud = SummaryPhaseReading.cloudValue
    /// The Summaries row's word while summaries are off.
    public static let off = SummaryPhaseReading.offValue

    /// The Summaries row from the one summaries state: `Downloading…`, `Checking…`, `On this Mac`, `OpenRouter`, `Off`, or
    /// the problem's line. Never "Not set up" while a download runs.
    public static func summariesLabel(_ phase: SummaryPhase) -> String {
        switch phase {
        case .downloading: return "Downloading…"
        case .checking: return "Checking…"
        default: return SummaryPhaseReading.value(phase)
        }
    }

    /// The same, from the Today data's summaries value: the writer's own phase (wired since fix/sx-all), else the phase
    /// read from its provider, busy and download progress. fix/bugs7: the row used to ignore the wired phase, so a stopped
    /// download read "Off" and a model that couldn't start or a refused key read "On this Mac" or "OpenRouter".
    public static func summariesLabel(_ summaries: SummaryAvailability) -> String {
        summariesLabel(summaries.phase != .off ? summaries.phase : SummaryPhaseReading.phase(summaries))
    }

    /// The Apps row's accessory: only what you chose, `1 excluded` or `None excluded`. The always-private
    /// apps are the same for everyone, so the row doesn't count them (the Apps page lists them).
    public static func appsLabel(_ exclusions: ExclusionSummary) -> String {
        exclusions.excludedByYou.isEmpty ? "None excluded" : "\(exclusions.excludedByYou.count) excluded"
    }

    /// `Both allowed`, or the missing permission (`Input Monitoring needed`), which is a problem;
    /// `short` is the narrow-window form of a problem (`Input Monitoring`). nil until both
    /// permissions have been read, unless one read already says it is off.
    public static func permissionsLabel(_ permissions: PermissionSnapshot?) -> (text: String, short: String, problem: Bool)? {
        guard let permissions else { return nil }
        switch permissions.missing {
        case [.inputMonitoring]: return ("Input Monitoring needed", "Input Monitoring", true)
        case [.accessibility]: return ("Accessibility needed", "Accessibility", true)
        case []: return permissions.allGranted == true ? ("Both allowed", "Both allowed", false) : nil
        default: return ("Both needed", "Both needed", true)
        }
    }
}

public struct DaydreamSettingsOverview: View {
    private let status: SettingsStatusSnapshot?
    private let rows: SettingsRowsSnapshot
    private let calendar: Calendar
    private let select: (DaydreamSettingsPage) -> Void
    private let act: (SettingsStatusAction) -> Void
    private let learnMore: () -> Void
    private let fileVaultOn: Bool?
    private var reportRows: ((CGRect, [CGRect]) -> Void)?
    @Environment(\.daydreamNow) private var fixedNow

    /// Rows only: no status line, and only the Summaries row has an accessory.
    public init(summaries: String, select: @escaping (DaydreamSettingsPage) -> Void) {
        self.init(status: nil, rows: SettingsRowsSnapshot(summaries: summaries), select: select)
    }

    /// The status line (when `status` is set and it has something to say) above the grouped area rows (Advanced
    /// is the frame's button) and the privacy line. Nothing runs until a control is pressed: the status line's
    /// one button runs `select` (a page that fixes an issue, or Permissions, DayDream's drag cards, for Needs
    /// Permission) or `act` (Start or Resume Recording, the Applications folder); `learnMore` is the privacy
    /// line's link (the app opens PRIVACY.md); `select` opens a page. `fileVaultOn` is the app's read of
    /// FileVault (nil: unknown).
    public init(status: SettingsStatusSnapshot?, rows: SettingsRowsSnapshot, calendar: Calendar = .current,
                select: @escaping (DaydreamSettingsPage) -> Void,
                act: @escaping (SettingsStatusAction) -> Void = { _ in },
                learnMore: @escaping () -> Void = {}, fileVaultOn: Bool? = nil) {
        self.status = status; self.rows = rows; self.calendar = calendar
        self.select = select; self.act = act; self.learnMore = learnMore
        self.fileVaultOn = fileVaultOn
    }

    /// The privacy line under the rows, one short true line (honesty items 20, 21 and 23): where history
    /// is kept, that DayDream doesn't encrypt it (whatever FileVault's state: any app running as you can
    /// read the file), and who can send parts of it out, naming OpenRouter. "Kept", never "stays". The
    /// long form is PRIVACY.md, behind Learn more. The consent notice shown before cloud summaries turn on
    /// says what they never get (`CloudActivation.disclosure`). This is the line unless FileVault is known to
    /// be off; only then does it also say to turn it on (`storageFooterFileVaultOff`), as setup does.
    public static let storageFooter = "Your history is kept on this Mac, and DayDream doesn't encrypt it. Connected AI apps and cloud summaries (OpenRouter) can send parts of it out."
    public static let storageFooterFileVaultOff = "Your history is kept on this Mac, and DayDream doesn't encrypt it: turn on FileVault. Connected AI apps and cloud summaries (OpenRouter) can send parts of it out."
    public static let learnMoreTitle = "Learn more"

    /// The privacy line for a FileVault read: the FileVault clause only when FileVault is known to be off
    /// (an unknown read, or one not made yet, never says it is off).
    public static func footer(fileVaultOn: Bool?) -> String { fileVaultOn == false ? storageFooterFileVaultOff : storageFooter }

    /// Reports the scroll viewport and the four area rows' frames, in window coordinates, after each
    /// layout. The settings checks use it to assert the rows fit without scrolling.
    public func reportingRowFrames(_ report: @escaping (_ viewport: CGRect, _ rows: [CGRect]) -> Void) -> Self {
        var copy = self
        copy.reportRows = report
        return copy
    }

    public var body: some View {
        DaydreamSettingsScroll {
            VStack(alignment: .leading, spacing: 10) {
                // Recording with nothing to act on draws no card: the menu bar and toolbar already say it.
                if let status, !SettingsStatusCardModel(status, calendar: calendar, now: fixedNow ?? Date()).quiet {
                    SettingsStatusCard(status, calendar: calendar, act: { action in
                        if case .open(let page) = action { select(page) } else { act(action) }
                    })
                }
                areaRows
                footer
            }
        }
        .onPreferenceChange(SettingsRowFrames.self) { frames in
            guard let reportRows, let viewport = frames["viewport"] else { return }
            reportRows(viewport, (0..<4).compactMap { frames["row\($0)"] })
        }
    }

    /// One line with its Learn more link inline. The link runs `learnMore` (never a URL opened here).
    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).frame(width: 12)
            let line = Self.footer(fileVaultOn: fileVaultOn)
            (Text(line + " ") + Text(.init("[\(Self.learnMoreTitle)](daydream-settings:privacy)")))
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { _ in learnMore(); return .handled })
                .settingsElement("footer", line + " " + Self.learnMoreTitle)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2).padding(.horizontal, 4)
    }

    private var areaRows: some View {
        let permissions = SettingsRowsSnapshot.permissionsLabel(rows.permissions)
        // Needs Permission already says what is missing, with its button, in the status line above: the
        // row then says nothing. In any other state (Off or Paused with a permission read as missing) the
        // orange pill is the hub's only warning, so it stays.
        let statusSaysIt: Bool = { if case .needsPermission? = status?.state { return true }; return false }()
        let problem = permissions?.problem == true && !statusSaysIt
        let shown = statusSaysIt ? nil : permissions
        return VStack(spacing: 0) {
            SettingsAreaRow(title: DaydreamSettingsPage.permissions.title, area: .permissions, accessory: shown?.text,
                            badge: problem ? .attention : nil, action: { select(.permissions) }) {
                if let permissions = shown {
                    if problem {
                        // A narrow window drops "needed" first. Each branch reports itself, so the element
                        // is the text actually drawn.
                        ViewThatFits(in: .horizontal) {
                            SettingsProblemPill(text: permissions.text).settingsElement("row.permissions", permissions.text)
                            SettingsProblemPill(text: permissions.short).settingsElement("row.permissions", permissions.short)
                        }
                    } else {
                        QuietStatus(permissions.text, symbol: permissions.problem ? "exclamationmark.circle" : "checkmark.circle.fill",
                                    tint: permissions.problem ? .secondary : KitPalette.green)
                            .settingsElement("row.permissions", permissions.text)
                    }
                }
            }
            .reportingFrame("row0")
            SettingsRowDivider()
            SettingsAreaRow(title: DaydreamSettingsPage.summaries.title, area: .summaries, accessory: rows.summaries,
                            action: { select(.summaries) }) {
                if let summaries = rows.summaries {
                    QuietStatus(summaries, symbol: summaries == Locality.local.title ? Locality.local.symbol
                                : summaries == SettingsRowsSnapshot.cloud ? "key.fill" : "circle.dashed")
                        .settingsElement("row.summaries", summaries)
                }
            }
            .reportingFrame("row1")
            SettingsRowDivider()
            // The typing switch, its off switch and Forget what I typed live on this page too.
            SettingsAreaRow(title: DaydreamSettingsPage.apps.title, area: .apps,
                            accessory: rows.exclusions.map(SettingsRowsSnapshot.appsLabel), action: { select(.apps) }) {
                if let exclusions = rows.exclusions {
                    QuietStatus(SettingsRowsSnapshot.appsLabel(exclusions), symbol: "eye.slash")
                        .settingsElement("row.apps", SettingsRowsSnapshot.appsLabel(exclusions))
                }
            }
            .reportingFrame("row2")
            SettingsRowDivider()
            SettingsAreaRow(title: DaydreamSettingsPage.connections.title, area: .connections, accessory: rows.connections,
                            action: { select(.connections) }) {
                if let connections = rows.connections {
                    // "Reconnect needed": an AI app's access was turned off (for example by a change to Apps to remember).
                    QuietStatus(connections, symbol: connections == SettingsRowsSnapshot.notSetUp ? "circle.dashed"
                                : connections == SettingsRowsSnapshot.reconnectNeeded ? "exclamationmark.circle.fill" : "link",
                                tint: connections == SettingsRowsSnapshot.reconnectNeeded ? KitPalette.orange : .secondary)
                        .settingsElement("row.connections", connections)
                }
            }
            .reportingFrame("row3")
        }
        .daydreamCard()
    }
}

/// One 56 pt area row (settings-A `ARow`): 40 pt area art, the title, a quiet accessory and a chevron.
/// VoiceOver reads the title, the accessory as its value, and where it goes.
private struct SettingsAreaRow<Accessory: View>: View {
    let title: String
    let area: Area
    var accessory: String? = nil
    var badge: BadgeKind? = nil
    var accessibilityLabel: String? = nil
    let action: () -> Void
    @ViewBuilder let trailing: () -> Accessory
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                AreaIcon(area, size: 40)
                    .stateBadge(badge, iconSize: 40, ring: DaydreamStyle.card)
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 12)
                trailing()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
        }
        .buttonStyle(SettingsRowButtonStyle(hovered: hovered, tint: badge == .attention ? KitPalette.orange : nil))
        .onHover { hovered = $0 }
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityValue(accessory ?? "")
        .accessibilityHint("Opens " + title)
    }
}

/// The row's hover and press fill, inset like System Settings' grouped rows. An attention row keeps a
/// faint orange wash.
private struct SettingsRowButtonStyle: ButtonStyle {
    let hovered: Bool
    let tint: Color?
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.08)
                          : tint.map { $0.opacity(hovered ? 0.12 : 0.08) } ?? Color.primary.opacity(hovered ? 0.045 : 0))
                    .padding(.vertical, 3).padding(.horizontal, 4))
    }
}

private struct SettingsRowDivider: View {
    var body: some View {
        Rectangle().fill(KitPalette.rule).frame(height: 1)
            .padding(.leading, 68).padding(.trailing, 18)
            .accessibilityHidden(true)
    }
}

/// The only accessory with colour: a problem, in an orange capsule.
private struct SettingsProblemPill: View {
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(KitPalette.orange)
        .padding(.horizontal, 9).frame(height: 24)
        .background(KitPalette.orange.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

private struct SettingsRowFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func reportingFrame(_ key: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: SettingsRowFrames.self, value: [key: proxy.frame(in: .global)])
        })
    }
}

/// The privacy promise's long wording (typesafe SPEC 9.2; the Settings overview shows its own short line,
/// `DaydreamSettingsOverview.storageFooter`, with Learn more to `policyURL`, PRIVACY.md) (
/// "privacy promise fix", worded with the Saturday honesty rule: never "stays on this Mac"): history
/// is kept on this Mac, AI apps you connect read it and pass what they read to their AI provider, and
/// cloud summaries, when on, send the activity they summarize to OpenRouter. Cloud summaries
/// get the words you type (summaries/v3: decision 8 reversed) and, since fix/sx-all (owner 9/28), Chrome page titles
/// cleaned of addresses and unread counts.
public enum PrivacyPromise {
    public static let sentence = "Your history is kept on this Mac. AI apps you connect can read it and send what they read to their AI provider. Cloud summaries, if you turn them on, send the activity they summarize to OpenRouter."
    /// What cloud summaries get, in the words of the switch's own line (CloudSummariesText.line) and PRIVACY.md.
    public static let cloudLimit = "Cloud summaries get window titles, page titles and the words you type."
    /// The long form behind the Settings overview's Learn more.
    public static let policyURL = URL(string: "https://github.com/getnorthlight/daydream/blob/main/PRIVACY.md")!
}

/// How setup, Settings and the Settings overview read the one summaries state (`SummaryPhase`): one state at a time, and
/// every problem with its one line and one button.
public enum SummaryPhaseReading {
    public static let localValue = "On this Mac"
    public static let cloudValue = "OpenRouter"
    public static let offValue = "Off"

    public static func problem(_ phase: SummaryPhase) -> SummaryProblem? {
        if case .failed(let problem) = phase { return problem }
        return nil
    }
    /// A problem with the OpenRouter key, account or connection (its fix is on the cloud row).
    public static func isCloud(_ problem: SummaryProblem) -> Bool {
        [.cloudKey, .cloudCredits, .cloudHost, .cloudOffline].contains(problem)
    }
    /// "Summaries on this Mac" reads on: downloading, checking, on this Mac, or stopped by a problem on this Mac.
    public static func localOn(_ phase: SummaryPhase) -> Bool {
        switch phase {
        case .downloading, .checking, .on(.local): return true
        case .failed(let problem): return !isCloud(problem)
        default: return false
        }
    }
    /// The OpenRouter switch reads on: on with the key, or stopped by a problem with the key or the account.
    public static func cloudOn(_ phase: SummaryPhase) -> Bool {
        switch phase {
        case .on(.cloud): return true
        case .failed(let problem): return isCloud(problem)
        default: return false
        }
    }
    /// The one value: the phase's line while it has one (Downloading 1.2 of 2.7 GB, a problem), else On this Mac,
    /// OpenRouter or Off.
    public static func value(_ phase: SummaryPhase) -> String {
        if let line = phase.line { return line }
        switch phase {
        case .on(.local): return localValue
        case .on(.cloud): return cloudValue
        default: return offValue
        }
    }
    /// The phase a `SummaryAvailability` stands for, from its provider, busy and download progress.
    public static func phase(_ summaries: SummaryAvailability) -> SummaryPhase {
        switch summaries.provider {
        case .local: return .on(.local)
        case .cloud: return .on(.cloud)
        case .off:
            guard summaries.busy else { return .off }
            guard let progress = summaries.downloadProgress else { return .checking }
            let total = Int64(2_740_937_888) // WriterCandidates.recommended's model (MemoryUI doesn't link WriterBackend)
            return .downloading(received: Int64(progress * Double(total)), total: total)
        }
    }
    /// The size of the model, as setup's line says it ("2.7 GB").
    public static func gigabytes(_ bytes: Int64) -> String { SummaryPhase.gigabytes(bytes) + " GB" }
}
