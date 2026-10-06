import Foundation
private struct SearchCursor:Codable { var scope:String; var after:String }
/// The same time text `actions` compares against (fractional seconds, UTC).
/// Fixed-size opaque IDs in a bounded index-to-canonical continuation; no bodies.
private func searchSeenID(_ id:String) -> String {
    let hex=Array(fingerprint(id))
    return Data(stride(from:0,to:hex.count,by:2).map { UInt8(String(hex[$0...$0+1]),radix:16)! }).base64EncodedString()
}
private func fallbackTime(_ date:Date) -> String {
    let formatter=ISO8601DateFormatter(); formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
    return formatter.string(from:date)
}

public struct MemorySearchQuery {
    public var text: String
    public var app: String?
    public var start: Date?
    public var end: Date?
    public var limit: Int
    public var site:String?
    public var after:String?
    public init(_ text: String, app: String? = nil, start: Date? = nil, end: Date? = nil, limit: Int = 20, site:String?=nil, after:String?=nil) {
        self.text=text.prefixString(200); self.app=app.map { SearchDocument.bundle(forAlias:$0) ?? $0 }; self.start=start; self.end=end; self.limit=max(1,min(100,limit)); self.site=site?.lowercased(); self.after=after
    }
    /// Query words. Every word must match, in either backend: the index runs
    /// with drop_tokens_threshold 0, and the direct scan below does the same.
    /// Surrounding quotes and punctuation are ignored ("sync bug" -> sync, bug).
    public var words: [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’,;:()[]{}")) }
            .filter { !$0.isEmpty }
    }
    /// Case-, accent- and width-insensitive; each word may appear anywhere.
    func matchesWords(_ searchable: String) -> Bool {
        words.allSatisfy { searchable.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }
    }
    /// Metadata-only lexical recovery after ordinary substring/prefix matches.
    /// Every word remains required. Short words, numbers and identifiers never
    /// gain typo tolerance. Work per candidate is bounded independently of size.
    func lexicalScore(_ searchable:String) -> Int? {
        if matchesWords(searchable) { return 0 }
        let tokens=Self.lexicalTokens(searchable)
        var score=0
        for word in words {
            if searchable.range(of:word,options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive]) != nil { continue }
            let parts=Self.lexicalTokens(word)
            guard !parts.isEmpty else { return nil }
            for part in parts {
                let cap=Self.typoLimit(part)
                guard cap > 0 else { return nil }
                let distance=tokens.compactMap { Self.typoDistance(part,$0,limit:cap) }.min()
                guard let distance else { return nil }
                score += 10 + distance
            }
        }
        return score
    }
    var permitsTypos:Bool { words.contains { Self.lexicalTokens($0).contains { Self.typoLimit($0)>0 } } }
    private static func lexicalTokens(_ text:String) -> [String] {
        let folded=text.folding(options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive],locale:Locale(identifier:"en_US_POSIX"))
        // A mixed numeric token stays mixed, so e.g. invoice2026 cannot fuzzy-match
        // an adjacent year or turn its alphabetic fragment into a new token.
        return Array(folded.split { !$0.isLetter && !$0.isNumber }.prefix(512)).map(String.init)
    }
    private static func typoLimit(_ word:String) -> Int {
        guard (4...64).contains(word.count),word.allSatisfy(\.isLetter) else { return 0 }
        return word.count >= 8 ? 2 : 1
    }
    /// Banded optimal-string-alignment distance, including one adjacent swap.
    /// At most 64 characters, two edits and five columns per row are examined.
    private static func typoDistance(_ lhs:String,_ rhs:String,limit:Int) -> Int? {
        guard typoLimit(rhs)>0 else { return nil }
        let a=Array(lhs),b=Array(rhs),n=a.count,m=b.count
        guard abs(n-m)<=limit else { return nil }
        let far=limit+1
        var previous=Array(repeating:far,count:m+1),previousPrevious=previous
        for j in 0...min(m,limit) { previous[j]=j }
        for i in 1...n {
            var current=Array(repeating:far,count:m+1)
            if i<=limit { current[0]=i }
            let lower=max(1,i-limit),upper=min(m,i+limit)
            guard lower<=upper else { return nil }
            for j in lower...upper {
                current[j]=min(previous[j]+1,current[j-1]+1,previous[j-1]+(a[i-1]==b[j-1] ? 0 : 1))
                if i>1,j>1,a[i-1]==b[j-2],a[i-2]==b[j-1] { current[j]=min(current[j],previousPrevious[j-2]+1) }
            }
            if current.min()!>limit { return nil }
            previousPrevious=previous;previous=current
        }
        return previous[m]<=limit ? previous[m] : nil
    }
    /// The query's runs of ASCII letters and digits (lowercased). A row matches a word only if the word is in what
    /// search shows for it, so each run of the word is in the row's title, app or address, in the fixed wording search
    /// shows for a row of its kind (`templateCondition`), or in the words that stand in for a withheld title or app.
    /// Every run narrows the scan, a run of the fixed wording too (G27 review: "menu", "keyboard", "star", "window" and
    /// "search" read every row before).
    var filterRuns: [String] {
        var runs=Set<String>()
        for word in words {
            var run=""
            for scalar in (word.lowercased()+" ").unicodeScalars {
                if (scalar.value >= 0x61 && scalar.value <= 0x7a) || (scalar.value >= 0x30 && scalar.value <= 0x39) { run.unicodeScalars.append(scalar); continue }
                if !run.isEmpty { runs.insert(run) }
                run=""
            }
        }
        return runs.sorted()
    }
    /// ASCII control characters other than tab and newline (cleaning a title drops them, joining the text around).
    static let controlGlob="*["+String(String.UnicodeScalarView((Array(0x01...0x08)+Array(0x0b...0x1f)+[0x7f]).compactMap(Unicode.Scalar.init)))+"]*"
    /// claude/catchup-1003: characters beyond ASCII that no case, accent or width folding turns into a letter or a
    /// digit, and that search's wording keeps as they are (nothing drops them and joins the text around): terminal
    /// spinners and status marks, typographic quotes, dashes, bullets. A row whose only characters beyond ASCII are
    /// these is ruled in or out by its ASCII runs like any other row.
    static let inertScalars:[Character]=Array("◐◓◑◒✳✶✻✽✢⏺●○◉◯•·⋅…—–‘’“”«»→←↑↓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⠂⠐⠈⠁⠄⠠⠀✓✔✗✘★☆")
    /// Any character beyond ASCII that isn't inert (one GLOB class: neither ASCII nor one of `inertScalars`).
    static let foldableGlob="*[^\u{01}-\u{7f}"+String(inertScalars)+"]*"

    /// Rows the fixed wording treats alike: a kind it names (every `browser.` kind together: their wording turns on
    /// proofs the fields don't show), or "-" for every other kind; whether the title is empty; whether the address
    /// carries a search.
    struct TemplateCell: Hashable { var group:String; var emptyTitle:Bool; var search:Bool }
    /// The kinds the canonical projections word on their own ("-" stands for every other kind).
    static let templateKinds=["browser.observed","browser.extension_observed","browser.extension_tab_visited","message.sent","keyboard.submit",
                              "keyboard.text_input","selection.changed","terminal.value_changed","window.changed","window.observed","focus.observed",
                              "browser.snapshot","browser.tab_opened","browser.tab_visited","idle","mouse.click","mouse.context_menu","keyboard.shortcut",
                              "app.activated","session.started","session.ended","debug.error","conversation.assistant","conversation.user","-"]
    static func templateGroup(_ kind:String) -> String { kind.hasPrefix("browser.") ? "browser." : kind }
    /// What search shows in place of a withheld title or app (`Privacy.sanitized`, `SearchDocument.make`).
    static let withheldTitle="[sensitive title omitted]", withheldApp="[sensitive app omitted]"
    /// Everything the canonical projections write on their own, lowercased, per cell: made by running them on rows
    /// whose recorded fields hold only punctuation (each branch of the wording is reached), both ways search reads a
    /// row (as recorded, and as its search document, whose address keeps only the site).
    static let templateCells:[TemplateCell:String] = {
        var cells=[TemplateCell:Set<String>]()
        let at="2026-01-01T00:00:00Z"
        // The fields only take part through these: empty or not, an address with a search in it, Chrome's rows and
        // their proofs, a confirmed send or not, a synthetic row or not, typed words (one count per wording) or not.
        let sources:[(bundle:String,provider:String?)]=[("",nil),(BrowserSafety.supportedBundle,nil),(BrowserSafety.supportedBundle,BrowserSafety.pageProvider),
                                                        (BrowserSafety.supportedBundle,BrowserSafety.appTimeProvider),(BrowserSafety.supportedBundle,"chrome-native-bridge-v1")]
        for kind in templateKinds { for title in ["","-"] { for app in ["","-"] { for url in ["","https://-/","https://-/?q=-"] { for source in sources {
            for synthetic in kind.hasPrefix("browser.") ? [false,true] : [false] { for sent in kind == "message.sent" ? [false,true] : [false] {
                let cell=TemplateCell(group:templateGroup(kind),emptyTitle:title.isEmpty,search:url.contains("?q="))
                var e=Evidence(id:"-",at:at,kind:kind,app:app,bundle:source.bundle,title:title,url:url,synthetic:synthetic)
                e.browserVerification=source.provider.map { BrowserVerification(mode:"normal",windowID:"-",tabID:"-",focusedRole:"",checkedAt:at,provider:$0) }
                if sent { e.sendVerification=SendVerification(evidenceID:"-",messageID:"-",source:"native-delivery-receipt",confirmedAt:at) }
                let typed:[TypedRef?]=kind == "keyboard.text_input" ? [nil]+[-1,0,5,20,30,40,50,60,100].map { TypedRef(digest:"-",words:$0) } : [nil]
                for ref in typed {
                    e.typed=ref
                    cells[cell,default:[]].insert(ActionProjection.make(e).description)
                    var site=e; site.url=URL(string:e.url)?.host.map { "https://"+$0 } ?? ""
                    if site.url != e.url { cells[cell,default:[]].insert(ActionProjection.make(site).description) }
                }
            } }
        } } } } }
        return cells.mapValues { $0.sorted().joined(separator:"\n").lowercased() }
    }()
    /// All of the fixed wording, with the words for withheld text and corrections.
    static let templateText:String = ([withheldApp,withheldTitle,"user correction (not observed): "]+templateCells.values.sorted()).joined(separator:"\n").lowercased()

    /// The SQL condition under which the fixed wording search shows for a row can hold `run`, beside its title, app and
    /// address (nil: it never can). The subquery's columns: k (kind), ti (title), ap (app), u (address, lowercased).
    static func templateCondition(_ run:String) -> String? {
        // A title that cleans to nothing ("a window"); an address that can carry a search ("search results for").
        let emptyTitle="trim(ti,char(32,9,10,11,12,13))=''"
        let search="(instr(u,'q=')>0 OR instr(u,'query=')>0)"
        var byCondition=[String:[String]]()
        for group in Set(templateKinds.map(templateGroup)) {
            func holds(_ empty:Bool,_ withSearch:Bool) -> Bool { templateCells[TemplateCell(group:group,emptyTitle:empty,search:withSearch)]?.contains(run) == true }
            // Both title cases: "" (any title); one: that one; neither: nil.
            func title(_ empty:Bool,_ other:Bool) -> String? { empty && other ? "" : empty ? emptyTitle : other ? "NOT "+emptyTitle : nil }
            var parts=[String]()
            // Every row is read without a search (its search document keeps only the site); a row with a search is read with it too.
            if let plain=title(holds(true,false),holds(false,false)) {
                if plain.isEmpty { byCondition["1",default:[]].append(group); continue }
                parts.append(plain)
            }
            if let searched=title(holds(true,true),holds(false,true)) { parts.append(searched.isEmpty ? search : "("+search+" AND "+searched+")") }
            if !parts.isEmpty { byCondition[parts.joined(separator:" OR "),default:[]].append(group) }
        }
        let named=templateKinds.filter { $0 != "-" }
        var clauses=byCondition.sorted { $0.key < $1.key }.map { condition,groups -> String in
            var match=[String]()
            let kinds=named.filter { groups.contains(templateGroup($0)) }
            if !kinds.isEmpty { match.append("k IN ("+kinds.map { "'"+$0+"'" }.joined(separator:",")+")") }
            if groups.contains("-") { match.append("coalesce(k,'') NOT IN ("+named.map { "'"+$0+"'" }.joined(separator:",")+")") }
            let kind=match.count == 1 ? match[0] : "("+match.joined(separator:" OR ")+")"
            return condition == "1" ? kind : "("+kind+" AND ("+condition+"))"
        }
        // A withheld title or app shows words of its own: the rows whose title or app could be withheld.
        if withheldTitle.contains(run) { clauses.append(mayBeWithheld("ti")) }
        if withheldApp.contains(run) { clauses.append(mayBeWithheld("ap")) }
        return clauses.isEmpty ? nil : clauses.joined(separator:" OR ")
    }
    /// True for every value `Privacy.secret` withholds, as recorded or as cleaned (an app is checked cleaned: spaces
    /// joined, cut at 80 characters), and a few more. Pattern by pattern: a "password", "token" or "key" word with ':'
    /// or '='; a key's or token's opening; a private key's or a signed token's opening; 13 digits or more; 4 to 8
    /// digits alone; one word of 8 characters or more that isn't only letters. Values beyond ASCII or with control
    /// characters are always checked (`fallbackCandidates`), so these read ASCII.
    static func mayBeWithheld(_ v:String) -> String {
        let trimmed="trim(\(v),char(32,9,10,11,12,13))", lower="lower(\(v))"
        let digitsGone=(0...9).reduce(v) { "replace(\($0),'\($1)','')" }
        let labels=["passw","pwd","secret","token","key"].map { "instr(\(lower),'\($0)')>0" }.joined(separator:" OR ")
        let openings=["sk-","sk_live_","ghp_","github_pat_","xoxb-","xoxa-","xoxp-","akia","aiza","bearer"].map { "instr(\(lower),'\($0)')>0" }
        return "(" + (["((instr(\(v),':')>0 OR instr(\(v),'=')>0) AND (\(labels)))"] + openings
            + ["instr(\(v),'-----BEGIN')>0","instr(\(v),'eyJ')>0","length(\(v))-length(\(digitsGone))>=13",
               "(length(\(trimmed)) BETWEEN 4 AND 8 AND \(trimmed) NOT GLOB '*[^0-9]*')",
               "(length(\(trimmed))>=8 AND instr(\(trimmed),' ')=0 AND \(trimmed) GLOB '*[^A-Za-z]*')"]).joined(separator:" OR ") + ")"
    }
    func matches(_ item: MemoryItem) -> Bool {
        guard let at=timestamp(item.evidence.at) else { return false }
        return (app == nil || app == item.evidence.bundle || app == item.evidence.app) &&
            (site == nil || site == URL(string:item.evidence.url)?.host?.lowercased()) &&
            (start == nil || at >= start!) && (end == nil || at < end!)
    }
}
public struct MemorySearchResult: Codable {
    public var items: [MemoryItem]
    public var backend: String
    public var status: String
    public var partial: Bool
    public var next:String? = nil
    public var coverage:String = "Canonical metadata presentation only. Typed bodies unsupported. Generated summaries unsupported. URL-query observations are searchable in SQLite only, not Typesense."
    /// Direct scan only: the oldest action time checked before stopping early.
    public var scannedBackTo:String? = nil
}

