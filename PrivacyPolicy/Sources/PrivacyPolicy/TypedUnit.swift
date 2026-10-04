import Foundation

/// Field-agnostic edit operations. The native adapter derives them from key
/// code and modifiers before any characters are read; a browser adapter can
/// derive the same operations from InputEvent.inputType. Only insert has text.
public enum TypingOp: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public enum Unit: Sendable { case character, word, line }
    case insert(String)
    case deleteBackward(Unit)
    case deleteForward(Unit)
    case moveBackward(Unit, extend: Bool)
    case moveForward(Unit, extend: Bool)
    case cutSelection
    public var description:String {"TypingOp(redacted)"}
    public var customMirror:Mirror {Mirror(self,children:[:])}
}

/// The contiguous run typed into one field, rebuilt without reading the field.
/// The caret and selection move inside the run; deletes and Option-word moves
/// are applied. Deleting past the start of the run changes nothing here (the
/// text before the run was never ours). `.outside` means the caret or the
/// selection would leave the run, so the unit must be committed first.
/// Every character carries the chunk it was typed in.
public struct TextEditModel: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public enum Result: Equatable, Sendable { case applied, outside }
    public var description:String {"TextEditModel(redacted)"}
    public var customMirror:Mirror {Mirror(self,children:[:])}
    public private(set) var characters:[Character]=[]
    public private(set) var tags:[Int]=[]
    public private(set) var cursor=0
    public private(set) var anchor:Int?
    /// UTF-8 size of `characters`, kept incrementally (checked on every key).
    public private(set) var utf8Count=0
    public init() {}
    public var text:String {String(characters)}
    public var selection:Range<Int>? {
        guard let anchor,anchor != cursor else {return nil}
        return min(anchor,cursor)..<max(anchor,cursor)
    }
    public var caretAtEnd:Bool {selection == nil && cursor == characters.count}
    static func isWord(_ c:Character) -> Bool {c.isLetter || c.isNumber || c == "_" || c == "'" || c == "\u{2019}"}
    /// Start of the previous word; `edge` means the scan reached the start of
    /// the run, so the real word may continue into text typed before it.
    func wordStart(_ i:Int) -> (Int,edge:Bool) {
        var j=i
        while j>0,!Self.isWord(characters[j-1]) {j-=1}
        while j>0,Self.isWord(characters[j-1]) {j-=1}
        return (j,j==0)
    }
    func wordEnd(_ i:Int) -> (Int,edge:Bool) {
        var j=i
        while j<characters.count,!Self.isWord(characters[j]) {j+=1}
        while j<characters.count,Self.isWord(characters[j]) {j+=1}
        return (j,j==characters.count)
    }
    private mutating func remove(_ r:Range<Int>) {
        anchor=nil
        guard !r.isEmpty else {return}
        utf8Count-=characters[r].reduce(0) {$0+$1.utf8.count}
        characters.removeSubrange(r);tags.removeSubrange(r);cursor=r.lowerBound
    }
    public mutating func apply(_ op:TypingOp,chunk:Int=0) -> Result {
        switch op {
        case .insert(let s):
            let new=Array(s)
            utf8Count+=s.utf8.count
            if let sel=selection {
                utf8Count-=characters[sel].reduce(0) {$0+$1.utf8.count}
                characters.replaceSubrange(sel,with:new);tags.replaceSubrange(sel,with:Array(repeating:chunk,count:new.count))
                cursor=sel.lowerBound+new.count
            } else {
                characters.insert(contentsOf:new,at:cursor);tags.insert(contentsOf:Array(repeating:chunk,count:new.count),at:cursor)
                cursor+=new.count
            }
            anchor=nil;return .applied
        case .cutSelection:
            guard let sel=selection else {return .outside}
            remove(sel);return .applied
        case .deleteBackward(let unit):
            if let sel=selection {remove(sel);return .applied}
            let start:Int
            switch unit {
            case .character: start=max(0,cursor-1)
            case .word: start=wordStart(cursor).0
            case .line: start=characters[..<cursor].lastIndex(of:"\n").map {$0+1} ?? 0
            }
            remove(start..<cursor);return .applied
        case .deleteForward(let unit):
            if let sel=selection {remove(sel);return .applied}
            let end:Int
            switch unit {
            case .character: end=min(characters.count,cursor+1)
            case .word: end=wordEnd(cursor).0
            case .line: // Ctrl-K deletes to the end of the paragraph.
                if cursor<characters.count,characters[cursor] == "\n" {end=cursor+1}
                else {end=characters[cursor...].firstIndex(of:"\n") ?? characters.count}
            }
            remove(cursor..<end);return .applied
        case .moveBackward(let unit,let extend):
            if !extend,let sel=selection,unit == .character {cursor=sel.lowerBound;anchor=nil;return .applied}
            let origin=(!extend ? selection?.lowerBound : nil) ?? cursor
            let target:Int
            switch unit {
            case .character: guard origin>0 else {return .outside};target=origin-1
            case .word: let w=wordStart(origin);guard !w.edge else {return .outside};target=w.0
            case .line: return .outside
            }
            anchor=extend ? (anchor ?? cursor) : nil;cursor=target;return .applied
        case .moveForward(let unit,let extend):
            if !extend,let sel=selection,unit == .character {cursor=sel.upperBound;anchor=nil;return .applied}
            let origin=(!extend ? selection?.upperBound : nil) ?? cursor
            let target:Int
            switch unit {
            case .character: guard origin<characters.count else {return .outside};target=origin+1
            case .word: let w=wordEnd(origin);guard !w.edge else {return .outside};target=w.0
            case .line: return .outside
            }
            anchor=extend ? (anchor ?? cursor) : nil;cursor=target;return .applied
        }
    }
    /// Keeps the first `n` characters; the caret moves to the end.
    mutating func truncate(to n:Int) {
        guard n<characters.count else {return}
        utf8Count-=characters[n...].reduce(0) {$0+$1.utf8.count}
        characters.removeSubrange(n...);tags.removeSubrange(n...);cursor=characters.count;anchor=nil
    }
}

