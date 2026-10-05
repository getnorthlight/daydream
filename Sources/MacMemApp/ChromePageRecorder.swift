import AppKit
import Carbon
import Foundation
import MemoryCore

/// Everything Chrome page history asks the system. Injectable: the synthetic
/// checks use fakes and send zero Apple Events.
struct ChromePageEnvironment {
    /// Main thread: the frontmost app (pid, bundle ID, launch identity, name).
    var frontmost:()->(pid:pid_t,bundle:String,launch:String,name:String)?
    /// Main thread: the person's running `com.google.Chrome` application processes: a headless or automation Chrome
    /// (no window, or not a regular app, and not in front) is not counted (`ChromeProcesses`).
    var instances:()->Int
    /// Main thread: secure keyboard input is on.
    var secureInput:()->Bool
    /// Background: Google's signature, cached by launch identity.
    var verify:(pid_t,String)->Bool
    /// Background: Automation status for Chrome. Never asks.
    var permission:(pid_t)->OSStatus
    /// Background: one probe's Apple Event session (one shared deadline).
    var transport:(pid_t)->(ChromePageRequest)->ChromePageReply?
    var background:(@escaping ()->Void)->Void
    var main:(@escaping ()->Void)->Void
    var schedule:(TimeInterval,@escaping ()->Void)->Void
    var now:()->Date
    /// Main thread: seconds since the last key, click or mouse move anywhere.
    var idleSeconds:()->TimeInterval={0}

    static let queue=DispatchQueue(label:"daydream.chrome-pages",qos:.utility)
    static var live:ChromePageEnvironment {
        ChromePageEnvironment(
            frontmost:{
                guard let app=NSWorkspace.shared.frontmostApplication else {return nil}
                let bundle=app.bundleIdentifier ?? ""
                // The launch identity matters only for Chrome (signature cache).
                let launch=bundle == ChromePageTarget.bundleID ? ChromeEventSender.launchIdentity(app) ?? "" : ""
                return (app.processIdentifier,bundle,launch,app.localizedName ?? "Google Chrome")
            },
            instances:{ChromeEventSender.userProcessCount()},
            secureInput:{IsSecureEventInputEnabled()},
            verify:{pid,launch in !launch.isEmpty && ChromeEventSender.signatureValid(pid:pid,launch:launch)},
            permission:{ChromeEventSender.permissionStatus(pid:$0)},
            transport:{ChromeEventSender.pageTransport(pid:$0)},
            background:{queue.async(execute:$0)},
            main:{DispatchQueue.main.async(execute:$0)},
            schedule:{delay,work in DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:work)},
            now:{Date()},
            idleSeconds:{CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:CGEventType(rawValue:~0)!)})
    }
}

/// Chrome page history: saves the title and site of the page in front in
/// Google Chrome, only while "Web pages in Chrome" is on. State lives on the
/// main thread; signature, permission and Apple Events run on `background`.
/// Started only by an app switch, a window or title change, a confirm and the
/// poll. Keys, clicks, value and selection changes never start or cancel a read.
/// Window and title changes start at most one read every 1.5 s (the last one
/// is always read); the poll stops after a minute with no key, click or mouse move.
final class ChromePageRecorder {
    /// Neutral: never changes with the result, never names a site, a title or Incognito.
    static let status="Chrome pages: only the page in front is checked. Private, blocked and unreadable pages are skipped."
    enum Trigger {case appSwitch,window,poll,confirm,rerun}
    /// The name Chrome app time is saved under.
    static let appName="Google Chrome"
    /// Least time between two reads started by window or title changes.
    static let windowGap:TimeInterval=1.5
    /// No poll after this long without a key, click or mouse move.
    static let idleLimit:TimeInterval=60
    private enum Outcome {case unverified,permission(OSStatus),read(ChromePageResult)}
    private struct Start {let pid:pid_t;let launch:String;let name:String;let blocked:[String];let revision:String;var emailSubjects:Bool=false;var searchQueries:Bool=false}
    /// fix/chrome-x2: a search results page's query reader and where a read that found one goes. Set only by the owner
    /// build's website typing (`WebTypingRoute.wireSearches`); nil elsewhere, so the read never keeps a query.
    nonisolated(unsafe) static var searchQuery:((String)->(engine:String,query:String)?)?
    nonisolated(unsafe) static var onSearch:((ChromePageRead,Coordinator)->Void)?

