import AppKit
import ApplicationServices
import Foundation
import PrivacyPolicy

/// messages-1003: Messages' composer, read through Accessibility. Metadata reads (labels, character count) at a key's
/// proof; the field's value only at a send key, after that proof passed the gate (`CoreCaptureBinding.commitText`).
/// Nothing here is logged or kept.
enum MessagesComposer {
    static let bundle = "com.apple.MobileSMS"
    static let labelLimit = 128
    /// Description, placeholder, help and identifier of a field: never its value or title. nil when one can't be read.
    static func labels(_ node: AXUIElement) -> [String]? {
        guard AXUIElementSetMessagingTimeout(node, 0.025) == .success else { return nil }
        var out: [String] = []
        // The placeholder is read in the owner build only (Messages typing is owner-only; the public build never names it).
        #if DAYDREAM_OWNER_TYPING
        let names = [kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute, kAXIdentifierAttribute]
        #else
        let names = [kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute]
        #endif
        for name in names {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(node, name as CFString, &value)
            if result == .attributeUnsupported || result == .noValue { continue }
            guard result == .success else { return nil }
            guard let value else { continue }
            guard CFGetTypeID(value) == CFStringGetTypeID(), let text = value as? String, text.utf8.count <= labelLimit else { return nil }
            if !text.isEmpty { out.append(text) }
        }
        return out
    }
    /// The same logical field: same role, subrole and labels, and not a search or To box.
    static func sameField(_ old: (role: String, subrole: String, labels: [String]), _ new: (role: String, subrole: String, labels: [String])) -> Bool {
        SendRules.messagesSameField(old: old, new: new)
    }
    /// The field class stored on a Messages proof (`SendRules.messagesField`).
    static func classify(_ proof: inout FocusProof) {
        guard proof.bundle == bundle else { return }
        proof.sendField = SendRules.messagesField(role: proof.role, subrole: proof.subrole, labels: proof.nativeLabels, title: proof.place)
    }
}

/// compose-send/v1: the focused composer of any app, read through Accessibility at a send gesture only, after that
/// field's proof passed the gate (`CoreCaptureBinding.commitText`). Nothing here is logged or kept.
enum ComposerAX {
    private static func focused(pid: pid_t) -> AXUIElement? {
        guard Thread.isMainThread, pid > 0, AXIsProcessTrusted() else { return nil }   // perm-1004
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(app, 0.025) == .success else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let node = value as! AXUIElement
        guard AXUIElementSetMessagingTimeout(node, 0.025) == .success else { return nil }
        return node
    }
    /// The focused field's value, at a send key only. nil when it can't be read.
    static func value(pid: pid_t) -> String? {
        guard let node = focused(pid: pid) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, kAXValueAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }
    /// Whether the focused field is empty: its character count (an integer, never the text); nil when unknown.
    static func isEmpty(pid: pid_t) -> Bool? {
        guard let node = focused(pid: pid) else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(node, kAXNumberOfCharactersAttribute as CFString, &value)
        if result == .attributeUnsupported || result == .noValue {
            // No count: whether the value is empty, nothing else about it.
            var text: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXValueAttribute as CFString, &text) == .success, let text,
                  CFGetTypeID(text) == CFStringGetTypeID() else { return nil }
            return (text as? String)?.isEmpty
        }
        guard result == .success, let value, CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var count: Int64 = 0
        guard CFNumberGetValue((value as! CFNumber), .sInt64Type, &count) else { return nil }
        return count == 0
    }
}
