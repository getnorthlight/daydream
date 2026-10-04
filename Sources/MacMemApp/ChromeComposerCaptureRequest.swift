import Foundation

#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING && DAYDREAM_CHROME_TYPING
struct ChromeComposerCaptureRequest {
    let root: String; let pid: Int32; let caseID: String
    static func knownLeafWithoutChildren(role: String, supported: [String]) -> Bool {
        supported.contains("AXRole") && !supported.contains("AXChildren") && ["AXStaticText","AXButton","AXImage","AXTextField","AXSearchField","AXComboBox","AXTextArea","AXLink","AXCheckBox","AXRadioButton","AXMenuItem","AXMenuBarItem","AXPopUpButton","AXSlider","AXProgressIndicator","AXScrollBar"].contains(role)
    }
    static func bootstrapCaptureSupported(_ id: String) -> Bool { id == "x-search-v1" }
    static func destination(_ id: String) -> String? {
        switch id { case "x-search-v1": return "x-search-home"; case "x-post-draft-v1": return "x-post-compose"; case "chatgpt-prompt-draft-v1": return "chatgpt-new-prompt"; default: return nil }
    }
    static func eligible(scenario: String, role: String, subrole: String, labels: [String]) -> Bool {
        guard destination(scenario) != nil, !subrole.lowercased().contains("secure") else { return false }
        if scenario == "x-search-v1" {
            return ["AXSearchField","AXTextField","AXComboBox"].contains(role) && (role == "AXSearchField" || labels.contains { ["search","search query","search x"].contains($0) })
        }
        return role == "AXTextArea"
    }
    static func parse(_ o: [String:String]) -> Self? {
        let required: Set<String> = ["--fixture","--mode","--scenario","--work-root","--expected-pid","--input"]
        guard required.isSubset(of: Set(o.keys)), Set(o.keys).isSubset(of: required.union(["--seconds"])),
              o["--fixture"] == "chrome", o["--mode"] == "site-capture", o["--input"] == "fixed-marker",
              let id = o["--scenario"], ["x-search-v1","x-post-draft-v1","chatgpt-prompt-draft-v1"].contains(id),
              let root = o["--work-root"], !root.isEmpty, let pid = o["--expected-pid"].flatMap(Int32.init), pid > 0,
              let seconds = Double(o["--seconds"] ?? "30"), seconds.isFinite, (20...45).contains(seconds) else { return nil }
        return .init(root: root, pid: pid, caseID: id)
    }
}
#endif
