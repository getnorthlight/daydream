import Foundation
@testable import MemoryCore
@testable import MemoryUI

/// claude/dayeval-1005 (owner 10/05): never "draft" anywhere a person or an AI app can see it. Stored words keep their
/// wording (an action is still described "Typed a draft in Notes (a sentence).", an older note may say "Drafted a text
/// to Sam (not sent)."); every surface rewrites them last through `DisplayWords.undraft`. This renders fictional
/// fixtures through each surface and greps the copy for draft, unsent and not-sent wording: What happened rows, the
/// moment card and day headline (`TodaySnapshot`), the day's level slice, note search, and the legacy AI-app tools
/// (action lines, item reads, recall, note reads). A scratch store under $TMPDIR; fictional apps, names and words only.
@main @MainActor enum NoDraftDisplayChecks {
    static var checks = 0, failures = 0
    static func require(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        checks += 1
        if !ok { failures += 1; print("FAIL: \(name)\(got().isEmpty ? "" : " (got: \(got()))")") }
    }
    /// No quote-skipping here: the fixtures' own typed words never say draft, so any hit is a surface's copy.
    static let banned = try! NSRegularExpression(pattern: #"(?i)\b(draft|drafts|drafted|drafting|unsent|not sent|never sent|no send seen)\b|isn['’]t confirmed"#)
    static func says(_ s: String) -> Bool { banned.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
    static func clean(_ texts: [String], _ name: String) {
        let bad = texts.filter(says)
        require(!texts.isEmpty, "\(name): something rendered")
        require(bad.isEmpty, "\(name): no draft or unsent wording", bad.prefix(3).joined(separator: " / "))
    }
    /// Every string value in a JSON reply (keys are not copy).
    static func strings(_ value: Any) -> [String] {
        if let s = value as? String { return [s] }
        if let a = value as? [Any] { return a.flatMap(strings) }
        if let d = value as? [String: Any] { return d.values.flatMap(strings) }
        return []
    }
    static func strings(json: String) -> [String] {
        guard let data = json.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: data) else { return [json] }
        return strings(v)
    }

    static let zone = "America/Chicago"
    static let tz = TimeZone(identifier: zone)!
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c }
    static func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: h, minute: m, second: s))! }
    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
    static func ev(_ id: String, _ when: Date, _ kind: String, app: String = "Notes", bundle: String = "com.apple.Notes",
                   title: String = "Fictional list", text: String = "") -> Evidence {
        Evidence(id: id, at: iso(when), kind: kind, app: app, bundle: bundle, title: title, url: "", text: text, synthetic: true)
    }

    /// 1. The shared rules: stored wording in, plain wording out; quotes (titles, the person's words) untouched.
    static func rules() {
        let cases: [(String, String)] = [
            ("Typed a draft in Notes (a sentence).", "Typed in Notes (a sentence)."),
            ("Drafted a text to Sam (not sent).", "Wrote a text to Sam."),
            ("Drafted an email to Avery about the picnic", "Wrote an email to Avery about the picnic"),
            ("Draft to Jamie Lin (not sent)", "Typed to Jamie Lin"),
            ("Typed a draft in Ghostty.", "Typed in Ghostty."),
            ("Left a draft reply to Sam unsent.", "Left a reply to Sam."),
            ("Opened “Draft plan for the picnic” in Notes.", "Opened “Draft plan for the picnic” in Notes."),
            ("Opened Notes and drafted a draft email to Avery.", "Opened Notes and wrote an email to Avery."),
            ("Edited a draft of the picnic plan, unsent.", "Edited the picnic plan."),
            // A title's own word is the person's, quoted or not: it stays.
            ("Read Lab Report Draft.", "Read Lab Report Draft."),
            ("Read PR #12: Fix Messages drafts on GitHub.", "Read PR #12: Fix Messages drafts on GitHub."),
            ("Went through Drafts in Gmail.", "Went through Drafts in Gmail."),
        ]
        for (stored, shown) in cases {
            let got = DisplayWords.undraft(stored)
            require(got == shown, "undraft: \(stored)", got)
        }
        require(!DisplayWords.saysDraft("Opened “Draft plan” in Notes."), "a quoted title is the person's, not copy")
        require(DisplayWords.saysDraft("Drafted a text"), "saysDraft finds stored wording")
    }

    /// 2. What happened rows for stored draft descriptions.
    static func whatHappened() {
        let raw = [ev("w0", at(9, 0), "keyboard.text_input", text: "Fictional grocery list for the week."),
                   ev("w1", at(9, 2), "keyboard.text_input", app: "Ghostty", bundle: "com.mitchellh.ghostty", title: "zsh"),
                   ev("w2", at(9, 4), "keyboard.text_input", app: "Messages", bundle: "com.apple.MobileSMS", title: "Sam", text: "See you at six."),
                   ev("w3", at(9, 6), "keyboard.submit", app: "Messages", bundle: "com.apple.MobileSMS", title: "Sam")]
        let actions = raw.map(ActionProjection.make)
        require(actions.contains { $0.description.hasPrefix("Typed a draft in ") }, "fixture keeps the stored draft wording")
        let rows = MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(actions, previews: []), actions: actions, timeZone: tz)
        clean(rows.flatMap { [$0.title, $0.detail] }, "What happened")
        // 3. Legacy AI-app tools: one line per action, and a decorated reply.
        clean(actions.map { AssistantView.line($0) }, "AI-app action lines")
        let body = "{\"actions\":" + String(data: try! JSONEncoder().encode(actions), encoding: .utf8)! + "}"
        clean(strings(json: AssistantView.decorate(body, zone: tz)), "AI-app decorated reply")
        // The fallback timeline (ActivityTimelineView, shown only when the day loader is missing) writes its own
        // sentence for typed text: it said "A draft in TextEdit: ...".
        let typed = ActivityUIFixtures.items().filter { $0.evidence.kind == "keyboard.text_input" && !$0.generatedAt.isEmpty }
        require(!typed.isEmpty, "fallback timeline: the fixture has typed text")
        clean(typed.map { ActivityWords.narrative([$0]) } + [ActivityWords.narrative(ActivityUIFixtures.items())], "fallback timeline")
        require(typed.allSatisfy { ActivityWords.narrative([$0]).hasPrefix("Typed in \($0.evidence.app): ") }, "fallback timeline: typed text reads Typed in <app>")
    }

    /// 4. A scratch store: a moment whose saved note (from an earlier writer) says Drafted and not sent.
    static func stored() {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("no-draft-display-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: home)
        defer { try? FileManager.default.removeItem(at: home) }
        let now = at(23, 0), day = "2026-10-04"
        do {
            let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
            for i in 0..<6 {   // the last two: Return pressed in the conversation (stored state "draft")
                _ = try store.ingest(ev("s\(i)", at(14, i * 2), i < 4 ? "window.changed" : "keyboard.submit", app: "Messages", bundle: "com.apple.MobileSMS", title: "Sam"), now: now)
            }
            let layers = try store.dayLayers(day: day, timezone: zone, limit: 200, now: now)
            guard let moment = layers.activities.first else { require(false, "fixture has a moment"); return }
            let request = try store.prepareNote(kind: "activity", day: day, timezone: zone, activityID: moment.id, now: now)
            let ids = request.actions.map(\.id)
            let saved = try store.commitNote(NoteWriterOutput(requestID: request.id, title: "Drafted a text to Sam",
                                                      bullets: [NoteBullet(text: "Drafted a text to Sam about the picnic, left unsent.", actionIDs: request.actions.filter { $0.state == "draft" }.map(\.id), assertion: "draft"),
                                                                NoteBullet(text: "Typed a draft in Messages.", actionIDs: Array(ids.prefix(2)), assertion: "observed")],
                                                      generator: "local/synthetic", generatorVersion: "1"), now: now)
            let ready = try store.dayLayers(day: day, timezone: zone, limit: 200, now: now)
            let snap = TodaySnapshot.make(day: ready, summaries: SummaryAvailability(provider: .local, busy: false), calendar: cal, now: now)
            let cards = snap.moments.flatMap { [$0.title] + ($0.firstBullet.map { [$0] } ?? []) + $0.bullets.map(\.text) } + (snap.headline.map { [$0] } ?? [])
            require(snap.moments.contains { !$0.bullets.isEmpty }, "the saved note reaches the card", cards.joined(separator: " / "))
            clean(cards, "moment card")
            let hits = try store.noteSearch("Sam", timezone: zone, now: now)
            clean(hits.flatMap { [$0.text, $0.noteTitle] + ($0.inTitle.map { [$0] } ?? []) + $0.lines + $0.children.map(\.title) }, "note search")
            if let levels = try? store.dayLevels(day: day, timezone: zone, now: now), let slice = DayLevelSlice.make(levels, calendar: cal) {
                clean([slice.dayTitle ?? ""] + slice.dayLines + slice.blocks.flatMap { [$0.name, $0.title] + $0.lines } + [slice.weekTitle ?? ""] + slice.dayBullets.map(\.text), "day level slice")
            }
            for (name, json) in [("AI-app recall (day)", try store.assistantRecall(level: "day", when: day, open: nil, query: nil, timezone: zone, now: now)),
                                 ("AI-app recall (search)", try store.assistantRecall(level: nil, when: nil, open: nil, query: "Sam", timezone: zone, now: now)),
                                 ("AI-app day context", try store.assistantContext(now: now))] {
                clean(strings(json: AssistantView.decorate(json, zone: tz)), name)
            }
            if let note = AssistantView.note(saved) { clean([note.title ?? ""] + note.points, "AI-app note read") }
            else { require(false, "AI-app note read: the saved note reads") }
        } catch { require(false, "scratch store", "\(error)") }
    }

    static func main() {
        rules()
        whatHappened()
        stored()
        if failures > 0 { print("FAIL: no-draft-display \(failures) of \(checks) checks"); exit(1) }
        print("PASS: no-draft-display \(checks) checks; fictional fixtures, no words printed")
    }
}
