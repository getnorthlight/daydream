import Foundation
import MemoryCore

/// ActivityNote.bundles / bundleActionCounts: derivation, and proof that the
/// fields stay out of every revision so notes generated before them stay ready.
func runActivityBundleChecks(home: URL, now: Date) throws {
    let store = try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
    let zone = "UTC", day = try DayScope.key(now,timezone:zone)
    func event(_ id:String,_ minutesAgo:Double,_ app:String,_ bundle:String,_ title:String,kind:String="window.changed") -> Evidence {
        Evidence(id:id,at:iso(now.addingTimeInterval(-minutesAgo*60)),kind:kind,app:app,bundle:bundle,title:title,synthetic:true)
    }
    // One mixed-app moment (5 TextEdit, a 2/2 Notes/Safari tie, 1 action without a
    // bundle) interleaved with a moment whose actions carry no bundle at all. The last
    // two TextEdit samples are consecutive window.observed, so they coalesce into one
    // cluster: counts must be per action, not per observation cluster.
    let mixed = "Garden sensor research", bare = "Unbundled scratch notes"
    let fixture = [
        event("mix-1",30,"TextEdit","com.apple.TextEdit",mixed), event("mix-2",28,"Safari","com.apple.Safari",mixed),
        event("bare-1",27,"Fixture","",bare), event("mix-3",26,"Notes","com.apple.Notes",mixed),
        event("mix-4",24,"TextEdit","com.apple.TextEdit",mixed), event("mix-5",22,"Terminal","",mixed),
        event("bare-2",21,"Fixture","",bare), event("mix-6",20,"Safari","com.apple.Safari",mixed),
        event("mix-7",18,"Notes","com.apple.Notes",mixed), event("mix-8",16,"TextEdit","com.apple.TextEdit",mixed),
        event("mix-9",14,"TextEdit","com.apple.TextEdit",mixed,kind:"window.observed"), event("mix-10",13,"TextEdit","com.apple.TextEdit",mixed,kind:"window.observed"),
    ]
    for e in fixture { _ = try store.ingest(e,now:now) }
    let layers = try store.dayLayers(day:day,timezone:zone,now:now)
    guard let research = layers.activities.first(where:{$0.subject == mixed}), let scratch = layers.activities.first(where:{$0.subject == bare}) else { throw MemError.invalid("FAILED: bundle fixture grouped as two moments") }
    try check(layers.activities.count == 2 && research.actionIDs.count == 10 && scratch.actionIDs.count == 2,"bundle fixture groups one mixed-app moment and one bundle-less moment")
    let bundleOf=Dictionary(uniqueKeysWithValues:fixture.map { ($0.id,$0.bundle) })
    let textEditActions=research.actionIDs.filter { bundleOf[$0] == "com.apple.TextEdit" }.count
    let textEditClusters=research.clusters.filter { bundleOf[$0.actionIDs[0]] == "com.apple.TextEdit" }.count
    try check(textEditActions == 5 && textEditClusters == 4 && research.clusters.contains { $0.actionIDs == ["mix-9","mix-10"] },"fixture coalesces two TextEdit actions into one observation cluster")
    try check(research.bundles == ["com.apple.TextEdit","com.apple.Notes","com.apple.Safari"],"bundles order by member action count, ties by bundle ID")
    try check(research.bundleActionCounts == ["com.apple.TextEdit":5,"com.apple.Notes":2,"com.apple.Safari":2] && research.bundleActionCounts?["com.apple.TextEdit"] == textEditActions,"bundleActionCounts count member actions per bundle, not observation clusters")
    try check(research.bundleActionCounts!.values.reduce(0,+) == research.actionIDs.count-1,"actions without a bundle are not counted")
    try check(research.apps == ["Notes","Safari","Terminal","TextEdit"],"apps stay alphabetical display names")
    try check(scratch.bundles == [] && scratch.bundleActionCounts == [:],"bundle-less moment reports known-empty bundles, not another moment's")

    // inputRevision keeps its pre-bundles formula: members + policy + subject + corrections.
    func legacyInput(_ note:ActivityNote) throws -> String {
        let members = try note.actionIDs.map { id -> CanonicalAction in
            guard let action = try store.action(id,now:now) else { throw MemError.invalid("FAILED: member action readable") }
            return action
        }
        return fingerprint(try json(members)+store.policy().revision+note.subject+json(note.corrections ?? []))
    }
    func legacyDay(_ layers:ActionDay) throws -> String {
        fingerprint(try json(layers.activities.map { [$0.id,$0.inputRevision] })+store.policy().revision)
    }
    try check(try layers.activities.allSatisfy { try $0.inputRevision == legacyInput($0) },"activity inputRevision unchanged by bundle fields")
    try check(try layers.summary.inputRevision == legacyDay(layers),"day inputRevision unchanged by bundle fields")

    // Old JSON (no bundle keys) still decodes; new keys are additive.
    let encoded = try json(research)
    try check(encoded.contains("\"bundles\":[") && encoded.contains("\"bundleActionCounts\":{"),"encoded note carries additive bundle keys")
    var legacyShape = try JSONSerialization.jsonObject(with:Data(encoded.utf8)) as! [String:Any]
    legacyShape["bundles"] = nil; legacyShape["bundleActionCounts"] = nil
    let decoded = try JSONDecoder().decode(ActivityNote.self,from:JSONSerialization.data(withJSONObject:legacyShape))
    try check(decoded.bundles == nil && decoded.bundleActionCounts == nil && decoded.inputRevision == research.inputRevision && decoded.actionIDs == research.actionIDs,"note JSON without bundle keys decodes with nil bundles")
    let roundTrip = try decode(ActivityNote.self,encoded)
    try check(roundTrip.bundles == research.bundles && roundTrip.bundleActionCounts == research.bundleActionCounts,"bundle fields survive a JSON round trip")

    // A committed note keyed by the unchanged revision reads back ready.
    let scope = MemoryActionScope(kind:"activity",id:research.id,day:day,timezone:zone)
    _ = try store.correctNote(scope:scope,text:"Comparing sensors, not buying one.",expectedRevision:research.inputRevision,now:now)
    let corrected = try store.dayLayers(day:day,timezone:zone,now:now).activities.first { $0.id == research.id }!
    try check(corrected.corrections?.count == 1 && corrected.inputRevision == legacyInput(corrected) && corrected.inputRevision != research.inputRevision,"note correction still enters inputRevision by the legacy formula")
    let request = try store.prepareNote(kind:"activity",day:day,timezone:zone,activityID:research.id,now:now)
    try check(request.inputRevision == corrected.inputRevision,"writer request pins the legacy inputRevision")
    let output = NoteWriterOutput(requestID:request.id,title:mixed,bullets:[NoteBullet(text:"Compared garden sensors across three apps.",actionIDs:request.actions.map(\.id),assertion:"interpretation")],generator:"local/synthetic",generatorVersion:"1")
    let saved = try store.commitNote(output,now:now)
    let reread = try store.dayLayers(day:day,timezone:zone,now:now)
    let ready = reread.activities.first { $0.id == research.id }!
    try check(ready.status == "ready" && ready.generated?.version == saved.version && ready.generated?.inputRevision == corrected.inputRevision,"committed note reads back ready under the unchanged revision")
    try check(ready.inputRevision == corrected.inputRevision && ready.bundles == research.bundles && ready.bundleActionCounts == research.bundleActionCounts,"ready note keeps its revision and bundle metadata")
    try check(try reread.summary.inputRevision == legacyDay(reread),"day inputRevision formula unchanged after commit")
    print("Activity bundle checks use a synthetic store only. No capture, provider or index.")
}

