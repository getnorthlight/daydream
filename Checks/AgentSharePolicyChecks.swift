import Foundation
import MemoryCore

/// agent-tools v2, WP-A (owner decisions 10/04): the one share policy for AI apps.
/// - `shareable` redacts every secret class the owner named and keeps ordinary writing word for word (a table of
///   secrets and a table of near-misses), is idempotent, and shares nothing while typed words are off.
/// - `status` lines come from the same value; the setup check (`assistantReadiness`) and the app's bridge agree with them.
/// - The bridge: `policy`, `words` (400 ids, a byte budget, `more`), `search` v2 (every row, total, the wall clock), the
///   setting off, DayDream closed, typing locked, a key that doesn't verify.
/// - The local-owner preview gate: only the owner's own `mac-mem agent-preview --owner-preview`, never `mcp`, never with a
///   grant, never with the setting off.
/// - A source check: no agent-facing file opens typed words outside the policy.
/// Synthetic words only; every secret below is made up (and assembled at run time so no file holds a token shape).
/// Prints labels only, never typed text.
func runAgentSharePolicyChecks(home: URL) throws {
    try runAgentRedactionChecks()
    try runAgentStatusLineChecks()
    try runAgentBridgeChecks(home: home.appendingPathComponent("bridge"))
    try runAgentOwnerPreviewChecks(home: home.appendingPathComponent("owner"))
    try runAgentShareSourceChecks()
}

// MARK: - Redaction

private struct Secret { let label: String; let input: String; let gone: [String]; let kept: [String] }

