#if DAYDREAM_OWNER_TYPING
import AppKit
import Carbon
import CoreGraphics
import Foundation
import MemoryCore
import PrivacyPolicy

/// Owner build only: website typing through the Chrome join (typing-all
/// SPEC-LATER 4.2, owner decision 3). EventCapture hands every key to
/// `handle` first. A key in Google Chrome is taken here only while recording,
/// typing and "Web pages in Chrome" are on and the typing policy allows typed
/// text; every check before the join reads nothing from the OS. The words are
/// kept by `BrowserTypingBurst` (a `TypingSession` with `WebTypingGate`). In
/// the synchronous design (the default) a key is read only after a fresh join
/// proved a normal-window text field on a site the person allows, with no
/// Incognito or Guest window open. In the QF-17 bracketed design (prototype;
/// needs the privacy reviewer's approval of the diff) a key's characters may be
/// held in memory, unproven, in an owned buffer for at most its bracket (64 keys,
/// 1 s), only while a read that started before the key is running, no quiet
/// period or refusal hold is on, secure input is off and Chrome is frontmost with
/// the key-time focus refs of the last verified read; nothing is written, logged
/// or counted per key before proof, and they reach the typing session only when
/// verified reads bracket the key (`ChromeBracketEngine`).
///
/// Boundaries it sees without any other EventCapture hook:
/// - privacy boundaries (pause, typing off, policy or consent change, secure
///   input, excluded apps, faults): EventCapture invalidates its binding,
///   which moves the binding's generation; any change drops everything here
///   before the next key or timer does anything;
/// - a mouse button going down (capture's event tap, `TypingPointer`): the
///   unfinished text is saved at once, if a click join proves the page and
///   window list it was typed in are unchanged (`BrowserTypingBurst.pointerDown`),
///   so a click on Send, Post or another field doesn't lose it;
/// - a mouse button pressed since the last key (the OS's idle clock, no
///   permission): a pointer boundary, like native typing's click;
/// - a key in another app: the unfinished website text is dropped, because
///   it can be saved only while a fresh join finds its field;
/// - a change of keyboard input source (`TypingInputSource`, from capture's
///   observer): the unfinished text is sealed, as native typing seals its unit;
/// - a key capture dropped as late, unread (`TypingKeyGap`): the unfinished
///   text is sealed, so a later key never joins it across the missing one;
/// - a chorded Return (Command-Return sends in many web apps): the unfinished
///   text is saved at once, like a click;
/// - Tab: the unfinished text is parked, and after the settle it is saved if
///   focus is in another text field of the same page or on something there
///   that isn't a text field and isn't secure (`BrowserTypingBurst.resolveParked`).
///   A password field after it drops it, as in native typing.
///
/// The Post gesture (fix/chrome-capture, `BrowserSubmitGesture`): the rows a
/// composer's words were saved in are marked submitted (`sendBy` "button")
/// only when a plain left press proven on that composer's own Post or Reply
/// button (a click join, then the witness's hit test) is released on it.
/// Anything else leaves them drafts. It never says the post was published.
///
/// Diagnostics (fix/chrome-capture, opt-in, `CaptureDiagnostics`): counts of
/// why keys were not taken, each join's answer and time, what ended each
/// piece and what the write and the store said. Never a key or a word.
///
/// Native typing's direct-keyboard rule applies here too (review F3): while
/// the input source is not the US, ABC or British layout, a key is unproven
/// (`.inputMethod`) before any join read, so text an input method composes
/// (Japanese, Chinese, Korean) is never read or saved.
final class WebTypingRoute {
    struct Environment {
        var now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
        var wall: () -> Date = { Date() }
        /// One full join against the Chrome `pid`. Called only after every
        /// check before it passed, on the route's executor (`executor`; main without one).
        var join: (_ pid: pid_t, _ sites: BrowserTypingSiteRules, _ enabled: @escaping () -> Bool) -> BrowserTypingJoinResult
        /// The click join (`anyFocus`): the same checks, with focus anywhere
        /// in the page. Called only at a click, a chorded Return and the
        /// settle (right after a full join denied `.field`), on the route's executor.
        var pointerJoin: (_ pid: pid_t, _ sites: BrowserTypingSiteRules, _ enabled: @escaping () -> Bool) -> BrowserTypingJoinResult = { _, _, _ in .denied(.notFocused) }
        /// The light per-key check (`BrowserTypingJoin.light`) of the field
        /// the last full join allowed; nil takes the full join. Called only for
        /// a typed, deleted or accented key of an open burst, on the route's executor.
        var light: (_ pid: pid_t, _ sites: BrowserTypingSiteRules, _ enabled: @escaping () -> Bool) -> BrowserTypingJoinResult? = { _, _, _ in nil }
        /// Codex 07:10 (field hold): whether focus is still in the box the last full join refused as `field`
        /// (`BrowserTypingJoin.holdsRefusedBox`: which app, window and element have focus, nothing else). true only
        /// drops the key unread; false: the full join decides. Called only for a plain key of a held burst.
        var fieldHeld: (_ pid: pid_t) -> Bool? = { _ in nil }
        /// Runs work after a delay in seconds on this (main) executor.
        var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
        var secureInput: () -> Bool = { MainInputFacts.secureInput() }   // claude/crashguard-015: main queue only
        var pressAndHold: () -> Bool = { UserDefaults.standard.object(forKey: "ApplePressAndHoldEnabled") as? Bool ?? true }
        /// Seconds since any mouse button last went down (nil: unknown).
        var secondsSinceMouseDown: () -> Double? = {
            [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown]
                .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min()
        }
        /// Native typing's rule: the keyboard input source is a direct layout
        /// (US, ABC or British), so each key is the character it types.
        var directKeyboardInput: () -> Bool = { AccessibilityReader.keyboardInputIsDirect() }
        /// The Post check (`BrowserTypingJoin.submitControl`) at a global point, right after a click join proved
        /// `page`. Called only for a plain left press after rows a click may mark, on the route's executor.
        var submitControl: (_ pid: pid_t, _ x: Double, _ y: Double, _ page: BrowserTypingJoinProof, _ focusID: String, _ names: Set<String>,
                            _ enabled: @escaping () -> Bool) -> Result<BrowserSubmitPress, BrowserSubmitDenial> = { _, _, _, _, _, _, _ in .failure(.noField) }
        /// claude/int-1003 (compose-send/v1): the composer the last full join proved, read again after a Return or
        /// Command-Return (`ChromeTypingWitness.composeSnapshot`). nil: not read (nothing is confirmed). On the route's executor.
        var composeSnapshot: (_ pid: pid_t) -> BrowserComposeSnapshot? = { _ in nil }
        /// claude/xtyping-1005: wakes Chrome's accessibility (`ChromeTypingWitness.wake`); true when it woke it. Called
        /// only when Chrome comes to the front (`chromeInFront`), on the route's executor.
        var wake: (_ pid: pid_t, _ enabled: @escaping () -> Bool) -> Bool = { _, _ in false }
        // ---- QF-17 bracketed design (prototype). Unused by the synchronous design. ----
        /// Which join design this route runs (`ChromeJoinDesign.current` when the environment is made).
        var design: ChromeJoinDesign = ChromeJoinDesign.current
        /// Codex QF-1 prototype. Default off; requires a privacy review before use.
        /// Has no effect in the synchronous design.
        var recoverBracketedBoundaries = false
        /// Runs one read off the main thread (production: the witness's serial queue, the only place join state
        /// lives: M4). nil: `schedule(0, …)`, so a harness drives reads on its own clock.
        var background: ((@escaping () -> Void) -> Void)? = nil
        /// Posts a read's result to the main thread. nil: `schedule(0, …)`.
        var toMain: ((@escaping () -> Void) -> Void)? = nil
        /// B2: key-time identity, on main. nil (not wired): unavailable, so every key is discarded (fail closed).
        var keyIdentity: ((_ pid: pid_t) -> ChromeKeyIdentity?)? = nil
        /// QF-17 bracketed field hold (Codex 07:10, as `fieldHeld` in the synchronous design): the box the read just
        /// finished refused as `field` after a completed scan (`BrowserTypingJoin.refusedBoxRefs`), as refs. Called on
        /// the read's own executor right after a full read denied `field`; nil: no hold.
        var refusedBox: ((_ pid: pid_t) -> (window: ChromeRef, focus: ChromeRef)?)? = nil
        /// B3 barrier: the uptime of the OS's latest mouse-down or key-down (its idle clock; no permission). nil: unknown.
        var latestInput: (() -> UInt64?)? = nil
        /// The frontmost app's PID without any Accessibility read (a click starts reads only in Chrome). nil: unknown.
        var frontmostPID: (() -> pid_t?)? = nil
        /// PM2: the system-focused app's PID, when the key's caller didn't read it (`NativeTypingRoute.keyFocus`,
        /// which checks substitute). Read on main only for a key that already passed the freshness gate.
        var systemFocus: () -> pid_t? = { NativeTypingRoute.keyFocus() }
        /// claude/chrome-offmain-1003 (PERF-1003 risk 1): the synchronous design's one serial executor off the main
        /// thread, where the route keeps all its state and does all its work, its joins and per-key checks included
        /// (`TypingKeyHandoff`). nil: everything runs on the caller, the main thread, as before (checks, the bracketed
        /// design, and the `TypingKeyHandoff.onMainDefaultsKey` way back).
        var executor: TypingRouteExecutor? = nil
        static var live: Environment {
            // QF-17: the one place the design is chosen; the route and the witness both take it from here.
            let design = ChromeJoinDesign.current
            let witness = ChromeTypingWitness(design: design)
            var env = Environment(join: { pid, sites, enabled in
                witness.read(pid: pid, enabled: enabled, blockList: sites.blockList, alwaysBlocked: sites.alwaysBlocked, sites: sites.permits(url:),
                             field: sites.permits(url:field:))
            }, pointerJoin: { pid, sites, enabled in
                witness.read(pid: pid, enabled: enabled, blockList: sites.blockList, alwaysBlocked: sites.alwaysBlocked, sites: sites.permits(url:),
                             anyFocus: true)
            }, light: { pid, sites, enabled in
                witness.light(pid: pid, enabled: enabled, blockList: sites.blockList, alwaysBlocked: sites.alwaysBlocked, sites: sites.permits(url:),
                              field: sites.permits(url:field:))
            }, fieldHeld: { pid in
                witness.holdsRefusedBox(pid: pid)
            }, submitControl: { pid, x, y, page, focusID, names, enabled in
                witness.submitControl(pid: pid, x: x, y: y, page: page, focusID: focusID, names: names, enabled: enabled)
            })
            env.composeSnapshot = { pid in witness.composeSnapshot(pid: pid) }
            env.wake = { pid, enabled in witness.wake(pid: pid, enabled: enabled) }
            env.design = design
            // QF-17: reads run on the witness's own serial queue (the one instance that holds all join state: M4).
            env.background = { work in witness.queue.async(execute: work) }
            env.toMain = { work in DispatchQueue.main.async(execute: work) }
            let identity = ChromeTypingWitness.KeyIdentityReader()
            env.keyIdentity = { pid in identity.read(pid: pid) }
            env.refusedBox = { pid in witness.refusedBoxRefs(pid: pid) }
            env.latestInput = {
                let since = [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
                    .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min()
                guard let since, since >= 0, since < 3600 else { return nil }
                let now = DispatchTime.now().uptimeNanoseconds
                return now &- UInt64(since * 1_000_000_000)
            }
            env.frontmostPID = { MainInputFacts.frontmostPID() }
            // claude/chrome-offmain-1003: the synchronous design runs on its own executor (owner builds; the bracketed
            // design keeps its own read loop and stays on main). The witness's reads, the timers and the stop's one
            // bounded join run there; the keyboard input source is read on main for each key and kept for it.
            if design == .synchronous, TypingKeyHandoff.offMainEnabled {
                let executor = TypingRouteExecutor()
                witness.executor = executor
                env.executor = executor
                env.schedule = { delay, work in executor.after(delay, work) }
                env.toMain = nil
                let direct = env.directKeyboardInput, memory = DirectInputMemory()
                env.directKeyboardInput = { memory.read(direct) }
            }
            return env
        }
    }

    /// Website typing's own soft split: a short pause commits while Chrome is
    /// still in front, because a unit left behind can't be saved later
    /// without a fresh join of its field.
    static let limits: TypingLimits = {
        var l = TypingLimits()
        l.idleClosed = 2_000_000_000
        l.idleWord = 4_000_000_000
        l.idleOpen = 4_000_000_000
        l.idleSendFloor = 0
        // fix/public-web-typing: a secret cut by the 4 s pause ("the passphrase is corre", a pause, "ct horse
        // battery staple") latches Chrome, and the latch must outlast the pause, or after it only the first token
        // of the next piece is withheld and the rest of the secret is saved. Native typing splits such a tail
        // after 60 s and its latch runs 30 s more; 90 s here keeps websites at least as long (typed-secret-fuzz,
        // website limits). Return or Tab in Chrome still ends the latch at once.
        l.latchExpiry = 90_000_000_000
        return l
    }()

