#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
import SwiftUI
import MemoryCore

/// Called only behind PackagedTrial's physical synthetic-home/marker gate.
@MainActor enum PackagedHistoryChecks {
    static func run(model:MemoryViewModel,home:URL) async throws -> [String] {
        var checks=[String]()
        func check(_ value:Bool,_ label:String) throws {
            guard value else {throw MemError.invalid(label)};checks.append(label)
        }
        func settle(_ flow:MemoryFlows) async throws {
            for _ in 0..<1500 {if !flow.busy {return};try await Task.sleep(nanoseconds:20_000_000)}
            throw MemError.invalid("History UI timeout")
        }
        // Migration fixtures use the real export schema (synthetic=false), in a
        // separate marked test store, never the app's demo or user's memory.
        let fixture=home.deletingLastPathComponent().appendingPathComponent("history-fixture-"+UUID().uuidString)
        let store=try MemoryStore(home:fixture,writable:true,automaticallySyncSearch:false)
        _=try store.ingest(Evidence(id:"existing-history-fixture",at:iso(Date()),kind:"mouse.click",app:"TextEdit",title:"Synthetic existing action",synthetic:true))
        _=try store.correctAction(id:"existing-history-fixture",text:"Synthetic attributed correction",expectedRevision:store.action("existing-history-fixture")!.revision)
        let flow=MemoryFlows(home:fixture);flow.permitsImport=model.history.permitsImport
        try await settle(flow)
        let before=try store.actions(limit:500).actions
        guard let corrected=before.first(where:{$0.correction != nil}) else {throw MemError.missing}
        let namespace="packaged-stage-"+UUID().uuidString,now=Date(),source=home.appendingPathComponent("synthetic-history.json")
        var entries=[[String:Any]](),ids=[String]()
        for n in 0..<105 {
            let sourceID="event-\(n)",id="legacy_"+fingerprint(try json([namespace,"collector-event",sourceID]))
            ids.append(id)
            let raw=try json(["id":sourceID,"timestamp":iso(now),"kind":"mouse.click"])
            let evidence=Evidence(id:id,at:iso(now),kind:"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Synthetic staged action \(n)")
            entries.append(["id":id,"sourceID":sourceID,"family":"collector-event","format":"history-segment-v1","at":iso(now),"epochNanos":String(Int64(now.timeIntervalSince1970)*1_000_000_000),"timezone":"UTC","raw":raw,"rawSHA256":fingerprint(raw),"deleted":false,"evidence":try JSONSerialization.jsonObject(with:JSONEncoder().encode(evidence)),"attachments":[]])
        }
        let bytes=try JSONSerialization.data(withJSONObject:["version":1,"namespace":namespace,"entries":entries],options:.sortedKeys)
        try bytes.write(to:source)
        flow.prepare(source);try await settle(flow)
        try check(flow.session != nil,"actual populated History UI prepares isolated stage")
        try check(try store.action(ids[0])==nil,"source review adds no active actions")
        flow.cancel();try await settle(flow)
        try check(flow.session==nil && (try store.action(ids[0]))==nil,"actual History cancellation retains active store")
        flow.prepare(source);try await settle(flow)
        guard let stage=flow.session else {throw MemError.missing}
        let worker=MemoryFlowStore(home:fixture)
        _=try await worker.confirm(stage.id,exclusions:false,limit:1)
        let cold=MemoryFlows(home:fixture);cold.permitsImport=flow.permitsImport
        try await settle(cold)
        try check(cold.session?.id==stage.id && cold.progress?.next==1,"cold History model recovers exact saved batch without adoption")
        cold.confirm()
        try check(cold.operation == .staging && cold.cancelTitle == "Pause after current batch","Pause is available only for the staging loop")
        try await settle(cold)
        try check(cold.session?.adoption?.actionIDs.count==105 && (try store.action(ids[0]))==nil,"actual resumed UI offers separate exact adoption review")
        let host=NSHostingView(rootView:MemoryHistorySettings(flow:cold))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:480),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.contentView=host;window.makeKeyAndOrderFront(nil)
        defer {window.orderOut(nil)}
        for dark in [false,true] {
            window.appearance=NSAppearance(named:dark ? .darkAqua:.aqua)
            host.frame=NSRect(x:0,y:0,width:680,height:480)
            try await Task.sleep(nanoseconds:300_000_000);host.layoutSubtreeIfNeeded()
            if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) {
                host.cacheDisplay(in:host.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])?.write(to:home.appendingPathComponent("history-"+(dark ? "dark":"light")+".png"))
            }
        }
        cold.review()
        try check(cold.operation == .reviewing && cold.cancelTitle == nil,"atomic review exposes no cancellation promise")
        cold.cancel();try await settle(cold)
        cold.adopt()
        try check(cold.operation == .adopting && cold.cancelTitle == nil,"atomic adoption exposes no cancellation promise")
        cold.cancel();try await settle(cold)
        try check(cold.cancelTitle == nil && cold.status.hasPrefix("Reviewed history added"),"committed adoption cannot be presented as cancelled")
        try check(cold.session==nil && (try store.action(ids[104])) != nil,"actual explicit adoption adds all 105 staged actions")
        let receipt=try await worker.adopt(stage.id)
        try check(receipt.actionIDs.count==105,"duplicate adoption retry returns saved receipt")
        try check(try store.action(corrected.id)?.correction?.text==corrected.correction?.text,"populated import preserves attributed correction")
        for action in before {try check(try store.action(action.id) != nil,"existing action retained "+action.id)}
        // Clear the original model's stale presentation without adopting again.
        flow.session=nil;flow.progress=nil
        flow.skip();try await settle(flow)
        try check(try store.action(ids[104]) != nil,"Start From Scratch retains already imported memory")
        try check(try Data(contentsOf:source)==bytes,"selected synthetic export unchanged")
        try check(!model.recording && model.noteWriter.provider=="off","staged UI leaves capture and writer OFF")
        return checks
    }
}

#endif
