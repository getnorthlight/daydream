import SwiftUI
import AppKit

// Main-window toolbar (header-A; spec §3.2, §5.1, plan §5 A3; lifted from proto/status/header.swift `ToolbarA`,
// `DayNav`, `SearchField` and `ToolCircle`). One set of item views, drawn two ways:
// - `DaydreamToolbarRow`: a 52 pt row in the content (`MemoryShell(chrome: .inline)`: harnesses, renders, trials).
// - `.daydreamWindowToolbar(enabled:)`: the same views as items of the window's unified toolbar (production).
// Leading, the day stepper. Centre, the search trigger: a button that summons Recall and never types a query.
// Trailing, the status capsule and its popover (when recording is off and can start, the capsule is the
// `Start Recording` pill, whose chevron opens the same popover), and the Settings gear. The summary-model
// download's progress is in Settings › Summaries, not here. Every control sets its own button style: the shell's content
// style (ShellButtonStyle) never reaches the toolbar.

// MARK: - Item chrome

/// Where a toolbar item is drawn. In the window toolbar on macOS 26 the system backs each item with glass, so
/// the items drop their own fills; the in-content row always draws them (renders stay deterministic).
enum ToolbarItemChrome: Equatable {
    case inline, windowToolbar

    var drawsFill: Bool {
        guard self == .windowToolbar else { return true }
        if #available(macOS 26, *) { return false }
        return true
    }
}

/// Toolbar item colours (header-A `SC.item` / `SC.itemStroke`).
enum ToolbarPalette {
    /// Raised item fill: white α.96 on light, white 0.245 on dark.
    static let item = KitPalette.dynamic(NSColor(white: 1, alpha: 0.96), NSColor(white: 0.245, alpha: 1))
    static let stroke = KitPalette.dynamic(NSColor(white: 0, alpha: 0.08), NSColor(white: 1, alpha: 0.14))
}

extension View {
    /// Header-A item chrome (`glassCapsule`): fill, 0.5 pt hairline and a soft shadow under the shape only.
    /// Nothing is drawn where the system provides glass.
    @ViewBuilder
    func toolbarItemChrome<S: InsettableShape>(_ shape: S, fill: Color = ToolbarPalette.item, stroke: Color = ToolbarPalette.stroke,
                                               shadow: Bool = true, chrome: ToolbarItemChrome) -> some View {
        if chrome.drawsFill {
            background(shape.fill(fill).shadow(color: .black.opacity(shadow ? 0.07 : 0), radius: 2, y: 1))
                .overlay(shape.strokeBorder(stroke, lineWidth: 0.5))
        } else {
            self
        }
    }
}

/// Press and disabled feedback for toolbar items. The item's chrome is applied outside the button, so only the
/// glyph fades when pressed or disabled and the capsule or circle stays put (as the day stepper's does).
struct ToolbarPressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
    }
}

extension View {
    /// Toolbar buttons never take keyboard focus: a mouse click must not leave one focused for Space to press again
    /// (owner 10/2, the Previous Day segment). Their commands have menu keys (⌘[ ⌘] ⌘K ⌘,); VoiceOver still presses them.
    func toolbarButtonNoFocus() -> some View { focusable(false) }
}

// MARK: - Layout

/// Toolbar widths from the window width (0 before the first layout pass: the narrowest layout, so the first
/// pass never asks for more room than the window has).
struct ToolbarLayout: Equatable {
    static let height: CGFloat = 52
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 8
    /// Below this the capsule shows its glyph only.
    static let compactCapsuleBelow: CGFloat = 720
    /// Below this the search trigger is a 32 pt magnifier.
    static let magnifierBelow: CGFloat = 600
    static let searchMax: CGFloat = 380
    static let searchMin: CGFloat = 180
    /// Two 34 pt segments and their divider.
    static let stepperWidth: CGFloat = 69
    /// The window toolbar's leading room before the day stepper, less `padding`: the traffic lights. Measured on
    /// macOS 26 (zoom button ends at 79 pt, the stepper starts at 96 pt); `WindowConfigurator` reports the window's
    /// own value, never less than this.
    static let windowLeadingInset: CGFloat = 80

    let compactCapsule: Bool
    /// nil: the magnifier.
    let searchWidth: CGFloat?
    /// The in-content row centres the search on the window. When even the centred magnifier would touch the
    /// controls at either side (Off with Start Recording at 560 pt), it sits beside the day
    /// stepper instead. The window toolbar's principal item is placed by AppKit.
    let centresSearch: Bool

