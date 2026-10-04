import SwiftUI
import AppKit

// DayDream visual kit: small shared pieces (spec §10.5, §10.7, §10.8, §10.12, §10.14).
// Public, value-driven and macOS 13 safe. Lifted from the prototypes (`home/common.swift`,
// `find/common.swift`, `status/common.swift`, `settings/shared.swift`) with fixtures removed.
// Nothing here reads a store, the clock or the system; callers pass values.

// MARK: - Kit palette (module-internal)

/// Colours the kit draws with beyond `DaydreamStyle`. Semantic colours stay exclusive (spec §1.2):
/// red is Recording only, indigo is Paused, orange is permissions, violet (`model`) is what the model wrote.
enum KitPalette {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static let red = Color(nsColor: .systemRed)
    static let orange = Color(nsColor: .systemOrange)
    static let green = Color(nsColor: .systemGreen)
    static let redHalo = dynamic(NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 0.14), NSColor(srgbRed: 1, green: 0.42, blue: 0.40, alpha: 0.26))
    static let dimOrange = dynamic(NSColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 0.10), NSColor(srgbRed: 1, green: 0.72, blue: 0.36, alpha: 0.09))
    static let warnGlow = LinearGradient(
        colors: [dynamic(NSColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 0.14), NSColor(srgbRed: 1, green: 0.66, blue: 0.25, alpha: 0.16)),
                 dynamic(NSColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 0.03), NSColor(srgbRed: 1, green: 0.66, blue: 0.25, alpha: 0))],
        startPoint: .top, endPoint: .bottom)
    /// Menu bar card tiles and their hairline.
    static let tile = dynamic(NSColor(white: 1, alpha: 0.86), NSColor(white: 1, alpha: 0.09))
    static let tileStroke = dynamic(NSColor(white: 0, alpha: 0.05), NSColor(white: 1, alpha: 0.09))
    /// Inset well inside a tile (the permission rows).
    static let inset = dynamic(NSColor(white: 1, alpha: 1), NSColor(white: 1, alpha: 0.07))
    static let chip = Color.primary.opacity(0.07)
    /// The raised segment of `Segmented`.
    static let knob = dynamic(.white, NSColor(white: 1, alpha: 0.2))
    static let menuFill = dynamic(.white, NSColor(white: 0.2, alpha: 1))
    static let menuStroke = dynamic(NSColor(white: 0, alpha: 0.12), NSColor(white: 1, alpha: 0.16))
    static let panelStroke = dynamic(NSColor(white: 0, alpha: 0.10), NSColor(white: 1, alpha: 0.14))
    static let tooltipFill = dynamic(NSColor(srgbRed: 0.988, green: 0.99, blue: 0.994, alpha: 1), NSColor(srgbRed: 0.285, green: 0.285, blue: 0.30, alpha: 1))
    static let tooltipStroke = dynamic(NSColor(white: 0, alpha: 0.13), NSColor(white: 1, alpha: 0.17))
    static let tooltipShadow = dynamic(NSColor(white: 0, alpha: 0.24), NSColor(white: 0, alpha: 0.6))
    /// Settings-style row hairline.
    static let rule = Color.primary.opacity(0.09)

    // DayDream gradient (blue → violet → peach, from the app icon) for model-written surfaces.
    static let dreamBlue = Color(.sRGB, red: 0.36, green: 0.48, blue: 1.0, opacity: 1)
    static let dreamViolet = DaydreamStyle.model
    static let dreamPeach = Color(.sRGB, red: 1.0, green: 0.60, blue: 0.44, opacity: 1)
    static var dreamGradient: LinearGradient {
        LinearGradient(colors: [dreamBlue, dreamViolet, dreamPeach], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension View {
    /// Menu bar card tile (spec §5.3: radius 14, hairline).
    func kitTile(_ radius: CGFloat = 14, fill: Color = KitPalette.tile) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(KitPalette.tileStroke, lineWidth: 0.5))
    }
}

