import AppKit
import MemoryCore

/// One DayDream at a time (gold r2). A copy opened while another one runs brings that one forward and exits before it
/// opens anything, saying nothing: the running copy is the one the person sees. The exception is a running copy in the
/// download window, which records and saves nothing: a copy that can record opens instead, and the download-window copy
/// steps aside for it (`MemoryViewModel.otherCopyOpened`). Only when the running copy can't be brought forward does this
/// copy stay, with one short line ("DayDream is already open."), and it opens the history by itself once the other copy
/// lets go of it (`MemoryViewModel.anotherCopyHoldsHistory`).
struct OtherCopy {
    /// A DayDream that was running before this one.
    struct Running: Equatable {
        var pid: pid_t
        var bundleURL: URL?
        var location: LaunchLocation
    }
    /// The DayDream (same bundle identifier) that was running first, or nil.
    var find: () -> Running?
    /// Brings it forward with its window, as clicking its Dock icon does. False when it couldn't be reached.
    var bringForward: (Running) -> Bool
    /// Ends this copy quietly, before anything was opened.
    var leave: () -> Void
    /// This copy, in the download window, quits for a copy that can record.
    var stepAside: () -> Void
    /// Where a DayDream opened after this one runs from, when one of those can record, or nil. The model asks once when
    /// it is made (`MemoryViewModel.otherCopyOpened`): launch can prepare the history for seconds before the model
    /// exists (HistoryPreparation, off the main thread), and a copy opened meanwhile was never seen by its watch for one
    /// (gold/int round 2).
    var openedLater: () -> LaunchLocation? = { nil }

    enum Decision: Equatable { case open, handOff }
    /// `mine`: where this copy runs from.
    static func decide(mine: LaunchLocation, other: Running?) -> Decision {
        guard let other else { return .open }
        // A copy in the download window steps aside for one that can record.
        if other.location.blocksRecording && !mine.blocksRecording { return .open }
        return .handOff
    }

    /// At launch, before the history opens (DaydreamLaunchSession): true when this copy handed off to the running one
    /// and must open nothing.
    @MainActor static func handedOff(mine: LaunchLocation) -> Bool {
        let seam = current
        guard let other = seam.find(), decide(mine: mine, other: other) == .handOff else { return false }
        guard seam.bringForward(other) else {
            RecordingLog.note("Another DayDream is open and couldn't be brought forward.")
            return false
        }
        RecordingLog.note("Another DayDream is open; brought it forward and closed this one.")
        seam.leave()
        return true
    }

    /// Check builds find no other copy and never leave or quit.
    #if DEVELOPMENT_SOURCE_CHECKS
    static var current = OtherCopy.inert
    #else
    static var current = OtherCopy.live
    #endif
    static let inert = OtherCopy(find: { nil }, bringForward: { _ in false }, leave: {}, stepAside: {})
    static let live = OtherCopy(find: { runningFirst() }, bringForward: { bringForwardLive($0) }, leave: { exit(0) },
                                stepAside: { AppQuit.quit() }, openedLater: { recordingCopyOpenedLater() })

    /// Only the installed DayDream app looks (never a development binary, or a copy pointed at another history).
    private static func runningFirst() -> Running? {
        guard let id = Bundle.main.bundleIdentifier, id == DaydreamIdentity.bundleID,
              (ProcessInfo.processInfo.environment["MAC_MEM_HOME"] ?? "").isEmpty else { return nil }
        let me = NSRunningApplication.current
        let mine = me.launchDate ?? Date()
        // Only a copy that was running first: of two opened together, the later one leaves, never both.
        let earlier = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { other in
            guard other.processIdentifier != me.processIdentifier, !other.isTerminated else { return false }
            guard let at = other.launchDate else { return true }
            return at < mine || (at == mine && other.processIdentifier < me.processIdentifier)
        }
        guard let first = earlier.min(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }) else { return nil }
        return Running(pid: first.processIdentifier, bundleURL: first.bundleURL,
                       location: first.bundleURL.map { LaunchLocation.read(bundleURL: $0) } ?? .notAnApp)
    }
    /// The installed DayDream opened after this one (the other side of `runningFirst`'s order), when it can record.
    private static func recordingCopyOpenedLater() -> LaunchLocation? {
        guard let id = Bundle.main.bundleIdentifier, id == DaydreamIdentity.bundleID,
              (ProcessInfo.processInfo.environment["MAC_MEM_HOME"] ?? "").isEmpty else { return nil }
        let me = NSRunningApplication.current
        let mine = me.launchDate ?? Date()
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
            guard other.processIdentifier != me.processIdentifier, !other.isTerminated, let at = other.launchDate,
                  at > mine || (at == mine && other.processIdentifier > me.processIdentifier), let url = other.bundleURL else { continue }
            let location = LaunchLocation.read(bundleURL: url)
            if !location.blocksRecording && location != .notAnApp { return location }
        }
        return nil
    }

    /// LaunchServices opens the running copy as clicking its Dock icon does (it comes forward with its window). It never
    /// starts another one: an answer naming any other process (the copy quit meanwhile) counts as not reached.
    private static func bringForwardLive(_ other: Running) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: other.pid), !app.isTerminated else { return false }
        guard let url = other.bundleURL, url.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL else {
            return app.activate(options: [.activateAllWindows])
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        let reply = OpenReply()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { opened, _ in reply.answer(opened?.processIdentifier) }
        guard let answer = reply.wait(seconds: 3) else { return false }
        return answer == other.pid
    }
}

/// The open's answer, handed from LaunchServices' queue to launch (which waits for it, briefly, before anything opens).
private final class OpenReply: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var pid: pid_t?
    func answer(_ value: pid_t?) { lock.lock(); pid = value; lock.unlock(); done.signal() }
    /// nil when no answer came in time; otherwise the process that was opened (nil inside: none).
    func wait(seconds: Double) -> pid_t?? {
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return .some(pid)
    }
}
