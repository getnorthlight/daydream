import Foundation
import ApplicationServices

@main enum EmptyGateControls {
    @MainActor static func main() {
        typealias Gate = BrowserFixtureEmptyGate
        var checks = 0
        func check(_ expected: Gate.Result, status: AXError = .success, value: CFTypeRef? = "" as CFString,
                   scopeAnswers: [Bool] = [true, true], proofAnswers: [Bool] = [true, true], times: [UInt64] = [0, 0, 0], readsExpected: Int = 1) {
            var scopes = scopeAnswers, proofs = proofAnswers, ticks = times, reads = 0
            let outcome = Gate.run(deadline: 10, now: { ticks.removeFirst() },
                scope: { scopes.removeFirst() }, proof: { proofs.removeFirst() },
                read: { reads += 1; return (status, value) })
            precondition(outcome.result == expected && outcome.allowed == (expected == .empty))
            precondition(reads == readsExpected)
            checks += 1
        }
        check(.empty)
        check(.nonEmpty, value: "synthetic draft" as CFString)
        check(.nonEmpty, value: " \n" as CFString)
        check(.nilValue, value: nil)
        check(.nonString, value: kCFBooleanFalse)
        check(.unsupported, status: .attributeUnsupported, value: nil)
        check(.axFailure, status: .cannotComplete, value: nil)
        check(.scopeBefore, scopeAnswers: [false], proofAnswers: [], times: [0], readsExpected: 0)
        check(.proofBefore, scopeAnswers: [true], proofAnswers: [false], times: [0], readsExpected: 0)
        check(.scopeAfter, scopeAnswers: [true, false], proofAnswers: [true], times: [0, 0])
        check(.proofAfter, scopeAnswers: [true, true], proofAnswers: [true, false], times: [0, 0])
        check(.late, scopeAnswers: [], proofAnswers: [], times: [10], readsExpected: 0)
        check(.late, scopeAnswers: [true], proofAnswers: [true], times: [0, 10], readsExpected: 0)
        check(.late, times: [0, 0, 10])
        print("{\"checksPassed\":\(checks),\"actualUIReads\":false,\"inputPosted\":false}")
    }
}
