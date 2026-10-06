import AppKit
import SwiftUI
import MemoryCore
import MemoryUI

/// What DayDream counts for `UsageSender`, and when (the list is `UsageCounts` in MemoryCore):
/// - installed: once, when the install ID is made on a Mac that never finished setup (an update doesn't count).
/// - setup_step: each setup step, once per install (ai_connected once per AI app).
/// - daily_check: once per calendar day, on the first hourly tick of the day. `hours_recorded_bucket` is the previous
///   calendar day: the 10-minute slots with at least one saved action (`MemoryStore.recordedSeconds`), bucketed.
/// - summaries_result: with the daily check, the notes written, fallen back to the code note and failed since the last
///   one, by mode and failure kind, plus the summaries state's problem now. Not sent when all are zero and no problem.
/// - ai_used: what `mac-mem mcp` appended to `UsageInbox`, read each hour and when See what's sent opens.
/// - app_opened: the menu bar's Open DayDream (and its other routes to the window), a click on the Dock icon while
///   DayDream runs (macOS's reopen), or a launch that isn't macOS opening DayDream at login ("other").
/// - app_search: a search in DayDream's window once it settles (3 s with no newer search), with its result count.
/// Nothing is counted in the developer preview or the trials: only the production model calls `start`.
@MainActor enum UsageReport {
    static var sender: UsageSender { .shared }
    private static weak var model: MemoryViewModel?
    static let dailyKey = "DaydreamUsageDailyCheckDay"
    static let stepsKey = "DaydreamUsageSetupSteps"
    static let summaryCountsKey = "DaydreamUsageSummaryCounts"
    /// How this launch opened the window, decided as AppKit finishes launching (nil: at login, or not decided).
    private static var launchHow: String?
    private static var lastOpened: Date = .distantPast
    private static var searchWork: DispatchWorkItem?

    static func start(model: MemoryViewModel, home: URL) {
        guard sender.home == nil else { return }
        self.model = model
        let made = sender.ensureInstallID().made
        sender.start(home: home)
        sender.beforeSend = { hourly() }
        WriterIntegration.noteSummaryOutcome = { mode, outcome in noteSummary(mode: mode, outcome) }
        if made && !UserDefaults.standard.bool(forKey: MemoryViewModel.setupCompletedKey) {
            sender.record("installed", ["macos_version": .text(macOSVersion), "chip": .text(chip)])
        }
        if let how = launchHow { launchHow = nil; opened(how) }
    }

    static func hourly() { drainInbox(); dailyCheck() }

    static func drainInbox() {
        guard sender.enabled, let home = sender.home else { return }
        sender.add(UsageInbox.drain(home: home))
    }

    // MARK: App

