import SwiftUI
import AppKit
import MemoryCore
import MemoryUI
import WriterBackend
import CoreIntegration
import notify

/// How "On this Mac" is admitted. The app always uses `.live`; checks swap in fakes to prove that a
/// launch never goes online and that only a click reaches Apple.
struct LocalAdmission {
    /// Offline only: the downloaded model and the runtime inside the app, checked with the certificate
    /// status already saved on this Mac. Never uses the network.
    var restoreOffline:@Sendable (URL,[Data]) async throws -> CompatibleWriterFiles
    /// The only network use: asks Apple about DayDream's signing certificate. Reached from a click only.
    var checkWithApple:@Sendable () async throws -> Void
    var signedBuild:@Sendable () throws -> Bool
    /// fix/sx-engine-battery: downloads the model into the folder (resuming a partial file), reporting progress.
    /// fix/model-download: network drops, sleep, stalls and busy servers are retried by itself (PersistentModelCache); a
    /// failure reaches here only after that, or for a 4xx, a full disk or a damaged file. Signed
    /// builds return nil (the runtime is inside the app: `restoreOffline` then checks both); development builds return
    /// the files they installed. Checks swap in a fake.
    var download:@Sendable (URL,@escaping @Sendable (InstallState) -> Void) async throws -> CompatibleWriterFiles? = LocalAdmission.liveDownload
    static let live=LocalAdmission(
        restoreOffline:{try await WriterRuntimeAdmission.restore(modelRoot:$0,revocationResponses:$1)},
        checkWithApple:{try await RuntimeTrustProvisioning.prepareForExplicitLocalSetup()},
        signedBuild:{try WriterRuntimeAdmission.requiresSignedDistribution()})
    static let liveDownload:@Sendable (URL,@escaping @Sendable (InstallState) -> Void) async throws -> CompatibleWriterFiles? = { root,progress in
        if try WriterRuntimeAdmission.requiresSignedDistribution() {
            // Signed releases never download/load upstream ad-hoc libraries.
            _ = try await PersistentModelCache.acquire(in:root,priorRoots:PersistentModelCache.searchRoots(for:root),progress:progress)
            return nil
        }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let installer=CompatibleInstallation()
        return try await withTaskCancellationHandler(operation:{try await installer.install(in:root,progress:progress)},
                                                     onCancel:{Task {await installer.cancel()}})
    }
}

/// fix/sx-engine-battery: what the writer reads about this Mac. The app uses `.live`; checks and the simulation swap in
/// a clock they move and power and idle they set, and drive `pass(_:)` themselves (`automatic` false).
struct WriterEnvironment {
    var now:@Sendable () -> Date = {Date()}
    var power:@Sendable () -> ModelPower = {ModelPower.current()}
    /// Seconds since the last keyboard, mouse or trackpad input.
    var idleSeconds:@Sendable () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:CGEventType(rawValue:UInt32.max)!)
    }
    /// Actual key-down age only: pointer movement and clicks never pause inference.
    var typingSeconds:@Sendable () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.keyDown)
    }
    /// perf2-1005 (owner 10/04): seconds the background writer still waits before it reads the history or writes a note
    /// (the app: while DayDream opens, `LaunchQuiet`, and while keys were typed in the last `typingBurst` seconds). 0: go.
    /// Summarize Now and an AI app's request never wait for it. Checks: never waits.
    var quietFor:@Sendable () -> TimeInterval = {0}
    /// perf2-1005: the priority the background writer's passes and note runs take (nil: the caller's; the app: utility).
    var workPriority:TaskPriority?=nil
    /// perf2-1005 (owner 10/04): false (the app), only today's moments get notes in the background: no catch-up of past
    /// days, and a past day's entries still in the queue (a moment of yesterday at midnight, an older backlog) are dropped,
    /// never run. Notes they already have stay; levels never wait for them (a block leaves a waiting moment out a day after
    /// it ended). Summarize Now and AI apps' requests are unchanged. Checks keep the 7-day catch-up (true).
    var pastDayNotes=true
    var timezone:@Sendable () -> String = {TimeZone.current.identifier}
    var defaults:UserDefaults = .standard
    /// The model runtime for checked files. The writer wraps it in one `BatchRuntime` per activation.
    var makeRuntime:(@Sendable (CompatibleWriterFiles) -> any LocalInference)?
    /// Predicate-aware fixture factory; ordinary fake factories remain compatible.
    var makeRuntimeWithPause:(@Sendable (CompatibleWriterFiles,@escaping @Sendable () -> Bool) -> any LocalInference)?
    /// BatchRuntime's wait before it unloads an idle model.
    var unloadSleep:BatchRuntime.Sleep = {try await Task.sleep(nanoseconds:UInt64(max(0,$0)*1_000_000_000))}
    /// Tells a waiting AI app that the on-demand notes are written (`WriterIntegration.recentDone`).
    var postDone:@Sendable () -> Void = {notify_post(WriterIntegration.recentDone)}
    /// false: no timer and no system observers; the caller runs `pass(_:)` at `nextWake` and on the events it plays.
    var automatic=true
    /// Only source metadata discovery is debounced; never capture, privacy fencing or inference.
    var sourceChangeSleep:@Sendable (TimeInterval) async throws -> Void = {seconds in
        try await Task.sleep(nanoseconds:UInt64(max(0,seconds)*1_000_000_000))
    }
    /// claude/dayeval-1005 (owner 10/05: "the only thing that needs a summary is the day"): false, no model writes a moment
    /// or level note: code writes them (`CanonicalGrounding.codeOnlyNote`, LevelRunner's code notes) and the model is
    /// loaded only for the day card's line. Checks and `.live` keep the model (true); the app runs on `.app`, which turns
    /// it off unless the hidden default `DayDreamMomentSummaries` is set (`WriterQuiet.swift`, with perf2-1005's quiet rules).
    var momentModel=true
    static let live=WriterEnvironment()
}

/// Why the writer looks now.
enum WakeReason: Equatable, Sendable {
    /// The one scheduled wake-up (`nextWake`).
    case timer
    /// The screen locked, or the Mac is going to sleep: every moment that ended before now is closed.
    case lock, sleep
    /// The Mac woke from sleep.
    case wake
    /// The power source, Low Power Mode or the thermal state changed.
    case power
    /// A writer was turned on, Retry, or a check.
    case explicit
}

/// Admission is read again at the actual local runtime boundary, after asynchronous canonical preparation.
/// A declined boundary cancels this attempt; it is not a model-load failure. Unload is always permitted.
private struct AdmissionGuardedInference:LocalInference {
    let base:any LocalInference
    let allowed:@Sendable () async -> Bool
    private func check() async throws {
        try Task.checkCancellation()
        guard await allowed() else {throw CancellationError()}
    }
    func load() async throws {try await check();try await base.load();try await check()}
    func unload() async {await base.unload()}
    func generate(instruction:String,evidence:String,maxTokens:Int) async throws -> Data {
        try await generate(instruction:instruction,evidence:evidence,maxTokens:maxTokens,prefill:"")
    }
    func generate(instruction:String,evidence:String,maxTokens:Int,prefill:String) async throws -> Data {
        try await check()
        return try await base.generate(instruction:instruction,evidence:evidence,maxTokens:maxTokens,prefill:prefill)
    }
    func generate(instruction:String,evidence:String,maxTokens:Int,prefill:String,expiresAt:Date) async throws -> Data {
        try await check()
        return try await base.generate(instruction:instruction,evidence:evidence,maxTokens:maxTokens,prefill:prefill,expiresAt:expiresAt)
    }
}

@MainActor final class WriterIntegration:ObservableObject {
    @Published var status="Summaries on this Mac aren't set up."
    @Published var progress:Double?
    @Published private(set) var downloadEstimate=DownloadTimeEstimate()
    /// Downloading or checking the model only. Writing notes never sets it (fix/sx-engine-battery).
    @Published var busy=false
    @Published var ready=false
    /// fix/sx-engine-battery: the one summaries state every surface shows (MemoryUI/SummaryPhase.swift).
    @Published private(set) var phase:SummaryPhase = .off
    /// "off", "local" or "cloud". Every change is written to the store (`setSummaryWriter`), so the
    /// status AI apps read says whether cloud summaries are on now, not a fixed "off".
    @Published private(set) var provider="off" {didSet {if provider != oldValue {publishProvider();if provider == "off" {queue=nil;lastLook = .distantPast}}}}
    @Published private(set) var pendingCount=0
    /// fix/bugs7-late: moments the writer gave up on for good (a local note that failed its last try, so the code note
    /// stands, or a moment with nothing to write), from the ledger's written marks. The Today page shows them as not
    /// written, never as pending (`SummaryAvailability.skipped`); before, nothing published them and they looked pending.
    @Published private(set) var skippedMoments:Set<String>=[]
    private func publishSkipped() async {
        guard let scheduler else {return}
        let ids=Set(await scheduler.writtenMarks().compactMap { key,mark -> String? in
            // A legacy skipped mark without fallback is due once more. Only a final skip can say no update is scheduled.
            guard mark.skipped,!mark.recoverable,key.hasPrefix("activity\u{1f}"),let id=key.split(separator:"\u{1f}",omittingEmptySubsequences:false).last,!id.isEmpty else {return nil}
            return String(id)
        })
        if ids != skippedMoments {skippedMoments=ids}
    }
    /// fix/writing-forever: what the writer has queued (by moment ID), the moments still going at its last look, and why
    /// this Mac's model waits (Today says "Writing the summary…" only for a queued moment; `SummaryAvailability.queue`).
    @Published private(set) var queue:SummaryQueue?
    private var lastOpen:Set<String>=[]
    private var lastLook=Date.distantPast
    private var lastWait:SummaryWait?
    private func publishQueue() async {
        guard let scheduler,provider != "off" else {if queue != nil {queue=nil};return}
        // Before the first look nothing is known about open moments: Today keeps its old line until then.
        guard lastLook != .distantPast else {return}
        let ids=Set(await scheduler.snapshot().filter {[.queued,.running,.retry].contains($0.status)}.compactMap(\.item.activityID))
        let value=SummaryQueue(writing:ids,open:lastOpen,lookedAt:lastLook,wait:provider == "local" ? lastWait : nil)
        if value != queue {queue=value}
    }
    /// Why this Mac's model can't write in the background now (nil: it can), in the order `allowsBackground` checks.
    static func wait(_ power:ModelPower) -> SummaryWait? {
        if power.allowsBackground {return nil}
        if power.lowPowerMode {return .lowPower}
        if power.thermal >= ProcessInfo.ThermalState.serious.rawValue {return .heat}
        return .battery
    }
    /// fix/writing-forever (owner lane): at most this many model loads in any hour for the background and AI apps' requests
    /// together (Summarize Now always runs; its loads count). The shipped build keeps typed rows, so nearly every moment
    /// needs the model, and a background batch every 20 minutes plus an AI app's requests loaded it up to 6 times an hour.
    static let loadsPerHour=4
    private var loadTimes:[Date]=[]
    private var seenLoads=0
    /// Records the running model's new loads (at the writer's clock).
    private func noteLoads() async {
        guard let runtime else {return}
        let n=await runtime.loads
        if n>seenLoads {loadTimes+=Array(repeating:env.now(),count:n-seenLoads)}
        seenLoads=n
        let hour=env.now().addingTimeInterval(-3600)
        loadTimes.removeAll {$0<=hour}
    }
    /// Whether a background batch or a request may load the model now; else when it may (the oldest load of the hour + 1 h).
    private func loadAllowed(_ now:Date) async -> (ok:Bool,at:Date?) {
        await noteLoads()
        let recent=loadTimes.filter {now.timeIntervalSince($0)<3600}
        guard recent.count>=Self.loadsPerHour else {return (true,nil)}
        return (false,recent.min().map {$0.addingTimeInterval(3600)})
    }
    /// Try Again on battery: the model is tried when the Mac is plugged in (Settings says so under the switch).
    @Published private(set) var retryWaitsForPower=false
    @Published private(set) var cloudEnabled=false
    /// fix/day-card: while cloud summaries are on, the moment they were turned on (nothing before it is ever sent), so
    /// Today draws earlier moments as never written, with no Summarize Now. nil otherwise.
    @Published private(set) var cloudCutoff:Date?
    /// The model is downloaded and checked, whatever else is still needed.
    @Published private(set) var modelOnMac=false
    /// On this Mac was on before the restart, but the saved certificate status has expired. It stays off
    /// until the person clicks Turn on, which asks Apple (the only network use) and then turns it back on.
    @Published private(set) var needsAppleCheck=false
    static let appleCheckLine="On this Mac is off until DayDream checks its signature with Apple."
    static let cloudDisclosure=CloudActivation.disclosure
    static let cloudDisclosureVersion=CloudActivation.disclosureVersion
    /// Whether this build can summarize on this Mac. Signed builds carry the runtime inside the app
    /// (developer-id-release.py stage); a test build staged without it greys "On this Mac" out and says so.
    /// Development builds keep it.
    static let localOffered:Bool=(try? WriterRuntimeAdmission.signedPayloadMissing()) == false
    var localOffered:Bool {offerLocal ?? Self.localOffered}
    /// Checks only: whether this build offers On this Mac (nil: `localOffered`).
    var offerLocal:Bool?