    static var shared = WebTypingRoute(environment: .live)

    /// EventCapture's one call. true: the key was Chrome's and was handled
    /// here (typed, dropped or a boundary); false: it goes on to native typing.
    @inline(never) static func handle(eventAt: UInt64, stroke: KeyStroke, bundle: String, pid: pid_t?, coordinator: Coordinator,
                                      keyFocus: pid_t?? = .none, acquire: () throws -> String) -> Bool {
        shared.intake(eventAt: eventAt, stroke: stroke, bundle: bundle, pid: pid, coordinator: coordinator, keyFocus: keyFocus, acquire: acquire)
    }

    /// claude/chrome-offmain-1003: capture's key, on the main thread. With no executor it is handled right here, as
    /// before. Otherwise only `handle`'s answer is worked out here, from the same reads `handle` makes before any join
    /// (Chrome, recording, typing, "Web pages in Chrome", the typing policy and the site choices: `activeRead`), and
    /// the keyboard input source is read for the key (`DirectInputMemory`). The key itself is handled on the executor,
    /// in order with everything else the route was given:
    /// - a key website typing takes is handed back to the tap thread waiting on it (`TypingKeyHandoff`), which runs
    ///   it on the executor, with the key's characters, before it takes its next event; with no tap thread waiting
    ///   (a caller on main itself), it is run on the executor while this thread waits, as it waited before;
    /// - any other key (another app's, or Chrome's while website typing is off) is queued: it reads no characters.
    func intake(eventAt: UInt64, stroke: KeyStroke, bundle: String, pid: pid_t?, coordinator: Coordinator,
                keyFocus: pid_t?? = .none, acquire: () throws -> String) -> Bool {
        guard let executor = environment.executor, !executor.isCurrent else {
            return handle(eventAt: eventAt, stroke: stroke, bundle: bundle, pid: pid, coordinator: coordinator, keyFocus: keyFocus, acquire: acquire)
        }
        let chrome = bundle == WebTypingGate.bundle && pid != nil
        // The input source, for this key's join (Chrome keys only: a key in another app reads nothing here).
        if chrome { _ = environment.directKeyboardInput() }
        // claude/crashguard-015: and secure input and the frontmost app, read here on the main queue for the executor.
        if chrome { MainInputFacts.refresh() }
        let read = chrome ? Self.activeRead(coordinator) : nil
        let work: TypingKeyHandoff.Work = { [self] characters in
            decided = .some(read)
            defer { decided = nil }
            _ = handle(eventAt: eventAt, stroke: stroke, bundle: bundle, pid: pid, coordinator: coordinator, keyFocus: keyFocus, acquire: characters)
        }
        // Not taken: `handle` returns before the join (another app's key, or `active` finds `read` nil): no characters.
        guard chrome, read != nil else { executor.async { work { "" } }; return false }
        if TypingKeyHandoff.offer({ characters in executor.sync { work(characters) } }) { return true }
        executor.sync { work(acquire) }
        return true
    }
    /// claude/chrome-offmain-1003: an entry point called from the main thread (capture's events and listeners, page
    /// history's reads) when the route has an executor: `work` (the same call) is queued there, in the order called,
    /// and true is returned. false: already on the route's executor, or no executor (run it here, as before).
    private func elsewhere(_ work: @escaping () -> Void) -> Bool {
        guard let executor = environment.executor, !executor.isCurrent else { return false }
        executor.async(work)
        return true
    }
    /// claude/chrome-offmain-1003: a failed write's report to the coordinator, whose recorder state belongs to the main
    /// thread: posted there from the executor, judged by whether it was recording when it failed.
    private func failed(_ coordinator: Coordinator, _ error: Error) {
        guard environment.executor?.isCurrent == true else { coordinator.captureFailed(error); return }
        let recording = coordinator.session.state == "recording"
        DispatchQueue.main.async { coordinator.captureFailed(error, recording: recording) }
    }

