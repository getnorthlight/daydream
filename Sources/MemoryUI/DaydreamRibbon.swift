import SwiftUI
import AppKit
import MemoryCore

// DayDream day ribbon (spec §10.1): one component for the menu bar card and popover (.h28),
// the home summary and settings (.h8) and the Recall preview (.h6). Lifted from
// `status/common.swift` DayRibbon, `home/optionC.swift` SlimRibbonC and `find/common.swift`.
// Value-driven: callers pass segments, the live pause and the clock; nothing here reads a store
// or the system clock.

// MARK: - Values

/// One span of recorded activity (a moment, or one cluster of a moment).
public struct RibbonSegment: Identifiable, Equatable {
    public let id: String
    public let start: Date
    public let end: Date
    public let tint: Color
    /// Summary pending: drawn in model violet at α.5.
    public let pending: Bool
    /// The app, e.g. "Zed" (tooltip and VoiceOver).
    public let label: String
    /// The moment's title, if any (tooltip second line).
    public let title: String?
    /// Segments with the same group highlight together (the moment ID for cluster segments).
    public let group: String
    /// summaries/v3 levels: the block (band) the moment is in; hovering the band lights its segments.
    public var band: String? = nil
    /// The moment's main app and first site: the hover tip's icon and name (`RibbonTooltip`).
    public var bundle: String? = nil
    public var site: String? = nil

    public init(id: String, start: Date, end: Date, tint: Color, pending: Bool = false, label: String,
                title: String? = nil, group: String? = nil, band: String? = nil) {
        self.id = id; self.start = min(start, end); self.end = max(start, end); self.tint = tint
        self.pending = pending; self.label = label; self.title = title; self.group = group ?? id; self.band = band
    }
}

/// summaries/v3 levels: a block (L3) drawn as a band behind the ribbon's segments.
public struct RibbonBand: Identifiable, Equatable {
    public let id: String
    public let start: Date
    public let end: Date
    public let title: String
    public init(id: String, start: Date, end: Date, title: String) { self.id = id; self.start = min(start, end); self.end = max(start, end); self.title = title }
    /// The `hovered` value while the pointer is over this band (every segment of the block stays lit).
    public var hoverKey: String { "band:" + id }
}

/// The live pause only (spec §9: historical pauses are not stored).
public struct RibbonPause: Equatable {
    public let start: Date
    public let end: Date
    public init(start: Date, end: Date) { self.start = min(start, end); self.end = max(start, end) }
}

public enum RibbonHeight: CGFloat, CaseIterable, Sendable {
    case h6 = 6, h8 = 8, h28 = 28
    /// Bar thickness. `.h28` is the menu bar / popover ribbon: a 14 pt bar in a 28 pt band
    /// (bar, hatch overhang and flag row), as in the M1 reference.
    public var bar: CGFloat {
        switch self {
        case .h6: return 6
        case .h8: return 8
        case .h28: return 14
        }
    }
}

public enum RibbonFlag: Equatable, Sendable {
    case none
    /// `Now` (.h28, with a red dot while Recording) or `Now 4:21` (.h6/.h8).
    case now
    /// `Paused · 12m left` (whole minutes, rounded up).
    case pausedLeft(TimeInterval)
    /// `Stopped at 4:18 PM`.
    case stoppedAt(Date)
}

// MARK: - App tints

/// Stable app colours for ribbon segments and top-app underlines: a curated 10-colour palette keyed
/// by a stable hash of the bundle ID. Red, indigo, orange and violet are left out: they mean
/// Recording, Paused, permissions and the model (spec §1.2).
public enum AppTint {
    public static let palette: [Color] = [
        Color(.sRGB, red: 0.20, green: 0.55, blue: 0.98, opacity: 1),   // blue
        Color(.sRGB, red: 0.16, green: 0.72, blue: 0.96, opacity: 1),   // sky
        Color(.sRGB, red: 0.08, green: 0.62, blue: 0.70, opacity: 1),   // teal
        Color(.sRGB, red: 0.24, green: 0.74, blue: 0.38, opacity: 1),   // green
        Color(.sRGB, red: 0.30, green: 0.80, blue: 0.66, opacity: 1),   // mint
        Color(.sRGB, red: 0.98, green: 0.78, blue: 0.18, opacity: 1),   // yellow
        Color(.sRGB, red: 0.93, green: 0.40, blue: 0.66, opacity: 1),   // pink
        Color(.sRGB, red: 0.66, green: 0.50, blue: 0.36, opacity: 1),   // brown
        KitPalette.dynamic(NSColor(white: 0.34, alpha: 1), NSColor(white: 0.70, alpha: 1)), // graphite
        Color(.sRGB, red: 0.60, green: 0.78, blue: 0.20, opacity: 1)    // lime
    ]

    /// Palette index for `bundle`. Stable across launches (String.hashValue is seeded per process).
    public static func index(_ bundle: String) -> Int {
        let sum = bundle.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return sum % palette.count
    }

    /// The tint for `bundle`; grey when unknown.
    public static func of(_ bundle: String?) -> Color {
        guard let bundle, !bundle.isEmpty else { return Color(nsColor: .systemGray) }
        return palette[index(bundle)]
    }
}

