import Foundation
import MemoryCore
import PrivacyPolicy
import BrowserBridge

/// Native capture executor binding. The host must supply independently verified
/// metadata and invalidate every focus/navigation/pause boundary. No OS grants
/// or browser identity claims are manufactured by this adapter.
public final class CoreCaptureBinding: @unchecked Sendable {
    // Synchronous capture boundary: never suspend between a fresh native proof
    // and acquiring characters. One recursive lock also serializes invalidation.
    private let lock=NSRecursiveLock()
    /// claude/cc-label-1003: the AI tool (by process name) a terminal app's own processes run, when exactly one runs; nil
    /// when none or unknown. The host sets it (MacMemApp `TerminalToolProcesses`); never asked for a line that isn't a prompt.
    public var terminalToolProbe:((String)->String?)?
    private let store:MemoryStore
    private let typing:TypingSession
    private var policyRevision=""
    private var policyVersion:UInt64=0
    private struct BrowserChannel {
        let session:AuthenticatedMetadataSession, pins:MetadataPins
        let integrationValidated:Bool, physicalDeviceValidated:Bool
    }
    private var browserChannels:[String:BrowserChannel]=[:]
    private var browserEpoch=""
    /// summaries/v3: Mail's To-field name and the paste mark, per window (memory only, under `lock`).
    private let recipients=RecipientMemory()
    private let pastes=PasteMemory()
    /// Wall clock for the typing pause (checks set a fixed clock).
    public var wallClock:@Sendable ()->Date = {Date()}
    /// `promptLatchApps`: which apps go through the terminal prompt latch
    /// (default: the table's terminals and editors with a terminal). Checks
    /// substitute an app the capture gate admits today.
    public init(store:MemoryStore,promptLatchApps:@escaping @Sendable (String)->Bool = TypingSession.tablePromptLatch) {
        self.store=store;typing=TypingSession(promptLatchApps:promptLatchApps)
    }
    public func invalidate(_ reason:PrivacyBoundary) {
        lock.lock();defer{lock.unlock()};typing.invalidate(reason);recipients.forget()
        for channel in browserChannels.values {channel.session.invalidate()}
    }
    public func context() throws -> (generation:UInt64,policy:CapturePolicy,revision:String) {
        lock.lock();defer{lock.unlock()}
        let saved=try store.policy()
        // Hard rule (safe typing B): typed text is read only while the vault
        // can encrypt it. A vault change is a policy boundary like any other.
        let vaultReady=store.typingUnlocked
        // Safe typing E/F: consent v2, categories and the typing pause come
        // from the typed policy row; a change there is a policy boundary too.
        let typed=try store.typedTextPolicy(),wall=wallClock(),paused=typed.snoozed(now:wall)
        let effective=saved.revision+(vaultReady ? "|typed-vault-ready" : "|typed-vault-locked")+"|"+typed.captureFingerprint(now:wall)
        if effective != policyRevision { policyRevision=effective;policyVersion &+= 1;invalidate(.policy) }
        var policy=CapturePolicy();policy.version=policyVersion
        policy.typedText=saved.captureText && saved.typedConsentVersion==1 && typed.consented && vaultReady && !paused
        // Deny-only: apps whose category is off or that the release gate
        // doesn't allow join the excluded set. No CaptureGate change.
        policy.excludedApps=Set(saved.blockedApps+PrivacySettings.sensitiveApps).union(typed.excludedBundles())
        policy.excludedDomains=Set(saved.blockedDomains+PrivacySettings.sensitiveDomains)
        return (typing.generation,policy,saved.revision)
    }
    /// Native setup only: pins come from reviewed enrollment, never a hello key.
    /// Validation is supplied from actual release/device evidence, never inferred.
    public func openBrowser(pins:MetadataPins,clientNonce:String,integrationValidated:Bool=false,physicalDeviceValidated:Bool=false)->String? {
        lock.lock();defer{lock.unlock()}
        guard !browserChannels.values.contains(where:{$0.pins.browser==pins.browser}) else {return nil}
        guard let session=AuthenticatedMetadataSession(pins:pins,clientNonce:clientNonce) else {return nil}
        let handle=UUID().uuidString
        browserChannels[handle]=BrowserChannel(session:session,pins:pins,integrationValidated:integrationValidated,physicalDeviceValidated:physicalDeviceValidated)
        return handle
    }
    public func closeBrowser(_ handle:String) {
        lock.lock();defer{lock.unlock()};browserChannels.removeValue(forKey:handle)?.session.close()
    }
    public func closeBrowsers() {
        lock.lock();defer{lock.unlock()};for channel in browserChannels.values {channel.session.close()};browserChannels.removeAll()
    }
    private func browserState(_ channel:BrowserChannel,native:MetadataGate,now:UInt64,wallTime:Date)throws->(BridgePolicy,MetadataGate,CapturePolicy,String,String)? {
        let current=try context(),capture=try store.captureStatus(now:wallTime),epoch=capture["epoch"] ?? ""
        if browserEpoch != epoch {browserEpoch=epoch;for held in browserChannels.values {held.session.invalidate()}}
        guard capture["state"]=="recording",UUID(uuidString:epoch) != nil,
              native.generation==Int(current.generation),native.captureEnabled,!native.excluded,
              native.frontmostBrowserBundle==channel.pins.browser.bundle,
              BrowserMetadataGate.preflight(bundle:native.frontmostBrowserBundle,secureInput:native.secureInputOff ? .no : .unknown,policy:current.policy)
        else {channel.session.invalidate();return nil}
        var gate=native;gate.captureEnabled=true
        let domains=Set(current.policy.excludedDomains.map{$0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"."))})
        let policy=BridgePolicy.masterRecording(true,integrationValidated:channel.integrationValidated,
            physicalDeviceValidated:channel.physicalDeviceValidated,revision:Int(current.policy.version),excludedDomains:domains)
        return (policy,gate,current.policy,current.revision,epoch)
    }
    /// Call immediately for the active page, then at a bounded cadence (100 ms
    /// minimum). There is no ten-second delay before the first observation.
    public func requestBrowser(_ handle:String,native:MetadataGate,now:UInt64,wallTime:Date=Date())throws->Data? {
        lock.lock();defer{lock.unlock()}
        guard let channel=browserChannels[handle],let state=try browserState(channel,native:native,now:now,wallTime:wallTime) else {return nil}
        return channel.session.request(policy:state.0,gate:state.1,now:now,privacyAllowsOrigins:{_ in false},privacyAllowsOrdinaryMetadata:{true})
    }
    /// The only browser-owned commit entry accepts signed bytes, not a renderer
    /// boolean or constructible store proof. Verification and commit never suspend.
    public func receiveBrowser(_ handle:String,frame:Data,native:MetadataGate,now:UInt64,wallTime:Date=Date())throws->Bool {
        lock.lock();defer{lock.unlock()}
        guard let channel=browserChannels[handle],let state=try browserState(channel,native:native,now:now,wallTime:wallTime) else {return false}
        let accepted=channel.session.receive(frame,policy:state.0,gate:state.1,now:now,privacyAllowsMetadata:{ observation in
            var proof=BrowserMetadataProof()
            proof.bundle=channel.pins.browser.bundle;proof.origin=observation.origin;proof.role=observation.role
            proof.sessionID=channel.session.sessionID;proof.generation=UInt64(native.generation)
            proof.policyVersion=state.2.version;proof.checkedAt=native.checkedAt;proof.authenticated=true
            proof.normalWindow=observation.windowMode=="normal";proof.normalTab=observation.tabMode=="normal"
            proof.noneditable=observation.safety=="noneditable";proof.secureInput=native.secureInputOff ? .no : .unknown
            proof.windowID=observation.windowID;proof.tabID=observation.tabID;proof.frameID=observation.frameID
            proof.documentID=observation.documentID;proof.focusID=observation.focusID
            proof.navigationGeneration=observation.navigationGeneration;proof.focusGeneration=observation.focusGeneration
            return BrowserMetadataGate.allows(proof,policy:state.2,generation:UInt64(native.generation),now:now)
        })
        guard let event=accepted else {return false}
        let o=event.observation
        var proof=BrowserVerification(mode:"normal",windowID:String(o.windowID),tabID:String(o.tabID),focusedRole:o.role,checkedAt:iso(wallTime),provider:"browser-extension-v3")
        proof.documentID=o.documentID;proof.frameID=o.frameID;proof.navigationGeneration=o.navigationGeneration
        proof.focusID=o.focusID;proof.focusGeneration=o.focusGeneration;proof.sessionID=event.sessionID
        proof.policyRevision=state.3;proof.captureEpoch=state.4;proof.captureGeneration=UInt64(native.generation)
        proof.extensionID=channel.pins.extensionID;proof.browserNamespace=event.browser.rawValue;proof.continuousNanoseconds=event.continuousNanoseconds
        let id="browser_"+fingerprint(event.sessionID+"|"+o.nonce)
        let evidence=Evidence(id:id,at:iso(wallTime),kind:event.kind,app:event.browser == .chrome ? "Chrome" : "Safari",bundle:event.browser.bundle,url:o.origin,browserVerification:proof)
        return try store.ingest(evidence,now:wallTime,expectedPolicyRevision:state.3,requireRecording:true,preserveExisting:true,expectedCaptureEpoch:state.4)
    }
    // MARK: Typing pause (safe typing F)

    /// "Don't record typing for 10 minutes". Stored, so it survives a relaunch;
    /// pressing it again while paused does not extend it. The unfinished
    /// draft and any parked one are dropped, never saved.
    @discardableResult public func snoozeTyping(minutes:Int=10) throws -> Date {
        lock.lock();defer{lock.unlock()}
        let until=try store.snoozeTyping(minutes:minutes,now:wallClock())
        typing.invalidate(.pause)
        _=try context()
        return until
    }
    /// "Record typing again".
    public func resumeTyping() throws {
        lock.lock();defer{lock.unlock()}
        try store.resumeTyping(now:wallClock())
        _=try context()
    }

    // MARK: Typed units (TypingSession under this lock)

    /// readCharacters is called only AFTER metadata authorization, under the
    /// lock: recording state, then the gate, then the latch, then the read.
    /// No NSEvent.characters/AX value/clipboard read may precede this entry point.
    public func insert(proof:FocusProof,eventAt:UInt64,now:UInt64,deadKey:DeadKey?=nil,compositionFinal:Bool=true,readCharacters:() throws -> String) throws -> TypingStep {
        lock.lock();defer{lock.unlock()}
        let current=try context()
        guard try store.captureStatus()["state"] == "recording" else { typing.invalidate(.pause);throw MemError.invalid("Capture is not recording") }
        let gate=CaptureGate.typing(proof,policy:current.policy,generation:current.generation,now:now)
        guard gate.outcome == .allowed else { recipients.editedUnknown(now:eventAt);typing.refuse(gate,now:now);return TypingStep(decision:gate,commit:nil) }
        editedRecipient(proof,now:eventAt)
        if let latched=typing.admit(proof,now:now) {return TypingStep(decision:latched,commit:nil)}
        let raw=try readCharacters()
        return typing.insert(deadKey.map {$0.compose(raw)} ?? raw,proof:proof,policy:current.policy,eventAt:eventAt,now:now,compositionFinal:compositionFinal)
    }
    private func editedRecipient(_ proof:FocusProof,now:UInt64) {
        guard proof.bundle == SendRules.mailApp else {return}
        let field=proof.sendField.isEmpty ? SendRules.fieldClass(role:proof.role,labels:[proof.fieldLabel]) : proof.sendField
        if field == "to" {recipients.editedTo(window:proof.windowID,now:now)}
    }
    /// Paste/undo/redo change a field without readable characters. Called before
    /// saving/retracting the previous unit, including when no live unit exists.
    public func recipientExternallyEdited(proof:FocusProof?,eventAt:UInt64,now:UInt64) throws {
        lock.lock();defer{lock.unlock()}
        let current=try context()
        guard let proof,CaptureGate.typing(proof,policy:current.policy,generation:current.generation,now:now).outcome == .allowed else {
            recipients.editedUnknown(now:eventAt);return
        }
        editedRecipient(proof,now:eventAt)
    }
    /// Compatibility wrapper: one insert whose time is also the event time.
    public func append(proof:FocusProof,now:UInt64,compositionFinal:Bool=true,readCharacters:() throws -> String) throws -> PrivacyDecision {
        try insert(proof:proof,eventAt:now,now:now,compositionFinal:compositionFinal,readCharacters:readCharacters).decision
    }
    /// Backspace family, in-run caret moves, Cmd-X. Nothing is read.
    public func edit(_ op:TypingOp,proof:FocusProof,eventAt:UInt64,now:UInt64) throws -> TypingStep {
        lock.lock();defer{lock.unlock()}
        let current=try context()
        let gate=CaptureGate.typing(proof,policy:current.policy,generation:current.generation,now:now)
        if gate.outcome != .allowed {recipients.editedUnknown(now:eventAt)}
        switch op {
        case .insert, .deleteBackward, .deleteForward, .cutSelection:
            if gate.outcome == .allowed {
                editedRecipient(proof,now:eventAt)
            }
        default: break
        }
        return typing.apply(op,proof:proof,policy:current.policy,eventAt:eventAt,now:now)
    }
    /// An ordinary boundary: park the live unit for the settle. `proof`
    /// names the app for Return/Tab, which clear a latch there.
    public func seal(_ reason:SealReason,now:UInt64,focusMoved:Bool,proof:FocusProof?=nil) {
        lock.lock();defer{lock.unlock()};typing.seal(reason,now:now,focusMoved:focusMoved,proof:proof)
    }
    /// Esc: in a search panel (Spotlight, Raycast, a search field) the
    /// unfinished search is discarded, never saved; elsewhere it is an
    /// ordinary Tab-like boundary. `proof` is where Esc was pressed, if read.
    @discardableResult public func escape(now:UInt64,proof:FocusProof?=nil) -> Bool {
        lock.lock();defer{lock.unlock()};return typing.escape(now:now,proof:proof)
    }
    /// Whether keys in this focus are dropped at a terminal password prompt now.
    public func promptArmed(_ proof:FocusProof) -> Bool {lock.lock();defer{lock.unlock()};return typing.promptArmed(proof)}
    /// No proof could be read for a key: the key is dropped, the unit and
    /// the latch are kept.
    public func unproven(now:UInt64) {lock.lock();defer{lock.unlock()};typing.unproven(now:now)}
    /// Drops typing state that has run out (context, latch, guard).
    public func expireTyping(now:UInt64) {lock.lock();defer{lock.unlock()};typing.expire(now:now)}
    public func retract() {lock.lock();defer{lock.unlock()};typing.retract()}
    /// A right, middle or modified click: a terminal line may have changed unseen (`TypingSession.pointerMayEdit`).
    public func pointerMayEdit() {lock.lock();defer{lock.unlock()};typing.pointerMayEdit()}
    /// Control-U or Control-C in a terminal: the unsent line is dropped, never saved (`TypingSession.eraseLine`).
    @discardableResult public func eraseLine(_ how:TypingSession.LineErase,now:UInt64) -> Bool {lock.lock();defer{lock.unlock()};return typing.eraseLine(how,now:now)}
    public var hasPendingTyping:Bool {lock.lock();defer{lock.unlock()};return typing.hasLive}
    /// A repeated native AX notification is not a boundary when a fresh,
    /// allowed proof still names the live unit's exact field and window.
    /// Browser joins retain their separate boundary handling.
    public func matchesLiveNativeFocus(_ proof:FocusProof,now:UInt64) throws -> Bool {
        lock.lock();defer{lock.unlock()}
        let current=try context()
        guard proof.surface == .native,
              try store.captureStatus()["state"] == "recording",
              CaptureGate.typing(proof,policy:current.policy,generation:current.generation,now:now).outcome == .allowed
        else {return false}
        return typing.matchesLiveFocus(proof)
    }
    // gold/capture-input (golden 5 G7): keys the host handled late join the open unit; if they turn out unsafe, only
    // they are dropped (`TypingSession.rollBackLate`). Nothing here writes.
    // gold/r2-typing review round 1: one cut per backlog of late keys, each decided on its own by its id.
    @discardableResult public func markLateCut() -> UInt64 {lock.lock();defer{lock.unlock()};return typing.markLateCut()}
    public var hasLateCut:Bool {lock.lock();defer{lock.unlock()};return typing.hasLateCut}
    public func holdsLateCut(_ id:UInt64) -> Bool {lock.lock();defer{lock.unlock()};return typing.holdsLateCut(id)}
    public func releaseLateCut(through id:UInt64?=nil) {lock.lock();defer{lock.unlock()};typing.releaseLateCut(through:id)}
    /// A unit judged on time that waited for late keys is free now: the host writes it at once.
    public var hasFreedJudged:Bool {lock.lock();defer{lock.unlock()};return typing.hasFreedJudged}
    @discardableResult public func rollBackLate(from id:UInt64?=nil,now:UInt64,focusMoved:Bool,keepOpen:Bool=false) -> Bool {
        lock.lock();defer{lock.unlock()};return typing.rollBackLate(from:id,now:now,focusMoved:focusMoved,keepOpen:keepOpen)
    }
    /// Monotonic deadlines the host schedules: the idle commit of the live
    /// unit, the earliest parked unit's settle, and housekeeping (`expireTyping`).
    public func typingDeadlines() -> (idle:UInt64?,parked:UInt64?,housekeeping:UInt64?) {
        lock.lock();defer{lock.unlock()};return (typing.idleDeadline,typing.nextParkedDeadline,typing.housekeepingDeadline)
    }
    public func parkedDue(now:UInt64,force:Bool=false) -> Bool {
        lock.lock();defer{lock.unlock()}
        guard let next=typing.nextParkedDeadline else {return false}
        return force || next<=now
    }
    /// Metadata gate for markers, with this binding's generation and policy.
    public func typingDecision(_ proof:FocusProof,now:UInt64) throws -> PrivacyDecision {
        lock.lock();defer{lock.unlock()}
        let current=try context()
        return CaptureGate.typing(proof,policy:current.policy,generation:current.generation,now:now)
    }
    /// Live commit: `proof` is a fresh proof read now. A different field
    /// parks the unit instead; a deny discards everything.
    /// `sentText` (messages-1003): at a send key in Messages, reads the field's value; asked only after this proof passed
    /// the gate, under this lock, and only for a unit that can adopt it (`TypingSession.adoptSentText`).
    public func commitText(id:String,proof:FocusProof,now:UInt64,wallTime:Date=Date(),reason:SealReason = .idle,sentText:(() -> String?)?=nil) throws -> Bool {
        lock.lock();defer{lock.unlock()}
        let current=try context()
        let outcome=try typing.commitLive(fresh:proof,reason:reason,policy:current.policy,now:now,sentText:sentText) {
            try write($0,id:id,current:current,now:now,wallTime:wallTime)
        }
        if case .committed=outcome {return true}
        return false
    }
    /// Parked commit of the oldest due unit (all with `force`). nil when none
    /// is due; otherwise whether a row was written.
    public func commitParked(id:String,destination:TypingDestination,secureInput:Bool,now:UInt64,wallTime:Date=Date(),force:Bool=false) throws -> Bool? {
        lock.lock();defer{lock.unlock()}
        let current=try context()
        guard let outcome=try typing.resolveParked(destination:destination,secureInput:secureInput,policy:current.policy,now:now,force:force,write:{
            try write($0,id:id,current:current,now:now,wallTime:wallTime)
        }) else {return nil}
        if case .committed=outcome {return true}
        return false
    }
    /// The one typed-text write path, inside the classification critical
    /// section: the store's own secret check (a match means no row), then
    /// Evidence with v2 and typed-unit provenance, then an ingest bound to the
    /// policy revision and to recording state.
    private func write(_ c:TypingCommit,id:String,current:(generation:UInt64,policy:CapturePolicy,revision:String),now:UInt64,wallTime:Date) throws -> Bool {
        guard !Privacy.secret(c.text) else {return false}
        let started=wallTime.addingTimeInterval(-Double(now>=c.startedAt ? now-c.startedAt : 0)/1_000_000_000)
        // The place label is the window title from the proof. The store runs
        // it through the title rules and the secret scrubber like the words.
        var event=Evidence(id:id,at:iso(wallTime),kind:"keyboard.text_input",app:AppNames.display(app:"",bundle:c.proof.bundle),bundle:c.proof.bundle,title:c.proof.place,text:c.text)
        event.captureProvenance=NativeCaptureProvenance(policyRevision:current.revision,classifierVersion:UnitClassifier.version,windowID:c.proof.windowID,focusID:c.proof.focusID,checkedAt:iso(wallTime),generation:c.proof.generation,
            unit:TypedUnitProvenance(runID:c.runID,part:c.part,sealReason:c.reason.rawValue,startedAt:iso(started),
                                     keys:c.withheld>0 ? nil : c.keys,edits:c.withheld>0 ? nil : c.edits,withheld:c.withheld))
        // summaries/v3 (spec §3, §4): the send facts, decided by code from the unit's own place (never the last window
        // change), its field and its seal. A Mail To unit remembers one short name for the email units after it.
        let field=c.proof.sendField.isEmpty ? SendRules.fieldClass(role:c.proof.role,labels:[c.proof.fieldLabel]) : c.proof.sendField
        let recipient=c.proof.bundle==SendRules.mailApp ? recipients.observe(window:c.proof.windowID,field:field,text:c.text,seal:c.reason,now:now,lastEditedAt:c.lastEditedAt) : nil
        // claude/cc-label-1003 (owner 10/03): a line typed in a terminal running an AI tool is a prompt to it. The window's
        // title names the tool by a glyph only while it shows one, so the window keeps the tool while its title stays the
        // same (`TerminalToolMemory`); a prompt-shaped line in a terminal app whose own processes run exactly one AI tool
        // agrees as well (`terminalToolProbe`, process names only). Kept as `titleTool`, and as the unit's surface and who.
        var tool:String?
        if TerminalToolMemory.applies(bundle:c.proof.bundle) {
            tool=TerminalToolMemory.shared.observe(bundle:c.proof.bundle,title:c.proof.place,now:wallTime)
            if (tool ?? "").isEmpty,PromptShape.natural(c.text),let probed=terminalToolProbe?(c.proof.bundle),!probed.isEmpty {tool=probed}
            if let tool,!tool.isEmpty {event.titleTool=tool}
        }
        let facts=SendRules.facts(bundle:c.proof.bundle,host:nil,title:c.proof.place,field:field,
                                  composerPlace:c.proof.sendPlace.isEmpty ? nil : c.proof.sendPlace,recipient:recipient,seal:c.reason,terminalTool:tool)
        event.captureProvenance?.unit?.apply(facts,pasted:pastes.observe(field:c.proof.windowID+"|"+c.proof.focusID,seal:c.reason))
        // compose-send/v1: the native identity adapters (`ComposeIdentity`), from the unit's own window title only.
        if let identity=Self.nativeIdentity(bundle:c.proof.bundle,surface:facts.surface,title:c.proof.place,recipient:facts.to) {
            event.captureProvenance?.unit?.apply(destination:identity.0,context:identity.1)
        }
        return try store.ingest(event,now:wallTime,expectedPolicyRevision:current.revision,requireRecording:true)
    }
    /// compose-send/v1: who or what a native unit went to. Messages: nothing beyond the conversation (`to`). Mail: the
    /// subject (and, for a reply, the subject as its context). AI apps: the chat's name as the subject.
    static func nativeIdentity(bundle:String,surface:String,title:String,recipient:String?) -> (ComposeDestination,ComposeContext)? {
        switch surface {
        // claude/int-1003: Mail through email-compose/v1 (`EmailComposeAdapter`), from the compose window's title only
        // (the subject, reply or forward) and the To-field rule's name; no new Accessibility read.
        case "email":
            let facts=EmailComposeAdapter.facts(EmailComposeSnapshot(title:title,fields:[]))
            return EmailComposeAdapter.identity(facts,recipient:recipient,service:"Mail")
        case "ai":
            guard let service=SendRules.aiName(bundle:bundle) else {return nil}
            let d=ComposeIdentity.aiChat(title:title,service:service)
            return (ComposeDestination(subject:d.subject),ComposeContext())
        default: return nil
        }
    }
    public func commitBrowser(_ event:VerifiedBrowserEvent,proof:FocusProof,now:UInt64,wallTime:Date=Date()) throws -> Bool {
        lock.lock();defer{lock.unlock()}
        let current=try context()
        guard event.policyRevision == Int(current.policy.version),now>=event.checkedAt,now-event.checkedAt<=1_000_000_000,
              proof.bundle==event.bundle,proof.tabID==String(event.tabID),proof.documentID==event.documentID,
              proof.frameID==String(event.frameID),proof.url==event.origin,proof.focusID==event.focusID,
              proof.role == (event.role == "button" ? "AXButton" : "AXLink"),
              CaptureGate.metadata(proof,policy:current.policy,generation:current.generation,now:now).outcome == .allowed else { throw MemError.denied }
        var verification=BrowserVerification(mode:"normal",windowID:String(event.windowID),tabID:String(event.tabID),focusedRole:proof.role,checkedAt:iso(wallTime),provider:"chrome-native-bridge-v1")
        verification.documentID=event.documentID;verification.frameID=event.frameID
        verification.navigationGeneration=event.navigationGeneration;verification.focusID=event.focusID
        verification.focusGeneration=event.focusGeneration;verification.sessionID=event.sessionID;verification.policyRevision=current.revision
        let id="browser_"+fingerprint("\(event.sessionID)|\(event.checkedAt)|\(event.windowID)|\(event.tabID)|\(event.documentID)|\(event.navigationGeneration)|\(event.focusID)|\(event.focusGeneration)|\(event.policyRevision)|\(event.kind)|\(event.origin)")
        let evidence=Evidence(id:id,at:iso(wallTime),kind:event.kind,app:"Chrome",bundle:event.bundle,url:event.origin,browserVerification:verification)
        return try store.ingest(evidence,now:wallTime,expectedPolicyRevision:current.revision,requireRecording:true,preserveExisting:true)
    }
    /// compose-send/v1: the row's composer was confirmed after its gesture: mark the row sent
    /// (`MemoryStore.markComposerSent`), under this binding's policy revision.
    public func markComposerSent(id:String,windowID:String,gesture:ComposeGesture = .returnKey,confirmation:ComposeConfirmation = .fieldCleared,wallTime:Date=Date()) throws -> Bool {
        lock.lock();defer{lock.unlock()}
        let current=try context()
        return try store.markComposerSent(id:id,windowID:windowID,gesture:gesture,confirmation:confirmation,expectedPolicyRevision:current.revision,now:wallTime)
    }
    public func commitKeyMarker(id:String,kind:String,proof:FocusProof,now:UInt64) throws -> Bool {
        lock.lock();defer{lock.unlock()}
        let current=try context()
        guard ["keyboard.submit","keyboard.shortcut"].contains(kind),
              CaptureGate.typing(proof,policy:current.policy,generation:current.generation,now:now).outcome == .allowed else {throw MemError.denied}
        let time=Date()
        return try store.ingest(Evidence(id:id,at:iso(time),kind:kind,app:AppNames.display(app:"",bundle:proof.bundle),bundle:proof.bundle),now:time,expectedPolicyRevision:current.revision,requireRecording:true,preserveExisting:true)
    }
}