    let environment: Environment
    private(set) var burst: BrowserTypingBurst
    private let sites: BrowserTypingSiteRules
    private var keyMap = TypingKeyMap()
    /// summaries/v3: marks the unit a paste sealed and the next one in the same field (send facts, `pasted`).
    private let pastes = PasteMemory()
    /// fix/typing-e2e: webmail's To-field name for the email units after it in the same tab (as Mail's, `RecipientMemory`).
    private let recipients = RecipientMemory()
    private weak var coordinator: Coordinator?
    private var pid: pid_t?
    /// The binding generation and policy version the pending text was typed under.
    private var watched: (generation: UInt64, version: UInt64)?
    private var lastKeyAt: UInt64?
    private var idleEpoch: UInt64 = 0, settleEpoch: UInt64 = 0, housekeepingEpoch: UInt64 = 0
    private var idleAt: UInt64?, settleAt: UInt64?, housekeepingAt: UInt64?
    /// Rows written (checks and diagnostics; never the words).
    private(set) var written = 0
    /// fix/chrome-x2 (searches): the last search a page read saved for a tab, and searches the join saved from a page's
    /// own box in the last `searchRepeatSeconds` (so a search typed there is not saved twice). Memory only.
    private var lastSearch: (tabID: String, engine: String, query: String)?
    private var typedSearches: [(host: String, query: String, at: Date)] = []
    /// Searches saved from a results page's address in the last `searchRepeatSeconds`: the same search typed in the page's
    /// box and saved after it (a send judged at the settle) is not saved twice. Memory only.
    private var urlSearches: [(host: String, query: String, at: Date)] = []
    static let searchRepeatSeconds: TimeInterval = 120
    static func searchKey(_ q: String) -> String { q.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
    /// fix/chrome-capture: the rows a Post click may mark, and a press proven on a Post button until it comes up.
    let submit = BrowserSubmitTracker()
    /// Rows a proven Post click marked (checks; never the words).
    private(set) var marked = 0
    private var diagnostics: CaptureDiagnostics { CaptureDiagnostics.shared }
    /// Diagnostics only: whether the last full or click join allowed typing (B5-1).
    private var lastJoinAllowed = true
    /// claude/int-1003 (compose-send/v1): the last allowed join's proof (memory only), for the compose signals of the
    /// rows written from it (`BrowserComposeSignals.submit`: the page title, route kind and reply phrases it already read).
    private var composeProof: BrowserTypingJoinProof?
    /// Re-reads after a gesture in progress, by row; a key typed after the gesture ends them.
    private var composeEpoch: UInt64 = 0

    /// An ordinary user Stop/pause freezes intake, then gives existing admitted
    /// text one bounded opportunity to obtain a fresh proof. Privacy stops never
    /// call this API. The deadline is independent of a blocked background read.
    private struct Finish {
        let id: UUID, epoch: UInt64, generation: UInt64
        let revision: String
        let cutoff: UInt64, deadline: UInt64
        let completion: () -> Void
    }
    private var finishing: Finish?
    private var finishWriteID: UUID?

    func finishPending(coordinator: Coordinator, completion: @escaping () -> Void) {
        // claude/chrome-offmain-1003: decided on the executor while main waits (work there never waits on main, so this
        // can't deadlock; it waits at most for a key's join already under way). The completion is capture's: with
        // nothing to save it runs here, before this returns, as it did on main; after a finish's join it is posted to
        // the main thread.
        if let executor = environment.executor, !executor.isCurrent {
            _ = environment.directKeyboardInput()
            MainInputFacts.refresh()   // claude/crashguard-015
            let lock = NSLock()
            var deciding = true, done = false
            executor.sync {
                self.finishPending(coordinator: coordinator) {
                    lock.lock(); let now = deciding; if now { done = true }; lock.unlock()
                    if !now { DispatchQueue.main.async(execute: completion) }
                }
            }
            lock.lock(); deciding = false; let call = done; lock.unlock()
            if call { completion() }
            return
        }
        guard finishing == nil else { return }
        guard let a = active(coordinator), let pid, !environment.secureInput(),
              environment.directKeyboardInput(), burst.session.hasLive || burst.session.parkedCount > 0 || !held.isEmpty else {
            drop(.focus); completion(); return
        }
        self.coordinator = coordinator
        let cutoff = environment.now()
        let finish = Finish(id: UUID(), epoch: control.epoch, generation: a.context.generation,
                            revision: a.context.revision, cutoff: cutoff,
                            deadline: cutoff &+ BrowserTypingTiming.proofTTLNanoseconds, completion: completion)
        finishing = finish
        submit.clear()
        idleEpoch &+= 1; settleEpoch &+= 1; housekeepingEpoch &+= 1
        idleAt = nil; settleAt = nil; housekeepingAt = nil
        environment.schedule(Double(BrowserTypingTiming.proofTTLNanoseconds) / 1e9) { [weak self] in
            self?.finishEnded(finish.id)
        }
        if environment.design == .bracketed {
            control.setEnabled(true); control.extend(until: finish.deadline)
            enqueue(Op(.finish(finish.id), at: cutoff)); return
        }
        // The synchronous witness owns all reads/invalidation on the route's executor (main without one). Schedule
        // one bounded join there; never wait on main for a background result.
        let env = environment
        let snapshot = BrowserTypingSiteRules(choices: sites.choices, alwaysBlocked: sites.alwaysBlocked,
                                             blockList: sites.blockList, expanded: sites.expanded)
        let main = env.toMain ?? { work in env.schedule(0, work) }
        let enabled: () -> Bool = { [weak coordinator] in
            guard let coordinator, env.now() <= finish.deadline else { return false }
            guard coordinator.isRunning, coordinator.captureText, coordinator.allowsApp(WebTypingGate.bundle),
                  let current = try? coordinator.captureBinding.context() else { return false }
            return current.generation == finish.generation && current.revision == finish.revision
        }
        main { [weak self] in
            guard let self, self.finishAuthority(finish) else { return }
            let full = self.settled(env.join(pid, snapshot, enabled), anchor: finish.cutoff)
            guard self.finishAuthority(finish) else { return }
            let page = full.denial == .field
                ? self.settled(env.pointerJoin(pid, snapshot, enabled), anchor: finish.cutoff) : nil
            guard self.finishAuthority(finish), let a = self.active(coordinator) else { return }
            self.saveFinish(full, page: page, a: a, finish: finish)
        }
    }

    /// Checked again inside the only write closure, immediately before storage.
    private func finishAuthority(_ f: Finish) -> Bool {
        // active can invalidate this finish and invoke its completion. Take its
        // snapshot first, then test the token/epoch again after those effects.
        guard let a = active(coordinator) else { return false }
        return finishing?.id == f.id && control.epoch == f.epoch
            && environment.now() <= f.deadline && !environment.secureInput()
            && environment.directKeyboardInput() && environment.frontmostPID?() == pid
            && a.coordinator.isRunning && a.context.generation == f.generation
            && a.context.revision == f.revision
    }

    private func saveFinish(_ full: BrowserTypingJoinResult?, page: BrowserTypingJoinResult?, a: Active, finish: Finish) {
        guard finishAuthority(finish) else { finishEnded(finish.id); return }
        for proof in [full?.proof, page?.proof].compactMap({ $0 }) {
            guard !proof.light, proof.checkedAt >= finish.cutoff,
                  proof.bracket.map({ $0.start >= finish.cutoff }) ?? true else { finishEnded(finish.id); return }
        }
        finishWriteID = finish.id
        defer { finishWriteID = nil }
        do {
            // Older deferred parts precede their live carry. Keep the same
            // finite parked/carry budget and the finish's current write guard.
            for _ in 0...Self.limits.maxParked {
                guard try burst.resolveParked(full, page: page, secureInput: environment.secureInput(),
                                              now: environment.now(), policy: a.context.policy, force: true,
                                              write: { try self.write($0, a) }) != nil else { break }
            }
            for _ in 0...Self.limits.maxParked {
                guard burst.session.hasLive, let full, finishAuthority(finish) else { break }
                let reason: SealReason = burst.session.liveAtCap ? .size : .suspend
                _ = try burst.commit(full, typedAt: nil, processedAt: environment.now(), reason: reason,
                                     policy: a.context.policy) { try self.write($0, a) }
            }
            for _ in 0...Self.limits.maxParked {
                guard try burst.resolveParked(full, page: page, secureInput: environment.secureInput(),
                                              now: environment.now(), policy: a.context.policy, force: true,
                                              write: { try self.write($0, a) }) != nil else { break }
            }
        } catch { failed(a.coordinator, error) }
        finishEnded(finish.id)
    }

    private func finishEnded(_ id: UUID) {
        guard let f = finishing, f.id == id else { return }
        finishing = nil
        drop(.focus)
        f.completion()
    }


    // MARK: QF-17 bracketed design state (main thread only; the reads themselves run on the background executor)
    /// The chain of reads and boundaries (B1, B3).
    var engine = ChromeBracketEngine()
    /// B4: held keys' characters, owned and wiped.
    let held = ChromeHeldKeys()
    /// Shared with the read loop behind a lock (epoch, activity, requests, running reads).
    let control = ChromeReadControl()
    /// B5: aggregate-only counters (checks and harness runs; never logged per key).
    let bracketDiagnostics = ChromeBracketDiagnostics()
    /// Boundary work queued in event order with the held keys (a save waits for a read that started after it).
    var ops: [Op] = []
    /// Recent reads' results (a save or click join picks the first that started after its boundary).
    var results: [(start: UInt64, end: UInt64, page: Bool, result: BrowserTypingJoinResult)] = []
    /// Verified reads' proofs, by read id (the engine keeps digests only).
    var proofs: [UUID: BrowserTypingJoinProof] = [:]
    /// The quiet period at intake (a boundary's burst effects wait in `ops`; keys after it are judged at once).
    var intakeQuietFrom: UInt64?
    /// QF-17 bracketed field hold (Codex 07:10; review FH-1): the box a full read refused as `field` after a completed
    /// scan, and the latest time the hold's burst went on (the read's end, then each held key).
    struct FieldHold { let window: ChromeRef; let focus: ChromeRef; var lastAt: UInt64 }
    var fieldHold: FieldHold?
    /// QF-17 key accounting: the work since the last reconciliation involved a privacy refusal, boundary, drop or secret.
    var privacyContext = false
    /// QF-17 key accounting: a row was refused since the last reconciliation (not a secret: that is `privacyContext`).
    var saveRefusedContext = false
    /// The latest input event time main has processed (keys in any app, mouse downs): the B3 barrier's reference.
    var lastInputAt: UInt64 = 0
    /// Start of the latest read whose result main has handled.
    var lastDeliveredStart: UInt64?
    /// When a B3 barrier wait began (it ends in a discard after `barrierWaitNanoseconds`).
    var barrierSince: UInt64?
    var pumpScheduled = false

    init(environment: Environment) {
        self.environment = environment
        sites = BrowserTypingSiteRules()
        burst = BrowserTypingBurst(sites: sites, limits: Self.limits)
        burst.bracketed = environment.design == .bracketed
        burst.recoverBracketedBoundaries = environment.recoverBracketedBoundaries
        // Always the route in use (checks put their own in `shared`).
        TypingInputSource.listen { WebTypingRoute.shared.inputSourceChanged() }
        TypingPointer.listen { WebTypingRoute.shared.pointerDown(at: $0) }
        TypingKeyGap.listen { WebTypingRoute.shared.keyLost(at: $0) }
        Self.wireSearches()
        TypingPointer.listenRelease { WebTypingRoute.shared.pointerUp(at: $0, x: $1, y: $2, left: $3) }
    }

    private struct Active {
        let coordinator: Coordinator
        let context: (generation: UInt64, policy: CapturePolicy, revision: String)
    }
    /// Everything before a join, with no OS read: recording, typing, "Web
    /// pages in Chrome" (`allowsApp`), typed text allowed by the policy
    /// (consent, vault, not paused), the site choices loaded, and no privacy
    /// boundary since the pending text was typed. nil drops everything.
    private func active(_ coordinator: Coordinator?) -> Active? {
        // claude/chrome-offmain-1003: a key's own reads, made on the main thread when capture handed it over (`intake`),
        // are used once, for that key; everything else reads now.
        let read: ActiveRead?
        if let d = decided { read = d; decided = nil } else { read = Self.activeRead(coordinator) }
        guard let coordinator, let read else { inactive(coordinator); drop(.policy); return nil }
        let context = read.context, saved = read.saved
        if let w = watched, w.generation != context.generation || w.version != context.policy.version { diagnostics.count("web.policyChanged"); drop(.policy) }
        watched = (context.generation, context.policy.version)
        let choices = saved.typed.categories
        let blocked = PrivacySettings.sensitiveDomains + saved.settings.blockedDomains
        if choices != sites.choices || blocked != sites.alwaysBlocked {
            // A narrower choice drops what was typed under the wider one.
            diagnostics.count("web.siteChoicesChanged")
            drop(.policy)
            sites.choices = choices; sites.alwaysBlocked = blocked
        }
        return Active(coordinator: coordinator, context: context)
    }

    /// What `active` reads, with nothing changed: recording, typing, "Web pages in Chrome", the binding's context with
    /// typed text allowed, and the saved website typing policy. nil: one of them says no (or can't be read).
    struct ActiveRead {
        let context: (generation: UInt64, policy: CapturePolicy, revision: String)
        let saved: (settings: PrivacySettings, typed: TypedTextPolicy)
    }
    static func activeRead(_ coordinator: Coordinator?) -> ActiveRead? {
        guard let coordinator, coordinator.isRunning, coordinator.captureText, coordinator.allowsApp(WebTypingGate.bundle),
              let context = try? coordinator.captureBinding.context(), context.policy.typedText,
              let saved = try? coordinator.session.webTypingPolicy() else { return nil }
        return ActiveRead(context: context, saved: saved)
    }
    /// claude/chrome-offmain-1003: the main thread's `activeRead` for the key being handled (executor only).
    private var decided: ActiveRead??

    /// Diagnostics only: which check before the join said no (consent, the vault, the typing pause, typing or
    /// "Web pages in Chrome" off, recording stopped). Reads nothing more when diagnostics are off.
    private func inactive(_ coordinator: Coordinator?) {
        // fix/chrome-root: the always-on tally (`WebTypingRefusals`: episodes, never keys).
        WebTypingRefusals.shared.note(Self.offReason(coordinator))
        guard diagnostics.enabled else { return }
        guard let coordinator, coordinator.isRunning else { diagnostics.count("web.off.notRecording"); return }
        guard coordinator.captureText else { diagnostics.count("web.off.typingOff"); return }
        guard coordinator.allowsApp(WebTypingGate.bundle) else { diagnostics.count("web.off.chromeExcluded"); return }
        guard let context = try? coordinator.captureBinding.context() else { diagnostics.count("web.off.policyUnread"); return }
        guard context.policy.typedText else {
            if let typed = try? coordinator.session.webTypingPolicy().typed {
                if !typed.consented { diagnostics.count("web.off.noConsent") }
                else if typed.snoozed(now: environment.wall()) { diagnostics.count("web.off.paused") }
                else { diagnostics.count("web.off.vaultOrSwitch") }
            } else { diagnostics.count("web.off.typedTextOff") }
            return
        }
        diagnostics.count("web.off.settingsUnread")
    }

    /// fix/chrome-root: which check before the join said no, for the always-on tally. The same order as `active`.
    static func offReason(_ coordinator: Coordinator?) -> StaticString {
        guard let coordinator, coordinator.isRunning else { return "off.notRecording" }
        guard coordinator.captureText else { return "off.typingOff" }
        guard coordinator.allowsApp(WebTypingGate.bundle) else { return "off.chromePagesOff" }
        guard let context = try? coordinator.captureBinding.context() else { return "off.policyUnread" }
        guard context.policy.typedText else { return "off.typedTextOff" }
        return "off.policyUnread"
    }

    /// `keyFocus`: the system-focused app's PID as `NativeTypingRoute.keyTarget` read it for this key on main
    /// (`.none`: not read upstream, as in builds with no key panels; the bracketed design then reads it itself).
    func handle(eventAt: UInt64, stroke: KeyStroke, bundle: String, pid: pid_t?, coordinator: Coordinator,
                keyFocus: pid_t?? = .none, acquire: () throws -> String) -> Bool {
        if finishing != nil { return bundle == WebTypingGate.bundle }
        noteInput(eventAt)
        // Any key between a Post press and its release: not a click on the button.
        if submit.press != nil { submit.clear(); diagnostics.count("post.cancel.key") }
        guard bundle == WebTypingGate.bundle, let pid else {
            // A key in another app: website text left behind can't be proven any more.
            if burst.pending || burst.session.hasLive || burst.session.parkedCount > 0 { drop(.focus) }
            // Review FH-2: a key in another app ends a refusal hold (the field hold too), even with nothing unfinished.
            burst.endHolds()
            fieldHold = nil   // QF-17: the bracketed field hold too
            submit.clear()
            WebTypingStatus.set(.unknown)
            return false
        }
        diagnostics.count("web.key")
        WebTypingRefusals.shared.keyArrived(at: eventAt)   // claude/xtyping-1005: the tally's typing sessions
        guard let a = active(coordinator) else { return false }
        self.coordinator = coordinator
        if self.pid != pid { if self.pid != nil { diagnostics.count("web.chromeRelaunched") }; drop(.focus); self.pid = pid }
        let now = environment.now()
        // A click since the last key: the caret or focus may have moved.
        if let last = lastKeyAt, let since = environment.secondsSinceMouseDown(), since >= 0 {
            let downAt = now &- UInt64(min(since, 3600) * 1_000_000_000)
            if downAt > last {
                diagnostics.count("seal.clickSinceKey")
                if environment.design == .bracketed { chainBoundary(at: downAt) } else { burst.boundary(.pointer, at: downAt, now: now, focusMoved: true) }
                WebTypingStatus.set(.unknown)
            }
        }
        lastKeyAt = eventAt
        let intent = keyMap.intent(stroke, pressAndHold: environment.pressAndHold())
        if environment.design == .bracketed {
            switch intent {
            case .paste,.redo,.retract: bracketedRecipientEdited(a,eventAt:eventAt,now:now)
            default: break
            }
            do { try bracketedHandle(a, eventAt: eventAt, stroke: stroke, intent: intent, now: now, keyFocus: keyFocus, acquire: acquire) } catch {
                drop(.focus)
                failed(a.coordinator, error)
                return true
            }
            refreshTimers()
            return true
        }
        do {
            if case .leave(.focusKey, _) = intent, stroke.keyCode == 53 {
                keyMap.reset()
                diagnostics.count("seal.escape")
                burst.escape(at: eventAt, now: now)
            } else {
                if case .leave(let reason, _) = intent {
                    diagnostics.count("seal.leave", reason)
                    keyMap.reset()
                    // A shortcut may open a window or tab (Incognito too): the dot waits for the next join.
                    if reason != .focusKey { WebTypingStatus.set(.unknown) }
                    // Review G12: Command-Return or Control-Return sends in many web apps and may move
                    // focus off the field (or the page) before the settle: save now, like a click.
                    // summaries/v3: saved as .submitChord, so SendRules can mark the web mail send (spec §3).
                    if [.shortcut, .submitChord].contains(reason), [36, 76].contains(stroke.keyCode) { try saveLive(a, at: eventAt, reason: reason) }
                    // fix/chrome-capture (QF-2): a shortcut to another app, window or tab, or to the address bar,
                    // saves now too, while the page it was typed in is still in front (`WebSwitchShortcut`).
                    else if reason == .shortcut, WebSwitchShortcut.savesAtKeyDown(stroke), burst.session.hasLive {
                        try saveLive(a, at: eventAt, reason: reason)
                    }
                }
                let changing:Bool
                switch intent {case .paste,.redo,.retract:changing=true;default:changing=false}
                func editJoin() -> BrowserTypingJoinResult {
                    let result=join(a,anchor:eventAt)
                    if changing {
                        let allowed=result.proof.map { CaptureGate.typing(burst.proof($0,policy:a.context.policy),policy:a.context.policy,generation:burst.session.generation,now:environment.now()).outcome == .allowed } ?? false
                        if !allowed {recipients.editedUnknown(now:eventAt)}
                    }
                    return result
                }
                let step = try burst.key(intent, join: editJoin, light: { light(a, anchor: eventAt) }, held: { fieldHeld() }, typedAt: eventAt, now: environment.now, policy: a.context.policy, beforeEdit: editedRecipient,
                                         read: acquire, write: { try write($0, a) })
                note(step)
            }
        } catch {
            diagnostics.count("write.threw")
            drop(.focus)
            failed(a.coordinator, error)
            return true
        }
        refreshTimers()
        return true
    }
    /// Diagnostics: what one key did.
    private func note(_ step: BrowserTypingStep) {
        // fix/chrome-root: the always-on tally names a drop only after an allowed join, and never a gate or latch
        // refusal (reviews B5-1, B5-3), as the diagnostics below.
        if case .dropped = step, lastJoinAllowed, let r = burst.dropReason {
            switch r {
            case .late: WebTypingRefusals.shared.note("drop.late")
            case .stale: WebTypingRefusals.shared.note("drop.stale")
            case .quiet: WebTypingRefusals.shared.note("drop.quiet")
            case .held: WebTypingRefusals.shared.note("drop.held")
            case .otherBurst: WebTypingRefusals.shared.note("drop.otherBurst")
            case .lightStart: WebTypingRefusals.shared.note("drop.lightStart")
            case .denied, .gate, .latch: break
            }
        }
        guard diagnostics.enabled else { return }
        switch step {
        case .ignored: diagnostics.count("burst.ignored")
        // Review B5-3: a typed key is not named; a key the gate, the secret latch or the classifier refuses after an
        // allowed join is never named either, so a window of refused keys reads like one of typed keys.
        case .typed: break
        case .sealed: diagnostics.count("burst.sealed")
        // Review B5-1: after a denied join a drop names no reason (a refusal hold after a privacy denial drops keys
        // unnamed, after any other denial as `quiet`: that difference would tell the denial's kind).
        case .dropped: if lastJoinAllowed, let r = burst.dropReason { diagnostics.count("burst.dropped", r) }
        case .committed(let outcome): note(outcome)
        }
    }
    private func note(_ outcome: TypingOutcome?) {
        guard diagnostics.enabled, let outcome else { return }
        switch outcome {
        case .none: break   // B5-2: the same line as a withheld secret (.notWritten)
        case .committed: diagnostics.count("commit.saved")
        case .notWritten: break
        case .rejected: break
        case .parked: break   // B5-2: only a saved piece is named (a secret ends the piece; nothing is parked)
        case .discarded: break
        }
    }

    private func join(_ a: Active, anchor: UInt64? = nil) -> BrowserTypingJoinResult {
        lastJoinAllowed = false
        guard let pid else { return .denied(.notFocused) }
        // Native typing's direct-keyboard rule, before any join read: under an
        // input method the key is unproven and nothing is read (review F3).
        if !environment.directKeyboardInput() { WebTypingRefusals.shared.note("inputMethod") }   // fix/chrome-root: the tally
        guard environment.directKeyboardInput() else { diagnostics.count("web.inputMethod"); WebTypingStatus.set(.denied); return .denied(.inputMethod) }
        let coordinator = a.coordinator
        diagnostics.settleHeld(allowed: false)
        let began = environment.now()
        let result = environment.join(pid, sites) { [weak coordinator] in
            guard let coordinator else { return false }
            return coordinator.isRunning && coordinator.captureText && coordinator.allowsApp(WebTypingGate.bundle)
        }
        // Review B5-1: a denied join leaves `join.full.denied` alone: no reason, no timing, nothing it noted on its way.
        if result.proof != nil {
            diagnostics.joinTime(.full, from: began, to: environment.now())
            diagnostics.count("join.full.allowed")
            diagnostics.settleHeld(allowed: true)
        } else { diagnostics.count("join.full.denied"); diagnostics.settleHeld(allowed: false) }
        lastJoinAllowed = result.proof != nil
        // fix/chrome-root: the always-on tally of the full join's answer (privacy refusals as one name).
        WebTypingRefusals.shared.join(denial: result.denial?.rawValue)
        if result.denial != nil {recipients.editedUnknown(now:anchor ?? began)}
        // The menu-bar dot shows only after a join that allowed typing here.
        WebTypingStatus.set(result.proof != nil ? .allowed : .denied)
        let full = settled(result, anchor: anchor ?? began)
        composeProof = full.proof   // claude/int-1003: a full join's page facts (a light or click join keeps them)
        return full
    }

    /// The light per-key check (review G51), under the same rules before it
    /// as the full join; nil: the full join decides.
    private func light(_ a: Active, anchor: UInt64? = nil) -> BrowserTypingJoinResult? {
        guard let pid, environment.directKeyboardInput() else { return nil }
        let coordinator = a.coordinator
        let began = environment.now()
        let result = environment.light(pid, sites) { [weak coordinator] in
            guard let coordinator else { return false }
            return coordinator.isRunning && coordinator.captureText && coordinator.allowsApp(WebTypingGate.bundle)
        }
        // Review B5-1: timing only for an allowed check (a refusal's time can tell its reason).
        if result?.proof != nil { diagnostics.joinTime(.light, from: began, to: environment.now()) }
        diagnostics.count(result?.proof != nil ? "join.light.allowed" : "join.light.none")
        if result?.proof != nil { WebTypingStatus.set(.allowed) }
        if result?.denial != nil {recipients.editedUnknown(now:anchor ?? began)}
        return result.map { settled($0, anchor: anchor ?? began) }
    }
    /// Codex 07:10 (field hold): the box a full join refused as `field` still has focus. Never allows a key.
    private func fieldHeld() -> Bool? {
        guard let pid else { return nil }
        return environment.fieldHeld(pid)
    }
    /// The click join (`anyFocus`): the page, wherever focus is on it.
    private func pageJoin(_ a: Active, anchor: UInt64? = nil) -> BrowserTypingJoinResult {
        lastJoinAllowed = false
        guard let pid else { return .denied(.notFocused) }
        let coordinator = a.coordinator
        diagnostics.settleHeld(allowed: false)
        let began = environment.now()
        let result = environment.pointerJoin(pid, sites) { [weak coordinator] in
            guard let coordinator else { return false }
            return coordinator.isRunning && coordinator.captureText && coordinator.allowsApp(WebTypingGate.bundle)
        }
        // Review B5-1, as in `join`.
        if result.proof != nil {
            diagnostics.joinTime(.click, from: began, to: environment.now())
            diagnostics.count("join.click.allowed")
            diagnostics.settleHeld(allowed: true)
        } else { diagnostics.count("join.click.denied"); diagnostics.settleHeld(allowed: false) }
        lastJoinAllowed = result.proof != nil
        return settled(result, anchor: anchor ?? began)
    }

    private func settled(_ result: BrowserTypingJoinResult, anchor: UInt64) -> BrowserTypingJoinResult {
        guard let proof = result.proof else { return result }
        guard let metadata = proof.settledMetadata(anchor: anchor) else { return .denied(.changed) }
        return .allowed(metadata)
    }

    /// The one write path: the scrubber's secret check (a match means no
    /// row), a join row, then the session's store under its lock.
    /// Shortcuts expose no characters. Use only existing fresh witness metadata
    /// matched to key-time refs; otherwise retire authority for all known scopes.
    private func bracketedRecipientEdited(_ a:Active,eventAt:UInt64,now:UInt64) {
        guard let pid,let read=engine.verified(endingBefore:eventAt),let raw=proofs[read.id],
              let identity=environment.keyIdentity?(pid),identity.frontmostPID == pid,!identity.secureInput,
              let w=identity.window,let f=identity.focus,read.window.matches(object:w),read.focus.matches(object:f) else {
            recipients.editedUnknown(now:eventAt);return
        }
        let proof=burst.proof(raw,policy:a.context.policy)
        guard CaptureGate.typing(proof,policy:a.context.policy,generation:burst.session.generation,now:now).outcome == .allowed else {
            recipients.editedUnknown(now:eventAt);return
        }
        editedRecipient(proof,eventAt)
    }
    private func editedRecipient(_ proof: FocusProof, _ now: UInt64) {
        guard proof.sendField == "to",
              SendRules.surface(bundle: proof.bundle, host: BrowserSites.host(of: proof.url)) == "email" else { return }
        recipients.editedTo(window: proof.windowID + "|" + proof.tabID, now: now)
    }
    private func write(_ commit: TypingCommit, _ a: Active) throws -> Bool {
        if let f = finishing {
            guard finishWriteID == f.id, finishAuthority(f), a.context.generation == f.generation,
                  a.context.revision == f.revision else { return false }
        }
        // Review B5-2: nothing is counted before the secret check; `seal.reason` only with a saved row (below).
        guard !Privacy.secret(commit.text) else { privacyContext = true; return false }
        let wall = environment.wall()
        let email = SendRules.surface(bundle: commit.proof.bundle, host: BrowserSites.host(of: commit.proof.url)) == "email"
        let recipient = email ? recipients.observe(window: commit.proof.windowID + "|" + commit.proof.tabID, field: commit.proof.sendField,
                                                   text: commit.text, seal: commit.reason, now: environment.now(), lastEditedAt: commit.lastEditedAt) : nil
        guard var e = WebTypedRow.evidence(commit, id: "web-typing-" + UUID().uuidString.lowercased(), policyRevision: a.context.revision,
                                           wallTime: wall, now: environment.now(),
                                           pasted: pastes.observe(field: commit.proof.windowID + "|" + commit.proof.focusID, seal: commit.reason),
                                           recipient: recipient) else { diagnostics.count("write.noRow"); saveRefusedContext = true; return false }
        // claude/int-1003 (compose-send/v1): who or what it went to and what it answered (X, Reddit, webmail), from the
        // proof of the join that allowed these words: the same page, window, tab and document only.
        let gesture = BrowserComposeSignals.gesture(seal: commit.reason.rawValue)
        // fix/chrome-x2: a send judged at the settle, after the page moved on (the post window closed onto the timeline): the
        // settle's join replaced `composeProof`, so the last admitted key's proof (the same document) answers instead.
        let sameDocument: (BrowserTypingJoinProof) -> Bool = { $0.windowID == commit.proof.windowID && $0.tabID == commit.proof.tabID && $0.documentID == commit.proof.documentID }
        if let p = [composeProof, burst.last].compactMap({ $0 }).first(where: sameDocument),
           let unit = e.captureProvenance?.unit,
           let identity = BrowserComposeSignals.submit(proof: p, gesture: (gesture ?? .returnKey).rawValue)?.identity(surface: unit.surface ?? "", recipient: unit.to) {
            e.captureProvenance?.unit?.apply(destination: identity.0, context: identity.1)
        }
        guard WebTypedRow.valid(e) else { diagnostics.count("write.invalidRow"); saveRefusedContext = true; return false }
        // fix/chrome-x2: the same search already saved from its results page's address (`recordSearch`): not twice.
        if e.captureProvenance?.unit?.surface == "search", let host = BrowserSites.host(of: e.url) {
            urlSearches.removeAll { wall.timeIntervalSince($0.at) > Self.searchRepeatSeconds }
            if urlSearches.contains(where: { $0.host == host && $0.query == Self.searchKey(commit.text) }) { diagnostics.count("search.alreadySaved"); return true }
        }
        let wrote: Bool
        do { wrote = try a.coordinator.session.recordWebTyping(e, expectedPolicyRevision: a.context.revision, now: wall) }
        catch { diagnostics.count("write.storeThrew"); throw error }
        diagnostics.count(wrote ? "write.saved" : "write.storeRefused")
        if wrote { WebTypingRefusals.shared.saved() } else { WebTypingRefusals.shared.note("store.refused") }
        if !wrote { saveRefusedContext = true }
        if wrote { diagnostics.count("seal.reason", commit.reason) }
        if wrote, environment.design == .bracketed { bracketDiagnostics.saved(commit.keys + commit.edits) }
        if wrote, let gesture, let unit = e.captureProvenance?.unit, let v = e.browserVerification,
           BrowserComposeSignals.confirms(surface: unit.surface ?? "", field: unit.field ?? "", gesture: gesture),
           unit.send != "detected" || unit.sendBy == gesture.rawValue {
            confirmComposerSend(id: e.id, windowID: v.windowID, surface: unit.surface ?? "", gesture: gesture, a)
        }
        if wrote, e.captureProvenance?.unit?.surface == "search", let host = BrowserSites.host(of: e.url) {
            typedSearches.append((host, Self.searchKey(commit.text), wall))
        }
        if wrote {
            written += 1
            if let unit = e.captureProvenance?.unit, let v = e.browserVerification {
                let row = BrowserSubmitTracker.Row(id: e.id, runID: unit.runID, origin: e.url, windowID: v.windowID, tabID: v.tabID,
                                                   documentID: v.documentID ?? "", focusID: v.focusID ?? "", surface: unit.surface ?? "",
                                                   field: unit.field ?? "", sealReason: unit.sealReason, writtenAt: environment.now())
                // claude/livefix-1004: Command-Return sent the post; its earlier pieces (before a click or caret move in
                // the box, or in a box X re-created) are that post too.
                if unit.send == "detected", unit.sendBy == "commandReturn", BrowserSubmitControls.names(origin: e.url) != nil {
                    markChordPieces(submit.chordSent(row, now: environment.now()), a)
                }
                submit.wrote(row, send: unit.send)
            }
        }
        return wrote
    }

    /// fix/chrome-x2 (owner, 2026-10-03): a search the page read found on a search engine's results page
    /// (`ChromePageRead.search`, from Chrome page history's own read), saved as a typed search row
    /// (`WebTypedRow.searchEvidence`: "Searched Google for '…'"), whether it was typed in the page's box or in Chrome's
    /// address bar. Only while recording with typing on, Chrome allowed and Search and AI on; the store's checks follow
    /// (typing pause, site choices, block lists, the scrubber). The page read already refused Incognito and Guest
    /// windows, blocked sites and addresses. Once per tab and query; never one the join already saved from the box.
    /// fix/chrome-x2: page history's read keeps a results page's query (`ChromePageRecorder.searchQuery`) and hands the
    /// read here. Wired by the route and by capture's heartbeat (whichever comes first); the public build has neither.
    static func wireSearches() {
        guard ChromePageRecorder.onSearch == nil else { return }
        ChromePageRecorder.searchQuery = { WebSearchQuery.query($0) }
        ChromePageRecorder.onSearch = { read, coordinator in WebTypingRoute.shared.recordSearch(read, coordinator: coordinator) }
    }
    func recordSearch(_ read: ChromePageRead, coordinator: Coordinator) {
        // claude/chrome-offmain-1003: page history's read arrives on main; the route's search memory lives on its executor.
        if elsewhere({ self.recordSearch(read, coordinator: coordinator) }) { return }
        guard let s = read.search, read.siteOnly, let host = BrowserSites.host(of: read.origin), WebSearchQuery.engine(host: host) == s.engine,
              coordinator.isRunning, coordinator.captureText, coordinator.allowsApp(WebTypingGate.bundle),
              let context = try? coordinator.captureBinding.context(), context.policy.typedText,
              let saved = try? coordinator.session.webTypingPolicy(), saved.typed.categories.searchAndAI else { return }
        let key = Self.searchKey(s.query)
        if let l = lastSearch, l.tabID == read.tabID, l.engine == s.engine, l.query == key { return }
        lastSearch = (read.tabID, s.engine, key)
        let wall = environment.wall()
        typedSearches.removeAll { wall.timeIntervalSince($0.at) > Self.searchRepeatSeconds }
        guard !typedSearches.contains(where: { $0.host == host && $0.query == key }) else { diagnostics.count("search.alreadyTyped"); return }
        guard let e = WebTypedRow.searchEvidence(query: s.query, engine: s.engine, origin: read.origin, windowID: read.windowID, tabID: read.tabID,
                                                 id: "web-search-" + UUID().uuidString.lowercased(), policyRevision: context.revision,
                                                 generation: context.generation, wallTime: wall) else { diagnostics.count("search.noRow"); return }
        let wrote = (try? coordinator.session.recordWebTyping(e, expectedPolicyRevision: context.revision, now: wall)) ?? false
        diagnostics.count(wrote ? "search.saved" : "search.storeRefused")
        if wrote { WebTypingRefusals.shared.saved(); urlSearches.append((host, key, wall)) } else { WebTypingRefusals.shared.note("store.refused") }
    }

    /// claude/int-1003 (compose-send/v1, fix/chrome-x's compose signals): after a Return or Command-Return wrote a
    /// composer's row, the composer is read again at `BrowserComposeSignals.checks` (0.12, 0.35, 0.8 s; webmail until
    /// `EmailComposeAdapter.closeWindow`). The first read that confirms it (the route left, the composer closed, the field
    /// emptied; webmail: the compose closed) marks the row (`Coordinator.markComposerSent`). A key typed after the
    /// gesture, another Chrome, an unread composer or no confirmation by the last read leave the row as it was. Time
    /// alone never marks a send.
    private func confirmComposerSend(id: String, windowID: String, surface: String, gesture: ComposeGesture, _ a: Active) {
        guard let pid, let before = environment.composeSnapshot(pid) else { return }
        composeEpoch &+= 1
        let epoch = composeEpoch, keyAt = lastKeyAt, started = environment.now()
        var done = false
        for delay in BrowserComposeSignals.checks(surface: surface) {
            environment.schedule(delay) { [weak self, weak coordinator = a.coordinator] in
                guard let self, let coordinator, !done, self.finishing == nil, self.composeEpoch == epoch, self.pid == pid else { return }
                guard self.lastKeyAt == keyAt else { done = true; return }
                guard let after = self.environment.composeSnapshot(pid) else { return }
                let elapsed = Double(self.environment.now() &- started) / 1_000_000_000
                guard let confirmation = BrowserComposeSignals.confirm(surface: surface, gesture: gesture, before: before, after: after,
                                                                       elapsed: elapsed) else { return }
                done = true
                coordinator.markComposerSent(id: id, windowID: windowID, gesture: gesture, confirmation: confirmation, wallTime: self.environment.wall())
            }
        }
    }

    /// A mouse button went down (any app): the unfinished website text is
    /// saved now, before the click can move focus (Saturday test: a click
    /// lost it). Only while every check before a join still passes; the click
    /// join and `BrowserTypingBurst.pointerDown` decide the rest. The next
    /// key still treats the click as a boundary.
    ///
    /// fix/chrome-capture: then, when rows a click may mark are waiting (this
    /// click's own save included) and the press is a plain left click, the
    /// Post check (`armSubmit`). Any other press ends those rows' chance.
    func pointerDown(at downAt: UInt64) {
        // claude/chrome-offmain-1003: the press capture reported just before this call is taken now, on its thread.
        let press = TypingPointer.takePress()
        if elsewhere({ self.pointerDown(at: downAt, press: press) }) { return }
        pointerDown(at: downAt, press: press)
    }
    private func pointerDown(at downAt: UInt64, press: TypingPress?) {
        if finishing != nil { drop(.focus); return }
        noteInput(downAt)
        // QF-17 bracketed design (prototype): the Post gesture is not wired to it yet; a press is taken and dropped.
        if environment.design == .bracketed { submit.cancelPress(); bracketedPointerDown(at: downAt); return }
        submit.cancelPress()
        let live = burst.session.hasLive
        guard live || !submit.rows.isEmpty, pid != nil else { return }
        guard let a = active(coordinator) else { return }
        var page: BrowserTypingJoinResult?
        if live {
            do { page = try saveLive(a, at: downAt, reason: .pointer) } catch { diagnostics.count("write.threw"); drop(.focus); failed(a.coordinator, error); return }
        }
        armSubmit(a, press: press, page: page, downAt: downAt)
        refreshTimers()
    }
    /// A click or a chorded Return: the unfinished text is saved to its field
    /// if a click join taken now proves the same page and window list. The
    /// click join it took, if any.
    @discardableResult private func saveLive(_ a: Active, at typedAt: UInt64, reason: SealReason) throws -> BrowserTypingJoinResult? {
        guard burst.session.hasLive, pid != nil else { return nil }
        guard environment.secureInput() == false else { drop(.secureInput); return nil }
        let result = pageJoin(a, anchor: typedAt)
        note(try burst.pointerDown(result, at: typedAt, now: environment.now(), policy: a.context.policy, reason: reason) { try write($0, a) })
        return result
    }
    /// The Post check at a mouse-down, after any save: only for a plain left press, on a site with known submit
    /// controls, while rows of one composer saved in the last two minutes are waiting, with secure input off, after a
    /// click join (this click's own, or one taken now) proved their page; then the witness's hit test
    /// (`BrowserTypingJoin.submitControl`). A proven press waits for its release (`pointerUp`); anything else forgets
    /// the rows, so a later click can't mark them.
    private func armSubmit(_ a: Active, press: TypingPress?, page: BrowserTypingJoinResult?, downAt: UInt64) {
        let rows = submit.candidates(now: environment.now())
        guard let first = rows.first, let newest = rows.last else { submit.clear(); return }
        guard let press, press.plain else { diagnostics.count("post.skip.notPlainClick"); submit.clear(); return }
        guard let names = BrowserSubmitControls.names(origin: first.origin) else { diagnostics.count("post.skip.noControls"); submit.clear(); return }
        // Review B5-1: secure input, a denied click join, another page and a denied check all read `post.denied` alone.
        guard let pid, environment.secureInput() == false else { diagnostics.count("post.denied"); submit.clear(); return }
        let result = page ?? pageJoin(a, anchor: downAt)
        guard let p = result.proof, !p.light, p.checkedAt >= downAt, p.origin == first.origin, p.windowID == first.windowID,
              p.tabID == first.tabID, p.documentID == first.documentID else { diagnostics.count("post.denied"); submit.clear(); return }
        let coordinator = a.coordinator
        let began = environment.now()
        // claude/livefix-1004: the button must belong to the box in use now (the newest piece's), not the first piece's:
        // X re-creates its post box mid-draft.
        let checked = environment.submitControl(pid, press.x, press.y, p, newest.focusID, names) { [weak coordinator] in
            guard let coordinator else { return false }
            return coordinator.isRunning && coordinator.captureText && coordinator.allowsApp(WebTypingGate.bundle)
        }
        switch checked {
        // claude/livefix-1004: a click in the box itself (moving the caret) is not a Post, and the post's pieces wait for one.
        // No diagnostics name: review B5-1 names no denial reason (a named harmless one would single out the others).
        case .failure(.inField): break
        case .failure: diagnostics.count("post.denied"); submit.clear()
        case .success(let control):
            diagnostics.joinTime(.submit, from: began, to: environment.now())
            diagnostics.count("post.pressed")
            submit.arm(BrowserSubmitTracker.Press(rows: rows, control: control.control, frame: control.frame, downAt: downAt, x: press.x, y: press.y,
                                                  revision: a.context.revision, generation: a.context.generation))
        }
    }
    /// A mouse button came up. A press proven on a Post button that comes up on
    /// it (in time, without moving off, nothing in between) marks its rows
    /// submitted in the store, under the policy revision the press was proven
    /// under (`CaptureSession.recordWebSubmitGesture`); the rows are forgotten
    /// either way.
    func pointerUp(at upAt: UInt64, x: Double, y: Double, left: Bool) {
        if elsewhere({ self.pointerUp(at: upAt, x: x, y: y, left: left) }) { return }
        if finishing != nil { drop(.focus); return }
        guard submit.press != nil else { return }
        guard let press = submit.release(at: upAt, x: x, y: y, left: left) else { diagnostics.count("post.release.notClick"); submit.clear(); return }
        submit.clear()
        guard let a = active(coordinator), a.context.revision == press.revision, a.context.generation == press.generation,
              !press.rows.isEmpty else { diagnostics.count("post.release.policyChanged"); return }
        do {
            // claude/livefix-1004: the store checks each row against its own field: one call per box the pieces were typed in.
            var ids: [String] = []
            for group in Self.byField(press.rows) {
                ids += try a.coordinator.session.recordWebSubmitGesture(ids: group.map(\.id), documentID: group[0].documentID, focusID: group[0].focusID,
                                                                           control: press.control, expectedPolicyRevision: press.revision, now: environment.wall())
            }
            marked += ids.count
            diagnostics.count(ids.isEmpty ? "post.storeRefused" : "post.marked")
        } catch { diagnostics.count("post.storeThrew"); failed(a.coordinator, error) }
    }
    /// Rows grouped by their field (focus ID), in first-seen order.
    static func byField(_ rows: [BrowserSubmitTracker.Row]) -> [[BrowserSubmitTracker.Row]] {
        var order: [String] = [], groups: [String: [BrowserSubmitTracker.Row]] = [:]
        for r in rows { if groups[r.focusID] == nil { order.append(r.focusID) }; groups[r.focusID, default: []].append(r) }
        return order.compactMap { groups[$0] }
    }
    /// claude/livefix-1004: Command-Return sent a post; its earlier waiting pieces are marked sent by the chord too
    /// (`sendBy` "commandReturn"), under the policy the chord was written under.
    private func markChordPieces(_ rows: [BrowserSubmitTracker.Row], _ a: Active) {
        guard !rows.isEmpty else { return }
        do {
            var ids: [String] = []
            for group in Self.byField(rows) {
                ids += try a.coordinator.session.recordWebSubmitGesture(ids: group.map(\.id), documentID: group[0].documentID, focusID: group[0].focusID,
                                                                           control: "", expectedPolicyRevision: a.context.revision, chord: true,
                                                                           now: environment.wall())
            }
            marked += ids.count
            diagnostics.count(ids.isEmpty ? "post.storeRefused" : "post.chord.marked")
            // final-1004 (with claude/chrome-offmain-1003): this runs inside `write`, on the route's executor in owner
            // builds, so a failure is reported to the coordinator on main (`failed`), as pointerUp's is.
        } catch { diagnostics.count("post.storeThrew"); failed(a.coordinator, error) }
    }

    /// claude/xtyping-1005: EventCapture, on main: Chrome `pid` came to the front, or was in front when recording
    /// started (a relaunched Chrome comes to the front as a new PID). Chrome's accessibility is asleep until an
    /// assistive client asks its application its role, and while it sleeps every join is refused `notFocused`; so,
    /// with website typing on (the same checks a key's join makes first: `activeRead`), the witness wakes it now
    /// (`BrowserTypingJoin.wake`: the join's checks and mode gate, then that one role read). Synchronous design only;
    /// when Chrome is already awake it reads no more than which app is in front and focused.
    func chromeInFront(pid: pid_t, coordinator: Coordinator) {
        guard environment.design == .synchronous, Self.activeRead(coordinator) != nil else { return }
        let work: () -> Void = { [self, weak coordinator] in
            let woke = environment.wake(pid) { [weak coordinator] in
                guard let coordinator else { return false }
                return coordinator.isRunning && coordinator.captureText && coordinator.allowsApp(WebTypingGate.bundle)
            }
            if woke { WebTypingRefusals.shared.woke() }
        }
        if elsewhere(work) { return }
        work()
    }

    /// EventCapture dropped a key as late, unread (review G51): the
    /// unfinished text is sealed like native typing's gap, so it is saved
    /// only if a fresh join finds its field again, and never joined to the
    /// next key across the missing one.
    func keyLost(at now: UInt64) {
        if elsewhere({ self.keyLost(at: now) }) { return }
        // fix/chrome-root: a key lost at intake (processed too long after it was typed) while Chrome is in front.
        if let pid, environment.frontmostPID?() == pid {
            WebTypingRefusals.shared.keyArrived(at: now)   // claude/xtyping-1005: a lost key is part of a typing session too
            WebTypingRefusals.shared.note("key.lateAtIntake")
        }
        if finishing != nil { drop(.focus); return }
        if environment.design == .bracketed { bracketedBoundary(at: now, op: .gap); return }
        guard burst.pending || burst.session.hasLive else { return }
        burst.boundary(.gap, at: now, now: now, focusMoved: false)
        refreshTimers()
    }

    /// The keyboard input source changed: like native typing, the unfinished
    /// text is sealed (parked; after the settle a fresh join of its field saves
    /// it, and under an input method that join is refused, so it is dropped),
    /// the quiet period starts, and the dot waits for the next join.
    func inputSourceChanged() {
        // claude/chrome-offmain-1003: the new input source is read on main (`DirectInputMemory`) before the change is queued.
        if environment.executor?.isCurrent == false { _ = environment.directKeyboardInput() }
        if elsewhere({ self.inputSourceChanged() }) { return }
        if finishing != nil { drop(.focus); return }
        WebTypingStatus.set(.unknown)
        keyMap.reset()
        // Codex 07:10: an input-source change ends a refusal hold (the field hold too), even with nothing unfinished.
        burst.endHolds()
        if environment.design == .bracketed { bracketedBoundary(at: environment.now(), op: .inputSource); return }
        guard burst.pending || burst.session.hasLive else { return }
        let now = environment.now()
        burst.boundary(.inputSource, at: now, now: now, focusMoved: true)
        refreshTimers()
    }

    /// Drops everything unsaved and cancels the timers.
    func drop(_ boundary: PrivacyBoundary) {
        // claude/chrome-offmain-1003: a privacy boundary from the main thread (a pause, secure input, a policy change)
        // takes effect before the caller goes on, as it did on main: run on the executor while main waits, after
        // everything the route was given before it (a key's join in progress finishes first; its write still asks the
        // session, which is no longer recording after a pause). Work there never waits on main: no deadlock.
        if let executor = environment.executor, !executor.isCurrent { executor.sync { self.drop(boundary) }; return }
        if boundary != .focus { recipients.forget() }
        let finish = finishing; finishing = nil
        if boundary != .focus { WebTypingStatus.set(.unknown) }
        // QF-17: every held key is wiped (never counted), the chain and the queued work end, and running reads'
        // results will be ignored (the epoch moves).
        held.wipe(); engine.reset(); ops.removeAll(); results.removeAll(); proofs.removeAll(); control.bump(); intakeQuietFrom = nil
        fieldHold = nil
        lastDeliveredStart = nil
        idleEpoch &+= 1; settleEpoch &+= 1; housekeepingEpoch &+= 1
        idleAt = nil; settleAt = nil; housekeepingAt = nil
        keyMap.reset()
        submit.clear()
        // claude/int-1003: the page facts go; a privacy boundary also ends a send's re-reads (a focus change doesn't:
        // a sent compose closing moves focus).
        composeProof = nil
        if boundary != .focus { composeEpoch &+= 1 }
        // Review B5-2: no name for a drop. Whether there was unsaved text to drop tells whether a secret ended it.
        burst.invalidate(boundary)
        // QF-17 key accounting: what a drop removes is never counted (B5-2), but it is accounted (privacy).
        privacyContext = true; reconcileKeys()
        finish?.completion()
    }

    // MARK: Timers

    private func refreshTimers() {
        guard finishing == nil else { return }
        let session = burst.session, now = environment.now()
        func delay(_ at: UInt64) -> TimeInterval { at > now ? Double(at - now) / 1_000_000_000 : 0 }
        if session.idleDeadline != idleAt {
            idleAt = session.idleDeadline; idleEpoch &+= 1
            if let at = idleAt {
                let epoch = idleEpoch
                environment.schedule(delay(at)) { [weak self] in self?.idle(epoch) }
            }
        }
        if session.nextParkedDeadline != settleAt {
            settleAt = session.nextParkedDeadline; settleEpoch &+= 1
            if let at = settleAt {
                let epoch = settleEpoch
                environment.schedule(delay(at)) { [weak self] in self?.settle(epoch) }
            }
        }
        if session.housekeepingDeadline != housekeepingAt {
            housekeepingAt = session.housekeepingDeadline; housekeepingEpoch &+= 1
            if let at = housekeepingAt {
                let epoch = housekeepingEpoch
                environment.schedule(delay(at)) { [weak self] in
                    guard let self, epoch == self.housekeepingEpoch else { return }
                    self.housekeepingAt = nil
                    self.burst.session.expire(now: self.environment.now())
                    self.reconcileKeys()
                    self.refreshTimers()
                }
            }
        }
    }
    /// A pause in typing: a live save, with a fresh join of the same burst.
    private func idle(_ epoch: UInt64) {
        guard epoch == idleEpoch else { return }
        idleAt = nil
        guard let a = active(coordinator) else { return }
        if environment.design == .bracketed { enqueue(Op(.idle, at: environment.now())); return }
        guard environment.secureInput() == false else { lastJoinAllowed = false; drop(.secureInput); return }
        let result = join(a)
        do {
            note(try burst.commit(result, typedAt: nil, processedAt: environment.now(), reason: .idle, policy: a.context.policy) { try write($0, a) })
            // Still due after its idle save: it could not be written. Drop it rather than retry in a loop.
            if let due = burst.session.idleDeadline, due <= environment.now() { burst.session.retract() }
        } catch { drop(.focus); failed(a.coordinator, error); return }
        refreshTimers()
    }
    /// After the settle: a parked unit is saved only if fresh joins of its
    /// page find focus in its field, in another text field there, or on
    /// something there that is neither a text field nor secure
    /// (`BrowserTypingBurst.resolveParked`, review G12). The full join goes
    /// first and decides whenever it can, as before the Tab fix. Only when it
    /// finds focus on something that isn't a text field (`.field`: Tab to a
    /// button) is the click join taken, and the join compares it with the page
    /// from before that denial (review G12, round 1: a click join taken first
    /// that failed once made the full join forget the page, and the unit was
    /// dropped).
    private func settle(_ epoch: UInt64) {
        guard epoch == settleEpoch else { return }
        settleAt = nil
        guard let a = active(coordinator) else { return }
        if environment.design == .bracketed { enqueue(Op(.settle, at: environment.now())); return }
        var secure = environment.secureInput()
        let result: BrowserTypingJoinResult? = secure ? nil : join(a)
        // fix/chrome-x2: also after a send whose page was still changing (`BrowserTypingBurst.wantsPageJoin`).
        let page: BrowserTypingJoinResult? = !secure && burst.wantsPageJoin(result, now: environment.now()) ? pageJoin(a) : nil
        if !secure { secure = environment.secureInput() }
        // Review B5-1: the settle's full join decides (a click join taken after it denied can't clear the flag).
        lastJoinAllowed = !secure && result?.proof != nil
        do {
            for _ in 0...Self.limits.maxParked {
                guard let outcome = try burst.resolveParked(result, page: page, secureInput: secure, now: environment.now(), policy: a.context.policy,
                                                            write: { try write($0, a) })
                else { break }
                note(outcome)
            }
            if let due = burst.session.nextParkedDeadline, due <= environment.now() { drop(.focus); return }
        } catch { drop(.focus); failed(a.coordinator, error); return }
        refreshTimers()
    }
}

// MARK: - QF-17 bracketed design (prototype)

extension WebTypingRoute {
    /// Boundary work queued with the held keys, in event order.
    final class Op {
        enum Kind: Equatable {
            case leave(SealReason), escape, retract, split(SealReason), save(SealReason), click(SealReason), idle, settle, gap, inputSource, dropUnread, finish(UUID)
        }
        let kind: Kind
        let at: UInt64
        /// The settle's full-join result while it waits for its click join.
        var settleFull: BrowserTypingJoinResult??
        /// A key dropped by the field hold (or FH-1): it follows a privacy refusal (never counted).
        var privacy = false
        init(_ kind: Kind, at: UInt64) { self.kind = kind; self.at = at }
    }
    /// Denials that are about privacy (B5: nothing around them is counted; everything held is wiped).
    static let privacyDenials: Set<BrowserTypingDenial> = [.notNormal, .sensitiveField, .blockedSite, .disabled, .field, .notFocused]
    /// Denials that drop everything unsaved, as a key's join does in the synchronous design (invariant 6).
    static let dropsUnsaved: Set<BrowserTypingDenial> = [.notNormal, .sensitiveField, .blockedSite, .disabled]

