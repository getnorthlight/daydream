import Foundation

// The ITEMS view the writer model reads (prompt5). Port of PromptEval/final/prompt4.py:43-360:
// code folds a note's actions into items (and, for long scopes, items into one per app), hides injected,
// health, money and sensitive-number text and idle time, and never shows action IDs, bundle IDs, hedges,
// timestamps, key presses or repeat visits. PromptChecks pins this port
// to the Python spec with PromptEval/final/goldens-prompt4.json.

/// A compiled ICU pattern with the few Python `re` operations the spec uses.
struct Pattern: @unchecked Sendable {
    let regex: NSRegularExpression
    init(_ pattern: String) { regex = try! NSRegularExpression(pattern: pattern) }
    private func all(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }
    func first(_ s: String) -> Range<String.Index>? {
        regex.firstMatch(in: s, range: all(s)).flatMap { Range($0.range, in: s) }
    }
    func search(_ s: String) -> Bool { regex.firstMatch(in: s, range: all(s)) != nil }
    /// Every match, left to right: (range, matched text).
    func matches(_ s: String) -> [(Range<String.Index>, String)] {
        regex.matches(in: s, range: all(s)).compactMap { m in Range(m.range, in: s).map { ($0, String(s[$0])) } }
    }
    /// Capture group `group` of the first match, nil when there is no match or the group did not take part.
    func group(_ s: String, _ group: Int) -> String?? {
        guard let m = regex.firstMatch(in: s, range: all(s)) else { return nil }
        guard let r = Range(m.range(at: group), in: s) else { return .some(nil) }
        return .some(String(s[r]))
    }
    func replacing(_ s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: all(s), withTemplate: template)
    }
}

/// prompt7 send facts a typed row carries (typed-unit/v3, spec §3): code decides the surface and whether a send gesture was
/// detected; the view only renders them. Rows sealed before v3 carry none: their surface comes from the app or site.
struct SendFacts: Sendable, Equatable {
    enum Key { case surface, send, sendBy, to, pasted, runID, field, sendControl, handle, community, subject, contextAuthor, contextExcerpt, seal }
    var surface: String?, send: String?, sendBy: String?, to: String?, pasted: Bool?, runID: String?, field: String?
    /// claude/messages2-1003: what sealed the unit (`NoteAction.seal`).
    var seal: String?
    /// claude/messages-1003 (compose-send/v1): the composer's control, destination and what a reply answered (metadata).
    var sendControl: String?, handle: String?, community: String?, subject: String?, contextAuthor: String?, contextExcerpt: String?
    init() {}
    init(_ a: NoteAction) {
        surface = a.surface; send = a.send; sendBy = a.sendBy; to = a.to; pasted = a.pasted; runID = a.runID; field = a.field
        sendControl = a.sendControl; handle = a.handle; community = a.community; subject = a.subject
        contextAuthor = a.contextAuthor; contextExcerpt = a.contextExcerpt
        seal = a.seal
    }
    /// Python truthiness: nil for a missing, empty or false fact.
    func value(_ key: Key) -> String? {
        let v: String?
        switch key {
        case .surface: v = surface
        case .send: v = send
        case .sendBy: v = sendBy
        case .to: v = to
        case .pasted: v = pasted == true ? "true" : nil
        case .runID: v = runID
        case .field: v = field
        case .sendControl: v = sendControl
        case .handle: v = handle
        case .community: v = community
        case .subject: v = subject
        case .contextAuthor: v = contextAuthor
        case .contextExcerpt: v = contextExcerpt
        case .seal: v = seal
        }
        return v?.isEmpty == false ? v : nil
    }
    /// The later piece's facts win; pasted text anywhere in the unit counts.
    func merged(_ later: SendFacts) -> SendFacts {
        var m = self
        if later.surface != nil { m.surface = later.surface }
        if later.send != nil { m.send = later.send }
        if later.sendBy != nil { m.sendBy = later.sendBy }
        if later.to != nil { m.to = later.to }
        if later.pasted != nil { m.pasted = later.pasted }
        if later.runID != nil { m.runID = later.runID }
        if later.field != nil { m.field = later.field }
        if later.sendControl != nil { m.sendControl = later.sendControl }
        if later.handle != nil { m.handle = later.handle }
        if later.community != nil { m.community = later.community }
        if later.subject != nil { m.subject = later.subject }
        if later.contextAuthor != nil { m.contextAuthor = later.contextAuthor }
        if later.contextExcerpt != nil { m.contextExcerpt = later.contextExcerpt }
        if later.seal != nil { m.seal = later.seal }
        if pasted == true || later.pasted == true { m.pasted = true }
        return m
    }
}

/// notes-quality: one typed text the copy rule checks, with its field and the text whose capitals count as names.
struct Guarded: Sendable, Equatable {
    let words: String, field: String, nameSource: String
}

