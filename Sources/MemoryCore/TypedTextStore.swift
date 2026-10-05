import Foundation
import CryptoKit

/// The pointer a typed row's record body keeps instead of the words:
/// `{v, digest, words}`. `digest` is the SHA-256 of the sealed bytes (random
/// looking ciphertext), so record, action and note revisions never hash the
/// words. An empty digest means no sealed copy was ever kept (a stub).
public struct TypedRef: Codable, Equatable {
    public var v: Int
    public var digest: String
    public var words: Int
    public init(v: Int = 1, digest: String, words: Int) { self.v = v; self.digest = digest; self.words = words }
}

/// What survives once the exact words are gone. `summary` "" means stub only.
/// `source`: "note" | "stub" | "key-lost" | "forgotten".
public struct TypedAfter: Codable, Equatable {
    public var id: String
    public var words: Int
    public var summary: String
    public var source: String
    public var endedAt: String
}

/// Website typing's rules for its own rows, in the owner build only (the
/// Chrome typing file's `WebsiteTypingRowRules`). Every other build has none
/// and never writes a website row.
protocol WebsiteTypingRows: Sendable {
    /// The ingest check (`TypedTextPolicy.permitsWebsiteRow`).
    func permits(_ e: Evidence, typed: TypedTextPolicy, settings: PrivacySettings) -> Bool
    /// Whether a row an earlier build saved may stay (`settleWebsiteTypingRows`).
    func keeps(_ e: Evidence, typed: TypedTextPolicy) -> Bool
}

/// Who is asking for the words. Only `hydrateTypedText` opens them.
/// - owner: the DayDream app itself.
/// - summary: an AI app without an exact-words grant (the default). Never words.
/// - exact: an AI app the person allowed to see exact words; opens only with
///   that app's `TypedReader`, whose `typed-exact` grant MAC verifies here.
/// - localWriter: the note writer on this Mac; opens while typing is on
///   (switch on, safe-typing consent, key ready).
/// - cloudWriter: a cloud note writer; opens only while Cloud is the chosen writer (typedDisclosureAllows).
public enum TypedDisclosure: String {
    case owner, summary, exact, localWriter, cloudWriter
    /// claude/summary-1003 (owner decision 2026-10-03): a connected AI app reading through the app's bridge while
    /// "Let AI apps read what you typed" is on (`AssistantTypedRead.swift`; the bridge checks the grant and the setting).
    case assistant
}

