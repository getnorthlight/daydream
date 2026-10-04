import Foundation
import MemoryCore
import PrivacyPolicy

/// Safe typing D (retention slice), through the public store API only:
/// the policy row, read-time hiding, the expiry job (stub or note summary),
/// the verbatim guard, key drops, Forget and the presentation lines.
/// Raw rows, file bytes and crypto-shred proofs run in scripts/typed-store-checks.swift.
func runTypedRetentionChecks(home: URL) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000), day = 86400.0
    func typedStore(_ name: String, accept: Bool = true) throws -> (MemoryStore, InMemoryTypedKeyStore) {
        let store = try MemoryStore(home: home.appendingPathComponent(name), writable: true, automaticallySyncSearch: false)
        var consent = try store.policy(); consent.captureText = true; consent.typedConsentVersion = 1; try store.updatePolicy(consent, now: now)
        let keys = InMemoryTypedKeyStore()
        try store.attachVault(TypedTextVault(keyStore: keys), now: now); try store.setUpTypedVault(now: now)
        // "Turn on typing" is also accepting the safe-typing screen (consent v2).
        if accept { try store.acceptSafeTyping(now: now) }
        return (store, keys)
    }
    func typed(_ id: String, _ text: String, at: Date, app: String = "Notes", run: String? = nil, part: Int = 1) -> Evidence {
        var e = Evidence(id: id, at: iso(at), kind: "keyboard.text_input", app: app, bundle: "com.apple.Notes", title: "Standup", text: text, synthetic: true)
        if let run {
            e.captureProvenance = NativeCaptureProvenance(policyRevision: "r", classifierVersion: "sensitive-typing/v2", windowID: "w", focusID: "f", checkedAt: iso(at), generation: 1,
                                                          unit: TypedUnitProvenance(runID: run, part: part, sealReason: part == 1 ? "idle" : "focus", startedAt: iso(at), keys: nil, edits: nil, withheld: 0))
        }
        return e
    }
    func dayKeys(_ keys: InMemoryTypedKeyStore) -> [String] {
        ((try? JSONSerialization.jsonObject(with: keys.raw ?? Data())) as? [String: Any]).flatMap { ($0["keys"] as? [String: String])?.keys.sorted() } ?? []
    }
    func refused(_ work: () throws -> Any) -> Bool { do { _ = try work(); return false } catch { return true } }
    func epoch(_ date: Date) -> String { TypedTextVault.epoch(for: date) }

    // MARK: Policy row (typed-text-policy-v1), outside PrivacySettings

    let (store, keys) = try typedStore("main", accept: false)
    let p0 = try store.typedTextPolicy()
    try check(p0.consentVersion == 0 && !p0.consented && p0.acceptedAt == "" && p0.retention == .days7 && p0.shareWithSummaries == .off && p0.snoozeUntil == ""
              && p0.categories == TypedCategoryChoices(searchAndAI: true, writing: true, code: true, messagesAndEmail: true), "no policy row: locked, 7 days, every category at its default (on, fix/typing-e2e L1), summaries can't read typing")
    try check(TypedRetention.allCases.map(\.label) == ["1 day", "7 days", "30 days", "Forever"] && TypedRetention.allCases.map(\.rawValue) == ["1d", "7d", "30d", "forever"] && TypedRetention.default == .days7, "retention choices and stored values")
    try check(TypedRetention.day1.cutoff(now: now) == now.addingTimeInterval(-day) && TypedRetention.days30.cutoff(now: now) == now.addingTimeInterval(-30 * day) && TypedRetention.forever.cutoff(now: now) == nil, "retention cutoffs")
    try check(TypedRetention.day1.isShorter(than: .days7) && TypedRetention.days30.isShorter(than: .forever) && !TypedRetention.forever.isShorter(than: .day1) && !TypedRetention.days7.isShorter(than: .days7) && !TypedRetention.days30.isShorter(than: .days7), "which change is shorter")
    try check(TypedRetention.day1.shorteningConfirmation == "This deletes the exact words older than 1 day now.", "shortening confirmation text")
    let odd = try JSONDecoder().decode(TypedTextPolicy.self, from: Data(#"{"retention":"90d","shareWithSummaries":"everywhere","categories":{"writing":false}}"#.utf8))
    try check(odd.retention == .day1 && odd.shareWithSummaries == .off && odd.categories.messagesAndEmail && !odd.categories.writing && odd.categories.code && odd.consentVersion == 0, "unknown values fail safe: shortest retention, sharing off, locked; a missing category takes its default (on)")
    let privacyRevision = try store.policy().revision
    var next = p0; next.categories.messagesAndEmail = true; next.shareWithSummaries = .localOnly; next.consentVersion = 2; next.snoozeUntil = iso(now.addingTimeInterval(9999))
    let saved = try store.updateTypedTextPolicy(next, now: now)
    try check(saved.categories.messagesAndEmail && saved.shareWithSummaries == .localOnly && saved.consentVersion == 0 && saved.snoozeUntil == "" && !saved.revision.isEmpty, "update saves categories and sharing, never consent or snooze")
    try check(try store.policy().revision == privacyRevision, "typing settings never rotate PrivacySettings (notes are not wiped)")
    let accepted = try store.acceptSafeTyping(now: now)
    try check(accepted.consented && accepted.consentVersion == 2 && accepted.acceptedAt == iso(now) && accepted.revision != saved.revision, "accepting the safe-typing screen records consent v2")
    // Review F2: the consent keeps the scope it was given for; a wider build asks again.
    try check(accepted.acceptedScope == .current && TypedConsentScope.current == TypedConsentScope(apps: CaptureGate.nativeApps, websites: OwnerTyping.enabled)
              && TypedConsentScope.current.apps == CaptureGate.nativeApps.sorted(),
              "consent scope: accepting saves the scope this build records (its app allowlist, and whether it types websites)")
    let narrowScope = TypedConsentScope(apps: ["com.apple.Notes", "com.apple.TextEdit"], websites: false)
    let moreApps = TypedConsentScope(apps: ["com.apple.Notes", "com.apple.TextEdit", "com.apple.Pages"], websites: false)
    let withWebsites = TypedConsentScope(apps: ["com.apple.Notes", "com.apple.TextEdit"], websites: true)
    var given = TypedTextPolicy(); given.consentVersion = TypedTextPolicy.currentConsentVersion; given.acceptedScope = narrowScope
    try check(given.consented(in: narrowScope) && given.consented(in: TypedConsentScope(apps: ["com.apple.Notes"], websites: false))
              && !given.scopeWidened(for: narrowScope), "consent scope: an unchanged or narrower build keeps the consent")
    try check(!given.consented(in: moreApps) && !given.consented(in: withWebsites) && given.scopeWidened(for: moreApps) && given.scopeWidened(for: withWebsites)
              && !given.consented(in: TypedConsentScope(apps: ["com.apple.Notes", "com.apple.TextEdit", "com.apple.Pages"], websites: true)),
              "consent scope: a build that records more apps, or websites, needs the safe-typing screen again")
    var wide = given; wide.acceptedScope = TypedConsentScope(apps: ["com.apple.Notes", "com.apple.TextEdit", "com.apple.Pages"], websites: true)
    try check(wide.consented(in: moreApps) && wide.consented(in: withWebsites) && wide.consented(in: narrowScope), "consent scope: a consent for a wider build covers every narrower one")
    var legacy = given; legacy.acceptedScope = nil
    try check(legacy.consented(in: narrowScope) && legacy.consented(in: .legacy) && !legacy.consented(in: moreApps) && !legacy.consented(in: withWebsites)
              && TypedConsentScope.legacy == narrowScope, "consent scope: a consent saved before scopes were kept covers Notes and TextEdit, no websites")
    var noConsent = given; noConsent.consentVersion = 0
    try check(!noConsent.consented(in: narrowScope) && !noConsent.scopeWidened(for: moreApps), "consent scope: no consent is not a widened scope")
    let olderRow = try JSONDecoder().decode(TypedTextPolicy.self, from: Data(#"{"version":1,"consentVersion":2}"#.utf8))
    let damagedRow = try JSONDecoder().decode(TypedTextPolicy.self, from: Data(#"{"version":1,"consentVersion":2,"acceptedScope":{"apps":"everything","websites":"yes"}}"#.utf8))
    try check(olderRow.acceptedScope == nil && !olderRow.consented(in: moreApps) && damagedRow.acceptedScope == TypedConsentScope(apps: [], websites: false)
              && !damagedRow.consented(in: narrowScope), "consent scope: an older row and a damaged scope fail closed")
    let roundTrip = try JSONDecoder().decode(TypedTextPolicy.self, from: JSONEncoder().encode(wide))
    try check(roundTrip.acceptedScope == wide.acceptedScope && roundTrip.consented(in: withWebsites), "consent scope: the scope is saved in the typing row")
    let (scoped, _) = try typedStore("scoped", accept: false)
    try scoped.acceptSafeTyping(now: now, scope: TypedConsentScope(apps: ["com.apple.Notes"], websites: false))
    var scopeRefused = false
    do { _ = try scoped.ingest(typed("scope-narrow", "typed after a narrower consent", at: now), now: now) } catch TypedTextError.notAccepted { scopeRefused = true }
    try check(scopeRefused && (try scoped.typedTextPolicy().scopeWidened) && !(try scoped.typedTextPolicy().consented) && (try scoped.read("scope-narrow", now: now)) == nil,
              "consent scope: consent given for fewer apps than this build records keeps typing off (nothing written)")
    // The menu while capture is recording (typingfix review: the store's own indicator reads "off" here,
    // because this check store never records, so the rule is asked directly).
    var narrowConsent = TypedTextPolicy(); narrowConsent.consentVersion = TypedTextPolicy.currentConsentVersion
    narrowConsent.acceptedScope = TypedConsentScope(apps: ["com.apple.Notes"], websites: false)
    var fullConsent = narrowConsent; fullConsent.acceptedScope = .current
    func indicator(_ p: TypedTextPolicy, _ vault: TypedVaultState = .ready) -> TypingIndicatorState {
        TypingIndicator.state(capture: "recording", typingOn: true, policy: p, vault: vault, frontmostBundle: "com.apple.Notes", now: now)
    }
    try check(indicator(narrowConsent) == .locked(.notAccepted) && !indicator(narrowConsent).showsDot && indicator(fullConsent) == .recording(app: "Notes"),
              "consent scope: while recording, the menu shows typing locked, never recording, until the consent covers this build")
    try check(indicator(narrowConsent, .locked) == .locked(.keychainLocked) && indicator(fullConsent, .locked) == .locked(.keychainLocked)
              && indicator(TypedTextPolicy(), .locked) == .locked(.notAccepted),
              "consent scope: with the Keychain locked the menu asks for the unlock first (Settings shows the locked card), then the new scope")
    try scoped.acceptSafeTyping(now: now)
    try check(try scoped.ingest(typed("scope-again", "typed after accepting again", at: now), now: now) && scoped.typedTextPolicy().consented && !scoped.typedTextPolicy().scopeWidened,
              "consent scope: accepting again, for this build's scope, turns typing back on")
    // typingfix review: "Turn on typing" for a wider build while the Keychain is locked writes nothing, so the
    // settings keep their signature: after the unlock retention, categories and sharing are unchanged and no word goes.
    let (lockedScope, scopeKeys) = try typedStore("scope-locked")
    var kept = try lockedScope.typedTextPolicy(); kept.retention = .forever; kept.categories.messagesAndEmail = true; kept.shareWithSummaries = .localOnly
    _ = try lockedScope.updateTypedTextPolicy(kept, now: now)
    try check(try lockedScope.ingest(typed("scope-locked-old", "kept forever before the update", at: now.addingTimeInterval(-40 * day)), now: now),
              "locked Keychain setup: a 40 day old draft kept Forever")
    try lockedScope.acceptSafeTyping(now: now, scope: TypedConsentScope(apps: ["com.apple.Notes"], websites: false))
    let signed = try lockedScope.typedTextPolicy()
    try check(signed.scopeWidened && (try lockedScope.typedTextPolicyVerified()), "locked Keychain setup: a signed consent for fewer places than this build records")
    scopeKeys.locked = true
    try check(try lockedScope.reconcileTypedVault(now: now) == .locked, "locked Keychain setup: the Keychain locks")
    try check(refused { try lockedScope.acceptSafeTyping(now: now) } && refused { try lockedScope.setUpTypedVault(now: now) },
              "locked Keychain: Turn on typing is refused while the key can't be read")
    scopeKeys.locked = false
    try check(try lockedScope.retryLockedTypedVault(now: now) == .ready && lockedScope.typedTextPolicyVerified(),
              "locked Keychain: after the unlock the settings still carry their signature")
    let afterUnlock = try lockedScope.typedTextPolicy()
    try check(afterUnlock == signed && afterUnlock.retention == .forever && afterUnlock.categories.messagesAndEmail && afterUnlock.shareWithSummaries == .localOnly
              && afterUnlock.consentVersion == TypedTextPolicy.currentConsentVersion && afterUnlock.scopeWidened,
              "locked Keychain: after the unlock retention, categories, sharing and the consent are unchanged")
    try check(try lockedScope.expireTypedText(now: now).expired == 0 && lockedScope.hydrateTypedText("scope-locked-old", disclosure: .owner, now: now) == "kept forever before the update",
              "locked Keychain: no kept word is deleted")
    try lockedScope.acceptSafeTyping(now: now); try lockedScope.setUpTypedVault(now: now)
    let reaccepted = try lockedScope.typedTextPolicy()
    try check(reaccepted.consented && reaccepted.retention == .forever && reaccepted.categories.messagesAndEmail && reaccepted.shareWithSummaries == .localOnly
              && (try lockedScope.typedTextPolicyVerified()), "locked Keychain: Turn on typing after the unlock keeps the owner's settings")
    let until = try store.snoozeTyping(now: now)
    try check(until == now.addingTimeInterval(600) && (try store.typedTextPolicy().snoozed(now: now.addingTimeInterval(599))) && !(try store.typedTextPolicy().snoozed(now: now.addingTimeInterval(600))), "snooze lasts 10 minutes")
    try check(try store.snoozeTyping(now: now.addingTimeInterval(60)) == until, "pressing the shortcut again never extends the pause")
    try store.resumeTyping(now: now.addingTimeInterval(61))
    try check(try !store.typedTextPolicy().snoozed(now: now.addingTimeInterval(62)) && store.typedTextPolicy().snoozeUntil == "", "record typing again clears the pause")
    try check(refused { try store.snoozeTyping(minutes: 0, now: now) }, "a zero-minute pause is refused")
    var broken = TypedTextPolicy(); broken.snoozeUntil = "not a time"
    try check(broken.snoozed(now: now), "an unreadable pause time counts as paused (fail closed)")
    try check(refused { try MemoryStore(home: home.appendingPathComponent("main")).snoozeTyping(now: now) }, "a read-only store can't change typing settings")
    try check(try store.policy().revision == privacyRevision, "consent and snooze never rotate PrivacySettings")

    // Verbatim guard (review fix): relative to the draft, and a short draft
    // is never kept whole, even a one-word search.
    try check(TypedVerbatimGuard.allowedRun(draftWords: 1) == 1 && TypedVerbatimGuard.allowedRun(draftWords: 8) == 3 && TypedVerbatimGuard.allowedRun(draftWords: 40) == 5, "the guard allows fewer copied words for shorter drafts, 5 at most")
    try check(TypedVerbatimGuard.copies("Looked up zanzibar flights", from: "Zanzibar") && !TypedVerbatimGuard.copies("Looked up island flights", from: "Zanzibar"), "a one-word draft can't be carried whole into a note")
    try check(TypedVerbatimGuard.copies("Texted Mom: running late, start dinner without me", from: "Running late, start dinner without me")
              && !TypedVerbatimGuard.copies("Texted Mom that you'd be late for dinner", from: "Running late, start dinner without me", places: ["Mom"]), "guard v2: a whole short draft is refused even when its words are stop words; a paraphrase passes")
    try check(!TypedVerbatimGuard.copies("Asked Claude to move the 14 Priya sync to 3pm on Friday", from: "can you move the 14 Priya sync to 3pm on Friday and tell Dana")
              && TypedVerbatimGuard.names(in: "Make sure Sam sees it. make it quick") == ["sam"], "guard v2: numbers and names are free; a sentence-initial or also-lowercase word is not a name")
    try check(TypedVerbatimGuard.copies("Messaged #launch that the build is ready", from: "The build is signed test green up on the drive", places: ["#launch"]) == false
              && TypedVerbatimGuard.copies("Messaged that the build is signed, test green, up on the drive", from: "The build is signed test green up on the drive"), "guard v2: the channel name is free; the whole message copied is refused")
    // fix/sx-all round 2: the message said again with only small words dropped is a copy too (reworded).
    try check(TypedVerbatimGuard.copies("Messaged #launch that build signed test green", from: "The build is signed test green up on the drive", places: ["#launch"]),
              "guard v2: the message's words kept with small words dropped are refused (reworded)")
    try check(TypedVerbatimGuard.copies("Searched divorce lawyer", from: "divorce lawyer near me") && !TypedVerbatimGuard.copies("Searched for a lawyer", from: "divorce lawyer near me"), "two words in a row from a 4-word draft are too many; one is fine")

    // MARK: Read-time hiding and the expiry job

    let words = ["a0": "fresh roadmap draft for the team", "a2": "two day old draft about budgets", "a10": "ten day old draft about the offsite", "a40": "forty day old draft about hiring"]
    // Each draft is saved when it was typed (oldest first): a draft that is
    // already past the period when it arrives is saved as a stub straight
    // away (checked in typed-store), and the store's clock never runs back.
    for (id, offset) in [("a40", 40.0), ("a10", 10.0), ("a2", 2.0), ("a0", 0.5)] {
        let at = now.addingTimeInterval(-offset * day)
        try check(try store.ingest(typed(id, words[id]!, at: at), now: at.addingTimeInterval(60)), "draft \(id) sealed")
    }
    try check(dayKeys(keys).count == 4, "one day key per UTC day of drafts")
    try check(try store.hydrateTypedText("a2", disclosure: .owner, now: now) == words["a2"], "words inside the period open for the owner")
    try check(try store.hydrateTypedText("a10", disclosure: .owner, now: now) == nil && store.hydrateTypedText("a40", disclosure: .owner, now: now) == nil, "words past 7 days are hidden at read time, before the job runs")
    // A later clock is remembered (review: a clock set back never reopens
    // words), so this probe runs on its own store.
    let (probe, probeKeys) = try typedStore("probe")
    try check(try probe.ingest(typed("p2", words["a2"]!, at: now.addingTimeInterval(-2 * day)), now: now) && probe.hydrateTypedText("p2", disclosure: .owner, now: now) == words["a2"], "probe draft opens inside the period")
    try check(try probe.hydrateTypedText("p2", disclosure: .owner, now: now.addingTimeInterval(5.6 * day)) == nil, "words hide the moment they pass the period")
    try check(try probe.hydrateTypedText("p2", disclosure: .owner, now: now) == nil, "setting the clock back doesn't reopen them")
    // typing-all W0: the high-water is kept across launches. A new store on
    // the same folder (as after a relaunch) with the clock set back still
    // hides them; a control store that never saw the later clock opens its words.
    let relaunched = try MemoryStore(home: home.appendingPathComponent("probe"), writable: true, automaticallySyncSearch: false)
    try relaunched.attachVault(TypedTextVault(keyStore: probeKeys), now: now)
    try check(try relaunched.hydrateTypedText("p2", disclosure: .owner, now: now) == nil, "after a relaunch, setting the clock back still doesn't reopen them")
    let (control, controlKeys) = try typedStore("probe-control")
    try check(try control.ingest(typed("c2", words["a2"]!, at: now.addingTimeInterval(-2 * day)), now: now), "control draft sealed")
    let controlRelaunched = try MemoryStore(home: home.appendingPathComponent("probe-control"), writable: true, automaticallySyncSearch: false)
    try controlRelaunched.attachVault(TypedTextVault(keyStore: controlKeys), now: now)
    try check(try controlRelaunched.hydrateTypedText("c2", disclosure: .owner, now: now) == words["a2"], "control: after a relaunch, words inside the period open")
    try check(try relaunched.expireTypedText(now: now).expired == 1, "the relaunched store's expiry job deletes them at the remembered clock")
    let early = try store.typedStatuses(["a0", "a10", "w-none"], now: now)
    try check(early["a0"]?.state == .live && early["a10"]?.state == .expired && early["a10"]?.summary == "" && early["w-none"] == nil, "status: live and expired-but-not-yet-deleted")
    try check(try store.assistantItem("a10", now: now)?["snippet"] == "Typed in Notes, a sentence (exact words deleted after 7 days)", "AI apps see the stub line as soon as words expire")
    let revisionA10 = try store.action("a10", now: now)?.revision
    let report = try store.expireTypedText(now: now)
    try check(report.expired == 2 && report.keptNotes == 0 && report.orphans == 0 && !report.keyDropPending, "the job deletes the two expired drafts, with stubs")
    try check(report.droppedKeys == [epoch(now.addingTimeInterval(-40 * day)), epoch(now.addingTimeInterval(-10 * day))], "the job drops the keys of days with nothing left")
    try check(dayKeys(keys) == [epoch(now.addingTimeInterval(-2 * day)), epoch(now.addingTimeInterval(-0.5 * day))].sorted(), "keys of days that still have words stay")
    try check(try store.typedCounts() == (2, 2) && store.typedAfter("a10")?.source == "stub" && store.typedAfter("a10")?.summary == "" && store.typedAfter("a10")?.words == 7, "expired drafts become stubs with a word count")
    try check(try store.action("a10", now: now)?.revision == revisionA10 && store.action("a10", now: now)?.description == "Typed a draft in Notes (a sentence).", "the record and its action never change on expiry")
    try check(try store.expireTypedText(now: now) == TypedExpiryReport(), "running the job again changes nothing")
    try check(try store.hydrateTypedText("a10", disclosure: .owner, now: now.addingTimeInterval(-9 * day)) == nil, "deleted words never come back, even for an earlier clock")

    // Shorter needs confirmation and applies now; longer brings nothing back.
    var shorter = try store.typedTextPolicy(); shorter.retention = .day1
    try check(try store.typedRetentionChangeCount(.day1, now: now) == 1, "a 1-day period would delete one draft now")
    try check(refused { try store.updateTypedTextPolicy(shorter, now: now) }, "a shorter period without confirmation is refused")
    try check(try store.typedTextPolicy().retention == .days7 && store.hydrateTypedText("a2", disclosure: .owner, now: now) == words["a2"], "the refused change deleted nothing")
    try store.updateTypedTextPolicy(shorter, confirmed: true, now: now)
    try check(try store.typedTextPolicy().retention == .day1 && store.typedAfter("a2")?.source == "stub" && store.hydrateTypedText("a2", disclosure: .owner, now: now) == nil, "a confirmed shorter period deletes older words at once")
    try check(!dayKeys(keys).contains(epoch(now.addingTimeInterval(-2 * day))), "and drops their day key")
    var longer = try store.typedTextPolicy(); longer.retention = .days30
    try store.updateTypedTextPolicy(longer, now: now)
    try check(try store.typedStatuses(["a2"], now: now)["a2"]?.state == .expired && store.hydrateTypedText("a2", disclosure: .owner, now: now) == nil, "a longer period brings nothing back")
    try check(try store.assistantItem("a2", now: now)?["snippet"] == "Typed in Notes, a sentence (exact words deleted after 30 days)", "the stub line names the current period")
    var forever = try store.typedTextPolicy(); forever.retention = .forever
    try store.updateTypedTextPolicy(forever, now: now)
    try check(try store.ingest(typed("old-forever", "kept forever draft", at: now.addingTimeInterval(-200 * day)), now: now), "an old draft saves when words are kept forever")
    try check(try store.expireTypedText(now: now).expired == 0 && store.hydrateTypedText("old-forever", disclosure: .owner, now: now) == "kept forever draft", "forever keeps words")
    try check(try store.assistantItem("a2", now: now)?["snippet"] == "Typed in Notes, a sentence (exact words deleted)", "with forever, the stub line doesn't name a period")
    var back = try store.typedTextPolicy(); back.retention = .days7
    try store.updateTypedTextPolicy(back, confirmed: true, now: now)
    try check(try store.typedAfter("old-forever")?.source == "stub" && store.hydrateTypedText("a0", disclosure: .owner, now: now) == words["a0"], "back to 7 days: the old draft goes, the fresh one stays")

    // The shorter of typed and whole-history retention wins.
    try check(try store.typedCutoff(now: now) == now.addingTimeInterval(-7 * day), "typed cutoff alone")
    let review = try store.prepareRetentionChange(.days(5), now: now)
    _ = try store.confirmRetentionChange(review.id, confirmed: true, now: now)
    try check(try store.typedCutoff(now: now) == now.addingTimeInterval(-5 * day), "whole-history retention shorter than typed retention wins")
    var one = try store.typedTextPolicy(); one.retention = .day1
    try store.updateTypedTextPolicy(one, confirmed: true, now: now)
    try check(try store.typedCutoff(now: now) == now.addingTimeInterval(-day), "typed retention shorter than whole history wins")

    // writePending runs the job; deletion never waits for a summarizer.
    let (pending, pendingKeys) = try typedStore("pending")
    try check(try pending.ingest(typed("p8", "eight day old draft for the pending queue", at: now.addingTimeInterval(-8 * day)), now: now) && pending.ingest(typed("p0", "fresh draft", at: now), now: now), "drafts sealed")
    _ = try pending.writePending(now: now)
    try check(try pending.typedAfter("p8")?.source == "stub" && pending.typedCounts() == (1, 1) && !dayKeys(pendingKeys).contains(epoch(now.addingTimeInterval(-8 * day))), "writePending deletes expired words and drops the empty day's key")
    try check(try pending.read("p8", now: now)?.summary == "Typed in Notes, a sentence.", "the regenerated summary still has no words")

    // MARK: Note summary, verbatim guard, stable note revisions

    let (notes, _) = try typedStore("notes")
    let t = now.addingTimeInterval(-8 * day), noteDay = epoch(t)
    let draft = "Hi Sam, the pricing page ships Friday and the new plans go live after lunch"
    try check(try notes.ingest(typed("n1", draft, at: t), now: t), "a draft to summarize")
    _ = try notes.writePending(now: t)
    let request = try notes.prepareNote(kind: "day", day: noteDay, timezone: "UTC", now: t)
    func output(_ title: String, _ bullets: [String]) -> NoteWriterOutput {
        NoteWriterOutput(requestID: request.id, title: title, bullets: bullets.map { NoteBullet(text: $0, actionIDs: ["n1"], assertion: "draft") }, generator: "fixture", generatorVersion: "1")
    }
    try check(refused { try notes.commitNote(output("Pricing", ["Told Sam the new plans go live after lunch"]), now: t) }, "a bullet copying 6 words in a row is refused at commit")
    try check(refused { try notes.commitNote(output("new plans go live after lunch", ["Drafted a reply to Sam about pricing"]), now: t) }, "a title copying 6 words in a row is refused at commit")
    try check(refused { try notes.commitNote(output("Pricing", ["HI SAM — THE NEW PLANS, GO LIVE AFTER lunch!"]), now: t) }, "the guard ignores case and punctuation")
    try check(!TypedVerbatimGuard.copies("Told Sam the pricing page ships Friday and more", from: draft), "guard v2: names (Sam, Friday) and stop words don't count toward a copied run")
    let note = try notes.commitNote(output("Pricing reply", ["Wrote that the pricing page ships Friday", "Drafted a reply to Sam about pricing"]), now: t)
    try check(note.output.bullets.count == 2, "5 words in a row are allowed; the note commits")
    let before = try notes.dayLayers(day: noteDay, timezone: "UTC", now: t)
    try check(before.summary.status == "ready", "the day note is ready")
    let expired = try notes.expireTypedText(now: now)
    try check(expired.expired == 1 && expired.keptNotes == 1 && notes.typedAfter("n1")?.source == "note" && notes.typedAfter("n1")?.summary == "Drafted a reply to Sam about pricing", "the shortest grounded bullet that passes the guard is kept as the summary")
    let after = try notes.dayLayers(day: noteDay, timezone: "UTC", now: now)
    try check(after.summary.inputRevision == before.summary.inputRevision && after.summary.status == "ready" && after.summary.generated?.output == note.output, "the note's inputRevision is unchanged and the note survives expiry")
    try check(try notes.assistantItem("n1", now: now)?["snippet"] == "Typed in Notes: Drafted a reply to Sam about pricing (exact words deleted after 7 days)", "AI apps see the kept summary, never the words, with no \"summary;\" (N14)")
    try check(try !(json(notes.assistantItem("n1", now: now))).contains("ships Friday and the new plans"), "no words in the MCP read after expiry")

    // A writer without a key can't be checked at commit; the expiry guard catches it.
    let (guarded, _) = try typedStore("guarded")
    let g = now.addingTimeInterval(-9 * day)
    let copied = "we should move the launch review to thursday afternoon at three"
    try check(try guarded.ingest(typed("c1", copied, at: g), now: g), "a draft written in the app")
    _ = try guarded.writePending(now: g)
    let cli = try MemoryStore(home: guarded.home, writable: true, automaticallySyncSearch: false)
    let cliRequest = try cli.prepareNote(kind: "day", day: epoch(g), timezone: "UTC", now: g)
    _ = try cli.commitNote(NoteWriterOutput(requestID: cliRequest.id, title: "Launch review", bullets: [NoteBullet(text: "Drafted: move the launch review to Thursday afternoon at three", actionIDs: ["c1"], assertion: "draft")], generator: "fixture", generatorVersion: "1"), now: g)
    try check(true, "a process without a key has no words to check at commit")
    try check(try guarded.expireTypedText(now: now).keptNotes == 0 && guarded.typedAfter("c1")?.source == "stub", "at expiry a bullet copying more than 5 words is not kept; the stub is used")

    // A locked Keychain: words are still deleted (stubs), the key drop waits.
    let (locked, lockedKeys) = try typedStore("locked")
    try check(try locked.ingest(typed("k8", "eight day old words behind a locked keychain", at: now.addingTimeInterval(-8 * day)), now: now.addingTimeInterval(-8 * day)) && locked.ingest(typed("k0", "fresh words", at: now), now: now), "drafts sealed")
    lockedKeys.locked = true
    try check(try locked.reconcileTypedVault(now: now) == .locked, "the Keychain locks")
    let lockedReport = try locked.expireTypedText(now: now)
    try check(lockedReport.expired == 1 && lockedReport.keyDropPending && lockedReport.droppedKeys.isEmpty && locked.typedAfter("k8")?.source == "stub", "a locked Keychain still deletes expired words; the key drop waits")
    lockedKeys.locked = false
    try check(try locked.reconcileTypedVault(now: now) == .ready, "the Mac unlocks")
    try check(try locked.expireTypedText(now: now).droppedKeys == [epoch(now.addingTimeInterval(-8 * day))], "the next run drops the key")

    // MARK: Presentation (no words)

    try check(TypedLine.withoutWords(app: "Slack", status: TypedStatus(state: .live, words: 5)) == "Typed in Slack, a sentence (exact words not shared with AI apps)", "live line")
    try check(TypedLine.withoutWords(app: "Slack", status: TypedStatus(state: .expired, words: 7, summary: "drafted a reply to Sam about pricing.")) == "Typed in Slack: drafted a reply to Sam about pricing (exact words deleted after 7 days)", "expired with a summary: where, then the line (N14)")
    try check(TypedLine.withoutWords(app: "Slack", status: TypedStatus(state: .expired, words: 7, summary: "Messaged #launch on Slack that the build is signed.")) == "Messaged #launch on Slack that the build is signed (exact words deleted after 7 days)", "N14: a kept line that already names the app doesn't repeat it")
    try check(TypedLine.withoutWords(app: "Slack", status: TypedStatus(state: .expired, words: 21)) == "Typed in Slack, about 20 words (exact words deleted after 7 days)", "expired without a summary: a word-count range")
    try check(TypedLine.withoutWords(app: "Slack", status: TypedStatus(state: .expired, words: 2, keptFor: .forever)) == "Typed in Slack, a few words (exact words deleted)", "expired while kept forever (a deleted or declined draft)")
    try check(TypedLine.withoutWords(app: "Slack", status: TypedStatus(state: .unavailable, words: 9)) == "Typed in Slack (exact words no longer available)", "key lost")
    try check(TypedLine.owner(app: "Slack", status: TypedStatus(state: .live, words: 4), words: "pricing page ships Friday") == "Typed in Slack: “pricing page ships Friday”", "the owner sees live words")
    try check(TypedLine.owner(app: "Slack", status: TypedStatus(state: .live, words: 4), words: nil) == "Typed in Slack, a sentence (exact words unavailable right now)", "the owner, Keychain locked")
    try check(TypedLine.owner(app: "Slack", status: TypedStatus(state: .expired, words: 4), words: "never shown") == "Typed in Slack, a sentence (exact words deleted after 7 days)", "the owner never sees expired words")

    // One draft per run.
    let (runs, _) = try typedStore("runs")
    try check(try runs.ingest(typed("r1a", "first part of one long draft", at: now.addingTimeInterval(-30), run: "run-1", part: 1), now: now)
              && runs.ingest(typed("r1b", "second part of the same draft here", at: now.addingTimeInterval(-20), run: "run-1", part: 2), now: now)
              && runs.ingest(typed("r2", "another draft", at: now.addingTimeInterval(-10), run: "run-2"), now: now), "three typed rows in two runs")
    let page = try runs.actions(now: now).actions
    let statuses = try runs.typedStatuses(page.map(\.id), now: now)
    try check(statuses["r1a"]?.runID == "run-1" && statuses["r1b"]?.part == 2 && statuses["r2"]?.runID == "run-2", "status carries runID and part")
    let groups = TypedDrafts.group(page, status: { statuses[$0] })
    try check(groups.map { $0.map(\.id) } == [["r1a", "r1b"], ["r2"]], "rows of one run show as one draft")
    let combined = TypedDrafts.combined(groups[0].compactMap { statuses[$0.id] })
    try check(combined?.words == 13 && combined?.state == .live && AssistantView.line(groups[0][0], typed: combined) == "Typed in Notes, a sentence (exact words not shared with AI apps)", "one line for the run, words added up")
    try check(TypedDrafts.combined([TypedStatus(state: .live, words: 3), TypedStatus(state: .expired, words: 3)])?.state == .unavailable
              && TypedDrafts.combined([TypedStatus(state: .expired, words: 3), TypedStatus(state: .expired, words: 3, summary: "planned the offsite")])?.summary == "planned the offsite", "mixed runs never read as live; a kept summary carries over")

    // MARK: Forget what I typed

    let (forget, forgetKeys) = try typedStore("forget")
    try check(try forget.ingest(typed("f1", "forget this draft please", at: now), now: now) && forget.ingest(typed("f2", "and this other draft", at: now.addingTimeInterval(-9 * day)), now: now), "drafts sealed")
    try check(try forget.ingest(Evidence(id: "fw", at: iso(now), kind: "window.changed", app: "Notes", bundle: "com.apple.Notes", title: "Standup", synthetic: true), now: now), "a window row")
    _ = try forget.acceptSafeTyping(now: now)
    _ = try forget.writePending(now: now)
    let forgetRequest = try forget.prepareNote(kind: "day", day: epoch(now), timezone: "UTC", now: now)
    _ = try forget.commitNote(NoteWriterOutput(requestID: forgetRequest.id, title: "Notes", bullets: [NoteBullet(text: "Drafted something in Notes", actionIDs: ["f1"], assertion: "draft")], generator: "fixture", generatorVersion: "1"), now: now)
    try check(refused { try forget.forgetTypedText(confirmed: false, now: now) } && forget.typedCounts() == (1, 1), "Forget needs confirmation")
    let forgot = try forget.forgetTypedText(confirmed: true, now: now)
    try check(forgot.deletedDrafts == 2 && forgot.deletedNotes >= 1 && forgot.keyringDeleted && forgetKeys.raw == nil, "Forget deletes every typed draft, the notes citing them, and the keyring")
    try check(try forget.typedCounts() == (0, 0) && forget.read("f1", now: now) == nil && forget.read("f2", now: now) == nil && forget.read("fw", now: now) != nil, "typed rows are gone; other activity stays")
    try check(try !forget.typedTextPolicy().consented && forget.typedVaultState == .notSetUp && !forget.typedForgetPending(), "Forget turns typing off (consent cleared, no key)")
    try check(try !forget.ingest(typed("f1", "forget this draft please", at: now), now: now), "a forgotten draft can't be saved again")
    try check(refused { try forget.ingest(typed("f3", "new words after forget", at: now), now: now) }, "new words are locked until typing is turned on again")
    try forget.setUpTypedVault(now: now)
    try check(forgetKeys.raw != nil && forget.typedVaultState == .ready, "turning typing on again makes a new keyring")

    // Forget from a process without a key finishes when the app attaches its vault.
    let (app, appKeys) = try typedStore("forget-cli")
    try check(try app.ingest(typed("x1", "words the cli forgets", at: now), now: now), "a draft")
    let reader = try MemoryStore(home: app.home, writable: true, automaticallySyncSearch: false)
    let remote = try reader.forgetTypedText(confirmed: true, now: now)
    try check(!remote.keyringDeleted && (try reader.typedForgetPending()) && appKeys.raw != nil && (try app.typedCounts()) == (0, 0), "without a key the words go at once and the keyring waits")
    _ = try app.reconcileTypedVault(now: now)
    try check(appKeys.raw == nil && (try !app.typedForgetPending()), "the app deletes the keyring the next time it checks its vault")
    let (lockedForget, lockedForgetKeys) = try typedStore("forget-locked")
    try check(try lockedForget.ingest(typed("y1", "locked forget words", at: now), now: now), "a draft")
    lockedForgetKeys.locked = true
    try check(try !lockedForget.forgetTypedText(confirmed: true, now: now).keyringDeleted && lockedForget.typedForgetPending(), "a locked Keychain keeps Forget pending")
    lockedForgetKeys.locked = false
    _ = try lockedForget.expireTypedText(now: now)
    try check(lockedForgetKeys.raw == nil && (try !lockedForget.typedForgetPending()), "the next expiry run finishes Forget")
}
