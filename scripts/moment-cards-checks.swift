// claude/dayeval-1005 (owner 10/05: "the only thing that needs a summary is the day"): moment cards without a model's
// note. With `momentModel` false the local and cloud writers write every moment's note by code (`codeNote`, else the
// fallback note's own lines from the facts) and never load the model or send a request for a moment; a day note keeps
// the model. Synthetic requests only: fake apps, fake words; a fake runtime and a fake cloud sender count calls.
import Foundation
@testable import MemoryCore
import WriterBackend

var passes = 0, failures = 0
func check(_ ok: Bool, _ label: String) { if ok { passes += 1; print("PASS " + label) } else { failures += 1; print("FAIL " + label) } }

func row(_ i: Int, kind: String = "window.changed", app: String, site: String = "", title: String, state: String = "seen", extra: [String: Any] = [:]) -> [String: Any] {
    var r: [String: Any] = ["id": "r\(i)", "at": String(format: "2026-10-05T14:%02d:00Z", i), "kind": kind, "app": app, "site": site, "title": title,
                            "state": state, "revision": "v\(i)", "description": kind == "window.changed" ? "Opened \(app) window “\(title)”." : "Typed in \(app) (a sentence)."]
    for (k, v) in extra { r[k] = v }
    return r
}
func typed(_ i: Int, app: String, title: String, surface: String, sent: Bool, to: String? = nil) -> [String: Any] {
    var extra: [String: Any] = ["surface": surface, "send": sent ? "detected" : "unknown", "runID": "run\(i)", "field": "textArea"]
    if sent { extra["sendBy"] = "return" }
    if let to { extra["to"] = to }
    return row(i, kind: "keyboard.text_input", app: app, title: title, state: sent ? "submitted" : "draft", extra: extra)
}
func request(_ id: String, _ rows: [[String: Any]], kind: String = "activity") throws -> CanonicalNoteRequest {
    let json: [String: Any] = ["id": id, "schemaVersion": 1, "targetKind": kind, "targetID": id, "day": "2026-10-05", "timezone": "UTC",
        "inputRevision": id, "policyRevision": "p", "expiresAt": "2099-01-01T00:00:00Z", "actions": rows, "actionCount": rows.count]
    return try JSONDecoder().decode(CanonicalNoteRequest.self, from: JSONSerialization.data(withJSONObject: json))
}