    /// - `leadingInset`: room before the row's leading padding (window controls; the traffic lights in the window
    ///   toolbar, `windowLeadingInset`). Without it the window toolbar asks for a search field that pushes the
    ///   status controls into the overflow menu at 600-640 pt.
    /// - `gap`: room between two status controls (`trailingWidth`).
    init(width: CGFloat, state: CapturePresentation, leadingInset: CGFloat = 0, gap: CGFloat = spacing) {
        compactCapsule = width < Self.compactCapsuleBelow
        let trailing = Self.trailingWidth(state, compact: compactCapsule, gap: gap)
        // The search stays window-centred, so it gets twice the room left of the wider side.
        let side = max(leadingInset + Self.stepperWidth, trailing) + Self.padding + 12
        let room = width - 2 * side
        searchWidth = width < Self.magnifierBelow || room < Self.searchMin ? nil : min(Self.searchMax, room.rounded(.down))
        if searchWidth != nil {
            centresSearch = true
        } else {
            let half = width / 2, magnifier: CGFloat = 32
            let leadingEnd = Self.padding + leadingInset + Self.stepperWidth + Self.spacing
            let trailingStart = width - Self.padding - trailing - Self.spacing
            centresSearch = half - magnifier / 2 >= leadingEnd && half + magnifier / 2 <= trailingStart
        }
    }

    /// Stepped widths for the window toolbar, whose items keep the size they were created with on macOS 13.
    var toolbarSearchWidth: CGFloat? {
        guard let searchWidth else { return nil }
        return [380, 300, 240, 180].first { $0 <= searchWidth } ?? nil
    }

    /// Off and able to start: the capsule's place is taken by the Start Recording pill (one control, not two).
    static func showsStart(_ state: CapturePresentation) -> Bool { state.state.kind == .off && state.canResume }

    /// The status capsule was pressed. perm-1004 (owner 10/3: one click): while it says `Turn on Accessibility` (or
    /// Input Monitoring) the press goes straight to that permission (its System Settings pane and DayDream's drag card,
    /// `CaptureActions.openSystemSettings`); every other state opens the status popover.
    static func capsulePressed(_ state: RecordingState, actions: CaptureActions, open: inout Bool) {
        if let next = state.nextPermission { open = false; actions.openSystemSettings(next); return }
        open.toggle()
    }

