import SwiftUI
import AppKit
import Combine
import MemoryCore
import MemoryUI

// Report a Problem… (Help, AppCommands.swift; and the menu bar menu above Quit DayDream, MenuBarContent.swift) opens a
// new email to support@getdaydream.app in the person's default mail app, as a mailto: link. The person reads it and
// presses Send there: this code has no network calls and sends nothing. When no mail app takes the link, the same text
// goes on the clipboard and one line says so. What the email may hold, and the checks that keep everything else out:
// Sources/MemoryCore/ProblemReportMail.swift.

@MainActor enum ReportProblemMail {
    /// Where the action leads. The defaults are the Mac's; the checks inject recorders (nothing is opened or copied).
    struct Routes {
        /// The app that opens mailto: links, or nil when there is none.
        var mailApp: (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        /// Opens the link in that app; false when it didn't.
        var open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
        var pasteboard: NSPasteboard = .general
        /// Says the one line (an alert with OK), next turn, so the menu bar menu has closed first.
        var say: @MainActor (String) -> Void = { line in
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = line
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    enum Outcome: Equatable { case mail, copied }

    /// The line shown when no mail app opened the email.
    static let copiedLine = "No mail app opened, so the report is copied. Paste it into an email to \(ProblemReportMail.supportAddress)."

    /// Opens the email in the person's mail app, or copies the same text when none takes it.
    @discardableResult
    static func compose(app: MemoryViewModel?, routes: Routes = Routes()) -> Outcome {
        let facts = facts(app: app)
        let link = ProblemReportMail.url(facts)
        if routes.mailApp(link) != nil, routes.open(link) { return .mail }
        routes.pasteboard.clearContents()
        routes.pasteboard.setString(ProblemReportMail.clipboardText(facts), forType: .string)
        routes.say(copiedLine)
        return .copied
    }

    /// The states the email says, read now. Only states, counts and names from DayDream's lists: never a title, a typed
    /// word, a web address, a site, a contact, a path or a key. nil `app`: DayDream hasn't finished starting.
    static func facts(app: MemoryViewModel?, errors: ProblemReportErrors = .shared,
                      info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> ProblemReportFacts {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        func state(_ value: Bool?) -> ProblemReportFacts.Switch { value.map { $0 ? .on : .off } ?? .unknown }
        var facts = ProblemReportFacts(version: info["CFBundleShortVersionString"] as? String ?? "development",
                                       build: info["CFBundleVersion"] as? String ?? "none",
                                       macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                                       errors: errors.recent, errorCount: errors.count)
        guard let app else { return facts }
        facts.accessibility = state(app.permissionSnapshot.accessibility)
        facts.inputMonitoring = state(app.permissionSnapshot.inputMonitoring)
        facts.chromeAutomation = chromeAutomation(app.chromeAccessShown)
        facts.recording = recording(app.recordingState.kind)
        switch app.noteWriter.provider {
        case "local": facts.summaries = .thisMac
        case "cloud": facts.summaries = .cloud
        default: facts.summaries = .off
        }
        facts.connectedApps = app.connection.rows.filter { $0.state == .connected }.map(\.app.name)
        facts.momentsToday = app.activity.today.snapshot?.momentCount
        facts.summariesWaiting = app.noteWriter.pendingCount
        return facts
    }

    /// Chrome automation (System Settings › Privacy & Security › Automation): on when allowed, off when refused or not
    /// asked yet, unknown while it can't be read (Chrome not running, two Chromes, not checked).
    static func chromeAutomation(_ access: ChromeAccessState) -> ProblemReportFacts.Switch {
        switch access {
        case .allowed: return .on
        case .denied, .notAsked, .askFailed: return .off
        case .unknown, .checking, .chromeNotRunning, .unverified, .twoCopies: return .unknown
        }
    }

    static func recording(_ kind: DaydreamCaptureState) -> ProblemReportFacts.Recording {
        switch kind {
        case .recording: return .on
        case .paused: return .paused
        case .off: return .off
        case .needsPermission: return .needsPermission
        }
    }
}

/// Writes DayDream's own log lines for this run (DiagnosticsLog, memory only) from the app's states: recording,
/// problems shown, permission reads, and the status lines of summaries, updates, import and backup.
/// Attached once per app model, from AppCommands.
@MainActor enum ReportProblemLog {
    private static var attached: ObjectIdentifier?
    private static var sinks = Set<AnyCancellable>()

    static func attach(_ model: MemoryViewModel?, log: DiagnosticsLog = .shared) {
        guard let model, attached != ObjectIdentifier(model) else { return }
        attached = ObjectIdentifier(model)
        sinks.removeAll()
        let info = Bundle.main.infoDictionary ?? [:]
        log.record("DayDream \(info["CFBundleShortVersionString"] as? String ?? "development") (build \(info["CFBundleVersion"] as? String ?? "none")) started.")
        // Published values arrive before the property changes: read the model on the next turn. The model re-assigns
        // its states on every refresh (twice a second while recording), so each watcher logs only when its own line
        // changes; a problem that clears and comes back is logged again.
        func watch<P: Publisher>(_ publisher: P, _ line: @escaping (MemoryViewModel) -> String?) where P.Failure == Never {
            var last: String?
            publisher.receive(on: RunLoop.main).sink { [weak model] _ in
                guard let model else { return }
                let text = line(model)
                guard text != last else { return }
                last = text
                if let text { log.record(text) }
            }.store(in: &sinks)
        }
        watch(model.$recording.combineLatest(model.$stopped, model.$pauseUntil, model.$resumeUnavailable)) { "Recording: \($0.shortState)." }
        watch(model.$operationalIssue) { $0.operationalIssue.map { "Problem shown: \($0)" } }
        watch(model.$permissionSnapshot) { model in
            let p = model.permissionSnapshot
            guard p.accessibility != nil || p.inputMonitoring != nil else { return nil }
            func word(_ value: Bool?) -> String { value.map { $0 ? "allowed" : "not allowed" } ?? "not checked" }
            return "Permissions: Accessibility \(word(p.accessibility)), Input Monitoring \(word(p.inputMonitoring))."
        }
        watch(model.$status) { "Status: " + statusLine($0.status, frontNote: $0.recording ? AccessibilityReader.status : nil) }
        watch(model.$privacySaveStatus) { $0.privacySaveStatus.isEmpty ? nil : "Settings: \($0.privacySaveStatus)" }
        watch(model.noteWriter.$status) { "Summaries: \($0.noteWriter.status)" }
        watch(model.updates.$status) { $0.updates.status.isEmpty ? nil : "Updates: \($0.updates.status)" }
        watch(model.history.$status) { $0.history.status.isEmpty ? nil : "Import: \($0.history.status)" }
        watch(model.backups.$status) { $0.backups.status.isEmpty ? nil : "Backup: \($0.backups.status)" }
    }

    /// The status line without what moves on its own: the pending-summaries count (it changes after nearly every save;
    /// the summary writer's own lines say what it does) and the note about the app in front (it changes with every app
    /// switch). What is left changes only when the recording state, a blocker or a problem does, so hours of recording
    /// don't push the lines that matter out of the report.
    static func statusLine(_ status: String, frontNote: String?) -> String {
        var line = status
        if let pending = line.range(of: " Summaries pending:") { line = String(line[..<pending.lowerBound]) }
        if let frontNote, !frontNote.isEmpty, line.hasSuffix(" " + frontNote) { line = String(line.dropLast(frontNote.count + 1)) }
        return line
    }
}
