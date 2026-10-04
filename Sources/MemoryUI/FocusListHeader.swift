import SwiftUI
import MemoryCore

// The Focus List header (spec §3.3, plan §5 A1; declutter): the calendar tile and the day title. The
// title is one line: "Today", else the short date ("Thu, Oct 1"), never a second date line. The tile opens the
// jump-to-date popover: a month calendar where one click on a day goes there (it replaced day chips, a stepper date
// field and Cancel/Jump). Days with moments carry a dot; days after today can't be picked.
// The toolbar's day stepper and ⌘[ ⌘] stay the quick way between days.

/// Day keys ("yyyy-MM-dd") and dates in the browser calendar's time zone.
public enum FocusDay {
    static func key(_ date: Date, _ calendar: Calendar) -> String? {
        try? DayScope.key(date, timezone: calendar.timeZone.identifier)
    }
    /// Midnight at the start of the day.
    static func date(_ key: String, _ calendar: Calendar) -> Date? {
        (try? DayScope.interval(day: key, timezone: calendar.timeZone.identifier).start) ?? RibbonModel.dayDate(key, calendar)
    }
    /// The key `days` calendar days from `key` (negative is earlier).
    static func shift(_ key: String, by days: Int, _ calendar: Calendar) -> String? {
        guard let start = date(key, calendar) else { return nil }
        // Noon, so a daylight-saving change never lands the shift on the wrong day.
        let noon = calendar.date(byAdding: .hour, value: 12, to: start) ?? start
        return calendar.date(byAdding: .day, value: days, to: noon).flatMap { FocusDay.key($0, calendar) }
    }
    /// Where Previous Day (`direction` < 0) or Next Day (> 0) goes from `key`: the nearest day before or after it that has
    /// records, and forward past the last recorded day, today. Days with nothing are skipped (owner 10/2: Back from Today
    /// landed on an empty day, whose page was only the week line, and read as a week view). nil: nowhere to go (Previous
    /// before the first recorded day, Next on today). `recorded` nil (not read yet, or no such read): the next calendar
    /// day, as before.
    public static func step(from key: String, by direction: Int, today: String, recorded: [String]?, calendar: Calendar) -> String? {
        guard direction != 0 else { return nil }
        let todayKnown = !today.isEmpty
        if direction > 0, todayKnown, key >= today { return nil }
        guard let recorded else {
            guard let next = shift(key, by: direction > 0 ? 1 : -1, calendar) else { return nil }
            return todayKnown ? min(next, today) : next
        }
        if direction < 0 { return recorded.last { $0 < key } }
        if let next = recorded.first(where: { $0 > key && (!todayKnown || $0 < today) }) { return next }
        return todayKnown ? today : nil
    }
    /// Whole days from `a` to `b` (positive when `b` is later).
    static func distance(_ a: String, _ b: String, _ calendar: Calendar) -> Int? {
        guard let da = date(a, calendar), let db = date(b, calendar) else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: da), to: calendar.startOfDay(for: db)).day
    }
    /// How a day's count line names it: "today", "yesterday", "on Sunday", "on Sep 14".
    static func word(_ key: String, today: String, calendar: Calendar, now: Date) -> DayWord {
        switch distance(key, today, calendar) {
        case 0?: return .today
        case 1?: return .yesterday
        default: return .day(date(key, calendar).map { DaydreamFormat.dayName($0, now: now, calendar: calendar) } ?? key)
        }
    }
}

public struct FocusListHeader: View {
    let day: Date
    let dayKey: String
    let now: Date
    let calendar: Calendar
    let chips: [DayChipModel]
    let narrow: Bool
    let onSelectDay: (String) -> Void
    let onJump: (Date) -> Void
    /// Days known to have moments ("yyyy-MM-dd"): a dot under the day in the calendar.
    let recorded: Set<String>
    /// The calendar shows these past days (a month): the owner loads what it doesn't know yet, for their dots.
    let onShowDays: ([String]) -> Void
    @State private var calendarOpen = false
    @State private var picked = Date()

