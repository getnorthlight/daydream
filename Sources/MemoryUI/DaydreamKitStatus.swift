import SwiftUI
import AppKit

// DayDream visual kit: recording status (spec §5, §10.2, §10.3, §10.11). State glyphs and badges,
// the shared recording controls for the header popover and the menu bar card, permission rows,
// link rows and the trust and exclusion footnotes. Lifted from `status/common.swift`,
// `status/header.swift` and `status/menubar.swift` with the prototype clock and copy removed.
// Every control calls exactly one `CaptureActions` closure; rendering and hovering call none.

// MARK: - Tints

extension DaydreamCaptureState {
    /// Recording red, Paused indigo, Off secondary, Needs Permission orange (spec §1.2).
    public var tint: Color {
        switch self {
        case .recording: return KitPalette.red
        case .paused: return DaydreamStyle.paused
        case .off: return .secondary
        case .needsPermission: return KitPalette.orange
        }
    }
}

extension RecordingState {
    public var tint: Color { kind.tint }

    /// Share of a timed pause still to run (1 at the start, 0 at the end). nil when open-ended
    /// or when the pause start is unknown.
    public func pauseRemaining(now: Date) -> Double? {
        guard case .paused(let until?, let since?, _) = self else { return nil }
        let total = until.timeIntervalSince(since)
        guard total > 0 else { return nil }
        return min(1, max(0, until.timeIntervalSince(now) / total))
    }
}

// MARK: - Clock

/// Supplies "now" to status glyphs: the environment's fixed clock (renders, checks) or a
/// 30-second tick in the app.
///
/// A plain timer, not a `TimelineView` (fix/scroll-perf): a timeline hangs its content on the graph's own clock, so
/// every frame of a scroll re-dirtied the day card's ribbon (every span and its menu), about a third of each frame.
struct KitClock<Content: View>: View {
    let content: (Date) -> Content
    @Environment(\.daydreamNow) private var fixedNow
    @State private var now = Date()
    init(@ViewBuilder content: @escaping (Date) -> Content) { self.content = content }
    var body: some View {
        if let fixedNow {
            content(fixedNow)
        } else {
            content(now).onReceive(KitClockTicks.every30s) { now = $0 }
        }
    }
}

/// One shared 30-second tick for every `KitClock` (one publisher, so a redraw never restarts it).
enum KitClockTicks {
    static let every30s = Timer.publish(every: 30, tolerance: 1, on: .main, in: .common).autoconnect().share()
}

// MARK: - Glyph pieces (status/common.swift)

struct KitRing: View {
    let progress: Double?
    let color: Color
    let size: CGFloat
    let line: CGFloat
    var track: Double = 0.2
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(track), lineWidth: line)
            if let progress {
                Circle().trim(from: 0, to: min(1, max(0, progress)))
                    .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size - line, height: size - line)
        .frame(width: size, height: size)
    }
}

struct KitPauseBars: View {
    let color: Color
    let h: CGFloat
    var body: some View {
        HStack(spacing: h * 0.3) {
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: h * 0.16, style: .continuous).fill(color).frame(width: h * 0.3, height: h)
            }
        }
    }
}

/// Red live dot on a soft, still halo: solid, the same in every frame (owner, launch build 9/28: "nothing moving, no
/// status noise"). It used to breathe (a 1.6 s repeating scale and opacity on the halo), which kept the window
/// redrawing for as long as it was open and recording; the perf audit measured it as a steady CPU cost. The halo is
/// drawn at rest, exactly as renders and Reduce Motion always drew it, so the look doesn't change.
///
/// No state, no timer, no animation: nothing here can move the dot or ask for another frame. Before the breathing was
/// removed, a `withAnimation(.repeatForever)` in `onAppear` also dragged the capsule on a diagonal (45495a5, d91be87).
/// check: dd-kit-checks (liveDotStaysPut: every frame identical to the static render, and the source sweep) and
/// dd-status-checks (compositeLiveDot, in the real window toolbar).
struct LiveDot: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(KitPalette.redHalo)
                .frame(width: size * 2, height: size * 2)
            Circle().fill(LinearGradient(colors: [Color(.sRGB, red: 1, green: 0.42, blue: 0.38, opacity: 1), Color(.sRGB, red: 0.94, green: 0.16, blue: 0.16, opacity: 1)],
                                         startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
        }
        .frame(width: size * 2, height: size * 2)
        // No animation reaches the dot: a state change swaps it in place.
        .transaction { $0.animation = nil }
    }
}

