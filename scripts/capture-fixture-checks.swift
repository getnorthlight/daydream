import Foundation
import ApplicationServices
import Darwin
import PrivacyPolicy
import MemoryCore

@main enum FixtureChecks {
    @MainActor static func main() throws {
        var checks=0
        func expect(_ b:Bool,_ name:String) { checks+=1; if !b { fatalError(name) } }
        func rejects(_ f:() throws ->Void)->Bool { do { try f(); return false } catch { return true } }
        typealias R=CaptureFixtureLaunch.Route
        let flag="--capture-fixture-trial"
        expect(CaptureFixtureLaunch.route(arguments:["app"],ownerCompiled:true)==R.application,"ordinary owner launch")
        expect(CaptureFixtureLaunch.route(arguments:["app","--recording-trial"],ownerCompiled:true)==R.application,"recording trial unchanged")
        expect(CaptureFixtureLaunch.route(arguments:["app",flag],ownerCompiled:true)==R.fixture,"fixture selected before model")
        expect(CaptureFixtureLaunch.route(arguments:["app",flag],ownerCompiled:false)==R.refused,"nonowner cannot fallback")
        expect(CaptureFixtureLaunch.route(arguments:["app","x",flag],ownerCompiled:true)==R.refused,"misordered fixture cannot fallback")
        expect(CaptureFixtureLaunch.route(arguments:["app",flag,flag],ownerCompiled:true)==R.refused,"duplicate cannot fallback")
        expect(CaptureFixtureLaunch.route(arguments:[flag],ownerCompiled:true)==R.refused,"missing argv0 cannot fallback")
        expect(CaptureFixtureLaunch.route(arguments:["app","--signed-writer-acceptance"],ownerCompiled:false)==R.application,"existing writer launch unchanged")
        expect(CaptureFixtureLaunch.browserFixture(arguments:["app",flag,"--fixture","chrome"]),"exact browser fixture route")
        expect(!CaptureFixtureLaunch.browserFixture(arguments:["app",flag,"--fixture","textedit"]),"native fixture stays native")
        expect(!CaptureFixtureLaunch.browserFixture(arguments:["app",flag,"--fixture"]),"missing fixture value refuses browser")
        expect(!CaptureFixtureLaunch.browserFixture(arguments:["app",flag,"--fixture","chrome","--fixture","textedit"]),"duplicate fixture cannot choose browser")
        expect(!CaptureFixtureLaunch.browserFixture(arguments:["app",flag]),"absent fixture stays native")
        let unknown=CaptureFixtureMetadata.subrole(status:.cannotComplete,raw:nil,withinDeadline:true)
        expect(unknown==nil,"transport failure rejected")
        expect(!CaptureFixtureMetadata.nonSecure(role:"AXTextArea",subrole:unknown),"old nil secure predicate regression")
        expect(CaptureFixtureMetadata.subrole(status:.attributeUnsupported,raw:nil,withinDeadline:true)=="","definitive absent permitted")
        expect(CaptureFixtureMetadata.subrole(status:.noValue,raw:nil,withinDeadline:false)==nil,"late absence rejected")
        expect(CaptureFixtureMetadata.subrole(status:.success,raw:kCFBooleanTrue,withinDeadline:true)==nil,"wrong type rejected")
        expect(!CaptureFixtureMetadata.nonSecure(role:"AXTextField",subrole:"AXSecureTextField"),"secure rejected")
        expect(CaptureFixtureTrial.marker.count==35,"fixed marker bounded")
        expect(CaptureFixtureTrial.marker.allSatisfy { CaptureFixtureTrial.fixtureKey($0) != nil },"all fixed keys supported")
        expect(CaptureFixtureTrial.fixtureKey("\n")==nil,"Return not supported")
        expect(CaptureFixtureTrial.fixtureKey("\r")==nil,"alternate Return not supported")
        expect(CaptureFixtureTrial.fixtureKey("@")==nil,"arbitrary characters not supported")
        let textRoot=try root(marker:CaptureFixtureKind.textEdit.declaration)
        let name=CaptureFixtureKind.textEdit.documentName(textRoot)
        let doc=textRoot.appendingPathComponent(name)
        try Data().write(to:doc);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:doc.path)
        expect(try CaptureFixtureTrial.checkedRoot(textRoot.path,fixture:.textEdit)==textRoot,"new empty TextEdit file allowed")
        expect(name.contains(String(textRoot.lastPathComponent.dropFirst("daydream-capture-fixture-".count))),"nonce in exact document name")
        expect(rejects { _=try CaptureFixtureTrial.checkedRoot(textRoot.path,fixture:.nativeClaude) },"wrong fixture declaration refused")
        let absentDoc=try root(marker:CaptureFixtureKind.textEdit.declaration)
        expect(rejects { _=try CaptureFixtureTrial.checkedRoot(absentDoc.path,fixture:.textEdit) },"missing TextEdit file refused")
        try Data("fiction".utf8).write(to:doc)
        expect(rejects { _=try CaptureFixtureTrial.checkedRoot(textRoot.path,fixture:.textEdit) },"nonempty draft refused")
        let publicRoot=try root(marker:CaptureFixtureKind.textEdit.declaration)
        let publicDoc=publicRoot.appendingPathComponent(CaptureFixtureKind.textEdit.documentName(publicRoot))
        try Data().write(to:publicDoc);try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:publicDoc.path)
        expect(rejects { _=try CaptureFixtureTrial.checkedRoot(publicRoot.path,fixture:.textEdit) },"nonprivate document refused")
        let symRoot=try root(marker:CaptureFixtureKind.textEdit.declaration)
        try FileManager.default.createSymbolicLink(at:symRoot.appendingPathComponent(CaptureFixtureKind.textEdit.documentName(symRoot)),withDestinationURL:publicDoc)
        expect(rejects { _=try CaptureFixtureTrial.checkedRoot(symRoot.path,fixture:.textEdit) },"symlink document refused")
        var proof=FocusProof();proof.bundle="com.apple.TextEdit";proof.surface = .native
        expect(CaptureFixtureKind.textEdit.accepts(proof),"TextEdit ordinary production surface")
        expect(!CaptureFixtureKind.nativeClaude.accepts(proof),"TextEdit proof cannot authorize Claude")
        proof.bundle="com.anthropic.claudefordesktop";proof.surface = .embeddedWeb
        expect(CaptureFixtureKind.nativeClaude.accepts(proof),"Claude existing vendor surface")
        expect(!CaptureFixtureKind.textEdit.accepts(proof),"Claude proof cannot authorize TextEdit")
        proof.surface = .native
        expect(!CaptureFixtureKind.nativeClaude.accepts(proof),"Claude plain native proof refused")
        expect(!CaptureFixtureKind.nativeChatGPT.accepts(proof),"ChatGPT plain native proof refused")
        proof.bundle="com.openai.codex";proof.surface = .embeddedWeb
        expect(CaptureFixtureKind.nativeChatGPT.accepts(proof) && !CaptureFixtureKind.nativeClaude.accepts(proof),"ChatGPT embedded web surface, never Claude's")
        proof.bundle="com.anthropic.claudefordesktop"
        expect(!CaptureFixtureKind.nativeChatGPT.accepts(proof),"Claude proof cannot authorize ChatGPT")
        expect(CaptureFixtureKind(rawValue:"native-chatgpt") == .nativeChatGPT && CaptureFixtureKind.nativeChatGPT.bundle == "com.openai.codex"
               && CaptureFixtureKind.nativeChatGPT.declaration == "native-chatgpt-empty-unsent-v1\n" && CaptureFixtureKind.nativeChatGPT.ownedComposer == .chatGPT
               && CaptureFixtureKind.nativeClaude.ownedComposer == .claude && CaptureFixtureKind.textEdit.ownedComposer == nil,"ChatGPT fixture next to Claude")
        let chatRoot=try root(marker:CaptureFixtureKind.nativeChatGPT.declaration)
        expect(try CaptureFixtureTrial.checkedRoot(chatRoot.path,fixture:.nativeChatGPT)==chatRoot,"ChatGPT declared owned root allowed")
        expect(rejects { _=try CaptureFixtureTrial.checkedRoot(chatRoot.path,fixture:.nativeClaude) },"ChatGPT declaration cannot authorize Claude")
        let early=Evidence(id:"z-fragment",at:"2026-09-30T12:00:00Z",kind:"keyboard.text_input",app:"fixture",text:"qa final ")
        let late=Evidence(id:"a-fragment",at:"2026-09-30T12:00:01Z",kind:"keyboard.text_input",app:"fixture",text:"source")
        expect(CaptureFixtureTrial.orderedRows([late,early]).map(\.id)==[early.id,late.id],"chronology overrides UUID order")
        expect(CaptureFixtureTrial.orderedRows([late,early]).map(\.text).joined()=="qa final source","split fragments retain exact order")
        var tie=late;tie.at=early.at
        expect(CaptureFixtureTrial.orderedRows([early,tie]).map(\.id)==[tie.id,early.id],"equal times deterministic ID tie")
        let originalHome=ProcessInfo.processInfo.environment["MAC_MEM_HOME"]
        func root(_ suffix:String="",mode:Int=0o700,marker:String="native-claude-empty-unsent-v1\n") throws -> URL {
            let u=URL(fileURLWithPath:"/private/tmp/daydream-capture-fixture-checks-"+UUID().uuidString+suffix,isDirectory:true)
            try FileManager.default.createDirectory(at:u,withIntermediateDirectories:false,attributes:[.posixPermissions:mode])
            let m=u.appendingPathComponent("OWNED-FIXTURE")
            try Data(marker.utf8).write(to:m);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:m.path)
            return u
        }
        let good=try root()
        expect(try CaptureFixtureTrial.checkedRoot(good.path)==good,"owned empty fixture allowed")
        let wrong=try root(marker:"not-owned\n")
        expect(rejects { _=try CaptureFixtureTrial.checkedRoot(wrong.path) },"wrong owner declaration refused")
        let permissive=try root(mode:0o755)
        expect(rejects { _=try CaptureFixtureTrial.checkedRoot(permissive.path) },"nonprivate root refused")
        let replay=try root();try Data().write(to:replay.appendingPathComponent("capture-fixture-receipt.jsonl"))
        expect(rejects { _=try CaptureFixtureTrial.checkedRoot(replay.path) },"prior attempt no replay")
        let extra=try root();try Data().write(to:extra.appendingPathComponent("history.sqlite"))
        expect(rejects { _=try CaptureFixtureTrial.checkedRoot(extra.path) },"existing history refused")
        let linked=try root();let alias=URL(fileURLWithPath:"/private/tmp/daydream-capture-fixture-checks-"+UUID().uuidString)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:linked)
        expect(rejects { _=try CaptureFixtureTrial.checkedRoot(alias.path) },"symlink root refused")
        let hard=try root();let h=hard.appendingPathComponent("OWNED-FIXTURE")
        try FileManager.default.linkItem(at:h,to:hard.appendingPathComponent("another-name"))
        expect(rejects { _=try CaptureFixtureTrial.checkedRoot(hard.path) },"hardlinked marker refused")
        expect(rejects { _=try CaptureFixtureTrial.checkedRoot("/private/tmp/nonfixture") },"wrong prefix refused")
        expect(rejects { _=try CaptureFixtureTrial.checkedRoot("/private/tmp/daydream-capture-fixture-absent-"+UUID().uuidString) },"absent root refused")
        try CaptureFixtureTrial.reserveOutput(good)
        expect(rejects { try CaptureFixtureTrial.reserveOutput(good) },"exclusive output refuses repeat")
        expect(ProcessInfo.processInfo.environment["MAC_MEM_HOME"]==originalHome,"default home untouched")
        print("fixture_contract_checks=\(checks) failures=0 no_capture=true no_input=true no_default_store=true")
    }
}
