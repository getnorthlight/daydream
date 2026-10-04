import Foundation
@testable import MemoryCore
import MemoryUI
import BackupRestore

@main struct AppFlowChecks {
    static var count=0
    static func check(_ value:Bool,_ label:String) {precondition(value,label);count += 1;print("PASS "+label)}
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let root=try physicalDirectory(FileManager.default.temporaryDirectory).appendingPathComponent("macmem-ui-flow-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let home=root.appendingPathComponent("memory"),store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
        let now=Date(),old=now.addingTimeInterval(-86400)
        for n in 0..<5 {_=try store.ingest(Evidence(id:"a\(n)",at:iso(old),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Needle research \(n)",synthetic:true))}
        let first=try store.searchResult(MemorySearchQuery("Needle",limit:2))
        check(first.items.count==2 && first.next != nil,"global search finds prior-day actions and continuation")
        let second=try store.searchResult(MemorySearchQuery("Needle",limit:2,after:first.next))
        check(Set(first.items.map(\.id)).isDisjoint(with:second.items.map(\.id)),"search continuation preserves distinct rows")
        try store.delete(first.items[0].id)
        check(try store.searchResult(MemorySearchQuery("Needle")).items.allSatisfy{$0.id != first.items[0].id},"deleted action absent from new global search")
        let flow=MemoryFlowStore(home:home)
        let skipped=try await flow.choose(.scratch)
        check(skipped.retainedActionCount==4,"actual UI worker skip preserves existing memory")
        check(try MemoryStore(home:home).captureStatus()["state"]=="off","cold reader sees capture OFF")
        check(try MemoryStore(home:home).searchResult(MemorySearchQuery("Needle")).items.count==4,"cold restart retains searchable actions")
        let snapshot=root.appendingPathComponent("snapshot.json"),namespace="synthetic-ui-import"
        var entries=[MigrationEntry]()
        for n in 0..<3 {
            let source="event-\(n)",id="legacy_"+fingerprint(try json([namespace,"collector-event",source]))
            let evidence=Evidence(id:id,at:iso(now),kind:"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Imported fixture")
            let raw=try json(["id":source,"kind":"mouse.click","timestamp":iso(now)])
            entries.append(MigrationEntry(id:id,sourceID:source,family:"collector-event",format:"history-segment-v1",at:iso(now),epochNanos:String(Int64(now.timeIntervalSince1970)*1_000_000_000),timezone:"UTC",raw:raw,rawSHA256:fingerprint(raw),deleted:false,evidence:evidence,summary:nil,end:nil,attachments:[]))
        }
        let data=Data(try json(MigrationSnapshot(version:1,namespace:namespace,entries:entries)).utf8)
        try data.write(to:snapshot)
        let populated=try await flow.preview(snapshot)
        check(try store.actions().actions.count==4,"populated-store preview leaves existing actions intact")
        _=try await flow.confirm(populated.id,exclusions:false,limit:1)
        let restarted=MemoryFlowStore(home:home)
        check(try await restarted.recover()?.progress?.next==1,"actual UI worker cold restart recovers saved batch")
        try await restarted.cancel(populated.id)
        check(try await restarted.recover()==nil,"cancellation clears pending recovery")
        check(try store.actions().actions.count==4,"cancelled staging preserves existing memory")
        let imported=root.appendingPathComponent("imported"),importFlow=MemoryFlowStore(home:imported)
        let preview=try await importFlow.preview(snapshot)
        check(preview.source.counts["accepted"]==3 && preview.source.start != nil,"actual UI preview gives counts and dates")
        check(try MemoryStore(home:imported).actions().actions.isEmpty,"preview never imports actions")
        let completed=try await importFlow.confirm(preview.id,exclusions:false)
        check(completed.progress?.complete == true,"actual UI worker confirmed staging completes")
        check(try MemoryStore(home:imported).actions().actions.isEmpty,"staging does not adopt without separate confirmation")
        let importUI=MemoryFlows(home:imported);importUI.permitsImport={true}
        while importUI.busy {try await Task.sleep(nanoseconds:10_000_000)}
        importUI.confirm()
        check(importUI.operation == .staging && importUI.cancelTitle == "Pause after current batch","staging alone advertises bounded pause")
        importUI.cancel()
        check(importUI.cancelTitle == nil,"requested pause removes repeated cancellation promise")
        while importUI.busy {try await Task.sleep(nanoseconds:10_000_000)}
        importUI.review()
        check(importUI.operation == .reviewing && importUI.cancelTitle == nil,"atomic review offers no Pause or Cancel control")
        importUI.cancel()
        while importUI.busy {try await Task.sleep(nanoseconds:10_000_000)}
        check(importUI.session?.adoption != nil,"unsupported review cancellation cannot report false cancellation")
        importUI.adopt()
        check(importUI.operation == .adopting && importUI.cancelTitle == nil,"atomic adoption offers no Pause or Cancel control")
        importUI.cancel()
        while importUI.busy {try await Task.sleep(nanoseconds:10_000_000)}
        check(importUI.session == nil && importUI.cancelTitle == nil && importUI.status.hasPrefix("Reviewed history added"),"committed adoption has no cancellation affordance or false cancelled status")
        check(try MemoryStore(home:imported).actions().actions.count==3,"import survives reopened store")
        check(try MemoryStore(home:imported).captureStatus()["state"]=="off","import leaves recording OFF")
        check(try Data(contentsOf:snapshot)==data,"import does not alter source export")
        let stale=try await flow.preview(snapshot)
        _=try await flow.confirm(stale.id,exclusions:false)
        _=try await flow.review(stale.id)
        var policy=try store.policy();policy.blockedApps=["com.apple.TextEdit"]
        try store.updatePolicy(policy)
        do {_=try await flow.adopt(stale.id);fatalError("stale policy adopted")} catch {check(true,"actual UI worker rejects adoption after policy revision")}
        try await flow.cancel(stale.id)
        let excluded=try await flow.preview(snapshot)
        check(excluded.source.counts["excluded_privacy_or_unverified_browser"]==3,"app exclusion appears in exact staged review")
        do {_=try await flow.confirm(excluded.id,exclusions:false);fatalError("exclusions unconfirmed")} catch {check(true,"policy exclusions require explicit acceptance")}
        _=try await flow.confirm(excluded.id,exclusions:true)
        let excludedReview=try await flow.review(excluded.id)
        check(excludedReview.adoption?.actionIDs.isEmpty==true,"excluded records never reach adoption")
        _=try await flow.adopt(excluded.id)
        policy.blockedApps=[];try store.updatePolicy(policy)
        check(try store.actions().actions.count==4,"policy toggle and excluded import preserve existing originals")
        let denied=OriginalHEADVerifier()
        for url in ["file:///tmp/example","javascript:alert(1)","https://localhost/path","https://127.0.0.1/path","https://example.test/?token=abc"] {
            check(try !denied.verify(url:url,deadline:Date().addingTimeInterval(1)).exists,"unsafe source rejected before transport")
        }
        let model=MemoryFlows(home:home)
        while model.busy {try await Task.sleep(nanoseconds:10_000_000)}
        model.skip()
        while model.busy {try await Task.sleep(nanoseconds:10_000_000)}
        check(model.status.contains("retained"),"UI skip reports retained history")
        check(try MemoryStore(home:home).actions().actions.count==4,"UI skip action never erases records")
        if CommandLine.arguments.count==2 {
            let backup=BackupSettingsModel(home:home,helper:URL(fileURLWithPath:CommandLine.arguments[1]))
            backup.permitted={true}
            let destination=root.appendingPathComponent("ui-backup")
            backup.export(to:destination)
            while backup.busy {try await Task.sleep(nanoseconds:10_000_000)}
            check(backup.status.hasPrefix("Backup saved"),"actual backup UI invokes bundled helper export")
            backup.prepare(from:destination)
            while backup.busy {try await Task.sleep(nanoseconds:10_000_000)}
            check(backup.prepared != nil,"actual restore UI receives verified canonical preview")
            let coldBackup=BackupSettingsModel(home:home,helper:URL(fileURLWithPath:CommandLine.arguments[1]))
            check(coldBackup.prepared?.preview.id==backup.prepared?.preview.id && !coldBackup.busy,"cold restore UI retains exact preview without running worker")
            _=try store.ingest(Evidence(id:"new-since-preview",at:iso(now),kind:"window.changed",app:"TextEdit",title:"New fixture",synthetic:true))
            backup.confirm()
            while backup.busy {try await Task.sleep(nanoseconds:10_000_000)}
            check(backup.status.hasPrefix("Couldn't confirm the restore"),"UI reports stale restore rejection without success")
            backup.cancel()
            while backup.busy {try await Task.sleep(nanoseconds:10_000_000)}
            check(backup.prepared==nil,"UI cancellation clears canonical preview")
            backup.prepare(from:destination)
            while backup.busy {try await Task.sleep(nanoseconds:10_000_000)}
            backup.confirm()
            while backup.busy {try await Task.sleep(nanoseconds:10_000_000)}
            check(backup.status.hasPrefix("Restored"),"UI confirmed restore completes canonical merge")
            check(try MemoryStore(home:home).captureStatus()["state"]=="off","UI restore leaves capture OFF")
        }
        print("\(count) app flow checks passed; synthetic stores only, no source URLs opened")
    }
}
