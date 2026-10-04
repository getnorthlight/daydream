import SwiftUI
import MemoryUI
import MemoryCore
import BackupRestore
import Darwin

func physicalDirectory(_ url:URL) throws -> URL {
    guard let resolved=realpath(url.path,nil) else {throw BackupFailure.invalid}
    defer {free(resolved)}
    return URL(fileURLWithPath:String(cString:resolved),isDirectory:true)
}

private struct BackupRequest:Encodable {
    var operation:String;var source:String
    var destination:String?;var backup:String?;var manifestSHA256:String?
    var build:String?;var version:String?;var prepared:BackupPrepared?;var confirmed:Bool?
}
private final class BackupCancellation {
    private let lock=NSLock();private var cancelled=false
    func set(_ value:Bool) {lock.lock();cancelled=value;lock.unlock()}
    func read()->Bool {lock.lock();defer{lock.unlock()};return cancelled}
}
@MainActor final class BackupSettingsModel:ObservableObject {
    @Published var busy=false
    @Published var status=""
    @Published var prepared:BackupPrepared?
    let home:URL
    private let worker=BackupWorker()
    private let cancellation=BackupCancellation()
    private let helperOverride:URL?
    private var stagingRoot:URL?
    var permitted:()->Bool={false}
    var onResolved:()->Void={}
    var allowedPath:(URL)->Bool={_ in true}
    var requiresKnownBackup=false
    var trialBackupDirectory:URL?
    /// A launch repaired a damaged history and some rows couldn't be read (StoreIntegrity, gold G45). The menu's orange
    /// line leads here until this page has been seen or a backup restored (`historySetAside`). The damaged file is kept
    /// beside the history, and this page says so with the one button that deletes it, for as long as it is there
    /// (`damagedCopy`; Remove everything deletes it too).
    @Published private(set) var historySetAside=BackupSettingsModel.defaults.bool(forKey:BackupSettingsModel.historySetAsideKey)
    /// Where that line is remembered across launches. A check sets its own, in memory, so it writes no preferences file.
    static var defaults:UserDefaults = .standard
    @Published private(set) var damagedCopy=false
    static let historySetAsideKey="DaydreamHistoryDamagedV2"
    static let historySetAsideLine="Some of your history couldn't be read. DayDream kept the damaged file."
    static let deleteDamagedTitle="Delete Damaged File"
    /// Under a restore preview's count, only when a repair that couldn't read back every deletion held some of the
    /// backup back (`CanonicalRestorePreview.heldBackBefore`): why the count is short, often "0 actions to add". nil
    /// for every other preview, which says nothing more.
    static func heldBackLine(_ heldBackBefore:String?)->String? {heldBackBefore == nil ? nil:heldBackWords}
    static let heldBackWords="Older actions aren't added, in case you deleted them."
    func noteHistorySetAside() {historySetAside=true;damagedCopy=true;Self.defaults.set(true,forKey:Self.historySetAsideKey)}
    func historySetAsideSeen() {
        guard historySetAside else {return}
        historySetAside=false;Self.defaults.removeObject(forKey:Self.historySetAsideKey)
    }
    /// Deletes the kept damaged file; the line goes with it. One that can't be deleted stays, and so does the line.
    func deleteDamagedCopy() {
        guard !busy else {return}
        try? StoreIntegrity.deleteDamagedCopies(home:home)
        damagedCopy = !StoreIntegrity.damagedCopies(home:home).isEmpty
        if damagedCopy {status="Couldn't delete the damaged file. Try again."} else {historySetAsideSeen()}
    }
    var helper:URL {helperOverride ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mac-mem-backup")}
    var available:Bool {FileManager.default.isExecutableFile(atPath:helper.path)}
    private var pendingFile:URL {home.appendingPathComponent("backup-pending-v1.json")}
    init(home:URL,helper:URL?=nil) {
        self.home=home;helperOverride=helper
        damagedCopy = !StoreIntegrity.damagedCopies(home:home).isEmpty
        if !damagedCopy {historySetAsideSeen()}   // deleted another way: the menu never points at a line that isn't there
        let file=home.appendingPathComponent("backup-pending-v1.json")
        if FileManager.default.fileExists(atPath:file.path) {
            do {
                // A restore preview lists every moment it adds, so it can be as large as the helper's reply (G29).
                let value=try JSONDecoder().decode(BackupPrepared.self,from:LegacyMigration.file(file,limit:CanonicalBackupBounds.messageBytes))
                let candidate=URL(fileURLWithPath:value.staging),parent=candidate.deletingLastPathComponent()
                let temp=try physicalDirectory(FileManager.default.temporaryDirectory)
                guard candidate.lastPathComponent=="candidate",parent.deletingLastPathComponent()==temp,
                      parent.lastPathComponent.hasPrefix("macmem-restore-"),UUID(uuidString:String(parent.lastPathComponent.dropFirst("macmem-restore-".count))) != nil else {throw BackupFailure.invalid}
                prepared=value;stagingRoot=parent;status="Previous restore needs review. Nothing runs automatically."
            } catch {status="Saved restore review is invalid. No restore was started."}
        }
    }
    /// A saved restore preview whose time ran out can't be confirmed: the app closes it at launch, so it holds nothing
    /// back. Nothing is restored. Returns the closed preview's id.
    func closeExpiredPreview(now:Date) -> String? {
        guard !busy,let prepared,let end=timestamp(prepared.preview.expiresAt),end < now else {return nil}
        self.prepared=nil;try? savePending();cleanup();status=Self.previewExpired
        return prepared.preview.id
    }
    static let previewExpired="The restore preview expired. Nothing was restored."
    private func savePending() throws {
        if let prepared {try JSONEncoder().encode(prepared).write(to:pendingFile,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:pendingFile.path)}
        else if FileManager.default.fileExists(atPath:pendingFile.path) {try FileManager.default.removeItem(at:pendingFile)}
    }
    private func pin(_ hash:String,for url:URL,save:Bool) throws {
        let file=home.appendingPathComponent("backup-pins-v1.json")
        var pins:[String:String]=[:]
        if FileManager.default.fileExists(atPath:file.path) {pins=try JSONDecoder().decode([String:String].self,from:LegacyMigration.file(file,limit:256*1024))}
        let identity=url.standardizedFileURL.path
        if let old=pins[identity],old != hash {throw BackupFailure.invalid}
        if save {pins[identity]=hash;guard pins.count<=1000 else {throw BackupFailure.limit};try JSONEncoder().encode(pins).write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)}
    }
    private func invoke<T:Decodable>(_ request:BackupRequest,as:T.Type) async throws -> T {
        guard available,permitted() else {throw MemError.denied}
        cancellation.set(false)
        let executable=helper,worker=worker,cancellation=cancellation,data=try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos:.userInitiated).async {
                continuation.resume(with:Result {try JSONDecoder().decode(T.self,from:worker.run(executable:executable,request:data,cancelled:cancellation.read))})
            }
        }
    }
    func export() {
        guard !busy,permitted(),available else {status="Stop recording and turn off summaries, then finish other work first.";return}
        let panel=NSSavePanel();panel.nameFieldStringValue="DayDream Backup";panel.message="Backups aren't encrypted."
        if let trialBackupDirectory {panel.directoryURL=trialBackupDirectory;panel.message="Save a synthetic backup inside this Development Trial's backups folder."}
        guard panel.runModal() == .OK,let destination=panel.url else {return}
        export(to:destination)
    }
    func export(to destination:URL) {
        guard allowedPath(destination) else {status="Development Trial backups must stay in its backups folder.";return}
        guard !busy,permitted(),available else {return}
        busy=true
        Task {defer {busy=false}
            do {
                let seal=try await invoke(BackupRequest(operation:"export",source:home.path,destination:destination.path,build:Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "local",version:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "local"),as:BackupSeal.self)
                try pin(seal.manifestSHA256,for:destination,save:true)
                status="Backup saved."
            } catch {status="Backup failed. Any incomplete folder is not a verified backup."}
        }
    }
    func restore() {
        guard !busy,permitted(),available else {status="Stop recording and turn off summaries, then finish other work first.";return}
        guard prepared==nil else {status="Cancel or confirm the current preview first.";return}
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false;panel.message="Choose a DayDream backup."
        if let trialBackupDirectory {panel.directoryURL=trialBackupDirectory;panel.message="Choose a backup exported by this Development Trial. Personal imports are disabled."}
        guard panel.runModal() == .OK,let backup=panel.url else {return}
        prepare(from:backup)
    }
    func prepare(from backup:URL) {
        guard allowedPath(backup) else {status="Development Trial can restore only its own synthetic backups.";return}
        if requiresKnownBackup {
            guard let data=try? Data(contentsOf:home.appendingPathComponent("backup-pins-v1.json")),
                  let pins=try? JSONDecoder().decode([String:String].self,from:data),pins[backup.standardizedFileURL.path] != nil else {status="Choose a backup exported by this Development Trial.";return}
        }
        guard !busy,permitted(),available,prepared==nil else {return}
        busy=true
        Task {defer {busy=false}
            do {
                let manifest=try LegacyMigration.file(backup.appendingPathComponent("manifest.json"),limit:256*1024)
                let digest=NativeBackup.hash(manifest)
                try pin(digest,for:backup,save:false)
                let root=try physicalDirectory(FileManager.default.temporaryDirectory).appendingPathComponent("macmem-restore-"+UUID().uuidString)
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);stagingRoot=root
                prepared=try await invoke(BackupRequest(operation:"prepare",source:home.path,destination:root.appendingPathComponent("candidate").path,backup:backup.path,manifestSHA256:digest),as:BackupPrepared.self)
                try pin(digest,for:backup,save:true)
                try savePending()
                status="Backup verified. Review the exact additions."
            } catch {self.prepared=nil;cleanup();status="Restore preview rejected. Current memory is unchanged."}
        }
    }
    func confirm() {
        guard !busy,let prepared else {return};busy=true
        Task {defer {busy=false}
            do {
                let receipt=try await invoke(BackupRequest(operation:"confirm",source:home.path,prepared:prepared,confirmed:true),as:CanonicalRestoreReceipt.self)
                status="Restored \(receipt.addedActionIDs.count) actions. Recording stays off.";self.prepared=nil;historySetAsideSeen();try savePending();cleanup();onResolved()
            } catch {self.prepared=prepared;status="Couldn't confirm the restore. Check your history, then review again."}
        }
    }
    /// Closes a preview inside the app (the app sets it): what the helper's cancel does, dropping the preview's row.
    var closeHere:((String) throws -> Void)?
    func cancel() {
        if busy {cancellation.set(true);status="Canceling. DayDream will check whether the restore already finished.";return}
        guard !busy,let prepared else {return}
        // The helper runs only with recording and notes off; closing a preview writes nothing else, so it never waits for that.
        if !permitted(),let closeHere {
            do {try closeHere(prepared.preview.id);self.prepared=nil;try savePending();cleanup();status="Preview closed.";onResolved()}
            catch {status="Cancellation not confirmed. Preview remains; no restore was requested."}
            return
        }
        busy=true
        Task {defer {busy=false}
            do {_=try await invoke(BackupRequest(operation:"cancel",source:home.path,prepared:prepared),as:[String:Bool].self);self.prepared=nil;try savePending();cleanup();status="Preview closed.";onResolved()}
            catch {status="Cancellation not confirmed. Preview remains; no restore was requested."}
        }
    }
    private func cleanup() {if let stagingRoot {try? FileManager.default.removeItem(at:stagingRoot);self.stagingRoot=nil}}
}
/// Settings › Backup and restore, laid out like a macOS settings pane: one group of rows,
/// each a name, one short line and its button on the right. Only what applies now is shown: the damaged file's row
/// while that file is there, a progress row while the helper works, the restore preview's row while it waits. The
/// page is as tall as its rows (no scroll view), so the sheet fits it (`DaydreamSettingsPage.fitsContent`).
struct BackupSettingsView:View {
    @ObservedObject var model:BackupSettingsModel
    static let exportTitle="Back Up…"
    static let exportDetail="Save a copy of your memory to a folder. Backups aren't encrypted."
    static let restoreTitle="Restore…"
    static let restoreDetail="Add what's missing from a backup you saved."
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            SettingsGroup {
                if model.damagedCopy {
                    SettingsActionRow("Damaged file",detail:BackupSettingsModel.historySetAsideLine) {
                        Button(BackupSettingsModel.deleteDamagedTitle,role:.destructive,action:model.deleteDamagedCopy).disabled(model.busy)
                    }
                    SettingsGroupDivider()
                }
                SettingsActionRow("Back up",detail:Self.exportDetail) {
                    Button(Self.exportTitle,action:model.export).disabled(model.busy || !model.available)
                }
                SettingsGroupDivider()
                SettingsActionRow("Restore",detail:Self.restoreDetail) {
                    Button(Self.restoreTitle,action:model.restore).disabled(model.busy || !model.available)
                }
                if model.busy {
                    SettingsGroupDivider()
                    SettingsActionRow("Verifying local data…") {
                        ProgressView().controlSize(.small)
                        Button("Cancel",action:model.cancel)
                    }
                }
                if let prepared=model.prepared {
                    SettingsGroupDivider()
                    VStack(alignment:.leading,spacing:4) {
                        Text("\(prepared.preview.addedActionIDs.count) actions to add").font(.system(size:13,weight:.semibold))
                        if let why=BackupSettingsModel.heldBackLine(prepared.preview.heldBackBefore) {Text(why).font(.system(size:12)).foregroundStyle(.secondary)}
                        Text(prepared.preview.explanation).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        HStack(spacing:8) {
                            Spacer(minLength:0)
                            Button("Cancel",action:model.cancel).disabled(model.busy)
                            Button("Confirm Restore",action:model.confirm).disabled(model.busy).buttonStyle(SettingsGroupButtonStyle(prominent:true))
                        }.padding(.top,6)
                    }.padding(.vertical,12)
                }
            }
            if !model.available {footnote("Backup isn't available in this build.")}
            if !model.status.isEmpty {footnote(model.status).textSelection(.enabled)}
        }
        .buttonStyle(SettingsGroupButtonStyle())
        .padding(.bottom,4)
        .frame(maxWidth:.infinity,alignment:.topLeading)
        .onDisappear {model.historySetAsideSeen()}
    }
    private func footnote(_ text:String)->some View {
        Text(text).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).padding(.horizontal,16)
    }
}
