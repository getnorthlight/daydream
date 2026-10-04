#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
import AppKit
import ApplicationServices
import Carbon
import CryptoKit
import Darwin
import Foundation
import PrivacyPolicy
import MemoryCore
import Security

/// QA-only fact finding. No capture, stores, model, input, activation, AE or permission request.
@MainActor enum CaptureNotesMetadataInspector {
    static let bundle = "com.apple.Notes"
    static func main() {
        do {try run()}
        catch {CaptureFixtureTrial.emit(["phase":"notes-inspection-blocked","code":(error as? NotesMetadataError)?.rawValue ?? "operation","inputAuthorized":false,"captureStarted":false,"storeOpened":false,"noteIdentityVerified":false]);exit(77)}
    }
    static func root(_ c: NotesMetadataContract.Configuration) throws -> URL {
        var s=stat();guard let physical=realpath(c.root,nil) else {throw NotesMetadataError.path}
        defer{free(physical)}
        guard String(cString:physical)==c.root,lstat(c.root,&s)==0,s.st_mode&S_IFMT==S_IFDIR,
              s.st_uid==getuid(),s.st_mode&0o777==0o700 else {throw NotesMetadataError.path}
        let root=URL(fileURLWithPath:c.root,isDirectory:true)
        guard Set(try FileManager.default.contentsOfDirectory(atPath:c.root))==["OWNED-FIXTURE"],
              try file(root.appendingPathComponent("OWNED-FIXTURE"),maximum:128).0 == Data(NotesMetadataContract.declaration.utf8) else {throw NotesMetadataError.declaration}
        return root
    }
    static func file(_ url: URL,maximum: Int) throws -> (Data,Double) {
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else {throw NotesMetadataError.ticket};defer{close(fd)}
        var s=stat();guard fstat(fd,&s)==0,s.st_mode&S_IFMT==S_IFREG,s.st_uid==getuid(),s.st_nlink==1,
              s.st_mode&0o777==0o600,s.st_size>=0,s.st_size<=maximum else {throw NotesMetadataError.ticket}
        var data=Data(count:Int(s.st_size))
        guard data.withUnsafeMutableBytes({Darwin.read(fd,$0.baseAddress,$0.count)})==data.count else {throw NotesMetadataError.ticket}
        return(data,Double(s.st_mtimespec.tv_sec)+Double(s.st_mtimespec.tv_nsec)/1e9)
    }
    static func process(_ pid:pid_t)->Double? {
        guard let p=NSRunningApplication(processIdentifier:pid),p.bundleIdentifier==bundle else{return nil}
        return ProcessStart.seconds(launchDate:p.launchDate,pid:pid)
    }
    static func trusted(_ pid:pid_t)->Bool {
        guard let row=TypingCategories.app(bundle),let text=TypingCategories.signingRequirement(row) else{return false}
        var code:SecCode?,requirement:SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:pid] as CFDictionary,[],&code)==errSecSuccess,
              let code,SecRequirementCreateWithString(text as CFString,[],&requirement)==errSecSuccess,let requirement else{return false}
        return SecCodeCheckValidity(code,[],requirement)==errSecSuccess
    }
    static func windows(_ pid:pid_t)throws->[NotesMetadataContract.Window] {
        // Only number/owner/layer/bounds. Never access CGWindowName or other window labels.
        guard let info=CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]] else {throw NotesMetadataError.window}
        var result:[NotesMetadataContract.Window]=[]
        for row in info where (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==pid && (row[kCGWindowLayer as String] as? NSNumber)?.intValue==0 {
            guard let number=row[kCGWindowNumber as String] as? NSNumber,let b=row[kCGWindowBounds as String] as? [String:Any],
                  let x=b["X"] as? Double,let y=b["Y"] as? Double,let w=b["Width"] as? Double,let h=b["Height"] as? Double else {throw NotesMetadataError.bounds}
            let f=NotesMetadataContract.Frame(x:x,y:y,width:w,height:h);guard f.valid else {throw NotesMetadataError.bounds}
            result.append(.init(id:number.intValue,frame:f))
        }
        guard Set(result.map(\.id)).count==result.count else {throw NotesMetadataError.multipleWindows}
        return result
    }
    static func read(_ node:AXUIElement,_ name:String)throws->(AXError,CFTypeRef?) {
        guard AXUIElementSetMessagingTimeout(node,0.025) == .success else {throw NotesMetadataError.attribute}
        var value:CFTypeRef?;let error=AXUIElementCopyAttributeValue(node,name as CFString,&value);return(error,value)
    }
    static func element(_ node:AXUIElement,_ name:String)throws->AXUIElement {
        let (e,v)=try read(node,name);guard e == .success,let v,CFGetTypeID(v)==AXUIElementGetTypeID() else {throw NotesMetadataError.field};return v as! AXUIElement
    }
    static func owner(_ node:AXUIElement)throws->pid_t {
        guard AXUIElementSetMessagingTimeout(node,0.025) == .success else {throw NotesMetadataError.attribute}
        var pid:pid_t=0;guard AXUIElementGetPid(node,&pid) == .success,pid>0 else {throw NotesMetadataError.field};return pid
    }
    static func count(_ node:AXUIElement)throws->Int {
        let (e,v)=try read(node,kAXNumberOfCharactersAttribute);guard e == .success,let v,CFGetTypeID(v)==CFNumberGetTypeID(),let n=v as? NSNumber,CFNumberIsFloatType((v as! CFNumber))==false else {throw NotesMetadataError.characters};return n.intValue
    }
    static func text(_ node:AXUIElement,_ name:String)throws->NotesMetadataContract.Attribute {
        let(e,v)=try read(node,name)
        switch e {
        case .attributeUnsupported:return .unsupported
        case .noValue:return .absent
        case .success:
            guard let v,CFGetTypeID(v)==CFStringGetTypeID(),let s=v as? String else{return .wrongType}
            return s.utf8.count<=4096 ? .text(s) : .oversized
        default:return .transport
        }
    }
    static func frame(_ window:AXUIElement)throws->NotesMetadataContract.Frame {
        let(ep,p)=try read(window,kAXPositionAttribute), (es,s)=try read(window,kAXSizeAttribute)
        guard ep == .success,es == .success,let p,let s,CFGetTypeID(p)==AXValueGetTypeID(),CFGetTypeID(s)==AXValueGetTypeID() else {throw NotesMetadataError.bounds}
        var point=CGPoint.zero,size=CGSize.zero
        guard AXValueGetValue(p as! AXValue,.cgPoint,&point),AXValueGetValue(s as! AXValue,.cgSize,&size) else {throw NotesMetadataError.bounds}
        return .init(x:point.x,y:point.y,width:size.width,height:size.height)
    }
    static func ready(_ c:NotesMetadataContract.Configuration,start:Double)->Bool {
        AXIsProcessTrusted() && CGPreflightListenEventAccess() && !IsSecureEventInputEnabled() && process(c.pid)==start &&
        NSWorkspace.shared.frontmostApplication?.processIdentifier==c.pid &&
        AccessibilityReader.systemFocusedApplication()==c.pid
    }
    static func proof(_ c:NotesMetadataContract.Configuration)->Bool {
        let p=AccessibilityReader.typingProof(pid:c.pid,generation:0,policyVersion:0,now:DispatchTime.now().uptimeNanoseconds)
        return p.map{$0.bundle==bundle && $0.surface == .native && $0.verified && $0.fieldStateVerified && $0.frameAccessible && $0.navigationStable} ?? false
    }
    static func run() throws {
        try CaptureFixtureTrial.authenticate()
        let c=try NotesMetadataContract.Configuration.parse(CommandLine.arguments),r=try root(c)
        try CaptureFixtureTrial.reserveOutput(r)
        guard let processStart=process(c.pid),trusted(c.pid) else {throw NotesMetadataError.process}
        let baseline=Set(try windows(c.pid).map(\.id)),armed=Date().timeIntervalSince1970
        let end=DispatchTime.now().uptimeNanoseconds + UInt64(c.seconds*1e9)
        CaptureFixtureTrial.emit(["phase":"notes-inspection-armed","baselineWindowCount":baseline.count,"waitsForFreshCUACreationTicket":true,"notesFieldsRead":false,"inputAuthorized":false,"captureStarted":false,"storeOpened":false])
        let ticket=r.appendingPathComponent("CUA-CREATED-NOTE")
        var observed=false
        while DispatchTime.now().uptimeNanoseconds<=end {
            if FileManager.default.fileExists(atPath:ticket.path) {
                let(bytes,modified)=try file(ticket,maximum:256)
                guard bytes==Data(c.ticket.utf8),NotesMetadataContract.freshTicket(modified:modified,now:Date().timeIntervalSince1970,armed:armed) else {throw NotesMetadataError.ticket}
                observed=true;break
            }
            guard process(c.pid)==processStart else {throw NotesMetadataError.process}
            RunLoop.current.run(until:Date().addingTimeInterval(0.05))
        }
        guard observed else {throw NotesMetadataError.deadline}
        // Before this point no Notes AX window/editor/body/title/document/identifier was read.
        guard ready(c,start:processStart),proof(c),AXIsProcessTrusted() else {throw NotesMetadataError.proof}
        let app=AXUIElementCreateApplication(c.pid),window=try element(app,kAXFocusedWindowAttribute),editor=try element(app,kAXFocusedUIElementAttribute)
        let ownedID=try NotesMetadataContract.ownedWindow(frame(window),windows:windows(c.pid),baseline:baseline)
        let budget=NotesMetadataContract.Budget(began:DispatchTime.now().uptimeNanoseconds,limit:CaptureGate.ttlNanoseconds)
        func held() throws {
            guard budget.accepts(DispatchTime.now().uptimeNanoseconds) else {throw NotesMetadataError.deadline}
            guard ready(c,start:processStart),proof(c),try owner(window)==c.pid,try owner(editor)==c.pid else {throw NotesMetadataError.proof}
            guard NotesMetadataContract.referencesHeld(window:window,editor:editor,currentWindow:try element(app,kAXFocusedWindowAttribute),currentEditor:try element(app,kAXFocusedUIElementAttribute),equal:{CFEqual($0,$1)}) else {throw NotesMetadataError.closure}
            guard try NotesMetadataContract.ownedWindow(frame(window),windows:windows(c.pid),baseline:baseline)==ownedID else {throw NotesMetadataError.window}
            guard NotesMetadataContract.editorRole(try text(editor,kAXRoleAttribute).text) else {throw NotesMetadataError.field}
            guard NotesMetadataContract.characters(try count(editor),phase:c.phase,title:c.title) else {throw NotesMetadataError.empty}
            if c.phase == .firstLine {guard try text(window,kAXTitleAttribute) == .text(c.title) else {throw NotesMetadataError.title}}
            guard budget.accepts(DispatchTime.now().uptimeNanoseconds) else {throw NotesMetadataError.deadline}
        }
        let attributes=[kAXDocumentAttribute,kAXDocumentAttribute,kAXIdentifierAttribute,kAXIdentifierAttribute]
        let nodes=[window,editor,window,editor]
        var samples:[[NotesMetadataContract.Attribute]]=[]
        for _ in 0..<2 {
            var row:[NotesMetadataContract.Attribute]=[]
            for (node,name) in zip(nodes,attributes) {try held();let v=try text(node,name);try held();row.append(v)}
            samples.append(row)
        }
        try held();guard NotesMetadataContract.stable(samples[0],samples[1]) else {throw NotesMetadataError.changed}
        // The ticket is a declaration from the authorized CUA owner, not an input/capture capability.
        let characterCount=try count(editor);try held()
        let labels=["windowDocument","editorDocument","windowWidgetIdentifier","editorWidgetIdentifier"]
        var result:[String:Any]=["phase":"notes-inspection-complete","scopeHeld":true,"newDedicatedWindowRelation":true,"freshCreationTicket":true,
            "metadataSamples":2,"candidateAttributeReads":8,"nativeProof":true,"nativeTextAreaOnly":true,"characterCount":characterCount,
            "noteIdentityVerified":false,"widgetIdentifierPromoted":false,"inputAuthorized":false,"captureStarted":false,"storeOpened":false,
            "defaultNotesProductionGateChanged":false,"permissionRequested":false,"selectedRowOrOtherNoteRead":false]
        for (i,v) in samples[1].enumerated() {
            result[labels[i]+"Status"]=v.status
            if i<2 {result[labels[i]+"URISyntax"]=v.uri}
            if let s=v.text,!s.isEmpty {
                let salt=c.nonce.uuidString+"|"+labels[i]+"|"+s
                result[labels[i]+"CandidateHash"]=SHA256.hash(data:Data(salt.utf8)).map{String(format:"%02x",$0)}.joined()
            }
        }
        CaptureFixtureTrial.emit(result)
    }
}
#endif