/// One continuous editing run in one field. Host-owned, used on one serial
/// executor under the capture binding's lock. Holds only keys that were each
/// proven in a permitted, non-secure field. Diagnostics are redacted.
public final class TypedUnit: CustomStringConvertible, CustomReflectable {
    public let identity:[String]
    public let bundle:String
    public let generation:UInt64, policyVersion:UInt64
    public let runID:String, part:Int
    public let startedAt:UInt64
    /// Tail of the previous unit in the same app AS IT WAS STORED: withheld
    /// tokens are [withheld] markers and a rejected unit is one marker, so no
    /// secret outlives its own unit here. Classification only; never stored.
    let context:String, separator:String
    /// The previous unit ended at a boundary where its last token may go on
    /// in this unit (not Return or Tab): a head that continues a withheld or
    /// suspicious tail is withheld.
    let joinable:Bool
    /// A latch in this app expired before this unit began: the first token
    /// may be the rest of the value and is withheld.
    let guardHead:Bool
    public private(set) var proof:FocusProof
    /// Set for an unconfirmed start: only a proof of this field read at or
    /// after this instant confirms the unit.
    public private(set) var confirmAfter:UInt64?
    private(set) var model=TextEditModel()
    /// Every character inserted, in typing order, including ones deleted later.
    private(set) var typedLog:[Character]=[]
    private(set) var typedLogBytes=0
    /// Index into typedLog where each chunk starts.
    private(set) var chunkStarts:[Int]=[0]
    private var chunkCharacters=0
    private var newChunkPending=false
    private var lastEventAt:UInt64?
    /// Monotonic time of the latest operation event, independent of processing delay.
    public var lastEditedAt:UInt64 {lastEventAt ?? startedAt}
    public private(set) var lastOpAt:UInt64
    public private(set) var keys=0, edits=0
    public var description:String {"TypedUnit(redacted)"}
    public var customMirror:Mirror {Mirror(self,children:[:])}

