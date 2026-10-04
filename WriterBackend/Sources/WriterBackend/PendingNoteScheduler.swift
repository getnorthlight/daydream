import Foundation
import Darwin

/// Contains only routing/revision metadata. Never persist evidence or provider errors here.
public struct ScheduledWriterTarget: Codable, Sendable, Equatable {
    public let kind:String,day:String,timezone:String,activityID:String?,inputRevision:String,policyRevision:String
    public let lastActivity:Date
    public init(target:WriterTarget,inputRevision:String,policyRevision:String,lastActivity:Date) {
        kind=target.kind.rawValue;day=target.day;timezone=target.timezone;activityID=target.activityID
        self.inputRevision=inputRevision;self.policyRevision=policyRevision;self.lastActivity=lastActivity
    }
    public var target:WriterTarget {WriterTarget(kind:kind == "day" ? .day:.activity,day:day,timezone:timezone,activityID:activityID)}
    public var key:String {[kind,day,timezone,activityID ?? ""].joined(separator:"\u{1f}")}
}
public enum ScheduledWriterOutcome:Sendable {case committed, retry, pending}
/// fix/sx-engine-battery: what a moment held when its note was last written (or when it was set aside), kept in the
/// ledger so a written moment is rewritten only when it grew enough (WriterQueueSource's rewrite rule).
public struct WrittenMark: Codable, Sendable, Equatable {
    /// Member actions, and typed or sent rows among them, at that write.
    public var actions:Int, typed:Int
    public var at:Date
    /// Written while still open, for an AI app's request: rewritten normally once it closes.
    public var provisional:Bool
    /// Not a note: an idle-only or empty moment (nothing to write), or a local note that failed its checks for good
    /// (the code note stands). Either way nothing more runs for it until the rewrite rule says it grew.
    public var skipped:Bool
    /// fix/resummarize: the moment's last action at that write (nil in marks from before it): a moment used a few more
    /// minutes after its note is rewritten.
    public var end:Date?
    /// fix/sx-all round 3: what the moment was written (or set aside) at: its input, the privacy settings and who reads it
    /// (`WriterQueueSource.markRevision`). A closed moment pending again at another revision without growing (a moment
    /// rejoined, Forget, typing turned off, cloud turned on) is written once more; at the same revision, never again.
    /// nil in marks from before round 3: counts as another revision.
    public var revision:String?
    /// fix/writing-forever: notes written for this moment so far, Summarize Now included (nil in marks from before it).
    /// Ordinary background growth is capped by `WriterQueueSource.maxWrites`;
    /// new typed/submitted evidence and writer-version refreshes still qualify.
    public var writes:Int?
    /// fix/summary-fallback (QF-16): set aside by a writer with the code fallback note (`CanonicalGrounding.fallbackNote`).
    /// nil in marks from before it: a moment an earlier build set aside because every answer failed (pending for good,
    /// no note) is written once more, now ending in at least the fallback note (`recoverable`).
    public var fallback:Bool?
    /// Fixed writer version set that made this attempt. Optional so existing
    /// ledgers decode; a legacy timestamp cannot identify the build that tried.
    public var writerRevision:String?
    public init(actions:Int,typed:Int,at:Date,provisional:Bool=false,skipped:Bool=false,end:Date?=nil,revision:String?=nil,writes:Int?=nil,fallback:Bool?=nil,writerRevision:String?=nil) {
        self.actions=actions;self.typed=typed;self.at=at;self.provisional=provisional;self.skipped=skipped;self.end=end;self.revision=revision
        self.writes=writes;self.fallback=fallback;self.writerRevision=writerRevision
    }
    /// fix/summary-fallback: a mark an earlier build set aside (skipped, no `fallback`): due once more.
    public var recoverable:Bool {skipped && fallback == nil}
}
public struct ScheduledWriterState:Codable,Sendable {
    public enum Status:String,Codable,Sendable {case queued,running,retry,pending,cancelled,completed}
    public var item:ScheduledWriterTarget
    public var status:Status
    public var attempts:Int
    public var nextAttempt:Date
}

