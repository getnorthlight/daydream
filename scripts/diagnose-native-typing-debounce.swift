import Foundation
import PrivacyPolicy

// Synthetic diagnostic of native typing capture timing, before and after
// typed units.
//
// Before: each 0.7-second idle burst was a transient that expired two seconds
// after its first key. Anything typed for more than about 1.3 seconds without
// a pause was lost, and sustained typing lost characters. The obvious repair,
// an unconditional one-second commit, was rejected because it split a
// credential into fragments that each passed classification.
//
// After: TypingSession keeps one typed unit per field and commits it at
// natural boundaries (idle, Return, focus or pointer moves, size), with
// Backspace applied and every chunk, line, token and the typing log classified.
// The regression cases below keep both old failures and the rejected repair.
//
// Synthetic strings and a fake monotonic clock only. No event tap,
// permissions, app, persistent store, accessibility read or personal data.
@main struct NativeTypingDebounceDiagnostic {
    /// A fake host that drives TypingSession the way EventCapture does:
    /// intent from key code, proof before characters, live commit with a fresh
    /// proof, parked commit after the settle.
    final class Host {
        let s=TypingSession()
        var policy=CapturePolicy()
        var keyMap=TypingKeyMap()
        var clock:UInt64=10_000_000_000
        var field="field"
        private(set) var rows:[TypingCommit]=[]
        init() {policy.typedText=true}

        func proof() -> FocusProof {
            var p=FocusProof();p.generation=s.generation;p.policyVersion=policy.version;p.checkedAt=clock
            p.bundle="com.apple.TextEdit";p.windowID="window";p.focusID=field;p.role="AXTextArea"
            p.surface = .native;p.secureInput = .no;p.privateMode = .no
            p.verified=true;p.fieldStateVerified=true;p.frameAccessible=true;p.navigationStable=true
            return p
        }
        private func write(_ c:TypingCommit) -> Bool {rows.append(c);return true}
        private func live(_ reason:SealReason) {_=s.commitLive(fresh:proof(),reason:reason,policy:policy,now:clock,write:write)}
        private func resolve() {
            let destination=TypingDestination(proof:proof(),departure:DepartureState(secureInput:.no,bundle:"com.apple.TextEdit",focusSecure:.no))
            while s.resolveParked(destination:destination,secureInput:false,policy:policy,now:clock,write:write) != nil {}
        }
        /// Runs the idle, settle and housekeeping timers the host would schedule.
        func advance(_ seconds:Double) {
            let target=clock+UInt64(seconds*1_000_000_000)
            while let next=[s.idleDeadline,s.nextParkedDeadline,s.housekeepingDeadline].compactMap({$0}).min(),next<=target {
                clock=max(clock,next)
                if let parked=s.nextParkedDeadline,parked<=clock {resolve()}
                else if let idle=s.idleDeadline,idle<=clock {live(.idle)}
                else {s.expire(now:clock)}
            }
            clock=target
        }
        func key(_ code:Int64,_ characters:String="") {
            let p=proof()
            switch keyMap.intent(KeyStroke(keyCode:code),pressAndHold:false) {
            case .insert(let dead):
                guard CaptureGate.typing(p,policy:policy,generation:s.generation,now:clock).outcome == .allowed,
                      s.admit(p,now:clock) == nil else {return}
                let text=dead.map {$0.compose(characters)} ?? characters
                if let c=s.insert(text,proof:p,policy:policy,eventAt:clock,now:clock).commit {live(c)}
            case .edit(let op): if let c=s.apply(op,proof:p,policy:policy,eventAt:clock,now:clock).commit {live(c)}
            case .submit: live(.submit)
            case .split(let r): live(r)
            case .leave(let r,_): s.seal(r,now:clock,focusMoved:true);keyMap.reset()
            default: break
            }
        }
        /// "\u{8}" is Backspace.
        func type(_ text:String,every interval:Double=0.1) {
            for c in text {advance(interval);if c == "\u{8}" {key(51)} else {key(0,String(c))}}
        }
        /// Click another field: seal now, judge the destination after the settle.
        func click(to next:String) {s.seal(.pointer,now:clock,focusMoved:true);keyMap.reset();field=next}
        var texts:[String] {rows.map(\.text)}
    }