    init(proof:FocusProof,generation:UInt64,policyVersion:UInt64,runID:String,part:Int,context:String,separator:String,
         joinable:Bool=false,guardHead:Bool=false,now:UInt64,confirmAfter:UInt64?) {
        identity=CaptureAuthorization.identity(proof);bundle=proof.bundle
        self.proof=proof;self.generation=generation;self.policyVersion=policyVersion
        self.runID=runID;self.part=part;self.context=context;self.separator=separator
        self.joinable=joinable;self.guardHead=guardHead
        startedAt=now;lastOpAt=now;self.confirmAfter=confirmAfter
    }
    public var text:String {model.text}
    public var isEmpty:Bool {model.characters.isEmpty}
    var hasText:Bool {model.characters.contains(where:{!$0.isWhitespace})}
    public var chunkCount:Int {chunkStarts.count}
    var currentChunk:Int {chunkStarts.count-1}
    func chunkLog(_ i:Int) -> String {
        let end=i+1<chunkStarts.count ? chunkStarts[i+1] : typedLog.count
        return String(typedLog[chunkStarts[i]..<end])
    }
    var typedLogText:String {String(typedLog)}

    /// A proof of this same field. Newer proofs replace the unit's own proof;
    /// one read at/after `confirmAfter` confirms an unconfirmed start.
    func observe(_ p:FocusProof) {
        guard CaptureAuthorization.identity(p) == identity,p.generation == generation,p.policyVersion == policyVersion else {return}
        if p.checkedAt >= proof.checkedAt {proof=p}
        if let confirmAfter,p.checkedAt >= confirmAfter {self.confirmAfter=nil}
    }
    private func startChunk() {
        if typedLog.count>chunkStarts.last! {chunkStarts.append(typedLog.count)}
        chunkCharacters=0;newChunkPending=false
    }
    /// Applies one operation. Chunks: a gap of `chunkGap` since the previous
    /// operation, any caret move, or `chunkCharacters` inserted characters.
    /// Cmd-Backspace deletes to the start of the VISUAL line, which a key
    /// tap cannot see: it is applied only when the text since the last
    /// newline is short enough to be one line in any window
    /// (`lineDeleteCertain`); otherwise it is `.outside`, so the host commits
    /// the unit as typed before the app deletes an unknown amount.
    func apply(_ op:TypingOp,eventAt:UInt64,now:UInt64,limits:TypingLimits) -> TextEditModel.Result {
        if case .deleteBackward(.line)=op,model.selection == nil {
            let start=model.characters[..<model.cursor].lastIndex(of:"\n").map {$0+1} ?? 0
            if model.cursor-start>limits.lineDeleteCertain {return .outside}
        }
        if let last=lastEventAt,eventAt>=last,eventAt-last>=limits.chunkGap {newChunkPending=true}
        lastEventAt=max(lastEventAt ?? eventAt,eventAt)
        let result:TextEditModel.Result
        if case .insert(let s)=op {
            var applied=false
            for c in s {
                if newChunkPending || chunkCharacters>=limits.chunkCharacters {startChunk()}
                _=model.apply(.insert(String(c)),chunk:currentChunk)
                typedLog.append(c);typedLogBytes+=String(c).utf8.count;chunkCharacters+=1;applied=true
            }
            if applied {keys+=1}
            result = .applied
        } else {
            result=model.apply(op)
            if result == .applied {
                edits+=1
                if case .moveBackward=op {newChunkPending=true}
                if case .moveForward=op {newChunkPending=true}
            }
        }
        if result == .applied {lastOpAt=now}
        return result
    }
    /// messages-1003: the unit's text becomes `text` (what the field held when it was sent), keeping the typing log,
    /// chunks, counts and proof. Returns the previous model so a caller can put it back (`restore`).
    func replaceText(_ text:String) -> TextEditModel {
        let saved=model
        var m=TextEditModel()
        _=m.apply(.insert(text),chunk:currentChunk)
        model=m
        return saved
    }
    func restore(_ saved:TextEditModel) {model=saved}
    /// Hard cap with the caret at the end: keep the longest head within the
    /// limits, cut at the last whitespace within `capWhitespaceWindow`
    /// characters and return the partial word as the carry. Returns nil when
    /// the unit is under the hard cap or the caret is inside the run (commit
    /// as is).
    func cutForCap(_ limits:TypingLimits) -> [Character]? {
        let chars=model.characters
        guard chars.count>=limits.maxCharacters || model.utf8Count>=limits.maxBytes,model.caretAtEnd else {return nil}
        var end=0,bytes=0
        while end<chars.count,end<limits.maxCharacters {
            let b=String(chars[end]).utf8.count
            if bytes+b>limits.maxBytes {break}
            bytes+=b;end+=1
        }
        var cut=end
        if let ws=(max(0,end-limits.capWhitespaceWindow)..<end).last(where:{chars[$0].isWhitespace}) {cut=ws+1}
        guard cut>0 else {return nil}
        let carry=Array(chars[cut...])
        model.truncate(to:cut)
        return carry
    }
    /// When a key completes a secret pattern in a long unit, the sentences
    /// typed before it need not be lost: the latest sentence or line start
    /// from which the rest of the unit matches on its own. Only for a unit
    /// typed straight through (no edits or caret moves, so the typing log is
    /// the text), with something other than whitespace before the cut.
    func cleanHeadCut() -> Int? {
        let chars=model.characters
        guard edits == 0,typedLog.count == chars.count,model.caretAtEnd,chars.count>2 else {return nil}
        for c in stride(from:chars.count-1,to:0,by:-1) {
            let boundary=chars[c-1] == "\n" || (c>=2 && chars[c-1].isWhitespace && ".!?\u{2026}".contains(chars[c-2]))
            guard boundary else {continue}
            let rest=String(chars[c...])
            guard TextClassifier.substringReason(rest,final:false) ?? TextClassifier.proseReason(rest,final:false) != nil else {continue}
            let head=String(chars[..<c])
            guard head.contains(where:{!$0.isWhitespace}),!TextClassifier.pendingLabel(head) else {return nil}
            return c
        }
        return nil
    }
    /// Keeps the first `n` characters of the text and of the typing log.
    /// Only valid when they are equal (see `cleanHeadCut`).
    func truncateAll(to n:Int) {
        guard n<typedLog.count,typedLog.count == model.characters.count else {return}
        model.truncate(to:n)
        typedLog.removeSubrange(n...)
        typedLogBytes=typedLog.reduce(0) {$0+String($1).utf8.count}
        while chunkStarts.count>1,chunkStarts.last! >= n {chunkStarts.removeLast()}
    }
}

