import Foundation

/// Accessibility seam. Production supplies AXUIElement reads; tests supply a
/// fake tree. There is deliberately no closure for a field's value, selected
/// text, or any parameterized text attribute.
public struct AXAccess<Node> {
    public var frontmostPID: () -> Int32?
    /// System-wide `AXFocusedApplication`: who really receives keys.
    public var focusedApplicationPID: () -> Int32?
    public var secureInputOn: () -> Bool
    /// `AXRole` of Chrome's application element. Reading a role is what turns
    /// on Chrome's basic accessibility mode; nothing is ever set.
    public var applicationRole: () -> String?
    public var focusedWindow: () -> Node?
    /// `AXWindows` of Chrome's application element: every window Accessibility
    /// knows, read for subrole and geometry only (review I1).
    public var windows: () -> [Node]?
    public var focusedElement: () -> Node?
    public var owner: (Node) -> Int32?
    public var role: (Node) -> String?
    /// "" when the element has no subrole; nil on error.
    public var subrole: (Node) -> String?
    public var parent: (Node) -> Node?
    public var minimized: (Node) -> Bool?
    /// AXPosition + AXSize.
    public var frame: (Node) -> Rect?
    /// AXTitle of the focused AXWindow (compared with Chrome's window name).
    public var windowTitle: (Node) -> String?
    /// AXURL of an AXWebArea.
    public var webAreaURL: (Node) -> String?
    /// Only present with --probe-labels. Deny-only metadata of the focused field.
    public var fieldLabels: ((Node) -> FieldLabels)?
    public var equal: (Node, Node) -> Bool
    /// fix/web-textbox: `AXEditableAncestor` (an element reference), read
    /// only on a focused AXComboBox, to tell an editable search box that is
    /// its own editable root from a select-only drop-down, as the app does
    /// (`ChromeAXAccess.textBox`). nil: not supplied.
    public var editableAncestor: ((Node) -> Node?)?

    public init(frontmostPID: @escaping () -> Int32?, focusedApplicationPID: @escaping () -> Int32?,
                secureInputOn: @escaping () -> Bool, applicationRole: @escaping () -> String?,
                focusedWindow: @escaping () -> Node?, windows: @escaping () -> [Node]?, focusedElement: @escaping () -> Node?,
                owner: @escaping (Node) -> Int32?, role: @escaping (Node) -> String?,
                subrole: @escaping (Node) -> String?, parent: @escaping (Node) -> Node?,
                minimized: @escaping (Node) -> Bool?, frame: @escaping (Node) -> Rect?,
                windowTitle: @escaping (Node) -> String?, webAreaURL: @escaping (Node) -> String?,
                fieldLabels: ((Node) -> FieldLabels)?, equal: @escaping (Node, Node) -> Bool,
                editableAncestor: ((Node) -> Node?)? = nil) {
        self.frontmostPID = frontmostPID; self.focusedApplicationPID = focusedApplicationPID
        self.secureInputOn = secureInputOn; self.applicationRole = applicationRole
        self.focusedWindow = focusedWindow; self.windows = windows; self.focusedElement = focusedElement
        self.owner = owner; self.role = role; self.subrole = subrole; self.parent = parent
        self.minimized = minimized; self.frame = frame; self.windowTitle = windowTitle
        self.webAreaURL = webAreaURL; self.fieldLabels = fieldLabels; self.equal = equal
        self.editableAncestor = editableAncestor
    }
}

