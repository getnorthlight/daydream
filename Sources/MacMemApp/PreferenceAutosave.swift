import Foundation
import MemoryCore

/// One main-actor producer stop and revision-fenced transaction per coalesced draft.
/// Retention and authority activation cannot be expressed by this binding.
@MainActor final class PreferenceAutosave {
    private let store:MemoryStore
    private let stopProducer:()->Void
    private var pending:Task<Void,Never>?
    private(set) var policy:PrivacySettings
    private(set) var draft:MemoryPreferences?
    private(set) var error:PreferenceSaveError?
    private(set) var changedOnLastSave=false
    /// AI app connections (grants) the last save revoked.
    private(set) var revokedOnLastSave=0
    var onChange:()->Void = {}
    /// A save that failed for a moment (another connection held the file, or the stop before it couldn't be saved) is
    /// tried again by itself: the same change, on the same saved revision (never rebased, so a change made elsewhere
    /// meanwhile still fails as a conflict). Recording stays stopped until it saves, then the app starts it again
    /// (`resumeAfterSave`). The first tries (about 10 s) are quiet: the change still reads as waiting. After them the
    /// problem shows with its one button while the tries go on, then once a minute.
    var retryDelays:[TimeInterval]=[0.5,1,2,5,10,30]
    var retryEvery:TimeInterval=60
    static let quietTries=4
    /// Tries scheduled since the last save that landed (0: none).
    private(set) var retries=0
    var retrying:Bool {retries > 0}
    /// A change being tried again quietly after a busy moment: it is saving, not failing. No problem shows, and an
    /// action that saves at once (Exclude App, Don't Record <site>, a site added in Settings) must not say it didn't
    /// save: it lands by itself (`settled()` waits for it), or its problem shows once the quiet tries are used up.
    var saving:Bool {retrying && error == nil && draft != nil}
    /// The change didn't save and is not saving by itself: its problem (`PreferenceProblem`) is the one line to show.
    var failed:Bool {!saving && (draft != nil || error != nil)}
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    init(store:MemoryStore,stopProducer:@escaping()->Void) throws {
        self.store=store;self.stopProducer=stopProducer;policy=try store.policy()
    }
    func submit(_ value:MemoryPreferences) {
        pending?.cancel();pending=nil
        stopProducer() // Synchronous, before debounce, including restrictive failures.
        draft=value;onChange()
        // Never silently rebase/retry failed intent. A save that failed for a moment is being tried again anyway: the
        // newest change is the one it tries.
        guard error == nil || retrying else {return}
        pending=Task { [weak self] in
            do {try await Task.sleep(nanoseconds:200_000_000)} catch {return}
            guard !Task.isCancelled else {return};self?.flush()
        }
    }
    func flush() {flush(stopFirst:true)}
    /// `stopFirst` false: a try again by itself. The try that failed already stopped the producer, and nothing starts
    /// it while a change waits (Start saves first); the store still refuses while its saved state says recording, and
    /// then the producer is stopped again below. So a busy file costs each try one wait (the save's), not the stop's
    /// writes as well, on the main thread.
    private func flush(stopFirst:Bool) {
        pending?.cancel();pending=nil
        guard let draft,error != .revisionConflict else {return}
        if stopFirst {stopProducer()}
        var retried=false
        var momentary:PreferenceSaveError?
        while true {
            do {
                let result=try store.savePreferences(draft,expectedRevision:policy.revision)
                policy=result.policy;self.draft=nil;error=nil;changedOnLastSave=result.changed;revokedOnLastSave=result.revokedGrantCount;retries=0
            } catch PreferenceSaveError.captureMustBeStopped where !retried {
                // The saved capture state still says recording (a crash, or a stop whose write failed) although
                // this app holds the recorder and has just stopped it: stop once more, which writes "off", and
                // save once more. The store still refuses while anything records.
                retried=true;stopProducer();continue
            } catch PreferenceSaveError.captureMustBeStopped {
                // The stop's own write failed again (most often the same busy moment): tried again below.
                momentary = .captureMustBeStopped
            } catch let failure as PreferenceSaveError {error=failure;retries=0}
            catch let busy as MemError where CaptureFault.busy(busy) {momentary = .storageUnavailable}
            catch {self.error = .storageUnavailable;retries=0}
            break
        }
        if let momentary {tryAgain(momentary)}
        onChange()
        settle()
    }
    /// Waits while the change is `saving` (the quiet tries: about 10 s, plus each try's wait for the file), then
    /// returns: it saved, its problem shows, or it was dropped (`reload`). Returns at once when nothing is being tried again.
    func settled() async {
        while saving {await withCheckedContinuation {waiters.append($0)}}
    }
    /// Wakes every `settled()` so each looks again.
    private func settle() {
        let waiting=waiters;waiters=[]
        for waiter in waiting {waiter.resume()}
    }
    /// Schedules the next try of a save that failed for a moment. Its problem shows only once the quiet tries are used up.
    private func tryAgain(_ failure:PreferenceSaveError) {
        retries += 1
        if retries > Self.quietTries {error=failure}
        let wait=retries <= retryDelays.count ? retryDelays[retries-1] : retryEvery
        RecordingLog.note("Choices didn't save for a moment; trying again in \(wait) s.")
        pending=Task { [weak self] in
            do {try await Task.sleep(nanoseconds:UInt64(wait*1_000_000_000))} catch {return}
            guard !Task.isCancelled else {return};self?.flush(stopFirst:false)
        }
    }
    func reload() {
        pending?.cancel();pending=nil;stopProducer();retries=0
        do {policy=try store.policy();draft=nil;error=nil;changedOnLastSave=false;revokedOnLastSave=0}
        catch {self.error = .storageUnavailable}
        onChange()
        settle()
    }
    deinit {pending?.cancel();for waiter in waiters {waiter.resume()}}
}