    static func main() {
        let short=Host();short.type("hello");short.advance(61) // an open tail waits for the 60 s idle
        precondition(short.texts == ["hello"])
        print("PASS CONTROL: a short typing burst is saved.")

        // Old failure 1: 1.4 s of typing plus the 0.7 s debounce outlived the
        // 2 s transient and saved nothing.
        let nearTTL=Host();nearTTL.type("ordinary words ");nearTTL.advance(31)
        precondition(nearTTL.texts == ["ordinary words "])
        print("PASS REGRESSION (old failure): 1.4 s of typing then idle is saved in full (was: nothing saved).")

        // Old failure 2: sustained typing lost characters.
        let sustained=Host();sustained.type(String(repeating:"ordinary ",count:5));sustained.advance(31)
        precondition(sustained.texts == [String(repeating:"ordinary ",count:5)])
        print("PASS REGRESSION (old failure): 4.5 s of sustained typing is saved without loss (was: characters lost).")

        // A long paragraph typed over minutes with thinking pauses: one run,
        // split at the first closed tail (a space or sentence end) after 1800
        // characters, rejoining exactly.
        let sentence="We walked along the river after lunch and talked about the plans for next spring. "
        let paragraph=String(repeating:sentence,count:30)
        let long=Host()
        for (i,word) in paragraph.split(separator:" ").enumerated() {
            long.type(word+" ",every:0.06)
            if i % 15 == 14 {long.advance(8)} // a thinking pause, shorter than idle
        }
        long.advance(31)
        precondition(long.texts.joined() == paragraph && long.rows.count == 2)
        precondition(long.rows.allSatisfy {$0.text.count <= 2000 && [" ","."].contains($0.text.last)} && long.rows[0].reason == .size)
        precondition(Set(long.rows.map(\.runID)).count == 1 && long.rows.map(\.part) == [1,2])
        print("PASS FIX: a \(paragraph.count)-character paragraph typed with pauses is saved as one run in \(long.rows.count) parts, split at a word boundary.")

        let corrected=Host();corrected.type("Teh\u{8}\u{8}\u{8}The quikc\u{8}\u{8}ck brown fox.");corrected.advance(31)
        precondition(corrected.texts == ["The quick brown fox."])
        print("PASS FIX: Backspace corrections are applied before saving.")

        let boundaries=Host()
        boundaries.type("send the draft");boundaries.key(36)
        boundaries.type("note in another field");boundaries.click(to:"other");boundaries.advance(0.5)
        precondition(boundaries.texts == ["send the draft","note in another field"] && boundaries.rows.map(\.reason) == [.submit,.pointer])
        print("PASS FIX: Return commits at once; a click commits after the 0.4 s settle confirms where focus went.")

        // The rejected repair: a one-second commit split a credential so each
        // fragment passed. Typed units have no periodic commit; a pause long
        // enough to commit inside a token withholds the cut-off part (it may
        // be a secret prefix) and the part that continues it.
        let token="sk-abcdefghijklmnop"
        let whole=Host();whole.type(token);whole.advance(61)
        precondition(whole.rows.isEmpty)
        let paused=Host();paused.type("the key sk-abcdefgh");paused.advance(61);paused.type("ijklmnop today.");paused.advance(31)
        precondition(paused.texts == ["the key [withheld]","[withheld] today."] && !paused.texts.joined().contains("sk-") && !paused.texts.joined().contains("ijkl"))
        print("PASS REGRESSION (rejected repair): a credential interrupted by a 61 s pause is withheld on both sides of the cut; no fragment is stored.")
        print("Diagnostic: typed units fix both old failures and keep the credential split closed. Synthetic only.")
    }
}
