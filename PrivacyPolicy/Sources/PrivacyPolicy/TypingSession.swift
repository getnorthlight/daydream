import Foundation

/// Timing and size limits for typed units. Monotonic nanoseconds.
public struct TypingLimits: Sendable {
    /// Pause that commits a unit whose text ends at a natural stop
    /// (whitespace or . ! ? …, closing quotes and brackets ignored); leaving
    /// the field, Return, sleep and pause commit at once. Live test (build 7):
    /// at 30 s a TextEdit draft was still unsaved after 25 s idle, so rows,
    /// prompt rows and summaries missed what was just typed. 12 s is past a
    /// typical pause between sentences, and a pause that does split a draft
    /// keeps its run: the next piece in the same field continues it (same
    /// runID, part + 1, joined with no separator, shown as one draft; the run
    /// stays open for `softRunJoin` after the split).
    public var idleClosed:UInt64=12_000_000_000
    /// Pause that commits a unit ending inside a plain word (letters only, not
    /// a label or anything secret-shaped): most drafts end without a trailing
    /// space. A little longer than `idleClosed`, for a pause mid-word.
    public var idleWord:UInt64=15_000_000_000
    /// Pause that commits a unit ending after a digit group, a label still
    /// waiting for its value ("password: "), or any other unfinished token,
    /// so a label and its value, or the groups of one number, stay one unit.
    public var idleOpen:UInt64=60_000_000_000
    /// Where Return (or a send chord) sends (AI prompts, texts, chat, email,
    /// search and social composers, `SendRules`), the send is decided on the
    /// piece it ends: a draft committed by a pause before the send would lose
    /// "sent". A natural stop or a plain word waits at least this long there
    /// (people reread before sending); 30 s is the old idle.
    public var idleSendFloor:UInt64=30_000_000_000
    /// How long after an idle or size split the next piece typed in the same
    /// field continues the same run (the context lives this long after a soft
    /// split): a draft paused to think stays one draft, not many tiny rows.
    public var softRunJoin:UInt64=60_000_000_000
    /// Gap that starts a new chunk (the old burst boundary; classification only).
    public var chunkGap:UInt64=700_000_000
    /// Wait after leaving a field before judging where focus went; also the
    /// window after a focus-moving input in which a new unit is unconfirmed.
    public var settle:UInt64=400_000_000
    /// A parked unit resolved later than this after its deadline is discarded.
    public var lateResolution:UInt64=2_000_000_000
    public var softSplitCharacters=1800
    public var maxCharacters=2000
    public var maxBytes=3584
    public var capWhitespaceWindow=64
    public var typedLogBytes=8192
    public var tokenCharacters=256
    public var chunkCharacters=256
    public var contextCharacters=256
    /// How long the previous unit's stored tail is used to classify the next
    /// unit in the same app.
    public var contextLifetime:UInt64=30_000_000_000
    /// A unit that ended in a label still waiting for its value ("wifi
    /// password: ") or in a withheld token guards the next unit in that app
    /// this long.
    public var labelLifetime:UInt64=300_000_000_000
    /// A latched app stays latched until Return or Tab there, a privacy
    /// boundary, or this long without a key in that app.
    public var latchExpiry:UInt64=30_000_000_000
    /// After a latch expires, the first token of the next unit in that app is
    /// withheld if it starts within this long.
    public var guardLifetime:UInt64=300_000_000_000
    /// Cmd-Backspace is applied only when the text since the last newline is
    /// at most this long (one visual line in any window); otherwise the unit
    /// is committed as typed first.
    public var lineDeleteCertain=40
    public var maxParked=4
    /// Units judged on time that wait for the decision on keys the host handled late (`TypingSession.markLateCut`)
    /// are never dropped to make room under `maxParked`. Past this many, the oldest late keys are decided the safe way
    /// (dropped with what followed them, the text typed on time before them kept: `rollBackLate`). Far more lines than
    /// anyone ends in the second or two a decision takes (gold/r2-typing review round 1).
    public var maxHeldForLateKeys=16
    public var perKeyWindow=256
    public var logWindow=512
    public init() {}
}

/// Why a unit ended. Privacy boundaries are not seal reasons: they invalidate.
public enum SealReason: String, Sendable, CaseIterable {
    case idle, size, submit, cursor, paste, pointer, focusKey, shortcut, focus, window, app, inputSource, gap, suspend
    /// The rest of the run completed a secret pattern: this is the part typed
    /// before the sentence or line that matched.
    case sensitive
    /// summaries/v3 (spec §3): Command- or Control-Return, the send chord of Gmail, Outlook and iCloud mail on the web
    /// (and some chat apps). Behaves like `shortcut` for focus; SendRules decides whether it was a send.
    case submitChord
    /// summaries/v3: Command-Shift-D, Mail's Send. Behaves like `shortcut` for focus.
    case mailSend
    /// Idle and size splits keep the run (runID, part + 1) and join the next
    /// unit's seam with no separator.
    public var soft:Bool {self == .idle || self == .size}
    /// Return or Tab/Esc: an explicit end of a value. Clears a latch in that
    /// app, and the next unit never continues this unit's last token.
    public var endsValue:Bool {self == .submit || self == .focusKey}
    /// Only Return ends the last token for certain; any other end may cut a
    /// token that goes on later.
    var trailingOpen:Bool {self != .submit}
    /// Boundaries after which focus may be in another app.
    public var mayChangeApp:Bool {[.pointer,.shortcut,.submitChord,.mailSend,.window,.app,.inputSource,.gap].contains(self)}
}

/// Where focus is when a parked unit is resolved: a fresh typing proof when
/// one could be read, and the departure metadata (read regardless, cheap).
public struct TypingDestination: Sendable {
    public var proof:FocusProof?
    public var departure:DepartureState
    public init(proof:FocusProof?,departure:DepartureState) {self.proof=proof;self.departure=departure}
}

/// Result of one key for the host. `commit` asks for a live commit now.
public struct TypingStep: Sendable, Equatable {
    public let decision:PrivacyDecision
    public let commit:SealReason?
    public init(decision:PrivacyDecision,commit:SealReason?) {self.decision=decision;self.commit=commit}
}

/// A classified unit handed to the host's write closure, under its lock.
public struct TypingCommit: CustomStringConvertible, CustomReflectable {
    public let text:String
    public let proof:FocusProof
    public let runID:String, part:Int
    public let reason:SealReason
    public let startedAt:UInt64
    /// In-memory monotonic event time, used only to reject stale recipient authority.
    public let lastEditedAt:UInt64
    public let keys:Int, edits:Int, withheld:Int
    public var description:String {"TypingCommit(redacted)"}
    public var customMirror:Mirror {Mirror(self,children:[:])}
}

public enum TypingOutcome: Equatable, Sendable {
    case none
    case committed(withheld:Int)
    /// Classified allowed, but the host's write declined it (store pre-check).
    case notWritten
    case rejected(PrivacyReason)
    /// The live commit could not take a fresh proof of the same field.
    case parked
    case discarded(PrivacyReason)
}

