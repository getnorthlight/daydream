import Foundation
import AppKit
import Combine
import MemoryCore
import PrivacyPolicy

/// What the menu and Settings show about typing. `MemoryViewModel` owns one
/// and refreshes it on every capture-state change; the model also refreshes
/// when another app comes to the front and when a typing pause ends, so the
/// menu-bar dot shows exactly while `indicator.showsDot` is true.
/// Reads only the saved policy, the vault state and the front app's bundle ID.
@MainActor final class TypingModel: ObservableObject {
    @Published private(set) var indicator: TypingIndicatorState = .off
    @Published private(set) var policy = TypedTextPolicy()
    @Published private(set) var vault: TypedVaultState = .unavailable
    /// The typing key was lost and typing has not been turned on again.
    @Published private(set) var keyLost = false
    /// The global pause shortcut.
    @Published private(set) var hotkey: TypingHotkeyStatus = .notInstalled
    /// "Turn on typing" could not create the typing key. Typing stays off.
    @Published private(set) var setupFailed = false
    /// A change could not be saved.
    @Published private(set) var saveFailed = false
    /// The confirmation shown for 2 seconds after the shortcut paused typing.
    @Published private(set) var toast: String?
    /// When the model reads the store again by itself (the end of a typing pause).
    private(set) var refreshAt: Date?

    private weak var store: MemoryStore?
    private let now: () -> Date
    private var registrar: TypingHotkeyRegistrar?
    private var observers: [NSObjectProtocol] = []
    /// Hears the screen unlock even while DayDream is in the background (`TypingUnlockListener`).
    private var unlockListener: TypingUnlockListener?
    /// The one end-of-pause refresh and the one toast clear waiting to run. A new one replaces (cancels) the old,
    /// and one that was replaced does nothing if it runs anyway.
    private var endOfPauseItem: DispatchWorkItem?
    private var toastItem: DispatchWorkItem?
    private var endOfPauseToken = 0
    private var toastToken = 0
    private var lastFront = ""
    /// The last time a locked Keychain was read again (at most every
    /// `unlockRetrySeconds` from `refresh`; unlock, wake and Try again always read).
    private var lastUnlockRetry: Date?
    static let unlockRetrySeconds: TimeInterval = 30
    /// The app in front. The app reads NSWorkspace; the checks substitute a value.
    var frontmostBundle: () -> String = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" }
    /// An allowed launcher panel (Spotlight) holding key focus in front of the
    /// frontmost app, or nil. Keys go there, so the dot is judged for it. The
    /// app sets `NativeTypingRoute.keyPanelBundle`; public builds allow no panel.
    var keyPanel: () -> String? = { nil }
    /// The app the indicator was last judged for (the key target).
    private(set) var judgedBundle = ""
    /// Shows the 2-second toast. The app draws `TypingToast`; the checks record the text.
    var presentToast: (String) -> Void = { TypingToast.show($0) }
    /// Runs `work` after `seconds` on the main queue. The checks record instead of waiting.
    var after: (TimeInterval, @escaping () -> Void) -> DispatchWorkItem = { seconds, work in
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }
    /// Where the chosen chord is remembered (a per-Mac convenience).
    var defaults: UserDefaults = .standard

    init(now: @escaping () -> Date = Date.init) { self.now = now }
    /// The screen-unlock notification. The checks use a name of their own.
    static var unlockNotification = Notification.Name("com.apple.screenIsUnlocked")