/// Capsule button used by the kit's controls: one blue prominent style, one grey secondary style.
/// `RecordingControls` guarantees at most one prominent button per surface.
struct KitCapsuleButtonStyle: ButtonStyle {
    var prominent = false
    var height: CGFloat = 28
    var expand = false
    /// Horizontal padding; nil is the kit's 14 (prominent) / 13. The menu bar card's controls use 10 (W2-27).
    var horizontalPadding: CGFloat? = nil
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: prominent ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, horizontalPadding ?? (prominent ? 14 : 13))
            .frame(maxWidth: expand ? .infinity : nil)
            .frame(height: height)
            .background(prominent ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(KitPalette.chip), in: Capsule())
            .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.12 : 0)))
            .shadow(color: prominent && enabled ? Color.accentColor.opacity(0.25) : .clear, radius: 3, y: 1.5)
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
    }
}

/// Plain row button: full-width hit area, a hover/press fill, no system chrome.
struct KitRowButtonStyle: ButtonStyle {
    var radius: CGFloat = 8
    var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(Color.primary.opacity(configuration.isPressed ? 0.10 : hovered ? 0.06 : 0),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Keycaps and key hints (spec §10.8)

/// One shortcut cap, e.g. `Keycap("⌘K")`. Hidden from VoiceOver: shortcuts are exposed by the menus.
public struct Keycap: View {
    let keys: String
    public init(_ keys: String) { self.keys = keys }
    public var body: some View {
        Text(keys)
            .font(DaydreamType.keycap)
            .foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .frame(minWidth: 17)
            .background(DaydreamStyle.pillFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(DaydreamStyle.hairline, lineWidth: DaydreamStyle.hairlineWidth))
            .accessibilityHidden(true)
    }
}

/// A label followed by its keycaps: `KeyHint("Change day", "⌘[", "⌘]")`.
public struct KeyHint: View {
    public let label: String
    public let keys: [String]
    public init(_ label: String, _ keys: String...) { self.label = label; self.keys = keys }
    public init(_ label: String, keys: [String]) { self.label = label; self.keys = keys }
    public var body: some View {
        HStack(spacing: 6) {
            Text(label).font(DaydreamType.detail).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            HStack(spacing: 3) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in Keycap(key) }
            }
        }
    }
}

/// A 28 pt footer row of key hints (Recall panel, Focus List footer).
public struct KeyHintBar: View {
    let hints: [KeyHint]
    public init(_ hints: [KeyHint]) { self.hints = hints }
    public var body: some View {
        HStack(spacing: 16) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in hint }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }
}

// MARK: - Locality and model chips (spec §10.5, §10.12)

/// Where a summary was written.
public enum Locality: String, CaseIterable, Sendable {
    /// Stored and summarized on this Mac (`local/` generator, and all evidence).
    case local
    /// Summarized with the person's own cloud key.
    case cloudKey

    public var title: String { self == .local ? "On this Mac" : "Cloud" }
    public var symbol: String { self == .local ? "lock.fill" : "key.fill" }
    public var accessibilityLabel: String {
        self == .local ? "Stored and summarized on this Mac" : "Summarized with your cloud key"
    }
    /// What VoiceOver hears for a `.local` chip that stands for where the evidence (windows, pages, actions)
    /// lives, not for a summary: it may be pending, off, or written with a cloud key.
    /// "Kept", not "stays": cloud summaries, when on, send the activity they summarize.
    public static let evidenceAccessibilityLabel = "Kept on this Mac"
}

extension MomentSummaryState {
    /// A ready summary written on this Mac: the one case where a local chip may say "summarized on this Mac".
    var isReadyLocally: Bool {
        if case .ready(_, true) = self { return true }
        return false
    }
}

