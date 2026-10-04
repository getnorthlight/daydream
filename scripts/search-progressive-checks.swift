// Headless synthetic search checks. No windows, permissions, capture or owner data.
import Foundation
@testable import MemoryCore
@testable import MemoryUI

@main enum ProgressiveSearchChecks {
    @MainActor static func main() async {
        do { try await run(); print("PASS progressive search fixture") }
        catch { print("FAIL \(error)"); exit(1) }
    }
    static func check(_ condition:Bool,_ name:String) throws {
        guard condition else { throw MemError.invalid(name) }; print("PASS \(name)")
    }
    @MainActor static func until(_ condition:() -> Bool) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(nanoseconds:1_000_000) }
        throw MemError.invalid("fixture did not reach expected state")
    }
    @MainActor static func run() async throws {
        let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("dd-progressive-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let now=Date(),store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        func seed(_ id:String,_ title:String,_ age:Double,_ bundle:String="fiction.Notes",_ body:String="") throws {
            _=try store.ingest(Evidence(id:id,at:iso(now.addingTimeInterval(-age)),kind:body.isEmpty ? "window.changed" : "keyboard.text_input",app:"Notes",bundle:bundle,title:title,url:"https://fiction.example/",text:body,synthetic:true),now:now)
        }
        try seed("exact","Cedar maple",90); try seed("prefix","Cedarwood maple",100)
        try seed("fuzzy","Cedar mple",40); try seed("secret","password: cedarsecret",60)
        try seed("body","",50,"fiction.Notes","cedarbodyword")
        let q=MemorySearchQuery("cedar maple",limit:50),preview=try store.directSearchPreview(q,now:now)
        try check(!preview.items.isEmpty && preview.items.allSatisfy { ["exact","prefix"].contains($0.id) },"direct preview contains exact canonical matches only, newest first")
        try check(preview.partial && preview.next==nil && preview.backend=="sqlite","preview never claims final coverage or exposes a premature paging cursor")
        try check(try store.directSearchPreview(MemorySearchQuery("cedarsecret"),now:now).items.isEmpty,"secret filter remains intact")
        try check(try store.directSearchPreview(MemorySearchQuery("cedarbodyword"),now:now).items.isEmpty,"preview never searches captured typed bodies")
        try check(try store.directSearchPreview(MemorySearchQuery("cedar maple",site:"other.example"),now:now).items.isEmpty,"site filter applies before display")
        let a=try store.searchActionItem("exact",now:now)!,b=try store.searchActionItem("prefix",now:now)!
        let reconciled=try store.reconcileDirectPreview(q,ids:["exact","exact","secret"],with:MemorySearchResult(items:[b,b],backend:"typesense",status:"ready",partial:false),now:now)
        try check(reconciled.items.map(\.id)==["exact","prefix"] && reconciled.next != nil,"fresh direct matches enrich ranked hits, dedupe, and preserve canonical continuation")
        let small=MemorySearchQuery("cedar maple",limit:1)
        let limited=try store.reconcileDirectPreview(small,ids:["exact"],with:MemorySearchResult(items:[b],backend:"typesense",status:"ready",partial:false),now:now)
        let continued=try store.searchResult(MemorySearchQuery("cedar maple",limit:1,after:limited.next),now:now)
        try check(limited.items.map(\.id)==["exact"] && continued.items.map(\.id)==["prefix"],"a direct hit displacing an index hit never loses that index hit from later pages")
        try store.delete("exact")
        let afterDelete=try store.reconcileDirectPreview(q,ids:["exact"],with:MemorySearchResult(items:[b],backend:"typesense",status:"ready",partial:false),now:now)
        try check(afterDelete.items.map(\.id)==["prefix"],"deletion between preview and final reconciliation cannot resurrect a hit")
        _=try store.ingest(Evidence(id:"url-only",at:iso(now.addingTimeInterval(-600)),kind:"window.changed",app:"Chrome",bundle:"fiction.Chrome",title:"",url:"https://www.google.com/search?q=cedar%20maple",synthetic:true),now:now)
        let localOnly=try store.reconcileDirectPreview(q,ids:["url-only"],with:MemorySearchResult(items:[],backend:"typesense",status:"ready",partial:true),now:now)
        try check(localOnly.items.map(\.id)==["url-only"],"older permitted URL-query observation survives a Typesense page that cannot index its words")
        let browser=ActivityBrowser(),model=browser.recallModel
        var reconciliations=0
        browser.reconcileSearchPreview={ _,_,page in reconciliations+=1; return page }
        var ranked:[String:CheckedContinuation<MemorySearchResult,Error>]=[:]
        browser.searchCanonicalQuery={ query in try await withCheckedThrowingContinuation { ranked[query.text]=$0 } }
        browser.searchDirectPreview={ _ in MemorySearchResult(items:[a,a],backend:"sqlite",status:"direct_preview",partial:true) }
        browser.query="cedar";model.load(immediate:true)
        try await until { ranked["cedar"] != nil && model.items.count==1 }
        try check(model.busy && model.items.map(\.id)==["exact"],"real direct match is usable while ranked search is still blocked; preview IDs dedupe")
        try check(model.footerText=="Finding more matches…","populated preview keeps a restrained loading state")
        model.select("action:exact")
        ranked.removeValue(forKey:"cedar")?.resume(returning:MemorySearchResult(items:[b,a,a],backend:"typesense",status:"ready",partial:false))
        try await until { !model.busy }
        try check(model.items.map(\.id)==["prefix","exact"],"final canonical ranking replaces preview and duplicate IDs appear once")
        try check(model.selectedRowID=="action:exact","selection stays on the chosen direct match when ranked results arrive")
        try check(reconciliations==1,"Recall invokes canonical reconciliation before showing the final ranked page")
        var oldPreview:CheckedContinuation<MemorySearchResult,Never>?
        browser.searchDirectPreview={ query in
            if query.text=="old" { return await withCheckedContinuation { oldPreview=$0 } }
            return MemorySearchResult(items:[b],backend:"sqlite",status:"direct_preview",partial:true)
        }
        browser.query="old";model.load(immediate:true)
        try await until { oldPreview != nil && ranked["old"] != nil }
        browser.query="new";model.load(immediate:true)
        try await until { ranked["new"] != nil && model.searchedText=="new" }
        ranked.removeValue(forKey:"new")?.resume(returning:MemorySearchResult(items:[b],backend:"typesense",status:"ready",partial:false))
        try await until { !model.busy }
        oldPreview?.resume(returning:MemorySearchResult(items:[a],backend:"sqlite",status:"direct_preview",partial:true))
        ranked.removeValue(forKey:"old")?.resume(returning:MemorySearchResult(items:[a],backend:"typesense",status:"ready",partial:false))
        for _ in 0..<20 { await Task.yield() }
        try check(model.searchedText=="new" && model.items.map(\.id)==["prefix"],"superseded preview and ranked completion cannot replace a newer query")
        try store.delete("url-only")
        _=try store.savePreferences(MemoryPreferences(blockedApps:["fiction.Notes"],nativeTyping:false),expectedRevision:try store.policy().revision)
        try check(try store.directSearchPreview(q,now:now).items.isEmpty,"fresh privacy revision immediately removes direct matches")
        browser.searchDirectPreview={ _ in try store.directSearchPreview(q,now:now) }
        browser.reconcileSearchPreview={ query,ids,page in try store.reconcileDirectPreview(query,ids:ids,with:page,now:now) }
        model.memoryChanged()
        try check(model.items.isEmpty && model.displayRows.isEmpty,"privacy invalidation clears visible provisional and final rows immediately")
        try await until { ranked["new"] != nil }
        ranked.removeValue(forKey:"new")?.resume(returning:MemorySearchResult(items:[],backend:"typesense",status:"ready",partial:false))
        try await until { !model.busy }
        try check(model.items.isEmpty,"ranked empty result never resurrects a previously visible preview")
        model.disappeared()
    }
}
