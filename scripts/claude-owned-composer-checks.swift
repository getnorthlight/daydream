import Foundation
import ApplicationServices
#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
@main enum ClaudeOwnedComposerChecks {
    static func main() {
        var checks = 0
        func expect(_ value: Bool,_ name: String) { checks += 1; if !value { fputs("FAIL \(name)\n",stderr);exit(1) } }
        expect(ClaudeComposerMetadata.newURL("https://claude.ai/new"),"exact new path")
        for bad in [nil,"","about:blank","file:///new","https://other.example/new","https://sub.claude.ai/new","https://claude.ai/chat/old","https://claude.ai/new?x=1","https://claude.ai/new#x","https://u:p@claude.ai/new","https://claude.ai:443/new","https://claude.ai/n%65w"," https://claude.ai/new"] as [String?] {
            expect(!ClaudeComposerMetadata.newURL(bad),"missing opaque foreign or query URL refuses")
        }
        expect(ClaudeComposerMetadata.empty(status:.success,raw:NSNumber(value:0),timely:true),"typed numeric zero")
        for raw in [nil,kCFBooleanFalse,NSNumber(value:1),NSNumber(value:-1),NSNumber(value:0.25),NSNumber(value:Double.nan),"0" as CFString] as [CFTypeRef?] {
            expect(!ClaudeComposerMetadata.empty(status:.success,raw:raw,timely:true),"nil wrongtype nonzero count refuses")
        }
        expect(!ClaudeComposerMetadata.empty(status:.attributeUnsupported,raw:nil,timely:true),"unsupported count refuses")
        expect(!ClaudeComposerMetadata.empty(status:.noValue,raw:nil,timely:true),"absent count refuses")
        expect(!ClaudeComposerMetadata.empty(status:.cannotComplete,raw:NSNumber(value:0),timely:true),"failed transport refuses")
        expect(!ClaudeComposerMetadata.empty(status:.success,raw:NSNumber(value:0),timely:false),"late zero refuses")
        let good: [(ids:Set<String>,kind:String,state:String)] = [(Set(["a"]),"keyboard.text_input","draft")]
        expect(ClaudeComposerMetadata.drafts(rowIDs:Set(["a"]),actions:good),"persisted typed draft positive")
        expect(!ClaudeComposerMetadata.drafts(rowIDs:[],actions:good),"no sealed rows does not assert drafts")
        expect(!ClaudeComposerMetadata.drafts(rowIDs:Set(["a","b"]),actions:good),"missing row action coverage refuses")
        expect(!ClaudeComposerMetadata.drafts(rowIDs:Set(["a"]),actions:[]),"missing actions refuses")
        expect(!ClaudeComposerMetadata.drafts(rowIDs:Set(["a"]),actions:[(Set(["a"]),"keyboard.text_input","sent")]),"false send state refuses")
        expect(!ClaudeComposerMetadata.drafts(rowIDs:Set(["a"]),actions:[(Set(["a"]),"other","draft")]),"unrelated action kind refuses")
        final class State {
            var now: UInt64 = 1,ready = true,window = 0,editor = 3,empty = true,editable = true,pid:Int32 = 23,url = "https://claude.ai/new"
            var parents = [3:2,2:1,1:0],roles = [0:"AXWindow",1:"AXWebArea",2:"AXGroup",3:"AXTextArea"]
            var owners:[Int:Int32]=[:]
            var roleCalls = 0,emptyReads = 0,delay:UInt64 = 0
            var calls:[String]=[], diagnostics:[ClaudeComposerDiagnostic]=[]
            var report=true,issue:ClaudeEmptyIssue?=nil
            func access() -> ClaudeComposerAccess<Int> {
                ClaudeComposerAccess(now:{self.now},ready:{self.calls.append("ready");return self.ready},window:{self.calls.append("window");return self.window},editor:{self.calls.append("editor");return self.editor},owner:{n in self.calls.append("owner");return self.owners[n] ?? self.pid},role:{ n in self.calls.append("role");self.roleCalls += 1;self.now += self.delay;return self.roles[n]},parent:{self.calls.append("parent");return self.parents[$0]},equal:{$0 == $1},url:{_ in self.calls.append("url");return self.url},editable:{_ in self.calls.append("editable");return self.editable},empty:{_ in self.calls.append("empty");self.emptyReads += 1;return self.empty},emptyIssue:{self.issue},diagnostic:{if self.report {self.diagnostics.append($0)}})
            }
        }
        let s=State();let bound=ClaudeOwnedComposer.bind(pid:23,window:0,editor:3,access:s.access())
        expect(bound != nil,"fresh empty scope binds");expect(bound?.matches() == true,"retained scope matches");expect(bound?.initiallyEmpty() == true,"fresh before-arm empty check")
        s.roles[2]="AXWebArea";expect(bound?.matches() == false,"extra web area after binding refuses");s.roles[2]="AXGroup"
        s.roles[1]="AXGroup";expect(bound?.matches() == false,"original retained area loses its role refuses");s.roles[1]="AXWebArea"
        expect(bound?.matches() == true,"restored unique retained area matches")
        s.empty=false;expect(bound?.matches() == true,"text after own input does not demand empty");expect(bound?.initiallyEmpty() == false,"intervening text refuses before-arm")
        s.empty=true;s.url="https://claude.ai/chat/old";expect(bound?.matches() == false,"same retained editor foreign thread refuses")
        s.url="https://claude.ai/new";s.editor=2;expect(bound?.matches() == false,"focus moved refuses");s.editor=3
        s.window=4;expect(bound?.matches() == false,"window replaced refuses");s.window=0
        s.parents[3]=1;expect(bound?.matches() == false,"reparented editor refuses");s.parents[3]=2
        s.ready=false;expect(bound?.matches() == false,"current permission or secure gate refuses");s.ready=true
        s.editable=false;expect(bound?.matches() == false,"current editability lost refuses")
        for change in 0..<8 {
            let n=State()
            switch change {
            case 0:n.empty=false
            case 1:n.roles[1]=nil
            case 2:n.roles[2]="AXWebArea"
            case 3:n.parents[2]=3
            case 4:n.pid=24
            case 5:n.editable=false
            case 6:n.url="https://claude.ai/chat/old"
            default:n.roles[3]="AXSecureTextField"
            }
            expect(ClaudeOwnedComposer.bind(pid:23,window:0,editor:3,access:n.access()) == nil,"unproved whole context refuses")
        }
        let delayed=State();delayed.delay=50_000_001
        expect(ClaudeOwnedComposer.bind(pid:23,window:0,editor:3,access:delayed.access()) == nil,"aggregate deadline refuses")
        expect(delayed.roleCalls<=2 && delayed.emptyReads==0,"no subsequent reads or zero count after expired deadline")
        let success=State()
        expect(ClaudeOwnedComposer.bind(pid:23,window:0,editor:3,access:success.access()) != nil && success.diagnostics.isEmpty,"success emits no refusal or new permission authority")
        for change in 0..<9 {
            let enabled=State(), silent=State();silent.report=false
            func alter(_ n:State) {
                switch change {
                case 0:n.ready=false
                case 1:n.roles[3]=nil
                case 2:n.pid=24
                case 3:n.roles[2]="AXWebArea"
                case 4:n.url="https://claude.ai/chat/private-do-not-log"
                case 5:n.editable=false
                case 6:n.empty=false;n.issue = .nonzero
                case 7:n.delay=50_000_001
                default:n.parents[2]=nil
                }
            }
            alter(enabled);alter(silent)
            let a=ClaudeOwnedComposer.bind(pid:23,window:0,editor:3,access:enabled.access())
            let b=ClaudeOwnedComposer.bind(pid:23,window:0,editor:3,access:silent.access())
            expect(a == nil && b == nil,"diagnostic callback cannot admit failed scope")
            expect(enabled.calls == silent.calls,"diagnostic adds zero metadata reads or changes read order")
            let expected:[ClaudeGuardRefusal]=[.readiness,.roleUnusable,.ownerMismatch,.areaCount,.pageNotNew,.notEditable,.zeroUnverified,.deadline,.parentUnavailable]
            expect(enabled.diagnostics.count == 1 && enabled.diagnostics[0].refusal == expected[change],"fixed refusal class for existing result")
        }
        let observed=State();let o=ClaudeOwnedComposer.bind(pid:23,window:0,editor:3,access:observed.access())!
        observed.roles[2]="AXWebArea"
        expect(!o.matches() && observed.diagnostics.last?.phase == "retained-match" && observed.diagnostics.last?.areaCount == 2,"fresh role mutation reports actual area count")
        observed.roles[2]="AXGroup";observed.roles[1]="AXGroup"
        expect(!o.matches() && observed.diagnostics.last?.areaCount == 0,"original area role loss reports zero")
        observed.roles[1]="AXWebArea";observed.empty=false;observed.issue = .absent
        expect(!o.initiallyEmpty() && observed.diagnostics.last?.phase == "initial-empty" && observed.diagnostics.last?.emptyIssue == .absent,"before-arm zero failure reports typed status only")
        let backward=State();let backwards=ClaudeOwnedComposer.bind(pid:23,window:0,editor:3,access:backward.access())!
        // A fresh check's first clock is 1, then the ready callback turns the same fake clock back.
        var badClock:UInt64=1
        var ba=backward.access();ba = ClaudeComposerAccess(now:{badClock},ready:{badClock=0;return true},window:ba.window,editor:ba.editor,owner:ba.owner,role:ba.role,parent:ba.parent,equal:ba.equal,url:ba.url,editable:ba.editable,empty:ba.empty,diagnostic:{backward.diagnostics.append($0)})
        expect(ClaudeOwnedComposer.bind(pid:23,window:0,editor:3,access:ba) == nil && backward.diagnostics.last?.clockWentBackwards == true,"clock reversal refusal cannot extend deadline")
        _ = backwards
        let absent=State();absent.empty=false;absent.issue = .absent
        expect(ClaudeOwnedComposer.bind(pid:23,window:0,editor:3,access:absent.access()) == nil && absent.diagnostics.last?.refusal == .zeroUnverified && absent.diagnostics.last?.emptyIssue == .absent,"missing count is unverified zero, not observed nonempty")
        let cycle=State();cycle.parents[2]=2
        expect(ClaudeOwnedComposer.bind(pid:23,window:0,editor:3,access:cycle.access()) == nil && cycle.diagnostics.last?.refusal == .cycle && cycle.diagnostics.last?.roleClass == "other","permitted AXGroup cycle reports cycle, not unusable role")
        func chain(_ length:Int) -> State {
            let n=State();n.editor=length-1;n.parents=[:];n.roles=[:]
            for i in 0..<length {n.roles[i]=i==0 ? "AXWindow" : (i==1 ? "AXWebArea" : (i==length-1 ? "AXTextArea" : "AXGroup"));if i>0 {n.parents[i]=i-1}}
            return n
        }
        expect(ClaudeOwnedComposer<Int>.maxDepth == 64,"QA depth matches production embedded web bound")
        for length in [16,17,64] {
            let n=chain(length),b=ClaudeOwnedComposer.bind(pid:23,window:0,editor:n.editor,access:n.access())
            expect(b != nil && b?.matches() == true,"retained exact window/page/editor binds through bounded deep ancestry")
            expect(n.diagnostics.isEmpty,"successful deep path emits no false depth refusal")
        }
        let tooDeep=chain(65)
        expect(ClaudeOwnedComposer.bind(pid:23,window:0,editor:tooDeep.editor,access:tooDeep.access()) == nil,"65-node path cannot fit64")
        expect(tooDeep.diagnostics.last?.refusal == .depthLimit && tooDeep.diagnostics.last?.visitedCount == 64 && tooDeep.diagnostics.last?.depthLimitReached == true,"depth exhausted reports exact bounded visited count")
        expect(tooDeep.emptyReads == 0 && !tooDeep.calls.contains("url") && tooDeep.calls.filter{$0=="parent"}.count == 64,"depth exhaustion stops before page/field emptiness")
        let absentAtLimit=chain(65);absentAtLimit.parents[1]=nil
        expect(ClaudeOwnedComposer.bind(pid:23,window:0,editor:absentAtLimit.editor,access:absentAtLimit.access()) == nil && absentAtLimit.diagnostics.last?.refusal == .parentUnavailable && absentAtLimit.diagnostics.last?.depthLimitReached == false,"missing parent at final bounded read is not an observed deeper path")
        let deepCycle=chain(64);deepCycle.parents[32]=40
        expect(ClaudeOwnedComposer.bind(pid:23,window:0,editor:deepCycle.editor,access:deepCycle.access()) == nil && deepCycle.diagnostics.last?.cycleDetected == true && deepCycle.diagnostics.last?.refusal == .cycle,"deep cycle cannot become depth authority")
        let foreign=chain(64);foreign.owners[32]=24
        expect(ClaudeOwnedComposer.bind(pid:23,window:0,editor:foreign.editor,access:foreign.access()) == nil && foreign.diagnostics.last?.refusal == .ownerMismatch,"deep foreign owner refuses")
        let secure=chain(64);secure.roles[32]="AXSecureTextField"
        expect(ClaudeOwnedComposer.bind(pid:23,window:0,editor:secure.editor,access:secure.access()) == nil && secure.diagnostics.last?.refusal == .roleUnusable,"deep secure ancestor refuses")
        let multiple=chain(64);multiple.roles[32]="AXWebArea"
        expect(ClaudeOwnedComposer.bind(pid:23,window:0,editor:multiple.editor,access:multiple.access()) == nil && multiple.diagnostics.last?.areaCount == 2,"deep multiple web areas refuse")
        let wrongURL=chain(64);wrongURL.url="https://foreign.invalid/new"
        expect(ClaudeOwnedComposer.bind(pid:23,window:0,editor:wrongURL.editor,access:wrongURL.access()) == nil && wrongURL.diagnostics.last?.refusal == .pageNotNew,"deep foreign page refuses")
        let deadline=chain(64);deadline.delay=2_000_000
        expect(ClaudeOwnedComposer.bind(pid:23,window:0,editor:deadline.editor,access:deadline.access()) == nil && deadline.diagnostics.last?.refusal == .deadline,"deep path cannot extend100ms deadline")
        expect(deadline.roleCalls <= 51 && deadline.emptyReads==0 && !deadline.calls.contains("url"),"aggregate deadline stops subsequent reads on deep path")
        let mutated=chain(17);let retained=ClaudeOwnedComposer.bind(pid:23,window:0,editor:mutated.editor,access:mutated.access())!
        mutated.parents[8]=16
        expect(!retained.matches() && mutated.diagnostics.last?.cycleDetected == true,"retained deep path mutation refuses perkey")
        let samples:[(AXError,CFTypeRef?,Bool,ClaudeEmptyIssue?)]=[(.success,NSNumber(value:0),true,nil),(.cannotComplete,nil,true,.transport),(.attributeUnsupported,nil,true,.absent),(.noValue,nil,true,.absent),(.success,nil,true,.absent),(.success,kCFBooleanFalse,true,.wrongType),(.success,NSNumber(value:Double.nan),true,.invalidNumber),(.success,NSNumber(value:1),true,.nonzero),(.success,NSNumber(value:0),false,.late)]
        for (status,raw,timely,issue) in samples {expect(ClaudeComposerMetadata.emptyResult(status:status,raw:raw,timely:timely).issue == issue,"typed empty diagnostic preserves exact status distinction")}
        // ChatGPT desktop (com.openai.codex): the same guard with its bundled-UI page rule, held to the exact bound page.
        expect(OwnedComposerApp.chatGPT.bundle == "com.openai.codex" && OwnedComposerApp.claude.bundle == "com.anthropic.claudefordesktop"
               && OwnedComposerApp.chatGPT.windowTitle == "ChatGPT","ChatGPT and Claude bundles and titles")
        for bad in ["https://chatgpt.com/","http://localhost/","data:text/html,x","javascript:x","about:blank","blob:x","","no scheme"] {
            expect(!ChatGPTComposerMetadata.bundledPage(bad),"ChatGPT web, script and blank pages refuse")
        }
        expect(ChatGPTComposerMetadata.bundledPage("app://-/index.html") && ChatGPTComposerMetadata.bundledPage("file:///Applications/ChatGPT.app/x.html"),"ChatGPT bundled UI page")
        let rule=OwnedComposerApp.chatGPT.pageRule()
        expect(!rule(nil) && rule("app://-/index.html#/a") && rule("app://-/index.html#/a") && !rule("app://-/index.html#/b"),"ChatGPT page rule holds the first bundled page exactly")
        expect(OwnedComposerApp.chatGPT.pageRule()("app://-/index.html#/b"),"each binding gets a fresh page rule")
        let chat=State();chat.url="app://-/index.html#/new"
        var chatAccess=chat.access();chatAccess.page=OwnedComposerApp.chatGPT.pageRule()
        let chatBound=ClaudeOwnedComposer.bind(pid:23,window:0,editor:3,access:chatAccess)
        expect(chatBound != nil && chatBound?.matches() == true && chatBound?.initiallyEmpty() == true,"ChatGPT empty bundled-page composer binds")
        chat.url="app://-/index.html#/c/other";expect(chatBound?.matches() == false,"ChatGPT page changed after binding refuses")
        chat.url="app://-/index.html#/new";expect(chatBound?.matches() == true,"ChatGPT original page matches again")
        let chatWeb=State();chatWeb.url="https://chatgpt.com/";var webAccess=chatWeb.access();webAccess.page=OwnedComposerApp.chatGPT.pageRule()
        expect(ClaudeOwnedComposer.bind(pid:23,window:0,editor:3,access:webAccess) == nil && chatWeb.diagnostics.last?.refusal == .pageNotNew,"ChatGPT https page refuses")
        let chatFull=State();chatFull.url="app://-/index.html";chatFull.empty=false;var fullAccess=chatFull.access();fullAccess.page=OwnedComposerApp.chatGPT.pageRule()
        expect(ClaudeOwnedComposer.bind(pid:23,window:0,editor:3,access:fullAccess) == nil,"ChatGPT composer with text refuses")
        let claudeOnChat=State();claudeOnChat.url="app://-/index.html"
        expect(ClaudeOwnedComposer.bind(pid:23,window:0,editor:3,access:claudeOnChat.access()) == nil,"Claude's default rule never accepts a ChatGPT page")
        print("PASS \(checks) Claude and ChatGPT owned-composer controls; no AX or UI calls")
    }
}
#endif
