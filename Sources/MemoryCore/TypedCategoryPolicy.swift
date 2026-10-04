import Foundation
import PrivacyPolicy

// Safe typing E in the store: the person's category choices (kept in the
// `typed-text-policy-v1` row) applied to the shipped table in
// `PrivacyPolicy.TypingCategories`. Deny-only everywhere:
// - the capture binding adds `typedExcludedBundles` to `CapturePolicy.excludedApps`;
// - `ingest` refuses a typed row whose app the policy does not permit, or
//   that arrives while typing is paused.

extension TypedCategoryChoices {
    public func isOn(_ category: TypingCategory) -> Bool {
        switch category {
        case .searchAndAI: return searchAndAI
        case .writing: return writing
        case .code: return code
        case .messagesAndEmail: return messagesAndEmail
        }
    }
    public mutating func set(_ category: TypingCategory, _ on: Bool) {
        switch category {
        case .searchAndAI: searchAndAI = on
        case .writing: writing = on
        case .code: code = on
        case .messagesAndEmail: messagesAndEmail = on
        }
    }
    public var enabled: Set<TypingCategory> { Set(TypingCategory.allCases.filter(isOn)) }
}

extension TypedTextPolicy {
    /// The app rule: not on the person's block list or the sensitive list,
    /// in the shipped table, its category on, and allowed by the release gate.
    /// Consent, the vault and a pause are separate (the effective switch).
    public func permits(bundle: String, blockedApps: [String] = [], expanded: Bool = TypingRelease.open) -> Bool {
        guard !bundle.isEmpty, !blockedApps.contains(bundle), !PrivacySettings.sensitiveApps.contains(bundle) else { return false }
        return TypingCategories.permits(bundle: bundle, on: categories.isOn, expanded: expanded)
    }
    /// Website rule for website typing (Chrome join, owner build). Always
    /// false while the release gate is closed. "Other websites" follow their
    /// own switch (owner decision 3).
    public func permitsSite(host: String, path: String = "/", expanded: Bool = TypingRelease.open) -> Bool {
        TypingCategories.permitsSite(host: host, path: path, on: categories.isOn, other: categories.otherWebsites, expanded: expanded)
    }
    /// Apps the capture binding denies typing in right now (deny-only).
    public func excludedBundles(expanded: Bool = TypingRelease.open) -> Set<String> {
        TypingCategories.excludedBundles(on: categories.isOn, expanded: expanded)
    }
    /// What the capture switch depends on in this row: consent, categories
    /// and whether a pause is running. Retention and sharing changes are not
    /// capture boundaries and do not drop the unfinished draft.
    public func captureFingerprint(now: Date) -> String {
        let on = TypingCategory.allCases.map { categories.isOn($0) ? "1" : "0" }.joined()
        return "typed-policy:c\(consented ? 1 : 0):\(on):w\(categories.otherWebsites ? 1 : 0):\(snoozed(now: now) ? "paused" : "live")"
    }
}

extension MemoryStore {
    /// The saved choices applied to the table: every app typing is denied in now.
    public func typedExcludedBundles() throws -> Set<String> { try typedTextPolicy().excludedBundles() }
    /// Switches one category (Settings checkbox). Other settings are kept.
    @discardableResult public func setTypingCategory(_ category: TypingCategory, on: Bool, now: Date = Date()) throws -> TypedTextPolicy {
        var next = try typedTextPolicy()
        next.categories.set(category, on)
        return try updateTypedTextPolicy(next, now: now)
    }
}
