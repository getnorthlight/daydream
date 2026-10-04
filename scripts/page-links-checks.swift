import Foundation
@testable import MemoryCore
@testable import MemoryUI

/// page-links-1003 (owner decision 2026-10-03): a Chrome page row on the details page, a Windows and pages entry and a
/// search result open the exact page (the YouTube video, the X post), and the row reads "<title>  youtube.com/watch…",
/// never the title twice ("youtube.com · Why do…"). Rows saved without a link fall back to their site.
/// Fictional fixtures only (fake URLs, fake titles): projections and pure rules. No app, window, Chrome, network or
/// owner data.
@main @MainActor enum PageLinksChecks {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ label: String, _ got: @autoclosure () -> String = "") {
        print("\(ok ? "PASS" : "FAIL") \(label)\(ok ? "" : " :: " + got())")
        if ok { passed += 1 } else { failed += 1 }
    }
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func page(_ id: String, _ seconds: TimeInterval, title: String, url: String, link: String?) -> CanonicalAction {
        var proof = BrowserVerification(mode: "normal", windowID: "1520", tabID: "1733", focusedRole: "", checkedAt: isoPrecise(t0.addingTimeInterval(seconds)),
                                        provider: BrowserSafety.pageProvider)
        proof.policyRevision = "policy-fixture"
        var e = Evidence(id: id, at: isoPrecise(t0.addingTimeInterval(seconds)), kind: "window.changed", app: "Google Chrome",
                         bundle: BrowserSafety.supportedBundle, title: title, url: url, browserVerification: proof)
        e.page = link
        return ActionProjection.make(e)
    }

    static func main() {
        let video = "Why do fixtures wear jackets? - YouTube"
        let yt = page("a1", 0, title: video, url: "https://www.youtube.com", link: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s")
        let post = page("a2", 60, title: "Fixture User on X: \"a post\" / X", url: "https://x.com", link: "https://x.com/fixtureuser/status/1839123456789012344")
        let old = page("a3", 120, title: "An older video - YouTube", url: "https://www.youtube.com", link: nil)
        let other = page("a4", 180, title: "Another video - YouTube", url: "https://www.youtube.com", link: "https://www.youtube.com/watch?v=AbCdEfGhIjK")

        // The action carries the link for the app, never in its encoding or equality.
        check(yt.link == "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s", "action: a page row's action carries its link", "\(String(describing: yt.link))")
        var bare = yt; bare.link = nil
        check(bare == yt, "action: the link is not part of ==")
        let json = (try? JSONEncoder().encode(yt)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(!json.isEmpty && !json.contains("dQw4w9WgXcQ") && !json.contains("\"link\""), "action: the link is never encoded")
        let synthetic = ActionProjection.make({ var e = Evidence(id: "s", at: isoPrecise(t0), kind: "window.changed", app: "Google Chrome",
                                                                  bundle: "com.google.Chrome", title: "x", url: "https://x.com", synthetic: true)
                                                 e.page = "https://x.com/a/status/1"; return e }())
        check(synthetic.link == nil, "action: only a verified Chrome page row carries a link")

        // The details page's What happened: the short link beside the title, never the title twice.
        let actions = [yt, post, old]
        let history = OwnerSourceMomentProjection.history(actions, previews: [])
        let lines = MomentHistoryCondense.lines(history, actions: actions, timeZone: TimeZone(identifier: "UTC")!)
        let ytLine = lines.first { $0.actionIDs.contains("a1") }, xLine = lines.first { $0.actionIDs.contains("a2") }, oldLine = lines.first { $0.actionIDs.contains("a3") }
        check(ytLine?.detail == "youtube.com/watch…" && ytLine?.title == video, "details: a video row reads its title and youtube.com/watch…",
              "\(String(describing: ytLine?.title)) | \(String(describing: ytLine?.detail))")
        check(ytLine.map { !$0.detail.contains("Why do") } == true, "details: the title is never repeated beside it")
        check(ytLine?.openActionID == "a1" && ytLine?.link == "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s", "details: the row opens the video's own action and link")
        check(xLine?.detail == "x.com/fixtureuser/status/18391234567…", "details: an X post reads its short link", "\(String(describing: xLine?.detail))")
        check(oldLine?.detail == "youtube.com" && oldLine?.openActionID == "a3" && oldLine?.link == nil,
              "details: a row saved without a link reads its site and opens its site", "\(String(describing: oldLine?.detail))")
        check(ytLine?.place == "youtube.com/watch…",
              "details: the open help names the short link")
        // The same video seen twice in a row is one line; two videos are two.
        let again = page("a5", 30, title: video, url: "https://www.youtube.com", link: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s")
        let twice = MomentHistoryCondense.lines(OwnerSourceMomentProjection.history([yt, again, other], previews: []), actions: [yt, again, other],
                                                timeZone: TimeZone(identifier: "UTC")!)
        check(twice.count == 2 && twice[0].actionIDs == ["a1", "a5"] && twice[1].openActionID == "a4",
              "details: one line per video, each opening its own", "\(twice.map { ($0.title, $0.actionIDs) })")
        // The pushed detail's entries (`MomentDetailBody.entries`) too.
        let entries = MomentDetailBody.entries([yt, old], typed: .empty)
        check(entries.first { $0.openActionID == "a1" }?.detail == "youtube.com/watch…", "entries: a page entry reads its short link",
              "\(entries.map(\.detail))")
        check(MomentDetailBody.rowOpenTitle(yt).help == "Opens youtube.com/watch… in your browser"
              && MomentDetailBody.rowOpenTitle(old).help == "Opens youtube.com in your browser", "Open Original help: the short link, else the site")

        // Windows and pages: each video with a link is its own entry; pages without one stay one per site.
        let sources = FocusListExpanded.allSources(from: [yt, other, old, post])
        let ytSources = sources.filter { $0.site == "youtube.com" }
        check(ytSources.count == 3, "Windows and pages: each linked video is its own entry, the unlinked one its site's", "\(sources.map { ($0.id, $0.title) })")
        let mine = sources.first { $0.openActionID == "a1" }
        check(mine?.title == video && mine?.link == "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s" && mine?.place == "youtube.com/watch…",
              "Windows and pages: the video's entry opens its own action", "\(String(describing: mine))")
        let row = FocusAppCard.PanelRow(name: video, bundle: BrowserSafety.supportedBundle, site: "youtube.com", wrote: false)
        check(FocusAppCard.panelSource(row, sources: sources)?.openActionID == "a1", "Windows and pages: the panel row clicks through to its page")
        let window = FocusAppCard.PanelRow(name: "Notes", bundle: "com.apple.Notes", site: "", wrote: false)
        check(FocusAppCard.panelSource(window, sources: sources) == nil, "Windows and pages: a window row opens no page")
        let unlinked = FocusListExpanded.allSources(from: [old, page("a6", 200, title: "Third - YouTube", url: "https://www.youtube.com", link: nil)])
        check(unlinked.count == 1 && unlinked[0].openActionID == "a6" && unlinked[0].link == nil, "Windows and pages: old rows stay one entry per site, opening its latest")

        // Search results: the short link, never the row's own title twice.
        var e = Evidence(id: "h1", at: isoPrecise(t0), kind: "window.changed", app: "Google Chrome", bundle: "com.google.Chrome", title: video,
                         url: "https://www.youtube.com", synthetic: true)
        e.page = "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s"
        let hit = IntentWriter.write(e)
        let result = RecallRow(id: "r1", kind: .action, hits: [hit], dayKey: "2027-01-15", day: t0, time: t0, latest: t0)
        let line = RecallResultRow.line(RecallMatch(source: .page, text: "youtube.com"), row: result)
        check(line == video + " · youtube.com/watch…", "search: a page result reads its title and short link", line)
        var plain = e; plain.page = nil
        let oldResult = RecallRow(id: "r2", kind: .action, hits: [IntentWriter.write(plain)], dayKey: "2027-01-15", day: t0, time: t0, latest: t0)
        check(RecallResultRow.line(RecallMatch(source: .page, text: "youtube.com"), row: oldResult) == video + " · youtube.com",
              "search: an old result reads its site")

        print("page-links: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
