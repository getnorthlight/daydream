// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// Help › Report a Problem: the report holds no history, titles, typed text or keys
// (Sources/MemoryCore/Diagnostics.swift). A scratch history is seeded with titles, web addresses and typed text;
// log lines are seeded with those and with keys, tokens, emails and home paths. None may survive. Synthetic only.
import Foundation
import Darwin
@testable import MemoryCore
import PrivacyPolicy

@main struct ConnectDiagnosticsChecks {
    static var passes = 0, failures = 0
    static func check(_ value: Bool, _ name: String, _ detail: String = "") {
        if value { passes += 1; print("PASS " + name) } else { failures += 1; print("FAIL " + name + (detail.isEmpty ? "" : ": " + detail)) }
    }

    static func main() throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("daydream-diagnostics-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("history", isDirectory: true)
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        let now = Date()

        // Seeded history: what must never reach a report.
        let title = "Quarterly Layoff Plan — Confidential"
        let pageTitle = "Divorce lawyer consultation notes"
        let page = "https://bank.example-private.com/accounts/991234?session=abc"
        let typed = "my secret diary entry about Sam"
        let shortTitle = "Budg"   // a short title: removed only as a whole word
        let records = [
            Evidence(id: "d1", at: iso(now.addingTimeInterval(-30)), kind: "window.changed", app: "Pages", bundle: "com.apple.iWork.Pages", title: title),
            Evidence(id: "d2", at: iso(now.addingTimeInterval(-20)), kind: "window.changed", app: "Google Chrome", bundle: "com.google.Chrome", title: pageTitle, url: page),
            Evidence(id: "d3", at: iso(now.addingTimeInterval(-10)), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes", title: shortTitle, text: typed),
        ]
        // Written straight into the records table: ingest would (rightly) skip an unverified browser page and typed
        // text while typing is off, and this check needs every kind stored.
        for record in records { try store.exec("INSERT INTO records VALUES(?,?,?)", [record.id, try json(record), record.id]) }
        let redactions = store.diagnosticsRedactions()
        let stored = Set(redactions)
        check(stored.isSuperset(of: [title, pageTitle, shortTitle]), "the redaction list has the recorded titles", redactions.joined(separator: " | "))
        check(stored.contains { $0.contains("bank.example-private.com") } && stored.contains("bank.example-private.com"),
              "the redaction list has the recorded web address and its site")
        check(redactions.contains { $0.contains("secret diary") }, "the redaction list has recorded typed text (whatever the store kept of it)")

        // Seeded log lines.
        let openRouter = "sk-or-v1-0123456789abcdef0123456789abcdef0123456789abcdef"
        let capability = UUID().uuidString + UUID().uuidString
        var log = (0..<20).map { "09:00:\(String(format: "%02d", $0)) Status: filler line \($0)" }
        log += [
            "09:01:00 Status: Recording \(title) in Pages",
            "09:01:01 Problem shown: couldn't read \(pageTitle.uppercased())",
            "09:01:02 Import: opened \(page)",
            "09:01:03 Settings: saved typed text \(typed)",
            "09:01:04 Summaries: key \(openRouter) rejected",
            "09:01:05 Updates: Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123",
            "09:01:06 Connect: MAC_MEM_CAPABILITY=\(capability)",
            "09:01:07 Backup: saved to /Users/someone/Documents/Private Folder/backup",
            "09:01:08 Backup: temp /private/var/folders/ab/cdef123/T/daydream-x/file",
            "09:01:09 Status: mail from someone.person@example.org",
            "09:01:10 Status: window \(shortTitle) and \(shortTitle)et and email",
            "09:01:11 Status: token: a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
            "09:01:12 Status: api_key=\"plain-secret-value\"",
            "09:01:13 Status: hash 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "09:01:14 Status: " + String(repeating: "long ", count: 100),
        ]
        log += (0..<29).map { "09:02:\(String(format: "%02d", $0)) Status: tail line \($0)" }
        let snapshot = DiagnosticsSnapshot(version: "0.1.0", build: "7", macOS: "26.0.0", architecture: "Apple silicon",
            appLocation: "/Applications/DayDream.app", dataFolder: "/Users/someone/Library/Application Support/DayDream",
            databaseBytes: 12_345_678, recording: "Recording", problem: "Recording stopped while \(title) was open",
            accessibility: true, inputMonitoring: false, typedText: true, chromePages: "Off", summaries: "off",
            connectedApps: ["Claude Desktop"])
        let report = Diagnostics.report(snapshot, log: log, userHome: "/Users/someone", redactions: redactions + ["Recording"])
        let lower = report.lowercased()

        for secret in [title, pageTitle, "bank.example-private.com", "accounts/991234", "session=abc", typed, "secret diary", openRouter, capability,
                       "abcdefghijklmnopqrstuvwxyz0123", "someone.person@example.org", "plain-secret-value", "/Users/someone", "cdef123",
                       "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", "0123456789abcdef0123456789abcdef"] {
            check(!lower.contains(secret.lowercased()), "the report never contains \"\(secret.prefix(24))\"")
        }
        check(!report.contains(" \(shortTitle) ") && report.contains("\(shortTitle)et") && report.contains("and email"),
              "a short title is removed as a whole word only")
        check(report.contains("~/Documents/Private Folder/backup") && report.contains("[temp]"), "paths are shortened to ~ and [temp]")
        check(report.contains("History folder: ~/Library/Application Support/DayDream"), "the history folder is shown from ~")
        check(report.contains("Recording: Recording") && report.contains("Problem shown: [removed] stopped while [removed] was open"),
              "a history word never blanks a fixed label; the problem message is cleaned")
        check(report.contains("App: DayDream 0.1.0 (build 7)") && report.contains("macOS: 26.0.0 (Apple silicon)")
              && report.contains("History database: 12.3 MB") && report.contains("Accessibility: allowed")
              && report.contains("Input Monitoring: not allowed") && report.contains("\(Diagnostics.typedTextLabel): on")
              && report.contains("AI apps connected: Claude Desktop"), "the report shows version, macOS, database size, permissions and states")
        // The typed-text line names what this build types in: the release (every stage compiles the owner typing
        // flags) says "Typed text" (ux/declutter) and its typing-build line says apps and websites; a narrow build
        // says Notes and TextEdit.
        check(OwnerTyping.enabled
              ? report.contains("Typed text: on") && report.contains("Typing build: more apps and websites in Google Chrome (each off until turned on)")
              : report.contains("Typed text (Notes and TextEdit): on") && !report.contains("Typing build:"),
              "the typed-text line matches the build (\(OwnerTyping.enabled ? "release, flagged" : "narrow"))")
        // ux/declutter: the log header is short; Report a Problem's one line says what the report leaves out.
        let logPart = report.components(separatedBy: "lines from this run, cleaned):\n").last ?? ""
        let logLines = logPart.split(separator: "\n")
        check(report.contains("Recent log (50 lines from this run, cleaned):") && logLines.count == 50, "exactly the last 50 log lines", "\(logLines.count)")
        check(logLines.first?.hasPrefix("09:01:00") == false && logLines.last?.contains("tail line 28") == true && !report.contains("filler line 0 "),
              "the oldest lines are dropped, the newest kept")
        check(logLines.allSatisfy { $0.count <= Diagnostics.maxLineLength + 1 }, "every log line is at most 300 characters")
        check(report.contains("Import: opened https://[removed]") || report.contains("Import: opened [removed]"), "a web address keeps at most its scheme")
        check(Diagnostics.clean("see https://example.com/private/path?q=1#x now", userHome: "/Users/a", redactions: []) == "see https://example.com now",
              "an unrecorded web address is cut to its site")
        let longPath = "/Volumes/External Disk/projects-without-dots/daydream-builds/release-candidates/DayDream.app"
        check(Diagnostics.clean("App location: " + longPath, userHome: "/Users/a", redactions: []) == "App location: " + longPath,
              "a long folder path is kept (it isn't a key)")
        check(Diagnostics.clean("blob QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9w/cXJzdHV2d3h5eg== end", userHome: "/Users/a", redactions: [])
              == "blob [removed] end", "a long base64 run is removed, slashes and all")
        check(Diagnostics.shortenPaths("/Users/other/x and /Users/a/y", userHome: "/Users/a") == "~/x and ~/y", "any /Users/<name> becomes ~")

        // An empty log and an unknown database.
        var bare = snapshot
        bare.databaseBytes = nil; bare.problem = nil; bare.accessibility = nil; bare.connectedApps = []
        let empty = Diagnostics.report(bare, log: [], userHome: "/Users/someone", redactions: [])
        check(empty.contains("History database: not found") && empty.contains("Problem shown: none") && empty.contains("Accessibility: not checked yet")
              && empty.contains("AI apps connected: none") && empty.contains("(none yet)"), "an empty log and unknown values read plainly")

        // DayDream's own log: memory only, capped, no repeats.
        let clock = Date(timeIntervalSince1970: 0)
        let own = DiagnosticsLog(limit: 5, clock: { clock })
        for n in 0..<8 { own.record("line \(n)"); own.record("line \(n)") }
        own.record("  ")
        let lines = own.recent()
        check(lines.count == 5 && lines.last?.hasSuffix("line 7") == true && lines.first?.hasSuffix("line 3") == true, "the log keeps the newest lines up to its limit")
        check(Set(lines).count == lines.count, "a repeated line is recorded once")
        check(own.recent(2).count == 2, "recent(n) returns the newest n")
        own.record("two\nlines")
        check(own.recent(1).first?.contains("two lines") == true, "a line break can't split a log line")

        // The snapshot has no field that can hold history: only settings and states.
        let fields = Mirror(reflecting: snapshot).children.compactMap(\.label)
        check(fields == ["version", "build", "macOS", "architecture", "appLocation", "dataFolder", "databaseBytes", "recording", "problem",
                         "accessibility", "inputMonitoring", "typedText", "chromePages", "summaries", "connectedApps", "search"],
              "the report's fields are settings and states only", fields.joined(separator: ","))

        print("\(passes) diagnostics checks passed, \(failures) failed. Synthetic history and log lines only; nothing was sent.")
        exit(failures == 0 ? 0 : 1)
    }
}
