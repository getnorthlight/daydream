// DD-RECIPE: CAPTURE
//
// Capture input (golden test 5). The actual EventCapture and Coordinator on synthetic stores under TMPDIR, permissions
// faked on, in-memory key stores, a fake clock and a fake scheduler. EventCapture is never started: no event tap, no
// Accessibility read, no permission request, no app launch. The distributed notifications use names of their own.
//   G3   an input tap macOS turned off is turned back on (or made again); recording stops only when neither works.
//   G7   a key handled late (the main thread was busy) is read when nothing could have moved focus since a key read on
//        time in that same field, and never otherwise; late keys found unsafe afterwards are dropped, never the text
//        typed on time before them. Late keys join the open draft (nothing is written early), so its end decides it as
//        with no stall: the typing pause drops it, a secret completed across the stall drops its sentence, Backspace
//        edits across it (review round 1). Nothing that may hold late keys is written before they are decided: vouched
//        for (an event typed after them, then 1 s with no change heard; or 30 s with nothing typed) or dropped (a
//        change in the backlog or heard within that second, recording stopping first). The rig runs work already due
//        between keys, as the main run loop does (gold/r2-typing, golden 5 G7). Each backlog of late keys is decided on
//        its own, nothing that waits is dropped to make room, what a decision frees is written at once, and a privacy
//        boundary decides the late keys first (gold/r2-typing review round 1: `lateStreak`). The typing pause (its chord
//        or the menu) decides them first too, whichever of the tap's callback and the hot key's handler runs first: a
//        line ended and judged on time before a stall is kept (gold/r3-typing, the test 5 gate's item 1: `pauseChord`).
//   G3/G7 through the tap's callback (`handleTap`, real CGEvents with their own times): a tap macOS turned off keeps
//        recording; a click, a modifier change and a system key each count as a focus move; the tap listens to them.
//   G41  app notifications an app refused at an app switch are registered again, a few times.
//   G58  the input-source change is heard while DayDream is in the background.
//   G8 / G74b  source pins: every snapshot element answers within a short timeout, and the app-notification source
//        runs in the common run-loop modes.
// 237f6fb preserves safe ASCII spaces at certified typed-piece edges. Exact expected rows below retain the
// spaces already typed before each late-key cut or clean-head boundary; no comparison trims or ignores them.
// Compiled like production-event-capture-checks.swift: the capture file list from scripts/daydream-core-source-checks.py
// plus the app dependency objects, once plain and once with the owner flags. Run from the repository root.
import Foundation
import AppKit
import ApplicationServices
import HistoryCore
@testable import MemoryCore
import PrivacyPolicy

/// One synthetic recorder: a store, a coordinator recording with typing on, and an EventCapture on a fake clock.
final class Rig {
    var mono: UInt64 = 10_000_000_000
    var focus = "field-a", bundle = "com.apple.Notes", role = "AXTextArea", subrole = "", known = true
    /// Characters read (only `key` counts; focus-moving keys use `press`).
    var reads = 0
    var timers: [(at: UInt64, work: () -> Void)] = []
    let store: MemoryStore
    let coordinator: Coordinator
    private(set) var capture: EventCapture!
    init(_ root: URL, _ name: String) throws {
        store = try MemoryStore(home: root.appendingPathComponent(name), writable: true, automaticallySyncSearch: false)
        try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore())); try store.setUpTypedVault(); try store.acceptSafeTyping()
        coordinator = try Coordinator(store: store, permissions: { true }) {}
        let environment = EventCapture.TypingEnvironment(
            now: { [unowned self] in self.mono },
            proof: { [unowned self] generation, version in
                guard self.known else { return nil }
                var p = FocusProof(); p.generation = generation; p.policyVersion = version; p.checkedAt = self.mono
                p.bundle = self.bundle; p.windowID = "window"; p.focusID = self.focus; p.role = self.role; p.subrole = self.subrole
                p.surface = .native; p.secureInput = .no; p.privateMode = .no
                p.verified = true; p.fieldStateVerified = true; p.frameAccessible = true; p.navigationStable = true
                return p
            },
            schedule: { [unowned self] delay, work in self.timers.append((self.mono + UInt64(delay * 1_000_000_000), work)) },
            secureInput: { false },
            departure: { [unowned self] in DepartureState(secureInput: .no, bundle: self.bundle, focusSecure: .unknown) },
            pressAndHold: { true })
        capture = EventCapture(coordinator: coordinator, typingEnvironment: environment)
        try coordinator.start()
        var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try store.updatePolicy(policy)
        coordinator.captureText = true
    }
    /// Runs the fake timers due within `seconds`, in order.
    func advance(_ seconds: Double) {
        let target = mono + UInt64(seconds * 1_000_000_000)
        while let i = timers.indices.filter({ timers[$0].at <= target }).min(by: { timers[$0].at < timers[$1].at }) {
            let timer = timers.remove(at: i); mono = max(mono, timer.at); timer.work()
        }
        mono = target
    }
    /// The moment `ago` seconds before now.
    func at(_ ago: Double) -> UInt64 { mono - UInt64(ago * 1_000_000_000) }
    /// A key typed `ago` seconds before it is handled (now), with its text. Work already due runs after it, before the
    /// next event, as on the main run loop, where a timer due now runs between two tap events, late ones included
    /// (gold/r2-typing, golden 5 G7: with timers run only by `advance`, a zero-delay settle never ran between keys).
    func key(_ text: String, ago: Double = 0) {
        capture.handleNativeKey(eventAt: at(ago), stroke: KeyStroke(keyCode: 0)) { reads += 1; return text }; advance(0)
    }
    /// A key that is not text (Tab, Esc, a chord, Return).
    func press(_ stroke: KeyStroke, ago: Double = 0) { capture.handleNativeKey(eventAt: at(ago), stroke: stroke) { "" }; advance(0) }
    /// Saves what is pending: the live unit now (or parked), then every parked unit after the settle.
    func settle() { capture.flushNativeText(); advance(1) }
    /// Nothing typed for longer than `EventCapture.lateQuietNanoseconds` (30 s): late keys that nothing typed after
    /// them vouched for are vouched for by the quiet, and what held them is written.
    func quiet() { advance(31) }
    /// The words of every saved typed row (record bodies hold none: they are read back through the store).
    func words() throws -> [String] {
        try store.rows("SELECT id FROM typed_text ORDER BY id").compactMap { try store.hydrateTypedText($0[0], disclosure: .owner) }
    }
    func saved(_ text: String) throws -> Bool { try words().contains { $0.contains(text) } }
    /// Types `text` one character per key, `every` seconds apart, each handled on time.
    func type(_ text: String, every: Double = 0.1) {
        for c in text { advance(every); capture.handleNativeKey(eventAt: mono, stroke: KeyStroke(keyCode: 0)) { reads += 1; return String(c) }; advance(0) }
    }
    /// Keys typed while the main thread was busy: one character per key, the first `startAgo` seconds ago, `every`
    /// seconds apart, all handled now.
    func typeLate(_ text: String, startAgo: Double, every: Double = 0.1) {
        var ago = startAgo
        for c in text { capture.handleNativeKey(eventAt: at(ago), stroke: KeyStroke(keyCode: 0)) { reads += 1; return String(c) }; advance(0); ago -= every }
    }
    func markers(_ kind: String) throws -> Int { try store.actions(limit: 200).actions.filter { $0.kind == kind }.count }
}

