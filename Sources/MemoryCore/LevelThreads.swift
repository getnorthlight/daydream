import Foundation
import PrivacyPolicy

// Threads (summaries/v3, Preview 4): smarter grouping for the memory levels. A person does many things at once: texts
// with two people while writing the investor update, a Slack ping, a YouTube break. Grouping by time alone chops that
// up or lets the longest-open window win ("Mostly Screen recording guide"). Here, by code only (the summarizer writes
// at most the one-line title):
//
// 1. Entities: every action is tagged with what it is about, from what DayDream already reads (app, site, window
//    title, and a typed row's recipient label, which is code-read from the window, never from the typed words):
//    a person (Messages, WhatsApp, Slack DMs, email recipients), a document or project (doc name, repo or folder, Figma
//    file, meeting), or a site and topic (domain and title).
// 2. Threads: moments are linked by shared entity keys, not by time adjacency, so four texting bursts with Maya across
//    two hours are one thread. Documents, meetings, AI chats, pull requests, email subjects and pages whose titles
//    share their words ("Investor update" in Claude and "Q3 investor update" in Google Docs) are one thread.
// 3. Focused time: each action counts until the next one (at most `dwellCap`); a thread's time is the sum over its
//    actions. Threads rank by it. The headline is the main thread only; the others are bullets with names and
//    minutes: "Texts with Maya and Sam, ~15 min".
// 4. Blocks: a stretch is cut at a gap of over 30 minutes, past 3 hours, or when another thread takes over (holds
//    `switchCut` of focus before the main thread is back for `shortSwitch`). A short switch never cuts a block: it
//    accrues to its own thread.
// Deterministic: the same actions always give the same blocks, threads, bullets and fallback titles, with summaries
// off too. Typed words are never read here.

/// One thread of a block or a day: what it is about, who, and how much focused time it had.
public struct LevelThread: Codable, Equatable, Sendable {
    /// Stable within a day: "doc:q3 investor update", "texts:maya", "slack:#eng", "email:q3 numbers", "site:youtube.com".
    public var key: String
    /// texts, chat (a Teams chat), slack, email, meeting, doc, code, pr, ai, video, search, web, app.
    public var kind: String
    /// The fallback title: "Q3 investor update", "Texts with Maya", "YouTube".
    public var label: String
    /// Names, in the order first seen (texts, Slack DMs, email recipients).
    public var people: [String]
    /// Slack channels ("#eng") and email subjects.
    public var places: [String]
    /// Focused seconds (see `ThreadPlanner.dwellCap`).
    public var seconds: Int
    /// How many separate stretches it came back in.
    public var bursts: Int
    /// The child notes it covers: moment ids for a block, block ids for a day.
    public var children: [String]
    public var start: String
    public var end: String
    /// The moments it covers, at any level (a block's: its children; a day's: its blocks' threads' moments).
    public var moments: [String]? = nil
    /// notes-quality: what was sent or asked in it, as its moment note says it ("Texted Q7 about Friday dinner"): the
    /// thread's bullet when there is one. nil: nothing sent, or a note written before threads5.
    public var intent: String? = nil
    public init(key: String, kind: String, label: String, people: [String], places: [String], seconds: Int, bursts: Int,
                children: [String], start: String, end: String, moments: [String]? = nil, intent: String? = nil) {
        self.key = key; self.kind = kind; self.label = label; self.people = people; self.places = places; self.seconds = seconds
        self.bursts = bursts; self.children = children; self.start = start; self.end = end; self.moments = moments; self.intent = intent
    }
    /// The moments it covers (older notes: its children).
    public var momentIDs: [String] { moments ?? children }
}

/// What one action is about.
public struct ThreadEntity: Equatable, Sendable {
    /// Unique per thing ("doc:q3 investor update", "page:developer.apple.com|writing large files").
    public var raw: String
    /// The thread key when nothing links it to a document, meeting, chat or project ("site:developer.apple.com").
    public var fallback: String
    public var kind: String
    public var label: String
    public var people: [String] = []
    public var places: [String] = []
    /// Content words its title links by (documents, meetings, AI chats, pull requests, email subjects, pages).
    public var topic: [String] = []
    /// A repo or project folder (code, pull requests): the same project links ("tallybird/tallybird" and Xcode's "Tallybird").
    public var project: String? = nil
    /// notes-quality: the title's salient names (a proper noun like "Lisbon" or "Lumo", a code name like "Q3"): two things
    /// that share one are one thread (texts, chats and email never link this way).
    public var nouns: [String] = []
    /// fix/sx-all round 3: a pull request's author as its title names it ("Add Windows ARM builds by tomasz-k · Pull
    /// Request #907"), lower case; nil when the title names none. Someone else's pull request (the author isn't one of the
    /// person's own account names) joins code by its issue key or topic words, never by the project alone.
    public var author: String? = nil
    /// Documents, meetings, pull requests, code and AI chats give a linked thread its key; the rest join it.
    public var anchor: Bool { ["doc", "meeting", "pr", "code", "ai"].contains(kind) }
    public init(raw: String, fallback: String? = nil, kind: String, label: String, people: [String] = [], places: [String] = [], topic: [String] = [],
                project: String? = nil, nouns: [String] = []) {
        self.raw = raw; self.fallback = fallback ?? raw; self.kind = kind; self.label = label; self.people = people; self.places = places; self.topic = topic
        self.project = project; self.nouns = nouns
    }
    /// notes-quality: what people do with others (texts, Slack, email, Teams chats, posts). Never linked by a shared name.
    public var comms: Bool { ["texts", "slack", "email", "chat", "social"].contains(kind) }
}

public enum ThreadEntities {
    static func host(_ site: String) -> String {
        var h = site.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }
    static let friendlyHosts: [String: String] = [
        "youtube.com": "YouTube", "m.youtube.com": "YouTube", "youtu.be": "YouTube", "netflix.com": "Netflix", "twitch.tv": "Twitch",
        "x.com": "X", "twitter.com": "X", "reddit.com": "Reddit", "news.ycombinator.com": "Hacker News", "linkedin.com": "LinkedIn",
        "github.com": "GitHub", "figma.com": "Figma", "notion.so": "Notion", "docs.google.com": "Google Docs"]
    static let socialHosts: Set<String> = ["x.com", "twitter.com", "mobile.twitter.com", "threads.net", "bsky.app", "mastodon.social"]
    static let videoHosts: Set<String> = ["youtube.com", "m.youtube.com", "youtu.be", "netflix.com", "twitch.tv", "vimeo.com"]
    static let searchHosts: Set<String> = ["google.com", "bing.com", "duckduckgo.com", "kagi.com", "search.brave.com"]
    /// Words that name an app, a site or nothing in particular: never a reason to link two titles.
    static let stopWords: Set<String> = Set("""
a an the of for and or to in on at by with from my our your re fwd fw notes note draft copy final new untitled tab home inbox \
google docs doc sheets slides drive gmail mail slack github youtube zoom meeting meet call claude chatgpt chat pull request \
issue v1 v2 v3 v4 edited document page is it this that how what why
""".split(whereSeparator: \.isWhitespace).map(String.init))
    static let utilityApps: Set<String> = ["calendar", "finder", "system settings", "system preferences", "music", "spotify", "photos",
                                          "activity monitor", "app store", "preview", "podcasts", "tv"]

