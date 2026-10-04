// fix/summary-fallback (QF-16 and the QA ChatGPT under-claim), overnight QA 2026-09-30.
// QF-16: 6 of 13 QA moments were left pending(invalidOutput) for good: the model's answers, the repair turn and salvage all
//        failed, and nothing was written. Now code writes the note from the moment's facts (`fallbackNote`).
// ChatGPT: two prompts sealed with the send key were written "Drafted a message to ChatGPT." (label submitted). A bullet
//        that calls a send a draft is now refused, and salvage drops it (code writes the send's own line).
// No model, no store: a fake runtime replays fixed answers. Compiles on the base (1e800d2): new API only by behavior.
import Foundation
@testable import MemoryCore
import WriterBackend

var passes = 0, failures = 0
func check(_ ok: Bool, _ label: String) { if ok { passes += 1; print("PASS " + label) } else { failures += 1; print("FAIL " + label) } }
let fallbackVersion = CanonicalGrounding.fallbackVersion

/// core's claim rule (MemoryStore.commitNote), word for word (as in summary-sends-checks).
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
func coreAcceptsAll(_ n: CanonicalNoteOutput, _ r: CanonicalNoteRequest) -> Bool { n.bullets.allSatisfy { coreAccepts(n.title, $0, r.actions) } }
/// No delivery or publication words, and no draft lead over a row sealed with the send key.
func truthful(_ n: CanonicalNoteOutput, _ r: CanonicalNoteRequest) -> Bool {
    let byID = Dictionary(uniqueKeysWithValues: r.actions.map { ($0.id, $0) })
    return n.bullets.allSatisfy { b in
        let sentRow = b.actionIDs.contains { byID[$0]?.kind == "keyboard.text_input" && byID[$0]?.state == "submitted" }
        let draftLead = b.text.range(of: "(?i)^\\s*(drafted|typed a draft|wrote a draft|started a draft)\\b", options: .regularExpression) != nil
        let delivery = (n.title + " " + b.text).range(of: "(?i)\\b(sent|delivered|published|posted)\\b", options: .regularExpression) != nil
        return !(sentRow && draftLead) && !delivery
    }
}
/// Every typed row with the send key is cited by a bullet that says so ("send key", or a send lead), never by a draft line.
func sendsSaid(_ n: CanonicalNoteOutput, _ r: CanonicalNoteRequest) -> Bool {
    r.actions.filter { $0.kind == "keyboard.text_input" && $0.state == "submitted" }.allSatisfy { a in
        n.bullets.contains { $0.actionIDs.contains(a.id) && $0.text.range(of: "(?i)send key|^(asked|texted|emailed|messaged|replied|searched|told)\\b", options: .regularExpression) != nil }
    }
}

func typedRow(_ i: Int, app: String, site: String = "", title: String, surface: String, sent: Bool, words: String? = nil, to: String? = nil) -> [String: Any] {
    var r: [String: Any] = ["id": "r\(i)", "at": String(format: "2026-09-30T06:%02d:00Z", 10 + i), "kind": "keyboard.text_input", "app": app, "site": site,
        "title": title, "state": sent ? "submitted" : "draft", "revision": "v\(i)", "surface": surface, "send": sent ? "detected" : "unknown",
        "runID": "run\(i)", "field": "textArea",
        "description": words.map { "Typed a draft in \(app). \($0)" } ?? (sent ? "Typed in \(app), then used its send key (a sentence)." : "Typed a draft in \(app) (a sentence).")]
    if sent { r["sendBy"] = "commandReturn" }
    if let to { r["to"] = to }
    return r
}
func request(_ id: String, _ rows: [[String: Any]], kind: String = "activity") throws -> CanonicalNoteRequest {
    let json: [String: Any] = ["id": id, "schemaVersion": 1, "targetKind": kind, "targetID": id, "day": "2026-09-30", "timezone": "UTC",
        "inputRevision": id, "policyRevision": "p", "expiresAt": "2099-01-01T00:00:00Z", "actions": rows, "actionCount": rows.count]
    return try JSONDecoder().decode(CanonicalNoteRequest.self, from: JSONSerialization.data(withJSONObject: json))
}
func answer(_ bullets: [([String], String)], title: String = "Chat") -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: ["title": title, "bullets": bullets.map { ["ids": $0.0, "text": $0.1] }])) ?? Data(), as: UTF8.self)
}
func alias(_ v: ModelView, _ id: String) -> String { v.owner(of: id)?.alias ?? "i0" }

