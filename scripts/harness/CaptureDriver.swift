import Foundation
import AppKit
import ApplicationServices
import CryptoKit
import HistoryCore
@testable import MemoryCore
import PrivacyPolicy

// The recording-pipeline session driver (scripts/harness/README.md). It replays a timeline (Timeline.swift) through the
// app's real capture objects, compiled from the CAPTURE source list (scripts/daydream-core-source-checks.py) with the
// headless Coordinator, plus WakeResume.swift: EventCapture (typing, app and window switches, the Chrome page recorder),
// Coordinator, CoreCaptureBinding, the sealed MemoryStore, the summaries worker, WakeResumeMachine and UsageLaunch.
//
// Nothing real is touched: EventCapture.start() is never called (no event tap, no workspace or AX observer), the typing
// proof, the Chrome page answers and the front app come from the timeline, the typing key lives in memory
// (InMemoryTypedKeyStore, never the Keychain), launch counts use in-memory defaults, and every store is a fresh folder
// under the driver's root. A virtual clock (`mono`) runs the typing timers, the wake settle, timed pauses and the
// recorder's half-second heartbeat; the store itself keeps real time (its rows' times are not part of the hash).

/// Launch-count preferences kept in memory only (nothing reaches cfprefsd).
final class HarnessDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: nil)! }
    override func object(forKey k: String) -> Any? { values[k] }
    override func set(_ v: Any?, forKey k: String) { if let v { values[k] = v } else { values.removeValue(forKey: k) } }
    override func removeObject(forKey k: String) { values.removeValue(forKey: k) }
    override func string(forKey k: String) -> String? { values[k] as? String }
    override func bool(forKey k: String) -> Bool { (values[k] as? NSNumber)?.boolValue ?? false }
    override func double(forKey k: String) -> Double { (values[k] as? NSNumber)?.doubleValue ?? 0 }
    override func set(_ v: Double, forKey k: String) { values[k] = v }
    override func set(_ v: Bool, forKey k: String) { values[k] = v }
}

/// What one replay left behind, for the flow checks.
struct ReplayResult {
    /// Every records row in order, without ids, times or revisions (see `CaptureDriver.normalizedRows`).
    let rows: [String]
    /// sha256 of `rows`: two replays of one timeline must print the same.
    let hash: String
    /// Typed rows as a person sees them: (bundle, words, run ordinal, part, seal reason).
    let typed: [(bundle: String, words: String, run: Int, part: Int, seal: String)]
    /// Chrome page rows' titles and sites, in order.
    let pages: [String]
    let pageSites: [String]
    /// usage counts the launches made: app_opened "how", app_updated (from, to).
    let opened: [String]
    let updated: [[String]]
    let recordingAtEnd: Bool
    /// Raw record bodies and hydrated words, for the never-saved checks.
    let raw: String
    let notes: [String]
    /// The carry replay's typed rows (`CaptureDriver.carryReplay`).
    var carry: [(bundle: String, words: String, part: Int, seal: String)] = []
}

final class CaptureDriver {
    static let chrome = "com.google.Chrome"
    let timeline: Timeline
    let root: URL
    /// Where each run keeps its store (a fresh folder under `root`).
    private(set) var home: URL
    private let keys = InMemoryTypedKeyStore()
    let defaults = HarnessDefaults()

