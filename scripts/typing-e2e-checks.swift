import Foundation
@testable import MemoryCore
import PrivacyPolicy
import CoreIntegration
import WriterBackend

/// fix/typing-e2e: typing is really on, and what is typed reaches both writers, for a fresh install and for an
/// upgrade from test 4 and test 5 (the owner's case). Each case applies what setup (or what's-new) does on Continue,
/// then types through the real capture paths (CoreCaptureBinding for apps, the website typing session and
/// `WebTypedRow` for Chrome), then builds the local and cloud writers' views (CoreWriterBinding, ModelView) of the
/// Messages, Mail, X, Claude, ChatGPT and Slack moments and checks each names who it went to and how it starts.
/// Compiled from TypingModel.swift, the capture files and the owner flags (runner step typing-e2e). Synthetic stores
/// under TMPDIR, in-memory typing keys, a scratch defaults suite: no Keychain, no app launch, no capture, no model.
///
/// `-D TYPING_E2E_OLD` compiles the same checks against 5c76a6f's objects (the proof that they fail there): the few
/// names that build lacks are stood in for below by what it did instead.
@main struct TypingE2EChecks {
    static var passed = 0, failed = 0
    static var failures: [String] = []
    static func check(_ value: Bool, _ label: String) {
        if value { passed += 1; print("PASS " + label) } else { failed += 1; failures.append(label); print("FAIL " + label) }
    }
    static var evidence: [String] = []