    /// fix/sx-all: a note title that says only that the app was used ("Worked in ChatGPT", "Used Claude", "Had ChatGPT
    /// open and in use") names nothing: an AI ask's thread keeps its own name rather than take it.
    static let usedWords: Set<String> = ["worked", "working", "had", "used", "using", "opened", "chatted", "chatting", "was",
                                        "in", "on", "with", "to", "the", "a", "an", "open", "and", "use", "app", "window"]
    static func saysOnlyTheApp(_ title: String, _ e: ThreadEntity) -> Bool {
        let named = Set(tokens(e.fallback) + tokens(e.label))
        return tokens(title).allSatisfy { usedWords.contains($0) || named.contains($0) }
    }
    /// Lowercased word tokens of a title.
    static func tokens(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    /// The words a title links by: tokens without the stop words.
    public static func topicWords(_ s: String) -> [String] { tokens(s).filter { !stopWords.contains($0) } }
    /// Common words a title may capitalize ("Weekly Product Sync"): never a salient name on their own.
    static let commonWords: Set<String> = Set("""
about after again all also any back best big can day days did does doing done down each even every fix first from get good great guide help here \
how into its just last like long look make many more most much need next now off old one only other out over part plan planning plans please \
price pricing product project real review right same see show some start still such sync take team than thank thanks them then there these \
they thing things think three time today tomorrow top travel trip two update updates use using very want was way week weekly well were what \
when where which while who why will work working would year yes yet you your mode chart numbers number summary summaries weekly friday monday \
tuesday wednesday thursday saturday sunday morning evening night dinner lunch breakfast cabin cabins near file files crash crashes bug bugs
""".split(whereSeparator: \.isWhitespace).map(String.init))
    /// notes-quality: a title's salient names: words written with a capital inside the title (not its first word) or with
    /// a digit ("Q3"), four letters or more unless they hold a digit, and not a common word, an app or a site.
    public static func salientNouns(_ title: String) -> [String] {
        let raw = title.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        var out = [String]()
        for (i, w) in raw.enumerated() {
            let lower = w.lowercased()
            let digit = w.rangeOfCharacter(from: .decimalDigits) != nil, letter = w.rangeOfCharacter(from: .letters) != nil
            let named = (i > 0 && w.first?.isUppercase == true) || w.dropFirst().contains(where: \.isUppercase)
            guard (digit && letter && w.count >= 2) || (named && w.count >= 4), !stopWords.contains(lower), !commonWords.contains(lower),
                  !out.contains(lower) else { continue }
            out.append(lower)
        }
        return out
    }
    static func norm(_ s: String) -> String { tokens(s).joined(separator: " ") }

    /// A person's name as a window shows it ("Maya", "Sam Lee"), or nil for anything else (a phone number, an address,
    /// the app's own name, "2 more").
    public static func personName(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...32).contains(s.count), !s.contains("@"), !s.contains("#"), s.rangeOfCharacter(from: .decimalDigits) == nil else { return nil }
        let words = s.split(separator: " ")
        guard (1...3).contains(words.count), words.allSatisfy({ $0.first?.isLetter == true && $0.first?.isUppercase == true }) else { return nil }
        let generic: Set<String> = ["messages", "new message", "whatsapp", "signal", "telegram", "chats", "inbox", "slack", "threads",
                                    "direct messages", "activity", "home", "search", "later", "mentions", "drafts"]
        return generic.contains(s.lowercased()) ? nil : s
    }
    /// notes-quality: a conversation's own name when it is not a person's ("Q7", "Book club"): up to 32 characters, not
    /// a phone number, an address or the app's own window.
    public static func conversationName(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...32).contains(s.count), !s.contains("@"), s.filter(\.isNumber).count < 5, s.first?.isLetter == true,
              s.split(separator: " ").count <= 4 else { return nil }
        let generic: Set<String> = ["messages", "new message", "whatsapp", "signal", "telegram", "chats", "inbox", "threads", "home", "search",
                                    "messenger", "imessage", "compose", "new chat", "new group"]
        return generic.contains(s.lowercased()) ? nil : s
    }
    /// The people a conversation title names: "Maya", "Maya, Sam & 2 more", "Maya and Sam".
    static func people(_ title: String) -> [String] {
        let parts = title.replacingOccurrences(of: " & ", with: ", ").replacingOccurrences(of: " and ", with: ", ").components(separatedBy: ",")
        var out = [String]()
        for p in parts { if let n = personName(p), !out.contains(n) { out.append(n) } }
        return out
    }
    static func strip(_ s: String, suffixes: [String]) -> String {
        for suffix in suffixes where s.hasSuffix(suffix) { return String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces) }
        return s
    }
    static func segments(_ s: String) -> [String] {
        var parts = [s]
        for sep in [" — ", " – ", " - ", " | ", " · "] { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
    /// fix/sx-all round 1: a project as it is known ("daydream" is DayDream, "ios-app" keeps iOS), else as written with
    /// its first letter raised ("tallybird-sync" -> "Tallybird-sync"), never a name that already has capitals changed.
    static let knownCasing: [String: String] = ["daydream": "DayDream", "macos": "macOS", "ios": "iOS", "ipados": "iPadOS", "watchos": "watchOS"]
    static func projectName(_ project: String) -> String {
        if let known = knownCasing[project.lowercased()] { return known }
        if project.contains(where: \.isUppercase) { return project }
        return capitalized(project)
    }

    static func isTexts(_ b: String, _ a: String, _ h: String) -> Bool {
        ["com.apple.mobilesms", "net.whatsapp.whatsapp", "desktop.whatsapp", "org.whispersystems.signal-desktop", "ru.keepcoder.telegram",
         "com.facebook.archon", "com.facebook.messenger"].contains(b)
            || ["messages", "whatsapp", "signal", "telegram", "messenger"].contains(a) || h == "web.whatsapp.com" || h == "messenger.com"
    }
    static func isSlack(_ b: String, _ a: String, _ h: String) -> Bool { b == "com.tinyspeck.slackmacgap" || a == "slack" || h == "slack.com" || h.hasSuffix(".slack.com") }
    static func isEmail(_ b: String, _ a: String, _ h: String) -> Bool {
        b == "com.apple.mail" || a == "mail" || b.contains("outlook") || b.contains("superhuman") || b == "com.readdle.smartemail-mac"
            || h == "mail.google.com" || h.hasPrefix("outlook.") || h == "app.superhuman.com" || h == "mail.proton.me"
    }
    static func isMeeting(_ b: String, _ a: String, _ h: String) -> Bool {
        b == "us.zoom.xos" || a == "zoom" || a == "zoom.us" || b.hasPrefix("com.microsoft.teams") || a == "facetime" || b == "com.apple.facetime"
            || h == "meet.google.com" || h.hasSuffix("zoom.us") || h == "teams.microsoft.com" || b.contains("webex")
    }
    static func isTeams(_ b: String, _ h: String) -> Bool { b.hasPrefix("com.microsoft.teams") || h == "teams.microsoft.com" || h == "teams.live.com" }
    static func isZoom(_ b: String, _ a: String, _ h: String) -> Bool { b == "us.zoom.xos" || a == "zoom" || a == "zoom.us" || a == "zoom workplace" }
    /// Zoom's own windows when no call is on.
    static let zoomHomeTitles: Set<String> = ["zoom", "zoom workplace", "zoom - free account", "zoom - pro account", "zoom - licensed account",
                                              "zoom - basic account", "zoom cloud meetings", "zoom.us", "home - zoom", "zoom - home"]
    /// Microsoft Teams titles its windows "<view> | <name> | Microsoft Teams": "Chat | Maya Chen | Microsoft Teams" is a
    /// chat with Maya, "Calendar | Calendar | Microsoft Teams" and "Activity | Microsoft Teams" are the app, and only a
    /// meeting or call window ("Meeting | Weekly sync | Microsoft Teams", "Call with Maya Chen") is a meeting. Anything else
    /// is the app too: never the raw title (r1 summaries-quality).
    static func teamsEntity(_ title: String) -> ThreadEntity {
        let app = ThreadEntity(raw: "app:teams", kind: "app", label: "Microsoft Teams")
        let parts = title.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("microsoft teams") }
        guard let view = parts.first?.lowercased() else { return app }
        let rest = parts.dropFirst().first
        if view == "chat" || view == "chats" {
            let who = rest.map(people) ?? []
            guard !who.isEmpty else { return app }
            return ThreadEntity(raw: "chat:teams|" + who[0].lowercased(), kind: "chat", label: "Teams chat with " + LevelThreads.names(who), people: who)
        }
        let meetingViews = ["meeting", "meeting compact view", "meeting in progress", "call", "calling"]
        if meetingViews.contains(view) || view.hasPrefix("meeting with ") || view.hasPrefix("call with ") || view.hasPrefix("meeting in ") {
            var name = meetingViews.contains(view) ? rest : parts.first
            if let n = name, meetingViews.contains(n.lowercased()) { name = nil }
            for p in ["Meeting with ", "Call with "] where name?.hasPrefix(p) == true {
                // "Call with Maya Chen": the person, not a meeting name.
                let who = people(String(name!.dropFirst(p.count)))
                return ThreadEntity(raw: "meeting:" + norm(name!), kind: "meeting", label: name!, people: who, topic: [])
            }
            guard let name, !name.isEmpty else { return ThreadEntity(raw: "meeting:", kind: "meeting", label: "Meeting") }
            return ThreadEntity(raw: "meeting:" + norm(name), kind: "meeting", label: name, topic: topicWords(name))
        }
        return app
    }
    static func isAI(_ b: String, _ a: String, _ h: String) -> Bool {
        ["com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex"].contains(b) || ["claude", "chatgpt"].contains(a)
            || ["claude.ai", "chatgpt.com", "chat.openai.com", "gemini.google.com", "perplexity.ai"].contains(h)
    }
    static func isCode(_ b: String, _ a: String) -> Bool {
        ["com.apple.dt.xcode", "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "dev.zed.zed", "com.apple.terminal", "com.googlecode.iterm2",
         "com.jetbrains.intellij", "com.sublimetext.4", "com.mitchellh.ghostty", "dev.warp.warp-stable"].contains(b)
            || ["xcode", "visual studio code", "code", "cursor", "zed", "terminal", "iterm2", "ghostty", "warp"].contains(a)
    }

    /// A window title as a name: no unread counts ("Inbox (12)", "(3) WhatsApp"), no email addresses, no "12 messages".
    public static func clean(_ raw: String) -> String {
        var s = raw
        for pattern in ["^\\(\\d+\\+?\\)\\s*", "\\s*\\(\\d+\\+?( unread| new)?( messages?)?\\)", "\\s*[-–—|·]\\s*[^\\s]+@[^\\s]+", "[^\\s]+@[^\\s]+\\s*[-–—|·]?\\s*"] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—|·")))
    }
    /// What an action is about. `to`: a typed row's recipient label (code-read from the window; never typed words).
    public static func entity(app: String, bundle: String, site: String, title rawTitle: String, to: String? = nil) -> ThreadEntity {
        var e = rawEntity(app: app, bundle: bundle, site: site, title: rawTitle, to: to)
        let label = clean(e.label)
        e.label = label.isEmpty ? (app.isEmpty ? "Other apps" : app) : label
        e.places = e.places.map(clean).filter { !$0.isEmpty }
        return e
    }
    static func rawEntity(app: String, bundle: String, site: String, title rawTitle: String, to rawTo: String?) -> ThreadEntity {
        let h = host(site), b = bundle.lowercased(), a = app.lowercased()
        // claude/catchup-1003: Messages names a contact Siri only suggests "Maybe: Sam"; Sam is the name, never "Maybe:".
        let siri = b == "com.apple.mobilesms" || a == "messages"
        let to = siri ? rawTo.map(SendRules.siriSuggestion) : rawTo
        let title = clean(siri ? SendRules.siriSuggestion(rawTitle) : rawTitle.trimmingCharacters(in: .whitespacesAndNewlines))
        let lower = title.lowercased()
        let bare = title.isEmpty || lower == a || lower == h || lower == site.lowercased() || lower == "google chrome" || lower == "safari"
        let recipient = to.flatMap(personName)
        let appName = app.isEmpty ? (friendlyHosts[h] ?? h) : app

        if isTexts(b, a, h) {
            // notes-quality: a group chat's own name counts too ("Q7", "Family"): "Texts with Q7".
            let messages = b == "com.apple.mobilesms" || a == "messages"
            // Messages recipient authority wins over a stale window title.
            // New Message is a placeholder, never a person or group name.
            let messageTitle = messages && ["new message", "imessage", "untitled"].contains(lower)
            var who = messages && to != nil ? [] : bare || messageTitle ? [] : people(title)
            if who.isEmpty, !bare, !messageTitle, !(messages && to != nil), let group = conversationName(title) { who = [group] }
            if who.isEmpty, let recipient { who = [recipient] }
            if who.isEmpty, let to, let group = conversationName(to) { who = [group] }
            // fix/sx-all round 1: WhatsApp, Signal, Telegram and Messenger are named by their app ("WhatsApp with Mom"),
            // never the generic "Texts" that means Messages.
            if !messages {
                let appLabel = b.contains("whatsapp") || a == "whatsapp" || h == "web.whatsapp.com" ? "WhatsApp" : b.contains("signal") || a == "signal" ? "Signal"
                    : b.contains("telegram") || a == "telegram" ? "Telegram" : b.contains("facebook") || a == "messenger" || h == "messenger.com" ? "Messenger" : (app.isEmpty ? "Chat" : app)
                return ThreadEntity(raw: "chat:" + appLabel.lowercased() + "|" + (who.first?.lowercased() ?? ""), kind: "chat",
                                    label: who.isEmpty ? appLabel : appLabel + " with " + who[0], people: who)
            }
            let key = "texts:" + (who.first?.lowercased() ?? "")
            return ThreadEntity(raw: key, kind: "texts", label: who.isEmpty ? "Texts" : "Texts with " + who[0], people: who)
        }
        if isSlack(b, a, h) {
            var t = strip(title, suffixes: [" - Slack", " | Slack"])
            let named = t != title
            if t.hasPrefix("Slack | ") { t = t.components(separatedBy: " | ").dropFirst().first ?? "" }
            let parts = bare ? [] : t.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
            var person: [String] = [], place: [String] = []
            if let first = parts.first, !first.isEmpty {
                if first.hasSuffix(" (Channel)") || first.hasPrefix("#") {
                    let name = first.replacingOccurrences(of: " (Channel)", with: "").trimmingCharacters(in: .whitespaces)
                    place = [name.hasPrefix("#") ? name : "#" + name]
                } else if first.hasSuffix("(DM)") || first.hasSuffix("(Group DM)") || (named && parts.count >= 2) {
                    person = people(first.replacingOccurrences(of: " (Group DM)", with: "").replacingOccurrences(of: " (DM)", with: ""))
                }
            }
            if person.isEmpty, place.isEmpty, let recipient { person = [recipient] }
            // fix/sx-all round 3: a web typing row is titled with its host ("app.slack.com"); its composer's place ("#infra",
            // code-read from the field's label) is the channel, so the post joins that channel's thread.
            if person.isEmpty, place.isEmpty, let to = to?.trimmingCharacters(in: .whitespaces), to.hasPrefix("#"), to.count > 1, to.count <= 80 { place = [to] }
            let key = "slack:" + (place.first ?? person.first ?? "").lowercased()
            let label = !place.isEmpty ? "Slack in " + place[0] : !person.isEmpty ? "Slack with " + person[0] : "Slack"
            return ThreadEntity(raw: key, kind: "slack", label: label, people: person, places: place)
        }
        if isEmail(b, a, h) {
            var subject: String? = nil
            if !bare {
                let t = strip(title, suffixes: [" - Gmail", " — Gmail", " - Outlook", " - Mail"])
                let parts = t.components(separatedBy: " - ").filter { !$0.contains("@") }
                var s = (parts.first ?? "").trimmingCharacters(in: .whitespaces)
                var changed = true
                while changed {
                    changed = false
                    for p in ["Re: ", "RE: ", "Fwd: ", "FW: ", "Fw: ", "Re:", "Fwd:"] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces); changed = true }
                }
                let l = s.lowercased()
                // fix/sx-all: "email" too: TitleClean (fix/day-card) names a mailbox view "Email", as the cloud view shows it.
                let boxes = ["inbox", "sent", "drafts", "all mail", "starred", "archive", "outbox", "junk", "spam", "trash", "mail", "email", "new message"]
                if !s.isEmpty, !boxes.contains(where: { l == $0 || l.hasPrefix($0 + " (") || l.hasPrefix($0 + " –") || l.hasPrefix($0 + " -") }) { subject = s }
            }
            let who = recipient.map { [$0] } ?? []
            // fix/sx-all round 2: an email to someone is its own thread by who it went to ("email:to:riley"): two emails to
            // different people never share a thread, a label or people. Without a recipient, email stays one thread (triage
            // is one thing) unless a subject links it to a document, meeting or chat.
            let key = recipient.map { "email:to:" + norm($0) } ?? subject.map { "email:" + norm($0) } ?? "email"
            let label = subject.map { "Email about " + $0 } ?? recipient.map { "Email to " + $0 } ?? "Email"
            return ThreadEntity(raw: key, fallback: recipient == nil ? "email" : key, kind: "email", label: label,
                                people: who, places: subject.map { [$0] } ?? [], topic: subject.map(topicWords) ?? [])
        }
        if isTeams(b, h) { return teamsEntity(title) }
        // fix/sx-all round 3: a Discord channel ("#help | Tallybird Community - Discord") is a chat in that channel, said to
        // others like Slack; never a document that links to code by the server's name.
        if b == "com.hnc.discord" || a == "discord" || h == "discord.com" {
            let parts = strip(title, suffixes: [" - Discord"]).components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
            let channel = parts.first.flatMap { $0.hasPrefix("#") || $0.hasPrefix("@") ? $0 : nil }
            let server = parts.count >= 2 ? parts[1] : nil
            return ThreadEntity(raw: "chat:discord|" + [channel, server].compactMap { $0?.lowercased() }.joined(separator: "|"), kind: "chat",
                                label: channel.map { "Discord in " + $0 } ?? "Discord", places: channel.map { [$0] } ?? [])
        }
        if socialHosts.contains(h) {
            // notes-quality: a post is said to others, like a text: "Posted on X".
            let site = friendlyHosts[h] ?? h
            return ThreadEntity(raw: "social:" + site.lowercased(), kind: "social", label: site, places: [site])
        }
        if isZoom(b, a, h), bare || zoomHomeTitles.contains(lower) {
            // Zoom open with no call (its home window) is the app, not a meeting.
            return ThreadEntity(raw: "app:zoom", kind: "app", label: "Zoom")
        }
        if isMeeting(b, a, h) {
            var t = strip(title, suffixes: [" - Zoom", " - Google Meet"])
            for p in ["Meet – ", "Meet - "] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
            let generic = t.isEmpty || bare || ["zoom meeting", "zoom", "meet", "google meet", "facetime", "microsoft teams"].contains(t.lowercased())
                || t.range(of: "^[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: .regularExpression) != nil
            if generic { return ThreadEntity(raw: "meeting:", kind: "meeting", label: isZoom(b, a, h) ? "Zoom call" : h == "meet.google.com" ? "Google Meet call" : a == "facetime" || b == "com.apple.facetime" ? "FaceTime call" : "Meeting") }
            return ThreadEntity(raw: "meeting:" + norm(t), kind: "meeting", label: t, topic: topicWords(t), nouns: salientNouns(t))
        }
        if h == "github.com" {
            // "Add weekly export by sam · Pull Request #418 · tallybird/tallybird"
            let parts = title.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 3, let kindPart = parts.first(where: { $0.hasPrefix("Pull Request #") || $0.hasPrefix("Issue #") }) {
                let repo = parts.last ?? ""
                let number = kindPart.components(separatedBy: "#").last ?? ""
                var name = parts[0], author: String? = nil
                if let by = name.range(of: " by ", options: .backwards) {
                    let who = name[by.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !who.isEmpty, !who.contains(" ") { author = who.lowercased() }
                    name = String(name[..<by.lowerBound])
                }
                let pr = kindPart.hasPrefix("Pull")
                var e = ThreadEntity(raw: "pr:" + repo.lowercased() + "#" + number, kind: "pr",
                                     label: (pr ? "PR #" : "Issue #") + number + ": " + name, topic: topicWords(name),
                                     project: repo.split(separator: "/").last.map { $0.lowercased() }, nouns: salientNouns(name))
                e.author = pr ? author : nil
                return e
            }
            let repo = parts.last(where: { $0.contains("/") && !$0.contains(" ") })
            return ThreadEntity(raw: "site:github.com" + (repo.map { "|" + $0.lowercased() } ?? ""), fallback: "site:github.com", kind: "web",
                                label: repo.map { "GitHub: " + $0 } ?? "GitHub")
        }
        if isAI(b, a, h) {
            let t = bare || ["new chat", "claude", "chatgpt", "new conversation"].contains(lower) ? "" : strip(title, suffixes: [" - Claude", " | Claude", " - ChatGPT"])
            let web = a == "google chrome" || a == "safari" || a == "chrome" || a == "arc" || a == "firefox"
            let name = b == "com.openai.codex" || b == "com.openai.chat" ? "ChatGPT" : b == "com.anthropic.claudefordesktop" ? "Claude"
                : web || app.isEmpty ? (h.contains("claude") ? "Claude" : h.contains("gemini") ? "Gemini" : h.contains("perplexity") ? "Perplexity" : "ChatGPT") : app
            // notes-quality: one thread per AI app ("ai:claude"), unless an ask shares a name with a document or project
            // (the planner links it by its moment note's title). Never a chat title as the label: it is often the question.
            let key = "ai:" + name.lowercased()
            return ThreadEntity(raw: key + (t.isEmpty ? "" : "|" + norm(t)), fallback: key, kind: "ai", label: name, topic: topicWords(t), nouns: salientNouns(t))
        }
        if isCode(b, a) {
            let parts = segments(strip(title, suffixes: [" — Visual Studio Code", " - Visual Studio Code", " — Cursor", " - Cursor"]))
            var project: String? = nil
            // Xcode: "ExportView.swift — Tallybird", "Tallybird — Debug navigator": the first part that isn't a file.
            if b == "com.apple.dt.xcode" || a == "xcode" { project = parts.count >= 2 ? parts.first(where: { !$0.contains(".") }) : nil }
            else if ["com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.warp-stable"].contains(b) || ["terminal", "iterm2", "ghostty", "warp"].contains(a) {
                if let first = parts.first {
                    let path = first.hasPrefix("~") || first.hasPrefix("/") ? (first.split(separator: "/").last.map(String.init) ?? first) : first
                    let l = path.lowercased()
                    if !(l.contains("zsh") || l.contains("bash") || l.contains("@") || l.contains("×") || l == "~" || l == "fish") { project = path }
                }
            } else { project = parts.count >= 2 ? parts.last : parts.first }
            guard let project, !project.isEmpty else { return ThreadEntity(raw: "app:" + a, kind: "app", label: appName) }
            return ThreadEntity(raw: "code:" + project.lowercased(), kind: "code", label: projectName(project) + " code", project: project.lowercased())
        }
        if !h.isEmpty {
            if videoHosts.contains(h) {
                // notes-quality: a video's own title links it ("Lisbon in 3 days" joins the Lisbon trip).
                let t = bare ? "" : strip(title, suffixes: [" - YouTube", " | Netflix", " - Twitch", " on Vimeo"])
                let home = ["youtube", "home", "netflix", "twitch", "subscriptions"].contains(t.lowercased())
                guard !t.isEmpty, !home else { return ThreadEntity(raw: "site:" + h, kind: "video", label: friendlyHosts[h] ?? h) }
                return ThreadEntity(raw: "video:" + h + "|" + norm(t), fallback: "site:" + h, kind: "video", label: friendlyHosts[h] ?? h,
                                    topic: topicWords(t), nouns: salientNouns(t))
            }
            if searchHosts.contains(h) && (bare || lower == "google" || lower.hasSuffix(" - google search") || lower.hasSuffix(" - bing") || lower.contains("duckduckgo")) {
                return ThreadEntity(raw: "search", kind: "search", label: "Web searches")
            }
            if h == "docs.google.com" || h == "notion.so" || h.hasSuffix(".notion.site") || h == "figma.com" || h == "coda.io" || h == "dropbox.com" && lower.contains("paper") {
                let t = strip(title, suffixes: [" - Google Docs", " - Google Sheets", " - Google Slides", " - Google Drive", " - Google Forms", " | Notion", " - Notion", " – Figma", " - Figma", " - Coda"])
                if !bare, !t.isEmpty { return ThreadEntity(raw: "doc:" + norm(t), kind: "doc", label: t, topic: topicWords(t), nouns: salientNouns(t)) }
            }
            let segs = bare ? [] : segments(title)
            let page = segs.first(where: { $0.split(separator: " ").count >= 2 }) ?? segs.first
            let site = friendlyHosts[h] ?? h
            guard let page, !page.isEmpty else { return ThreadEntity(raw: "site:" + h, kind: "web", label: site) }
            return ThreadEntity(raw: "page:" + h + "|" + norm(page), fallback: "site:" + h, kind: "web", label: page, topic: topicWords(page), nouns: salientNouns(page))
        }
        if bare || utilityApps.contains(a) { return ThreadEntity(raw: "app:" + (b.isEmpty ? a : b), kind: "app", label: appName.isEmpty ? "Other apps" : appName) }
        // A document in a desktop app (Notes, Figma, Pages, Word, Preview...): its name.
        var t = strip(title, suffixes: [" — Edited", " - Edited", " – Figma", " - Figma"])
        if a == "figma" || b == "com.figma.desktop" { t = segments(t).first ?? t }
        for ext in [".docx", ".doc", ".pages", ".key", ".numbers", ".xlsx", ".pptx", ".pdf", ".md", ".txt", ".rtf"] where t.lowercased().hasSuffix(ext) { t = String(t.dropLast(ext.count)) }
        return ThreadEntity(raw: "doc:" + norm(t), kind: "doc", label: t, topic: topicWords(t), nouns: salientNouns(t))
    }

    /// fix/sx-all round 2: a pull request, an issue and an AI ask join the code they are about: the same issue key
    /// ("LOOM-88" in a PR title, a Linear page and an ask's note), a code project's name in the other's title ("loomwork"),
    /// or two or more topic words in common between a PR or issue and an ask. The day then has one thread for the work
    /// ("Fixed double webhook retries (LOOM-88)"), not four.
    static let issueKey = try! NSRegularExpression(pattern: #"\b[A-Z][A-Z0-9]{1,9}-\d{1,6}\b"#)
    public static func issueKeys(_ e: ThreadEntity) -> Set<String> {
        let text = e.label
        return Set(issueKey.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } })
    }
    static func work(_ e: ThreadEntity) -> Bool {
        e.kind == "pr" || e.kind == "ai" || e.kind == "code" || ((e.kind == "web" || e.kind == "doc") && !issueKeys(e).isEmpty)
    }
    static func workLinked(_ x: ThreadEntity, _ y: ThreadEntity, projects: Set<String>, people: Set<String>, byProject: Bool = true) -> Bool {
        guard work(x), work(y), !(x.kind == "ai" && y.kind == "ai") else { return false }
        if !issueKeys(x).isDisjoint(with: issueKeys(y)) { return true }
        // fix/sx-all round 3: only a pull request or an issue joins code by the project's name in its title. An AI ask that
        // names the project ("Harborline 2.0 release notes") is about something else; it joins by an issue key or by two
        // topic words shared with a PR or issue (below), never by the project word.
        func mentions(_ a: ThreadEntity, _ project: String?) -> Bool {
            guard let project, !project.isEmpty, a.kind == "pr" || (a.kind != "code" && a.kind != "ai" && !issueKeys(a).isEmpty) else { return false }
            return Set(tokens(a.label) + a.topic + a.nouns).contains(project)
        }
        if byProject, mentions(x, y.project) || mentions(y, x.project) { return true }
        guard x.kind != "code", y.kind != "code" else { return false }
        let shared = Set(x.topic).intersection(y.topic).subtracting(people).subtracting(projects).filter { $0.count >= 3 && Int($0) == nil }
        return shared.count >= 2
    }
    /// Two titles are one thread when they share a run of at least two words in the same order that covers at least
    /// two thirds of the shorter title's words ("Investor update" and "Q3 investor update"; "Weekly sync notes" and
    /// "Weekly sync"). One shared word never links.
    public static func linked(_ a: [String], _ b: [String]) -> Bool {
        guard a.count >= 2, b.count >= 2 else { return false }
        var best = 0
        for i in 0..<a.count {
            for j in 0..<b.count {
                var k = 0
                while i + k < a.count, j + k < b.count, a[i + k] == b[j + k] { k += 1 }
                best = max(best, k)
            }
        }
        return best >= 2 && best * 3 >= 2 * min(a.count, b.count)
    }
}

