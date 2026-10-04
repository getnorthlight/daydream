import SwiftUI
import MemoryCore

@main struct DevelopmentModelChecks {
    @MainActor static func main() async throws {
        let trial=try DevelopmentTrial.validate();try trial.prepare()
        let model=MemoryViewModel(development:trial)
        for _ in 0..<100 {if !model.history.busy {break};try await Task.sleep(nanoseconds:10_000_000)}
        precondition(!model.recording && model.noteWriter.provider=="off" && !model.noteWriter.busy && !model.noteWriter.cloudEnabled)
        precondition(!model.updates.canCheck && model.activity.reopenCanonical==nil && model.activity.generateCanonicalNote==nil)
        precondition(!model.history.permitsImport())
        model.startCapture();model.pauseFor(minutes:5)
        precondition(!model.recording && model.pauseUntil==nil)
        let found=try await model.activity.searchCanonical!("research",nil)
        precondition(found.items.count==5)
        let store=try MemoryStore(home:trial.memory)
        let action=try store.action(found.items[0].id)!
        try model.activity.correctCanonical!(MemoryActionScope(kind:"action",id:action.id),"Development model correction",action.revision)
        let preview=try model.activity.previewCanonicalDelete!(MemoryActionScope(kind:"action",id:found.items[1].id))
        try model.activity.cancelCanonicalDelete!(preview.id)
        let afterCancel=try store.action(found.items[1].id);precondition(afterCancel != nil)
        let next=try model.activity.previewCanonicalDelete!(MemoryActionScope(kind:"action",id:found.items[1].id))
        try model.activity.confirmCanonicalDelete!(next.id)
        model.refresh();precondition(model.items.count==4)
        let second=MemoryViewModel(development:trial)
        precondition(!second.recording && second.noteWriter.provider=="off" && !second.noteWriter.busy && second.items.count==4)
        precondition(second.backups.requiresKnownBackup && second.backups.allowedPath(trial.root.appendingPathComponent("backups/test")))
        let backup=BackupSettingsModel(home:trial.memory,helper:URL(fileURLWithPath:CommandLine.arguments[1]))
        backup.permitted={true};backup.allowedPath=trial.allowsBackup;backup.requiresKnownBackup=true
        let exported=trial.root.appendingPathComponent("backups/test.macmembackup")
        backup.export(to:exported)
        for _ in 0..<500 {if !backup.busy {break};try await Task.sleep(nanoseconds:10_000_000)}
        precondition(backup.status == "Backup saved.",backup.status)
        backup.prepare(from:exported)
        for _ in 0..<500 {if !backup.busy {break};try await Task.sleep(nanoseconds:10_000_000)}
        precondition(backup.prepared != nil,backup.status)
        backup.cancel()
        for _ in 0..<500 {if !backup.busy {break};try await Task.sleep(nanoseconds:10_000_000)}
        precondition(backup.prepared == nil,backup.status)
        backup.prepare(from:URL(fileURLWithPath:"/private/tmp/unapproved-personal-backup"))
        precondition(!backup.busy && backup.prepared == nil)
        print("PASS actual MemoryViewModel: startup/reconstruction OFF, disabled capabilities, actual search/correction/cancel/delete bindings, retained state and backup scope")
        print("PASS actual backup model/helper: synthetic export, restore preview, cancel, outside-path denial")
    }
}
