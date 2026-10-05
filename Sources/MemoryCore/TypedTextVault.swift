import Foundation
import CryptoKit

// Encryption at rest for what the person types (safe typing, idea B).
//
// Typed words are sealed with AES-GCM under one 256-bit key per UTC day.
// The additional data binds each sealed row to its record id and its day, so
// a row copied to another id or day fails to open. All day keys, plus the key
// for grant MACs, live in ONE keyring item behind `TypedKeyStore`:
// - `InMemoryTypedKeyStore` for checks (never the real Keychain);
// - `KeychainTypedKeyStore` (MacMemApp) when the app runs.
// Only the DayDream app process holds a key store. The CLI and MCP process
// open the store without one, so they can never read typed words.

/// Where the keyring item lives. `load` returns nil when there is no item and
/// throws `.locked` when it can't be read without a prompt.
/// The Keychain item's names, in one place: the app's `KeychainTypedKeyStore` uses them, and the
/// uninstall steps (`UninstallSteps`) name the same item. One item per store: account
/// `accountPrefix + core_store_id`, so moving the history folder keeps its key (no rename, no copy).
public enum TypedKeychainName {
    public static let service = "DayDream.TypedText"
    public static let accountPrefix = "keyring-v1:"
    public static let label = "DayDream typing key"
}

public protocol TypedKeyStore: AnyObject {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

public enum TypedKeyStoreError: Error, Equatable, CustomStringConvertible {
    /// `unsupported`: this kind of keychain can't be used by this build (for
    /// example the data-protection keychain without its entitlement).
    case notFound, locked, unsupported, other(Int32)
    public var description: String {
        switch self {
        case .notFound: return "The typing key isn't in the Keychain."
        case .locked: return "The Keychain is locked, so the typing key can't be read right now."
        case .unsupported: return "This build can't use that keychain."
        case .other(let status): return "The Keychain returned an error (\(status))."
        }
    }
}

/// Key store for checks. Keeps the keyring item in memory only. `locked`
/// simulates a locked Keychain (errSecInteractionNotAllowed); `unsupported`
/// a keychain this build may not use; `failSaves` any other save error.
public final class InMemoryTypedKeyStore: TypedKeyStore {
    private let lock = NSLock()
    private var item: Data?
    private var isLocked = false
    private var isUnsupported = false
    private var failing = false
    private var saveCount = 0
    public init(item: Data? = nil) { self.item = item }
    public var locked: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isLocked }
        set { lock.lock(); isLocked = newValue; lock.unlock() }
    }
    public var unsupported: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isUnsupported }
        set { lock.lock(); isUnsupported = newValue; lock.unlock() }
    }
    public var failSaves: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failing }
        set { lock.lock(); failing = newValue; lock.unlock() }
    }
    /// The raw keyring item, for checks that corrupt or remove it.
    public var raw: Data? {
        get { lock.lock(); defer { lock.unlock() }; return item }
        set { lock.lock(); item = newValue; lock.unlock() }
    }
    public var saves: Int { lock.lock(); defer { lock.unlock() }; return saveCount }
    public func load() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if isUnsupported { throw TypedKeyStoreError.unsupported }
        if isLocked { throw TypedKeyStoreError.locked }
        return item
    }
    public func save(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if isUnsupported { throw TypedKeyStoreError.unsupported }
        if isLocked { throw TypedKeyStoreError.locked }
        if failing { throw TypedKeyStoreError.other(-25293) }
        item = data; saveCount += 1
    }
    public func delete() throws {
        lock.lock(); defer { lock.unlock() }
        if isUnsupported { throw TypedKeyStoreError.unsupported }
        if isLocked { throw TypedKeyStoreError.locked }
        item = nil
    }
}

/// Moves the keyring from an older place to a newer one, explicitly, instead
/// of reading "no item in the new place" as a lost key (which would turn every
/// sealed word into a stub). The app uses the data-protection keychain as
/// `primary` and the login keychain as `legacy`:
/// - load: the primary item; else the legacy item, copied to the primary and
///   then deleted from the legacy place; a primary this build can't use
///   (`unsupported`) falls back to the legacy place for good;
/// - save: where the keyring lives now;
/// - delete (Forget): both places.
/// `location` says where the keyring lives, so Settings only claims what holds.
public final class MigratingTypedKeyStore: TypedKeyStore {
    public enum Location: String, Sendable { case primary, legacy }
    private let lock = NSRecursiveLock()
    private let primary: TypedKeyStore, legacy: TypedKeyStore
    private var fallback = false
    public init(primary: TypedKeyStore, legacy: TypedKeyStore) { self.primary = primary; self.legacy = legacy }
    public var location: Location { lock.lock(); defer { lock.unlock() }; return fallback ? .legacy : .primary }

