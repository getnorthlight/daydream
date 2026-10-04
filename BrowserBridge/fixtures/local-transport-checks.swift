import Foundation
import Darwin
import BrowserBridge

@main struct LocalTransportChecks {
    static func check(_ value:Bool){precondition(value)}
    static func main()throws {
        let directory=URL(fileURLWithPath:"/private/tmp/browser-relay-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let listener=try MetadataLocalListener(directory:directory)
        do {_=try MetadataLocalListener(directory:directory);fatalError("second owner accepted")}catch{}
        let hello=Data(#"{"version":3,"kind":"metadata_hello","browser":"chrome","extensionID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","clientNonce":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","textEnabled":false}"#.utf8)
        let response=Data(#"{"version":1,"kind":"unavailable","reason":"fixture_no_capture","textEnabled":false}"#.utf8)
        let group=DispatchGroup();group.enter()
        DispatchQueue.global().async {
            defer{group.leave()}
            do {
                let fd=try listener.accept(deadline:DispatchTime.now().uptimeNanoseconds+2_000_000_000);defer{Darwin.close(fd)}
                check(try MetadataRelay.readFrame(fd,deadline:DispatchTime.now().uptimeNanoseconds+1_000_000_000)==hello)
                try MetadataRelay.writeFrame(response,to:fd,deadline:DispatchTime.now().uptimeNanoseconds+1_000_000_000)
            }catch{fatalError("fixture server failed: \(error)")}
        }
        let received=try MetadataLocalTransport.exchange(hello,directory:directory,deadline:DispatchTime.now().uptimeNanoseconds+2_000_000_000)
        precondition(received==response);precondition(group.wait(timeout:.now()+3) == .success)
        // Exercise the actual Chrome host callable, not an inert host surrogate.
        var input:[Int32]=[0,0],output:[Int32]=[0,0];precondition(pipe(&input)==0 && pipe(&output)==0)
        let hostDone=DispatchGroup();hostDone.enter()
        DispatchQueue.global().async {
            defer{hostDone.leave()}
            do {
                let config=try MetadataHostConfiguration(directory:directory,extensionID:String(repeating:"a",count:32),browser:.chrome)
                try ChromeMetadataHost.run(configuration:config,callerOrigin:"chrome-extension://"+String(repeating:"a",count:32)+"/",input:input[0],output:output[1])
            }catch{} // expected EOF after the synthetic peer closes
        }
        let deadline=DispatchTime.now().uptimeNanoseconds+2_000_000_000
        try MetadataRelay.writeFrame(hello,to:input[1],deadline:deadline)
        let app=try listener.accept(deadline:deadline)
        check(try MetadataRelay.readFrame(app,deadline:deadline)==hello)
        try MetadataRelay.writeFrame(response,to:app,deadline:deadline)
        check(try MetadataRelay.readFrame(output[0],deadline:deadline)==response)
        try MetadataRelay.writeFrame(hello,to:input[1],deadline:deadline)
        check(try MetadataRelay.readFrame(app,deadline:deadline)==hello)
        Darwin.close(app);Darwin.close(input[1]);precondition(hostDone.wait(timeout:.now()+3) == .success)
        for fd in [input[0],output[0],output[1]]{Darwin.close(fd)}
        let config=try MetadataHostConfiguration(directory:directory,extensionID:String(repeating:"a",count:32),browser:.chrome)
        do {try ChromeMetadataHost.run(configuration:config,callerOrigin:"chrome-extension://forged/");fatalError("forged caller accepted")}catch{}
        listener.close()
        do {_=try MetadataLocalTransport.connect(directory:directory,deadline:deadline);fatalError("disconnected endpoint accepted")}catch{}
        print("PASS local relay: single owner, request/response, actual Chrome host bidirectional forwarding, forged origin and disconnect; temporary endpoints only")
    }
}