/// Minimal derived projection. Raw typed text, URLs/queries and source bodies are NOT indexed.
struct SearchDocument: Codable, Equatable {
    var id: String
    var source_id: String
    var revision: String
    var summary: String
    var app: String
    var app_keys: [String]
    var site: String
    var at: Int64
    /// Known bundle IDs are metadata names, even when capitalization makes the
    /// generic credential heuristic match. Only the fixed app-name map receives
    /// this exemption; unknown/credential-shaped labels still use the mask.
    static func appLabel(_ app:String)->String {
        let name=AppNames.known[app] ?? app
        return Privacy.secret(name) ? "[sensitive app omitted]" : name
    }
    /// claude/catchup-1003: the names the app itself gives an app beside its own ("Texts" for Messages), so searching
    /// for what a card says finds that app's rows. Search wording and matching only; nothing shown changes.
    static let appAliases:[String:String]=["com.apple.MobileSMS":"Texts"]
    static func alias(bundle:String,app:String) -> String? {
        appAliases[bundle] ?? (app == "Messages" ? "Texts" : nil)
    }
    /// The bundle an alias names ("Texts" -> Messages), for an app filter.
    static func bundle(forAlias name:String) -> String? {
        appAliases.first { $0.value.caseInsensitiveCompare(name.trimmingCharacters(in:.whitespaces)) == .orderedSame }?.key
    }
    static func make(_ item: MemoryItem) -> Self? {
        var evidence=item.evidence
        evidence.text=""
        evidence.url=URL(string:evidence.url)?.host.map { "https://" + $0 } ?? ""
        let alias=Self.alias(bundle:evidence.bundle,app:evidence.app)
        evidence.app=Self.appLabel(evidence.app)
        let projected=ActionProjection.make(evidence)
        let summary=item.correction?.text.map { "User correction (not observed): "+$0 } ?? (projected.title.isEmpty ? projected.description : projected.title+". "+projected.description)
        guard let date=timestamp(evidence.at), !Privacy.secret(summary) else { return nil }
        // An alias joins the digest only where there is one, so only those rows are indexed again.
        let digest=fingerprint(ActionProjection.version + ((try? json(evidence)) ?? "") + ((try? json(item.correction)) ?? "") + (alias.map { "|alias:"+$0 } ?? ""))
        return Self(id:fingerprint(evidence.id),source_id:evidence.id,revision:digest,summary:summary,
                    app:evidence.app+(alias.map { " ("+$0+")" } ?? ""),app_keys:[fingerprint(evidence.bundle),fingerprint(evidence.app)]+(alias.map { [fingerprint($0)] } ?? []),
                    site:URL(string:evidence.url)?.host ?? "",at:Int64(date.timeIntervalSince1970))
    }
}

