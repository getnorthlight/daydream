import AppKit
import MemoryCore

/// An AI app's running copy, as Settings › Connections sees it.
struct RunningAIApp: Equatable, Sendable {
    let pid: pid_t
    let launchDate: Date?
    let bundleURL: URL?
}

/// A `mac-mem … --client <id> … mcp` an AI app is running (read from the process list only: its arguments and start
/// time, never its memory, files or what it answers).
struct ConnectionServer: Equatable, Sendable {
    let pid: pid_t
    /// The AI app's id (the entry's `--client` label).
    let client: String
    let started: Date
}

/// Everything Settings › Connections does outside DayDream's own files: find an AI app, see whether it is running,
/// quit and reopen it, open its new-chat link, and copy the starter prompt. The app uses `LiveAIAppControl`; checks
/// pass a fake, so nothing is launched, quit, opened or copied while they run. Nothing here types into another app.
protocol AIAppControlling: Sendable {
    /// Where the app is installed, or nil when it isn't on this Mac.
    func location(_ app: AIApp, env: AIAppConnectEnvironment) -> URL?
    /// The app's running copy, or nil. Read on the main thread, where the list of running apps is kept current.
    @MainActor func running(_ app: AIApp) -> RunningAIApp?
    /// The bundle identifier of the app that opens `url`, or nil when no app does.
    func handler(for url: URL) -> String?
    /// When DayDream last changed this app's settings file from Settings (kept across launches).
    func lastChange(_ app: AIApp) -> Date?
    func recordChange(_ app: AIApp, at date: Date)
    /// Asks the running app to quit (`force`: force-quits it) and waits up to `timeout` seconds. True when it exited.
    @MainActor func quit(_ running: RunningAIApp, force: Bool, timeout: TimeInterval) async -> Bool
    /// Opens the app again without bringing it in front of DayDream.
    @MainActor func reopen(_ url: URL) async -> Bool
    /// Opens a link in the app that handles it.
    @MainActor func open(_ url: URL) -> Bool
    /// Puts `text` on the clipboard.
    @MainActor func copy(_ text: String)
    /// Every `mac-mem … mcp` running for this user that an AI app started from a Connect entry.
    func connectionServers() -> [ConnectionServer]
    /// Since when this Mac's DayDream starts servers that carry on as the updated copy after an update (kept across
    /// launches). One started earlier runs a copy from before then, which can't: once DayDream is updated it answers
    /// every request with an error until its AI app starts it again.
    func renewingServersSince() -> Date?
    /// claude/recall-1004: since when this Mac's DayDream has offered the tool list it offers now (kept across launches).
    /// An AI app keeps the tool list its DayDream server gave it when it started, also after the server carries on as the
    /// updated copy; one started earlier has an older list, which can lack tools the replies name, until it restarts.
    func toolsChangedSince() -> Date?
    /// Calls `changed` when an app launches or quits, or DayDream becomes the active app, until `stopObserving`.
    @MainActor func observe(_ changed: @escaping @MainActor () -> Void) -> [NSObjectProtocol]
    @MainActor func stopObserving(_ tokens: [NSObjectProtocol])
}

extension AIAppControlling {
    func connectionServers() -> [ConnectionServer] { [] }
    func renewingServersSince() -> Date? { nil }
    func toolsChangedSince() -> Date? { nil }
}

/// The real Mac: LaunchServices, NSRunningApplication, NSWorkspace and the general pasteboard. Quitting is the
/// standard polite quit (`terminate()`); `force` is used only when the person presses Force Quit & Reopen.
struct LiveAIAppControl: AIAppControlling {
    static let changesKey = "DaydreamConnectionChanges"

    func location(_ app: AIApp, env: AIAppConnectEnvironment) -> URL? {
        for id in app.bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        let fm = FileManager.default
        for folder in env.applicationFolders {
            for bundle in app.bundles where fm.fileExists(atPath: folder.appendingPathComponent(bundle).path) {
                return folder.appendingPathComponent(bundle)
            }
        }
        return nil
    }

    @MainActor func running(_ app: AIApp) -> RunningAIApp? {
        // By bundle identifier when it is known; otherwise by the app bundle's name (Cursor.app, Windsurf.app).
        let candidates = app.bundleIDs.isEmpty
            ? NSWorkspace.shared.runningApplications.filter { $0.bundleURL.map { app.bundles.contains($0.lastPathComponent) } ?? false }
            : app.bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        guard let found = candidates.first(where: { !$0.isTerminated }) else { return nil }
        return RunningAIApp(pid: found.processIdentifier, launchDate: found.launchDate, bundleURL: found.bundleURL)
    }

