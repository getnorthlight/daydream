// Model-free AppKit request window; only a human button action can request Automation.
import AppKit
import Carbon
import Foundation
import MemoryCore

#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
private final class ChromePermissionCallState: @unchecked Sendable {
    private let lock = NSLock()
    private var issued = false
    private var returned = false
    func markIssued() { lock.lock(); issued = true; lock.unlock() }
    func markReturned() { lock.lock(); returned = true; lock.unlock() }
    func snapshot() -> (issued: Bool, returned: Bool) {
        lock.lock(); defer { lock.unlock() }; return (issued, returned)
    }
}
@MainActor enum CaptureChromeAutomationRequestUI {
    enum Refusal: String, Error { case arguments, applicationInitialization = "application-initialization" }
    static func run(_ options: [String: String], checkedRoot: (String) throws -> URL) throws {
        guard let request = ChromeAutomationRequestControls.uiRequest(options) else { throw Refusal.arguments }
        let root = try checkedRoot(request.root)
        try CaptureFixtureTrial.reserveOutput(root)
        guard Thread.isMainThread else {
            CaptureFixtureTrial.emit(["phase": "permission-ui-initialization", "mainThread": false,
                                      "inputPosted": false, "storeOpened": false, "captureStarted": false])
            throw Refusal.applicationInitialization
        }
        let app = NSApplication.shared
        let policyBefore = app.activationPolicy()
        let switchAttempted = policyBefore != .regular
        let switchAccepted = switchAttempted ? app.setActivationPolicy(.regular) : false
        CaptureFixtureTrial.emit(["phase": "permission-ui-initialization", "mainThread": true,
                                  "policyBefore": policyBefore.rawValue, "policyAfter": app.activationPolicy().rawValue,
                                  "policySwitchAttempted": switchAttempted, "policySwitchAccepted": switchAccepted,
                                  "inputPosted": false, "storeOpened": false, "captureStarted": false])
        // A regular application already satisfies the requirement; setter success is not the policy itself.
        guard app.activationPolicy() == .regular else { throw Refusal.applicationInitialization }
        let controller = ChromeAutomationRequestWindow(request: request)
        app.delegate = controller
        // Normal AppKit launch/event processing, without constructing the normal app model.
        withExtendedLifetime(controller) { app.run() }
    }
}
@MainActor private final class ChromeAutomationRequestWindow: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let request: ChromeAutomationRequestControls.Request
    private var window: NSWindow!
    private var button: NSButton!
    private var status: NSTextField!
    private let permissionCall = ChromePermissionCallState()
    private var attempted = false
    private var completed = false
    private var unresolvedReported = false
    private var timeout: Timer?
    init(request: ChromeAutomationRequestControls.Request) { self.request = request; super.init() }
    private func emit(_ fields: [String: Any]) {
        var receipt = fields
        receipt["permissionRequestOnly"] = true; receipt["humanActionRequired"] = true
        receipt["inputPosted"] = false; receipt["storeOpened"] = false; receipt["captureStarted"] = false
        receipt["pageMetadataRead"] = false; receipt["fieldRead"] = false
        receipt["ownedDraftEstablished"] = false; receipt["typingProofGranted"] = false
        let call = permissionCall.snapshot()
        receipt["actualOSrequestIssued"] = call.issued; receipt["callbackReturned"] = call.returned
        CaptureFixtureTrial.emit(receipt)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "DayDream — Chrome access"; window.delegate = self; window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        let explanation = NSTextField(wrappingLabelWithString:
            "Allow DayDream to read Chrome tab information. History and recording are off in this window. Click below to ask macOS. If the macOS question names an SSH launcher, do not allow it.")
        explanation.frame = NSRect(x: 24, y: 118, width: 472, height: 78)
        content.addSubview(explanation)
        status = NSTextField(wrappingLabelWithString: "Ready. No permission request has been made.")
        status.frame = NSRect(x: 24, y: 65, width: 472, height: 48)
        content.addSubview(status)
        button = NSButton(title: "Allow Chrome Access…", target: self, action: #selector(allow))
        button.frame = NSRect(x: 24, y: 22, width: 225, height: 32); button.bezelStyle = .rounded
        content.addSubview(button); window.contentView = content
        let menu = NSMenu(); let item = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit DayDream", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item); NSApplication.shared.mainMenu = menu
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        emit(["phase": "permission-ui-ready", "appKitLaunched": true,
              "requestAttempted": false, "observedPID": request.pid])
    }
    @objc private func allow() {
        guard !attempted, NSApplication.shared.isRunning, NSApplication.shared.isActive,
              window.isKeyWindow else { return }
        attempted = true; button.isEnabled = false
        guard !IsSecureEventInputEnabled(), ChromeEventSender.enabled,
              let facts = ChromeTypingWitness.targetFacts(pid: request.pid), ChromeTargetPolicy.accepts(facts),
              let launch = ChromeEventSender.launchIdentity(pid: request.pid) else {
            completed = true; status.stringValue = "Chrome could not be verified. No permission request was made."
            emit(["phase": "blocked", "code": "permission-target", "requestAttempted": false,
                  "allowButtonClicked": true]); return
        }
        status.stringValue = "Waiting for macOS. Only allow a question that names DayDream."
        emit(["phase": "permission-ui-request-starting", "allowButtonClicked": true,
              "appKitLaunched": true, "appActive": true, "ownWindowKey": true,
              "observedPID": request.pid])
        timeout = Timer.scheduledTimer(withTimeInterval: request.seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.completed else { return }
                self.unresolvedReported = true
                self.status.stringValue = "macOS has not returned an answer. The request is unresolved."
                self.emit(["phase": "permission-request-unresolved", "operationFinished": false,
                           "promptCancellationVerified": false])
            }
        }
        let pid = request.pid
        let call = permissionCall
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard ChromeEventSender.launchIdentity(pid: pid) == launch,
                  ChromeEventSender.signatureValid(pid: pid, launch: launch),
                  !IsSecureEventInputEnabled() else {
                DispatchQueue.main.async { self?.targetChanged() }; return
            }
            let before = ChromeEventSender.permissionStatus(pid: pid) // No prompt.
            call.markIssued()
            let answer = ChromeEventSender.askForChromeAccess(pid: pid) // Exactly once; off main.
            call.markReturned()
            let unchanged = ChromeEventSender.launchIdentity(pid: pid) == launch
            DispatchQueue.main.async { self?.answered(before: before, answer: answer, unchanged: unchanged) }
        }
    }
    private func targetChanged() {
        timeout?.invalidate(); completed = true
        status.stringValue = "Chrome changed before the request. No permission request was made."
        emit(["phase": "blocked", "code": "permission-target", "requestAttempted": false])
    }
    private func answered(before: OSStatus, answer: OSStatus, unchanged: Bool) {
        timeout?.invalidate(); completed = true
        switch answer {
        case 0: status.stringValue = "Chrome access is allowed. History and recording remain off."
        case -1744: status.stringValue = "macOS still requires consent. No access was granted."
        case -1743: status.stringValue = "macOS did not permit Chrome access. This does not establish who declined it."
        case -600: status.stringValue = "Chrome is no longer running."
        default: status.stringValue = "macOS returned an unexpected status. No access is assumed."
        }
        emit(["phase": "permission-ui-request-complete", "operationFinished": true,
              "beforeOSStatus": before, "beforeAccessState": ChromeAutomationRequestControls.state(before),
              "osStatus": answer, "accessState": ChromeAutomationRequestControls.state(answer),
              "targetLaunchUnchanged": unchanged, "deadlinePreviouslyUnresolved": unresolvedReported])
    }
    func windowWillClose(_ notification: Notification) { NSApplication.shared.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        timeout?.invalidate()
        if attempted && !completed {
            emit(["phase": "permission-ui-closed-unresolved", "operationFinished": false,
                  "promptCancellationVerified": false])
        } else {
            emit(["phase": "permission-ui-closed", "allowButtonActionObserved": attempted, "operationFinished": completed])
        }
        return .terminateNow
    }
}
#endif