/// Pure typing state machine. Owner confines it to one serial executor (the
/// capture binding's lock). No clock, timer, persistence, logging, AX or key
/// event API: the host passes monotonic time and schedules `idleDeadline`,
/// `nextParkedDeadline` and `housekeepingDeadline`. Swift strings may leave
/// copies in process memory; clearing is not a secure-erasure guarantee.
///
/// Rules:
/// 1. Characters are read by the host only after a metadata proof and the
///    gate pass, and never in a latched app (`admit`).
/// 2. A unit holds only keys that were each proven in a permitted field. No
///    timer ends a unit while typing continues.
/// 3. Live commit: the field is still focused and a fresh proof of the same
///    field is taken now. Parked commit: the field was left; after `settle`
///    the host says where focus went.
/// 4. The whole unit is classified in the same critical section as the write.
/// 5. Privacy boundaries (`invalidate`) discard. Ordinary boundaries commit.
/// 6. A detected secret latches its APP (a field ID cannot scope it: the
///    value can go on in another field, or under new IDs after the app
///    re-creates its AX objects). Only Return, Tab or Esc in that app, a
///    privacy boundary, or `latchExpiry` without keys there clears it;
///    ordinary boundaries (click, Cmd-Tab, AX focus changes, stalls,
///    unreadable proofs) do not. After an expiry the next unit's first token
///    is withheld.
/// 7. What carries over between units is what was STORED (markers in place of
///    withheld tokens), never raw text: a token cut off at the end of a unit
///    is withheld, and so is the head of the next unit that continues it.
/// 8. Terminal password prompts (safe typing C, `TerminalPromptLatch`): in an
///    app that needs the latch (terminals and editors with a built-in
///    terminal), every key goes through it in `admit`, before anything is
///    read, and every unit that ends without Return tells it what was typed
///    into the shell line (Tab, idle and size splits) or that the line changed
///    unseen (history recall, caret jumps, paste, undo, unread keys), or that
///    capture only stopped watching it (another app or window, a plain
///    click: `interrupts`). Return on a privileged command line (`sudo`,
///    `ssh`, ...), on a line changed unseen, or on an interrupted line that
///    could still be privileged, arms it and every key is dropped until the next
///    Return in that focus; a window title showing such a process
///    (`FocusProof.place`) drops every key while it shows; `ssh` stops
///    recording in that focus until the focus changes. A focus change ends
///    all of them. A Return with no readable proof is fed to every latch app.
///    The store's scrubber still runs on what is kept ("sudo [withheld]").
/// 9. Esc in a search panel (Spotlight, Raycast, or a search field) abandons
///    the search: the unit is discarded, never saved (`escape`). Elsewhere
///    Esc is an ordinary Tab-like boundary.
public final class TypingSession: CustomStringConvertible, CustomReflectable {
    public let limits:TypingLimits
    private let authorization=CaptureAuthorization()
    private var live:TypedUnit?
    /// `judged` (gold/r2-typing, golden 5 G7): its destination was proven on time and it holds keys the host handled
    /// late that are not vouched for yet (`lateCut`); it is written only once they are (`waitsForLateKeys`).
    private struct Parked {let unit:TypedUnit, reason:SealReason, deadline:UInt64, sameField:Bool; var judged=false}
    private var parked:[Parked]=[]
    /// Per app (Notes and TextEdit each keep their own, so a visit to the
    /// other app neither clears nor escapes them).
    private struct Latch {let reason:PrivacyReason; var lastKeyAt:UInt64}
    private var latches:[String:Latch]=[:]
    /// App -> until: the first token of the next unit there is withheld.
    private var guards:[String:UInt64]=[:]
    private struct Context {
        let identity:[String], text:String, until:UInt64
        var soft:Bool
        let joinable:Bool, runID:String, part:Int
    }
    private var contexts:[String:Context]=[:]
    private var focusMovedAt:UInt64?
    /// The app of the last key proof, for Tab (which carries no proof).
    private var lastKeyBundle:String?
    /// One terminal prompt latch per app that needs it (focus-scoped inside).
    private var prompts:[String:TerminalPromptLatch]=[:]
    /// A key that may have changed a shell line unseen (a shortcut like
    /// Control-R, Tab, a caret jump) came with no proof and no known app: the
    /// next proven key or Return in a latch app counts its line as unseen.
    private var unseenPending=false
    /// Capture stopped watching a latch app (another app, a click) with no
    /// known app: the next proven key or Return there counts its line as
    /// interrupted (`TerminalPromptLatch.Key.interrupted`). `unseenPending` wins.
    private var interruptPending=false
    /// Keys the host handled late (golden 5 G7): what was typed on time before each backlog of them, oldest first,
    /// until that backlog is vouched for or dropped (gold/r2-typing review round 1: one cut per backlog).
    private var lateCuts:[LateCut]=[]
    private var lateCutSerial:UInt64=0
    /// Which apps go through the prompt latch: the table's `promptLatch` rows
    /// (terminals and editors with a built-in terminal). Checks substitute an
    /// app the capture gate admits today.
    public let promptLatchApps:@Sendable (String)->Bool
    /// The focus gate every proof goes through. Native typing uses
    /// `CaptureGate.typing` (the default). Website typing (owner build only)
    /// passes its own gate, which never admits anything but a proven Chrome field.
    public typealias Gate=(FocusProof,CapturePolicy,UInt64,UInt64)->PrivacyDecision
    public let typingGate:Gate
    /// claude/livefix-1004 (owner, live test 10/3: one X reply was saved as 11 drafts): a click or a caret move inside
    /// the same field keeps the run open, so the next piece typed in that field (the same identity) continues it
    /// (runID, part + 1) as an idle split does. Website typing only (`BrowserTypingBurst` sets it); off for native
    /// typing, where a click still starts a new draft. Only which run a piece belongs to changes: every piece is still
    /// sealed, judged and saved on its own, and another field, page or app still starts a new run.
    public var pointerContinuesRun=false
    /// Whether a unit sealed by `reason` leaves its run open for the next unit in the same field.
    private func keepsRun(_ reason:SealReason) -> Bool {reason.soft || (pointerContinuesRun && (reason == .pointer || reason == .cursor))}

