// DD-RECIPE: UI
//
// fix/day-card: the Today card and the moment rows over a whole made-up workday, minute by minute from 8:30 to 18:00,
// with summaries off, downloading, on this Mac on power (notes and level notes written as it goes), on this Mac on
// battery (moment notes only), and cloud summaries turned on at 13:00. Along the way: a privacy-setting revision bump,
// new actions landing in moments that already have notes, a Forget of a moment, and a stored day note cut by an older
// threads planner. Every frame is checked:
//   - the card has a headline (never "24 moments", never empty) and its lines put sends and conversations first;
//   - no row title is filler or a raw window title ('@', "(3)", " - Gmail", " · Pull Request"), no row says pending;
//   - a moment that had a note never goes blank while a newer note is written (stale-while-updating);
//   - a forgotten moment shows nothing of its old note;
//   - moments cloud summaries will never write (before the cutoff) are never pending (no Summarize Now);
//   - idle-only moments are not rows, and no writer is ever asked for one.
// Synthetic data only: a temp store under DD_CHECK_OUT (or the temp folder), no app, no permissions, no capture, no model.
//
// Compiled with -D CANDIDATE_5C76A6F it builds against the candidate (without the new API) and must fail there.
import Foundation
import AppKit
import SwiftUI
import MemoryCore
import MemoryUI
import CoreIntegration

