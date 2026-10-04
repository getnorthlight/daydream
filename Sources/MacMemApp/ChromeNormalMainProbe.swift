#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
import Foundation
import AppKit
import SwiftUI
import CoreServices
import Darwin

/// QA only. Runs under MacMemApplication.main with no normal model or unrelated scenes.
/// This is not customer startup and makes no claim about framework-owned preferences.
enum ChromeNormalMainProbeAdmission {
    static let flag = "--normal-main-chrome-metadata"
    static let watermark = "QA normal-main Chrome metadata · customer startup unverified"
    static func requested(_ arguments: [String]) -> Bool { arguments.contains(flag) }
    static func shape(_ arguments: [String], info: [String: Any]) -> Bool {
        guard arguments.count == 4, arguments[1] == "--isolated-interactive-trial",
              arguments[2] == flag, arguments[3].hasPrefix("/"),
              info["DaydreamQAHarness"] as? Bool == true,
              info["MacMemOwnerTyping"] as? Bool == true,
              info["CFBundleIdentifier"] as? String == "com.getnorthlight.daydream" else { return false }
        for key in ["DaydreamDevelopmentTrial", "DaydreamRecordingTrial", "DaydreamFunctionalTrial", "DaydreamPreview", "DaydreamPreviewSample"] {
            if info[key] != nil { return false }
        }
        return true
    }
    struct Request {
        let root: URL
        let runID: String
        let rootDevice: dev_t
        let rootInode: ino_t
        var result: URL { root.appendingPathComponent("result.json") }
    }
    enum Refused: Error { case isolation }
    static func owned(_ url: URL, directory: Bool, mode: mode_t) -> Bool {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_uid == geteuid(),
              (value.st_mode & mode_t(S_IFMT)) == mode_t(directory ? S_IFDIR : S_IFREG),
              (value.st_mode & 0o777) == mode else { return false }
        return true
    }
    static func canonicalRoot(_ root: URL) -> Bool {
        guard let resolved = realpath(root.path, nil) else {return false}
        defer {free(resolved)}
        return String(cString: resolved) == root.path
    }
    static func openOwnedRoot(_ root: URL) throws -> (Int32, stat) {
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {throw Refused.isolation}
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_uid == geteuid(),
              (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (value.st_mode & 0o777) == 0o700 else {close(descriptor);throw Refused.isolation}
        return (descriptor, value)
    }
    static func boundedFile(_ name: String, rootDescriptor: Int32, maxBytes: Int) throws -> Data {
        let descriptor = openat(rootDescriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {throw Refused.isolation}
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {try? handle.close()}
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_uid == geteuid(), before.st_nlink == 1,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), (before.st_mode & 0o777) == 0o600,
              before.st_size >= 0, before.st_size <= maxBytes else {throw Refused.isolation}
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        var after = stat()
        guard data.count == before.st_size, data.count <= maxBytes, fstat(descriptor, &after) == 0,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino, after.st_nlink == 1,
              after.st_size == before.st_size, after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {throw Refused.isolation}
        return data
    }
    static func validate(_ arguments: [String], info: [String: Any]) throws -> Request {
        guard shape(arguments, info: info), geteuid() != 0 else { throw Refused.isolation }
        let file = URL(fileURLWithPath: arguments[3])
        let root = file.deletingLastPathComponent()
        let prefix = "daydream-normal-main-chrome-"
        guard file.lastPathComponent == "request.json", root.deletingLastPathComponent().path == "/private/tmp",
              root.lastPathComponent.hasPrefix(prefix),
              let id = UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))),
              file.path == arguments[3],
              file.path == "/private/tmp/" + prefix + id.uuidString.lowercased() + "/request.json",
              canonicalRoot(root) else {throw Refused.isolation}
        let (descriptor, identity) = try openOwnedRoot(root)
        defer {close(descriptor)}
        var resultInfo = stat()
        guard try boundedFile("TRIAL-ONLY", rootDescriptor: descriptor, maxBytes: 32) == Data("synthetic-only\n".utf8),
              fstatat(descriptor, "result.json", &resultInfo, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else {throw Refused.isolation}
        let data = try boundedFile("request.json", rootDescriptor: descriptor, maxBytes: 1024)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schema", "run_id", "mode"]),
              object["schema"] as? String == "daydream-qa-normal-main-chrome-metadata-v1",
              object["mode"] as? String == "passive-only",
              object["run_id"] as? String == id.uuidString.lowercased() else { throw Refused.isolation }
        return Request(root: root, runID: id.uuidString.lowercased(), rootDevice: identity.st_dev, rootInode: identity.st_ino)
    }

}

