import Foundation
import Darwin
import MemoryCore
import WriterBackend

actor ForbiddenKeys:WriterSecureKeyStore {
    func readSecret()async throws->String{throw WriterFailure.denied}
    func saveSecret(_ value:String)async throws{throw WriterFailure.denied}
    func removeSecret()async throws{throw WriterFailure.denied}
}
@main struct ControllerModelChecks {
    @MainActor static func settle(_ writer:WriterIntegration)async throws {
        for _ in 0..<1000 {
            if !writer.busy {guard writer.ready else{throw WriterFailure.unavailable};return}
            try await Task.sleep(nanoseconds:20_000_000)
        }
        throw WriterFailure.unavailable
    }
    @MainActor static func main()async throws {
        guard CommandLine.arguments.count==3,let plan=WriterCandidates.recommended else{throw WriterFailure.invalidInput}
        let root=URL(fileURLWithPath:"/private/tmp/writer-controller-model-"+UUID().uuidString)
        let fm=FileManager.default
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer{try? fm.removeItem(at:root)}
        let store=try MemoryStore(home:root.appendingPathComponent("memory"),writable:true,automaticallySyncSearch:false)
        // Same Models path relative to the selected memory home as the app.
        let models=store.home.appendingPathComponent("Models")
        try fm.createDirectory(at:models,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        guard clonefile(CommandLine.arguments[1],models.appendingPathComponent(plan.asset.sha256+".model").path,0)==0 else{throw WriterFailure.unavailable}
        _=try CompatibleInstallation.extractRuntime(archive:URL(fileURLWithPath:CommandLine.arguments[2]),root:models)
        let observed=Date().addingTimeInterval(-150),day=try DayScope.key(observed,timezone:TimeZone.current.identifier)
        let started=Date()
        for n in 0..<3 {_=try store.ingest(Evidence(id:"synthetic-\(n)",at:iso(observed),kind:"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Synthetic Swift activity",synthetic:true))}
        let immediate=try store.actions()
        guard immediate.actions.count==3 else{throw WriterFailure.invalidOutput}
        let freshness=Date().timeIntervalSince(started)
        print("SOURCE_VISIBLE writer=absent count=3 seconds=\(freshness)");fflush(stdout)
        var writer:WriterIntegration?=WriterIntegration(modelRoot:models,keyStore:ForbiddenKeys(),send:{_ in throw WriterFailure.denied})
        writer!.configure(store:store);try await settle(writer!)
        guard writer!.provider=="off",!writer!.cloudEnabled else{throw WriterFailure.denied}
        print("STARTUP verified_assets=1 local=off cloud=off");fflush(stdout)
        let generationStart=Date()
        try await writer!.useLocal()
        var generated=false
        for _ in 0..<900 {
            let layers=try store.dayLayers(day:day,timezone:TimeZone.current.identifier)
            if let note=layers.activities.first?.generated {
                guard note.status=="generated_unverified",Set(note.actionIDs)==Set((0..<3).map{"synthetic-\($0)"}) else{throw WriterFailure.invalidOutput}
                generated=true;break
            }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        await writer!.disableCloud();await writer!.shutdown();writer=nil
        guard generated else{throw WriterFailure.unavailable}
        print("ACTUAL_CONTROLLER generated=1 actions=3 elapsed_seconds=\(Date().timeIntervalSince(generationStart))");fflush(stdout)
        let reopened=try MemoryStore(home:store.home,writable:true,automaticallySyncSearch:false)
        writer=WriterIntegration(modelRoot:models,keyStore:ForbiddenKeys(),send:{_ in throw WriterFailure.denied})
        writer!.configure(store:reopened);try await settle(writer!)
        guard writer!.provider=="off",!writer!.cloudEnabled,try reopened.actions().actions.count==3 else{throw WriterFailure.invalidOutput}
        await writer!.shutdown();writer=nil
        print("PASS controller activation -> real local inference -> core commit -> OFF/reopen, canonical inputs retained. Not the sealed packaged executable.")
    }
}