    private let coordinator:Coordinator
    private let environment:ChromePageEnvironment
    private var generation:UInt64=0
    private var confirmEpoch:UInt64=0
    private var inFlight=false
    private var rerun=false
    private var tracker=ChromePageTracker()
    private var revision:String?
    private var ticks=0
    private var failures=0
    private var accessOff=false
    /// Chrome's app time is saved once per stint in front while its page can't be read.
    private var appTimeSaved=false
    private var lastWindowRead:Date?
    private var windowPending=false
    private var windowEpoch:UInt64=0
    /// Access facts for Settings and Diagnostics. Never a page, a site or a window's mode.
    private(set) var lastPermission:OSStatus?
    private(set) var lastVerified:Bool?
    /// What each finished read learned about Chrome access (review G30: the menu bar said "Browser history on"
    /// while Chrome couldn't be verified or access was off, because only Settings' own check told it). Called on
    /// the main thread, only for a read that still counts. Never a page, a site or a window's mode.
    /// `twoCopies`: two of the person's own Chrome processes run (a second profile folder with its own windows),
    /// whose windows each other's Apple Events never list: nothing is read until one quits, and Settings says so.
    enum Access:Equatable {case unverified,status(OSStatus),twoCopies}
    var onAccess:((Access)->Void)?
    /// Reads started (for the synthetic checks).
    private(set) var probes=0

    init(coordinator:Coordinator,environment:ChromePageEnvironment) {
        self.coordinator=coordinator;self.environment=environment
    }

    /// The page path counts only for Google Chrome while Chrome is allowed,
    /// which needs "Web pages in Chrome" on.
    func pathActive(_ bundle:String)->Bool {ReleaseFeatures.chromePageHistory && bundle == ChromePageTarget.bundleID && coordinator.allowsApp(bundle)}

    /// 3 s; after unreadable reads 6, 12, 24, then 30 s; 30 s while Chrome access is off.
    var pollPeriod:TimeInterval {
        if accessOff {return 30}
        return [3,6,12,24,30][min(failures,4)]
    }

    /// Drops the read in flight and any pending confirm or window read.
    func invalidate() {generation &+= 1;confirmEpoch &+= 1;windowEpoch &+= 1;windowPending=false;rerun=false}
    /// App switch, start, stop, policy change: also forgets the last page and the backoff.
    func reset() {invalidate();tracker.reset();ticks=0;failures=0;accessOff=false;lastWindowRead=nil;appTimeSaved=false}
    /// Chrome is no longer in front.
    func left() {reset()}

    /// Every 0.5 s from EventCapture's control timer.
    func tick() {
        // claude/perf3-1005: judged by the choices last read (no read of the history on the main thread every 0.5 s);
        // a read that starts is judged by choices read for it (`preflight`).
        guard let front=environment.frontmost(),ReleaseFeatures.chromePageHistory,front.bundle == ChromePageTarget.bundleID,
              coordinator.allowsAppLastRead(front.bundle) else {ticks=0;return}
        ticks += 1
        guard Double(ticks)*0.5 >= pollPeriod else {return}
        ticks=0
        // Away from the Mac: no poll. A window or title change still reads.
        if environment.idleSeconds() >= Self.idleLimit {return}
        trigger(.poll)
    }

    /// A Chrome window or title change (straight from the AX notification,
    /// never debounced or cancelled by keys and clicks). Reads now, or once at
    /// the end of the 1.5 s gap when a window read started less than 1.5 s ago.
    func windowChanged() {
        guard pathActive(environment.frontmost()?.bundle ?? "") else {return}
        if windowPending {return}
        let now=environment.now()
        if let last=lastWindowRead {
            let wait=Self.windowGap-now.timeIntervalSince(last)
            if wait > 0 {
                windowPending=true
                let epoch=windowEpoch
                environment.schedule(wait) {[weak self] in
                    guard let self,epoch == self.windowEpoch else {return}
                    self.windowPending=false
                    self.lastWindowRead=self.environment.now()
                    self.trigger(.window)
                }
                return
            }
        }
        lastWindowRead=now
        trigger(.window)
    }

