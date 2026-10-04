import Foundation
import CryptoKit
import PrivacyPolicy
@testable import MemoryCore

/// Safe typing B (vault slice): crypto, raw SQLite rows and raw file bytes.
/// In-memory key stores only: no Keychain, no app, no capture, no network.
@main struct TypedStoreChecks {
    static var count = 0
    static func check(_ value: Bool, _ label: String) { precondition(value, "FAILED: " + label); count += 1; print("PASS " + label) }
    static func rejects(_ label: String, _ work: () throws -> Void) { do { try work(); fatalError("FAILED: " + label) } catch { check(true, label) } }
    /// Refused for the stated reason (so a refusal for any other reason can't pass).
    static func rejects(_ label: String, saying: String, _ work: () throws -> Void) {
        do { try work(); fatalError("FAILED: " + label) } catch { let ok = String(describing: error).contains(saying); check(ok, ok ? label : label + " (refused for another reason: \(error))") }
    }
    static func openFails(_ vault: TypedTextVault, _ sealed: Data, _ id: String, _ epoch: String) -> Bool {
        do { _ = try vault.open(sealed, id: id, epoch: epoch); return false } catch { return (error as? TypedTextError) == .openFailed }
    }
    /// Every file under `root`, raw bytes, searched for each needle as UTF-8
    /// and UTF-16 (little and big endian).
    static func filesContain(_ root: URL, _ needles: [String]) throws -> [String] {
        var found = [String]()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let data = try Data(contentsOf: file)
            for needle in needles {
                let forms = [Data(needle.utf8), needle.data(using: .utf16LittleEndian)!, needle.data(using: .utf16BigEndian)!]
                if forms.contains(where: { data.range(of: $0) != nil }) { found.append(file.lastPathComponent + ":" + needle) }
            }
        }
        return found
    }

    static func main() throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("typed-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try vaultCrypto()
        try storeBytes(root)
        try scrubberBeforeSeal(root)
        try retentionBytes(root)
        try keyringSharing(root)
        try reviewFixes(root)
        print("PASS \(count) typed store checks. In-memory keys only; no Keychain, app, capture or network.")
    }

    // MARK: Scrubber (safe typing C) before the seal

    /// The store-side scrubber runs before sealing: the sealed plaintext
    /// itself (opened here with the vault, below the store API) never holds
    /// the secret, dropped units leave no row, the build 4 migration scrubs
    /// too, and no secret is in any database file byte.
    static func scrubberBeforeSeal(_ root: URL) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let home = root.appendingPathComponent("scrub")
        var store: MemoryStore? = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        var policy = try store!.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try store!.updatePolicy(policy, now: now)
        try store!.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore()), now: now); try store!.setUpTypedVault(now: now); try store!.acceptSafeTyping(now: now)
        func typed(_ id: String, _ text: String) -> Evidence {
            // TextEdit: only Notes and TextEdit record typing while the release gate is closed.
            Evidence(id: id, at: iso(now), kind: "keyboard.text_input", app: "TextEdit", bundle: "com.apple.TextEdit", title: "zsh", text: text, synthetic: true)
        }
        let token = "ghp_" + String(repeating: "Q7x", count: 12)
        let kept: [(String, String, [String])] = [
            ("k-token", "deploy with \(token) today", [token, "Q7xQ7x"]),
            ("k-card", "card 4111 1111 1111 1111 please", ["4111 1111", "41111111"]),
            ("k-sudo", "sudo apt update\nhunterzebra2secret\nls", ["hunterzebra2secret", "apt update"]),
            ("k-ssn", "my ssn is 123-45-6789 ok", ["123-45-6789"]),
            ("k-otp", "your verification code is 482913 thanks", ["482913"]),
            ("k-conn", "postgres://admin:Zz9pass4word@db/app now", ["Zz9pass4word"]),
        ]
        let secrets = kept.flatMap(\.2) + ["770011", "OPENSSH"]
        for (id, text, bad) in kept {
            check(try store!.ingest(typed(id, text), now: now), "scrubbed unit \(id) is saved")
            let row = try store!.rows("SELECT epoch,sealed FROM typed_text WHERE id=?", [id])[0]
            let plain = try store!.attachedVault!.open(Data(base64Encoded: row[1])!, id: id, epoch: row[0])
            check(plain.contains(TypedSecretScrubber.marker) && !bad.contains(where: plain.contains), "the sealed plaintext of \(id) holds the marker, not the secret")
        }
        check(try !store!.ingest(typed("d-lone", "770011"), now: now) && !store!.ingest(typed("d-key", "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA"), now: now), "secret-only units are dropped")
        check(try store!.rows("SELECT id FROM records WHERE id LIKE 'd-%' UNION ALL SELECT id FROM typed_text WHERE id LIKE 'd-%' UNION ALL SELECT id FROM typed_after WHERE id LIKE 'd-%'").isEmpty, "a dropped unit leaves no record, sealed row or stub")
        // Build 4 rows go through the same scrubber when sealed.
        for (id, text) in [("legacy-token", "plainlegacy \(token)"), ("legacy-lone", "770011"), ("legacy-plain", "plainlegacy harmless")] {
            var e = typed(id, text); e.at = iso(now.addingTimeInterval(5))
            let body = try json(e)
            try store!.exec("INSERT INTO records VALUES(?,?,?)", [e.id, body, fingerprint(body)])
        }
        check(try store!.migrateLegacyTypedText(seal: true, now: now) == 3, "three build 4 rows migrated")
        check(try store!.hydrateTypedText("legacy-token", disclosure: .owner, now: now) == "plainlegacy \(TypedSecretScrubber.marker)", "a build 4 row with a token is sealed scrubbed")
        check(try store!.hydrateTypedText("legacy-plain", disclosure: .owner, now: now) == "plainlegacy harmless", "a build 4 row without secrets is sealed unchanged")
        let lone = try decode(Evidence.self, store!.rows("SELECT body FROM records WHERE id='legacy-lone'")[0][0])
        check(try lone.text == "" && lone.typed?.digest == "" && store!.typedAfter("legacy-lone")?.source == "stub" && store!.rows("SELECT id FROM typed_text WHERE id='legacy-lone'").isEmpty, "a build 4 row that is only a secret keeps a stub, never a sealed copy")
        // Backups carry no scrubbed secret either.
        let target = try MemoryStore(home: root.appendingPathComponent("scrub-backup"), writable: true, automaticallySyncSearch: false)
        _ = try MemoryStore(home: home).exportCanonicalSnapshot(to: target, now: now.addingTimeInterval(40))
        check(try filesContain(target.home, secrets).isEmpty, "backup file bytes hold no scrubbed secret")
        check(try filesContain(home, ["zsh"]).count >= 1, "control: the byte scanner finds the plain window title")
        store = nil
        check(try filesContain(home, secrets).isEmpty, "no scrubbed secret in any database file byte")
    }

    // MARK: Retention (safe typing D): secure delete, crypto-shred, stable notes

    /// Expired words leave no plain text and no ciphertext in any database
    /// file byte; the day key is dropped so a stray copy of the ciphertext
    /// can't be opened; records, note revisions and committed notes stay;
    /// pending writer requests are blanked; Forget leaves nothing either.
    static func retentionBytes(_ root: URL) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), day = 86400.0
        let home = root.appendingPathComponent("retention")
        var store: MemoryStore? = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        var policy = try store!.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try store!.updatePolicy(policy, now: now)
        let keys = InMemoryTypedKeyStore(), vault = TypedTextVault(keyStore: keys)
        try store!.attachVault(vault, now: now); try store!.setUpTypedVault(now: now); try store!.acceptSafeTyping(now: now)
        func typed(_ id: String, _ text: String, at: Date) -> Evidence {
            Evidence(id: id, at: iso(at), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes", title: "Trip", text: text, synthetic: true)
        }
        let old = now.addingTimeInterval(-9 * day), oldDay = TypedTextVault.epoch(for: old)
        let expiring = [("expiring1", "quokkamarble lagoon draft for the retention check"), ("expiring2", "ibexsaffron harbour second old draft")]
        let liveWords = "narwhalcobalt fresh draft stays"
        for (index, item) in expiring.enumerated() { check(try store!.ingest(typed(item.0, item.1, at: old.addingTimeInterval(Double(index) * 60)), now: old.addingTimeInterval(120)), "old draft \(item.0) sealed") }
        // The ciphertext as a stray copy (an old SQLite page, a backup of the file) would hold it.
        let stray = try store!.rows("SELECT id,epoch,sealed FROM typed_text WHERE id LIKE 'expiring%' ORDER BY id")
        check(stray.count == 2 && stray.allSatisfy { $0[1] == oldDay }, "fixture: two sealed rows on the old day")
        _ = try store!.writePending(now: old.addingTimeInterval(180))
        check(try store!.rows("SELECT id FROM summaries WHERE id LIKE 'expiring%'").count == 2, "fixture: summaries exist for the old drafts")
        let request = try store!.prepareNote(kind: "day", day: oldDay, timezone: "UTC", now: old.addingTimeInterval(180))
        _ = try store!.commitNote(NoteWriterOutput(requestID: request.id, title: "Trip planning", bullets: [NoteBullet(text: "Planned the harbour trip", actionIDs: ["expiring1"], assertion: "draft")], generator: "fixture", generatorVersion: "1"), now: old.addingTimeInterval(180))
        let committed = try store!.rows("SELECT body FROM note_requests WHERE id=?", [request.id])[0][0]
        let layersBefore = try store!.dayLayers(day: oldDay, timezone: "UTC", now: old.addingTimeInterval(180))
        let pending = try store!.prepareNote(kind: "activity", day: oldDay, timezone: "UTC", activityID: layersBefore.activities[0].id, now: now.addingTimeInterval(-60))
        check(try store!.rows("SELECT state FROM note_requests WHERE id=?", [pending.id])[0][0] == "pending", "fixture: a pending writer request cites the old drafts")
        // The fresh draft comes last: the store's clock never runs back, so
        // anything done at the old time after "now" would already expire them.
        check(try store!.ingest(typed("live1", liveWords, at: now), now: now), "a fresh draft sealed")
        let liveSealed = try store!.rows("SELECT sealed FROM typed_text WHERE id='live1'")[0][0]
        let revisions = try store!.rows("SELECT id,revision FROM records ORDER BY id")

        let report = try store!.expireTypedText(now: now)
        check(report.expired == 2 && report.keptNotes == 1 && report.droppedKeys == [oldDay], "the job expires both old drafts and drops their day key")
        check(try store!.rows("SELECT id FROM typed_text WHERE id LIKE 'expiring%'").isEmpty, "no sealed row is left for the old drafts")
        check(try store!.rows("SELECT id,source,summary FROM typed_after ORDER BY id") == [["expiring1", "note", "Planned the harbour trip"], ["expiring2", "stub", ""]], "typed_after keeps the note bullet or an empty stub")
        check(try store!.rows("SELECT id FROM summaries WHERE id LIKE 'expiring%'").isEmpty, "their summaries rows are deleted")
        check(try store!.rows("SELECT state,body FROM note_requests WHERE id=?", [pending.id])[0] == ["invalidated", ""], "the pending writer request is blanked")
        check(try store!.rows("SELECT body FROM note_requests WHERE id=?", [request.id])[0][0] == committed, "the committed request (no writer actions) is kept, so a retry still answers")
        check(try store!.rows("SELECT id,revision FROM records ORDER BY id") == revisions, "record revisions never change on expiry")
        let layersAfter = try store!.dayLayers(day: oldDay, timezone: "UTC", now: now)
        check(layersAfter.summary.inputRevision == layersBefore.summary.inputRevision && layersAfter.activities.map(\.inputRevision) == layersBefore.activities.map(\.inputRevision), "note inputRevision is stable across expiry")
        check(layersAfter.summary.status == "ready" && layersAfter.summary.generated?.output.title == "Trip planning", "the committed day note survives")
        // Crypto-shred: the day key is gone, so the stray ciphertext never opens again.
        let ring = try JSONSerialization.jsonObject(with: keys.raw ?? Data()) as? [String: Any] ?? [:]
        check(!vault.hasKey(epoch: oldDay) && (ring["keys"] as? [String: String])?[oldDay] == nil && (ring["keys"] as? [String: String])?[TypedTextVault.epoch(for: now)] != nil, "the keyring holds today's key, not the old day's")
        for row in stray { check(openFails(vault, Data(base64Encoded: row[2])!, row[0], row[1]), "a stray copy of \(row[0])'s ciphertext can't be opened") }
        check(try store!.hydrateTypedText("live1", disclosure: .owner, now: now) == liveWords, "the fresh draft still opens")
        store = nil
        let strayNeedles = stray.flatMap { [$0[2], String($0[2].prefix(32))] }
        check(try filesContain(home, expiring.map(\.1) + ["quokkamarble", "ibexsaffron"] + strayNeedles).isEmpty, "no expired word and no expired ciphertext in any database file byte (secure delete)")
        check(try filesContain(home, [liveSealed]).count >= 1, "control: the scanner finds live ciphertext")

        // Forget: nothing typed is left in the file, and the keyring is gone.
        let reopened = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        try reopened.attachVault(TypedTextVault(keyStore: keys), now: now)
        check(try reopened.forgetTypedText(confirmed: true, now: now).keyringDeleted && keys.raw == nil, "Forget deletes the keyring")
        check(try reopened.rows("SELECT id FROM records WHERE json_extract(body,'$.kind')='keyboard.text_input' UNION ALL SELECT id FROM typed_text UNION ALL SELECT id FROM typed_after").isEmpty, "Forget leaves no typed record, sealed row or stub")
        check(try reopened.rows("SELECT id FROM generated_notes").isEmpty && reopened.rows("SELECT id FROM note_requests WHERE body<>'' AND body LIKE '%expiring%'").isEmpty, "Forget deletes notes and writer input that cite typed drafts")
        let forgottenPolicy = try reopened.typedTextPolicy()
        check(forgottenPolicy.consentVersion == 0 && forgottenPolicy.acceptedAt == "", "Forget clears typing consent")
        check(try filesContain(home, [liveWords, "narwhalcobalt", liveSealed, String(liveSealed.prefix(32)), "Planned the harbour trip"]).isEmpty, "after Forget no typed word, ciphertext or typed summary is in any file byte")

        // A damaged policy row falls back to the locked defaults.
        try reopened.exec("INSERT OR REPLACE INTO metadata VALUES('typed-text-policy-v1','not json')")
        check(try reopened.typedTextPolicy() == TypedTextPolicy(), "an unreadable policy row reads as the locked defaults")
        try reopened.exec("INSERT OR REPLACE INTO metadata VALUES('typed-text-policy-v1',?)", [#"{"version":1,"consentVersion":2,"retention":"12d"}"#])
        // The fixture row has no acceptedScope (an older build's consent), so it counts for the Notes and TextEdit
        // scope; the full-typing build asks again for its wider scope (TypedConsentScope), which is not this check.
        check(try reopened.typedTextPolicy().retention == .day1 && reopened.typedTextPolicy().consented(in: .legacy), "an unknown period reads as the shortest")

        // Which bullet may outlive the words: grounded, short, no secret, no long copy.
        let words = "alpha beta gamma delta epsilon zeta eta theta"
        func noteRow(_ id: String, _ bullets: [NoteBullet]) throws {
            try reopened.exec("INSERT INTO generated_notes VALUES(?,1,'rev',?)", [id, json(GeneratedNote(id: id, version: 1, schemaVersion: 1, generatedAt: iso(now), inputRevision: "rev", actionIDs: Array(Set(bullets.flatMap(\.actionIDs))).sorted(), output: NoteWriterOutput(requestID: "q-" + id, title: "T", bullets: bullets, generator: "fixture", generatorVersion: "1"), status: "generated_unverified"))])
        }
        try noteRow("pick1", [NoteBullet(text: "PIN is 4921", actionIDs: ["s1"]), NoteBullet(text: "alpha beta gamma delta epsilon zeta", actionIDs: ["s1"]),
                              NoteBullet(text: String(repeating: "long ", count: 60), actionIDs: ["s1"]), NoteBullet(text: "Did two things", actionIDs: ["s1", "other"]),
                              NoteBullet(text: "Planned the offsite with the whole team for spring", actionIDs: ["s1"]), NoteBullet(text: "Unrelated", actionIDs: ["other"])])
        check(try reopened.noteSummary(for: "s1", words: words) == "Planned the offsite with the whole team for spring", "secret-looking, copying and over-long bullets are skipped; the fewest-actions bullet wins")
        try reopened.exec("DELETE FROM generated_notes")
        // The guard is relative to the draft: 5 words in a row only from a
        // draft of 13 words or more; 3 from this 8-word draft.
        try noteRow("pick2", [NoteBullet(text: "alpha beta gamma delta epsilon", actionIDs: ["s1"]), NoteBullet(text: "Did two things", actionIDs: ["s1", "other"])])
        let longWords = words + " iota kappa lambda mu nu"
        check(try reopened.noteSummary(for: "s1", words: longWords) == "alpha beta gamma delta epsilon", "5 copied words in a row may be kept from a 13-word draft")
        check(try reopened.noteSummary(for: "s1", words: words) == "Did two things", "but not from an 8-word draft (3 at most)")
        try reopened.exec("DELETE FROM generated_notes")
        try noteRow("pick2b", [NoteBullet(text: "alpha beta gamma", actionIDs: ["s1"])])
        check(try reopened.noteSummary(for: "s1", words: words) == "alpha beta gamma", "3 copied words from an 8-word draft may be kept")
        try reopened.exec("DELETE FROM generated_notes")
        try noteRow("pick2c", [NoteBullet(text: "alpha beta gamma delta", actionIDs: ["s1"])])
        check(try reopened.noteSummary(for: "s1", words: "zeta eta theta") == "alpha beta gamma delta", "fixture: the bullet copies nothing from this part alone")
        check(try reopened.noteSummary(for: "s1", words: "zeta eta theta", run: words) == nil, "the whole run counts too: a copy longer than the run allows is refused")
        try reopened.exec("DELETE FROM generated_notes")
        try noteRow("pick3", [NoteBullet(text: "Sent sk-ant-api03-" + String(repeating: "Zq9", count: 20) + " to Sam", actionIDs: ["s1"]), NoteBullet(text: "Unrelated", actionIDs: ["other"])])
        check(try reopened.noteSummary(for: "s1", words: words) == nil, "no usable bullet: nil, and the stub is used")
    }

    // MARK: Crypto

    static func vaultCrypto() throws {
        let keys = InMemoryTypedKeyStore(), vault = TypedTextVault(keyStore: keys)
        check(vault.refresh(hadWords: false) == .notSetUp, "a new vault with no item is notSetUp")
        rejects("an unset vault never seals") { _ = try vault.seal("words", id: "a", epoch: "2026-09-24") }
        try vault.create()
        rejects("create never runs over a ready keyring") { try vault.create() }
        rejects("an unavailable vault can't be set up") { try TypedTextVault.unavailable().create() }
        check(TypedTextVault.epoch(for: Date(timeIntervalSince1970: 1_790_000_000)) == "2026-09-21" && TypedTextVault.epoch(for: Date(timeIntervalSince1970: 1_790_035_199)) == "2026-09-21" && TypedTextVault.epoch(for: Date(timeIntervalSince1970: 1_790_035_200)) == "2026-09-22", "epoch is the UTC day")
        let text = "pricing page ships Friday \u{1F680} caf\u{E9}"
        let sealed = try vault.seal(text, id: "row-1", epoch: "2026-09-24")
        check(try vault.open(sealed, id: "row-1", epoch: "2026-09-24") == text, "round trip, including emoji and accents")
        check(sealed.count == 12 + Data(text.utf8).count + 16, "combined box = 12-byte nonce | ciphertext | 16-byte tag")
        check(sealed.range(of: Data("pricing".utf8)) == nil, "ciphertext does not contain the words")
        let again = try vault.seal(text, id: "row-1", epoch: "2026-09-24")
        check(again != sealed && again.prefix(12) != sealed.prefix(12), "every seal uses a fresh random nonce")
        check(openFails(vault, sealed, "row-2", "2026-09-24"), "a row copied to another id fails (AAD binds the id)")
        check(openFails(vault, sealed, "row-1", "2026-09-25"), "a row moved to another day fails (AAD binds the day)")
        for (label, index) in [("nonce", 0), ("ciphertext", 14), ("tag", sealed.count - 1)] {
            var tampered = sealed; tampered[index] ^= 0x01
            check(openFails(vault, tampered, "row-1", "2026-09-24"), "one flipped bit in the \(label) fails authentication")
        }
        check(openFails(vault, sealed.prefix(20), "row-1", "2026-09-24") && openFails(vault, Data(), "row-1", "2026-09-24"), "truncated or empty rows fail")
        // Wrong key: another keyring, same id and day.
        let otherKeys = InMemoryTypedKeyStore(), other = TypedTextVault(keyStore: otherKeys)
        _ = other.refresh(hadWords: false); try other.create()
        _ = try other.seal("warm the day key", id: "row-1", epoch: "2026-09-24")
        check(openFails(other, sealed, "row-1", "2026-09-24"), "a different keyring's key can't open the row")
        // Missing key: a day that was never keyed.
        check(openFails(vault, sealed, "row-1", "2026-09-23"), "a missing day key fails")
        // Rotation: one key per day; dropping one day's key shreds only that day.
        let savesBefore = keys.saves
        let tomorrow = try vault.seal("tomorrow's words", id: "row-3", epoch: "2026-09-25")
        check(keys.saves == savesBefore + 1 && vault.epochs == ["2026-09-24", "2026-09-25"], "a new day adds one key and rewrites the item once")
        let ring = try JSONDecoder().decode(TypedKeyring.self, from: keys.raw ?? Data())
        check(ring.version == 1 && Set(ring.keys.values).count == 2 && ring.keys.values.allSatisfy { Data(base64Encoded: $0)?.count == 32 } && Data(base64Encoded: ring.mac)?.count == 32, "the keyring item holds two distinct 256-bit day keys and a MAC key")
        check(keys.raw.map { $0.range(of: Data("pricing".utf8)) == nil } == true, "the keyring item holds no words")
        try vault.dropKeys(["2026-09-24"])
        check(try openFails(vault, sealed, "row-1", "2026-09-24") && (try vault.open(tomorrow, id: "row-3", epoch: "2026-09-25")) == "tomorrow's words", "dropping one day's key shreds that day only")
        let reread = TypedTextVault(keyStore: keys)
        check(reread.refresh(hadWords: true) == .ready && reread.epochs == ["2026-09-25"], "the dropped key is gone from the stored item too")
        check(reread.grantMACKey != nil && TypedTextVault.unavailable().grantMACKey == nil, "the grant MAC key is available only with a keyring")
        // Locked while a new day key is needed: nothing is sealed.
        keys.locked = true
        do { _ = try vault.seal("locked day", id: "row-4", epoch: "2026-09-26"); check(false, "locked seal refused") } catch { check((error as? TypedTextError) == .typingLocked(.locked) && vault.state == .locked, "a locked Keychain refuses a new day key and locks the vault") }
        check(TypedTextVault(keyStore: keys).refresh(hadWords: true) == .locked, "a locked Keychain reads as locked, not lost")
        keys.locked = false
        check(vault.refresh(hadWords: true) == .ready, "unlocking reads the same keyring again")
        try vault.destroy()
        let afterDestroy = TypedTextVault(keyStore: keys)
        check(keys.raw == nil && vault.state == .notSetUp && afterDestroy.refresh(hadWords: true) == .keyLost && (try? afterDestroy.open(tomorrow, id: "row-3", epoch: "2026-09-25")) == nil, "destroy deletes the keyring item; old words can't be opened")
    }

    // MARK: Store rows and file bytes

    static func storeBytes(_ root: URL) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), day = TypedTextVault.epoch(for: now)
        let words = ["zebraquince marmalade", "velvetplover sonata", "copperfinch lantern", "saffronotter meadow"]
        let control = "harmlesswindowtitlecontrol"
        let home = root.appendingPathComponent("live")
        var store: MemoryStore? = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        var policy = try store!.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try store!.updatePolicy(policy, now: now)
        func typed(_ id: String, _ text: String, at: Date = now) -> Evidence {
            Evidence(id: id, at: iso(at), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes", title: "Standup", text: text, synthetic: true)
        }

        // No plain-text fallback, at the lowest level.
        rejects("ingest without a vault throws") { _ = try store!.ingest(typed("x0", words[0]), now: now) }
        check(try store!.rows("SELECT id FROM records UNION ALL SELECT id FROM typed_text").isEmpty, "the refused row left nothing in records or typed_text")

        let keys = InMemoryTypedKeyStore()
        try store!.attachVault(TypedTextVault(keyStore: keys), now: now); try store!.setUpTypedVault(now: now); try store!.acceptSafeTyping(now: now)
        // A failed record write rolls back the seal too.
        try store!.exec("CREATE TRIGGER reject_typed BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
        rejects("a failed record write throws") { _ = try store!.ingest(typed("x1", words[0]), now: now) }
        try store!.exec("DROP TRIGGER reject_typed")
        check(try store!.rows("SELECT id FROM typed_text").isEmpty, "a failed record write leaves no sealed row (one transaction)")

        _ = try store!.ingest(Evidence(id: "w1", at: iso(now), kind: "window.changed", app: "Notes", bundle: "com.apple.Notes", title: control, synthetic: true), now: now)
        for (index, text) in words.prefix(3).enumerated() { check(try store!.ingest(typed("t\(index)", text, at: now.addingTimeInterval(Double(index))), now: now), "typed row \(index) sealed") }
        check(try store!.ingest(typed("t-old", words[3], at: now.addingTimeInterval(-86400)), now: now), "yesterday's typed row sealed")
        let sealedRows = try store!.rows("SELECT id,epoch,sealed,words,created_at FROM typed_text ORDER BY id")
        check(sealedRows.count == 4 && sealedRows.first { $0[0] == "t0" }?[1] == day && sealedRows.first { $0[0] == "t-old" }?[1] == TypedTextVault.epoch(for: now.addingTimeInterval(-86400)), "typed_text rows carry their UTC day")
        for row in sealedRows {
            let body = try store!.rows("SELECT body FROM records WHERE id=?", [row[0]])[0][0]
            let evidence = try decode(Evidence.self, body)
            check(evidence.text == "" && evidence.typed?.digest == sealedDigest(Data(base64Encoded: row[2])!) && String(evidence.typed?.words ?? -1) == row[3] && evidence.at == row[4], "record \(row[0]) points at its sealed row by digest")
        }
        _ = try store!.writePending(now: now)
        // A note that cites typed rows: the committed request keeps no actions.
        let request = try store!.prepareNote(kind: "day", day: day, timezone: "UTC", now: now)
        _ = try store!.commitNote(NoteWriterOutput(requestID: request.id, title: "Standup notes", bullets: [NoteBullet(text: "Drafted standup notes in Notes.", actionIDs: ["t0"], assertion: "draft")], generator: "fixture", generatorVersion: "1"), now: now)
        let stored = try store!.rows("SELECT body,state FROM note_requests WHERE id=?", [request.id])[0]
        check(try stored[1] == "committed" && (try JSONSerialization.jsonObject(with: Data(stored[0].utf8)) as? [String: Any]).flatMap { ($0["request"] as? [String: Any])?["actions"] as? [Any] }?.isEmpty == true, "a committed note request citing typed rows keeps no writer actions")
        check(try store!.commitNote(NoteWriterOutput(requestID: request.id, title: "Standup notes", bullets: [NoteBullet(text: "Drafted standup notes in Notes.", actionIDs: ["t0"], assertion: "draft")], generator: "fixture", generatorVersion: "1"), now: now).output.title == "Standup notes", "an identical retry of a committed note still succeeds")
        for table in ["records", "summaries", "note_requests", "generated_notes", "metadata", "receipts", "user_corrections"] {
            let dump = try store!.rows("SELECT * FROM \(table)").flatMap { $0 }.joined(separator: "\n")
            check(!words.contains { dump.contains($0) }, "raw \(table) rows hold none of the typed words")
        }
        let sealedDump = sealedRows.map { String(decoding: Data(base64Encoded: $0[2])!, as: UTF8.self) }.joined()
        check(!words.contains { sealedDump.contains($0) }, "decoded typed_text ciphertext holds none of the words")
        check(try store!.hydrateTypedText("t1", disclosure: .owner, now: now) == words[1], "the owner opens a sealed row")
        check(try store!.timeline(query: "zebraquince", now: now).isEmpty && store!.searchResult(MemorySearchQuery("velvetplover"), now: now).items.isEmpty, "typed words are not searchable")

        // Tamper and swap inside the database.
        let t2 = sealedRows.first { $0[0] == "t2" }!, t1 = sealedRows.first { $0[0] == "t1" }!
        var flipped = Data(base64Encoded: t2[2])!; flipped[20] ^= 0x80
        try store!.exec("UPDATE typed_text SET sealed=? WHERE id='t2'", [flipped.base64EncodedString()])
        check(try store!.hydrateTypedText("t2", disclosure: .owner, now: now) == nil, "a changed ciphertext byte never opens (digest and tag)")
        // Copy t1's box onto t2 and forge t2's digest to match: the AAD still refuses.
        try store!.exec("UPDATE typed_text SET sealed=? WHERE id='t2'", [t1[2]])
        var t2Body = try decode(Evidence.self, store!.rows("SELECT body FROM records WHERE id='t2'")[0][0]); t2Body.typed?.digest = t1[2].isEmpty ? "" : sealedDigest(Data(base64Encoded: t1[2])!)
        let forgedBody = try json(t2Body); try store!.exec("UPDATE records SET body=?,revision=? WHERE id='t2'", [forgedBody, fingerprint(forgedBody)])
        check(try store!.hydrateTypedText("t2", disclosure: .owner, now: now) == nil, "another row's ciphertext under a forged digest still fails (AAD binds the id)")
        check(try store!.reconcileTypedVault(now: now) == .ready && store!.typedAfter("t2")?.source == "key-lost" && store!.typedKeyLostRowCount() == 1, "reconcile turns the bad row into a key-lost stub and counts it")
        check(try store!.hydrateTypedText("t0", disclosure: .owner, now: now) == words[0], "good rows are untouched")

        // Deletion and retention take sealed rows with them.
        try store!.delete("t0")
        check(try store!.rows("SELECT id FROM typed_text WHERE id='t0' UNION ALL SELECT id FROM typed_after WHERE id='t0'").isEmpty, "delete removes the sealed row")
        let review = try store!.prepareRetentionChange(.days(1), now: now)
        _ = try store!.confirmRetentionChange(review.id, confirmed: true, now: now)
        _ = try store!.writePending(now: now.addingTimeInterval(3600))
        check(try store!.rows("SELECT id FROM typed_text WHERE id='t-old' UNION ALL SELECT id FROM records WHERE id='t-old'").isEmpty, "record retention removes the sealed row too")

        // Build 4 plain-text rows: seal them in one transaction; blank what quoted them.
        let legacyWords = ["plainbuildfour otterlime", "plainbuildfour quartzfig"]
        for (index, text) in legacyWords.enumerated() {
            var e = typed("legacy\(index)", text, at: now.addingTimeInterval(10 + Double(index)))
            e.captureProvenance = NativeCaptureProvenance(policyRevision: "r", classifierVersion: "sensitive-typing/v2", windowID: "w", focusID: "f", checkedAt: e.at, generation: 1)
            let body = try json(e)
            try store!.exec("INSERT INTO records VALUES(?,?,?)", [e.id, body, fingerprint(body)])
            try store!.exec("INSERT INTO summaries VALUES(?,?,?)", [e.id, json(IntentWriter.write(e, now: now)), fingerprint(body)])
        }
        let legacyRequest = try store!.prepareNote(kind: "day", day: day, timezone: "UTC", now: now.addingTimeInterval(20))
        // Safe typing D: a build 4 row waiting for the upgrade already gives
        // writers a word count, not its words.
        let legacyBody = try store!.rows("SELECT body FROM note_requests WHERE id=?", [legacyRequest.id])[0][0]
        check(!legacyBody.contains("plainbuildfour") && legacyBody.contains("Typed a draft in Notes (a few words)."), "a build 4 row gives the writer a word count, not its words")
        check(try store!.action("legacy0", now: now)?.description == "Typed a draft in Notes (a few words).", "a build 4 row's action carries a word count, not its words")
        // Fixture: a request written by build 4 itself quoted the words.
        try store!.exec("UPDATE note_requests SET body=? WHERE id=?", [legacyBody.replacingOccurrences(of: "Typed a draft in Notes (a few words).", with: "Typed a draft in Notes. plainbuildfour otterlime"), legacyRequest.id])
        check(try store!.rows("SELECT body FROM note_requests WHERE id=?", [legacyRequest.id])[0][0].contains("plainbuildfour"), "fixture: a build 4 writer request quoted the words")
        try store!.exec("INSERT INTO generated_notes VALUES('legacy-note',1,'old',?)", [json(GeneratedNote(id: "legacy-note", version: 1, schemaVersion: 1, generatedAt: iso(now), inputRevision: "old", actionIDs: ["legacy0"], output: NoteWriterOutput(requestID: "q", title: "Old", bullets: [NoteBullet(text: "Typed plainbuildfour otterlime", actionIDs: ["legacy0"])], generator: "fixture", generatorVersion: "1"), status: "generated_unverified"))])
        let legacyRevision = try store!.rows("SELECT revision FROM records WHERE id='legacy0'")[0][0]
        rejects("sealing legacy rows needs a ready vault") { _ = try MemoryStore(home: root.appendingPathComponent("no-vault"), writable: true).migrateLegacyTypedText(seal: true, now: now) }
        check(try store!.migrateLegacyTypedText(seal: true, now: now) == 2, "two build 4 rows sealed")
        check(try store!.migrateLegacyTypedText(seal: true, now: now) == 0, "the migration runs once")
        for (index, text) in legacyWords.enumerated() {
            let evidence = try decode(Evidence.self, store!.rows("SELECT body FROM records WHERE id=?", ["legacy\(index)"])[0][0])
            check(try evidence.text == "" && evidence.typed != nil && (try store!.hydrateTypedText("legacy\(index)", disclosure: .owner, now: now.addingTimeInterval(30))) == text, "legacy row \(index) sealed and still opens")
        }
        check(try store!.rows("SELECT revision FROM records WHERE id='legacy0'")[0][0] != legacyRevision, "the sealed legacy row gets a new revision (notes regenerate once)")
        check(try store!.rows("SELECT id FROM summaries WHERE id LIKE 'legacy%'").isEmpty, "legacy summaries are deleted")
        check(try store!.rows("SELECT state,body FROM note_requests WHERE id=?", [legacyRequest.id])[0] == ["invalidated", ""], "writer requests citing legacy rows are blanked")
        check(try store!.rows("SELECT id FROM generated_notes WHERE id='legacy-note'").isEmpty, "notes built from legacy words are deleted")
        for table in ["records", "summaries", "note_requests", "generated_notes"] {
            let dump = try store!.rows("SELECT * FROM \(table)").flatMap { $0 }.joined(separator: "\n")
            check(!dump.contains("plainbuildfour"), "no legacy words left in \(table)")
        }
        // Declined upgrade: the words are deleted, a stub stays.
        let declined = try MemoryStore(home: root.appendingPathComponent("declined"), writable: true, automaticallySyncSearch: false)
        var e = typed("declined0", "plainbuildfour declinedwords"); let body = try json(e)
        try declined.exec("INSERT INTO records VALUES(?,?,?)", [e.id, body, fingerprint(body)])
        check(try declined.migrateLegacyTypedText(seal: false, now: now) == 1 && declined.typedAfter("declined0")?.source == "stub" && declined.typedAfter("declined0")?.words == 2, "declining keeps a stub")
        e = try decode(Evidence.self, declined.rows("SELECT body FROM records WHERE id='declined0'")[0][0])
        check(try e.text == "" && e.typed?.digest == "" && declined.typedCounts() == (0, 1), "declining deletes the words and keeps no sealed copy")
        check(try filesContain(declined.home, ["declinedwords"]).isEmpty, "declined words are gone from the database file bytes")
        // Legacy import never brings typed words in.
        var entry = MigrationEntry(id: "legacy_x", sourceID: "1", family: "collector-event", format: "v1", at: iso(now), epochNanos: "1", timezone: "UTC", raw: #"{"key":{"text":"importedwords"}}"#, rawSHA256: "", deleted: false, evidence: typed("legacy_x", "importedwords"), summary: nil, end: nil, attachments: [])
        check(LegacyMigration.carriesTypedWords(entry), "an imported typed row with words is excluded")
        entry.evidence?.text = ""
        check(LegacyMigration.carriesTypedWords(entry), "an imported typed row whose raw JSON holds the words is excluded")
        entry.raw = "{}"
        check(!LegacyMigration.carriesTypedWords(entry), "an imported typed row with no words may import")

        // Backups: typed_after only, never typed_text; manifest flag false.
        let target = try MemoryStore(home: root.appendingPathComponent("snapshot"), writable: true, automaticallySyncSearch: false)
        let audit = try MemoryStore(home: home).exportCanonicalSnapshot(to: target, now: now.addingTimeInterval(40))
        check(try audit.typedTextExact == false && (try json(audit)).contains("\"typedTextExact\":false"), "the backup manifest says typedTextExact:false")
        check(try target.rows("SELECT id FROM typed_text").isEmpty && target.rows("SELECT id FROM typed_after").map { $0[0] } == ["t2"], "the backup has no sealed words, only stubs")
        check(try target.rows("SELECT id FROM records WHERE id='t1'").count == 1 && target.hydrateTypedText("t1", disclosure: .owner, now: now) == nil, "a restored copy can't open words")
        check(try filesContain(target.home, words + legacyWords + ["plainbuildfour"]).isEmpty, "backup file bytes hold no typed words")
        check(try target.inspectCanonicalSnapshot(now: now.addingTimeInterval(40)).typedTextExact == false, "the backup inspects clean")
        let crafted = try MemoryStore(home: root.appendingPathComponent("crafted"), writable: true, automaticallySyncSearch: false)
        _ = try MemoryStore(home: home).exportCanonicalSnapshot(to: crafted, now: now.addingTimeInterval(40))
        try crafted.exec("INSERT INTO typed_text VALUES('t1','2026-01-01','AAAA',1,?)", [iso(now)])
        rejects("a backup carrying typed_text is refused") { _ = try crafted.inspectCanonicalSnapshot(now: now.addingTimeInterval(40)) }
        // Merge restore brings a lost record back with its stub, never words.
        try store!.exec("DELETE FROM records WHERE id='t2'"); try store!.exec("DELETE FROM typed_after WHERE id='t2'"); try store!.invalidateDisclosure()
        let preview = try store!.prepareCanonicalRestore(target, now: now.addingTimeInterval(40))
        check(preview.addedActionIDs == ["t2"], "restore preview lists the missing typed record")
        _ = try store!.confirmCanonicalRestore(target, previewID: preview.id, confirmed: true, now: now.addingTimeInterval(40))
        check(try store!.typedAfter("t2")?.source == "key-lost" && store!.rows("SELECT id FROM typed_text WHERE id='t2'").isEmpty, "restore adds the stub, not words")
        check(try store!.hydrateTypedText("t1", disclosure: .owner, now: now) == words[1], "restore leaves live sealed words alone")

        // Control: the scanner does find plain text (the window title).
        check(try filesContain(home, [control]).count >= 1, "control: the byte scanner finds a plain-text title")
        store = nil
        check(try filesContain(home, words + legacyWords + ["plainbuildfour"]).isEmpty, "no typed word, current or legacy, in any database file byte")
    }

    // MARK: Review fixes: several vaults, one keyring; keyring moves and binding

    /// Several vaults (one per writable store instance) share one keyring
    /// item: no key made by one is overwritten by another, and no dropped key
    /// comes back. A keyring belongs to one store. The keyring moves between
    /// keychains without losing words. A newer build's keyring and a deleted
    /// item are never overwritten. Any failed save stops typing.
    static func keyringSharing(_ root: URL) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), day = 86400.0
        func typed(_ id: String, _ text: String, at: Date) -> Evidence {
            Evidence(id: id, at: iso(at), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes", title: "Trip", text: text, synthetic: true)
        }
        func ready(_ store: MemoryStore, _ keys: TypedKeyStore) throws {
            var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try store.updatePolicy(policy, now: now)
            try store.attachVault(TypedTextVault(keyStore: keys), now: now); try store.acceptSafeTyping(now: now); try store.setUpTypedVault(now: now)
        }
        func ringKeys(_ keys: InMemoryTypedKeyStore) -> [String] {
            ((try? JSONSerialization.jsonObject(with: keys.raw ?? Data())) as? [String: Any]).flatMap { ($0["keys"] as? [String: String])?.keys.sorted() } ?? []
        }
        // Two store instances on one home, each with its own vault on one item.
        let home = root.appendingPathComponent("two-vaults"), keys = InMemoryTypedKeyStore()
        let a = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        try ready(a, keys)
        let b = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        try b.attachVault(TypedTextVault(keyStore: keys), now: now)
        let d1 = now.addingTimeInterval(-2 * day), d2 = now.addingTimeInterval(-day)
        check(try a.ingest(typed("v-a", "first vault words", at: d1), now: now), "vault A seals day 1")
        check(try b.ingest(typed("v-b", "second vault words", at: d2), now: now), "vault B (loaded before A's key) seals day 2")
        check(ringKeys(keys) == [TypedTextVault.epoch(for: d1), TypedTextVault.epoch(for: d2)].sorted(), "the stored keyring keeps both vaults' day keys")
        check(try a.reconcileTypedVault(now: now) == .ready && a.typedAfter("v-a") == nil && a.hydrateTypedText("v-a", disclosure: .owner, now: now) == "first vault words", "A's words still open: nothing became a key-lost stub")
        check(try a.hydrateTypedText("v-b", disclosure: .owner, now: now) == "second vault words", "A opens a row sealed under a key only B had made")
        // A drops day 1 (its words expired); B, with the old copy, seals day 3.
        try a.attachedVault!.dropKeys([TypedTextVault.epoch(for: d1)])
        check(try b.ingest(typed("v-b3", "third day words", at: now), now: now), "B seals a new day after A's drop")
        check(!ringKeys(keys).contains(TypedTextVault.epoch(for: d1)) && ringKeys(keys).contains(TypedTextVault.epoch(for: now)), "a dropped day key never comes back from another vault's copy")

        // A keyring belongs to one store: another store never uses or drops it.
        let otherHome = root.appendingPathComponent("other-store")
        let other = try MemoryStore(home: otherHome, writable: true, automaticallySyncSearch: false)
        var otherPolicy = try other.policy(); otherPolicy.captureText = true; otherPolicy.typedConsentVersion = 1; try other.updatePolicy(otherPolicy, now: now)
        check(try other.attachVault(TypedTextVault(keyStore: keys), now: now) == .locked, "a store attaching another store's keyring stays locked")
        rejects("it can't turn typing on over that keyring") { try other.setUpTypedVault(now: now) }
        _ = try other.expireTypedText(now: now.addingTimeInterval(400 * day))
        check(ringKeys(keys).contains(TypedTextVault.epoch(for: d2)) && keys.raw.map { $0.range(of: Data("store".utf8)) != nil } == true, "its expiry never drops the other store's keys; the keyring names its store")
        let sameVault = TypedTextVault(keyStore: InMemoryTypedKeyStore())
        let c = try MemoryStore(home: root.appendingPathComponent("bind-c"), writable: true, automaticallySyncSearch: false)
        let d = try MemoryStore(home: root.appendingPathComponent("bind-d"), writable: true, automaticallySyncSearch: false)
        try c.attachVault(sameVault, now: now)
        rejects("one vault serves one store") { _ = try d.attachVault(sameVault, now: now) }

        // A newer build's keyring: locked, never lost, never overwritten.
        let newerKeys = InMemoryTypedKeyStore(item: Data(#"{"version":2,"keys":{},"mac":"x"}"#.utf8))
        let newer = TypedTextVault(keyStore: newerKeys)
        check(newer.refresh(hadWords: true) == .locked && newerKeys.raw == Data(#"{"version":2,"keys":{},"mac":"x"}"#.utf8), "a newer keyring version reads as locked and is left alone")
        rejects("a newer keyring is never replaced by turning typing on") { try newer.create() }

        // A newer build rewrites the item while this app runs: the next change
        // locks typing and keeps every sealed word (not a key-lost stub).
        let mid = try MemoryStore(home: root.appendingPathComponent("newer-mid"), writable: true, automaticallySyncSearch: false)
        let midKeys = InMemoryTypedKeyStore(); try ready(mid, midKeys)
        check(try mid.ingest(typed("n1", "words before the newer build", at: now), now: now), "a draft sealed before the newer build")
        midKeys.raw = Data(#"{"version":2,"keys":{},"mac":"x"}"#.utf8)
        rejects("sealing over a newer build's keyring throws") { _ = try mid.ingest(typed("n2", "words after the newer build", at: now), now: now) }
        check(try mid.typedVaultState == .locked && mid.typedAfter("n1") == nil && mid.rows("SELECT id FROM typed_text WHERE id='n1'").count == 1
              && midKeys.raw == Data(#"{"version":2,"keys":{},"mac":"x"}"#.utf8), "the vault locks, keeps the sealed words, and leaves the newer keyring alone")

        // The item deleted while the app runs: never quietly re-created.
        let gone = try MemoryStore(home: root.appendingPathComponent("gone"), writable: true, automaticallySyncSearch: false)
        let goneKeys = InMemoryTypedKeyStore(); try ready(gone, goneKeys)
        check(try gone.ingest(typed("g1", "words before the delete", at: now), now: now), "a draft sealed")
        goneKeys.raw = nil
        rejects("sealing after the item was deleted throws") { _ = try gone.ingest(typed("g2", "words after the delete", at: now.addingTimeInterval(day)), now: now.addingTimeInterval(day)) }
        check(try goneKeys.raw == nil && gone.typedVaultState == .keyLost && (try gone.read("g2", now: now.addingTimeInterval(day))) == nil, "the deleted item is not re-created from memory, nothing is written, the vault is keyLost")

        // A failed save that isn't "locked" still stops typing.
        let failing = try MemoryStore(home: root.appendingPathComponent("failing"), writable: true, automaticallySyncSearch: false)
        let failingKeys = InMemoryTypedKeyStore(); try ready(failing, failingKeys)
        failingKeys.failSaves = true
        rejects("a new day key that can't be saved refuses the draft") { _ = try failing.ingest(typed("f1", "words on a new day", at: now), now: now) }
        check(!failing.typingUnlocked && failing.typedVaultState == .locked, "after any failed key save typing is locked (capture stops reading, no dot)")
        failingKeys.failSaves = false
        check(try failing.reconcileTypedVault(now: now) == .ready, "the next reconcile reads the keyring again")

        // The keyring moves from the login keychain to the data-protection
        // keychain explicitly: no key loss, no stubs.
        let login = InMemoryTypedKeyStore(), dataProtection = InMemoryTypedKeyStore()
        let moving = try MemoryStore(home: root.appendingPathComponent("moving"), writable: true, automaticallySyncSearch: false)
        try ready(moving, login)
        check(try moving.ingest(typed("m1", "words before the move", at: now), now: now), "a draft sealed with the key in the login keychain")
        let movingStore = MigratingTypedKeyStore(primary: dataProtection, legacy: login)
        let moved = try MemoryStore(home: root.appendingPathComponent("moving"), writable: true, automaticallySyncSearch: false)
        check(try moved.attachVault(TypedTextVault(keyStore: movingStore), now: now) == .ready && moved.typedAfter("m1") == nil, "after the switch the vault is ready and nothing became a stub")
        check(dataProtection.raw != nil && login.raw == nil && movingStore.location == .primary, "the item moved: in the new place, gone from the old")
        check(try moved.hydrateTypedText("m1", disclosure: .owner, now: now) == "words before the move", "the words still open")
        // A build that may not use the data-protection keychain keeps the login keychain.
        let loginOnly = InMemoryTypedKeyStore(), denied = InMemoryTypedKeyStore(); denied.unsupported = true
        let fallback = MigratingTypedKeyStore(primary: denied, legacy: loginOnly)
        let fb = try MemoryStore(home: root.appendingPathComponent("fallback"), writable: true, automaticallySyncSearch: false)
        try ready(fb, fallback)
        check(loginOnly.raw != nil && fallback.location == .legacy, "without the entitlement the keyring lives in the login keychain, and says so")
        try fallback.delete()
        check(loginOnly.raw == nil, "Forget's delete clears the keyring wherever it lives")
        let both = MigratingTypedKeyStore(primary: dataProtection, legacy: InMemoryTypedKeyStore(item: Data("stale".utf8)))
        _ = try both.load(); try both.delete()
        check(dataProtection.raw == nil, "delete clears both places")
    }

    // MARK: Review fixes: retention, verbatim guard, policy MAC, legacy rows, scrubbed titles

    static func reviewFixes(_ root: URL) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), day = 86400.0
        func typed(_ id: String, _ text: String, at: Date, run: String? = nil, part: Int = 1, keys: Int? = nil) -> Evidence {
            var e = Evidence(id: id, at: iso(at), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes", title: "Trip", text: text, synthetic: true)
            if run != nil || keys != nil {
                e.captureProvenance = NativeCaptureProvenance(policyRevision: "r", classifierVersion: "sensitive-typing/v2", windowID: "w", focusID: "f", checkedAt: iso(at), generation: 1,
                                                              unit: TypedUnitProvenance(runID: run ?? "r0", part: part, sealReason: "idle", startedAt: iso(at), keys: keys, edits: keys.map { _ in 3 }, withheld: 0))
            }
            return e
        }
        func ready(_ name: String) throws -> (MemoryStore, InMemoryTypedKeyStore) {
            let store = try MemoryStore(home: root.appendingPathComponent(name), writable: true, automaticallySyncSearch: false)
            var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try store.updatePolicy(policy, now: now)
            let keys = InMemoryTypedKeyStore()
            try store.attachVault(TypedTextVault(keyStore: keys), now: now); try store.acceptSafeTyping(now: now); try store.setUpTypedVault(now: now)
            return (store, keys)
        }
        func legacy(_ store: MemoryStore, _ e: Evidence) throws {
            let body = try json(e); try store.exec("INSERT INTO records VALUES(?,?,?)", [e.id, body, fingerprint(body)])
        }

        // Finding: lengthening the period showed hidden words again.
        let (lengthen, _) = try ready("lengthen")
        check(try lengthen.ingest(typed("L1", "offsite words from ten days ago", at: now), now: now), "a fresh draft")
        let later = now.addingTimeInterval(10 * day)
        var thirty = try lengthen.typedTextPolicy(); thirty.retention = .days30
        try lengthen.updateTypedTextPolicy(thirty, now: later)
        check(try lengthen.hydrateTypedText("L1", disclosure: .owner, now: later) == nil && lengthen.typedAfter("L1")?.source == "stub" && lengthen.rows("SELECT id FROM typed_text").isEmpty, "words past 7 days are deleted before a longer period is saved, so they never show again")
        // Finding: a clock going back showed hidden words again.
        let (clock, _) = try ready("clock")
        check(try clock.ingest(typed("K1", "clock rollback words", at: now), now: now), "a draft for the clock check")
        check(try clock.hydrateTypedText("K1", disclosure: .owner, now: now.addingTimeInterval(8 * day)) == nil, "hidden at 8 days")
        check(try clock.hydrateTypedText("K1", disclosure: .owner, now: now.addingTimeInterval(6 * day)) == nil, "still hidden when the clock goes back to 6 days")
        check(try clock.expireTypedText(now: now.addingTimeInterval(6 * day)).expired == 1, "and the next expiry run deletes them, whatever the clock says")
        // A draft that arrives already past the period is never written.
        let (late, _) = try ready("late")
        check(try late.ingest(typed("late1", "stale arriving words", at: now.addingTimeInterval(-9 * day)), now: now), "an old draft keeps its record")
        check(try late.rows("SELECT id FROM typed_text").isEmpty && late.typedAfter("late1")?.source == "stub" && late.read("late1", now: now)?.evidence.typed?.digest == "", "but its words are never sealed: a stub from the start")
        // Review G44: a clock set ahead and then back. Words the later clock hid stay deleted, and new words are sealed again.
        let (ahead, aheadKeys) = try ready("g44-clock-ahead")
        check(try ahead.ingest(typed("A1", "words before the clock jumped", at: now), now: now), "G44 a draft before the Mac's clock is set a month ahead")
        _ = try ahead.expireTypedText(now: now.addingTimeInterval(30 * day))
        check(try ahead.hydrateTypedText("A1", disclosure: .owner, now: now) == nil && ahead.typedAfter("A1")?.source == "stub", "G44 the month-ahead clock deleted it (a stub stays)")
        _ = try ahead.expireTypedText(now: now)
        check(try ahead.ingest(typed("A2", "words after the clock was fixed", at: now), now: now)
              && ahead.hydrateTypedText("A2", disclosure: .owner, now: now) == "words after the clock was fixed",
              "G44 once the clock is set back, the next expiry run lowers the typed clock: a new word is sealed and opens")
        check(try ahead.hydrateTypedText("A1", disclosure: .owner, now: now) == nil && ahead.typedAfter("A1")?.source == "stub", "G44 the word the later clock hid stays deleted")
        let aheadAgain = try MemoryStore(home: root.appendingPathComponent("g44-clock-ahead"), writable: true, automaticallySyncSearch: false)
        try aheadAgain.attachVault(TypedTextVault(keyStore: aheadKeys), now: now)
        check(try aheadAgain.hydrateTypedText("A2", disclosure: .owner, now: now) == "words after the clock was fixed"
              && aheadAgain.ingest(typed("A3", "words after a relaunch", at: now), now: now)
              && aheadAgain.hydrateTypedText("A3", disclosure: .owner, now: now) == "words after a relaunch",
              "G44 after a relaunch the words still open and new words are sealed")
        // Control: a clock that only goes back (never ahead of the real time by more than the slack) keeps the rollback rule.
        check(try clock.hydrateTypedText("K1", disclosure: .owner, now: now) == nil, "G44 control: the rollback check's word stays hidden")
        // An instance that doesn't save its clock (a reader, like the MCP server) never follows a lower clock
        // just because the time went back: only a reset made after it started, covering its own clock, counts.
        let reader = try MemoryStore(home: root.appendingPathComponent("g44-clock-ahead"))
        _ = reader.typedClock(now.addingTimeInterval(3 * 3600))
        check(reader.typedClock(now) == now.addingTimeInterval(3 * 3600), "G44 a reader's clock stays ahead when the time goes back with no new reset")
        let (twin, _) = try ready("g44-twin")
        let cli = try MemoryStore(home: root.appendingPathComponent("g44-twin"), writable: true, automaticallySyncSearch: false)
        _ = cli.typedClock(now.addingTimeInterval(30 * day))
        _ = try twin.expireTypedText(now: now.addingTimeInterval(30 * day)); _ = try twin.expireTypedText(now: now)
        check(cli.typedClock(now) == now, "G44 another instance that saw the month-ahead clock follows the app's reset")
        _ = cli.typedClock(now.addingTimeInterval(2 * 3600))
        check(cli.typedClock(now) == now.addingTimeInterval(2 * 3600), "G44 once: a later step back is the rollback rule again")

        // Review G43: while the Keychain can't be read, Pause, Resume and settings changes are refused and the
        // settings keep their signature (before, the save dropped it: typing off, 7 days, older words deleted).
        let (sig, sigKeys) = try ready("g43-locked")
        var wide = try sig.typedTextPolicy(); wide.retention = .days30; wide.categories.messagesAndEmail = true; wide.shareWithSummaries = .localOnly
        _ = try sig.updateTypedTextPolicy(wide, now: now)
        check(try sig.ingest(typed("G1", "a draft from twenty days ago", at: now.addingTimeInterval(-20 * day)), now: now), "G43 a 20 day old draft kept for 30 days")
        _ = try sig.snoozeTyping(minutes: 10, now: now)
        let signedWide = try sig.typedTextPolicy()
        check(try sig.typedTextPolicyVerified() && signedWide.retention == .days30 && signedWide.snoozed(now: now), "G43 signed settings: 30 days, Messages on, paused")
        sigKeys.locked = true
        check(try sig.reconcileTypedVault(now: now) == .locked, "G43 the Keychain locks")
        rejects("G43 Resume is refused while the key can't be read") { try sig.resumeTyping(now: now) }
        rejects("G43 Pause is refused while the key can't be read") { _ = try sig.snoozeTyping(minutes: 10, now: now.addingTimeInterval(3600)) }
        var narrower = signedWide; narrower.categories.messagesAndEmail = false
        rejects("G43 a settings change is refused while the key can't be read") { _ = try sig.updateTypedTextPolicy(narrower, now: now) }
        sigKeys.locked = false
        check(try sig.retryLockedTypedVault(now: now) == .ready && sig.typedTextPolicyVerified() && sig.typedTextPolicy() == signedWide,
              "G43 after the unlock the settings still carry their signature and are unchanged")
        check(try sig.hydrateTypedText("G1", disclosure: .owner, now: now) == "a draft from twenty days ago", "G43 and the 20 day old draft is still there")
        // Case D: the vault locks during the call (a day key can't be dropped in the expiry pre-pass).
        let (flip, flipKeys) = try ready("g43-flip")
        check(try flip.ingest(typed("F1", "a draft whose day key goes", at: now), now: now), "G43 case D: a draft")
        flipKeys.failSaves = true
        var thirtyFlip = try flip.typedTextPolicy(); thirtyFlip.retention = .days30
        rejects("G43 case D: the Keychain fails while the period is lengthened: the change is refused") { _ = try flip.updateTypedTextPolicy(thirtyFlip, now: now.addingTimeInterval(9 * day)) }
        flipKeys.failSaves = false
        check(try flip.retryLockedTypedVault(now: now.addingTimeInterval(9 * day)) == .ready && flip.typedTextPolicyVerified() && flip.typedTextPolicy().retention == .days7
              && flip.typedTextPolicy().consented, "G43 case D: the settings keep their signature, 7 days and consent")
        // Forget still works while locked (it turns typing off anyway).
        sigKeys.locked = true
        check(try sig.reconcileTypedVault(now: now) == .locked, "G43 locked again")
        _ = try sig.forgetTypedText(confirmed: true, now: now)
        check(try sig.rows("SELECT id FROM typed_text").isEmpty && !sig.typedTextPolicy().consented, "G43 Forget works while the Keychain is locked")

        // Finding: build 4 plain-text rows had no deadline.
        let (old, _) = try ready("legacy-deadline")
        try legacy(old, typed("B-old", "legacyzebra twenty day old words", at: now.addingTimeInterval(-20 * day)))
        try legacy(old, typed("B-new", "legacyfresh two day old words", at: now.addingTimeInterval(-2 * day)))
        let expiry = try old.expireTypedText(now: now)
        check(try expiry.legacyExpired == 1 && old.typedAfter("B-old")?.source == "stub", "the expiry job stubs a build 4 row past the period (no key needed)")
        check(try !old.rows("SELECT body FROM records").flatMap { $0 }.joined().contains("legacyzebra"), "its words are gone from records")
        check(try old.rows("SELECT body FROM records WHERE id='B-new'")[0][0].contains("legacyfresh"), "a build 4 row inside the period waits for the launch rule")
        // Exports never carry build 4 words.
        let target = try MemoryStore(home: root.appendingPathComponent("legacy-backup"), writable: true, automaticallySyncSearch: false)
        _ = try MemoryStore(home: root.appendingPathComponent("legacy-deadline")).exportCanonicalSnapshot(to: target, now: now)
        check(try target.rows("SELECT id FROM records WHERE id='B-new'").isEmpty && filesContain(target.home, ["legacyfresh"]).isEmpty, "a build 4 row still holding words is left out of backups")
        // The launch rule: seal with a ready key and consent, else delete.
        check(try old.settleLegacyTypedText(now: now) == 1 && old.hydrateTypedText("B-new", disclosure: .owner, now: now) == "legacyfresh two day old words", "with typing on, the launch rule seals the remaining build 4 row")
        // Review G59: after the launch rule, the hourly expiry no longer scans every record for build 4 rows.
        // (Only raw SQL could add one now: ingest seals or refuses, and an import makes the next expiry scan again.)
        try legacy(old, typed("B-sql", "legacyraw words written by sqlite3", at: now.addingTimeInterval(-20 * day)))
        check(try old.expireTypedText(now: now).legacyExpired == 0, "G59 after the launch rule, the expiry skips the scan for build 4 rows")
        check(try MemoryStore(home: root.appendingPathComponent("legacy-deadline"), writable: true, automaticallySyncSearch: false).expireTypedText(now: now).legacyExpired == 1
              && old.typedAfter("B-sql")?.source == "stub", "G59 a new process scans again (the flag lives in memory only)")
        for (file, anchor) in [("Sources/MemoryCore/LegacyMigration.swift", "try exec(\"INSERT INTO records VALUES(?,?,?)\",[entry.id,body,fingerprint(body)])\n                    legacyTypedClear = false"),
                               ("Sources/MemoryCore/StagedOnboarding.swift", "{try exec(\"INSERT INTO records VALUES(?,?,?)\",row)}\n            legacyTypedClear = false")] {
            check(((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").contains(anchor), "G59 an import (\(file.split(separator: "/").last!)) makes the next expiry scan again")
        }
        let (withdrawn, _) = try ready("legacy-withdrawn")
        var noText = try withdrawn.policy(); noText.captureText = false; try withdrawn.updatePolicy(noText, now: now)
        try legacy(withdrawn, typed("B-wd", "legacywithdrawn words", at: now))
        check(try withdrawn.settleLegacyTypedText(now: now) == 1 && withdrawn.typedAfter("B-wd")?.source == "stub" && withdrawn.rows("SELECT id FROM typed_text").isEmpty, "a ready key alone isn't enough: with typing switched off the launch rule deletes the words")
        let unconsented = try MemoryStore(home: root.appendingPathComponent("legacy-off"), writable: true, automaticallySyncSearch: false)
        try legacy(unconsented, typed("B-off", "legacyoff words", at: now))
        check(try unconsented.settleLegacyTypedText(now: now) == 1 && unconsented.typedAfter("B-off")?.source == "stub", "without a ready key and consent the launch rule deletes the words")
        check(try filesContain(unconsented.home, ["legacyoff"]).isEmpty, "no build 4 word left in the file bytes")
        // Migration: past-period rows stub, scrub provenance, imported originals purged.
        let (migrate, _) = try ready("legacy-migrate")
        try migrate.exec("CREATE TABLE IF NOT EXISTS migration_originals(id TEXT PRIMARY KEY, body TEXT NOT NULL, raw_hash TEXT NOT NULL, policy_hash TEXT NOT NULL)")
        try legacy(migrate, typed("M-old", "legacyancient words", at: now.addingTimeInterval(-10 * day)))
        let token = "ghp_" + String(repeating: "Q7x", count: 12)
        try legacy(migrate, typed("M-secret", "legacykeys deploy \(token) today", at: now, keys: 70))
        try migrate.exec("INSERT INTO migration_originals VALUES(?,?,?,?)", ["M-secret", #"{"raw":"legacykeys deploy words importedoriginal"}"#, "h", "p"])
        check(try migrate.migrateLegacyTypedText(seal: true, now: now) == 2, "two build 4 rows migrated")
        check(try migrate.typedAfter("M-old")?.source == "stub" && migrate.rows("SELECT id FROM typed_text WHERE id='M-old'").isEmpty, "a build 4 row already past the period becomes a stub, never sealed")
        let migrated = try decode(Evidence.self, migrate.rows("SELECT body FROM records WHERE id='M-secret'")[0][0])
        check(migrated.captureProvenance?.unit?.keys == nil && migrated.captureProvenance?.unit?.edits == nil && migrated.captureProvenance?.unit?.withheld == 1
              && migrated.captureProvenance?.classifierVersion.hasSuffix("+typed-scrub/v1") == true, "the migration applies the ingest provenance rule (withheld counted, key and edit counts cleared)")
        check(try migrate.rows("SELECT id FROM migration_originals WHERE id='M-secret'").isEmpty, "the imported original holding the words is deleted")
        check(try filesContain(migrate.home, ["importedoriginal", "legacyancient"]).isEmpty, "no imported or expired build 4 word in the file bytes")

        // Digest binding: an older box of the same id and day, under the same key, is refused.
        let (replay, _) = try ready("replay")
        check(try replay.ingest(typed("R1", "the words saved first", at: now), now: now), "a draft sealed")
        let older = try replay.attachedVault!.seal("replayed older words", id: "R1", epoch: TypedTextVault.epoch(for: now))
        try replay.exec("UPDATE typed_text SET sealed=? WHERE id='R1'", [older.base64EncodedString()])
        check((try? replay.attachedVault!.open(older, id: "R1", epoch: TypedTextVault.epoch(for: now))) == "replayed older words", "fixture: the swapped box is valid for this id and day")
        check(try replay.hydrateTypedText("R1", disclosure: .owner, now: now) == nil, "the record's digest refuses a box it wasn't saved with")

        // Finding: the typing settings row had no MAC.
        let (policyStore, _) = try ready("policy-mac")
        check(try policyStore.ingest(typed("P1", "words the cloud must not read", at: now), now: now), "a draft sealed")
        check(try policyStore.typedTextPolicyVerified(), "the saved row carries a MAC")
        let tampered = #"{"version":1,"consentVersion":2,"acceptedAt":"x","retention":"forever","categories":{"searchAndAI":true,"writing":true,"code":true,"messagesAndEmail":true},"shareWithSummaries":"localAndCloud","snoozeUntil":"","revision":"forged"}"#
        try policyStore.exec("UPDATE metadata SET body=? WHERE id='typed-text-policy-v1'", [tampered])
        let seen = try policyStore.typedTextPolicy()
        check(seen.shareWithSummaries == .off && seen.retention == .days7 && !seen.categories.messagesAndEmail && !seen.consented, "a row changed with sqlite3 reads as: sharing off, 7 days, messages off, typing locked")
        check(try policyStore.hydrateTypedText("P1", disclosure: .cloudWriter, now: now) == nil && policyStore.hydrateTypedText("P1", disclosure: .localWriter, now: now) == nil, "so no writer can read the words")
        rejects("and typing is locked (no words saved)") { _ = try policyStore.ingest(typed("P2", "more words", at: now), now: now) }
        check(try MemoryStore(home: root.appendingPathComponent("policy-mac")).typedTextPolicy().shareWithSummaries == .localAndCloud, "control: a keyless reader sees the raw row (it can't open words anyway)")
        try policyStore.acceptSafeTyping(now: now)
        check(try policyStore.typedTextPolicyVerified() && policyStore.typedTextPolicy().consented && policyStore.typedTextPolicy().shareWithSummaries == .off, "turning typing on again signs the safe values")
        // Settings saved before the key existed are signed at setup, without widening.
        let early = try MemoryStore(home: root.appendingPathComponent("policy-early"), writable: true, automaticallySyncSearch: false)
        var earlyPolicy = try early.policy(); earlyPolicy.captureText = true; earlyPolicy.typedConsentVersion = 1; try early.updatePolicy(earlyPolicy, now: now)
        try early.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore()), now: now)
        try early.acceptSafeTyping(now: now)
        try early.exec("UPDATE metadata SET body=? WHERE id='typed-text-policy-v1'", [tampered])
        try early.setUpTypedVault(now: now)
        let signed = try early.typedTextPolicy()
        // The tampered row has no acceptedScope: the consent kept is the one it records (Notes and TextEdit), never widened.
        check(try early.typedTextPolicyVerified() && signed.consented(in: .legacy) && signed.acceptedScope == nil && signed.shareWithSummaries == .off && signed.retention == .days7 && signed.categories.messagesAndEmail, "setup signs an earlier row keeping consent, never cloud sharing or forever (Messages and email is on by default, fix/typing-e2e L1, so keeping it widens nothing)")

        // fix/messaging-default (owner 9/28): Messages and email is on by default (opt-out). A fresh install reads it on;
        // a row an earlier build saved (off was its default, so its off can't be told from never chosen) reads it on;
        // an off the person set in this build, or one kept outside the row (SetupChoices), stays off.
        func policyJSON(_ store: MemoryStore) throws -> [String: Any] {
            let raw = try store.rows("SELECT body FROM metadata WHERE id=?", [MemoryStore.typedPolicyID]).first?.first ?? "{}"
            return (try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) ?? [:]
        }
        // An earlier build's row: the same row without `messagesOptOut`, Messages and email saved off, signed with the key.
        func writeEarlierBuildRow(_ store: MemoryStore, messages: Bool) throws {
            var row = try policyJSON(store); row.removeValue(forKey: "messagesOptOut")
            var categories = (row["categories"] as? [String: Any]) ?? [:]; categories["messagesAndEmail"] = messages; row["categories"] = categories
            let body = String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self)
            let mac = Data(HMAC<SHA256>.authenticationCode(for: Data((MemoryStore.typedPolicyMACDomain + "\u{1f}" + body).utf8),
                                                           using: store.attachedVault!.grantMACKey!)).base64EncodedString()
            try store.exec("INSERT OR REPLACE INTO metadata VALUES(?,?)", [MemoryStore.typedPolicyID, body])
            try store.exec("INSERT OR REPLACE INTO metadata VALUES(?,?)", [MemoryStore.typedPolicyMACID, mac])
        }
        let messageApps = ["com.apple.MobileSMS", "com.apple.mail"]
        // The full-typing build's gates (the release gate open, the probe build's apps), with this row's categories.
        // X, Reddit and the other social sites are the Chrome join's rule (WebTypingChecks, Chrome builds only).
        func messagesAllowed(_ policy: TypedTextPolicy) -> [Bool] {
            messageApps.map { TypingCategories.permits(bundle: $0, on: policy.categories.isOn, expanded: true, probeBuild: true) }
                + [("mail.google.com", "/mail/u/0/"), ("discord.com", "/channels/1"), ("web.whatsapp.com", "/")].map {
                    TypingCategories.permitsSite(host: $0.0, path: $0.1, on: policy.categories.isOn, other: false, expanded: true) }
        }
        let (fresh, _) = try ready("messages-fresh")
        let freshPolicy = try fresh.typedTextPolicy()
        check(TypedTextPolicy().categories.messagesAndEmail && TypedTextPolicy().messagesOptOut && TypedCategoryChoices().messagesAndEmail,
              "messages default: a new policy has Messages and email on")
        check(try fresh.typedTextPolicyVerified() && freshPolicy.consented && freshPolicy.categories.messagesAndEmail
              && !messagesAllowed(freshPolicy).contains(false)
              && (try policyJSON(fresh))["messagesOptOut"] as? Bool == true,
              "messages default: a fresh install has Messages and email on (Messages, Mail, Gmail, Discord and WhatsApp allowed), saved as this build's choice")
        // The owner's case: a test build with setup finished, typing on, Messages and email saved off (never chosen).
        let (upgrader, upgraderKeys) = try ready("messages-upgrader")
        try writeEarlierBuildRow(upgrader, messages: false)
        let upgraded = try upgrader.typedTextPolicy()
        check(try upgrader.typedTextPolicyVerified() && upgraded.consented && upgraded.categories.messagesAndEmail && upgraded.messagesOptOut
              && !messagesAllowed(upgraded).contains(false),
              "messages default: an earlier build's row with Messages and email off (never chosen) reads it on, typing still on and signed")
        check(try MemoryStore(home: root.appendingPathComponent("messages-upgrader")).typedTextPolicy().categories.messagesAndEmail,
              "messages default: a keyless reader (CLI, MCP) reads the earlier build's row the same way")
        var longer = upgraded; longer.retention = .days30
        _ = try upgrader.updateTypedTextPolicy(longer, now: now)
        check(try upgrader.typedTextPolicyVerified() && upgrader.typedTextPolicy().categories.messagesAndEmail
              && (try policyJSON(upgrader))["messagesOptOut"] as? Bool == true
              && ((try policyJSON(upgrader))["categories"] as? [String: Any])?["messagesAndEmail"] as? Bool == true,
              "messages default: the next save writes it on, as this build's choice")
        // One click off in this build is an explicit choice: it stays off, also after a relaunch.
        let turnedOff = try upgrader.setTypingCategory(.messagesAndEmail, on: false, now: now)
        let reopened = try MemoryStore(home: root.appendingPathComponent("messages-upgrader"), writable: true, automaticallySyncSearch: false)
        try reopened.attachVault(TypedTextVault(keyStore: upgraderKeys), now: now)
        let offAgain = try reopened.typedTextPolicy()
        check(try !turnedOff.categories.messagesAndEmail && reopened.typedTextPolicyVerified() && !offAgain.categories.messagesAndEmail && offAgain.consented
              && !messagesAllowed(offAgain).contains(true) && offAgain.excludedBundles(expanded: true).isSuperset(of: messageApps)
              && !(try MemoryStore(home: root.appendingPathComponent("messages-upgrader")).typedTextPolicy().categories.messagesAndEmail),
              "messages default: Messages and email turned off stays off after a relaunch (Messages, Mail, Gmail, Discord and WhatsApp not allowed)")
        var shorter = offAgain; shorter.retention = .day1
        _ = try reopened.updateTypedTextPolicy(shorter, confirmed: true, now: now)
        check(try !reopened.typedTextPolicy().categories.messagesAndEmail, "messages default: an unrelated save keeps the explicit off")
        _ = try reopened.setTypingCategory(.messagesAndEmail, on: true, now: now)
        check(try reopened.typedTextPolicy().categories.messagesAndEmail, "messages default: one click turns it back on")
        // An earlier build's row with an off kept outside it (SetupChoices, a build that recorded the checkbox there) stays off.
        let (chose, _) = try ready("messages-chose-off")
        try chose.saveSetupChoices(SetupChoices(messagesAndEmail: .off, at: iso(now)))
        try writeEarlierBuildRow(chose, messages: false)
        check(try chose.typedTextPolicyVerified() && !chose.typedTextPolicy().categories.messagesAndEmail && chose.typedTextPolicy().consented,
              "messages default: an earlier build's off on record as the person's choice (SetupChoices) stays off")
        try chose.saveSetupChoices(SetupChoices(messagesAndEmail: .on, at: iso(now)))
        check(try chose.typedTextPolicy().categories.messagesAndEmail, "control: an earlier build's row with the choice on record as on reads on")
        // An earlier build's row changed by something else (no valid MAC) still fails closed: locked, messages off.
        let (forged, _) = try ready("messages-forged")
        try writeEarlierBuildRow(forged, messages: true)
        try forged.exec("DELETE FROM metadata WHERE id=?", [MemoryStore.typedPolicyMACID])
        let forgedSeen = try forged.typedTextPolicy()
        check(!forgedSeen.categories.messagesAndEmail && !forgedSeen.consented, "messages default: an unsigned earlier row still reads messages off and typing locked")

        // Finding: a whole short draft could live on in a note (and reach AI apps).
        let (guardStore, _) = try ready("short-guard")
        let t = now.addingTimeInterval(-8 * day)
        check(try guardStore.ingest(typed("S1", "divorce lawyer near me", at: t), now: t), "a short search")
        _ = try guardStore.writePending(now: t)
        let request = try guardStore.prepareNote(kind: "day", day: TypedTextVault.epoch(for: t), timezone: "UTC", now: t)
        rejects("a note that carries a whole short search is refused at commit", saying: "may not copy") {
            _ = try guardStore.commitNote(NoteWriterOutput(requestID: request.id, title: "Search", bullets: [NoteBullet(text: "Searched for divorce lawyer near me", actionIDs: ["S1"], assertion: "draft")], generator: "fixture", generatorVersion: "1"), now: t)
        }
        rejects("two words in a row from a 4-word draft are refused", saying: "may not copy") {
            _ = try guardStore.commitNote(NoteWriterOutput(requestID: request.id, title: "Search", bullets: [NoteBullet(text: "Looked up a divorce lawyer", actionIDs: ["S1"], assertion: "draft")], generator: "fixture", generatorVersion: "1"), now: t)
        }
        // A note written under an older, looser rule is removed at expiry.
        try guardStore.exec("INSERT INTO generated_notes VALUES('loose-note',1,'rev',?)", [json(GeneratedNote(id: "loose-note", version: 1, schemaVersion: 1, generatedAt: iso(t), inputRevision: "rev", actionIDs: ["S1"], output: NoteWriterOutput(requestID: "q", title: "Searches", bullets: [NoteBullet(text: "Searched for divorce lawyer near me", actionIDs: ["S1"])], generator: "fixture", generatorVersion: "1"), status: "generated_unverified"))])
        let removed = try guardStore.expireTypedText(now: now)
        check(try removed.expired == 1 && removed.removedNotes == 1 && guardStore.typedAfter("S1")?.summary == "", "at expiry the note carrying the draft goes with the words; the stub keeps no summary")
        check(try guardStore.rows("SELECT id FROM generated_notes WHERE id='loose-note'").isEmpty && !guardStore.rows("SELECT * FROM typed_after").flatMap { $0 }.joined().contains("divorce"), "no copy of the search words is left in notes or stubs")
        check(try !String(describing: guardStore.assistantItem("S1", now: now) as Any).contains("divorce"), "AI apps see no search words")
        // Across a run split: a copy spanning two parts is refused.
        let (runStore, _) = try ready("run-guard")
        check(try runStore.ingest(typed("RUN1", "we should move the offsite to the lake house", at: t, run: "run-x", part: 1), now: t)
              && runStore.ingest(typed("RUN2", "because the city venue doubled its price again", at: t.addingTimeInterval(61), run: "run-x", part: 2), now: t.addingTimeInterval(62)), "two parts of one typing run")
        _ = try runStore.writePending(now: t.addingTimeInterval(62))
        let runRequest = try runStore.prepareNote(kind: "day", day: TypedTextVault.epoch(for: t), timezone: "UTC", now: t.addingTimeInterval(62))
        rejects("a copy across the split of one run is refused", saying: "may not copy") {
            _ = try runStore.commitNote(NoteWriterOutput(requestID: runRequest.id, title: "Offsite", bullets: [NoteBullet(text: "Moving the offsite to the lake house because the city venue", actionIDs: ["RUN1", "RUN2"], assertion: "draft")], generator: "fixture", generatorVersion: "1"), now: t.addingTimeInterval(62))
        }
        // Guard v2: stop words are free, so the copied run is offsite, lake, house | because, city, venue (3 + 3; 6 > 5 for the 17-word run).
        let across = "Moving the offsite to the lake house because the city venue"
        check(!TypedVerbatimGuard.copies(across, from: "we should move the offsite to the lake house")
              && !TypedVerbatimGuard.copies(across, from: "because the city venue doubled its price again")
              && TypedVerbatimGuard.copies(across, from: "we should move the offsite to the lake house because the city venue doubled its price again"), "fixture: each part alone allows that bullet; the whole run does not")
        let control = try runStore.commitNote(NoteWriterOutput(requestID: runRequest.id, title: "Offsite", bullets: [NoteBullet(text: "Picked the lake house for the offsite", actionIDs: ["RUN1", "RUN2"], assertion: "draft")], generator: "fixture", generatorVersion: "1"), now: t.addingTimeInterval(62))
        check(control.output.bullets.count == 1, "control: a bullet within the limits commits")

        // Finding: typed words in other history (titles, search pages).
        let (history, _) = try ready("history")
        check(try history.ingest(Evidence(id: "h-term", at: iso(now), kind: "window.changed", app: "Terminal", bundle: "com.apple.Terminal", title: "mysql -u root -pS3cretzz db", synthetic: true), now: now), "a terminal window row")
        check(try !(history.read("h-term", now: now)?.evidence.title ?? "S3cretzz").contains("S3cretzz"), "a terminal title goes through the typed scrubber")
        check(try history.ingest(Evidence(id: "h-search", at: iso(now), kind: "window.changed", app: "Search", bundle: "com.example.search", title: "divorce lawyer - Google Search", url: "https://www.google.com/search?q=divorce+lawyer#top", synthetic: true), now: now), "a search page row")
        let page = try history.read("h-search", now: now)?.evidence
        check(page?.url == "https://www.google.com/" && page?.title == "", "while search typing is on, a search page keeps only the site")
        check(try !history.rows("SELECT body FROM records UNION ALL SELECT body FROM summaries").flatMap { $0 }.joined().contains("divorce"), "no search word in records or summaries")
        let off = try MemoryStore(home: root.appendingPathComponent("history-off"), writable: true, automaticallySyncSearch: false)
        check(try off.ingest(Evidence(id: "h-off", at: iso(now), kind: "window.changed", app: "Search", bundle: "com.example.search", title: "pricing - Google Search", url: "https://www.google.com/search?q=pricing", synthetic: true), now: now)
              && off.read("h-off", now: now)?.evidence.url.contains("q=pricing") == true, "control: with typing off, page history is unchanged")
    }
}
