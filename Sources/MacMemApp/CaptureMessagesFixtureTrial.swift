#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
import AppKit
import ApplicationServices
import Carbon
import Darwin
import Foundation
import MemoryCore
import PrivacyPolicy
import Security

/// Private actual-app preflight only. New and optional fictional To setup are
/// closed control operations; no body marker, Return, store, capture or model.
@MainActor enum CaptureMessagesFixtureTrial {
    static let bundle="com.apple.MobileSMS"
    typealias Inventory=MessagesExistingEditors<AXUIElement>.Snapshot
    private static var newPosted=false, recipientPosted=0, tabPosted=false
    static func emit(_ value:[String:Any]) {
        var value=value;value["newCommandPosted"]=newPosted;value["recipientKeyPairsPosted"]=recipientPosted;value["recipientTabPosted"]=tabPosted
        value["bodyInputPosted"]=false;value["capturePass"]=false;value["storeOpened"]=false;value["bodyCaptureImplemented"]=false
        CaptureFixtureTrial.emit(value)
    }
    @MainActor final class AX {
        let pid:pid_t, held:MessagesKernelIdentity, deadline:UInt64
        static var identityAccess:MessagesKernelProcessIdentity<NSRunningApplication>.Access {
            .init(now:{DispatchTime.now().uptimeNanoseconds},birth:{ProcessStart.kernelSeconds(pid:$0)},
                  application:{NSRunningApplication(processIdentifier:$0)},currentPID:{$0.processIdentifier},terminated:{$0.isTerminated},
                  bundle:{$0.bundleIdentifier},bundlePath:{$0.bundleURL?.path},executablePath:{$0.executableURL?.path},signature:{vendorValid(pid:$0)})
        }
        static func vendorValid(pid:pid_t)->Bool {
            guard let row=TypingCategories.app(bundle),let text=TypingCategories.signingRequirement(row) else {return false}
            var code:SecCode?,requirement:SecRequirement?
            guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:pid] as CFDictionary,[],&code)==errSecSuccess,
                  let code,SecRequirementCreateWithString(text as CFString,[],&requirement)==errSecSuccess,
                  let requirement else {return false}
            return SecCodeCheckValidity(code,[],requirement)==errSecSuccess
        }
        init(pid:pid_t) throws {
            let deadline=DispatchTime.now().uptimeNanoseconds+8_000_000_000
            let identity=try MessagesKernelProcessIdentity<NSRunningApplication>.read(pid:pid,deadline:deadline,access:Self.identityAccess,observe:{issue in
                CaptureMessagesFixtureTrial.emit(["phase":"messages-kernel-identity-diagnostic","fixture":MessagesOwnedComposerContract.fixture,
                    "identityIssue":issue.rawValue,"identityAuthority":"production-kernel-start","AXFieldRead":false])
            })
            self.pid=pid;held=identity;self.deadline=deadline
        }
        func sameBirth()->Bool {
            guard DispatchTime.now().uptimeNanoseconds<deadline else {return false}
            let same=held.matches(pid:pid,start:ProcessStart.kernelSeconds(pid:pid))
            return same && DispatchTime.now().uptimeNanoseconds<deadline
        }
        func identityReady()->Bool {
            (try? MessagesKernelProcessIdentity<NSRunningApplication>.read(pid:pid,held:held,deadline:deadline,access:Self.identityAccess))==held
        }
        func ready(post:Bool=false)->Bool {
            guard DispatchTime.now().uptimeNanoseconds<deadline,Thread.isMainThread,
                  AXIsProcessTrusted(),CGPreflightListenEventAccess(),!IsSecureEventInputEnabled(),
                  !post || (CGPreflightPostEventAccess() && Self.fixedUSKeyboard()),AccessibilityReader.keyboardInputIsDirect(),
                  AccessibilityReader.systemFocusedApplication()==pid,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier==pid else {return false}
            return identityReady() && sameBirth() && DispatchTime.now().uptimeNanoseconds<deadline
        }
        func read(_ node:AXUIElement,_ name:String,_ budget:MessagesOwnedComposerContract.Budget)throws->(AXError,CFTypeRef?) {
            let began=DispatchTime.now().uptimeNanoseconds
            guard sameBirth() else {throw MessagesFixtureError.identity}
            guard budget.accepts(began),began<deadline,AXUIElementSetMessagingTimeout(node,0.025) == .success else {throw MessagesFixtureError.deadline}
            var value:CFTypeRef?;let status=AXUIElementCopyAttributeValue(node,name as CFString,&value)
            let same=sameBirth(),ended=DispatchTime.now().uptimeNanoseconds
            guard same else {throw MessagesFixtureError.identity}
            guard ended>=began,ended-began<=25_000_000,budget.accepts(ended),ended<deadline else {throw MessagesFixtureError.deadline}
            return(status,value)
        }
        func owner(_ node:AXUIElement,_ budget:MessagesOwnedComposerContract.Budget)throws {
            let began=DispatchTime.now().uptimeNanoseconds;var actual:pid_t=0
            guard sameBirth() else {throw MessagesFixtureError.identity}
            guard budget.accepts(began),AXUIElementSetMessagingTimeout(node,0.025) == .success,
                  AXUIElementGetPid(node,&actual) == .success,actual==pid else {throw MessagesFixtureError.foreignScope}
            guard sameBirth() else {throw MessagesFixtureError.identity}
            guard budget.accepts(DispatchTime.now().uptimeNanoseconds),DispatchTime.now().uptimeNanoseconds-began<=25_000_000 else {throw MessagesFixtureError.foreignScope}
        }
        func string(_ node:AXUIElement,_ name:String,_ b:MessagesOwnedComposerContract.Budget)throws->String {
            let(s,v)=try read(node,name,b);guard s == .success,let v,CFGetTypeID(v)==CFStringGetTypeID(),let text=v as? String,text.utf8.count<=128 else {throw MessagesFixtureError.metadata};return text
        }
        func subrole(_ node:AXUIElement,_ b:MessagesOwnedComposerContract.Budget)throws->String {
            let(s,v)=try read(node,kAXSubroleAttribute,b)
            if s == .attributeUnsupported || s == .noValue {return ""}
            guard s == .success,let v,CFGetTypeID(v)==CFStringGetTypeID(),let text=v as? String,text.utf8.count<=128 else {throw MessagesFixtureError.metadata};return text
        }
        func elements(_ node:AXUIElement,_ name:String,_ b:MessagesOwnedComposerContract.Budget)throws->[AXUIElement] {
            let(s,v)=try read(node,name,b)
            guard let rows:[AXUIElement]=MessagesOwnedComposerContract.completeElements(success:s == .success,raw:v,timely:true,decode:{raw in
                guard let rows=raw as? [AXUIElement],rows.allSatisfy({CFGetTypeID($0)==AXUIElementGetTypeID()}) else {return nil}
                return rows
            }) else {throw MessagesFixtureError.inventoryIncomplete};return rows
        }
        func element(_ node:AXUIElement,_ name:String,_ b:MessagesOwnedComposerContract.Budget)throws->AXUIElement {
            let(s,v)=try read(node,name,b);guard s == .success,let v,CFGetTypeID(v)==AXUIElementGetTypeID() else {throw MessagesFixtureError.metadata};return v as! AXUIElement
        }
        func zero(_ field:AXUIElement,_ b:MessagesOwnedComposerContract.Budget)throws->Bool {
            let(s,v)=try read(field,kAXNumberOfCharactersAttribute,b)
            guard let zero=MessagesOwnedComposerContract.typedZero(success:s == .success,raw:v,timely:true) else {throw MessagesFixtureError.typedZero}
            return zero
        }
        func editable(_ node:AXUIElement,_ b:MessagesOwnedComposerContract.Budget)throws->Bool {
            let began=DispatchTime.now().uptimeNanoseconds;var flag=DarwinBoolean(false)
            guard sameBirth() else {throw MessagesFixtureError.identity}
            guard b.accepts(began),AXUIElementSetMessagingTimeout(node,0.025) == .success else {throw MessagesFixtureError.deadline}
            let status=AXUIElementIsAttributeSettable(node,kAXValueAttribute as CFString,&flag)
            let same=sameBirth(),ended=DispatchTime.now().uptimeNanoseconds
            guard same else {throw MessagesFixtureError.identity}
            guard ended>=began,ended-began<=25_000_000,b.accepts(ended) else {throw MessagesFixtureError.deadline}
            if status == .attributeUnsupported {return false}
            guard status == .success else {throw MessagesFixtureError.metadata};return flag.boolValue
        }
        func enabled(_ field:AXUIElement,_ b:MessagesOwnedComposerContract.Budget)throws {
            let(s,v)=try read(field,kAXEnabledAttribute,b);guard s == .success,let v,CFGetTypeID(v)==CFBooleanGetTypeID(),CFBooleanGetValue((v as! CFBoolean)) else {throw MessagesFixtureError.metadata}
        }
        func inventory()throws->Inventory {
            guard AXIsProcessTrusted() else {throw MessagesFixtureError.permission}   // perm-1004
            let b=MessagesOwnedComposerContract.Budget(began:DispatchTime.now().uptimeNanoseconds,limit:100_000_000)
            let root=AXUIElementCreateApplication(pid)
            let access=MessagesExistingEditors<AXUIElement>.Access(now:{DispatchTime.now().uptimeNanoseconds},ready:{self.ready()},
                windows:{try? self.elements(root,kAXWindowsAttribute,b)},owner:{node in do {try self.owner(node,b);return true} catch {return nil}},
                role:{try? self.string($0,kAXRoleAttribute,b)},subrole:{try? self.subrole($0,b)},editable:{try? self.editable($0,b)},
                zero:{try? self.zero($0,b)},children:{try? self.elements($0,kAXChildrenAttribute,b)},equal:{CFEqual($0,$1)})
            return try MessagesExistingEditors<AXUIElement>.read(access,budget:b)
        }
        func focused()throws->(AXUIElement,AXUIElement) {
            guard ready(),AXIsProcessTrusted() else {throw MessagesFixtureError.permission}
            let b=MessagesOwnedComposerContract.Budget(began:DispatchTime.now().uptimeNanoseconds,limit:100_000_000),root=AXUIElementCreateApplication(pid)
            let window=try element(root,kAXFocusedWindowAttribute,b),field=try element(root,kAXFocusedUIElementAttribute,b)
            try owner(window,b);try owner(field,b)
            guard try string(window,kAXRoleAttribute,b)=="AXWindow",CaptureFixtureMetadata.nonSecure(role:try string(field,kAXRoleAttribute,b),subrole:try subrole(field,b)) else {throw MessagesFixtureError.foreignScope}
            try enabled(field,b);guard try editable(field,b) else {throw MessagesFixtureError.metadata};return(window,field)
        }
        func proof()->Bool {
            guard sameBirth(),let p=AccessibilityReader.typingProof(pid:pid,generation:1,policyVersion:1,now:DispatchTime.now().uptimeNanoseconds) else {return false}
            return sameBirth() && p.bundle==bundle && p.surface == .native && p.verified && p.fieldStateVerified
        }
        func label(_ field:AXUIElement,_ name:String,_ b:MessagesOwnedComposerContract.Budget)throws->MessagesLabelRead {
            let(s,v)=try read(field,name,b)
            if s == .attributeUnsupported || s == .noValue {return .absent}
            guard s == .success,let v,CFGetTypeID(v)==CFStringGetTypeID(),let text=v as? String,text.utf8.count<=128 else {return .unreadable}
            return .text(text)
        }
        /// Called only after the new editor's positive ownership proof, never inventory.
        func fieldClass(_ field:AXUIElement)throws->MessagesFieldClass {
            let b=MessagesOwnedComposerContract.Budget(began:DispatchTime.now().uptimeNanoseconds,limit:100_000_000)
            return MessagesOwnedComposerContract.field(description:try label(field,kAXDescriptionAttribute,b),help:try label(field,kAXHelpAttribute,b))
        }
        func retained(window:AXUIElement,field:AXUIElement)throws->Bool {
            let(w,f)=try focused()
            guard CFEqual(w,window),CFEqual(f,field),proof() else {return false}
            let(afterW,afterF)=try focused()
            return CFEqual(afterW,window) && CFEqual(afterF,field) && ready()
        }
        func matches(window:AXUIElement,field:AXUIElement,kind:MessagesFieldClass)throws->Bool {
            let b=MessagesOwnedComposerContract.Budget(began:DispatchTime.now().uptimeNanoseconds,limit:100_000_000)
            guard try retained(window:window,field:field),try fieldClass(field)==kind,
                  try retained(window:window,field:field),try fieldClass(field)==kind else {return false}
            return b.accepts(DispatchTime.now().uptimeNanoseconds) && ready(post:true)
        }
        static func fixedUSKeyboard()->Bool {
            guard let source=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),let layout=TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let sourceRaw=TISGetInputSourceProperty(source,kTISPropertyInputSourceID),let layoutRaw=TISGetInputSourceProperty(layout,kTISPropertyInputSourceID) else {return false}
            return CaptureWorkflowContract.fixedUSKeyboard(inputID:Unmanaged<CFString>.fromOpaque(sourceRaw).takeUnretainedValue() as String,
                layoutID:Unmanaged<CFString>.fromOpaque(layoutRaw).takeUnretainedValue() as String,flags:CGEventSource.flagsState(.combinedSessionState))
        }
        /// Final exact refs after the potentially slow app/signature readiness.
        /// No ready()/proof()/label callback runs after these ref reads.
        func finalFocused(window:AXUIElement,field:AXUIElement,kind:MessagesFieldClass)throws->Bool {
            guard AXIsProcessTrusted() else {return false}   // perm-1004
            let b=MessagesOwnedComposerContract.Budget(began:DispatchTime.now().uptimeNanoseconds,limit:100_000_000)
            let root=AXUIElementCreateApplication(pid)
            let w=try element(root,kAXFocusedWindowAttribute,b),f=try element(root,kAXFocusedUIElementAttribute,b)
            try owner(w,b);try owner(f,b)
            guard CFEqual(w,window),CFEqual(f,field),try string(w,kAXRoleAttribute,b)=="AXWindow",
                  CaptureFixtureMetadata.nonSecure(role:try string(f,kAXRoleAttribute,b),subrole:try subrole(f,b)) else {return false}
            try enabled(f,b)
            guard try editable(f,b),try fieldClass(f)==kind,proof(),b.accepts(DispatchTime.now().uptimeNanoseconds) else {return false}
            // Proof/metadata can themselves take time; exact focus refs are
            // read last. No readiness/proof/label work follows these reads.
            let afterW=try element(root,kAXFocusedWindowAttribute,b),afterF=try element(root,kAXFocusedUIElementAttribute,b)
            return CFEqual(afterW,window) && CFEqual(afterF,field) && b.accepts(DispatchTime.now().uptimeNanoseconds)
                && DispatchTime.now().uptimeNanoseconds<deadline && !IsSecureEventInputEnabled()
        }
        func post(code:CGKeyCode,flags:CGEventFlags=[],requiredScope:()throws->Bool)throws {
            guard AXIsProcessTrusted(),CGPreflightPostEventAccess() else {throw MessagesFixtureError.permission}   // perm-1004
            guard (flags.isEmpty || flags == .maskCommand),MessagesOwnedComposerContract.allowedControl(code:code,command:flags == .maskCommand),
                  let down=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:true),let up=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:false) else {throw MessagesFixtureError.permission}
            down.flags=flags;up.flags=[]
            // An attempted-control receipt is deliberately before all final
            // admission reads, never a latency gap after scope validation.
            CaptureMessagesFixtureTrial.emit(["phase":"messages-control-attempt","fixture":MessagesOwnedComposerContract.fixture,
                "control":flags == .maskCommand ? "new":(code == 48 ? "recipient-tab":"recipient-digit")])
            try MessagesOwnedComposerContract.postControl(ready:{self.ready(post:true)},requiredScope:{
                try MessagesKernelControlScope.read(now:{DispatchTime.now().uptimeNanoseconds},
                    scope:requiredScope,birth:{self.sameBirth()},secure:{IsSecureEventInputEnabled()})
            },post:{
                down.post(tap:.cgSessionEventTap);up.post(tap:.cgSessionEventTap)
            })
        }
    }
    static func checkedRoot(_ text:String)throws->URL {
        guard let physical=realpath(text,nil) else {throw MessagesFixtureError.path};defer{free(physical)}
        var s=stat();let root=URL(fileURLWithPath:text,isDirectory:true)
        guard String(cString:physical)==text,root.path==text,root.deletingLastPathComponent().path=="/private/tmp",
              lstat(text,&s)==0,s.st_mode&S_IFMT==S_IFDIR,s.st_uid==getuid(),s.st_mode&0o777==0o700,
              Set(try FileManager.default.contentsOfDirectory(atPath:text))==["OWNED-FIXTURE"] else {throw MessagesFixtureError.path}
        let fd=open(root.appendingPathComponent("OWNED-FIXTURE").path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else {throw MessagesFixtureError.path};defer{close(fd)}
        let marker=Array(MessagesOwnedComposerContract.declaration.utf8);var bytes=[UInt8](repeating:0,count:marker.count)
        guard fstat(fd,&s)==0,s.st_mode&S_IFMT==S_IFREG,s.st_uid==getuid(),s.st_nlink==1,s.st_mode&0o777==0o600,s.st_size==marker.count,
              bytes.withUnsafeMutableBytes({read(fd,$0.baseAddress,$0.count)})==marker.count,bytes==marker else {throw MessagesFixtureError.path};return root
    }
    static func main() {
        do {try run()}
        catch {emit(["phase":"blocked","fixture":MessagesOwnedComposerContract.fixture,"code":(error as? MessagesFixtureError)?.rawValue ?? "operation","allowed":false,"capturePass":false,"storeOpened":false,"bodyInputPosted":false]);exit(77)}
    }
    static func run()throws {
        try CaptureFixtureTrial.authenticate()
        let config=try MessagesOwnedComposerContract.Configuration.parse(CaptureFixtureTrial.options())
        let root=try checkedRoot(config.root);try CaptureFixtureTrial.reserveOutput(root)
        let ax=try AX(pid:config.pid),prior=try ax.inventory()
        guard ax.ready(post:true) else {throw MessagesFixtureError.permission}
        // Repeat the entire positive-empty inventory immediately before New.
        let finalPrior=try ax.inventory()
        guard prior.windows.count==finalPrior.windows.count,zip(prior.windows,finalPrior.windows).allSatisfy({CFEqual($0,$1)}),
              prior.editors.count==finalPrior.editors.count,zip(prior.editors,finalPrior.editors).allSatisfy({CFEqual($0,$1)}) else {throw MessagesFixtureError.changed}
        emit(["phase":"messages-new-attempt","fixture":MessagesOwnedComposerContract.fixture,"existingEditableFieldsEmptyVerified":true,"bodyInputPosted":false,"storeOpened":false])
        try ax.post(code:45,flags:.maskCommand,requiredScope:{
            let atPost=try ax.inventory()
            return finalPrior.windows.count==atPost.windows.count && zip(finalPrior.windows,atPost.windows).allSatisfy({CFEqual($0,$1)})
                && finalPrior.editors.count==atPost.editors.count && zip(finalPrior.editors,atPost.editors).allSatisfy({CFEqual($0,$1)})
        });newPosted=true // fixed Command-N; no Return or content clearing
        let until=min(ax.deadline,DispatchTime.now().uptimeNanoseconds+2_000_000_000)
        var selected:(AXUIElement,AXUIElement)?
        while DispatchTime.now().uptimeNanoseconds<until {
            if let pair=try? ax.focused(),!finalPrior.editors.contains(where:{CFEqual($0,pair.1)}),ax.proof() {selected=pair;break}
            CFRunLoopRunInMode(.defaultMode,0.025,true)
        }
        guard let(window,field)=selected else {throw MessagesFixtureError.newTransition}
        let b=MessagesOwnedComposerContract.Budget(began:DispatchTime.now().uptimeNanoseconds,limit:100_000_000)
        guard try ax.zero(field,b),MessagesOwnedComposerContract.ownsNew(commandPosted:true,allPriorEmpty:true,newEditor:true,exactPID:ax.ready(),exactWindow:true,typedZero:true,nativeProof:ax.proof()) else {throw MessagesFixtureError.typedZero}
        // Field labels are read only now: all prior editors were empty and New
        // produced a fresh empty editor with real signed-native proof.
        guard try ax.retained(window:window,field:field) else {throw MessagesFixtureError.changed}
        let initial=try ax.fieldClass(field)
        guard try ax.retained(window:window,field:field) else {throw MessagesFixtureError.changed}
        emit(["phase":"messages-owned-new","fixture":MessagesOwnedComposerContract.fixture,"ownedNewComposerVerified":true,"currentEditorEmptyVerified":true,"fieldClass":initial.rawValue,"nativeProofVerified":true,"bodyInputPosted":false,"storeOpened":false])
        guard initial != .unknown && initial != .unreadable else {throw MessagesFixtureError.fieldUnknown}
        guard initial == .recipient else {throw MessagesFixtureError.fieldRecipient}
        guard config.recipientSetup else {
            emit(["phase":"preflight","mode":"preflight","fixture":MessagesOwnedComposerContract.fixture,"allowed":false,"ownedNewComposerVerified":true,"fieldClass":"recipient","requiresRecipientSetup":true,"bodyInputPosted":false,"capturePass":false,"storeOpened":false]);return
        }
        guard MessagesOwnedComposerContract.mayTypeRecipient(ownedNew:true,field:initial,zeroAtStart:true,retainedScope:try ax.matches(window:window,field:field,kind:.recipient),postAllowed:CGPreflightPostEventAccess()) else {throw MessagesFixtureError.changed}
        let codes:[Character:CGKeyCode]=["0":29,"1":18,"2":19,"5":23]
        for c in MessagesOwnedComposerContract.recipient {
            guard try ax.matches(window:window,field:field,kind:.recipient),let code=codes[c] else {throw MessagesFixtureError.changed}
            try ax.post(code:code,requiredScope:{try ax.finalFocused(window:window,field:field,kind:.recipient)});recipientPosted += 1;CFRunLoopRunInMode(.defaultMode,0.015,true)
        }
        guard try ax.matches(window:window,field:field,kind:.recipient) else {throw MessagesFixtureError.changed}
        try ax.post(code:48,requiredScope:{try ax.finalFocused(window:window,field:field,kind:.recipient)});tabPosted=true // Tab recipient completion; never Return/body send
        var body:(AXUIElement,AXUIElement)?;let bodyUntil=min(ax.deadline,DispatchTime.now().uptimeNanoseconds+2_000_000_000)
        while DispatchTime.now().uptimeNanoseconds<bodyUntil {
            if let pair=try? ax.focused(),CFEqual(pair.0,window),!CFEqual(pair.1,field),!finalPrior.editors.contains(where:{CFEqual($0,pair.1)}),ax.proof() {body=pair;break}
            CFRunLoopRunInMode(.defaultMode,0.025,true)
        }
        guard let(_,editor)=body else {throw MessagesFixtureError.fieldBody}
        let bodyBudget=MessagesOwnedComposerContract.Budget(began:DispatchTime.now().uptimeNanoseconds,limit:100_000_000)
        guard try ax.retained(window:window,field:editor) else {throw MessagesFixtureError.changed}
        let bodyZero=try ax.zero(editor,bodyBudget),bodyClass=try ax.fieldClass(editor)
        guard MessagesOwnedComposerContract.ownsBody(ownedNew:true,sameWindow:true,
              newEditor:!finalPrior.editors.contains(where:{CFEqual($0,editor)}),differsRecipient:!CFEqual(field,editor),
              typedZero:bodyZero,field:bodyClass,nativeProof:ax.proof()),
              try ax.matches(window:window,field:editor,kind:.body) else {throw MessagesFixtureError.fieldBody}
        emit(["phase":"preflight","mode":"preflight","fixture":MessagesOwnedComposerContract.fixture,"allowed":true,"ownedNewComposerVerified":true,"existingEditableFieldsEmptyVerified":true,"nativeProofVerified":true,"currentEditorEmptyVerified":true,"fieldClass":"body","scopeHeld":true,"newCommandPosted":true,"recipientSetupPosted":true,"recipientOutcomeVerified":false,"bodyInputPosted":false,"capturePass":false,"storeOpened":false,"submitted":false,"sendClaim":false])
    }
}
#endif
