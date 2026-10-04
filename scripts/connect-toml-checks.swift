// Headless, synthetic HOME + history only. Never reads the owner's ~/.codex/config.toml or starts an app.
import Foundation
import Darwin
@testable import MemoryCore

@main struct ConnectTOMLChecks {
    static var passes = 0, failures = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) {
        if (try? value()) == true { passes += 1; print("PASS " + name) }
        else { failures += 1; print("FAIL " + name) }
    }
    static func refuses(_ error: AIAppConnectError, _ name: String, _ body: () throws -> Void) {
        do { try body(); check(false, name) }
        catch let actual as AIAppConnectError { check(actual == error, name) }
        catch { check(false, name) }
    }
    static func main() throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("daydream-toml-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let user = root.appendingPathComponent("home")
        let apps = root.appendingPathComponent("apps")
        setenv("HOME", user.path, 1)
        try fm.createDirectory(at: apps.appendingPathComponent("ChatGPT.app"), withIntermediateDirectories: true)
        try fm.createDirectory(at: user, withIntermediateDirectories: true)
        let env = AIAppConnectEnvironment(userHome: user, applicationFolders: [apps])
        let app = try AIAppConnect.app("chatgpt")
        let file = AIAppConnect.file(app, env), backup = AIAppConnect.backupFile(app, env)
        let cli = root.appendingPathComponent("DayDream.app/Contents/MacOS/mac-mem")
        try fm.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cli)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let history = root.appendingPathComponent("history")
        let store = try MemoryStore(home: history, writable: true, automaticallySyncSearch: false)
        func verify(_ key: String) -> Bool? { store.connectKeyWorks(app, key: key) }
        func plan(_ action: AIAppConnectAction = .connect) throws -> AIAppConnectPlan {
            try AIAppConnect.plan(action, app, env: env, command: cli, home: history, verify: verify)
        }
        func connect(_ sha: String? = nil, command: URL? = nil) throws -> AIAppConnectResult {
            try AIAppConnect.connect(app, env: env, command: command ?? cli, home: history, expectedSHA256: sha, verify: verify,
                                     grant: { try store.connectGrant(app) }, revoke: { try store.connectRevoke(app) })
        }
        func disconnect(_ sha: String? = nil) throws -> AIAppConnectResult {
            try AIAppConnect.disconnect(app, env: env, command: cli, home: history, expectedSHA256: sha, revoke: { try store.connectRevoke(app) })
        }
        func write(_ text: String) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        func bytes(_ url: URL = file) -> Data? { try? Data(contentsOf: url) }
        func editor() throws -> MCPConfigTOML { try MCPConfigTOML(data: Data(contentsOf: file), shown: "~/.codex/config.toml") }
        func entry() throws -> [String: Any] { (try editor().root["mcp_servers"] as? [String: Any])?["daydream"] as? [String: Any] ?? [:] }
        func key() throws -> String { (try entry()["env"] as? [String: Any])?["MAC_MEM_CAPABILITY"] as? String ?? "" }
        func mode(_ url: URL) -> Int { (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int ?? -1 }
        check(app.name == "ChatGPT" && app.configPath == ".codex/config.toml" && app.bundleIDs == ["com.openai.codex"] && app.style == .toml, "ChatGPT targets shared local config with verified bundle identity")
        check(app.newChatLink("starter") == nil, "starter uses existing copied-prompt flow without inventing a deep link")
        let review = try plan()
        check(review.reviewedSHA256 == "absent" && review.outcome == .add && review.entryPreview?.contains("[mcp_servers.daydream]") == true, "missing file review shows TOML")
        check(review.entryPreview?.contains(AIAppConnect.keyPlaceholder) == true && !fm.fileExists(atPath: file.path), "review has placeholder and makes no file")
        _ = try connect(review.reviewedSHA256)
        check(mode(file) == 0o600 && mode(file.deletingLastPathComponent()) == 0o700, "new file and folder owner-only")
        let firstKey = try key(), connectedBytes = bytes()
        check(store.connectKeyWorks(app, key: firstKey), "ChatGPT capability opens synthetic history")
        check(!store.connectKeyWorks(try AIAppConnect.app("cursor"), key: firstKey), "capability isolated to ChatGPT client")
        check(try entry()["args"] as? [String] == AIAppConnect.arguments(app, home: history), "same MCP invocation with distinct client and pinned history")
        check(try AIAppConnect.entryCommand(app, env: env) == cli.path, "entry command reads TOML")
        check(AIAppConnect.status(app, env: env, command: cli, home: history, verify: verify) == .connected, "status recognizes connected TOML")
        check(!(try connect()).wrote && bytes() == connectedBytes, "repeated connect leaves bytes unchanged")
        _ = try disconnect(try plan(.disconnect).reviewedSHA256)
        check(!fm.fileExists(atPath: file.path) && bytes(backup) == connectedBytes, "disconnect restores originally missing file and backs up connected bytes")
        check(!store.connectKeyWorks(app, key: firstKey), "disconnect revokes capability")
        check(!(try disconnect()).wrote && !fm.fileExists(atPath: file.path), "repeated disconnect keeps missing file missing")

        let codexShaped = """
        model = "fixture-model"
        model_reasoning_effort = "high"
        notify = [
          "/synthetic/notify", # a comment inside an array
          "--quiet",
        ]
        tui.notifications = true
        max_bytes = 1_048_576
        mask = 0xFF_FF
        ratio = 1e-3
        limit = inf
        started = 2026-10-03T14:00:01Z
        day = 2026-10-03
        spaced = 2026-10-03 14:00:01
        unicode = "caf\\u00e9 東京 ✓"
        [mcp_servers.context7]
        command = "npx"
        args = ["-y", "@synthetic/context7-mcp"]
        env = { "API_KEY" = "synthetic-value", nested.key = 'x' }
        [mcp_servers.figma]
        url = "https://example.invalid/mcp"
        http_headers = { "X-Region" = "us-east-1" }
        [projects."/Users/synthetic/work/ünïcödé"]
        trust_level = "trusted"

        """
        for (index, original) in ["", "  \n# Settings comment\n", "model = \"fixture-model\" # comment\n[mcp_servers.notes]\ncommand = '/fixture/notes'\nargs = [\"--stdio\", \"quoted # value\"]\n[mcp_servers.notes.env]\nTOKEN = \"synthetic\"\n[profiles.\"work.local\"]\nenabled = true\n", "# no trailing newline",
            // claude/connect-fix-1003: valid TOML a ChatGPT/Codex config uses (Codex's docs show inline env tables).
            codexShaped, codexShaped.replacingOccurrences(of: "\n", with: "\r\n"), "x.y = 1\nz = [\n1, 2]\n"].enumerated() {
            try write(original)
            try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
            _ = try connect()
            check(bytes(backup) == Data(original.utf8) && mode(backup) == 0o600 && mode(file) == 0o640, "fixture \(index): exact backup and preserved mode")
            check(try editor().removingEntry() == Data(original.utf8), "fixture \(index): other settings/comments preserved byte-for-byte")
            let snapshot = bytes()
            check(!(try connect()).wrote && bytes() == snapshot, "fixture \(index): repeated connect idempotent")
            _ = try disconnect()
            check(bytes() == Data(original.utf8), "fixture \(index): disconnect exact inverse")
            check(!(try disconnect()).wrote && bytes() == Data(original.utf8), "fixture \(index): repeated disconnect idempotent")
        }
        let hand = "[mcp_servers.daydream]\ncommand = \"/manual/mac-mem\"\nargs = [\"--client\", \"chatgpt\", \"--recipient\", \"daydream-connect\", \"mcp\"]\n[mcp_servers.daydream.env]\nMAC_MEM_CAPABILITY = \"synthetic-hand\"\n"
        try write(hand)
        check(AIAppConnect.status(app, env: env, command: cli, home: history, verify: verify) == .needsAttention(.addedByHand), "hand entry even with matching flags stays hand entry")
        refuses(.notOurs, "hand entry connect refused") { _ = try connect() }
        refuses(.notOurs, "hand entry disconnect refused") { _ = try disconnect() }
        check(bytes() == Data(hand.utf8), "manual file untouched")
        let inlineHand = "[mcp_servers]\ndaydream = { command = \"x\" }\n"
        try write(inlineHand)
        refuses(.notOurs, "an inline-table daydream entry is a hand entry: connect refused") { _ = try connect() }
        check(bytes() == Data(inlineHand.utf8), "inline hand entry untouched")
        let unsupported = ["[broken\ncommand = \"x\"\n", "[a]\nx = 1\n[a]\ny = 2\n", "x = \"\"\"multiline\ntext\"\"\"\n", "[[servers]]\nx = 1\n", "x = 01\n", "x = \"bad\\q\"\n", "x = 1\nx = 2\n", "x = '''multi\nline'''\n",
                           "mcp_servers.other.command = \"/synthetic/other\"\n", "mcp_servers = { other = { command = \"/synthetic/other\" } }\n",
                           "x = { a = 1, a = 2 }\n", "x = { a = 1,\n b = 2 }\n", "x = [1, 2\n", "x = 1\ry = 2\n", "# malformed \u{1} comment\n", "# malformed \u{7f} comment\n", "[" + Array(repeating: "a", count: 17).joined(separator: ".") + "]\nx = 1\n"]
        for (index, text) in unsupported.enumerated() {
            try write(text)
            refuses(.notEditableTOML("~/.codex/config.toml"), "unsupported/invalid \(index) refused") { _ = try connect() }
            check(bytes() == Data(text.utf8), "unsupported/invalid \(index) untouched")
        }
        // claude/connect-fix-1003: a review covers the file being there and DayDream's own entry. Other settings saved
        // in between are kept and the change still goes ahead; DayDream's entry changing is refused.
        try write("# original\n")
        let stale = try plan()
        try write("# changed\n")
        check(try connect(stale.reviewedSHA256).wrote && editor().removingEntry() == Data("# changed\n".utf8),
              "a comment saved after the connect review is kept, and the entry still goes in")
        let off = try plan(.disconnect), beforeChange = bytes()!
        try Data((String(decoding: beforeChange, as: UTF8.self) + "[mcp_servers.new]\ncommand = \"/synthetic/new\"\n").utf8).write(to: file)
        check((try disconnect(off.reviewedSHA256)).wrote, "another server added after the disconnect review: disconnect still goes ahead")
        check(!(try disconnect()).wrote, "disconnecting again changes nothing")
        check(bytes() == Data("# changed\n[mcp_servers.new]\ncommand = \"/synthetic/new\"\n".utf8), "disconnect preserves another server added after connect")
        let entryStale = try plan(), withoutEntry = bytes()
        _ = try connect()
        try store.connectRevoke(app)
        let connectedOnce = bytes()
        refuses(.changedSinceReview, "a connect review made before DayDream's entry appeared is refused") { _ = try connect(entryStale.reviewedSHA256) }
        check(bytes() == connectedOnce, "the refused connect leaves the file untouched")
        _ = try connect()
        let offStale = try plan(.disconnect)
        try store.connectRevoke(app)
        _ = try connect()
        let reconnected = bytes(), reconnectedKey = try key()
        refuses(.changedSinceReview, "a disconnect review of an earlier entry is refused") { _ = try disconnect(offStale.reviewedSHA256) }
        check(bytes() == reconnected && store.connectKeyWorks(app, key: reconnectedKey), "the refused disconnect leaves the entry and its key")
        _ = try disconnect()
        check(bytes() == withoutEntry, "disconnect after those gives the file back byte for byte")
        // A stale capability can be refreshed while preserving original-existence metadata.
        try fm.removeItem(at: file)
        _ = try connect()
        try store.connectRevoke(app)
        check(try plan().outcome == .replace, "stopped key receives replacement plan")
        _ = try connect()
        _ = try disconnect()
        check(!fm.fileExists(atPath: file.path), "reconnect retains missing-file inverse")
        // Disconnect's two writes fail closed: access stops before the settings entry disappears.
        try write("# disconnect failure fixture\n")
        _ = try connect()
        let retainedKey = try key(), beforeRevokeFailure = bytes(), backupBeforeRevokeFailure = bytes(backup)
        try store.exec("INSERT INTO generated_notes VALUES('disconnect-fixture',1,'r','{}')")
        let keptNotes = try store.rows("SELECT * FROM generated_notes ORDER BY id")
        try store.exec("CREATE TRIGGER fail_connect_revoke BEFORE DELETE ON grants BEGIN SELECT RAISE(ABORT,'synthetic revocation failure'); END")
        do { _ = try disconnect(); check(false, "failed revocation reports failure") }
        catch { check((error as? MemError)?.sqliteCode == 1811, "failed revocation reports trigger constraint error") }
        check(bytes() == beforeRevokeFailure && bytes(backup) == backupBeforeRevokeFailure,
              "failed revocation keeps configured entry and backup unchanged")
        check(store.connectKeyWorks(app, key: retainedKey) && (try? plan())?.outcome == .alreadyConnected,
              "failed revocation keeps truthful connected state while key still works")
        try store.exec("DROP TRIGGER fail_connect_revoke")
        _ = try disconnect()
        check(!store.connectKeyWorks(app, key: retainedKey), "retry after revocation failure turns access off")
        _ = try connect()
        let stoppedKey = try key(), beforeFileFailure = bytes()
        try fm.removeItem(at: backup)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        refuses(.notAFile("~/.codex/config.toml.daydream-backup"), "unsafe backup stops disconnect file write") { _ = try disconnect() }
        check(bytes() == beforeFileFailure && !store.connectKeyWorks(app, key: stoppedKey),
              "failed settings write preserves entry with access already off")
        check(try store.rows("SELECT * FROM generated_notes ORDER BY id") == keptNotes, "disconnect failures preserve saved notes")
        try fm.removeItem(at: backup)
        _ = try disconnect()
        check(bytes() == Data("# disconnect failure fixture\n".utf8), "retry after file failure restores original config")
        _ = try connect()
        let racedDisconnectKey = try key()
        let raced = try AIAppConnect.disconnect(app, env: env, command: cli, home: history, expectedSHA256: nil,
            revoke: { try store.connectRevoke(app); try write("# changed during revocation\n") })
        check(!raced.wrote, "a file saved without DayDream's entry during revocation is read again: nothing left to remove")
        check(bytes() == Data("# changed during revocation\n".utf8) && !store.connectKeyWorks(app, key: racedDisconnectKey),
              "revocation-time race preserves external file change with access off")
        // A save while granting is read again: the external edit is kept and the entry goes in after it.
        try write("# grant race\n")
        var raceKey = ""
        let grantRace = try AIAppConnect.connect(app, env: env, command: cli, home: history, expectedSHA256: nil, verify: verify,
            grant: { raceKey = try store.connectGrant(app); try write("# changed while granting\n"); return raceKey }, revoke: { try store.connectRevoke(app) })
        check(try grantRace.wrote && store.connectKeyWorks(app, key: raceKey) && key() == raceKey
              && editor().removingEntry() == Data("# changed while granting\n".utf8), "grant race keeps external edit and adds the entry after it")
        _ = try disconnect()
        check(bytes() == Data("# changed while granting\n".utf8) && !store.connectKeyWorks(app, key: raceKey), "…and disconnect removes exactly that entry")
        try fm.removeItem(at: file)
        let target = root.appendingPathComponent("target.toml")
        try Data("# target\n".utf8).write(to: target)
        try fm.createSymbolicLink(at: file, withDestinationURL: target)
        refuses(.linkedFile("~/.codex/config.toml"), "linked TOML refused") { _ = try connect() }
        check(bytes(target) == Data("# target\n".utf8), "linked target untouched")
        try fm.removeItem(at: file)
        try fm.removeItem(at: file.deletingLastPathComponent())
        let redirected = root.appendingPathComponent("redirected-codex")
        try fm.createDirectory(at: redirected, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: file.deletingLastPathComponent(), withDestinationURL: redirected)
        refuses(.linkedFile("~/.codex"), "linked TOML folder refused") { _ = try connect() }
        check((try? fm.contentsOfDirectory(atPath: redirected.path).isEmpty) == true, "linked folder gets no file")
        print("\(passes) TOML connector checks passed, \(failures) failed. Synthetic HOME/history only; no app or real config touched.")
        exit(failures == 0 ? 0 : 1)
    }
}
