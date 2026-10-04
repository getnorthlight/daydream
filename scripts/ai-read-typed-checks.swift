import Foundation
@testable import MemoryCore

/// claude/summary-1003 (owner decision 2026-10-03): "Let AI apps read what you typed". Synthetic store, made-up words,
/// in-memory typing keys only (never the Keychain); the bridge socket lives in a scratch folder. Covers: the setting on
/// and off, a grant that doesn't verify, a secret never returned, expired words never returned, an excluded app and a
/// private window never returned, moment_details pagination and its byte bound, and (with DAYDREAM_TEST_CLI) the real
/// `mac-mem mcp` reading through the bridge: moment_details and search with the setting on and off.
/// Prints labels and counts only, never a typed word.
@main struct AIReadTypedChecks {
    static var count = 0
    static func check(_ value: Bool, _ label: String) { precondition(value, "FAILED: " + label); count += 1; print("PASS " + label) }

    /// Fixture replies saved for the evidence notes (AI_READ_SAMPLES, optional). Made-up words only.
    static func sample(_ name: String, _ replies: [String]) {
        guard let folder = ProcessInfo.processInfo.environment["AI_READ_SAMPLES"], !folder.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? replies.joined(separator: "\n\n-----\n\n").write(toFile: folder + "/" + name + ".md", atomically: true, encoding: .utf8)
    }
    /// Every “quoted” span of a concise reply (up to an ellipsis) is inside one of the detailed reply's strings.
    static func quotesWithin(_ concise: String, _ detailed: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(detailed.utf8)) else { return false }
        var values: [String] = []
        func walk(_ v: Any) { if let s = v as? String { values.append(s) } else if let a = v as? [Any] { a.forEach(walk) } else if let d = v as? [String: Any] { d.values.forEach(walk) } }
        walk(object)
        var rest = Substring(concise)
        while let open = rest.firstIndex(of: "\u{201C}") {
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "\u{201D}") else { break }
            let quoted = after[..<close].split(separator: "\u{2026}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 3 }
            if !quoted.allSatisfy({ q in values.contains { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).contains(q) } }) { return false }
            rest = after[after.index(after: close)...]
        }
        return true
    }

    static func main() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AI_READ_CHECK_ROOT"] ?? NSTemporaryDirectory())
            .appendingPathComponent("ai-read-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let home = root.appendingPathComponent("h", isDirectory: true)
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try store.updatePolicy(policy, now: now)
        try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore()), now: now); try store.setUpTypedVault(now: now); try store.acceptSafeTyping(now: now)

        // Made-up words. One marker per row so a leak is easy to see in raw output.
        let marker = "zebraquilt"
        func typed(_ id: String, _ text: String, at: Date, app: String = "Notes", bundle: String = "com.apple.Notes", privateWindow: Bool = false) -> Evidence {
            Evidence(id: id, at: iso(at), kind: "keyboard.text_input", app: app, bundle: bundle, title: "Plans", text: text, privateWindow: privateWindow, synthetic: true)
        }
        let base = now.addingTimeInterval(-600)
        var ids: [String] = []
        for i in 0..<30 {
            let id = "t\(i)"
            check(try store.ingest(typed(id, "note \(marker) number \(i) about the ZUX launch plan", at: base.addingTimeInterval(Double(i) * 5)), now: now), "typed row \(i) sealed")
            ids.append(id)
        }
        let token = "ghp_" + String(repeating: "Q7x", count: 12)
        _ = try store.ingest(typed("t-secret", "deploy \(marker) with \(token) today", at: base.addingTimeInterval(160)), now: now)
        let old = now.addingTimeInterval(-9 * 86400)
        let expiredSaved = try store.ingest(typed("t-old", "old \(marker) words", at: old), now: old.addingTimeInterval(60))
        let privateSaved = (try? store.ingest(typed("t-private", "private \(marker) words", at: base.addingTimeInterval(170), privateWindow: true), now: now)) ?? false
        let otherSaved = (try? store.ingest(typed("t-other", "textedit \(marker) words", at: base.addingTimeInterval(175), app: "TextEdit", bundle: "com.apple.TextEdit"), now: now)) ?? false
        print("INFO saved expired=\(expiredSaved) private=\(privateSaved) textedit=\(otherSaved)")

        let capability = try store.grant(client: "test-host", recipient: "synthetic-local", scopes: ["context", "search", "detail"])
        let reader = TypedReader(client: "test-host", recipient: "synthetic-local", capability: capability)
        let wrong = TypedReader(client: "test-host", recipient: "synthetic-local", capability: "not-the-key")

        // The one setting (AIReadsTypedSetting, key "aiAppsReadTyped"): on by default, off when the person turns it off.
        let suite = "ai-read-check-\(getpid())", defaults = UserDefaults(suiteName: suite)!
        check(AIReadsTypedSetting.key == "aiAppsReadTyped" && AIReadsTypedSetting.isOn(defaults), "the setting is on by default (owner decision 2026-10-03)")
        AIReadsTypedSetting.set(false, defaults); check(!AIReadsTypedSetting.isOn(defaults), "turning it off is read back as off")
        defaults.removePersistentDomain(forName: suite)
        // Setting off: nothing.
        do { _ = try store.assistantTypedWords(ids, reader: reader, enabled: false, now: now); check(false, "off refuses words") }
        catch { check((error as? AssistantTypedReadError) == .off, "setting off: no words") }
        check(store.assistantBridgeAnswer(["op": "words", "ids": ids, "client": reader.client, "recipient": reader.recipient, "capability": capability], enabled: false)["status"] as? String == "off", "setting off: bridge answers off")
        check(store.assistantBridgeAnswer(["op": "search", "query": "ZUX", "client": reader.client, "recipient": reader.recipient, "capability": capability], enabled: false)["status"] as? String == "off", "setting off: typed search answers off")
        // A key that doesn't verify.
        check(store.assistantBridgeAnswer(["op": "words", "ids": ids, "client": wrong.client, "recipient": wrong.recipient, "capability": wrong.capability], enabled: true)["status"] as? String == "denied", "wrong key: denied")

        // Setting on.
        let words = try store.assistantTypedWords(ids + ["t-secret", "t-old", "t-private"], reader: reader, enabled: true, now: now)
        check(ids.allSatisfy { words[$0]?.contains(marker) == true }, "setting on: every typed row's words come back (30)")
        check(words["t-secret"].map { !$0.contains(token) && !$0.contains("Q7xQ7x") } ?? true, "a secret is never returned")
        check(words["t-old"] == nil, "expired words are never returned")
        check(words["t-private"] == nil, "private window words are never returned")
        check(AssistantTypedText.shareable("password: hunter2zz") .map { !$0.contains("hunter2zz") } ?? true, "a password assignment is withheld")
        check(AssistantTypedText.shareable("770011") == nil, "a lone one-time code is withheld")
        check(AssistantTypedText.shareable("deploy with \(token) today").map { !$0.contains(token) && !$0.contains("Q7xQ7x") } ?? true, "a provider token in raw words is withheld on the way out")

        // A blocked site: a row whose page is blocked later is never returned.
        var site = typed("t-site", "site \(marker) words", at: base.addingTimeInterval(178)); site.url = "https://blocked-fixture.example/page"
        if (try? store.ingest(site, now: now)) == true, try store.assistantTypedWords(["t-site"], reader: reader, enabled: true, now: now)["t-site"] != nil {
            var p = try store.policy(); p.blockedDomains = ["blocked-fixture.example"]; try store.updatePolicy(p, now: now)
            check(try store.assistantTypedWords(["t-site"], reader: reader, enabled: true, now: now)["t-site"] == nil, "blocked site: words never returned")
            check(try !store.assistantTypedSearch("site \(marker)", reader: reader, enabled: true, now: now).contains { $0["id"] == "t-site" }, "blocked site: never in typed search")
        } else { check(true, "blocked site: this lane keeps no page on a typed row (nothing to return)") }

        let hits = try store.assistantTypedSearch("ZUX launch", reader: reader, enabled: true, now: now)
        check(!hits.isEmpty && hits.count <= 20 && hits.allSatisfy { ($0["snippet"] ?? "").lowercased().contains("zux") }, "typed search finds ZUX (\(hits.count) hits, at most 20)")
        check(try store.assistantTypedSearch("nothingmatchesthis", reader: reader, enabled: true, now: now).isEmpty, "typed search: no false hits")
        check(try !store.assistantTypedSearch("old \(marker)", reader: reader, enabled: true, now: now).contains { $0["id"] == "t-old" }, "typed search skips expired words")

        // An excluded app: its words are never returned once it's excluded.
        if otherSaved {
            check(try store.assistantTypedWords(["t-other"], reader: reader, enabled: true, now: now)["t-other"] != nil, "before exclusion the TextEdit row reads")
            var p = try store.policy(); p.blockedApps = ["com.apple.TextEdit"]; try store.updatePolicy(p, now: now)
            check(try store.assistantTypedWords(["t-other"], reader: reader, enabled: true, now: now)["t-other"] == nil, "excluded app: words never returned")
            check(try !store.assistantTypedSearch("textedit \(marker)", reader: reader, enabled: true, now: now).contains { $0["id"] == "t-other" }, "excluded app: never in typed search")
        } else { check(true, "excluded app: this lane records no TextEdit typing (refused at ingest)") }

        // moment_details: pagination and its bound (no words: as the MCP process sees it without the bridge).
        guard let page1 = try store.assistantMomentPage(id: "t3", uri: nil, now: now) else { check(false, "moment found"); return }
        check(page1.total >= 30 && page1.actions.count == 25, "moment_details page 1 holds 25 of \(page1.total) actions")
        let body1 = try store.assistantMomentDetails(page1, words: [:], wordsNote: "off")
        let json1 = try JSONSerialization.jsonObject(with: Data(body1.utf8)) as! [String: Any]
        check(body1.utf8.count <= MemoryStore.momentPageBytes && json1["next"] as? String == "o:25", "page 1 is bounded and continues at o:25")
        check(!body1.contains(marker), "without the bridge's words no typed word appears")
        guard let page2 = try store.assistantMomentPage(id: "t3", uri: nil, after: "o:25", now: now) else { check(false, "page 2"); return }
        let body2 = try store.assistantMomentDetails(page2, words: [:], wordsNote: nil)
        let json2 = try JSONSerialization.jsonObject(with: Data(body2.utf8)) as! [String: Any]
        let shown2 = (json2["actions"] as? [[String: Any]])?.count ?? 0
        check(shown2 == page1.total - 25 && json2["next"] == nil, "page 2 holds the rest (\(shown2)) and ends")
        let withWords = try store.assistantMomentDetails(page1, words: words, wordsNote: nil)
        check(withWords.contains(marker) && withWords.utf8.count <= MemoryStore.momentPageBytes, "with the setting on, the page carries the typed words, still bounded")
        let big = Dictionary(uniqueKeysWithValues: page1.typedIDs.map { ($0, String(repeating: "word ", count: 320)) })
        let bounded = try store.assistantMomentDetails(page1, words: big, wordsNote: nil)
        let jb = try JSONSerialization.jsonObject(with: Data(bounded.utf8)) as! [String: Any]
        check(bounded.utf8.count <= MemoryStore.momentPageBytes && (jb["actions"] as? [[String: Any]])?.count ?? 0 < 25 && jb["next"] != nil, "long words: the page is cut to the bound and continues")

        // The socket: same user only, one request per connection.
        var enabled = true
        let server = AssistantTypedBridgeServer(home: home) { request in store.assistantBridgeAnswer(request, enabled: enabled) }
        check(server.start(), "bridge listens")
        var info = stat(); _ = lstat(server.path, &info)
        check((info.st_mode & 0o777) == 0o600, "bridge socket is 0600")
        let reply = AssistantTypedBridge.call(home: home, ["op": "words", "ids": ["t1"], "client": reader.client, "recipient": reader.recipient, "capability": capability])
        check((reply?["words"] as? [String: String])?["t1"]?.contains(marker) == true, "bridge round trip: words with the setting on")
        enabled = false
        check(AssistantTypedBridge.call(home: home, ["op": "words", "ids": ["t1"], "client": reader.client, "recipient": reader.recipient, "capability": capability])?["status"] as? String == "off", "bridge round trip: off")
        enabled = true

        // The real MCP server, reading through this bridge.
        if let cli = ProcessInfo.processInfo.environment["DAYDREAM_TEST_CLI"], FileManager.default.isExecutableFile(atPath: cli) {
            func mcp(_ calls: [(String, [String: Any])]) throws -> [String] {
                let p = Process(); p.executableURL = URL(fileURLWithPath: cli)
                p.arguments = ["--home", home.path, "--client", reader.client, "--recipient", reader.recipient, "mcp"]
                var env = ProcessInfo.processInfo.environment; env["MAC_MEM_CAPABILITY"] = capability; env["DAYDREAM_TEST_FRESHEN_REQUEST"] = "com.example.ai-read-check"
                p.environment = env
                let input = Pipe(), output = Pipe(); p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
                try p.run()
                var lines = ""
                for (i, call) in calls.enumerated() {
                    let req: [String: Any] = ["jsonrpc": "2.0", "id": i + 1, "method": "tools/call", "params": ["name": call.0, "arguments": call.1]]
                    lines += String(decoding: try JSONSerialization.data(withJSONObject: req), as: UTF8.self) + "\n"
                }
                input.fileHandleForWriting.write(Data(lines.utf8)); try input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                return String(decoding: data, as: UTF8.self).split(separator: "\n").map { line in
                    guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let r = o["result"] as? [String: Any], let c = (r["content"] as? [[String: Any]])?.first, let t = c["text"] as? String else { return "ERROR " + String(line.prefix(200)) }
                    return t
                }
            }
            // claude/mcp-prompts-1003: the JSON checks ask for response_format "detailed"; concise (the default) is checked after.
            let on = try mcp([("moment_details", ["id": "t3", "response_format": "detailed"]), ("moment_details", ["id": "t3", "after": "o:25", "response_format": "detailed"]),
                              ("search", ["query": "ZUX", "response_format": "detailed"])])
            check(on.count == 3 && on[0].contains(marker) && on[0].contains("\"next\":\"o:25\""), "mcp moment_details (on): exact words, paginated")
            check(on[1].contains(marker) && !on[1].contains("\"next\""), "mcp moment_details page 2 (on): the rest")
            check(on[2].contains("\"typed\"") && on[2].lowercased().contains("zux"), "mcp search (on): typed hits with excerpts")
            check(!on.joined().contains(token) && !on.joined().contains("old \(marker)") && !on.joined().contains("private \(marker)"), "mcp (on): no secret, expired or private words")
            // Concise (the default): the same words, as quotes, only because the setting is on; ids, local times, Next lines.
            let concise = try mcp([("moment_details", ["id": "t3"]), ("search", ["query": "ZUX"]), ("moment_details", ["id": "t3", "after": "o:25"])])
            sample("concise-on", concise)
            check(concise.count == 3 && concise[0].contains("> \u{201C}note \(marker)") && concise[0].contains("draft, not sent") && concise[0].contains("moment `activity_")
                  && concise[0].contains("Next: more of this moment with the same id and after `o:25`") && !concise[0].contains("\"actions\""),
                  "mcp concise moment_details (on): quoted words, draft not sent, the moment id and the next page")
            check(concise[1].contains("**Typed words that match**") && concise[1].contains("> \u{201C}") && concise[1].contains("id `t") && concise[1].contains("Next:"),
                  "mcp concise search (on): typed hits quoted with their ids and a Next line")
            check(!concise.joined().contains(token) && !concise.joined().contains("old \(marker)") && !concise.joined().contains("private \(marker)"),
                  "mcp concise (on): no secret, expired or private words")
            check(quotesWithin(concise[0], on[0]) && quotesWithin(concise[1], on[2]) && quotesWithin(concise[2], on[1]),
                  "mcp concise says nothing detailed doesn't: every quote in it is in the detailed reply")
            enabled = false
            let conciseOff = try mcp([("moment_details", ["id": "t3"]), ("search", ["query": "ZUX"])])
            sample("concise-off", conciseOff)
            check(!conciseOff.joined().contains(marker) && conciseOff[0].contains("Typed in Notes") && conciseOff[0].contains("is off in DayDream")
                  && !conciseOff[1].contains("Typed words that match"), "mcp concise (off): where and how much, why not, no words and no typed hits")
            let off = try mcp([("moment_details", ["id": "t3", "response_format": "detailed"]), ("search", ["query": "ZUX", "response_format": "detailed"])])
            check(off.count == 2 && !off.joined().contains(marker) && off[0].contains("typing_note"), "mcp (off): no typed words, a plain note")
            check(!off[1].contains("\"typed\""), "mcp search (off): as before, no typed hits")
            enabled = true
            server.stop()
            let closed = try mcp([("moment_details", ["id": "t3", "response_format": "detailed"]), ("moment_details", ["id": "t3"])])
            check(!closed.joined().contains(marker) && closed[0].contains("typing_note") && closed[1].contains("isn't open"), "mcp (DayDream not running): no typed words, a plain note (detailed and concise)")
        } else {
            server.stop()
            print("SKIP mcp end-to-end (DAYDREAM_TEST_CLI not set)")
        }
        print("ai-read-typed: \(count) checks passed")
    }
}