extension MemoryStore {
    /// App labels shaped like credentials use the same mask as SearchDocument.
    /// This changes search presentation/matching, never the canonical source.
    private func searchAppLabel(_ app:String)->String { SearchDocument.appLabel(app) }
    private func searchAppDescription(_ description:String,app:String,label:String)->String {
        return label==app || app.isEmpty ? description : description.replacingOccurrences(of:app,with:label)
    }
    func searchActionItem(_ id:String,now:Date) throws -> MemoryItem? {
        guard var item=try read(id,now:now) else { return nil }
        guard let action=try action(id,now:now) else { return nil }
        let label=searchAppLabel(item.evidence.app)
        item.evidence.app=label
        item.summary=searchAppDescription(action.description,app:action.app,label:label); item.actionState=action.state
        item.writer=ActionProjection.version; item.generatedAt=iso(now)
        return item
    }
    /// Shared app/CLI/MCP backend. No indexing or service start occurs on a search.
    /// UI callers use searchAsync; CLI callers retain the bounded synchronous interface.
    public func searchResult(_ query: MemorySearchQuery, now: Date = Date()) throws -> MemorySearchResult {
        if query.after != nil { return try fallbackSearch(query,now:now,status:"sqlite_continuation") }
        do {
            guard let config=try TypesenseConfiguration.load(home:home) else { return try fallbackSearch(query,now:now,status:"disabled") }
            return try indexedSearch(query,config:config,transport:LocalTypesenseHTTP(config,sync:false),now:now)
        } catch SearchFailure.changed { return MemorySearchResult(items:[],backend:"sqlite",status:"source_changed_retry",partial:true) }
        catch { return try fallbackSearch(query,now:now,status:"unavailable_fallback") }
    }
    public func searchAsync(_ query: MemorySearchQuery, completion: @escaping (Result<MemorySearchResult,Error>) -> Void) {
        DispatchQueue.global(qos:.userInitiated).async { completion(Result { try self.searchResult(query) }) }
    }
    /// The direct scan: all ordinary matches first, then typo matches, newest
    /// first within each tier. Every query word remains required in both tiers.
    ///
    /// SQLite first drops the rows that can't match, from the few fields a match can come from (title, app, address)
    /// and the fixed wording of the row's kind: each run of letters and digits in the query must appear in them
    /// (`MemorySearchQuery.filterRuns`, `templateCondition`). Rows those fields can't rule out (non-ASCII or control
    /// characters, a percent-encoded address, a user correction) are always checked. The exact check (`fallbackMatch`, the same as
    /// before) then decides each remaining row, so the scan reaches the whole history in about a second instead of
    /// a few hours of it. It stops after `fallbackBudget` seconds with a continuation (`next`) and never gives a
    /// partial answer as final. When the history changes under it (a deletion, a correction, a privacy change) it
    /// scans again, so a search never fails for that.
    ///
    /// SQLite reads the history a window at a time, newest first (`fallbackWindow` rows, found through the time
    /// index): each statement holds the store's lock, and SQLite's lock on the file, for tens of milliseconds, so the
    /// recorder's writes (the heartbeat, every save) go on between them. Before (gold G27 x G7, final review): one
    /// statement read until it had `fallbackPage` candidates, so a rare or missing word held both locks over the whole
    /// history (0.6 s at two months; at six months an AI app's search failed the recorder's saves with busy).
    func fallbackSearch(_ query: MemorySearchQuery, now: Date, status: String) throws -> MemorySearchResult {
        for _ in 0..<Self.fallbackAttempts {
            if let result=try fallbackScan(query,now:now,status:status) { return result }
        }
        throw SearchFailure.changed
    }
    /// A first-page preview of real direct matches only. It never starts or waits
    /// for Typesense, never scans the fuzzy tier, and uses the canonical privacy
    /// checks and read/policy fences of the ordinary fallback. This is provisional
    /// coverage; the final ranked search must re-read rather than retain these hits.
    public func directSearchPreview(_ query:MemorySearchQuery, now:Date=Date()) throws -> MemorySearchResult {
        guard query.after == nil else { throw MemError.invalid("Preview requires a first page") }
        guard let result=try fallbackScan(query,now:now,status:"direct_preview",budget:0.075,exactOnly:true) else {
            return MemorySearchResult(items:[],backend:"sqlite",status:"source_changed_retry",partial:true)
        }
        var preview=result
        preview.partial=true; preview.next=nil
        return preview
    }
    /// Re-read a preview's IDs alongside the final page under one disclosure
    /// fence. Local-only URL observations can survive a healthy index response,
    /// but stale/deleted/excluded or newly nonmatching rows cannot. Rebuild the
    /// canonical continuation after ranking so displaced index hits are not lost.
    public func reconcileDirectPreview(_ query:MemorySearchQuery, ids:[String], with page:MemorySearchResult, now:Date=Date()) throws -> MemorySearchResult {
        guard query.after == nil, ids.count <= 100, page.items.count <= 100 else { throw MemError.invalid("Invalid preview reconciliation") }
        let epoch=try actionReadEpoch(), privacy=try policy().revision
        var seen=Set<String>(), current=[MemoryItem]()
        for id in page.items.map(\.id)+ids where seen.insert(id).inserted {
            guard let item=try searchActionItem(id,now:now), query.matches(item),
                  let document=SearchDocument.make(item) else { continue }
            let text=localSearchable(item,projection:document)
            // Index hits retain their conservative typo recovery; a provisional
            // direct match must still match literally when the final page lands.
            if page.items.contains(where:{$0.id==id}) ? query.lexicalScore(text) != nil : query.matchesWords(text) { current.append(item) }
        }
        let scores=Dictionary(uniqueKeysWithValues:current.map { item in
            (item.id,SearchDocument.make(item).flatMap {query.lexicalScore(localSearchable(item,projection:$0))} ?? Int.max)
        })
        current.sort {
            let left=scores[$0.id] ?? Int.max,right=scores[$1.id] ?? Int.max
            if (left==0) != (right==0) {return left==0}
            let a=timestamp($0.evidence.at) ?? .distantPast,b=timestamp($1.evidence.at) ?? .distantPast
            return a == b ? $0.id > $1.id : a > b
        }
        current=Array(current.prefix(query.limit))
        var result=page; result.items=current
        if current.map(\.id) != page.items.map(\.id) {
            result.partial=true; result.next=try indexedContinuation(query,excluding:current)
        }
        guard try epoch == actionReadEpoch(), try privacy == policy().revision else {throw SearchFailure.changed}
        return result
    }
    static let fallbackAttempts=3
    /// Seconds one call may spend reading and checking rows.
    static let fallbackBudget:TimeInterval=2
    /// Candidates asked of SQLite at a time.
    static let fallbackPage=400
    /// Rows of history one SQLite statement may read past (every row at the window's oldest time too).
    static let fallbackWindow=2000

