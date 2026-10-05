// DD-RECIPE: APP
// gold/save-path, review round 1: an action that saves at once never says it didn't save while the change is being
// tried again quietly after a busy moment. On the real MemoryViewModel (production mode, a private store under
// DD_CHECK_OUT) while another process holds a read lock on the file past the 1.5 s busy timeout (a child copy of this
// binary, --hold, the way an AI app's MCP read can):
//   A. Exclude App from a moment or Recall (activity.excludeApp, what ExcludeAppModifier awaits);
//   B. Don't Record <site>… (activity.excludeSite);
//   C. Settings › Sites not recorded: add and remove (model.addSite / removeSite, the card's closures);
//   D. MemoryViewModel.excludeApp itself.
// Each must produce no failure text (the notice the Recall footer and the timeline would show), save by itself once
// the file is free, and leave no problem line. It never starts capture, never opens an app, never requests a
// permission and uses no Keychain or network; the fake Chrome environment answers "not running".
import AppKit
import Combine
import CSQLite
import SwiftUI
import MemoryCore
import MemoryUI

@main @MainActor struct SavePathAppChecks {
    static var checks = 0, failures = 0
    static func check(_ condition: Bool, _ name: String) {
        if condition { checks += 1; print("PASS: " + name) }
        else { failures += 1; FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8)); print("FAIL: " + name) }
        fflush(stdout)
    }
    static func tick(_ seconds: Double = 0.05) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    static func waitUntil(_ timeout: Double, _ done: () -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if done() { return true }; try await tick(0.02) }
        return done()
    }
    static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    /// The notice a failed exclusion leaves: Recall's footer (RecallModel.excludeFailureText) and the timeline's
    /// (CanonicalTimeline.excludeFailureMessage) show the thrown text; nil when nothing was thrown.
    static func notice(_ body: () async throws -> Void) async -> String? {
        do { try await body(); return nil } catch { return RecallModel.excludeFailureText(error) }
    }
    /// Saves that failed for a moment and stayed quiet: the submit says "Unsaved changes…" once; each quiet failed try
    /// says it again (preferencesChanged runs after every flush), never "Not saved…".
    static func quietTries(_ statuses: [String]) -> Int {
        statuses.contains { $0.hasPrefix("Not saved") } ? -1 : statuses.filter { $0 == "Unsaved changes. Recording is stopped." }.count - 1
    }
    static func thrown(_ body: () throws -> Void) -> String? {
        do { try body(); return nil }
        catch let site as ChromeSiteMessage { return site.text }
        catch MemError.invalid(let text) { return text }
        catch { return "\(error)" }
    }

    /// Another process holds a read transaction (SQLite's SHARED lock) on the store's file for `seconds`.
    static func hold(_ memory: URL, seconds: Double) throws -> Process {
        let child = Process(), out = Pipe()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--hold", memory.appendingPathComponent("memory.sqlite").path, String(seconds)]
        child.standardOutput = out
        try child.run()
        var buffer = Data()
        while !String(decoding: buffer, as: UTF8.self).contains("held") {
            let more = out.fileHandleForReading.availableData
            if more.isEmpty { break }
            buffer.append(more)
        }
        return child
    }
    static func holdChild(_ path: String, _ seconds: Double) -> Never {
        // wal-1005: another connection's save holds the file (the write lock). The app's history keeps SQLite's
        // write-ahead log now, where a read (an AI app's) never makes a save busy.
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK else { exit(3) }
        print("held"); fflush(stdout)
        Thread.sleep(forTimeInterval: seconds)
        sqlite3_exec(db, "COMMIT", nil, nil, nil); sqlite3_close(db)
        exit(0)
    }

    static func main() async throws {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        if args.count == 4, args[1] == "--hold" { holdChild(args[2], Double(args[3]) ?? 2) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 240) {
            FileHandle.standardError.write(Data("FAIL: save-path-app-checks watchdog expired after 240s\n".utf8))
            exit(2)
        }
        // Codex's shared roots, spelled so run-checks.sh's rewrite of the literal prefix leaves them intact.
        let shared = ["/private/tmp/" + "day" + "dream-", "/tmp/" + "day" + "dream-"]
        guard let outPath = ProcessInfo.processInfo.environment["DD_CHECK_OUT"], outPath.hasPrefix("/"),
              !shared.contains(where: { outPath.hasPrefix($0) }) else {
            FileHandle.standardError.write(Data("FAIL: DD_CHECK_OUT is not a private output directory; run this check through run-checks.sh\n".utf8))
            exit(1)
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        let home = out.appendingPathComponent("save-path-app-" + UUID().uuidString, isDirectory: true)
        let memory = home.appendingPathComponent("memory", isDirectory: true)
        try makePrivateDirectory(out); try makePrivateDirectory(home); try makePrivateDirectory(memory)
        setenv("MAC_MEM_HOME", memory.path, 1)
        let model = MemoryViewModel()
        model.chromeAccessEnvironment = ChromeAccessEnvironment(running: { nil }, verify: { _ in false }, status: { _ in -1 }, ask: { _ in -1 },
                                                                background: { $0() }, main: { $0() })
        try await tick()
        guard !model.recordingTrial, model.development == nil, model.preferencesAvailable, !model.recording,
              let excludeApp = model.activity.excludeApp, let excludeSite = model.activity.excludeSite else {
            FileHandle.standardError.write(Data("FAIL: the production model did not open its private store: \(model.status)\n".utf8))
            exit(1)
        }
        // Longer than the first save's own waits: the stop writes the recorder's state (each write waits out the 1.5 s
        // busy timeout) before the save does, so a shorter hold lets the first try land late instead of failing.
        let holdFor = 9.0
        let reader = try MemoryStore(home: memory, automaticallySyncSearch: false)
        var statuses: [String] = []
        let watch = model.$privacySaveStatus.sink { statuses.append($0) }
        defer { watch.cancel() }

        // A. Exclude App from a moment or Recall.
        statuses = []
        var holder = try hold(memory, seconds: holdFor)
        var started = Date()
        let appNotice = await notice { try await excludeApp("com.example.synthetic") }
        var took = Date().timeIntervalSince(started)
        check(quietTries(statuses) >= 1, "A: the exclusion met the busy file and was tried again quietly (statuses \(statuses))")
        check(appNotice == nil, "A: Exclude App says nothing failed while its save is tried again (notice: \(appNotice ?? "none"), after \(String(format: "%.1f", took)) s)")
        check((try? reader.policy().blockedApps.contains("com.example.synthetic")) == true && model.activity.exclusions.excludedByYou.contains("com.example.synthetic"),
              "A: and it returns once the app is excluded")
        check(!model.preferencesUnresolved && model.preferenceProblem == nil && model.privacySaveStatus.hasPrefix("Saved preferences."),
              "A: no problem line and the status says saved (\(model.privacySaveStatus))")
        holder.waitUntilExit()

        // B. Don't Record <site>….
        _ = try await waitUntil(2) { model.activity.excludeSite != nil }
        statuses = []
        holder = try hold(memory, seconds: holdFor)
        started = Date()
        let siteNotice = await notice { try await (model.activity.excludeSite ?? excludeSite)("news.example.org") }
        took = Date().timeIntervalSince(started)
        check(quietTries(statuses) >= 1, "B: Don't Record met the busy file and was tried again quietly (statuses \(statuses))")
        check(siteNotice == nil, "B: Don't Record <site> says nothing failed while its save is tried again (notice: \(siteNotice ?? "none"), after \(String(format: "%.1f", took)) s)")
        check((try? reader.policy().blockedDomains.contains("news.example.org")) == true && model.savedSites.contains("news.example.org"),
              "B: and it returns once the site is skipped")
        check(!model.preferencesUnresolved && model.preferenceProblem == nil, "B: no problem line")
        holder.waitUntilExit()

        // C. Settings › Sites not recorded (the card's add and remove closures are synchronous).
        statuses = []
        holder = try hold(memory, seconds: holdFor)
        started = Date()
        let added = thrown { try model.addSite("example.net") }
        took = Date().timeIntervalSince(started)
        check(added == nil, "C: adding a site shows nothing under the field while its save is tried again (\(added ?? "nothing"), first try took \(String(format: "%.1f", took)) s)")
        check(quietTries(statuses) >= 1 && model.preferencesUnresolved && model.preferenceProblem == nil,
              "C: meanwhile the save is tried again quietly, the card waits and the page shows no problem line (statuses \(statuses))")
        check(try await waitUntil(10) { !model.preferencesUnresolved } && model.savedSites.contains("example.net") && model.preferenceProblem == nil,
              "C: the site is listed once the save lands by itself (\(model.savedSites))")
        holder.waitUntilExit()
        statuses = []
        holder = try hold(memory, seconds: holdFor)
        let removed = thrown { try model.removeSite("example.net") }
        check(removed == nil && quietTries(statuses) >= 1, "C: removing a site shows nothing while its save is tried again (\(removed ?? "nothing"), statuses \(statuses))")
        check(try await waitUntil(10) { !model.preferencesUnresolved } && !model.savedSites.contains("example.net") && model.preferenceProblem == nil,
              "C: the site goes once the save lands by itself (\(model.savedSites))")
        holder.waitUntilExit()

        // D. MemoryViewModel.excludeApp itself: never the status line.
        statuses = []
        holder = try hold(memory, seconds: holdFor)
        let direct = thrown { try model.excludeApp("com.example.second") }
        check(direct == nil && quietTries(statuses) >= 1, "D: excludeApp throws nothing while its save is tried again (\(direct ?? "nothing"), statuses \(statuses))")
        check(try await waitUntil(10) { !model.preferencesUnresolved } && (try? reader.policy().blockedApps.contains("com.example.second")) == true,
              "D: and the exclusion saves by itself")
        holder.waitUntilExit()

        check(!model.recording && model.stopped, "end: nothing started recording (recording \(model.recording), stopped \(model.stopped))")
        if failures > 0 { print("\(failures) FAILED, \(checks) passed"); exit(1) }
        print("PASS all \(checks) save-path app checks. Nothing started, opened or asked.")
    }
}
