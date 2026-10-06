// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// Portions of this file are derived from open-codex-computer-history
// (https://github.com/hqhq1025/open-codex-computer-history),
// Copyright (c) 2026 Open Codex Computer History contributors, used under the
// MIT License. The full MIT notice is in THIRD-PARTY-NOTICES.md.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import HistoryCore
import MemoryCore
import CoreIntegration
import PrivacyPolicy
import Carbon
import os

// C-ABI trampolines: CoreGraphics/AX hand us a raw pointer, which we turn back
// into the EventCapture instance. `passUnretained` is safe because EventCapture
// outlives the tap/observer for the whole run (on the main thread; the tap
// thread's trampoline uses a retained box instead).
private let eventTapTrampoline: CGEventTapCallBack = { _, type, event, userInfo in
    if let userInfo {
        Unmanaged<EventCapture>.fromOpaque(userInfo).takeUnretainedValue().handleTap(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
// claude/chrome-offmain-1003: the tap on its own thread (`TypingKeyHandoff.offMainEnabled`). Its target is a box the tap
// keeps for good (one small object per tap made), holding the recorder weakly: a callback already running on the tap
// thread when the recorder goes away finds nil and does nothing.
private final class EventTapTarget { weak var capture: EventCapture?; init(_ c: EventCapture) { capture = c } }
private let offMainTapTrampoline: CGEventTapCallBack = { _, type, event, userInfo in
    if let userInfo, let capture = Unmanaged<EventTapTarget>.fromOpaque(userInfo).takeUnretainedValue().capture {
        capture.handleTapOffMain(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
/// claude/chrome-offmain-1003: the thread whose run loop holds the input tap when key work runs off the main thread.
/// It does nothing else: every event is handled on the main thread while it waits (`EventCapture.handleTapOffMain`).
private final class EventTapThread: Thread {
    static let shared: EventTapThread = {
        let t = EventTapThread()
        t.name = "DayDream input tap"; t.qualityOfService = .userInteractive
        t.start(); t.ready.wait()
        return t
    }()
    private let ready = DispatchSemaphore(value: 0)
    private(set) var runLoop: CFRunLoop!
    override func main() {
        runLoop = CFRunLoopGetCurrent()
        RunLoop.current.add(Port(), forMode: .default)   // the run loop never runs out of sources
        ready.signal()
        while true { CFRunLoopRun() }
    }
}

private let axTrampoline: AXObserverCallback = { _, _, notification, userInfo in
    guard let userInfo else { return }
    Unmanaged<EventCapture>.fromOpaque(userInfo).takeUnretainedValue().handleAX(notification as String)
}

/// Permission-gated native entry points. Typing goes through the synchronous
/// proof/classifier/persistence binding (typed units in TypingSession); other
/// metadata retains Coordinator's existing scoped intake. No second store or
/// summary worker is created here.
final class EventCapture {
    private let coordinator: Coordinator
    struct TypingEnvironment {
        var now:()->UInt64 = {DispatchTime.now().uptimeNanoseconds}
        /// The Accessibility proof, admitted by `NativeTypingRoute`, with the
        /// focused window's title as its place label (read per key: the
        /// terminal prompt latch arms from it).
        var proof:(UInt64,UInt64)->FocusProof? = {generation,version in
            guard let pid=NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  var proof=AccessibilityReader.typingProof(pid:pid,generation:generation,policyVersion:version,now:DispatchTime.now().uptimeNanoseconds),
                  NativeTypingRoute.admits(bundle:proof.bundle,pid:pid) else {return nil}
            proof.place=NativeTypingRoute.place(for:pid) ?? ""
            MessagesComposer.classify(&proof)
            return proof
        }
        /// compose-send/v1: the frontmost app's focused composer. The value is read at a send gesture only, after that
        /// field's proof passed the gate; emptiness is a character count.
        var composerValue:()->String? = {
            guard let pid=NSWorkspace.shared.frontmostApplication?.processIdentifier else {return nil}
            return ComposerAX.value(pid:NativeTypingRoute.keyTarget(frontmost:pid))
        }
        var composerEmpty:()->Bool? = {
            guard let pid=NSWorkspace.shared.frontmostApplication?.processIdentifier else {return nil}
            return ComposerAX.isEmpty(pid:NativeTypingRoute.keyTarget(frontmost:pid))
        }
        /// Runs work after a delay in seconds on this (main) executor.
        var schedule:(TimeInterval,@escaping ()->Void)->Void = {delay,work in DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:work)}
        var secureInput:()->Bool = {IsSecureEventInputEnabled()}
        /// Where focus went, for a unit whose field was left. Metadata only.
        var departure:()->DepartureState = {AccessibilityReader.departureState()}
        var pressAndHold:()->Bool = {UserDefaults.standard.object(forKey:"ApplePressAndHoldEnabled") as? Bool ?? true}
    }
    private let typingEnvironment:TypingEnvironment
    /// Idle-commit and settle timers are cancelled by bumping their epoch.
    private var inputEpoch:UInt64=0
    private var settleEpoch:UInt64=0
    private var idleAt:UInt64?
    private var settleAt:UInt64?
    private var housekeepingEpoch:UInt64=0
    private var housekeepingAt:UInt64?
    private var keyMap=TypingKeyMap()
    private enum TypingRace:Error {case moved}
    private var sleepObservers:[NSObjectProtocol]=[]
    private var inputSourceObserver:InputSourceListener?

    private var currentPID: pid_t?
    private var currentBundle = ""
    /// Chrome page history (title, site, time of the page in front). Keys,
    /// clicks and typing never reach it.
    let pages: ChromePageRecorder
    private var eventTap: CFMachPort?
    /// The run loop the tap's source is in: the main thread's, or the tap thread's (claude/chrome-offmain-1003).
    private var eventTapRunLoop: CFRunLoop?
    /// claude/chrome-offmain-1003: whether the tap is made on its own thread. Read when a tap is made.
    static var tapOffMain: Bool { TypingKeyHandoff.offMainEnabled }
    private var eventTapSource: CFRunLoopSource?
    private var axObserver: AXObserver?
    private var workspaceObserver: NSObjectProtocol?
    private var controlTimer: Timer?

    private var terminalText: String?
    private var terminalSnapshot: AccessibilitySnapshot?
    private var terminalFlush: DispatchWorkItem?

    private struct MouseDown { let point: CGPoint; let button: String; let clickCount: Int; let modifiers: [String] }
    private var mouseDown: MouseDown?
    private var axDebounce: [String: DispatchWorkItem] = [:]
    private var lastWindowSignature: String?
    private var lastSelectionSignature: String?
    private var stopped = false
    private var finishingTyping = false
    private var finishTypingEpoch: UInt64 = 0
    private var finishTypingCompletion: (() -> Void)?

    /// Disruption remains observable during a drain, solely to cancel it.
    /// No new key bytes, page reads, field snapshots or AX registration occurs.
    private func interruptTypingFinish() {
        #if DAYDREAM_OWNER_TYPING
        WebTypingRoute.shared.drop(.focus)
        #endif
    }

    /// Ordinary Stop/pause only. New input and observations freeze immediately;
    /// existing admitted Chrome text must obtain a fresh proof before pausing.
    /// The route completes or cancels within one proof TTL without waiting for
    /// background delivery (synchronous capture keeps its bounded main read).
    func finishPendingTyping(completion: @escaping () -> Void) {
        guard !stopped else { completion(); return }
        // A later ordinary request owns the final transition (for example,
        // Stop pressed while a timed pause is draining). The same drain/token
        // completes once; it never silently ignores that newer user intent.
        if finishingTyping { finishTypingCompletion = completion; return }
        commitPendingTyping()
        finishTypingCompletion = completion
        finishingTyping = true
        inputEpoch &+= 1; settleEpoch &+= 1; housekeepingEpoch &+= 1
        idleAt = nil; settleAt = nil; housekeepingAt = nil
        anchor = nil; lateBatches.removeAll()
        finishTypingEpoch &+= 1
        let epoch = finishTypingEpoch
        pages.invalidate()
        axRetryEpoch &+= 1
        axDebounce.values.forEach { $0.cancel() }; axDebounce.removeAll()
        terminalFlush?.cancel(); terminalFlush = nil; terminalText = nil; terminalSnapshot = nil
        #if DAYDREAM_OWNER_TYPING
        WebTypingRoute.shared.finishPending(coordinator: coordinator) { [weak self] in
            guard let self, !self.stopped, self.finishingTyping, self.finishTypingEpoch == epoch else { return }
            self.finishTypingEpoch &+= 1
            let done = self.finishTypingCompletion; self.finishTypingCompletion = nil
            done?()
        }
        #else
        let done = finishTypingCompletion; finishTypingCompletion = nil
        done?()
        #endif
    }

    init(coordinator: Coordinator,typingEnvironment:TypingEnvironment=TypingEnvironment(),pageEnvironment:ChromePageEnvironment = .live) {
        self.coordinator = coordinator
        self.typingEnvironment=typingEnvironment
        self.pages=ChromePageRecorder(coordinator:coordinator,environment:pageEnvironment)
        coordinator.onPause = { [weak self] in
            if Thread.isMainThread {self?.discardPending();Self.releaseAppTrees()}
            else {DispatchQueue.main.async {[weak self] in self?.discardPending();Self.releaseAppTrees()}}
        }
    }

    func start() -> Bool {
        guard coordinator.recordingSettled else { return false }
        stopped = false
        pages.reset()
        guard installEventTap() else { coordinator.pause("Input event tap unavailable. No recording started."); return false }
        keyWatch.start()
        installWorkspaceObserver()
        if let app = NSWorkspace.shared.frontmostApplication {
            currentPID = app.processIdentifier
            currentBundle = app.bundleIdentifier ?? ""
            installAXObserver(pid: app.processIdentifier, chrome: currentBundle == ChromePageTarget.bundleID)
            #if DAYDREAM_OWNER_TYPING
            // claude/xtyping-1005: Chrome in front as recording starts: wake its accessibility for website typing.
            if currentBundle == ChromePageTarget.bundleID { WebTypingRoute.shared.chromeInFront(pid: app.processIdentifier, coordinator: coordinator) }
            #endif
        }
        coordinator.record(kind: .sessionStarted, snapshot: snapshot())
        emitWindowChangeIfNeeded(snapshot())

        // The heartbeat. In the common run-loop modes, so an open menu or a tracking loop doesn't hold it back past the
        // store's 5 s freshness window (a late heartbeat makes the store refuse the next unit).
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.coordinator.reconcileResumeOffMain()
            #if DAYDREAM_OWNER_TYPING
            if Self.tapOffMain { MainInputFacts.refresh() }   // claude/crashguard-015: kept fresh between events
            #endif
            if self?.coordinator.recordingSettled != true { self?.stop(reason: "Recording stopped") }
            else if self?.finishingTyping == false { self?.heartbeat(); self?.pages.tick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        controlTimer = timer
        // While recording, App Nap must not throttle the heartbeat. Idle sleep is still allowed.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "DayDream is recording")
        return true
    }
    /// The App Nap opt-out held while recording (`start` to `stop`).
    private var activity: NSObjectProtocol?
    /// Called once when this recorder stops, for any reason (the app drops its reference to a stopped recorder).
    var onStopped: (() -> Void)?
    /// A key down reached the input tap (main thread). Nothing about the key is passed.
    var onKeyInput: (() -> Void)?
    /// claude/typing-1004: keys the Mac counted while recording never reached this tap (`KeyArrivalWatch`), once per
    /// recording (main thread). The app restarts itself or says so.
    var onKeysNotArriving: (() -> Void)?
    private var keyWatch = KeyArrivalWatch()
    /// The session's key-down count and secure input, read by the heartbeat. The checks replace it.
    static var keyCounter: () -> (count: UInt32, secureInput: Bool) = {
        (CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown), IsSecureEventInputEnabled())
    }
    var isStopped: Bool { stopped }

    func stop(reason: String) {
        guard !stopped else { return }
        finishTypingEpoch &+= 1
        stopped = true
        controlTimer?.invalidate()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        pages.reset()
        discardPending()
        axDebounce.values.forEach { $0.cancel() }
        if coordinator.isRunning {coordinator.record(kind: .sessionEnded, snapshot: snapshot())}
        coordinator.finish(reason: reason)
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        for observer in sleepObservers {NSWorkspace.shared.notificationCenter.removeObserver(observer)}
        sleepObservers.removeAll()
        inputSourceObserver=nil
        axRetryEpoch &+= 1
        if let axObserver { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(axObserver), .commonModes) }
        removeEventTap()
        axObserver = nil
        let stopped = onStopped; onStopped = nil
        stopped?()
    }

    // MARK: - CGEventTap

    fileprivate func handleTap(type: CGEventType, event: CGEvent) {
        guard !finishingTyping else { interruptTypingFinish(); return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { tapDisabled(byTimeout: type == .tapDisabledByTimeout); return }
        guard !stopped, coordinator.isRunning else { discardPending(); return }
        #if DAYDREAM_OWNER_TYPING
        // claude/crashguard-015: secure input and the frontmost app as of this event, for website typing's executor
        // (WebTypingRoute, owner-flag code like the calls above; the owner flag always brings the Chrome flag).
        if Self.tapOffMain { MainInputFacts.refresh() }
        #endif
        // gold r3: a key reaching the tap proves Input Monitoring works in this run (`MemoryViewModel.keysArrived`). Key
        // downs only: they reach a listen-only tap only with Input Monitoring.
        if type == .keyDown { keyWatch.keyArrived(); onKeyInput?(); lastKeyAt = typingEnvironment.now() }
        // fix/chrome-capture: opt-in counts only (`CaptureDiagnostics`); never a key code or character.
        if type == .keyDown { CaptureDiagnostics.shared.count("tap.key") }
        switch type {
        case .keyDown: handleKeyDown(event)
        case .flagsChanged: handleFlagsChanged(eventAt:Self.eventNanoseconds(event.timestamp),flags:event.flags)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // fix/bugs7: a click may open another Messages conversation in the same window: its name is read again.
            MessagesConversation.forget()
            CaptureDiagnostics.shared.count("tap.mouse")
            // fix/chrome-capture: where the button went down, which button, the click count and whether a modifier
            // was held, for website typing's Post gesture (metadata only).
            TypingPointer.press(TypingPress(x:Double(event.location.x),y:Double(event.location.y),left:type == .leftMouseDown,
                                            clicks:Int(event.getIntegerValueField(.mouseEventClickState)),modified:!modifiers(event.flags).isEmpty))
            handlePointerDown(eventAt:Self.eventNanoseconds(event.timestamp))
            // A context-menu Paste or a drop may change a terminal's line unseen; a plain left click only moves focus
            // or the caret (owner live test 2026-10-02: the prompt latch arms only for what could change the line).
            if (type != .leftMouseDown || !modifiers(event.flags).isEmpty), !stopped, coordinator.isRunning { coordinator.captureBinding.pointerMayEdit() }
            mouseDown = MouseDown(point: event.location, button: button(for: type),
                                  clickCount: Int(event.getIntegerValueField(.mouseEventClickState)),
                                  modifiers: modifiers(event.flags))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            // fix/chrome-capture: the release ends a press website typing may have proven on a Post button.
            TypingPointer.up(at:Self.eventNanoseconds(event.timestamp),x:Double(event.location.x),y:Double(event.location.y),left:type == .leftMouseUp)
            handleMouseUp(event)
        default: if type.rawValue == Self.systemDefinedEvent { handleSystemKey(eventAt:Self.eventNanoseconds(event.timestamp)) }
        }
    }

    /// claude/chrome-offmain-1003: one event on the tap thread. It is handled on the main thread, exactly as a tap on main
    /// handles it, while this thread waits, so events stay in order and each sees the main thread's state as before.
    /// Website typing's handling of a key down it takes is handed back (`TypingKeyHandoff`) and run here, before this
    /// callback returns and before the next event: the key's characters are read, if at all, inside this callback, only
    /// when that handling asks, and the event is never kept past it.
    ///
    /// perf2-1005: the tap thread waits for the main thread at most `TapMainHandoff.deadline` (it waited as long as main
    /// was busy, and macOS turned the tap off after about a second: seven times in an hour on the owner's laptop). An
    /// event main hasn't reached by then is never handled; it and the events after it until main catches up are one gap
    /// (`eventsMissed`), like a tap macOS turned off, except that the tap stays on.
    fileprivate func handleTapOffMain(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Reads nothing from the event: main turns the tap back on whenever it gets there.
            let byTimeout = type == .tapDisabledByTimeout
            DispatchQueue.main.async { [weak self] in self?.tapDisabled(byTimeout: byTimeout) }
            return
        }
        let work: TypingKeyHandoff.Work?? = tapHandoff.deliver(key: type == .keyDown, post: { DispatchQueue.main.async(execute: $0) }, handle: {
            TypingKeyHandoff.arm()
            self.handleTap(type: type, event: event)
            return TypingKeyHandoff.take()
        }, gap: { [weak self] missed in self?.eventsMissed(missed) })
        // Never AppKit here: this runs on the tap thread (`keyCharacters`, typing-1004: macOS 15 traps in TSM off main).
        if let work = work ?? nil { work { Self.keyCharacters(event) } }
    }
    /// perf2-1005: the last key down at the tap (uptime ns), for keeping the front app's signature pass warm.
    private var lastKeyAt: UInt64?
    static let signatureWarmNanoseconds: UInt64 = 60_000_000_000
    /// The checks turn it off (no real signature checks).
    static var signatureWarm = true
    /// perf2-1005: the tap thread's bounded wait for the main thread.
    let tapHandoff = TapMainHandoff()
    private var missedLoggedAt: UInt64?
    /// perf2-1005: events the tap took while the main thread was too busy to handle them in time
    /// (`TapMainHandoff`). Keys and clicks went by unseen, as when macOS turns the tap off (`tapDisabled`): the unit typed
    /// before is parked and judged like any other (dropped if it holds late keys) and no late key reads across the gap.
    /// A key down that reached the tap still proves Input Monitoring works (`KeyArrivalWatch`).
    func eventsMissed(_ missed: TapMainHandoff.Missed) {
        if missed.keys > 0 { keyWatch.keyArrived(); onKeyInput?() }
        guard !finishingTyping else { interruptTypingFinish(); return }
        guard !stopped, coordinator.isRunning else { discardPending(); return }
        let now = typingEnvironment.now()
        focusChangeHeard()
        if lateReadAt != nil { dropLateKeys(focusMoved: true) } else { sealTyping(.gap, focusMoved: true) }
        // Website typing's unfinished text is sealed at the missing events too (a key, or a click that may have moved
        // focus), never joined across them.
        if missed.events > 0 { TypingKeyGap.lost(at: now) }
        mouseDown = nil
        heldModifiers = []; loneModifier = false
        CaptureDiagnostics.shared.count("tap.missed")
        if missedLoggedAt.map({ now < $0 || now - $0 >= 60_000_000_000 }) ?? true {
            missedLoggedAt = now
            RecordingLog.note("DayDream was busy: \(missed.events) input event(s) went by unseen; the input tap stayed on.")
        }
    }

    /// The characters a key down typed. On the main thread, AppKit's (`NSEvent.characters`, as always). Anywhere else
    /// (the tap thread and the website typing route's executor, claude/chrome-offmain-1003) the characters the event
    /// itself carries (`CGEventKeyboardGetUnicodeString`), never AppKit, HIToolbox or Text Input Sources: `NSEvent.characters`
    /// translates the key through TSM, which asserts the main queue, and macOS 15 traps there (owner laptop 10/04,
    /// public 0.1.4 on 15.7.2: EXC_BREAKPOINT in `_dispatch_assert_queue_fail` under `TSMTranslateKeyEvent` on the
    /// "DayDream input tap" thread, queue daydream.web-typing.route, whenever a Chrome typing burst read its key).
    /// The test is the main QUEUE, as TSM's assertion is, not the main thread: the route's executor may run its work on
    /// the main thread inside `queue.sync`, where `Thread.isMainThread` is true and TSM still traps.
    static func keyCharacters(_ event: CGEvent, onMain: Bool = MainQueue.isCurrent) -> String {
        onMain ? appKitCharacters(event) : eventCharacters(event)
    }
    /// AppKit's reading, main queue only (`MainQueue.require`: debug and check builds trap anywhere else). The checks
    /// replace it to prove it is never called anywhere else.
    static var appKitCharacters: (CGEvent) -> String = { MainQueue.require(); return NSEvent(cgEvent: $0)?.characters ?? "" }
    /// The event's own Unicode string (a CoreGraphics read of the event; no input source, no AppKit), any thread.
    static func eventCharacters(_ event: CGEvent) -> String {
        var units = [UniChar](repeating: 0, count: 64)
        var count = 0
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
        return String(utf16CodeUnits: units, count: max(0, min(count, units.count)))
    }

    private func handleKeyDown(_ event: CGEvent) {
        // Metadata only: key code, modifier flags and the autorepeat bit.
        // Option is not a shortcut: Option characters are text.
        let flags = event.flags
        // fix/bugs7: Return (a sent text) and shortcuts (Messages' conversation keys) may move to another conversation in
        // the same window, whose title stays "Messages": the next key reads the selected conversation again instead of a
        // name cached up to 3 s earlier ("Texted Maya" for a reply typed to Sam right after).
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 36 || keyCode == 76 || flags.contains(.maskCommand) || flags.contains(.maskControl) { MessagesConversation.forget() }
        let stroke=KeyStroke(keyCode:event.getIntegerValueField(.keyboardEventKeycode),command:flags.contains(.maskCommand),control:flags.contains(.maskControl),
                             option:flags.contains(.maskAlternate),shift:flags.contains(.maskShift),autorepeat:event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                             fn:flags.contains(.maskSecondaryFn))
        // The route may read it on its executor (`WebTypingRoute.intake` with no tap thread waiting): never AppKit there.
        handleNativeKey(eventAt:Self.eventNanoseconds(event.timestamp),stroke:stroke) {
            Self.keyCharacters(event)
        }
    }

    /// CGEvent timestamps are documented as nanoseconds, but on Apple silicon they
    /// carry mach_absolute_time ticks (125/3 ns each). For a live key only one of
    /// the two readings can be at or before now, so that one is used; with a 1:1
    /// timebase both agree. Everything after this works in uptime nanoseconds.
    static func eventNanoseconds(_ raw:UInt64,now:UInt64=DispatchTime.now().uptimeNanoseconds,
                                 timebase:(numer:UInt32,denom:UInt32)=machTimebase)->UInt64 {
        guard timebase.denom != 0,timebase.numer != timebase.denom else {return raw}
        let (product,overflow)=raw.multipliedReportingOverflow(by:UInt64(timebase.numer))
        guard !overflow else {return raw}
        let converted=product/UInt64(timebase.denom)
        return converted<=now ? converted:raw
    }
    static let machTimebase:(numer:UInt32,denom:UInt32)={
        var info=mach_timebase_info_data_t();mach_timebase_info(&info);return (info.numer,info.denom)
    }()

    /// Every focus check describes the moment a key is processed, not the
    /// moment it was typed. A key processed later than this may have gone to a
    /// panel or window that has closed since (Spotlight): it is read only when
    /// nothing could have moved focus since a key read on time, in that same
    /// field (`lateKeyMayRead`), and otherwise dropped.
    static let maxKeyLagNanoseconds:UInt64=150_000_000
    /// No key processed later than this after it was typed is read, nor one
    /// typed longer than this after the last key read on time (the settle's
    /// late limit, `TypingLimits.lateResolution`).
    static let maxLateKeyNanoseconds:UInt64=2_000_000_000
    /// A focus, window, app or input-source change heard within this of reading
    /// a late key may have happened before that key was typed.
    static let lateNoticeNanoseconds:UInt64=1_000_000_000
    /// Late keys followed by nothing typed for this long (as long as a draft's own idle end, `TypingLimits.idleClosed`):
    /// the backlog they came in is long done, so no event typed before them can still be waiting. They are vouched for
    /// as if an event typed after them had been seen (gold/r2-typing: what holds them is written only then).
    static let lateQuietNanoseconds:UInt64=30_000_000_000
    /// After a denied or late key, keys typed during this period are dropped
    /// too: they were typed while focus was somewhere capture does not allow.
    static let deniedQuietNanoseconds:UInt64=400_000_000
    private var lastTypingDenial:UInt64?
    private func noteTypingDenial(_ at:UInt64) {lastTypingDenial=max(lastTypingDenial ?? 0,at)}
    /// When a late key was last refused. Keys typed within `deniedQuietNanoseconds` of it may have gone where it did
    /// (a panel closing): they are dropped, but what was typed on time before stays parked and is judged as usual.
    private var lateRefusedAt:UInt64?
    /// The last key read on time with its field proven: that field (metadata
    /// identity) and when the key was typed.
    private struct Anchor {let identity:[String];let typedAt:UInt64}
    private var anchor:Anchor?
    /// The latest moment focus may have moved: a click, a key that can move
    /// focus or open a panel, a lone modifier tap or a system key (at their own
    /// event times), or a focus, window, app or input-source change, a key
    /// without a proof or a gap in the tap (when DayDream heard it).
    private var focusSignalAt:UInt64=0
    /// One backlog of late keys: the keys read late since the last event typed after the previous backlog's last read
    /// (gold/r2-typing review round 1: each is vouched for or dropped on its own, so late keys that keep coming never
    /// keep an older backlog, or the lines ended after it, waiting). `cut` is the binding's mark of what was typed on
    /// time before its first key (`CoreCaptureBinding.markLateCut`); `lastRead` when its last key was read; `open` until
    /// an event typed after that read is seen (the backlog it came in is done).
    private struct LateBatch {let cut:UInt64;var lastRead:UInt64;var open:Bool}
    /// Oldest first. A backlog is vouched for once it is closed and `lateNoticeNanoseconds` have passed since its last
    /// read with no change heard (`settleLateCut`); a change heard within that second drops it and every newer one
    /// (`focusChangeHeard`); an event in the open backlog that can move focus drops the open one (`dropLateKeys`).
    private var lateBatches:[LateBatch]=[]
    /// When DayDream last read a late key of the open backlog, until it sees an event typed after that. Events typed
    /// before it waited behind that key: one that can move focus means the late keys can't be vouched for, so they are
    /// dropped (`dropLateKeys`).
    private var lateReadAt:UInt64? {lateBatches.last.flatMap {$0.open ? $0.lastRead : nil}}
    /// The key being handled was processed late: its text may be read, but it leaves no marker (as before).
    private var keyIsLate=false
    /// Keys that can move focus or open a panel with nothing else to hear: Tab,
    /// Esc, a chord or Option (launchers use Option-Space), Fn/Globe with a
    /// letter or digit, a function key, or a system key (Spotlight, Dictation).
    static func keyMayMoveFocus(_ k:KeyStroke)->Bool {
        k.command || k.control || k.option || k.keyCode == 48 || k.keyCode == escapeKey || k.keyCode >= 0x80
            || functionKeys.contains(k.keyCode) || (k.fn && !caretKeys.contains(k.keyCode))
    }
    private static let functionKeys:Set<Int64>=[122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
    /// Arrows, navigation and delete keys: the OS sets Fn on them by itself.
    private static let caretKeys:Set<Int64>=[123,124,125,126,115,119,116,121,117,114,71,51]
    /// NX_SYSDEFINED: media, brightness and system keys (some Macs' Spotlight
    /// and Dictation keys). Only its time is used.
    static let systemDefinedEvent:UInt32=14
    /// A late key: the unit's field was proven by a key read on time, nothing
    /// that can move focus happened since (a key or click typed before it is
    /// handled before it), and it was typed within `maxLateKeyNanoseconds` of
    /// that key. Its own proof must still show that field (`lateFieldHolds`).
    private func lateKeyMayRead(eventAt:UInt64,now:UInt64)->Bool {
        guard now-eventAt<=Self.maxLateKeyNanoseconds,let anchor,focusSignalAt<anchor.typedAt,
              eventAt>=anchor.typedAt,eventAt-anchor.typedAt<=Self.maxLateKeyNanoseconds else {return false}
        return true
    }
    /// A late key that can't be read. The unit typed before it is sealed; with
    /// late keys already in it, they are dropped (they can't be vouched for).
    private func refuseLateKey(_ now:UInt64) {
        lateRefusedAt=max(lateRefusedAt ?? 0,now)
        if lateReadAt != nil {dropLateKeys()} else {sealTyping(.gap,focusMoved:false)}
    }
    /// Late keys already read can't be vouched for: they are dropped, with anything typed after them: the backlog
    /// `lateBatches[first]` and every newer one (default: the open backlog). What was typed on time before them is kept
    /// (`CoreCaptureBinding.rollBackLate`): judged on time already, it is written at once (`writeFreedTyping`);
    /// otherwise it stays unwritten and is parked like at any gap, then judged as usual, or (`keepOpen`, a key with no
    /// proof) stays open. Older backlogs are decided on their own. No late key reads until a key read on time proves a
    /// field again.
    private func dropLateKeys(from first:Int?=nil,focusMoved:Bool=false,keepOpen:Bool=false) {
        keyMap.reset()
        anchor=nil
        guard let k=first ?? (lateReadAt != nil ? lateBatches.count-1 : nil),lateBatches.indices.contains(k) else {return}
        let cut=lateBatches[k].cut
        lateBatches.removeSubrange(k...)
        // The binding drops them even when recording has stopped: no cut outlives its backlog here.
        coordinator.captureBinding.rollBackLate(from:cut,now:typingEnvironment.now(),focusMoved:focusMoved,keepOpen:keepOpen)
        guard !stopped,coordinator.isRunning else {return}
        writeFreedTyping()
        refreshTypingTimers()
    }
    /// A backlog of late keys is vouched for once an event typed after it was seen and `lateNoticeNanoseconds` have
    /// passed since its last read: the binding lets go of what was typed before it, and what it kept for that decision
    /// (a unit holding it, judged on time) is written now, before the event being handled can be a privacy boundary
    /// that drops it (gold/r2-typing, golden 5 G7; review round 1: written by a timer, it lost the race with a key typed
    /// straight into a password field). Backlogs are vouched for oldest first; a newer one never keeps an older one
    /// waiting.
    private func settleLateCut() {
        let now=typingEnvironment.now()
        var through:UInt64?
        while let b=lateBatches.first,!b.open,now<b.lastRead || now-b.lastRead>Self.lateNoticeNanoseconds {
            through=b.cut;lateBatches.removeFirst()
        }
        guard let through else {return}
        coordinator.captureBinding.releaseLateCut(through:through)
        writeFreedTyping()
        if !stopped,coordinator.isRunning {refreshTypingTimers()}
    }
    /// Units judged on time that waited for late keys and are free now: written at once (the settle's own write).
    private func writeFreedTyping() {
        guard !finishingTyping else { return }
        guard !stopped,coordinator.isRunning,coordinator.captureText,coordinator.captureBinding.hasFreedJudged else {return}
        resolveParkedTyping()
    }
    /// Nothing typed after the late keys for `lateQuietNanoseconds`: the backlog is done, as if an event typed after
    /// them had been seen. Checked by one timer at a time.
    private var lateQuietCheck=false
    private func scheduleLateQuiet(after seconds:Double) {
        guard !lateQuietCheck else {return}
        lateQuietCheck=true
        typingEnvironment.schedule(seconds) {[weak self] in
            guard let self else {return}
            self.lateQuietCheck=false
            guard let i=self.lateBatches.indices.last,self.lateBatches[i].open else {return}
            let now=self.typingEnvironment.now(),due=self.lateBatches[i].lastRead &+ Self.lateQuietNanoseconds
            guard now>due else {self.scheduleLateQuiet(after:Double(due>now ? due-now : 0)/1_000_000_000+0.01);return}
            self.lateBatches[i].open=false;self.settleLateCut()
        }
    }
    /// Recording stops (the person's pause or stop, sleep, the screen locking, quit, an update), or a privacy boundary
    /// is about to drop everything pending: the late keys are decided now, as when the tap turns off. Nothing typed
    /// after them will be seen any more, so late keys still waiting for that, or read within `lateNoticeNanoseconds`
    /// (this is a change heard now), are dropped; the text typed on time before them is kept. Older backlogs are
    /// vouched for. What was judged on time is written now.
    private func decideLateKeys() {
        focusChangeHeard()
        if lateReadAt != nil {dropLateKeys(focusMoved:true)}
        settleLateCut()
    }
    /// The typing pause (the chord or the menu) is next: it changes the typed policy, which drops everything pending,
    /// the unit held for undecided late keys included (gold/r3-typing: after a stall the whole ended line was lost,
    /// the text typed on time too). The late keys are decided first, as at a stop (`decideLateKeys`), so a line ended
    /// and judged on time before them is written now, as with no stall, and only what is still in doubt is lost.
    /// `chordAt` is when the pause chord was pressed (the hot key's own event time), when known: the hot key can be
    /// handled before the tap's callback for the chord, and a chord pressed after the last late read ends that backlog
    /// as the tap would (`tapEventSeen`), so a Return still in it is vouched for as usual. Nothing unfinished is
    /// written here: the pause drops the draft and parked units, as before.
    func typingWillPause(chordAt:UInt64?=nil) {
        guard !stopped,coordinator.isRunning,coordinator.captureText,!lateBatches.isEmpty else {return}
        if let chordAt,chordAt<=typingEnvironment.now() {tapEventSeen(at:chordAt,movesFocus:true)}
        decideLateKeys()
    }
    /// A privacy boundary is next (a key into a password field or an app capture excludes, secure input): it drops
    /// everything pending. The late keys are decided first (`decideLateKeys`), so a line judged on time before them
    /// is written, as with no stall, and only what is still in doubt is lost (gold/r2-typing review round 1: the whole
    /// line was dropped). Nothing else is written here.
    private func lateKeysMeetBoundary() {
        guard !stopped,coordinator.isRunning,coordinator.captureText,!lateBatches.isEmpty else {return}
        decideLateKeys()
    }
    /// The same when a key's or a commit's own proof shows the boundary (the binding refuses it and drops everything).
    private func lateKeysMeetBoundary(_ proof:FocusProof) {
        guard !lateBatches.isEmpty,
              let decision=try? coordinator.captureBinding.typingDecision(proof,now:typingEnvironment.now()),
              decision.outcome != .allowed,CaptureGate.typingDenyReasons.contains(decision.reason) else {return}
        lateKeysMeetBoundary()
    }
    /// A tap event typed at `eventAt`. One typed after the last late read ends
    /// the backlog; one that can move focus, typed before it, drops the late
    /// keys. `movesFocus` marks the moment for later late keys.
    private func tapEventSeen(at eventAt:UInt64,movesFocus:Bool) {
        if movesFocus {MessagesConversation.forget()}
        if let late=lateReadAt {
            if eventAt>late {lateBatches[lateBatches.count-1].open=false;settleLateCut()}
            else if movesFocus {dropLateKeys()}
        }
        if movesFocus {focusSignalAt=max(focusSignalAt,eventAt)}
    }
    /// A focus, window, app or input-source change heard now (when it happened
    /// isn't known). Heard just after a late read, it may have come before that
    /// key was typed: that backlog is dropped, with every newer one. Older
    /// backlogs vouched for before it are let go first.
    private func focusChangeHeard() {
        MessagesConversation.forget()
        let now=typingEnvironment.now()
        settleLateCut()
        if let k=lateBatches.firstIndex(where:{now>=$0.lastRead && now-$0.lastRead<=Self.lateNoticeNanoseconds}) {dropLateKeys(from:k)}
        focusSignalAt=max(focusSignalAt,now)
    }
    /// Late: the key's own proof must show the anchor's field. On time but
    /// typed before the last late read: a different field means focus moved
    /// unheard behind the late keys, so the late keys are dropped first.
    /// False when the key must not be read.
    private func lateFieldHolds(_ proof:FocusProof,eventAt:UInt64,late:Bool)->Bool {
        let same=anchor.map {$0.identity == Self.identity(proof)} ?? false
        if late {
            if !same {refuseLateKey(typingEnvironment.now())}
            // The first late key of a backlog: the draft stays open (nothing is written early), so its end decides it as
            // if there had been no stall. What was typed on time is marked; late keys found unsafe later are dropped alone.
            // A backlog whose cut is gone (a privacy boundary dropped it) starts again.
            else if lateReadAt == nil || !coordinator.captureBinding.holdsLateCut(lateBatches[lateBatches.count-1].cut) {
                lateBatches.removeAll {!coordinator.captureBinding.holdsLateCut($0.cut)}
                let now=typingEnvironment.now()
                lateBatches.append(LateBatch(cut:coordinator.captureBinding.markLateCut(),lastRead:now,open:true))
                // Decided even if this key is never applied (a latch refused it): what the cut holds waits for it.
                typingEnvironment.schedule(Double(Self.lateNoticeNanoseconds)/1_000_000_000+0.01) {[weak self] in self?.settleLateCut()}
                scheduleLateQuiet(after:Double(Self.lateQuietNanoseconds)/1_000_000_000+0.01)
            }
            return same
        }
        if let lateAt=lateReadAt,eventAt<=lateAt,!same {dropLateKeys()}
        return true
    }
    /// A key was applied to the unit: on time, it proves its field; late, the
    /// backlog must be watched until an event typed after now.
    private func keyApplied(_ proof:FocusProof,eventAt:UInt64,late:Bool,readAt:UInt64) {
        if late {
            if let i=lateBatches.indices.last {lateBatches[i].lastRead=max(lateBatches[i].lastRead,readAt);lateBatches[i].open=true}
            typingEnvironment.schedule(Double(Self.lateNoticeNanoseconds)/1_000_000_000+0.01) {[weak self] in self?.settleLateCut()}
            scheduleLateQuiet(after:Double(Self.lateQuietNanoseconds)/1_000_000_000+0.01)
        }
        else {anchor=Anchor(identity:Self.identity(proof),typedAt:eventAt)}
    }
    /// A modifier went down or up. A modifier pressed and let go with no key or
    /// click in between (a double-tap launcher, Fn/Globe alone) or Caps Lock can
    /// move focus.
    private var heldModifiers:CGEventFlags=[]
    private var loneModifier=false
    func handleFlagsChanged(eventAt:UInt64,flags:CGEventFlags) {
        guard !finishingTyping else { interruptTypingFinish(); return }
        guard !stopped,coordinator.isRunning else {return}
        let watched:CGEventFlags=[.maskCommand,.maskControl,.maskAlternate,.maskShift,.maskSecondaryFn,.maskAlphaShift]
        let now=flags.intersection(watched),before=heldModifiers
        heldModifiers=now
        let capsLock=now.contains(.maskAlphaShift) != before.contains(.maskAlphaShift)
        let released = !before.subtracting(now).subtracting(.maskAlphaShift).isEmpty
        let pressed = !now.subtracting(before).subtracting(.maskAlphaShift).isEmpty
        let lone=released && loneModifier
        if pressed {loneModifier=true} else if released {loneModifier=false}
        tapEventSeen(at:eventAt,movesFocus:capsLock || lone)
    }
    /// A system key (NX_SYSDEFINED): it can open a panel.
    func handleSystemKey(eventAt:UInt64) {
        guard !finishingTyping else { interruptTypingFinish(); return }
        guard !stopped,coordinator.isRunning else {return}
        loneModifier=false
        tapEventSeen(at:eventAt,movesFocus:true)
    }
    /// Any mouse button, from the tap: it can move focus.
    func handlePointerDown(eventAt:UInt64) {
        guard !finishingTyping else { interruptTypingFinish(); return }
        MessagesConversation.forget()
        guard !stopped,coordinator.isRunning else {return}
        loneModifier=false
        tapEventSeen(at:eventAt,movesFocus:true)
        handleNativeMouseDown(at:eventAt)
    }
    /// Metadata only: whether the gate refuses where keyboard focus is now.
    private func focusDenied()->Bool {
        guard coordinator.isRunning,coordinator.captureText,let context=try? coordinator.captureBinding.context(),
              let proof=typingEnvironment.proof(context.generation,context.policy.version),coordinator.allowsApp(proof.bundle)
        else {return true}
        return CaptureGate.typing(proof,policy:context.policy,generation:context.generation,now:typingEnvironment.now()).outcome != .allowed
    }

    // This is the production entry point also exercised by synthetic OS adapters.
    // No Task, event copy or asynchronous character acquisition is queued: a
    // key's characters are acquired, if at all, inside this call (owner build,
    // website typing off the main thread, claude/chrome-offmain-1003: inside
    // the tap callback that delivered the key, right after this call, on the
    // route's executor while the tap thread waits: `handleTapOffMain`). Owner build,
    // QF-17 bracketed design only (prototype; privacy review approval needed):
    // WebTypingRoute may acquire a Chrome key's characters here, before proof,
    // into its owned buffer, held unproven for at most the key's bracket (64
    // keys, 1 s) and wiped on discard; nothing is written, logged or counted per
    // key before proof. The synchronous design (default) never does.
    func handleNativeKey(eventAt:UInt64,keyCode:Int64,shortcut:Bool,acquire:() throws -> String) {
        handleNativeKey(eventAt:eventAt,stroke:KeyStroke(keyCode:keyCode,command:shortcut),acquire:acquire)
    }
    func handleNativeKey(eventAt:UInt64,stroke:KeyStroke,acquire:() throws -> String) {
        guard !finishingTyping else { interruptTypingFinish(); return }
        guard !stopped,coordinator.isRunning else {discardPending();return}
        // Typing off: nothing pending to drop, and the window signatures stay,
        // so the next AX notification does not write a second identical row.
        guard coordinator.captureText else {discardPending(resetSignatures:false);Self.releaseAppTrees();return}
        prepareAppTree()
        let now=typingEnvironment.now()
        lastKeyHandledAt=now
        loneModifier=false
        settleLateCut()
        // A late key may have gone to a panel that has closed since (Spotlight):
        // it is read only when nothing could have moved focus since the last
        // key read on time (then only in that key's field); otherwise it is
        // never read, and the unit typed before it is sealed (website typing
        // seals its unfinished text too: TypingKeyGap).
        let late = now<eventAt || now-eventAt>Self.maxKeyLagNanoseconds
        let movesFocus=Self.keyMayMoveFocus(stroke)
        let afterRefusal=lateRefusedAt.map {eventAt<$0 &+ Self.deniedQuietNanoseconds} ?? false
        CaptureDiagnostics.shared.keyLag(eventAt:eventAt,now:now)
        guard !late || (now>=eventAt && !afterRefusal && lateKeyMayRead(eventAt:eventAt,now:now)) else {
            CaptureDiagnostics.shared.count("key.late.refused")
            tapEventSeen(at:eventAt,movesFocus:movesFocus);refuseLateKey(now);TypingKeyGap.lost(at:now);return
        }
        tapEventSeen(at:eventAt,movesFocus:movesFocus)
        keyIsLate=late
        defer {keyIsLate=false}
        if let denied=lastTypingDenial,eventAt<denied &+ Self.deniedQuietNanoseconds {discardPending();return}
        if afterRefusal {sealTyping(.gap,focusMoved:false);TypingKeyGap.lost(at:now);return}
        // Where the key goes: the frontmost app, or a launcher panel the build
        // allows (Spotlight) holding key focus in front of it (never in public builds).
        let target=NativeTypingRoute.keyTargetAppAndFocus(frontmost:currentPID,bundle:currentBundle)
        CaptureDiagnosticsLog.keyTarget(pid:target.pid,bundle:target.bundle)
        noteKeyTarget(target.bundle)
        #if DAYDREAM_OWNER_TYPING
        // Owner build: a key in a Chrome page goes to website typing instead.
        // A Spotlight search over Chrome is Spotlight's (native typing).
        if WebTypingRoute.handle(eventAt:eventAt,stroke:stroke,bundle:target.bundle,pid:target.pid,coordinator:coordinator,keyFocus:target.keyFocus,acquire:acquire) {return}
        #endif
        let binding=coordinator.captureBinding
        // The typing pause chord (Control-Option-Command-T) leaves no shortcut row.
        let marks = !TypingHotkey.isPauseChord(stroke)
        do {
            // The intent comes from metadata only; only .insert reads characters.
            switch keyMap.intent(stroke,pressAndHold:typingEnvironment.pressAndHold()) {
            case .consume: return
            case .noop(let marker): if marker && marks {try writeMarker("keyboard.shortcut")}
            case .retract:
                try binding.recipientExternallyEdited(proof:freshTypingProof(),eventAt:eventAt,now:typingEnvironment.now())
                binding.retract();refreshTypingTimers();try writeMarker("keyboard.shortcut")
            case .redo:
                try binding.recipientExternallyEdited(proof:freshTypingProof(),eventAt:eventAt,now:typingEnvironment.now())
                flushNativeText(reason:.cursor);try writeMarker("keyboard.shortcut")
            case .leave(let reason,let marker):
                // Tab, Esc, chords, Ctrl-Space: focus may move. Park, then judge.
                if reason == .focusKey,stroke.keyCode == Self.escapeKey {escapeTyping()}
                // Control-U / Control-C in a terminal: the line is erased or abandoned, so it is dropped, not saved.
                else if let erase=TypingKeyMap.lineErase(stroke),binding.eraseLine(erase,now:typingEnvironment.now()) {keyMap.reset();refreshTypingTimers()}
                else {sealTyping(TypingKeyMap.switchReason(stroke) ?? reason,focusMoved:true)}
                if marker && marks {try writeMarker("keyboard.shortcut")}
            case .split(let reason): flushNativeText(reason:reason)
            case .submit:
                // While the key is still in the tap, Return commits the unit. It
                // never proves send by itself. messages-1003: in Messages the
                // composer's value is taken as the sent text, and the row is
                // marked sent once a re-read finds the composer empty.
                flushNativeText(reason:.submit);MessagesConversation.forget();try writeMarker("keyboard.submit")
            case .paste:
                try binding.recipientExternallyEdited(proof:freshTypingProof(),eventAt:eventAt,now:typingEnvironment.now())
                flushNativeText(reason:.paste);try writeMarker("keyboard.shortcut")
            case .edit(let op):
                let mutating:Bool
                switch op {case .insert,.deleteBackward,.deleteForward,.cutSelection:mutating=true;default:mutating=false}
                guard let proof=try freshTypingProof() else {try noTypingProof(mutationAt:mutating ? eventAt:nil);return}
                guard lateFieldHolds(proof,eventAt:eventAt,late:late) else {return}
                lateKeysMeetBoundary(proof)
                let step=try binding.edit(op,proof:proof,eventAt:eventAt,now:typingEnvironment.now())
                if step.decision.outcome == .allowed {keyApplied(proof,eventAt:eventAt,late:late,readAt:now)}
                afterTypingStep(step)
            case .insertText(let text): try insertTyping(eventAt:eventAt,deadKey:nil,late:late,readAt:now) {text}
            case .accent(let letter):
                // The popup replaced the held letter. Derived from key codes;
                // nothing is read.
                guard let proof=try freshTypingProof() else {try noTypingProof(mutationAt:eventAt);return}
                guard lateFieldHolds(proof,eventAt:eventAt,late:late) else {return}
                lateKeysMeetBoundary(proof)
                let step=try binding.edit(.deleteBackward(.character),proof:proof,eventAt:eventAt,now:typingEnvironment.now())
                guard step.commit == nil,step.decision.outcome == .allowed else {afterTypingStep(step);return}
                try insertTyping(eventAt:eventAt,deadKey:nil,late:late,readAt:now) {letter}
            case .insert(let deadKey): try insertTyping(eventAt:eventAt,deadKey:deadKey,late:late,readAt:now,acquire:acquire)
            }
        } catch TypingRace.moved {coordinator.captureBinding.unproven(now:typingEnvironment.now());sealTyping(.focus,focusMoved:false)}
        catch MemError.denied {
            // Only a focus denial starts the quiet period; a content rejection
            // (secret latch) keeps its own lock, which Return/Tab/Esc clear.
            if focusDenied() {noteTypingDenial(now)}
            lateKeysMeetBoundary()
            discardPending()
        }
        catch {discardPending();coordinator.captureFailed(error)}
    }
    /// The menu-bar dot follows key focus into a launcher panel that never
    /// becomes the frontmost app (owner builds; public builds allow no panel).
    private var lastKeyTarget:String?
    private func noteKeyTarget(_ bundle:String) {
        guard !CaptureGate.keyPanelApps.isEmpty,bundle != lastKeyTarget else {return}
        lastKeyTarget=bundle
        coordinator.onKeyTarget?(bundle)
    }
    /// Proof, then (inside the binding, under its lock) recording state, gate
    /// and latch, and only then the final proof and the character read.
    private func insertTyping(eventAt:UInt64,deadKey:DeadKey?,late:Bool,readAt:UInt64,acquire:() throws -> String) throws {
        guard let proof=try freshTypingProof() else {try noTypingProof(mutationAt:eventAt);return}
        guard lateFieldHolds(proof,eventAt:eventAt,late:late) else {return}
        lateKeysMeetBoundary(proof)
        // Right after an unproven key, a key in a different field may have been
        // typed into a panel that closed before it was processed (Spotlight):
        // it is not read. The same field (one AX timeout) continues the unit.
        if let unproven=lastUnprovenAt,eventAt<unproven &+ Self.deniedQuietNanoseconds,
           lastProvenIdentity != Self.identity(proof) {noteTypingDenial(unproven);sealTyping(.gap,focusMoved:false);return}
        lastProvenIdentity=Self.identity(proof)
        let context=try coordinator.captureBinding.context()
        let step=try coordinator.captureBinding.insert(proof:proof,eventAt:eventAt,now:typingEnvironment.now(),deadKey:deadKey) {
            guard coordinator.isRunning,coordinator.captureText else {throw MemError.denied}
            guard let final=typingEnvironment.proof(context.generation,context.policy.version),
                  Self.identity(final)==Self.identity(proof) else {throw TypingRace.moved}
            let decision=CaptureGate.typing(final,policy:context.policy,generation:context.generation,now:typingEnvironment.now())
            guard decision.outcome == .allowed else {
                if CaptureGate.typingDenyReasons.contains(decision.reason) {throw MemError.denied}
                throw TypingRace.moved
            }
            return try acquire()
        }
        if step.decision.outcome == .allowed {keyApplied(proof,eventAt:eventAt,late:late,readAt:readAt)}
        afterTypingStep(step)
    }
    /// chatgpt-capture: ChatGPT's web tree (`AppTrees.prepare`): turned on at a key in that app only while recording,
    /// typing, its category and the person's app list allow it (the policy this key is judged by), before the key's
    /// proof. Nothing for any other app; nothing at all outside the owner build (`CaptureGate.webContentApps` is empty).
    private func prepareAppTree() {
        // The app this capture tracks as frontmost (as the key's target below), not a fresh workspace read.
        guard let pid=currentPID,TypingCategories.enhancedUserInterfaceApps.contains(currentBundle),
              CaptureGate.webContentApps.contains(currentBundle) else {return}
        AppTrees.prepare(frontmost:pid) {[coordinator] bundle in
            guard let policy=(try? coordinator.captureBinding.context())?.policy else {return false}
            return coordinator.isRunning && coordinator.captureText && policy.typedText && !policy.excludedApps.contains(bundle) && coordinator.allowsApp(bundle)
        }
    }
    /// chatgpt-capture: turns ChatGPT's accessibility setting back off where DayDream turned it on (recording paused or
    /// stopped, typing off). No Accessibility call when DayDream turned it on nowhere.
    static func releaseAppTrees() { AppTrees.release() }
    private static func identity(_ proof:FocusProof)->[String] {
        var identity=[proof.bundle,proof.windowID,proof.focusID,proof.role,proof.subrole,proof.url]
        // Match the session's Messages recipient boundary at the final proof
        // fence and late-key anchor: reused AX fields cannot vouch for another conversation.
        if proof.bundle == "com.apple.MobileSMS" {
            let field=proof.sendField.isEmpty ? SendRules.fieldClass(role:proof.role,labels:[proof.fieldLabel]) : proof.sendField
            identity.append(SendRules.facts(bundle:proof.bundle,title:proof.place,field:field,seal:.idle).to ?? "")
        }
        return identity
    }
    private func afterTypingStep(_ step:TypingStep) {
        if let reason=step.commit {flushNativeText(reason:reason)} else {refreshTypingTimers()}
    }
    /// Metadata only, before any character read. The raw proof: the binding
    /// runs the gate, and a different field parks the unit instead of
    /// discarding it. One unreadable proof (an AX timeout) is read once more
    /// unless secure input is on. Typing into an app the user or the
    /// sensitive list excludes is a privacy boundary (`discardExcluded`);
    /// when a parked unit is judged, focus in such an app only means the
    /// departure metadata decides (the unit was typed elsewhere).
    private func freshTypingProof(discardExcluded:Bool=true) throws -> FocusProof? {
        let context=try coordinator.captureBinding.context()
        var read=typingEnvironment.proof(context.generation,context.policy.version)
        if read == nil,!typingEnvironment.secureInput() {read=typingEnvironment.proof(context.generation,context.policy.version)}
        guard let proof=read else {return nil}
        guard coordinator.allowsApp(proof.bundle) else {
            if discardExcluded {lateKeysMeetBoundary();discardPending(resetSignatures:false)}
            return nil
        }
        return proof
    }
    /// No metadata proof for a key: secure input is a privacy boundary;
    /// anything else drops the key and keeps the unit open (the next proven
    /// key continues it only in the same field).
    private var lastUnprovenAt:UInt64?
    private var lastProvenIdentity:[String]?
    private func noTypingProof(mutationAt:UInt64?=nil) throws {
        if let mutationAt {try coordinator.captureBinding.recipientExternallyEdited(proof:nil,eventAt:mutationAt,now:typingEnvironment.now())}
        lastUnprovenAt=typingEnvironment.now()
        // Focus may be in a panel no proof can see: no late key reads across it,
        // and late keys already read can't be vouched for.
        focusSignalAt=max(focusSignalAt,typingEnvironment.now())
        if lateReadAt != nil {dropLateKeys(keepOpen:true)}
        if typingEnvironment.secureInput() {lateKeysMeetBoundary();discardPending(resetSignatures:false);return}
        coordinator.captureBinding.unproven(now:typingEnvironment.now());refreshTypingTimers()
    }
    private func writeMarker(_ kind:String) throws {
        guard coordinator.isRunning,!keyIsLate,let proof=try freshTypingProof(),
              try coordinator.captureBinding.typingDecision(proof,now:typingEnvironment.now()).outcome == .allowed else {return}
        try coordinator.commitKeyMarker(kind:kind,proof:proof,now:typingEnvironment.now())
    }
    /// Any mouse button: the caret or focus may move. Park the unit; keys in
    /// the next settle window are unconfirmed until their field is proven.
    /// Website typing (owner build) saves its unfinished text first.
    private func handleNativeMouseDown(at eventAt:UInt64) {
        TypingPointer.down(at:eventAt)
        // A click may change window, tab or page: a front-window judgement waits for the next key.
        TypingFocus.mayHaveMoved()
        sealTyping(.pointer,focusMoved:true)
    }

    private func handleMouseUp(_ event: CGEvent) {
        // Browser clicks are never recorded. Typing was already sealed on mouse down.
        if CaptureSession.excludedBrowsers.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") { resetObservation(resetSignatures: false); return }
        guard let down = mouseDown else { return }
        mouseDown = nil
        // Only clicks are emitted; a drag is not part of the history event set.
        let distance = hypot(event.location.x - down.point.x, event.location.y - down.point.y)
        guard distance <= 6 else { return }
        let kind: HistoryEventKind = down.button == "right" ? .mouseContextMenu : .mouseClick
        let mouse = MouseInfo(button: down.button, clickCount: down.clickCount, modifiers: down.modifiers)
        // perf2-1005: the click's Accessibility read (up to `snapshotBudgetNanoseconds`) ran on main inside the tap's
        // wait; it runs off main now and the click is saved when it answers, in order with the other reads.
        readSnapshot(at: event.location) { [weak self] snap in
            guard let self, !self.stopped, self.coordinator.isRunning else { return }
            self.coordinator.record(kind: kind, snapshot: snap, mouse: mouse)
        }
    }

    // MARK: - Typed units

    /// Reschedules the idle commit, the settle and housekeeping from the
    /// binding's deadlines.
    private func refreshTypingTimers() {
        let deadlines=coordinator.captureBinding.typingDeadlines(),now=typingEnvironment.now()
        if deadlines.idle != nil {coordinator.prefetchTypingKey()}
        func delay(_ deadline:UInt64)->TimeInterval {deadline>now ? Double(deadline-now)/1_000_000_000 : 0}
        if deadlines.idle != idleAt {
            idleAt=deadlines.idle;inputEpoch &+= 1
            if let idle=deadlines.idle {
                let epoch=inputEpoch
                typingEnvironment.schedule(delay(idle)) {[weak self] in self?.flushNativeText(expectedEpoch:epoch,reason:.idle)}
            }
        }
        if deadlines.parked != settleAt {
            settleAt=deadlines.parked;settleEpoch &+= 1
            if let parked=deadlines.parked {
                let epoch=settleEpoch
                typingEnvironment.schedule(delay(parked)) {[weak self] in self?.resolveParkedTyping(expectedEpoch:epoch)}
            }
        }
        if deadlines.housekeeping != housekeepingAt {
            housekeepingAt=deadlines.housekeeping;housekeepingEpoch &+= 1
            if let at=deadlines.housekeeping {
                let epoch=housekeepingEpoch
                typingEnvironment.schedule(delay(at)) {[weak self] in
                    guard let self,epoch == self.housekeepingEpoch else {return}
                    self.housekeepingAt=nil
                    self.coordinator.captureBinding.expireTyping(now:self.typingEnvironment.now())
                    self.refreshTypingTimers()
                }
            }
        }
    }

    /// Live commit: a fresh proof of the same field is read now. Without one,
    /// the unit is parked and judged after the settle.
    /// Returns the row written now and its window, if one was.
    @discardableResult func flushNativeText(expectedEpoch:UInt64?=nil,reason:SealReason = .idle) -> (id:String,windowID:String)? {
        guard !finishingTyping else { return nil }
        if let expectedEpoch,expectedEpoch != inputEpoch {return nil}
        idleAt=nil
        guard !stopped,coordinator.isRunning,coordinator.captureText else {discardPending();return nil}
        do {
            let epoch=inputEpoch
            guard let proof=try freshTypingProof(),epoch==inputEpoch else {
                if typingEnvironment.secureInput() {lateKeysMeetBoundary();discardPending(resetSignatures:false);return nil}
                coordinator.captureBinding.seal(reason,now:typingEnvironment.now(),focusMoved:false);refreshTypingTimers();return nil
            }
            // Late keys in the unit and no event typed after them seen yet (a Return in the backlog): parked and
            // judged after the settle, never written now, so a change heard just after the backlog still drops it.
            if lateReadAt != nil {
                coordinator.captureBinding.seal(reason,now:typingEnvironment.now(),focusMoved:false,proof:proof);refreshTypingTimers();return nil
            }
            lateKeysMeetBoundary(proof)
            // compose-send/v1: at Return the composer's value is the sent text, and a re-read decides the send
            // (`ComposeSend`): Messages, chat, unknown composers; AI asks take the value too (Return already sends there).
            let compose=reason == .submit ? Self.composeAtReturn(proof) : (adopt:false,confirm:false)
            let written=try coordinator.commitTypedText(proof:proof,now:typingEnvironment.now(),reason:reason,sentText:compose.adopt ? typingEnvironment.composerValue : nil)
            if compose.confirm,let written {confirmComposerSend(id:written,windowID:proof.windowID)}
            // A unit still due after its idle commit could not be written (no
            // receipt authority): drop it rather than retry in a loop.
            if reason == .idle,let idle=coordinator.captureBinding.typingDeadlines().idle,idle<=typingEnvironment.now() {discardPending(resetSignatures:false);return nil}
            // Past the bound on lines waiting for late keys, the commit cut the oldest back to its text typed on time.
            writeFreedTyping()
            refreshTypingTimers()
            return written.map {($0,proof.windowID)}
        } catch {discardPending();coordinator.captureFailed(error);return nil}
    }
    /// compose-send/v1: what a Return in this proof's field does: take the composer's value as the text (`adopt`), and
    /// re-read it for a confirmation (`confirm`). Code (terminals, editors), writing and search fields: neither.
    static func composeAtReturn(_ proof:FocusProof)->(adopt:Bool,confirm:Bool) {
        let field=proof.sendField.isEmpty ? SendRules.fieldClass(role:proof.role,labels:[proof.fieldLabel]) : proof.sendField
        let facts=SendRules.facts(bundle:proof.bundle,title:proof.place,field:field,seal:.submit)
        let confirm=ComposeSend.confirmable(surface:facts.surface,field:facts.field,gesture:.returnKey) && facts.send != "detected"
        return (confirm || (facts.surface == "ai" && !["to","subject","search"].contains(facts.field)),confirm)
    }
    /// When the last key was handled (any key), for `confirmComposerSend`.
    private var lastKeyHandledAt:UInt64=0
    /// compose-send/v1: after Return, the composer is re-read (`ComposeSend.confirmChecks`). The first read
    /// that proves the same window's composer and finds it empty marks the row sent; a field still holding text at
    /// the last read, another window, another field or an unreadable state leaves the row a draft. Time alone never
    /// marks a send. Keys typed after the Return end the checks (their text would make the field look full, and a
    /// field emptied by them is not a send).
    private func confirmComposerSend(id:String,windowID:String) {
        let started=typingEnvironment.now()
        var done=false
        for delay in ComposeSend.confirmChecks {
            typingEnvironment.schedule(delay) {[weak self] in
                guard let self,!done,!self.stopped,self.coordinator.isRunning,!self.finishingTyping else {return}
                guard self.lastKeyHandledAt<=started else {done=true;return}
                guard let context=try? self.coordinator.captureBinding.context(),
                      let proof=self.typingEnvironment.proof(context.generation,context.policy.version),
                      proof.windowID == windowID,Self.composeAtReturn(proof).confirm else {return}
                guard self.typingEnvironment.composerEmpty() == true else {return}
                done=true
                self.coordinator.markComposerSent(id:id,windowID:windowID,gesture:.returnKey,confirmation:.fieldCleared)
            }
        }
    }

    /// Parked commit after the settle (every parked unit now with `force`):
    /// the destination proof or departure metadata decides.
    func resolveParkedTyping(expectedEpoch:UInt64?=nil,force:Bool=false) {
        guard !finishingTyping else { return }
        if let expectedEpoch,expectedEpoch != settleEpoch {return}
        settleAt=nil
        guard !stopped,coordinator.isRunning,coordinator.captureText else {discardPending();return}
        do {
            let destination=TypingDestination(proof:try freshTypingProof(discardExcluded:false),departure:typingEnvironment.departure())
            try coordinator.commitParkedText(destination:destination,secureInput:typingEnvironment.secureInput(),now:typingEnvironment.now(),force:force)
            // Parked units still due could not be written: drop, never retry in a loop.
            if coordinator.captureBinding.parkedDue(now:typingEnvironment.now()) {discardPending(resetSignatures:false);return}
            refreshTypingTimers()
        } catch {discardPending();coordinator.captureFailed(error)}
    }

    static let escapeKey:Int64=53
    /// Esc. In a search panel (Spotlight, Raycast, a search field) the
    /// unfinished search is discarded, never saved; elsewhere it parks the
    /// unit like Tab. The proof says where Esc was pressed (metadata only).
    private func escapeTyping() {
        keyMap.reset()
        guard !stopped,coordinator.isRunning else {return}
        let proof=(try? freshTypingProof(discardExcluded:false)) ?? nil
        coordinator.captureBinding.escape(now:typingEnvironment.now(),proof:proof)
        refreshTypingTimers()
    }
    /// The keyboard input source changed (the observer's one call). Units
    /// typed on the direct layout commit; keys under an input method get no
    /// proof. A listener with its own unfinished text (website typing in the
    /// owner build) seals it too (`TypingInputSource`).
    func inputSourceChanged() {
        focusChangeHeard()
        // claude/crashguard-015: the new source, read here on the main queue, for readers off it (`KeyboardInputSource`).
        KeyboardInputSource.refresh()
        TypingInputSource.changed()
        sealTyping(.inputSource,focusMoved:true)
    }
    /// An ordinary boundary: park the live unit; it is judged after the settle.
    func sealTyping(_ reason:SealReason,focusMoved:Bool) {
        keyMap.reset()
        guard !stopped,coordinator.isRunning else {return}
        coordinator.captureBinding.seal(reason,now:typingEnvironment.now(),focusMoved:focusMoved)
        refreshTypingTimers()
    }

    /// Legacy native-only synchronous flush (secure input must be off).
    /// Ordinary Stop/pause uses finishPendingTyping to include Chrome under a
    /// fresh bounded proof; privacy and suspension never start that web drain.
    func commitPendingTyping() {
        guard !finishingTyping else { return }
        guard !stopped,coordinator.isRunning,coordinator.captureText else {return}
        // Late keys are decided first: nothing that may hold them is written before that (gold/r2-typing).
        decideLateKeys()
        flushNativeText(reason:.suspend)
        resolveParkedTyping(force:true)
    }

    /// Privacy boundaries only: faults, pause, policy and consent changes,
    /// excluded apps, secure input. Everything pending is dropped, never written.
    private func discardPending(resetSignatures: Bool = true) {
        finishTypingEpoch &+= 1; finishTypingCompletion = nil; finishingTyping = false
        #if DAYDREAM_OWNER_TYPING
        WebTypingRoute.shared.drop(.focus)
        #endif
        inputEpoch &+= 1;settleEpoch &+= 1;housekeepingEpoch &+= 1;idleAt=nil;settleAt=nil;housekeepingAt=nil;keyMap.reset()
        // No late key reads until a key read on time proves a field again.
        anchor=nil;lateBatches.removeAll()
        coordinator.captureBinding.invalidate(.focus)
        // A privacy boundary also drops a Chrome page read in flight. Keys and
        // clicks with typing off (resetSignatures false) never touch it.
        if resetSignatures {pages.invalidate()}
        resetObservation(resetSignatures:resetSignatures)
    }
    /// Non-typing observation state (clicks, AX debounce, terminal buffer).
    private func resetObservation(resetSignatures: Bool = true) {
        terminalFlush?.cancel(); terminalFlush = nil; terminalText = nil; terminalSnapshot = nil
        mouseDown = nil
        axDebounce.values.forEach { $0.cancel() }; axDebounce.removeAll()
        axReadEpoch &+= 1
        if resetSignatures { lastWindowSignature = nil; lastSelectionSignature = nil }
    }

    // MARK: - Accessibility notifications

    func handleAX(_ notification: String) {
        guard !finishingTyping else { interruptTypingFinish(); return }
        guard !stopped, coordinator.isRunning else { return }
        // Seal before the debounce, not after a delayed callback. Value changes
        // are excluded because each ordinary keystroke changes the field value,
        // and title changes because they do not move focus.
        if notification == kAXFocusedUIElementChangedNotification || notification == kAXFocusedWindowChangedNotification {
            // Every notification still interrupts unsafe late-key backlogs.
            // Some native apps repeat it while typing in the same field.
            focusChangeHeard()
            let sameLiveField:Bool
            do {
                if let proof=try freshTypingProof() {
                    sameLiveField=try coordinator.captureBinding.matchesLiveNativeFocus(proof,now:typingEnvironment.now())
                } else {sameLiveField=false}
            } catch {sameLiveField=false}
            if !sameLiveField {
                sealTyping(notification == kAXFocusedWindowChangedNotification ? .window:.focus,focusMoved:false)
            }
        }
        #if DAYDREAM_OWNER_TYPING
        // QF-17 B3: Chrome's focused-window and title notifications are boundaries for website typing's brackets
        // (they carry no time: treated as inside every bracket not yet decided).
        if currentBundle == ChromePageTarget.bundleID,
           notification == kAXFocusedWindowChangedNotification || notification == kAXTitleChangedNotification {
            WebTypingRoute.shared.chromeWindowNotification()
        }
        #endif
        // Chrome page history: a window or title change asks for one read of
        // the page in front, paced by the recorder itself. Not debounced here,
        // so keys and clicks never cancel it. Chrome's windows are never read
        // through AX.
        if pages.pathActive(currentBundle) {
            if notification == kAXFocusedWindowChangedNotification || notification == kAXTitleChangedNotification { pages.windowChanged() }
            return
        }
        axDebounce[notification]?.cancel()
        let epoch=inputEpoch
        let task = DispatchWorkItem { [weak self] in
            guard self?.inputEpoch==epoch else {return}
            self?.axDebounce.removeValue(forKey: notification)
            self?.processAX(notification)
        }
        axDebounce[notification] = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: task)
    }

    private func processAX(_ notification: String) {
        guard !finishingTyping else { interruptTypingFinish(); return }
        guard !stopped, coordinator.isRunning else { return }
        // Chrome page history: handled in handleAX; Chrome's windows are never
        // read through AX here.
        if pages.pathActive(currentBundle) { return }
        // perf2-1005: the Accessibility read runs off the main thread (laptop sample: `processAX` → `snapshot` was the
        // main thread's Accessibility calls to the app in front); what it found is judged here, on main, if nothing
        // moved meanwhile (no key, no app switch, no reset).
        let epoch = inputEpoch, pid = currentPID, reads = axReadEpoch
        readSnapshot { [weak self] snap in
            guard let self, !self.stopped, !self.finishingTyping, self.coordinator.isRunning,
                  self.inputEpoch == epoch, self.currentPID == pid, self.axReadEpoch == reads else { return }
            self.applyAX(notification, snap)
        }
    }
    private func applyAX(_ notification: String, _ snap: AccessibilitySnapshot?) {
        guard coordinator.accepts(snap) else {
            // A readable context the policy rejects (private title, excluded
            // domain) is a privacy boundary. An unreadable one (browser, secure
            // field or input, excluded app, AX failure) was sealed by handleAX;
            // its parked unit is judged by where focus went.
            if snap != nil {discardPending()} else {resetObservation()}
            return
        }
        switch notification {
        case kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXTitleChangedNotification:
            emitWindowChangeIfNeeded(snap)
        case kAXSelectedTextChangedNotification:
            emitSelection(snap)
        case kAXValueChangedNotification:
            if isTerminal(snap?.app.bundleIdentifier) {
                terminalSnapshot = snap
                terminalText = coordinator.captureText ? snap?.element?.value : nil
                scheduleTerminalFlush()
            }
        default: break
        }
    }

    /// Also the synthetic checks' entry point (with a built snapshot).
    func emitWindowChangeIfNeeded(_ snap: AccessibilitySnapshot?) {
        // claude/title-spinner-1003 (audit B1): the title as it is saved, without the status glyphs an app animates at its
        // ends. Claude Code ticks "✳ / ◐ / ◑ <session>" in a terminal tab about once a second (7,301 of 8,163 rows one
        // night); a tick that only moves the glyph is the same title in the same window, so nothing is written for it.
        guard coordinator.accepts(snap), let snap, let raw = snap.window?.title else { return }
        // claude/cc-label-1003: every tick is seen (a tick that only moves the glyph writes nothing): the window keeps the
        // AI tool its glyph names while its title stays the same (`TerminalToolMemory`).
        TerminalToolMemory.shared.observe(bundle: snap.app.bundleIdentifier ?? "", title: raw)
        let title = TitleClean.statusless(raw)
        guard !title.isEmpty else { return }
        let signature = [snap.focusID, snap.app.bundleIdentifier ?? "", title, snap.window?.url ?? "", snap.element?.role ?? ""].joined(separator: "\u{1F}")
        guard signature != lastWindowSignature else { return }
        lastWindowSignature = signature
        coordinator.record(kind: .windowChanged, snapshot: snap)
    }

    private func emitSelection(_ snap: AccessibilitySnapshot?) {
        guard snap?.browserVerification == nil else { resetObservation(); return }
        guard coordinator.accepts(snap), let snap else { return }
        let text = snap.selectedText
        guard text?.isEmpty == false || (snap.selectedLength ?? 0) > 0 else { return }
        let signature = [snap.focusID, snap.element?.identifier ?? "", text ?? "", "\(snap.selectedLocation ?? -1):\(snap.selectedLength ?? 0)"].joined(separator: "\u{1F}")
        guard signature != lastSelectionSignature else { return }
        lastSelectionSignature = signature
        coordinator.record(kind: .selectionChanged, snapshot: snap,
                           selection: SelectionInfo(selectedText: text, location: snap.selectedLocation, length: snap.selectedLength))
    }

    private func scheduleTerminalFlush() {
        terminalFlush?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.flushTerminal() }
        terminalFlush = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    private func flushTerminal() {
        terminalFlush?.cancel(); terminalFlush = nil
        guard let snap = terminalSnapshot else { terminalText = nil; return }
        let text = terminalText
        terminalText = nil; terminalSnapshot = nil
        // perf2-1005: the focus check reads off the main thread too.
        let reads = axReadEpoch
        readSnapshot { [weak self] current in
            guard let self, !self.stopped, self.coordinator.isRunning, self.axReadEpoch == reads,
                  current?.focusID == snap.focusID, self.coordinator.accepts(current) else { return }
            self.coordinator.record(kind: .terminalValueChanged, snapshot: snap, key: KeyInfo(text: text))
        }
    }

    // MARK: - Installation

    private func installWorkspaceObserver() {
        // Heard at once while DayDream is in the background (a menu bar app mostly is): AppKit holds an observer
        // with the default suspension behavior until DayDream is next active, and keys typed on the new layout
        // would join the unit typed on the old one meanwhile.
        inputSourceObserver=InputSourceListener(name:Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)) {[weak self] in
            self?.inputSourceChanged()
        }
        // claude/crashguard-015: the source selected now, for readers off the main queue until the next change.
        KeyboardInputSource.refresh()
        for name in [NSWorkspace.willSleepNotification,NSWorkspace.sessionDidResignActiveNotification] {
            sleepObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main) {[weak self] _ in
                self?.handleSuspension()
            })
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.switchFrontmost(to: app)
        }
    }
    func handleSuspension() {
        // The existing native-only synchronous flush can finish before the
        // suspension; Chrome never starts or continues an asynchronous drain.
        commitPendingTyping()
        discardPending();coordinator.pause("System slept or session became inactive. Resume explicitly.")
    }

    private func switchFrontmost(to app: NSRunningApplication) {
        switchFrontmost(pid: app.processIdentifier, bundle: app.bundleIdentifier ?? "") { [weak self] pid, chrome in
            self?.installAXObserver(pid: pid, chrome: chrome)
        }
    }
    /// The app switch itself; `observe` installs the AX observer (the synthetic
    /// checks install none). Google Chrome with page history on gets one page
    /// read and no snapshot or app row; leaving Chrome drops any page read.
    func switchFrontmost(pid: pid_t, bundle: String, observe: (pid_t, Bool) -> Void) {
        guard !stopped else { return }
        guard !finishingTyping else { interruptTypingFinish(); return }
        focusChangeHeard()
        sealTyping(.app,focusMoved:true)
        // A front-window judgement (website typing's dot) waits for a key in the app now in front.
        TypingFocus.mayHaveMoved()
        resetObservation()
        currentPID = pid
        currentBundle = bundle
        if Self.signatureWarm { AccessibilityReader.prewarmSignature(pid: pid, bundle: bundle) }
        observe(pid, bundle == ChromePageTarget.bundleID)
        #if DAYDREAM_OWNER_TYPING
        // claude/xtyping-1005: Chrome came to the front (a relaunched Chrome too): wake its accessibility for website
        // typing, so the first key of a page doesn't find it asleep (`WebTypingRoute.chromeInFront`).
        if bundle == ChromePageTarget.bundleID { WebTypingRoute.shared.chromeInFront(pid: pid, coordinator: coordinator) }
        #endif
        if pages.pathActive(bundle) {
            pages.reset()
            pages.trigger(.appSwitch)
            return
        }
        pages.left()
        let snap = snapshot()
        coordinator.record(kind: .appActivated, snapshot: snap)
        emitWindowChangeIfNeeded(snap)
    }

    /// Google Chrome gets only the focused-window and title notifications:
    /// never value, selection or focused-element changes.
    private func installAXObserver(pid: pid_t, chrome: Bool) {
        axRetryEpoch &+= 1
        observeApp(pid: pid, chrome: chrome, attempt: 0)
    }
    /// A new app in front, or a registration it refused, is retried this long after (an app still launching or busy
    /// answers "cannot complete"). Each app switch starts over.
    static let axRetryDelays: [TimeInterval] = [0.5, 2, 5]
    private var axRetryEpoch: UInt64 = 0
    /// Registers the notifications for `pid`: the observer (nil when none could be made) and whether every
    /// notification is registered or not posted by that app at all. False: worth another try. The checks replace
    /// it (they never observe a real app).
    static var registerAX: (pid_t, [String], UnsafeMutableRawPointer) -> (observer: AXObserver?, complete: Bool) = { pid, notifications, pointer in
        var made: AXObserver?
        // perm-1004: never while Accessibility is off (an untrusted Accessibility call makes macOS prompt).
        guard AXIsProcessTrusted(), AXObserverCreate(pid, axTrampoline, &made) == .success, let observer = made else { return (nil, false) }
        let appElement = AXUIElementCreateApplication(pid)
        // An app that has stopped answering can't hold the main thread for the default six seconds per call.
        AXUIElementSetMessagingTimeout(appElement, AccessibilityReader.snapshotTimeout)
        var complete = true
        for notification in notifications {
            switch AXObserverAddNotification(observer, appElement, notification as CFString, pointer) {
            case .success, .notificationAlreadyRegistered, .notificationUnsupported: break
            default: complete = false
            }
        }
        return (observer, complete)
    }
    private func observeApp(pid: pid_t, chrome: Bool, attempt: Int) {
        guard !stopped else { return }
        guard !finishingTyping else { return }
        // Common modes, like the tap: a focus change during an open menu is heard then, not after it closes.
        if let axObserver { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(axObserver), .commonModes) }
        axObserver = nil
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let notifications = chrome ? [kAXFocusedWindowChangedNotification, kAXTitleChangedNotification] : [
            kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification,
            kAXTitleChangedNotification, kAXValueChangedNotification, kAXSelectedTextChangedNotification,
        ]
        let registered = Self.registerAX(pid, notifications, pointer)
        if let observer = registered.observer {
            axObserver = observer
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        guard !registered.complete else { return }
        guard attempt < Self.axRetryDelays.count else {
            RecordingLog.note("App notifications not registered after \(attempt + 1) tries; window changes are read on the next app switch.")
            return
        }
        let epoch = axRetryEpoch
        typingEnvironment.schedule(Self.axRetryDelays[attempt]) { [weak self] in
            guard let self, epoch == self.axRetryEpoch, !self.stopped, self.coordinator.isRunning, self.currentPID == pid else { return }
            self.observeApp(pid: pid, chrome: self.currentBundle == ChromePageTarget.bundleID, attempt: attempt + 1)
        }
    }

    /// The events the tap listens to: keys, modifier changes, mouse buttons, and system keys (NX_SYSDEFINED; only
    /// their time is used, `handleSystemKey`). Modifier changes and system keys are how a late key learns focus may
    /// have moved.
    static let tapMask: CGEventMask = {
        let types: [CGEventType] = [
            .keyDown, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        ]
        return types.reduce(CGEventMask(1) << CGEventMask(systemDefinedEvent)) { $0 | (CGEventMask(1) << $1.rawValue) }
    }()
    private func installEventTap() -> Bool {
        let offMain = Self.tapOffMain
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                     options: .listenOnly, eventsOfInterest: Self.tapMask,
                                     callback: offMain ? offMainTapTrampoline : eventTapTrampoline,
                                     userInfo: offMain ? Unmanaged.passRetained(EventTapTarget(self)).toOpaque() : Unmanaged.passUnretained(self).toOpaque())
        guard let eventTap else { return false }
        eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        let loop: CFRunLoop = offMain ? EventTapThread.shared.runLoop : CFRunLoopGetCurrent()
        eventTapRunLoop = loop
        if let eventTapSource { CFRunLoopAddSource(loop, eventTapSource, .commonModes); CFRunLoopWakeUp(loop) }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return eventTapSource != nil
    }
    private func removeEventTap() {
        if let eventTapSource { CFRunLoopRemoveSource(eventTapRunLoop ?? CFRunLoopGetCurrent(), eventTapSource, .commonModes) }
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventTap = nil; eventTapSource = nil; eventTapRunLoop = nil
    }

    // MARK: - A tap macOS turned off

    /// Turns the tap back on; true when macOS reports it on. The checks replace it (they make no real tap).
    static var reenableTap: (CFMachPort?) -> Bool = { tap in
        guard let tap else { return false }
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }
    /// Whether the tap is on (the heartbeat's check). The checks replace it.
    static var tapIsOn: (CFMachPort?) -> Bool = { tap in tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? true }
    /// Makes the tap again when macOS won't turn the old one back on. The checks replace it.
    static var remakeTap: (EventCapture) -> Bool = { capture in
        capture.removeEventTap()
        return capture.installEventTap()
    }
    private var tapDisables = 0
    private var tapDisableLoggedAt: UInt64?
    /// macOS turned the input tap off: DayDream took too long to take an event (a busy main thread), or user input
    /// did. The tap goes back on and recording goes on (Apple's documented recovery); if it won't, a new tap is
    /// made. Keys and clicks went by unseen meanwhile, so the unit typed before is parked and judged like any other
    /// (dropped if it holds late keys) and no late key reads across the gap. Only when no tap can be had does
    /// recording stop, like a tap that couldn't be made at Start; the app keeps it wanted, so the wake rules start it
    /// again (`MemoryViewModel.recordingEnded`).
    func tapDisabled(byTimeout: Bool = true) {
        guard !finishingTyping else { interruptTypingFinish(); return }
        guard !stopped, coordinator.isRunning else { discardPending(); return }
        focusChangeHeard()
        if lateReadAt != nil { dropLateKeys(focusMoved: true) } else { sealTyping(.gap, focusMoved: true) }
        mouseDown = nil
        heldModifiers = []; loneModifier = false
        tapDisables += 1
        if byTimeout { CaptureDiagnostics.shared.count("tap.disabled.timeout") } else { CaptureDiagnostics.shared.count("tap.disabled.userInput") }
        let now = typingEnvironment.now()
        let log = tapDisableLoggedAt.map { now < $0 || now - $0 >= 60_000_000_000 } ?? true
        let cause = byTimeout ? "timeout" : "user input"
        if Self.reenableTap(eventTap) {
            if log { tapDisableLoggedAt = now; RecordingLog.note("Input tap turned off by macOS (\(cause)); turned back on (\(tapDisables) so far).") }
            return
        }
        if Self.remakeTap(self) {
            if log { tapDisableLoggedAt = now; RecordingLog.note("Input tap turned off by macOS (\(cause)); made again (\(tapDisables) so far).") }
            return
        }
        RecordingLog.note("Input tap turned off by macOS (\(cause)) and couldn't be made again; recording stopped.")
        coordinator.pause("Input tap was disabled. Resume explicitly.")
        stop(reason: "Input tap disabled")
    }
    /// Every half second while recording: a tap macOS turned off without telling (no callback) is recovered the same
    /// way. Also the checks' entry point.
    func heartbeat() {
        guard !finishingTyping else { return }
        guard !stopped, coordinator.isRunning else { return }
        if !Self.tapIsOn(eventTap) { tapDisabled() }
        // perf2-1005: for a minute after a key, the native app in front keeps a fresh signature pass, checked off the
        // main thread (`AccessibilityReader.prewarmSignature`), so a key after a pause doesn't check it on main.
        if let lastKeyAt, let currentPID, !currentBundle.isEmpty, Self.signatureWarm,
           typingEnvironment.now() &- lastKeyAt < Self.signatureWarmNanoseconds {
            AccessibilityReader.prewarmSignature(pid: currentPID, bundle: currentBundle)
        }
        // perf2-1005: key downs the tap took while main was busy reached the tap all the same.
        if tapHandoff.pendingMissedKeys > 0 { keyWatch.keyArrived() }
        watchKeyArrival()
        CaptureDiagnosticsLog.flush(coordinator)
    }
    /// claude/typing-1004: one sample of the session's key count against the keys this tap got (`KeyArrivalWatch`).
    private func watchKeyArrival() {
        guard !keyWatch.proved, !keyWatch.reported else { return }
        let read = Self.keyCounter()
        guard keyWatch.sample(counter: read.count, secureInput: read.secureInput) else { return }
        WebTypingRefusals.shared.note("tap.noKeys")
        WebTypingRefusals.shared.flush()
        RecordingLog.note("Keys typed while recording haven't reached DayDream's input tap (Input Monitoring works only after DayDream reopens).")
        onKeysNotArriving?()
    }
    /// The checks' state of the watch.
    var keyWatchForChecks: KeyArrivalWatch { keyWatch }
    /// The checks' way in to `installAXObserver` (with `registerAX` replaced: they never observe a real app).
    func observeAppForChecks(pid: pid_t, chrome: Bool) { installAXObserver(pid: pid, chrome: chrome) }
    /// The checks' way in to `handleTap`, as the tap's callback delivers an event (they build the event; no tap is made).
    func tapEventForChecks(_ type: CGEventType, _ event: CGEvent) { handleTap(type: type, event: event) }

    // MARK: - Helpers

    /// perf2-1005: one Accessibility read queue (serial: reads answer in the order asked). Set to false, reads run on
    /// the caller as before (the checks that drive capture synchronously).
    static var readsOffMain = true
    private static let axReadQueue = DispatchQueue(label: "daydream.ax-snapshot", qos: .userInitiated)
    /// Bumped by every reset of what's observed: a read asked before it is dropped when it answers.
    private var axReadEpoch: UInt64 = 0
    /// `snapshot(at:)` off the main thread: the same gates on main first, the read on `axReadQueue`, then `apply` on
    /// main with what it found (and the status line it leaves).
    private func readSnapshot(at point: CGPoint? = nil, _ apply: @escaping (AccessibilitySnapshot?) -> Void) {
        guard Self.readsOffMain else { apply(snapshot(at: point)); return }
        guard !finishingTyping, coordinator.isRunning, let currentPID,
              let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == currentPID else { apply(nil); return }
        guard coordinator.allowsApp(front.bundleIdentifier ?? "") else {
            AccessibilityReader.status="Excluded app or browser. No foreground content recorded."; apply(nil); return
        }
        let captureText = coordinator.captureText
        Self.axReadQueue.async {
            let read = AccessibilityReader.read(pid: currentPID, at: point, captureText: captureText)
            DispatchQueue.main.async {
                AccessibilityReader.status = read.status
                apply(read.snapshot)
            }
        }
    }

    private func snapshot(at point: CGPoint? = nil) -> AccessibilitySnapshot? {
        guard !finishingTyping, coordinator.isRunning, let currentPID,
              let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == currentPID else { return nil }
        guard coordinator.allowsApp(front.bundleIdentifier ?? "") else {
            AccessibilityReader.status="Excluded app or browser. No foreground content recorded."; return nil
        }
        return AccessibilityReader.snapshot(pid: currentPID, at: point, captureText: coordinator.captureText)
    }

    private func modifiers(_ flags: CGEventFlags) -> [String] {
        var result: [String] = []
        if flags.contains(.maskCommand) { result.append("command") }
        if flags.contains(.maskControl) { result.append("control") }
        if flags.contains(.maskAlternate) { result.append("option") }
        if flags.contains(.maskShift) { result.append("shift") }
        if flags.contains(.maskSecondaryFn) { result.append("fn") }
        return result
    }

    private func button(for type: CGEventType) -> String {
        switch type {
        case .rightMouseDown, .rightMouseUp: return "right"
        case .otherMouseDown, .otherMouseUp: return "other"
        default: return "left"
        }
    }

    private func isTerminal(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty"].contains(bundleID)
    }
}