public enum DenyReason: String, Codable, CaseIterable {
    case chromeNotFrontmost = "chrome-not-frontmost"
    case focusInOtherApp = "focus-in-other-app"
    case secureInput = "secure-input-on"
    case listingFailed = "window-listing-failed"
    case noWindows = "no-windows"
    case axWindowMissing = "ax-window-missing"
    case axWindowNotChrome = "ax-window-not-chrome"
    case axWindowRole = "ax-window-role"
    case axWindowMinimized = "ax-window-minimized"
    case axWindowSubrole = "ax-window-not-standard"
    case boundsMismatch = "bounds-mismatch"
    /// AXWindows, or a window's subrole or frame in it, could not be read.
    case axWindowsUnreadable = "ax-windows-unreadable"
    /// A standard AX window pairs with no listed window: Apple Events left it
    /// out (a window still opening or closing, maybe Incognito). Review I1.
    case unlistedWindow = "ax-window-not-listed"
    /// Two AX windows share the focused window's frame: they can't be told apart.
    case sameFrameTwin = "same-frame-window"
    /// The focused window is not one of the AXWindows elements (the app
    /// denies this too, BrowserTypingJoin.swift read() step 4).
    case focusedNotInAXWindows = "focused-window-not-in-ax-windows"
    case aeContentFailed = "ae-content-read-failed"
    case titleMismatch = "title-mismatch"
    case fieldMissing = "no-focused-field"
    case fieldNotChrome = "field-not-chrome"
    case fieldRole = "field-not-text-role"
    case fieldSecure = "field-secure-subrole"
    case noWebArea = "no-web-area"
    case iframe = "iframe-second-web-area"
    case nearestURLDiffers = "field-frame-url-differs"
    case walkIncomplete = "walk-did-not-reach-window"
    case walkCycle = "walk-cycle"
    case webAreaURLUnreadable = "web-area-url-unreadable"
    case urlMismatch = "url-mismatch"
    case scheme = "not-http-https"
    case userInfo = "url-has-user-info"
    case sensitiveLabel = "sensitive-label"
    case changedAE = "changed-during-join-apple-events"
    case changedAX = "changed-during-join-accessibility"
}

public enum Verdict: String, Codable {
    /// Every condition held: production would accept a keystroke.
    case allow = "ALLOW"
    case deny = "DENY"
    /// Strict mode: at least one window is not "normal". Nothing else read.
    case strictPause = "PAUSE"
    case unavailable = "UNAVAILABLE"
}

/// One full join (plan §2 steps 0-6). Codable for the JSON report. It holds no
/// title, full URL, label or typed text: only booleans, roles, counts,
/// the origin and timings.
public struct JoinReport: Codable {
    public var verdict: Verdict = .unavailable
    public var reasons: [DenyReason] = []
    public var listing: String = "not-run"
    public var windowCount = 0
    public var modes: [String] = []
    public var frontmostIsChrome = false
    public var focusedAppIsChrome = false
    public var secureInput = false
    public var axWindowRole: String?
    public var axWindowSubrole: String?
    /// Review I1: AXWindows of Chrome (all, and standard ones), standard ones
    /// that pair with no listed window, and standard ones with the focused frame.
    public var axWindowCount: Int?
    public var axStandardWindows: Int?
    public var unpairedAXWindows: Int?
    public var sameFrameWindows: Int?
    public var focusedInAXWindows: Bool?
    /// The join stopped after the window count, before any title, address,
    /// tab or field read.
    public var stoppedBeforeContent = false
    public var boundsMatchFront: Bool?
    /// 1-based positions (front to back) of every AE window whose bounds match the AX window.
    public var boundsMatchPositions: [Int] = []
    public var titleMatch: TitleMatch = .unread
    public var fieldRole: String?
    public var fieldSubrole: String?
    /// fix/web-textbox: for a focused AXComboBox, whether its
    /// AXEditableAncestor is the element itself (nil for other roles).
    public var fieldEditableSelf: Bool?
    public var ancestorRoles: [String] = []
    public var webAreaCount = 0
    public var topWebAreaParentRole: String?
    public var reachedWindow = false
    public var urlComparison = "unread"
    public var nearestFrameVsTab = "unread"
    public var origin: String?
    public var labelPresence: [String: Int]?
    public var labelDeny: [String]?
    public var stableAE: Bool?
    public var stableAX: Bool?
    public var totalMs = 0.0
    public var aeReads = 0
    public var axReads = 0
    public var maxAEms = 0.0
    public var maxAXms = 0.0
    public var aeContentReads = 0
    public var axContentReads = 0
    public var auditViolations: [String] = []
    public var reads: [TimedRead]?

    public init() {}
    mutating func deny(_ r: DenyReason) { if !reasons.contains(r) { reasons.append(r) } }
    public var overBudget: Bool { totalMs > Harness.joinBudgetMs }
    public var summary: String {
        var s = "\(verdict.rawValue)"
        if !reasons.isEmpty { s += " [" + reasons.map(\.rawValue).joined(separator: ", ") + "]" }
        return s
    }
}

