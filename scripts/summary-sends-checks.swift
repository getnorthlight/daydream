// fix/summary-sends: regressions for the overnight QA findings QF-13, QF-14 and QF-15 (qa-0930/QA-FINDINGS.md,
// "Summaries"). Synthetic requests and records only: no model, store file, network, Keychain or capture.
// Compiles against the base (fix/writing-forever 2376cd3) too, where the QF checks fail.
//
// QF-13 word-less typed rows of one app+site folded into one item whose send facts are its LAST part's: a post sent with
//       Command-Return followed by a draft read "sending unknown" ("Posted on X" refused: an under-claim).
// QF-14 the writer accepted "Posted on X" labelled draft over a draft plus a sent post; core refuses it (every cited typed
//       row must be submitted), the commit threw with no salvage and the app retried the same answer.
// QF-15 `read` (IntentWriter, the reader line, AI apps' lines) said a row sent with its send key was only "typed".
@testable import MemoryCore
import WriterBackend
import Foundation

var failures = 0, passes = 0
func check(_ ok: Bool, _ name: String) {
    if ok { passes += 1; print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

/// Core's claim rule for one bullet, copied from MemoryStore.commitNote (Sources/MemoryCore/DerivedNotes.swift: "Send
/// claim lacks verified delivery evidence", "Send claim lacks a detected send", "Draft claim has mismatched evidence"),
/// so this file compiles on the base. true: core accepts the bullet's claim.
func coreAccepts(_ title: String, _ b: GroundedBullet, _ acts: [NoteAction]) -> Bool {
    let byID = Dictionary(uniqueKeysWithValues: acts.map { ($0.id, $0) })
    let text = title + " " + b.text
    let claimsSend = text.range(of: "(?i)\\b(sent|delivered|published)\\b", options: .regularExpression) != nil
    let allSent = b.actionIDs.allSatisfy { byID[$0]?.state == "sent" }
    if b.assertion == "sent" || claimsSend { guard b.assertion == "sent", allSent else { return false } }
    let claimsSubmit = text.range(of: "(?i)\\b(emailed|messaged|posted|texted|replied)\\b", options: .regularExpression) != nil
    let typed = b.actionIDs.compactMap { byID[$0] }.filter { $0.kind == "keyboard.text_input" }
    if b.assertion == "submitted" || (claimsSubmit && !(b.assertion == "sent" && allSent)) {
        let own = typed.filter { !["to", "subject"].contains($0.field ?? "") }
        guard b.assertion == "submitted", !own.isEmpty, own.allSatisfy({ $0.state == "submitted" }) else { return false }
    }
    if b.assertion == "draft" && !b.actionIDs.allSatisfy({ ["draft", "typed", "drafted_request", "submitted"].contains(byID[$0]?.state ?? "") }) { return false }
    return true
}

/// A word-less typed row (the writer can't read the words: typing off, expired, key locked or lost).
func typedRow(_ i: Int, app: String = "Google Chrome", site: String = "x.com", title: String = "Home / X", surface: String = "social",
              sent: Bool, run: String, to: String? = nil) -> [String: Any] {
    var r: [String: Any] = ["id": "r\(i)", "at": String(format: "2026-09-30T06:%02d:00Z", 10 + i), "kind": "keyboard.text_input", "app": app, "site": site,
        "title": title, "state": sent ? "submitted" : "draft", "revision": "v\(i)", "surface": surface, "send": sent ? "detected" : "unknown",
        "runID": run, "field": "textArea",
        "description": sent ? "Typed in \(app), then used its send key (a sentence)." : "Typed a draft in \(app) (a sentence)."]
    if sent { r["sendBy"] = "commandReturn" }
    if let to { r["to"] = to }
    return r
}
func request(_ id: String, _ rows: [[String: Any]]) throws -> CanonicalNoteRequest {
    let json: [String: Any] = ["id": id, "schemaVersion": 1, "targetKind": "activity", "targetID": id, "day": "2026-09-30", "timezone": "UTC",
        "inputRevision": id, "policyRevision": "p", "expiresAt": "2099-01-01T00:00:00Z", "actions": rows, "actionCount": rows.count]
    return try JSONDecoder().decode(CanonicalNoteRequest.self, from: JSONSerialization.data(withJSONObject: json))
}
func answer(_ ids: [String], _ text: String) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: ["title": "X", "bullets": [["ids": ids, "text": text]]])) ?? Data(), as: UTF8.self)
}
func answers(_ bullets: [([String], String)]) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: ["title": "X", "bullets": bullets.map { ["ids": $0.0, "text": $0.1] }])) ?? Data(), as: UTF8.self)
}
func alias(_ v: ModelView, _ id: String) -> String { v.owner(of: id)?.alias ?? "i0" }
func line(_ v: ModelView, _ a: String) -> String { v.text.split(separator: "\n").first { $0.hasPrefix(a + ". ") }.map(String.init) ?? "" }
func validated(_ raw: String, _ r: CanonicalNoteRequest, _ v: ModelView) -> CanonicalNoteOutput? {
    try? CanonicalGrounding.validate(raw, request: r, view: v, provider: CanonicalLocalWriter.provider)
}
func coreAcceptsAll(_ out: CanonicalNoteOutput, _ r: CanonicalNoteRequest) -> Bool { out.bullets.allSatisfy { coreAccepts(out.title, $0, r.actions) } }