    /// - `chips`: the recent days in the jump-to-date popover, oldest first (`chipModels(keys:digests:calendar:)`).
    /// - `onSelectDay`: a chip's day key. `onJump`: the date picked in the jump-to-date popover.
    public init(day: Date, dayKey: String, now: Date, calendar: Calendar, chips: [DayChipModel], narrow: Bool,
                recorded: Set<String> = [], onShowDays: @escaping ([String]) -> Void = { _ in },
                onSelectDay: @escaping (String) -> Void, onJump: @escaping (Date) -> Void) {
        self.day = day; self.dayKey = dayKey; self.now = now; self.calendar = calendar; self.chips = chips; self.narrow = narrow
        self.recorded = recorded; self.onShowDays = onShowDays
        self.onSelectDay = onSelectDay; self.onJump = onJump
    }

    /// The chips' day keys, oldest first: `count` days ending today, or, for an older focused day,
    /// the days around it (never past today).
    public static func chipKeys(focused: String, today: String, count: Int, calendar: Calendar) -> [String] {
        let n = max(1, count)
        var end = today
        if let age = FocusDay.distance(focused, today, calendar), age >= n,
           let centred = FocusDay.shift(focused, by: n / 2, calendar) {
            end = centred
        }
        return (0..<n).reversed().compactMap { FocusDay.shift(end, by: -$0, calendar) }
    }

    /// Chip models from the day cache's digests. A day not read yet has no count (a neutral
    /// loading circle, never a guessed icon); a day with no moments shows the dashed circle.
    public static func chipModels(keys: [String], digests: [String: DayDigest], calendar: Calendar) -> [DayChipModel] {
        keys.compactMap { key in
            guard let date = FocusDay.date(key, calendar) else { return nil }
            let digest = digests[key]
            let top = digest.flatMap { $0.momentCount > 0 ? $0.topApp : nil }
            // An app known only by its bundle ID is drawn (icon or monogram) but never named.
            return DayChipModel(id: key, date: date, topBundle: top?.bundle, topName: top?.nameResolved == true ? top?.name : nil,
                                moments: digest?.momentCount)
        }
    }

    /// "Jump to date, Tuesday, September 22".
    public static func jumpLabel(_ day: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.timeZone = calendar.timeZone
        f.dateFormat = "EEEE, MMMM d"
        return "Jump to date, " + f.string(from: day)
    }

    public var body: some View {
        let title = DaydreamFormat.dayHeader(day, now: now, calendar: calendar)
        return HStack(alignment: .center, spacing: 12) {
            Button {
                picked = day
                calendarOpen = true
            } label: {
                CalendarTile(date: day, calendar: calendar, size: 34).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Jump to Date")
            .accessibilityLabel(Self.jumpLabel(day, calendar: calendar))
            .accessibilityValue(calendarOpen ? "Expanded" : "Collapsed")
            .popover(isPresented: $calendarOpen, arrowEdge: .bottom) { jumpPopover }
            // One title for every day, as Today's: "Today", else "Thu, Oct 1" (the tile shows the weekday and date).
            Text(title).font(DaydreamType.pageTitle).lineLimit(1).fixedSize()
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
        }
        .padding(.leading, 8).padding(.trailing, 2)
    }

    private var jumpPopover: some View {
        JumpCalendar(focused: dayKey, now: now, calendar: calendar,
                     recorded: recorded.union(chips.filter { ($0.moments ?? 0) > 0 }.map(\.id)),
                     onShowDays: onShowDays) { key in
            calendarOpen = false
            onSelectDay(key)
        }
        .daydreamNoInitialFocusRing()
    }
}

/// The jump-to-date calendar: the month, ‹ Today ›, and a grid of days. One click on a day goes there; days after
/// today are greyed and can't be picked; days with moments carry a small dot; the day shown is filled. Esc or a click
/// outside closes the popover (NSPopover's own).
public struct JumpCalendar: View {
    let focused: String
    let now: Date
    let calendar: Calendar
    let recorded: Set<String>
    let onShowDays: ([String]) -> Void
    let onPick: (String) -> Void
    /// Any day of the month shown.
    @State private var month: Date

    public init(focused: String, now: Date, calendar: Calendar, recorded: Set<String>, onShowDays: @escaping ([String]) -> Void = { _ in },
                onPick: @escaping (String) -> Void) {
        self.focused = focused; self.now = now; self.calendar = calendar; self.recorded = recorded
        self.onShowDays = onShowDays; self.onPick = onPick
        _month = State(initialValue: FocusDay.date(focused, calendar) ?? now)
    }

    static let cell = CGSize(width: 34, height: 30)

