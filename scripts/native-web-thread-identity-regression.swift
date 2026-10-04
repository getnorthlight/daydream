import Foundation
import PrivacyPolicy
@main enum NativeWebThreadIdentityRegression {
    static func main() {
        var url = "https://claude.ai/chat/qa-thread-a"
        let base=NativeFocusAccess<Int>(now:{1},ready:{true},identity:{"qa-process-23"},focusedApplication:{23},window:{0},focus:{2},owner:{_ in 23},role:{$0==0 ? "AXWindow" : ($0==1 ? "AXWebArea" : "AXTextArea")},subrole:{_ in ""},parent:{$0==2 ? 1 : ($0==1 ? 0 : nil)},equal:{$0 == $1})
        let a=WebContentAccess<Int>(base:base,editable:{_ in true},url:{_ in .some(url)},label:{_ in ""})
        let witness=WebContentFocusWitness<Int>()
        guard let first=witness.read(pid:23,bundle:"com.anthropic.claudefordesktop",generation:1,policyVersion:1,access:a),
              let same=witness.read(pid:23,bundle:"com.anthropic.claudefordesktop",generation:1,policyVersion:1,access:a) else {fputs("FIXTURE_ERROR baseline refused\n",stderr);exit(2)}
        guard first.windowID==same.windowID,first.focusID==same.focusID else {fputs("FIXTURE_ERROR stable page negative control\n",stderr);exit(2)}
        url="https://claude.ai/chat/qa-thread-b"
        guard let switched=witness.read(pid:23,bundle:"com.anthropic.claudefordesktop",generation:1,policyVersion:1,access:a) else {fputs("FIXTURE_ERROR permitted owned page refused\n",stderr);exit(2)}
        url="https://foreign.example/chat"
        guard witness.read(pid:23,bundle:"com.anthropic.claudefordesktop",generation:1,policyVersion:1,access:a)==nil else {fputs("FIXTURE_ERROR foreign host negative control failed\n",stderr);exit(2)}
        let gap=first.windowID==switched.windowID && first.focusID==switched.focusID && switched.url.isEmpty && switched.documentID.isEmpty
        print("same-page identity retained: true; foreign-host proof refused: true")
        print("same-editor thread URL transition has unchanged capture identity: \(gap)")
        print("Synthetic source reproduction only; no AX, app, UI or input calls.")
        exit(gap ? 1 : 0)
    }
}
