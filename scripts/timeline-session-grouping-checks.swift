// Timeline session grouping: which moments share one card on the day page, in what order, with what anchor and
// header, and the X/Instagram title cleanup the grouping relies on. One file for what were three (derived session
// intervals, within-block grouping, title grouping acceptance); every assertion reports. Made-up activity only.
// Usage: timeline-session-grouping [fixtures/derived-session-interval-pattern.json]
import Foundation
import CoreGraphics
import MemoryCore
import MemoryUI

var passes = 0, failures = 0
func check(_ ok: Bool, _ label: String, output: String = "") {
    print("\(ok ? "PASS" : "FAIL") \(label)\(output.isEmpty || ok ? "" : " -> " + output)")
    if ok { passes += 1 } else { failures += 1 }
}

/// A recorded interval pattern (fixtures/derived-session-interval-pattern.json) replayed at three gaps.
enum DerivedIntervals {
    struct Row: Decodable, Equatable {
        let id: String, channel: String
        let startOffsetSeconds: Double, endOffsetSeconds: Double
        let actionCount: Int
        let sites: [String], bundles: [String]
    }
    struct Fixture: Decodable { let source: String, testEpoch: String; let members: [Row] }
    static func run(_ fixturePath: URL) throws {
        let fixturePath = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1])
            : URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/derived-session-interval-pattern.json")
        let data = try Data(contentsOf: fixturePath)
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ s: String) -> Date { fractional.date(from:s) ?? plain.date(from:s)! }
        let epoch = date(fixture.testEpoch)
        let members = fixture.members.map {
            TimelineSessionMember(id:$0.id, dayKey:"2001-01-01", start:epoch.addingTimeInterval($0.startOffsetSeconds), end:epoch.addingTimeInterval($0.endOffsetSeconds),
                                  channel:TimelineSessionChannel.recorded(sites:$0.sites,bundles:$0.bundles), detail:$0)
        }
        check(members.allSatisfy { $0.channel?.rawValue == $0.detail.channel }, "Derived recorded-pattern metadata routes every selected member without title guesses")
        for gap in [60.0, 300.0, 1800.0] {
            let at = " (gap \(Int(gap))s)"
            let groups = TimelineSessionGrouping.group(members, maximumGap:gap)
            check(groups.count == 4, "Derived interval pattern must make X + Instagram + two Texts containers" + at)
            check(groups.filter { $0.channel == .x }.map { $0.members.count } == [3], "X overlapping Home interval retains both post records" + at)
            check(groups.filter { $0.channel == .instagram }.map { $0.members.count } == [2], "Instagram labels 3.118 sec apart join" + at)
            check(groups.filter { $0.channel == .messages }.map { $0.members.count } == [3,4], "Texts separate at 75m22s gap" + at)
            let flattened = groups.flatMap(\.members)
            check(flattened.count == members.count && Set(flattened.map(\.id)) == Set(members.map(\.id)), "Every anonymous member ID retained exactly once" + at)
            check(flattened.allSatisfy { child in members.first { $0.id == child.id }?.detail == child.detail }, "Complete fixture detail retained" + at)
            check(flattened.reduce(0) { $0 + $1.detail.actionCount } == members.reduce(0) { $0 + $1.detail.actionCount }, "All source action counts retained, no synthetic summary" + at)
            check(groups.allSatisfy { group in group.members.map(\.id) == members.filter { x in group.members.contains { $0.id == x.id } }.map(\.id) }, "Fixture child display order retained" + at)
            let twice = TimelineSessionGrouping.group(flattened,maximumGap:gap)
            check(twice.map(\.id) == groups.map(\.id) && twice.map { $0.members.map(\.id) } == groups.map { $0.members.map(\.id) }, "Idempotent display grouping" + at)
        }
        check(TimelineSessionChannel.recorded(sites:["www.instagram.com"],bundles:["com.google.Chrome"]) == .instagram,"Recorded www host normalizes")
        check(TimelineSessionChannel.recorded(sites:["https://www.instagram.com/"],bundles:["com.google.Chrome"]) == .instagram,"Recorded URL normalizes")
        check(TimelineSessionChannel.recorded(sites:["x.com","twitter.com"],bundles:["com.google.Chrome"]) == .x,"Known X aliases share display channel")
        check(TimelineSessionChannel.recorded(sites:["x.com","instagram.com"],bundles:["com.google.Chrome"]) == nil,"Derived two-site pattern must not choose first site")
        check(TimelineSessionChannel.recorded(sites:[],bundles:["com.apple.MobileSMS"]) == .messages,"Texts channel needs exact app identity")
        check(TimelineSessionChannel.recorded(sites:[],bundles:["com.apple.MobileSMS","com.google.Chrome"]) == nil,"Mixed-app record does not infer one conversation")
    }
}

