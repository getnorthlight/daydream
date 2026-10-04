import Foundation
import SafariServices
import BrowserBridge
import BrowserDiagnostic

/// Compile in the containing app's Safari Web Extension target. The concrete
/// reference also retains the shared handler when BrowserBridge is statically linked.
@objc(DaydreamSafariEntry)
final class RequestHandler:NSObject,NSExtensionRequestHandling {
    func beginRequest(with context:NSExtensionContext) {
        if context.inputItems.contains(where: {
            (($0 as? NSExtensionItem)?.userInfo?[SFExtensionMessageKey] as? [String:Any])?.keys.contains("diagnostic") == true
        }) {
            SafariDiagnosticHandler().beginRequest(with:context)
            return // Diagnostic rejection never falls through to the capture handler.
        }
        SafariMetadataRequestHandler().beginRequest(with:context)
    }
}
