import AppKit
import CoreGraphics
import UserNotifications

// What the sleep/lock rules (WakeResume.swift) need from macOS, injectable so the checks run without it:
// the lock and console reads, the delay, and the one notification. Reads only: nothing here asks for a
// permission except the notification center, and only when recording first starts.

struct WakeSystem {
    /// The login window covers this session (the screen is locked). A read of the session dictionary.
    var screenLocked: () -> Bool
    /// This login session is the one on screen (not switched away from).
    var onConsole: () -> Bool
    /// Runs `work` on the main queue after `delay` seconds.
    var after: (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void
    var now: () -> Date

    static let live = WakeSystem(
        screenLocked: { WakeSystem.sessionFlag("CGSSessionScreenIsLocked") ?? false },
        onConsole: { WakeSystem.sessionFlag(kCGSessionOnConsoleKey as String) ?? true },
        after: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
        now: { Date() })

    private static func sessionFlag(_ key: String) -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return (session[key] as? NSNumber)?.boolValue ?? (session[key] as? Bool)
    }

    /// Screen lock and unlock arrive as distributed notifications.
    static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")
}

/// Hears the screen lock and unlock as they happen, whether or not DayDream is the active app.
///
/// AppKit suspends the distributed notification center while an app is inactive (`-[NSApplication
/// _handleDeactivateEvent:]` sets it suspended) and resumes it on activation. Observers with the default suspension
/// behavior (the block API's, `.coalesce`) then get nothing until the person next clicks into DayDream, and the lock
/// and unlock arrive back to back, sometimes in the wrong order. So recording went on behind the lock screen, and the
/// "Paused for screen lock" pause landed when the person opened DayDream. `.deliverImmediately` delivers them at once.
final class ScreenLockObserver: NSObject {
    private let center: DistributedNotificationCenter
    private let lockedName: Notification.Name
    private let unlockedName: Notification.Name
    private let locked: () -> Void
    private let unlocked: () -> Void

    /// `locked` and `unlocked` run on the main thread. The names are the system's; the checks pass their own.
    init(center: DistributedNotificationCenter = .default(), lockedName: Notification.Name = WakeSystem.screenLocked,
         unlockedName: Notification.Name = WakeSystem.screenUnlocked, locked: @escaping () -> Void, unlocked: @escaping () -> Void) {
        self.center = center; self.lockedName = lockedName; self.unlockedName = unlockedName
        self.locked = locked; self.unlocked = unlocked
        super.init()
        center.addObserver(self, selector: #selector(screenDidLock(_:)), name: lockedName, object: nil, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(screenDidUnlock(_:)), name: unlockedName, object: nil, suspensionBehavior: .deliverImmediately)
    }
    deinit {
        center.removeObserver(self, name: lockedName, object: nil)
        center.removeObserver(self, name: unlockedName, object: nil)
    }
    @objc private func screenDidLock(_ note: Notification) { onMain(locked) }
    @objc private func screenDidUnlock(_ note: Notification) { onMain(unlocked) }
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

/// The one "DayDream stopped recording" notification. A new notice replaces the old one (same
/// identifier), and starting to record again removes it.
struct RecordingNoticeCenter {
    /// Called when recording first starts: lets macOS ask once whether DayDream may show notifications.
    var prepare: () -> Void
    var post: (RecordingNotice) -> Void
    var clear: () -> Void

    static let identifier = "daydream.recording-stopped"

    /// Posts nothing (the checks, previews, and a process that is not the DayDream app bundle).
    static let silent = RecordingNoticeCenter(prepare: {}, post: { _ in }, clear: {})

    /// The app's. Silent unless this process is an .app bundle with a bundle identifier: the notification
    /// center needs one, and the command-line checks have none.
    static var live: RecordingNoticeCenter {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return .silent }
        return RecordingNoticeCenter(
            prepare: {
                let center = UNUserNotificationCenter.current()
                center.delegate = RecordingNoticePresenter.shared
                center.getNotificationSettings { settings in
                    guard settings.authorizationStatus == .notDetermined else { return }
                    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
                }
            },
            post: { notice in
                let center = UNUserNotificationCenter.current()
                center.delegate = RecordingNoticePresenter.shared
                let content = UNMutableNotificationContent()
                content.title = notice.title
                content.body = notice.body
                content.sound = .default
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
                center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { _ in }
            },
            clear: {
                let center = UNUserNotificationCenter.current()
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
            })
    }
}

/// Shows the notice even while DayDream is the active app (a menu bar app often is).
final class RecordingNoticePresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RecordingNoticePresenter()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    /// Clicking the notice brings DayDream forward.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        completionHandler()
    }
}
