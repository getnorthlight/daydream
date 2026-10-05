#if DAYDREAM_CHROME_TYPING
// Compiled only with -DDAYDREAM_CHROME_TYPING: every release build defines it; a plain swift build leaves this file out.
// Nothing in EventCapture, Coordinator or AccessibilitySnapshot calls this;
// only the owner build's WebTypingRoute does (website typing, typing-all
// SPEC-LATER 4.2). It is the OS side of BrowserTypingJoin.
import AppKit
import ApplicationServices
import Carbon
import MemoryCore
import Security

/// claude/crashguard-015: secure keyboard input (HIToolbox, `IsSecureEventInputEnabled`) and the frontmost app
/// (`NSWorkspace`), for website typing. Both are read on the main queue only: they belong to the same OS family as the
/// key translation that trapped off the main queue on macOS 15 (owner laptop 10/04), and they have never been run off
/// it there. On the main queue each read is live, as before, and kept; elsewhere (the route's executor, a join on the
/// tap thread) the value last read on the main queue is answered. The main queue reads them again for every input
/// event at the tap and every heartbeat (0.5 s) while recording (`EventCapture`), and for every Chrome key before its
/// work is handed over (`WebTypingRoute.intake`). Fail closed: before the first read, or when the last one is older than
/// `staleAfter` (the main thread stalled), secure input reads as on (refuse) and no app reads as frontmost.
enum MainInputFacts {
    static let staleAfter: UInt64 = 2_000_000_000
    private static let lock = NSLock()
    private static var secure = true
    private static var front: pid_t?
    private static var readAt: UInt64?
    /// Reads both now on the main queue and keeps them. Does nothing anywhere else.
    static func refresh() {
        guard MainQueue.isCurrent else { return }
        _ = readLive()
    }
    /// Secure input is on, or (off the main queue) was at the last fresh main-queue read; true when unknown.
    static func secureInput() -> Bool {
        if MainQueue.isCurrent { return readLive().secure }
        lock.lock(); defer { lock.unlock() }
        return fresh ? secure : true
    }
    /// The frontmost app's PID, read the same way; nil when unknown.
    static func frontmostPID() -> pid_t? {
        if MainQueue.isCurrent { return readLive().front }
        lock.lock(); defer { lock.unlock() }
        return fresh ? front : nil
    }
    /// Called with `lock` held.
    private static var fresh: Bool {
        guard let readAt else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= readAt && now - readAt <= staleAfter
    }
    private static func readLive() -> (secure: Bool, front: pid_t?) {
        MainQueue.require()
        let s = IsSecureEventInputEnabled()
        let f = NSWorkspace.shared.frontmostApplication?.processIdentifier
        lock.lock(); secure = s; front = f; readAt = DispatchTime.now().uptimeNanoseconds; lock.unlock()
        return (s, f)
    }
}

