import Foundation
import CryptoKit
import WriterBackend

@main struct InstallationChecks {
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--cache-lock-probe" {
            try await modelCacheLockProbe(URL(fileURLWithPath:CommandLine.arguments[2]));return
        }
        if CommandLine.arguments.count == 6, CommandLine.arguments[1] == "--download-quit-probe" {
            let a=CommandLine.arguments
            try await downloadQuitProbe(root:URL(fileURLWithPath:a[2]),port:UInt16(a[3])!,bytes:Int64(a[4])!,hash:a[5]);return
        }
        try await modelCacheChecks()
        try await downloadServerChecks()
        precondition(!CompatibleInstallation.supportsRuntime(osMajor:25,architecture:"arm64"))
        precondition(CompatibleInstallation.supportsRuntime(osMajor:26,architecture:"arm64"))
        precondition(!CompatibleInstallation.supportsRuntime(osMajor:26,architecture:"x86_64"))
        let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("writer-install-check-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:root)}
        let payload=Data("synthetic model bytes".utf8)
        let hash=SHA256.hash(data:payload).map{String(format:"%02x",$0)}.joined()
        let asset=PinnedAsset(url:URL(string:"https://example.invalid/model")!,bytes:Int64(payload.count),sha256:hash)
        let plan=ModelInstallPlan(asset:asset,minimumMemory:1,architecture:"test",runtimeCompatible:true)
        let chunks:AssetChunks={_ in AsyncThrowingStream{ $0.yield(payload);$0.finish() }}
        func expectFailure(_ run: () async throws -> Void) async {
            do {try await run();fatalError("expected rejection")} catch {}
        }
        await expectFailure { _ = try await ManagedInstaller().start(plan,directory:root,physicalMemory:1,freeBytes:1,architecture:"test",chunks:chunks,progress:{_ in}) }
        let corrupt:AssetChunks={_ in AsyncThrowingStream{$0.yield(Data(repeating:0,count:payload.count));$0.finish()}}
        await expectFailure {_ = try await ManagedInstaller().start(plan,directory:root,physicalMemory:1,freeBytes:1000,architecture:"test",chunks:corrupt,progress:{_ in})}
        let offline:AssetChunks={_ in throw URLError(.notConnectedToInternet)}
        await expectFailure {_ = try await ManagedInstaller().start(plan,directory:root,physicalMemory:1,freeBytes:1000,architecture:"test",chunks:offline,progress:{_ in})}
        let installer=ManagedInstaller()
        let slow:AssetChunks={_ in AsyncThrowingStream(unfolding:{try await Task.sleep(for:.seconds(10));return payload})}
        let pending=Task{try await installer.start(plan,directory:root,physicalMemory:1,freeBytes:1000,architecture:"test",chunks:slow,progress:{_ in})}
        try await Task.sleep(for:.milliseconds(30));await installer.cancel()
        await expectFailure {_ = try await pending.value}
        let installed=try await installer.start(plan,directory:root,physicalMemory:1,freeBytes:1000,architecture:"test",chunks:chunks,progress:{_ in})
        try CompatibleInstallation.verify(installed,asset:asset)
        let files=try FileManager.default.contentsOfDirectory(atPath:root.path)
        precondition(!files.contains(where:{$0.hasSuffix(".partial")}))
        let source=WriterCandidates.recommended!.asset.url
        precondition(AssetDownload.redirectAllowed(from:source,to:URL(string:"https://us.aws.cdn.hf.co/public-asset")!))
        for url in ["http://us.aws.cdn.hf.co/a","https://evil.invalid/a","https://user:pass@us.aws.cdn.hf.co/a","https://us.aws.cdn.hf.co:444/a"] {
            precondition(!AssetDownload.redirectAllowed(from:source,to:URL(string:url)!))
        }
        if CommandLine.arguments.count == 2 {
            let library=try CompatibleInstallation.extractRuntime(archive:URL(fileURLWithPath:CommandLine.arguments[1]),root:root)
            let names=try FileManager.default.contentsOfDirectory(atPath:library.deletingLastPathComponent().path)
            precondition(names.count == 7 && names.allSatisfy{$0.hasSuffix(".dylib")})
            for name in names {let values=try library.deletingLastPathComponent().appendingPathComponent(name).resourceValues(forKeys:[.isSymbolicLinkKey]);precondition(values.isSymbolicLink == false)}
            _ = try CompatibleInstallation.extractRuntime(archive:URL(fileURLWithPath:CommandLine.arguments[1]),root:root)
            try Data("corrupt".utf8).write(to:library)
            await expectFailure {_ = try CompatibleInstallation.extractRuntime(archive:URL(fileURLWithPath:CommandLine.arguments[1]),root:root)}
            print("PASS verified pinned runtime extraction, reuse, dependency tamper rejection; only seven regular dylibs")
        }
        print("PASS macOS25/26 and architecture compatibility; low-space/hash-fail/offline/cancel/retry/partial cleanup/redirect policy synthetic checks")
    }
}
