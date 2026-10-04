#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
import AppKit
import ApplicationServices
import Carbon
import Darwin
import Foundation
import MemoryCore
import PrivacyPolicy
import Security

/// Separate QA preparation. App activation/menu action only; no keystroke, note fields or capture.
@MainActor enum CaptureNotesActivation {
    static var menuObservation:NotesActivationContract.MenuObservation?
    static var activationRequestIssued=false,activationCallReturned=false,newNoteMenuPressIssued=false
    static func emit(_ phase:String,code:String?=nil) {
        var r:[String:Any] = ["phase":phase,"activationRequestIssued":activationRequestIssued,
            "activationCallReturned":activationCallReturned,"newNoteMenuPressIssued":newNoteMenuPressIssued,
            "typingInputPosted":false,"notesFieldsRead":false,"noteIdentityVerified":false,
            "cloudNoteVerified":false,"dedicatedWindowVerified":false,"inputAuthorized":false,
            "captureStarted":false,"storeOpened":false,"permissionRequested":false]
        if let menuObservation { for (key,value) in menuObservation.fields { r[key]=value } }
        if let code {r["code"]=code};CaptureFixtureTrial.emit(r)
    }
    static func main() {
        do {try run()} catch {emit("notes-preparation-blocked",code:(error as? NotesActivationError)?.rawValue ?? "operation");exit(77)}
    }
    static func root(_ c:NotesActivationContract.Configuration) throws -> URL {
        guard let physical=realpath(c.root,nil) else {throw NotesActivationError.path};defer{free(physical)}
        var s=stat()
        guard String(cString:physical)==c.root,lstat(c.root,&s)==0,s.st_mode&S_IFMT==S_IFDIR,s.st_uid==getuid(),s.st_mode&0o777==0o700,
              Set(try FileManager.default.contentsOfDirectory(atPath:c.root))==["OWNED-FIXTURE"] else {throw NotesActivationError.path}
        let r=URL(fileURLWithPath:c.root,isDirectory:true)
        let (data,_)=try CaptureNotesMetadataInspector.file(r.appendingPathComponent("OWNED-FIXTURE"),maximum:128)
        guard data==Data(c.declaration.utf8) else {throw NotesActivationError.declaration};return r
    }
    static func held(_ c:NotesActivationContract.Configuration,_ deadline:NotesActivationContract.Deadline,front:Bool) throws {
        guard deadline.accepts(DispatchTime.now().uptimeNanoseconds) else {throw NotesActivationError.deadline}
        if front {
            guard AXIsProcessTrusted() else {throw NotesActivationError.permission}
            RunLoop.current.run(until:Date().addingTimeInterval(0.001))
        }
        guard let app=NSRunningApplication(processIdentifier:c.pid),app.bundleURL?.path==NotesActivationContract.appPath,
              NotesActivationContract.identity(pid:c.pid,start:c.start,path:app.executableURL?.path,bundle:app.bundleIdentifier,currentPID:app.processIdentifier,
                  currentStart:ProcessStart.kernelSeconds(pid:c.pid)) else {throw NotesActivationError.process}
        guard let row=TypingCategories.app(NotesActivationContract.bundle),let text=TypingCategories.signingRequirement(row) else {throw NotesActivationError.signature}
        var code:SecCode?,requirement:SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:c.pid] as CFDictionary,[],&code)==errSecSuccess,let code,
              SecRequirementCreateWithString(text as CFString,[],&requirement)==errSecSuccess,let requirement,
              SecCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),requirement)==errSecSuccess else {throw NotesActivationError.signature}
        guard !IsSecureEventInputEnabled() else {throw NotesActivationError.secureInput}
        if front {
            // Require live system focus in addition to refreshed NSWorkspace state.
            guard NotesActivationContract.focused(expected:c.pid,workspace:NSWorkspace.shared.frontmostApplication?.processIdentifier,system:AccessibilityReader.systemFocusedApplication()) else {throw NotesActivationError.foreground}
        }
        guard deadline.accepts(DispatchTime.now().uptimeNanoseconds) else {throw NotesActivationError.deadline}
    }
    static func run() throws {
        try CaptureFixtureTrial.authenticate()
        let c=try NotesActivationContract.Configuration.parse(CommandLine.arguments),r=try root(c)
        try CaptureFixtureTrial.reserveOutput(r)
        let d=NotesActivationContract.Deadline(began:DispatchTime.now().uptimeNanoseconds,limit:UInt64(c.seconds*1e9))
        try held(c,d,front:false)
        if c.action == .inspectMenu {
            // Passive diagnostic: fresh foreground must already hold. No activation or menu action.
            try held(c,d,front:true)
            let original=try menu(c,d,scan:.first,diagnostic:true)
            let current=try menu(c,d,scan:.second,diagnostic:true)
            guard NotesActivationContract.references([original.bar,original.file,original.menu,original.item],[current.bar,current.file,current.menu,current.item],equal:{CFEqual($0,$1)}) else {throw NotesActivationError.reference}
            try held(c,d,front:true);emit("notes-menu-diagnostic-complete");return
        }
        // Retain and activate only the exact existing process. No opener or launch fallback.
        guard let retained=NSRunningApplication(processIdentifier:c.pid) else {throw NotesActivationError.process}
        try held(c,d,front:false)
        guard !retained.isTerminated else {throw NotesActivationError.process}
        try held(c,d,front:false)
        activationRequestIssued=true
        let accepted=retained.activate(options:[])
        activationCallReturned=true;emit("notes-preparation-activation-returned")
        guard accepted else {throw NotesActivationError.activation}
        while !NotesActivationContract.foreground(expected:c.pid,actual:NSWorkspace.shared.frontmostApplication?.processIdentifier) {
            try held(c,d,front:false);RunLoop.current.run(until:Date().addingTimeInterval(0.01))
        }
        try held(c,d,front:true)
        if c.action == .newNote {try pressNew(c,d)}
        try held(c,d,front:true);emit("notes-preparation-complete")
    }
    // Only bounded command topology. Never inspect windows/editor, AXValue, recent submenu or private rows.
    static func read(_ node:AXUIElement,_ name:String) throws -> (AXError,CFTypeRef?) {
        guard AXUIElementSetMessagingTimeout(node,0.025) == .success else {throw NotesActivationError.transport}
        var v:CFTypeRef?;let e=AXUIElementCopyAttributeValue(node,name as CFString,&v);return(e,v)
    }
    static func owner(_ node:AXUIElement,_ c:NotesActivationContract.Configuration) throws {
        guard AXUIElementSetMessagingTimeout(node,0.025) == .success else {throw NotesActivationError.transport}
        var p:pid_t=0;guard AXUIElementGetPid(node,&p) == .success,p==c.pid else {
            menuObservation?.failure = .owner;throw NotesActivationError.process
        }
    }
    static func element(_ node:AXUIElement,_ name:String) throws -> AXUIElement {
        let(e,v)=try read(node,name);guard e == .success,let v,CFGetTypeID(v)==AXUIElementGetTypeID() else {throw NotesActivationError.menu};return v as! AXUIElement
    }
    static func children(_ node:AXUIElement,maximum:Int) throws -> [AXUIElement] {
        let(e,v)=try read(node,kAXChildrenAttribute);guard e == .success,let v,CFGetTypeID(v)==CFArrayGetTypeID(),let a=v as? [AXUIElement],a.count<=maximum else {throw NotesActivationError.menu}
        guard a.allSatisfy({CFGetTypeID($0)==AXUIElementGetTypeID()}) else {throw NotesActivationError.type};return a
    }
    static func string(_ node:AXUIElement,_ name:String,optional:Bool=false) throws -> String? {
        let(e,v)=try read(node,name)
        if optional && (e == .attributeUnsupported || e == .noValue) {return nil}
        guard e == .success,let v,CFGetTypeID(v)==CFStringGetTypeID(),let s=v as? String,s.utf8.count<=32 else {throw NotesActivationError.type};return s
    }
    static func menuRole(_ node:AXUIElement,_ expected:String) throws -> String? {
        let value=try string(node,kAXRoleAttribute)
        if value != expected {menuObservation?.failure = .role}
        return value
    }
    static func number(_ node:AXUIElement,_ name:String,optional:Bool=false) throws -> Int? {
        let(e,v)=try read(node,name)
        if optional && (e == .attributeUnsupported || e == .noValue) {return nil}
        guard e == .success,let v,CFGetTypeID(v)==CFNumberGetTypeID(),!CFNumberIsFloatType((v as! CFNumber)) else {throw NotesActivationError.type}
        var raw:Int64=0
        guard CFNumberGetValue((v as! CFNumber),.sInt64Type,&raw),let number=Int(exactly:raw) else {throw NotesActivationError.type};return number
    }
    static func enabled(_ node:AXUIElement) throws -> Bool {
        let(e,v)=try read(node,kAXEnabledAttribute);guard e == .success,let v,CFGetTypeID(v)==CFBooleanGetTypeID() else {throw NotesActivationError.type};return CFBooleanGetValue((v as! CFBoolean))
    }
    static func supportsPress(_ node:AXUIElement) throws -> Bool {
        guard AXUIElementSetMessagingTimeout(node,0.025) == .success else {throw NotesActivationError.transport}
        var a:CFArray?;guard AXUIElementCopyActionNames(node,&a) == .success,let a,let names=a as? [String],names.count<=8 else {throw NotesActivationError.action};return names.contains(kAXPressAction as String)
    }
    struct MenuReferences {let bar:AXUIElement,file:AXUIElement,menu:AXUIElement,item:AXUIElement}
    static func menu(_ c:NotesActivationContract.Configuration,_ d:NotesActivationContract.Deadline,scan:NotesActivationContract.MenuScan = .first,diagnostic:Bool = false) throws -> MenuReferences {
        if diagnostic {menuObservation = .init(scan:scan)}
        try held(c,d,front:true)
        guard AXIsProcessTrusted() else {throw NotesActivationError.permission}   // perm-1004
        let app=AXUIElementCreateApplication(c.pid),bar=try element(app,kAXMenuBarAttribute)
        try owner(bar,c);guard try menuRole(bar,"AXMenuBar")=="AXMenuBar" else {throw NotesActivationError.menu}
        let top=try children(bar,maximum:16);guard top.count>NotesActivationContract.filePosition else {throw NotesActivationError.menu}
        let file=top[NotesActivationContract.filePosition];try owner(file,c)
        guard try NotesActivationContract.staticFile(role:menuRole(file,"AXMenuBarItem"),title:string(file,kAXTitleAttribute),position:NotesActivationContract.filePosition) else {throw NotesActivationError.menu}
        let branches=try children(file,maximum:1);guard branches.count==1 else {throw NotesActivationError.menu}
        let menu=branches[0];try owner(menu,c);guard try menuRole(menu,"AXMenu")=="AXMenu" else {throw NotesActivationError.menu}
        let items=try children(menu,maximum:64);var matches:[Int]=[],buckets=NotesActivationContract.CommandBuckets()
        for (i,item) in items.enumerated() {
            try held(c,d,front:true);try owner(item,c)
            guard try menuRole(item,"AXMenuItem")=="AXMenuItem" else {throw NotesActivationError.menu}
            // No title or submenu reads here, including recent-note commands.
            let character=try string(item,kAXMenuItemCmdCharAttribute,optional:true),modifiers=try number(item,kAXMenuItemCmdModifiersAttribute,optional:true)
            if NotesActivationContract.command(character:character,modifiers:modifiers) {matches.append(i)}
            if diagnostic {buckets.observe(character:character,modifiers:modifiers)}
        }
        if diagnostic {
            menuObservation?.counted(matches.count)
            menuObservation?.countedCommands(buckets)
            emit("notes-menu-scan-observed")
        }
        let index=try NotesActivationContract.unique(matches)
        guard NotesActivationContract.candidatePosition(index) else {throw NotesActivationError.command}
        let item=items[index]
        if diagnostic {try held(c,d,front:true);return .init(bar:bar,file:file,menu:menu,item:item)}
        guard try NotesActivationContract.staticNew(role:string(item,kAXRoleAttribute),title:string(item,kAXTitleAttribute),character:string(item,kAXMenuItemCmdCharAttribute),modifiers:number(item,kAXMenuItemCmdModifiersAttribute),enabled:enabled(item),press:supportsPress(item)) else {throw NotesActivationError.command}
        try held(c,d,front:true);return .init(bar:bar,file:file,menu:menu,item:item)
    }
    static func pressNew(_ c:NotesActivationContract.Configuration,_ d:NotesActivationContract.Deadline) throws {
        guard AXIsProcessTrusted() else {throw NotesActivationError.permission}
        let original=try menu(c,d,scan:.first),current=try menu(c,d,scan:.second)
        guard NotesActivationContract.references([original.bar,original.file,original.menu,original.item],[current.bar,current.file,current.menu,current.item],equal:{CFEqual($0,$1)}) else {throw NotesActivationError.reference}
        try owner(original.item,c);try held(c,d,front:true)
        // This action is bound to the validated Notes command. No key can fall through to TextEdit.
        guard try NotesActivationContract.staticNew(role:string(original.item,kAXRoleAttribute),title:string(original.item,kAXTitleAttribute),character:string(original.item,kAXMenuItemCmdCharAttribute),modifiers:number(original.item,kAXMenuItemCmdModifiersAttribute),enabled:enabled(original.item),press:supportsPress(original.item)) else {throw NotesActivationError.command}
        try held(c,d,front:true)
        newNoteMenuPressIssued=true
        let result=AXUIElementPerformAction(original.item,kAXPressAction as CFString)
        emit("notes-preparation-new-menu-returned")
        guard result == .success else {throw NotesActivationError.action}
        try held(c,d,front:true)
        // Success only acknowledges command delivery; no new/cloud/dedicated/note identity claim.
    }
}
#endif
