// DD-RECIPE: CAPTURE + scripts/harness/Timeline.swift scripts/harness/Oracles.swift scripts/harness/CaptureDriver.swift Sources/MacMemApp/WakeResume.swift Sources/MacMemApp/LaunchLocation.swift Sources/MacMemApp/TypedTextExpiryTimer.swift
import Foundation
import HistoryCore
@testable import MemoryCore
import PrivacyPolicy

// Replays every synthetic flow in scripts/fixtures/flows through the real capture objects (scripts/harness/README.md),
// compiled from the runner's capture list ($CAPTURE: Sources/MacMemApp/Coordinator.swift as its headless copy, with
// EventCapture.swift and the rest of the list in scripts/daydream-core-source-checks.py),
// twice each into fresh scratch stores, and checks:
// - determinism: both replays leave the same store rows (the printed HASH is sha256 of the normalized rows);
// - the fixture's `expect` block: typed rows and their exact words, Chrome page rows, words never saved, launch counts,
//   whether recording is on at the end;
// - the bug labels: [bug-7] (four Google searches keep their own words), [bug-8] (a draft extended later keeps its
//   "sig :(" ending and its own row), [bug-9] (login launches and update relaunches), [bug-13] (Messages typing saved
//   on a fresh install, an upgrade's explicit off kept).
//
// Usage: flow-replay-checks <fixtures dir> <scratch dir> [name-filter]