/// App-owned connection facade. Keep it on the capture executor and close it
/// on transport loss. Safari keeps this object across request-handler calls;
/// Chrome keeps it for one native port. Hello cannot evict another connection.
public final class CoreBrowserConnection {
    private let binding:CoreCaptureBinding,pins:MetadataPins
    private let integrationValidated:Bool,physicalDeviceValidated:Bool
    private var handle:String?
    public init(binding:CoreCaptureBinding,pins:MetadataPins,integrationValidated:Bool=false,physicalDeviceValidated:Bool=false) {
        self.binding=binding;self.pins=pins;self.integrationValidated=integrationValidated;self.physicalDeviceValidated=physicalDeviceValidated
    }
    public func acceptHello(_ frame:Data)->Bool {
        guard handle==nil,let hello=MetadataHello.decode(frame),hello.browser==pins.browser,hello.extensionID==pins.extensionID else{return false}
        handle=binding.openBrowser(pins:pins,clientNonce:hello.clientNonce,integrationValidated:integrationValidated,physicalDeviceValidated:physicalDeviceValidated)
        return handle != nil
    }
    public func request(native:MetadataGate,now:UInt64,wallTime:Date=Date())throws->Data? {
        guard let handle else{return nil};return try binding.requestBrowser(handle,native:native,now:now,wallTime:wallTime)
    }
    public func receive(_ frame:Data,native:MetadataGate,now:UInt64,wallTime:Date=Date())throws->Bool {
        guard let handle else{return false};return try binding.receiveBrowser(handle,frame:frame,native:native,now:now,wallTime:wallTime)
    }
    public func close(){if let handle{binding.closeBrowser(handle)};handle=nil}
    deinit{close()}
}