@MainActor @main enum StaleCardChecks {
    static var failures = 0, checked = 0
    static var failed = [String: Int]()
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        checked += 1
        if ok { return }
        failures += 1
        failed[name, default: 0] += 1
        if failed[name]! <= 3 { print("FAIL: \(name)\(detail().isEmpty ? "" : " (\(detail()))")") }
    }
    static let zone = "America/Los_Angeles", day = "2026-09-22"
    static var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }()
    static func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: h, minute: m, second: s))!
    }
    static let root: URL = {
        let base = ProcessInfo.processInfo.environment["DD_CHECK_OUT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("stale-card-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }()

    static func main() async {
        do {
            let rows = workday()
            sources()
            let only = ProcessInfo.processInfo.environment["STALE_CARD_MODES"].map { Set($0.split(separator: ",").map(String.init)) }
            for mode in ["off", "downloading", "local-ac", "local-battery", "cloud-13"] where only?.contains(mode) ?? true { try await replay(mode, rows) }
            if only == nil { try outdatedNotes(rows) }
        } catch {
            check(false, "setup", "\(error)")
        }
        try? FileManager.default.removeItem(at: root)
        for (name, n) in failed.sorted(by: { $0.key < $1.key }) where n > 3 { print("  \(name): \(n) frames in all") }
        print(failures == 0 ? "PASS: stale-card: \(checked) checks over 5 summary modes, minute by minute 8:30 to 18:00; synthetic temp stores only"
                            : "\(failures) of \(checked) stale-card check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: The day (SYNTHETIC; every person, message and site is made up)

    /// A dense workday: email, an export crash with ChatGPT and Xcode, texts with Riley and Sam, the investor update in
    /// Google Docs, a group text to Q7, a ChatGPT session with no typing, a pull request, Slack, a call, idle stretches.
    static func workday() -> [[String: Any]] {
        var rows = [[String: Any]](), n = 0, runs = 0
        func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); return f.string(from: d) }
        let bundles = ["ChatGPT": "com.openai.chat", "Xcode": "com.apple.dt.Xcode", "Messages": "com.apple.MobileSMS", "Slack": "com.tinyspeck.slackmacgap",
                       "Chrome": "com.google.Chrome", "Google Chrome": "com.google.Chrome", "Zoom": "us.zoom.xos", "Terminal": "com.apple.Terminal", "": ""]
        func ev(_ t: Date, _ kind: String, _ app: String, _ title: String = "", _ url: String = "", text: String = "", unit: [String: Any]? = nil) {
            n += 1
            var e: [String: Any] = ["id": String(format: "stc-%05d", n), "at": iso(t), "kind": kind, "app": app, "bundle": bundles[app] ?? "",
                                    "title": title, "url": url, "text": text, "secure": false, "privateWindow": false, "synthetic": true]
            if let unit {
                e["captureProvenance"] = ["policyRevision": "synthetic", "classifierVersion": "sensitive-typing/v2", "windowID": "w", "focusID": "f",
                                          "checkedAt": iso(t), "generation": 1, "unit": unit] as [String: Any]
            }
            if app == "Google Chrome" && kind == "keyboard.text_input" {
                e["browserVerification"] = ["provider": "chrome-typing-join-v1", "mode": "normal", "windowID": "w\(n)", "tabID": "t\(n)",
                                            "focusedRole": "AXTextArea", "checkedAt": iso(t), "documentID": String(format: "00000000-0000-4000-8000-%012d", n),
                                            "focusID": String(format: "00000000-0000-4000-9000-%012d", n), "policyRevision": "synthetic"]
            }
            rows.append(e)
        }
        func stretch(_ t: Date, _ minutes: Int, _ app: String, _ title: String, _ url: String = "", every: Int = 45) {
            ev(t, "window.changed", app, title, url)
            var s = every
            while s < minutes * 60 { ev(t.addingTimeInterval(Double(s)), "mouse.click", app, title, url); s += every }
        }
        func typed(_ t: Date, _ app: String, _ title: String, _ words: String, _ surface: String, to: String?, url: String = "") {
            runs += 1
            let send = to != nil
            var unit: [String: Any] = ["version": "typed-unit/v3", "runID": "stc-run-\(runs)", "part": 1, "sealReason": send ? "submit" : "idle",
                                       "startedAt": iso(t.addingTimeInterval(-40)), "keys": NSNull(), "edits": NSNull(), "withheld": 0,
                                       "surface": surface, "send": send ? "detected" : "none"]
            if send { unit["sendBy"] = surface == "email" ? "commandReturn" : "return" }
            if let to { unit["to"] = to }
            ev(t, "keyboard.text_input", app == "Chrome" ? "Google Chrome" : app, title, url, text: words, unit: unit)
            if send { ev(t.addingTimeInterval(1), surface == "email" ? "keyboard.shortcut" : "keyboard.submit", app, title, url) }
        }
        func text(_ t: Date, _ who: String, _ words: String) {
            stretch(t, 3, "Messages", who)
            typed(t.addingTimeInterval(60), "Messages", who, words, "text", to: who)
        }
        let gm = "https://mail.google.com", docs = "https://docs.google.com", gh = "https://github.com"
        stretch(at(8, 30), 8, "Chrome", "Inbox (23) - sam@daydream.example - Gmail", gm)
        stretch(at(8, 38), 6, "Chrome", "Re: Pro plan pricing - sam@daydream.example - Gmail", gm)
        typed(at(8, 42), "Chrome", "mail.google.com", "Sam, eight a month with a free tier, let's decide Thursday", "email", to: "Sam", url: gm)
        stretch(at(8, 45), 12, "ChatGPT", "ChatGPT")
        typed(at(8, 46), "ChatGPT", "ChatGPT", "My app crashes exporting a big file, where do I look first?", "ai", to: "ChatGPT")
        stretch(at(8, 57), 30, "Xcode", "ExportView.swift — daydream")
        stretch(at(9, 27), 6, "Terminal", "daydream — swift test")
        stretch(at(9, 33), 25, "Xcode", "ExportView.swift — daydream")
        text(at(9, 58), "Riley", "Dinner Thursday at 7? Sam is in")
        text(at(10, 2), "Sam", "Riley said yes to Thursday, booking the Thai place")
        stretch(at(10, 6), 30, "Xcode", "ExportTests.swift — daydream")
        // Clicks every 2.5 minutes: the writer writes this moment between clicks, and the next click lands in a moment
        // that already has a note (a moment revision bump) — its note must stay on screen until the new one is written.
        stretch(at(10, 36), 40, "Chrome", "Q3 investor update - Google Docs", docs, every: 150)
        text(at(11, 16), "Sam", "Investor update draft is in the doc")
        stretch(at(11, 20), 30, "Chrome", "Q3 investor update - Google Docs", docs)
        // Lunch: idle rows only, a group text to Q7, then ChatGPT with no typing.
        for i in 0..<6 { ev(at(11, 52, i * 20), "idle", "") }
        text(at(12, 0), "Q7", "Friday dinner at 8? I booked the place on Elm Street")
        stretch(at(12, 5), 38, "ChatGPT", "ChatGPT")
        for i in 0..<4 { ev(at(12, 45, i * 30), "idle", "") }
        stretch(at(13, 0), 35, "Chrome", "Weekly summaries export by riley · Pull Request #418 · daydream/daydream", gh)
        stretch(at(13, 35), 8, "Slack", "#eng (Channel) - DayDream - Slack")
        typed(at(13, 38), "Slack", "#eng (Channel) - DayDream - Slack", "Left comments on the export pull request", "chat", to: "#eng")
        stretch(at(13, 43), 30, "Chrome", "Weekly summaries export by riley · Pull Request #418 · daydream/daydream", gh)
        stretch(at(14, 15), 30, "Zoom", "Zoom Meeting", every: 120)
        stretch(at(14, 45), 45, "Xcode", "ExportWriter.swift — daydream")
        text(at(15, 30), "Q7", "Still on for Friday?")
        stretch(at(15, 34), 50, "Xcode", "ExportWriter.swift — daydream")
        stretch(at(16, 24), 10, "Chrome", "Inbox (9) - sam@daydream.example - Gmail", gm)
        stretch(at(16, 34), 30, "ChatGPT", "ChatGPT")
        typed(at(16, 36), "ChatGPT", "ChatGPT", "Review this writer for empty days", "ai", to: "ChatGPT")
        stretch(at(17, 4), 40, "Xcode", "ExportWriter.swift — daydream")
        text(at(17, 50), "Riley", "See you at 7 Thursday")
        return rows.sorted { ($0["at"] as! String, $0["id"] as! String) < ($1["at"] as! String, $1["id"] as! String) }
    }

    // MARK: Once: no skeleton or pending chip anywhere in the card, the rows or the expanded moment

    static func sources() {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let dir = ProcessInfo.processInfo.environment["DD_SOURCE_ROOT"].map { URL(fileURLWithPath: $0) } ?? here
        for file in ["FocusListSummaryCard", "FocusListRows", "FocusListExpanded", "DaydreamKitMoments", "RecallPreview", "CanonicalTimeline"] {
            guard let text = try? String(contentsOf: dir.appendingPathComponent("Sources/MemoryUI/\(file).swift"), encoding: .utf8) else {
                check(false, "sources: \(file).swift readable"); continue
            }
            check(!text.contains("SkeletonLines(") && !text.contains("PendingChip("), "sources: no skeleton lines or pending chip in \(file).swift")
            // The candidate's count headline was `.fallback(title: "24 moments")`; the ribbon's VoiceOver label keeps its count.
            check(!text.contains("case fallback(") && !text.contains(".fallback(title:"), "sources: no \"N moments\" headline in \(file).swift")
        }
    }

    // MARK: One mode, minute by minute

    static func store(_ name: String) throws -> MemoryStore {
        let home = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: home)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        var consent = try store.policy(); consent.captureText = true; consent.typedConsentVersion = 1; try store.updatePolicy(consent)
        let keys = InMemoryTypedKeyStore()
        try store.attachVault(TypedTextVault(keyStore: keys)); try store.setUpTypedVault(); try store.acceptSafeTyping()
        var typed = try store.typedTextPolicy()
        typed.retention = .days30
        typed.categories = TypedCategoryChoices(searchAndAI: true, writing: true, code: true, messagesAndEmail: true, otherWebsites: true)
        typed.shareWithSummaries = .localOnly
        _ = try store.updateTypedTextPolicy(typed, confirmed: true)
        return store
    }

    static func availability(_ mode: String) -> SummaryAvailability {
        switch mode {
        #if CANDIDATE_5C76A6F
        case "off": return SummaryAvailability(provider: .off, busy: false)
        case "downloading": return SummaryAvailability(provider: .local, busy: false, downloadProgress: 1.2 / 2.7)
        case "cloud-13": return SummaryAvailability(provider: .cloud, busy: false)
        default: return SummaryAvailability(provider: .local, busy: false)
        #else
        case "off": return SummaryAvailability(provider: .off, busy: false, phase: .off)
        case "downloading": return SummaryAvailability(provider: .off, busy: false, phase: .downloading(received: 1_200_000_000, total: 2_700_000_000))
        case "cloud-13": return SummaryAvailability(provider: .cloud, busy: false, phase: .on(.cloud), writesFrom: at(13, 0))
        default: return SummaryAvailability(provider: .local, busy: false, phase: .on(.local))
        #endif
        }
    }

    /// What a note says for a moment, by what it is (a fake writer; the words are made up and never copy typed words).
    static func note(for m: ActivityNote, actions: [CanonicalAction]) -> (title: String, bullets: [(String, [String], String)]) {
        let typedSent = actions.filter { $0.kind == "keyboard.text_input" && $0.state == "submitted" }.map(\.id)
        let seen = actions.filter { $0.kind != "keyboard.text_input" }.prefix(2).map(\.id)
        let s = m.subject
        func with(_ title: String, _ observed: String, send: String? = nil) -> (String, [(String, [String], String)]) {
            var b = [(String, [String], String)]()
            if !seen.isEmpty { b.append((observed, Array(seen), "observed")) }
            if let send, !typedSent.isEmpty { b.append((send, typedSent, "submitted")) }
            return (title, b)
        }
        if s == "Q7", let start = ISO8601DateFormatter().date(from: m.start), start >= at(15, 0) {
            return with("Checking in with Q7", "Read the latest in the Q7 group chat.", send: "Texted Q7 to confirm the plan")
        }
        if s == "Q7" { return with("Friday dinner plans with Q7", "Had the Q7 group chat open in Messages.", send: "Texted Q7 about Friday dinner") }
        if s == "Riley" { return with("Thursday dinner with Riley", "Had the Riley conversation open in Messages.", send: "Texted Riley about Thursday dinner") }
        if s == "Sam" { return with("Dinner and the update with Sam", "Had the Sam conversation open in Messages.", send: "Texted Sam about the booking") }
        if s.contains("Pro plan pricing") || s == "mail.google.com" { return with("Pro plan pricing", "Read the pricing thread in Gmail.", send: "Emailed Sam about pricing") }
        if s.hasPrefix("Inbox") { return with("Inbox triage", "Went through the inbox in Gmail.") }
        if s.contains("Pull Request #418") { return with("Reviewed PR #418: weekly summaries export", "Read the export pull request on GitHub.") }
        if s.contains("#eng") { return with("Export review in #eng", "Had the eng channel open in Slack.", send: "Messaged #eng about the export review") }
        if s.contains("Q3 investor update") { return with("Q3 investor update", "Edited the Q3 investor update in Google Docs.") }
        if s.hasPrefix("ChatGPT") || s == "ChatGPT" {
            // The weak writer's filler for a chat: the page must not show it.
            return typedSent.isEmpty ? with("Worked in ChatGPT", "Had ChatGPT open and in use.")
                                     : with("Export crash help from ChatGPT", "Had a ChatGPT chat open.", send: "Asked ChatGPT how to fix the export crash")
        }
        if s.contains(".swift") { return with("Export crash fix in \(s.components(separatedBy: " — ").first ?? s)", "Changed the export code in Xcode.") }
        return with("Export tests", "Ran the tests in Terminal.")
    }

    /// fix/sx-all round 2 (F1): a note an earlier writer wrote ("...-prompt7-validator9") is pending again on a recent
    /// day, with the old note kept as `previous` (the row never goes blank), until this build's note is saved; an older
    /// day keeps it.
    static func outdatedNotes(_ rows: [[String: Any]]) throws {
        let store = try store("outdated")
        for row in rows.prefix(40) {
            let e = try JSONDecoder().decode(Evidence.self, from: JSONSerialization.data(withJSONObject: row))
            _ = try store.ingest(e, now: (ISO8601DateFormatter().date(from: e.at) ?? at(9, 0)).addingTimeInterval(1))
        }
        let now = at(18, 0)
        guard let m = try store.dayLayers(day: day, timezone: zone, now: now).activities.first(where: { $0.status == "pending" }) else {
            check(false, "outdated: a moment to write"); return
        }
        func commit(_ version: String) throws -> Bool {
            let request = try store.prepareNote(kind: "activity", day: day, timezone: zone, activityID: m.id, now: now)
            var actions = request.actions, next = request.next
            while let offset = next { let page = try store.noteActions(requestID: request.id, after: offset, now: now); actions += page.actions; next = page.next }
            guard let first = actions.first(where: { $0.kind != "keyboard.text_input" }) ?? actions.first else { return false }
            let output = NoteWriterOutput(requestID: request.id, title: "Morning email", bullets: [NoteBullet(text: "Went through the inbox.", actionIDs: [first.id], assertion: "observed")],
                                          generator: "local/qwen3.5-4b-q4_k_m", generatorVersion: version)
            do { _ = try store.commitNote(output, now: now); return true } catch { return false }
        }
        check(try commit("qwen35-4b-q4-b9723-prompt7-validator9"), "outdated: an old writer's note is saved")
        let again = try store.dayLayers(day: day, timezone: zone, now: now).activities.first { $0.id == m.id }
        check(again?.status == "pending" && again?.generated == nil && again?.previous?.output.generatorVersion == "qwen35-4b-q4-b9723-prompt7-validator9",
              "outdated: a prompt7-validator9 note is pending again today, the old note kept on screen", "\(String(describing: again?.status))")
        let later = try store.dayLayers(day: day, timezone: zone, now: now.addingTimeInterval(10 * 86400)).activities.first { $0.id == m.id }
        check(later?.status == "ready", "outdated: on a day 10 days back the old note stays", "\(String(describing: later?.status))")
        check(try commit(NoteWriterVersions.current[0]), "outdated: this build's note is saved")
        let fresh = try store.dayLayers(day: day, timezone: zone, now: now).activities.first { $0.id == m.id }
        check(fresh?.status == "ready" && fresh?.generated?.output.generatorVersion == NoteWriterVersions.current[0], "outdated: once rewritten it is ready")
    }

    /// Writes a moment's note the way a writer does (prepare, read every page, commit). Refusals are the store's own
    /// checks (a moment that changed meanwhile, a cloud writer's scope) and simply leave it for the next pass.
    static func write(_ store: MemoryStore, _ m: ActivityNote, audience: NoteAudience, now: Date) throws -> Bool {
        let request: NoteWriterRequest
        do { request = try store.prepareNote(kind: "activity", day: day, timezone: zone, activityID: m.id, audience: audience, now: now) }
        catch { return false }
        var actions = request.actions, next = request.next
        while let offset = next {
            let page = try store.noteActions(requestID: request.id, after: offset, now: now)
            actions += page.actions; next = page.next
        }
        let byID = Dictionary(actions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let (title, bullets) = note(for: m, actions: m.actionIDs.compactMap { byID[$0] })
        let usable = bullets.map { b in (b.0, b.1.filter { byID[$0] != nil }, b.2) }.filter { !$0.1.isEmpty }
        guard !usable.isEmpty else { return false }
        let output = NoteWriterOutput(requestID: request.id, title: title,
                                      bullets: usable.map { NoteBullet(text: $0.0, actionIDs: $0.1, assertion: $0.2) },
                                      generator: audience == .cloud ? "cloud/synthetic" : "local/synthetic", generatorVersion: "1")
        do { _ = try store.commitNote(output, now: now); return true } catch { return false }
    }

    static let fillerPatterns = ["^(had|has) .* open( and in use)?", "^(worked|working|was working) (in|on|with) ", "open and in use", "window open$",
                                 "^wrote a message (in|on) ", "^untitled", "^\\d+\\+? moments?$", "^summary pending$", "^typ(ed|ing) in "]
    static func filler(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return fillerPatterns.contains { t.range(of: $0, options: .regularExpression) != nil }
    }
    static func raw(_ title: String) -> Bool {
        title.contains("@") || title.range(of: "\\(\\d+\\)", options: .regularExpression) != nil || title.contains(" - Gmail")
            || title.contains(" · Pull Request") || title.contains(" | ")
    }
    static let talk = ["Texted", "Emailed", "Messaged", "Asked", "Posted", "Replied", "Texts with", "Email with", "Email about", "Slack with", "Slack in"]
    static func conversation(_ line: String) -> Bool { talk.contains { line.hasPrefix($0 + " ") || line.hasPrefix($0) } }

    static func replay(_ mode: String, _ rows: [[String: Any]]) async throws {
        let store = try store(mode)
        let summaries = availability(mode)
        let writes = ["local-ac", "local-battery", "cloud-13"].contains(mode)
        let levelsOn = mode == "local-ac" || mode == "cloud-13"
        let audience: NoteAudience = mode == "cloud-13" ? .cloud : .local
        let levelWriter = LevelWriterBinding(store: store, generate: nil)
        var evidence = try rows.map { try JSONDecoder().decode(Evidence.self, from: JSONSerialization.data(withJSONObject: $0)) }
        evidence.sort { $0.at < $1.at }
        var next = 0
        var hadNote = [String: String]()        // moment id -> the note title once shown
        var forgotten: (id: String, words: [String])? = nil
        var typedAccepted = 0
        var staleFrames = 0
        var t = at(8, 30)
        while t <= at(18, 0) {
            while next < evidence.count, let when = ISO8601DateFormatter().date(from: evidence[next].at), when <= t {
                if try store.ingest(evidence[next], now: when.addingTimeInterval(1)), evidence[next].kind == "keyboard.text_input" { typedAccepted += 1 }
                next += 1
            }
            // A privacy-setting change at 12:30 (a policy revision bump). Core deletes every stored note on a privacy change
            // by design (an excluded app's words must not survive in a note), so rows fall back to the day's threads by code:
            // never blank, never pending-looking, but not the old note either.
            if t == at(12, 30) {
                var policy = try store.policy()
                policy.blockedApps.append("com.example.never-installed")
                try store.updatePolicy(policy, now: t)
                hadNote.removeAll()
            }

            // The writer: moments that settled two minutes ago, two a minute (one on battery), cloud only from 13:00.
            if writes {
                let layers = try store.dayLayers(day: day, timezone: zone, limit: 1, now: t)
                var budget = mode == "local-battery" ? 1 : 2
                for m in layers.activities where m.status != "ready" && budget > 0 {
                    guard let end = ISO8601DateFormatter().date(from: m.end), t.timeIntervalSince(end) >= 120 else { continue }
                    if audience == .cloud, let start = ISO8601DateFormatter().date(from: m.start), start < at(13, 0) { continue }
                    let targets = try store.noteTargets(day: day, timezone: zone, audience: audience, now: t)
                    guard targets.contains(where: { $0.id == m.id }) else { continue }
                    if try write(store, m, audience: audience, now: t) { budget -= 1 }
                }
                // No writer is ever asked for an idle-only moment.
                for target in try store.noteTargets(day: day, timezone: zone, audience: audience, now: t) where target.kind == "activity" {
                    if let m = layers.activities.first(where: { $0.id == target.id }) {
                        check(!(m.apps.allSatisfy(\.isEmpty) && m.sites.isEmpty), "writer: an idle-only moment is never a note target", "\(mode) \(m.start)")
                    }
                }
                if levelsOn, Calendar.current.component(.minute, from: t) % 10 == 0 {
                    for _ in 0..<3 { if (try? await levelWriter.step(timezone: zone, now: t)) == nil { break } }
                }
            }
            // A Forget at 16:40: the first Q7 group text (with its note where one was written).
            if t == at(16, 40) {
                let layers = try store.dayLayers(day: day, timezone: zone, limit: 1, now: t)
                if let m = layers.activities.first(where: { $0.subject == "Q7" }) {
                    let words = [m.generated?.output.title].compactMap { $0 } + (m.generated?.output.bullets.map(\.text) ?? []) + ["Q7"]
                    let preview = try store.prepareDeletion(scope: MemoryActionScope(kind: "activity", id: m.id, day: day, timezone: zone), now: t)
                    _ = try store.executeDeletion(previewID: preview.id, confirmed: true, now: t)
                    forgotten = (m.id, words)
                    hadNote[m.id] = nil
                } else { check(false, "forget: the Q7 moment is there to forget", mode) }
            }
            staleFrames += try frame(store, mode: mode, summaries: summaries, now: t, hadNote: &hadNote, forgotten: forgotten)
            t = t.addingTimeInterval(60)
        }
        #if DAYDREAM_OWNER_TYPING
        // Six texts and the Gmail reply (typing in the ChatGPT app and Slack is not recorded).
        check(typedAccepted >= 7, "fixture: typed rows with send facts were recorded", "\(mode): \(typedAccepted)")
        #endif
        if mode == "local-ac" || mode == "local-battery" {
            check(staleFrames > 0, "rows: a moment's revision bump was exercised (its older note shown while a newer one is written)", "\(mode): \(staleFrames)")
        }
        #if !CANDIDATE_5C76A6F
        if mode == "local-ac" { try await threadsBump(store, levelWriter) }
        #endif
    }

    /// Checks one minute; returns 1 when a row showed an older note while a newer one was being written.
    @discardableResult
    static func frame(_ store: MemoryStore, mode: String, summaries: SummaryAvailability, now: Date, hadNote: inout [String: String],
                      forgotten: (id: String, words: [String])?) throws -> Int {
        var stale = 0
        var read = try store.dayLayers(day: day, timezone: zone, limit: 200, now: now)
        read.levels = try store.dayLevels(day: day, timezone: zone)
        let s = TodaySnapshot.make(day: read, summaries: summaries, calendar: cal, now: now)
        let hm = String(format: "%02d:%02d", cal.component(.hour, from: now), cal.component(.minute, from: now))
        let tag = "\(mode) \(hm)"
        guard !s.moments.isEmpty else { return 0 }
        // The card: a headline, never a count; sends and conversations first.
        var cardLines = [String]()
        switch FocusListSummaryCard.headline(for: s, day: .today, timeZone: cal.timeZone) {
        case .ready(let title, let bullets, _):
            check(!title.trimmingCharacters(in: .whitespaces).isEmpty, "card: the headline is never empty", tag)
            check(!filler(title) && !raw(title), "card: the headline is a name, not filler or a raw title", "\(tag): \(title)")
            let lines = bullets.filter { !$0.correction }.map(\.text)
            if let firstOther = lines.firstIndex(where: { !conversation($0) }) {
                check(!lines[firstOther...].contains(where: conversation), "card: sends and conversations come first", "\(tag): \(lines)")
            }
            check(!lines.contains(where: filler), "card: no filler line", "\(tag): \(lines)")
            cardLines = [title] + lines
        default:
            check(false, "card: a day with moments always has a headline (never \"N moments\")", tag)
        }
        #if !CANDIDATE_5C76A6F
        let phase = FocusListSummaryCard.phaseLine(s.summaries)
        switch mode {
        case "off": check(phase == .off, "card: \"Summaries are off\" only while off", tag)
        case "downloading": check(phase == .status("Downloading 1.2 of 2.7 GB"), "card: the download's own line", "\(tag): \(phase)")
        default: check(phase == .none, "card: nothing about summaries while they are on", "\(tag): \(phase)")
        }
        if let live = s.live {
            let lines = live.lines.map(\.text)
            if let firstOther = lines.firstIndex(where: { !conversation($0) }) {
                check(!lines[firstOther...].contains(where: conversation), "live: send lines come first in LiveDay.lines", "\(tag): \(lines)")
            }
        }
        #endif
        // The rows.
        for m in s.moments {
            let sub = MomentSubtitle.rowText(for: m)
            check(!m.title.isEmpty && !filler(m.title), "rows: a row title is never filler", "\(tag): \(m.title)")
            check(!raw(m.title), "rows: a row title is never a raw window title", "\(tag): \(m.title)")
            check(!filler(sub) && sub != "Summary pending", "rows: a row's second line is never filler or pending", "\(tag): \(m.title) | \(sub)")
            check(!(m.apps.allSatisfy(\.isEmpty) && m.sites.isEmpty), "rows: idle-only moments are not rows", "\(tag): \(m.id)")
            if hadNote[m.id] != nil {
                check(m.summary.isReady && (!m.bullets.isEmpty || !sub.isEmpty), "rows: a moment that had a note never goes blank while a newer one is written",
                      "\(tag): \(m.title) [\(m.summary)]")
            }
            if m.summary.isReady, !m.bullets.isEmpty { hadNote[m.id] = m.title }
            // Never blank: every row has a title and a second line (a note line, a send, or its time).
            check(!m.title.isEmpty && !(sub.isEmpty && m.bullets.isEmpty), "rows: no row is ever blank", "\(tag): \(m.title) | \(sub)")
            #if !CANDIDATE_5C76A6F
            if m.stale { stale = 1 }
            #endif
            #if !CANDIDATE_5C76A6F
            if mode == "cloud-13", m.start < at(13, 0) {
                check(m.summary == .notWritten, "cloud: a moment before the cutoff is never pending (no Summarize Now)", "\(tag): \(m.title) [\(m.summary)]")
            }
            if m.summary == .pending || m.summary == .summariesOff || m.summary == .notWritten, let live = m.live, live.sends.isEmpty {
                check(sub == live.duration || sub.isEmpty, "rows: without a note or a send, the second line is the time", "\(tag): \(m.title) | \(sub)")
            }
            #endif
            // The ChatGPT session with no typing: "ChatGPT" and its time.
            if m.apps == ["ChatGPT"], m.start >= at(12, 5), m.start < at(12, 44), !m.summary.isReady {
                check(m.title == "ChatGPT" && sub.hasPrefix("~") && sub.hasSuffix("min"), "rows: a ChatGPT session with no typing reads \"ChatGPT\" and its time",
                      "\(tag): \(m.title) | \(sub)")
            }
            #if DAYDREAM_OWNER_TYPING && !CANDIDATE_5C76A6F
            if m.subject == "Q7", !m.summary.isReady, let typedAt = [at(12, 1), at(15, 31)].last(where: { $0 < m.start.addingTimeInterval(120) }),
               now > typedAt {
                check(m.title == "Texts with Q7" && sub == "Texted Q7", "rows: the Q7 group text reads \"Texts with Q7\" / \"Texted Q7\"", "\(tag): \(m.title) | \(sub)")
            }
            #endif
        }
        // The 11:00 card while nothing writes: the main thread and its time, named side lines.
        if hm == "11:00", ["off", "downloading", "local-battery"].contains(mode) {
            #if !CANDIDATE_5C76A6F
            check(s.levels?.headlineDuration != nil, "card at 11:00: the main thread's time beside the headline", tag)
            #endif
            #if DAYDREAM_OWNER_TYPING
            check(cardLines.contains { $0.contains("Riley") || $0.contains("Sam") }, "card at 11:00: the texts are a named side line", "\(tag): \(cardLines)")
            #endif
        }
        // A forgotten moment shows nothing of its old note.
        if let forgotten {
            check(!s.moments.contains { $0.id == forgotten.id }, "forget: the forgotten moment is gone", tag)
            let shown = cardLines + s.moments.flatMap { [$0.title, MomentSubtitle.rowText(for: $0)] + $0.bullets.map(\.text) }
                + (s.levels?.blocks.flatMap { [$0.name] + $0.sideThreads } ?? [])
            for word in forgotten.words where word != "Q7" || !s.moments.contains(where: { $0.subject == "Q7" }) {
                check(!shown.contains { $0.contains(word) }, "forget: nothing of the forgotten moment's note shows", "\(tag): \(word)")
            }
        }
        return stale
    }

    #if !CANDIDATE_5C76A6F
    /// A stored day note cut by an older threads planner (its main thread's key no longer the day's): the day's threads by
    /// code show instead, never a blank card; and with nothing live to compare, the stored note shows.
    static func threadsBump(_ store: MemoryStore, _ writer: LevelWriterBinding) async throws {
        // The evening pass: every moment written, then the block and day notes (code-only binding, no model).
        let evening = at(18, 30)
        for _ in 0..<40 {
            let pending = try store.noteTargets(day: day, timezone: zone, audience: .local, now: evening).filter { $0.kind == "activity" }
            let layers = try store.dayLayers(day: day, timezone: zone, limit: 1, now: evening)
            var wrote = false
            for target in pending { if let m = layers.activities.first(where: { $0.id == target.id }), try write(store, m, audience: .local, now: evening) { wrote = true } }
            if !wrote { break }
        }
        for _ in 0..<40 { if (try? await writer.step(timezone: zone, now: evening)) == nil { break } }
        guard var levels = try? store.dayLevels(day: day, timezone: zone), var note = levels.day, var threads = note.threads, !threads.isEmpty,
              let live = levels.live else {
            let l = try? store.dayLevels(day: day, timezone: zone)
            let work = (try? store.levelWork(timezone: zone, now: evening, limit: 8)) ?? []
            check(false, "threads bump: the day note and live threads are there by 18:00 on power",
                  "day \(l?.day != nil) live \(l?.live != nil) blocks \(l?.blocks.count ?? -1) work \(work.map { $0.target })"); return
        }
        let fits = DayLevelSlice.make(levels, calendar: cal)
        check(fits?.dayTitle?.isEmpty == false, "threads bump: the card has a headline before the bump")
        threads[0].key = "threads-old:" + threads[0].key
        note.threads = threads
        levels.day = note
        let bumped = DayLevelSlice.make(levels, calendar: cal)
        check(bumped?.dayIsLive == true && bumped?.dayTitle == live.mainTitle && !(live.mainTitle.isEmpty),
              "threads bump: a day note from an older planner gives way to the day's threads by code, never a blank card")
        levels.live = nil
        let stored = DayLevelSlice.make(levels, calendar: cal)
        check(stored?.dayIsLive == false && stored?.dayTitle?.isEmpty == false, "threads bump: with nothing live, the stored day note shows")
        // A model day title that only says what was open (real Qwen 3.5 4B, 9/24) gives way to the note's stored main thread.
        var filler = note
        filler.title = "Had the Q3 investor update open in Google Docs."
        levels.day = filler
        let named = DayLevelSlice.make(levels, calendar: cal)
        check(named?.dayTitle == LevelWords.sentence(threads[0].label) && !(named?.dayTitle ?? "").lowercased().hasPrefix("had "),
              "card: a day title that only says what was open gives way to the day's main thread", named?.dayTitle ?? "nil")
        // A day note the code saved plain (r2: kinds only, "Document") gives way to the day's threads by code.
        var plain = note
        plain.threads = [LevelThreads.plained(threads[0])] + threads.dropFirst()
        plain.threads?[0].key = String(threads[0].key.dropFirst("threads-old:".count))
        plain.generator = LevelWriterVersion.extractive
        plain.title = LevelThreads.plainLabel(threads[0])
        levels.day = plain
        levels.live = live
        let plainSlice = DayLevelSlice.make(levels, calendar: cal)
        check(!DayLevels.savedPlain(plain) || (plainSlice?.dayIsLive == true && plainSlice?.dayTitle == live.mainTitle),
              "card: a day note saved plain gives way to the day's threads by code", "\(plain.title) -> \(plainSlice?.dayTitle ?? "nil")")
        check(threads[0].kind == "app" || DayLevels.savedPlain(plain), "card: a plain day note is known as one", plain.title)
    }
    #endif
}
