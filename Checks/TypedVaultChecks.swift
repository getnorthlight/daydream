import Foundation
import MemoryCore

/// Every check that writes typed rows attaches this: an in-memory key store,
/// never the real Keychain, then the explicit "Turn on typing" step, which
/// is accepting the safe-typing screen (consent v2) and creating the key.
@discardableResult func attachTestVault(_ store: MemoryStore, accept: Bool = true) throws -> InMemoryTypedKeyStore {
    let keys = InMemoryTypedKeyStore()
    try store.attachVault(TypedTextVault(keyStore: keys))
    if accept { try store.acceptSafeTyping() }
    try store.setUpTypedVault()
    return keys
}

private func throwsLocked(_ work: () throws -> Any) -> TypedVaultState? {
    do { _ = try work(); return nil } catch let error as TypedTextError {
        if case .typingLocked(let state) = error { return state }; return nil
    } catch { return nil }
}

/// Safe typing B (vault slice), through the public store API only. Raw-byte,
/// crypto and migration checks run in scripts/typed-store-checks.swift.
func runTypedVaultChecks(home: URL) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    var consent = try store.policy(); consent.captureText = true; consent.typedConsentVersion = 1; try store.updatePolicy(consent, now: now)
    func typed(_ id: String, _ text: String, at: Date = now) -> Evidence {
        Evidence(id: id, at: iso(at), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes", title: "Standup", text: text, synthetic: true)
    }

    // Lock: no vault, consent alone is not enough, and nothing is written.
    try check(store.typedVaultState == .unavailable && !store.typingUnlocked, "a store without a vault is unavailable and typing is locked")
    try check(throwsLocked { try store.ingest(typed("t-none", "pricing page ships Friday"), now: now) } == .unavailable, "typed text without a vault throws typingLocked")
    try check(try store.read("t-none", now: now) == nil && store.typedCounts() == (0, 0), "a refused typed row writes nothing, with no plain-text fallback")
    try check(try store.ingest(Evidence(id: "t-window", at: iso(now), kind: "window.changed", app: "Notes", bundle: "com.apple.Notes", title: "Standup", synthetic: true), now: now), "metadata rows still save while typing is locked")

    // notSetUp: attaching never creates a key; turning typing on does.
    let keys = InMemoryTypedKeyStore()
    try check(try store.attachVault(TypedTextVault(keyStore: keys), now: now) == .notSetUp && keys.raw == nil, "attaching a vault never creates a key")
    try check(throwsLocked { try store.ingest(typed("t-notsetup", "pricing page ships Friday"), now: now) } == .notSetUp, "notSetUp still refuses typed text")
    try store.setUpTypedVault(now: now)
    try check(store.typedVaultState == .ready && keys.saves == 1, "turning typing on creates one keyring item")
    let ring = try JSONSerialization.jsonObject(with: keys.raw ?? Data()) as? [String: Any] ?? [:]
    try check(ring["version"] as? Int == 1 && (ring["keys"] as? [String: String])?.isEmpty == true && Data(base64Encoded: ring["mac"] as? String ?? "")?.count == 32, "keyring JSON: version 1, no day keys yet, a 32-byte MAC key")
    try store.setUpTypedVault(now: now)
    try check(keys.saves == 1, "turning typing on again over a ready vault changes nothing")
    // Safe typing E/F: a ready key is not consent. Until the safe-typing
    // screen is accepted (consent v2) the store refuses words and writes nothing.
    var notAccepted = false
    do { _ = try store.ingest(typed("t-noconsent", "pricing page ships Friday"), now: now) } catch TypedTextError.notAccepted { notAccepted = true }
    try check(notAccepted && (try store.read("t-noconsent", now: now)) == nil && (try store.typedCounts()) == (0, 0), "a ready vault without consent v2 refuses typed text and writes nothing")
    try store.acceptSafeTyping(now: now)

    // Sealing: the record keeps text "" and a pointer; the words open only for the owner.
    try check(try store.ingest(typed("t1", "pricing page ships Friday"), now: now), "typed text saves with a ready vault")
    let item = try store.read("t1", now: now)
    try check(item?.evidence.text == "" && item?.evidence.typed?.words == 4 && item?.evidence.typed?.digest.count == 64 && item?.evidence.typed?.v == 1, "the record body has text \"\" plus typed{v,digest,words}")
    try check(try store.typedCounts() == (1, 0), "one sealed row in typed_text")
    let ringAfter = try JSONSerialization.jsonObject(with: keys.raw ?? Data()) as? [String: Any] ?? [:]
    try check((ringAfter["keys"] as? [String: String])?.keys.sorted() == [TypedTextVault.epoch(for: now)], "the first seal of a UTC day adds that day's key")
    try check(try store.hydrateTypedText("t1", disclosure: .owner, now: now) == "pricing page ships Friday", "the owner opens the exact words")
    try check(try store.hydrateTypedText("t1", disclosure: .summary, now: now) == nil, "summary disclosure never opens words")
    try check(try !(json(store.action("t1", now: now))).contains("pricing") && !(json(item)).contains("pricing"), "actions and summaries carry no words")
    try check(try store.action("t1", now: now)?.description == "Typed a draft in Notes (a sentence).", "the action says where and about how much")
    try check(try store.timeline(query: "pricing", now: now).isEmpty && store.searchResult(MemorySearchQuery("pricing"), now: now).items.isEmpty, "typed words are in no search")

    // Insert once.
    try check(try !store.ingest(typed("t1", "pricing page ships Friday"), now: now), "the same typed row is not saved twice")
    try check(try !store.ingest(typed("t1", "a different sentence entirely"), now: now), "a typed row is never re-sealed with new words")
    try check(try store.hydrateTypedText("t1", disclosure: .owner, now: now) == "pricing page ships Friday" && store.typedCounts() == (1, 0), "the first words stay")
    try check(try !store.ingest(typed("t-window", "late words for a metadata id"), now: now) && store.typedCounts() == (1, 0), "typed words never attach to an existing record")

    // A caller can't forge a pointer.
    var forged = Evidence(id: "t-forged", at: iso(now), kind: "window.changed", app: "Notes", bundle: "com.apple.Notes", title: "Forged", synthetic: true)
    forged.typed = TypedRef(digest: String(repeating: "0", count: 64), words: 9)
    try check(try store.ingest(forged, now: now) && store.read("t-forged", now: now)?.evidence.typed == nil, "a typed pointer from a caller is dropped")

    // Word buckets, never exact lengths.
    try check(TypedWords.bucket(1) == "a few words" && TypedWords.bucket(3) == "a few words" && TypedWords.bucket(4) == "a sentence" && TypedWords.bucket(15) == "a sentence"
              && TypedWords.bucket(16) == "about 20 words" && TypedWords.bucket(44) == "about 40 words" && TypedWords.bucket(60) == "about 60 words" && TypedWords.bucket(61) == "a long passage", "word buckets")
    try check(TypedWords.bucket(fromDescription: "Typed a draft in Notes (a sentence).", app: "Notes") == "a sentence" && TypedWords.bucket(fromDescription: "Typed a draft in Notes (pricing page).", app: "Notes") == nil, "only real buckets parse")

    // A reader process (CLI, MCP) has no key.
    let reader = try MemoryStore(home: home)
    try check(reader.typedVaultState == .unavailable && (try reader.hydrateTypedText("t1", disclosure: .owner, now: now)) == nil, "a reader process never opens words")
    var refused = false; do { _ = try reader.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore())) } catch { refused = true }
    try check(refused, "a read-only store never takes a vault")
    try check(TypedTextVault.unavailable().state == .unavailable, "a vault without a key store is unavailable")

    // Typing off keeps the sealed words but withholds them.
    consent.captureText = false; try store.updatePolicy(consent, now: now)
    try check(try store.hydrateTypedText("t1", disclosure: .owner, now: now) == nil && store.typedCounts() == (1, 0), "typing off withholds kept words")
    consent.captureText = true; try store.updatePolicy(consent, now: now)

    // Locked Keychain: nothing sealed, nothing opened, nothing lost.
    keys.locked = true
    try check(try store.reconcileTypedVault(now: now) == .locked && !store.typingUnlocked, "a locked Keychain locks typing")
    try check(throwsLocked { try store.ingest(typed("t-locked", "while locked words"), now: now) } == .locked && store.read("t-locked", now: now) == nil, "locked: typed text is refused, nothing written")
    try check(try store.hydrateTypedText("t1", disclosure: .owner, now: now) == nil && store.typedCounts() == (1, 0), "locked: words unavailable but kept")
    var setUpRefused = false; do { try store.setUpTypedVault(now: now) } catch { setUpRefused = true }
    try check(setUpRefused && keys.saves == 2, "locked: turning typing on never makes a new key")
    keys.locked = false
    try check(try store.reconcileTypedVault(now: now) == .ready && store.hydrateTypedText("t1", disclosure: .owner, now: now) == "pricing page ships Friday", "unlocking brings the same words back")

    // Deleting a record deletes its sealed words.
    try check(try store.ingest(typed("t-delete", "delete me please now"), now: now) && store.typedCounts() == (2, 0), "second row sealed")
    try store.delete("t-delete")
    try check(try store.typedCounts() == (1, 0) && store.hydrateTypedText("t-delete", disclosure: .owner, now: now) == nil, "delete removes the sealed words")

    // Two days, two keys; one day's key lost: only that day's words go.
    let yesterday = now.addingTimeInterval(-86400)
    try check(try store.ingest(typed("t-y", "yesterday draft about budgets", at: yesterday), now: now), "yesterday's row sealed")
    var raw = try JSONSerialization.jsonObject(with: keys.raw ?? Data()) as? [String: Any] ?? [:]
    var dayKeys = raw["keys"] as? [String: String] ?? [:]
    try check(dayKeys.count == 2 && Set(dayKeys.values).count == 2, "each UTC day has its own key")
    dayKeys.removeValue(forKey: TypedTextVault.epoch(for: yesterday)); raw["keys"] = dayKeys
    keys.raw = try JSONSerialization.data(withJSONObject: raw)
    try check(try store.reconcileTypedVault(now: now) == .ready, "a missing day key keeps the vault ready")
    try check(try store.typedAfter("t-y")?.source == "key-lost" && store.typedAfter("t-y")?.summary == "" && store.typedAfter("t-y")?.words == 4, "that day's row becomes a key-lost stub")
    try check(try store.hydrateTypedText("t1", disclosure: .owner, now: now) == "pricing page ships Friday" && store.typedKeyLostRowCount() == 1, "other days still open; the loss is counted")
    try check(try store.read("t-y", now: now)?.evidence.typed?.words == 4, "the record survives with its word count")

    // Whole keyring lost: every row becomes a stub; no new key appears quietly.
    keys.raw = nil
    try check(try store.reconcileTypedVault(now: now) == .keyLost && keys.raw == nil, "a missing keyring with sealed words is keyLost, never a new key")
    try check(try store.typedCounts() == (0, 2) && store.typedAfter("t1")?.source == "key-lost" && store.typedKeyLostNotice(), "every sealed row moves to a key-lost stub")
    try check(throwsLocked { try store.ingest(typed("t-after-loss", "after the loss"), now: now) } == .keyLost, "keyLost refuses new typed text")
    try check(try store.reconcileTypedVault(now: now) == .keyLost && keys.raw == nil, "keyLost stays keyLost across launches")
    try store.setUpTypedVault(now: now)
    try check(store.typedVaultState == .ready && keys.raw != nil && (try !store.typedKeyLostNotice()), "only turning typing on again makes a new key")
    try check(try store.hydrateTypedText("t1", disclosure: .owner, now: now) == nil && store.typedAfter("t1") != nil, "the lost words stay gone")

    // A corrupt keyring is a lost keyring.
    let other = try MemoryStore(home: home.appendingPathComponent("corrupt"), writable: true, automaticallySyncSearch: false)
    try other.updatePolicy(consent, now: now)
    let otherKeys = try attachTestVault(other)
    _ = try other.ingest(typed("c1", "corrupt keyring words"), now: now)
    otherKeys.raw = Data("{\"version\":1,\"keys\":{\"x\":\"short\"},\"mac\":\"\"}".utf8)
    try check(try other.reconcileTypedVault(now: now) == .keyLost && other.typedAfter("c1")?.source == "key-lost", "an unreadable keyring counts as lost")
}
