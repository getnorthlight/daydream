import Foundation
import CryptoKit
import PrivacyPolicy

// Safe typing settings (ideas D, E, F, G and the cloud rule), kept in ONE
// metadata row, `typed-text-policy-v1`, outside `PrivacySettings`. Changing
// them never rotates `PrivacySettings.revision`, so no note is wiped.
//
// A missing or unreadable row means the defaults with consent 0: typing
// stays locked until the person accepts the safe-typing screen.

/// How long the exact typed words are kept. After this, only a short summary
/// (a note bullet) or a stub with a word count stays.
public enum TypedRetention: String, Codable, CaseIterable, Sendable {
    case day1 = "1d", days7 = "7d", days30 = "30d", forever
    public static let `default` = TypedRetention.days7

    public var days: Int? {
        switch self {
        case .day1: return 1
        case .days7: return 7
        case .days30: return 30
        case .forever: return nil
        }
    }
    /// Picker text: "1 day", "7 days", "30 days", "Forever".
    public var label: String {
        switch self {
        case .day1: return "1 day"
        case .days7: return "7 days"
        case .days30: return "30 days"
        case .forever: return "Forever"
        }
    }
    /// Words typed before this moment are expired. nil keeps them.
    public func cutoff(now: Date) -> Date? { days.map { now.addingTimeInterval(-Double($0) * 86400) } }
    public func isShorter(than other: TypedRetention) -> Bool {
        switch (days, other.days) {
        case (.some(let a), .some(let b)): return a < b
        case (.some, .none): return true
        default: return false
        }
    }
    /// The confirmation shown before a shorter period applies.
    public var shorteningConfirmation: String { "This deletes the exact words older than \(label.lowercased()) now." }

