// DD-RECIPE: APP
// F2 app-model plumbing (plan §5 F2, amendments "F2 additions") on real MemoryViewModel instances:
//   A. a Development Trial model (synthetic store, the five seeded TextEdit actions);
//   B. a recording-trial model on an empty private store;
//   F. recording-trial models whose launch fails (a memory home that is a file; a second recorder);
//   C. a production-mode model on an empty private store (no Info.plist, so no updater or search runtime);
//   D. the pure transition-date rules;
//   E. source guarantees (preflight-only permission reads, the start/resume and save paths).
// All stores live under DD_CHECK_OUT (run-checks.sh sets it); the check refuses to run without it.
// It never starts or resumes capture on a non-development model, never opens an app and never requests
// a permission: the only permission calls are the two preflight reads. Stop and Pause run on the
// recording trial only while nothing records (they rewrite its private session row), and note
// generation runs only with the writer off, where it refuses before any work.
import AppKit
import SwiftUI
import MemoryCore
import MemoryUI

@MainActor final class DayDataRecorder {
    private(set) var events:[String]=[]
    func hooks() -> MemoryViewModel.DayDataHooks {
        MemoryViewModel.DayDataHooks(
            invalidate:{ [unowned self] day in self.events.append("invalidate:\(day)") },
            invalidateAll:{ [unowned self] in self.events.append("invalidateAll") },
            // fix/day-card: a background note commit drops cached days but keeps digests (notesChanged).
            notesChanged:{ [unowned self] in self.events.append("notesChanged") },
            noteDaysChanged:{ [unowned self] days in self.events.append("notes:"+days.sorted().joined(separator:",")) },
            refreshToday:{ [unowned self] force in self.events.append("today:\(force)") },
            refreshTodayIfStale:{ [unowned self] age in self.events.append("stale:\(Int(age))") })
    }
    func take() -> [String] { defer {events=[]}; return events }
}

func fail(_ message:String) -> Never {
    fflush(stdout)
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}
@MainActor func expect(_ condition:Bool,_ message:@autoclosure ()->String) { if !condition {fail(message())} }
func pass(_ message:String) { print("PASS: \(message)"); fflush(stdout) }
@MainActor func thrownMessage(_ body:() throws -> Void) -> String? {
    do {try body();return nil}
    catch MemError.invalid(let message) {return message}
    catch {return "\(error)"}
}
@MainActor func asyncThrownMessage(_ body:() async throws -> Void) async -> String? {
    do {try await body();return nil}
    catch MemError.invalid(let message) {return message}
    catch {return "\(error)"}
}
/// Lets main-queue work (Combine `.receive(on: DispatchQueue.main)`, the autosave debounce) run.
@MainActor func tick(_ seconds:Double=0.05) async throws { try await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000)) }
func makePrivateDirectory(_ url:URL) throws {
    try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path)
}
/// The text of the first `{…}` block after `signature` (brace counting; the bodies checked hold no braces in strings).
func body(of signature:String,in source:String) -> String {
    guard let start=source.range(of:signature),let open=source[start.lowerBound...].firstIndex(of:"{") else {fail("source: \(signature) not found")}
    var depth=0,index=open
    while index < source.endIndex {
        if source[index] == "{" {depth += 1}
        if source[index] == "}" {depth -= 1;if depth == 0 {return String(source[open...index])}}
        index=source.index(after:index)
    }
    fail("source: \(signature) has no closing brace")
}