    /// The month's days as grid slots: nil before the 1st (the week starts on the calendar's first weekday).
    static func slots(month: Date, calendar: Calendar) -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let count = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let lead = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        let noon = calendar.date(byAdding: .hour, value: 12, to: interval.start) ?? interval.start
        return Array(repeating: nil, count: lead) + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: noon) }
    }

    private var todayKey: String { FocusDay.key(now, calendar) ?? "" }
    private var monthTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = "MMMM yyyy"
        return f.string(from: month)
    }
    private var showsCurrentMonth: Bool { calendar.isDate(month, equalTo: now, toGranularity: .month) }
    private func shift(_ months: Int) { if let next = calendar.date(byAdding: .month, value: months, to: month) { month = next } }
    private var pastKeys: [String] {
        Self.slots(month: month, calendar: calendar).compactMap { $0.flatMap { FocusDay.key($0, calendar) } }.filter { $0 <= todayKey }
    }

    public var body: some View {
        let symbols = Array(0..<7).map { i -> String in
            let all = calendar.veryShortStandaloneWeekdaySymbols
            return all[(i + calendar.firstWeekday - 1) % 7]
        }
        let columns = Array(repeating: GridItem(.fixed(Self.cell.width), spacing: 0), count: 7)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                Text(monthTitle).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                arrow("chevron.left", help: "Previous Month", enabled: true) { shift(-1) }
                Button("Today") { onPick(todayKey) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6).frame(height: 24).contentShape(Rectangle())
                    .help("Go to Today")
                arrow("chevron.right", help: "Next Month", enabled: !showsCurrentMonth) { shift(1) }
            }
            .padding(.leading, 6)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                        .frame(width: Self.cell.width, height: 20)
                }
                ForEach(Array(Self.slots(month: month, calendar: calendar).enumerated()), id: \.offset) { _, slot in
                    if let slot, let key = FocusDay.key(slot, calendar) { dayCell(slot, key: key) }
                    else { Color.clear.frame(width: Self.cell.width, height: Self.cell.height) }
                }
            }
        }
        .padding(12)
        .fixedSize()
        .onAppear { onShowDays(pastKeys) }
        .onChange(of: month) { _ in onShowDays(pastKeys) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Jump to date")
    }

    private func dayCell(_ date: Date, key: String) -> some View {
        let future = key > todayKey
        let selected = key == focused
        let isToday = key == todayKey
        let has = recorded.contains(key)
        let number = calendar.component(.day, from: date)
        return Button { onPick(key) } label: {
            VStack(spacing: 1) {
                Text("\(number)").font(.system(size: 12.5, weight: selected || isToday ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(selected ? AnyShapeStyle(Color.white) : future ? AnyShapeStyle(.quaternary)
                                     : isToday ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                Circle().fill(selected ? Color.white.opacity(0.85) : Color.secondary.opacity(0.7)).frame(width: 3.5, height: 3.5)
                    .opacity(has && !future ? 1 : 0)
            }
            .frame(width: 28, height: 28)
            .background(selected ? Color.accentColor : Color.clear, in: Circle())
            .frame(width: Self.cell.width, height: Self.cell.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(JumpDayButtonStyle(selected: selected))
        .disabled(future)
        .accessibilityLabel(DayChips.spokenDate(date, calendar: calendar))
        .accessibilityValue(has ? "Has moments" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func arrow(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).help(help).accessibilityLabel(help)
    }
}

/// A calendar day: a soft circle on hover and press, nothing else (no focus ring on the first day).
private struct JumpDayButtonStyle: ButtonStyle {
    let selected: Bool
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(Color.primary.opacity(selected ? 0 : configuration.isPressed ? 0.12 : hovered ? 0.07 : 0)).frame(width: 28, height: 28))
            .onHover { hovered = $0 }
    }
}

extension View {
    /// A popover's first control gets keyboard focus when it opens; with keyboard navigation on, macOS drew a thick
    /// blue ring around it every time (owner, Preview 2: the first day chip "always surrounded by blue"). The ring
    /// is dropped in popovers (macOS 14 and later); the controls still take Tab and Space.
    @ViewBuilder public func daydreamNoInitialFocusRing() -> some View {
        if #available(macOS 14.0, *) { self.focusEffectDisabled() } else { self }
    }
}
