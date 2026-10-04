import Foundation
import Darwin

/// Local app lifecycle only. No launchd service, default path, installation or
/// trust from a socket. App/extension signatures remain mandatory end to end.
public final class MetadataLocalListener {
    public let descriptor:Int32
    private let path:String
    private let inode:ino_t
    private var closed=false
    public init(directory:URL)throws {
        try MetadataLocalTransport.directory(directory)
        path=directory.appendingPathComponent("browser-metadata.sock").path
        let fd=socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else {throw MetadataRelayError.io}
        do {
            var address=try MetadataLocalTransport.address(path)
            let result=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
            guard result==0 else {throw MetadataRelayError.io} // never replace stale/live endpoints
            guard chmod(path,0o600)==0,listen(fd,2)==0 else {throw MetadataRelayError.io}
            var info=stat();guard lstat(path,&info)==0 else {throw MetadataRelayError.io}
            descriptor=fd;inode=info.st_ino
        } catch {Darwin.close(fd);throw error}
    }
    public func accept(deadline:UInt64)throws->Int32 {
        guard !closed else {throw MetadataRelayError.closed}
        try MetadataRelay.ready(descriptor,Int16(POLLIN),deadline)
        let fd=Darwin.accept(descriptor,nil,nil);guard fd>=0 else {throw MetadataRelayError.io}
        do {try MetadataLocalTransport.peer(fd);return fd} catch {Darwin.close(fd);throw error}
    }
    public func close() {
        guard !closed else{return};closed=true;Darwin.close(descriptor)
        var info=stat()
        if lstat(path,&info)==0,info.st_ino==inode,info.st_uid==geteuid(),info.st_mode&S_IFMT==S_IFSOCK {unlink(path)}
    }
    deinit {close()}
}
public enum MetadataLocalTransport {
    static func directory(_ url:URL)throws {
        var s=stat();guard url.isFileURL,lstat(url.path,&s)==0,s.st_mode&S_IFMT==S_IFDIR,
              s.st_uid==geteuid(),s.st_mode&0o077==0 else {throw MetadataRelayError.descriptor}
    }
    static func address(_ path:String)throws->sockaddr_un {
        var value=sockaddr_un();value.sun_family=sa_family_t(AF_UNIX);value.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes=Array(path.utf8)+[0]
        guard bytes.count<=MemoryLayout.size(ofValue:value.sun_path) else {throw MetadataRelayError.descriptor}
        withUnsafeMutableBytes(of:&value.sun_path){$0.copyBytes(from:bytes)};return value
    }
    static func peer(_ fd:Int32)throws {
        var uid:uid_t=0,gid:gid_t=0
        guard getpeereid(fd,&uid,&gid)==0,uid==geteuid() else {throw MetadataRelayError.descriptor}
    }
    public static func connect(directory url:URL,deadline:UInt64)throws->Int32 {
        try directory(url)
        let path=url.appendingPathComponent("browser-metadata.sock").path
        var info=stat();guard lstat(path,&info)==0,info.st_mode&S_IFMT==S_IFSOCK,info.st_uid==geteuid(),info.st_mode&0o077==0 else {throw MetadataRelayError.descriptor}
        let fd=socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else {throw MetadataRelayError.io}
        do {
            guard fcntl(fd,F_SETFL,O_NONBLOCK)==0 else {throw MetadataRelayError.io}
            var a=try address(path)
            let result=withUnsafePointer(to:&a){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
            if result != 0 {
                guard errno==EINPROGRESS else {throw MetadataRelayError.io}
                try MetadataRelay.ready(fd,Int16(POLLOUT),deadline)
                var error:Int32=0,length=socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&length)==0,error==0 else {throw MetadataRelayError.io}
            }
            try peer(fd);return fd
        }catch{Darwin.close(fd);throw error}
    }
    /// Safari request/response entry. App retains the authenticated session,
    /// not this transient connection. All bytes are verified by the endpoints.
    public static func exchange(_ frame:Data,directory:URL,deadline:UInt64)throws->Data {
        let fd=try connect(directory:directory,deadline:deadline);defer{Darwin.close(fd)}
        try MetadataRelay.writeFrame(frame,to:fd,deadline:deadline)
        return try MetadataRelay.readFrame(fd,deadline:deadline)
    }
}

/// Packaged configuration is explicit. Missing config stays unavailable; no
/// environment variables, home-directory guessing or synthetic enable flag.
public struct MetadataHostConfiguration {
    public let directory:URL, extensionID:String
    public init(directory:URL,extensionID:String,browser:MetadataBrowser)throws {
        guard browser.acceptsExtensionID(extensionID) else {throw MetadataEnrollmentError.invalid}
        try MetadataLocalTransport.directory(directory);self.directory=directory;self.extensionID=extensionID
    }
    public static func bundled(browser:MetadataBrowser,bundle:Bundle = .main)throws->Self {
        guard let path=bundle.object(forInfoDictionaryKey:"DaydreamBrowserRelayDirectory") as? String,path.hasPrefix("/"),
              let id=bundle.object(forInfoDictionaryKey:"DaydreamBrowserExtensionID") as? String else {throw MetadataEnrollmentError.invalid}
        return try Self(directory:URL(fileURLWithPath:path,isDirectory:true),extensionID:id,browser:browser)
    }
}
public enum ChromeMetadataHost {
    public static func run(configuration:MetadataHostConfiguration,callerOrigin:String,input:Int32=STDIN_FILENO,output:Int32=STDOUT_FILENO)throws {
        guard callerOrigin=="chrome-extension://\(configuration.extensionID)/" else {throw MetadataEnrollmentError.invalid}
        let firstDeadline=DispatchTime.now().uptimeNanoseconds+2_000_000_000
        let first=try MetadataRelay.readFrame(input,deadline:firstDeadline)
        guard let hello=MetadataHello.decode(first),hello.browser == .chrome,hello.extensionID==configuration.extensionID else {throw MetadataEnrollmentError.invalid}
        let fd=try MetadataLocalTransport.connect(directory:configuration.directory,deadline:firstDeadline);defer{Darwin.close(fd)}
        try MetadataRelay.writeFrame(first,to:fd,deadline:firstDeadline)
        while true {
            let deadline=DispatchTime.now().uptimeNanoseconds+5_000_000_000
            try MetadataRelay.forward(from:fd,to:output,deadline:deadline)
            try MetadataRelay.forward(from:input,to:fd,deadline:deadline)
        }
    }
}
public struct MetadataHello:Decodable {
    public let version:Int,browser:MetadataBrowser,kind:String,extensionID:String,clientNonce:String,textEnabled:Bool
    public static func decode(_ bytes:Data)->Self? {
        guard bytes.count<=4096,let object=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              Set(object.keys)==["version","browser","kind","extensionID","clientNonce","textEnabled"],
              let hello=try? JSONDecoder().decode(Self.self,from:bytes),hello.version==3,hello.kind=="metadata_hello",!hello.textEnabled,
              hello.browser.acceptsExtensionID(hello.extensionID),SignedMetadataFrame.token(hello.clientNonce) else{return nil}
        return hello
    }
}
