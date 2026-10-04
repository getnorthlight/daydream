// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
// claude/catchup-1003: the direct scan (no index) reaches 30 days in one call through a night of terminal spinner title
// churn, title rows stay findable, accents still fold, "Texts" finds Messages, and a moved history folder's own index
// binding is recognized. Fictional rows only, in a scratch folder.
import Foundation
@testable import MemoryCore
var scratchRoot=URL(fileURLWithPath:"/nonexistent")
@main struct SearchFallbackCoverageChecks {
    static var passes=0,failures=0
    static func check(_ value:Bool,_ name:String,_ detail:@autoclosure ()->String="") {
        if value {passes+=1;print("PASS "+name)} else {failures+=1;print("FAIL "+name+": "+detail())}
    }
    static func insert(_ store:MemoryStore,_ records:[Evidence])throws {
        try store.transaction {for e in records {try store.exec("INSERT INTO records VALUES(?,?,?)",[e.id,try json(e),fingerprint(try json(e))])}}
    }
    static func main() {
        setbuf(stdout,nil)
        let base=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TMPDIR"] ?? "/private/tmp")
        scratchRoot=base.appendingPathComponent("daydream-search-fallback-coverage-"+UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at:scratchRoot,withIntermediateDirectories:true)
            try coverage(scratchRoot.appendingPathComponent("month"))
            moved()
        } catch {check(false,"fixture completed without unexpected error",String(describing:error))}
        print("\(passes) search fallback coverage checks passed, \(failures) failed. Fictional histories only.")
        try? FileManager.default.removeItem(at:scratchRoot)
        exit(failures==0 ? 0 : 1)
    }
    static func coverage(_ home:URL) throws {
        let store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
        let now=Date()
        func at(_ secondsAgo:Double)->String {iso(now.addingTimeInterval(-secondsAgo))}
        var rows=[Evidence]()
        // A month of ordinary use, then three evenings of Claude Code in Ghostty: its title glyph ticks every 1.5 s and
        // each tick is a row (the audit's 10/02 night: 7,301 of 8,163 rows).
        for day in 0..<30 {
            for i in 0..<300 {
                let ago=Double(day)*86400+Double(i)*60+3600
                rows.append(Evidence(id:"ord-\(day)-\(i)",at:at(ago),kind:"window.changed",app:"Finder",bundle:"com.apple.finder",title:"Folder \(i%7)",synthetic:true))
            }
        }
        let glyphs=["◐","◓","◑","◒","✳"]
        for night in 0..<3 {
            for i in 0..<8000 {
                let ago=Double(night)*86400+Double(i)*1.5+60
                rows.append(Evidence(id:"spin-\(night)-\(i)",at:at(ago),kind:"window.changed",app:"Ghostty",bundle:"com.mitchellh.ghostty",
                                     title:glyphs[i%glyphs.count]+" Parser cleanup session \(night)",synthetic:true))
            }
        }
        // Titles beyond ASCII that could fold (accents) can't be ruled out by SQL; a window repeating one is read once.
        for i in 0..<6000 {
            rows.append(Evidence(id:"accent-\(i)",at:at(Double(i)*2+30),kind:"window.changed",app:"Preview",bundle:"com.apple.Preview",title:"Résumé draft",synthetic:true))
        }
        rows.append(Evidence(id:"old-notes",at:at(25*86400+500),kind:"window.changed",app:"Notes",bundle:"com.apple.Notes",title:"Shopping list",synthetic:true))
        rows.append(Evidence(id:"old-textedit",at:at(18*86400+500),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Draft outline",synthetic:true))
        rows.append(Evidence(id:"old-texts",at:at(12*86400+500),kind:"window.changed",app:"Messages",bundle:"com.apple.MobileSMS",title:"Riley Fixture",synthetic:true))
        rows.append(Evidence(id:"old-cafe",at:at(20*86400+500),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Café menu",synthetic:true))
        try insert(store,rows);print("inserted \(rows.count)")
        let month=MemorySearchQuery("",start:now.addingTimeInterval(-30*86400),end:now.addingTimeInterval(60),limit:20)
        func first(_ text:String,app:String?=nil)throws->(ids:[String],seconds:Double,result:MemorySearchResult) {
            var q=month;q.text=text;q.app=app.map { SearchDocument.bundle(forAlias:$0) ?? $0 }
            let started=Date();let r=try store.fallbackSearch(q,now:now,status:"unavailable_fallback")
            let s=Date().timeIntervalSince(started)
            print(String(format:"MEASURE %@: %.3fs, %d hits, partial=%@, scannedBackTo=%@",text,s,r.items.count,String(r.partial),r.scannedBackTo ?? "end"))
            return (r.items.map(\.id),s,r)
        }
        let notes=try first("Notes")
        check(notes.ids.contains("old-notes"),"one 2-second call reaches a Notes row 25 days back past 24,000 spinner rows and 6,000 accented title rows",notes.ids.prefix(5).description)
        check(!notes.result.partial || notes.result.next != nil,"an unfinished scan keeps its continuation")
        let edit=try first("TextEdit")
        check(edit.ids.contains("old-textedit") && edit.ids.contains("old-cafe"),"TextEdit finds its rows 18 and 20 days back in one call",edit.ids.description)
        let texts=try first("Texts")
        check(texts.ids == ["old-texts"],"\"Texts\" (the app's name for Messages) finds the Messages row",texts.ids.description)
        let messages=try first("Messages")
        check(messages.ids.contains("old-texts"),"\"Messages\" still finds it")
        let byApp=try first("Riley",app:"Texts")
        check(byApp.ids == ["old-texts"],"the app filter \"Texts\" means Messages",byApp.ids.description)
        check(MemorySearchQuery("x",app:"texts").app == "com.apple.MobileSMS" && MemorySearchQuery("x",app:"com.apple.Notes").app == "com.apple.Notes","an app filter maps only the alias")
        let resume=try first("resume")
        check(resume.ids.count == 20 && resume.ids.allSatisfy { $0.hasPrefix("accent-") },"accented repeated titles still match (\"resume\")",resume.ids.prefix(3).description)
        let cafe=try first("cafe")
        check(cafe.ids.contains("old-cafe"),"accents still fold: \"cafe\" finds \"Café menu\"",cafe.ids.description)
        // Coordinator rule (claude/title-spinner-1003 395b2cc): a title tick (the same title without its glyph as the
        // previous title row of the day, same app) is never a hit; the row that starts a run still is.
        var parser=month;parser.text="Parser cleanup";parser.limit=100
        var spinIDs=[String](),calls=0
        while calls<200 {
            calls+=1
            let r=try store.fallbackSearch(parser,now:now,status:"unavailable_fallback")
            spinIDs+=r.items.map(\.id)
            guard let next=r.next else {break}
            parser.after=next
        }
        check(spinIDs.allSatisfy { $0.hasPrefix("spin-") } && (0..<3).allSatisfy { spinIDs.contains("spin-\($0)-7999") },
              "the row that starts each spinner session is found",spinIDs.suffix(5).description)
        let ticks=try store.titleTicks(from:at(86400*3),to:at(0))
        check(ticks.count > 10000 && spinIDs.count+ticks.count == 24000,"title ticks are not hits: \(spinIDs.count) runs returned, \(ticks.count) ticks left out (other windows' rows in between start new runs)")
        check(spinIDs.allSatisfy { !ticks.contains($0) },"no returned row is a tick by the day-assembly rule")
        check(try store.titleTicks(from:at(26*86400),to:at(24*86400)).isEmpty,"rows without a status glyph are never ticks")
        // The index projection carries the alias too, and only Messages rows' revisions change for it.
        if let item=try store.read("old-texts",now:now),let doc=SearchDocument.make(item) {
            check(doc.app.contains("Texts") && doc.app_keys.contains(fingerprint("Texts")),"index document for a Messages row matches and filters by Texts",doc.app)
        } else {check(false,"Messages row projects to a search document")}
        if let item=try store.read("old-notes",now:now),let doc=SearchDocument.make(item) {
            check(!doc.app.contains("(") && doc.app_keys.count == 2,"other rows' index documents are unchanged",doc.app)
        } else {check(false,"Notes row projects to a search document")}
    }
    /// The binding the supervisor wrote before the history folder moved is its own (same store, same layout), so it is
    /// set aside and rebuilt; anything else still refuses.
    static func moved() {
        let parent=URL(fileURLWithPath:"/private/tmp/fixture-support")
        let old=parent.appendingPathComponent("Mac Mem"),new=parent.appendingPathComponent("DayDream")
        let newRoot=new.appendingPathComponent("local-search-v1")
        let search=newRoot.appendingPathComponent("search.key"),sync=newRoot.appendingPathComponent("sync.key")
        func binding(home:URL,store:String="store-1",collectionHome:URL?=nil,keys:URL?=nil,synthetic:Bool=false)->ManagedSearchBinding {
            let root=keys ?? home.appendingPathComponent("local-search-v1")
            var config=TypesenseConfiguration(home:collectionHome ?? home,port:28100,searchKeyFile:root.appendingPathComponent("search.key").path,syncKeyFile:root.appendingPathComponent("sync.key").path,enabled:true)
            if synthetic {config.syntheticOnly=true}
            return ManagedSearchBinding(storeID:store,peerPort:28101,config:config)
        }
        check(LocalSearchSupervisor.movedWithFolder(binding(home:old),storeID:"store-1",home:new,search:search,sync:sync),
              "a binding written in the old Mac Mem folder for this store is recognized as this folder's own")
        check(!LocalSearchSupervisor.movedWithFolder(binding(home:new),storeID:"store-1",home:new,search:search,sync:sync),"the current folder's binding is not a moved one")
        check(!LocalSearchSupervisor.movedWithFolder(binding(home:old,store:"store-2"),storeID:"store-1",home:new,search:search,sync:sync),"another store's binding still refuses")
        check(!LocalSearchSupervisor.movedWithFolder(binding(home:old,keys:URL(fileURLWithPath:"/private/tmp/shared-index")),storeID:"store-1",home:new,search:search,sync:sync),"keys outside a local-search-v1 folder still refuse")
        check(!LocalSearchSupervisor.movedWithFolder(binding(home:old,collectionHome:URL(fileURLWithPath:"/private/tmp/elsewhere")),storeID:"store-1",home:new,search:search,sync:sync),"a collection that isn't the old folder's still refuses")
        check(!LocalSearchSupervisor.movedWithFolder(binding(home:old,synthetic:true),storeID:"store-1",home:new,search:search,sync:sync),"a synthetic preview binding still refuses")
    }
}
