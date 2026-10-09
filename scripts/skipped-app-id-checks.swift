// DD-RECIPE: MemoryUI MemoryCore HistoryCore PrivacyPolicy objects (no app sources). Synthetic stores in TMPDIR only.
// rel-018: an app the picker lists can always be skipped. Some games and App Store apps have bundle IDs with
// underscores or spaces ("com.studio.Space_Game", "com.Company.Game Name"), which the old save rule
// (^[A-Za-z0-9][A-Za-z0-9.-]*$) refused with "One of the apps in this change can't be skipped, so it didn't save."
//   A. The one rule (`SkippedAppID.accepts`): real IDs pass; empty, too long, comma, control, padded are refused.
//   B. Odd IDs go through a save (store and CaptureSession), the app model's comma list, and back.
//   C. A skipped odd ID is skipped everywhere: capture intake, reads, context and search (what AI apps read).
//   D. The picker (`LocalApp.catalog`) on a synthetic Applications folder lists odd-ID apps, and skips an app whose ID
//      can't be saved; everything it lists saves.
//   E. Every app on this Mac (the real catalog: /Applications, /System/Applications) is accepted and saves.
import Foundation
import AppKit
import MemoryCore
import MemoryUI
import HistoryCore

@main struct SkippedAppIDChecks {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ name: String) {
        if ok { passed += 1; print("PASS " + name) } else { failed += 1; print("FAIL " + name) }
    }
    static let odd = ["com.studio.Space_Game", "com.Company.Game Name", "unity.Co.My_Game", "com.example.ゲーム", "com.example.app+beta", "1Password_7-Helper"]

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skipped-app-id-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A. The rule.
        for id in odd + ["com.apple.TextEdit", "dev.zed.Zed", "*", String(repeating: "a", count: 256)] {
            check(SkippedAppID.accepts(id), "A: accepted: \(id.prefix(40))")
        }
        for (id, why) in [("", "empty"), (String(repeating: "a", count: 257), "257 bytes"), (String(repeating: "é", count: 129), "258 UTF-8 bytes"),
                          ("com.a,com.b", "comma"), ("com.tab\tname", "tab"), ("com.line\nname", "newline"), ("com.nul\u{0}", "NUL"),
                          ("com.zwj\u{200D}x", "format character"), (" com.lead", "leading space"), ("com.trail ", "trailing space")] {
            check(!SkippedAppID.accepts(id), "A: refused (\(why))")
        }

        // B. Through a save, the app model's string, and back.
        let store = try MemoryStore(home: root.appendingPathComponent("store"), writable: true, automaticallySyncSearch: false)
        let session = try CaptureSession(store: store)
        let now = Date()
        let start = try store.policy()
        let saved = try session.savePreferences(MemoryPreferences(blockedApps: odd, nativeTyping: false, typingChoiceShown: true),
                                                expectedRevision: start.revision, now: now)
        check(saved.changed && Set(saved.policy.blockedApps) == Set(odd), "B: a save with underscore, space and non-ASCII IDs lands")
        let reopened = try MemoryStore(home: root.appendingPathComponent("store"), writable: false, automaticallySyncSearch: false)
        check(try Set(reopened.policy().blockedApps) == Set(odd), "B: the saved list reads back exactly (JSON round trip)")
        // The app model keeps the list as "a, b, c" and splits on commas, trimming each entry (MacMemApp.savePolicy).
        let modelString = saved.policy.blockedApps.joined(separator: ", ")
        let splitBack = modelString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        check(Set(splitBack) == Set(odd), "B: the app model's comma list keeps every ID whole")
        let again = try session.savePreferences(MemoryPreferences(blockedApps: splitBack, nativeTyping: false),
                                                expectedRevision: saved.policy.revision, now: now)
        check(!again.changed, "B: saving the list read back from the app model is no change")
        // An entry an older build saved that breaks today's rule is still taken back unchanged (never blocks a save).
        var legacy = try store.policy(); legacy.blockedApps = odd + ["bad,legacy"]; try store.updatePolicy(legacy, now: now)
        let kept = try store.savePreferences(MemoryPreferences(blockedApps: try store.policy().blockedApps + ["com.more.Game_2"], nativeTyping: false),
                                             expectedRevision: try store.policy().revision)
        check(kept.policy.blockedApps.contains("bad,legacy") && kept.policy.blockedApps.contains("com.more.Game_2"),
              "B: an older saved entry is kept and doesn't block adding an odd ID")
        var refused = false
        do { _ = try store.savePreferences(MemoryPreferences(blockedApps: ["new,entry"], nativeTyping: false), expectedRevision: try store.policy().revision) }
        catch PreferenceSaveError.invalidApps { refused = true }
        check(refused, "B: a new entry the rule refuses is still refused (invalidApps)")

        // C. Skipped everywhere: intake, reads, context, search.
        let read = try MemoryStore(home: root.appendingPathComponent("reads"), writable: true, automaticallySyncSearch: false)
        let readSession = try CaptureSession(store: read)
        let gameID = "com.Company.Game Name", spaceID = "com.studio.Space_Game"
        func event(_ id: String, _ bundle: String, _ title: String) -> Evidence {
            Evidence(id: id, at: ISO8601DateFormatter().string(from: now), kind: "window.changed", app: "Synthetic Game", bundle: bundle, title: title, synthetic: true)
        }
        check(try read.ingest(event("game-before", gameID, "Synthetic lagoon level"), now: now), "C: an included odd-ID app is recorded")
        check(try read.read("game-before", now: now) != nil, "C: and read back")
        let wordHits = try read.search(query: "lagoon")
        check(!wordHits.isEmpty, "C: search finds the included app's row")
        let skip = try readSession.savePreferences(MemoryPreferences(blockedApps: [gameID, spaceID], nativeTyping: false, typingChoiceShown: true),
                                                   expectedRevision: try read.policy().revision, now: now)
        check(skip.changed, "C: skipping both odd IDs saves")
        let policy = try read.policy()
        check(policy.policy.dropReason(bundleIdentifier: gameID, windowTitle: nil, urlDomain: nil) == .applicationPolicy
              && policy.policy.dropReason(bundleIdentifier: spaceID, windowTitle: nil, urlDomain: nil) == .applicationPolicy,
              "C: the privacy policy drops both apps at capture")
        check(policy.policy.dropReason(bundleIdentifier: "com.Company.Game", windowTitle: nil, urlDomain: nil) == nil
              && policy.policy.dropReason(bundleIdentifier: "com.studio.Space-Game", windowTitle: nil, urlDomain: nil) == nil,
              "C: matching is exact (a near-miss ID is not skipped)")
        check(try !read.ingest(event("game-after", gameID, "Synthetic cavern level"), now: now), "C: a new event from the skipped app is not recorded")
        check(try read.read("game-before", now: now) == nil, "C: the earlier row is hidden from reads")
        check(try read.search(query: "lagoon").isEmpty, "C: and from search (what AI apps read)")
        check(try !read.context(now: now).sourceIDs.contains("game-before"), "C: and from the AI apps' context")
        let unskip = try readSession.savePreferences(MemoryPreferences(blockedApps: [], nativeTyping: false),
                                                     expectedRevision: try read.policy().revision, now: now)
        check(try unskip.changed && read.read("game-before", now: now) != nil, "C: unskipping brings the row back (skipping is not deleting)")

        // D. The picker on a synthetic Applications folder.
        let apps = root.appendingPathComponent("Applications")
        func makeApp(_ name: String, _ id: String) throws {
            let contents = apps.appendingPathComponent(name + ".app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        }
        try makeApp("Space Game", "com.studio.Space_Game")
        try makeApp("Game Name", "com.Company.Game Name")
        try makeApp("My Game", "unity.Co.My_Game")
        try makeApp("Comma App", "com.bad,comma")
        let listed = LocalApp.catalog(roots: [apps])
        let ids = Set(listed.map(\.id))
        check(ids == ["com.studio.Space_Game", "com.Company.Game Name", "unity.Co.My_Game"],
              "D: the picker lists the odd-ID apps and leaves out the one that can't be saved: \(ids.sorted())")
        let pickStore = try MemoryStore(home: root.appendingPathComponent("pick"), writable: true, automaticallySyncSearch: false)
        let picked = try pickStore.savePreferences(MemoryPreferences(blockedApps: listed.map(\.id), nativeTyping: false), expectedRevision: try pickStore.policy().revision)
        check(Set(picked.policy.blockedApps) == ids, "D: every listed app saves")

        // E. Every app on this Mac.
        let mac = LocalApp.catalog()
        check(!mac.isEmpty, "E: the catalog found apps on this Mac (\(mac.count))")
        let notAccepted = mac.filter { !SkippedAppID.accepts($0.id) }
        check(notAccepted.isEmpty, "E: every app on this Mac is accepted by the rule")
        let oldRule = mac.filter { $0.id.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) == nil }
        print("INFO \(oldRule.count) of \(mac.count) apps on this Mac would have been refused by the old rule: \(oldRule.map(\.id).sorted())")
        let macStore = try MemoryStore(home: root.appendingPathComponent("mac"), writable: true, automaticallySyncSearch: false)
        var everySaved = true
        for chunk in stride(from: 0, to: mac.count, by: 256).map({ Array(mac[$0..<min($0 + 256, mac.count)]) }) {
            do {
                let result = try macStore.savePreferences(MemoryPreferences(blockedApps: chunk.map(\.id), nativeTyping: false),
                                                          expectedRevision: try macStore.policy().revision)
                if Set(result.policy.blockedApps) != Set(chunk.map(\.id)) { everySaved = false }
            } catch { everySaved = false; print("INFO save failed: \(error)") }
        }
        check(everySaved, "E: every app on this Mac saves as skipped (in lists of up to 256)")

        print("\(failed == 0 ? "PASSED" : "FAILED") \(passed) skipped-app-id checks, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
