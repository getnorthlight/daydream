// Standalone QA check: swiftc -D DAYDREAM_QA_HARNESS -D DAYDREAM_OWNER_TYPING -parse-as-library Sources/MacMemApp/RedditCombinedCaptureRequest.swift scripts/reddit-combined-capture-checks.swift
import Foundation
@main struct RedditCombinedChecks {
    static func main() {
        let good = ["--fixture":"chrome", "--work-root":"/private/tmp/daydream-capture-fixture-test",
                    "--expected-pid":"123", "--mode":"reddit-capture", "--scenario":"reddit-search-v1", "--input":"fixed-marker"]
        var checked = 0
        func expect(_ allowed: Bool, _ o: [String:String]) {
            checked += 1
            precondition((RedditCombinedCaptureRequest.parse(o) != nil) == allowed)
        }
        expect(true, good)
        for key in good.keys { var o = good; o.removeValue(forKey:key); expect(false,o) }
        for (key, values) in [
            "--mode":["capture","preflight","reddit-bootstrap",""],
            "--scenario":["reddit-post-title-v1","reddit-search","unknown",""],
            "--input":["operator","arbitrary-text",""],
            "--fixture":["textedit-workflow",""],
            "--expected-pid":["0","-1","999999999999","x"],
            "--seconds":["19","46","nan","inf","-inf","x"]
        ] {
            for value in values { var o=good;o[key]=value;expect(false,o) }
        }
        for key in ["--window-id","--tab-id","--origin","--url","--text","--execute","--send"] {
            var o=good;o[key]="injected";expect(false,o)
        }
        for value in ["20","30","45"] { var o=good;o["--seconds"]=value;expect(true,o) }
        let r = RedditCombinedCaptureRequest.parse(good)!
        precondition(r.pid == 123 && r.seconds == 30 && r.root == good["--work-root"])
        print("PASS \(checked) source-selected route controls; no GUI/input/capture.")
    }
}
