import AppKit
import SwiftUI
import CoreGraphics

// rel-019: the recording-off reminder's one surface (the rules: RecordingReminder.swift). A small one-line panel just
// under DayDream's menu bar item: "Recording is off." with Start Recording and ✕. It asks for nothing: no notification
// permission (a person who never allowed DayDream's notifications, or has Focus on, still sees it), it never activates
// DayDream or takes the keyboard from the app in front, and it stays until the person clicks one of its two buttons or
// recording starts some other way. The menu bar item itself already draws the Off state.

/// What the reminder needs from macOS, injectable so the checks run without it: the idle read, the clock, the saved day
/// and the panel.
struct RecordingReminderSystem {
    /// The app model reads once a minute (its maintenance timer). The checks call `reminderTick` themselves.
    var drives: Bool
    /// Seconds since the last keyboard or mouse input in this login session (any app). A read that asks for nothing.
    var idleSeconds: () -> TimeInterval
    var now: () -> Date
    /// Where the day it last showed is saved (nil: nowhere).
    var defaults: UserDefaults?
    /// Shows the panel with its two actions: Start Recording, and ✕.
    var show: @MainActor (_ start: @escaping () -> Void, _ dismiss: @escaping () -> Void) -> Void
    var hide: @MainActor () -> Void

    /// Never reads or shows anything (the checks, previews, and a process that is not the DayDream app bundle).
    static let inert = RecordingReminderSystem(drives: false, idleSeconds: { .infinity }, now: { Date() }, defaults: nil,
                                               show: { _, _ in }, hide: {})

    /// The app's. Inert unless this process is an .app bundle with a bundle identifier, like the stop notice.
    static var live: RecordingReminderSystem {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return .inert }
        return RecordingReminderSystem(
            drives: true,
            idleSeconds: { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) },
            now: { Date() }, defaults: .standard,
            show: { start, dismiss in RecordingReminderPanel.shared.show(start: start, dismiss: dismiss) },
            hide: { RecordingReminderPanel.shared.hide() })
    }
}

/// rel-019 final: hands the reminder the menu bar's own routes (`reminderRoutes`), so a Start that must open setup
/// opens it even when the main window (which sets `openSetupWindow`) never showed (a quiet login launch). On the menu bar
/// item's label, which exists from launch; the label itself is unchanged.
struct RecordingReminderRoutes: ViewModifier {
    let model: MemoryViewModel
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear { [model, openWindow] in
            if model.reminderRoutes == nil { model.reminderRoutes = DaydreamMenuBarRoutes(openWindow: { openWindow(id: $0) }) }
        }
    }
}

/// The panel's words.
enum RecordingReminderCopy {
    static let line = "Recording is off."
    static let start = "Start Recording"
    static let dismiss = "Dismiss"
}

/// Where the panel goes: centered under the menu bar item, inside the screen's visible frame. Pure, for the checks.
enum RecordingReminderPlacement {
    struct WindowInfo: Equatable { var frame: CGRect; var level: Int; var visible: Bool }
    static let gap: CGFloat = 6
    static let margin: CGFloat = 8

    /// The menu bar item's frame among the app's windows: a visible window no taller than a menu bar, flush with the top
    /// of a screen (the status item's own window; public AppKit only, no private class names). One at the status bar
    /// level or above wins. nil when none is found (the panel then sits at the top right).
    static func statusItemFrame(_ windows: [WindowInfo], screens: [CGRect], statusLevel: Int = Int(CGWindowLevelForKey(.statusWindow))) -> CGRect? {
        let strip = windows.filter { w in
            w.visible && w.frame.height > 0 && w.frame.height <= 40 && w.frame.width > 0 && w.frame.width <= 400
                && screens.contains { abs($0.maxY - w.frame.maxY) <= 1 && $0.intersects(w.frame) }
        }
        return (strip.first { $0.level >= statusLevel } ?? strip.first)?.frame
    }

    /// The panel's origin for `size`: under `item` (centered on it), else at the top right of `visible`; always inside it.
    static func origin(size: CGSize, item: CGRect?, visible: CGRect) -> CGPoint {
        let top = min(item?.minY ?? visible.maxY, visible.maxY)
        let wanted = item.map { $0.midX - size.width / 2 } ?? (visible.maxX - margin - size.width)
        let x = max(visible.minX + margin, min(wanted, visible.maxX - margin - size.width))
        return CGPoint(x: x.rounded(), y: (top - gap - size.height).rounded())
    }
}

/// The panel's content: one line, Start Recording, ✕.
struct RecordingReminderView: View {
    let start: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Text(RecordingReminderCopy.line)
                .font(.system(size: 13))
                .fixedSize()
            Button(RecordingReminderCopy.start, action: start)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .help(RecordingReminderCopy.dismiss)
            .accessibilityLabel(RecordingReminderCopy.dismiss)
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 8)
        .fixedSize()
        .accessibilityElement(children: .contain)
    }
}

/// The panel itself: borderless, never activates DayDream, on every Space, above other windows like a menu.
@MainActor final class RecordingReminderPanel {
    static let shared = RecordingReminderPanel()
    private var panel: NSPanel?

    func show(start: @escaping () -> Void, dismiss: @escaping () -> Void) {
        hide()
        let host = FirstClickHostingView(rootView: RecordingReminderView(start: start, dismiss: dismiss))
        let size = host.fittingSize
        let panel = ReminderPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.title = RecordingReminderCopy.line
        // The menu's own material, with the menu's rounded corners.
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        panel.contentView = effect
        let screens = NSScreen.screens
        let item = RecordingReminderPlacement.statusItemFrame(
            NSApp.windows.filter { $0 !== panel }.map {
                RecordingReminderPlacement.WindowInfo(frame: $0.frame, level: $0.level.rawValue, visible: $0.isVisible)
            },
            screens: screens.map(\.frame))
        let screen = item.flatMap { frame in screens.first { $0.frame.intersects(frame) } } ?? NSScreen.main ?? screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(RecordingReminderPlacement.origin(size: size, item: item, visible: visible))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        guard let old = panel else { return }
        panel = nil
        old.orderOut(nil)
        // rel-019 final: released on the next main-queue turn, never inside its own button's action (Start Recording and
        // ✕ both end here while the click is still being handled). Only this panel is held: a show() in between keeps
        // its new one.
        DispatchQueue.main.async { withExtendedLifetime(old) {} }
    }

    /// Takes clicks for its buttons without making DayDream the active app.
    private final class ReminderPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
    /// The first click on a button acts at once (one click), even while another app is active.
    private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
