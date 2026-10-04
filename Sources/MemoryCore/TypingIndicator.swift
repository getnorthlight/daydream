import Foundation
import PrivacyPolicy

// Safe typing F, pure: what the menu bar shows about typing right now.
// The dot appears only while what you type in the front app can be recorded
// this moment. The menu-bar drawing, the menu rows and the global shortcut
// are wired in a later run (they live in app and capture files); the state,
// its strings and the shortcut's definition are fixed here.

/// Key focus may have moved without a key: an app switch or a mouse click.
/// Capture reports it; a listener that judged the front window from its last
/// key (website typing in the owner build) forgets that judgement. Nothing
/// listens in public builds.
public enum TypingFocus {
    private static let lock = NSLock()
    private static var listener: (() -> Void)?
    public static func mayHaveMoved() { lock.lock(); let l = listener; lock.unlock(); l?() }
    public static func listen(_ f: (() -> Void)?) { lock.lock(); listener = f; lock.unlock() }
}
/// A mouse button went down (capture's event tap, on the main thread), with
/// the event's time in uptime nanoseconds. Native typing seals its own unit; a
/// listener that keeps its own unfinished text (website typing in the owner
/// build) saves it before the click can move focus away from its field.
/// Nothing listens in public builds.
public enum TypingPointer {
    private static let lock = NSLock()
    private static var listener: ((UInt64) -> Void)?
    private static var releaseListener: ((UInt64, Double, Double, Bool) -> Void)?
    private static var pressed: TypingPress?
    public static func down(at eventAt: UInt64) { lock.lock(); let l = listener; lock.unlock(); l?(eventAt) }
    public static func listen(_ f: ((UInt64) -> Void)?) { lock.lock(); listener = f; lock.unlock() }
    /// fix/chrome-capture: where the button that goes down next went down (capture reports it just before `down`).
    /// Taken once by the listener (`takePress`); a `down` with no press before it has none.
    public static func press(_ p: TypingPress) { lock.lock(); pressed = p; lock.unlock() }
    public static func takePress() -> TypingPress? { lock.lock(); defer { pressed = nil; lock.unlock() }; return pressed }
    /// A mouse button came up (event time in uptime nanoseconds, the point in global top-left coordinates).
    public static func up(at eventAt: UInt64, x: Double, y: Double, left: Bool) {
        lock.lock(); let l = releaseListener; lock.unlock(); l?(eventAt, x, y, left)
    }
    public static func listenRelease(_ f: ((UInt64, Double, Double, Bool) -> Void)?) { lock.lock(); releaseListener = f; lock.unlock() }
}
/// fix/chrome-capture: a mouse button going down: its point (global, top-left origin, as Accessibility frames),
/// whether it was the left button, the click count and whether a modifier was held. Metadata only.
public struct TypingPress: Equatable, Sendable {
    public var x: Double, y: Double, left: Bool, clicks: Int, modified: Bool
    public init(x: Double, y: Double, left: Bool, clicks: Int, modified: Bool) {
        self.x = x; self.y = y; self.left = left; self.clicks = clicks; self.modified = modified
    }
    /// A plain single left click: the only press that may activate a Post button here.
    public var plain: Bool { left && clicks == 1 && !modified }
}
/// Capture dropped a key as late, unread (its event tap, on the main queue).
/// Native typing seals its unit at the gap; a listener that keeps its own
/// unfinished text (website typing in the owner build) seals it too, so the
/// text on either side of the missing key is never saved as one. Nothing
/// listens in public builds.
public enum TypingKeyGap {
    private static let lock = NSLock()
    private static var listener: ((UInt64) -> Void)?
    public static func lost(at now: UInt64) { lock.lock(); let l = listener; lock.unlock(); l?(now) }
    public static func listen(_ f: ((UInt64) -> Void)?) { lock.lock(); listener = f; lock.unlock() }
}
/// The keyboard input source changed (capture's observer, on the main queue).
/// Native typing seals its own unit; a listener that keeps its own unfinished
/// text (website typing in the owner build) seals it too, so text typed on a
/// direct layout never runs on into keys an input method composes. Nothing
/// listens in public builds.
public enum TypingInputSource {
    private static let lock = NSLock()
    private static var listener: (() -> Void)?
    public static func changed() { lock.lock(); let l = listener; lock.unlock(); l?() }
    public static func listen(_ f: (() -> Void)?) { lock.lock(); listener = f; lock.unlock() }
}
public extension Notification.Name {
    /// Something the typing indicator is worked out from changed outside the
    /// store (posted on the main queue); the app refreshes its menu.
    static let typingIndicatorInputsChanged = Notification.Name("DayDreamTypingIndicatorInputsChanged")
}

/// Why typing can't be recorded although the person turned it on.
public enum TypingLockReason: String, Sendable {
    /// The safe-typing screen (consent v2) was not accepted yet.
    case notAccepted
    /// The Keychain is locked (the Mac is locked or the item can't be read now).
    case keychainLocked
    /// The typing key was lost; typing stays off until turned on again.
    case keyLost
    /// "Turn on typing" has not created the key yet.
    case notSetUp
    /// This process holds no key (the CLI and MCP never do).
    case unavailable
}

public enum TypingIndicatorState: Equatable, Sendable {
    /// Recording is stopped, or typing is off. Nothing is shown.
    case off
    case locked(TypingLockReason)
    /// "Don't record typing" is running. nil: the saved end time is unreadable,
    /// so typing stays paused until "Record typing again".
    case snoozed(until: Date?)
    /// Typing is on, but not in the front app.
    case notHere
    /// What you type in this app is being recorded.
    case recording(app: String)

