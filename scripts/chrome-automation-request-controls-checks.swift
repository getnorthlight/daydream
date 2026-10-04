import Foundation
@main enum ChromeAutomationRequestChecks {
    static func main() {
        let base = ["--fixture": "chrome", "--mode": "request-automation",
                    "--work-root": "/private/tmp/daydream-capture-fixture-control", "--expected-pid": "123"]
        precondition(ChromeAutomationRequestControls.request(base)?.seconds == 180)
        precondition(ChromeAutomationRequestControls.declaration != ChromeFrontInspectionControls.declaration)
        precondition(ChromeAutomationRequestControls.declaration != "chrome-empty-unsent-v1\n")
        for (key, value) in [("--input", "fixed-marker"), ("--window-id", "1"), ("--tab-id", "2"),
                             ("--origin", "https://x.com"), ("--mode", "inspect-front"),
                             ("--expected-pid", "0"), ("--expected-pid", "-1"),
                             ("--expected-pid", "2147483648"), ("--expected-pid", "１２３"),
                             ("--seconds", "NaN"), ("--seconds", "0"), ("--seconds", "301")] {
            var invalid = base; invalid[key] = value
            precondition(ChromeAutomationRequestControls.request(invalid) == nil)
        }
        var missing = base; missing.removeValue(forKey: "--expected-pid")
        precondition(ChromeAutomationRequestControls.request(missing) == nil)
        for seconds in ["30", "300"] {
            var valid = base; valid["--seconds"] = seconds
            precondition(ChromeAutomationRequestControls.request(valid) != nil)
        }
        for (status, state) in [(Int32(0), "allowed"), (-1744, "not-asked"), (-1743, "denied"),
                                (-600, "chrome-not-running"), (-50, "unknown")] {
            precondition(ChromeAutomationRequestControls.state(status) == state)
        }
        var ui = base; ui["--mode"] = "request-automation-ui"
        precondition(ChromeAutomationRequestControls.uiRequest(ui) != nil)
        precondition(ChromeAutomationRequestControls.request(ui) == nil)
        precondition(ChromeAutomationRequestControls.uiRequest(base) == nil)
        precondition(ChromeAutomationRequestControls.uiDeclaration != ChromeAutomationRequestControls.declaration)
        precondition(ChromeAutomationRequestControls.uiDeclaration != ChromeFrontInspectionControls.declaration)
        precondition(ChromeAutomationRequestControls.uiDeclaration != "chrome-empty-unsent-v1\n")
        ui["--input"] = "fixed-marker"
        precondition(ChromeAutomationRequestControls.uiRequest(ui) == nil)
        print("chrome automation request controls passed")
    }
}