    /// claude/catchup-1003 (coordinator rule): the title ticks among the rows from `low` to `high` (inclusive), which
    /// search never returns: a title row whose title without its status glyphs is the one the previous title row of the
    /// same day showed (same app, same site), where either of the two carried a glyph. Day assembly drops exactly these
    /// rows (claude/title-spinner-1003 395b2cc `droppingTitleTicks`), so as hits they would belong to no moment. A row
    /// with a grouping edit or a correction always stays. Days are local to this Mac's time zone.
    func titleTicks(from low:String,to high:String) throws -> Set<String> {
        let kinds=Self.tickKinds.map { "'"+$0+"'" }.joined(separator:",")
        let fields="id,json_extract(body,'$.at'),coalesce(json_extract(body,'$.bundle'),''),coalesce(json_extract(body,'$.app'),''),coalesce(json_extract(body,'$.title'),''),coalesce(json_extract(body,'$.url'),'')"
        var rows=try self.rows("SELECT "+fields+" FROM records WHERE julianday(json_extract(body,'$.at'))>=julianday(?) AND julianday(json_extract(body,'$.at'))<=julianday(?)"
                               + " AND json_extract(body,'$.kind') IN ("+kinds+") ORDER BY julianday(json_extract(body,'$.at')),id",[low,high])
        guard rows.contains(where: { TitleClean.statusless($0[4]) != $0[4] }) else { return [] }
        let zone=TimeZone.current.identifier
        // The title row just before the range, on the same day, is the first row's "previous".
        if let first=rows.first, let start=timestamp(first[1]), let day=try? DayScope.key(start,timezone:zone),
           let dayStart=try? DayScope.interval(day:day,timezone:zone).start {
            let before=try self.rows("SELECT "+fields+" FROM records WHERE julianday(json_extract(body,'$.at'))<julianday(?) AND julianday(json_extract(body,'$.at'))>=julianday(?)"
                                     + " AND json_extract(body,'$.kind') IN ("+kinds+") ORDER BY julianday(json_extract(body,'$.at')) DESC,id DESC LIMIT 1",[low,iso(dayStart)])
            rows.insert(contentsOf:before,at:0)
        }
        let edited=Set(try self.rows("SELECT name FROM sqlite_master WHERE name='action_group_edits'").isEmpty ? [] : try self.rows("SELECT action_id FROM action_group_edits").map { $0[0] })
            .union(try hasMemoryControls() ? try self.rows("SELECT target FROM user_corrections WHERE kind='action'").map { $0[0] } : [])
        var ticks=Set<String>(), last:(key:String,glyph:Bool,day:String)?
        for row in rows {
            let title=TitleClean.statusless(row[4]), glyph=title != row[4]
            let day=timestamp(row[1]).flatMap { try? DayScope.key($0,timezone:zone) } ?? ""
            let site=URL(string:row[5])?.host?.lowercased() ?? ""
            let key=[row[2].isEmpty ? row[3] : row[2],title,site].joined(separator:"\u{1F}")
            if let last, last.day == day, last.key == key, last.glyph || glyph, !edited.contains(row[0]) { ticks.insert(row[0]) }
            last=(key,glyph,day)
        }
        return ticks
    }
    static let tickKinds=["window.changed","window.observed","focus.observed"]
    /// Kinds whose search match depends only on the row's own body (no typed words, sends, page proofs or joins).
    static let shapeKinds=["window.changed","window.observed","focus.observed","app.activated"]
    private struct FallbackPosition: Codable { var at:String; var id:String; var fence:Int64; var fuzzy:Bool? = nil; var excluding:[String]? = nil }

