import Foundation
import SafariServices

/// Containing extension's diagnostic entry. Bundle supplies reviewed PUBLIC pins.
/// No configuration defaults, capture handler, Keychain or group creation.
@objc(DaydreamSafariDiagnosticHandler)
public final class SafariDiagnosticHandler:NSObject,NSExtensionRequestHandling {
    public func beginRequest(with context:NSExtensionContext) {
        do {
            guard context.inputItems.count==1,
                let item=context.inputItems.first as? NSExtensionItem,
                let object=item.userInfo?[SFExtensionMessageKey] as? [String:Any],
                Set(object.keys)==["diagnostic"],JSONSerialization.isValidJSONObject(object) else {throw DiagnosticError.invalid}
            let data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
            _ = try DiagnosticWire.unwrap(data)
            let bundle=Bundle.main
            guard let group=bundle.object(forInfoDictionaryKey:"DaydreamDiagnosticAppGroup") as? String,!group.isEmpty,!group.contains("$"),
                let container=FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:group),
                let id=bundle.object(forInfoDictionaryKey:"DaydreamDiagnosticExtensionID") as? String,
                let deployment=bundle.object(forInfoDictionaryKey:"DaydreamDiagnosticDeployment") as? String,
                let pin=bundle.object(forInfoDictionaryKey:"DaydreamDiagnosticAppPublicKey") as? String,
                let key=Data(base64Encoded:pin) else {throw DiagnosticError.unavailable}
            let c=try DiagnosticConfiguration.load(setupDirectory:container.appendingPathComponent("BrowserSetup"),
                diagnosticDirectory:container.appendingPathComponent("BrowserDiagnostic"),
                browser:"safari",extensionID:id,deployment:deployment,trustedAppPublicKey:key)
            DispatchQueue.global(qos:.utility).async {
                Self.finish(context,try? DiagnosticHost.exchange(data,configuration:c))
            }
        } catch {Self.finish(context,nil)}
    }
    private static func finish(_ context:NSExtensionContext,_ data:Data?) {
        let reply=NSExtensionItem()
        reply.userInfo=[SFExtensionMessageKey:data.flatMap{try? JSONSerialization.jsonObject(with:$0)} ??
            ["diagnosticError":"unavailable"]]
        context.completeRequest(returningItems:[reply],completionHandler:nil)
    }
}
