import Foundation
import Darwin
import MemoryCore
import WriterBackend

actor NoKeys:WriterSecureKeyStore {
    var calls=0
    func readSecret() async throws -> String {calls+=1;throw WriterFailure.denied}
    func saveSecret(_ value:String) async throws {calls+=1;throw WriterFailure.denied}
    func removeSecret() async throws {calls+=1;throw WriterFailure.denied}
}
@main struct ColdRestartChecks {
    @MainActor static func waitReady(_ writer:WriterIntegration) async throws {
        for _ in 0..<1000 {
            if !writer.busy {guard writer.ready else {throw WriterFailure.unavailable};return}
            try await Task.sleep(nanoseconds:20_000_000)
        }
        throw WriterFailure.unavailable
    }
    static func seed(_ file:URL,preference:Bool?) async throws {
        let ledger=try PendingNoteScheduler(file:file)
        if let preference {try await ledger.setResumeLocal(preference)}
    }
    static func savedPreference(_ file:URL) async throws -> Bool? {
        let ledger=try PendingNoteScheduler(file:file)
        return await ledger.resumeLocalPreference()
    }
    /// `expect`: "local" when the saved preference says On this Mac was on (it comes back by itself,
    /// offline evidence only, owner decision 2026-09-26), else "off".
    static func launchCold(models:URL,home:URL,expect:String) throws {
        let process=Process()
        process.executableURL=URL(fileURLWithPath:CommandLine.arguments[0])
        process.arguments=["--cold",models.path,home.path,expect]
        try process.run();process.waitUntilExit()
        guard process.terminationStatus==0 else {throw WriterFailure.unavailable}
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.count==5,CommandLine.arguments[1]=="--cold" {
            let keys=NoKeys(),store=try MemoryStore(home:URL(fileURLWithPath:CommandLine.arguments[3]),writable:true,automaticallySyncSearch:false)
            let writer=WriterIntegration(modelRoot:URL(fileURLWithPath:CommandLine.arguments[2]),keyStore:keys,send:{_ in throw WriterFailure.denied})
            writer.configure(store:store);try await waitReady(writer)
            precondition(writer.provider==CommandLine.arguments[4] && !writer.cloudEnabled && !writer.needsAppleCheck)
            let calls=await keys.calls;precondition(calls==0)
            await writer.shutdown()
            print("PASS separate process with existing assets: ready, local \(CommandLine.arguments[4]), cloud OFF, no key access")
            return
        }
        guard CommandLine.arguments.count==3,let plan=WriterCandidates.recommended else {throw WriterFailure.invalidInput}
        let root=URL(fileURLWithPath:"/private/tmp/writer-cold-restart-"+UUID().uuidString,isDirectory:true)
        let fm=FileManager.default
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer{try? fm.removeItem(at:root)}
        let models=root.appendingPathComponent("Models",isDirectory:true)
        try fm.createDirectory(at:models,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        // Reuse existing verified bytes with a COW clone. No model download,
        // inference, global installation, credentials or private history.
        guard clonefile(CommandLine.arguments[1],models.appendingPathComponent(plan.asset.sha256+".model").path,0)==0 else {throw WriterFailure.unavailable}
        _=try CompatibleInstallation.extractRuntime(archive:URL(fileURLWithPath:CommandLine.arguments[2]),root:models)
        let keys=NoKeys()
        for preference in [Optional<Bool>.none,false,true] {
            let home=root.appendingPathComponent(UUID().uuidString)
            let store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
            let at=Date().addingTimeInterval(-150),day=try DayScope.key(at,timezone:"UTC")
            for n in 0..<101 {_=try store.ingest(Evidence(id:"synthetic-\(n)",at:iso(at),kind:"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Synthetic bounded scope",synthetic:true))}
            let queue=home.appendingPathComponent("WriterScheduling",isDirectory:true)
            try fm.createDirectory(at:queue,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            let ledger=queue.appendingPathComponent("pending-v1.json")
            try await seed(ledger,preference:preference)
            let resumes=preference==true
            try launchCold(models:models,home:home,expect:resumes ? "local":"off")
            var writer:WriterIntegration?=WriterIntegration(modelRoot:models,keyStore:keys,send:{_ in throw WriterFailure.denied})
            writer!.configure(store:store);try await waitReady(writer!)
            precondition(writer!.provider==(resumes ? "local":"off") && !writer!.cloudEnabled)
            let initial=try store.dayLayers(day:day,timezone:"UTC")
            precondition(initial.summary.generated==nil)
            print("PASS cold configure with verified assets, preference \(String(describing:preference)): ready, \(resumes ? "back on by itself" : "OFF")")
            fflush(stdout)
            if !resumes {try await writer!.useLocal()};precondition(writer!.provider=="local")
            // 101-action scope intentionally exceeds model batch capacity. It
            // exercises the real queue/binding without loading the model.
            try await Task.sleep(nanoseconds:100_000_000)
            await writer!.disableCloud();precondition(writer!.provider=="off")
            await writer!.shutdown();writer=nil
            let saved=try await savedPreference(ledger);precondition(saved==false)
            try launchCold(models:models,home:home,expect:"off")
            writer=WriterIntegration(modelRoot:models,keyStore:keys,send:{_ in throw WriterFailure.denied})
            writer!.configure(store:store);try await waitReady(writer!)
            precondition(writer!.provider=="off" && !writer!.cloudEnabled)
            await writer!.shutdown();writer=nil
            let layers=try store.dayLayers(day:day,timezone:"UTC")
            precondition(layers.summary.actionCount==101 && layers.summary.generated==nil)
            print("PASS explicit enable then awaited OFF persisted; 101 actions retained without partial note")
        }
        let keyCalls=await keys.calls;precondition(keyCalls==0)
        print("PASS existing pinned model/runtime verified only; no inference, HTTP or Keychain calls")
    }
}