/// A core that refuses every commit with a claim refusal (MemoryStore.commitNote's text).
struct ClaimRefusal: Error, CustomStringConvertible { var description: String { "invalid(\"Send claim lacks a detected send\")" } }
actor Commits { var n = 0; func add() { n += 1 }; func count() -> Int { n } }


// ---------------- claude/messages-1003: Messages, one bullet per conversation ----------------
// The owner's three texts to one person read "Typed a draft in Messages." / "Drafted a text about the message to
// unknown.". Synthetic texts and fictional names only.
var msgN = 0
/// A Messages typed row as the capture fix seals it: surface text, field message, send detected with Return and the
/// conversation's name in `to` for a sent text; send unknown for a draft. The writer sees the words (typing on).
func msg(_ words: String, to: String?, sent: Bool, run: String? = nil, title: String? = nil) -> [String: Any] {
    msgN += 1
    var r: [String: Any] = ["id": "t\(msgN)", "at": String(format: "2026-10-03T18:%02d:00Z", msgN), "kind": "keyboard.text_input", "app": "Messages", "site": "",
        "title": title ?? to ?? "Messages", "state": sent ? "submitted" : "draft", "revision": "v", "surface": "text", "field": "message",
        "send": sent ? "detected" : "unknown", "runID": run ?? "run\(msgN)", "description": "Typed a draft in Messages. " + words]
    if sent { r["sendBy"] = "return" }
    if let to { r["to"] = to }
    return r
}
/// The keyboard.submit marker each Return writes.
func ret(_ to: String?) -> [String: Any] {
    msgN += 1
    return ["id": "k\(msgN)", "at": String(format: "2026-10-03T18:%02d:00Z", msgN), "kind": "keyboard.submit", "app": "Messages", "site": "", "title": to ?? "Messages",
            "state": "observed", "revision": "v", "description": "Pressed Return in Messages; sending is not established."]
}
func fallbackLines(_ r: CanonicalNoteRequest, _ v: ModelView) -> [GroundedBullet]? {
    (try? CanonicalGrounding.check(CanonicalGrounding.fallbackNote(r, view: v), request: r, view: v))?.bullets
}
/// Core's verbatim guard (TypedVerbatimGuard, the rule commitNote runs) over every typed row of the request.
func coreCopies(_ text: String, _ r: CanonicalNoteRequest) -> Bool {
    r.actions.filter { $0.kind == "keyboard.text_input" }.contains { a in
        let words = String(a.description.dropFirst("Typed a draft in Messages. ".count))
        return TypedVerbatimGuard.copies(text, fromAny: [words], places: [a.to ?? "", a.title].filter { !$0.isEmpty }, field: a.field ?? "")
    }
}
func checked(_ raw: String, _ r: CanonicalNoteRequest, _ v: ModelView) -> CanonicalNoteOutput? {
    validated(raw, r, v).flatMap { try? CanonicalGrounding.check($0, request: r, view: v) }
}
let gendered = try! NSRegularExpression(pattern: "(?i)\\b(he|him|his|she|her|hers)\\b")
func noBadWords(_ lines: [String]) -> Bool {
    lines.allSatisfy { l in !l.hasPrefix("Typed a draft") && l.range(of: "(?i)\\bunknown\\b", options: .regularExpression) == nil
        && gendered.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) == nil }
}

// ---------------- claude/messages-1003: compose-send/v1, replies carry what they answered ----------------
/// A typed row on a web composer with the compose facts capture reads (metadata only). Synthetic text, fictional names.
func post(_ words: String, app: String = "Google Chrome", site: String, title: String, surface: String, sent: Bool, sendBy: String? = "return",
          field: String = "textArea", extra: [String: Any] = [:]) -> [String: Any] {
    msgN += 1
    var r: [String: Any] = ["id": "t\(msgN)", "at": String(format: "2026-10-03T19:%02d:00Z", msgN), "kind": "keyboard.text_input", "app": app, "site": site,
        "title": title, "state": sent ? "submitted" : "draft", "revision": "v", "surface": surface, "field": field,
        "send": sent ? "detected" : "unknown", "runID": "run\(msgN)", "description": "Typed a draft in \(app). " + words]
    if sent, let sendBy { r["sendBy"] = sendBy }
    for (k, v) in extra { r[k] = v }
    return r
}
func visit(_ title: String, site: String) -> [String: Any] {
    msgN += 1
    return ["id": "w\(msgN)", "at": String(format: "2026-10-03T19:%02d:00Z", msgN), "kind": "browser.tab_visited", "app": "Google Chrome", "site": site,
            "title": title, "state": "observed", "revision": "v", "description": "Visited a page."]
}
/// Core's verbatim guard over every typed row, whatever its app.
func coreCopiesAny(_ text: String, _ r: CanonicalNoteRequest) -> Bool {
    r.actions.filter { $0.kind == "keyboard.text_input" }.contains { a in
        let words = String(a.description.dropFirst("Typed a draft in \(a.app). ".count))
        return TypedVerbatimGuard.copies(text, fromAny: [words], places: [a.to ?? "", a.title].filter { !$0.isEmpty }, field: a.field ?? "")
    }
}