    enum Case: String, CaseIterable { case fresh = "FRESH", upgradeT4 = "UPGRADE_T4", upgradeT5 = "UPGRADE_T5" }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("typing-e2e-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "typing-e2e-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        conversationChecks()
        Web.titleChecks()
        for c in Case.allCases { try await run(c, root: root, defaults: defaults) }
        try negativeChecks(root: root)

        if let out = ProcessInfo.processInfo.environment["TYPING_E2E_EVIDENCE"], !out.isEmpty {
            try evidence.joined(separator: "\n").appending("\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
        print("typing-e2e: \(passed) passed, \(failed) failed")
        if failed > 0 { print("FAILED: " + failures.joined(separator: " | ")); exit(1) }
    }

    // MARK: Messages: who a conversation is with when the window title doesn't say

    @MainActor static func conversationChecks() {
        Conversation.fake(rows: ["Riley", "can you send me the flight times", "Yesterday"])
        check(Conversation.place(title: "Messages", bundle: "com.apple.MobileSMS") == "Messages",
              "generic Messages title never borrows a selected conversation or preview")
        check(Conversation.place(title: "Q7", bundle: "com.apple.MobileSMS") == "Q7", "Messages titled with the conversation: the title (Q7)")
        Conversation.fake(rows: ["+1 (415) 555-0100", "see you there"])
        check(Conversation.place(title: "Messages", bundle: "com.apple.MobileSMS") == "Messages",
              "a conversation named by a phone number is never saved as who (the title stays)")
        Conversation.fake(rows: ["sam@example.com"])
        check(Conversation.place(title: "Messages", bundle: "com.apple.MobileSMS") == "Messages", "nor one named by an email address")
        Conversation.fake(rows: ["Riley"])
        check(Conversation.place(title: "Notes", bundle: "com.apple.Notes") == "Notes", "other app window titles are retained")
    }

    // MARK: One case

    @MainActor static func run(_ c: Case, root: URL, defaults: UserDefaults) async throws {
        let tag = "[\(c.rawValue)] "
        let home = root.appendingPathComponent(c.rawValue)
        let keys = InMemoryTypedKeyStore()
        let base = Date().addingTimeInterval(-3 * 3600)
        var preUpgradeRow: String?
        // The store as the earlier build left it (sx-diag-setup-upgrade/harness/store-states.swift).
        do {
            let old = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
            switch c {
            case .fresh: break
            case .upgradeT4:
                // Test 4's setup saved typing at its Off default; the save deleted the first-choice marker. Consent 0.
                let p = try old.policy()
                _ = try old.savePreferences(prefs(p.blockedApps, typing: false), expectedRevision: p.revision)
            case .upgradeT5:
                // Test 5: typing turned on (consent v2) for test 5's narrower places, and a draft typed then.
                let p = try old.policy()
                _ = try old.savePreferences(prefs(p.blockedApps, typing: true, shown: true), expectedRevision: p.revision)
                try old.attachVault(TypedTextVault(keyStore: keys))
                try old.acceptSafeTyping(now: base.addingTimeInterval(-86_400))
                try old.setUpTypedVault(now: base.addingTimeInterval(-86_400))
                try old.setCaptureState("recording", reason: "synthetic fixture")
                let binding = CoreCaptureBinding(store: old)
                var mono: UInt64 = 5_000_000_000
                let id = "t5-notes-draft"
                check(try unit(binding, &mono, id: id, bundle: "com.apple.Notes", place: "Trip plan", window: "n1", focus: "n1f",
                               text: "book the lisbon hotel near the old town", reason: .idle, wall: Date()),
                      tag + "setup: a Notes draft typed under test 5")
                preUpgradeRow = id
                try old.setCaptureState("off", reason: "synthetic fixture")
                try old.acceptSafeTyping(now: base.addingTimeInterval(-86_000), scope: TypedConsentScope(apps: ["com.apple.Notes", "com.apple.TextEdit", "com.apple.Terminal"], websites: false))
            }
            defaults.set(c != .fresh, forKey: "DaydreamOnboardingCompletedV1")
        }
        // The candidate's launch: reopen, the legacy settle, the vault with the same keys.
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        _ = try store.settleLegacyPreferences()
        try store.attachVault(TypedTextVault(keyStore: keys))
        if let id = preUpgradeRow {
            // (L2) Reading is not capture: rows kept under a narrower consent stay readable by the writers.
            check(try store.typedTextPolicy().scopeWidened, tag + "the upgrade finds test 5's consent narrower than this build")
            check(try store.hydrateTypedText(id, disclosure: .localWriter) == "book the lisbon hotel near the old town",
                  tag + "localWriter reads words after upgrade")
            try store.setSummaryWriter("cloud")
            check(try store.hydrateTypedText(id, disclosure: .cloudWriter) == "book the lisbon hotel near the old town",
                  tag + "cloudWriter (Cloud chosen) reads words after upgrade")
            try store.setSummaryWriter("local")
        }
        // What setup and what's-new show: every switch on unless the person turned it off.
        let seeds = try store.setupChoices()
        check(seeds.typingSeed && seeds.chromePagesSeed && seeds.messagesSeed, tag + "setup seeds typing, Web pages in Chrome and Messages on")

        // Continue.
        let model = TypingModel(now: { base })
        let ok = try continueSetup(store, model: model)
        let policy = try store.policy(), typed = try store.typedTextPolicy()
        check(ok, tag + "Continue turns typing on (no sheet, no second question)")
        check(policy.captureText && policy.typedConsentVersion == 1, tag + "the typing switch is saved on (captureText, consent version 1)")
        check(typed.consented && typed.acceptedScope == .current && !typed.scopeWidened, tag + "consent covers everything this build records")
        check(TypingCategory.allCases.allSatisfy { typed.categories.isOn($0) } && typed.categories.otherWebsites, tag + "every category is on, Messages and email too")
        let excluded = TypingCategories.excludedBundles(on: typed.categories.isOn)
        for bundle in ["com.apple.MobileSMS", "com.apple.mail", "com.openai.codex", "com.openai.chat", "com.anthropic.claudefordesktop"] {
            check(!excluded.contains(bundle), tag + "\(bundle) is not excluded")
        }
        check(policy.browserPagesOn, tag + "Web pages in Chrome is on")
        // An unrelated Settings save (an app excluded) changes no explicit choice.
        let choices = try store.setupChoices()
        let current = try store.policy()
        _ = try store.savePreferences(prefs(current.blockedApps + ["com.example.synthetic-excluded"], typing: current.captureText), expectedRevision: current.revision)
        check(try store.setupChoices() == choices && store.setupChoices().typingSeed, tag + "an unrelated save (an app excluded) keeps the explicit choices")

        // Type.
        try store.setCaptureState("recording", reason: "synthetic fixture")
        let session = try CaptureSession(store: store)
        try session.start(permitted: true)
        let binding = CoreCaptureBinding(store: store)
        var mono: UInt64 = 10_000_000_000
        // The store takes typed rows only while the recorder's heartbeat is fresh (5 s), at the time they are typed.
        func next() -> Date { try? session.start(permitted: true); return Date() }
        var refused: [String] = []
        func accept(_ ok: Bool, _ name: String) { if !ok { refused.append(name) }; check(ok, tag + name + " typed row accepted") }
        Conversation.fake(rows: ["Riley", "can you send me the lisbon flight times", "Yesterday"])
        let rilleyPlace = Conversation.place(title: "Messages", bundle: "com.apple.MobileSMS") ?? "Messages"
        accept(try unit(binding, &mono, id: "m5", bundle: "com.apple.MobileSMS", place: "Q7", window: "m1", focus: "m1f",
                        text: "are we still on for dinner friday, I can book lumo at 7", reason: .submit, wall: next()), "Messages Q7")
        accept(try unit(binding, &mono, id: "riley", bundle: "com.apple.MobileSMS", place: rilleyPlace, window: "m1", focus: "m1f",
                        text: "can you send me the lisbon flight times", reason: .submit, wall: next()), "Messages Riley")
        // messages-1003: Return alone is a draft; the composer emptying after it (the app's re-read) makes each a send.
        check(try store.action("m5")?.state == "draft" && store.action("riley")?.state == "draft", tag + "Messages Return alone stays a draft")
        _ = next()
        check(try binding.markComposerSent(id: "m5", windowID: "m1") && binding.markComposerSent(id: "riley", windowID: "m1"), tag + "an emptied composer marks both Messages rows sent")
        check(try store.action("m5")?.state == "submitted" && store.action("m5")?.title == "Q7" && store.action("riley")?.title == "Messages", tag + "sent rows: Q7 named, the generic window names nobody")
        let mailAt = next()
        accept(try unit(binding, &mono, id: "mail-to", bundle: "com.apple.mail", place: "New Message", window: "mw", focus: "mw-to",
                        role: "AXTextField", label: "To:", text: "Sam", reason: .focusKey, wall: mailAt), "Mail To")
        accept(try unit(binding, &mono, id: "mail-subject", bundle: "com.apple.mail", place: "New Message", window: "mw", focus: "mw-subject",
                        role: "AXTextField", label: "Subject:", text: "Pricing", reason: .focusKey, wall: next()), "Mail Subject")
        accept(try unit(binding, &mono, id: "mail-body", bundle: "com.apple.mail", place: "Pricing", window: "mw", focus: "mw-body",
                        role: "AXWebArea", surface: .embeddedWeb, text: "here is the pricing sheet for the team plan, 20 dollars a seat",
                        reason: .mailSend, wall: next()), "Mail body to Sam")
        accept(try webUnit(session, binding, &mono, id: "x-post", url: "https://x.com/home", pageTitle: "Home / X",
                           text: "DayDream launches tomorrow, it remembers where you left off", reason: .submitChord, wall: next()), "X post")
        accept(try unit(binding, &mono, id: "claude", bundle: "com.anthropic.claudefordesktop", place: "Claude", window: "c1", focus: "c1f",
                        surface: .embeddedWeb, text: "how do I fix the export crash on large CSV files", reason: .submit, wall: next()), "Claude ask")
        accept(try unit(binding, &mono, id: "chatgpt", bundle: "com.openai.codex", place: "ChatGPT", window: "g1", focus: "g1f",
                        surface: .embeddedWeb, text: "write a regex that matches ISO dates", reason: .submit, wall: next()), "ChatGPT ask")
        accept(try webUnit(session, binding, &mono, id: "slack", url: "https://app.slack.com/client/T01/C02", pageTitle: "eng (Channel) - Acme - Slack",
                           labels: ["Message #eng"], text: "export fix is in PR 518", reason: .submit, wall: next()), "Slack #eng")
        check(refused.isEmpty, tag + "refused == 0 (\(refused.count): \(refused.joined(separator: ", ")))")
        try session.stop()

        // The writers' evidence.
        for id in ["m5", "riley", "mail-body", "x-post", "claude", "chatgpt", "slack"] {
            let words = try store.hydrateTypedText(id, disclosure: .localWriter)
            check(words?.isEmpty == false, tag + "\(id): the local writer's hydration returns the words")
        }
        try store.setSummaryWriter("cloud")
        for id in ["m5", "riley", "mail-body", "x-post", "claude", "chatgpt", "slack"] {
            let words = try store.hydrateTypedText(id, disclosure: .cloudWriter)
            check(words?.isEmpty == false, tag + "\(id): the cloud writer's hydration returns the words (Cloud chosen)")
        }
        let tz = "UTC"
        let wants: [(id: String, name: String, needs: [String], localOnly: [String], cloudNot: [String])] = [
            ("m5", "Q7", ["to \"Q7\"", "Start with: Texted"], [], []),
            ("riley", "Unknown Messages recipient", ["Start with: Texted"], [], ["Riley"]),
            ("mail-body", "Mail", ["to \"Sam\"", "in \"Pricing\"", "Start with: Emailed"], [], []),
            // fix/sx-all (notes-quality): a post leads "Posted on X", and its page title is not a place ("in \"X\" on X").
            ("x-post", "X", ["(social) on x.com", "on X; sent with Command-Return", "Start with: Posted on X"], [], ["Home / X", "in \"X\""]),
            ("claude", "Claude", ["to \"Claude\"", "Start with: Asked"], [], []),
            ("chatgpt", "ChatGPT", ["to \"ChatGPT\"", "Start with: Asked"], [], []),
            ("slack", "Slack", ["in \"#eng\"", "Start with: Messaged"], [], []),
        ]
        for audience in ["LOCAL", "CLOUD"] {
            try store.setSummaryWriter(audience == "CLOUD" ? "cloud" : "local")
            let writer = CoreWriterBinding(store: store, typedWriter: audience == "CLOUD" ? .cloud : .local)
            let port = audience == "CLOUD" ? writer.port(audience: .cloud) : writer.port()
            for w in wants {
                guard let row = try store.action(w.id), let day = Optional(String(row.at.prefix(10))),
                      let moment = try store.dayLayers(day: day, timezone: tz).activities.first(where: { $0.actionIDs.contains(w.id) }) else {
                    evidence.append("[\(c.rawValue)] \(audience) \(w.name): no typed row (refused at capture)")
                    check(false, tag + "\(audience) \(w.name): the typed row is in a moment"); continue
                }
                do {
                    let request = try await port.prepare(WriterTarget(kind: .activity, day: day, timezone: tz, activityID: moment.id))
                    var actions = request.actions
                    var after = request.next
                    while let a = after { let page = try await port.page(request.id, a); actions += page.actions; after = page.next }
                    let view = try ModelView(request: request, actions: actions)
                    try await port.cancel(request.id)
                    let item = view.items.first { $0.actions.contains { $0.id == w.id } || $0.parts.contains { $0.actions.contains { $0.id == w.id } } }
                    let line = item?.line ?? ""
                    // The moment's on-device name is printed for LOCAL only: the cloud request carries its own text (checked below).
                    let label = audience == "LOCAL" ? " moment \"\(moment.subject)\"" : ""
                    evidence.append("[\(c.rawValue)] \(audience) \(w.name)\(label): \(line.isEmpty ? "(typed item missing)" : line)")
                    check(item != nil && line.contains("typed \""), tag + "\(audience) \(w.name) appears in model evidence with the words")
                    for need in w.needs + (audience == "LOCAL" ? w.localOnly : []) {
                        check(line.contains(need), tag + "\(audience) \(w.name): the item says \(need)")
                    }
                    if audience == "CLOUD" {
                        for not in w.cloudNot { check(!view.text.contains(not), tag + "CLOUD \(w.name): never the page title \(not)") }
                    }
                } catch {
                    evidence.append("[\(c.rawValue)] \(audience) \(w.name): prepare failed: \(error)")
                    check(false, tag + "\(audience) \(w.name) appears in model evidence (\(error))")
                }
            }
        }
        // The named checks the acceptance asks for.
        check(evidence.contains { $0.hasPrefix("[\(c.rawValue)] LOCAL Q7") && $0.contains("to \"Q7\"") }
              && evidence.contains { $0.hasPrefix("[\(c.rawValue)] CLOUD Q7") && $0.contains("to \"Q7\"") }, tag + "Q7 appears in model evidence")
        try store.setSummaryWriter("local")
    }

    // MARK: Explicit off stays off

    @MainActor static func negativeChecks(root: URL) throws {
        for (name, choices) in [("typing off", SetupChoices(typing: .off)), ("messages off", SetupChoices(messagesAndEmail: .off))] {
            let tag = "[NEGATIVE \(name)] "
            let store = try MemoryStore(home: root.appendingPathComponent("negative-" + name.replacingOccurrences(of: " ", with: "-")), writable: true, automaticallySyncSearch: false)
            try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore()))
            try store.saveSetupChoices(choices)
            let model = TypingModel(now: { Date() })
            _ = try continueSetup(store, model: model)
            let policy = try store.policy(), typed = try store.typedTextPolicy()
            try store.setCaptureState("recording", reason: "synthetic fixture")
            let binding = CoreCaptureBinding(store: store)
            var mono: UInt64 = 10_000_000_000
            let messages = try unit(binding, &mono, id: "neg-m5", bundle: "com.apple.MobileSMS", place: "Q7", window: "m", focus: "mf",
                                    text: "are we still on for dinner friday", reason: .submit, wall: Date())
            if choices.typing == .off {
                check(!policy.captureText && !typed.consented, tag + "an explicit Off keeps typing off through Continue")
                check(!messages, tag + "nothing is typed")
            } else {
                check(policy.captureText && typed.consented && !typed.categories.messagesAndEmail, tag + "typing on, Messages and email kept off")
                check(!messages, tag + "Messages stays refused")
                let notes = try unit(binding, &mono, id: "neg-notes", bundle: "com.apple.Notes", place: "Plan", window: "n", focus: "nf",
                                     text: "outline the launch plan", reason: .idle, wall: Date())
                check(notes, tag + "Notes still types")
            }
        }
    }

