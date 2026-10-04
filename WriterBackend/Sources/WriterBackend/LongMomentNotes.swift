import Foundation

/// claude/ready-1002 (owner, 10/2): long moments get summaries. A moment over the 400 actions one ITEMS view reads (or
/// one whose view still overflows after folding) is written in segments of about 150 actions, cut where the conversation
/// or window changes and never inside a typing run. Each segment is written and checked on its own view, exactly like a
/// short moment (model, repair, salvage, code's fallback); the segment notes are then merged into one card: bullets in
/// order, an identical line once citing every segment it stands for, and the title of the largest segment.
public struct NoteChunk: Sendable {
    public let actions:[NoteAction]
    public let view:ModelView
}

extension CanonicalGrounding {
    /// Target segment size; segments grow only so a moment never needs more than `maxChunks` of them.
    public static let chunkActions=150
    public static let maxChunks=8
    /// The longest moment written in segments (core's request bound is 5,000). Today's "too long" starts above it.
    public static let maxChunkedActions=2000

    /// Whether this request is written in segments: a moment over one view's bound. nil: the one ITEMS view holds it.
    /// Throws `capacity` for a day, or a moment too long even for segments.
    public static func chunks(_ request:CanonicalNoteRequest,actions:[NoteAction],appNames:[String:String]=[:],localIntentSessions:Bool=false) throws -> [NoteChunk]? {
        if actions.count<=maxActions,(try? ModelView(request:request,actions:actions,appNames:appNames,localIntentSessions:localIntentSessions)) != nil {return nil}
        guard request.targetKind=="activity",actions.count<=maxChunkedActions else {throw WriterFailure.capacity}
        var out:[NoteChunk]=[]
        func add(_ part:[NoteAction]) throws {
            if let view=try? ModelView(request:request,actions:part,appNames:appNames,localIntentSessions:localIntentSessions) {
                out.append(NoteChunk(actions:part,view:view));return
            }
            // A segment that still overflows (too many apps or words) is halved, at a conversation change when it can be.
            guard part.count>1 else {throw WriterFailure.capacity}
            let cut=cutIndex(part,near:part.count/2)
            try add(Array(part[..<cut]));try add(Array(part[cut...]))
        }
        for part in segments(actions) {try add(part)}
        guard out.count>=2,out.count<=maxChunks*2 else {throw WriterFailure.capacity}
        return out
    }

    /// Chronological segments of about `chunkActions` (or n / `maxChunks`), each ending at a conversation change.
    static func segments(_ actions:[NoteAction])->[[NoteAction]] {
        let acts=actions.sorted {($0.at,$0.id)<($1.at,$1.id)}
        let target=min(maxActions,max(chunkActions,(acts.count+maxChunks-1)/maxChunks))
        var out:[[NoteAction]]=[],start=0
        while acts.count-start>target {
            let cut=cutIndex(Array(acts[start...]),near:target)
            out.append(Array(acts[start..<start+cut]));start+=cut
        }
        if start<acts.count {out.append(Array(acts[start...]))}
        return out
    }
    /// Where to end a segment of `part` at or before `near` (and after two thirds of it): the last change of app, window
    /// or typing run; never between two rows of one typing run unless the run itself is longer than the segment.
    static func cutIndex(_ part:[NoteAction],near:Int)->Int {
        let near=max(1,min(near,part.count-1))
        func sameRun(_ i:Int)->Bool {
            guard let a=part[i-1].runID,let b=part[i].runID else {return false}
            return a==b
        }
        func conversation(_ i:Int)->Bool {part[i-1].app != part[i].app || part[i-1].title != part[i].title}
        let floor=max(1,near*2/3)
        for i in stride(from:near,through:floor,by:-1) where conversation(i) && !sameRun(i) {return i}
        for i in stride(from:near,through:floor,by:-1) where !sameRun(i) {return i}
        for i in stride(from:near,through:1,by:-1) where !sameRun(i) {return i}
        return near
    }

