import Foundation
import PrivacyPolicy

/// URL handling. Only the origin ever leaves this file (printed or reported).
public enum URLRules {
    public static func withoutFragment(_ s: String) -> String {
        guard var c = URLComponents(string: s) else { return s.split(separator: "#", maxSplits: 1).first.map(String.init) ?? s }
        c.fragment = nil
        return c.string ?? s
    }
    public static func sameIgnoringFragment(_ a: String, _ b: String) -> Bool {
        withoutFragment(a) == withoutFragment(b)
    }
    /// `scheme://host[:port]`, lowercased; nil when there is no host.
    public static func origin(_ s: String?) -> String? {
        guard let s, let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        return c.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }
    public static func isWebScheme(_ s: String?) -> Bool {
        guard let s, let scheme = URLComponents(string: s)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
    public static func hasUserInfo(_ s: String?) -> Bool {
        guard let s, let c = URLComponents(string: s) else { return false }
        return c.user != nil || c.password != nil
    }
    /// Where two URLs differ, without saying what they are.
    public static func difference(_ a: String?, _ b: String?) -> String {
        guard let a, let b else { return "unread" }
        if sameIgnoringFragment(a, b) { return "same" }
        if origin(a) != origin(b) { return "origin differs" }
        return "path or query differs"
    }
}

/// Field labels are read only with --probe-labels, only from the focused
/// field, and only to decide "deny". Raw strings never leave this process:
/// callers get attribute presence (length) and the names of matched rules.
public struct FieldLabels {
    public var title: String?, description: String?, placeholder: String?, domIdentifier: String?
    /// `AXDOMClassList`: the element's class names (a web terminal's hidden
    /// input is recognised by its class, e.g. xterm.js's `xterm-helper-textarea`).
    public var classList: [String]?
    public init(title: String? = nil, description: String? = nil, placeholder: String? = nil, domIdentifier: String? = nil, classList: [String]? = nil) {
        self.title = title; self.description = description; self.placeholder = placeholder; self.domIdentifier = domIdentifier
        self.classList = classList
    }
    public var presence: [String: Int] {
        var out: [String: Int] = [:]
        for (k, v) in [("AXTitle", title), ("AXDescription", description), ("AXPlaceholderValue", placeholder), ("AXDOMIdentifier", domIdentifier)] {
            out[k] = v?.count ?? 0
        }
        out["AXDOMClassList"] = classList?.count ?? 0
        return out
    }
}

public enum FieldDeny {
    /// Extra id and class tokens proposed in noext.md §3 (Chrome exposes the
    /// element id and classes, not HTML `autocomplete`), plus web terminals.
    /// The app's BrowserTypingFieldRules.idTokens must stay a superset
    /// (scripts/check_browser_boundary.py), so a harness deny implies an app deny.
    public static let idTokens: Set<String> = ["cc", "card", "cvc", "cvv", "csc", "exp", "otp", "code", "pin", "iban", "routing", "password", "passcode", "totp", "2fa", "mfa",
                                               "ssn", "xterm", "inputarea", "terminal", "monaco"]

    /// Splits `ccNumber`, `cc-exp`, `one_time_code` into lowercase tokens.
    public static func tokens(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        var prevLower = false
        for ch in s {
            if ch.isLetter || ch.isNumber {
                if ch.isUppercase && prevLower { out.append(cur); cur = "" }
                cur.append(Character(ch.lowercased()))
                prevLower = ch.isLowercase || ch.isNumber
            } else {
                if !cur.isEmpty { out.append(cur); cur = "" }
                prevLower = false
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out.filter { !$0.isEmpty }
    }

    /// Names of the rules that matched (for example "AXTitle:sensitiveLabel",
    /// "AXDOMIdentifier:card"). Never the label text itself.
    public static func matches(_ l: FieldLabels) -> [String] {
        var hits: [String] = []
        for (k, v) in [("AXTitle", l.title), ("AXDescription", l.description), ("AXPlaceholderValue", l.placeholder), ("AXDOMIdentifier", l.domIdentifier)] {
            guard let v, !v.isEmpty else { continue }
            if TextClassifier.sensitiveLabel(v) { hits.append("\(k):sensitiveLabel") }
        }
        if let id = l.domIdentifier {
            for t in tokens(id) where idTokens.contains(t) { hits.append("AXDOMIdentifier:\(t)") }
        }
        for c in l.classList ?? [] {
            for t in tokens(c) where idTokens.contains(t) { hits.append("AXDOMClassList:\(t)") }
        }
        return Array(Set(hits)).sorted()
    }
}

public enum TitleMatch: String, Codable {
    case exact, axStartsWithAE = "ax-starts-with-ae", aeStartsWithAX = "ae-starts-with-ax", differs, unread
    public static func compare(ae: String?, ax: String?) -> TitleMatch {
        guard let ae, let ax else { return .unread }
        if ae == ax { return .exact }
        if !ae.isEmpty && ax.hasPrefix(ae) { return .axStartsWithAE }
        if !ax.isEmpty && ae.hasPrefix(ax) { return .aeStartsWithAX }
        return .differs
    }
    /// The plan accepts an exact match, with "AX title starts with it" as fallback.
    public var acceptable: Bool { self == .exact || self == .axStartsWithAE }
}
