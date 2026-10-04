import Foundation
@testable import MemoryCore

@main struct OnboardingTypingChoiceChecks {
    static var count = 0
    static let marker = "native-typing-choice-pending-v1"

    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) rethrows {
        let value = try condition()
        precondition(value, label)
        count += 1
        print("PASS " + label)
    }

    static func main() throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("onboarding-typing-synthetic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func store(_ name: String) throws -> MemoryStore {
            try MemoryStore(home: root.appendingPathComponent(name), writable: true, automaticallySyncSearch: false)
        }
        func markerRows(_ value: MemoryStore) throws -> [[String]] {
            try value.rows("SELECT body FROM metadata WHERE id=?", [marker])
        }
        func noCapture(_ value: MemoryStore) throws -> Bool {
            try value.captureStatus()["state"] == "off"
        }

        let fresh = try store("fresh")
        let firstPolicy = try fresh.policy()
        try check(fresh.nativeTypingChoicePending(), "new store offers its first typing choice")
        try check(markerRows(fresh) == [[firstPolicy.revision]], "pending choice is pinned to the original privacy revision")
        check(!firstPolicy.captureText && firstPolicy.typedConsentVersion == nil, "new-store capture policy remains typing off without consent")
        try check(noCapture(fresh), "new-store recording remains off")
        let beforeReads = try fresh.rows("SELECT * FROM metadata ORDER BY id")
        let readOnly = try MemoryStore(home: fresh.home)
        try check(readOnly.nativeTypingChoicePending(), "pending choice survives read-only reopen")
        try check(fresh.rows("SELECT * FROM metadata ORDER BY id") == beforeReads, "reading the first-choice flag does not mutate metadata")
        let reopened = try MemoryStore(home: fresh.home, writable: true, automaticallySyncSearch: false)
        try check(reopened.nativeTypingChoicePending(), "pending choice survives writable reopen")
        try check(reopened.policy() == firstPolicy, "reopening does not alter original privacy settings")

        let off = try store("explicit-off")
        let offPolicy = try off.policy()
        try off.exec("INSERT INTO grants VALUES('fixture','synthetic unchanged authority')")
        let offGrants = try off.rows("SELECT * FROM grants ORDER BY id")
        let beforeOff = try off.rows("SELECT * FROM metadata WHERE id<>? ORDER BY id", [marker])
        // fix/typing-e2e (L3): the setup page that showed the typing switch says so (`typingChoiceShown`).
        let savedOff = try off.savePreferences(MemoryPreferences(blockedApps: offPolicy.blockedApps, nativeTyping: false, typingChoiceShown: true), expectedRevision: offPolicy.revision)
        check(!savedOff.changed && savedOff.revokedGrantCount == 0, "explicit Off is a privacy no-op")
        try check(!off.nativeTypingChoicePending() && markerRows(off).isEmpty, "explicit Off consumes the pending choice")
        try check(off.policy() == offPolicy, "explicit Off preserves policy bytes and revision")
        try check(off.rows("SELECT * FROM grants ORDER BY id") == offGrants, "explicit Off preserves existing grants")
        try check(off.rows("SELECT * FROM metadata WHERE id<>? ORDER BY id", [marker]) == beforeOff, "explicit Off changes only the choice marker")
        let offReopened = try MemoryStore(home: off.home, writable: true, automaticallySyncSearch: false)
        try check(!offReopened.nativeTypingChoicePending(), "saved Off stays reviewed on restart")
        try check(!offReopened.policy().captureText, "saved Off is not changed on restart")

        // fix/typing-e2e (L3): a save from a surface that never showed the typing switch (an app excluded in Settings)
        // answers nothing: the first typing choice stays pending, carried to the new revision.
        let unrelated = try store("unrelated-save")
        let unrelatedPolicy = try unrelated.policy()
        let savedUnrelated = try unrelated.savePreferences(MemoryPreferences(blockedApps: unrelatedPolicy.blockedApps + ["com.example.synthetic-excluded"], nativeTyping: false),
                                                           expectedRevision: unrelatedPolicy.revision)
        try check(savedUnrelated.changed && unrelated.nativeTypingChoicePending() && markerRows(unrelated) == [[savedUnrelated.policy.revision]],
                  "an unrelated save (an app excluded) keeps the first typing choice pending")
        try check(unrelated.setupChoices() == SetupChoices(), "an unrelated save leaves the explicit choices unset (typing seeds on)")

        let on = try store("explicit-on")
        let onInitial = try on.policy()
        let savedOn = try on.savePreferences(MemoryPreferences(blockedApps: onInitial.blockedApps, nativeTyping: true), expectedRevision: onInitial.revision)
        check(savedOn.changed && savedOn.policy.captureText && savedOn.policy.typedConsentVersion == 1, "explicit On stores typed-text consent")
        try check(!on.nativeTypingChoicePending() && markerRows(on).isEmpty, "explicit On consumes the pending choice")
        try check(noCapture(on), "saving On still does not start recording")

        // Consent audit 9/28: setup's switches start on (opt-out). An AI app connected before Start keeps its key when
        // the first setup saves typing and Web pages in Chrome on as they started; the same change later revokes keys.
        let firstOn = try store("first-setup-keeps-grants")
        let firstOnPolicy = try firstOn.policy()
        try firstOn.exec("INSERT INTO grants VALUES('fixture','synthetic authority made before Start')")
        let keptGrants = try firstOn.rows("SELECT * FROM grants ORDER BY id")
        let firstSaved = try firstOn.savePreferences(MemoryPreferences(blockedApps: firstOnPolicy.blockedApps, nativeTyping: true, browserPages: true),
                                                     expectedRevision: firstOnPolicy.revision)
        check(firstSaved.changed && firstSaved.policy.captureText && firstSaved.policy.browserPagesOn && firstSaved.revokedGrantCount == 0,
              "first setup: typing and Web pages in Chrome saved on as they started revoke no AI app key")
        try check(firstOn.rows("SELECT * FROM grants ORDER BY id") == keptGrants, "first setup: the AI app connected before Start keeps its grant")
        let offAgain = try firstOn.savePreferences(MemoryPreferences(blockedApps: firstSaved.policy.blockedApps, nativeTyping: false, browserPages: false),
                                                   expectedRevision: firstSaved.policy.revision)
        try check(firstOn.rows("SELECT * FROM grants ORDER BY id") == keptGrants, "turning both off later keeps the grant (it shares less)")
        let laterOn = try firstOn.savePreferences(MemoryPreferences(blockedApps: offAgain.policy.blockedApps, nativeTyping: true, browserPages: true),
                                                  expectedRevision: offAgain.policy.revision)
        try check(laterOn.revokedGrantCount == 1 && firstOn.rows("SELECT * FROM grants").isEmpty,
                  "after the first setup, turning typing and Chrome pages on shares more: AI app keys are revoked")
        // Excluding fewer apps in the first setup still shares more (a fixture exclusion first, then setup drops it).
        let unexclude = try store("first-setup-unexclude")
        var unexcludePolicy = try unexclude.policy()
        unexcludePolicy.blockedApps.append("com.example.synthetic-excluded")
        unexcludePolicy.revision = UUID().uuidString
        try unexclude.exec("UPDATE metadata SET body=? WHERE id='policy'", [String(decoding: JSONEncoder().encode(unexcludePolicy), as: UTF8.self)])
        try unexclude.exec("UPDATE metadata SET body=? WHERE id=?", [unexcludePolicy.revision, marker])
        try unexclude.exec("INSERT INTO grants VALUES('fixture','synthetic authority made before Start')")
        let dropped = try unexclude.savePreferences(MemoryPreferences(blockedApps: unexcludePolicy.blockedApps.filter { $0 != "com.example.synthetic-excluded" },
                                                                      nativeTyping: true, browserPages: true), expectedRevision: unexcludePolicy.revision)
        check(dropped.revokedGrantCount == 1, "first setup: excluding fewer apps still shares more and revokes keys")

        let stale = try store("stale-save")
        let stalePolicy = try stale.policy()
        do {
            _ = try stale.savePreferences(MemoryPreferences(blockedApps: stalePolicy.blockedApps, nativeTyping: false), expectedRevision: "stale-revision")
            preconditionFailure("stale save must be rejected")
        } catch PreferenceSaveError.revisionConflict {}
        try check(stale.nativeTypingChoicePending(), "revision-conflicted save leaves the first choice pending")
        try check(markerRows(stale) == [[stalePolicy.revision]], "revision-conflicted save preserves its marker")

        let invalid = try store("invalid-save")
        let invalidPolicy = try invalid.policy()
        do {
            _ = try invalid.savePreferences(MemoryPreferences(blockedApps: ["invalid app"], nativeTyping: false), expectedRevision: invalidPolicy.revision)
            preconditionFailure("invalid save must be rejected")
        } catch PreferenceSaveError.invalidApps {}
        try check(invalid.nativeTypingChoicePending(), "invalid app choices do not consume first typing choice")

        let failed = try store("failed-write")
        let failedPolicy = try failed.policy()
        try failed.exec("CREATE TRIGGER fail_choice_delete BEFORE DELETE ON metadata WHEN OLD.id='native-typing-choice-pending-v1' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
        do {
            _ = try failed.savePreferences(MemoryPreferences(blockedApps: failedPolicy.blockedApps, nativeTyping: true), expectedRevision: failedPolicy.revision)
            preconditionFailure("marker persistence failure must reject save")
        } catch PreferenceSaveError.storageUnavailable {}
        try check(failed.nativeTypingChoicePending() && failed.policy() == failedPolicy, "failed marker removal rolls back typed-text consent and revision")

        let legacy = try store("legacy-no-marker")
        try legacy.exec("DELETE FROM metadata WHERE id=?", [marker])
        let legacyPolicy = try legacy.policy()
        try check(!legacy.nativeTypingChoicePending(), "existing store without marker is not treated as fresh")
        let legacyReopened = try MemoryStore(home: legacy.home, writable: true, automaticallySyncSearch: false)
        try check(!legacyReopened.nativeTypingChoicePending() && markerRows(legacyReopened).isEmpty, "opening an existing store never invents pending choice")
        try check(legacyReopened.policy() == legacyPolicy && !legacyReopened.policy().captureText, "existing saved Off is preserved unchanged")

        let superseded = try store("superseded-policy")
        let supersededInitial = try superseded.policy()
        var replacement = supersededInitial
        replacement.revision = UUID().uuidString
        try superseded.exec("UPDATE metadata SET body=? WHERE id='policy'", [json(replacement)])
        try check(!superseded.nativeTypingChoicePending(), "unrelated policy revision change suppresses a stale first-choice default")
        try check(markerRows(superseded) == [[supersededInitial.revision]], "stale-marker detection is read-only")

        let consented = try store("consented-policy")
        var consentedPolicy = try consented.policy()
        consentedPolicy.captureText = true
        consentedPolicy.typedConsentVersion = 1
        try consented.exec("UPDATE metadata SET body=? WHERE id='policy'", [json(consentedPolicy)])
        try check(!consented.nativeTypingChoicePending(), "existing typed consent is never classified as a first choice")

        let backupSource = try store("backup-source")
        let backupDestination = try store("backup-destination")
        try check(backupDestination.nativeTypingChoicePending(), "new backup destination initially has its own first-choice marker")
        _ = try backupSource.exportCanonicalSnapshot(to: backupDestination)
        try check(backupSource.nativeTypingChoicePending(), "backup export preserves the source first-choice marker")
        try check(markerRows(backupDestination).isEmpty && !backupDestination.nativeTypingChoicePending(), "export strips destination onboarding choice instead of transferring it")
        try check(backupDestination.inspectCanonicalSnapshot().capture == "off", "canonical backup remains valid and recording off")
        let backupReopened = try MemoryStore(home: backupDestination.home, writable: true, automaticallySyncSearch: false)
        try check(!backupReopened.nativeTypingChoicePending(), "opening exported backup does not recreate a fresh choice")

        print("\(count) typing-choice checks passed. Synthetic stores only; no capture, real permissions, providers, or user preferences changed.")
    }
}
