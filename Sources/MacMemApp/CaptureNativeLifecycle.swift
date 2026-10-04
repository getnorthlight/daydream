import AppKit
import Foundation
import Darwin

#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
/// Closed QA story; never receives arbitrary typing strings from the CLI.
enum NativeLifecycleContract {
    static let id = "native-owned-day-v1"
    static let savedID = "native-owned-save-reopen-v1"
    static let persistedID = "native-owned-persisted-reopen-v1"
    static let persistedV2ID = "native-owned-persisted-reopen-v2"
    static let texts = ["I started a chess club note","Write the morning plan"," about the vote and support"]
    static var alpha: String {texts[0]+texts[2]}
    static func expectedDocument(_ index:Int, final:Bool) -> String {
        index == 1 ? texts[1] : (final ? alpha : texts[0])
    }

}

/// Reads only bounded, private, task-owned files beneath the already admitted QA root.
enum NativeLifecycleFiles {
    static func root(_ root:URL) throws {
        var st=stat()
        guard let physical=realpath(root.path,nil) else {throw IntakeError.path}
        defer{free(physical)}
        guard root.deletingLastPathComponent().path == "/private/tmp",
              root.lastPathComponent.hasPrefix("daydream-capture-fixture-"),
              String(cString:physical)==root.path,
              lstat(root.path,&st)==0,st.st_mode & S_IFMT == S_IFDIR,
              st.st_uid==getuid(),st.st_mode & 0o077==0 else {throw IntakeError.path}
    }
    static func read(_ name:String, root:URL, maximum:Int=65536) throws -> Data {
        try self.root(root)
        guard !name.isEmpty,!name.contains("/"),!name.contains("\0"),maximum>0,maximum<=65536 else {throw IntakeError.path}
        let directory=open(root.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard directory>=0 else {throw IntakeError.path};defer{close(directory)}
        var parent=stat()
        guard fstat(directory,&parent)==0,parent.st_mode & S_IFMT == S_IFDIR,
              parent.st_uid==getuid(),parent.st_mode & 0o077==0 else {throw IntakeError.path}
        let fd=openat(directory,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else {throw IntakeError.path};defer{close(fd)}
        var st=stat()
        guard fstat(fd,&st)==0,st.st_mode & S_IFMT == S_IFREG,st.st_uid==getuid(),
              st.st_nlink==1,st.st_mode & 0o077==0,st.st_size>=0,st.st_size<=maximum else {throw IntakeError.path}
        let count=Int(st.st_size)
        var bytes=[UInt8](repeating:0,count:count),offset=0
        while offset<bytes.count {
            let n=bytes.withUnsafeMutableBytes {raw in Darwin.read(fd,raw.baseAddress!.advanced(by:offset),count-offset)}
            if n<0 && errno==EINTR {continue}
            guard n>0 else {throw IntakeError.path};offset+=n
        }
        var after=stat(),named=stat(),currentParent=stat()
        guard fstat(fd,&after)==0,fstatat(directory,name,&named,AT_SYMLINK_NOFOLLOW)==0,
              lstat(root.path,&currentParent)==0,currentParent.st_dev==parent.st_dev,currentParent.st_ino==parent.st_ino,
              currentParent.st_mode & S_IFMT == S_IFDIR,currentParent.st_uid==getuid(),currentParent.st_mode & 0o077==0,
              named.st_dev==st.st_dev,named.st_ino==st.st_ino,named.st_mode & S_IFMT == S_IFREG,
              named.st_uid==getuid(),named.st_nlink==1,named.st_mode & 0o077==0,
              after.st_size==st.st_size,after.st_mtimespec.tv_sec==st.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec==st.st_mtimespec.tv_nsec else {throw IntakeError.path}
        return Data(bytes)
    }
}

@MainActor final class NativeLifecycleNeutralWindow {
    let window:NSWindow
    let identifier:String
    init(root:URL){
        identifier="DayDream QA Neutral "+root.lastPathComponent
        window=NSWindow(contentRect:NSRect(x:160,y:160,width:420,height:150),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title=identifier
        window.identifier=NSUserInterfaceItemIdentifier(identifier)
        let label=NSTextField(labelWithString:"Owned recorder workflow pause")
        label.frame=NSRect(x:24,y:50,width:370,height:30);window.contentView?.addSubview(label)
        window.isReleasedWhenClosed=false
    }
    func show() throws {
        guard Thread.isMainThread else {throw IntakeError.lifecycleNeutralRefused}
        // The private fixture entry bypasses the normal SwiftUI app construction.
        // Initialize only this QA application's activation lifecycle, after owned A typing.
        let app=NSApplication.shared
        let before=app.activationPolicy().rawValue
        let attempted=app.activationPolicy() != .regular
        let accepted=attempted ? app.setActivationPolicy(.regular) : false
        CaptureFixtureTrial.emit(["phase":"workflow-neutral-initialization","policyBefore":before,
            "policyAfter":app.activationPolicy().rawValue,"policySwitchAttempted":attempted,
            "policySwitchAccepted":accepted,"regularApplication":app.activationPolicy() == .regular,
            "mainThread":true,"inputPosted":false])
        guard app.activationPolicy() == .regular else {throw IntakeError.lifecycleNeutralRefused}
        app.finishLaunching()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps:true)
    }
    var readiness:[String:Any] {
        ["phase":"workflow-neutral-readiness","windowVisible":window.isVisible,
         "windowKey":window.isKeyWindow,"applicationKeyWindowMatches":NSApp.keyWindow===window,
         "windowIdentifierMatches":window.identifier?.rawValue==identifier,
         "frontmostMatches":NSWorkspace.shared.frontmostApplication?.processIdentifier==getpid(),
         "applicationActive":NSApp.isActive,"activationPolicy":NSApp.activationPolicy().rawValue,
         "inputPosted":false,"ready":focused]
    }
    var focused:Bool{
        window.isVisible && window.isKeyWindow && NSApp.keyWindow===window &&
        window.identifier?.rawValue==identifier &&
        NSWorkspace.shared.frontmostApplication?.processIdentifier==getpid()
    }
    func close(){window.close()}
}
#endif