    func noteInput(_ t: UInt64) { lastInputAt = max(lastInputAt, t) }

    /// One key in Chrome, bracketed design. Nothing here waits on an Apple Event or reads Accessibility before a
    /// verified read exists (M8, M9).
    private func bracketedHandle(_ a: Active, eventAt t: UInt64, stroke: KeyStroke, intent: KeyIntent, now: UInt64,
                         keyFocus: pid_t??, acquire: () throws -> String) throws {
        // B5-3 (fix/chrome-capture 20d09a8): intake time is kept only for a key that was read and held. A key refused
        // at intake (another window or app, secure input, the quiet period, no fresh read) leaves no sample, so a
        // window of refused keys reads like a window with no typing.
        let wallStart = DispatchTime.now().uptimeNanoseconds
        var heldKey = false
        defer { if heldKey { bracketDiagnostics.intake(microseconds: Double(DispatchTime.now().uptimeNanoseconds &- wallStart) / 1000) } }
        control.setEnabled(true)
        // The tap's input-lag bound, unchanged: a key processed more than maxKeyLag after it was typed is refused
        // (and is a boundary: nothing is attributed across it).
        guard now >= t, now - t <= BrowserTypingTiming.maxKeyLagNanoseconds else { bracketedBoundary(at: t, op: .gap); return }
        // B3: any Command, Control or Option chord is a boundary.
        if stroke.command || stroke.control || stroke.option { chainBoundary(at: t) }
        switch intent {
        case .consume, .noop:
            return
        case .leave(let reason, _):
            keyMap.reset(); chainBoundary(at: t); quietAtIntake(t)
            if reason != .focusKey { WebTypingStatus.set(.unknown) }
            if stroke.keyCode == 53 { enqueue(Op(.escape, at: t)) } else {
                // Review G12: Command-Return or Control-Return saves the unfinished text at once, like a click.
                if [.shortcut, .submitChord].contains(reason), [36, 76].contains(stroke.keyCode), burst.session.hasLive { enqueue(Op(.click(reason), at: t)) }
                enqueue(Op(.leave(reason), at: t))
            }
            activity(t)
        case .retract:
            chainBoundary(at: t); quietAtIntake(t); enqueue(Op(.retract, at: t))
        case .split(let reason):
            chainBoundary(at: t); enqueue(Op(.split(reason), at: t)); activity(t)
        case .redo, .paste, .submit:
            let reason: SealReason = intent == .submit ? .submit : intent == .paste ? .paste : .cursor
            chainBoundary(at: t); quietAtIntake(t); enqueue(Op(.save(reason), at: t)); activity(t)
        case .edit(.moveBackward), .edit(.moveForward):
            // PM5 (B3): a plain Left or Right arrow moves the caret, and page scripts use arrows to move focus
            // between split one-time-code boxes: a boundary, and the unit is saved there.
            chainBoundary(at: t); quietAtIntake(t); enqueue(Op(.split(.cursor), at: t)); activity(t)
        case .edit, .insertText, .insert, .accent:
            // The quiet period and the refusal hold: dropped unread, as in the synchronous design (in order, after
            // any boundary work queued before it). A privacy drop: never counted.
            let quietDrop = burst.dropsUnread(typedAt: t) || (!environment.recoverBracketedBoundaries
                && intakeQuietFrom.map({ t < $0 &+ BrowserTypingTiming.quietNanoseconds }) == true)
            // The field hold (review 10:35 Q-2): after the quiet period is judged, before `activity` (a held key starts
            // no read), `bracketedIntakeAdmits` and `acquire`.
            if fieldHoldIntake(at: t, now: now) { return }
            activity(t)
            if quietDrop { enqueue(Op(.dropUnread, at: t)); return }
            // Native typing's direct-keyboard rule, before anything is read (review F3).
            guard environment.directKeyboardInput() else { held.wipe(); enqueue(Op(.dropUnread, at: t)); return }
            // D3 + PM3 (D5): a verified read of this Chrome that ended before the key and is still fresh enough for
            // the span to hold (its first observation began less than SPAN before the key). Otherwise nothing is
            // read at the key and the key is dropped unread: it could never be admitted. Not counted (PM6 a: its
            // refs were never matched to a verified read; the harness measures first-key loss from its known input).
            guard let pid, let last = engine.verified(endingBefore: t), last.pid == pid, t - last.start < ChromeBracketTiming.spanNanoseconds else {
                unreadGap(at: t); return
            }
            // QF-1: after a boundary, recovery needs a whole verified read that
            // started after it and ended before this key, before acquiring any bytes.
            guard burst.bracketedIntakeAdmits(typedAt: t, priorReadStartedAt: last.start, boundaryAt: intakeQuietFrom) else {
                unreadGap(at: t); return
            }
            // PM2 (B2): the system-focused app is Chrome (read upstream for this key; else read here, on main).
            let focusPID: pid_t? = keyFocus ?? environment.systemFocus()
            guard let focusPID else { lose(); unreadGap(at: t); return }                          // unknown: a real loss
            guard focusPID == pid else { focusMoved(at: t); return }                              // PM1: never counted
            // B2 (D5): frontmost == Chrome, no secure input, the focused window and element refs of that read.
            guard let identity = environment.keyIdentity?(pid) else { lose(); unreadGap(at: t); return }
            guard identity.frontmostPID == pid, !identity.secureInput else { focusMoved(at: t); return }
            // PM6 b: the identity reader paused or timed out: a real, non-privacy loss (aggregate count only).
            guard let w = identity.window, let f = identity.focus else { lose(); unreadGap(at: t); return }
            // PM1: another window, tab or field (maybe Incognito): a boundary; everything held is wiped; not counted.
            guard last.window.matches(object: w), last.focus.matches(object: f) else { focusMoved(at: t); return }
            // D3: a following read is running or will run (the loop is claimed; `activity` just extended it).
            guard control.running else { lose(); unreadGap(at: t); return }
            let chars: String, kind: ChromeHeldKind
            switch intent {
            case .insert(let dead): let raw = try acquire(); chars = dead.map { $0.compose(raw) } ?? raw; kind = .text
            case .insertText(let text): chars = text; kind = .text
            case .accent(let letter): chars = letter; kind = .accent
            case .edit(let op): chars = ""; kind = .edit(op)
            default: return
            }
            let refs = (ChromeRef(w, same: { $0 === w }), ChromeRef(f, same: { $0 === f }))
            if held.append(typedAt: t, kind: kind, window: refs.0, focus: refs.1, characters: chars) == .overflow {
                // B4 cap: the whole buffer is wiped; nothing across the gap is kept.
                lose(held.count + 1, .bracket); held.wipe(); nonUserHoldEnd(at: t); chainBoundary(at: t)
                enqueue(Op(.gap, at: t))
                return
            }
            heldKey = true
            pump()
        }
    }