@main @MainActor struct DDAppModelChecks {
    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline:.now()+90) {
            FileHandle.standardError.write(Data("FAIL: dd-app-model-checks watchdog expired after 90s\n".utf8))
            exit(2)
        }
        // Codex's shared roots, spelled so run-checks.sh's rewrite of the literal prefix leaves them intact.
        let shared=["/private/tmp/"+"day"+"dream-","/tmp/"+"day"+"dream-"]
        guard let outPath=ProcessInfo.processInfo.environment["DD_CHECK_OUT"],outPath.hasPrefix("/"),
              !shared.contains(where:{outPath.hasPrefix($0)}) else {
            fail("DD_CHECK_OUT is not a private output directory; run this check through run-checks.sh")
        }
        let out=URL(fileURLWithPath:outPath,isDirectory:true)
        try makePrivateDirectory(out)

        try transitionDates()
        try sources()
        let development=try await developmentModel(shared:shared)
        let trial=try await recordingTrialModel(out:out)
        try storageFailureModels(out:out,liveMemory:MemPaths.home())
        let production=try await productionModel(out:out)

        for (name,model) in [("development",development),("recording trial",trial),("production",production)] {
            expect(!model.recording && model.stopped && model.noteWriter.provider == "off",
                   "\(name) model ended recording=\(model.recording) stopped=\(model.stopped) provider=\(model.noteWriter.provider)")
        }
        pass("end: every model stopped, not recording, summaries provider off; nothing started or opened")
    }

    // MARK: D. Transition dates (pure)
    static func transitionDates() throws {
        typealias Dates=MemoryViewModel.CaptureTransitionDates
        let t1=Date(timeIntervalSince1970:1_800_000_000),t2=t1+60,t2b=t1+90,t3=t1+120,t4=t1+180,t5=t1+240
        var dates=Dates()
        expect(dates.recordingSince == nil && dates.pausedAt == nil && dates.stoppedAt == nil,"launch dates are not all nil")
        dates.recordingStarted(at:t1)
        expect(dates.recordingSince == t1 && dates.pausedAt == nil && dates.stoppedAt == nil,"start T1: \(dates)")
        dates.paused(fromRecording:true,at:t2)
        expect(dates.recordingSince == nil && dates.pausedAt == t2 && dates.stoppedAt == nil,"pause T2: \(dates)")
        dates.paused(fromRecording:false,at:t2b)
        expect(dates.pausedAt == t2,"a second pause (sleep, then wake) moved pausedAt: \(dates)")
        dates.recordingStarted(at:t3)
        expect(dates.recordingSince == t3 && dates.pausedAt == nil && dates.stoppedAt == nil,"timed auto-resume T3: \(dates)")
        expect(RecordingState.derive(RecordingStateInputs(recording:true,stopped:false,recordingSince:dates.recordingSince)) == .recording(since:t3),
               "derive does not show the auto-resume time")
        dates.stopped(at:t4)
        expect(dates.stoppedAt == t4 && dates.recordingSince == nil && dates.pausedAt == nil,"stop T4: \(dates)")
        dates.paused(fromRecording:false,at:t5)
        expect(dates.pausedAt == t5 && dates.stoppedAt == nil && dates.recordingSince == nil,"pause after Off T5: \(dates)")
        dates.recordingStarted(at:t1);dates.notRecording()
        expect(dates.recordingSince == nil && dates.pausedAt == nil && dates.stoppedAt == nil,"notRecording kept a start time: \(dates)")
        pass("transition dates: start T1 → pause T2 (a later pause keeps T2) → timed auto-resume T3 shows since T3 → stop T4 clears the others")
    }

    // MARK: E. Source guarantees
    static func sources() throws {
        let app=try String(contentsOfFile:"Sources/MacMemApp/MacMemApp.swift",encoding:.utf8)
        let code=app.split(separator:"\n",omittingEmptySubsequences:false)
            .filter {!$0.trimmingCharacters(in:.whitespaces).hasPrefix("//")}.joined(separator:"\n")
        for banned in ["AXIsProcessTrustedWithOptions","CGRequestListenEventAccess","kAXTrustedCheckOptionPrompt","checked_at"] {
            expect(!code.contains(banned),"MacMemApp.swift uses \(banned)")
        }
        let read=body(of:"private func readPermissions()",in:code)
        expect(read.contains("AXIsProcessTrusted()") && read.contains("CGPreflightListenEventAccess()"),"readPermissions does not use the two preflight reads")
        pass("permissions: MacMemApp.swift reads AXIsProcessTrusted() and CGPreflightListenEventAccess() only; no request API, no checked_at")

        let start=body(of:"func startCapture()",in:code)
        expect(start.contains("defer {if recording && !wasRecording {transitions.recordingStarted(at:activity.now())}}"),
               "startCapture does not stamp recordingSince on every false → true transition")
        expect(start.contains("guard !privacyDirty,preferenceSave?.draft == nil,preferenceSave?.error == nil"),"startCapture lost its unsaved-preferences guard")
        // SPEC 6.3: the timer lives in armTimedPause, so a timed pause a sleep interrupted can be picked up too.
        let timed=body(of:"func pauseFor(minutes:Int)",in:code)
        expect(timed.contains("armTimedPause(ticket)"),"pauseFor no longer arms the timed-pause timer")
        let armed=body(of:"private func armTimedPause(_ ticket:TimedPause.Ticket)",in:code)
        // gold/int final review (G33): through automaticStart, which holds for a moment's "not allowed" and calls startCapture.
        expect(armed.contains("if resume { self.timedPauseEnded(); return }")
               && body(of:"private func timedPauseEnded()",in:code).contains("automaticStart(again:{ [weak self] in self?.timedPauseEnded() })")
               && body(of:"private func automaticStart(again:@escaping ()->Void) -> AutomaticStart",in:code).contains("if !recording {startCapture()}"),
               "the timed-pause resume no longer goes through startCapture")
        pass("recordingSince: startCapture stamps every false → true transition, and the timed-pause resume calls startCapture")

        let exclude=body(of:"func excludeApp(_ bundle:String) throws",in:code)
        guard let queued=exclude.range(of:"queuePreferences()"),let flushed=exclude.range(of:"preferenceSave?.flush()") else {fail("excludeApp does not queue and flush")}
        expect(queued.lowerBound < flushed.lowerBound,"excludeApp flushes before it queues")
        expect(exclude.contains("if preferenceSave?.failed == true {throw MemError.invalid((preferenceProblem ?? .notSaved).text)}"),"excludeApp does not surface the one-sentence problem")
        let generate=body(of:"activity.generateCanonicalNote = {",in:code)
        expect(generate.contains("defer { self.noteWriterFinished(day:day,timezone:zone) }"),"generateCanonicalNote does not report completion")
        guard let started=generate.range(of:"self.noteWriterStarted()"),let finished=generate.range(of:"defer { self.noteWriterFinished(") else {
            fail("generateCanonicalNote does not mark its generation in flight")
        }
        expect(started.lowerBound < finished.lowerBound,"generateCanonicalNote marks its generation in flight after its completion defer")
        let inputs=body(of:"var recordingInputs:RecordingStateInputs",in:code)
        expect(inputs.contains("session?.state == \"permission_denied\" && permissionSnapshot.allGranted == true"),"recordingInputs lost the stale-denial rule")
        let presentation=body(of:"var presentation:CapturePresentation",in:code)
        expect(presentation.contains("CapturePresentation(title:shortState,") && presentation.contains("presentation.state=recordingState"),
               "presentation no longer keeps the legacy title and the derived state")
        pass("save and notes: excludeApp queues then flushes and throws the one-sentence problem; note generation reports its day; presentation keeps shortState")

        let writer=try String(contentsOfFile:"Sources/MacMemApp/WriterIntegration.swift",encoding:.utf8)
        guard let line=writer.split(separator:"\n").first(where:{$0.contains("case .committed:status=")}) else {fail("WriterIntegration has no committed status")}
        let statuses=line.split(separator:"\"",omittingEmptySubsequences:false).enumerated().filter {$0.offset % 2 == 1}.map {String($0.element)}.filter {$0 != "cloud"}
        expect(statuses.count == 2 && statuses.allSatisfy {$0.hasPrefix(MemoryViewModel.noteSavedStatus)},
               "WriterIntegration commit statuses \(statuses) do not start with \(MemoryViewModel.noteSavedStatus)")
        pass("background notes: both WriterIntegration commit statuses start with \"\(MemoryViewModel.noteSavedStatus)\"")

        let flows=try String(contentsOfFile:"Sources/MacMemApp/MemoryFlows.swift",encoding:.utf8)
        let adopt=body(of:"func adopt()",in:flows)
        guard let opening=adopt.range(of:"status=\"") else {fail("MemoryFlows.adopt sets no status")}
        let added=String(adopt[opening.upperBound...].prefix {$0 != "\""})
        expect(added.hasPrefix(MemoryViewModel.historyAddedStatus),"MemoryFlows.adopt's status \"\(added)\" does not start with \(MemoryViewModel.historyAddedStatus)")
        pass("history import: MemoryFlows.adopt's success status starts with \"\(MemoryViewModel.historyAddedStatus)\"")

        // Once ActivityBrowser has the day cache (F0b), the seam must reach it: unbound hooks are no-ops.
        let memoryUI=try FileManager.default.contentsOfDirectory(atPath:"Sources/MemoryUI").filter {$0.hasSuffix(".swift")}.sorted()
            .map {try String(contentsOfFile:"Sources/MemoryUI/"+$0,encoding:.utf8)}.joined(separator:"\n")
        if memoryUI.range(of:#"var\s+dayCache\b"#,options:.regularExpression) != nil {
            // The binding, not the no-op declaration `var dayData=DayDataHooks()`.
            let bound=code.range(of:#"(?<!var )dayData\s*=\s*DayDataHooks\(\s*invalidate\s*:"#,options:.regularExpression) != nil
            let targets=["dayCache.invalidate(","dayCache.invalidateAll()","today.refresh(force:","today.refreshIfStale(maxAge:"]
            let missing=targets.filter {!code.contains($0)}
            expect(bound && missing.isEmpty,"ActivityBrowser has dayCache but MacMemApp.swift does not bind dayData to it (F2 contract request 1); missing \(bound ? missing:["dayData=DayDataHooks(invalidate:"]+missing)")
            pass("day data: dayData is bound to activity.dayCache and activity.today")
        } else {
            pass("day data: ActivityBrowser has no dayCache yet, so dayData keeps its no-op hooks (F2 contract request 1)")
        }
    }

    // MARK: A. Development Trial model
    static func developmentModel(shared:[String]) async throws -> MemoryViewModel {
        let root=URL(fileURLWithPath:"/private/tmp/daydream-development-trial-"+UUID().uuidString)
        expect(!shared.contains(where:{root.path.hasPrefix($0)}),"development root was not redirected: \(root.path)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        for name in ["memory","preferences","backups"] {
            try FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:false)
        }
        try Data("synthetic-only\n".utf8).write(to:root.appendingPathComponent("DEVELOPMENT-ONLY"))
        setenv("DAYDREAM_DEVELOPMENT_ROOT",root.path,1)
        setenv("MAC_MEM_HOME",root.appendingPathComponent("memory").path,1)
        setenv("CFFIXED_USER_HOME",root.appendingPathComponent("preferences").path,1)
        let trial=try DevelopmentTrial.validate()
        try trial.prepare()
        let model=MemoryViewModel(development:trial)
        for _ in 0..<100 {if !model.history.busy {break};try await tick(0.01)}
        let activity=model.activity

        let off=RecordingState.off(since:nil,reason:"Development Trial · recording is disabled")
        expect(model.recordingState == off,"development recordingState is \(model.recordingState)")
        expect(model.presentation.state == off,"development presentation.state is \(model.presentation.state)")
        expect(model.presentation.title == "Development Trial · OFF","legacy title changed: \(model.presentation.title)")
        expect(model.presentation.permissions == nil && model.permissionsCheckedAt == nil && model.permissionSnapshot == PermissionSnapshot(),
               "the Development Trial read permissions")
        pass("development: presentation.state == recordingState == Off \"Development Trial · recording is disabled\"; legacy title kept; permissions never read")

        expect(activity.openApp == nil && activity.excludeApp == nil,"development offers openApp or excludeApp")
        expect(activity.reopenCanonical == nil && activity.generateCanonicalNote == nil,"development offers reopen or note generation")
        expect(activity.searchCanonical != nil && (activity.searchCanonicalQuery != nil) == (activity.searchCanonical != nil),
               "searchCanonicalQuery is not set exactly when searchCanonical is")
        expect(activity.openSettingsSection != nil,"openSettingsSection is not wired")
        pass("development: openApp and excludeApp nil, reopen and note generation nil, searchCanonicalQuery set exactly when searchCanonical is")

        let legacy=try await activity.searchCanonical!("research",nil)
        let query=try await activity.searchCanonicalQuery!(MemorySearchQuery("research"))
        expect(legacy.items.count == 5 && query.items.map(\.id) == legacy.items.map(\.id),
               "searchCanonicalQuery found \(query.items.count), searchCanonical \(legacy.items.count)")
        let small=try await activity.searchCanonicalQuery!(MemorySearchQuery("research",limit:2))
        expect(small.items.count == 5,"searchCanonicalQuery did not use the 50-result page: \(small.items.count)")
        let app=try await activity.searchCanonicalQuery!(MemorySearchQuery("research",app:"com.apple.TextEdit"))
        let otherApp=try await activity.searchCanonicalQuery!(MemorySearchQuery("research",app:"com.example.none"))
        let later=try await activity.searchCanonicalQuery!(MemorySearchQuery("research",start:Date().addingTimeInterval(86_400)))
        expect(app.items.count == 5 && otherApp.items.isEmpty && later.items.isEmpty,
               "filters were dropped: app \(app.items.count), other app \(otherApp.items.count), later \(later.items.count)")
        pass("development: searchCanonicalQuery matches searchCanonical, pages 50 and keeps app and date filters")

        let own="com.getnorthlight.daydream"
        let policy=try MemoryStore(home:trial.memory,automaticallySyncSearch:false).policy()
        let expected=ExclusionSummary.make(blockedApps:policy.blockedApps) {NSWorkspace.shared.urlForApplication(withBundleIdentifier:$0) != nil}
        expect(PrivacySettings.sensitiveApps.contains(own),"the own bundle is not a sensitive app")
        expect(!activity.exclusions.alwaysPrivate.contains(own) && !activity.exclusions.excludedByYou.contains(own),"exclusions list \(own)")
        expect(Set(activity.exclusions.alwaysPrivate).isSubset(of:Set(PrivacySettings.sensitiveApps)) && activity.exclusions == expected,
               "exclusions \(activity.exclusions) are not the saved policy's \(expected)")
        pass("development: activity.exclusions mirrors the saved policy and never lists \(own)")

        expect(activity.summaries == SummaryAvailability(provider:.off,busy:false,downloadProgress:nil),"summaries start as \(activity.summaries)")
        model.noteWriter.progress=0.25
        expect(activity.summaries.downloadProgress == 0.25,"download progress did not follow the writer: \(activity.summaries)")
        model.noteWriter.busy=true
        expect(activity.summaries.busy && activity.summaries.downloadProgress == 0.25,"busy did not follow the writer: \(activity.summaries)")
        model.noteWriter.progress=nil;model.noteWriter.busy=false
        expect(activity.summaries == SummaryAvailability(provider:.off,busy:false),"summaries did not return to off: \(activity.summaries)")
        pass("development: activity.summaries follows the writer's provider, busy and real progress, and shows no progress without one")

        model.startCapture();model.pauseFor(minutes:5);model.stopCapture()
        expect(!model.recording && model.pauseUntil == nil && model.recordingState == off,"development capture controls changed state")
        expect(model.recordingSince == nil && model.pausedAt == nil && model.stoppedAt == nil,"development capture controls stamped dates")
        activity.openSettingsSection?("Recording")
        expect(model.settingsSection == "Recording" && model.settingsPresented,"openSettingsSection did not open Settings at Recording")
        model.settingsPresented=false;model.settingsSection="General"
        pass("development: Start, Pause and Stop stay Off with no dates; openSettingsSection opens Settings at the section")

        // The bound hooks reach the real day cache: a finished note drops its cached day.
        let zone0=activity.calendar.timeZone.identifier
        let key=activity.dayCache.syncTodayKey() ?? "2026-09-22"
        _=try await activity.dayCache.day(key)
        expect(activity.dayCache.cachedDay(key) != nil,"the day cache did not keep \(key)")
        model.noteWriterFinished(day:key,timezone:zone0)
        expect(activity.dayCache.cachedDay(key) == nil,"a finished note left \(key) cached: dayData is not bound")
        _=try await activity.dayCache.day(key)
        model.noteWriter.status="Generated note saved locally"
        expect(activity.dayCache.cachedDay(key) != nil,"status text alone invalidated a cached day")
        model.noteWriter.onNotesCommitted?([NoteCommitScope(day:key,timezone:zone0)])
        expect(activity.dayCache.cachedDay(key) == nil,"an actual committed scope left \(key) cached")
        pass("development: dayData reaches activity.dayCache (a finished note and a background commit drop the cached day)")
        let recorder=DayDataRecorder()
        model.dayData=recorder.hooks()
        let store=try MemoryStore(home:trial.memory,automaticallySyncSearch:false)
        guard let action=try store.action(legacy.items[0].id) else {fail("seeded action missing")}
        try activity.correctCanonical!(MemoryActionScope(kind:"action",id:action.id),"Development model correction",action.revision)
        expect(recorder.take() == ["invalidateAll","today:true"],"a correction did not drop cached days and refresh Today")
        let preview=try activity.previewCanonicalDelete!(MemoryActionScope(kind:"action",id:legacy.items[1].id))
        expect(recorder.take().isEmpty,"a deletion preview touched day data")
        try activity.confirmCanonicalDelete!(preview.id)
        expect(recorder.take() == ["invalidateAll","today:true"],"a deletion did not drop cached days and refresh Today")
        let zone=activity.calendar.timeZone.identifier
        let todayKey=try DayScope.key(activity.now(),timezone:zone)
        let pastKey=try DayScope.key(activity.now().addingTimeInterval(-86400),timezone:zone)
        model.noteWriterFinished(day:pastKey,timezone:zone)
        expect(recorder.take() == ["notes:"+pastKey],"a finished past note refreshed unrelated Today")
        let foreign=zone == "Pacific/Chatham" ? "Asia/Kathmandu":"Pacific/Chatham"
        model.noteWriterFinished(day:pastKey,timezone:foreign)
        expect(recorder.take() == ["notesChanged","today:true"],"a note in another time zone lost the conservative fallback")
        model.refresh()
        expect(recorder.take() == ["today:false"],"refresh() did not ask Today to refresh")
        pass("finished notes: affected day only; timezone mismatch falls back; memory corrections/deletions still invalidate all")

        let status=model.noteWriter.status
        for text in ["Generated note saved locally","Generated note saved. Processed Using ZDR Endpoints","Local model not set up. Recording stays off."] {
            model.noteWriter.status=text
            try await tick()
            expect(recorder.take().isEmpty,"status text was treated as a commit receipt")
        }
        model.noteWriter.onNotesCommitted?([NoteCommitScope(day:pastKey,timezone:zone)])
        expect(recorder.take() == ["notes:"+pastKey],"past committed scope touched unrelated Today")
        model.noteWriter.onNotesCommitted?([NoteCommitScope(day:todayKey,timezone:zone)])
        expect(recorder.take() == ["notes:"+todayKey,"today:true"],"Today committed scope did not force Today")
        model.noteWriter.onNotesCommitted?([NoteCommitScope(day:todayKey,timezone:zone),NoteCommitScope(day:pastKey,timezone:zone),NoteCommitScope(day:pastKey,timezone:zone)])
        expect(recorder.take() == ["notes:"+[todayKey,pastKey].sorted().joined(separator:","),"today:true"],"duplicate/multiple scopes were not coalesced")
        model.noteWriter.onNotesCommitted?(nil)
        expect(recorder.take() == ["notesChanged","today:true"],"unknown commit scope lost global fallback")
        model.noteWriter.onNotesCommitted?([])
        expect(recorder.take().isEmpty,"empty commit scopes invalidated day data")
        pass("committed metadata scopes: past/today/multiple/duplicate/unknown; status, pending and retry words confer no write authority")

        model.noteWriterStarted()
        model.noteWriter.onNotesCommitted?([NoteCommitScope(day:pastKey,timezone:zone)])
        expect(recorder.take().isEmpty,"a foreground commit invalidated before its final read")
        model.noteWriterFinished(day:pastKey,timezone:zone)
        expect(recorder.take() == ["notes:"+pastKey],"a foreground past note refreshed unrelated Today")
        model.noteWriterStarted();model.noteWriterStarted()
        model.noteWriter.onNotesCommitted?([NoteCommitScope(day:pastKey,timezone:zone),NoteCommitScope(day:todayKey,timezone:zone)])
        model.noteWriterFinished(day:pastKey,timezone:zone)
        expect(recorder.take().isEmpty,"overlapping foreground notes refreshed early")
        model.noteWriterFinished(day:todayKey,timezone:zone)
        expect(recorder.take() == ["notes:"+[todayKey,pastKey].sorted().joined(separator:","),"today:true"],"foreground/background scopes were lost or repeated")
        model.noteWriterStarted();model.noteWriter.onNotesCommitted?(nil)
        model.noteWriterFinished(day:pastKey,timezone:zone)
        expect(recorder.take() == ["notesChanged","today:true"],"unknown foreground commit scope lost fallback")
        // A failed/pending foreground generation may change its note state even without a model answer.
        model.noteWriterStarted();model.noteWriterFinished(day:pastKey,timezone:zone)
        expect(recorder.take() == ["notes:"+pastKey],"a noncommitted foreground finish left the selected past day stale")
        model.noteWriter.status=status
        try await tick();expect(recorder.take().isEmpty,"restored status caused an invalidation")
        pass("foreground completion preserves committed scopes, unknown fallback and pending/failure selected-day visibility")

        model.history.status="Reviewed history added. Existing memory retained. Capture remains OFF."
        try await tick()
        expect(recorder.take() == ["invalidateAll","today:false"],"a history import did not drop cached days and refresh")
        model.history.status="Import cancelled. Existing memory is unchanged."
        try await tick()
        expect(recorder.take().isEmpty,"a history status that adds nothing invalidated day data")
        model.history.status=""
        pass("development: a history import drops every cached day and refreshes; other import statuses do not")

        expect(thrownMessage {try model.excludeApp("dev.zed.Zed")} == "Preferences can't be saved here. Nothing was excluded.",
               "the Development Trial excluded an app")
        expect(!model.canExcludeApps && activity.excludeApp == nil && recorder.take().isEmpty,"the Development Trial offers Exclude")
        expect(!model.recording && model.noteWriter.provider == "off","development model is not off")
        pass("development: excludeApp refuses with nothing saved, and recording and summaries stay off")
        return model
    }

    // MARK: B. Recording-trial model
    static func recordingTrialModel(out:URL) async throws -> MemoryViewModel {
        let home=out.appendingPathComponent("recording-trial-"+UUID().uuidString,isDirectory:true)
        let memory=home.appendingPathComponent("memory",isDirectory:true)
        try makePrivateDirectory(home);try makePrivateDirectory(memory)
        setenv("MAC_MEM_HOME",memory.path,1)
        let model=MemoryViewModel(recordingTrial:true)
        expect(model.recordingTrial && model.development == nil && model.preferencesAvailable,"recording-trial model did not open its private store: \(model.status)")
        let activity=model.activity
        expect(activity.openApp == nil && activity.excludeApp == nil && activity.generateCanonicalNote == nil,"the recording trial offers openApp, excludeApp or notes")
        expect(activity.searchCanonicalQuery != nil && activity.searchCanonical != nil,"the recording trial has no searchCanonicalQuery")
        let empty=try await activity.searchCanonicalQuery!(MemorySearchQuery("anything"))
        expect(empty.items.isEmpty,"the empty trial store returned \(empty.items.count) results")
        expect(!model.recording && model.stopped && model.noteWriter.provider == "off","the recording trial started something")
        pass("recording trial: openApp and excludeApp nil, searchCanonicalQuery set, Off with summaries off")

        let fresh=PermissionSnapshot(accessibility:AXIsProcessTrusted(),inputMonitoring:CGPreflightListenEventAccess())
        model.checkPermissions()
        expect(model.permissionSnapshot == fresh && model.presentation.permissions == fresh && model.permissionsCheckedAt != nil,
               "permission snapshot \(model.permissionSnapshot) is not the preflight read \(fresh)")
        let inputs=model.recordingInputs
        expect(inputs.accessibilityGranted == fresh.accessibility && inputs.inputMonitoringGranted == fresh.inputMonitoring && !inputs.development
               && inputs.recordingSince == nil && inputs.pausedAt == nil && inputs.stoppedAt == nil,"recordingInputs \(inputs)")
        expect(model.recordingState == RecordingState.derive(inputs) && model.presentation.state == model.recordingState,"recordingState is not derived from recordingInputs")
        if model.resumeUnavailable == RecordingCopy.permissionBlocker {
            expect(model.recordingState == .needsPermission(missing:fresh.missing),"missing permissions show as \(model.recordingState)")
        } else {
            expect(model.recordingState.kind == .off,"a stopped trial shows \(model.recordingState)")
        }
        pass("recording trial: permissions are the preflight reads (\(fresh.accessibility == true ? "AX granted":"AX missing"), \(fresh.inputMonitoring == true ? "IM granted":"IM missing")); presentation.state \(model.recordingState.kind.rawValue) is derived from recordingInputs")

        let recorder=DayDataRecorder()
        model.dayData=recorder.hooks()
        var changes=0,unchanged=0
        let steps:[(String,()->Void)]=[
            ("replacement busy",{model.replacementBusy=true}),
            ("open-ended pause",{model.replacementBusy=false;model.stopped=false}),
            ("stopped",{model.stopped=true}),
            ("nothing",{})]
        for (label,apply) in steps {
            let before=model.recordingState.kind
            apply();model.refreshCaptureStatus()
            let after=model.recordingState.kind
            let events=recorder.take()
            expect(events == (after != before ? ["today:false"]:[]),"\(label): \(before.rawValue) → \(after.rawValue) refreshed Today \(events)")
            if after != before {changes += 1} else {unchanged += 1}
        }
        model.refreshCaptureStatus()
        expect(recorder.take().isEmpty && changes > 0 && unchanged > 0,"kind changes \(changes), unchanged \(unchanged)")
        expect(model.stopped && !model.replacementBusy && !model.recording,"the trial did not return to Off")
        pass("recording trial: Today refreshes once per recording-state kind change (\(changes) changes) and not otherwise (\(unchanged))")

        let reader=try MemoryStore(home:memory,automaticallySyncSearch:false)
        let domains=model.blockedDomains
        try model.excludeApp("dev.zed.Zed")
        expect(recorder.take().contains("invalidateAll"),"a policy save did not drop cached days")
        expect(activity.exclusions.excludedByYou.contains("dev.zed.Zed"),"exclusions did not update: \(activity.exclusions.excludedByYou)")
        expect(model.privacySaveStatus.hasPrefix("Saved preferences. Recording is stopped."),"save status: \(model.privacySaveStatus)")
        expect(try reader.policy().blockedApps.contains("dev.zed.Zed") && !model.preferencesUnresolved,"the exclusion was not saved")
        expect(model.stopped && !model.recording && model.stoppedAt == nil && model.recordingSince == nil,"a save while Off stamped a stop or started something")
        expect(activity.excludeApp == nil,"the recording trial gained an excludeApp hook")
        pass("recording trial: excludeApp saves through the Settings path, updates exclusions, invalidates day data and leaves recording stopped")

        let revision=try reader.policy().revision
        try model.excludeApp("dev.zed.Zed")
        expect(try reader.policy().revision == revision && recorder.take().isEmpty,"excluding an excluded app saved again")
        for (bundle,message) in [("com.apple.Passwords","This app is always private."),("com.getnorthlight.daydream","This app is always private."),
                                 ("not an app id!","This app can't be excluded. Nothing was saved."),(".hidden","This app can't be excluded. Nothing was saved.")] {
            expect(thrownMessage {try model.excludeApp(bundle)} == message,"excluding \(bundle) did not refuse with \(message)")
        }
        expect(try reader.policy().revision == revision && !model.preferencesUnresolved,"a refused exclusion left a draft or a save")
        model.blockedDomains="example.com"
        expect(model.preferencesUnresolved,"an unsaved domain edit is not unresolved")
        expect(thrownMessage {try model.excludeApp("com.example.editor")} == "Your saved choices changed while this page was open. Nothing was excluded.",
               "excludeApp ran over unsaved preferences")
        expect(model.preferenceProblem == .changedElsewhere && model.preferenceProblem?.buttonTitle == "Use saved choices",
               "an unsaved edit with no save waiting is not one sentence with Use saved choices")
        model.blockedDomains=domains
        expect(try !model.preferencesUnresolved && reader.policy().revision == revision,"reverting the domain edit did not resolve it")
        pass("recording trial: repeat, always-private, invalid and unsaved-preferences exclusions refuse without saving")

        let elsewhere=try MemoryStore(home:memory,writable:true,automaticallySyncSearch:false)
        _=try elsewhere.savePreferences(MemoryPreferences(blockedApps:["dev.zed.Zed","com.example.elsewhere"],nativeTyping:false),expectedRevision:try elsewhere.policy().revision)
        let conflict=thrownMessage {try model.excludeApp("com.example.third")}
        expect(conflict == "Your app choices changed in another window, so this change didn't save." && model.preferenceProblem == .conflict
               && model.privacySaveStatus == "Not saved. Your app choices changed in another window. Recording is stopped.",
               "a revision conflict surfaced \(conflict ?? "nothing") / \(model.privacySaveStatus)")
        expect(try model.preferencesUnresolved && !reader.policy().blockedApps.contains("com.example.third"),"a conflicting exclusion was saved")
        expect(model.stopped && !model.recording,"a conflicting save left recording on")
        _=recorder.take()
        model.reloadPreferences()
        expect(!model.preferencesUnresolved && activity.exclusions.excludedByYou.sorted() == ["com.example.elsewhere","dev.zed.Zed"],
               "reload did not adopt the other save: \(activity.exclusions.excludedByYou)")
        expect(recorder.take().contains("invalidateAll"),"reloading a newer policy did not drop cached days")
        expect(!model.recording && model.noteWriter.provider == "off","recording-trial model is not off")
        pass("recording trial: a revision conflict throws one sentence and saves nothing; reload adopts the other policy")

        // Stop, Pause and the preference save stamp their times through the model's clock. The trial is
        // put in an open-ended pause by hand: nothing records, and only its private session row changes.
        let t0=Date(timeIntervalSince1970:1_900_000_000)
        activity.now={t0}
        model.stopped=false;model.refreshCaptureStatus()
        expect(!model.recording && !model.stopped && model.stoppedAt == nil && model.pausedAt == nil,"the trial is not in an open-ended pause")
        model.stopCapture()
        expect(model.stopped && model.stoppedAt == t0 && model.pausedAt == nil && model.recordingSince == nil && model.recordingInputs.stoppedAt == t0,
               "Stop from a pause: stoppedAt \(String(describing:model.stoppedAt)), pausedAt \(String(describing:model.pausedAt))")
        activity.now={t0+60}
        model.stopCapture()
        expect(model.stoppedAt == t0,"a Stop while already Off moved stoppedAt to \(String(describing:model.stoppedAt))")
        activity.now={t0+120}
        model.stopped=false;model.pauseCapture()
        expect(!model.stopped && !model.recording && model.pausedAt == t0+120 && model.stoppedAt == nil && model.recordingInputs.pausedAt == t0+120,
               "Pause: pausedAt \(String(describing:model.pausedAt)), stoppedAt \(String(describing:model.stoppedAt))")
        activity.now={t0+180}
        model.pauseCapture("Paused for sleep. Resume explicitly after waking.")
        expect(model.pausedAt == t0+120 && !model.stopped,"a second pause moved pausedAt to \(String(describing:model.pausedAt))")
        activity.now={t0+240}
        try model.excludeApp("com.example.fourth")
        expect(model.stopped && !model.recording && model.stoppedAt == t0+240 && model.pausedAt == nil && model.recordingSince == nil,
               "an exclusion saved while paused: stoppedAt \(String(describing:model.stoppedAt)), pausedAt \(String(describing:model.pausedAt))")
        expect(try reader.policy().blockedApps.contains("com.example.fourth") && !model.preferencesUnresolved,"the exclusion made while paused was not saved")
        activity.now=Date.init
        _=recorder.take()
        pass("recording trial: Stop from a pause stamps stoppedAt (a second Stop keeps it), Pause stamps pausedAt (a second pause keeps it), and a save while paused stamps stoppedAt")
        return model
    }

    // MARK: F. Launch failures (recording-trial models; nothing opens and nothing starts)
    static func storageFailureModels(out:URL,liveMemory:URL) throws {
        let file=out.appendingPathComponent("memory-file-"+UUID().uuidString)
        try Data("not a memory directory\n".utf8).write(to:file)
        let unavailable=RecordingState.off(since:nil,reason:"Storage needs attention. Nothing is recorded.")
        // A second copy of DayDream holding the recorder lock is named as that, not as a storage problem.
        // gold r2: one short line that tells nobody to quit anything.
        let anotherCopy=RecordingState.off(since:nil,reason:"DayDream is already open.")
        // The live trial model (part B) still holds capture.lock in liveMemory, so a second recorder there fails.
        for (label,home,status,state) in [("a memory home that is a regular file",file,"Storage unavailable. No capture started.",unavailable),
                                          ("a second recorder on a live memory directory",liveMemory,"Another copy of DayDream is open. No capture started.",anotherCopy)] {
            setenv("MAC_MEM_HOME",home.path,1)
            let model=MemoryViewModel(recordingTrial:true)
            expect(model.status == status && !model.preferencesAvailable,"\(label): the model opened (\(model.status))")
            expect(model.recordingState == state && model.presentation.state == state,"\(label): state \(model.recordingState)")
            expect(model.presentation.title == "Setup required","\(label): legacy title \(model.presentation.title)")
            let line=model.recordingState.attentionLine(issue:model.presentation.issue,now:Date(),timeZone:.current)
            expect(line == nil,"\(label): attention line \(line ?? "") contradicts the state")
            expect(!model.recording && model.stopped && model.noteWriter.provider == "off","\(label): something started")
        }
        pass("launch failures: a broken store reads Off \"Storage needs attention. Nothing is recorded.\", a second recorder reads Off \"DayDream is already open.\", with no setup prompt")
    }

    // MARK: C. Production-mode model (private store; openApp is never called)
    static func productionModel(out:URL) async throws -> MemoryViewModel {
        let home=out.appendingPathComponent("production-"+UUID().uuidString,isDirectory:true)
        let memory=home.appendingPathComponent("memory",isDirectory:true)
        try makePrivateDirectory(home);try makePrivateDirectory(memory)
        setenv("MAC_MEM_HOME",memory.path,1)
        let model=MemoryViewModel()
        try await tick()
        expect(!model.recordingTrial && model.development == nil && model.preferencesAvailable,"production model did not open its private store: \(model.status)")
        expect(!model.updates.canCheck,"the updater started in a check")
        let activity=model.activity
        expect(activity.openApp != nil && activity.excludeApp != nil && model.canExcludeApps,"production does not offer openApp and excludeApp")
        expect(activity.searchCanonicalQuery != nil && activity.searchCanonical != nil && activity.openSettingsSection != nil,"production search or settings hook missing")
        expect(model.permissionsCheckedAt != nil && model.presentation.permissions == model.permissionSnapshot,"production did not read permissions")
        pass("production: openApp, excludeApp, searchCanonicalQuery and openSettingsSection are wired")

        let domains=model.blockedDomains
        model.blockedDomains="example.com"
        try await tick()
        expect(activity.excludeApp == nil && !model.canExcludeApps,"excludeApp is offered over unsaved preferences")
        model.blockedDomains=domains
        try await tick()
        expect(activity.excludeApp != nil,"excludeApp did not come back once preferences resolved")
        pass("production: excludeApp is nil while preferences are unsaved and returns once they resolve")

        let recorder=DayDataRecorder()
        model.dayData=recorder.hooks()
        try await activity.excludeApp!("dev.zed.Zed")
        expect(activity.exclusions.excludedByYou.contains("dev.zed.Zed") && recorder.events.contains("invalidateAll"),"the hook did not save: \(activity.exclusions)")
        let refused=await asyncThrownMessage {try await activity.excludeApp!("com.1password.1password")}
        expect(refused == "This app is always private.","the hook excluded an always-private app: \(refused ?? "no error")")
        try await tick()
        expect(activity.excludeApp != nil && !model.preferencesUnresolved,"the hook disappeared after a successful save")

        // The real Summarize Now closure, with the writer off: it refuses before any work, still reports its
        // day, and leaves no generation counted in flight (a later commit drops every day at once).
        for _ in 0..<100 {if !model.history.busy {break};try await tick(0.01)}
        expect(!model.history.busy && !model.backups.busy && model.backups.prepared == nil,"a history or backup operation is still running")
        _=recorder.take()
        let zone=activity.calendar.timeZone.identifier
        let refusedNote=await asyncThrownMessage {try await activity.generateCanonicalNote!("2026-09-21",zone,"no-such-action",Date())}
        expect(refusedNote != nil && model.noteWriter.provider == "off","note generation ran with the writer off")
        // 6d815a8: selected past day changes through notes metadata; unrelated Today stays cached.
        expect(recorder.take() == ["notes:2026-09-21"],"a refused foreground note did not refresh its selected past day")
        model.noteWriter.status="Generated note saved locally"
        expect(recorder.take().isEmpty,"status text incorrectly counted as a committed note")
        model.noteWriter.onNotesCommitted?([NoteCommitScope(day:"2026-09-21",timezone:zone)])
        expect(recorder.take() == ["notes:2026-09-21"],"the refused foreground note stayed counted in flight")
        expect(!model.recording && model.stopped && model.stoppedAt == nil && model.noteWriter.provider == "off","production model is not off")
        pass("production: the excludeApp hook saves end to end, refuses always-private apps and leaves recording stopped; a refused Summarize Now refreshes only its day")
        return model
    }
}