    /// nil: the history changed while scanning; the caller scans again.
    private func fallbackScan(_ query: MemorySearchQuery, now: Date, status: String, budget:TimeInterval=MemoryStore.fallbackBudget, exactOnly:Bool=false) throws -> MemorySearchResult? {
        let before=try actionReadEpoch(), policyBefore=try policy().revision
        let scope=fingerprint("\(query.text)|\(query.app ?? "")|\(query.site ?? "")|\(query.start?.timeIntervalSince1970 ?? 0)|\(query.end?.timeIntervalSince1970 ?? 0)")
        var position:FallbackPosition
        if let after=query.after {
            guard after.utf8.count < 8192, let data=Data(base64Encoded:after), let value=try? JSONDecoder().decode(SearchCursor.self,from:data), value.scope == scope,
                  let saved=try? JSONDecoder().decode(FallbackPosition.self,from:Data(value.after.utf8)) else { throw MemError.invalid("Invalid search continuation") }
            position=saved
        } else {
            position=FallbackPosition(at:"9999-12-31T00:00:00Z",id:"\u{10ffff}",fence:Int64(try rows("SELECT coalesce(max(rowid),0) FROM records").first!.first!) ?? 0)
        }
        let excluded=Set(position.excluding ?? [])
        guard excluded.count<=100,excluded.allSatisfy({ Data(base64Encoded:$0)?.count==32 }) else { throw MemError.invalid("Invalid search continuation") }
        let words=query.words, corrections=try hasMemoryControls()
        let deadline=Date().addingTimeInterval(budget)
        let floor=query.start.map(fallbackTime) ?? "0001-01-01T00:00:00Z", end=query.end.map(fallbackTime) ?? "9999-12-31T00:00:00Z"
        var items=[MemoryItem](), oldest:String?, exhausted=false
        var turnedDown=Set<String>(), fuzzyTurnedDown=Set<String>()
        scan: while true {
            // This window: from the position down to the time of the `fallbackWindow`th row below it (nil: the start).
            let bound=try rows("SELECT json_extract(body,'$.at') FROM records WHERE julianday(json_extract(body,'$.at'))<julianday(?)"
                               + " AND julianday(json_extract(body,'$.at'))<julianday(?) AND julianday(json_extract(body,'$.at'))>=julianday(?)"
                               + " ORDER BY julianday(json_extract(body,'$.at')) DESC LIMIT 1 OFFSET ?",
                               [position.at,end,floor,String(Self.fallbackWindow)]).first?.first
            // Exact/prefix rows across the whole scope precede every fuzzy row,
            // including across pages. Fuzzy recovery must not use the exact SQL
            // prefilter: it would discard the very misspellings being recovered.
            let fuzzy=position.fuzzy == true
            let page=try fallbackCandidates(query,runs:fuzzy ? [] : query.filterRuns,corrections:corrections,from:position,down:bound ?? floor,end:end,limit:Self.fallbackPage)
            let ticks=try page.isEmpty ? [] : titleTicks(from:page.last![1],to:position.at)
            for (index,row) in page.enumerated() {
                position.id=row[0]; position.at=row[1]; oldest=row[1]
                do {
                    let shape=row.count > 2 ? row[2] : ""
                    if ticks.contains(row[0]) {}
                    else if !shape.isEmpty, (fuzzy ? fuzzyTurnedDown : turnedDown).contains(shape) {}
                    else if (excluded.isEmpty || !excluded.contains(searchSeenID(row[0]))) {
                        if let item=try fallbackMatch(row[0],query:query,words:words,now:now,fuzzyOnly:fuzzy) { items.append(item) }
                        else if !shape.isEmpty { if fuzzy { fuzzyTurnedDown.insert(shape) } else { turnedDown.insert(shape) } }
                    }
                } catch {
                    // A read that saw the history change mid-way: scan again rather than fail the search.
                    if try before != actionReadEpoch() || policyBefore != policy().revision { return nil }
                    throw error
                }
                if items.count >= query.limit || Date() >= deadline {
                    exhausted=index == page.count-1 && page.count < Self.fallbackPage && bound == nil
                    if exhausted && !exactOnly && !fuzzy && query.permitsTypos {
                        position=FallbackPosition(at:"9999-12-31T00:00:00Z",id:"\u{10ffff}",fence:position.fence,fuzzy:true,excluding:position.excluding)
                        exhausted=false
                    }
                    break scan
                }
            }
            if page.count < Self.fallbackPage {
                // Every row of this window was read: the next starts below its oldest time.
                if let bound { position.at=bound; position.id=""; oldest=bound }
                else if !exactOnly && !fuzzy && query.permitsTypos {
                    position=FallbackPosition(at:"9999-12-31T00:00:00Z",id:"\u{10ffff}",fence:position.fence,fuzzy:true,excluding:position.excluding)
                    oldest=nil
                } else { exhausted=true; break }
            }
            if Date() >= deadline { break }
        }
        guard try before == actionReadEpoch(), try policyBefore == policy().revision else { return nil }
        let next=try exhausted ? nil : Data(try json(SearchCursor(scope:scope,after:String(decoding:try JSONEncoder().encode(position),as:UTF8.self))).utf8).base64EncodedString()
        return MemorySearchResult(items:items,backend:"sqlite",status:status,partial:next != nil,next:next,scannedBackTo:next == nil ? nil : oldest)
    }