/// notes-quality: a moment's note as the planner reads it: its title, and its sent or asked line ("Texted Q7 about
/// Friday dinner."), which is its thread's bullet.
public struct MomentGist: Sendable, Equatable {
    public var title: String
    public var intent: String?
    public init(title: String, intent: String?) { self.title = title; self.intent = intent }
    /// Leads of a line that says something was sent, asked, posted or reviewed (validator10's did-verbs), or a draft to
    /// someone. "Worked on", "Watched" and "On a call" lines are a thread's name and time already.
    static let sent = ["Texted", "Emailed", "Replied", "Messaged", "Told", "Posted", "Asked", "Reviewed", "Approved", "Submitted"]
    static let drafted = ["Drafted a text", "Drafted an email", "Drafted a reply", "Drafted a message", "Wrote a post"]
    public static func intent(_ bullets: [String]) -> String? {
        let lines = bullets.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return lines.first { l in sent.contains { l.hasPrefix($0 + " ") } } ?? lines.first { l in drafted.contains { l.hasPrefix($0) } }
    }
}

/// One action as the planner sees it.
public struct ThreadAction: Sendable {
    public var id: String
    public var moment: String
    public var at: Date
    public var idle: Bool
    public var entity: ThreadEntity
    public init(id: String, moment: String, at: Date, idle: Bool, entity: ThreadEntity) {
        self.id = id; self.moment = moment; self.at = at; self.idle = idle; self.entity = entity
    }
}

