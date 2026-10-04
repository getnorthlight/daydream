import AppKit
import ApplicationServices
import Carbon
import ChromeProbeCore

/// The only Accessibility attributes this harness may read. There is no case
/// for a field's value, selected text, or any parameterized text attribute,
/// and nothing is ever set (so Chrome's heavy "enhanced" mode is never
/// switched on). check_harness_source.py enforces this list.
enum AXAttr: String {
    case role = "AXRole"
    case subrole = "AXSubrole"
    case parent = "AXParent"
    case focusedWindow = "AXFocusedWindow"
    case focusedElement = "AXFocusedUIElement"
    case focusedApplication = "AXFocusedApplication"
    /// Chrome's window list on the Accessibility side, for the window count
    /// (review I1). Each window is read for subrole and geometry only.
    case windows = "AXWindows"
    case position = "AXPosition"
    case size = "AXSize"
    case minimized = "AXMinimized"
    /// Only on the focused AXWindow (to compare with Chrome's window name).
    case title = "AXTitle"
    /// Only on AXWebArea elements.
    case url = "AXURL"
    /// Deny-only field metadata, read only with --probe-labels.
    case labelDescription = "AXDescription"
    case labelPlaceholder = "AXPlaceholderValue"
    case labelDOMIdentifier = "AXDOMIdentifier"
    case labelClassList = "AXDOMClassList"
    /// An element reference, read only on a focused AXComboBox (fix/web-textbox).
    case editableAncestor = "AXEditableAncestor"
}

final class LiveAX {
    let chromePID: pid_t
    let timeout: Float
    let app: AXUIElement
    let system: AXUIElement

    init(chromePID: pid_t, timeoutMs: Double) {
        self.chromePID = chromePID
        self.timeout = Float(timeoutMs / 1000)
        app = AXUIElementCreateApplication(chromePID)
        system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(app, timeout)
        AXUIElementSetMessagingTimeout(system, timeout)
    }

    private func copy(_ element: AXUIElement, _ attr: AXAttr) -> (CFTypeRef?, AXError) {
        // Timeouts are per object, not inherited from the application.
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr.rawValue as CFString, &value)
        return (err == .success ? value : nil, err)
    }
    func element(_ e: AXUIElement, _ attr: AXAttr) -> AXUIElement? {
        guard let v = copy(e, attr).0, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    func string(_ e: AXUIElement, _ attr: AXAttr) -> String? { copy(e, attr).0 as? String }
    func subrole(_ e: AXUIElement) -> String? {
        let (v, err) = copy(e, .subrole)
        if err == .attributeUnsupported || err == .noValue { return "" }
        guard err == .success else { return nil }
        return v as? String
    }
    func pid(_ e: AXUIElement) -> pid_t? {
        var p: pid_t = 0
        return AXUIElementGetPid(e, &p) == .success ? p : nil
    }
    func frame(_ e: AXUIElement) -> Rect? {
        guard let pv = copy(e, .position).0, CFGetTypeID(pv) == AXValueGetTypeID(),
              let sv = copy(e, .size).0, CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return Rect(x: Double(p.x), y: Double(p.y), w: Double(s.width), h: Double(s.height))
    }
    func minimized(_ e: AXUIElement) -> Bool? { copy(e, .minimized).0 as? Bool }
    /// AXWindows as elements; nil when unreadable or not all elements.
    func windows(_ e: AXUIElement) -> [AXUIElement]? {
        guard let v = copy(e, .windows).0, let list = v as? [AnyObject] else { return nil }
        var out: [AXUIElement] = []
        for item in list {
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            out.append(item as! AXUIElement)
        }
        return out
    }
    /// Standard windows in AXWindows, and whether `focused` is one of the
    /// listed elements. Subrole only; nil when anything is unreadable.
    func standardWindowCount(focused: AXUIElement?) -> (count: Int?, focusedListed: Bool?) {
        guard let list = windows(app) else { return (nil, nil) }
        var n = 0
        for w in list {
            guard let sub = subrole(w) else { return (nil, nil) }
            if sub == "AXStandardWindow" { n += 1 }
        }
        return (n, focused.map { f in list.contains { CFEqual($0, f) } })
    }
    func webAreaURL(_ e: AXUIElement) -> String? {
        guard let v = copy(e, .url).0 else { return nil }
        if let u = v as? URL { return u.absoluteString }
        return v as? String
    }
    func labels(_ e: AXUIElement) -> FieldLabels {
        FieldLabels(title: string(e, .title), description: string(e, .labelDescription),
                    placeholder: string(e, .labelPlaceholder), domIdentifier: string(e, .labelDOMIdentifier),
                    classList: copy(e, .labelClassList).0 as? [String])
    }
    func focusedApplicationPID() -> pid_t? { element(system, .focusedApplication).flatMap(pid) }

    func access(probeLabels: Bool) -> AXAccess<AXUIElement> {
        AXAccess<AXUIElement>(
            frontmostPID: { System.frontmostPID() },
            focusedApplicationPID: { self.focusedApplicationPID() },
            secureInputOn: { IsSecureEventInputEnabled() },
            applicationRole: { self.string(self.app, .role) },
            focusedWindow: { self.element(self.app, .focusedWindow) },
            windows: { self.windows(self.app) },
            focusedElement: { self.element(self.app, .focusedElement) },
            owner: { self.pid($0) },
            role: { self.string($0, .role) },
            subrole: { self.subrole($0) },
            parent: { self.element($0, .parent) },
            minimized: { self.minimized($0) },
            frame: { self.frame($0) },
            windowTitle: { self.string($0, .title) },
            webAreaURL: { self.webAreaURL($0) },
            fieldLabels: probeLabels ? { self.labels($0) } : nil,
            equal: { CFEqual($0, $1) },
            editableAncestor: { self.element($0, .editableAncestor) })
    }
}