/// Grouping inside one existing block: contacts, aliases, Settings, X, order, identity, anchors and the layout cache.
enum LocalBlock {
    struct Detail: Equatable { let title: String; let actions: [String] }
    typealias Member = TimelineSessionMember<Detail>
    static func run() {
        func member(_ id: String, _ start: Double, _ end: Double, _ channel: TimelineSessionChannel?,
                    _ person: String? = nil, title: String = "Fictional activity", alias: Bool = true, day: String = "2001-01-01") -> Member {
            Member(id: id, dayKey: day, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end), channel: channel,
                   detail: Detail(title: title, actions: [id + ":source-action"]), conversation: person, allowsGenericAlias: alias)
        }
        func group(_ rows: [Member], _ block: String = "fictional-block") -> [TimelineSession<Detail>] {
            TimelineSessionGrouping.group(rows, withinSection: true, sectionID: block)
        }
        let named = member("read", 10, 15, .messages, "Avery Example")
        let generic = member("generic", 16, 17, .messages)
        let typed = member("draft", 18, 19, .messages, "Avery Example", title: "Fictional thank-you draft")
        let conversation = group([typed, generic, named])
        check(conversation.count == 1 && conversation[0].members.count == 3, "Same recorded conversation and unambiguous generic alias share one card")
        check(conversation[0].label == "Texts with Avery Example", "Card header names recorded identity")
        check(conversation[0].start == named.start && conversation[0].end == typed.end, "Full observed range retained")
        check(conversation[0].members.map(\.id) == ["draft", "generic", "read"], "Children latest observed first")
        check(conversation[0].members.map(\.detail).contains(typed.detail), "Typed draft detail retained verbatim, never merged")
        let other = member("other", 20, 21, .messages, "Jordan Sample")
        let ambiguous = group([named, generic, typed, other])
        check(ambiguous.count == 3, "Different contacts and ambiguous generic remain three cards")
        check(ambiguous.allSatisfy { !($0.members.contains { $0.id == "other" } && $0.members.contains { $0.id == "draft" }) }, "No false merge across contacts")
        check(ambiguous.first { $0.members.contains { $0.id == "generic" } }?.conversation == nil, "Ambiguous alias gains no invented recipient")
        let unknown = member("unreadable-name", 22, 23, .messages, nil, alias: false)
        check(group([named, unknown]).count == 2, "Unrecognized non-generic identity is not a generic alias")
        let caseAlias = member("case", 24, 25, .messages, "AVERY EXAMPLE")
        check(group([named, caseAlias]).count == 1, "Exact case-normalized recorded name shares identity")
        let groupChat = member("group-chat", 26, 27, .messages, "Avery Example, Jordan Sample")
        check(group([named, groupChat]).count == 2, "Group conversation does not collapse into first participant")
        let settingsA = member("settings-a", 100, 101, .systemSettings)
        let settingsB = member("settings-b", 900, 901, .systemSettings)
        check(group([settingsA, settingsB]).count == 1, "System Settings groups throughout existing block, beyond nearby gap")
        check(group([settingsA, settingsB])[0].label == "System Settings", "Settings header stays concrete")
        let xA = member("x-search", 30, 40, .x, title: "Fictional search for lanterns")
        let xB = member("x-post", 45, 50, .x, title: "Fictional post about cups")
        let x = group([xA, xB])
        check(x.count == 1 && x[0].members.count == 2, "Same X channel shares one presentation card")
        check(Set(x[0].members.map(\.detail.title)).count == 2, "Distinct searches/posts retain their own subjects")
        check(x[0].members.flatMap(\.detail.actions) == ["x-post:source-action", "x-search:source-action"], "All source actions retained")
        let oldLong = member("old-long", 1, 200, nil)
        let newShort = member("new-short", 150, 160, nil)
        check(group([newShort, oldLong]).first?.members.first?.id == "old-long", "Sort by latest persisted activity, not moment start")
        let mix = [xA, typed, settingsA, xB, generic, named]
        let result = group(mix)
        check(result.map(\.latestObserved) == result.map(\.latestObserved).sorted(by: >), "Groups latest descending")
        check(group(Array(mix.reversed())).map(\.id) == result.map(\.id), "Callback/input order does not shuffle groups")
        check(group(Array(mix.reversed())).map { $0.members.map(\.id) } == result.map { $0.members.map(\.id) }, "Callback/input order does not shuffle children")
        let changedTitle = member("draft", 18, 19, .messages, "Avery Example", title: "Late fictional summary title")
        check(group([named, generic, changedTitle]).map(\.id) == conversation.map(\.id), "Late summary/title arrival cannot change identity")
        check(group([named, generic, changedTitle]).map(\.latestObserved) == conversation.map(\.latestObserved), "Late summary/title arrival cannot affect latest sort")
        let laterDraft = member("draft", 18, 1000, .messages, "Avery Example")
        check(group([named, generic, laterDraft])[0].id == conversation[0].id, "Persisted activity extends range without replacing group identity")
        let olderAdded = member("older", 0, 1, .messages, "Avery Example")
        check(group([named, generic, typed, olderAdded])[0].id == conversation[0].id, "Late older child does not replace group ID")
        check(group([named])[0].id == conversation[0].id, "Eligible singleton and later grouped card share stable identity")
        check(group([named], "other-block")[0].id != group([named])[0].id, "Same conversation in separate existing blocks has separate frame identity")
        let tieA = member("a-tie", 0, 100, nil), tieB = member("b-tie", 0, 100, nil)
        check(group([tieA, tieB]).map(\.id) == group([tieB, tieA]).map(\.id), "Equal activity timestamps have deterministic tie-break")
        let nextDay = member("next-day", 10, 20, .messages, "Avery Example", day: "2001-01-02")
        check(group([named, nextDay]).count == 2, "No cross-day alias")
        let invalid = member("invalid", 100, 1, .systemSettings)
        check(group([invalid, settingsA]).count == 2, "Invalid range stays separate")
        check(group([]).isEmpty, "Empty section has no fabricated group")
        check(TimelineSessionChannel.recorded(sites: [], bundles: ["com.apple.systempreferences"]) == .systemSettings, "Settings needs recorded bundle")
        check(TimelineSessionChannel.recorded(sites: [], bundles: ["com.apple.systempreferences", "com.apple.MobileSMS"]) == nil, "Mixed apps stay separate")
        check(TimelineSessionChannel.recorded(sites: ["x.com", "instagram.com"], bundles: ["com.google.Chrome"]) == nil, "Different sites stay separate")
        let visible = CGRect(x: 0, y: 100, width: 500, height: 300)
        let frames: [String: CGRect] = ["header": CGRect(x: 0, y: 80, width: 500, height: 52),
                                       "expanded": CGRect(x: 0, y: 180, width: 500, height: 200),
                                       "offscreen": CGRect(x: 0, y: 700, width: 500, height: 52)]
        let anchor = TimelineVisibleAnchor.select(frames: frames, visible: visible, preferredIDs: ["expanded"])
        check(anchor?.id == "expanded" && anchor?.offset == 80, "Visible expanded child remains anchor over group header")
        check(TimelineVisibleAnchor.select(frames: frames, visible: visible, preferredIDs: ["offscreen"])?.id == "header", "Offscreen selection does not jump viewport")
        check(TimelineVisibleAnchor.select(frames: frames, visible: visible, preferredIDs: ["header", "expanded"])?.id == "header", "Visible preferred selection priority deterministic")
        let moved = CGRect(x: 0, y: 240, width: 500, height: 200)
        check(moved.minY - anchor!.offset == 160, "Existing anchor delta preserves child's visible offset after reordering")
        check(TimelineVisibleAnchor.select(frames: frames, visible: CGRect(x: 0, y: 0, width: 500, height: 300), preferredIDs: ["expanded"]) == nil, "Top of list keeps new latest activity visible")
        let singletonMember = member("a-singleton", 30, 40, .x)
        let singleton = group([singletonMember])[0]
        let singletonFrame = CGRect(x: 0, y: 120, width: 500, height: 52)
        let singletonFrames = [singletonMember.id: singletonFrame, singleton.id: singletonFrame]
        let transitionAnchor = TimelineVisibleAnchor.select(frames: singletonFrames, visible: visible, preferredIDs: [])
        check(transitionAnchor?.id == singleton.id, "Unselected singleton prefers stable presentation frame over original child frame")
        check(group([singletonMember, xB])[0].id == singleton.id, "Singleton's frame key survives second-member grouped transition")
        let collapsedGroupFrames = [group([singletonMember, xB])[0].id: CGRect(x: 0, y: 200, width: 500, height: 52)]
        check(collapsedGroupFrames[transitionAnchor!.id] != nil, "Collapsed new group retains old viewport anchor without forcing child open")
        check(collapsedGroupFrames[transitionAnchor!.id]!.minY - transitionAnchor!.offset == 180, "New grouped header preserves singleton's prior screen offset")
        check(TimelineVisibleAnchor.select(frames: singletonFrames, visible: visible, preferredIDs: [singletonMember.id])?.id == singletonMember.id, "Selected singleton still anchors original child; its group opens on selection")
        var visits = 0
        check(TimelineVisibleAnchor.select(frames: frames, visible: visible, preferredIDs: ["expanded"], examined: { visits = $0 })?.id == "expanded" && visits == 1, "Visible selection anchors with one lookup instead of full frame scan")
        check(TimelineVisibleAnchor.select(frames: frames, visible: visible, preferredIDs: [], previousID: "expanded", examined: { visits = $0 })?.id == "expanded" && visits == 1, "Small scroll retains visible anchor with one lookup")
        check(TimelineVisibleAnchor.select(frames: frames, visible: visible, preferredIDs: [], previousID: "offscreen")?.id == "header", "Retained anchor leaving viewport falls back to visible row")
        check(TimelineVisibleAnchor.select(frames: frames, visible: visible, preferredIDs: ["header"], previousID: "expanded")?.id == "header", "Visible requested selection overrides retained anchor")
        let cache = TimelineSessionLayoutCache<Detail>()
        let firstCached = cache.sessions([named, generic, typed], sectionID: "fictional-block")
        let freshCached = cache.sessions([named, generic, changedTitle], sectionID: "fictional-block")
        check(cache.builds == 1 && cache.hits == 1, "Title callback reuses grouping/order plan")
        check(freshCached[0].members.first?.detail.title == changedTitle.detail.title, "Cache hydrates fresh current detail instead of retaining old summary")
        check(firstCached[0].id == freshCached[0].id, "Cached title callback retains stable presentation ID")
        _ = cache.sessions([named, generic, laterDraft], sectionID: "fictional-block")
        check(cache.builds == 2, "Persisted observed timestamp changes invalidate plan")
        _ = cache.sessions([named, generic, laterDraft], sectionID: "other-block")
        check(cache.builds == 3, "Section change invalidates plan")
        let deleted = cache.sessions([named], sectionID: "other-block")
        check(cache.builds == 4 && deleted.flatMap(\.members).map(\.id) == [named.id], "Removed child drops cached membership immediately")
    }
}

