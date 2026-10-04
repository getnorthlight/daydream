import Foundation
import MemoryCore

@main struct AuditChecks {
    static var count=0
    static func check(_ test:@autoclosure () throws -> Bool,_ label:String) throws {
        guard try test() else { throw MemError.invalid("FAIL: "+label) }
        count += 1; print("PASS: "+label)
    }
    static func rejects(_ label:String,_ body:() throws -> Void) throws {
        do { try body() } catch { count += 1; print("PASS: "+label); return }
        throw MemError.invalid("FAIL: "+label)
    }
    static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("macmem-audit-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let now=timestamp("2026-09-11T20:00:00Z")!, day="2026-09-11"
        let store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        func e(_ id:String,_ offset:Double,_ title:String="Research project",_ site:String="one.example",_ app:String="Safari") -> Evidence {
            Evidence(id:id,at:iso(now.addingTimeInterval(offset)),kind:"browser.tab_visited",app:app,bundle:app,title:title,url:site.isEmpty ? "" : "https://"+site+"/",synthetic:true)
        }
        for event in [e("morning",-36000),e("a",-100),e("unrelated",-50,"Research project","two.example"),e("interrupt",-80,"Build status","","Terminal"),e("desktop",-70,"Research project","","TextEdit"),e("revisit",-60)] { _=try store.ingest(event,now:now) }
        let layers=try store.dayLayers(day:day,timezone:"UTC",now:now)
        try check(layers.activities.count == 4,"same title unrelated sites and morning session stay separate")
        let research=layers.activities.first{$0.actionIDs.contains("a")}!
        try check(research.actionIDs == ["a","desktop","revisit"],"cross-app related research survives brief interruption")
        try check(layers.actions.actions.count == 6,"every brief action retained")
        let page=try store.actions(limit:2,now:now)
        _=try store.ingest(e("late-append",-95),now:now)
        let reader=try MemoryStore(home:root)
        var ids=page.actions.map(\.id), cursor=page.next
        while let next=cursor {
            let nextPage=try reader.actions(after:next,limit:2,now:now)
            ids += nextPage.actions.map(\.id); cursor=nextPage.next
            _=try store.ingest(e("concurrent-"+UUID().uuidString,-10),now:now)
        }
        try check(Set(ids).count == 6 && !ids.contains("late-append"),"reload plus continuous append cannot starve or contaminate snapshot")
        try store.delete("unrelated")
        try rejects("deletion invalidates pre-deletion cursor") { _=try reader.actions(after:page.next,now:now) }
        let busy=try MemoryStore(home:root.appendingPathComponent("dense"),writable:true,automaticallySyncSearch:false)
        let begin=DispatchTime.now().uptimeNanoseconds
        for i in 0..<5105 { _=try busy.ingest(e(String(format:"dense-%05d",i),Double(i)-6000,"Routine page"),now:now) }
        _=try busy.ingest(e("old-needle",-7000,"Rare authorized subject"),now:now)
        _=try busy.ingest(e("quick",-9,"Brief quick visit","quick.example","QuickApp"),now:now)
        for i in 0..<55 { _=try busy.ingest(e("recent-\(i)",-Double(i)/10,"Dense recent"),now:now) }
        let denseDay=try busy.dayLayers(day:day,timezone:"UTC",limit:200,now:now)
        // gold/notes G24: a day over 5000 actions is assembled whole (its newest actions included), not cut off as partial.
        try check(!denseDay.partial && denseDay.summary.countIsComplete && denseDay.summary.actionCount == 5162 && denseDay.activities.contains(where:{$0.actionIDs.contains("recent-0")}),"a day over 5000 actions is assembled whole, newest actions included")
        var actionCount=0, after:String?
        repeat { let p=try busy.actions(after:after,limit:200,now:now); actionCount += p.actions.count; after=p.next } while after != nil
        try check(actionCount == 5162,"all actions beyond day assembly cap remain accessible")
        let context=try busy.currentActions(now:now)
        try check(context.actions.count == 10 && context.truncated && context.continuation != nil,"dense recent context exposes truncation and continuation")
        var recentIDs=context.actions.map(\.id), continuation=context.continuation
        while let token=continuation { let p=try busy.currentActions(now:now,after:token); recentIDs += p.actions.map(\.id); continuation=p.continuation }
        try check(recentIDs.count == 56 && Set(recentIDs).count == 56 && recentIDs.contains("quick"),"current-context pages retain every quick visit without duplicates")
        let bounded=try busy.context(now:now)
        try check(bounded.truncated && bounded.text.utf8.count <= 1200 && bounded.continuationResource == "macmem://current-context","before-turn byte limit truthfully exposes further evidence")
        let quick=try busy.searchResult(MemorySearchQuery("Brief quick",app:"QuickApp",start:now.addingTimeInterval(-10),end:now.addingTimeInterval(1),site:"quick.example"),now:now)
        try check(quick.items.map(\.id) == ["quick"],"scoped last-ten-second search bypasses current-context budget without index")
        var searchAfter:String?, hits=[String](), pages=0
        repeat {
            let result=try busy.searchResult(MemorySearchQuery("Rare authorized",site:"one.example",after:searchAfter),now:now)
            hits += result.items.map(\.id); searchAfter=result.next; pages += 1
            try check(pages <= 100,"bounded search makes forward progress")
        } while searchAfter != nil
        // gold/int: connections-storage G27 lets search without the index reach the month, so the old needle may come in
        // the first page now; it must still come exactly once, and the continuation must end.
        try check(hits == ["old-needle"] && pages >= 1,"authorized old description beyond newest 1000 is searchable (first page or by continuation)")
        let filtered=try busy.searchResult(MemorySearchQuery("Rare authorized",app:"WrongApp",site:"one.example"),now:now)
        try check(filtered.items.isEmpty && filtered.next == nil,"app filter applied before candidate budget")
        // gold/int: connections-storage (G27, critic extra 4) made a search continuation a position read live (time, id and
        // a rowid fence) instead of a snapshot cursor a deletion invalidates. So a continuation still works after a
        // deletion, and it never returns what was deleted.
        let firstSearch=try busy.searchResult(MemorySearchQuery("Routine page"),now:now)
        let nextID=String(format:"dense-%05d",5104-firstSearch.items.count)
        try check(firstSearch.next != nil && !firstSearch.items.isEmpty && !firstSearch.items.contains{$0.id == nextID},"a search with more hits than a page holds has a continuation")
        try busy.delete(nextID)
        try busy.delete("old-needle")
        let continued=try busy.searchResult(MemorySearchQuery("Routine page",after:firstSearch.next),now:now)
        try check(continued.items.first?.id == String(format:"dense-%05d",5103-firstSearch.items.count) && !continued.items.contains{$0.id == nextID},
                  "a search continuation read after a deletion goes on where it stopped and never returns the deleted source")
        try check(try busy.action("old-needle",now:now) == nil,"deleted source cannot be reopened")
        print(String(format:"MEASURE 5162-source dense audit: %.2f seconds",Double(DispatchTime.now().uptimeNanoseconds-begin)/1_000_000_000))
        print("Audit checks: \(count) passed. Synthetic only.")
    }
}
