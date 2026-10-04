// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// Settings › Connections and Help › Report a Problem, as the app runs them (compiled with the MacMemApp sources).
//
// Connections: one row per AI app with a true status and one button. Connect is one click: the settings file is
// checked before the AI app is touched, a running app is asked to quit, DayDream's own command-line tool writes the
// entry pinned to the file as read after the quit, then Claude Desktop opens on its new-chat link with a starter prompt
// typed in (nothing copied), and an app without a link opens again with the prompt copied. The page itself writes nothing. A fake command-line tool (it edits only scratch settings files through AIAppConnect) and a
// fake AI app control (it records every quit, open, reopen and copy) stand in for the real ones. Report a Problem:
// one mailto: link to support opens through a fake mail app; with none, the same text goes on a private pasteboard and
// one line says so; nothing is sent. Light and dark renders go to DD_CHECK_OUT.
//
// Synthetic only: no real home folder, AI app, network, Keychain, general pasteboard or browser. Nothing is launched,
// quit or opened. (The Claude Desktop row may draw Claude.app's icon when it is installed; the icon is only read.)
import SwiftUI
import AppKit
import CryptoKit
@testable import MemoryCore
import MemoryUI

/// Records what Connections asked of the Mac, in order. Shared by the fake control and the fake command-line tool.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    func add(_ event: String) { lock.lock(); _events.append(event); lock.unlock() }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return _events }
    func reset() { lock.lock(); _events = []; lock.unlock() }
}

/// The AI apps as a fake Mac sees them. Nothing here touches a real app or the general pasteboard.
final class FakeAIAppControl: AIAppControlling, @unchecked Sendable {
    private let lock = NSLock()
    let log: EventLog
    private var _locations: [String: URL] = [:]
    private var _running: [String: RunningAIApp] = [:]
    private var _changes: [String: Date] = [:]
    private var _handlers: [String: String] = [:]
    /// Whether a polite quit works. A force quit always does.
    var quits = true
    /// While true, a quit waits (the check renders the page mid-way), until `release()`.
    private var held: CheckedContinuation<Void, Never>?
    var hold = false
    @MainActor func release() { hold = false; held?.resume(); held = nil }
    /// Runs when an app is asked to quit, before it exits (an AI app may save its settings file as it quits).
    var onQuit: (@Sendable (String) -> Void)?
    private(set) var copied: [String] = []
    private(set) var opened: [URL] = []
    private(set) var observing = 0
    var changed: (@MainActor () -> Void)?
    private var nextPID: pid_t = 500

    init(log: EventLog) { self.log = log }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    func install(_ id: String, at url: URL?) { locked { _locations[id] = url } }
    /// A nil date: started outside LaunchServices, so macOS gives no launch date.
    func launch(_ id: String, at date: Date?) { locked { nextPID += 1; _running[id] = RunningAIApp(pid: nextPID, launchDate: date, bundleURL: _locations[id]) } }
    /// Whether opening a link works (a new-chat link starts its app, like macOS does).
    var opens = true
    func stop(_ id: String) { locked { _running[id] = nil } }
    func handle(_ scheme: String, with bundle: String?) { locked { _handlers[scheme] = bundle } }
    func setChange(_ id: String, _ date: Date?) { locked { _changes[id] = date } }
    private var _servers: [ConnectionServer] = []
    private var _since: Date?
    /// The DayDream servers AI apps run, and since when DayDream's servers carry on across an update (gold G13).
    func setServers(_ servers: [ConnectionServer], since: Date?) { locked { _servers = servers; _since = since } }
    func connectionServers() -> [ConnectionServer] { locked { _servers } }
    func renewingServersSince() -> Date? { locked { _since } }
    func runningInfo(_ id: String) -> RunningAIApp? { locked { _running[id] } }

    func location(_ app: AIApp, env: AIAppConnectEnvironment) -> URL? { locked { _locations[app.id] } }
    @MainActor func running(_ app: AIApp) -> RunningAIApp? { locked { _running[app.id] } }
    func handler(for url: URL) -> String? { locked { url.scheme.flatMap { _handlers[$0] } } }
    func lastChange(_ app: AIApp) -> Date? { locked { _changes[app.id] } }
    func recordChange(_ app: AIApp, at date: Date) { locked { _changes[app.id] = date } }

    @MainActor func quit(_ running: RunningAIApp, force: Bool, timeout: TimeInterval) async -> Bool {
        let id = locked { _running.first { $0.value.pid == running.pid }?.key }
        log.add("quit \(id ?? "?")\(force ? " force" : "")")
        if hold { await withCheckedContinuation { held = $0 } }
        if let id { onQuit?(id) }
        guard force || quits, let id else { return false }
        locked { _running[id] = nil }
        return true
    }
    @MainActor func reopen(_ url: URL) async -> Bool {
        let id = locked { _locations.first { $0.value == url }?.key }
        log.add("reopen \(id ?? url.lastPathComponent)")
        if let id { launch(id, at: Date()) }
        return true
    }
    @MainActor func open(_ url: URL) -> Bool {
        log.add("open \(url.absoluteString)")
        guard opens else { return false }
        opened.append(url)
        if url.scheme == "claude", handler(for: url) != nil, runningInfo("claude-desktop") == nil { launch("claude-desktop", at: Date()) }
        return true
    }
    @MainActor func copy(_ text: String) { log.add("copy"); copied.append(text) }
    @MainActor func observe(_ changed: @escaping @MainActor () -> Void) -> [NSObjectProtocol] {
        observing += 1
        self.changed = changed
        return [NSObject()]
    }
    @MainActor func stopObserving(_ tokens: [NSObjectProtocol]) {
        if !tokens.isEmpty { observing -= 1; changed = nil }
    }
}

/// `mac-mem connect|disconnect` against the scratch home: the real AIAppConnect write rules, with keys kept in memory.
final class ScratchCommand: ConnectionCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    let env: AIAppConnectEnvironment
    let cli: URL
    let log: EventLog
    private var _keys: [String: String] = [:]
    private var _calls: [[String]] = []
    /// When set, the tool fails with this output instead of writing.
    var failure: ConnectionCommandOutput?
    /// Fails the next runs with these outputs, one each, then works again (an AI app saving its file as it quits).
    var failNext: [ConnectionCommandOutput] = []
    init(env: AIAppConnectEnvironment, cli: URL, log: EventLog) { self.env = env; self.cli = cli; self.log = log }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
    func key(_ id: String) -> String? { lock.lock(); defer { lock.unlock() }; return _keys[id] }
    func setKey(_ id: String, _ key: String?) { lock.lock(); _keys[id] = key; lock.unlock() }
    func works(_ app: AIApp, _ key: String) -> Bool { self.key(app.id) == key }

    private func record(_ arguments: [String]) { lock.lock(); _calls.append(arguments); lock.unlock() }
    func run(_ arguments: [String]) async -> ConnectionCommandOutput {
        record(arguments)
        log.add("cli \(arguments[0]) \(arguments[1])")
        if let failure { return failure }
        let once: ConnectionCommandOutput? = { lock.lock(); defer { lock.unlock() }; return failNext.isEmpty ? nil : failNext.removeFirst() }()
        if let once { return once }
        guard let app = try? AIAppConnect.app(arguments[1]), let i = arguments.firstIndex(of: "--expect-sha256") else {
            return ConnectionCommandOutput(status: 1, stdout: "", stderr: "bad arguments")
        }
        do {
            let result: AIAppConnectResult
            if arguments[0] == "connect" {
                let fresh = "synthetic-key-" + UUID().uuidString
                result = try AIAppConnect.connect(app, env: env, command: cli, home: nil, expectedSHA256: arguments[i + 1],
                    verify: { self.works(app, $0) }, grant: { self.setKey(app.id, fresh); return fresh }, revoke: { self.setKey(app.id, nil) })
            } else {
                result = try AIAppConnect.disconnect(app, env: env, command: cli, home: nil, expectedSHA256: arguments[i + 1],
                    revoke: { self.setKey(app.id, nil) })
            }
            let json = try JSONSerialization.data(withJSONObject: ["wrote": result.wrote, "outcome": result.plan.outcome.rawValue, "message": result.message])
            return ConnectionCommandOutput(status: 0, stdout: String(decoding: json, as: UTF8.self), stderr: "")
        } catch {
            return ConnectionCommandOutput(status: 1, stdout: "", stderr: ((error as? AIAppConnectError)?.description ?? "\(error)") + "\n")
        }
    }
}

