import Foundation
import MemoryCore

/// What other AI apps read over MCP: the catalog text, search wording and
/// matching, and the day and moment pages. Uses the real clock because
/// searchReport, like every MCP read, hides evidence dated after it.
func runAssistantChecks(home: URL) throws {
    // Catalog: distinct, read-only, and short enough for a system context.
    let tools = AssistantCatalog.toolList()
    // claude/summary-1003 (owner decision 2026-10-03): moment_details added last; it alone carries typed words, gated in the app.
    try check(tools.compactMap { $0["name"] as? String } == ["status","context","search","read","open","recall","current-context","recap","moment_details"],"assistant catalog keeps tool names and order (moment_details added last)")
    let descriptions = tools.compactMap { $0["description"] as? String }
    try check(Set(descriptions).count == 9 && descriptions.allSatisfy { $0.count >= 150 },"every tool has its own description")
    try check(tools.allSatisfy { ($0["annotations"] as? [String:Any])?["readOnlyHint"] as? Bool == true },"every tool is marked read-only")
    let catalogText = ([AssistantCatalog.instructions] + descriptions).joined(separator:"\n")
    try check(AssistantCatalog.instructions.count <= 2200 && AssistantCatalog.instructions.contains("what did I do") && AssistantCatalog.instructions.contains("macmem://days/today.json"),"server instructions say when to use DayDream and where day recaps start")
    // Honesty track (H1): the line now also says other browsers are not recorded, and names
    // no Chrome pages at all in a release built without them (ReleaseFeatures).
    try check(AssistantCatalog.instructions.count <= 2200
              && AssistantCatalog.instructions.contains(ReleaseFeatures.chromePageHistory ? "Chrome pages (title and site, if turned on; other browsers are not recorded)" : "(web browsers are not recorded)")
              && !AssistantCatalog.instructions.contains("documents and websites were in front"),
              "server instructions name Chrome pages (title and site, if turned on) and no other websites, within 2200 characters")
    try runConciseFormatChecks(tools:tools)
    func pageLine(_ bundle:String, app:String, site:String, title:String) throws -> String {
        let value:[String:Any]=["id":"p","evidenceIDs":[],"at":"2026-09-22T08:00:00Z","kind":"window.changed","app":app,"bundle":bundle,"site":site,
                                "title":title,"description":"","state":"observed","revision":"fixture","subject":"","observationKey":"p"]
        return AssistantView.line(try JSONDecoder().decode(CanonicalAction.self, from: JSONSerialization.data(withJSONObject:value)))
    }
    try check(try pageLine("com.google.Chrome", app:"Google Chrome", site:"github.com", title:"Pull requests") == "Google Chrome page “Pull requests” (github.com)",
              "an AI app reads a Chrome page as its title and site")
    try check(try pageLine("com.google.Chrome", app:"Google Chrome", site:"google.com", title:"") == "Google Chrome page on google.com (title not kept)",
              "an AI app reads a site-only Chrome page as its site, title not kept")
    try check(try pageLine("com.apple.Notes", app:"Notes", site:"", title:"List") == "Notes window “List”", "other apps keep the window line")
    try check(!AssistantView.privacy.contains("Chrome"), "the base privacy line is unchanged")
    try check(!catalogText.contains("not established") && !catalogText.contains("Observations"),"catalog text carries no internal wording")
    // Typing-all decision 4 superseded by owner decision 2026-10-03: AI apps read typed words only through moment_details
    // (and search's typed hits), from the running app, while "Let AI apps see your typed words" is on. Every other tool
    // still never returns them, and the text says the words depend on the person's choice.
    let desc = Dictionary(uniqueKeysWithValues: tools.compactMap { t in (t["name"] as? String).map { ($0, t["description"] as? String ?? "") } })
    try check(!catalogText.contains("allowed this app") && AssistantCatalog.instructions.contains("(the words only if allowed)")
              && desc["read"]?.contains("for the typed words use moment_details") == true && desc["recall"]?.contains("never typed words") == true
              && desc["recap"]?.contains("Never returns typed words") == true
              && desc["moment_details"]?.contains("when they allowed AI apps to read them") == true && desc["moment_details"]?.contains("Passwords, secrets") == true
              && desc["search"]?.contains("When the person allows AI apps to read what they typed") == true,
              "catalog text: typed words only through moment_details and search, only when the person allows it")
    try check(AssistantCatalog.negotiatedVersion("2024-11-05") == "2024-11-05" && AssistantCatalog.negotiatedVersion("1999-01-01") == AssistantCatalog.protocolVersions[0],"protocol version echoes a supported request, else the newest")
    try check(MemorySearchQuery("\u{201C}sync bug\u{201D}  tallybird,").words == ["sync","bug","tallybird"],"query words ignore quotes, punctuation and extra spaces")
    try check(!AssistantCatalog.protocolVersions.contains("2025-03-26") && AssistantCatalog.negotiatedVersion("2025-03-26") == "2025-06-18","2025-03-26 (JSON-RPC batches required) is not offered")
    try check(AssistantCatalog.resources.first { $0["name"] == "context" }?["mimeType"] == "text/plain","the context resource is listed as text/plain, as resources/read returns it")
    try check(!AssistantCatalog.instructions.contains("stays on this Mac") && AssistantCatalog.instructions.contains("aren't verified") && !AssistantView.privacy.contains("only on this Mac"),
              "privacy and note wording hold with a cloud writer: no \"stays on this Mac\", notes are not verified")
    let labelled = try JSONDecoder().decode(GeneratedNote.self, from: Data(#"{"id":"n","version":1,"schemaVersion":1,"generatedAt":"2026-01-01T00:00:00Z","inputRevision":"r","actionIDs":["a","b","c","d"],"status":"generated_unverified","output":{"requestID":"q","title":"Reply to Priya","generator":"local/qwen3.5-4b-q4_k_m","generatorVersion":"v","bullets":[{"text":"Drafted a reply to Priya; sending isn't confirmed.","actionIDs":["a"],"assertion":"draft"},{"text":"Claude reported the tests pass; not verified.","actionIDs":["b"],"assertion":"reported"},{"text":"You plan to ship on Monday.","actionIDs":["c"],"assertion":"interpretation"},{"text":"Slack confirmed a message was sent.","actionIDs":["d"],"assertion":"sent"}]}}"#.utf8))
    try check(AssistantView.note(labelled)?.points == ["Wrote a reply to Priya.","(reported) Claude reported the tests pass; not verified.","(interpretation) You plan to ship on Monday.","Slack confirmed a message was sent."],
              "note points tell the reading model which are reports and interpretations, and never say draft")

    // Fixture on a day that cannot straddle midnight in the chosen zone.
    let now = Date()
    let zone = ["UTC","Etc/GMT-12"].first { name in
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(identifier:name)!
        return now.timeIntervalSince(calendar.startOfDay(for:now)) > 3600
    }!
    let store = try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
    _ = try attachTestVault(store)
    var consent = try store.policy(); consent.captureText = true; try store.updatePolicy(consent,now:now)
    var seconds = 400.0
    func event(_ id:String,_ kind:String,_ app:String,_ bundle:String,_ title:String,text:String="") -> Evidence {
        seconds -= 1
        return Evidence(id:id,at:iso(now.addingTimeInterval(-seconds)),kind:kind,app:app,bundle:bundle,title:title,text:text,synthetic:true)
    }
    var fixture = [event("a-mail","window.changed","Mail","com.apple.mail","Re: sync bug from Priya"),
                   event("a-zed","window.changed","Zed","dev.zed.Zed","SyncEngine.swift \u{2014} tallybird"),
                   event("a-typed","keyboard.text_input","com.apple.Notes","com.apple.Notes","Standup",text:"standup draft for the team")]
    // Many newer actions, so the one match for "priya" sits deep in the scan.
    for n in 0..<300 { fixture.append(event("a-fill-\(n)","mouse.click","TextEdit","com.apple.TextEdit","Filler document")) }
    // A late moment whose actions all come after the day's first page.
    for n in 0..<25 { fixture.append(event("a-late-\(n)","mouse.click","Pages","com.apple.iWork.Pages","Release checklist")) }
    for e in fixture { _ = try store.ingest(e,now:now) }

    // Search: every word must match, anywhere, in either order.
    let found = try store.searchReport(MemorySearchQuery("tallybird SyncEngine"))
    try check(found.hits.map { $0["id"] } == ["a-zed"] && found.status == "basic" && !found.partial,"multi-word search matches words anywhere, and reports basic, not disabled (\(found.hits.map { $0["id"] ?? "" }) \(found.status) partial \(found.partial))")
    let none = try store.searchReport(MemorySearchQuery("sync bug tallybird"))
    try check(none.hits.isEmpty && !none.partial && none.note?.contains("fewer words") == true,"no single action with every word says to use fewer words")
    let deep = try store.searchReport(MemorySearchQuery("priya"))
    try check(deep.hits.map { $0["id"] } == ["a-mail"] && !deep.partial,"search reaches an old match past hundreds of newer actions")
    try check(try store.searchReport(MemorySearchQuery("team")).hits.isEmpty,"typed text is not searchable")
    let typed = try store.searchReport(MemorySearchQuery("",app:"com.apple.Notes"))
    try check(typed.hits.first?["app"] == "Notes" && typed.hits.first?["snippet"]?.hasPrefix("Typed in Notes") == true,"typed text shows the app name, not its bundle id")
    let snippets = (found.hits + deep.hits + typed.hits).compactMap { $0["snippet"] }.joined(separator:"\n")
    try check(!snippets.isEmpty && !snippets.contains("not established") && !snippets.contains("macmem://") && !snippets.contains("com.apple"),"search snippets are plain words")
    try check(found.hits.first?["when"]?.isEmpty == false && found.timezone != nil,"search hits carry local time and the zone")
    let item = try store.assistantItem("a-typed",now:now)
    // Rewritten for safe typing: AI apps see where and about how much was
    // typed, never the words (they are sealed; MCP has no key).
    try check(item?["text"] == nil && item?["text_is"] == nil && item?["app"] == "Notes" && item?["snippet"] == "Typed in Notes, a sentence (exact words not shared with AI apps)","read shows who typed, the app and a word bucket, never the typed words")
    try check(!(try json(item ?? [:])).contains("standup draft") && !(try json(store.searchReport(MemorySearchQuery("",app:"com.apple.Notes")))).contains("standup draft"),"no MCP read or search reply carries the typed words")
    try check(try store.hydrateTypedText("a-typed",disclosure:.summary,now:now) == nil && store.hydrateTypedText("a-typed",disclosure:.owner,now:now) == "standup draft for the team","summary disclosure never opens words; the owner can")
    // Summary-only case, for a connected app (safe typing G): the default grant has no exact words.
    let token = try store.grant(client:"claude-code",recipient:"local",scopes:["context","search","detail"])
    let allowed = TypedReader(client:"claude-code",recipient:"local",capability:token)
    let connected = try store.assistantItem("a-typed",now:now,reader:allowed)
    try check(connected?["text"] == nil && connected?["typing_note"] == nil && connected?["snippet"] == "Typed in Notes, a sentence (exact words not shared with AI apps)","a connected app without the exact-words permission reads a summary")
    // Exact-with-grant case: a separate owner action, only where the key is (the DayDream app).
    try check(try store.grantTypedWords(client:"claude-code",recipient:"local") == .granted,"the owner allows exact words for one app")
    let exact = try store.assistantItem("a-typed",now:now,reader:allowed)
    try check(exact?["text"] == "standup draft for the team" && exact?["text_is"] == TypedAccessText.exactTextIs && exact?["snippet"] == "Typed in Notes: \u{201C}standup draft for the team\u{201D}","read shows the exact words to the allowed app, in the app process")
    try check(try store.assistantItem("a-typed",now:now)?["text"] == nil && store.assistantItem("a-typed",now:now,reader:TypedReader(client:"other",recipient:"local",capability:token))?["text"] == nil,"without that app's grant, read stays a summary")
    let mcpProcess = try MemoryStore(home:home)
    let viaMCP = try mcpProcess.assistantItem("a-typed",now:now,reader:allowed)
    try check(viaMCP?["text"] == nil && viaMCP?["typing_note"] == TypedAccessText.appOnly && !(try json(viaMCP ?? [:])).contains("standup draft"),"the MCP process (no key) gives even the allowed app a summary and says where the words are")
    try store.revokeTypedWords(client:"claude-code",recipient:"local")
    try check(try store.assistantItem("a-typed",now:now,reader:allowed)?["text"] == nil,"turning exact words off returns the app to summaries")
    try store.revoke(client:"claude-code",recipient:"local")

    // Day pages: today/yesterday resolve in the link's zone; the overview is MCP-only.
    func object(_ body:String) throws -> [String:Any] { try JSONSerialization.jsonObject(with:Data(body.utf8)) as? [String:Any] ?? [:] }
    let day = try DayScope.key(now,timezone:zone)
    let today = try object(store.openActionResource("macmem://days/today.json?timezone=\(zone)",now:now,assistant:true))
    let overview = today["overview"] as? [String:Any] ?? [:]
    let moments = overview["moments"] as? [[String:Any]] ?? []
    try check(overview["date"] as? String == day && moments.count >= 3,"today.json opens the current day with its moments")
    let yesterday = try object(store.openActionResource("macmem://days/yesterday.json?timezone=\(zone)",now:now,assistant:true))
    try check((yesterday["overview"] as? [String:Any])?["date"] as? String == (try DayScope.key(now.addingTimeInterval(-86400),timezone:zone)),"yesterday.json opens the previous day")
    try check(try !store.openActionResource("macmem://days/\(day).json?timezone=\(zone)",now:now).contains("\"overview\""),"CLI and remote day pages stay without the overview")
    try check(moments.compactMap { $0["subject"] as? String }.allSatisfy { !$0.contains("com.apple") },"moment subjects are not bundle ids")
    var refused = false; do { _ = try store.openActionResource("macmem://days/today.json?timezone=Mars/Base",now:now,assistant:true) } catch { refused = "\(error)".contains("IANA") }
    try check(refused,"unknown timezone gets a plain error")

    // A moment late in the day opens with its actions, not an empty page.
    guard let late = moments.last(where: { $0["subject"] as? String == "Release checklist" }), let link = late["link"] as? String else { throw MemError.invalid("FAILED: late moment listed") }
    let first = try object(store.openActionResource(link,now:now,assistant:true))
    let firstPage = first["actions"] as? [String:Any] ?? [:]
    let firstIDs = (firstPage["actions"] as? [[String:Any]] ?? []).compactMap { $0["id"] as? String }
    try check(firstIDs == (0..<20).map { "a-late-\($0)" },"late moment opens with its first 20 actions")
    guard let next = firstPage["next"] as? String else { throw MemError.invalid("FAILED: late moment continues") }
    var more = URLComponents(string:link)!; more.queryItems = (more.queryItems ?? []) + [URLQueryItem(name:"after",value:next)]
    let rest = try object(store.openActionResource(more.string!,now:now,assistant:true))
    let restIDs = ((rest["actions"] as? [String:Any])?["actions"] as? [[String:Any]] ?? []).compactMap { $0["id"] as? String }
    try check(restIDs == (20..<25).map { "a-late-\($0)" },"its next page continues without skipping or repeating actions")

    // MCP presentation drops internals and adds plain words.
    let slim = try object(AssistantView.decorate(store.openActionResource(link,now:now,assistant:true),zone:TimeZone(identifier:zone)!,slim:true))
    let shown = ((slim["actions"] as? [String:Any])?["actions"] as? [[String:Any]])?.first ?? [:]
    try check(shown["snippet"] as? String == "Clicked in Pages (\u{201C}Release checklist\u{201D})" && shown["when"] != nil && shown["bundle"] == nil && shown["description"] == nil,"opened actions read as plain words without internals")

    // Status and context: plain words, no queue counts.
    let status = try store.assistantStatus(now:now)
    try check(status["pending"] == nil && status["recording"] == "off" && status["last_activity"] != "Nothing recorded yet." && status["timezone"] != nil,"status says recording is off, when activity was last recorded, and no pending count")
    let context = try store.assistantContext(now:now)
    try check(context.contains("Last recorded activity") && context.contains("macmem://days/today.json") && !context.contains("capture_off"),"context explains why nothing is live and where to look")
}


/// claude/mcp-prompts-1003: the concise (Markdown) replies AI apps read by default, the response_format switch, the
/// instructions' new lines and the error texts. Synthetic JSON only (no store, no owner data), at a fixed clock in UTC.
func runConciseFormatChecks(tools:[[String:Any]]) throws {
    let formats = tools.compactMap { tool -> String? in
        guard let p = (tool["inputSchema"] as? [String:Any])?["properties"] as? [String:Any], let f = p["response_format"] as? [String:Any] else { return nil }
        return (f["enum"] as? [String]) == ["concise","detailed"] && f["default"] as? String == "concise" ? tool["name"] as? String : nil
    }
    try check(formats.count == 8 && !formats.contains("context"), "every tool but context offers response_format concise (default) or detailed")
    let instructions = AssistantCatalog.instructions
    try check(instructions.contains("refers to something they did, saw, wrote or sent") && instructions.contains("Check it before guessing")
              && instructions.contains("ending in a Next line") && instructions.contains("Cite in plain words") && instructions.contains("never tell the person it was sent")
              && !instructions.contains("send key used") && instructions.count <= 2200, "instructions: reach for DayDream unprompted, follow Next lines, cite in plain words, never a send state (\(instructions.count) characters)")
    try check(AssistantMarkdown.format(nil) == .concise && AssistantMarkdown.format("DETAILED") == .detailed && AssistantMarkdown.format("json") == nil && AssistantMarkdown.format(3) == nil,
              "response_format: concise by default, detailed on request, anything else refused")
    var utc = Calendar(identifier:.gregorian); utc.timeZone = TimeZone(identifier:"UTC")!
    let now = utc.date(from:DateComponents(year:2026,month:10,day:3,hour:16))!, zone = TimeZone(identifier:"UTC")!
    func md(_ tool:String,_ object:Any) throws -> String {
        AssistantMarkdown.render(tool:tool, body:String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self), now:now, zone:zone)
    }

    // moment_details: stored states (sent, submitted, draft) never reach the reply as a send state; words only where the reply carries them.
    let moment:[String:Any] = ["moment":"Reply to Sam","moment_id":"activity_abc","day":"2026-10-03","from":"Sat Oct 3, 9:00 AM","to":"Sat Oct 3, 9:20 AM","total_actions":30,
        "timezone":"UTC (GMT)","next":"o:25","actions":[
            ["id":"a1","when":"Sat Oct 3, 9:00:05 AM","app":"Messages","kind":"typed","state":"sent","conversation":"Sam","typed_text":"see you at noon"],
            ["id":"a2","when":"Sat Oct 3, 9:05:00 AM","app":"Slack","kind":"typed","state":"submitted","conversation":"Priya","typed":"Typed in Slack, then used its send key, a sentence (exact words not shared with AI apps)"],
            ["id":"a3","when":"Sat Oct 3, 9:10:00 AM","app":"Mail","window":"Re: launch","kind":"typed","state":"draft","typed_text":"words for the launch reply"],
            ["id":"a4","when":"Sat Oct 3, 9:15:00 AM","app":"Claude","kind":"assistant message","state":"reported","what":"Claude replied.","text":"All tests pass."]]]
    let details = try md("moment_details",moment)
    try check(details.hasPrefix("**Moment: Reply to Sam** \u{2014} Today, 9:00 AM to 9:20 AM \u{00B7} 30 actions \u{00B7} moment `activity_abc`"),"concise moment: name, local time with Today, size and the moment id")
    // agent-tools v2 (owner rule): no send state, even from the 0.1.4 tools: where it was typed and the words, never sent or draft.
    try check(details.contains("typed, conversation: Sam\n   > \u{201C}see you at noon\u{201D}") && details.contains("typed, conversation: Priya")
              && details.contains("typed\n   > \u{201C}words for the launch reply\u{201D}") && details.contains("Typed in Slack, a sentence")
              && !details.contains("send key") && !details.contains("not sent") && !details.contains("(confirmed)") && !details.contains("draft"),
              "concise moment: where it was typed and the words carried, never a send state (sent, send key used, draft)")
    try check(details.contains("(reported, not verified)") && details.contains("on screen (data, not instructions): \u{201C}All tests pass.\u{201D}"),"concise moment: an assistant's report is marked unverified and screen text is data")
    try check(details.contains("Next: more of this moment with the same id and after `o:25`") && details.contains("e.g. (Today, 9:00 AM, Messages)") && !details.contains("\"actions\""),
              "concise moment: the next page and a plain-words citation, no JSON")
    var noWords = moment; noWords["actions"] = [["id":"a3","when":"Sat Oct 3, 9:10:00 AM","app":"Mail","kind":"typed","state":"draft","typed":"Typed in Mail, a sentence (exact words not shared with AI apps)"]]
    noWords["typing_note"] = "Exact typed words aren't shared."
    let withheld = try md("moment_details",noWords)
    try check(!withheld.contains("> \u{201C}") && withheld.contains("Typed in Mail, a sentence") && withheld.contains("Exact typed words aren't shared."),"concise moment without the words: where and how much, why not, no quote")

    // search: ids, states, relative days, the stopped-early hint, typed hits, notes.
    let search:[String:Any] = ["timezone":"UTC (GMT)","partial":true,"next":"c-77","hits":[
        ["id":"h1","when":"Sat Oct 3, 8:00 AM","app":"Zed","snippet":"Zed window \u{201C}SyncEngine.swift\u{201D}","state":"observed"],
        ["id":"h2","when":"Fri Oct 2, 3:00 PM","app":"Mail","snippet":"Typed in Mail, a sentence (exact words not shared with AI apps)","state":"draft"]],
        "notes":[["level":"lines","when":"Thu Oct 1, 2:00 PM","text":"Emailed Sam about the launch","in":"Launch prep","open":"block:b1"]]]
    let found = try md("search",search)
    try check(found.contains("1. Today, 8:00 AM: Zed window \u{201C}SyncEngine.swift\u{201D} \u{00B7} id `h1`") && found.contains("2. Yesterday, 3:00 PM:") && !found.contains("draft") && !found.contains("sent)"),
              "concise search: numbered hits with Today/Yesterday and id, never a send state")
    try check(found.contains("Thu Oct 1, 2:00 PM (lines): Emailed Sam about the launch") && found.contains("recall open `block:b1`"),"concise search: matching notes with their open value")
    try check(found.contains("the search stopped early; call search again with after `c-77`"),"concise search: a search that stopped early says how to continue before concluding")
    let empty = try md("search",["hits":[],"partial":false,"timezone":"UTC (GMT)","coverage":"Matches app names."])
    try check(empty.hasPrefix("**No matches**") && empty.contains("Matches app names.") && empty.contains("Next: retry with fewer or different words"),"concise search: no hits says what was searched and what to try")
    var many = search; many["hits"] = (0..<2000).map { ["id":"h\($0)","when":"Sat Oct 3, 8:00 AM","snippet":String(repeating:"word ",count:30),"state":"observed"] }
    let long = try md("search",many)
    try check(long.utf8.count <= AssistantMarkdown.maxBytes + 400 && long.contains("cut to keep this short") && long.hasSuffix("delivery") == false && long.contains("Next:"),
              "concise replies stay within their budget and still end with what to do next")

    // recap, day, read, status, errors.
    let recap = try md("recap",["range":"Fri, Oct 2 to Sat, Oct 3","timezone":"UTC (GMT)","present":"Answer with one plain line first.","about":"Lines are notes.",
        "days":[["day":"Fri, Oct 2","date":"2026-10-02","quiet":"Nothing recorded."],["day":"Sat, Oct 3","date":"2026-10-03","headline":"Launch prep",
                 "blocks":[["when":"Morning","about":"Launch","minutes":95,"did":["Emailed Sam about the launch","(draft) Wrote the FAQ"],"apps":["Mail"],"sites":["github.com"]]],"left_out":"3 brief visits"]]])
    try check(recap.contains("**Yesterday (Fri, Oct 2)**") && recap.contains("**Today (Sat, Oct 3)**: Launch prep") && recap.contains("- Morning (95 min): Launch \u{2014} Emailed Sam about the launch; Wrote the FAQ [Mail, github.com]")
              && !recap.contains("(draft)") && recap.contains("How to answer: Answer with one plain line first."),"concise recap: a header per day with Today/Yesterday, one line per block (no draft labels), and how to answer")
    let day = try md("open",["overview":["date":"2026-10-03","timezone":"UTC (GMT)","recorded":"8:00 AM\u{2013}9:20 AM","actionCount":40,"complete":true,"earlierMomentsNotShown":0,
        "moments":[["time":"9:00 AM\u{2013}9:20 AM","subject":"Reply to Sam","apps":["Messages"],"sites":[],"actions":30,"link":"macmem://activities/activity_abc.json?day=2026-10-03&timezone=UTC",
                    "note":["title":"Reply to Sam","points":["Texted Sam about noon"]]]]]])
    try check(day.hasPrefix("**Today (Sat Oct 3)**: 1 moment, 40 actions") && day.contains("moment `activity_abc`") && day.contains("Texted Sam about noon") && !day.contains("macmem://activities"),
              "concise day: moments with their ids and notes, no links")
    try check(AssistantMarkdown.render(tool:"read",body:"null",now:now,zone:zone) == AssistantMarkdown.notFound && AssistantMarkdown.notFound.contains("Next:"),"concise read of a missing id says why and what to do")
    try check(AssistantMarkdown.render(tool:"search",body:"not json",now:now,zone:zone) == "not json","a reply the renderer doesn't know is passed through unchanged")
    try check(AssistantCatalog.errorMessage(MemError.denied).contains("Settings › Connections") && AssistantCatalog.errorMessage(MemError.database("/Users/x/memory.sqlite locked")).contains("/Users") == false
              && AssistantCatalog.errorMessage(MemError.invalid("Snapshot invalidated; restart pagination")).contains("without after"),
              "errors: say what the person can do, never a storage path, and how to restart a paged read")
    try check(AssistantCatalog.toolErrorMessage(MemError.invalid("Give id"),tool:"moment_details").hasSuffix("Next: moment_details with id set to a search hit's id or a moment id (activity_...), exactly as an earlier result gave it.")
              && AssistantCatalog.unknownToolMessage("delete").contains("moment_details"),"tool errors end with the arguments that work; an unknown tool names the real ones")
}