// MARK: - Ribbon

enum KitText {
    /// Rendered width of a single-line label (for clamping and collision checks).
    static func width(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }
    static func clock(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.timeZone = tz
        f.dateFormat = "h:mm"
        return f.string(from: d)
    }
}

/// The day ribbon. Segments on a track, the live pause hatched in indigo, a now tick and flag,
/// and an hour axis (9 AM · 12 PM · 3 PM · 6 PM). Hovering dims every other moment.
public struct DDRibbon: View {
    let segments: [RibbonSegment]
    let pause: RibbonPause?
    let range: ClosedRange<Date>
    let now: Date?
    let nowTint: Color
    let height: RibbonHeight
    let axis: Bool
    let flag: RibbonFlag
    let empty: Bool
    let hovered: String?
    let onHover: ((RibbonSegment?) -> Void)?
    let calendar: Calendar
    let momentCount: Int?
    /// The slim ribbon's `Now` flag carries the clock (`Now 4:21`); the day card passes false for `Now`.
    var nowClock = true
    /// summaries/v3 levels: blocks as bands behind the segments (the day card only).
    var bands: [RibbonBand] = []
    /// The hover tip over the span under the pointer (the day card only): after `tipDelay`, then it follows the pointer
    /// from span to span at once until the pointer leaves the bar.
    var tips = false
    public static let tipDelay: UInt64 = 300_000_000
    /// Checks: the day card's ribbon in its window's content (top-left origin), where a secondary click reaches a span.
    @MainActor public static var dayCardFrameForTesting: CGRect?
    @State private var pointed: RibbonSegment?
    @State private var tip: RibbonSegment?
    @State private var tipX: CGFloat = 0
    @State private var tipTask: Task<Void, Never>?
    @State private var tipShownOnce = false
    /// perf2-1005: the span group under the pointer, for the one span-menu surface (`RibbonSpanMenus`).
    @State private var menuGroup: String?
    @Environment(\.daydreamRibbonMenu) private var menu
    @Environment(\.daydreamReferenced) private var referenced
    @Environment(\.daydreamRibbonTip) private var pinnedTip

    /// - `range`: nil uses 8:00–19:00 on the day, widened to the segments, pause and now, rounded to the hour.
    /// - `nowTint`: nil is Recording red.
    /// - `hovered`: the hovered segment's `group`; every other group dims to α.35.
    /// - `momentCount`: spoken by VoiceOver when given.
    public init(segments: [RibbonSegment], pause: RibbonPause? = nil, range: ClosedRange<Date>? = nil, now: Date?,
                nowTint: Color? = nil, height: RibbonHeight, axis: Bool = false, flag: RibbonFlag = .none,
                empty: Bool = false, hovered: String? = nil, onHover: ((RibbonSegment?) -> Void)? = nil,
                calendar: Calendar = .current, momentCount: Int? = nil, nowClock: Bool = true) {
        self.nowClock = nowClock
        // Most callers pass them in order already; sorting a full day on every redraw was a measurable share of one.
        func before(_ a: RibbonSegment, _ b: RibbonSegment) -> Bool { (a.start, a.id) < (b.start, b.id) }
        self.segments = zip(segments, segments.dropFirst()).allSatisfy { !before($1, $0) } ? segments : segments.sorted(by: before)
        self.pause = pause; self.now = now
        self.nowTint = nowTint ?? KitPalette.red
        self.height = height; self.axis = axis; self.flag = flag; self.empty = empty
        self.hovered = hovered; self.onHover = onHover; self.calendar = calendar; self.momentCount = momentCount
        self.range = range ?? DDRibbon.defaultRange(segments: segments, pause: pause, now: now, calendar: calendar)
    }