/// Word counts shown as buckets, never as exact lengths.
public enum TypedWords {
    public static func count(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
    public static func bucket(_ words: Int) -> String {
        switch words {
        case ..<4: return "a few words"
        case 4...15: return "a sentence"
        case 16...60: return "about \(max(20, Int((Double(words) / 10).rounded()) * 10)) words"
        default: return "a long passage"
        }
    }
    static let draftPrefix = "Typed a draft in "
    /// Canonical action description for a sealed row: no words, a bucket only.
    public static func actionDescription(app: String, words: Int) -> String {
        "\(draftPrefix)\(app) (\(bucket(words)))."
    }
    /// summaries/v3 (spec §2): a unit whose send key was detected. Never says "sent" (that needs a delivery receipt).
    public static func submittedDescription(app: String, words: Int) -> String {
        "Typed in \(app), then used its send key (\(bucket(words)))."
    }
    /// terminal-1002: a terminal unit sealed by Return (surface "code", send detected): the shell ran it. No words.
    public static func ranDescription(app: String, words: Int) -> String {
        "\(ranPrefix)\(app) (\(bucket(words)))."
    }
    /// The card label for a run command (claude/ui-nav-1002 groups terminal rows in one card per app).
    public static let ranCommandLabel = "Ran a command"
    static let ranPrefix = "Ran a command in "
    /// fix/chrome-capture: a unit after which DayDream proved a click on the composer's own Post or Reply button
    /// (`sendBy` "button"). A send gesture, like a send key; never "sent" (that needs a delivery receipt).
    public static func buttonDescription(app: String, control: String, words: Int) -> String {
        "Typed in \(app), then clicked its \(controlName(control)) button (\(bucket(words)))."
    }
    /// The button's name as shown on the site, from the fixed list only; anything else is "send".
    public static func controlName(_ control: String?) -> String {
        switch control { case "post": return "Post"; case "reply": return "Reply"; case "post all": return "Post all"; default: return "send" }
    }
    static let controlNames = ["Post", "Reply", "Post all", "send"]
    /// The bucket inside `actionDescription`, `submittedDescription` or `buttonDescription`, or nil for any other text.
    public static func bucket(fromDescription description: String, app: String) -> String? {
        let suffix = ")."
        let prefixes = ["\(draftPrefix)\(app) (", "Typed in \(app), then used its send key (", "\(ranPrefix)\(app) ("] + controlNames.map { "Typed in \(app), then clicked its \($0) button (" }
        guard let prefix = prefixes.first(where: description.hasPrefix),
              description.hasSuffix(suffix), description.count > prefix.count + suffix.count else { return nil }
        let inner = String(description.dropFirst(prefix.count).dropLast(suffix.count))
        return inner == "a few words" || inner == "a sentence" || inner == "a long passage" || inner.range(of: "^about [0-9]+ words$", options: .regularExpression) != nil ? inner : nil
    }
}

private struct TypedVaultNotice: Codable {
    var keyLost = false
    var keyLostRows = 0
}

func sealedDigest(_ sealed: Data) -> String {
    SHA256.hash(data: sealed).map { String(format: "%02x", $0) }.joined()
}

extension MemoryStore {
    func setupTypedTables() throws {
        // No indexes: the canonical backup allows listed tables only.
        try exec("CREATE TABLE IF NOT EXISTS typed_text(id TEXT PRIMARY KEY, epoch TEXT NOT NULL, sealed TEXT NOT NULL, words INTEGER NOT NULL, created_at TEXT NOT NULL)")
        try exec("CREATE TABLE IF NOT EXISTS typed_after(id TEXT PRIMARY KEY, words INTEGER NOT NULL, summary TEXT NOT NULL, source TEXT NOT NULL, ended_at TEXT NOT NULL)")
        // fix/r1-writer: the name typed in Mail's To field, sealed like the words and kept only while they are.
        try exec("CREATE TABLE IF NOT EXISTS typed_recipients(id TEXT PRIMARY KEY, epoch TEXT NOT NULL, sealed TEXT NOT NULL)")
    }
    func hasTypedRecipients() throws -> Bool {
        try !rows("SELECT name FROM sqlite_master WHERE type='table' AND name='typed_recipients'").isEmpty
    }
    /// fix/r1-writer: the recipient of these typed rows goes with their words (expiry, Forget, deletion, a lost key).
    func dropTypedRecipients(_ ids: [String]) throws {
        guard !ids.isEmpty, try hasTypedRecipients() else { return }
        try exec("DELETE FROM typed_recipients WHERE id IN (SELECT value FROM json_each(?))", [json(ids)])
    }
    /// A recipient whose words are gone, whatever removed them, goes too.
    func dropOrphanTypedRecipients() throws {
        guard try hasTypedRecipients() else { return }
        try exec("DELETE FROM typed_recipients WHERE id NOT IN (SELECT id FROM typed_text)")
    }
    static func recipientSealID(_ id: String) -> String { id + "|to" }
    /// fix/r1-writer: an email unit's recipient (`unit.to`, a name the person typed in Mail's To field) is never kept in
    /// the record. With the words sealed it is sealed beside them, under the same day key; otherwise it is dropped.
    func sealTypedRecipientWithinTransaction(_ e: inout Evidence, epoch: String?) throws {
        guard e.captureProvenance?.unit?.surface == "email", let to = e.captureProvenance?.unit?.to else { return }
        e.captureProvenance?.unit?.to = nil
        guard let epoch, !to.isEmpty, try hasTypedRecipients(), let vault = attachedVault, vault.state == .ready else { return }
        let sealed = try vault.seal(to, id: Self.recipientSealID(e.id), epoch: epoch)
        try exec("INSERT OR REPLACE INTO typed_recipients VALUES(?,?,?)", [e.id, epoch, sealed.base64EncodedString()])
    }
    /// The recipient sealed for a typed email row, while its words are kept (typing on, the row not past the kept
    /// period, a ready key). The caller decides who may see it.
    /// `forGuard`: for the verbatim guard only (in memory, never shown), also while typing is off or the period ends.
    func typedRecipient(_ id: String, now: Date = Date(), forGuard: Bool = false) throws -> String? {
        guard try hasTypedRecipients(), let vault = attachedVault, vault.state == .ready, try forGuard || policy().captureText,
              let row = try rows("SELECT r.epoch,r.sealed,t.created_at FROM typed_recipients r JOIN typed_text t ON t.id=r.id WHERE r.id=?", [id]).first,
              try forGuard || !typedExpired(createdAt: row[2], now: typedClock(now)),
              let sealed = Data(base64Encoded: row[1]) else { return nil }
        return try? vault.open(sealed, id: Self.recipientSealID(id), epoch: row[0])
    }
    func hasTypedTables() throws -> Bool {
        try rows("SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('typed_text','typed_after')").first?.first == "2"
    }

