import Foundation
import MemoryCore
import PrivacyPolicy

/// Threads (Preview 4, LevelThreads): moments are grouped by what they are about (people, documents, projects, sites),
/// not by time alone; threads rank by focused time; a block's and a day's headline is the main thread only and the
/// others are bullets with names and minutes. Golden expectations for the multitasking sample day, the entity and
/// planner rules they rest on, and the privacy rules (typed words never reach a level note; no window-title noise).
/// Synthetic data only; no model runs (the code titles are what DayDream shows with summaries off).
func runThreadChecks(home: URL) throws {
    // MARK: entities
    func e(_ app: String, _ bundle: String, _ title: String, _ url: String = "", to: String? = nil) -> ThreadEntity {
        ThreadEntities.entity(app: app, bundle: bundle, site: URL(string: url)?.host ?? "", title: title, to: to)
    }
    let maya = e("Messages", "com.apple.MobileSMS", "Maya")
    try check(maya.kind == "texts" && maya.people == ["Maya"] && maya.label == "Texts with Maya", "entity: a Messages conversation is a person")
    try check(e("Messages", "com.apple.MobileSMS", "Maya, Sam & 2 more").people == ["Maya", "Sam"], "entity: a group chat names its people, not \"2 more\"")
    try check(e("Messages", "com.apple.MobileSMS", "+1 (555) 010-4477").people.isEmpty, "entity: a phone number is not a name")
    try check(e("Messages", "com.apple.MobileSMS", "", to: "Maya").people == ["Maya"], "entity: a typed row's recipient label names the person")
    // claude/catchup-1003: Siri's suggested contact ("Maybe: Maya") is Maya.
    let maybe = e("Messages", "com.apple.MobileSMS", "Maybe: Maya")
    try check(maybe.people == ["Maya"] && maybe.label == "Texts with Maya", "entity: Siri's \"Maybe:\" prefix is not part of the name (\(maybe.label))")
    try check(e("Messages", "com.apple.MobileSMS", "", to: "Maybe: Maya").people == ["Maya"], "entity: a recipient label's \"Maybe:\" prefix is dropped")
    try check(TitleClean.clean("Maybe: Maya Chen", app: "Messages") == "Maya Chen", "title: Messages' \"Maybe:\" prefix is dropped (\(TitleClean.clean("Maybe: Maya Chen", app: "Messages")))")
    try check(SendRules.conversationName("Maybe: Maya") == "Maya" && SendRules.siriSuggestion("Maybe:") == "Maybe:", "send facts: a Siri-suggested conversation is named; a bare \"Maybe:\" stays as it is")
    let eng = e("Chrome", "com.google.Chrome", "#eng (Channel) - Tallybird - Slack", "https://app.slack.com")
    try check(eng.kind == "slack" && eng.places == ["#eng"] && eng.people.isEmpty, "entity: a Slack channel")
    try check(e("Chrome", "com.google.Chrome", "Priya (DM) - Tallybird - Slack", "https://app.slack.com").people == ["Priya"], "entity: a Slack DM is a person")
    try check(e("Slack", "com.tinyspeck.slackmacgap", "Tallybird - Slack").people.isEmpty, "entity: a Slack workspace alone names no one")
    let inbox = e("Chrome", "com.google.Chrome", "Inbox (12) - riley@tallybird.example", "https://mail.google.com")
    try check(inbox.kind == "email" && inbox.label == "Email" && inbox.places.isEmpty, "entity: an inbox is email with no subject")
    let invoice = e("Chrome", "com.google.Chrome", "Re: Invoice #2291 from Hostwell - riley@tallybird.example - Gmail", "https://mail.google.com")
    try check(invoice.places == ["Invoice #2291 from Hostwell"] && !invoice.label.contains("@"), "entity: an email subject, without Re:, the account or Gmail")
    try check(e("Mail", "com.apple.mail", "Inbox – iCloud (14 messages)").label == "Email", "entity: Apple Mail's inbox is email")
    let doc = e("Chrome", "com.google.Chrome", "Q3 investor update - Google Docs", "https://docs.google.com")
    try check(doc.kind == "doc" && doc.label == "Q3 investor update" && doc.topic == ["q3", "investor", "update"], "entity: a Google Doc by its name")
    let pr = e("Chrome", "com.google.Chrome", "Add weekly summaries export by sam · Pull Request #418 · tallybird/tallybird", "https://github.com")
    try check(pr.kind == "pr" && pr.label == "PR #418: Add weekly summaries export" && pr.project == "tallybird", "entity: a pull request, its repo a project")
    try check(e("Xcode", "com.apple.dt.Xcode", "Tallybird — Debug navigator").raw == "code:tallybird"
              && e("Xcode", "com.apple.dt.Xcode", "ExportView.swift — Tallybird").raw == "code:tallybird", "entity: Xcode windows of one project are one project")
    try check(e("Terminal", "com.apple.Terminal", "tallybird — swift test").raw == "code:tallybird", "entity: a Terminal in the project folder")
    try check(e("Chrome", "com.google.Chrome", "How Linear builds product - YouTube", "https://www.youtube.com").label == "YouTube", "entity: YouTube is YouTube")
    try check(e("Zoom", "us.zoom.xos", "Weekly sync - Tallybird").kind == "meeting" && e("Zoom", "us.zoom.xos", "Zoom Meeting").label == "Zoom call", "entity: a meeting by its name (an unnamed Zoom meeting: \"Zoom call\")")
    // r1 summaries-quality: Teams chats and views, and Zoom with no call, are not meetings named by the raw title.
    let teamsChat = e("Microsoft Teams", "com.microsoft.teams2", "Chat | Maya Chen | Microsoft Teams")
    try check(teamsChat.kind == "chat" && teamsChat.people == ["Maya Chen"] && teamsChat.label == "Teams chat with Maya Chen" && !teamsChat.anchor,
              "entity: a Teams chat is a chat with its person, not a meeting (\(teamsChat.kind): \(teamsChat.label))")
    for title in ["Calendar | Calendar | Microsoft Teams", "Activity | Microsoft Teams", "Microsoft Teams", "Files | Microsoft Teams", "Q3 planning | Microsoft Teams"] {
        let x = e("Microsoft Teams", "com.microsoft.teams2", title)
        try check(x.kind == "app" && x.label == "Microsoft Teams", "entity: Teams '\(title)' is the app, not a meeting named by its title")
    }
    try check(e("Chrome", "com.google.Chrome", "Calendar | Calendar | Microsoft Teams", "https://teams.microsoft.com").kind == "app", "entity: Teams on the web too")
    let teamsMeeting = e("Microsoft Teams", "com.microsoft.teams2", "Meeting | Weekly sync | Microsoft Teams")
    try check(teamsMeeting.kind == "meeting" && teamsMeeting.label == "Weekly sync", "entity: a Teams meeting window is a meeting, by its name")
    try check(e("Microsoft Teams", "com.microsoft.teams2", "Meeting compact view | Microsoft Teams").label == "Meeting", "entity: an unnamed Teams meeting is \"Meeting\"")
    for title in ["Zoom Workplace", "Zoom - Free Account", "Zoom Cloud Meetings", "Zoom", ""] {
        let x = e("zoom.us", "us.zoom.xos", title)
        try check(x.kind == "app" && x.label == "Zoom", "entity: Zoom's home window '\(title)' is the app, not a meeting")
    }
    for t in [teamsChat, teamsMeeting] + ["Chat | Maya Chen | Microsoft Teams", "Calendar | Calendar | Microsoft Teams"].map({ e("Microsoft Teams", "com.microsoft.teams2", $0) }) {
        try check(!t.label.contains("|") && !t.label.contains("Microsoft Teams |"), "entity: no Teams label keeps the raw window title (\(t.label))")
    }
    let chatThread = LevelThread(key: "chat:teams|maya chen", kind: "chat", label: "Teams chat with Maya Chen", people: ["Maya Chen"], places: [], seconds: 600, bursts: 1, children: ["m1"], start: "a", end: "b")
    let mainThread = LevelThread(key: "doc:plan", kind: "doc", label: "Plan", people: [], places: [], seconds: 1200, bursts: 1, children: ["m2"], start: "a", end: "b")
    try check(LevelThreads.bullets([mainThread, chatThread], max: 4).map(\.text) == ["Teams chat with Maya Chen, ~10 min"], "a Teams chat bullet names its person")
    // fix/sx-all round 1: WhatsApp is named by its app, never "Texts"; a project keeps its own casing across apps.
    let wa = e("WhatsApp", "net.whatsapp.WhatsApp", "Mom")
    try check(wa.label == "WhatsApp with Mom" && !wa.label.hasPrefix("Texts"), "entity: a WhatsApp chat reads \"WhatsApp with Mom\" (\(wa.label))")
    do {
        let xc = e("Xcode", "com.apple.dt.Xcode", "ExportView.swift — DayDream"), term = e("Terminal", "com.apple.Terminal", "daydream — zsh")
        let a0 = Date(timeIntervalSince1970: 1_790_000_000)
        let acts = [ThreadAction(id: "c1", moment: "m1", at: a0, idle: false, entity: term), ThreadAction(id: "c2", moment: "m1", at: a0.addingTimeInterval(60), idle: false, entity: xc),
                    ThreadAction(id: "c3", moment: "m1", at: a0.addingTimeInterval(120), idle: false, entity: xc)]
        let label = ThreadPlanner.plan(acts).threads(for: ["m1"]).first?.label ?? ""
        try check(label == "DayDream code", "a project keeps its casing: \"DayDream code\", never \"Daydream code\" (\(label))")
        // Only a terminal's lower-case folder seen all day: the product's known casing, and other projects as written.
        let only = e("Terminal", "com.apple.Terminal", "daydream - swift test"), other = e("Terminal", "com.apple.Terminal", "tallybird-sync — zsh")
        try check(only.label == "DayDream code" && other.label == "Tallybird-sync code", "a lower-case folder: \"DayDream code\", \"Tallybird-sync code\" (\(only.label), \(other.label))")
    }
    try check(ThreadEntities.clean("(3) WhatsApp") == "WhatsApp" && ThreadEntities.clean("Inbox (12) - riley@tallybird.example") == "Inbox",
              "titles lose unread counts and email addresses")
    try check(ThreadEntities.linked(["investor", "update"], ["q3", "investor", "update"]) && ThreadEntities.linked(["weekly", "sync"], ["weekly", "sync", "tallybird"]),
              "titles sharing their words link (Investor update / Q3 investor update; Weekly sync notes / Weekly sync)")
    try check(!ThreadEntities.linked(["weekly", "sync"], ["weekly", "review"]) && !ThreadEntities.linked(["q3", "metrics"], ["q3", "investor", "update"]),
              "one shared word never links")

    // MARK: planner
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    var input = [ThreadAction](), n = 0
    func stretch(_ moment: String, _ entity: ThreadEntity, _ fromMinute: Int, _ minutes: Int) {
        var s = 0
        while s < minutes * 60 { n += 1; input.append(ThreadAction(id: String(format: "a%04d", n), moment: moment, at: t0.addingTimeInterval(Double(fromMinute * 60 + s)), idle: false, entity: entity)); s += 60 }
    }
    let sam = e("Messages", "com.apple.MobileSMS", "Sam"), meet = e("Zoom", "us.zoom.xos", "Board prep")
    stretch("doc1", doc, 0, 20); stretch("maya1", maya, 20, 3); stretch("doc1", doc, 23, 15); stretch("sam1", sam, 38, 1)
    stretch("doc1", doc, 39, 20); stretch("maya2", maya, 59, 4); stretch("doc1", doc, 63, 10)
    stretch("meet", meet, 73, 40); stretch("doc2", doc, 113, 25)
    let plan = ThreadPlanner.plan(input)
    try check(plan.blocks.count == 3 && plan.blocks[0] == ["doc1", "maya1", "sam1", "maya2"] && plan.blocks[1] == ["meet"] && plan.blocks[2] == ["doc2"],
              "blocks: short switches stay in the block; a 40-minute meeting takes over; the document again after it is a new block")
    let first = plan.threads(for: Set(plan.blocks[0]))
    try check(first.first?.key == "doc:q3 investor update" && first.first?.seconds == 65 * 60, "the main thread is the one with the most focused time")
    let texts = first.first { $0.key == "texts:maya" }
    try check(texts?.bursts == 2 && texts?.children == ["maya1", "maya2"] && texts?.seconds == 7 * 60, "two texting bursts with Maya are one thread")
    let bullets = LevelThreads.bullets(first, max: 4).map(\.text)
    try check(bullets == ["Texts with Maya and Sam, ~8 min"], "side threads are bullets with names and minutes: \(bullets)")
    // r1 summaries-quality: Slack names people, then channels after "in"; an "Also" bullet never stacks a second "and".
    try check(LevelThreads.channelLabel("slack", people: ["Priya Patel"], places: ["#fundraising", "#eng"]) == "Slack with Priya Patel, in #fundraising and #eng",
              "Slack: people, then channels after \"in\" (a channel never reads as a person)")
    func side(_ label: String, _ minutes: Int, _ kind: String = "doc") -> LevelThread {
        LevelThread(key: label, kind: kind, label: label, people: [], places: [], seconds: minutes * 60, bursts: 1, children: [label], start: label, end: label)
    }
    // notes-quality: at most four side bullets, never an "Also" line; what was said to others first.
    let also = LevelThreads.bullets([side("Main", 60), side("A", 20), side("B", 15), side("C", 12), side("Slack with Priya Patel, in #fundraising and #eng", 9), side("Claude", 6)], max: 4).map(\.text)
    try check(also == ["A, ~20 min", "B, ~15 min", "C, ~10 min", "Slack with Priya Patel, in #fundraising and #eng, ~9 min"], "no Also: the four biggest side threads (\(also))")
    var said = side("Texts with Maya", 2, "texts"); said.people = ["Maya"]; said.intent = "Texted Maya about the launch party."
    let first4 = LevelThreads.bullets([side("Main", 60), side("A", 20), side("B", 15), side("C", 12), side("YouTube", 9, "video"), said], max: 4).map(\.text)
    try check(first4 == ["Texted Maya about the launch party.", "A, ~20 min", "B, ~15 min", "C, ~10 min"], "a sent line comes first; a short video is no bullet (\(first4))")
    // fix/sx-all: passive viewing never leads while something active held at least half its time (typing off, 9/23).
    input = []
    let travelVideo = e("Chrome", "com.google.Chrome", "Lisbon in 3 days - travel guide - YouTube", "https://www.youtube.com")
    let cabins = e("Chrome", "com.google.Chrome", "Cabins near Sintra - Airbnb", "https://www.airbnb.com")
    stretch("video1", travelVideo, 0, 30); stretch("cabins1", cabins, 30, 17)
    let passivePlan = ThreadPlanner.plan(input)
    let passiveThreads = passivePlan.threads(for: Set(passivePlan.blocks.flatMap { $0 }))
    try check(passiveThreads.first?.kind != "video" && passiveThreads.contains { $0.kind == "video" },
              "a 30-minute video is not the main thread next to 17 minutes of searching cabins (\(passiveThreads.map(\.label)))")
    // fix/sx-all: a mailbox view TitleClean named "Email" (the cloud view) is no subject: never "Email about Email".
    input = []
    stretch("mailbox1", e("Chrome", "com.google.Chrome", "Email", "https://mail.google.com"), 0, 10)
    let mailPlan = ThreadPlanner.plan(input)
    let mailThreads = mailPlan.threads(for: Set(mailPlan.blocks.flatMap { $0 }))
    try check(mailThreads.first?.label == "Email", "a mailbox view named \"Email\" is the Email thread, never \"Email about Email\" (\(mailThreads.map(\.label)))")
    // fix/sx-all: the day's threads (merged from its blocks) lead the same way: the 9/23 day read "Watched Lisbon ...".
    func block(_ id: String, _ threads: [LevelThread]) throws -> LevelNote {
        var note = try JSONDecoder().decode(LevelNote.self, from: Data(#"{"id":"\#(id)","level":"block","period":"2026-09-23","timezone":"UTC","start":"\#(id)","end":"\#(id)","title":"","lines":[],"children":[],"actionIDs":[],"inputRevision":"","typedDerived":false,"frozen":false,"generator":"code","generatorVersion":"","generatedAt":"","version":1}"#.utf8))
        note.threads = threads
        return note
    }
    let dayThreads = LevelThreads.merge([try block("b1", [side("Lisbon in 3 days travel guide", 30, "video")]), try block("b2", [side("Cabins near Sintra", 17, "search")])])
    try check(dayThreads.map(\.label) == ["Cabins near Sintra", "Lisbon in 3 days travel guide"],
              "a day: a 30-minute video is not the main thread next to 17 minutes of searching cabins (\(dayThreads.map(\.label)))")
    // r1 summaries-quality: the span phrase never overstates a short stretch by much.
    func phrase(_ minutes: Int) -> String { MemoryStore.spanPhrase(start: iso(t0), end: iso(t0.addingTimeInterval(Double(minutes * 60))), timezone: "UTC") }
    try check(phrase(12) == "A few minutes" && phrase(20) == "About 20 minutes" && phrase(30) == "About half an hour" && phrase(45) == "About 45 minutes" && phrase(60) == "About an hour",
              "span phrase: 12 -> a few minutes, 20 -> about 20 minutes, 30 -> half an hour, 45 -> 45 minutes, 60 -> an hour")
    try check(LevelThreads.duration(59) == "~1 min" && LevelThreads.duration(14 * 60 + 40) == "~15 min" && LevelThreads.duration(83 * 60) == "~1 hr 25 min",
              "minutes read as ~N min")

    // fix/sx-all round 3 (the Wednesday coding day): code is joined by project only through its pull request or issue; an
    // email or an AI ask that names the repo keeps its own thread; the code thread is named by its pull request; a Slack
    // post from the web composer (row titled with the host, its place "#infra") joins #infra, never an empty "slack:".
    do {
        input = []
        let issue903 = e("Chrome", "com.google.Chrome", "Sync drops rows when the laptop sleeps mid-upload · Issue #903 · tallybird/harborline", "https://github.com")
        let pr911 = e("Chrome", "com.google.Chrome", "Resume interrupted uploads from the last acked chunk by sam · Pull Request #911 · tallybird/harborline", "https://github.com")
        let cursor = e("Cursor", "com.todesktop.230313mzl4w4u92", "uploader.rs — harborline")
        let iterm = e("iTerm2", "com.googlecode.iterm2", "harborline — zsh")
        let owen = e("Mail", "com.apple.mail", "Harborline 2.0 launch date moved to October 14", to: "Owen Blake")
        let gpt = e("ChatGPT", "com.openai.chat", "Harborline 2.0 release notes")
        let infra = e("Chrome", "com.google.Chrome", "#infra (Channel) - Tallybird - Slack", "https://app.slack.com")
        let infraPost = e("Chrome", "com.google.Chrome", "app.slack.com", "https://app.slack.com", to: "#infra")
        // Someone else's pull request in the same repo (a review): its own thread, and never the code thread's name.
        let pr907 = e("Chrome", "com.google.Chrome", "Add Windows ARM builds by tomasz-k · Pull Request #907 · tallybird/harborline", "https://github.com")
        try check(pr907.author == "tomasz-k" && pr911.author == "sam" && issue903.author == nil, "a pull request's author is read from its title")
        try check(infraPost.raw == "slack:#infra" && infraPost.places == ["#infra"], "a Slack web post keys by its composer's place: \(infraPost.raw)")
        stretch("i903", issue903, 0, 6); stretch("cur1", cursor, 6, 25); stretch("term1", iterm, 31, 15); stretch("pr911", pr911, 46, 12)
        stretch("slk1", infra, 58, 1); stretch("slk2", infraPost, 59, 1); stretch("cur2", cursor, 60, 20)
        stretch("owen", owen, 80, 4); stretch("gpt", gpt, 84, 6); stretch("cur3", cursor, 90, 20); stretch("pr907", pr907, 110, 12)
        let gists = ["owen": MomentGist(title: "Harborline 2.0 launch date moved to October 14", intent: "Emailed Owen Blake about moving the launch to October 14."),
                     "gpt": MomentGist(title: "Harborline 2.0 release notes", intent: "Asked ChatGPT to draft Harborline 2.0 release notes.")]
        let beforeInput = input
        let codePlan = ThreadPlanner.plan(input, gists: gists, selfNames: ["sam"])
        let all = codePlan.threads(for: Set(codePlan.blocks.flatMap { $0 }))
        let main = all.first
        let mainMoments = Set(main?.children ?? [])
        try check(main?.kind == "code" && main?.label.hasPrefix("PR #911") == true,
                  "the code thread is named by the person's own pull request, never someone else's or \"<Repo> code\" (\(main?.label ?? "nil"))")
        try check(!mainMoments.contains("pr907") && all.contains { $0.children == ["pr907"] },
                  "someone else's pull request in the same repo (a review) is its own thread (\(all.map { "\($0.label): \($0.children)" }))")
        // Not knowing who the person is, it still never names the code by the pull request of a moment it wasn't keyed by.
        let unknown = ThreadPlanner.plan(beforeInput, gists: gists)
        let unknownMain = unknown.threads(for: Set(unknown.blocks.flatMap { $0 })).first
        try check(unknownMain?.label.hasPrefix("PR #907") != true, "with no account names, the code thread isn't named by the review (\(unknownMain?.label ?? "nil"))")
        try check(["i903", "cur1", "term1", "pr911", "cur2", "cur3"].allSatisfy(mainMoments.contains), "the issue, the PR, Cursor and iTerm2 are one thread (\(main?.children ?? []))")
        try check(!mainMoments.contains("owen") && !mainMoments.contains("gpt"),
                  "an email to Owen and a ChatGPT ask that name \"Harborline\" keep their own threads (\(all.map { "\($0.label): \($0.children)" }))")
        try check(!all.contains { $0.key == "slack:" } && all.filter { $0.kind == "slack" }.count == 1 && all.first { $0.kind == "slack" }?.children == ["slk1", "slk2"],
                  "the #infra channel and the post from its web composer are one Slack thread, never an empty \"slack:\" key (\(all.filter { $0.kind == "slack" }.map { "\($0.key): \($0.children)" }))")
        let slackBullets = LevelThreads.bullets(all, max: 4).map(\.text).filter { $0.localizedCaseInsensitiveContains("slack") || $0.contains("#infra") }
        try check(slackBullets.count <= 1, "one Slack bullet, never a post and a \"Slack in #infra, ~N min\" line (\(slackBullets))")
        // The Friday day: a Discord channel on the project's server is a chat, never a document that the project's name joins
        // to the code (it keyed the day's code thread "doc:help tallybird community discord").
        input = []
        let discord = e("Discord", "com.hnc.Discord", "#help | Tallybird Community - Discord")
        try check(discord.kind == "chat" && discord.comms && discord.label == "Discord in #help", "a Discord channel is a chat in that channel (\(discord.kind) \(discord.label))")
        let engine = e("Cursor", "com.todesktop.230313mzl4w4u92", "SyncEngine.swift — tallybird-sync")
        let pr530 = e("Chrome", "com.google.Chrome", "Offline sync conflict resolution by sam · Pull Request #530 · tallybird/tallybird-sync", "https://github.com")
        let helpDoc = e("Notes", "com.apple.Notes", "Tallybird Community help")
        stretch("eng1", engine, 0, 30); stretch("pr530", pr530, 30, 15); stretch("disc", discord, 45, 8); stretch("note", helpDoc, 53, 5); stretch("eng2", engine, 58, 20)
        let friPlan = ThreadPlanner.plan(input, gists: [:], selfNames: ["sam"])
        let friThreads = friPlan.threads(for: Set(friPlan.blocks.flatMap { $0 }))
        try check(friThreads.first?.label.hasPrefix("PR #530") == true && !(friThreads.first?.children.contains("disc") ?? true) && !(friThreads.first?.children.contains("note") ?? true),
                  "the code thread is named by its pull request; neither the Discord channel nor a note that names the project's server joins it (\(friThreads.map { "\($0.key) \($0.label): \($0.children)" }))")
        // A block of code alone is named by the PR its day's thread joined later, as the day is: never "Tallybird-sync code".
        let codeOnlyBlock = friPlan.threads(for: ["eng1"])
        try check(codeOnlyBlock.first?.label.hasPrefix("PR #530") == true, "a code-only stretch is named by its thread's pull request (\(codeOnlyBlock.map(\.label)))")
        // An AI chat linked only to a page is named by its own title, never the page's.
        input = []
        let linearPage = e("Chrome", "com.google.Chrome", "Linear – HAR-231 Flaky resume test on Linux CI", "https://linear.app")
        let claudeChat = e("Claude", "com.anthropic.claudefordesktop", "Debugging CI test failures")
        stretch("cl1", claudeChat, 0, 7); stretch("lin1", linearPage, 7, 9)
        let aiPlan = ThreadPlanner.plan(input, gists: ["cl1": MomentGist(title: "Debugging CI test failures", intent: "Asked Claude why cargo tests pass locally but time out on Linux CI."),
                                                       "lin1": MomentGist(title: "HAR-231 Flaky resume test on Linux CI", intent: nil)])
        let aiThreads = aiPlan.threads(for: Set(aiPlan.blocks.flatMap { $0 }))
        try check(aiThreads.allSatisfy { !$0.key.hasPrefix("ai:") || $0.kind == "ai" } && aiThreads.allSatisfy { !$0.label.hasPrefix("Linear") },
                  "an AI chat's thread is named by its own title, not the page beside it; no label keeps \"Linear –\" (\(aiThreads.map { "\($0.key) \($0.kind) \($0.label)" }))")
    }

    // MARK: golden: the multitasking sample day (today in the preview)
    let zone = "America/Los_Angeles"
    let temp = home.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let now = try DayScope.interval(day: "2026-09-29", timezone: zone).start.addingTimeInterval(20 * 3600)
    let (memory, report) = try PreviewSample.prepare(root: PreviewSample.root(temporaryDirectory: temp), now: now, timezone: zone, temporaryDirectory: temp)
    let store = try MemoryStore(home: memory)
    let today = try store.dayLevels(day: "2026-09-29", timezone: zone)
    guard let dayNote = today.day else { throw MemError.invalid("FAILED: the sample day has its day note") }
    print("THREADS golden day: \(dayNote.title)")
    for l in dayNote.lines { print("THREADS   • \(l.text)") }
    for b in today.blocks { print("THREADS block: \(b.title) | " + b.lines.map(\.text).joined(separator: " | ")) }
    try check(dayNote.title == "Q3 investor update", "golden: the day's headline is the main thread only")
    // fix/sx-all round 2: a capture landing mid-read is read again once; still changing, the day's notes stay.
    MemoryStore.levelReadFailuresForChecks = 1
    let retried = try store.dayLevels(day: "2026-09-29", timezone: zone, now: now)
    try check(retried.day?.title == dayNote.title && retried.live != nil && MemoryStore.levelReadFailuresForChecks == 0, "a day read that changed mid-read is read again once")
    MemoryStore.levelReadFailuresForChecks = 2
    let kept = try store.dayLevels(day: "2026-09-29", timezone: zone, now: now)
    try check(kept.day?.title == dayNote.title && kept.blocks.count == today.blocks.count && kept.live == nil, "a day still changing keeps its notes; only the live threads wait")
    MemoryStore.levelReadFailuresForChecks = 0
    try check(today.blocks.map(\.title).count == 5, "golden: five blocks (email triage, the update, the sync, the pull request, the update again)")
    #if DAYDREAM_OWNER_TYPING
    // The owner build keeps typed rows from Mail and Messages: the email recipients name the triage thread.
    // fix/sx-all round 2: an email to Priya and one to Dana are two threads (keyed by who each went to), so the triage
    // block is the first email's thread, and the email to Dana is its own line saying who.
    try check(today.blocks.first?.title == "A few minutes: Email about Q3 numbers for the board"
              && today.blocks.first?.lines.map(\.text).contains("Emailed Dana about the Northwind pilot kickoff.") == true,
              "golden (owner): the triage block is the email to Priya; the email to Dana is its own line naming who")
    #else
    // notes-quality: at most four side bullets, what was said to others first, never an "Also" line.
    try check(dayNote.lines.map(\.text) == ["Texts with Maya and Sam, ~20 min", "Email triage, ~15 min", "Slack with Priya, in #eng, ~15 min",
                                             "PR #418: Add weekly summaries export, ~55 min"],
              "golden: the day's bullets are its side threads, with names and minutes, the people first")
    try check(today.blocks.map(\.title) == ["A few minutes: Email triage", "Most of the morning: Q3 investor update",
                                            "About 45 minutes: Weekly sync - Tallybird", "About an hour: PR #418: Add weekly summaries export",
                                            "About half an hour: Q3 investor update"], "golden: block titles are their main threads")
    try check(today.blocks[1].lines.map(\.text) == ["Texts with Maya and Sam, ~10 min", "Slack with Priya, in #eng, ~9 min"],
              "golden: interleaved texts and Slack are the update block's bullets; the Q3 metrics sheet shares \"Q3\" and joins the update")
    try check(today.blocks[2].lines.map(\.text) == ["Texts with Maya and Sam, ~2 min", "YouTube, ~15 min"], "golden: the YouTube break sits under the sync")
    try check(today.blocks[3].lines.map(\.text) == ["Slack in #eng, ~4 min", "Texts with Maya, ~2 min"], "golden: the pull request and its code in Xcode are one thread")
    try check(today.blocks[4].lines.map(\.text) == ["Texts with Sam, ~3 min"], "golden: emailing the update is part of the update")
    #endif
    let update = today.blocks[1].threads?.first
    try check(update?.label == "Q3 investor update" && (update?.seconds ?? 0) > 90 * 60 && (update?.bursts ?? 0) >= 5,
              "golden: the Claude chat about the update's metrics joins the update; it came back in bursts (\(update?.label ?? "") \(update?.seconds ?? 0) \(update?.bursts ?? 0))")
    try check(today.blocks.allSatisfy { $0.generatorVersion == LevelWriterVersion.threads && $0.threads?.isEmpty == false }, "golden: every block is written from threads")

    // Every bullet and headline carries the moments it is about (a click highlights exactly them).
    let dayMoments = try store.dayLayers(day: "2026-09-29", timezone: zone, limit: 1, now: now).activities
    let momentByID = Dictionary(uniqueKeysWithValues: dayMoments.map { ($0.id, $0) })
    let messagesMoments = Set(dayMoments.filter { $0.apps.contains("Messages") }.map(\.id))
    // notes-quality: with typed rows (the owner build) the texts thread reads as what was texted ("Texted Sam asking for
    // the churn chart."): its lines together carry the day's Messages moments.
    let textsLines = dayNote.lines.filter { $0.text.hasPrefix("Texts with") || $0.text.hasPrefix("Texted ") }
    try check(!messagesMoments.isEmpty && Set(textsLines.flatMap { $0.moments ?? [] }) == messagesMoments, "a day bullet carries exactly its moments: the texts lines are the day's Messages moments")
    try check(dayNote.lines.allSatisfy { !($0.moments ?? []).isEmpty && ($0.moments ?? []).allSatisfy { momentByID[$0] != nil } }, "every day bullet names moments of the day")
    let mainMoments = Set(dayNote.threads?.first?.momentIDs ?? [])
    try check(!mainMoments.isEmpty && mainMoments.allSatisfy { momentByID[$0]?.subject.contains("investor update") == true || momentByID[$0]?.subject == "Investor update metrics"
                                                         || momentByID[$0]?.subject.contains("Q3 metrics") == true },
              "the headline's moments are the update's moments (the doc, the Claude chat, the email, the Q3 metrics sheet)")
    for b in today.blocks {
        let side = b.lines.filter { $0.text.contains(", ~") }
        try check(side.allSatisfy { Set($0.moments ?? []).isSubset(of: Set(b.children.map(\.id))) && $0.moments == $0.children }, "a block bullet's moments are its own moments (\(b.title))")
    }

    // Privacy and clean names: no typed words, no unread counts or addresses, at any level on any day.
    let typedWords = ["Running ten late", "save me a seat", "churn chart before noon", "seed-stage", "Thursday works", "final numbers go out",
                      "ship export beta wed", "Revenue grew"]
    var notes = [LevelNote]()
    for d in report.days { let lv = try store.dayLevels(day: d, timezone: zone); notes += lv.blocks + [lv.day, lv.week].compactMap { $0 } }
    var texts2 = [String]()
    for note in notes {
        texts2.append(note.title)
        texts2 += note.lines.map(\.text)
        for t in note.threads ?? [] { texts2.append(t.label); texts2 += t.people; texts2 += t.places }
    }
    func noisy(_ t: String) -> Bool { t.contains("@") || t.range(of: "\\(\\d+\\)", options: String.CompareOptions.regularExpression) != nil }
    try check(!texts2.isEmpty && !texts2.contains { t in typedWords.contains { t.localizedCaseInsensitiveContains($0) } }, "typed words never reach a block, day or week")
    try check(!texts2.contains(where: noisy), "no email address or unread count in any block, day or week (\(texts2.first(where: noisy) ?? ""))")
    try check(!texts2.contains { $0.hasPrefix("Mostly ") }, "no headline is \"Mostly <window title>\"")

    // MARK: the model names the main thread only
    guard let request = try store.levelRequest(id: today.blocks[1].id, timezone: zone, now: now) else { throw MemError.invalid("FAILED: the update block's request") }
    let code = LevelGrounding.extractive(request)
    let named = try LevelGrounding.validate(#"{"goal":"writing the Q3 investor update","lines":[{"ids":["m1"],"text":"Emailed Maya the update."}]}"#, request: request)
    try check(named.title == MemoryStore.spanPhrase(start: request.start, end: request.end, timezone: zone) + ": writing the Q3 investor update" && named.lines == code.lines,
              "a model names the main thread; the bullets stay the code's (its lines are ignored)")
    try check(LevelGrounding.check(title: named.title, lines: named.lines, request: request, extractive: false) == nil, "core accepts a model's name for the main thread")
    var refusedName = false
    do { _ = try LevelGrounding.validate(#"{"goal":"writing the update for Jordan"}"#, request: request) } catch { refusedName = true }
    try check(refusedName, "a name the main thread's notes don't have is refused")
    // fix/sx-all round 2 (F11): an -ing goal is grounded: a purpose verb passes, an activity no note says is refused.
    for goal in ["reviewing code for the update", "explaining the Q3 investor update"] {
        var refused = false
        do { _ = try LevelGrounding.validate("{\"goal\":\"\(goal)\"}", request: request) } catch { refused = true }
        try check(refused, "an -ing goal no note says is refused (\"\(goal)\")")
    }
    let fixing = try? LevelGrounding.validate(#"{"goal":"fixing the Q3 investor update"}"#, request: request)
    try check(fixing != nil, "a purpose -ing goal (\"fixing the Q3 investor update\") passes")
    // fix/sx-all round 3 (P0, the coding day's "Wrote the Harborline 2.0 release notes"): a goal or headline whose telling
    // words come only from a small part of the main thread's time is refused, and code's thread name stays.
    let mainKids = request.children.filter { (request.threads?.first?.children ?? []).contains($0.ref.id) }
    print("THREADS main children: " + mainKids.map { $0.title }.joined(separator: " | "))
    var sideRefused: String? = nil
    do { _ = try LevelGrounding.validate(#"{"goal":"updating the Q3 metrics sheet"}"#, request: request) } catch { sideRefused = "\(error)" }
    try check(sideRefused?.contains("\"main\"") == true && LevelGrounding.sideProblem("updating the Q3 metrics sheet", request) != nil,
              "a goal from one short side of the main thread is refused (\(sideRefused ?? "kept"))")
    try check(LevelGrounding.sideProblem("writing the Q3 investor update", request) == nil, "a goal naming the main thread holds")
    try check(LevelGrounding.check(title: MemoryStore.spanPhrase(start: request.start, end: request.end, timezone: zone) + ": updating the Q3 metrics sheet",
                                   lines: code.lines, request: request, extractive: false) != nil, "core refuses a stored title that names a small part")
    // fix/sx-all round 3 (the coding day's "Drafted release notes and merged PR #911"): a day headline whose telling words
    // only its side threads say (a block's lines) names a side thread, and is refused.
    do {
        func child(_ id: String, _ title: String, _ lines: [String], _ start: String, _ end: String) -> [String: Any] {
            ["alias": id, "ref": ["id": id, "version": "1", "start": start, "end": end], "label": id, "title": title, "lines": lines, "typed": false]
        }
        let kids: [[String: Any]] = [
            child("b1", "Most of the morning: fixing sync drops rows when the laptop sleeps", ["Asked ChatGPT to draft Harborline 2.0 release notes.", "Emailed Owen Blake about shifting the 2.0 launch."], "2026-09-16T15:52:00Z", "2026-09-16T18:35:00Z"),
            child("b2", "About an hour and a half: checking PR #911", ["Posted in #infra that 911 is merged and 2.0 rc1 is cut.", "Texted Theo about Sunday instead of Saturday."], "2026-09-16T19:58:00Z", "2026-09-16T21:39:00Z"),
            child("b3", "A few minutes: texting Brunch Club about Sunday brunch", [], "2026-09-16T15:30:00Z", "2026-09-16T15:37:00Z")]
        let main: [String: Any] = ["key": "pr:tallybird/harborline#911", "kind": "code", "label": "PR #911: Resume interrupted uploads from the last acked chunk", "people": [String](), "places": [String](),
                                   "seconds": 15000, "bursts": 2, "children": ["b1", "b2"], "start": "2026-09-16T15:52:00Z", "end": "2026-09-16T21:39:00Z"]
        let side: [String: Any] = ["key": "texts:brunch club", "kind": "texts", "label": "Texts with Brunch Club", "people": ["Brunch Club"], "places": [String](),
                                   "seconds": 400, "bursts": 1, "children": ["b3"], "start": "2026-09-16T15:30:00Z", "end": "2026-09-16T15:37:00Z"]
        let json: [String: Any] = ["target": "day", "level": "day", "period": "2026-09-16", "timezone": zone, "start": "2026-09-16T15:30:00Z", "end": "2026-09-16T21:39:00Z",
                                   "children": kids, "actionIDs": [String](), "inputRevision": "r", "threads": [main, side]]
        let dayRequest = try JSONDecoder().decode(LevelRequest.self, from: JSONSerialization.data(withJSONObject: json))
        try check(LevelGrounding.sideProblem("Drafted release notes and merged PR #911", dayRequest) != nil,
                  "a day headline naming the release notes (a side line) is refused")
        try check(LevelGrounding.sideProblem("Fixed sync dropping rows when the laptop sleeps and checked PR #911", dayRequest) == nil,
                  "a day headline naming the main thread holds")
        try check(LevelGrounding.sideProblem("Resumed interrupted uploads in PR #911", dayRequest) == nil,
                  "a day headline in the main thread's own words holds")
        let sideWhy = LevelGrounding.sideProblem("Resumed PR #911 uploads and drafted Harborline 2.0 release notes", dayRequest) ?? ""
        try check(sideWhy.contains("notes") && !sideWhy.contains("(not)") && !sideWhy.contains(" not,"), "the refusal names the headline's own side words, never a stem (\(sideWhy))")
        // The coding morning: code files and a terminal say what was open, not what for; their time is the issue's and the
        // pull request's that joined them, so "fixing sync drops rows" (issue #903) holds and the 6-minute release notes
        // ask does not.
        let morning: [[String: Any]] = [
            child("m1", "Issue #903: Sync drops rows when the laptop sleeps", ["Looked at Issue #903: Sync drops rows when the laptop sleeps mid-upload."], "2026-09-16T15:52:00Z", "2026-09-16T15:58:00Z"),
            child("m2", "uploader.rs in harborline", ["Worked on uploader.rs in harborline."], "2026-09-16T15:58:00Z", "2026-09-16T16:24:00Z"),
            child("m3", "Claude Code in harborline", ["Used Claude Code in harborline."], "2026-09-16T16:25:00Z", "2026-09-16T16:39:00Z"),
            child("m4", "uploader_tests.rs in harborline", ["Worked on uploader_tests.rs in harborline."], "2026-09-16T16:40:00Z", "2026-09-16T16:58:00Z"),
            child("m5", "PR #911 for resume uploads", ["Wrote the PR #911 description about resume uploads."], "2026-09-16T17:10:00Z", "2026-09-16T17:18:00Z"),
            child("m6", "Harborline 2.0 release notes", ["Asked ChatGPT to draft Harborline 2.0 release notes."], "2026-09-16T18:15:00Z", "2026-09-16T18:21:00Z"),
            child("m7", "CHANGELOG.md in harborline", ["Worked on CHANGELOG.md in harborline."], "2026-09-16T18:25:00Z", "2026-09-16T18:35:00Z")]
        let codeMain: [String: Any] = ["key": "pr:tallybird/harborline#903", "kind": "code", "label": "PR #911: Resume interrupted uploads from the last acked chunk", "people": [String](), "places": [String](),
                                       "seconds": 9000, "bursts": 1, "children": ["m1", "m2", "m3", "m4", "m5", "m6", "m7"], "start": "2026-09-16T15:52:00Z", "end": "2026-09-16T18:35:00Z"]
        let blockJSON: [String: Any] = ["target": "blk", "level": "block", "period": "2026-09-16", "timezone": zone, "start": "2026-09-16T15:52:00Z", "end": "2026-09-16T18:35:00Z",
                                        "children": morning, "actionIDs": [String](), "inputRevision": "r", "threads": [codeMain]]
        let blockRequest = try JSONDecoder().decode(LevelRequest.self, from: JSONSerialization.data(withJSONObject: blockJSON))
        try check(LevelGrounding.sideProblem("fixing sync drops rows when laptop sleeps", blockRequest) == nil,
                  "a coding stretch's goal naming the issue its code was for holds (the code's time is the issue's)")
        try check(LevelGrounding.sideProblem("drafting the Harborline 2.0 release notes", blockRequest) != nil,
                  "a coding stretch's goal naming a 6-minute ask is still refused")
        // Friday's morning: an ask about one of the stretch's files names what its code was for.
        let friday: [[String: Any]] = [
            child("f1", "SyncEngine.swift in tallybird-sync", ["Worked on SyncEngine.swift in tallybird-sync."], "2026-09-25T15:43:00Z", "2026-09-25T16:40:00Z"),
            child("f2", "Race condition in SyncEngine", ["Asked Claude Code to find the race in SyncEngine.merge."], "2026-09-25T16:08:00Z", "2026-09-25T16:18:00Z"),
            child("f3", "Swift tests in tallybird-sync", ["Ran the Swift tests (SyncEngineConflictTests) in tallybird-sync."], "2026-09-25T16:50:00Z", "2026-09-25T16:56:00Z"),
            child("f4", "SyncEngineConflictTests.swift in tallybird-sync", ["Worked on SyncEngineConflictTests.swift in tallybird-sync."], "2026-09-25T16:58:00Z", "2026-09-25T17:16:00Z")]
        var friMain = codeMain; friMain["label"] = "PR #530: Offline sync conflict resolution"; friMain["children"] = ["f1", "f2", "f3", "f4"]
        var friJSON = blockJSON; friJSON["children"] = friday; friJSON["threads"] = [friMain]
        let friRequest = try JSONDecoder().decode(LevelRequest.self, from: JSONSerialization.data(withJSONObject: friJSON))
        try check(LevelGrounding.sideProblem("fixing the race condition in SyncEngine", friRequest) == nil,
                  "a coding stretch's goal from an ask about its own file holds (\(LevelGrounding.sideProblem("fixing the race condition in SyncEngine", friRequest) ?? "held"))")
    }
    // A video never leads while a conversation shares the stretch.
    func thread(_ kind: String, _ seconds: Int) -> LevelThread {
        LevelThread(key: kind, kind: kind, label: kind, people: [], places: [], seconds: seconds, bursts: 1, children: [kind], start: "2026-09-24T16:00:00Z", end: "2026-09-24T17:00:00Z")
    }
    try check(LevelThreads.leadFirst([thread("video", 3000), thread("texts", 300)]).first?.kind == "texts", "a video never leads over texts in the same stretch")
    try check(LevelGrounding.check(title: code.title, lines: [LevelLine(text: "Texted Maya the numbers, ~10 min", children: code.lines[0].children)], request: request, extractive: false) == "threads",
              "core refuses bullets that aren't the code's")
    try check(LevelGrounding.instruction(for: request).contains("main thread") && !LevelGrounding.evidence(request).contains("Slack"),
              "the model reads only the main thread's notes")
    print("Thread checks use a synthetic store only. No model, capture or index.")
}