/// TitleClean's X and Instagram cleanup, and grouping over the cleaned titles.
enum TitleGrouping {
    static func run() {
        // Two long X titles in the shape the 9/30 acceptance fixture had (author, quoted topic, " / X"); made up.
        let observedShapes = [
            "Example Author on X: \"A paper lantern hung over the fictional garden path at dusk while the neighbours gathered to watch it glow\" / X",
            "Sample Writer on X: \"My blue ceramic cup came back from the made-up kiln with a crackle glaze that nobody in the studio expected\" / X"]
        for (i, raw) in observedShapes.enumerated() {
            let out = TitleClean.clean(raw, app: "Google Chrome", site: "x.com")
            let author = i == 0 ? "Example Author" : "Sample Writer"
            let topic = i == 0 ? "paper lantern" : "blue ceramic cup"
            check(out.contains(author) && out.contains(topic), "observed-derived X shape \(i): author and cited topic retained", output: out)
            check(!out.hasSuffix(" / X") && out.count <= 90 && out.hasSuffix("…"), "observed-derived X shape \(i): site suffix removed and title bounded")
        }
        let cases: [(String, String, String, String)] = [
            ("Home / X", "x.com", "X", "X home has site-only fallback"),
            ("", "x.com", "X", "missing X title has site-only fallback"),
            ("Example Author on X: \"A paper lantern\" / X", "x.com", "Example Author on X: \"A paper lantern\"", "short X quote and author retained"),
            ("Example Author on X: \"A paper lantern\" / X - Google Chrome", "x.com", "Example Author on X: \"A paper lantern\"", "extension: stacked browser/site suffix cleanup"),
            ("", "mobile.twitter.com", "X", "extension: mobile Twitter missing-title site normalization"),
            ("", "www.instagram.com", "Instagram", "extension: Instagram missing-title friendly name"),
            ("www.instagram.com", "www.instagram.com", "Instagram", "extension: Instagram host-only friendly name"),
            ("Instagram", "https://www.instagram.com/", "Instagram", "Instagram product-only title remains factual"),
            ("ChatGPT", "chatgpt.com", "ChatGPT", "generic ChatGPT stays generic"),
            ("New chat", "chatgpt.com", "New chat", "generic new chat does not invent coursework or project"),
            ("Example Author on X:", "x.com", "Example Author on X", "extension: incomplete attributed X title adds no topic")
        ]
        for (raw, site, expected, label) in cases {
            let out = TitleClean.clean(raw, app: "Google Chrome", site: site)
            check(out == expected, label, output: out)
        }
        let unfinished = TitleClean.clean("Example Author on X: \" / X", app: "Google Chrome", site: "x.com")
        check(!unfinished.hasSuffix("\"") && !unfinished.contains("paper lantern"), "extension: empty quoted X topic leaves no dangling quote or invented topic", output: unfinished)

        let punctuation = "Example Author on X: \"Paper lantern | blue cup - garden gate · red kite (3) [14]\""
        check(TitleClean.clean(punctuation + " / X - Google Chrome", app: "Google Chrome", site: "x.com") == punctuation,
              "quoted X topic keeps interior separators and semantic numbers")
        let nestedProduct = "Example Author on X: \"Chrome - X / Twitter\""
        check(TitleClean.clean(nestedProduct + " / X - Chrome / X", app: "Chrome", site: "x.com") == nestedProduct,
              "repeated suffixes leave quoted product words intact")
        let unicodeAuthor = "作者 😀 on X: “ ” / X"
        check(TitleClean.clean(unicodeAuthor, app: "Chrome", site: "x.com") == "作者 😀 on X", "empty Unicode quote keeps original Unicode author")
        let topicEmail = "Example Author on X: \"sample@fixture.example\" / X"
        let scrubbed = TitleClean.clean(topicEmail, app: "Chrome", site: "x.com")
        check(scrubbed == "Example Author on X" && !scrubbed.contains("@"), "email removal does not leave an empty quoted topic")
        check(TitleClean.clean("Example Author on X: '' / X", app: "Chrome", site: "x.com") == "Example Author on X", "empty single quotes establish no topic")
        check(TitleClean.clean("", app: "Chrome", site: "https://WWW.INSTAGRAM.COM/") == "Instagram", "case and URL normalize canonical Instagram fallback")
        for host in ["x.com.example.org", "instagram.com.example.org", "https://x.com@example.org/", "notinstagram.com"] {
            check(TitleClean.clean("Home / X", app: "Chrome", site: host) == "Home / X", "lookalike or credential-style host grants no X title cleanup: " + host)
        }
        check(TitleClean.clean("", app: "Chrome", site: "instagram.com.example.org") == "instagram.com.example.org", "lookalike host grants no canonical Instagram fallback")
        let longParts = "Example Author on X: \"Lantern | ceramic cup - garden gate · red kite " + String(repeating: "fictional phrase ", count: 10) + "\" / X"
        let longOut = TitleClean.clean(longParts, app: "Chrome", site: "x.com")
        check(longOut.hasPrefix("Example Author on X: \"Lantern | ceramic cup - garden gate · red kite") && longOut.count <= 90 && longOut.hasSuffix("…"), "long attributed topic keeps all prefix segments before word-bound truncation")

        check(TitleClean.clean("Home (2) / X - Google Chrome", app: "Google Chrome", site: "x.com") == "X", "generic X view with unread count stays site-only")
        let githubQuote = "Example Author on X: \"Upgrade · Pull Request #7 · demo/repo\""
        check(TitleClean.clean(githubQuote + " / X", app: "Chrome", site: "x.com") == githubQuote, "quoted GitHub words remain an X topic with original author")
        struct Detail: Equatable { let title: String, draftID: String }
        let epoch = Date(timeIntervalSince1970: 978307200)
        func member(_ id: String, _ start: Double, _ end: Double, _ channel: TimelineSessionChannel?, _ title: String, day: String = "2001-01-01") -> TimelineSessionMember<Detail> {
            TimelineSessionMember(id:id, dayKey:day, start:epoch.addingTimeInterval(start), end:epoch.addingTimeInterval(end), channel:channel, detail:Detail(title:title, draftID:id))
        }
        let distinct = [member("post-b", 200, 210, .x, "Sample Writer on X: fictional second post"), member("draft-a", 0, 10, .x, "Example Author on X: fictional first draft")]
        let sessions = TimelineSessionGrouping.group(distinct)
        check(sessions.count == 1 && sessions[0].isGrouped, "distinct X posts/drafts may share one presentation session")
        check(sessions[0].members.map(\.id) == distinct.map(\.id) && sessions[0].members.map(\.detail) == distinct.map(\.detail), "distinct child IDs, order and draft details remain lossless")
        let breakRows = [member("resume", 4522, 4522, .messages, "partial resume"), member("before-break", 0, 0, .messages, "partial before")]
        check(TimelineSessionGrouping.group(breakRows).count == 2, "observed-derived 75m22s break separates Texts sessions")
        let near = [member("piece-b", 309, 310, .x, "second partial"), member("piece-a", 0, 10, .x, "first partial")]
        check(TimelineSessionGrouping.group(near).count == 1, "extension: 299-second break may group display pieces")
        let far = [member("piece-b", 311, 312, .x, "second partial"), member("piece-a", 0, 10, .x, "first partial")]
        check(TimelineSessionGrouping.group(far).count == 2, "extension: 301-second break separates display pieces")
        let generic = [member("chat-b", 20, 30, TimelineSessionChannel.recorded(sites:["chatgpt.com"], bundles:["com.google.Chrome"]), "ChatGPT"), member("chat-a", 0, 10, nil, "ChatGPT")]
        check(TimelineSessionGrouping.group(generic).count == 2, "unrelated generic ChatGPT rows never gain task identity from time/name")
        check(TimelineSessionChannel.recorded(sites:["https://www.instagram.com/"], bundles:["com.google.Chrome"]) == .instagram, "Instagram recorded host/URL aliases normalize for session channel")
        check(TimelineSessionChannel.recorded(sites:["x.com", "instagram.com"], bundles:["com.google.Chrome"]) == nil, "mixed X/Instagram record does not select first channel")
        check(TimelineSessionChannel.recorded(sites:["instagram.com.example.org"], bundles:["com.google.Chrome"]) == nil, "lookalike Instagram host does not group")
        check(TimelineSessionGrouping.group([member("day-a",0,10,.x,"A"),member("day-b",20,30,.x,"B",day:"2001-01-02")]).count == 2, "day boundary prevents grouping")
    }
}

@main enum TimelineSessionGroupingChecks {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let fixture = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1])
            : URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/derived-session-interval-pattern.json")
        do { try DerivedIntervals.run(fixture) } catch { check(false, "the derived interval fixture reads (\(fixture.path)): \(error)") }
        LocalBlock.run()
        TitleGrouping.run()
        print("\(passes) timeline session grouping checks passed, \(failures) failed. Made-up activity only.")
        if failures > 0 { exit(1) }
    }
}