/// Grey capsule: lock + `On this Mac`, or key + `Cloud` (N17). Replaces LocalBadge, MetaPill and
/// the settings laptop glyph.
public struct OnThisMacChip: View {
    let kind: Locality
    let size: ControlSize
    let evidence: Bool
    /// - `evidence`: the chip says where the recorded evidence is kept, not where a summary was written. It looks
    ///   the same, but VoiceOver hears `Kept on this Mac` instead of the summary's locality.
    public init(_ kind: Locality = .local, size: ControlSize = .regular, evidence: Bool = false) {
        self.kind = kind; self.size = size; self.evidence = evidence
    }
    /// The chip's VoiceOver label: a summary's locality, or (`evidence`, local) where the evidence stays.
    public static func accessibilityLabel(_ kind: Locality, evidence: Bool) -> String {
        evidence && kind == .local ? Locality.evidenceAccessibilityLabel : kind.accessibilityLabel
    }
    private var small: Bool { size == .small || size == .mini }
    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbol).font(.system(size: small ? 8 : 9, weight: .semibold))
            Text(kind.title).font(.system(size: small ? 10.5 : 11, weight: .medium)).lineLimit(1).fixedSize()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, small ? 7 : 8)
        .frame(height: small ? 18 : 20)
        .background(DaydreamStyle.pillFill, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(kind, evidence: evidence))
    }
}

/// The model's mark. Owner (Preview 4): no AI star anywhere, so it draws nothing; kept so callers stay as they are.
public struct ModelMark: View {
    let size: CGFloat
    public init(size: CGFloat = 12) { self.size = size }
    public var body: some View { EmptyView() }
}

// MARK: - Section header (spec §10.7)

/// Section title with an optional glyph, count and trailing detail, over a 0.5 pt rule.
public struct SectionHeader: View {
    let title: String
    let symbol: String?
    let part: DayPart?
    let count: Int?
    let detail: String?

    public init(_ title: String, symbol: String? = nil, count: Int? = nil, detail: String? = nil) {
        self.title = title; self.symbol = symbol; self.part = nil; self.count = count; self.detail = detail
    }
    /// Morning / Afternoon / Evening with its day-part glyph.
    public init(_ part: DayPart, count: Int? = nil, detail: String? = nil) {
        self.title = part.title; self.symbol = nil; self.part = part; self.count = count; self.detail = detail
    }