    /// ready only when an attached vault can seal and open right now.
    public var typedVaultState: TypedVaultState { attachedVault?.state ?? .unavailable }
    /// The single "may typed words be saved" answer for capture.
    public var typingUnlocked: Bool { typedVaultState == .ready }

    private func notice() throws -> TypedVaultNotice {
        guard let raw = try rows("SELECT body FROM metadata WHERE id='typed-vault-v1'").first?.first else { return TypedVaultNotice() }
        return (try? decode(TypedVaultNotice.self, raw)) ?? TypedVaultNotice()
    }
    private func saveNotice(_ value: TypedVaultNotice) throws {
        try exec("INSERT OR REPLACE INTO metadata VALUES('typed-vault-v1',?)", [json(value)])
    }
    /// True when the key was lost and typing has not been turned on again.
    public func typedKeyLostNotice() throws -> Bool { try notice().keyLost }
    /// Diagnostics: how many rows lost their words to a missing or bad key. A count only.
    public func typedKeyLostRowCount() throws -> Int { try notice().keyLostRows }

    /// Reads the keyring again and repairs what it finds, in one transaction:
    /// - no readable keyring while words exist: every row becomes a
    ///   `typed_after(source:"key-lost")` stub; no new key is made;
    /// - ready: any row whose day key is missing or that fails to open becomes
    ///   a key-lost stub (counted, never logged).
    /// perf2-1005: while typing, the typing key's Keychain item is read ahead off the main thread
    /// (`TypedTextVault.prefetch`), so the seal at commit needn't read it there.
    public func prefetchTypedKey() { attachedVault?.prefetch() }

    @discardableResult public func reconcileTypedVault(now: Date = Date()) throws -> TypedVaultState {
        lock.lock(); defer { lock.unlock() }
        guard let vault = attachedVault else { return .unavailable }
        guard writable, try hasTypedTables() else { return vault.refresh(hadWords: false) }
        // A "Forget what I typed" made without a key finishes here.
        try retryPendingTypedForget()
        let sealedCount = Int(try rows("SELECT count(*) FROM typed_text").first?.first ?? "0") ?? 0
        let lostBefore = try notice().keyLost
        let state = vault.refresh(hadWords: sealedCount > 0 || lostBefore)
        if state == .keyLost && sealedCount > 0 {
            try transaction {
                var value = try notice()
                for row in try rows("SELECT id FROM typed_text") { try moveTypedToAfterWithinTransaction(row[0], summary: "", source: "key-lost", now: now) }
                value.keyLost = true; value.keyLostRows += sealedCount
                try saveNotice(value)
                try invalidateDisclosure(invalidateSnapshots: false)
            }
        } else if state == .ready && sealedCount > 0 {
            var lost = [String]()
            for row in try rows("SELECT id,epoch,sealed FROM typed_text") {
                guard let sealed = Data(base64Encoded: row[2]), (try? vault.open(sealed, id: row[0], epoch: row[1])) != nil else { lost.append(row[0]); continue }
            }
            if !lost.isEmpty {
                try transaction {
                    for id in lost { try moveTypedToAfterWithinTransaction(id, summary: "", source: "key-lost", now: now) }
                    var value = try notice(); value.keyLostRows += lost.count; try saveNotice(value)
                    try invalidateDisclosure(invalidateSnapshots: false)
                }
            }
        }
        return vault.state
    }