    public func load() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if fallback { return try legacy.load() }
        let current: Data?
        do { current = try primary.load() } catch TypedKeyStoreError.unsupported { fallback = true; return try legacy.load() }
        if let current {
            // A copy left in the legacy place (an interrupted move) is removed.
            if (try? legacy.load()) != nil { try? legacy.delete() }
            return current
        }
        guard let old = try legacy.load() else { return nil }
        do { try primary.save(old) } catch TypedKeyStoreError.unsupported { fallback = true; return old }
        // Only after the new copy is written: never a moment with no copy.
        try? legacy.delete()
        return old
    }
    public func save(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if fallback { return try legacy.save(data) }
        do { try primary.save(data) } catch TypedKeyStoreError.unsupported { fallback = true; try legacy.save(data) }
    }
    public func delete() throws {
        lock.lock(); defer { lock.unlock() }
        var failure: Error?
        do { try primary.delete() } catch TypedKeyStoreError.unsupported {} catch { failure = error }
        do { try legacy.delete() } catch { failure = failure ?? error }
        if let failure { throw failure }
    }
}

/// - notSetUp: no keyring and nothing sealed. Typing is locked until the
///   person turns it on, which creates the keyring.
/// - ready: keyring loaded; sealing and opening are allowed.
/// - locked: the Keychain can't be read without a prompt. Nothing is sealed
///   (capture discards units), nothing is opened.
/// - keyLost: sealed words exist (or existed) but the keyring is gone or
///   unreadable. The words become stubs; a new key is never made quietly.
/// - unavailable: this process has no key store (MCP, CLI, remote).
public enum TypedVaultState: String, Codable, Equatable {
    case notSetUp, ready, locked, keyLost, unavailable
}

public enum TypedTextError: Error, Equatable, CustomStringConvertible {
    /// Typed text reached the store without a ready vault. Nothing was saved.
    case typingLocked(TypedVaultState)
    /// The typing key can't be created in this state.
    case cannotSetUp(TypedVaultState)
    /// A sealed row failed to open (missing day key, wrong key or tampered).
    case openFailed
    /// Typed text reached the store before the person accepted the
    /// safe-typing screen (consent v2). Nothing was saved.
    case notAccepted
    public var description: String {
        switch self {
        case .typingLocked(let state): return "Typing is locked (\(state.rawValue)): what you type is saved only after it can be encrypted. Nothing was saved."
        case .cannotSetUp(let state): return "DayDream couldn't create its typing key in your Keychain (\(state.rawValue)), so typing stays off."
        case .openFailed: return "The exact words can't be opened."
        case .notAccepted: return "Typing is locked until you turn it on in Settings. Nothing was saved."
        }
    }
}

/// The keyring item's JSON: `{"version":1,"keys":{"2026-09-24":"<base64>"},"mac":"<base64>","store":"<core_store_id>"}`.
/// `store` binds the keyring to one DayDream store: a vault bound to another
/// store never uses, extends or drops it.
struct TypedKeyring: Codable, Equatable {
    var version = 1
    var keys: [String: String]
    var mac: String
    var store: String? = nil
}

public final class TypedTextVault {
    public static let aadPrefix = "daydream-typed/v1|"
    private let lock = NSRecursiveLock()
    private let keyStore: TypedKeyStore?
    private var keyring: TypedKeyring?
    private var current: TypedVaultState
    private var boundStore: String?

    /// perf2-1005: the Keychain read a seal makes first (`latest`) was on the main thread for every typed unit (laptop:
    /// `SecItemCopyMatching` from the main thread). While typing, the item is read ahead off the main thread
    /// (`prefetch`); a seal that writes nothing (its day key is already in the item) uses that read when it is at most
    /// `prefetchFresh` old and no vault in this process has written the item since. A seal that writes (a new day key),
    /// Forget, dropping keys and turning typing on always read the item at once, as before, so an item that disappeared
    /// is still never re-created from a copy.
    public static let prefetchFresh: UInt64 = 30_000_000_000
    /// A new read ahead at most this often while typing.
    public static let prefetchEvery: UInt64 = 10_000_000_000
    private static let writesLock = NSLock()
    private static var writes: UInt64 = 0
    static var writeGeneration: UInt64 { writesLock.lock(); defer { writesLock.unlock() }; return writes }
    private static func wrote() { writesLock.lock(); writes &+= 1; writesLock.unlock() }
    private var ahead: (data: Data?, at: UInt64, generation: UInt64)?
    private var aheadAsked: UInt64?
    /// Keychain reads made by this vault (the checks count them).
    public private(set) var keychainReads = 0
    private func load(_ keyStore: TypedKeyStore) throws -> Data? { keychainReads += 1; return try keyStore.load() }
    private static let aheadQueue = DispatchQueue(label: "daydream.typed-key-ahead", qos: .utility)