    /// The rows after `position` (newest first) that could match: each of the query's filter runs appears in the
    /// title, app or address, or in the fixed wording of a row like this one (its kind, an empty title, a search in
    /// its address, a withheld title or app), or those fields can't rule the row out. A superset of what
    /// `fallbackMatch` accepts.
    /// Only rows at or after `down` (a window's oldest time, or the query's start) and before `end`, through the time
    /// index, so the statement reads no more than its window.
    private func fallbackCandidates(_ query:MemorySearchQuery, runs:[String], corrections:Bool, from position:FallbackPosition, down:String, end:String, limit:Int) throws -> [[String]] {
        // claude/catchup-1003: a window row's shape (its body without its id and time). Rows of the same shape read and
        // match alike, so once one is turned down the scan skips the rest without reading them (a window's repeated
        // title changes). Only window/focus/app rows, never one with a user correction.
        // Built in steps: Swift 6.2's type checker times out on the one long expression.
        let kinds:String=MemoryStore.shapeKinds.map { "'"+$0+"'" }.joined(separator:",")
        var shape:String="CASE WHEN json_extract(body,'$.kind') IN ("+kinds+")"
        if corrections { shape += " AND id NOT IN (SELECT target FROM user_corrections WHERE kind='action')" }
        shape += " THEN json_remove(body,'$.id','$.at') ELSE '' END"
        // The shape is read only for the rows the filter keeps (outer select), so each window's statement costs no more.
        var sql="SELECT id,at,"+shape+" FROM (SELECT id,body,json_extract(body,'$.at') AS at,julianday(json_extract(body,'$.at')) AS jd"
        if !runs.isEmpty {
            let aliases=SearchDocument.appAliases.map { "WHEN json_extract(body,'$.bundle')='"+$0.key+"' THEN char(10)||'"+$0.value.lowercased()+"'" }.joined(separator:" ")
            sql += ",lower(coalesce(json_extract(body,'$.title'),'')||char(10)||coalesce(json_extract(body,'$.app'),'')||char(10)||coalesce(json_extract(body,'$.url'),''))"
            sql += "||CASE "+aliases+" WHEN json_extract(body,'$.app')='Messages' THEN char(10)||'texts' ELSE '' END AS t"
            sql += ",json_extract(body,'$.kind') AS k,coalesce(json_extract(body,'$.title'),'') AS ti,coalesce(json_extract(body,'$.app'),'') AS ap"
            sql += ",lower(coalesce(json_extract(body,'$.url'),'')) AS u"
        }
        // After the position (older, or as old with a smaller id), written so the time index bounds it on both sides.
        sql += " FROM records WHERE rowid<=? AND julianday(json_extract(body,'$.at'))<=julianday(?) AND (julianday(json_extract(body,'$.at'))<julianday(?) OR id<?)"
        sql += " AND julianday(json_extract(body,'$.at'))>=julianday(?) AND julianday(json_extract(body,'$.at'))<julianday(?)"
        sql += " AND (?='' OR json_extract(body,'$.app')=? OR json_extract(body,'$.bundle')=?))"
        var values=[String(position.fence),position.at,position.at,position.id,down,end,
                    query.app ?? "",query.app ?? "",query.app ?? ""]
        if !runs.isEmpty {
            sql += " WHERE (" + runs.map { run in MemorySearchQuery.templateCondition(run).map { "(instr(t,?)>0 OR "+$0+")" } ?? "instr(t,?)>0" }.joined(separator:" AND ") + ")"
            values += runs
            // What the fields can't rule out: letters beyond ASCII (accents, width and case folding), control
            // characters (cleaning drops them and joins the text around them), a percent-encoded search in the
            // address (it is shown decoded), and a user correction (its words replace the description).
            // claude/catchup-1003: symbols that never fold to a letter or digit (a terminal tool's spinner, quotes,
            // dashes) don't count as letters beyond ASCII: Claude Code's "◐ …" / "◑ …" window titles were thousands of
            // rows a night, each read and checked one by one, so a 2-second scan reached only a few hours back.
            sql += " OR t GLOB ? OR instr(t,'%')>0 OR t GLOB ?"
            values.append(MemorySearchQuery.foldableGlob); values.append(MemorySearchQuery.controlGlob)
            if corrections { sql += " OR id IN (SELECT target FROM user_corrections WHERE kind='action')" }
        }
        sql += " ORDER BY jd DESC,id DESC LIMIT ?"
        values.append(String(limit))
        return try rows(sql,values)
    }

