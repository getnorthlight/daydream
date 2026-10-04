import Foundation
import MemoryCore
import BrowserBridge

struct BrowserCaptureReceipt {
    let actionID:String,sessionID:String,actionRevision:String,captureEpoch:String
    let sequence:Int
    let committedAt:Date
}

enum BrowserReceiptReadback {
    /// Called only after CoreBrowserConnection.receive committed verified bytes.
    /// The request nonce, not a recent-record scan or callback, selects the row.
    static func read(store:MemoryStore,request:Data,now:Date)throws->BrowserCaptureReceipt? {
        guard let frame=SignedMetadataFrame.decode(request),let payload=Data(base64Encoded:frame.payload),
              let object=try JSONSerialization.jsonObject(with:payload) as? [String:Any],let nonce=object["nonce"] as? String else {return nil}
        let id="browser_"+fingerprint(frame.sessionID+"|"+nonce)
        guard let action=try store.action(id,now:now),action.correction==nil,let item=try store.read(id,now:now),
              !item.evidence.synthetic,item.evidence.text.isEmpty,item.evidence.title.isEmpty,
              item.evidence.bundle==frame.browser.bundle,
              ["browser.extension_observed","browser.extension_tab_visited"].contains(item.evidence.kind),
              let proof=item.evidence.browserVerification,proof.provider=="browser-extension-v3",
              proof.sessionID==frame.sessionID,proof.extensionID==frame.extensionID,
              proof.policyRevision == (try store.policy()).revision,
              let epoch=try store.captureStatus(now:now)["epoch"],proof.captureEpoch==epoch,
              try store.captureStatus(now:now)["state"]=="recording",
              let at=timestamp(item.evidence.at),at<=now,now.timeIntervalSince(at)<1 else {return nil}
        return BrowserCaptureReceipt(actionID:id,sessionID:frame.sessionID,actionRevision:action.revision,captureEpoch:epoch,sequence:frame.sequence,committedAt:now)
    }
}
