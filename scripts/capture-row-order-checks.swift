import Foundation
import Darwin

@main enum RowOrderChecks {
    static func main() {
        var checks=0, failures=0
        func expect(_ ok:Bool,_ name:String) {
            checks += 1
            if !ok { failures += 1; print("FAIL "+name) }
        }
        let start="2026-10-01T08:36:06Z"
        func row(_ id:String,_ run:String,_ part:Int,_ at:String,_ began:String=start,_ text:String="") -> Evidence {
            var e=Evidence(id:id,at:at,kind:"keyboard.text_input",app:"TextEdit",bundle:"com.apple.TextEdit",text:text)
            e.captureProvenance=NativeCaptureProvenance(policyRevision:"fixture-policy",classifierVersion:"typed-unit/v3;typed-secret-scrubber/v1",windowID:"fixture-window",focusID:"fixture-focus",checkedAt:at,generation:3,
                unit:TypedUnitProvenance(runID:run,part:part,sealReason:"focus",startedAt:began,keys:text.count,edits:0,withheld:0,surface:"writing",field:"textArea",send:"unknown"))
            return e
        }
        func ids(_ rows:[Evidence]) -> [String] { CaptureFixtureTrial.orderedRows(rows).map(\.id) }
        // Actual099 B shape: first character sealed earlier, rest later; UUID order is reversed.
        let first=row("first","z-first",1,"2026-10-01T08:36:07Z",start,"b")
        let rest=row("rest","a-rest",1,"2026-10-01T08:36:09Z",start,"eta draft stays separate")
        expect(ids([rest,first])==["first","rest"],"actual tied-start reversed-UUID split")
        expect(CaptureFixtureTrial.orderedRows([rest,first]).map(\.text).joined()=="beta draft stays separate","unchanged literal groundtruth")
        expect(ids([first,rest])==["first","rest"],"input order independent")
        let part2=row("part2","z-first",2,"2026-10-01T08:36:08Z")
        expect(ids([rest,part2,first])==["first","part2","rest"],"same-run part order before other tied run")
        let oddPart2=row("odd2","z-first",2,"2026-10-01T08:36:05Z")
        expect(ids([oddPart2,first])==["first","odd2"],"same-run parts outrank reversed commit timestamps")
        let equal=row("equal","a-equal",1,first.at)
        expect(ids([first,equal])==["equal","first"],"equal commits deterministic run tie")
        let samePart=row("a-tie","z-first",1,first.at)
        expect(ids([first,samePart])==["a-tie","first"],"equal run part commit deterministic evidence tie")
        let earlierStart=row("early-start","zz",1,"2026-10-01T08:36:20Z","2026-10-01T08:36:01Z")
        expect(ids([first,earlierStart])==["early-start","first"],"actual started chronology remains primary")
        let badStart=row("bad-start","zz",1,"2026-10-01T08:36:04Z","bad")
        expect(ids([first,badStart])==["bad-start","first"],"invalid start falls back to commit")
        let badCommit=row("bad-commit","a-invalid",1,"bad")
        expect(ids([badCommit,first])==["first","bad-commit"],"invalid commit ranked after known time")
        var legacy=first;legacy.id="legacy";legacy.at="2026-10-01T08:36:03Z";legacy.captureProvenance=nil
        expect(ids([first,legacy])==["legacy","first"],"legacy timestamp ordering unchanged")
        expect(ids([]).isEmpty,"empty remains empty")
        expect(ids([rest])==["rest"],"singleton unchanged")
        // Comparator must give the same total order even when part and commit times disagree.
        let cycle=[first,oddPart2,rest,equal]
        func permutations(_ a:[Evidence]) -> [[Evidence]] {
            if a.isEmpty {return [[]]}
            return a.indices.flatMap {i -> [[Evidence]] in
                var b=a;let e=b.remove(at:i);return permutations(b).map {[e]+$0}
            }
        }
        let expected=ids(cycle)
        for p in permutations(cycle) {expect(ids(p)==expected,"permutation total ordering")}
        // Sorting is never a grant; unchanged scope/privacy predicates must still refuse.
        var owned=first;owned.text="";owned.typed=TypedRef(digest:"fixture-pointer",words:1)
        let identity:Set<String>=["fixture-window|fixture-focus"]
        expect(CaptureFixtureTrial.scoped([owned],identity,bundle:"com.apple.TextEdit"),"exact owned scope unchanged")
        for kind in 0..<7 {
            var unsafe=owned
            switch kind {
            case 0:unsafe.secure=true
            case 1:unsafe.privateWindow=true
            case 2:unsafe.synthetic=true
            case 3:unsafe.bundle="other"
            case 4:unsafe.text="plaintext"
            case 5:unsafe.typed=nil
            default:unsafe.captureProvenance?.focusID="other-field"
            }
            expect(!CaptureFixtureTrial.scoped(CaptureFixtureTrial.orderedRows([unsafe]),identity,bundle:"com.apple.TextEdit"),"sorting cannot admit unsafe scope \(kind)")
        }
        expect(!CaptureFixtureTrial.scoped([],identity,bundle:"com.apple.TextEdit"),"empty scope refused")
        print("row_order_checks=\(checks) failures=\(failures) no_capture=true no_input=true no_store=true")
        exit(failures == 0 ? 0 : 1)
    }
}
