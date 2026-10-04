import SwiftUI
import AppKit

// Header-A popover (spec §5.2, plan §5 A3; lifted from proto/status/header.swift `PopoverA`, `PopHeader`,
// `QuickLinks` and `TrustFooter`), composed from the kit: `RecordingStateHeader`, `RecordingControls`, `LinkRow`,
// `TrustFooter`. Value-driven: the toolbar hosts it with the live presentation.
// Top to bottom (declutter): state badge, title and detail; the orange attention line (an operational issue the
// state doesn't already say; one click that fixes it, as in the menu bar panel); the recording controls; a Permissions row only when a permission reads as missing
// while the state isn't Needs Permission (then it is the popover's only sign that Start can't work); the short
// trust footer. Today's ribbon and count live on the day card, and the Settings gear sits beside the capsule.
// Opening it changes nothing; every capture change is one explicit press.

private struct StatusPreviewKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True in a synthetic preview (MemoryShell `demo`): nothing there is a real permission read, so the popover
    /// shows no Permissions row.
    public var daydreamStatusPreview: Bool {
        get { self[StatusPreviewKey.self] }
        set { self[StatusPreviewKey.self] = newValue }
    }
}

// MARK: - Popover

public struct StatusPopover: View {
    let state: RecordingState
    let presentation: CapturePresentation
    let actions: CaptureActions
    let now: Date
    let calendar: Calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.daydreamStatusPreview) private var preview

    public static let width: CGFloat = 364

    /// - `state`: what the popover draws (normally `presentation.state`); `presentation` supplies `canResume`,
    ///   `canStop`, the permission reads and the issue.
    public init(state: RecordingState, presentation: CapturePresentation, actions: CaptureActions, now: Date,
                calendar: Calendar = .current) {
        self.state = state; self.presentation = presentation; self.actions = actions; self.now = now; self.calendar = calendar
    }

    private var zone: TimeZone { calendar.timeZone }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                RecordingStateHeader(state: state, style: .popover, timeZone: zone)
                if let line = state.attentionLine(issue: presentation.issue, now: now, timeZone: zone) {
                    Self.attentionButton(line, actions: actions).transition(StatusMotion.fade)
                }
                // One slot: the old and new controls cross-fade over each other instead of stacking.
                ZStack(alignment: .topLeading) {
                    RecordingControls(state: state, actions: actions, style: .popover, canStart: presentation.canResume,
                                      canStop: presentation.canStop, permissions: presentation.permissions)
                        .id(state.kind)
                        .transition(StatusMotion.fade)
                }
            }
            .padding(14)
            if !preview, let missing = Self.missingPermissions(state: state, reads: presentation.permissions) {
                PopoverRule().padding(.horizontal, 14)
                LinkRow("Permissions", area: .permissions, action: { actions.openSettingsSection("Permissions") }) {
                    QuietStatus(missing, symbol: "exclamationmark.circle.fill", tint: KitPalette.orange)
                }
                .padding(.horizontal, 6).padding(.vertical, 6)
                .transition(StatusMotion.fade)
            }
            PopoverRule()
            TrustFooter(short: true).padding(.horizontal, 14).frame(height: 36)
        }
        .frame(width: Self.width, alignment: .leading)
        .environment(\.daydreamNow, now)
        // Layout follows with a spring; under Reduce Motion it changes at once and only the fades run.
        .animation(StatusMotion.layout(reduceMotion: reduceMotion), value: state.kind)
    }

    /// The orange line as the menu bar panel draws it: one click that does what fixes it (`MenuBarMenu.attentionAction`),
    /// ending in Try Again in the accent colour, or in a chevron to the Settings page. The popover's actions close it first.
    static func attentionButton(_ line: String, actions: CaptureActions) -> some View {
        let action = MenuBarMenu.attentionAction(line)
        let hint: String
        switch action {
        case .retry: hint = MenuBarMenu.retryHint
        case .open(let section): hint = MenuBarMenu.settingsHint(section)
        }
        return Button {
            switch action {
            case .retry: actions.retryIssue()
            case .open(let section): actions.openSettingsSection(section)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                attention(line)
                Spacer(minLength: 8)
                if action == .retry {
                    Text(RecordingCopy.retryTitle).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(hint)
        .accessibilityIdentifier("popover-attention")
    }

    /// Orange attention line for an operational issue (copy from `RecordingCopy.issue`).
    static func attention(_ line: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .semibold))
            Text(line).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(KitPalette.orange)
        .accessibilityElement(children: .combine)
    }

    // MARK: Permissions row

    /// The Permissions row's orange text (`Input Monitoring needed`, `Both needed`), or nil: no row. Needs
    /// Permission says it in the header and offers Open System Settings, so it gets no row; neither do unread or
    /// granted permissions.
    public static func missingPermissions(state: RecordingState, reads: PermissionSnapshot?) -> String? {
        guard state.kind != .needsPermission, let text = permissionsText(reads), text.missing else { return nil }
        return text.title
    }

    /// Permissions copy. nil: a permission hasn't been read.
    public static func permissionsText(_ reads: PermissionSnapshot?) -> (title: String, missing: Bool)? {
        guard let reads else { return nil }
        let missing = reads.missing
        if missing.count == 2 { return ("Both needed", true) }
        if let kind = missing.first { return (kind.title + " needed", true) }
        return reads.allGranted == true ? ("Both allowed", false) : nil
    }
}

/// A one-device-pixel rule (KitPalette.rule). A 0.5 pt rectangle is snapped to the pixel grid, and at a
/// half-point origin on a 1x display it rounds to nothing; one pixel at the display's scale always draws.
struct PopoverRule: View {
    @Environment(\.displayScale) private var scale
    var body: some View {
        Rectangle().fill(KitPalette.rule).frame(height: 1 / max(1, scale)).accessibilityHidden(true)
    }
}

// MARK: - Live host

/// The popover as the toolbar shows it, with a live clock.
struct StatusPopoverHost: View {
    @ObservedObject var browser: ActivityBrowser
    let presentation: CapturePresentation
    let actions: CaptureActions

    var body: some View {
        StatusClock(until: presentation.state.pauseUntil) { now in
            StatusPopover(state: presentation.state, presentation: presentation, actions: actions, now: now, calendar: browser.calendar)
        }
    }
}