/// One thing the person had open, typed or was told, with its clicks, shortcuts, Return presses and repeat visits folded in.
/// The view says only whether an item was "in use", never which keys or how often (prompt5).
public struct ModelItem: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case window, tab, mechonly, other, typed, search, screentext, idle, sent, unverified, unavailable, report, note, request, plan
    }
    public let kind: Kind
    public let app: String
    public fileprivate(set) var title: String
    public fileprivate(set) var text: String?
    public let site: String
    /// prompt7: surface, send, sendBy, to, pasted, runID from the last piece of the unit (typed items only).
    fileprivate(set) var facts = SendFacts()
    /// prompt7: the whole unit's words as typed (a run joined by runID), for the copy rule; never shown longer than 1,600.
    fileprivate(set) var words: String?
    /// prompt7: shown under NEXT (after the moment's last send).
    public fileprivate(set) var next = false
    public fileprivate(set) var actions: [NoteAction] = []
    public fileprivate(set) var alias = ""
    public fileprivate(set) var line = ""
    /// Items folded into this one (scopes over 40 items or 16,000 bytes), or the drafts of a typing run, in order.
    public fileprivate(set) var parts: [ModelItem] = []
    /// sat5: typed items in a row in one app whose words aren't shown, as one item with its window titles and how long it took.
    public fileprivate(set) var run = false
    /// A summary-only collection of independently captured requests to the same verified AI context.
    /// Source actions and guards remain complete; it never claims the requests were one typing run.
    public fileprivate(set) var requestSession = false
    fileprivate(set) var counts: [String: Int] = [:]
    fileprivate var lastAt = ""
    /// notes-quality: focused seconds (each action of the scope counts until the next one, at most 5 minutes).
    public fileprivate(set) var seconds: Double = 0
    /// notes-quality: every typed text the item holds, for the copy rule: each unit of a merged send, a run's pieces, an
    /// email's To and Subject units (checked as core checks them, `TypedVerbatimGuard.copies(field:)`).
    fileprivate(set) var guards: [Guarded] = []
    /// notes-quality: the texts of the sends to one person or place merged into this item, in order.
    /// claude/messages-1003 (owner): every text sent in one Messages conversation of the moment, in order.
    fileprivate(set) var pieces: [String] = []
    /// claude/messages-1003: texts typed in this Messages conversation that no send was seen for (a draft left after the
    /// sends). Shown on the conversation's line for the model to mention at most; their rows are never cited (a bullet
    /// that cites a draft row can't say "Texted").
    fileprivate(set) var unsent: [String] = []
    /// notes-quality: an email's subject typed in its Subject field (folded into the email).
    fileprivate(set) var subject: String?
    /// notes-quality: the typed row's own window name (cleaned), which core's copy guard also treats as a place.
    fileprivate(set) var rowTitle = ""
    /// fix/sx-all round 2: a pull request's author as its page title names it ("... by sam · Pull Request #212 · ..."), or nil.
    fileprivate(set) var prAuthor: String?
    /// fix/sx-all round 2: true for the person's own pull request (its author is one of the request's `selfNames`), false
    /// for someone else's (the person's names are known and the author isn't one of them), nil when code can't tell.
    public fileprivate(set) var ownPR: Bool?
    /// fix/sx-all round 2: DayDream could have recorded typing in this app (site) while it was in front: typing on, its
    /// category on, the app's signer confirmed, not paused (`NoteAction.typing`). Only then does nothing typed mean
    /// nothing was written there, so code may say "Read" or "Looked at".
    public fileprivate(set) var typingRecordable = false

    init(_ kind: Kind, app: String, title: String = "", text: String? = nil, site: String = "") {
        self.kind = kind; self.app = app; self.title = title; self.text = text
        // chrome/v1 stores an origin; show the host.
        self.site = ModelView.trailing(ModelView.scheme.replacing(site, with: ""), "/")
    }
    fileprivate mutating func add(_ action: NoteAction, _ count: String?) {
        actions.append(action); lastAt = max(lastAt, action.at)
        if let count, count != "silent" { counts[count, default: 0] += 1 }
    }
    /// Clicks, shortcuts or Return presses were folded in.
    func inUse() -> Bool { ["click", "shortcut", "return"].contains { (counts[$0] ?? 0) > 0 } }
    /// Typed text where a message could be sent (prompt7: an email, text, chat or social surface).
    func message() -> Bool { kind == .typed && ["email", "text", "chat", "social"].contains(surface() ?? "") }
    /// prompt7: where the typing happened, from the seal's facts or, for older rows, the app or site.
    func surface() -> String? {
        guard kind == .typed else { return nil }
        let src = parts.last ?? self
        if let s = src.facts.surface, !s.isEmpty { return s }
        return ModelView.derivedSurface(app, site)
    }
    func fact(_ key: SendFacts.Key) -> String? { (parts.last ?? self).facts.value(key) }
    func detected() -> Bool { kind == .typed && fact(.send) == "detected" && ModelView.sendSurfaces.contains(surface() ?? "") }
    func label() -> String {
        guard let s = surface() else { return "" }
        if s == "ai" && !site.isEmpty { return "AI website" }
        return ModelView.surfaceLabel[s] ?? ""
    }
    /// "sent with Return" and the like when a send gesture was detected; "sending unknown" where a send was possible.
    func ending() -> String {
        if detected() { return "sent with " + (ModelView.endingName[fact(.sendBy) ?? "return"] ?? "Return") }
        if fact(.send) == "none" || !ModelView.sendSurfaces.contains(surface() ?? "") { return "" }
        return "sending unknown"
    }
    func toName() -> String {
        let t = (fact(.to) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // claude/messages2-1003: a text's phone number or email address is never a name the model sees (`textHandle`).
        if surface() == "text", ModelView.contactHandle(t) { return "" }
        return t.isEmpty || t.hasPrefix("#") ? "" : ModelView.clean(t, 60)
    }
    /// claude/messages2-1003 (owner 10/3: "the card knows who"): a Messages conversation known only by its phone number or
    /// email address (its own window title, which core passes in `to`). The model never sees it (rule 6: it writes
    /// "Texted someone", as for a conversation no one was read for); code groups the conversation's texts by it and names
    /// it in the stored bullet (`CanonicalGrounding.nameHandles`). "" for anything else.
    func textHandle() -> String {
        guard surface() == "text" else { return "" }
        let t = (fact(.to) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ModelView.contactHandle(t) ? t : ""
    }
    /// The conversation a text belongs to: its name, else its handle; "" when code read neither.
    func conversation() -> String { toName().isEmpty ? textHandle() : toName() }
    /// The window the unit was typed in, unless it only repeats who it went to (a Messages conversation). A channel code read
    /// ("#launch", capture puts it in `to`) is where it was posted, so it is the in name.
    func inName() -> String {
        let channel = (fact(.to) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if channel.hasPrefix("#") { return "\"" + ModelView.clean(channel, 60) + "\"" }
        let place = typedPlace()
        if !place.isEmpty, !toName().isEmpty, ModelView.stripQuotes(place).lowercased() == toName().lowercased() { return "" }
        // claude/messages2-1003: a text's window titled by its number or address is that conversation: never shown (rule 6).
        if !place.isEmpty, surface() == "text", !textHandle().isEmpty || ModelView.contactHandle(ModelView.stripQuotes(place)) { return "" }
        // fix/sx-all: a post's cleaned page title is often just the site ("X"): not `in "X" on X`.
        if !place.isEmpty, surface() == "social", ModelView.stripQuotes(place).lowercased() == who().lowercased() { return "" }
        return place
    }
    /// The words a bullet about this send may start with (spec §6). Only when a send was detected. notes-quality: a send
    /// whose words weren't shown still gets its lead and who ("Texted Q7"): code saw the send key and read the window.
    func leads() -> [String] {
        guard detected() else { return [] }
        let s = surface() ?? ""
        let w = (words?.isEmpty == false ? words : nil) ?? text ?? ""
        switch s {
        case "ai", "aiTool":
            var out = ["Asked"]
            // claude/summary-1003 (owner): feedback to a coding tool reads "Told Claude Code the summary is confusing".
            if s == "aiTool" { out.append("Told") }
            if ModelView.approvalCue.search(w) { out.append("Approved") }
            if ModelView.agreeCue.search(w) { out.append("Agreed") }
            return out
        case "email":
            // fix/sx-all round 1: a reply with no recipient read leads with the thread ("Replied on the pricing thread"),
            // not "Emailed about <Subject>".
            let reply = ModelView.stripQuotes(inName()).lowercased().hasPrefix("re:")
            if reply && addressee().isEmpty && !who().isEmpty { return ["Replied", "Emailed"] }
            return ["Emailed"] + (reply ? ["Replied"] : [])
        case "text": return ["Texted"]
        case "chat": return channel().isEmpty ? ["Messaged", "Told"] : ["Messaged", "Told", "Posted"]
        // claude/messages-1003: a reply, quote or comment says what it answered ("Replied to Ada's post on X").
        case "social":
            switch compose() {
            case "replied": return ["Replied"]
            case "quoted": return ["Quoted"]
            case "commented": return ["Commented"]
            default: return ["Posted"]
            }
        case "search": return ["Searched"]
        case "form": return ["Filled in"]
        default: return []
        }
    }
    /// A chat channel code read ("#eng"), or "".
    func channel() -> String {
        let c = (fact(.to) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return c.hasPrefix("#") ? ModelView.clean(c, 60) : ""
    }
    /// The AI app or site a question went to. build/7 (APP-COVERAGE): an AI surface's stored `to` fact first (capture
    /// names Gemini and Perplexity web there), so they read "Asked Gemini", never "Asked Google Chrome". fix/sx-all round 1:
    /// an AI tool in a terminal ("Claude Code", "Codex") is the tool capture read into `to`, never the terminal app.
    func aiName() -> String {
        let s = surface()
        if s == "ai" || s == "aiTool", !toName().isEmpty { return toName() }
        if !site.isEmpty && ModelView.aiSite.search(site) { return site.lowercased().contains("claude") ? "Claude" : "ChatGPT" }
        if surface() == "aiTool", !toName().isEmpty { return toName() }
        return app
    }
    /// fix/sx-all round 1: the short names a bullet may call an AI tool by ("Claude" for Claude Code), besides its full name.
    func aiAliases() -> [String] {
        guard surface() == "aiTool" else { return [] }
        let n = aiName().lowercased()
        var out: [String] = []
        if n.hasPrefix("claude") && n != "claude" { out.append("claude") }
        if n.hasPrefix("codex") && n != "codex" { out.append("codex") }
        return out
    }
    /// notes-quality: who or where a send went, as its bullet must name it: the Messages conversation ("Q7"), the email's
    /// recipient ("Sam") or thread ("Q3 numbers"), the channel ("#eng"), the site ("X") or the AI app ("Claude"). "" when
    /// code read none. From the typed words only for an email with no recipient read: the name its greeting opens with
    /// ("Hi Sam, ..." is to Sam).
    func who() -> String {
        switch surface() ?? "" {
        case "text": return toName()
        case "email":
            if !toName().isEmpty { return toName() }
            // A To field typed on its own ("Sam"): who the email was to (its copy rule allows it, field "to").
            if fact(.field) == "to", let t = text, let name = ModelView.personName(t) { return name }
            if fact(.field) != "subject", let t = text, let name = ModelView.greeted(t) { return name }
            return ModelView.subjectOf(ModelView.stripQuotes(inName()))
        case "chat": return channel().isEmpty ? toName() : channel()
        case "social": return ModelView.friendlySite(site)
        case "ai", "aiTool": return aiName()
        default: return ""
        }
    }
    /// notes-quality: the person an email or text went to (read To, a To field typed on its own, an email's greeting), or "".
    func addressee() -> String {
        if !toName().isEmpty { return toName() }
        guard surface() == "email", let t = text else { return "" }
        if fact(.field) == "to" { return ModelView.personName(t) ?? "" }
        return fact(.field) == "subject" ? "" : ModelView.greeted(t) ?? ""
    }
    /// claude/messages-1003: the first name of the one person a text went to ("Jamie" for "Jamie Lin"), which a bullet
    /// may call them by; nil for a group, a one-word name or anything that isn't a person's name.
    func firstName() -> String? {
        guard surface() == "text", let name = ModelView.personName(toName()), name.contains(" "),
              let first = name.split(separator: " ").first, first.count >= 2 else { return nil }
        return String(first)
    }
    /// A Messages conversation that isn't one person ("Q7", "Maya, Sam & 2 more").
    func groupChat() -> Bool { surface() == "text" && !toName().isEmpty && ModelView.personName(toName()) == nil }
    /// claude/messages-1003 (compose-send/v1, `ComposeSend.outcome`): what a post on a social site was: "replied",
    /// "quoted", "commented" or "posted", from the composer's control, its community and handle and whether it answered
    /// something, as capture read them (metadata, never the words). "" off a social site. A draft is decided the same
    /// way, for "Drafted a reply to ...".
    func compose() -> String {
        guard kind == .typed, surface() == "social" else { return "" }
        let control = (fact(.sendControl) ?? "").lowercased()
        let answered = contextAuthor() != nil || contextExcerpt() != nil
        if control == "quote" { return "quoted" }
        if community() != nil { return control == "comment" || answered ? "commented" : "posted" }
        if control == "reply" || answered || handle() != nil { return "replied" }
        return "posted"
    }
    /// The author of what a reply, quote or comment answered, as the page shows them ("Ada"), or nil (none read, too
    /// long, or anything private or addressed to AI tools).
    func contextAuthor() -> String? { ModelView.metaName(fact(.contextAuthor), 40) }
    /// What it answered, as the page shows it, at most 80 characters, or nil (none read, or private: health, money, a
    /// secret or text addressed to AI tools are never shown).
    func contextExcerpt() -> String? { ModelView.metaName(fact(.contextExcerpt), 80) }
    /// The community it went to ("swift" for r/swift), or nil.
    func community() -> String? {
        guard let c = ModelView.metaName(fact(.community), 40) else { return nil }
        let bare = c.hasPrefix("r/") ? String(c.dropFirst(2)) : c
        return bare.isEmpty || bare.contains(" ") ? nil : bare
    }
    /// The handle a reply went to, without "@" ("ada"), or nil.
    func handle() -> String? {
        guard let h = ModelView.metaName(fact(.handle), 30) else { return nil }
        let bare = h.hasPrefix("@") ? String(h.dropFirst()) : h
        return bare.isEmpty || bare.contains(" ") ? nil : bare
    }
    /// What a reply answered, as a bullet names it: "Ada's post", "@ada", "r/swift", or nil.
    func answered() -> String? {
        switch compose() {
        case "replied", "quoted":
            if let a = contextAuthor() { return ModelView.possessive(a) + " post" }
            if let h = handle() { return compose() == "replied" ? "@" + h : "@" + ModelView.possessive(h) + " post" }
            return nil
        case "commented":
            if let c = community() { return "r/" + c }
            if let a = contextAuthor() { return ModelView.possessive(a) + " post" }
            return nil
        default: return nil
        }
    }
    /// The names a bullet may call what a reply answered by: its author, handle and community.
    func composeAliases() -> [String] {
        var out: [String] = []
        if let a = contextAuthor() { out.append(a) }
        if let h = handle() { out += [h, "@" + h] }
        if let c = community() { out += [c, "r/" + c] }
        return out
    }
    /// The lead and who together, as a bullet starts: "Texted Q7", "Emailed Sam", "Replied about Q3 numbers",
    /// "Posted in #eng", "Posted on X", "Asked Claude".
    func leadPhrases() -> [String] {
        let w = who()
        return leads().map { l in
            // claude/messages-1003: a text to a conversation code couldn't read went to "someone", never "unknown".
            if w.isEmpty { return l == "Searched" ? "Searched " + ModelView.engine(site, app) : l == "Texted" ? "Texted someone" : l }
            switch l {
            case "Asked": return "Asked " + aiName()
            case "Approved", "Agreed", "Filled in": return l
            case "Searched": return "Searched " + ModelView.engine(site, app)
            // fix/sx-all round 1: a subject inside a sentence is lower case ("Emailed about pricing for the team plan").
            case "Replied" where surface() != "social": return addressee().isEmpty ? "Replied on the " + ModelView.lowerTopic(w) + " thread" : "Replied to " + w
            case "Emailed": return addressee().isEmpty ? "Emailed about " + ModelView.lowerTopic(w) : "Emailed " + w
            case "Posted":
                if surface() == "social", let c = community() { return "Posted on r/" + c }
                return (surface() == "social" ? "Posted on " : "Posted in ") + w
            case "Replied" where surface() == "social", "Quoted", "Commented":
                // "Replied to Ada's post on X", "Quoted @ada's post on X", "Commented on r/swift", "Replied on X".
                let on = " on " + w
                if l == "Commented" {
                    if let c = community() { return "Commented on r/" + c }
                    return answered().map { "Commented on " + $0 + on } ?? "Commented" + on
                }
                if l == "Quoted" { return "Quoted " + (answered() ?? "a post") + on }
                return answered().map { "Replied to " + $0 + on } ?? "Replied" + on
            default: return l + " " + w
            }
        }
    }
    /// Who a send lead may name: the read to/in name, the app for an AI surface, the engine for a search, or "someone".
    func recipients() -> Set<String> {
        // "someone" only when code read no one: a send names who when it can.
        var names: Set<String> = who().isEmpty ? ["someone"] : []
        if !toName().isEmpty { names.insert(toName().lowercased()) }
        if !who().isEmpty { names.insert(who().lowercased()) }
        if let first = firstName() { names.insert(first.lowercased()) }
        for a in composeAliases() { names.insert(a.lowercased()) }
        let s = surface()
        if !inName().isEmpty {
            let place = ModelView.stripQuotes(inName())
            names.insert(place.lowercased())
            // validator9: a name read from the place ("Re: sync bug from Priya") may be who a reply went to
            if let s, ["email", "chat", "social"].contains(s) {
                for (_, w) in ModelView.placeWord.matches(place) where w.unicodeScalars.first!.properties.isUppercase && w.lowercased() != "re" { names.insert(w.lowercased()) }
            }
        }
        if s == "ai" || s == "aiTool" {
            names.insert(app.lowercased())
            names.insert(aiName().lowercased())
            for a in aiAliases() { names.insert(a) }
            if ModelView.aiSite.search(site) && site.lowercased().contains("claude") { names.insert("claude") }
            if ModelView.aiSite.search(site) && site.lowercased().contains("chat") { names.insert("chatgpt") }
        }
        if s == "search" { names.insert(ModelView.engine(site, app).lowercased()) }
        return names
    }
    /// What comes before ": " on the item's line: the app, and for typing its surface and site.
    func head() -> String {
        let name = app.isEmpty ? "Mac" : app
        if kind == .typed, !label().isEmpty, requestSession || run || parts.isEmpty { return "\(name) (\(label()))" + (site.isEmpty ? "" : " on " + site) }
        return name
    }
    /// prompt7 (spec §5): typed "<words>"[ with pasted text][ to "<to>"][ in "<in>"]; <ending>[. Start with: <leads>]. Your own
    /// words to an AI are shown whole (up to 1,600 characters); health and money stay hidden everywhere.
    func intentBody() -> String {
        if requestSession {
            // The same context and submission state were proved by the fold key.
            // Print that shared metadata once; retain every independently filtered
            // request, in order, rather than thirteen copies of prompt scaffolding.
            let requests = parts.enumerated().map { index,item in
                let source=item.text ?? ""
                let quoted = !ModelView.health.search(source) && !ModelView.finance.search(source)
                    ? "\"" + ModelView.clean(source,ModelView.typedQuoteChars) + "\""
                    : ModelView.shown(source,ModelView.typedQuoteChars).text
                let pasted=item.fact(.pasted) == nil ? "" : " (with pasted text)"
                let unverified=item.unverified() ? "; a message appeared, sending not confirmed" : ""
                return "Request \(index + 1): " + quoted + pasted + unverified
            }.joined(separator:"\n")
            let endings=Set(parts.map {$0.ending()})
            let sharedEnding=endings.count==1 ? (endings.first ?? "") :
                (parts.allSatisfy {$0.detected()} ? "submission gesture observed" : "sending unknown")
            let commonEnding=sharedEnding.isEmpty ? "" : "; each " + sharedEnding
            let leads=leadPhrases().isEmpty ? "" : ". Start with: " + leadPhrases().joined(separator:", ")
            return "Own captured requests in this AI session to \"" + aiName() + "\"" +
                (typedPlace().isEmpty ? "" : " in " + typedPlace()) + commonEnding + leads +
                ". Summarize their shared intent; these remain separate actions:\n" + requests
        }
        var b: String
        if pieces.count > 1 {
            // notes-quality: sends to one person or place in a row are one item, their texts in order.
            b = "typed " + ModelView.joinAnd(pieces.map { ModelView.shown($0, ModelView.quoteChars).text })
        } else if let t = text, !t.isEmpty {
            let limit = ModelView.typedQuoteChars
            let ai = ["ai", "aiTool"].contains(surface() ?? "")
            b = "typed " + (ai && !ModelView.health.search(t) && !ModelView.finance.search(t) ? "\"" + ModelView.clean(t, limit) + "\"" : ModelView.shown(t, limit).text)
        } else { b = "typed text (not captured)" }
        if fact(.pasted) != nil { b += " with pasted text" }
        // notes-quality: who it went to, always: to "Q7" (group chat), to "Sam", in "#eng", in "Re: Q3 numbers", on X.
        if !toName().isEmpty { b += " to \"" + toName() + "\"" + (groupChat() ? " (group chat)" : "") }
        // fix/sx-all round 2: a text, chat or email whose conversation code couldn't read (a Messages window titled
        // "Messages") says so: the model invented "Q7" from the examples when nothing named who.
        else if who().isEmpty, ["text", "chat", "email"].contains(surface() ?? "") { b += " to someone DayDream couldn't read (name no one)" }
        // claude/messages-1003: a reply's page is the post it answered, said once below ("in reply to Ada's post ...").
        let context = contextPhrase()
        if !inName().isEmpty, context == nil { b += " in " + inName() }
        if surface() == "social", !who().isEmpty { b += " on " + who() }
        // claude/messages-1003 (compose-send/v1): what a reply, quote or comment answered, as the page showed it.
        if let context { b += " " + context }
        if let subject, !subject.isEmpty, ModelView.stripQuotes(inName()).lowercased() != subject.lowercased() {
            b += " with the subject " + ModelView.shown(subject, ModelView.titleQuoteChars).text
        }
        if unverified() { b += "; a message appeared, sending not confirmed" }
        else if !ending().isEmpty { b += "; " + (pieces.count > 1 && detected() ? "each " : "") + ending() }
        // claude/messages-1003: a draft left in the conversation after its sends.
        if !unsent.isEmpty { b += "; then typed " + ModelView.joinAnd(unsent.map { ModelView.shown($0, ModelView.quoteChars).text }) + " with no send seen" }
        if !leadPhrases().isEmpty { b += ". Start with: " + leadPhrases().joined(separator: ", ") }
        else if surface() == "social", let a = answered(), compose() != "posted" {
            let what = compose() == "quoted" ? "Wrote a quote of " : compose() == "commented" && community() != nil ? "Wrote a comment on " : "Wrote a reply to "
            b += ". Start with: " + what + a + (who().isEmpty || (compose() == "commented" && community() != nil) ? "" : " on " + who())
        }
        else if surface() == "social" { b += ". Start with: Wrote a post" + (who().isEmpty ? "" : " on " + who()) }
        else if !who().isEmpty, let s = surface(), ["email", "text", "chat"].contains(s) {
            // notes-quality: a draft still names who: "Drafted an email to Sam", "Drafted a text to Q7".
            let w = who(), to = s == "email" && addressee().isEmpty ? " about " : channel().isEmpty ? " to " : " in "
            b += ". Start with: " + (s == "email" ? "Wrote an email" : s == "text" ? "Wrote a text" : "Wrote a message") + to + w
        }
        return b
    }
    /// claude/messages-1003: `in reply to Ada's post "Small tools beat big frameworks…"`, `quoting @ada's post`, `on
    /// r/swift`, or nil. The excerpt is the page's own text (metadata code read), shown as a title is: never health,
    /// money or text addressed to AI tools.
    func contextPhrase() -> String? {
        let kind = compose()
        guard ["replied", "quoted", "commented"].contains(kind) else { return nil }
        let excerpt = contextExcerpt().map { " " + ModelView.shown($0, ModelView.titleQuoteChars).text }
        var whose: String
        if let a = contextAuthor() { whose = ModelView.possessive(a) + " post" }
        else if let h = handle() { whose = "@" + ModelView.possessive(h) + " post" }
        else if excerpt != nil { whose = "a post" }
        else { return kind == "commented" && community() != nil ? "on r/" + community()! : nil }
        let verb = kind == "quoted" ? "quoting " : kind == "commented" ? "commenting on " : "in reply to "
        return verb + whose + (excerpt ?? "") + (kind == "commented" && community() != nil ? " on r/" + community()! : "")
    }
    /// A message appeared but the app did not confirm it was sent.
    func unverified() -> Bool { (counts["unverified"] ?? 0) > 0 }
    /// Title safe to show and reuse (fallback titles, "Also" bullets), or "".
    func plainTitle() -> String {
        let t = title
        if t.isEmpty || t == ModelView.hiddenTitle || t.trimmed.lowercased() == app.trimmed.lowercased() || ModelView.inject.search(t) { return "" }
        return ModelView.clean(t, ModelView.titleQuoteChars)
    }
    /// The window a typed item was typed in, quoted, or "" (no title, the app's own name, a hidden title, or a window
    /// that names nothing yet: Mail's "New Message" before a subject, "Untitled 2").
    func typedPlace() -> String {
        if title.isEmpty || title == ModelView.hiddenTitle || title.trimmed.lowercased() == app.trimmed.lowercased()
            || ModelView.placeholderTitle(title) { return "" }
        let q = ModelView.shown(title, ModelView.titleQuoteChars)
        return q.hidden ? "" : q.text
    }
    /// Adds the next typed item of a run (ModelView.init): the first becomes the run's first part.
    fileprivate mutating func join(_ x: ModelItem) {
        if parts.isEmpty {
            var first = ModelItem(kind, app: app, title: title, text: text, site: site)
            first.actions = actions; first.lastAt = lastAt
            parts = [first]; run = true
        }
        parts.append(x)
        actions += x.actions
        lastAt = max(lastAt, x.lastAt)
    }
    /// Seconds from the run's first draft to its last.
    func span() -> Double {
        guard let first = parts.first?.actions.first, let last = parts.last?.actions.first else { return 0 }
        return ModelView.seconds(last.at) - ModelView.seconds(first.at)
    }
    func windowName() -> String {
        if title == ModelView.hiddenTitle { return "a window with a hidden title" }
        if title.isEmpty || title.trimmed.lowercased() == app.trimmed.lowercased() { return "a window" }
        let q = ModelView.shown(title, ModelView.titleQuoteChars).text
        return q == ModelView.healthNote || q == ModelView.financeNote ? "a window with a hidden title" : q == ModelView.aiNote ? "a window titled with " + ModelView.aiNote : q
    }
    /// notes-quality: where it was: the site's name in a browser ("Google Docs", "YouTube"), else its host, else the app.
    func placeName() -> String {
        let friendly = ModelView.friendlySite(site)
        if !friendly.isEmpty { return friendly }
        return site.isEmpty ? (app.isEmpty ? "Mac" : app) : site
    }
    /// notes-quality: the item's name as the view shows it (quoted, cleaned title), or "" when it only repeats the app or site.
    func shownName() -> String {
        if title == ModelView.hiddenTitle { return "a window with a hidden title" }
        let t = title.trimmed.lowercased()
        if t.isEmpty || t == app.trimmed.lowercased() || t == site.lowercased() || t == placeName().lowercased() { return "" }
        let q = ModelView.shown(title, ModelView.titleQuoteChars).text
        return q == ModelView.healthNote || q == ModelView.financeNote ? "a window with a hidden title" : q == ModelView.aiNote ? "a window titled with " + ModelView.aiNote : q
    }
    /// notes-quality (prompt8): what was in front, for how long, and whether it was in use, with counts only:
    /// "Q3 investor update" in Google Docs, about 23 minutes, in use (clicked 9 times). Never "open".
    func factsLine() -> String {
        let name = shownName()
        var s = name.isEmpty ? placeName() : name + " in " + placeName()
        // fix/sx-all round 2: the person's own pull request is never "Reviewed".
        if ownPR == true { s += ", your own pull request" } else if ownPR == false { s += ", someone else's pull request" }
        if case let took = ModelView.about(seconds), !took.isEmpty { s += ", " + took }
        var use: [String] = []
        if let c = counts["click"], c > 0 { use.append("clicked " + (c == 1 ? "once" : "\(c) times")) }
        if inUse() || !use.isEmpty { s += ", in use" + (use.isEmpty ? "" : " (" + use.joined(separator: ", ") + ")") }
        return s
    }
    func body() -> String {
        if requestSession { return intentBody() }
        if !parts.isEmpty { return foldedBody() }
        let use = inUse() ? ", in use" : ""
        let hasText = !(text ?? "").isEmpty
        switch kind {
        case .window, .tab, .mechonly:
            return factsLine()
        case .other:
            return "other activity"
        case .typed:
            if !label().isEmpty { return intentBody() }
            var b = hasText ? "typed " + ModelView.shown(text!).text : "typed text (not captured)"
            if !typedPlace().isEmpty { b += " in " + typedPlace() }
            if !site.isEmpty { b += " on " + site }
            if unverified() { b += "; a message appeared, sending not confirmed" }
            return b
        case .search:
            return "search results for " + ModelView.shown(text ?? "", ModelView.titleQuoteChars).text + use
        case .screentext:
            return "text on screen, not necessarily typed by you" + (hasText ? ": " + ModelView.shown(text!).text : "")
        case .idle:
            return "idle"
        case .sent:
            let n = counts["sent"] ?? 1
            return n == 1 ? "SENT, the app confirmed a message was sent" : "SENT, the app confirmed messages were sent " + ModelView.times(n)
        case .unverified:
            return "a message appeared; sending not confirmed"
        case .unavailable:
            return "a browser record, details unavailable"
        case .report, .note, .request, .plan:
            var b = ModelView.tags[kind]! + " " + (hasText ? ModelView.shown(text!).text : "(text not captured)")
            if kind == .note, !plainTitle().isEmpty { b += " about \"" + plainTitle() + "\"" }
            return b
        }
    }
    /// One line for several items of one app folded together.
    func foldedBody() -> String {
        let most = ModelView.foldNames
        let use = parts.contains { $0.inUse() } ? ", in use" : ""
        switch kind {
        case .window, .tab:
            var labels: [String] = [], weight: [String: Int] = [:], unnamed = false
            for x in parts {
                var label = kind == .window ? x.windowName() : x.site
                if kind == .window, !label.hasPrefix("\"") { label = "" }
                if label.isEmpty { unnamed = true; continue }
                if weight[label] == nil { labels.append(label); weight[label] = 0 }
                weight[label]! += x.actions.count
            }
            let top = Set(labels.enumerated().sorted { weight[$0.element]! != weight[$1.element]! ? weight[$0.element]! > weight[$1.element]! : $0.offset < $1.offset }
                .prefix(most).map(\.element))
            var chosen = labels.filter { top.contains($0) }
            let other = kind == .window ? "other windows" : "other websites"
            if !chosen.isEmpty, unnamed || labels.count > chosen.count { chosen.append(other) }
            let place = chosen.isEmpty ? (kind == .window ? "several windows" : "several websites") : ModelView.joinAnd(chosen)
            let took = ModelView.about(seconds)
            return place + (took.isEmpty ? "" : ", " + took) + use
        case .mechonly:
            let took = ModelView.about(seconds)
            return app + (took.isEmpty ? "" : ", " + took) + use
        case .other:
            return "other activity"
        default:
            var said: [String] = []
            let limit = run ? ModelView.quoteChars : ModelView.foldQuoteChars
            for x in parts {
                let q = (x.text ?? "").isEmpty ? "text (not captured)" : ModelView.shown(x.text!, limit).text
                if !said.contains(q) { said.append(q) }
            }
            let list = said.count <= most ? ModelView.joinAnd(said) : "\(said[0]), \(said[1]) and more, ending with \(said[said.count - 1])"
            switch kind {
            case .typed:
                var b = "typed " + list
                if run {
                    var places: [String] = []
                    for x in parts where !x.typedPlace().isEmpty && !places.contains(x.typedPlace()) { places.append(x.typedPlace()) }
                    if !places.isEmpty { b += " in " + ModelView.joinAnd(Array(places.prefix(most)) + (places.count > most ? ["other windows"] : [])) }
                }
                var sites: [String] = []
                for x in parts where !x.site.isEmpty && !sites.contains(x.site) { sites.append(x.site) }
                if !sites.isEmpty { b += " on " + ModelView.joinAnd(sites) }
                if run, case let took = ModelView.about(span()), !took.isEmpty { b += " over " + took }
                if unverified() || parts.contains(where: { $0.unverified() }) { b += "; messages appeared, sending not confirmed" }
                else if let last = parts.last, !last.label().isEmpty, !last.ending().isEmpty { b += "; " + last.ending() }
                return b
            case .search: return "search results for " + list + use
            case .screentext: return "text on screen, not necessarily typed by you: " + list
            default: return (ModelView.tags[kind] ?? kind.rawValue) + " " + list
            }
        }
    }
}

/// The deterministic user message for one moment or day: `NOTE: moment|day`, `ITEMS:`, then `iN. App: body` lines.
/// Items and hidden idle time partition the actions; items are ordered by their first action.
public struct ModelView: Sendable {
    public enum Scope: String, Sendable { case moment, day }
    public let scope: Scope
    public let items: [ModelItem]
    /// Idle time: never shown to the model, never cited, never written about.
    public let hidden: [ModelItem]
    public let text: String
    let byAlias: [String: Int]
    let owner: [String: Int]

    public static let maxActions = 400, maxItems = 40, maxViewBytes = 16000, maxNext = 3
    static let typedQuoteChars = 1600
    static let quoteChars = 240, titleQuoteChars = 160, foldQuoteChars = 80, foldNames = 3
    static let aiNote = "text addressed to AI tools"
    static let healthNote = "a personal health note (details hidden)"
    static let financeNote = "a personal finance note (details hidden)"
    static let hiddenTitle = "[sensitive title omitted]"
    /// fix/app-coverage: window titles that name no conversation, email or document yet (Mail's compose window before a
    /// subject, a new document, Messages' own title). An `in` part made of one reads as a subject ("Emailed about New
    /// Message"), so a typed item's place leaves it out.
    static func placeholderTitle(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["new message", "untitled", "messages", "new document", "new note"].contains(t)
            || t.range(of: #"^untitled( \d+)?( — edited| - edited)?$"#, options: .regularExpression) != nil
    }
    static let correctionAction = "User correction (not observed): "
    static let correctionAppended = "\nUser correction to related note (not observed evidence): "
    static let tags: [ModelItem.Kind: String] = [.report: "REPORT", .note: "YOUR NOTE", .request: "YOU ASKED", .plan: "YOUR PLAN"]
    /// Where typed text is a message someone could send: the view says "sending not confirmed" only there.
    static let messageApps: Set<String> = ["Mail", "Messages", "Slack", "LINE", "WhatsApp", "Discord", "Microsoft Teams", "Teams", "Telegram", "Signal", "Outlook",
                                           "Microsoft Outlook", "Messenger", "Spark", "Superhuman", "Airmail", "Mimestream", "Zoom"]
    static let messageSite = Pattern(#"(?i)^(?:mail\.google\.com|outlook\.(?:live|office|office365)\.com|(?:[a-z0-9-]+\.)*slack\.com|web\.whatsapp\.com|discord\.com|teams\.(?:microsoft|live)\.com|(?:www\.)?messenger\.com|web\.telegram\.org|mail\.yahoo\.com|mail\.proton\.me)$"#)

    // MARK: prompt7 surfaces, send facts, leads (spec §3, §5, §6)

    static let sendSurfaces: Set<String> = ["ai", "aiTool", "email", "text", "chat", "social", "search", "form"]
    static let surfaceLabel = ["ai": "AI app", "aiTool": "AI tool", "email": "email", "text": "text", "chat": "chat", "social": "social",
                               "search": "search", "form": "form", "code": "code", "writing": "writing"]
    static let aiApps: Set<String> = ["Claude", "ChatGPT", "Codex"]
    static let aiSite = Pattern(#"(?i)^(?:claude\.ai|chatgpt\.com|chat\.openai\.com)$"#)
    static let emailApps: Set<String> = ["Mail", "Outlook", "Microsoft Outlook", "Spark", "Superhuman", "Airmail", "Mimestream"]
    static let emailSite = Pattern(#"(?i)^(?:mail\.google\.com|outlook\.(?:live|office|office365)\.com|outlook\.cloud\.microsoft|(?:www\.)?icloud\.com|mail\.yahoo\.com|mail\.proton\.me)$"#)
    static let textApps: Set<String> = ["Messages"]
    static let chatApps: Set<String> = ["Slack", "LINE", "WhatsApp", "Discord", "Microsoft Teams", "Teams", "Telegram", "Signal", "Messenger", "Zoom"]
    static let chatSite = Pattern(#"(?i)^(?:(?:[a-z0-9-]+\.)*slack\.com|web\.whatsapp\.com|discord\.com|teams\.(?:microsoft|live)\.com|(?:www\.)?messenger\.com|web\.telegram\.org)$"#)
    static let socialSite = Pattern(#"(?i)^(?:www\.)?linkedin\.com$"#)
    static let endingName = ["return": "Return", "commandReturn": "Command-Return", "mailSend": "Command-Shift-D", "button": "the Send button"]
    static let approvalCue = Pattern(#"(?i)\b(?:permission|approve|approved|go ahead|it is fine|it's fine|that's fine|that is fine|ok to|okay to|sounds good|ship it|yes,? do it|lgtm|i agree|agreed)\b"#)
    static let agreeCue = Pattern(#"(?i)\b(?:i agree|agreed)\b"#)
    static let engines = ["google": "Google", "bing": "Bing", "duckduckgo": "DuckDuckGo", "yahoo": "Yahoo", "ecosia": "Ecosia", "kagi": "Kagi", "perplexity": "Perplexity", "brave": "Brave"]
    static let placeWord = Pattern(#"[^\W\d_][\w'’-]*"#)

    /// The surface of a row sealed without facts (typed-unit/v2), from its app or site.
    static func derivedSurface(_ app: String, _ site: String) -> String? {
        if !site.isEmpty ? aiSite.search(site) : aiApps.contains(app) { return "ai" }
        if !site.isEmpty ? emailSite.search(site) : emailApps.contains(app) { return "email" }
        if site.isEmpty && textApps.contains(app) { return "text" }
        if !site.isEmpty ? chatSite.search(site) : chatApps.contains(app) { return "chat" }
        if !site.isEmpty && socialSite.search(site) { return "social" }
        return nil
    }
    /// The search engine's name from its host ("www.google.com" -> "Google"), or the app (Spotlight).
    static func engine(_ site: String, _ app: String) -> String {
        if site.isEmpty { return app }
        var host = site.lowercased(); if host.hasPrefix("www.") { host.removeFirst(4) }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for p in parts { if let e = engines[p] { return e } }
        guard let first = parts.first, let c = first.first else { return "" }
        return String(c).uppercased() + first.dropFirst().lowercased()
    }
    /// Python `str.strip('"')`.
    static func stripQuotes(_ s: String) -> String {
        var t = Substring(s)
        while t.first == "\"" { t = t.dropFirst() }
        while t.last == "\"" { t = t.dropLast() }
        return String(t)
    }
    static let foldBackground: Set<ModelItem.Kind> = [.window, .tab, .mechonly, .other]
    static let foldContent: Set<ModelItem.Kind> = [.typed, .search, .screentext, .report, .note, .request, .plan]

    public func item(_ alias: String) -> ModelItem? { byAlias[alias].map { items[$0] } }
    /// The item that owns an action ID (nil for hidden idle time).
    public func owner(of actionID: String) -> ModelItem? { owner[actionID].map { items[$0] } }

    /// Builds the view. Long scopes fold per app (background items first, then content) instead of waiting;
    /// throws `WriterFailure.capacity` above 400 actions, or when 40 items or 16,000 UTF-8 bytes are still exceeded after folding.
    /// `appNames` maps bundle IDs to installed apps' names.
    public init(request: CanonicalNoteRequest, actions: [NoteAction], appNames: [String: String] = [:], localIntentSessions: Bool = false) throws {
        let acts = actions.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
        guard acts.count <= Self.maxActions else { throw WriterFailure.capacity }
        var items: [ModelItem] = [], ctx: [String: Int] = [:], keyed: [String: Int] = [:], runs: [String: Int] = [:], units: [String: Int] = [:], prevApp: String?
        func key(_ parts: String...) -> String { parts.joined(separator: "\u{1f}") }
        for a in acts {
            let app = Self.appName(a.app, appNames)
            let (kind, text) = Self.classify(a)
            // sat5: typing whose words aren't shown, in one app with nothing else in between (only its windows, tabs, clicks
            // and keys), is one run: "Typed three drafts in Claude" was the view's count, not what the person did. Another
            // app or any other item ends it. Typed text with its words stays one item per draft: the words say what it was.
            if app != prevApp || !["window", "tab", "mech", "typed"].contains(kind) { runs = [:]; units = [:] }
            prevApp = app
            switch kind {
            case "window", "tab":
                let k = kind == "window" ? key(kind, app, a.title) : key(kind, app, a.site.isEmpty ? a.title : a.site)
                let index: Int
                if let found = keyed[k] { index = found } else {
                    items.append(ModelItem(kind == "window" ? .window : .tab, app: app, title: Self.cleanTitle(a.title, app: app, site: a.site), site: a.site))
                    index = items.count - 1; keyed[k] = index
                    items[index].prAuthor = Self.prAuthor(a.title)
                    if kind == "window", !a.title.isEmpty { ctx[key(app, a.title)] = index }
                }
                items[index].add(a, "open")
            case "mech", "unverified":
                let count = kind == "mech" ? text! : "unverified"
                var latest: Int?
                for (i, it) in items.enumerated() where it.app == app && Self.attachable.contains(it.kind) {
                    if latest == nil || it.lastAt > items[latest!].lastAt { latest = i }
                }
                let w = a.title.isEmpty ? nil : ctx[key(app, a.title)]
                let target: Int
                if let l = latest, items[l].kind == .typed, w == nil || items[l].lastAt >= items[w!].lastAt { target = l }
                else if let w { target = w }
                else if let l = latest { target = l }
                else if kind == "unverified" { items.append(ModelItem(.unverified, app: app)); target = items.count - 1 }
                else {
                    items.append(ModelItem(.mechonly, app: app, title: Self.cleanTitle(a.title, app: app, site: a.site))); target = items.count - 1
                    if !a.title.isEmpty { ctx[key(app, a.title)] = target }
                }
                items[target].add(a, items[target].kind == .unverified ? nil : count)
            case "idle", "sent":
                let k = key(kind, kind == "idle" ? "" : app)
                let index: Int
                if let found = keyed[k] { index = found } else {
                    items.append(ModelItem(kind == "idle" ? .idle : .sent, app: kind == "idle" ? "Mac" : app))
                    index = items.count - 1; keyed[k] = index
                }
                items[index].add(a, kind)
            default:
                var it = ModelItem(ModelItem.Kind(rawValue: kind)!, app: app, title: Self.cleanTitle(a.title, app: app, site: a.site), text: text, site: a.site)
                it.add(a, nil)
                if kind == "typed" {
                    it.facts = SendFacts(a); it.words = (text ?? "").isEmpty ? nil : text
                    it.rowTitle = it.title
                    if let t = text, !t.isEmpty { it.guards = [Guarded(words: t, field: a.field ?? "", nameSource: t)] }
                }
                // prompt7 (N11): the pieces of one typing unit (same runID, split by a pause or size) are one item with all its
                // words; the last piece's seal says whether it was sent.
                if kind == "typed", let t = text, !t.isEmpty, let rid = it.facts.value(.runID) {
                    let k = key(app, rid)
                    if let u = units[k], items[u].site == it.site {
                        // claude/messages-1003: a Messages unit split mid-word ("wanna me" + "et us there?") reads as typed.
                        items[u].text = it.surface() == "text" ? Self.stitch(items[u].text ?? "", t) : (items[u].text ?? "") + " " + t; items[u].words = items[u].text
                        items[u].actions += it.actions
                        items[u].lastAt = max(items[u].lastAt, it.lastAt)
                        items[u].facts = items[u].facts.merged(it.facts)
                        if items[u].title.isEmpty { items[u].title = it.title }
                        // Core checks each piece and the whole run; names come from the whole run.
                        let whole = items[u].text ?? ""
                        items[u].guards = items[u].guards.map { Guarded(words: $0.words, field: $0.field, nameSource: whole) }
                            + it.guards.map { Guarded(words: $0.words, field: $0.field, nameSource: whole) } + [Guarded(words: whole, field: "", nameSource: whole)]
                        continue
                    }
                    units[k] = items.count
                }
                if kind == "typed", (text ?? "").isEmpty {
                    // fix/summary-sends QF-13: word-less rows of one app and site join one run, but a row sealed with a
                    // detected send key joins only other such rows. A run takes its facts from its last part (`fact`), so a
                    // joined draft after a send hid the send ("sending unknown"), and a send after drafts claimed the
                    // drafts were sent. Now the sends are their own item (sent, label submitted) and drafts stay drafts.
                    let k = key(app, it.site, it.facts.value(.send) == "detected" ? "send-key" : "")
                    if let run = runs[k] { items[run].join(it); continue }
                    runs[k] = items.count
                }
                items.append(it)
            }
        }
        // Idle proves nothing worth a bullet: the model never sees it and no bullet may cite it.
        var hidden = items.filter { $0.kind == .idle }
        let scope: Scope = request.targetKind == "day" ? .day : .moment
        // notes-quality: an email's To and Subject units join the email; sends to one person or place in a row are one
        // item; windows of an app (a site, in a browser) where something was typed or sent join that item.
        var visible = Self.mergeSends(Self.foldFields(items.filter { $0.kind != .idle }))
        // claude/messages-1003 (owner): Messages reads as one item per conversation (the pieces of each sent text stitched,
        // every text sent to one person together, a draft left after them on the same line). The rows it folds away are
        // never shown or cited on their own.
        let conversations = Self.messagesConversations(visible)
        visible = conversations.items; hidden += conversations.absorbed
        // claude/summary-1003 (owner): lines typed in a terminal running an AI coding tool are prompts to it, for every writer.
        visible = Self.tagTerminalTools(visible)
        let prompts = Self.joinTerminalPrompts(visible)
        visible = prompts.items; hidden += prompts.absorbed
        if localIntentSessions, scope == .moment {
            visible = Self.foldAIRequestSessions(visible)
        }
        visible = Self.foldWindows(Self.absorbNext(visible, scope), scope)
        Self.measure(&visible, acts)
        // fix/sx-all round 2: whose pull request it is (the request's `selfNames`: the person's own account names) and
        // whether typing there would have been recorded (every one of its own actions says so).
        let selfNames = Set((request.selfNames ?? []).map { $0.lowercased() }.filter { !$0.isEmpty })
        for i in visible.indices {
            if let author = visible[i].prAuthor?.lowercased(), !selfNames.isEmpty { visible[i].ownPR = selfNames.contains(author) }
            let own = visible[i].actions.filter { $0.kind != "keyboard.text_input" }
            visible[i].typingRecordable = !own.isEmpty && own.allSatisfy { $0.typing == "on" }
        }
        var numbered = Self.number(visible, scope), text = Self.render(scope, numbered)
        for kinds in [Self.foldBackground, Self.foldContent] {
            if numbered.count <= Self.maxItems && text.utf8.count <= Self.maxViewBytes { break }
            visible = Self.fold(visible, kinds); numbered = Self.number(visible, scope); text = Self.render(scope, numbered)
        }
        guard numbered.count <= Self.maxItems, text.utf8.count <= Self.maxViewBytes else { throw WriterFailure.capacity }
        guard scope == .day || numbered.filter({$0.kind == .typed}).count<=CanonicalGrounding.maxBullets else {throw WriterFailure.capacity}
        self.scope = scope; self.items = numbered; self.hidden = hidden; self.text = text
        byAlias = Dictionary(uniqueKeysWithValues: numbered.enumerated().map { ($1.alias, $0) })
        owner = Dictionary(numbered.enumerated().flatMap { i, it in it.actions.map { ($0.id, i) } }, uniquingKeysWith: { first, _ in first })
    }

    /// claude/summary-1003 (owner): a line typed in a terminal (Ghostty, Terminal, iTerm2 ...) whose window title shows an AI
    /// coding tool (`CanonicalGrounding.terminalTool(title:)`: Claude Code's "✳ <topic>", "harborline — claude", "codex"),
    /// or that follows a line starting one in the same app ("claude", then prompts until a known shell command), is a
    /// prompt to that tool: surface "aiTool", to the tool ("Asked Claude Code ..."). The line that starts the tool and
    /// shell commands stay commands.
    static func tagTerminalTools(_ items: [ModelItem]) -> [ModelItem] {
        var out = items, started: [String: String] = [:]
        // claude/cc-label-1003 (owner 10/03): Claude Code names itself in its tab title only by a glyph, and reads drop the
        // glyph (core keeps the tool it named as the action's `tool`; "" a bare spinner). A prompt typed while the title
        // was plain or only spinning named no tool, so the session's prompts read as shell lines. A window keeps its tool
        // while its title stays the same: any row of the moment with that app and title names it for the rest; a spinner
        // (or a prompt-shaped line in a window that is no shell's) takes the one tool the moment names in that app.
        func key(_ app: String, _ title: String) -> String {
            app + "\u{1f}" + CanonicalGrounding.stripStatusGlyph(title).lowercased()
        }
        var titled: [String: String] = [:], named: [String: Set<String>] = [:], spinning = Set<String>()
        for it in items where CanonicalGrounding.terminalApps.contains(it.app) {
            for a in it.actions {
                if let tool = (a.tool ?? "").isEmpty ? CanonicalGrounding.terminalTool(title: a.title) : a.tool {
                    if titled[key(it.app, a.title)] == nil { titled[key(it.app, a.title)] = tool }
                    named[it.app, default: []].insert(tool)
                } else if a.tool == "" { spinning.insert(key(it.app, a.title)) }
            }
        }
        for i in out.indices where out[i].kind == .typed && out[i].parts.isEmpty && CanonicalGrounding.terminalApps.contains(out[i].app)
            && ["", "text", "code", "terminal"].contains(out[i].facts.surface ?? "") {
            let app = out[i].app
            if let tool = CanonicalGrounding.toolStarted(out[i]) { started[app] = tool; continue }
            let command = CanonicalGrounding.terminalCommand(out[i])
            let keys = out[i].actions.map { key(app, $0.title) } + [key(app, out[i].title)]
            let only = named[app].flatMap { $0.count == 1 ? $0.first : nil }
            var tool = CanonicalGrounding.terminalTool(out[i]) ?? keys.lazy.compactMap { titled[$0] }.first
            if tool == nil, keys.contains(where: spinning.contains) { tool = only }
            if tool == nil, CanonicalGrounding.promptShaped(out[i].text ?? ""),
               !out[i].actions.contains(where: { CanonicalGrounding.shellTitle($0.title) }) { tool = only }
            if tool == nil, command == nil { tool = started[app] }
            if let tool {
                out[i].facts.surface = "aiTool"
                out[i].facts.to = tool
            } else if command != nil { started[app] = nil }
        }
        return out
    }
    /// claude/cc-label-1003 (owner 10/03): one prompt typed into an AI tool in a terminal is saved in pieces whenever
    /// typing is cut (an app switch, a click), and only the last piece carries the Return, so the earlier pieces read as
    /// drafts ("Drafted a message to Claude Code" for a prompt that was sent). Unsent pieces typed right before a sent
    /// prompt to the same tool in the same app (only that app's windows, clicks and keys between) are that prompt's start:
    /// they join it, in order. Pieces never followed by a send stay drafts. The joined rows are `absorbed`: kept by the
    /// note's snapshot, never shown or cited on their own (as Messages pieces are).
    static func joinTerminalPrompts(_ items: [ModelItem]) -> (items: [ModelItem], absorbed: [ModelItem]) {
        func prompt(_ it: ModelItem) -> Bool {
            it.kind == .typed && it.parts.isEmpty && it.surface() == "aiTool" && CanonicalGrounding.terminalApps.contains(it.app)
                && !(it.text ?? "").isEmpty && !it.unverified()
        }
        var out: [ModelItem] = [], absorbed: [ModelItem] = [], pending: [Int] = []
        for it in items {
            guard prompt(it) else {
                // Another app's typing, or anything else typed, ends the pieces; this app's windows, clicks and keys don't.
                if it.kind == .typed || (!pending.isEmpty && it.app != out[pending[0]].app && !ModelView.background.contains(it.kind)) { pending = [] }
                out.append(it); continue
            }
            if let p = pending.first, out[p].app != it.app || out[p].toName() != it.toName() { pending = [] }
            if it.detected() {
                if !pending.isEmpty {
                    let earlier = pending.map { out[$0] }
                    var whole = it
                    let text = (earlier.map { $0.text ?? "" } + [it.text ?? ""]).map { $0.trimmed }.filter { !$0.isEmpty }.joined(separator: " ")
                    whole.text = text; whole.words = text
                    whole.guards = earlier.flatMap(\.guards) + it.guards + [Guarded(words: text, field: it.fact(.field) ?? "", nameSource: text)]
                    absorbed += earlier
                    for p in pending.sorted(by: >) { out.remove(at: p) }
                    out.append(whole)
                } else { out.append(it) }
                pending = []
                continue
            }
            pending.append(out.count); out.append(it)
        }
        return (out, absorbed)
    }
    /// Only own AI requests with an explicit tool/surface/run/field and identical context/state
    /// are consolidated for summary capacity. Messages/email and ordinary terminal commands never join.
    static func foldAIRequestSessions(_ items:[ModelItem]) -> [ModelItem] {
        var out:[ModelItem]=[], lastKey:String?, lastIndex:Int?
        for item in items {
            // claude/cc-label-1003: an AI tool's own terminal window, its clicks and keys between two prompts don't end the
            // session (a window row came between each prompt, so a session was one prompt per item).
            if let index=lastIndex, out[index].surface() == "aiTool", CanonicalGrounding.terminalApps.contains(out[index].app),
               item.app == out[index].app, ModelView.background.contains(item.kind) {out.append(item);continue}
            guard item.kind == .typed, ["ai","aiTool"].contains(item.surface() ?? ""),
                  !item.toName().isEmpty, !(item.text ?? "").isEmpty, item.parts.isEmpty else {
                // A different action/context ends a session. Separate chats/email never join.
                lastKey=nil;lastIndex=nil;out.append(item);continue
            }
            // claude/summary-1003: a coding tool's window title is its status ("✳ topic", "⠐ topic") and changes with it.
            let place=item.surface() == "aiTool" && CanonicalGrounding.terminalApps.contains(item.app) ? "" : item.title
            let key=[item.app,item.site,place,item.toName(),item.surface() ?? "",item.fact(.field) ?? "",item.detected() ? "submitted":"draft"].joined(separator:"\u{1f}")
            if key == lastKey, let index=lastIndex {
                if !out[index].requestSession {out[index].parts=[out[index]];out[index].requestSession=true}
                out[index].parts.append(item)
                out[index].actions += item.actions
                out[index].guards += item.guards
                out[index].text=(out[index].text ?? "")+"\n"+(item.text ?? "")
                out[index].words=out[index].text
                out[index].lastAt=max(out[index].lastAt,item.lastAt)
                for (kind,count) in item.counts {out[index].counts[kind,default:0]+=count}
            } else {lastKey=key;lastIndex=out.count;out.append(item)}
        }
        return out
    }
    /// Folds items of the same app and kind (typed: app and site) into one, keeping first-seen order; a group of one stays as it was.
    static func fold(_ items: [ModelItem], _ kinds: Set<ModelItem.Kind>) -> [ModelItem] {
        var out: [ModelItem] = [], groups: [String: Int] = [:], members: [Int: [ModelItem]] = [:]
        for it in items {
            // Capacity folding must not turn separate drafts/messages into a
            // shared source of context. Same-run pieces already joined above.
            guard kinds.contains(it.kind), it.kind != .typed else { out.append(it); continue }
            // fix/summary-sends QF-13: typed items sent with a detected send key fold only with each other (a group's facts
            // are its last part's).
            let k = [it.kind.rawValue, it.app, it.kind == .typed ? it.site : "", it.kind == .typed && it.fact(.send) == "detected" ? "send-key" : ""].joined(separator: "\u{1f}")
            let g: Int
            if let found = groups[k] { g = found } else {
                out.append(ModelItem(it.kind, app: it.app, title: it.title, text: it.text, site: it.site)); g = out.count - 1; groups[k] = g
            }
            members[g, default: []].append(it)
            out[g].parts += it.run ? it.parts : [it]   // a typing run folds as its drafts
            out[g].actions += it.actions
            out[g].lastAt = max(out[g].lastAt, it.lastAt)
            out[g].seconds += it.seconds
            out[g].guards += it.guards
            for (c, n) in it.counts { out[g].counts[c, default: 0] += n }
        }
        for g in groups.values {
            out[g].actions.sort { ($0.at, $0.id) < ($1.at, $1.id) }
            if members[g]!.count == 1 { out[g] = members[g]![0] }   // nothing folded
        }
        return out
    }
    /// Separate fields have no proven compose identity. Shared app/site and time
    /// cannot attach a recipient or subject to another email's body.
    static func foldFields(_ items: [ModelItem]) -> [ModelItem] { items }
    /// claude/messages-1003: two pieces of one Messages text, joined as typed. A later piece that already holds the earlier
    /// one (the field's whole value read at Return) stands for both; otherwise nothing is inserted between them: a unit
    /// sealed mid-word ("wanna me" + "et us there?") reads "wanna meet us there?".
    static func stitch(_ a: String, _ b: String) -> String {
        let head = a.trimmed
        if head.isEmpty { return b }
        if b.hasPrefix(a) || b.trimmed.hasPrefix(head) { return b }
        return a + b
    }
    /// claude/messages-1003 (owner, 10/3): Messages, one item per conversation. A Messages conversation is its read
    /// name (the unit's `to`, from the window title): code never guesses one, so texts with no name read stay apart.
    /// 1. Unsent pieces typed right before a send in the same conversation (no other typing in between) are that text's
    ///    start, sealed early by a pause or a focus change: they join it, as typed (`stitch`).
    /// 2. Every text sent to one named conversation is one item, its texts in order (`pieces`): one bullet each.
    /// 3. A draft in a named conversation that also has sends joins it as `unsent`: no draft line beside the sends.
    /// Rows joined in 1 and 3 are returned as `absorbed`: kept by the note's snapshot, never shown or cited on their own.
    static func messagesConversations(_ items: [ModelItem]) -> (items: [ModelItem], absorbed: [ModelItem]) {
        func isText(_ it: ModelItem) -> Bool {
            it.kind == .typed && it.parts.isEmpty && it.surface() == "text" && !(it.text ?? "").isEmpty && !it.unverified() && it.pieces.isEmpty
        }
        // claude/messages2-1003: a conversation known by its number or address is one conversation too.
        func key(_ it: ModelItem) -> String { [it.app, it.site, it.conversation().lowercased()].joined(separator: "\u{1f}") }
        var stitched: [ModelItem] = [], absorbed: [ModelItem] = [], pending: [Int] = []
        for it in items {
            guard isText(it) else {
                // Any other typing ends a text's pieces; windows, clicks and keys don't.
                if it.kind == .typed { pending = [] }
                stitched.append(it); continue
            }
            if let p = pending.first, key(stitched[p]) != key(it) { pending = [] }
            // claude/messages2-1003 (owner 10/3): a text sealed by Return is a whole text even when no send was confirmed;
            // it never starts the next one ("pretty good" + "home alone" are two texts).
            if !it.detected(), it.fact(.seal) == "submit" { pending = []; stitched.append(it); continue }
            if it.detected() {
                if !pending.isEmpty {
                    let earlier = pending.map { stitched[$0] }
                    var whole = it
                    let text = stitch(earlier.reduce("") { stitch($0, $1.text ?? "") }, it.text ?? "")
                    whole.text = text; whole.words = text
                    whole.guards = earlier.flatMap(\.guards) + it.guards + [Guarded(words: text, field: it.fact(.field) ?? "", nameSource: text)]
                    absorbed += earlier
                    for p in pending.sorted(by: >) { stitched.remove(at: p) }
                    stitched.append(whole)
                } else { stitched.append(it) }
                pending = []
                continue
            }
            pending.append(stitched.count); stitched.append(it)
        }
        // 2. One item per named conversation with sends.
        var out: [ModelItem] = [], conversation: [String: Int] = [:]
        for it in stitched {
            guard isText(it), it.detected(), !it.conversation().isEmpty else { out.append(it); continue }
            if let c = conversation[key(it)] {
                if out[c].pieces.isEmpty { out[c].pieces = [out[c].text ?? ""] }
                out[c].pieces.append(it.text ?? "")
                out[c].actions = (out[c].actions + it.actions).sorted { ($0.at, $0.id) < ($1.at, $1.id) }
                out[c].lastAt = max(out[c].lastAt, it.lastAt)
                out[c].facts = out[c].facts.merged(it.facts)
                out[c].guards += it.guards
                for (k, n) in it.counts { out[c].counts[k, default: 0] += n }
                out[c].text = out[c].pieces.joined(separator: "\n"); out[c].words = out[c].text
            } else { conversation[key(it)] = out.count; out.append(it) }
        }
        // 3. A draft in a named conversation with sends goes on that conversation's line.
        var drop = Set<Int>()
        for (i, it) in out.enumerated() where isText(it) && !it.detected() && !it.conversation().isEmpty {
            guard let c = conversation[key(it)] else { continue }
            out[c].unsent.append(it.text ?? "")
            out[c].guards += it.guards
            absorbed.append(it); drop.insert(i)
        }
        return (out.indices.filter { !drop.contains($0) }.map { out[$0] }, absorbed)
    }
    /// Same-run pieces already joined above with all source IDs. A shared
    /// recipient, surface or wording cannot establish that other messages are
    /// one action. UI conversation grouping remains a separate projection.
    static func mergeSends(_ items: [ModelItem]) -> [ModelItem] { items }
    /// notes-quality (d): a window, tab or the app in use, of an app (a site, in a browser) where something was typed,
    /// searched or sent, joins that item (the nearest in time): the view shows what was done there, not that it was
    /// open. A window typed in that has no name of its own (a web row titled by its host) takes the window's name
    /// ("Re: Q3 numbers"). NEXT windows stay: they are what came next.
    static func foldWindows(_ items: [ModelItem], _ scope: Scope) -> [ModelItem] {
        var items = items, drop = Set<Int>()
        let nexts = Set(nextWindows(items, afterLastSend(items, scope)))
        let hosts = items.indices.filter { [.typed, .search].contains(items[$0].kind) }
        for i in items.indices where [.window, .tab, .mechonly].contains(items[i].kind) && !nexts.contains(i) {
            let w = items[i], at = seconds(w.actions[0].at)
            let near = hosts.filter { h in items[h].app == w.app && items[h].site == w.site }
                .min { abs(seconds(items[$0].actions[0].at) - at) < abs(seconds(items[$1].actions[0].at) - at) }
            guard let h = near else { continue }
            items[h].actions = (items[h].actions + w.actions).sorted { ($0.at, $0.id) < ($1.at, $1.id) }
            items[h].lastAt = max(items[h].lastAt, w.lastAt)
            for (c, n) in w.counts where c != "open" { items[h].counts[c, default: 0] += n }
            let own = items[h].title.trimmed.lowercased()
            if !w.title.isEmpty, own.isEmpty || own == items[h].site.lowercased() || own == items[h].app.lowercased() { items[h].title = w.title }
            drop.insert(i)
        }
        return items.indices.filter { !drop.contains($0) }.map { items[$0] }
    }
    /// notes-quality: each item's focused seconds. An action counts until the next action of the scope, at most 5
    /// minutes (window samples come about every 2 minutes); the last one 30 seconds; idle time never.
    static func measure(_ items: inout [ModelItem], _ acts: [NoteAction]) {
        let times = acts.map { seconds($0.at) }
        var dwell = [String: Double]()
        for (i, a) in acts.enumerated() {
            if a.kind == "idle" || a.state == "idle" { dwell[a.id] = 0; continue }
            dwell[a.id] = i + 1 < acts.count ? min(max(0, times[i + 1] - times[i]), 300) : 30
        }
        for i in items.indices { items[i].seconds = items[i].actions.reduce(0) { $0 + (dwell[$1.id] ?? 0) } }
    }

    // MARK: notes-quality names

    static let friendlyHosts: [String: String] = [
        "docs.google.com": "Google Docs", "mail.google.com": "Gmail", "drive.google.com": "Google Drive", "calendar.google.com": "Google Calendar",
        "meet.google.com": "Google Meet", "github.com": "GitHub", "youtube.com": "YouTube", "m.youtube.com": "YouTube", "youtu.be": "YouTube",
        "x.com": "X", "twitter.com": "X", "app.slack.com": "Slack", "linkedin.com": "LinkedIn", "notion.so": "Notion", "figma.com": "Figma",
        "claude.ai": "Claude", "chatgpt.com": "ChatGPT", "chat.openai.com": "ChatGPT", "netflix.com": "Netflix", "twitch.tv": "Twitch",
        "vimeo.com": "Vimeo", "reddit.com": "Reddit", "news.ycombinator.com": "Hacker News", "web.whatsapp.com": "WhatsApp",
        "discord.com": "Discord", "outlook.office.com": "Outlook", "outlook.live.com": "Outlook", "teams.microsoft.com": "Microsoft Teams"]
    static func host(_ site: String) -> String {
        var h = site.lowercased(); if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }
    /// "Google Docs" for docs.google.com, "X" for x.com; "" for a site with no known name.
    static func friendlySite(_ site: String) -> String { friendlyHosts[host(site)] ?? "" }
    /// A person's name as a Messages window shows it ("Maya", "Sam Lee"), or nil (a group's name, a number, "Messages").
    /// Same rule as ThreadEntities.personName (Sources/MemoryCore/LevelThreads.swift).
    /// notes-quality: the one name an email's greeting opens with ("Hi Sam,", "Thanks Dana, ..."), or nil.
    static let greeting = Pattern(#"^\s*(?i:hi|hey|hello|dear|thanks|thank you|morning|good morning|good afternoon|good evening)[ ,]+([A-Z][a-z]+)(?=[\s,!.:;]|$)"#)
    static func greeted(_ text: String) -> String? {
        guard case .some(.some(let n)) = greeting.group(text, 1), !["All", "Team", "Everyone", "Guys", "Folks", "Again", "So", "For", "Both"].contains(n) else { return nil }
        return personName(n)
    }
    /// claude/messages-1003: a name or excerpt capture read from a page (metadata), cleaned, or nil when empty, too long to
    /// be a name, or private (a secret, health, money, text addressed to AI tools).
    static func metaName(_ raw: String?, _ limit: Int) -> String? {
        guard let raw else { return nil }
        let t = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, limit >= 80 || t.count <= limit, !WriterPrivacy.secret(t), !health.search(t), !finance.search(t), !inject.search(t) else { return nil }
        return clean(t, limit)
    }
    /// "Ada's", "James'".
    static func possessive(_ name: String) -> String { name.hasSuffix("s") ? name + "'" : name + "'s" }
    static func personName(_ raw: String) -> String? {
        let s = raw.trimmed
        guard (1...32).contains(s.count), !s.contains("@"), !s.contains("#"), !s.contains(","), !s.contains("&"), s.rangeOfCharacter(from: .decimalDigits) == nil else { return nil }
        let words = s.split(separator: " ")
        guard (1...3).contains(words.count), words.allSatisfy({ $0.first?.isLetter == true && $0.first?.isUppercase == true }) else { return nil }
        let generic: Set<String> = ["messages", "new message", "whatsapp", "signal", "telegram", "chats", "inbox", "slack", "threads",
                                    "direct messages", "activity", "home", "search", "later", "mentions", "drafts"]
        return generic.contains(s.lowercased()) ? nil : s
    }
    /// fix/sx-all round 1: a title or subject as it reads inside a sentence: its first letter lower case, unless its first
    /// word is a name the capital belongs to ("Q3 numbers", "PR #418", "TAL-212 ...", "Friday dinner", "DayDream launch").
    static let properStarts: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february",
                                            "march", "april", "may", "june", "july", "august", "september", "october", "november", "december", "i"]
    /// claude/catchup-1003: a person's name as a page or window shows it ("Sam Lee", "Maya Chen Ortiz"): two or three words,
    /// each capitalized, letters only. It keeps its case: never "Looked at sam Lee.".
    static func personLike(_ t: String) -> Bool {
        let words = t.split(separator: " ")
        return (2...3).contains(words.count) && words.allSatisfy { w in
            w.count >= 2 && w.first?.isUppercase == true && w.dropFirst().allSatisfy { $0.isLowercase || $0 == "-" || $0 == "'" || $0 == "\u{2019}" }
        }
    }
    static func lowerTopic(_ t: String) -> String {
        guard let first = t.split(separator: " ").first.map(String.init), let c = first.first, c.isUppercase else { return t }
        let letters = first.filter(\.isLetter)
        let keep = first.contains(where: \.isNumber) || first.dropFirst().contains(where: \.isUppercase) || properStarts.contains(first.lowercased())
            || (letters.count >= 2 && letters == letters.uppercased()) || personLike(t)
        return keep ? t : t.prefix(1).lowercased() + t.dropFirst()
    }
    /// An email thread's subject from its window name: "Re: Q3 numbers" -> "Q3 numbers"; "" for a mailbox.
    static func subjectOf(_ place: String) -> String {
        var s = place.trimmed, changed = true
        while changed {
            changed = false
            for p in ["re:", "fwd:", "fw:", "aw:", "wg:"] where s.lowercased().hasPrefix(p) { s = String(s.dropFirst(p.count)).trimmed; changed = true }
        }
        // fix/sx-all: "email" is TitleClean's name for a mailbox view (the cloud view's titles): no subject.
        let boxes: Set<String> = ["inbox", "sent", "drafts", "all mail", "starred", "archive", "outbox", "junk", "spam", "trash", "mail", "email", "gmail", "new message"]
        // A mailing list's "[owner/repo] " tag is not the subject.
        if let r = s.range(of: #"^\[[^\]]{1,40}\]\s*"#, options: .regularExpression) { s = String(s[r.upperBound...]) }
        // A web typing row's title is its site ("mail.google.com"): no subject.
        if !s.contains(" "), s.contains(".") { return "" }
        return boxes.contains(s.lowercased()) ? "" : s
    }
    /// notes-quality: a window or tab title as a name (CanonicalGrounding.fallbackName): no unread counts, email addresses
    /// or " - Gmail", " - Google Docs", " - YouTube", " / X", " - Slack" endings; a Slack channel is "#eng", a pull request
    /// "PR #418: Add weekly export"; a mailbox or home page ("Inbox", "Home") names nothing (""), so the site or app does.
    static func cleanTitle(_ raw: String, app: String, site: String) -> String {
        if raw.isEmpty || raw == hiddenTitle { return raw }
        // Microsoft Teams: "Meeting | Weekly sync | Microsoft Teams" is the meeting, "Chat | Priya Shah" the person.
        if teamsApps.contains(app) || host(site).hasPrefix("teams.") {
            let parts = raw.components(separatedBy: " | ").map(\.trimmed).filter { !$0.isEmpty && $0 != "Microsoft Teams" }
            if parts.count >= 2, ["meeting", "chat", "call"].contains(parts[0].lowercased()) { return parts[1] }
        }
        return CanonicalGrounding.fallbackName(raw, app: app, site: site).title
    }
    /// fix/sx-all round 2: the author a GitHub pull request's page title names ("Dedupe retries by sam · Pull Request #212 ·
    /// loomwork/api" -> "sam"), or nil.
    static func prAuthor(_ raw: String) -> String? {
        guard case .some(.some(let name)) = CanonicalGrounding.githubItem.group(raw, 1), case .some(.some(let what)) = CanonicalGrounding.githubItem.group(raw, 2),
              what == "Pull Request", let by = name.range(of: " by ", options: .backwards) else { return nil }
        let login = name[by.upperBound...].trimmingCharacters(in: .whitespaces)
        return login.isEmpty || login.contains(" ") ? nil : login
    }
    static let videoHosts: Set<String> = ["youtube.com", "m.youtube.com", "youtu.be", "vimeo.com", "netflix.com", "twitch.tv"]
    static let docHosts: Set<String> = ["docs.google.com", "notion.so", "figma.com", "coda.io", "quip.com", "dropbox.com"]
    static let docApps: Set<String> = ["Pages", "Numbers", "Keynote", "Microsoft Word", "Microsoft Excel", "Microsoft PowerPoint", "Word", "Excel",
                                       "PowerPoint", "TextEdit", "Notes", "Figma", "Notion", "Obsidian", "Craft", "Bear"]
    static let teamsApps: Set<String> = ["Microsoft Teams", "Teams"]
    /// A Teams window that is a chat, not a call ("Chat | Priya Shah | Microsoft Teams").
    static func teamsChat(_ it: ModelItem) -> Bool {
        (teamsApps.contains(it.app) || host(it.site).hasPrefix("teams.")) && it.actions.contains { $0.title.lowercased().hasPrefix("chat |") }
    }
    static let meetingApps: Set<String> = ["Zoom", "zoom.us", "FaceTime", "Microsoft Teams", "Teams", "Webex", "Cisco Webex Meetings"]
    static let meetingHosts: Set<String> = ["meet.google.com", "zoom.us", "app.zoom.us", "teams.microsoft.com", "teams.live.com"]
    static let meetingHomes: Set<String> = ["zoom", "zoom workplace", "zoom - free account", "zoom - pro account", "zoom - licensed account", "zoom - basic account",
                                            "zoom cloud meetings", "zoom.us", "home - zoom", "zoom - home", "home", "facetime", "microsoft teams", "meet", "google meet"]

    /// The time of the moment's last detected send's last action, or nil (days have no NEXT).
    static func afterLastSend(_ items: [ModelItem], _ scope: Scope) -> String? {
        if scope == .day { return nil }
        return items.filter { $0.detected() }.flatMap { $0.actions.map(\.at) }.max()
    }
    /// Indices of up to 3 windows or tabs first seen after `after`, in order of their first action.
    static func nextWindows(_ items: [ModelItem], _ after: String?) -> [Int] {
        guard let after else { return [] }
        let first = items.indices.sorted { (items[$0].actions[0].at, items[$0].actions[0].id) < (items[$1].actions[0].at, items[$1].actions[0].id) }
        return Array(first.filter { [.window, .tab].contains(items[$0].kind) && items[$0].actions[0].at > after }.prefix(maxNext))
    }
    /// prompt7: code typed after the last send in the app of a NEXT window is folded into that window ("…open, typed"):
    /// it is what the person did next, not something they asked or sent.
    static func absorbNext(_ items: [ModelItem], _ scope: Scope) -> [ModelItem] {
        guard let after = afterLastSend(items, scope) else { return items }
        var items = items
        let nexts = nextWindows(items, after)
        var drop = Set<Int>()
        for i in items.indices where items[i].kind == .typed && items[i].surface() == "code" && items[i].parts.isEmpty && items[i].actions[0].at > after {
            guard let w = nexts.first(where: { items[$0].app == items[i].app }) else { continue }
            for a in items[i].actions { items[w].add(a, "typed") }
            drop.insert(i)
        }
        return items.indices.filter { !drop.contains($0) }.map { items[$0] }
    }
    /// Numbers the items. prompt7: in a moment, up to 3 windows or tabs first seen after the last detected send are NEXT
    /// (n1-n3): what the person did right afterwards; ", typed" when typing followed in that app too.
    static func number(_ items: [ModelItem], _ scope: Scope) -> [ModelItem] {
        var sorted = items.sorted { ($0.actions[0].at, $0.actions[0].id) < ($1.actions[0].at, $1.actions[0].id) }
        for n in sorted.indices { sorted[n].next = false }
        for n in nextWindows(sorted, afterLastSend(sorted, scope)) { sorted[n].next = true }
        var main = sorted.filter { !$0.next }, nexts = sorted.filter(\.next)
        for n in main.indices {
            main[n].alias = "i\(n + 1)"
            main[n].line = "\(main[n].alias). \(main[n].head()): \(main[n].body())"
        }
        for n in nexts.indices {
            nexts[n].alias = "n\(n + 1)"
            nexts[n].line = "\(nexts[n].alias). \(nexts[n].head()): \(nexts[n].body())" + ((nexts[n].counts["typed"] ?? 0) > 0 ? ", typed" : "")
        }
        return main + nexts
    }
    static func render(_ scope: Scope, _ items: [ModelItem]) -> String {
        let main = items.filter { !$0.next }, nexts = items.filter(\.next)
        return "NOTE: \(scope.rawValue)\nITEMS:\n" + main.map(\.line).joined(separator: "\n") + (nexts.isEmpty ? "" : "\nNEXT:\n" + nexts.map(\.line).joined(separator: "\n"))
    }

    // MARK: app names

    /// Names the model sees for common bundle IDs; installed apps' own names (LocalApp.catalog) win.
    public static let knownApps: [String: String] = [
        "com.tinyspeck.slackmacgap": "Slack", "jp.naver.line.mac": "LINE", "com.apple.iWork.Pages": "Pages",
        "com.apple.iWork.Keynote": "Keynote", "com.apple.mail": "Mail", "com.apple.Notes": "Notes", "us.zoom.xos": "Zoom",
        "com.google.Chrome": "Chrome", "com.apple.Safari": "Safari", "dev.zed.Zed": "Zed", "com.mitchellh.ghostty": "Ghostty",
        "com.apple.iCal": "Calendar", "com.apple.freeform": "Freeform", "com.figma.Desktop": "Figma", "com.spotify.client": "Spotify",
        "com.anthropic.claudefordesktop": "Claude", "com.microsoft.VSCode": "VS Code", "com.apple.Terminal": "Terminal",
        "com.apple.dt.Xcode": "Xcode", "com.apple.MobileSMS": "Messages", "com.apple.iWork.Numbers": "Numbers", "zoom.us": "Zoom",
        "com.openai.chat": "ChatGPT", "com.openai.codex": "ChatGPT",
    ]
    static let fixedApps = ["com.openai.codex": "ChatGPT"]
    static let bundleID = Pattern(#"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}$"#)
    /// One name per app, whichever source named it: the browser extension files Chrome evidence as "Chrome" while the
    /// installed catalog names com.google.Chrome "Google Chrome", and clicks and typing attach to items by app name.
    static let canonicalApps = ["Google Chrome": "Chrome", "zoom.us": "Zoom", "Visual Studio Code": "VS Code"]
    static func appName(_ app: String, _ names: [String: String] = [:]) -> String {
        if app.isEmpty { return "" }
        var name: String
        // notes-quality: ChatGPT.app ships as com.openai.codex; its bundle metadata may name it "Codex".
        if let fixed = fixedApps[app] { name = fixed }
        else if let known = names[app] ?? knownApps[app] { name = known }
        else if bundleID.search(app) { let last = app.split(separator: ".").last.map(String.init) ?? app; name = last.prefix(1).uppercased() + last.dropFirst() }
        else { name = app }
        name = canonicalApps[name] ?? name
        // An app's name is untrusted too: one line, no quotes or angle brackets, never an instruction.
        let shownName = clean(name, 60)
        return inject.search(shownName) ? "an app" : shownName
    }

    // MARK: untrusted text as the model sees it

    static let health = Pattern(#"(?i)(?<![\w-])(?:MRI|CT scan|x-rays?|ultrasound|biopsy|diagnos(?:is|es|ed)|prescri(?:ption|bed)|medications?|meds|dosage|therapy|therapist|psychiatrist|blood (?:test|work)|lab results|surgery|chemo(?:therapy)?|pregnan(?:t|cy)|HIV|STD|STI|antidepressants?|insulin|urgent care|cancer|oncolog\w*|tumou?rs?|mammograms?|colonoscopy|(?:cancer|health|medical|STD|STI) screenings?|depression|anxiety|ADHD|bipolar|rehab|IVF|miscarriage|abortion|(?-i:Dr\.? [A-Z][a-z]+))(?![\w-])"#)
    static let finance = Pattern(#"(?i)(?<![\w-])(?:declined (?:card|payment|transaction|charge)|card (?:was |got )?declined|overdraft|overdrawn|collections? agency|debt collectors?|past[- ]due|credit score|bankruptcy|foreclosure|payday loan|(?:card|account|routing) number|(?-i:Chase|Wells Fargo|Citi|Citibank|Capital One|Bank of America|American Express|Amex|Discover|Barclays|HSBC|Schwab|Fidelity|Venmo|PayPal|Zelle) (?:bank|card|account|checking|savings|credit|debit|statement|payment|transfer|login))(?![\w-])"#)
    /// claude/messages2-1003: a phone number or an email address as Messages titles a conversation with no contact name
    /// (core's `SendRules.messagesHandle`): an address, or 7 to 15 digits with only phone punctuation.
    static func contactHandle(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("@") { return !t.contains(where: \.isWhitespace) && t.split(separator: "@").count == 2 }
        let digits = t.filter(\.isNumber).count
        return (7...15).contains(digits) && t.allSatisfy { $0.isASCII && ($0.isNumber || " +()-.".contains($0)) }
    }
    static let sensitiveNumber = Pattern(#"\d{5,}|(?<!\d)\d{3}[\s.-]\d{3}[\s.-]\d{4}(?!\d)|\+\d{6,}|(?<!\d)(?:\d{4}[ -]){3}\d{4}(?!\d)"#)
    /// Injection markers, and text addressed to whatever summarizes the page.
    static let inject = Pattern(#"(?i)\b(?:ignore|disregard|forget) (?:all |any )?(?:the |your )?(?:previous|prior|above|earlier|preceding) (?:instructions|prompts?|rules)|<\|?(?:im_start|im_end|endoftext)|\|im_(?:start|end)\||</?think>|\byou are now\b|\bsystem prompt\b|\b(?:admin|developer|god) mode\b|\{\s*[\"'](?:title|bullets|ids)[\"']\s*:|[\"'](?:actionIDs|assertion)[\"']\s*:|\b(?:notes?|instructions?|messages?|reminders?) (?:for|to) (?:the |any |all )?(?:AI|assistants?|summari[sz]ers?|language models?|LLMs?|chatbots?)\b|\b(?:AI|assistants?|summari[sz]ers?|language models?|LLMs?|chatbots?)\b[^.\n]{0,40}?\b(?:summari[sz]\w*|summary|say|state|write|mention|describe|record|report|include|claim)\b|\b(?:mention|say|state|write|include|record|note) (?:this |that |it )?(?:in|into) (?:the|your) (?:summary|summaries|notes?|recap|report)\b|\bif you are an? (?:AI|assistant|language model|LLM|chatbot)\b"#)
    static let control = Pattern(#"[\u0000-\u001F\u007F]"#)
    static let spaces = Pattern(#"[\s\u0085]+"#)
    static let scheme = Pattern(#"^https?://"#)

    /// One line; no double quotes or angle brackets (so text cannot close its quotes or form a special token),
    /// and no phone, account or reference numbers (the model cannot copy what it never sees).
    static func clean(_ s: String, _ limit: Int) -> String {
        var t = control.replacing(s, with: " ")
        t = t.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "<", with: "\u{2039}").replacingOccurrences(of: ">", with: "\u{203A}")
        t = spaces.replacing(t, with: " ").trimmed
        t = sensitiveNumber.replacing(t, with: "[number]")
        return t.count <= limit ? t : trailingSpace(String(t.prefix(limit - 1))) + "\u{2026}"
    }
    /// The quoted text, and whether anything was hidden. Text from the first injection marker on is never shown; health and money text never is.
    static func shown(_ s: String, _ limit: Int = quoteChars) -> (text: String, hidden: Bool) {
        if health.search(s) { return (healthNote, true) }
        if finance.search(s) { return (financeNote, true) }
        guard let m = inject.first(s) else { return ("\"" + clean(s, limit) + "\"", false) }
        let head = trailing(clean(String(s[..<m.lowerBound]), limit), " :;,.-\u{2014}\u{2013}")
        return (head.split(whereSeparator: \.isWhitespace).count >= 2 ? "\"\(head)\" plus \(aiNote)" : aiNote, true)
    }
    static func trailing(_ s: String, _ chars: String) -> String {
        var t = Substring(s)
        while let last = t.last, chars.contains(last) { t = t.dropLast() }
        return String(t)
    }
    static func trailingSpace(_ s: String) -> String {
        var t = Substring(s)
        while let last = t.last, last.isWhitespace { t = t.dropLast() }
        return String(t)
    }
    /// An action's `at` (ISO 8601, optional fractional seconds) as seconds since 1970.
    static func seconds(_ at: String) -> Double {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (f.date(from: at) ?? ISO8601DateFormatter().date(from: at))?.timeIntervalSince1970 ?? 0
    }
    /// How long a typing run took, in words the model may repeat ("about 2 minutes"); "" under 45 seconds (sat5).
    public static func about(_ span: Double) -> String {
        if span < 45 { return "" }
        let m = max(1, Int((span / 60 + 0.5).rounded(.down)))
        if m < 90 { return "about \(m) minute" + (m == 1 ? "" : "s") }
        let h = Int((Double(m) / 60 + 0.5).rounded(.down))
        return "about \(h) hour" + (h == 1 ? "" : "s")
    }
    static func times(_ n: Int) -> String { n < 2 ? "" : n == 2 ? "twice" : n <= 5 ? "a few times" : "many times" }
    static func joinAnd(_ xs: [String]) -> String {
        xs.count <= 1 ? (xs.first ?? "") : xs.dropLast().joined(separator: ", ") + " and " + xs.last!
    }

    // MARK: classification (descriptions: Actions.swift, Models.swift)

    static let mech: [String: String] = ["mouse.click": "click", "mouse.context_menu": "click", "keyboard.shortcut": "shortcut", "keyboard.submit": "return",
                                         "app.activated": "silent", "session.started": "silent", "session.ended": "silent", "debug.error": "silent"]
    static let windowKinds: Set<String> = ["window.changed", "window.observed", "focus.observed", "browser.snapshot"]
    static let tabKinds: Set<String> = ["browser.tab_opened", "browser.tab_visited", "browser.extension_tab_visited", "browser.observed", "browser.extension_observed"]
    static let draftStates: Set<String> = ["draft", "typed", "drafted_request"]
    static let inputKinds: Set<String> = ["mouse.click", "mouse.context_menu", "keyboard.shortcut", "keyboard.submit", "keyboard.text_input"]
    /// Get their own bullets; never absorb background items.
    static let special: Set<ModelItem.Kind> = [.sent, .report, .note, .request, .plan]
    /// May own folded clicks, shortcuts and Return presses.
    static let attachable: Set<ModelItem.Kind> = [.window, .typed, .tab, .search, .screentext, .mechonly, .other]
    /// Items the model may leave out: code covers them.
    static let background: Set<ModelItem.Kind> = [.window, .tab, .mechonly, .other, .unavailable]

    static let payloadPattern = Pattern(#"(?s):\s*"(.*)"(?:\s*\(not independently verified\))?\.?(?:\s*Authorship and completion are not established\.)?\s*$"#)
    static let hedges = [Pattern(#";\s*(reading|sending|authorship|submission and reading) (is|are) not established\.?"#), Pattern(#"\s*\(not independently verified\)"#),
                         Pattern(#"\s*Authorship and completion are not established\.?"#), Pattern(#";\s*no reading or work duration is established\.?"#)]
    static let typedDraft = Pattern(#"(?s)^Typed a draft in .*?\.(?: (.*))?$"#)
    static let observedSearch = Pattern(#"(?s)^Observed search results for (.*) in .*; submission and reading are not established\.$"#)
    static let viewedSearch = Pattern(#"(?s)^Viewed search results for "(.*)"\.$"#)

    static func payload(_ d: String) -> String? { payloadPattern.group(d, 1) ?? nil }
    static func stripHedges(_ d: String) -> String { hedges.reduce(d) { $1.replacing($0, with: "") }.trimmed }
    static func classify(_ a: NoteAction) -> (String, String?) {
        let k = a.kind, s = a.state, d = a.description
        func payloadOrHedged() -> String { payload(d).flatMap { $0.isEmpty ? nil : $0 } ?? stripHedges(d) }
        if d.contains(correctionAppended) { return ("note", d.components(separatedBy: correctionAppended).last!) }
        if s == "reported" || s == "user_corrected" {
            if d.hasPrefix(correctionAction) { return ("note", String(d.dropFirst(correctionAction.count))) }
            return ("report", payloadOrHedged())
        }
        if s == "planned" { return ("plan", payloadOrHedged()) }
        if s == "requested" { return ("request", payloadOrHedged()) }
        if s == "unavailable" { return ("unavailable", nil) }
        if s == "drafted_request" || s == "typed", let p = payload(d) { return ("typed", p) }
        if k == "message.sent" { return s == "sent" ? ("sent", nil) : ("unverified", nil) }
        if k == "keyboard.text_input" {
            let rest = typedDraft.group(d, 1)
            if case .some(.some(let t)) = rest, !t.isEmpty { return ("typed", t) }
            return ("typed", "")
        }
        if let m = mech[k] { return ("mech", m) }
        if k == "idle" || s == "idle" { return ("idle", nil) }
        if case .some(.some(let q)) = observedSearch.group(d, 1) { return ("search", q) }
        if case .some(.some(let q)) = viewedSearch.group(d, 1) { return ("search", q) }
        if tabKinds.contains(k) { return ("tab", nil) }
        if windowKinds.contains(k) { return ("window", a.title) }
        if k == "selection.changed" || k == "terminal.value_changed" { return ("screentext", payload(d)) }
        return ("other", nil)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
