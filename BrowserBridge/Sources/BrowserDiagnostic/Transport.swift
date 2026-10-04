import Foundation
import CryptoKit
import Darwin

/// Diagnostic-only descriptor framing. Never imports capture relay/protocol.
public enum DiagnosticWire {
    static func ready(_ fd:Int32,_ event:Int16,_ deadline:UInt64,cancelled:()->Bool={false})throws {
        while true {
            guard !cancelled() else {throw DiagnosticError.closed}
            let now=DispatchTime.now().uptimeNanoseconds;guard now<deadline else {throw DiagnosticError.expired}
            var p=pollfd(fd:fd,events:event,revents:0)
            let result=poll(&p,1,Int32(min(100,(deadline-now)/1_000_000+1)))
            if result<0 && errno==EINTR {continue}
            guard result>=0 else {throw DiagnosticError.io}
            if result==0 {continue}
            guard p.revents & event != 0 else {throw DiagnosticError.closed};return
        }
    }
    public static func read(_ fd:Int32,deadline:UInt64)throws->Data {
        func exact(_ n:Int)throws->Data {
            var result=Data()
            while result.count<n {
                try ready(fd,Int16(POLLIN),deadline)
                var bytes=[UInt8](repeating:0,count:n-result.count)
                let got=Darwin.read(fd,&bytes,bytes.count)
                if got<0 && (errno==EINTR || errno==EAGAIN){continue}
                guard got>0 else {throw DiagnosticError.closed};result.append(contentsOf:bytes.prefix(got))
            };return result
        }
        let header=try exact(4)
        let count=header.enumerated().reduce(UInt32(0)){$0 | UInt32($1.element)<<($1.offset*8)}
        guard count>0,count<=4096 else {throw DiagnosticError.invalid}
        return try exact(Int(count))
    }
    public static func write(_ data:Data,to fd:Int32,deadline:UInt64)throws {
        guard data.count>0,data.count<=4096 else {throw DiagnosticError.invalid}
        let flags=fcntl(fd,F_GETFL),sig=fcntl(fd,F_GETNOSIGPIPE)
        guard flags>=0,sig>=0,fcntl(fd,F_SETFL,flags|O_NONBLOCK)==0,fcntl(fd,F_SETNOSIGPIPE,1)==0 else {throw DiagnosticError.io}
        defer{_ = fcntl(fd,F_SETFL,flags);_ = fcntl(fd,F_SETNOSIGPIPE,sig)}
        var count=UInt32(data.count).littleEndian
        let framed=withUnsafeBytes(of:&count){Data($0)}+data
        try framed.withUnsafeBytes{raw in
            var at=0
            while at<framed.count {
                try ready(fd,Int16(POLLOUT),deadline)
                let n=Darwin.write(fd,raw.baseAddress!.advanced(by:at),framed.count-at)
                if n<0 && (errno==EINTR || errno==EAGAIN){continue}
                guard n>0 else {throw DiagnosticError.closed};at+=n
            }
        }
    }
    static func address(_ path:String)throws->sockaddr_un {
        var a=sockaddr_un();a.sun_family=sa_family_t(AF_UNIX);a.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes=Array(path.utf8)+[0]
        guard bytes.count<=MemoryLayout.size(ofValue:a.sun_path) else {throw DiagnosticError.invalid}
        withUnsafeMutableBytes(of:&a.sun_path){$0.copyBytes(from:bytes)};return a
    }
    static func peer(_ fd:Int32)throws {
        var uid:uid_t=0,gid:gid_t=0
        guard getpeereid(fd,&uid,&gid)==0,uid==geteuid() else {throw DiagnosticError.invalid}
    }
    static func connect(_ directory:URL,deadline:UInt64)throws->Int32 {
        try DiagnosticConfiguration.privateDirectory(directory)
        let path=directory.appendingPathComponent("browser-diagnostic.sock").path
        var s=stat()
        guard lstat(path,&s)==0,s.st_mode&S_IFMT==S_IFSOCK,s.st_uid==geteuid(),s.st_mode&0o077==0 else {throw DiagnosticError.unavailable}
        let fd=socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else {throw DiagnosticError.io}
        do {
            guard fcntl(fd,F_SETFL,O_NONBLOCK)==0 else {throw DiagnosticError.io}
            var a=try address(path)
            let r=withUnsafePointer(to:&a){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
            if r != 0 {
                guard errno==EINPROGRESS else {throw DiagnosticError.unavailable}
                try ready(fd,Int16(POLLOUT),deadline)
                var err:Int32=0,len=socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd,SOL_SOCKET,SO_ERROR,&err,&len)==0,err==0 else {throw DiagnosticError.io}
            }
            try peer(fd);return fd
        } catch {Darwin.close(fd);throw error}
    }
    struct Envelope:Codable {let diagnostic:DiagnosticFrame}
    public static func unwrap(_ data:Data)throws->DiagnosticFrame {
        guard data.count<=4096 else {throw DiagnosticError.invalid}
        let value=try JSONDecoder().decode(Envelope.self,from:data)
        guard try DiagnosticFrame.encode(value)==data else {throw DiagnosticError.invalid}
        return try DiagnosticFrame.decode(DiagnosticFrame.encode(value.diagnostic))
    }
    public static func wrap(_ frame:DiagnosticFrame)throws->Data {try DiagnosticFrame.encode(Envelope(diagnostic:frame))}
}

