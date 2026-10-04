import SwiftUI
import MemoryCore
import MemoryUI

/// All blocking snapshot work runs on this serial actor, never the view thread.
actor MemoryFlowStore {
    let home:URL
    init(home:URL) {self.home=home}
    func choose(_ choice:MemoryOnboardingChoice) throws -> MemoryOnboardingState {
        try store().chooseOnboarding(choice)
    }
    /// Every open here comes after the model's own open of the history (launch's look for a paused import runs once this
    /// app holds it), and none does launch work (`.prepared`: no time index is built). A time index the history still
    /// lacks is launch's preparation's, before anything records (r2-store-perf): built here, beside the recorder, its one
    /// long statement held the file for seconds and every save meanwhile failed busy (gold/int round 2).
    private func store() throws -> MemoryStore {try MemoryStore(home:home,writable:true,automaticallySyncSearch:false,launchWork:.prepared)}
    func recover() throws -> StagedOnboardingImport? {
        let current=try store()
        guard let id=try current.onboardingState()?.activeImportID else {return nil}
        return try current.stagedOnboardingImport(id:id)
    }
    func preview(_ url:URL) throws -> StagedOnboardingImport {
        let bytes=try LegacyMigration.file(url,limit:64*1024*1024)
        let current=try store()
        let stage=home.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(".daydream-import-"+UUID().uuidString)
        return try current.prepareStagedOnboardingImport(snapshotURL:url,expectedHash:LegacyMigration.hash(bytes),stagingURL:stage)
    }
    func confirm(_ id:String,exclusions:Bool,limit:Int=100) throws -> StagedOnboardingImport {
        try store().stageOnboardingImport(id:id,confirmed:true,acceptPolicyExclusions:exclusions,limit:limit)
    }
    func review(_ id:String) throws -> StagedOnboardingImport {try store().prepareOnboardingAdoption(id:id)}
    func adopt(_ id:String) throws -> OnboardingAdoptionReceipt {try store().confirmOnboardingAdoption(id:id,confirmed:true)}
    func cancel(_ id:String) throws {try store().cancelStagedOnboardingImport(id:id)}
}

@MainActor final class MemoryFlows:ObservableObject {
    enum Operation {case idle,recovering,skipping,preparing,staging,reviewing,adopting,cancelling}
    @Published private(set) var operation:Operation = .idle
    @Published var session:StagedOnboardingImport?
    var preview:OnboardingImportPreview? {session?.source}
    @Published var busy=false
    /// An import holds recording back while it runs. The read at launch (`recovering`) does not: it only looks for a
    /// paused import, which stays paused until the person resumes it.
    var blocksRecording:Bool { busy && operation != .recovering }
    @Published var status=""
    @Published var acceptExclusions=false
    @Published var progress:MigrationProgress?
    private let worker:MemoryFlowStore
    @Published private var cancelRequested=false
    var cancelTitle:String? {
        guard !cancelRequested else {return nil}
        switch operation {
        case .idle: return session == nil ? nil : "Cancel"
        case .preparing: return "Cancel"
        case .staging: return "Pause after current batch"
        default: return nil
        }
    }
    var permitsImport:()->Bool = {false}
    /// `recoverNow: false` waits for `recover()`: the app looks for a paused import only once it knows it holds the
    /// history (a second copy of DayDream never opens it).
    init(home:URL,recoverNow:Bool=true) {
        worker=MemoryFlowStore(home:home)
        if recoverNow {recover()}
    }
    /// Looks for an import that was paused (it stays paused until the person resumes it).
    func recover() {
        guard !busy,operation == .idle else {return}
        busy=true;operation = .recovering
        Task {
            defer {busy=false;operation = .idle}
            do {
                session=try await worker.recover();progress=session?.progress
                if session != nil {status="Import paused. Review and resume explicitly; existing memory is unchanged."}
            } catch {status="Import state unavailable: \(error). No import resumed."}
        }
    }
    func skip() {
        guard !busy else {return};busy=true;operation = .skipping
        Task {
            defer {busy=false;operation = .idle}
            do {
                if let session {try await worker.cancel(session.id)}
                let state=try await worker.choose(.scratch);session=nil;status=state.explanation
            }
            catch {status="Choice not saved. Existing history is unchanged."}
        }
    }
    /// The status a cancelled file picker leaves (Advanced's Import History… then stays where it is).
    static let pickerCancelled="Import cancelled. Nothing imported."
    func choose() {
        guard !busy,session==nil,permitsImport() else {status="Finish or cancel the current import. Stop recording and turn off summaries before importing.";return}
        let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        panel.message="Choose a history export file."
        guard panel.runModal() == .OK,let url=panel.url else {status=Self.pickerCancelled;return}
        prepare(url)
    }
    func prepare(_ url:URL) {
        guard !busy,session==nil,permitsImport() else {return}
        busy=true;operation = .preparing;acceptExclusions=false;progress=nil;cancelRequested=false
        Task {
            let scoped=url.startAccessingSecurityScopedResource();defer {if scoped {url.stopAccessingSecurityScopedResource()};busy=false;operation = .idle;cancelRequested=false}
            do {
                let prepared=try await worker.preview(url)
                session=prepared
                guard !cancelRequested else {try await worker.cancel(prepared.id);session=nil;status="Preview cancelled. Nothing imported.";return}
                status="Check this export, then choose Review. Your current history is unchanged."
            }
            catch {status="Export not ready: \(error)"}
        }
    }
    func confirm() {
        guard !busy,let session,!session.source.blocked,permitsImport() else {return}
        busy=true;operation = .staging;cancelRequested=false
        Task {
            defer {busy=false;operation = .idle;cancelRequested=false}
            do {
                let url=URL(fileURLWithPath:session.source.snapshotPath)
                let scoped=url.startAccessingSecurityScopedResource();defer {if scoped {url.stopAccessingSecurityScopedResource()}}
                repeat {
                    guard permitsImport() else {throw MemError.invalid("Recording or another protected operation became active")}
                    let next=try await worker.confirm(session.id,exclusions:acceptExclusions);self.session=next;progress=next.progress
                    if next.progress?.complete == true {
                        operation = .reviewing
                        self.session=try await worker.review(session.id)
                        status="Review done. Check what will be added, then add it.";return
                    }
                } while !cancelRequested
                status="Review paused. Your current history is unchanged."
            } catch {status="Import stopped: \(error). Cancel and review a new stage if memory, policy or source changed."}
        }
    }
    func adopt() {
        guard !busy,let session,session.adoption != nil,permitsImport() else {return};busy=true;operation = .adopting
        Task {
            defer {busy=false;operation = .idle}
            do {
                _=try await worker.adopt(session.id);self.session=nil
                status="Reviewed history added. Existing memory retained. Recording wasn't started."
            } catch {status="Nothing added: \(error). Review again or cancel."}
        }
    }
    func review() {
        guard !busy,let session,permitsImport() else {return};busy=true;operation = .reviewing
        Task {
            defer {busy=false;operation = .idle}
            do {self.session=try await worker.review(session.id);status="Review these exact additions before confirming."}
            catch {status="Review unavailable: \(error). Cancel and prepare a new stage."}
        }
    }
    func cancel() {
        guard cancelTitle != nil else {return}
        if busy {cancelRequested=true;return}
        guard let session else {return};busy=true;operation = .cancelling
        Task {
            defer {busy=false;operation = .idle}
            do {try await worker.cancel(session.id);self.session=nil;progress=nil;status="Import cancelled. Existing memory is unchanged."}
            catch {status="Cancellation not saved: \(error)"}
        }
    }
}