    public init(limits:TypingLimits=TypingLimits(),promptLatchApps:@escaping @Sendable (String)->Bool = TypingSession.tablePromptLatch,
                gate:@escaping Gate = {CaptureGate.typing($0,policy:$1,generation:$2,now:$3)}) {
        self.limits=limits;self.promptLatchApps=promptLatchApps;self.typingGate=gate
    }
    public static let tablePromptLatch:@Sendable (String)->Bool = {TypingCategories.app($0)?.promptLatch == true}
    /// Launcher panels where Esc abandons what was typed.
    public static let searchPanels:Set<String>=["com.apple.Spotlight","com.raycast.macos"]
    /// Esc here throws the unit away: a launcher panel, or a search field in any app.
    public static func isSearchPanel(_ p:FocusProof) -> Bool {
        searchPanels.contains(p.bundle) || p.subrole == "AXSearchField"
    }
    /// Whether keys in this proof's focus are being dropped at a terminal
    /// password prompt right now (for checks and diagnostics).
    public func promptArmed(_ p:FocusProof) -> Bool {prompts[p.bundle].map {$0.arm != nil && $0.focusID == p.focusID} ?? false}
    /// Whether this proof's focus is in a remote (ssh) session, where nothing is recorded.
    public func remoteSession(_ p:FocusProof) -> Bool {prompts[p.bundle].map {$0.remote && $0.focusID == p.focusID} ?? false}
    public var description:String {"TypingSession(redacted)"}
    public var customMirror:Mirror {Mirror(self,children:[:])}
    /// Increases only on privacy boundaries, so a focused field keeps its IDs.
    public var generation:UInt64 {authorization.generation}
    public var hasLive:Bool {live != nil}
    /// Metadata comparison only. The caller must freshly authorize the proof;
    /// matching a retained identity never grants permission to read characters.
    public func matchesLiveFocus(_ proof:FocusProof) -> Bool {
        guard let u=live else {return false}
        return u.generation==proof.generation && proof.generation==generation && u.policyVersion==proof.policyVersion
            && u.identity==CaptureAuthorization.identity(proof)
    }
    /// Whether a deferred carry needs another ordinary hard-cap split.
    public var liveAtCap:Bool {live.map {$0.model.characters.count>=limits.maxCharacters || $0.model.utf8Count>=limits.maxBytes} ?? false}
    public var parkedCount:Int {parked.count}
    /// QF-17 (bracketed prototype, key accounting): the keys and edits held by units not written yet (the live unit
    /// and every parked one). A count only, never text.
    public var pendingUnits:Int {(live.map {$0.keys+$0.edits} ?? 0)+parked.reduce(0) {$0+$1.unit.keys+$1.unit.edits}}
    /// QF-17 key accounting: why units left unwritten (keys + edits), since the host last took the tally. Counts only,
    /// never text; a passive tally that changes nothing the session decides. Not every exit is named (a retract, an
    /// abandoned search, a late-key rollback): the host names the rest from its own context.
    public enum UnitDrop:String,CaseIterable,Sendable {
        /// A classifier rejection (a secret, an opaque token), a privacy boundary (`invalidate`), a policy or
        /// generation change, or a settle discard for a privacy gate reason.
        case privacy
        /// A settle that couldn't prove where the text went: departure denied, focus unconfirmed, or judged too late.
        case departure
        /// Nothing but whitespace (or only deletions) was left: there was no text to write.
        case empty
        /// The parked FIFO was full (`maxParked`): its oldest unit was evicted.
        case capacity
    }
    public private(set) var unitDrops:[UnitDrop:Int]=[:]
    /// The tally since the last call; it starts over.
    public func takeUnitDrops() -> [UnitDrop:Int] {defer {unitDrops=[:]};return unitDrops}
    private func dropped(_ u:TypedUnit?,_ why:UnitDrop) {if let u,u.keys+u.edits>0 {unitDrops[why,default:0]+=u.keys+u.edits}}
    private func dropped(_ u:TypedUnit,_ outcome:TypingOutcome) -> TypingOutcome {
        switch outcome {
        case .rejected: dropped(u,.privacy)
        case .discarded(let r): dropped(u,[.departureDenied,.unconfirmedFocus,.staleProof].contains(r) ? .departure : .privacy)
        default: break
        }
        return outcome
    }
    public var isLatched:Bool {!latches.isEmpty}
    public func isLatched(_ bundle:String) -> Bool {latches[bundle] != nil}
    /// When the live unit should be committed as an idle soft split.
    public var idleDeadline:UInt64? {
        guard let u=live,!u.isEmpty else {return nil}
        return u.lastOpAt &+ idleWait(u)
    }
    /// The pause that commits `u` (see `TypingLimits`): a natural stop, a plain word, anything else unfinished.
    func idleWait(_ u:TypedUnit) -> UInt64 {
        let base:UInt64
        if closedTail(u) {base=limits.idleClosed} else if plainWordTail(u) {base=limits.idleWord} else {return limits.idleOpen}
        return Self.sendSurfaces.contains(surface(u)) ? max(base,limits.idleSendFloor) : base
    }
    /// Surfaces where a Return or send chord can send what is typed (`SendRules.send`).
    static let sendSurfaces:Set<String>=["ai","aiTool","text","chat","email","social","search"]
    private func surface(_ u:TypedUnit) -> String {
        let p=u.proof
        return SendRules.surface(bundle:u.bundle,host:p.url.isEmpty ? nil : p.url,title:p.place,field:p.sendField.isEmpty ? "unknown" : p.sendField)
    }
    /// A unit judged on time that waits for its late keys' decision has no deadline until that decision.
    public var nextParkedDeadline:UInt64? {parked.filter {!waitsForLateKeys($0)}.map(\.deadline).min()}
    /// When the host should call `expire`: the context, a latch or a guard
    /// runs out. Nothing is committed then; state is only dropped.
    public var housekeepingDeadline:UInt64? {
        (latches.values.map {$0.lastKeyAt &+ limits.latchExpiry &+ 1}+guards.values.map {$0 &+ 1}+contexts.values.map {$0.until &+ 1}).min()
    }

    // MARK: Privacy boundary

    /// Drops the live unit, every parked unit, the latch, the guard and the context.
    @discardableResult public func invalidate(_ boundary:PrivacyBoundary) -> UInt64 {
        dropped(live,.privacy);for p in parked {dropped(p.unit,.privacy)}
        live=nil;parked.removeAll();latches.removeAll();guards.removeAll();contexts.removeAll();focusMovedAt=nil;lastKeyBundle=nil;lateCuts.removeAll()
        // A prompt latch is kept: a pause or policy change doesn't end the
        // prompt, and dropping more keys is the safe side. Focus changes end it.
        // Keys dropped here never reached a latch, so its line is unseen now.
        for bundle in Array(prompts.keys) {
            guard var l=prompts[bundle] else {continue}
            _=l.key(.unseen(typed:""),focusID:l.focusID ?? "");prompts[bundle]=l
        }
        return authorization.invalidate(boundary)
    }
    /// Drops what has run out: the context, the guard, and a latch (which
    /// leaves a guard on the next unit's first token in that app).
    public func expire(now:UInt64) {
        for (bundle,l) in latches where now>=l.lastKeyAt && now-l.lastKeyAt>limits.latchExpiry {
            latches[bundle]=nil
            guards[bundle]=l.lastKeyAt &+ limits.latchExpiry &+ limits.guardLifetime
        }
        guards=guards.filter {now<=$0.value}
        contexts=contexts.filter {now<=$0.value.until}
    }

    // MARK: Keys