struct ChromeNormalMainProbeSnapshot: Codable {
    let runID: String
    let callerPID: Int32
    let callerEUID: UInt32
    let appKitRunning: Bool
    let phase: String
    let chromePID: Int32?
    let chromeCopies: Int
    let signatureVerified: Bool
    let permissionStatus: Int32?
    let requestedPermission: Bool
    let releaseEnabled: Bool
    let permissionStatusSource: String
}

/// Finite public QA metadata only. Every write rechecks the originally admitted directory inode.
@MainActor final class ChromeNormalMainProbeDiagnostics {
    struct Row: Codable {
        let schema: Int
        let runID: String
        let callerPID: Int32
        let callerEUID: UInt32
        let sequence: Int
        let phase: String
        let appKitRunning: Bool
        let acceptedArgumentCount: Int
        let requestedPermission: Bool
    }
    static let phases: Set<String> = ["main-entered", "session-created", "scene-created", "view-task",
        "did-finish-launching", "appkit-ready", "appkit-not-yet-running", "appkit-readiness-deadline",
        "passive-read-started", "result-persisted", "result-persist-refused", "will-terminate", "view-disappeared"]
    private let request: ChromeNormalMainProbeAdmission.Request
    private var seen: Set<String> = []
    init(request: ChromeNormalMainProbeAdmission.Request) { self.request = request }
    func record(_ phase: String, appKitRunning: Bool) throws {
        guard Self.phases.contains(phase) else {throw ChromeNormalMainProbeAdmission.Refused.isolation}
        guard !seen.contains(phase) else {return}
        guard seen.count < Self.phases.count, ChromeNormalMainProbeAdmission.canonicalRoot(request.root) else {throw ChromeNormalMainProbeAdmission.Refused.isolation}
        let (directory, identity) = try ChromeNormalMainProbeAdmission.openOwnedRoot(request.root)
        defer {close(directory)}
        guard identity.st_dev == request.rootDevice, identity.st_ino == request.rootInode else {throw ChromeNormalMainProbeAdmission.Refused.isolation}
        let row = Row(schema: 1, runID: request.runID, callerPID: getpid(), callerEUID: geteuid(),
            sequence: seen.count + 1, phase: phase, appKitRunning: appKitRunning,
            acceptedArgumentCount: 4, requestedPermission: false)
        let data = try JSONEncoder().encode(row)
        guard data.count <= 1024 else {throw ChromeNormalMainProbeAdmission.Refused.isolation}
        let descriptor = openat(directory, "phase-" + phase + ".json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {throw ChromeNormalMainProbeAdmission.Refused.isolation}
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        guard fsync(descriptor) == 0 else {throw ChromeNormalMainProbeAdmission.Refused.isolation}
        try handle.close()
        guard fsync(directory) == 0 else {throw ChromeNormalMainProbeAdmission.Refused.isolation}
        seen.insert(phase)
    }
}

/// One shared session, independent of whether SwiftUI ever presents its window.
/// The real delegate supplies didFinishLaunching; a view task alone cannot admit the read.
@MainActor final class ChromeNormalMainProbeLifecycle {
    private let running: () -> Bool
    private let nextMain: (@escaping () -> Void) -> Void
    private let deadline: (@escaping () -> Void) -> Void
    private let record: (String) throws -> Void
    private let start: () -> Void
    private let stop: () -> Void
    private var finishedLaunching = false
    private var started = false
    private var closed = false
    init(running: @escaping () -> Bool, nextMain: @escaping (@escaping () -> Void) -> Void,
         deadline: @escaping (@escaping () -> Void) -> Void, record: @escaping (String) throws -> Void,
         start: @escaping () -> Void, stop: @escaping () -> Void) {
        self.running = running; self.nextMain = nextMain; self.deadline = deadline
        self.record = record; self.start = start; self.stop = stop
    }
    func didFinishLaunching() {
        guard !closed, !finishedLaunching else {return}
        finishedLaunching = true
        guard note("did-finish-launching") else {return}
        deadline { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.closed, !self.started else {return}
                _ = self.note("appkit-readiness-deadline"); self.close()
            }
        }
        admitRead()
        if !closed && !started {
            guard note("appkit-not-yet-running") else {return}
            nextMain { [weak self] in MainActor.assumeIsolated {self?.admitRead()} }
        }
    }
    func viewTask() {guard !closed else {return}; if note("view-task") {admitRead()} }
    func viewDisappeared() {guard !closed else {return}; _ = note("view-disappeared"); close()}
    func willTerminate() {guard !closed else {return}; _ = note("will-terminate"); close()}
    private func admitRead() {
        guard !closed, finishedLaunching, !started, running() else {return}
        guard note("appkit-ready") else {return}
        // A metadata write may outlive application shutdown. Fence immediately before starting.
        guard !closed, running() else {close(); return}
        started = true; start()
    }
    private func note(_ phase: String) -> Bool {
        do {try record(phase); return true} catch {close(); return false}
    }
    private func close() {guard !closed else {return}; closed = true; stop()}
}
struct ChromeNormalMainProbeEnvironment {
    var running: () -> pid_t?
    var copies: () -> Int
    var verify: (pid_t) -> Bool
    var releaseEnabled: () -> Bool
    var identity: (pid_t) -> String?
    var statusSource: String
    var status: (pid_t) -> OSStatus
    var background: (@escaping () -> Void) -> Void
    var main: (@escaping () -> Void) -> Void
    var mainSnapshot: (() -> Bool) -> Bool
    var deadline: (@escaping () -> Void) -> Void
    var caller: () -> (pid_t, uid_t, Bool)
    static var live: Self {
        #if DEVELOPMENT_SOURCE_CHECKS
        preconditionFailure("Focused QA checks must inject a metadata environment")
        #else
        let production = ChromeAccessEnvironment.live
        return Self(running: production.running, copies: production.copies,
                    verify: production.verify, releaseEnabled: {ChromeEventSender.enabled},
                    identity: {ChromeEventSender.launchIdentity(pid: $0)}, statusSource: "production-preflight",
                    status: production.status,
                    background: production.background, main: production.main,
                    mainSnapshot: { check in Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check) },
                    deadline: { DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: $0) },
                    caller: { (getpid(), geteuid(), NSApp?.isRunning == true) })
        #endif
    }
}
@MainActor final class ChromeNormalMainProbeSession: ObservableObject {
    let request: ChromeNormalMainProbeAdmission.Request
    private let environment: ChromeNormalMainProbeEnvironment
    private let persist: (ChromeNormalMainProbeSnapshot) throws -> Void
    private let diagnostic: (String) throws -> Void
    @Published private(set) var phase = "idle"
    @Published private(set) var status: Int32?
    private var generation = 0
    init(request: ChromeNormalMainProbeAdmission.Request,
         environment: ChromeNormalMainProbeEnvironment = .live,
         persist: ((ChromeNormalMainProbeSnapshot) throws -> Void)? = nil,
         diagnostic: @escaping (String) throws -> Void = { _ in }) {
        self.request = request; self.environment = environment
        self.diagnostic = diagnostic
        self.persist = persist ?? { snapshot in
            guard ChromeNormalMainProbeAdmission.canonicalRoot(request.root) else {throw ChromeNormalMainProbeAdmission.Refused.isolation}
            let (rootDescriptor, identity) = try ChromeNormalMainProbeAdmission.openOwnedRoot(request.root)
            defer {close(rootDescriptor)}
            guard identity.st_dev == request.rootDevice, identity.st_ino == request.rootInode else {throw ChromeNormalMainProbeAdmission.Refused.isolation}
            let data = try JSONEncoder().encode(snapshot)
            let descriptor = openat(rootDescriptor, "result.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw ChromeNormalMainProbeAdmission.Refused.isolation }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data); try handle.close()
        }
    }
    func readOnce() {
        guard phase == "idle" else { return }
        generation += 1; let ticket = generation
        phase = "checking"
        let caller = environment.caller()
        guard caller.2 else {finish(ticket, caller, "appkit-not-running", nil, 0, false, nil); return}
        do {try diagnostic("passive-read-started")} catch {generation += 1; phase = "diagnostic-write-refused"; return}
        let copies = environment.copies()
        guard environment.releaseEnabled() else {finish(ticket, caller, "release-disabled", nil, 0, false, nil); return}
        guard let pid = environment.running() else {
            finish(ticket, caller, "chrome-not-running", nil, copies, false, nil); return
        }
        guard copies == 1 else { finish(ticket, caller, "multiple-chrome-copies", pid, copies, false, nil); return }
        guard let identity = environment.identity(pid) else {finish(ticket, caller, "target-identity-unavailable", pid, copies, false, nil); return}
        environment.deadline { [weak self] in
            MainActor.assumeIsolated { self?.finish(ticket, caller, "deadline", pid, copies, false, nil) }
        }
        let env = environment
        env.background { [weak self] in
            let sameBefore = env.identity(pid) == identity && env.releaseEnabled()
            let verified = sameBefore && env.verify(pid)
            // Verification may outlive the selected process. Fence again before any OS query.
            let sameForStatus = env.mainSnapshot {
                MainActor.assumeIsolated {
                    self?.generation == ticket && self?.phase == "checking" &&
                    env.caller().2 && env.running() == pid && env.copies() == 1 && env.identity(pid) == identity && env.releaseEnabled()
                }
            }
            let sameImmediately = env.identity(pid) == identity && env.releaseEnabled()
            let answer = verified && sameForStatus && sameImmediately ? env.status(pid) : nil
            let sameAfter = env.identity(pid) == identity && env.releaseEnabled()
            env.main {
                MainActor.assumeIsolated {
                    let selected = env.caller().2 && env.running() == pid && env.copies() == 1 && env.identity(pid) == identity && env.releaseEnabled()
                    let stable = sameBefore && sameForStatus && sameImmediately && sameAfter && selected
                    self?.finish(ticket, caller, !stable ? "target-changed" : verified ? "complete" : "unverified-target",
                                 pid, copies, verified && stable, stable ? answer : nil)
                }
            }
        }
    }
    private func finish(_ ticket: Int, _ caller: (pid_t, uid_t, Bool), _ phase: String,
                        _ pid: pid_t?, _ copies: Int, _ verified: Bool, _ answer: OSStatus?) {
        guard generation == ticket, self.phase == "checking" else { return }
        generation += 1
        status = answer; self.phase = phase
        let snapshot = ChromeNormalMainProbeSnapshot(runID: request.runID, callerPID: caller.0, callerEUID: caller.1,
            appKitRunning: caller.2, phase: phase, chromePID: pid, chromeCopies: copies,
            signatureVerified: verified, permissionStatus: answer, requestedPermission: false,
            releaseEnabled: environment.releaseEnabled(),
            permissionStatusSource: answer != nil ? environment.statusSource : phase == "deadline" ? "deadline-in-flight-unknown" : "none")
        do {
            try persist(snapshot)
            do {try diagnostic("result-persisted")} catch {self.phase = "diagnostic-write-refused"}
        } catch {self.phase = "receipt-write-refused"; try? diagnostic("result-persist-refused")}
    }
    func stop() { generation += 1; if phase == "checking" || phase == "idle" { phase = "closed" } }
}
struct ChromeNormalMainProbeView: View {
    @ObservedObject var session: ChromeNormalMainProbeSession
    let lifecycle: ChromeNormalMainProbeLifecycle
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ChromeNormalMainProbeAdmission.watermark).font(.headline)
            Text("Passive permission status only. No permission request or browser content read.")
            Text("State: \(session.phase)")
            if let status = session.status { Text("Automation status: \(status)") }
        }.padding(24).frame(minWidth: 420)
            .task { lifecycle.viewTask() }
            .onDisappear { lifecycle.viewDisappeared() }
    }
}
#if !DEVELOPMENT_SOURCE_CHECKS
/// Distinct QA SwiftUI App Scene. Native MacMemApplication.main dispatches here before creating
/// its normal StateObject or scenes. Customer full startup remains unverified.
@MainActor enum ChromeNormalMainProbeRuntime {
    private(set) static var session: ChromeNormalMainProbeSession?
    private(set) static var lifecycle: ChromeNormalMainProbeLifecycle?
    private(set) static var diagnostics: ChromeNormalMainProbeDiagnostics?
    static func prepare(arguments: [String], info: [String: Any]) -> Bool {
        guard session == nil, lifecycle == nil else {return false}
        do {
            let request = try ChromeNormalMainProbeAdmission.validate(arguments, info: info)
            let diagnostics = ChromeNormalMainProbeDiagnostics(request: request)
            let record: (String) throws -> Void = {try diagnostics.record($0, appKitRunning: NSApp?.isRunning == true)}
            try record("main-entered")
            let session = ChromeNormalMainProbeSession(request: request, diagnostic: record)
            try record("session-created")
            let lifecycle = ChromeNormalMainProbeLifecycle(running: {NSApp?.isRunning == true},
                nextMain: {DispatchQueue.main.async(execute: $0)},
                deadline: {DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: $0)},
                record: record, start: {session.readOnce()}, stop: {session.stop()})
            self.session = session; self.lifecycle = lifecycle; self.diagnostics = diagnostics
            return true
        } catch {return false}
    }
}
@MainActor final class ChromeNormalMainProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {ChromeNormalMainProbeRuntime.lifecycle?.didFinishLaunching()}
    func applicationWillTerminate(_ notification: Notification) {ChromeNormalMainProbeRuntime.lifecycle?.willTerminate()}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {false}
}
struct ChromeNormalMainProbeApplication: App {
    @NSApplicationDelegateAdaptor(ChromeNormalMainProbeDelegate.self) private var delegate
    init() {
        do {try ChromeNormalMainProbeRuntime.diagnostics?.record("scene-created", appKitRunning: NSApp?.isRunning == true)}
        catch {ChromeNormalMainProbeRuntime.lifecycle?.willTerminate()}
    }
    var body: some Scene {
        WindowGroup("QA normal-main Chrome metadata", id: "qa-normal-chrome") {
            if let probe = ChromeNormalMainProbeRuntime.session, let lifecycle = ChromeNormalMainProbeRuntime.lifecycle {
                ChromeNormalMainProbeView(session: probe, lifecycle: lifecycle)
            } else {Text("QA isolation unavailable.").padding()}
        }.windowResizability(.contentSize).commandsRemoved()
    }
}
@MainActor func daydreamDefaultSwiftUIAppMain<A: App>(_ type: A.Type) {type.main()}
#endif

#endif
