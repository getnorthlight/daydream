import Foundation

public enum PrivacyBoundary: Sendable {case focus, navigation, privateMode, policy, secureInput, pause, inputSource}
/// Synchronous host-owned state. Use exclusively on the capture serial executor.
/// No candidate buffers are stored here. invalidate marks a privacy boundary:
/// the host discards every pending typed unit. Ordinary seals (a pause, Return,
/// leaving the field) are not invalidations; they commit only the unit's own
/// proven keys after TypingSession's checks.
public final class CaptureAuthorization {
    public private(set) var generation:UInt64=1
    private var approved:PrivacyDecision?
    private var identity:[String]?
    public init() {}
    @discardableResult public func invalidate(_ boundary:PrivacyBoundary) -> UInt64 {
        generation &+= 1;approved=nil;identity=nil;return generation
    }
    public func classify(_ text:String,proof:FocusProof,policy:CapturePolicy,now:UInt64,compositionFinal:Bool=true) -> PrivacyDecision {
        let decision=TextClassifier.evaluate(text,proof:proof,policy:policy,generation:generation,now:now,compositionFinal:compositionFinal)
        // A decision is never authority for a different text buffer. Caller must
        // perform check+commit together and may not cache the allowed result.
        approved=decision.outcome == .allowed ? decision:nil
        identity=approved == nil ? nil : Self.identity(proof)
        return decision
    }
    /// Field identity: bundle, window, focus, tab, document, frame, URL and field metadata.
    static func identity(_ p:FocusProof) -> [String] {
        var identity=[p.bundle,p.windowID,p.focusID,p.tabID,p.documentID,p.frameID,p.url,p.role,p.subrole,p.fieldType,p.autocomplete,p.fieldLabel]
        // Messages can reuse one window and AX field for different conversations.
        // The unit's own validated body recipient is a boundary, including nil → named:
        // a later proof must never relabel or join words typed before that recipient.
        if p.bundle == "com.apple.MobileSMS" {
            let field=p.sendField.isEmpty ? SendRules.fieldClass(role:p.role,labels:[p.fieldLabel]) : p.sendField
            identity.append(SendRules.facts(bundle:p.bundle,title:p.place,field:field,seal:.idle).to ?? "")
        }
        return identity
    }
    public func revalidate(_ text:String,proof:FocusProof,policy:CapturePolicy,now:UInt64) -> PrivacyDecision {
        guard let approved,approved.generation==generation,approved.policyVersion==policy.version else {return CaptureGate.result(.unknown,.invalidated,proof)}
        guard identity == Self.identity(proof) else {return CaptureGate.result(.unknown,.generationChanged,proof)}
        return TextClassifier.evaluate(text,proof:proof,policy:policy,generation:generation,now:now)
    }
}
