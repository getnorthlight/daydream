import Foundation
import Darwin

actor Calls {
    var count=0,active=0,peak=0
    func enter(){count+=1;active+=1;peak=max(peak,active)}
    func leave(){active-=1}
}
@main struct Checks {
    static func check(_ condition:Bool,_ name:String) {if !condition {fatalError(name)};print("PASS \(name)")}
    static func item(_ id:String="activity-a",revision:String="r1",policy:String="p1")->ScheduledWriterTarget {
        ScheduledWriterTarget(target:WriterTarget(kind:.activity,day:"2026-09-11",timezone:"UTC",activityID:id),inputRevision:revision,policyRevision:policy,lastActivity:Date(timeIntervalSinceNow:-60))
    }
    static func savePreference(_ file:URL,_ enabled:Bool) async throws {
        let scheduler=try PendingNoteScheduler(file:file)
        try await scheduler.setResumeLocal(enabled)
    }
    static func readPreference(_ file:URL) async throws -> Bool? {
        let scheduler=try PendingNoteScheduler(file:file)
        return await scheduler.resumeLocalPreference()
    }
    static func main() async throws {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("scheduler-check-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("queue.json")
        var holder:PendingNoteScheduler?=try PendingNoteScheduler(file:file,baseRetry:0.05,maxRetry:0.1,maxAttempts:2)
        do {let duplicate=try PendingNoteScheduler(file:file);_ = duplicate;fatalError("duplicate lease")}catch {print("PASS exclusive process lease")}
        var scheduler=holder!
        let a=item()
        try await scheduler.enqueue(a);try await scheduler.enqueue(a)
        check(await scheduler.snapshot().count==1,"coalesces same source revision")
        let calls=Calls()
        let committed:PendingNoteScheduler.Process={_ in await calls.enter();await calls.leave();return .committed}
        let paused=try await scheduler.runNext(process:committed)
        check(paused==nil,"construction does not generate")
        try await scheduler.start()
        _ = try await scheduler.runNext(process:committed)
        try await scheduler.enqueue(a)
        _ = try await scheduler.runNext(process:committed)
        check(await calls.count==1,"completed revision never duplicates")
        try await scheduler.enqueue(item(revision:"r2"))
        try await scheduler.cancel(key:a.key)
        try await scheduler.enqueue(item(revision:"r2"))
        check(await scheduler.snapshot().first?.status == .cancelled,"discovery cannot undo explicit cancel")
        try await scheduler.retry(key:a.key)
        _ = try await scheduler.runNext(process:{_ in .retry})
        check(await scheduler.snapshot().first?.status == .retry,"provider offline records retry")
        let before=try await scheduler.runNext(process:committed)
        check(before==nil,"retry deadline prevents busy loop")
        try await Task.sleep(nanoseconds:80_000_000)
        _ = try await scheduler.runNext(process:{_ in throw WriterFailure.unavailable})
        check(await scheduler.snapshot().first?.status == .pending,"attempt limit remains pending")
        try await scheduler.retry(key:a.key)
        let slow=Task {[scheduler] in try await scheduler.runNext(process:{_ in
            await calls.enter()
            do {try await Task.sleep(nanoseconds:1_000_000_000)}catch {await calls.leave();throw error}
            await calls.leave();return .committed
        })}
        try await Task.sleep(nanoseconds:20_000_000)
        let duplicate=try await scheduler.runNext(process:committed)
        check(duplicate==nil,"single worker during actor reentrancy")
        try await scheduler.enqueue(item(revision:"r3"))
        _ = try await slow.value
        check(await scheduler.snapshot().first?.item.inputRevision == "r3","source revision supersedes old completion")
        _ = try await scheduler.runNext(process:committed)
        check(await calls.peak==1,"no concurrent provider work")
        try await scheduler.enqueue(item("other"))
        _ = try await scheduler.runNext(preferredKey:item("other").key,process:committed)
        check(await scheduler.snapshot().first(where:{$0.item.activityID=="other"})?.status == .completed,"explicit key selection")
        try await scheduler.enqueue(item(revision:"r4"))
        try await scheduler.cancelAll()
        let contents=try String(contentsOf:file,encoding:.utf8)
        check(!contents.contains("fallback") && !contents.contains("description") && !contents.contains("credential"),"checkpoint excludes action buffers and provider errors")
        let permissions=try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as! NSNumber
        check(permissions.intValue & 0o777 == 0o600,"checkpoint private from atomic creation")
        // Release the first actor before reopening the same checkpoint.
        holder=nil
        scheduler=try PendingNoteScheduler(file:root.appendingPathComponent("other.json"))
        let restored=try PendingNoteScheduler(file:file,baseRetry:0.05)
        check(await restored.snapshot().first(where:{$0.item.key==a.key})?.status == .cancelled,"cancellation persists across restart")
        check(await restored.snapshot().first(where:{$0.item.activityID=="other"})?.status == .completed,"cancel-all preserves completed receipts")
        try await restored.enqueue(item(revision:"r4"))
        check(await restored.snapshot().first(where:{$0.item.key==a.key})?.status == .cancelled,"restart rediscovery preserves cancelled revision")
        try await restored.enqueue(item(revision:"r5"))
        try await restored.start()
        _ = try await restored.runNext(preferredKey:a.key,process:committed)
        check(await restored.snapshot().first(where:{$0.item.key==a.key})?.status == .completed,"new revision eligible after restart")
        let bounded=try PendingNoteScheduler(file:root.appendingPathComponent("bounded.json"),limit:1)
        try await bounded.enqueue(a);try await bounded.cancel(key:a.key)
        do {try await bounded.enqueue(item("second"));fatalError("capacity")}catch {print("PASS cancelled tombstone never evicted to requeue history")}
        try await restored.enqueue(item(revision:"r6"))
        let slow2=Task {try await restored.runNext(process:{_ in try await Task.sleep(nanoseconds:1_000_000_000);return .committed})}
        try await Task.sleep(nanoseconds:20_000_000)
        await restored.pauseAndDrain();_ = try await slow2.value
        check(try await restored.runNext(process:committed)==nil,"pause drains before provider switch")
        check(await restored.snapshot().first(where:{$0.item.key==a.key})?.status == .retry,"interrupted inference remains retryable")
        try await restored.enqueue(item(revision:"r6",policy:"p2"))
        check(await restored.snapshot().first(where:{$0.item.key==a.key})?.attempts==0,"policy revision supersedes retry")
        let link=root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:root)
        do {let bad=try PendingNoteScheduler(file:link.appendingPathComponent("bad.json"));_ = bad;fatalError("symlink")}catch {print("PASS symlink parent rejected")}
        let invalid=root.appendingPathComponent("invalid.json")
        try Data("not-json".utf8).write(to:invalid)
        do {let bad=try PendingNoteScheduler(file:invalid);_ = bad;fatalError("corrupt")}catch {print("PASS corrupt ledger fails closed")}
        let preference=root.appendingPathComponent("preference.json")
        try await savePreference(preference,true)
        check(try await readPreference(preference)==true,"local resume true survives restart")
        try await savePreference(preference,false)
        check(try await readPreference(preference)==false,"local resume false survives restart")
        let legacy=root.appendingPathComponent("legacy.json")
        try Data("{\"version\":1,\"entries\":[]}".utf8).write(to:legacy)
        check(try await readPreference(legacy)==nil,"legacy ledger has no implied local activation")
        let preferenceText=try String(contentsOf:preference,encoding:.utf8)
        check(!preferenceText.lowercased().contains("cloud"),"no cloud activation persisted")
        try await restored.start()
        let discarded=Task {try await restored.runNext(preferredKey:a.key,process:{_ in
            try await Task.sleep(nanoseconds:1_000_000_000);return .committed
        })}
        try await Task.sleep(nanoseconds:20_000_000)
        try await restored.discard(key:a.key)
        _ = try await discarded.value
        check(await restored.snapshot().allSatisfy{$0.item.key != a.key},"discard cancels active without resurrection")
        print("Scheduler synthetic checks complete")
    }
}
