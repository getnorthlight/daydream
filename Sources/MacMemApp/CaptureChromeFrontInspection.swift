// Same signed-app metadata route; never creates capture/store/input or draft authority.
import AppKit
import ApplicationServices
import Carbon
import Foundation
import MemoryCore
import PrivacyPolicy

#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
@MainActor enum CaptureChromeFrontInspection {
    enum Refusal: String, Error {
        case arguments, deadline, permission, front, target, automation
        case windowList = "window-list", windowModes = "window-modes"
        case focusedWindow = "focused-window", windowFrame = "window-frame"
        case windowOwner = "window-owner", uniqueWindow = "unique-window"
        case activeTab = "active-tab", changed
    }
    static func run(_ options: [String: String],
                    checkedRoot: (String) throws -> URL) throws {
        guard let request = ChromeFrontInspectionControls.request(options) else { throw Refusal.arguments }
        let root = try checkedRoot(request.root)
        try CaptureFixtureTrial.reserveOutput(root)
        let geometryOutcomes = ChromeFrontInspectionControls.GeometryBuffer()
        let transportOutcomes = ChromeEventSender.QAOutcomeBuffer()
        ChromeEventSender.observeQA { transportOutcomes.record($0) }
        defer {
            ChromeEventSender.observeQA(nil)
            for record in geometryOutcomes.drain() { CaptureFixtureTrial.emit(record.receipt) }
            if geometryOutcomes.truncated {
                CaptureFixtureTrial.emit(["phase":"qa-window-geometry", "bufferTruncated":true])
            }
            for outcome in transportOutcomes.drain() {
                CaptureFixtureTrial.emit(["phase":"qa-transport", "outcome":outcome.rawValue])
            }
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(request.seconds * 1_000_000_000)
        func front() throws {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Refusal.deadline }
            guard Thread.isMainThread, AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { throw Refusal.permission }
            guard let app = NSWorkspace.shared.frontmostApplication,
                  app.bundleIdentifier == "com.google.Chrome", app.processIdentifier == request.pid else { throw Refusal.front }
        }
        try front()
        guard ChromeEventSender.enabled,
              let facts = ChromeTypingWitness.targetFacts(pid: request.pid),
              ChromeTargetPolicy.accepts(facts) else { throw Refusal.target }
        let passiveStatus = ChromeEventSender.permissionStatus(pid: request.pid) // Existing no-prompt read, once.
        CaptureFixtureTrial.emit(ChromePermissionReadiness.collect(releaseEnabled: ChromeEventSender.enabled,
                                                                  automationStatus: passiveStatus))
        guard passiveStatus == noErr else { throw Refusal.automation }
        func normalIDs() throws -> [String] {
            try front()
            guard ChromeEventSender.permissionStatus(pid: request.pid) == noErr else { throw Refusal.automation }
            let session = ChromeModeReader.JoinSession(pid: request.pid, budget:ChromeEventSender.pageProbeBudget, eventTimeout:ChromeEventSender.pageEventTimeout)
            guard case .ids(let ids)? = session.reply(.windowIDs), !ids.isEmpty, ids.count <= 64,
                  Set(ids).count == ids.count, ids.allSatisfy(ChromeAppleEvents.validID) else { throw Refusal.windowList }
            for id in ids {
                try front()
                guard case .text(let mode)? = session.reply(.mode(id)) else { throw Refusal.windowModes }
                guard mode == "normal" else {
                    CaptureFixtureTrial.emit(["phase":"qa-window-mode", "normal":false])
                    throw Refusal.windowModes
                }
            }
            try front()
            return ids
        }
        let ids = try normalIDs()
        let ax = ChromeTypingWitness.access(pid: request.pid)
        // All windows must be normal before every AX read; read no field/title/value/document attributes.
        guard try normalIDs() == ids else { throw Refusal.changed }
        guard let window = ax.focusedWindow() else { throw Refusal.focusedWindow }
        guard try normalIDs() == ids else { throw Refusal.changed }
        guard ax.owner(window) == request.pid else { throw Refusal.windowOwner }
        guard try normalIDs() == ids else { throw Refusal.changed }
        guard let frame = ax.frame(window) else { throw Refusal.windowFrame }
        var matches: [String] = []
        var exactMatches = 0
        for (ordinal, id) in ids.enumerated() {
            guard try normalIDs() == ids else { throw Refusal.changed }
            guard case .bounds(let bounds)? = ChromeModeReader.JoinSession(pid: request.pid, budget:ChromeEventSender.pageProbeBudget, eventTimeout:ChromeEventSender.pageEventTimeout).reply(.bounds(id)) else { throw Refusal.windowFrame }
            let comparison = ChromeFrontInspectionControls.compareGeometry(bounds, frame)
            geometryOutcomes.record(.candidate(.initial, ordinal, comparison))
            if comparison.exactMatch { exactMatches += 1 }
            if comparison.productionMatch { matches.append(id) }
        }
        geometryOutcomes.record(.summary(.initial, exactMatches, matches.count))
        guard let windowID = ChromeFrontInspectionControls.uniqueWindowID(matches) else { throw Refusal.uniqueWindow }
        guard try normalIDs() == ids else { throw Refusal.changed }
        guard case .text(let tabID)? = ChromeModeReader.JoinSession(pid: request.pid, budget:ChromeEventSender.pageProbeBudget, eventTimeout:ChromeEventSender.pageEventTimeout).reply(.activeTabID(windowID)),
              ChromeAppleEvents.validID(tabID) else { throw Refusal.activeTab }
        // Rebind the observed front window without acquiring editor contents or claiming ownership.
        guard try normalIDs() == ids else { throw Refusal.changed }
        guard let current = ax.focusedWindow(), CFEqual(current, window) else { throw Refusal.changed }
        guard try normalIDs() == ids else { throw Refusal.changed }
        guard ax.owner(current) == request.pid else { throw Refusal.windowOwner }
        guard try normalIDs() == ids else { throw Refusal.changed }
        guard ax.frame(current) == frame else { throw Refusal.changed }
        // A different normal window may have moved onto this frame since the initial scan.
        // Recheck uniqueness across every window, rather than only rechecking the selected ID.
        var finalMatches: [String] = []
        var finalExactMatches = 0
        for (ordinal, id) in ids.enumerated() {
            guard try normalIDs() == ids else { throw Refusal.changed }
            guard case .bounds(let bounds)? = ChromeModeReader.JoinSession(pid: request.pid, budget:ChromeEventSender.pageProbeBudget, eventTimeout:ChromeEventSender.pageEventTimeout).reply(.bounds(id)) else { throw Refusal.windowFrame }
            let comparison = ChromeFrontInspectionControls.compareGeometry(bounds, frame)
            geometryOutcomes.record(.candidate(.final, ordinal, comparison))
            if comparison.exactMatch { finalExactMatches += 1 }
            if comparison.productionMatch { finalMatches.append(id) }
        }
        geometryOutcomes.record(.summary(.final, finalExactMatches, finalMatches.count))
        guard ChromeFrontInspectionControls.uniqueWindowID(finalMatches) == windowID else { throw Refusal.uniqueWindow }
        guard try normalIDs() == ids else { throw Refusal.changed }
        guard case .text(let currentTab)? = ChromeModeReader.JoinSession(pid: request.pid, budget:ChromeEventSender.pageProbeBudget, eventTimeout:ChromeEventSender.pageEventTimeout).reply(.activeTabID(windowID)),
              currentTab == tabID else { throw Refusal.changed }
        // Rebind after the final AE scan as well; no editor contents are acquired.
        guard try normalIDs() == ids else { throw Refusal.changed }
        guard let finalWindow = ax.focusedWindow(), CFEqual(finalWindow, window) else { throw Refusal.changed }
        guard try normalIDs() == ids else { throw Refusal.changed }
        guard ax.owner(finalWindow) == request.pid else { throw Refusal.windowOwner }
        guard try normalIDs() == ids else { throw Refusal.changed }
        guard ax.frame(finalWindow) == frame else { throw Refusal.changed }
        guard try normalIDs() == ids else { throw Refusal.changed }
        try front()
        CaptureFixtureTrial.emit([
            "phase": "inspection-complete", "inspectionOnly": true,
            "observedPID": request.pid, "windowID": windowID, "tabID": tabID,
            "observedFrontWindowStable": true, "allWindowsNormal": true,
            "inputPosted": false, "storeOpened": false, "captureStarted": false,
            "ownedDraftEstablished": false, "emptyComposerEstablished": false,
            "typingProofGranted": false
        ])
    }
}
#endif