    /// A locked Keychain (the Mac was locked, or the item couldn't be read
    /// without a prompt) leaves the vault `.locked` until the keyring is read
    /// again. The app calls this after an unlock, on app activation, from the
    /// hourly job and from Settings' "Try again". Does nothing in any other state.
    @discardableResult public func retryLockedTypedVault(now: Date = Date()) throws -> TypedVaultState {
        guard typedVaultState == .locked else { return typedVaultState }
        return try reconcileTypedVault(now: now)
    }

    /// "Turn on typing": creates the keyring when there is none. Never runs
    /// over a readable keyring, a locked Keychain, or sealed words it can't open.
    public func setUpTypedVault(now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        guard writable, let vault = attachedVault else { throw TypedTextError.cannotSetUp(.unavailable) }
        let state = try reconcileTypedVault(now: now)
        if state == .ready { return }
        guard state == .notSetUp || state == .keyLost,
              try rows("SELECT id FROM typed_text LIMIT 1").isEmpty else { throw TypedTextError.cannotSetUp(state) }
        try vault.create()
        var value = try notice(); if value.keyLost { value.keyLost = false; try saveNotice(value) }
        // Settings saved before the key existed are signed now (only the ones
        // that don't widen what is kept or shared). A keyring adopted from
        // another vault may already verify the row; then nothing changes.
        try signTypedPolicyAfterSetUp()
    }

    /// Inside ingest's transaction. Seals `e.text` into `typed_text` and leaves
    /// the record with `text:""` and a `typed` pointer. Returns false (nothing
    /// written) when this id was saved before: typed words are saved once.
    /// Throws, with nothing written, when the vault isn't ready.
    func sealTypedWithinTransaction(_ e: inout Evidence, now: Date) throws -> Bool {
        guard try hasTypedTables() else { throw TypedTextError.typingLocked(.unavailable) }
        guard try rows("SELECT id FROM typed_text WHERE id=? UNION ALL SELECT id FROM typed_after WHERE id=? UNION ALL SELECT id FROM records WHERE id=?", [e.id, e.id, e.id]).isEmpty else { return false }
        guard let vault = attachedVault, vault.state == .ready else { throw TypedTextError.typingLocked(attachedVault?.state ?? .unavailable) }
        // The effective switch again, in the store: words only after the
        // safe-typing screen was accepted (consent v2).
        guard try typedTextPolicy().consented else { throw TypedTextError.notAccepted }
        guard let at = timestamp(e.at) else { return false }
        let epoch = TypedTextVault.epoch(for: at), words = TypedWords.count(e.text)
        // Already past the kept period when it arrives: the words are never
        // written, sealed or not; a stub stays.
        if try typedCutoff(now: typedClock(now)).map({ at < $0 }) ?? false {
            try exec("INSERT INTO typed_after VALUES(?,?,?,?,?)", [e.id, String(words), "", "stub", iso(now)])
            e.text = ""
            e.typed = TypedRef(digest: "", words: words)
            try sealTypedRecipientWithinTransaction(&e, epoch: nil)
            return true
        }
        let sealed = try vault.seal(e.text, id: e.id, epoch: epoch)
        try exec("INSERT INTO typed_text VALUES(?,?,?,?,?)", [e.id, epoch, sealed.base64EncodedString(), String(words), e.at])
        try sealTypedRecipientWithinTransaction(&e, epoch: epoch)
        e.text = ""
        e.typed = TypedRef(digest: sealedDigest(sealed), words: words)
        return true
    }

