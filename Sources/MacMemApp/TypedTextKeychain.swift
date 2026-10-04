import Foundation
import Security
import LocalAuthentication
import MemoryCore

/// The typing keyring in the macOS Keychain: one generic password per
/// DayDream store, service "DayDream.TypedText", account
/// "keyring-v1:<core_store_id>", never synced, readable only while the Mac is
/// unlocked. Reads never show a prompt: a locked Keychain is reported as
/// `.locked` and typing stays paused.
///
/// Runtime only. Checks never construct this; they use InMemoryTypedKeyStore
/// (and MigratingTypedKeyStore over two of them).
/// The app attaches `KeychainTypedKeyStore.forStore(_:)` at launch
/// (`TypedTextLaunch.wire` in `MacMemApp.swift`), outside development trials.
///
/// `dataProtection` selects the data-protection keychain, where
/// ThisDeviceOnly holds and the item is not in the login keychain file that
/// Time Machine and Migration Assistant copy. Whether the Developer ID build
/// (team L76C3ZC66J) may use it is UNCONFIRMED until the signed MacBook test;
/// a build without the entitlement gets errSecMissingEntitlement, reported as
/// `.unsupported`, and `MigratingTypedKeyStore` then keeps the login keychain.
/// Settings names the place (`TypedKeyPlace`) and never claims "this device
/// only" for the login keychain.
final class KeychainTypedKeyStore: TypedKeyStore {
    static let service = TypedKeychainName.service
    static let accountPrefix = TypedKeychainName.accountPrefix
    private let dataProtection: Bool
    private let account: String
    init(storeID: String, dataProtection: Bool) {
        self.dataProtection = dataProtection
        account = Self.accountPrefix + storeID
    }

    /// The app's key store for one DayDream store: the data-protection
    /// keychain, moving an item found in the login keychain across once, or
    /// the login keychain when this build can't use the data-protection one.
    static func forStore(_ storeID: String) -> MigratingTypedKeyStore {
        let store = MigratingTypedKeyStore(primary: KeychainTypedKeyStore(storeID: storeID, dataProtection: true),
                                           legacy: KeychainTypedKeyStore(storeID: storeID, dataProtection: false))
        lastMade = store
        return store
    }
    /// The same two places, for Remove everything to delete a history's key (`UninstallTypingKeys`).
    /// Not remembered as the launch store, so Settings never names its place.
    static func forUninstall(_ storeID: String) -> MigratingTypedKeyStore {
        MigratingTypedKeyStore(primary: KeychainTypedKeyStore(storeID: storeID, dataProtection: true),
                               legacy: KeychainTypedKeyStore(storeID: storeID, dataProtection: false))
    }
    /// The key store the app made at launch (its vault holds it), so Settings can name the key's
    /// place. Read only; nothing here touches the Keychain.
    private static weak var lastMade: MigratingTypedKeyStore?
    /// Where the typing key lives, once the vault has loaded it: the data-protection keychain, or the
    /// login keychain on a build that can't use it. Settings shows the place line only while the
    /// vault is ready, so a place that was never read is never claimed.
    static var currentPlace: TypedKeyPlace? {
        lastMade.map { $0.location == .primary ? .dataProtectionKeychain : .loginKeychain }
    }

    private func base() -> [CFString: Any] {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service,
                                      kSecAttrAccount: account, kSecAttrSynchronizable: kCFBooleanFalse as Any]
        if dataProtection { query[kSecUseDataProtectionKeychain] = kCFBooleanTrue }
        return query
    }
    private func noPrompt() -> LAContext { let context = LAContext(); context.interactionNotAllowed = true; return context }
    private func failure(_ status: OSStatus) -> TypedKeyStoreError {
        switch status {
        case errSecItemNotFound: return .notFound
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable: return .locked
        case errSecMissingEntitlement: return .unsupported
        default: return .other(status)
        }
    }

    func load() throws -> Data? {
        var query = base()
        query[kSecReturnData] = kCFBooleanTrue; query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext] = noPrompt()
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return data
    }

    /// Rewrites the whole item in one call, or adds it when missing. The vault
    /// reads the item again before every change, so an item deleted while the
    /// app runs is never quietly re-created from memory.
    func save(_ data: Data) throws {
        var query = base(); query[kSecUseAuthenticationContext] = noPrompt()
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw failure(update) }
        var add = base()
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel] = TypedKeychainName.label
        add[kSecUseAuthenticationContext] = noPrompt()
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure(status) }
    }

    func delete() throws {
        var query = base(); query[kSecUseAuthenticationContext] = noPrompt()
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
}
