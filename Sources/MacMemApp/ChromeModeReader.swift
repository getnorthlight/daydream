#if DAYDREAM_CHROME_TYPING
// Compiled only with -DDAYDREAM_CHROME_TYPING: every release build defines it; a plain swift build leaves this file out.
// The Apple Event sender and the Automation check are ChromeEventSender's, shared
// with Chrome page history. (Its only caller is the flagged ChromeTypingWitness.)
import AppKit
import Carbon
import MemoryCore

/// Only read-only AppleEvents, addressed to the already-running Chrome PID.
/// No script execution, JavaScript, launch, keystrokes or permission prompting.
/// Every event is `core/getd` of an allowlisted property (`ChromeAppleEvents`),
/// built by MemoryCore and re-audited by the one sender, `ChromeEventSender.send`.
enum ChromeModeReader {
    /// Per-event and whole-join deadlines (noext §2.2): 100 ms per Apple Event
    /// (never past the join's deadline), `BrowserTypingTiming.joinBudgetNanoseconds`
    /// for the full double-read join. fix/chrome-root: was 20 ms, which Apple
    /// Events count in ticks (1/60 s): about 16.7 ms, below the 17-25 ms a tenth
    /// of the events to Chrome take on the owner's Mac. A timed-out mode read
    /// refused the key as `notNormal`, as if an Incognito window were open.
    static let joinEventTimeout:TimeInterval=0.1
    static var joinBudget:TimeInterval { TimeInterval(BrowserTypingTiming.joinBudgetNanoseconds)/1_000_000_000 }

    /// One join's worth of reads against one Chrome PID, sharing one deadline.
    /// Only `ChromeJoinRequest` values can be expressed; each maps to exactly
    /// one allowlisted property and is audited again by `send`.
    struct JoinSession {
        let target:NSAppleEventDescriptor
        let deadline:Date
        /// QF-17: the bracketed design's reads use a longer per-event timeout inside their own budget.
        let eventTimeout:TimeInterval
        /// fix/chrome-root: a full join's session tells the always-on tally (`WebTypingRefusals`) when an event got
        /// no answer in time, so a refusal caused by a slow Chrome can be told apart (never which event or what).
        let tally:Bool
        init(pid:pid_t, budget:TimeInterval=ChromeModeReader.joinBudget, eventTimeout:TimeInterval=ChromeModeReader.joinEventTimeout, tally:Bool=false) {
            target=NSAppleEventDescriptor(processIdentifier:pid); deadline=Date().addingTimeInterval(budget); self.eventTimeout=eventTimeout
            self.tally=tally
        }
        func reply(_ request:ChromeJoinRequest) -> ChromeJoinReply? {
            let descriptor=ChromeEventSender.send(request.specifier,to:target,deadline:deadline,eventTimeout:eventTimeout,
                                   everyWindow:ChromeJoinRequest.everyWindow)
            let decoded=descriptor.flatMap(request.decode)
            if tally && descriptor == nil { WebTypingRefusals.shared.transportFailed() }
            #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
            if descriptor != nil && decoded == nil { ChromeEventSender.noteQA(.decodeFailed) }
            #endif
            return decoded
        }
    }
}
#endif
