import AppKit
import Carbon
import CoreGraphics
import MemoryCore
import Security

/// The one Apple Event sender in DayDream (Chrome page history, and Chrome
/// typing in the private build). Only read-only `core/getd` events of an
/// allowlisted property (`ChromeAppleEvents`), addressed to the already-running
/// Chrome PID. No script, JavaScript, launch or keystroke (setup's Chrome step
/// opens Chrome through Launch Services, not from here); the only permission
/// prompt is `askForChromeAccess`: setup's Chrome step (`askChromeAccessInSetup`),
/// right after setup starts recording with the switch on if still unanswered
/// (`askChromeAccessAfterSetup`), and from Settings' Allow… button.
/// Never called on the main thread by page history (`ChromePageRecorder`).
///
/// Release switch: with `ReleaseFeatures.chromePageHistory` false every entry
/// point below returns before building an event or asking macOS, so the app
/// sends no Apple Event and never shows the Automation prompt
/// (`honesty-switch-off` builds the app that way and checks it).
enum ChromeEventSender {
    #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
    /// Bound only by isolated metadata/preflight fixture routes; never enabled by normal app startup.
    enum QAOutcome: String { case budgetExpired, transportTimeout, transportFailed, replyFailed, lateReply, missingResult, resultPresent, decodeFailed, bufferTruncated }
    /// Fixed-enum diagnostics must never run metadata enrichment/file IO inside the measured production join.
    final class QAOutcomeBuffer {
        static let limit = 1024
        private var pending: [QAOutcome] = []
        private var truncated = false
        init() { pending.reserveCapacity(Self.limit) }
        func record(_ outcome: QAOutcome) {
            guard pending.count < Self.limit else { truncated = true; return }
            pending.append(outcome)
        }
        func drain() -> [QAOutcome] {
            let result = pending + (truncated ? [.bufferTruncated] : [])
            pending.removeAll(keepingCapacity:true); truncated = false
            return result
        }
    }
    private static var qaObserver: ((QAOutcome) -> Void)?
    static func observeQA(_ observer: ((QAOutcome) -> Void)?) { qaObserver = observer }
    static func noteQA(_ outcome: QAOutcome) { qaObserver?(outcome) }
    #endif
    private static func code(_ s:String) -> UInt32 { ChromeAppleEvents.code(s) }
    /// Whether this release may talk to Chrome at all.
    static var enabled:Bool { ReleaseFeatures.chromePageHistory }
    /// What the permission calls return while the release switch is off: "not permitted", without asking.
    static let switchedOff:OSStatus = OSStatus(errAEEventNotPermitted)

    /// Per-event and whole-probe deadlines for page history.
    static let pageEventTimeout:TimeInterval=0.2
    static let pageProbeBudget:TimeInterval=0.75

    /// Capture reads must never trigger the consent prompt, including a permission race.
    static let noConsentPrompt=NSAppleEventDescriptor.SendOptions(rawValue:UInt(kAEDoNotPromptForUserConsent))

