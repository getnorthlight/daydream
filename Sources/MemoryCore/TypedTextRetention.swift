import Foundation

// Safe typing D: the exact words are short-lived.
//
// - Words are hidden the moment they pass the kept period (read time), and
//   the expiry job deletes them from disk: at launch, hourly, and in every
//   `writePending`. It never waits for a summarizer.
// - What survives is a grounded note bullet that cites the draft and copies
//   at most 5 words in a row from it, or else a stub with a word count.
// - Once every draft of a UTC day is gone, that day's key is dropped from the
//   keyring, so any stray copy of its ciphertext can never be opened again.
// - "Forget what I typed" deletes every typed row, the notes that cite them
//   and the keyring, and turns typing off.

/// How many words in a row a note may copy from what the person typed
/// (case- and punctuation-insensitive):
/// - never more than `maxRun` (5);
/// - for short drafts less: 40% of the draft's words, at least 1, so a
///   search or prompt of a few words can't be carried whole into a note;
/// - a draft of one word may not appear at all.
/// Checked against each typed row and against a whole typing run (rows split
/// by idle time or size), so a copy across the split is caught too.
///
/// Guard v2 (summaries/v3, owner decision 3): names and numbers don't count.
/// Stop words, numbers, words written with a capital inside a sentence of the
/// draft, and the recipient or window name code read, neither count toward a
/// copied run nor break it; the whole-short-draft rule still counts every word.
/// Same rules as the writer's CanonicalGrounding.copyProblem (prompt4.py).
public enum TypedVerbatimGuard {
    public static let maxRun = 5
    /// Drafts of this many words or fewer may never appear whole.
    public static let shortDraft = 8