struct MemoryHistorySettings:View {
    @ObservedObject var flow:MemoryFlows
    @State private var details=false
    /// One plain line with true units, from the preview's per-reason counts (LegacyMigration): what will
    /// be added, what your settings leave out (every `excluded_…` reason, which the toggle below accepts),
    /// what is already here, and what can't be imported. Zero parts are left out; nil when all are zero.
    static func countsLine(_ counts:[String:Int]) -> String? {
        func sum(_ keep:(String)->Bool) -> Int { counts.filter { keep($0.key) }.values.reduce(0,+) }
        let add=counts["accepted"] ?? 0, left=leftOut(counts)
        let already=sum { $0 == "already_imported" || $0 == "duplicate_same_source" }
        let unreadable=sum { $0.hasPrefix("unsupported") || $0.hasPrefix("conflicting") }
        let parts=[(add,"to add"),(left,"left out by your settings"),(already,"already added"),(unreadable,"can't be imported")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? nil : parts.joined(separator:" · ")
    }
    /// The items the import gate asks you to accept leaving out (StagedOnboarding: every `excluded…` count).
    static func leftOut(_ counts:[String:Int]) -> Int { counts.filter { $0.key.hasPrefix("excluded") }.values.reduce(0,+) }
    /// The export's dates, or its file name when it has none.
    static func title(_ preview:OnboardingImportPreview) -> String {
        let range=[preview.start,preview.end].compactMap{$0}.joined(separator:" to ")
        return range.isEmpty ? URL(fileURLWithPath:preview.snapshotPath).lastPathComponent : range
    }
    var body:some View {
        SettingsSurface("History") {
            SettingsCard {
                // Only when an import can start: during one, the page shows its progress and review instead.
                if !flow.busy && flow.session == nil {Button("Import History…",action:flow.choose)}
                if flow.busy {ProgressView("Working…")}
                if flow.preview == nil,let title=flow.cancelTitle {Button(title,action:flow.cancel)}
                if flow.operation == .adopting {Text("Adding reviewed history…").font(.system(size:14))}
                if !flow.status.isEmpty {Text(flow.status).font(.system(size:14)).textSelection(.enabled)}
                if let progress=flow.progress {Text("\(progress.next) of \(progress.total) reviewed").font(.system(size:14))}
            }
            if let preview=flow.preview {
                SettingsCard {
                    Text(Self.title(preview)).font(.system(size:16,weight:.semibold))
                    if let line=Self.countsLine(preview.counts) {Text(line).font(.system(size:14))}
                    // The gate: with items left out, staging is refused until you accept leaving them out.
                    let left=Self.leftOut(preview.counts)
                    if left > 0 {
                        Toggle("Leave out the \(left) \(left == 1 ? "item" : "items") your settings don't allow (needed to import)",isOn:$flow.acceptExclusions).disabled(flow.busy)
                    }
                    Text("Nothing is uploaded, and recording doesn't start.").font(.system(size:14)).foregroundStyle(.secondary)
                    if let adoption=flow.session?.adoption {
                        let items=adoption.actionIDs.count + adoption.historicalSummaryIDs.count
                        Text("Add \(items) \(items == 1 ? "item" : "items"). Your current history stays.").font(.system(size:16,weight:.semibold))
                        Button("Add reviewed history to memory",action:flow.adopt).disabled(flow.busy)
                    } else {
                        Button(flow.progress == nil ? "Review…" : "Continue Review",action:flow.confirm).disabled(flow.busy || preview.blocked)
                    }
                    if let title=flow.cancelTitle {Button(title,action:flow.cancel)}
                    if flow.session?.adoption != nil {
                        DisclosureGroup("Details",isExpanded:$details) {
                            Button("Review Again",action:flow.review).disabled(flow.busy)
                        }
                    }
                }
            }
        }
    }
}