actor Counter { var n = 0; func add() { n += 1 }; func count() -> Int { n } }
struct Counting: LocalInference {
    let calls: Counter
    func load() async throws { await calls.add() }
    func generate(instruction: String, evidence: String, maxTokens: Int) async throws -> Data {
        await calls.add(); return Data(#"{"title":"Chat","bullets":[]}"#.utf8)
    }
    func unload() async {}
}

@main enum MomentCardsChecks {
    static func main() async throws {
        let moments: [(String, [[String: Any]])] = [
            ("window only", [row(1, app: "Preview", title: "Field guide.pdf"), row(2, app: "Preview", title: "Field guide.pdf")]),
            ("an AI ask", [row(1, app: "ChatGPT", title: "ChatGPT"), typed(2, app: "ChatGPT", title: "ChatGPT", surface: "ai", sent: true, to: "ChatGPT")]),
            ("a text", [row(1, app: "Messages", title: "Quill Harrow"), typed(2, app: "Messages", title: "Quill Harrow", surface: "text", sent: true, to: "Quill Harrow")]),
            ("a draft", [row(1, app: "Notes", title: "Trip"), typed(2, app: "Notes", title: "Trip", surface: "writing", sent: false)]),
        ]
        for (name, rows) in moments {
            let r = try request("m-" + name.replacingOccurrences(of: " ", with: "-"), rows)
            let calls = Counter()
            let off = CanonicalLocalWriter(runtime: Counting(calls: calls), policy: { _, _ in true }, momentModel: false)
            let note = try? await off.generate(r, completeActions: r.actions)
            let n = await calls.count()
            check(note != nil && n == 0, "moment cards, \(name): a note with no model load or call (calls \(n))")
            if let note {
                check([CanonicalGrounding.codeProvider, CanonicalGrounding.fallbackProvider].contains(note.generator),
                      "moment cards, \(name): written by code (\(note.generator))")
                check(note.bullets.allSatisfy { !$0.actionIDs.isEmpty }, "moment cards, \(name): every line cites its records")
                check(NoteWriterVersions.current.contains(note.generatorVersion), "moment cards, \(name): a current version (never rewritten)")
                print("  \(name): \(note.title) | " + note.bullets.map(\.text).joined(separator: " | "))
            }
            // The model's path, as before (control): the runtime is used for anything typed.
            let onCalls = Counter()
            let on = CanonicalLocalWriter(runtime: Counting(calls: onCalls), policy: { _, _ in true })
            _ = try? await on.generate(r, completeActions: r.actions)
            let used = await onCalls.count()
            let view = try ModelView(request: r, actions: r.actions)
            check(CanonicalGrounding.codeWrites(view) ? used == 0 : used > 0, "moment cards, \(name): with the model on, as before (calls \(used))")
        }
        // claude/dayeval-1005 (owner 10/05: never "draft"): code's moment notes, and the level notes code writes from
        // them, never say draft, unsent or not sent, whatever was typed and whether or not a send was seen.
        let draftWords = #"(?i)\b(draft|drafts|drafted|drafting|unsent|not sent|never sent|no send seen)\b|isn['’]t confirmed"#
        func drafty(_ s: String) -> Bool { s.range(of: draftWords, options: .regularExpression) != nil }
        let typing: [(String, [[String: Any]])] = [
            ("an email not sent", [row(1, app: "Mail", title: "Garden plan"), typed(2, app: "Mail", title: "Garden plan", surface: "email", sent: false, to: "Pell Ardent")]),
            ("a text not sent", [row(1, app: "Messages", title: "Quill Harrow"), typed(2, app: "Messages", title: "Quill Harrow", surface: "text", sent: false, to: "Quill Harrow")]),
            ("a text, no one named", [row(1, app: "Messages", title: "Messages"), typed(2, app: "Messages", title: "Messages", surface: "text", sent: false)]),
            ("a chat message not sent", [row(1, app: "Slack", title: "#garden"), typed(2, app: "Slack", title: "#garden", surface: "chat", sent: false, to: "#garden")]),
            ("an AI ask not sent", [row(1, app: "ChatGPT", title: "ChatGPT"), typed(2, app: "ChatGPT", title: "ChatGPT", surface: "ai", sent: false, to: "ChatGPT")]),
            ("three typing runs", [row(1, app: "TextEdit", title: "Plan"), typed(2, app: "TextEdit", title: "Plan", surface: "writing", sent: false),
                                   typed(3, app: "TextEdit", title: "Plan", surface: "writing", sent: false), typed(4, app: "TextEdit", title: "Plan", surface: "writing", sent: false)]),
            ("a send and a draft", [row(1, app: "Messages", title: "Quill Harrow"), typed(2, app: "Messages", title: "Quill Harrow", surface: "text", sent: true, to: "Quill Harrow"),
                                    typed(3, app: "Messages", title: "Quill Harrow", surface: "text", sent: false, to: "Quill Harrow")]),
        ] + moments
        var children: [LevelChildView] = []
        for (i, (name, rows)) in typing.enumerated() {
            let r = try request("t-\(i)", rows)
            let view = try ModelView(request: r, actions: r.actions)
            let off = CanonicalLocalWriter(runtime: Counting(calls: Counter()), policy: { _, _ in true }, momentModel: false)
            var notes = [CanonicalNoteOutput]()
            if let n = try? await off.generate(r, completeActions: r.actions) { notes.append(n) }
            if let n = try? CanonicalGrounding.fallbackNote(r, view: view) { notes.append(n) }
            if let n = try? CanonicalGrounding.codeNote(r, view: view) { notes.append(n) }
            check(!notes.isEmpty, "never draft, \(name): code wrote a note")
            for n in notes {
                let lines = n.bullets.map(\.text)
                check(!lines.contains(where: drafty), "never draft, \(name) (\(n.generator)): \(lines.joined(separator: " | "))")
            }
            if let n = notes.first {
                children.append(LevelChildView(alias: "c\(i)", ref: LevelChildRef(id: "t-\(i)", version: n.generatorVersion, start: String(format: "2026-10-05T%02d:00:00Z", 8 + i),
                                                                                   end: String(format: "2026-10-05T%02d:30:00Z", 8 + i)),
                                               label: "moment", title: n.title, lines: n.bullets.map(\.text), typed: true))
            }
        }
        for level in [LevelKind.block, .day] {
            let req = LevelRequest(target: "level-\(level)", level: level, period: "2026-10-05", timezone: "UTC", start: "2026-10-05T08:00:00Z", end: "2026-10-05T20:00:00Z",
                                   children: children, actionIDs: [], inputRevision: "r")
            let (title, lines) = LevelGrounding.extractive(req)
            check(!drafty(title) && !lines.contains { drafty($0.text) }, "never draft, a \(level) note by code: \(title) | \(lines.map(\.text).joined(separator: " | "))")
        }
        check(CanonicalGrounding.undraft("Drafted an email to Sam about “Drafts folder cleanup”; sending isn't confirmed.") == "Wrote an email to Sam about “Drafts folder cleanup”.",
              "never draft: a quoted title keeps its words, code's own words change")
        // The writer and the display rewrite stored words the same way (MemoryCore `DisplayWords.undraft`).
        for line in ["Typed a draft in Notes (a sentence).", "Drafted a text to Sam, left unsent.", "Draft to Jamie Lin (not sent)", "Draft",
                     "Opened Notes and drafted a draft email to Avery.", "Edited a draft of the picnic plan.", "Was drafting a reply; sending isn't confirmed.",
                     "Read Lab Report Draft.", "Read PR #12: Fix Messages drafts on GitHub.", "Asked Claude about “Draft plan”."] {
            check(CanonicalGrounding.undraft(line) == DisplayWords.undraft(line), "never draft: writer and display agree on \(line)")
        }
        // Cloud: no moment is ever sent.
        let sends = Counter()
        let r = try request("m-cloud", moments[1].1)
        let cloud = CanonicalCloudWriter(consent: { CloudConsent(enabled: true, disclosureVersion: CloudConsent.currentVersion) }, key: { "fixture-key" },
                                         policy: { _, _ in true }, send: { _ in await sends.add(); throw URLError(.notConnectedToInternet) }, momentModel: false)
        let cloudNote = try? await cloud.generate(r, completeActions: r.actions)
        let sent = await sends.count()
        check(cloudNote != nil && sent == 0, "moment cards, cloud: the moment's note is code's, nothing sent (sends \(sent))")
        let noConsent = CanonicalCloudWriter(consent: { CloudConsent() }, key: { "fixture-key" }, policy: { _, _ in true },
                                             send: { _ in await sends.add(); throw URLError(.notConnectedToInternet) }, momentModel: false)
        check((try? await noConsent.generate(r, completeActions: r.actions)) == nil, "moment cards, cloud: without cloud consent, nothing written there")
        // A day note keeps the model (the day is the one summary).
        let dayCalls = Counter()
        let day = CanonicalLocalWriter(runtime: Counting(calls: dayCalls), policy: { _, _ in true }, momentModel: false)
        let rd = try request("d-1", moments[1].1, kind: "day")
        _ = try? await day.generate(rd, completeActions: rd.actions)
        check(await dayCalls.count() > 0, "moment cards: a day note still goes to the model")
        print("moment-cards-checks: \(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
