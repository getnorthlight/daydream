import Foundation
import MemoryCore

@main struct TitleGroupingAcceptance {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ label: String, output: String = "") {
        if ok { passed += 1 } else { failed += 1 }
        print("\(ok ? "PASS" : "FAIL") \(label)\(output.isEmpty ? "" : " -> " + output)")
    }
    static func main() throws {
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let rows = fixture["actions"] as! [[String: Any]]
        for (i, row) in rows.prefix(2).enumerated() {
            let raw = row["title"] as! String
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
        print("ACCEPTANCE: \(passed) PASS, \(failed) FAIL. All fixtures synthetic/deidentified; live workflows UNVERIFIED.")
        if failed > 0 { exit(1) }
    }
}
