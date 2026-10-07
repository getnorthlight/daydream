import Foundation
@testable import MemoryCore
@testable import MemoryUI

private var passed = 0, failed = 0
private func check(_ ok: Bool, _ label: String) {
    print("\(ok ? "PASS" : "FAIL") \(label)")
    if ok { passed += 1 } else { failed += 1 }
}
private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private func row(_ id: String, _ words: String, seconds: Double = 0, run: String? = nil,
                 part: Int = 1, submit: Bool = true, withheld: Int = 0) -> Evidence {
    let at = iso(epoch.addingTimeInterval(seconds))
    var e = Evidence(id: id, at: at, kind: "keyboard.text_input", app: "Ghostty",
        bundle: "com.mitchellh.ghostty", title: "Claude Code", text: words, synthetic: true)
    let unit = TypedUnitProvenance(runID: run ?? id, part: part, sealReason: submit ? "submit" : "idle",
        startedAt: at, keys: nil, edits: nil, withheld: withheld, surface: "text", field: "terminal",
        send: submit ? "detected" : "unknown", sendBy: submit ? "return" : nil, to: nil)
    e.captureProvenance = NativeCaptureProvenance(policyRevision: "synthetic", classifierVersion: "sensitive-typing/v2",
        windowID: "fixture-terminal", focusID: "fixture-prompt", checkedAt: at, generation: 1, unit: unit)
    return e
}
private func action(_ evidence: Evidence) -> CanonicalAction {
    CanonicalAction(id: evidence.id, evidenceIDs: [evidence.id], at: evidence.at, kind: evidence.kind,
        app: evidence.app, bundle: evidence.bundle, site: "", title: evidence.title,
        description: "Typing observed", state: "submitted", revision: "fixture", subject: "", observationKey: "fixture")
}
@main @MainActor struct SummaryUXOwnerChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        let store = try MemoryStore(home: root, writable: true, automaticallySyncSearch: false)
        var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1
        try store.updatePolicy(policy, now: epoch)
        let keys = InMemoryTypedKeyStore()
        try store.attachVault(TypedTextVault(keyStore: keys), now: epoch)
        try store.setUpTypedVault(now: epoch); try store.acceptSafeTyping(now: epoch)
        let prompts = [
            "Read the parser and explain its inputs.", "Check the route matching logic.",
            "Add a concrete example to the docs.", "Review the import boundary.",
            "Check the route matching logic.", "Explain the cancellation behavior.",
            "Find the call site for the retry policy.", "Review the empty input path.",
            "Keep the user's date ordering.", "Check the report table labels.",
            "Review the timestamp tie breaker.", "Keep the user's date ordering.",
            "Summarize the remaining parser changes."
        ]
        let rows = prompts.enumerated().map { row("prompt-\($0.offset)", $0.element, seconds: Double($0.offset) * 100) }
        for e in rows { _ = try store.ingest(e, now: epoch.addingTimeInterval(1200)) }
        let ids = rows.map(\.id)
        let previews = try store.ownerSourceMomentPreviewsForActions(ids, now: epoch.addingTimeInterval(1201))
        let excerpts = OwnerSourceMomentProjection.standIn(previews)
        check(previews.count == 13, "synthetic 20-minute Ghostty/Claude Code fixture retains thirteen filtered owner runs")
        check(excerpts.count == 5, "stand-in is bounded at five distinct merged excerpts")
        check(excerpts.map(\.text) == [prompts[12], prompts[11], prompts[10], prompts[9], prompts[7]], "stand-in is newest-first and exact duplicate request appears once")
        check(excerpts.allSatisfy { prompts.contains($0.text) }, "stand-in only quotes captured user words")
        let history = OwnerSourceMomentProjection.history(rows.reversed().map(action), previews: previews)
        check(history.map(\.id) == ids, "history shows all thirteen actual actions in chronological order")
        check(history.allSatisfy { $0.detail.contains("Typing observed") }, "history carries actual action descriptions alongside app/window metadata")
        check(history.flatMap(\.typed).map(\.text) == prompts, "history keeps all thirteen captured prompts, including repeated real events")
        check(OwnerSourceMomentProjection.sectionOrder == [.summary, .whatHappened], "both views share Summary then What happened ordering")
        check(OwnerSourceMomentProjection.summaryExcerpts(previews, modelReady: false).count == 5, "pending summary shows bounded stand-in")
        check(OwnerSourceMomentProjection.summaryExcerpts(previews, modelReady: true).isEmpty &&
              OwnerSourceMomentProjection.history(rows.map(action), previews: previews) == history,
              "model summary replaces stand-in only; all thirteen history entries and captured wording remain")
        check(OwnerSourceMomentProjection.history(rows.map(action), previews: []).count == 13,
              "denied or expired wording still leaves every real metadata action visible")
        let p1 = row("merged-1", "Inspect the queue.", seconds: 1210, run: "merged", part: 1, submit: false)
        let p2 = row("merged-2", "Then verify cancellation.", seconds: 1211, run: "merged", part: 2)
        for e in [p1, p2] { _ = try store.ingest(e, now: epoch.addingTimeInterval(1212)) }
        let merged = try store.ownerSourceMomentPreviewsForActions([p2.id, p1.id], now: epoch.addingTimeInterval(1213))
        check(OwnerSourceMomentProjection.standIn(merged).map(\.text) == [p1.text + "\n" + p2.text], "one verified multipart run becomes one excerpt, never one per source entry")
        check(OwnerSourceMomentProjection.history([action(p2), action(p1)], previews: merged).flatMap(\.typed).map(\.text) == [p1.text, p2.text], "merged summary never merges away chronological real parts")
        for (id, words) in [("secret", "export API_TOKEN=sk-live-synthetic-abcdefghijklmnopqrstuvwxyz0123456789"),
                            ("otp", "Your verification code is 123456")] {
            _ = try store.ingest(row(id, words), now: epoch.addingTimeInterval(1300))
            let filtered = try store.ownerSourceMomentPreviewsForActions([id], now: epoch.addingTimeInterval(1301))
            // claude/terminal-details-1003: a refused run gives no words, only a withheld marker with its privacy reason.
            check(filtered.allSatisfy { $0.parts.isEmpty && $0.withheldReason != nil } && OwnerSourceMomentProjection.standIn(filtered).isEmpty,
                  "\(id) scrubber/withheld gate cannot expose a stand-in or captured quote")
        }
        var secure = row("secure", "Fictional private field"); secure.secure = true
        var privateWindow = row("private-window", "Fictional private window"); privateWindow.privateWindow = true
        for e in [secure, privateWindow, row("withheld", "Visible remainder", withheld: 1)] {
            _ = try store.ingest(e, now: epoch.addingTimeInterval(1300))
            check(try store.ownerSourceMomentPreviewsForActions([e.id], now: epoch.addingTimeInterval(1301)).allSatisfy { $0.parts.isEmpty },
                  "\(e.id) is refused by unchanged source privacy filters")
        }
        let variant1 = row("variant-1", "Review the route match.", seconds: 1400)
        let variant2 = row("variant-2", "REVIEW  the route match.", seconds: 1401)
        for e in [variant1, variant2] { _ = try store.ingest(e, now: epoch.addingTimeInterval(1402)) }
        let variants = try store.ownerSourceMomentPreviewsForActions([variant1.id, variant2.id], now: epoch.addingTimeInterval(1403))
        check(OwnerSourceMomentProjection.standIn(variants).count == 1, "look-alike case and whitespace variants share one newest excerpt")
        check(excerpts.allSatisfy { $0.label == "Asked:" && $0.text.count <= 160 }, "observed terminal requests use Asked and short source excerpts")
        let draft = row("draft-label", "Review the parser draft.", seconds: 1450, submit: false)
        _ = try store.ingest(draft, now: epoch.addingTimeInterval(1451))
        let draftPreview = try store.ownerSourceMomentPreviewsForActions([draft.id], now: epoch.addingTimeInterval(1452))
        check(OwnerSourceMomentProjection.standIn(draftPreview).first?.label == "Wrote:",
              "terminal draft is Wrote rather than an inferred ask or confirmed send")
        let long = row("excerpt-long", String(repeating: "Review the parser clauses. ", count: 10), seconds: 1500)
        _ = try store.ingest(long, now: epoch.addingTimeInterval(1501))
        let longPreviews = try store.ownerSourceMomentPreviewsForActions([long.id], now: epoch.addingTimeInterval(1502))
        check(OwnerSourceMomentProjection.standIn(longPreviews).first?.text.count == 160 &&
              OwnerSourceMomentProjection.history([action(long)], previews: longPreviews).first?.typed.first?.text == long.text.trimmingCharacters(in: .whitespacesAndNewlines),
              "summary clips source excerpt while history preserves all admitted captured words")
        let commonPrefix = String(repeating: "Review the captured parser context. ", count: 5)
        let similarA = row("similar-a", commonPrefix + "Check the route matcher.", seconds: 1510)
        let similarB = row("similar-b", commonPrefix + "Check the retry matcher.", seconds: 1511)
        for e in [similarA, similarB] { _ = try store.ingest(e, now: epoch.addingTimeInterval(1512)) }
        let similar = try store.ownerSourceMomentPreviewsForActions([similarA.id, similarB.id], now: epoch.addingTimeInterval(1513))
        check(OwnerSourceMomentProjection.standIn(similar).count == 1 &&
              OwnerSourceMomentProjection.history([action(similarB), action(similarA)], previews: similar).flatMap(\.typed).map(\.text) == [similarA.text, similarB.text],
              "look-alike short excerpt prefixes merge while differing complete requests remain in history")
        let legacy = MomentTypedLoad(blocks: [MomentTypedBlock(id: rows[0].id, at: rows[0].at,
            app: "Ghostty", bundle: rows[0].bundle, host: "", title: "Claude Code", text: "Legacy filtered words", send: nil)])
        check(OwnerSourceMomentProjection.history(rows.map(action), previews: [], typed: legacy).count == 13,
              "nonempty legacy typed path keeps thirteen chronological actual actions")
        // The complete selected scope contains thirteen safe prompts and two
        // rejected sources. Each independently complete run must pass the
        // unchanged owner proof; refused runs never hide thirteen admitted ones.
        let secrets = [row("secret", "export API_TOKEN=sk-live-synthetic-abcdefghijklmnopqrstuvwxyz0123456789"),
                       row("otp", "Your verification code is 123456")]
        let mixedIDs = ids + secrets.map(\.id)
        let legacyWholeSelection = try store.ownerSourcePreviewsForActions(mixedIDs, now: epoch.addingTimeInterval(1520))
        check(legacyWholeSelection.isEmpty, "original all-or-nothing quote API retains its whole-selection refusal")
        let mixed = try store.ownerSourceMomentPreviewsForActions(mixedIDs, now: epoch.addingTimeInterval(1520))
        var mixedState = OwnerSourceDetailState()
        let mixedTicket = mixedState.begin(scope: "fixture|safe-and-secret-terminal", actionIDs: mixedIDs)
        let mixedRevision = try store.ownerSourcePreviewRevision(now: epoch.addingTimeInterval(1520))
        check(mixed.filter { !$0.isWithheld }.count == 13 && mixedState.accept(mixed, ticket: mixedTicket, revision: mixedRevision, now: epoch.addingTimeInterval(1520)) && mixedState.previews.filter { !$0.isWithheld }.count == 13,
              "same selected session retains thirteen safe complete runs while refusing secret and OTP runs")
        let mixedHistory = OwnerSourceMomentProjection.history((rows + secrets).map(action), previews: mixedState.previews)
        check(mixedHistory.count == 15 && mixedHistory.flatMap(\.typed).map(\.text) == prompts &&
              mixedHistory.filter(\.capturedWordingUnavailable).map(\.id).sorted() == ["otp", "secret"] && Set(ids).isSubset(of: Set(mixedHistory.map(\.id))),
              "mixed selection shows all thirteen safe captured prompts and marks only secret/OTP wording unavailable")
        var editor = row("editor-draft", "Review the route diagram.", seconds: 550, submit: false)
        editor.app = "TextEdit"; editor.bundle = "com.apple.TextEdit"; editor.title = "Route notes"
        let window = Evidence(id: "window-observed", at: iso(epoch.addingTimeInterval(650)), kind: "window.observed",
            app: "TextEdit", bundle: "com.apple.TextEdit", title: "Route notes", text: "", synthetic: true)
        for e in [editor, window] { _ = try store.ingest(e, now: epoch.addingTimeInterval(1521)) }
        let interleavedRows = rows + [editor, window]
        let interleaved = try store.ownerSourceMomentPreviewsForActions(interleavedRows.map(\.id), now: epoch.addingTimeInterval(1522))
        let interleavedHistory = OwnerSourceMomentProjection.history(interleavedRows.reversed().map(action), previews: interleaved)
        check(interleavedHistory.map(\.id) == ["prompt-0", "prompt-1", "prompt-2", "prompt-3", "prompt-4", "prompt-5", "editor-draft", "prompt-6", "window-observed", "prompt-7", "prompt-8", "prompt-9", "prompt-10", "prompt-11", "prompt-12"],
              "interleaved terminal/editor/window actions stay in actual chronological order")
        check(interleavedHistory.first(where: { $0.id == editor.id })?.typed.first?.text == editor.text &&
              interleavedHistory.first(where: { $0.id == window.id })?.typed.isEmpty == true,
              "interleaved editor words attach only to its real typing action, never its observed window")
        let refusedLong = row("refused-long", String(repeating: "A fictional lengthy request. ", count: 20), seconds: 1530)
        _ = try store.ingest(refusedLong, now: epoch.addingTimeInterval(1531))
        let refusedPreview = try store.ownerSourceMomentPreviewsForActions([refusedLong.id], now: epoch.addingTimeInterval(1532))
        // claude/terminal-details-1003 (owner 10/03): the detail quotes a long prompt whole; only the stand-in stays short.
        let longHistory = OwnerSourceMomentProjection.history([action(refusedLong)], previews: refusedPreview).first
        check(longHistory?.typed.first?.text == refusedLong.text.trimmingCharacters(in: .whitespacesAndNewlines) && longHistory?.capturedWordingUnavailable == false &&
              OwnerSourceMomentProjection.standIn(refusedPreview).isEmpty,
              "a long source is quoted whole in the detail (never \"unavailable\") and never becomes a stand-in")
        let sessionPreviews = try store.ownerSourceMomentPreviewsForActions(ids, now: epoch.addingTimeInterval(1540))
        var state = OwnerSourceDetailState()
        let ticket = state.begin(scope: "fixture|terminal", actionIDs: ids)
        let revision = try store.ownerSourcePreviewRevision(now: epoch.addingTimeInterval(1540))
        check(state.accept(sessionPreviews, ticket: ticket, revision: revision, now: epoch.addingTimeInterval(1540)), "selected local session accepts filtered previews under matching disclosure revision")
        check(!state.revalidate(nil, now: epoch.addingTimeInterval(1541)) && state.previews.isEmpty,
              "loss of owner access clears captured words and stand-in immediately")
        let staleTicket = state.begin(scope: "fixture|terminal", actionIDs: ids); state.clear()
        check(!state.accept(sessionPreviews, ticket: staleTicket, revision: revision, now: epoch.addingTimeInterval(1541)), "closed selection rejects stale hydrated results")
        let expiringTicket = state.begin(scope: "fixture|terminal", actionIDs: ids)
        _ = state.accept(sessionPreviews, ticket: expiringTicket, revision: revision, now: epoch.addingTimeInterval(1541))
        let deadline = sessionPreviews.compactMap(\.expiresAt).min() ?? epoch
        check(!state.revalidate(revision, now: deadline) && state.previews.isEmpty, "existing retention deadline clears both stand-in and history wording")
        var pendingMoment = MomentSlice(id: "status-fixture", dayKey: "fixture", start: epoch, end: epoch.addingTimeInterval(1200),
            title: "Claude Code", subject: "", firstBullet: nil, bullets: [], apps: ["Ghostty"], primaryBundle: "com.mitchellh.ghostty",
            bundles: ["com.mitchellh.ghostty"], sites: [], actionIDs: ids, actionCount: 13, clusters: [], summary: .pending, hasCorrection: false)
        let openQueue = SummaryQueue(open: [pendingMoment.id], lookedAt: epoch.addingTimeInterval(1201))
        // claude/messages2-1003 (owner 10/3): no writer schedule. A moment still going has no local line; a previous summary
        // shows its bullets with at most a quiet "Updating…". 0.1.7 (notesfix, owner 10/06): not even that, never "Updating…".
        check(openQueue.line(for: pendingMoment, phase: .on(.local)).isEmpty,
              "local open moment: no status line (the refresh schedule was jargon)")
        check(openQueue.line(for: pendingMoment, phase: .on(.cloud)) == SummaryQueue.cloudOpenLine,
              "cloud open moment status retains its existing closing gate")
        pendingMoment.stale = true
        check(pendingMoment.previousSummaryStatus(phase: .on(.local), queue: openQueue) == nil &&
              pendingMoment.previousSummaryStatus(phase: .on(.cloud), queue: openQueue) == nil &&
              pendingMoment.previousSummaryStatus(phase: .off, queue: openQueue) == nil,
              "previous summary: no status line at all, never \"Updating…\" or the writer's schedule (0.1.7)")
        print("\(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
