// DD-RECIPE: SRC Sources/MacMemApp/WakeSystem.swift Sources/MacMemApp/WakeResume.swift Sources/MacMemApp/LaunchLocation.swift
//
// The screen lock is heard while DayDream is in the background. AppKit suspends an inactive app's distributed
// notification center, and an observer with the default suspension behavior (the block API's) then gets nothing until
// the app is next activated: the lock and unlock arrived together when the person clicked into DayDream, so
// recording went on behind the lock screen and the "Paused for screen lock" pause landed late. ScreenLockObserver
// asks for immediate delivery.
//
// Uses its own notification names (never com.apple.screenIsLocked or screenIsUnlocked): nothing else hears them.
// No app, no permission, no capture.
//
//   swiftc -parse-as-library Sources/MacMemApp/WakeSystem.swift Sources/MacMemApp/WakeResume.swift \
//     Sources/MacMemApp/LaunchLocation.swift scripts/lock-notice-delivery-checks.swift -o lock-notice && ./lock-notice
import AppKit

/// An observer with the default suspension behavior (`.coalesce`), for comparison. In an app, the block API's
/// observers behaved the same way (held while suspended, then delivered together, unlock first).
final class DefaultObserver: NSObject {
    var locks = 0
    @objc func heard(_ note: Notification) { locks += 1 }
}

@main enum LockNoticeDeliveryChecks {
    static var passes = 0
    static func check(_ ok: Bool, _ name: String) {
        guard ok else { FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8)); exit(1) }
        passes += 1; print("PASS " + name)
    }
    /// Runs the main run loop until `done` or `seconds` pass.
    static func spin(_ seconds: TimeInterval, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

    static func main() {
        let center = DistributedNotificationCenter.default()
        let tag = UUID().uuidString
        let lock = Notification.Name("com.getnorthlight.daydream.checks.lock-" + tag)
        let unlock = Notification.Name("com.getnorthlight.daydream.checks.unlock-" + tag)
        // The comparison has a name of its own: once any observer in a process asks for immediate delivery of a name,
        // every observer of that name in the process hears it at once.
        let other = Notification.Name("com.getnorthlight.daydream.checks.other-" + tag)
        var locks = 0, unlocks = 0, offMain = 0
        var observer: ScreenLockObserver? = ScreenLockObserver(lockedName: lock, unlockedName: unlock,
            locked: { locks += 1; if !Thread.isMainThread { offMain += 1 } },
            unlocked: { unlocks += 1; if !Thread.isMainThread { offMain += 1 } })
        // For comparison: an observer with the default suspension behavior.
        let control = DefaultObserver()
        center.addObserver(control, selector: #selector(DefaultObserver.heard(_:)), name: other, object: nil, suspensionBehavior: .coalesce)

        // DayDream in the background: AppKit has suspended its distributed center.
        center.suspended = true
        center.postNotificationName(lock, object: nil, userInfo: nil, deliverImmediately: false)
        center.postNotificationName(other, object: nil, userInfo: nil, deliverImmediately: false)
        spin(5) { locks == 1 }
        check(locks == 1, "the lock is heard while the app is in the background")
        spin(0.5) { false }
        check(control.locks == 0, "an observer with the default suspension behavior hears nothing while the app is in the background")
        center.postNotificationName(unlock, object: nil, userInfo: nil, deliverImmediately: false)
        spin(5) { unlocks == 1 }
        check(unlocks == 1 && locks == 1, "the unlock is heard at once too, once")
        check(offMain == 0, "the handlers run on the main thread")
        // The app becomes active again: only then did the old observer hear the lock, long after it happened.
        center.suspended = false
        spin(5) { control.locks == 1 }
        check(control.locks == 1, "it hears the lock only once the app is active again (why the pause came late)")
        check(locks == 1, "and the lock observer hears it once only")

        // Released, it hears nothing more.
        observer = nil
        center.postNotificationName(lock, object: nil, userInfo: nil, deliverImmediately: true)
        center.postNotificationName(other, object: nil, userInfo: nil, deliverImmediately: true)
        spin(5) { control.locks == 2 }
        spin(0.5) { false }
        check(control.locks == 2 && locks == 1, "a released observer is removed from the center")
        center.removeObserver(control)
        _ = observer
        print("PASS all \(passes) lock-notice delivery checks. Own notification names only; no app, permission or capture.")
    }
}
