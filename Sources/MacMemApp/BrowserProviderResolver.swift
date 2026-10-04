import Foundation
import Security
import CryptoKit
import BrowserBridge
import CoreIntegration

enum BrowserProviderError:Error {case missing,invalid,unreviewed,unsupported,changed}
/// Installed app build inputs, never incoming extension or checkbox values.
struct BrowserProviderConfiguration:Equatable {
    let directory:URL
    let keychainService:String
    let deployment:String
    let extensionID:String
    static func bundled(_ bundle:Bundle)throws->Self {
        guard let path=bundle.object(forInfoDictionaryKey:"DaydreamBrowserRelayDirectory") as? String,
              let service=bundle.object(forInfoDictionaryKey:"DaydreamBrowserKeychainService") as? String,
              let deployment=bundle.object(forInfoDictionaryKey:"DaydreamBrowserDeployment") as? String,
              let id=bundle.object(forInfoDictionaryKey:"DaydreamBrowserExtensionID") as? String,path.hasPrefix("/") else {throw BrowserProviderError.missing}
        let value=Self(directory:URL(fileURLWithPath:path,isDirectory:true),keychainService:service,deployment:deployment,extensionID:id)
        try value.validate();return value
    }
    func validate()throws {
        guard directory.isFileURL,directory.path.hasPrefix("/"),directory.resolvingSymlinksInPath().path==directory.standardizedFileURL.path,
              keychainService.range(of:"^[A-Za-z0-9][A-Za-z0-9.-]{3,199}$",options:.regularExpression) != nil,
              deployment.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              MetadataBrowser.chrome.acceptsExtensionID(extensionID) else {throw BrowserProviderError.invalid}
    }
}
/// Producer owns signature/schema/freshness verification and read-existing keys.
enum BrowserProviderResolver {
    static func bundled(_ bundle:Bundle)throws->BrowserCaptureProvider {
        let config=try BrowserProviderConfiguration.bundled(bundle)
        var code:SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL,[],&code)==errSecSuccess,let code,
              SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | (1 << 29)),nil)==errSecSuccess else {throw BrowserProviderError.unreviewed}
        // Structural resource seal only, not Gatekeeper/notarization acceptance.
        return try resolve(configuration:config,load:{try MetadataProductionSetup.existing(directory:config.directory,keychainService:config.keychainService)})
    }
    static func resolve(configuration:BrowserProviderConfiguration,load:@escaping()throws->MetadataProductionSetup,now:@escaping()->Date={Date()})throws->BrowserCaptureProvider {
        try configuration.validate()
        func resolveCurrent()throws->MetadataResolvedProvider {
            let value=try load().resolve(browser:.chrome,expectedDeployment:configuration.deployment,now:now())
            guard value.configuration.browser == .chrome,value.pins.browser == .chrome,
                  value.pins.extensionID==configuration.extensionID,value.configuration.extensionID==configuration.extensionID,
                  value.directory.standardizedFileURL.path==configuration.directory.standardizedFileURL.path,
                  value.configuration.relayDirectory==configuration.directory.path,
                  value.configuration.deployment==configuration.deployment else {throw BrowserProviderError.changed}
            guard value.integrationValidated,value.physicalDeviceValidated else {throw BrowserProviderError.unreviewed}
            return value
        }
        let admitted=try resolveCurrent()
        func current()->MetadataResolvedProvider? {
            guard let fresh=try? resolveCurrent(),fresh.configuration==admitted.configuration else {return nil}
            return fresh
        }
        return BrowserCaptureProvider(directory:admitted.directory,connection:{binding in
            let fresh=current()
            return CoreBrowserConnection(binding:binding,pins:fresh?.pins ?? admitted.pins,
                integrationValidated:fresh?.integrationValidated ?? false,physicalDeviceValidated:fresh?.physicalDeviceValidated ?? false)
        },validate:{current() != nil})
    }
}
/// Explicit native review consumes existing possession/readback APIs. No receipt
/// is minted by enrollment; physical validation belongs to producer setup.
final class BrowserEnrollmentReview {
    private let enrollment:MetadataEnrollment
    private let setup:MetadataProductionSetup
    private let directory:URL,deployment:String
    private var pending:MetadataEnrollmentChallenge?
    init(directory:URL,deployment:String,appKey:P256.Signing.PrivateKey)throws {
        self.directory=directory;self.deployment=deployment
        let file=try MetadataRegistrationFile(directory:directory)
        setup=try MetadataProductionSetup(directory:directory,appKey:appKey)
        enrollment=MetadataEnrollment(appKey:appKey,load:{try file.load(browser:$0,extensionID:$1)},save:{try file.save($0)})
    }
    static func existing(configuration:BrowserProviderConfiguration)throws->BrowserEnrollmentReview {
        try configuration.validate()
        return try Self(directory:configuration.directory,deployment:configuration.deployment,appKey:MetadataAppKeychain.loadOrCreate(service:configuration.keychainService,allowCreate:false))
    }
    func prepare(_ candidate:MetadataRegistration,now:UInt64)throws->MetadataEnrollmentChallenge {
        guard candidate.browser == .chrome else {throw BrowserProviderError.unsupported}
        let value=try enrollment.begin(candidate,now:now);pending=value;return value
    }
    func cancel() {if let pending {enrollment.cancel(pending.registration.browser)};pending=nil}
    func confirm(displayedFingerprint:String,displayedAppFingerprint:String,extensionSignature:Data,now:UInt64)throws->MetadataReviewedConfiguration {
        guard let held=pending else {throw BrowserProviderError.missing};pending=nil
        _=try enrollment.approve(browser:held.registration.browser,nonce:held.nonce,displayedFingerprint:displayedFingerprint,displayedAppFingerprint:displayedAppFingerprint,possessionSignature:extensionSignature,now:now)
        return try setup.reviewConfiguration(registration:held.registration,relayDirectory:directory,deployment:deployment,nativeHumanConfirmed:true)
    }
}