    func trigger(_ why:Trigger) {
        guard let start=preflight() else {return}
        if inFlight {rerun=true;return}
        inFlight=true;probes += 1
        AccessibilityReader.status=Self.status
        let generation=self.generation,environment=self.environment,pid=start.pid,launch=start.launch,blocked=start.blocked,emailSubjects=start.emailSubjects
        let searchQuery=start.searchQueries ? Self.searchQuery : nil
        environment.background {
            // Signature, then permission (no prompt), then the read. A failed
            // signature or permission sends zero Apple Events.
            let outcome:Outcome
            if !environment.verify(pid,launch) {outcome = .unverified}
            else {
                let status=environment.permission(pid)
                outcome = status == noErr ? .read(ChromePageProbe.read(userBlocked:blocked,emailSubjects:emailSubjects,searchQuery:searchQuery,environment.transport(pid))) : .permission(status)
            }
            let checkedAt=environment.now()
            environment.main {[weak self] in self?.finish(outcome,generation:generation,start:start,checkedAt:checkedAt)}
        }
    }
    /// Main thread checks before anything is read.
    private func preflight()->Start? {
        // A release without Chrome page history never starts a read (ReleaseFeatures).
        guard ReleaseFeatures.chromePageHistory,coordinator.isRunning,let settings=coordinator.pageSettings(),settings.browserPagesOn else {return nil}
        if revision != settings.revision {revision=settings.revision;reset()}
        guard coordinator.allowsApp(ChromePageTarget.bundleID),let front=environment.frontmost(),
              front.bundle == ChromePageTarget.bundleID else {return nil}
        let instances=environment.instances()
        if instances > 1 {onAccess?(.twoCopies)}
        guard !environment.secureInput() else {return nil}
        var start=Start(pid:front.pid,launch:front.launch,name:front.name,blocked:settings.blockedDomains,revision:settings.revision,emailSubjects:settings.emailSubjects)
        start.searchQueries=Self.searchQuery != nil && Self.onSearch != nil && coordinator.captureText
        guard instances == 1 else {saveAppTime(start);return nil}
        return start
    }

    /// Back on main: the result counts only if nothing moved while it was read.
    private func finish(_ outcome:Outcome,generation:UInt64,start:Start,checkedAt:Date) {
        inFlight=false
        defer {
            if rerun {rerun=false;environment.schedule(0.1) {[weak self] in self?.trigger(.rerun)}}
        }
        guard generation == self.generation,coordinator.isRunning,let settings=coordinator.pageSettings(),
              settings.browserPagesOn,settings.revision == start.revision,
              let front=environment.frontmost(),front.bundle == ChromePageTarget.bundleID,front.pid == start.pid,
              !environment.secureInput() else {return}
        switch outcome {
        case .unverified:lastVerified=false;failures += 1;onAccess?(.unverified);saveAppTime(start)
        case .permission(let status):lastVerified=true;lastPermission=status;accessOff=true;onAccess?(.status(status));saveAppTime(start)
        case .read(let result):
            lastVerified=true;lastPermission=noErr;accessOff=false;onAccess?(.status(noErr))
            switch result {
            case .skipped(.unreadable):failures += 1
            case .skipped(.unstableTitle),.skipped(.changed):failures=0;apply(tracker.unstable(at:checkedAt),start:start,checkedAt:checkedAt)
            case .skipped:failures=0;tracker.skipped()
            case .page(let read):
                failures=0;apply(tracker.observe(read,at:checkedAt),start:start,checkedAt:checkedAt)
                if read.search != nil {Self.onSearch?(read,coordinator)}
            }
        }
    }
    /// Chrome's page can't be read (not verified, Automation not allowed, two copies open): its time still counts, as
    /// "Google Chrome" and nothing else (live test, build 7: Chrome vanished from the day). Once per stint in front.
    private func saveAppTime(_ start:Start) {
        guard !appTimeSaved else {return}
        // A fixed name: an unverified process's own name is not trusted.
        appTimeSaved=coordinator.recordChromeAppTime(appName:Self.appName,policyRevision:start.revision)
    }
    private func apply(_ step:ChromePageStep,start:Start,checkedAt:Date) {
        switch step {
        case .record(let read):
            // A row the write gate refuses (late, switch off, policy changed)
            // is not counted as saved: the page is read again.
            if !coordinator.recordPage(read,appName:start.name,checkedAt:checkedAt,policyRevision:start.revision) {
                apply(tracker.notSaved(read,at:environment.now()),start:start,checkedAt:checkedAt)
            }
        case .confirm(let delay):
            confirmEpoch &+= 1
            let epoch=confirmEpoch
            environment.schedule(delay) {[weak self] in
                guard let self,epoch == self.confirmEpoch else {return}
                self.trigger(.confirm)
            }
        case .nothing:break
        }
    }
}
