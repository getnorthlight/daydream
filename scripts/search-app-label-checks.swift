// Fabricated secret-shaped app label only. Never private history or a service.
import Foundation
@testable import MemoryCore
private final class AppLabelTransport:TypesenseTransport {
    var documents=[SearchDocument]()
    func request(_ method:String,_ path:String,query:[URLQueryItem],body:Data?,deadline:Date)throws->TypesenseResponse {
        TypesenseResponse(status:200,data:try JSONSerialization.data(withJSONObject:["found":documents.count,"hits":documents.map {["document":["source_id":$0.source_id,"revision":$0.revision]]}]))
    }
}
@main enum SearchAppLabelChecks {
    static var count=0,failures=0
    static func check(_ value:Bool,_ label:String) {
        if value {count+=1;print("PASS "+label)} else {failures+=1;print("FAIL "+label)}
    }
    static func main() {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:"/private/tmp/daydream-app-label-fixture-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        do {try run(root)} catch {check(false,"unexpected fixture error: \(error)")}
        print("\(count) app-label privacy checks passed, \(failures) failed. Fabricated metadata only.");exit(failures==0 ? 0 : 1)
    }
    static func run(_ root:URL)throws {
        let now=Date(),store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        let name="sk-live_abcdefghijklmnop"
        _=try store.ingest(Evidence(id:"masked",at:iso(now.addingTimeInterval(-60)),kind:"window.changed",app:name,bundle:"fiction.secretlabel",title:"Ordinary ledger",synthetic:true),now:now)
        _=try store.ingest(Evidence(id:"contacts",at:iso(now.addingTimeInterval(-70)),kind:"window.changed",app:"Memos",bundle:"fiction.Memos",title:"Contact alice@example.test at +1 (312) 555-0199",synthetic:true),now:now)
        let body=Evidence(id:"body",at:iso(now.addingTimeInterval(-80)),kind:"keyboard.text_input",app:"Memos",bundle:"fiction.Memos",text:"forbiddenbodyword",synthetic:true)
        try store.exec("INSERT INTO records VALUES(?,?,?)",[body.id,try json(body),fingerprint(try json(body))])
        check(try store.searchResult(MemorySearchQuery("abcdefghijklmnop"),now:now).items.isEmpty,"secret-shaped app substring cannot drive canonical admission")
        check(try store.searchResult(MemorySearchQuery("abcdegfhijklmnop"),now:now).items.isEmpty,"secret-shaped app typo cannot drive fuzzy admission")
        let found=try store.searchResult(MemorySearchQuery("ordinary ledger"),now:now)
        check(found.items.map(\.id)==["masked"],"permitted title remains searchable")
        check(found.items.allSatisfy {$0.evidence.app=="[sensitive app omitted]" && !$0.summary.contains(name)},"returned evidence app and canonical description share the index's mask")
        let report=try store.searchReport(MemorySearchQuery("ordinary ledger"))
        check(report.hits.map {$0["id"] ?? ""}==["masked"] && report.hits.allSatisfy {!($0["app"] ?? "").contains(name) && !($0["snippet"] ?? "").contains(name)},"reader app/snippet cannot expose the masked label")
        let original=try store.read("masked",now:now)!,projection=SearchDocument.make(original)!
        check(original.evidence.app==name,"canonical source metadata is unchanged by search presentation")
        guard let foundItem=found.items.first else {throw MemError.invalid("permitted title lost") }
        check(SearchDocument.make(foundItem)?.revision==projection.revision,"mask does not invalidate already-indexed document revisions")
        let action=try store.action("masked",now:now)!
        _=try store.correctAction(id:"masked",text:"New dossier",expectedRevision:action.revision,now:now)
        check(try store.searchResult(MemorySearchQuery("abcdefghijklmnop"),now:now).items.isEmpty,"observed description behind a correction cannot reintroduce the app secret")
        check(try store.searchResult(MemorySearchQuery("new dossier"),now:now).items.map(\.id)==["masked"],"permitted user correction still matches")
        check(try store.searchResult(MemorySearchQuery("alice@example.test"),now:now).items.map(\.id)==["contacts"],"allowed email metadata is unchanged")
        check(try store.searchResult(MemorySearchQuery("555-0199"),now:now).items.map(\.id)==["contacts"],"allowed formatted phone metadata is unchanged")
        check(try store.searchResult(MemorySearchQuery("forbiddenbodywrd"),now:now).items.isEmpty,"body exclusion remains unchanged for typos")
        let ordinary=try store.searchResult(MemorySearchQuery("memos",app:"fiction.Memos"),now:now)
        check(ordinary.items.map(\.id)==["contacts","body"] && ordinary.items.allSatisfy {$0.evidence.app=="Memos"},"ordinary app labels and exact bundle selection remain unchanged")
        // A fallback app name can be the real bundle ID (legacy rows). Its
        // uppercase component must not turn Notes into a secret-shaped label.
        _=try store.ingest(Evidence(id:"known-bundle",at:iso(now.addingTimeInterval(-90)),kind:"window.changed",app:"com.apple.Notes",bundle:"com.apple.Notes",title:"Fictional grocery ledger",synthetic:true),now:now)
        let known=try store.searchResult(MemorySearchQuery("",app:"com.apple.Notes"),now:now)
        check(known.items.map(\.id)==["known-bundle"] && known.items.first?.evidence.app=="Notes","known bundle label and exact bundle filter retain the readable app name")
        let knownReport=try store.searchReport(MemorySearchQuery("",app:"com.apple.Notes"))
        check(knownReport.hits.first?["app"]=="Notes" && knownReport.hits.first?["snippet"]?.hasPrefix("Notes window")==true,"assistant search uses readable known app names")
        check(try store.read("known-bundle",now:now)?.evidence.app=="com.apple.Notes","known-label normalization changes search projection only")
        let config=TypesenseConfiguration(home:root,port:28120,searchKeyFile:root.appendingPathComponent("search.key").path,syncKeyFile:root.appendingPathComponent("sync.key").path,enabled:true)
        for path in [config.searchKeyFile,config.syncKeyFile] {try Data("fictional-fixture-key-000000000000".utf8).write(to:URL(fileURLWithPath:path));try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path)}
        let configURL=root.appendingPathComponent("search-typesense.json");try JSONEncoder().encode(config).write(to:configURL);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configURL.path)
        let transport=AppLabelTransport();transport.documents=[SearchDocument.make(try store.read("masked",now:now)!)!]
        let indexed=try store.indexedSearch(MemorySearchQuery("new dossier"),config:config,transport:transport,now:now)
        check(indexed.items.map(\.id)==["masked"] && indexed.items.allSatisfy {$0.evidence.app=="[sensitive app omitted]" && !$0.summary.contains(name)},"indexed admission and presentation retain the same masked canonical metadata")
    }
}
