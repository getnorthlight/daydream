import Foundation
import CryptoKit
import Security
import LocalAuthentication

/// Called only by containing-app setup. Tests inject in-memory app keys and do
/// not invoke Keychain. No synchronization, export API or automatic trust.
public enum MetadataAppKeychain {
    public static func loadOrCreate(service:String,allowCreate:Bool=true)throws->P256.Signing.PrivateKey {
        guard service.range(of:"^[A-Za-z0-9][A-Za-z0-9.-]{3,199}$",options:.regularExpression) != nil else {throw MetadataEnrollmentError.invalid}
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
            kSecAttrAccount as String:"browser-metadata-signing-v1",kSecAttrSynchronizable as String:false]
        func load()throws->P256.Signing.PrivateKey? {
            var result:CFTypeRef?
            let context=LAContext();context.interactionNotAllowed=true
            let status=SecItemCopyMatching(query.merging([kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne,
                kSecUseAuthenticationContext as String:context]){_,new in new} as CFDictionary,&result)
            if status==errSecItemNotFound{return nil}
            guard status==errSecSuccess,let data=result as? Data else {throw MetadataEnrollmentError.invalid}
            return try P256.Signing.PrivateKey(rawRepresentation:data)
        }
        if let key=try load(){return key}
        guard allowCreate else {throw MetadataEnrollmentError.unapproved}
        let candidate=P256.Signing.PrivateKey()
        let status=SecItemAdd(query.merging([kSecValueData as String:candidate.rawRepresentation,
            kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]){_,new in new} as CFDictionary,nil)
        guard status==errSecSuccess || status==errSecDuplicateItem,let saved=try load() else {throw MetadataEnrollmentError.invalid}
        return saved
    }
}
