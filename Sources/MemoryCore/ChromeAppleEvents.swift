import Foundation

/// The only Apple Event shapes DayDream may send to Google Chrome.
///
/// Chrome enforces nothing: once Automation is granted, any code in this
/// process could ask Chrome for every tab (Incognito included) or run its
/// `execute` command. So the allowlist lives here, in one place:
/// - one event, `core/getd` (read a property);
/// - six properties: `mode`, `ID  `, `pbnd`, `pnam`, `URL `, `acTa`;
/// - object specifiers built only by this type, and re-audited before sending.
/// Nothing here sends an event. One sender in MacMemApp does, after auditing again.
public enum ChromeAppleEvents {
    public static let eventClass = "core"
    public static let eventID = "getd"
    /// mode, id, bounds, name/title, URL, active tab. Nothing else, ever.
    public static let readableProperties: Set<String> = ["mode", "ID  ", "pbnd", "pnam", "URL ", "acTa"]
    static let windowProperties: Set<String> = ["mode", "ID  ", "pbnd", "pnam", "acTa"]
    static let tabProperties: Set<String> = ["ID  ", "pnam", "URL "]
    /// `… of every window`: its IDs only, unless a caller widens it (PM7: only Chrome typing's batched reads, through
    /// their own session, pass `mode` and `pbnd`; page history and every other caller keep IDs only).
    public static let everyWindowDefault: Set<String> = ["ID  "]

    public static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    public static func fourCC(_ value: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }, encoding: .macOSRoman) ?? ""
    }
    /// The event is allowed only when it is exactly core/getd.
    public static func permits(eventClass: String, eventID: String) -> Bool {
        eventClass == self.eventClass && eventID == self.eventID
    }
    /// Chrome window and tab IDs are short decimal session IDs. Accept 1-80
    /// printable ASCII characters without spaces; anything odd fails closed.
    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.count <= 80 && id.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7f }
    }

    // MARK: - Specifier construction (the only builders)

    static func object(_ want: String, form: String, key: NSAppleEventDescriptor, container: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        let value = NSAppleEventDescriptor.record()
        value.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
        value.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        value.setDescriptor(key, forKeyword: code("seld"))
        value.setDescriptor(container, forKeyword: code("from"))
        return value.coerce(toDescriptorType: code("obj "))
    }
    static func property(_ name: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        guard readableProperties.contains(name) else { return nil }
        return object("prop", form: "prop", key: NSAppleEventDescriptor(typeCode: code(name)), container: container)
    }
    /// AppleScript's `first`/`every` are absolute ordinals (`abso`), not
    /// enumerations. The previous `enumCode("firs")` is rejected by Cocoa
    /// Scripting's specifier parser, so every read failed closed.
    static func ordinal(_ which: String) -> NSAppleEventDescriptor? {
        guard ["firs", "all "].contains(which) else { return nil }
        var raw = code(which)
        return NSAppleEventDescriptor(descriptorType: code("abso"), bytes: &raw, length: MemoryLayout<UInt32>.size)
    }
    static func firstWindow() -> NSAppleEventDescriptor? {
        ordinal("firs").flatMap { object("cwin", form: "indx", key: $0, container: .null()) }
    }
    static func everyWindow() -> NSAppleEventDescriptor? {
        ordinal("all ").flatMap { object("cwin", form: "indx", key: $0, container: .null()) }
    }
    static func window(_ id: String) -> NSAppleEventDescriptor? {
        guard validID(id) else { return nil }
        return object("cwin", form: "ID  ", key: NSAppleEventDescriptor(string: id), container: .null())
    }
    static func tab(_ windowID: String, _ tabID: String) -> NSAppleEventDescriptor? {
        guard validID(tabID) else { return nil }
        return window(windowID).flatMap { object("CrTb", form: "ID  ", key: NSAppleEventDescriptor(string: tabID), container: $0) }
    }

    /// The specifier for `property` of `target`, or nil unless every part is allowlisted.
    public static func specifier(_ target: BrowserTarget, property name: String) -> NSAppleEventDescriptor? {
        let built: NSAppleEventDescriptor?
        switch target {
        case .frontWindow: built = name == "ID  " ? firstWindow().flatMap { property(name, of: $0) } : nil
        case .window(let id): built = windowProperties.contains(name) ? window(id).flatMap { property(name, of: $0) } : nil
        case .activeTab(let id): built = tabProperties.contains(name) ? window(id).flatMap { property("acTa", of: $0) }.flatMap { property(name, of: $0) } : nil
        case .tab(let id, let tab): built = tabProperties.contains(name) ? self.tab(id, tab).flatMap { property(name, of: $0) } : nil
        }
        return built.flatMap { audit($0) ? $0 : nil }
    }

    // MARK: - Audit (enforced again by the sender)

    private enum Node { case frontWindow, window, windows, tab, value }
    /// Accepts only `property of (window | tab)` chains this type can build:
    /// window by ID; first window for its ID only; every window for its ID only (or, for a caller that passes
    /// them, `everyWindow`'s properties, never a name, tab or URL); tab by ID or active tab of a window by ID;
    /// each property allowed for its container.
    public static func audit(_ descriptor: NSAppleEventDescriptor, everyWindow: Set<String> = everyWindowDefault) -> Bool {
        let every = everyWindow.intersection(["ID  ", "mode", "pbnd"])
        guard case .value? = node(descriptor, depth: 0, every: every) else { return false }
        return true
    }
    private static func node(_ d: NSAppleEventDescriptor, depth: Int, every: Set<String>) -> Node? {
        guard depth < 5, d.descriptorType == code("obj "),
              let want = d.forKeyword(code("want")), want.descriptorType == code("type"),
              let form = d.forKeyword(code("form")), form.descriptorType == code("enum"),
              let seld = d.forKeyword(code("seld")), let from = d.forKeyword(code("from")) else { return nil }
        switch (fourCC(want.typeCodeValue), fourCC(form.enumCodeValue)) {
        case ("cwin", "indx"):
            guard from.descriptorType == code("null"), seld.descriptorType == code("abso"), seld.data.count == 4 else { return nil }
            let raw = seld.data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return raw == code("firs") ? .frontWindow : raw == code("all ") ? .windows : nil
        case ("cwin", "ID  "):
            guard from.descriptorType == code("null"), seld.descriptorType == code("utxt"),
                  let id = seld.stringValue, validID(id) else { return nil }
            return .window
        case ("CrTb", "ID  "):
            guard case .window? = node(from, depth: depth + 1, every: every), seld.descriptorType == code("utxt"),
                  let id = seld.stringValue, validID(id) else { return nil }
            return .tab
        case ("prop", "prop"):
            guard seld.descriptorType == code("type") else { return nil }
            let name = fourCC(seld.typeCodeValue)
            guard readableProperties.contains(name) else { return nil }
            switch node(from, depth: depth + 1, every: every) {
            case .frontWindow?: return name == "ID  " ? .value : nil
            // Every window: its IDs, and only for Chrome typing's batched reads (QF-17 M6) its modes and bounds.
            // Never a name, tab or URL of every window, whatever the caller passes.
            case .windows?: return every.contains(name) ? .value : nil
            case .window?: return windowProperties.contains(name) ? (name == "acTa" ? .tab : .value) : nil
            case .tab?: return tabProperties.contains(name) ? .value : nil
            default: return nil
            }
        default: return nil
        }
    }
}