    // An unknown value (a newer build's row) keeps words for the shortest time.
    public init(from decoder: Decoder) throws {
        self = TypedRetention(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .day1
    }
}

/// The removed "Let summaries read what you type" choice. Kept only so saved
/// rows decode; no writer reads it (writer/v2: summaries on this Mac read the
/// words while typing is on, cloud summaries never do, `typedDisclosureAllows`).
/// `localAndCloud` can't be saved (owner decision 8).
public enum TypedSummarySharing: String, Codable, CaseIterable, Sendable {
    case off, localOnly, localAndCloud
    public init(from decoder: Decoder) throws {
        self = TypedSummarySharing(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .off
    }
}

/// Which kinds of apps may record typing once typing is on. All four are on
/// by default (opt-out, owner 9/28): one click in Settings turns one off.
/// Apps outside the shipped table never.
public struct TypedCategoryChoices: Codable, Equatable, Sendable {
    public var searchAndAI = true
    public var writing = true
    public var code = true
    public var messagesAndEmail = true
    /// "Other websites" (owner decision 3): websites outside the four
    /// categories, except blocked sites, never in Incognito or Guest windows.
    /// On by default. Read only by website typing (`OwnerTyping`), which every
    /// release stage compiles in; unflagged local builds never type websites.
    public var otherWebsites = true
    public init(searchAndAI: Bool = true, writing: Bool = true, code: Bool = true, messagesAndEmail: Bool = true, otherWebsites: Bool = true) {
        self.searchAndAI = searchAndAI; self.writing = writing; self.code = code; self.messagesAndEmail = messagesAndEmail
        self.otherWebsites = otherWebsites
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        searchAndAI = try c.decodeIfPresent(Bool.self, forKey: .searchAndAI) ?? true
        writing = try c.decodeIfPresent(Bool.self, forKey: .writing) ?? true
        code = try c.decodeIfPresent(Bool.self, forKey: .code) ?? true
        // A missing value reads as the default (on); a saved false stays off.
        messagesAndEmail = try c.decodeIfPresent(Bool.self, forKey: .messagesAndEmail) ?? true
        otherWebsites = try c.decodeIfPresent(Bool.self, forKey: .otherWebsites) ?? true
    }
}

/// What a build can record typing in (review F2): the apps its capture gate
/// can read typing in, and whether it types websites. Saved with the consent:
/// a build that can record more than the scope accepted needs the safe-typing
/// screen accepted again, showing the new scope; typing stays off until then.
public struct TypedConsentScope: Codable, Equatable, Sendable {
    /// Bundle IDs, sorted.
    public var apps: [String]
    public var websites: Bool
    public init(apps: Set<String>, websites: Bool) { self.apps = apps.sorted(); self.websites = websites }
    /// This build: the capture gate's app allowlist (every category on) and
    /// website typing (`OwnerTyping`: every release stage, not unflagged local builds).
    public static var current: TypedConsentScope { TypedConsentScope(apps: CaptureGate.nativeApps, websites: OwnerTyping.enabled) }
    /// What a consent saved before scopes were kept covers: build 4's Notes
    /// and TextEdit, which every build's safe-typing screen covered, and no websites.
    public static let legacy = TypedConsentScope(apps: TypingRelease.buildFourApps, websites: false)
    /// True when everything `other` can record is inside this scope.
    public func covers(_ other: TypedConsentScope) -> Bool {
        Set(apps).isSuperset(of: other.apps) && (websites || !other.websites)
    }
    /// A missing or unreadable part reads as the narrowest (nothing accepted).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apps = ((try? c.decodeIfPresent([String].self, forKey: .apps)) ?? nil) ?? []
        websites = ((try? c.decodeIfPresent(Bool.self, forKey: .websites)) ?? nil) ?? false
    }
}

/// The `typed-text-policy-v1` row (SPEC 5.1).
public struct TypedTextPolicy: Codable, Equatable, Sendable {
    /// The safe-typing screen version that unlocks typing.
    public static let currentConsentVersion = 2
    public var version = 1
    /// 2 = accepted the safe-typing screen. 0 = typing locked.
    public var consentVersion = 0
    public var acceptedAt = ""
    /// What the accepted safe-typing screen covered (review F2). nil: saved
    /// before scopes were kept (`TypedConsentScope.legacy`).
    public var acceptedScope: TypedConsentScope?
    public var retention = TypedRetention.default
    public var categories = TypedCategoryChoices()
    public var shareWithSummaries = TypedSummarySharing.off
    /// ISO time; "" = not snoozed.
    public var snoozeUntil = ""
    /// Messages and email is on by default (opt-out, owner 9/28). true: this row was saved by a build where that is
    /// so, so its Messages and email value is the person's (a saved off is their opt-out). A row from an earlier build
    /// (missing: off was the default there) can't tell never chose from chose off, so it reads as never chose (on),
    /// unless an explicit off is on record (`MemoryStore.typedTextPolicy`, `SetupChoices.messagesAndEmail`).
    public var messagesOptOut = true
    /// Fingerprint of everything above; changes whenever the row changes.
    public var revision = ""

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        consentVersion = try c.decodeIfPresent(Int.self, forKey: .consentVersion) ?? 0
        acceptedAt = try c.decodeIfPresent(String.self, forKey: .acceptedAt) ?? ""
        // An unreadable scope reads as the narrowest one: this build asks again.
        acceptedScope = (try? c.decodeIfPresent(TypedConsentScope.self, forKey: .acceptedScope)) ?? nil
        retention = try c.decodeIfPresent(TypedRetention.self, forKey: .retention) ?? .default
        categories = try c.decodeIfPresent(TypedCategoryChoices.self, forKey: .categories) ?? TypedCategoryChoices()
        shareWithSummaries = try c.decodeIfPresent(TypedSummarySharing.self, forKey: .shareWithSummaries) ?? .off
        snoozeUntil = try c.decodeIfPresent(String.self, forKey: .snoozeUntil) ?? ""
        // A row from before Messages and email was opt-out: its off was that build's default, not a choice.
        messagesOptOut = try c.decodeIfPresent(Bool.self, forKey: .messagesOptOut) ?? false
        if !messagesOptOut { categories.messagesAndEmail = true }
        revision = try c.decodeIfPresent(String.self, forKey: .revision) ?? ""
    }

