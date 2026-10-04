import Foundation
import WriterBackend

func check(_ value:Bool,line:Int = #line) {precondition(value,"check at line \(line)")}

final class Clock: @unchecked Sendable {
    private let lock=NSLock();private var date=Date(timeIntervalSince1970:1_800_000_000)
    func read()->Date {lock.lock();defer{lock.unlock()};return date}
    func advance(){lock.lock();date=date.addingTimeInterval(60);lock.unlock()}
}
actor FakeKeys: WriterSecureKeyStore {
    var value="";var reads=0;var writes=0;var deletes=0
    func readSecret() async throws -> String {reads+=1;return value}
    func saveSecret(_ input:String) async throws {writes+=1;value=input}
    func removeSecret() async throws {deletes+=1;value=""}
    func counts()->[Int] {[reads,writes,deletes]}
}
actor FakeHTTP {
    var calls=0
    func send(_ request:URLRequest) throws -> CloudHTTPResponse {
        calls+=1
        let json=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        let provider=json["provider"] as! [String:Any]
        precondition(provider["zdr"] as? Bool == true && provider["data_collection"] as? String == "deny")
        precondition(provider["allow_fallbacks"] as? Bool == false && json["model"] as? String == CloudWriter.model)
        let messages=json["messages"] as! [[String:String]]
        precondition(messages[0]["content"]==CanonicalGrounding.instruction && messages[1]["content"]=="NOTE: moment\nITEMS:\ni1. Notes: other activity","cloud sees the prompt4 instruction and the ITEMS view, never raw actions")
        // A prompt4 answer: item ids and text only; code derives labels and real action IDs.
        let content=#"{"title":"Draft in Notes","bullets":[{"ids":["i1"],"text":"Kept a draft in Notes."}]}"#
        return CloudHTTPResponse(status:200,body:try JSONSerialization.data(withJSONObject:["model":CloudWriter.model,"choices":[["message":["content":content]]]]))
    }
    func count()->Int {calls}
}
@main struct CloudActivationChecks {
    static func rejected(_ operation:()async throws->Void) async {
        do {try await operation();fatalError("expected denial")}catch{}
    }
    static func main() async throws {
        let clock=Clock(),keys=FakeKeys(),http=FakeHTTP()
        let activation=CloudActivation(store:keys,now:{clock.read()})
        let before=clock.read()
        func request(at:Date,policy:String="p1") throws -> CanonicalNoteRequest {
            let action:[String:String]=["id":"a","at":ISO8601DateFormatter().string(from:at),"kind":"typing","app":"Notes","site":"","title":"Draft","description":"Edited a draft","state":"draft","revision":"1"]
            let json:[String:Any]=["id":"req","schemaVersion":1,"targetKind":"activity","targetID":"act","day":"2026-09-11","timezone":"UTC","inputRevision":"1","policyRevision":policy,"expiresAt":"2099-01-01T00:00:00Z","actions":[action],"actionCount":1]
            return try JSONDecoder().decode(CanonicalNoteRequest.self,from:JSONSerialization.data(withJSONObject:json))
        }
        func writer(_ binding:CloudActivationBindings)->CanonicalCloudWriter {
            CanonicalCloudWriter(consent:binding.consent,key:binding.key,policy:binding.permits,send:{try await http.send($0)})
        }
        let oldRequest=try request(at:before)
        let disabled=await activation.bindings()
        await rejected {_ = try await writer(disabled).generate(oldRequest,completeActions:oldRequest.actions)}
        check(await keys.counts()==[0,0,0]);check(await http.count()==0)
        try await activation.pasteKey("synthetic-only-key")
        check(await activation.consent().enabled == false)
        await rejected {try await activation.enable(acceptedDisclosureVersion:0,currentPolicyRevision:"p1")}
        // summaries/v3 (K7): the v1 notice said cloud never gets the words; accepting it no longer turns cloud on.
        await rejected {try await activation.enable(acceptedDisclosureVersion:1,currentPolicyRevision:"p1")}
        let v1Enabled=await activation.consent().enabled
        // fix/sx-all round 1: the v2 notice didn't name page titles; accepting it no longer turns cloud on either.
        await rejected {try await activation.enable(acceptedDisclosureVersion:2,currentPolicyRevision:"p1")}
        let v2Enabled=await activation.consent().enabled
        check(!v1Enabled && !v2Enabled && CloudActivation.disclosureVersion == 3)
        try await activation.enable(acceptedDisclosureVersion:3,currentPolicyRevision:"p1")
        let enabled=await activation.bindings()
        await rejected {_ = try await writer(enabled).generate(oldRequest,completeActions:oldRequest.actions)}
        check(await keys.counts()==[0,1,0]);check(await http.count()==0)
        clock.advance();let current=try request(at:clock.read())
        let note=try await writer(enabled).generate(current,completeActions:current.actions)
        check(note.generatorVersion==CanonicalGrounding.cloudVersion && note.bullets.map(\.actionIDs)==[["a"]] && note.bullets[0].assertion=="draft")
        _ = try await writer(enabled).generate(current,completeActions:current.actions)
        check(await http.count()==2)
        // fix/sx-engine-battery: no 100-action cloud limit (cloud is as capable as this Mac's model); the core decides.
        func many(_ plain:Int,markers:Int) throws -> CanonicalNoteRequest {
            let at=ISO8601DateFormatter().string(from:clock.read())
            let kinds=Array(repeating:"keyboard.text_input",count:plain)+Array(repeating:"keyboard.submit",count:markers)
            let actions=kinds.enumerated().map {i,kind in ["id":"m\(i)","at":at,"kind":kind,"app":"Notes","site":"","title":"Draft","description":"Edited a draft","state":"draft","revision":"1"]}
            let json:[String:Any]=["id":"req-many","schemaVersion":1,"targetKind":"activity","targetID":"act","day":"2026-09-11","timezone":"UTC","inputRevision":"1","policyRevision":"p1","expiresAt":"2099-01-01T00:00:00Z","actions":actions,"actionCount":actions.count]
            return try JSONDecoder().decode(CanonicalNoteRequest.self,from:JSONSerialization.data(withJSONObject:json))
        }
        let withMarkers=try many(100,markers:30),overLimit=try many(101,markers:0)
        let markersFit=await enabled.permits(withMarkers,withMarkers.actions),overFits=await enabled.permits(overLimit,overLimit.actions)
        check(markersFit && overFits)
        let wrongPolicy=try request(at:clock.read(),policy:"p2")
        let beforePolicyReads=await keys.counts()
        await rejected {_ = try await writer(enabled).generate(wrongPolicy,completeActions:wrongPolicy.actions)}
        check(await keys.counts()==beforePolicyReads)
        await activation.policyChanged()
        await rejected {_ = try await writer(enabled).generate(current,completeActions:current.actions)}
        check(await http.count()==2)
        try await activation.enable(acceptedDisclosureVersion:3,currentPolicyRevision:"p2")
        let rebound=await activation.bindings()
        await rejected {_ = try await writer(rebound).generate(wrongPolicy,completeActions:wrongPolicy.actions)}
        clock.advance();let fresh=try request(at:clock.read(),policy:"p2")
        let racing=CanonicalCloudWriter(consent:rebound.consent,key:rebound.key,policy:rebound.permits,send:{req in
            await activation.disable();return try await http.send(req)
        })
        await rejected {_ = try await racing.generate(fresh,completeActions:fresh.actions)}
        check(await http.count()==3)
        try await activation.deleteKey()
        let final=await keys.counts();precondition(final[2]==1)
        check(await activation.consent().enabled == false)
        print("PASS fake-only cloud: paste-not-enable, disclosure, no historical backfill before key/network, repeated ZDR requests, policy/generation invalidation, disable during response, delete-key")
    }
}