struct MiniAlert: View {
    let size: CGFloat
    var body: some View {
        Circle().fill(LinearGradient(colors: [Color(.sRGB, red: 1, green: 0.70, blue: 0.22, opacity: 1), Color(.sRGB, red: 0.98, green: 0.50, blue: 0.06, opacity: 1)],
                                     startPoint: .top, endPoint: .bottom))
            .overlay(Image(systemName: "exclamationmark").font(.system(size: size * 0.58, weight: .heavy)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

/// A slashed ring (never a dashed ring, which reads as loading).
struct MiniOff: View {
    let size: CGFloat
    var body: some View {
        Image(systemName: "circle.slash").font(.system(size: size * 0.92, weight: .medium)).foregroundStyle(.secondary)
            .frame(width: size, height: size)
    }
}

// MARK: - State glyph (small)

/// The small state glyph for capsules, footers and rows: live dot (Recording), draining countdown
/// ring with pause bars (timed pause), pause bars (open-ended pause), slashed ring (Off), orange
/// "!" (Needs Permission). Hidden from VoiceOver: the surrounding label carries the state.
public struct StateGlyph: View {
    let state: RecordingState
    let size: CGFloat
    public init(state: RecordingState, size: CGFloat = 16) { self.state = state; self.size = size }
    public var body: some View {
        Group {
            switch state {
            case .recording:
                LiveDot(size: size * 0.44)
            case .paused(let until, _, _):
                if until != nil {
                    KitClock { now in
                        ZStack {
                            KitRing(progress: state.pauseRemaining(now: now) ?? 1, color: DaydreamStyle.paused, size: size, line: 2, track: 0.22)
                            KitPauseBars(color: DaydreamStyle.paused, h: size * 0.34)
                        }
                    }
                } else {
                    ZStack {
                        KitRing(progress: nil, color: DaydreamStyle.paused, size: size, line: 2, track: 0.22)
                        KitPauseBars(color: DaydreamStyle.paused, h: size * 0.34)
                    }
                }
            case .off:
                MiniOff(size: size * 0.94)
            case .needsPermission:
                MiniAlert(size: size * 0.94)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - State badge (44 pt)

/// The large state badge for the popover and menu bar card: red dot with halo, indigo countdown
/// ring, grey slashed ring, orange "!".
public struct StateBadge: View {
    let state: RecordingState
    let size: CGFloat
    public init(_ state: RecordingState, size: CGFloat = 44) { self.state = state; self.size = size }
    public var body: some View {
        Group {
            switch state {
            case .recording:
                ZStack {
                    Circle().fill(KitPalette.redHalo)
                    Circle().strokeBorder(KitPalette.red.opacity(0.25), lineWidth: 1)
                    Circle().fill(LinearGradient(colors: [Color(.sRGB, red: 1, green: 0.45, blue: 0.40, opacity: 1), Color(.sRGB, red: 0.93, green: 0.15, blue: 0.16, opacity: 1)],
                                                 startPoint: .top, endPoint: .bottom))
                        .frame(width: size * 0.44, height: size * 0.44)
                        .shadow(color: Color(.sRGB, red: 1, green: 0.25, blue: 0.2, opacity: 0.55), radius: size * 0.1)
                }
            case .paused:
                KitClock { now in
                    ZStack {
                        Circle().fill(DaydreamStyle.paused.opacity(0.1))
                        KitRing(progress: state.pauseRemaining(now: now) ?? (isTimed ? 1 : nil), color: DaydreamStyle.paused,
                                size: size, line: max(3.5, size * 0.09), track: 0.16)
                        KitPauseBars(color: DaydreamStyle.paused, h: size * 0.3)
                    }
                }
            case .off:
                ZStack {
                    Circle().fill(Color.primary.opacity(0.07))
                    Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                    Image(systemName: "circle.slash").font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.secondary)
                }
            case .needsPermission:
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color(.sRGB, red: 1, green: 0.72, blue: 0.25, opacity: 1), Color(.sRGB, red: 0.98, green: 0.52, blue: 0.08, opacity: 1)],
                                                 startPoint: .top, endPoint: .bottom))
                    Image(systemName: "exclamationmark").font(.system(size: size * 0.42, weight: .heavy)).foregroundStyle(.white)
                }
                .shadow(color: KitPalette.orange.opacity(0.35), radius: 4, y: 1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
    private var isTimed: Bool { if case .paused(_?, _, _) = state { return true }; return false }
}

/// Badge, title and detail line for a recording state (header-A `PopHeader`, M1 `M1State`).
/// Title per the copy deck (`Recording`, `Paused`, `Off`, `Needs Permission`, orange for the last);
/// the detail is `RecordingState.detail(now:timeZone:)`.
public struct RecordingStateHeader: View {
    public enum Style: Sendable { case popover, menu }
    let state: RecordingState
    let style: Style
    let timeZone: TimeZone
    public init(state: RecordingState, style: Style = .popover, timeZone: TimeZone) {
        self.state = state; self.style = style; self.timeZone = timeZone
    }
    public var body: some View {
        KitClock { now in
            HStack(spacing: 12) {
                StateBadge(state, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.system(size: style == .menu ? 17 : 15, weight: style == .menu ? .bold : .semibold))
                        .foregroundStyle(state.kind == .needsPermission ? AnyShapeStyle(KitPalette.orange) : AnyShapeStyle(.primary))
                    if let detail = state.detail(now: now, timeZone: timeZone) {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // The column fills the row (W2-26): no trailing spacer, so its HStack spacing goes to the text.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording status")
            .accessibilityValue(state.accessibilityValue(now: now, timeZone: timeZone))
        }
    }
}

// MARK: - Recording controls

/// One control of `RecordingControls`, as data (the checks and the native menus read the same list).
public struct RecordingControlButton: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String?
    public let prominent: Bool
    public let enabled: Bool
    public let action: RecordingAction
    public let help: String
    public let accessibilityLabel: String
    /// A pause preset shown as a segment rather than a capsule.
    public var isPreset: Bool { if case .pause = action { return true }; return false }
}

/// The recording controls shared by the header popover and the menu bar card.
/// - Recording: `Pause for` presets `5m 15m 30m 2h` (help `Pause for 5 minutes`, …) and `Stop Recording`.
/// - Paused: `Resume Recording` (blue) and `Stop Recording`.
/// - Off: `Start Recording` (blue), with an optional reason line when it can't start.
/// - Needs Permission: the two permission rows, `Allow Permissions` (blue, full width: DayDream's drag cards),
///   then a quiet `Check Again` link.
/// At most one blue control per state; Stop is never blue.
public struct RecordingControls: View {
    public enum Style: Sendable { case popover, menu }

    let state: RecordingState
    let actions: CaptureActions
    let style: Style
    let canStart: Bool
    let canStop: Bool
    let permissions: PermissionSnapshot?
    let startBlockedReason: String?

    public init(state: RecordingState, actions: CaptureActions, style: Style, canStart: Bool = true, canStop: Bool = true,
                permissions: PermissionSnapshot? = nil, startBlockedReason: String? = nil) {
        self.state = state; self.actions = actions; self.style = style; self.canStart = canStart; self.canStop = canStop
        self.permissions = permissions; self.startBlockedReason = startBlockedReason
    }

    /// From the app's presentation: state, `canResume`, `canStop` and the permission reads.
    public init(presentation p: CapturePresentation, actions: CaptureActions, style: Style, startBlockedReason: String? = nil) {
        self.init(state: p.state, actions: actions, style: style, canStart: p.canResume, canStop: p.canStop,
                  permissions: p.permissions, startBlockedReason: startBlockedReason)
    }

    // MARK: Model

    static func presetTitle(_ minutes: Int) -> String { minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m" }
    static func presetSpoken(_ minutes: Int) -> String {
        if minutes % 60 == 0 { let h = minutes / 60; return h == 1 ? "1 hour" : "\(h) hours" }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// The controls for a state, in display order. Presets appear only while Recording.
    public static func buttons(for state: RecordingState, style: Style = .popover, canStart: Bool = true,
                               canStop: Bool = true) -> [RecordingControlButton] {
        let stop = RecordingControlButton(id: "stop", title: "Stop Recording", symbol: "stop.fill", prominent: false, enabled: canStop,
                                          action: .stop, help: canStop ? "Stop Recording" : "Recording can't be stopped right now",
                                          accessibilityLabel: "Stop Recording")
        switch state {
        case .recording:
            let presets = RecordingState.pausePresets.map { m in
                RecordingControlButton(id: "pause-\(m)", title: presetTitle(m), symbol: nil, prominent: false, enabled: true,
                                       action: .pause(minutes: m), help: "Pause for " + presetSpoken(m),
                                       accessibilityLabel: "Pause for " + presetSpoken(m))
            }
            return presets + [stop]
        case .paused:
            return [RecordingControlButton(id: "resume", title: "Resume Recording", symbol: "play.fill", prominent: true, enabled: canStart,
                                           action: .resume, help: "Resume Recording", accessibilityLabel: "Resume Recording"), stop]
        case .off:
            return [RecordingControlButton(id: "start", title: "Start Recording", symbol: "record.circle", prominent: true, enabled: canStart,
                                           action: .start, help: "Start Recording", accessibilityLabel: "Start Recording")]
        case .needsPermission:
            // perm-1004: `Turn on Accessibility` (the permission to turn on next): its System Settings pane, with
            // DayDream's drag card beside it. `Allow Permissions` while which one is missing isn't known.
            let title = state.nextPermission?.turnOnTitle ?? "Allow Permissions"
            return [RecordingControlButton(id: "open-system-settings", title: title, symbol: "checkmark.shield", prominent: true,
                                           enabled: true, action: .openSystemSettings,
                                           help: state.nextPermission.map { "Opens \($0.title) in System Settings, with DayDream's card to drag into the list" }
                                               ?? "Show how to allow Accessibility and Input Monitoring",
                                           accessibilityLabel: title),
                    RecordingControlButton(id: "check-again", title: "Check Again", symbol: "arrow.clockwise", prominent: false, enabled: true,
                                           action: .checkAgain, help: "Check permissions again", accessibilityLabel: "Check Again")]
        }
    }

    /// Runs one control: exactly one `CaptureActions` closure. `Allow Permissions` passes the one missing
    /// permission when exactly one is known to be missing, else nil (the app shows DayDream's drag cards).
    public static func perform(_ action: RecordingAction, actions: CaptureActions, state: RecordingState,
                               permissions: PermissionSnapshot? = nil) {
        if action == .openSystemSettings {
            var missing = permissions?.missing ?? []
            if case .needsPermission(let m) = state { missing.formUnion(m) }
            // perm-1004: the permission to turn on next (Accessibility first), not only when exactly one is missing.
            actions.openSystemSettings(PermissionKind.next(missing))
            return
        }
        actions.perform(action)
    }

    private var model: [RecordingControlButton] { Self.buttons(for: state, style: style, canStart: canStart, canStop: canStop) }
    private func run(_ b: RecordingControlButton) {
        guard b.enabled else { return }
        Self.perform(b.action, actions: actions, state: state, permissions: permissions)
    }
    private func button(_ id: String) -> RecordingControlButton? { model.first { $0.id == id } }

    // MARK: Views

    public var body: some View {
        Group {
            switch state {
            case .recording: recording
            case .paused: paused
            case .off: off
            case .needsPermission: permission
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var menu: Bool { style == .menu }

    @ViewBuilder private func capsule(_ b: RecordingControlButton, height: CGFloat, expand: Bool) -> some View {
        Button { run(b) } label: {
            // An arrow that leaves the app trails the title (copy deck §8.3); Allow Permissions stays in DayDream.
            let trailing = b.symbol == "arrow.up.forward"
            HStack(spacing: 6) {
                if let symbol = b.symbol, !trailing { glyph(symbol, b) }
                Text(b.title).lineLimit(1).fixedSize()
                if let symbol = b.symbol, trailing { glyph(symbol, b).accessibilityHidden(true) }
            }
        }
        .buttonStyle(KitCapsuleButtonStyle(prominent: b.prominent, height: height, expand: expand, horizontalPadding: menu ? 10 : nil))
        .disabled(!b.enabled)
        .help(b.help)
        .accessibilityLabel(b.accessibilityLabel)
    }

    private func glyph(_ symbol: String, _ b: RecordingControlButton) -> some View {
        Image(systemName: symbol).font(.system(size: b.prominent ? 11 : 10, weight: .bold))
            .foregroundStyle(b.action == .stop ? AnyShapeStyle(KitPalette.red) : AnyShapeStyle(b.prominent ? Color.white : Color.primary))
    }

    private var presets: some View {
        let items = model.filter(\.isPreset).map {
            SegmentedItem(id: $0.id, title: $0.title, help: $0.help, accessibilityLabel: $0.accessibilityLabel, enabled: $0.enabled)
        }
        return Segmented(items, highlighted: "pause-15", height: menu ? 32 : 28) { id in
            if let b = button(id) { run(b) }
        }
    }

    private var pauseHeader: some View {
        HStack(spacing: 6) {
            Text("Pause for").font(.system(size: menu ? 11 : 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if menu {
                Text("⌘P pauses 15 min").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 5) {
                    Keycap("⌘P")
                    Text("pauses 15 min").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var recording: some View {
        if menu {
            VStack(alignment: .leading, spacing: 7) {
                pauseHeader
                HStack(spacing: 8) {
                    presets
                    if let stop = button("stop") { capsule(stop, height: 32, expand: false) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                pauseHeader
                presets
                if let stop = button("stop") { capsule(stop, height: 28, expand: true).padding(.top, 2) }
            }
        }
    }

    private var paused: some View {
        HStack(spacing: 8) {
            if let resume = button("resume") { capsule(resume, height: menu ? 30 : 28, expand: true) }
            if let stop = button("stop") { capsule(stop, height: menu ? 30 : 28, expand: false) }
        }
    }

    private var off: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let start = button("start") { capsule(start, height: menu ? 32 : 28, expand: true) }
            if !canStart, let reason = startBlockedReason, !reason.isEmpty {
                Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permission: some View {
        let missing: Set<PermissionKind> = { if case .needsPermission(let m) = state { return m }; return [] }()
        func granted(_ kind: PermissionKind) -> Bool? {
            if missing.contains(kind) { return false }
            switch kind {
            case .accessibility: return permissions?.accessibility
            case .inputMonitoring: return permissions?.inputMonitoring
            }
        }
        return VStack(alignment: .leading, spacing: menu ? 10 : 12) {
            VStack(spacing: 0) {
                PermissionRow(.accessibility, granted: granted(.accessibility))
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).padding(.leading, 50)
                PermissionRow(.inputMonitoring, granted: granted(.inputMonitoring))
            }
            .kitTile(12, fill: KitPalette.inset)
            if let open = button("open-system-settings") { capsule(open, height: menu ? 32 : 28, expand: true) }
            HStack(spacing: 8) {
                Spacer(minLength: 6)
                if let again = button("check-again") { link(again) }
            }
        }
    }

    /// A quiet accent link (`Check Again`): never a second blue capsule.
    private func link(_ b: RecordingControlButton) -> some View {
        Button { run(b) } label: {
            HStack(spacing: 4) {
                if let symbol = b.symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
                Text(b.title).lineLimit(1).fixedSize()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!b.enabled)
        .help(b.help)
        .accessibilityLabel(b.accessibilityLabel)
    }
}

// MARK: - Permission row

/// A macOS permission with its pane icon and state: `Allowed` with a green check, an orange `Off`
/// tag, or nothing when it hasn't been read.
public struct PermissionRow: View {
    let kind: PermissionKind
    let granted: Bool?
    public init(_ kind: PermissionKind, granted: Bool?) { self.kind = kind; self.granted = granted }

    public static func subtitle(_ kind: PermissionKind) -> String {
        // Input Monitoring is needed for clicks even with typing off, so it never reads as optional.
        kind == .accessibility ? "Apps, windows and pages" : "Clicks, and typing when on"
    }

    public var body: some View {
        HStack(spacing: 10) {
            PermissionPaneIcon(kind, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(Self.subtitle(kind)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if granted == true {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(KitPalette.green)
                    Text("Allowed").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else if granted == false {
                Text("Off").font(.system(size: 11, weight: .semibold)).foregroundStyle(KitPalette.orange)
                    .padding(.horizontal, 8).frame(height: 20).background(KitPalette.orange.opacity(0.15), in: Capsule())
            }
        }
        .padding(.horizontal, 12).frame(height: 50)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.title)
        .accessibilityValue(granted == true ? "Allowed" : granted == false ? "Off" : "Not checked")
    }
}

// MARK: - Link row

/// A 36 pt row that opens a settings area: illustrated icon, title, a trailing status and a chevron.
public struct LinkRow<Trailing: View>: View {
    let title: String
    let area: Area
    let action: () -> Void
    let trailing: Trailing
    @State private var hovered = false

    public init(_ title: String, area: Area, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.area = area; self.action = action; self.trailing = trailing()
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AreaIcon(area, size: 24)
                Text(title).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(1).fixedSize()
                Spacer(minLength: 6)
                trailing.layoutPriority(1)   // W2-23: the trailing value keeps its width before the spacer gives way
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).frame(height: 36)
        }
        .buttonStyle(KitRowButtonStyle(radius: 8, hovered: hovered))
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
    }
}

extension LinkRow where Trailing == EmptyView {
    public init(_ title: String, area: Area, action: @escaping () -> Void) {
        self.init(title, area: area, action: action) { EmptyView() }
    }
}

// MARK: - Footnotes

/// Exclusions line: `{a} always private · {b} excluded by you` and the shared footnote.
public struct ExclusionFootnote: View {
    let summary: ExclusionSummary
    let showsCounts: Bool
    public init(summary: ExclusionSummary, showsCounts: Bool = true) { self.summary = summary; self.showsCounts = showsCounts }

    public static let footnote = "Always-private apps can't be recorded. Apps you exclude are skipped from now on."
    public static func countsText(_ s: ExclusionSummary) -> String {
        "\(s.alwaysPrivate.count) always private · \(s.excludedByYou.count) excluded by you"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showsCounts {
                Text(Self.countsText(summary)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(Self.footnote).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Lock + `Common password managers are skipped. Add others in Settings.` Private windows are named only
/// when the caller has verified the private-window drop path (spec §2.3, L23). "Common": the built-in list
/// (`PasswordManagerApps`) can't name every password manager, so the line says how to add one. `short` (the
/// status popover, whose width clipped the long line mid-word) keeps "Common" and drops the how-to, which setup
/// and Settings › Apps to remember still say.
public struct TrustFooter: View {
    let includePrivateWindows: Bool
    let short: Bool
    public init(includePrivateWindows: Bool = false, short: Bool = false) {
        self.includePrivateWindows = includePrivateWindows; self.short = short
    }
    /// The popover's short form. It still says "Common": only common password managers are skipped.
    public static let shortText = "Common password managers are skipped."
    public static func text(includePrivateWindows: Bool) -> String {
        includePrivateWindows ? "Common password managers and private windows are skipped. Add other apps in Settings." : DaydreamSetupText.passwordManagers
    }
    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").font(.system(size: 10))
            Text(short && !includePrivateWindows ? Self.shortText : Self.text(includePrivateWindows: includePrivateWindows))
                .font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
