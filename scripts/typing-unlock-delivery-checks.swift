// DD-RECIPE: SRC Sources/MacMemApp/TypedTextExpiryTimer.swift Sources/MacMemApp/TypingHotkey.swift Sources/MacMemApp/TypingModel.swift + MemoryCore HistoryCore PrivacyPolicy
//
// Typing's model (golden test 5), compiled from the app's own files like typed-launch-checks.swift.
//   G58  "Typing is paused until you unlock your Mac": the unlock is heard while DayDream is in the background. AppKit
//        suspends an inactive app's distributed center, and the block observer typing had heard nothing until
//        DayDream was next active, so typing stayed locked after the unlock until then.
//   G74a The end-of-pause refresh and the toast clear: one of each waits at a time; a replaced one is cancelled and
//        does nothing if it runs anyway (they piled up, and an old toast clear hid a newer toast early).
// In-memory key store, a synthetic store under TMPDIR, the model's scheduler recorded (nothing waits), and a
// notification name of its own (never com.apple.screenIsUnlocked). No Keychain, app launch, capture or permission.
import Foundation
import AppKit
@testable import MemoryCore
import PrivacyPolicy

@main struct TypingUnlockDeliveryChecks {
    static var count = 0
    static func check(_ value: Bool, _ label: String) {
        guard value else { FileHandle.standardError.write(Data("FAIL: \(label)\n".utf8)); exit(1) }
        count += 1; print("PASS " + label)
    }
    static func spin(_ seconds: TimeInterval, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("typing-unlock-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let keys = InMemoryTypedKeyStore()
        let store = try MemoryStore(home: root.appendingPathComponent("store"), writable: true, automaticallySyncSearch: false)
        var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try store.updatePolicy(policy, now: now)
        try store.attachVault(TypedTextVault(keyStore: keys), now: now); try store.acceptSafeTyping(now: now); try store.setUpTypedVault(now: now)
        func typed(_ id: String) -> Evidence {
            Evidence(id: id, at: iso(now), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes", title: "Trip", text: "typed while locked", synthetic: true)
        }

        // G58. The Keychain locks; typing locks with it.
        keys.locked = true
        _ = try? store.ingest(typed("K-1"), now: now)
        check(store.typedVaultState == .locked, "setup: a seal with the Keychain locked leaves typing locked")
        let tag = UUID().uuidString
        let unlock = Notification.Name("com.getnorthlight.daydream.checks.unlock-" + tag)
        let other = Notification.Name("com.getnorthlight.daydream.checks.unlock-block-" + tag)
        TypingModel.unlockNotification = unlock
        let model = TypingModel(now: { now })
        model.frontmostBundle = { "com.apple.Notes" }
        model.attach(store, hotkeys: nil)
        check(model.vault == .locked, "setup: the model reads typing locked")
        let center = DistributedNotificationCenter.default()
        var blockHeard = 0
        // For comparison, the observer typing had before (the block API, default suspension behavior).
        let block = center.addObserver(forName: other, object: nil, queue: .main) { _ in blockHeard += 1 }
        // The person unlocks the Mac while DayDream is in the background (AppKit has suspended its center). The model's
        // clock stands still, so its own every-30-seconds read can't be what reads the Keychain again.
        keys.locked = false
        center.suspended = true
        center.postNotificationName(unlock, object: nil, userInfo: nil, deliverImmediately: false)
        center.postNotificationName(other, object: nil, userInfo: nil, deliverImmediately: false)
        spin(5) { model.vault == .ready }
        check(model.vault == .ready && store.typedVaultState == .ready, "G58: the unlock is heard while DayDream is in the background: typing is no longer locked")
        spin(0.5) { false }
        check(blockHeard == 0, "G58: the old block observer hears nothing while DayDream is in the background (typing stayed locked until DayDream was opened)")
        center.suspended = false
        spin(5) { blockHeard == 1 }
        check(blockHeard == 1, "G58: it hears the unlock only once DayDream is active again")
        center.removeObserver(block)

        // G74a. The model's scheduler is recorded: nothing waits, and each item can be run by hand.
        var items: [(seconds: TimeInterval, work: () -> Void, item: DispatchWorkItem)] = []
        model.after = { seconds, work in let item = DispatchWorkItem(block: work); items.append((seconds, work, item)); return item }
        var shown: [String] = []
        model.presentToast = { shown.append($0) }
        func endOfPause() -> [(seconds: TimeInterval, work: () -> Void, item: DispatchWorkItem)] { items.filter { $0.seconds > TypingToast.seconds } }
        func toasts() -> [(seconds: TimeInterval, work: () -> Void, item: DispatchWorkItem)] { items.filter { $0.seconds == TypingToast.seconds } }
        try store.setCaptureState("recording", reason: "", now: now)
        model.refresh()
        check(model.indicator == .recording(app: "Notes"), "setup: recording with typing on")

        try model.snooze(frontmostBundle: "com.apple.Notes")
        check(endOfPause().count == 1 && !endOfPause()[0].item.isCancelled, "G74a: a pause waits for its end with one refresh")
        try model.resume(frontmostBundle: "com.apple.Notes")
        check(endOfPause()[0].item.isCancelled, "G74a: resuming cancels the refresh waiting for the pause's end")
        for _ in 0..<4 { try model.snooze(frontmostBundle: "com.apple.Notes"); try model.resume(frontmostBundle: "com.apple.Notes") }
        try model.snooze(frontmostBundle: "com.apple.Notes")
        check(endOfPause().count == 6 && endOfPause().filter { !$0.item.isCancelled }.count == 1,
              "G74a: after six pauses only the last one's refresh is waiting (they piled up, one per pause)")
        // A replaced refresh that runs anyway (already on its way) does nothing: no second refresh is set up.
        let before = items.count
        endOfPause()[0].work()
        model.refresh()
        check(items.count == before, "G74a: a replaced end-of-pause refresh that runs anyway does nothing (no duplicate is scheduled)")
        try model.resume(frontmostBundle: "com.apple.Notes")

        // The toast: a second press replaces the first one's clear.
        model.pauseFromShortcut()
        check(shown.count == 1 && model.toast != nil && toasts().count == 1, "setup: the shortcut pauses typing and shows the toast")
        try model.resume(frontmostBundle: "com.apple.Notes")
        model.pauseFromShortcut()
        check(shown.count == 2 && toasts().count == 2 && toasts()[0].item.isCancelled && !toasts()[1].item.isCancelled,
              "G74a: a second toast replaces the first one's clear")
        toasts()[0].work()
        check(model.toast != nil, "G74a: the first toast's clear, run anyway, leaves the second toast up (it hid it early)")
        toasts()[1].work()
        check(model.toast == nil, "G74a: the second toast's own clear takes it down")
        print("PASS all \(count) typing unlock and scheduling checks. Own notification names; no Keychain, app or capture.")
    }
}