    /// One permitted canonical row and its filters. The fuzzy tier accepts only
    /// rows the exact tier did not accept, preventing repeats across continuation.
    /// Typed bodies and generated notes never match.
    func fallbackMatch(_ id:String, query:MemorySearchQuery, words:[String], now:Date, fuzzyOnly:Bool=false) throws -> MemoryItem? {
        guard let action=try action(id,now:now), query.app == nil || query.app == action.app || query.app == action.bundle else { return nil }
        // Cheap superset check on the canonical action first.
        if !words.isEmpty && !fuzzyOnly {
            let label=searchAppLabel(action.app)
            let rough=[action.title,searchAppDescription(action.description,app:action.app,label:label),searchAppDescription(action.observedDescription ?? "",app:action.app,label:label),label,action.site,
                       "Viewed","[sensitive app omitted]",SearchDocument.alias(bundle:action.bundle,app:action.app) ?? ""].joined(separator:" ")
            guard query.matchesWords(rough) else { return nil }
        }
        if let site=query.site, site != action.site.lowercased() { return nil }
        guard let item=try searchActionItem(action.id,now:now), query.matches(item), let projection=SearchDocument.make(item) else { return nil }
        // Preserve existing local lookup of permitted search observations.
        // No typed body is added, and the Typesense projection stays stricter.
        let searchable=localSearchable(item,projection:projection)
        // Every word must appear somewhere, not the whole query as one phrase.
        if fuzzyOnly { return query.lexicalScore(searchable).map { $0 > 0 ? item : nil } ?? nil }
        return words.isEmpty || query.matchesWords(searchable) ? item : nil
    }
    private func localSearchable(_ item:MemoryItem,projection:SearchDocument) -> String {
        var metadata=item.evidence; metadata.text="";metadata.app=projection.app
        return ActionProjection.make(metadata).description+" "+projection.summary+" "+projection.app+" "+projection.site
    }
    /// Healthy index pages continue through the full canonical scope, skipping
    /// only IDs already returned. This also covers permitted SQLite-only query
    /// observations and an unfinished recent merge without losing more history.
    private func indexedContinuation(_ query:MemorySearchQuery,excluding:[MemoryItem]) throws -> String {
        let scope=fingerprint("\(query.text)|\(query.app ?? "")|\(query.site ?? "")|\(query.start?.timeIntervalSince1970 ?? 0)|\(query.end?.timeIntervalSince1970 ?? 0)")
        let fence=Int64(try rows("SELECT coalesce(max(rowid),0) FROM records").first!.first!) ?? 0
        let position=FallbackPosition(at:"9999-12-31T00:00:00Z",id:"\u{10ffff}",fence:fence,excluding:excluding.map { searchSeenID($0.id) })
        let cursor=SearchCursor(scope:scope,after:String(decoding:try JSONEncoder().encode(position),as:UTF8.self))
        let next=Data(try json(cursor).utf8).base64EncodedString()
        guard next.utf8.count<8192 else { throw SearchFailure.response }
        return next
    }
    func indexedSearch(_ query: MemorySearchQuery, config: TypesenseConfiguration, transport: TypesenseTransport, now: Date) throws -> MemorySearchResult {
        let before=try disclosureRevision(), epoch=try actionReadEpoch(), policyBefore=try policy().revision
        let deadline=Date().addingTimeInterval(0.6)
        var filters=[String]()
        if let app=query.app { filters.append("app_keys:="+fingerprint(app)) }
        if let site=query.site {
            guard site.range(of:"^[a-z0-9.-]{1,253}$",options:.regularExpression) != nil else { throw MemError.invalid("Exact hostname required") }
            filters.append("site:=`"+site+"`")
        }
        if let start=query.start { filters.append("at:>=\(Int64(start.timeIntervalSince1970))") }
        if let end=query.end { filters.append("at:<\(Int64(end.timeIntervalSince1970))") }
        let response=try transport.request("GET","/collections/\(config.collection)/documents/search",query:[
            URLQueryItem(name:"q",value:query.text.isEmpty ? "*" : query.text),
            URLQueryItem(name:"query_by",value:"summary,app,site"),
            URLQueryItem(name:"query_by_weights",value:"4,2,1"),
            URLQueryItem(name:"num_typos",value:"2"),
            URLQueryItem(name:"min_len_1typo",value:"4"),
            URLQueryItem(name:"min_len_2typo",value:"8"),
            URLQueryItem(name:"enable_typos_for_numerical_tokens",value:"false"),
            URLQueryItem(name:"enable_typos_for_alpha_numerical_tokens",value:"false"),
            URLQueryItem(name:"split_join_tokens",value:"off"),
            URLQueryItem(name:"prioritize_exact_match",value:"true"),
            URLQueryItem(name:"drop_tokens_threshold",value:"0"),
            URLQueryItem(name:"sort_by",value:"_text_match:desc,at:desc"),
            URLQueryItem(name:"include_fields",value:"source_id,revision"),
            URLQueryItem(name:"highlight_fields",value:"none"),
            URLQueryItem(name:"per_page",value:"100"),
            URLQueryItem(name:"filter_by",value:filters.joined(separator:" && ")),
            URLQueryItem(name:"enable_analytics",value:"false"),
            URLQueryItem(name:"use_cache",value:"false")],body:nil,deadline:deadline)
        guard response.status == 200, let root=try JSONSerialization.jsonObject(with:response.data) as? [String:Any],
              let hits=root["hits"] as? [[String:Any]], hits.count <= 100 else { throw SearchFailure.response }
        // Always consult the canonical last ten seconds, including while a healthy
        // index is behind. This is not a second persistence or search-index store.
        let recent=try fallbackSearch(MemorySearchQuery(query.text,app:query.app,start:max(query.start ?? .distantPast,now.addingTimeInterval(-10)),end:query.end,limit:query.limit,site:query.site),now:now,status:"recent_database")
        var items=recent.items
        var seen=Set(items.map(\.id)), rejected=false
        for hit in hits {
            guard let doc=hit["document"] as? [String:Any], let id=doc["source_id"] as? String,
                  id.count <= 200, let revision=doc["revision"] as? String else { throw SearchFailure.response }
            guard seen.insert(id).inserted else { continue }
            guard let item=try searchActionItem(id,now:now), let current=SearchDocument.make(item), current.revision == revision,
                  query.matches(item), config.syntheticOnly != true || item.evidence.synthetic,
                  query.lexicalScore(current.summary+" "+current.app+" "+current.site) != nil else { rejected=true; continue }
            items.append(item)
        }
        // A recent fuzzy row must not outrank an older exact index hit. Rank
        // only canonical metadata; neither server snippets nor bodies are read.
        let ranks=Dictionary(uniqueKeysWithValues:items.map { item -> (String,Int) in
            let score=SearchDocument.make(item).flatMap { query.lexicalScore(localSearchable(item,projection:$0)) } ?? Int.max
            return (item.id,score)
        })
        items.sort {
            let left=ranks[$0.id] ?? 0,right=ranks[$1.id] ?? 0
            if (left==0) != (right==0) { return left==0 }
            let a=timestamp($0.evidence.at) ?? .distantPast,b=timestamp($1.evidence.at) ?? .distantPast
            if a != b { return a>b }
            return $0.id > $1.id
        }
        items=Array(items.prefix(query.limit))
        guard try epoch == actionReadEpoch(), try policyBefore == policy().revision,
              try TypesenseConfiguration.load(home:home) == config else { throw SearchFailure.changed }
        // Never surface Typesense snippets, stored source bodies or unvalidated hit counts.
        let caughtUp=try before == disclosureRevision() && rows("SELECT body FROM metadata WHERE id='search_complete_revision'").first?.first == before && rows("SELECT body FROM metadata WHERE id='search_projection_version'").first?.first == ActionProjection.version
        // The local metadata path preserves permitted URL search observations,
        // while SearchDocument deliberately strips the URL query. A caught-up
        // index and complete last-ten-seconds merge cannot prove a text query's
        // full canonical scope exhausted: older local-only matches can remain.
        // Always offer canonical continuation for text, even with zero hits.
        let requiresCanonicalCoverage = !query.words.isEmpty
        let partial = requiresCanonicalCoverage || !caughtUp || rejected || recent.partial || (root["found"] as? Int ?? 0) > items.count
        let next=try partial ? indexedContinuation(query,excluding:items) : nil
        guard try epoch == actionReadEpoch(),try policyBefore == policy().revision else { throw SearchFailure.changed }
        return MemorySearchResult(items:items,backend:"typesense",status:rejected ? "stale_hits_removed" : caughtUp ? "ready" : "catching_up",
                                  partial:partial,next:next)
    }
}
