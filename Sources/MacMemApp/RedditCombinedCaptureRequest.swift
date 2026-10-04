import Foundation
#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
struct RedditCombinedCaptureRequest {
    let root: String
    let pid: Int32
    let seconds: Double
    static func parse(_ options: [String: String]) -> Self? {
        let required: Set<String> = ["--fixture", "--work-root", "--expected-pid", "--mode", "--scenario", "--input"]
        guard required.isSubset(of: Set(options.keys)), Set(options.keys).isSubset(of: required.union(["--seconds"])),
              options["--fixture"] == "chrome", options["--mode"] == "reddit-capture",
              options["--scenario"] == "reddit-search-v1", options["--input"] == "fixed-marker",
              let root = options["--work-root"], let pid = options["--expected-pid"].flatMap(Int32.init), pid > 0,
              let seconds = Double(options["--seconds"] ?? "30"), (20...45).contains(seconds) else { return nil }
        return Self(root: root, pid: pid, seconds: seconds)
    }
}
#endif