    /// While typing (any thread): reads the item ahead off the caller's thread, at most once per `prefetchEvery`,
    /// only while ready. `async`: false runs the read on the caller (the checks).
    public func prefetch(now: UInt64 = DispatchTime.now().uptimeNanoseconds, async: Bool = true) {
        lock.lock()
        guard keyStore != nil, current == .ready, aheadAsked.map({ now < $0 || now - $0 >= Self.prefetchEvery }) ?? true else { lock.unlock(); return }
        aheadAsked = now
        lock.unlock()
        let read = { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard let keyStore = self.keyStore, self.current == .ready else { return }
            let generation = Self.writeGeneration
            guard let data = try? self.load(keyStore) else { self.ahead = nil; return }
            self.ahead = (data, DispatchTime.now().uptimeNanoseconds, generation)
        }
        if async { Self.aheadQueue.async(execute: read) } else { read() }
    }
    /// The read ahead, used once: fresh and with no write since; nil otherwise.
    private func takeAhead(now: UInt64) -> Data?? {
        defer { ahead = nil }
        guard let a = ahead, now >= a.at, now - a.at <= Self.prefetchFresh, a.generation == Self.writeGeneration else { return nil }
        return .some(a.data)
    }

    /// nil key store means this process may never hold a key.
    public init(keyStore: TypedKeyStore?) {
        self.keyStore = keyStore
        current = keyStore == nil ? .unavailable : .notSetUp
    }
    public static func unavailable() -> TypedTextVault { TypedTextVault(keyStore: nil) }

    public var state: TypedVaultState { lock.lock(); defer { lock.unlock() }; return current }

    /// Ties this vault to one store (`core_store_id`). A vault serves one store
    /// only, and a keyring made for another store is never used.
    func bind(store id: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let boundStore, boundStore != id { throw TypedTextError.cannotSetUp(current) }
        boundStore = id
    }

    /// The UTC day that names a row's key.
    public static func epoch(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static func aad(id: String, epoch: String) -> Data { Data((aadPrefix + id + "|" + epoch).utf8) }

    /// What a stored item turned out to be.
    enum Reading { case ring(TypedKeyring), missing, newer, foreign, damaged }
    /// - newer: a later build's keyring (version above 1): never overwritten,
    ///   never read as lost; this build stays locked.
    /// - foreign: made for another store.
    func read(_ data: Data?) -> Reading {
        guard let data else { return .missing }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let version = object["version"] as? Int, version > 1 { return .newer }
        guard let ring = try? JSONDecoder().decode(TypedKeyring.self, from: data), ring.version == 1,
              Data(base64Encoded: ring.mac)?.count == 32,
              ring.keys.values.allSatisfy({ Data(base64Encoded: $0)?.count == 32 }) else { return .damaged }
        if let owner = ring.store, let boundStore, owner != boundStore { return .foreign }
        return .ring(ring)
    }

    /// Reads the keyring again. Never creates one. `hadWords` says whether
    /// sealed words exist (or a key loss was already recorded): with no
    /// readable keyring that is `keyLost`, otherwise `notSetUp`. A newer
    /// build's keyring, another store's keyring or a Keychain error is
    /// `locked`: never guessed at, never replaced.
    @discardableResult func refresh(hadWords: Bool) -> TypedVaultState {
        lock.lock(); defer { lock.unlock() }
        guard let keyStore else { current = .unavailable; return current }
        let data: Data?
        do { data = try load(keyStore) } catch { keyring = nil; current = .locked; return current }
        switch read(data) {
        case .ring(let ring): keyring = ring; current = .ready
        case .missing, .damaged: keyring = nil; current = hadWords ? .keyLost : .notSetUp
        case .newer, .foreign: keyring = nil; current = .locked
        }
        return current
    }

    /// The stored keyring as it is right now, read inside the lock before any
    /// change. Several vaults (one per writable store instance) may share one
    /// item: changing a cached copy could put back a dropped key or overwrite
    /// a key another vault just made. An item that disappeared (deleted in
    /// Keychain Access, or by Forget elsewhere) is never re-created from the
    /// cache: the vault becomes keyLost.
    private func latest() throws -> TypedKeyring {
        guard let keyStore else { throw TypedTextError.typingLocked(.unavailable) }
        let data: Data?
        do { data = try load(keyStore) } catch { keyring = nil; current = .locked; throw TypedTextError.typingLocked(.locked) }
        switch read(data) {
        case .ring(let ring): keyring = ring; return ring
        case .missing, .damaged: keyring = nil; current = .keyLost; throw TypedTextError.typingLocked(.keyLost)
        case .newer, .foreign: keyring = nil; current = .locked; throw TypedTextError.typingLocked(.locked)
        }
    }
    /// Writes a changed keyring. Any failure leaves the vault not ready
    /// (locked), so capture stops reading and the menu-bar dot goes away.
    private func store(_ ring: TypedKeyring) throws {
        Self.wrote(); ahead = nil
        do { try keyStore?.save(try Self.encode(ring)) } catch { keyring = nil; current = .locked; throw TypedTextError.typingLocked(.locked) }
        keyring = ring
    }

    /// The explicit "Turn on typing" step: a new keyring with a MAC key and no
    /// day keys yet. Only from notSetUp or keyLost (after the lost words were
    /// moved to stubs); never over a readable keyring. A keyring another vault
    /// made in the meantime is adopted instead.
    func create() throws {
        lock.lock(); defer { lock.unlock() }
        guard let keyStore, current == .notSetUp || current == .keyLost else { throw TypedTextError.cannotSetUp(current) }
        let existing: Data?
        do { existing = try load(keyStore) } catch { throw TypedTextError.cannotSetUp(current) }
        switch read(existing) {
        case .ring(let ring): keyring = ring; current = .ready; return
        case .newer, .foreign: throw TypedTextError.cannotSetUp(current)
        case .missing, .damaged: break
        }
        let ring = TypedKeyring(keys: [:], mac: Self.fresh(), store: boundStore)
        Self.wrote(); ahead = nil
        do { try keyStore.save(try Self.encode(ring)) } catch { throw TypedTextError.cannotSetUp(current) }
        keyring = ring; current = .ready
    }

    public var epochs: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(keyring.map { Array($0.keys.keys) } ?? []) }
    public func hasKey(epoch: String) -> Bool { lock.lock(); defer { lock.unlock() }; return keyring?.keys[epoch] != nil }
    /// For grant and policy MACs. nil unless ready.
    public var grantMACKey: SymmetricKey? {
        lock.lock(); defer { lock.unlock() }
        guard current == .ready else { return nil }
        return keyring.flatMap { Data(base64Encoded: $0.mac) }.map { SymmetricKey(data: $0) }
    }