/// A day's actions cut into blocks and threads (see the file comment).
public struct ThreadPlan: Sendable {
    /// Moment ids per block, in time order (each moment in exactly one block).
    public var blocks: [[String]]
    /// Each moment's thread key.
    public var momentKey: [String: String]
    let actions: [ThreadAction]
    let dwell: [String: Double]
    let momentEntity: [String: ThreadEntity]
    /// notes-quality: each moment's note as the planner read it (title, and its sent or asked line).
    var gists: [String: MomentGist] = [:]
    /// The person's own account names (`ThreadPlanner.plan`).
    var selfNames: Set<String> = []

    /// The threads of these moments, most focused first (ties: the earlier one).
    public func threads(for moments: Set<String>) -> [LevelThread] {
        struct Acc { var seconds = 0.0; var bursts = 0; var children = [String](); var people = [String](); var places = [String]()
            var start: Date; var end: Date; var byRaw = [String: Double](); var entities = [String: ThreadEntity](); var byMoment = [String: Double]() }
        var acc = [String: Acc](), order = [String](), last: String? = nil
        for a in actions where moments.contains(a.moment) && !a.idle {
            guard let key = momentKey[a.moment], let entity = momentEntity[a.moment] else { continue }
            let d = dwell[a.id] ?? 0
            if acc[key] == nil { acc[key] = Acc(start: a.at, end: a.at); order.append(key) }
            acc[key]!.seconds += d
            acc[key]!.end = max(acc[key]!.end, a.at)
            if last != key { acc[key]!.bursts += 1 }
            last = key
            if !acc[key]!.children.contains(a.moment) { acc[key]!.children.append(a.moment) }
            acc[key]!.byRaw[entity.raw, default: 0] += d
            acc[key]!.byMoment[a.moment, default: 0] += d + 0.001
            acc[key]!.entities[entity.raw] = entity
            for p in entity.people where !acc[key]!.people.contains(p) { acc[key]!.people.append(p) }
            for p in entity.places where !acc[key]!.places.contains(p) { acc[key]!.places.append(p) }
        }
        let out = order.compactMap { key -> LevelThread? in
            guard let x = acc[key] else { return nil }
            // The label and kind of the member with the most focus (a page group with several pages: the site); a thread linked
            // by a shared name takes its most telling member's (a document before a meeting, a pull request, code, a page, an
            // AI ask, a video).
            let ranked = x.byRaw.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.compactMap { x.entities[$0.key] }
            guard var top = ranked.first else { return nil }
            // (Only when the member with the most focus names little: a video, an AI app, a site or an app.)
            if x.entities.count > 1, ["video", "ai", "app", "search"].contains(top.kind) || (top.kind == "web" && top.raw.hasPrefix("site:")) {
                let order = ["doc", "meeting", "pr", "code", "web", "ai", "video"]
                if let best = ranked.filter({ order.contains($0.kind) && !($0.kind == "web" && $0.raw.hasPrefix("site:")) })
                    .min(by: { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }) { top = best }
            }
            // fix/sx-all round 3: a thread keyed by an AI chat (linked to nothing more telling than a page) is that chat's,
            // named by its own title ("Debugging CI test failures"), never by the page read beside it.
            if let own = x.entities[key], own.kind == "ai", top.kind == "web" || top.kind == "video" { top = own }
            // fix/sx-all round 3: code joined by a pull request or an issue is named by it ("PR #911: Resume interrupted
            // uploads"), the pull request with the most focus first, never "<Repo> code".
            // The person's own pull request first, then the one the thread is keyed by, then the one with the most focus.
            // The whole day's thread counts, not only these moments: a block of code alone is named by the PR its thread
            // joined later ("PR #530: ...", never "Tallybird-sync code" for the morning and the PR's name after).
            var prs = ranked.filter { $0.kind == "pr" }
            for (m, e) in momentEntity.sorted(by: { $0.key < $1.key }) where e.kind == "pr" && momentKey[m] == key && !prs.contains(where: { $0.raw == e.raw }) { prs.append(e) }
            let mine = prs.first { p in p.author.map { selfNames.contains($0) } == true && p.label.hasPrefix("PR #") }
            let keyed = prs.first { $0.raw == key }
            if top.kind == "code", let pr = mine ?? keyed ?? prs.first(where: { $0.label.hasPrefix("PR #") && $0.author.map { !selfNames.contains($0) } != true }) ?? prs.first {
                top = ThreadEntity(raw: top.raw, fallback: top.fallback, kind: "code", label: pr.label, people: top.people, places: top.places,
                                   topic: pr.topic, project: top.project, nouns: pr.nouns)
            }
            var label = top.label
            if key.hasPrefix("site:"), x.entities.count > 1 { let h = String(key.dropFirst(5)); label = ThreadEntities.friendlyHosts[h] ?? h }
            if key == "email" || top.kind == "texts" { label = LevelThreads.channelLabel(top.kind, people: x.people, places: x.places) }
            // What was sent or asked in it: the line of its moment with the most focus that has one.
            let intent = x.byMoment.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.lazy.compactMap { self.gists[$0.key]?.intent }.first
            return LevelThread(key: key, kind: top.kind, label: label, people: x.people, places: x.places, seconds: Int(x.seconds.rounded()),
                               bursts: x.bursts, children: x.children, start: iso(x.start), end: iso(x.end), moments: x.children, intent: intent)
        }.sorted { ($0.seconds, $1.start) > ($1.seconds, $0.start) }
        return LevelThreads.leadFirst(out)
    }
}