    /// QF-17 bracketed field hold (Codex 07:10; the three-way rule of fix/chrome-capture 9de7d09, review FH-1), at a
    /// plain key before `activity`: true when the key was dropped unread. While plain keys come less than
    /// `refusedHoldNanoseconds` apart after a full read refused a box as `field` (a completed scan), every key is
    /// dropped unread, starts no read and is never counted (it follows a privacy refusal):
    /// - Chrome frontmost, no secure input, focus in that same window and element: the hold goes on and the quiet
    ///   period starts again (`burst.noteDenied`);
    /// - anything else (another box or window, another app, secure input, refs that can't be read: fail closed): it may
    ///   have been typed in the refused box before a scripted focus move, so it is never bracket-admitted; a boundary
    ///   (the chain's, every held key wiped), the quiet period starts again (`burst.noteDenied`) and the hold ends;
    ///   reads decide after the quiet period.
    /// Both quiet periods are denial quiet (review 10:35 Q-1/Q-2): never the intake boundary (`intakeQuietFrom`), which
    /// QF-1 recovery may shorten; `noteDenied` can't be recovered and an older or equal boundary can't undo it.
    /// No box (a read refused focus on a button, labels that couldn't be read, a timeout): no hold. A pause of
    /// `refusedHoldNanoseconds` or more, every boundary (`chainBoundary`, `drop`) and a key in another app end it.
    func fieldHoldIntake(at t: UInt64, now: UInt64) -> Bool {
        guard let h = fieldHold else { return false }
        guard t < h.lastAt || t - h.lastAt < BrowserTypingTiming.refusedHoldNanoseconds else { fieldHold = nil; return false }
        fieldHold?.lastAt = max(h.lastAt, t)
        let op = Op(.dropUnread, at: t)
        op.privacy = true
        if let pid, let id = environment.keyIdentity?(pid), id.frontmostPID == pid, !id.secureInput,
           let w = id.window, let f = id.focus, h.window.matches(object: w), h.focus.matches(object: f) {
            burst.noteDenied(at: max(now, t)); enqueue(op); return true
        }
        // FH-1: dropped unread, a boundary (engine and held keys; `focusMoved` ends the hold), and denial quiet.
        focusMoved(at: t); burst.noteDenied(at: max(now, t)); enqueue(op)
        return true
    }
    /// Review 11:05 FHB-1: a non-user event (a late or lost key, a window notification, an input-source change, the hold
    /// cap) that ends an active field hold starts denial quiet, as the synchronous path's hold drops do (`noteDenied`:
    /// QF-1 recovery can't shorten it; an older or equal time changes nothing).
    func nonUserHoldEnd(at t: UInt64) { if fieldHold != nil { burst.noteDenied(at: t) } }
    /// A boundary for the chain (B3); it ends the field hold too.
    func chainBoundary(at t: UInt64) { engine.boundary(at: t); fieldHold = nil }
    /// A non-privacy loss (B5: counted only after a later read proves no privacy refusal).
    func lose(_ n: Int = 1, _ reason: ChromeBracketDiagnostics.LossReason = .unread) { bracketDiagnostics.keyLost(n, reason) }
    /// QF-17 key accounting (the b+ silent-loss finding on 939e6df): after any work that can change the session,
    /// admitted text that left it unwritten is counted in `keys.dropped` with a reason: `privacy` when a privacy
    /// refusal, boundary, drop, gate, latch or secret caused it, `save` when a row was refused, else `retract`.
    /// Nothing admitted leaves silently; the checks assert admitted = saved + dropped + pending in every lane
    /// (`ChromeBracketDiagnostics.balanced`), and pending 0 once a burst is over. The reason stays inside: the snapshot
    /// has the undivided `keys.dropped` (review 08:29).
    func reconcileKeys() {
        guard environment.design == .bracketed else { return }
        let reason: ChromeBracketDiagnostics.DropReason = privacyContext ? .privacy : saveRefusedContext ? .save : .retract
        // The session names what it can (a rejection or a privacy discard: privacy; a settle that couldn't prove the
        // departure: departure; no text: empty; the parked cap: capacity); the context names the rest.
        var named: [ChromeBracketDiagnostics.DropReason: Int] = [:]
        for (why, n) in burst.session.takeUnitDrops() {
            switch why {
            case .privacy: named[.privacy, default: 0] += n
            case .departure: named[.departure, default: 0] += n
            case .empty: named[.empty, default: 0] += n
            case .capacity: named[.capacity, default: 0] += n
            }
        }
        bracketDiagnostics.reconcile(sessionPending: burst.session.pendingUnits, reason: reason, named: named)
        privacyContext = false; saveRefusedContext = false
    }
    /// A key dropped unread: text on either side of it is never one unit (sealed there, in event order).
    func unreadGap(at t: UInt64) {
        if burst.pending || burst.session.hasLive || !held.isEmpty || !ops.isEmpty { enqueue(Op(.gap, at: t)) }
    }
    /// PM1: key-time evidence that focus moved (another app or window, secure input, other refs): a boundary for
    /// the chain, every held key wiped, and the unit sealed there. Nothing is counted (it may be Incognito).
    func focusMoved(at t: UInt64) {
        chainBoundary(at: t)
        held.wipe()
        if burst.pending || burst.session.hasLive || !ops.isEmpty { enqueue(Op(.gap, at: t)) }
    }
    func quietAtIntake(_ t: UInt64) { intakeQuietFrom = max(intakeQuietFrom ?? 0, t) }
    /// B3 "reads start on a click, Tab or key": keep the read loop running for `activeNanoseconds` after `t`.
    func activity(_ t: UInt64) {
        control.extend(until: t &+ ChromeBracketTiming.activeNanoseconds)
        ensureLoop()
    }
    func enqueue(_ op: Op) {
        ops.append(op)
        ops.sort { $0.at < $1.at }
        pump()
    }
    /// Keys lost unread (TypingKeyGap), an input source change, an AX focused-window or title notification:
    /// a boundary. Every held key is discarded (an AX notification carries no time: it is treated as inside
    /// every bracket not yet decided).
    func bracketedBoundary(at t: UInt64, op kind: Op.Kind?) {
        nonUserHoldEnd(at: t)
        chainBoundary(at: t)
        if !held.isEmpty { lose(held.count, .bracket); held.wipe() }
        if let kind, burst.pending || burst.session.hasLive || !ops.isEmpty { enqueue(Op(kind, at: t)) }
    }
    /// EventCapture: Chrome's focused window or its title changed (the only AX notifications Chrome gets).
    func chromeWindowNotification() {
        if elsewhere({ self.chromeWindowNotification() }) { return }
        if finishing != nil { drop(.focus); return }
        guard environment.design == .bracketed else { return }
        bracketedBoundary(at: environment.now(), op: nil)
    }
    func bracketedPointerDown(at downAt: UInt64) {
        chainBoundary(at: downAt)
        guard pid != nil, active(coordinator) != nil else { return }
        quietAtIntake(downAt)
        enqueue(Op(.click(.pointer), at: downAt))
        if environment.frontmostPID?() == pid { activity(downAt) }
    }