    /// The hours the day's data covers (every segment, the pause and now), rounded out to whole hours, at least three
    /// hours long and kept inside the day; 8:00–19:00 when there is nothing to show. (Owner, Preview 2: a fixed
    /// 8 AM–7 PM left a short or early day as a sliver at one edge.)
    public static func defaultRange(segments: [RibbonSegment], pause: RibbonPause?, now: Date?, calendar: Calendar,
                                    day: Date? = nil) -> ClosedRange<Date> {
        let anchor = day ?? now ?? segments.map(\.start).min() ?? pause?.start ?? Date(timeIntervalSinceReferenceDate: 0)
        let dayStart = calendar.startOfDay(for: anchor)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        var points = segments.flatMap { [$0.start, $0.end] }
        if let pause { points += [pause.start, pause.end] }
        if let now { points.append(now) }
        let inDay = points.filter { $0 >= dayStart && $0 <= dayEnd }
        guard let first = inDay.min(), let last = inDay.max() else {
            let lo = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: dayStart) ?? dayStart
            let hi = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: dayStart) ?? dayEnd
            return lo...hi
        }
        func floorHour(_ d: Date) -> Date { calendar.dateInterval(of: .hour, for: d)?.start ?? d }
        func ceilHour(_ d: Date) -> Date {
            let f = floorHour(d)
            return f == d ? d : (calendar.date(byAdding: .hour, value: 1, to: f) ?? d)
        }
        var lo = max(dayStart, floorHour(first)), hi = min(dayEnd, ceilHour(last))
        // At least three hours, so half an hour of work isn't one wide smear: later first, then earlier.
        let least: TimeInterval = 3 * 3600
        if hi.timeIntervalSince(lo) < least { hi = min(dayEnd, lo.addingTimeInterval(least)) }
        if hi.timeIntervalSince(lo) < least { lo = max(dayStart, hi.addingTimeInterval(-least)) }
        return lo...max(hi, lo.addingTimeInterval(3600))
    }

    /// The axis labels' hours inside the range (not at its ends): every 1, 2, 3, 4 or 6 hours, at most four of them
    /// (9 AM · 12 PM · 3 PM · 6 PM over 8 AM–7 PM; 1 AM · 2 AM over midnight to 3 AM).
    public static func axisHours(_ range: ClosedRange<Date>, calendar: Calendar) -> [(Int, Date)] {
        let hours = range.upperBound.timeIntervalSince(range.lowerBound) / 3600
        let step = [1, 2, 3, 4, 6].first { hours / Double($0) <= 5 } ?? 6
        var out: [(Int, Date)] = []
        var d = calendar.dateInterval(of: .hour, for: range.lowerBound)?.start ?? range.lowerBound
        while d < range.upperBound, out.count < 24 {
            let h = calendar.component(.hour, from: d)
            if d > range.lowerBound && h % step == 0 { out.append((h, d)) }
            guard let next = calendar.date(byAdding: .hour, value: 1, to: d) else { break }
            d = next
        }
        return out
    }

    // MARK: Drawn content (also the test hooks)

    /// Segments that are drawn: none when `empty`, else those overlapping the range.
    var drawnSegments: [RibbonSegment] {
        guard !empty else { return [] }
        return segments.filter { $0.end >= range.lowerBound && $0.start <= range.upperBound }
    }
    var drawnPause: RibbonPause? {
        guard let pause, pause.end >= range.lowerBound, pause.start <= range.upperBound else { return nil }
        return pause
    }
    /// Test hook: how many segment layers the ribbon draws.
    public var segmentCountForTesting: Int { drawnSegments.count }
    /// Test hook: whether the pause hatch is drawn.
    public var hatchPresentForTesting: Bool { drawnPause != nil }
    /// Test hook: the VoiceOver value of the ribbon's single `Activity` element.
    public var accessibilityValueForTesting: String { accessibilityValue(drawnSegments) }

    private var bar: CGFloat { height.bar }
    private var slim: Bool { height != .h28 }
    private var flagRow: CGFloat { !slim && flag != .none ? 16 : 0 }
    private var labelRow: Bool { slim ? (axis || flag != .none) : axis }
    private var totalHeight: CGFloat {
        if slim { return bar + (labelRow ? 21 : 0) + (bands.isEmpty ? 0 : 7) }
        return flagRow + bar + 6 + (axis ? 20 : 0)
    }
    private var span: TimeInterval { max(1, range.upperBound.timeIntervalSince(range.lowerBound)) }
    private func x(_ d: Date, _ w: CGFloat) -> CGFloat {
        CGFloat(min(max(d.timeIntervalSince(range.lowerBound) / span, 0), 1)) * w
    }

    public var body: some View {
        // The spans in range, once per redraw (fix/scroll-perf): the spans, their menus and VoiceOver all read them.
        let drawn = drawnSegments
        return GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .topLeading) {
                ForEach(drawnBands) { b in band(b, w) }
                track(w)
                if slim { slimSpans(drawn, w) } else { ForEach(drawn) { s in segment(s, w) } }
                if let p = drawnPause { hatch(p, w) }
                if let now, now >= range.lowerBound, now <= range.upperBound { tick(now, w) }
                labels(w)
                if let menu {
                    RibbonSpanMenus(spans: drawn.map { menuArea($0, w) }, menu: menu, pointed: menuGroup)
                        .equatable()
                        .frame(width: w, height: totalHeight, alignment: .topLeading)
                }
                if tips { tipView(w) }
            }
            .frame(width: w, height: totalHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            // The checks' window frame lives in its own small reader: reading the global frame here made every scroll
            // step rebuild the whole ribbon, its spans and their menus (fix/scroll-perf).
            .background { if tips { DayCardFrameReporter() } }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    // perf2-1005: the span whose menu a secondary click opens (one menu surface, `RibbonSpanMenus`).
                    if menu != nil {
                        let group = RibbonSpanMenus.group(at: p, in: drawn.map { menuArea($0, w) })
                        if group != menuGroup { menuGroup = group }
                    }
                    let s = segment(at: p.x, width: w)
                    onHover?(s ?? bandSegment(at: p.x, width: w))
                    if tips {
                        if pointed != s { pointed = s }
                        follow(s, x: p.x)
                    }
                case .ended:
                    if menuGroup != nil { menuGroup = nil }
                    onHover?(nil)
                    if tips { pointed = nil; tipTask?.cancel(); tipTask = nil; tip = nil; tipShownOnce = false }
                }
            }
        }
        .frame(height: totalHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity")
        .accessibilityValue(accessibilityValue(drawn))
        .accessibilityIdentifier("day-ribbon")
    }

    /// Secondary click on a span: the moment's actions (`MomentContextMenu`), where the day's owner set them. A clear
    /// area a little taller and wider than the span, so a thin span is still easy to reach.
    private func menuArea(_ s: RibbonSegment, _ w: CGFloat) -> RibbonSpanMenus.Span {
        let a = x(s.start, w)
        return .init(id: s.id, group: s.group, frame: CGRect(x: a - 1, y: barTop - 5, width: max(6, x(s.end, w) - a + 2), height: bar + 10))
    }

    /// With bands, the slim bar sits 7 pt lower so the band's top edge fits.
    private var barTop: CGFloat { slim ? (bands.isEmpty ? 0 : 7) : flagRow + 3 }

    @ViewBuilder private func track(_ w: CGFloat) -> some View {
        let radius = slim ? bar / 2 : 4
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if empty {
            shape.strokeBorder(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
                .frame(width: w, height: bar).offset(y: barTop)
        } else {
            shape.fill(Color.primary.opacity(slim ? 0.06 : 0.07)).frame(width: w, height: bar).offset(y: barTop)
        }
    }

    var drawnBands: [RibbonBand] {
        guard !empty else { return [] }
        return bands.filter { $0.end >= range.lowerBound && $0.start <= range.upperBound }
    }
    /// Test hook: how many block bands the ribbon draws.
    public var bandCountForTesting: Int { drawnBands.count }

    /// A band: 3 pt wider than its block on each side, 7 pt above and below the bar (the mock's 22 pt band on an 8 pt bar).
    private func band(_ b: RibbonBand, _ w: CGFloat) -> some View {
        let lit = hovered == b.hoverKey
        let left = x(b.start, w) - 3, width = max(6, x(b.end, w) - x(b.start, w) + 6)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(lit ? DaydreamStyle.model.opacity(0.13) : Color.primary.opacity(0.035))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
            .frame(width: width, height: bar + 14)
            .offset(x: left, y: barTop - 7)
    }
    /// Hovering a band away from any segment: a stand-in segment whose group is the band's hover key.
    private func bandSegment(at px: CGFloat, width w: CGFloat) -> RibbonSegment? {
        guard let b = drawnBands.last(where: { px >= x($0.start, w) - 3 && px <= x($0.end, w) + 3 }) else { return nil }
        return RibbonSegment(id: b.hoverKey, start: b.start, end: b.end, tint: .clear, label: b.title, title: b.title, group: b.hoverKey)
    }

    private func segment(_ s: RibbonSegment, _ w: CGFloat) -> some View {
        let isHovered = hovered == s.group || (s.band != nil && hovered == "band:" + s.band!)
        // A lit span stands up out of the bar (taller, never thinner than 4 pt) while the rest fade.
        let lift: CGFloat = isHovered ? (slim ? 3 : 2) : 0
        let width = max(isHovered ? 4 : 2.5, x(s.end, w) - x(s.start, w) - 1)
        let fill: Color = s.pending ? DaydreamStyle.model.opacity(0.5) : s.tint
        return RoundedRectangle(cornerRadius: slim ? min(2.5, bar / 2) : 2.5, style: .continuous)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(Color.white.opacity(isHovered && !slim ? 0.95 : 0), lineWidth: 1.5))
            .shadow(color: .black.opacity(isHovered && !slim ? 0.3 : 0), radius: 2, y: 1)
            .frame(width: width, height: bar + lift * 2)
            .offset(x: x(s.start, w), y: barTop - lift)
            .opacity(hovered != nil ? (isHovered ? 1 : 0.3) : (referenced.map { $0.contains(s.group) ? 1 : 0.3 } ?? 1))
    }

    /// The slim bar's spans (the day card), drawn as two pictures instead of a view per span (fix/scroll-perf): a full
    /// day's hundred-odd span views made every hover, highlight and redraw of the day card lay out and diff each one.
    /// Every span is drawn in the base, which fades to α.3 while something is lit; the lit spans (hovered, lifted
    /// 3 pt; or referenced) are drawn again on top at full strength. Both fade with the transaction as the views did.
    @ViewBuilder private func slimSpans(_ spans: [RibbonSegment], _ w: CGFloat) -> some View {
        let dimmed = hovered != nil || referenced != nil
        RibbonSpanCanvas(spans: spans.map { slimSpan($0, w, lifted: false) }).equatable()
            .opacity(dimmed ? 0.3 : 1)
        if dimmed {
            let lit = spans.filter { hovered != nil ? isHovered($0) : referenced?.contains($0.group) == true }
            if !lit.isEmpty { RibbonSpanCanvas(spans: lit.map { slimSpan($0, w, lifted: hovered != nil) }).equatable() }
        }
    }
    private func isHovered(_ s: RibbonSegment) -> Bool {
        hovered == s.group || (s.band != nil && hovered == "band:" + s.band!)
    }
    private func slimSpan(_ s: RibbonSegment, _ w: CGFloat, lifted: Bool) -> RibbonSpanCanvas.Span {
        let lift: CGFloat = lifted ? 3 : 0, a = x(s.start, w)
        return .init(rect: CGRect(x: a, y: barTop - lift, width: max(lifted ? 4 : 2.5, x(s.end, w) - a - 1), height: bar + lift * 2),
                     radius: min(2.5, bar / 2), fill: s.pending ? DaydreamStyle.model.opacity(0.5) : s.tint)
    }

    @ViewBuilder private func hatch(_ p: RibbonPause, _ w: CGFloat) -> some View {
        let width = max(3, x(p.end, w) - x(p.start, w))
        if slim {
            HatchBand(radius: 2, strong: false).frame(width: width, height: bar + 2).offset(x: x(p.start, w), y: barTop - 1)
        } else {
            HatchBand().frame(width: width, height: bar + 6).offset(x: x(p.start, w), y: flagRow)
        }
    }

    private func tick(_ now: Date, _ w: CGFloat) -> some View {
        let nx = x(now, w)
        return Capsule().fill(nowTint)
            .frame(width: 2, height: slim ? bar + 6 : bar + 8)
            .offset(x: nx - 1, y: slim ? barTop - 3 : flagRow - 1)
    }

    // MARK: Labels

    private struct Label: Identifiable {
        let id: String
        let text: String
        let x: CGFloat          // leading edge
        let y: CGFloat
        let width: CGFloat
        let strong: Bool
        let dot: Bool
    }

    private var flagText: String? {
        switch flag {
        case .none: return nil
        case .now:
            guard let now else { return "Now" }
            return slim && nowClock ? "Now " + KitText.clock(now, calendar.timeZone) : "Now"
        case .pausedLeft(let t):
            let minutes = max(1, Int((t / 60).rounded(.up)))
            let h = minutes / 60, m = minutes % 60
            let compact = h == 0 ? "\(m)m" : (m == 0 ? "\(h)h" : "\(h)h \(m)m")
            return "Paused · " + compact + " left"
        case .stoppedAt(let d):
            return "Stopped at " + DaydreamFormat.time(d, calendar.timeZone)
        }
    }

    private func flagAnchor(_ w: CGFloat) -> CGFloat {
        switch flag {
        case .pausedLeft: if let p = drawnPause { return x(p.end, w) }
        case .stoppedAt(let d): return x(now ?? d, w)
        default: break
        }
        return now.map { x($0, w) } ?? w
    }

    private func computedLabels(_ w: CGFloat) -> [Label] {
        var out: [Label] = []
        let size: CGFloat = 10.5
        var flagBox: ClosedRange<CGFloat>?
        if let text = flagText {
            let dot = !slim && flag == .now && nowTint == KitPalette.red
            let tw = KitText.width(text, size: size, weight: .semibold) + (dot ? 9 : 0)
            let anchor = flagAnchor(w)
            // .h28: the flag ends at the anchor (trailing-aligned above the bar); slim: centred under it.
            let raw = slim ? anchor - tw / 2 : anchor - tw + (flag == .now ? 1 : 0)
            let lead = min(max(0, raw), max(0, w - tw))
            out.append(Label(id: "flag", text: text, x: lead, y: slim ? barTop + bar + 7 : -1, width: tw, strong: true, dot: dot))
            if slim { flagBox = (lead - 6)...(lead + tw + 6) }
        }
        if axis {
            for (hour, d) in Self.axisHours(range, calendar: calendar) {
                let text = hour == 0 ? "12 AM" : hour == 12 ? "12 PM" : hour < 12 ? "\(hour) AM" : "\(hour - 12) PM"
                let tw = KitText.width(text, size: size, weight: slim ? .regular : .medium)
                let lead = min(max(0, x(d, w) - tw / 2), max(0, w - tw))
                if let box = flagBox, box.overlaps(lead...(lead + tw)) { continue }
                out.append(Label(id: "h\(hour)", text: text, x: lead, y: slim ? barTop + bar + 7 : flagRow + bar + 6 + 4 + 5, width: tw, strong: false, dot: false))
            }
        }
        return out
    }

    @ViewBuilder private func labels(_ w: CGFloat) -> some View {
        if axis && !slim {
            ForEach([9, 12, 15, 18], id: \.self) { hour in
                if let d = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: range.lowerBound),
                   d >= range.lowerBound, d <= range.upperBound {
                    Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 1, height: 3)
                        .offset(x: x(d, w) - 0.5, y: flagRow + bar + 6 + 4)
                }
            }
        }
        ForEach(computedLabels(w)) { label in
            HStack(spacing: 4) {
                if label.dot { Circle().fill(nowTint).frame(width: 5, height: 5) }
                Text(label.text)
                    .font(.system(size: 10.5, weight: label.strong ? .semibold : (slim ? .regular : .medium)))
                    .monospacedDigit()
                    .lineLimit(1).fixedSize()
            }
            .foregroundStyle(label.strong ? AnyShapeStyle(nowTint) : AnyShapeStyle(.tertiary))
            .offset(x: label.x, y: label.y)
        }
    }

    // MARK: Hover tip

    /// The pointer moved over the bar: a tip already up follows it to `s` at once; otherwise one comes up after
    /// `tipDelay` over whatever span is under the pointer then. Between spans the tip hides but comes back at once.
    private func follow(_ s: RibbonSegment?, x px: CGFloat) {
        tipX = px
        if tipShownOnce { tip = s; return }
        guard tipTask == nil, s != nil else { return }
        tipTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.tipDelay)
            guard !Task.isCancelled else { return }
            tip = pointed
            tipShownOnce = pointed != nil
            tipTask = nil
        }
    }

    @ViewBuilder private func tipView(_ w: CGFloat) -> some View {
        let pinned = pinnedTip.flatMap { id in drawnSegments.first { $0.group == id } }
        if let shown = pinned ?? tip {
            let tw = RibbonTooltip.width(shown, timeZone: calendar.timeZone)
            let anchor = pinned != nil ? (x(shown.start, w) + x(shown.end, w)) / 2 : tipX
            let lead = min(max(0, anchor - tw / 2), max(0, w - tw))
            RibbonTooltip(segment: shown, timeZone: calendar.timeZone)
                .fixedSize()
                .offset(x: lead, y: barTop - RibbonTooltip.height - 6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }

    // MARK: Hover and accessibility

    private func segment(at px: CGFloat, width w: CGFloat) -> RibbonSegment? {
        drawnSegments.last { s in
            let a = x(s.start, w), b = max(a + 2.5, x(s.end, w))
            return px >= a - 2 && px <= b + 2
        }
    }

    private func accessibilityValue(_ shown: [RibbonSegment]) -> String {
        let tz = calendar.timeZone
        guard let first = shown.map(\.start).min(), let last = shown.map(\.end).max() else {
            return "No recorded actions for this day."
        }
        var parts: [String] = []
        let groups = Set(shown.map(\.group)).count
        let count = momentCount ?? groups
        parts.append((count == 1 ? "1 moment" : "\(count) moments") + " from " + DaydreamFormat.spokenRange(first, last, tz))
        if let p = drawnPause { parts.append("paused from " + DaydreamFormat.spokenRange(p.start, p.end, tz)) }
        if let text = flagText, flag != .now { parts.append(text) }
        return parts.joined(separator: ", ")
    }
}

/// Rounded spans drawn in one picture (`DDRibbon.slimSpans`), a little past the ribbon's edges so a lifted span isn't
/// clipped. Equal spans keep the picture as it was.
struct RibbonSpanCanvas: View, Equatable {
    struct Span: Equatable {
        let rect: CGRect
        let radius: CGFloat
        let fill: Color
    }
    let spans: [Span]
    private static let pad: CGFloat = 4

    var body: some View {
        let pad = Self.pad
        Canvas { ctx, _ in
            ctx.translateBy(x: pad, y: pad)
            for s in spans { ctx.fill(Path(roundedRect: s.rect, cornerRadius: s.radius, style: .continuous), with: .color(s.fill)) }
        }
        .padding(-pad)
        .allowsHitTesting(false)
    }
}

/// The spans' secondary-click menus and primary clicks (`DDRibbon.menuArea`), as ONE surface over the ribbon, apart from
/// the spans themselves (fix/scroll-perf): a hover or a highlight redraws the spans, never this, while the spans stay
/// where they are and the menu's revision holds.
///
/// perf2-1005 (owner 10/4, "clicking cards is glitchy"): this was one view per span (276 on a big day), each with its own
/// tap gesture and context menu. Every change the day's list saw (a card click is three or four of them) re-dirtied all of
/// them: about 60 of a click's ~100 ms on a 276-moment day. Now one hit shape (the union of the span areas, so a click
/// between spans still falls through), one tap that finds its span by location, and one context menu for the span under
/// the pointer (the pointer is over the span it right-clicks, so its last hover names it).
struct RibbonSpanMenus: View, Equatable {
    struct Span: Identifiable, Equatable {
        let id: String
        let group: String
        let frame: CGRect
    }
    let spans: [Span]
    let menu: RibbonMomentMenu
    /// The span group under the pointer (`DDRibbon` follows the pointer): the menu a secondary click opens.
    let pointed: String?

    static func == (a: Self, b: Self) -> Bool { a.spans == b.spans && a.menu == b.menu && a.pointed == b.pointed }

    /// The span at `point` (the topmost: the last drawn), else nil.
    static func group(at point: CGPoint, in spans: [Span]) -> String? {
        spans.last { $0.frame.contains(point) }?.group
    }

    var body: some View {
        let spans = spans, menu = menu
        Color.clear
            .contentShape(RibbonSpanAreas(frames: spans.map(\.frame)))
            .gesture(SpatialTapGesture().onEnded { tap in
                if let group = Self.group(at: tap.location, in: spans) { menu.select?(group) }
            })
            .contextMenu {
                if let group = pointed {
                    MomentContextMenu(items: menu.items(group), sites: menu.sites(group), excludeSite: menu.excludeSite) { menu.perform($0, group) }
                }
            }
    }
}

/// The union of the spans' click areas: the one hit shape of `RibbonSpanMenus`.
struct RibbonSpanAreas: Shape {
    let frames: [CGRect]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for f in frames { path.addRect(f) }
        return path
    }
}

