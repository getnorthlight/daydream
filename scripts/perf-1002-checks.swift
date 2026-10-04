// perf-1002: the menu bar label's feed (MemoryUI DedupedFeed) and the label's wiring. Headless: no window, status
// item, event tap or permission. Build (from the repo root, after `swift build`):
//   swiftc -parse-as-library -I <build>/Modules scripts/perf-1002-checks.swift <build>/MemoryUI.build/*.o \
//     <MemoryCore, HistoryCore, PrivacyPolicy objects> -o perf-1002 && ./perf-1002
import Combine
import Foundation
import MemoryUI

@MainActor final class Source: ObservableObject {
    @Published var heartbeat = 0
    @Published var state = "recording"
}

@main struct Perf1002Checks {
    @MainActor static var fails = 0
    @MainActor static func check(_ ok: Bool, _ name: String) { print((ok ? "PASS: " : "FAIL: ") + name); if !ok { fails += 1 } }
    @MainActor static func turn() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    @MainActor static func main() {
        let source = Source()
        let feed = DedupedFeed<String>(changes: [source.objectWillChange.map { _ in () }.eraseToAnyPublisher()]) { source.state }
        var sent = 0
        let watch = feed.objectWillChange.sink { sent += 1 }
        check(feed.current == "recording" && feed.publishes == 0, "the feed starts with the computed value and publishes nothing")

        // A busy model: 500 unrelated changes (heartbeats, search lines, keys) across 50 main-loop turns.
        for t in 0..<50 { for _ in 0..<10 { source.heartbeat += 1 }; if t % 10 == 0 { turn() } }
        turn()
        check(sent == 0 && feed.publishes == 0, "500 unrelated model changes publish nothing (status item untouched)")
        check(feed.computes <= 6, "a burst of changes in one main-loop turn recomputes once (\(feed.computes) recomputes)")

        // A real change publishes exactly once, with the value stored after objectWillChange.
        source.state = "paused"; source.heartbeat += 1; source.heartbeat += 1
        turn()
        check(sent == 1 && feed.current == "paused", "a changed label publishes once, after the new value is stored")
        source.heartbeat += 1; turn()
        check(sent == 1, "the same label again publishes nothing")
        source.state = "recording"; turn()
        check(sent == 2 && feed.current == "recording", "changing back publishes again")

        // A clock-only change is caught by the refresh timer.
        var clock = "Paused until 4:30 PM"
        let timed = DedupedFeed<String>(changes: [], refresh: 0.05) { clock }
        var timedSent = 0
        let watchTimed = timed.objectWillChange.sink { timedSent += 1 }
        clock = "Recording"
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check(timedSent == 1 && timed.current == "Recording", "the refresh timer publishes a label that changed with the clock alone")
        timed.stop(); feed.stop()
        source.state = "off"; turn()
        check(sent == 2, "a stopped feed publishes nothing")
        _ = (watch, watchTimed)

        // The app wiring: the label observes only the feed, never the whole app model or the typing model.
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let menu = (try? String(contentsOf: root.appendingPathComponent("Sources/MacMemApp/MenuBarContent.swift"), encoding: .utf8)) ?? ""
        let label = menu.components(separatedBy: "struct DaydreamMenuBarLabel: View {").dropFirst().first?.components(separatedBy: "\n}\n").first ?? ""
        check(!label.isEmpty && !label.contains("@ObservedObject var model") && !label.contains("@ObservedObject private var typing")
              && label.contains("@ObservedObject private var feed: MenuBarLabelFeed"), "the menu bar label observes only its feed")
        check(menu.contains("model.objectWillChange") && menu.contains("model.typing.objectWillChange") && menu.contains("refresh: 60"),
              "the feed listens to the app model, the typing model and a minute timer")

        let commands = (try? String(contentsOf: root.appendingPathComponent("Sources/MacMemApp/AppCommands.swift"), encoding: .utf8)) ?? ""
        let rowsView = commands.components(separatedBy: "struct DaydreamRecordingRows: View {").dropFirst().first?.components(separatedBy: "\n}\n").first ?? ""
        check(!rowsView.isEmpty && !rowsView.contains("@ObservedObject var model") && rowsView.contains("@ObservedObject private var rows: DedupedFeed<RecordingRowsInputs>"),
              "the main menu's Recording rows observe only their feed")

        print("perf-1002: " + (fails == 0 ? "all passed" : "\(fails) failed"))
        exit(fails == 0 ? 0 : 1)
    }
}