    public var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                if let part {
                    DayPartGlyph(part, size: 15).frame(width: 22)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary).frame(width: 22)
                }
                Text(title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                if let count {
                    Text(DaydreamFormat.count(count)).font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Rectangle().fill(KitPalette.rule).frame(height: DaydreamStyle.hairlineWidth)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Placeholders and bullets

/// One summary bullet. A bullet the writer marked as interpretation says "Interpretation" in italic
/// secondary; the person's own correction says "Your correction" and is not drawn in model violet.
public struct Bullet: View {
    let text: String
    let interpretation: Bool
    let correction: Bool
    let size: CGFloat

    public init(_ text: String, interpretation: Bool = false, correction: Bool = false, size: CGFloat = 13) {
        self.text = text; self.interpretation = interpretation; self.correction = correction; self.size = size
    }
    public init(_ bullet: MomentBullet, size: CGFloat = 13) {
        self.init(bullet.text, interpretation: bullet.interpretation, correction: bullet.correction, size: size)
    }

    private var marker: String? { correction ? "Your correction" : interpretation ? "Interpretation" : nil }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle().fill(correction ? Color.secondary.opacity(0.7) : DaydreamStyle.model)
                .frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + size * 0.28 }
            label.font(.system(size: size)).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var label: Text {
        let body = Text(text).foregroundColor(.primary.opacity(0.8))
        guard let marker else { return body }
        return body + Text("  " + marker).italic().foregroundColor(.secondary)
    }
}

// MARK: - Glyphs (spec §10.14)

/// Time-of-day glyph with an explicit palette (the multicolour moon is white in light mode).
public struct DayPartGlyph: View {
    let part: DayPart
    let size: CGFloat
    public init(_ part: DayPart, size: CGFloat = 14) { self.part = part; self.size = size }
    public var body: some View {
        Group {
            switch part {
            case .morning:
                Image(systemName: "sunrise.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(Color.orange, Color(.sRGB, red: 1, green: 0.78, blue: 0.1, opacity: 1))
            case .afternoon:
                Image(systemName: "sun.max.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(Color(.sRGB, red: 1, green: 0.72, blue: 0, opacity: 1))
            case .evening:
                Image(systemName: "moon.stars.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(Color.indigo, Color(.sRGB, red: 1, green: 0.78, blue: 0.2, opacity: 1))
            }
        }
        .font(.system(size: size, weight: .medium))
        .accessibilityHidden(true)
    }
}

/// Calendar-style date tile ("TUE" band over "22"), for Today without a time-of-day sun.
public struct CalendarTile: View {
    let weekday: String
    let day: String
    let size: CGFloat
    public init(date: Date, calendar: Calendar, size: CGFloat = 34) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.timeZone = calendar.timeZone
        f.dateFormat = "EEE"
        weekday = f.string(from: date).uppercased()
        day = String(calendar.component(.day, from: date))
        self.size = size
    }
    public var body: some View {
        VStack(spacing: 0) {
            Text(weekday).font(.system(size: size * 0.25, weight: .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: size * 0.32)
                .background(Color(.sRGB, red: 0.98, green: 0.26, blue: 0.27, opacity: 1))
            Text(day).font(.system(size: size * 0.46, weight: .semibold, design: .rounded)).foregroundStyle(Color(white: 0.12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .accessibilityHidden(true)
    }
}

/// Gradient tile with a white glyph, for model-written headlines (summary card).
public struct DreamGlyph: View {
    let size: CGFloat
    let symbol: String
    public init(size: CGFloat = 22, symbol: String = "text.alignleft") { self.size = size; self.symbol = symbol }
    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(KitPalette.dreamGradient)
            .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.52, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
            .shadow(color: KitPalette.dreamViolet.opacity(0.25), radius: 3, y: 1)
            .accessibilityHidden(true)
    }
}

/// Soft aurora wash of radial gradients (renders offscreen, unlike `.blur`). Dark stays cool.
public struct DreamWash: View {
    let intensity: Double
    @Environment(\.colorScheme) private var scheme
    public init(intensity: Double = 1) { self.intensity = intensity }
    public var body: some View {
        let dark = scheme == .dark
        let k = (dark ? 0.26 : 0.20) * intensity
        GeometryReader { g in
            ZStack {
                blob(KitPalette.dreamBlue, g.size.width * 0.62, x: g.size.width * 0.78, y: g.size.height * 0.05, k)
                blob(KitPalette.dreamViolet, g.size.width * 0.50, x: g.size.width * 0.98, y: g.size.height * 0.70, k * (dark ? 0.8 : 0.9))
                if dark {
                    blob(Color(.sRGB, red: 0.30, green: 0.34, blue: 0.95, opacity: 1), g.size.width * 0.42, x: g.size.width * 0.52, y: g.size.height * 1.05, k * 0.55)
                } else {
                    blob(KitPalette.dreamPeach, g.size.width * 0.42, x: g.size.width * 0.55, y: g.size.height * 1.05, k * 0.8)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    private func blob(_ c: Color, _ d: CGFloat, x: CGFloat, y: CGFloat, _ o: Double) -> some View {
        Circle().fill(RadialGradient(colors: [c.opacity(o), c.opacity(0)], center: .center, startRadius: 0, endRadius: max(1, d / 2)))
            .frame(width: max(1, d), height: max(1, d)).position(x: x, y: y)
    }
}

// MARK: - Hatching

/// Diagonal hatch lines for a live pause (and other not-recorded spans).
public struct Hatch: Shape {
    public var spacing: CGFloat
    public init(spacing: CGFloat = 3.2) { self.spacing = spacing }
    public func path(in r: CGRect) -> Path {
        var p = Path()
        guard spacing > 0 else { return p }
        var x = r.minX - r.height
        while x < r.maxX + r.height {
            p.move(to: CGPoint(x: x, y: r.maxY))
            p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += spacing
        }
        return p
    }
}

/// Tinted hatched band with a border. Indigo (`paused`) by default.
public struct HatchBand: View {
    let tint: Color
    let radius: CGFloat
    let strong: Bool
    /// `tint` nil is Paused indigo.
    public init(tint: Color? = nil, radius: CGFloat = 3, strong: Bool = true) {
        self.tint = tint ?? DaydreamStyle.paused; self.radius = radius; self.strong = strong
    }
    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(tint.opacity(strong ? 0.18 : 0.1))
            .overlay(Hatch().stroke(tint.opacity(strong ? 0.75 : 0.45), lineWidth: 1).clipShape(shape))
            .overlay(shape.strokeBorder(tint.opacity(strong ? 0.9 : 0.5), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

// MARK: - Settings accessories (settings/shared.swift)

/// Neutral pill with an optional symbol or image, e.g. "Show in Finder".
public struct IconPill: View {
    let label: String
    let symbol: String?
    let image: NSImage?
    let height: CGFloat
    let prominent: Bool
    public init(_ label: String, symbol: String? = nil, image: NSImage? = nil, height: CGFloat = 26, prominent: Bool = false) {
        self.label = label; self.symbol = symbol; self.image = image; self.height = height; self.prominent = prominent
    }
    public var body: some View {
        HStack(spacing: 6) {
            if let image { Image(nsImage: image).resizable().interpolation(.high).frame(width: height * 0.66, height: height * 0.66) }
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
            Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(prominent ? Color.white : Color.primary)
        .padding(.leading, image == nil ? 12 : 7).padding(.trailing, 12)
        .frame(height: height)
        .background(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(KitPalette.chip), in: Capsule())
        .shadow(color: .black.opacity(prominent ? 0.12 : 0), radius: 2, y: 1)
        .fixedSize()
    }
}

/// Tiny progress ring (for example ready vs pending summaries).
public struct MiniRing: View {
    let progress: Double
    let size: CGFloat
    let tint: Color
    /// `tint` nil is the model violet.
    public init(progress: Double, size: CGFloat = 12, tint: Color? = nil) {
        self.progress = progress; self.size = size; self.tint = tint ?? DaydreamStyle.model
    }
    public var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2)
            Circle().trim(from: 0, to: min(1, max(0, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The one grammar for row accessories: leading glyph + secondary text.
public struct QuietStatus: View {
    let text: String
    let symbol: String
    let tint: Color
    public init(_ text: String, symbol: String, tint: Color = .secondary) { self.text = text; self.symbol = symbol; self.tint = tint }
    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Flow layout (find/common.swift, macOS 13 Layout)

/// Wraps subviews onto lines of `line` points, left to right.
public struct Flow: Layout {
    public var spacing: CGFloat
    public var line: CGFloat
    public init(spacing: CGFloat = 4, line: CGFloat = 22) { self.spacing = spacing; self.line = line }

    private func rows(_ maxW: CGFloat, _ subviews: Subviews) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxW { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, size))
            x += size.width + spacing
        }
        return rows
    }
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 10_000
        let r = rows(width, subviews)
        var used: CGFloat = 0
        for row in r {
            var w: CGFloat = 0
            for item in row { w += item.1.width }
            w += CGFloat(max(0, row.count - 1)) * spacing
            used = max(used, w)
        }
        return CGSize(width: proposal.width ?? used, height: CGFloat(r.count) * line)
    }
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (ri, row) in rows(bounds.width, subviews).enumerated() {
            var x = bounds.minX
            for (i, size) in row {
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + CGFloat(ri) * line + (line - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }
}

// MARK: - Segmented presets (status/common.swift)

/// One segment of `Segmented`: a real button with its own help and VoiceOver label.
public struct SegmentedItem: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let help: String?
    public let accessibilityLabel: String
    public let enabled: Bool
    public init(id: String, title: String, help: String? = nil, accessibilityLabel: String? = nil, enabled: Bool = true) {
        self.id = id; self.title = title; self.help = help; self.accessibilityLabel = accessibilityLabel ?? title; self.enabled = enabled
    }
}

/// One track of buttons with one raised segment (the default). Each segment's width follows its
/// label and the spare width is shared equally (a `Layout` measures the labels), so a long label
/// never touches the edge. Tapping a segment calls `action` once with its id; nothing is selected.
public struct Segmented: View {
    let items: [SegmentedItem]
    let highlighted: String?
    let height: CGFloat
    let action: (String) -> Void

    public init(_ items: [SegmentedItem], highlighted: String? = nil, height: CGFloat = 28, action: @escaping (String) -> Void) {
        self.items = items; self.highlighted = highlighted; self.height = height; self.action = action
    }

    public var body: some View {
        SegmentRow(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                segment(item, separator: showsSeparator(after: i))
            }
        }
        .padding(2)
        .frame(height: height)
        .background(KitPalette.chip, in: Capsule())
    }

    private func showsSeparator(after i: Int) -> Bool {
        guard i < items.count - 1 else { return false }
        return items[i].id != highlighted && items[i + 1].id != highlighted
    }

    private func segment(_ item: SegmentedItem, separator: Bool) -> some View {
        let raised = item.id == highlighted
        let label = Text(item.title).font(.system(size: 12, weight: .medium)).monospacedDigit().lineLimit(1).fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        return Button { action(item.id) } label: { label }
            .buttonStyle(SegmentButtonStyle(raised: raised, height: height - 4))
            .disabled(!item.enabled)
            .help(item.help ?? item.title)
            .accessibilityLabel(item.accessibilityLabel)
            .overlay(alignment: .trailing) { SegmentSeparator(visible: separator) }
    }
}

private struct SegmentSeparator: View {
    let visible: Bool
    var body: some View {
        if visible {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 12).offset(x: 1.5).accessibilityHidden(true)
        }
    }
}

private struct SegmentButtonStyle: ButtonStyle {
    let raised: Bool
    let height: CGFloat
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .frame(height: height)
            .background {
                if raised {
                    RoundedRectangle(cornerRadius: height / 2, style: .continuous).fill(KitPalette.knob)
                        .shadow(color: .black.opacity(0.16), radius: 1.5, y: 0.5)
                } else if configuration.isPressed {
                    RoundedRectangle(cornerRadius: height / 2, style: .continuous).fill(Color.primary.opacity(0.08))
                }
            }
            .opacity(enabled ? 1 : 0.45)
    }
}

/// Lays segments out at their ideal widths plus an equal share of the spare width.
struct SegmentRow: Layout {
    var spacing: CGFloat = 2
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = ideal.reduce(CGFloat(0)) { $0 + $1.width + 12 } + CGFloat(max(0, subviews.count - 1)) * spacing
        let height = proposal.height ?? (ideal.map(\.height).max() ?? 0)
        return CGSize(width: proposal.width ?? natural, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let inner = bounds.width - CGFloat(subviews.count - 1) * spacing
        let spare = max(0, inner - ideal.reduce(0, +)) / CGFloat(subviews.count)
        var x = bounds.minX
        for (i, s) in subviews.enumerated() {
            let w = ideal[i] + spare
            s.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + spacing
        }
    }
}

// MARK: - Floating panel (find/common.swift:601-607)

extension View {
    /// Floating panel chrome: panel fill, hairline and the two-layer shadow (.10/2 + .26/44), radius 16.
    /// Production hosts it in an NSPanel; the fill stands in for the material in offscreen renders.
    public func daydreamFloatingPanel(radius: CGFloat = 16) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(DaydreamStyle.panelFill)
                    .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                    .shadow(color: .black.opacity(0.26), radius: 44, y: 24))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(KitPalette.panelStroke, lineWidth: 1))
    }
}
