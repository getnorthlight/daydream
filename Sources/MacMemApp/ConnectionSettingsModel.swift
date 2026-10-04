import Foundation
import SwiftUI
import MemoryCore
import MemoryUI

/// Runs DayDream's own command-line tool for Connect and Disconnect, so the button and Terminal do the same
/// thing (`mac-mem connect <app>`). Checks substitute a fake.
protocol ConnectionCommandRunning: Sendable {
    func run(_ arguments: [String]) async -> ConnectionCommandOutput
}

struct ConnectionCommandOutput: Sendable, Equatable {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// `Contents/MacOS/mac-mem` of this app, run with fixed arguments and no shell.
struct BundledConnectionCommand: ConnectionCommandRunning {
    let executable: URL
    func run(_ arguments: [String]) async -> ConnectionCommandOutput {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    done.resume(returning: ConnectionCommandOutput(status: -1, stdout: "", stderr: "DayDream's command-line tool couldn't start."))
                    return
                }
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                done.resume(returning: ConnectionCommandOutput(status: process.terminationStatus,
                    stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self)))
            }
        }
    }
}

/// Settings › Connections: one row per AI app, each with one button. Connect is one click: DayDream checks the
/// app's settings file first, quits the app if it is running, writes its entry through `mac-mem connect` (pinned to
/// the file as just read), then opens the app on a new chat with a starter prompt typed in (not sent) when the app
/// has a new-chat link, or opens it again and copies the prompt when it hasn't (the button's help tag says so).
/// Disconnect is the same, without the prompt. Status reads the settings files, DayDream's own key and the running apps; it never writes. Replacing an
/// entry that starts another copy of DayDream asks first (`pendingReplace`).
@MainActor final class ConnectionSettingsModel: ObservableObject {
    struct Row: Identifiable, Equatable, Sendable {
        let app: AIApp
        /// What the app's settings file says about DayDream's entry and key.
        var state: AIAppConnectionState
        /// The app is on this Mac.
        var installed = true
        /// Where the app is (its icon, and where it is opened again).
        var location: URL?
        /// Its running copy, if any.
        var running: RunningAIApp?
        /// Connected, but the running app started before DayDream last changed its settings file, so it hasn't
        /// loaded DayDream yet, or it still runs a DayDream from before an update, which answers only with errors.
        var needsRestart = false
        /// Connected, and no app to restart (Claude Code), but a session still runs a DayDream from before an update.
        var oldSession = false
        /// The other copy of DayDream the entry starts (shown before replacing it). Nil when that copy is gone.
        var otherCopy: String?
        /// The app's documented new-chat link with the starter prompt, when the app that opens it is this AI app.
        var newChat: URL?
        var id: String { app.id }
    }

    /// What a row shows: one status line, at most one button, and a reason when there is no button.
    struct RowPresentation: Equatable {
        enum Tone: Equatable { case quiet, good, attention, failure }
        enum Action: Equatable { case connect, disconnect, restart, forceRestart }
        struct Control: Equatable {
            let title: String
            let action: Action
        }
        var status: String
        var symbol: String
        var tone: Tone
        var working = false
        var button: Control?
        var detail: String?
        var dimmed = false
    }

    enum Phase: Equatable {
        /// A step of Connect, Disconnect or Restart is running; the text says which.
        case working(String)
        /// The change was written, but the app didn't quit when asked.
        case quitRefused
        /// It didn't work; `state` is what the row showed then (a later, different state clears it).
        case failed(String, state: AIAppConnectionState)
    }

    struct PendingReplace: Identifiable, Equatable {
        let app: AIApp
        let otherCopy: String
        var id: String { app.id }
    }

    /// The starter prompt after Connect (owner's words, 9/30). It holds no history and asks for no recap: the AI app
    /// explains DayDream, checks the setup with DayDream's `status` tool (connected, recording, typing verified) and
    /// suggests questions from its `examples`. Typed into the app's new chat when its link fits
    /// (`AIApp.newChatLinkMaxLength`), otherwise copied.
    nonisolated static let starterPrompt = "Explain what DayDream does, what you can use it for here, and how to get started. Check that DayDream is connected and ready to use, explain any setup issue simply, and give me three example questions I can ask."
    /// How long an AI app gets to quit when asked.
    static let quitTimeout: TimeInterval = 10

