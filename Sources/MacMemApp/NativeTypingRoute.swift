import AppKit
import Foundation
import PrivacyPolicy

/// Which apps typing is read in, and the place label for a typed row.
/// EventCapture only asks these questions. The allowlist is the category
/// table's allowed set (`CaptureGate.nativeApps`): Notes and TextEdit in
/// public builds; in the owner build every row with a proof and a signer read
/// on a Mac. The Accessibility proof checks the same allowlist and each app's
/// own signer (`TypingCategories.signingRequirement`) on its own. Apps with web
/// content (`CaptureGate.webContentApps`) are proved by `WebContentFocusWitness`.
enum NativeTypingRoute {
    /// The capture gate's apps: native and web-content proofs alike.
    static func admits(bundle: String, pid: pid_t) -> Bool {
        pid > 0 && CaptureGate.nativeApps.contains(bundle)
    }
    /// The process a key goes to: the frontmost app, or a launcher panel the
    /// build allows (Spotlight) that holds key focus in front of it. Public
    /// builds allow no panel, so this costs no Accessibility read there.
    static func keyTarget(frontmost: pid_t) -> pid_t { keyTargetAndFocus(frontmost: frontmost).pid }
    /// `keyTarget` and the system-focused PID it read (`.none`: not read, as in builds with no key panels).
    /// QF-17 (PM2): website typing's bracketed design checks that PID at the key, with no second read.
    static func keyTargetAndFocus(frontmost: pid_t) -> (pid: pid_t, keyFocus: pid_t??) {
        guard !CaptureGate.keyPanelApps.isEmpty, Thread.isMainThread else { return (frontmost, .none) }
        let focus = keyFocus()
        return (KeyPanelRoute.target(frontmost: frontmost, keyFocus: focus, bundle: bundleOf), .some(focus))
    }
    /// The process holding key focus system-wide, and a process's bundle ID.
    /// Checks substitute both; the app reads Accessibility and NSRunningApplication.
    static var keyFocus: () -> pid_t? = { AccessibilityReader.systemFocusedApplication() }
    static var bundleOf: (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    /// The app a key goes to: the frontmost app, or an allowed launcher panel
    /// (Spotlight) holding key focus in front of it. Website typing and the
    /// menu-bar dot use this, so a Spotlight search over Chrome is native
    /// typing in Spotlight, and the dot follows Spotlight.
    static func keyTargetApp(frontmost pid: pid_t?, bundle: String) -> (pid: pid_t?, bundle: String) {
        let target = keyTargetAppAndFocus(frontmost: pid, bundle: bundle)
        return (target.pid, target.bundle)
    }
    /// `keyTargetApp` and the system-focused PID it read (`.none`: not read).
    static func keyTargetAppAndFocus(frontmost pid: pid_t?, bundle: String) -> (pid: pid_t?, bundle: String, keyFocus: pid_t??) {
        guard let pid, !CaptureGate.keyPanelApps.isEmpty else { return (pid, bundle, .none) }
        let target = keyTargetAndFocus(frontmost: pid)
        guard target.pid != pid, let panel = bundleOf(target.pid) else { return (pid, bundle, target.keyFocus) }
        return (target.pid, panel, target.keyFocus)
    }
    /// The allowed launcher panel holding key focus now, or nil (always nil in
    /// public builds, which allow no panel, and read nothing then).
    static func keyPanelBundle() -> String? {
        guard !CaptureGate.keyPanelApps.isEmpty, let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let target = keyTargetApp(frontmost: front.processIdentifier, bundle: front.bundleIdentifier ?? "")
        return target.pid != front.processIdentifier ? target.bundle : nil
    }
    /// Longest place label kept; the store's title rules and secret scrubber
    /// run on it before it is saved.
    static let placeLimit = 200
    /// The title of the focused window of the app the key went to ("Untitled
    /// 3", "Terminal — zsh"), read with the key's proof. nil when there is
    /// none or it can't be read in time. Metadata only: never the field's
    /// value or selection. For a launcher panel it is the panel's own window,
    /// never the title of the app behind it.
    static func place(for frontmost: pid_t) -> String? {
        let pid = keyTarget(frontmost: frontmost)
        return place(title: AccessibilityReader.focusedWindowTitle(pid: pid), bundle: bundleOf(pid), pid: pid)
    }
    /// Keep only this focused window title. A generic Messages/New Message
    /// window does not establish that the selected conversation row belongs
    /// to its composer; neither an old row nor its cached name is authority.
    /// Unknown recipients stay unknown without reading conversation previews.
    static func place(title raw: String?, bundle: String?, pid: pid_t) -> String? {
        clip(raw)
    }
    static func clip(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return String(title.prefix(placeLimit))
    }
}

/// fix/typing-e2e: who a Messages conversation is with when the window title doesn't say (it is "Messages"): the first
/// text of the selected row of the conversation list, through `SendRules.conversationName(rowTexts:)`. One bounded
/// Accessibility walk (at most `maxNodes` elements, 25 ms per read), kept for the same window for `ttl`, so typing
/// doesn't walk the window on every key. Reads roles, the selection and static texts of the selected row only; never
/// a field's value or the transcript's messages. Device check pending (test 7): nil whenever the tree differs.
enum MessagesConversation {
    static let bundle = "com.apple.MobileSMS"
    static let ttl: TimeInterval = 3
    static let maxNodes = 240
    /// The selected row's texts in the focused window, or nil. Checks substitute a read.
    static var rowTexts: (pid_t) -> [String]? = { MessagesConversationAX.selectedRowTexts(pid: $0) }
    /// The window a cached answer belongs to (its title and frame), and when it was read.
    static var windowKey: (pid_t) -> String? = { MessagesConversationAX.windowKey(pid: $0) }
    static var clock: () -> Date = Date.init
    private static var cache: (pid: pid_t, window: String, at: Date, name: String?)?
    private static let lock = NSLock()
    static func name(pid: pid_t) -> String? {
        let key = windowKey(pid) ?? ""
        let now = clock()
        lock.lock()
        if let c = cache, c.pid == pid, c.window == key, now >= c.at, now.timeIntervalSince(c.at) < ttl { lock.unlock(); return c.name }
        lock.unlock()
        let name = rowTexts(pid).flatMap { SendRules.conversationName(rowTexts: $0) }
        lock.lock(); cache = (pid, key, now, name); lock.unlock()
        return name
    }
    /// fix/sx-all round 1: switching conversations in the same window changes neither the pid nor the window, so the
    /// cache is dropped on everything that can switch it: a click, a Return (a send), a focus-moving key or a focus,
    /// window or app change (EventCapture). A quick reply after a click is never filed under the previous person.
    static func forget() { lock.lock(); cache = nil; lock.unlock() }
}

enum MessagesConversationAX {
    static func windowKey(pid: pid_t) -> String? {
        guard Thread.isMainThread, pid > 0, let window = focusedWindow(pid) else { return nil }
        return "\(CFHash(window))"
    }
    static func selectedRowTexts(pid: pid_t) -> [String]? {
        guard Thread.isMainThread, pid > 0, let window = focusedWindow(pid) else { return nil }
        // Breadth first, so the conversation list (a table, outline or list near the top of the window) is met
        // before anything deep in the transcript.
        var queue: [AXUIElement] = [window], visited = 0
        while !queue.isEmpty, visited < MessagesConversation.maxNodes {
            let node = queue.removeFirst(); visited += 1
            _ = AXUIElementSetMessagingTimeout(node, 0.025)
            let role = string(node, kAXRoleAttribute) ?? ""
            if ["AXTable", "AXOutline", "AXList"].contains(role) {
                let selected = (attribute(node, kAXSelectedRowsAttribute) as? [AXUIElement])
                    ?? (attribute(node, kAXSelectedChildrenAttribute) as? [AXUIElement]) ?? []
                if let row = selected.first { return texts(in: row) }
                continue   // a list with nothing selected (the transcript): not descended into
            }
            queue.append(contentsOf: (attribute(node, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
        }
        return nil
    }
    /// Static texts of one row, in order (at most 12, 4 levels deep).
    private static func texts(in row: AXUIElement) -> [String] {
        var out: [String] = []
        func walk(_ node: AXUIElement, _ depth: Int) {
            guard out.count < 12, depth <= 4 else { return }
            _ = AXUIElementSetMessagingTimeout(node, 0.025)
            if string(node, kAXRoleAttribute) == "AXStaticText", let value = string(node, kAXValueAttribute) ?? string(node, kAXTitleAttribute) {
                out.append(value)
            }
            for child in (attribute(node, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth + 1) }
        }
        walk(row, 0)
        return out
    }
    private static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }   // perm-1004: never an Accessibility read while untrusted
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(app, 0.025) == .success, let value = attribute(app, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