    /// Consent v2 given for everything this build can record (review F2).
    public var consented: Bool { consented(in: .current) }
    /// Consent v2 given, whatever scope it covered (fix/typing-e2e L2): what the writers need to read words
    /// already recorded. The scope gates only what capture records now (`consented`), never what was kept.
    public var readConsented: Bool { consentVersion >= Self.currentConsentVersion }
    /// Consent v2 given for a scope that covers `scope`. A consent saved
    /// before scopes were kept covers only `TypedConsentScope.legacy`.
    public func consented(in scope: TypedConsentScope) -> Bool {
        consentVersion >= Self.currentConsentVersion && (acceptedScope ?? .legacy).covers(scope)
    }
    /// The safe-typing screen was accepted, but for less than this build can
    /// record: typing is off until it is accepted again, showing the new scope.
    public var scopeWidened: Bool { scopeWidened(for: .current) }
    public func scopeWidened(for scope: TypedConsentScope) -> Bool {
        consentVersion >= Self.currentConsentVersion && !consented(in: scope)
    }
    /// True while "Don't record typing" is running. An unreadable time counts
    /// as snoozed until it is cleared (fail closed).
    public func snoozed(now: Date) -> Bool {
        guard !snoozeUntil.isEmpty else { return false }
        guard let until = timestamp(snoozeUntil) else { return true }
        return now < until
    }
    func stamped() -> TypedTextPolicy {
        var copy = self; copy.revision = ""
        copy.revision = fingerprint((try? json(copy)) ?? UUID().uuidString)
        return copy
    }
    /// A row the app can't verify (changed by something other than DayDream,
    /// for example `sqlite3` run by an agent with a shell): typing is locked
    /// (consent 0), summaries can't read typing, messages and email are off
    /// and words are kept at most 7 days. Turning typing on again signs it
    /// (`MemoryStore.turnOnTyping` turns the categories on again then).
    func unverified() -> TypedTextPolicy {
        var copy = safeForSetup()
        copy.categories.messagesAndEmail = false
        copy.consentVersion = 0; copy.acceptedAt = ""; copy.acceptedScope = nil
        copy.revision = "unverified-" + revision
        return copy
    }
    /// What "Turn on typing" signs from a row saved before the key existed:
    /// the person's consent and pause stay; the settings that widen what is
    /// kept or shared beyond the defaults go back to them. The categories are
    /// kept as saved (all four are on by default).
    func safeForSetup() -> TypedTextPolicy {
        var copy = self
        copy.shareWithSummaries = .off
        if !copy.retention.isShorter(than: .default) && copy.retention != .default { copy.retention = .default }
        return copy
    }
}

extension MemoryStore {
    static let typedPolicyID = "typed-text-policy-v1"

    static let typedPolicyMACID = "typed-text-policy-mac-v1"
    static let typedPolicyMACDomain = "daydream-typed-policy/v1"

