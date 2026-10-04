#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
import Foundation
import CoreFoundation

enum MessagesFixtureError: String, Error {
    case arguments, identity, path, permission, deadline, metadata, existingDraft,
         inventoryIncomplete, foreignScope, newTransition, typedZero, fieldUnknown,
         fieldRecipient, fieldBody, nativeProof, changed
}
enum MessagesIdentityIssue:String {case applicationUnavailable,bundleUnavailable,bundleMismatch,launchDateUnavailable}
struct MessagesIdentityDiagnostic {
    let issue:MessagesIdentityIssue,pidPositive:Bool,applicationAvailable:Bool,bundleRead:Bool,bundleAvailable:Bool,bundleMatches:Bool,launchDateRead:Bool
}
/// Exact original constructor metadata/admission order; failed reads stop.
/// The observer receives only finite failure/evaluation facts, never raw data.
enum MessagesProcessIdentity<Application,Birth> {
    struct Access {
        let application:(Int32)->Application?,bundle:(Application)->String?,launch:(Application)->Birth?
    }
    static func read(pid:Int32,expectedBundle:String,access:Access,observe:(MessagesIdentityDiagnostic)->Void)throws->(Application,Birth) {
        guard let app=access.application(pid) else {
            observe(.init(issue:.applicationUnavailable,pidPositive:pid>0,applicationAvailable:false,bundleRead:false,bundleAvailable:false,bundleMatches:false,launchDateRead:false));throw MessagesFixtureError.identity
        }
        guard let bundle=access.bundle(app) else {
            observe(.init(issue:.bundleUnavailable,pidPositive:pid>0,applicationAvailable:true,bundleRead:true,bundleAvailable:false,bundleMatches:false,launchDateRead:false));throw MessagesFixtureError.identity
        }
        guard bundle==expectedBundle else {
            observe(.init(issue:.bundleMismatch,pidPositive:pid>0,applicationAvailable:true,bundleRead:true,bundleAvailable:true,bundleMatches:false,launchDateRead:false));throw MessagesFixtureError.identity
        }
        guard let birth=access.launch(app) else {
            observe(.init(issue:.launchDateUnavailable,pidPositive:pid>0,applicationAvailable:true,bundleRead:true,bundleAvailable:true,bundleMatches:true,launchDateRead:true));throw MessagesFixtureError.identity
        }
        return(app,birth)
    }
}
/// QA target identity uses the existing production kernel start API, never
/// requires Launch Services' optional Date. Hold the exact public Double
/// representation only while its ULP can distinguish adjacent microseconds.
struct MessagesKernelIdentity:Equatable {
    let pid:Int32, start:Double
    static func precise(_ value:Double?)->Double? {
        guard let value,value.isFinite,value>0,value.ulp<0.000001 else {return nil}
        return value
    }
    func matches(pid:Int32,start:Double?)->Bool {
        pid==self.pid && Self.precise(start)==self.start
    }
}
enum MessagesKernelIdentityIssue:String {
    case pidInvalid,kernelBirthUnavailable,kernelBirthUnusable,heldIdentityChanged,
         kernelBirthChanged,applicationUnavailable,applicationPIDMismatch,terminated,
         bundleUnavailable,bundleMismatch,bundlePathUnavailable,bundlePathMismatch,
         executablePathUnavailable,executablePathMismatch,signatureUnverified,deadline
}
enum MessagesKernelProcessIdentity<Application> {
    struct Access {
        let now:()->UInt64,birth:(Int32)->Double?,application:(Int32)->Application?,
            currentPID:(Application)->Int32,terminated:(Application)->Bool,
            bundle:(Application)->String?,bundlePath:(Application)->String?,
            executablePath:(Application)->String?,signature:(Int32)->Bool
    }
    static func read(pid:Int32,held:MessagesKernelIdentity?=nil,deadline:UInt64,
                     access:Access,observe:(MessagesKernelIdentityIssue)->Void={_ in})throws->MessagesKernelIdentity {
        func reject(_ issue:MessagesKernelIdentityIssue)throws->Never {observe(issue);throw MessagesFixtureError.identity}
        guard pid>0 else {try reject(.pidInvalid)}
        let began=access.now()
        func timely()throws {let n=access.now();guard n>=began,n<deadline else {try reject(.deadline)}}
        try timely()
        guard let raw=access.birth(pid) else {try reject(.kernelBirthUnavailable)}
        guard let start=MessagesKernelIdentity.precise(raw) else {try reject(.kernelBirthUnusable)}
        let identity=MessagesKernelIdentity(pid:pid,start:start)
        guard held==nil || held==identity else {try reject(.heldIdentityChanged)}
        try timely()
        guard let app=access.application(pid) else {try reject(.applicationUnavailable)}
        try timely()
        guard access.currentPID(app)==pid else {try reject(.applicationPIDMismatch)}
        guard !access.terminated(app) else {try reject(.terminated)}
        try timely()
        guard let bundle=access.bundle(app) else {try reject(.bundleUnavailable)}
        guard bundle=="com.apple.MobileSMS" else {try reject(.bundleMismatch)}
        try timely()
        guard let bundlePath=access.bundlePath(app) else {try reject(.bundlePathUnavailable)}
        guard bundlePath=="/System/Applications/Messages.app" else {try reject(.bundlePathMismatch)}
        try timely()
        guard let path=access.executablePath(app) else {try reject(.executablePathUnavailable)}
        guard path=="/System/Applications/Messages.app/Contents/MacOS/Messages" else {try reject(.executablePathMismatch)}
        try timely()
        guard access.signature(pid) else {try reject(.signatureUnverified)}
        try timely()
        guard identity.matches(pid:pid,start:access.birth(pid)) else {try reject(.kernelBirthChanged)}
        try timely()
        return identity
    }
}
/// Include the final fresh kernel read in the retained scope's admission cap.
enum MessagesKernelControlScope {
    static func read(now:()->UInt64,scope:()throws->Bool,birth:()->Bool,secure:()->Bool) rethrows ->Bool {
        let budget=MessagesOwnedComposerContract.Budget(began:now(),limit:100_000_000)
        guard try scope(),birth(),!secure() else {return false}
        return budget.accepts(now())
    }
}
/// QA-only finite metadata classifier. Unknown strings never leave this function.
enum MessagesFieldClass: String { case body, recipient, unknown, unreadable }
enum MessagesLabelRead: Equatable { case text(String), absent, unreadable }
/// Same traversal in console controls and the real AX adapter. No label/value
/// seam exists here: every known editor must positively report integer zero.
enum MessagesExistingEditors<Node> {
    struct Snapshot {let windows:[Node], editors:[Node]}
    struct Access {
        let now:()->UInt64,ready:()->Bool,windows:()->[Node]?
        let owner:(Node)->Bool?,role:(Node)->String?,subrole:(Node)->String?
        let editable:(Node)->Bool?,zero:(Node)->Bool?,children:(Node)->[Node]?
        let equal:(Node,Node)->Bool
    }
    static func read(_ a:Access,budget:MessagesOwnedComposerContract.Budget)throws->Snapshot {
        guard a.ready() else {throw MessagesFixtureError.permission}
        guard budget.accepts(a.now()),let windows=a.windows(),!windows.isEmpty,windows.count<=4 else {throw MessagesFixtureError.inventoryIncomplete}
        var editors:[Node]=[],visited:[Node]=[],queue=windows.map{($0,0)}
        while !queue.isEmpty {
            guard budget.accepts(a.now()) else {throw MessagesFixtureError.deadline}
            guard visited.count<256 else {throw MessagesFixtureError.inventoryIncomplete}
            let(node,depth)=queue.removeFirst()
            guard depth<64,!visited.contains(where:{a.equal($0,node)}) else {throw MessagesFixtureError.inventoryIncomplete}
            visited.append(node)
            guard a.owner(node)==true else {throw MessagesFixtureError.foreignScope}
            guard let role=a.role(node),let sub=a.subrole(node),role.utf8.count<=128,sub.utf8.count<=128 else {throw MessagesFixtureError.metadata}
            guard !role.lowercased().contains("secure"),!sub.lowercased().contains("secure"),role != "AXWebArea" else {throw MessagesFixtureError.foreignScope}
            guard let editable=a.editable(node) else {throw MessagesFixtureError.metadata}
            let known=["AXTextField","AXTextArea","AXSearchField"].contains(role)
            guard !editable || known else {throw MessagesFixtureError.inventoryIncomplete}
            if known {
                guard let zero=a.zero(node) else {throw MessagesFixtureError.typedZero}
                guard zero else {throw MessagesFixtureError.existingDraft};editors.append(node)
            }
            guard let children=a.children(node),children.count<=256 else {throw MessagesFixtureError.inventoryIncomplete}
            queue += children.map{($0,depth+1)}
        }
        guard budget.accepts(a.now()) else {throw MessagesFixtureError.deadline}
        guard MessagesOwnedComposerContract.mayCreateNew(complete:true,editableZero:editors.map{_ in true}),a.ready() else {throw MessagesFixtureError.inventoryIncomplete}
        guard budget.accepts(a.now()) else {throw MessagesFixtureError.deadline}
        return Snapshot(windows:windows,editors:editors)
    }
}
enum MessagesOwnedComposerContract {
    static let fixture = "native-messages-owned-new"
    static let declaration = "messages-owned-new-preflight-v1\n"
    static let recipient = "2025550100" // reserved fictional NANP 555-0100; never sent
    static func typedZero(success:Bool, raw:CFTypeRef?, timely:Bool) -> Bool? {
        guard success,timely,let raw,CFGetTypeID(raw)==CFNumberGetTypeID(),!CFNumberIsFloatType((raw as! CFNumber)) else {return nil}
        var count:Int64=0
        guard CFNumberGetValue((raw as! CFNumber),.sInt64Type,&count),count>=0 else {return nil}
        return count==0
    }
    /// No unsupported/noValue/opaque child result proves absence, even for a
    /// conventional leaf role. The real adapter and controls use this decoder.
    static func completeElements<Node>(success:Bool, raw:CFTypeRef?, timely:Bool,
                                       decode:(CFTypeRef)->[Node]?) -> [Node]? {
        guard success,timely,let raw,CFGetTypeID(raw)==CFArrayGetTypeID(),
              let rows=decode(raw),rows.count<=256 else {return nil}
        return rows
    }
    /// Readiness can move focus or take time. Its result must precede the final
    /// required scope, and neither failed/throwing guard may invoke the post.
    static func postControl(ready:()->Bool,requiredScope:()throws->Bool,post:()->Void)throws {
        guard ready() else {throw MessagesFixtureError.permission}
        guard try requiredScope() else {throw MessagesFixtureError.changed}
        post()
    }
    static func allowedControl(code:UInt16, command:Bool) -> Bool {
        command ? code == 45 : [18,19,23,29,48].contains(code)
    }
    static func field(description: MessagesLabelRead, help: MessagesLabelRead) -> MessagesFieldClass {
        var positive: Set<String> = []
        for read in [description, help] {
            switch read {
            case .unreadable: return .unreadable
            case .absent: continue
            case .text(let raw):
                guard raw.utf8.count <= 128 else { return .unreadable }
                let text=raw.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
                if text.isEmpty {continue}
                switch text {
                case "message", "imessage", "text message": positive.insert("body")
                case "to", "to:", "recipient", "recipients": positive.insert("recipient")
                default: return .unknown
                }
            }
        }
        guard positive.count == 1 else {return .unknown}
        return positive.contains("body") ? .body:.recipient
    }
    struct Configuration {
        let root:String, pid:Int32, recipientSetup:Bool
        static func parse(_ o:[String:String]) throws -> Self {
            guard Set(o.keys).isSubset(of:["--fixture","--work-root","--expected-pid","--mode","--input"]),
                  o["--fixture"] == fixture,o["--mode"] == "preflight",
                  let pid=o["--expected-pid"].flatMap(Int32.init),pid>0,
                  let root=o["--work-root"],root.hasPrefix("/private/tmp/daydream-capture-fixture-"),
                  UUID(uuidString:String(root.dropFirst("/private/tmp/daydream-capture-fixture-".count))) != nil,
                  let input=o["--input"],["none","recipient-only"].contains(input) else {throw MessagesFixtureError.arguments}
            return Self(root:root,pid:pid,recipientSetup:input == "recipient-only")
        }
    }
    struct Budget {
        let began:UInt64, limit:UInt64
        func accepts(_ time:UInt64)->Bool {time>=began && time-began<=limit}
    }
    /// New cannot replace an opaque/nonempty prior editor. Only complete,
    /// positively empty inventories authorize the initial New control chord.
    static func mayCreateNew(complete:Bool, editableZero:[Bool?]) -> Bool {
        complete && !editableZero.isEmpty && editableZero.allSatisfy {$0 == true}
    }
    /// A command alone is not ownership: the fresh focused editor must be
    /// absent from the whole pre-command inventory, empty, owned and proved.
    static func ownsNew(commandPosted:Bool, allPriorEmpty:Bool, newEditor:Bool,
                        exactPID:Bool, exactWindow:Bool, typedZero:Bool, nativeProof:Bool) -> Bool {
        commandPosted && allPriorEmpty && newEditor && exactPID && exactWindow && typedZero && nativeProof
    }
    static func mayTypeRecipient(ownedNew:Bool, field:MessagesFieldClass, zeroAtStart:Bool,
                                retainedScope:Bool, postAllowed:Bool) -> Bool {
        ownedNew && field == .recipient && zeroAtStart && retainedScope && postAllowed
    }
    static func ownsBody(ownedNew:Bool,sameWindow:Bool,newEditor:Bool,differsRecipient:Bool,
                         typedZero:Bool,field:MessagesFieldClass,nativeProof:Bool) -> Bool {
        ownedNew && sameWindow && newEditor && differsRecipient && typedZero && field == .body && nativeProof
    }
}
#endif
