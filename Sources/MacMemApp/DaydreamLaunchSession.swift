import SwiftUI
import AppKit
import MemoryCore
import os

/// This branch precedes MemoryViewModel construction, including all property
/// initializers that open MemPaths.home(), preferences or writer configuration.
@MainActor final class DaydreamLaunchSession:ObservableObject {
    let isolated:Bool
    #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
    let normalChromeProbeRequested:Bool
    @Published private(set) var normalChromeProbe:ChromeNormalMainProbeSession?=nil
    #endif
    /// Set once: at init, or when launch has prepared the history (`preparing`).
    @Published private(set) var model:MemoryViewModel?=nil
    /// Launch is preparing the history off the main thread before the model opens it (HistoryPreparation: a damaged
    /// history's repair, the one-time time indexes of a history an earlier DayDream saved, the owner build's one-time
    /// settle of website typing rows; each takes seconds on a long history). Meanwhile the window and the menu bar say one calm line and nothing records: there is no model or
    /// recorder yet, and the recorder lock is held. Then `model` is made as usual and this goes false.
    @Published private(set) var preparing=false
    let development:Bool
    /// "DayDream Preview" (PreviewLaunch): sample data, never recording. Also `development` (the same isolated model).
    let preview:Bool
    let signedWriterAcceptance:Bool
    /// Set at init, or (the preview) when its sample couldn't be made.
    @Published private(set) var failure:String?
    /// `previewTemporaryDirectory`: where the preview's sample lives (the checks pass a scratch folder, so a first
    /// launch's new sample never touches the per-user one an installed preview uses).
    /// `deferModel`: the app's own scene (perf2-1005): the model is made once the window has appeared (`windowShown`).
    /// The checks make their sessions without a window and get the model at once, as before.
    init(arguments:[String]=CommandLine.arguments,previewTemporaryDirectory:URL=FileManager.default.temporaryDirectory,deferModel:Bool=false) {
        LaunchTrace.mark("session.init")
        LaunchTrace.watchMain()
        StoreMainThreadLog.install()
        defer {LaunchTrace.mark("session.ready")}
        #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
        isolated=arguments.contains("--isolated-interactive-trial")
        #else
        isolated=false
        #endif
        #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
        normalChromeProbeRequested=ChromeNormalMainProbeAdmission.requested(arguments)
        if normalChromeProbeRequested {
            preview=false;development=false;signedWriterAcceptance=false
            do {
                let request=try ChromeNormalMainProbeAdmission.validate(arguments,info:Bundle.main.infoDictionary ?? [:])
                normalChromeProbe=ChromeNormalMainProbeSession(request:request);failure=nil
            } catch {failure="QA normal-main Chrome isolation refused. No normal model was opened."}
            return
        }
        #endif
        preview=PreviewLaunch.requested(arguments:arguments)
        development=preview || arguments.contains("--development-trial") || Bundle.main.object(forInfoDictionaryKey:"DaydreamDevelopmentTrial") as? Bool == true
        #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
        signedWriterAcceptance=SignedWriterTrial.requested(arguments:arguments) && !development
        if SignedWriterTrial.requested(arguments:arguments) {
            model=nil
            failure=development ? "Signed writer acceptance is unavailable in Development Trial." : nil
            return
        }
        #else
        signedWriterAcceptance=false
        #endif
        if preview {
            // Before anything opens a history: MAC_MEM_HOME points at the preview folder now, on the main thread, so nothing
            // that runs while the sample is seeded (Help › Report a Problem…, say) can reach the real history. It stays on
            // the preview path even when seeding fails. The folder is made (or today's reused) off the main thread (a new
            // seed takes a few seconds) while the window says "Getting ready…".
            PreviewLaunch.pointHome(temporaryDirectory:previewTemporaryDirectory)
            failure=nil;preparing=true
            let reuse = !arguments.contains(PreviewSample.reseedArgument)
            Self.preparationQueue.async { [weak self] in
                let trial=Result {try PreviewLaunch.prepare(temporaryDirectory:previewTemporaryDirectory,reuse:reuse)}
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.previewPrepared(trial) }
                }
            }
            return
        }
        if development {
            do {let trial=try DevelopmentTrial.validate();try trial.prepare();model=MemoryViewModel(development:trial);failure=nil}
            catch {model=nil;failure="Development Trial isolation rejected. No normal memory was opened."}
        } else {
            #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
            let recordingTrial=arguments.contains("--recording-trial") || Bundle.main.object(forInfoDictionaryKey:"DaydreamRecordingTrial") as? Bool == true
            let functionalTrial=arguments.contains("--functional-trial") || Bundle.main.object(forInfoDictionaryKey:"DaydreamFunctionalTrial") as? Bool == true
            #else
            let recordingTrial=false,functionalTrial=false
            #endif
            // gold r2: one DayDream at a time. Another copy is running: it comes forward and this one exits quietly,
            // before it moves, opens or saves anything (OtherCopy.swift).
            if !isolated && !recordingTrial && !functionalTrial && OtherCopy.handedOff(mine:MemoryViewModel.readLaunchLocation()) {
                model=nil;failure=nil;return
            }
            if !isolated {Self.moveLegacyInstall()}
            failure=nil
            guard !isolated else {return}
            let home=MemPaths.home()
            // wal-1005: the history's journal (HistoryJournal.swift): the write-ahead log unless this Mac's setting puts
            // it back in the rollback journal.
            HistoryJournal.wanted=HistoryJournal.wanted(fromDefaults:UserDefaults.standard.string(forKey:HistoryJournal.defaultsKey))
            guard Self.prepares(home:home) else {
                guard deferModel else {
                    model=MemoryViewModel(recordingTrial:recordingTrial,functionalTrial:functionalTrial)
                    LaunchTrace.mark("model.made")
                    return
                }
                // perf2-1005 (owner 10/04, "took like 10 seconds"): the window first. The model opens the history, wires
                // the typing key and the recorder on the main thread (2.4 s on the owner's laptop before any window);
                // it is made once the "Getting ready…" window has appeared (`windowShown`), or a moment after launch
                // when no window opens (a launch at login), so the window draws first.
                preparing=true
                pendingModel={ [weak self] in
                    guard let self else {return}
                    self.model=MemoryViewModel(recordingTrial:recordingTrial,functionalTrial:functionalTrial)
                    LaunchTrace.mark("model.made")
                    self.preparing=false
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+Self.modelFallback) { [weak self] in
                    MainActor.assumeIsolated { self?.makePendingModel() }
                }
                return
            }
            preparing=true
            Self.preparationQueue.async { [weak self] in
                // Opened as the model opens it (a row the settle deletes leaves the search index too); the preparation
                // then builds what the history lacks itself, waiting for AI apps' reads (HistoryPreparation.finish).
                let outcome=HistoryPreparation.prepare(home:home) { try MemoryStore(home:$0,writable:true,automaticallySyncSearch:!recordingTrial,launchWork:.preparation,liveHistory:true) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.prepared(outcome,recordingTrial:recordingTrial,functionalTrial:functionalTrial) }
                }
            }
        }
    }

    /// Launch prepares the history before the model (`preparing`) only when there is work that takes long
    /// (`HistoryPreparation.needed`: one file lookup and a read of the schema on a usual launch). Not in a
    /// second copy of DayDream (the recorder lock is held: the model says another copy is open, having opened nothing).
    static func prepares(home:URL)->Bool {
        !MemoryViewModel.recorderLockHeld(home:home) && HistoryPreparation.needed(home:home)
    }
    private static let preparationQueue=DispatchQueue(label:"DayDream.history-preparation",qos:.userInitiated)
    /// perf2-1005: the model waiting for the window (`windowShown`), made once.
    private var pendingModel:(()->Void)?
    /// A launch whose window never appears (at login, the window closed) makes its model this long after launch.
    static let modelFallback:TimeInterval=1.0
    /// The "Getting ready…" window appeared: the model is made on the next turn, after this frame is drawn.
    func windowShown() {
        guard pendingModel != nil else {return}
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.makePendingModel() } }
    }
    private func makePendingModel() {
        guard let make=pendingModel else {return}
        pendingModel=nil
        make()
    }
    private func previewPrepared(_ trial:Result<DevelopmentTrial,Error>) {
        switch trial {
        case .success(let trial): model=MemoryViewModel(development:trial)
        case .failure: failure="The preview's sample data couldn't be made. Nothing was opened or recorded."
        }
        preparing=false
    }
    private func prepared(_ outcome:HistoryPreparation.Outcome,recordingTrial:Bool,functionalTrial:Bool) {
        model=MemoryViewModel(recordingTrial:recordingTrial,functionalTrial:functionalTrial,prepared:outcome)
        LaunchTrace.mark("model.made")
        preparing=false
    }

    /// The one-time move from the pre-rename "Mac Mem" install (DaydreamIdentity.swift). Only the
    /// installed DayDream app does it, before anything opens the history and while recording is off.
    /// A deferred move changes nothing: MemPaths.home() keeps using the old folder until it succeeds.
    private(set) static var legacyMove:DataHomeMigration.Outcome = .notNeeded
    private static func moveLegacyInstall() {
        guard Bundle.main.bundleIdentifier == DaydreamIdentity.bundleID,
              (ProcessInfo.processInfo.environment["MAC_MEM_HOME"] ?? "").isEmpty else {return}
        DaydreamIdentity.migrateDefaults(legacy:UserDefaults.standard.persistentDomain(forName:DaydreamIdentity.legacyBundleID),
                                         into:UserDefaults.standard)
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier:DaydreamIdentity.legacyBundleID).isEmpty
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support",isDirectory:true)
        legacyMove = DataHomeMigration.run(applicationSupport:support, legacyAppRunning:running)
        // Both folders hold a history: DayDream never opens the Mac Mem one, so its build 4
        // plain-text typed words are deleted here (stubs stay), as launch does for DayDream's own.
        // Off the main thread: with a 280 MiB history it took about 2.8 s before the first window,
        // at every launch while both folders exist. Nothing waits for it.
        legacyTypedScrubQueue.async {
            let outcome = LegacyTypedScrub.run(applicationSupport:support, legacyAppRunning:running)
            Task { @MainActor in legacyTypedScrub = outcome }
        }
    }
    private static let legacyTypedScrubQueue = DispatchQueue(label: "DayDream.legacy-typed-scrub", qos: .utility)
    private(set) static var legacyTypedScrub:LegacyTypedScrub.Outcome = .notNeeded
}