    /// The card's note from the segments' checked notes: bullets in order, a line two segments wrote alike once (citing
    /// both, its label derived again), the largest segment's title. A model wrote it when any segment's model did.
    public static func mergeChunks(_ request:CanonicalNoteRequest,notes:[CanonicalNoteOutput],chunks:[NoteChunk]) throws -> CanonicalNoteOutput {
        guard notes.count==chunks.count,!notes.isEmpty else {throw WriterFailure.invalidOutput}
        let byID=Dictionary(uniqueKeysWithValues:chunks.flatMap(\.actions).map {($0.id,$0)})
        // claude/summary-1003 (owner): a line two segments wrote with the same words, case and end punctuation aside, is
        // one line ("Entered a command in Ghostty" and "Entered a command in Ghostty."), as salvage's `mergeRepeats`.
        func key(_ t:String)->String {t.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:" .!"))}
        var texts:[String]=[],ids:[String:[String]]=[:],shown:[String:String]=[:]
        for note in notes {
            for b in note.bullets {
                let k=key(b.text)
                if ids[k]==nil {texts.append(k);shown[k]=b.text}
                ids[k,default:[]]+=b.actionIDs.filter {!(ids[k] ?? []).contains($0)}
            }
        }
        let bullets=texts.map {k -> GroundedBullet in
            let text=shown[k]!
            let acts=ids[k]!.compactMap {byID[$0]}.sorted {($0.at,$0.id)<($1.at,$1.id)}
            return GroundedBullet(text:text,actionIDs:acts.map(\.id),assertion:assertion(of:acts))
        }
        guard (1...maxBullets).contains(bullets.count) else {throw WriterFailure.capacity}
        let largest=zip(notes,chunks).max {$0.1.actions.count<$1.1.actions.count}!.0
        let model=notes.first {![codeProvider,fallbackProvider].contains($0.generator)}
        let provider=model?.generator ?? (notes.allSatisfy {$0.generator==fallbackProvider} ? fallbackProvider : codeProvider)
        let output=CanonicalNoteOutput(requestID:request.id,title:largest.title,bullets:bullets,generator:provider,generatorVersion:model?.generatorVersion ?? version(provider))
        return try checkChunked(output,request:request,chunks:chunks)
    }

    /// The final check of a note written in segments (CoreWriterAdapter, before commit): this build's version, whole
    /// actions of this moment, derived labels, core's claim rules, each bullet's wording against the views it cites, and
    /// every segment's required items covered.
    public static func checkChunked(_ note:CanonicalNoteOutput,request:CanonicalNoteRequest,chunks:[NoteChunk]) throws -> CanonicalNoteOutput {
        guard note.requestID==request.id,currentVersions.contains(note.generatorVersion),version(note.generator)==note.generatorVersion || note.generator==CloudWriter.model,
              !note.title.isEmpty,note.title.count<=titleChars,(1...maxBullets).contains(note.bullets.count) else {throw reject("check","chunked note")}
        let byID=Dictionary(uniqueKeysWithValues:chunks.flatMap(\.actions).map {($0.id,$0)})
        var cited=Set<String>()
        for b in note.bullets {
            let acts=b.actionIDs.compactMap {byID[$0]}
            guard !acts.isEmpty,acts.count==b.actionIDs.count,Set(b.actionIDs).count==b.actionIDs.count,b.assertion==assertion(of:acts),
                  !b.text.isEmpty,b.text.count<=bulletChars,coreClaimProblem(note.title,b,acts)==nil,!underClaim(b,acts) else {throw reject("check","chunked bullet")}
            // Whole items of each segment it cites, and no copied typed words in any of them.
            for chunk in chunks {
                let owners=chunk.actions.filter {b.actionIDs.contains($0.id)}.compactMap {chunk.view.owner(of:$0.id)}
                for it in owners where !it.actions.allSatisfy({b.actionIDs.contains($0.id)}) {throw reject("check","a bullet cites part of an item")}
                if !owners.isEmpty,viewCopy(b.text,chunk.view)>0 {throw reject("check","copied typed words")}
            }
            cited.formUnion(b.actionIDs)
        }
        for chunk in chunks {
            for it in chunk.view.items where mustCite(it,chunk.view) && !it.actions.allSatisfy({cited.contains($0.id)}) {throw reject("check","coverage")}
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.withoutEscapingSlashes]
        guard try encoder.encode(note).count<=outputMax else {throw reject("structure","too long")}
        return note
    }
}
