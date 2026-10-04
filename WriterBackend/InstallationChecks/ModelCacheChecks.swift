import Foundation
import CryptoKit
import Darwin
@testable import WriterBackend

func modelCacheLockProbe(_ root:URL) async throws {
    let data=Data("synthetic model weights, not a real model".utf8)
    let asset=PinnedAsset(url:URL(string:"https://example.invalid/model")!,bytes:Int64(data.count),sha256:SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined())
    do {_ = try await PersistentModelCache.acquire(asset:asset,root:root,priorRoots:[],chunks:{_,_ in fatalError("duplicate transfer")});throw WriterFailure.integrity}
    catch WriterFailure.busy {print("PASS separate-process shared cache lock")}
}

func modelCacheChecks() async throws {
    precondition(AssetDownload.responseAllowed(status:206,contentRange:"bytes 7-39/40",offset:7,total:40))
    precondition(!AssetDownload.responseAllowed(status:200,contentRange:nil,offset:7,total:40))
    precondition(!AssetDownload.responseAllowed(status:206,contentRange:"bytes 8-39/40",offset:7,total:40))
    precondition(!AssetDownload.responseAllowed(status:206,contentRange:"bytes 7-40/41",offset:7,total:40))
    let fm = FileManager.default
    let root = URL(fileURLWithPath:"/private/tmp/writer-cache-check-" + UUID().uuidString)
    try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    defer {try? fm.removeItem(at:root)}
    let data = Data("synthetic model weights, not a real model".utf8)
    let hash = SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
    let asset = PinnedAsset(url:URL(string:"https://example.invalid/model")!,bytes:Int64(data.count),sha256:hash)
    let chunks:ModelRangeChunks = {_,offset in AsyncThrowingStream {$0.yield(data.dropFirst(Int(offset)));$0.finish()}}
    let noNetwork:ModelRangeChunks = {_,_ in throw WriterFailure.denied}
    func sub(_ name:String) throws -> URL {let u=root.appendingPathComponent(name);try fm.createDirectory(at:u,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);return u}
    func fails(_ work:() async throws -> Void) async {do {try await work();fatalError("expected failure")} catch {}}
    let first = try sub("Mac Mem"), next = try sub("Daydream")
    let original = try await PersistentModelCache.acquire(asset:asset,root:first,priorRoots:[],chunks:chunks)
    let reused = try await PersistentModelCache.acquire(asset:asset,root:next,priorRoots:[first],chunks:noNetwork)
    precondition(original == reused && !fm.fileExists(atPath:next.appendingPathComponent(hash+".model").path))
    let restarted = try await PersistentModelCache.discover(asset:asset,roots:[next,first]);precondition(restarted == original)
    let partial = try sub("partial")
    try data.prefix(7).write(to:partial.appendingPathComponent(hash+".partial"))
    let resume:ModelRangeChunks = {url,offset in precondition(offset == 7);return try await chunks(url,offset)}
    _ = try await PersistentModelCache.acquire(asset:asset,root:partial,priorRoots:[],chunks:resume)
    let corrupt = try sub("corrupt")
    try Data(repeating:0,count:data.count).write(to:corrupt.appendingPathComponent(hash+".model"))
    await fails {_ = try await PersistentModelCache.acquire(asset:asset,root:corrupt,priorRoots:[],chunks:noNetwork)}
    precondition(fm.fileExists(atPath:corrupt.appendingPathComponent(hash+".model").path))
    let badPartial = try sub("badPartial")
    try Data(repeating:0,count:data.count).write(to:badPartial.appendingPathComponent(hash+".partial"))
    await fails {_ = try await PersistentModelCache.acquire(asset:asset,root:badPartial,priorRoots:[],chunks:noNetwork)}
    let locked = try sub("locked")
    let slow:ModelRangeChunks = {_,_ in AsyncThrowingStream(unfolding:{try await Task.sleep(nanoseconds:5_000_000_000);return data})}
    let task = Task {try await PersistentModelCache.acquire(asset:asset,root:locked,priorRoots:[],chunks:slow)}
    for _ in 0..<100 {if fm.fileExists(atPath:locked.appendingPathComponent(hash+".partial").path) {break};try await Task.sleep(nanoseconds:5_000_000)}
    do {_ = try await PersistentModelCache.acquire(asset:asset,root:locked,priorRoots:[],chunks:chunks);fatalError("concurrent acquisition")}
    catch WriterFailure.busy {} // kernel lock, independent cache calls
    var pathSize:UInt32=4096;var path=[CChar](repeating:0,count:Int(pathSize))
    precondition(_NSGetExecutablePath(&path,&pathSize)==0)
    let process=Process();process.executableURL=URL(fileURLWithPath:String(cString:path));process.arguments=["--cache-lock-probe",locked.path]
    try process.run();process.waitUntilExit();precondition(process.terminationStatus==0)
    task.cancel();await fails {_ = try await task.value}
    _ = try await PersistentModelCache.acquire(asset:asset,root:locked,priorRoots:[],chunks:chunks)
    let revisedData=Data("new explicit model version".utf8)
    let revised=PinnedAsset(url:asset.url,bytes:Int64(revisedData.count),sha256:SHA256.hash(data:revisedData).map{String(format:"%02x",$0)}.joined())
    let revisionURL=try await PersistentModelCache.acquire(asset:revised,root:first,priorRoots:[],chunks:{_,_ in AsyncThrowingStream{$0.yield(revisedData);$0.finish()}})
    precondition(revisionURL != original && fm.fileExists(atPath:original.path))
    let linked = try sub("linked")
    try fm.createSymbolicLink(at:linked.appendingPathComponent(hash+".model"),withDestinationURL:original)
    await fails {_ = try await PersistentModelCache.discover(asset:asset,roots:[linked])}
    print("PASS cache: reuse/update/restart discovery, range resume, corrupt preservation, cancel/retry, shared lock contention, symlink rejection; synthetic only")
}
