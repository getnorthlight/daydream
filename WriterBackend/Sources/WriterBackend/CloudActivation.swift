import Foundation
import Security

/// Secret storage only. Never persist action inputs, a key in settings JSON, or log values.
public protocol WriterSecureKeyStore: Sendable {
    func readSecret() async throws -> String
    func saveSecret(_ value: String) async throws
    func removeSecret() async throws
}
extension WriterKeychain: WriterSecureKeyStore {
    public func readSecret() async throws -> String { try read() }
    public func saveSecret(_ value: String) async throws {
        guard !value.isEmpty, value.utf8.count <= 4096, !value.contains("\r"), !value.contains("\n") else {throw WriterFailure.invalidInput}
        let identity: [CFString:Any] = [kSecClass:kSecClassGenericPassword,kSecAttrService:WriterKeychain.service,kSecAttrAccount:"owner"]
        let update=SecItemUpdate(identity as CFDictionary,[kSecValueData:Data(value.utf8)] as CFDictionary)
        if update == errSecItemNotFound {
            var item=identity
            item[kSecValueData]=Data(value.utf8)
            item[kSecAttrAccessible]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrSynchronizable]=false
            guard SecItemAdd(item as CFDictionary,nil) == errSecSuccess else {throw WriterFailure.unavailable}
        } else if update != errSecSuccess {throw WriterFailure.unavailable}
    }
    public func removeSecret() async throws {
        let status=SecItemDelete([kSecClass:kSecClassGenericPassword,kSecAttrService:WriterKeychain.service,kSecAttrAccount:"owner"] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {throw WriterFailure.unavailable}
    }
}

public struct CloudActivationBindings: Sendable {
    public let consent: @Sendable () async -> CloudConsent
    public let key: @Sendable () async throws -> String
    public let permits: CanonicalPolicyCheck
}