/// Replays one fixed answer for the first turn and the repair turn.
struct Replay: LocalInference {
    let text: String
    func load() async throws {}
    func generate(instruction: String, evidence: String, maxTokens: Int) async throws -> Data { Data(text.utf8) }
    func unload() async {}
}
func write(_ r: CanonicalNoteRequest, _ text: String) async -> Result<CanonicalNoteOutput, Error> {
    let w = CanonicalLocalWriter(runtime: Replay(text: text), policy: { _, _ in true })
    do { return .success(try await w.generate(r, completeActions: r.actions)) } catch { return .failure(error) }
}
func describe(_ r: Result<CanonicalNoteOutput, Error>) -> String {
    switch r { case .success(let n): return "\(n.generatorVersion): " + n.bullets.map { "[\($0.assertion)] \($0.text)" }.joined(separator: " | ")
               case .failure(let e): return "threw \(e)" }
}
/// One piece of a ChatGPT prompt: `run` names its send unit (pieces of one run are one unit).
func unit(_ i: Int, sent: Bool, run: String, words: String?, sendFact: String) -> [String: Any] {
    var r = typedRow(i, app: "ChatGPT", title: "ChatGPT", surface: "ai", sent: sent, words: words, to: "ChatGPT")
    r["runID"] = run; r["send"] = sendFact; if !sent { r.removeValue(forKey: "sendBy") }
    return r
}
actor Commits { var n = 0; func add() { n += 1 }; func count() -> Int { n } }