/// Accessibility + target-identity adapter for `BrowserTypingJoin`.
/// Reads metadata only: roles, parents, window frames, the focused window's
/// title, the one AXWebArea's AXURL, the focused field's labels (deny-only)
/// and whether a combo box (or a gated C1 QA search match) is its own editable root.
/// Never a field's value (after a send gesture only whether it is empty, `composeSnapshot`), selection, the clipboard or window lists from the
/// window server. Never sets any AX attribute, so it never switches on
/// Chrome's heavier screen-reader accessibility mode.
final class ChromeTypingWitness {
    /// QF-17: which join design this witness serves, fixed at creation from the one switch the route also uses
    /// (`WebTypingRoute.Environment.live`), so the route and the witness can't disagree.
    let design: ChromeJoinDesign
    private let join: BrowserTypingJoin<AXUIElement>
    /// fix/chrome-large-pages: the page search answers an exhausted form walk in production and QA (default true).
    private let formSearchRecoveryEnabled: Bool
    /// Launch-stable target facts and a short-lived Automation answer (per-key cost).
    private let facts = ChromeTargetFactsCache()
    /// QF-17 (M4), bracketed design only: the one serial queue that owns this witness and all join state
    /// (`previous`, `departedPage`, the facts cache, document and focus IDs) while the bracketed design runs.
    /// Its read loop runs here and nowhere else. The synchronous design never uses it: it stays as before QF-17,
    /// behind one serial executor's guards (privacy review part B, PB3): the main thread then, the route's own executor
    /// since claude/chrome-offmain-1003 (`executor`).
    let queue = DispatchQueue(label: "daydream.chrome-typing.join")
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()
    init(design: ChromeJoinDesign, formSearchRecoveryEnabled: Bool = true) {
        self.formSearchRecoveryEnabled = formSearchRecoveryEnabled
        self.design = design
        join = BrowserTypingJoin<AXUIElement>(design: design)
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(queue))
    }
    private var onOwnQueue: Bool { DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(queue) }
    /// claude/chrome-offmain-1003: the synchronous design's one serial executor (`WebTypingRoute.Environment.executor`),
    /// set once when the route is made, before any read. nil: the main thread, as before. Either way one serial executor
    /// owns this witness and all join state, and every synchronous read refuses to run anywhere else.
    var executor: TypingRouteExecutor?
    private var onRouteExecutor: Bool { executor.map { $0.isCurrent } ?? Thread.isMainThread }
    func invalidate() {
        if design == .synchronous { join.invalidate(); facts.invalidate(); return }
        queue.async { [self] in join.invalidate(); facts.invalidate() }
    }

    /// fix/chrome-capture: the Post check (`BrowserTypingJoin.submitControl`) for a plain left press at a global point,
    /// right after a click join (`read(... anyFocus: true)`) of this witness proved `page`. Reads nothing else.
    func submitControl(pid: pid_t, x: Double, y: Double, page: BrowserTypingJoinProof, focusID: String, names: Set<String>,
                       enabled: @escaping () -> Bool) -> Result<BrowserSubmitPress, BrowserSubmitDenial> {
        guard onRouteExecutor else { return .failure(.typingOff) }
        return join.submitControl(at: x, y, pid: pid, page: page, focusID: focusID, names: names,
                                  environment: Self.environment(pid: pid, enabled: enabled, facts: facts), accessibility: Self.access(pid: pid, formSearchRecoveryEnabled: formSearchRecoveryEnabled))
    }

    /// One full, double-read join against the running Chrome `pid`.
    /// `enabled` must be the private build's separate browser-typing consent
    /// and runtime state; the join returns `.disabled` before any read otherwise.
    /// `sites` is the person's website choices for the full address (read and
    /// dropped): a page they don't allow is `.blockedSite`. `field` is asked
    /// of the address and the focused field's labels (a message composer on a
    /// site outside the categories follows Messages and email).
    func read(pid: pid_t, enabled: @escaping () -> Bool, blockList: BrowserTypingBlockList, alwaysBlocked: [String],
              sites: (String) -> Bool = { _ in true },
              field: (String, BrowserTypingFieldLabels) -> Bool = { _, _ in true }, anyFocus: Bool = false) -> BrowserTypingJoinResult {
        if design == .synchronous {
            // Apple Events and AX block; production capture runs them on the route's one serial executor (main without one).
            guard onRouteExecutor else { join.invalidate(); return .denied(.disabled) }
            // fix/chrome-root: a key's full join (not a click join) reports Apple Events that got no answer to the tally.
            let session = ChromeModeReader.JoinSession(pid: pid, tally: !anyFocus)
            let result = join.join(environment: Self.environment(pid: pid, enabled: enabled, facts: facts), appleEvents: session.reply,
                                   accessibility: Self.access(pid: pid, formSearchRecoveryEnabled: formSearchRecoveryEnabled), blockList: blockList, alwaysBlocked: alwaysBlocked, sites: sites, field: field,
                                   anyFocus: anyFocus)
            // fix/web-textbox (battery): a page or field refusal keeps Chrome's cached facts.
            facts.after(result.denial)
            return result
        }
        // QF-17 bracketed design: only on this witness's own queue (M4); never on main (M9).
        guard onOwnQueue else { return .denied(.disabled) }
        let session = ChromeModeReader.JoinSession(pid: pid, budget: TimeInterval(ChromeBracketTiming.readBudgetNanoseconds) / 1_000_000_000,
                                                   eventTimeout: TimeInterval(ChromeBracketTiming.eventTimeoutNanoseconds) / 1_000_000_000)
        let result = join.join(environment: Self.environment(pid: pid, enabled: enabled, facts: facts), appleEvents: session.reply,
                               accessibility: Self.access(pid: pid, formSearchRecoveryEnabled: formSearchRecoveryEnabled), blockList: blockList, alwaysBlocked: alwaysBlocked, sites: sites, field: field,
                               anyFocus: anyFocus)
        facts.after(result.denial)
        return result
    }

    /// The light per-key check between full joins (`BrowserTypingJoin.light`,
    /// review G51): two window-list Apple Events, every window's mode and a
    /// few Accessibility reads, within its own budget. nil: it can't vouch for
    /// the key, and the full join decides.
    func light(pid: pid_t, enabled: @escaping () -> Bool, blockList: BrowserTypingBlockList, alwaysBlocked: [String],
               sites: (String) -> Bool = { _ in true },
               field: (String, BrowserTypingFieldLabels) -> Bool = { _, _ in true }) -> BrowserTypingJoinResult? {
        // The bracketed design never uses the light check (M3).
        guard design == .synchronous else { return nil }
        guard onRouteExecutor else { join.invalidate(); return nil }
        let session = ChromeModeReader.JoinSession(pid: pid, budget: TimeInterval(BrowserTypingTiming.lightBudgetNanoseconds) / 1_000_000_000)
        return join.light(environment: Self.environment(pid: pid, enabled: enabled, facts: facts), appleEvents: session.reply,
                          accessibility: Self.access(pid: pid, formSearchRecoveryEnabled: formSearchRecoveryEnabled), blockList: blockList, alwaysBlocked: alwaysBlocked, sites: sites, field: field)
    }

    /// claude/xtyping-1005: wakes Chrome's accessibility when Chrome comes to the front (`BrowserTypingJoin.wake`): the
    /// join's own checks and mode gate, then Chrome's application role, nothing else. Synchronous design, on the route's
    /// executor only. When Chrome is already awake it stops before any Apple Event.
    func wake(pid: pid_t, enabled: @escaping () -> Bool) -> Bool {
        guard design == .synchronous, onRouteExecutor else { return false }
        let session = ChromeModeReader.JoinSession(pid: pid, budget: TimeInterval(BrowserTypingTiming.lightBudgetNanoseconds) / 1_000_000_000)
        return join.wake(environment: Self.environment(pid: pid, enabled: enabled, facts: facts), appleEvents: session.reply,
                         accessibility: Self.access(pid: pid, formSearchRecoveryEnabled: formSearchRecoveryEnabled))
    }

    /// Codex 07:10 (field hold, `BrowserTypingJoin.holdsRefusedBox`): whether focus is still in the box the last full
    /// join refused as `field`. Reads which app, window and element have focus and secure input; nothing else.
    func holdsRefusedBox(pid: pid_t) -> Bool? {
        guard onRouteExecutor else { join.invalidate(); return false }
        return join.holdsRefusedBox(accessibility: Self.access(pid: pid, formSearchRecoveryEnabled: formSearchRecoveryEnabled))
    }

    /// claude/int-1003 (compose-send/v1): the composer the last full join proved, read again after a Return or
    /// Command-Return (`BrowserTypingJoin.composeSnapshot`, at `BrowserComposeSignals.checks`): still in the page, focused,
    /// empty, and the route's compose kind. Whether it is empty is its character count (AXNumberOfCharacters), never the
    /// text. Accessibility only, no Apple Event; synchronous design on main only (the bracketed design has no trail).
    func composeSnapshot(pid: pid_t) -> BrowserComposeSnapshot? {
        guard design == .synchronous, onRouteExecutor else { return nil }
        return join.composeSnapshot(accessibility: Self.access(pid: pid, formSearchRecoveryEnabled: formSearchRecoveryEnabled)) { node in
            Self.characterCount(node).map { $0 == 0 ? "" : "-" }
        }
    }
    /// A field's AXNumberOfCharacters (an integer, never its text); nil when unsupported or unreadable (then only a
    /// closed composer or a route change can confirm).
    private static func characterCount(_ node: AXUIElement) -> Int? {
        guard case .value(let v) = copy(node, .numberOfCharacters) else { return nil }
        return v as? Int
    }

    /// QF-17 bracketed field hold: the box the last bracketed read refused as `field`, as refs. Called on `queue` right
    /// after that read (the one place join state lives, M4); never on main.
    func refusedBoxRefs(pid: pid_t) -> (window: ChromeRef, focus: ChromeRef)? {
        guard design == .bracketed, onOwnQueue else { return nil }
        return join.refusedBoxRefs(accessibility: Self.access(pid: pid))
    }

    static func environment(pid: pid_t, enabled: @escaping () -> Bool, facts: ChromeTargetFactsCache = ChromeTargetFactsCache()) -> ChromeJoinEnvironment {
        ChromeJoinEnvironment(now: { DispatchTime.now().uptimeNanoseconds }, enabled: enabled,
                              target: { targetFacts(pid: pid, cache: facts) },
                              automationPermitted: { facts.permitted(pid: $0, launch: launchIdentity(pid: $0), now: DispatchTime.now().uptimeNanoseconds,
                                                                     read: { ChromeEventSender.permission(pid: $0) }) },
                              launchIdentity: { launchIdentity(pid: $0) })
            .withAccessibilityJoin()
    }

    /// pid + launch date + bundle ID; a relaunch is a different target.
    static func launchIdentity(pid: pid_t) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return ChromeEventSender.launchIdentity(app)
    }

    /// Signature (Google, Team EQHXZ8M8AV) of the running code, the version
    /// read from the Chrome bundle, and how many Chrome processes are running.
    /// A bundle identifier alone can be copied.
    static func targetFacts(pid: pid_t, cache: ChromeTargetFactsCache? = nil) -> ChromeTargetFacts? {
        guard let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier,
              let identity = launchIdentity(pid: pid), let bundleURL = app.bundleURL else { return nil }
        // Read once per Chrome launch (an Info.plist and a directory listing).
        let versions = cache?.versions(launch: identity) { ChromeTargetPolicy.bundleVersions(at: bundleURL) } ?? ChromeTargetPolicy.bundleVersions(at: bundleURL)
        // A second `--user-data-dir` instance is another application process
        // with this bundle ID; its windows are invisible to this process's
        // Apple Events. Helpers and app shims have other bundle IDs. A headless
        // or automation Chrome (no window, not in front) is not the person's
        // and is not counted (`ChromeProcesses`, live test build 7).
        let instances = ChromeEventSender.userProcessCount(frontmost: MainInputFacts.frontmostPID())
        return ChromeTargetFacts(pid: pid, bundleID: bundleID, launchIdentity: identity,
                                 signatureValid: signatureValid(pid: pid), bundleVersion: versions.bundleVersion,
                                 frameworkVersions: versions.frameworkVersions, instances: instances)
    }
    private static func signatureValid(pid: pid_t) -> Bool { ChromeEventSender.signatureValid(pid: pid) }

    /// Every Accessibility attribute this witness can read. Nothing else can
    /// be named: `copy` takes only this type (checked by
    /// scripts/check_browser_boundary.py). No value, selection or text range.
    enum Attribute: String, CaseIterable {
        case role = "AXRole", subrole = "AXSubrole", parent = "AXParent"
        case focusedWindow = "AXFocusedWindow", focusedElement = "AXFocusedUIElement", windows = "AXWindows"
        case position = "AXPosition", size = "AXSize", minimized = "AXMinimized"
        case title = "AXTitle", url = "AXURL"
        case description = "AXDescription", placeholder = "AXPlaceholderValue"
        case domIdentifier = "AXDOMIdentifier", domClassList = "AXDOMClassList"
        /// An element reference (metadata): AXComboBox, or the gated C1 search sentinel/editable-group root.
        case editableAncestor = "AXEditableAncestor"
        /// fix/chrome-capture: whether a button is enabled; asked only of the button under a Post click.
        case enabled = "AXEnabled"
        /// fix/chrome-capture (QF-11, QF-3): element references (metadata) of the containers around a typed field.
        case children = "AXChildren"
        /// claude/int-1003 (compose-send/v1): how many characters the proven composer holds, read only after a Return or
        /// Command-Return (`composeSnapshot`): whether it emptied. A count, never the value.
        case numberOfCharacters = "AXNumberOfCharacters"
        /// claude/axjoin-1005 (the Accessibility join): the focused window's AXDocument, its active tab's address
        /// (compared with the page's AXURL, as the tab's Apple Events URL was); asked only after every window answered "normal".
        case document = "AXDocument"
        /// claude/axjoin-1005: whether Chrome's profile button has an accessible description (Incognito and Guest
        /// windows do). Presence only: the value is never decoded, compared or kept.
        case customContent = "AXCustomContent"
    }

    /// Created on first use, which is after every Chrome window answered
    /// "normal": no Accessibility object for Chrome exists before the gate.
    private final class LazyApplication {
        let pid: pid_t
        private var made: (element: AXUIElement, ready: Bool)?
        init(pid: pid_t) { self.pid = pid }
        /// The element under a global point (Accessibility's hit test on Chrome's application element), with this
        /// file's timeout. Only the Post check asks, after the click join proved the page.
        func element(at x: Double, _ y: Double) -> AXUIElement? {
            guard AXIsProcessTrusted(), let root = element else { return nil }   // perm-1004
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(root, Float(x), Float(y), &hit) == .success else { return nil }
            return hit
        }
        var element: AXUIElement? {
            guard AXIsProcessTrusted() else { return nil }   // perm-1004: never an Accessibility read while untrusted
            if made == nil {
                let app = AXUIElementCreateApplication(pid)
                made = (app, AXUIElementSetMessagingTimeout(app, 0.025) == .success)
            }
            return made!.ready ? made!.element : nil
        }
    }

    static func access(pid: pid_t, formSearchRecoveryEnabled: Bool = true) -> ChromeAXAccess<AXUIElement> {
        let app = LazyApplication(pid: pid)
        var access = ChromeAXAccess<AXUIElement>(
            frontmostPID: { MainInputFacts.frontmostPID() },
            // Shared with the native witness. No timeout is set on the
            // system-wide element: AXUIElementSetMessagingTimeout on it sets the
            // default for every Accessibility call in this process.
            systemFocusedPID: { AccessibilityReader.systemFocusedApplication() },
            secureInput: { MainInputFacts.secureInput() },
            focusedWindow: { app.element.flatMap { element($0, .focusedWindow) } },
            windows: {
                guard let root = app.element, case .value(let v) = copy(root, .windows), let list = v as? [AnyObject],
                      list.count <= BrowserTypingTiming.maxWindows else { return nil }
                var out: [AXUIElement] = []
                for item in list {
                    guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
                    out.append(item as! AXUIElement)
                }
                return out
            },
            focusedElement: { app.element.flatMap { element($0, .focusedElement) } },
            owner: owner,
            role: { optionalString($0, .role) },
            subrole: { optionalString($0, .subrole) },
            parent: { element($0, .parent) },
            frame: { node in
                guard case .value(let position) = copy(node, .position), CFGetTypeID(position) == AXValueGetTypeID(),
                      case .value(let size) = copy(node, .size), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
                var p = CGPoint.zero, s = CGSize.zero
                guard AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
                return ChromeBounds(x: Double(p.x), y: Double(p.y), width: Double(s.width), height: Double(s.height))
            },
            minimized: { node in
                guard case .value(let v) = copy(node, .minimized) else { return nil }
                return v as? Bool
            },
            title: { node in
                guard case .value(let v) = copy(node, .title) else { return nil }
                return v as? String
            },
            url: { node in
                guard case .value(let value) = copy(node, .url) else { return nil }
                if let url = value as? URL { return url.absoluteString }
                return value as? String
            },
            fieldLabels: { node in
                // Absent labels are fine; a failed read denies.
                var texts: [String] = [], identifiers: [String] = []
                for name in [Attribute.title, .description, .placeholder] {
                    guard let s = optionalString(node, name) else { return nil }
                    if !s.isEmpty { texts.append(s) }
                }
                guard let id = optionalString(node, .domIdentifier) else { return nil }
                if !id.isEmpty { identifiers.append(id) }
                switch copy(node, .domClassList) {
                case .missing: break
                case .failed: return nil
                case .value(let v):
                    guard let classes = v as? [String], classes.count <= BrowserTypingFieldRules.maxLabels else { return nil }
                    identifiers += classes
                }
                return BrowserTypingFieldLabels(texts: texts, identifiers: identifiers)
            },
            equal: { CFEqual($0, $1) },
            editableAncestor: { element($0, .editableAncestor) },
            elementAt: { app.element(at: $0, $1) },
            enabled: { node in
                guard case .value(let v) = copy(node, .enabled) else { return nil }
                return v as? Bool
            },
            controlNames: { node in
                // A button's own names, compared with the site's control names and dropped. nil if either can't be read.
                guard let title = optionalString(node, .title), let description = optionalString(node, .description) else { return nil }
                return [title, description]
            },
            children: { node in childList(copy(node, .children)) },
            formSearch: { page, predicate, limit in formSearch(page: page, predicate: predicate, limit: limit) })
        access.formControlNames = { node, late in Self.formControlNames(node, late: late) }
        // claude/axjoin-1005: the Accessibility join's seams (`ChromeAXAccess.offersAccessibilityJoin`).
        access.document = { node in
            guard case .value(let value) = copy(node, .document) else { return nil }
            if let url = value as? URL { return url.absoluteString }
            return value as? String
        }
        if getWindow != nil { access.windowIdentity = { windowNumber($0) } }
        access.viewClasses = { node in
            switch copy(node, .domClassList) {
            case .missing: return []
            case .failed: return nil
            case .value(let v): return v as? [String]
            }
        }
        access.described = { node in
            switch copy(node, .customContent) { case .missing: return false; case .failed: return nil; case .value: return true }
        }
        access.formSearchRecoveryEnabled = formSearchRecoveryEnabled
        // claude/xtyping-1005: Chrome's application role, read and dropped; asking is what wakes Chrome's accessibility.
        access.wake = { app.element.map { if case .value = copy($0, .role) { return true }; return false } ?? false }
        return access
    }
    /// claude/axjoin-1005: a window's number in the window server (stable for the window's lifetime), from
    /// Accessibility's own `_AXUIElementGetWindow`, looked up once at run time. Unavailable: the seam isn't wired, so
    /// `offersAccessibilityJoin` is false and every join takes the full Apple Events read.
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindow? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()
    private static func windowNumber(_ node: AXUIElement) -> String? {
        guard let get = getWindow, timed(node) else { return nil }
        var number: CGWindowID = 0
        guard get(node, &number) == .success, number != 0 else { return nil }
        return String(number)
    }
    /// Form metadata reads honor the join deadline between names, without changing the click-control adapter.
    private static func formControlNames(_ node: AXUIElement, late: () -> Bool) -> [String]? {
        guard !late(), let title = optionalString(node, .title) else { return nil }
        guard !late(), let description = optionalString(node, .description) else { return nil }
        return late() ? nil : [title, description]
    }
    /// A container's children for the form scan: element references only. nil when the read failed, when there are
    /// more than `BrowserFormScan.maxChildren`, and (review RB-M) when AXChildren is unsupported or has no value: a
    /// container Chrome built no subtree for can't be read as empty (the scan then denies, `field`). A successful read
    /// of an empty list is empty.
    static func childList(_ copied: Copied) -> [AXUIElement]? {
        guard case .value(let v) = copied, let list = v as? [AnyObject], list.count <= BrowserFormScan.maxChildren else { return nil }
        var out: [AXUIElement] = []
        for item in list {
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            out.append(item as! AXUIElement)
        }
        return out
    }

    /// QF-17 B2 (M8): the key-time identity, on main, with its own AXUIElement for Chrome (never shared with the
    /// witness's queue; never the system-wide element). Only the frontmost PID (no AX), secure input, and Chrome's
    /// AXFocusedWindow and AXFocusedUIElement REFS, each with a 25 ms timeout; no attribute of the refs is read.
    /// The route asks only after a verified read of this Chrome passed the mode gate. A read that fails or runs
    /// long pauses these reads for `pauseNanoseconds` (a frozen Chrome can't hold key intake: M9); keys then
    /// aren't held.
    final class KeyIdentityReader {
        static let pauseNanoseconds: UInt64 = 500_000_000
        private var app: (pid: pid_t, element: AXUIElement)?
        private var pausedUntil: UInt64 = 0
        func read(pid: pid_t) -> ChromeKeyIdentity? {
            dispatchPrecondition(condition: .onQueue(.main))
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let secure = IsSecureEventInputEnabled()
            let began = DispatchTime.now().uptimeNanoseconds
            // perm-1004: no Accessibility read while untrusted (it would make macOS prompt).
            guard front == pid, !secure, began >= pausedUntil, AXIsProcessTrusted() else { return ChromeKeyIdentity(frontmostPID: front, secureInput: secure, window: nil, focus: nil) }
            if app?.pid != pid {
                let element = AXUIElementCreateApplication(pid)
                guard ChromeTypingWitness.timed(element) else { return nil }
                app = (pid, element)
            }
            let root = app!.element
            let window = ChromeTypingWitness.element(root, .focusedWindow)
            let focus = window == nil ? nil : ChromeTypingWitness.element(root, .focusedElement)
            if window == nil || focus == nil || DispatchTime.now().uptimeNanoseconds &- began > 20_000_000 {
                pausedUntil = DispatchTime.now().uptimeNanoseconds &+ Self.pauseNanoseconds
            }
            return ChromeKeyIdentity(frontmostPID: front, secureInput: secure, window: window, focus: focus)
        }
    }

    /// C1 option 1. Exactly one parameterized read, with fixed keys and fixed control-only search text.
    /// Never count-only, backwards, visible-only or immediate-descendants-only. Results are transient references.
    private static func formSearch(page: AXUIElement, predicate: BrowserFormSearch, limit: Int) -> [AXUIElement]? {
        guard limit == BrowserFormScan.searchLimit, timed(page) else { return nil }
        var arguments: [String: Any] = ["AXResultsLimit": limit, "AXDirection": "AXDirectionNext"]
        switch predicate {
        case .textFields: arguments["AXSearchKey"] = "AXTextFieldSearchKey"
        case .revealControls(let word):
            guard BrowserFormScan.searchWords.contains(word) else { return nil }
            arguments["AXSearchKey"] = ["AXButtonSearchKey", "AXCheckBoxSearchKey", "AXLinkSearchKey"]
            arguments["AXSearchText"] = word
        }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(page, "AXUIElementsForSearchPredicate" as CFString,
                                                        arguments as CFDictionary, &value) == .success,
              let list = value as? [AnyObject], list.count < limit else { return nil }
        var out: [AXUIElement] = []
        for item in list {
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            let node = item as! AXUIElement
            // The core checks each owner with late() before every AX read.
            out.append(node)
        }
        return out
    }

    // MARK: - AX plumbing (per-object timeouts; AX timeouts are not inherited)

    enum Copied { case value(CFTypeRef), missing, failed }
    fileprivate static func timed(_ node: AXUIElement) -> Bool { AXUIElementSetMessagingTimeout(node, 0.025) == .success }
    private static func owner(_ node: AXUIElement) -> Int32? {
        guard timed(node) else { return nil }
        var value: pid_t = 0
        return AXUIElementGetPid(node, &value) == .success ? value : nil
    }
    /// The only Accessibility read in this file.
    private static func copy(_ node: AXUIElement, _ name: Attribute) -> Copied {
        guard timed(node) else { return .failed }
        var value: CFTypeRef?
        return copied(AXUIElementCopyAttributeValue(node, name.rawValue as CFString, &value), value)
    }
    /// An Accessibility read's answer: unsupported or no value is `missing`; any other error, or no value on success, `failed`.
    static func copied(_ result: AXError, _ value: CFTypeRef?) -> Copied {
        if result == .attributeUnsupported || result == .noValue { return .missing }
        guard result == .success, let value else { return .failed }
        return .value(value)
    }
    fileprivate static func element(_ node: AXUIElement, _ name: Attribute) -> AXUIElement? {
        guard case .value(let value) = copy(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    /// "" when the attribute is unsupported or empty; nil on error or a non-string.
    private static func optionalString(_ node: AXUIElement, _ name: Attribute) -> String? {
        switch copy(node, name) {
        case .missing: return ""
        case .failed: return nil
        case .value(let v): return v as? String
        }
    }
}
/// claude/axjoin-1005: the Accessibility join for Chrome builds it is validated on (`ChromeAXJoinPolicy`); any other
/// build takes the full Apple Events join.
extension ChromeJoinEnvironment {
    func withAccessibilityJoin() -> ChromeJoinEnvironment {
        var e = self
        e.accessibilityJoin = { ChromeAXJoinPolicy.validated($0) }
        return e
    }
}
#endif