    /// Lowercased words; letters and digits only, apostrophes dropped
    /// ("Don't" -> "dont"), everything else separates words.
    public static func words(_ text: String, lower: Bool = true) -> [String] {
        var result = [String](), current = ""
        let normal = text.precomposedStringWithCompatibilityMapping
        for scalar in (lower ? normal.lowercased() : normal).unicodeScalars {
            if isWordScalar(scalar) { current.unicodeScalars.append(scalar) }
            else if scalar == "'" || scalar == "\u{2019}" { continue }
            else if !current.isEmpty { result.append(current); current = "" }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
    /// Python `str.isalnum`: letters (L*) and numbers (N*); combining marks separate words.
    static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return s.properties.numericType != nil
        }
    }
    /// Words that neither count toward a copied run nor break it (guard v2).
    public static let stopWords: Set<String> = Set(("a an the to of in on at for and or but is are was were be been am i you we me my your our it its this that these those "
        + "with about from by as so can will would could should do does did not no yes ok okay hi hey please thanks thank "
        + "just up if some any all get got have has had there here then than too also").split(separator: " ").map(String.init))
    static func startsUpper(_ w: String) -> Bool { w.unicodeScalars.first?.properties.isUppercase ?? false }
    /// Words written with a capital letter inside a sentence of `source` ("Sam", "Friday", "Tallybird"); a word that starts a
    /// sentence or is also written in lower case is not a name.
    public static func names(in source: String) -> Set<String> {
        let pieces = source.components(separatedBy: CharacterSet(charactersIn: ".!?:;\n")).map { words($0, lower: false) }
        let lower = Set(pieces.flatMap { $0 }.filter { !startsUpper($0) }.map { $0.lowercased() })
        return Set(pieces.flatMap { $0.dropFirst() }.filter(startsUpper).map { $0.lowercased() }).subtracting(lower)
    }
    /// The free words for a draft: stop words, its names, and the recipient or window name code read (`places`).
    public static func freeWords(source: String, places: [String] = []) -> Set<String> {
        stopWords.union(names(in: source)).union(places.flatMap { words($0) })
    }
    static func isNumber(_ w: String) -> Bool {
        if !w.isEmpty, w.unicodeScalars.allSatisfy({ $0.properties.numericType == .decimal || $0.properties.numericType == .digit }) { return true }
        return w.range(of: "^\\d+[a-z]{0,2}$", options: .regularExpression) != nil
    }
    /// (weighted, raw): the longest run of consecutive words `candidate` shares with `source`, counting only words not in
    /// `free` and not numbers (weighted), and counting every word (raw).
    public static func copiedRun(_ candidate: String, from source: String, free: Set<String>) -> (weighted: Int, raw: Int) {
        let a = words(candidate), b = words(source)
        guard !a.isEmpty, !b.isEmpty else { return (0, 0) }
        var previous = [(Int, Int)](repeating: (0, 0), count: b.count + 1), best = 0, rawBest = 0
        for i in 1...a.count {
            var row = [(Int, Int)](repeating: (0, 0), count: b.count + 1)
            for j in 1...b.count where a[i - 1] == b[j - 1] {
                let w = free.contains(a[i - 1]) || isNumber(a[i - 1]) ? 0 : 1
                row[j] = (previous[j - 1].0 + w, previous[j - 1].1 + 1)
                best = max(best, row[j].0); rawBest = max(rawBest, row[j].1)
            }
            previous = row
        }
        return (best, rawBest)
    }
    /// The longest run of consecutive words `candidate` shares with `source` (every word counts).
    public static func longestCopiedRun(_ candidate: String, from source: String) -> Int { copiedRun(candidate, from: source, free: []).raw }
    /// The most words in a row a note may copy from a draft of `n` words.
    public static func allowedRun(draftWords n: Int) -> Int { min(maxRun, max(1, Int(Double(n) * 0.4))) }
    /// Noun/qualifier overlap is considered separately from contiguous copying.
    /// Only complete short captured requests with distinct recipient authority qualify.
    static func summaryNouns(_ candidate:String,_ source:String,recipient:String?)->Set<String>? {
        guard let recipient,!recipient.isEmpty,!["unknown","[withheld]"].contains(recipient.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()),source.count<=400,!source.isEmpty,
              !source.contains("[withheld]"),!source.contains("…"),!source.contains("..."),
              !candidate.contains("\""),!candidate.contains("“"),!candidate.contains("”"),
              candidate.range(of:#"(?<![0-9]):|:(?![0-9])"#,options:.regularExpression)==nil else {return nil}
        let a=words(candidate),who=words(recipient)
        guard !who.isEmpty,who.count<=8 else {return nil}
        let leads=[["texted"],["emailed"],["drafted","a","text","to"],["drafted","a","message","to"],["drafted","an","email","to"]]
        guard let lead=leads.first(where:{a.starts(with:$0+who)}) else {return nil}
        let body=Array(a.dropFirst(lead.count+who.count))
        let transcript:Set<String>=["i","im","ive","id","ill","me","my","mine","we","our","ours","you","your","yours"]
        guard body.count>=5,body.count<=50,!body.contains(where:transcript.contains),
              ["that","about","asking","to"].contains(body.first ?? ""),
              body.contains(where:{["asked","asking","requested","requesting"].contains($0)}) else {return nil}
        let verbs="look over|point out|check|confirm|mark|flag|add|update|locate|suggest|review|inspect"
        func captures(_ pattern:String,_ text:String)->[[String]] {
            guard let rx=try? NSRegularExpression(pattern:pattern,options:.caseInsensitive) else {return []}
            return rx.matches(in:text,range:NSRange(text.startIndex...,in:text)).map {match in
                (1..<match.numberOfRanges).map {index in Range(match.range(at:index),in:text).map{String(text[$0])} ?? ""}
            }
        }
        var requests=captures("(?:^|[.;!?]\\s*|,\\s*)(?:please\\s+|(?:could|can|would|will)\\s+you\\s+)("+verbs+")\\s+([^.;!?]+)",source)
        // A bounded direct existence/availability inquiry supplies its own
        // object/time nouns. It never supplies a confirmed outcome.
        let directQuestions=captures(#"(?:^|[.;!?]\s*)(?:is|are)\s+there\s+([^.;!?]+)\?"#,source)
        requests += directQuestions.compactMap {$0.count==1 ? ["question",$0[0]]:nil}
        let availabilityQuestions=captures(#"(?:^|[.;!?]\s*)(?:is|are)\s+((?:the|this|that)\s+[^.;!?]+?)\s+(?:open|available)\s+([^.;!?]*)\?"#,source)
        requests += availabilityQuestions.compactMap {$0.count==2 ? ["question",$0.joined(separator:" ")]:nil}
        guard !requests.isEmpty,requests.count<=3 else {return nil}
        var nouns=Set<String>(),targets=0
        let declarationSource=source.replacingOccurrences(of:#"(?i)^I noticed that\s+"#,with:"",options:.regularExpression)
        let declaration=captures(#"^(?:the|this|that|my|our|a|an)\s+([\p{L}'’-]+(?:\s+[\p{L}'’-]+){0,4}?)\s+(?:still\s+)?(?:lacks?|(?:is|are|was|were)\s+(?:still\s+)?missing|lost)\s+([^.;!?]+)"#,declarationSource)
        if declaration.count==1 {
            let subject=words(declaration[0][0]),object=words(declaration[0][1])
            guard subject.count<=5,object.count<=6 else {return nil}
            nouns.formUnion(subject);nouns.formUnion(object)
        }
        let negativeSubject=captures(#"^(?:the|this|that|my|our|a|an)\s+([\p{L}'’-]+(?:\s+[\p{L}'’-]+){0,4}?)\s+(?:is|are|was|were)\s+(?:unavailable|not\s+[\p{L}]+)\b"#,source)
        if negativeSubject.count==1 {nouns.formUnion(words(negativeSubject[0][0]))}
        // Only the explicit uncertain plan's short object is a noun exemption;
        // modality, plan verbs and qualifiers are never freed.
        let plan=captures(#"(?:^|[.;!?]\s*)(?:I|we)\s+(?:might|may|could)\s+(?:try|apply|book|reserve|replace|visit|use|check|request|review|inspect|read|write|fix)\s+([^,.;!?]+)"#,source)
        for match in plan where match.count==1 {
            let object=words(match[0])
            guard object.count<=5,!object.contains(where:{["if","unless","whether","might","maybe","uncertain","unsure"].contains($0)}) else {return nil}
            nouns.formUnion(object)
        }
        for request in requests {
            guard request.count==2 else {return nil}
            let next=try? NSRegularExpression(pattern:"\\s+and\\s+(?=(?:"+verbs+")\\s+)",options:.caseInsensitive)
            let text=request[1],ranges=next?.matches(in:text,range:NSRange(text.startIndex...,in:text)) ?? []
            var pieces:[String]=[],from=text.startIndex
            for match in ranges {
                guard let range=Range(match.range,in:text) else {return nil}
                pieces.append(String(text[from..<range.lowerBound]));from=range.upperBound
            }
            pieces.append(String(text[from...]))
            for (index,piece) in pieces.enumerated() {
                var target=piece
                if index>0 {
                    guard let rx=try? NSRegularExpression(pattern:"^(?:"+verbs+")\\s+",options:.caseInsensitive),
                          let match=rx.firstMatch(in:piece,range:NSRange(piece.startIndex...,in:piece)),
                          let range=Range(match.range,in:piece) else {return nil}
                    target=String(piece[range.upperBound...])
                }
                let targetWords=words(target)
                guard !targetWords.isEmpty,targetWords.count<=6,
                      !targetWords.contains(where:{["whether","if","how","when","where","that","because"].contains($0)}) else {return nil}
                if request[0]=="question",targetWords.contains(where:{["no","not","never"].contains($0)}) {return nil}
                nouns.formUnion(targetWords);targets+=1
            }
        }
        guard targets>0,targets<=3 else {return nil}
        let predicates:Set<String>=["lack","lacks","missing","lost","unavailable","available","open","might","may","could","uncertain","unsure","book","reserve","apply","try","replace","visit","use","request","read","write","fix","check","confirm","mark","flag","add","update","locate","suggest","review","inspect","look","over","point","out"]
        nouns.subtract(stopWords);nouns.subtract(predicates)
        return nouns.isEmpty ? nil:nouns
    }

    /// True when `candidate` copies more than the draft allows (guard v2). `places`: the recipient and window name code read
    /// for the draft; `nameSource`: the text whose capitals count as names (the whole run, when the draft is one piece of it).
    public static func copies(_ candidate: String, from source: String, places: [String] = [], nameSource: String? = nil, summaryRecipient: String? = nil) -> Bool {
        let n = words(source).count
        guard n > 0 else { return false }
        let free = freeWords(source: nameSource ?? source, places: places)
        let run = copiedRun(candidate, from: source, free: free)
        // A new exception never inherits arbitrary window/title/name free words.
        // Keep the original contiguous limit independently with only function
        // words, numbers and the recorded recipient free.
        if let recipient=summaryRecipient,source.count<=400,
           copiedRun(candidate,from:source,free:stopWords.union(words(recipient))).weighted>allowedRun(draftWords:n) {return true}
        return run.weighted > allowedRun(draftWords: n) || (n <= shortDraft && run.raw >= n) || reworded(candidate, from: source, free: free, summaryRecipient: summaryRecipient)
    }
    /// fix/sx-all round 2: the typed sentence said again with its words kept and only small words changed ("Addressed
    /// Marco's comments and added a two-worker test." from "addressed marcos comments, added two worker test"): at least
    /// `rewordMin` content words typed (not stop words, names or numbers) and `rewordShare` of them in the note.
    public static let rewordMin = 5, rewordShare = 0.75
    public static func reworded(_ candidate: String, from source: String, free: Set<String>, summaryRecipient: String? = nil) -> Bool {
        let nounFree = summaryNouns(candidate, source, recipient: summaryRecipient) ?? []
        let content = Set(words(source).filter { !free.contains($0) && !nounFree.contains($0) && !isNumber($0) })
        guard content.count >= rewordMin else { return false }
        let said = Set(words(candidate))
        return Double(content.intersection(said).count) >= rewordShare * Double(content.count)
    }
    /// True when `candidate` copies too much from any of `sources`. Names are read from the longest source (the whole run).
    public static func copies(_ candidate: String, fromAny sources: [String], places: [String] = [], summaryRecipient: String? = nil) -> Bool {
        let nameSource = sources.max { words($0).count < words($1).count }
        return sources.contains { copies(candidate, from: $0, places: places, nameSource: nameSource, summaryRecipient: summaryRecipient) }
    }
    /// notes-quality: the rule for a unit's field. What was typed in Mail's To field is who the email went to, which a
    /// note names by design ("Emailed Sam about pricing"); a subject line names the thread (the compose window takes it as
    /// its title), so a note may say a short one whole but never more than `maxRun` of its words in a row. Every other
    /// field: `copies(_:fromAny:places:)`. The writer checks the same (CanonicalGrounding.copyProblem).
    public static func copies(_ candidate: String, fromAny sources: [String], places: [String] = [], field: String, summaryRecipient: String? = nil) -> Bool {
        switch field {
        case "to": return false
        case "subject":
            let nameSource = sources.max { words($0).count < words($1).count } ?? ""
            return sources.contains { copiedRun(candidate, from: $0, free: freeWords(source: nameSource, places: places)).weighted > maxRun }
        default: return copies(candidate, fromAny: sources, places: places, summaryRecipient: summaryRecipient)
        }
    }
}

/// Where one typed draft stands, without its words. Readable by every
/// process (no key needed): it comes from `typed_text` and `typed_after`.
public struct TypedStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// The words exist (they may still be hidden from this reader).
        case live
        /// Past the kept period: deleted, or hidden until the job deletes them.
        case expired
        /// The key was lost or the words can't be found; never coming back.
        case unavailable
    }
    public var state: State
    public var words: Int
    /// A grounded note bullet kept after expiry, or "" (stub).
    public var summary: String
    public var keptFor: TypedRetention
    /// Rows of one typing run (split by idle or size) share this.
    public var runID: String?
    public var part: Int?
    public init(state: State, words: Int, summary: String = "", keptFor: TypedRetention = .default, runID: String? = nil, part: Int? = nil) {
        self.state = state; self.words = words; self.summary = summary; self.keptFor = keptFor; self.runID = runID; self.part = part
    }
}

/// Plain-words lines for typed drafts (SPEC 1.2). Never quotes words unless
/// the caller passes them (the owner's own view).
public enum TypedLine {
    static func deleted(_ keptFor: TypedRetention) -> String {
        keptFor == .forever ? "exact words deleted" : "exact words deleted after \(keptFor.label)"
    }
    /// What AI apps and any reader without the words see. `usedSendKey` (fix/summary-sends QF-15): the row's send key was
    /// detected at seal time (state "submitted", the same fact `actions` reports); a gesture, never "sent" (no receipt).
    public static func withoutWords(app: String, status: TypedStatus, usedSendKey: Bool = false) -> String {
        let where_ = usedSendKey ? "\(app), then used its send key" : app
        switch status.state {
        case .live: return "Typed in \(where_), \(TypedWords.bucket(status.words)) (exact words not shared with AI apps)"
        case .expired:
            let summary = status.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            // N14: the kept line doesn't repeat itself. A line that already names the app stands alone; otherwise it
            // says where. No "summary;".
            if !summary.isEmpty {
                let line = summary.hasSuffix(".") ? String(summary.dropLast()) : summary
                let named = line.range(of: "\\b" + NSRegularExpression.escapedPattern(for: app) + "\\b", options: [.regularExpression, .caseInsensitive]) != nil
                return named ? "\(line) (\(deleted(status.keptFor)))" : "Typed in \(app): \(line) (\(deleted(status.keptFor)))"
            }
            return "Typed in \(where_), \(TypedWords.bucket(status.words)) (\(deleted(status.keptFor)))"
        case .unavailable: return "Typed in \(where_) (exact words no longer available)"
        }
    }
    /// The DayDream app's own view: the words while they exist and open.
    public static func owner(app: String, status: TypedStatus, words: String?) -> String {
        if status.state == .live {
            if let words, !words.isEmpty { return "Typed in \(app): “\(words)”" }
            return "Typed in \(app), \(TypedWords.bucket(status.words)) (exact words unavailable right now)"
        }
        return withoutWords(app: app, status: status)
    }
}

/// One displayed draft per typing run: consecutive typed rows with the same
/// runID are shown together. Storage (and expiry) stays per row.
public enum TypedDrafts {
    public static func group(_ actions: [CanonicalAction], status: (String) -> TypedStatus?) -> [[CanonicalAction]] {
        var groups = [[CanonicalAction]](), lastRun: String?
        for action in actions {
            let run = action.kind == "keyboard.text_input" ? status(action.id)?.runID : nil
            if let run, run == lastRun, !groups.isEmpty, groups[groups.count - 1].last?.app == action.app { groups[groups.count - 1].append(action) }
            else { groups.append([action]) }
            lastRun = run
        }
        return groups
    }
    /// The status of a whole run: words add up; the run is live only if every
    /// row is, expired only if every row is (the first kept summary wins);
    /// anything else reads as unavailable. Never the words.
    public static func combined(_ parts: [TypedStatus]) -> TypedStatus? {
        guard let first = parts.first else { return nil }
        guard parts.count > 1 else { return first }
        var result = first
        result.words = parts.reduce(0) { $0 + $1.words }
        if parts.allSatisfy({ $0.state == .live }) { result.state = .live; result.summary = "" }
        else if parts.allSatisfy({ $0.state == .expired }) { result.state = .expired; result.summary = parts.first { !$0.summary.isEmpty }?.summary ?? "" }
        else { result.state = .unavailable; result.summary = "" }
        return result
    }
}

public struct TypedExpiryReport: Codable, Equatable, Sendable {
    /// Drafts whose exact words were deleted in this run.
    public var expired = 0
    /// Of those, how many kept a note bullet; the rest kept a stub.
    public var keptNotes = 0
    /// Sealed rows whose record was already gone (deleted outright).
    public var orphans = 0
    /// Day keys removed from the keyring (crypto-shred).
    public var droppedKeys = [String]()
    /// A key drop or Forget waits for an unlocked Keychain or the app.
    public var keyDropPending = false
    /// Notes removed because they copy more of an expiring draft than the
    /// verbatim guard allows (they would outlive the words).
    public var removedNotes = 0
    /// Build 4 plain-text drafts past the period whose words were deleted.
    public var legacyExpired = 0
    public init() {}
}

public struct TypedForgetReport: Codable, Equatable, Sendable {
    public var deletedDrafts = 0
    public var deletedNotes = 0
    /// False when this process has no key or the Keychain is locked: the
    /// keyring is deleted the next time the app can.
    public var keyringDeleted = false
}

private struct TypedForgetPending: Codable { var requestedAt: String }

extension MemoryStore {
    static let typedForgetPendingID = "typed-forget-pending-v1"

    /// The earlier (shorter) of the typed-words period and whole-history
    /// retention wins. nil keeps words.
    public func typedCutoff(now: Date = Date()) throws -> Date? {
        let typed = try typedTextPolicy().retention.cutoff(now: now)
        let history = try policy().retention.cutoff(now: now)
        switch (typed, history) {
        case (.some(let a), .some(let b)): return max(a, b)
        case (.some(let a), .none): return a
        case (.none, .some(let b)): return b
        default: return nil
        }
    }
    func typedExpired(createdAt: String, now: Date) throws -> Bool {
        guard let at = timestamp(createdAt) else { return true }
        return try typedCutoff(now: now).map { at < $0 } ?? false
    }
    /// `now`, or the latest clock any DayDream process already used for
    /// typed words if that is later: words once hidden are never shown again
    /// because the clock went back, and the next expiry run deletes them.
    /// The high-water is kept in `metadata` (`typed-clock-v1`) so it holds
    /// across launches: each store instance reads it once, and a writable one
    /// saves it again whenever it has moved on by a minute or more.
    func typedClock(_ now: Date) -> Date {
        lock.lock(); defer { lock.unlock() }
        if typedClockSeen == nil { typedClockStored = savedTypedClock(); typedClockSeen = typedClockStored; typedClockResetSeen = savedTypedClockReset()?.body }
        // Review G44: far behind what this instance saw, follow a clock the app brought back after this
        // instance started (`resetTypedClock`), once, and only when the reset covered this instance's own
        // high-water: every word it hid was deleted then. A clock that only went back changes nothing.
        if let seen = typedClockSeen, seen.timeIntervalSince(now) > Self.typedClockResetSlack,
           let reset = savedTypedClockReset(), reset.body != typedClockResetSeen {
            typedClockResetSeen = reset.body
            if seen <= reset.from, let saved = savedTypedClock(), saved < seen { typedClockSeen = saved; typedClockStored = saved }
        }
        let seen = max(now, typedClockSeen ?? now)
        typedClockSeen = seen
        if writable, seen.timeIntervalSince(typedClockStored ?? .distantPast) >= Self.typedClockSaveStep { saveTypedClock(seen) }
        return seen
    }
    static let typedClockID = "typed-clock-v1"
    static let typedClockSaveStep: TimeInterval = 60
    /// The saved high-water, or nil. Unreadable text reads as nil.
    func savedTypedClock() -> Date? {
        guard let raw = try? rows("SELECT body FROM metadata WHERE id=?", [Self.typedClockID]).first?.first else { return nil }
        return timestamp(raw)
    }
    /// Saves the high-water unless a later one is stored already (another
    /// process). Best effort: a failed write keeps the in-memory value.
    func saveTypedClock(_ seen: Date) {
        if let stored = savedTypedClock(), stored >= seen { typedClockStored = stored; return }
        if (try? exec("INSERT OR REPLACE INTO metadata VALUES(?,?)", [Self.typedClockID, isoPrecise(seen)])) != nil { typedClockStored = seen }
    }
    /// A wall clock this far behind the high-water's cutoff means a clock
    /// that ran ahead was set back (see `expireTypedText`).
    static let typedClockResetSlack: TimeInterval = 3600
    /// Brings the high-water back to the wall clock (review G44: a Mac clock
    /// once set ahead kept every new word a stub, and deleted words early,
    /// until real time caught up). Only `expireTypedText` calls this, right
    /// after it deleted every word the later clock hid. Best effort, like
    /// `saveTypedClock`: a failed write keeps the later clock, and the next
    /// run tries again.
    func resetTypedClock(to wall: Date) {
        guard let from = typedClockSeen else { return }
        // The marker names the high-water this reset replaced; other instances follow it once (`typedClock`).
        let marker = isoPrecise(from) + " " + isoPrecise(wall)
        let saved: Bool? = try? transaction {
            try exec("INSERT OR REPLACE INTO metadata VALUES(?,?)", [Self.typedClockID, isoPrecise(wall)])
            try exec("INSERT OR REPLACE INTO metadata VALUES(?,?)", [Self.typedClockResetID, marker])
            return true
        }
        if saved == true { typedClockStored = wall; typedClockSeen = wall; typedClockResetSeen = marker }
    }
    static let typedClockResetID = "typed-clock-reset-v1"
    /// The last reset: the high-water it replaced, and the marker text. Unreadable text reads as nil.
    func savedTypedClockReset() -> (from: Date, body: String)? {
        guard let body = try? rows("SELECT body FROM metadata WHERE id=?", [Self.typedClockResetID]).first?.first,
              let first = body.split(separator: " ").first, let from = timestamp(String(first)) else { return nil }
        return (from, body)
    }

    /// Deletes exact words past the kept period, keeps a summary or stub, and
    /// drops day keys whose day is fully gone. Safe to run often; it never
    /// waits for a summarizer and never needs the network. Processes without
    /// a key still delete words (with stubs); the key drop then waits for the app.
    @discardableResult public func expireTypedText(now wall: Date = Date()) throws -> TypedExpiryReport {
        try expireTypedTextImplementation(now:wall,preservingNarrative:false)
    }
    @discardableResult func expireTypedTextForSummaryMaintenance(now wall:Date) throws -> TypedExpiryReport {
        try observingTypedNarrativeMaintenance(now:wall) {try expireTypedTextImplementation(now:wall,preservingNarrative:true)}
    }
    private func expireTypedTextImplementation(now wall:Date,preservingNarrative:Bool) throws -> TypedExpiryReport {
        lock.lock(); defer { lock.unlock() }
        let changes=typedNarrativeMutationCount()
        var completed=false
        defer {if !completed {discardTypedNarrativeCarry()}}
        if try !preservingNarrative || !typedNarrativeMaintenanceAllowed(now:wall) {discardTypedNarrativeCarry()}
        var report = TypedExpiryReport()
        guard writable, try hasTypedTables() else { return report }
        let now = typedClock(wall)
        if try retryPendingTypedForget() { report.keyDropPending = true }
        let cutoff = try typedCutoff(now: now)
        // Build 4 wrote typed words in plain text. Past the period they are
        // deleted like sealed words (a stub stays); this needs no key.
        if let cutoff, !legacyTypedClear { report.legacyExpired = try stubLegacyTypedText(before: cutoff, now: now) }
        var due = [(id: String, orphan: Bool)]()
        for row in try rows("SELECT t.id,t.created_at,(SELECT count(*) FROM records r WHERE r.id=t.id) FROM typed_text t ORDER BY t.id") {
            let orphan = row[2] == "0"
            if orphan || (timestamp(row[1]).map { at in cutoff.map { at < $0 } ?? false } ?? true) { due.append((row[0], orphan)) }
        }
        // Summaries are picked first. The words are opened in memory only, to
        // run the verbatim guard; without a ready vault every draft gets a stub.
        var summaries = [String: String]()
        var failingNotes = Set<[String]>()
        for item in due where !item.orphan {
            guard let words = try openTypedForGuard(item.id) else { continue }
            let run = try typedRunText(for: item.id)
            if let bullet = try noteSummary(for: item.id, words: words, run: run, places: try typedPlaces(for: item.id)) { summaries[item.id] = bullet }
            // Notes outlive the words: a note that copies too much of this
            // draft (checked again with today's rule) goes with the words.
            failingNotes.formUnion(try notesCopying(item.id, sources: [words] + (run.map { [$0] } ?? []), places: try typedPlaces(for: item.id)))
        }
        if !due.isEmpty {
            try transaction {
                for item in due {
                    if item.orphan {
                        try exec("DELETE FROM typed_text WHERE id=?", [item.id]); try dropTypedRecipients([item.id]); report.orphans += 1; continue
                    }
                    let summary = summaries[item.id] ?? ""
                    try moveTypedToAfterWithinTransaction(item.id, summary: summary, source: summary.isEmpty ? "stub" : "note", now: now)
                    try exec("DELETE FROM summaries WHERE id=?", [item.id])
                    try blankPendingNoteRequests(citing: item.id)
                    report.expired += 1; if !summary.isEmpty { report.keptNotes += 1 }
                }
                for note in failingNotes.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                    // A block written from a note that copies the words goes too (and what was written from it).
                    if let raw = try rows("SELECT body FROM generated_notes WHERE id=? AND version=?", note).first?.first,
                       let ids = try? decode(GeneratedNote.self, raw).actionIDs { try dropLevels(forActions: ids) }
                    try exec("DELETE FROM generated_notes WHERE id=? AND version=?", note); report.removedNotes += 1
                }
                try invalidateDisclosure(invalidateSnapshots: false)
            }
        }
        // fix/r1-writer: no recipient outlives its words, whatever removed them.
        try dropOrphanTypedRecipients()
        let drop = dropEmptyDayKeys(cutoff: cutoff, now: now)
        report.droppedKeys = drop.dropped
        report.keyDropPending = report.keyDropPending || drop.pending
        // Review G44: a clock that ran ahead and was set back. Once the
        // high-water's cutoff has passed the wall clock, every word typed now
        // would be a stub on arrival until real time caught up. Every word
        // that later clock hid was deleted above (and its day key dropped), so
        // the high-water returns to the wall clock without reopening anything.
        // Only the process holding the vault does this, after the key drop.
        if let cutoff, cutoff > wall.addingTimeInterval(-Self.typedClockResetSlack), attachedVault != nil, !drop.pending {
            resetTypedClock(to: wall)
        }
        if try typedNarrativeMutationCount() != changes || report != TypedExpiryReport() || !typedNarrativeMaintenanceAllowed(now:wall) {discardTypedNarrativeCarry()}
        completed=true
        return report
    }

    /// Writer requests still waiting for a note lose their input. Committed
    /// requests already keep no actions for typed rows (see commitNote), and
    /// their notes survive expiry because the record never changes.
    func blankPendingNoteRequests(citing id: String) throws {
        guard try hasActionLayers() else { return }
        try exec("UPDATE note_requests SET state='invalidated',body='' WHERE state='pending' AND body<>'' AND EXISTS (SELECT 1 FROM json_each(note_requests.body,'$.actionIDs') WHERE value=?)", [id])
    }

    /// Opens words for the verbatim guard, in this process only. nil when
    /// this process has no ready vault or the row doesn't open.
    func openTypedForGuard(_ id: String) throws -> String? {
        guard let vault = attachedVault, vault.state == .ready,
              let row = try rows("SELECT epoch,sealed FROM typed_text WHERE id=?", [id]).first,
              let sealed = Data(base64Encoded: row[1]) else { return nil }
        return try? vault.open(sealed, id: id, epoch: row[0])
    }

    /// summaries/v3: a typed row's seal facts (surface, send, sendBy, to, pasted, runID). Metadata only, never words; nil for a
    /// row that isn't typed or has no provenance.
    /// fix/r1-writer: an email unit's recipient (typed in Mail's To field) is sealed with the words and comes back only
    /// while they are kept and only for a reader the typed-words disclosure allows (`disclosure`; none by default): the
    /// writer on this Mac while typing is on, the cloud writer only while cloud summaries and typing are both on.
    public func typedUnit(_ id: String, disclosure: TypedDisclosure = .summary) throws -> TypedUnitProvenance? {
        guard let json = try rows("SELECT coalesce(json_extract(body,'$.captureProvenance.unit'),'') FROM records WHERE id=?", [id]).first?.first,
              !json.isEmpty else { return nil }
        guard var unit = try? JSONDecoder().decode(TypedUnitProvenance.self, from: Data(json.utf8)) else { return nil }
        // A plain-text recipient an earlier test build left in the record is never handed on.
        if unit.surface == "email" { unit.to = try typedDisclosureAllows(disclosure, reader: nil) ? typedRecipient(id) : nil }
        // B2: writer metadata must obey the same recipient proof as grouping
        // and canonical titles, including records from an earlier build.
        // claude/messages2-1003: or, for a proven message box, the number or address its own window title showed
        // (`MessagesMomentIdentity.conversation`); the writer names it in code, never in a model's input.
        if unit.surface == "text" {
            // The title as the current policy shows it (a withheld title names nobody).
            let title = try permittedOriginal(id, now: Date())?.title ?? ""
            unit.to = MessagesMomentIdentity.conversation(unit, title: title)
        }
        return unit
    }
    /// Guard v2: the recipient and window title code read for a typed row (never its words); they don't count as copied.
    /// notes-quality: a typed row's field class (`captureProvenance.unit.field`: to, subject, body, ...), or "".
    func typedField(for id: String) throws -> String {
        try rows("SELECT coalesce(json_extract(body,'$.captureProvenance.unit.field'),'') FROM records WHERE id=?", [id]).first?.first ?? ""
    }
    func typedPlaces(for id: String) throws -> [String] {
        guard let row = try rows("SELECT coalesce(json_extract(body,'$.captureProvenance.unit.to'),''),coalesce(json_extract(body,'$.title'),'') FROM records WHERE id=?", [id]).first else { return [] }
        return (row + [try typedRecipient(id, forGuard: true) ?? ""]).filter { !$0.isEmpty }
    }
    /// Distinct from typedPlaces: a window title is never recipient authority.
    /// Split, legacy or mixed runs keep the original copy policy.
    func typedSummaryRecipient(for id:String) throws->String? {
        guard let raw=try rows("SELECT coalesce(json_extract(body,'$.captureProvenance.unit'),'') FROM records WHERE id=?",[id]).first?.first,
              let unit=try? JSONDecoder().decode(TypedUnitProvenance.self,from:Data(raw.utf8)),
              unit.version==TypedUnitProvenance.sendFactsVersion,unit.part==1,unit.withheld==0,!unit.runID.isEmpty,
              (unit.surface=="text" && unit.field=="message") || (unit.surface=="email" && unit.field=="body"),
              try rows("SELECT count(*) FROM records WHERE json_extract(body,'$.captureProvenance.unit.runID')=?",[unit.runID]).first?.first=="1" else {return nil}
        let recipient=unit.surface=="email" ? try typedRecipient(id,forGuard:true):unit.to
        guard let recipient else {return nil}
        let normalized=recipient.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !normalized.isEmpty,!["unknown","[withheld]"].contains(normalized.lowercased()) else {return nil}
        return normalized
    }

    /// The whole typing run `id` belongs to, in order, when it has more than
    /// one sealed row that opens here; nil otherwise.
    func typedRunText(for id: String) throws -> String? {
        guard let run = try rows("SELECT coalesce(json_extract(body,'$.captureProvenance.unit.runID'),'') FROM records WHERE id=?", [id]).first?.first, !run.isEmpty else { return nil }
        let parts = try rows("""
            SELECT t.id FROM typed_text t JOIN records r ON r.id=t.id
            WHERE json_extract(r.body,'$.captureProvenance.unit.runID')=?
            ORDER BY coalesce(json_extract(r.body,'$.captureProvenance.unit.part'),0), t.created_at, t.id
            """, [run]).map { $0[0] }
        guard parts.count > 1 else { return nil }
        let texts = try parts.compactMap { try openTypedForGuard($0) }
        return texts.count > 1 ? texts.joined(separator: " ") : nil
    }
    /// (id, version) of generated notes citing `id` whose title or a bullet
    /// copies too much from any of `sources`.
    func notesCopying(_ id: String, sources: [String], places: [String] = []) throws -> Set<[String]> {
        guard try hasActionLayers() else { return [] }
        let field = try typedField(for: id)
        let summaryRecipient=try typedSummaryRecipient(for:id)
        var out = Set<[String]>()
        for row in try rows("SELECT id,version,body FROM generated_notes WHERE EXISTS (SELECT 1 FROM json_each(generated_notes.body,'$.actionIDs') WHERE value=?)", [id]) {
            guard let note = try? decode(GeneratedNote.self, row[2]) else { out.insert([row[0], row[1]]); continue }
            let texts = [note.output.title] + note.output.bullets.map(\.text)
            if texts.contains(where: { TypedVerbatimGuard.copies($0, fromAny: sources, places: places, field: field, summaryRecipient: summaryRecipient) }) { out.insert([row[0], row[1]]) }
        }
        return out
    }

    /// The best note bullet that cites this draft and may outlive its words:
    /// fewest cited actions first, at most 240 characters, nothing that looks
    /// like a secret, and no more copied from the draft (or its whole run)
    /// than `TypedVerbatimGuard` allows.
    func noteSummary(for id: String, words: String, run: String? = nil, places: [String] = []) throws -> String? {
        guard try hasActionLayers() else { return nil }
        let field = try typedField(for: id)
        let summaryRecipient=try typedSummaryRecipient(for:id)
        var bullets = [NoteBullet]()
        for row in try rows("SELECT body FROM generated_notes WHERE EXISTS (SELECT 1 FROM json_each(generated_notes.body,'$.actionIDs') WHERE value=?)", [id]) {
            guard let note = try? decode(GeneratedNote.self, row[0]) else { continue }
            bullets += note.output.bullets.filter { $0.actionIDs.contains(id) }
        }
        bullets.sort { ($0.actionIDs.count, $0.text.count, $0.text) < ($1.actionIDs.count, $1.text.count, $1.text) }
        for bullet in bullets {
            let text = bullet.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 240, !Privacy.secret(text),
                  case .keep(let kept, let redactions) = TypedSecretScrubber.scrub(text), redactions.isEmpty, kept == text,
                  !TypedVerbatimGuard.copies(text, fromAny: [words] + (run.map { [$0] } ?? []), places: places, field: field, summaryRecipient: summaryRecipient) else { continue }
            return text
        }
        return nil
    }

    /// Crypto-shred: removes every day key with no sealed row left whose whole
    /// UTC day is before the cutoff (or, when words are kept forever, ended
    /// more than a day ago). A locked Keychain retries on the next run.
    func dropEmptyDayKeys(cutoff: Date?, now: Date) -> (dropped: [String], pending: Bool) {
        guard let vault = attachedVault, vault.state != .unavailable else { return ([], false) }
        guard vault.state == .ready else { return ([], vault.state == .locked) }
        guard let live = try? Set(rows("SELECT DISTINCT epoch FROM typed_text").map { $0[0] }) else { return ([], true) }
        let threshold = cutoff ?? now.addingTimeInterval(-86400)
        let drop = vault.epochs.filter { epoch in
            guard !live.contains(epoch), let start = Self.epochStart(epoch) else { return false }
            return start.addingTimeInterval(86400) <= threshold
        }
        guard !drop.isEmpty else { return ([], false) }
        do { try vault.dropKeys(drop); return (drop.sorted(), false) } catch { return ([], true) }
    }
    static func epochStart(_ epoch: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: epoch)
    }

    /// Verbatim guard at note commit: the title and every bullet may copy no
    /// more than `TypedVerbatimGuard` allows from any typed draft the note
    /// covers, or from the whole typing run such a draft belongs to.
    /// - A process without a key (CLI, MCP) can't have shown words to its
    ///   writer, so there is nothing to check.
    /// - A process whose vault is locked refuses the note until it can check.
    /// The refusal `typedVerbatimGuard` throws (the level writer falls back to a plain note on it).
    public static let typedCopyRefusal = "A note may not copy what the person typed: at most \(TypedVerbatimGuard.maxRun) words in a row, fewer for short drafts, and never a whole short draft."
    func typedVerbatimGuard(texts: [String], actionIDs: [String]) throws {
        guard try hasTypedTables(), try citesTypedText(actionIDs) else { return }
        let sealed = try rows("SELECT id FROM typed_text WHERE id IN (SELECT value FROM json_each(?)) ORDER BY id", [json(actionIDs)])
        guard !sealed.isEmpty, let vault = attachedVault, vault.state != .unavailable else { return }
        guard vault.state == .ready else { throw MemError.invalid("The typed words this note covers can't be checked while the Keychain is locked. Try again after unlocking the Mac.") }
        for row in sealed {
            guard let words = try openTypedForGuard(row[0]) else { continue }
            let sources = [words] + (try typedRunText(for: row[0]).map { [$0] } ?? [])
            let places = try typedPlaces(for: row[0]), field = try typedField(for: row[0]), summaryRecipient=try typedSummaryRecipient(for:row[0])
            for text in texts where TypedVerbatimGuard.copies(text, fromAny: sources, places: places, field: field, summaryRecipient: summaryRecipient) {
                throw MemError.invalid(Self.typedCopyRefusal)
            }
        }
    }

    // MARK: Status for presentation (no key needed)

    /// Where each typed draft stands. Ids that are not typed rows are left out.
    public func typedStatuses(_ ids: [String], now: Date = Date()) throws -> [String: TypedStatus] {
        guard !ids.isEmpty, try hasTypedTables() else { return [:] }
        let keptFor = try typedTextPolicy().retention
        var result = [String: TypedStatus]()
        for row in try rows("""
            SELECT r.id,coalesce(json_extract(r.body,'$.typed.words'),0),coalesce(json_extract(r.body,'$.captureProvenance.unit.runID'),''),
                   coalesce(json_extract(r.body,'$.captureProvenance.unit.part'),''),t.created_at,a.words,a.summary,a.source,
                   (t.id IS NOT NULL),(a.id IS NOT NULL)
            FROM records r LEFT JOIN typed_text t ON t.id=r.id LEFT JOIN typed_after a ON a.id=r.id
            WHERE r.id IN (SELECT value FROM json_each(?)) AND json_extract(r.body,'$.typed') IS NOT NULL
            """, [json(ids)]) {
            var status = TypedStatus(state: .unavailable, words: Int(row[1]) ?? 0, keptFor: keptFor, runID: row[2].isEmpty ? nil : row[2], part: Int(row[3]))
            if row[8] == "1" {
                status.state = try typedExpired(createdAt: row[4], now: now) ? .expired : .live
            } else if row[9] == "1" {
                status.words = Int(row[5]) ?? status.words
                if row[7] == "note" || row[7] == "stub" { status.state = .expired; status.summary = row[7] == "note" ? row[6] : "" }
            }
            result[row[0]] = status
        }
        return result
    }
    /// A lazy per-id lookup for presentation code (`AssistantView.decorate`).
    public func typedStatusLookup(now: Date = Date()) -> (String) -> TypedStatus? {
        { [weak self] id in (try? self?.typedStatuses([id], now: now))?[id] }
    }

    // MARK: Forget

    /// "Forget what I typed": deletes every typed draft (sealed, stubbed or
    /// build 4 plain text), the notes and writer requests that cite them, and
    /// the keyring, and turns typing off (consent 0). Needs `confirmed: true`.
    /// Without a key in this process, or with the Keychain locked, the
    /// keyring is deleted the next time the app attaches its vault.
    @discardableResult public func forgetTypedText(confirmed: Bool, now: Date = Date()) throws -> TypedForgetReport {
        lock.lock(); defer { lock.unlock() }
        guard confirmed else { throw MemError.invalid("Delete everything DayDream saved from your typing, including summaries? This can't be undone. Confirm first.") }
        guard writable, try hasTypedTables() else { throw MemError.denied }
        var report = TypedForgetReport()
        try transaction {
            let ids = try rows("""
                SELECT id FROM records WHERE json_extract(body,'$.kind')='keyboard.text_input'
                UNION SELECT id FROM typed_text UNION SELECT id FROM typed_after
                """).map { $0[0] }
            // fix/r1-writer: every typed recipient goes with the words.
            if try hasTypedRecipients() { try exec("DELETE FROM typed_recipients") }
            let notesBefore = try hasActionLayers() ? Int(try rows("SELECT count(*) FROM generated_notes").first?.first ?? "0") ?? 0 : 0
            for id in ids {
                try dropTypedDerivatives(id)
                if try !rows("SELECT id FROM records WHERE id=?", [id]).isEmpty { try deleteActionWithinTransaction(id); report.deletedDrafts += 1 }
                try deleteTypedWithinTransaction(id)
            }
            try forgetTypedLevels()
            report.deletedNotes = notesBefore - (try hasActionLayers() ? Int(try rows("SELECT count(*) FROM generated_notes").first?.first ?? "0") ?? 0 : 0)
            var policy = try typedTextPolicy()
            policy.consentVersion = 0; policy.acceptedAt = ""; policy.acceptedScope = nil; policy.snoozeUntil = ""
            // Forget turns typing off: it must work while the Keychain is locked too (review G43).
            try saveTypedTextPolicyWithinTransaction(policy, unsignedWhileLocked: true)
            try exec("DELETE FROM metadata WHERE id='typed-vault-v1'")
            // No AI app keeps exact-word access (the new keyring would void it anyway).
            try stripTypedExactGrantsWithinTransaction()
            try exec("INSERT OR REPLACE INTO metadata VALUES(?,?)", [Self.typedForgetPendingID, json(TypedForgetPending(requestedAt: iso(now)))])
            try exec("DELETE FROM receipts")
            try invalidateDisclosure()
        }
        report.keyringDeleted = try !retryPendingTypedForget()
        scheduleSearchRefresh()
        return report
    }

    /// Finishes a Forget: deletes the keyring when this process can. Returns
    /// true while it is still pending.
    @discardableResult func retryPendingTypedForget() throws -> Bool {
        guard writable, try !rows("SELECT id FROM metadata WHERE id=?", [Self.typedForgetPendingID]).isEmpty else { return false }
        guard let vault = attachedVault, vault.state != .unavailable else { return true }
        do { try vault.destroy() } catch { return true }
        try exec("DELETE FROM metadata WHERE id=?", [Self.typedForgetPendingID])
        return false
    }
    /// True while a Forget still has to delete the keyring.
    public func typedForgetPending() throws -> Bool {
        try !rows("SELECT id FROM metadata WHERE id=?", [Self.typedForgetPendingID]).isEmpty
    }
}
