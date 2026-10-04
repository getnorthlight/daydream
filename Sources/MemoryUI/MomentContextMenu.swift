import SwiftUI

/// A moment's secondary-click menu (Recall's result rows, the Focus List's rows, the day card's ribbon spans): the
/// items of the ⌘K Actions menu (`ActionsMenuView`) for the same moment and place, in the same order, the privacy
/// items after a divider, then any "Don't Record <site>…" items. One source (`MomentActions.items`, or
/// `RecallModel.menuItems(for:)`), so the menus never differ.
public struct MomentContextMenu: View {
    public enum Entry: Equatable {
        case action(MomentActionItem)
        case site(ExcludeSiteRequest)
        case divider
    }

    let items: [MomentActionItem]
    let sites: [ExcludeSiteRequest]
    let perform: (MomentActionID) -> Void
    let excludeSite: (ExcludeSiteRequest) -> Void

    public init(items: [MomentActionItem], sites: [ExcludeSiteRequest] = [], excludeSite: @escaping (ExcludeSiteRequest) -> Void = { _ in },
                perform: @escaping (MomentActionID) -> Void) {
        self.items = items; self.sites = sites; self.perform = perform; self.excludeSite = excludeSite
    }

    /// What the menu shows, in order (also the check hook).
    public static func entries(_ items: [MomentActionItem], sites: [ExcludeSiteRequest] = []) -> [Entry] {
        let rows = ActionsMenuView.visibleRows(items, filter: "")
        let main = rows.filter { $0.group != .privacy }, privacy = rows.filter { $0.group == .privacy }
        var out = main.map(Entry.action)
        if !main.isEmpty && !(privacy.isEmpty && sites.isEmpty) { out.append(.divider) }
        return out + privacy.map(Entry.action) + sites.map(Entry.site)
    }

    public var body: some View {
        ForEach(Array(Self.entries(items, sites: sites).enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .action(let item):
                Button(role: item.destructive ? .destructive : nil) { perform(item.id) } label: {
                    Label(item.title, systemImage: item.symbol)
                }
                .disabled(!item.enabled)
            case .site(let request):
                Button { excludeSite(request) } label: { Label(request.menuTitle, systemImage: "eye.slash") }
            case .divider:
                Divider()
            }
        }
    }
}

/// The day card's ribbon spans' menu (`DDRibbon`): the moment's actions by its ID, set by whoever owns the day
/// (`CanonicalTimeline`). Unset (renders, the menu bar card): the spans have no menu.
public struct RibbonMomentMenu: Equatable {
    public var items: (String) -> [MomentActionItem]
    public var sites: (String) -> [ExcludeSiteRequest]
    public var perform: (MomentActionID, String) -> Void
    public var excludeSite: (ExcludeSiteRequest) -> Void
    /// A primary click on a span (click-to-reference): the span's moment.
    public var select: ((String) -> Void)? = nil
    /// The owner's count of what the closures read by value (fix/scroll-perf): menus with the same revision are the
    /// same menu, so a redraw of the day card keeps every span's menu instead of rebuilding it. nil: never equal.
    public var revision: Int? = nil

    public static func == (a: Self, b: Self) -> Bool { a.revision != nil && a.revision == b.revision }
    public init(items: @escaping (String) -> [MomentActionItem], sites: @escaping (String) -> [ExcludeSiteRequest] = { _ in [] },
                perform: @escaping (MomentActionID, String) -> Void, excludeSite: @escaping (ExcludeSiteRequest) -> Void = { _ in },
                select: ((String) -> Void)? = nil, revision: Int? = nil) {
        self.items = items; self.sites = sites; self.perform = perform; self.excludeSite = excludeSite; self.select = select
        self.revision = revision
    }
}

private struct RibbonMomentMenuKey: EnvironmentKey { static let defaultValue: RibbonMomentMenu? = nil }
/// The day ribbon's span menu, and a pinned hover tip for renders (the pointer is never over a render).
private struct RibbonTipKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    public var daydreamRibbonMenu: RibbonMomentMenu? {
        get { self[RibbonMomentMenuKey.self] } set { self[RibbonMomentMenuKey.self] = newValue }
    }
    /// Renders and checks: the moment (segment group) whose hover tip the day card's ribbon shows.
    public var daydreamRibbonTip: String? {
        get { self[RibbonTipKey.self] } set { self[RibbonTipKey.self] = newValue }
    }
}
