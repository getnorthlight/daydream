import Foundation
import SafariServices

/// Principal-class source for the Safari containing Web Extension target.
/// No enrollment from messages, user data access or context classification here.
/// Root packages this with its exact extension ID and private app relay path.
@objc(DaydreamSafariMetadataRequestHandler)
public final class SafariMetadataRequestHandler:NSObject,NSExtensionRequestHandling {
    public func beginRequest(with context:NSExtensionContext) {
        guard context.inputItems.count==1,let item=context.inputItems.first as? NSExtensionItem,
              let object=item.userInfo?[SFExtensionMessageKey] as? [String:Any],object.count<=8,
              object.values.allSatisfy({ value in
                  if let text=value as? String{return text.utf8.count<=4096}
                  return value is NSNumber
              }),JSONSerialization.isValidJSONObject(object),
              let frame=try? JSONSerialization.data(withJSONObject:object),frame.count<=4096,
              let config=try? MetadataHostConfiguration.bundled(browser:.safari),
              (MetadataHello.decode(frame).map{$0.browser == .safari && $0.extensionID==config.extensionID}
                ?? SignedMetadataFrame.decode(frame).map{$0.browser == .safari && $0.extensionID==config.extensionID} ?? false)
        else {Self.finish(context,nil);return}
        DispatchQueue.global(qos:.utility).async {
            let response=try? MetadataLocalTransport.exchange(frame,directory:config.directory,deadline:DispatchTime.now().uptimeNanoseconds+2_000_000_000)
            Self.finish(context,response)
        }
    }
    private static func finish(_ context:NSExtensionContext,_ data:Data?) {
        let value=data.flatMap{try? JSONSerialization.jsonObject(with:$0)} ?? ["version":1,"kind":"unavailable","reason":"native_app_not_integrated","textEnabled":false]
        let reply=NSExtensionItem();reply.userInfo=[SFExtensionMessageKey:value]
        context.completeRequest(returningItems:[reply],completionHandler:nil)
    }
}
