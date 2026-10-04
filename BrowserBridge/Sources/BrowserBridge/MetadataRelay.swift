import Foundation
import Darwin

public enum MetadataRelayError: Error {case deadline,closed,io,oversized,descriptor}

/// Bounded framing on already-owned local descriptors. End-to-end v3 signatures
/// authenticate the app/extension; this relay never grants trust to argv or an
/// arbitrary local socket. Root supplies the authenticated endpoint lifecycle.
/// One owner only; don't pass shared descriptors. No listener/service is started.
public enum MetadataRelay {
    static func ready(_ fd:Int32,_ events:Int16,_ until:UInt64) throws {
        let now=DispatchTime.now().uptimeNanoseconds
        guard now<until else {throw MetadataRelayError.deadline}
        var item=pollfd(fd:fd,events:events,revents:0)
        let ms=Int32(min(1000,(until-now)/1_000_000+1)),result=poll(&item,1,ms)
        guard result>0 else {throw result==0 ? MetadataRelayError.deadline : MetadataRelayError.io}
        guard item.revents & events != 0 else {throw MetadataRelayError.closed}
    }
    public static func readFrame(_ fd:Int32,deadline:UInt64)throws->Data {
        func exact(_ count:Int)throws->Data {
            var result=Data()
            while result.count<count {
                try ready(fd,Int16(POLLIN),deadline)
                var bytes=[UInt8](repeating:0,count:count-result.count)
                let got=Darwin.read(fd,&bytes,bytes.count)
                if got<0 && (errno==EINTR || errno==EAGAIN){continue}
                guard got>0 else {throw MetadataRelayError.closed}
                result.append(contentsOf:bytes.prefix(got))
            }
            return result
        }
        let header=try exact(4);var length:UInt32=0
        _=withUnsafeMutableBytes(of:&length){header.copyBytes(to:$0)}
        guard length>0,length<=NativeFrames.limit else {throw MetadataRelayError.oversized}
        return try exact(Int(length))
    }
    public static func writeFrame(_ body:Data,to fd:Int32,deadline:UInt64)throws {
        let frame=try NativeFrames.encode(body),flags=fcntl(fd,F_GETFL),noSignal=fcntl(fd,F_GETNOSIGPIPE)
        guard flags>=0,noSignal>=0,fcntl(fd,F_SETFL,flags|O_NONBLOCK)==0 else {throw MetadataRelayError.descriptor}
        defer{_ = fcntl(fd,F_SETFL,flags);_ = fcntl(fd,F_SETNOSIGPIPE,noSignal)}
        guard fcntl(fd,F_SETNOSIGPIPE,1)==0 else {throw MetadataRelayError.descriptor}
        try frame.withUnsafeBytes{raw in
            var at=0
            while at<frame.count {
                try ready(fd,Int16(POLLOUT),deadline)
                let wrote=Darwin.write(fd,raw.baseAddress!.advanced(by:at),frame.count-at)
                if wrote<0 && (errno==EINTR || errno==EAGAIN){continue}
                guard wrote>0 else {throw MetadataRelayError.closed};at+=wrote
            }
        }
    }
    /// One exact frame transfer, including hello. Signature validation is owned
    /// by AuthenticatedMetadataSession/AuthenticatedChromeBridge, not the relay.
    public static func forward(from:Int32,to:Int32,deadline:UInt64)throws {
        try writeFrame(readFrame(from,deadline:deadline),to:to,deadline:deadline)
    }
}
