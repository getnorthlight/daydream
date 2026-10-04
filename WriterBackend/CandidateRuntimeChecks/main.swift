import Foundation
import Darwin
import WriterBackend

@main struct CandidateRuntimeChecks {
    static func main() async {
        do {
            if CommandLine.arguments.dropFirst().first=="--candidate" {try await child()}
            else {try stage()}
        } catch {print("FAIL candidate runtime check (no private input)");exit(1)}
    }
    static func stage() throws {
        guard CommandLine.arguments.count==3,let plan=WriterCandidates.recommended else {throw WriterFailure.invalidInput}
        let archive=URL(fileURLWithPath:CommandLine.arguments[1]),model=URL(fileURLWithPath:CommandLine.arguments[2])
        try CompatibleInstallation.verify(model,asset:plan.asset)
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("writer-candidate-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer {try? fm.removeItem(at:root)}
        let contents=root.appendingPathComponent("Synthetic Writer.app/Contents"),macOS=contents.appendingPathComponent("MacOS"),resources=contents.appendingPathComponent("Resources/Writer")
        for directory in [macOS,resources] {try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
        // Copy-on-write reuses the verified model bytes. No download/second model.
        guard clonefile(model.path,resources.appendingPathComponent(plan.asset.sha256+".model").path,0)==0 else {throw WriterFailure.unavailable}
        _=try CompatibleInstallation.extractRuntime(archive:archive,root:resources)
        let executable=macOS.appendingPathComponent("WriterCandidateCheck")
        try fm.copyItem(at:URL(fileURLWithPath:CommandLine.arguments[0]),to:executable)
        // Stage child locates all resources relative to its own executable.
        // No source model path, build-directory path or DYLD override is passed.
        let process=Process();process.executableURL=executable;process.arguments=["--candidate"]
        process.currentDirectoryURL=root
        process.environment=["PATH":"/usr/bin:/bin","TMPDIR":root.path]
        try process.run();process.waitUntilExit()
        guard process.terminationStatus==0 else {throw WriterFailure.unavailable}
        print("PASS fresh relocated app-shaped process, seven pinned dylibs, actual synthetic inference; own candidate removed")
    }
    static func child() async throws {
        let executable=URL(fileURLWithPath:CommandLine.arguments[0])
        let resources=executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Writer")
        let files=try await CompatibleInstallation.restore(in:resources)
        let runtime=LlamaInference(files:files)
        let start=Date();try await runtime.load()
        guard await runtime.dependenciesAreLocal() else {throw WriterFailure.integrity}
        let output=try await runtime.generate(instruction:"Return JSON only: {\"ok\":true}",evidence:"Synthetic relocated candidate loader acceptance",maxTokens:64)
        guard (try JSONSerialization.jsonObject(with:output) as? [String:Bool])?["ok"]==true else {throw WriterFailure.invalidOutput}
        let gpu=await runtime.offloadEvidence();await runtime.unload()
        print("PASS child: resource-relative load, no DYLD overrides, offloaded=\(gpu.layers)/\(gpu.total), synthetic inference seconds=\(Date().timeIntervalSince(start))")
        let restored=try await CompatibleInstallation.restore(in:resources)
        let reopened=LlamaInference(files:restored)
        try await reopened.load()
        guard await reopened.dependenciesAreLocal() else {throw WriterFailure.integrity}
        let retry=try await reopened.generate(instruction:"Return JSON only: {\"ok\":true}",evidence:"Synthetic offline reopened writer",maxTokens:64)
        guard (try JSONSerialization.jsonObject(with:retry) as? [String:Bool])?["ok"]==true else {throw WriterFailure.invalidOutput}
        await reopened.unload()
        print("PASS child: second offline restore, revalidation, new writer and inference")
    }
}