@main
struct FlowReplayChecks {
    static var failures = 0, passes = 0
    static func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1; print("PASS \(label)") } else { failures += 1; print("FAIL \(label)\(detail().isEmpty ? "" : ": " + detail())") }
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("usage: flow-replay-checks <fixtures dir> <scratch dir> [filter]"); exit(2) }
        let dir = URL(fileURLWithPath: args[1]), scratch = URL(fileURLWithPath: args[2])
        let filter = args.count > 3 ? args[3] : nil
        // Only a scratch folder: the replay's stores live here and nowhere else.
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        guard !scratch.path.contains("/Library/Application Support/DayDream"), !home.isEmpty else { print("FAIL scratch is not a scratch folder"); exit(1) }
        CaptureDriver.installSeams()
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        check(files.count >= 12, "[flows] at least 12 synthetic flows", "\(files.count)")
        for file in files where filter.map({ file.lastPathComponent.contains($0) }) ?? true {
            let started = Date()
            do {
                let t = try Timeline.load(file)
                let a = try replay(t, scratch.appendingPathComponent("\(t.name)-a"))
                let b = try replay(t, scratch.appendingPathComponent("\(t.name)-b"))
                print("HASH \(t.name) \(a.hash)")
                check(a.hash == b.hash && !a.rows.isEmpty, "[flows] \(t.name): two replays leave the same \(a.rows.count) store rows",
                      firstDiff(a.rows, b.rows))
                expectations(t, a)
                labels(t, a)
                for note in a.notes { print("note \(t.name): \(note)") }
                if ProcessInfo.processInfo.environment["DD_FLOW_VERBOSE"] != nil { print("typed \(t.name): " + show(a)); print("pages \(t.name): \(a.pages)") }
                print(String(format: "time %@ %.1fs", t.name, Date().timeIntervalSince(started)))
            } catch { check(false, "[flows] \(file.lastPathComponent) replays", "\(error)") }
        }
        print("flow-replay: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func replay(_ t: Timeline, _ root: URL) throws -> ReplayResult {
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = try CaptureDriver(t, root: root).replay()
        try? FileManager.default.removeItem(at: root)
        return result
    }

    static func firstDiff(_ a: [String], _ b: [String]) -> String {
        if a.count != b.count { return "\(a.count) rows vs \(b.count)" }
        for (x, y) in zip(a, b) where x != y { return "first differing row:\n  \(x)\n  \(y)" }
        return "no rows"
    }

    static func show(_ r: ReplayResult) -> String {
        r.typed.map { "\($0.bundle) run \($0.run).\($0.part) [\($0.seal)] \"\($0.words)\"" }.joined(separator: " | ")
    }

    static func expectations(_ t: Timeline, _ r: ReplayResult) {
        guard let e = t.expect else { return }
        if let typed = e.typed {
            let got = r.typed.map { ExpectedTyped(bundle: $0.bundle, words: $0.words) }
            check(got == typed, "[flows] \(t.name): typed rows and their exact words", "got " + show(r))
        }
        if let pages = e.pages { check(r.pages == pages, "[flows] \(t.name): Chrome page rows", "got \(r.pages)") }
        for word in e.never ?? [] { check(!r.raw.contains(word), "[flows] \(t.name): \"\(word)\" is never saved") }
        if let opened = e.opened { check(r.opened == opened, "[flows] \(t.name): app_opened counts", "got \(r.opened)") }
        if let updated = e.updated { check(r.updated == updated, "[flows] \(t.name): app_updated versions", "got \(r.updated)") }
        if let on = e.recordingAtEnd { check(r.recordingAtEnd == on, "[flows] \(t.name): recording on at the end = \(on)", "got \(r.recordingAtEnd)") }
    }

    /// The bug labels, each from the flows built on that bug's real report.
    static func labels(_ t: Timeline, _ r: ReplayResult) {
        let n = t.name
        if n.hasPrefix("google-searches") {
            let searches = zip(r.pages, r.pageSites).filter { $0.1.contains("google.") }.map { $0.0 }
            check(searches.count == 4 && Set(searches).count == 4 && searches.allSatisfy { !$0.isEmpty && !$0.contains("google.") },
                  "[bug-7] \(n): four Google searches are four page rows, each titled with its own words (never google.com x4)", "pages \(Array(zip(r.pages, r.pageSites)))")
            let typedSearches = r.typed.filter { $0.bundle == CaptureDriver.chrome }
            check(typedSearches.count == 4 && typedSearches.allSatisfy { !$0.words.hasPrefix("<") },
                  "[flows] \(n): each search's typed search row reads back with its words", show(r))
        }
        if n.hasPrefix("draft-extended") {
            let sig = r.typed.filter { $0.words.hasSuffix("sig :(") }
            check(!sig.isEmpty, "[bug-8] \(n): the draft continued after a long pause keeps its exact \"sig :(\" ending", show(r))
            // Not vacuous: with no "sig :(" row at all (the carry lost) this fails too, never passes on an empty list.
            check(!sig.isEmpty && sig.allSatisfy { $0.part >= 2 }, "[bug-8] \(n): the continuation is the same unit's next part, not a lost carry", show(r))
            check(!r.raw.contains("[withheld]"), "[bug-8] \(n): nothing typed is withheld as a secret", show(r))
            // The same records re-saved with the paste fact the RC's binding leaves out (CaptureDriver.carryReplay),
            // with the summaries pass where the replay ran it: bug 8 itself (the pass dropped the carry).
            let carried = r.carry.map { "\($0.bundle) part \($0.part) [\($0.seal)] \"\($0.words)\"" }.joined(separator: " | ")
            check(r.carry.contains { $0.words.hasSuffix("sig :(") && $0.part >= 2 } && !r.carry.contains { $0.words.contains("[withheld]") },
                  "[bug-8] \(n): a summaries pass between two parts keeps the carry, the next part is saved as typed (carry replay)", carried)
        }
        if n.hasPrefix("login-launch") || n.hasPrefix("update-relaunch") || n.hasPrefix("quit-and-reopen") {
            // Every launch the person asked for (Finder, the Dock) counts once; a login launch and DayDream's own
            // relaunch never do.
            let asked = t.events.filter { $0.op == .launch && $0.how == "opened" }.count
            check(r.opened == Array(repeating: "other", count: asked),
                  "[bug-9] \(n): app_opened counts each launch the person asked for once, never a login launch or a relaunch", "opened \(r.opened), want \(asked)")
        }
        if n.hasPrefix("update-relaunch") || n.hasPrefix("upgrade-") {
            check(!r.updated.isEmpty && r.updated.allSatisfy { $0.count == 2 && UsageLaunch.isVersion($0[0]) && UsageLaunch.isVersion($0[1]) && $0[0] != $0[1] },
                  "[bug-9] \(n): app_updated sends the release versions it updated from and to (never unknown or the same)", "updated \(r.updated)")
        }
        if n.hasPrefix("busy-mac-then-lock") {
            check(r.typed.contains { $0.words == "and the agenda" },
                  "[bug-1] \(n): a save refused for a late heartbeat never stops recording: the next words are saved", show(r))
            check(r.recordingAtEnd && r.typed.contains { $0.words == "after the unlock" },
                  "[bug-1] \(n): after the lock, the unlock records again and what is typed next is saved", show(r))
        }
        if n.hasPrefix("fresh-install-messages") {
            check(r.typed.contains { $0.bundle == "com.apple.MobileSMS" && !$0.words.isEmpty },
                  "[bug-13] \(n): a fresh install saves what is typed in Messages", show(r))
        }
        if n.hasPrefix("upgrade-messages-off") {
            check(!r.typed.contains { $0.bundle == "com.apple.MobileSMS" }, "[bug-13] \(n): an upgrade keeps the person's Messages opt-out", show(r))
        }
    }
}