/// claude/perf3-1005: a debug build of the app reports each place that uses the history on the main thread
/// (`StoreMainThread`), once per place, in the log (subsystem `com.getnorthlight.daydream`, category `store-main`): the
/// statement's first word and the calling functions' names, never a value. With `DAYDREAM_STORE_MAIN_ASSERT=1` in the
/// environment it stops at the first one (assertionFailure). Release builds set nothing.
enum StoreMainThreadLog {
    static func install() {
        #if DEBUG && !DEVELOPMENT_SOURCE_CHECKS
        guard StoreMainThread.report == nil else { return }
        let log = os.Logger(subsystem: "com.getnorthlight.daydream", category: "store-main")
        let stop = ProcessInfo.processInfo.environment["DAYDREAM_STORE_MAIN_ASSERT"] == "1"
        var seen = Set<String>()
        StoreMainThread.report = { verb in
            let callers = Thread.callStackSymbols.dropFirst(4).prefix(6).map { line in
                line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).first.map(String.init) ?? ""
            }.joined(separator: " < ")
            guard seen.insert(callers).inserted else { return }
            log.fault("history used on the main thread: \(verb, privacy: .public) from \(callers, privacy: .public)")
            if stop { assertionFailure("history used on the main thread: \(verb) from \(callers)") }
        }
        #endif
    }
}