    /// Defence in depth for the capture binding's deny-only exclusions: any
    /// `keyboard.text_input` row (with or without words) is refused when its
    /// app is not permitted by the category policy and the release gate
    /// (`TypedTextPolicy.permits`), or while "Don't record typing" runs.
    func typedIngestPermitted(_ e: Evidence, now: Date) throws -> Bool {
        let typed = try typedTextPolicy()
        guard !typed.snoozed(now: now) else { return false }
        // Owner build: website typing rows follow the site rules instead of the app table.
        if e.bundle == BrowserSafety.supportedBundle, let web = Self.websiteRows { return web.permits(e, typed: typed, settings: try policy()) }
        return typed.permits(bundle: e.bundle, blockedApps: try policy().blockedApps)
    }

    #if DAYDREAM_OWNER_TYPING
    static let websiteRows: (any WebsiteTypingRows)? = WebsiteTypingRowRules()
    #else
    /// Website typing's rules for its own rows: only the owner build has them.
    static let websiteRows: (any WebsiteTypingRows)? = nil
    #endif
    static let websiteSettleID = "typed-web-settle-v1"
    /// The one-time settle below is done (its mark is in the history). Builds without website typing never settle.
    func websiteRowsSettled() -> Bool {
        !((try? rows("SELECT 1 FROM metadata WHERE id=?", [Self.websiteSettleID])) ?? []).isEmpty
    }

    /// Once, at launch (typingfix, owner/v1 review F1 follow-up): website
    /// typing rows an earlier owner build saved that this build would never
    /// have saved and whose switch is still off (`WebsiteTypingRows.keeps`:
    /// a messaging site while Messages and email is off) are deleted with
    /// their words, stub, summary and the notes and writer requests that
    /// cite them. Later rows and later switch changes are left alone. Builds
    /// without website typing do nothing and leave no mark.
    @discardableResult public func settleWebsiteTypingRows(now: Date = Date()) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard writable, let web = Self.websiteRows, try hasTypedTables(),
              try rows("SELECT id FROM metadata WHERE id=?", [Self.websiteSettleID]).isEmpty else { return 0 }
        let typed = try typedTextPolicy()
        let refused = try rows("SELECT id,body FROM records WHERE json_extract(body,'$.kind')='keyboard.text_input' AND json_extract(body,'$.bundle')=? ORDER BY id",
                               [BrowserSafety.supportedBundle]).compactMap { row -> String? in
            guard let e = try? decode(Evidence.self, row[1]), e.id == row[0] else { return nil }
            return web.keeps(e, typed: typed) ? nil : row[0]
        }
        try transaction {
            for id in refused {
                try dropTypedDerivatives(id)
                try deleteActionWithinTransaction(id)
                try deleteTypedWithinTransaction(id)
            }
            try exec("INSERT OR REPLACE INTO metadata VALUES(?,?)", [Self.websiteSettleID, json(["settledAt": iso(now), "deleted": String(refused.count)])])
            if !refused.isEmpty { try exec("DELETE FROM receipts"); try invalidateDisclosure() }
        }
        if !refused.isEmpty { scheduleSearchRefresh() }
        return refused.count
    }

    /// The only way to get typed words back. nil for `.summary`, for `.exact`
    /// without a verified exact-words grant for `reader`, for the cloud writer,
    /// for the local writer without safe-typing consent, without a ready vault (every MCP/CLI
    /// process), while typing is off, for deleted, hidden or blocked records,
    /// and when the sealed row doesn't match the record's digest.
    public func hydrateTypedText(_ id: String, disclosure: TypedDisclosure, reader: TypedReader? = nil, now: Date = Date()) throws -> String? {
        guard try typedDisclosureAllows(disclosure, reader: reader), let vault = attachedVault, vault.state == .ready, try hasTypedTables(),
              // Typing off withholds kept words from every read, as before.
              try policy().captureText,
              let original = try permittedOriginal(id, now: now), let ref = original.typed, !ref.digest.isEmpty,
              let row = try rows("SELECT epoch,sealed,created_at FROM typed_text WHERE id=?", [id]).first,
              // Safe typing D: hidden the moment the kept period ends, even
              // before the expiry job deletes them.
              try !typedExpired(createdAt: row[2], now: typedClock(now)),
              let sealed = Data(base64Encoded: row[1]), sealedDigest(sealed) == ref.digest else { return nil }
        return try? vault.open(sealed, id: id, epoch: row[0])
    }

