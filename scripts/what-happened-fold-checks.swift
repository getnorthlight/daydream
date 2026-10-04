import Foundation
@testable import MemoryCore
@testable import MemoryUI

/// perf-1005 (owner 10/4): a moment's What happened listed fifteen "ChatGPT  chatgpt.com · Clicked" rows at the same
/// minute. Back-to-back rows of the same app, site and kind (no words of their own) are one row with how many times and
/// the time range, in the words the neighbour fold already used ("15 times · 2:31–2:32 PM"). Fictional actions only; no
/// app, window, model or owner data. Part 6 (headless, a scratch store under $TMPDIR): a card's member actions in ONE read
/// (`MemoryStore.memberActions`) are exactly what the day's page walk finds, at a fraction of its cost.
@main @MainActor enum WhatHappenedFoldChecks {
    static var checks = 0
    static func require(_ ok: Bool, _ reason: String, _ got: @autoclosure () -> String = "") {
        guard ok else { FileHandle.standardError.write(Data("FAIL: \(reason) \(got())\n".utf8)); exit(1) }
        checks += 1
    }
    static let tz = TimeZone(identifier: "America/Chicago")!
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c }
    static func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: h, minute: m, second: s))!
    }
    static func action(_ id: String, _ when: Date, _ kind: String, app: String = "Google Chrome", bundle: String = "com.google.Chrome",
                       title: String = "ChatGPT", url: String = "https://chatgpt.com", link: String? = nil, text: String = "") -> CanonicalAction {
        var a = ActionProjection.make(Evidence(id: id, at: iso(when), kind: kind, app: app, bundle: bundle, title: title, url: url, text: text, synthetic: true))
        a.link = link
        return a
    }
    /// 6. perf-1005: one read per card. A big synthetic day (thousands of actions, hundreds of moments); a late moment's
    /// members read by the page walk (what What happened did) and in one read: the same actions, in the same order.
    static func memberRead() {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("what-happened-fold-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: home)
        defer { try? FileManager.default.removeItem(at: home) }
        let zone = "America/Chicago", now = at(23, 50)
        guard let store = try? MemoryStore(home: home, writable: true, automaticallySyncSearch: false) else { require(false, "scratch store opens"); return }
        let apps = [("Mail", "com.apple.mail", ""), ("Google Chrome", "com.google.Chrome", "https://chatgpt.com"), ("Xcode", "com.apple.dt.Xcode", ""),
                    ("Notes", "com.apple.Notes", ""), ("Terminal", "com.apple.Terminal", "")]
        var n = 0, t = at(7, 0)
        var stretch = 0
        while t < at(21, 0) {
            let app = apps[stretch % apps.count]; stretch += 1
            for k in 0..<12 {
                n += 1
                let e = Evidence(id: String(format: "fold-%05d", n), at: iso(t), kind: k == 0 ? "window.changed" : "mouse.click", app: app.0, bundle: app.1,
                                 title: "Fictional window \(stretch)", url: app.2, synthetic: true)
                _ = try? store.ingest(e, now: t.addingTimeInterval(1))
                t = t.addingTimeInterval(4)
            }
            t = t.addingTimeInterval(20)
        }
        guard let key = try? DayScope.key(at(12, 0), timezone: zone), let day = try? store.dayLayers(day: key, timezone: zone, limit: 200, now: now),
              let late = day.activities.last(where: { $0.actionIDs.count >= 5 }) else { require(false, "the synthetic day assembles"); return }
        require(day.summary.actionCount >= 3000 && day.activities.count >= 200, "fixture: thousands of actions in hundreds of moments",
                "\(day.summary.actionCount) actions, \(day.activities.count) moments")
        let members = Set(late.actionIDs)
        var t0 = Date()
        var walked = [CanonicalAction](), page = day.actions, pages = 1
        while true {
            walked += page.actions.filter { members.contains($0.id) }
            guard walked.count < members.count, let next = page.next, let more = try? store.dayLayers(day: key, timezone: zone, after: next, limit: 200, now: now) else { break }
            page = more.actions; pages += 1
        }
        let walk = Date().timeIntervalSince(t0) * 1000
        t0 = Date()
        let one = (try? store.memberActions(day: key, timezone: zone, ids: late.actionIDs, now: now)) ?? nil
        let read = Date().timeIntervalSince(t0) * 1000
        print(String(format: "BENCH member read: page walk %d pages %.0f ms, one read %.0f ms (%d actions)", pages, walk, read, members.count))
        require(one?.map(\.id) == walked.map(\.id) && walked.count == members.count, "one read finds the same actions as the page walk, in order",
                "\(one?.count ?? -1) vs \(walked.count)")
        require(one?.map(\.revision) == walked.map(\.revision), "one read's actions are the walk's, field for field (revisions)")
        require(read * 4 < walk, "one read costs a fraction of the walk", String(format: "%.0f vs %.0f ms", read, walk))
    }

    static func lines(_ actions: [CanonicalAction]) -> [MomentDetailEntry] {
        MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(actions, previews: []), actions: actions, timeZone: tz)
    }
    static func show(_ l: [MomentDetailEntry]) -> String { l.map { $0.title + " | " + $0.detail }.joined(separator: " / ") }

    static func main() {
        // 1. Fifteen clicks in one minute on one ChatGPT conversation whose link changes (a query the short link hides),
        //    with Chrome rows of no site between some of them (they fold into their neighbours afterwards).
        var actions: [CanonicalAction] = []
        for i in 0..<15 {
            actions.append(action("c\(i)", at(14, 31, 2 + i * 3), "mouse.click", link: "https://chatgpt.com/c/fictional-1?model=\(i % 3)"))
            if i % 5 == 4 { actions.append(action("q\(i)", at(14, 31, 3 + i * 3), "app.activated", title: "", url: "")) }
        }
        var out = lines(actions)
        let clicks = out.filter { $0.detail.contains("Clicked") }
        require(clicks.count == 1, "fifteen back-to-back clicks on one site are one row", show(out))
        require(clicks[0].detail.contains("15 times"), "the row says how many times", clicks[0].detail)
        // All in one minute: the row's time column already says 2:31, so no range repeats it.
        require(!clicks[0].detail.contains("\u{2013}"), "a run inside one minute adds no range", clicks[0].detail)
        require(clicks[0].first == at(14, 31, 2) && (clicks[0].last ?? .distantPast) >= at(14, 31, 44), "the row spans the run")
        require(Set(out.flatMap(\.actionIDs)) == Set(actions.map(\.id)) && out.flatMap(\.actionIDs).count == actions.count,
                "every action stays reachable exactly once", show(out))
        require(clicks[0].openActionID == "c14", "the row opens the latest click", clicks[0].openActionID ?? "nil")

        // 1b. A run over three minutes says its range.
        let spread = (0..<6).map { i in action("t\(i)", at(14, 40 + i / 2, (i % 2) * 20), "mouse.click") }
        let spreadLines = lines(spread)
        require(spreadLines.count == 1 && spreadLines[0].detail.hasSuffix("6 times · 2:40\u{2013}2:42 PM"), "a longer run says its time range", show(spreadLines))

        // 2. A conversation renamed mid-run (same app, site and kind): one row, titled by the latest.
        actions = (0..<6).map { i in action("r\(i)", at(15, 0, i * 5), "mouse.click", title: i < 3 ? "ChatGPT" : "Fictional parser help - ChatGPT") }
        out = lines(actions)
        require(out.count == 1 && out[0].detail.contains("6 times"), "a renamed conversation's clicks are one row", show(out))

        // 3. Never folded: different kinds, different sites, page views of different pages, rows with words.
        actions = [action("k0", at(16, 0, 0), "mouse.click"), action("k1", at(16, 0, 5), "keyboard.submit"), action("k2", at(16, 0, 9), "mouse.click")]
        out = lines(actions)
        require(!out.contains { $0.detail.contains("times") }, "different kinds stay apart", show(out))
        actions = [action("s0", at(16, 1, 0), "mouse.click"), action("s1", at(16, 1, 5), "mouse.click", url: "https://github.com"),
                   action("s2", at(16, 1, 9), "mouse.click")]
        out = lines(actions)
        require(out.count == 3, "another site in between keeps the runs apart", show(out))
        actions = [action("v0", at(16, 2, 0), "window.changed", title: "Fictional video one - YouTube", url: "https://www.youtube.com", link: "https://www.youtube.com/watch?v=one"),
                   action("v1", at(16, 2, 30), "window.changed", title: "Fictional video two - YouTube", url: "https://www.youtube.com", link: "https://www.youtube.com/watch?v=two")]
        out = lines(actions)
        require(out.count == 2, "two pages seen back to back keep a row each (each opens itself)", show(out))
        actions = [action("w0", at(16, 3, 0), "keyboard.text_input", text: "fictional words one"),
                   action("w1", at(16, 3, 9), "keyboard.text_input", text: "fictional words two")]
        let typed = MomentTypedLoad(sends: [:], blocks: zip(actions, ["fictional words one", "fictional words two"]).map { a, words in
            MomentTypedBlock(id: a.id, at: a.at, app: "Google Chrome", bundle: "com.google.Chrome", host: "chatgpt.com", title: "ChatGPT",
                             text: words, send: "Drafted text") })
        out = MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(actions, previews: [], typed: typed), actions: actions, timeZone: tz)
        require(!out.contains { $0.detail.contains("times") }, "rows with words are never folded", show(out))

        // 4. Windows (no site) fold only with their own title.
        actions = [action("x0", at(17, 0, 0), "keyboard.submit", app: "Notes", bundle: "com.apple.Notes", title: "Fictional list", url: ""),
                   action("x1", at(17, 0, 30), "keyboard.submit", app: "Notes", bundle: "com.apple.Notes", title: "Another fictional list", url: "")]
        out = lines(actions)
        require(!out.contains { $0.detail.contains("2 times") }, "two windows' rows stay apart", show(out))

        // 5. The fold is pure display and the wording is the neighbour fold's: regular weight, no new words.
        let source = (try? String(contentsOfFile: "Sources/MemoryUI/OwnerSourceMomentProjection.swift", encoding: .utf8)) ?? ""
        require(source.contains("static func foldRepeats") && !source.contains("weight: .bold"), "the fold adds no bold text")
        memberRead()
        print("PASS: what-happened-fold \(checks) checks; fictional actions, no windows")
    }
}
