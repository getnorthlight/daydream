import Foundation
import MemoryCore

@main enum ChromeFrontInspectionControlChecks {
    static func main() {
        let valid = ["--fixture": "chrome", "--mode": "inspect-front",
                     "--work-root": "/private/tmp/daydream-capture-fixture-controlled",
                     "--expected-pid": "123"]
        precondition(ChromeFrontInspectionControls.request(valid)?.pid == 123)
        precondition(ChromeFrontInspectionControls.declaration == "chrome-front-metadata-v1\n")
        for change in [["--input": "fixed-marker"], ["--window-id": "1"], ["--tab-id": "2"],
                       ["--origin": "https://x.com"], ["--mode": "capture"],
                       ["--expected-pid": "0"], ["--expected-pid": "-1"],
                       ["--expected-pid": "2147483648"], ["--expected-pid": "１２３"],
                       ["--seconds": "nan"], ["--seconds": "0"], ["--seconds": "30"]] {
            var candidate = valid
            candidate.merge(change) { _, new in new }
            precondition(ChromeFrontInspectionControls.request(candidate) == nil)
        }
        var missing = valid; missing.removeValue(forKey: "--expected-pid")
        precondition(ChromeFrontInspectionControls.request(missing) == nil)
        precondition(ChromeFrontInspectionControls.uniqueWindowID([]) == nil)
        precondition(ChromeFrontInspectionControls.uniqueWindowID(["1", "2"]) == nil)
        precondition(ChromeFrontInspectionControls.uniqueWindowID(["1", "1"]) == nil)
        precondition(ChromeFrontInspectionControls.uniqueWindowID(["1"]) == "1")
        for origin in ["https://google.com","https://www.google.com"] {
            precondition(ChromeFrontInspectionControls.allowsDraftInspection(origin:origin,mode:"preflight"))
            for mode in ["capture","inspect-front","bootstrap",""] {
                precondition(!ChromeFrontInspectionControls.allowsDraftInspection(origin:origin,mode:mode))
            }
        }
        for origin in ["http://www.google.com","https://google.com.evil.invalid","https://mail.google.com","https://www.google.com/"] {
            precondition(!ChromeFrontInspectionControls.allowsDraftInspection(origin:origin,mode:"preflight"))
        }
        let exact = ChromeBounds(x:100,y:100,width:800,height:600)
        let roundedAX = ChromeBounds(x:100.5,y:100.5,width:800,height:600)
        let comparison = ChromeFrontInspectionControls.compareGeometry(exact, roundedAX)
        precondition(comparison.valid && !comparison.positionEqual && comparison.sizeEqual)
        precondition(!comparison.exactMatch && comparison.productionMatch)
        func match(_ candidates: [(String,ChromeBounds)], _ ax: ChromeBounds) -> String? {
            ChromeFrontInspectionControls.uniqueWindowID(candidates.filter {
                ChromeFrontInspectionControls.compareGeometry($0.1, ax).productionMatch
            }.map { $0.0 })
        }
        precondition(match([("1",exact)],exact) == "1")
        precondition(match([("1",exact)],roundedAX) == "1")
        precondition(match([],roundedAX) == nil)
        precondition(match([("1",exact),("2",exact)],exact) == nil)
        let nearby = ChromeBounds(x:101,y:101,width:800,height:600)
        precondition(match([("1",exact),("2",nearby)],roundedAX) == nil)
        precondition(match([("1",exact),("1",exact)],exact) == nil)
        precondition(match([("1",exact)],ChromeBounds(x:101.01,y:100,width:800,height:600)) == nil)
        precondition(match([("1",exact)],ChromeBounds(x:100,y:100,width:801,height:600)) == "1")
        let sized = ChromeFrontInspectionControls.compareGeometry(exact,ChromeBounds(x:100,y:100,width:800.5,height:600))
        precondition(sized.positionEqual && !sized.sizeEqual && sized.productionMatch)
        for invalid in [ChromeBounds(x:100,y:100,width:0,height:600),
                        ChromeBounds(x:.infinity,y:100,width:800,height:600),
                        ChromeBounds(x:100,y:100,width:800,height:-1)] {
            let comparison = ChromeFrontInspectionControls.compareGeometry(invalid,invalid)
            precondition(!comparison.valid && !comparison.exactMatch && !comparison.productionMatch)
            precondition(match([("1",invalid)],invalid) == nil)
        }
        let initial = match([("1",exact)],roundedAX)
        let final = match([("2",exact)],roundedAX)
        precondition(initial != nil && initial != final) // A changed unique ID is refused by the route.
        precondition(ChromeFrontInspectionControls.MatchCardinality(0) == .zero)
        precondition(ChromeFrontInspectionControls.MatchCardinality(1) == .one)
        precondition(ChromeFrontInspectionControls.MatchCardinality(2) == .ambiguous)
        let buffer = ChromeFrontInspectionControls.GeometryBuffer()
        for scan in [ChromeFrontInspectionControls.GeometryScan.initial,.final] {
            for ordinal in 0..<64 { buffer.record(.candidate(scan,ordinal,comparison)) }
            buffer.record(.summary(scan,0,1))
        }
        let records = buffer.drain()
        precondition(records.count == 130 && !buffer.truncated && buffer.drain().isEmpty)
        let candidate = records[0].receipt
        let allowed:Set<String> = ["phase","scan","candidateOrdinal","valid","positionEqual","sizeEqual","exactMatch","productionMatch"]
        precondition(Set(candidate.keys) == allowed)
        precondition(candidate["positionEqual"] as? Bool == false && candidate["productionMatch"] as? Bool == true)
        let summary = records[64].receipt
        precondition(summary["exactMatchCount"] as? Int == 0 && summary["productionMatchCount"] as? Int == 1)
        precondition(summary["exactCardinality"] as? String == "zero" && summary["productionCardinality"] as? String == "one")
        for _ in 0..<131 { buffer.record(.summary(.initial,0,0)) }
        precondition(buffer.truncated && buffer.drain().count == 130)
        print("PASS chrome front inspection controls and geometry/mapping/buffer assertions; headless, no OS calls")
    }
}