    /// Call with every key's proof before anything is read. Parks a live unit
    /// whose field is no longer focused, and returns a refusal when this app
    /// is latched (read nothing, apply nothing).
    public func admit(_ proof:FocusProof,now:UInt64) -> PrivacyDecision? {
        expire(now:now)
        let id=CaptureAuthorization.identity(proof)
        if let u=live,u.identity != id {live=nil;park(u,.focus,now:now)}
        for p in parked where !p.unit.hasText && p.unit.identity != id {dropped(p.unit,.empty)}
        parked.removeAll {!$0.unit.hasText && $0.unit.identity != id}
        lastKeyBundle=proof.bundle
        if let dropped=promptKey(proof) {return dropped}
        guard var l=latches[proof.bundle] else {return nil}
        l.lastKeyAt=max(l.lastKeyAt,now);latches[proof.bundle]=l
        return CaptureGate.result(.blocked,l.reason,proof)
    }
    /// Characters already read after `admit` returned nil for this proof.
    public func insert(_ characters:String,proof:FocusProof,policy:CapturePolicy,eventAt:UInt64,now:UInt64,compositionFinal:Bool=true) -> TypingStep {
        let gate=typingGate(proof,policy,generation,now)
        guard gate.outcome == .allowed else {refuse(gate,now:now);return TypingStep(decision:gate,commit:nil)}
        if let latched=admit(proof,now:now) {return TypingStep(decision:latched,commit:nil)}
        guard compositionFinal else {
            promptLine(.inputSource,bundle:proof.bundle,proof:proof)
            discardParkedSpaces(includingLive:true);live=nil;return TypingStep(decision:CaptureGate.result(.unknown,.compositionPending,proof),commit:nil)
        }
        let text=Self.printable(characters)
        guard !text.isEmpty else {discardParkedSpaces(includingLive:true);return TypingStep(decision:gate,commit:nil)}
        resumeParkedSpaces(proof,now:now)
        let u=live ?? begin(proof,policy:policy,now:now)
        u.observe(proof)
        _=u.apply(.insert(text),eventAt:eventAt,now:now,limits:limits)
        return checked(u,proof:proof,gate:gate,now:now)
    }
    /// Edits and in-run caret moves. Ignored in a latched app and before a
    /// unit exists. Leaving the run asks for a live commit (`cursor`).
    public func apply(_ op:TypingOp,proof:FocusProof,policy:CapturePolicy,eventAt:UInt64,now:UInt64) -> TypingStep {
        if case .insert(let s)=op {return insert(s,proof:proof,policy:policy,eventAt:eventAt,now:now)}
        discardParkedSpaces()
        let gate=typingGate(proof,policy,generation,now)
        guard gate.outcome == .allowed else {refuse(gate,now:now);return TypingStep(decision:gate,commit:nil)}
        if let latched=admit(proof,now:now) {return TypingStep(decision:latched,commit:nil)}
        guard let u=live else {return TypingStep(decision:gate,commit:nil)}
        u.observe(proof)
        if u.apply(op,eventAt:eventAt,now:now,limits:limits) == .outside {return TypingStep(decision:gate,commit:.cursor)}
        return checked(u,proof:proof,gate:gate,now:now)
    }
    /// Cmd-Z: the app undid text we cannot see, and how much is unknown (a
    /// whole typing run in the text system, a shorter burst in some web
    /// editors). The whole unsaved unit is dropped, which can lose words
    /// before the undone part but never saves undone text (review G72; C7).
    public func retract() {discardParkedSpaces();promptLine(.cursor,bundle:live?.bundle ?? lastKeyBundle,proof:nil);live=nil}
    /// Control-U (`kill`) or Control-C (`interrupt`) in an app with the prompt latch (a terminal): the shell line is
    /// erased or abandoned, never run, so what was typed into it and not written yet (the live unit, and a unit of
    /// that focus still settling) is dropped, never saved (owner request 2026-10-02, RECORDING-MATRIX-1002 P3). The
    /// latch learns it: Control-C ends the line and a command arm (the prompt was interrupted); Control-U clears a line
    /// that was fully seen. Returns false outside a latch app (the host seals as for any shortcut). Nothing is read.
    public enum LineErase:Sendable {case kill,interrupt}
    @discardableResult public func eraseLine(_ how:LineErase,now:UInt64) -> Bool {
        expire(now:now)
        guard let bundle=live?.bundle ?? lastKeyBundle,promptLatchApps(bundle) else {return false}
        let focus=live.flatMap {$0.bundle == bundle ? $0.proof.focusID : nil} ?? prompts[bundle]?.focusID
        discardParkedSpaces(includingLive:true)
        if let u=live,u.bundle == bundle {
            live=nil;dropped(u,.empty)
            if contexts[bundle]?.identity == u.identity {contexts[bundle]=nil}
        }
        for p in parked where p.unit.bundle == bundle && p.unit.proof.focusID == focus && !waitsForLateKeys(p) {
            dropped(p.unit,.empty)
            if contexts[bundle]?.identity == p.unit.identity {contexts[bundle]=nil}
        }
        parked.removeAll {$0.unit.bundle == bundle && $0.unit.proof.focusID == focus && !waitsForLateKeys($0)}
        if var l=prompts[bundle],let f=l.focusID,focus == nil || focus == f {
            _=l.key(how == .interrupt ? .interrupt : .cleared,focusID:f)
            prompts[bundle]=l
        }
        unseenPending=false;interruptPending=false
        return true
    }
    /// A gate refusal the host saw before calling `insert` (nothing read).
    /// Deny reasons are privacy boundaries; others park the unit.
    public func refuse(_ gate:PrivacyDecision,now:UInt64) {
        guard gate.outcome != .allowed else {return}
        discardParkedSpaces(includingLive:true)
        if CaptureGate.typingDenyReasons.contains(gate.reason) {
            if live != nil || !parked.isEmpty || !latches.isEmpty || !contexts.isEmpty || !guards.isEmpty {invalidate(.focus)}
        } else {_=seal(.focus,now:now,focusMoved:false)}
    }
    /// No proof could be read for a key (an AX timeout, or keyboard focus in
    /// another app's panel). The key is dropped, nothing is read, and the
    /// live unit stays open: the next proven key continues it only if it is
    /// the same field (`admit` parks it otherwise). The latch is kept.
    public func unproven(now:UInt64) {discardParkedSpaces(includingLive:true);expire(now:now);promptLine(.gap,bundle:lastKeyBundle,proof:nil)}
    /// An ordinary boundary: the live unit is parked and judged after
    /// `settle`. `focusMoved` marks a tap-visible focus-moving input, after
    /// which a new unit is unconfirmed for `settle`. Tab/Esc (`focusKey`)
    /// clears a latch in the app of `proof`, or of the last key when no proof
    /// is given; no other seal clears it.
    @discardableResult public func seal(_ reason:SealReason,now:UInt64,focusMoved:Bool,proof:FocusProof?=nil) -> Bool {
        sealing(reason,now:now,focusMoved:focusMoved,proof:proof,lineUnseen:false)
    }
    private func sealing(_ reason:SealReason,now:UInt64,focusMoved:Bool,proof:FocusProof?,lineUnseen:Bool) -> Bool {
        if reason != .focus && reason != .window {discardParkedSpaces()}
        expire(now:now)
        // Return with no unit to commit (keys at a prompt were dropped): the
        // prompt is answered, and a command arm ends. Without a proof the
        // Return can't be tied to a focus: every latch app gets it, as a line
        // capture couldn't see.
        if reason == .submit {
            if let proof {promptSubmit(proof,line:live.flatMap {CaptureAuthorization.identity(proof) == $0.identity ? $0.text : nil})}
            else {promptSubmitUnproven()}
        } else {
            promptLine(lineUnseen ? .gap : reason,bundle:live?.bundle ?? proof?.bundle ?? lastKeyBundle,proof:proof)
        }
        if focusMoved {focusMovedAt=now}
        if reason.endsValue {endValue(proof?.bundle ?? lastKeyBundle)}
        if reason.mayChangeApp {lastKeyBundle=nil}
        if !keepsRun(reason) {for b in contexts.keys {contexts[b]?.soft=false}}
        guard let u=live else {return false}
        live=nil
        return park(u,reason,now:now)
    }

    /// Defer an automatic commit while a lifecycle drain owns write authority.
    /// Size boundaries retain the existing hard-cap head/carry and run identity.
    /// This admits nothing and uses only the unit's already admitted proof.
    @discardableResult public func deferCommit(_ reason:SealReason,now:UInt64) -> Bool {
        guard reason == .size,let u=live else {return seal(reason,now:now,focusMoved:false)}
        expire(now:now)
        guard live === u else {return false}
        let carry=u.cutForCap(limits)
        live=nil
        let kept=park(u,reason,now:now)
        if let carry,!carry.isEmpty {
            let next=TypedUnit(proof:u.proof,generation:u.generation,policyVersion:u.policyVersion,runID:u.runID,part:u.part+1,
                               context:contexts[u.bundle]?.text ?? "",separator:"",joinable:true,now:now,confirmAfter:nil)
            _=next.apply(.insert(String(carry)),eventAt:u.lastEditedAt,now:now,limits:limits)
            live=next
        }
        return kept
    }

    // MARK: Commits

