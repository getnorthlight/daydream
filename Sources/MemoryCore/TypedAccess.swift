import Foundation
import CryptoKit

// Safe typing G: what connected AI apps, other processes and writers may see
// of what the person typed.
//
// - Every AI app is summary-only by default: "Typed in Notes, a sentence".
// - Exact words need the grant scope `typed-exact`. The CLI `grant` never
//   issues it; it takes a separate owner action (`grantTypedWords`, or the
//   CLI `grant-typed-words`, which the DayDream app must confirm).
// - A `typed-exact` scope counts only with an HMAC made with the keyring's
//   grant key. The key is only in the DayDream app process, so a scope
//   written straight into SQL, or copied from another grant, is ignored.
// - The MCP, CLI and remote processes never hold a key, so every surface
//   there is summary-only by construction. Remote reads refuse `typed-exact`.
// - Writers (note summaries): the writer on this Mac reads the words while
//   typing is on (switch on, safe-typing consent, key ready), in memory and
//   only in the app process. The cloud writer does too, only while Cloud is the chosen writer (notice v2).
// - `hydrateTypedText(id, disclosure:, reader:)` is the only way to the words.

/// A connected AI app, identified exactly as `authorize` checks it.
public struct TypedReader: Equatable, Sendable {
    public var client: String
    public var recipient: String
    public var capability: String
    public init(client: String, recipient: String, capability: String) {
        self.client = client; self.recipient = recipient; self.capability = capability
    }
}

/// Who writes a note: a model on this Mac, or a cloud model. A writer of
/// unknown kind counts as cloud (the stricter rule).
public enum TypedWriterKind: String, Codable, Sendable {
    case local, cloud
    public var disclosure: TypedDisclosure { self == .local ? .localWriter : .cloudWriter }
}

/// What one AI app may see of typed words, as far as this process can tell.
public enum TypedWordsAccess: String, Codable, Sendable {
    /// Where and about how much, never the words (the default).
    case summaryOnly
    /// The app was allowed exact words, but only the DayDream app can check
    /// that permission and open the words (every MCP and CLI process).
    case appOnly
    /// Allowed, and checked with the key in this process.
    case exact
}

public enum TypedWordsGrantResult: String, Codable, Sendable {
    /// Signed with the key: the app may see exact words (in the DayDream app).
    case granted
    /// Recorded without a key (CLI). The DayDream app must confirm it.
    case pendingAppConfirmation = "pending_app_confirmation"
}

/// A `grant-typed-words` request waiting for the DayDream app.
public struct TypedWordsRequest: Codable, Equatable, Sendable {
    public var client: String
    public var recipient: String
    /// Bound to the grant's token: a new token voids the request.
    public var capabilityHash: String
    public var requestedAt: String
}

/// Plain words for replies and Settings.
public enum TypedAccessText {
    public static let appOnly = "The exact words are only available in the DayDream app in this version."
    /// owner/v1: no screen in this version confirms a request (typing-all decision 4), so the note says so.
    public static let pending = "Request saved. This version of the DayDream app can't confirm it yet, so this app sees only a short note about what you typed."
    public static let granted = "This app may see the exact words you typed, in the DayDream app."
    /// Settings row for one AI app (later run).
    public static func toggle(_ app: String) -> String { "Let \(app) see the exact words you typed" }
    public static let toggleHelp = "Otherwise it sees only a short note, like 'Typed in Slack, a sentence'."
    public static let exactTextIs = "typed by the person (state sent means it was sent); shown because the person allowed this app to see the exact words"
}

extension MemoryStore {
    public static let typedExactScope = "typed-exact"
    static let typedWordsRequestsID = "typed-exact-requests-v1"
    static let grantMACDomain = "daydream-grant/v1"

    /// What the grant MAC covers: client, recipient, every scope and the
    /// token's hash. Changing any of them breaks it.
    static func grantMACMessage(_ grant: ClientGrant) -> Data {
        Data([grantMACDomain, grant.client, grant.recipient, grant.scopes.sorted().joined(separator: ","), grant.capabilityHash].joined(separator: "\u{1f}").utf8)
    }