    // MARK: virtual clock
    private let monoZero: UInt64 = 10_000_000_000
    private(set) var mono: UInt64 = 10_000_000_000
    var now: Double { Double(mono - monoZero) / 1e9 }
    private var timers: [(at: UInt64, seq: Int, work: () -> Void)] = []
    private var seq = 0
    private var lastActivity = 0.0
    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        seq += 1; timers.append((mono + UInt64(max(0, delay) * 1e9), seq, work))
    }
    /// Runs every timer due up to `offset` in order, with the recorder's 0.5 s heartbeat: every 0.5 s while Chrome is in
    /// front (its page poll counts the ticks) and for 10 s after anything happened, every 15 s in a long quiet stretch
    /// elsewhere (nothing else in 0.1.8 counts heartbeats; the store's own 5 s heartbeat limit is real time, which a
    /// replay never comes near). After each timer, the summaries pass a save asked for runs (`runCommittedSummaries`).
    func advance(to offset: Double) throws {
        let target = monoZero + UInt64((offset * 1e9).rounded())
        guard target >= mono else { throw HarnessError("clock went backwards: \(offset) < \(now)") }
        var fired = 0
        while true {
            let nextTimer = timers.min { ($0.at, $0.seq) < ($1.at, $1.seq) }
            // Chrome in front: every 0.5 s (its page poll counts these ticks).
            let beatGap = now - lastActivity < 10 || frontBundle == Self.chrome ? 0.5 : 15
            let nextBeat = recordingLive ? monoZero + UInt64((((now / beatGap).rounded(.down) + 1) * beatGap * 1e9).rounded()) : UInt64.max
            let due = min(nextTimer?.at ?? .max, nextBeat)
            guard due <= target else { break }
            fired += 1
            guard fired < 200_000 else { throw HarnessError("timers never settled by \(offset)") }
            mono = max(mono, due)
            if let t = nextTimer, t.at == due {
                timers.removeAll { $0.seq == t.seq }
                t.work(); lastActivity = now
            } else { heartbeat() }
            try runCommittedSummaries()
        }
        mono = target
    }

    // MARK: what the Mac shows (made up by the timeline)
    private var frontApp = "", frontBundle = "", window = "w-0", windowTitle = "", field = "field-0", place = ""
    private var chromeTabs: [String: (url: String, title: String)] = [:]
    private var chromeWindows: [String: String] = [:]  // window -> active tab
    private var chromeFront = "cw-1"
    private var lastInput = -1e9
    private var pids: [String: pid_t] = [:]
    /// A pid no real process has (negative), so EventCapture's own snapshot never reads Accessibility.
    private func pid(_ bundle: String) -> pid_t { if let p = pids[bundle] { return p }; let p = pid_t(-(4200 + pids.count)); pids[bundle] = p; return p }

    // MARK: the app's objects
    private(set) var store: MemoryStore?
    private(set) var coordinator: Coordinator?
    private(set) var capture: EventCapture?
    private var running = false, recordingWanted = false, personPaused = false
    private var timedPauseToken = 0
    private var wake = WakeResumeMachine()
    private var locked = false
    private var firstLaunch = true
    private(set) var opened: [String] = [], updated: [[String]] = []
    private(set) var notes: [String] = []
    private var expiry: TypedTextExpiryTimer?
    var recordingLive: Bool { coordinator?.isRunning == true && capture?.isStopped == false }

    init(_ timeline: Timeline, root: URL) {
        self.timeline = timeline; self.root = root
        home = root.appendingPathComponent("store", isDirectory: true)
    }

    static func installSeams() {
        // No OS tap, AX observer or signature read can be made from here, even by a path the replay never meant to take.
        EventCapture.reenableTap = { _ in fatalError("harness: an OS event tap was asked for") }
        EventCapture.remakeTap = { _ in fatalError("harness: an OS event tap was asked for") }
        EventCapture.registerAX = { _, _, _ in fatalError("harness: a live Accessibility observer was asked for") }
        EventCapture.signatureWarm = false
        #if DAYDREAM_OWNER_TYPING
        WebTypingRoute.shared = WebTypingRoute(environment: .init(now: { DispatchTime.now().uptimeNanoseconds }, join: { _, _, _ in .denied(.disabled) },
            schedule: { _, _ in }, secureInput: { false }, pressAndHold: { true }, secondsSinceMouseDown: { nil }, directKeyboardInput: { true }))
        #endif
    }

    // MARK: replay

    func replay() throws -> ReplayResult {
        try timeline.validate()
        for (i, e) in timeline.events.enumerated() {
            try advance(to: e.at)
            lastActivity = now
            do { try apply(e); try runCommittedSummaries() } catch { throw HarnessError("\(timeline.name) event \(i) (\(e.op.rawValue) at \(e.at)): \(error)") }
        }
        // The person stops: the typing timers run out (idle seals, parked units), then whatever is still live is sealed.
        try advance(to: timeline.end + 30)
        if running, let capture, !capture.isStopped { capture.flushNativeText(); try advance(to: timeline.end + 32); capture.resolveParkedTyping(force: true) }
        var result = try read()
        result.carry = try carryReplay()
        if running { stopObjects(reason: "App closed.") }
        timers.removeAll()
        return result
    }

    private func apply(_ e: TimelineEvent) throws {
        if RecordingOracle.inputOps.contains(e.op) { lastInput = e.at }
        switch e.op {
        case .launch: try launch(e)
        case .quit: quit(nextLaunch: nextLaunch(after: e))
        case .record:
            if e.on ?? true { recordingWanted = true; personPaused = false; if !wake.suspended { try startRecording() } }
            else { recordingWanted = false; stopObjects(reason: "Stopped by you. Resume explicitly.") }
        case .front:
            frontApp = e.app ?? ""; frontBundle = e.bundle ?? ""
            if let w = e.window { window = w }
            if let t = e.title { windowTitle = t }
            if frontBundle == Self.chrome { if let w = e.window { chromeFront = w }; pageChanged() }
            field = e.field ?? "field-\(frontBundle)-\(window)"
            place = e.place ?? ""
            guard let capture, !capture.isStopped else { return }
            capture.switchFrontmost(pid: pid(frontBundle), bundle: frontBundle) { _, _ in }
            if frontBundle != Self.chrome {
                coordinator?.record(kind: .appActivated, snapshot: snapshot())
                capture.emitWindowChangeIfNeeded(snapshot())
            }
        case .window:
            if let w = e.window { window = w }
            if let t = e.title { windowTitle = t }
            if let f = e.field { field = f } else { field = "field-\(frontBundle)-\(window)" }
            if frontBundle == Self.chrome, let w = e.window { chromeFront = w; pageChanged() }
            guard let capture, !capture.isStopped else { return }
            capture.handleAX(kAXFocusedWindowChangedNotification as String)
            if frontBundle != Self.chrome { capture.emitWindowChangeIfNeeded(snapshot()) }
        case .tab:
            let w = e.window ?? chromeFront, tab = e.tab ?? "t-1"
            chromeFront = w
            chromeWindows[w] = tab
            chromeTabs[tab] = (e.url ?? "", e.title ?? "")
            if frontBundle == Self.chrome { pageChanged() }
            guard let capture, !capture.isStopped, frontBundle == Self.chrome else { return }
            capture.handleAX(kAXTitleChangedNotification as String)
        case .focus:
            if let f = e.field { field = f }
            if let p = e.place { place = p }
            guard let capture, !capture.isStopped else { return }
            capture.handleAX(kAXFocusedUIElementChangedNotification as String)
        case .type:
            for (i, character) in (e.text ?? "").enumerated() {
                try advance(to: e.keyTimes[i])
                key(String(character), code: character == "\n" ? 36 : 0)
                try runCommittedSummaries()
            }
        case .backspace:
            for t in e.keyTimes { try advance(to: t); key("", code: 51) }
        case .key:
            key(e.key == "tab" ? "\t" : "\r", code: e.key == "tab" ? 48 : 36)
        case .input:
            // A click lands in the app in front: native typing treats it as the edge of what was typed.
            if e.kind == "click", let capture, !capture.isStopped { capture.handlePointerDown(eventAt: mono) }
        case .mic: break  // 0.2.0's sample row; 0.1.8 records nothing for it (the oracles cover it)
        case .sleep:
            runWake(wake.begin(.sleep, wantsRecording: recordingWanted && !personPaused, timedPauseUntil: nil, recorderActive: recordingLive))
        case .lock:
            locked = true
            runWake(wake.begin(.screenLock, wantsRecording: recordingWanted && !personPaused, timedPauseUntil: nil, recorderActive: recordingLive))
        case .wake: runWake(wake.end(.sleep))
        case .unlock: locked = false; runWake(wake.end(.screenLock))
        case .pause:
            personPaused = true
            pauseObjects(reason: "Paused by you")
            if let s = e.seconds {
                timedPauseToken += 1
                let token = timedPauseToken
                schedule(s) { [weak self] in
                    guard let self, self.personPaused, self.timedPauseToken == token, self.running, !self.wake.suspended else { return }
                    self.personPaused = false; try? self.startRecording()
                }
            }
        case .resume:
            personPaused = false; timedPauseToken += 1
            if !wake.suspended { try startRecording() }
        case .hold:
            // The main thread held: nothing runs (no timer, no heartbeat) for `seconds`, in virtual and in real time.
            let s = e.seconds ?? 0
            Thread.sleep(forTimeInterval: s)
            mono += UInt64((s * 1e9).rounded())
        case .writer:
            // The app's summaries pass on its own (its one-minute retry, a launch): the same SummaryWorker, same store.
            if let store { try runSummaries(store) }
        }
    }

    /// How the launch after this quit opens DayDream (nil: no launch follows).
    private func nextLaunch(after e: TimelineEvent) -> String? {
        timeline.events.first { $0.op == .launch && $0.at >= e.at }?.how
    }

    private func key(_ text: String, code: Int64) {
        guard let capture, !capture.isStopped else { return }
        // The words as typed, per field, for the carry replay (`carryReplay`): what each typed row held before the
        // store's scrubber saw it.
        if code == 51 { if !shadow[field, default: ""].isEmpty { shadow[field]!.removeLast() } } else if code == 0 { shadow[field, default: ""] += text }
        capture.handleNativeKey(eventAt: mono, stroke: KeyStroke(keyCode: code)) { text }
    }
    private var shadow: [String: String] = [:]
    /// Typed row id -> the words typed for it; record count -> a summaries pass ran right after that many records.
    private var typedAsTyped: [String: String] = [:]
    private var summariesAfter: [Int] = []
    private var knownRecords = 0
    private func noteNewRows(_ store: MemoryStore) throws {
        let rows = try store.rows("SELECT id, json_extract(body,'$.kind'), json_extract(body,'$.captureProvenance.focusID') FROM records ORDER BY rowid")
        for row in rows.dropFirst(knownRecords) where row[1] == "keyboard.text_input" {
            typedAsTyped[row[0]] = shadow[row[2]] ?? ""
            shadow[row[2]] = ""
        }
        knownRecords = rows.count
    }

    private func snapshot() -> AccessibilitySnapshot {
        AccessibilitySnapshot(focusID: field, app: AppInfo(name: frontApp, bundleIdentifier: frontBundle),
                              window: WindowInfo(title: windowTitle, url: nil), element: ElementInfo(role: "AXTextArea"),
                              secureInput: false, privateBrowsing: false, selectedText: nil, selectedLocation: nil, selectedLength: nil)
    }

    // MARK: launches, recording and suspensions

    private func launch(_ e: TimelineEvent) throws {
        let version = e.version ?? "0.1.8 Beta (20261008120000)"
        if firstLaunch {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try makeHistory(version: version)
        }
        let s = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        // The app's launch for typed words (TypedTextLaunch.wire): the keyring (in memory here), the build 4 settle, the
        // website-row settle, expiry now and every hour after (on the virtual clock).
        TypedTextExpiryTimer.runsOffMain = false
        let keys = self.keys
        expiry = TypedTextLaunch.wire(store: s, keys: { _ in keys }, schedule: { [unowned self] interval, work in
            var live = true
            func again() { self.schedule(interval) { guard live else { return }; work(); again() } }
            again()
            return { live = false }
        }).timer
        store = s
        running = true
        // Launch counts, the app's own rules (UsageReport applies UsageLaunch at launch).
        let kind: UsageLaunch.Kind
        switch e.how ?? "opened" {
        case "login": kind = UsageLaunch.kind(openEvent: true, loginItem: true)
        case "no-open-event": kind = UsageLaunch.kind(openEvent: false, loginItem: false)
        default: kind = UsageLaunch.kind(openEvent: true, loginItem: false)  // Finder/Dock/Spotlight; `open` after a relaunch
        }
        // What the sender would queue: only events UsageCounts allows (UsageSender.add drops the rest).
        if let how = UsageLaunch.launchOpen(kind, selfRelaunch: UsageLaunch.takeSelfRelaunch(defaults)),
           UsageCounts.allowed(UsageEvent("app_opened", ["how": .text(how)])) { opened.append(how) }
        // The build's version as the app reads it (UsageReport.currentVersion: Info.plist's short version and build).
        let current = UsageLaunch.version(short: Self.short(version), build: Self.build(version))
        if let up = UsageLaunch.takeUpdate(defaults, current: current, newInstall: firstLaunch),
           UsageCounts.allowed(UsageEvent("app_updated", ["from_version": .text(up.from), "to_version": .text(up.to)])) { updated.append([up.from, up.to]) }
        firstLaunch = false
        // Recording that was on starts again at launch (the launch intent), unless the person's pause is still on or the
        // screen is locked (the unlock starts it).
        if recordingWanted && !personPaused {
            if locked { _ = wake.begin(.screenLock, wantsRecording: true, timedPauseUntil: nil, recorderActive: false) }
            else { try startRecording() }
        } else { try reopenObjectsStopped() }
    }

    /// "0.1.8 Beta (20261008120000)" as Info.plist holds it: CFBundleShortVersionString "0.1.8 Beta", CFBundleVersion
    /// "20261008120000".
    static func short(_ v: String) -> String? { v.range(of: " (").map { String(v[..<$0.lowerBound]) } }
    static func build(_ v: String) -> String? {
        guard let open = v.range(of: " ("), v.hasSuffix(")") else { return nil }
        return String(v[open.upperBound..<v.index(before: v.endIndex)])
    }

    /// The history as this timeline's install left it before its first launch.
    private func makeHistory(version: String) throws {
        let install = timeline.install ?? TimelineInstall(kind: "fresh")
        let s = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        try s.attachVault(TypedTextVault(keyStore: keys))
        switch install.kind {
        case "fresh":
            // Setup's defaults (owner 9/28: typing and Chrome pages on, opt-out): its Continue turns typing on with the
            // categories as they are (`MemoryStore.turnOnTyping`), and saves Chrome pages on.
            _ = try s.turnOnTyping()
            var p = try s.policy(); p.captureText = true; p.typedConsentVersion = 1
            p.browserPages = true; p.browserPagesConsentVersion = PrivacySettings.browserPagesConsentCurrent
            try s.updatePolicy(p)
        case "upgrade":
            // An earlier build's history: its version ran here, typing was set up, and the person's own choices are on
            // record (nil: never chosen).
            defaults.set(install.from ?? "0.1.7 Beta (20261001120000)", forKey: UsageLaunch.lastRunKey)
            _ = try s.turnOnTyping()
            if let messages = install.messagesAndEmail {
                // The person's choice, saved the way the Messages and email checkbox saves it (rememberMessagesChoice).
                try s.rememberMessagesChoice(messages)
                var typed = try s.typedTextPolicy(); typed.categories.messagesAndEmail = messages
                try s.updateTypedTextPolicy(typed, confirmed: true)
                // Then the typing switch off and on again in Settings (TypingModel.turnOff/turnOn: rememberTypingOff,
                // then turnOnTyping, the one ON path setup and what's-new use too). Bug 13's other side: the ON path's
                // defaults must keep this person's explicit choice, not only a store nothing re-seeds.
                try s.rememberTypingOff()
                _ = try s.turnOnTyping()
            }
            var p = try s.policy(); p.captureText = install.typing ?? true; p.typedConsentVersion = 1
            p.browserPages = true; p.browserPagesConsentVersion = PrivacySettings.browserPagesConsentCurrent
            try s.updatePolicy(p)
        default: throw HarnessError("install kind \(install.kind)")
        }
    }

    /// The app's Coordinator: after every save it runs the summaries pass (`scheduleLegacySummaries`, one at a time).
    /// Here the pass runs as soon as the save that asked for it returns (`runCommittedSummaries`), the same order as
    /// the app's main-queue hop, and always to completion, so a replay is the same every time.
    private func makeCoordinator(_ store: MemoryStore) throws -> Coordinator {
        try Coordinator(store: store, permissions: { true }) { [weak self] in
            guard let self else { return }
            self.summariesWanted = true
        }
    }
    private var summariesWanted = false
    func runCommittedSummaries() throws {
        guard summariesWanted, let store else { return }
        summariesWanted = false
        try runSummaries(store)
    }
    private func runSummaries(_ store: MemoryStore, note: Bool = true) throws {
        if note { try noteNewRows(store); summariesAfter.append(knownRecords) }
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<Int, Error>?
        SummaryWorker(store: store).schedule { outcome = $0; done.signal() }
        guard done.wait(timeout: .now() + 30) == .success else { throw HarnessError("the summaries pass did not finish") }
        if case .failure(let error) = outcome! { notes.append("summaries pass failed: \(error)") }
    }

    /// The recorder's objects for a run that isn't recording (Coordinator only).
    private func reopenObjectsStopped() throws {
        guard let store else { return }
        if coordinator == nil { coordinator = try makeCoordinator(store) }
    }

    /// Start, as the model's startCapture does: Coordinator.start, then a new EventCapture (never started: no tap).
    private func startRecording() throws {
        guard running, let store else { return }
        capture?.stop(reason: "Replacing stopped capture"); capture = nil
        let c = try coordinator ?? makeCoordinator(store)
        coordinator = c
        c.captureText = try store.policy().captureText
        c.captureBinding.wallClock = { Date() }
        try c.start(permitted: true)
        let next = EventCapture(coordinator: c, typingEnvironment: typingEnvironment(), pageEnvironment: pageEnvironment())
        capture = next
        NativeTypingRoute.keyFocus = { 4242 }
        NativeTypingRoute.bundleOf = { [weak self] _ in self?.frontBundle ?? "" }
        // The app in front as recording starts (EventCapture.start records it the same way).
        if frontBundle == Self.chrome { pageChanged() }
        if !frontBundle.isEmpty {
            next.switchFrontmost(pid: pid(frontBundle), bundle: frontBundle) { _, _ in }
            if frontBundle != Self.chrome { c.record(kind: .appActivated, snapshot: snapshot()); next.emitWindowChangeIfNeeded(snapshot()) }
        }
    }

    /// The model's pauseCapture with typing committed first (the person's pause, a suspension, quit).
    private func pauseObjects(reason: String) {
        guard let capture, !capture.isStopped else { coordinator?.pause(reason); return }
        var done = false
        capture.finishPendingTyping { done = true }
        if !done { capture.commitPendingTyping() }
        coordinator?.pause(reason)
        capture.stop(reason: reason)
        self.capture = nil
    }
    private func stopObjects(reason: String) {
        pauseObjects(reason: reason)
        coordinator?.stop()
    }

    private func quit(nextLaunch: String?) {
        // DayDream's own restarts leave their one-use mark just before they quit (UsageLaunch.markSelfRelaunch).
        if nextLaunch == "self-relaunch" || nextLaunch == "update-relaunch" { UsageLaunch.markSelfRelaunch(defaults) }
        stopObjects(reason: "App closed.")
        expiry?.stop(); expiry = nil
        coordinator = nil; store = nil; running = false
        timers.removeAll()
        wake = WakeResumeMachine()
    }

    private func runWake(_ effects: [WakeResumeMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .pause(let suspension): pauseObjects(reason: suspension.pauseReason)
            case .settle(let delay, let token):
                schedule(delay) { [weak self] in
                    guard let self else { return }
                    self.runWake(self.wake.settled(token: token, screenLocked: self.locked, onConsole: true, now: Date()))
                }
            case .start, .resumeTimedPause:
                var ok = false
                do { try startRecording(); ok = recordingLive } catch { notes.append("wake start failed: \(error)") }
                runWake(wake.started(succeeded: ok, cause: ok ? .other : .storage, resumeTitle: "Resume"))
            case .notify(let notice): notes.append("notice: \(notice.body)")
            case .retryStorage: notes.append("storage retry")
            }
        }
    }

    /// The recorder's half-second timer (EventCapture.start's control timer body).
    private func heartbeat() {
        guard let coordinator, let capture, !capture.isStopped else { return }
        coordinator.reconcileResume()
        if !coordinator.isRunning { capture.stop(reason: "Recording stopped") } else { capture.pages.tick() }
    }

    private func typingEnvironment() -> EventCapture.TypingEnvironment {
        EventCapture.TypingEnvironment(now: { [unowned self] in self.mono }, proof: { [unowned self] generation, version in
            // Production reads no native typing proof for Chrome (website typing is its own route).
            guard self.frontBundle != Self.chrome, !self.frontBundle.isEmpty else { return nil }
            var p = FocusProof(); p.generation = generation; p.policyVersion = version; p.checkedAt = self.mono
            p.bundle = self.frontBundle; p.windowID = self.window; p.focusID = self.field; p.role = "AXTextArea"; p.place = self.place
            p.surface = .native; p.secureInput = .no; p.privateMode = .no
            p.verified = true; p.fieldStateVerified = true; p.frameAccessible = true; p.navigationStable = true
            return p
        }, schedule: { [unowned self] d, w in self.schedule(d, w) }, secureInput: { false },
        departure: { [unowned self] in DepartureState(secureInput: .no, bundle: self.frontBundle, focusSecure: .no) }, pressAndHold: { true })
    }

    /// Chrome as the timeline draws it: one verified Chrome, Automation allowed, the front window's active tab.
    ///
    /// Its clock (README "The Chrome page clock"): the page tracker measures dwell with it (a read and its confirm 1.2 s
    /// later must be at least 1 s apart), while the Coordinator stamps the row with real time and the store keeps a
    /// page row only when its read is at most 1 s old and at most 0.1 s ahead (BrowserSafety.fresh). The replay runs
    /// far faster than real time, so the page clock is real time plus a skew that follows the virtual clock from the
    /// first read of the page now in front: 0.98 s behind at that read, 1.02 s later (0.04 s ahead) by its confirm,
    /// and no further. So it steps back about a second when another page is first read, every window read waits the
    /// recorder's 1.5 s gap, and a page seen again in the same tab is never judged flicker. The flows space page
    /// changes 3 s or more apart and never come back to a page within 10 s.
    private var pageAnchor = 0.0, pageKey = ""
    private func pageRead(_ key: String) { if key != pageKey { pageKey = key; pageAnchor = now } }
    private func pageChanged() {}
    private func pageClock() -> Date { Date().addingTimeInterval(min(max(now - pageAnchor, 0), 1.2) * 0.85 - 0.98) }

    private func pageEnvironment() -> ChromePageEnvironment {
        ChromePageEnvironment(
            frontmost: { [unowned self] in
                guard !self.frontBundle.isEmpty else { return nil }
                return (self.pid(self.frontBundle), self.frontBundle, "\(self.pid(self.frontBundle)):1:\(self.frontBundle)", self.frontApp)
            },
            instances: { 1 }, secureInput: { false }, verify: { _, _ in true }, permission: { _ in noErr },
            transport: { [unowned self] _ in { request in
                switch request {
                case .windowIDs: return .ids([self.chromeFront] + self.chromeWindows.keys.filter { $0 != self.chromeFront }.sorted())
                case .mode: return .text("normal")
                case .activeTabID(let w): return self.chromeWindows[w].map { .text($0) }
                case .tabURL(_, let t): self.pageRead(t + " " + (self.chromeTabs[t]?.url ?? "")); return self.chromeTabs[t].map { .text($0.url) }
                case .tabTitle(_, let t): return self.chromeTabs[t].map { .text($0.title) }
                }
            } },
            background: { $0() }, main: { $0() },
            schedule: { [unowned self] d, w in self.schedule(d, w) },
            now: { [unowned self] in self.pageClock() },
            idleSeconds: { [unowned self] in self.now - self.lastInput })
    }

    // MARK: read back

    /// Field names that differ between two replays of one timeline (ids, times, revisions, keys made per store).
    static let volatile: Set<String> = ["id", "at", "checkedAt", "revision", "policyRevision", "generation", "captureEpoch", "epoch", "startedAt",
                                        "typed", "sealedAt", "createdAt", "documentID", "sessionID", "recipientRef"]
    private var runOrdinals: [String: Int] = [:]
    private static let uuid = try! NSRegularExpression(pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
    private var uuidOrdinals: [String: Int] = [:]
    /// Made-per-run identifiers (UUIDs: run, page, field ids) become their order of first appearance.
    private func renumber(_ s: String) -> String {
        var out = s
        for m in Self.uuid.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            let r = Range(m.range, in: s)!, key = s[r].uppercased()
            if uuidOrdinals[key] == nil { uuidOrdinals[key] = uuidOrdinals.count + 1 }
            out.replaceSubrange(Range(m.range, in: out)!, with: "uuid-\(uuidOrdinals[key]!)")
        }
        return out
    }
    private func normalize(_ value: Any) -> Any {
        if let d = value as? [String: Any] {
            var out: [String: Any] = [:]
            for k in d.keys.sorted() where !Self.volatile.contains(k) {
                let v = d[k]!
                if k == "runID", let s = v as? String { if runOrdinals[s] == nil { runOrdinals[s] = runOrdinals.count + 1 }; out[k] = "run-\(runOrdinals[s]!)" }
                else { out[k] = normalize(v) }
            }
            return out
        }
        if let a = value as? [Any] { return a.map(normalize) }
        if let s = value as? String { return renumber(s) }
        return value
    }

    /// The carry replay (bug 8; README "The pasted fact"). 0.1.8's binding writes `pasted: nil` for a unit with no paste
    /// while the store's certified carry asks for `pasted == false`, so in real capture no carry ever forms (the RC
    /// finding this package pins). To still check what bug 8 broke, the summaries pass dropping the carry between two
    /// parts, this re-saves the replay's own records into a fresh store in the same order, the typed ones with the words
    /// as typed and that one fact as false, and runs the summaries pass exactly where the replay ran it.
    func carryReplay() throws -> [(bundle: String, words: String, part: Int, seal: String)] {
        guard let source = store ?? (try? MemoryStore(home: home, writable: false, automaticallySyncSearch: false)) else { throw HarnessError("no store") }
        if store != nil { try noteNewRows(source) }
        let target = try MemoryStore(home: root.appendingPathComponent("carry", isDirectory: true), writable: true, automaticallySyncSearch: false)
        var settings = try target.policy(); settings.captureText = true; settings.typedConsentVersion = 1; try target.updatePolicy(settings)
        try target.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore())); try target.setUpTypedVault()
        _ = try target.acceptSafeTyping(); _ = try target.settleLegacyTypedText()
        try target.setCaptureState("recording", reason: "Flow carry replay")
        let revision = try target.policy().revision
        for (i, id) in try source.rows("SELECT id FROM records ORDER BY rowid").map({ $0[0] }).enumerated() {
            guard var e = try source.read(id)?.evidence else { continue }
            let now = Date()
            if e.kind == "keyboard.text_input" {
                e.text = try typedAsTyped[id] ?? source.hydrateTypedText(id, disclosure: .owner) ?? ""
                e.typed = nil; e.at = iso(now)
                if var p = e.captureProvenance {
                    p.policyRevision = revision; p.classifierVersion = UnitClassifier.version; p.checkedAt = iso(now)
                    if var u = p.unit { u.pasted = false; u.withheld = 0; u.keys = e.text.count; u.edits = 0; p.unit = u }
                    e.captureProvenance = p
                }
                _ = try target.ingest(e, now: now, expectedPolicyRevision: revision, requireRecording: true)
            } else { _ = try? target.ingest(e, now: now) }
            if summariesAfter.contains(i + 1) { try runSummaries(target, note: false) }
        }
        return try target.rows("SELECT id FROM records WHERE json_extract(body,'$.kind')='keyboard.text_input' ORDER BY rowid").map { row in
            let e = try target.read(row[0])?.evidence, u = e?.captureProvenance?.unit
            return (e?.bundle ?? "", try target.hydrateTypedText(row[0], disclosure: .owner) ?? "<none>", u?.part ?? 0, u?.sealReason ?? "")
        }
    }

    func read() throws -> ReplayResult {
        guard let store = store ?? (try? MemoryStore(home: home, writable: false, automaticallySyncSearch: false)) else { throw HarnessError("no store") }
        runOrdinals = [:]; uuidOrdinals = [:]
        var rows: [String] = [], typed: [(String, String, Int, Int, String)] = [], pages: [String] = [], pageSites: [String] = [], raw: [String] = []
        for row in try store.rows("SELECT id, body FROM records ORDER BY rowid") {
            let id = row[0], body = row[1]
            raw.append(body)
            guard let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { continue }
            var normalized = normalize(object) as! [String: Any]
            if object["kind"] as? String == "keyboard.text_input" {
                // The words as the app reads them back; a row its own read hides is "<unreadable>".
                let words = try store.hydrateTypedText(id, disclosure: .owner) ?? (try store.read(id) == nil ? "<unreadable>" : "<none>")
                normalized["words"] = words
                raw.append(words)
                let unit = (object["captureProvenance"] as? [String: Any])?["unit"] as? [String: Any]
                typed.append((object["bundle"] as? String ?? "", words, runOrdinals[unit?["runID"] as? String ?? ""] ?? 0,
                              unit?["part"] as? Int ?? 0, unit?["sealReason"] as? String ?? ""))
            }
            if object["bundle"] as? String == Self.chrome, object["kind"] as? String == "window.changed" {
                pages.append(object["title"] as? String ?? ""); pageSites.append(object["url"] as? String ?? "")
            }
            rows.append(String(decoding: try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]), as: UTF8.self))
        }
        let digest = SHA256.hash(data: Data(rows.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        return ReplayResult(rows: rows, hash: digest, typed: typed.map { (bundle: $0.0, words: $0.1, run: $0.2, part: $0.3, seal: $0.4) }, pages: pages, pageSites: pageSites,
                            opened: opened, updated: updated, recordingAtEnd: recordingLive, raw: raw.joined(separator: "\n"), notes: notes)
    }
}