    // MARK: Setup's Continue

    /// What setup (and what's-new) does on Continue: the typing switch as seeded (on unless turned off), then the
    /// apps page saved with Web pages in Chrome as seeded.
    @MainActor static func continueSetup(_ store: MemoryStore, model: TypingModel) throws -> Bool {
        let seeds = try store.setupChoices()
        model.attach(store, hotkeys: nil)
        var typingOn = false
        #if TYPING_E2E_OLD
        // 5c76a6f: its setup turned typing on (acceptSafeTyping + the key), then saved the switch with the apps page.
        if seeds.typingSeed { typingOn = model.turnOn() }
        #else
        model.saveSwitch = { on in
            if let p = try? store.policy() { _ = try? store.savePreferences(prefs(p.blockedApps, typing: on, shown: true), expectedRevision: p.revision) }
        }
        if seeds.typingSeed { typingOn = model.turnOn() } else { model.turnOff() }
        #endif
        let p = try store.policy()
        _ = try store.savePreferences(prefs(p.blockedApps, typing: typingOn, pages: seeds.chromePagesSeed, shown: true), expectedRevision: p.revision)
        return typingOn
    }

    // MARK: Typing through the capture paths

    /// One app unit through CoreCaptureBinding (the production path): the gate, the read, the seal, the write.
    static func unit(_ binding: CoreCaptureBinding, _ mono: inout UInt64, id: String, bundle: String, place: String, window: String, focus: String,
                     role: String = "AXTextArea", surface: AppSurface = .native, label: String = "", text: String, reason: SealReason, wall: Date) throws -> Bool {
        mono += 2_000_000_000
        let ctx = try binding.context()
        var p = FocusProof()
        p.generation = ctx.generation; p.policyVersion = ctx.policy.version; p.checkedAt = mono
        p.bundle = bundle; p.windowID = window; p.focusID = focus; p.role = role; p.surface = surface; p.place = place; p.fieldLabel = label
        p.secureInput = .no; p.privateMode = .no; p.verified = true; p.fieldStateVerified = true; p.frameAccessible = true; p.navigationStable = true
        let step = try binding.insert(proof: p, eventAt: mono, now: mono, readCharacters: { text })
        guard step.decision.outcome == .allowed else { return false }
        return try binding.commitText(id: id, proof: p, now: mono, wallTime: wall, reason: reason)
    }