/// sat5: the owner's Saturday test 4 timeline showed "Notes app", "Notes" and "Notes app" a minute apart, and "Claude"
/// next to "Chats in Claude". The next action in the same desktop app within five minutes joins the moment before it,
/// even when the window title changed; the moment keeps the latest real title, never a bare app name.
func runMomentContinuationChecks(home: URL, now: Date) throws {
    let store = try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
    let zone = "UTC", day = try DayScope.key(now,timezone:zone)
    func event(_ id:String,_ minutesAgo:Double,_ app:String,_ bundle:String,_ title:String) -> Evidence {
        Evidence(id:id,at:iso(now.addingTimeInterval(-minutesAgo*60)),kind:"window.changed",app:app,bundle:bundle,title:title,synthetic:true)
    }
    let notes = "com.apple.Notes", claude = "com.anthropic.claudefordesktop", textEdit = "com.apple.TextEdit"
    // "Shopping" and "Shopping list" are eight minutes apart: two moments. Two different documents in one app a few
    // seconds apart stay two moments, and so do "Draft 1" and "Draft 10".
    for e in [event("old-1",30,"Notes",notes,"Shopping"), event("old-2",22,"Notes",notes,"Shopping list"),
              event("te-1",16,"TextEdit",textEdit,"Budget"), event("te-2",15.5,"TextEdit",textEdit,"Letter to landlord"),
              event("te-3",15,"TextEdit",textEdit,"Letter to landlord"),
              event("te-4",13,"TextEdit",textEdit,"Draft 1"), event("te-5",12.5,"TextEdit",textEdit,"Draft 10"),
              event("claude-1",10,"Claude",claude,"Claude"), event("claude-2",9,"Claude",claude,"Tallybird launch plan"),
              event("claude-3",8.5,"Claude",claude,"Tallybird launch plan"),
              event("notes-1",5,"Notes",notes,"Groceries"), event("notes-2",4.75,"Notes",notes,"Groceries and err"),
              event("notes-3",4.5,"Notes",notes,"Groceries and"),
              event("notes-4",4,"Notes",notes,""), event("notes-5",3.5,"Notes",notes,"Groceries and errands")] {
        _ = try store.ingest(e,now:now)
    }
    let moments = try store.dayLayers(day:day,timezone:zone,now:now).activities
    try check(moments.map(\.subject) == ["Shopping","Shopping list","Budget","Letter to landlord","Draft 1","Draft 10","Tallybird launch plan","Groceries and errands"],
              "consecutive moments in one window are one row with the latest window title: \(moments.map(\.subject))")
    try check(moments.map { $0.actionIDs.count } == [1,1,1,2,1,1,3,5],
              "a note retitled as you type, and a chat that got its name, stay one moment; another document or a longer gap starts a new one: \(moments.map { $0.actionIDs.count })")
    try check(MemoryStore.relatedTitles("New Message","Pricing for the team plan",app:"Mail") && !MemoryStore.relatedTitles("New Message","Pricing for the team plan",app:"Notes"),
              "a Mail compose window's \"New Message\" and the subject typed into it are one email (one moment)")
    try check(MemoryStore.relatedTitles("Groceries","Groceries and errands",app:"Notes") && MemoryStore.relatedTitles("Groceries and err","Groceries and errands",app:"Notes")
              && MemoryStore.relatedTitles("Claude","Tallybird launch plan",app:"Claude") && MemoryStore.relatedTitles("","Budget",app:"TextEdit")
              && !MemoryStore.relatedTitles("Draft 1","Draft 10",app:"TextEdit") && !MemoryStore.relatedTitles("Budget","Letter to landlord",app:"TextEdit")
              && !MemoryStore.relatedTitles("Groceries list","Groceries and errands",app:"Notes"),
              "related window titles: grown word by word, a word being typed, empty or the app's name; not another document")
    print("Moment continuation checks use a synthetic store only. No capture, provider or index.")
}