    func grantRow(client: String, recipient: String) throws -> ClientGrant? {
        guard let raw = try rows("SELECT body FROM grants WHERE id=?", [client + "\u{1f}" + recipient]).first?.first else { return nil }
        return try? decode(ClientGrant.self, raw)
    }
    private func saveGrant(_ grant: ClientGrant) throws {
        try exec("INSERT OR REPLACE INTO grants VALUES(?,?)", [grant.client + "\u{1f}" + grant.recipient, json(grant)])
    }

    /// True only where the typing key is loaded (the DayDream app) and the
    /// grant's `typed-exact` scope carries a MAC made with that key.
    func typedExactVerified(_ grant: ClientGrant) -> Bool {
        guard grant.scopes.contains(Self.typedExactScope), let mac = grant.mac.flatMap({ Data(base64Encoded: $0) }),
              let vault = attachedVault, vault.state == .ready, let key = vault.grantMACKey else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Self.grantMACMessage(grant), using: key)
    }
    /// The reader's grant exists, matches its token, and its exact-words scope verifies here.
    func verifiedTypedExact(_ reader: TypedReader) throws -> Bool {
        guard !reader.capability.isEmpty, let grant = try grantRow(client: reader.client, recipient: reader.recipient),
              grant.client == reader.client, grant.recipient == reader.recipient,
              grant.capabilityHash == fingerprint(reader.capability) else { return false }
        return typedExactVerified(grant)
    }

    /// `.exact` only for a verified exact-words grant; otherwise `.summary`.
    public func typedDisclosure(for reader: TypedReader?) throws -> TypedDisclosure {
        guard let reader else { return .summary }
        return try verifiedTypedExact(reader) ? .exact : .summary
    }
    /// What `read` tells this AI app about exact words.
    public func typedWordsAccess(for reader: TypedReader?) throws -> TypedWordsAccess {
        guard let reader, !reader.capability.isEmpty, let grant = try grantRow(client: reader.client, recipient: reader.recipient),
              grant.capabilityHash == fingerprint(reader.capability), grant.scopes.contains(Self.typedExactScope),
              !(grant.mac ?? "").isEmpty else { return .summaryOnly }
        if typedExactVerified(grant) { return .exact }
        // A process without the key can't check the permission; the app can,
        // and there a scope that doesn't verify is ignored.
        return attachedVault?.state == .ready ? .summaryOnly : .appOnly
    }

    /// Whether `hydrateTypedText` may open words for this kind of reader.
    func typedDisclosureAllows(_ disclosure: TypedDisclosure, reader: TypedReader?) throws -> Bool {
        switch disclosure {
        case .summary: return false
        case .owner: return true
        case .exact: return try reader.map(verifiedTypedExact) ?? false
        // writer/v2 (owner decision 2026-09-26): summaries on this Mac read the words whenever typing is on.
        // `hydrateTypedText` also needs the typing switch on and a ready key; this adds the safe-typing
        // consent of a row this key signed (a row changed by another process reads as consent 0).
        // The saved `shareWithSummaries` choice is no longer read here.
        // fix/typing-e2e (L2): reading is not capture. The consent's scope only gates what capture records now
        // (`TypedTextPolicy.consented`); it never hides words already recorded under a consent, so an upgrade to a
        // build that records in more places no longer takes the words away from the writers.
        case .localWriter: return try typedTextPolicy().readConsented
        // summaries/v3 (owner, 2026-09-27, decision 8 reversed): cloud summaries read the words only while the
        // person chose Cloud: typing consented (as for the writer on this Mac) and the app's saved summary writer is
        // "cloud", which it saves only after the cloud notice v2 was accepted (CloudActivation.enable refuses v1).
        // "This Mac only" (the local writer) and summaries off keep the cloud from reading anything.
        case .cloudWriter: return try typedTextPolicy().readConsented && summaryWriter()?.mode == "cloud"
        // claude/summary-1003 (owner decision 2026-10-03): AI apps read the words through the app's bridge only, which
        // verified the reader's grant and the setting first (`assistantTypedWords`); typing consent as for the writers.
        case .assistant: return try typedTextPolicy().readConsented
        }
    }

    /// The scopes an AI app holds, for Settings and checks. nil = no grant.
    public func grantScopes(client: String, recipient: String) throws -> [String]? {
        try grantRow(client: client, recipient: recipient)?.scopes
    }

    /// "Let <App> see the exact words you typed": a separate owner action on
    /// top of an existing grant with `detail`. In the DayDream app (key
    /// loaded) the grant is signed at once. Without a key (CLI) the request
    /// is recorded, and the DayDream app must confirm it
    /// (`confirmTypedWords`); until then the app stays summary-only.
    @discardableResult public func grantTypedWords(client: String, recipient: String, now: Date = Date()) throws -> TypedWordsGrantResult {
        lock.lock(); defer { lock.unlock() }
        guard writable else { throw MemError.denied }
        guard let grant = try grantRow(client: client, recipient: recipient), grant.scopes.contains("detail") else {
            throw MemError.invalid("Connect this AI app first (grant with detail), then allow exact words")
        }
        if attachedVault?.state == .ready { try signTypedExact(grant); return .granted }
        try transaction {
            var pending = try typedWordsRequests().filter { !($0.client == client && $0.recipient == recipient) }
            pending.append(TypedWordsRequest(client: client, recipient: recipient, capabilityHash: grant.capabilityHash, requestedAt: iso(now)))
            try exec("INSERT OR REPLACE INTO metadata VALUES(?,?)", [Self.typedWordsRequestsID, json(pending)])
        }
        return .pendingAppConfirmation
    }
    /// Requests from `grant-typed-words` waiting for the DayDream app.
    public func typedWordsRequests() throws -> [TypedWordsRequest] {
        guard let raw = try rows("SELECT body FROM metadata WHERE id=?", [Self.typedWordsRequestsID]).first?.first else { return [] }
        return (try? decode([TypedWordsRequest].self, raw)) ?? []
    }
    /// The owner confirms a pending request in the DayDream app. Needs the
    /// key, and the grant must still hold the token the request was made for.
    public func confirmTypedWords(client: String, recipient: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard writable else { throw MemError.denied }
        guard attachedVault?.state == .ready else { throw TypedTextError.typingLocked(typedVaultState) }
        guard let request = try typedWordsRequests().first(where: { $0.client == client && $0.recipient == recipient }),
              let grant = try grantRow(client: client, recipient: recipient), grant.capabilityHash == request.capabilityHash,
              grant.scopes.contains("detail") else {
            try dropTypedWordsRequest(client: client, recipient: recipient)
            throw MemError.invalid("This request is no longer valid. Ask again from the AI app's connection.")
        }
        try signTypedExact(grant)
    }
    private func signTypedExact(_ grant: ClientGrant) throws {
        guard let key = attachedVault?.grantMACKey else { throw TypedTextError.typingLocked(typedVaultState) }
        var next = grant
        next.scopes = Array(Set(grant.scopes + [Self.typedExactScope])).sorted()
        next.mac = nil
        next.mac = Data(HMAC<SHA256>.authenticationCode(for: Self.grantMACMessage(next), using: key)).base64EncodedString()
        try transaction {
            try saveGrant(next)
            try dropTypedWordsRequestWithinTransaction(client: grant.client, recipient: grant.recipient)
            try invalidateDisclosure()
        }
    }
    /// Back to summary-only for this app. Its other scopes stay.
    public func revokeTypedWords(client: String, recipient: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard writable else { throw MemError.denied }
        try transaction {
            if var grant = try grantRow(client: client, recipient: recipient) {
                grant.scopes.removeAll { $0 == Self.typedExactScope }; grant.mac = nil
                try saveGrant(grant)
            }
            try dropTypedWordsRequestWithinTransaction(client: client, recipient: recipient)
            try invalidateDisclosure()
        }
    }
    func dropTypedWordsRequest(client: String, recipient: String) throws {
        try transaction { try dropTypedWordsRequestWithinTransaction(client: client, recipient: recipient) }
    }
    func dropTypedWordsRequestWithinTransaction(client: String, recipient: String) throws {
        let rest = try typedWordsRequests().filter { !($0.client == client && $0.recipient == recipient) }
        if rest.isEmpty { try exec("DELETE FROM metadata WHERE id=?", [Self.typedWordsRequestsID]) }
        else { try exec("INSERT OR REPLACE INTO metadata VALUES(?,?)", [Self.typedWordsRequestsID, json(rest)]) }
    }
    /// Forget: no AI app keeps exact-word access or a pending request.
    func stripTypedExactGrantsWithinTransaction() throws {
        for row in try rows("SELECT body FROM grants") {
            guard var grant = try? decode(ClientGrant.self, row[0]), grant.scopes.contains(Self.typedExactScope) || grant.mac != nil else { continue }
            grant.scopes.removeAll { $0 == Self.typedExactScope }; grant.mac = nil
            try saveGrant(grant)
        }
        try exec("DELETE FROM metadata WHERE id=?", [Self.typedWordsRequestsID])
    }

    // MARK: Summary-only presentation for readers outside the app

    /// A typed item as any reader outside the DayDream app sees it: no words
    /// (sealed rows have none in the body; build 4 plain-text rows waiting
    /// for the upgrade have theirs removed here), a word-count line instead.
    static func withoutTypedWords(_ item: MemoryItem, status: TypedStatus?) -> MemoryItem {
        guard item.evidence.kind == "keyboard.text_input" else { return item }
        var copy = item
        copy.evidence.text = ""
        if copy.correction == nil { copy.summary = typedReaderLine(item.evidence, status: status) + "." }
        // fix/summary-sends QF-15: a detected send key is "submitted" here too, as `actions` says (Actions.swift): a send
        // gesture, not a delivery ("sent" stays receipt-only). A correction keeps its own state.
        if usedSendKey(item.evidence), ["typed", "observed"].contains(copy.actionState) { copy.actionState = "submitted" }
        return copy
    }
    /// The seal-time send fact of a typed row (typed-unit/v3 `send == "detected"`). Metadata only.
    static func usedSendKey(_ e: Evidence) -> Bool { e.kind == "keyboard.text_input" && e.captureProvenance?.unit?.send == "detected" }
    /// "Typed in Notes, a sentence (exact words not shared with AI apps)".
    static func typedReaderLine(_ e: Evidence, status: TypedStatus?) -> String {
        // Review G31: rows saved before the fix hold the bundle ID as the app: name it the way people see it.
        let app = AppNames.display(app: e.app, bundle: e.bundle)
        let sent = usedSendKey(e)
        if let status { return TypedLine.withoutWords(app: app, status: status, usedSendKey: sent) }
        let words = e.typed?.words ?? TypedWords.count(e.text)
        let where_ = sent ? "\(app), then used its send key" : app
        return words == 0 ? "Typed in \(where_) (text not kept)" : "Typed in \(where_), \(TypedWords.bucket(words)) (exact words not shared with AI apps)"
    }
    /// CLI `read`: the stored item without typed words.
    public func readerItem(_ id: String, now: Date = Date()) throws -> MemoryItem? {
        guard var item = try read(id, now: now) else { return nil }
        // fix/show-all: a page's own link stays on this Mac (Open Original in the app); the reply names its site only.
        item.evidence.page = nil
        guard item.evidence.kind == "keyboard.text_input" else { return item }
        return Self.withoutTypedWords(item, status: try typedStatuses([id], now: now)[id])
    }
}