    func handler(for url: URL) -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    func lastChange(_ app: AIApp) -> Date? {
        guard let seconds = (UserDefaults.standard.dictionary(forKey: Self.changesKey)?[app.id] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func recordChange(_ app: AIApp, at date: Date) {
        var changes = UserDefaults.standard.dictionary(forKey: Self.changesKey) ?? [:]
        changes[app.id] = date.timeIntervalSince1970
        UserDefaults.standard.set(changes, forKey: Self.changesKey)
    }

    /// This user's processes named `mac-mem` whose arguments are a Connect entry's (`--client <id> … mcp`). Reads the
    /// process list and each match's arguments (the same user's, as `ps` does); nothing is logged or kept.
    func connectionServers() -> [ConnectionServer] {
        Self.connectionServers(named: "mac-mem")
    }

    static func connectionServers(named name: String) -> [ConnectionServer] {
        let uid = getuid()
        let size = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard size > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.stride + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        var servers: [ConnectionServer] = []
        for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.stride) where pid > 0 {
            var info = proc_bsdinfo()
            let wanted = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, wanted) == wanted else { continue }
            let command = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard command == name, let arguments = arguments(pid), arguments.last == "mcp",
                  let flag = arguments.firstIndex(of: "--client"), flag + 1 < arguments.count,
                  let recipient = arguments.firstIndex(of: "--recipient"), recipient + 1 < arguments.count,
                  arguments[recipient + 1] == AIAppConnect.recipient else { continue }
            let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
            servers.append(ConnectionServer(pid: pid, client: arguments[flag + 1], started: started))
        }
        return servers
    }

    /// A process's arguments (`KERN_PROCARGS2`: argc, the executable path, then argv), or nil when they can't be read.
    private static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX], limit: Int32 = 0, length = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &limit, &length, nil, 0) == 0, limit > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(limit))
        // The buffer also holds the process's environment (an AI app's server has its DayDream key there): only the
        // arguments are read, and the buffer is wiped before it is freed.
        defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count < 4096 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 } // the executable path
        while index < size && buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(count) && index < size {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == Int(count) ? arguments : nil
    }

    static let renewingKey = "DaydreamRenewingServersSince"

    /// Kept the first time a DayDream with this code runs: when its `mac-mem` was put in place (the file's status-change
    /// time, set when the update or the copy wrote it; the modification time keeps the build's date). Every later
    /// DayDream keeps the same date, so a server that carried itself on across later updates still counts as current.
    func renewingServersSince() -> Date? {
        if let seconds = (UserDefaults.standard.object(forKey: Self.renewingKey) as? NSNumber)?.doubleValue {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let cli = ConnectionSettingsModel.bundledCLI(), let placed = Self.placed(cli) else { return nil }
        UserDefaults.standard.set(placed.timeIntervalSince1970, forKey: Self.renewingKey)
        return placed
    }

    static let toolsKey = "DaydreamMCPToolsSince"

    /// Kept with the tool names it is for: the first DayDream that runs with these names keeps when its `mac-mem` was put
    /// in place, and every later DayDream with the same names keeps that date. New names (an update that adds, renames
    /// or removes a tool) start a new date. With no kept date yet (the first DayDream with this code), the older list
    /// isn't known, so it counts as changed: an AI app that started its server before this copy restarts once.
    func toolsChangedSince() -> Date? {
        let names = AssistantCatalog.toolNames.joined(separator: ",")
        if let kept = UserDefaults.standard.dictionary(forKey: Self.toolsKey), kept["tools"] as? String == names,
           let seconds = (kept["since"] as? NSNumber)?.doubleValue {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let cli = ConnectionSettingsModel.bundledCLI(), let placed = Self.placed(cli) else { return nil }
        UserDefaults.standard.set(["tools": names, "since": placed.timeIntervalSince1970] as [String: Any], forKey: Self.toolsKey)
        return placed
    }

    static func placed(_ file: URL) -> Date? {
        var info = stat()
        guard stat(file.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_ctimespec.tv_sec) + TimeInterval(info.st_ctimespec.tv_nsec) / 1_000_000_000)
    }

    @MainActor func quit(_ running: RunningAIApp, force: Bool, timeout: TimeInterval) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: running.pid), !app.isTerminated else { return true }
        // False: macOS didn't pass the request on, so there is nothing to wait for.
        let asked = force ? app.forceTerminate() : app.terminate()
        guard asked else { return app.isTerminated }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.isTerminated || !Self.alive(running.pid) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return app.isTerminated || !Self.alive(running.pid)
    }

    private static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno != ESRCH }

    @MainActor func reopen(_ url: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        return await withCheckedContinuation { done in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                done.resume(returning: app != nil && error == nil)
            }
        }
    }

    @MainActor func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }

    @MainActor func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor func observe(_ changed: @escaping @MainActor () -> Void) -> [NSObjectProtocol] {
        let workspace = NSWorkspace.shared.notificationCenter
        let notify: @Sendable (Notification) -> Void = { _ in Task { @MainActor in changed() } }
        // Only the AI apps Connections lists: other apps launching or quitting change nothing here.
        let aiApp: @Sendable (Notification) -> Void = { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  AIAppConnect.apps.contains(where: { known in
                      app.bundleIdentifier.map(known.bundleIDs.contains) == true
                          || (known.bundleIDs.isEmpty && app.bundleURL.map { known.bundles.contains($0.lastPathComponent) } == true)
                  }) else { return }
            notify(note)
        }
        return [workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: aiApp),
                workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: aiApp),
                NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: notify)]
    }

    @MainActor func stopObserving(_ tokens: [NSObjectProtocol]) {
        guard tokens.count == 3 else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(tokens[0])
        NSWorkspace.shared.notificationCenter.removeObserver(tokens[1])
        NotificationCenter.default.removeObserver(tokens[2])
    }
}
