// Legitimate, explicit Automation request by the authenticated actual app.
// No default model/home, page/field reads, capture, tap, store or typed input.
import AppKit
import Carbon
import Foundation
import MemoryCore

#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
private final class ChromeAutomationRequestReply: @unchecked Sendable {
    enum Outcome { case status(OSStatus), targetChanged }
    private let lock = NSLock()
    private var result: Outcome?
    func finish(_ outcome: Outcome) { lock.lock(); result = outcome; lock.unlock() }
    func read() -> Outcome? { lock.lock(); defer { lock.unlock() }; return result }
}
@MainActor enum CaptureChromeAutomationRequest {
    enum Refusal: String, Error { case arguments, permissionTarget = "permission-target", secureInput = "secure-input" }
    static func run(_ options: [String: String], checkedRoot: (String) throws -> URL) throws {
        guard let request = ChromeAutomationRequestControls.request(options) else { throw Refusal.arguments }
        let root = try checkedRoot(request.root)
        try CaptureFixtureTrial.reserveOutput(root)
        guard Thread.isMainThread, !IsSecureEventInputEnabled() else { throw Refusal.secureInput }
        guard ChromeEventSender.enabled,
              let facts = ChromeTypingWitness.targetFacts(pid: request.pid),
              ChromeTargetPolicy.accepts(facts),
              let launch = ChromeEventSender.launchIdentity(pid: request.pid) else { throw Refusal.permissionTarget }
        let before = ChromeEventSender.permissionStatus(pid: request.pid) // Never prompts.
        CaptureFixtureTrial.emit([
            "phase": "permission-request-starting", "permissionRequestOnly": true,
            "observedPID": request.pid, "beforeOSStatus": before,
            "beforeAccessState": ChromeAutomationRequestControls.state(before),
            "inputPosted": false, "storeOpened": false, "captureStarted": false,
            "pageMetadataRead": false, "fieldRead": false
        ])
        let reply = ChromeAutomationRequestReply()
        // The one prompt-capable call runs off main; the main run loop remains responsive.
        DispatchQueue.global(qos: .userInitiated).async {
            guard ChromeEventSender.launchIdentity(pid: request.pid) == launch,
                  ChromeEventSender.signatureValid(pid: request.pid, launch: launch),
                  !IsSecureEventInputEnabled() else { reply.finish(.targetChanged); return }
            reply.finish(.status(ChromeEventSender.askForChromeAccess(pid: request.pid)))
        }
        let deadline = ProcessInfo.processInfo.systemUptime + request.seconds
        while reply.read() == nil, ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard let outcome = reply.read() else {
            // A callback deadline is not an OS denial and does not prove prompt cancellation.
            CaptureFixtureTrial.emit([
                "phase": "permission-request-unresolved", "permissionRequestOnly": true,
                "callbackCompleted": false, "promptCancellationVerified": false,
                "inputPosted": false, "storeOpened": false, "captureStarted": false,
                "pageMetadataRead": false, "fieldRead": false
            ])
            return
        }
        switch outcome {
        case .targetChanged: throw Refusal.permissionTarget
        case .status(let status):
            let unchanged = ChromeEventSender.launchIdentity(pid: request.pid) == launch
            CaptureFixtureTrial.emit([
                "phase": "permission-request-complete", "permissionRequestOnly": true,
                "callbackCompleted": true, "osStatus": status,
                "accessState": ChromeAutomationRequestControls.state(status),
                "targetLaunchUnchanged": unchanged,
                "inputPosted": false, "storeOpened": false, "captureStarted": false,
                "pageMetadataRead": false, "fieldRead": false,
                "ownedDraftEstablished": false, "typingProofGranted": false
            ])
        }
    }
}
#endif