/// The keyboard input source changed (a distributed notification). Delivered at once even while DayDream is in the
/// background: AppKit suspends an inactive app's distributed center, and an observer with the default suspension
/// behavior (the block API's) hears nothing until DayDream is next active. `heard` runs on the main thread. The
/// checks pass a name of their own.
final class InputSourceListener: NSObject {
    private let center: DistributedNotificationCenter
    private let name: Notification.Name
    private let heard: () -> Void
    init(center: DistributedNotificationCenter = .default(), name: Notification.Name, heard: @escaping () -> Void) {
        self.center = center; self.name = name; self.heard = heard
        super.init()
        center.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil, suspensionBehavior: .deliverImmediately)
    }
    deinit { center.removeObserver(self, name: name, object: nil) }
    @objc private func changed(_ note: Notification) {
        if Thread.isMainThread { heard() } else { DispatchQueue.main.async(execute: heard) }
    }
}

/// fix/chrome-capture: the app side of `CaptureDiagnostics` (opt-in; see there). It reads the defaults switch, macOS's
/// session key counters and, per key only while diagnostics are on, which process is frontmost (no Accessibility
/// call), and writes the line to the unified log. Process IDs are compared, never logged.
enum CaptureDiagnosticsLog {
    static let logger = os.Logger(subsystem: "com.getnorthlight.daydream", category: "capture-diagnostics")
    private static var counters: (hid: UInt32, session: UInt32)?
    /// fix/chrome-root: `WebTypingRefusals.shared` writes to the app's defaults once wired here (first heartbeat).
    private static var tallyWired = false
    /// Where a key was sent (EventCapture's cached front app, updated on app activation) against the frontmost app and
    /// the app with system focus now: a stale cache sends a Chrome key to native typing, or another app's key to Chrome.
    static func keyTarget(pid: pid_t?, bundle: String) {
        let d = CaptureDiagnostics.shared
        guard d.enabled else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let chrome = ChromePageTarget.bundleID
        if bundle == chrome { d.count("key.target.chrome") } else { d.count("key.target.other") }
        if front?.processIdentifier != pid { d.count("key.target.notFrontmost") }
        if front?.bundleIdentifier == chrome, bundle != chrome { d.count("key.target.missedChrome") }
        // No system-focus read here: it would be an unbounded Accessibility call on main for every key (a timeout on
        // the system-wide element would set every call's default). Chrome's join still requires system focus.
    }
    /// From the heartbeat: at most one line per `CaptureDiagnostics.flushInterval`, only when a count changed.
    static func flush(_ coordinator: Coordinator) {
        #if DAYDREAM_OWNER_TYPING
        // fix/chrome-root: the always-on website typing tally goes to the app's own defaults (read by
        // `mac-mem --local web-typing-refusals`), from this heartbeat, only when a count changed.
        if !tallyWired { tallyWired = true; WebTypingRefusals.shared.persistToDefaults(); WebTypingRoute.wireSearches() }
        WebTypingRefusals.shared.flush()
        #endif
        let d = CaptureDiagnostics.shared
        let wanted = UserDefaults.standard.bool(forKey: CaptureDiagnostics.defaultsKey)
        if wanted != d.enabled { d.setEnabled(wanted); counters = nil }
        guard wanted else { return }
        let line = d.flush(context: {
            guard let c = try? coordinator.captureBinding.context() else { return nil }
            return CaptureDiagnostics.Context(generation: c.generation, policyRevision: c.revision,
                                              captureEpoch: coordinator.session.captureEpoch())
        }, system: {
            let hid = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
            let session = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
            defer { counters = (hid, session) }
            guard let last = counters else { return nil }
            return CaptureDiagnostics.System(hidKeys: Int(hid &- last.hid), sessionKeys: Int(session &- last.session))
        })
        if let line { logger.notice("\(line, privacy: .public)") }
    }
}
