import SwiftUI
import AppKit

/// Shared visual language of the "Set up DayDream" onboarding. The main window,
/// settings detail pages and onboarding draw from these tokens so the app reads
/// as one system. Colors alias `DaydreamOnboardingTheme` rather than copying it.
enum DaydreamStyle {
    static let window = DaydreamOnboardingTheme.window
    static let card = DaydreamOnboardingTheme.card
    static let selected = DaydreamOnboardingTheme.selected
    static let cardStroke = Color.primary.opacity(0.06)
    static let fieldFill = Color.primary.opacity(0.035)
    static let fieldStroke = Color.primary.opacity(0.07)
    static let pillFill = Color.primary.opacity(0.08)
    static let pillPressed = Color.primary.opacity(0.16)
    static let recording = Color.red
    static let attention = Color.orange

    static let cardRadius: CGFloat = 18
    static let tileRadius: CGFloat = 11
    static let fieldRadius: CGFloat = 8

    // Redesign tokens (spec §1). Additive: the values above stay as the legacy views draw them.

    /// Raised controls and segments above a card: white / white .24.
    static let raised = dynamic(light: NSColor.white, dark: NSColor(white: 0.24, alpha: 1))
    /// Recall panel body: white / white .155.
    static let panelFill = dynamic(light: NSColor.white, dark: NSColor(white: 0.155, alpha: 1))
    /// Selected row inside the Recall panel.
    static let panelSelection = dynamic(light: NSColor(srgbRed: 0.855, green: 0.918, blue: 0.996, alpha: 1),
                                        dark: NSColor(srgbRed: 0.15, green: 0.24, blue: 0.37, alpha: 1))
    /// Flat popover fill, for inner surfaces only (the popover itself uses system material).
    static let popover = dynamic(light: NSColor(srgbRed: 0.988, green: 0.99, blue: 0.994, alpha: 1),
                                 dark: NSColor(srgbRed: 0.285, green: 0.285, blue: 0.30, alpha: 1))
    /// Inner wells and tiles inside a card.
    static let wellFill = Color.primary.opacity(0.035)
    /// Row separators and well outlines, drawn at `hairlineWidth`.
    static let hairline = Color.primary.opacity(0.06)
    static let hairlineWidth: CGFloat = 0.5
    /// Scrim behind a summoned panel: black .10 / .42.
    static let dim = dynamic(light: NSColor.black.withAlphaComponent(0.10), dark: NSColor.black.withAlphaComponent(0.42))
    /// Paused state, including the live pause on the ribbon.
    static let paused = Color(nsColor: .systemIndigo)
    /// Anything the model wrote, including "Summary pending". Dream violet.
    static let model = Color(.sRGB, red: 0.72, green: 0.42, blue: 0.96, opacity: 1)
    /// Summarize Now's sweep over the quotes (summary-v2 `--sweep`): a soft violet light, #c9b4f5 / #e4d8ff.
    static let sweep = dynamic(light: NSColor(srgbRed: 0xc9/255.0, green: 0xb4/255.0, blue: 0xf5/255.0, alpha: 1),
                               dark: NSColor(srgbRed: 0xe4/255.0, green: 0xd8/255.0, blue: 0xff/255.0, alpha: 1))
    /// Search match background (always paired with an underline or weight, never colour alone).
    static let highlight = dynamic(light: NSColor(srgbRed: 1, green: 0.84, blue: 0.24, alpha: 0.5),
                                   dark: NSColor(srgbRed: 1, green: 0.80, blue: 0.24, alpha: 0.16))
    /// Search match text: label colour / warm yellow.
    static let highlightText = dynamic(light: NSColor.labelColor, dark: NSColor(srgbRed: 1, green: 0.86, blue: 0.42, alpha: 1))

    /// Inner wells, stat cells, the actions menu and inset cards. Spec §1.4 says 12; `tileRadius`
    /// stays 11 until the legacy views that draw with it are retired.
    static let wellRadius: CGFloat = 12
    /// Popovers and floating panels.
    static let panelRadius: CGFloat = 16
    /// Accent outline of an expanded row card (α .55); keyboard selection has no outline.
    static let expandedStroke: CGFloat = 1.5

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}

/// Type scale used across the app. Titles follow the onboarding cards; body text
/// is never smaller than 13pt, supporting text never smaller than 11pt.
enum DaydreamType {
    static let pageTitle = Font.system(size: 26, weight: .bold)
    static let sectionTitle = Font.system(size: 17, weight: .semibold)
    static let itemTitle = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let detail = Font.system(size: 12)
    static let meta = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11)
    /// Row title in lists and menus.
    static let rowTitle = Font.system(size: 13, weight: .semibold)
    /// Stat values.
    static let metric = Font.system(size: 17, weight: .semibold, design: .rounded)
    /// Shortcut keycaps.
    static let keycap = Font.system(size: 11, weight: .medium, design: .rounded)
}

extension View {
    /// Onboarding card: soft fill, hairline stroke, gentle shadow.
    func daydreamCard(radius: CGFloat = DaydreamStyle.cardRadius, fill: Color = DaydreamStyle.card, shadow: Bool = true) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(DaydreamStyle.cardStroke, lineWidth: 1))
            .shadow(color: .black.opacity(shadow ? 0.07 : 0), radius: 7, y: 3)
    }

    /// Onboarding search/input field chrome.
    func daydreamField(radius: CGFloat = DaydreamStyle.fieldRadius, focused: Bool = false) -> some View {
        background(DaydreamStyle.fieldFill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(focused ? Color.accentColor : DaydreamStyle.fieldStroke, lineWidth: focused ? 2 : 1))
    }
}

/// Secondary action: grey capsule, as on the permission cards' "Open System Settings".
struct DaydreamPillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: prominent ? .medium : .regular))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 13).frame(minHeight: 28)
            .background(prominent ? Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1)
                        : configuration.isPressed ? DaydreamStyle.pillPressed : DaydreamStyle.pillFill, in: Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
    }
}

/// Round header control, e.g. the Settings gear beside search.
struct DaydreamCircleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var size: CGFloat = 38
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.secondary).frame(width: size, height: size)
            .background(configuration.isPressed ? DaydreamStyle.selected : DaydreamStyle.card, in: Circle())
            .overlay(Circle().stroke(DaydreamStyle.cardStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.07), radius: 5, y: 2)
            .contentShape(Circle())
            .opacity(enabled ? 1 : 0.45)
    }
}

/// Fallback identity for sources without an installed app bundle: a lettered
/// tile in the onboarding icon style instead of an empty dashed square.
struct DaydreamMonogram: View {
    let name: String
    var size: CGFloat = 32
    private static let palette: [Color] = [.blue, .teal, .indigo, .purple, .pink, .orange, .green, .cyan]
    private var letter: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "?"
    }
    private var color: Color {
        // Stable across launches (String.hashValue is seeded per process).
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return Self.palette[sum % Self.palette.count]
    }
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24).fill(color.gradient)
            .overlay(Text(letter).font(.system(size: size * 0.5, weight: .semibold, design: .rounded)).foregroundStyle(.white))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
