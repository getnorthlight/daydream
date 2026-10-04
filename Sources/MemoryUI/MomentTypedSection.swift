import SwiftUI
import MemoryCore

// fix/show-all: "What happened" in a moment's detail ("Show All"), owner test 7. It used to be one row per run of repeats,
// so a Claude chat was thirteen rows that all said "Claude", each with an arrow that only brought the Claude app forward.
// Now it is one entry per real thing (a chat or window by its title, a page by its site and title), in the order they
// were first seen, each with its time, what was sent there (who only: "Asked Claude", "Texted Q7") and what was typed
// there, as quoted blocks with their own time; a long block shows its first lines and a "More" toggle. A page entry is
// its own click target (it opens that page); an app entry is not a button (bringing the app forward was the noise).
//
// The words come from `browser.loadMomentTyped` (the app: `MemoryStore.momentTypedRows` on a reader connection, then
// `ownerMomentTyped` in the app's own process, off the main thread) when the detail opens, and are held in the detail's
// view state only: gone when it closes, when the day's memory changes (a Forget, typing turned off, an exclusion) and
// before the next read. Nothing here is written anywhere, logged, indexed or sent: the MCP and CLI (`mac-mem`) don't
// link MemoryUI, and the writers and the cloud read the store, which this never writes.

/// A moment's typed rows as its detail draws them: the send lines by code (action ID → "Asked Claude", who only) and
/// the words in blocks (empty while typing is off, without a ready key, or with nothing typed).
public struct MomentTypedLoad: Equatable {
    public var sends: [String: String]
    public var blocks: [MomentTypedBlock]
    public init(sends: [String: String] = [:], blocks: [MomentTypedBlock] = []) { self.sends = sends; self.blocks = blocks }
    public static let empty = MomentTypedLoad()
}

/// One thing the moment was about, in its detail.
public struct MomentDetailEntry: Identifiable, Equatable {
    /// `app|host|title` (the title empty when it only names the app).
    public internal(set) var id: String
    public let bundle: String
    public let app: String
    public let host: String
    /// What the entry says: the window or page title, else the page's host, else the app.
    public internal(set) var title: String
    /// The site or the app beside the title, when it isn't the title.
    public internal(set) var detail: String
    public internal(set) var first: Date?
    public internal(set) var last: Date?
    /// Every action of the moment in this place, in time order.
    public internal(set) var actionIDs: [String]
    /// The action a page entry opens: its latest.
    public let openActionID: String?
    /// What was sent here, who only, in order, once each.
    public internal(set) var sends: [String]
    /// What was typed here, in time order.
    public internal(set) var typed: [MomentTypedBlock]
    public var isWeb: Bool { !host.isEmpty }
    /// claude/terminal-details-1003: why the words are withheld, a privacy reason only ("Hidden: looked like a password
    /// or key"); nil shows no line.
    var withheldReason: String? = nil
    /// Metadata-only absence label; never substitutes invented text for a quote.
    var capturedWordingUnavailable = false
    /// A merged run of views, clicks and switches ("Worked in Terminal"): drawn quietly (owner 10/2).
    var quiet = false
    /// A Messages line (owner 10/3, `MessagesTypedFold`): a sent text, an unsent draft or a draft then Return.
    public internal(set) var message: MessagesTypedFold.Line? = nil
    /// The message's words as typed so far (untrimmed: a trailing space says the next piece is a new word).
    var messageWords = ""
    /// The muted replied-to line under a compose line's block (`on: “…”`, `ComposeSend.contextLine`).
    public internal(set) var context: String? = nil
    /// A page-visit row a reply to the same post replaced (the reply's entry ID); dropped by the fold.
    var replacedBy: String? = nil
    /// page-links-1003: the page's own link (`CanonicalAction.link`) its open action opens; nil for a window, or a page
    /// saved without one (it opens its site).
    public internal(set) var link: String? = nil
    /// The short link beside a page's title ("youtube.com/watch…"), else its site.
    var place: String { link.flatMap(BrowserSites.shortLink) ?? host }
}

extension MomentDetailBody {
    /// The place key shared by actions and typed blocks: the app (bundle, else name), the page's host, and the title
    /// cleaned, dropped when it only names the app ("Claude" in Claude) so every window of a one-window app is one thing.
    static func entryKey(bundle: String, app: String, host: String, title: String) -> (key: String, title: String) {
        let name = AppNames.display(app: app, bundle: bundle)
        var t = TitleClean.clean(title, app: name, site: host)
        if t.caseInsensitiveCompare(name) == .orderedSame || t.caseInsensitiveCompare(app) == .orderedSame
            || (!host.isEmpty && t.caseInsensitiveCompare(host) == .orderedSame) { t = "" }
        return ((bundle.isEmpty ? app.lowercased() : bundle) + "|" + host + "|" + t.lowercased(), t)
    }