    /// Live commit with a fresh proof read now. A different or unprovable
    /// field parks the unit instead; a deny reason discards everything.
    /// Return (`submit`) clears a latch in the proof's app even with no unit.
    public func commitLive(fresh:FocusProof,reason:SealReason,policy:CapturePolicy,now:UInt64,sentText:(() -> String?)?=nil,write:(TypingCommit) throws -> Bool) rethrows -> TypingOutcome {
        expire(now:now)
        // Return submits the line: a privileged command arms the prompt
        // latch before the next key (the command itself is saved and scrubbed).
        if reason == .submit {promptSubmit(fresh,line:live.flatMap {CaptureAuthorization.identity(fresh) == $0.identity ? $0.text : nil})}
        else {promptLine(reason,bundle:fresh.bundle,proof:fresh)}
        if reason.endsValue {endValue(fresh.bundle)}
        if !keepsRun(reason) {for b in contexts.keys {contexts[b]?.soft=false}}
        guard let u=live else {return .none}
        let gate=typingGate(fresh,policy,generation,now)
        guard gate.outcome == .allowed else {
            if CaptureGate.typingDenyReasons.contains(gate.reason) {invalidate(.focus);return .discarded(gate.reason)}
            live=nil;return park(u,.focus,now:now) ? .parked : .none
        }
        guard CaptureAuthorization.identity(fresh) == u.identity else {live=nil;return park(u,.focus,now:now) ? .parked : .none}
        u.observe(fresh)
        live=nil
        // Nothing but whitespace: no row, no latch, and the context is kept.
        guard u.hasText else {dropped(u,.empty);return .none}
        // Still unconfirmed: wait for the deadline, then require this field.
        if let after=u.confirmAfter {return park(u,reason,now:now,sameField:true,deadline:max(after,now)) ? .parked : .none}
        guard u.generation == generation,u.policyVersion == policy.version,policy.typedText else {dropped(u,.privacy);return .discarded(.generationChanged)}
        let carry=reason == .size ? u.cutForCap(limits) : nil
        // Keys the host handled late in it, not vouched for yet: judged here (this field, still focused), written once
        // they are (gold/r2-typing, golden 5 G7).
        let held=holdForLateKeys(u,reason:reason,now:now)
        if !held,reason == .submit,let sentText {adoptSentText(u,read:sentText,reason:reason)}
        let outcome=try held ? .parked : finish(u,reason:reason,proof:fresh,now:now,live:true,write:write)
        if case .rejected=outcome {return dropped(u,outcome)}
        if let carry,!carry.isEmpty {
            // Hard cap: the partial word continues the run in the next part.
            let next=TypedUnit(proof:fresh,generation:generation,policyVersion:policy.version,runID:u.runID,part:u.part+1,
                               context:contexts[fresh.bundle]?.text ?? "",separator:"",joinable:true,now:now,confirmAfter:nil)
            _=next.apply(.insert(String(carry)),eventAt:u.lastEditedAt,now:now,limits:limits)
            live=next
        }
        if held {boundLateHolds(now:now)}
        return outcome
    }
    /// messages-1003 (owner, 2026-10-03): at a send key the field's own value (read by the host just now, after this
    /// field's proof passed the gate) is what was sent; the keys rebuild it imperfectly (autocorrect, automatic
    /// capitals: "friendsr" typed, "friendr" sent). It replaces the unit's text only when
    /// - the unit is the whole message (its run's first part), and the keys' text passed the classifier whole, nothing
    ///   withheld;
    /// - the value is plain text of about the same length (autocorrect and capitals, not an older draft or another
    ///   message), with no attachment characters;
    /// - the value passes the same classifier whole (the typing log, with everything deleted, is still checked).
    /// Otherwise the keys' text stays. Nothing is stored here.
    func adoptSentText(_ u:TypedUnit,read:() -> String?,reason:SealReason) {
        guard u.part == 1,case .allow(_,let withheld)=UnitClassifier.verdict(u,limits:limits,trailingOpen:reason.trailingOpen),withheld == 0,
              let raw=read(),let value=Self.sentValue(raw,typed:u.text,limits:limits) else {return}
        let saved=u.replaceText(value)
        guard case .allow(_,let after)=UnitClassifier.verdict(u,limits:limits,trailingOpen:reason.trailingOpen),after == 0 else {u.restore(saved);return}
    }
    /// The field's value as the sent text, or nil when it can't stand for the keys' text.
    public static func sentValue(_ raw:String,typed:String,limits:TypingLimits=TypingLimits()) -> String? {
        var value=raw
        while let last=value.last,last == "\n" || last == "\r" {value.removeLast()}
        guard value.contains(where:{!$0.isWhitespace}),!value.contains("\u{FFFC}"),
              value.count<=limits.maxCharacters,value.utf8.count<=limits.maxBytes else {return nil}
        let typedCount=typed.trimmingCharacters(in:.whitespacesAndNewlines).count,valueCount=value.trimmingCharacters(in:.whitespacesAndNewlines).count
        guard abs(typedCount-valueCount)<=max(8,typedCount/4) else {return nil}
        return printable(value)
    }
    /// Resolves the oldest parked unit that is due (all of them with `force`).
    /// nil when none is due. `secureInput` is the OS state read now. A unit
    /// that holds keys the host handled late is judged at its deadline as
    /// usual but written only once those keys are vouched for (`lateCut`);
    /// until then it waits, judged, and is never written, even with `force`
    /// (gold/r2-typing, golden 5 G7). Judged, its destination was proven on
    /// time: once written it is not judged again.
    public func resolveParked(destination:TypingDestination,secureInput:Bool,policy:CapturePolicy,now:UInt64,force:Bool=false,write:(TypingCommit) throws -> Bool) rethrows -> TypingOutcome? {
        guard let i=parked.firstIndex(where:{!waitsForLateKeys($0) && (force || $0.deadline<=now)}) else {return nil}
        let p=parked.remove(at:i),u=p.unit
        if !p.judged {
            if secureInput {return dropped(u,.discarded(.secureInput))}
            if now>p.deadline,now-p.deadline>limits.lateResolution {return dropped(u,.discarded(.staleProof))}
        }
        guard u.generation == generation,u.policyVersion == policy.version else {return dropped(u,.discarded(.generationChanged))}
        guard policy.typedText else {return dropped(u,.discarded(.typingOff))}
        if !p.judged {
            // A destination proof that passes the gate settles it. A deny about
            // the destination itself discards. Anything else falls back to the
            // departure metadata.
            let dest=destination.proof.map {($0,typingGate($0,policy,generation,now))}
            if p.sameField {
                guard let (d,gate)=dest,gate.outcome == .allowed,CaptureAuthorization.identity(d) == u.identity else {return dropped(u,.discarded(.unconfirmedFocus))}
                u.observe(d)
            } else if let (_,gate)=dest,gate.outcome == .allowed {
            } else if let (_,gate)=dest,CaptureGate.typingDenyReasons.contains(gate.reason),gate.reason != .excludedApp {
                return dropped(u,.discarded(gate.reason))
            } else if !CaptureGate.departureAllows(destination.departure,from:u.proof) {
                return dropped(u,.discarded(.departureDenied))
            }
        }
        guard u.confirmAfter == nil else {return dropped(u,.discarded(.unconfirmedFocus))}
        guard u.hasText else {dropped(u,.empty);return TypingOutcome.none}
        // The unit's own last proof, judged against the current policy at the time it was read.
        let own=typingGate(u.proof,policy,generation,u.proof.checkedAt)
        guard own.outcome == .allowed else {return dropped(u,.discarded(own.reason))}
        if holdParkedForLateKeys(p,at:i) {boundLateHolds(now:now);return .parked}
        return dropped(u,try finish(u,reason:p.reason,proof:u.proof,now:now,live:false,write:write))
    }

    /// Esc. In a search panel the live unit, and any parked unit typed in
    /// that panel, is discarded (the search was abandoned). Elsewhere it is an
    /// ordinary Tab-like boundary (`focusKey`). Returns true when a unit was
    /// discarded.
    @discardableResult public func escape(now:UInt64,proof:FocusProof?=nil) -> Bool {
        expire(now:now)
        let panel=live.map {Self.isSearchPanel($0.proof)} ?? proof.map(Self.isSearchPanel) ?? false
        // Esc in a shell can edit the line (meta keys, vi mode): unseen.
        guard panel else {_=sealing(.focusKey,now:now,focusMoved:true,proof:proof,lineUnseen:true);return false}
        focusMovedAt=now
        endValue(proof?.bundle ?? live?.bundle ?? lastKeyBundle)
        for b in contexts.keys {contexts[b]?.soft=false}
        var dropped=false
        if let u=live {
            live=nil;dropped=true
            // Nothing of the abandoned search carries over as context.
            if contexts[u.bundle]?.identity == u.identity {contexts[u.bundle]=nil}
        }
        let before=parked.count
        parked.removeAll {Self.isSearchPanel($0.unit.proof) && (proof == nil || $0.unit.bundle == proof!.bundle)}
        return dropped || parked.count != before
    }

    // MARK: Internals