/// One-to-one pairing of AX window frames with listed Apple Events bounds.
public enum WindowMatch {
    /// Size of a maximum matching (Kuhn's algorithm): how many AX frames get a
    /// listed window of their own. A greedy pass can strand a frame when two
    /// listed windows share bounds, so this is exact.
    public static func maximum(_ ax: [Rect], _ ae: [Rect]) -> Int {
        var owner = [Int?](repeating: nil, count: ae.count)
        func place(_ i: Int, _ seen: inout [Bool]) -> Bool {
            for j in ae.indices where !seen[j] && ax[i].matches(ae[j]) {
                seen[j] = true
                if owner[j] == nil || place(owner[j]!, &seen) { owner[j] = i; return true }
            }
            return false
        }
        var count = 0
        for i in ax.indices {
            var seen = [Bool](repeating: false, count: ae.count)
            if place(i, &seen) { count += 1 }
        }
        return count
    }
}

public struct JoinOutcome<Node> {
    public var report: JoinReport
    public var frontID: String?
    public var window: Node?
    public var element: Node?
}

/// The join protocol from the plan, run read-only against Chrome. It collects
/// as much metadata as it safely can (so a deny still tells us why), but it
/// never reads a title, address or any Accessibility content while any Chrome
/// window is not "normal" (strict mode), and it never reads field values.
public final class ChromeJoin<Node> {
    public let chromePID: Int32
    public let ae: AppleEventPort
    public let audit: ReadAudit
    public let ax: AXAccess<Node>
    public let timings: TimingLog
    public let now: () -> UInt64
    public var listingMode: ListingMode = .every
    public var probeLabels = false
    public var keepReads = false
    private var reads: [TimedRead] = []

    public init(chromePID: Int32, ae: AppleEventPort, audit: ReadAudit, ax: AXAccess<Node>, timings: TimingLog, now: @escaping () -> UInt64) {
        self.chromePID = chromePID; self.ae = ae; self.audit = audit; self.ax = ax; self.timings = timings; self.now = now
    }

    private func timed<T>(_ kind: ReadKind, _ label: String, _ body: () -> T) -> T {
        let s = now(); let v = body(); let ms = milliseconds(now() &- s)
        timings.record(kind, label, ms)
        reads.append(TimedRead(kind: kind, label: label, ms: ms))
        return v
    }
    /// Every Chrome Accessibility read inside a join goes through here.
    private func axRead<T>(_ label: String, _ body: () -> T) -> T {
        audit.willReadAX(label)
        return timed(.ax, label, body)
    }
    private func send(_ q: AEQuery) -> AEReply {
        let r = ae.send(q)
        reads.append(TimedRead(kind: .ae, label: q.label, ms: milliseconds(r.nanos)))
        return r
    }