public enum ThreadPlanner {
    /// An action counts until the next one, at most this long (window samples come about every 2 minutes).
    public static let dwellCap: TimeInterval = 5 * 60
    /// The last action before a gap or the end counts this long.
    public static let lastDwell: TimeInterval = 30
    /// A gap this long ends a stretch.
    public static let sessionGap: TimeInterval = 30 * 60
    /// A switch this short never cuts a block, and the main thread must be back this long to end an excursion.
    public static let shortSwitch: TimeInterval = 2 * 60
    /// A block has a main thread once it holds this much focus.
    public static let establish: TimeInterval = 10 * 60
    /// Another thread takes over (a new block) when the excursion away from the main thread holds this much focus...
    public static let switchCut: TimeInterval = 20 * 60
    /// ...and its own main thread at least this much.
    public static let switchTop: TimeInterval = 10 * 60
    /// A block keeps an interruption the main thread comes back from, unless it holds this much focus, and its own
    /// main thread at least `interruptionTop` (a long meeting in the middle of writing is its own block).
    public static let interruptionCut: TimeInterval = 30 * 60
    public static let interruptionTop: TimeInterval = 20 * 60
    /// A block never spans more than this.
    public static let maxSpan: TimeInterval = 3 * 3600

    public static func plan(_ input: [ThreadAction]) -> ThreadPlan { plan(input, gists: [:]) }
    /// notes-quality: `gists` are the moments' notes (title, and the sent or asked line): an AI ask is linked by its
    /// note's title (the chat's own title is often the question typed into it), and a thread's bullet is its sent line.
    /// fix/sx-all round 3: `selfNames` are the person's own account names (`MemoryStore.accountHandles`): a pull request by
    /// someone else joins the person's code only through an issue key or its topic words, and a code thread is named by the
    /// person's own pull request first.
    public static func plan(_ input: [ThreadAction], gists: [String: MomentGist], selfNames: Set<String> = []) -> ThreadPlan {
        let sorted = input.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
        var dwell = [String: Double]()
        for (i, a) in sorted.enumerated() {
            guard !a.idle else { dwell[a.id] = 0; continue }
            if i + 1 < sorted.count {
                let gap = sorted[i + 1].at.timeIntervalSince(a.at)
                dwell[a.id] = gap > sessionGap ? lastDwell : min(max(0, gap), dwellCap)
            } else { dwell[a.id] = lastDwell }
        }
        // Each moment is about the entity it spent the most time on.
        var perMoment = [String: [String: Double]](), entities = [String: ThreadEntity](), firstSeen = [String: Int]()
        var momentPeople = [String: [String]]()
        for (i, a) in sorted.enumerated() where !a.idle {
            perMoment[a.moment, default: [:]][a.entity.raw, default: 0] += (dwell[a.id] ?? 0) + 0.001
            if entities[a.entity.raw] == nil { entities[a.entity.raw] = a.entity; firstSeen[a.entity.raw] = i }
            else {
                // fix/sx-all round 1: a project keeps its own casing ("DayDream code" as Xcode writes it, not "Daydream
                // code" from a terminal's lower-case folder): the spelling with the most capitals wins.
                if a.entity.kind == "code", a.entity.label.filter(\.isUppercase).count > entities[a.entity.raw]!.label.filter(\.isUppercase).count {
                    entities[a.entity.raw]!.label = a.entity.label
                }
                for p in a.entity.people where !entities[a.entity.raw]!.people.contains(p) { entities[a.entity.raw]!.people.append(p) }
                for p in a.entity.places where !entities[a.entity.raw]!.places.contains(p) { entities[a.entity.raw]!.places.append(p) }
            }
            for p in a.entity.people where !momentPeople[a.moment, default: []].contains(p) { momentPeople[a.moment, default: []].append(p) }
        }
        // The named Slack channel or person seen last before each moment starts (for a Slack row with neither).
        var lastSlack = [String: ThreadEntity](), seenSlack: ThreadEntity? = nil, started = Set<String>()
        for a in sorted where !a.idle {
            if started.insert(a.moment).inserted, let s = seenSlack { lastSlack[a.moment] = s }
            if a.entity.kind == "slack", a.entity.raw != "slack:" { seenSlack = entities[a.entity.raw] ?? a.entity }
        }
        var momentEntity = [String: ThreadEntity]()
        for (m, raws) in perMoment {
            guard let best = raws.sorted(by: { ($0.value, -(firstSeen[$0.key] ?? 0)) > ($1.value, -(firstSeen[$1.key] ?? 0)) }).first, var e = entities[best.key] else { continue }
            // A typed row's recipient joins its conversation (a Messages row whose title had no name).
            if ["texts", "email", "slack"].contains(e.kind) { for p in momentPeople[m] ?? [] where !e.people.contains(p) { e.people.append(p) } }
            // fix/sx-all round 2: a Messages window titled only "Messages" is keyed by the conversation its typed rows went
            // to ("texts:riley"); with no name at all, by its own moment. Never one empty "texts:" thread for every chat.
            if e.kind == "texts", e.raw == "texts:" {
                if let who = e.people.first { e.raw = "texts:" + who.lowercased(); e.fallback = e.raw; e.label = "Texts with " + who }
                else { e.raw = "texts:?" + m; e.fallback = e.raw }
            }
            // fix/sx-all round 3: a Slack row with no channel or person (a web typing row whose composer had no label) goes
            // with the channel or person last seen in Slack before it that day; with none, its own moment. Never one empty
            // "slack:" thread beside the channel it was posted in.
            if e.kind == "slack", e.raw == "slack:" {
                if let prior = lastSlack[m] { e = prior } else { e.raw = "slack:?" + m; e.fallback = e.raw }
            }
            // The same for an email whose typed rows say who it went to: it is that recipient's thread (the subject, if
            // any, still names it), never inbox triage and never merged with an email to someone else.
            if e.kind == "email", !e.raw.hasPrefix("email:to:"), let who = e.people.first {
                e.raw = "email:to:" + ThreadEntities.norm(who); e.fallback = e.raw
                if e.label == "Email" { e.label = "Email to " + who }
            }
            // An AI ask: its note's title names what it was about (never the chat title, often the typed question).
            if e.kind == "ai", let title = gists[m]?.title, !title.isEmpty, !ThreadEntities.saysOnlyTheApp(title, e) {
                e.raw = e.fallback + "|" + ThreadEntities.norm(title); e.label = title
                e.topic = ThreadEntities.topicWords(title); e.nouns = ThreadEntities.salientNouns(title)
                if let line = gists[m]?.intent { e.nouns += ThreadEntities.salientNouns(line).filter { !e.nouns.contains($0) } }
            }
            momentEntity[m] = e
        }
        // Link by topic: union-find over the entities the moments are about.
        let used = Array(Set(momentEntity.values.map(\.raw))).sorted()
        // notes-quality: names the day's titles write with a capital inside them ("Lisbon", "Q3", "SaaS"); a title that
        // starts with one ("Lisbon in 3 days") has it too. People's names never link two things.
        let peopleWords = Set(momentEntity.values.flatMap { $0.people.flatMap(ThreadEntities.tokens) })
        // A name in many titles (a workspace or company: "Tallybird") or a project's own name (projects link by project)
        // says nothing about which thing it is: never a link.
        let linkable = Dictionary(momentEntity.values.filter { !$0.comms }.map { ($0.raw, $0) }, uniquingKeysWith: { a, _ in a }).values
        var spread = [String: Int]()
        for e in linkable { for w in Set(e.nouns + ThreadEntities.tokens(e.label)) { spread[w, default: 0] += 1 } }
        let projects = Set(linkable.compactMap(\.project))
        // fix/sx-all round 3: nor any part of a project's name ("Tallybird" of tallybird-sync: a Discord server, a company).
        let projectParts = Set(projects.flatMap { ThreadEntities.tokens($0) })
        let salient = Set(linkable.flatMap(\.nouns)).subtracting(peopleWords).subtracting(projects).subtracting(projectParts).filter { (spread[$0] ?? 0) <= 3 }
        func names(_ e: ThreadEntity) -> Set<String> {
            guard !e.comms, !["search", "app"].contains(e.kind) else { return [] }
            return Set(e.nouns + ThreadEntities.tokens(e.kind == "ai" ? e.topic.joined(separator: " ") : e.label + " " + e.topic.joined(separator: " "))).intersection(salient)
        }
        var parent = Dictionary(uniqueKeysWithValues: used.map { ($0, $0) })
        func find(_ x: String) -> String { var x = x; while parent[x]! != x { parent[x] = parent[parent[x]!]!; x = parent[x]! }; return x }
        let byRaw = Dictionary(momentEntity.values.map { ($0.raw, $0) }, uniquingKeysWith: { a, _ in a })
        for (i, x) in used.enumerated() {
            guard let ex = byRaw[x] else { continue }
            for y in used[(i + 1)...] {
                guard let ey = byRaw[y] else { continue }
                // fix/sx-all round 3: someone else's pull request (its author known and not the person) is never joined by the
                // project alone: a review of PR #907 is not the person's own work on #903 and #911.
                func foreign(_ e: ThreadEntity) -> Bool { e.kind == "pr" && !selfNames.isEmpty && e.author.map { !selfNames.contains($0) } == true }
                let byProject = !foreign(ex) && !foreign(ey)
                let sameProject = byProject && ex.project != nil && ex.project == ey.project
                // fix/sx-all round 3: titles link by their own words, never by the project's name or a bare number they share
                // ("Harborline 2.0 launch date" and "Harborline 2.0 release notes" are two things).
                func own(_ e: ThreadEntity) -> [String] { e.topic.filter { !projects.contains($0) && Int($0) == nil } }
                guard sameProject || ThreadEntities.linked(own(ex), own(ey)) || !names(ex).isDisjoint(with: names(ey))
                        || ThreadEntities.workLinked(ex, ey, projects: projects, people: peopleWords, byProject: byProject) else { continue }
                let (rx, ry) = (find(x), find(y))
                if rx != ry { parent[max(rx, ry)] = min(rx, ry) }
            }
        }
        var groups = [String: [ThreadEntity]]()
        for raw in used { groups[find(raw), default: []].append(byRaw[raw]!) }
        var keyFor = [String: String]()
        let rank = ["doc", "meeting", "pr", "code", "ai"]
        for (_, members) in groups {
            // An AI ask on its own stays in its app's thread ("ai:claude"); linked, the most telling anchor names the key.
            let anchors = members.filter { $0.anchor && ($0.kind != "ai" || members.count > 1) }
                .sorted { (rank.firstIndex(of: $0.kind) ?? 9, $0.raw) < (rank.firstIndex(of: $1.kind) ?? 9, $1.raw) }.map(\.raw)
            // Things linked by a name with no anchor (a video and a page about Lisbon): one thread keyed by the first.
            let linkedKey = members.count > 1 ? "topic:" + members.map(\.raw).sorted()[0] : nil
            // AI asks linked only to each other stay in their app's thread.
            let onlyAI = members.allSatisfy { $0.kind == "ai" }
            for m in members { keyFor[m.raw] = onlyAI ? m.fallback : anchors.first ?? linkedKey ?? m.fallback }
        }
        var momentKey = [String: String]()
        for (m, e) in momentEntity { momentKey[m] = keyFor[e.raw] ?? e.fallback }

        // Runs: consecutive actions of one thread, cut into sessions at long gaps.
        struct Run { var key: String; var start: Date; var end: Date; var focus: Double; var ids: [String]; var session: Int }
        var runs = [Run](), session = 0, previous: Date? = nil
        for a in sorted {
            if let p = previous, a.at.timeIntervalSince(p) > sessionGap { session += 1 }
            previous = a.at
            guard !a.idle, let key = momentKey[a.moment] else { continue }
            if let last = runs.last, last.key == key, last.session == session {
                runs[runs.count - 1].end = a.at; runs[runs.count - 1].focus += dwell[a.id] ?? 0; runs[runs.count - 1].ids.append(a.id)
            } else { runs.append(Run(key: key, start: a.at, end: a.at, focus: dwell[a.id] ?? 0, ids: [a.id], session: session)) }
        }
        // Blocks over runs (see the file comment).
        var blockOf = [String: Int](), block = -1, focus = [String: Double](), blockStart = Date.distantPast, blockSession = -1
        func main() -> String? { focus.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.first?.key }
        for (i, run) in runs.enumerated() {
            var cut = block < 0 || run.session != blockSession || run.end.timeIntervalSince(blockStart) > maxSpan
            if !cut, let m = main(), run.key != m, focus.values.reduce(0, +) >= establish {
                var excursion = [String: Double](), j = i
                while j < runs.count, runs[j].session == run.session, !(runs[j].key == m && runs[j].focus >= shortSwitch) {
                    excursion[runs[j].key, default: 0] += runs[j].focus; j += 1
                }
                // The main thread comes back: an interruption, unless a long one. It doesn't: the other thread took over.
                let back = j < runs.count && runs[j].session == run.session
                let total = excursion.values.reduce(0, +), top = excursion.values.max() ?? 0
                cut = back ? total >= interruptionCut && top >= interruptionTop : total >= switchCut && top >= switchTop
            }
            if cut { block += 1; focus = [:]; blockStart = run.start; blockSession = run.session }
            focus[run.key, default: 0] += run.focus
            for id in run.ids { blockOf[id] = block }
        }
        // Each moment goes to the block that holds most of its time.
        var momentBlocks = [String: [Int: Double]](), momentFirst = [String: (Date, Int)](), lastBlock = 0
        for a in sorted {
            // An idle row goes with the block before it.
            let b = blockOf[a.id] ?? lastBlock
            lastBlock = b
            momentBlocks[a.moment, default: [:]][b, default: 0] += (dwell[a.id] ?? 0) + 0.001
            if momentFirst[a.moment] == nil { momentFirst[a.moment] = (a.at, b) }
        }
        var members = [Int: [String]]()
        for (m, shares) in momentBlocks {
            let b = shares.sorted { ($0.value, -$0.key) > ($1.value, -$1.key) }.first?.key ?? 0
            members[b, default: []].append(m)
        }
        let blocks = members.keys.sorted().map { b in members[b]!.sorted { (momentFirst[$0]!.0, $0) < (momentFirst[$1]!.0, $1) } }
        return ThreadPlan(blocks: blocks, momentKey: momentKey, actions: sorted, dwell: dwell, momentEntity: momentEntity, gists: gists, selfNames: selfNames)
    }
}

