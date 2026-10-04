// Compiles the actual app WriterScheduling.swift, not a substitute scheduler.
import Foundation
@testable import MemoryCore
import WriterBackend

@main struct WriterRetentionChecks {
    static var count=0
    static func check(_ value:Bool,_ name:String)throws {
        guard value else {throw MemError.invalid("FAIL: "+name)}
        count += 1;print("PASS: "+name)
    }
    static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("writer-retention-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let now=timestamp("2026-09-14T12:00:00Z")!
        func store(_ name:String)throws->MemoryStore {try MemoryStore(home:root.appendingPathComponent(name),writable:true,automaticallySyncSearch:false)}
        func add(_ s:MemoryStore,_ id:String,_ at:Date,_ title:String="Orchid",_ app:String="com.apple.TextEdit")throws {
            _=try s.ingest(Evidence(id:id,at:iso(at),kind:"window.changed",app:"TextEdit",bundle:app,title:title,synthetic:true),now:now)
        }
        let s=try store("history"),recent=now.addingTimeInterval(-86400),ancient=now.addingTimeInterval(-5000*86400)
        try add(s,"today",now.addingTimeInterval(-180));try add(s,"yesterday",recent);try add(s,"ancient",ancient)
        let first=try await WriterQueueSource(store:s).discover(now:now,timezone:"UTC")
        try check(Set(first.map(\.day)) == Set(["2026-09-14","2026-09-13"]),"actual scheduler returns today and one populated historical day")
        let reopened=try MemoryStore(home:root.appendingPathComponent("history"),writable:true,automaticallySyncSearch:false)
        let second=try await WriterQueueSource(store:reopened).discover(now:now,timezone:"UTC")
        let oldDay=try DayScope.key(ancient,timezone:"UTC")
        // fix/sx-engine-battery: catch-up writes the past 7 days; older history is kept, never written in the background.
        try check(!second.contains{$0.day==oldDay} && (try reopened.action("ancient",now:now)) != nil,"restart: catch-up reaches back 7 days; the 5000-day-old action stays in history")
        try check(second.count<=64 && Set(second.map(\.day)).count<=2,"poll result bounded to 32 targets per day and two days")
        let emptySweep=try await WriterQueueSource(store:reopened).discover(now:now,timezone:"UTC")
        try check(Set(emptySweep.map(\.key))==Set(second.map(\.key)),"discovery is stateless: asking again returns the same moments, no invented day")
        try add(s,"late",now.addingTimeInterval(-2*86400))
        _=try await WriterQueueSource(store:reopened).discover(now:now,timezone:"UTC")
        let late=try await WriterQueueSource(store:reopened).discover(now:now,timezone:"UTC")
        try check(late.contains{$0.day=="2026-09-12"},"late history discovered on next bounded sweep")
        let finite=try s.prepareRetentionChange(.days(30),now:now)
        _=try s.confirmRetentionChange(finite.id,confirmed:true,now:now)
        var seen=Set<String>()
        for _ in 0..<6 {for target in try await WriterQueueSource(store:s).discover(now:now,timezone:"UTC") {seen.insert(target.day)}}
        try check(!seen.contains(oldDay) && seen.contains("2026-09-12"),"finite policy excludes expired history but keeps permitted targets")
        let excluded=try store("excluded")
        var p=try excluded.policy();p.blockedApps=["example.blocked"];try excluded.updatePolicy(p,now:now)
        // Populate under permitted policy first, then exclude. No private source.
        p.blockedApps=[];try excluded.updatePolicy(p,now:now)
        for n in 0..<140 {try add(excluded,"blocked-\(n)",recent.addingTimeInterval(Double(n)),"Blocked","example.blocked")}
        try add(excluded,"visible",ancient)
        p=try excluded.policy();p.blockedApps=["example.blocked"];try excluded.updatePolicy(p,now:now)
        let scan=try excluded.nextWriterDiscoveryWindow(now:now,timezone:"UTC")
        try check(scan.candidatesExamined==128 && scan.scanning && scan.historicalDay==nil,"excluded-only candidate page is bounded with honest continuation")
        try add(excluded,"append",now.addingTimeInterval(-180))
        let exReopen=try MemoryStore(home:root.appendingPathComponent("excluded"),writable:true,automaticallySyncSearch:false)
        let continued=try exReopen.nextWriterDiscoveryWindow(now:now,timezone:"UTC")
        try check(continued.historicalDay==oldDay && continued.candidatesExamined<=128,"restart and concurrent append preserve excluded-page continuation")
        let crowded=try store("crowded")
        for n in 0..<40 {try add(crowded,"distinct-\(n)",recent,"Distinct subject \(n)")}
        let batchA=try await WriterQueueSource(store:crowded).discover(now:now,timezone:"UTC")
        _=try await WriterQueueSource(store:crowded).discover(now:now,timezone:"UTC")
        let batchB=try await WriterQueueSource(store:crowded).discover(now:now,timezone:"UTC")
        try check(Set(batchA.map(\.key))==Set(batchB.map(\.key)) && Set(batchA.map(\.key)).count==40 && batchA.allSatisfy{$0.kind=="activity"},"all 40 moments are found, and no whole-day note")
        let empty=try store("empty")
        try check(try await WriterQueueSource(store:empty).discover(now:now,timezone:"UTC").isEmpty,"empty Never store emits no invented work")
        let dst=try store("dst")
        let dstNow=timestamp("2026-11-02T12:00:00Z")!
        for (id,at) in [("fall-a","2026-11-01T05:30:00Z"),("fall-b","2026-11-01T06:30:00Z")] {
            _=try dst.ingest(Evidence(id:id,at:at,kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:id,synthetic:true),now:dstNow)
        }
        let dstTargets=try await WriterQueueSource(store:dst).discover(now:dstNow,timezone:"America/New_York")
        try check(dstTargets.count==2 && dstTargets.allSatisfy{$0.day=="2026-11-01"},"DST repeated hour retains both activities within the historical local day")
        do {_=try dst.nextWriterDiscoveryWindow(now:dstNow,timezone:"invalid");throw MemError.invalid("FAIL invalid timezone accepted")}
        catch {try check(String(describing:error).contains("Invalid writer timezone"),"invalid timezone fails visibly without a force unwrap")}
        try empty.exec("INSERT OR REPLACE INTO metadata VALUES('writer-discovery-v1','not-json')")
        do {_=try empty.nextWriterDiscoveryWindow(now:now,timezone:"UTC");throw MemError.invalid("FAIL corrupt checkpoint accepted")}
        catch {try check(!String(describing:error).contains("FAIL"),"corrupt checkpoint fails visibly instead of claiming complete")}
        try check(try s.captureStatus()["state"]=="off" && s.policy().captureText==false,"discovery never starts capture or widens typing")
        print("PASS \(count) production writer retention checks; synthetic stores only")
    }
}