    // MARK: The read loop (background executor; at most one read in flight: M9)

    func ensureLoop() {
        guard let pid, control.claim() else { return }
        let epoch = control.epoch
        // Immutable snapshots (M4): the site choices as of now, and consent read through the shared control.
        let snapshot = BrowserTypingSiteRules(choices: sites.choices, alwaysBlocked: sites.alwaysBlocked, blockList: sites.blockList, expanded: sites.expanded)
        let env = environment, control = control
        let background = env.background ?? { work in env.schedule(0, work) }
        let toMain = env.toMain ?? { work in env.schedule(0, work) }
        final class Loop { var step: (() -> Void)?; var backoff: UInt64 = 0 }
        let loop = Loop()
        // PM8: the next read starts only after main has handled this one's result (`delivered` re-checks recording,
        // typing, consent, the pause and the policy version first, and a refusal bumps the epoch). So after any
        // revocation at most the one read already in flight completes, and nothing it read is ever used.
        loop.step = { [weak self] in
            let next = control.next(epoch: epoch, now: env.now())
            guard next != .stop, next != .stale else {
                loop.step = nil
                if next == .stale { toMain { self?.ensureLoopIfWanted() } }
                return
            }
            let enabled: () -> Bool = { control.enabled(epoch: epoch) }
            let t0 = env.now()
            let token = control.began(t0, epoch: epoch, full: next != .page)
            let result = next == .page ? env.pointerJoin(pid, snapshot, enabled) : env.join(pid, snapshot, enabled)
            let t1 = env.now()
            // The field hold: the refused box's refs, read from the join's own state on this executor (M4).
            let box = next != .page && result.denial == .field ? env.refusedBox?(pid) : nil
            control.ended(token, at: t1)
            // A refused read, or one that ended almost at once, pauses the loop (doubling while refusals continue, up
            // to retryMax; reset by a verified read): it never spins, e.g. while secure input stays on.
            if result.denial != nil || t1 &- t0 < ChromeBracketTiming.minimumReadNanoseconds {
                loop.backoff = loop.backoff == 0 ? ChromeBracketTiming.retryNanoseconds : min(loop.backoff * 2, ChromeBracketTiming.retryMaxNanoseconds)
            } else {
                loop.backoff = 0
            }
            let pause = loop.backoff
            toMain {
                self?.delivered(result, start: t0, end: t1, page: next == .page, epoch: epoch, pid: pid, refusedBox: box)
                guard let step = loop.step else { return }
                // PM8: after a pause, consent, typing, the pause and the policy are re-checked on main before the next
                // read (a revocation bumps the epoch, and the step then stops at `next`).
                if pause > 0 {
                    env.schedule(Double(pause) / 1_000_000_000) { [weak self] in if let self { _ = self.active(self.coordinator) }; background(step) }
                } else { background(step) }
            }
        }
        background(loop.step!)
    }

