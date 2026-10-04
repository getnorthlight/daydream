import Foundation

extension MemoryStore {
    /// Owner moment detail treats each complete observed typing run as its own
    /// source quote. A refused run cannot disclose a partial quote or hide the
    /// other admitted runs. The entire selected action scope remains fenced.
    /// This is ephemeral owner hydration, never writer input or stored metadata.
    public func ownerSourceMomentPreviewsForActions(_ actionIDs:[String],now:Date=Date()) throws -> [OwnerSourcePreview] {
        // claude/terminal-details-1003 (owner 10/03, "Captured wording unavailable" on every Ghostty row): the row bound
        // applies to the typed rows the detail opens, not to every action of the moment. A Claude Code session in Ghostty
        // is hundreds of title-change rows (591 in the owner's 03:14 moment), so the old whole-scope 400 cap refused
        // every quote. The whole selected scope is still fenced (each original checked), up to `scanLimit`.
        guard !actionIDs.isEmpty,actionIDs.count<=Self.ownerSourceScanLimit,
              typedVaultState == .ready,try policy().captureText else {return []}
        let epoch=try actionReadEpoch(),disclosure=try disclosureRevision()
        let wanted=Set(actionIDs)
        struct RunKey:Hashable {
            let run,bundle,url,window,focus,field,surface,recipient:String
            let generation:UInt64
        }
        var runs:[RunKey:[String]]=[:]
        var typed:[(at:String,id:String,original:Evidence)]=[]
        // A missing/deleted/hidden original invalidates the whole selected scope.
        for id in wanted {
            guard let original=try permittedOriginal(id,now:now) else {return []}
            guard original.kind == "keyboard.text_input" else {continue}
            typed.append((original.at,id,original))
        }
        // The first `rowLimit` typed rows in time order (the detail lists oldest first).
        for (_,id,original) in typed.sorted(by:{($0.at,$0.id)<($1.at,$1.id)}).prefix(MomentTypedText.rowLimit) {
            let provenance=original.captureProvenance,unit=provenance?.unit
            let verified=unit.map{!$0.runID.isEmpty && $0.part>0 && !($0.field ?? "").isEmpty} == true &&
                provenance.map{!$0.windowID.isEmpty && !$0.focusID.isEmpty && $0.generation>0} == true
            let key=RunKey(run:verified ? unit!.runID:id,bundle:original.bundle.isEmpty ? original.app:original.bundle,
                url:original.url,window:verified ? provenance!.windowID:id,focus:verified ? provenance!.focusID:id,
                field:unit?.field ?? "",surface:unit?.surface ?? "",recipient:unit?.to ?? "",
                generation:verified ? provenance!.generation:0)
            runs[key,default:[]].append(id)
        }
        let clock=typedClock(now)
        var found:[OwnerSourcePreview]=[]
        for ids in runs.values {
            // Existing proof, completeness, scrubber, field and vault gates remain authoritative for the whole
            // independently captured run; the detail's bound is a whole prompt (`blockLimit`), not the stand-in's 400.
            let run=try ownerSourcePreviews(ids,now:now,characterLimit:MomentTypedText.blockLimit,bound:MomentTypedText.blockLimit)
            found += run
            guard run.isEmpty else {continue}
            // A refused run: say why only when the reason is a privacy one (metadata and the scrubber's marker; never words).
            for id in ids {
                guard let reason=try typedWithheldReason(id,now:now) else {continue}
                let at=try permittedOriginal(id,now:now)?.at ?? ""
                found.append(OwnerSourcePreview(id:id,actionIDs:[id],at:at,runID:id,parts:[],state:OwnerSourcePreview.withheldState,
                    lead:reason,readAt:clock,disclosureRevision:disclosure,expiresAt:nil))
            }
        }
        guard try epoch == actionReadEpoch(),try disclosure == disclosureRevision(),
              typedVaultState == .ready,try policy().captureText else {return []}
        return found.sorted{($0.at,$0.id)<($1.at,$1.id)}
    }

    /// How many selected actions the owner moment detail fences (each original is checked; only typed rows are opened).
    public static let ownerSourceScanLimit=5000

    /// claude/terminal-details-1003: the short reason a typed action's words are withheld, when it is a privacy reason:
    /// the scrubber removed something that looked like a password, key or code, or the words are past the kept period.
    /// nil for anything else (the detail then shows no line at all, never a default "unavailable").
    func typedWithheldReason(_ id:String,now:Date) throws -> String? {
        guard let original=try permittedOriginal(id,now:now),original.kind == "keyboard.text_input" else {return nil}
        if original.secure {return OwnerSourcePreview.hiddenSecure}
        if (original.captureProvenance?.unit?.withheld ?? 0)>0 {return OwnerSourcePreview.hiddenSecret}
        guard try hasTypedTables(),let ref=original.typed,!ref.digest.isEmpty else {return nil}
        guard let row=try rows("SELECT created_at FROM typed_text WHERE id=?",[id]).first else {
            return try rows("SELECT id FROM typed_after WHERE id=?",[id]).isEmpty ? nil : OwnerSourcePreview.hiddenExpired
        }
        if try typedExpired(createdAt:row[0],now:typedClock(now)) {return OwnerSourcePreview.hiddenExpired}
        if let text=try hydrateTypedText(id,disclosure:.owner,now:now),text.contains(TypedSecretScrubber.marker) {return OwnerSourcePreview.hiddenSecret}
        return nil
    }
}

extension OwnerSourcePreview {
    /// The reasons the owner detail may show in place of withheld words (claude/terminal-details-1003). Short and plain.
    public static let hiddenSecret="Hidden: looked like a password or key"
    public static let hiddenSecure="Hidden: typed in a password field"
    public static let hiddenExpired="Not kept: past your typed-words period"
}
