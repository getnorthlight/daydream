// notes-quality: moment notes that read like the owner's own ("Texted Q7 about Friday dinner", "Posted on X about the
// DayDream launch"), code notes for moments with nothing typed, and threads named and ordered for people. Synthetic
// requests only: no model, no network, no store, no capture. Compiles against 5c76a6f too, where it fails (the
// candidate wrote "Wrote a message in Messages." and loaded the model for a window).
import Foundation
import MemoryCore
import WriterBackend

var failures = 0, passes = 0
func check(_ ok: Bool, _ name: String) {
    if ok { passes += 1; print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func request(_ id: String, _ actions: [[String: Any]]) throws -> CanonicalNoteRequest {
    var rows = [[String: Any]]()
    for (i, a) in actions.enumerated() {
        var row: [String: Any] = ["id": "\(id)-\(i + 1)", "at": String(format: "2026-09-24T16:%02d:00Z", 10 + i), "site": "", "revision": "r1", "state": "observed"]
        for (k, v) in a { row[k] = v }
        rows.append(row)
    }
    let json: [String: Any] = ["id": id, "schemaVersion": 1, "targetKind": "activity", "targetID": id, "day": "2026-09-24", "timezone": "UTC",
                               "inputRevision": id, "policyRevision": "p", "expiresAt": "2099-01-01T00:00:00Z", "actions": rows, "actionCount": rows.count]
    return try JSONDecoder().decode(CanonicalNoteRequest.self, from: JSONSerialization.data(withJSONObject: json))
}
func typed(_ app: String, _ title: String, _ text: String, surface: String, to: String? = nil, site: String = "", detected: Bool = true) -> [String: Any] {
    var a: [String: Any] = ["kind": "keyboard.text_input", "app": app, "title": title, "site": site, "surface": surface,
                            "description": "Typed a draft in \(app). \(text)", "state": detected ? "submitted" : "typed",
                            "send": detected ? "detected" : "unknown", "runID": "u-\(title)"]
    if detected { a["sendBy"] = "return" }
    if let to { a["to"] = to }
    return a
}
func window(_ app: String, _ title: String, site: String = "") -> [String: Any] {
    ["kind": "window.changed", "app": app, "title": title, "site": site, "description": "Observed \(title) in \(app); reading is not established."]
}
func answer(_ title: String, _ bullet: String) -> String {
    #"{"title":"\#(title)","bullets":[{"ids":["i1"],"text":"\#(bullet)"}]}"#
}
func refused(_ raw: String, _ r: CanonicalNoteRequest, _ v: ModelView) -> Bool {
    (try? CanonicalGrounding.validate(raw, request: r, view: v, provider: CanonicalLocalWriter.provider)) == nil
}

actor Loads: LocalInference {
    var loads = 0
    func load() async throws { loads += 1 }
    func generate(instruction: String, evidence: String, maxTokens: Int) async throws -> Data { Data(#"{"title":"x","bullets":[]}"#.utf8) }
    func unload() async {}
    func count() -> Int { loads }
}

actor Cloud {
    var answers: [String]; var sent: [(system: String, user: String)] = []
    init(_ answers: [String]) { self.answers = answers }
    func send(_ r: URLRequest) -> CloudHTTPResponse {
        let body = (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any]
        let m = body?["messages"] as? [[String: String]] ?? []
        sent.append((m.first?["content"] ?? "", m.last?["content"] ?? ""))
        let reply: [String: Any] = ["model": CloudWriter.model, "choices": [["message": ["content": answers.isEmpty ? "{}" : answers.removeFirst()]]]]
        return CloudHTTPResponse(status: 200, body: (try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
    }
    func log() -> [(system: String, user: String)] { sent }
}
/// A local runtime that records what it was asked and answers one fixed answer.
actor Recorder: LocalInference {
    var seen: [(String, String)] = []; let answer: String
    init(_ a: String) { answer = a }
    func load() async throws {}
    func generate(instruction: String, evidence: String, maxTokens: Int) async throws -> Data { seen.append((instruction, evidence)); return Data(answer.utf8) }
    func unload() async {}
    func log() -> [(String, String)] { seen }
}
func json(_ title: String, _ bullets: [(String, String)]) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: ["title": title, "bullets": bullets.map { ["ids": [$0.0], "text": $0.1] }])) ?? Data(), as: UTF8.self)
}
func alias(_ v: ModelView, _ id: String) -> String { v.items.first { $0.actions.contains { $0.id == id } }?.alias ?? "i0" }

@main struct NotesQualityChecks {
    static func main() async throws {
        // A text to a group chat, sent with Return.
        let m5 = try request("m5", [typed("Messages", "Q7", "who's in for dinner friday? thinking Lumo at 8", surface: "text", to: "Q7")])
        let m5View = try ModelView(request: m5, actions: m5.actions)
        check(m5View.text.contains("Start with: Texted Q7"), "a detected text names its group chat: \"Start with: Texted Q7\"")
        check(refused(answer("Friday dinner", "Wrote a message in Messages."), m5, m5View), "filler: \"Wrote a message in Messages.\" is refused")
        // fix/bugs7: lines that name nothing at all.
        for vague in ["You used your Mac.", "Worked in apps.", "Used several apps.", "Switched between various applications.", "Computer use."] {
            check(refused(answer("Friday dinner", vague), m5, m5View), "filler: \"\(vague)\" is refused")
        }
        check(refused(answer("Friday dinner", "Texted about Friday dinner."), m5, m5View), "who: a send that doesn't name who it went to is refused")
        let good = try? CanonicalGrounding.validate(answer("Friday dinner", "Texted Q7 about Friday dinner."), request: m5, view: m5View, provider: CanonicalLocalWriter.provider)
        check(good?.bullets.map(\.text) == ["Texted Q7 about Friday dinner."] && good?.bullets.first?.assertion == "submitted",
              "the owner's line passes as written, labelled submitted")
        // Salvage: a refused line becomes code's line with the model's title as the topic, never "Wrote to Messages."
        let salvaged = try? CanonicalGrounding.salvage(answer("Friday dinner", "Wrote a message in Messages."), request: m5, view: m5View, provider: CanonicalLocalWriter.provider)
        check(salvaged?.bullets.map(\.text) == ["Texted Q7 about Friday dinner."], "salvage: \"Texted Q7 about Friday dinner.\" from the title and who (got \(salvaged?.bullets.map(\.text) ?? []))")

        // A post on X, sent with Command-Return.
        let x = try request("x", [typed("Google Chrome", "x.com", "DayDream launches tomorrow on Show HN. It remembers what you did", surface: "social", site: "x.com")])
        let xView = try ModelView(request: x, actions: x.actions)
        check(xView.text.contains("Start with: Posted on X"), "social: a detected post leads \"Posted on X\"")
        let post = try? CanonicalGrounding.validate(answer("DayDream launch", "Posted on X about the DayDream launch."), request: x, view: xView, provider: CanonicalLocalWriter.provider)
        check(post?.bullets.map(\.text) == ["Posted on X about the DayDream launch."], "social: \"Posted on X about the DayDream launch.\" passes")

        // build/7 (APP-COVERAGE): an AI website capture names in `to` (Gemini, Perplexity) is who was asked, never the browser.
        for (site, name) in [("gemini.google.com", "Gemini"), ("www.perplexity.ai", "Perplexity")] {
            let ask = try request("ai-" + name, [typed("Google Chrome", name, "why does the export crash on big files", surface: "ai", to: name, site: site)])
            let askView = try ModelView(request: ask, actions: ask.actions)
            check(askView.text.contains("Start with: Asked " + name) && !askView.text.contains("Asked Google Chrome"),
                  "\(site): a detected question leads \"Asked \(name)\", never \"Asked Google Chrome\"")
            // fix/sx-all (merged at build/launch-sx): in the note's own words; the typed question said again ("why the export
            // crashes on big files") is a copy, and typed words are never shown back.
            let asked = try? CanonicalGrounding.validate(answer("Export crash", "Asked \(name) about the export crash."), request: ask, view: askView,
                                                         provider: CanonicalLocalWriter.provider)
            check(asked?.bullets.map(\.text) == ["Asked \(name) about the export crash."], "\(site): \"Asked \(name) ...\" passes")
            check((try? CanonicalGrounding.validate(answer("Export crash", "Asked \(name) why the export crashes on big files."), request: ask, view: askView,
                                                    provider: CanonicalLocalWriter.provider)) == nil, "\(site): the typed question said again is refused as a copy")
        }

        // fix/sx-all: a webmail reply titled with its thread's subject (website typing rows carry the page title), no To
        // read and no greeting: the lead already says what about, so it is not bare, and salvage never repeats the subject.
        let reply = try request("gm", [typed("Google Chrome", "Re: Pricing for the team plan", "Let's keep the per seat price and offer a yearly plan", surface: "email", site: "mail.google.com")])
        let replyView = try ModelView(request: reply, actions: reply.actions)
        let lead = try? CanonicalGrounding.validate(answer("Pricing the team plan", "Emailed about Pricing for the team plan."), request: reply, view: replyView, provider: CanonicalLocalWriter.provider)
        check(lead?.bullets.map(\.text) == ["Emailed about Pricing for the team plan."], "webmail: \"Emailed about <subject>\" already says what about (got \(lead?.bullets.map(\.text) ?? []))")
        let replySalvage = try? CanonicalGrounding.salvage(answer("Pricing the team plan", "Wrote a message in Chrome."), request: reply, view: replyView, provider: CanonicalLocalWriter.provider)
        check(replySalvage.map { $0.bullets.allSatisfy { $0.text.components(separatedBy: "Pricing for the team plan").count <= 2 } } == true,
              "webmail salvage never says the subject twice (got \(replySalvage?.bullets.map(\.text) ?? []))")

        // fix/sx-all: a weak answer ("Worked in Messages" / "Had Messages open and in use.") is salvaged to the send and its
        // who, never "Texted Sam about worked in Messages." (the model's title is a topic only when it names a thing).
        let sam = try request("sam", [typed("Messages", "Sam", "can you send me the churn chart before 3?", surface: "text", to: "Sam")])
        let samView = try ModelView(request: sam, actions: sam.actions)
        let weak = try? CanonicalGrounding.salvage(answer("Worked in Messages", "Had Messages open and in use."), request: sam, view: samView, provider: CanonicalLocalWriter.provider)
        // fix/sx-all round 2 (F2): the typed words never give a topic ("Texted Sam about the riley said." was a typed
        // fragment shown back): with no checked title, the who-line.
        check(weak?.bullets.map(\.text) == ["Texted Sam."], "salvage: a generic model title is no topic and the typed words never give one (got \(weak?.bullets.map(\.text) ?? []))")

        // fix/sx-all round 1 (renders): the person it went to is never part of the topic.
        let riley = try request("riley", [typed("Google Chrome", "Launch checklist", "Riley, launch checklist is final, see you at 8 tomorrow", surface: "email", to: "Riley", site: "mail.google.com")])
        let rileyView = try ModelView(request: riley, actions: riley.actions)
        let rileyNote = try? CanonicalGrounding.salvage(answer("Worked in Chrome", "Had Chrome open and in use."), request: riley, view: rileyView, provider: CanonicalLocalWriter.provider)
        check(rileyNote?.bullets.first?.text == "Emailed Riley about the launch checklist.","salvage: an email's subject reads as a topic in lower case (got \(rileyNote?.bullets.map(\.text) ?? []))")
        check(rileyNote.map { !$0.bullets.isEmpty && $0.bullets.allSatisfy { !$0.text.lowercased().contains("riley launch") && !$0.text.contains("the riley") } } == true,
              "salvage: the recipient's name is never in the topic (got \(rileyNote?.bullets.map(\.text) ?? []))")

        let titled = try? CanonicalGrounding.validate(answer("Worked in Messages", "Texted Sam asking for the churn chart."), request: sam, view: samView, provider: CanonicalLocalWriter.provider)
        check(titled.map { !$0.title.lowercased().hasPrefix("worked in") && !$0.title.isEmpty } == true && titled?.bullets.map(\.text) == ["Texted Sam asking for the churn chart."],
              "title: \"Worked in Messages\" gives way to code's title, the line kept (got \(titled?.title ?? "nil"))")

        // fix/sx-all: the cloud view's mailbox title "Email" is no subject: never "Emailed about Email."
        let box = try request("box", [typed("Google Chrome", "Email", "Sounds good, see you then", surface: "email", site: "mail.google.com")])
        let boxView = try ModelView(request: box, actions: box.actions)
        let boxSalvage = try? CanonicalGrounding.salvage(answer("Worked in Chrome", "Had Chrome open and in use."), request: box, view: boxView, provider: CanonicalLocalWriter.provider)
        check(boxSalvage.map { $0.bullets.allSatisfy { !$0.text.contains("about Email") && $0.text != "Emailed." } } ?? true,
              "salvage: a mailbox named \"Email\" is no subject (got \(boxSalvage?.bullets.map(\.text) ?? []))")

        // A window only: code writes the note, the model is never loaded.
        let doc = try request("doc", [window("Google Chrome", "Q3 investor update - Google Docs", site: "docs.google.com")])
        let loads = Loads()
        let writer = CanonicalLocalWriter(runtime: loads, policy: { _, _ in true })
        let note = try? await writer.generate(doc, completeActions: doc.actions)
        let loaded = await loads.count()
        check(loaded == 0 && note != nil, "window only: no model load (loads \(loaded)), a code note instead")
        check(note?.title == "Q3 investor update", "window only: titled by what it was about, the cleaned title (got \(note?.title ?? "nil"))")
        check(!(note?.bullets.contains { $0.text.hasPrefix("Had ") } ?? true), "window only: never \"Had ... open\"")
        // fix/resummarize (owner, test 7): a short page says what it was, never how long ("Under a minute." was the note).
        let xPost = try request("post", [window("Google Chrome", "Sample Author on X: \"A fictional garden lantern beside the gate\" / X", site: "x.com")])
        let postNote = try? await writer.generate(xPost, completeActions: xPost.actions)
        let postLoads = await loads.count()
        check(postLoads == 0 && postNote?.bullets.map(\.text) == ["Viewed Sample Author's post on X, titled “A fictional garden lantern beside the gate”."],
              "a short X title: attributed saved title, no model (got \(postNote?.bullets.map(\.text) ?? []), loads \(postLoads))")
        // fix/sx-all round 3 (merged at build/launch-sx): a document whose typing wasn't recorded gets no reading line (it may
        // have been written in): only its place, which every surface reads as filler; never a duration.
        let docLines = note?.bullets.map(\.text) ?? []
        check(!docLines.isEmpty && docLines.allSatisfy { NoteFiller.isFiller($0, apps: ["Google Chrome"]) && !$0.lowercased().contains("minute") && !$0.hasPrefix("About") && !$0.hasPrefix("Under") },
              "a short page: never a duration (got \(docLines))")
        let bareX = try request("bare", [window("Google Chrome", "x.com", site: "x.com")])
        let bareNote = try? await writer.generate(bareX, completeActions: bareX.actions)
        check(bareNote != nil && !(bareNote?.bullets.contains { $0.text.hasPrefix("Viewed") } ?? true),
              "a page whose title only names the site gets no page line (got \(bareNote?.bullets.map(\.text) ?? []))")

        // Titles are cleaned the same way for the writer and the threads (unread counts, addresses, site names).
        let fixture = [("(3) How to price a SaaS product", "How to price a SaaS product"),
                       ("Re: Q3 numbers - sam@tallybird.example", "Re: Q3 numbers"),
                       ("Inbox (23)", "Inbox")]
        for (raw, clean) in fixture {
            let v = try ModelView(request: request("t", [window("Preview", raw)]), actions: request("t", [window("Preview", raw)]).actions)
            check(ThreadEntities.clean(raw) == clean && !v.text.contains(raw), "title-clean fixture: \"\(raw)\" -> \"\(clean)\" in both")
        }

        // Threads: an AI app is one thread per app; a group chat is named; side bullets never merge into "Also ...".
        let ask = ThreadEntities.entity(app: "Claude", bundle: "com.anthropic.claudefordesktop", site: "", title: "CSV export crash")
        check(ask.fallback == "ai:claude" && ask.label == "Claude", "threads: Claude asks share the Claude thread unless a name links them")
        let codex = ThreadEntities.entity(app: "Codex", bundle: "com.openai.codex", site: "", title: "Team plan pricing")
        check(codex.fallback == "ai:chatgpt" && codex.label == "ChatGPT", "threads: com.openai.codex is ChatGPT")
        let group = ThreadEntities.entity(app: "Messages", bundle: "com.apple.MobileSMS", site: "", title: "Q7")
        check(group.label == "Texts with Q7", "threads: a group chat reads \"Texts with Q7\" (got \(group.label))")
        func side(_ label: String, _ minutes: Int, kind: String = "doc") -> LevelThread {
            LevelThread(key: label, kind: kind, label: label, people: [], places: [], seconds: minutes * 60, bursts: 1, children: [label], start: "2026-09-24T16:00:00Z", end: "2026-09-24T17:00:00Z")
        }
        var texts = side("Texts with Riley", 2, kind: "texts"); texts.people = ["Riley"]
        let bullets = LevelThreads.bullets([side("Main", 90), side("A", 20), side("B", 15), side("C", 12), side("D", 11), side("E", 10),
                                            texts], max: 4).map(\.text)
        check(bullets.count == 4 && !bullets.contains { $0.hasPrefix("Also ") } && bullets.first == "Texts with Riley, ~2 min",
              "threads: at most four side bullets, texts first, no \"Also\" (got \(bullets))")


        // An email with no To read: its greeting names who it went to; "someone" is refused when code read who.
        let gmail = try request("gmail", [typed("Google Chrome", "mail.google.com", "Hi Sam, the Q3 update draft is in the doc. Can you check the churn numbers?", surface: "email", site: "mail.google.com")])
        let gmailView = try ModelView(request: gmail, actions: gmail.actions)
        check(gmailView.text.contains("Start with: Emailed Sam"), "email: the greeting names who (\"Start with: Emailed Sam\")")
        check(refused(answer("Q3 update", "Emailed someone about the Q3 update draft."), gmail, gmailView), "email: \"Emailed someone\" is refused when code read who")
        check((try? CanonicalGrounding.validate(answer("Q3 update", "Emailed Sam about the Q3 update draft."), request: gmail, view: gmailView, provider: CanonicalLocalWriter.provider)) != nil,
              "email: \"Emailed Sam about the Q3 update draft.\" passes")
        // A Return pressed in Slack with nothing typed shown is no claim: a code note, no model.
        let slack = try request("slack", [window("Slack", "eng (Channel) - Tallybird - Slack"),
                                          ["kind": "keyboard.submit", "app": "Slack", "title": "eng (Channel) - Tallybird - Slack", "state": "draft",
                                           "description": "Pressed Return in Slack; sending is not established."]])
        let slackLoads = Loads()
        let slackNote = try? await CanonicalLocalWriter(runtime: slackLoads, policy: { _, _ in true }).generate(slack, completeActions: slack.actions)
        let slackLoaded = await slackLoads.count()
        check(slackLoaded == 0 && slackNote?.title == "Slack in #eng", "a Return alone is no claim: code note \"Slack in #eng\", no model (\(slackNote?.title ?? "nil"), loads \(slackLoaded))")
        // Microsoft Teams: a chat window is not a call; a meeting window is named by its meeting.
        let teamsChat = try request("teamschat", (0..<6).map { _ in window("Microsoft Teams", "Chat | Priya Shah | Microsoft Teams") })
        let chatNote = try? await CanonicalLocalWriter(runtime: Loads(), policy: { _, _ in true }).generate(teamsChat, completeActions: teamsChat.actions)
        check(chatNote?.title == "Teams chat with Priya Shah" && !(chatNote?.bullets.contains { $0.text.hasPrefix("On a call") } ?? true),
              "Teams: a chat is \"Teams chat with Priya Shah\", never \"On a call\" (\(chatNote?.title ?? "nil") \(chatNote?.bullets.map(\.text) ?? []))")
        let teamsMeeting = try request("teamsmeet", [window("Microsoft Teams", "Meeting | Weekly product sync | Microsoft Teams")])
        check((try? ModelView(request: teamsMeeting, actions: teamsMeeting.actions))?.items.first?.title == "Weekly product sync", "Teams: \"Meeting | Weekly product sync\" reads \"Weekly product sync\"")
        // Cloud (no key: a stand-in OpenRouter). Owner-style answers a strong model writes pass as written; a wrong opening
        // word is repaired in one more call; the cloud gets local's instruction and ITEMS view, page titles included.
        let zoom = try request("zoom", [window("zoom.us", "Weekly product sync"),
                                        typed("zoom.us", "Weekly product sync", "can you share the roadmap slide again", surface: "chat", to: "Everyone")])
        let prTitle = "Add weekly summaries export by sam · Pull Request #418 · tallybird/app"
        var prRows: [[String: Any]] = [window("Google Chrome", prTitle, site: "github.com").merging(["kind": "browser.tab_visited"]) { $1 }]
        for _ in 0..<4 { prRows.append(["kind": "mouse.click", "app": "Google Chrome", "title": prTitle, "site": "github.com", "description": "Clicked in Google Chrome."]) }
        let prRead = try request("prread", prRows)
        prRows.append(typed("Google Chrome", "github.com", "looks good, one nit on the csv header naming", surface: "other", site: "github.com", detected: false))
        let pr = try request("pr", prRows)
        let mail = try request("mail", [typed("Mail", "Team plan pricing", "Hi Sam, here is the Team plan at $8 a seat per month, billed yearly", surface: "email", to: "Sam")])
        typealias Case = (String, CanonicalNoteRequest, (ModelView) -> [String], [String])
        let cases: [Case] = [
            ("group chat", m5, { v in [json("Friday dinner", [(alias(v, "m5-1"), "Texted Q7 about Friday dinner at Lumo.")])] }, ["Texted Q7 about Friday dinner at Lumo."]),
            ("X post", x, { v in [json("DayDream launch", [(alias(v, "x-1"), "Posted on X about the DayDream launch on Show HN.")])] }, ["Posted on X about the DayDream launch on Show HN."]),
            ("Zoom chat", zoom, { v in [json("Weekly product sync", [(alias(v, "zoom-2"), "Messaged Everyone in the Weekly product sync to reshare the roadmap slide.")])] },
             ["Messaged Everyone in the Weekly product sync to reshare the roadmap slide."]),
            ("PR comment", pr, { v in [json("PR #418 review", [(alias(v, "pr-6"), "Drafted a review comment on PR #418 about the CSV header naming.")])] },
             ["Drafted a review comment on PR #418 about the CSV header naming."]),
            ("wrong lead", mail, { v in [json("Team plan pricing", [(alias(v, "mail-1"), "Texted Sam about Team plan pricing.")]),
                                        json("Team plan pricing", [(alias(v, "mail-1"), "Emailed Sam about Team plan pricing.")])] }, ["Emailed Sam about Team plan pricing."]),
        ]
        for (name, r, answers, expect) in cases {
            guard let v = try? ModelView(request: r, actions: r.actions) else { check(false, "cloud \(name): a view"); continue }
            let a = answers(v), c = Cloud(a)
            let writer = CanonicalCloudWriter(consent: { CloudConsent(enabled: true, disclosureVersion: CloudConsent.currentVersion) }, key: { "synthetic" },
                                              policy: { _, _ in true }, send: { await c.send($0) })
            let out = try? await writer.generate(r, completeActions: r.actions)
            let log = await c.log(), lines = out?.bullets.map(\.text) ?? []
            check(lines == expect && log.count == a.count, "cloud \(name): \(lines) in \(log.count) call(s)")
            let rec = Recorder(a.last!)
            _ = try? await CanonicalLocalWriter(runtime: rec, policy: { _, _ in true }).generate(r, completeActions: r.actions)
            let local = await rec.log()
            check(log.first?.system == CanonicalGrounding.instruction && local.first?.0 == CanonicalGrounding.instruction && log.first?.user == local.first?.1 && log.first?.user == v.text,
                  "cloud \(name): the same instruction and ITEMS view as local")
        }
        check((try? ModelView(request: pr, actions: pr.actions))?.text.contains("PR #418: Add weekly summaries export") == true, "cloud and local: the page title, cleaned (\"PR #418: Add weekly summaries export\")")
        // A pull request read for 5 minutes with nothing typed: code writes "Reviewed PR #418: ...", no cloud call.
        let none = Cloud([])
        let read = try? await CanonicalCloudWriter(consent: { CloudConsent(enabled: true, disclosureVersion: CloudConsent.currentVersion) }, key: { "synthetic" },
                                                   policy: { _, _ in true }, send: { await none.send($0) }).generate(prRead, completeActions: prRead.actions)
        let noneCalls = await none.log().count
        // fix/sx-all round 2 (F14): whose pull request it is decides "Reviewed": sam's own PR (his mail account "sam@...")
        // is "Checked", someone else's "Reviewed", and one code can't tell whose is "Looked at" (round 3: never a bare name,
        // never "your").
        check(noneCalls == 0 && read?.bullets.map(\.text) == ["Looked at PR #418: Add weekly summaries export."], "cloud: a PR read with nothing typed is a code note, no call (\(read?.bullets.map(\.text) ?? []))")
        for (names, expect) in [(["sam"], "Checked PR #418: Add weekly summaries export."), (["riley"], "Reviewed PR #418: Add weekly summaries export.")] {
            var r = prRead; r.selfNames = names
            let n = try? await CanonicalLocalWriter(runtime: Loads(), policy: { _, _ in true }).generate(r, completeActions: r.actions)
            check(n?.bullets.map(\.text) == [expect], "PR by sam, you are \(names[0]): \"\(expect)\" (got \(n?.bullets.map(\.text) ?? []))")
        }
        // Salvage when both answers fail: where it happened, never a bare lead or "Wrote in X about X".
        for (r, bad, expect) in [(zoom, "Wrote a message in Zoom.", "Messaged Everyone in Weekly product sync."), (pr, "Wrote a message in Chrome.", "Drafted a comment on PR #418: Add weekly summaries export.")] {
            guard let v = try? ModelView(request: r, actions: r.actions) else { continue }
            let got = try? CanonicalGrounding.salvage(json("", [("i1", bad)]), request: r, view: v, provider: CanonicalLocalWriter.provider)
            check(got?.bullets.map(\.text) == [expect], "salvage: \"\(expect)\" (got \(got?.bullets.map(\.text) ?? []))")
        }


        // fix/sx-all round 1 (P0): an AI tool in a terminal is asked by its own name, never "Asked Terminal".
        let codexAsk = try request("codex", [typed("Terminal", "tallybird-sync \u{2014} codex", "add a migration that backfills vector clocks for rows created before beta 9", surface: "aiTool", to: "Codex")])
        let codexView = try ModelView(request: codexAsk, actions: codexAsk.actions)
        check(codexView.text.contains("Start with: Asked Codex") && !codexView.text.contains("Asked Terminal"), "aiTool: \"Start with: Asked Codex\", never \"Asked Terminal\"")
        check(refused(answer("Vector clock migration", "Asked Terminal to add a migration for older rows."), codexAsk, codexView), "aiTool: \"Asked Terminal ...\" is refused")
        check((try? CanonicalGrounding.validate(answer("Vector clock migration", "Asked Codex for a migration for older rows."), request: codexAsk, view: codexView, provider: CanonicalLocalWriter.provider)) != nil,
              "aiTool: \"Asked Codex for a migration for older rows.\" passes")
        let claudeAsk = try request("cc", [typed("Terminal", "tallybird-sync \u{2014} claude", "why does the sync test fail on the second device", surface: "aiTool", to: "Claude Code")])
        let claudeView = try ModelView(request: claudeAsk, actions: claudeAsk.actions)
        check((try? CanonicalGrounding.validate(answer("Sync test failure", "Asked Claude why a sync test fails on another device."), request: claudeAsk, view: claudeView, provider: CanonicalLocalWriter.provider)) != nil,
              "aiTool: \"Asked Claude ...\" names Claude Code by its short name")

        // fix/sx-all round 1 (P0): salvage keeps the WHAT. A send whose words were shown never salvages to "<Lead> <who>."
        let bare = try NSRegularExpression(pattern: #"^(Asked|Emailed|Messaged|Texted|Posted|Replied|Told)( to)?( [A-Z][\w.'-]*)*\.$"#)
        func isBare(_ t: String) -> Bool { bare.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil }
        let p0: [(String, [String: Any], String)] = [
            ("Priya email", typed("Google Chrome", "mail.google.com", "Hi Priya, can you send the beta 9 crash logs before the release call? I want to confirm the sync fix", surface: "email", to: "Priya", site: "mail.google.com"),
             json("Beta 9 crash logs from Priya", [("i1", "Emailed Priya asking for beta 9 crash logs before the release call.")])),
            ("Slack DM", typed("Google Chrome", "app.slack.com", "the sync fix is merged, can you run the beta 9 build on your two iPads tonight?", surface: "chat", to: "Priya Shah", site: "app.slack.com"),
             json("Sync fix merged for Priya", [("i1", "Messaged Priya Shah that the sync fix is merged and asked her to run the beta 9 build on her iPads tonight.")])),
            ("release notes", typed("Google Chrome", "claude.ai", "write release notes for beta 9: sync conflicts fixed, faster export, new iPad layout", surface: "ai", site: "claude.ai"),
             json("Beta 9 release notes", [("i1", "Asked Claude to write release notes for beta 9: sync conflicts fixed, faster export.")])),
        ]
        for (name, row, raw) in p0 {
            let r = try request("p0", [row]), v = try ModelView(request: r, actions: r.actions)
            let got = try? CanonicalGrounding.salvage(raw, request: r, view: v, provider: CanonicalLocalWriter.provider)
            let lines = got?.bullets.map(\.text) ?? []
            // fix/sx-all round 2 (F2): a model line that copies is cut back or dropped; what stays is the model's own words
            // (never more than 4 typed words in a row) or code's who-line, never a topic taken from the typed words.
            let typedText = (row["description"] as? String) ?? ""
            check(!lines.isEmpty && !lines.contains { $0.contains(" her ") || $0.hasSuffix(" her.") } && lines.allSatisfy { TypedVerbatimGuard.longestCopiedRun($0, from: typedText) <= 4 },
                  "salvage \(name): no \"her\", never 5 typed words in a row (got \(lines))")
            // A code-written line (the model's answer was filler) never shares 3 words in a row with what was typed.
            let codeOnly = try? CanonicalGrounding.salvage(json("Worked in Chrome", [("i1", "Wrote something.")]), request: r, view: v, provider: CanonicalLocalWriter.provider)
            let codeLines = codeOnly?.bullets.map(\.text) ?? []
            check(codeLines.allSatisfy { TypedVerbatimGuard.longestCopiedRun($0, from: typedText) < 3 },
                  "salvage \(name): code's line shares under 3 typed words in a row (got \(codeLines))")
        }
        // Pronouns are neutral ("asked them to run the build"), so a good line is not thrown away for "her".
        let slackR = try request("p0", [p0[1].1]), slackV = try ModelView(request: slackR, actions: slackR.actions)
        let neutral = try? CanonicalGrounding.salvage(p0[1].2, request: slackR, view: slackV, provider: CanonicalLocalWriter.provider)
        check(neutral?.bullets.first.map { $0.text.hasPrefix("Messaged Priya Shah") && !$0.text.contains(" her") } == true, "salvage Slack DM: \"Messaged Priya Shah ...\" (got \(neutral?.bullets.map(\.text) ?? []))")

        // fix/sx-all round 1 (P1): terminal commands are said by code, never the window title, and need no model.
        func submit(_ title: String) -> [String: Any] {
            ["kind": "keyboard.submit", "app": "Terminal", "title": title, "state": "draft", "description": "Pressed Return in Terminal; sending is not established."]
        }
        for (cmd, expect) in [("git push origin sync-conflicts", "Entered a command to push sync-conflicts"), ("swift test", "Entered a command to run the Swift tests"), ("swift test --filter SyncConflictTests", "Entered a command to run the Swift tests")] {
            let t = "tallybird-sync \u{2014} zsh"
            let r = try request("term", [typed("Terminal", t, cmd, surface: "code", detected: false), submit(t)])
            let l = Loads()
            let n = try? await CanonicalLocalWriter(runtime: l, policy: { _, _ in true }).generate(r, completeActions: r.actions)
            let loadsN = await l.count(), lines = n?.bullets.map(\.text) ?? []
            check(loadsN == 0 && lines.first?.hasPrefix(expect) == true && !lines.contains { $0.contains("\u{2014}") || $0.contains(cmd) } && n?.title.contains("\u{2014}") == false,
                  "terminal \"\(cmd)\": \"\(expect) ...\" by code, no model (got \(n?.title ?? "nil"): \(lines), loads \(loadsN))")
        }

        // Return and detected-send facts prove command entry, not success. These are the same
        // captured invocation facts when the command later fails or its result is unknown.
        // Cover every deterministic command family, including launch/test verbs and title nouns.
        let terminalCases = [
            ("git push origin sync-conflicts", "push sync-conflicts"), ("git pull", "pull the latest changes"),
            ("git commit -m repair --allow-empty", "make a git commit"), ("git switch sync-conflicts", "switch to sync-conflicts"),
            ("git checkout -b sync-conflicts", "start the sync-conflicts branch"), ("git clone tallybird.git", "clone tallybird"),
            ("git stash", "stash changes"), ("git fetch", "fetch from the remote"),
            ("swift test --filter SyncConflictTests", "run the Swift tests (SyncConflictTests)"),
            ("swift build", "build the Swift package"), ("swift run", "start the Swift app"),
            ("xcodebuild test", "run the Xcode tests"), ("xcodebuild build", "build with Xcode"),
            ("npm test", "run the tests"), ("npm install", "install npm packages"),
            ("yarn --silent", "install yarn packages"), ("pnpm add widget", "install pnpm packages"),
            ("bun run preview", "run the preview script with bun"),
            ("cargo test", "run the Rust tests"), ("cargo build", "build with cargo"), ("cargo run", "start the Rust app"),
            ("pytest", "run the Python tests"), ("go test", "run the Go tests"), ("go build", "build with go"),
            ("make check", "run the check make target"), ("make --jobs=2", "run make"),
            ("claude --continue", "start Claude Code"), ("codex --quiet", "start Codex"), ("python3 replay.py --mode fixture", "run replay.py")
        ]
        for (cmd, purpose) in terminalCases {
            for entered in [false, true] {
                let t = "tallybird-sync \u{2014} zsh"
                let actions = [typed("Terminal", t, cmd, surface: "code", detected: entered)]
                let r = try request("term-facts", actions), v = try ModelView(request: r, actions: r.actions)
                let expected = (entered ? "Entered a command to " : "Typed a command to ") + purpose + " in tallybird-sync."
                let note = try? CanonicalGrounding.codeNote(r, view: v)
                let fallback = try? CanonicalGrounding.fallbackNote(r, view: v)
                check(note?.bullets.map(\.text) == [expected] && fallback?.bullets.map(\.text) == [expected]
                      && note.flatMap { try? CanonicalGrounding.check($0, request: r, view: v) } != nil
                      && fallback.flatMap { try? CanonicalGrounding.check($0, request: r, view: v) } != nil
                      && note.map { !$0.title.hasPrefix("Pushing") && !$0.title.hasPrefix("Cloning") } == true,
                      "terminal facts: \(cmd), entered=\(entered), unknown or failed result never claimed (got \(note?.bullets.map(\.text) ?? []))")
            }
        }
        // A process title, including a failure-looking suffix, cannot establish that this typed
        // command was entered or establish its result. This covers the former process-title shortcut.
        for process in ["git push", "git push (exit 1)"] {
            let t = "tallybird-sync \u{2014} " + process
            for entered in [false, true] {
                let r = try request("term-process", [typed("Terminal", t, "git push origin sync-conflicts", surface: "code", detected: entered)])
                let v = try ModelView(request: r, actions: r.actions)
                let n = try CanonicalGrounding.codeNote(r, view: v)
                let expected = (entered ? "Entered" : "Typed") + " a command to push sync-conflicts in tallybird-sync."
                check(n.bullets.map(\.text) == [expected],
                      "terminal process metadata \(process), entered=\(entered): entry depends on recorded facts; result never inferred")
            }
        }

        // fix/sx-all round 3 (P1): code and terminal moments say what was done or nothing: never a window title dressed as a
        // line ("SyncEngine.swift in tallybird-sync in Cursor.", "iTerm2 in harborline.", "Terminal in harborline.").
        func clicks(_ app: String, _ title: String, _ n: Int) -> [[String: Any]] {
            [window(app, title)] + (0..<n).map { _ in ["kind": "mouse.click", "app": app, "title": title, "description": "Clicked in \(app)."] }
        }
        let rawCode = try NSRegularExpression(pattern: #"^(?:[\w.+-]+\.[A-Za-z]{1,6} in [^ ]+ in [^ ]+|(?:Cursor|Xcode|VS Code|iTerm2|Terminal|Ghostty|Warp) in [^ ]+|In [^ ]+ in [^ ]+)\.?$"#)
        func rawLine(_ l: String) -> Bool { rawCode.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil }
        let codeCases: [(String, CanonicalNoteRequest, String?)] = [
            ("Cursor, 3 minutes", try request("cur3", clicks("Cursor", "uploader.rs \u{2014} harborline", 3)), nil),
            ("Cursor, 12 minutes", try request("cur12", clicks("Cursor", "uploader.rs \u{2014} harborline", 12)), "Worked on uploader.rs in harborline."),
            ("Xcode, 3 minutes", try request("xc3", clicks("Xcode", "SyncEngine.swift \u{2014} tallybird-sync", 3)), nil),
            ("iTerm2 running claude", try request("it2", clicks("iTerm2", "harborline \u{2014} claude", 4)), "Used Claude Code in harborline."),
            ("Terminal, 3 minutes", try request("tm3", clicks("Terminal", "harborline \u{2014} zsh", 3)), nil),
            ("Terminal, 12 minutes", try request("tm12", clicks("Terminal", "harborline \u{2014} zsh", 12)), "Worked in the terminal in harborline."),
        ]
        for (name, r, expect) in codeCases {
            let l = Loads()
            let n = try? await CanonicalLocalWriter(runtime: l, policy: { _, _ in true }).generate(r, completeActions: r.actions)
            let lines = n?.bullets.map(\.text) ?? [], loadsN = await l.count()
            let said = lines.filter { !NoteFiller.isFiller($0, apps: [r.actions.first?.app ?? ""]) }
            check(loadsN == 0 && !lines.contains(where: rawLine) && (expect.map { said == [$0] } ?? said.isEmpty),
                  "code moment \(name): \(expect.map { "\"\($0)\"" } ?? "no line but the place") by code, never '<file> in <proj> in <app>' (got \(lines), loads \(loadsN))")
        }
        // A terminal in a project is titled by it, never its raw window title "harborline — zsh".
        let termTitle = try? await CanonicalLocalWriter(runtime: Loads(), policy: { _, _ in true }).generate(try request("tmt", clicks("iTerm2", "harborline \u{2014} zsh", 4)), completeActions: try request("tmt", clicks("iTerm2", "harborline \u{2014} zsh", 4)).actions)
        check(termTitle?.title == "Terminal in harborline", "code moment: a terminal is titled \"Terminal in harborline\" (got \(termTitle?.title ?? "nil"))")
        check(rawLine("SyncEngine.swift in tallybird-sync in Cursor.") && rawLine("iTerm2 in harborline.") && !rawLine("Worked on uploader.rs in harborline."),
              "code moment: the raw-line pattern this check uses catches the round-3 lines")

        // fix/sx-all round 3 (P1): "Commented on PR #907 about ..." is a draft's own verb (the prompt's example), never refused;
        // salvage never leaves a topic dangling ("... about the question on PR.") or repeats what the line already names.
        let prPage = "Notarize step fails on CI by owen \u{00B7} Pull Request #907 \u{00B7} tallybird/harborline"
        let cmt = try request("prc", [window("Google Chrome", prPage, site: "github.com"),
                                       typed("Google Chrome", prPage, "did you try the keychain unlock before notarytool, the codesigning step times out", surface: "other", site: "github.com", detected: false)])
        let cmtView = try ModelView(request: cmt, actions: cmt.actions)
        let cmtID = alias(cmtView, "prc-2")
        let commented = #"{"title":"Notarize step on CI","bullets":[{"ids":["\#(cmtID)"],"text":"Commented on PR #907 about the codesigning timeout."}]}"#
        check(!refused(commented, cmt, cmtView), "PR comment: \"Commented on PR #907 about the codesigning timeout.\" is kept")
        let garble = #"{"title":"Question on PR","bullets":[{"ids":["\#(cmtID)"],"text":"Said the codesigning step on PR #907 times out."}]}"#
        let garbled = try? CanonicalGrounding.salvage(garble, request: cmt, view: cmtView, provider: CanonicalLocalWriter.provider)
        check(garbled.map { $0.bullets.allSatisfy { !$0.text.hasSuffix(" on PR.") && !$0.text.contains("about the question") && !$0.text.contains(" PR #907 about PR") } } ?? true,
              "PR comment: salvage never dangles (\"about the question on PR\") (got \(garbled?.bullets.map { $0.text } ?? []))")

        // fix/sx-all round 3 (P2): no second person in a line. claude/messages-1003 (owner, 10/3): except a "Texted ..." line,
        // which retells a text in the person's own voice ("Texted Mom that you'll call tonight").
        let momSend = try request("mom2", [typed("Messages", "Mom", "ill call tonight after dinner", surface: "text", to: "Mom")])
        let momSendView = try ModelView(request: momSend, actions: momSend.actions)
        let yourCall = try? CanonicalGrounding.validate(answer("Calling tonight", "Texted Mom about your call tonight."), request: momSend, view: momSendView, provider: CanonicalLocalWriter.provider)
        check(!refused(answer("Calling tonight", "Texted Mom that you'll call tonight."), momSend, momSendView)
              && yourCall.map { $0.bullets.map(\.text) == ["Texted Mom about your call tonight."] } != false
              && !refused(answer("Calling tonight", "Texted Mom about calling tonight."), momSend, momSendView)
              && CanonicalGrounding.instruction.contains("never \"you\" or \"your\" outside the gist of a text"),
              "second person: a text's gist may say \"you\" (\"Texted Mom that you'll call tonight\"), and the prompt says only there")

        // fix/sx-all round 3 (P2): a page title's own-site part goes ("Linear \u{2013} HAR-231 ..."), and an ID-led topic keeps its case.
        let har = try request("har", clicks("Google Chrome", "Linear \u{2013} HAR-231 Flaky resume test on Linux CI", 3).map { $0.merging(["site": "linear.app"]) { $1 } })
        let harNote = try? await CanonicalLocalWriter(runtime: Loads(), policy: { _, _ in true }).generate(har, completeActions: har.actions)
        check(harNote?.bullets.map(\.text) == ["Looked at HAR-231 Flaky resume test on Linux CI."], "Linear page: \"Looked at HAR-231 Flaky resume test on Linux CI.\" (got \(harNote?.bullets.map(\.text) ?? []))")
        check(TitleClean.clean("Linear \u{2013} HAR-231 Flaky resume test on Linux CI", app: "Google Chrome", site: "linear.app").hasPrefix("HAR-231"),
              "Linear page: the stored title drops Linear's own name (got \(TitleClean.clean("Linear \u{2013} HAR-231 Flaky resume test on Linux CI", app: "Google Chrome", site: "linear.app")))")

        // fix/sx-all round 1 (P1): a note that only says how long ("About 38 minutes.") is filler; a read says what was read.
        check(CanonicalGrounding.durationLine("About 38 minutes.") && CanonicalGrounding.durationLine("~10 min") && !CanonicalGrounding.durationLine("Viewed texts with Mom."),
              "filler: a line that is only a duration is filler")
        // Passive surface templates keep the existing typing/category/pause gate, but never infer reading or attention.
        // The observed window title supports a viewed-surface line only; without the gate, retain the place fallback.
        let momRead = try request("mom", (0..<6).map { _ in window("Messages", "Mom").merging(["typing": "on"]) { $1 } })
        let momNote = try? await CanonicalLocalWriter(runtime: Loads(), policy: { _, _ in true }).generate(momRead, completeActions: momRead.actions)
        check(momNote?.bullets.first?.text == "Viewed texts with Mom." , "reading: a Messages window with typing recorded shows \"Viewed texts with Mom.\" (got \(momNote?.bullets.map(\.text) ?? []))")
        let momOff = try request("mom", (0..<6).map { _ in window("Messages", "Mom") })
        let momOffNote = try? await CanonicalLocalWriter(runtime: Loads(), policy: { _, _ in true }).generate(momOff, completeActions: momOff.actions)
        // Round 3 (P1): with nothing to tell, no verbless line ("Texts with Mom.", "In Messages."): the row shows its time.
        check(momOffNote.map { $0.bullets.allSatisfy { !$0.text.hasPrefix("Read") && (NoteFiller.isFiller($0.text, apps: ["Messages"]) || $0.text.contains(" about ")) && $0.text != "Texts with Mom." } } == true, "reading: typing off, a Messages window writes no \"Read\" and no bare place line (got \(momOffNote?.bullets.map(\.text) ?? []))")
        var jordanRows = (0..<5).map { _ in window("Messages", "Jordan").merging(["typing": "on"]) { $1 } }
        jordanRows.append(["kind": "keyboard.submit", "app": "Messages", "title": "Jordan", "state": "draft", "typing": "on", "description": "Pressed Return in Messages; sending is not established."])
        let jordan = try request("jordan", jordanRows)
        let jordanNote = try? await CanonicalLocalWriter(runtime: Loads(), policy: { _, _ in true }).generate(jordan, completeActions: jordan.actions)
        check(jordanNote.map { !$0.bullets.contains { $0.text.hasPrefix("Read") } } == true, "reading: a Return pressed with nothing typed shown is never \"Read texts with Jordan\" (got \(jordanNote?.bullets.map(\.text) ?? []))")
        // fix/sx-all round 2 (real-model run): WhatsApp with a Return and its typed row refused wrote "WhatsApp.", which core
        // refused as a secret (one mixed-case word), so the moment never got a note. Code's line names the place in words.
        var waRows = (0..<3).map { _ in window("WhatsApp", "WhatsApp") }
        waRows.append(["kind": "keyboard.submit", "app": "WhatsApp", "title": "WhatsApp", "state": "draft", "description": "Pressed Return in WhatsApp; sending is not established."])
        let wa = try request("wa", waRows)
        let waNote = try? await CanonicalLocalWriter(runtime: Loads(), policy: { _, _ in true }).generate(wa, completeActions: wa.actions)
        check(waNote?.bullets.map(\.text) == ["In WhatsApp."] && waNote.map { $0.bullets.allSatisfy { !Privacy.secret($0.text) } } == true,
              "reading: WhatsApp with nothing recorded is \"In WhatsApp.\", a line core commits (got \(waNote?.bullets.map(\.text) ?? []))")
        // Slack desktop, where the typing category refused the typed row: the channel, never "Read".
        let slackOff = try request("slk", (0..<5).map { _ in window("Slack", "backend (Channel) - Tallybird - Slack") })
        let slackOffNote = try? await CanonicalLocalWriter(runtime: Loads(), policy: { _, _ in true }).generate(slackOff, completeActions: slackOff.actions)
        check(slackOffNote.map { $0.bullets.allSatisfy { !$0.text.hasPrefix("Read") && (NoteFiller.isFiller($0.text, apps: ["Slack"]) || $0.text.contains(" about ")) && !$0.text.hasSuffix(" on Slack.") } } == true, "reading: Slack with typing not recorded writes no \"Read\" and no bare place line (got \(slackOffNote?.bullets.map(\.text) ?? []))")
        let cabins = try request("cab", (0..<4).map { _ in window("Google Chrome", "Cabins near Sintra - Airbnb", site: "airbnb.com") })
        let cabinNote = try? await CanonicalLocalWriter(runtime: Loads(), policy: { _, _ in true }).generate(cabins, completeActions: cabins.actions)
        check(cabinNote.map { $0.bullets.allSatisfy { !CanonicalGrounding.durationLine($0.text) } && $0.bullets.first?.text.hasPrefix("Looked at") == true } == true,
              "reading: a page reads \"Looked at ...\", never a duration (got \(cabinNote?.bullets.map(\.text) ?? []))")

        // fix/sx-all round 1 (real-model run): a page reads by its own title, never the site's parts or a lowered name.
        for (app, title, site, expect) in [
            ("Google Chrome", "Swift concurrency: Behind the scenes - WWDC21 - Videos - Apple Developer", "developer.apple.com", "Looked at Swift concurrency: Behind the scenes."),
            ("Google Chrome", "swift - How to compare vector clocks for concurrent writes", "stackoverflow.com", "Looked at how to compare vector clocks for concurrent writes."),
            ("Discord", "#help | Tallybird Community", "", "Viewed #help on Discord."),
        ] {
            let r = try request("pg", (0..<4).map { _ in window(app, title, site: site).merging(["typing": "on"]) { $1 } })
            let n = try? await CanonicalLocalWriter(runtime: Loads(), policy: { _, _ in true }).generate(r, completeActions: r.actions)
            check(n?.bullets.first?.text == expect, "reading: \"\(title)\" reads \"\(expect)\" (got \(n?.bullets.map(\.text) ?? []))")
        }
        let video = try request("yt", (0..<4).map { _ in window("Google Chrome", "Swift actors explained - YouTube", site: "youtube.com") })
        let videoNote = try? await CanonicalLocalWriter(runtime: Loads(), policy: { _, _ in true }).generate(video, completeActions: video.actions)
        check(videoNote?.bullets.first?.text == "Viewed Swift actors explained on YouTube.", "reading: a short video observation reads \"Viewed ...\" (got \(videoNote?.bullets.map(\.text) ?? []))")

        for (gap, verb) in [(0, "Viewed"), (269, "Viewed"), (270, "Watched")] {
            let start = Date(timeIntervalSince1970: 1_000_000), end = start.addingTimeInterval(Double(gap))
            let format = ISO8601DateFormatter()
            let rows = [window("Google Chrome", "Swift actors explained - YouTube", site: "youtube.com").merging(["at": format.string(from: start)]) { $1 },
                        window("Google Chrome", "Swift actors explained - YouTube", site: "youtube.com").merging(["at": format.string(from: end)]) { $1 }]
            let r = try request("video-edge", rows), v = try ModelView(request: r, actions: r.actions)
            let n = try CanonicalGrounding.codeNote(r, view: v)
            let words = n.bullets.map(\.text).joined(separator: " ")
            check(v.items.first?.seconds == Double(gap + 30) && words.hasPrefix(verb + " Swift actors explained")
                  && (try? CanonicalGrounding.check(n, request: r, view: v)) != nil,
                  "video observation \(gap+30)s: \(verb) preserves the existing300s boundary (got \(words))")
        }

        // fix/sx-all round 1 (P2): a webmail reply with no recipient leads with its thread, the subject in lower case.
        check(replyView.text.contains("Start with: Replied on the pricing for the team plan thread"), "reply: \"Replied on the pricing for the team plan thread\" leads")

        // fix/sx-all round 1 (P2): a send's title never turns it round ("... from Priya" for an email to Priya).
        let priyaR = try request("p0", [p0[0].1]), priyaV = try ModelView(request: priyaR, actions: priyaR.actions)
        let priyaNote = try? CanonicalGrounding.salvage(p0[0].2, request: priyaR, view: priyaV, provider: CanonicalLocalWriter.provider)
        check(priyaNote.map { !$0.title.lowercased().contains("from priya") && !$0.title.isEmpty } == true, "title: an email to Priya is never titled \"... from Priya\" (got \(priyaNote?.title ?? "nil"))")

        // fix/sx-all round 1 (P2): a long title drops its site name before it is cut, and never ends on " -".
        let linear = try request("lin", (0..<3).map { _ in window("Google Chrome", "TAL-212 Sync conflicts on second device after reinstall when offline for more than a day - Linear", site: "linear.app") })
        let linNote = try? await CanonicalLocalWriter(runtime: Loads(), policy: { _, _ in true }).generate(linear, completeActions: linear.actions)
        check(linNote.map { !$0.title.hasSuffix("-") && !$0.title.hasSuffix(" -") && !$0.title.contains("Linear") } == true, "title: a Linear title is cut cleanly (got \(linNote?.title ?? "nil"))")

        // fix/sx-all round 2 (F8, F4): a text sent in a window titled "Messages" with no conversation name read. The prompt
        // for it names no one (the real model wrote "Texted Q7" from the examples); a name the items don't show is taken
        // out and the rest kept; "Texted." and "Drafted a text" are filler, so code writes no line rather than those.
        let unnamed = try request("un", [typed("Messages", "Messages", "on my way, 10 min", surface: "text")])
        let unnamedView = try ModelView(request: unnamed, actions: unnamed.actions)
        let unnamedPrompt = CanonicalGrounding.instruction(for: unnamedView)
        check(unnamedView.text.contains("name no one") && unnamedView.text.contains("Start with: Texted") && !unnamedPrompt.contains("Q7") && !unnamedPrompt.contains("Lumo"),
              "unnamed send: the item says \"name no one\" and its prompt names no Q7 or Lumo")
        check(CanonicalGrounding.instruction(for: m5View) == CanonicalGrounding.instruction, "named send: the usual prompt")
        check(refused(answer("On the way", "Texted."), unnamed, unnamedView) && refused(answer("On the way", "Texted Q7 that you're on the way."), unnamed, unnamedView),
              "unnamed send: \"Texted.\" and \"Texted Q7 ...\" are refused")
        let stripped = try? CanonicalGrounding.salvage(answer("On the way", "Texted Q7 about being on the way."), request: unnamed, view: unnamedView, provider: CanonicalLocalWriter.provider)
        check(stripped?.bullets.map(\.text) == ["Texted about being on the way."], "unnamed send: salvage takes the unshown name out, keeps the rest (got \(stripped?.bullets.map(\.text) ?? []))")
        // Round 3: the person's own note, plan or request still says whose words they are (rule 4): "You noted ..." is kept.
        let corrected = try request("yn", [["kind": "window.changed", "app": "Notes", "title": "Research", "description": "User correction (not observed): Corrected research topic", "state": "reported"]])
        if let cv = try? ModelView(request: corrected, actions: corrected.actions), let item = cv.items.first, item.kind == .note {
            let noted = #"{"title":"Research in Notes","bullets":[{"ids":["\#(item.alias)"],"text":"You noted a corrected research topic."}]}"#
            check(!refused(noted, corrected, cv), "second person: a YOUR NOTE line keeps \"You noted ...\" (rule 4)")
            let other = try? CanonicalGrounding.validate(#"{"title":"Research in Notes","bullets":[{"ids":["\#(item.alias)"],"text":"You noted that your topic changed."}]}"#, request: corrected, view: cv, provider: CanonicalLocalWriter.provider)
            check(other.map { $0.bullets.allSatisfy { !$0.text.lowercased().contains("your") } } ?? true, "second person: only the cue itself, never another \"your\" (got \(other?.bullets.map(\.text) ?? []))")
        } else { check(false, "second person: the correction fixture is a YOUR NOTE item") }
        // Round 3 (P2), claude/messages-1003: a text's gist keeps "you" in salvage too, with the unshown name taken out.
        let youLine = try? CanonicalGrounding.salvage(answer("On the way", "Texted Q7 that you're on the way."), request: unnamed, view: unnamedView, provider: CanonicalLocalWriter.provider)
        check(youLine?.bullets.map(\.text) == ["Texted that you're on the way."],
              "second person: salvage keeps a text's gist without the unshown name (got \(youLine?.bullets.map(\.text) ?? []))")
        let unnamedCode = try? CanonicalGrounding.salvage(answer("Worked in Messages", "Had Messages open."), request: unnamed, view: unnamedView, provider: CanonicalLocalWriter.provider)
        // (No line at all leaves the note pending: the moment keeps its own line; never a filler line.)
        check(unnamedCode.map { $0.bullets.allSatisfy { !CanonicalGrounding.sharedFiller($0.text, apps: ["Messages"]) && !$0.text.hasPrefix("Drafted a text") } } ?? true,
              "unnamed send: code never writes \"Texted.\" or \"Drafted a text\" (got \(unnamedCode?.bullets.map(\.text) ?? []))")
        for line in ["Texted.", "Drafted a text.", "Drafted a message in Messages.", "Wrote something on x.com.", "Drafted an email.", "Emailed someone."] {
            check(CanonicalGrounding.sharedFiller(line, apps: []), "filler: \"\(line)\"")
        }
        for line in ["Drafted a message in #eng.", "Emailed Riley about Launch checklist.", "Wrote an email to Dana about the offsite."] {
            check(!CanonicalGrounding.sharedFiller(line, apps: []), "not filler: \"\(line)\"")
        }

        // fix/sx-all round 2 (F1): core rewrites notes of every version but these, for recent days.
        check(NoteWriterVersions.current == CanonicalGrounding.currentVersions && NoteWriterVersions.outdated("qwen35-4b-q4-b9723-prompt7-validator9")
              && !NoteWriterVersions.outdated(CanonicalGrounding.localVersion) && !NoteWriterVersions.outdated("1")
              && NoteWriterVersions.outdated("code-moment5-validator12") && NoteWriterVersions.outdated("code-fallback1-validator12"),
              "versions: core's current writer versions are the writer's; prompt7-validator9 is outdated, a fixture's \"1\" is not")

        // fix/sx-all round 2 (F16): MemoryCore's NoteFiller (the day card and recall) is the writer's list, line for line.
        check(NoteFiller.patterns == CanonicalGrounding.fillerPatterns && NoteFiller.knownApps == CanonicalGrounding.fillerApps
              && NoteFiller.ais == CanonicalGrounding.fillerAIs && NoteFiller.appPatterns("x") == CanonicalGrounding.fillerAppPatterns("x"),
              "filler parity: NoteFiller holds the writer's patterns, apps and AI names")
        let fillerSamples = ["Texted.", "Drafted a text.", "Wrote a message in Messages.", "Wrote an email to Dana about the offsite.", "Had a chat with Priya on Microsoft Teams.",
                             "Had a conversation with Dana about pricing.", "Drafted a message to Claude.", "Drafted a message in #eng.", "Worked in Slack.", "Notes app",
                             "Emailed someone.", "Wrote something on x.com.", "About 38 minutes.", "Texted Sam.", "Asked Claude about vector clocks."]
        check(fillerSamples.allSatisfy { NoteFiller.isFiller($0, apps: ["Notes"]) == CanonicalGrounding.sharedFiller($0, apps: ["Notes"]) },
              "filler parity: the day card and the writer agree on every sample")
        check(!NoteFiller.isFiller("Wrote an email to Dana about the offsite.", apps: []) && NoteFiller.isFiller("Wrote a message in Messages.", apps: []),
              "filler: \"Wrote an email to Dana about ...\" is kept, \"Wrote a message in Messages.\" dropped")

        // fix/sx-all round 2 (F13): the typed words said again with small words changed are a copy, in the writer and core.
        let pairTyped = "added the two-worker test, and addressed all the comments Marco left"
        let pairNote = "Addressed Marco's comments and added a two-worker test."
        let prc = try request("prc", [typed("Google Chrome", "github.com", pairTyped, surface: "other", site: "github.com", detected: false)])
        let prcView = try ModelView(request: prc, actions: prc.actions)
        check(refused(answer("Retry test", pairNote), prc, prcView), "copy: \"\(pairNote)\" is refused by the writer")
        check(TypedVerbatimGuard.copies(pairNote, fromAny: [pairTyped]), "copy: \"\(pairNote)\" is refused by core")
        check(!TypedVerbatimGuard.copies("Replied to Marco's review with a new test.", fromAny: [pairTyped]), "copy: a line in its own words passes core")

        // fix/sx-all round 2 (F12, F15, F10): threads by who, never one "email" or "texts:" thread for everyone; the work on
        // one issue is one thread.
        func plan(_ moments: [(String, [ThreadEntity])], gists: [String: MomentGist] = [:]) -> ThreadPlan {
            var acts: [ThreadAction] = [], t = Date(timeIntervalSince1970: 1_790_000_000)
            for (m, es) in moments { for (i, e) in es.enumerated() { acts.append(ThreadAction(id: "\(m)-\(i)", moment: m, at: t, idle: false, entity: e)); t += 90 } }
            return ThreadPlanner.plan(acts, gists: gists)
        }
        let toRiley = ThreadEntities.entity(app: "Mail", bundle: "com.apple.mail", site: "", title: "Launch checklist", to: "Riley")
        let toDana = ThreadEntities.entity(app: "Mail", bundle: "com.apple.mail", site: "", title: "Offsite dates", to: "Dana")
        let mailPlan = plan([("e1", [toRiley, toRiley]), ("e2", [toDana, toDana])])
        let mailThreads = mailPlan.threads(for: ["e1", "e2"])
        check(mailPlan.momentKey["e1"] != mailPlan.momentKey["e2"] && mailThreads.count == 2 && !mailThreads.contains { $0.people.contains("Riley") && $0.people.contains("Dana") }
              && Set(mailThreads.map(\.label)).count == 2, "threads: emails to Riley and to Dana are two threads (\(mailThreads.map(\.label)))")
        let inbox = ThreadEntities.entity(app: "Mail", bundle: "com.apple.mail", site: "", title: "Inbox (12)")
        check(inbox.raw == "email", "threads: only inbox triage is the one \"email\" thread (\(inbox.raw))")
        let msgWin = ThreadEntities.entity(app: "Messages", bundle: "com.apple.MobileSMS", site: "", title: "Messages")
        let msgRiley = ThreadEntities.entity(app: "Messages", bundle: "com.apple.MobileSMS", site: "", title: "Messages", to: "Riley")
        let msgDana = ThreadEntities.entity(app: "Messages", bundle: "com.apple.MobileSMS", site: "", title: "Messages", to: "Dana")
        let textPlan = plan([("t1", [msgWin, msgWin, msgWin, msgRiley]), ("t2", [msgWin, msgWin, msgWin, msgDana]), ("t3", [msgWin])])
        let textKeys = ["t1", "t2", "t3"].compactMap { textPlan.momentKey[$0] }
        check(textKeys.count == 3 && Set(textKeys).count == 3 && !textKeys.contains("texts:") && textPlan.momentKey["t1"] == "texts:riley",
              "threads: Messages windows titled \"Messages\" go by who the texts went to, never one \"texts:\" thread (\(textKeys))")
        let code = ThreadEntities.entity(app: "Xcode", bundle: "com.apple.dt.Xcode", site: "", title: "webhooks.swift \u{2014} loomwork")
        let pr212 = ThreadEntities.entity(app: "Google Chrome", bundle: "com.google.Chrome", site: "github.com",
                                           title: "Fix double webhook retries (LOOM-88) by sam \u{00B7} Pull Request #212 \u{00B7} acme/loomwork")
        let issue = ThreadEntities.entity(app: "Google Chrome", bundle: "com.google.Chrome", site: "linear.app", title: "LOOM-88 Webhook retries fire twice - Linear")
        let loomAsk = ThreadEntities.entity(app: "Claude", bundle: "com.anthropic.claudefordesktop", site: "", title: "New chat")
        let workPlan = plan([("w1", [code, code, code]), ("w2", [pr212, pr212]), ("w3", [issue, issue]), ("w4", [loomAsk, loomAsk])],
                            gists: ["w4": MomentGist(title: "Webhook retries for LOOM-88", intent: "Asked Claude why webhook retries fire twice for LOOM-88.")])
        let workKeys = Set(["w1", "w2", "w3", "w4"].compactMap { workPlan.momentKey[$0] })
        check(workKeys.count == 1, "threads: the code, its PR, the LOOM-88 issue and the ask about it are one thread (\(workKeys))")
        let other = ThreadEntities.entity(app: "Google Chrome", bundle: "com.google.Chrome", site: "airbnb.com", title: "Cabins near Sintra - Airbnb")
        let apart = plan([("a1", [code, code]), ("a2", [other, other])])
        check(apart.momentKey["a1"] != apart.momentKey["a2"], "threads: an unrelated page stays its own thread")

        // fix/sx-all round 2 (F3): with no model, a send line names the subject code read from the window.
        let mailAction = try JSONDecoder().decode(CanonicalAction.self, from: Data(#"{"id":"m1","evidenceIDs":[],"at":"2026-09-24T16:10:00Z","kind":"keyboard.text_input","app":"Mail","bundle":"com.apple.mail","site":"","title":"Launch checklist","description":"","state":"observed","revision":"r","subject":"","observationKey":"k"}"#.utf8))
        // email-1003 (owner decision 2026-10-03): the subject is quoted after a dash ("Emailed Sam — 'Startup credits question'"),
        // from the compose window's title; was "Emailed Riley about Launch checklist".
        let emailed = MemoryStore.sendLine(mailAction, surface: "email", to: "Riley", label: "Email with Riley about Launch checklist")
        check(emailed == "Emailed Riley — 'Launch checklist'", "no model: an email send says who and the subject code read (\(emailed ?? "nil"))")
        var untitled = mailAction; untitled.title = "New Message"
        check(MemoryStore.sendLine(untitled, surface: "email", to: "Riley", label: "Email with Riley") == "Emailed Riley", "no model: an email send with no subject says who")
        check(MemoryStore.sendLine(untitled, surface: "email", to: "Riley", label: "Email with Riley about Launch checklist") == "Emailed Riley — 'Launch checklist'",
              "no model: with no subject in the title, the thread's subject is used")

        print(failures == 0 ? "PASS notes-quality: \(passes) checks" : "FAIL notes-quality: \(failures) of \(passes + failures) checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