    /// A loop stopped because the epoch moved on while reads were still wanted: start one for the current epoch.
    func ensureLoopIfWanted() {
        guard environment.design == .bracketed, pid != nil, active(coordinator) != nil else { return }
        ensureLoop()
    }

    /// A read's result, on main. Stale results (another epoch or Chrome) are ignored; the generation, policy
    /// version and PID are re-checked (M4) before anything is admitted.
    func delivered(_ result: BrowserTypingJoinResult, start: UInt64, end: UInt64, page: Bool, epoch: UInt64, pid readPID: pid_t,
                   refusedBox: (window: ChromeRef, focus: ChromeRef)? = nil) {
        guard epoch == control.epoch, readPID == pid else { return }
        lastDeliveredStart = start
        guard active(coordinator) != nil, epoch == control.epoch else { return }
        results.append((start, end, page, result))
        if results.count > 16 { results.removeFirst(results.count - 16) }
        if let denial = result.denial {
            recipients.editedUnknown(now:end)
            bracketDiagnostics.read(verified: false, milliseconds: Double(end &- start) / 1e6, events: 0)
            if !page { engine.readFinished(start: start, end: end, record: nil) }
            if Self.privacyDenials.contains(denial) {
                // Everything held is dropped at once, with no count (B4 d, B5).
                held.wipe(); bracketDiagnostics.privacyRefusal(); privacyContext = true
                // The field hold starts (or follows the box) only on a full read's `field` after a completed scan;
                // never on a timeout or labels that couldn't be read (no box then). Any other result leaves it alone:
                // it ends only at a boundary, a pause or a key that doesn't match it (`fieldHoldIntake`).
                // The pause is measured between keys: a later read that refuses again follows the box, never the clock.
                if !page, denial == .field, let refusedBox { fieldHold = FieldHold(window: refusedBox.window, focus: refusedBox.focus, lastAt: fieldHold?.lastAt ?? end) }
            } else if !held.isEmpty, !page {
                lose(held.count, .bracket); held.wipe()
            }
            WebTypingStatus.set(.denied)
            if Self.dropsUnsaved.contains(denial) {
                // Invariant 6: an Incognito or Guest window, a sensitive field, a blocked site or typing off drops
                // everything unsaved, as a key's join does; the chain starts over.
                burst.denied(denial, at: environment.now())
                engine.reset(); ops.removeAll(); control.bump(); lastDeliveredStart = nil; fieldHold = nil; reconcileKeys(); refreshTimers(); return
            }
        } else if let proof = result.proof {
            WebTypingStatus.set(.allowed)
            if !page, let record = proof.bracket {
                engine.readFinished(start: record.start, end: record.end, record: record)
                proofs[record.id] = proof
                if proofs.count > 32 { let keep = Set(results.compactMap { $0.result.proof?.bracket?.id }); proofs = proofs.filter { keep.contains($0.key) } }
                bracketDiagnostics.confirm()
                bracketDiagnostics.read(verified: true, milliseconds: Double(end &- start) / 1e6, events: record.appleEvents)
            } else if !page {
                engine.readFinished(start: start, end: end, record: nil)
            }
        }
        pump()
        refreshTimers()
    }

