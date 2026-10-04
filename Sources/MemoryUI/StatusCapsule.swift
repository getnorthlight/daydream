import SwiftUI
import AppKit

// Header-A status capsule (spec §5.1, plan §5 A3; lifted from proto/status/header.swift `StatusCapsule`,
// and `StartSplit`). The capsule only opens the popover: every capture change is an explicit press inside it.
// Off and able to start, the capsule's place is the Start Recording pill: its label starts recording (the one
// capture change outside the popover, and it says so), its chevron opens the popover. Opening changes nothing.
//
// | State            | Glyph (StateGlyph 16)     | Label               | Chrome                          |
// | Recording        | red live dot              | `Recording`         | toolbar item                    |
// | Paused until     | draining indigo ring      | `Paused · 12m`      | toolbar item                    |
// | Paused           | indigo pause bars         | `Paused`            | toolbar item                    |
// | Off              | slashed ring              | `Off`               | toolbar item (Start Recording   |
// |                  |                           |                     | pill instead when it can start) |
// | Needs Permission | orange "!"                | `Needs Permission`  | dimOrange fill, orange stroke   |
//
// Below 720 pt the capsule is its glyph in a 32 pt circle; its label, value and help keep the full state.

// MARK: - Capsule

public struct StatusCapsule: View {
    let state: RecordingState
    let canStart: Bool
    let compact: Bool
    let isOpen: Bool
    let timeZone: TimeZone
    let action: () -> Void
    var chrome: ToolbarItemChrome = .inline
    @State private var hovered = false

    /// - `canStart`: Recording can start from Off (`CapturePresentation.canResume`); only the help changes.
    /// - `isOpen`: the popover is showing (the capsule draws its pressed fill).
    /// - `action`: toggles the popover. It must not change recording.
    public init(state: RecordingState, canStart: Bool = true, compact: Bool = false, isOpen: Bool = false,
                timeZone: TimeZone = .current, action: @escaping () -> Void = {}) {
        self.state = state; self.canStart = canStart; self.compact = compact; self.isOpen = isOpen
        self.timeZone = timeZone; self.action = action
    }

    init(state: RecordingState, canStart: Bool, compact: Bool, isOpen: Bool, timeZone: TimeZone, chrome: ToolbarItemChrome,
         action: @escaping () -> Void) {
        self.init(state: state, canStart: canStart, compact: compact, isOpen: isOpen, timeZone: timeZone, action: action)
        self.chrome = chrome
    }

    public var body: some View {
        // Only a timed pause reads the clock here (`Paused · 12m`); Recording, Off, an open pause and Needs Permission
        // draw the same at every instant, so they run no clock and nothing redraws the capsule while recording.
        StatusClock(until: state.pauseUntil, ticks: state.pauseUntil != nil) { now in
            Button(action: action) { label(now) }
                .buttonStyle(StatusCapsuleButtonStyle(state: state, compact: compact, highlighted: isOpen || hovered, chrome: chrome,
                                                      width: Self.width(for: state, compact: compact)))
                .onHover { hovered = $0 }
                .help(Self.help(for: state, canStart: canStart, timeZone: timeZone))
                .accessibilityLabel("Recording status")
                .accessibilityValue(state.accessibilityValue(now: now, timeZone: timeZone))
                .accessibilityIdentifier("capture-state")
        }
    }