    @Published private(set) var rows: [Row]
    @Published private(set) var phases: [String: Phase] = [:]
    /// The app whose starter prompt shows: the one last connected from this page, until the page closes.
    @Published private(set) var promptApp: String?
    /// The app whose Connect, Disconnect or Restart is running. Other buttons wait.
    @Published private(set) var working: String?
    /// Connect would replace an entry that starts another copy of DayDream: the page asks first.
    @Published var pendingReplace: PendingReplace?
    /// Force Quit & Reopen was pressed: the page asks first (anything unsaved in the app is lost).
    @Published var pendingForceQuit: AIApp?
    @Published private(set) var loaded = false
    /// A saved change to Apps to remember turned the keys off this run (the app model sets it), so a key that stopped
    /// working can say why.
    @Published var disconnectedByAppsChange = false
    /// Connected, but the app didn't quit: the prompt comes when it restarts.
    private var promptOnReopen: Set<String> = []

    let environment: AIAppConnectEnvironment
    /// This app's `mac-mem`, or nil when it's missing.
    let cli: URL?
    /// DayDream's history folder, for checking keys.
    let home: URL
    /// Written as `--home` when the history isn't in the usual place (the command-line tool does the same).
    let pinnedHome: URL?
    let control: any AIAppControlling
    private let runner: (any ConnectionCommandRunning)?
    private let verifier: @Sendable (AIApp, String) -> Bool?
    private var refreshGeneration = 0
    private var observers: [NSObjectProtocol] = []

    init(environment: AIAppConnectEnvironment = .live, cli: URL? = ConnectionSettingsModel.bundledCLI(), home: URL = MemPaths.home(),
         pinnedHome: URL? = ConnectionSettingsModel.environmentHome(), runner: (any ConnectionCommandRunning)? = nil,
         verifier: (@Sendable (AIApp, String) -> Bool?)? = nil, control: any AIAppControlling = LiveAIAppControl()) {
        self.environment = environment
        self.cli = cli
        self.home = home
        self.pinnedHome = pinnedHome
        self.control = control
        self.runner = runner ?? cli.map { BundledConnectionCommand(executable: $0) }
        self.verifier = verifier ?? { app, key in
            // Read-only. With no history at all no key can work; history that can't be opened can't tell (nil).
            guard FileManager.default.fileExists(atPath: home.appendingPathComponent("memory.sqlite").path) else { return false }
            guard let store = try? MemoryStore(home: home) else { return nil }
            return store.connectKeyWorks(app, key: key)
        }
        rows = AIAppConnect.apps.map { Row(app: $0, state: .notConnected) }
    }

    /// The app's model: reads the connections once at launch, for the Settings overview.
    static func remembered() -> ConnectionSettingsModel {
        let model = ConnectionSettingsModel()
        model.refresh()
        return model
    }

