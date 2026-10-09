// Headless synthetic search checks: the direct preview shown while ranked search runs, its reconciliation with the
// ranked page, and (what was search-progressive-layout) the result list's geometry staying put when the ranked page
// lands. No windows, permissions, capture or owner data.
import Foundation
@testable import MemoryCore
@testable import MemoryUI

@main enum ProgressiveSearchChecks {
    /// Each scenario is one flow whose steps build on each other, so a failed step ends its scenario; the other still runs.
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        var failed = 0
        do { try await run(); print("PASS progressive search fixture") } catch { failed += 1; print("FAIL progressive search: \(error)") }
        do { try await layout(); print("PASS stable-layout fixture; synthetic model geometry only") } catch { failed += 1; print("FAIL stable layout: \(error)") }
        if failed > 0 { exit(1) }
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
    // Independent geometry from the result list's fixed layout contract:
    // 6pt top inset, 24pt section heading, 4pt between sections, 48pt rows.
    @MainActor static func top(_ model:RecallModel,_ id:String) -> Double? {
        var y=6.0
        for (i,section) in model.sections.enumerated() {
            y += (i==0 ? 0 : 4)+24
            for row in section.rows {if row.id==id {return y};y+=48}
        }
        return nil
    }
    @MainActor static func structure(_ model:RecallModel) -> [String] {model.sections.map {$0.id+"|"+$0.title}}
    /// What was search-progressive-layout: the chosen row keeps its place when ranked results replace the preview.
    @MainActor static func layout() async throws {
        let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("dd-search-layout-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false),now=Date()
        for (n,id) in ["a","b","c","d"].enumerated() {
            _=try store.ingest(Evidence(id:id,at:iso(now.addingTimeInterval(-Double(120+n*60))),kind:"window.changed",app:"Notes",bundle:"fiction.Notes",title:"Cedar planning \(id)",synthetic:true),now:now)
        }
        func items(_ ids:[String]) throws -> [MemoryItem] {try ids.compactMap {try store.searchActionItem($0,now:now)}}
        let a=try items(["a"])[0],b=try items(["b"])[0],c=try items(["c"])[0],d=try items(["d"])[0]
        let browser=ActivityBrowser(),model=browser.recallModel;browser.now={now}
        var pending:CheckedContinuation<MemorySearchResult,Error>?
        browser.searchCanonicalQuery={ q in
            if q.after != nil {return MemorySearchResult(items:[c,d],backend:"sqlite",status:"sqlite_continuation",partial:false)}
            return try await withCheckedThrowingContinuation {pending=$0}
        }
        browser.searchDirectPreview={_ in MemorySearchResult(items:[a,b],backend:"sqlite",status:"direct_preview",partial:true)}
        browser.reconcileSearchPreview={q,ids,page in try store.reconcileDirectPreview(q,ids:ids,with:page,now:now)}
        browser.query="cedar";model.load(immediate:true)
        try await until {pending != nil && model.items.count==2}
        model.select("action:b")
        let before=structure(model),beforeTop=top(model,"action:b")
        try check(beforeTop==78,"chosen second direct row starts at independently calculated 78pt")
        try check(model.sections.allSatisfy {!$0.best},"provisional direct matches never claim Best match")
        pending?.resume(returning:MemorySearchResult(items:[a,c,b],backend:"typesense",status:"ready",partial:false));pending=nil
        try await until {!model.busy}
        print("GEOMETRY chosen-row top: before=\(beforeTop ?? -1) after=\(top(model,"action:b") ?? -1)")
        try check(structure(model)==before,"section IDs and headings do not change when final ranked results arrive")
        try check(top(model,"action:b")==beforeTop,"chosen row content position stays fixed; no 28pt header insertion")
        try check(model.selectedRowID=="action:b","chosen direct anchor remains selected")
        try check(model.items.map(\.id)==["a","b","c"],"new valid final hit is shown with canonical ranking unchanged")
        try check(model.hasMore,"canonical reconciliation still offers complete-history continuation")
        model.searchMore();try await until {!model.busy}
        try check(model.items.map(\.id)==["a","b","c","d"],"continuation adds the new valid hit and dedupes its repeated match")
        try check(structure(model)==before && top(model,"action:b")==beforeTop,"paging preserves the chosen row's section structure and content position")
        // A fresh query with no direct matches keeps the existing one-stage
        // ranked presentation; layout state must not leak from the previous query.
        browser.searchDirectPreview={_ in MemorySearchResult(items:[],backend:"sqlite",status:"direct_preview",partial:true)}
        browser.query="cedar planning";model.load(immediate:true)
        try await until {pending != nil}
        pending?.resume(returning:MemorySearchResult(items:[a,b],backend:"typesense",status:"ready",partial:false));pending=nil
        try await until {!model.busy}
        try check(model.sections.first?.best==true,"a new query without a direct preview retains genuine ranked Best match presentation")
        // Metadata from the original preview is intentionally made stale. The
        // existing canonical reconciler must still remove the deleted row.
        browser.searchDirectPreview={_ in MemorySearchResult(items:[a,b],backend:"sqlite",status:"direct_preview",partial:true)}
        browser.query="CEDAR";model.load(immediate:true)
        try await until {pending != nil && model.result?.status=="direct_preview"}
        model.select("action:b");try store.delete("b")
        pending?.resume(returning:MemorySearchResult(items:[b,a],backend:"typesense",status:"ready",partial:false));pending=nil
        try await until {!model.busy}
        try check(model.items.map(\.id)==["a"] && model.selectedRowID==nil,"keeping layout never retains a deleted chosen row or stale selection")
        try check(model.sections.allSatisfy {!$0.best},"deletion does not reintroduce a late Best match header")
        _=try store.savePreferences(MemoryPreferences(blockedApps:["fiction.Notes"],nativeTyping:false),expectedRevision:try store.policy().revision)
        browser.searchDirectPreview={q in try store.directSearchPreview(q,now:now)}
        browser.searchCanonicalQuery={q in try store.directSearchPreview(q,now:now)}
        model.memoryChanged()
        try check(model.items.isEmpty && model.displayRows.isEmpty,"privacy invalidation clears all results immediately despite stable-section state")
        try await until {!model.busy}
        try check(model.items.isEmpty,"excluded rows stay absent after the new final response")
        model.disappeared()
    }
}