@main struct CaptureInputChecks {
    static var checks = 0, failures = 0
    /// DD_CHECK_KEEP_GOING=1 lists every failing check instead of stopping at the first (to show a fix's checks all
    /// fail on the tree before it). The suite always stops at the first.
    static let keepGoing = ProcessInfo.processInfo.environment["DD_CHECK_KEEP_GOING"] == "1"
    static func check(_ condition: Bool, _ name: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
            if keepGoing { failures += 1; return }
            exit(1)
        }
        checks += 1; print("PASS " + name)
    }
    static func spin(_ seconds: TimeInterval, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }
    static func source(_ path: String) -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { check(false, "read \(path) (run from the repository root)"); return "" }
        return text
    }
    static func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }
    #if DAYDREAM_OWNER_TYPING
    /// Owner build: website typing never uses the live Chrome witness here (as in production-event-capture-checks).
    static func installFakeWebRoute() {
        WebTypingRoute.shared=WebTypingRoute(environment:WebTypingRoute.Environment(now:{DispatchTime.now().uptimeNanoseconds},join:{_,_,_ in .denied(.disabled)},
            schedule:{_,_ in},secureInput:{false},pressAndHold:{true},secondsSinceMouseDown:{nil},directKeyboardInput:{true}))
    }
    #endif

    static func main() throws {
        setbuf(stdout, nil)
        #if DAYDREAM_OWNER_TYPING
        installFakeWebRoute()
        #endif
        // Key focus follows the synthetic front app; nothing asks Accessibility or the running apps.
        NativeTypingRoute.keyFocus = { 4242 }
        NativeTypingRoute.bundleOf = { _ in "com.apple.Notes" }
        // No test here may touch a real tap or a real app's notifications.
        EventCapture.reenableTap = { _ in check(false, "no real tap is turned on"); return false }
        EventCapture.remakeTap = { _ in check(false, "no real tap is made"); return false }
        EventCapture.registerAX = { _, _, _ in check(false, "no real app is observed"); return (nil, true) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-input-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        try inputSourceDelivery()
        try lateKeys(root)
        try lateDraft(root)
        try lateStreak(root)
        try pauseChord(root)
        try tapTurnedOff(root)
        try tapCallback(root)
        try appNotifications(root)
        try messagesConversationCache(root)
        sourcePins()
        if failures > 0 { FileHandle.standardError.write(Data("FAIL: \(failures) capture-input checks failed\n".utf8)); exit(1) }
        print("PASS all \(checks) capture-input checks. Synthetic stores, fake clock; no tap, app, Accessibility read or permission.")
    }

    // MARK: G58 — the input-source change while DayDream is in the background

    static func inputSourceDelivery() throws {
        let center = DistributedNotificationCenter.default()
        let tag = UUID().uuidString
        let name = Notification.Name("com.getnorthlight.daydream.checks.input-source-" + tag)
        let other = Notification.Name("com.getnorthlight.daydream.checks.input-source-block-" + tag)
        var heard = 0, offMain = 0, blockHeard = 0
        var listener: InputSourceListener? = InputSourceListener(name: name) { heard += 1; if !Thread.isMainThread { offMain += 1 } }
        // For comparison, the observer the recorder had before (the block API, default suspension behavior).
        let block = center.addObserver(forName: other, object: nil, queue: .main) { _ in blockHeard += 1 }
        // DayDream in the background: AppKit has suspended its distributed center.
        center.suspended = true
        center.postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: false)
        center.postNotificationName(other, object: nil, userInfo: nil, deliverImmediately: false)
        spin(5) { heard == 1 }
        check(heard == 1, "G58: an input-source change is heard while DayDream is in the background")
        spin(0.5) { false }
        check(blockHeard == 0, "G58: the old block observer hears nothing while DayDream is in the background (why keys on the new layout joined the old unit)")
        check(offMain == 0, "G58: the listener runs its handler on the main thread")
        center.suspended = false
        spin(5) { blockHeard == 1 }
        check(blockHeard == 1 && heard == 1, "G58: the old observer hears it only once DayDream is active again; the listener heard it once")
        // Released, it hears nothing more (a second listener on the name shows the post was delivered).
        var control = 0
        let second = InputSourceListener(name: name) { control += 1 }
        listener = nil
        center.postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
        spin(5) { control == 1 }
        spin(0.3) { false }
        check(control == 1 && heard == 1, "G58: a released listener is removed from the center")
        center.removeObserver(block)
        _ = (listener, second)
    }

    // MARK: G7 — keys handled late

    static func lateKeys(_ root: URL) throws {
        var n = 0
        func rig() throws -> Rig { n += 1; return try Rig(root, "late-\(n)") }
        /// "before " typed and read on time (it proves the field), then the main thread is busy for 0.6 s: `during`
        /// happens, then "after" (typed 0.3 s after "before") is handled 0.3 s late.
        func stalled(_ during: (Rig) -> Void) throws -> Rig {
            let r = try rig()
            r.advance(0.5); r.key("before ")
            r.advance(0.6)
            during(r)
            r.key("after", ago: 0.3)
            return r
        }
        /// Nothing late was read, and the text typed on time is saved.
        func refused(_ r: Rig, _ name: String) throws {
            let reads = r.reads
            r.settle()
            check(try reads == 1 && r.saved("before") && !r.saved("after"), "G7: " + name)
        }

        // Rule A: read when nothing could have moved focus.
        do {
            let r = try rig()
            r.advance(0.5); r.key("one ")
            r.advance(0.6)
            r.key("two ", ago: 0.5); r.key("three ", ago: 0.4); r.key("four", ago: 0.3)
            check(r.reads == 4, "G7: keys typed while the main thread was busy, in the field of the last key read on time, are read")
            check(try r.words().isEmpty, "G7: at the first late key nothing is written: the draft stays open until its own end (was, round 1: the text typed on time was saved at once)")
            r.settle()
            check(try r.words().isEmpty, "G7: nothing typed after the late keys yet: the settle does not write them (an event still in the backlog may show focus moved first; was: saved at the settle)")
            r.advance(28)
            check(try r.words().isEmpty, "G7: still nothing written while the late keys are undecided")
            r.quiet()
            check(try r.words() == ["one two three four"], "G7: the late keys are saved in the same row as the text typed before the stall, once 30 s with nothing typed vouch for them (was: every key handled more than 150 ms late was dropped)")
        }
        do {
            let r = try rig()
            r.advance(0.5); r.key("steady ")
            r.advance(0.6); r.key("late ", ago: 0.3)
            r.advance(0.1); r.key("prompt")
            r.capture.flushNativeText()
            check(try r.words().isEmpty, "G7: an event typed after the late keys ends the backlog, but a change heard within 1 s of the last late read may still have come first: not written yet (was: saved at once)")
            r.advance(1)
            check(try r.saved("late prompt"), "G7: an event typed after the late keys ends the backlog: the unit is saved once no change was heard within 1 s of the last late read")
        }
        do {
            let r = try rig()
            r.advance(0.5); r.key("steady ")
            r.advance(0.6); r.key("late ", ago: 0.3)
            r.advance(0.1); r.key("prompt")
            r.capture.flushNativeText()
            r.advance(0.3); r.capture.handleAX(kAXFocusedUIElementChangedNotification as String)
            r.settle(); r.quiet()
            check(try r.words() == ["steady "], "G7: the unit ended just after the late keys, then a focus change heard within 1 s of the late read: the late keys and what followed them are dropped, the text typed on time is saved (was: \"steady late prompt\" written before the change was heard)")
        }
        try refused(try stalled { $0.capture.handlePointerDown(eventAt: $0.at(0.45)) }, "a click typed before a late key: the key is not read, the text before is saved")
        try refused(try stalled { $0.press(KeyStroke(keyCode: 48), ago: 0.45) }, "Tab typed before a late key: not read")
        try refused(try stalled { $0.press(KeyStroke(keyCode: 53), ago: 0.45) }, "Esc typed before a late key: not read")
        try refused(try stalled { $0.press(KeyStroke(keyCode: 49, command: true), ago: 0.45) }, "Command-Space (Spotlight) typed before a late key: not read")
        try refused(try stalled { $0.press(KeyStroke(keyCode: 49, option: true), ago: 0.45) }, "Option-Space (a launcher) typed before a late key: not read")
        try refused(try stalled { $0.press(KeyStroke(keyCode: 49, control: true), ago: 0.45) }, "a Control chord typed before a late key: not read")
        try refused(try stalled { $0.press(KeyStroke(keyCode: 0, fn: true), ago: 0.45) }, "Fn/Globe with a letter typed before a late key: not read")
        try refused(try stalled { $0.press(KeyStroke(keyCode: 96), ago: 0.45) }, "a function key typed before a late key: not read")
        try refused(try stalled { $0.press(KeyStroke(keyCode: 177), ago: 0.45) }, "a Spotlight or Dictation key (a key code of the system row) typed before a late key: not read")
        try refused(try stalled { $0.capture.handleSystemKey(eventAt: $0.at(0.45)) }, "a system key event typed before a late key: not read")
        try refused(try stalled {
            $0.capture.handleFlagsChanged(eventAt: $0.at(0.46), flags: .maskCommand)
            $0.capture.handleFlagsChanged(eventAt: $0.at(0.45), flags: [])
        }, "a modifier pressed and let go alone (a double-tap launcher) before a late key: not read")
        try refused(try stalled { $0.capture.handleFlagsChanged(eventAt: $0.at(0.45), flags: .maskAlphaShift) }, "Caps Lock before a late key: not read")
        try refused(try stalled { $0.capture.handleAX(kAXFocusedUIElementChangedNotification as String) }, "a focus change heard before a late key: not read")
        try refused(try stalled { $0.capture.handleAX(kAXFocusedWindowChangedNotification as String) }, "a window change heard before a late key: not read")
        try refused(try stalled { $0.capture.inputSourceChanged() }, "an input-source change heard before a late key: not read")
        try refused(try stalled { r in r.capture.switchFrontmost(pid: 4242, bundle: "com.apple.Notes") { _, _ in } }, "an app switch heard before a late key: not read")
        try refused(try stalled { $0.known = false; $0.key("unproven", ago: 0.01); $0.known = true }, "a key with no focus proof before a late key: not read")
        try refused(try stalled { $0.focus = "field-b" }, "a late key whose own proof shows another field: not read")
        try refused(try stalled { $0.advance(1.9) }, "a late key typed more than 2 s after the last key read on time: not read")
        do {
            let r = try rig()
            r.advance(0.5); r.key("before ")
            r.advance(0.3); r.key("after", ago: 0.4)
            try refused(r, "a late key typed before the last key read on time: not read")
        }
        // Keys typed just after a refused late key may have gone where it did: dropped, but only they.
        do {
            let r = try stalled { $0.capture.handlePointerDown(eventAt: $0.at(0.45)) }
            r.advance(0.05); r.key("typed on", ago: 0.01)
            let reads = r.reads
            r.advance(0.5); r.key("later")
            r.settle()
            check(try reads == 1 && r.saved("before") && r.saved("later") && !r.saved("typed on") && !r.saved("after"),
                  "G7: keys typed within 400 ms of a refused late key are dropped; the text typed on time before the stall is kept (was: dropped with them)")
        }
        do {
            let r = try rig()
            r.advance(0.5); r.key("before ")
            r.advance(2.2); r.key("after", ago: 2.1)
            try refused(r, "a key handled more than 2 s after it was typed: not read")
        }
        do {
            let r = try rig()
            r.advance(0.6); r.key("after", ago: 0.3)
            r.settle()
            check(try r.reads == 0 && r.words().isEmpty, "G7: a late key with no key read on time before it (no proven field): not read")
        }
        // Not focus moves: Shift for a capital, and Fn with an arrow (macOS sets Fn on arrows itself).
        do {
            let r = try stalled {
                $0.capture.handleFlagsChanged(eventAt: $0.at(0.47), flags: .maskShift)
                $0.key("X", ago: 0.46)
                $0.capture.handleFlagsChanged(eventAt: $0.at(0.45), flags: [])
                $0.press(KeyStroke(keyCode: 123, fn: true), ago: 0.44)
            }
            r.settle(); r.quiet()
            check(try r.reads == 3 && r.saved("after"), "G7: Shift held for a capital and an arrow key don't count as a focus move: later late keys are read (saved after the quiet)")
        }

        // Rule B: late keys already read, then something in the backlog shows focus may have moved first.
        /// "before " read on time, then "two" read late (the busy main thread): `then` follows.
        func lateRead(_ then: (Rig) -> Void) throws -> Rig {
            let r = try rig()
            r.advance(0.5); r.key("before ")
            r.advance(0.6); r.key("two", ago: 0.4)
            check(r.reads == 2, "G7: setup: a late key read")
            then(r)
            r.settle()
            return r
        }
        func dropped(_ r: Rig, _ name: String) throws {
            check(try r.saved("before") && !r.saved("two"), "G7: " + name)
        }
        try dropped(try lateRead { $0.press(KeyStroke(keyCode: 53), ago: 0.2) }, "Esc typed before a late key was read (still in the backlog): the late keys are dropped, the text typed on time is kept")
        try dropped(try lateRead { $0.capture.handlePointerDown(eventAt: $0.at(0.2)) }, "a click in the backlog: the late keys are dropped")
        try dropped(try lateRead { $0.press(KeyStroke(keyCode: 49, command: true), ago: 0.2) }, "a chord in the backlog: the late keys are dropped")
        try dropped(try lateRead { $0.advance(0.5); $0.capture.handleAX(kAXFocusedUIElementChangedNotification as String) }, "a focus change heard within 1 s of a late read (it may have come first): the late keys are dropped")
        try dropped(try lateRead { r in r.advance(0.3); r.capture.switchFrontmost(pid: 4242, bundle: "com.apple.Notes") { _, _ in } }, "an app switch heard within 1 s of a late read: the late keys are dropped")
        try dropped(try lateRead { $0.focus = "field-b"; $0.advance(0.01); $0.key("three", ago: 0.05) }, "a key typed before the late read and handled on time, in another field: the late keys are dropped")
        try dropped(try lateRead { $0.focus = "field-b"; $0.key("three", ago: 0.2) }, "a late key refused while late keys are pending: they are dropped")
        try dropped(try lateRead { $0.known = false; $0.key("three", ago: 0.2); $0.known = true },
                    "a key with no focus proof while late keys are pending: they are dropped")
        do {
            let r = try lateRead { $0.known = false; $0.key("three", ago: 0.2); $0.known = true; $0.advance(0.1); $0.key(" more") }
            check(try r.words() == ["before more"], "G7: the draft typed on time stays open after that key, as after any key with no proof: the next key in its field joins it")
        }
        try dropped(try lateRead { r in r.press(KeyStroke(keyCode: 36), ago: 0.2); r.capture.switchFrontmost(pid: 4242, bundle: "com.apple.Notes") { _, _ in } },
                    "Return in the backlog parks the unit instead of saving it; the app switch heard just after drops the late keys")
        do {
            let r = try lateRead { $0.press(KeyStroke(keyCode: 36), ago: 0.2) }
            check(try r.words().isEmpty, "G7: Return in the backlog with nothing heard after: the settle judges the unit but does not write it while its late keys are undecided (was: written at the settle)")
            r.quiet()
            check(try r.saved("before two"), "G7: Return in the backlog with nothing heard after: the late keys are saved once 30 s with nothing typed vouch for them")
        }
        try dropped(try lateRead { r in r.press(KeyStroke(keyCode: 36), ago: 0.2); r.advance(0.6); r.capture.handleAX(kAXFocusedUIElementChangedNotification as String); r.quiet() },
                    "Return in the backlog, then a focus change heard 0.6 s after the late read (after the Return's settle): the late keys are dropped (was: written at the settle, before the change was heard)")
        do {
            let r = try lateRead { $0.advance(1.2); $0.capture.handleAX(kAXFocusedUIElementChangedNotification as String) }
            r.quiet()
            check(try r.saved("before two"), "G7: a focus change heard more than 1 s after the late read keeps the late keys")
        }
        // Recording stops (pause, sleep, the screen locking, quit) while the late keys are undecided: they are decided
        // then, as when the tap goes off. The text typed on time is kept.
        do {
            let r = try rig()
            r.advance(0.5); r.key("before ")
            r.advance(0.6); r.key("two", ago: 0.4)
            r.advance(0.3); r.capture.commitPendingTyping(); r.advance(1)
            check(try r.words() == ["before "], "G7: recording stops within 1 s of a late read: the late keys are dropped, the text typed on time is saved (was: \"before two\" written at once)")
        }
        do {
            let r = try rig()
            r.advance(0.5); r.key("before ")
            r.advance(0.6); r.key("two", ago: 0.4)
            r.advance(0.1); r.key(" more"); r.advance(1.2)
            r.capture.commitPendingTyping(); r.advance(1)
            check(try r.words() == ["before two more"], "G7: recording stops after the late keys were vouched for: they are saved with the rest")
        }
        // A later stall starts from its own draft: the mark of the first one was let go once its late keys were vouched for.
        do {
            let r = try rig()
            r.advance(0.5); r.key("one ")
            r.advance(0.6); r.key("two", ago: 0.4)
            r.advance(0.1); r.key(" three"); r.advance(2); r.press(KeyStroke(keyCode: 36))
            r.advance(1); r.key("five ")
            r.advance(0.6); r.key("six", ago: 0.4)
            r.capture.handlePointerDown(eventAt: r.at(0.2))
            r.settle()
            check(try r.words() == ["one two three", "five "], "G7: a second stall later, its late keys found unsafe: what was typed on time before it is kept (the first stall's mark was let go)")
        }
        // A key handled late leaves no shortcut or Return marker (as before): only its text may be read.
        do {
            let r = try rig()
            r.advance(0.5); r.key("before ")
            let markers = try r.markers("keyboard.shortcut")
            r.advance(0.6); r.press(KeyStroke(keyCode: 11, command: true), ago: 0.3)
            check(try r.markers("keyboard.shortcut") == markers, "G7: a shortcut handled late leaves no marker")
            r.advance(0.5); r.press(KeyStroke(keyCode: 11, command: true))
            check(try r.markers("keyboard.shortcut") == markers + 1, "G7: setup: the same shortcut on time leaves a marker")
        }
    }

    // MARK: G7 — the typing pause chord right after a stall (gold/r3-typing)

    /// The typing pause (Control-Option-Command-T/Y/P, or the menu) changes the typed policy, which drops everything
    /// pending. A line ended (Return) and judged on time but held for its undecided late keys was dropped with it, the
    /// text typed on time too (the test 5 gate, item 1; `a6944d3` wrote that line at Return). The pause now decides the
    /// late keys first, as a stop does (`EventCapture.typingWillPause`, called by `TypingModel.snooze` before the pause
    /// is saved), whichever runs first: the tap's callback for the chord or the hot key's handler. The rows are the
    /// r2-typing reviewer's pause.swift (28 scenarios) and adv.swift A1–A3, on the real EventCapture.
    /// Each row's first check (the line is not lost) passes on `a6944d3` and fails on `3f70834`. A late word still in
    /// doubt at the pause (read under 1 s before it, an event typed after it already seen) is dropped, as at a stop or a
    /// privacy boundary (`a6944d3` wrote it: the G7 leak); that is the second check of those rows.
    static func pauseChord(_ root: URL) throws {
        var n = 0
        func rig() throws -> Rig { n += 1; return try Rig(root, "pause-\(n)") }
        let ret = KeyStroke(keyCode: 36)
        let chord = KeyStroke(keyCode: 17, command: true, control: true, option: true) // Control-Option-Command-T
        /// The hot key's handler: `TypingModel.snooze` with the chord's own press time, then the pause saved.
        func hotkey(_ r: Rig, pressedAt: UInt64?) throws {
            r.capture.typingWillPause(chordAt: pressedAt); _ = try r.store.snoozeTyping(minutes: 10, now: Date())
        }
        /// The pause chord pressed now: the tap's callback and the hot key's handler, in either order.
        func chordNow(_ r: Rig, hotkeyFirst: Bool) throws {
            let at = r.mono
            if hotkeyFirst { try hotkey(r, pressedAt: at); r.press(chord) } else { r.press(chord); try hotkey(r, pressedAt: at) }
        }
        /// "before " read on time, then "two" read late (the stall) or on time.
        func line(_ r: Rig, stall: Bool, returnInBacklog: Bool) {
            r.advance(0.5); r.key("before ")
            if returnInBacklog {
                if stall { r.advance(0.6); r.key("two", ago: 0.4); r.press(ret, ago: 0.2) } else { r.advance(0.3); r.key("two"); r.advance(0.2); r.press(ret) }
            } else {
                if stall { r.advance(0.6); r.key("two", ago: 0.4) } else { r.advance(0.3); r.key("two") }
                r.advance(0.05); r.press(ret)
            }
        }
        func row(_ name: String, _ r: Rig, inDoubt: Bool) throws {
            let words = try r.words()
            check(words.count == 1 && words[0].hasPrefix("before") && (inDoubt || words[0] == "before two"),
                  "G7 pause: " + name + ": the ended line is saved, the text typed on time included (was, 3f70834: nothing saved) \(words)")
            if inDoubt {
                check(words == ["before "], "G7 pause: " + name + ": the late word still in doubt at the pause is not saved, as at a stop \(words)")
            }
        }
        for stall in [true, false] {
            let tag = stall ? "stall" : "steady"
            // P1: Return typed on time after the late read; the pause chord `gap` s after the late read.
            for gap in [0.3, 0.8, 1.2] {
                for hotkeyFirst in [false, true] {
                    let r = try rig()
                    line(r, stall: stall, returnInBacklog: false)
                    r.advance(gap - 0.05)
                    try chordNow(r, hotkeyFirst: hotkeyFirst)
                    r.advance(40)
                    try row("P1 [\(tag)] Return typed after, pause chord \(gap) s after the late read, \(hotkeyFirst ? "hotkey" : "tap") first", r,
                            inDoubt: stall && gap < 1)
                }
            }
            // P2: Return still in the late backlog; the pause chord is the first input `wait` s later.
            for wait in [1.5, 10.0, 29.0, 31.0] {
                for hotkeyFirst in [false, true] {
                    let r = try rig()
                    line(r, stall: stall, returnInBacklog: true)
                    r.advance(wait)
                    try chordNow(r, hotkeyFirst: hotkeyFirst)
                    r.advance(40)
                    try row("P2 [\(tag)] Return in the backlog, pause chord the first input \(wait) s later, \(hotkeyFirst ? "hotkey" : "tap") first", r, inDoubt: false)
                }
            }
            // adv A1-A3 (the reviewer's adversarial rows): Return after, chord 0.3 s later, tap then hot key, and hot key
            // then tap; Return in the backlog, the chord 5 s later, hot key first.
            do {
                let r = try rig(); line(r, stall: stall, returnInBacklog: false); r.advance(0.3); try chordNow(r, hotkeyFirst: false); r.advance(40)
                try row("A1 [\(tag)] Return after, pause chord 0.3 s later (tap first)", r, inDoubt: stall)
            }
            do {
                let r = try rig(); line(r, stall: stall, returnInBacklog: false); r.advance(0.3); try chordNow(r, hotkeyFirst: true); r.advance(40)
                try row("A2 [\(tag)] Return after, pause chord 0.3 s later (hotkey first)", r, inDoubt: stall)
            }
            do {
                let r = try rig(); line(r, stall: stall, returnInBacklog: true); r.advance(5); try chordNow(r, hotkeyFirst: true); r.advance(40)
                try row("A3 [\(tag)] Return in backlog, 5 s later pause chord (hotkey first)", r, inDoubt: false)
            }
        }
        // What the pause must still never do.
        do {
            // The chord pressed in the same backlog as the late keys (before the last of them was read), its hot key
            // handled first: nothing typed after the backlog was seen, so the late keys are never vouched for.
            let r = try rig()
            r.advance(0.5); r.key("before ")
            r.advance(0.6); r.key("two", ago: 0.4); r.press(ret, ago: 0.3)
            try hotkey(r, pressedAt: r.at(0.2)); r.press(chord, ago: 0.2); r.advance(40)
            check(try !r.saved("two"), "G7 pause: the chord pressed inside the backlog (hot key first): the late keys are not saved \(try r.words())")
        }
        do {
            // Menu pause (no chord time) with Return in the backlog and nothing typed after: the late keys are decided as
            // at a stop, never written undecided.
            let r = try rig()
            line(r, stall: true, returnInBacklog: true); r.advance(0.5)
            try hotkey(r, pressedAt: nil); r.advance(40)
            check(try !r.saved("two"), "G7 pause: the pause from the menu with the late keys undecided: they are not saved \(try r.words())")
        }
        do {
            // A press time the recorder can't place (after now: another clock) counts as unknown.
            let r = try rig()
            line(r, stall: true, returnInBacklog: true); r.advance(0.5)
            try hotkey(r, pressedAt: r.mono + 5_000_000_000); r.advance(40)
            check(try !r.saved("two"), "G7 pause: a chord time later than now is not trusted to end the backlog \(try r.words())")
        }
        do {
            // The unfinished draft is dropped at the pause, stall or not (as before), and nothing typed after it is saved.
            for stall in [true, false] {
                let r = try rig()
                r.advance(0.5); r.key("draft ")
                if stall { r.advance(0.6); r.key("late", ago: 0.4) } else { r.advance(0.3); r.key("late") }
                r.advance(1.5); try chordNow(r, hotkeyFirst: true)
                r.advance(0.2); r.key("after"); r.advance(0.1); r.press(ret); r.advance(40)
                check(try r.words().isEmpty, "G7 pause: the unfinished draft is dropped at the pause and nothing typed after it is saved [\(stall ? "stall" : "steady")] \(try r.words())")
            }
        }
        do {
            // The pause decides only the late keys: with none pending it writes nothing and changes nothing.
            let r = try rig()
            r.advance(0.5); r.key("parked "); r.capture.handlePointerDown(eventAt: r.mono)
            try hotkey(r, pressedAt: r.mono); r.advance(40)
            check(try r.words().isEmpty, "G7 pause: with no late keys the pause writes nothing (a parked unit is dropped, as before) \(try r.words())")
        }
        // Source pins: the app's pause decides the late keys before the pause is saved, and the Carbon chord time is kept.
        let model = source("Sources/MacMemApp/TypingModel.swift"), app = source("Sources/MacMemApp/MacMemApp.swift")
        let hot = source("Sources/MacMemApp/TypingHotkey.swift")
        if let hook = model.range(of: "willPause(chordAt)"), let save = model.range(of: "return try store.snoozeTyping(minutes: TypingPauseShortcut.minutes, now: now())") {
            check(hook.lowerBound < save.lowerBound, "G7 pause: TypingModel.snooze decides the late keys before the pause is saved")
        } else { check(false, "G7 pause: TypingModel.snooze calls willPause, then saves the pause") }
        check(model.contains("let chordAt = TypingHotkey.takePress()") && model.contains("snooze(frontmostBundle: front, chordAt: chordAt)"),
              "G7 pause: the shortcut passes the chord's press time")
        check(count("typing.willPause = { [weak self] chordAt in self?.capture?.typingWillPause(chordAt: chordAt) }", in: app) == 1,
              "G7 pause: the app wires the pause to its recorder")
        check(hot.contains("TypingHotkey.notePress(at: pressed > 0 ? UInt64(pressed * 1_000_000_000) : nil)"),
              "G7 pause: the Carbon handler notes when the chord was pressed")
    }

    // MARK: G7 — late keys join the open draft (review round 1)

    /// Nothing is written at the first late key: the draft's own end decides it, as if there had been no stall. Each
    /// case runs on two fresh recorders, once with the main thread busy in the middle and once without; both must save
    /// the same rows. (Round 1 saved the text typed on time at the first late key: the pause chord, a secret's sentence
    /// and Backspace no longer reached it.)
    static func lateDraft(_ root: URL) throws {
        var n = 0
        func rig() throws -> Rig { n += 1; return try Rig(root, "draft-\(n)") }
        /// Every end: the settle, the idle commit, the late-resolution window.
        func finish(_ r: Rig) throws -> [String] {
            r.advance(1); r.capture.flushNativeText(); r.advance(2); r.advance(70); r.capture.flushNativeText(); r.advance(2)
            return try r.words()
        }
        func same(_ name: String, expect: [String], stall: (Rig) throws -> Void, steady: (Rig) throws -> Void) throws {
            let a = try rig(); try stall(a); let stalled = try finish(a)
            let b = try rig(); try steady(b); let calm = try finish(b)
            check(stalled == calm && calm == expect, "G7: " + name + " (rows: \(stalled.count) with the stall, \(calm.count) without)")
        }
        let chord = KeyStroke(keyCode: 17, command: true, control: true, option: true) // the typing pause, Control-Option-Command-T
        let returnKey = KeyStroke(keyCode: 36), escape = KeyStroke(keyCode: 53), backspace = KeyStroke(keyCode: 51)
        // What the hotkey's handler does next (TypingModel.snooze): the recorder decides its late keys, then the pause is saved.
        func pause(_ r: Rig) throws { r.capture.typingWillPause(chordAt: r.mono); _ = try r.store.snoozeTyping(minutes: 10, now: Date()) }

        try same("the typing pause pressed while DayDream was busy drops the whole draft, as with no stall", expect: [], stall: { r in
            r.type("the private stuff I typed"); r.advance(0.6)
            r.typeLate(" x", startAgo: 0.5, every: 0.05); r.press(chord, ago: 0.3); try pause(r)
        }, steady: { r in r.type("the private stuff I typed"); r.advance(0.1); r.press(chord); try pause(r) })
        try same("the typing pause pressed on time seconds after a stall in the middle of the draft drops the whole draft", expect: [], stall: { r in
            r.type("the private stuff I typed"); r.advance(0.6)
            r.typeLate(" and", startAgo: 0.5, every: 0.05); r.type(" then I kept typing for a while", every: 0.12)
            r.advance(0.2); r.press(chord); try pause(r)
        }, steady: { r in
            r.type("the private stuff I typed and then I kept typing for a while", every: 0.1); r.advance(0.2); r.press(chord); try pause(r)
        })
        try same("a card number finished while DayDream was busy: its sentence is never saved (was: \"card [withheld]\")", expect: [], stall: { r in
            r.type("card 4111 1111 "); r.advance(0.6); r.typeLate("1111 1111", startAgo: 0.5, every: 0.05); r.advance(0.1); r.press(returnKey)
        }, steady: { r in r.type("card 4111 1111 1111 1111"); r.advance(0.1); r.press(returnKey) })
        try same("a password typed while DayDream was busy after its label: nothing is saved (was: \"my password is\")", expect: [], stall: { r in
            r.type("my password is "); r.advance(0.6); r.typeLate("Hunter2Zq9", startAgo: 0.5, every: 0.04); r.advance(0.1); r.press(returnKey)
        }, steady: { r in r.type("my password is Hunter2Zq9"); r.advance(0.1); r.press(returnKey) })
        try same("a key-like token finished while DayDream was busy: nothing is saved (was: \"key [withheld]\")", expect: [], stall: { r in
            r.type("key sk-proj-AbCdEf"); r.advance(0.6); r.typeLate("GhIjKlMnOpQrStUv", startAgo: 0.5, every: 0.02); r.advance(0.1); r.press(returnKey)
        }, steady: { r in r.type("key sk-proj-AbCdEfGhIjKlMnOpQrStUv"); r.advance(0.1); r.press(returnKey) })
        func search(_ r: Rig) { r.role = "AXTextField"; r.subrole = "AXSearchField"; r.focus = "search" }
        try same("a search abandoned with Esc while DayDream was busy is never saved", expect: [], stall: { r in
            search(r); r.type("private search"); r.advance(0.6); r.typeLate("x", startAgo: 0.5); r.press(escape, ago: 0.4); r.advance(0.2)
        }, steady: { r in search(r); r.type("private search"); r.type("x"); r.advance(0.1); r.press(escape) })
        try same("a Backspace typed while DayDream was busy edits the text typed before it (was: two rows, \"helo\" and \"lo world\")",
                 expect: ["please send the hello world"], stall: { r in
            r.type("please send the helo"); r.advance(0.6)
            r.press(backspace, ago: 0.5); r.typeLate("lo world", startAgo: 0.4, every: 0.04); r.advance(0.1); r.press(returnKey)
        }, steady: { r in
            r.type("please send the helo"); r.advance(0.1); r.press(backspace); r.type("lo world"); r.advance(0.1); r.press(returnKey)
        })
        try same("a late letter and two Backspaces into the text typed on time: the edit is kept whole", expect: ["please send the hello world"], stall: { r in
            r.type("please send the helo"); r.advance(0.6)
            r.typeLate("x", startAgo: 0.5); r.press(backspace, ago: 0.45); r.press(backspace, ago: 0.42)
            r.typeLate("lo world", startAgo: 0.4, every: 0.04); r.advance(0.1); r.press(returnKey)
        }, steady: { r in
            r.type("please send the helo"); r.type("x"); r.advance(0.1); r.press(backspace); r.advance(0.03); r.press(backspace)
            r.type("lo world"); r.advance(0.1); r.press(returnKey)
        })

        try same("a password typed while DayDream was busy, then a click in the backlog and more typing: nothing is saved, the app stays latched",
                 expect: [], stall: { r in
            r.type("my password is "); r.advance(0.6); r.typeLate("Hunter2", startAgo: 0.5, every: 0.04)
            r.capture.handlePointerDown(eventAt: r.at(0.05)); r.advance(0.3); r.type("Zq9")
        }, steady: { r in r.type("my password is Hunter2"); r.advance(0.1); r.capture.handlePointerDown(eventAt: r.mono); r.advance(0.3); r.type("Zq9") })

        // Late keys found unsafe afterwards: dropped alone. The draft goes back to what was typed on time, never more.
        do {
            let r = try rig()
            r.type("before words")
            r.advance(0.6); r.press(backspace, ago: 0.5); r.press(backspace, ago: 0.45); r.typeLate("xy", startAgo: 0.4)
            r.capture.handlePointerDown(eventAt: r.at(0.2))
            check(try finish(r) == ["before words"], "G7: late Backspaces and letters, then a click in the backlog: the text typed on time comes back whole")
        }
        do {
            let r = try rig()
            r.type("my password is "); r.advance(0.6); r.typeLate("Hunter2Zq9", startAgo: 0.5, every: 0.04)
            r.capture.handlePointerDown(eventAt: r.at(0.05))
            check(try finish(r).isEmpty, "G7: a draft dropped because a late key finished a secret stays dropped when the late keys are found unsafe")
        }
        try same("a secret finished while DayDream was busy, then a click in the backlog: the draft is dropped whole, as with no stall",
                 expect: [], stall: { r in
            r.type("Meeting notes. my pass"); r.advance(0.6); r.typeLate("word is Hunter2Zq9", startAgo: 0.5, every: 0.02)
            r.capture.handlePointerDown(eventAt: r.at(0.05))
        }, steady: { r in r.type("Meeting notes. my password is Hunter2Zq9"); r.capture.handlePointerDown(eventAt: r.mono) })
        try same("the sentences before a secret stay cut where the secret began (never back to the cut, \"my pass\")",
                 expect: ["Meeting notes. "], stall: { r in
            r.type("Meeting notes. my pass"); r.advance(0.6); r.typeLate("word: Hunter2Zq9", startAgo: 0.5, every: 0.02)
            r.capture.handlePointerDown(eventAt: r.at(0.05))
        }, steady: { r in r.type("Meeting notes. my password: Hunter2Zq9"); r.capture.handlePointerDown(eventAt: r.mono) })
        do {
            let r = try rig()
            r.type("Hello"); r.advance(1.0); r.typeLate(" there. My password: Hunter2Zq9", startAgo: 0.9, every: 0.02)
            r.capture.handlePointerDown(eventAt: r.at(0.05))
            check(try finish(r) == ["Hello"], "G7: a clean head that holds late keys goes back to the text typed on time when they are found unsafe (the rig runs due work between keys; was: \"Hello there.\" written by its zero-delay settle before the click was handled)")
        }
        try same("a clean head that holds late keys, vouched for by a click typed after them: saved as with no stall", expect: ["Hello there. "], stall: { r in
            r.type("Hello"); r.advance(1.0); r.typeLate(" there. My password: Hunter2Zq9", startAgo: 0.9, every: 0.02)
            r.advance(0.1); r.capture.handlePointerDown(eventAt: r.mono)
        }, steady: { r in r.type("Hello there. My password: Hunter2Zq9"); r.advance(0.1); r.capture.handlePointerDown(eventAt: r.mono) })
        do {
            let r = try rig()
            r.type("hello "); r.advance(1.0)
            r.typeLate("secret", startAgo: 0.9, every: 0.1); r.press(returnKey, ago: 0.3); r.typeLate(" world", startAgo: 0.2, every: 0.03)
            r.advance(0.05); r.capture.handleAX(kAXFocusedWindowChangedNotification as String)
            check(try finish(r) == ["hello "], "G7: Return in the backlog, then a window change heard at once: only the text typed on time is saved")
        }
    }

    // MARK: G7 review round 1 (gold/r2-typing) — late keys that keep coming, many lines, a privacy boundary next

    /// Round 1 found three ways the G7 hold lost text typed on time (7158fb4). One cut held every line until 1 s passed
    /// with no late read, so a stall about once a second kept every line waiting, the 4-unit parked list silently
    /// dropped the oldest, and one change heard dropped every line back to the first cut. A line vouched for was
    /// written by a timer, after a key typed straight into a password field had dropped it. Now each backlog of late
    /// keys is decided on its own, a unit that waits is never dropped to make room, what a decision frees is written at
    /// once, and a privacy boundary decides the late keys first, keeping the text typed on time.
    static func lateStreak(_ root: URL) throws {
        var n = 0
        func rig() throws -> Rig { n += 1; return try Rig(root, "streak-\(n)") }
        let ret = KeyStroke(keyCode: 36)
        /// One chat line at 0.1 s a key. Every `stallEvery` keys the main thread is busy for 0.3 s: the next two keys,
        /// typed during it, are handled late together. Then Return, typed and handled on time.
        func line(_ r: Rig, _ text: String, stallEvery: Int = 4) {
            let chars = Array(text); var i = 0
            while i < chars.count {
                if i > 0 && i % stallEvery == 0 && i + 1 < chars.count {
                    r.advance(0.3); r.key(String(chars[i]), ago: 0.2); r.key(String(chars[i + 1]), ago: 0.16); i += 2; continue
                }
                r.advance(0.1); r.key(String(chars[i])); i += 1
            }
            r.advance(0.1); r.press(ret)
        }
        func password(_ r: Rig, _ app: Bool) { if app { r.bundle = "com.1password.1password"; r.focus = "pm" } else { r.subrole = "AXSecureTextField"; r.focus = "pw" } }
        func back(_ r: Rig) { r.subrole = ""; r.bundle = "com.apple.Notes"; r.focus = "field-a" }
        let chat = ["see you at noon", "bring the slides", "and the laptop", "room four b", "thanks a lot", "ok bye now", "one more thing", "the door code"]
        do {
            let r = try rig()
            r.advance(0.5)
            for m in chat { line(r, m) }
            r.advance(1.5)
            check(try r.words().sorted() == chat.sorted(), "G7 round 1: eight chat lines with a short stall about every half second (two keys handled late each time), Return after each: every line is saved within 1.5 s of the last (was, 7158fb4: the first four lost)")
        }
        do {
            let r = try rig()
            r.advance(0.5)
            for m in chat.prefix(4) { line(r, m) }
            // "room four b": "room" on time, " f" late, "ou" on time, "r " late (read 0.3 s before its Return), "b" on time.
            r.advance(0.45); r.capture.handlePointerDown(eventAt: r.mono)
            r.advance(0.1); r.focus = "field-b"; r.capture.handleAX(kAXFocusedUIElementChangedNotification as String)
            r.advance(1); r.quiet()
            check(try r.words().sorted() == ["and the laptop", "bring the slides", "room fou", "see you at noon"],
                  "G7 round 1: four such lines, then a click in another window, its focus change heard within 1 s of the last late keys: the three lines before are saved whole, the fourth goes back to what was typed on time before those late keys (was, 7158fb4: only \"see\")")
        }
        do {
            let r = try rig()
            r.advance(0.5)
            for m in chat.prefix(2) { line(r, m) }
            // "bring the slides": its last late keys ("id") are read 0.3 s before its Return, the ones before ("e ") 0.8 s.
            r.advance(0.4); r.capture.commitPendingTyping(); r.advance(1)
            check(try r.words().sorted() == ["bring the sl", "see you at noon"], "G7 round 1: recording stops 0.7 s after the last late keys: the line before is saved whole, the last goes back to what was typed on time before those keys (was, 7158fb4: every line back to the first cut)")
        }
        do {
            let r = try rig()
            r.advance(0.5)
            let messages = ["hey", "you free", "lunch?", "noon", "or 1", "lmk"]
            for m in messages {
                r.type(String(m.dropLast()), every: 0.08)
                r.advance(0.25); r.key(String(m.last!), ago: 0.2)
                r.advance(0.05); r.press(ret)
                r.advance(0.2)
            }
            r.advance(2)
            check(try r.words().sorted() == messages.sorted(), "G7 round 1: six short chat messages, the last letter of each handled 0.2 s late, Return on time: all six are saved (was, 7158fb4: \"you free\" dropped by the 4-unit parked list)")
        }
        do {
            let r = try rig()
            r.advance(0.5); r.key("before ")
            r.advance(0.6); r.key("two", ago: 0.4)
            r.advance(0.05); r.press(ret)
            let quick = ["ok", "yes", "sure", "fine", "cool", "great", "done"]
            for w in quick { r.type(w, every: 0.02); r.advance(0.02); r.press(ret) }
            r.advance(2)
            check(try r.words().sorted() == (["before two"] + quick).sorted(), "G7 round 1: eight lines ended within the second after late keys all wait for them, then all eight are saved (was, 7158fb4: the oldest dropped to keep four parked)")
        }
        // A privacy boundary next: the key that vouches for the late keys, or comes within the second they are in doubt,
        // goes straight into a password field or a password manager (no click or shortcut first).
        for app in [false, true] {
            let r = try rig()
            let place = app ? "a password manager" : "a password field"
            r.advance(0.5); r.key("before ")
            r.advance(0.6); r.key("two", ago: 0.4); r.press(ret, ago: 0.2)   // Return typed before "two" was read: in the backlog
            r.advance(5)
            password(r, app); r.key("x"); back(r); r.advance(40)
            check(try r.words() == ["before two"], "G7 round 1: Return in the backlog, then 5 s later the first event is a key typed straight into \(place): it vouches for the late keys, and the line is saved before that key drops what is pending (was, 7158fb4: lost; the write waited for a timer)")
        }
        for app in [false, true] {
            let r = try rig()
            let place = app ? "a password manager" : "a password field"
            r.advance(0.5); r.key("before ")
            r.advance(0.6); r.key("two", ago: 0.4)
            r.advance(0.05); r.press(ret)
            r.advance(0.5); password(r, app); r.key("x"); back(r); r.advance(40)
            check(try r.words() == ["before "], "G7 round 1: Return typed after late keys, then 0.5 s later a key typed straight into \(place), within the second they are in doubt: they are dropped, the text typed on time before them is saved (was, 7158fb4: nothing; a6944d3 also wrote the undecided late keys)")
        }
        do {
            let r = try rig()
            r.advance(0.5); r.key("before ")
            r.advance(0.6); r.key("two", ago: 0.4)
            r.advance(0.05); r.press(ret)
            r.advance(0.3); password(r, false); r.capture.handleAX(kAXFocusedUIElementChangedNotification as String)
            r.advance(0.1); r.key("x"); back(r); r.advance(40)
            check(try r.words() == ["before "], "G7 round 1: Return typed after late keys, then focus moves to a password field (heard within 1 s) and a key is typed there: the text typed on time is saved, the late keys are not (was, 7158fb4: nothing)")
        }
        do {
            let r = try rig()
            r.advance(0.5); r.key("before ")
            r.advance(0.6); r.key("two", ago: 0.4)
            r.advance(0.3); password(r, false); r.key("x"); back(r); r.advance(40)
            let steady = try rig()
            steady.advance(0.5); steady.key("before "); steady.advance(0.3); steady.key("two")
            steady.advance(0.3); password(steady, false); steady.key("x"); back(steady); steady.advance(40)
            check(try r.words().isEmpty && steady.words().isEmpty, "G7 round 1: a draft still open when a key goes straight into a password field is dropped, as with no stall (a boundary writes only what was judged on time)")
        }
    }

    // MARK: G3 — an input tap macOS turned off

    static func tapTurnedOff(_ root: URL) throws {
        var reenables = 0, remakes = 0, reenableWorks = true, remakeWorks = true, tapOn = true
        EventCapture.reenableTap = { _ in reenables += 1; return reenableWorks }
        EventCapture.remakeTap = { _ in remakes += 1; return remakeWorks }
        EventCapture.tapIsOn = { _ in tapOn }
        defer {
            EventCapture.reenableTap = { _ in check(false, "no real tap is turned on"); return false }
            EventCapture.remakeTap = { _ in check(false, "no real tap is made"); return false }
            EventCapture.tapIsOn = { _ in true }
        }
        let logBefore = DiagnosticsLog.shared.recent(1000).count
        let r = try Rig(root, "tap")
        var stops = 0
        r.capture.onStopped = { stops += 1 }
        r.advance(0.5); r.key("typed before the tap went off ")
        r.capture.tapDisabled(byTimeout: true)
        check(reenables == 1 && remakes == 0 && r.coordinator.isRunning && !r.capture.isStopped && stops == 0,
              "G3: a tap macOS turned off (timeout) is turned back on and recording goes on (was: recording paused until Resume)")
        r.advance(1)
        check(try r.saved("typed before the tap went off"), "G3: what was typed before the tap went off is saved after the settle")
        // No key read late across the gap: keys and clicks went by unseen.
        r.advance(0.2); r.key("anchor ")
        r.advance(0.4); r.capture.tapDisabled(byTimeout: false)
        let reads = r.reads
        r.key("typed before the gap", ago: 0.3)
        check(r.reads == reads && reenables == 2, "G3: a key typed before the tap went off and handled late is not read (user-input disable turned back on too)")
        // Late keys already read when the tap goes off are dropped; the text typed on time is kept.
        r.advance(1); r.key("steady ")
        r.advance(0.6); r.key("late words", ago: 0.4)
        r.capture.tapDisabled()
        r.settle()
        check(try r.saved("steady") && !r.saved("late words"), "G3: late keys pending when the tap goes off are dropped, the text typed on time is kept")
        r.advance(1); r.key("calm ")
        r.advance(0.6); r.key("backlog words", ago: 0.4)
        r.advance(1.5); r.capture.tapDisabled()
        r.settle()
        check(try r.saved("calm") && !r.saved("backlog words"),
              "G3: late keys still waiting for an event typed after them are dropped when the tap goes off, even well after they were read")
        // The heartbeat: a tap that went off without telling (no callback) is recovered the same way.
        tapOn = false; r.capture.heartbeat(); tapOn = true
        check(reenables == 5, "G3: the heartbeat finds a tap that went off without a callback and turns it back on")
        r.capture.heartbeat()
        check(reenables == 5, "G3: a tap that is on is left alone")
        // Won't turn back on: made again.
        reenableWorks = false
        r.capture.tapDisabled()
        check(remakes == 1 && r.coordinator.isRunning && !r.capture.isStopped, "G3: a tap that won't turn back on is made again, recording goes on")
        let lines = DiagnosticsLog.shared.recent(1000).dropFirst(logBefore).filter { $0.contains("Input tap") }
        check(lines.count == 1 && lines.allSatisfy { !$0.contains("typed") && !$0.contains("words") && !$0.contains("field") },
              "G3: one content-free log line a minute, however often the tap goes off (\(lines.count))")
        // Neither: recording stops like a tap that couldn't be made at Start (the app keeps it wanted: model checks).
        remakeWorks = false
        r.capture.tapDisabled()
        check(!r.coordinator.isRunning && r.capture.isStopped && stops == 1 && r.coordinator.session.reason == "Input tap was disabled. Resume explicitly.",
              "G3: only when no tap can be had does recording stop, with the input-tap reason")
        let all = DiagnosticsLog.shared.recent(1000).dropFirst(logBefore).filter { $0.contains("Input tap") }
        check(all.count == 2 && all.last?.contains("couldn't be made again") == true, "G3: the stop is logged")
    }

    // MARK: G3 / G7 — through the tap's callback

    /// CGEvent times are mach ticks on Apple silicon (`EventCapture.eventNanoseconds`): the ticks for `ns`.
    /// fix/sx-all round 1: the Messages conversation name is cached for 3 s per window; a click, a Return or a
    /// focus-moving key drops it, so a reply typed right after switching conversations is filed under the new one.
    static func messagesConversationCache(_ root: URL) throws {
        var rows = ["Riley", "ok", "Now"]
        MessagesConversation.rowTexts = { _ in rows }
        MessagesConversation.windowKey = { _ in "one-window" }
        MessagesConversation.forget()
        let r = try Rig(root, "messages-cache")
        check(MessagesConversation.name(pid: 42) == "Riley", "messages cache: the selected conversation is read")
        rows = ["Q7", "on my way", "Now"]
        check(MessagesConversation.name(pid: 42) == "Riley", "messages cache: within 3 s and with no signal, the cached name stands (the walk is skipped)")
        r.capture.handlePointerDown(eventAt: r.mono)
        check(MessagesConversation.name(pid: 42) == "Q7", "messages cache: a click drops the cached name (a quick reply after switching goes to the new conversation)")
        rows = ["Sam", "sure", "Now"]
        r.press(KeyStroke(keyCode: 36))
        check(MessagesConversation.name(pid: 42) == "Sam", "messages cache: a Return (a send) drops the cached name")
        rows = ["Priya", "yes", "Now"]
        r.press(KeyStroke(keyCode: 30, command: true))
        check(MessagesConversation.name(pid: 42) == "Priya", "messages cache: a focus-moving chord (Command-]) drops the cached name")
        MessagesConversation.forget()
    }

    static func ticks(_ ns: UInt64) -> UInt64 {
        let tb = EventCapture.machTimebase
        return tb.denom == 0 || tb.numer == tb.denom ? ns : ns * UInt64(tb.denom) / UInt64(tb.numer)
    }
    /// An event as the tap's callback delivers it, typed at `at` (the rig's clock). Built here; nothing is posted.
    static func tapEvent(_ type: CGEventType, at: UInt64, flags: CGEventFlags = [], keyCode: Int64 = 0, text: String? = nil) -> CGEvent {
        let event: CGEvent
        if type == .keyDown { event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)! }
        else { event = CGEvent(source: nil)!; event.type = type }
        event.flags = flags
        event.timestamp = ticks(at)
        if let text {
            let units = Array(text.utf16)
            units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
        }
        return event
    }

    static func tapCallback(_ root: URL) throws {
        var reenables = 0, remakes = 0
        EventCapture.reenableTap = { _ in reenables += 1; return true }
        EventCapture.remakeTap = { _ in remakes += 1; return false }
        EventCapture.tapIsOn = { _ in true }
        defer {
            EventCapture.reenableTap = { _ in check(false, "no real tap is turned on"); return false }
            EventCapture.remakeTap = { _ in check(false, "no real tap is made"); return false }
        }
        check(DispatchTime.now().uptimeNanoseconds > 120_000_000_000 && EventCapture.eventNanoseconds(ticks(12_000_000_000)) == 12_000_000_000,
              "G7: setup: an event's own time (mach ticks) reads back on the rig's clock")
        var n = 0
        func rig() throws -> Rig { n += 1; return try Rig(root, "callback-\(n)") }

        // G3: the callback macOS makes when it turns the tap off.
        let r = try rig()
        var stops = 0
        r.capture.onStopped = { stops += 1 }
        r.advance(0.5); r.key("typed before the tap went off ")
        r.capture.tapEventForChecks(.tapDisabledByTimeout, CGEvent(source: nil)!)
        check(reenables == 1 && remakes == 0 && r.coordinator.isRunning && !r.capture.isStopped && stops == 0,
              "G3: the tap's callback for a tap macOS turned off (timeout) turns it back on and recording goes on (was: paused, stopped for good)")
        r.capture.tapEventForChecks(.tapDisabledByUserInput, CGEvent(source: nil)!)
        check(reenables == 2 && r.coordinator.isRunning && !r.capture.isStopped && stops == 0,
              "G3: the same for a tap turned off by user input")
        for _ in 0..<50 { r.capture.tapEventForChecks(.tapDisabledByTimeout, CGEvent(source: nil)!) }
        check(reenables == 52 && remakes == 0 && r.coordinator.isRunning && !r.capture.isStopped && stops == 0,
              "G3: fifty in a row through the callback: recording goes on")
        r.advance(1)
        check(try r.saved("typed before the tap went off"), "G3: what was typed before is saved after the settle")

        // G7: the tap-visible focus moves, delivered through the callback with their own times.
        do {
            let r = try rig()
            r.advance(0.5); r.key("before ")
            r.advance(0.6)
            r.capture.tapEventForChecks(.keyDown, tapEvent(.keyDown, at: r.at(0.3), text: "k"))
            r.settle(); r.quiet()
            check(try r.words() == ["before k"], "G7: setup: a key event typed while DayDream was busy, with nothing before it, is read through the callback into the same field")
        }
        /// "before " read on time, then the main thread is busy; `during` goes through the callback, then a key typed
        /// 0.3 s ago (after it) arrives through the callback too. It must not be read.
        func late(_ name: String, _ during: (Rig) -> Void) throws {
            let r = try rig()
            r.advance(0.5); r.key("before ")
            r.advance(0.6)
            during(r)
            r.capture.tapEventForChecks(.keyDown, tapEvent(.keyDown, at: r.at(0.3), text: "k"))
            r.settle()
            check(try r.words() == ["before "], "G7: " + name)
        }
        for (type, button) in [(CGEventType.leftMouseDown, "left"), (.rightMouseDown, "right"), (.otherMouseDown, "other")] {
            try late("a click (\(button) button) through the tap's callback before a late key: the key is not read") {
                $0.capture.tapEventForChecks(type, tapEvent(type, at: $0.at(0.45)))
            }
        }
        try late("a modifier pressed and let go alone, through the tap's callback, before a late key: not read") {
            $0.capture.tapEventForChecks(.flagsChanged, tapEvent(.flagsChanged, at: $0.at(0.47), flags: .maskCommand))
            $0.capture.tapEventForChecks(.flagsChanged, tapEvent(.flagsChanged, at: $0.at(0.46)))
        }
        try late("Caps Lock through the tap's callback before a late key: not read") {
            $0.capture.tapEventForChecks(.flagsChanged, tapEvent(.flagsChanged, at: $0.at(0.45), flags: .maskAlphaShift))
        }
        let system = CGEventType(rawValue: EventCapture.systemDefinedEvent)!
        try late("a system key (NX_SYSDEFINED) through the tap's callback before a late key: not read") {
            $0.capture.tapEventForChecks(system, tapEvent(system, at: $0.at(0.45)))
        }
        try late("Command-Space as a key event through the tap's callback before a late key: not read") {
            $0.capture.tapEventForChecks(.keyDown, tapEvent(.keyDown, at: $0.at(0.45), flags: .maskCommand, keyCode: 49))
        }
        // Late keys already read, then a click typed before them waits in the backlog: they are dropped, the rest kept.
        do {
            let r = try rig()
            r.advance(0.5); r.key("before ")
            r.advance(0.6)
            r.capture.tapEventForChecks(.keyDown, tapEvent(.keyDown, at: r.at(0.4), text: "k"))
            r.capture.tapEventForChecks(.leftMouseDown, tapEvent(.leftMouseDown, at: r.at(0.2)))
            r.settle()
            check(try r.words() == ["before "], "G7: a click through the tap's callback, typed before a late key was read: the late key is dropped, the text typed on time kept")
        }

        // The tap listens to exactly these events.
        let mask = EventCapture.tapMask
        func listens(_ type: UInt32) -> Bool { mask & (CGEventMask(1) << CGEventMask(type)) != 0 }
        let wanted: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        check(wanted.allSatisfy { listens($0.rawValue) } && EventCapture.systemDefinedEvent == 14 && listens(14),
              "G7: the tap listens to keys, modifier changes, mouse buttons and system keys (NX_SYSDEFINED): the focus moves a late key is checked against")
        check(mask == wanted.reduce(CGEventMask(1) << 14) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) },
              "G7: and to nothing else (no key-up, pointer move or scroll)")
    }

    // MARK: G41 — app notifications registered again

    static func appNotifications(_ root: URL) throws {
        var calls: [(pid: pid_t, names: [String])] = [], answers: [Bool] = []
        EventCapture.registerAX = { pid, names, _ in calls.append((pid, names)); return (nil, answers.isEmpty ? true : answers.removeFirst()) }
        defer { EventCapture.registerAX = { _, _, _ in check(false, "no real app is observed"); return (nil, true) } }
        let r = try Rig(root, "ax")
        func front(_ pid: pid_t) { r.capture.switchFrontmost(pid: pid, bundle: "com.apple.Notes") { pid, chrome in r.capture.observeAppForChecks(pid: pid, chrome: chrome) } }
        answers = [false, false, true]
        front(4242)
        check(calls.count == 1, "G41: an app switch registers the app's notifications once")
        r.advance(0.5)
        check(calls.count == 2 && calls[1].pid == 4242, "G41: a registration the app refused is tried again 0.5 s later (was: never, until the next app switch)")
        r.advance(2)
        check(calls.count == 3, "G41: and again 2 s after that; it worked")
        r.advance(20)
        check(calls.count == 3, "G41: nothing more once registered")
        calls = []; answers = [false, false, false, false, false]
        front(4242); r.advance(30)
        check(calls.count == 4, "G41: an app that keeps refusing is tried four times in all, then left until the next app switch")
        calls = []; answers = [false, true]
        front(4242); front(5151); r.advance(10)
        check(calls.map(\.pid) == [4242, 5151], "G41: a retry for an app no longer in front does nothing")
        calls = []; answers = [false]
        front(4242); r.capture.stop(reason: "Recording stopped"); r.advance(10)
        check(calls.count == 1, "G41: a retry after recording stopped does nothing")
        let c = try Rig(root, "ax-chrome")
        calls = []; answers = [true]
        c.capture.observeAppForChecks(pid: 4343, chrome: true)
        check(calls.count == 1 && calls[0].names == [kAXFocusedWindowChangedNotification, kAXTitleChangedNotification],
              "G41: Google Chrome still gets only the window and title notifications")
    }

    // MARK: G8 / G74b / G58 source pins

    static func sourcePins() {
        let capture = source("Sources/MacMemApp/EventCapture.swift")
        let snapshot = source("Sources/MacMemApp/AccessibilitySnapshot.swift")
        check(!capture.contains(".defaultMode") && count("AXObserverGetRunLoopSource(", in: capture) >= 3
              && capture.components(separatedBy: "\n").filter { $0.contains("AXObserverGetRunLoopSource(") }.allSatisfy { $0.contains(".commonModes") },
              "G74b: the app-notification source is added and removed in the common run-loop modes (was: default mode, held during menus)")
        check(AccessibilityReader.snapshotTimeout == 0.25 && AccessibilityReader.snapshotBudgetNanoseconds == 500_000_000,
              "G8: a snapshot call answers within 0.25 s, a snapshot within 0.5 s in all")
        check(snapshot.contains("let appElement = bounded(AXUIElementCreateApplication(pid))") && count(".map(bounded)", in: snapshot) >= 4
              && count("overBudget()", in: snapshot) >= 4,
              "G8: every element a snapshot reads (app, window, focus, the final checks) has the timeout, and the read gives up over budget")
        check(capture.contains("AXUIElementSetMessagingTimeout(appElement, AccessibilityReader.snapshotTimeout)"),
              "G8: registering an app's notifications has the timeout too")
        let all = ["Sources/MacMemApp/AccessibilitySnapshot.swift", "Sources/MacMemApp/EventCapture.swift", "Sources/MacMemApp/ChromeTypingWitness.swift",
                   "Sources/MacMemApp/NativeFocusWitness.swift"].map(source).joined()
        check(!all.contains("AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide") && !all.contains("AXUIElementSetMessagingTimeout(systemWide"),
              "G8: no timeout is set on the system-wide element (it would apply to every app)")
        let timer = capture.components(separatedBy: "let timer = Timer(timeInterval: 0.5, repeats: true)").dropFirst().first?
            .components(separatedBy: "timer.tolerance").first ?? ""
        check(timer.contains("self?.heartbeat()"),
              "G3: the 0.5 s heartbeat checks the tap every tick (a tap turned off with no callback is found)")
        let install = capture.components(separatedBy: "private func installEventTap() -> Bool {").dropFirst().first?
            .components(separatedBy: "private func removeEventTap()").first ?? ""
        check(install.contains("eventsOfInterest: Self.tapMask") && count("eventsOfInterest:", in: capture) == 1,
              "G7: the tap is made with that mask")
        check(capture.contains("Unmanaged<EventCapture>.fromOpaque(userInfo).takeUnretainedValue().handleTap(type: type, event: event)"),
              "G3: the tap's C callback hands every event to handleTap")
        check(capture.contains("InputSourceListener(name:Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))")
              && !capture.contains("DistributedNotificationCenter.default().addObserver(forName"),
              "G58: the recorder hears the input-source change through the immediate-delivery listener")
    }
}