    /// Seals `text` for record `id` on day `epoch`. Reads the stored keyring
    /// first; creates that day's key on first use and rewrites the item before
    /// any ciphertext exists.
    func seal(_ text: String, id: String, epoch: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard current == .ready, keyring != nil else { throw TypedTextError.typingLocked(current) }
        var ring: TypedKeyring
        if let data = takeAhead(now: DispatchTime.now().uptimeNanoseconds), case .ring(let early) = read(data), early.keys[epoch] != nil {
            keyring = early; ring = early
        } else { ring = try latest() }
        if ring.keys[epoch] == nil {
            ring.keys[epoch] = Self.fresh()
            if ring.store == nil { ring.store = boundStore }
            try store(ring)
        }
        guard let raw = ring.keys[epoch].flatMap({ Data(base64Encoded: $0) }) else { throw TypedTextError.typingLocked(current) }
        let box = try AES.GCM.seal(Data(text.utf8), using: SymmetricKey(data: raw), nonce: AES.GCM.Nonce(), authenticating: Self.aad(id: id, epoch: epoch))
        guard let combined = box.combined else { throw TypedTextError.typingLocked(current) }
        return combined
    }

    /// Opens a sealed row. Throws `.openFailed` for a missing day key, a wrong
    /// key, a changed byte, or a row moved to another id or day. A day key this
    /// vault hasn't seen yet (another vault made it) is looked up once.
    func open(_ sealed: Data, id: String, epoch: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard current == .ready, var ring = keyring else { throw TypedTextError.typingLocked(current) }
        if ring.keys[epoch] == nil, let keyStore, let stored = try? load(keyStore), case .ring(let fresh) = read(stored) { keyring = fresh; ring = fresh }
        guard let raw = ring.keys[epoch].flatMap({ Data(base64Encoded: $0) }),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: raw), authenticating: Self.aad(id: id, epoch: epoch)),
              let text = String(data: plain, encoding: .utf8) else { throw TypedTextError.openFailed }
        return text
    }

    /// Crypto-shred: removes these day keys from the stored keyring (read
    /// again first, so a key dropped elsewhere never comes back) and rewrites it.
    func dropKeys(_ drop: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }
        guard current == .ready else { throw TypedTextError.typingLocked(current) }
        var ring = try latest()
        let before = ring.keys.count
        for epoch in drop { ring.keys.removeValue(forKey: epoch) }
        guard ring.keys.count != before else { return }
        try store(ring)
    }

    /// Forget: deletes the keyring item. Every sealed word becomes unreadable.
    func destroy() throws {
        lock.lock(); defer { lock.unlock() }
        guard let keyStore else { throw TypedTextError.cannotSetUp(current) }
        Self.wrote(); ahead = nil
        try keyStore.delete()
        keyring = nil; current = .notSetUp
    }

    private static func fresh() -> String { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString() }
    private static func encode(_ ring: TypedKeyring) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ring)
    }
}
