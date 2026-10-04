// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// Settings › Connections, the file edits (Sources/MemoryCore/AIAppConnect.swift). Scratch folders only: a fake
// home with each AI app's settings file, a fake DayDream.app with an executable `mac-mem`, and a scratch history.
// Nothing reads or writes the real home folder, and no AI app or MCP server is started.
//
// Covers: review before writing (file, entry, key hidden), add, connect twice changes nothing, other entries and
// settings kept exactly, the backup, permissions kept, disconnect, hand-made entries left alone, links / other
// owners' files / JSON with comments / odd shapes refused, a file changed after review refused, the key working
// and then turned off, another copy of DayDream, the download window, and rollback when a write fails.
import Foundation
import Darwin
@testable import MemoryCore

@main struct ConnectConfigChecks {
    static var passes = 0, failures = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) {
        let ok = (try? value()) ?? false
        if ok { passes += 1; print("PASS " + name) } else { failures += 1; print("FAIL " + name) }
    }
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String, _ detail: String) {
        let ok = (try? value()) ?? false
        if ok { passes += 1; print("PASS " + name) } else { failures += 1; print("FAIL \(name): \(detail)") }
    }
    static func rejects<E: Error & Equatable>(_ expected: E, _ name: String, _ body: () throws -> Void) {
        do { try body(); failures += 1; print("FAIL \(name) (no error)") }
        catch let error as E where error == expected { passes += 1; print("PASS " + name) }
        catch { failures += 1; print("FAIL \(name) (\(error))") }
    }
    static let fm = FileManager.default

    static func write(_ url: URL, _ text: String, mode: Int = 0o600) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
    static func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }
    static func mode(_ url: URL) -> Int { ((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int) ?? -1 }
    static func object(_ url: URL) -> [String: Any] {
        guard let data = bytes(url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    static func entry(_ url: URL, _ key: String = "mcpServers") -> [String: Any]? {
        (object(url)[key] as? [String: Any])?[AIAppConnect.entryName] as? [String: Any]
    }
    static func key(_ url: URL) -> String? { (entry(url)?["env"] as? [String: Any])?["MAC_MEM_CAPABILITY"] as? String }
    static func grants(_ store: MemoryStore) -> Int { (try? store.rows("SELECT id FROM grants").count) ?? -1 }

    static func main() throws {
        setbuf(stdout, nil)
        let root = fm.temporaryDirectory.appendingPathComponent("daydream-connect-config-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let user = root.appendingPathComponent("home", isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: user, withIntermediateDirectories: true)
        try fm.createDirectory(at: applications, withIntermediateDirectories: true)
        let env = AIAppConnectEnvironment(userHome: user, applicationFolders: [applications])
        func fakeCLI(_ name: String) throws -> URL {
            let url = root.appendingPathComponent("\(name)/DayDream.app/Contents/MacOS/mac-mem")
            try write(url, "#!/bin/sh\nexit 0\n", mode: 0o755)
            return url
        }
        let cli = try fakeCLI("apps"), otherCLI = try fakeCLI("moved")
        let store = try MemoryStore(home: root.appendingPathComponent("history", isDirectory: true), writable: true, automaticallySyncSearch: false)
        let desktop = try AIAppConnect.app("claude-desktop"), code = try AIAppConnect.app("claude-code")
        let cursor = try AIAppConnect.app("cursor"), windsurf = try AIAppConnect.app("windsurf")
        func verify(_ app: AIApp) -> (String) -> Bool? { { store.connectKeyWorks(app, key: $0) } }
        func connect(_ app: AIApp, command: URL? = nil, home: URL? = nil, expected: String? = nil) throws -> AIAppConnectResult {
            try AIAppConnect.connect(app, env: env, command: command ?? cli, home: home, expectedSHA256: expected, verify: verify(app),
                                     grant: { try store.connectGrant(app) }, revoke: { try store.connectRevoke(app) })
        }
        func disconnect(_ app: AIApp, expected: String? = nil) throws -> AIAppConnectResult {
            try AIAppConnect.disconnect(app, env: env, command: cli, home: nil, expectedSHA256: expected, revoke: { try store.connectRevoke(app) })
        }
        func state(_ app: AIApp, command: URL? = nil) -> AIAppConnectionState {
            AIAppConnect.status(app, env: env, command: command ?? cli, home: nil, verify: verify(app))
        }

        // MARK: Nothing installed
        check(AIAppConnect.apps.allSatisfy { state($0) == .notInstalled }, "an empty home: every app reads Not on this Mac")
        rejects(AIAppConnectError.notInstalled("Cursor"), "connecting an app that isn't on this Mac is refused") { _ = try connect(cursor) }
        check(!fm.fileExists(atPath: AIAppConnect.file(cursor, env).path), "a refused connect writes no file")
        rejects(AIAppConnectError.unknownApp("chatbot"), "an unknown app name is refused") { _ = try AIAppConnect.app("chatbot") }

        // MARK: Claude Desktop: the app is installed (its bundle), no settings folder yet
        try fm.createDirectory(at: applications.appendingPathComponent("Claude.app"), withIntermediateDirectories: true)
        check(state(desktop) == .notConnected, "an installed app with no settings file reads Not connected")
        let desktopFile = AIAppConnect.file(desktop, env)
        let review = try AIAppConnect.plan(.connect, desktop, env: env, command: cli, home: nil, verify: verify(desktop))
        check(review.outcome == .add && !review.fileExists && review.backup == nil && review.reviewedSHA256 == "absent", "review: adds the entry to a new file, no backup")
        check(review.file == desktopFile && AIAppConnect.display(review.file, env) == "~/Library/Application Support/Claude/claude_desktop_config.json",
              "review names the exact file, shortened to ~")
        let preview = review.entryPreview ?? ""
        check(preview.contains("\"mcpServers\"") && preview.contains("\"daydream\"") && preview.contains(cli.path) && preview.contains("\"mcp\"")
              && preview.contains(AIAppConnect.keyPlaceholder), "review shows the whole entry with the key as a placeholder")
        check(!fm.fileExists(atPath: desktopFile.path) && grants(store) == 0, "reviewing writes nothing and makes no key")
        let added = try connect(desktop, expected: review.reviewedSHA256)
        check(added.wrote && added.backup == nil && added.message.contains("Quit and reopen Claude Desktop"), "connect writes the file and says to reopen the app")
        check(mode(desktopFile) == 0o600 && mode(desktopFile.deletingLastPathComponent()) == 0o700, "a new settings file is owner-only, in an owner-only folder")
        let desktopKey = key(desktopFile) ?? ""
        check(desktopKey.count == 72 && store.connectKeyWorks(desktop, key: desktopKey), "the written key opens DayDream's history for that app")
        check(!store.connectKeyWorks(cursor, key: desktopKey), "the key works only for the app it was made for")
        check(entry(desktopFile)?["command"] as? String == cli.path
              && entry(desktopFile)?["args"] as? [String] == ["--client", "claude-desktop", "--recipient", AIAppConnect.recipient, "mcp"]
              && entry(desktopFile)?["type"] == nil, "the entry starts this mac-mem with fixed arguments (plain style)")
        check(!review.notes.joined().contains(desktopKey) && !preview.contains(desktopKey) && !added.message.contains(desktopKey), "the key is never in a review or message")
        check(state(desktop) == .connected, "status reads Connected")

        // Connecting twice changes nothing.
        let before = bytes(desktopFile), attributes = try fm.attributesOfItem(atPath: desktopFile.path)
        let again = try connect(desktop)
        check(!again.wrote && again.plan.outcome == .alreadyConnected, "connecting again reports already connected")
        let modified = try fm.attributesOfItem(atPath: desktopFile.path)[.modificationDate] as? Date
        check(bytes(desktopFile) == before && modified == attributes[.modificationDate] as? Date,
              "connecting again leaves the file untouched")
        check(store.connectKeyWorks(desktop, key: desktopKey) && grants(store) == 1, "connecting again keeps the same key")
        check(!fm.fileExists(atPath: AIAppConnect.backupFile(desktop, env).path), "no backup when nothing was written")

        // MARK: Cursor: an existing file with other servers and settings
        let cursorFile = AIAppConnect.file(cursor, env)
        let original = """
        {
          "mcpServers": {
            "notes": {"command": "/usr/local/bin/notes-mcp", "args": ["--stdio"], "env": {"NOTES_TOKEN": "keep-me"}},
            "weather": {"url": "http://localhost:4000/sse", "disabled": true}
          },
          "theme": "dark",
          "fontSize": 13.5,
          "retries": 3,
          "beta": false,
          "nested": {"list": [1, 2.25, "three", null, {"deep": true}], "empty": {}},
          "unicode": "Café — 東京 ✓"
        }
        """
        try write(cursorFile, original, mode: 0o644)
        let originalObject = object(cursorFile)
        let cursorReview = try AIAppConnect.plan(.connect, cursor, env: env, command: cli, home: nil, verify: verify(cursor))
        check(cursorReview.outcome == .add && cursorReview.fileExists && cursorReview.backup == AIAppConnect.backupFile(cursor, env)
              && cursorReview.notes.contains { $0.contains("~/.cursor/mcp.json.daydream-backup") } && cursorReview.notes.contains("Nothing else in the file changes."),
              "review of an existing file names the backup and says nothing else changes")
        let cursorResult = try connect(cursor, expected: cursorReview.reviewedSHA256)
        var withoutOurs = object(cursorFile)
        var servers = withoutOurs["mcpServers"] as? [String: Any] ?? [:]
        let ours = servers.removeValue(forKey: "daydream")
        withoutOurs["mcpServers"] = servers
        check(ours != nil && NSDictionary(dictionary: withoutOurs).isEqual(to: originalObject), "every other server and setting is kept exactly")
        check((servers["notes"] as? [String: Any])?["env"] as? [String: String] == ["NOTES_TOKEN": "keep-me"], "another server's own key is kept")
        check(cursorResult.backup == AIAppConnect.backupFile(cursor, env) && bytes(AIAppConnect.backupFile(cursor, env)) == Data(original.utf8),
              "the backup is the file exactly as it was")
        check(mode(AIAppConnect.backupFile(cursor, env)) == 0o600 && mode(cursorFile) == 0o644, "the backup is owner-only; the file keeps its permissions")
        check((try? fm.contentsOfDirectory(atPath: cursorFile.deletingLastPathComponent().path).filter { $0.contains(".tmp") }.isEmpty) == true,
              "no temporary file is left behind")
        let cursorBytes = bytes(cursorFile)
        check(!(try connect(cursor)).wrote && bytes(cursorFile) == cursorBytes && bytes(AIAppConnect.backupFile(cursor, env)) == Data(original.utf8),
              "connecting Cursor again changes neither the file nor the backup")

        // Disconnect: removes only DayDream's entry and turns the key off.
        let cursorKey = key(cursorFile) ?? ""
        let off = try AIAppConnect.plan(.disconnect, cursor, env: env, command: cli, home: nil, verify: { _ in nil })
        check(off.outcome == .remove && off.entryPreview == nil && off.backup != nil, "disconnect review: removes the entry, keeps a backup")
        let removed = try disconnect(cursor, expected: off.reviewedSHA256)
        check(removed.wrote && entry(cursorFile) == nil && NSDictionary(dictionary: object(cursorFile)).isEqual(to: originalObject),
              "disconnect removes only DayDream's entry: the file equals the original again")
        check(!store.connectKeyWorks(cursor, key: cursorKey), "disconnect turns the key off")
        check(bytes(AIAppConnect.backupFile(cursor, env)) == cursorBytes, "the backup holds the file as it was just before disconnect")
        let afterOff = bytes(cursorFile)
        let twice = try disconnect(cursor)
        check(!twice.wrote && twice.plan.outcome == .nothingToRemove && bytes(cursorFile) == afterOff, "disconnecting again changes nothing")
        check(state(cursor) == .notConnected, "status reads Not connected after disconnect")
        check(store.connectKeyWorks(desktop, key: desktopKey), "disconnecting one app leaves another connected")

        // MARK: Claude Code: typed entries, a big settings file kept as is
        let codeFile = AIAppConnect.file(code, env)
        try write(codeFile, #"{"numStartups": 42, "projects": {"/Users/someone/work": {"allowedTools": [], "history": [{"display": "hi"}]}}, "mcpServers": {}}"#)
        let codeBefore = object(codeFile)
        _ = try connect(code)
        check(entry(codeFile)?["type"] as? String == "stdio", "Claude Code's entry has type stdio")
        var codeAfter = object(codeFile)
        codeAfter["mcpServers"] = [String: Any]()
        check(NSDictionary(dictionary: codeAfter).isEqual(to: codeBefore), "Claude Code's other settings are kept exactly")

        // MARK: A pinned history folder is written as --home
        let pinned = root.appendingPathComponent("elsewhere", isDirectory: true)
        check(AIAppConnect.arguments(windsurf, home: pinned) == ["--home", pinned.path, "--client", "windsurf", "--recipient", AIAppConnect.recipient, "mcp"],
              "a history outside the usual folder is passed as --home")

        // MARK: Hand-made entries are left alone
        let windsurfFile = AIAppConnect.file(windsurf, env)
        let handMade = #"{"mcpServers": {"daydream": {"command": "/Applications/DayDream.app/Contents/MacOS/mac-mem", "args": ["--client", "my-ai-app", "--recipient", "me", "mcp"], "env": {"MAC_MEM_CAPABILITY": "hand"}}}}"#
        try write(windsurfFile, handMade)
        check(state(windsurf) == .needsAttention(.addedByHand), "a hand-made entry reads Needs attention (added by hand)")
        rejects(AIAppConnectError.notOurs, "connect refuses to replace a hand-made entry") { _ = try connect(windsurf) }
        rejects(AIAppConnectError.notOurs, "disconnect refuses to remove a hand-made entry") { _ = try disconnect(windsurf) }
        check(bytes(windsurfFile) == Data(handMade.utf8) && !fm.fileExists(atPath: AIAppConnect.backupFile(windsurf, env).path), "the hand-made file is untouched")

        // MARK: Files DayDream won't change
        func refused<E: Error & Equatable>(_ text: String?, link: Bool = false, _ expected: E, _ name: String) throws {
            try? fm.removeItem(at: windsurfFile)
            let target = root.appendingPathComponent("elsewhere.json")
            if link {
                try write(target, #"{"mcpServers": {}}"#)
                try fm.createSymbolicLink(at: windsurfFile, withDestinationURL: target)
            } else if let text { try write(windsurfFile, text) }
            let snapshot = bytes(link ? target : windsurfFile)
            let keys = grants(store)
            rejects(expected, name) { _ = try connect(windsurf) }
            check(bytes(link ? target : windsurfFile) == snapshot && grants(store) == keys, name + ": nothing written, no key made")
            if link { try fm.removeItem(at: windsurfFile); try fm.removeItem(at: target) }
        }
        try refused(nil, link: true, AIAppConnectError.linkedFile("~/.codeium/windsurf/mcp_config.json"), "a linked settings file is refused")
        try refused("{\n  // my servers\n  \"mcpServers\": {}\n}", AIAppConnectError.notPlainJSON("~/.codeium/windsurf/mcp_config.json"), "a settings file with comments is refused")
        try refused("[1, 2, 3]", AIAppConnectError.notPlainJSON("~/.codeium/windsurf/mcp_config.json"), "a settings file that isn't an object is refused")
        try refused(#"{"mcpServers": ["daydream"]}"#, AIAppConnectError.unexpectedShape("~/.codeium/windsurf/mcp_config.json"), "servers that aren't an object are refused")
        try? fm.removeItem(at: windsurfFile)
        try fm.createDirectory(at: windsurfFile, withIntermediateDirectories: true)
        rejects(AIAppConnectError.notAFile("~/.codeium/windsurf/mcp_config.json"), "a folder in place of the file is refused") { _ = try connect(windsurf) }
        try fm.removeItem(at: windsurfFile)
        check(state(windsurf) == .notConnected, "with the file gone (and the folder left), Windsurf reads Not connected")

        // An empty file is an empty settings object.
        try write(windsurfFile, "")
        let emptyResult = try connect(windsurf)
        check(emptyResult.wrote && entry(windsurfFile) != nil && bytes(AIAppConnect.backupFile(windsurf, env)) == Data(), "an empty file gets the entry; its backup is empty")

        // A backup path that is a link is refused (never written through).
        try write(windsurfFile, #"{"mcpServers": {}, "x": 1}"#)
        let backupTarget = root.appendingPathComponent("backup-target")
        try write(backupTarget, "untouched")
        try? fm.removeItem(at: AIAppConnect.backupFile(windsurf, env))
        try fm.createSymbolicLink(at: AIAppConnect.backupFile(windsurf, env), withDestinationURL: backupTarget)
        let windsurfBefore = bytes(windsurfFile)
        rejects(AIAppConnectError.notAFile("~/.codeium/windsurf/mcp_config.json.daydream-backup"), "a linked backup path is refused") { _ = try connect(windsurf) }
        check(bytes(backupTarget) == Data("untouched".utf8) && bytes(windsurfFile) == windsurfBefore, "nothing is written through the linked backup")
        try fm.removeItem(at: AIAppConnect.backupFile(windsurf, env))

        // MARK: The file changed after the review
        // claude/connect-fix-1003: a review covers what it showed (the file being there, DayDream's own entry). The app
        // saving the rest of its file in between is kept, and the entry still goes in; DayDream's entry changing is refused.
        let stale = try AIAppConnect.plan(.connect, windsurf, env: env, command: cli, home: nil, verify: verify(windsurf))
        try write(windsurfFile, #"{"mcpServers": {}, "x": 2}"#)
        let meanwhile = try connect(windsurf, expected: stale.reviewedSHA256)
        check(meanwhile.wrote && entry(windsurfFile) != nil && object(windsurfFile)["x"] as? Int == 2
              && bytes(AIAppConnect.backupFile(windsurf, env)) == Data(#"{"mcpServers": {}, "x": 2}"#.utf8),
              "another setting saved after the review is kept, and the entry still goes in")
        _ = try disconnect(windsurf)
        check(bytes(windsurfFile) == Data(#"{"mcpServers": {}, "x": 2}"#.utf8), "disconnect gives the file back byte for byte")
        let staleEntry = try AIAppConnect.plan(.connect, windsurf, env: env, command: cli, home: nil, verify: verify(windsurf))
        _ = try connect(windsurf)
        try store.connectRevoke(windsurf)
        let withEntry = bytes(windsurfFile)
        let keysBefore = grants(store)
        rejects(AIAppConnectError.changedSinceReview, "a review made before DayDream's entry changed is refused") {
            _ = try connect(windsurf, expected: staleEntry.reviewedSHA256)
        }
        check(bytes(windsurfFile) == withEntry && grants(store) == keysBefore, "after a refused stale review: file kept, no key made")
        _ = try disconnect(windsurf)
        check(bytes(windsurfFile) == Data(#"{"mcpServers": {}, "x": 2}"#.utf8), "disconnecting the refused file gives it back byte for byte")

        // MARK: Rollback: the write fails, the new key is turned off
        let folder = windsurfFile.deletingLastPathComponent()
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        var failedKey: String?
        do {
            _ = try AIAppConnect.connect(windsurf, env: env, command: cli, home: nil, expectedSHA256: nil, verify: verify(windsurf),
                                         grant: { let k = try store.connectGrant(windsurf); failedKey = k; return k }, revoke: { try store.connectRevoke(windsurf) })
            check(false, "a failed write is reported")
        } catch { check(error is AIAppConnectError, "a failed write is reported") }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        check(failedKey.map { !store.connectKeyWorks(windsurf, key: $0) } == true, "when the write fails, the key made for it is turned off")
        check(bytes(windsurfFile) == Data(#"{"mcpServers": {}, "x": 2}"#.utf8), "when the write fails, the file is unchanged")
        do {
            _ = try AIAppConnect.connect(windsurf, env: env, command: cli, home: nil, expectedSHA256: nil, verify: verify(windsurf),
                                         grant: { throw MemError.denied }, revoke: {})
            check(false, "a key that can't be made stops the connect")
        } catch { check(bytes(windsurfFile) == Data(#"{"mcpServers": {}, "x": 2}"#.utf8), "a key that can't be made stops the connect before writing") }

        // MARK: Another copy of DayDream, and a key that stopped working
        check(state(desktop, command: otherCLI) == .needsAttention(.otherCopy), "an entry for another copy of DayDream reads Needs attention")
        let moved = try AIAppConnect.plan(.connect, desktop, env: env, command: otherCLI, home: nil, verify: verify(desktop))
        check(moved.outcome == .replace && moved.notes.contains { $0.contains("replaces its earlier") }, "connecting the moved copy replaces DayDream's own entry")
        _ = try connect(desktop, command: otherCLI)
        let newKey = key(desktopFile) ?? ""
        check(entry(desktopFile)?["command"] as? String == otherCLI.path && newKey != desktopKey && !store.connectKeyWorks(desktop, key: desktopKey)
              && store.connectKeyWorks(desktop, key: newKey), "reconnecting points at the new copy with a new key; the old key stops working")
        try store.connectRevoke(desktop)
        check(state(desktop, command: otherCLI) == .needsAttention(.keyStopped) && AIAppAttention.keyStopped.reconnects, "a key that stopped working reads Needs attention, and Connect fixes it")
        check(try AIAppConnect.plan(.connect, desktop, env: env, command: otherCLI, home: nil, verify: verify(desktop)).outcome == .replace,
              "connecting with a stopped key replaces the entry")

        // MARK: The download window
        let dmg = URL(fileURLWithPath: "/private/var/folders/xx/T/AppTranslocation/ABC/d/DayDream.app/Contents/MacOS/mac-mem")
        check(AIAppConnect.commandProblem(dmg)?.contains("Move DayDream to Applications") == true, "a translocated copy can't be connected")
        check(AIAppConnect.commandProblem(cli, readOnlyVolume: { _ in true })?.contains("Move DayDream to Applications") == true,
              "a copy on a read-only volume (the disk image) can't be connected")
        check(AIAppConnect.commandProblem(cli, readOnlyVolume: { _ in false }) == nil, "an installed copy can be connected")
        check(AIAppConnect.commandProblem(root.appendingPathComponent("missing/mac-mem"))?.contains("missing") == true, "a missing command-line tool is reported")
        rejects(AIAppConnectError.unsafeCommand(AIAppConnect.commandProblem(dmg)!), "connect from the download window is refused") { _ = try connect(cursor, command: dmg) }

        // MARK: Summaries survive a disconnect; prepared snapshots don't
        try store.exec("INSERT INTO generated_notes VALUES('fixture-note',1,'r','{}')")
        let revision = try store.disclosureRevision()
        _ = try store.connectGrant(cursor)
        try store.connectRevoke(cursor)
        check((try? store.rows("SELECT id FROM generated_notes").count) == 1, "turning an AI app's key off keeps the person's summaries")
        check((try? store.disclosureRevision()) != revision, "turning a key off invalidates prepared snapshots (new disclosure revision)")

        try exactEdits(root: root, user: user, env: env, cli: cli, store: store)

        print("\(passes) connect config checks passed, \(failures) failed. Scratch folders only; no AI app, MCP server or real settings file was touched.")
        exit(failures == 0 ? 0 : 1)
    }
    // MARK: Exact text edits (claude/connect-fix-1003)
    // The live bug: `mac-mem connect claude-code` refused ~/.claude.json ("couldn't prove that the rest of the file would
    // stay the same"). Connect printed the whole file again, and Foundation prints some decimals with 17 digits
    // (0.022845 -> 0.022845000000000001) that read back as different numbers. Now only the entry's own bytes change.

    /// `after` is `before` with one run of bytes inserted (nothing else differs).
    static func onlyInserted(_ before: Data, _ after: Data) -> Bool {
        let (p, q) = commonEnds(before, after)
        return after.count >= before.count && p + q == before.count
    }
    /// Lengths of the common prefix and (non-overlapping) common suffix.
    static func commonEnds(_ before: Data, _ after: Data) -> (Int, Int) {
        let a = [UInt8](before), b = [UInt8](after)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var q = 0
        while q < a.count - p, q < b.count - p, a[a.count - 1 - q] == b[b.count - 1 - q] { q += 1 }
        return (p, q)
    }
    static func inserted(_ before: Data, _ after: Data) -> String {
        let (p, q) = commonEnds(before, after)
        return String(decoding: after[p..<(after.count - q)], as: UTF8.self)
    }
    static func plusEntry(_ before: [String: Any], _ key: String = "mcpServers", entry: [String: Any]?) -> NSDictionary {
        var root = before
        var servers = root[key] as? [String: Any] ?? [:]
        servers[AIAppConnect.entryName] = entry
        root[key] = servers
        return NSDictionary(dictionary: root)
    }

    /// Rewrites a file over and over from another thread, as an AI app saving its own settings does.
    final class Rewriter: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private(set) var writes = 0
        private let done = DispatchSemaphore(value: 0)
        /// `merge`: read the file, change one setting, write it back (an app that reads before it saves).
        /// Otherwise: write `stale` again and again (an app saving the copy it read before DayDream's change).
        init(_ url: URL, every interval: useconds_t, stale: Data? = nil) {
            DispatchQueue.global().async { [self] in
                defer { done.signal() }
                while isRunning {
                    if let stale {
                        Self.save(stale, to: url)
                    } else if let data = try? Data(contentsOf: url), var text = String(data: data, encoding: .utf8),
                              let range = text.range(of: #""numStartups": \d+"#, options: .regularExpression) {
                        let n = Int(text[range].split(separator: " ").last ?? "0") ?? 0
                        text.replaceSubrange(range, with: "\"numStartups\": \(n + 1)")
                        Self.save(Data(text.utf8), to: url)
                    }
                    lock.lock(); writes += 1; lock.unlock()
                    usleep(interval)
                }
            }
        }
        static func save(_ data: Data, to url: URL) {
            let temp = url.deletingLastPathComponent().appendingPathComponent(".rewriter-\(UUID().uuidString)")
            if (try? data.write(to: temp)) != nil { rename(temp.path, url.path) }
        }
        private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
        func stop() { lock.lock(); running = false; lock.unlock(); done.wait() }
    }

    static func exactEdits(root: URL, user: URL, env: AIAppConnectEnvironment, cli: URL, store: MemoryStore) throws {
        let code = try AIAppConnect.app("claude-code"), cursor = try AIAppConnect.app("cursor")
        let desktop = try AIAppConnect.app("claude-desktop"), windsurf = try AIAppConnect.app("windsurf")
        func verify(_ app: AIApp) -> (String) -> Bool? { { store.connectKeyWorks(app, key: $0) } }
        func connect(_ app: AIApp, expected: String? = nil, grant: (() throws -> Void)? = nil) throws -> AIAppConnectResult {
            try AIAppConnect.connect(app, env: env, command: cli, home: nil, expectedSHA256: expected, verify: verify(app),
                                     grant: { let key = try store.connectGrant(app); try grant?(); return key }, revoke: { try store.connectRevoke(app) })
        }
        func disconnect(_ app: AIApp) throws -> AIAppConnectResult {
            try AIAppConnect.disconnect(app, env: env, command: cli, home: nil, expectedSHA256: nil, revoke: { try store.connectRevoke(app) })
        }
        let codeFile = AIAppConnect.file(code, env), codeBackup = AIAppConnect.backupFile(code, env)
        func reset(_ app: AIApp) { try? fm.removeItem(at: AIAppConnect.backupFile(app, env)); try? store.connectRevoke(app) }

        // The reproduction: base 8cfa725 refuses every one of these with "couldn't prove…".
        try write(codeFile, #"{"numStartups": 1, "lastCost": 0.022845}"#)
        let tiny = try connect(code)
        check(tiny.wrote && bytes(codeFile).map { String(decoding: $0, as: UTF8.self).hasPrefix(#"{"numStartups": 1, "lastCost": 0.022845, "mcpServers": {"#) } == true,
              "a decimal Foundation can't print back (0.022845) no longer stops Connect, and is kept as written")
        _ = try disconnect(code)
        check(bytes(codeFile) == Data(#"{"numStartups": 1, "lastCost": 0.022845}"#.utf8), "disconnect gives the small file back byte for byte")
        reset(code)

        // A large ~/.claude.json-shaped file, with and without a servers object, in Claude Code's own layout.
        for (label, servers) in [("no mcpServers", nil), ("empty mcpServers", []), ("other servers", ["notes", "weather"])] as [(String, [String]?)] {
            let original = Data(ClaudeJSONShape.make(projects: 300, servers: servers).utf8)
            try write(codeFile, String(decoding: original, as: UTF8.self))
            let before = object(codeFile)
            check(original.count > 800_000 && before.count > 8, "\(label): the synthetic file is large (\(original.count) bytes) and parses")
            let review = try AIAppConnect.plan(.connect, code, env: env, command: cli, home: nil, verify: verify(code))
            let result = try connect(code, expected: review.reviewedSHA256)
            let connected = bytes(codeFile) ?? Data()
            let key = Self.key(codeFile) ?? ""
            check(result.wrote && onlyInserted(original, connected), "\(label): connect only inserts bytes; every other byte is unchanged")
            check(plusEntry(before, entry: entry(codeFile)).isEqual(to: object(codeFile)) && entry(codeFile)?["type"] as? String == "stdio",
                  "\(label): the file reads as the original plus DayDream's entry, value by value")
            let added = inserted(original, connected)
            check(added.contains("\"daydream\": {\n      \"type\": \"stdio\",\n      \"command\": "),
                  "\(label): the entry uses the file's own two-space layout and \": \"")
            check(bytes(codeBackup) == original, "\(label): the backup is the file exactly as it was")
            check(AIAppConnect.status(code, env: env, command: cli, home: nil, verify: verify(code)) == .connected, "\(label): status reads Connected")
            check(!result.message.contains(key) && !review.notes.joined().contains(key) && !(review.entryPreview ?? "").contains(key),
                  "\(label): the key is in no message or review")
            _ = try disconnect(code)
            check(bytes(codeFile) == original, "\(label): disconnect is the exact inverse: the original bytes come back")
            // A stopped key: Connect replaces only the entry's value.
            _ = try connect(code)
            let first = bytes(codeFile) ?? Data(), firstKey = Self.key(codeFile)
            try store.connectRevoke(code)
            _ = try connect(code)
            let replaced = bytes(codeFile) ?? Data()
            let (p, q) = commonEnds(first, replaced)
            check(Self.key(codeFile) != firstKey && replaced.count == first.count && first.count - p - q <= 72,
                  "\(label): reconnecting replaces only the key's characters")
            _ = try disconnect(code)
            var afterReplace = object(codeFile), originalObject = before
            for i in [0, 1] {
                var o = i == 0 ? afterReplace : originalObject
                if (o["mcpServers"] as? [String: Any])?.isEmpty == true { o.removeValue(forKey: "mcpServers") }
                if i == 0 { afterReplace = o } else { originalObject = o }
            }
            check(NSDictionary(dictionary: afterReplace).isEqual(to: originalObject) && onlyInserted(original, bytes(codeFile) ?? Data()),
                  "\(label): after a reconnect, disconnect gives back the original settings (an empty mcpServers DayDream added may stay)")
            reset(code)
        }

        // Claude Code saves its file while DayDream connects. Its saves read the file first, so the entry survives them.
        let shaped = ClaudeJSONShape.make(projects: 40, servers: nil)
        try write(codeFile, shaped)
        let racedReview = try AIAppConnect.plan(.connect, code, env: env, command: cli, home: nil, verify: verify(code))
        try write(codeFile, shaped.replacingOccurrences(of: "\"numStartups\": 412", with: "\"numStartups\": 413"))
        let afterSave = try connect(code, expected: racedReview.reviewedSHA256, grant: {
            try write(codeFile, shaped.replacingOccurrences(of: "\"numStartups\": 412", with: "\"numStartups\": 414"))
        })
        check(afterSave.wrote && entry(codeFile) != nil && object(codeFile)["numStartups"] as? Int == 414,
              "Claude Code saving its file after the review and while the key is made: the entry still goes in, its save is kept")
        _ = try disconnect(code)
        check(bytes(codeFile) == Data(shaped.replacingOccurrences(of: "\"numStartups\": 412", with: "\"numStartups\": 414").utf8),
              "after those saves, disconnect gives back Claude Code's latest file byte for byte")
        reset(code)
        try write(codeFile, shaped)
        let merging = Rewriter(codeFile, every: 50_000)
        let busy = try connect(code)
        usleep(200_000)
        merging.stop()
        check(busy.wrote && entry(codeFile) != nil && Self.key(codeFile).map { store.connectKeyWorks(code, key: $0) } == true && merging.writes >= 5,
              "Claude Code saving every 50 ms during and after Connect: connected, and its saves kept the entry", "writes \(merging.writes)")
        check((object(codeFile)["numStartups"] as? Int ?? 0) > 412 && object(codeFile)["projects"] != nil, "…and its own changes are all there")
        _ = try disconnect(code)
        reset(code)
        // An app that keeps saving the copy it read before DayDream's change: DayDream stops, says what to do, turns the key off.
        try write(codeFile, shaped)
        var keys = grants(store)
        let clobber = Rewriter(codeFile, every: 1_000, stale: Data(shaped.utf8))
        var clobberError: Error?
        do { _ = try connect(code) } catch { clobberError = error }
        clobber.stop()
        let message = (clobberError as? AIAppConnectError)?.description ?? ""
        check(clobberError as? AIAppConnectError == .keptChanging("Claude Code", "~/.claude.json")
              && message.contains("Connect again") && message.contains("quit Claude Code"),
              "a file overwritten again and again: refused with what to do", message)
        check(bytes(codeFile) == Data(shaped.utf8) && grants(store) == keys, "…the file is the app's own, and the key made for it is off",
              "same bytes \(bytes(codeFile) == Data(shaped.utf8)), grants \(grants(store)) vs \(keys), writes \(clobber.writes)")
        reset(code)
        // Claude Code's own lock (~/.claude.json.lock, a folder): DayDream waits for it and never touches it.
        try write(codeFile, shaped)
        let lock = URL(fileURLWithPath: codeFile.path + ".lock")
        try fm.createDirectory(at: lock, withIntermediateDirectories: false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            try? Data(shaped.replacingOccurrences(of: "\"numStartups\": 412", with: "\"numStartups\": 500").utf8).write(to: codeFile)
            try? FileManager.default.removeItem(at: lock)
        }
        let started = Date()
        let waited = try connect(code)
        check(waited.wrote && Date().timeIntervalSince(started) >= 0.35 && object(codeFile)["numStartups"] as? Int == 500 && entry(codeFile) != nil,
              "a held Claude Code lock: DayDream waits, then adds its entry to the file Claude Code saved")
        check(!fm.fileExists(atPath: lock.path), "DayDream never makes Claude Code's lock")
        _ = try disconnect(code)
        reset(code)
        try fm.createDirectory(at: lock, withIntermediateDirectories: false)
        utimes(lock.path, [timeval(tv_sec: time(nil) - 3600, tv_usec: 0), timeval(tv_sec: time(nil) - 3600, tv_usec: 0)])
        let quick = Date()
        _ = try connect(code)
        check(Date().timeIntervalSince(quick) < 1.5 && fm.fileExists(atPath: lock.path) && entry(codeFile) != nil,
              "a lock left an hour ago is stale: DayDream goes ahead and leaves it where it is")
        try fm.removeItem(at: lock)
        _ = try disconnect(code)
        reset(code)

        // Claude Code in the middle of saving (the file empty, then half written): DayDream reads again.
        for partial in ["", String(shaped.prefix(4000))] {
            try write(codeFile, partial)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.06) { try? Data(shaped.utf8).write(to: codeFile) }
            let midSave = try connect(code)
            check(midSave.wrote && entry(codeFile) != nil && object(codeFile)["projects"] != nil,
                  "a file read while Claude Code was saving it (\(partial.isEmpty ? "empty" : "half written")) is read again, not mistaken for a blank or broken file")
            _ = try disconnect(code)
            check(bytes(codeFile) == Data(shaped.utf8), "…and disconnect gives Claude Code's saved file back")
            reset(code)
        }

        // Disconnect is the exact inverse for files DayDream made, too (Claude Code is found by its ~/.claude folder).
        try fm.createDirectory(at: user.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try? fm.removeItem(at: codeFile)
        _ = try connect(code)
        let made = String(decoding: bytes(codeFile) ?? Data(), as: UTF8.self)
        check(made.hasPrefix("{\n  \"mcpServers\": {\n    \"daydream\": {\n      \"type\": \"stdio\",") && made.hasSuffix("\n    }\n  }\n}\n"),
              "a file made from nothing is laid out like Claude Code's own")
        _ = try disconnect(code)
        check(!fm.fileExists(atPath: codeFile.path), "disconnect removes the file DayDream made from nothing")
        reset(code)
        for blank in ["", "\n", "  \n"] {
            try write(codeFile, blank)
            _ = try connect(code)
            _ = try disconnect(code)
            check(bytes(codeFile) == Data(blank.utf8), "a blank file (\(blank.utf8.count) bytes) comes back blank")
            reset(code)
        }
        try write(codeFile, "{}\n")
        _ = try connect(code)
        check(String(decoding: bytes(codeFile) ?? Data(), as: UTF8.self).hasPrefix("{\n  \"mcpServers\": {"), "an empty object gets the entry on its own lines")
        _ = try disconnect(code)
        check(bytes(codeFile) == Data("{}\n".utf8), "…and gets `{}` back")
        reset(code)

        // A review of a missing file doesn't cover a file that appeared since (it might hold an entry).
        try? fm.removeItem(at: codeFile)
        keys = grants(store)
        let absentReview = try AIAppConnect.plan(.connect, code, env: env, command: cli, home: nil, verify: verify(code))
        try write(codeFile, shaped)
        rejects(AIAppConnectError.changedSinceReview, "a file that appeared after the review of a missing file is refused") {
            _ = try connect(code, expected: absentReview.reviewedSHA256)
        }
        check(bytes(codeFile) == Data(shaped.utf8) && grants(store) == keys, "…nothing written, no key made")

        // Names listed twice are refused before a key is made: which one an app reads isn't certain.
        for twice in [#"{"mcpServers": {}, "x": 1, "mcpServers": {}}"#, "{\"mcpServers\": {\"daydream\": {\"command\": \"\(cli.path)\", \"args\": [\"--client\", \"claude-code\", \"--recipient\", \"daydream-connect\", \"mcp\"]}, \"daydream\": {\"command\": \"\(cli.path)\", \"args\": [\"--client\", \"claude-code\", \"--recipient\", \"daydream-connect\", \"mcp\"]}}}"] {
            try write(codeFile, twice)
            keys = grants(store)
            rejects(AIAppConnectError.unexpectedShape("~/.claude.json"), "a name listed twice is refused") { _ = try connect(code) }
            check(bytes(codeFile) == Data(twice.utf8) && grants(store) == keys, "…the file is untouched and no key is left")
        }
        check(AIAppConnectError.unexpectedShape("~/x.json").description.contains("Fix that part of the file, or add DayDream by hand"),
              "the layout refusal says what to do")
        check(AIAppConnectError.keptOtherSettingsCheckFailed("~/x.json").description.contains("Add DayDream by hand")
              && !AIAppConnectError.keptOtherSettingsCheckFailed("~/x.json").description.contains("couldn't prove"),
              "the value-check refusal says what to do, not just that it couldn't prove something")
        try? fm.removeItem(at: codeFile)

        // The other JSON apps: other layouts (four spaces, tabs, CRLF, one line), the same exact edits.
        let layouts: [(String, ClaudeJSONShape.Style)] = [
            ("four spaces", .init(indent: "    ")), ("tabs", .init(indent: "\t")), ("CRLF", .init(newline: "\r\n")),
            ("one line", .init(compact: true)), ("space before colon", .init(colon: " : ")),
        ]
        for (app, style) in [(cursor, layouts[0]), (desktop, layouts[1]), (windsurf, layouts[2]), (cursor, layouts[3]), (desktop, layouts[4])] {
            let file = AIAppConnect.file(app, env)
            for servers in [nil, ["notes"]] as [[String]?] {
                let original = Data(ClaudeJSONShape.make(projects: 6, servers: servers, style: style.1).utf8)
                try write(file, String(decoding: original, as: UTF8.self))
                let before = object(file)
                let label = "\(app.name), \(style.0), \(servers == nil ? "no servers" : "a server")"
                _ = try connect(app)
                let connected = bytes(file) ?? Data()
                let added = inserted(original, connected)
                check(onlyInserted(original, connected) && plusEntry(before, entry: entry(file)).isEqual(to: object(file)),
                      "\(label): only the entry's bytes are added")
                let layoutKept: Bool
                switch style.0 {
                case "four spaces": layoutKept = added.contains("\n            \"command\": ")
                case "tabs": layoutKept = added.contains("\n\t\t\t\"command\": ")
                case "CRLF": layoutKept = added.contains("\r\n") && !added.replacingOccurrences(of: "\r\n", with: "").contains("\n")
                case "one line": layoutKept = !added.contains("\n")
                default: layoutKept = added.contains("\"command\" : ")
                }
                check(layoutKept && entry(file)?["type"] == nil, "\(label): the entry copies the file's layout", added.debugDescription)
                _ = try disconnect(app)
                check(bytes(file) == original, "\(label): disconnect gives the original bytes back")
                reset(app)
            }
        }
    }
}


/// A synthetic file shaped like a real ~/.claude.json (made up here; no real file is read): large, nested projects,
/// raw and escaped unicode, `\/`, long decimals that don't survive a print-and-read, 1.0 next to 1, odd key order.
enum ClaudeJSONShape {
    indirect enum Node { case raw(String), obj([(String, Node)]), arr([Node]) }
    struct Style { var indent = "  "; var colon = ": "; var newline = "\n"; var compact = false }
    static func str(_ s: String) -> Node { .raw(s) }   // already a JSON string literal, quotes included
    static func emit(_ node: Node, _ style: Style, _ level: Int = 0) -> String {
        switch node {
        case .raw(let r): return r
        case .arr(let items):
            if items.isEmpty { return "[]" }
            if style.compact { return "[" + items.map { emit($0, style, level + 1) }.joined(separator: ",") + "]" }
            let pad = String(repeating: style.indent, count: level + 1), end = String(repeating: style.indent, count: level)
            return "[" + style.newline + items.map { pad + emit($0, style, level + 1) }.joined(separator: "," + style.newline) + style.newline + end + "]"
        case .obj(let members):
            if members.isEmpty { return "{}" }
            if style.compact { return "{" + members.map { "\"\($0.0)\"" + ":" + emit($0.1, style, level + 1) }.joined(separator: ",") + "}" }
            let pad = String(repeating: style.indent, count: level + 1), end = String(repeating: style.indent, count: level)
            return "{" + style.newline + members.map { pad + "\"\($0.0)\"" + style.colon + emit($0.1, style, level + 1) }.joined(separator: "," + style.newline)
                + style.newline + end + "}"
        }
    }
    /// `projects` sets the size (300 gives about 1.3 MB). `servers`: nil (no top-level mcpServers), [] ("{}"), or names.
    static func make(projects: Int = 300, servers: [String]? = nil, style: Style = Style()) -> String {
        var seed: UInt64 = 0x5eed_1003
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        let decimals = ["0.1234567890123456789", "0.00031415926535897932", "1.0", "2.50", "1e3", "-0", "5e-324", "1.7976931348623157e308",
                        "0.30000000000000004", "123456.78901234567", "1E-7", "0.1",
                        // Costs as Claude Code writes them: Foundation prints these with 17 digits and reads them back as other numbers.
                        "0.022845", "0.082605", "0.09819900000000001", "0.055491", "0.061275"]
        var projectMembers: [(String, Node)] = []
        for p in 0..<projects {
            var history: [Node] = []
            for h in 0..<(4 + Int(next() % 12)) {
                history.append(.obj([("display", str("\"Fix the caf\\u00e9 build \(p)-\(h): \\\"quoted\\\" path src\\/main.swift, 東京 ✓ 🚀 \\ud83d\\ude80 tab\\tend\"")),
                                     ("pastedContents", .obj(h % 3 == 0 ? [("1", .obj([("id", .raw("1")), ("type", str("\"text\"")), ("content", str("\"line\\nline \\u2028 sep\""))]))] : []))]))
            }
            let usage: Node = .obj([("claude-synthetic-\(p % 3)", .obj([("inputTokens", .raw("\(next() % 90000)")), ("outputTokens", .raw("\(next() % 9000)")),
                                                                     ("costUSD", .raw(decimals[Int(next() % UInt64(decimals.count))])), ("webSearchRequests", .raw("0"))]))])
            projectMembers.append(("/Users/synthetic/work/proj-\(p)/ünïcödé dir/\\u00e9", .obj([
                ("allowedTools", .arr([])), ("history", .arr(history)), ("mcpContextUris", .arr([])), ("mcpServers", .obj([])),
                ("enabledMcpjsonServers", .arr([])), ("disabledMcpjsonServers", .arr([])), ("hasTrustDialogAccepted", .raw(p % 2 == 0 ? "true" : "false")),
                ("projectOnboardingSeenCount", .raw("1")), ("lastCost", .raw(decimals[p % decimals.count])), ("lastAPIDuration", .raw("\(next() % 100000)")),
                ("lastDuration", .raw("1.0")), ("lastTotalInputTokens", .raw("1e3")), ("lastModelUsage", usage),
                ("exampleFiles", .arr([str("\"Sources\\/App\\/main.swift\""), str("\"README.md\"")])), ("lastSessionId", str("\"00000000-0000-4000-8000-\(String(format: "%012d", p))\"")),
            ])))
        }
        var tips: [(String, Node)] = []
        for t in 0..<60 { tips.append(("tip-\(t)", .raw("\(next() % 500)"))) }
        var top: [(String, Node)] = [
            ("numStartups", .raw("412")), ("installMethod", str("\"native\"")), ("autoUpdates", .raw("false")), ("tipsHistory", .obj(tips)),
            ("promptQueueUseCount", .raw("3")), ("userID", str("\"" + String(repeating: "0f", count: 32) + "\"")),
            ("firstStartTime", str("\"2026-01-02T03:04:05.678Z\"")), ("projects", .obj(projectMembers)),
            ("cachedGrowthBookFeatures", .obj([("rate", .raw("0.1234567890123456789")), ("ratio", .raw("1.0")), ("big", .raw("12345678901234567890")),
                                               ("neg", .raw("-0.0")), ("exp", .raw("6.02214076e23")), ("url", str("\"https:\\/\\/example.invalid\\/a\\/b\""))])),
            ("oauthAccount", .obj([("accountUuid", str("\"00000000-0000-4000-8000-000000000000\"")), ("emailAddress", str("\"someone@example.invalid\""))])),
            ("escapes", str("\"tab\\t nl\\n cr\\r bs\\\\ q\\\" slash\\/ nul\\u0000 bom\\ufeff surrogate \\ud83d\\ude00 raw 😀 é e\\u0301\"")),
        ]
        if let servers {
            let entries: [(String, Node)] = servers.map { ($0, .obj([("type", str("\"stdio\"")), ("command", str("\"\\/usr\\/local\\/bin\\/\($0)\"")),
                                                                    ("args", .arr([str("\"--stdio\"")])), ("env", .obj([("TOKEN", str("\"keep-\($0)\""))]))])) }
            top.insert(("mcpServers", .obj(entries)), at: 5)
        }
        top.append(("lastReleaseNotesSeen", str("\"2.1.288\"")))
        return emit(.obj(top), style) + style.newline
    }
}