private func runAgentRedactionChecks() throws {
    let on = AgentSharePolicy(typedWords: true)
    let ghp = "gh" + "p_" + String(repeating: "Q7x", count: 12)
    let openai = "sk-" + "proj-" + String(repeating: "Zt4qW9", count: 6)
    let legacyKey = "sk-" + String(repeating: "aB3dE5", count: 6)
    let aws = "AK" + "IA" + "QZ7XW2VY4TR8PL3M"
    let stripe = "sk_" + "live_" + String(repeating: "9Kx2", count: 6)
    let slack = "xo" + "xb-" + "1234567890-" + String(repeating: "aZ9", count: 6)
    func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
    let jwt = b64("{\"alg\":\"HS256\",\"typ\":\"JWT\"}") + "." + b64("{\"sub\":\"fixture-zebraquilt\"}") + "." + String(repeating: "sG7k", count: 8)
    let pem = "-----BEGIN " + "OPENSSH PRIVATE KEY-----\n" + String(repeating: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo", count: 2) + "\n-----END " + "OPENSSH PRIVATE KEY-----"

    // Each secret class the owner named: the secret is gone, the words around it stay.
    let secrets: [Secret] = [
        // One-time and 2FA codes.
        Secret(label: "verification code", input: "Your verification code is 482913 for zebraquilt", gone: ["482913"], kept: ["zebraquilt", "verification code"]),
        Secret(label: "sign-in code", input: "use code 739104 to sign in to zebraquilt", gone: ["739104"], kept: ["sign in", "zebraquilt"]),
        Secret(label: "2FA code split 3-3", input: "2FA code: 551 204 for the zebraquilt login", gone: ["551 204"], kept: ["zebraquilt"]),
        Secret(label: "a code read off a phone", input: "it's 482913", gone: ["482913"], kept: ["it's"]),
        // API keys and tokens.
        Secret(label: "GitHub token", input: "deploy zebraquilt with \(ghp) today", gone: [ghp, "Q7xQ7x"], kept: ["deploy zebraquilt with", "today"]),
        Secret(label: "OpenAI project key", input: "set the key to \(openai) for zebraquilt", gone: [openai, "Zt4qW9"], kept: ["zebraquilt"]),
        Secret(label: "sk- key", input: "zebraquilt uses \(legacyKey) now", gone: [legacyKey, "aB3dE5"], kept: ["zebraquilt uses", "now"]),
        Secret(label: "AWS access key id", input: "aws id \(aws) for the zebraquilt bucket", gone: [aws, "QZ7XW2"], kept: ["zebraquilt bucket"]),
        Secret(label: "Stripe live key", input: "billing \(stripe) zebraquilt", gone: [stripe, "9Kx2"], kept: ["billing", "zebraquilt"]),
        Secret(label: "Slack bot token", input: "bot token \(slack) zebraquilt", gone: [slack, "aZ9aZ9"], kept: ["zebraquilt"]),
        Secret(label: "JWT", input: "the header was \(jwt) for zebraquilt", gone: [jwt, "sG7ksG7k"], kept: ["the header was", "zebraquilt"]),
        Secret(label: "bearer token", input: "Authorization: Bearer 9fKq2LmZ8vXw4TbN7pRs zebraquilt", gone: ["9fKq2LmZ8vXw4TbN7pRs"], kept: []),
        Secret(label: "token pair outside a web address", input: "append &sig=AbCdEf123456 to the zebraquilt call", gone: ["AbCdEf123456"], kept: ["zebraquilt call"]),
        Secret(label: "high-entropy key", input: "the key is 9fKq2LmZ8vXw4TbN7pRs for zebraquilt", gone: ["9fKq2LmZ8vXw4TbN7pRs"], kept: ["zebraquilt"]),
        // Passwords.
        Secret(label: "password label", input: "the wifi password is Summer-Kite-2024. zebraquilt", gone: ["Summer-Kite-2024", "Kite"], kept: ["zebraquilt"]),
        Secret(label: "password assignment", input: "password: hunter2zz then zebraquilt", gone: ["hunter2zz"], kept: ["zebraquilt"]),
        Secret(label: "password with symbols", input: "pw=Tr0ub4dor&3 for zebraquilt", gone: ["Tr0ub4dor"], kept: ["zebraquilt"]),
        Secret(label: "password-like word, no label", input: "new one is Summer2024! ok zebraquilt", gone: ["Summer2024"], kept: ["new one is", "zebraquilt"]),
        // Card numbers (Luhn-valid test numbers).
        Secret(label: "card number", input: "card 4111 1111 1111 1111 exp 08/29 cvv 123 zebraquilt", gone: ["4111 1111", "1111 1111", "08/29", "cvv 123"], kept: ["zebraquilt"]),
        Secret(label: "card number unspaced", input: "pay with 5555555555554444 for zebraquilt", gone: ["5555555555554444"], kept: ["zebraquilt"]),
        // Government IDs and bank accounts.
        Secret(label: "SSN", input: "my ssn is 123-45-6789 zebraquilt", gone: ["123-45-6789"], kept: ["zebraquilt"]),
        Secret(label: "passport number", input: "passport number X12345678 expires next year zebraquilt", gone: ["X12345678"], kept: ["passport number", "expires next year", "zebraquilt"]),
        Secret(label: "driver's license", input: "driver's license D1234567 renewed zebraquilt", gone: ["D1234567"], kept: ["renewed zebraquilt"]),
        Secret(label: "UK National Insurance", input: "my NI number is AB 12 34 56 C zebraquilt", gone: ["AB 12 34 56 C", "34 56"], kept: ["zebraquilt"]),
        Secret(label: "UK National Insurance unspaced", input: "AB123456C is on the zebraquilt form", gone: ["AB123456C"], kept: ["zebraquilt form"]),
        Secret(label: "IBAN grouped", input: "IBAN GB82 WEST 1234 5698 7654 32 zebraquilt", gone: ["GB82", "WEST 1234", "7654 32"], kept: ["zebraquilt"]),
        Secret(label: "IBAN compact", input: "pay GB82WEST12345698765432 by Friday zebraquilt", gone: ["GB82WEST12345698765432", "WEST1234"], kept: ["by Friday zebraquilt"]),
        Secret(label: "labelled tax id", input: "tax id 12-3456789 for zebraquilt", gone: ["3456789"], kept: ["zebraquilt"]),
        Secret(label: "NHS number", input: "NHS number 943 476 5919 zebraquilt", gone: ["943 476 5919", "476"], kept: ["zebraquilt"]),
        // Credentials in web addresses; query strings stripped.
        Secret(label: "login in a web address", input: "clone https://deploybot:s3cretPass@git.example.com/team/repo.git now zebraquilt",
               gone: ["s3cretPass", "deploybot"], kept: ["https://git.example.com/team/repo.git now zebraquilt"]),
        Secret(label: "query string and fragment", input: "reset at https://example.com/reset?token=abc123XYZ&user=fixture#step2 zebraquilt",
               gone: ["abc123XYZ", "user=fixture", "?", "#step2"], kept: ["reset at https://example.com/reset zebraquilt"]),
        Secret(label: "query string without a scheme", input: "go to example.com/login?session=zzTOPsecret9 please, zebraquilt",
               gone: ["zzTOPsecret9", "session="], kept: ["go to example.com/login please, zebraquilt"]),
        Secret(label: "query string ending a sentence", input: "see www.example.com/a?ref=zebra1&utm_source=mail.", gone: ["ref=zebra1", "utm_source"], kept: ["see www.example.com/a."]),
        Secret(label: "login without a scheme", input: "upload to admin:Opensesame42@files.example.com today zebraquilt", gone: ["Opensesame42", "admin:"], kept: ["files.example.com today zebraquilt"]),
        // The eval fixture's mixed text (plan E11): five secrets in one unit, the words between them kept.
        Secret(label: "five secrets in one text", input: "zebraquilt notes: key \(legacyKey), the code is 482913, card 4111 1111 1111 1111, repo https://u:p@host.example.com/x and \(jwt) done",
               gone: [legacyKey, "482913", "4111", "u:p@", ":p@", jwt], kept: ["zebraquilt notes", "https://host.example.com/x", "done"]),
    ]
    for s in secrets {
        let out = on.shareable(s.input)
        try check(out != nil && s.gone.allSatisfy { !out!.contains($0) }, "agent share redaction: \(s.label) is withheld")
        try check(out.map { o in s.kept.allSatisfy { o.contains($0) } } == true, "agent share redaction: \(s.label), the words around it stay")
    }

    // Whole units that are only a secret share nothing.
    for (label, input) in [("private key", "key: " + pem + " zebraquilt"), ("a lone one-time code", "482913"), ("a lone Google code", "G-482913"),
                           ("a lone token", ghp), ("only secrets", "\(ghp) \(aws)")] {
        try check(on.shareable(input) == nil, "agent share redaction: \(label) shares nothing")
    }

    // Near-misses: ordinary writing comes back word for word.
    let ordinary = [
        "Can we move the standup to 10:30am tomorrow?",
        "The invoice total is $1,240.50 for 12 hours",
        "Call me at (415) 555-0134 after lunch",
        "Order 123456 shipped on 2026-10-02, tracking soon",
        "Meet in room 1204 at 3pm",
        "Back in 2026 we shipped v2.3.1 of the app",
        "zip code 94110 is right",
        "The code review is at 3pm",
        "COVID-19 rules changed in 2021",
        "Ask Sam about the Q3 plan",
        "Read https://example.com/docs/intro first",
        "Did you see example.com?",
        "Wouldn't it be easier to use McDonald's Wi-Fi?",
        "Our Co-Founder emailed the U.S. team",
        "Write to sam@example.com about it",
        "Passport photos are due Friday",
        "My passport expires 2027-05-01",
        "Card ending 4242 was declined",
        "Flight UA 1234 leaves at 6:45pm",
        "Try GPT-4o-mini and Claude-3.5 on the #launch notes",
        "Q3_plan.pdf is in the shared folder",
        "Version 1.2.3 fixed the login page bug",
        "Security review is on Tuesday",
        "Use 2-factor auth for the new account",
        "The tax ID form is due next week",
        "We sold 1,500,000 units last year",
        "Meet at 12:00pm-1:00pm in the lobby",
        "Sorry, I'm 5 mins late!",
        "Our NPS went from 42 to 57",
        "The iPhone 15 Pro case is blue",
        "Ticket #48213 is closed",
        "Is it done? Really?",
    ]
    for text in ordinary {
        try check(on.shareable(text) == text, "agent share near-miss kept word for word: \(text.prefix(24))…")
    }

    // Idempotent, one function for every path, nothing while off.
    let all = secrets.map(\.input) + ordinary
    try check(all.allSatisfy { x in on.shareable(x).map { on.shareable($0) == $0 } ?? true }, "agent share: redacting a result again changes nothing (\(all.count) inputs)")
    try check(all.allSatisfy { AssistantTypedText.shareable($0) == on.shareable($0) }, "agent share: the 0.1.4 path is the same function (AssistantTypedText.shareable)")
    for off in [AgentSharePolicy.TypedWordsOff.settingOff, .appClosed, .locked] {
        try check(all.allSatisfy { AgentSharePolicy(typedWords: false, typedWordsOff: off).shareable($0) == nil }, "agent share: typed words \(off.rawValue): nothing is shared")
    }
    try check(on.shareable("plain zebraquilt words", secure: true) == nil && on.shareable("plain zebraquilt words", secure: false) == "plain zebraquilt words",
              "agent share: a secure-field row shares nothing")
    try check(on.redactions == AgentSharePolicy.Redaction.allCases && on.sendStateShown == false, "agent share: every redaction applies; send state never shown")
    let long = String(repeating: "zebraquilt words ", count: 200)
    try check((on.shareable(long)?.count ?? 0) == AssistantTypedText.maxCharacters && on.shareable(long)?.hasSuffix("\u{2026}") == true,
              "agent share: one typed text is bounded")
}

// MARK: - Status lines

private func runAgentStatusLineChecks() throws {
    let on = AgentSharePolicy(typedWords: true)
    let line = on.statusLines()
    try check(line.count == 2 && line[0] == on.typedWordsLine && AgentSharePolicy.Redaction.allCases.allSatisfy { line[0].contains($0.plain) },
              "agent status: the typed-words line names every redaction the policy applies")
    try check(line[1] == AgentSharePolicy.sendStateLine && line[1].contains("went out") && line[1].hasPrefix("Never shown")
              && !["draft", "sent", "delivered", "read"].contains { line[1].range(of: "\\b\($0)\\b", options: [.regularExpression, .caseInsensitive]) != nil }, "agent status: send states are never shown, and status says so")
    let cases: [(AgentBridgePolicy, AgentSharePolicy.TypedWordsOff?, String)] = [
        (.unreachable, .appClosed, "Typed words: unavailable while DayDream is closed."),
        (AgentBridgePolicy(reachable: true, typedWords: false, vault: .ready), .settingOff, "Typed words: off (Settings › Connections)."),
        (AgentBridgePolicy(reachable: true, typedWords: true, vault: .locked), .locked, "Typed words: unavailable until typing is unlocked in DayDream."),
        (AgentBridgePolicy(reachable: true, typedWords: true, vault: .unavailable), .locked, "Typed words: unavailable until typing is unlocked in DayDream."),
        (AgentBridgePolicy(reachable: true, typedWords: true, vault: .ready), nil, on.typedWordsLine),
    ]
    for (answer, off, expected) in cases {
        let p = AgentSharePolicy.current(bridge: AgentNoTypedSource(answer))
        try check(p.typedWords == (off == nil) && p.typedWordsOff == off && p.statusLines().first == expected,
                  "agent status: bridge answer \(answer.reachable ? (answer.typedWords ? answer.vault.rawValue : "setting off") : "none") reads \(off?.rawValue ?? "on")")
    }
    let banned = ["a few words", "not shared", "never the words", "exact words"]
    for p in cases.map({ AgentSharePolicy.current(bridge: AgentNoTypedSource($0.0)) }) {
        let text = p.statusLines().joined(separator: " ").lowercased()
        try check(!banned.contains { text.contains($0) } && text.range(of: #"typed \d+ words"#, options: .regularExpression) == nil,
                  "agent status (\(p.typedWordsOff?.rawValue ?? "on")): no word-count or 'not shared' wording")
    }
    try check(AIReadsTypedSetting.line == "AI apps you connect can see what you type, minus passwords and codes." && AIReadsTypedSetting.defaultValue,
              "setup sentence (owner 10/04), typed words on by default")
    try check(AgentBridgeError.unavailable(.appClosed).description == AgentSharePolicy(typedWords: false, typedWordsOff: .appClosed).typedWordsLine,
              "agent status: a reply's 'unavailable' line is the policy's own line")
}

// MARK: - The bridge

private func typedRow(_ id: String, _ text: String, at: Date) -> Evidence {
    Evidence(id: id, at: iso(at), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes", title: "Plans", text: text, synthetic: true)
}

private func runAgentBridgeChecks(home: URL) throws {
    let now = Date()
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try store.updatePolicy(policy, now: now)
    let keys = try attachTestVault(store)
    let base = now.addingTimeInterval(-3600)
    var ids: [String] = [], sealed = 0
    for i in 0..<450 {
        let id = "ash-\(i)"
        if try store.ingest(typedRow(id, "zebraquilt row \(i) see https://example.com/r?page=\(i)&ref=mail", at: base.addingTimeInterval(Double(i))), now: now) { sealed += 1 }
        ids.append(id)
    }
    try check(sealed == 450, "bridge fixture: 450 typed rows sealed")
    _ = try store.ingest(typedRow("ash-old", "zebraquilt older entry", at: now.addingTimeInterval(-3 * 86400)), now: now)
    let capability = try store.grant(client: "fixture-host", recipient: "fixture-local", scopes: MemoryStore.assistantScopes)
    let reader = TypedReader(client: "fixture-host", recipient: "fixture-local", capability: capability)
    func ask(_ o: [String: Any], enabled: Bool = true) -> [String: Any] {
        store.assistantBridgeAnswer(o.merging(["client": reader.client, "recipient": reader.recipient, "capability": reader.capability]) { $1 }, enabled: enabled)
    }

    // words: 400 per request, the rest named in `more`; every word through the policy.
    let first = ask(["op": "words", "ids": ids])
    let firstWords = first["words"] as? [String: String] ?? [:]
    try check(first["status"] as? String == "ok" && firstWords.count == 400 && (first["more"] as? [String])?.count == 50, "bridge words: 400 per request, 50 left in more")
    try check(firstWords.values.allSatisfy { $0.contains("zebraquilt") && $0.contains("https://example.com/r") && !$0.contains("ref=") && !$0.contains("?") },
              "bridge words: every word went through the policy (the query string is gone)")
    try check(ask(["op": "words", "ids": ids], enabled: false)["status"] as? String == "off", "bridge words: setting off answers off")
    try check(store.assistantBridgeAnswer(["op": "words", "ids": ids, "client": reader.client, "recipient": reader.recipient, "capability": "not-the-key"], enabled: true)["status"] as? String == "denied",
              "bridge words: a key that doesn't verify is denied")
    try check(ask(["op": "nonsense"])["status"] as? String == "error", "bridge: an unknown op is an error")

    // The reply budget: long words come back over several requests, never past the socket's limit.
    let longText = String(repeating: "zebraquilt long words ", count: 75)
    var longIDs: [String] = []
    for i in 0..<300 {
        let id = "ash-long-\(i)"; longIDs.append(id)
        _ = try store.ingest(typedRow(id, longText + "\(i)", at: base.addingTimeInterval(1000 + Double(i))), now: now)
    }
    let budgeted = ask(["op": "words", "ids": longIDs])
    let bytes = (try? JSONSerialization.data(withJSONObject: budgeted).count) ?? .max
    try check(budgeted["status"] as? String == "ok" && !(budgeted["more"] as? [String] ?? []).isEmpty && bytes < 1_000_000,
              "bridge words: a reply stays under the socket limit and names the rest (\(bytes / 1000) KB)")

    // search v2: every row, the true total, the limit, a range, the wall clock.
    let all = try store.assistantTypedSearch("zebraquilt row", start: nil, end: nil, limit: 20, reader: reader, enabled: true, now: now)
    try check(all.total == 450 && all.hits.count == 20 && all.complete && all.oldestScanned == nil, "bridge search: total counts every match (450), 20 listed, complete")
    try check(all.hits.first?.id == "ash-449" && all.hits.allSatisfy { !$0.snippet.contains("ref=") }, "bridge search: newest first, snippets through the policy")
    let older = try store.assistantTypedSearch("zebraquilt older", start: nil, end: nil, limit: nil, reader: reader, enabled: true, now: now)
    try check(older.total == 1 && older.hits.first?.id == "ash-old", "bridge search: no 7-day window inside retention (a 3-day-old row is found)")
    let ranged = try store.assistantTypedSearch("zebraquilt row", start: base.addingTimeInterval(100), end: base.addingTimeInterval(200), limit: 500, reader: reader, enabled: true, now: now)
    try check(ranged.total == 100 && ranged.hits.count == 100, "bridge search: start..<end bounds the rows (100)")
    var ticks = 0.0
    let cut = try store.assistantTypedSearch("zebraquilt row", start: nil, end: nil, limit: 20, reader: reader, enabled: true, now: now, wall: 10,
                                             clock: { ticks += 1; return now.addingTimeInterval(ticks) })
    try check(!cut.complete && cut.oldestScanned != nil && cut.total < 450, "bridge search: the wall clock stops the scan and says how far back it got")
    let reply = ask(["op": "search", "query": "zebraquilt row", "limit": 5])
    try check(reply["status"] as? String == "ok" && (reply["hits"] as? [[String: String]])?.count == 5 && (reply["total"] as? Int) == 450 && reply["complete"] as? Bool == true,
              "bridge search op: hits, total, complete")
    let legacy = try store.assistantTypedSearch("zebraquilt row", reader: reader, enabled: true, now: now)
    try check(legacy.count == 20 && legacy.allSatisfy { $0["id"] != nil && $0["at"] != nil && $0["snippet"] != nil }, "bridge search: the 0.1.4 form still answers")

    // In-process source (WP-D's fixture path): the same answers and errors.
    let local = AgentStoreTypedSource(store: store, reader: reader, enabled: true, now: now)
    try check(AgentSharePolicy.current(bridge: local).typedWords && (try local.words(["ash-1"]))["ash-1"]?.contains("zebraquilt") == true, "in-process source: policy on, words through the policy")
    var offError: AgentBridgeError?
    do { _ = try AgentStoreTypedSource(store: store, reader: reader, enabled: false).words(["ash-1"]) } catch let e as AgentBridgeError { offError = e }
    try check(offError == .unavailable(.settingOff), "in-process source: setting off throws unavailable(settingOff)")

    // Over the real socket, read by a keyless reader the way `mac-mem mcp` reads.
    var enabled = true
    let server = AssistantTypedBridgeServer(home: home) { request in store.assistantBridgeAnswer(request, enabled: enabled) }
    try check(server.start(), "bridge listens in the scratch home")
    defer { server.stop() }
    let client = AgentBridgeSource(home: home, client: reader.client, recipient: reader.recipient, capability: reader.capability)
    try check(client.policy() == AgentBridgePolicy(reachable: true, typedWords: true, vault: .ready), "bridge policy op: reachable, on, ready")
    let socketWords = try client.words(ids + ids.prefix(3) + ["", "ash-missing"])
    try check(socketWords.count == 450 && socketWords["ash-missing"] == nil, "bridge client: 450 ids over two requests, duplicates and unknown ids left out")
    let longWords = try client.words(longIDs)
    try check(longWords.count == 300 && longWords.values.allSatisfy { $0.hasPrefix("zebraquilt long words") }, "bridge client: long words over several requests within the budget")
    let found = try client.search("zebraquilt row", start: nil, end: nil, limit: 3)
    try check(found.total == 450 && found.hits.count == 3 && found.complete, "bridge client: search v2 total and hits")

    let reader2 = try MemoryStore(home: home)
    func readiness() throws -> [String: String] { try reader2.assistantReadiness(access: nil, now: now) }
    var status = try readiness()
    let live = AgentSharePolicy.current(bridge: client)
    try check(status["shared"] == live.statusLines().joined(separator: " ") && status["typing"]?.hasSuffix(live.typedWordsLine) == true && live.typedWords,
              "status agrees with the policy: on (asked over the bridge)")
    enabled = false
    status = try readiness()
    let offPolicy = AgentSharePolicy.current(bridge: client)
    try check(offPolicy.typedWordsOff == .settingOff && status["shared"] == offPolicy.statusLines().joined(separator: " ")
              && status["typing"]?.hasSuffix("Typed words: off (Settings › Connections).") == true, "status agrees with the policy: setting off")
    var thrown: AgentBridgeError?
    do { _ = try client.words(["ash-1"]) } catch let e as AgentBridgeError { thrown = e }
    try check(thrown == .unavailable(.settingOff), "bridge client: setting off throws unavailable(settingOff)")
    enabled = true
    keys.locked = true
    _ = try store.reconcileTypedVault(now: now)
    let lockedPolicy = AgentSharePolicy.current(bridge: client)
    thrown = nil
    do { _ = try client.words(["ash-1"]) } catch let e as AgentBridgeError { thrown = e }
    try check(lockedPolicy.typedWordsOff == .locked && thrown == .unavailable(.locked) && (try readiness())["shared"] == lockedPolicy.statusLines().joined(separator: " "),
              "typing locked: policy, words and status all say locked")
    keys.locked = false
    _ = try store.reconcileTypedVault(now: now)
    thrown = nil
    do { _ = try AgentBridgeSource(home: home, client: reader.client, recipient: reader.recipient, capability: "not-the-key").words(["ash-1"]) } catch let e as AgentBridgeError { thrown = e }
    try check(thrown == .denied, "bridge client: a key that doesn't verify throws denied")
    server.stop()
    let closed = AgentSharePolicy.current(bridge: client)
    thrown = nil
    do { _ = try client.search("zebraquilt", start: nil, end: nil, limit: nil) } catch let e as AgentBridgeError { thrown = e }
    try check(closed.typedWordsOff == .appClosed && thrown == .unavailable(.appClosed) && (try readiness())["shared"] == closed.statusLines().joined(separator: " "),
              "DayDream closed: policy, search and status all say closed")
}

// MARK: - The local-owner preview

private func runAgentOwnerPreviewChecks(home: URL) throws {
    // The gate, as a table: every condition is needed.
    let owner = AgentBridgeRequest(op: .words, ids: ["x"], ownerPreview: true)
    try check(AgentOwnerPreview.permits(owner, sameUser: true, fromMCPServer: false, typedWordsSetting: true), "owner preview: allowed when every condition holds")
    var granted = owner; granted.client = "fixture-host"
    var keyed = owner; keyed.capability = "a-key"
    var recipient = owner; recipient.recipient = "fixture-local"
    let refusals: [(String, Bool)] = [
        ("not asked for", AgentOwnerPreview.permits(AgentBridgeRequest(op: .words, ids: ["x"]), sameUser: true, fromMCPServer: false, typedWordsSetting: true)),
        ("another user", AgentOwnerPreview.permits(owner, sameUser: false, fromMCPServer: false, typedWordsSetting: true)),
        ("from mac-mem mcp", AgentOwnerPreview.permits(owner, sameUser: true, fromMCPServer: true, typedWordsSetting: true)),
        ("setting off", AgentOwnerPreview.permits(owner, sameUser: true, fromMCPServer: false, typedWordsSetting: false)),
        ("with a client", AgentOwnerPreview.permits(granted, sameUser: true, fromMCPServer: false, typedWordsSetting: true)),
        ("with a key", AgentOwnerPreview.permits(keyed, sameUser: true, fromMCPServer: false, typedWordsSetting: true)),
        ("with a recipient", AgentOwnerPreview.permits(recipient, sameUser: true, fromMCPServer: false, typedWordsSetting: true)),
    ]
    for (label, allowed) in refusals { try check(!allowed, "owner preview refused: \(label)") }
    try check(AgentBridgeRequest(bridge: owner.bridgeObject) == owner && AgentBridgeRequest(bridge: ["op": "words"])?.ownerPreview == false,
              "owner preview: the request flag survives the socket encoding, and is off unless sent")

    // Who the peer is: fails closed.
    try check(AgentBridgePeer.isMCPServer(arguments: ["/x/mac-mem", "--home", "/h", "--client", "c", "mcp"]) && !AgentBridgePeer.isMCPServer(arguments: ["/x/mac-mem", "--local", "agent-preview"]),
              "owner preview: a mac-mem mcp command line is recognised")
    try check(AgentBridgePeer.isOwnerPreviewCommand(executable: "/x/mac-mem", arguments: ["/x/mac-mem", "--local", "agent-preview", "--owner-preview", "status", "{}"])
              && !AgentBridgePeer.isOwnerPreviewCommand(executable: "/x/mac-mem", arguments: ["/x/mac-mem", "--local", "agent-preview", "status"])
              && !AgentBridgePeer.isOwnerPreviewCommand(executable: "/x/mac-mem", arguments: ["/x/mac-mem", "mcp", "agent-preview", "--owner-preview"])
              && !AgentBridgePeer.isOwnerPreviewCommand(executable: "/x/other", arguments: ["/x/other", "agent-preview", "--owner-preview"]),
              "owner preview: only mac-mem agent-preview with the explicit flag, never mcp")
    try check(AgentBridgePeer.fromMCPServer(pid: nil) && AgentBridgePeer.fromMCPServer(pid: getpid()) && AgentBridgePeer.fromMCPServer(pid: 1)
              && AgentBridgePeer.fromMCPServer(pid: 999_999), "owner preview: no pid, this checks process, another user's process and no process all fail closed")
    var pair: [Int32] = [0, 0]
    try check(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0, "owner preview: socket pair for the peer check")
    let peer = AgentBridgePeer.peerPID(pair[0])
    close(pair[0]); close(pair[1])
    try check(peer == getpid(), "owner preview: the socket peer's process id is read (LOCAL_PEERPID)")

    // End to end against a store: a stand-in process named mac-mem with the owner's command line.
    let now = Date()
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try store.updatePolicy(policy, now: now)
    try attachTestVault(store)
    _ = try store.ingest(typedRow("own-1", "zebraquilt owner preview words with \("sk-" + String(repeating: "aB3dE5", count: 6))", at: now.addingTimeInterval(-60)), now: now)
    let bin = home.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let fake = bin.appendingPathComponent("mac-mem")
    try? FileManager.default.removeItem(at: fake)
    // `tee` waits on its input and leaves its arguments as they are; after "--" each argument is just a file name in
    // the scratch folder. The stand-ins are this check's own processes and are stopped below.
    try FileManager.default.createSymbolicLink(at: fake, withDestinationURL: URL(fileURLWithPath: "/usr/bin/tee"))
    var inputs: [Pipe] = []
    func standIn(_ arguments: [String]) throws -> Process {
        let p = Process(); p.executableURL = fake; p.arguments = ["--"] + arguments; p.currentDirectoryURL = bin
        let input = Pipe(); inputs.append(input)
        p.standardInput = input; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); return p
    }
    let preview = try standIn(["--local", "agent-preview", "--owner-preview", "status"])
    let mcp = try standIn(["--home", "fixture", "mcp", "agent-preview", "--owner-preview"])
    let plain = try standIn(["--local", "agent-preview", "status"])
    defer { for p in [preview, mcp, plain] where p.isRunning { p.terminate(); p.waitUntilExit() } }
    usleep(100_000)
    func ask(pid: pid_t, enabled: Bool = true, extra: [String: Any] = [:]) -> [String: Any] {
        store.assistantBridgeAnswer(["op": "words", "ids": ["own-1"], "owner": true, "pid": Int(pid)].merging(extra) { $1 }, enabled: enabled)
    }
    let allowed = ask(pid: preview.processIdentifier)
    let words = (allowed["words"] as? [String: String])?["own-1"]
    try check(allowed["status"] as? String == "ok" && words?.contains("zebraquilt owner preview words") == true && words?.contains("aB3dE5") == false,
              "owner preview: the owner's own command reads their words, still through the policy")
    try check(ask(pid: preview.processIdentifier, enabled: false)["status"] as? String == "denied", "owner preview: refused with the setting off")
    try check(ask(pid: mcp.processIdentifier)["status"] as? String == "denied", "owner preview: refused from a mac-mem mcp command")
    try check(ask(pid: plain.processIdentifier)["status"] as? String == "denied", "owner preview: refused without the explicit flag")
    try check(ask(pid: preview.processIdentifier, extra: ["client": "fixture-host"])["status"] as? String == "denied", "owner preview: refused with a grant field")
    try check(ask(pid: getpid())["status"] as? String == "denied", "owner preview: refused for any other process")
    try check(store.assistantBridgeAnswer(["op": "words", "ids": ["own-1"], "owner": true, "pid": Int(getpid())], enabled: true, peerPID: preview.processIdentifier)["status"] as? String == "ok"
              && store.assistantBridgeAnswer(["op": "words", "ids": ["own-1"], "owner": true, "pid": Int(preview.processIdentifier)], enabled: true, peerPID: getpid())["status"] as? String == "denied",
              "owner preview: the server's peer pid wins over the pid a request claims")
    let search = store.assistantBridgeAnswer(["op": "search", "query": "zebraquilt", "owner": true, "pid": Int(preview.processIdentifier)], enabled: true)
    try check(search["status"] as? String == "ok" && (search["total"] as? Int) == 1, "owner preview: search too")
    try check(store.assistantBridgeAnswer(["op": "policy", "owner": true], enabled: false)["typedWords"] as? Bool == false, "owner preview: policy answers without the gate (no words in it)")

    // The client never asks for an owner preview with a grant, and this process (not mac-mem) is refused by the app.
    let seenPID = NSLock()
    var seen: [Any?] = []
    let server = AssistantTypedBridgeServer(home: home) { request in
        seenPID.lock(); seen.append(request["pid"]); seenPID.unlock()
        return store.assistantBridgeAnswer(request, enabled: true)
    }
    try check(server.start(), "owner preview: bridge listens in the scratch home")
    defer { server.stop() }
    // Integrator: the server overwrites a client-written pid with the kernel's peer pid (this checks process here), so
    // a request claiming the owner's preview process is still refused.
    let forged = AssistantTypedBridge.call(home: home, ["op": "words", "ids": ["own-1"], "owner": true, "pid": Int(preview.processIdentifier)])
    seenPID.lock(); let claimed = seen.last.flatMap { $0 as? Int }; seenPID.unlock()
    try check(forged?["status"] as? String == "denied" && claimed == Int(getpid()),
              "owner preview: the bridge server replaces a request's pid with the kernel peer pid (a forged preview pid is refused)")
    var refused: AgentBridgeError?
    do { _ = try AgentBridgeSource(home: home, ownerPreview: true).words(["own-1"]) } catch let e as AgentBridgeError { refused = e }
    try check(refused == .denied, "owner preview: a process that isn't the owner's mac-mem command is refused over the socket")
    refused = nil
    do { _ = try AgentBridgeSource(home: home, client: "fixture-host", recipient: "fixture-local", capability: "not-a-key", ownerPreview: true).words(["own-1"]) }
    catch let e as AgentBridgeError { refused = e }
    try check(refused == .denied, "owner preview: with grant fields the client sends a normal request (denied for a bad key), never the preview")
}

// MARK: - Source check: no agent-facing code opens typed words outside the policy

private func runAgentShareSourceChecks() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let sources = root.appendingPathComponent("Sources")
    guard FileManager.default.fileExists(atPath: sources.appendingPathComponent("MemoryCore/AgentShare/AgentShareModel.swift").path) else {
        throw MemError.invalid("FAILED: agent share source check: run MacMemChecks from the worktree root")
    }
    /// The file without comment lines and trailing `// ` comments (doc text may name the functions).
    func code(_ path: String) throws -> String {
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("//") { return "" }
            if let r = line.range(of: " // ") { return String(line[..<r.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }
    func count(_ pattern: String, in text: String) -> Int {
        (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) ?? 0
    }
    var swiftFiles: [String] = []
    if let walk = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) {
        for case let url as URL in walk where url.pathExtension == "swift" { swiftFiles.append(String(url.path.dropFirst(root.path.count + 1))) }
    }
    // 1. The AI-app disclosure is opened in exactly one place: `agentTypedText`, which applies the policy.
    var assistantOpens: [String: Int] = [:]
    for f in swiftFiles {
        let n = count(#"disclosure\s*:\s*\.assistant\b"#, in: try code(f))
        if n > 0 { assistantOpens[f] = n }
    }
    let readFile = "Sources/MemoryCore/AssistantTypedRead.swift"
    try check(assistantOpens == [readFile: 1], "agent share source: the AI-app disclosure opens only in agentTypedText (\(assistantOpens.keys.sorted()))")
    let read = try code(readFile)
    if let fn = read.range(of: "func agentTypedText(") {
        let body = String(read[fn.lowerBound...].prefix(900))
        try check(body.contains("disclosure: .assistant") && body.contains("policy.shareable(raw, secure:"), "agent share source: agentTypedText applies the policy to what it opens")
    } else { try check(false, "agent share source: agentTypedText exists") }

    // 2. Agent-facing files open no typed words themselves. The one 0.1.4 exception: `read`'s exact-words grant in
    //    AssistantView (never words in the MCP process, which has no key); it leaves with the legacy tools in 0.1.6.
    let agentFacing = swiftFiles.filter { $0.hasPrefix("Sources/MemoryCore/AgentShare/") } + [
        readFile, "Sources/MemoryCore/AssistantTypedBridge.swift", "Sources/MemoryCore/AssistantReadiness.swift",
        "Sources/MemoryCore/AssistantCatalog.swift", "Sources/MemoryCore/AssistantView.swift", "Sources/MacMemCLI/main.swift",
    ]
    let legacyExact = ["Sources/MemoryCore/AssistantView.swift": 1]
    for f in agentFacing where FileManager.default.fileExists(atPath: root.appendingPathComponent(f).path) {
        let text = try code(f)
        let opens = count(#"hydrateTypedText\s*\("#, in: text) - (text.contains("public func hydrateTypedText") ? 1 : 0)
        let allowed = f == readFile ? 1 : legacyExact[f] ?? 0
        try check(opens == allowed, "agent share source: \(f) opens typed words only through the policy (\(opens) of \(allowed) allowed)")
        if f == "Sources/MemoryCore/AssistantView.swift" {
            try check(count(#"hydrateTypedText\s*\([^)]*disclosure\s*:\s*\.exact"#, in: text) == 1, "agent share source: AssistantView's one legacy open is the exact-words grant")
        }
    }
    // 3. The v2 tool files reach typed words only through an `AgentTypedSource` (never the scrubber, the store's rows,
    //    the vault or the socket directly); only the policy file redacts and only the bridge client talks to the socket.
    for f in swiftFiles where f.hasPrefix("Sources/MemoryCore/AgentShare/") {
        let text = try code(f)
        let name = (f as NSString).lastPathComponent
        var banned = ["hydrateTypedText", "typed_text", "attachedVault", "vault.open", "AssistantTypedText.", "typedAfter("]
        if name != "AgentSharePolicy.swift" { banned.append("TypedSecretScrubber.") }
        if name != "AgentBridgeSource.swift" { banned += ["AssistantTypedBridge.call", "assistantTypedWords", "assistantTypedSearch", "assistantBridgeAnswer"] }
        let hits = banned.filter { text.contains($0) }
        try check(hits.isEmpty, "agent share source: \(name) reads typed words only through the policy and a typed source \(hits)")
    }
}
