import SwiftUI
import AppKit

/// chromeask-1005 (owner 10/5): one calm line wherever DayDream says Chrome pages aren't being saved (the menu bar, the
/// Settings status, the toolbar's status popover and the one-time reminder), always with the same one click. It shows
/// only after setup, while recording with Web pages in Chrome on, Google Chrome not excluded and its access off.
/// Refused, the click is Ask again (macOS's question comes back); never asked, Fix (setup's Chrome row).
/// Values only; the app decides what the click does (`CaptureActions.fixChrome`).
public enum ChromeAccessNotice {
    public static let line = "Chrome pages aren't being saved."
    /// Never asked yet: opens setup's Chrome row, whose Allow is where macOS asks.
    public static let fixTitle = "Fix"
    /// Refused (owner 10/5): DayDream clears its own Automation answer and macOS asks again, now.
    public static let askAgainTitle = "Ask again"
    /// VoiceOver's hints.
    public static let fixHint = "Opens the setting that lets DayDream read Chrome's page"
    public static let askAgainHint = "macOS asks again whether DayDream may read Chrome's page"
    public static let symbol = "globe"
    /// The guide beside System Settings when macOS can't ask again (owner 10/5): one line, then a check once it's on.
    public static let guideLine = "Turn this on."
    public static let guideDone = "Chrome pages are on."

    public static func title(askAgain: Bool) -> String { askAgain ? askAgainTitle : fixTitle }
    public static func hint(askAgain: Bool) -> String { askAgain ? askAgainHint : fixHint }
}

/// The one-time reminder's content: Chrome's icon, the line, Ask again and a close button. The app hosts it in a
/// non-activating panel under the menu bar (`ChromeReminderPanel`); the checks render it directly.
public struct ChromeReminderView: View {
    public static let width: CGFloat = 372
    let chromeIcon: NSImage?
    let title: String
    let fix: () -> Void
    let close: () -> Void

    public init(chromeIcon: NSImage?, title: String = ChromeAccessNotice.askAgainTitle, fix: @escaping () -> Void, close: @escaping () -> Void) {
        self.chromeIcon = chromeIcon; self.title = title; self.fix = fix; self.close = close
    }

    /// Google Chrome's own icon (Launch Services; nothing opens), or nil.
    public static func chromeIcon() -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome").map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    public var body: some View {
        HStack(spacing: 10) {
            Group {
                if let chromeIcon { Image(nsImage: chromeIcon).resizable().interpolation(.high) }
                else { Image(systemName: ChromeAccessNotice.symbol).resizable().scaledToFit().foregroundStyle(.secondary) }
            }
            .frame(width: 22, height: 22).accessibilityHidden(true)
            Text(ChromeAccessNotice.line).font(.system(size: 13)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(title, action: fix)
                .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.accentColor)
                .fixedSize()
                .accessibilityHint(ChromeAccessNotice.hint(askAgain: title == ChromeAccessNotice.askAgainTitle))
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Close")
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 10)
        .frame(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chrome-reminder")
    }
}

/// The fallback guide (owner 10/5), only when macOS can't ask again (the reset failed, or macOS answered with no
/// question: a managed Mac, an older macOS). A small card beside System Settings' Automation pane: DayDream's row with
/// Google Chrome's switch flipping on, and "Turn this on."; once it is on, a check, then it closes by itself. The app
/// hosts it in a floating panel (`ChromeGuidePanel`); the checks render each step with the switch held still.
public struct ChromeGuideView: View {
    public enum Step: Equatable, Sendable { case turnOn, done }
    public static let width: CGFloat = 264
    let step: Step
    let chromeIcon: NSImage?
    let appIcon: NSImage?
    /// nil: the switch flips on and off by itself. A value holds it (the checks' renders).
    let held: Bool?
    let close: () -> Void
    @State private var on = false

    public init(step: Step, chromeIcon: NSImage?, appIcon: NSImage?, held: Bool? = nil, close: @escaping () -> Void) {
        self.step = step; self.chromeIcon = chromeIcon; self.appIcon = appIcon; self.held = held; self.close = close
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if step == .done {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemGreen)).accessibilityHidden(true)
                }
                Text(step == .done ? ChromeAccessNotice.guideDone : ChromeAccessNotice.guideLine)
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Close")
            }
            ChromeAutomationRowDrawing(chromeIcon: chromeIcon, appIcon: appIcon, on: step == .done ? true : (held ?? on),
                                       width: Self.width - 28, ringed: step == .turnOn)
        }
        .padding(14)
        .frame(width: Self.width)
        .task(id: step) {
            guard held == nil, step == .turnOn else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                withAnimation(.easeInOut(duration: 0.25)) { on.toggle() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(step == .done ? ChromeAccessNotice.guideDone
                            : "In System Settings, under DayDream, turn on Google Chrome.")
        .accessibilityIdentifier("chrome-guide")
    }
}

/// System Settings › Privacy & Security › Automation, drawn: DayDream, and under it Google Chrome with its switch,
/// ringed (the switch to turn on). Drawn rather than pictured so it stays sharp and follows light and dark.
public struct ChromeAutomationRowDrawing: View {
    let chromeIcon: NSImage?
    let appIcon: NSImage?
    let on: Bool
    let width: CGFloat
    /// The switch to turn on is ringed (not once it's done).
    let ringed: Bool
    public init(chromeIcon: NSImage?, appIcon: NSImage?, on: Bool, width: CGFloat, ringed: Bool = true) {
        self.chromeIcon = chromeIcon; self.appIcon = appIcon; self.on = on; self.width = width; self.ringed = ringed
    }
    private static let panel = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.21, alpha: 1) : NSColor(white: 0.97, alpha: 1)
    })
    private func icon(_ image: NSImage?, _ fallback: String, _ size: CGFloat) -> some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high) }
            else { Image(systemName: fallback).resizable().scaledToFit().foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size)
    }

    public var body: some View {
        let s = width / 236
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8 * s) {
                icon(appIcon, "app.fill", 20 * s)
                Text("DayDream").font(.system(size: 12 * s, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12 * s).frame(height: 34 * s)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).padding(.leading, 40 * s)
            HStack(spacing: 8 * s) {
                icon(chromeIcon, "globe", 17 * s)
                Text("Google Chrome").font(.system(size: 11.5 * s)).lineLimit(1).fixedSize()
                Spacer(minLength: 6 * s)
                // The ring sits inside the switch's own frame (nothing drawn outside it).
                ZStack {
                    RoundedRectangle(cornerRadius: 10 * s).strokeBorder(Color.accentColor.opacity(ringed ? 0.45 : 0), lineWidth: 2)
                        .frame(width: 38 * s, height: 25 * s)
                    Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.16)).frame(width: 30 * s, height: 17 * s)
                        .overlay(alignment: on ? .trailing : .leading) {
                            Circle().fill(Color.white).frame(width: 15 * s, height: 15 * s).padding(.horizontal, 1 * s)
                                .shadow(color: .black.opacity(0.25), radius: 0.6, y: 0.5)
                        }
                }
                .frame(width: 40 * s, height: 27 * s)
            }
            .padding(.leading, 40 * s).padding(.trailing, 10 * s).frame(height: 36 * s)
        }
        .frame(width: width)
        .background(Self.panel, in: RoundedRectangle(cornerRadius: 10 * s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10 * s, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