    // MARK: fix/sx-engine-battery scheduling
    /// The person's choice, kept across windows closing and relaunches: "local", "cloud" or "off".
    static let intentKey="DaydreamWriterIntent"
    /// Set while a download the person started runs; a relaunch finishes it (and only then goes online by itself).
    static let downloadingKey="DaydreamWriterDownloading"
    /// An AI app asks for the last hour's notes (Sources/MacMemCLI/main.swift `WriterFreshen`).
    nonisolated static let recentRequest="com.getnorthlight.daydream.writer.recent"
    nonisolated static let recentDone="com.getnorthlight.daydream.writer.recent.done"
    /// A batch runs at most this often while the person keeps working (sooner once the Mac is idle, locked or asleep).
    static let batchEvery:TimeInterval=20*60
    nonisolated static let typingBurst:TimeInterval=3
    /// Local closed moments must not wait for typing to stop. The ordinary batch cadence may be
    /// bypassed five minutes after the oldest queued attempt is due. Power, failure backoff,
    /// load-budget and single-writer gates still apply; inference remains on its background queue.
    static let overdueAfter:TimeInterval=5*60
    static func overdueDeadline(_ states:[ScheduledWriterState],day:String) -> Date? {
        states.filter {($0.status == .queued || $0.status == .retry) && $0.item.day==day}
            .map { $0.nextAttempt.addingTimeInterval(overdueAfter) }.min()
    }
    /// Idle this long closes every moment and starts a batch.
    static let idleClose:TimeInterval=5*60
    static let batchNotes=12
    static let catchUpNotes=10
    /// claude/catchup-1003 (owner): past days catch up steadily at low priority. On power a catch-up batch may run at every
    /// look once the Mac has been idle 5 minutes (looks are at least 5 minutes apart, and the hourly load budget holds),
    /// else every 20 minutes; on battery at most every 30 minutes. Never while the person is typing, and never ahead of today's closed
    /// moments while the person is using the Mac.
    static let catchUpBatteryEvery:TimeInterval=30*60
    static func catchUpSpacing(_ power:ModelPower,idle:TimeInterval,mode:String) -> TimeInterval {
        if mode == "local" && !power.onPower {return catchUpBatteryEvery}
        return idle>=idleClose ? 0 : batchEvery
    }
    static let batchLevels=24
    /// While this Mac's model waits (Low Power Mode, under 20%, hot), level notes are written by code at most this often.
    static let codeLevelsEvery:TimeInterval=10*60
    /// Scheduled wake-ups are at least this far apart (at most 12 an hour).
    static let wakeSpacing:TimeInterval=5*60
    /// With nothing open and nothing waiting, the writer still looks this often.
    static let quietWake:TimeInterval=15*60
    /// An AI app's request writes notes at most this often.
    static let onDemandEvery:TimeInterval=5*60
    /// fix/sx-all round 1: on battery (this Mac's model) an AI app's request writes at most 3 notes, at most every
    /// 15 minutes, and rewrites a moment it already wrote only once that note is 20 minutes old and the moment grew by a
    /// quarter. Before, every request rewrote the same open, growing moment.
    static let onDemandBatteryEvery:TimeInterval=15*60
    static let onDemandBatteryNotes=3
    /// fix/sx-all round 3: on power a request writes only moments with no note yet (the background batch rewrites the
    /// rest); before, it wrote and loaded the model about 10 times an hour.
    static let onDemandRewriteAfter:TimeInterval=20*60
    static let onDemandWindow:TimeInterval=60*60
    /// The writer-wide back-off after a failed model or provider: 1, 5, 15, then every 60 minutes.
    static let backoff:[TimeInterval]=[60,300,900,3600]
    /// What checks and the simulation read.
    struct Counters:Equatable {
        var timerPasses=0,eventPasses=0,batches=0,onDemandBatches=0,onDemandSkipped=0
        var sourceSignals=0,sourceReads=0
        var noteRuns=0,modelLevels=0,codeLevels=0,catchUpNotes=0,codeNotes=0,committedNotes=0
        /// fix/bugs7: passes that found the writer held (Summarize Now, an AI app's batch, a switch) and stopped looking.
        var heldPasses=0
        /// Ticks a pass ran (its first and each look again).
        var passTicks=0
        /// perf2-1005: looks put off while DayDream opened or the person typed (`quietFor`); past moments set aside.
        var quietDeferrals=0,pastSetAside=0
    }
    private(set) var counters=Counters()
    /// Checks and the simulation: called with each moment a note ran for.
    var onNoteRun:((ScheduledWriterTarget) -> Void)?
    /// Only stored activity notes, once per distinct day/timezone at the end of a run.
    /// nil retains the consumer's conservative unknown-scope fallback.
    var onNotesCommitted:(([NoteCommitScope]?) -> Void)?
    private func publishCommitted(_ scopes: Set<NoteCommitScope>) {
        guard !scopes.isEmpty else { return }
        onNotesCommitted?(scopes.sorted { ($0.day, $0.timezone) < ($1.day, $1.timezone) })
    }
    /// When the writer looks next by itself (nil: not scheduled).
    private(set) var nextWake:Date?
    private let env:WriterEnvironment
    private var timer:Task<Void,Never>?
    private var lastBatch=Date.distantPast
    private var lastCatchUp=Date.distantPast
    private var catchUpQuietUntil=Date.distantPast
    /// claude/catchup-1003: the last catch-up left past moments unwritten, so the next look comes when the next catch-up is
    /// allowed (`catchUpSpacing`) instead of after the quiet look.
    private var catchUpBacklog=false
    private var lastCodeLevels=Date.distantPast
    private var lastOnDemand=Date.distantPast
    private var lastTimerPass=Date.distantPast
    private var ordinaryWakeAt:Date?,serviceWakeAt:Date?,cadenceWakeAt:Date?
    private var sourceChangeTask:Task<Void,Never>?,sourceChangeToken:UUID?
    private var sourceChangeVersion=0
    private var sourceLastRead=Date.distantPast
    static let sourceChangeDebounce:TimeInterval=2
    static let sourceChangeReadSpacing:TimeInterval=60
    /// The Mac locked or slept at this time: moments that ended before it are closed.
    private var closedBy:Date?
    private var holdUntil=Date.distantPast
    private var failuresInRow=0
    /// Whether the last pass could run the model in the background (fix/battery-summaries: a pass that finds it may again
    /// writes what waited at once).
    private var wasBackground:Bool?
    private var rerun:WakeReason?
    private var powerObservation:ModelPower.Observation?
    private var systemObservers:[(NotificationCenter,NSObjectProtocol)]=[]
    private var recentToken:Int32 = -1
    /// The model runtime of the running local writer (one load per batch).
    private var runtime:BatchRuntime?
    /// A note is being written (never shown as busy).
    private var writing=false
    private enum LocalWorkAdmission {case automatic,onDemand,manual}
    private var localWorkAdmission=LocalWorkAdmission.automatic
    private var stopping:Task<Bool,Never>?
    private var setup:Task<Void,Never>?

    private var statusStore:MemoryStore?
    private let cloud:CloudActivation
    private let cloudSend:CloudSender
    private var files:CompatibleWriterFiles?
    private var work:Task<Void,Never>?
    private var downloadAttempt:UUID?
    private var lastDownloadEventTime:TimeInterval=0
    private var lastPublished:(time:TimeInterval,bytes:Int64)=(0,0)
    private var trustSetup:Task<Void,Error>?
    private var processing:Task<ScheduledWriterOutcome?,Error>?
    private var coreBinding:CoreWriterBinding?
    private var source:WriterQueueSource?
    private var scheduler:PendingNoteScheduler?
    private var adapter:CoreWriterAdapter?
    /// Levels above moments (summaries/v3): written one at a time after the moment queue is empty.
    private var levels:LevelWriterBinding?
    /// fix/r1-writer: runs each level note as a task `stopProvider` cancels and waits for (one model load at a time).
    private let levelRunner=LevelRunner()
    /// Called on the main actor with each level note the level writer commits (the app drops the cached days it shows).
    var onLevelCommitted:((LevelNote)->Void)?
    /// claude/day-review-1003: called on the main actor with the day and time zone of each day-review clause saved.
    var onReviewClauseCommitted:((String,String)->Void)?
    /// At most this many day-review clauses per look, and only while nobody types (`typingBurst`).
    static let batchClauses=2
    private var policyRevision=""
    private var modeGeneration=0
    private var expiryWaitsForQuiet=false
    /// claude/ready-1002 (owner): a version-bump rewrite waited because the person was typing; the next look comes once
    /// typing has been quiet `typingBurst` seconds.
    private var rewriteWaitsForQuiet=false
    /// perf2-1005: a batch stopped between notes because DayDream was opening or the person typed: look again then.
    private var quietWakeAt:Date?
    private var expiryRetryKeys=Set<String>()
    private func expiryQuietWake() -> Date {
        env.now().addingTimeInterval(max(1,Self.typingBurst-max(0,env.typingSeconds())))
    }
    private var switching=false
    private var cycleRunning=false
    private var sweepOffset=0
    private var liveLease=false
    /// Invalidates an acquire suspended inside BatchRuntime.beginBatch when a newer reconciliation releases it.
    private var warmLeaseRevision=0
    /// gold/notes G52: saves the mode AI apps are told, in order, and retries a failed save off the main thread.
    private var report:ProviderReport?
    private var reportRetry:Task<Void,Never>?
    private var terminateObserver:NSObjectProtocol?
    /// The writer's own status lines, owned by the pass: each is replaced once it no longer holds (gold/notes).
    static let cloudResting="Cloud enabled for new permitted actions only. Earlier history will not upload."
    static let localResting="Local writer ready. Pending notes run after activity settles."
    static let queueFull="Writer queue full. New notes wait for room. All actions retained."
    static let notePending="Note pending: capacity, changed scope, provider unavailable, or an answer that failed the grounding checks. All actions retained."
    static let cloudRetry="Note pending: couldn't reach the cloud; retry scheduled. All actions retained."
    static let localRetry="Local note pending; bounded retry scheduled. All actions retained."
    static let writerPending="Writer pending. Actions remain available; retry after resolving setup or policy."
    static let cloudNotRecorded="Couldn't save the summary setting, so cloud stays off. Try again."
    private static let pollLines=["Writer queue full","Note pending","Local note pending","Writer pending"]
    private let modelRoot:URL
    private let runtimeRevocationResponses:[Data]
    private let admission:LocalAdmission

    /// Construction reads neither Keychain nor memory. Tests inject fake HTTP/keys/admission.
    init(modelRoot:URL?=nil,keyStore:any WriterSecureKeyStore=WriterKeychain(),runtimeRevocationResponses:[Data]=[],send:@escaping CloudSender={try await CloudTransport.send($0)},admission:LocalAdmission = .live,environment:WriterEnvironment = .live) {
        self.runtimeRevocationResponses=runtimeRevocationResponses;self.admission=admission;self.env=environment
        self.modelRoot=modelRoot ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent(DaydreamIdentity.dataFolder+"/Models")
        self.cloud=CloudActivation(store:keyStore,now:environment.now);self.cloudSend=send
    }

    // MARK: intent

    enum Intent:String {case off,local,cloud}
    private var intent:Intent? {
        env.defaults.string(forKey:Self.intentKey).flatMap(Intent.init(rawValue:))
    }
    private func setIntent(_ value:Intent) {
        env.defaults.set(value.rawValue,forKey:Self.intentKey)
        // claude/recall-1004: a choice turned off while nothing runs ends "starting" for AI apps (provider stays "off").
        if value == .off && provider == "off" {publishProvider()}
    }
    /// fix/sx-all round 2: OpenRouter is the person's choice, with its key saved (set when cloud summaries turned on;
    /// cleared by turning summaries off or deleting the key). Setup starts on the OpenRouter row then.
    var cloudIntended:Bool {intent == .cloud}