    /// The prompt latch for one key in `p`'s focus: nil records it, a
    /// decision drops it (nothing is read). Apps outside the latch pass.
    private func promptKey(_ p:FocusProof) -> PrivacyDecision? {
        guard promptLatchApps(p.bundle) else {unseenPending=false;interruptPending=false;return nil}
        var l=prompts[p.bundle] ?? TerminalPromptLatch()
        // An unread title keeps what was seen last in this focus.
        if p.place.isEmpty {l.focusChanged(to:p.focusID)} else {l.titleObserved(p.place,focusID:p.focusID)}
        takePending(&l,p)
        let decision=l.key(.text,focusID:p.focusID)
        prompts[p.bundle]=l
        guard decision == .drop else {return nil}
        // Whatever was being typed in this focus is not saved either.
        if let u=live,u.bundle == p.bundle {live=nil}
        return CaptureGate.result(.blocked,.terminalPrompt,p)
    }
    /// A unit in a latch app ended without Return (or the line changed where
    /// capture can't see): its latch learns what was typed into the shell
    /// line. Idle and size splits keep the line known; Tab (`focusKey`) keeps
    /// it known only after a complete, harmless command word; anything else
    /// makes it unknown. `proof` nil: the latch's own focus.
    private func promptLine(_ reason:SealReason,bundle:String?,proof:FocusProof?) {
        guard let bundle else {
            pend(reason)
            return
        }
        guard promptLatchApps(bundle) else {return}
        guard var l=prompts[bundle] ?? proof.map({_ in TerminalPromptLatch()}) else {
            pend(reason)
            return
        }
        let focus=proof?.focusID ?? l.focusID ?? ""
        // The ending unit's text, when it was typed in this focus.
        let typed=live.flatMap {u in u.bundle == bundle && u.proof.focusID == focus ? u.text : nil} ?? ""
        let key:TerminalPromptLatch.Key
        switch reason {
        case .idle,.size: key = .split(typed:typed,completion:false)
        case .focusKey: key = .split(typed:typed,completion:true)
        case _ where Self.interrupts.contains(reason): key = .interrupted(typed:typed)
        default: key = .unseen(typed:typed)
        }
        _=l.key(key,focusID:focus)
        prompts[bundle]=l
    }
    /// A pending unseen change lands in the latch of the first proven key after it.
    private func takePending(_ l:inout TerminalPromptLatch,_ p:FocusProof) {
        defer {unseenPending=false;interruptPending=false}
        if unseenPending {_=l.key(.unseen(typed:""),focusID:p.focusID)}
        else if interruptPending {_=l.key(.interrupted(typed:""),focusID:p.focusID)}
    }
    /// Ends that only stop capture watching the line (owner live test
    /// 2026-10-02): keyboard focus left the app or window, or a plain left
    /// click (the host reports any other button or a modified click as a
    /// possible edit: `pointerMayEdit`). A key capture missed never reached
    /// the line here. Everything else (a shortcut, paste, undo, a caret key,
    /// an unread key: `gap`) is a change capture couldn't see.
    static let interrupts:Set<SealReason>=[.app,.window,.focus,.pointer]
    private func pend(_ reason:SealReason) {
        if reason == .idle || reason == .size {return}
        if Self.interrupts.contains(reason) {interruptPending=true} else {unseenPending=true}
    }
    /// A right, middle or modified click (a context-menu Paste, a drop): the
    /// shell line in the next latch app may have changed unseen.
    public func pointerMayEdit() {unseenPending=true}
    /// Return with no readable proof: in every latch app, the live unit's text
    /// joins the line, the line counts as unseen, and the Return is submitted.
    private func promptSubmitUnproven() {
        for bundle in Array(prompts.keys) {
            promptLine(.gap,bundle:bundle,proof:nil)
            guard var l=prompts[bundle] else {continue}
            _=l.key(.submit(line:nil),focusID:l.focusID ?? "")
            prompts[bundle]=l
        }
    }
    /// Return in `p`'s focus, submitting `line` (nil when unknown).
    private func promptSubmit(_ p:FocusProof,line:String?) {
        guard promptLatchApps(p.bundle) else {unseenPending=false;interruptPending=false;return}
        var l=prompts[p.bundle] ?? TerminalPromptLatch()
        if !p.place.isEmpty {l.titleObserved(p.place,focusID:p.focusID)}
        takePending(&l,p)
        // The last line of the unit is what the shell runs.
        let submitted=line.map {String($0.split(separator:"\n",omittingEmptySubsequences:false).last ?? "")}
        _=l.key(.submit(line:submitted),focusID:p.focusID)
        prompts[p.bundle]=l
    }

    private func begin(_ proof:FocusProof,policy:CapturePolicy,now:UInt64) -> TypedUnit {
        expire(now:now)
        let id=CaptureAuthorization.identity(proof)
        var text="",separator="",runID=UUID().uuidString,part=1,joinable=false
        if let c=contexts[proof.bundle],!c.text.isEmpty {
            text=c.text;joinable=c.joinable
            if c.soft,c.identity == id {runID=c.runID;part=c.part+1} else {separator="\n"}
        }
        var guardHead=false
        if guards.removeValue(forKey:proof.bundle) != nil {guardHead=true}
        let confirmAfter=focusMovedAt.flatMap {now<$0 &+ limits.settle ? $0 &+ limits.settle : nil}
        let u=TypedUnit(proof:proof,generation:generation,policyVersion:policy.version,runID:runID,part:part,
                        context:text,separator:separator,joinable:joinable,guardHead:guardHead,now:now,confirmAfter:confirmAfter)
        live=u;return u
    }
    private func checked(_ u:TypedUnit,proof:FocusProof,gate:PrivacyDecision,now:UInt64) -> TypingStep {
        if let reason=UnitClassifier.perKey(u,limits:limits) {
            // Keep what was typed before the sentence or line that matched;
            // it is committed after the settle if the field is still focused.
            if live === u,let cut=u.cleanHeadCut() {
                u.truncateAll(to:cut);live=nil
                park(u,.sensitive,now:now,sameField:true,deadline:now)
            }
            latchApp(u.bundle,reason,now:now)
            return TypingStep(decision:CaptureGate.result(.blocked,reason,proof),commit:nil)
        }
        let count=u.model.characters.count
        if count>=limits.maxCharacters || u.model.utf8Count>=limits.maxBytes || u.typedLogBytes>=limits.typedLogBytes {return TypingStep(decision:gate,commit:.size)}
        if count>=limits.softSplitCharacters,closedTail(u) {return TypingStep(decision:gate,commit:.size)}
        return TypingStep(decision:gate,commit:nil)
    }
    /// Stops reads in `bundle`, drops its live unit, and leaves a marker as
    /// the context so a continuation is withheld.
    private func latchApp(_ bundle:String,_ reason:PrivacyReason,now:UInt64) {
        latches[bundle]=Latch(reason:reason,lastKeyAt:max(now,latches[bundle]?.lastKeyAt ?? 0))
        if live?.bundle == bundle {live=nil}
        guards[bundle]=nil
        contexts[bundle]=Context(identity:[],text:UnitClassifier.marker,until:now &+ limits.contextLifetime,soft:false,joinable:true,runID:"",part:0)
    }
    /// Return or Tab in `bundle`: the value ended. A latch there is cleared
    /// with its context and guard (the next line is not the secret).
    private func endValue(_ bundle:String?) {
        guard let bundle else {return}
        guards[bundle]=nil
        guard latches.removeValue(forKey:bundle) != nil else {return}
        contexts[bundle]=nil
    }
    /// A unit parked while unconfirmed is dropped and never becomes context.
    /// The context is what the unit would store, computed now so a unit that
    /// begins during the settle is classified against it.
    @discardableResult private func park(_ u:TypedUnit,_ reason:SealReason,now:UInt64,sameField:Bool=false,deadline:UInt64?=nil) -> Bool {
        if u.confirmAfter != nil,!sameField {dropped(u,.departure);return false}
        guard u.hasText else {
            // An AX focus/window notice can arrive after the first space of a
            // resumed draft. Keep only these already admitted ASCII keys until
            // the very next proven input, within the existing settle bound.
            // They never classify/write alone or become cross-field context.
            guard (reason == .focus || reason == .window), Self.onlyUneditedSpaces(u) else {dropped(u,.empty);return false}
            parked.append(Parked(unit:u,reason:reason,deadline:min(now &+ limits.settle,u.lastEditedAt &+ 400_000_000),sameField:true))
            evictParked()
            return true
        }
        setContext(u,UnitClassifier.verdict(u,limits:limits,trailingOpen:reason.trailingOpen),reason:reason,now:now)
        parked.append(Parked(unit:u,reason:reason,deadline:deadline ?? now &+ limits.settle,sameField:sameField))
        evictParked()
        return true
    }
    private static func onlyUneditedSpaces(_ u:TypedUnit) -> Bool {
        u.proof.surface == .native && u.confirmAfter == nil && u.edits == 0 && (1...16).contains(u.model.characters.count)
            && asciiSpacesOnly(u)
    }
    private static func asciiSpacesOnly(_ u:TypedUnit) -> Bool {
        !u.model.characters.isEmpty && u.model.characters.allSatisfy { $0 == " " }
            && u.typedLog.allSatisfy { $0 == " " }
    }
    private func discardParkedSpaces(includingLive:Bool=false) {
        // An uncertain key may precede the AX boundary. Do not let its live
        // native ASCII-only prefix become a resumable unit at the later seal.
        // Never drop a typed log containing other characters by this shortcut.
        if includingLive,let u=live,u.proof.surface == .native,Self.asciiSpacesOnly(u) {
            dropped(u,.empty);live=nil
        }
        for p in parked where !p.unit.hasText {dropped(p.unit,.empty)}
        parked.removeAll {!$0.unit.hasText}
    }
    private func resumeParkedSpaces(_ proof:FocusProof,now:UInt64) {
        let spaces=parked.filter {!$0.unit.hasText}
        guard !spaces.isEmpty else {return}
        parked.removeAll {!$0.unit.hasText}
        // A second boundary cannot extend the original deadline. Any other
        // field/input, stale generation/policy, late hold or uncertain start
        // discards the spaces, preserving all existing focus/privacy authority.
        if spaces.count == 1,let p=spaces.first,live == nil,
           Self.onlyUneditedSpaces(p.unit),now >= p.unit.lastEditedAt,now < p.deadline,!p.judged,!holdsLateKeys(p.unit),
           p.unit.identity == CaptureAuthorization.identity(proof),
           p.unit.generation == generation,proof.generation == generation,
           p.unit.policyVersion == proof.policyVersion {
            live=p.unit
        } else {for p in spaces {dropped(p.unit,.empty)}}
    }