    /// The saved typing settings, or the locked defaults when there are none.
    /// Where the typing key is loaded (the DayDream app), the row counts only
    /// with its MAC: anything else that wrote it (another process with
    /// `sqlite3`) gets `unverified()`, so it can't turn on cloud summaries of
    /// the words, keep them forever, turn on messages, or turn typing back on.
    /// Processes without the key (CLI, MCP) read the row as stored; they can
    /// never open words, whatever it says.
    public func typedTextPolicy() throws -> TypedTextPolicy {
        guard let raw = try rows("SELECT body FROM metadata WHERE id=?", [Self.typedPolicyID]).first?.first else { return TypedTextPolicy() }
        var value = (try? decode(TypedTextPolicy.self, raw)) ?? TypedTextPolicy()
        // A row from before Messages and email was opt-out reads it on (never chose), except an off the person set
        // where it was kept outside this row (`SetupChoices`); a row this build saves carries the choice itself.
        if !value.messagesOptOut {
            if (try? setupChoices())?.messagesAndEmail == .off { value.categories.messagesAndEmail = false }
            value.messagesOptOut = true
        }
        guard let key = attachedVault?.grantMACKey else { return value }
        return try typedPolicySigned(raw, key: key) ? value : value.unverified()
    }
    /// True when the stored row carries a MAC made with this keyring.
    public func typedTextPolicyVerified() throws -> Bool {
        guard let raw = try rows("SELECT body FROM metadata WHERE id=?", [Self.typedPolicyID]).first?.first,
              let key = attachedVault?.grantMACKey else { return false }
        return try typedPolicySigned(raw, key: key)
    }
    private func typedPolicySigned(_ raw: String, key: SymmetricKey) throws -> Bool {
        guard let mac = try rows("SELECT body FROM metadata WHERE id=?", [Self.typedPolicyMACID]).first?.first.flatMap({ Data(base64Encoded: $0) }) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data((Self.typedPolicyMACDomain + "\u{1f}" + raw).utf8), using: key)
    }
    /// Saves the row, signed when the key is loaded. Without it the MAC row is
    /// removed, so the app reads the change as unverified (typing locked).
    /// Review G43: while the Keychain holds a typing key this process can't
    /// read now (`.locked`, also when the vault flipped during this call)
    /// nothing is saved and the transaction rolls back: dropping the MAC then
    /// would make the settings read as unverified after the unlock (consent
    /// gone; retention, categories and sharing reset; older words deleted).
    /// Only Forget, which turns typing off anyway, saves unsigned then
    /// (`unsignedWhileLocked`).
    func saveTypedTextPolicyWithinTransaction(_ value: TypedTextPolicy, unsignedWhileLocked: Bool = false) throws {
        let key = attachedVault?.grantMACKey
        if key == nil, !unsignedWhileLocked, attachedVault?.state == .locked { throw TypedTextError.typingLocked(.locked) }
        let body = try json(value.stamped())
        try exec("INSERT OR REPLACE INTO metadata VALUES(?,?)", [Self.typedPolicyID, body])
        if let key {
            let mac = Data(HMAC<SHA256>.authenticationCode(for: Data((Self.typedPolicyMACDomain + "\u{1f}" + body).utf8), using: key)).base64EncodedString()
            try exec("INSERT OR REPLACE INTO metadata VALUES(?,?)", [Self.typedPolicyMACID, mac])
        } else {
            try exec("DELETE FROM metadata WHERE id=?", [Self.typedPolicyMACID])
        }
    }
    /// "Turn on typing" signs a row saved before the key existed, with
    /// `safeForSetup()` applied. A row that already verifies is left alone.
    func signTypedPolicyAfterSetUp() throws {
        guard attachedVault?.grantMACKey != nil, try !typedTextPolicyVerified(),
              let raw = try rows("SELECT body FROM metadata WHERE id=?", [Self.typedPolicyID]).first?.first else { return }
        let value = (try? decode(TypedTextPolicy.self, raw)) ?? TypedTextPolicy()
        try transaction { try saveTypedTextPolicyWithinTransaction(value.safeForSetup()) }
    }

    /// Saves retention and categories (and the unused sharing value). Consent and snooze
    /// have their own calls and are kept as saved. A shorter retention
    /// deletes words at once and needs `confirmed: true`
    /// (`TypedRetention.shorteningConfirmation` is the text to show).
    /// Lengthening only affects words that still exist; nothing comes back
    /// (words past the old period are deleted before the change is saved).
    @discardableResult public func updateTypedTextPolicy(_ next: TypedTextPolicy, confirmed: Bool = false, now: Date = Date()) throws -> TypedTextPolicy {
        lock.lock(); defer { lock.unlock() }
        guard writable else { throw MemError.denied }
        // Review G43: as `acceptSafeTyping`, before the expiry pre-pass.
        guard attachedVault?.state != .locked else { throw TypedTextError.typingLocked(.locked) }
        let current = try typedTextPolicy()
        let shorter = next.retention.isShorter(than: current.retention)
        guard !shorter || confirmed else {
            throw MemError.invalid("Keeping the exact words for less time deletes older words now. \(next.retention.shorteningConfirmation) Confirm first.")
        }
        // The old "This Mac and cloud" value stays refused, confirmed or not, and nothing is changed. No saved
        // sharing value is read any more (writer/v2): which writer reads the words follows the summary writer the
        // person chose (TypedAccess `typedDisclosureAllows`, summaries/v3).
        guard next.shareWithSummaries != .localAndCloud else {
            throw MemError.invalid("This choice was removed. Summaries read what you type with the writer you chose.")
        }
        var value = current
        value.retention = next.retention; value.categories = next.categories; value.shareWithSummaries = next.shareWithSummaries
        // Words already past the current period are deleted under it first,
        // so a longer period never shows them again.
        if value.retention != current.retention { try expireTypedText(now: now) }
        try transaction {
            try saveTypedTextPolicyWithinTransaction(value)
            // What readers may see changes with the period; notes do not.
            if value.retention != current.retention { try invalidateDisclosure(invalidateSnapshots: false) }
        }
        if shorter { try expireTypedText(now: now) }
        return try typedTextPolicy()
    }
    /// The number of typed drafts a shorter period would delete now.
    public func typedRetentionChangeCount(_ proposed: TypedRetention, now: Date = Date()) throws -> Int {
        guard try hasTypedTables(), let cutoff = proposed.cutoff(now: now) else { return 0 }
        return try rows("SELECT created_at FROM typed_text").filter { timestamp($0[0]).map { $0 < cutoff } ?? true }.count
    }

    /// The person accepted the safe-typing screen (consent v2) for `scope`,
    /// what this build can record (the screen shows it). Creating the key is
    /// the separate `setUpTypedVault` step. Refused while the Keychain holds
    /// a typing key it can't read now (`.locked`): saving then would drop the
    /// settings' signature, and after the unlock they would read as
    /// unverified (retention, categories and sharing reset, older words
    /// deleted). Nothing is written; the app reads the key again first.
    @discardableResult public func acceptSafeTyping(now: Date = Date(), scope: TypedConsentScope = .current) throws -> TypedTextPolicy {
        lock.lock(); defer { lock.unlock() }
        guard writable else { throw MemError.denied }
        guard attachedVault?.state != .locked else { throw TypedTextError.typingLocked(.locked) }
        var value = try typedTextPolicy()
        value.consentVersion = TypedTextPolicy.currentConsentVersion; value.acceptedAt = iso(now); value.acceptedScope = scope
        try transaction { try saveTypedTextPolicyWithinTransaction(value) }
        return try typedTextPolicy()
    }

    /// fix/typing-e2e: the one ON path (setup, what's-new, the Settings switch), with no sheet and no second
    /// question: the switch and its one line are the consent (opt-out, owner 9/27). Accepts the safe-typing screen
    /// for everything this build records (`TypedConsentScope.current`, so an upgrade from a narrower build is
    /// covered), makes the typing key when there is none, turns on all four categories and Other websites, except
    /// Messages and email when the person turned that checkbox off (`SetupChoices.messagesAndEmail == .off`), and
    /// remembers the explicit choice (`SetupChoices.typing = .on`). The typing switch itself (`captureText`) is a
    /// preference: the app saves it through its preference path right after (`TypingModel.saveSwitch`).
    /// Refused, with nothing changed, while the Keychain holds a key this process can't read now.
    @discardableResult public func turnOnTyping(now: Date = Date()) throws -> TypedTextPolicy {
        try acceptSafeTyping(now: now, scope: .current)
        try setUpTypedVault(now: now)
        var choices = try setupChoices()
        let saved = try typedTextPolicy()
        var next = saved
        // fix/sx-all round 2: every category the person turned off in Settings stays off (not only Messages and email).
        for category in TypingCategory.allCases {
            next.categories.set(category, choices.categorySeed(category))
        }
        next.categories.otherWebsites = choices.otherWebsitesSeed
        if next.shareWithSummaries == .localAndCloud { next.shareWithSummaries = .off }
        if next != saved { try updateTypedTextPolicy(next, now: now) }
        choices.typing = .on; choices.at = iso(now)
        try saveSetupChoices(choices)
        return try typedTextPolicy()
    }
    /// The person turned the typing switch off (Settings, setup, Forget): remembered, so setup and what's-new keep
    /// it off. The switch itself is saved through the preference path.
    public func rememberTypingOff(now: Date = Date()) throws {
        var choices = try setupChoices()
        choices.typing = .off; choices.at = iso(now)
        try saveSetupChoices(choices)
    }
    /// The Messages and email checkbox, remembered (setup and `turnOnTyping` keep an explicit off).
    public func rememberMessagesChoice(_ on: Bool, now: Date = Date()) throws {
        var choices = try setupChoices()
        choices.messagesAndEmail = on ? .on : .off; choices.at = iso(now)
        var picked = choices.categories ?? [:]
        picked[TypingCategory.messagesAndEmail.rawValue] = on ? .on : .off
        choices.categories = picked
        try saveSetupChoices(choices)
    }
    /// fix/sx-all round 2: any category checkbox (or "otherWebsites", `SetupChoices.otherWebsitesKey`), remembered, so
    /// turning typing on again (Settings, setup, what's-new) keeps each explicit off.
    public func rememberCategoryChoice(_ key: String, _ on: Bool, now: Date = Date()) throws {
        if key == TypingCategory.messagesAndEmail.rawValue { return try rememberMessagesChoice(on, now: now) }
        var choices = try setupChoices()
        var picked = choices.categories ?? [:]
        picked[key] = on ? .on : .off
        choices.categories = picked; choices.at = iso(now)
        try saveSetupChoices(choices)
    }

    /// "Don't record typing for 10 minutes". Pressing it again while snoozed
    /// does nothing (it never extends). Returns the end time.
    @discardableResult public func snoozeTyping(minutes: Int = 10, now: Date = Date()) throws -> Date {
        lock.lock(); defer { lock.unlock() }
        guard writable else { throw MemError.denied }
        // Review G43: nothing is recorded while the key can't be read, and saving would drop the settings' signature.
        guard attachedVault?.state != .locked else { throw TypedTextError.typingLocked(.locked) }
        guard (1...24 * 60).contains(minutes) else { throw MemError.invalid("Pause typing for 1 minute to 24 hours") }
        var value = try typedTextPolicy()
        if value.snoozed(now: now), let until = timestamp(value.snoozeUntil) { return until }
        let until = now.addingTimeInterval(Double(minutes) * 60)
        value.snoozeUntil = iso(until)
        try transaction { try saveTypedTextPolicyWithinTransaction(value) }
        // The stored time (whole seconds), so a second press returns the same value.
        return timestamp(value.snoozeUntil) ?? until
    }
    /// "Record typing again".
    public func resumeTyping(now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        guard writable else { throw MemError.denied }
        guard attachedVault?.state != .locked else { throw TypedTextError.typingLocked(.locked) }
        var value = try typedTextPolicy()
        guard !value.snoozeUntil.isEmpty else { return }
        value.snoozeUntil = ""
        try transaction { try saveTypedTextPolicyWithinTransaction(value) }
    }
}