    /// App interface calls once with the existing store. No second MemoryStore,
    /// direct SQL, UI changes, capture start or install occurs here.
    /// Owner decision (2026-09-26): if On this Mac was on when the app or the Mac stopped, it turns back on
    /// by itself, using only what is already on this Mac (the offline check). A launch never goes online:
    /// when the saved certificate status has expired it stays off and Settings shows one line and Turn on.
    /// fix/sx-engine-battery: the one exception is a download the person started and didn't finish (closing the window
    /// or quitting mid-download): it carries on, and summaries turn on when it's done.
    func configure(store:MemoryStore) {
        guard source==nil else {return}
        cancelSourceService()
        // Summaries start off after launch until the offline check passes: say so to AI apps (writer/v2).
        statusStore=store
        report=ProviderReport(save:{ [statusStore] provider in try statusStore?.setSummaryWriter(provider) })
        // claude/recall-1004: a saved choice that is on reads "starting" to AI apps until the writer runs (never "cloud"
        // early: G52), not "off", which they reported as "Summaries are off" right after an update.
        if let saved=intent,saved != .off {if report?.set("starting") == false {scheduleReportRetry()}} else {publishProvider()}
        // At quit "off" is the last word, so AI apps never read "cloud" from a DayDream that isn't running (G52).
        terminateObserver=NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report?.close() }
        }
        // The saved choice shows as being checked, never as off, while the check runs.
        if let saved=intent,saved != .off {phase = .checking}
        busy=true
        source=WriterQueueSource(store:store);coreBinding=Self.makeCoreBinding(store:store)
        if env.automatic {observeSystem()}
        work=Task {
            defer{busy=false;work=nil}
            var resumeDownload=false
            do {
                let root=store.home.appendingPathComponent("WriterScheduling",isDirectory:true)
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                scheduler=try PendingNoteScheduler(file:root.appendingPathComponent("pending-v1.json"),now:env.now)
                pendingCount=Self.waiting(await scheduler!.snapshot());await publishSkipped()
                policyRevision=try await source!.policyRevision()
                // Before the intent was saved (an update): the ledger's switches say what was on.
                if intent == nil {
                    if await scheduler!.resumeLocalPreference()==true {setIntent(.local)}
                    else if await scheduler!.resumeCloudPreference() != nil {setIntent(.cloud)}
                    else {setIntent(.off)}
                    if intent != .off {phase = .checking}
                }
                let wantLocal=intent == .local && localOffered
                let roots=PersistentModelCache.searchRoots(for:modelRoot)
                modelOnMac=Self.modelFilePresent(roots)
                if wantLocal {
                    if env.defaults.bool(forKey:Self.downloadingKey) && !modelOnMac {
                        // Quit mid-download: the download the person started finishes, then summaries turn on.
                        resumeDownload=true
                    } else if roots.contains(where:{FileManager.default.fileExists(atPath:$0.path)}) {
                        // A launch never goes online: the model is checked with what is on this Mac only.
                        status="Checking the model on this Mac"
                        do {files=try await admission.restoreOffline(modelRoot,runtimeRevocationResponses)}
                        catch WriterFailure.trustEvidenceUnavailable {
                            // The model passed; only Apple's certificate status is stale. No network here.
                            modelOnMac=true;needsAppleCheck=true
                            throw WriterFailure.trustEvidenceUnavailable
                        }
                        try Task.checkCancellation();ready=true;modelOnMac=true
                        let storageOK=await scheduler!.storageFailed==false
                        if storageOK {try await activateLocal();startPolling()}
                        else {phase = .failed(.modelWontStart);status=Self.writerPending}
                    } else {
                        // No model and no download under way: off, until the person turns it on (which downloads).
                        setIntent(.off);phase = .off
                        status="The model for summaries on this Mac isn't downloaded."
                    }
                } else {
                    if intent == .local {setIntent(.off)}
                    status=modelOnMac ? "Ready. Summaries are off until you turn them on." : "The model for summaries on this Mac isn't downloaded."
                    if intent != .cloud {phase = .off}
                }
            } catch {
                ready=false;status=setupFailureStatus(error)
                if intent == .local {phase = .failed(Self.problem(error,stage:.check))}
            }
            // The Cloud summaries switch left on (summaries/v3): back on after the relaunch, current notice only.
            if provider=="off" && !Task.isCancelled {await resumeCloud()}
            if intent == .cloud && provider=="off" && phase == .checking {phase = .off}
            if resumeDownload && !Task.isCancelled {busy=false;chooseLocal()}
        }
    }
    /// A model file of the right size in one of the model folders. Cheap: the hash is checked when summaries turn on.
    static func modelFilePresent(_ roots:[URL]) -> Bool {
        guard let asset=WriterCandidates.recommended?.asset else {return false}
        return roots.contains { root in
            let size=(try? FileManager.default.attributesOfItem(atPath:root.appendingPathComponent(asset.sha256+".model").path)[.size]) as? NSNumber
            return size?.int64Value == asset.bytes
        }
    }
    /// writer/v2 (owner decision 2026-09-26): summaries on this Mac read the saved typed words while typing is on,
    /// in memory in this process, so a note can say what was asked or written. One binding serves both writers:
    /// the cloud writer always gets `port(audience:.cloud)`, which counts as the cloud writer whatever this
    /// binding was made for, so it never gets the words or a typed row's window title.
    static func makeCoreBinding(store:MemoryStore)->CoreWriterBinding {CoreWriterBinding(store:store,typedWriter:.local)}

    // MARK: the one timer and the events

    /// fix/sx-engine-battery: no polling. One timer at the next moment that closes or the next batch, and the events
    /// that close moments or allow work (lock, sleep, wake, power, an AI app's request, a writer turned on).
    private func startPolling() {
        guard env.automatic else {return}
        wake(.explicit)
    }
    /// Looks now (an event). A pass already running looks again when it ends.
    func wake(_ reason:WakeReason) {
        if reason == .lock || reason == .sleep {closedBy=env.now()}
        if passing {rerun=reason;return}
        // fix/bugs7: Summarize Now, an AI app's batch or a writer switching holds the writer (no pass to look again).
        // fix/sx-all round 1: the look is kept, and `resumeDeferred` runs it as soon as that hold ends.
        if writerHeld {rerun=reason;lookAgainSoon();return}
        Task(priority:env.workPriority) { [weak self] in await self?.pass(reason) }
    }
    /// fix/sx-all round 1: a look deferred while something held the writer (a switch, an AI app's request, Summarize
    /// now) runs once that ends, instead of waiting for the next timer.
    private func resumeDeferred() {
        guard let reason=rerun,!passing,!writerHeld else {return}
        rerun=nil
        wake(reason)
    }
    /// One pass, and another if an event came in meanwhile. The simulation and checks call this directly.
    ///
    /// fix/bugs7: only one pass loops. `tick` returns at once, without suspending, while the writer is held, and `pass` and
    /// `tick` share the main actor: a pass that looped on that refusal (the one timer firing during a batch, or an event
    /// during Summarize Now, an AI app's batch or a switch) spun the main thread forever and the batch could never
    /// resume. A pass that arrives while another runs leaves its reason for that one; a pass refused by a hold that is
    /// not a pass looks again within a minute.
    func pass(_ reason:WakeReason) async {
        if reason == .timer {counters.timerPasses+=1;lastTimerPass=env.now()} else {counters.eventPasses+=1}
        switch reason {
        case .lock,.sleep:closedBy=env.now()
        default:break
        }
        guard !passing else {rerun=reason;return}
        passing=true;defer{passing=false}
        var next:WakeReason?=reason
        while let current=next {
            rerun=nil;counters.passTicks+=1
            // fix/sx-all round 1 (P0): a tick refused because the writer is busy returns at once, with no suspension;
            // looping on it spun the main thread for good. It is kept as the deferred look and this pass ends.
            if await tick(reason:current) == .busy {rerun=current;counters.heldPasses+=1;lookAgainSoon();break}
            next=rerun
            // The writer is held now, so another tick would be refused at once: never loop on it.
            if next != nil && writerHeld {counters.heldPasses+=1;lookAgainSoon();break}
        }
    }
    /// A pass is running (`pass`'s loop): it takes any reason left in `rerun` when its tick ends.
    private var passing=false
    /// What makes `tick` refuse to start. claude/summary-fail-1003: a Summarize Now waiting for the writer holds it too,
    /// so no new background look starts between the batch it waits for and the click.
    private var writerHeld:Bool {writerBusy || clicksWaiting>0}
    /// Something is writing or switching (what a Summarize Now waits for).
    private var writerBusy:Bool {switching || cycleRunning || writing || processing != nil}
    /// claude/summary-fail-1003: Summarize Now clicks waiting for the writer. A background batch stops after the note it
    /// is writing (`runNotes` and the level loop look between notes), so the click runs next instead of failing after a
    /// minute behind a long rewrite or catch-up batch.
    private var clicksWaiting=0
    /// Held by something that isn't a pass: the timer looks again within a minute (sooner if it is already due).
    static let heldRetry:TimeInterval=60
    private func lookAgainSoon() {
        guard provider != "off" else {return}
        let soon=env.now().addingTimeInterval(Self.heldRetry)
        if timer == nil || (nextWake ?? .distantFuture) > soon {schedule(soon)}
    }
    private func schedule(_ date:Date?) {
        ordinaryWakeAt=date;serviceWakeAt=nil;cadenceWakeAt=nil
        installSchedule(date)
    }
    private func installSchedule(_ date:Date?) {
        nextWake=date
        timer?.cancel();timer=nil
        guard env.automatic,let date else {return}
        let delay=max(1,date.timeIntervalSince(env.now()))
        timer=Task(priority:env.workPriority) { [weak self] in
            do {try await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000))} catch {return}
            guard let self else {return}
            self.timer=nil
            // fix/sx-all round 1: through wake, so a timer that fires while the writer is busy is deferred, not spun on.
            self.wake(.timer)
        }
    }
    /// Called only after a canonical source mutation commits. The callback carries no captured content,
    /// does no canonical read/model work, and coalesces metadata discovery outside the ingest transaction.
    func sourceChanged() {
        guard provider=="local",source != nil,scheduler != nil else {return}
        counters.sourceSignals+=1;sourceChangeVersion+=1
        beginSourceDiscovery()
    }
    private func cancelSourceService() {
        sourceChangeTask?.cancel();sourceChangeTask=nil;sourceChangeToken=nil
        let old=serviceWakeAt
        sourceChangeVersion+=1;sourceLastRead = .distantPast;serviceWakeAt=nil;cadenceWakeAt=nil
        if let old,nextWake==old {installSchedule(ordinaryWakeAt)}
    }
    private func beginSourceDiscovery() {
        guard sourceChangeTask==nil,provider=="local",!expiryWaitsForQuiet,let source,let scheduler else {return}
        let token=UUID(),epoch=modeGeneration,sleep=env.sourceChangeSleep,quietFor=env.quietFor
        let delay=max(Self.sourceChangeDebounce,Self.sourceChangeReadSpacing-env.now().timeIntervalSince(sourceLastRead))
        sourceChangeToken=token
        sourceChangeTask=Task(priority:.utility) { [weak self] in
            do {
                try await sleep(delay)
                // perf2-1005: today's read waits while DayDream opens or the person types (each key's save shares the store).
                var waits=0
                while waits<120,case let quiet=quietFor(),quiet>0 {waits+=1;try await sleep(quiet+0.25)}
            } catch {return}
            guard let self,self.sourceChangeToken==token,epoch==self.modeGeneration,
                  self.provider=="local",self.source === source,self.scheduler === scheduler,!Task.isCancelled else {return}
            let version=self.sourceChangeVersion
            defer {
                if self.sourceChangeToken==token {
                    self.sourceChangeTask=nil;self.sourceChangeToken=nil
                    if version != self.sourceChangeVersion {self.beginSourceDiscovery()}
                }
            }
            if self.expiryWaitsForQuiet {
                self.serviceWakeAt=nil;self.cadenceWakeAt=nil
                self.schedule(self.expiryQuietWake());return
            }
            guard self.env.power().allowsBackground else {
                self.serviceWakeAt=nil;self.cadenceWakeAt=nil
                self.installSchedule(self.ordinaryWakeAt);return
            }
            let marks=await scheduler.writtenMarks()
            guard epoch==self.modeGeneration,self.provider=="local",self.source === source,
                  self.scheduler === scheduler,!Task.isCancelled else {return}
            if self.expiryWaitsForQuiet {
                self.serviceWakeAt=nil;self.cadenceWakeAt=nil
                self.schedule(self.expiryQuietWake());return
            }
            guard self.env.power().allowsBackground else {
                self.serviceWakeAt=nil;self.cadenceWakeAt=nil
                self.installSchedule(self.ordinaryWakeAt);return
            }
            let now=self.env.now(),zone=self.env.timezone(),idle=self.env.idleSeconds()
            var closing=self.closedBy
            if idle>=Self.idleClose {closing=max(closing ?? .distantPast,now.addingTimeInterval(-idle+1))}
            guard let day=try? DayScope.key(now,timezone:zone),
                  let found=try? await source.discoverDay(day,now:now,timezone:zone,closedBy:closing,marks:marks) else {return}
            guard self.sourceChangeToken==token,epoch==self.modeGeneration,self.provider=="local",
                  self.source === source,self.scheduler === scheduler,!Task.isCancelled else {return}
            if self.expiryWaitsForQuiet {
                self.serviceWakeAt=nil;self.cadenceWakeAt=nil
                self.schedule(self.expiryQuietWake());return
            }
            self.sourceLastRead=self.env.now();self.counters.sourceReads+=1
            var service:Date?
            let current=self.env.now()
            if self.env.power().allowsBackground,self.holdUntil != .distantFuture {
                var cadence=[found.nextLive,found.nextFinal,self.cadenceWakeAt].compactMap {$0}
                if !found.live.isEmpty || !found.final.isEmpty {cadence.append(current.addingTimeInterval(1))}
                self.cadenceWakeAt=cadence.min()
                // Recorded load accounting is metadata only: this task never asks the runtime/provider.
                // Do not arm repeated immediate first-note work while the ordinary cold-load budget is held.
                let recent=self.loadTimes.filter {current.timeIntervalSince($0)<3600}
                let budgetAt=recent.count>=Self.loadsPerHour ? recent.min().map {$0.addingTimeInterval(3600)} : nil
                var summary=found.nextSummary
                if !found.summaryDue.isEmpty {summary=current.addingTimeInterval(1)}
                if let at=summary,let budgetAt {summary=max(at,budgetAt)}
                let dates=[summary,self.cadenceWakeAt].compactMap {$0}
                service=dates.min().map {max($0,self.holdUntil)}
            }
            // A raced newer source change can add another earlier moment. Never postpone an existing service
            // from a snapshot that predates it; the next coalesced discovery accounts for that mutation.
            if version != self.sourceChangeVersion,let old=self.serviceWakeAt {service=min(service ?? old,old)}
            self.serviceWakeAt=service
            let ordinary=self.ordinaryWakeAt ?? current.addingTimeInterval(Self.quietWake)
            self.installSchedule(min(ordinary,service ?? ordinary))
        }
    }
    private func observeSystem() {
        // fix/perf7: IOPS calls on every battery-percent or time-remaining update. Only a change the writer acts on (the
        // power source, Low Power Mode, the thermal state, the battery crossing 20%) looks again.
        var lastPower=env.power().decision
        let powerChanged:() -> Void = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {return}
                let now=self.env.power().decision
                guard now != lastPower else {return}
                lastPower=now
                self.wake(.power)
            }
        }
        powerObservation=ModelPower.Observation(powerChanged)
        let workspace=NSWorkspace.shared.notificationCenter
        let add={ (center:NotificationCenter,name:Notification.Name,reason:WakeReason) in
            let observer=center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wake(reason) }
            }
            self.systemObservers.append((center,observer))
        }
        add(workspace,NSWorkspace.willSleepNotification,.sleep)
        add(workspace,NSWorkspace.screensDidSleepNotification,.lock)
        add(workspace,NSWorkspace.didWakeNotification,.wake)
        add(DistributedNotificationCenter.default(),Notification.Name("com.apple.screenIsLocked"),.lock)
        var token:Int32=0
        if notify_register_dispatch(Self.recentRequest,&token,DispatchQueue.main,{ [weak self] _ in
            MainActor.assumeIsolated { self?.recentRequested() }
        }) == NOTIFY_STATUS_OK {recentToken=token}
    }
    /// An AI app asked (MCP): write the last hour's moments, open ones too, then say done.
    func recentRequested() {Task { [weak self] in await self?.onDemand() }}

    // MARK: turning on and off

    private func activateLocal() async throws {
        guard let files,let coreBinding,let scheduler else {throw WriterFailure.unavailable}
        let names=await Self.installedAppNames()
        expiryWaitsForQuiet=false;expiryRetryKeys.removeAll();modeGeneration+=1;let epoch=modeGeneration
        localWorkAdmission = .automatic
        await scheduler.pauseAndDrain();await levelRunner.stop();await levelRunner.reset();await cloud.disable();cloudEnabled=false
        await runtime?.unloadNow();runtime=nil;liveLease=false
        try Task.checkCancellation();guard epoch==modeGeneration else {throw CancellationError()}
        cloudCutoff=nil;await source?.setAudience(.local)
        let port=coreBinding.port()
        let typingAge=env.typingSeconds
        let shouldPause:@Sendable () -> Bool = {typingAge()<Self.typingBurst}
        let base=env.makeRuntimeWithPause?(files,shouldPause) ?? env.makeRuntime?(files) ?? LlamaInference(files:files,shouldPause:shouldPause)
        let guarded=AdmissionGuardedInference(base:base,allowed:{[weak self] in await self?.localRuntimeAllowed(epoch:epoch)==true})
        let batch=BatchRuntime(guarded,idleUnload:90,now:env.now,sleep:env.unloadSleep)
        runtime=batch;seenLoads=0
        let local=CanonicalLocalWriter(runtime:batch,policy:{ [weak self] request,actions in
            guard await self?.allows(epoch:epoch,mode:"local")==true else {return false}
            return await port.permitted(request,actions)
        },appNames:names,momentModel:env.momentModel)
        let now=env.now
        adapter=CoreWriterAdapter(core:port,generate:{try await local.generate($0,completeActions:$1,now:now())},appNames:names,localIntentSessions:true)
        levels=statusStore.map { LevelWriterBinding.local(store:$0,runtime:batch) }
        try await scheduler.setResumeLocal(true)
        guard epoch==modeGeneration else {throw CancellationError()}
        provider="local";needsAppleCheck=false;try await scheduler.start();try await scheduler.retryAll();status=Self.localResting
        setIntent(.local);resetSchedule();phase = .on(.local)
    }
    private func resetSchedule() {
        cancelSourceService()
        expiryWaitsForQuiet=false;expiryRetryKeys.removeAll()
        lastBatch = .distantPast;lastCatchUp = .distantPast;catchUpQuietUntil = .distantPast;catchUpBacklog=false;lastCodeLevels = .distantPast
        holdUntil = .distantPast;failuresInRow=0
    }
    private func allows(epoch:Int,mode:String)->Bool {epoch==modeGeneration && provider==mode}
    private func localRuntimeAllowed(epoch:Int)->Bool {
        guard epoch==modeGeneration,provider=="local" else {return false}
        let power=env.power()
        switch localWorkAdmission {
        case .automatic:return power.allowsBackground
        case .onDemand:return power.allowsOnDemand
        case .manual:return power.thermal < ProcessInfo.ThermalState.critical.rawValue
        }
    }
    /// Tells AI apps the mode (gold/notes G52). A failed save is tried again after 2, 5, 15 and 60 s, then every
    /// minute, off the main thread, until the saved value is the current one.
    private func publishProvider() {
        guard let report else {return}
        if !report.set(provider) {scheduleReportRetry()}
    }
    private func scheduleReportRetry() {
        guard reportRetry==nil,let report else {return}
        reportRetry=Task { [weak self] in
            var delays:[UInt64]=[2,5,15,60]
            while !Task.isCancelled {
                let delay=delays.isEmpty ? 60 : delays.removeFirst()
                do {try await Task.sleep(nanoseconds:delay*1_000_000_000)} catch {break}
                if await Task.detached(priority:.utility,operation:{report.retry()}).value {break}
            }
            self?.reportRetry=nil
        }
    }
    /// Entries only an explicit Retry moves on: the count the Retry button shows.
    static func waiting(_ states:[ScheduledWriterState]) -> Int {states.filter{$0.status == .pending || $0.status == .cancelled}.count}
    /// Installed apps' display names from bundle metadata, so the writer sees "Pages", not com.apple.iWork.Pages.
    /// The writer and the adapter get the same map: the adapter's final check rebuilds the writer's ITEMS view.
    private static func installedAppNames() async -> [String:String] {
        await Task.detached(priority:.utility) {Dictionary(LocalApp.catalog().map {($0.id,$0.name)},uniquingKeysWith:{first,_ in first})}.value
    }

    /// fix/sx-engine-battery: On this Mac, in one call: download the model if it isn't here (resuming a partial file),
    /// check it, and turn summaries on. The choice is saved first, so closing every window or quitting mid-download
    /// still ends with summaries on this Mac turned on.
    func chooseLocal() {
        guard localOffered else {
            status=DaydreamSetupText.localUnavailable;return
        }
        guard scheduler != nil,setup == nil,!switching else {return}
        if provider=="local",case .on(.local)=phase {return}
        setIntent(.local)
        busy=true
        setup=Task { [weak self] in
            await self?.runLocalSetup()
            self?.setup=nil
        }
    }
    enum Stage {case download,check,load}
    /// `download` false (Turn on, for a model already here): checks and loads only; it never downloads.
    private func runLocalSetup(download:Bool=true) async {
        busy=true
        // Summaries turned off a moment ago finish stopping first (one model, nothing stranded).
        _ = await stopping?.value
        switching=true
        let epoch=modeGeneration
        defer {switching=false;busy=false;progress=nil;downloadAttempt=nil;resumeDeferred()}
        var stage=Stage.check
        do {
            if files == nil {
                if Self.appLocationBlocksRuntime {throw WriterFailure.denied}
                if download && !Self.modelFilePresent(PersistentModelCache.searchRoots(for:modelRoot)) {
                    stage = .download
                    let attempt=UUID();downloadAttempt=attempt;lastDownloadEventTime=0;lastPublished=(0,0)
                    downloadEstimate.begin()
                    phase = .downloading(received:0,total:WriterCandidates.recommended?.asset.bytes ?? 0)
                    env.defaults.set(true,forKey:Self.downloadingKey)
                    let installed:CompatibleWriterFiles?
                    do {
                        installed=try await admission.download(modelRoot) { state in
                            let time=ProcessInfo.processInfo.systemUptime
                            Task { @MainActor [weak self] in self?.receiveDownload(state,attempt:attempt,at:time) }
                        }
                    } catch {
                        // Cancelled (Off, or a quit) keeps the mark: a relaunch with On still saved finishes it.
                        // fix/model-download: so does a download that stopped. It already kept trying by itself; a
                        // relaunch tries once more from the partial file instead of saying the model couldn't start.
                        throw error
                    }
                    env.defaults.removeObject(forKey:Self.downloadingKey)
                    try Task.checkCancellation();guard epoch==modeGeneration else {throw CancellationError()}
                    // The hash matched: the model is on this Mac, whatever the Apple check says next.
                    modelOnMac=true;downloadAttempt=nil;downloadEstimate.complete();progress=nil
                    if let installed {files=installed}
                }
                stage = .check
                phase = .checking;status="Checking the model"
                if files == nil {files=try await restoreForExplicitSetup()}
                try Task.checkCancellation();guard epoch==modeGeneration else {throw CancellationError()}
                ready=true;modelOnMac=true
            }
            stage = .load
            phase = .checking
            try await activateLocal();startPolling()
        } catch {
            if Task.isCancelled || error is CancellationError || epoch != modeGeneration {
                if downloadAttempt != nil {downloadEstimate.cancel()}
                return
            }
            if stage == .download {downloadEstimate.fail()}
            if case WriterFailure.trustEvidenceUnavailable = error {needsAppleCheck=true}
            ready = files != nil
            status=setupFailureStatus(error)
            phase = .failed(Self.problem(error,stage:stage))
        }
    }
    /// Download progress, at most once a second or every 0.1 GB (fix/sx-engine-battery).
    private func receiveDownload(_ state:InstallState,attempt:UUID,at time:TimeInterval) {
        guard downloadAttempt==attempt,time>=lastDownloadEventTime else {return}
        lastDownloadEventTime=time
        switch state {
        case .downloading(let received,let total):
            let done=total>0 && received>=total
            guard done || time-lastPublished.time>=1 || received-lastPublished.bytes>=100_000_000 || lastPublished.time==0 else {return}
            lastPublished=(time,received)
            progress=total>0 ? min(max(Double(received)/Double(total),0),1) : nil
            downloadEstimate.record(received:received,total:total,at:time)
            phase = .downloading(received:received,total:total)
            if done {status="Checking the download"}
            else if total==WriterCandidates.recommended?.asset.bytes {status="Downloading the model"}
            else if total==WriterCandidates.llamaARM64.bytes {status="Downloading the runtime"}
            else {status="Downloading"}
        case .ready:
            progress=nil;downloadEstimate.verifying();status="Checking the model";phase = .checking
        case .failed: progress=nil;downloadEstimate.fail()
        case .cancelled: progress=nil;downloadEstimate.cancel()
        case .idle: break
        }
    }
    /// Earlier entry points, kept for callers: Download is On this Mac in one call now.
    func install() {chooseLocal()}
    func useLocal() async throws {
        if provider=="local",case .on(.local)=phase {return}
        guard !switching,setup == nil,scheduler != nil else {throw WriterFailure.busy}
        guard localOffered else {status=DaydreamSetupText.localUnavailable;throw WriterFailure.unavailable}
        setIntent(.local)
        let task=Task { await runLocalSetup(download:false) }
        setup=task
        await task.value
        setup=nil
        if case .failed=phase {throw WriterFailure.unavailable}
    }
    /// Stop (Cancel): the same as turning summaries off.
    func cancel() {turnOff()}

    /// fix/sx-engine-battery: Off at once. The phase is `.off` before this returns; the note being written, the level
    /// note and a download stop, the model is unloaded, and nothing queued is marked cancelled (it runs when a writer
    /// is turned on again).
    func turnOff() {
        cancelSourceService()
        setIntent(.off)
        if downloadAttempt != nil {downloadAttempt=nil;downloadEstimate.cancel()}
        progress=nil;busy=false
        trustSetup?.cancel();setup?.cancel();setup=nil
        processing?.cancel()
        expiryWaitsForQuiet=false;expiryRetryKeys.removeAll();modeGeneration+=1;provider="off";cloudEnabled=false;needsAppleCheck=false
        adapter=nil;levels=nil
        phase = .off
        schedule(nil)
        let previous=stopping
        stopping=Task { [weak self] in
            _ = await previous?.value
            guard let self else {return true}
            let stopped=await self.stopProvider()
            if !stopped {self.status="Stopped, but DayDream couldn't save that. It may turn back on after a restart."}
            return stopped
        }
    }
    /// fix/sx-engine-battery: Cloud with OpenRouter, in one call. The key is tried with ONE tiny request first (same
    /// model and host rules, one output token, a fixed prompt with nothing from your history); only a key that works is
    /// saved and turns cloud summaries on. Returns what went wrong, or nil when cloud summaries are on.
    func chooseCloud(key:String) async -> SummaryProblem? {
        var value=key.trimmingCharacters(in:.whitespacesAndNewlines)
        let pasted = !value.isEmpty
        // fix/sx-all: an empty field (the Settings switch) tries the saved key; with none saved, the key field is the
        // question: nothing is sent and the state doesn't change.
        if !pasted {
            guard let saved=await cloud.savedKeyForExplicitUse() else {return .cloudKey}
            value=saved
        }
        if let failure=await CloudWriter.probe(key:value,send:cloudSend) {
            let problem=Self.problem(failure)
            if provider=="off" {phase = .failed(problem)}
            return problem
        }
        // fix/sx-all round 1: a model download or setup for this Mac still running stops first (the choice is now the
        // key). Before, saving the key found the writer switching, threw, and the key was dropped with no word.
        if setup != nil || switching {
            let running=setup
            turnOff()
            await running?.value
            _ = await stopping?.value
            for _ in 0..<100 where switching {try? await Task.sleep(nanoseconds:20_000_000)}
        }
        let before=phase
        await stopLocalSetup()
        phase = .checking
        do {
            if pasted {try await saveCloudKey(value)}
            try await enableCloud(acceptedDisclosureVersion:Self.cloudDisclosureVersion)
            return nil
        } catch {
            // A real problem, never a silent nil: the switch would say on while nothing was saved.
            let problem:SummaryProblem = (error as? CloudFailure).map {Self.problem($0)} ?? .cloudOffline
            if case .on=before {phase=before} else {phase = .failed(problem)}
            return problem
        }
    }
    /// fix/bugs7: OpenRouter chosen while summaries on this Mac are still downloading or being checked: that setup stops
    /// first (one state at a time). Otherwise saving the key and turning cloud on were refused as busy, nothing said so
    /// (the switch just went back off), and the download still turned summaries on this Mac on once it finished.
    private func stopLocalSetup() async {
        guard let running=setup else {return}
        setup=nil;running.cancel()
        if downloadAttempt != nil {downloadAttempt=nil;downloadEstimate.cancel()}
        _ = await running.value
    }
    /// The one fixing button (Try Again, Change Key's retest, Add Credits' retest).
    func retry() {
        switch phase {
        case .failed(let problem):
            switch problem {
            case .cloudKey,.cloudCredits,.cloudHost,.cloudOffline:
                Task { [weak self] in await self?.retestCloud() }
            default:
                // fix/sx-all round 2: Try Again forgets the loads that failed before (the switch no longer snaps back to
                // the same line at the next pass); only a new failed load says it again. On battery the model is tried
                // once the Mac is plugged in, and the row says so.
                if provider=="local" {
                    phase = .on(.local);retryWaitsForPower = !env.power().allowsBackground
                    let runtime=self.runtime
                    Task { [weak self] in
                        await runtime?.resetFailedLoads()
                        self?.tryAgainNow()
                    }
                }
                else {chooseLocal()}
            }
        default:
            if provider != "off" {tryAgainNow()}
        }
    }
    /// Try Again ends the writer-wide back-off: the moments it held are due now, and a pass runs.
    private func tryAgainNow() {
        holdUntil = .distantPast;failuresInRow=0
        Task { [weak self] in
            await self?.releaseHold()
            self?.wake(.explicit)
        }
    }
    private func releaseHold() async {
        guard let scheduler else {return}
        for key in await scheduler.waitingKeys() {try? await scheduler.retry(key:key)}
    }
    private func retestCloud() async {
        guard provider=="cloud" else {
            if intent == .cloud {await resumeCloud()}
            return
        }
        let key:String
        do {key=try await cloud.bindings().key()} catch {phase = .failed(.cloudKey);return}
        if let failure=await CloudWriter.probe(key:key,send:cloudSend) {phase = .failed(Self.problem(failure));return}
        holdUntil = .distantPast;failuresInRow=0;phase = .on(.cloud)
        try? await scheduler?.retryAll();await releaseHold()
        wake(.explicit)
    }

    /// Plain problem for each failure (fix/sx-engine-battery: every setup failure maps to one line and one button).
    static func problem(_ error:Error,stage:Stage) -> SummaryProblem {
        if error is DownloadDamaged {return .badDownload}
        switch error {
        // fix/sx-all round 1: too little memory has its own line and button (use a key instead); Try Again can't fix it.
        case WriterFailure.capacity:return Self.enoughMemory ? .noSpace : .noMemory
        case WriterFailure.trustEvidenceUnavailable:return .appleCheck
        // The signed runtime refuses this app folder (SignedRuntimeLoader.safePath): moving DayDream fixes it, Try Again can't.
        case WriterFailure.denied where Self.appLocationBlocksRuntime:return .moveApp
        case WriterFailure.integrity:return stage == .download ? .badDownload : .modelWontStart
        default:return stage == .download ? .downloadStopped : .modelWontStart
        }
    }
    static func problem(_ failure:CloudFailure) -> SummaryProblem {
        switch failure {
        case .key:return .cloudKey
        case .credits:return .cloudCredits
        case .host:return .cloudHost
        case .offline:return .cloudOffline
        }
    }
    /// Every line `setupFailureStatus` can say, and the problem it goes with (checked: none is left unmapped).
    static var enoughMemory:Bool {ProcessInfo.processInfo.physicalMemory>=(WriterCandidates.recommended?.minimumMemory ?? 8_589_934_592)}
    static let setupFailureLines:[(line:String,problem:SummaryProblem)]=[
        ("Another setup is using the model. Try again when it finishes.",.modelWontStart),
        ("A file for summaries on this Mac didn't pass its check. Nothing was deleted.",.badDownload),
        ("This Mac needs about 2.8 GB of free space for the model.",.noSpace),
        (appleCheckLine,.appleCheck),
        ("Summaries on this Mac need 8 GB of memory.",.noMemory),
        ("The download was damaged. Try Again downloads it from the start.",.badDownload),
        ("Summaries on this Mac couldn't start. Everything else still works.",.modelWontStart),
        (SummaryProblem.moveApp.line,.moveApp),
    ]
    /// A signed build in a folder its runtime won't load from (an external drive with a group-writable root, a translocated
    /// or disk-image copy). Checked before a download too: 2.7 GB would download and still never start.
    static var appLocationBlocksRuntime:Bool {
        (try? WriterRuntimeAdmission.requiresSignedDistribution()) == true && !SignedRuntimeLoader.appLocationAllowed()
    }
    static func problem(forStatus line:String) -> SummaryProblem? {setupFailureLines.first {$0.line == line}?.problem}
    func setupFailureStatus(_ error: Error) -> String {
        if error is DownloadDamaged {return Self.setupFailureLines[5].line}
        if case WriterFailure.busy = error {return Self.setupFailureLines[0].line}
        if case WriterFailure.integrity = error {return Self.setupFailureLines[1].line}
        if case WriterFailure.capacity = error {return Self.enoughMemory ? Self.setupFailureLines[2].line : Self.setupFailureLines[4].line}
        if case WriterFailure.trustEvidenceUnavailable = error {return Self.appleCheckLine}
        if case WriterFailure.denied = error, Self.appLocationBlocksRuntime {return Self.setupFailureLines[7].line}
        return Self.setupFailureLines[6].line
    }
    /// Only clicks (Download, Turn on, setup's Continue) enter this path; configure never does, except to finish a
    /// download the person started.
    /// This is the one place DayDream asks Apple about its certificate.
    private func restoreForExplicitSetup() async throws -> CompatibleWriterFiles {
        do { return try await admission.restoreOffline(modelRoot,runtimeRevocationResponses) }
        catch WriterFailure.trustEvidenceUnavailable {
            try Task.checkCancellation()
            guard try admission.signedBuild() else {throw WriterFailure.trustEvidenceUnavailable}
            status=RuntimeTrustProvisioning.disclosure
            let check=admission.checkWithApple
            let task=Task {try await check()}
            trustSetup=task;defer{trustSetup=nil}
            do {try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})}
            catch is CancellationError {throw CancellationError()}
            // Apple couldn't be asked (offline, or the answer didn't check out): the one Apple-check line and Try Again.
            catch {try Task.checkCancellation();throw WriterFailure.trustEvidenceUnavailable}
            try Task.checkCancellation()
            // No network permission reaches loader. Recheck everything offline.
            return try await admission.restoreOffline(modelRoot,runtimeRevocationResponses)
        }
    }
    /// Key paste never enables cloud and is never persisted in settings JSON.
    func saveCloudKey(_ value:String) async throws {
        _ = await stopping?.value
        guard !switching else {throw WriterFailure.busy};switching=true;defer{switching=false;resumeDeferred()}
        guard await stopProvider() else {throw WriterFailure.integrity}
        try await cloud.pasteKey(value);status="Key saved securely. Cloud remains off until you accept the disclosure and enable it."
    }
    /// `resuming`: turning the saved switch back on at launch (`resumeCloud`). Nothing runs then, and a failure (the key
    /// unreadable for a moment, a locked Keychain) must not clear the switch for every later launch (claude/recall-1004).
    func enableCloud(acceptedDisclosureVersion:Int,resuming:Bool=false) async throws {
        _ = await stopping?.value
        guard !switching,let source,let coreBinding,let scheduler else {throw WriterFailure.unavailable}
        switching=true;defer{switching=false;resumeDeferred()}
        // fix/sx-engine-battery: turning cloud back on (relaunch, privacy change) keeps the first activation's cutoff.
        let since=await scheduler.resumeCloudCutoff()
        guard await stopProvider(persistStop:!resuming) else {throw WriterFailure.integrity}
        let names=await Self.installedAppNames()
        let operationEpoch=modeGeneration
        let revision=try await source.policyRevision()
        try await cloud.enable(acceptedDisclosureVersion:acceptedDisclosureVersion,currentPolicyRevision:revision,since:since)
        guard operationEpoch==modeGeneration,!Task.isCancelled else {await cloud.disable();throw CancellationError()}
        // gold/notes G52: AI apps are told cloud is on before anything can be sent. If that can't be saved, it stays off.
        guard report?.set("cloud") == true else {
            await cloud.disable();publishProvider()
            status=Self.cloudNotRecorded;throw WriterFailure.unavailable
        }
        do {
            // gold/notes G25: everything queued before is found again under the cloud's rules.
            try await scheduler.discardAll();pendingCount=0
            policyRevision=revision;expiryWaitsForQuiet=false;expiryRetryKeys.removeAll();modeGeneration+=1;let epoch=modeGeneration
            let cutoff=await cloud.activeCutoff();cloudCutoff=cutoff
            await source.setAudience(.cloud,cutoff:cutoff)
            let bindings=await cloud.bindings(),port=coreBinding.port(audience:.cloud)
            let remote=CanonicalCloudWriter(consent:bindings.consent,key:bindings.key,policy:{[weak self] request,actions in
                guard await self?.allows(epoch:epoch,mode:"cloud")==true,await bindings.permits(request,actions) else {return false}
                return await port.permitted(request,actions)
            },send:cloudSend,appNames:names,momentModel:env.momentModel)
            adapter=CoreWriterAdapter(core:port,generate:{try await remote.generate($0,completeActions:$1)},appNames:names)
            // fix/sx-engine-battery: level notes are written by the cloud model too (only periods that start after the
            // cutoff; code writes the rest, and whatever the cloud can't).
            let writer=CloudWriter(consent:bindings.consent,key:bindings.key,policy:{_ in false},send:cloudSend)
            levels=statusStore.map { store in
                LevelWriterBinding.cloud(store:store,model:CloudWriter.model,
                    permits:{ request in
                        // fix/sx-all round 1: what the cloud would read starts after the cutoff (a day's main thread).
                        guard let cutoff,let start=timestamp(LevelGrounding.evidenceStart(request)) else {return false}
                        return start > cutoff
                    },
                    complete:{ [weak self] instruction,evidence,maxTokens in
                        let owner=self
                        return try await writer.completeText(instruction:instruction,evidence:evidence,maxTokens:maxTokens,
                                                             permitted:{ await owner?.allows(epoch:epoch,mode:"cloud")==true })
                    })
            }
            await levelRunner.reset()
            try await scheduler.start()
            // summaries/v3 (owner 9/28): the switch stays on across relaunches, for this notice version only, with the
            // cutoff of its first activation (fix/sx-engine-battery).
            try await scheduler.setResumeCloud(acceptedDisclosureVersion,cutoff:cutoff)
        } catch {
            await stopProvider(persistStop:false);publishProvider()
            throw error
        }
        provider="cloud";cloudEnabled=true;setIntent(.cloud);resetSchedule();phase = .on(.cloud);startPolling()
        status=Self.cloudResting
    }
    @discardableResult private func stopProvider(persistStop:Bool=true) async -> Bool {
        cancelSourceService()
        trustSetup?.cancel()
        expiryWaitsForQuiet=false;expiryRetryKeys.removeAll();modeGeneration+=1;provider="off";cloudEnabled=false
        if persistStop {needsAppleCheck=false}
        // fix/r1-writer: a level note being written stops too, and is waited for, so nothing more is saved and its model
        // copy is gone before a writer can be turned on again.
        processing?.cancel();await levelRunner.stop();await cloud.disable();await scheduler?.pauseAndDrain();adapter=nil;levels=nil
        await runtime?.unloadNow();runtime=nil;liveLease=false
        schedule(nil)
        cloudCutoff=nil;await source?.setAudience(.local)
        if persistStop {
            do {try await scheduler?.setResumeLocal(false);try await scheduler?.setResumeCloud(nil)}
            catch {status="Writer stopped here, but saving the stopped state failed.";return false}
        }
        return true
    }
    /// App termination hook. Crash recovery also treats running ledger entries
    /// as pending; it never assumes a note was committed from provider success.
    func shutdown() async {
        trustSetup?.cancel()
        schedule(nil)
        let loading=work,local=setup
        loading?.cancel();local?.cancel()
        await stopProvider(persistStop:false)
        _ = await loading?.result
        _ = await local?.value
        _ = await stopping?.value
        powerObservation=nil
        for (center,observer) in systemObservers {center.removeObserver(observer)}
        systemObservers=[]
        if recentToken >= 0 {notify_cancel(recentToken);recentToken = -1}
        // A quit: let go of the queue, which releases its ledger lock for the next launch.
        adapter=nil;source=nil;scheduler=nil
    }
    /// summaries/v3 (owner 9/28): turns cloud summaries back on after a relaunch or a privacy change, while the switch
    /// was left on with the current notice version (`setResumeCloud`). A version bump resets the switch to off; nothing
    /// asks. Reads the saved key only here, through `CloudActivation.enable`, as turning the switch on does.
    func resumeCloud() async {
        guard let scheduler,provider=="off",!switching,let version=await scheduler.resumeCloudPreference() else {return}
        guard version==Self.cloudDisclosureVersion else {try? await scheduler.setResumeCloud(nil);return}
        do {try await enableCloud(acceptedDisclosureVersion:version,resuming:true)}
        catch {status=Self.cloudNotResumed}
    }
    static let cloudNotResumed="Cloud summaries couldn't turn back on. Turn them on again in Settings."
    func disableCloud() async {
        turnOff()
        if await stopping?.value == true {status="Automatic notes off. No fallback provider enabled."}
    }
    func deleteCloudKey() async throws {guard await stopProvider() else {throw WriterFailure.integrity};setIntent(.off);phase = .off;try await cloud.deleteKey();status="Cloud key deleted; cloud off."}
    func retryPending() async throws {
        guard provider != "off",let scheduler else {throw WriterFailure.unavailable}
        try await scheduler.retryAll();await releaseHold();try await scheduler.start();pendingCount=Self.waiting(await scheduler.snapshot())
        holdUntil = .distantPast;failuresInRow=0
        await pass(.explicit)
    }

    /// Hold already-loaded local weights during continuous eligible activity, without loading or generating.
    /// Both timer and MCP discovery use this path. Every suspended operation owns only its captured runtime;
    /// a stop, replacement, or intervening release must not install its lease on the new provider.
    @discardableResult private func reconcileWarmLease(writableOpen:Bool,epoch:Int,mode:String) async -> Bool {
        guard epoch==modeGeneration,provider==mode else {return false}
        warmLeaseRevision+=1
        let revision=warmLeaseRevision
        let eligible=mode=="local" && writableOpen && env.power().allowsBackground && env.idleSeconds()<Self.idleClose
        guard let captured=runtime else {liveLease=false;return !eligible}
        if !eligible {
            if liveLease {
                liveLease=false // Clear before suspension: never clear a replacement runtime's lease afterwards.
                await captured.endBatch()
            }
            return epoch==modeGeneration && provider==mode && runtime === captured && !Task.isCancelled
        }
        if liveLease {return !Task.isCancelled}
        await captured.beginBatch() // May unload an overdue model; it never loads or generates one.
        guard epoch==modeGeneration,provider==mode,runtime === captured,warmLeaseRevision==revision,
              env.power().allowsBackground,env.idleSeconds()<Self.idleClose,!Task.isCancelled else {
            await captured.endBatch() // Balance this acquire, even if unloadNow already reset the old runtime.
            return false
        }
        liveLease=true
        return true
    }

    /// Typing expiry waits may release an existing lease, never acquire/load/generate.
    /// One policy revision read only while a lease exists; no target scan or discovery.
    private func releaseExpiredWaitLease(source:WriterQueueSource,epoch:Int,mode:String) async -> Bool {
        guard epoch==modeGeneration,provider==mode,!Task.isCancelled else {return false}
        let captured=runtime
        var release = !env.power().allowsBackground || env.idleSeconds()>=Self.idleClose
        if liveLease,!release {
            let revision=try? await source.policyRevision()
            guard epoch==modeGeneration,provider==mode,runtime === captured,!Task.isCancelled else {return false}
            release = !env.power().allowsBackground || env.idleSeconds()>=Self.idleClose || revision == nil || revision != policyRevision
        }
        if release {
            guard await reconcileWarmLease(writableOpen:false,epoch:epoch,mode:mode) else {return false}
        }
        return epoch==modeGeneration && provider==mode && runtime === captured && !Task.isCancelled
    }

    // MARK: the pass

    /// One pass: drop obsolete entries, find today's closed moments, and when a batch is due write them with one model
    /// load, then catch up past days and write the level notes that are due, then let the model go. Returns true when
    /// a note ran. Sets the one timer (`nextWake`).
    enum TickResult {case ran,idle,busy}
    /// fix/sx-all round 2: moments code writes whole (nothing typed, sent or on screen: a window read, a call, a pull
    /// request, a terminal command) get their code note while no model is on too (summaries off, the model still
    /// downloading, the cloud switch before its key): a row says "Texts with Mom" or "PR #212: ..." instead of only a
    /// duration. Nothing is loaded or sent; a moment that needs a model waits for one. Each moment revision is tried once.
    static let codePassNotes=20,codePassEvery:TimeInterval=15*60
    private var codeTried=Set<String>()
    private var lastCodePass=Date.distantPast
    private func codePass(now:Date) async {
        guard provider=="off",!switching,processing==nil,!writing,let source,let coreBinding,now.timeIntervalSince(lastCodePass)>=60 else {return}
        lastCodePass=now
        let zone=env.timezone()
        guard let day=try? DayScope.key(now,timezone:zone),
              let found=try? await source.discoverDay(day,now:now,timezone:zone,closedBy:closedBy,marks:[:]) else {return}
        if codeTried.count>5000 {codeTried.removeAll()}
        let names=await Self.installedAppNames()
        let adapter=CoreWriterAdapter(core:coreBinding.port(),generate:{request,actions in
            let view=try ModelView(request:request,actions:actions,appNames:names)
            guard CanonicalGrounding.codeWrites(view) else {throw WriterFailure.notSent}
            guard let note=try? CanonicalGrounding.check(CanonicalGrounding.codeNote(request,view:view),request:request,view:view) else {throw WriterFailure.invalidOutput}
            return note
        },appNames:names)
        var ran=0,committed=Set<NoteCommitScope>()
        defer { publishCommitted(committed) }
        for item in found.targets where ran<Self.codePassNotes {
            guard provider=="off",!switching,codeTried.insert(item.key+"|"+item.inputRevision).inserted else {continue}
            ran+=1
            if case .committed? = try? await adapter.process(item.target,lastActivity:item.lastActivity,now:now) {
                counters.codeNotes+=1;counters.committedNotes+=1;onNoteRun?(item)
                committed.insert(NoteCommitScope(day:item.day,timezone:item.timezone))
            }
        }
    }
    @discardableResult private func tick(reason:WakeReason = .explicit) async -> TickResult {
        // perf2-1005 (owner 10/04): nothing reads the history or writes a note while DayDream opens or the person types
        // (the store's one connection is shared with every capture save); the writer looks again once it is quiet.
        let quiet=env.quietFor()
        if quiet>0 {
            counters.quietDeferrals+=1
            installSchedule(env.now().addingTimeInterval(quiet+0.5));return .idle
        }
        if provider=="off",!cycleRunning {
            cycleRunning=true
            await codePass(now:env.now())
            cycleRunning=false
            schedule(scheduler != nil && source != nil ? env.now().addingTimeInterval(Self.codePassEvery) : nil)
            return .idle
        }
        guard provider != "off",let scheduler,let source,adapter != nil else {schedule(nil);if queue != nil {queue=nil};return .idle}
        guard !switching,!cycleRunning,processing==nil,!writing,clicksWaiting==0 else {rerun=reason;return .busy}
        cycleRunning=true
        defer{cycleRunning=false}
        let epoch=modeGeneration,mode=provider
        if mode=="local",expiryWaitsForQuiet {
            guard await releaseExpiredWaitLease(source:source,epoch:epoch,mode:mode) else {return .idle}
            guard env.typingSeconds()>=Self.typingBurst else {schedule(expiryQuietWake());return .idle}
            expiryWaitsForQuiet=false
        }
        let priorAdmission=localWorkAdmission;localWorkAdmission = .automatic
        defer {if epoch==modeGeneration {localWorkAdmission=priorAdmission}}
        let now=env.now(),zone=env.timezone()
        var power=env.power(),idle=env.idleSeconds()
        if retryWaitsForPower && (power.allowsBackground || mode != "local") {retryWaitsForPower=false}
        // fix/battery-summaries: on battery too, unless Low Power Mode, under 20% or hot (ModelPower.allowsBackground).
        let previousBackground=wasBackground
        var background=mode=="cloud" || power.allowsBackground
        var resumed=previousBackground == false && background
        wasBackground=background
        func refreshBackgroundDecision() {
            power=env.power();idle=env.idleSeconds()
            background=mode=="cloud" || power.allowsBackground
            resumed=previousBackground == false && background;wasBackground=background
        }
        do {
            let revision=try await source.policyRevision()
            if revision != policyRevision {
                policyRevision=revision
                // fix/r1-writer: the settings changed, so a model that kept failing is tried again at once.
                await levelRunner.reset()
                // summaries/v3 (owner 9/28): a privacy change no longer turns the switch off. Cloud stops (nothing prepared
                // under the old settings is ever sent: its bindings and queue go) and turns on again under the new
                // settings, with the same cutoff, as the switch still says. Notes already written stay (gold/notes G21).
                if provider=="cloud" {
                    await stopProvider(persistStop:false)
                    Task { [weak self] in await self?.resumeCloud() }
                    return .idle
                }
                // Local policy is checked at every generation/commit as well.
            }
            // A ledger save that failed stops the queue. Once saving works again it starts again (gold/notes).
            if await !scheduler.started {try await scheduler.start()}
            let existing=await scheduler.snapshot()
            if !existing.isEmpty {
                let start=sweepOffset%existing.count
                let ordered=Array(existing[start...])+Array(existing[..<start])
                for key in try await source.obsoleteKeys(Array(ordered.prefix(4)).map(\.item),now:now) {try await scheduler.discard(key:key)}
                sweepOffset=start+4
            }
            // Moments close after 10 minutes (2 once a later one exists), or when the Mac locks, sleeps or idles 5 minutes.
            var closing=closedBy
            if idle >= Self.idleClose {closing=max(closing ?? .distantPast,now.addingTimeInterval(-idle+1))}
            let today=try DayScope.key(now,timezone:zone)
            if !env.pastDayNotes {
                for state in await scheduler.snapshot() where state.item.day != today && state.status != .running && state.status != .completed {
                    try await scheduler.discard(key:state.item.key);counters.pastSetAside+=1
                }
            }
            let marks=await scheduler.writtenMarks()
            let found=try await source.discoverDay(today,now:now,timezone:zone,closedBy:closing,marks:marks)
            // Short open moments share the same lease as mature ones. Discovery alone never loads a model;
            // idle, power holds and closure let the existing 90-second unload grace start.
            guard await reconcileWarmLease(writableOpen:found.keepLocalWarm,epoch:epoch,mode:mode) else {
                // The fired timer has already been consumed. A same-provider eligibility change during acquire
                // needs a fresh power/idle discovery; an old provider must never rearm the replacement's timer.
                if epoch==modeGeneration,provider==mode,!Task.isCancelled {lookAgainSoon()}
                return .idle
            }
            refreshBackgroundDecision() // Discovery and lease balancing can suspend across a power transition.
            for (item,mark) in found.skipped {try await scheduler.setWritten(key:item.key,mark)}
            var willNotWrite=found.willNotWrite
            lastOpen=Set(found.open.compactMap(\.activityID));lastLook=now;lastWait=mode == "local" ? Self.wait(power) : nil
            var full=false
            let cadenceKeys=Set(found.live.map(\.key)).union(found.final)
            let openKeys=Set(found.open.map(\.key))
            let summaryKeys=Set(found.summaryDue.map(\.key))
            let liveKeys=Set(found.live.map(\.key)).union(summaryKeys.intersection(openKeys))
            let forcedKeys=liveKeys.union(found.final).union(summaryKeys)
            let routedKeys=Set((found.targets+found.live).map(\.key))
            let discovered=found.targets+found.live+found.summaryDue.filter {!routedKeys.contains($0.key)}
            let ordered=discovered.filter {cadenceKeys.contains($0.key)} +
                discovered.filter {forcedKeys.contains($0.key) && !cadenceKeys.contains($0.key)} +
                discovered.filter {!forcedKeys.contains($0.key)}
            for item in ordered {
                do {
                    try await Self.enqueueToday(item,scheduler:scheduler,today:today,priority:forcedKeys.contains(item.key),protected:cadenceKeys)
                    if forcedKeys.contains(item.key) {try await scheduler.retry(key:item.key)}
                } catch WriterFailure.capacity {full=true;break}
            }
            guard epoch==modeGeneration,provider != "off",!Task.isCancelled else {return .idle}
            let held=now<holdUntil
            // Today's moments already queued (Summarize Now, or one a back-off held) run with the batch, closed or not.
            let queuedStates=await scheduler.snapshot()
            let overdueAt = mode == "local" ? Self.overdueDeadline(queuedStates,day:today) : nil
            let overdue = overdueAt.map {now >= $0} ?? false
            let queuedToday=queuedStates.filter {($0.status == .queued || $0.status == .retry) && $0.item.day==today}.map(\.item.key)
            let keys=Set(found.targets.map(\.key)).union(liveKeys).union(summaryKeys).union(queuedToday)
            let eventCloses=reason == .lock || reason == .sleep || reason == .wake
            let budget:(ok:Bool,at:Date?)=mode == "local" ? await loadAllowed(now) : (true,nil)
            refreshBackgroundDecision() // loadAllowed reads actor state; never use a pre-await power gate.
            let forcedDue = mode == "local" && !forcedKeys.isEmpty
            // Only the original live/final cadence may bypass the existing hourly cold-load limit.
            // New first-note service priority bypasses ordinary batch spacing, never the load budget.
            let cadenceDue = mode == "local" && !cadenceKeys.isEmpty
            let expiryKeys = mode == "local" ? keys.intersection(expiryRetryKeys) : []
            expiryRetryKeys.formIntersection(keys) // Removed/obsolete targets cannot retain an expiry retry.
            let expiryDue = !expiryKeys.isEmpty
            let batchDue = !keys.isEmpty && background && !held && (budget.ok || cadenceDue) &&
                (forcedDue || expiryDue || overdue || idle>=Self.idleClose || eventCloses || resumed || reason == .explicit || failuresInRow>0 || now.timeIntervalSince(lastBatch)>=Self.batchEvery)
            var outcome:ScheduledWriterOutcome?,ranNotes=0,failed:SummaryProblem??=nil
            var batchOpen=false
            var batchRuntime:BatchRuntime?
            func openBatch() async -> Bool {
                guard epoch==modeGeneration,provider==mode,!Task.isCancelled,
                      mode != "local" || env.power().allowsBackground else {return false}
                if batchOpen {return true}
                let captured=runtime
                await captured?.beginBatch()
                guard epoch==modeGeneration,provider==mode,runtime === captured,!Task.isCancelled,
                      mode != "local" || env.power().allowsBackground else {
                    await captured?.endBatch();return false
                }
                batchRuntime=captured;batchOpen=true;counters.batches+=1;lastBatch=now
                return true
            }
            defer {if batchOpen {let captured=batchRuntime;Task {await captured?.endBatch()}}}
            if batchDue,await openBatch() {
                var processedExpiryKeys=Set<String>()
                if expiryDue,budget.ok {
                    let run=await runNotes(only:expiryKeys,limit:Self.batchNotes,newestFirst:false,provisional:liveKeys,written:expiryKeys.intersection(forcedKeys),active:liveKeys,closing:found.final,mode:mode,epoch:epoch,automatic:true)
                    outcome=run.outcome;ranNotes+=run.ran;failed=run.failure
                    processedExpiryKeys=expiryKeys
                }
                let permittedPriorityKeys=budget.ok ? forcedKeys : cadenceKeys
                let remainingForced=permittedPriorityKeys.subtracting(processedExpiryKeys)
                if !remainingForced.isEmpty,failed == nil,!expiryWaitsForQuiet,ranNotes<Self.batchNotes {
                    let run=await runNotes(only:remainingForced,limit:Self.batchNotes-ranNotes,newestFirst:false,provisional:liveKeys,written:remainingForced,active:liveKeys,closing:found.final,mode:mode,epoch:epoch,automatic:true)
                    outcome=run.outcome;ranNotes+=run.ran;failed=run.failure
                }
                if failed == nil,budget.ok,ranNotes<Self.batchNotes {
                    let run=await runNotes(only:keys.subtracting(forcedKeys).subtracting(expiryKeys).subtracting(found.rewriteKeys),limit:Self.batchNotes-ranNotes,newestFirst:false,provisional:[],mode:mode,epoch:epoch,automatic:true)
                    if run.outcome != nil {outcome=run.outcome}
                    ranNotes+=run.ran;failed=run.failure
                }
                // claude/ready-1002 (owner): notes an earlier writer wrote, rewritten after new moments, newest first, and
                // only while the person isn't typing (the model also pauses mid-answer on a keystroke).
                let rewriteKeys=found.rewriteKeys.subtracting(forcedKeys).subtracting(expiryKeys)
                if failed == nil,budget.ok,ranNotes<Self.batchNotes,!rewriteKeys.isEmpty {
                    let run=await runNotes(only:rewriteKeys,limit:Self.batchNotes-ranNotes,newestFirst:true,provisional:[],mode:mode,epoch:epoch,automatic:true,quietOnly:true)
                    if run.outcome != nil {outcome=run.outcome}
                    ranNotes+=run.ran;failed=run.failure
                }
            }
            // Catch-up (whenever background work may run): the past 7 days, newest first, 10 notes a batch.
            // claude/catchup-1003 (owner): before, it ran only once today had nothing left, and today always has an open
            // moment, a retry waiting out its back-off or dozens of version-bump rewrites while the person works, so past days
            // stayed "Summarizing…" for days. Now only today's closed moments still due their first note hold it back while
            // the person uses the Mac (an open moment gets its own live notes; rewrites are as low priority as catch-up);
            // once the Mac is idle 5 minutes it runs anyway, after today's batch. Never while typing (`quietOnly`), on
            // battery at most every 30 minutes (`catchUpSpacing`).
            let todayClosedLeft = await scheduler.snapshot().contains { state in
                state.item.day == today && !openKeys.contains(state.item.key) && !found.rewriteKeys.contains(state.item.key) &&
                    (state.status == .queued || (state.status == .retry && state.nextAttempt<=now))
            }
            let catchUpEvery=Self.catchUpSpacing(power,idle:idle,mode:mode)
            let typingNow = mode == "local" && env.typingSeconds()<Self.typingBurst
            if typingNow,catchUpBacklog,background {rewriteWaitsForQuiet=true}
            if env.pastDayNotes,failed == nil,!typingNow,clicksWaiting==0,!todayClosedLeft || idle>=Self.idleClose,background,budget.ok,now>=holdUntil,now>=catchUpQuietUntil,epoch==modeGeneration,
               now.timeIntervalSince(lastCatchUp)>=catchUpEvery {
                var items:[ScheduledWriterTarget]=[]
                var pastRewrites=Set<String>()
                var nextRewrite:Date?
                for day in try await source.catchUpDays(now:now,timezone:zone) where items.count<Self.catchUpNotes*3 {
                    let past=try await source.discoverDay(day,now:now,timezone:zone,marks:marks)
                    for (item,mark) in past.skipped {try await scheduler.setWritten(key:item.key,mark)}
                    willNotWrite.formUnion(past.willNotWrite)
                    if let due=past.nextRewrite {nextRewrite=min(nextRewrite ?? due,due)}
                    items+=past.targets
                    pastRewrites.formUnion(past.rewriteKeys)
                }
                // No target due yet is not empty history: a past moment may be waiting for its rewrite cooldown.
                // Preserve the long quiet only when discovery has no future rewrite deadline.
                if items.isEmpty {catchUpQuietUntil=nextRewrite ?? now.addingTimeInterval(6*3600);catchUpBacklog=false}
                else {
                    for item in items {do {try await scheduler.enqueue(item)} catch WriterFailure.capacity {full=true;break}}
                    if await openBatch() {
                        lastCatchUp=now
                        let run=await runNotes(only:Set(items.map(\.key)).subtracting(pastRewrites),limit:Self.catchUpNotes,newestFirst:true,provisional:[],mode:mode,epoch:epoch,automatic:true,quietOnly:true)
                        counters.catchUpNotes+=run.ran
                        // More discovered than this batch writes (discovery stops at 30): the next look comes when the next
                        // catch-up may run.
                        catchUpBacklog=items.count>run.ran
                        if run.outcome != nil {outcome=run.outcome}
                        ranNotes+=run.ran;failed=run.failure
                        // claude/ready-1002 (owner): then the past days' version-bump rewrites, newest first, never while typing.
                        if failed == nil,run.ran<Self.catchUpNotes,!pastRewrites.isEmpty {
                            let again=await runNotes(only:pastRewrites,limit:Self.catchUpNotes-run.ran,newestFirst:true,provisional:[],mode:mode,epoch:epoch,automatic:true,quietOnly:true)
                            counters.catchUpNotes+=again.ran
                            catchUpBacklog=items.count>run.ran+again.ran
                            if again.outcome != nil {outcome=again.outcome}
                            ranNotes+=again.ran;failed=again.failure
                        }
                    }
                }
            }
            if let failed {await providerFailed(failed,mode:mode,now:now)}
            var states=await scheduler.snapshot()
            pendingCount=Self.waiting(states);await publishSkipped();await publishQueue()
            guard epoch==modeGeneration else {return ranNotes>0 ? .ran : .idle}
            settle(mode:mode,outcome:outcome,full:full,states:states)
            // Levels once no moment of today waits for this batch. While this Mac's model waits (Low Power Mode, under 20%,
            // hot) code writes them, at most every 10 minutes; otherwise the model writes them in a batch.
            // r2: never gated on pending entries (pendingCount). A moment left waiting for Retry holds only its own block,
            // and blockPlan leaves it out a day after it ended, so one stuck note never stops every block, day, week and month.
            refreshBackgroundDecision()
            let codeOnly = mode == "local" && !background
            let momentsWaiting = !codeOnly && (failed != nil || (!keys.isEmpty && (!batchDue || ranNotes<keys.count)))
            // fix/sx-all round 3: and the pending moments the rewrite rule won't write again (`Discovery.willNotWrite`).
            let skippedIDs=Set(marks.filter {$0.value.skipped}.map {$0.key.components(separatedBy:"\u{1f}").last ?? ""}).union(willNotWrite)
            let willBeWritten:@Sendable (String) -> Bool = {!skippedIDs.contains($0)}
            // claude/dayeval-1005: with no moment model (`WriterEnvironment.momentModel`), code writes the level notes too.
            let levelsByCode = codeOnly || !env.momentModel
            if !momentsWaiting, let levels, now>=holdUntil, epoch==modeGeneration, levelsByCode || budget.ok,
               levelsByCode ? now.timeIntervalSince(lastCodeLevels)>=Self.codeLevelsEvery
                        : batchOpen || mode == "cloud" || now.timeIntervalSince(lastBatch)>=Self.batchEvery || idle>=Self.idleClose {
                if levelsByCode {lastCodeLevels=now}
                // Outside a batch, the model is held for all the level notes due now (one load), and it counts as a batch
                // once one of them used it.
                let hold = !levelsByCode && !batchOpen && runtime != nil
                if hold {await runtime?.beginBatch()}
                for _ in 0..<Self.batchLevels {
                    guard epoch==modeGeneration,!Task.isCancelled,clicksWaiting==0,codeOnly || !env.momentModel || mode != "local" || env.power().allowsBackground else {break}
                    guard let step=try? await levelRunner.step(levels,timezone:zone,now:now,codeOnly:levelsByCode,momentWillBeWritten:willBeWritten) else {break}
                    if step.source == "model" || step.source == "repair" {
                        counters.modelLevels+=1
                        if hold && !batchOpen {batchOpen=true;counters.batches+=1;lastBatch=now}
                    } else {counters.codeLevels+=1}
                    onLevelCommitted?(step.note)
                }
                if hold {
                    if batchOpen {batchOpen=false}
                    await runtime?.endBatch()
                }
            }
            // claude/day-review-1003: then the day review's clauses, low priority: only once no moment waits, never while the
            // person types (a short pause is enough), in the background, within the budget. Each is due only after a
            // material change and at most every 15 minutes per thread (`reviewClauseWork`); the card is put together from
            // the cached clauses with no model call, and keeps its code bullets when the model fails.
            if !momentsWaiting, !codeOnly, let levels, levels.usesModel, now>=holdUntil, epoch==modeGeneration, budget.ok, background,
               mode != "local" || env.typingSeconds()>=Self.typingBurst {
                let hold = mode == "local" && !batchOpen && runtime != nil
                if hold {await runtime?.beginBatch()}
                for _ in 0..<Self.batchClauses {
                    guard epoch==modeGeneration,!Task.isCancelled,mode != "local" || (env.power().allowsBackground && env.typingSeconds()>=Self.typingBurst) else {break}
                    guard let step=try? await levelRunner.clause(levels,timezone:zone,now:now) else {break}
                    onReviewClauseCommitted?(step.clause.day,zone)
                }
                if hold {await runtime?.endBatch()}
            }
            if mode == "local",let runtime,await runtime.failedLoads>=2 {phase = .failed(.modelWontStart);retryWaitsForPower=false}
            states=await scheduler.snapshot()
            await noteLoads()
            let afterMarks=await scheduler.writtenMarks()
            let scheduledFound=mode == "local" ? try await source.discoverDay(today,now:env.now(),timezone:zone,closedBy:closing,marks:afterMarks) : found
            let liveAt = !scheduledFound.live.isEmpty && failed == nil && env.now()>=holdUntil ? env.now().addingTimeInterval(1) : scheduledFound.nextLive
            let summaryAt = !scheduledFound.summaryDue.isEmpty && budget.ok && failed == nil && env.now()>=holdUntil ? env.now().addingTimeInterval(1) : scheduledFound.nextSummary
            refreshBackgroundDecision()
            let catchUpAt = catchUpBacklog && failed == nil ? max(lastCatchUp.addingTimeInterval(Self.catchUpSpacing(power,idle:idle,mode:mode)),budget.at ?? .distantPast) : nil
            scheduleNext(now:now,found:scheduledFound,waiting:!keys.isEmpty && ranNotes<keys.count,background:background,mode:mode,idle:idle,budgetAt:budget.at,overdueAt:Self.overdueDeadline(states,day:today),liveAt:liveAt,summaryAt:summaryAt,catchUpAt:catchUpAt)
            return ranNotes>0 ? .ran : .idle
        } catch {processing=nil;status=Self.writerPending;scheduleNext(now:now,found:nil,waiting:false,background:false,mode:mode,idle:idle);return .idle}
    }
    /// The one timer: the earliest of the next moment that closes by itself, the next batch, the end of a back-off and
    /// (while the model waits) the next code-written levels. At least 5 minutes after the last scheduled look.
    private func scheduleNext(now:Date,found:WriterQueueSource.Discovery?,waiting:Bool,background:Bool,mode:String,idle:TimeInterval,budgetAt:Date?=nil,overdueAt:Date?=nil,liveAt:Date?=nil,summaryAt:Date?=nil,catchUpAt:Date?=nil) {
        guard provider != "off" else {schedule(nil);return}
        if mode=="local",expiryWaitsForQuiet {schedule(expiryQuietWake());return}
        var next=now.addingTimeInterval(Self.quietWake)
        if mode=="local",rewriteWaitsForQuiet,background {next=min(next,expiryQuietWake())}
        func consider(_ date:Date?) {if let date {next=min(next,date)}}
        if let quiet=quietWakeAt {quietWakeAt=nil;if quiet>now {consider(quiet)}}
        consider(found?.nextClose);consider(found?.nextRewrite)
        if background && catchUpQuietUntil>now {consider(catchUpQuietUntil)}
        if background {consider(catchUpAt)}
        if waiting && background {
            consider(budgetAt)
            if mode == "local" {consider(overdueAt)}
            consider(lastBatch.addingTimeInterval(Self.batchEvery))
            consider(now.addingTimeInterval(max(60,Self.idleClose-idle)))
        }
        if mode == "local" && !background {consider(lastCodeLevels.addingTimeInterval(Self.codeLevelsEvery))}
        next=max(next,lastTimerPass.addingTimeInterval(Self.wakeSpacing),now.addingTimeInterval(1))
        // A back-off ends on time (it is not a moment check; it is at most one a minute and only after a failure).
        if holdUntil>now && holdUntil != .distantFuture {next=min(next,max(holdUntil,now.addingTimeInterval(1)))}
        ordinaryWakeAt=next
        let cadence=mode == "local" && background ? [liveAt,found?.nextFinal].compactMap {$0}.filter {$0>now} : []
        cadenceWakeAt=cadence.min()
        let services=mode == "local" && background ? [summaryAt,cadenceWakeAt].compactMap {$0}.filter {$0>now} : []
        serviceWakeAt=services.min()
        installSchedule(min(next,serviceWakeAt ?? next))
    }
    /// A failed model or provider: one writer-wide back-off (1, 5, 15, then every 60 minutes), no per-moment retries.
    /// A cloud key, credits or host problem waits for the fixing button instead.
    private func providerFailed(_ problem:SummaryProblem?,mode:String,now:Date) async {
        failuresInRow+=1
        switch problem {
        case .cloudKey?,.cloudCredits?,.cloudHost?:
            holdUntil = .distantFuture;phase = .failed(problem!)
        default:
            holdUntil=now.addingTimeInterval(Self.backoff[min(failuresInRow,Self.backoff.count)-1])
            if mode == "cloud" && (problem == .cloudOffline || failuresInRow>=2) {phase = .failed(.cloudOffline)}
        }
        try? await scheduler?.holdAll(until:holdUntil)
        // The one timer fires when the back-off ends, if nothing else comes first.
        if holdUntil != .distantFuture && (nextWake.map {$0>holdUntil} ?? true) {schedule(holdUntil)}
    }
    private enum RunKind {case none,committed,final,stale,waiting,expired,provider(SummaryProblem?)}
    private final class RunBox:@unchecked Sendable {var kind=RunKind.none;var item:ScheduledWriterTarget?}
    /// Writes up to `limit` of `only`, one at a time. Stops at the first model or provider failure (its moment waits for
    /// the back-off). `provisional`: open moments an AI app asked for; they are written again once they close.
    /// `written`: Summarize Now's moment, written afresh even when its note is current (fix/resummarize). `stale` counts
    /// moments that changed between choosing and preparing (nothing ran for them).
    private func runNotes(only keys:Set<String>,limit:Int,newestFirst:Bool,provisional:Set<String>,written:Set<String>=[],active:Set<String>=[],closing:Set<String>=[],mode:String,epoch:Int,automatic:Bool=false,quietOnly:Bool=false) async -> (ran:Int,outcome:ScheduledWriterOutcome?,failure:SummaryProblem??,stale:Int) {
        guard let scheduler,let source,let adapter,!keys.isEmpty else {return (0,nil,nil,0)}
        if quietOnly {rewriteWaitsForQuiet=false}
        if mode=="local",expiryWaitsForQuiet {
            guard env.typingSeconds()>=Self.typingBurst else {schedule(expiryQuietWake());return (0,nil,nil,0)}
            expiryWaitsForQuiet=false
        }
        var ran=0,last:ScheduledWriterOutcome?,stale=0,committed=Set<NoteCommitScope>()
        defer { publishCommitted(committed) }
        let clock=env.now,powerNow=env.power
        while ran<limit,epoch==modeGeneration,provider==mode,!Task.isCancelled,
              !automatic || clicksWaiting==0,
              !automatic || mode != "local" || env.power().allowsBackground {
            // claude/ready-1002 (owner): a rewrite never starts while the person is typing (lag); it waits for quiet.
            if quietOnly,mode == "local",env.typingSeconds()<Self.typingBurst {rewriteWaitsForQuiet=true;break}
            // perf2-1005 (owner 10/04): no background note starts while DayDream opens or the person types; it looks again then.
            if automatic,case let quiet=env.quietFor(),quiet>0 {quietWakeAt=env.now().addingTimeInterval(quiet+0.5);counters.quietDeferrals+=1;break}
            let box=RunBox()
            let attemptAt=clock()
            // The core receipt survives a later scheduler cancellation or ledger failure.
            defer {
                if case .committed = box.kind,let item=box.item {
                    counters.committedNotes+=1
                    committed.insert(NoteCommitScope(day:item.day,timezone:item.timezone))
                }
            }
            let task=Task(priority:env.workPriority) {try await scheduler.runNext(only:keys,newestFirst:newestFirst) {item in
                box.item=item
                guard try await source.isCurrent(item,written:written.contains(item.key)) else {box.kind = .stale;return .pending}
                let result:CoreWriterResult
                let live=mode == "local" && active.contains(item.key)
                let target=WriterTarget(kind:item.target.kind,day:item.day,timezone:item.timezone,activityID:item.activityID,allowGrowingSnapshot:live)
                do {result=try await adapter.process(target,lastActivity:item.lastActivity,now:clock(),allowActive:live || (mode == "local" && closing.contains(item.key)))} catch {
                    try Task.checkCancellation()
                    if error is CancellationError {throw error}
                    if case WriterFailure.requestExpired=error {box.kind = .expired;throw error}
                    // gold/notes G26: nothing left this Mac (preparing raced a capture, or the writer was busy): the whole
                    // writer backs off and it is tried again.
                    box.kind = .provider(nil);return .retry
                }
                switch result {
                case .committed:box.kind = .committed;return .committed
                case .pending(let pending):
                    switch pending.reason {
                    // Greedy local decoding would replay a rejected answer, and a moment too long stays too long: the
                    // note is final (the code note stands) until the moment grows (the rewrite rule).
                    case .capacity:box.kind = .final;return .pending
                    case .invalidOutput:
                        // A cloud answer that failed may have been billed: it waits for Retry, never replayed by itself.
                        if mode=="cloud" {box.kind = .waiting} else {box.kind = .final}
                        return .pending
                    case .notSent,.providerUnavailable:
                        // A current power hold keeps the automatic target queued without blaming the provider.
                        if automatic,mode=="local",!powerNow().allowsBackground {box.kind = .waiting;return .retry}
                        box.kind = .provider(nil);return .retry
                    case .cloudOffline:box.kind = .provider(.cloudOffline);return .retry
                    case .cloudKey:box.kind = .provider(.cloudKey);return .retry
                    case .cloudCredits:box.kind = .provider(.cloudCredits);return .retry
                    case .cloudHost:box.kind = .provider(.cloudHost);return .retry
                    }
                }
            }}
            processing=task
            writing=true
            let outcome:ScheduledWriterOutcome?
            do {outcome=try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})}
            catch {processing=nil;writing=false;status=Self.writerPending;return (ran,last,nil,stale)}
            processing=nil;writing=false
            guard let outcome,let item=box.item else {break}
            if case .expired=box.kind {
                guard epoch==modeGeneration,provider==mode else {break}
                expiryRetryKeys.insert(item.key);expiryWaitsForQuiet=true;schedule(expiryQuietWake())
                return (ran,last,nil,stale)
            }
            expiryRetryKeys.remove(item.key)
            ran+=1;last=outcome;counters.noteRuns+=1;onNoteRun?(item)
            guard epoch==modeGeneration else {break}
            let now=clock()
            switch box.kind {
            case .committed:
                failuresInRow=0
                if case .failed(let problem)=phase,[.cloudOffline,.modelWontStart].contains(problem) {phase = .on(mode == "cloud" ? .cloud : .local)}
                let extent=try? await source.extent(item)
                let writes=WriterQueueSource.writes(await scheduler.writtenMarks()[item.key])+1
                let cadenceAt=mode == "local" && active.contains(item.key) && provisional.contains(item.key) ? attemptAt : now
                try? await scheduler.setWritten(key:item.key,WrittenMark(actions:extent?.actions ?? 0,typed:0,at:cadenceAt,provisional:provisional.contains(item.key),end:extent?.end ?? nil,revision:await source.markRevision(item),writes:writes,writerRevision:WriterQueueSource.writerRevision))
            case .final:
                let extent=try? await source.extent(item)
                let writes=WriterQueueSource.writes(await scheduler.writtenMarks()[item.key])
                let cadenceAt=mode == "local" && active.contains(item.key) && provisional.contains(item.key) ? attemptAt : now
                try? await scheduler.setWritten(key:item.key,WrittenMark(actions:extent?.actions ?? 0,typed:0,at:cadenceAt,provisional:provisional.contains(item.key),skipped:true,end:extent?.end ?? nil,revision:await source.markRevision(item),writes:writes,fallback:true,writerRevision:WriterQueueSource.writerRevision))
                try? await scheduler.discard(key:item.key)
            case .stale:
                stale+=1
                try? await scheduler.discard(key:item.key)
            case .provider(let problem):
                // Never used up by a back-off: the moment is queued again, and waits for the writer-wide hold.
                try? await scheduler.retry(key:item.key)
                return (ran,outcome,.some(problem),stale)
            case .waiting,.expired,.none:break
            }
        }
        return (ran,last,nil,stale)
    }
    /// fix/sx-engine-battery: an AI app asked about the last hour (Sources/MacMemCLI/main.swift). One priority batch over
    /// the last 60 minutes, open moments too (written provisionally, and again once they close), at most every
    /// 5 minutes; on battery too, unless Low Power Mode is on or the battery is under 20%. Always says done.
    func onDemand() async {
        defer {env.postDone()}
        let now=env.now(),requestEpoch=modeGeneration,requestMode=provider
        // Release only (never acquire) even when this request will be rate limited or declined for power.
        if requestMode=="local",!env.power().allowsBackground || env.idleSeconds()>=Self.idleClose {
            guard await reconcileWarmLease(writableOpen:false,epoch:requestEpoch,mode:requestMode) else {counters.onDemandSkipped+=1;return}
        }
        guard requestEpoch==modeGeneration,requestMode==provider,provider != "off",case .on=phase,
              now.timeIntervalSince(lastOnDemand)>=Self.onDemandEvery,let scheduler,let source else {counters.onDemandSkipped+=1;return}
        if provider=="local" && !env.power().allowsOnDemand {counters.onDemandSkipped+=1;return}
        var lean=provider=="local" && !env.power().allowsBackground
        // build/launch: fix/battery-summaries lets this Mac's model write on battery (not lean above 20%), so a request
        // on battery keeps battery's spacing and batch size (at most 4 requests and 12 notes an hour), as before.
        var battery=provider=="local" && !env.power().onPower
        if (lean || battery) && now.timeIntervalSince(lastOnDemand)<Self.onDemandBatteryEvery {counters.onDemandSkipped+=1;return}
        for _ in 0..<150 where cycleRunning || writing {try? await Task.sleep(nanoseconds:100_000_000)}
        guard !cycleRunning,!writing,!switching,requestEpoch==modeGeneration,requestMode==provider,!Task.isCancelled else {counters.onDemandSkipped+=1;return}
        cycleRunning=true
        defer {cycleRunning=false;resumeDeferred()}
        // The wait above may cross a power transition. Keep ordinary MCP power/spacing rules intact.
        if requestMode=="local" {
            let power=env.power()
            if !power.allowsBackground || env.idleSeconds()>=Self.idleClose {
                guard await reconcileWarmLease(writableOpen:false,epoch:requestEpoch,mode:requestMode) else {counters.onDemandSkipped+=1;return}
            }
            guard power.allowsOnDemand else {counters.onDemandSkipped+=1;return}
            lean = !power.allowsBackground; battery = !power.onPower
            if (lean || battery) && now.timeIntervalSince(lastOnDemand)<Self.onDemandBatteryEvery {counters.onDemandSkipped+=1;return}
        }
        guard requestEpoch==modeGeneration,requestMode==provider,!Task.isCancelled else {counters.onDemandSkipped+=1;return}
        let epoch=modeGeneration,mode=provider,zone=env.timezone()
        let priorAdmission=localWorkAdmission;localWorkAdmission = .onDemand
        defer {if epoch==modeGeneration {localWorkAdmission=priorAdmission}}
        if mode != "local" {lastOnDemand=now} // Preserve cloud's existing request timestamp, including empty discoveries.
        // Source discovery, persistent acquire and ordinary batch acquire can all suspend. Read power AFTER
        // any required release, and compare spacing against the previous accepted request, not this request itself.
        func freshRequestAllowed() async -> Bool {
            guard epoch==modeGeneration,provider==mode,!Task.isCancelled else {return false}
            guard mode=="local" else {return true} // Cloud already passed its ordinary gate; no local lease or power budget.
            if mode=="local" {
                if !env.power().allowsBackground || env.idleSeconds()>=Self.idleClose {
                    guard await reconcileWarmLease(writableOpen:false,epoch:epoch,mode:mode) else {return false}
                }
                let currentPower=env.power()
                guard currentPower.allowsOnDemand else {return false}
                lean = !currentPower.allowsBackground; battery = !currentPower.onPower
            }
            let elapsed=env.now().timeIntervalSince(lastOnDemand)
            return elapsed>=Self.onDemandEvery && (!(lean || battery) || elapsed>=Self.onDemandBatteryEvery)
        }
        do {
            let marks=await scheduler.writtenMarks()
            let found=try await source.discoverDay(try DayScope.key(now,timezone:zone),now:now,timezone:zone,closedBy:closedBy,marks:marks,since:now.addingTimeInterval(-Self.onDemandWindow))
            guard await reconcileWarmLease(writableOpen:found.keepLocalWarm,epoch:epoch,mode:mode) else {return}
            guard await freshRequestAllowed() else {counters.onDemandSkipped+=1;return}
            for (item,mark) in found.skipped {try await scheduler.setWritten(key:item.key,mark)}
            var items=found.targets+found.open
            // fix/sx-all round 3: on power too (see onDemandRewriteAfter), stricter; the batch size and spacing are battery's.
            do {
                var kept:[ScheduledWriterTarget]=[]
                for item in items {
                    guard let mark=marks[item.key] else {kept.append(item);continue}
                    // On power the background batch rewrites what grew or changed, within minutes: a request writes only
                    // moments with no note yet (a moment was written up to 5 times, and the model loaded about 10 times
                    // an hour).
                    if !lean || WriterQueueSource.writes(mark)>=WriterQueueSource.maxWrites {continue}
                    let count=(try? await source.actionCount(item)) ?? 0
                    if now.timeIntervalSince(mark.at)>=Self.onDemandRewriteAfter && Double(count)>=Double(mark.actions)*1.25 && count>mark.actions {kept.append(item)}
                }
                items=kept
            }
            guard !items.isEmpty else {return}
            if mode == "local",await loadAllowed(now).ok == false {counters.onDemandSkipped+=1;return}
            for item in items {do {try await scheduler.enqueue(item)} catch WriterFailure.capacity {break}}
            let batch=runtime
            await batch?.beginBatch()
            guard await freshRequestAllowed() else {await batch?.endBatch();counters.onDemandSkipped+=1;return}
            if mode=="local" {lastOnDemand=env.now()}
            counters.onDemandBatches+=1
            let run=await runNotes(only:Set(items.map(\.key)),limit:lean || battery ? Self.onDemandBatteryNotes : Self.batchNotes,newestFirst:true,provisional:Set(found.open.map(\.key)),mode:mode,epoch:epoch)
            await batch?.endBatch();await noteLoads()
            if let failure=run.failure {await providerFailed(failure,mode:mode,now:now)}
            let states=await scheduler.snapshot()
            pendingCount=Self.waiting(states);await publishSkipped();await publishQueue()
            if epoch==modeGeneration {settle(mode:mode,outcome:run.outcome,full:false,states:states)}
        } catch {status=Self.writerPending}
    }
    /// The status after a pass: a line holds only while it is true. Once nothing waits, it goes back to the resting line.
    private func settle(mode:String,outcome:ScheduledWriterOutcome?,full:Bool,states:[ScheduledWriterState]) {
        if full {status=Self.queueFull;return}
        if let outcome {
            switch outcome {
            case .committed:status=mode=="cloud" ? "Generated note saved. Written through OpenRouter by a model host asked not to keep it.":"Generated note saved locally"
            case .pending:if pendingCount>0 {status=Self.notePending}
            case .retry:status=mode=="cloud" ? Self.cloudRetry : Self.localRetry
            }
            return
        }
        guard Self.pollLines.contains(where:{status.hasPrefix($0)}) else {return}
        if pendingCount>0 {status=Self.notePending}
        else if states.contains(where:{$0.status == .retry}) {status=mode=="cloud" ? Self.cloudRetry : Self.localRetry}
        else {status=mode=="cloud" ? Self.cloudResting : Self.localResting}
    }
    /// Summarize now: one moment, at once, open or not, written or not (a click). Never shown as busy: the row keeps the
    /// note it shows until the fresh one is stored (stale-while-updating), then the app rereads its day.
    /// fix/resummarize (owner, test 7): a moment that already had a note did nothing (its note was current, so the run
    /// was dropped as stale), and a click during a background batch failed. Now it waits for a running batch (up to a
    /// minute), writes a fresh note from everything in the moment now, and a moment still open is marked provisional so it
    /// is written again, normally, once it closes. On this Mac a click always runs, except while the Mac is critically hot.
    ///
    /// claude/summary-fail-1003 (owner 10/3, installed 20261003140001): the click waited at most a minute while the
    /// background writer rewrote the day after the version bump (a batch of notes, minutes long), then threw, and the
    /// card said "Couldn't summarize. Check Summaries in Settings." with summaries fine. Now the batch stops after the
    /// note it is writing (`clicksWaiting`), the click waits up to `generateWait` for that note, and a failure says what
    /// kind it is (`SummarizeNowFailure`): `.setup` only when summaries are off, `.once` for everything that passes.
    /// A click still refused by a busy writer leaves its moment queued first, so the next look writes it anyway.
    static var generateWait:TimeInterval=180
    func generate(day:String,timezone:String,activityID:String,lastActivity:Date) async throws {
        guard provider != "off" else { throw SummarizeNowFailure.setup("Summaries are off.") }
        guard source != nil,scheduler != nil else { throw SummarizeNowFailure.once("writer-starting") }
        // A click always runs (owner: one click that works), in Low Power Mode or on a low battery too; only a Mac that is
        // critically hot refuses. Background writing keeps its power rules.
        if provider == "local" && env.power().thermal >= ProcessInfo.ThermalState.critical.rawValue { throw SummarizeNowFailure.once("too-hot") }
        clicksWaiting+=1
        for _ in 0..<Int(Self.generateWait*10) where writerBusy {try? await Task.sleep(nanoseconds:100_000_000)}
        clicksWaiting-=1
        guard provider != "off" else { resumeDeferred(); throw SummarizeNowFailure.setup("Summaries are off.") }
        guard !writerBusy,let source,let scheduler else {
            if !switching,let source,let scheduler,let (item,_)=try? await source.selected(day:day,timezone:timezone,activityID:activityID,now:env.now(),closedBy:closedBy) {
                try? await Self.enqueueToday(item,scheduler:scheduler,today:(try? DayScope.key(env.now(),timezone:env.timezone())) ?? item.day,priority:true)
                try? await scheduler.retry(key:item.key)
            }
            resumeDeferred()
            throw SummarizeNowFailure.once("writer-busy")
        }
        cycleRunning=true
        defer {cycleRunning=false;resumeDeferred()}
        let epoch=modeGeneration,mode=provider
        let priorAdmission=localWorkAdmission;localWorkAdmission = .manual
        defer {if epoch==modeGeneration {localWorkAdmission=priorAdmission}}
        await runtime?.beginBatch()
        var run:(ran:Int,outcome:ScheduledWriterOutcome?,failure:SummaryProblem??,stale:Int)=(0,nil,nil,0)
        // Once more if the moment changed between reading it and preparing (a capture landed): the note covers it all.
        do {
            for _ in 0..<2 {
                let now=env.now()
                let (item,open)=try await source.selected(day:day,timezone:timezone,activityID:activityID,now:now,closedBy:closedBy)
                // The adapter refuses a moment whose last action is under 2 seconds old; wait that out (at most 3 seconds).
                let young=item.lastActivity.addingTimeInterval(2.1).timeIntervalSince(now)
                if young>0 {try? await Task.sleep(nanoseconds:UInt64(min(young,3)*1e9))}
                try await Self.enqueueToday(item,scheduler:scheduler,today:(try? DayScope.key(now,timezone:env.timezone())) ?? item.day)
                try await scheduler.retry(key:item.key);try await scheduler.start();await publishQueue()
                run=await runNotes(only:[item.key],limit:1,newestFirst:false,provisional:open ? [item.key] : [],written:[item.key],mode:mode,epoch:epoch)
                guard run.stale>0,epoch==modeGeneration else {break}
            }
        } catch {await runtime?.endBatch();throw error}
        await runtime?.endBatch();await noteLoads()
        if let failure=run.failure {await providerFailed(failure,mode:mode,now:env.now())}
        let states=await scheduler.snapshot()
        pendingCount=Self.waiting(states);await publishSkipped();await publishQueue()
        if epoch==modeGeneration {settle(mode:mode,outcome:run.outcome,full:false,states:states)}
    }
    /// fix/writing-forever: today's moment (or Summarize Now's) always gets a place in the queue. The queue holds 128
    /// entries and only a completed one gave way, so a queue filled by past days' catch-up entries (queued, or waiting
    /// for Retry) refused every new moment of today for good: today's batch then found nothing to run, and catch-up, which
    /// waits until today is written, never ran either. Nothing was written again, with no model load, while Today said
    /// "Writing the summary…". Now the past-day entry that ended longest ago gives way (catch-up finds it again: core is
    /// the note authority); only a queue full of today's moments still says it is full.
    static func enqueueToday(_ item:ScheduledWriterTarget,scheduler:PendingNoteScheduler,today:String,priority:Bool=false,protected:Set<String>=[]) async throws {
        do {try await scheduler.enqueue(item);return} catch WriterFailure.capacity {}
        // A due live/final note must retain a slot even behind a full same-day
        // backlog. Discard only routing metadata; core rediscovers the old note.
        let past=await scheduler.snapshot().filter {$0.status != .running && (priority || $0.item.day != today) && $0.item.key != item.key && !protected.contains($0.item.key)}
        guard let oldest=past.min(by:{($0.item.lastActivity,$0.item.key)<($1.item.lastActivity,$1.item.key)}) else {throw WriterFailure.capacity}
        try await scheduler.discard(key:oldest.item.key)
        try await scheduler.enqueue(item)
    }
}
/// Saves the summary mode AI apps read (gold/notes G52). One lock orders every save, so a late retry never writes an
/// older value over a newer one; after `close()` (quit) nothing replaces "off".
final class ProviderReport:@unchecked Sendable {
    private let lock=NSLock(),save:(String) throws -> Void
    private var wanted="off",saved:String?,closed=false
    init(save:@escaping (String) throws -> Void) {self.save=save}
    /// Saves `value` now. false when the save failed; `retry()` then saves whatever is wanted by then.
    @discardableResult func set(_ value:String) -> Bool {
        lock.lock();defer{lock.unlock()}
        guard !closed else {return true}
        wanted=value;return write()
    }
    /// true once the wanted value is saved (or after quit).
    func retry() -> Bool {
        lock.lock();defer{lock.unlock()}
        return closed || saved==wanted || write()
    }
    func close() {
        lock.lock();defer{lock.unlock()}
        guard !closed else {return}
        wanted="off";_=write();closed=true
    }
    private func write() -> Bool {
        do {try save(wanted);saved=wanted;return true} catch {saved=nil;return false}
    }
}
struct WriterSetup:View {
    @ObservedObject var writer:WriterIntegration
    var body:some View {
        SettingsSurface("Writer") { SettingsCard {
            Text("On this Mac").font(.headline)
            Text("Qwen3.5-4B · 2.74 GB download · macOS 15 or later, Apple silicon, 8 GB of memory").font(.caption)
            Text(writer.status).font(.caption)
            if let progress=writer.progress { ProgressView(value:progress) }
            if writer.busy && writer.downloadEstimate.isActive { DownloadTimeRemaining(estimate:writer.downloadEstimate) }
            Button("Set up local writer") { writer.install() }.disabled(writer.busy)
            if writer.busy { Button("Cancel",action:writer.cancel) }
        }
        SettingsCard {
            Text("Cloud Provider").font(.headline)
            Text(CloudActivation.destination).font(.caption)
        } }
    }
}