    /// The context is the stored form: markers for withheld tokens, one
    /// marker for a rejected unit. A tail waiting for its value ("password:")
    /// or ending in a withheld token lasts `labelLifetime`.
    private func setContext(_ u:TypedUnit,_ verdict:UnitVerdict,reason:SealReason,now:UInt64) {
        let text:String
        switch verdict {
        case .reject:
            // "Password:" alone looks opaque and is rejected, but its value
            // may come next: keep the label (never the rest).
            text=UnitClassifier.marker+(TextClassifier.pendingLabelText(u.text).map {" "+$0} ?? "")
        case .allow(let output,_): text=String(output.suffix(limits.contextCharacters))
        }
        // A tail still waiting for its value, or a withheld tail that may be
        // continued, guards the next unit longer.
        // Review round 1: a bare label too ("wifi pw ", then a pause to look the password up).
        let waiting=TextClassifier.pendingLabel(text) || TextClassifier.bareLabel(text) || text.trimmingCharacters(in:.whitespaces).hasSuffix(UnitClassifier.marker)
        // A soft split (idle, size) keeps the run open longer, so a thinking pause doesn't start a new draft.
        let lifetime=waiting ? limits.labelLifetime : reason.soft ? max(limits.contextLifetime,limits.softRunJoin) : limits.contextLifetime
        contexts[u.bundle]=Context(identity:u.identity,text:text,until:now &+ lifetime,soft:keepsRun(reason),
                                   joinable:!reason.endsValue,runID:u.runID,part:u.part)
    }
    private func finish(_ u:TypedUnit,reason:SealReason,proof:FocusProof,now:UInt64,live isLive:Bool,write:(TypingCommit) throws -> Bool) rethrows -> TypingOutcome {
        let verdict=UnitClassifier.verdict(u,limits:limits,trailingOpen:reason.trailingOpen)
        if isLive {setContext(u,verdict,reason:reason,now:now)}
        switch verdict {
        case .reject(let r):
            // A secret the user may still be typing latches the app: any
            // rejection for a secret pattern, live or parked, except at Return
            // or Tab (the value ended there).
            if Self.latching.contains(r),!reason.endsValue {latchApp(u.bundle,r,now:now)}
            return .rejected(r)
        case .allow(let text,let withheld):
            let commit=TypingCommit(text:text,proof:proof,runID:u.runID,part:u.part,reason:reason,startedAt:u.startedAt,lastEditedAt:u.lastEditedAt,keys:u.keys,edits:u.edits,withheld:withheld)
            return try write(commit) ? .committed(withheld:withheld) : .notWritten
        }
    }
    /// Rejections that mean a secret was typed (not size or a lone number).
    static let latching:Set<PrivacyReason>=[.credentialPattern,.privateKey,.paymentIdentifier,.identityIdentifier,.sensitiveContext,.suspiciousOpaque]
    /// Closed tail: ends in whitespace or . ! ? … (closing quotes and
    /// brackets ignored), and not in a label still waiting for its value
    /// ("password: ") or a digit group ("4111 1111 "), so a label and its
    /// value, or the groups of one number, stay in one unit across a pause.
    func closedTail(_ u:TypedUnit) -> Bool {
        let chars=u.model.characters
        guard let i=chars.lastIndex(where:{!"\"')]}\u{201D}\u{2019}\u{00BB}".contains($0)}) else {return true}
        let c=chars[i]
        guard c.isWhitespace || ".!?\u{2026}".contains(c) else {return false}
        let tail=String(chars.suffix(64))
        if TextClassifier.pendingLabel(tail) {return false}
        if c.isWhitespace,let last=tail.split(whereSeparator:{$0.isWhitespace}).last,TextClassifier.digitGroup(last) {return false}
        return true
    }
    /// The unit ends inside a plain word: its last character is a letter and its last token is letters only (an
    /// apostrophe or hyphen inside is fine), not a label waiting for its value and nothing secret-shaped.
    /// build/launch: nor a tail that names a secret ("the passphrase is corre", "wifi pw blue"): a value may be in
    /// progress there, and the short pause cut it (typed-secret-fuzz: a passphrase split at the pause kept its words).
    /// Such a tail keeps the long wait (`idleOpen`), as before the short pause.
    func plainWordTail(_ u:TypedUnit) -> Bool {
        let chars=u.model.characters
        guard let last=chars.last,last.isLetter else {return false}
        let tail=String(chars.suffix(64))
        guard let token=tail.split(whereSeparator:{$0.isWhitespace}).last,
              token.allSatisfy({$0.isLetter || $0 == "'" || $0 == "\u{2019}" || $0 == "-"}) else {return false}
        return !TextClassifier.pendingLabel(tail) && !TextClassifier.sensitiveLabel(tail) && !TextClassifier.bareLabel(tail)
            && !TextClassifier.suspiciousPartial(token) && !TextClassifier.opaqueToken(token)
    }
    static func printable(_ s:String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter {
            ($0 == "\n" || !CharacterSet.controlCharacters.contains($0)) && !(0xF700...0xF8FF).contains($0.value)
        })).precomposedStringWithCanonicalMapping
    }
}

// MARK: - The late-key cut (gold/capture-input, golden 5 G7)