    /// The single sender. Refuses any specifier the allowlist audit rejects,
    /// never interacts, never records, and never waits past `deadline`.
    /// `everyWindow`: the `… of every window` properties this caller may read (IDs only unless Chrome typing's
    /// join session widens it to modes and bounds; never names, tabs or URLs: the audit enforces that).
    static func send(_ specifier:NSAppleEventDescriptor?, to target:NSAppleEventDescriptor, deadline:Date, eventTimeout:TimeInterval,
                     everyWindow:Set<String> = ChromeAppleEvents.everyWindowDefault) -> NSAppleEventDescriptor? {
        guard enabled else { return nil }
        guard let specifier, ChromeAppleEvents.audit(specifier, everyWindow:everyWindow) else { return nil }
        let remaining=deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
            noteQA(.budgetExpired)
            #endif
            return nil
        }
        let event=NSAppleEventDescriptor(eventClass:code(ChromeAppleEvents.eventClass),eventID:code(ChromeAppleEvents.eventID),targetDescriptor:target,returnID:-1,transactionID:0)
        event.setParam(specifier,forKeyword:code("----"))
        let reply:NSAppleEventDescriptor
        do {
            reply=try event.sendEvent(options:[.waitForReply,.neverInteract,.dontRecord,noConsentPrompt],timeout:min(eventTimeout,remaining))
        } catch {
            #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
            noteQA((error as NSError).code == Int(errAETimeout) ? .transportTimeout : .transportFailed)
            #endif
            return nil
        }
        guard reply.paramDescriptor(forKeyword:code("errn"))?.int32Value ?? 0 == 0 else {
            #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
            noteQA(.replyFailed)
            #endif
            return nil
        }
        guard deadline.timeIntervalSinceNow > 0 else {
            #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
            noteQA(.lateReply)
            #endif
            return nil
        }
        let result=reply.paramDescriptor(forKeyword:code("----"))
        #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
        noteQA(result == nil ? .missingResult : .resultPresent)
        #endif
        return result
    }

    /// Whether DayDream may send Chrome `core/getd`. Never asks: macOS shows
    /// no prompt from here. noErr allowed, -1743 denied, -1744 not asked yet,
    /// -600 Chrome not running.
    static func permissionStatus(pid:pid_t) -> OSStatus {
        guard enabled else { return switchedOff }
        let target=NSAppleEventDescriptor(processIdentifier:pid)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc,code(ChromeAppleEvents.eventClass),code(ChromeAppleEvents.eventID),false)
    }
    static func permission(pid:pid_t) -> Bool { permissionStatus(pid:pid) == noErr }

    /// The one call in DayDream that lets macOS ask the person to allow
    /// DayDream to control Google Chrome. Setup's Start Recording (with Web
    /// pages in Chrome on) and Settings' "Allow…" reach it, through the app
    /// model's `allowChromeAccess`, off the main thread (it waits while the macOS
    /// prompt is up). Same read-only `core/getd` scope.
    static func askForChromeAccess(pid:pid_t) -> OSStatus {
        guard enabled else { return switchedOff }
        let target=NSAppleEventDescriptor(processIdentifier:pid)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc,code(ChromeAppleEvents.eventClass),code(ChromeAppleEvents.eventID),true)
    }

    /// One probe's worth of reads against one Chrome PID, sharing one deadline
    /// that starts now. Only `ChromePageRequest` values can be expressed.
    static func pageTransport(pid:pid_t) -> (ChromePageRequest) -> ChromePageReply? {
        guard enabled else { return { _ in nil } }
        let target=NSAppleEventDescriptor(processIdentifier:pid)
        let deadline=Date().addingTimeInterval(pageProbeBudget)
        return { request in
            send(request.specifier,to:target,deadline:deadline,eventTimeout:pageEventTimeout).flatMap(request.decode)
        }
    }

    /// pid + launch date + bundle ID; a relaunch is a different target.
    static func launchIdentity(pid:pid_t) -> String? {
        NSRunningApplication(processIdentifier:pid).flatMap { launchIdentity($0) }
    }
    static func launchIdentity(_ app:NSRunningApplication) -> String? {
        // A Chrome macOS didn't launch (reopened at login) has no launch date: the kernel's start time stands in.
        guard let bundleID=app.bundleIdentifier, let launched=ProcessStart.seconds(launchDate:app.launchDate,pid:app.processIdentifier) else { return nil }
        return "\(app.processIdentifier):\(launched):\(bundleID)"
    }

    /// Every running `com.google.Chrome` application process (`ChromeProcesses` picks the person's). The window
    /// read runs only when more than one process runs: it asks the window server for each window's owner and layer,
    /// never a title (no Screen Recording needed), so a headless Chrome (no window) is told from the person's.
    static func processes(frontmost:pid_t?=NSWorkspace.shared.frontmostApplication?.processIdentifier) -> [ChromeProcess] {
        let apps=NSRunningApplication.runningApplications(withBundleIdentifier:ChromePageTarget.bundleID).filter { !$0.isTerminated }
        let owners:Set<pid_t>? = apps.count > 1 ? windowOwners() : nil
        return apps.map { app in
            let pid=app.processIdentifier
            return ChromeProcess(pid:pid,regular:app.activationPolicy == .regular,windows:owners.map { $0.contains(pid) } ?? true,
                                 frontmost:pid == frontmost,started:ProcessStart.seconds(launchDate:app.launchDate,pid:pid))
        }
    }
    /// The person's Chrome to check: the frontmost one, else the newest user process (never a headless one).
    static func chosenProcess() -> pid_t? { ChromeProcesses.chosen(processes())?.pid }
    /// How many of the running Chrome processes are the person's (background and headless ones don't count).
    static func userProcessCount(frontmost:pid_t?=NSWorkspace.shared.frontmostApplication?.processIdentifier) -> Int {
        ChromeProcesses.user(processes(frontmost:frontmost)).count
    }
    /// PIDs owning an ordinary (layer 0) window, on screen or not. Owner and layer only.
    private static func windowOwners() -> Set<pid_t> {
        let list=(CGWindowListCopyWindowInfo([.optionAll],kCGNullWindowID) as? [[String:Any]]) ?? []
        return Set(list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return (w[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) }
        })
    }

    private static let signatureLock=NSLock()
    private static var signatures:[String:Bool]=[:]
    /// Signature check flags for the running (dynamic) code: none.
    /// `SecCodeCheckValidity` checks the running code's signature and the
    /// requirement; it does not hash Chrome's resource files (1-9 ms measured).
    /// It does not accept the static-code "skip resources" flag (value 4):
    /// passing it returns errSecCSInvalidFlags (-67070) on every call, which
    /// failed every Chrome check (review, critical).
    static let signatureFlags=SecCSFlags(rawValue:0)
    /// The status of checking the running code at `pid` against `requirement`
    /// with `signatureFlags`. The one Security call behind `signatureValid`;
    /// checks run it against their own process.
    static func signatureStatus(pid:pid_t, requirement text:String) -> OSStatus {
        var code:SecCode?, requirement:SecRequirement?
        let copied=SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:pid] as CFDictionary,SecCSFlags(rawValue:0),&code)
        guard copied == errSecSuccess, let code else { return copied == errSecSuccess ? errSecCSStaticCodeNotFound : copied }
        let made=SecRequirementCreateWithString(text as CFString,SecCSFlags(rawValue:0),&requirement)
        guard made == errSecSuccess, let requirement else { return made == errSecSuccess ? errSecCSReqInvalid : made }
        return SecCodeCheckValidity(code,signatureFlags,requirement)
    }
    /// The running code at `pid` is Google Chrome signed by Google (Team
    /// EQHXZ8M8AV). A bundle identifier alone can be copied. Cached by launch
    /// identity for as long as that process runs; `launch`, when given, must be
    /// the identity of the process now at `pid`.
    /// Settings refreshes this check on Try Again; capture callers retain the launch cache.
    /// Fails closed when the Chrome on disk no longer matches the Chrome that
    /// is running (Chrome updated itself and waits to be relaunched): nothing
    /// is read until Chrome is quit and reopened, and Settings says so.
    static func signatureValid(pid:pid_t, launch:String?=nil, refresh:Bool=false) -> Bool {
        guard enabled, let identity=launchIdentity(pid:pid), launch == nil || launch == identity else { return false }
        signatureLock.lock()
        if !refresh, let known=signatures[identity] { signatureLock.unlock(); return known }
        signatureLock.unlock()
        let valid = signatureStatus(pid:pid,requirement:ChromePageTarget.requirement) == errSecSuccess
        signatureLock.lock()
        if signatures.count >= 16 { signatures.removeAll() }
        signatures[identity]=valid
        signatureLock.unlock()
        return valid
    }
}
