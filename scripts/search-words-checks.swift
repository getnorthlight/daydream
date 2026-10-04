import Foundation
@testable import MemoryCore
@testable import MemoryUI

/// claude/search-1005 (owner decision 2026-10-04: "I went to different google sites so it is retarded that that was not
/// saved"): the Web searches card lists each search with its words ("Searched “fixture boots”"), never
/// "google.com 4 times"; the same search in a row is one line with its count; a typed search row with the same words
/// joins its line (never shown twice); rows saved before (the site only) still read as the site.
/// Fictional fixtures only (made-up searches, fake windows): projections and pure rules. No app, window, Chrome, network
/// or owner data.
@main @MainActor enum SearchWordsChecks {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ label: String, _ got: @autoclosure () -> String = "") {
        print("\(ok ? "PASS" : "FAIL") \(label)\(ok ? "" : " :: " + got())")
        if ok { passed += 1 } else { failed += 1 }
    }
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let utc = TimeZone(identifier: "UTC")!
    static func page(_ id: String, _ seconds: TimeInterval, title: String, url: String = "https://www.google.com") -> CanonicalAction {
        var proof = BrowserVerification(mode: "normal", windowID: "1520", tabID: "1733", focusedRole: "", checkedAt: isoPrecise(t0.addingTimeInterval(seconds)),
                                        provider: BrowserSafety.pageProvider)
        proof.policyRevision = "policy-fixture"
        let e = Evidence(id: id, at: isoPrecise(t0.addingTimeInterval(seconds)), kind: "window.changed", app: "Google Chrome",
                         bundle: BrowserSafety.supportedBundle, title: title, url: url, browserVerification: proof)
        return ActionProjection.make(e)
    }
    static func lines(_ actions: [CanonicalAction], blocks: [MomentTypedBlock] = []) -> [MomentDetailEntry] {
        MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(actions, previews: [], typed: MomentTypedLoad(blocks: blocks)),
                                    actions: actions, timeZone: utc)
    }

    static func main() {
        // The owner's morning: four Google searches, three of them different.
        let a1 = page("s1", 0, title: "fixture boots"), a2 = page("s2", 60, title: "fixture boots"),
            a3 = page("s3", 120, title: "fixture laces"), a4 = page("s4", 300, title: "fixture weather")
        let out = lines([a1, a2, a3, a4])
        let titles = out.map(\.title)
        check(titles == ["Searched \u{201C}fixture boots\u{201D}", "Searched \u{201C}fixture laces\u{201D}", "Searched \u{201C}fixture weather\u{201D}"],
              "card: each search is its own line with its words", titles.joined(separator: " | "))
        check(!out.contains { $0.title == "google.com" || $0.detail.contains("4 times") }, "card: never \"google.com 4 times\"")
        check(out.first?.detail.hasPrefix("google.com · 2 times") == true && out.first?.actionIDs == ["s1", "s2"],
              "card: the same search twice in a row is one line with its count", out.first?.detail ?? "nil")
        check(out[1].detail == "google.com" && out[1].search == "fixture laces" && out[1].openActionID == "s3",
              "card: a search line names its engine's site and opens its own row", out[1].detail)
        let sentences = FocusAppCard.sentences(out, start: t0, end: t0.addingTimeInterval(300))
        check(sentences.first == "Searched \u{201C}fixture boots\u{201D} (2 times)." && sentences.last == "Searched \u{201C}fixture weather\u{201D}.",
              "card: the summary-less card says each search", sentences.joined(separator: " | "))
        // Other engines read the same way.
        let ddg = lines([page("d1", 0, title: "fixture tea", url: "https://duckduckgo.com")])
        check(ddg.first?.title == "Searched \u{201C}fixture tea\u{201D}" && ddg.first?.detail == "duckduckgo.com", "card: DuckDuckGo too", ddg.first?.title ?? "nil")
        // Rows saved before (the site only) still read as the site; an ordinary page is unchanged.
        let old = lines([page("o1", 0, title: ""), page("o2", 60, title: "")])
        check(old.count == 1 && old.first?.title == "google.com" && old.first?.search == nil, "card: an older site-only search row still reads as its site",
              old.first?.title ?? "nil")
        let docs = lines([page("p1", 0, title: "Fixture plan - Google Docs", url: "https://docs.google.com")])
        check(docs.first?.title == "Fixture plan - Google Docs" && docs.first?.search == nil, "card: an ordinary page keeps its title", docs.first?.title ?? "nil")
        // A typed search row with the same words joins the search line (one search, one line); a different one stays.
        var typed = page("t1", 30, title: "www.google.com"); typed.kind = "keyboard.text_input"; typed.description = "Typed in Google Chrome."
        var other = page("t2", 400, title: "www.google.com"); other.kind = "keyboard.text_input"; other.description = "Typed in Google Chrome."
        let blocks = [MomentTypedBlock(id: "t1", at: typed.at, app: "Google Chrome", bundle: BrowserSafety.supportedBundle, host: "google.com",
                                       title: "google.com", text: "Fixture  boots", send: "Submission observed"),
                      MomentTypedBlock(id: "t2", at: other.at, app: "Google Chrome", bundle: BrowserSafety.supportedBundle, host: "google.com",
                                       title: "google.com", text: "fixture socks", send: "Submission observed")]
        let folded = lines([a1, typed, a3, other], blocks: blocks)
        let boots = folded.first { $0.search == "fixture boots" }
        check(boots?.actionIDs.contains("t1") == true && !folded.contains { $0.actionIDs == ["t1"] },
              "card: a typed search with the same words joins its search line", folded.map(\.title).joined(separator: " | "))
        check(folded.contains { $0.actionIDs.contains("t2") && $0.typed.contains { $0.text == "fixture socks" } },
              "card: a typed search with other words keeps its own line")
        let twice = lines([a1, typed, a2], blocks: [blocks[0]])
        check(twice.count == 1 && twice[0].detail.contains("2 times"), "card: a folded typed row is not counted as a search", twice.first?.detail ?? "nil")
        // The details page's entries say the same.
        let entries = MomentDetailBody.entries([a1, a3], typed: MomentTypedLoad(blocks: []))
        check(entries.map(\.title) == ["Searched \u{201C}fixture boots\u{201D}", "Searched \u{201C}fixture laces\u{201D}"],
              "details: each search is its own entry with its words", entries.map(\.title).joined(separator: " | "))
        print("search-words: \(passed) passed, \(failed) failed; fictional fixtures, no windows")
        exit(failed == 0 ? 0 : 1)
    }
}
