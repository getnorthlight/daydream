// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.

import AppKit
import ServiceManagement
import MemoryCore

/// Settings › Setup › Uninstall DayDream, in the app. The plan and the removal rules are in
/// Sources/MemoryCore/Uninstall.swift; this adds what needs the running app: its busy states,
/// the login item, the preferences domains, and a last pass as DayDream quits.
@MainActor final class DaydreamUninstaller: UninstallPerforming {
    private let model: MemoryViewModel
    init(model: MemoryViewModel) { self.model = model }

    func blocker() -> String? {
        if model.replacementBusy { return "A recorder replacement is running. Wait for it to finish, then try again. Nothing was removed." }
        if model.replacementNeedsReview { return "Finish or roll back the recorder replacement first. Nothing was removed." }
        if model.backups.busy || model.backups.prepared != nil { return "A backup or restore is in progress. Finish or cancel it, then try again. Nothing was removed." }
        if model.history.busy { return "A history import is in progress. Wait for it to finish, then try again. Nothing was removed." }
        return nil
    }

    func preview(_ choice: UninstallChoice) -> Result<UninstallPlan, UninstallRefusal> {
        UninstallPlanner.plan(choice, requester: UninstallRequester(bundleURL: Bundle.main.bundleURL, bundleID: Bundle.main.bundleIdentifier,
                                                                    info: Bundle.main.infoDictionary ?? [:],
                                                                    environmentHome: ProcessInfo.processInfo.environment["MAC_MEM_HOME"]),
                              locations: .live(), probe: .live)
    }

    func perform(_ plan: UninstallPlan) -> UninstallReport {
        // Checked again here: the button may have been pressed long after the sheet opened.
        if let blocker = blocker() { var report = UninstallReport(); report.stopped = blocker; return report }
        // Open at login (SMAppService.mainApp, LoginItem.swift): removed with the app.
        let service = SMAppService.mainApp
        if service.status == .enabled || service.status == .requiresApproval { try? service.unregister() }
        // Remove everything: which typing keys go, read from the histories before they are removed.
        let typingKeyIDs = UninstallTypingKeys.storeIDs(plan, current: model.historyStoreID, probe: .live,
                                                        read: UninstallTypingKeys.readStoreID)
        var report = UninstallRunner.run(plan, locations: .live(), probe: .live, operations: .live)
        guard report.finished else { return report }
        // Then the keys themselves (both the data-protection and the login keychain copy). Only after the
        // app is in the Trash: an uninstall that stopped there leaves a kept history that still needs its key.
        if plan.removesHistory {
            report.typingKey = UninstallTypingKeys.delete(typingKeyIDs, keys: { KeychainTypedKeyStore.forUninstall($0) })
        }
        // A LaunchAgent login item: stop it too, now that its file is gone.
        for item in report.removed where item.kind == .loginItem {
            LaunchctlControl().bootout(label: item.url.deletingPathExtension().lastPathComponent)
        }
        for domain in plan.preferenceDomains { UserDefaults.standard.removePersistentDomain(forName: domain) }
        UninstallExitSweep.arm(plan)
        return report
    }

    /// Settings › Setup is a sheet: AppQuit closes it first, or AppKit would refuse to quit.
    func quit() { AppQuit.terminate() }
}

/// The last pass, as DayDream quits. The app saves a few things on the way out (recording
/// state, settings); this deletes them again. It runs from `atexit`, after every quit handler.
enum UninstallExitSweep {
    nonisolated(unsafe) private static var pending: UninstallPlan?
    nonisolated(unsafe) private static var registered = false

    static func arm(_ plan: UninstallPlan) {
        pending = plan
        guard !registered else { return }
        registered = true
        atexit { UninstallExitSweep.fire() }
    }

    static func fire() {
        guard let plan = pending else { return }
        pending = nil
        for domain in plan.preferenceDomains { UserDefaults.standard.removePersistentDomain(forName: domain) }
        _ = UninstallRunner.sweep(plan, locations: .live(), probe: .live, delete: { try FileManager.default.removeItem(at: $0) })
    }
}