    @ViewBuilder private func label(_ now: Date) -> some View {
        HStack(spacing: 7) {
            StateGlyph(state: state, size: 16)
            if !compact {
                Self.title(state.capsuleLabel(now: now), permission: state.kind == .needsPermission)
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .lineLimit(1).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(state.kind == .needsPermission ? AnyShapeStyle(KitPalette.orange.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
            }
        }
        // The glyph and the words never move: a state change swaps them in place (owner 9/28: the live dot travelled
        // on a diagonal under "Recording"). The live dot itself is solid (LiveDot).
        .transaction { $0.animation = nil }
    }

    /// `Paused · 12m` draws its countdown secondary; Needs Permission is orange.
    static func title(_ label: String, permission: Bool) -> Text {
        if permission { return Text(label).foregroundColor(KitPalette.orange) }
        guard let dot = label.range(of: " · ") else { return Text(label).foregroundColor(.primary) }
        return Text(label[..<dot.lowerBound]).foregroundColor(.primary) + Text(label[dot.lowerBound...]).foregroundColor(.secondary)
    }

    // MARK: Model (shared with the checks)

    /// Tooltip: the state alone, `Recording since 8:40 AM`, `Paused until 4:36 PM`, `Off`, `Needs Permission`
    /// (declutter: no "Click to …"). "since" and "until" are left out when unknown. `canStart` is kept for
    /// callers; Off reads the same either way (Off and able to start draws the Start Recording pill instead).
    public static func help(for state: RecordingState, canStart: Bool = true, timeZone: TimeZone) -> String {
        switch state {
        case .recording(let since):
            return since.map { "Recording since " + DaydreamFormat.time($0, timeZone) } ?? "Recording"
        case .paused(let until, _, _):
            return until.map { "Paused until " + DaydreamFormat.time($0, timeZone) } ?? "Paused"
        case .off:
            return "Off"
        case .needsPermission:
            // perm-1004: which permission is off, as the detail line says it ("Accessibility is off in System Settings.").
            return state.nextPermission == nil ? "Needs Permission" : state.detail(now: Date(), timeZone: timeZone) ?? state.title
        }
    }

    /// Width the capsule is pinned to, in the window toolbar and the in-content row (NSToolbar on macOS 13 caches item
    /// sizes, so it must not change while a pause counts down). sat5: the owner saw the recording control move
    /// around, because each state had its own width (and Off's Start Recording pill another). Every state now
    /// takes the same slot (`slotWidth`), so the control and the gear beside it stay put; the label is centred.
    public static func width(for state: RecordingState, compact: Bool) -> CGFloat {
        compact ? 32 : slotWidth
    }

    /// The one width of the recording control in the wide toolbar: the widest of every state's own width and the
    /// Start Recording pill with its chevron.
    public static let slotWidth: CGFloat = {
        let states: [RecordingState] = [.recording(since: nil), .paused(until: Date(), since: nil, reason: nil),
                                        .paused(until: nil, since: nil, reason: nil), .off(since: nil, reason: nil), .needsPermission(missing: [])]
        return max(states.map(ownWidth).max() ?? 0, StartRecordingButton.width(more: true), StartRecordingButton.width(more: false))
    }()

    /// What a state's label needs on its own. A timed pause reserves its longest countdown.
    static func ownWidth(_ state: RecordingState) -> CGFloat {
        let label: String
        switch state {
        case .paused(_?, _, _): label = "Paused · 1h 59m"
        // perm-1004: Needs Permission names the permission to turn on; the slot reserves the longer of the two.
        case .needsPermission: label = PermissionKind.allCases.map(\.turnOnTitle).max { $0.count < $1.count } ?? state.kind.title
        default: label = state.kind.title
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let text = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        let leading: CGFloat = state.kind == .recording ? 7 : 10
        // glyph 16 + 7 + text + 7 + chevron + trailing 12 (+1 rounding slack)
        return leading + 16 + 7 + text + 7 + chevronWidth + 12 + 1
    }

    /// The 9 pt bold `chevron.down` as laid out (11 pt wide; the point size is not its width).
    static let chevronWidth: CGFloat = {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        return ceil(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(config)?.size.width ?? 11)
    }()
}

extension RecordingState {
    /// The end of a timed pause; nil otherwise.
    var pauseUntil: Date? { if case .paused(let until?, _, _) = self { return until }; return nil }
}

/// Capsule chrome: 32 pt tall, item fill with a hairline and a soft shadow; the pointer or the open popover
/// darkens the fill and drops the shadow. Needs Permission is tinted orange. Where the system draws glass
/// (macOS 26 window toolbar) the resting fill, hairline and shadow are left to it, but the pointer / open fill is
/// still drawn: it is what marks the capsule as the open popover's anchor.
struct StatusCapsuleButtonStyle: ButtonStyle {
    let state: RecordingState
    let compact: Bool
    let highlighted: Bool
    let chrome: ToolbarItemChrome
    /// A pinned width (window toolbar); nil hugs the label.
    var width: CGFloat? = nil

    /// The pointer-over / open-popover fill (header-A: primary α.1).
    static let activeFill = Color.primary.opacity(0.1)

    func makeBody(configuration: Configuration) -> some View {
        let permission = state.kind == .needsPermission
        let active = highlighted || configuration.isPressed
        let fill: Color = permission ? KitPalette.dimOrange : active ? Self.activeFill : ToolbarPalette.item
        let stroke: Color = permission ? KitPalette.orange.opacity(0.5) : ToolbarPalette.stroke
        return configuration.label
            .padding(.leading, compact ? 0 : (state.kind == .recording ? 7 : 10))
            .padding(.trailing, compact ? 0 : 12)
            .frame(width: compact ? 32 : width, height: 32)
            .contentShape(Capsule())
            .background { if !chrome.drawsFill && active { Capsule().fill(Self.activeFill) } }
            .toolbarItemChrome(Capsule(), fill: fill, stroke: stroke, shadow: !active, chrome: chrome)
    }
}

// MARK: - Start Recording (Off)

/// The Off state's control when recording can start: one blue pill in the capsule's place. Its label,
/// `Start Recording`, starts recording (one explicit press); its chevron (`more`) opens the status popover,
/// which says what needs attention. With no `more` (a plain Off, whose popover would only repeat Start
/// Recording), just the label, and the label is then the toolbar's recording control (`capture-state`).
public struct StartRecordingButton: View {
    let isOpen: Bool
    let action: () -> Void
    let more: (() -> Void)?
    /// The toolbar's fixed slot (`StatusCapsule.slotWidth`); nil hugs the label.
    var width: CGFloat? = nil
    /// Below 720 pt: a 32 pt circle, as the capsule is there. With `more` it opens the popover (which offers Start
    /// Recording and says what needs attention); without, it starts recording.
    var compact = false
    public init(isOpen: Bool = false, action: @escaping () -> Void, more: (() -> Void)? = nil) {
        self.isOpen = isOpen; self.action = action; self.more = more
    }
    init(isOpen: Bool, action: @escaping () -> Void, more: (() -> Void)?, width: CGFloat?, compact: Bool) {
        self.init(isOpen: isOpen, action: action, more: more)
        self.width = width; self.compact = compact
    }

    public var body: some View {
        if compact { circle } else { pill }
    }

    private var circle: some View {
        Self.recordingControl(Button(action: more ?? action) {
            Image(systemName: "record.circle").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.gradient, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(StartPillPressStyle(pressed: isOpen))
        .clipShape(Circle())
        .help(more == nil ? "Start Recording" : "Off")
        .accessibilityLabel(more == nil ? "Start Recording" : "Recording status")
        .accessibilityValue(more == nil ? "" : "Off"))
    }

    private var pill: some View {
        HStack(spacing: 0) {
            let label = Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle").font(.system(size: 12, weight: .semibold)).accessibilityHidden(true)
                    Text("Start Recording").fixedSize()
                }
                .padding(.leading, 14).padding(.trailing, more == nil ? 14 : 9)
                .frame(maxWidth: width == nil ? nil : .infinity)
                .frame(height: 32).contentShape(Rectangle())
            }
            .buttonStyle(StartPillPressStyle())
            .help("Start Recording")
            .accessibilityLabel("Start Recording")
            if let more {
                label
                Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1, height: 16).accessibilityHidden(true)
                Self.recordingControl(Button(action: more) {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        .frame(width: Self.chevronWidth, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(StartPillPressStyle(pressed: isOpen))
                .help("Off")
                .accessibilityLabel("Recording status")
                .accessibilityValue("Off"))
            } else {
                Self.recordingControl(label)
            }
        }
        .font(.system(size: 12.5, weight: .semibold))
        .lineLimit(1)
        .foregroundStyle(Color.white)
        .frame(width: width)
        .background(Color.accentColor.gradient, in: Capsule())
        .clipShape(Capsule())
        .shadow(color: Color.accentColor.opacity(0.25), radius: 3, y: 1.5)
        .fixedSize()
    }

    /// The pill's one `capture-state` control: the chevron when there is one, else the label. Exactly one
    /// element carries the identifier, as the status capsule does in every other state.
    private static func recordingControl<V: View>(_ control: V) -> some View {
        control.accessibilityIdentifier("capture-state")
    }

    /// The chevron segment (and its divider) beside the label.
    static let chevronWidth: CGFloat = 24

    /// Laid-out width, with or without the chevron, for the toolbar's space budget.
    static func width(more: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let label = 14 + 13 + 6 + ceil(("Start Recording" as NSString).size(withAttributes: [.font: font]).width)
        return more ? label + 9 + 1 + chevronWidth + 1 : label + 14 + 1
    }
}

/// A press (or the open popover) darkens one segment of the Start Recording pill.
private struct StartPillPressStyle: ButtonStyle {
    var pressed = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(Color.black.opacity(configuration.isPressed || pressed ? 0.12 : 0))
    }
}

// MARK: - Clock

/// "now" for the capsule and the popover. Renders and checks pin `\.daydreamNow`; the app ticks every 30 s, on
/// each minute boundary of a timed pause (so `Paused · 12m` never lags) and every second in its last minute.
/// Children read the same instant through `\.daydreamNow`, so the glyph ring and the label agree.
/// `ticks: false` runs no timeline at all (the content doesn't read the clock): it draws once per state change.
struct StatusClock<Content: View>: View {
    let until: Date?
    let ticks: Bool
    let content: (Date) -> Content
    @Environment(\.daydreamNow) private var fixedNow

    init(until: Date?, ticks: Bool = true, @ViewBuilder content: @escaping (Date) -> Content) {
        self.until = until; self.ticks = ticks; self.content = content
    }

    var body: some View {
        if let fixedNow {
            content(fixedNow)
        } else if !ticks {
            content(Date())
        } else {
            TimelineView(CountdownSchedule(until: until)) { context in
                content(context.date).environment(\.daydreamNow, context.date)
            }
        }
    }
}

/// 30-second ticks, plus each minute boundary before `until` and 1-second ticks in its last minute.
struct CountdownSchedule: TimelineSchedule {
    let until: Date?

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = startDate
        return AnyIterator {
            guard let current = next else { return nil }
            next = Self.tick(after: current, until: until)
            return current
        }
    }

    static func tick(after t: Date, until: Date?) -> Date {
        let regular = t.addingTimeInterval(30)
        guard let until else { return regular }
        let left = until.timeIntervalSince(t)
        if left <= 0 { return regular }
        if left <= 60 { return t.addingTimeInterval(1) }
        // Minutes left read `ceil(left / 60)`, so the label changes at `until - 60k`.
        let boundary = until.addingTimeInterval(-60 * (ceil(left / 60) - 1))
        return boundary > t ? min(regular, boundary) : t.addingTimeInterval(1)
    }
}