/// Keys the host handled late (its main thread was busy) are read into the open unit like any other key, so the
/// unit's end decides it as if there had been no stall: the typing pause drops the whole draft, a secret completed
/// across the stall drops its sentence, Backspace edits across it. If the late keys turn out unsafe afterwards (focus
/// may have moved before they were typed), they alone are dropped, with anything typed after them; what was typed on
/// time before them is kept and parked like at any gap. Nothing here writes. Until the late keys are vouched for
/// (`releaseLateCut`) or dropped (`rollBackLate`), nothing that may hold them is written either: a live commit or a
/// parked unit's settle judges it on time and keeps it (`waitsForLateKeys`, gold/r2-typing: a secret cut to its clean
/// head was parked with no settle and written before a click in the backlog could drop its late keys).
///
/// One cut per backlog of late keys, oldest first (gold/r2-typing review round 1). Each backlog is decided on its own:
/// vouched for (`releaseLateCut(through:)`), or dropped with every newer one (`rollBackLate(from:)`). A unit waits only
/// while the oldest undecided backlog may be in it, so late keys that keep coming never keep an older backlog, or the
/// lines ended after it, waiting; and dropping a backlog never drops a line kept before it. A unit that waits is never
/// dropped to make room (`evictParked`, `boundLateHolds`).
extension TypingSession {
    fileprivate struct LateCut {
        let id:UInt64
        /// The unit open at the backlog's first late key (nil: none), and its state then.
        let unit:TypedUnit?, mark:TypedUnitMark?
        /// Units parked before that key: none of them holds a key of this backlog or of a newer one.
        let parkedBefore:[TypedUnit]
    }
    /// Before the first late key of a backlog is applied: marks what was typed on time before it. Returns the cut's id,
    /// which decides that backlog later.
    @discardableResult public func markLateCut() -> UInt64 {
        lateCutSerial &+= 1
        lateCuts.append(LateCut(id:lateCutSerial,unit:live,mark:live?.mark(),parkedBefore:parked.map(\.unit)))
        return lateCutSerial
    }
    public var hasLateCut:Bool {!lateCuts.isEmpty}
    /// Whether that cut's backlog is still undecided (not vouched for, dropped, or gone at a privacy boundary).
    public func holdsLateCut(_ id:UInt64) -> Bool {lateCuts.contains {$0.id == id}}
    /// The late keys of the cut `id` and of every older cut are vouched for (nil: every cut): the marks are let go, and
    /// what waited only for them (`waitsForLateKeys`) is due for its write.
    public func releaseLateCut(through id:UInt64?=nil) {
        guard let id else {lateCuts.removeAll();return}
        guard let k=lateCuts.firstIndex(where:{$0.id == id}) else {return}
        lateCuts.removeSubrange(...k)
    }
    /// A unit judged on time that waited for late keys and is free now (they were vouched for, or it was cut back to
    /// the text typed on time): due for its write at once, before anything can drop it.
    public var hasFreedJudged:Bool {parked.contains {$0.judged && !waitsForLateKeys($0)}}
    /// A unit begun or parked since the oldest undecided cut, the open unit at that cut included: it may hold late keys.
    private func holdsLateKeys(_ u:TypedUnit) -> Bool {
        guard let cut=lateCuts.first else {return false}
        return !cut.parkedBefore.contains {$0 === u}
    }
    /// Judged on time, and its late keys are still undecided: no deadline, no write, until they are.
    private func waitsForLateKeys(_ p:Parked) -> Bool {p.judged && holdsLateKeys(p.unit)}
    /// The parked FIFO drops its oldest unit past `maxParked`, never one that waits for late keys (round 1: under steady
    /// stalls, once five lines waited, the oldest was lost without a trace).
    fileprivate func evictParked() {
        guard parked.filter({!waitsForLateKeys($0)}).count>limits.maxParked,let i=parked.firstIndex(where:{!waitsForLateKeys($0)}) else {return}
        dropped(parked.remove(at:i).unit,.capacity)
    }
    /// Past `maxHeldForLateKeys` units waiting: the oldest late keys are decided now, the safe way (`rollBackLate`).
    fileprivate func boundLateHolds(now:UInt64) {
        guard parked.filter({waitsForLateKeys($0)}).count>limits.maxHeldForLateKeys,let oldest=lateCuts.first else {return}
        rollBackLate(from:oldest.id,now:now,focusMoved:false)
    }
    /// A live commit (same field, proven now) of a unit that may hold late keys not vouched for yet: kept, judged, and
    /// written once they are (never before: a change heard or seen in the backlog may still show they went
    /// elsewhere). A secret is not kept: it is refused now, as `finish` refuses it. True when kept.
    private func holdForLateKeys(_ u:TypedUnit,reason:SealReason,now:UInt64) -> Bool {
        guard holdsLateKeys(u) else {return false}
        let verdict=UnitClassifier.verdict(u,limits:limits,trailingOpen:reason.trailingOpen)
        guard case .allow=verdict else {return false}
        setContext(u,verdict,reason:reason,now:now)
        parked.append(Parked(unit:u,reason:reason,deadline:now,sameField:true,judged:true))
        return true
    }
    /// The same for a parked unit whose destination was just judged: put back, judged, where it was. True when kept.
    private func holdParkedForLateKeys(_ p:Parked,at index:Int) -> Bool {
        guard holdsLateKeys(p.unit),case .allow=UnitClassifier.verdict(p.unit,limits:limits,trailingOpen:p.reason.trailingOpen) else {return false}
        var held=p;held.judged=true
        parked.insert(held,at:min(index,parked.count))
        return true
    }
    /// The late keys of the cut `from` (nil: the oldest) can't be vouched for. Dropped: every unit begun or parked
    /// after that cut, and every newer cut; older cuts stay undecided. Kept: the unit open at the cut, back to what it
    /// held then. Judged on time already (it ended and its field was proven), it stays judged and is written as soon
    /// as no older backlog holds it, as with no stall (round 1: parked again for a settle, a privacy boundary in that
    /// settle dropped the text typed on time too). Otherwise it is parked for the settle (`gap`) and judged as usual,
    /// or with `keepOpen` (a key with no proof, which never ends a unit) open again. A unit the session already
    /// dropped (a latch, an abandoned search, a pause) or wrote stays that way. A unit parked because a late key
    /// completed a secret (`sensitive`) keeps the clean head it was cut to, never more than the cut. A draft that is a
    /// secret as a whole is dropped (and its app latched), as its end would have done. A cut already decided: nothing
    /// is left to drop. No cut held and none named: everything pending is dropped. True when the text typed on time is
    /// kept.
    @discardableResult public func rollBackLate(from id:UInt64?=nil,now:UInt64,focusMoved:Bool,keepOpen:Bool=false) -> Bool {
        let k:Int
        if let id {
            guard let i=lateCuts.firstIndex(where:{$0.id == id}) else {return false}
            k=i
        } else {
            guard !lateCuts.isEmpty else {live=nil;parked.removeAll();return false}
            k=0
        }
        let cut=lateCuts[k]
        lateCuts.removeSubrange(k...)
        expire(now:now)
        let unit=cut.unit
        let wasLive=unit.map {live === $0} ?? false
        let parkedEntry=unit.flatMap {u in parked.first(where:{$0.unit === u})}
        live=nil
        parked.removeAll {p in !cut.parkedBefore.contains(where:{$0 === p.unit})}
        guard let u=unit,let mark=cut.mark,wasLive || parkedEntry != nil else {return false}
        if let p=parkedEntry,p.reason == .sensitive {
            // Its settle stands (and its judgement, when it was already judged: `judged`): only its late keys were in doubt.
            if u.characterCount>mark.characterCount {u.restore(mark,confirmed:p.judged)}
            parked.append(p)
            return true
        }
        // A secret the whole draft completes stays one: the draft is dropped and its app latched, as the draft's own
        // end would have done. Dropping the late keys must never let the head of that sentence through.
        let reason=parkedEntry?.reason ?? .gap
        if case .reject(let r)=UnitClassifier.verdict(u,limits:limits,trailingOpen:reason.trailingOpen),Self.latching.contains(r) {
            if !reason.endsValue {latchApp(u.bundle,r,now:now)}
            return false
        }
        let judged=parkedEntry?.judged == true
        u.restore(mark,confirmed:judged)
        live=u
        if judged {
            // Parked at the gap like any unit cut there (its context, the latch lines), then judged as it was.
            guard seal(.gap,now:now,focusMoved:focusMoved),let i=parked.lastIndex(where:{$0.unit === u}) else {return false}
            let q=parked[i]
            parked[i]=Parked(unit:u,reason:q.reason,deadline:now,sameField:true,judged:true)
            return true
        }
        return keepOpen || seal(.gap,now:now,focusMoved:focusMoved)
    }
}