    /// One website unit: the site rules the join applies, the join's proof (its page title as page history saves
    /// it), the website gate, the typing session, `WebTypedRow` and the capture session's write (WebTypingRoute.write).
    static func webUnit(_ session: CaptureSession, _ binding: CoreCaptureBinding, _ mono: inout UInt64, id: String, url: String, pageTitle: String,
                        labels: [String] = [], text: String, reason: SealReason, wall: Date) throws -> Bool {
        mono += 2_000_000_000
        let ctx = try binding.context()
        let saved = try session.webTypingPolicy()
        let sites = BrowserTypingSiteRules(policy: saved.typed, settings: saved.settings, expanded: TypingRelease.open)
        let field = BrowserTypingFieldLabels(texts: labels, identifiers: [])
        guard let origin = BrowserSites.origin(url), sites.permits(url: url, field: field) else { print("NOTE \(id): the site rules refuse \(url)"); return false }
        var j = BrowserTypingJoinProof(origin: origin, windowID: "1101", tabID: "2202", windowList: ["1101"], documentID: UUID().uuidString,
                                       focusID: UUID().uuidString, targetIdentity: "chrome-fixture", role: "AXTextArea", subrole: "", checkedAt: mono)
        j.sendField = SendRules.fieldClass(role: "AXTextArea", labels: labels, composer: BrowserTypingComposerRules.composer(field))
        j.sendPlace = SendRules.composerPlace(labels: labels, host: BrowserTypingSites.host(of: url)) ?? ""
        Web.setPageTitle(&j, pageTitle, url: url, origin: origin)
        // The route's typing session, with its own generation (`BrowserTypingBurst.proof`).
        let burst = BrowserTypingBurst(sites: sites)
        let p = BrowserTypingBurst.focusProof(j, generation: burst.session.generation, policyVersion: ctx.policy.version)
        let gate = WebTypingGate.typing(p, policy: ctx.policy, generation: burst.session.generation, now: mono, expanded: sites.expanded, site: sites.permits(host:))
        guard gate.outcome == .allowed else { print("NOTE \(id): the website gate refuses (\(gate.reason))"); return false }
        _ = burst.session.insert(text, proof: p, policy: ctx.policy, eventAt: mono, now: mono)
        var wrote = false
        let outcome = try burst.session.commitLive(fresh: p, reason: reason, policy: ctx.policy, now: mono) { commit in
            guard let e = Web.evidence(commit, id: id, revision: ctx.revision, wall: wall, now: mono) else { print("NOTE \(id): no website typing row"); return false }
            wrote = try session.recordWebTyping(e, expectedPolicyRevision: ctx.revision, now: wall)
            if !wrote { print("NOTE \(id): the capture session refused the row") }
            return wrote
        }
        if !wrote { print("NOTE \(id): commit \(outcome)") }
        return wrote
    }

