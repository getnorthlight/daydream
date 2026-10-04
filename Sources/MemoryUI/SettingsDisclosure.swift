import SwiftUI

// Owner decision 2026-10-03 (clarifying faec835): Settings › Apps to remember keeps its scrolling app list in sight. The two
// switch rows under it, "Web pages in Chrome" and "Remember what you type", are each the title and the switch; a click on
// the row (not the switch) opens that row's own settings under it, and another click closes them. Problems that need a
// click (Chrome access, a locked Keychain, a lost key) never hide behind a closed row.

/// The open and close motion of a Settings row's details.
public enum SettingsDisclosure {
    /// The height: a critically damped spring (no overshoot, no bounce; a click mid-way turns it around from where it
    /// is). None with Reduce Motion: the details appear and go at once.
    public static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 1)
    }

    /// The details fade in just after the height starts to grow, and out faster than it shrinks, so nothing shows
    /// half-cut at the moving edge. Nothing with Reduce Motion.
    public static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.06)),
                                               removal: .opacity.animation(.easeIn(duration: 0.12)))
    }

    public static func accessibilityValue(open: Bool) -> String { open ? "Expanded" : "Collapsed" }
    public static func accessibilityHint(open: Bool) -> String { open ? "Hides the settings" : "Shows the settings" }
}

/// Which Settings rows are open, for this run of DayDream only: never saved, so every launch starts closed.
@MainActor public final class SettingsExpansion: ObservableObject {
    public enum Row: String, CaseIterable, Sendable { case chromePages, typing }

    /// The app's one memory of open rows (Settings closes and opens again with the rows as they were).
    public static let session = SettingsExpansion()

    @Published public private(set) var open: Set<Row> = []

    public init() {}

    public func isOpen(_ row: Row) -> Bool { open.contains(row) }

    public func set(_ row: Row, open now: Bool) {
        if now { open.insert(row) } else { open.remove(row) }
    }

    public func binding(_ row: Row) -> Binding<Bool> {
        Binding(get: { self.isOpen(row) }, set: { self.set(row, open: $0) })
    }
}

/// The clickable part of a Settings switch row: its icon and title (everything but the switch) and a small chevron.
/// VoiceOver reads the label's own text, then Expanded or Collapsed. With no `open` binding, or nothing to show
/// (`hasDetails` false), it is the plain label and does nothing on a click.
struct SettingsDisclosureLabel<Label: View>: View {
    let open: Binding<Bool>?
    let hasDetails: Bool
    let label: Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(open: Binding<Bool>?, hasDetails: Bool, @ViewBuilder label: () -> Label) {
        self.open = open; self.hasDetails = hasDetails; self.label = label()
    }

    var body: some View {
        if let open, hasDetails {
            Button {
                withAnimation(SettingsDisclosure.animation(reduceMotion: reduceMotion)) { open.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 8) {
                    label
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(SettingsDisclosure.accessibilityValue(open: open.wrappedValue))
            .accessibilityHint(SettingsDisclosure.accessibilityHint(open: open.wrappedValue))
        } else {
            label
        }
    }
}