    /// AppKit finished launching: a launch macOS made at login opens nothing that counts.
    static func launched(atLogin: Bool) { if !atLogin { launchHow = "other" } }
    static func opened(_ how: String) {
        let now = Date()
        guard now.timeIntervalSince(lastOpened) > 2 else { return }
        lastOpened = now
        sender.record("app_opened", ["how": .text(how)])
    }
    static func searched(results: Int) {
        searchWork?.cancel()
        let work = DispatchWorkItem { sender.record("app_search", ["result_count": .int(results)]) }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: Setup

    static func setupStep(_ step: String, _ extra: [String: UsageValue] = [:]) {
        guard sender.enabled, sender.home != nil else { return }
        let key = step + (extra["ai_app"].map { if case .text(let app) = $0 { return ":" + app }; return "" } ?? "")
        var done = UserDefaults.standard.stringArray(forKey: stepsKey) ?? []
        guard !done.contains(key) else { return }
        done.append(key)
        UserDefaults.standard.set(done, forKey: stepsKey)
        sender.record("setup_step", extra.merging(["step": .text(step)]) { $1 })
    }
    static func aiApp(_ app: AIApp) -> String { UsageCounts.aiApp(clientName: nil, connection: app.id) }

    // MARK: Summaries

    /// WriterIntegration (through its `noteSummaryOutcome` hook, set in `start`): one note's outcome. `mode`: the writer's provider ("local" or "cloud").
    static func noteSummary(mode: String, _ outcome: String) {
        guard sender.enabled, sender.home != nil else { return }
        let key = (mode == "cloud" ? "openrouter" : "local") + "_" + outcome
        guard UsageCounts.summaryKeys.contains(key) else { return }
        var counts = UserDefaults.standard.dictionary(forKey: summaryCountsKey) as? [String: Int] ?? [:]
        counts[key, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: summaryCountsKey)
    }
    static func problem(_ phase: SummaryPhase) -> String {
        guard case .failed(let problem) = phase else { return "none" }
        switch problem {
        case .cloudKey: return "key"
        case .cloudCredits: return "credits"
        case .cloudOffline: return "offline"
        case .cloudHost: return "host"
        default: return "other"
        }
    }

    // MARK: Daily

    static func dailyCheck(now: Date = Date()) {
        guard let model, sender.enabled, let home = sender.home else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"
        let key = format.string(from: today)
        guard UserDefaults.standard.string(forKey: dailyKey) != key, let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return }
        UserDefaults.standard.set(key, forKey: dailyKey)
        var properties: [String: UsageValue] = [
            "recording": .text(recording(model.recordingState.kind)),
            "accessibility_ok": .bool(model.permissionSnapshot.accessibility == true),
            "input_monitoring_ok": .bool(model.permissionSnapshot.inputMonitoring == true),
            "summaries": .text(summaries(model.noteWriter.provider)),
            "connected_ai_apps": .list(model.connection.rows.filter { $0.installed && $0.state == .connected }.map { aiApp($0.app) }),
            "chrome_pages": .bool(model.browserPagesSaved),
        ]
        var result: [String: UsageValue] = (UserDefaults.standard.dictionary(forKey: summaryCountsKey) as? [String: Int] ?? [:])
            .filter { UsageCounts.summaryKeys.contains($0.key) && $0.value > 0 }.mapValues { .int($0) }
        let problem = problem(model.noteWriter.phase)
        UserDefaults.standard.removeObject(forKey: summaryCountsKey)
        if !result.isEmpty || problem != "none" { result["problem"] = .text(problem) }
        // The day's recorded time, read off the main thread from a read-only connection of its own.
        Task.detached(priority: .utility) {
            let seconds = try? MemoryStore(home: home).recordedSeconds(start: yesterday, end: today)
            await MainActor.run {
                if let seconds { properties["hours_recorded_bucket"] = .text(UsageCounts.hoursBucket(seconds: seconds)) }
                sender.record("daily_check", properties, at: now)
                if !result.isEmpty { sender.record("summaries_result", result, at: now) }
            }
        }
    }
    static func recording(_ state: DaydreamCaptureState) -> String {
        switch state { case .recording: return "on"; case .paused: return "paused"; case .off, .needsPermission: return "off" }
    }
    static func summaries(_ provider: String) -> String { provider == "local" ? "local" : provider == "cloud" ? "openrouter" : "off" }

    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }
    static var chip: String {
        #if arch(arm64)
        return "apple_silicon"
        #else
        return "intel"
        #endif
    }
}

/// The app delegate SwiftUI forwards to (`MacMemApplication`): only to count opens. Reopen keeps AppKit's and SwiftUI's
/// usual behavior (true: a window opens when none is showing).
final class DaydreamAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { UsageReport.launched(atLogin: Self.launchedAtLogin) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { UsageReport.opened("dock") }
        return true
    }
    /// macOS marks the open event of a login item (keyAELaunchedAsLogInItem).
    static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}

/// Settings › Advanced's usage counts card, following the sender.
struct UsageSharingSettingsHost: View {
    @ObservedObject var usage = UsageSender.shared
    var body: some View {
        UsageSharingCard(isOn: Binding(get: { usage.enabled }, set: { usage.setEnabled($0) }), installID: usage.installID,
                         entries: usage.recent.enumerated().map { UsageSharingEntry(id: $0.offset, sent: $0.element.sent, json: usage.json($0.element)) },
                         refresh: { UsageReport.drainInbox() })
    }
}
