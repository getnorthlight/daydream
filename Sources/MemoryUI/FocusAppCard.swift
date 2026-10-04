import Foundation
import MemoryCore

/// One card per app inside a bracket (owner 10/2, Main.dc.html). Every moment of one app in a bracket is one card:
/// titled by the app's friendly name ("Texts", "Terminal", "ChatGPT"), never a thread name, with the card's range under
/// it. Collapsed it shows the newest summary line on the right; open, the summary bullets of every member (one per
/// conversation or action) on the left and a "Conversations" / "Pages" / "Windows" panel of up to 3 names on the right.
/// What happened and the full list are behind "Show details". Each member keeps its own ID, summary and actions.
/// These are the pure rules; the checks call them.
public enum FocusAppCard {
    /// Friendly names that differ from the app's own.
    static let friendlyNames: [String: String] = ["com.apple.MobileSMS": "Texts"]
    /// Apps whose windows are conversations.
    static let conversationBundles: Set<String> = [
        // claude/catchup-1003: the installed ChatGPT app is com.openai.codex (com.openai.chat is the older bundle).
        "com.apple.MobileSMS", "com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop", "net.whatsapp.WhatsApp",
        "com.tinyspeck.slackmacgap", "ru.keepcoder.Telegram", "org.telegram.desktop", "org.whispersystems.signal-desktop",
        "com.hnc.Discord", "com.facebook.archon", "com.microsoft.teams2", "com.apple.mail", "com.apple.iChat"
    ]

    /// The members, newest first (the card's anchor is the first).
    public static func members(_ session: TimelineSession<MomentSlice>) -> [MomentSlice] {
        session.members.sorted { ($0.latestObserved, $0.start, $0.id) > ($1.latestObserved, $1.start, $1.id) }.map(\.detail)
    }

    // MARK: Grouping by situation (owner 10/2)

    /// The card a moment joins in its bracket; nil keeps it a card of its own (owner 10/2, corrected).
    /// - Messages and chat apps, terminals and every other app: one card per app. Every Terminal window and folder is
    ///   one "Terminal" card, every Ghostty window one "Ghostty" card; the folders and windows are in its side panel.
    /// - Websites: each site is its own "app", in any browser: every x.com tab and page in the bracket is one "X" card,
    ///   adjacent or not. Keyed on the site (`siteKey`). A moment that touched several sites joins its first site's card
    ///   (a moment is one saved unit; its actions aren't split across cards). A browser moment with no site is the
    ///   browser's card.
    /// - A moment over several non-browser apps: its own card.
    public static func situation(_ m: MomentSlice) -> String? {
        var bundles = Set(m.bundles.filter { !$0.isEmpty })
        // Older notes: a moment recorded with no bundle, or only typed-text evidence, still names its app ("Messages",
        // "Texts"); it joins that app's card, so a "Viewed texts" moment is never a card of its own.
        if bundles.isEmpty {
            let names = Set((m.apps + [m.primaryApp ?? ""]).filter { !$0.isEmpty }.map { $0.lowercased() })
            if !names.isEmpty, names.isSubset(of: ["messages", "texts"]) { bundles = ["com.apple.MobileSMS"] }
            else if names.count == 1, let only = names.first { return "app:" + only }
        }
        if !bundles.isEmpty, bundles.allSatisfy(KitBrowsers.isBrowser),
           let first = m.sites.lazy.filter({ !$0.isEmpty }).map(siteKey).first(where: { !$0.isEmpty }) {
            return "site:" + first
        }
        guard bundles.count == 1, let bundle = bundles.first else { return nil }
        return bundle
    }

