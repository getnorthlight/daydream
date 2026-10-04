// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
// Deterministic canonical metadata fixtures. Expected IDs are hand-curated,
// never computed by fallbackMatch, lexicalScore, projections or an SQL oracle.
// Every page is bounded, deduplicated and followed through exact then fuzzy tiers.
import Foundation
@testable import MemoryCore
var scratchRoot=URL(fileURLWithPath:"/nonexistent")
func finishScratch(_ code:Int32)->Never {try? FileManager.default.removeItem(at:scratchRoot);exit(code)}
@main struct SearchPrefilterChecks {
    static var passes=0,failures=0
    static func check(_ value:Bool,_ name:String,_ detail:@autoclosure ()->String="") {
        if value {passes+=1;print("PASS "+name)} else {failures+=1;print("FAIL "+name+": "+detail())}
    }
    static func main() {
        setbuf(stdout,nil)
        do {
            let base=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TMPDIR"] ?? "/private/tmp")
            scratchRoot=base.appendingPathComponent("daydream-search-prefilter-"+UUID().uuidString)
            try differential(scratchRoot)
        } catch {check(false,"fixture completed without unexpected error",String(describing:error))}
        print("\(passes) search prefilter checks passed, \(failures) failed. Fictional metadata only.")
        finishScratch(failures==0 ? 0 : 1)
    }
    static func all(_ store:MemoryStore,_ query:MemorySearchQuery,now:Date)throws->[String] {
        var q=query,ids=[String](),seen=Set<String>(),cursors=Set<String>()
        let started=Date()
        for _ in 0..<100 {
            let call=Date(),r=try store.searchResult(q,now:now)
            guard Date().timeIntervalSince(call)<3,Date().timeIntervalSince(started)<30 else {throw MemError.invalid("Search exceeded3s call/30s complete-scope budget")}
            guard r.partial==(r.next != nil) else {throw MemError.invalid("Incomplete answer lost its continuation")}
            for item in r.items {guard seen.insert(item.id).inserted else {throw MemError.invalid("Repeated result ID")};ids.append(item.id)}
            guard let next=r.next else {return ids}
            guard next.utf8.count<8192,cursors.insert(next).inserted else {throw MemError.invalid("Oversized/nonadvancing continuation")}
            q.after=next
        }
        throw MemError.invalid("Search did not finish within100 pages")
    }
    static func differential(_ home:URL)throws {
        let store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false),now=Date()
        var records=[Evidence]()
        func row(_ id:String,_ title:String,_ age:Double,_ kind:String="window.changed",_ app:String="Notes",_ bundle:String="com.apple.Notes",_ url:String="") {
            records.append(Evidence(id:id,at:iso(now.addingTimeInterval(-age)),kind:kind,app:app,bundle:bundle,title:title,url:url,synthetic:true))
        }
        row("budget-old","Budget roadmap",300)
        row("budget-prefix","Budgeting roadmap",200)
        row("budget-typo","Budegt roadmap",10)
        row("accent","Café Müller naïve résumé",400)
        row("width","ＦＵＬＬ width",410)
        row("controls","ctrl\u{0B}joined soft\u{00AD}hyphen zero\u{200B}width tab\tsep",420)
        row("google-query","",500,"window.changed","Notes","com.apple.Notes","https://www.google.com/search?q=hello+world&tbm=isch")
        row("youtube-query","",510,"window.changed","Notes","com.apple.Notes","https://www.youtube.com/results?search_query=quarterly+roadmap")
        row("percent-query","",520,"window.changed","Notes","com.apple.Notes","https://www.google.com/search?q=caf%C3%A9+cr%C3%A8me")
        row("site","Orbit chart",530,"window.changed","Notes","com.apple.Notes","https://Docs.Example.COM/a/b?x=1#frag")
        row("credentials-url","Orbit atlas",540,"window.changed","Notes","com.apple.Notes","https://user:pw@example.net/x")
        row("app-only","Orchard planning",550,"window.changed","Instagram","com.example.instagram","https://photos.example/")
        row("numeric","Calibration 2026 invoice2026",560)
        row("contacts","Contact alice@example.test at +1 (312) 555-0199",570)
        row("same-a","Twin docket",600);row("same-b","Twin docket",600)
        row("deleted","Vanishing azimuth",610)
        row("excluded","Forbidden chrysalis",620,"window.changed","Excluded Thing","com.example.excluded")
        row("correction","Obsolete plan",630)
        row("secret-password","password: hunter2",700)
        row("secret-card","4111 1111 1111 1111",710)
        row("secret-jwt","eyJhbGciOi.eyJzdWIi.sig",720)
        row("secret-numeric","4412",730)
        row("secret-app","Ordinary ledger",740,"window.changed","sk-live_abcdefghijklmnop","com.example.secretname")
        var body=Evidence(id:"body",at:iso(now.addingTimeInterval(-750)),kind:"keyboard.text_input",app:"Notes",bundle:"com.apple.Notes",title:"",text:"forbiddenbodyword",synthetic:true)
        body.typed=TypedRef(digest:"fabricateddigest",words:20);body.text="";records.append(body)
        let kinds=["window.changed","window.observed","focus.observed","browser.snapshot","browser.tab_opened","browser.tab_visited","browser.observed","message.sent","keyboard.submit","keyboard.text_input","selection.changed","idle","mouse.click","app.activated","conversation.user","conversation.assistant","custom.kind","mouse.context_menu","keyboard.shortcut","session.started","session.ended","debug.error","terminal.value_changed","browser.extension_tab_visited","browser.extension_observed","browser.custom","Window.Changed"]
        for (n,kind) in kinds.enumerated() {
            var e=Evidence(id:"kind-\(n)",at:iso(now.addingTimeInterval(-1000-Double(n))),kind:kind,app:"Notes",bundle:"com.apple.Notes",title:"kindmarker\(n)probe",text:"forbiddenbodyword",synthetic:true)
            if kind=="message.sent" {e.sendVerification=SendVerification(evidenceID:e.id,messageID:"fabricated-receipt",source:"native-delivery-receipt",confirmedAt:e.at)}
            records.append(e)
        }
        try store.transaction {for e in records {try store.exec("INSERT INTO records VALUES(?,?,?)",[e.id,try json(e),fingerprint(try json(e))])}}
        _=try store.savePreferences(MemoryPreferences(blockedApps:["com.example.excluded"],nativeTyping:false),expectedRevision:try store.policy().revision)
        try store.delete("deleted")
        let action=try store.action("correction",now:now)!
        _=try store.correctAction(id:"correction",text:"Quokkamention corrected",expectedRevision:action.revision,now:now)
        func expect(_ query:MemorySearchQuery,_ expected:[String],_ label:String)throws {
            let actual=try all(store,query,now:now)
            check(actual==expected,label,"actual=\(actual), expected=\(expected)")
        }
        // Explicit positive/negative pairs: AND semantics and ordinary rank are
        // preserved; genuine typo expansion is expected rather than waived.
        try expect(MemorySearchQuery("budget roadmap",limit:1),["budget-prefix","budget-old","budget-typo"],"all exact/prefix pages precede the newer typo, with every word required")
        try expect(MemorySearchQuery("budegt roadmap",limit:1),["budget-typo","budget-old"],"literal misspelling first, then one-transposition recovery; unrelated long prefix refused")
        try expect(MemorySearchQuery("budget missingword"),[],"one missing query word cannot be dropped")
        try expect(MemorySearchQuery("bud"),["budget-typo","budget-prefix","budget-old"],"short literal prefix retains its original semantics")
        try expect(MemorySearchQuery("bdu"),[],"short typo is not expanded")
        try expect(MemorySearchQuery("2027"),[],"numeric typo is not expanded")
        try expect(MemorySearchQuery("invoice2027"),[],"mixed identifier typo is not expanded")
        try expect(MemorySearchQuery("cafe muller"),["accent"],"case/accent folding retains both required words")
        try expect(MemorySearchQuery("cafe creme"),["percent-query"],"percent-encoded query survives the SQL prefilter")
        try expect(MemorySearchQuery("full width"),["width"],"full-width metadata survives the SQL prefilter")
        try expect(MemorySearchQuery("ctrljoined softhyphen zerowidth"),["controls"],"cleaned control/format characters cannot cause a false negative")
        try expect(MemorySearchQuery("hello world"),["google-query"],"permitted decoded URL search observations remain searchable")
        try expect(MemorySearchQuery("hello tbm"),[],"arbitrary URL parameter is stripped")
        try expect(MemorySearchQuery("quarterly roadmap"),["youtube-query"],"alternate permitted query key is searchable")
        try expect(MemorySearchQuery("docs.example.com"),["site"],"canonical host retains case-insensitive lookup")
        try expect(MemorySearchQuery("frag"),[],"URL fragment is stripped")
        try expect(MemorySearchQuery("example.net"),[],"credential-bearing URL is withheld")
        try expect(MemorySearchQuery("instagrm phoots"),["app-only"],"app/site typo recovery still requires both words")
        try expect(MemorySearchQuery("quokkamenton corrected"),["correction"],"approved user correction supplies allowed lexical metadata")
        try expect(MemorySearchQuery("vanishing"),[],"deleted row cannot match")
        try expect(MemorySearchQuery("chrysalis"),[],"excluded app cannot match")
        try expect(MemorySearchQuery("hunter2"),[],"withheld password title cannot match")
        try expect(MemorySearchQuery("4412"),[],"withheld numeric secret cannot match")
        try expect(MemorySearchQuery("sensitive title omitted",limit:1),["secret-password","secret-card","secret-jwt","secret-numeric"],"withheld-label wording survives the prefilter without exposing secrets")
        try expect(MemorySearchQuery("abcdefghijklmnop"),[],"withheld app name cannot match")
        let masked=try store.searchResult(MemorySearchQuery("ordinary ledger"),now:now)
        check(masked.items.map(\.id)==["secret-app"] && masked.items.allSatisfy {$0.evidence.app=="[sensitive app omitted]" && !$0.summary.contains("sk-live_")},"allowed title remains searchable while returned app/description stay masked")
        let maskedReader=try store.searchReport(MemorySearchQuery("ordinary ledger"))
        check(maskedReader.hits.map {$0["id"] ?? ""}==["secret-app"] && maskedReader.hits.allSatisfy {!($0["app"] ?? "").contains("sk-live_") && !($0["snippet"] ?? "").contains("sk-live_")},"reader results cannot expose the raw app label through their snippet or app field")
        try expect(MemorySearchQuery("alice@example.test"),["contacts"],"permitted email metadata remains searchable")
        try expect(MemorySearchQuery("555-0199"),["contacts"],"permitted formatted phone metadata remains searchable")
        try expect(MemorySearchQuery("forbiddenbodywrd"),[],"neither bodies nor their typos enter search")
        try expect(MemorySearchQuery("20 words"),["body"],"sealed word-count metadata remains searchable, never its body")
        try expect(MemorySearchQuery("twin",limit:1),["same-b","same-a"],"equal timestamps retain descending ID tie order across pages")
        try expect(MemorySearchQuery("budget roadmap",app:"com.apple.Notes",start:now.addingTimeInterval(-250),end:now.addingTimeInterval(-20),limit:1),["budget-prefix"],"date/app filters apply across both tiers")
        try expect(MemorySearchQuery("budget roadmap",app:"fiction.other"),[],"app selection is exact and never fuzzy")
        try expect(MemorySearchQuery("instagrm",site:"photos.example"),["app-only"],"exact site filter preserves a lexical app typo")
        try expect(MemorySearchQuery("instagrm",site:"phoots.example"),[],"site filter itself is never fuzzy")
        for n in kinds.indices {try expect(MemorySearchQuery("kindmarker\(n)probe",limit:1),["kind-\(n)"],"kind \(kinds[n]) retains its allowed title through the prefilter")}
        try expect(MemorySearchQuery("context-menu"),["kind-17"],"template-only context-menu word survives the SQL prefilter")
        try expect(MemorySearchQuery("keyboard shortcut"),["kind-18"],"template-only keyboard shortcut keeps every word")
        try expect(MemorySearchQuery("recording-session"),["kind-19","kind-20"],"template-only start/end words retain both canonical rows")
        // The fixed wording is read from the projections themselves.
        let template = MemorySearchQuery.templateText
        check(["reading is not established", "sensitive title omitted", "typed a draft in", "viewed search results for", "user correction (not observed)",
               "a few words", "about 20 words", "observed search results for"].allSatisfy(template.contains), "the fixed wording covers every template")
        check(MemorySearchQuery("zebracorn quokka").filterRuns == ["quokka", "zebracorn"] && MemorySearchQuery("reading observed").filterRuns == ["observed", "reading"]
              && MemorySearchQuery("Café-2026").filterRuns == ["2026", "caf"] && MemorySearchQuery("in;").filterRuns == ["in"],
              "filter runs: every run of letters and digits, the fixed wording's own words too (G27 review)")
        // A run only the fixed wording holds narrows the scan to the kinds whose wording holds it.
        let menu = MemorySearchQuery.templateCondition("menu") ?? ""
        check(menu.contains("'mouse.context_menu'") && !menu.contains("'window.changed'") && !menu.contains("NOT IN"),
              "\"menu\": only rows of the kind whose wording says \"context-menu\"", menu)
        let window = MemorySearchQuery.templateCondition("window") ?? ""
        check(window.contains("'window.changed'") && window.contains("trim(ti,") && !window.contains("'mouse.click'"),
              "\"window\": only window rows with an empty title (\"a window\")", window)
        let results = MemorySearchQuery.templateCondition("submission") ?? ""
        check(results.contains("instr(u,'q=')>0") && results.contains("'window.changed'"), "\"submission\": only rows whose address carries a search", results)
        check(MemorySearchQuery.templateCondition("zebracorn") == nil, "a word no wording holds: its title, app or address only")
        check((MemorySearchQuery.templateCondition("omitted") ?? "").contains("GLOB '*[^A-Za-z]*'"), "\"omitted\": the rows whose title or app could be withheld")
        // Every kind the projections word on their own is one the template knows (a new kind must be added there).
        let sourceRoot=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let named = Set((try? String(contentsOf:sourceRoot.appendingPathComponent("Sources/MemoryCore/Actions.swift"), encoding: .utf8)).map(kindLiterals(inside: "public static func make(_ e:Evidence)")) ?? [])
            .union((try? String(contentsOf:sourceRoot.appendingPathComponent("Sources/MemoryCore/Models.swift"), encoding: .utf8)).map(kindLiterals(inside: "public static func write(_ evidence: Evidence")) ?? [])
        check(!named.isEmpty && named.isSubset(of: Set(MemorySearchQuery.templateKinds)), "every kind the projections name is in the template's kinds",
              "\(named.subtracting(MemorySearchQuery.templateKinds).sorted())")
    }

    /// The "kind.name" literals in the function that starts at `marker` (up to the next top-level declaration).
    static func kindLiterals(inside marker: String) -> (String) -> [String] {
        { source in
            guard let start = source.range(of: marker) else { return [] }
            let rest = source[start.upperBound...]
            let body = rest[..<(rest.range(of: "\n    public static func ")?.lowerBound ?? rest.endIndex)]
            let regex = try! NSRegularExpression(pattern: "\"([a-z]+\\.[a-z_]+)\"")
            return regex.matches(in: String(body), range: NSRange(body.startIndex..., in: body)).compactMap { Range($0.range(at: 1), in: body).map { String(body[$0]) } }
        }
    }

    static func fallbackISO(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

}
