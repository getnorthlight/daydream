import SwiftUI
import AppKit
import MemoryCore

/// The kit's Actions menu, limited to the room above the action bar. When the panel is too short
/// for the whole menu (list-only and minimum window sizes), it scrolls, and keeps the keyboard
/// highlight in view. (Contract request: `ActionsMenuView(maxHeight:)` that scrolls only the item region.)
struct RecallActionsMenu: View {
    @ObservedObject var model: RecallModel
    let maxHeight: CGFloat

    private var menu: some View {
        ActionsMenuView(items: model.menuItems, selected: model.menuSelection) { id in
            model.run(id); model.requestFocus()
        }
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            menu
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) { menu }
                    .frame(height: maxHeight)
                    .fixedSize(horizontal: true, vertical: false)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KitPalette.menuStroke, lineWidth: 1))
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KitPalette.menuFill)
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        .shadow(color: .black.opacity(0.30), radius: 28, y: 14))
                    .onAppear { if let id = model.menuSelection { proxy.scrollTo(id) } }
                    .onChange(of: model.menuSelection) { id in if let id { proxy.scrollTo(id) } }
            }
        }
        .frame(maxHeight: maxHeight, alignment: .bottom)
    }
}

// The Recall panel (find-A `AResults`): the query bar (or the detail's breadcrumb), the list and
// preview split (list only below 760 pt), the footer banners, the 44 pt action bar and the ⌘K
// Actions menu. Its size comes from RecallHost.

struct RecallPanel: View {
    @ObservedObject var browser: ActivityBrowser
    @ObservedObject var model: RecallModel
    @ObservedObject var today: TodayDigest
    let size: CGSize

    private var detail: RecallRow? { model.detailRow }