    /// The moment's actions and typed blocks as entries: one per place (`entryKey`), in the order each was first seen.
    /// An entry's sends come from its actions (`typed.sends`, a confirmed message send is "Sent") and its typed blocks;
    /// a typed block whose place has no loaded action still gets its entry. Idle rows and actions naming no app or site
    /// are no entry.
    public static func entries(_ actions: [CanonicalAction], typed: MomentTypedLoad) -> [MomentDetailEntry] {
        struct Open {
            var bundle: String, app: String, host: String, title: String
            var first: Date?, last: Date?, order: Int
            var ids: [String] = [], latest: (at: Date?, id: String)? = nil, sends: [String] = [], typed: [MomentTypedBlock] = []
            var link: String? = nil
        }
        var byKey = [String: Open](), order = 0
        func add(_ key: String, _ make: () -> Open, _ update: (inout Open) -> Void) {
            var o = byKey[key] ?? { order += 1; return make() }()
            update(&o)
            byKey[key] = o
        }
        func note(_ send: String?, into o: inout Open) { if let send, !send.isEmpty, !o.sends.contains(send) { o.sends.append(send) } }
        let sorted = actions.sorted { (timestamp($0.at) ?? .distantPast, $0.id) < (timestamp($1.at) ?? .distantPast, $1.id) }
        for a in sorted where a.kind != "idle" && !(a.app.isEmpty && a.bundle.isEmpty && a.site.isEmpty) {
            let host = a.site.isEmpty ? "" : KitBrowsers.host(a.site)
            let (key, title) = entryKey(bundle: a.bundle, app: a.app, host: host, title: a.title)
            let at = timestamp(a.at)
            add(key, { Open(bundle: a.bundle, app: a.app, host: host, title: title, first: at, last: at, order: order) }) { o in
                o.ids.append(a.id)
                if o.title.isEmpty && !title.isEmpty { o.title = title }
                if let at { o.first = min(o.first ?? at, at); o.last = max(o.last ?? at, at) }
                if !host.isEmpty, (o.latest?.at ?? .distantPast) <= (at ?? .distantPast) { o.latest = (at, a.id); o.link = a.link }
                note(typed.sends[a.id] ?? (a.state == "sent" ? "Sent" : nil), into: &o)
            }
        }
        for b in typed.blocks.sorted(by: { ($0.at, $0.id) < ($1.at, $1.id) }) {
            let (key, title) = entryKey(bundle: b.bundle, app: b.app, host: b.host, title: b.title)
            let at = timestamp(b.at)
            add(key, { Open(bundle: b.bundle, app: b.app, host: b.host, title: title, first: at, last: at, order: order) }) { o in
                o.typed.append(b)
                if let at { o.first = min(o.first ?? at, at); o.last = max(o.last ?? at, at) }
                note(b.send, into: &o)
            }
        }
        return byKey.map { key, o in (key, o) }
            .sorted { ($0.1.first ?? .distantFuture, $0.1.order) < ($1.1.first ?? .distantFuture, $1.1.order) }
            .map { key, o in
                let name = AppNames.display(app: o.app, bundle: o.bundle)
                let appName = name.isEmpty ? (KitAppNames.name(for: o.bundle) ?? "") : name
                let title = !o.title.isEmpty ? o.title : !o.host.isEmpty ? o.host : (appName.isEmpty ? "Window" : appName)
                // page-links-1003: a page shows its short link beside the title ("youtube.com/watch…"), else its site.
                let place = o.link.flatMap(BrowserSites.shortLink) ?? o.host
                let detail = !o.host.isEmpty ? (place == title ? "" : place) : (appName == title ? "" : appName)
                var entry = MomentDetailEntry(id: key, bundle: o.bundle, app: appName, host: o.host, title: title, detail: detail,
                                              first: o.first, last: o.last, actionIDs: o.ids, openActionID: o.latest?.id,
                                              sends: o.sends, typed: o.typed)
                entry.link = o.link
                return entry
            }
    }
}

extension MomentDetailBody {
    /// An entry's time: "12:05 AM", or "12:05–12:11 AM" when it spans a minute or more.
    public static func entryTime(_ e: MomentDetailEntry, timeZone: TimeZone) -> String { MomentDetailEntryView.when(e, timeZone: timeZone) }
    /// A typed block long enough to collapse to its first lines ("More").
    public static func typedIsLong(_ text: String) -> Bool { MomentTypedBlockView.isLong(text) }
}