final class FakeConnectionCommand: ConnectionCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var reply: ConnectionCommandOutput
    init(reply: ConnectionCommandOutput) { self.reply = reply }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
    private func record(_ arguments: [String]) -> ConnectionCommandOutput { lock.lock(); defer { lock.unlock() }; _calls.append(arguments); return reply }
    func run(_ arguments: [String]) async -> ConnectionCommandOutput { record(arguments) }
}

@MainActor @main struct ConnectionReviewChecks {
    static var passes = 0, failures = 0
    static func check(_ value: Bool, _ name: String, _ detail: String = "") {
        if value { passes += 1; print("PASS " + name) } else { failures += 1; print("FAIL " + name + (detail.isEmpty ? "" : ": " + detail)) }
    }

    /// Waits for work the models run off the main thread.
    static func until(_ label: String, _ condition: () -> Bool) async {
        for _ in 0..<250 where !condition() { try? await Task.sleep(nanoseconds: 20_000_000) }
        if !condition() { check(false, "timed out waiting: " + label) }
    }

    /// Re-reads the model and waits for the read to land.
    static func reread(_ model: ConnectionSettingsModel) async {
        model.refresh()
        // A read always replaces `rows`; wait a few frames for it (the value may be equal).
        for _ in 0..<10 { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// Renders light and dark PNGs into DD_CHECK_OUT and returns how many distinct shades each has (a blank or
    /// unreadable render has very few), with the frames the page reported. One window shows both appearances, so the
    /// page appears once and closes once (closing drops its prompt and messages). It is never ordered on screen.
    static func render<V: View>(_ view: V, _ name: String, size: NSSize, to output: URL) async throws -> (shades: [Int], frames: [String: CGRect]) {
        var shades: [Int] = []
        let reported = Box<[String: CGRect]>([:])
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)).transaction { $0.disablesAnimations = true }
            .onPreferenceChange(ConnectionFrames.self) { reported.value = $0 })
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            if window.contentView !== hosting {
                window.contentView = hosting
                window.setContentSize(size)
                hosting.frame = NSRect(origin: .zero, size: size)
            }
            try await Task.sleep(nanoseconds: 250_000_000)
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fatalError("\(name) did not render") }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            var seen = Set<Int>()
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) { for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    seen.insert(Int(c.redComponent * 31) << 10 | Int(c.greenComponent * 31) << 5 | Int(c.blueComponent * 31))
                }
            } }
            shades.append(seen.count)
            check(!window.isVisible, "\(name) (\(dark ? "dark" : "light")) renders without showing a window")
        }
        window.contentView = nil
        return (shades, reported.value)
    }

    /// The page as people see it: inside the Settings sheet's frame at its real size.
    static func sheet(_ model: ConnectionSettingsModel) -> some View {
        DaydreamSettingsFrame(title: "Connections", back: {}, close: {}) { ConnectionSettings(model: model) }
    }

    /// Renders the page in the Settings sheet at its full size (DaydreamSettingsLayout: 720x540, what a 13-inch MacBook Air
    /// shows) and checks every row button and starter prompt is fully in view.
    static func page(_ model: ConnectionSettingsModel, _ name: String, to output: URL,
                     size: NSSize = NSSize(width: DaydreamSettingsLayout.width, height: DaydreamSettingsLayout.maxHeight)) async throws {
        let (shades, frames) = try await render(sheet(model), name, size: size, to: output)
        check(shades.allSatisfy { $0 > 12 }, "\(name): the page renders in light and dark", "\(shades)")
        guard let viewport = frames["viewport"] else { check(false, "\(name): the page reports its viewport"); return }
        let controls = frames.filter { $0.key.hasPrefix("button.") || $0.key.hasPrefix("prompt.") }
        let hidden = controls.filter { !viewport.insetBy(dx: -0.5, dy: -0.5).contains($0.value) }
        check(hidden.isEmpty, "\(name): every button and starter prompt is in view without scrolling (\(Int(size.width))x\(Int(size.height)))",
              "viewport \(viewport), hidden \(hidden)")
        let buttons = frames.keys.filter { $0.hasPrefix("button.") }.count
        let expected = model.rows.filter { model.presentation($0).button != nil }.count
        check(buttons == expected, "\(name): one button per row that offers one (\(expected))", "\(buttons) reported")
    }

    nonisolated static func sha(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "absent" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func main() async throws {
        // Stands in for an AI app's `mac-mem … mcp` for the live process-list check below: it only waits to be ended.
        if CommandLine.arguments.last == "mcp" { sleep(30); exit(0) }
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard let outPath = ProcessInfo.processInfo.environment["DD_CHECK_OUT"], outPath.hasPrefix("/") else {
            print("FAIL DD_CHECK_OUT must name a private output folder; run this through run-checks.sh"); exit(1)
        }
        let generalPasteboard = NSPasteboard.general.changeCount
        let output = URL(fileURLWithPath: outPath, isDirectory: true).appendingPathComponent("connections", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("daydream-connections-app-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("user", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: user.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        // A stand-in for the app's mac-mem: an executable file that is never run (the fake runs instead).
        let cli = root.appendingPathComponent("DayDream.app/Contents/MacOS/mac-mem")
        try fm.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: cli)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let env = AIAppConnectEnvironment(userHome: user, applicationFolders: [user.appendingPathComponent("Applications")])
        let history = root.appendingPathComponent("history", isDirectory: true)
        let log = EventLog()
        let control = FakeAIAppControl(log: log)
        let runner = ScratchCommand(env: env, cli: cli, log: log)

        // Like the owner's Mac: Claude Desktop installed and running (its settings file holds its own preference),
        // Claude Code connected, Cursor used (its folder, no DayDream), Windsurf not on this Mac.
        let claude = try AIAppConnect.app("claude-desktop"), claudeCode = try AIAppConnect.app("claude-code")
        let cursor = try AIAppConnect.app("cursor")
        let claudeFile = AIAppConnect.file(claude, env)
        try fm.createDirectory(at: claudeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"globalShortcut": "Alt+Space"}"#.utf8).write(to: claudeFile)
        let scratchClaudeApp = user.appendingPathComponent("Applications/Claude.app", isDirectory: true)
        try fm.createDirectory(at: scratchClaudeApp, withIntermediateDirectories: true)
        // The icon only: the real Claude.app is drawn when it is installed. The fake never opens anything.
        let claudeIcon = fm.fileExists(atPath: "/Applications/Claude.app") ? URL(fileURLWithPath: "/Applications/Claude.app") : scratchClaudeApp
        control.install("claude-desktop", at: claudeIcon)
        control.launch("claude-desktop", at: Date(timeIntervalSinceNow: -3600))
        control.handle("claude", with: "com.anthropic.claudefordesktop")
        try fm.createDirectory(at: user.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let codeKey = "synthetic-key-" + UUID().uuidString
        runner.setKey("claude-code", codeKey)
        let claudeCodeFile = AIAppConnect.file(claudeCode, env)
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["daydream": ["type": "stdio", "command": cli.path,
            "args": AIAppConnect.arguments(claudeCode, home: nil), "env": ["MAC_MEM_CAPABILITY": codeKey]]], "keep": true]).write(to: claudeCodeFile)
        let cursorFile = AIAppConnect.file(cursor, env)
        try fm.createDirectory(at: cursorFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cursorText = #"{"mcpServers": {"other": {"command": "/bin/echo"}}, "keep": [1, 2]}"#
        try Data(cursorText.utf8).write(to: cursorFile)

        let model = ConnectionSettingsModel(environment: env, cli: cli, home: history, pinnedHome: nil, runner: runner,
                                            verifier: { app, key in runner.works(app, key) }, control: control)
        func row(_ id: String) -> ConnectionSettingsModel.Row { model.row(id)! }
        func shown(_ id: String) -> ConnectionSettingsModel.RowPresentation { model.presentation(row(id)) }

        // Before the first read: nothing guessed, no button.
        check(!model.loaded && model.rows.map(\.app.id) == AIAppConnect.apps.map(\.id), "the page lists the four AI apps before reading anything")
        check(model.rows.allSatisfy { model.presentation($0).button == nil && model.presentation($0).status == "Checking…" },
              "before the first read no row shows a status or a button")
        model.refresh()
        await until("first read") { model.loaded }

        // 1. One true status and one button per row.
        check(shown("claude-desktop") == .init(status: "Not connected", symbol: "circle.dashed", tone: .quiet,
                                                button: .init(title: "Connect & Restart", action: .connect)),
              "Claude Desktop, running: Not connected, one button that says it restarts the app", "\(shown("claude-desktop"))")
        check(shown("claude-code").status == "Connected" && shown("claude-code").button == .init(title: "Disconnect", action: .disconnect),
              "Claude Code: Connected, one Disconnect button")
        check(shown("cursor").status == "Not connected" && shown("cursor").button == .init(title: "Connect", action: .connect),
              "Cursor, not running: Not connected, Connect")
        check(shown("windsurf").status == "Not installed" && shown("windsurf").button == nil && shown("windsurf").dimmed,
              "Windsurf, not on this Mac: Not installed, no button")
        check(model.visibleRows.map(\.app.id) == ["claude-desktop", "claude-code", "cursor"],
              "the page lists only the AI apps on this Mac (Windsurf's row is hidden)", "\(model.visibleRows.map(\.app.id))")
        check(model.rows.allSatisfy { model.presentation($0).detail == nil }, "no row adds a second line when its button says what to do")
        check(model.phaseLabel == "Claude Code", "the Settings overview names the one connected app")
        check(model.unavailable == nil, "a normal copy of DayDream can connect")
        let link = "claude://claude.ai/new?q=Explain%20what%20DayDream%20does%2C%20what%20you%20can%20use%20it%20for%20here%2C%20and%20how%20to%20get%20started.%20Check%20that%20DayDream%20is%20connected%20and%20ready%20to%20use%2C%20explain%20any%20setup%20issue%20simply%2C%20and%20give%20me%20three%20example%20questions%20I%20can%20ask."
        // fix/welcome-prompt: the owner's welcome prompt, fully encoded, fits every app's new-chat link; a prompt too
        // long for the link gets no link, so Connect copies it instead (the copy fallback below).
        check(link.utf8.count <= AIApp.newChatLinkMaxLength
              && AIAppConnect.apps.allSatisfy { $0.newChatLink(ConnectionSettingsModel.starterPrompt).map { $0.absoluteString.utf8.count <= AIApp.newChatLinkMaxLength } ?? true },
              "the starter prompt's new-chat link fits the link length limit for every app", "\(link.utf8.count)")
        let tooLong = String(repeating: "Explain what DayDream does. ", count: 100)
        check(claude.newChatLink(tooLong) == nil && claude.newChatLink(ConnectionSettingsModel.starterPrompt)?.absoluteString == link,
              "a prompt whose link would be too long gets no link (Connect copies it instead)")
        check(row("claude-desktop").newChat?.absoluteString == link, "Claude Desktop's new-chat link carries only the starter prompt, fully encoded",
              row("claude-desktop").newChat?.absoluteString ?? "nil")
        check(row("claude-code").newChat == nil && row("cursor").newChat == nil, "apps without a documented new-chat link get none")
        check(log.events.isEmpty && runner.calls.isEmpty, "reading the page quits, opens, copies and runs nothing", "\(log.events)")
        try await page(model, "1-list", to: output)
        check(control.observing == 0, "leaving the page stops watching the AI apps")
        log.reset()

        // A leftover settings folder is not an installed app; an app macOS finds is, wherever it is.
        let leftover = FakeAIAppControl(log: EventLog())
        let gone = ConnectionSettingsModel(environment: env, cli: cli, home: history, pinnedHome: nil, runner: runner,
                                           verifier: { app, key in runner.works(app, key) }, control: leftover)
        gone.refresh()
        await until("leftover") { gone.loaded }
        check(gone.row("claude-desktop").map { gone.presentation($0).status } == "Not installed" && gone.row("claude-desktop").map { gone.presentation($0).button } == .some(nil),
              "Claude Desktop's settings folder without Claude.app reads Not installed, with no Connect")
        leftover.install("claude-desktop", at: URL(fileURLWithPath: "/Volumes/Other/Claude.app"))
        gone.refresh()
        await until("found elsewhere") { gone.row("claude-desktop")?.installed == true }
        check(gone.row("claude-desktop").map { gone.presentation($0).status } == "Not connected", "Claude.app found anywhere reads Not connected")

        // 2. Connect & Restart: check the file, quit, write (pinned to the file as it is after the quit), then open Claude
        // Desktop on its new-chat link (it comes forward with the prompt typed in, not sent); nothing is copied.
        let quitSHA = Box<String>("")
        control.onQuit = { id in
            guard id == "claude-desktop" else { return }
            // Claude Desktop saves its own settings as it quits.
            try? Data(#"{"globalShortcut": "Alt+Space", "savedOnQuit": true}"#.utf8).write(to: claudeFile)
            // claude/connect-fix-1003: the pin is the review's (the file being there, DayDream's entry), read after the quit.
            quitSHA.value = AIAppConnect.reviewedSHA256(claude, env: env) ?? ""
        }
        await model.perform(.connect, claude)
        check(log.events == ["quit claude-desktop", "cli connect claude-desktop", "open " + link],
              "Connect & Restart: quit, then write, then open Claude Desktop on a new chat with the prompt typed in", "\(log.events)")
        check(runner.calls.last == ["connect", "claude-desktop", "--yes", "--json", "--expect-sha256", quitSHA.value],
              "Connect runs `mac-mem connect claude-desktop` once, pinned to the file as it was after the quit", "\(runner.calls)")
        let written = (try? JSONSerialization.jsonObject(with: Data(contentsOf: claudeFile))) as? [String: Any]
        check(written?["globalShortcut"] as? String == "Alt+Space" && written?["savedOnQuit"] as? Bool == true
              && ((written?["mcpServers"] as? [String: Any])?["daydream"] as? [String: Any]) != nil,
              "the app's own settings stay and DayDream's entry is added")
        check(fm.fileExists(atPath: AIAppConnect.backupFile(claude, env).path), "a copy of the old settings file is kept next to it")
        await until("connected") { model.row("claude-desktop")?.state == .connected && model.working == nil }
        check(shown("claude-desktop") == .init(status: "Connected", symbol: "checkmark.circle.fill", tone: .good,
                                                button: .init(title: "Disconnect & Restart", action: .disconnect)),
              "after Connect & Restart: Connected, and nothing else to do", "\(shown("claude-desktop"))")
        check(!row("claude-desktop").needsRestart, "the reopened app started after the change, so it has DayDream")
        check(model.promptApp == nil && control.copied.isEmpty,
              "Claude Desktop: nothing is copied and the row adds no prompt line (the prompt is typed in Claude Desktop)")
        check(ConnectionSettingsModel.starterPrompt == "Explain what DayDream does, what you can use it for here, and how to get started. Check that DayDream is connected and ready to use, explain any setup issue simply, and give me three example questions I can ask.",
              "the starter prompt is the owner's welcome prompt, word for word, with no history in it")
        check(!ConnectionSettingsModel.starterPrompt.lowercased().contains("today") && !ConnectionSettingsModel.starterPrompt.lowercased().contains("recap"),
              "the starter prompt asks for no recap of the person's day")
        check(control.opened.map(\.absoluteString) == [link], "Connect opens only Claude Desktop's documented new-chat link, once")
        check(DiagnosticsLog.shared.recent().contains { $0.hasSuffix("Connected Claude Desktop.") }, "the report's log notes the connect, without the key")
        check(model.phaseLabel == "2 AI apps", "the overview counts both connected apps")
        control.onQuit = nil
        try await page(model, "2-connected", to: output)
        log.reset()

        // Mid-way: the row says what is happening and offers no button; the other rows wait.
        await model.perform(.disconnect, claude)
        log.reset()
        control.hold = true
        let pending = Task { await model.perform(.connect, claude) }
        await until("quitting") { model.phases["claude-desktop"] == .working("Quitting Claude Desktop…") }
        check(shown("claude-desktop").working && shown("claude-desktop").button == nil && shown("claude-desktop").status == "Quitting Claude Desktop…",
              "while Claude Desktop quits, its row says so and has no button")
        check(!model.enabled(.connect) && !model.enabled(.disconnect), "other rows' buttons wait")
        try await page(model, "2b-working", to: output)
        control.release()
        await pending.value
        await until("reconnected") { model.row("claude-desktop")?.state == .connected && model.working == nil }
        check(log.events == ["quit claude-desktop", "cli connect claude-desktop", "open " + link], "the held Connect finished in order", "\(log.events)")
        log.reset()
        // A link that doesn't open: the app opens again the plain way and the prompt is copied instead.
        await model.perform(.disconnect, claude)
        log.reset()
        control.opens = false
        await model.perform(.connect, claude)
        check(log.events == ["quit claude-desktop", "cli connect claude-desktop", "open " + link, "reopen claude-desktop", "copy"],
              "a new-chat link that doesn't open falls back to reopening the app and copying the prompt", "\(log.events)")
        check(model.promptApp == "claude-desktop" && model.promptNote(claude) == "Prompt copied. Paste it in Claude Desktop.",
              "then the row says the prompt was copied and where to paste it")
        control.opens = true
        await until("fallback connected") { model.row("claude-desktop")?.state == .connected && model.working == nil }
        check(model.phases["claude-desktop"] == nil && shown("claude-desktop").status == "Connected"
              && shown("claude-desktop").button == .init(title: "Disconnect & Restart", action: .disconnect),
              "after reopening the app the row says Connected with its one button (no \"Opening…\" left behind)", "\(shown("claude-desktop"))")
        log.reset()

        // 3. An app that isn't running: no quit, no reopen; no link when the app has none.
        await model.perform(.connect, cursor)
        check(log.events == ["cli connect cursor", "copy"], "Connect for an app that isn't running: write and copy only", "\(log.events)")
        await until("cursor connected") { model.row("cursor")?.state == .connected }
        check(model.promptNote(cursor) == "Prompt copied. Paste it in Cursor." && row("cursor").newChat == nil
              && control.copied.last == ConnectionSettingsModel.starterPrompt,
              "Cursor: the prompt is copied, with one line saying so")
        check(model.promptApp == "cursor", "one starter prompt at a time: the app connected last")
        check(model.promptNote(claudeCode) == "Prompt copied. Paste it in a new Claude Code session.", "Claude Code: paste it in a new session")
        try await page(model, "2c-prompt-copied", to: output)
        log.reset()

        // 4. Disconnect & Restart: one click, no second screen; the status afterwards is the only status.
        await model.perform(.disconnect, claude)
        check(log.events == ["quit claude-desktop", "cli disconnect claude-desktop", "reopen claude-desktop"],
              "Disconnect & Restart: quit, remove the entry and key, reopen", "\(log.events)")
        await until("disconnected") { model.row("claude-desktop")?.state == .notConnected && model.working == nil }
        check(shown("claude-desktop") == .init(status: "Not connected", symbol: "circle.dashed", tone: .quiet,
                                                button: .init(title: "Connect & Restart", action: .connect)),
              "after Disconnect: Not connected, and no second message", "\(shown("claude-desktop"))")
        check(model.promptApp != "claude-desktop" && model.phases["claude-desktop"] == nil, "Disconnect leaves no prompt or message on the row")
        check(runner.key("claude-desktop") == nil, "Disconnect turned the key off")
        log.reset()

        // 5. The app doesn't quit when asked: the entry is written, the page says what to do, with one button.
        control.quits = false
        await model.perform(.connect, claude)
        let copiedBefore = control.copied.count
        check(log.events == ["quit claude-desktop", "cli connect claude-desktop"], "a refused quit: written, not reopened, no prompt yet", "\(log.events)")
        await until("restart needed") { model.row("claude-desktop")?.needsRestart == true && model.working == nil }
        check(shown("claude-desktop") == .init(status: "Quit Claude Desktop and open it again to finish.", symbol: "arrow.clockwise.circle.fill",
                                                tone: .attention, button: .init(title: "Force Quit & Reopen", action: .forceRestart)),
              "a refused quit: \"Quit Claude Desktop and open it again to finish.\" with one button", "\(shown("claude-desktop"))")
        check(model.promptApp != "claude-desktop" && control.copied.count == copiedBefore,
              "a refused quit shows and copies no prompt: it can't work until the app reopens")
        log.reset()
        // Force Quit & Reopen asks first; Cancel changes nothing. (Before the render: closing the page drops the
        // row's message.)
        await model.perform(.forceRestart, claude)
        check(model.pendingForceQuit?.id == "claude-desktop" && log.events.isEmpty, "Force Quit & Reopen asks before anything is quit", "\(log.events)")
        check(model.forceQuitTitle(claude) == "Force quit Claude Desktop?" && model.forceQuitMessage(claude) == "Anything unsaved in Claude Desktop will be lost.",
              "the question says what may be lost")
        check(!model.enabled(.connect) && !model.enabled(.disconnect) && !model.enabled(.forceRestart), "other buttons wait while the question is open")
        model.cancelForceQuit()
        check(model.pendingForceQuit == nil && log.events.isEmpty && shown("claude-desktop").button?.action == .forceRestart,
              "Cancel quits nothing and keeps the row as it was")
        await model.perform(.forceRestart, claude)
        guard let forced = model.pendingForceQuit else { check(false, "the question comes back"); exit(1) }
        model.cancelForceQuit() // the alert closing clears the question before its button's answer arrives
        await model.confirmForceQuit(forced)
        check(log.events == ["quit claude-desktop force", "open " + link],
              "Force Quit confirmed: force-quits, then opens Claude Desktop on a new chat with the prompt typed in", "\(log.events)")
        await until("restarted") { model.row("claude-desktop")?.needsRestart == false && model.working == nil }
        check(shown("claude-desktop").status == "Connected" && model.phases["claude-desktop"] == nil, "after the restart: Connected")
        // The refused-quit row again, for the render.
        await model.perform(.disconnect, claude)
        await model.perform(.connect, claude)
        await until("refused again") { model.phases["claude-desktop"] == .quitRefused && model.working == nil }
        try await page(model, "3-quit-refused", to: output)
        control.quits = true
        log.reset()

        // 6. Restart needed, found from the facts: connected, running, and started before DayDream's last change.
        control.launch("claude-desktop", at: Date(timeIntervalSinceNow: -7200))
        await reread(model)
        await until("stale launch") { model.row("claude-desktop")?.needsRestart == true }
        check(shown("claude-desktop").status == "Quit Claude Desktop and open it again to finish."
              && shown("claude-desktop").button == .init(title: "Restart", action: .restart),
              "an app started before the change offers a polite Restart")
        await model.perform(.restart, claude)
        check(log.events == ["quit claude-desktop", "reopen claude-desktop"], "Restart quits politely and reopens", "\(log.events)")
        await until("fresh launch") { model.row("claude-desktop")?.needsRestart == false }
        check(shown("claude-desktop").status == "Connected", "after Restart: Connected")
        // The app saving its own settings file later is not a DayDream change.
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: claudeFile.path)
        await reread(model)
        check(shown("claude-desktop").status == "Connected", "the app saving its own settings doesn't make DayDream ask for a restart")
        // A Connect from Terminal counts too (its backup is saved at the change), with no record from Settings.
        control.setChange("claude-desktop", nil)
        control.launch("claude-desktop", at: Date(timeIntervalSinceNow: -7200))
        await reread(model)
        await until("terminal change") { model.row("claude-desktop")?.needsRestart == true }
        check(true, "a change made from Terminal (seen by its backup) asks for a restart too")
        // A Connect from Terminal that created the file (no backup, no record): the file's own date counts.
        let backupFile = AIAppConnect.backupFile(claude, env), setAside = root.appendingPathComponent("backup-aside")
        try fm.moveItem(at: backupFile, to: setAside)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: claudeFile.path)
        control.launch("claude-desktop", at: Date(timeIntervalSinceNow: -7200))
        await reread(model)
        await until("file date") { model.row("claude-desktop")?.needsRestart == true }
        check(shown("claude-desktop").status == "Quit Claude Desktop and open it again to finish.",
              "no backup and no record: an app started before the settings file changed asks for a restart, not Connected")
        control.launch("claude-desktop", at: Date())
        await reread(model)
        check(shown("claude-desktop").status == "Connected", "started after the file changed: Connected")
        // Running with no launch date (started outside LaunchServices): it can't be shown to have loaded DayDream.
        control.launch("claude-desktop", at: nil)
        await reread(model)
        await until("no launch date") { model.row("claude-desktop")?.needsRestart == true }
        check(shown("claude-desktop").button == .init(title: "Restart", action: .restart), "no launch date: asks for a restart rather than Connected")
        try fm.moveItem(at: setAside, to: backupFile)
        control.launch("claude-desktop", at: Date())
        await reread(model)
        log.reset()

        // 7. Live: an AI app launching updates the page while it shows.
        model.pageAppeared()
        check(control.observing == 1, "the page watches AI apps launch and quit while it shows")
        check(shown("cursor").button?.title == "Disconnect", "Cursor not running: Disconnect")
        control.install("cursor", at: user.appendingPathComponent("Applications/Cursor.app"))
        control.launch("cursor", at: Date())
        control.changed?()
        await until("cursor launched") { model.row("cursor")?.running != nil }
        check(shown("cursor").button?.title == "Disconnect & Restart", "Cursor launching changes its button to Disconnect & Restart")
        control.stop("cursor")
        model.pageDisappeared()
        check(control.observing == 0 && model.promptApp == nil, "closing the page stops watching and drops the prompt")
        await reread(model)

        // 8. A preference save turned every key off: Disconnected, one Reconnect; the overview says so.
        runner.setKey("claude-desktop", nil); runner.setKey("claude-code", nil); runner.setKey("cursor", nil)
        await reread(model)
        await until("keys off") { model.row("claude-desktop")?.state == .needsAttention(.keyStopped) }
        check(shown("claude-desktop") == .init(status: "Disconnected", symbol: "exclamationmark.circle.fill", tone: .attention,
                                                button: .init(title: "Reconnect & Restart", action: .connect)),
              "a key that stopped working: Disconnected, one Reconnect", "\(shown("claude-desktop"))")
        model.disconnectedByAppsChange = true
        check(shown("claude-desktop").status == "Disconnected after an Apps change",
              "after a saved Apps change turned the keys off, the row says why")
        check(shown("claude-code").button == .init(title: "Reconnect", action: .connect), "Claude Code: Reconnect")
        check(model.phaseLabel == "Reconnect needed", "the overview says Reconnect needed, not Not set up")
        try await page(model, "4-access-off", to: output)
        log.reset()
        await model.perform(.connect, claudeCode)
        check(log.events == ["cli connect claude-code", "copy"] && runner.calls.last?.prefix(2) == ["connect", "claude-code"],
              "Reconnect is the same one click", "\(log.events)")
        await until("reconnected") { model.row("claude-code")?.state == .connected }
        check(model.phaseLabel == "Claude Code", "one reconnected app: the overview names it")
        log.reset()

        // 9. Another copy of DayDream in the entry: one short question first, only while that copy exists.
        let other = root.appendingPathComponent("Old/DayDream.app/Contents/MacOS/mac-mem")
        try fm.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: cli, to: other)
        let otherKey = "synthetic-key-" + UUID().uuidString
        runner.setKey("claude-code", otherKey)
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["daydream": ["type": "stdio", "command": other.path,
            "args": AIAppConnect.arguments(claudeCode, home: nil), "env": ["MAC_MEM_CAPABILITY": otherKey]]], "keep": true]).write(to: claudeCodeFile)
        await reread(model)
        await until("other copy") { model.row("claude-code")?.state == .needsAttention(.otherCopy) }
        check(shown("claude-code").status == "Uses another copy of DayDream" && shown("claude-code").button?.title == "Reconnect",
              "an entry for another copy: says so, one Reconnect")
        let calls = runner.calls.count
        await model.perform(.connect, claudeCode)
        guard let pending = model.pendingReplace else { check(false, "replacing another copy asks first"); exit(1) }
        check(runner.calls.count == calls && log.events.isEmpty, "the question comes before anything is quit or written")
        check(model.replaceTitle(pending) == "Switch Claude Code to this copy of DayDream?"
              && model.replaceMessage(pending).contains(AIAppConnect.display(other, env)) && model.replaceButton(pending) == "Switch",
              "the question names the other copy", model.replaceMessage(pending))
        check(!model.enabled(.connect) && !model.enabled(.disconnect), "other buttons wait while the question is open")
        model.cancelReplace()
        check(model.pendingReplace == nil && runner.calls.count == calls, "Cancel writes nothing")
        await model.perform(.connect, claudeCode)
        // The alert closing clears the question before its button's answer arrives; the answer still counts.
        guard let asked = model.pendingReplace else { check(false, "the question comes back"); exit(1) }
        model.cancelReplace()
        await model.replace(asked)
        check(runner.calls.count == calls + 1 && runner.calls.last?.prefix(2) == ["connect", "claude-code"], "Switch writes once")
        await until("switched") { model.row("claude-code")?.state == .connected }
        // The other copy is gone: nothing to lose, so no question.
        runner.setKey("claude-code", otherKey)
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["daydream": ["type": "stdio", "command": other.path,
            "args": AIAppConnect.arguments(claudeCode, home: nil), "env": ["MAC_MEM_CAPABILITY": otherKey]]], "keep": true]).write(to: claudeCodeFile)
        try fm.removeItem(at: other)
        await reread(model)
        await until("other copy gone") { model.row("claude-code")?.state == .needsAttention(.otherCopy) && model.row("claude-code")?.otherCopy == nil }
        await model.perform(.connect, claudeCode)
        check(model.pendingReplace == nil && runner.calls.last?.prefix(2) == ["connect", "claude-code"], "an entry for a copy that is gone is replaced without a question")
        log.reset()

        // 10. States with no button say why, in one line.
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["daydream": ["command": "/usr/local/bin/something"]]]).write(to: cursorFile)
        try Data("// comment\n{\"mcpServers\": {}}\n".utf8).write(to: claudeCodeFile)
        await reread(model)
        await until("hand-made") { model.row("cursor")?.state == .needsAttention(.addedByHand) }
        check(shown("cursor").status == "Set up by hand" && shown("cursor").button == nil && shown("cursor").detail?.contains("added by hand") == true,
              "a hand-made \"daydream\" entry is left alone and says so")
        check(shown("claude-code").status == "Can't read its settings file" && shown("claude-code").button == nil
              && shown("claude-code").detail?.contains("isn't plain JSON") == true, "a settings file DayDream can't read says why")
        try await page(model, "5-left-alone", to: output)
        try JSONSerialization.data(withJSONObject: ["mcpServers": [:]]).write(to: claudeCodeFile)
        try Data(cursorText.utf8).write(to: cursorFile)
        await reread(model)
        log.reset()

        // 11. A failure says what happened on the row, keeps the same button, and the app is reopened.
        runner.failure = ConnectionCommandOutput(status: 1, stdout: "", stderr: AIAppConnectError.changedSinceReview.description + "\n")
        // Claude Desktop's key is still off (section 8): its one button is Reconnect & Restart.
        let copies = control.copied.count
        await model.perform(.connect, claude)
        // gold G70: the file changing between the read and the write is read again and tried again (three times in all).
        check(log.events == ["quit claude-desktop"] + Array(repeating: "cli connect claude-desktop", count: ConnectionSettingsModel.writeAttempts) + ["reopen claude-desktop"],
              "a write the settings file keeps changing under is tried \(ConnectionSettingsModel.writeAttempts) times, then the app is reopened", "\(log.events)")
        await until("failed") { model.working == nil }
        check(control.copied.count == copies && model.promptApp != "claude-desktop", "a failed Connect copies no prompt")
        check(shown("claude-desktop").status == "The settings file changed just then, so nothing was written. Try again."
              && shown("claude-desktop").tone == .failure && shown("claude-desktop").button == .init(title: "Reconnect & Restart", action: .connect),
              "a failure says what happened in the page's own words (there is no review to redo), with the same button to try again", "\(shown("claude-desktop"))")
        runner.failure = ConnectionCommandOutput(status: 1, stdout: "", stderr: "~/.cursor/mcp.json belongs to another user. DayDream left it alone.\n")
        await model.perform(.connect, cursor)
        await until("reason") { model.working == nil }
        check(shown("cursor").status == "~/.cursor/mcp.json belongs to another user. DayDream left it alone.", "other failures show the tool's plain reason")
        try await page(model, "6-failed", to: output)
        runner.failure = ConnectionCommandOutput(status: 1, stdout: "", stderr: "")
        await model.perform(.connect, cursor)
        await until("silent") { model.working == nil }
        check(shown("cursor").status == "That didn't work. Nothing was changed.", "a silent failure still says what happened")
        runner.failure = nil
        model.pageDisappeared()
        check(model.phases.isEmpty, "closing the page drops old messages")
        log.reset()

        // 11b (gold G70). The AI app saves its settings file as it quits, just after DayDream read it: the write is
        // refused once, read again and written. One click, no error; the key works.
        runner.failNext = [ConnectionCommandOutput(status: 1, stdout: "", stderr: AIAppConnectError.changedSinceReview.description + "\n")]
        await model.perform(.connect, claude)
        await until("connected after one retry") { model.working == nil && model.row("claude-desktop")?.state == .connected }
        check(log.events.filter { $0 == "cli connect claude-desktop" }.count == 2 && model.phases["claude-desktop"] == nil
              && shown("claude-desktop").tone != .failure, "a settings file saved as the app quits is read again and written: Connected, no error", "\(log.events)")
        // Disconnect retries the same way.
        control.stop("claude-desktop")
        await reread(model)
        runner.failNext = [ConnectionCommandOutput(status: 1, stdout: "", stderr: AIAppConnectError.changedSinceReview.description + "\n")]
        log.reset()
        await model.perform(.disconnect, claude)
        await until("disconnected after one retry") { model.working == nil && model.row("claude-desktop")?.state == .notConnected }
        check(log.events == ["cli disconnect claude-desktop", "cli disconnect claude-desktop"] && model.phases["claude-desktop"] == nil
              && model.row("claude-desktop")?.state == .notConnected, "Disconnect is read again and written once more the same way", "\(log.events) \(String(describing: model.row("claude-desktop")?.state))")
        // Put Claude Desktop back as the later sections expect it: connected, running.
        control.launch("claude-desktop", at: Date(timeIntervalSinceNow: -60))
        await reread(model)
        await model.perform(.connect, claude)
        await until("reconnected for 12") { model.working == nil && model.row("claude-desktop")?.state == .connected }
        control.launch("claude-desktop", at: Date())
        await reread(model)
        log.reset()

        // 11c (gold G13). After an update from a DayDream whose servers can't carry on as the updated copy (test 4 and
        // earlier), the server an AI app started then answers every request with an error. The row never says
        // Connected for it: a running app asks for one Restart; Claude Code (no app to restart) asks for a new session.
        // DayDream's last change to the file (the reconnect above) came before the app's launch, so only the old server
        // can ask for the restart. The fake clock: the update that brought servers that carry on lands 10 minutes on.
        let now = Date(), since = now.addingTimeInterval(600)
        func stale(_ client: String, _ started: Date) -> ConnectionServer { ConnectionServer(pid: 900, client: client, started: started) }
        control.launch("claude-desktop", at: now)
        await reread(model)
        check(shown("claude-desktop").status == "Connected", "before: connected and loaded")
        control.setServers([stale("claude-desktop", now.addingTimeInterval(60))], since: since)
        await reread(model)
        await until("old server") { model.row("claude-desktop")?.needsRestart == true }
        check(shown("claude-desktop") == .init(status: "Quit Claude Desktop and open it again to finish.", symbol: "arrow.clockwise.circle.fill",
                                                tone: .attention, button: .init(title: "Restart", action: .restart)),
              "a running app with a server from before the update: one Restart, never Connected", "\(shown("claude-desktop"))")
        // A server left from an earlier run of the app (started before this launch) ends with that run: not this row's.
        control.setServers([stale("claude-desktop", now.addingTimeInterval(-60))], since: since)
        await reread(model)
        check(shown("claude-desktop").status == "Connected", "an old server from before the app's launch doesn't ask for a restart")
        control.setServers([stale("claude-desktop", now.addingTimeInterval(60))], since: since)
        await reread(model)
        await until("old server again") { model.row("claude-desktop")?.needsRestart == true }
        // Quitting the app ends its servers; the copy that opens again starts the current one.
        control.onQuit = { id in if id == "claude-desktop" { control.setServers([], since: since) } }
        log.reset()
        await model.perform(.restart, claude)
        control.onQuit = nil
        check(log.events == ["quit claude-desktop", "reopen claude-desktop"], "Restart quits politely and opens it again", "\(log.events)")
        await until("restarted") { model.row("claude-desktop")?.needsRestart == false }
        check(shown("claude-desktop").status == "Connected", "after the restart (its old server ended with it): Connected")
        let relaunched = control.runningInfo("claude-desktop")?.launchDate ?? now
        control.setServers([stale("claude-desktop", since.addingTimeInterval(5))], since: since)
        await reread(model)
        check(shown("claude-desktop").status == "Connected", "a server started after DayDream could carry its servers on: Connected")
        control.setServers([stale("claude-desktop", relaunched.addingTimeInterval(1))], since: nil)
        await reread(model)
        check(shown("claude-desktop").status == "Connected", "no date (a development copy): nothing is guessed")
        control.setServers([stale("cursor", relaunched.addingTimeInterval(1))], since: since)
        await reread(model)
        check(shown("claude-desktop").status == "Connected", "another app's old server doesn't change this row")
        // Claude Code: connected again, with an old session still running.
        runner.setKey("claude-code", nil)
        await model.perform(.connect, claudeCode)
        await until("claude code connected") { model.working == nil && model.row("claude-code")?.state == .connected }
        model.pageDisappeared()
        control.setServers([stale("claude-code", since.addingTimeInterval(-60))], since: since)
        await reread(model)
        await until("old session") { model.row("claude-code")?.oldSession == true }
        check(shown("claude-code") == .init(status: "Start a new Claude Code session to finish.", symbol: "arrow.clockwise.circle.fill",
                                             tone: .attention, button: .init(title: "Disconnect", action: .disconnect)),
              "Claude Code with a session from before the update: says to start a new session, never Connected", "\(shown("claude-code"))")
        check(model.phaseLabel != "Not connected", "the overview still counts it as set up")
        control.setServers([stale("claude-code", since.addingTimeInterval(5))], since: since)
        await reread(model)
        check(shown("claude-code").status == "Connected", "a new Claude Code session: Connected")
        control.setServers([], since: nil)
        await reread(model)
        log.reset()

        // 11d (gold G13). The live process list: a stand-in for an AI app's server (this check started again with a
        // Connect entry's arguments) is found with its app and start time; nothing else of it is read.
        // macOS keeps a process's name to 15 characters ("mac-mem" fits).
        let own = String(URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent.prefix(15))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--home", history.path] + Array(AIAppConnect.arguments(claudeCode, home: nil))
        child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        let before = Date()
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        var found: [ConnectionServer] = []
        for _ in 0..<100 {
            found = LiveAIAppControl.connectionServers(named: own).filter { $0.pid == child.processIdentifier }
            if !found.isEmpty { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        check(found.count == 1 && found[0].client == "claude-code" && abs(found[0].started.timeIntervalSince(before)) < 5,
              "the live list finds a running server with its app and start time", "\(found)")
        check(!LiveAIAppControl.connectionServers(named: own).contains { $0.pid == getpid() }, "a process without a Connect entry's arguments isn't listed")
        child.terminate(); child.waitUntilExit()
        check(!LiveAIAppControl.connectionServers(named: own).contains { $0.pid == child.processIdentifier }, "an ended server is gone from the list")
        // When DayDream's `mac-mem` was put in place: the status-change time (a copy or an update sets it; the
        // modification time keeps the build's date), kept once so later updates don't move it.
        let placedFile = root.appendingPathComponent("placed-mac-mem")
        try Data("x".utf8).write(to: placedFile)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400)], ofItemAtPath: placedFile.path)
        check(LiveAIAppControl.placed(placedFile).map { abs($0.timeIntervalSinceNow) < 60 } == true, "the date a file was put in place is its status-change time, not its build date")
        UserDefaults.standard.set(1_790_000_000.0, forKey: LiveAIAppControl.renewingKey)
        check(LiveAIAppControl().renewingServersSince() == Date(timeIntervalSince1970: 1_790_000_000), "the kept date is used as kept")
        UserDefaults.standard.removeObject(forKey: LiveAIAppControl.renewingKey)
        check(LiveAIAppControl().renewingServersSince() == nil, "no app bundle (a development copy): no date")

        // 11e. A key stopped by an Apps change says so only while it is stopped: after every app is connected again, a
        // key that stops later for another reason is just Disconnected (gold latch).
        model.disconnectedByAppsChange = true
        await reread(model)
        check(!model.disconnectedByAppsChange, "no stopped key: the Apps-change reason is dropped")
        runner.setKey("claude-code", nil)
        await reread(model)
        await until("stopped later") { model.row("claude-code")?.state == .needsAttention(.keyStopped) }
        check(shown("claude-code").status == "Disconnected", "a key that stops later for another reason isn't blamed on an Apps change", shown("claude-code").status)
        runner.setKey("claude-desktop", nil)
        log.reset()

        // 12. No command-line tool: the page says why; Connect is off, Disconnect still works.
        let missing = ConnectionSettingsModel(environment: env, cli: nil, home: history, pinnedHome: nil, runner: FakeConnectionCommand(reply: .init(status: 0, stdout: "", stderr: "")),
                                              verifier: { app, key in runner.works(app, key) }, control: control)
        check(missing.unavailable?.contains("command-line tool is missing") == true && !missing.enabled(.connect) && missing.enabled(.disconnect),
              "without the command-line tool, Connect is off and the page says why")
        await missing.connect(cursor)
        check(log.events.isEmpty, "Connect can't start without the tool, and touches no app")
        check(AIAppConnect.commandProblem(cli, readOnlyVolume: { _ in true })?.contains("download window") == true,
              "a copy on the read-only disk image can't connect")
        missing.refresh()
        await until("missing tool") { missing.loaded }
        try await page(missing, "7-unavailable", to: output)

        // The page's own words (the renders are PNGs; the text is checked in the source it is drawn from).
        let pageSource = (try? String(contentsOfFile: "Sources/MacMemApp/ConnectionSettings.swift", encoding: .utf8)) ?? ""
        let modelSource = (try? String(contentsOfFile: "Sources/MacMemApp/ConnectionSettingsModel.swift", encoding: .utf8)) ?? ""
        let controlSource = (try? String(contentsOfFile: "Sources/MacMemApp/AIAppControl.swift", encoding: .utf8)) ?? ""
        check(pageSource.contains("Connected AI apps can read your history and may send it to their own online service."),
              "the page says, in one line, that a connected app reads your history and may send it online")
        check(pageSource.contains("\"Adds DayDream to \\(model.settingsFile(row.app))") && pageSource.contains("Copies a first question to ask it."),
              "Connect's help tag names the settings file it changes and says when it copies a first question")
        check(!pageSource.contains("static let footnote"), "no footnote about the settings file below the list")
        check(!pageSource.isEmpty && pageSource.range(of: #"(?i)\bssh\b|horizon(?!tal)|other mac|coming soon"#, options: .regularExpression) == nil,
              "the page mentions no SSH, Horizon, other Mac or \"coming soon\"")
        // The only shortcut is inside the force-quit question, where Return means Cancel (nothing is lost by default).
        let shortcuts = pageSource.components(separatedBy: "keyboardShortcut").count - 1
        check(shortcuts == 1 && pageSource.contains("Button(\"Cancel\", role: .cancel) { model.cancelForceQuit() }.keyboardShortcut(.defaultAction)"),
              "the page adds no Return or Esc shortcut of its own (they belong to Settings' Done); in the force-quit question Cancel is the default")
        check(pageSource.contains("Button(\"Force Quit\", role: .destructive)"), "the force-quit question's Force Quit is marked destructive")
        check(!pageSource.contains("ConnectionReviewCard") && !pageSource.contains("Quit and reopen") && !pageSource.contains("mac-mem mcp"),
              "no review card below the list, no second \"quit and reopen\" message, no command-line footer")
        check(!pageSource.contains("NSPasteboard") && !modelSource.contains("NSPasteboard") && !modelSource.contains("NSWorkspace")
              && !modelSource.contains("NSRunningApplication"), "the page and its model reach the Mac only through AIAppControlling")
        check(controlSource.range(of: #"CGEvent|NSAppleScript|keystroke|postEvent|AXUIElement"#, options: .regularExpression) == nil,
              "Connections never types into or scripts another app")
        check(controlSource.contains("app.terminate()") && controlSource.contains("configuration.activates = false"),
              "the live control quits politely and reopens the app without taking focus")
        check(NSPasteboard.general.changeCount == generalPasteboard, "the checks never touched the general pasteboard")

        // Report a Problem… (report-1004): a new email to support@getdaydream.app in the person's mail app, through fakes
        // here (nothing is opened, copied to the general pasteboard or sent). A failed connect leaves its code.
        let failedFile = user.path + "/.cursor/mcp.json"
        let failedMessage = ConnectionSettingsModel.describe(AIAppConnectError.notYours(failedFile))
        let reportCodes = ProblemReportErrors.shared.recent.map(\.code)
        check(failedMessage.contains(failedFile) && reportCodes.last == "AIAppConnectError.notYours"
              && reportCodes.allSatisfy { ProblemReportErrors.isCode($0) && !$0.contains("/") },
              "a failed connect leaves its error code (type and case only, never the file) for the report", "\(reportCodes)")
        let facts = ReportProblemMail.facts(app: nil)
        check(facts.recording == .unknown && facts.accessibility == .unknown && facts.connectedApps.isEmpty && facts.momentsToday == nil
              && facts.errors == ProblemReportErrors.shared.recent, "before the model exists the email says unknown, and reads no history")
        let reportBoard = NSPasteboard(name: NSPasteboard.Name("daydream-check-" + UUID().uuidString))
        defer { reportBoard.releaseGlobally() }
        var opened: [URL] = [], said: [String] = [], mailAsks: [URL] = []
        var routes = ReportProblemMail.Routes(mailApp: { (link: URL) -> URL? in mailAsks.append(link); return URL(fileURLWithPath: "/System/Applications/Mail.app") },
                                              open: { (link: URL) -> Bool in opened.append(link); return true }, pasteboard: reportBoard, say: { said.append($0) })
        check(ReportProblemMail.compose(app: nil, routes: routes) == .mail && opened.count == 1 && mailAsks == opened
              && opened.first == ProblemReportMail.url(facts) && opened.first?.scheme == "mailto"
              && reportBoard.string(forType: .string) == nil && said.isEmpty,
              "with a mail app, Report a Problem opens one mailto: link to support and copies nothing", "\(opened)")
        routes.mailApp = { _ in nil }
        opened = []
        check(ReportProblemMail.compose(app: nil, routes: routes) == .copied && opened.isEmpty
              && reportBoard.string(forType: .string) == ProblemReportMail.clipboardText(facts) && said == [ReportProblemMail.copiedLine],
              "with no mail app, the same text is copied and one line says so")
        routes.mailApp = { _ in URL(fileURLWithPath: "/System/Applications/Mail.app") }
        routes.open = { (link: URL) -> Bool in opened.append(link); return false }
        reportBoard.clearContents(); said = []
        check(ReportProblemMail.compose(app: nil, routes: routes) == .copied && reportBoard.string(forType: .string) == ProblemReportMail.clipboardText(facts)
              && said.count == 1, "when the mail app doesn't open the link, the text is copied too")
        check(!ReportProblemMail.copiedLine.contains("\n") && ReportProblemMail.copiedLine.count <= 100
              && ReportProblemMail.copiedLine.contains("support@getdaydream.app"), "the copied line is one short line naming the address")
        check(MenuBarMenu.rows(isolated: false, onboardingComplete: true, development: false, canReport: true).suffix(2).map(\.title)
              == ["Report a Problem…", "Quit DayDream"], "the menu bar menu's Report a Problem… is the row above Quit")
        let commands = (try? String(contentsOfFile: "Sources/MacMemApp/AppCommands.swift", encoding: .utf8)) ?? ""
        check(commands.contains("CommandGroup(replacing: .help) { DaydreamReportProblemCommand(model: model) }")
              && commands.contains("Button(MenuBarMenu.reportProblemTitle) { ReportProblemMail.compose(app: model) }"),
              "Help's Report a Problem… opens the same email")
        let reportSource = (try? String(contentsOfFile: "Sources/MacMemApp/ReportProblem.swift", encoding: .utf8)) ?? ""
        check(!reportSource.contains("URLSession") && !reportSource.contains("URLRequest") && !reportSource.contains("NSSharingService")
              && !reportSource.contains("Window(") && !reportSource.contains("openWindow"),
              "the report code has no way to send anything and no window of its own")
        check(NSPasteboard.general.changeCount == generalPasteboard, "the report checks never touched the general pasteboard")

        print("\(passes) connections app checks passed, \(failures) failed. Scratch files, a fake command-line tool and a fake AI app control only; nothing was launched, quit, opened or sent.")
        exit(failures == 0 ? 0 : 1)
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