    nonisolated static func bundledCLI(_ bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL.appendingPathComponent("Contents/MacOS/mac-mem").standardizedFileURL.resolvingSymlinksInPath()
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    nonisolated static func environmentHome() -> URL? {
        guard let value = ProcessInfo.processInfo.environment["MAC_MEM_HOME"], !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    }

    static let reconnectNeeded = SettingsRowsSnapshot.reconnectNeeded

    /// The Settings overview's Connections accessory. "Not connected" hides it.
    var phaseLabel: String {
        let connected = rows.filter { $0.installed && $0.state == .connected }
        switch connected.count {
        case 0:
            return rows.contains { row in
                guard row.installed, case .needsAttention(let attention) = row.state else { return false }
                return attention.reconnects
            } ? Self.reconnectNeeded : "Not connected"
        case 1: return connected[0].app.name
        default: return "\(connected.count) AI apps"
        }
    }

    /// Why no app can be connected from this copy of DayDream, if so.
    var unavailable: String? {
        guard let cli else { return "DayDream's command-line tool is missing from this copy of the app, so AI apps can't be connected from here." }
        return AIAppConnect.commandProblem(cli)
    }

    /// Where Connect writes, for the button's help tag.
    func settingsFile(_ app: AIApp) -> String { AIAppConnect.display(AIAppConnect.file(app, environment), environment) }

    // MARK: What each row shows

    func presentation(_ row: Row) -> RowPresentation {
        // Before the first read nothing is known: no status is guessed and no button is offered.
        guard loaded else { return RowPresentation(status: "Checking…", symbol: "clock", tone: .quiet, working: true) }
        let name = row.app.name
        let restart = row.running != nil
        let connect = RowPresentation.Control(title: restart ? "Connect & Restart" : "Connect", action: .connect)
        let reconnect = RowPresentation.Control(title: restart ? "Reconnect & Restart" : "Reconnect", action: .connect)
        let disconnect = RowPresentation.Control(title: restart ? "Disconnect & Restart" : "Disconnect", action: .disconnect)
        let ours: Bool = {
            if row.state == .connected { return true }
            if case .needsAttention(let attention) = row.state { return attention.reconnects }
            return false
        }()
        // The button the row's state offers; a failure keeps it, so trying again is the same click.
        let normal: RowPresentation.Control? = {
            if !row.installed { return ours ? disconnect : nil }
            switch row.state {
            case .notInstalled: return nil
            case .notConnected: return connect
            case .connected: return row.needsRestart ? .init(title: "Restart", action: .restart) : disconnect
            case .needsAttention(let attention): return attention.reconnects ? reconnect : nil
            }
        }()
        switch phases[row.id] {
        case .working(let text)?:
            return RowPresentation(status: text, symbol: "clock", tone: .quiet, working: true)
        case .failed(let text, _)?:
            return RowPresentation(status: text, symbol: "exclamationmark.circle.fill", tone: .failure, button: normal)
        case .quitRefused? where row.state == .connected:
            return RowPresentation(status: "Quit \(name) and open it again to finish.", symbol: "arrow.clockwise.circle.fill", tone: .attention,
                                   button: .init(title: "Force Quit & Reopen", action: .forceRestart))
        default: break
        }
        if !row.installed {
            return RowPresentation(status: "Not installed", symbol: "minus.circle", tone: .quiet, button: normal, dimmed: !ours)
        }
        switch row.state {
        case .notInstalled:
            return RowPresentation(status: "Not installed", symbol: "minus.circle", tone: .quiet, dimmed: true)
        case .notConnected:
            return RowPresentation(status: "Not connected", symbol: "circle.dashed", tone: .quiet, button: normal)
        case .connected where row.needsRestart:
            return RowPresentation(status: "Quit \(name) and open it again to finish.", symbol: "arrow.clockwise.circle.fill", tone: .attention, button: normal)
        case .connected where row.oldSession:
            return RowPresentation(status: "Start a new \(name) session to finish.", symbol: "arrow.clockwise.circle.fill", tone: .attention, button: normal)
        case .connected:
            return RowPresentation(status: "Connected", symbol: "checkmark.circle.fill", tone: .good, button: normal)
        case .needsAttention(.keyStopped):
            return RowPresentation(status: disconnectedByAppsChange ? "Disconnected after an Apps change" : "Disconnected",
                                   symbol: "exclamationmark.circle.fill", tone: .attention, button: normal)
        case .needsAttention(.otherCopy):
            return RowPresentation(status: "Uses another copy of DayDream", symbol: "exclamationmark.circle.fill", tone: .attention, button: normal)
        case .needsAttention(.addedByHand):
            return RowPresentation(status: "Set up by hand", symbol: "info.circle", tone: .quiet,
                                   detail: AIAppAttention.addedByHand.reason(row.app))
        case .needsAttention(.unreadable(let reason)):
            return RowPresentation(status: "Can't read its settings file", symbol: "exclamationmark.circle.fill", tone: .attention, detail: reason)
        }
    }

    /// The rows the page lists: every AI app on this Mac, and one that isn't only while DayDream's entry is still in
    /// its settings file (so it can be disconnected).
    var visibleRows: [Row] { rows.filter { $0.installed || $0.state != .notInstalled } }

    /// Whether a row's button can be pressed now.
    func enabled(_ action: RowPresentation.Action) -> Bool {
        guard working == nil, pendingReplace == nil, pendingForceQuit == nil else { return false }
        switch action {
        case .connect: return runner != nil && unavailable == nil
        case .disconnect: return runner != nil
        case .restart, .forceRestart: return true
        }
    }

    /// The one line after Connect for an app without a new-chat link (the prompt is on the clipboard).
    func promptNote(_ app: AIApp) -> String {
        app.id == "claude-code" ? "Prompt copied. Paste it in a new Claude Code session." : "Prompt copied. Paste it in \(app.name)."
    }

    func forceQuitTitle(_ app: AIApp) -> String { "Force quit \(app.name)?" }
    func forceQuitMessage(_ app: AIApp) -> String { "Anything unsaved in \(app.name) will be lost." }

    func replaceTitle(_ pending: PendingReplace) -> String { "Switch \(pending.app.name) to this copy of DayDream?" }
    func replaceMessage(_ pending: PendingReplace) -> String {
        "\(pending.app.name) now starts another copy of DayDream, at \(pending.otherCopy). DayDream replaces that entry with this copy. If the settings file exists, DayDream first saves a copy next to it."
    }
    func replaceButton(_ pending: PendingReplace) -> String {
        row(pending.app.id)?.running != nil ? "Switch & Restart" : "Switch"
    }

    // MARK: Reading

    /// Reads every app's status off the main thread.
    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let environment = environment, cli = cli, pinnedHome = pinnedHome, verifier = verifier, control = control
        let running = Dictionary(uniqueKeysWithValues: AIAppConnect.apps.map { ($0.id, control.running($0)) })
        Task.detached(priority: .utility) {
            // claude/recall-1004: a server started before the tool list changed restarts too (its AI app's list is older).
            let servers = control.connectionServers()
            let since = [control.renewingServersSince(), control.toolsChangedSince()].compactMap { $0 }.max()
            let rows = AIAppConnect.apps.map { Self.read($0, running: running[$0.id] ?? nil, environment: environment, cli: cli, pinnedHome: pinnedHome,
                                                         verifier: verifier, control: control, servers: servers, renewingSince: since) }
            await MainActor.run { [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                self.rows = rows
                self.settle()
                self.loaded = true
            }
        }
    }

    nonisolated static func read(_ app: AIApp, running: RunningAIApp?, environment: AIAppConnectEnvironment, cli: URL?, pinnedHome: URL?,
                                 verifier: @Sendable (AIApp, String) -> Bool?, control: any AIAppControlling,
                                 servers: [ConnectionServer] = [], renewingSince: Date? = nil) -> Row {
        var state = AIAppConnect.status(app, env: environment, command: cli, home: pinnedHome) { verifier(app, $0) }
        let location = control.location(app, env: environment)
        // An app with a known bundle identifier is on this Mac only when macOS finds it (its settings folder can
        // outlive it); the others count their settings file and folders too, as the command-line tool does.
        let installed = location != nil || (app.bundleIDs.isEmpty && AIAppConnect.installed(app, environment))
        // The status reads .notInstalled only when there is no settings file (an app's settings folder counts as
        // installed there), so an app macOS found elsewhere is simply not connected yet.
        if installed && state == .notInstalled { state = .notConnected }
        if !installed && state == .notConnected { state = .notInstalled }
        let running = installed ? running : nil
        // When DayDream last wrote the file: recorded by Settings, or the backup it saves just before each change
        // (so a Connect from Terminal counts too). The file's own date isn't used: AI apps save it themselves.
        let backup = (try? FileManager.default.attributesOfItem(atPath: AIAppConnect.backupFile(app, environment).path))?[.modificationDate] as? Date
        var changed = [control.lastChange(app), backup].compactMap { $0 }.max()
        // Neither: the entry was written some other way, such as `mac-mem connect` creating the file (no copy to
        // save). Then the file's own date is the best known; an app saving the file itself later can only ask for
        // one restart too many, never show Connected before the app has loaded DayDream.
        if changed == nil, state == .connected {
            changed = (try? FileManager.default.attributesOfItem(atPath: AIAppConnect.file(app, environment).path))?[.modificationDate] as? Date
        }
        var needsRestart = false
        // A running copy with no launch date (started outside LaunchServices) can't be shown to have loaded it.
        if state == .connected, let running {
            if let launched = running.launchDate { needsRestart = changed.map { launched < $0 } ?? false } else { needsRestart = true }
        }
        // A DayDream server this app started before DayDream could carry its servers across an update (test 4 and
        // earlier) stays the old copy for good: after the update every request it gets fails. The app loads the
        // current one only when it starts the server again, so it is a restart, never "Connected". claude/recall-1004:
        // `renewingSince` is also when DayDream's tool list last changed: a server started before then carries on as the
        // update, but its AI app keeps the older tool list (without the newer tools its replies name) until it restarts.
        var oldSession = false
        if state == .connected, let renewingSince,
           servers.contains(where: { $0.client == app.id && $0.started < renewingSince }) {
            if let running {
                // Only a server of the copy running now (one left from an earlier run ends with it).
                let current = servers.contains { server in
                    server.client == app.id && server.started < renewingSince && (running.launchDate.map { server.started >= $0 } ?? true)
                }
                if current { needsRestart = true }
            } else if app.bundles.isEmpty && app.bundleIDs.isEmpty {
                oldSession = true
            }
        }
        var otherCopy: String?
        if state == .needsAttention(.otherCopy), let command = AIAppConnect.entryCommand(app, env: environment),
           FileManager.default.isExecutableFile(atPath: command) {
            otherCopy = AIAppConnect.display(URL(fileURLWithPath: command), environment)
        }
        var newChat: URL?
        if let link = app.newChatLink(starterPrompt), let handler = control.handler(for: link), app.bundleIDs.contains(handler) { newChat = link }
        return Row(app: app, state: state, installed: installed, location: location, running: running, needsRestart: needsRestart,
                   oldSession: oldSession, otherCopy: otherCopy, newChat: newChat)
    }

    /// Drops what no longer matches a row after a read: a prompt for an app that isn't connected, a failure from an
    /// earlier state, a "didn't quit" once the app has restarted.
    private func settle() {
        // The reason a key stopped holds only while one is stopped: once every app is connected again (or disconnected),
        // a key that stops later for another reason (a restore, `mac-mem disconnect`) must not be blamed on Apps.
        if !rows.contains(where: { $0.state == .needsAttention(.keyStopped) }) { disconnectedByAppsChange = false }
        for row in rows {
            if row.state != .connected && promptApp == row.id { promptApp = nil }
            switch phases[row.id] {
            case .failed(_, let state)? where state != row.state: phases[row.id] = nil
            case .quitRefused? where !row.needsRestart: phases[row.id] = nil; promptOnReopen.remove(row.id)
            default: break
            }
        }
    }

    func row(_ id: String) -> Row? { rows.first { $0.id == id } }

    /// The page is showing: read now, and again when an AI app launches or quits, or DayDream becomes active.
    func pageAppeared() {
        refresh()
        if observers.isEmpty { observers = control.observe { [weak self] in self?.refresh() } }
    }

    /// The page closed: stop watching, and drop the prompt and any message (a running step finishes on its own).
    func pageDisappeared() {
        control.stopObserving(observers)
        observers = []
        promptApp = nil
        pendingReplace = nil
        pendingForceQuit = nil
        promptOnReopen = []
        phases = phases.filter { if case .working = $0.value { return true } else { return false } }
    }

    // MARK: Buttons

    func perform(_ action: RowPresentation.Action, _ app: AIApp) async {
        switch action {
        case .connect: await connect(app)
        case .disconnect: await disconnect(app)
        case .restart: await restart(app, force: false)
        // Asks first: Force Quit & Reopen shows only after the app didn't quit when asked, usually because it is
        // asking the person something (such as whether to save), so what's unsaved would be lost.
        case .forceRestart: if enabled(.forceRestart) { pendingForceQuit = app }
        }
    }

    /// The person agreed to force quit. The alert passes what it showed, so dismissing it can't cancel the answer.
    func confirmForceQuit(_ app: AIApp) async {
        pendingForceQuit = nil
        await restart(app, force: true)
    }

    func cancelForceQuit() { pendingForceQuit = nil }

    /// Connect in one click. The settings file is checked before the app is touched; an entry that starts another
    /// copy of DayDream is replaced only after the person agrees (`replacing`).
    func connect(_ app: AIApp, replacing: Bool = false) async {
        guard enabled(.connect), let cli else { return }
        let verifier = verifier
        let plan: AIAppConnectPlan
        do { plan = try AIAppConnect.plan(.connect, app, env: environment, command: cli, home: pinnedHome) { verifier(app, $0) } }
        catch { fail(app, Self.describe(error)); return }
        if plan.outcome == .alreadyConnected { phases[app.id] = nil; showPromptInPlace(app); refresh(); return }
        if plan.outcome == .replace, !replacing, let other = row(app.id)?.otherCopy {
            pendingReplace = PendingReplace(app: app, otherCopy: other)
            return
        }
        working = app.id
        if promptApp == app.id { promptApp = nil }
        let running = control.running(app)
        var quit = false
        if let running {
            phases[app.id] = .working("Quitting \(app.name)…")
            quit = await control.quit(running, force: false, timeout: Self.quitTimeout)
        }
        phases[app.id] = .working("Connecting…")
        let failure = await write(.connect, app)
        if let failure {
            if quit, let running { await reopen(app, running) }
            fail(app, failure)
        } else if running != nil && !quit {
            // Still running the old way: no prompt until it restarts (Force Quit & Reopen, or the person quits it).
            phases[app.id] = .quitRefused
            promptOnReopen.insert(app.id)
        } else {
            await showPrompt(app, reopening: running)
            phases[app.id] = nil // after the reopen, which says "Opening…" while it runs
        }
        working = nil
        refresh()
    }

    /// The person agreed to replace the entry that starts another copy of DayDream. The alert passes what it showed,
    /// so dismissing it (which clears `pendingReplace`) can't cancel the answer.
    func replace(_ pending: PendingReplace) async {
        pendingReplace = nil
        await connect(pending.app, replacing: true)
    }

    func cancelReplace() { pendingReplace = nil }

    /// Disconnect in one click: quits the app if it is running, removes DayDream's entry and turns its key off, and
    /// opens the app again. The key is off even if the app doesn't quit.
    func disconnect(_ app: AIApp) async {
        guard enabled(.disconnect) else { return }
        working = app.id
        if promptApp == app.id { promptApp = nil }
        let running = control.running(app)
        var quit = false
        if let running {
            phases[app.id] = .working("Quitting \(app.name)…")
            quit = await control.quit(running, force: false, timeout: Self.quitTimeout)
        }
        phases[app.id] = .working("Disconnecting…")
        let failure = await write(.disconnect, app)
        if quit, let running { await reopen(app, running) }
        phases[app.id] = nil
        if let failure { fail(app, failure) }
        working = nil
        refresh()
    }

    /// Quits and reopens a connected app that hasn't loaded DayDream yet. `force` only after it didn't quit.
    func restart(_ app: AIApp, force: Bool) async {
        guard enabled(.restart) else { return }
        guard let running = control.running(app) else { phases[app.id] = nil; refresh(); return }
        working = app.id
        phases[app.id] = .working("Quitting \(app.name)…")
        if await control.quit(running, force: force, timeout: force ? 5 : Self.quitTimeout) {
            if promptOnReopen.remove(app.id) != nil { await showPrompt(app, reopening: running) }
            else { await reopen(app, running) }
            phases[app.id] = nil
        } else {
            phases[app.id] = .quitRefused
        }
        working = nil
        refresh()
    }

    /// After Connect. An app with a new-chat link opens on it, in front: a new chat with the starter prompt typed in,
    /// not sent, and nothing is copied. Any other app (or a link that didn't open) opens again (`reopening`: the copy
    /// that quit) and the prompt is copied, with one line saying so.
    private func showPrompt(_ app: AIApp, reopening: RunningAIApp?) async {
        if let link = row(app.id)?.newChat, control.open(link) { promptApp = nil; return }
        if let reopening { await reopen(app, reopening) }
        promptApp = app.id
        control.copy(Self.starterPrompt)
    }

    /// Already connected: the same prompt, without quitting anything.
    private func showPromptInPlace(_ app: AIApp) {
        if let link = row(app.id)?.newChat, control.open(link) { promptApp = nil; return }
        promptApp = app.id
        control.copy(Self.starterPrompt)
    }

    private func reopen(_ app: AIApp, _ running: RunningAIApp) async {
        guard let url = running.bundleURL ?? row(app.id)?.location else { return }
        phases[app.id] = .working("Opening \(app.name)…")
        _ = await control.reopen(url)
    }

    private func fail(_ app: AIApp, _ text: String) {
        phases[app.id] = .failed(text, state: row(app.id)?.state ?? .notConnected)
    }

    /// Runs `mac-mem connect|disconnect` pinned to the settings file as it is now. Returns the reason on failure.
    /// An AI app often saves its settings file as it quits, a moment after the file was read: the tool then refuses
    /// (the file changed since it was read) and nothing is written. That is read again and tried again, up to
    /// `writeAttempts` times, only while the change is the same kind as the first reading's (never a replace nobody
    /// agreed to).
    private func write(_ action: AIAppConnectAction, _ app: AIApp) async -> String? {
        guard let cli, let runner else { return unavailable ?? "That didn't work. Nothing was changed." }
        let verifier = verifier
        let verb = action == .connect ? "Connect" : "Disconnect"
        var first: AIAppConnectPlan.Outcome?
        for attempt in 1...Self.writeAttempts {
            let plan: AIAppConnectPlan
            // Read again here: the app may have saved its settings file as it quit.
            do { plan = try AIAppConnect.plan(action, app, env: environment, command: cli, home: pinnedHome) { verifier(app, $0) } }
            catch { return Self.describe(error) }
            if action == .connect && plan.outcome == .alreadyConnected { return nil }
            if let first, plan.outcome != first { return Self.changedJustThen }
            first = plan.outcome
            let output = await runner.run([action.rawValue, app.id, "--yes", "--json", "--expect-sha256", plan.reviewedSHA256])
            let reply = (try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8))) as? [String: Any]
            if output.status == 0, reply?["message"] is String {
                if reply?["wrote"] as? Bool == true { control.recordChange(app, at: Date()) }
                DiagnosticsLog.shared.record("\(action == .connect ? "Connected" : "Disconnected") \(app.name).")
                return nil
            }
            let reason = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            // The tool's words suit Terminal, where the plan is shown first; here the file was read a moment before.
            if reason == AIAppConnectError.changedSinceReview.description {
                if attempt < Self.writeAttempts {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 150_000_000)
                    continue
                }
                DiagnosticsLog.shared.record("\(verb) \(app.name) failed: the settings file kept changing.")
                return Self.changedJustThen
            }
            DiagnosticsLog.shared.record("\(verb) \(app.name) failed: \(reason)")
            return reason.isEmpty ? "That didn't work. Nothing was changed." : reason
        }
        return Self.changedJustThen
    }

    /// How many times Connect or Disconnect reads the settings file and writes, when it changes in between.
    nonisolated static let writeAttempts = 3
    nonisolated static let changedJustThen = "The settings file changed just then, so nothing was written. Try again."

    nonisolated static func describe(_ error: Error) -> String {
        // Report a Problem lists the code only (the error's type and case), never this message.
        ProblemReportErrors.shared.record(error)
        if (error as? AIAppConnectError) == .changedSinceReview { return changedJustThen }
        return (error as? AIAppConnectError)?.description ?? "That didn't work: \(error.localizedDescription)"
    }
}