    /// The pill's chevron (the status popover) only when there is an issue for the popover to say: a plain
    /// Off's popover would only repeat Start Recording.
    static func startHasMore(_ state: CapturePresentation) -> Bool {
        !(state.issue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// The status controls' width: the recording control's fixed slot (the capsule or the Start Recording pill, the
    /// same in every state, so nothing moves when recording starts, pauses or stops) and the gear. `gap` is the room
    /// between them (8 pt in the row; the window toolbar's item spacing, wider on macOS 26 where spacers keep
    /// the glass items apart).
    static func trailingWidth(_ state: CapturePresentation, compact: Bool, gap: CGFloat = spacing) -> CGFloat {
        statusSlotWidth(compact: compact) + gap + 32
    }
    /// The recording control's slot: 32 pt when compact, else `StatusCapsule.slotWidth`, whatever the state.
    static func statusSlotWidth(compact: Bool) -> CGFloat { compact ? 32 : StatusCapsule.slotWidth }
}

// MARK: - Day stepper

/// Previous and next day (⌘[ ⌘]): two 34×32 segments in one capsule. Sends `.previousDay` / `.nextDay` to
/// whichever surface owns the day. Disabled without canonical days or while Recall is up; Next is disabled on today.
public struct DayStepper: View {
    @ObservedObject var browser: ActivityBrowser
    /// The day cache's today and recorded days decide what each segment can do.
    @ObservedObject private var cache: DaydreamDayCache
    var chrome: ToolbarItemChrome = .inline

    public init(browser: ActivityBrowser) { self.browser = browser; _cache = ObservedObject(wrappedValue: browser.dayCache) }
    init(browser: ActivityBrowser, chrome: ToolbarItemChrome) {
        self.browser = browser; _cache = ObservedObject(wrappedValue: browser.dayCache); self.chrome = chrome
    }

    private var available: Bool { browser.loadCanonicalDay != nil && !browser.recallVisible }
    private var onToday: Bool { Self.isOnToday(browser) }

    /// Whether the Focus List shows today (`focusedDay` nil or today's key): Next Day and Today have nothing to do.
    /// Go ▸ Next Day / Today read the same rule, so the menu and the stepper agree.
    @MainActor public static func isOnToday(_ browser: ActivityBrowser) -> Bool {
        guard let day = browser.focusedDay else { return true }
        return day == browser.dayCache.todayKey
    }

    /// The day Previous Day (`direction` -1) or Next Day (+1) would show (`FocusDay.step`); nil: nowhere to go (no
    /// recorded day before the one shown). Go ▸ Previous Day / Next Day read the same rule.
    @MainActor public static func target(_ browser: ActivityBrowser, direction: Int) -> String? {
        let cache = browser.dayCache
        let today = cache.todayKey ?? ""
        let shown = browser.focusedDay.flatMap { $0.isEmpty ? nil : $0 } ?? today
        guard !shown.isEmpty else { return nil }
        return FocusDay.step(from: today.isEmpty ? shown : min(shown, today), by: direction, today: today,
                             recorded: cache.recordedDays, calendar: browser.calendar)
    }

    public var body: some View {
        HStack(spacing: 0) {
            segment("chevron.left", "Previous Day", keys: "⌘[", enabled: available && Self.target(browser, direction: -1) != nil) {
                browser.send(.previousDay)
            }
            Rectangle().fill(ToolbarPalette.stroke).frame(width: 1, height: 16).accessibilityHidden(true)
            segment("chevron.right", "Next Day", keys: "⌘]", enabled: available && !onToday) { browser.send(.nextDay) }
        }
        .toolbarItemChrome(Capsule(), chrome: chrome)
        .accessibilityElement(children: .contain)
    }

    private func segment(_ symbol: String, _ title: String, keys: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.8))
                .frame(width: 34, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarPressStyle())
        // Never keyboard focus (owner 10/2): a click left the segment focused with no ring drawn, and Space pressed
        // it again. ⌘[ ⌘] are the keyboard's way between days.
        .toolbarButtonNoFocus()
        .disabled(!enabled)
        .help("\(title) (\(keys))")
        .accessibilityLabel(title)
    }
}

// MARK: - Search trigger

/// Styled like a field, but a button: it summons Recall (`recallPresented`) and never writes `query`, so typing
/// happens in Recall's own field. A 32 pt magnifier when narrow; collapsed to it (and disabled) while Recall is up.
public struct ToolbarSearchTrigger: View {
    @ObservedObject var browser: ActivityBrowser
    /// nil: the magnifier.
    let width: CGFloat?
    var chrome: ToolbarItemChrome = .inline

    public static let placeholder = "Search your notes and what you've seen"
    /// The placeholder as the field narrows: whole, then cut at a phrase boundary, never mid-word.
    public static let placeholderSteps = [placeholder, "Search what you've seen", "Search"]

    public init(browser: ActivityBrowser, width: CGFloat? = 380) { self.browser = browser; self.width = width }
    init(browser: ActivityBrowser, width: CGFloat?, chrome: ToolbarItemChrome) { self.browser = browser; self.width = width; self.chrome = chrome }

    public var body: some View {
        let field = browser.recallVisible ? nil : width
        Button { browser.recallPresented = true } label: {
            if let field {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        placeholderText(Self.placeholderSteps[0])
                        placeholderText(Self.placeholderSteps[1])
                        placeholderText(Self.placeholderSteps[2])
                    }
                    // No keycap: Go › Search… shows ⌘K.
                }
                .padding(.leading, 12).padding(.trailing, 7)
                // Leading-aligned frame, never a Spacer: a Spacer in the button's label makes the bridged window
                // toolbar drop the principal item when it is built with the field (macOS 26.5), so the search
                // was missing whenever the toolbar arrived in a window already laid out (first launch: the
                // memory window replaces "Getting ready…"). check: dd-first-launch-checks.
                .frame(width: field, height: 32, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
        }
        .buttonStyle(ToolbarPressStyle())
        .toolbarButtonNoFocus()
        // Outside the button: disabled (Recall up, no search backend) fades the glyph and text, not the well or circle.
        .background { SearchTriggerChrome(field: field != nil, chrome: chrome) }
        .disabled(!browser.canSearch || browser.recallVisible)
        .help(Self.placeholder + " (⌘K)")
        .accessibilityLabel("Search")
        .accessibilityIdentifier("toolbar-search")
    }