    /// What is kept after the words are gone, if they are.
    public func typedAfter(_ id: String) throws -> TypedAfter? {
        guard try hasTypedTables(), let row = try rows("SELECT id,words,summary,source,ended_at FROM typed_after WHERE id=?", [id]).first else { return nil }
        return TypedAfter(id: row[0], words: Int(row[1]) ?? 0, summary: row[2], source: row[3], endedAt: row[4])
    }
    /// Counts for checks and diagnostics.
    public func typedCounts() throws -> (sealed: Int, after: Int) {
        guard try hasTypedTables() else { return (0, 0) }
        let row = try rows("SELECT (SELECT count(*) FROM typed_text),(SELECT count(*) FROM typed_after)").first ?? ["0", "0"]
        return (Int(row[0]) ?? 0, Int(row[1]) ?? 0)
    }

    /// fix/r1-writer: how many sealed Mail recipients are kept (checks and diagnostics; never the names).
    public func typedRecipientCount() throws -> Int {
        guard try hasTypedRecipients() else { return 0 }
        return Int(try rows("SELECT count(*) FROM typed_recipients").first?.first ?? "0") ?? 0
    }

    func moveTypedToAfterWithinTransaction(_ id: String, summary: String, source: String, now: Date) throws {
        try exec("INSERT OR REPLACE INTO typed_after SELECT id,words,?,?,? FROM typed_text WHERE id=?", [summary, source, iso(now), id])
        try exec("DELETE FROM typed_text WHERE id=?", [id])
        try dropTypedRecipients([id])
    }
    /// Deleting a record deletes its sealed words and its stub.
    func deleteTypedWithinTransaction(_ id: String) throws {
        guard try hasTypedTables() else { return }
        try exec("DELETE FROM typed_text WHERE id=?", [id])
        try exec("DELETE FROM typed_after WHERE id=?", [id])
        try dropTypedRecipients([id])
    }
    /// Notes and writer requests that cite these typed rows.
    func dropTypedDerivatives(_ id: String) throws {
        try exec("DELETE FROM summaries WHERE id=?", [id])
        guard try hasActionLayers() else { return }
        try exec("UPDATE note_requests SET state='invalidated',body='' WHERE body<>'' AND EXISTS (SELECT 1 FROM json_each(note_requests.body,'$.actionIDs') WHERE value=?)", [id])
        try exec("DELETE FROM generated_notes WHERE EXISTS (SELECT 1 FROM json_each(generated_notes.body,'$.actionIDs') WHERE value=?)", [id])
    }
    /// True when any of these ids is a typed row (sealed, stubbed or pointed to).
    func citesTypedText(_ ids: [String]) throws -> Bool {
        guard !ids.isEmpty else { return false }
        return try !rows("SELECT id FROM records WHERE json_extract(body,'$.typed') IS NOT NULL AND id IN (SELECT value FROM json_each(?)) LIMIT 1", [json(ids)]).isEmpty
    }