public enum UnitVerdict: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    case allow(String,withheld:Int), reject(PrivacyReason)
    public var description:String {
        switch self {case .allow(_,let w): "UnitVerdict.allow(redacted,withheld:\(w))";case .reject(let r): "UnitVerdict.reject(\(r.rawValue))"}
    }
    public var customMirror:Mirror {Mirror(self,children:[:])}
}

/// Whole-unit classification. Stricter than the v1 per-burst check: every
/// pause-separated chunk the old 0.7 s debounce would have classified alone
/// is still classified alone (from its typing log), plus the whole unit, each
/// line, each token, the typing log, and the seam with the previous unit.
/// A pattern match rejects the unit; a shape match (a lone number, an opaque
/// token, a run of digit groups, a token cut off at the end of the unit or
/// continuing one that was withheld) withholds just that token.
public enum UnitClassifier {
    public static let version="sensitive-typing/v2"
    public static let marker="[withheld]"
    static let seamCharacters=512

    /// Bounded per-key check (substring and typing-only rules, on unfinished
    /// text): the context plus the model text around the caret, and the tail
    /// of the typing log.
    public static func perKey(_ u:TypedUnit,limits:TypingLimits) -> PrivacyReason? {
        let m=u.model
        // With no edits or caret moves the text is the log, and the log window
        // below (512 back, with the context) covers the caret window.
        if u.edits>0 {
            let lo=max(0,m.cursor-limits.perKeyWindow),hi=min(m.characters.count,m.cursor+limits.perKeyWindow)
            var window=String(m.characters[lo..<hi])
            if lo == 0,!u.context.isEmpty {window=u.context+u.separator+window}
            if let r=TextClassifier.substringReason(window,final:false) ?? TextClassifier.proseReason(window,final:false) {return r}
        }
        var log=String(u.typedLog.suffix(limits.logWindow))
        if u.typedLog.count<limits.logWindow,!u.context.isEmpty {log=u.context+u.separator+log}
        return TextClassifier.substringReason(log,final:false) ?? TextClassifier.proseReason(log,final:false)
    }