    public func run() -> JoinOutcome<Node> {
        audit.beginPass(); reads = []
        let start = now()
        let v0 = audit.violations.count, ae0 = audit.aeContentReads, ax0 = audit.axContentReads
        var r = JoinReport()
        var out = JoinOutcome<Node>(report: r, frontID: nil, window: nil, element: nil)
        func finish() -> JoinOutcome<Node> {
            r.totalMs = milliseconds(now() &- start)
            r.aeReads = reads.filter { $0.kind == .ae }.count
            r.axReads = reads.filter { $0.kind == .ax }.count
            r.maxAEms = reads.filter { $0.kind == .ae }.map(\.ms).max() ?? 0
            r.maxAXms = reads.filter { $0.kind == .ax }.map(\.ms).max() ?? 0
            r.aeContentReads = audit.aeContentReads - ae0
            r.axContentReads = audit.axContentReads - ax0
            r.auditViolations = Array(audit.violations[v0...])
            if keepReads { r.reads = reads }
            if r.verdict == .unavailable && r.reasons.isEmpty { r.deny(.listingFailed) }
            out.report = r
            return out
        }

        // Step 0: who is in front, who really gets the keys. No Chrome content.
        r.frontmostIsChrome = timed(.system, "frontmost application") { ax.frontmostPID() } == chromePID
        r.focusedAppIsChrome = timed(.system, "system-wide focused application") { ax.focusedApplicationPID() } == chromePID
        r.secureInput = ax.secureInputOn()
        if !r.frontmostIsChrome { r.deny(.chromeNotFrontmost) }
        if !r.focusedAppIsChrome { r.deny(.focusInOtherApp) }
        if r.secureInput { r.deny(.secureInput) }

        // Step 1: Apple Events, identity only. Mode of every window by ID.
        guard let listing = WindowPass.list(ae, prefer: listingMode) else {
            r.listing = "failed"; r.deny(.listingFailed); return finish()
        }
        r.listing = listing.mode.rawValue
        r.windowCount = listing.ids.count
        guard let front = listing.ids.first else { r.deny(.noWindows); return finish() }
        out.frontID = front
        var modes: [String: String] = [:]
        for id in listing.ids { modes[id] = send(.window(.id(id), .mode)).text ?? "" }
        r.modes = listing.ids.map { modes[$0]!.isEmpty ? "(unreadable)" : modes[$0]! }
        var bounds: [String: Rect] = [:]
        let nonNormal = listing.ids.filter { modes[$0] != "normal" }
        if !nonNormal.isEmpty {
            // Geometry only for non-normal windows, then stop: strict pause.
            for id in nonNormal { bounds[id] = send(.window(.id(id), .bounds)).rect }
            r.verdict = .strictPause
            return finish()
        }
        for id in listing.ids { bounds[id] = send(.window(.id(id), .bounds)).rect }

        // Step 2: Accessibility, geometry only.
        _ = axRead("AX application role") { ax.applicationRole() }
        let window = axRead("AX focused window") { ax.focusedWindow() }
        out.window = window
        var winFrame: Rect?
        if let window {
            if axRead("AX window owner", { ax.owner(window) }) != chromePID { r.deny(.axWindowNotChrome) }
            r.axWindowRole = axRead("AX window role") { ax.role(window) }
            if r.axWindowRole != "AXWindow" { r.deny(.axWindowRole) }
            r.axWindowSubrole = axRead("AX window subrole") { ax.subrole(window) }
            if r.axWindowSubrole != "AXStandardWindow" { r.deny(.axWindowSubrole) }
            if axRead("AX window minimized", { ax.minimized(window) }) == true { r.deny(.axWindowMinimized) }
            winFrame = axRead("AX window position+size") { ax.frame(window) }
        } else {
            r.deny(.axWindowMissing)
        }
        if let winFrame {
            r.boundsMatchPositions = listing.ids.enumerated().compactMap { i, id in
                bounds[id].map { winFrame.matches($0) } == true ? i + 1 : nil
            }
            r.boundsMatchFront = bounds[front].map { winFrame.matches($0) } ?? false
        } else {
            r.boundsMatchFront = false
        }
        if r.boundsMatchFront != true { r.deny(.boundsMismatch) }

        // Step 2b (review I1): count Chrome's windows on the Accessibility
        // side, subrole and geometry only, before any title, address or field
        // read. Every standard AX window must pair with a listed window of its
        // own by bounds. One left over is a window Apple Events did not list
        // (still opening or closing, maybe Incognito). Two with the focused
        // frame can't be told apart. Either, or a focused window that matches
        // no listed window, stops the join here.
        let axWindows = axRead("AX windows") { ax.windows() }
        var standardFrames: [Rect] = []
        var windowsUnreadable = axWindows == nil
        for w in axWindows ?? [] {
            guard let sub = axRead("AX window subrole (list)", { ax.subrole(w) }) else { windowsUnreadable = true; break }
            guard sub == "AXStandardWindow" else { continue }
            guard let f = axRead("AX window position+size (list)", { ax.frame(w) }) else { windowsUnreadable = true; break }
            standardFrames.append(f)
        }
        r.axWindowCount = axWindows?.count
        if let axWindows, let window {
            r.focusedInAXWindows = axWindows.contains { ax.equal($0, window) }
            if r.focusedInAXWindows == false { r.deny(.focusedNotInAXWindows) }
        }
        if windowsUnreadable {
            r.deny(.axWindowsUnreadable)
        } else {
            audit.noteAXWindows(standard: standardFrames.count)
            r.axStandardWindows = standardFrames.count
            let unpaired = standardFrames.count - WindowMatch.maximum(standardFrames, listing.ids.compactMap { bounds[$0] })
            r.unpairedAXWindows = unpaired
            if unpaired > 0 { r.deny(.unlistedWindow) }
            if let winFrame {
                r.sameFrameWindows = standardFrames.filter { $0.matches(winFrame) }.count
                if r.sameFrameWindows! > 1 { r.deny(.sameFrameTwin) }
            }
        }
        if windowsUnreadable || (r.unpairedAXWindows ?? 0) > 0 || (r.sameFrameWindows ?? 0) > 1 || r.focusedInAXWindows == false || r.boundsMatchPositions.isEmpty {
            r.stoppedBeforeContent = true
            r.verdict = .deny
            return finish()
        }

        // Step 3: Apple Events content for the front window (all are normal).
        let tabID = send(.activeTab(windowID: front, .id)).text
        let tabURL = send(.activeTab(windowID: front, .url)).text
        let windowName = send(.window(.id(front), .name)).text
        if tabID == nil || tabURL == nil || windowName == nil { r.deny(.aeContentFailed) }
        r.origin = URLRules.origin(tabURL)
        if !URLRules.isWebScheme(tabURL) { r.deny(.scheme) }
        if URLRules.hasUserInfo(tabURL) { r.deny(.userInfo) }

        // Step 4: Accessibility content.
        let axTitle = window.flatMap { w in axRead("AX window title") { ax.windowTitle(w) } }
        r.titleMatch = TitleMatch.compare(ae: windowName, ax: axTitle)
        if !r.titleMatch.acceptable { r.deny(.titleMismatch) }
        let element = axRead("AX focused element") { ax.focusedElement() }
        out.element = element
        var topWebArea: Node?
        var topURL: String?
        if let element {
            if axRead("AX field owner", { ax.owner(element) }) != chromePID { r.deny(.fieldNotChrome) }
            r.fieldRole = axRead("AX field role") { ax.role(element) }
            r.fieldSubrole = axRead("AX field subrole") { ax.subrole(element) }
            // fix/web-textbox: the app's text boxes (`ChromeAXAccess.textBox`): a text field, a text area, or
            // an AXComboBox whose AXEditableAncestor is itself (an editable search or autocomplete box).
            if r.fieldRole == "AXComboBox" {
                r.fieldEditableSelf = axRead("AX editable ancestor") { ax.editableAncestor?(element) }.map { ax.equal($0, element) } ?? false
            }
            if !(["AXTextField", "AXTextArea"].contains(r.fieldRole ?? "") || r.fieldEditableSelf == true) { r.deny(.fieldRole) }
            if (r.fieldSubrole ?? "secure?").lowercased().contains("secure") { r.deny(.fieldSecure) }
            // Walk up: roles only, AXURL only on AXWebArea.
            var roles: [String] = [r.fieldRole ?? "(none)"]
            var visited: [Node] = [element]
            var webAreas: [Node] = r.fieldRole == "AXWebArea" ? [element] : []
            var cursor = axRead("AX parent") { ax.parent(element) }
            var reached = window.map { ax.equal(element, $0) } ?? false
            var cycle = false
            var parentOfTopRole: String?
            var steps = 0
            while !reached, let node = cursor, steps < Harness.maxWalk {
                steps += 1
                if visited.contains(where: { ax.equal($0, node) }) { cycle = true; break }
                visited.append(node)
                if let window, ax.equal(node, window) {
                    reached = true
                    if !webAreas.isEmpty && parentOfTopRole == nil { parentOfTopRole = "AXWindow" }
                    roles.append("AXWindow")
                    break
                }
                let role = axRead("AX ancestor role") { ax.role(node) } ?? "(none)"
                roles.append(role)
                if role == "AXWebArea" { webAreas.append(node); parentOfTopRole = nil }
                else if !webAreas.isEmpty && parentOfTopRole == nil { parentOfTopRole = role }
                cursor = axRead("AX parent") { ax.parent(node) }
            }
            r.ancestorRoles = roles
            r.reachedWindow = reached
            r.webAreaCount = webAreas.count
            r.topWebAreaParentRole = parentOfTopRole
            if cycle { r.deny(.walkCycle) }
            if !reached { r.deny(.walkIncomplete) }
            if webAreas.isEmpty { r.deny(.noWebArea) }
            if webAreas.count > 1 { r.deny(.iframe) }
            let urls = webAreas.map { n in axRead("AX web area URL") { ax.webAreaURL(n) } }
            topWebArea = webAreas.last
            topURL = urls.last ?? nil
            if !webAreas.isEmpty && topURL == nil { r.deny(.webAreaURLUnreadable) }
            r.urlComparison = URLRules.difference(topURL, tabURL)
            if topURL != nil && tabURL != nil && r.urlComparison != "same" { r.deny(.urlMismatch) }
            r.nearestFrameVsTab = URLRules.difference(urls.first ?? nil, tabURL)
            if urls.count > 0, r.nearestFrameVsTab != "same", r.nearestFrameVsTab != "unread" { r.deny(.nearestURLDiffers) }
            if probeLabels, let read = ax.fieldLabels {
                let labels = axRead("AX field labels (deny-only)") { read(element) }
                r.labelPresence = labels.presence
                r.labelDeny = FieldDeny.matches(labels)
                if !(r.labelDeny ?? []).isEmpty { r.deny(.sensitiveLabel) }
            }
        } else {
            r.deny(.fieldMissing)
        }

        // Step 5: Apple Events again; everything must be unchanged. If the
        // window list changed, read only the modes and stop: a new window may
        // be Incognito, so no further Accessibility read is allowed.
        let again = WindowPass.list(ae, prefer: listing.mode)
        let modesAgain = (again?.ids ?? []).map { send(.window(.id($0), .mode)).text ?? "" }
        guard let again, again.ids == listing.ids, modesAgain.allSatisfy({ $0 == "normal" }) else {
            r.stableAE = false
            r.deny(.changedAE)
            r.verdict = modesAgain.contains(where: { $0 != "normal" }) ? .strictPause : .deny
            return finish()
        }
        let boundsAgain = listing.ids.map { send(.window(.id($0), .bounds)).rect }
        let stableAE = boundsAgain == listing.ids.map { bounds[$0] }
            && send(.activeTab(windowID: front, .id)).text == tabID
            && send(.activeTab(windowID: front, .url)).text == tabURL
            && send(.window(.id(front), .name)).text == windowName
        r.stableAE = stableAE
        if !stableAE { r.deny(.changedAE) }

        // Step 6: Accessibility again.
        var stableAX = timed(.system, "frontmost application") { ax.frontmostPID() } == chromePID
            && timed(.system, "system-wide focused application") { ax.focusedApplicationPID() } == chromePID
            && ax.secureInputOn() == r.secureInput
        stableAX = stableAX && axRead("AX windows (again)") { ax.windows() }?.count == axWindows?.count
        let window2 = axRead("AX focused window (again)") { ax.focusedWindow() }
        let element2 = axRead("AX focused element (again)") { ax.focusedElement() }
        switch (window, window2) {
        case (let a?, let b?): stableAX = stableAX && ax.equal(a, b)
        case (nil, nil): break
        default: stableAX = false
        }
        switch (element, element2) {
        case (let a?, let b?):
            stableAX = stableAX && ax.equal(a, b)
                && axRead("AX field role (again)") { ax.role(b) } == r.fieldRole
                && axRead("AX field subrole (again)") { ax.subrole(b) } == r.fieldSubrole
        case (nil, nil): break
        default: stableAX = false
        }
        if let topWebArea { stableAX = stableAX && axRead("AX web area URL (again)") { ax.webAreaURL(topWebArea) } == topURL }
        r.stableAX = stableAX
        if !stableAX { r.deny(.changedAX) }

        r.verdict = r.reasons.isEmpty ? .allow : .deny
        return finish()
    }

    /// The light per-keystroke check the plan proposes between full joins:
    /// `id of window 1` + its mode, then the focused window/element identity.
    /// Identity only: no title, URL, role or label.
    public func lightCheck(frontID: String, window: Node?, element: Node?) -> (ok: Bool, ms: Double) {
        let s = now()
        let ref: WindowTarget = listingMode == .every ? .firstAbsolute : .index(1)
        let id = ae.send(.window(ref, .id)).text
        let mode = id.map { ae.send(.window(.id($0), .mode)).text } ?? nil
        let w = ax.focusedWindow(), e = ax.focusedElement()
        let same: (Node?, Node?) -> Bool = { a, b in
            switch (a, b) { case (let a?, let b?): return self.ax.equal(a, b); default: return false }
        }
        let ok = id == frontID && mode == "normal" && same(w, window) && same(e, element)
        return (ok, milliseconds(now() &- s))
    }
}