/// One process-wide owner must retain this actor. Core remains the durable note authority.
/// Start is explicit after provider readiness/consent. Construction never starts inference.
public actor PendingNoteScheduler {
    public typealias Process = @Sendable (ScheduledWriterTarget) async throws -> ScheduledWriterOutcome
    private struct Ledger:Codable {let version:Int;var entries:[ScheduledWriterState];var localResumeEnabled:Bool?;var cloudResumeVersion:Int?=nil
        var cloudCutoff:Date?=nil;var written:[String:WrittenMark]?=nil}
    /// The most written marks kept (oldest go first); a mark older than a week is dropped too.
    public static let writtenLimit=2048
    private let file:URL,limit:Int,baseRetry:TimeInterval,maxRetry:TimeInterval,maxAttempts:Int
    private let lockFD:Int32
    private var entries:[String:ScheduledWriterState]=[:]
    private var operation:Task<ScheduledWriterOutcome,Error>?
    private var activeKey:String?,enabled=false
    private var localResumeEnabled:Bool?
    /// The cloud notice version the person turned cloud summaries on with (summaries/v3, owner 9/28): cloud comes back
    /// on after a relaunch only while this equals `CloudActivation.disclosureVersion`. nil or another version: off.
    private var cloudResumeVersion:Int?
    /// When cloud summaries were first turned on for the current switch (kept across relaunches and privacy changes).
    private var cloudCutoff:Date?
    private var written:[String:WrittenMark]=[:]
    private let now:@Sendable () -> Date
    public private(set) var storageFailed=false

    public init(file:URL,limit:Int=128,baseRetry:TimeInterval=15,maxRetry:TimeInterval=3600,maxAttempts:Int=6,now:@escaping @Sendable () -> Date = {Date()}) throws {
        self.now=now
        self.file=file;self.limit=max(1,min(limit,512));self.baseRetry=max(0.05,baseRetry)
        self.maxRetry=max(baseRetry,maxRetry);self.maxAttempts=max(1,maxAttempts)
        try Self.verifyDirectory(file.deletingLastPathComponent())
        let fd=open(file.appendingPathExtension("lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard fd>=0 else {throw WriterFailure.denied}
        guard flock(fd,LOCK_EX|LOCK_NB)==0 else {close(fd);throw WriterFailure.busy}
        lockFD=fd
        do {
        if FileManager.default.fileExists(atPath:file.path) {
            let attributes=try FileManager.default.attributesOfItem(atPath:file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576 else {throw WriterFailure.integrity}
            let ledger=try JSONDecoder().decode(Ledger.self,from:Data(contentsOf:file))
            guard ledger.version==1,ledger.entries.count<=self.limit else {throw WriterFailure.integrity}
            localResumeEnabled=ledger.localResumeEnabled
            cloudResumeVersion=ledger.cloudResumeVersion
            cloudCutoff=ledger.cloudCutoff
            written=ledger.written ?? [:]
            for var entry in ledger.entries {
                guard Self.valid(entry.item),entries[entry.item.key]==nil,entry.attempts>=0 else {throw WriterFailure.integrity}
                // An interrupted inference is never treated as committed. Core prepare/commit
                // performs source validation and idempotency before a retry can commit.
                if entry.status == .running {entry.status = .retry;entry.nextAttempt=now().addingTimeInterval(self.baseRetry)}
                entries[entry.item.key]=entry
            }
        }
        } catch {flock(fd,LOCK_UN);close(fd);throw error}
    }
    deinit {flock(lockFD,LOCK_UN);close(lockFD)}
    public func snapshot()->[ScheduledWriterState] {entries.values.sorted{$0.item.key<$1.item.key}}
    public func resumeLocalPreference()->Bool? {localResumeEnabled}
    /// Local readiness is still revalidated by the app.
    public func setResumeLocal(_ enabled:Bool) throws {localResumeEnabled=enabled;try persist()}
    /// The switch, not the activation: the app turns cloud on again with this version through `CloudActivation.enable`,
    /// which refuses any version but the current one. The key stays in the Keychain; nothing else is kept.
    public func resumeCloudPreference()->Int? {cloudResumeVersion}
    /// fix/sx-engine-battery: the cutoff of the first activation is saved with the switch, so turning cloud back on after a
    /// relaunch or a privacy change keeps it. Turning the switch off (nil) forgets both.
    public func setResumeCloud(_ version:Int?,cutoff:Date?=nil) throws {
        cloudResumeVersion=version
        if version == nil {cloudCutoff=nil} else if let cutoff {cloudCutoff=cutoff}
        try persist()
    }
    public func resumeCloudCutoff()->Date? {cloudResumeVersion == nil ? nil : cloudCutoff}
    /// fix/sx-engine-battery: the written marks (keyed like entries), for the rewrite rule.
    public func writtenMarks()->[String:WrittenMark] {written}
    public func setWritten(key:String,_ mark:WrittenMark?) throws {
        written[key]=mark
        if written.count > Self.writtenLimit {
            let week=now().addingTimeInterval(-7*86400)
            written=written.filter { $0.value.at >= week }
            if written.count > Self.writtenLimit {
                for (key,_) in written.sorted(by:{$0.value.at < $1.value.at}).prefix(written.count-Self.writtenLimit) {written.removeValue(forKey:key)}
            }
        }
        try persist()
    }
    /// fix/sx-engine-battery: a writer-wide back-off after a provider failure. Every waiting entry waits at least until
    /// `until`; nothing is retried one moment at a time meanwhile.
    public func holdAll(until:Date) throws {
        for key in Array(entries.keys) where entries[key]?.status == .queued || entries[key]?.status == .retry {
            if entries[key]!.nextAttempt < until {entries[key]!.nextAttempt=until}
        }
        try persist()
    }
    /// Entries waiting to run (queued or due for a retry), whatever their time.
    public func waitingKeys()->[String] {entries.values.filter {$0.status == .queued || $0.status == .retry}.map(\.item.key)}
    public func enqueue(_ item:ScheduledWriterTarget) throws {
        guard Self.valid(item) else {throw WriterFailure.invalidInput}
        if let previous=entries[item.key],previous.item.inputRevision==item.inputRevision,
           previous.item.policyRevision==item.policyRevision {return}
        if entries[item.key]==nil,entries.count>=limit {
            guard let old=entries.values.filter({$0.status == .completed}).min(by:{$0.nextAttempt<$1.nextAttempt}) else {throw WriterFailure.capacity}
            entries.removeValue(forKey:old.item.key)
        }
        if activeKey==item.key {operation?.cancel()}
        entries[item.key]=ScheduledWriterState(item:item,status:.queued,attempts:0,nextAttempt:max(now(),item.lastActivity.addingTimeInterval(2)))
        try persist()
    }
    /// A save that works again clears an earlier storage failure (gold/notes latch fix): a full disk that was freed, or a
    /// transient write error, no longer stops notes until relaunch. The whole ledger is written, so disk matches memory.
    public func start() throws {enabled=true;try persist()}
    public var started:Bool {enabled}
    /// Drops every entry (gold/notes G25). Core stays the note authority: whatever is still due is found again.
    public func discardAll() throws {
        operation?.cancel()
        entries.removeAll()
        try persist()
    }
    /// Pausing cancels in-flight work, retaining it for a later explicit start.
    public func pause() {enabled=false;operation?.cancel()}
    public func pauseAndDrain() async {enabled=false;let pending=operation;pending?.cancel();_ = await pending?.result}
    public func cancelAll() async throws {
        enabled=false
        for key in Array(entries.keys) {try cancel(key:key)}
        let pending=operation;pending?.cancel();_ = await pending?.result
    }
    public func retryAll() throws {
        for key in Array(entries.keys) where entries[key]?.status == .pending || entries[key]?.status == .retry || entries[key]?.status == .cancelled {try retry(key:key)}
    }
    public func cancel(key:String) throws {
        guard var entry=entries[key],entry.status != .completed else{return}
        entry.status = .cancelled;entries[key]=entry
        if activeKey==key {operation?.cancel()}
        try persist()
    }
    /// Owner calls when core no longer lists a target (deletion/correction/policy change).
    public func retainOnly(keys:Set<String>) throws {
        for key in entries.keys where !keys.contains(key) {try cancel(key:key)}
    }
    /// Only after an authoritative core read confirms this target is gone or ready.
    /// Cancels in-flight processing; its eventual result cannot recreate the entry.
    public func discard(key:String) throws {
        if activeKey==key {operation?.cancel()}
        entries.removeValue(forKey:key)
        try persist()
    }
    public func retry(key:String) throws {
        guard var entry=entries[key],entry.status != .running else{return}
        entry.status = .queued;entry.attempts=0;entry.nextAttempt=now();entries[key]=entry
        try persist()
    }
    /// Performs at most one due unit. The app owns its low-frequency discovery/tick.
    /// Returns nil when paused, busy, empty, or waiting for the bounded retry deadline.
    /// fix/sx-engine-battery: `only` limits the pick to those keys (a batch's own targets); `newestFirst` takes the most
    /// recent moment first (catch-up: newest day first) instead of the one waiting longest.
    public func runNext(preferredKey:String?=nil,only:Set<String>?=nil,newestFirst:Bool=false,process:@escaping Process) async throws -> ScheduledWriterOutcome? {
            guard enabled,!storageFailed,operation==nil,!Task.isCancelled else{return nil}
            let time=now()
            let due=entries.values.filter({($0.status == .queued || $0.status == .retry) && $0.nextAttempt<=time && (preferredKey==nil || $0.item.key==preferredKey) && (only?.contains($0.item.key) ?? true)})
            guard var entry=newestFirst ? due.max(by:{($0.item.lastActivity,$0.item.key)<($1.item.lastActivity,$1.item.key)}) : due.min(by:{$0.nextAttempt<$1.nextAttempt}) else{return nil}
            let key=entry.item.key,item=entry.item
            entry.status = .running;entry.attempts+=1;entries[key]=entry
            try persist()
            activeKey=key
            let task=Task(priority:.background){try Task.checkCancellation();return try await process(item)}
            operation=task
            let result=await withTaskCancellationHandler(operation:{await task.result},onCancel:{task.cancel()})
            operation=nil;activeKey=nil
            guard var latest=entries[key],latest.item==item,latest.status == .running else {return nil}
            if task.isCancelled || Task.isCancelled || !enabled {
                // Stopped (summaries turned off, or the app quitting): waits to run again, never cancelled for good.
                latest.status = .retry;latest.nextAttempt=now()
            } else {
                switch result {
                case .success(.committed):latest.status = .completed
                case .success(.pending):latest.status = .pending
                case .failure(WriterFailure.requestExpired):
                    // Fresh preparation is scheduling work, not a provider attempt or failure.
                    latest.status = .queued;latest.attempts=max(0,latest.attempts-1);latest.nextAttempt=now()
                default:
                    latest.status=latest.attempts>=maxAttempts ? .pending:.retry
                    latest.nextAttempt=now().addingTimeInterval(min(maxRetry,baseRetry*pow(2,Double(min(latest.attempts-1,16)))))
                }
            }
            entries[key]=latest
            try persist()
            if case .success(let outcome)=result,!task.isCancelled {return outcome}
            return .retry
    }
    private func persist() throws {
        do {
            try Self.verifyDirectory(file.deletingLastPathComponent())
            if FileManager.default.fileExists(atPath:file.path) {
                guard try FileManager.default.attributesOfItem(atPath:file.path)[.type] as? FileAttributeType == .typeRegular else {throw WriterFailure.integrity}
            }
            let data=try JSONEncoder().encode(Ledger(version:1,entries:snapshot(),localResumeEnabled:localResumeEnabled,cloudResumeVersion:cloudResumeVersion,
                                                     cloudCutoff:cloudCutoff,written:written.isEmpty ? nil : written))
            guard data.count<=1_048_576 else {throw WriterFailure.capacity}
            var template=Array(file.deletingLastPathComponent().appendingPathComponent(".writer-ledger.XXXXXX").path.utf8CString)
            let fd=mkstemp(&template)
            guard fd>=0 else {throw WriterFailure.unavailable}
            let temporary=String(cString:template)
            defer {close(fd);unlink(temporary)}
            guard fchmod(fd,0o600)==0 else {throw WriterFailure.denied}
            try data.withUnsafeBytes { raw in
                var offset=0
                while offset<raw.count {
                    let count=write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset)
                    if count<0 && errno==EINTR {continue}
                    guard count>0 else {throw WriterFailure.unavailable}
                    offset+=count
                }
            }
            guard fsync(fd)==0,rename(temporary,file.path)==0 else {throw WriterFailure.unavailable}
            let directoryFD=open(file.deletingLastPathComponent().path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
            guard directoryFD>=0 else {throw WriterFailure.unavailable}
            defer{close(directoryFD)}
            guard fsync(directoryFD)==0 else {throw WriterFailure.unavailable}
            storageFailed=false
        } catch {storageFailed=true;enabled=false;operation?.cancel();throw error}
    }
    private static func valid(_ item:ScheduledWriterTarget)->Bool {
        [item.kind,item.day,item.timezone,item.inputRevision,item.policyRevision,item.activityID ?? ""].allSatisfy{$0.utf8.count<=512 && !$0.contains("\u{1f}")} &&
        ["activity","day"].contains(item.kind) && !item.inputRevision.isEmpty && !item.policyRevision.isEmpty &&
        (item.kind != "activity" || item.activityID?.isEmpty==false) && item.lastActivity.timeIntervalSince1970.isFinite
    }
    private static func verifyDirectory(_ directory:URL)throws {
        // standardizedFileURL rewrites /private/tmp to the /tmp symlink on macOS.
        // Preserve the supplied real path and reject traversal instead.
        guard !directory.pathComponents.contains(".."),!directory.pathComponents.contains(".") else {throw WriterFailure.integrity}
        var path=directory
        while path.path != "/" {
            let attributes=try FileManager.default.attributesOfItem(atPath:path.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {throw WriterFailure.integrity}
            if path==directory {
                guard let mode=attributes[.posixPermissions] as? NSNumber,mode.intValue & 0o077 == 0 else {throw WriterFailure.denied}
            }
            path.deleteLastPathComponent()
        }
    }
}
