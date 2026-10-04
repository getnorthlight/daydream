import SwiftUI
import MemoryCore
import MemoryUI
import WriterBackend
import Security

actor TrialForbiddenKeys: WriterSecureKeyStore {
    func readSecret() async throws -> String {throw WriterFailure.denied}
    func saveSecret(_ value:String) async throws {throw WriterFailure.denied}
    func removeSecret() async throws {throw WriterFailure.denied}
}

#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
/// Explicit disposable-store acceptance only. Never creates demo records or
/// enables capture, permissions, writers, updates or source reopening.
@MainActor enum PackagedTrial {
    private static var started=false
    static func runIfRequested(model:MemoryViewModel) async {
        guard model.development == nil else {return}
        let writerTest=CommandLine.arguments.contains("--synthetic-writer-check")
        let writerRestart=CommandLine.arguments.contains("--synthetic-writer-restart-check")
        guard (CommandLine.arguments.contains("--synthetic-trial-check") || writerTest || writerRestart),!started else {return}
        started=true
        guard let home=try? physicalDirectory(MemPaths.home()),
              home.path.hasPrefix("/private/tmp/daydream-trial-"),
              (try? String(contentsOf:home.appendingPathComponent("TRIAL-ONLY"),encoding:.utf8)) == "synthetic-only\n" else {NSApp.terminate(nil);return}
        let output=home.appendingPathComponent("trial-receipt.json")
        if writerTest || writerRestart {
            await runWriter(model:model,home:home,restart:writerRestart)
            NSApp.terminate(nil);return
        }
        var checks:[String]=[]
        func check(_ value:Bool,_ name:String) throws {
            guard value else {throw MemError.invalid(name)};checks.append(name)
        }
        do {
            for _ in 0..<200 {if !model.noteWriter.busy {break};try await Task.sleep(nanoseconds:50_000_000)}
            try check(!model.noteWriter.busy,"writer startup settled")
            try check(!model.recording && model.noteWriter.provider == "off" && !model.noteWriter.cloudEnabled,"capture and writers OFF")
            try check(model.backups.available,"bundled backup helper available")
            model.refreshNow()
            try check(!model.items.isEmpty && model.items.allSatisfy(\.evidence.synthetic),"only synthetic timeline records")
            guard let search=model.activity.searchCanonical else {throw MemError.invalid("search binding missing")}
            let result=try await search("Swift",nil)
            try check(!result.items.isEmpty,"actual global search binding")
            // A bare NSHostingView has no scene toolbar style, so the controls draw inline (the app uses the window toolbar).
            let host=NSHostingView(rootView:AnyView(MemoryWindow(model:model,chrome:.inline)))
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:480),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.title="DayDream · isolated trial";window.contentView=host;window.makeKeyAndOrderFront(nil)
            defer {window.orderOut(nil)}
            func render(_ name:String,_ width:CGFloat,_ height:CGFloat) async throws {
                window.setContentSize(NSSize(width:width,height:height))
                host.frame=NSRect(x:0,y:0,width:width,height:height)
                try await Task.sleep(nanoseconds:1_000_000_000)
                host.layoutSubtreeIfNeeded()
                guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw MemError.invalid("render unavailable")}
                host.cacheDisplay(in:host.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])!.write(to:home.appendingPathComponent(name+".png"))
            }
            try await render("window-narrow",680,480)
            try check(controlsOnce(host),"one recording control and one settings control")
            try await render("window-wide",1280,800)
            let key=try DayScope.key(Date(),timezone:model.activity.calendar.timeZone.identifier)
            guard let day=try await model.activity.loadCanonicalDay?(key,nil),let note=day.activities.first else {throw MemError.invalid("canonical activity missing")}
            model.activity.selectedCanonicalActivity=note.id
            try await render("detail",900,600)
            try check(model.activity.selectedCanonicalActivity==note.id && !note.actionIDs.isEmpty,"canonical activity selection and member actions")
            model.activity.selectedCanonicalActivity=nil
            try await render("returned",680,480)
            try check(model.activity.selectedCanonicalActivity==nil,"canonical detail back state")
            model.activity.query="Swift"
            try await render("search",900,600)
            try check(model.activity.query=="Swift","global search presentation state")
            model.activity.query=""
            host.rootView=AnyView(MemorySettings(model:model))
            try await render("settings",680,560)
            let reader=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
            guard let action=try reader.actions().actions.first,let correct=model.activity.correctCanonical else {throw MemError.missing}
            try correct(MemoryActionScope(kind:"action",id:action.id),"Synthetic UI correction: Swift review remains a request",action.revision)
            try check(try reader.action(action.id)?.correction?.text=="Synthetic UI correction: Swift review remains a request","actual UI correction binding persists attributed edit")
            func settleBackup() async throws {
                for _ in 0..<1000 {if !model.backups.busy {return};try await Task.sleep(nanoseconds:20_000_000)}
                throw MemError.invalid("backup timeout")
            }
            let backup=home.deletingLastPathComponent().appendingPathComponent("synthetic-backup-"+UUID().uuidString)
            model.backups.export(to:backup);try await settleBackup()
            try check(model.backups.status.hasPrefix("Backup saved"),"actual backup UI exports corrected synthetic store")
            model.backups.prepare(from:backup);try await settleBackup()
            try check(model.backups.prepared != nil,"actual restore UI prepares native preview")
            model.backups.cancel();try await settleBackup()
            try check(model.backups.prepared==nil,"actual restore cancellation clears preview")
            let victim="trial-delete-"+UUID().uuidString
            _=try reader.ingest(Evidence(id:victim,at:iso(Date()),kind:"mouse.click",app:"TextEdit",title:"Synthetic deletion fixture",synthetic:true))
            guard let preview=model.activity.previewCanonicalDelete,let confirm=model.activity.confirmCanonicalDelete,let cancel=model.activity.cancelCanonicalDelete else {throw MemError.missing}
            let abandoned=try preview(MemoryActionScope(kind:"action",id:victim));try cancel(abandoned.id)
            try check(try reader.action(victim) != nil,"cancelled deletion preserves exact action")
            let deletion=try preview(MemoryActionScope(kind:"action",id:victim))
            try check(deletion.actionIDs==[victim],"deletion preview exact scope")
            try confirm(deletion.id)
            try check(try reader.action(victim)==nil,"UI deletion after cancelled restore succeeds without misleading error")
            checks += try await PackagedHistoryChecks.run(model:model,home:home)
            try check(!model.recording && model.noteWriter.provider == "off","OFF after UI checks")
            await model.noteWriter.shutdown()
            try JSONSerialization.data(withJSONObject:["passed":true,"checks":checks],options:.prettyPrinted).write(to:output)
        } catch {
            try? JSONSerialization.data(withJSONObject:["passed":false,"checks":checks,"error":String(describing:error)],options:.prettyPrinted).write(to:output)
        }
        NSApp.terminate(nil)
    }

    /// The window shows `capture-state` and `memory-settings` exactly once. Counted in the accessibility tree when SwiftUI
    /// exposes one; offscreen it often exposes none, and then the shell census of this host stands in: exactly one
    /// inline toolbar row under `host` (which holds the one capsule and the one gear) and no window-toolbar shell.
    /// Per host: the trial runs from the app's own memory window, whose shell hands its controls to the window toolbar.
    static func controlsOnce(_ host:NSView) -> Bool {
        if countsByCensus(host) {
            let here=ShellChromeCensus.shells(under:host)
            return here.inlineRows == 1 && here.windowToolbars == 0
        }
        return accessibilityCount(host,identifier:"capture-state") == 1 && accessibilityCount(host,identifier:"memory-settings") == 1
    }
    /// `controlsOnce` counts toolbar rows, not identifiers: SwiftUI exposes no accessibility tree under `host`.
    static func countsByCensus(_ host:NSView) -> Bool { (host.accessibilityChildren() ?? []).isEmpty }

    /// Distinct accessibility elements under `root` with this identifier (the checks count controls with it).
    static func accessibilityCount(_ root:Any,identifier:String) -> Int {
        var seen=Set<ObjectIdentifier>(),count=0
        func walk(_ element:Any,_ depth:Int) {
            guard depth < 48,let node=element as? NSAccessibilityProtocol else {return}
            let object=node as AnyObject
            guard seen.insert(ObjectIdentifier(object)).inserted else {return}
            if node.accessibilityIdentifier() == identifier {count += 1}
            for child in node.accessibilityChildren() ?? [] {walk(child,depth+1)}
        }
        walk(root,0)
        return count
    }

    private static func runWriter(model:MemoryViewModel,home:URL,restart:Bool) async {
        var writer:WriterIntegration?
        var checks:[String]=[]
        var failure:String?
        do {
            // This acceptance entry may exercise upstream ad-hoc libraries only
            // in an ad-hoc trial app, never as a signed-loader fallback.
            var code:SecCode?;var staticCode:SecStaticCode?;var info:CFDictionary?
            guard SecCodeCopySelf([], &code)==errSecSuccess,let code,
                  SecCodeCopyStaticCode(code,[],&staticCode)==errSecSuccess,let staticCode,
                  SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,
                  let flags=(info as? [String:Any])?[kSecCodeInfoFlags as String] as? UInt32,
                  flags & 2 != 0 else {throw WriterFailure.denied} // kSecCodeSignatureAdhoc
            guard !model.recording,model.noteWriter.provider=="off" else {throw WriterFailure.denied}
            let store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
            let ids=Set((0..<3).map {"packaged-writer-synthetic-\($0)"})
            if !restart {
                guard try store.actions().actions.isEmpty else {throw WriterFailure.denied}
                let at=iso(Date().addingTimeInterval(-150))
                for id in ids.sorted() {_=try store.ingest(Evidence(id:id,at:at,kind:"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Synthetic Swift activity",synthetic:true))}
            }
            guard Set(try store.actions().actions.map(\.id))==ids else {throw WriterFailure.invalidOutput}
            checks.append("three synthetic actions immediately readable")
            // Exercise the app's actual controller. A second controller for this
            // store would correctly fail its exclusive scheduler lock.
            let current=model.noteWriter
            writer=current
            for _ in 0..<1500 {if !current.busy {break};try await Task.sleep(nanoseconds:20_000_000)}
            guard !current.busy,current.ready,current.provider=="off",!current.cloudEnabled,!model.recording else {throw WriterFailure.unavailable}
            checks.append("verified model present; capture/local/cloud OFF on process startup")
            if !restart {
                let action=try store.actions().actions[0]
                guard let observed=timestamp(action.at) else {throw WriterFailure.invalidOutput}
                let day=try DayScope.key(observed,timezone:TimeZone.current.identifier)
                try await current.useLocal()
                var generated=false
                for _ in 0..<900 {
                    let layers=try store.dayLayers(day:day,timezone:TimeZone.current.identifier)
                    if let note=layers.activities.first?.generated {
                        guard note.status=="generated_unverified",Set(note.actionIDs)==ids else {throw WriterFailure.invalidOutput}
                        generated=true;break
                    }
                    try await Task.sleep(nanoseconds:100_000_000)
                }
                guard generated else {throw WriterFailure.unavailable}
                checks.append("actual packaged app local inference committed one evidence-linked note for all three actions")
            }
        } catch {failure=String(describing:error)}
        if let writer {await writer.disableCloud();await writer.shutdown()}
        await model.noteWriter.shutdown()
        let result:[String:Any]=["passed":failure==nil,"checks":checks,"error":failure ?? "", "capture":model.recording ? "recording":"off","kind":"actual packaged executable; upstream local unsigned-trial mode only"]
        try? JSONSerialization.data(withJSONObject:result,options:.prettyPrinted).write(to:home.appendingPathComponent(restart ? "writer-restart-receipt.json":"writer-receipt.json"))
    }
}

#endif
