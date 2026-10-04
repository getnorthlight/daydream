import Foundation
import MemoryCore

@main struct Checks {
    static func main() throws {
        let root=URL(fileURLWithPath:"/private/tmp/daydream-recording-proof-"+UUID().uuidString)
        let store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        let now=Date(),start=now.addingTimeInterval(-10)
        var count=0
        func check(_ passed:Bool,_ name:String) {precondition(passed,name);count+=1}
        check(try RecordingTrialProof.latest(store:store,since:start,now:now)==nil,"empty is not proof")
        var e=Evidence(id:"native-test-1",at:iso(now.addingTimeInterval(-2)),kind:"window.changed",app:"Test app",bundle:"example.trial",title:"Dummy document")
        check(RecordingTrialProof.accepts(e,since:start,now:now),"native observation qualifies")
        e.synthetic=true
        check(!RecordingTrialProof.accepts(e,since:start,now:now),"synthetic native ID rejected")
        e.synthetic=false;e.secure=true
        check(!RecordingTrialProof.accepts(e,since:start,now:now),"secure rejected")
        e.secure=false;e.privateWindow=true
        check(!RecordingTrialProof.accepts(e,since:start,now:now),"private rejected")
        e.privateWindow=false;e.at=iso(start.addingTimeInterval(-5))
        check(!RecordingTrialProof.accepts(e,since:start,now:now),"older history rejected")
        e.at=iso(now.addingTimeInterval(5))
        check(!RecordingTrialProof.accepts(e,since:start,now:now),"future rejected")
        e.at=iso(now.addingTimeInterval(-2));e.id="imported-example"
        check(!RecordingTrialProof.accepts(e,since:start,now:now),"imported ID rejected")
        e.id="native-test-1";e.kind="keyboard.text_input"
        check(!RecordingTrialProof.accepts(e,since:start,now:now),"typing without provenance rejected")
        e.kind="window.changed"
        try store.ingest(e,now:now)
        check(try RecordingTrialProof.latest(store:store,since:start,now:now)?.id==e.id,"pending original works without writer or index")
        let action=try store.action(e.id,now:now)!
        _=try store.correctAction(id:e.id,text:"My correction",expectedRevision:action.revision)
        check(try RecordingTrialProof.latest(store:store,since:start,now:now)?.observedDescription != nil,"observed description survives correction")
        try store.delete(e.id)
        check(try RecordingTrialProof.latest(store:store,since:start,now:now)==nil,"deletion clears proof")
        e.id="native-test-2";try store.ingest(e,now:now)
        var policy=try store.policy();policy.blockedApps.append(e.bundle);try store.updatePolicy(policy,now:now)
        check(try RecordingTrialProof.latest(store:store,since:start,now:now)==nil,"exclusion clears proof")
        print("PASS \(count) synthetic proof checks; disposable fixture: \(root.path). No capture or OS permissions used.")
    }
}