    /// The app's store, once it is open. Development trials never attach one,
    /// so the model stays `.off` there and no shortcut is registered.
    /// - hotkeys: registers the pause chord (Carbon inside the app bundle; nil registers nothing).
    ///   The chord is held only while typing is turned on (consent saved), so a Mac that never
    ///   uses typing never takes Control-Option-Command-T from another app.
    func attach(_ store: MemoryStore, hotkeys: TypingHotkeyRegistrar? = TypingHotkey.appRegistrar()) {
        self.store = store
        if let hotkeys { registrar = hotkeys }
        if observers.isEmpty {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                               object: nil, queue: .main) { [weak self] note in
                let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier ?? ""
                MainActor.assumeIsolated { self?.refresh(frontmostBundle: bundle) }
            })
            // An input outside the store changed (website typing's last join in the owner build).
            observers.append(NotificationCenter.default.addObserver(forName: .typingIndicatorInputsChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
            // "Typing is paused until you unlock your Mac": an unlock, a new
            // session or a wake reads the Keychain again. The unlock is heard at
            // once, while DayDream is in the background too.
            let unlocked: (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.retryUnlock() } }
            unlockListener = TypingUnlockListener(name: Self.unlockNotification) { [weak self] in
                MainActor.assumeIsolated { self?.retryUnlock() }
            }
            for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
                observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main, using: unlocked))
            }
        }
        refresh()
    }
    var attached: Bool { store != nil }
    var snoozed: Bool { policy.snoozed(now: now()) }
    /// "Turn on typing" has been done: consent v2 is saved and the key is ready.
    var setUp: Bool { policy.consented && vault == .ready }

    func refresh(frontmostBundle: String) {
        // gold r3-store: on the main thread the reads wait at most `StoreWait.mainBudget` for another
        // connection's lock (a state change, a pause or a failed save refreshes this outside the heartbeat too).
        if Thread.isMainThread { _ = StoreWait.bounded(StoreWait.mainBudget) { refreshBounded(frontmostBundle: frontmostBundle) } }
        else { refreshBounded(frontmostBundle: frontmostBundle) }
    }
    private func refreshBounded(frontmostBundle: String) {
        lastFront = frontmostBundle
        // Runs on every recording heartbeat: a published value is written only when it changed (each write redraws
        // every view watching typing, the menu bar dot included).
        guard let store else { if indicator != .off { indicator = .off }; return }
        apply(Self.read(store: store, frontmostBundle: frontmostBundle, keyPanel: keyPanel, now: now(), retryLocked: lockedRetryDue()))
    }
    /// claude/perf3-1005: the heartbeat's typing refresh, read off the main thread (on `Coordinator.beatQueue`, with
    /// the heartbeat; `reads` is what that queue runs) and handled on the main thread (what `reads` returns), the
    /// same reads and the same handling as `refresh(frontmostBundle:)`. Called on the main thread.
    func beatReads() -> (() -> (() -> Void))? {
        guard let store else { return nil }
        // The key panel is read here: the system's key focus is read on the main thread only (NativeTypingRoute).
        let front = frontmostBundle(), panel = keyPanel(), clock = now, retry = lockedRetryDue()
        return { [weak self] in
            let reading = Self.read(store: store, frontmostBundle: front, keyPanel: { panel }, now: clock(), retryLocked: retry)
            return {
                MainActor.assumeIsolated {
                    guard let self, self.store === store else { return }
                    self.lastFront = front
                    self.apply(reading)
                    // Only for the status refresh that follows in this turn (`onStateChanged`).
                    self.beatApplied = true
                    DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.beatApplied = false } }
                }
            }
        }
    }
    /// The heartbeat just refreshed this model (`beatReads`): the status refresh that follows it doesn't read again.
    /// Reading it clears it.
    func takeBeatRefresh() -> Bool { defer { beatApplied = false }; return beatApplied }
    private var beatApplied = false
    private func lockedRetryDue() -> Bool {
        lastUnlockRetry.map { now().timeIntervalSince($0) >= Self.unlockRetrySeconds || now() < $0 } ?? true
    }
    /// What one refresh read: each value up to the first read given up because another connection held the history a
    /// moment (`heldUp`; gold r3-store, on a thread inside `StoreWait.bounded`).
    struct Reading {
        var vault: TypedVaultState
        var retriedLocked = false
        var policy: TypedTextPolicy?
        var keyLost: Bool?
        var target = ""
        var indicator: TypingIndicatorState?
        var heldUp = false
    }
    /// The reads, on any thread (the store serializes them).
    nonisolated static func read(store: MemoryStore, frontmostBundle: String, keyPanel: () -> String?, now: Date, retryLocked: Bool) -> Reading {
        var reading = Reading(vault: store.typedVaultState)
        // A locked Keychain is read again now and then (app activation calls
        // this), so typing resumes after an unlock without a relaunch.
        if reading.vault == .locked, retryLocked {
            reading.retriedLocked = true
            _ = try? store.retryLockedTypedVault(now: now)
            reading.vault = store.typedVaultState
        }
        // Unreadable settings show nothing rather than a guess. gold r3-store: except when another connection held
        // the history a moment (the wait is bounded, `StoreWait.heldUpNow`): what shows stays as last read, and the
        // next heartbeat reads again (the pause chord isn't let go for a moment's busy file).
        let policyRead = Result { try store.typedTextPolicy() }
        if case .failure = policyRead, StoreWait.heldUpNow { reading.heldUp = true; return reading }
        reading.policy = (try? policyRead.get()) ?? TypedTextPolicy()
        let keyLostRead = Result { try store.typedKeyLostNotice() }
        if case .failure = keyLostRead, StoreWait.heldUpNow { reading.heldUp = true; return reading }
        reading.keyLost = (try? keyLostRead.get()) ?? false
        reading.target = keyPanel() ?? frontmostBundle
        let indicatorRead = Result { try store.typingIndicator(frontmostBundle: reading.target, now: now) }
        if case .failure = indicatorRead, StoreWait.heldUpNow { reading.heldUp = true; return reading }
        reading.indicator = (try? indicatorRead.get()) ?? .off
        return reading
    }
    /// What a refresh read, shown: a published value is written only when it changed.
    private func apply(_ reading: Reading) {
        if reading.retriedLocked { lastUnlockRetry = now() }
        if vault != reading.vault { vault = reading.vault }
        guard let policy = reading.policy else { readAgainAfterHold(); return }
        if self.policy != policy { self.policy = policy }
        guard let keyLost = reading.keyLost else { readAgainAfterHold(); return }
        if self.keyLost != keyLost { self.keyLost = keyLost }
        judgedBundle = reading.target
        guard let indicator = reading.indicator else { readAgainAfterHold(); return }
        if self.indicator != indicator { self.indicator = indicator }
        syncHotkey()
        scheduleEndOfPause()
    }
    /// Holds the chord while typing is turned on (consent saved and the key made; a locked
    /// Keychain keeps it) and lets it go when it is not.
    private func syncHotkey() {
        guard let registrar else { return }
        if policy.consented && (vault == .ready || vault == .locked) {
            if hotkey == .notInstalled { register(TypingPauseChord.saved(defaults)) }
        } else if hotkey != .notInstalled {
            registrar.unregister()
            hotkey = .notInstalled
        }
    }
    /// The Keychain was locked: read it again now (an unlock, a wake, or
    /// Settings' "Try again"), then refresh what the menu and Settings show.
    func retryUnlock() {
        guard let store, store.typedVaultState == .locked else { return }
        lastUnlockRetry = now()
        _ = try? store.retryLockedTypedVault(now: now())
        refresh()
    }
    /// Capture saw a key go to `bundle`: when that isn't the app the indicator
    /// was judged for (a launcher panel opened or closed), judge it again.
    func keyTargetSeen(_ bundle: String) {
        guard bundle != judgedBundle else { return }
        refresh()
    }
    /// Reads the store again for the app in front now.
    func refresh() { refresh(frontmostBundle: frontmostBundle()) }

    /// The ring turns back into the dot (or nothing) when the pause ends,
    /// without waiting for another capture change.
    /// gold/int r3 review: a refresh given up because another connection held the history a moment. While a pause shows,
    /// its end's refresh may have been this one (nothing else reads again while recording is off), so it reads again
    /// shortly, until a read lands.
    private func readAgainAfterHold() {
        guard case .snoozed = indicator, endOfPauseItem == nil else { return }
        endOfPauseToken += 1
        let token = endOfPauseToken
        endOfPauseItem = after(0.5) { [weak self] in
            guard let self, token == self.endOfPauseToken else { return }
            self.endOfPauseItem = nil
            self.refreshAt = nil
            self.refresh()
        }
    }
    private func scheduleEndOfPause() {
        guard case .snoozed(let until?) = indicator else {
            // The pause ended or was lifted: its refresh has nothing left to do.
            refreshAt = nil; endOfPauseItem?.cancel(); endOfPauseItem = nil; return
        }
        guard refreshAt != until else { return }
        refreshAt = until
        let wait = max(0.5, until.timeIntervalSince(now()) + 0.5)
        endOfPauseItem?.cancel()
        endOfPauseToken += 1
        let token = endOfPauseToken
        endOfPauseItem = after(wait) { [weak self] in
            guard let self, token == self.endOfPauseToken else { return }
            self.endOfPauseItem = nil
            self.refreshAt = nil
            self.refresh()
        }
    }

    /// Runs just before the pause is saved: the recorder decides its late keys first, so a line ended and judged on
    /// time is written before the pause drops what is pending (gold/r3-typing). The argument is when the pause chord
    /// was pressed (uptime nanoseconds), nil from the menu or when unknown. The app wires it to its recorder.
    var willPause: (UInt64?) -> Void = { _ in }
    /// "Don't record typing for 10 minutes". Returns the end time.
    @discardableResult func snooze(frontmostBundle: String, chordAt: UInt64? = nil) throws -> Date {
        guard let store else { throw MemError.missing }
        // Refreshed on a refusal too (review G43: a Keychain that can't be read now shows its locked line).
        defer { refresh(frontmostBundle: frontmostBundle) }
        willPause(chordAt)
        return try store.snoozeTyping(minutes: TypingPauseShortcut.minutes, now: now())
    }
    /// "Record typing again".
    func resume(frontmostBundle: String) throws {
        guard let store else { throw MemError.missing }
        defer { refresh(frontmostBundle: frontmostBundle) }
        try store.resumeTyping(now: now())
    }

    // MARK: The shortcut

    /// Control-Option-Command-T pressed. Pauses typing only while there is
    /// typing to pause (the menu offers the same action then). While already
    /// paused it does nothing: the pause is never extended. Shows the toast
    /// only when typing was paused now.
    func pauseFromShortcut() {
        let chordAt = TypingHotkey.takePress()
        let front = frontmostBundle()
        refresh(frontmostBundle: front)
        switch indicator {
        case .recording, .notHere: break
        case .off, .locked, .snoozed: return
        }
        guard (try? snooze(frontmostBundle: front, chordAt: chordAt)) != nil else { return }
        let text = TypingPauseShortcut.toast
        toast = text
        presentToast(text)
        toastItem?.cancel()
        toastToken += 1
        let token = toastToken
        toastItem = after(TypingToast.seconds) { [weak self] in
            guard let self, token == self.toastToken else { return }
            self.toastItem = nil
            if self.toast == text { self.toast = nil }
        }
    }

    /// Registers `chord` in place of the current one and remembers the choice.
    func choose(_ chord: TypingPauseChord) {
        guard registrar != nil, hotkey != .notInstalled else { return }
        chord.save(defaults)
        register(chord)
    }
    private func register(_ chord: TypingPauseChord) {
        guard let registrar else { return }
        hotkey = TypingHotkey.register(chord, registrar: registrar) { [weak self] in
            MainActor.assumeIsolated { self?.pauseFromShortcut() }
        }
    }

    // MARK: Settings

    /// Saves the typing switch (`captureText`) through the app's preference path (`MemoryViewModel.typingPreference`,
    /// which stops and restarts recording around the save). The checks record it or save it on the store.
    var saveSwitch: (Bool) -> Void = { _ in }

    /// "Turn on typing", the one ON path (setup, what's-new, the Settings switch; no sheet, no second question):
    /// consent for everything this build records, the typing key, every category on (Messages and email unless its
    /// checkbox was turned off), the explicit choice remembered (`MemoryStore.turnOnTyping`), then the typing switch
    /// saved on. When the key can't be made, `setupFailed` is set and typing stays off ("Try again" calls this again).
    @discardableResult func turnOn() -> Bool {
        guard let store else { setupFailed = true; return false }
        // A locked Keychain is read again first: while it stays locked the store refuses the answer
        // (saving it would drop the settings' signature), so nothing changes and Try again stays.
        if store.typedVaultState == .locked { lastUnlockRetry = now(); _ = try? store.retryLockedTypedVault(now: now()) }
        do {
            try store.turnOnTyping(now: now())
            setupFailed = store.typedVaultState != .ready
        } catch {
            setupFailed = true
        }
        if !setupFailed { saveSwitch(true) }
        refresh()
        return !setupFailed
    }
    /// The typing switch turned off (Settings, setup, Forget): remembered as an explicit choice, so setup and what's-new
    /// keep it off, then the switch saved off.
    func turnOff() {
        if let store { try? store.rememberTypingOff(now: now()) }
        saveSwitch(false)
        refresh()
    }
    /// One category checkbox, also remembered as an explicit choice (`SetupChoices.categories`).
    func setCategory(_ category: TypingCategory, on: Bool) {
        save { store in
            var next = try store.typedTextPolicy()
            next.categories.set(category, on)
            try store.updateTypedTextPolicy(next, now: now())
            try store.rememberCategoryChoice(category.rawValue, on, now: now())
        }
    }
    /// "Other websites" (owner builds only show it).
    func setOtherWebsites(_ on: Bool) {
        save { store in
            var next = try store.typedTextPolicy()
            next.categories.otherWebsites = on
            try store.updateTypedTextPolicy(next, now: now())
            try store.rememberCategoryChoice(SetupChoices.otherWebsitesKey, on, now: now())
        }
    }
    /// True when choosing `retention` deletes words now, so it needs the confirmation first.
    func needsConfirmation(_ retention: TypedRetention) -> Bool { retention.isShorter(than: policy.retention) }
    /// "Keep exact words". A shorter period deletes older words at once and
    /// is saved only with `confirmed` (after "Delete").
    @discardableResult func setRetention(_ retention: TypedRetention, confirmed: Bool) -> Bool {
        guard !needsConfirmation(retention) || confirmed else { return false }
        return save { store in
            var next = try store.typedTextPolicy()
            next.retention = retention
            try store.updateTypedTextPolicy(next, confirmed: confirmed, now: now())
        }
    }
    /// "Forget what I typed…", after its confirmation.
    @discardableResult func forget() -> Bool {
        save { store in _ = try store.forgetTypedText(confirmed: true, now: now()) }
    }

    @discardableResult private func save(_ change: (MemoryStore) throws -> Void) -> Bool {
        guard let store else { saveFailed = true; return false }
        do { try change(store); saveFailed = false } catch { saveFailed = true }
        refresh()
        return !saveFailed
    }
}

/// Hears a distributed notification at once, even while DayDream is in the background: AppKit suspends an inactive
/// app's distributed center, and an observer with the default suspension behavior (the block API's) hears nothing
/// until DayDream is next active, so typing locked with the Keychain stayed paused after the unlock until then.
/// `heard` runs on the main thread.
final class TypingUnlockListener: NSObject {
    private let center: DistributedNotificationCenter
    private let name: Notification.Name
    private let heard: () -> Void
    init(center: DistributedNotificationCenter = .default(), name: Notification.Name, heard: @escaping () -> Void) {
        self.center = center; self.name = name; self.heard = heard
        super.init()
        center.addObserver(self, selector: #selector(posted(_:)), name: name, object: nil, suspensionBehavior: .deliverImmediately)
    }
    deinit { center.removeObserver(self, name: name, object: nil) }
    @objc private func posted(_ note: Notification) {
        if Thread.isMainThread { heard() } else { DispatchQueue.main.async(execute: heard) }
    }
}