    /// `trailingOpen`: the unit did not end at Return, so a token right at
    /// its end may be the first part of something longer.
    public static func verdict(_ u:TypedUnit,limits:TypingLimits,trailingOpen:Bool=true) -> UnitVerdict {
        let text=u.text
        // 1. Size.
        guard text.utf8.count<=limits.maxBytes+256 else {return .reject(.oversizedBurst)}
        // 2-3. The whole unit: every rule, so a unit that is one token or one
        // number is rejected whole; then the typing-only rules.
        if let r=TextClassifier.sensitiveReason(text) ?? TextClassifier.proseReason(text) {return .reject(r)}
        // 4. The typing log, including text deleted later (at most 8 KB, one
        // pass). When nothing was deleted or moved the log is the text itself.
        if u.typedLog != u.model.characters {
            let log=u.typedLogText
            if let r=TextClassifier.spanReason(log) ?? TextClassifier.proseReason(log) {return .reject(r)}
        }
        // 5. The seam with the previous unit (as stored, never stored again).
        if !u.context.isEmpty {
            let seam=u.context+u.separator+String(text.prefix(seamCharacters))
            if let r=TextClassifier.substringReason(seam) ?? TextClassifier.proseReason(seam) {return .reject(r)}
        }
        let characters=u.model.characters,tags=u.model.tags
        var withheld=[Bool](repeating:false,count:characters.count)
        // 6. Each line and each chunk log: a substring match rejects; a shape
        // match withholds the surviving characters of that line or chunk.
        // A single line is the whole text, already checked in steps 2-3.
        var lineStart=0
        if characters.contains("\n") {for i in 0...characters.count where i == characters.count || characters[i] == "\n" {
            let line=String(characters[lineStart..<i])
            if let r=TextClassifier.substringReason(line) {return .reject(r)}
            if lineStart<i,TextClassifier.anchoredReason(line) != nil {for j in lineStart..<i where !characters[j].isWhitespace {withheld[j]=true}}
            lineStart=i+1
        }}
        for c in 0..<u.chunkCount {
            let chunk=u.chunkLog(c)
            if chunk.isEmpty {continue}
            if let r=TextClassifier.substringReason(chunk,final:false) {return .reject(r)}
            if TextClassifier.anchoredReason(chunk) != nil {for j in characters.indices where tags[j] == c && !characters[j].isWhitespace {withheld[j]=true}}
        }
        // 7. Tokens (edge punctuation trimmed): too long rejects, opaque withholds.
        var tokens:[Range<Int>]=[]
        var i=0
        while i<characters.count {
            if characters[i].isWhitespace {i+=1;continue}
            var j=i;while j<characters.count,!characters[j].isWhitespace {j+=1}
            tokens.append(i..<j);i=j
        }
        func token(_ r:Range<Int>) -> Substring {Substring(String(characters[r]))}
        func withhold(_ r:Range<Int>) {for k in r {withheld[k]=true}}
        for r in tokens {
            let t=token(r)
            if t.trimmingCharacters(in:TextClassifier.edgePunctuation).count>limits.tokenCharacters {return .reject(.oversizedBurst)}
            if TextClassifier.opaqueToken(t) {withhold(r)}
        }
        // 7b. Runs of digit groups ("4111 1111 1111", "123 45", "1234 5678"
        // on a recovery-code line) with five or more digits, and one
        // dash-joined number ("4111-1111", "123-45-"), with an IBAN country
        // and check-digit head ("DE89") in front of such a run.
        // Review round 1: groups joined inside a token by other separators
        // ("4111,1111", eight digits or more alone) and groups with a
        // separator token between them ("4111 -- 1111", "4111 | 1111").
        func group(_ r:Range<Int>) -> Bool {TextClassifier.digitGroup(token(r)) || TextClassifier.joinedDigits(token(r))}
        var completePhoneTokens=Set<Int>()
        for (index,r) in tokens.enumerated() where ContactShape.phone(String(token(r))) {completePhoneTokens.insert(index)}
        var g=0
        while g<tokens.count {
            guard group(tokens[g]) else {g+=1;continue}
            var e=g,digits=0,dashed=false,joined=false,groups=0
            while e<tokens.count {
                if group(tokens[e]) {
                    let t=token(tokens[e]);digits+=t.filter(\.isNumber).count;dashed=dashed || t.contains("-");groups+=1
                    joined=joined || (!TextClassifier.digitGroup(t) && TextClassifier.joinedDigits(t));e+=1
                } else if e+1<tokens.count,TextClassifier.separatorToken(token(tokens[e])),group(tokens[e+1]) {e+=1}
                else {break}
            }
            let run=String(characters[tokens[g].lowerBound..<tokens[e-1].upperBound])
            if ContactShape.phone(run) {
                for index in g..<e {completePhoneTokens.insert(index)}
            } else if digits>=5,groups>=2 || dashed || (joined && digits>=8) {
                var start=g
                if g>0,String(token(tokens[g-1])).range(of:#"^[A-Z]{2}\d{2}$"#,options:.regularExpression) != nil {start=g-1}
                for r in tokens[start..<e] {withhold(r)}
            }
            g=e
        }
        // The first token, and the digit groups right after it when it is one
        // ("[withheld] " then "1111 2222 exp").
        func withholdHead() {
            guard let first=tokens.first else {return}
            withhold(first)
            var n=1
            while n<tokens.count,TextClassifier.digitGroup(token(tokens[n-1])),TextClassifier.digitGroup(token(tokens[n])) {withhold(tokens[n]);n+=1}
        }
        // 7c. The first token continuing the previous unit's last token.
        if !u.context.isEmpty,let first=tokens.first {
            let context=u.context
            let tail=context.split(whereSeparator:{$0.isWhitespace}).last.map(String.init) ?? ""
            let head=token(first)
            // Only a unit that ended somewhere other than Return or Tab can
            // be continued mid-token. A tail that was stored as it is and
            // ends a clause ("it.") was judged whole; the head is new text
            // ("it." then "John about it." after a correction).
            let clause=tail.last.map {".!?\u{2026},;:".contains($0)} ?? false
            if u.joinable,first.lowerBound == 0,!(context.last?.isWhitespace ?? true),tail.hasSuffix(marker) || !clause {
                if tail.hasSuffix(marker) {withholdHead()}
                else {
                    let joined=tail+head
                    if let r=TextClassifier.substringReason(joined) {return .reject(r)}
                    if TextClassifier.anchoredReason(joined) != nil || TextClassifier.opaqueToken(Substring(joined)) || TextClassifier.suspiciousPartial(Substring(joined)) {withholdHead()}
                }
            } else if tail.hasSuffix(marker),TextClassifier.digitGroup(head) || TextClassifier.suspiciousPartial(head) {
                // "card [withheld] " then "1111 exp", "pin: [withheld]" Return
                // "921": the next group of the value.
                withholdHead()
            }
        }
        // 7d. A latch expired in this app just before, or the previous unit
        // ended in a label still waiting for its value ("pin:", or "pw" when
        // the first token could be a password): the first token may be the value.
        if u.guardHead || (!u.context.isEmpty && TextClassifier.pendingLabel(u.context)) {withholdHead()}
        // A bare label ("pw ", "login sam ") and a made-up password next (review round 1).
        else if !u.context.isEmpty,let first=tokens.first,TextClassifier.bareLabel(u.context),TextClassifier.passwordLike(token(first)) {withholdHead()}
        // 7e. The last token when it may be the first part of a secret cut off
        // by the end of the unit (any end but Return), or when it follows a
        // label waiting for its value ("my pin is 49", any end). Never stored
        // on its own; the next unit's head that continues it is withheld too
        // (7c).
        if let last=tokens.last,last.upperBound == characters.count,
           (trailingOpen && !completePhoneTokens.contains(tokens.count-1) && TextClassifier.suspiciousPartial(token(last))) || TextClassifier.pendingLabel(String(characters[..<last.lowerBound])) {withhold(last)}
        // Withholding covers whole tokens (never the whitespace between them).
        for r in tokens where withheld[r].contains(true) {withhold(r)}
        for k in characters.indices where characters[k].isWhitespace {withheld[k]=false}
        // 8. Output with [withheld] markers (withheld tokens separated only by
        // spaces on one line become one marker, so the number of groups is
        // not shown); nothing but markers left rejects.
        var output="",spans=0,k=0
        while k<characters.count {
            guard withheld[k] else {output.append(characters[k]);k+=1;continue}
            spans+=1;output+=marker
            while k<characters.count {
                if withheld[k] {k+=1;continue}
                var w=k
                while w<characters.count,characters[w].isWhitespace,characters[w] != "\n" {w+=1}
                if w>k,w<characters.count,withheld[w] {k=w;continue}
                break
            }
        }
        let rest=output.replacingOccurrences(of:marker,with:"")
        guard rest.contains(where:{!$0.isWhitespace}),spans == 0 || rest.contains(where:{$0.isLetter || $0.isNumber}) else {return .reject(.classifierDeny)}
        if spans>0,let r=TextClassifier.substringReason(output) {return .reject(r)}
        // 9. One to three digits alone (one box of a one-time code that moves
        // focus by itself) is never a row.
        let trimmed=rest.trimmingCharacters(in:.whitespacesAndNewlines)
        if spans == 0,(1...3).contains(trimmed.count),trimmed.allSatisfy(\.isNumber) {return .reject(.ambiguousNumeric)}
        return .allow(output,withheld:spans)
    }
}

// MARK: - The late-key cut (gold/capture-input, golden 5 G7)

/// A unit's state at one moment: what was typed on time before keys the host handled late
/// (`TypingSession.markLateCut`). Held only while those late keys may still be dropped.
struct TypedUnitMark {
    fileprivate let model:TextEditModel, typedLog:[Character], typedLogBytes:Int, chunkStarts:[Int], chunkCharacters:Int
    fileprivate let newChunkPending:Bool, lastEventAt:UInt64?, lastOpAt:UInt64, keys:Int, edits:Int
    fileprivate let proof:FocusProof, confirmAfter:UInt64?
    var characterCount:Int {model.characters.count}
}

extension TypedUnit {
    func mark() -> TypedUnitMark {
        TypedUnitMark(model:model,typedLog:typedLog,typedLogBytes:typedLogBytes,chunkStarts:chunkStarts,chunkCharacters:chunkCharacters,
                      newChunkPending:newChunkPending,lastEventAt:lastEventAt,lastOpAt:lastOpAt,keys:keys,edits:edits,proof:proof,confirmAfter:confirmAfter)
    }
    /// Back to `m`: every key and edit applied since is undone (the text, the typing log, the chunks and the proof).
    /// `confirmed`: its field was confirmed since (it was judged), and stays confirmed (gold/r2-typing review round 1).
    func restore(_ m:TypedUnitMark,confirmed:Bool=false) {
        model=m.model;typedLog=m.typedLog;typedLogBytes=m.typedLogBytes;chunkStarts=m.chunkStarts;chunkCharacters=m.chunkCharacters
        newChunkPending=m.newChunkPending;lastEventAt=m.lastEventAt;lastOpAt=m.lastOpAt;keys=m.keys;edits=m.edits;proof=m.proof
        confirmAfter=confirmed ? nil : m.confirmAfter
    }
    var characterCount:Int {model.characters.count}
}
