import Foundation

/// The level writer's prompt, validator and extractive salvage (levels-prompt1-validator1). A level note is written
/// only from its children's notes, so every line must be grounded in the children it cites:
/// - names and numbers it uses appear in those children;
/// - a verb that claims something happened (Asked, Emailed, Texted, sent, fixed, finished, ...) appears in one of them:
///   a level never upgrades a draft to a send, or a request to a result;
/// - no "the user", no "they", no ids, no time spent.
/// When the model's answer fails twice, code writes the note from the children's own lines (they already passed).
public enum LevelGrounding {
    public struct Reject: Error, Equatable { public let code:String; public let reason:String }

    // MARK: prompt

    public static func instruction(_ level:LevelKind) -> String {
        let common = """
Rules:
- Use only what the notes say. Keep their verbs: write Asked, Emailed, Texted, Messaged, Searched or Approved only where a cited note says it. A draft stays a draft. Never say sent, finished, fixed or shipped unless a cited note says so.
- Use only names and numbers that are in the notes you cite.
- Write like a diary with no subject: "Asked Claude to ...", never "the user" or "they".
- No times, no durations, no ids in the text.
- Each line is one sentence under 20 words, and cites the ids it is based on.
Answer with JSON only.
"""
        switch level {
        case .block:
            return """
You group one stretch of someone's Mac activity. Below are DayDream's notes for the moments in the stretch, in time order, with ids m1, m2, ...
Write {"goal":"...","lines":[{"ids":["m1"],"text":"..."}]}.
goal: what the stretch was mostly for, as an -ing phrase of 2 to 8 words, like "making summaries smarter" or "planning the Tokyo trip".
lines: 1 to 3 lines. Lead with what was asked, sent or decided, then what else happened.
\(common)
"""
        case .day:
            return """
You write the note for one day of someone's Mac activity from DayDream's notes for the day's stretches, in time order, with ids b1, b2, ...
Write {"headline":"...","lines":[{"ids":["b1"],"text":"..."}]}.
headline: one sentence under 16 words saying what the day was mostly about.
lines: 2 to 5 lines, one for each main thread of the day, most important first. Lead with what was asked, sent or decided.
\(common)
"""
        case .week, .month:
            let (unit,ids)=level == .week ? ("week","d1, d2") : ("month","w1, w2")
            return """
You write the note for one \(unit) of someone's Mac activity from DayDream's notes for its \(level == .week ? "days" : "weeks"), in time order, with ids \(ids), ...
Write {"headline":"...","lines":[{"ids":["\(level.alias)1"],"text":"..."}]}.
headline: one sentence under 16 words saying what the \(unit) was mostly about.
lines: 2 to 5 lines, one for each thread that ran through the \(unit), most important first.
\(common)
"""
        }
    }
    public static func prefill(_ level:LevelKind) -> String { level == .block ? "{\"goal\":\"" : "{\"headline\":\"" }

    /// The instruction for a request: with threads (blocks and days, LevelThreads) the model names the main thread only
    /// (its bullets are written by code); else the level's full note.
    public static func instruction(for request:LevelRequest) -> String {
        guard threaded(request) else { return instruction(request.level) }
        let rules = """
Rules:
- Use only what the notes say. Keep their verbs: write Asked, Emailed, Texted, Messaged, Searched or Approved only where a note says it. A draft stays a draft. Never say sent, finished, fixed or shipped unless a note says so.
- Use only names and numbers that are in the notes.
- No subject: never "the user" or "they". No times, no durations, no ids.
Answer with JSON only.
"""
        if request.level == .block {
            return """
You name one stretch of someone's Mac activity by its main thread. Below are DayDream's notes for the moments of that thread, in time order.
Write {"goal":"..."}.
goal: what the thread was for, as an -ing phrase of 2 to 8 words, like "writing the Q3 investor update" or "planning the Tokyo trip". Never "opening", "having" or "using" something: say what it was for.
\(rules)
"""
        }
        let (unit,kids)=request.level == .day ? ("day","stretches") : request.level == .week ? ("week","days") : ("month","weeks")
        return """
You name one \(unit) of someone's Mac activity by its main thread. Below are DayDream's notes for the \(kids) of that thread, in time order.
Write {"headline":"..."}.
headline: one sentence of 3 to 16 words saying what the main thing of the \(unit) was, like "Planning the Lisbon trip" or "Wrote the Q3 investor update". Only the main thing. Never "opening", "having" or "using" something.
\(rules)
"""
    }
    /// A block or day written with threads: its lines are the side threads (code), its title the main thread.
    public static func threaded(_ request:LevelRequest) -> Bool {
        !(request.threads ?? []).isEmpty
    }
    /// The children of the main thread, and one more view carrying the thread's own names (its label, people and
    /// places), which a title may use.
    static func mainViews(_ request:LevelRequest) -> [LevelChildView] {
        guard let main = request.threads?.first else { return request.children }
        let kids = request.children.filter { main.children.contains($0.ref.id) }
        let names = LevelChildView(alias:"thread",ref:LevelChildRef(id:"thread:"+main.key,version:"",start:main.start,end:main.end),label:"",
                                   title:main.label,lines:main.people+main.places,typed:false)
        return (kids.isEmpty ? request.children : kids)+[names]
    }

