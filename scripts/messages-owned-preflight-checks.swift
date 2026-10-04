import Foundation
import CoreFoundation

@main struct MessagesPreflightChecks {
    static func main() {
        var count=0
        func check(_ value:Bool,_ label:String) {precondition(value,label);count+=1}
        let C=MessagesOwnedComposerContract.self
        func decoded(success:Bool,raw:CFTypeRef?,timely:Bool=true)->[Int]? {
            C.completeElements(success:success,raw:raw,timely:timely,decode:{$0 as? [Int]})
        }
        check(decoded(success:true,raw:[] as CFArray)==[],"only a typed successful empty array proves no children")
        check(decoded(success:true,raw:[2,3] as CFArray)==[2,3],"typed nonempty children preserved")
        for raw:CFTypeRef? in [nil,[] as CFArray,[2,3] as CFArray] {
            check(decoded(success:false,raw:raw)==nil,"unsupported/noValue/transport cannot fabricate empty children")
        }
        for raw:CFTypeRef in ["opaque" as CFString,NSNumber(value:0),["wrong-type"] as CFArray] {
            check(decoded(success:true,raw:raw)==nil,"wrong container or child element type refuses")
        }
        check(decoded(success:true,raw:[] as CFArray,timely:false)==nil,"late empty array refuses")
        check(decoded(success:true,raw:Array(0...256) as CFArray)==nil,"oversized array refuses without truncation")
        var postTrace:[String]=[],posted=0,focused=2
        try! C.postControl(ready:{postTrace.append("ready");return true},requiredScope:{postTrace.append("scope");return focused==2},post:{postTrace.append("post");posted+=1})
        check(postTrace==["ready","scope","post"] && posted==1,"shared actual posting helper scopes after readiness")
        postTrace=[];posted=0;focused=2
        do {try C.postControl(ready:{postTrace.append("ready");focused=3;return true},requiredScope:{postTrace.append("scope");return focused==2},post:{posted+=1})} catch {}
        check(posted==0 && postTrace==["ready","scope"],"same PID focus move during readiness refuses before any key")
        postTrace=[];posted=0
        do {try C.postControl(ready:{postTrace.append("ready");return false},requiredScope:{postTrace.append("scope");return true},post:{posted+=1})} catch {}
        check(posted==0 && postTrace==["ready"],"denied readiness never reaches scope or posts")
        posted=0
        do {try C.postControl(ready:{true},requiredScope:{throw MessagesFixtureError.deadline},post:{posted+=1})} catch {}
        check(posted==0,"scope read failure never posts")

        final class Tree {
            var time:UInt64=100,ready=true,windows:[Int]?=[1],role:[Int:String]=[1:"AXWindow",2:"AXTextField",3:"AXTextArea"]
            var sub:[Int:String]=[1:"",2:"",3:""],owners:[Int:Bool]=[1:true,2:true,3:true]
            var edit:[Int:Bool]=[1:false,2:true,3:true],zeros:[Int:Bool]=[2:true,3:true]
            var children:[Int:[Int]]=[1:[2,3],2:[],3:[]],reads=0,lateAt:Int?=nil,commands=0
            var access:MessagesExistingEditors<Int>.Access {
                .init(now:{self.reads+=1;return self.reads==self.lateAt ? 201:self.time},ready:{self.ready},windows:{self.windows},
                      owner:{self.owners[$0]},role:{self.role[$0]},subrole:{self.sub[$0]},editable:{self.edit[$0]},zero:{self.zeros[$0]},children:{self.children[$0]},equal:{$0==$1})
            }
            func attemptNew()->Bool {
                do {_=try MessagesExistingEditors<Int>.read(access,budget:.init(began:100,limit:100));commands+=1;return true} catch {return false}
            }
        }
        // The previous real seam treated unsupported children as [] for any
        // role. Simulate its exact omission of a hidden nonempty editor, then
        // drive the repaired actual decoder through the same traversal.
        let baselineOmission=Tree();baselineOmission.children[1]=[2,4]
        baselineOmission.role[4]="AXGroup";baselineOmission.sub[4]="";baselineOmission.owners[4]=true;baselineOmission.edit[4]=false
        baselineOmission.children[4]=[] // old real unsupported/noValue leaf:true result
        check(baselineOmission.attemptNew(),"preserved baseline seam can authorize New despite opaque subtree")
        for role in ["AXWindow","AXGroup","AXOpaqueContainer","AXTextArea"] {
            let t=Tree();t.children[1]=[2,4];t.role[4]=role;t.sub[4]="";t.owners[4]=true;t.edit[4]=false;t.zeros[4]=true
            t.children[4]=decoded(success:false,raw:nil)
            check(!t.attemptNew() && t.commands==0,"actual strict decoder refuses unavailable subtree for "+role)
        }
        let lateReady=Tree();var readyCalls=0
        let lateAccess=MessagesExistingEditors<Int>.Access(now:{lateReady.time},ready:{readyCalls+=1;if readyCalls==2 {lateReady.time=201};return true},
            windows:{lateReady.windows},owner:{lateReady.owners[$0]},role:{lateReady.role[$0]},subrole:{lateReady.sub[$0]},
            editable:{lateReady.edit[$0]},zero:{lateReady.zeros[$0]},children:{lateReady.children[$0]},equal:{$0==$1})
        check((try? MessagesExistingEditors<Int>.read(lateAccess,budget:.init(began:100,limit:100)))==nil,"slow final readiness cannot extend inventory aggregate deadline")
        let normalTree=Tree();check(normalTree.attemptNew() && normalTree.commands==1,"actual inventory helper admits complete empty tree")
        let errors:[(String,(Tree)->Void)]=[
            ("nonempty existing body",{$0.zeros[3]=false}),
            ("readonly prior draft",{$0.edit[3]=false;$0.zeros[3]=false}),
            ("nonempty existing To",{$0.zeros[2]=false}),
            ("opaque existing field count",{$0.zeros[2]=nil}),
            ("unknown editability",{$0.edit[2]=nil}),
            ("unknown role",{$0.role[2]=nil}),
            ("unknown subrole",{$0.sub[2]=nil}),
            ("secure old editor",{$0.sub[2]="AXSecureTextField"}),
            ("foreign owner",{$0.owners[2]=false}),
            ("missing owner",{$0.owners[2]=nil}),
            ("embedded web draft not known",{$0.role[2]="AXWebArea"}),
            ("editable unknown role",{$0.role[2]="AXGroup"}),
            ("cycle",{$0.children[2]=[1]}),
            ("unreadable children",{$0.children[2]=nil}),
            ("unreadable windows",{$0.windows=nil}),
            ("no windows",{$0.windows=[]}),
            ("duplicate window identity",{$0.windows=[1,1]}),
            ("deadline during traversal",{$0.lateAt=3}),
            ("backward clock",{$0.time=99}),
            ("missing permissions",{$0.ready=false}),
            ("unclassified editor inventory empty",{$0.children[1]=[]})
        ]
        for (label,configure) in errors {let t=Tree();configure(t);check(!t.attemptNew() && t.commands==0,"no New side effect when "+label)}
        let deep=Tree();deep.children[1]=[4]
        for i in 4...68 {deep.role[i]="AXGroup";deep.sub[i]="";deep.owners[i]=true;deep.edit[i]=false;deep.children[i]=[i+1]}
        deep.children[68]=[2]
        check(!deep.attemptNew() && deep.commands==0,"bounded depth cannot hide an old field")
        let large=Tree();large.children[1]=Array(4...260)
        check(!large.attemptNew() && large.commands==0,"bounded child limit does not truncate to empty")
        check(C.mayCreateNew(complete:true,editableZero:[true,true]),"known empty inventory permits New")
        for values:[Bool?] in [[],[nil],[false],[true,nil],[true,false]] {
            check(!C.mayCreateNew(complete:true,editableZero:values),"missing/nonempty/opaque prior editor prevents New")
        }
        check(!C.mayCreateNew(complete:false,editableZero:[true]),"truncated scan prevents New")
        for falseIndex in 0..<7 {
            var gates=[Bool](repeating:true,count:7);gates[falseIndex]=false
            check(!C.ownsNew(commandPosted:gates[0],allPriorEmpty:gates[1],newEditor:gates[2],exactPID:gates[3],exactWindow:gates[4],typedZero:gates[5],nativeProof:gates[6]),"New ownership requires every independent gate")
        }
        check(C.ownsNew(commandPosted:true,allPriorEmpty:true,newEditor:true,exactPID:true,exactWindow:true,typedZero:true,nativeProof:true),"positive New transition")
        for label in ["Message","iMessage","Text Message"," message "] {
            check(C.field(description:.text(label),help:.absent) == .body,"finite body candidate recognized after scope")
        }
        for label in ["To","To:","Recipient","Recipients"] {
            check(C.field(description:.text(label),help:.absent) == .recipient,"finite recipient candidate")
        }
        for label in ["Type a message to Existing Person","Search","Address","Message preview","", "unrecognized"] {
            check(C.field(description:.text(label),help:.absent) == .unknown,"unknown label cannot allow automated input")
        }
        check(C.field(description:.text("Message"),help:.text("To:")) == .unknown,"conflicting body/recipient metadata refused")
        check(C.field(description:.text("Message"),help:.text("unrecognized")) == .unknown,"positive description cannot hide unknown help")
        check(C.field(description:.unreadable,help:.text("Message")) == .unreadable,"failed description cannot hide behind help")
        check(C.field(description:.text("Message"),help:.unreadable) == .unreadable,"failed help refuses")
        check(C.field(description:.text(String(repeating:"x",count:129)),help:.absent) == .unreadable,"oversized labels refused")
        check(C.field(description:.absent,help:.absent) == .unknown,"absent label remains unknown")
        for field in [MessagesFieldClass.body,.unknown,.unreadable] {
            check(!C.mayTypeRecipient(ownedNew:true,field:field,zeroAtStart:true,retainedScope:true,postAllowed:true),"only positive To field may receive recipient setup")
        }
        for falseIndex in 0..<4 {
            var g=[Bool](repeating:true,count:4);g[falseIndex]=false
            check(!C.mayTypeRecipient(ownedNew:g[0],field:.recipient,zeroAtStart:g[1],retainedScope:g[2],postAllowed:g[3]),"recipient setup requires every current gate")
        }
        check(C.mayTypeRecipient(ownedNew:true,field:.recipient,zeroAtStart:true,retainedScope:true,postAllowed:true),"positive To scope permits fixed recipient only")
        for falseIndex in 0..<6 {
            var g=[Bool](repeating:true,count:6);g[falseIndex]=false
            check(!C.ownsBody(ownedNew:g[0],sameWindow:g[1],newEditor:g[2],differsRecipient:g[3],typedZero:g[4],field:.body,nativeProof:g[5]),"old body/foreign/reused/unproved field never owned body")
        }
        for field in [MessagesFieldClass.recipient,.unknown,.unreadable] {
            check(!C.ownsBody(ownedNew:true,sameWindow:true,newEditor:true,differsRecipient:true,typedZero:true,field:field,nativeProof:true),"only finite positive body may become ready")
        }
        check(C.ownsBody(ownedNew:true,sameWindow:true,newEditor:true,differsRecipient:true,typedZero:true,field:.body,nativeProof:true),"positive new body readiness distinct from capture")
        check(C.typedZero(success:true,raw:NSNumber(value:0),timely:true) == true,"integer zero positively empty")
        check(C.typedZero(success:true,raw:NSNumber(value:1),timely:true) == false,"positive count never empty")
        for raw:CFTypeRef? in [nil,NSNumber(value:true),"zero" as CFString,NSNumber(value:Double(0)),NSNumber(value:-1),NSNumber(value:UInt64.max)] {
            check(C.typedZero(success:true,raw:raw,timely:true) == nil,"absent/wrong type/float/negative/overflow counts refuse")
        }
        check(C.typedZero(success:false,raw:NSNumber(value:0),timely:true)==nil,"failed read cannot supply zero")
        check(C.typedZero(success:true,raw:NSNumber(value:0),timely:false)==nil,"late zero refuses")
        for code:UInt16 in [36,76,51,117,0,45] {
            check(!C.allowedControl(code:code,command:false),"no Return/delete/body arbitrary key")
        }
        for code:UInt16 in [18,19,23,29,48] {
            check(C.allowedControl(code:code,command:false),"closed digit/Tab set")
            check(!C.allowedControl(code:code,command:true),"command cannot modify recipient digits/Tab")
        }
        check(C.allowedControl(code:45,command:true),"only fixed Command-N opens New")
        for code:UInt16 in [36,76,0,13,12] {check(!C.allowedControl(code:code,command:true),"no alternate command/send/quit chord")}
        let good:[String:String]=["--fixture":C.fixture,"--mode":"preflight","--input":"none","--expected-pid":"7","--work-root":"/private/tmp/daydream-capture-fixture-4507F0EF-DBD8-409D-9241-B68FDD44A608"]
        check((try? C.Configuration.parse(good)) != nil,"closed preflight configuration")
        for (key,value) in [("--mode","capture"),("--input","fixed-marker"),("--fixture","textedit"),("--expected-pid","0"),("--work-root","/tmp/existing"),("--body","arbitrary"),("--recipient","someone") ] {
            var bad=good;bad[key]=value;check((try? C.Configuration.parse(bad)) == nil,"cannot widen fixture/input/root/recipient")
        }
        for key in good.keys {var bad=good;bad[key]=nil;check((try? C.Configuration.parse(bad))==nil,"required options cannot disappear")}
        let began:UInt64=100,b=MessagesOwnedComposerContract.Budget(began:began,limit:25)
        check(b.accepts(100) && b.accepts(125) && !b.accepts(99) && !b.accepts(126),"deadline and backwards clock refuse")
        print("\(count) synthetic Messages preflight controls passed. No app/AX/post/store/history access.")
    }
}
