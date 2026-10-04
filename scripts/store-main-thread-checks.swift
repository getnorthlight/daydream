// DD-RECIPE: APP
// The recording heartbeat (every 0.5 s on the main thread) redraws nothing when nothing changed (golden test 5,
// perf-store stream, G49). Every write to a @Published value redraws each view watching the model (the menu bar dot,
// the Recording menu), even when the value is the same.
//   A. TypingModel.refresh(frontmostBundle:), run by every heartbeat: ten ticks over an unchanged store publish nothing.
//   B. A real change (typing paused) still publishes, and the ticks after it publish nothing again.
// A private store under DD_CHECK_OUT, no hotkey registrar, no vault (so no Keychain), no permission, nothing recorded.
// MemoryViewModel's part of the heartbeat (refreshCaptureStatus: no store count, no reload after a summary job, no
// write of an unchanged value) opens the Keychain-backed vault at init, so store-main-thread-source-checks.py checks it.
import AppKit
import Combine
import MemoryCore
import MemoryUI

func fail(_ message: String) -> Never {
    fflush(stdout)
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}
@MainActor func expect(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { fail(message()) } }
func pass(_ message: String) { print("PASS: \(message)"); fflush(stdout) }

@main @MainActor struct StoreMainThreadChecks {
    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            FileHandle.standardError.write(Data("FAIL: store-main-thread-checks watchdog expired after 60s\n".utf8))
            exit(2)
        }
        let shared = ["/private/tmp/" + "day" + "dream-", "/tmp/" + "day" + "dream-"]
        guard let outPath = ProcessInfo.processInfo.environment["DD_CHECK_OUT"], outPath.hasPrefix("/"),
              !shared.contains(where: { outPath.hasPrefix($0) }) else {
            fail("DD_CHECK_OUT is not a private output directory; run this check through run-checks.sh")
        }
        let home = URL(fileURLWithPath: outPath, isDirectory: true).appendingPathComponent("store-main-thread-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        let clock = Date(timeIntervalSince1970: 1_790_000_000)
        let typing = TypingModel(now: { clock })
        typing.keyPanel = { nil }
        typing.attach(store, hotkeys: nil)
        typing.refresh(frontmostBundle: "com.apple.Notes")

        // A. Unchanged ticks.
        var published = 0
        let watch = typing.objectWillChange.sink { _ in published += 1 }
        for _ in 0..<10 { typing.refresh(frontmostBundle: "com.apple.Notes") }
        expect(published == 0, "ten heartbeat ticks over an unchanged store published \(published) times (the menu bar and every typing view redrew)")
        pass("ten heartbeat ticks over an unchanged store publish nothing")

        // B. A change publishes; the ticks after it don't.
        let before = typing.policy
        try store.snoozeTyping(minutes: 10, now: clock)
        typing.refresh(frontmostBundle: "com.apple.Notes")
        expect(typing.policy != before && published >= 1, "pausing typing did not reach the model (published \(published))")
        let afterChange = published
        for _ in 0..<10 { typing.refresh(frontmostBundle: "com.apple.Notes") }
        expect(published == afterChange, "the ticks after a change published \(published - afterChange) more times")
        pass("a real change (typing paused) publishes, and the ticks after it publish nothing")
        withExtendedLifetime(watch) {}
        print("store-main-thread-checks passed")
    }
}
