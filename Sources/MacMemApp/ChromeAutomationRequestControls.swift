#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
import Foundation

/// Owner-QA request authority, distinct from metadata inspection and draft capture.
enum ChromeAutomationRequestControls {
    static let mode = "request-automation"
    static let declaration = "chrome-automation-request-v1\n"
    static let uiMode = "request-automation-ui"
    static let uiDeclaration = "chrome-automation-request-ui-v1\n"
    struct Request: Equatable {
        let root: String
        let pid: Int32
        let seconds: Double
    }
    static func request(_ options: [String: String]) -> Request? {
        let required: Set<String> = ["--fixture", "--mode", "--work-root", "--expected-pid"]
        let permitted = required.union(["--seconds"])
        let supplied = Set(options.keys)
        guard required.isSubset(of: supplied), supplied.isSubset(of: permitted),
              options["--fixture"] == "chrome", options["--mode"] == mode,
              let root = options["--work-root"], !root.isEmpty, !root.contains("\0"),
              let pidText = options["--expected-pid"], !pidText.isEmpty,
              pidText.utf8.allSatisfy({ (48...57).contains($0) }),
              let pid = Int32(pidText), pid > 0,
              let seconds = Double(options["--seconds"] ?? "180"),
              seconds.isFinite, (30...300).contains(seconds) else { return nil }
        return Request(root: root, pid: pid, seconds: seconds)
    }
    static func uiRequest(_ options: [String: String]) -> Request? {
        guard options["--mode"] == uiMode else { return nil }
        var normalized = options
        normalized["--mode"] = mode
        return request(normalized)
    }
    static func state(_ status: Int32) -> String {
        switch status {
        case 0: return "allowed"
        case -1744: return "not-asked"
        case -1743: return "denied"
        case -600: return "chrome-not-running"
        default: return "unknown"
        }
    }
}

#endif
