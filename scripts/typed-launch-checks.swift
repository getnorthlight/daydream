import Foundation
@testable import MemoryCore
import PrivacyPolicy

/// W0 app wiring (typesafe SPEC 12.2 items 2 and 11): what the app does with
/// typed text at launch, compiled from the app's own files
/// (TypedTextExpiryTimer.swift, TypingHotkey.swift, TypingModel.swift).
/// In-memory key stores and a fake scheduler only: no Keychain, no app
/// launch, no timer on a real run loop, no capture.
@main struct TypedLaunchChecks {
    static var count = 0
    static func check(_ value: Bool, _ label: String) { precondition(value, "FAILED: " + label); count += 1; print("PASS " + label) }

    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("typed-launch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func typed(_ id: String, _ text: String, at: Date) -> Evidence {
            Evidence(id: id, at: iso(at), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes", title: "Trip", text: text, synthetic: true)
        }
        func legacy(_ store: MemoryStore, _ e: Evidence) throws {
            let body = try json(e); try store.exec("INSERT INTO records VALUES(?,?,?)", [e.id, body, fingerprint(body)])
        }
        func raw(_ store: MemoryStore) throws -> String { try store.rows("SELECT body FROM records").flatMap { $0 }.joined(separator: "\n") }

        // A store from an earlier launch: typing on, a key in the keyring,
        // two build 4 plain-text rows and one sealed draft typed 8 days ago.
        let home = root.appendingPathComponent("launch")
        let keys = InMemoryTypedKeyStore()
        do {
            let before = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
            var policy = try before.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try before.updatePolicy(policy, now: now.addingTimeInterval(-9 * day))
            try before.attachVault(TypedTextVault(keyStore: keys), now: now.addingTimeInterval(-9 * day))
            try before.acceptSafeTyping(now: now.addingTimeInterval(-9 * day)); try before.setUpTypedVault(now: now.addingTimeInterval(-9 * day))
            check(try before.ingest(typed("S-old", "sealed eight day old words", at: now.addingTimeInterval(-8 * day)), now: now.addingTimeInterval(-8 * day)), "setup: a sealed draft from 8 days ago")
            try legacy(before, typed("B-new", "launchfresh two day old words", at: now.addingTimeInterval(-2 * day)))
            try legacy(before, typed("B-old", "launchancient twenty day old words", at: now.addingTimeInterval(-20 * day)))
        }

        // Relaunch: a new store instance with no vault, then the launch wiring.
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        check(store.typedVaultState == .unavailable, "before launch wiring the store has no vault")
        var asked = [String]()
        var scheduled = [(interval: TimeInterval, work: () -> Void)]()
        var cancelled = 0
        var clock = now
        let launch = TypedTextLaunch.wire(store: store, keys: { id in asked.append(id); return keys }, now: { clock }) { interval, work in
            scheduled.append((interval, work)); return { cancelled += 1 }
        }
        check(try asked == [store.coreStoreID() ?? "missing"] && !asked[0].isEmpty, "the keyring is named by this store's core_store_id, asked once")
        check(launch.vault == .ready && store.typedVaultState == .ready, "the vault is attached at launch and reads ready with the saved key")
        check(try store.hydrateTypedText("B-new", disclosure: .owner, now: now) == "launchfresh two day old words", "decision 6: a build 4 row inside the period is sealed at launch")
        check(try !raw(store).contains("launchfresh") && !raw(store).contains("launchancient"), "no build 4 word is left in plain text after launch")
        check(try store.typedAfter("B-old")?.source == "stub", "a build 4 row past the period keeps only a stub")
        check((launch.settled ?? 0) >= 1, "settleLegacyTypedText ran at launch")
        // typingfix review: the one-time website settle runs at launch too; a build without website typing has
        // no website rules, so it deletes nothing and leaves no mark (an owner build later still settles once).
        check(try launch.websiteSettled == 0 && store.rows("SELECT id FROM metadata WHERE id='typed-web-settle-v1'").isEmpty == (MemoryStore.websiteRows == nil),
              "the one-time website settle ran at launch: nothing to do without website typing")
        check(launch.timer.runs == 1 && launch.timer.lastReport?.expired == 1 && !launch.timer.lastFailed, "expiry runs once at launch and deletes the 8 day old words")
        check(try store.hydrateTypedText("S-old", disclosure: .owner, now: now) == nil, "the expired draft no longer opens")
        check(scheduled.count == 1 && scheduled[0].interval == 3600, "one repeating job every hour")

        // An hour later the job runs again and deletes what has aged out since.
        check(try store.ingest(typed("S-edge", "words typed just inside the week", at: now.addingTimeInterval(-7 * day + 1800)), now: now), "a draft half an hour from the 7 day line")
        check(try store.hydrateTypedText("S-edge", disclosure: .owner, now: now) == "words typed just inside the week", "it opens before the hourly run")
        clock = now.addingTimeInterval(3600); scheduled[0].work()
        check(launch.timer.runs == 2 && launch.timer.lastReport?.expired == 1, "the hourly run deletes words that aged out during the hour")
        check(try store.rows("SELECT id FROM typed_text WHERE id='S-edge'").isEmpty, "their sealed row is gone from typed_text")
        launch.timer.stop()
        check(cancelled == 1, "stop cancels the hourly job")
        launch.timer.start { _, _ in { cancelled += 1 } }
        check(launch.timer.runs == 3, "start runs the job again at once")
        launch.timer.stop()

        // Controls: without the wiring the same store keeps the plain text and
        // the old words (so the checks above fail without it).
        let controlHome = root.appendingPathComponent("control")
        let controlKeys = InMemoryTypedKeyStore()
        do {
            let before = try MemoryStore(home: controlHome, writable: true, automaticallySyncSearch: false)
            var policy = try before.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try before.updatePolicy(policy, now: now)
            try before.attachVault(TypedTextVault(keyStore: controlKeys), now: now); try before.acceptSafeTyping(now: now); try before.setUpTypedVault(now: now)
            try legacy(before, typed("C-new", "controlfresh plain words", at: now.addingTimeInterval(-2 * day)))
        }
        let control = try MemoryStore(home: controlHome, writable: true, automaticallySyncSearch: false)
        check(try control.typedVaultState == .unavailable && raw(control).contains("controlfresh"), "control: a store opened without the launch wiring has no vault and keeps build 4 plain text")

        // No key saved for this store: typing stays locked; build 4 words are
        // deleted (never sealed under a new key); expiry still runs.
        let lostHome = root.appendingPathComponent("no-key")
        do {
            let before = try MemoryStore(home: lostHome, writable: true, automaticallySyncSearch: false)
            var policy = try before.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try before.updatePolicy(policy, now: now)
            try legacy(before, typed("L-new", "nokeyfresh plain words", at: now.addingTimeInterval(-1 * day)))
        }
        let lost = try MemoryStore(home: lostHome, writable: true, automaticallySyncSearch: false)
        let lostLaunch = TypedTextLaunch.wire(store: lost, keys: { _ in InMemoryTypedKeyStore() }, now: { now }) { _, _ in {} }
        check(lostLaunch.vault != .ready && lost.typedVaultState != .ready, "no saved key: the vault is attached but never ready (no key is made at launch)")
        check(try !raw(lost).contains("nokeyfresh") && lost.typedAfter("L-new")?.source == "stub", "no ready key: build 4 words are deleted at launch, a stub stays")
        check(lostLaunch.timer.runs == 1, "no ready key: expiry still runs at launch")
        lostLaunch.timer.stop()

        // gold/r2-store-perf review round 1: after launch prepared the history (off the main thread, before the model),
        // the website settle was the preparation's work (HistoryPreparation.finish). The model's open (`.prepared`, on
        // the main thread) leaves it: the preparation settled the rows, or the next launch's preparation will; it never
        // reads every record here. Any other open settles at launch as before.
        let preparedHome = root.appendingPathComponent("prepared")
        _ = try MemoryStore(home: preparedHome, writable: true, automaticallySyncSearch: false)
        let preparedStore = try MemoryStore(home: preparedHome, writable: true, automaticallySyncSearch: false, launchWork: .prepared)
        let preparedLaunch = TypedTextLaunch.wire(store: preparedStore, keys: { _ in keys }, now: { now }) { _, _ in {} }
        check(try preparedLaunch.websiteSettled == nil && preparedStore.rows("SELECT id FROM metadata WHERE id='typed-web-settle-v1'").isEmpty && preparedLaunch.timer.runs == 1,
              "after launch prepared the history, the website settle is left to the preparation (never read on the main thread); expiry still runs")
        preparedLaunch.timer.stop()

        // A read-only store: nothing attached, nothing written, no crash.
        let readOnly = try MemoryStore(home: home, writable: false, automaticallySyncSearch: false)
        let readOnlyLaunch = TypedTextLaunch.wire(store: readOnly, keys: { _ in keys }, now: { now }) { _, _ in {} }
        check(readOnlyLaunch.vault == nil && readOnlyLaunch.timer.runs == 1 && readOnlyLaunch.timer.lastReport?.expired == 0, "a read-only store takes no vault and the job writes nothing")
        readOnlyLaunch.timer.stop()

        // The typed clock high-water outlives the process: a later launch
        // whose clock went back still keeps words hidden that were hidden.
        let relaunched = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        _ = TypedTextLaunch.wire(store: relaunched, keys: { _ in keys }, now: { now.addingTimeInterval(-2 * day) }) { _, _ in {} }.timer
        check(try relaunched.hydrateTypedText("B-new", disclosure: .owner, now: now.addingTimeInterval(-2 * day)) == "launchfresh two day old words", "the relaunch opens words still inside the period")
        check(try relaunched.savedTypedClock().map { $0 >= now.addingTimeInterval(3600) } == true, "the saved high-water is the latest clock used (the hourly run)")

        // The pause chord (EventCapture skips its shortcut row).
        check(TypingHotkey.isPauseChord(KeyStroke(keyCode: 17, command: true, control: true, option: true)), "pause chord: Control-Option-Command-T")
        check(!TypingHotkey.isPauseChord(KeyStroke(keyCode: 17, command: true, control: true, option: true, shift: true))
              && !TypingHotkey.isPauseChord(KeyStroke(keyCode: 17, command: true, option: true))
              && !TypingHotkey.isPauseChord(KeyStroke(keyCode: 15, command: true, control: true, option: true))
              && !TypingHotkey.isPauseChord(KeyStroke(keyCode: -1, command: true, control: true, option: true)), "pause chord: nothing else matches")
        // The ui track registers the chord with Carbon; here a fake stands in for RegisterEventHotKey.
        let registrar = LaunchFakeRegistrar()
        check(TypingHotkey.install(onPause: {}, registrar: registrar) && registrar.calls == [[17, UInt32(4096 | 2048 | 256)]],
              "the global chord is registered once: T with exactly Control, Option and Command")

        // TypingModel reads the store; snooze and resume change it.
        let model = TypingModel(now: { now })
        model.refresh(frontmostBundle: "com.apple.Notes")
        check(model.indicator == .off, "model: no store attached reads off")
        model.attach(relaunched, hotkeys: nil)
        model.refresh(frontmostBundle: "com.apple.Notes")
        check(model.vault == .ready && model.policy.consented, "model: reads the vault state and the saved typing settings")
        let until = try model.snooze(frontmostBundle: "com.apple.Notes")
        check(until == now.addingTimeInterval(600) && model.snoozed && !model.policy.snoozeUntil.isEmpty, "model: snooze pauses typing for 10 minutes")
        check(model.indicator == .off, "model: with recording stopped the indicator stays off")
        try model.resume(frontmostBundle: "com.apple.Notes")
        check(!model.snoozed && model.policy.snoozeUntil.isEmpty, "model: resume records typing again")

        // typing-all final review: a locked Keychain doesn't stop typing for
        // the rest of the session. A seal while the Keychain is locked leaves
        // the vault locked; after the unlock the hourly job, the model's
        // refresh and "Try again" each read it again.
        keys.locked = true
        check((try? relaunched.ingest(typed("K-locked", "typed while the keychain was locked", at: now), now: now)) != true
              && relaunched.typedVaultState == .locked, "a seal with the Keychain locked leaves the vault locked")
        check(try relaunched.retryLockedTypedVault(now: now) == .locked, "while still locked, reading again keeps it locked")
        keys.locked = false
        let lockedTimer = TypedTextExpiryTimer(store: relaunched, now: { now })
        lockedTimer.run()
        check(relaunched.typedVaultState == .ready, "after the unlock, the hourly job reads the Keychain again and typing resumes")
        keys.locked = true
        _ = try? relaunched.ingest(typed("K-locked-2", "typed while the keychain was locked again", at: now), now: now)
        check(relaunched.typedVaultState == .locked, "locked again")
        keys.locked = false
        var later = now
        let unlockModel = TypingModel(now: { later })
        unlockModel.attach(relaunched, hotkeys: nil)
        check(unlockModel.vault == .ready && relaunched.typedVaultState == .ready, "after the unlock, the model's refresh (app activation) reads the Keychain again")
        keys.locked = true
        _ = try? relaunched.ingest(typed("K-locked-3", "typed while the keychain was locked a third time", at: now), now: now)
        keys.locked = false
        unlockModel.refresh(frontmostBundle: "com.apple.Notes")
        check(unlockModel.vault == .locked, "the refresh reads a locked Keychain at most every 30 seconds")
        unlockModel.retryUnlock()
        check(unlockModel.vault == .ready && unlockModel.indicator != .locked(.keychainLocked), "Try again (and an unlock or wake) reads it at once")
        later = now.addingTimeInterval(60)
        check(try relaunched.retryLockedTypedVault(now: later) == .ready, "reading again does nothing once the vault is ready")

        print("\(count) typed launch checks passed. No Keychain, app launch, run-loop timer or capture.")
    }
}

/// Records what would be registered with Carbon; never touches the system.
final class LaunchFakeRegistrar: TypingHotkeyRegistrar {
    var calls: [[UInt32]] = []
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> TypingHotkeyRegistration {
        calls.append([keyCode, modifiers]); return .registered
    }
    func unregister() {}
}
