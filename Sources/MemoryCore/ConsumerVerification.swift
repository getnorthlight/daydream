import Foundation

/// Implement in the actual consumer adapter. This must traverse its configured
/// read path, not echo a supplied expected value or call a checkbox. Credentials
/// stay in the adapter and are never included in the saved receipt.
public protocol ReplacementConsumerProbe {
    var identity:String { get }
    var client:String { get }
    var recipient:String { get }
    var capability:String { get }
    func read(resource:String,nonce:String,deadline:Date) throws -> ConsumerReadback
}
public struct ConsumerReadback {
    public var nonce:String
    public var resource:String
    public var body:String
    public init(nonce:String,resource:String,body:String) { self.nonce=nonce; self.resource=resource; self.body=body }
}
public struct ConsumerVerificationReceipt:Codable {
    public var identity:String
    public var client:String
    public var recipient:String
    public var verifiedAt:String
    public var epoch:String
    public var actionID:String
    public var actionRevision:String
    public var responseDigest:String
}
extension MemoryStore {
    /// No service/capture changes. Probe execution is synchronous: adapter must
    /// enforce the provided transport deadline and callers must run off UI thread.
    /// Late returns are rejected; core cannot safely kill an arbitrary callback.
    public func verifyReplacementConsumers(_ probes:[any ReplacementConsumerProbe],required:[String],now:Date=Date()) throws -> [ConsumerVerificationReceipt] {
        guard !required.isEmpty, required.count <= 16, Set(required).count == required.count,
              probes.count == required.count, Set(probes.map(\.identity)) == Set(required) else { throw MemError.invalid("Executable consumer probes required for every configured replacement route") }
        let epoch=try actionReadEpoch()
        guard let action=try actions(limit:1,now:now,descending:true).actions.first else { throw MemError.invalid("Consumer read-back needs a permitted canonical action") }
        let uri=ActionResources.actionURI(action.id)
        var receipts=[ConsumerVerificationReceipt]()
        for probe in probes {
            guard !probe.identity.isEmpty, probe.identity.count <= 200 else { throw MemError.invalid("Exact consumer identity required") }
            try authorize(client:probe.client,recipient:probe.recipient,capability:probe.capability,scope:"detail")
            try authorize(client:probe.client,recipient:probe.recipient,capability:probe.capability,scope:"context")
            let nonce=UUID().uuidString, deadline=Date().addingTimeInterval(2)
            let reply=try probe.read(resource:uri,nonce:nonce,deadline:deadline)
            guard Date() <= deadline, reply.nonce == nonce, reply.resource == uri, reply.body.utf8.count <= 32_000,
                  let readback=try? decode(CanonicalAction.self,reply.body), readback == action else { throw MemError.invalid("Consumer canonical read-back mismatch or timeout") }
            let contextNonce=UUID().uuidString, contextDeadline=Date().addingTimeInterval(2)
            let context=try probe.read(resource:"macmem://current-context",nonce:contextNonce,deadline:contextDeadline)
            guard Date() <= contextDeadline, context.nonce == contextNonce, context.resource == "macmem://current-context",context.body.utf8.count <= 64_000,
                  let received=try? decode(CurrentActions.self,context.body), timestamp(received.generatedAt).map({ abs(Date().timeIntervalSince($0)) <= 5 }) == true else { throw MemError.invalid("Consumer current-context read-back invalid or expired") }
            let expected=try currentActions()
            guard received.status == expected.status, received.actions == expected.actions,
                  received.revision == expected.revision else { throw MemError.invalid("Consumer current-context route is stale or mismatched") }
            try authorize(client:probe.client,recipient:probe.recipient,capability:probe.capability,scope:"detail")
            try authorize(client:probe.client,recipient:probe.recipient,capability:probe.capability,scope:"context")
            guard try epoch == actionReadEpoch() else { throw MemError.invalid("Consumer verification invalidated by source/policy change") }
            receipts.append(ConsumerVerificationReceipt(identity:probe.identity,client:probe.client,recipient:probe.recipient,verifiedAt:iso(Date()),epoch:epoch,actionID:action.id,actionRevision:action.revision,responseDigest:fingerprint(reply.body+context.body)))
        }
        return receipts
    }
}