@main struct SummaryFallbackChecks {
    static func main() async throws {
        // ---------------- QF-16: a moment whose answers all fail gets code's note from its facts ----------------
        // x.com: word-less drafts and a post sealed with the send key (the QA x.com moment). The model's only answer is
        // filler for the drafts, which no repair or salvage can hold.
        let rx = try request("fx", [typedRow(1, app: "Google Chrome", site: "x.com", title: "Home / X", surface: "social", sent: false),
                                    typedRow(2, app: "Google Chrome", site: "x.com", title: "Home / X", surface: "social", sent: true),
                                    typedRow(3, app: "Google Chrome", site: "x.com", title: "Home / X", surface: "social", sent: false)])
        let vx = try ModelView(request: rx, actions: rx.actions)
        let ax = await write(rx, answer([([alias(vx, "r2")], "Posted on X"), ([alias(vx, "r1")], "Drafted a post on X")], title: "X post"))
        let nx = try? ax.get()
        check(nx?.generatorVersion == fallbackVersion, "QF-16 x.com: every answer refused -> code's fallback note, not pending (\(describe(ax)))")
        check(nx.map { coreAcceptsAll($0, rx) && truthful($0, rx) && sendsSaid($0, rx) } ?? false, "QF-16 x.com: core accepts it; the send says send key; no delivery or publication claim")
        check(nx.map { n in n.bullets.first { $0.actionIDs.contains("r2") }.map { $0.assertion == "submitted" && !$0.actionIDs.contains("r1") } ?? false } ?? false,
              "QF-16 x.com: the send's line is its own (label submitted), the drafts stay drafts")
        check(nx.map { Set($0.bullets.flatMap(\.actionIDs)) == ["r1", "r2", "r3"] } ?? false, "QF-16 x.com: every typed row is covered")
        if let nx {
            check((try? CanonicalGrounding.check(nx, request: rx, view: vx)) == nx, "QF-16 check() accepts the fallback note (code would write exactly it)")
            var tampered = nx; tampered.bullets[0].text = "Posted a thread on X."
            check((try? CanonicalGrounding.check(tampered, request: rx, view: vx)) == nil, "QF-16 check() refuses a fallback note code would not write")
        } else { check(false, "QF-16 check() accepts the fallback note"); check(false, "QF-16 check() refuses a tampered fallback note") }
        // Not JSON at all (the model rambled): the same fallback.
        let garbage = await write(rx, "I cannot see the words, sorry.")
        check((try? garbage.get())?.generatorVersion == fallbackVersion, "QF-16 an answer that is not JSON also ends in the fallback note (\(describe(garbage)))")
        // Words kept (typing on): the fallback never shows them.
        let secret = "meet at the harbor at noon tomorrow"
        let rn = try request("fn", [typedRow(1, app: "Notes", title: "Plans", surface: "notes", sent: false, words: secret)])
        let an = await write(rn, "not json")
        let nn = try? an.get()
        let shown = nn.map { ([$0.title] + $0.bullets.map(\.text)).joined(separator: " ").lowercased() } ?? ""
        check(nn?.generatorVersion == fallbackVersion && !["harbor", "noon", "tomorrow", "meet"].contains { shown.contains($0) },
              "QF-16 a moment with its words kept: the fallback quotes none of them (\(describe(an)))")
        // Moments only: a day note's answers that all fail still leave it pending (code's lines are one moment's facts).
        let rday = try request("fday", rx.actions.map { a in ["id": a.id, "at": a.at, "kind": a.kind, "app": a.app, "site": a.site ?? "", "title": a.title ?? "",
                                                               "state": a.state, "revision": a.revision ?? "v", "description": a.description ?? ""] as [String: Any] }, kind: "day")
        let aday = await write(rday, "not json")
        let vday = try ModelView(request: rday, actions: rday.actions)
        let dayFallback = (try? CanonicalGrounding.fallbackNote(rday, view: vday)).flatMap { try? CanonicalGrounding.check($0, request: rday, view: vday) }
        check((try? aday.get()) == nil && dayFallback != nil, "QF-16 a day note is never code's fallback note, though code could write one (\(describe(aday)))")
        // Adapter end to end: committed once, never pending.
        let commits = Commits()
        let port = CoreWriterPort(prepare: { _ in rx }, page: { _, _ in WriterActionPage(actions: [], next: nil, actionCount: rx.actionCount) },
                                  commit: { out in await commits.add(); return WriterCommitReceipt(id: "fx", version: 1, inputRevision: "fx", status: "generated_unverified", output: out) },
                                  cancel: { _ in }, permitted: { _, _ in true })
        let writer = CanonicalLocalWriter(runtime: Replay(text: "nothing useful"), policy: { _, _ in true })
        let adapter = CoreWriterAdapter(core: port, generate: { r, acts in try await writer.generate(r, completeActions: acts) })
        var outcome = "threw"
        if let result = try? await adapter.process(WriterTarget(kind: .activity, day: "2026-09-30", timezone: "UTC", activityID: "fx"), lastActivity: .distantPast) {
            switch result { case .committed(let rc): outcome = "committed \(rc.output.generatorVersion)"; case .pending(let p): outcome = "pending(\(p.reason.rawValue))" }
        }
        check(outcome == "committed \(fallbackVersion)", "QF-16 adapter: the moment is committed with the fallback note (got \(outcome))")
        check(await commits.count() == 1, "QF-16 adapter: one commit")
        check(NoteWriterVersions.current.contains(fallbackVersion) && NoteWriterVersions.current == CanonicalGrounding.currentVersions && !NoteWriterVersions.outdated(fallbackVersion),
              "QF-16 core knows the fallback version (never rewritten as an earlier writer's)")

        // ---------------- ChatGPT: a send is never called a draft ----------------
        // The QA ChatGPT moment: prompts sealed with the send key and drafts between them.
        let g = (0..<4).map { typedRow($0 + 1, app: "ChatGPT", title: "ChatGPT", surface: "ai", sent: $0 % 2 == 0, to: "ChatGPT") }
        let rg = try request("fg", g)
        let vg = try ModelView(request: rg, actions: rg.actions)
        let both = Array(Set([alias(vg, "r1"), alias(vg, "r2")])).sorted()
        let under = try? CanonicalGrounding.validate(answer([(both, "Drafted a message to ChatGPT")]), request: rg, view: vg, provider: CanonicalLocalWriter.provider)
        check(under == nil, "ChatGPT: \"Drafted a message to ChatGPT\" over the sent prompts is refused (got \(under.map { $0.bullets.map { "[\($0.assertion)] \($0.text)" } } ?? []))")
        let ag = await write(rg, answer([(both, "Drafted a message to ChatGPT")], title: "ChatGPT message"))
        let ng = try? ag.get()
        check(ng.map { coreAcceptsAll($0, rg) && truthful($0, rg) && sendsSaid($0, rg) } ?? false,
              "ChatGPT: the note written instead says the prompts were sent with the send key, never drafted (\(describe(ag)))")
        let stored = try? JSONDecoder().decode(CanonicalNoteOutput.self, from: JSONSerialization.data(withJSONObject: [
            "requestID": "fg", "title": "ChatGPT message", "generator": CanonicalLocalWriter.provider, "generatorVersion": CanonicalGrounding.localVersion,
            "bullets": [["text": "Drafted a message to ChatGPT.", "actionIDs": ["r1", "r3"], "assertion": "submitted"],
                        ["text": "Drafted a message to ChatGPT.", "actionIDs": ["r2", "r4"], "assertion": "draft"]]]))
        check(stored.map { (try? CanonicalGrounding.check($0, request: rg, view: vg)) == nil } ?? false, "ChatGPT: check() refuses a stored note that calls the sends drafts")
        // A draft stays a draft: drafts only, the model's draft line holds.
        let rd = try request("fd", [typedRow(1, app: "ChatGPT", title: "ChatGPT", surface: "ai", sent: false, to: "ChatGPT")])
        let vd = try ModelView(request: rd, actions: rd.actions)
        let draftOnly = try? CanonicalGrounding.validate(answer([([alias(vd, "r1")], "Drafted a message to ChatGPT")]), request: rd, view: vd, provider: CanonicalLocalWriter.provider)
        check(draftOnly?.bullets.first?.assertion == "draft", "a real draft is still \"Drafted a message to ChatGPT\" (label draft)")

        // ---------------- Attribution: a stored note says whether code or the model wrote it ----------------
        // Code's note carries code's provider and the fallback version, the same pair the Today page trusts (MemoryCore
        // `CodeFallbackNote`) and core insists on together; a model's note carries the model's.
        check(nx.map { $0.generator == "code/fallback-notes" && $0.generator == CodeFallbackNote.provider && $0.generatorVersion == CodeFallbackNote.version } ?? false,
              "attribution: code's fallback note is stored as code's (provider code/fallback-notes, version \(fallbackVersion))")
        check(CanonicalGrounding.fallbackVersion == CodeFallbackNote.version && CanonicalGrounding.fallbackProvider == CodeFallbackNote.provider,
              "attribution: the writer's fallback pair is the one the Today page and core check")
        if let nx {
            // Code's note relabeled as the model's (either half, or both): check() refuses it, or the pair is split and core refuses it.
            var asModel = nx; asModel.generator = CanonicalLocalWriter.provider; asModel.generatorVersion = CanonicalGrounding.localVersion
            let modelLabel = try? CanonicalGrounding.check(asModel, request: rx, view: vx)
            var providerOnly = nx; providerOnly.generator = CanonicalLocalWriter.provider
            var versionOnly = nx; versionOnly.generatorVersion = CanonicalGrounding.localVersion
            check((try? CanonicalGrounding.check(providerOnly, request: rx, view: vx)) == nil && (try? CanonicalGrounding.check(versionOnly, request: rx, view: vx)) == nil,
                  "attribution: code's note with the model's provider or the model's version alone is refused")
            check(modelLabel == nil, "attribution: code's note fully relabeled as the model's (provider and version) is refused")
        } else { check(false, "attribution: provider/version halves refused"); check(false, "attribution: full relabel") }
        // The model's note relabeled as code's: check() refuses anything code would not write word for word.
        let rs = try request("fs", [unit(1, sent: false, run: "same", words: "what is the capital", sendFact: "unknown"),
                                    unit(2, sent: true, run: "same", words: "of peru please", sendFact: "detected")])
        let vs = try ModelView(request: rs, actions: rs.actions)
        let asked = answer([(Array(Set(rs.actions.map { alias(vs, $0.id) })).sorted(), "Asked ChatGPT")], title: "ChatGPT message")
        let ms = await write(rs, asked)
        if let model = try? ms.get() {
            check(model.generator == CanonicalLocalWriter.provider && model.generatorVersion == CanonicalGrounding.localVersion,
                  "attribution: the model's note is stored as the model's (\(model.generator), \(model.generatorVersion))")
            var asCode = model; asCode.generator = CanonicalGrounding.fallbackProvider; asCode.generatorVersion = CanonicalGrounding.fallbackVersion
            var codeVersionOnly = model; codeVersionOnly.generatorVersion = CanonicalGrounding.fallbackVersion
            check((try? CanonicalGrounding.check(asCode, request: rs, view: vs)) == nil && (try? CanonicalGrounding.check(codeVersionOnly, request: rs, view: vs)) == nil,
                  "attribution: the model's note relabeled as code's fallback note is refused")
        } else { check(false, "attribution: the model's note (\(describe(ms)))"); check(false, "attribution: model relabeled as code") }

        // ---------------- "Asked ChatGPT.": one send unit vs two ----------------
        // Same unit: an earlier paused piece of one run (no send key yet) and its last piece sealed with the send key.
        // The model's "Asked ChatGPT" is kept by salvage with label draft (the unit holds an unsent piece); code's note
        // says the send key was used. Separate units: two runs, each sealed with the send key: label submitted.
        let secretWords = ["capital", "peru", "please", "what"]
        func plain(_ n: CanonicalNoteOutput) -> [String] { n.bullets.map { "[\($0.assertion)] \($0.text)" } }
        func noInference(_ n: CanonicalNoteOutput) -> Bool {
            let all = ([n.title] + n.bullets.map(\.text)).joined(separator: " ").lowercased()
            return !secretWords.contains { all.contains($0) } && all.range(of: "\\b(sent|delivered|published|posted|about|replied|answered|received)\\b", options: .regularExpression) == nil
        }
        let rsep = try request("fsep", [unit(1, sent: true, run: "a", words: "what is the capital", sendFact: "detected"),
                                        unit(2, sent: true, run: "b", words: "of peru please", sendFact: "detected")])
        let vsep = try ModelView(request: rsep, actions: rsep.actions)
        let msep = await write(rsep, answer(rsep.actions.map { ([alias(vsep,$0.id)], "Asked ChatGPT") }, title: "ChatGPT message"))
        let fs = await write(rs, "not json"), fsep = await write(rsep, "not json")
        let same = (model: (try? ms.get()).map(plain), code: (try? fs.get()).map(plain))
        let sep = (model: (try? msep.get()).map(plain), code: (try? fsep.get()).map(plain))
        check(same.model == ["[draft] Asked ChatGPT."], "same unit (paused piece, then the send key): the model's note is exactly [draft] Asked ChatGPT. (got \(same.model ?? []))")
        check(same.code == ["[draft] Typed in ChatGPT and used the send key."], "same unit: code's note is exactly [draft] Typed in ChatGPT and used the send key. (got \(same.code ?? []))")
        check(sep.model == ["[submitted] Asked ChatGPT.","[submitted] Asked ChatGPT."], "separate units (two runs, each with the send key): each has its own submitted model bullet (got \(sep.model ?? []))")
        check(sep.code == ["[submitted] Used the send key in ChatGPT.","[submitted] Used the send key in ChatGPT."], "separate units: code keeps one submitted bullet per source run (got \(sep.code ?? []))")
        check((try? fs.get())?.generatorVersion == fallbackVersion && (try? fsep.get())?.generatorVersion == fallbackVersion
              && (try? ms.get())?.generatorVersion == CanonicalGrounding.localVersion && (try? msep.get())?.generatorVersion == CanonicalGrounding.localVersion,
              "same vs separate units: the model's notes are the model's, code's notes are code's")
        check([msep,fsep].compactMap {try? $0.get()}.allSatisfy {n in
            n.bullets.count==2 && n.bullets.allSatisfy {$0.actionIDs.count==1} && Set(n.bullets.flatMap(\.actionIDs))==Set(rsep.actions.map(\.id))
        }, "separate run bullets preserve distinct source IDs without inventing one message")
        let four = [ms, msep, fs, fsep].compactMap { try? $0.get() }
        check(four.count == 4 && four.allSatisfy(noInference), "same vs separate units: no typed words, no topic, no delivery or reply claim in any of the four")
        check(four.count == 4 && four.allSatisfy { coreAcceptsAll($0, $0.requestID == "fs" ? rs : rsep) }, "same vs separate units: core's claim rule accepts all four")
        // A paused piece alone (no send key anywhere in the run) is never "Asked".
        let rpause = try request("fp", [unit(1, sent: false, run: "same", words: "what is the capital", sendFact: "unknown")])
        let mpause = await write(rpause, answer([([alias(try ModelView(request: rpause, actions: rpause.actions), "r1")], "Asked ChatGPT")], title: "ChatGPT message"))
        check((try? mpause.get()).map { $0.bullets.allSatisfy { !$0.text.hasPrefix("Asked") } } ?? true,
              "a paused piece with no send key is never written \"Asked ChatGPT\" (got \(describe(mpause)))")

        // ---------------- Review C2: a Post-button click never says "send key" ----------------
        // fix/chrome-capture seals a proven click on X's Post button as submitted with sendBy "button". Code's note words
        // the line from sendBy: a key says "send key"; a click, or a send with no method recorded, says "Hit send".
        func xPost(_ id: String, sendBy: String?) async throws -> (CanonicalNoteRequest, CanonicalNoteOutput?) {
            var row = typedRow(1, app: "Google Chrome", site: "x.com", title: "Home / X", surface: "social", sent: true)
            if let sendBy { row["sendBy"] = sendBy } else { row.removeValue(forKey: "sendBy") }
            let r = try request(id, [row])
            return (r, try? await write(r, "not json").get())
        }
        let (rclick, nclick) = try await xPost("fclick", sendBy: "button")
        let (_, nnone) = try await xPost("fnone", sendBy: nil)
        let (rkey, nkey) = try await xPost("fkey", sendBy: "return")
        let vclick = try ModelView(request: rclick, actions: rclick.actions)
        check(nclick.map(plain) == ["[submitted] Hit send in X."] && nnone.map(plain) == ["[submitted] Hit send in X."]
              && nclick.map { n in coreAcceptsAll(n, rclick) && truthful(n, rclick) && (try? CanonicalGrounding.check(n, request: rclick, view: vclick)) == n
                  && !([n.title] + n.bullets.map(\.text)).joined(separator: " ").lowercased().contains("key") } ?? false
              && CodeFallbackNote.isFallbackLine("Hit send in X.") && CodeFallbackNote.isFallbackLine("Typed in X and hit send."),
              "C2 a Post-button click (sendBy button), or no method recorded: code's note is exactly [submitted] Hit send in X., never \"send key\"; core and check() accept it; Today shows it (got \(nclick.map(plain) ?? []), \(nnone.map(plain) ?? []))")
        check(nkey.map(plain) == ["[submitted] Used the send key in X."] && nkey.map { coreAcceptsAll($0, rkey) && truthful($0, rkey) } ?? false,
              "C2 the same post sealed with a key (sendBy return): code's note is exactly [submitted] Used the send key in X. (got \(nkey.map(plain) ?? []))")

        print("summary-fallback: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