    static func prefs(_ apps: [String], typing: Bool, pages: Bool? = nil, shown: Bool = false) -> MemoryPreferences {
        #if TYPING_E2E_OLD
        return MemoryPreferences(blockedApps: apps, nativeTyping: typing, browserPages: pages)
        #else
        return MemoryPreferences(blockedApps: apps, nativeTyping: typing, browserPages: pages, typingChoiceShown: shown)
        #endif
    }
}

// MARK: - This build, or what 5c76a6f did instead

#if TYPING_E2E_OLD
/// 5c76a6f has no explicit-choice row: setup seeded typing from the saved switch or a first choice still waiting
/// (`DaydreamOnboardingTyping.initialSwitch`), Chrome pages from the saved switch or a first choice, messages off.
struct SetupChoices: Equatable {
    enum Choice { case on, off }
    var typing: Choice?, chromePages: Choice?, messagesAndEmail: Choice?
    init(typing: Choice? = nil, chromePages: Choice? = nil, messagesAndEmail: Choice? = nil) {
        self.typing = typing; self.chromePages = chromePages; self.messagesAndEmail = messagesAndEmail
    }
    var typingSeed = false, chromePagesSeed = false, messagesSeed = false
}
extension MemoryStore {
    func setupChoices() throws -> SetupChoices {
        let p = try policy(), pending = try nativeTypingChoicePending()
        var s = SetupChoices()
        s.typingSeed = p.captureText || pending
        s.chromePagesSeed = p.browserPages || pending
        s.messagesSeed = try typedTextPolicy().categories.messagesAndEmail
        return s
    }
    func saveSetupChoices(_ value: SetupChoices) throws {
        if value.typing == .off { let p = try policy(); _ = try savePreferences(MemoryPreferences(blockedApps: p.blockedApps, nativeTyping: false), expectedRevision: p.revision) }
        if value.messagesAndEmail == .off { _ = try setTypingCategory(.messagesAndEmail, on: false) }
    }
}
enum Conversation {
    static var rows: [String] = []
    static func fake(rows: [String]) { self.rows = rows }
    /// 5c76a6f read the window title only.
    static func place(title: String, bundle: String) -> String? { NativeTypingRoute.clip(title) }
}
enum Web {
    static func titleChecks() {}
    /// 5c76a6f's join kept no page title: the place was the host.
    static func setPageTitle(_ j: inout BrowserTypingJoinProof, _ title: String, url: String, origin: String) {}
    static func evidence(_ c: TypingCommit, id: String, revision: String, wall: Date, now: UInt64) -> Evidence? {
        WebTypedRow.evidence(c, id: id, policyRevision: revision, wallTime: wall, now: now)
    }
}
#else
enum Conversation {
    static func fake(rows: [String]) {
        MessagesConversation.forget()
        MessagesConversation.rowTexts = { _ in rows }
        MessagesConversation.windowKey = { _ in "window-" + rows.joined(separator: "|") }
    }
    /// NativeTypingRoute's place label for a key in `bundle` (pid 42 is only the cache key here).
    static func place(title: String, bundle: String) -> String? { NativeTypingRoute.place(title: title, bundle: bundle, pid: 42) }
}
enum Web {
    /// (L5, 7c) The place a website typing row gets from its tab's title.
    static func titleChecks() {
        func t(_ title: String, _ url: String) -> String { WebTypingTitle.clean(title, url: url, origin: BrowserSites.origin(url) ?? "") }
        TypingE2EChecks.check(t("Home / X", "https://x.com/home") == "Home / X", "web title: a page history page keeps its title (Home / X)")
        TypingE2EChecks.check(t("(3) Home / X", "https://x.com/home") == "Home / X", "web title: without its unread count")
        TypingE2EChecks.check(t("weekly summaries export by sam · Pull Request #418 · acme/daydream", "https://github.com/acme/daydream/pull/418")
                              == "weekly summaries export by sam · Pull Request #418 · acme/daydream", "web title: a pull request's title")
        TypingE2EChecks.check(t("Messages / X", "https://x.com/messages/123") == "", "web title: a message page keeps the site only")
        TypingE2EChecks.check(t("Re: Pricing - sam@example.com - Gmail", "https://mail.google.com/mail/u/0/#inbox/FMfc") == "Re: Pricing",
                              "web title: webmail keeps the open email's subject, never the address or the app")
        TypingE2EChecks.check(t("Inbox (3) - sam@example.com - Gmail", "https://mail.google.com/mail/u/0/#inbox") == "", "web title: a mailbox is no subject")
        TypingE2EChecks.check(t("Mail - Sam Rivera - Outlook", "https://outlook.office.com/mail/") == "", "web title: Outlook's own title is no subject (never the owner's name)")
        TypingE2EChecks.check(t("eng (Channel) - Acme - Slack", "https://app.slack.com/client/T01/C02") == "", "web title: chat keeps the site only (its channel comes from the composer)")
        TypingE2EChecks.check(t("boots - Google Search", "https://www.google.com/search?q=boots") == "", "web title: search keeps the site only")
    }
    /// The join's own line (`BrowserTypingJoin.join`): the page's title as Chrome page history saves it.
    static func setPageTitle(_ j: inout BrowserTypingJoinProof, _ title: String, url: String, origin: String) {
        j.pageTitle = WebTypingTitle.clean(title, url: url, origin: origin)
    }
    static func evidence(_ c: TypingCommit, id: String, revision: String, wall: Date, now: UInt64) -> Evidence? {
        WebTypedRow.evidence(c, id: id, policyRevision: revision, wallTime: wall, now: now)
    }
}
#endif
