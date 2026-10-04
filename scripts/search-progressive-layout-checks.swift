// Headless synthetic geometry: no windows, permissions, hooks or owner history.
import Foundation
@testable import MemoryCore
@testable import MemoryUI

@main enum ProgressiveLayoutChecks {
    static var assertions=0
    static func check(_ value:Bool,_ name:String) throws {
        guard value else {throw MemError.invalid(name)};assertions+=1;print("PASS "+name)
    }
    @MainActor static func wait(_ condition:() -> Bool) async throws {
        for _ in 0..<2000 {if condition() {return};try await Task.sleep(nanoseconds:1_000_000)}
        throw MemError.invalid("Fixture failed to reach expected state")
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
    @MainActor static func run() async throws {
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
        try await wait {pending != nil && model.items.count==2}
        model.select("action:b")
        let before=structure(model),beforeTop=top(model,"action:b")
        try check(beforeTop==78,"chosen second direct row starts at independently calculated 78pt")
        try check(model.sections.allSatisfy {!$0.best},"provisional direct matches never claim Best match")
        pending?.resume(returning:MemorySearchResult(items:[a,c,b],backend:"typesense",status:"ready",partial:false));pending=nil
        try await wait {!model.busy}
        print("GEOMETRY chosen-row top: before=\(beforeTop ?? -1) after=\(top(model,"action:b") ?? -1)")
        try check(structure(model)==before,"section IDs and headings do not change when final ranked results arrive")
        try check(top(model,"action:b")==beforeTop,"chosen row content position stays fixed; no 28pt header insertion")
        try check(model.selectedRowID=="action:b","chosen direct anchor remains selected")
        try check(model.items.map(\.id)==["a","b","c"],"new valid final hit is shown with canonical ranking unchanged")
        try check(model.hasMore,"canonical reconciliation still offers complete-history continuation")
        model.searchMore();try await wait {!model.busy}
        try check(model.items.map(\.id)==["a","b","c","d"],"continuation adds the new valid hit and dedupes its repeated match")
        try check(structure(model)==before && top(model,"action:b")==beforeTop,"paging preserves the chosen row's section structure and content position")
        // A fresh query with no direct matches keeps the existing one-stage
        // ranked presentation; layout state must not leak from the previous query.
        browser.searchDirectPreview={_ in MemorySearchResult(items:[],backend:"sqlite",status:"direct_preview",partial:true)}
        browser.query="cedar planning";model.load(immediate:true)
        try await wait {pending != nil}
        pending?.resume(returning:MemorySearchResult(items:[a,b],backend:"typesense",status:"ready",partial:false));pending=nil
        try await wait {!model.busy}
        try check(model.sections.first?.best==true,"a new query without a direct preview retains genuine ranked Best match presentation")
        // Metadata from the original preview is intentionally made stale. The
        // existing canonical reconciler must still remove the deleted row.
        browser.searchDirectPreview={_ in MemorySearchResult(items:[a,b],backend:"sqlite",status:"direct_preview",partial:true)}
        browser.query="CEDAR";model.load(immediate:true)
        try await wait {pending != nil && model.result?.status=="direct_preview"}
        model.select("action:b");try store.delete("b")
        pending?.resume(returning:MemorySearchResult(items:[b,a],backend:"typesense",status:"ready",partial:false));pending=nil
        try await wait {!model.busy}
        try check(model.items.map(\.id)==["a"] && model.selectedRowID==nil,"keeping layout never retains a deleted chosen row or stale selection")
        try check(model.sections.allSatisfy {!$0.best},"deletion does not reintroduce a late Best match header")
        _=try store.savePreferences(MemoryPreferences(blockedApps:["fiction.Notes"],nativeTyping:false),expectedRevision:try store.policy().revision)
        browser.searchDirectPreview={q in try store.directSearchPreview(q,now:now)}
        browser.searchCanonicalQuery={q in try store.directSearchPreview(q,now:now)}
        model.memoryChanged()
        try check(model.items.isEmpty && model.displayRows.isEmpty,"privacy invalidation clears all results immediately despite stable-section state")
        try await wait {!model.busy}
        try check(model.items.isEmpty,"excluded rows stay absent after the new final response")
        model.disappeared()
        print("PASS \(assertions) stable-layout checks; synthetic model geometry only")
    }
    @MainActor static func main() async {
        do {try await run()} catch {print("FAIL \(error)");exit(1)}
    }
}