    // MARK: Admission and boundary work, in event order (main)

    func pump() {
        pumpLoop()
        reconcileKeys()
    }
    private func pumpLoop() {
        guard environment.design == .bracketed, let a = active(coordinator) else { return }
        let now = environment.now()
        while true {
            let key = held.keys.first
            if let k = key, ops.first.map({ k.typedAt < $0.at }) ?? true {
                if !decideFirstKey(a, now: now) { return }
            } else if let op = ops.first {
                if !run(op, a, now: now) { return }
                if ops.first === op { ops.removeFirst() }
            } else {
                return
            }
        }
    }

    /// The first held key: admitted, discarded, or (false) not decidable yet.
    private func decideFirstKey(_ a: Active, now: UInt64) -> Bool {
        guard let k = held.keys.first else { return true }
        // B4 (b): never held longer than the cap.
        if now > k.typedAt, now - k.typedAt > held.maxAge { held.dropFirst(); lose(1, .bracket); sealGap(at: k.typedAt, now: now); return true }
        // The worker publishes the start under a lock before acquiring facts. Sample it here, not in a queued
        // start callback: a main-queue delay must not expire keys before an already completed read is delivered.
        // Only this main-owned route mutates the engine; epoch/enable gates exclude stale and page reads.
        if let start = control.undeliveredFullReadStart(after: lastDeliveredStart, epoch: control.epoch) {
            engine.readStarted(at: start)
        }
        let anchor = max(k.typedAt, max(burst.quietFrom ?? 0, intakeQuietFrom ?? 0))
        let lean = engine.lastVerified?.facts.contains(.url) == false
        let floor: [ChromeFact: UInt64] = lean ? [.axURL: anchor &+ ChromeBracketTiming.metadataSettleNanoseconds] : [:]
        switch engine.decide(typedAt: k.typedAt, now: now, minimumBSent: floor) {
        case .wait:
            return false
        case .discard:
            held.dropFirst(); lose(1, .bracket); sealGap(at: k.typedAt, now: now)
            return true
        case .admit(let ra, let rb):
            // B3 barrier: an input event the OS has seen but main has not processed yet may be a boundary inside
            // this bracket: wait for it (briefly), then discard.
            if let latest = environment.latestInput?(), latest > lastInputAt &+ ChromeBracketTiming.pendingInputSlackNanoseconds {
                let since = barrierSince ?? now
                barrierSince = since
                if now - since < ChromeBracketTiming.barrierWaitNanoseconds { schedulePump(); return false }
                barrierSince = nil
                held.dropFirst(); lose(1, .bracket); sealGap(at: k.typedAt, now: now); return true
            }
            barrierSince = nil
            // B2: the key-time refs equal the bracketing reads' refs (every read in between is equal to ra).
            guard ra.window.matches(object: k.window.object), ra.focus.matches(object: k.focus.object), let pid, ra.pid == pid,
                  let rawA = proofs[ra.id], let rawB = proofs[rb.id],
                  let pa = rawA.settledMetadata(anchor: anchor, requireURL: false),
                  let pb = rawB.settledMetadata(anchor: anchor) else {
                held.dropFirst(); lose(1, .bracket); sealGap(at: k.typedAt, now: now); return true
            }
            guard let (key, chars) = held.takeFirst() else { return true }
            let intent: KeyIntent
            switch key.kind {
            case .text: intent = .insertText(chars)
            case .accent: intent = .accent(chars)
            case .edit(let op): intent = .edit(op)
            }
            do {
                // perFact: the engine's b-side observations (one per fact) were all sent after the key; their earliest
                // send is the burst's witness (the b-side read itself may have started before the key).
                let bSide = engine.rule == .perFact ? engine.admittedBSideSent : nil
                let pendingBefore = burst.session.pendingUnits, savedBefore = bracketDiagnostics.savedUnits
                let step = try burst.bracketedKey(intent, ra: pa, rb: pb, typedAt: key.typedAt, now: now, policy: a.context.policy,
                                                  deferCommit: finishing != nil, bSideSent: bSide, beforeEdit: editedRecipient, write: { try write($0, a) })
                if step != .dropped {
                    bracketDiagnostics.keyAdmitted()
                    bracketDiagnostics.admitUnits(burst.session.pendingUnits - pendingBefore + bracketDiagnostics.savedUnits - savedBefore)
                } else if burst.dropReason == .stale {
                    // Refused by the burst's own admission check after the engine bracketed it: this key is lost (not
                    // admitted, `keys.lost.admission`); fail closed, the unit was retracted and `reconcileKeys` counts its
                    // admitted keys dropped (`keys.dropped`, reason retract inside).
                    lose(1, .admission)
                } else {
                    // The gate or a latch refused it (privacy: never counted).
                    privacyContext = true
                }
            } catch {
                drop(.focus); failed(a.coordinator, error); return false
            }
            return true
        }
    }
    /// A key lost in the middle of a unit: the unit is sealed there, so text on either side of it is never one.
    private func sealGap(at t: UInt64, now: UInt64) {
        guard burst.session.hasLive else { burst.discard(); return }
        burst.discard()
        burst.session.seal(.gap, now: now, focusMoved: false)
    }
    private func schedulePump() {
        guard !pumpScheduled else { return }
        pumpScheduled = true
        environment.schedule(0.002) { [weak self] in self?.pumpScheduled = false; self?.pump() }
    }
    /// Whether every read that started before `t` has been handled on main.
    private func readsBeforeHandled(_ t: UInt64) -> Bool {
        !control.startedBetween(after: lastDeliveredStart, before: t)
    }
    /// The first result of the kind asked for, from a read that started at or after `t`.
    private func result(after t: UInt64, page: Bool) -> BrowserTypingJoinResult? {
        for entry in results where entry.start >= t && entry.page == page {
            if let proof = entry.result.proof {
                guard let metadata = proof.settledMetadata(anchor: t) else { continue }
                return .allowed(metadata)
            }
            return entry.result
        }
        return nil
    }
    /// Asks the loop for a read (a save's or a click join) and says whether to keep waiting.
    private func need(_ page: Bool, after t: UInt64, now: UInt64) -> BrowserTypingJoinResult?? {
        if let r = result(after: t, page: page) {
            if let d = r.denial, Self.privacyDenials.contains(d) { privacyContext = true }
            return .some(r)
        }
        // A save waits at most the proof TTL for its read; then it is refused like a join that timed out.
        if now > t, now - t > BrowserTypingTiming.proofTTLNanoseconds { return .some(.denied(.timeout)) }
        if page { control.wantPage() } else { control.wantFull() }
        ensureLoop()
        return .none
    }

    /// Runs one queued boundary op; false while it waits.
    private func run(_ op: Op, _ a: Active, now: UInt64) -> Bool {
        guard readsBeforeHandled(op.at) else { return false }
        // Existing work must keep its ordered boundary, but cannot consume a
        // unit through a writer suppressed by the finish token. Only .finish
        // may store, under a new proof whose read started after the cutoff.
        if let f = finishing {
            if case .finish = op.kind {} else {
                guard op.at <= f.cutoff else { return true }
                switch op.kind {
                case .split(let reason), .save(let reason):
                    // A later safe departure proves draft retention, not a send
                    // from the original composer at the queued key boundary.
                    let deferredReason: SealReason = [.submit, .submitChord, .mailSend].contains(reason) ? .focusKey : reason
                    burst.session.seal(deferredReason, now: now, focusMoved: false)
                    if case .save = op.kind { burst.noteDisruptive(at: op.at) }
                    return true
                case .click(let reason):
                    burst.boundary(reason, at: op.at, now: now, focusMoved: reason == .pointer)
                    return true
                case .idle:
                    burst.session.seal(.idle, now: now, focusMoved: false)
                    return true
                case .settle:
                    // Preserve already parked parts for cutoff-fresh resolution.
                    return true
                default: break
                }
            }
        }
        let write: (TypingCommit) throws -> Bool = { [unowned self] in try self.write($0, a) }
        do {
            switch op.kind {
            case .finish(let id):
                guard let f = finishing, f.id == id, finishAuthority(f) else { finishEnded(id); return true }
                guard let got = need(false, after: f.cutoff, now: now) else { return false }
                let full = got
                var page: BrowserTypingJoinResult?
                if full?.denial == .field, burst.session.parkedCount > 0, burst.last != nil {
                    guard let got = need(true, after: f.cutoff, now: now) else { return false }
                    page = got
                }
                saveFinish(full, page: page, a: a, finish: f)
            case .dropUnread:
                // A key in the refusal hold follows a privacy refusal (never counted); one in the quiet period is not.
                if op.privacy { privacyContext = true }
                if let h = burst.heldUntil, op.at < h { privacyContext = true }
                burst.discard(); burst.session.retract()
            case .leave(let reason):
                burst.boundary(reason, at: op.at, now: now, focusMoved: true)
            case .escape:
                burst.escape(at: op.at, now: now)
            case .retract:
                burst.session.retract(); burst.noteDisruptive(at: op.at)
            case .gap:
                burst.boundary(.gap, at: op.at, now: now, focusMoved: false)
            case .inputSource:
                burst.boundary(.inputSource, at: op.at, now: now, focusMoved: true)
            case .split(let reason), .save(let reason):
                // M5: only admitted keys are in the session; the save needs a read that started after the boundary.
                if burst.session.hasLive || burst.pending {
                    guard let got = need(false, after: op.at, now: now) else { return false }
                    _ = try burst.commit(got!, typedAt: op.at, processedAt: now, reason: reason, policy: a.context.policy, write: write)
                } else {
                    burst.discard()
                    burst.session.seal(reason, now: now, focusMoved: false)
                }
                if case .save = op.kind { burst.noteDisruptive(at: op.at) }
            case .click(let reason):
                if burst.session.hasLive, environment.secureInput() == false {
                    guard let got = need(true, after: op.at, now: now) else { return false }
                    _ = try burst.pointerDown(got!, at: op.at, now: now, policy: a.context.policy, reason: reason, write: write)
                } else if environment.secureInput() {
                    drop(.secureInput); return true
                }
                if reason == .pointer { burst.boundary(.pointer, at: op.at, now: now, focusMoved: true) }
            case .idle:
                guard environment.secureInput() == false else { drop(.secureInput); return true }
                guard burst.session.hasLive else { return true }
                guard let got = need(false, after: op.at, now: now) else { return false }
                _ = try burst.commit(got!, typedAt: nil, processedAt: now, reason: .idle, policy: a.context.policy, write: write)
                if let due = burst.session.idleDeadline, due <= now { burst.session.retract() }
            case .settle:
                var secure = environment.secureInput()
                guard burst.session.nextParkedDeadline != nil else { return true }
                var full: BrowserTypingJoinResult? = nil
                if !secure {
                    if let got = op.settleFull { full = got } else {
                        guard let got = need(false, after: op.at, now: now) else { return false }
                        op.settleFull = .some(got); full = got
                    }
                }
                var page: BrowserTypingJoinResult? = nil
                if !secure, full?.denial == .field, burst.last != nil {
                    guard let got = need(true, after: op.at, now: now) else { return false }
                    page = got
                }
                if !secure { secure = environment.secureInput() }
                for _ in 0...Self.limits.maxParked {
                    guard try burst.resolveParked(full, page: page, secureInput: secure, now: now, policy: a.context.policy, write: write) != nil else { break }
                }
                if let due = burst.session.nextParkedDeadline, due <= now { drop(.focus); return true }
            }
        } catch {
            drop(.focus); failed(a.coordinator, error); return true
        }
        refreshTimers()
        return true
    }
}
#endif