@main struct SummarySendsChecks {
    static func main() async throws {
        // ---------------- QF-13: a sent post is not hidden by a later draft ----------------
        let r13 = try request("qf13", [typedRow(1, sent: false, run: "a"), typedRow(2, sent: true, run: "b"), typedRow(3, sent: false, run: "c")])
        let v13 = try ModelView(request: r13, actions: r13.actions)
        let sentAlias = alias(v13, "r2"), draftAlias = alias(v13, "r1")
        check(sentAlias != draftAlias, "QF-13 a word-less row sent with Command-Return is not folded into the drafts on the same site")
        check(line(v13, sentAlias).contains("sent with Command-Return"), "QF-13 the sent row's ITEMS line says it was sent with Command-Return")
        check(!line(v13, draftAlias).contains("sent with"), "QF-13 never promote a draft: the drafts' line says no send")
        check(alias(v13, "r3") == draftAlias, "QF-13 word-less drafts on one site still fold into one item")
        check(validated(answer([draftAlias], "Posted on X"), r13, v13) == nil, "QF-13 \"Posted on X\" citing only the drafts is refused")
        // The QA case (qa-0930 ChatGPT moment): sent, draft, sent, draft prompts in ChatGPT were one item, and the note said
        // "Drafted a message to ChatGPT" for two sent prompts. The sent prompts are now their own item and "Asked ChatGPT" holds.
        let g = (0..<4).map { typedRow($0 + 1, app: "ChatGPT", site: "", title: "ChatGPT", surface: "ai", sent: $0 % 2 == 0, run: "g\($0)", to: "ChatGPT") }
        let rg = try request("qf13g", g)
        let vg = try ModelView(request: rg, actions: rg.actions)
        let gSent = alias(vg, "r1"), gDraft = alias(vg, "r2")
        check(gSent != gDraft && alias(vg, "r3") == gSent && alias(vg, "r4") == gDraft, "QF-13 ChatGPT: the sent prompts and the drafts are separate items")
        let asked = validated(answers([([gSent], "Asked ChatGPT"), ([gDraft], "Drafted a message to ChatGPT")]), rg, vg)
        check(asked != nil, "QF-13 ChatGPT: \"Asked ChatGPT\" citing the sent prompts passes the writer check")
        let askedBullet = asked?.bullets.first { $0.actionIDs.contains("r1") }
        check(askedBullet?.assertion == "submitted" && Set(askedBullet?.actionIDs ?? []) == ["r1", "r3"], "QF-13 ChatGPT: it is labelled submitted and cites only the sent prompts")
        check(asked.map { coreAcceptsAll($0, rg) } ?? false, "QF-13 ChatGPT: core's claim rule accepts that note")
        check(validated(answers([([gDraft], "Asked ChatGPT"), ([gSent], "Drafted a message to ChatGPT")]), rg, vg).map { coreAcceptsAll($0, rg) } ?? true,
              "QF-13 ChatGPT: \"Asked\" over the drafts is refused, or core accepts it (never a draft promoted to a send)")
        // Two sends on one site stay one sent item; an email's send is kept the same way.
        let r13b = try request("qf13b", [typedRow(1, sent: true, run: "a"), typedRow(2, sent: true, run: "b")])
        let v13b = try ModelView(request: r13b, actions: r13b.actions)
        check(alias(v13b, "r1") == alias(v13b, "r2") && line(v13b, alias(v13b, "r1")).contains("sent with"), "QF-13 two word-less sends on one site fold together and stay sent")
        let post13 = validated(answer([alias(v13b, "r1")], "Posted on X"), r13b, v13b)
        check(post13?.bullets.first?.assertion == "submitted" && post13.map { coreAcceptsAll($0, r13b) } == true, "QF-13 \"Posted on X\" over sent posts passes the writer check and core, label submitted")
        let r13c = try request("qf13c", [typedRow(1, site: "mail.google.com", title: "Inbox", surface: "email", sent: true, run: "a"),
                                         typedRow(2, site: "mail.google.com", title: "Inbox", surface: "email", sent: false, run: "b")])
        let v13c = try ModelView(request: r13c, actions: r13c.actions)
        check(line(v13c, alias(v13c, "r1")).contains("sent with Command-Return"), "QF-13 Gmail: a Command-Return send followed by a draft still reads sent")

        // ---------------- QF-14: the writer never hands core a note core refuses ----------------
        let r14 = try request("qf14", [typedRow(1, sent: false, run: "a"), typedRow(2, sent: true, run: "b")])
        let v14 = try ModelView(request: r14, actions: r14.actions)
        let both = Array(Set([alias(v14, "r1"), alias(v14, "r2")])).sorted()
        let post14 = validated(answer(both, "Posted on X"), r14, v14)
        check(post14.map { coreAcceptsAll($0, r14) } ?? true,
              "QF-14 \"Posted on X\" over a draft plus a sent post: the writer refuses it, or core accepts what it passed (label \(post14?.bullets.first?.assertion ?? "-"))")
        // Every note the writer passes for these moments is one core accepts (the salvage and repair paths included).
        var agreed = true
        for (text, ids) in [("Posted on X", both), ("Drafted a post on X", both), ("Posted on X", [alias(v14, "r2")]), ("Typed a draft on X", [alias(v14, "r1")])] {
            if let out = validated(answer(ids, text), r14, v14), !coreAcceptsAll(out, r14) { agreed = false; print("  disagree: \(text) -> \(out.bullets.map { $0.assertion })") }
            if let out = try? CanonicalGrounding.salvage(answer(ids, text), request: r14, view: v14, provider: CanonicalLocalWriter.provider), !coreAcceptsAll(out, r14) {
                agreed = false; print("  salvage disagrees: \(text) -> \(out.bullets.map { "\($0.assertion): \($0.text)" })")
            }
        }
        check(agreed, "QF-14 writer-accepted and salvaged notes all pass core's claim rule")
        // The commit backstop: core refuses a note's claim -> the moment ends pending with its code-written fallback
        // (invalidOutput: final in local mode), never a thrown error the app retries with the same answer.
        let claude = typedRow(1, app: "Claude", site: "", title: "Claude", surface: "ai", sent: true, run: "a", to: "Claude")
        let rc = try request("qf14c", [claude])
        let vc = try ModelView(request: rc, actions: rc.actions)
        let commits = Commits()
        let port = CoreWriterPort(prepare: { _ in rc }, page: { _, _ in WriterActionPage(actions: [], next: nil, actionCount: 1) },
                                  commit: { _ in await commits.add(); throw ClaimRefusal() }, cancel: { _ in }, permitted: { _, _ in true })
        let adapter = CoreWriterAdapter(core: port, generate: { r, _ in try CanonicalGrounding.validate(answer([alias(vc, "r1")], "Asked Claude"), request: r, view: vc, provider: CanonicalLocalWriter.provider) })
        var outcome = "threw"
        do {
            switch try await adapter.process(WriterTarget(kind: .activity, day: "2026-09-30", timezone: "UTC", activityID: "qf14c"), lastActivity: .distantPast) {
            case .committed: outcome = "committed"
            case .pending(let p): outcome = "pending(\(p.reason.rawValue))"
                check(p.fallback.count == 1 && p.fallback[0].assertion == "submitted" && !p.fallback[0].text.lowercased().contains("sent a"),
                      "QF-14 the fallback is the row's own truthful line (label submitted, no delivery claim)")
            }
        } catch { outcome = "threw \(type(of: error))" }
        check(outcome == "pending(invalidOutput)", "QF-14 a core claim refusal at commit ends pending(invalidOutput), not a retry (got \(outcome))")
        check(await commits.count() == 1, "QF-14 the refused note is committed once, not again")

        // ---------------- QF-15: `read` says a send key was used, never "sent" ----------------
        var e = Evidence(id: "t1", at: "2026-09-30T06:00:00Z", kind: "keyboard.text_input", app: "Claude", bundle: "com.anthropic.claudefordesktop")
        e.typed = TypedRef(digest: "d", words: 6)
        e.captureProvenance = NativeCaptureProvenance(policyRevision: "p", classifierVersion: "c", windowID: "w", focusID: "f", checkedAt: e.at, generation: 1,
            unit: TypedUnitProvenance(runID: "u", part: 1, sealReason: "send", startedAt: e.at, keys: 30, edits: 0, withheld: 0, surface: "ai", field: "textArea", send: "detected", sendBy: "return"))
        let item = IntentWriter.write(e)
        check(item.actionState == "submitted", "QF-15 IntentWriter: a row sealed with its send key is submitted (got \(item.actionState))")
        check(item.summary.contains("then used its send key") && item.summary.range(of: "(?i)\\bsent\\b", options: .regularExpression) == nil, "QF-15 IntentWriter's line says the send key, never \"sent\"")
        let reader = MemoryStore.withoutTypedWords(item, status: TypedStatus(state: .live, words: 6))
        check(reader.actionState == "submitted", "QF-15 read: actionState submitted, as `actions` says (got \(reader.actionState))")
        check(reader.summary == "Typed in Claude, then used its send key, a sentence (exact words not shared with AI apps).", "QF-15 read: detail line (\(reader.summary))")
        var stale = item; stale.actionState = "typed"   // a per-record item saved by an earlier build
        check(MemoryStore.withoutTypedWords(stale, status: TypedStatus(state: .live, words: 6)).actionState == "submitted", "QF-15 read: an item saved before the fix reads submitted too")
        var d = e; d.captureProvenance?.unit?.send = "unknown"
        let draft = MemoryStore.withoutTypedWords(IntentWriter.write(d), status: TypedStatus(state: .live, words: 6))
        check(draft.actionState == "typed" && draft.summary == "Typed in Claude, a sentence (exact words not shared with AI apps).", "QF-15 a draft is unchanged (\(draft.actionState): \(draft.summary))")
        let act = try JSONDecoder().decode(CanonicalAction.self, from: JSONSerialization.data(withJSONObject: ["id": "t1", "evidenceIDs": ["t1"], "at": e.at, "kind": "keyboard.text_input",
            "app": "Claude", "bundle": "com.anthropic.claudefordesktop", "site": "", "title": "", "description": TypedWords.submittedDescription(app: "Claude", words: 6),
            "state": "submitted", "revision": "r", "subject": "", "observationKey": "k"]))
        let aiLine = AssistantView.line(act, typed: TypedStatus(state: .live, words: 6))
        check(aiLine.contains("then used its send key") && !aiLine.lowercased().contains(" sent "), "QF-15 AI apps' line (search snippets, MCP) says the send key (\(aiLine))")
        check(AssistantView.line(act).contains("then used its send key"), "QF-15 AI apps' line without a status says the send key")


        // ---------------- claude/messages-1003: Messages, one bullet per conversation ----------------
        // 1. Three texts sent to one person, each with Return (the owner's case).
        let three = try request("m3", [msg("me and my friends are going to ZUX tmrw", to: "Jamie Lin", sent: true), ret("Jamie Lin"),
                                       msg("wanna meet us there?", to: "Jamie Lin", sent: true), ret("Jamie Lin"),
                                       msg("were gonna have a great time", to: "Jamie Lin", sent: true), ret("Jamie Lin")])
        let v3 = try ModelView(request: three, actions: three.actions)
        let typed3 = v3.items.filter { $0.kind == .typed }
        check(typed3.count == 1 && line(v3, "i1").contains("\"wanna meet us there?\"") && line(v3, "i1").contains("each sent with Return")
              && line(v3, "i1").contains("Start with: Texted Jamie Lin"), "Messages: three texts to one person are one item, every text in order (\(line(v3, "i1")))")
        let fb3 = fallbackLines(three, v3)
        check(fb3?.map(\.text) == ["Texted Jamie Lin about ZUX and asked a question."] && fb3?.first?.assertion == "submitted"
              && Set(fb3?.first?.actionIDs ?? []).isSuperset(of: ["t1", "t3", "t5"]),
              "Messages fallback: one line for the conversation, who and what about in code's words (got \(fb3?.map(\.text) ?? []))")
        check(fb3.map { $0.allSatisfy { coreAccepts("Texts with Jamie Lin", $0, three.actions) && !coreCopies($0.text, three) } } == true && noBadWords(fb3?.map(\.text) ?? ["x"]),
              "Messages fallback: core's claim and copy rules accept it; no draft line, no \"unknown\", no he or she")
        for example in ["Texted Jamie Lin that you and friends are going to ZUX tomorrow, asked if they want to meet you there, and said it'll be a great time.",
                        "Texted Jamie that you and friends are going to ZUX tomorrow, asked if they want to meet you there, and said it'll be a great time."] {
            let out = checked(answer(["i1"], example), three, v3)
            check(out?.bullets.map(\.text) == [example] && out?.bullets.first?.assertion == "submitted" && out.map { coreAcceptsAll($0, three) } == true && !coreCopies(example, three),
                  "Messages validator: the owner's gist passes the writer, its final check and core (\(example.prefix(40))...)")
        }
        for bad in ["Typed a draft in Messages.", "Drafted a text about the message to unknown.", "Texted unknown about ZUX.", "Drafted a message to someone.",
                    "Texted Jamie Lin that you and friends are going to ZUX tomorrow and asked if she wants to meet there.",
                    "Texted Sam that you and friends are going to ZUX tomorrow and asked if they want to meet there."] {
            check(validated(answer(["i1"], bad), three, v3) == nil, "Messages validator: \"\(bad)\" is refused when the texts were sent")
        }
        check(validated(answers([(["i1"], "Texted Jamie Lin about going to ZUX tomorrow."), (["i1"], "Texted Jamie Lin about ZUX tomorrow.")]), three, v3) == nil,
              "Messages validator: two near-identical bullets for one conversation are refused")
        let salv3 = try? CanonicalGrounding.salvage(answer(["i1"], "Typed a draft in Messages."), request: three, view: v3, provider: CanonicalLocalWriter.provider)
        check(salv3.map { noBadWords($0.bullets.map(\.text)) && $0.bullets.count == 1 && $0.bullets[0].text.hasPrefix("Texted Jamie Lin") } ?? true,
              "Messages salvage: a refused draft line becomes the conversation's Texted line (got \(salv3?.bullets.map(\.text) ?? []))")
        check(CanonicalGrounding.instruction.contains("Write ONE bullet for the whole conversation") && CanonicalGrounding.instruction.contains("\"they\"/\"them\", never \"he\" or \"she\"")
              && CanonicalGrounding.instruction.contains("Never write \"unknown\""), "Messages prompt: one bullet per conversation, they/them, never unknown")

        // 2. A text sent, then a draft left in the same conversation: no draft line beside the send.
        let sd = try request("m4", [msg("running late, grab a table at Lumo", to: "Maya", sent: true), ret("Maya"), msg("actually nvm", to: "Maya", sent: false)])
        let vsd = try ModelView(request: sd, actions: sd.actions)
        check(vsd.items.filter { $0.kind == .typed }.count == 1 && line(vsd, "i1").contains("then typed \"actually nvm\" with no send seen"),
              "Messages: a draft after a send is on the conversation's line, not its own item (\(line(vsd, "i1")))")
        let fbsd = fallbackLines(sd, vsd)
        check(fbsd?.map(\.text) == ["Texted Maya about Lumo."] && fbsd?.first?.assertion == "submitted", "Messages fallback: send then draft is one Texted line (got \(fbsd?.map(\.text) ?? []))")
        check(checked(answer(["i1"], "Texted Maya that you'd be late and asked them to get a table at Lumo, then started another text."), sd, vsd) != nil,
              "Messages validator: the send's gist with a short clause for the draft passes")
        check(validated(answers([(["i1"], "Texted Maya that you'd be late."), (["i1"], "Drafted a text to Maya.")]), sd, vsd) == nil
              && validated(answer(["i1"], "Drafted a text to Maya about Lumo."), sd, vsd) == nil, "Messages validator: a draft line for a conversation with a send is refused")

        // 3. Shift-Return: one sent text with a new line in it.
        let nl = try request("m5", [msg("see you at 8\nbring the ZUX tickets", to: "Sam", sent: true), ret("Sam")])
        let vnl = try ModelView(request: nl, actions: nl.actions)
        check(line(vnl, "i1").contains("\"see you at 8 bring the ZUX tickets\"") && fallbackLines(nl, vnl)?.map(\.text) == ["Texted Sam about ZUX."],
              "Messages: a text with a new line is one text on one line; fallback \"Texted Sam about ZUX.\" (got \(fallbackLines(nl, vnl)?.map(\.text) ?? []))")
        check(checked(answer(["i1"], "Texted Sam that you'll see them at 8 and asked them to bring the ZUX tickets."), nl, vnl) != nil, "Messages validator: the newline text's gist passes")

        // 4. A New Message with no To read: "Texted someone"; its draft never takes another conversation's name.
        let nm = try request("m6", [msg("lunch friday?", to: "Sam", sent: true), ret("Sam"), msg("on my way to Lumo", to: nil, sent: true, title: "New Message"), ret(nil),
                                    msg("almost there", to: nil, sent: false, title: "New Message")])
        let vnm = try ModelView(request: nm, actions: nm.actions)
        let unnamedSend = alias(vnm, "t14"), unnamedDraft = alias(vnm, "t16")
        check(line(vnm, unnamedSend).contains("name no one") && line(vnm, unnamedSend).contains("Start with: Texted someone") && !line(vnm, unnamedDraft).contains("Sam"),
              "Messages: a send with no conversation read says \"Texted someone\"; the draft names no one")
        let fbnm = fallbackLines(nm, vnm)?.map(\.text) ?? []
        check(fbnm == ["Texted Sam and asked a question.", "Texted someone about Lumo.", "Wrote a text in Messages."] && noBadWords(fbnm)
              && CodeFallbackNote.isFallbackLine("Wrote a text in Messages.") && !NoteFiller.isFiller("Texted someone about Lumo.", apps: ["Messages"]),
              "Messages fallback: Sam's line, \"Texted someone ...\" and a line with no name, never \"draft\" (got \(fbnm))")
        let nmOK = answers([([alias(vnm, "t12")], "Texted Sam asking about lunch on Friday."), ([unnamedSend], "Texted someone that you're on the way to Lumo."),
                            ([unnamedDraft], "Drafted a text to someone about being nearly there.")])
        check(checked(nmOK, nm, vnm) != nil, "Messages validator: \"Texted someone that ...\" passes for a send with no name read")
        check(validated(answers([([alias(vnm, "t12")], "Texted Sam asking about lunch on Friday."), ([unnamedSend], "Texted Sam that you're on the way to Lumo."),
                                 ([unnamedDraft], "Drafted a text to someone about being nearly there.")]), nm, vnm) == nil,
              "Messages validator: a send with no name read never takes Sam's name")

        // 5. Two conversations in one moment, interleaved: one bullet each.
        let two = try request("m7", [msg("dinner at Lumo?", to: "Sam", sent: true), msg("call me later", to: "Maya", sent: true), msg("8 works for me", to: "Sam", sent: true)])
        let vtwo = try ModelView(request: two, actions: two.actions)
        let samA = alias(vtwo, "t17"), mayaA = alias(vtwo, "t18")
        check(samA == alias(vtwo, "t19") && samA != mayaA && vtwo.items.filter { $0.kind == .typed }.count == 2, "Messages: two conversations are two items, each person's texts together")
        check(fallbackLines(two, vtwo)?.map(\.text) == ["Texted Sam about Lumo and asked a question.", "Texted Maya."], "Messages fallback: one line per conversation (got \(fallbackLines(two, vtwo)?.map(\.text) ?? []))")
        check(checked(answers([([samA], "Texted Sam about a Lumo dinner, saying 8 works."), ([mayaA], "Texted Maya asking them to call later.")]), two, vtwo) != nil,
              "Messages validator: one bullet per conversation passes")
        check(validated(answer([samA, mayaA], "Texted Sam and Maya about dinner."), two, vtwo) == nil, "Messages validator: one bullet for two conversations is refused")

        // 6. A text saved in two pieces mid-word ("wanna me" sealed by a focus change, then "et us there?" sent): one text.
        let split = try request("m8", [msg("wanna me", to: "Sam", sent: false), msg("et us there?", to: "Sam", sent: true), ret("Sam")])
        let vsplit = try ModelView(request: split, actions: split.actions)
        check(line(vsplit, "i1").contains("typed \"wanna meet us there?\" to \"Sam\"") && vsplit.items.filter { $0.kind == .typed }.count == 1 && vsplit.owner(of: "t20") == nil,
              "Messages: a text split mid-word reads as typed, \"wanna meet us there?\", and its first piece is never cited alone (\(line(vsplit, "i1")))")
        check(fallbackLines(split, vsplit)?.map(\.text) == ["Texted Sam and asked a question."], "Messages fallback: the split text is one Texted line (got \(fallbackLines(split, vsplit)?.map(\.text) ?? []))")
        // The capture fix stores the field's whole value at Return: the earlier piece is its start, said once.
        let whole = try request("m9", [msg("wanna me", to: "Sam", sent: false), msg("wanna meet us there?", to: "Sam", sent: true)])
        check(line(try ModelView(request: whole, actions: whole.actions), "i1").contains("typed \"wanna meet us there?\" to"), "Messages: a sent text that holds its earlier piece says it once")
        let sameRun = try request("m10", [msg("wanna me", to: "Sam", sent: false, run: "w"), msg("et us there?", to: "Sam", sent: true, run: "w")])
        check(line(try ModelView(request: sameRun, actions: sameRun.actions), "i1").contains("typed \"wanna meet us there?\" to"), "Messages: two parts of one typing run join as typed, no space added")
        check(CanonicalGrounding.sharedFiller("Drafted a message to someone.", apps: []) && NoteFiller.isFiller("Drafted a message to someone.", apps: [])
              && !CanonicalGrounding.sharedFiller("Texted someone in Messages.", apps: ["Messages"]), "filler: \"Drafted a message to someone.\" names no one, in the writer and on the Today page")
        // 7. compose-send/v1 (coordinator, 10/3): a reply says what it answered, and replaces the "Viewed" line for that post.
        let adaTitle = "Ada on X: \"Small tools beat big frameworks for most side projects\" / X"
        let adaCtx: [String: Any] = ["contextAuthor": "Ada", "contextExcerpt": "Small tools beat big frameworks for most side projects", "handle": "ada"]
        let adaGist = "Replied to Ada's post about small tools beating big frameworks, saying it'll help with weekend projects."
        for (name, sendBy, ctl, confirm) in [("button", "button", "reply", "composerClosed"), ("Command-Return", "commandReturn", "", "fieldCleared")] {
            var extra = adaCtx; extra["confirm"] = confirm; if !ctl.isEmpty { extra["sendControl"] = ctl }
            let rx = try request("x-\(sendBy)", [visit(adaTitle, site: "https://x.com"),
                                                post("this is gonna help so much with my weekend projects", site: "https://x.com", title: adaTitle, surface: "social", sent: true, sendBy: sendBy, extra: extra)])
            let vx = try ModelView(request: rx, actions: rx.actions)
            let reply = rx.actions[1].id, viewed = rx.actions[0].id
            check(vx.items.count == 1 && alias(vx, viewed) == alias(vx, reply) && line(vx, "i1").contains("in reply to Ada's post \"Small tools beat big frameworks")
                  && line(vx, "i1").contains("Start with: Replied to Ada's post on X"),
                  "X reply (\(name)): one item, the post viewed folds into the reply, which names what it answered (\(line(vx, "i1")))")
            let out = checked(answer(["i1"], adaGist), rx, vx)
            check(out?.bullets.map(\.text) == [adaGist] && out?.bullets.first?.assertion == "submitted" && out.map { coreAcceptsAll($0, rx) } == true && !coreCopiesAny(adaGist, rx),
                  "X reply (\(name)): the owner's reply gist passes the writer, its final check and core")
            let fb = fallbackLines(rx, vx)
            check(fb?.map(\.text) == ["Replied to Ada's post on X (“Small tools beat big frameworks for most side projects”)."] && fb?.first?.assertion == "submitted"
                  && Set(fb?.first?.actionIDs ?? []) == [viewed, reply] && fb.map { $0.allSatisfy { coreAccepts("Ada on X", $0, rx.actions) && !coreCopiesAny($0.text, rx) } } == true,
                  "X reply (\(name)) fallback: one Replied line quoting the post it answered, never the reply; no Viewed line (got \(fb?.map(\.text) ?? []))")
            for bad in ["Replied to Sam's post about small tools.", "Posted on X about small tools.", "Viewed Ada's post on X."] {
                check(validated(answer(["i1"], bad), rx, vx) == nil, "X reply (\(name)) validator: \"\(bad)\" is refused")
            }
        }
        // A post typed on X and left (no send): a draft, never "Posted".
        let xd = try request("x-draft", [post("hot take about compilers", site: "https://x.com", title: "Home / X", surface: "social", sent: false)])
        let vxd = try ModelView(request: xd, actions: xd.actions)
        check(fallbackLines(xd, vxd)?.map(\.text) == ["Typed in X."] && fallbackLines(xd, vxd)?.first?.assertion == "draft"
              && validated(answer(["i1"], "Posted on X about compilers."), xd, vxd) == nil, "X post not sent: code's line says typed, never posted or draft; \"Posted\" is refused")
        // A reply typed and left: "Wrote a reply to Ada's post", never "Replied" (or draft).
        let xrd = try request("x-reply-draft", [post("not sure about this one", site: "https://x.com", title: adaTitle, surface: "social", sent: false, extra: adaCtx)])
        let vxrd = try ModelView(request: xrd, actions: xrd.actions)
        check(line(vxrd, "i1").contains("Start with: Wrote a reply to Ada's post on X") && fallbackLines(xrd, vxrd)?.first?.text.hasPrefix("Wrote a reply to Ada's post on X") == true
              && validated(answer(["i1"], "Replied to Ada's post about small tools."), xrd, vxrd) == nil, "X reply not sent: code's line \"Wrote a reply to Ada's post\"; \"Replied\" is refused")
        // A Reddit comment: "Commented on r/swift".
        let rd = try request("reddit", [post("strict concurrency caught three races in my app", site: "https://www.reddit.com", title: "Swift 6 concurrency : r/swift", surface: "social", sent: true,
                                             sendBy: "button", extra: ["community": "swift", "sendControl": "comment", "contextAuthor": "jdoe", "contextExcerpt": "Swift 6 concurrency"])])
        let vrd = try ModelView(request: rd, actions: rd.actions)
        check(line(vrd, "i1").contains("Start with: Commented on r/swift") && fallbackLines(rd, vrd)?.map(\.text) == ["Commented on r/swift (“Swift 6 concurrency”)."]
              && checked(answer(["i1"], "Commented on r/swift that the Swift 6 checks found several data races in your app."), rd, vrd) != nil
              && validated(answer(["i1"], "Posted on r/swift about concurrency."), rd, vrd) == nil, "Reddit comment: \"Commented on r/swift\" from code and the model")
        // A Gmail reply sent with Command-Return: "Emailed Sam".
        let gm = try request("gmail", [post("Hi Sam, numbers look good, ship it", site: "https://mail.google.com", title: "Re: Q3 numbers - Gmail", surface: "email", sent: true,
                                            sendBy: "commandReturn", field: "body", extra: ["to": "Sam", "subject": "Re: Q3 numbers"])])
        let vgm = try ModelView(request: gm, actions: gm.actions)
        check(fallbackLines(gm, vgm)?.map(\.text) == ["Emailed Sam."] && checked(answer(["i1"], "Emailed Sam approving the Q3 numbers."), gm, vgm) != nil,
              "Gmail send: code says \"Emailed Sam.\"; the model's gist passes (got \(fallbackLines(gm, vgm)?.map(\.text) ?? []))")
        // A composer code can't place: its place line, no destination, never "unknown".
        let uc = try request("unknown-composer", [post("standup notes for monday", app: "Notion", site: "", title: "Notion", surface: "other", sent: true)])
        let fuc = fallbackLines(uc, try ModelView(request: uc, actions: uc.actions))?.map(\.text) ?? []
        check(fuc == ["Used the send key in Notion."] && noBadWords(fuc), "unknown composer: code's place line, no destination (got \(fuc))")
        // 8. claude/messages2-1003 (owner 10/3: "the card knows who"): a conversation known only by its (fictional) number.
        //    Core passes the formatted number in `to` (the text's own window title); the model never sees it, writes
        //    "Texted someone", and code names the number in the stored bullet. One item per conversation.
        let num = "+1 (555) 010-0142", num2 = "+1 (555) 010-0199"
        let hreq = try request("m-handle", [msg("does the plan still work for saturday", to: num, sent: true), ret(num),
                                            msg("have you seen any good movies lately", to: num, sent: true), ret(num),
                                            msg("running a bit late", to: num2, sent: true)])
        let vh = try ModelView(request: hreq, actions: hreq.actions)
        let hA = alias(vh, hreq.actions[0].id), hB = alias(vh, hreq.actions[4].id)
        check(hA == alias(vh, hreq.actions[2].id) && hA != hB && vh.items.filter { $0.kind == .typed }.count == 2,
              "Messages number: one item per conversation, each number's texts together")
        check(!vh.text.contains("555") && !vh.text.contains("010-0142") && line(vh, hA).contains("Texted someone"),
              "Messages number: the model never sees the number; its line starts \"Texted someone\" (\(vh.text))")
        let hOut = checked(answers([([hA], "Texted someone asking if the Saturday plan still works and about good movies."),
                                    ([hB], "Texted someone that you're running late.")]), hreq, vh)
        check(hOut?.bullets.map(\.text) == ["Texted \(num) asking if the Saturday plan still works and about good movies.", "Texted \(num2) that you're running late."],
              "Messages number: the stored bullets name the number; check passes (got \(hOut?.bullets.map(\.text) ?? []))")
        check(hOut.map { coreAcceptsAll($0, hreq) && $0.bullets.allSatisfy { !Privacy.secret($0.text) } } == true,
              "Messages number: core accepts the named bullets (claims, and its secret guard)")
        let hFb = fallbackLines(hreq, vh)?.map(\.text) ?? []
        check(hFb.count == 2 && hFb.allSatisfy { !$0.contains("someone") } && hFb.contains { $0.hasPrefix("Texted \(num)") } && hFb.contains { $0.hasPrefix("Texted \(num2)") },
              "Messages number fallback: one line per number, never \"someone\" (got \(hFb))")
        check(validated(answers([([hA, hB], "Texted someone about plans.")]), hreq, vh) == nil, "Messages number: one bullet for two conversations is refused")
        // A New Message with no recipient and no number stays "someone"; a name is never borrowed from a number.
        let nreq = try request("m-none", [msg("hello from a new thread", to: nil, sent: true)])
        let vn = try ModelView(request: nreq, actions: nreq.actions)
        check(checked(answer(["i1"], "Texted someone to say hello."), nreq, vn)?.bullets.map(\.text) == ["Texted someone to say hello."],
              "Messages, nobody read: \"Texted someone\" stays")
        // 9. A text sealed by Return whose send wasn't confirmed is a whole text: never the first piece of the next one.
        var sealed = msg("that sounds pretty good", to: "Sam", sent: false); sealed["seal"] = "submit"
        let sreq = try request("m-sealed", [sealed, msg("home alone tonight", to: "Sam", sent: true)])
        let vs = try ModelView(request: sreq, actions: sreq.actions)
        check(line(vs, "i1").contains("\"home alone tonight\"") && line(vs, "i1").contains("\"that sounds pretty good\"")
              && !line(vs, "i1").contains("goodhome") && !line(vs, "i1").contains("good home"),
              "Messages: a Return-sealed text is its own text on the conversation's line, never stitched to the next (\(vs.text))")
        check(CanonicalGrounding.instruction.contains("Replied to Ada's post about <its point>, saying <yours>") && CanonicalGrounding.instruction.utf8.count <= 8192,
              "prompt: a reply says what it answered; the instruction fits the local context")
        print("summary-sends: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