public enum LevelThreads {
    /// Bumped when the grouping or the bullets change, so every block and day is written again.
    public static let version = "threads9"
    /// A bullet needs at least this much focus.
    public static let minBullet = 60
    /// notes-quality: at most four side threads, on a block and on the day card.
    public static func maxBullets(_ level: LevelKind) -> Int { level == .block || level == .day ? 4 : 5 }
    /// A video or an app on its own is a bullet only from this much focus.
    public static let minPassive = 10 * 60

    /// "Maya", "Maya and Sam", "Maya, Sam and Priya", "Maya, Sam and 2 others".
    public static func names(_ people: [String]) -> String {
        switch people.count {
        case 0: return ""
        case 1: return people[0]
        case 2, 3: return people.dropLast().joined(separator: ", ") + " and " + people.last!
        default: return people.prefix(2).joined(separator: ", ") + " and \(people.count - 2) others"
        }
    }
    /// "~8 min", "~15 min", "~1 hr 20 min", "~2 hr".
    public static func duration(_ seconds: Int) -> String {
        let m = max(1, Int((Double(seconds) / 60).rounded()))
        if m < 10 { return "~\(m) min" }
        let r = Int((Double(m) / 5).rounded()) * 5
        if r < 60 { return "~\(r) min" }
        return r % 60 == 0 ? "~\(r / 60) hr" : "~\(r / 60) hr \(r % 60) min"
    }

