// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//45,000 fictional rows preserve deep exact discovery, then walk bounded fuzzy
//continuations to final answers. Expectations come from fixture labels/ages,
//never production matching/projection code or an SQL oracle.
import Foundation
@testable import MemoryCore
var scratchRoot=URL(fileURLWithPath:"/nonexistent")
func finishScratch(_ code:Int32)->Never {try? FileManager.default.removeItem(at:scratchRoot);exit(code)}
@main struct SearchDepthChecks {
    static var passes=0,failures=0
    static func check(_ value:Bool,_ name:String,_ detail:@autoclosure ()->String="") {
        if value {passes+=1;print("PASS "+name)} else {failures+=1;print("FAIL "+name+": "+detail())}
    }
    static func main() {
        setbuf(stdout,nil)
        do {
            let base=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TMPDIR"] ?? "/private/tmp")
            scratchRoot=base.appendingPathComponent("daydream-search-depth-"+UUID().uuidString)
            // Three whole45k sweeps (180s high-load ceilings), five app scopes,
            // filters and population share a600s offline fixture ceiling.
            // This is diagnostic completeness, never fast user-search proof.
            let started=Date()
            try continuation(scratchRoot.appendingPathComponent("continuation"))
            try depth(scratchRoot.appendingPathComponent("month"))
            check(Date().timeIntervalSince(started)<600,"all45k offline fixture scopes finish within600 seconds")
        } catch {check(false,"fixture completed without unexpected error",String(describing:error))}
        print("\(passes) search depth checks passed, \(failures) failed. Fictional histories only.")
        finishScratch(failures==0 ? 0 : 1)
    }
    static func insert(_ store:MemoryStore,_ records:[Evidence])throws {
        try store.transaction {for e in records {try store.exec("INSERT INTO records VALUES(?,?,?)",[e.id,try json(e),fingerprint(try json(e))])}}
    }
    /// Exact/fuzzy phases may need more calls. Each call stays under3s, every
    /// cursor advances, no ID repeats. Whole45k scopes have a calibrated180s
    /// high-load offline ceiling (measured62–86s); app scopes retain90s.
    /// The production2s call budget is unchanged.
    static func all(_ store:MemoryStore,_ query:MemorySearchQuery,now:Date,reader:Bool=false)throws->[String] {
        var q=query,ids=[String](),seen=Set<String>(),cursors=Set<String>(),calls=0
        let started=Date(),scopeBudget:TimeInterval=query.app == nil ? 180 : 90
        for _ in 0..<200 {
            let call=Date(),pageIDs:[String],partial:Bool,next:String?
            if reader {
                let r=try store.searchReport(q);pageIDs=r.hits.compactMap { $0["id"] };partial=r.partial;next=r.next
                guard pageIDs.count==r.hits.count,r.coverage.contains("Typed text is not searched") else {throw MemError.invalid("Reader lost source references or body coverage limit")}
            } else {let r=try store.searchResult(q,now:now);pageIDs=r.items.map(\.id);partial=r.partial;next=r.next}
            calls+=1
            let callSeconds=Date().timeIntervalSince(call),scopeSeconds=Date().timeIntervalSince(started)
            guard callSeconds<3,scopeSeconds<scopeBudget else {throw MemError.invalid("Search budget exceeded: call=\(callSeconds)s (<3), scope=\(scopeSeconds)s (<\(scopeBudget)), calls=\(calls), IDs=\(ids.count)")}
            print(String(format:"CALL %@ %@: %d, %.3fs, %d hits, partial=%@",query.text,reader ? "reader" : "app",calls,callSeconds,pageIDs.count,String(partial)))
            if calls%10==0 {print(String(format:"PROGRESS %@ %@: %d calls, %d IDs, %.2fs",query.text,reader ? "reader" : "app",calls,ids.count,scopeSeconds))}
            guard partial==(next != nil) else {throw MemError.invalid("Incomplete scope lost its continuation")}
            for id in pageIDs {guard seen.insert(id).inserted else {throw MemError.invalid("Repeated result ID")};ids.append(id)}
            guard let value=next else {
                print(String(format:"MEASURE %@ %@: %d calls, %.2fs complete",query.text,reader ? "reader" : "app",calls,Date().timeIntervalSince(started)))
                return ids
            }
            guard value.utf8.count<8192,cursors.insert(value).inserted else {throw MemError.invalid("Oversized/nonadvancing cursor")}
            q.after=value
        }
        throw MemError.invalid("Search did not finish within200 pages")
    }
    static func depth(_ home:URL)throws {
        let store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false),now=Date()
        let apps=[("Safari","com.apple.Safari"),("Xcode","com.apple.dt.Xcode"),("Slack","com.tinyspeck.slackmacgap"),("Notes","com.apple.Notes"),("Google Chrome","com.google.Chrome"),("Terminal","com.apple.Terminal"),("Mail","com.apple.mail"),("Figma","com.figma.Desktop")]
        let words=["project","review","budget","notes","meeting","design","draft","plan","report","update","sprint","invoice","roadmap","launch","customer","feedback","search","results","weekly","sync","bug","fix","release","docs"]
        var records=[Evidence](),ages=[String:Double](),reviewIDs=[String]()
        for n in 0..<45000 {
            let age=Double(n)*86400/1500+30,(app,bundle)=apps[n%apps.count]
            let title="\(words[n%words.count].capitalized) \(words[(n/7)%words.count]) \(n%97)",id="m\(n)"
            records.append(Evidence(id:id,at:iso(now.addingTimeInterval(-age)),kind:n%11==0 ? "keyboard.text_input" : "window.changed",app:app,bundle:bundle,title:n%11==0 ? "" : title,url:bundle=="com.google.Chrome" ? "https://docs.example.com/d/\(n)" : "",text:n%11==0 ? "typed zebracorn words that never match forbiddenbodyword" : "",synthetic:true));ages[id]=age
            // Independent fixture labels: these rows were deliberately assigned
            // the literal review word, not inferred from any production result.
            if n%11 != 0 && (n%words.count==1 || (n/7)%words.count==1) {reviewIDs.append(id)}
        }
        let targets:[(Double,String)]=[(1200,"zebracornalpha"),(10800,"zebracornbravo"),(93600,"zebracorncharlie"),(604800,"zebracorndelta"),(2505600,"zebracornecho")]
        for (age,word) in targets {
            let id="t-"+word
            records.append(Evidence(id:id,at:iso(now.addingTimeInterval(-age)),kind:"window.changed",app:"Notes",bundle:"com.apple.Notes",title:"Plan \(word) review",url:word=="zebracornalpha" ? "https://fixture.example/read" : "",synthetic:true));ages[id]=age;reviewIDs.append(id)
        }
        let everyday:[(Double,String,String)]=[(93600,"keyboard","Mechanical keyboard deals"),(259200,"menu","Lunch menu"),(604800,"star","Star chart"),(1036800,"window","Window blinds quote"),(1900800,"title","Title deed scan"),(2332800,"open","Open house flyer")]
        for (age,word,title) in everyday {records.append(Evidence(id:"w-"+word,at:iso(now.addingTimeInterval(-age)),kind:"window.changed",app:"Pages",bundle:"com.apple.iWork.Pages",title:title,synthetic:true));ages["w-"+word]=age}
        records.append(Evidence(id:"f-alpha",at:iso(now.addingTimeInterval(-60)),kind:"window.changed",app:"Notes",bundle:"com.apple.Notes",title:"Plan zebracornalhpa review",url:"https://fixture.example/read",synthetic:true));ages["f-alpha"]=60;reviewIDs.append("f-alpha")
        records.append(Evidence(id:"p-excluded",at:iso(now.addingTimeInterval(-70)),kind:"window.changed",app:"Excluded Thing",bundle:"com.example.excluded",title:"zebracornalpha review",synthetic:true))
        var privateRow=Evidence(id:"p-private",at:iso(now.addingTimeInterval(-80)),kind:"window.changed",app:"Notes",bundle:"com.apple.Notes",title:"zebracornalpha review",synthetic:true);privateRow.privateWindow=true;records.append(privateRow)
        records.append(Evidence(id:"p-secret",at:iso(now.addingTimeInterval(-90)),kind:"window.changed",app:"Notes",bundle:"com.apple.Notes",title:"password: zebracornalpha review",synthetic:true))
        records.append(Evidence(id:"p-deleted",at:iso(now.addingTimeInterval(-100)),kind:"window.changed",app:"Notes",bundle:"com.apple.Notes",title:"zebracornalpha review",synthetic:true))
        let start=Date();try insert(store,records)
        _=try store.savePreferences(MemoryPreferences(blockedApps:["com.example.excluded"],nativeTyping:false),expectedRevision:try store.policy().revision);try store.delete("p-deleted")
        check(records.count==45016,"fixture preserves45,000 background rows and16 labeled controls",String(records.count))
        print(String(format:"MEASURE populated%d rows in%.2fs",records.count,Date().timeIntervalSince(start)))
        let month=now.addingTimeInterval(-30*86400)
        for (age,word) in targets {
            let expected=word=="zebracornalpha" ? ["t-"+word,"f-alpha"] : ["t-"+word]
            let q=MemorySearchQuery(word,start:month,limit:50)
            var clock=Date();let first=try store.searchResult(q,now:now)
            check(first.items.first?.id=="t-"+word && first.items.allSatisfy {expected.contains($0.id)},"deep exact subject from\(Int(age/60)) minutes ago appears on the first app page before any fuzzy control")
            print(String(format:"FIRST %@ app: %.3fs, %d hits, partial=%@",word,Date().timeIntervalSince(clock),first.items.count,String(first.partial)))
            check(Date().timeIntervalSince(clock)<3 && first.partial==(first.next != nil),"first app call stays under3s and reports unfinished coverage honestly")
            clock=Date();let report=try store.searchReport(MemorySearchQuery(word,start:month,limit:20))
            check(report.hits.first?["id"]=="t-"+word && report.hits.allSatisfy {expected.contains($0["id"] ?? "")},"deep exact subject appears on the first reader page")
            print(String(format:"FIRST %@ reader: %.3fs, %d hits, partial=%@",word,Date().timeIntervalSince(clock),report.hits.count,String(report.partial)))
            check(Date().timeIntervalSince(clock)<3 && report.partial==(report.next != nil),"reader transport preserves bounded calls and canonical continuation")
            let complete=try all(store,MemorySearchQuery(word,app:"com.apple.Notes",start:month,limit:20),now:now)
            check(complete==expected,"complete Notes scope has every allowed exact/fuzzy ID, with no privacy rows",String(describing:complete))
        }
        for (age,word,_) in everyday {
            var clock=Date();let r=try store.searchResult(MemorySearchQuery(word,start:month,limit:50),now:now)
            let expectedFirst=word=="title" ? ["p-secret","w-title"] : ["w-"+word]
            check(r.items.map(\.id)==expectedFirst,"template word\(word) remains discoverable on the first page from\(Int(age/86400)) days ago")
            print(String(format:"FIRST %@ app: %.3fs, %d hits, partial=%@",word,Date().timeIntervalSince(clock),r.items.count,String(r.partial)))
            check(Date().timeIntervalSince(clock)<3 && r.partial==(r.next != nil),"template-word call remains bounded with usable continuation")
            clock=Date();let report=try store.searchReport(MemorySearchQuery(word,start:month,limit:20))
            print(String(format:"FIRST %@ reader: %.3fs, %d hits, partial=%@",word,Date().timeIntervalSince(clock),report.hits.count,String(report.partial)))
            check(report.hits.map {$0["id"] ?? ""}==expectedFirst && Date().timeIntervalSince(clock)<3 && report.partial==(report.next != nil),"reader also preserves first-page template-word discovery and boundedness")
            let complete=try all(store,MemorySearchQuery(word,app:"com.apple.iWork.Pages",start:month,limit:20),now:now)
            check(complete==["w-"+word],"complete Pages scope yields exactly the planted template-word ID")
        }
        let typed=try all(store,MemorySearchQuery("zebracorn",start:month,limit:50),now:now)
        let planted=["f-alpha"]+targets.map {"t-"+$0.1}
        check(typed==planted,"complete45k scope returns all six planted titles; typed words and privacy controls never match",String(describing:typed))
        let typo=try all(store,MemorySearchQuery("zebracornalhpa review",app:"com.apple.Notes",start:month,limit:1),now:now,reader:true)
        check(typo==["f-alpha","t-zebracornalpha"],"reader's misspelled multiword query completes both literal and recovered tiers")
        let date=try all(store,MemorySearchQuery("zebracornalpha",app:"com.apple.Notes",start:now.addingTimeInterval(-7200),end:now.addingTimeInterval(-120),limit:1,site:"fixture.example"),now:now)
        check(date==["t-zebracornalpha"],"combined date/app/site selection excludes newer fuzzy and private rows")
        let wrongSite=try all(store,MemorySearchQuery("zebracornalpha",app:"com.apple.Notes",start:month,limit:1,site:"other.example"),now:now)
        check(wrongSite.isEmpty,"exact site selection cannot leak a fuzzy cross-site result")
        let missing=try all(store,MemorySearchQuery("quuxnotthere",start:month,limit:50),now:now)
        check(missing.isEmpty,"absent word is final only after completing the whole45k canonical scope")
        let body=try all(store,MemorySearchQuery("forbiddenbodywrd",app:"com.apple.Notes",start:month,limit:20),now:now)
        check(body.isEmpty,"fuzzy recovery cannot expose typed body words")
        let expectedReview=reviewIDs.sorted {ages[$0] == ages[$1] ? $0>$1 : ages[$0]!<ages[$1]!}
        let common=try all(store,MemorySearchQuery("review",start:month,limit:50),now:now)
        check(common==expectedReview,"common-word complete scope returns every fixture-labeled ID exactly once in descending-time order","actual\(common.count), expected\(expectedReview.count)")
    }
    static func continuation(_ home:URL)throws {
        let store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false),now=Date()
        try insert(store,(0..<60).map {Evidence(id:String(format:"c%02d",$0),at:iso(now.addingTimeInterval(-Double($0)*60-5)),kind:"window.changed",app:"Notes",bundle:"com.apple.Notes",title:"Budget page \($0)",synthetic:true)})
        let first=try store.searchResult(MemorySearchQuery("budget",limit:10),now:now)
        check(first.items.map(\.id)==(0..<10).map {String(format:"c%02d",$0)} && first.next != nil,"first page preserves exact ten IDs and continuation")
        try store.delete("c30")
        let rest=try all(store,MemorySearchQuery("budget",limit:10,after:first.next),now:now)
        let expected=(10..<60).filter {$0 != 30}.map {String(format:"c%02d",$0)}
        check(rest==expected && Set(first.items.map(\.id)+rest).count==59,"after deletion every remaining ID appears once, without skipping the next page")
        check((try? store.searchResult(MemorySearchQuery("budget",after:"not-a-continuation"),now:now))==nil,"made-up continuation is refused")
        check((try? store.searchResult(MemorySearchQuery("page",after:first.next),now:now))==nil,"another query cannot reuse the continuation")
    }
}
