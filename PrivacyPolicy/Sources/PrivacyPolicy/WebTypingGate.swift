#if DAYDREAM_CHROME_TYPING
// Chrome typing builds only (compiled out of the public build); live only in
// the owner build, where `TypingRelease.open` is true.
// Website typing (typing-all SPEC-LATER 4.2): the focus gate for keys typed on
// websites in Google Chrome, which the Chrome join proves.
import Foundation

/// The focus gate for website typing (Chrome typing builds only; live only in
/// the owner build, where `TypingRelease.open` is true). Every key, commit
/// and parked unit of website typing goes through it instead of
/// `CaptureGate.typing`, which refuses every browser. It never opens what the
/// capture gate denies for every app: excluded apps and sites, password
/// managers, secure input, private windows, sensitive fields, sign-in and
/// payment addresses, stale or unverified proofs. On top it needs Google
/// Chrome's proven normal-window text field (the Chrome join), an origin-only
/// address, and a site the person's choices allow (`site`, host only).
public enum WebTypingGate {
    public static let bundle = "com.google.Chrome"
    /// Chrome's text boxes: text fields, text areas (a contenteditable root is
    /// one) and editable combo boxes (search and autocomplete boxes; the join
    /// proves the combo box is its own editable root). The same set as
    /// `ChromeAXAccess.textBox`. A label is never needed.
    public static let roles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    public static func typing(_ p: FocusProof, policy: CapturePolicy, generation: UInt64, now: UInt64,
                              expanded: Bool = TypingRelease.open, site: (String) -> Bool) -> PrivacyDecision {
        if let denied = CaptureGate.common(p, policy: policy, generation: generation, now: now) { return denied }
        guard policy.typedText else { return CaptureGate.result(.blocked, .typingOff, p) }
        if CaptureGate.sensitiveField(p) { return CaptureGate.result(.blocked, .sensitiveField, p) }
        guard expanded else { return CaptureGate.result(.blocked, .browserTypingOff, p) }
        guard p.bundle == bundle, p.surface == .browser, !p.tabID.isEmpty, !p.documentID.isEmpty, !p.frameID.isEmpty,
              p.fieldStateVerified, p.frameAccessible, p.navigationStable, roles.contains(p.role),
              !p.subrole.lowercased().contains("secure") else { return CaptureGate.result(.unknown, .unknownFocus, p) }
        // Origin only: scheme://host[:port], nothing after it.
        guard let u = URLComponents(string: p.url), let host = u.host?.lowercased(), !host.isEmpty, ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              ["", "/"].contains(u.percentEncodedPath), u.query == nil, u.fragment == nil, u.user == nil, u.password == nil
        else { return CaptureGate.result(.blocked, .sensitiveURL, p) }
        guard site(host) else { return CaptureGate.result(.blocked, .excludedSite, p) }
        return CaptureGate.result(.allowed, .permitted, p)
    }
}
#endif