    var body: some View {
        VStack(spacing: 0) {
            header
            rule
            ZStack(alignment: .topLeading) {
                results
                    .opacity(detail == nil ? 1 : 0)
                    .allowsHitTesting(detail == nil)
                    .accessibilityHidden(detail != nil)
                if let row = detail {
                    RecallDetailView(model: model, row: row)
                        .background(DaydreamStyle.panelFill)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            banners
            rule
            actionBar
        }
        .frame(width: size.width, height: size.height)
        .daydreamFloatingPanel(radius: DaydreamStyle.panelRadius)
        .overlay {
            if model.menuOpen || model.rangeMenuOpen {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { if model.menuOpen { model.closeMenu() }; model.closeRangeMenu(); model.requestFocus() }
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.menuOpen {
                RecallActionsMenu(model: model, maxHeight: RecallLayout.menuHeight(panel: size.height))
                    .padding(.trailing, 10).padding(.bottom, RecallLayout.barHeight + 6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.rangeMenuOpen { periodMenu.padding(.top, RecallLayout.headerHeight - 8).padding(.trailing, 14) }
        }
        .momentForgetConfirmation(browser: browser, request: $model.forgetRequest,
                                  onForgotten: { _ in model.memoryChanged() }, onError: { model.notice = $0 })
        .modifier(RecallActionForgetModifier(browser: browser, request: $model.actionForgetRequest,
                                             onForgotten: { _ in model.memoryChanged() }, onError: { model.notice = $0 }))
        .excludeAppConfirmation(browser: browser, request: $model.excludeRequest,
                                onExcluded: { _ in model.memoryChanged() },
                                onError: { model.excludeFailed($0) })
        // Esc with focus on one of the panel's controls (Full Keyboard Access moved it off the field with Tab):
        // the same step back as Esc in the field, and the field takes the keys again. In the field the field
        // delegate consumes Esc first (RecallKeys), so this never runs twice.
        .onExitCommand { model.cancel(); model.requestFocus() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search DayDream")
        .accessibilityAddTraits(.isModal)
    }

    private var rule: some View { RecallHairline() }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
        ZStack {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                RecallSearchField(browser: browser, model: model)
                    .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
                trailing
            }
            .padding(.leading, 20).padding(.trailing, 10)
            // The field stays mounted (and focused) under the breadcrumb, so ↑/↓ step results in the detail.
            .opacity(detail == nil ? 1 : 0)
            .allowsHitTesting(detail == nil)
            .accessibilityHidden(detail != nil)
            if detail != nil { RecallDetailBar(model: model, query: model.searchedText) }
        }
        .frame(maxWidth: .infinity)
            // On the results only: the detail has Back (and its ^ v buttons keep their place at the bar's end).
            if detail == nil { closeButton.padding(.trailing, 12) }
        }
        .frame(height: RecallLayout.headerHeight)
    }

    /// The visible way out (owner, Preview 2: "no way to exit it"): a small ✕ at the header's end, on the results and
    /// the detail alike. It closes Search in one click, as a click on the dimmed day or Esc (twice with a query) does.
    private var closeButton: some View {
        Button { model.close() } label: {
            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.07), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close (Esc)")
        .accessibilityLabel(Self.closeLabel)
        .accessibilityIdentifier("recall-close")
    }
    static let closeLabel = "Close Search"

    /// Spinner while in flight, else the date range; then the Find Related filter chip.
    @ViewBuilder private var trailing: some View {
        HStack(spacing: 8) {
            if model.busy {
                ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 16, height: 16)
                    .accessibilityLabel("Searching…")
            } else if model.rangeApplies {
                Button { model.toggleRangeMenu() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Text(model.period.title).font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Date range")
                .accessibilityLabel("Date range")
                .accessibilityValue(model.period.title)
            }
            if let filter = model.filter {
                HStack(spacing: 5) {
                    Text(filter.chipTitle ?? (filter.kind == .site ? "From this site" : "In this app")).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Button { model.applyFilter(nil); model.requestFocus() } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 16, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove Filter")
                    .accessibilityLabel("Remove Filter")
                }
                .padding(.leading, 10).padding(.trailing, 5).frame(height: 28)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
                .fixedSize()
                .accessibilityElement(children: .contain)
            }
        }
    }

    /// Past 7 Days / Past 30 Days / All Time. Hover and ↑/↓ move one highlight (the field keeps focus;
    /// Return picks, Esc closes), drawn like the Actions menu's selection.
    private var periodMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(RecallModel.Period.allCases, id: \.self) { p in
                let lit = model.rangeHighlight == p
                Button { model.setPeriod(p); model.requestFocus() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).opacity(p == model.period ? 1 : 0).frame(width: 14)
                        Text(p.title).font(.system(size: 13, weight: lit ? .medium : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(lit ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(KitRowButtonStyle(radius: 6))
                .onHover { inside in if inside { model.rangeHighlight = p } }
                .accessibilityAddTraits(p == model.period ? .isSelected : [])
            }
        }
        .padding(5)
        .frame(width: 170)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KitPalette.menuFill)
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            .shadow(color: .black.opacity(0.25), radius: 18, y: 10))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(KitPalette.menuStroke, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Date range")
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        if model.error != nil && !model.showsRecents {
            RecallErrorState(model: model)
        } else if model.showsNoResults {
            RecallNoResults(model: model)
        } else if model.showsRecents && model.displayRows.isEmpty {
            RecallNothingRecent()
        } else if model.busy && model.displayRows.isEmpty && !model.showsRecents {
            RecallSearchSkeleton()
        } else if model.split {
            HStack(spacing: 0) {
                RecallList(model: model, today: today)
                    .frame(width: RecallLayout.listWidth)
                    .opacity(model.stale ? 0.6 : 1)
                RecallHairline(axis: .vertical)
                Group {
                    if let row = model.selectedRow {
                        RecallPreview(model: model, row: row).id(row.id)
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(model.stale ? 0.6 : 1)
            }
        } else {
            RecallList(model: model, today: today)
                .opacity(model.stale ? 0.6 : 1)
        }
    }

    // MARK: Footer

    @ViewBuilder private var banners: some View {
        if model.originalBlocked {
            OriginalUnavailableBanner(onDismiss: { model.dismissOriginalBanner(); model.requestFocus() })
                .padding(.horizontal, 12).padding(.bottom, 8)
        }
        if let notice = model.notice {
            footerLine(notice, symbol: "exclamationmark.triangle") {
                Button { model.notice = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 18, height: 18)
                }
                .buttonStyle(.plain).help("Dismiss").accessibilityLabel("Dismiss")
            }
        }
        if let line = model.statusLine {
            footerLine(line, symbol: "hourglass") { EmptyView() }
        }
    }

    private func footerLine<Accessory: View>(_ text: String, symbol: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary).accessibilityHidden(true)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            accessory()
        }
        .padding(.horizontal, 14).frame(height: 32)
        .background(DaydreamStyle.wellFill)
        .accessibilityElement(children: .contain)
    }

    // MARK: Action bar

    private var actionBar: some View {
        let row = model.actionRow
        let items = model.menuItems
        // ⌘↩ is named for where it goes (L15): `Open Original` or `Open <App>`; hidden when neither exists.
        let open = items.first { $0.id == .openOriginal || $0.id == .openApp }
        let copy = items.first { $0.id == .copySummary }
        // The Open button says where it goes, so the left side is only the privacy line. Only what works now is
        // shown (declutter): no greyed Open Moment or Actions without a selected row, and no Open or Copy Summary
        // that can't run for this moment. The keys still do nothing then, as before.
        let openShown = open.flatMap { $0.enabled ? $0 : nil }
        let copyShown = copy.flatMap { $0.enabled ? $0 : nil }
        let openMoment = detail == nil && row != nil
        return HStack(spacing: 14) {
            footerStatus
            Spacer(minLength: 8)
            if detail == nil {
                if openMoment {
                    hint("Open Moment", "↩", strong: true, enabled: true) { model.openMoment(); model.requestFocus() }
                }
                if let open = openShown {
                    if openMoment { divider }
                    hint(open.title, "⌘↩", enabled: true) { model.handle(.openOriginal) }
                }
            } else {
                if let open = openShown {
                    hint(open.title, "⌘↩", strong: true, enabled: true) { model.handle(.openOriginal) }
                }
                if let copy = copyShown {
                    if openShown != nil { divider }
                    hint(copy.title, copy.keys ?? "", enabled: true) { model.run(copy.id) }
                }
            }
            if row != nil {
                if openMoment || openShown != nil || (detail != nil && copyShown != nil) { divider }
                hint("Actions", "⌘K", enabled: true, active: model.menuOpen) { model.toggleMenu(); model.requestFocus() }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: RecallLayout.barHeight)
        .background(Color.primary.opacity(0.025))
    }

    /// The lock and `On this Mac` (or `Searching…`), then the lock alone, so a narrow
    /// panel never clips a word.
    private var footerStatus: some View {
        let lock = Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) { lock; Text(model.footerText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).fixedSize() }
            HStack(spacing: 7) { lock; Text(model.footerShortText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).fixedSize() }
            lock
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.footerText)
    }

    private var divider: some View { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 16).accessibilityHidden(true) }

    private func hint(_ label: String, _ keys: String, strong: Bool = false, enabled: Bool, active: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 12, weight: strong ? .semibold : .regular))
                    .foregroundStyle(strong ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)).lineLimit(1).fixedSize()
                if !keys.isEmpty { Keycap(keys) }
            }
            .padding(.horizontal, active ? 8 : 0).frame(height: 28)
            .background(active ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(label)
    }
}

/// Shapes only: never presented as invented search hits or exposed as results.
private struct RecallSearchSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(0..<3, id: \.self) { row in
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)).frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)).frame(width: row == 1 ? 180 : 240, height: 12)
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.04)).frame(width: 130, height: 9)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore).accessibilityLabel("Searching…")
        .allowsHitTesting(false)
    }
}