    /// fix/sx-all round 1: when the earliest child the writer's evidence holds starts (a threaded day sends only its main
    /// thread's blocks). Cloud writes a level note only when this is after the moment cloud was turned on, so a key pasted
    /// at noon still gets the afternoon's main thread written by the cloud model, and nothing from the morning is sent.
    public static func evidenceStart(_ request:LevelRequest) -> String {
        var kids=request.children
        if threaded(request), let main=request.threads?.first {
            let only=request.children.filter { main.children.contains($0.ref.id) }
            if !only.isEmpty { kids=only }
        }
        return kids.map(\.ref.start).min() ?? request.start
    }
    /// The children as the writer reads them, trimmed to the level's budget: first "Also had ... open" lines go, then
    /// all but the first two lines of each child, then the lines.
    public static func evidence(_ request:LevelRequest) -> String {
        if threaded(request), let main = request.threads?.first {
            var only = request
            only.threads = nil
            let kids = request.children.filter { main.children.contains($0.ref.id) }
            if !kids.isEmpty { only.children = kids }
            return evidence(only)
        }
        let header:String
        switch request.level {
        case .block: header="STRETCH: "+(request.children.first.map { $0.label.components(separatedBy:" to ").first ?? "" } ?? "")+" to "+(request.children.last.map { $0.label.components(separatedBy:" to ").last ?? "" } ?? "")
        case .day: header="DAY"
        case .week: header="WEEK"
        case .month: header="MONTH"
        }
        func render(_ keep:(LevelChildView) -> [String]) -> String {
            header+"\nNOTES:\n"+request.children.map { c in
                let lines=keep(c)
                return "\(c.alias). \(c.label) - \(clean(c.title))"+(lines.isEmpty ? "" : "\n"+lines.map { "   - "+clean($0) }.joined(separator:"\n"))
            }.joined(separator:"\n")
        }
        let steps:[(LevelChildView) -> [String]]=[
            { $0.lines },
            { $0.lines.filter { !$0.hasPrefix("Also had") && !$0.hasPrefix("Had ") } },
            { Array($0.lines.filter { !$0.hasPrefix("Also had") && !$0.hasPrefix("Had ") }.prefix(2)) },
            { Array($0.lines.filter { !$0.hasPrefix("Also had") && !$0.hasPrefix("Had ") }.prefix(1)) },
            { _ in [] }]
        for step in steps {
            let text=render(step)
            if text.count <= request.level.evidenceChars { return text }
        }
        return String(render({ _ in [] }).prefix(request.level.evidenceChars))
    }
    static func clean(_ s:String) -> String { s.replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"<",with:"‹") }

    // MARK: validate

    public struct Answer: Equatable { public var head:String; public var lines:[(ids:[String],text:String)]
        public static func == (a:Answer,b:Answer) -> Bool { a.head == b.head && a.lines.map(\.text) == b.lines.map(\.text) && a.lines.map(\.ids) == b.lines.map(\.ids) }
    }
    public static func decode(_ raw:String,level:LevelKind) throws -> Answer {
        var text=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        if !text.hasPrefix("{") && !text.hasPrefix("```") { text=prefill(level)+text }
        if let open=text.firstIndex(of:"{"), let close=text.lastIndex(of:"}"), open < close { text=String(text[open...close]) }
        guard let data=text.data(using:.utf8), let obj=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw Reject(code:"json",reason:"The answer is not one JSON object.") }
        let key=level == .block ? "goal" : "headline"
        guard let head=obj[key] as? String else { throw Reject(code:"structure",reason:"The answer has no \"\(key)\".") }
        guard let raws=obj["lines"] as? [[String:Any]] else { throw Reject(code:"structure",reason:"The answer has no \"lines\" list.") }
        let lines=raws.map { r in ((r["ids"] as? [Any] ?? []).compactMap { $0 as? String }, (r["text"] as? String ?? "")) }
        return Answer(head:head,lines:lines)
    }
    /// The finished note (title, lines) for a model answer, or a Reject with a reason the repair turn can use.
    public static func validate(_ raw:String,request:LevelRequest) throws -> (title:String,lines:[LevelLine]) {
        if threaded(request) { return try validateHead(raw,request:request) }
        let answer=try decode(raw,level:request.level)
        let byAlias=Dictionary(uniqueKeysWithValues:request.children.map { ($0.alias.lowercased(),$0) })
        let head=answer.head.trimmingCharacters(in:.whitespacesAndNewlines).trimmingCharacters(in:CharacterSet(charactersIn:"."))
        guard !answer.lines.isEmpty else { throw Reject(code:"structure",reason:"Write 1 to \(request.level.maxLines) lines.") }
        // Too many lines: the first ones are kept (each is still checked); the model tends to list the biggest first.
        var lines=[LevelLine](), seen=Set<String>()
        for (n,line) in answer.lines.prefix(request.level.maxLines).enumerated() {
            let text=line.text.split(whereSeparator:\.isWhitespace).joined(separator:" ")
            guard !text.isEmpty else { throw Reject(code:"structure",reason:"Line \(n+1) is empty.") }
            guard seen.insert(text.lowercased()).inserted else { throw Reject(code:"structure",reason:"Two lines are the same.") }
            let kids=Array(NSOrderedSet(array:line.ids.map { $0.lowercased().trimmingCharacters(in:.whitespaces) })) as! [String]
            guard !kids.isEmpty, kids.allSatisfy({ byAlias[$0] != nil }) else { throw Reject(code:"ids",reason:"Line \(n+1) must cite ids from the list, like \"\(request.level.alias)1\".") }
            let cited=kids.map { byAlias[$0]! }
            if let why=problem(text,cited:cited,maxChars:180) { throw Reject(code:why.0,reason:"Line \(n+1) "+why.1) }
            lines.append(LevelLine(text:text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!") ? text : text+".",children:cited.map(\.ref.id)))
        }
        if request.level == .block {
            let words=head.split(separator:" ")
            guard (2...8).contains(words.count), let first=words.first, first.lowercased().hasSuffix("ing") else { throw Reject(code:"goal",reason:"The goal must be an -ing phrase of 2 to 8 words, like \"planning the Tokyo trip\".") }
            if let why=problem(head,cited:request.children,maxChars:70,sentenceStart:false) { throw Reject(code:why.0,reason:"The goal "+why.1) }
            let goal=head.prefix(1).lowercased()+head.dropFirst()
            return (LevelNotesTitle.block(request,goal:String(goal)),lines)
        }
        guard (3...16).contains(head.split(separator:" ").count) else { throw Reject(code:"headline",reason:"The headline must be one sentence of 3 to 16 words.") }
        if let why=problem(head,cited:request.children,maxChars:120) { throw Reject(code:why.0,reason:"The headline "+why.1) }
        // fix/sx-all round 1: the main-thread rule for weeks and months too. A headline that is one of the children's side
        // lines (a one-minute email) and none of their headlines is refused; the days' headlines say the main thing.
        if request.level == .week || request.level == .month, let side=sideLine(head,request) {
            throw Reject(code:"headline",reason:"The headline repeats one side line (\"\(side)\"). Say what the \(request.level == .week ? "week" : "month") was mostly about, from the headlines.")
        }
        return (head+".",lines)
    }
    /// fix/sx-all round 1: the child line a week or month headline repeats, when it repeats none of the children's titles.
    static func sideLine(_ head:String,_ request:LevelRequest) -> String? {
        func norm(_ s:String) -> String { s.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:". ")) }
        let h=norm(head)
        guard !h.isEmpty, !request.children.contains(where:{ let t=norm($0.title); return !t.isEmpty && (h.contains(t) || t.contains(h)) }) else { return nil }
        return request.children.flatMap(\.lines).first { let l=norm($0); return !l.isEmpty && (h == l || h.contains(l) || l.contains(h)) }
    }
    /// A threaded request: the model's goal or headline for the main thread, checked against that thread's notes and
    /// names; the lines are the code's side-thread bullets (`threadNote`).
    static func validateHead(_ raw:String,request:LevelRequest) throws -> (title:String,lines:[LevelLine]) {
        var text=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        if !text.hasPrefix("{") && !text.hasPrefix("```") { text=prefill(request.level)+text }
        if let open=text.firstIndex(of:"{"), let close=text.lastIndex(of:"}"), open < close { text=String(text[open...close]) }
        guard let data=text.data(using:.utf8), let obj=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw Reject(code:"json",reason:"The answer is not one JSON object.") }
        let key=request.level == .block ? "goal" : "headline"
        guard let rawHead=obj[key] as? String else { throw Reject(code:"structure",reason:"The answer has no \"\(key)\".") }
        let head=rawHead.split(whereSeparator:\.isWhitespace).joined(separator:" ").trimmingCharacters(in:CharacterSet(charactersIn:"."))
        let code=threadNote(request)
        let cited=mainViews(request)
        if let why=openOnly(head) { throw Reject(code:"goal",reason:why) }
        if request.level == .block {
            let words=head.split(separator:" ")
            guard (2...8).contains(words.count), let first=words.first, first.lowercased().hasSuffix("ing") else { throw Reject(code:"goal",reason:"The goal must be an -ing phrase of 2 to 8 words, like \"planning the Tokyo trip\".") }
            if let why=problem(head,cited:cited,maxChars:70,sentenceStart:false) { throw Reject(code:why.0,reason:"The goal "+why.1) }
            if let why=sideProblem(head,request) { throw Reject(code:"main",reason:"The goal "+why) }
            return (LevelNotesTitle.block(request,goal:head.prefix(1).lowercased()+head.dropFirst()),code.lines)
        }
        guard (3...16).contains(head.split(separator:" ").count) else { throw Reject(code:"headline",reason:"The headline must be one sentence of 3 to 16 words.") }
        // fix/sx-all round 1: a week or month headline that is one of its own side lines names no main thread.
        if request.level == .week || request.level == .month, let side=sideLine(head,request) ?? code.lines.map(\.text).first(where:{ $0.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:". ")) == head.lowercased() }) {
            throw Reject(code:"headline",reason:"The headline repeats one side line (\"\(side)\"). Say the main thing of the \(request.level == .week ? "week" : "month").")
        }
        if let why=problem(head,cited:cited,maxChars:120) { throw Reject(code:why.0,reason:"The headline "+why.1) }
        if let why=sideProblem(head,request) { throw Reject(code:"main",reason:"The headline "+why) }
        return (head+".",code.lines)
    }
    /// fix/sx-all round 3: the main thread's own time a goal or headline speaks for. Its telling words (not the thread's own
    /// name, people or places, not a verb, not a word every child of the thread has) must come from children that hold at
    /// least `mainShare` of the thread's time: a coding morning of about 3 hours is never "writing the release notes" from
    /// one 6-minute ask. A block's children are its moments (their titles and lines); a day's are its blocks (their titles:
    /// a block's lines are its side threads). nil: it holds, or nothing tells (every word is everywhere or nowhere).
    static let mainShare=0.25
    static let headStops:Set<String>=Set("a an the of to in on at for and or with about from by as my your our is was were be it its this that these those some more main new".split(separator:" ").map(String.init))
    static let headVerbs:Set<String>=Set("worked working work wrote write writing checked checking check looked looking reviewed reviewing read reading made making got getting went going did doing".split(separator:" ").map(String.init))
    static let muteTitlePattern=try! NSRegularExpression(pattern:#"^([\w.+-]+\.[A-Za-z]{1,6}( in [\w.-]+)?|(Terminal|Claude Code|Codex|Gemini CLI|Aider) in [\w.-]+|[\w.-]+( — [\w.-]+)?)$"#)
    static let workTitlePattern=try! NSRegularExpression(pattern:#"\b(PR|Issue) #\d+|\b[A-Z][A-Z0-9]{1,9}-\d{1,6}\b"#)
    static func workTitle(_ title:String) -> Bool { workTitlePattern.firstMatch(in:title,range:NSRange(title.startIndex...,in:title)) != nil }
    static func muteTitle(_ title:String) -> Bool {
        muteTitlePattern.firstMatch(in:title,range:NSRange(title.startIndex...,in:title)) != nil
    }
    public static func sideProblem(_ head:String,_ request:LevelRequest) -> String? {
        guard let main=request.threads?.first else { return nil }
        let kids=request.children.filter { main.children.contains($0.ref.id) }
        guard kids.count >= 2 else { return nil }
        let own=Set(words(([main.label]+main.people+main.places).joined(separator:" ")).map(stem))
        let skip=Set((headStops.union(headVerbs).union(purposeVerbs).union(claimWords)).map(stem))
        let told=Set(words(head).filter { $0.count >= 2 }.map(stem)).subtracting(own).subtracting(skip)
        func said(_ c:LevelChildView) -> Set<String> {
            Set(words(request.level == .block ? c.title+" "+c.lines.joined(separator:" ") : c.title).map(stem))
        }
        let kidWords=kids.map(said)
        // A project's or file's name (a code file's or a terminal's title: `muteTitle`) tells nothing about what for.
        let muteWords=request.level == .block ? Set(kids.filter { Self.muteTitle($0.title) }.flatMap { words($0.title).map(stem) }) : []
        let telling=told.subtracting(muteWords).filter { w in let n=kidWords.filter { $0.contains(w) }.count; return n > 0 && n < kids.count }
        // A day's or week's words that only its side threads say (a block's lines are its side threads, never its main
        // one): "Drafted release notes and merged PR #911" on a coding day whose release notes were a 6-minute ask. Half
        // the telling words or more from side threads alone names a side thread, whatever else it says.
        if request.level != .block {
            let titled=kidWords.reduce(into:Set<String>()) { $0.formUnion($1) }
            let sideSaid=Set(request.children.flatMap { c in c.lines.flatMap { words($0).map(stem) } })
            let sideOnly=told.filter { $0.count >= 3 && sideSaid.contains($0) && !titled.contains($0) }
            if !sideOnly.isEmpty, sideOnly.count*2 >= sideOnly.count+telling.count {
                var shown=[String]()
                for w in words(head) where sideOnly.contains(stem(w)) && !shown.contains(w) { shown.append(w) }
                return "names a side thread (\(shown.joined(separator:", "))), not the main one. Say what most of its notes were about."
            }
        }
        guard !telling.isEmpty else { return nil }
        func seconds(_ c:LevelChildView) -> Double { max(1,(timestamp(c.ref.end) ?? .distantPast).timeIntervalSince(timestamp(c.ref.start) ?? .distantPast)) }
        let total=kids.map(seconds).reduce(0,+)
        var support=zip(kids,kidWords).filter { !$0.1.isDisjoint(with:telling) }.map { seconds($0.0) }.reduce(0,+)
        // A code file, a terminal or a bare project name says what was open, not what it was for ("uploader.rs in
        // harborline", "Terminal in harborline"). In a block its thread joined through a pull request or an issue, that
        // time is the PR's or issue's: the coding morning's "fixing sync drops rows" names the issue its 3 hours of code
        // were for, not 6 minutes of reading it; "drafting the release notes" (a 6-minute ask) still names a small part.
        // So is an ask or a note in that thread about one of those files ("Race condition in SyncEngine" beside
        // "SyncEngine.swift in tallybird-sync"): the stretch's code was for it.
        let fileStems=Set(kids.filter { Self.muteTitle($0.title) }.flatMap { c -> [String] in
            let file=c.title.components(separatedBy:" in ")[0]
            guard let dot=file.lastIndex(of:"."), dot > file.startIndex else { return [] }
            return words(String(file[..<dot])).filter { $0.count >= 4 }.map(stem)
        })
        if request.level == .block, zip(kids,kidWords).contains(where: { c,w in !Self.muteTitle(c.title) && !w.isDisjoint(with:telling)
                                                                        && (Self.workTitle(c.title) || !Set(words(c.title).map(stem)).isDisjoint(with:fileStems)) }) {
            support += kids.filter { Self.muteTitle($0.title) }.map(seconds).reduce(0,+)
        }
        guard total > 0, support/total < mainShare else { return nil }
        return "names only a small part of this \(request.level == .block ? "stretch" : "day"). Say what most of its notes were about."
    }
    /// notes-quality: a goal or headline that only says something was open or used ("Opening the weekly summaries pull
    /// request", "Having the weekly product sync meeting") names no goal: refused, and code's thread name is used.
    /// A moment line that says only how long something was open (the code note of a moment with nothing done in it).
    /// fix/sx-all round 1: code's reading lines ("Read texts with Mom.", "Looked at cabins near Sintra.", "Went through
    /// the Gmail inbox.") are passive too: nothing was done that a goal could be read from.
    public static func passive(_ line:String) -> Bool {
        line.range(of:"^(About|Under) [^.]*(minute|minutes|hour|hours)\\.$",options:.regularExpression) != nil
            || line.range(of:"^(Looked at|Went through|Read|In) ",options:.regularExpression) != nil
    }
    static let openVerbs=["opening","having","using","viewing","browsing","looking at","keeping","had","opened","used","viewed"]
    static func openOnly(_ head:String) -> String? {
        let l=head.lowercased()
        guard let v=openVerbs.first(where:{ l.hasPrefix($0+" ") }) else { return nil }
        return "It starts with \"\(v)\", which says only what was open. Say what it was for, like \"planning the Tokyo trip\" or \"writing the Q3 investor update\"."
    }
    /// Code writes the block title's front ("Most of the afternoon") from the times; the model only writes the goal.
    enum LevelNotesTitle {
        static func block(_ r:LevelRequest,goal:String) -> String { MemoryStore.spanPhrase(start:r.start,end:r.end,timezone:r.timezone)+": "+goal }
    }

    /// Re-check of a finished note before it is saved (core runs this on every commit, model or code written).
    public static func check(title:String,lines:[LevelLine],request:LevelRequest,extractive:Bool) -> String? {
        guard !title.isEmpty, title.count <= 200, (1...max(request.level.maxLines,threaded(request) ? LevelThreads.maxBullets(request.level) : 5)).contains(lines.count) else { return "shape" }
        if threaded(request) {
            // Threads: the lines are exactly the code's bullets; the title is the code's, or a model's name for the main
            // thread that keeps to that thread's notes and names.
            // A code-written block may be the plain note (no window-title names), the fallback when the code's own
            // note repeats a short typed draft; the typed check still runs on it.
            if extractive, (title,lines) == plainThreadNote(request) { return nil }
            let code=threadNote(request)
            guard lines == code.lines else { return "threads" }
            if title == code.title { return nil }
            // Today's day note between model headlines: code keeps the last headline while it still holds.
            if extractive, let kept=request.keptTitle, title == kept, request.level != .block {
                let head=title.trimmingCharacters(in:CharacterSet(charactersIn:"."))
                return openOnly(head) != nil || sideProblem(head,request) != nil ? "threads" : problem(head,cited:mainViews(request),maxChars:120)?.0
            }
            guard !extractive else { return "threads" }
            let head:String
            if request.level == .block {
                let front=MemoryStore.spanPhrase(start:request.start,end:request.end,timezone:request.timezone)+": "
                guard title.hasPrefix(front) else { return "shape" }
                head=String(title.dropFirst(front.count))
            } else { head=title.trimmingCharacters(in:CharacterSet(charactersIn:".")) }
            if openOnly(head) != nil { return "goal" }
            if sideProblem(head,request) != nil { return "main" }
            return problem(head,cited:mainViews(request),maxChars:120,sentenceStart:request.level != .block)?.0
        }
        let byID=Dictionary(uniqueKeysWithValues:request.children.map { ($0.ref.id,$0) })
        for line in lines {
            guard !line.children.isEmpty, line.children.allSatisfy({ byID[$0] != nil }) else { return "children" }
            if extractive {
                // Code copies a child's own line or title: it must be exactly one of them.
                guard line.children.count == 1, let c=byID[line.children[0]], c.lines.contains(line.text) || c.title == line.text || c.title+"." == line.text else { return "extractive" }
                continue
            }
            if let why=problem(line.text,cited:line.children.map { byID[$0]! },maxChars:181) { return why.0 }
        }
        if !extractive {
            let head=request.level == .block ? String(title.split(separator:":",maxSplits:1).last ?? "").trimmingCharacters(in:.whitespaces) : title
            if let why=problem(head,cited:request.children,maxChars:120,sentenceStart:request.level != .block) { return why.0 }
        }
        return nil
    }

    static let claimWords:Set<String> = Set("""
asked approved agreed emailed replied texted messaged posted searched sent delivered submitted fixed finished shipped completed resolved merged \
released published passed launched signed read reviewed decided booked paid bought deployed solved done confirmed accepted declined cancelled canceled \
filled finalized closed landed won
""".split(whereSeparator:\.isWhitespace).map(String.init))
    /// -ing leads that only say what a stretch was for (never a claim that something happened).
    static let purposeVerbs:Set<String> = Set("""
working writing planning fixing building making preparing drafting editing updating designing debugging testing setting sorting getting cleaning organizing researching learning catching shopping booking tidying finishing starting moving figuring pricing packing
""".split(whereSeparator:\.isWhitespace).map(String.init))
    static let nameOK:Set<String> = ["i","ai","mac","daydream","claude","chatgpt"]
    static let they=try! NSRegularExpression(pattern:"(?i)(?:^|[.;:!?]\\s+|,\\s+and\\s+)(they|their|them)\\b")
    static let user=try! NSRegularExpression(pattern:"(?i)\\b(the user|user's|the person)\\b")
    static let you=try! NSRegularExpression(pattern:"(?i)\\b(?:you['’](?:ll|re|ve|d)|you|your|yours|yourself)\\b")
    static let alias=try! NSRegularExpression(pattern:"(?<![A-Za-z0-9])[mbdwMBDW]\\d{1,3}(?![A-Za-z0-9])|macmem://")
    static let duration=try! NSRegularExpression(pattern:"(?i)\\b(spent|worked for|for (about |nearly |almost )?(an?|\\d+|one|two|three|four|five|six) (minutes?|hours?|days?)|all day|all morning|all afternoon|hours of)\\b")
    static let number=try! NSRegularExpression(pattern:"\\d+(?:[.:/-]\\d+)*")

    static func words(_ s:String) -> [String] {
        s.lowercased().components(separatedBy:CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    static func stem(_ w:String) -> String {
        var w=w.lowercased()
        if w.hasSuffix("'s") || w.hasSuffix("’s") { w=String(w.dropLast(2)) }
        for suf in ["ing","ed","es","s"] where w.hasSuffix(suf) && w.count-suf.count >= 3 { w=String(w.dropLast(suf.count)); break }
        if w.hasSuffix("e") { w=String(w.dropLast()) }
        if w.count > 3, let last=w.last, w.dropLast().last == last, !"aeiou".contains(last) { w=String(w.dropLast()) }
        return w
    }
    static func matches(_ rx:NSRegularExpression,_ s:String) -> [String] {
        rx.matches(in:s,range:NSRange(s.startIndex...,in:s)).compactMap { Range($0.range,in:s).map { String(s[$0]) } }
    }
    /// (code, reason) for the first rule `text` breaks against the children it cites, or nil.
    static func problem(_ text:String,cited:[LevelChildView],maxChars:Int,sentenceStart:Bool=true) -> (String,String)? {
        guard text.count <= maxChars else { return ("length","is too long. Use one sentence under 20 words.") }
        let corpus=cited.map { $0.title+" "+$0.lines.joined(separator:" ")+" "+$0.label }.joined(separator:" ")
        let corpusWords=Set(words(corpus)), corpusStems=Set(words(corpus).map(stem))
        if !matches(alias,text).isEmpty { return ("alias","shows an id or link. Write plain words.") }
        if !matches(user,text).isEmpty { return ("user","says \"the user\". Write like a diary with no subject: \"Asked Claude ...\".") }
        if let m=matches(they,text).first { return ("they","says \"\(m.trimmingCharacters(in:.punctuationCharacters.union(.whitespaces)))\". Write like a diary with no subject.") }
        // fix/sx-all round 3: never "you" ("Texted Mom that you'll call tonight"): DayDream isn't talking to anyone.
        if let m=matches(you,text).first, !corpusWords.contains(m.lowercased().replacingOccurrences(of:"’",with:"'").components(separatedBy:"'")[0]) {
            return ("you","says \"\(m)\". Write with no subject, like \"Texted Mom about calling tonight\".")
        }
        if let m=matches(duration,text).first { return ("duration","says \"\(m)\". DayDream sees what was open, not time spent.") }
        if Privacy.secret(text) { return ("secret","looks like it holds a secret.") }
        for n in matches(number,text) where !corpus.contains(n) { return ("number","uses \"\(n)\", which is not in the notes it cites.") }
        // A claim verb must be written that way in a cited note: "Emailed" needs "Emailed", not "an email"; "fixed"
        // needs "fixed", not "a fix". An -ing goal ("fixing the export crash") is what the stretch was for, not a claim.
        // Every such word at once: the repair turn fixes what it is told and nothing more.
        // fix/sx-all round 2: an -ing lead says what the stretch was for, and is grounded like any claim: a plain purpose
        // verb ("writing", "planning", "fixing") always, any other only when a cited note says it ("Reviewed" for
        // "Reviewing"): never "Explaining webhook retries" or "Reviewing code" from nothing.
        if let lead=words(text).first, lead.hasSuffix("ing"), lead.count > 4, !purposeVerbs.contains(lead), !corpusStems.contains(stem(lead)) {
            return ("verb","starts with \"\(lead)\", which no note it cites says. Say what it was for with the notes' own words, like \"writing the Q3 investor update\".")
        }
        var bad=[String]()
        for w in words(text) where claimWords.contains(w) && !corpusWords.contains(w) && !bad.contains(w) { bad.append(w) }
        if !bad.isEmpty {
            // Name the replacement: the 4B model repeats a refused verb when told only to keep the notes' verbs.
            let sends:Set<String>=["asked","emailed","texted","messaged","sent","replied","posted","submitted","searched"]
            let says=bad.map { "\"\($0)\"" }.joined(separator:" and ")
            let fixes=bad.map { w in "\(sends.contains(w) ? "\"wrote to\" or \"drafted\"" : "\"worked on\"") instead of \"\(w)\"" }.joined(separator:", ")
            return ("verb","says \(says), but no note it cites says that. Write \(fixes).")
        }
        // Names: a capitalized word that doesn't start a sentence must be in the cited notes.
        let pieces=text.components(separatedBy:CharacterSet(charactersIn:".!?:;"))
        for piece in pieces {
            let tokens=piece.components(separatedBy:CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"'’")).inverted).filter { !$0.isEmpty }
            for (i,t) in tokens.enumerated() where (i > 0 || !sentenceStart) && t.first?.isUppercase == true {
                let bare=stem(t).lowercased(), plain=t.lowercased().replacingOccurrences(of:"’s",with:"").replacingOccurrences(of:"'s",with:"")
                if nameOK.contains(plain) || corpusWords.contains(plain) || corpusStems.contains(bare) { continue }
                return ("name","names \"\(t)\", which is not in the notes it cites.")
            }
        }
        return nil
    }

    // MARK: salvage

    /// The note written by code from the children's own lines: always true, never new wording.
    public static func extractive(_ request:LevelRequest) -> (title:String,lines:[LevelLine]) {
        if threaded(request) { return threadNote(request) }
        func seconds(_ c:LevelChildView) -> Double {
            guard let s=timestamp(c.ref.start), let e=timestamp(c.ref.end) else { return 0 }; return e.timeIntervalSince(s)
        }
        let biggest=request.children.sorted { (seconds($0),$1.ref.start) > (seconds($1),$0.ref.start) }
        func gist(_ c:LevelChildView) -> String? {
            c.lines.first { !$0.hasPrefix("Also had") && !$0.hasPrefix("Had ") && !$0.hasPrefix("The Mac was") } ?? c.lines.first
        }
        var lines=[LevelLine]()
        for c in biggest where lines.count < min(request.level.maxLines,3) {
            if let g=gist(c), !lines.contains(where:{ $0.text == g }) { lines.append(LevelLine(text:g,children:[c.ref.id])) }
        }
        if lines.isEmpty, let c=biggest.first { lines=[LevelLine(text:c.title,children:[c.ref.id])] }
        let lead=biggest.first?.title ?? "Activity"
        switch request.level {
        case .block: return (MemoryStore.spanPhrase(start:request.start,end:request.end,timezone:request.timezone)+": "+lead,lines)
        default:
            // A parent's lines are its biggest children's titles (a block title, a day's headline).
            var parent=[LevelLine]()
            for c in biggest where parent.count < 3 {
                let t=c.title
                if !parent.contains(where:{ $0.text == t }) { parent.append(LevelLine(text:t,children:[c.ref.id])) }
            }
            let head=lead.contains(": ") ? String(lead.split(separator:":",maxSplits:1)[1]).trimmingCharacters(in:.whitespaces) : lead
            // A block's goal ("fixing the export crash") reads "Mostly fixing the export crash."; a day's headline is
            // already a sentence ("Mostly …" or "Rewrote the pricing FAQ …") and is kept as it is.
            let bare=head.trimmingCharacters(in:CharacterSet(charactersIn:". "))
            let lowerStart=bare.first.map { $0.isLowercase } ?? false
            return ((lowerStart ? "Mostly "+bare : bare)+".",parent)
        }
    }
    /// A block or day written by code from its threads: the title is the main thread's name (a block's with the
    /// code-written span in front: "About 2 hours: Q3 investor update"); the lines are the side threads with names and
    /// minutes ("Texts with Maya and Sam, ~15 min"). With no side thread, the main thread's own notes' first lines.
    public static func threadNote(_ request:LevelRequest) -> (title:String,lines:[LevelLine]) { threadNote(request,plain:false) }
    /// The code's note with no name read from a window title, a person or a subject (`LevelThreads.plainLabel`): the
    /// title is the main thread's app, site or kind, the lines the side threads the same way, or with none the main
    /// thread's own plain line. Used when the code's note would repeat a short typed draft (r1 levels-pipeline).
    public static func plainThreadNote(_ request:LevelRequest) -> (title:String,lines:[LevelLine]) { threadNote(request,plain:true) }
    static func threadNote(_ request:LevelRequest,plain:Bool) -> (title:String,lines:[LevelLine]) {
        guard let main=request.threads?.first else { var plain=request; plain.threads=nil; return extractive(plain) }
        // A site's name stays as written ("developer.apple.com"); anything else starts with a capital.
        var label=plain ? LevelThreads.plainLabel(main) : main.label
        // notes-quality: a one-moment block is named by its moment's note title, which already says what it was.
        if !plain, request.level == .block, request.children.count == 1, let t=request.children.first?.title, !t.isEmpty { label=t }
        // fix/sx-all round 2: a stretch that was mostly a video says so ("Watched Swift actors explained"), from its
        // moment's own line, never the site's name alone.
        if !plain, main.kind == "video", let watched=request.children.filter({ main.children.contains($0.ref.id) }).flatMap(\.lines).first(where:{ $0.hasPrefix("Watched ") }) {
            label=watched.trimmingCharacters(in:CharacterSet(charactersIn:". "))
        }
        let name=label.contains(" ") || !label.contains(".") ? ThreadEntities.capitalized(label) : label
        var title=request.level == .block ? MemoryStore.spanPhrase(start:request.start,end:request.end,timezone:request.timezone)+": "+name : name
        if !plain, request.level != .block, let kept=request.keptTitle, kept != title {
            // Today's day note between model headlines keeps the model's while it still holds.
            let head=kept.trimmingCharacters(in:CharacterSet(charactersIn:"."))
            if openOnly(head) == nil, sideProblem(head,request) == nil, problem(head,cited:mainViews(request),maxChars:120) == nil { title=kept }
        }
        let known=Set(request.children.map(\.ref.id))
        var lines=LevelThreads.bullets(request.threads!,max:LevelThreads.maxBullets(request.level),plain:plain).filter { $0.children.allSatisfy(known.contains) }
        // Plain: a side thread named like the main one ("Document" beside "Document") says nothing more.
        if plain { lines=lines.filter { !$0.text.hasPrefix(name+", ") } }
        if lines.isEmpty, plain {
            // The main thread alone: its plain name and minutes (the moments' own lines may repeat the draft too).
            var kids=main.children.filter(known.contains)
            if kids.isEmpty { kids=request.children.prefix(1).map(\.ref.id) }
            lines=[LevelLine(text:name+", "+LevelThreads.duration(main.seconds),children:kids,moments:request.level == .block ? kids : main.momentIDs)]
        }
        if lines.isEmpty {
            // The main thread alone: its notes' own first lines (true, already checked), the longest first.
            let kids=request.children.filter { main.children.contains($0.ref.id) }
            func seconds(_ c:LevelChildView) -> Double { (timestamp(c.ref.end) ?? .distantPast).timeIntervalSince(timestamp(c.ref.start) ?? .distantPast) }
            for c in kids.sorted(by: { (seconds($0),$1.ref.start) > (seconds($1),$0.ref.start) }) where lines.count < 2 {
                let gist=c.lines.first { !$0.hasPrefix("Also had") && !$0.hasPrefix("Had ") && !$0.hasPrefix("The Mac was") } ?? c.lines.first ?? c.title
                // The moments it is about: a block's line, its moment; a day's or week's, the main thread's moments in it.
                let moments=request.level == .block ? [c.ref.id] : main.momentIDs
                if !gist.isEmpty, !lines.contains(where:{ $0.text == gist }) { lines.append(LevelLine(text:gist,children:[c.ref.id],moments:moments)) }
            }
            if lines.isEmpty, let c=request.children.first { lines=[LevelLine(text:c.title,children:[c.ref.id],moments:request.level == .block ? [c.ref.id] : main.momentIDs)] }
        }
        return (title,lines)
    }
    /// The repair turn: the same evidence with the previous answer and what was wrong.
    public static func repair(_ request:LevelRequest,previous:String,problem:String) -> String {
        evidence(request)+"\n\nYour previous answer was thrown away.\nPrevious answer: "+String(previous.split(whereSeparator:\.isNewline).joined(separator:" ").prefix(600))+"\nProblem: "+problem+"\nWrite the whole JSON object again. Fix that problem and keep everything else that was right."
    }
}