/// "What happened": the entries, each with its typed blocks under it.
struct MomentDetailEntries: View {
    let entries: [MomentDetailEntry]
    let timeZone: TimeZone
    let unavailable: Set<String>
    /// Opens a page entry's latest action (by ID); nil: no entry opens.
    let onOpen: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What happened").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 4)
            ForEach(entries) { entry in
                MomentDetailEntryView(entry: entry, timeZone: timeZone, unavailable: unavailable, onOpen: onOpen)
                Rectangle().fill(DaydreamStyle.hairline).frame(height: DaydreamStyle.hairlineWidth).padding(.leading, 82)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// One entry: `12:05 AM [icon] Title  site · Asked Claude        ↗` (the arrow on hover, pages only), then its typed
/// blocks, indented under the title.
struct MomentDetailEntryView: View {
    let entry: MomentDetailEntry
    let timeZone: TimeZone
    let unavailable: Set<String>
    let onOpen: ((String) -> Void)?

    /// claude/cc-label-1003: whether a typed block's caption shows its time: never for a row's only block (the row's time
    /// is already beside it, and a prompt sent at 2:31 that was started at 2:28 read "2:28" and "2:31"), and for one of
    /// several blocks only when its minute differs from the row's.
    static func blockShowsTime(_ b: MomentTypedBlock, in e: MomentDetailEntry, timeZone: TimeZone) -> Bool {
        guard e.typed.count > 1, let at = timestamp(b.at) else { return false }
        return DaydreamFormat.time(at, timeZone) != when(e, timeZone: timeZone)
    }

    /// "12:05 AM", or "12:05–12:11 AM" when the entry spans a minute or more.
    static func when(_ e: MomentDetailEntry, timeZone: TimeZone) -> String {
        // The start time only: a span doesn't fit the column (it truncated to "12:00–1…"), and the moment's header
        // already has the span; each typed block has its own time.
        guard let first = e.first else { return "" }
        return DaydreamFormat.time(first, timeZone)
    }

    var body: some View {
        let blocked = entry.openActionID.map(unavailable.contains) ?? false
        let canOpen = entry.isWeb && entry.openActionID != nil && onOpen != nil && !blocked
        VStack(alignment: .leading, spacing: 0) {
            FocusSourceEntry(help: blocked ? FocusListExpanded.unavailableHelp : canOpen ? "Opens \(entry.place) in your browser" : nil,
                             dimmed: blocked, run: canOpen ? { open() } : nil) {
                header
            }
            if !entry.typed.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    // claude/cc-label-1003 (owner 10/03): the time shows once. The row's own time is in the left column;
                    // a block repeats it only when the row holds several blocks typed at different times.
                    ForEach(entry.typed) { MomentTypedBlockView(block: $0, timeZone: timeZone,
                                                                showsTime: Self.blockShowsTime($0, in: entry, timeZone: timeZone)) }
                    // The replied-to post, muted, under the reply's words (compose-send/v1).
                    if let context = entry.context {
                        Text(verbatim: context).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 82).padding(.trailing, 12).padding(.bottom, 12).padding(.top, 2)
            } else if entry.capturedWordingUnavailable {
                Text(entry.withheldReason ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.leading, 82).padding(.trailing, 12).padding(.bottom, 8)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(Self.when(entry, timeZone: timeZone)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).frame(width: 56, alignment: .leading)
            Group {
                if entry.isWeb && KitBrowsers.isBrowser(entry.bundle) {
                    WebMonogramTile(domain: entry.host, browserBundle: nil, size: 16)
                } else {
                    AppIcon(bundle: entry.bundle.isEmpty ? nil : entry.bundle, name: entry.app, size: 16)
                }
            }
            .frame(width: 16, height: 16)
            Text(entry.title).font(.system(size: 12.5, weight: entry.quiet ? .regular : .medium)).lineLimit(1)
                .foregroundStyle(entry.quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            let side = ([entry.detail] + entry.sends).filter { !$0.isEmpty }.joined(separator: " · ")
            if !side.isEmpty {
                Text(side).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
        }
        .frame(height: 30)
    }

    private func open() {
        guard let id = entry.openActionID, let onOpen else { return }
        onOpen(id)
    }
}

/// One typed block under its entry: a small caption (the send and the time) and the words under a quiet rule, cut to
/// `collapsedLines` with a "More" toggle when longer.
struct MomentTypedBlockView: View {
    let block: MomentTypedBlock
    let timeZone: TimeZone
    /// claude/cc-label-1003: false when the row beside the block already shows its time.
    var showsTime: Bool = true
    @State private var expanded = false

    /// Lines shown before "More".
    static let collapsedLines = 4

    /// The small line over the words: the send ("Asked Claude") and the time.
    static func caption(_ b: MomentTypedBlock, timeZone: TimeZone, showsTime: Bool = true) -> String {
        let when = showsTime ? timestamp(b.at).map { DaydreamFormat.time($0, timeZone) } : nil
        return [b.send, when].compactMap { $0 }.joined(separator: " · ")
    }

    /// Long enough to cut: more lines than `collapsedLines`, or more characters than they hold at the detail's width.
    static func isLong(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).count > collapsedLines || text.count > collapsedLines * 90
    }

    var body: some View {
        let long = Self.isLong(block.text)
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1, style: .continuous).fill(Color.primary.opacity(0.14)).frame(width: 2)
            VStack(alignment: .leading, spacing: 4) {
                let caption = Self.caption(block, timeZone: timeZone, showsTime: showsTime)
                if !caption.isEmpty {
                    Text(caption).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(block.text)
                    .font(.system(size: 12.5)).foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(expanded || !long ? nil : Self.collapsedLines)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if long {
                    Button(expanded ? "Less" : "More") { expanded.toggle() }
                        .buttonStyle(FocusLinkButtonStyle())
                        .font(.system(size: 11.5, weight: .medium))
                        .accessibilityLabel(expanded ? "Show less" : "Show more")
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }
}
