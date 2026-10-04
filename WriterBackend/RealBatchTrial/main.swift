import Foundation
import MemoryCore
import WriterBackend

@main struct RealBatchTrial {
    static func main()async throws {
        guard CommandLine.arguments.count==3 else {throw WriterFailure.invalidInput}
        let validationStart=Date()
        let files=try CompatibleInstallation.validate(model:URL(fileURLWithPath:CommandLine.arguments[1]),runtimeDirectory:URL(fileURLWithPath:CommandLine.arguments[2]))
        print("VERIFIED_ARTIFACTS seconds=\(Date().timeIntervalSince(validationStart))");fflush(stdout)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("writer-real-batch-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false),now=Date(),zone="UTC"
        for n in 0..<21 {
            _=try store.ingest(Evidence(id:"synthetic-\(n)",at:iso(now.addingTimeInterval(Double(n)/1000)),kind:"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Synthetic research activity",synthetic:true))
        }
        let day=try DayScope.key(now,timezone:zone),layers=try store.dayLayers(day:day,timezone:zone)
        guard layers.activities.count==1,layers.activities[0].actionIDs.count==21 else {throw WriterFailure.invalidInput}
        let runtime=LlamaInference(files:files),binding=CoreWriterBinding(store:store),port=binding.port()
        let provider=CanonicalLocalWriter(runtime:runtime,policy:port.permitted)
        // prompt4: one call for the whole activity (21 clicks fold into one item), then one repair turn at most.
        let adapter=CoreWriterAdapter(core:port,generate:{request,actions in
            let begin=Date()
            do {
                let result=try await provider.generate(request,completeActions:actions)
                let offload=await runtime.offloadEvidence()
                print("NOTE count=\(actions.count) seconds=\(Date().timeIntervalSince(begin)) offload=\(offload.layers)/\(offload.total) valid=1 version=\(result.generatorVersion)");fflush(stdout)
                return result
            } catch {
                let offload=await runtime.offloadEvidence()
                print("NOTE count=\(actions.count) seconds=\(Date().timeIntervalSince(begin)) offload=\(offload.layers)/\(offload.total) valid=0");fflush(stdout)
                throw error
            }
        })
        let started=Date()
        let result=try await adapter.process(WriterTarget(kind:.activity,day:day,timezone:zone,activityID:layers.activities[0].id),lastActivity:now.addingTimeInterval(-3))
        switch result {
        case .committed(let receipt):
            let ids=receipt.output.bullets.flatMap(\.actionIDs)
            guard Set(ids)==Set((0..<21).map{"synthetic-\($0)"}),ids.count==21 else {throw WriterFailure.invalidOutput}
            print("REAL_BATCH result=committed status=\(receipt.status) actions=21 bullets=\(receipt.output.bullets.count) seconds=\(Date().timeIntervalSince(started))")
        case .pending(let note):
            guard note.actionIDs.count==21 else {throw WriterFailure.invalidOutput}
            print("REAL_BATCH result=pending reason=\(note.reason.rawValue) retained_actions=21 seconds=\(Date().timeIntervalSince(started))")
        }
        let after=try store.dayLayers(day:day,timezone:zone)
        print("CORE action_count=\(after.summary.actionCount) generated_activity=\(after.activities[0].generated != nil)")
    }
}