/// Reports the day card ribbon's window frame to `DDRibbon.dayCardFrameForTesting`. Its own view, so a scroll (which
/// moves the global frame) re-evaluates only this empty reader, never the ribbon (fix/scroll-perf).
private struct DayCardFrameReporter: View {
    var body: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { DDRibbon.dayCardFrameForTesting = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { frame in DDRibbon.dayCardFrameForTesting = frame }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

// MARK: - Tooltip

/// The day ribbon's hover tip (owner's design B): a small card with the moment's icon (28 pt), its clean title in bold,
/// and `1:31–1:45 PM · Xcode` under it. Never typed words: the title is the note's, else the window-derived subject,
/// cleaned of unread counts and addresses by `RibbonModel.make`.
public struct RibbonTooltip: View {
    let segment: RibbonSegment
    let timeZone: TimeZone
    public init(segment: RibbonSegment, timeZone: TimeZone) { self.segment = segment; self.timeZone = timeZone }

    static let height: CGFloat = 52

    /// The moment's app (its main app's name).
    static func app(_ s: RibbonSegment) -> String { s.label }
    /// The title without the app it names ("WeeklySummaryExport.swift in Xcode": the app is on the line below); the
    /// app when there is no title.
    public static func title(_ s: RibbonSegment) -> String {
        let a = app(s)
        var t = s.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for suffix in [" in " + a, " on " + a] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        return t.isEmpty ? a : t
    }
    /// The second line: `1:31–1:45 PM · Xcode`.
    public static func detail(_ s: RibbonSegment, timeZone: TimeZone) -> String {
        DaydreamFormat.range(s.start, s.end, timeZone) + " · " + app(s)
    }
    /// The tip's words (the check hook): title, then the second line.
    public static func line(_ s: RibbonSegment, timeZone: TimeZone) -> String { title(s) + " · " + detail(s, timeZone: timeZone) }
    /// Laid-out width (for placing the tip inside the bar's width).
    static func width(_ s: RibbonSegment, timeZone: TimeZone) -> CGFloat {
        let text = max(KitText.width(title(s), size: 13, weight: .semibold), KitText.width(detail(s, timeZone: timeZone), size: 11.5))
        return min(360, 11 + 28 + 10 + text + 11 + 2)
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            MomentIcon(apps: [(segment.bundle, segment.label)], site: segment.site, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(segment)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(Self.detail(segment, timeZone: timeZone)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: 300, alignment: .leading)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(KitPalette.tooltipFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(KitPalette.tooltipStroke, lineWidth: 0.5))
        .shadow(color: KitPalette.tooltipShadow, radius: 12, y: 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Model

/// Ribbon values for a day, from the Today snapshot and the recording state.
public struct RibbonModel: Equatable {
    public var segments: [RibbonSegment]
    public var pause: RibbonPause?
    public var range: ClosedRange<Date>
    public var now: Date?
    public var nowTint: Color
    public var flag: RibbonFlag
    public var empty: Bool
    public var momentCount: Int
    /// summaries/v3 levels: the day's blocks as bands (the day card draws them).
    public var bands: [RibbonBand] = []

    public init(segments: [RibbonSegment], pause: RibbonPause?, range: ClosedRange<Date>, now: Date?, nowTint: Color,
                flag: RibbonFlag, empty: Bool, momentCount: Int) {
        self.segments = segments; self.pause = pause; self.range = range; self.now = now; self.nowTint = nowTint
        self.flag = flag; self.empty = empty; self.momentCount = momentCount
    }

    /// - Segments come from each moment's clusters (or its start–end when it has none), tinted with
    ///   `AppTint.of(primary bundle)`; pending moments are marked pending.
    /// - The pause is the live pause only: `since…until` (or `since…now` when open-ended), and only
    ///   when `since` is known and the day is today.
    /// - `isToday == false` draws no now tick, flag or pause.
    public static func make(snapshot: TodaySnapshot?, state: RecordingState?, now: Date, calendar: Calendar,
                            isToday: Bool = true) -> RibbonModel {
        // The day card makes its model on every redraw (a hover, a selection) from the same inputs (fix/scroll-perf).
        let key = MadeKey(snapshot: snapshot, state: state, now: now, calendar: calendar, isToday: isToday)
        if let hit = made.model(for: key) { return hit }
        let model = build(snapshot: snapshot, state: state, now: now, calendar: calendar, isToday: isToday)
        made.keep(model, for: key)
        return model
    }

    private struct MadeKey: Equatable {
        let snapshot: TodaySnapshot?, state: RecordingState?, now: Date, calendar: Calendar, isToday: Bool
    }
    /// The last few models made (the day card's and the menu bar's), by their inputs.
    private static let made = MadeModels()
    private final class MadeModels: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [(key: MadeKey, model: RibbonModel)] = []
        func model(for key: MadeKey) -> RibbonModel? {
            lock.lock(); defer { lock.unlock() }
            return kept.first { $0.key == key }?.model
        }
        func keep(_ model: RibbonModel, for key: MadeKey) {
            lock.lock(); defer { lock.unlock() }
            kept.insert((key, model), at: 0)
            if kept.count > 4 { kept.removeLast() }
        }
    }

    private static func build(snapshot: TodaySnapshot?, state: RecordingState?, now: Date, calendar: Calendar,
                              isToday: Bool) -> RibbonModel {
        var segments: [RibbonSegment] = []
        var bandOf = [String: String]()
        for b in snapshot?.levels?.blocks ?? [] { for id in b.momentIDs where bandOf[id] == nil { bandOf[id] = b.id } }
        for m in snapshot?.moments ?? [] {
            let bundle = m.primaryBundle ?? m.bundles.first
            let label = m.primaryApp ?? m.apps.first ?? "Moment"
            let pending = m.summary == .pending
            let spans = m.clusters.isEmpty ? [m.start...m.end] : m.clusters
            // The note's title when ready, else the subject (MomentSlice.title), without window-title noise.
            let title = cleanTitles.clean(m.title)
            for (i, span) in spans.enumerated() {
                var segment = RibbonSegment(id: spans.count == 1 ? m.id : "\(m.id)#\(i)", start: span.lowerBound, end: span.upperBound,
                                            tint: AppTint.of(bundle), pending: pending, label: label,
                                            title: title.isEmpty ? nil : title, group: m.id, band: bandOf[m.id])
                segment.bundle = bundle; segment.site = m.sites.first { !$0.isEmpty }
                segments.append(segment)
            }
        }
        var pause: RibbonPause?
        var flag: RibbonFlag = .none
        var tint = Color.secondary
        if isToday, let state {
            switch state {
            case .recording:
                tint = KitPalette.red; flag = .now
            case .paused(let until, let since, _):
                tint = DaydreamStyle.paused
                if let since { pause = RibbonPause(start: since, end: max(since, until ?? now)) }
                if let until, until > now { flag = .pausedLeft(until.timeIntervalSince(now)) } else { flag = .now }
            case .off(let since, _):
                tint = .secondary
                // Only a stop that happened today: yesterday's stop time is not today's event.
                flag = since.flatMap { calendar.isDate($0, inSameDayAs: now) ? RibbonFlag.stoppedAt($0) : nil } ?? .none
            case .needsPermission:
                tint = KitPalette.orange; flag = .none
            }
        }
        let day = snapshot.flatMap { dayDate($0.dayKey, calendar) }
        let tickNow: Date? = isToday ? now : nil
        let range = DDRibbon.defaultRange(segments: segments, pause: pause, now: tickNow, calendar: calendar, day: day ?? tickNow)
        var model = RibbonModel(segments: segments, pause: pause, range: range, now: tickNow, nowTint: tint, flag: flag,
                                empty: segments.isEmpty, momentCount: snapshot?.moments.count ?? 0)
        model.bands = (snapshot?.levels?.blocks ?? []).map { RibbonBand(id: $0.id, start: $0.start, end: $0.end, title: $0.name) }
        return model
    }

    /// `ThreadEntities.clean` (four regexes) once per title (fix/scroll-perf): the model is made again on every redraw
    /// of the day card, for every moment of the day.
    private static let cleanTitles = CleanTitleCache()
    private final class CleanTitleCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cleaned: [String: String] = [:]
        func clean(_ raw: String) -> String {
            lock.lock(); defer { lock.unlock() }
            if let hit = cleaned[raw] { return hit }
            if cleaned.count >= 4096 { cleaned.removeAll(keepingCapacity: true) }
            let out = ThreadEntities.clean(raw)
            cleaned[raw] = out
            return out
        }
    }

    static func dayDate(_ key: String, _ calendar: Calendar) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }
}

extension DDRibbon {
    /// A ribbon from a `RibbonModel`.
    public init(model: RibbonModel, height: RibbonHeight, axis: Bool = false, showsFlag: Bool = true,
                hovered: String? = nil, onHover: ((RibbonSegment?) -> Void)? = nil, calendar: Calendar, nowClock: Bool = true,
                showsBands: Bool = false) {
        self.init(segments: model.segments, pause: model.pause, range: model.range, now: model.now, nowTint: model.nowTint,
                  height: height, axis: axis, flag: showsFlag ? model.flag : .none, empty: model.empty,
                  hovered: hovered, onHover: onHover, calendar: calendar, momentCount: model.momentCount, nowClock: nowClock)
        // Bands only where asked (the day card's slim ribbon); the menu bar's ribbon stays as it was. The day card
        // (the one ribbon with bands) also shows the hover tip.
        bands = showsBands && height != .h28 ? model.bands : []
        tips = showsBands && height != .h28
    }
}

extension RibbonModel {
    /// The day card's ribbon (declutter): only `Now`, without the clock the menu bar already shows. A timed
    /// pause is its hatch alone and a stop is the empty tail: the capsule and the paused row already say them.
    /// Off or Needs Permission draws no now tick either: a bare line marked nothing (only `Now` or a live pause's
    /// hatch gives the tick a meaning).
    public var dayCard: RibbonModel {
        var model = self
        if flag != .now {
            model.flag = .none
            if pause == nil { model.now = nil }
        }
        return model
    }
}
