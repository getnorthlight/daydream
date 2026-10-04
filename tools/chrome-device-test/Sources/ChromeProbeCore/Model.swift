import Foundation

/// Fixed numbers the device test grades against. They come from the approved
/// plan (browser-plan-final.md §2 and noext.md §2.2) and are agreed before the
/// run; do not change them after seeing results.
public enum Harness {
    public static let version = "chrome-device-test 2 (plan Work row 0, review fixes)"
    /// Whole join (steps 0-6) must fit here.
    public static let joinBudgetMs = 150.0
    /// Each Apple Event.
    public static let aeEventBudgetMs = 20.0
    /// Each Accessibility read.
    public static let axReadBudgetMs = 25.0
    /// The light per-keystroke check.
    public static let lightCheckBudgetMs = 30.0
    /// Chrome 151 fixed the "show password" secure-input bypass (CVE-2026-17975).
    public static let minimumChromeMajor = 151
    /// Chrome's designated requirement, Google's team ID.
    public static let chromeRequirement =
        "anchor apple generic and identifier \"com.google.Chrome\" and certificate leaf[subject.OU] = \"EQHXZ8M8AV\""
    /// A new Incognito window must be listed within this long of taking focus.
    public static let incognitoLagPassMs = 300.0
    /// Longer than the 0.7 s save debounce: the save-time check can't be relied on.
    public static let incognitoLagAbandonMs = 700.0
    /// Share of samples that must pass in the "ratio" criteria.
    public static let requiredRatio = 0.9
    /// Maximum parent-walk length (production: `BrowserTypingTiming.maxAncestors`, 160 since fix/x-typing).
    public static let maxWalk = 160
    /// Reply descriptor types the app's decoder accepts, per property
    /// (`ChromeJoinRequest.decode` and `ChromeBounds(descriptor:)` in
    /// Sources/MemoryCore/BrowserTypingJoin.swift). A reply of any other type
    /// is denied by the app even when this harness can read it (review C4).
    /// check_harness_source.py keeps this in step with the app.
    public static let appAcceptedReplyTypes: [String: Set<String>] = [
        "mode": ["utxt", "TEXT"], "name": ["utxt", "TEXT"], "tab-id": ["utxt", "TEXT"], "tab-url": ["utxt", "TEXT"],
        "bounds": ["qdrt", "list"],
    ]
    /// Many-windows step: at least this many windows must be open for F13.
    public static let manyWindows = 8
    /// Native editors whose system-wide focus is checked (review C10).
    public static let nativeEditors: Set<String> = ["com.apple.TextEdit", "com.apple.Notes"]
}

public struct Rect: Equatable, Codable, CustomStringConvertible {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    /// Chrome's `bounds` is a QuickDraw rectangle: left, top, right, bottom,
    /// top-left origin of the main display (the same space as AXPosition).
    public static func quickDraw(left: Int, top: Int, right: Int, bottom: Int) -> Rect {
        Rect(x: Double(left), y: Double(top), w: Double(right - left), h: Double(bottom - top))
    }
    public func matches(_ o: Rect, tolerance: Double = 1) -> Bool {
        abs(x - o.x) <= tolerance && abs(y - o.y) <= tolerance && abs(w - o.w) <= tolerance && abs(h - o.h) <= tolerance
    }
    public var description: String { "\(Int(x)),\(Int(y)) \(Int(w))x\(Int(h))" }
}

// MARK: - Apple Events model (allowlist)

/// The only Chrome properties the harness may ask for. This matches the
/// allowlist proposed in the plan (§2 "How Incognito is kept out"):
/// `mode`, `ID  `, `pbnd`, `pnam`, `URL `, plus `acTa` as a container only.
public enum AEProperty: String, CaseIterable, Codable {
    case id = "ID  ", mode = "mode", bounds = "pbnd", name = "pnam", url = "URL "
    public var label: String {
        switch self {
        case .id: return "id"
        case .mode: return "mode"
        case .bounds: return "bounds"
        case .name: return "name"
        case .url: return "URL"
        }
    }
}

public enum WindowTarget: Equatable, Hashable {
    /// `every window` (absolute ordinal `all `).
    case every
    /// `first window` as a real absolute ordinal (`abso` `firs`): the fix.
    case firstAbsolute
    /// `first window` built as the pre-fix `ChromeModeReader.swift:39` built it
    /// at 6f26d15 (typeEnumerated `firs`). Kept only to confirm on a real
    /// Chrome that the fix in 0584e30 (`ChromeAppleEvents.swift:56`) was needed.
    case firstLegacyEnum
    /// `window N` by integer index.
    case index(Int)
    /// `window id "X"`.
    case id(String)
    public var label: String {
        switch self {
        case .every: return "every window"
        case .firstAbsolute: return "first window (abso)"
        case .firstLegacyEnum: return "first window (legacy enum)"
        case .index(let i): return "window \(i)"
        case .id: return "window id"
        }
    }
}

public enum AEQuery: Equatable {
    case window(WindowTarget, AEProperty)
    /// Property (`ID  ` or `URL `) of `active tab of window id X`.
    case activeTab(windowID: String, AEProperty)

    /// Title/address reads and anything under a tab. These must never happen
    /// unless every listed window has just answered "normal".
    public var isContent: Bool {
        switch self {
        case .window(_, let p): return p == .name || p == .url
        case .activeTab: return true
        }
    }
    public var targetWindowID: String? {
        switch self {
        case .window(.id(let id), _): return id
        case .activeTab(let id, _): return id
        default: return nil
        }
    }
    public var label: String {
        switch self {
        case .window(let r, let p): return "AE \(p.label) of \(r.label)"
        case .activeTab(_, let p): return "AE \(p.label) of active tab"
        }
    }
    /// The key under which a reply's descriptor type is recorded (F9).
    public var replyKind: String {
        switch self {
        case .window(.every, .id): return "window-list"
        case .window(_, let p): return p == .id ? "window-id" : p == .bounds ? "bounds" : p == .url ? "url" : p.label
        case .activeTab(_, let p): return p == .id ? "tab-id" : p == .url ? "tab-url" : "tab-\(p.label)"
        }
    }
}

public enum AEValue: Equatable { case text(String), list([String]), rect(Rect) }

public struct AEReply {
    public var value: AEValue?
    /// 0, or the Apple Event / OSStatus error.
    public var status: Int32
    public var nanos: UInt64
    /// Four-char descriptor type of the reply, for the report.
    public var rawType: String?
    public init(value: AEValue?, status: Int32, nanos: UInt64, rawType: String? = nil) {
        self.value = value; self.status = status; self.nanos = nanos; self.rawType = rawType
    }
    public var text: String? {
        guard status == 0 else { return nil }
        if case .text(let s)? = value { return s }
        return nil
    }
    public var list: [String]? {
        guard status == 0 else { return nil }
        if case .list(let l)? = value { return l }
        return nil
    }
    public var rect: Rect? {
        guard status == 0 else { return nil }
        if case .rect(let r)? = value { return r }
        return nil
    }
}

/// Transport to Chrome. Production: `LiveAppleEvents` (one `core/getd` event
/// per call). Tests: a fake Chrome.
public protocol AppleEventPort: AnyObject {
    func send(_ query: AEQuery) -> AEReply
}

public func milliseconds(_ nanos: UInt64) -> Double { Double(nanos) / 1_000_000 }