/// In-memory activation only. Startup is disabled even if Keychain contains a key.
/// Core must AND `permits` with its current privacy/revision policy and use commitNote.
/// Disable/policy changes invalidate every previously issued binding. Re-enable makes
/// a fresh cutoff, never an automatic historical backfill or request replay.
public actor CloudActivation {
    /// summaries/v3: 2 is the notice that says cloud summaries get the words you type. Accepting 1 no longer turns cloud on.
    public static let disclosureVersion=CloudConsent.currentVersion
    /// What cloud summaries send, and to whom, in the words the person reads before turning them on
    /// (setup's confirmation and Settings > Summaries). Same facts as `CloudConsent.disclosure`.
    /// fix/sx-all (owner decision 9/28, fix/day-card `NoteAudience.cloudView`): cloud summaries get Chrome page titles,
    /// cleaned of addresses, unread counts and app suffixes, with their sites.
    public static let disclosure="Cloud summaries send what DayDream records, including the words you type when typing is on, through OpenRouter to write your notes. OpenRouter is told to use only model hosts that don't keep your data. OpenRouter keeps the time and cost of each request, and keeps the text only if logging is on in your OpenRouter account. Usage charges apply. What is sent: app names, window titles, Chrome page titles and sites (without web addresses or unread counts), the words you type, and corrections you write to notes. Only activity from after you turn this on is sent; pasting a key alone sends nothing."
    /// One line for Settings: who gets the text.
    public static let destination="Sent through OpenRouter, which is told to use only model hosts that don't keep your data."
    private let store: any WriterSecureKeyStore
    private let now: @Sendable () -> Date
    private var enabled=false
    private var keyPresent=false
    private var cutoff: Date?
    private var policyRevision=""
    private var generation: UInt64=0
    private var changingKey=false
    public init(store: any WriterSecureKeyStore, now: @escaping @Sendable () -> Date = {Date()}) {self.store=store;self.now=now}

    /// Key paste does not accept disclosure or enable processing. Key changes disable.
    public func pasteKey(_ value: String) async throws {
        guard !changingKey else {throw WriterFailure.busy}
        guard !value.isEmpty,value.utf8.count<=4096,!value.contains("\r"),!value.contains("\n") else {throw WriterFailure.invalidInput}
        changingKey=true;disable();defer{changingKey=false}
        keyPresent=false
        try await store.saveSecret(value)
        keyPresent=true
    }
    /// Explicit user activation. A saved key may be used after restart, but its presence
    /// is checked only during this user action, never automatic launch-time reads.
    /// fix/sx-engine-battery: `since` is the cutoff of the first activation (saved with the switch), so a relaunch or a
    /// privacy change turning cloud back on never moves it: activity between the two is still written, and nothing from
    /// before the person first turned cloud on is ever sent. nil (turning the switch on) starts a new cutoff now.
    public func enable(acceptedDisclosureVersion: Int, currentPolicyRevision: String, since: Date? = nil) async throws {
        guard !changingKey,acceptedDisclosureVersion==Self.disclosureVersion,!currentPolicyRevision.isEmpty else {throw WriterFailure.denied}
        let ticket=generation
        if !keyPresent {
            let value=try await store.readSecret()
            guard !value.isEmpty else {throw WriterFailure.unavailable}
            guard generation==ticket,!changingKey else {throw WriterFailure.denied}
            keyPresent=true
        }
        let time=now()
        generation &+= 1;policyRevision=currentPolicyRevision;cutoff=since.map { min($0,time) } ?? time;enabled=true
    }
    public func disable() {generation &+= 1;enabled=false;cutoff=nil}
    /// fix/sx-all: the saved key, read only for the person's own click (the Settings switch turned on with an empty
    /// field) so it can be tried before the field asks for one. nil when none is saved. Never read at launch.
    public func savedKeyForExplicitUse() async -> String? {
        guard !changingKey, let value=try? await store.readSecret(), !value.isEmpty else {return nil}
        return value
    }
    /// When this activation began, while it is on (gold/notes G25): nothing at or before it is ever sent, so the app
    /// never queues such work. Read only; `permits` stays the authority.
    public func activeCutoff() -> Date? {enabled ? cutoff : nil}
    /// Any core policy change requires a new deliberate enable and new bindings.
    public func policyChanged() {disable()}
    public func deleteKey() async throws {
        guard !changingKey else {throw WriterFailure.busy}
        changingKey=true;disable();keyPresent=false;defer{changingKey=false}
        try await store.removeSecret()
    }
    public func consent() -> CloudConsent {CloudConsent(enabled:enabled,disclosureVersion:enabled ? Self.disclosureVersion : 0)}
    public func bindings() -> CloudActivationBindings {
        let ticket=generation
        return CloudActivationBindings(consent:{await self.consent(ticket:ticket)},key:{try await self.key(ticket:ticket)},permits:{request,actions in await self.permits(request,actions:actions,ticket:ticket)})
    }
    /// N18: Return and shortcut marker rows only mark "in use".
    static func marker(_ kind:String)->Bool {kind=="keyboard.submit" || kind=="keyboard.shortcut"}
    private func consent(ticket: UInt64) -> CloudConsent {ticket==generation ? consent() : CloudConsent()}
    private func key(ticket: UInt64) async throws -> String {
        guard enabled,ticket==generation else {throw WriterFailure.denied}
        let value=try await store.readSecret()
        guard enabled,ticket==generation else {throw WriterFailure.denied}
        return value
    }
    private func permits(_ request:CanonicalNoteRequest,actions:[NoteAction],ticket:UInt64) -> Bool {
        // fix/sx-engine-battery: no action-count cap. The ModelView fold and the 24 KB request limit bound what a note
        // costs, so a long moment is written in one request like any other. Browser actions are not refused here either
        // (the core decides what a cloud request holds, `NoteAudience`).
        guard enabled,ticket==generation,let cutoff,request.policyRevision==policyRevision,
              !actions.isEmpty,actions.count==request.actionCount else {return false}
        let time=now(),fractional=ISO8601DateFormatter(),whole=ISO8601DateFormatter()
        fractional.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        return actions.allSatisfy { action in
            guard let date=fractional.date(from:action.at) ?? whole.date(from:action.at) else {return false}
            return date > cutoff && date <= time
        }
    }
}
