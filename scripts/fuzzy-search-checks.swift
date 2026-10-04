// Fictional metadata in an isolated store; no server, OS capture or private history.
import Foundation
@testable import MemoryCore

private final class SearchFixtureTransport:TypesenseTransport {
    var documents:[SearchDocument]=[]
    var parameters:[String:String]=[:]
    func request(_ method:String,_ path:String,query:[URLQueryItem],body:Data?,deadline:Date)throws->TypesenseResponse {
        parameters=Dictionary(uniqueKeysWithValues:query.map { ($0.name,$0.value ?? "") })
        return TypesenseResponse(status:200,data:try JSONSerialization.data(withJSONObject:["found":documents.count,"hits":documents.map { ["document":["source_id":$0.source_id,"revision":$0.revision,"summary":"untrustedindexword"]] }]))
    }
}
@main enum FuzzySearchChecks {
    static var passed=0
    static func check(_ value:Bool,_ label:String)throws {
        guard value else { throw MemError.invalid("FAIL: "+label) };passed+=1;print("PASS "+label)
    }
    static func main() {
        do { try runChecks() }
        catch { print("FAIL focused fixture: \(error)");exit(1) }
    }
    static func runChecks()throws {
        setbuf(stdout,nil)
        let now=Date(),root=URL(fileURLWithPath:"/private/tmp/daydream-fuzzy-fixture-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        func seed(_ id:String,_ title:String,_ age:Double=60,_ app:String="Notes",_ site:String="fiction.example")throws {
            _=try store.ingest(Evidence(id:id,at:iso(now.addingTimeInterval(-age)),kind:"window.changed",app:app,bundle:"fiction."+app,title:title,url:"https://"+site+"/",synthetic:true),now:now)
        }
        func all(_ q:MemorySearchQuery)throws->[String] {
            var query=q,ids=[String](),seen=Set<String>()
            for _ in 0..<100 {
                let result=try store.searchResult(query,now:now)
                try check(result.backend=="sqlite","disabled service uses canonical SQLite")
                for item in result.items {try check(seen.insert(item.id).inserted,"continuation never repeats IDs");ids.append(item.id)}
                guard let next=result.next else {return ids};query.after=next
            }
            throw MemError.invalid("FAIL: continuation did not finish")
        }
        try seed("exact","Garden sensor",300)
        try seed("prefix","Gardenia sensor",200)
        try seed("fuzzy","Gardan sensor",10)
        try seed("unrelated","Garden pottery",5)
        try seed("numeric","Calibration 2026",30)
        try seed("accent","Café résumé",40)
        try seed("app","Orchard planning",50,"Instagram","photos.example")
        let ordered=try all(MemorySearchQuery("garden sensor",limit:1))
        try check(ordered==["prefix","exact","fuzzy"],"all exact/prefix pages precede newer typo page; every word required")
        try check(try all(MemorySearchQuery("graden sensor"))==["exact"],"adjacent transposition is one edit")
        try check(try all(MemorySearchQuery("gardn sensor"))==["fuzzy","exact"],"missing letter matches permitted metadata")
        try check(try all(MemorySearchQuery("gardenn sensor"))==["exact"],"extra letter is tolerated")
        try check(try all(MemorySearchQuery("garden zyxwv"))==[],"second missing word cannot be dropped")
        try check(try all(MemorySearchQuery("ses"))==[],"three-letter tokens do not become fuzzy")
        try check(try all(MemorySearchQuery("2027"))==[],"numeric tokens remain exact")
        try check(try all(MemorySearchQuery("CFE"))==[],"short accent-normalized tokens stay exact")
        try check(try all(MemorySearchQuery("cafe resume"))==["accent"],"case/accent folding remains exact")
        try check(try all(MemorySearchQuery("instagrm"))==["app"],"app names recover a typo")
        try check(try all(MemorySearchQuery("phoots"))==["app"],"site metadata recovers an adjacent swap")
        try check(try all(MemorySearchQuery("garden sensor",app:"fiction.Notes",start:now.addingTimeInterval(-250),end:now.addingTimeInterval(-20)))==["prefix"],"date bounds apply to both tiers")
        try check(try all(MemorySearchQuery("gardn sensor",site:"other.example"))==[],"site filter is never fuzzy")
        try check(try all(MemorySearchQuery("gardn sensor",app:"fiction.Other"))==[],"app filter is never fuzzy")
        try store.delete("fuzzy")
        try check(try all(MemorySearchQuery("gardn sensor"))==["exact"],"deletion removes fuzzy metadata immediately")
        let action=try store.action("unrelated",now:now)!
        _=try store.correctAction(id:"unrelated",text:"Lantern astronomy",expectedRevision:action.revision,now:now)
        try check(try all(MemorySearchQuery("lantarn astronmy"))==["unrelated"],"approved canonical corrections are searchable with typos")
        try check(MemorySearchQuery("calibrton").lexicalScore("Calibration") != nil,"long tokens permit two edits")
        try check(MemorySearchQuery("grxxen").lexicalScore("Garden")==nil,"shorter tokens refuse two edits")
        try check(MemorySearchQuery("invoice2027").lexicalScore("invoice2026")==nil,"mixed identifiers refuse typo expansion")
        try check(MemorySearchQuery("abcdefgh").lexicalScore("xxxxxxxx")==nil,"unrelated long words are refused")
        try check(MemorySearchQuery("garden").lexicalScore("garden")==0 && MemorySearchQuery("garden").lexicalScore("gardan")!>0,"ordinary matches outrank fuzzy matches")
        var item=try store.read("exact",now:now)!
        item.evidence.text="zephyrbodyword";item.summary="nebulaGeneratedNote"
        let projection=SearchDocument.make(item)!
        try check(!projection.summary.contains("zephyrbodyword") && !projection.summary.contains("nebulaGeneratedNote"),"index projection excludes bodies and generated summaries")
        try check(try all(MemorySearchQuery("zephyrbodywrd"))==[],"typos cannot reveal unindexed body")
        try seed("secret","password: fictionalvalue",55)
        try check(try all(MemorySearchQuery("fictionalvalu"))==[],"withheld title cannot be exposed through typo recovery")
        // Typesense transport returns fabricated hits out of order, including a
        // nonmatching canonical action and an untrusted snippet. Real server not started.
        let config=TypesenseConfiguration(home:root,port:28108,searchKeyFile:root.appendingPathComponent("fixture-search.key").path,syncKeyFile:root.appendingPathComponent("fixture-sync.key").path,enabled:true)
        for path in [config.searchKeyFile,config.syncKeyFile] {
            try Data("fictional-fixture-key-000000000000".utf8).write(to:URL(fileURLWithPath:path));try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path)
        }
        let configURL=root.appendingPathComponent("search-typesense.json")
        try JSONEncoder().encode(config).write(to:configURL);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configURL.path)
        try seed("recent-typo","Gardan sensor",1)
        let transport=SearchFixtureTransport()
        transport.documents=try ["recent-typo","exact","unrelated"].map { SearchDocument.make(try store.read($0,now:now)!)! }
        let indexed=try store.indexedSearch(MemorySearchQuery("garden sensor",limit:2),config:config,transport:transport,now:now)
        try check(indexed.items.map(\.id)==["exact","recent-typo"],"older canonical exact hit outranks recent SQLite fuzzy hit")
        try check(indexed.items.allSatisfy { !$0.summary.contains("untrustedindexword") },"index snippets remain untrusted")
        try check(transport.parameters["drop_tokens_threshold"]=="0" && transport.parameters["min_len_2typo"]=="8","Typesense keeps all words and conservative typo threshold")
        try check(transport.parameters["enable_typos_for_numerical_tokens"]=="false" && transport.parameters["enable_typos_for_alpha_numerical_tokens"]=="false","Typesense refuses numeric/identifier typo expansion")
        try check(transport.parameters["prioritize_exact_match"]=="true","Typesense explicitly prioritizes exact matches")
        // A fuzzy URL-query observation is permitted only by the SQLite metadata
        // path. Its stripped index projection must not grant it exact rank.
        try seed("index-exact","Garden",600)
        _=try store.ingest(Evidence(id:"recent-query",at:iso(now.addingTimeInterval(-2)),kind:"window.changed",app:"Notes",bundle:"fiction.Notes",title:"",url:"https://www.google.com/search?q=gardan",synthetic:true),now:now)
        transport.documents=try ["index-exact"].map { SearchDocument.make(try store.read($0,now:now)!)! }
        let mixed=try store.indexedSearch(MemorySearchQuery("garden",limit:100),config:config,transport:transport,now:now)
        try check(mixed.items.contains { $0.id=="recent-query" },"SQLite query observation is a real metadata fuzzy control")
        let exactPosition=mixed.items.firstIndex { $0.id=="index-exact" },queryPosition=mixed.items.firstIndex { $0.id=="recent-query" }
        try check(exactPosition != nil && queryPosition != nil && exactPosition! < queryPosition!,"fuzzy URL-only recent hit never outranks a canonical exact hit")
        // A real index page can exceed the UI limit. More history resumes through
        // canonical rows with the original filters and without repeating index IDs.
        transport.documents=try ["prefix","exact","recent-typo"].map { SearchDocument.make(try store.read($0,now:now)!)! }
        let first=try store.indexedSearch(MemorySearchQuery("garden sensor",limit:1),config:config,transport:transport,now:now)
        try check(first.partial && first.next != nil,"partial healthy index result has a usable continuation")
        var continuation=MemorySearchQuery("garden sensor",limit:1,after:first.next)
        var continued=first.items.map(\.id)
        for _ in 0..<20 {
            let page=try store.searchResult(continuation,now:now);continued+=page.items.map(\.id)
            guard let next=page.next else { break };continuation.after=next
        }
        try check(Set(continued).count==continued.count && Set(continued)==Set(["prefix","exact","recent-typo"]),"index-to-SQLite continuation is complete and deduplicated across both tiers")
        // A complete index and a completed empty recent scan are still narrower
        // than canonical metadata: an older URL-query observation is absent from
        // the deliberately stripped SearchDocument. Prove the actual counterexample.
        let old=try MemoryStore(home:root.appendingPathComponent("old-query"),writable:true,automaticallySyncSearch:false)
        let oldConfig=TypesenseConfiguration(home:old.home,port:28110,searchKeyFile:config.searchKeyFile,syncKeyFile:config.syncKeyFile,enabled:true)
        let oldConfigURL=old.home.appendingPathComponent("search-typesense.json")
        try JSONEncoder().encode(oldConfig).write(to:oldConfigURL);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:oldConfigURL.path)
        _=try old.ingest(Evidence(id:"old-query-only",at:iso(now.addingTimeInterval(-600)),kind:"window.changed",app:"Notes",bundle:"fiction.Notes",title:"",url:"https://www.google.com/search?q=gardan",synthetic:true),now:now)
        let oldProjection=SearchDocument.make(try old.read("old-query-only",now:now)!)!
        try check(MemorySearchQuery("gardan").lexicalScore(oldProjection.summary+" "+oldProjection.app+" "+oldProjection.site)==nil,"older URL query is genuinely absent from the stricter index projection")
        let oldDirect=try old.fallbackSearch(MemorySearchQuery("gardan",limit:20),now:now,status:"control")
        try check(oldDirect.items.map(\.id)==["old-query-only"] && !oldDirect.partial,"permitted older URL-query metadata is actually searchable through canonical SQLite")
        let oldRecent=try old.fallbackSearch(MemorySearchQuery("gardan",start:now.addingTimeInterval(-10),limit:20),now:now,status:"control-recent")
        try check(oldRecent.items.isEmpty && !oldRecent.partial && oldRecent.next==nil,"recent-only control is empty and completely scanned")
        try old.exec("INSERT OR REPLACE INTO metadata VALUES('search_complete_revision',?)",[try old.disclosureRevision()])
        try old.exec("INSERT OR REPLACE INTO metadata VALUES('search_projection_version',?)",[ActionProjection.version])
        let oldTransport=SearchFixtureTransport()
        let oldIndexed=try old.indexedSearch(MemorySearchQuery("gardan",limit:20),config:oldConfig,transport:oldTransport,now:now)
        try check(oldIndexed.status=="ready" && oldIndexed.items.isEmpty && oldIndexed.partial && oldIndexed.next != nil,"caught-up empty index plus completed recent scan preserves older canonical coverage")
        let oldContinued=try old.searchResult(MemorySearchQuery("gardan",limit:20,after:oldIndexed.next),now:now)
        try check(oldContinued.backend=="sqlite" && oldContinued.items.map(\.id)==["old-query-only"] && !oldContinued.partial && oldContinued.next==nil,"empty-index continuation actually recovers the older observation and finishes")
        // UI-sized index page: twenty real canonical hits plus a local-only fuzzy
        // observation. Compact exclusions must fit and never repeat index results.
        for n in 0..<20 {
            _=try old.ingest(Evidence(id:"page-\(n)",at:iso(now.addingTimeInterval(-800-Double(n))),kind:"window.changed",app:"Notes",bundle:"fiction.Notes",title:"Orchard planning",synthetic:true),now:now)
        }
        _=try old.ingest(Evidence(id:"page-old-query-only",at:iso(now.addingTimeInterval(-700)),kind:"window.changed",app:"Notes",bundle:"fiction.Notes",title:"",url:"https://www.google.com/search?q=orchrad",synthetic:true),now:now)
        try old.exec("INSERT OR REPLACE INTO metadata VALUES('search_complete_revision',?)",[try old.disclosureRevision()])
        oldTransport.documents=try (0..<20).map { SearchDocument.make(try old.read("page-\($0)",now:now)!)! }
        let uiPage=try old.indexedSearch(MemorySearchQuery("orchard",limit:20),config:oldConfig,transport:oldTransport,now:now)
        try check(uiPage.status=="ready" && uiPage.items.count==20 && uiPage.partial && uiPage.next != nil && uiPage.next!.utf8.count<8192,"twenty-hit caught-up UI page carries a bounded usable canonical cursor")
        var uiIDs=uiPage.items.map(\.id),uiNext=uiPage.next
        for _ in 0..<10 {
            guard let next=uiNext else { break }
            let page=try old.searchResult(MemorySearchQuery("orchard",limit:20,after:next),now:now);uiIDs+=page.items.map(\.id);uiNext=page.next
        }
        try check(uiIDs.count==21 && Set(uiIDs).count==21 && uiIDs.contains("page-old-query-only") && uiNext==nil,"twenty-hit index continuation finds local-only fuzzy metadata without duplicating IDs")
        // Force a bounded continuation on a history far bigger than a page.
        let large=try MemoryStore(home:root.appendingPathComponent("large"),writable:true,automaticallySyncSearch:false)
        try large.transaction {
            for n in 0..<6000 {
                let evidence=Evidence(id:"filler-\(n)",at:iso(now.addingTimeInterval(-Double(n%5)-1)),kind:"window.changed",app:"Notes",bundle:"fiction.Notes",title:"Orchard schedule",synthetic:true)
                try large.exec("INSERT INTO records VALUES(?,?,?)",[evidence.id,try json(evidence),fingerprint(try json(evidence))])
            }
        }
        let start=Date(),bounded=try large.fallbackSearch(MemorySearchQuery("zyxwvuts"),now:now,status:"fixture")
        let elapsed=Date().timeIntervalSince(start)
        try check(elapsed<3.5,"missing typo query returns within bounded scan budget")
        try check(bounded.items.isEmpty && (bounded.next != nil)==bounded.partial,"unfinished fuzzy scan reports continuation rather than final completeness")
        print("MEASURE bounded missing query: \(Int(elapsed*1000))ms; partial=\(bounded.partial)")
        // Index reports complete/zero hits while the recent canonical fuzzy
        // merge exhausts its budget. Coverage must remain unfinished with next.
        let largeConfig=TypesenseConfiguration(home:large.home,port:28109,searchKeyFile:config.searchKeyFile,syncKeyFile:config.syncKeyFile,enabled:true)
        let largeConfigURL=large.home.appendingPathComponent("search-typesense.json")
        try JSONEncoder().encode(largeConfig).write(to:largeConfigURL);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:largeConfigURL.path)
        try large.exec("INSERT OR REPLACE INTO metadata VALUES('search_complete_revision',?)",[try large.disclosureRevision()])
        try large.exec("INSERT OR REPLACE INTO metadata VALUES('search_projection_version',?)",[ActionProjection.version])
        let emptyTransport=SearchFixtureTransport()
        let incomplete=try large.indexedSearch(MemorySearchQuery("zyxwvuts"),config:largeConfig,transport:emptyTransport,now:now)
        try check(incomplete.items.isEmpty && incomplete.status=="ready" && incomplete.partial && incomplete.next != nil,"caught-up empty index cannot hide an unfinished recent canonical scan")
        let wrongScope=MemorySearchQuery("differentword",after:incomplete.next)
        do { _=try large.searchResult(wrongScope,now:now);throw MemError.invalid("FAIL accepted another cursor scope") }
        catch { try check(!String(describing:error).contains("FAIL accepted"),"index continuation remains bound to its original query scope") }
        try check(incomplete.next!.utf8.count<8192,"healthy-index continuation stays within accepted cursor size")

        print("\(passed) focused fuzzy-search checks passed. Fictional metadata only.")
    }
}