    private func placeholderText(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
    }
}

/// The field's well and hairline, or the magnifier's circle (`toolbarItemChrome`); nothing where the system draws
/// glass. A background view rather than a conditional modifier: a toolbar item whose root switches modifier
/// branches is dropped from the bridged window toolbar (macOS 26.5).
private struct SearchTriggerChrome: View {
    let field: Bool
    let chrome: ToolbarItemChrome

    var body: some View {
        if chrome.drawsFill {
            if field {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DaydreamStyle.wellFill)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ToolbarPalette.stroke, lineWidth: 0.5))
            } else {
                Circle().fill(ToolbarPalette.item).shadow(color: .black.opacity(0.07), radius: 2, y: 1)
                    .overlay(Circle().strokeBorder(ToolbarPalette.stroke, lineWidth: 0.5))
            }
        }
    }
}

// MARK: - Settings gear

/// Opens Settings (⌘,). An orange badge with a window-coloured cut-out marks an issue that needs attention.
public struct SettingsGearButton: View {
    let issue: String?
    /// What the help says about the issue (`help(for:now:timeZone:)`).
    let attention: String?
    let action: () -> Void
    var chrome: ToolbarItemChrome = .inline

    /// A bare issue: its help is the mapped issue copy. The toolbar passes the state instead (`init(state:…)`),
    /// so the help names the permission that is actually missing.
    public init(issue: String?, action: @escaping () -> Void) {
        self.issue = issue; self.attention = issue.map(RecordingCopy.issue); self.action = action
    }
    init(state: CapturePresentation, now: Date, timeZone: TimeZone, chrome: ToolbarItemChrome, action: @escaping () -> Void) {
        issue = state.issue; attention = Self.attention(for: state, now: now, timeZone: timeZone)
        self.chrome = chrome; self.action = action
    }

    /// The gear's help: `Settings (⌘,)`, or `Settings · ` and what the issue means for this state: the attention line
    /// when the state doesn't say it, otherwise the state's own detail (`Input Monitoring is off in System Settings.`,
    /// never the generic both-required sentence when the reads name the missing permission).
    public static func help(for state: CapturePresentation, now: Date, timeZone: TimeZone) -> String {
        attention(for: state, now: now, timeZone: timeZone).map { "Settings · " + $0 } ?? "Settings (⌘,)"
    }

