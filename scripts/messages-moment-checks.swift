import Foundation
import PrivacyPolicy
@testable import MemoryCore

/// B2 regressions: fabricated metadata/words only. No AX, AppKit, recorder,
/// provider, real history, Keychain, model, network, or send operations.
@main struct MessagesMomentChecks {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let bundle = "com.apple.MobileSMS"
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        checks += 1
        guard try value() else { throw MemError.invalid("FAILED: " + label) }
        print("PASS: " + label)
    }
    static func row(_ id: String, _ seconds: Double, title: String, typed: Bool = false, to: String? = nil, field: String = "message") -> Evidence {
        let at = iso(now.addingTimeInterval(-600 + seconds))
        var e = Evidence(id: id, at: at, kind: typed ? "keyboard.text_input" : "window.changed", app: "Messages", bundle: bundle, title: title, synthetic: true)
        if typed {
            e.captureProvenance = NativeCaptureProvenance(policyRevision: "fixture", classifierVersion: "fixture", windowID: "synthetic-window", focusID: "synthetic-focus", checkedAt: at, generation: 1,
                unit: TypedUnitProvenance(runID: "synthetic-run-" + id, part: 1, sealReason: "idle", startedAt: at, keys: nil, edits: nil, withheld: 0, surface: "text", field: field, send: "unknown", to: to))
        }
        return e
    }
    static func groups(_ rows: [Evidence], since: Date? = .distantPast) throws -> (groups: [[String]], names: [String]) {
        let actions = rows.map(ActionProjection.make)
        let recipients = Dictionary(uniqueKeysWithValues: rows.compactMap { e -> (String, String)? in
            guard let unit = e.captureProvenance?.unit, ["message", "body", "textArea"].contains(unit.field ?? ""), let to = unit.to else { return nil }
            return (e.id, to)
        })
        let result = try MemoryStore.groupMoments(actions, times: rows.map { timestamp($0.at) }, day: "2027-01-15", timezone: "UTC", edits: [:], since: since, messagesRecipients: recipients)
        let ordered = result.groups.sorted { $0.value[0] < $1.value[0] }
        return (ordered.map { $0.value.map { rows[$0].id } }, ordered.map { result.names[$0.key]! })
    }
    static func main() throws {
        let recipientFree = [row("x", 0, title: "Maya"), row("new", 2, title: "New Message"), row("draft-1", 3, title: "Messages", typed: true, field: "oneLine"), row("draft-2", 4, title: "Messages", typed: true, field: "oneLine")]
        for since: Date? in [nil, .distantPast] {
            let result = try groups(recipientFree, since: since)
            try check(result.groups == [["x"], ["new", "draft-1", "draft-2"]], "recipient-free new composer stays separate before/after continuation stamp")
            try check(result.names == ["Maya", "Messages"], "anonymous draft never takes the previously visible name")
        }
        let later = recipientFree + [row("picked", 5, title: "Messages", typed: true, to: "Sam"), row("sam", 6, title: "Sam"), row("sam-draft", 7, title: "Maya", typed: true, to: "Sam")]
        let named = try groups(later)
        try check(named.groups == [["x"], ["new", "draft-1", "draft-2"], ["picked", "sam", "sam-draft"]], "later verified recipient starts its own named moment; no temporal back-link")
        try check(named.names == ["Maya", "Messages", "Sam"], "verified recipient wins over stale typed-row title")
        let noProof = try groups(recipientFree + [row("unproved", 5, title: "Sam", typed: true), row("window-sam", 6, title: "Sam")])
        try check(noProof.groups == [["x"], ["new", "draft-1", "draft-2", "unproved"], ["window-sam"]], "named typed title alone cannot retroactively prove an anonymous draft")
        let distinct = try groups([row("a", 0, title: "Maya"), row("b", 1, title: "Maya Chen"), row("c", 2, title: "Sam"), row("a2", 3, title: "Maya")])
        try check(distinct.groups == [["a", "a2"], ["b"], ["c"]], "different conversations seconds apart remain distinct, including name prefixes")
        let unknowns = try groups([row("u1", 0, title: "Messages", typed: true), row("known", 1, title: "Maya"), row("u2", 2, title: "Messages", typed: true)])
        try check(unknowns.groups == [["u1"], ["known"], ["u2"]], "anonymous sessions never stitch across an intervening conversation")
        let known = try groups([row("k1", 0, title: "Maya"), row("k2", 1, title: "Messages", typed: true, to: "Maya"), row("k3", 2, title: "Maya")])
        try check(known.groups == [["k1", "k2", "k3"]] && known.names == ["Maya"], "existing positively identified grouped-session behavior remains intact")
        var marker = row("marker", 1, title: "Maya"); marker.kind = "mouse.click"
        var after = row("after", 3, title: "Maya"); after.kind = "keyboard.submit"
        let observed = try groups([row("visible", 0, title: "Maya"), marker, row("unaddressed", 2, title: "Messages", typed: true), after])
        try check(observed.groups == [["visible", "marker", "after"], ["unaddressed"]], "named markers bracket a draft without pulling it into their conversation")
        for label in ["Messages", "New Message", "iMessage", "text message", "Delivered", "Read", "To:", "Untitled", ""] {
            try check(MessagesMomentIdentity.name(ActionProjection.make(row("label", 0, title: label))) == nil, "generic/status label never identifies a conversation: " + (label.isEmpty ? "empty" : label))
        }
        let note = ActivityNote(id: "fixture-moment", day: "2027-01-15", timezone: "UTC", subject: "Messages", actionIDs: ["anonymous"], apps: ["Messages"], sites: [], start: iso(now), end: iso(now), clusters: [], inputRevision: "fixture", status: "pending", generated: nil)
        let unknownEntity = ThreadEntities.entity(app: "Messages", bundle: bundle, site: "", title: "Messages")
        let action = ActionProjection.make(row("anonymous", 0, title: "Maya", typed: true, field: "oneLine"))
        let plan = ThreadPlanner.plan([ThreadAction(id: action.id, moment: note.id, at: now, idle: false, entity: unknownEntity)])
        let entity = plan.momentEntity[note.id]!
        try check(entity.raw == "texts:?" + note.id && entity.people.isEmpty, "anonymous thread is keyed by its own moment with no borrowed person")
        try check(MemoryStore.momentLabel(entity, moment: note, actions: [action], who: []) == "Texts", "anonymous moment display/title source ignores stale typed title")
        try check(ThreadEntities.entity(app: "Messages", bundle: bundle, site: "", title: "New Message").people.isEmpty, "New Message is never a group/person entity")
        try check(ThreadEntities.entity(app: "Messages", bundle: bundle, site: "", title: "Maya", to: "Sam").people == ["Sam"], "thread recipient authority precedes stale title")
        let field = SendRules.fieldClass(role: "AXTextField", labels: ["Message"])
        try check(field == "oneLine" && SendRules.facts(bundle: bundle, title: "Maya", field: field, seal: .submit).send == "unknown", "actual Messages role/label remains conservatively oneLine/unknown")
        // messages-1003: Return alone is never a send; a send is Return plus the composer emptying (compose-send/v1).
        try check(SendRules.facts(bundle: bundle, title: "Maya", field: "body", seal: .submit).send == "unknown", "body Return alone stays unknown (no confirmation)")
        try check(SendRules.messagesClearedSend(surface: "text", field: "body", seal: SealReason.submit.rawValue).send == "detected", "positively proved body Return plus a cleared composer detects a gesture only")
        try check(ActionProjection.make(row("draft", 0, title: "Messages", typed: true)).state == "draft", "unknown send never becomes sent")
        let stale = row("stale", 0, title: "Maya", typed: true, field: "oneLine")
        let canonical = ActionProjection.make(stale)
        try check(stale.title == "Maya" && canonical.title == "Messages" && canonical.subject == "Messages", "canonical writer presentation suppresses stale name while source evidence stays unchanged")
        try check(canonical.revision == fingerprint(ActionProjection.version + json(stale)), "canonical revision remains based on untouched source evidence")
        try check(canonical.revision != fingerprint("canonical-action-v3" + json(stale)), "changed Messages presentation invalidates its old canonical revision")
        guard let indexed = SearchDocument.make(IntentWriter.write(stale, now: now)) else { throw MemError.invalid("FAILED: synthetic Messages index document") }
        try check(!indexed.summary.contains("Maya") && indexed.summary.hasPrefix("Messages."), "derived search summary cannot preserve stale contact title")
        try check(indexed.revision != fingerprint("canonical-action-v3" + json(stale) + json(Optional<UserCorrection>.none)), "old Messages search digest is invalidated by projection version")
        let lead = LevelThread(key: "doc:garden", kind: "doc", label: "Garden plan", people: [], places: [], seconds: 600, bursts: 1, children: ["doc"], start: "a", end: "b")
        let chat = LevelThread(key: "texts:maya", kind: "texts", label: "Texts with Maya", people: ["Maya"], places: [], seconds: 120, bursts: 1, children: ["chat"], start: "a", end: "b")
        let anonymous = LevelThread(key: "texts:?draft", kind: "texts", label: "Texts", people: [], places: [], seconds: 90, bursts: 1, children: ["draft"], start: "a", end: "b")
        let bullets = LevelThreads.bullets([lead, chat, anonymous], max: 4)
        try check(bullets.first { $0.text.contains("Maya") }?.children == ["chat"] && bullets.first { $0.children.contains("draft") }?.text == "Texts, ~2 min", "block/day named conversation bullet never cites an anonymous draft")
        #if DAYDREAM_OWNER_TYPING
        try storedFixture(later)
        #endif
        print("Messages moment checks=\(checks), failures=0; synthetic only")
    }
    #if DAYDREAM_OWNER_TYPING
    static func storedFixture(_ rows: [Evidence]) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("daydream-messages-moments-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore()))
        try store.acceptSafeTyping(now: now); try store.setUpTypedVault(now: now)
        var policy = try store.policy(); policy.captureText = true; try store.updatePolicy(policy, now: now)
        for var e in rows {
            if e.kind == "keyboard.text_input" { e.text = "fictional garden plans for the weekend" }
            try check(try store.ingest(e, now: now), "synthetic Messages fixture ingested: " + e.id)
        }
        try check(try store.read("sam-draft", now: now)?.evidence.title == "Maya" && store.action("sam-draft", now: now)?.title == "Sam", "stored source title remains untouched; canonical title follows verified recipient")
        // Even corrupted/stale recipient facts on a recipient/search field
        // cannot be used by assembly or the thread planner.
        for field in ["to", "search", "oneLine", "unknown"] {
            var e = row("field-" + field, 8, title: "Sam", typed: true, to: "Sam", field: field)
            e.text = "fictional field fixture"
            try check(try store.ingest(e, now: now), "nonbody synthetic fixture ingested: " + field)
            try check(try store.read(e.id, now: now)?.evidence.title == "Sam" && store.action(e.id, now: now)?.title == "Messages", "stored unproved title is suppressed only in canonical presentation")
            try check(try store.typedUnit(e.id)?.to == nil, "writer recipient metadata refuses an unproven field")
        }
        var click = row("bracket-click", 9, title: "Maya"); click.kind = "mouse.click"
        var anonymous = row("bracket-draft", 10, title: "Maya", typed: true, field: "oneLine"); anonymous.text = "fictional unaddressed garden draft"
        var submit = row("bracket-submit", 11, title: "Maya"); submit.kind = "keyboard.submit"
        for e in [click, anonymous, submit] { try check(try store.ingest(e, now: now), "synthetic bracketing fixture ingested: " + e.id) }
        let day = try DayScope.key(now, timezone: "UTC")
        let assembled = try store.assembleDay(day: day, timezone: "UTC", now: now, notes: false)
        let moments = assembled.day.activities
        try check(moments.map(\.actionIDs) == [["x", "bracket-click", "bracket-submit"], ["new", "draft-1", "draft-2"], ["picked", "sam", "sam-draft"], ["field-oneLine", "field-search", "field-to", "field-unknown"], ["bracket-draft"]], "real assembly validates body recipient and keeps drafts outside named markers")
        try check(moments.map(\.subject) == ["Maya", "Messages", "Sam", "Messages", "Messages"], "real assembly keeps unknown drafts anonymous")
        let plan = try store.threadPlan(moments: moments, actions: assembled.actions)
        for m in moments where m.subject == "Messages" {
            let entity = plan.momentEntity[m.id]!
            try check(entity.people.isEmpty && entity.raw == "texts:?" + m.id, "real thread planner keeps anonymous moment isolated")
            let request = try store.prepareNote(kind: "activity", day: day, timezone: "UTC", activityID: m.id, now: now)
            try check(Set(request.actions.map(\.id)) == Set(m.actionIDs), "writer request cites only anonymous draft actions")
            let title = MemoryStore.momentLabel(entity, moment: m, actions: m.actionIDs.compactMap { assembled.actions[$0] }, who: [])
            try check(title == "Texts", "real moment heading is anonymous")
        }
    }
    #endif
}