    /// Build 4 wrote typed words into `records.body` in plain text. In one
    /// transaction every such row is either sealed (`seal: true`, needs a ready
    /// vault) or reduced to a stub (`seal: false`, the words are deleted). Its
    /// body becomes `text:""` plus `typed`; its summary, the writer requests and
    /// the notes that cite it are removed (notes regenerate once); an imported
    /// original holding the words is removed. `secure_delete` zeroes old cells.
    /// Rows already past the kept period go straight to a stub, sealed or not.
    /// The scrubber runs as on ingest (and its provenance rule: a withheld
    /// secret clears the key and edit counts).
    @discardableResult public func migrateLegacyTypedText(seal: Bool, now: Date = Date()) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard writable, try hasTypedTables() else { throw MemError.denied }
        if seal { guard let vault = attachedVault, vault.state == .ready else { throw TypedTextError.typingLocked(typedVaultState) } }
        let cutoff = try typedCutoff(now: typedClock(now))
        return try settleLegacyTypedText(seal: seal, before: nil, cutoff: cutoff, now: now)
    }

    /// The launch rule for build 4 plain-text rows (SPEC 2.6, as decided):
    /// sealed when typing is on with a ready key and the safe-typing screen
    /// was accepted; otherwise the words are deleted at once and stubs stay.
    /// Words are never kept in plain text past the first launch of this build.
    @discardableResult public func settleLegacyTypedText(now: Date = Date()) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard writable, try hasTypedTables() else { return 0 }
        let sealing = try typingUnlocked && typedTextPolicy().consented && policy().captureText
        return try migrateLegacyTypedText(seal: sealing, now: now)
    }

    /// The expiry job's part for build 4 rows: only rows typed before `cutoff`
    /// become stubs. Needs no key, so every process can run it.
    func stubLegacyTypedText(before cutoff: Date, now: Date) throws -> Int {
        try settleLegacyTypedText(seal: false, before: cutoff, cutoff: cutoff, now: now)
    }

    private func settleLegacyTypedText(seal: Bool, before: Date?, cutoff: Date?, now: Date) throws -> Int {
        // perf2-1005 (owner 10/04, slow open): a history with no build 4 plain-text row (every history since) is found so
        // with a read, not a write transaction: launch no longer waits on the main thread for another connection's lock
        // (up to 1.5 s) to learn there is nothing to settle.
        if try rows("SELECT 1 FROM records WHERE json_extract(body,'$.kind')='keyboard.text_input' AND coalesce(json_extract(body,'$.text'),'')<>'' AND json_extract(body,'$.typed') IS NULL LIMIT 1").isEmpty {
            legacyTypedClear = true
            return 0
        }
        var scannedEmpty = false
        let changed = try transaction { () -> Int in
            let legacy = try rows("SELECT id,body FROM records WHERE json_extract(body,'$.kind')='keyboard.text_input' AND coalesce(json_extract(body,'$.text'),'')<>'' AND json_extract(body,'$.typed') IS NULL ORDER BY id")
            scannedEmpty = legacy.isEmpty
            var count = 0
            for row in legacy {
                var e = try decode(Evidence.self, row[1])
                guard e.id == row[0] else { throw MemError.invalid("Typed record id mismatch") }
                let at = timestamp(e.at)
                if let before, let at, at >= before { continue }
                guard try rows("SELECT id FROM typed_text WHERE id=? UNION ALL SELECT id FROM typed_after WHERE id=?", [e.id, e.id]).isEmpty else { throw MemError.invalid("Typed record already has sealed words") }
                // The same store-side scrubber as ingest: a row that is only a
                // secret keeps a stub, never a sealed copy.
                let scrubbed = TypedSecretScrubber.scrubbed(e)
                let words = TypedWords.count(scrubbed?.text ?? e.text)
                let expired = at.map { time in cutoff.map { time < $0 } ?? false } ?? true
                if seal, !expired, let vault = attachedVault, var kept = scrubbed {
                    let epoch = TypedTextVault.epoch(for: at ?? now)
                    let sealed = try vault.seal(kept.text, id: kept.id, epoch: epoch)
                    try exec("INSERT INTO typed_text VALUES(?,?,?,?,?)", [kept.id, epoch, sealed.base64EncodedString(), String(words), kept.at])
                    kept.typed = TypedRef(digest: sealedDigest(sealed), words: words)
                    e = kept
                } else {
                    try exec("INSERT INTO typed_after VALUES(?,?,?,?,?)", [e.id, String(words), "", "stub", iso(now)])
                    if let scrubbed { e.captureProvenance = scrubbed.captureProvenance }
                    e.typed = TypedRef(digest: "", words: words)
                }
                e.text = ""
                let body = try json(e)
                try exec("UPDATE records SET body=?,revision=? WHERE id=?", [body, fingerprint(body), e.id])
                try dropTypedDerivatives(e.id)
                try purgeMigrationOriginal(e.id)
                count += 1
            }
            if count > 0 { try invalidateDisclosure() }
            return count
        }
        // Review G59: the launch settle (`before` nil) handles every row; any settle that found none leaves none.
        // New rows are always sealed or refused at ingest, so the hourly expiry need not scan for them again.
        if before == nil || scannedEmpty { legacyTypedClear = true }
        if changed > 0 { scheduleSearchRefresh() }
        return changed
    }
}