    /// The small filled dot on the menu-bar glyph.
    public var showsDot: Bool { if case .recording = self { return true }; return false }
    /// The small hollow ring while typing is paused.
    public var showsRing: Bool { if case .snoozed = self { return true }; return false }
    /// Only while the dot is shown.
    public var accessibilityLabel: String? { showsDot ? "DayDream is recording what you type" : nil }

    /// The row at the top of the menu. nil: no row (typing is off).
    public func menuTitle(timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        switch self {
        case .off: return nil
        case .recording(let app): return "Recording what you type in \(app)"
        case .notHere: return "Not recording typing in this app"
        case .snoozed(let until):
            guard let until else { return "Typing paused" }
            let format = DateFormatter(); format.locale = locale; format.timeZone = timeZone
            format.dateStyle = .none; format.timeStyle = .short
            // Newer ICU puts a narrow no-break space before AM/PM; a plain space reads the same.
            return "Typing paused until \(format.string(from: until).replacingOccurrences(of: "\u{202F}", with: " "))"
        case .locked(.keychainLocked): return "Typing is paused until you unlock your Mac."
        case .locked(.keyLost): return "DayDream couldn't find its typing key. Turn typing on again in Settings."
        case .locked: return "Typing is locked: turn it on in Settings"
        }
    }
    /// The menu action under the row.
    public var menuAction: String? {
        switch self {
        case .snoozed: return TypingPauseShortcut.resumeTitle
        case .recording, .notHere: return TypingPauseShortcut.menuTitle
        case .off, .locked: return nil
        }
    }
}

/// "Don't record typing for the next 10 minutes": one global shortcut,
/// Control-Option-Command-T. Typing only; the timed pause still stops everything.
public enum TypingPauseShortcut {
    public static let minutes = 10
    /// kVK_ANSI_T.
    public static let keyCode: UInt32 = 17
    public static let control = true, option = true, command = true, shift = false
    public static let display = "⌃⌥⌘T"
    public static let menuTitle = "Don't record typing for 10 minutes  ⌃⌥⌘T"
    public static let resumeTitle = "Record typing again"
    public static let settingsTitle = "Pause typing for 10 minutes"
    public static let toast = "Typing paused for 10 minutes"
    public static let taken = "This shortcut is used by another app. Pick another."
    /// True for the chord itself (T with exactly Control, Option and Command).
    public static func matches(keyCode: UInt32, control: Bool, option: Bool, command: Bool, shift: Bool) -> Bool {
        keyCode == Self.keyCode && control && option && command && !shift
    }
}

public enum TypingIndicator {
    /// - capture: the recorder's state ("recording" or anything else).
    /// - typingOn: the person's typing switch (`captureText` with the build 4 answer).
    /// - captureAllowlist: the apps this build's capture gate can read typing in.
    public static func state(capture: String, typingOn: Bool, policy: TypedTextPolicy, vault: TypedVaultState,
                             frontmostBundle: String, blockedApps: [String] = [], now: Date = Date(),
                             expanded: Bool = TypingRelease.open,
                             captureAllowlist: Set<String> = CaptureGate.nativeApps) -> TypingIndicatorState {
        guard capture == "recording", typingOn else { return .off }
        // Typing was turned on for fewer places than this build records, and the Keychain is locked:
        // the unlock comes first (Settings shows the locked card until then), then the new scope.
        if policy.scopeWidened && vault == .locked { return .locked(.keychainLocked) }
        guard policy.consented else { return .locked(.notAccepted) }
        switch vault {
        case .ready: break
        case .locked: return .locked(.keychainLocked)
        case .keyLost: return .locked(.keyLost)
        case .notSetUp: return .locked(.notSetUp)
        case .unavailable: return .locked(.unavailable)
        }
        if policy.snoozed(now: now) { return .snoozed(until: timestamp(policy.snoozeUntil)) }
        #if DAYDREAM_OWNER_TYPING
        // Owner build: website typing in Google Chrome (the join decides each page).
        if WebTypingText.mayRecord(frontmostBundle: frontmostBundle, policy: policy, blockedApps: blockedApps, expanded: expanded) {
            return .recording(app: WebTypedRow.app)
        }
        #endif
        guard captureAllowlist.contains(frontmostBundle),
              policy.permits(bundle: frontmostBundle, blockedApps: blockedApps, expanded: expanded),
              let app = TypingCategories.app(frontmostBundle) else { return .notHere }
        return .recording(app: app.name)
    }
}

extension MemoryStore {
    /// The indicator for the front app, from what is saved now. The app
    /// process (the one with the key) calls this; elsewhere it reads locked.
    public func typingIndicator(frontmostBundle: String, now: Date = Date()) throws -> TypingIndicatorState {
        let saved = try policy()
        return TypingIndicator.state(capture: try captureStatus(now: now)["state"] ?? "off",
                                     typingOn: saved.captureText && saved.typedConsentVersion == 1,
                                     policy: try typedTextPolicy(), vault: typedVaultState,
                                     frontmostBundle: frontmostBundle, blockedApps: Self.indicatorBlockedApps(saved), now: now)
    }
}

extension MemoryStore {
    /// Apps the indicator treats as excluded. Owner build: Google Chrome too
    /// while "Web pages in Chrome" is off, because website typing needs it.
    static func indicatorBlockedApps(_ saved: PrivacySettings) -> [String] {
        #if DAYDREAM_OWNER_TYPING
        if !saved.browserPagesOn { return saved.blockedApps + [BrowserSafety.supportedBundle] }
        #endif
        return saved.blockedApps
    }
}
