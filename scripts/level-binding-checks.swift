import Foundation
import MemoryCore
import WriterBackend

/// LevelWriterBinding (summaries/v3): the local runtime is loaded before a level note's first answer and unloaded
/// after its last, on success, after two refusals and on a runtime error; with no model (cloud mode) nothing loads and
/// code writes the note. A fake runtime refuses to answer while unloaded, as LlamaInference does. Synthetic store only.
actor FakeRuntime: LocalInference {
    var loaded = false, loads = 0, unloads = 0, answers: [String], fail = false
    /// fix/r1-writer: a load that takes this long and, like a native load that can't be interrupted, ignores cancellation.
    var loadSeconds = 0.0
    init(_ answers: [String], loadSeconds: Double = 0) { self.answers = answers; self.loadSeconds = loadSeconds }
    func setFail() { fail = true }
    /// fix/r1-writer: the model doesn't load (a damaged or missing file).
    var failLoad = false
    func setFailLoad(_ value: Bool) { failLoad = value }
    func load() async throws {
        if failLoad { loads += 1; throw WriterFailure.integrity }
        await ModelCopies.shared.loaded()
        loaded = true; loads += 1
        let end = Date().addingTimeInterval(loadSeconds)
        while Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    func unload() async { if loaded { await ModelCopies.shared.unloaded() }; loaded = false; unloads += 1 }
    func generate(instruction: String, evidence: String, maxTokens: Int) async throws -> Data {
        try await generate(instruction: instruction, evidence: evidence, maxTokens: maxTokens, prefill: "")
    }
    func generate(instruction: String, evidence: String, maxTokens: Int, prefill: String) async throws -> Data {
        guard loaded, !fail else { throw WriterFailure.unavailable }
        return Data((answers.isEmpty ? "{}" : answers.removeFirst()).utf8)
    }
    func counts() -> (Bool, Int, Int) { (loaded, loads, unloads) }
}

/// How many fake model copies are in memory at once, across runtimes (fix/r1-writer).
actor ModelCopies {
    static let shared = ModelCopies()
    var now = 0, peak = 0
    func loaded() { now += 1; peak = max(peak, now) }
    func unloaded() { now -= 1 }
    func reset() { now = 0; peak = 0 }
}

@main struct LevelBindingChecks {
    static var count = 0
    static func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1; print("PASS " + label) }
    static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("level-binding-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000), zone = "UTC"
        let store = try MemoryStore(home: root, writable: true, automaticallySyncSearch: false)
        let review = try store.prepareRetentionChange(.days(30), now: now)
        _ = try store.confirmRetentionChange(review.id, confirmed: true, now: now)
        // Three days, each one block of two moments; the notes are written by a stand-in.
        let days = ["2027-01-12", "2027-01-13", "2027-01-14"]
        for day in days {
            let start = try DayScope.interval(day: day, timezone: zone).start
            func at(_ m: Int) -> String { iso(start.addingTimeInterval(Double(9 * 3600 + m * 60))) }
            for (id, m, app, title) in [("x1", 0, "Xcode", "ExportView.swift"), ("x2", 4, "Xcode", "ExportView.swift"),
                                        ("c1", 20, "Claude", "Export crash"), ("c2", 24, "Claude", "Export crash")] {
                _ = try store.ingest(Evidence(id: day + id, at: at(m), kind: "window.changed", app: app, title: title, synthetic: true), now: now)
            }
            for m in try store.dayLayers(day: day, timezone: zone, now: now).activities {
                let request = try store.prepareNote(kind: "activity", day: day, timezone: zone, activityID: m.id, now: now)
                let text = m.subject == "Export crash" ? "Asked Claude why export crashes on big files." : "Had ExportView.swift open in Xcode."
                _ = try store.commitNote(NoteWriterOutput(requestID: request.id, title: m.subject, bullets: [NoteBullet(text: text, actionIDs: request.actions.map(\.id), assertion: "observed")],
                                                          generator: "local/synthetic", generatorVersion: "1"), now: now)
            }
        }
        let good = #"fixing the export crash","lines":[{"ids":["m2"],"text":"Asked Claude why export crashes on big files."}]}"#
        // Refused on its goal (not an -ing phrase): with threads a block's lines are the code's thread bullets, so a
        // refused line alone no longer makes the model's answer fail.
        let bad = #"fixed the export crash","lines":[{"ids":["m2"],"text":"Fixed the export crash."}]}"#

        // 1. A good first answer: loaded for the answer, unloaded after.
        let r1 = FakeRuntime([good])
        let s1 = try await LevelWriterBinding.local(store: store, runtime: r1).step(timezone: zone, now: now)
        var c = await r1.counts()
        check(s1?.note.level == .block && s1?.source == "model" && s1?.note.title.hasSuffix(": fixing the export crash") == true, "the local level writer answers once the runtime is loaded (prefill joined)")
        check(!c.0 && c.1 == 1 && c.2 == 1, "the runtime is loaded once and unloaded after the note")

        // 2. Two refusals: code writes the note, and the runtime is still unloaded.
        let r2 = FakeRuntime([bad, bad])
        let s2 = try await LevelWriterBinding.local(store: store, runtime: r2).step(timezone: zone, now: now)
        c = await r2.counts()
        check(s2?.source == "extractive" && s2?.rejections.count == 2 && s2?.note.generator == LevelWriterVersion.extractive, "after an answer and a repair are refused, code writes the note")
        check(!c.0 && c.1 == 1 && c.2 == 1, "the runtime is unloaded after two refusals too")

        // 3. A runtime error: the error is passed on, nothing is saved, and the runtime is unloaded.
        let r3 = FakeRuntime([good]); await r3.setFail()
        let before = try store.allLevelNotes().count
        var threw = false
        do { _ = try await LevelWriterBinding.local(store: store, runtime: r3).step(timezone: zone, now: now) } catch { threw = true }
        c = await r3.counts()
        let after = try store.allLevelNotes().count
        check(threw && after == before, "a runtime error saves no level note (it is tried again later)")
        check(!c.0 && c.2 == 1, "the runtime is unloaded after an error")

        // 4. No model (cloud mode): code writes the note and nothing loads.
        let r4 = FakeRuntime([])
        let s4 = try await LevelWriterBinding(store: store, generate: nil).step(timezone: zone, now: now)
        c = await r4.counts()
        // With threads a code-written block's lines lead with the thread's intent line (notes-quality), else its minutes.
        check(s4?.source == "extractive" && s4?.note.generator == LevelWriterVersion.extractive && s4?.note.lines.map(\.text).contains("Asked Claude why export crashes on big files.") == true, "with no model the note is written by code from the moments' threads (\(s4?.note.lines.map(\.text) ?? []))")
        check(c.1 == 0, "cloud mode loads nothing")

        // 5. r1 levels-pipeline: a note core can't save (here its code-written and plain notes both repeat a one-word
        // draft) is passed over for later ones instead of blocking every block, day, week and month; a note whose code
        // title repeats a short draft is saved as the plain note.
        let root5 = root.appendingPathComponent("typed")
        let typed = try MemoryStore(home: root5, writable: true, automaticallySyncSearch: false)
        let review5 = try typed.prepareRetentionChange(.days(30), now: now)
        _ = try typed.confirmRetentionChange(review5.id, confirmed: true, now: now)
        var consent = try typed.policy(); consent.captureText = true; consent.typedConsentVersion = 1; try typed.updatePolicy(consent, now: now)
        try typed.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore()), now: now); try typed.setUpTypedVault(now: now)
        try typed.acceptSafeTyping(now: now)
        for (day, draft, page) in [("2027-01-14", "document", "Document"), ("2027-01-13", "fix my resume", "Fix my resume"), ("2027-01-12", nil, nil)] as [(String, String?, String?)] {
            let start = try DayScope.interval(day: day, timezone: zone).start
            func at(_ m: Int) -> String { iso(start.addingTimeInterval(Double(9 * 3600 + m * 60))) }
            if let draft, let page {
                _ = try typed.ingest(Evidence(id: day + "n0", at: at(0), kind: "window.changed", app: "Notes", bundle: "com.apple.Notes", title: "New Note", synthetic: true), now: now)
                _ = try typed.ingest(Evidence(id: day + "t", at: at(1), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes", title: "New Note", text: draft, synthetic: true), now: now)
                for m in [3, 8, 13] { _ = try typed.ingest(Evidence(id: day + "n\(m)", at: at(m), kind: "window.changed", app: "Notes", bundle: "com.apple.Notes", title: page, synthetic: true), now: now) }
            } else {
                for m in [0, 4] { _ = try typed.ingest(Evidence(id: day + "x\(m)", at: at(m), kind: "window.changed", app: "Xcode", bundle: "com.apple.dt.Xcode", title: "ExportView.swift — tallybird", synthetic: true), now: now) }
            }
            for m in try typed.dayLayers(day: day, timezone: zone, now: now).activities {
                let request = try typed.prepareNote(kind: "activity", day: day, timezone: zone, activityID: m.id, now: now)
                _ = try typed.commitNote(NoteWriterOutput(requestID: request.id, title: m.apps.contains("Notes") ? "Notes" : "Xcode",
                                                          bullets: [NoteBullet(text: m.apps.contains("Notes") ? "Wrote a note in Notes." : "Had ExportView.swift open in Xcode.", actionIDs: request.actions.map(\.id), assertion: "observed")],
                                                          generator: "local/synthetic", generatorVersion: "1"), now: now)
            }
        }
        let writer = LevelWriterBinding(store: typed, generate: nil)
        var first = false
        do { _ = try await writer.step(timezone: zone, now: now) } catch { first = true }
        let none = try typed.allLevelNotes().isEmpty
        check(first && none, "a note core refuses (it would repeat a typed draft) is not saved")
        let p2 = try await writer.step(timezone: zone, now: now)
        check(p2?.note.period == "2027-01-13" && p2?.source == "plain" && p2?.note.title.lowercased().contains("resume") == false && p2?.note.title.hasSuffix(": Document") == true,
              "the next pass writes the next block, not the refused one again; a code title that repeats a draft is saved plain (\(p2?.note.title ?? "none"))")
        let p3 = try await writer.step(timezone: zone, now: now)
        check(p3?.note.period == "2027-01-12" && p3?.note.level == .block, "every later block is written")
        let p4 = try await writer.step(timezone: zone, now: now)
        check(p4?.note.level == .day, "and the days after them (summaries go on)")
        let later = try typed.levelWork(timezone: zone, now: now).first
        check(later?.period == "2027-01-14" && later?.level == .block, "the refused block is still waiting (tried again after \(Int(LevelWriterBinding.retryAfter / 60)) minutes, or when it changes)")

        // 6. fix/r1-writer: summaries turned off while a level note's model is loading. The note is cancelled and waited
        // for: nothing is saved, the runtime is unloaded, and a step asked for meanwhile loads nothing.
        let runner = LevelRunner()
        await ModelCopies.shared.reset()
        let r5 = FakeRuntime([good, good], loadSeconds: 0.6)
        let before5 = try store.allLevelNotes().count
        let writing = Task { try await runner.step(LevelWriterBinding.local(store: store, runtime: r5), timezone: zone, now: now) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let r6 = FakeRuntime([good])
        let second = try await runner.step(LevelWriterBinding.local(store: store, runtime: r6), timezone: zone, now: now)
        c = await r6.counts()
        check(second == nil && c.1 == 0, "a level step asked for while one is loading the model does nothing (one load in flight)")
        let busy = await runner.busy
        await runner.stop()
        let stopped = await runner.busy
        var cancelled = false
        do { _ = try await writing.value } catch is CancellationError { cancelled = true } catch {}
        c = await r5.counts()
        check(busy && !stopped && cancelled, "stopping the level writer cancels the note being written and waits for it")
        check(try store.allLevelNotes().count == before5, "a level note whose writer was turned off while the model loaded is never saved")
        check(!c.0 && c.1 == 1 && c.2 == 1, "the cancelled note's runtime is unloaded before stop returns")
        // Turned on again right away: the new runtime loads only after the old one is gone.
        let r7 = FakeRuntime([good])
        let s7 = try await runner.step(LevelWriterBinding.local(store: store, runtime: r7), timezone: zone, now: now)
        let peak = await ModelCopies.shared.peak
        check(s7 != nil && peak == 1, "turned on again right away, one copy of the model is loaded at a time")

        // 7. fix/r1-writer: a model that doesn't load is tried again after 1, 5 and 15 minutes (then hourly), not every
        // minute, and from the third failure in a row code writes the level notes meanwhile, without loading anything.
        let backoff = LevelRunner(), broken = FakeRuntime([good]); await broken.setFailLoad(true)
        let local = LevelWriterBinding.local(store: store, runtime: broken)
        func attempt(_ after: TimeInterval) async -> (step: LevelWriterBinding.Step?, failed: Bool) {
            do { return (try await backoff.step(local, timezone: zone, now: now.addingTimeInterval(after)), false) }
            catch is LevelWriterBinding.ModelFailure { return (nil, true) } catch { return (nil, false) }
        }
        let notes6 = try store.allLevelNotes().count
        var a = await attempt(0)
        c = await broken.counts()
        var retry = await backoff.modelRetryAt
        check(a.failed && c.1 == 1 && retry == now.addingTimeInterval(60), "a level model that fails to load waits a minute before it is tried again")
        a = await attempt(30); c = await broken.counts()
        check(a.step == nil && !a.failed && c.1 == 1, "within the wait the model isn't loaded (nor its file checked) again")
        a = await attempt(61); retry = await backoff.modelRetryAt
        check(a.failed && retry == now.addingTimeInterval(61 + 300), "after the second failure it waits 5 minutes")
        a = await attempt(200); c = await broken.counts()
        let notes6b = try store.allLevelNotes().count
        check(a.step == nil && !a.failed && c.1 == 2 && notes6b == notes6, "two failures in a row: nothing is written yet, and nothing loads")
        a = await attempt(400); retry = await backoff.modelRetryAt
        let failures = await backoff.modelFailures
        check(a.failed && failures == 3 && retry == now.addingTimeInterval(400 + 900), "after the third failure it waits 15 minutes")
        a = await attempt(460); c = await broken.counts()
        check(a.step?.source == "extractive" && a.step?.note.generator == LevelWriterVersion.extractive && c.1 == 3 && !c.0,
              "from the third failure code writes the level note, as in cloud mode, without loading the model")
        a = await attempt(400 + 901); retry = await backoff.modelRetryAt
        check(a.failed && retry == now.addingTimeInterval(400 + 901 + 3600), "then the model is tried once an hour")
        // A settings change starts over, and a note the model writes resets the count.
        await backoff.reset()
        let fixed = FakeRuntime([good, good])
        let healed = try await backoff.step(LevelWriterBinding.local(store: store, runtime: fixed), timezone: zone, now: now.addingTimeInterval(1400))
        let restarted = await backoff.modelFailures
        c = await fixed.counts()
        check(healed != nil && c.1 == 1 && restarted == 0, "after a settings change the model is tried at once, and a written note starts the count over")

        // 8. fix/sx-all round 1: a block that leaves out a moment the writer set aside (its note failed for good) commits on
        // the first try, with one model answer. Before, commit planned the block without the skip, read "Level input
        // changed", and the model was asked again every pass.
        let root8 = root.appendingPathComponent("skipped")
        let s8 = try MemoryStore(home: root8, writable: true, automaticallySyncSearch: false)
        let review8 = try s8.prepareRetentionChange(.days(30), now: now)
        _ = try s8.confirmRetentionChange(review8.id, confirmed: true, now: now)
        let day8 = try DayScope.key(now, timezone: zone)
        let start8 = try DayScope.interval(day: day8, timezone: zone).start
        func at8(_ m: Int) -> String { iso(start8.addingTimeInterval(Double(3600 + m * 60))) }
        for (id, m, app, title) in [("x1", 0, "Xcode", "ExportView.swift"), ("x2", 4, "Xcode", "ExportView.swift"), ("c1", 20, "Claude", "Export crash"), ("c2", 24, "Claude", "Export crash"),
                                    ("y1", 40, "Xcode", "ExportView.swift"), ("y2", 44, "Xcode", "ExportView.swift")] {
            _ = try s8.ingest(Evidence(id: "k" + id, at: at8(m), kind: "window.changed", app: app, title: title, synthetic: true), now: now)
        }
        let moments8 = try s8.dayLayers(day: day8, timezone: zone, now: now).activities
        let skippedID = moments8.first { $0.actionIDs.contains("ky1") }?.id ?? ""
        for m in moments8 where m.id != skippedID {
            let request = try s8.prepareNote(kind: "activity", day: day8, timezone: zone, activityID: m.id, now: now)
            let text = m.subject == "Export crash" ? "Asked Claude why export crashes on big files." : "Had ExportView.swift open in Xcode."
            _ = try s8.commitNote(NoteWriterOutput(requestID: request.id, title: m.subject, bullets: [NoteBullet(text: text, actionIDs: request.actions.map(\.id), assertion: "observed")],
                                                   generator: "local/synthetic", generatorVersion: "1"), now: now)
        }
        let skip: @Sendable (String) -> Bool = { $0 != skippedID }
        let waits = try s8.levelWork(timezone: zone, now: now).filter { $0.level == .block }.isEmpty
        let planned = try s8.levelWork(timezone: zone, now: now, momentWillBeWritten: skip).first { $0.level == .block }
        check(!skippedID.isEmpty && waits && planned != nil, "fixture: the set-aside moment sits in a block that waits for it unless it is skipped")
        let r8 = FakeRuntime([good, good])
        let s8step = try await LevelWriterBinding.local(store: s8, runtime: r8).step(timezone: zone, now: now, momentWillBeWritten: skip)
        let left8 = await r8.answers.count
        check(s8step?.note.level == .block && s8step?.source == "model" && left8 == 1, "a block without a set-aside moment commits on the first try with one model answer (\(s8step?.source ?? "none"), \(2 - left8) answers)")
        print("level-binding checks: \(count) passed")
    }
}
