// QA-only admission of a known owned composer. Production capture never calls this.
// The AXValue is used only for a zero-length Boolean and is never logged, saved,
// summarized, hashed or retained. No content is cleared or changed.
import Foundation
import ApplicationServices

#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
@MainActor enum BrowserFixtureEmptyGate {
    enum Result: String { case empty, scopeBefore, proofBefore, scopeAfter, proofAfter, late, unsupported, axFailure, nilValue, nonString, nonEmpty }
    struct Outcome {
        let result: Result
        let axError: Int32?
        var allowed: Bool { result == .empty }
    }
    static func run(deadline: UInt64, now: () -> UInt64,
                    scope: () -> Bool, proof: () -> Bool,
                    read: () -> (AXError, CFTypeRef?)) -> Outcome {
        func outcome(_ result: Result, _ error: AXError? = nil) -> Outcome {
            Outcome(result: result, axError: error?.rawValue)
        }
        guard now() < deadline else { return outcome(.late) }
        guard scope() else { return outcome(.scopeBefore) }
        guard proof() else { return outcome(.proofBefore) }
        guard now() < deadline else { return outcome(.late) }
        let (status, value) = read()
        // Reprove the exact retained field/document and default production proof
        // after the one read. A stale result never authorizes input.
        guard scope() else { return outcome(.scopeAfter) }
        guard proof() else { return outcome(.proofAfter) }
        guard now() < deadline else { return outcome(.late) }
        guard status == .success else {
            return outcome(status == .attributeUnsupported ? .unsupported : .axFailure, status)
        }
        guard let value else { return outcome(.nilValue, status) }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return outcome(.nonString, status) }
        // Do not trim whitespace or accept a missing/non-string value as empty.
        return outcome(CFStringGetLength((value as! CFString)) == 0 ? .empty : .nonEmpty, status)
    }
}
#endif