    /// Texts, Slack and email by who and where: "Texts with Maya and Sam", "Slack with Priya, in #eng" (people, then the
    /// channels after "in", so a channel never reads as a person),
    /// "Email with Dana and Priya", "Email about Invoice #3107", "Email triage" (three subjects or more, no names).
    public static func channelLabel(_ kind: String, people: [String], places: [String]) -> String {
        switch kind {
        case "texts": return people.isEmpty ? "Texts" : "Texts with " + names(people)
        case "slack":
            if !people.isEmpty { return "Slack with " + names(people) + (places.isEmpty ? "" : ", in " + names(places)) }
            return places.isEmpty ? "Slack" : "Slack in " + names(places)
        default:
            if !people.isEmpty { return "Email with " + names(people) }
            if places.count == 1 { return "Email about " + places[0] }
            if places.count == 2 { return "Email about " + places[0] + " and 1 more" }
            return places.isEmpty ? "Email" : "Email triage"
        }
    }
    /// A parent's threads from its children's (a day's from its blocks, a week's from its days, a month's from its
    /// weeks); each thread's children become the child note ids.
    public static func merge(_ blocks: [LevelNote]) -> [LevelThread] {
        var out = [String: LevelThread](), best = [String: Int](), order = [String]()
        for block in blocks.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            for t in block.threads ?? [] {
                if var x = out[t.key] {
                    x.seconds += t.seconds; x.bursts += t.bursts
                    if !x.children.contains(block.id) { x.children.append(block.id) }
                    x.moments = (x.moments ?? []) + t.momentIDs.filter { !(x.moments ?? []).contains($0) }
                    for p in t.people where !x.people.contains(p) { x.people.append(p) }
                    for p in t.places where !x.places.contains(p) { x.places.append(p) }
                    x.start = min(x.start, t.start); x.end = max(x.end, t.end)
                    if t.seconds > best[t.key]! { best[t.key] = t.seconds; x.label = t.label; x.kind = t.kind; x.intent = t.intent ?? x.intent }
                    else if x.intent == nil { x.intent = t.intent }
                    out[t.key] = x
                } else {
                    var x = t; x.children = [block.id]; x.moments = t.momentIDs; out[t.key] = x; best[t.key] = t.seconds; order.append(t.key)
                }
            }
        }
        for (k, t) in out where k == "email" || t.kind == "texts" { out[k]!.label = channelLabel(t.kind, people: t.people, places: t.places) }
        // fix/sx-all: a day's threads lead the same way as a block's (the 9/23 day read "Watched Lisbon in 3 days travel
        // guide": its blocks put the cabin search first, but the merge sorted by time alone).
        return leadFirst(order.compactMap { out[$0] }.sorted { ($0.seconds, $1.start) > ($1.seconds, $0.start) })
    }

    /// Threads most focus first, then what the stretch was for leads: texts read, an inbox or a video with nothing sent
    /// is not the main thread when something was sent or asked for at least a third of that time (notes-quality), and
    /// passive viewing never leads while something active held at least half its time (fix/sx-all, as LiveDay).
    public static func leadFirst(_ sorted: [LevelThread]) -> [LevelThread] {
        var out = sorted
        let quiet: Set<String> = ["texts", "slack", "email", "chat", "social", "video", "app", "site", "search"]
        if let top = out.first, top.intent == nil, quiet.contains(top.kind),
           let i = out.firstIndex(where: { $0.intent != nil && $0.seconds * 3 >= top.seconds }) {
            out.insert(out.remove(at: i), at: 0)
        }
        if let top = out.first, top.intent == nil, top.kind == "video",
           let i = out.firstIndex(where: { $0.kind != "video" && $0.seconds * 2 >= top.seconds }) {
            out.insert(out.remove(at: i), at: 0)
        }
        // fix/sx-all round 2: a video never leads while a conversation (texts, Slack, email, a chat) shares the stretch.
        if let top = out.first, top.kind == "video", let i = out.firstIndex(where: { ["texts", "slack", "email", "chat"].contains($0.kind) }) {
            out.insert(out.remove(at: i), at: 0)
        }
        return out
    }

    /// The side threads as bullets, most focus first: texts, Slack and email each one bullet with its names
    /// ("Texts with Maya and Sam, ~15 min"), everything else one bullet per thread; past `max`, one or two more share an
    /// "Also ..." bullet, and more than that are left out. The main thread (the first) is the headline, never a bullet.
    /// A thread's name with nothing read from a window title, a person or a subject: the app, the site or the kind of
    /// thing ("AI chat", "Document", "YouTube"). The fallback when the code's note would repeat a short typed draft (a
    /// chat whose page title is the question typed into it), so a note can still be saved (r1 levels-pipeline).
    public static func plainLabel(_ t: LevelThread) -> String {
        switch t.kind {
        case "texts": return "Texts"
        case "chat": return "Teams chat"
        case "slack": return "Slack"
        case "email": return "Email"
        case "meeting": return "Meeting"
        case "doc": return "Document"
        case "code": return "Code"
        case "pr": return "GitHub"
        case "ai": return "AI chat"
        case "search": return "Web searches"
        case "app": return t.label
        default:
            // video and web: the site, when the thread is keyed by it.
            guard t.key.hasPrefix("site:") else { return "Web page" }
            let host = String(t.key.dropFirst(5).split(separator: "|").first ?? "")
            return host.isEmpty ? "Web page" : ThreadEntities.friendlyHosts[host] ?? host
        }
    }
    /// r2: the thread as a plain note keeps it: its plain name, and no person, channel or subject read from a window.
    /// A note saved plain (its code note would repeat a typed draft) stores its threads this way, so the day, week and
    /// month merged from it, and what AI apps read (`levelNode`), never bring the raw name back.
    public static func plained(_ t: LevelThread) -> LevelThread {
        var x = t; x.label = plainLabel(t); x.people = []; x.places = []; return x
    }
    /// notes-quality: the side threads as bullets. Things said to others come first: a thread with a sent or asked line
    /// is that line ("Texted Q7 about Friday dinner."); texts, Slack and email with none are one bullet each with their
    /// names ("Texts with Riley and Sam, ~15 min"). Then the rest by focus: "<name>, ~N min", a meeting by its title, a
    /// video or an app alone only from 10 minutes. At most `max`, never an "Also" line. The main thread (the first) is
    /// the headline, never a bullet. `plain`: no name read from a window, a person or a subject, and no sent line.
    public static func bullets(_ threads: [LevelThread], max: Int, plain: Bool = false) -> [LevelLine] {
        struct Item { var text: String; var seconds: Int; var children: [String]; var start: String; var moments: [String]; var said: Bool; var line: Bool }
        var items = [Item](), channels = [String: [LevelThread]](), channelOrder = [String]()
        func union(_ lists: [[String]]) -> [String] { var out = [String](); for l in lists { for x in l where !out.contains(x) { out.append(x) } }; return out }
        let comms: Set<String> = ["texts", "slack", "email", "chat", "social"]
        for t in threads.dropFirst() {
            if !plain, let line = t.intent?.trimmingCharacters(in: .whitespaces), !line.isEmpty {
                let text = line.hasSuffix(".") || line.hasSuffix("?") || line.hasSuffix("!") ? line : line + "."
                if let i = items.firstIndex(where: { $0.text == text }) {
                    items[i].seconds += t.seconds; items[i].children = union([items[i].children, t.children]); items[i].moments = union([items[i].moments, t.momentIDs])
                } else {
                    items.append(Item(text: text, seconds: t.seconds, children: t.children, start: t.start, moments: t.momentIDs, said: true, line: true))
                }
            } else if ["texts", "slack", "email"].contains(t.kind) {
                // B2: an anonymous draft's citations must not be folded into
                // a named conversation bullet at the block/day level either.
                let channel=t.kind == "texts" && t.key.hasPrefix("texts:?") ? "texts:anonymous" : t.kind
                if channels[channel] == nil { channelOrder.append(channel) }
                channels[channel, default: []].append(t)
            } else if plain, let i = items.firstIndex(where: { $0.text == plainLabel(t) }) {
                // Plain names repeat ("Document" twice): one bullet each.
                items[i].seconds += t.seconds; items[i].children = union([items[i].children, t.children]); items[i].moments = union([items[i].moments, t.momentIDs])
                items[i].start = min(items[i].start, t.start)
            } else {
                // A video or an app alone is worth a line only when it held the screen for a while.
                if ["video", "app"].contains(t.kind), t.seconds < minPassive { continue }
                items.append(Item(text: plain ? plainLabel(t) : t.label, seconds: t.seconds, children: t.children, start: t.start, moments: t.momentIDs,
                                  said: comms.contains(t.kind), line: false))
            }
        }
        for channel in channelOrder {
            let group = channels[channel]!.sorted { ($0.start, $0.key) < ($1.start, $1.key) }
            let kind=group[0].kind
            let text = plain ? plainLabel(group[0]) : channelLabel(kind, people: union(group.map(\.people)), places: union(group.map(\.places)))
            items.append(Item(text: text, seconds: group.map(\.seconds).reduce(0, +), children: union(group.map(\.children)), start: group.map(\.start).min()!,
                              moments: union(group.map(\.momentIDs)), said: true, line: false))
        }
        // A sent line stays whatever its time (a text takes seconds); the rest need a minute of focus.
        items = items.filter { $0.line || $0.seconds >= minBullet }
            .sorted { ($0.line ? 1 : 0, $0.said ? 1 : 0, $0.seconds, $1.start) > ($1.line ? 1 : 0, $1.said ? 1 : 0, $1.seconds, $0.start) }
        return items.prefix(max).map { LevelLine(text: $0.line ? $0.text : $0.text + ", " + duration($0.seconds), children: $0.children, moments: $0.moments) }
    }
}