    /// The site a card is keyed on: the registrable domain ("www.reddit.com", "old.reddit.com" → "reddit.com";
    /// "bbc.co.uk" keeps its two-part suffix), with known aliases joined ("twitter.com", "mobile.twitter.com" → "x.com").
    /// Hosts whose subdomains are separate products stay apart: on google.com, apple.com, microsoft.com, live.com,
    /// amazon.com and github.io the product host is kept ("mail.google.com", "docs.google.com", "google.com" are three
    /// sites), so Gmail and a Google search aren't one card.
    public static func siteKey(_ raw: String) -> String {
        let host = KitBrowsers.host(raw).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return host }
        // claude/catchup-1003: Outlook on the web is one site under every host Microsoft serves it from (outlook.office.com,
        // outlook.office365.com, outlook.live.com, outlook.cloud.microsoft), never a "cloud.microsoft" card beside an
        // "outlook.office.com" one.
        if labels.first == "outlook", outlookHosts.contains(labels.dropFirst().joined(separator: ".")) { return "outlook.com" }
        let twoPart: Set<String> = ["co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.jp", "co.nz", "com.br",
                                    "co.in", "com.mx", "co.kr", "com.cn", "com.tw", "com.sg", "co.za"]
        let suffixCount = twoPart.contains(labels.suffix(2).joined(separator: ".")) ? 2 : 1
        guard labels.count > suffixCount else { return host }
        let registrable = labels.suffix(suffixCount + 1).joined(separator: ".")
        let aliases = ["twitter.com": "x.com", "t.co": "x.com", "youtu.be": "youtube.com", "fb.com": "facebook.com",
                       "instagr.am": "instagram.com", "redd.it": "reddit.com"]
        if let alias = aliases[registrable] { return alias }
        let productHosts: Set<String> = ["google.com", "apple.com", "microsoft.com", "live.com", "amazon.com", "github.io", "office.com"]
        if productHosts.contains(registrable), labels.count > suffixCount + 1 {
            let sub = labels[labels.count - suffixCount - 2]
            return sub == "www" ? registrable : sub + "." + registrable
        }
        return registrable
    }
    static let outlookHosts: Set<String> = ["office.com", "office365.com", "live.com", "cloud.microsoft", "com"]
    /// A site card's name: "X" for x.com, "Outlook" for Outlook on the web, else the site.
    static let siteNames = ["x.com": "X", "outlook.com": "Outlook"]

    /// The site of a browser card, else nil.
    static func site(_ m: MomentSlice) -> String? {
        guard let key = situation(m), key.hasPrefix("site:") else { return nil }
        return String(key.dropFirst(5))
    }

    /// The card's title: the app's friendly name ("Texts", "ChatGPT", "Terminal"); a site card's site ("X", "reddit.com"). A moment over several apps names them ("Terminal, Ghostty"). Never a
    /// conversation, a raw window title or a withheld one.
    public static func title(_ members: [MomentSlice]) -> String {
        guard let first = members.first else { return "Activity" }
        if let site = site(first) { return siteNames[site] ?? site }
        let bundles = Set(members.flatMap { $0.bundles.filter { !$0.isEmpty } })
        if bundles.count == 1, let only = bundles.first, let friendly = friendlyNames[only] { return friendly }
        if bundles.count == 1, let name = FocusListLayout.appName(first) { return name }
        var names: [String] = []
        for m in members { for n in FocusListLayout.appNames(m) where !names.contains(n) { names.append(n) } }
        names = names.map { $0 == "Messages" ? "Texts" : $0 }
        if names.isEmpty { return first.primaryApp ?? (first.subject.isEmpty ? "Activity" : first.subject) }
        return names.count > 2 ? names.prefix(2).joined(separator: ", ") + " +\(names.count - 2)" : names.joined(separator: ", ")
    }

    /// claude/messages2-1003 (owner 10/3, "earlier texts are missing from What happened"): the card's details page is the
    /// whole card, not its newest member: one slice under the anchor's ID with every member's actions (oldest first),
    /// the card's span, its title and its summary lines (`bullets`, as the card shows them). A one-member card is that
    /// member unchanged. Display only: actions on the page (Forget, Summarize Now) still name the anchor moment.
    public static func detailMoment(_ anchor: MomentSlice, members: [MomentSlice]) -> MomentSlice {
        let all = members.contains { $0.id == anchor.id } ? members : [anchor] + members
        guard all.count > 1 else { return anchor }
        let ordered = all.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        var ids: [String] = [], seen = Set<String>()
        for m in ordered { for id in m.actionIDs where seen.insert(id).inserted { ids.append(id) } }
        func union(_ xs: [[String]]) -> [String] {
            var out: [String] = []
            for x in xs.joined() where !out.contains(x) { out.append(x) }
            return out
        }
        let ready = all.filter { $0.summary.isReady && $0.bullets.contains { !$0.correction } }
        let lines = bullets(all), fixes = corrections(all)
        let summary: MomentSummaryState = ready.isEmpty ? anchor.summary
            : .ready(generatedAt: ready.compactMap { if case .ready(let at, _) = $0.summary { return at }; return nil }.max(),
                     local: ready.allSatisfy { if case .ready(_, let local) = $0.summary { return local }; return false })
        let pending = all.contains { if case .pending = $0.currentSummaryState { return true }; return false }
        var m = MomentSlice(id: anchor.id, dayKey: anchor.dayKey, start: ordered.map(\.start).min() ?? anchor.start,
                            end: ordered.map(\.end).max() ?? anchor.end, title: title(all), subject: anchor.subject,
                            firstBullet: lines.first?.text ?? anchor.firstBullet, bullets: lines + fixes,
                            apps: union(ordered.map(\.apps)), primaryBundle: anchor.primaryBundle, bundles: union(ordered.map(\.bundles)),
                            sites: union(ordered.map(\.sites)), actionIDs: ids, actionCount: ordered.reduce(0) { $0 + $1.actionCount },
                            clusters: ordered.flatMap(\.clusters), summary: summary, hasCorrection: all.contains(where: \.hasCorrection),
                            primaryApp: anchor.primaryApp, bundleActionCounts: nil, timeZoneID: anchor.timeZoneID,
                            stale: !ready.isEmpty && pending, live: anchor.live)
        m.currentSummary = pending ? .pending : summary
        m.byCode = !ready.isEmpty && ready.allSatisfy(\.byCode)
        return m
    }

    /// The header's time (owner 10/2, final): the latest time only, "5:24 PM" (the bracket shows the range).
    public static func latestTime(_ members: [MomentSlice], timeZone: TimeZone) -> String {
        guard let end = members.map(\.end).max() else { return "" }
        return DaydreamFormat.time(end, timeZone)
    }
    /// "5:14–5:22 PM": from the first member's start to the last member's end.
    public static func range(_ members: [MomentSlice], timeZone: TimeZone) -> String {
        guard let start = members.map(\.start).min(), let end = members.map(\.end).max() else { return "" }
        return DaydreamFormat.range(start, end, timeZone)
    }

    /// Names a filler line may carry besides its duration.
    static func names(_ m: MomentSlice) -> [String] { m.apps + [m.primaryApp, m.subject, m.title].compactMap { $0 } }

    /// One member's summary lines: the note's bullets (not corrections), else its sends by code; nothing when every
    /// line only says how long ("~1 min").
    static func lines(_ m: MomentSlice) -> [MomentBullet] {
        let generated = m.bullets.filter { !$0.correction }
        let lines = m.summary.isReady && !generated.isEmpty ? generated : m.lines.map { MomentBullet(text: $0) }
        return lines.contains { !MomentSummaryWorth.isFiller($0.text, names: names(m)) } ? lines : []
    }

    // MARK: Writing, not reading (owner 10/2)

    /// Actions that write: typing, a send, a filled field, Return (a send, a submitted search, a command run).
    public static let writingKinds: Set<String> = ["keyboard.text_input", "message.sent", "keyboard.fill", "keyboard.submit"]
    /// The IDs of the actions that wrote.
    public static func writingIDs(_ actions: [CanonicalAction]) -> Set<String> {
        Set(actions.filter { writingKinds.contains($0.kind) }.map(\.id))
    }
    /// A line about reading or viewing: "Read Sam's reply", "Viewed the chat", "Looked at github.com".
    static let readingVerbs = ["read ", "viewed ", "looked at ", "looked over ", "looked through ", "browsed ", "opened ", "scrolled ",
                               "checked ", "saw ", "watched ", "reviewed ", "skimmed ", "visited ", "switched ", "worked in ", "on a call"]
    public static func isReading(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        return readingVerbs.contains { t.hasPrefix($0) } || t == "read" || t == "viewed"
    }
    /// Whether a summary line is about writing: with the actions read, whether it cites a typed, sent or drafted action;
    /// before that (or for a line that cites none), by its words.
    public static func writes(_ b: MomentBullet, writingIDs: Set<String>?) -> Bool {
        if let ids = writingIDs, !b.actionIDs.isEmpty { return b.actionIDs.contains(where: ids.contains) }
        return !isReading(b.text)
    }

    /// The left column's bullets: every member's summary lines, newest member first, one per conversation or action. Only
    /// writing (typed, sent, drafted) when the card wrote anything; reading lines only for a card with no writing at all.
    /// claude/summary-1003 (owner): across members too, code's place-only lines ("Typed a draft in Ghostty.", "Wrote code in
    /// Ghostty.") only when no line says more, each line once, at most about 4, the most informative.
    public static func bullets(_ members: [MomentSlice], writingIDs: Set<String>? = nil) -> [MomentBullet] {
        let all = members.flatMap(lines)
        let written = all.filter { writes($0, writingIDs: writingIDs) }
        return SummaryLines.tidy(written.isEmpty ? all : written) { $0.text }
    }
    /// The person's corrections, after the bullets.
    public static func corrections(_ members: [MomentSlice]) -> [MomentBullet] { members.flatMap { $0.bullets.filter(\.correction) } }
    /// Whether the card has a summary to show. Without one, the left column is the condensed What happened.
    public static func hasSummary(_ members: [MomentSlice]) -> Bool { !bullets(members).isEmpty }

    /// The collapsed card's line on the right: the newest written summary line (else the newest line); without a
    /// summary, "Read texts with Q7." for Messages or how long the app was used ("Worked in Terminal for 5 minutes.").
    /// claude/livefix-1004 (owner, live test 10/3): the newest member's ask leads, in quotes, until that member's note has
    /// a line (`MomentSubtitle.shownPrompt`), as the row's ask preview did before cards: an AI or terminal moment still
    /// going (no note yet) showed an older moment's summary, so what was just asked never appeared on the card.
    public static func collapsedLine(_ members: [MomentSlice]) -> String {
        if let newest = members.first, let ask = MomentSubtitle.shownPrompt(newest) { return PromptLine.open + ask + PromptLine.close }
        if let line = bullets(members).first?.text { return line }
        guard let start = members.map(\.start).min(), let end = members.map(\.end).max() else { return "" }
        if let read = readingSentence(members, names: members.compactMap(FocusListLayout.recordedConversation)) { return read }
        return workedSentence(app: title(members), from: start, to: end)
    }

    /// A Messages card with no writing: "Read texts with Q7 and Alex." An email card with no writing: "Read 'Demo
    /// feedback'." (email-1003, from the opened emails' titles: `emailReadingSentence`). nil for other apps.
    static func readingSentence(_ members: [MomentSlice], names: [String]) -> String? {
        let bundles = Set(members.flatMap { $0.bundles.filter { !$0.isEmpty } })
        if let email = emailReadingSentence(members) { return email }
        guard bundles == ["com.apple.MobileSMS"] else { return nil }
        var unique: [String] = []
        for n in names where !unique.contains(where: { $0.lowercased() == n.lowercased() }) { unique.append(n) }
        if unique.isEmpty { return "Read texts." }
        let list = unique.count <= 2 ? unique.joined(separator: " and ") : unique.dropLast().joined(separator: ", ") + " and " + unique.last!
        return "Read texts with \(list)."
    }

    /// email-1003 (owner decision 2026-10-03): an email card (Mail, or only webmail sites) with no writing names the
    /// emails it opened: "Read 'Demo feedback'.", "Read 'Demo feedback' and 'Startup credits'.". Folders ("Inbox") name no
    /// email; nil when no member's title is an email's subject.
    static func emailReadingSentence(_ members: [MomentSlice]) -> String? {
        let bundles = Set(members.flatMap { $0.bundles.filter { !$0.isEmpty } })
        let sites = Set(members.flatMap(\.sites).filter { !$0.isEmpty })
        let mail = !bundles.isEmpty && bundles.isSubset(of: EmailTitle.mailApps)
        let webmail = !sites.isEmpty && bundles.isSubset(of: ["com.google.Chrome"])
            && sites.allSatisfy { BrowserSites.emailHost(host: BrowserSites.host(of: $0.contains("://") ? $0 : "https://" + $0) ?? $0) }
        guard mail || webmail else { return nil }
        var subjects: [String] = []
        for m in members.sorted(by: { $0.start < $1.start }) {
            // A moment named by its thread ("Email about Demo feedback", "Email with Sam about Demo feedback") or its title.
            var name = m.subject
            if name.hasPrefix("Email about ") { name = String(name.dropFirst("Email about ".count)) }
            else if name.hasPrefix("Email with "), let about = name.range(of: " about ") { name = String(name[about.upperBound...]) }
            else if name.hasPrefix("Email to ") || name.hasPrefix("Email with ") { continue }
            guard case .email(let subject, _, _)? = EmailTitle.kind(name), !subject.isEmpty,
                  TypedSecretScrubber.sensitiveSubject(subject) == nil,
                  !subjects.contains(where: { $0.lowercased() == subject.lowercased() }) else { continue }
            subjects.append(subject)
        }
        guard let first = subjects.first else { return nil }
        if subjects.count == 1 { return EmailLines.read(subject: first) + "." }
        let quoted = subjects.prefix(3).map { "'" + $0 + "'" }
        let list = quoted.count == 2 ? quoted.joined(separator: " and ") : quoted.dropLast().joined(separator: ", ") + " and " + quoted.last!
        return "Read " + list + (subjects.count > 3 ? " and more." : ".")
    }

    /// "Worked in Terminal for 5 minutes."
    public static func workedSentence(app: String, from start: Date, to end: Date) -> String {
        "Worked in \(app) for \(DaydreamFormat.spokenDuration(from: start, to: end))."
    }

    /// The side panel's title: "Conversations" for Messages only; every other card "Windows and pages".
    public static func panelTitle(_ members: [MomentSlice]) -> String {
        Set(members.flatMap { $0.bundles.filter { !$0.isEmpty } }) == ["com.apple.MobileSMS"] ? "Conversations" : "Windows and pages"
    }

    /// One side-panel row: the app's icon (a site's favicon for a page) and the conversation, person or page name.
    public struct PanelRow: Equatable, Identifiable {
        public let name: String, bundle: String, site: String
        /// The person typed, sent or drafted there.
        public let wrote: Bool
        public var id: String { bundle + "|" + site + "|" + name.lowercased() }
    }

    /// The side panel's rows, most recent first: every conversation, window or page the person wrote in; the ones only
    /// read only when nothing was written. Messages' recorded conversations come from the members, the rest from the
    /// windows and pages the actions touched (`FocusListExpanded.allSources`). The card's own app name only when
    /// nothing else is known. The panel shows `panelLimit`; the rest are behind Show details.
    public static func panelRows(_ members: [MomentSlice], sources: [FocusListSource], writingIDs: Set<String>) -> [PanelRow] {
        var seen = Set<String>(), rows: [PanelRow] = []
        let app = title(members).lowercased()
        func add(_ name: String?, bundle: String, site: String, wrote: Bool) {
            guard let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty,
                  !n.contains(MomentHistoryCondense.withheldTitle),
                  !["messages", "texts", "new message", app].contains(n.lowercased()) else { return }
            if seen.insert(n.lowercased()).inserted { rows.append(PanelRow(name: n, bundle: bundle, site: site, wrote: wrote)) }
            else if wrote, let i = rows.firstIndex(where: { $0.name.lowercased() == n.lowercased() }), !rows[i].wrote {
                rows[i] = PanelRow(name: rows[i].name, bundle: rows[i].bundle, site: rows[i].site, wrote: true)
            }
        }
        for m in members {
            let wrote = m.actionIDs.contains(where: writingIDs.contains) || !(m.live?.sends ?? []).isEmpty
            add(FocusListLayout.recordedConversation(m), bundle: m.primaryBundle ?? m.bundles.first ?? "", site: "", wrote: wrote)
        }
        for s in sources { add(s.isWeb && s.title == s.site ? s.site : s.title, bundle: s.bundle, site: s.site, wrote: s.wrote) }
        if rows.isEmpty, let only = sources.first { rows.append(PanelRow(name: only.title, bundle: only.bundle, site: only.site, wrote: only.wrote)) }
        let written = rows.filter(\.wrote)
        return written.isEmpty ? rows : written
    }
    /// page-links-1003: the page a side-panel row names (the source it came from), for its click; nil for a window or a
    /// conversation.
    public static func panelSource(_ row: PanelRow, sources: [FocusListSource]) -> FocusListSource? {
        guard !row.site.isEmpty else { return nil }
        return sources.first { s in
            s.isWeb && s.site == row.site && s.bundle == row.bundle
                && (s.isWeb && s.title == s.site ? s.site : s.title).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == row.name.lowercased()
        }
    }
    /// The panel shows at most this many; its link opens the details page for the rest.
    public static let panelLimit = 3
    public static func shownRows(_ rows: [PanelRow]) -> [PanelRow] { Array(rows.prefix(panelLimit)) }
    /// The panel's link, which opens the card's details page: "Show more" past 3 rows, else "Show details".
    public static func panelLink(rows: Int) -> String { rows > panelLimit ? "Show more" : "Show details" }

    /// The left column without a summary: the condensed What happened as sentences, no times. A noise-only card is one
    /// line over the card's range: "Worked in Terminal for 5 minutes."
    public static func sentences(_ lines: [MomentDetailEntry], start: Date, end: Date, members: [MomentSlice] = [],
                                 names: [String] = []) -> [String] {
        if lines.allSatisfy(\.quiet), let read = readingSentence(members, names: names) { return [read] }
        if lines.count == 1, lines[0].quiet { return [workedSentence(app: appOf(lines[0]), from: start, to: end)] }
        // Owner 10/3: Messages lines say "Texted Jamie." ("Texted someone." with no name); the same line in a row says it
        // once ("Texted Sam (3 times).").
        var folded: [(MomentDetailEntry, Int)] = []
        for e in lines {
            if let m = e.message, let last = folded.last, last.0.message == m { folded[folded.count - 1].1 += 1 }
            else { folded.append((e, 1)) }
        }
        return folded.map { e, count in
            if let m = e.message { return MessagesTypedFold.sentence(m, times: count) }
            let app = appOf(e)
            if e.quiet, let first = e.first, let last = e.last { return workedSentence(app: app, from: first, to: last) }
            let times = e.detail.components(separatedBy: " · ").first { $0.hasSuffix(" times") }.flatMap { Int($0.dropLast(6)) } ?? 1
            if e.detail.contains(TypedWords.ranCommandLabel) {
                return (times == 1 ? TypedWords.ranCommandLabel : "Ran \(times) commands") + " in \(app)."
            }
            if !e.sends.isEmpty { return "Sent to \(e.sends.joined(separator: ", ")) in \(e.title == app ? app : e.title)." }
            if !e.typed.isEmpty || e.capturedWordingUnavailable { return "Typed in \(e.title)." }
            if e.isWeb { return "Visited \(e.title == e.host ? e.host : e.title)." }
            let what = e.detail.components(separatedBy: " · ").filter { !$0.hasSuffix(" times") && !$0.contains("\u{2013}") && $0 != e.app && $0 != e.host }.last
            return [what, e.title == app ? nil : "in " + e.title].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                .nonEmpty.map { $0 + (times > 1 ? " (\(times) times)." : ".") } ?? e.title + "."
        }
    }
    static func appOf(_ e: MomentDetailEntry) -> String {
        let app = e.app.isEmpty ? (e.host.isEmpty ? "an app" : e.host) : e.app
        return app == "Messages" ? "Texts" : app
    }

    /// Copy Summary for the whole card: its title and range, then every member's bullets and corrections.
    public static func copyText(_ members: [MomentSlice], timeZone: TimeZone) -> String? {
        let bullets = bullets(members), corrections = corrections(members)
        guard !bullets.isEmpty || !corrections.isEmpty else { return nil }
        return ([title(members) + " · " + range(members, timeZone: timeZone)] + bullets.map { "• " + $0.text }
                + corrections.map { "Correction: " + $0.text }).joined(separator: "\n")
    }

    // MARK: Before the summary (owner 10/2)

    /// Whether a summary is on its way for this card: a member is pending and its job is queued or running (summaries on
    /// or getting ready, and the queue has it). Not when summaries are off or failed, or it won't be written.
    public static func summaryPending(_ members: [MomentSlice], phase: SummaryPhase, queue: SummaryQueue?) -> Bool {
        switch phase { case .off, .failed: return false; default: break }
        return members.contains { m in
            guard case .pending = m.currentSummaryState else { return false }
            guard let queue else { return true }
            return queue.writing.contains(m.id) || queue.open.contains(m.id) || m.end > queue.lookedAt
        }
    }
    /// The left column's header (owner 10/2, final): "Summary" over a summary; "Summary pending" (in the model's violet)
    /// while one is queued or running, so the card doesn't jump when it arrives; "What you wrote" over quoted words when
    /// no summary is coming, so raw words are never presented as a summary; nil over a card with neither.
    public static func header(bullets: Bool, quotes: Bool, pending: Bool) -> String? {
        if bullets { return "Summary" }
        if pending { return "Summary pending" }
        return quotes ? "What you wrote" : nil
    }
    /// The left column before and after the summary (owner 10/3): a written note's bullets under "Summary"; until one
    /// exists, the stitched quotes (`CapturedStitch`) under "Summary pending" (violet) while one is on its way, else
    /// "What you wrote", even when the moment has sends by code ("Texted Jamie": that stays the collapsed line);
    /// without quotes, the sends by code under "Summary" as before. Raw words are never under a "Summary" header.
    ///
    /// claude/messages2-1003 (owner 10/3: "texting is nuanced and contextual"): a Texts card keeps the original texts. Its
    /// Summary is each conversation (`textThreads`: the name or number, then the texts sent, verbatim, newest first, about
    /// 3 each and "+N more"), never a model paraphrase of them; a model line only as a short gist over a conversation with
    /// more texts than shown. Bullets stay only for texts whose words couldn't be opened.
    public struct LeftColumn: Equatable {
        public let header: String?; public let bullets: [MomentBullet]; public let quotes: [String]
        public var threads: [TextThread] = []
    }
    public static func leftColumn(_ members: [MomentSlice], previews: [OwnerSourcePreview], writingIDs: Set<String>? = nil,
                                  pending: Bool, compose: [String: ComposeLine] = [:], actions: [CanonicalAction] = []) -> LeftColumn {
        if isTexts(members) {
            var threads = textThreads(previews: previews, compose: compose, actions: actions)
            if !threads.isEmpty {
                let all = bullets(members, writingIDs: writingIDs)
                let covered = Set(threads.flatMap(\.actionIDs))
                for i in threads.indices where threads[i].more > 0 {
                    threads[i].gist = all.first { !Set($0.actionIDs).isDisjoint(with: threads[i].actionIDs) }?.text
                }
                let typedIDs = Set(actions.filter { $0.kind == "keyboard.text_input" }.map(\.id))
                let rest = all.filter { b in b.actionIDs.contains { typedIDs.contains($0) && !covered.contains($0) } }
                return LeftColumn(header: "Summary", bullets: rest, quotes: [], threads: threads)
            }
        }
        let noted = members.contains { $0.summary.isReady && $0.bullets.contains { !$0.correction } } && !bullets(members, writingIDs: writingIDs).isEmpty
        let quotes = noted ? [] : CapturedStitch.messages(CapturedStitch.fragments(previews))
        let shown = quotes.isEmpty ? bullets(members, writingIDs: writingIDs) : []
        return LeftColumn(header: header(bullets: !shown.isEmpty, quotes: !quotes.isEmpty, pending: pending), bullets: shown, quotes: quotes)
    }
    // MARK: Texts keep their words (claude/messages2-1003, owner 10/3)

    /// One conversation on a Texts card.
    public struct TextThread: Equatable {
        /// The verified conversation: its name, else its formatted number or address (`ComposeLine.name`, the unit's own);
        /// nil when code read neither ("Other texts": never another conversation's name).
        public let name: String?
        /// The texts sent, verbatim (whitespace collapsed), newest first. A text typed in pieces is one text.
        public let texts: [String]
        /// Every typed action the conversation's texts and unsent pieces cite.
        public let actionIDs: [String]
        /// The newest text's time (conversations are ordered by it, newest first).
        public let latest: String
        /// A short model line, only over a conversation with more texts than shown.
        public var gist: String?
        public init(name: String?, texts: [String], actionIDs: [String], latest: String, gist: String? = nil) {
            self.name = name; self.texts = texts; self.actionIDs = actionIDs; self.latest = latest; self.gist = gist
        }
        public var title: String { name ?? FocusAppCard.otherTexts }
        public var shown: [String] { Array(texts.prefix(FocusAppCard.threadLimit)) }
        public var more: Int { max(0, texts.count - FocusAppCard.threadLimit) }
    }
    /// Texts shown per conversation; the rest are "+N more".
    public static let threadLimit = 3
    public static let otherTexts = "Other texts"
    public static func moreLine(_ n: Int) -> String? { n > 0 ? "+\(n) more" : nil }
    /// A Texts (Messages) card.
    public static func isTexts(_ members: [MomentSlice]) -> Bool {
        members.contains { $0.bundles.contains("com.apple.MobileSMS") || $0.apps.contains("Messages") || $0.primaryApp == "Messages" }
    }
    /// The card's conversations from the owner's source previews (the words, opened under the owner grant) and the typed
    /// rows' compose lines (who, metadata only). A text is a preview a send or Return ended; the unsent pieces before it
    /// in the same conversation are its start (`MessagesTypedFold.stitch`). A draft never sent is not shown. Each text is
    /// its own line: two texts never join.
    public static func textThreads(previews: [OwnerSourcePreview], compose: [String: ComposeLine], actions: [CanonicalAction]) -> [TextThread] {
        let byID = Dictionary(actions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        struct Open { var name: String?; var texts: [(at: String, text: String)] = []; var ids: [String] = []; var pending = ""; var pendingAt = "" }
        var open: [String: Open] = [:], order: [String] = []
        for p in previews.sorted(by: { ($0.at, $0.id) < ($1.at, $1.id) }) where !p.parts.isEmpty && !p.isWithheld {
            guard let last = p.actionIDs.last else { continue }
            let a = byID[last]
            guard a.map({ MessagesTypedFold.applies(bundle: $0.bundle, app: $0.app) }) ?? p.lead.hasSuffix(" in Messages") else { continue }
            let line = compose[last]
            // The preview's lead names the unit's own code-read recipient ("Submitted text to Sam in Messages").
            let place = CapturedStitch.place(p.lead)
            let led = place.hasPrefix(" to ") && place.hasSuffix(" in Messages") ? String(place.dropFirst(4).dropLast(12)) : ""
            let name = line?.name.flatMap { $0.hasPrefix("#") ? nil : MessagesTypedFold.name($0) } ?? a.flatMap { MessagesTypedFold.name($0.title) }
                ?? MessagesTypedFold.name(led)
            let key = name?.lowercased() ?? ""
            if open[key] == nil { open[key] = Open(name: name); order.append(key) }
            let words = p.parts.map(\.text).reduce("") { MessagesTypedFold.join($0, $1) }
            let sent = p.state == "submitted" || p.sealedByReturn || line?.sent == true || line?.sealedByReturn == true
            open[key]!.ids += p.actionIDs
            // Pieces further apart than a message are not one.
            if !open[key]!.pending.isEmpty, let then = timestamp(open[key]!.pendingAt), let now = timestamp(p.at),
               now.timeIntervalSince(then) > MessagesTypedFold.pieceWindow { open[key]!.pending = "" }
            if open[key]!.pending.isEmpty { open[key]!.pendingAt = p.at }
            let whole = MessagesTypedFold.stitch(open[key]!.pending, words)
            if sent {
                let text = whole.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !text.isEmpty { open[key]!.texts.append((p.at, text)) }
                open[key]!.pending = ""
            } else { open[key]!.pending = whole }
        }
        return order.compactMap { k -> TextThread? in
            let o = open[k]!
            guard let newest = o.texts.last else { return nil }
            return TextThread(name: o.name, texts: o.texts.reversed().map(\.text), actionIDs: o.ids, latest: newest.at)
        }.sorted { ($0.latest, $0.name == nil ? 0 : 1) > ($1.latest, $1.name == nil ? 0 : 1) }
    }

    /// A quoted message is cut to about this many characters (2 lines); opened, to `openQuoteLimit` (4 lines).
    public static let quoteLimit = 90
    public static let openQuoteLimit = 200
    /// The details page shows each message whole, up to this many characters.
    public static let detailQuoteLimit = 600
    /// "“Hey are we still on for dinner tonight? I was thinking we could move it to 7:30 if…”": cut at a word boundary.
    public static func quote(_ text: String, limit: Int = quoteLimit) -> String {
        guard text.count > limit else { return "\u{201C}" + text + "\u{201D}" }
        var cut = String(text.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 { cut = String(cut[..<space]) }
        while let last = cut.unicodeScalars.last, CharacterSet(charactersIn: " ,;:-–—").contains(last) { cut = String(cut.unicodeScalars.dropLast()) }
        return "\u{201C}" + cut + "\u{2026}\u{201D}"
    }
    /// Summarize Now in the card's footer (owner 10/3).
    public static let summarizeTitle = "Summarize Now"
    public static let summarizingTitle = "Summarizing\u{2026}"
    /// The members Summarize Now writes: each with no summary worth showing that the existing Summarize Now can write
    /// (`MomentActions.canSummarizeNow`: summaries on and able to write, the moment pending or rewritable).
    /// claude/summary-fail-1003: a member without a written note counts as unsummarized even when code has lines for it
    /// (a Claude Code moment's "Asked Claude Code" send line): before, those lines hid Summarize Now from every pending
    /// terminal or AI-app card whose quotes stood under "Summary pending".
    public static func summarizeTargets(_ members: [MomentSlice], caps: MomentActions.Capabilities) -> [MomentSlice] {
        members.filter { (!$0.summary.isReady || lines($0).isEmpty) && MomentActions.canSummarizeNow($0, caps: caps) }
    }
    /// Shown while the left column is "Summary pending" or "What you wrote" and a member can be written; "Summarizing…"
    /// while one is being written; never over a summary. `bullets` and `header` are the left column's as drawn
    /// (`leftColumn`): quotes stand in for code's lines there, so code's lines alone never hide the button.
    public static func offersSummarizeNow(bullets: Bool, header: String?, targets: Int, running: Bool) -> Bool {
        guard !bullets, header == "Summary pending" || header == "What you wrote" else { return false }
        return running || targets > 0
    }
    /// The same, from the left column the card draws.
    public static func offersSummarizeNow(_ column: LeftColumn, targets: Int, running: Bool) -> Bool {
        offersSummarizeNow(bullets: !column.bullets.isEmpty, header: column.header, targets: targets, running: running)
    }

    /// Quoted messages shown before the summary; the rest are "+N earlier messages".
    public static let messageLimit = 2
    public static func earlierLine(_ count: Int) -> String? {
        count <= messageLimit ? nil : count - messageLimit == 1 ? "+1 earlier message" : "+\(count - messageLimit) earlier messages"
    }

    /// VoiceOver: "Texts, 5:14 to 5:22 PM, Texted Q7 about moving dinner to 7:30."
    public static func accessibilityLabel(_ members: [MomentSlice], timeZone: TimeZone) -> String {
        guard let start = members.map(\.start).min(), let end = members.map(\.end).max() else { return title(members) }
        return [title(members), DaydreamFormat.spokenRange(start, end, timeZone), collapsedLine(members)]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Typing interrupted (a click, a switch, a pause) leaves one message in pieces: ". still on for", "\"we could move",
/// mid-word cuts ("wanna me" + "et us there?"). Before a summary exists the card shows the message, stitched (owner 10/2).
/// Owner 10/3: a send ends its message (three texts to one person are three quotes, never one), the pieces join as typed
/// (`MessagesTypedFold.join`: a mid-word cut joins with no space), and a send whose words already hold the pieces before
/// it (the field's whole value at Return) is the message on its own.
public enum CapturedStitch {
    public struct Fragment: Equatable {
        /// The field or conversation it was typed in (the preview's lead, without its draft or send word).
        public let place: String
        public let at: String
        /// The words as captured (their own leading and trailing whitespace kept: it says whether a cut was mid-word).
        public let text: String
        /// A send was detected on it: it ends its message.
        public let sent: Bool
        public init(place: String, at: String, text: String, sent: Bool = false) {
            self.place = place; self.at = at; self.text = text; self.sent = sent
        }
    }
    static let strip = CharacterSet(charactersIn: ".,;:!?-–—…\"'“”‘’`")
    /// Trims leading punctuation and stray quotes, stray trailing quotes, and collapses whitespace.
    public static func clean(_ text: String) -> String {
        var t = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let c = t.unicodeScalars.first, strip.contains(c) { t = String(t.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces) }
        while let c = t.unicodeScalars.last, CharacterSet(charactersIn: "\"'“”‘’`").contains(c) {
            t = String(t.unicodeScalars.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return t
    }
    static func words(_ t: String) -> Int { t.split(whereSeparator: \.isWhitespace).count }
    /// A piece cut mid-word: the one before ended in a letter or digit and this one starts with one.
    static func continues(_ before: String, _ piece: String) -> Bool {
        guard let x = before.last, let y = piece.first else { return false }
        return (x.isLetter || x.isNumber) && (y.isLetter || y.isNumber)
    }
    /// One message per run of consecutive fragments typed in the same place, up to and including a send, joined on each
    /// interruption, newest first. A fragment under 3 words that a neighbour already contains is dropped (unless it
    /// continues a word cut mid-way).
    public static func messages(_ fragments: [Fragment]) -> [String] {
        let ordered = fragments.sorted { $0.at < $1.at }.filter { !clean($0.text).isEmpty }
        var runs: [[Fragment]] = []
        for f in ordered {
            if let last = runs.last?.last, last.place == f.place, !last.sent { runs[runs.count - 1].append(f) } else { runs.append([f]) }
        }
        let joined = runs.map { run -> String in
            let kept = run.enumerated().filter { i, f in
                let text = clean(f.text)
                guard words(text) < 3 else { return true }
                if i > 0, continues(run[i - 1].text, f.text) { return true }
                if i + 1 < run.count, continues(f.text, run[i + 1].text) { return true }
                let low = text.lowercased()
                let neighbours = [i > 0 ? run[i - 1].text : nil, i + 1 < run.count ? run[i + 1].text : nil].compactMap { $0 }.map(clean)
                return !neighbours.contains { $0.lowercased().contains(low) }
            }.map(\.element)
            var out = ""
            for (i, piece) in kept.enumerated() {
                let text = clean(piece.text)
                let midWord = i > 0 && continues(kept[i - 1].text, piece.text)
                if !midWord, words(text) < 3, clean(out).lowercased().contains(text.lowercased()) { continue }
                // A send's words that already hold everything before it are the message.
                if piece.sent, MessagesTypedFold.normalized(clean(piece.text)).contains(MessagesTypedFold.normalized(clean(out))) {
                    out = piece.text; continue
                }
                if out.isEmpty { out = piece.text; continue }
                // Cut mid-word: no space; otherwise one (a cleaned piece lost the whitespace it carried).
                out = midWord ? out + piece.text : clean(out) + " " + text
            }
            return clean(out)
        }.filter { !$0.isEmpty }
        return joined.reversed()
    }
    /// The place a preview's lead names, without its draft or send word: "Submitted text to Sam in Messages" and
    /// "Drafted text to Sam in Messages" are one conversation.
    public static func place(_ lead: String) -> String {
        for word in ["Submitted text", "Drafted text"] where lead.hasPrefix(word) { return String(lead.dropFirst(word.count)) }
        return lead
    }
    /// The fragments of the card's typing runs, from the owner's source previews. A run's parts join as typed.
    public static func fragments(_ previews: [OwnerSourcePreview]) -> [Fragment] {
        previews.filter { $0.runID != nil && !$0.parts.isEmpty }
            // claude/messages2-1003: a text Return sealed ends its message too, sent or not ("pretty good" + "home alone").
            .map { p in Fragment(place: place(p.lead), at: p.at, text: p.parts.map(\.text).reduce("") { MessagesTypedFold.join($0, $1) },
                                 sent: p.state == "submitted" || p.sealedByReturn) }
    }
}
