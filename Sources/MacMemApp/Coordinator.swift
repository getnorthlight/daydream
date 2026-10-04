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
import Darwin
import Carbon
import os
import BrowserBridge

/// Adapted from the upstream recorder's coordinator (see the header above).
/// Keeps its single intake/policy boundary, but starts OFF and uses one SQLite
/// transaction store for original evidence and derived records. No helper home,
/// segment copy, writable socket, auto-resume, or swallowed persistence error.
final class Coordinator {
    private let store: MemoryStore
    let session: CaptureSession
    let captureBinding:CoreCaptureBinding
    private let permissionCheck:()->Bool
    private let browserEnvironment:BrowserNativeEnvironment
    let nativeReceipts=NativeCaptureReceipts()
    var onNativeCommitted:((NativeCaptureReceipt)->Void)?
    private var browserProvider:BrowserCaptureProvider?
    private var browserTransport:BrowserCaptureTransport?
    private(set) var browserReceipt:BrowserCaptureReceipt?
    private(set) var browserStatus="Browser metadata unavailable: reviewed provider setup and device validation required."
    private var lockFD: Int32 = -1
    var onPause: (() -> Void)?
    var onStateChanged: (() -> Void)?
    /// Thrown when another DayDream (often a second copy of the app) already holds the recorder lock.
    static let lockHeld = "Another DayDream recorder owns this memory directory."
    /// The app keys go to changed (a launcher panel such as Spotlight took or
    /// left key focus without becoming the frontmost app). The menu-bar dot follows it.
    var onKeyTarget: ((String) -> Void)?
    static var permitted: Bool { AXIsProcessTrusted() && CGPreflightListenEventAccess() }
    init(store: MemoryStore, permissions:@escaping ()->Bool = {Coordinator.permitted}, browserEnvironment:BrowserNativeEnvironment=BrowserNativeEnvironment(), onCommitted: @escaping () -> Void) throws {
        self.store = store
        self.permissionCheck=permissions
        self.browserEnvironment=browserEnvironment
        let binding=CoreCaptureBinding(store:store)
        // claude/cc-label-1003: process names only (no new permission), for a prompt-shaped line in a terminal app.
        binding.terminalToolProbe={TerminalToolProcesses.shared.tool(bundle:$0)}
        self.captureBinding=binding
        let fd = open(store.home.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw MemError.database("recorder lock unavailable") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw MemError.invalid(Coordinator.lockHeld) }
        do { session = try CaptureSession(store: store) }
        catch { close(fd); throw error }
        lockFD = fd
        // gold r3-store: a save written later (`writeLater`) commits off the main thread; what follows a commit (the
        // summary job, the day's refresh) runs on the main thread, as for every other save.
        session.onCommitted = { if Thread.isMainThread { onCommitted() } else { DispatchQueue.main.async { onCommitted() } } }
    }
    deinit { browserTransport?.stop();if lockFD >= 0 { close(lockFD) } }
    /// Intake's gate: the session records and both permissions read on now. A fresh read every time, so a unit read
    /// while a permission reads off is dropped at once.
    var isRunning: Bool { session.state == "recording" && permissionCheck() }
    /// Recording, as its lifecycle sees it (whether the recorder keeps running, whether the app says Recording): the
    /// session records and the permissions are on, where one false read is not enough to say they are off
    /// (`SettledPermission`). Only stopping waits for a loss to hold; intake never does (`isRunning`).
    var recordingSettled: Bool { session.state == "recording" && permittedSettled() }
    /// Both permissions, read now, as `SettledPermission` settles them: a real loss counts after about a second.
    func permittedSettled() -> Bool {
        let read = permissionCheck()
        permissionLock.lock(); defer { permissionLock.unlock() }
        return permission.read(read, at: now())
    }
    private let permissionLock = NSLock()
    private var permission = SettledPermission()
    var captureText = false
    /// The status line (Settings › Diagnostics, Help › Report a Problem). Its cloud part is the summary
    /// setting the app last saved (`setSummaryWriter`), never a fixed "Cloud OFF".
    var label: String { "Capture \(session.state.uppercased()) · \(Coordinator.cloudLabel(summaryMode())). \(session.reason)" }
    /// The summary setting for `label`. gold r3-store: on the main thread the read waits at most `mainWaitBudget` for
    /// another connection's lock (every state change reads the label: a failed save, a pause, the heartbeat), and a
    /// read given up that way (the history held for a moment) says what the last read said, rather than "unknown".
    private func summaryMode() -> String? {
        let read = Thread.isMainThread ? StoreWait.bounded(Self.mainWaitBudget) { try store.summaryWriter()?.mode }
                                       : (result: Result { try store.summaryWriter()?.mode }, heldUp: false)
        switch read.result {
        case .success(let mode): lastSummaryMode = .some(mode); return mode
        case .failure: if read.heldUp || StoreWait.heldUpNow, let last = lastSummaryMode { return last }; return nil
        }
    }
    private var lastSummaryMode: String??
    static func cloudLabel(_ mode: String?) -> String {
        switch mode {
        case "cloud": return "Cloud summaries ON (OpenRouter)"
        case "off", "local": return "Cloud OFF"
        default: return "Cloud summaries unknown"
        }
    }
    /// Starts recording on one permission read (`permitted`: the caller's own, when it made one). Two reads that
    /// disagree must never leave the session recording with nothing started, or started with no save authority.
    func start(permitted given: Bool? = nil) throws {
        newRun()
        dropped.reset();healthFailures=0;heldSince=nil;closeBrowserTransport();nativeReceipts.invalidate();captureBinding.invalidate(.pause)
        // The choices intake judges by are read again at every start.
        policyChanged()
        let permitted = given ?? permissionCheck()
        permissionLock.lock(); permission = SettledPermission(); _ = permission.read(permitted, at: now()); permissionLock.unlock()
        try session.start(permitted: permitted)
        if session.state == "recording" {nativeReceipts.begin();if let browserProvider {let transport=BrowserCaptureTransport(provider:browserProvider,coordinator:self);browserTransport=transport;transport.start()}}
        onStateChanged?()
    }
    /// - drain: saves still waiting to be written (the history was held a moment, `writeLater`) go in first, as they
    ///   would have before the pause when they were written at once. A pause for a failed save doesn't wait for them.
    func pause(_ reason: String, drain: Bool = true) {
        if drain { drainUnits() }
        newRun()
        closeBrowserTransport()
        nativeReceipts.invalidate()
        captureBinding.invalidate(.pause)
        try? session.pause(reason)
        onPause?(); onStateChanged?()
    }
    func stop() { drainUnits();newRun();closeBrowserTransport();nativeReceipts.invalidate();captureBinding.invalidate(.pause);try? session.stop(); onPause?(); onStateChanged?() }
    /// Additive setup handoff. The normal app has no reviewed provider resolver
    /// yet, so this is never called from launch, intent fields or key creation.
    func configureBrowserProvider(_ provider:BrowserCaptureProvider?) {
        precondition(Thread.isMainThread)
        closeBrowserTransport();browserProvider=provider
    }
    func resolveBrowserProvider(bundle:Bundle) {
        precondition(Thread.isMainThread)
        do {configureBrowserProvider(try BrowserProviderResolver.bundled(bundle));browserStatus="Browser provider reviewed; recording still requires Start."}
        catch {configureBrowserProvider(nil);browserStatus="Browser metadata unavailable: enrollment or validated provider evidence missing."}
    }
    private func closeBrowserTransport() {
        browserTransport?.stop();browserTransport=nil;captureBinding.closeBrowsers();browserReceipt=nil
    }
    func browserTransportFailed(_ source:BrowserCaptureTransport) {
        guard browserTransport === source else {return} // old stop/EOF cannot cancel a newer capture session
        closeBrowserTransport();browserStatus="Browser connection unavailable. Review provider setup.";onStateChanged?()
    }
    func browserNativeGate() throws -> MetadataGate {
        precondition(Thread.isMainThread)
        let context=try captureBinding.context()
        var gate=MetadataGate()
        let front=browserEnvironment.frontmost()
        gate.permissionPresent=permissionCheck();gate.secureInputOff = browserEnvironment.secureInputOff()
        gate.captureEnabled=isRunning;gate.excluded=context.policy.excludedApps.contains(front)
        gate.generation=Int(context.generation)
        gate.frontmostBrowserBundle=browserEnvironment.frontmost() == front ? front : ""
        gate.checkedAt=browserEnvironment.now()
        return gate
    }
    func browserRequest(_ connection:CoreBrowserConnection) throws -> Data? {
        let gate=try browserNativeGate()
        return try connection.request(native:gate,now:browserEnvironment.now())
    }
    func browserResponse(_ connection:CoreBrowserConnection,request:Data,response:Data) throws -> Bool {
        browserReceipt=nil
        let gate=try browserNativeGate()
        guard try connection.receive(response,native:gate,now:browserEnvironment.now()),
              let receipt=try BrowserReceiptReadback.read(store:store,request:request,now:Date()) else {return false}
        browserReceipt=receipt;session.onCommitted?();onStateChanged?();return true
    }
    /// Called on the same main actor as EventCapture intake. Invalidates proof
    /// before removing the tap and discarding every pending burst.
    func stopForPreferences(capture:EventCapture?) {
        precondition(Thread.isMainThread)
        stop()
        capture?.stop(reason:"Preferences changed. Resume explicitly.")
    }
    /// The 0.5 s heartbeat. One failed heartbeat doesn't stop recording: another connection may have held the file for
    /// a moment. Three in a row, or one that failed for any other reason, pause it (`storageFault`), and the app tries
    /// again by itself. One false permission read doesn't stop it either: a loss must hold (`permittedSettled`).
    func reconcileResume() {
        // gold r3-store: the heartbeat waits at most `mainWaitBudget` in all for another connection's lock, the menu's
        // reads after it (`onStateChanged`) included. A heartbeat held up that way counts as a failed one only once the
        // history has been held for as long as one heartbeat used to wait (`heldCountsAfter`, the 1.5 s busy timeout),
        // so recording pauses after the same time held as before (three such waits), without the main thread waiting.
        _ = StoreWait.bounded(Self.mainWaitBudget) { reconcileResumeBounded() }
    }
    private func reconcileResumeBounded() {
        do {
            let attempt = StoreWait.bounded(Self.mainWaitBudget) { try session.health(permitted: permittedSettled()) }
            if attempt.heldUp, case .failure(let error) = attempt.result, CaptureFault.busy(error) {
                faulted = true
                let at = now()
                let since = heldSince ?? at
                heldSince = since
                if at.timeIntervalSince(since) < Self.heldCountsAfter {
                    if session.state == "recording" {
                        if !nativeReceipts.active { nativeReceipts.begin(); RecordingLog.note("Save authority restored while recording.") }
                    } else { closeBrowserTransport();nativeReceipts.invalidate();onPause?() }
                    onStateChanged?()
                    return
                }
                // One failed heartbeat per `heldCountsAfter` held (not from this heartbeat on: heartbeats that come
                // late would stretch the time held before the pause).
                heldSince = since.addingTimeInterval(Self.heldCountsAfter)
            }
            try attempt.result.get()
            heldSince = nil
            healthFailures = 0
            // The choices intake judges by, read again (a change saved elsewhere, such as mac-mem). A read that fails
            // keeps the last ones: every save reads them again from the history anyway (CaptureSession.record).
            reloadPolicy()
            // Saving works again only while recording. A heartbeat that saves while recording is paused for a failed
            // save (the recorder's timer runs once more before it stops) says nothing about that save: the app's retry,
            // a fresh Start, must still run.
            if faulted && session.state == "recording" { faulted = false; RecordingLog.note("Saving works again."); onHealthy?() }
        } catch {
            healthFailures += 1
            faulted = true
            let recordingNow = session.state == "recording"
            let busy = CaptureFault.classify(error, sessionRecording: recordingNow) == .dropUnit
            let pausing = recordingNow && (!busy || healthFailures >= Self.healthFailureLimit)
            RecordingLog.fault("heartbeat", error: error, action: pausing ? "paused" : recordingNow ? "kept recording" : "not recording")
            if pausing { storageFault(error) }
        }
        // Save authority goes with recording. While the session records, commits are authorized: nothing that dropped
        // one unit (or read a permission off once) leaves recording on with every later unit refused unsaid.
        if session.state == "recording" {
            if !nativeReceipts.active { nativeReceipts.begin(); RecordingLog.note("Save authority restored while recording.") }
        } else { closeBrowserTransport();nativeReceipts.invalidate();onPause?() }
        onStateChanged?()
    }
    /// Failed heartbeats in a row before recording pauses (only busy ones; any other pauses at once).
    static let healthFailureLimit = 3
    private var healthFailures = 0
    /// gold r3-store: since when the heartbeat has been held up by another connection's lock (`reconcileResume`).
    private var heldSince: Date?
    /// How long the history must stay held before a held-up heartbeat counts as one failed heartbeat: the busy timeout
    /// each heartbeat used to wait on the main thread.
    static let heldCountsAfter: TimeInterval = 1.5
    /// How long the main thread's capture paths (a save, the heartbeat) wait in all for another connection's lock.
    static let mainWaitBudget: TimeInterval = StoreWait.mainBudget
    /// A fault since the last good heartbeat while recording (`onHealthy` fires once one is good again).
    private var faulted = false
    private var dropped = CaptureFaultBudget()
    /// When a fault is noted; the checks substitute a clock.
    var now: () -> Date = { Date() }
    /// Recording paused because a save failed; the app starts it again by itself (`StorageRetry`).
    var onStorageFault: (() -> Void)?
    /// The first good heartbeat while recording after a fault (never one while paused: that isn't a recovery).
    var onHealthy: (() -> Void)?
    /// The last pause for a failed save was a full disk.
    private(set) var storageFull = false
    /// The reason written while the app tries again (RecordingCopy maps it to "Couldn't save for a moment. Trying again.").
    static let storageRetryReason = CaptureFault.retryReason
    /// A failed save that won't pass in a moment: recording pauses with the retry reason, and the app tries again.
    private func storageFault(_ error: Error) {
        // gold r3-store: recording pauses because the history couldn't be written, so the pause's own write waits at
        // most `mainWaitBudget` on the main thread (it used to wait 1.5 s a statement, and usually failed as well: the
        // session then reads "error", and the app shows the same "trying again" state and retries either way).
        if Thread.isMainThread { _ = StoreWait.bounded(Self.mainWaitBudget) { storageFaultBounded(error) } }
        else { storageFaultBounded(error) }
    }
    private func storageFaultBounded(_ error: Error) {
        dropped.reset(); healthFailures = 0; heldSince = nil; faulted = true
        storageFull = CaptureFault.diskFull(error)
        pause(storageFull ? CaptureFault.fullReason : Self.storageRetryReason, drain: false)
        onStorageFault?()
    }
    func finish(reason: String) { if session.state == "recording" { pause(reason) } }
    /// Google Chrome counts only while "Web pages in Chrome" is on; every other
    /// browser (Chrome Beta, Dev, Canary and web-app shims included) never does.
    func allowsApp(_ bundle: String) -> Bool {
        guard !bundle.isEmpty, let settings = policyForIntake() else { return false }
        if bundle == BrowserSafety.supportedBundle {
            guard settings.browserPagesOn else { return false }
        } else if CaptureSession.excludedBrowsers.contains(bundle) { return false }
        return settings.policy.dropReason(bundleIdentifier: bundle, windowTitle: nil, urlDomain: nil) == nil
    }
    func accepts(_ snap: AccessibilitySnapshot?) -> Bool {
        guard isRunning, let snap, let settings = policyForIntake() else { return false }
        return CaptureSession.accepts(evidence(snap, kind: .windowChanged, text: "", id: "check"), focusedFieldKnown: !snap.focusID.isEmpty, settings: settings)
    }
    func acceptsTyping(_ snap: AccessibilitySnapshot?) -> Bool {
        // gold r3-store: typing is judged by the choices read now, never the last ones read: a read held up by another
        // connection (at most `mainWaitBudget` on the main thread) refuses the typing, as a read that failed did.
        guard captureText, accepts(snap), let snap,
              let settings = (Thread.isMainThread ? (try? StoreWait.bounded(Self.mainWaitBudget) { try store.policy() }.result.get()) : (try? store.policy())) else { return false }
        return PreCapturePrivacy.nativeTypingAllowed(bundle:snap.app.bundleIdentifier ?? "",role:snap.element?.role ?? "",url:snap.window?.url ?? "",secure:snap.secureInput,settings:settings)
    }
    private func evidence(_ snap: AccessibilitySnapshot, kind: HistoryEventKind, text: String, id: String) -> Evidence {
        var e = Evidence(id: id, at: iso(Date()), kind: kind.rawValue, app: snap.app.name ?? "Unknown app", bundle: snap.app.bundleIdentifier ?? "", title: snap.window?.title ?? "", url: snap.window?.url ?? "", text: text, secure: snap.secureInput, privateWindow: snap.privateBrowsing, browserVerification:snap.browserVerification)
        // claude/cc-label-1003: a terminal window keeps the AI tool its title last showed while the title stays the same.
        if let tool = TerminalToolMemory.shared.observe(bundle: e.bundle, title: e.title), !tool.isEmpty { e.titleTool = tool }
        return e
    }
    func record(kind: HistoryEventKind, snapshot: AccessibilitySnapshot?, key: KeyInfo? = nil, selection: SelectionInfo? = nil, mouse: MouseInfo? = nil, diagnostic: Diagnostic? = nil) {
        // gold r3-store: one event's reads and its save share one wait of at most `mainWaitBudget` on the main thread.
        let body = { [self] in
            // Boundary markers never justify persisting an unknown/sensitive context.
            guard kind != .sessionStarted, kind != .sessionEnded, accepts(snapshot), let snapshot else { return }
            recordAccepted(kind: kind, snapshot: snapshot, key: key, selection: selection)
        }
        if Thread.isMainThread { _ = StoreWait.bounded(Self.mainWaitBudget, body) } else { body() }
    }
    private func recordAccepted(kind: HistoryEventKind, snapshot: AccessibilitySnapshot, key: KeyInfo?, selection: SelectionInfo?) {
        // Typed text has one producer: CoreCaptureBinding, never this legacy path.
        if kind == .textInput { return }
        if kind == .selectionChanged || kind == .terminalValueChanged { return }
        let unit = MetadataUnit(source: evidence(snapshot, kind: kind, text: key?.text ?? selection?.selectedText ?? "", id: ""),
                                focusedFieldKnown: !snapshot.focusID.isEmpty, at: Date(), run: currentRun)
        // gold r3-store: saves waiting to be written go first, in order: this one joins them.
        if unitsWaiting > 0 { writeLater(unit); return }
        // Written now, waiting at most `mainWaitBudget` for another connection's lock. A save the history was held
        // for (an AI app's read committing, a backup, another process writing) is written a moment later, off the
        // main thread (`writeLater`), instead of the main thread waiting up to 1.5 s and then dropping it.
        let attempt = StoreWait.bounded(Self.mainWaitBudget) { try commitUnit(unit) }
        switch attempt.result {
        case .success(let receipt):
            if let receipt {onNativeCommitted?(receipt)}
            // Save authority stays: a unit that is only dropped leaves recording on, and the next unit must save.
            // Whatever pauses or stops (captureFailed's storage fault included) takes it away itself.
        case .failure(let error) where CaptureFault.busy(error):
            writeLater(unit)
        case .failure(let error):
            onPause?();captureFailed(error,recording:true)
        }
    }
    /// A click, window or app change, as read on the main thread. `permitted` is the permission read made for it
    /// (made when it is first written, as always: one read per unit).
    final class MetadataUnit {
        let source: Evidence
        let focusedFieldKnown: Bool
        let at: Date
        let run: Int
        var permitted: Bool?
        init(source: Evidence, focusedFieldKnown: Bool, at: Date, run: Int) { self.source = source; self.focusedFieldKnown = focusedFieldKnown; self.at = at; self.run = run }
    }
    /// - later: written after the moment (`writeLater`). The run is checked under the receipts' lock, which a start
    ///   takes to begin new authority, so a unit of an earlier run is never written under a later one.
    private func commitUnit(_ unit: MetadataUnit, later: Bool = false) throws -> NativeCaptureReceipt? {
        try nativeReceipts.commit(store:store,path:.metadata) {id in
            if later && currentRun != unit.run { return false }
            var source=unit.source; source.id=id
            let permitted=unit.permitted ?? permittedSettled()
            unit.permitted=permitted
            return try session.record(source,focusedFieldKnown:unit.focusedFieldKnown,permitted:permitted)
        }
    }
    /// gold r3-store: how long a unit written later keeps trying: under the receipt's 5 s window (NativeCaptureReceipts).
    static let unitPatience: TimeInterval = 4
    /// How long a pause or stop waits, at most, for units still waiting to be written (`drainUnits`): the 1.5 s one save
    /// used to wait on the main thread.
    static let drainPatience: TimeInterval = 1.5
    /// Units handed to `unitQueue` and not yet finished (main thread only).
    private(set) var unitsWaiting = 0
    private let unitQueue = DispatchQueue(label: "com.getnorthlight.daydream.capture-units", qos: .userInitiated)
    private let runLock = NSLock()
    private var run = 0
    private var drainBy: Date?
    /// Recording's current run: a start, pause or stop begins a new one, and a unit waiting from an earlier run is
    /// never written (nothing written after a pause, as before).
    private var currentRun: Int { runLock.lock(); defer { runLock.unlock() }; return run }
    private func newRun() { runLock.lock(); run += 1; runLock.unlock() }
    private var drainDeadline: Date? { runLock.lock(); defer { runLock.unlock() }; return drainBy }
    /// Written on `unitQueue`, in order, trying again while the history is held (each try waits `mainWaitBudget` at
    /// most, so the main thread never waits long for the store's lock either), until `unitPatience` after the event.
    /// What a save that failed for good does (the drop budget, a pause) happens on the main thread, as before.
    private func writeLater(_ unit: MetadataUnit) {
        unitsWaiting += 1
        unitQueue.async { [weak self] in
            guard let self else { return }
            var result: Result<NativeCaptureReceipt?, Error> = .success(nil)
            var stale = false
            while true {
                guard self.currentRun == unit.run else { stale = true; break }
                // gold/int r3 review: a pause or stop waits `drainPatience` in all, not one more try per unit after it.
                if let drain = self.drainDeadline, Date() >= drain { stale = true; RecordingLog.note("A capture save written later was still held when recording paused; dropped."); break }
                result = StoreWait.bounded(Self.mainWaitBudget) { try self.commitUnit(unit, later: true) }.result
                guard case .failure(let error) = result, CaptureFault.busy(error) else { break }
                let now = Date()
                if now >= unit.at.addingTimeInterval(Self.unitPatience) { break }
                if let drain = self.drainDeadline, now >= drain { break }
                usleep(20_000)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.unitsWaiting -= 1
                switch result {
                case .success(let receipt): if !stale, let receipt { self.onNativeCommitted?(receipt) }
                case .failure(let error):
                    // A unit of an earlier run (recording paused or stopped since) changes nothing now.
                    guard !stale, self.currentRun == unit.run else {
                        RecordingLog.note("A capture save written later failed after recording changed: \(RecordingLog.name(error)); dropped.")
                        return
                    }
                    self.onPause?(); self.captureFailed(error, recording: true)
                }
            }
        }
    }
    /// Units still waiting go in before a pause or stop (at most `drainPatience`).
    private func drainUnits() {
        guard unitsWaiting > 0 else { return }
        runLock.lock(); drainBy = Date().addingTimeInterval(Self.drainPatience); runLock.unlock()
        unitQueue.sync {}
        runLock.lock(); drainBy = nil; runLock.unlock()
    }
    /// gold r3-store: the saved choices intake judges each event by (`accepts`, `acceptsTyping`, `allowsApp`). Read
    /// from the history for every event, as before, but on the main thread the read waits at most `mainWaitBudget` for
    /// another connection (it used to wait 1.5 s, then fail, and the click was dropped with nothing said). A read held
    /// up that way uses the choices last read (and, for a quarter second, doesn't try again, so a click under a hold
    /// doesn't wait twice); every save reads them again from the history itself (`CaptureSession.record`), so an
    /// event judged by choices changed a moment ago elsewhere is still refused there. A read that fails otherwise, or
    /// with nothing read yet, refuses the event, as before.
    private var intakePolicy: PrivacySettings?
    private var intakeHeldUntil: Date?
    private let intakePolicyLock = NSLock()
    private func policyForIntake() -> PrivacySettings? {
        intakePolicyLock.lock(); let known = intakePolicy, heldUntil = intakeHeldUntil; intakePolicyLock.unlock()
        guard Thread.isMainThread else { return reloadPolicy() }
        if let known, unitsWaiting > 0 || (heldUntil.map { Date() < $0 } ?? false) { return known }
        let read = StoreWait.bounded(Self.mainWaitBudget) { try store.policy() }
        switch read.result {
        case .success(let settings):
            intakePolicyLock.lock(); intakePolicy = settings; intakeHeldUntil = nil; intakePolicyLock.unlock()
            return settings
        case .failure where read.heldUp:
            intakePolicyLock.lock(); intakeHeldUntil = Date().addingTimeInterval(0.25); intakePolicyLock.unlock()
            return known
        case .failure:
            return nil
        }
    }
    @discardableResult private func reloadPolicy() -> PrivacySettings? {
        guard let read = try? store.policy() else { return nil }
        intakePolicyLock.lock(); intakePolicy = read; intakeHeldUntil = nil; intakePolicyLock.unlock()
        return read
    }
    /// The saved choices changed (a preference save landed): intake judges nothing by the old ones (an event with no
    /// readable choices is not recorded, as before) and reads them again.
    func policyChanged() {
        intakePolicyLock.lock(); intakePolicy = nil; intakeHeldUntil = nil; intakePolicyLock.unlock()
        if Thread.isMainThread { _ = StoreWait.bounded(Self.mainWaitBudget) { reloadPolicy() } } else { reloadPolicy() }
    }
    /// The saved policy, for Chrome page history (switch, owner's site list, revision).
    func pageSettings() -> PrivacySettings? { try? store.policy() }
    /// One Chrome page row: title (none for site-only pages, except an email page's kept title: email-1003), origin and time.
    /// Written only while recording, while Chrome is allowed (the switch is on)
    /// and under the policy revision the read started with.
    /// Whether the page row was written. A refused row (late, switch off,
    /// policy changed) is false, so the recorder can look again.
    @discardableResult func recordPage(_ read: ChromePageRead, appName: String, checkedAt: Date, policyRevision: String) -> Bool {
        guard isRunning, allowsApp(BrowserSafety.supportedBundle), let settings = try? store.policy(),
              settings.revision == policyRevision else { return false }
        var wrote=false
        do {
            let receipt=try nativeReceipts.commit(store:store,path:.metadata) {id in
                var proof=BrowserVerification(mode:"normal",windowID:read.windowID,tabID:read.tabID,focusedRole:"",checkedAt:isoPrecise(checkedAt),provider:BrowserSafety.pageProvider)
                proof.policyRevision=policyRevision
                var page=Evidence(id:id,at:isoPrecise(Date()),kind:HistoryEventKind.windowChanged.rawValue,app:appName,bundle:BrowserSafety.supportedBundle,
                                  title:read.title,url:read.origin,text:"",secure:false,privateWindow:false,browserVerification:proof)
                // fix/show-all: the page's own link, on this Mac only (Open Original opens the page, not just its site).
                page.page=read.siteOnly ? nil : read.link
                wrote=try session.record(page,focusedFieldKnown:true,permitted:permittedSettled())
                return wrote
            }
            if let receipt {onNativeCommitted?(receipt)}
        } catch {onPause?();captureFailed(error,recording:true)}
        return wrote
    }
    /// Chrome app time: "Google Chrome" and the time, while Chrome is allowed ("Web pages in Chrome" on) but its page
    /// can't be read. No title, address, window or tab. Whether it was written.
    @discardableResult func recordChromeAppTime(appName: String, policyRevision: String) -> Bool {
        guard isRunning, allowsApp(BrowserSafety.supportedBundle), let settings = try? store.policy(),
              settings.revision == policyRevision else { return false }
        var wrote=false
        do {
            let receipt=try nativeReceipts.commit(store:store,path:.metadata) {id in
                let now=Date()
                var proof=BrowserVerification(mode:"",windowID:"",tabID:"",focusedRole:"",checkedAt:isoPrecise(now),provider:BrowserSafety.appTimeProvider)
                proof.policyRevision=policyRevision
                let row=Evidence(id:id,at:isoPrecise(now),kind:HistoryEventKind.appActivated.rawValue,app:appName,bundle:BrowserSafety.supportedBundle,
                                 title:"",url:"",text:"",secure:false,privateWindow:false,browserVerification:proof)
                wrote=try session.record(row,focusedFieldKnown:true,permitted:permittedSettled())
                return wrote
            }
            if let receipt {onNativeCommitted?(receipt)}
        } catch {onPause?();captureFailed(error,recording:true)}
        return wrote
    }
    /// Live commit of the typed unit. With no unit pending only the boundary
    /// is noted (a non-idle reason ends the run and clears a latch).
    /// The written row's ID, or nil. `sentText`: see `CoreCaptureBinding.commitText`.
    @discardableResult func commitTypedText(proof:FocusProof,now:UInt64,reason:SealReason = .idle,sentText:(() -> String?)?=nil) throws -> String? {
        guard isRunning,captureText else {return nil}
        guard captureBinding.hasPendingTyping else {captureBinding.seal(reason,now:now,focusMoved:false,proof:proof);return nil}
        let receipt=try nativeReceipts.commit(store:store,path:.typedText) {id in try captureBinding.commitText(id:id,proof:proof,now:now,reason:reason,sentText:sentText)}
        if let receipt {session.onCommitted?();onNativeCommitted?(receipt)}
        return receipt?.actionID
    }
    /// compose-send/v1: a row whose composer was confirmed after its gesture is marked sent (`MemoryStore.markComposerSent`).
    /// `wallTime`: the caller's wall clock (website typing's route passes its own, claude/chrome-offmain-1003).
    func markComposerSent(id:String,windowID:String,gesture:ComposeGesture,confirmation:ComposeConfirmation,wallTime:Date=Date()) {
        guard isRunning,captureText else {return}
        do { if try captureBinding.markComposerSent(id:id,windowID:windowID,gesture:gesture,confirmation:confirmation,wallTime:wallTime) {session.onCommitted?()} } catch {}
    }
    /// Parked commits after the settle: one receipt per unit, oldest first. Every unit that can be parked at once is
    /// written: the FIFO's own and those that waited for late keys, which come due together once vouched for
    /// (gold/r2-typing review round 1: a sixth unit due was dropped as "could not be written").
    func commitParkedText(destination:TypingDestination,secureInput:Bool,now:UInt64,force:Bool=false) throws {
        guard isRunning,captureText else {return}
        let limits=TypingLimits()
        for _ in 0...(limits.maxParked+limits.maxHeldForLateKeys) {
            guard captureBinding.parkedDue(now:now,force:force) else {return}
            let receipt=try nativeReceipts.commit(store:store,path:.typedText) {id in
                try captureBinding.commitParked(id:id,destination:destination,secureInput:secureInput,now:now,force:force) ?? false
            }
            if let receipt {session.onCommitted?();onNativeCommitted?(receipt)}
        }
    }
    func commitKeyMarker(kind:String,proof:FocusProof,now:UInt64) throws {
        guard isRunning,captureText else {return}
        let receipt=try nativeReceipts.commit(store:store,path:.keyMarker) {id in try captureBinding.commitKeyMarker(id:id,kind:kind,proof:proof,now:now)}
        if let receipt {session.onCommitted?();onNativeCommitted?(receipt)}
    }
    /// A capture write failed. The caller has already dropped the unit (nothing is kept to write later).
    /// - A momentary refusal (busy, a late heartbeat, a policy or session change): recording goes on. Five within a
    ///   minute pause it once, as a failed save.
    /// - A locked typing key: typing waits for the key; recording goes on.
    /// - A unit that wasn't allowed (a check said no, typing not accepted): not a failed save; recording goes on, and
    ///   nothing counts, pauses or retries.
    /// - Anything else: recording pauses and the app tries again by itself (`onStorageFault`).
    /// - `recording`: the write was made while recording (the session may have paused itself since); nil reads the session.
    func captureFailed(_ error: Error, recording: Bool? = nil) {
        let recordingNow = recording ?? (session.state == "recording")
        let fault = CaptureFault.classify(error, sessionRecording: recordingNow)
        switch fault {
        case .typingLocked:
            RecordingLog.fault("capture", error: error, action: "dropped the unit")
            onStateChanged?()
        case .refused:
            RecordingLog.note("capture unit not allowed: \(RecordingLog.name(error)); dropped the unit.")
            onStateChanged?()
        case .dropUnit:
            // A unit refused because the heartbeat ran late: write one now, so the next unit isn't refused too.
            let stale = CaptureFault.staleHeartbeat(error, sessionRecording: recordingNow)
            if stale || CaptureFault.busy(error) { faulted = true }
            if stale { try? session.health(permitted: permittedSettled()) }
            guard recordingNow, dropped.dropped(at: now()) else {
                RecordingLog.fault("capture", error: error, action: "dropped the unit")
                onStateChanged?()
                return
            }
            RecordingLog.fault("capture", error: error, action: "paused after \(CaptureFaultBudget.limit) dropped units")
            storageFault(error)
        case .storage, .other:
            // Only a live recorder pauses (and is retried): a write that fails after recording stopped changes nothing.
            guard recordingNow else { RecordingLog.fault("capture", error: error, action: "not recording"); onStateChanged?(); return }
            RecordingLog.fault("capture", error: error, action: "paused")
            storageFault(error)
        }
    }
}

/// Recording faults, pauses, stops and retries, for `log show --predicate 'subsystem == "com.getnorthlight.daydream"'`
/// and Help › Report a Problem. Only the kind of event, the SQLite code or OSStatus and what DayDream did: never a
/// title, typed text, site or path.
enum RecordingLog {
    static let logger = os.Logger(subsystem: "com.getnorthlight.daydream", category: "recording")
    static func note(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        DiagnosticsLog.shared.record("Recording: " + line)
    }
    static func fault(_ path: String, error: Error, action: String) {
        note("\(path) write failed: \(name(error)); \(action).")
    }
    /// The log's name for a failed call (`CaptureFault.logName`). Its code is kept for Report a Problem too
    /// (`ProblemReportErrors`: the error's type and case only).
    static func name(_ error: Error) -> String {
        ProblemReportErrors.shared.record(error)
        return CaptureFault.logName(error)
    }
}