/// One separately owned endpoint for one armed attempt. App calls run on a worker.
/// cancel shuts down descriptors; only the owning run closes them. Never replaces sockets.
public final class DiagnosticEndpoint {
    public let attempt:DiagnosticAttempt
    private let path:String,inode:ino_t,listener:Int32
    private let lock=NSLock()
    private var stopped=false,started=false,peerFD:Int32 = -1
    private let configurationIsCurrent:()->Bool
    public init(configuration:DiagnosticConfiguration,appKey:P256.Signing.PrivateKey,
                configurationIsCurrent:@escaping()->Bool)throws {
        self.configurationIsCurrent=configurationIsCurrent
        guard configurationIsCurrent() else {throw DiagnosticError.invalid}
        attempt=try DiagnosticAttempt(binding:configuration.binding,appKey:appKey,extensionKey:configuration.extensionPublicKey)
        path=configuration.directory.appendingPathComponent("browser-diagnostic.sock").path
        try DiagnosticConfiguration.privateDirectory(configuration.directory)
        let fd=socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else {throw DiagnosticError.io}
        do {
            var a=try DiagnosticWire.address(path)
            let r=withUnsafePointer(to:&a){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
            guard r==0 else {throw DiagnosticError.unavailable}
            var s=stat();guard lstat(path,&s)==0,chmod(path,0o600)==0,listen(fd,2)==0 else {throw DiagnosticError.io}
            inode=s.st_ino;listener=fd
        } catch {Darwin.close(fd);throw error}
    }
    public func cancel() {
        lock.lock();stopped=true
        if peerFD>=0 {_ = shutdown(peerFD,SHUT_RDWR)}
        _ = shutdown(listener,SHUT_RDWR);lock.unlock();attempt.cancel()
    }
    private var active:Bool {lock.lock();defer{lock.unlock()};return !stopped}
    public func run()throws->String {
        lock.lock();guard !started,!stopped else {lock.unlock();throw DiagnosticError.closed};started=true;lock.unlock()
        defer{cancel()}
        let end=DispatchTime.now().uptimeNanoseconds+30_000_000_000
        for _ in 0..<2 {
            guard active,configurationIsCurrent() else {throw DiagnosticError.closed}
            try DiagnosticWire.ready(listener,Int16(POLLIN),end,cancelled:{!self.active})
            let fd=Darwin.accept(listener,nil,nil);guard fd>=0 else {throw DiagnosticError.io}
            lock.lock();peerFD=fd;let allowed = !stopped;lock.unlock()
            defer{lock.lock();peerFD = -1;Darwin.close(fd);lock.unlock()}
            guard allowed else {throw DiagnosticError.closed}
            try DiagnosticWire.peer(fd)
            let deadline=min(end,DispatchTime.now().uptimeNanoseconds+2_000_000_000)
            let frame=try DiagnosticWire.unwrap(DiagnosticWire.read(fd,deadline:deadline))
            guard active,configurationIsCurrent() else {throw DiagnosticError.closed}
            let reply=try DiagnosticFrame.decode(attempt.receive(DiagnosticFrame.encode(frame)))
            guard active,configurationIsCurrent() else {throw DiagnosticError.closed}
            try DiagnosticWire.write(DiagnosticWire.wrap(reply),to:fd,deadline:deadline)
        }
        return "acknowledged"
    }
    deinit {
        Darwin.close(listener)
        var s=stat()
        if lstat(path,&s)==0,s.st_ino==inode,s.st_uid==geteuid(),s.st_mode&S_IFMT==S_IFSOCK {unlink(path)}
    }
}

public enum DiagnosticHost {
    /// One native message, not an unbounded relay. Public configuration rechecked by app.
    public static func exchange(_ data:Data,configuration:DiagnosticConfiguration)throws->Data {
        let f=try DiagnosticWire.unwrap(data)
        guard f.binding==configuration.binding,["hello","ack"].contains(f.kind) else {throw DiagnosticError.invalid}
        try f.verify(configuration.extensionPublicKey,now:DiagnosticFrame.milliseconds)
        let deadline=DispatchTime.now().uptimeNanoseconds+2_000_000_000
        let fd=try DiagnosticWire.connect(configuration.directory,deadline:deadline);defer{Darwin.close(fd)}
        try DiagnosticWire.write(data,to:fd,deadline:deadline)
        let response=try DiagnosticWire.read(fd,deadline:deadline),r=try DiagnosticWire.unwrap(response)
        guard r.sameAttempt(as:f),r.clientNonce==f.clientNonce,
              r.kind==(f.kind=="hello" ? "challenge" : "receipt") else {throw DiagnosticError.invalid}
        try r.verify(configuration.appPublicKey,now:DiagnosticFrame.milliseconds)
        return response
    }
    public static func run(configuration:DiagnosticConfiguration,callerOrigin:String,input:Int32=STDIN_FILENO,output:Int32=STDOUT_FILENO)throws {
        guard configuration.binding.browser=="chrome",
              callerOrigin=="chrome-extension://"+configuration.binding.extensionID+"/" else {throw DiagnosticError.invalid}
        let deadline=DispatchTime.now().uptimeNanoseconds+2_000_000_000
        let response=try exchange(DiagnosticWire.read(input,deadline:deadline),configuration:configuration)
        try DiagnosticWire.write(response,to:output,deadline:deadline)
    }
}
