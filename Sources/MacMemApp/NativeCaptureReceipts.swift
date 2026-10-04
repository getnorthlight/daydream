import Foundation
import MemoryCore

struct NativeCaptureReceipt:Equatable {
    enum Path:String {case metadata,typedText,keyMarker}
    let actionID:String
    let captureSessionID:String
    let sequence:UInt64
    let committedAt:Date
    let path:Path
    let actionRevision:String
}

/// Process-local commit authority. A receipt cannot be created by searching
/// records or calling a notification. Restart/pause discards its authority.
final class NativeCaptureReceipts {
    private let lock=NSRecursiveLock()
    private var sessionID:String?
    private var sequence:UInt64=0
    private var latest:NativeCaptureReceipt?
    func begin() {lock.lock();defer{lock.unlock()};sessionID=UUID().uuidString;sequence=0;latest=nil}
    func invalidate() {lock.lock();defer{lock.unlock()};sessionID=nil;latest=nil}
    /// Commits are authorized (begun and not invalidated since).
    var active:Bool {lock.lock();defer{lock.unlock()};return sessionID != nil}
    @discardableResult func commit(store:MemoryStore,path:NativeCaptureReceipt.Path,now:()->Date={Date()},write:(String)throws->Bool) throws -> NativeCaptureReceipt? {
        lock.lock();defer{lock.unlock()}
        guard let sessionID else {return nil}
        sequence += 1
        let id="native-\(sessionID)-\(sequence)"
        // Only this closure receives this fresh ID. A false return/throw never
        // creates a receipt; even a true return must pass durable readback.
        latest=nil
        guard try write(id),self.sessionID==sessionID else {return nil}
        // The row is saved. This read only proves it, for a receipt: a read that fails now leaves no receipt, never a
        // failed save (nothing to drop, pause or retry). A read that raced another connection's change ("Actions
        // changed; retry fresh read") is read once more, as the error asks.
        for attempt in 0..<2 {
            let time=now()
            do {
                guard let action=try store.action(id,now:time),let item=try store.read(id,now:time),
                      Self.allowed(item.evidence,path:path,commitTime:time),action.correction==nil else {return nil}
                let receipt=NativeCaptureReceipt(actionID:id,captureSessionID:sessionID,sequence:sequence,committedAt:time,path:path,actionRevision:action.revision)
                latest=receipt;return receipt
            } catch MemError.invalid(let text) where attempt == 0 && text == Self.actionsChanged {
                continue
            } catch {
                RecordingLog.note("Saved; its proof read failed: \(RecordingLog.name(error)).")
                return nil
            }
        }
        return nil
    }
    static let actionsChanged="Actions changed; retry fresh read"
    func validated(store:MemoryStore,now:Date=Date()) throws -> (NativeCaptureReceipt,CanonicalAction)? {
        lock.lock();defer{lock.unlock()}
        guard let receipt=latest,receipt.captureSessionID==sessionID,receipt.sequence==sequence,
              receipt.committedAt<=now,
              let action=try store.action(receipt.actionID,now:now),action.revision==receipt.actionRevision,action.correction==nil,
              let item=try store.read(receipt.actionID,now:now),Self.allowed(item.evidence,path:receipt.path,commitTime:receipt.committedAt) else {latest=nil;return nil}
        return (receipt,action)
    }
    private static func allowed(_ e:Evidence,path:NativeCaptureReceipt.Path,commitTime:Date)->Bool {
        guard !e.synthetic,!e.secure,!e.privateWindow,!e.bundle.isEmpty,
              let at=timestamp(e.at),at<=commitTime,commitTime.timeIntervalSince(at)<5,
              (!CaptureSession.excludedBrowsers.contains(e.bundle) ||
               ([BrowserSafety.pageProvider,BrowserSafety.appTimeProvider].contains(e.browserVerification?.provider ?? "") && BrowserSafety.valid(e))) else {return false}
        switch path {
        case .metadata:return ["window.changed","window.observed","focus.observed","app.activated","mouse.clicked","mouse.scrolled"].contains(e.kind)
        case .typedText:return e.kind=="keyboard.text_input" && e.captureProvenance != nil
        case .keyMarker:return ["keyboard.submit","keyboard.shortcut"].contains(e.kind)
        }
    }
}