    static func attention(for state: CapturePresentation, now: Date, timeZone: TimeZone) -> String? {
        guard let issue = state.issue else { return nil }
        return state.attentionLine(now: now, timeZone: timeZone) ?? state.state.detail(now: now, timeZone: timeZone) ?? RecordingCopy.issue(issue)
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape").font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.8))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(ToolbarPressStyle())
        .toolbarButtonNoFocus()
        .toolbarItemChrome(Circle(), chrome: chrome)
        .overlay(alignment: .topTrailing) {
            if issue != nil {
                Circle().fill(KitPalette.orange).frame(width: 10, height: 10)
                    .padding(2).background(Circle().fill(DaydreamStyle.window))
                    .offset(x: 3, y: -3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .help(attention.map { "Settings · " + $0 } ?? "Settings (⌘,)")
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("memory-settings")
        .accessibilityValue(issue == nil ? "" : "Attention required")
    }
}

// MARK: - Status group

/// Motion for status changes (plan §5 A3): a 0.2 s cross-fade for what appears or disappears, and a spring for the
/// layout around it; under Reduce Motion only the cross-fade, and the layout changes at once.
enum StatusMotion {
    static let fade = AnyTransition.opacity.animation(.easeInOut(duration: 0.2))
    static func layout(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85) }
}

/// The status capsule and the popover it opens. `open` is owned by whoever places the capsule (the row, or the
/// window toolbar, so the popover survives AppKit rebuilding the toolbar item).
struct StatusCapsuleItem: View {
    @ObservedObject var browser: ActivityBrowser
    let state: CapturePresentation
    let actions: CaptureActions
    let compact: Bool
    let chrome: ToolbarItemChrome
    @Binding var open: Bool

    var body: some View {
        Group {
            if ToolbarLayout.showsStart(state) {
                // Off and able to start: one control that reads as the action. Its label starts recording
                // (one explicit press); with an issue, its chevron opens the same popover the capsule does.
                StartRecordingButton(isOpen: open, action: { actions.perform(.start) }, more: ToolbarLayout.startHasMore(state) ? { open.toggle() } : nil,
                                     width: ToolbarLayout.statusSlotWidth(compact: compact), compact: compact)
            } else {
                StatusCapsule(state: state.state, canStart: state.canResume, compact: compact, isOpen: open,
                              timeZone: browser.calendar.timeZone, chrome: chrome) { ToolbarLayout.capsulePressed(state.state, actions: actions, open: &open) }
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            StatusPopoverHost(browser: browser, presentation: state, actions: actions.closing { open = false })
                .daydreamNoInitialFocusRing()
        }
    }
}

/// The in-content row's status controls: the status capsule (or, Off, the Start Recording pill) with its
/// popover, and the gear.
struct StatusControlGroup: View {
    @ObservedObject var browser: ActivityBrowser
    let state: CapturePresentation
    let actions: CaptureActions
    let compact: Bool
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.daydreamNow) private var fixedNow

    var body: some View {
        HStack(spacing: ToolbarLayout.spacing) {
            StatusCapsuleItem(browser: browser, state: state, actions: actions, compact: compact, chrome: .inline, open: $open)
            SettingsGearButton(state: state, now: fixedNow ?? Date(), timeZone: browser.calendar.timeZone, chrome: .inline,
                               action: actions.settings)
        }
        .animation(StatusMotion.layout(reduceMotion: reduceMotion), value: state.state.kind)
    }
}

extension CaptureActions {
    /// The same actions, each dismissing the popover first. `Check Again` keeps it open to show the new reads.
    func closing(_ dismiss: @escaping () -> Void) -> CaptureActions {
        let base = self
        var out = CaptureActions(pause: { dismiss(); base.pause($0) }, resume: { dismiss(); base.resume() },
                                 stop: { dismiss(); base.stop() }, settings: { dismiss(); base.settings() })
        out.openSystemSettings = { dismiss(); base.openSystemSettings($0) }
        out.checkPermissions = base.checkPermissions
        out.openSettingsSection = { dismiss(); base.openSettingsSection($0) }
        out.openMain = { dismiss(); base.openMain() }
        out.openRecall = { dismiss(); base.openRecall() }
        out.quit = base.quit
        out.retryIssue = { dismiss(); base.retryIssue() }
        return out
    }
}

// MARK: - In-content row

/// The 52 pt toolbar row drawn in the content (`MemoryShell(chrome: .inline)`). The search trigger is centred on
/// the row, whatever the widths at either side.
public struct DaydreamToolbarRow: View {
    @ObservedObject var browser: ActivityBrowser
    let state: CapturePresentation
    let actions: CaptureActions
    /// Window width for the compact layouts; 0 when not laid out yet (the narrowest layout).
    let width: CGFloat
    /// Room kept free at the leading edge for window controls drawn over the row (0 under a normal title bar).
    let leadingInset: CGFloat

    public init(browser: ActivityBrowser, state: CapturePresentation, actions: CaptureActions, width: CGFloat = 0, leadingInset: CGFloat = 0) {
        self.browser = browser; self.state = state; self.actions = actions; self.width = width; self.leadingInset = leadingInset
    }

    public var body: some View {
        let layout = ToolbarLayout(width: width, state: state, leadingInset: leadingInset)
        ZStack {
            HStack(spacing: ToolbarLayout.spacing) {
                DayStepper(browser: browser)
                if !layout.centresSearch {
                    ToolbarSearchTrigger(browser: browser, width: nil)
                }
                Spacer(minLength: 0)
                StatusControlGroup(browser: browser, state: state, actions: actions, compact: layout.compactCapsule)
            }
            .padding(.leading, ToolbarLayout.padding + leadingInset)
            .padding(.trailing, ToolbarLayout.padding)
            if layout.centresSearch {
                ToolbarSearchTrigger(browser: browser, width: layout.searchWidth)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: ToolbarLayout.height)
    }
}

// MARK: - Window toolbar

extension View {
    /// Window-toolbar chrome (plan §4.7, L1): when `enabled`, places the stepper (`.navigation`), the search trigger
    /// (`.principal`) and the status controls and the gear (`.primaryAction`, one item each) in the window's unified
    /// toolbar, on the window colour, and configures the window (`WindowConfigurator`). The scene sets
    /// `.windowToolbarStyle(.unified(showsTitle: false))`: the style must be in place before the toolbar is built
    /// (NSToolbar never recovers its layout from a style or title change made after its items exist).
    @ViewBuilder
    public func daydreamWindowToolbar(enabled: Bool, browser: ActivityBrowser, state: CapturePresentation, actions: CaptureActions) -> some View {
        if enabled {
            modifier(DaydreamWindowToolbar(browser: browser, state: state, actions: actions))
        } else {
            self
        }
    }
}

/// The window toolbar's items, one per control, so each gets its own item (and, on macOS 26, its own glass):
/// - the day stepper (`.navigation`), the search trigger (`.principal`);
/// - `.primaryAction`: the capsule (Off: the Start Recording pill) and its popover, the gear.
/// The capsule's popover state lives here, outside the items.
struct DaydreamWindowToolbar: ViewModifier {
    @ObservedObject var browser: ActivityBrowser
    let state: CapturePresentation
    let actions: CaptureActions
    @State private var width: CGFloat = 0
    @State private var leadingInset = ToolbarLayout.windowLeadingInset
    @State private var capsuleOpen = false
    @Environment(\.daydreamNow) private var fixedNow

    /// Room between two `.primaryAction` items: NSToolbar's 8 pt item spacing, plus the fixed spacer that keeps
    /// the glass items apart on macOS 26.
    static var itemGap: CGFloat {
        if #available(macOS 26, *) { return ToolbarLayout.spacing + glassSpacer }
        return ToolbarLayout.spacing
    }
    /// A fixed `ToolbarSpacer` plus its item spacing, as laid out on macOS 26.5.
    static let glassSpacer: CGFloat = 10

    func body(content: Content) -> some View {
        let layout = ToolbarLayout(width: width, state: state,
                                   leadingInset: leadingInset, gap: Self.itemGap)
        let placed = content
            .background(GeometryReader { Color.clear.preference(key: WindowToolbarWidthKey.self, value: $0.size.width) })
            .onPreferenceChange(WindowToolbarWidthKey.self) { width = $0 }
        return Group {
            if #available(macOS 26, *) {
                placed.toolbar { glassItems(layout) }
            } else {
                placed.toolbar { items(layout) }
            }
        }
        .toolbarBackground(DaydreamStyle.window, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .background(WindowConfigurator { inset in
            if abs(inset - leadingInset) > 0.5 { leadingInset = inset }
        })
    }

    // MARK: Items

    private var zone: TimeZone { browser.calendar.timeZone }

    private func stepper() -> some View { DayStepper(browser: browser, chrome: .windowToolbar) }
    private func search(_ layout: ToolbarLayout) -> some View {
        ToolbarSearchTrigger(browser: browser, width: layout.toolbarSearchWidth, chrome: .windowToolbar)
    }
    private func capsule(_ layout: ToolbarLayout, chrome: ToolbarItemChrome = .windowToolbar) -> some View {
        StatusCapsuleItem(browser: browser, state: state, actions: actions, compact: layout.compactCapsule, chrome: chrome,
                          open: $capsuleOpen)
    }
    private func gear() -> some View {
        SettingsGearButton(state: state, now: fixedNow ?? Date(), timeZone: zone, chrome: .windowToolbar, action: actions.settings)
    }

    /// macOS 13-15: every item draws its own chrome.
    @ToolbarContentBuilder
    private func items(_ layout: ToolbarLayout) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) { stepper() }
        ToolbarItem(placement: .principal) { search(layout) }
        ToolbarItem(placement: .primaryAction) { capsule(layout) }
        ToolbarItem(placement: .primaryAction) { gear() }
    }

    /// macOS 26: the system backs each item with glass. A fixed spacer keeps the recording control and the gear in
    /// separate pieces. The recording control's item is the same in every state (sat5): it used to be two different
    /// items, glass for the capsule and none for the blue Start Recording pill, so AppKit removed and re-added it on
    /// every start and stop and the control jumped. Now it never has glass and the capsule draws its own fill.
    @available(macOS 26, *)
    @ToolbarContentBuilder
    private func glassItems(_ layout: ToolbarLayout) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) { stepper() }
        ToolbarItem(placement: .principal) { search(layout) }
        ToolbarItem(placement: .primaryAction) { capsule(layout, chrome: .inline) }
            .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) { gear() }
    }
}

private struct WindowToolbarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
