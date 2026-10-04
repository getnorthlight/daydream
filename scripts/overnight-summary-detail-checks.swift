import Foundation
@testable import MemoryCore
@testable import MemoryUI
@testable import WriterBackend
import CoreIntegration

/// Synthetic source/store/port/detail verification only. The output submitted to
/// the core commit gate is handwritten fake-backend JSON, never model inference.
private var passed = 0, failed = 0
private func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "PASS" : "FAIL") \(label)")
    if condition { passed += 1 } else { failed += 1 }
}
private let provider = "local/overnight-fixture"
private let ownRequests = [
    "Please review DayDream's activity detail. It should show a useful recap first and the real sequence of my requests beneath it; inspect the current presentation and identify the changes needed.",
    "Look at the expanded activity card as well as the full detail. I want the same section order in both places, with the captured requests staying visible while a generated note is being prepared.",
    "The window title alone does not explain my work in Claude Code. Follow the terminal request data through the local writer and determine how the recap can express the actual design task I asked for.",
    "Before changing the layout, trace how each captured request is associated with its own action. Keep the actual chronological sequence even when several requests came from the same terminal window.",
    "Review the temporary recap shown before generation finishes. Keep it compact: show only the newest distinct request excerpts and merge repeated entries without erasing the complete action history.",
    "Please inspect the privacy checks around owner previews. The selected activity may include a scrubbed credential or a verification code; retain permitted independent requests without quoting those secrets.",
    "Check the long activity scheduling. I want a provisional local note during a continuing session, with periodic refreshes rather than waiting until I leave the terminal or end the activity.",
    "Examine what happens when I begin typing while the local model is processing a recap. Pause the background work safely and retry from an intact snapshot when the input burst has settled.",
    "Follow cancellation through the native model wrapper and the writer queue. An interrupted attempt should keep its place and avoid creating a completed note or losing the earlier captured requests.",
    "Review the retained note after more requests arrive. Make the previous recap visibly provisional while the current action list and exact captured wording continue to reflect the selected activity.",
    "Check the restart path using synthetic data. The saved queue should retain an interrupted attempt, restore its scheduling state and avoid treating a suspended model call as a successful generation.",
    "Verify the full detail using a longer realistic request sequence. Keep every actual request readable, use concise fallback excerpts and make unavailable source wording clear without inventing a quote.",
    "Give me a concise account of the proposed DayDream design changes, tying the recap presentation, periodic refresh and interruption handling together. Distinguish source checks from live application verification."
]
private func row(_ id: String, _ words: String, at: Date, state: Bool = true) -> Evidence {
    var e = Evidence(id: id, at: iso(at), kind: "keyboard.text_input", app: "Ghostty",
        bundle: "com.mitchellh.ghostty", title: "DayDream design — Claude Code", text: words, synthetic: true)
    let unit = TypedUnitProvenance(runID: id, part: 1, sealReason: state ? "submit" : "idle", startedAt: iso(at),
        keys: nil, edits: nil, withheld: 0, surface: "aiTool", field: "terminal",
        send: state ? "detected" : "unknown", sendBy: state ? "return" : nil, to: "Claude Code")
    e.captureProvenance = NativeCaptureProvenance(policyRevision: "synthetic", classifierVersion: "sensitive-typing/v2",
        windowID: "synthetic-ghostty", focusID: "synthetic-claude-code", checkedAt: iso(at), generation: 1, unit: unit)
    return e
}
private func actualActions(_ store: MemoryStore, _ ids: [String], now: Date) throws -> [CanonicalAction] {
    try ids.map { id in
        guard let value = try store.action(id, now: now) else { throw MemError.invalid("Synthetic canonical action missing") }
        return value
    }
}
private func payload(_ view: ModelView, text: String, title: String = "DayDream recap design") throws -> String {
    let aliases = view.items.filter { $0.kind == .typed }.map(\.alias)
    return String(decoding: try JSONSerialization.data(withJSONObject: ["title": title,
        "bullets": [["ids": aliases, "text": text]]]), as: UTF8.self)
}
private func checkedFake(_ request: CanonicalNoteRequest, view: ModelView) throws -> (CanonicalNoteOutput, Int) {
    let candidates = [
        "Asked Claude Code to improve DayDream's activity recap design and examine how requests are displayed, refreshed and retained during interruptions.",
        "Asked Claude Code to review DayDream's recap presentation, privacy checks, periodic updates and cancellation behavior, then plan the design changes.",
        "Asked Claude Code to assess DayDream's activity recaps and plan improvements to request visibility, local refreshes and interrupted processing."
    ]
    for (index, text) in candidates.enumerated() {
        let raw = try payload(view, text: text)
        if let output = try? CanonicalGrounding.validate(raw, request: request, view: view, provider: provider),
           (try? CanonicalGrounding.check(output, request: request, view: view)) != nil { return (output, index) }
    }
    throw MemError.invalid("No handwritten fake response passed the unchanged semantic validator")
}
@main @MainActor struct OvernightSummaryDetailChecks {
    static func main() async throws {
        guard CommandLine.arguments.count > 1 else { throw MemError.invalid("An isolated synthetic fixture root is required") }
        print("EVIDENCE synthetic source/port/detail checks; handwritten fake backend; no actual model or UI evidence")
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("overnight-detail-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let start = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: yesterday)!
        let day = try DayScope.key(start, timezone: "UTC")
        let store = try MemoryStore(home: root.appendingPathComponent("store"), writable: true, automaticallySyncSearch: false)
        try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore()), now: now)
        var capture = try store.policy(); capture.captureText = true; capture.typedConsentVersion = 1
        try store.updatePolicy(capture, now: now)
        try store.setUpTypedVault(now: now); try store.acceptSafeTyping(now: now)
        var typing = try store.typedTextPolicy()
        typing.categories = TypedCategoryChoices(searchAndAI: true, writing: true, code: true, messagesAndEmail: true, otherWebsites: true)
        _ = try store.updateTypedTextPolicy(typing, confirmed: true, now: now)
        check(try store.typedTextPolicyVerified() && store.typedTextPolicy().consented && store.typedTextPolicy().categories.code,
              "synthetic terminal consent is signed and explicit; production privacy defaults are unchanged")
        check(ownRequests.count == 13 && ownRequests.allSatisfy { $0.count < 400 } && ownRequests.joined().count > 1600,
              "realistic thirteen-request fixture exceeds one concatenated quote bound while every independent source fits owner proof")
        let rows = ownRequests.enumerated().map { row("request-\($0.offset)", $0.element, at: start.addingTimeInterval(Double($0.offset) * 100)) }
        for e in rows { check(try store.ingest(e, now: now), "real Ghostty request \(e.id) passes actual owner-build intake") }
        check(try store.typedCounts().sealed == 13, "all thirteen admitted request sources are actually sealed rather than fabricated NoteAction descriptions")
        let ids = rows.map(\.id), actions = try actualActions(store, ids, now: now)
        let before = try store.ownerSourceMomentPreviewsForActions(ids, now: now)
        check(before.count == 13, "actual owner hydration yields thirteen independently complete Ghostty requests")
        let historyBefore = OwnerSourceMomentProjection.history(actions.reversed(), previews: before)
        check(historyBefore.map(\.id) == ids && historyBefore.flatMap(\.typed).map(\.text) == ownRequests,
              "pending detail preserves every real action and exact captured request in chronological order")
        let excerptBefore = OwnerSourceMomentProjection.summaryExcerpts(before, modelReady: false, actions: actions)
        check(excerptBefore.count == 5 && excerptBefore.allSatisfy { $0.text.count <= 160 && $0.label == "Asked:" },
              "pending stand-in is at most five short own-request excerpts rather than thirteen entry placeholders")
        check(excerptBefore.map(\.id) == ["request-12", "request-11", "request-10", "request-9", "request-8"],
              "realistic stand-in retains the five newest distinct captured requests")
        check(OwnerSourceMomentProjection.sectionOrder == [.summary, .whatHappened], "actual detail and expanded-card projection shares summary-before-history order")
        let layers = try store.dayLayers(day: day, timezone: "UTC", now: now)
        guard let activity = layers.activities.first(where: { Set(ids).isSubset(of: Set($0.actionIDs)) }) else {
            throw MemError.invalid("Actual Ghostty activity grouping split the thirteen-request fixture")
        }
        let beforeSlice = MomentSlice.make(note: activity, dayPartial: layers.partial, summaries: SummaryAvailability(provider: .local, busy: false),
            calendar: calendar, pageActions: actions)
        check(!beforeSlice.summary.isReady && beforeSlice.actionIDs.count == 13, "actual store-to-UI moment has thirteen pending requests before fake commit")
        let binding = CoreWriterBinding(store: store, typedWriter: .local), port = binding.port(audience: .local)
        let target = WriterTarget(kind: .activity, day: day, timezone: "UTC", activityID: activity.id)
        let request = try await port.prepare(target)
        check(request.actionCount == 13 && Set(request.actions.map(\.id)) == Set(ids), "actual local writer port prepares all thirteen captured action identities")
        check(zip(ids, ownRequests).allSatisfy { id, words in request.actions.first(where: { $0.id == id })?.description.contains(words) == true },
              "actual local writer hydration reflects each complete own request rather than app/window-only placeholders")
        check(await port.permitted(request, request.actions), "real port revalidates the prepared local snapshot")
        let localView = try ModelView(request: request, actions: request.actions, localIntentSessions: true)
        let sessions = localView.items.filter(\.requestSession)
        check(sessions.count == 1 && sessions[0].parts.count == 13 && sessions[0].guards.count == 13,
              "actual hydrated local input forms one summary-intent session while preserving thirteen copy guards")
        check(ownRequests.allSatisfy { localView.text.contains($0) } && localView.text.contains("Request 13:"),
              "actual local prompt includes all thirteen realistic own requests without a whole-session quote cutoff")
        let instruction = CanonicalGrounding.instruction(for: localView)
        check(instruction.contains("shared intent") && localView.text.utf8.count <= ModelView.maxViewBytes,
              "actual local instruction describes shared captured intent within the production evidence bound")
        check((try? QwenNoThinkingTemplate.render(instruction: instruction, evidence: localView.text, prefill: CanonicalGrounding.prefill)) != nil,
              "actual prepared local instruction and evidence fit the unchanged no-thinking template bounds")
        let (fakeOutput, candidate) = try checkedFake(request, view: localView)
        check(fakeOutput.generator == provider && fakeOutput.bullets.flatMap(\.actionIDs).sorted() == ids.sorted(),
              "handwritten fake output passes unchanged validator with all real action citations and no code fallback")
        print("FAKE_BACKEND validator-accepted candidate \(candidate); provenance is handwritten synthetic JSON, not inference")
        _ = try await port.commit(fakeOutput)
        let reloaded = try store.dayLayers(day: day, timezone: "UTC", now: Date())
        guard let committedActivity = reloaded.activities.first(where: { $0.id == activity.id }), let note = committedActivity.generated else {
            throw MemError.invalid("Handwritten fake output did not survive real canonical commit/readback")
        }
        let afterActions = try actualActions(store, ids, now: Date())
        let after = try store.ownerSourceMomentPreviewsForActions(ids, now: Date())
        let afterSlice = MomentSlice.make(note: committedActivity, dayPartial: reloaded.partial,
            summaries: SummaryAvailability(provider: .local, busy: false), calendar: calendar, pageActions: afterActions)
        let modelReady = afterSlice.summary.isReady && !afterSlice.byCode && afterSlice.bullets.contains { !$0.correction }
        check(note.output.generator == provider && note.status == "generated_unverified" && modelReady,
              "fake backend commit reloads as an unverified current local note through the actual moment adapter")
        check(afterSlice.bullets.flatMap(\.actionIDs).sorted() == ids.sorted(), "actual generated-note-to-UI adapter keeps all thirteen fake-summary citations")
        check(OwnerSourceMomentProjection.summaryExcerpts(after, modelReady: modelReady, actions: afterActions).isEmpty,
              "persisted fake summary removes only the bounded stand-in")
        check(OwnerSourceMomentProjection.history(afterActions.reversed(), previews: after) == historyBefore,
              "all thirteen actual chronological actions and own captured requests remain identical after real fake-summary commit")
        let secrets = [row("secret", "Review this synthetic setting: API_TOKEN=sk-live-synthetic-abcdefghijklmnopqrstuvwxyz0123456789", at: start.addingTimeInterval(450)),
                       row("otp", "My verification code is 123456; please review the privacy handling.", at: start.addingTimeInterval(950))]
        for e in secrets { check(try store.ingest(e, now: Date()), "mixed \(e.id) record is actually admitted with secret content scrubbed") }
        let mixedIDs = ids + secrets.map(\.id)
        let mixedActions = try actualActions(store, mixedIDs, now: Date())
        let mixed = try store.ownerSourceMomentPreviewsForActions(mixedIDs, now: Date())
        let mixedHistory = OwnerSourceMomentProjection.history(mixedActions.reversed(), previews: mixed)
        check(mixed.filter { !$0.isWithheld }.count == 13 && mixed.filter(\.isWithheld).allSatisfy { $0.parts.isEmpty } && mixedHistory.count == 15 && mixedHistory.flatMap(\.typed).map(\.text) == ownRequests,
              "same mixed session retains thirteen safe request quotes and all fifteen actual actions")
        check(mixedHistory.filter(\.capturedWordingUnavailable).map(\.id).sorted() == ["otp", "secret"],
              "only refused secret and OTP runs receive captured-wording-unavailable metadata")
        check(OwnerSourceMomentProjection.standIn(mixed, actions: mixedActions).allSatisfy { !$0.text.contains("123456") && !$0.text.contains("sk-live") },
              "mixed bounded stand-in cannot disclose scrubbed secret or OTP values")
        let mixedLayers = try store.dayLayers(day: day, timezone: "UTC", now: Date())
        guard let mixedActivity = mixedLayers.activities.first(where: { Set(mixedIDs).isSubset(of: Set($0.actionIDs)) }) else {
            throw MemError.invalid("Mixed actual activity grouping lost a source identity")
        }
        let mixedRequest = try await port.prepare(WriterTarget(kind: .activity, day: day, timezone: "UTC", activityID: mixedActivity.id))
        let mixedView = try ModelView(request: mixedRequest, actions: mixedRequest.actions, localIntentSessions: true)
        check(ownRequests.allSatisfy { mixedView.text.contains($0) }, "actual mixed local prompt preserves every safe own request despite refused independent source runs")
        check(!mixedView.text.contains("123456") && !mixedView.text.contains("sk-live") && !mixedView.text.contains("abcdefghijklmnopqrstuvwxyz0123456789"),
              "actual mixed local prompt refuses scrubbed secret and OTP values")
        try await port.cancel(mixedRequest.id)
        print("RESULT \(passed) passed \(failed) failed; ACTUAL_MODEL_UNVERIFIED; LIVE_UI_UNVERIFIED")
        if failed > 0 { exit(1) }
    }
}
