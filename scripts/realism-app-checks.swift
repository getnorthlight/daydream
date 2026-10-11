// DD-RECIPE: APP
// Realism checks (test-suite phase 2): the owner's own bugs, replayed where DayDream meets macOS, on the REAL app code
// (every Sources/MacMemApp file through scripts/realism-seams.py, the owner objects and both shipped flags). One binary;
// the first argument picks the section, and each section is its own runner step with its own scratch HOME:
//
//   skip-app        bug 2 (0.1.7, Noah): real third-party bundle IDs (underscores, spaces, odd characters) are listed by
//                   the picker, saved by setup's Apps page and by Exclude App, and are still skipped after a reload;
//                   "One of the apps in this change can't be skipped" never appears.
//   writer-binding  bug 4: "This Mac only" reaches the binding WriterIntegration builds (the writer on this Mac reads the
//                   typed words; the cloud nothing), and the reverse choice (Cloud) too.
//   setup-poll      bug 5: Accessibility (and Input Monitoring) turned on while setup is open shows Allowed on its card
//                   within the page's poll, with no click and no app switch.
//   setup-start     bug 12: Start Recording in every setup state, with each injected permission and store problem,
//                   either changes something or shows one plain-words line with exactly one button that fixes it.
//   tcc-states      bug 3's screen half and the TCC matrix: 5 injected states (off, on, on in System Settings but not
//                   effective, granted after launch and needs a reopen, revoked while recording) x 3 permissions
//                   (Accessibility, Input Monitoring, Chrome automation): plain words, and exactly one fixing button
//                   where something needs fixing (none where nothing does).
//   drag-caches     bug 6: five drags of the DayDream card in a row write nothing under the scratch HOME's
//                   Library/Caches, and what is dragged is the installed app's own URL: first through the drag helper,
//                   then pressed and dragged on setup's own card (its press view), as a person does.
//   window-layouts  where setup's window, System Settings and the Chrome guide go on 6 injected display layouts.
//
// Every permission state is INJECTED through the check seams (`DaydreamOnboarding.readPermissions`,
// `MemoryViewModel.permissionRead/permissionsGranted`, the page's read closures, `ChromeAccessEnvironment`): nothing here
// reads or changes a real permission, asks macOS anything, opens System Settings, records, downloads or goes online.
// Windows are never ordered on screen (hosting windows stay hidden; NSApp's activation policy is .prohibited). Scratch
// HOME, CFFIXED_USER_HOME and DD_CHECK_OUT only; histories are synthetic.
import AppKit
import Combine
import CoreIntegration
import MemoryCore
import MemoryUI
import ObjectiveC
import SwiftUI
import WriterBackend

// RealismReview (what setup's last page offered after its last draw) is added to the app sources by realism-seams.py.

// MARK: Report

@MainActor enum Report {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("PASS " + label) } else { failed += 1; let d = detail(); print("FAIL " + label + (d.isEmpty ? "" : "  [" + d + "]")) }
        fflush(stdout)
    }
}
@MainActor func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") { Report.check(ok, label, detail()) }
func stop(_ message: String) -> Never { fflush(stdout); FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(2) }
@MainActor func pump(_ seconds: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
@MainActor @discardableResult func waitFor(_ seconds: Double, _ done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { pump(0.02) }
    return done()
}
func ms(_ seconds: Double) -> String { "\(Int((seconds * 1000).rounded())) ms" }

/// Plain words: a sentence a person reads, never an error code, a status number, a type name or a developer word.
func plainWords(_ text: String?) -> Bool {
    guard let text, !text.isEmpty, text.count <= 220 else { return false }
    let banned = ["Error", "error:", "OSStatus", "nil", "Optional(", "NSError", "kTCC", "TCC", "errAE", "domain=", "code=", "Exception", "\\"]
    if banned.contains(where: text.contains) { return false }
    if text.range(of: #"-?\d{3,}"#, options: .regularExpression) != nil { return false }
    if text.range(of: #"[a-z][A-Z][a-z]+[A-Z]"#, options: .regularExpression) != nil { return false }  // camelCase identifiers
    return text.first?.isUppercase == true || text.hasPrefix("macOS ")  // a sentence starts with a capital (or macOS)
}

// MARK: Harness

/// The scratch HOME rule every section runs under: HOME and CFFIXED_USER_HOME one scratch folder (never the person's own
/// home or anything in it), DD_CHECK_OUT a private folder, Application Support inside the scratch HOME.
@MainActor func guardScratch() -> (home: URL, out: URL) {
    let env = ProcessInfo.processInfo.environment
    let shared = ["/private/tmp/" + "day" + "dream-", "/tmp/" + "day" + "dream-"]
    guard let outPath = env["DD_CHECK_OUT"], outPath.hasPrefix("/"), !shared.contains(where: { outPath.hasPrefix($0) }) else {
        stop("DD_CHECK_OUT must be a private scratch folder (run through runner-1001/steps.d/realism.sh)")
    }
    let realHome = URL(fileURLWithPath: getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "/Users/" + NSUserName())
        .resolvingSymlinksInPath().path
    guard let home = env["CFFIXED_USER_HOME"], env["HOME"] == home, home.hasPrefix("/"),
          case let scratch = URL(fileURLWithPath: home).resolvingSymlinksInPath().path, scratch != "/",
          !(realHome + "/").hasPrefix(scratch + "/"), scratch != realHome, !(scratch + "/").hasPrefix(realHome + "/Library/") else {
        stop("HOME and CFFIXED_USER_HOME must be the same scratch folder, not your own home")
    }
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath().path
    guard appSupport.hasPrefix(URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
        stop("REFUSING: Application Support resolves to \(appSupport), outside the scratch HOME")
    }
    let out = URL(fileURLWithPath: outPath, isDirectory: true).appendingPathComponent("realism-" + UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return (URL(fileURLWithPath: home, isDirectory: true), out)
}

/// Launch-intent and relaunch defaults in memory only.
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init(inMemory: Void = ()) { super.init(suiteName: nil)! }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) } }
    override func removeObject(forKey defaultName: String) { values.removeValue(forKey: defaultName) }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { values[defaultName] as? [String: Any] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func bool(forKey defaultName: String) -> Bool { (values[defaultName] as? NSNumber)?.boolValue ?? false }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func double(forKey defaultName: String) -> Double { (values[defaultName] as? NSNumber)?.doubleValue ?? 0 }
    override func set(_ value: Double, forKey defaultName: String) { values[defaultName] = value }
    override func integer(forKey defaultName: String) -> Int { (values[defaultName] as? NSNumber)?.intValue ?? 0 }
    override func set(_ value: Int, forKey defaultName: String) { values[defaultName] = value }
}

/// The injected permission reads (both preflight reads, and setup's own): nothing reads macOS.
enum Perm {
    nonisolated(unsafe) static var accessibility = true, inputMonitoring = true
    @MainActor static func install() {
        MemoryViewModel.permissionsGranted = { Perm.accessibility && Perm.inputMonitoring }
        MemoryViewModel.permissionRead = { PermissionSnapshot(accessibility: Perm.accessibility, inputMonitoring: Perm.inputMonitoring) }
        DaydreamOnboarding.readPermissions = { (Perm.accessibility, Perm.inputMonitoring) }
    }
    static func set(_ a: Bool, _ i: Bool) { accessibility = a; inputMonitoring = i }
}

/// The two permission cards, by the names their elements use (`open.accessibility`, `open.inputMonitoring`).
enum CardPermission: String, CaseIterable {
    case accessibility, inputMonitoring
    var title: String { self == .accessibility ? "Accessibility" : "Input Monitoring" }
}

/// Google Chrome as the checks stand it in: installed, running as a fake pid, verified, and answering `status`.
final class FakeChrome: @unchecked Sendable {
    var status: OSStatus = 0
    var running = true
    var asks = 0
    var environment: ChromeAccessEnvironment {
        var env = ChromeAccessEnvironment(running: { self.running ? 4242 : nil }, verify: { _ in true }, status: { _ in self.status },
                                          ask: { _ in self.asks += 1; return self.status }, background: { $0() }, main: { $0() },
                                          onNextChromeActivation: { _ in })
        env.installed = { true }
        return env
    }
}

/// Fake lock, console and timers for the model (FakeWake in permission-flash-checks).
@MainActor final class FakeWake {
    var pending: [(due: Date, work: () -> Void)] = []
    var system: WakeSystem {
        WakeSystem(screenLocked: { false }, onConsole: { true },
                   after: { delay, work in self.pending.append((Date().addingTimeInterval(delay), work)) }, now: { Date() })
    }
    func runDue() {
        let now = Date(), due = pending.filter { $0.due <= now }
        pending.removeAll { $0.due <= now }
        for job in due { job.work() }
    }
}

@MainActor final class Opened {
    let model: MemoryViewModel, wake = FakeWake(), chrome = FakeChrome()
    let memory: URL
    init(model: MemoryViewModel, memory: URL) { self.model = model; self.memory = memory }
    /// Real time passes; what the model set to run later runs once due.
    func run(_ seconds: Double, until done: (() -> Bool)? = nil) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            wake.runDue()
            if model.recording { model.coordinator?.reconcileResume() }
            if done?() == true { return }
            pump(0.02)
        }
    }
}

/// A production MemoryViewModel on its own new synthetic history (MAC_MEM_HOME in the scratch output).
@MainActor func openModel(_ root: URL, _ name: String) -> Opened {
    let memory = root.appendingPathComponent(name + "-" + UUID().uuidString.prefix(8), isDirectory: true)
    try? FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    setenv("MAC_MEM_HOME", memory.path, 1)
    let model = MemoryViewModel()
    let o = Opened(model: model, memory: memory)
    RealismAppChecks.Current.model = model
    model.wakeSystem = o.wake.system
    model.chromeAccessEnvironment = o.chrome.environment
    guard waitFor(20, { model.preferencesAvailable && !model.historyOpening }) else { stop("\(name): the synthetic history did not open: \(model.status)") }
    _ = waitFor(10, { !model.history.busy && !model.noteWriter.busy })
    o.run(0.15)
    return o
}

/// A hidden window (never ordered on screen) hosting `view`, and the page's element frames (`PermissionPageElements`).
@MainActor final class Hosted {
    let window: NSWindow
    let host: NSHostingView<AnyView>
    var elements: [String: CGRect] = [:]
    init<V: View>(_ view: V, requests: PermissionRequestActions? = nil, size: NSSize = NSSize(width: 660, height: 632)) {
        window = KeyWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: AnyView(EmptyView()))
        let box = self
        host.rootView = AnyView(view.environment(\.daydreamPermissionRequests, requests).frame(width: size.width, height: size.height)
            .onPreferenceChange(PermissionPageElements.self) { frames in MainActor.assumeIsolated { box.elements = frames } })
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        settle(0.3)
    }
    func settle(_ seconds: Double = 0.2) {
        let end = Date().addingTimeInterval(seconds)
        repeat { host.layoutSubtreeIfNeeded(); pump(0.02) } while Date() < end
    }
    /// The page's buttons by their element names (Open System Settings, Ask again, Allow, Turn On, Quit & Reopen, ...).
    var buttons: [String] {
        elements.keys.filter { $0.hasPrefix("open.") || $0.hasPrefix("askagain.") || $0.hasPrefix("allow.") || $0.hasPrefix("pages.")
            || $0 == "quitAndReopen" || $0 == "recovery.quitAndReopen" || $0 == "reAdd" }.sorted()
    }
    /// Return: the page's main button (`.keyboardShortcut(.defaultAction)`).
    func pressReturn() {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                       isARepeat: false, keyCode: 36) else { stop("no Return event") }
        _ = window.performKeyEquivalent(with: e)
        settle(0.3)
    }
    func close() { window.contentView = nil; window.close(); pump(0.05) }
}
/// Drawn as the key window (switches and buttons in their active colors), never ordered on screen.
final class KeyWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// A synthetic DayDream.app in the scratch HOME's Applications (Info.plist and a placeholder executable, 2 MB, so a
/// copy of it would be seen).
func fixtureApp(_ home: URL, name: String = "DayDream", id: String = "com.getnorthlight.daydream") -> URL {
    let app = home.appendingPathComponent("Applications/\(name).app", isDirectory: true)
    let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try? FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleExecutable": name, "CFBundlePackageType": "APPL"]
    try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    let exe = macos.appendingPathComponent(name)
    if !FileManager.default.fileExists(atPath: exe.path) { try? Data(repeating: 0x2a, count: 2 << 20).write(to: exe) }
    return app
}

// MARK: Main

@main @MainActor struct RealismAppChecks {
    static var home = URL(fileURLWithPath: "/"), out = URL(fileURLWithPath: "/")

    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let args = CommandLine.arguments
        guard args.count >= 2 else { stop("usage: realism-app-checks SECTION [FIXTURE]") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { FileHandle.standardError.write(Data("FAIL: realism-app-checks timed out\n".utf8)); exit(2) }
        (home, out) = guardScratch()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        // The seams every section shares: nothing records for real, asks, relaunches or downloads.
        Perm.install()
        MemoryViewModel.readLaunchLocation = { .applications }
        MemoryViewModel.canReopen = { false }
        MemoryViewModel.performAutoRelaunch = { _ in false }
        MemoryViewModel.autoRelaunchDefaults = MemoryDefaults()
        MemoryViewModel.launchIntentDefaults = MemoryDefaults()
        SummaryControls.current = .recording
        let section = args[1]
        switch section {
        case "skip-app": try await skipApp(args.count > 2 ? args[2] : "scripts/fixtures/realism/skip-app-bundle-ids.tsv")
        case "writer-binding": try await writerBinding()
        case "setup-poll": setupPoll()
        case "setup-start": setupStart()
        case "tcc-states": tccStates()
        case "drag-caches": dragCaches()
        case "window-layouts": try windowLayouts(args.count > 2 ? args[2] : "scripts/fixtures/realism/display-layouts.json")
        default: stop("unknown section \(section)")
        }
        try? FileManager.default.removeItem(at: out)
        print("realism \(section): \(Report.passed) passed, \(Report.failed) failed. Injected states only; nothing asked, recorded or sent.")
        fflush(stdout)
        exit(Report.failed == 0 ? 0 : 1)
    }

    // MARK: bug 2: skip any app

    static func skipApp(_ fixture: String) async throws {
        let rows = try String(contentsOfFile: fixture, encoding: .utf8).split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }.dropFirst().map { $0.components(separatedBy: "\t") }
        let ids = rows.map { $0[0] }
        let underscore = ids.filter { $0.contains("_") }.count, odd = ids.filter { $0.contains(" ") || $0.contains("+") || !$0.allSatisfy(\.isASCII) }.count
        let installed = rows.filter { $0.count > 2 && $0[2].hasPrefix("installed") && !$0[0].hasPrefix("com.apple.") }.count
        check(ids.count >= 12 && underscore >= 3 && odd >= 2 && installed >= 12,
              "bug2 fixture: \(ids.count) bundle IDs, \(installed) from installed third-party apps, \(underscore) with underscores, \(odd) with spaces or other characters")
        // The picker: the apps as installed (Info.plist only), found by the catalog setup and Settings use.
        let apps = home.appendingPathComponent("Applications", isDirectory: true)
        for row in rows { _ = fixtureApp(home, name: row[1], id: row[0]) }
        let listed = Set(LocalApp.catalog(roots: [apps]).map(\.id))
        // Setup's Apps page: pick every app, Continue saves them (saveOnboardingPreferences), then a reload.
        let setupModel = openModel(out, "skip-setup")
        let picked = Set(ids)
        setupModel.model.saveOnboardingPreferences(excluded: picked, typedText: setupModel.model.captureText)
        setupModel.run(3) { !setupModel.model.preferencesUnresolved }
        let setupProblem = setupModel.model.preferenceProblem?.text
        setupModel.model.reloadPreferences()
        setupModel.run(0.3)
        let afterSetup = Set(setupModel.model.blockedApps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let storedSetup = Set((try? MemoryStore(home: setupModel.memory, writable: false, automaticallySyncSearch: false).policy().blockedApps) ?? [])
        setupModel.model.stopCapture()
        // Exclude App (a moment's menu, Settings): one app at a time, then a reload.
        let menuModel = openModel(out, "skip-menu")
        var menuErrors: [String: String] = [:]
        for id in ids {
            do { try await menuModel.model.excludeAppSaved(id) } catch { menuErrors[id] = "\(error)" }
        }
        menuModel.model.reloadPreferences()
        menuModel.run(0.3)
        let afterMenu = Set(menuModel.model.blockedApps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let storedMenu = Set((try? MemoryStore(home: menuModel.memory, writable: false, automaticallySyncSearch: false).policy().blockedApps) ?? [])
        let noSkipLine = "One of the apps in this change can't be skipped"
        for id in ids {
            check(listed.contains(id), "bug2 skip-app \(id): the picker lists it")
            check(setupProblem == nil && afterSetup.contains(id) && storedSetup.contains(id),
                  "bug2 skip-app \(id): picked on setup's Apps page, saved, still skipped after a reload", "problem: \(setupProblem ?? "none")")
            check(menuErrors[id] == nil && afterMenu.contains(id) && storedMenu.contains(id),
                  "bug2 skip-app \(id): Exclude App saves it and it is still skipped after a reload", menuErrors[id] ?? "not in the saved list")
        }
        check(!(setupProblem ?? "").contains(noSkipLine) && !menuErrors.values.contains { $0.contains(noSkipLine) },
              "bug2 skip-app: \"\(noSkipLine)\" never appears for an installed app")
        menuModel.model.stopCapture()
    }

    // MARK: bug 4: This Mac only reaches the writer

    static func writerBinding() async throws {
        actor Keys: WriterSecureKeyStore {
            var value = ""
            func readSecret() async throws -> String { value }
            func saveSecret(_ value: String) async throws { self.value = value }
            func removeSecret() async throws { value = "" }
        }
        let storeHome = out.appendingPathComponent("writer-store", isDirectory: true)
        let store = try MemoryStore(home: storeHome, writable: true, automaticallySyncSearch: false)
        var policy = try store.policy(); policy.captureText = true; try store.updatePolicy(policy)
        try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore())); try store.setUpTypedVault(); try store.acceptSafeTyping()
        let words = "move the standup to thursday zzqrealismwords"
        let at = Date()
        _ = try store.ingest(Evidence(id: "realism-window", at: iso(at.addingTimeInterval(-0.2)), kind: "window.changed", app: "Notes",
                                      bundle: "com.apple.Notes", title: "Standup", synthetic: true))
        _ = try store.ingest(Evidence(id: "realism-typed", at: iso(at), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes",
                                      title: "Standup", text: words, synthetic: true))
        let writer = WriterIntegration(modelRoot: out.appendingPathComponent("absent-model"), keyStore: Keys(),
                                       send: { _ in throw URLError(.notConnectedToInternet) })
        writer.configure(store: store)
        for _ in 0..<250 where writer.busy { try await Task.sleep(nanoseconds: 20_000_000) }
        let target = WriterTarget(kind: .day, day: try DayScope.key(at, timezone: "UTC"), timezone: "UTC")
        func reads(_ port: CoreWriterPort) async -> Bool {
            guard let prepared = try? await port.prepare(target) else { return false }
            return prepared.actions.contains { $0.id == "realism-typed" && $0.description.contains("zzqrealismwords") }
        }
        guard let live = writer.coreBinding else { check(false, "bug4 WriterIntegration built a binding in configure(store:)"); return }
        // "This Mac only".
        try store.setSummaryWriter("local")
        let liveLocal = await reads(live.port()), liveCloud = await reads(live.port(audience: .cloud))
        let made = WriterIntegration.makeCoreBinding(store: store)
        let madeLocal = await reads(made.port())
        check(liveLocal, "bug4 This Mac only: the binding WriterIntegration built gives the writer on this Mac the typed words")
        check(madeLocal, "bug4 This Mac only: WriterIntegration.makeCoreBinding (what configure wires) gives the writer on this Mac the typed words")
        check(!liveCloud, "bug4 This Mac only: the cloud port gets no typed words")
        // The reverse: Cloud chosen (its notice accepted), then back to This Mac only.
        try store.setSummaryWriter("cloud")
        let cloudLocal = await reads(live.port()), cloudCloud = await reads(live.port(audience: .cloud))
        check(cloudLocal && cloudCloud, "bug4 Cloud chosen: the writer on this Mac and the cloud port both get the typed words",
              "local \(cloudLocal), cloud \(cloudCloud)")
        try store.setSummaryWriter("local")
        let backLocal = await reads(live.port()), backCloud = await reads(live.port(audience: .cloud))
        check(backLocal && !backCloud, "bug4 back to This Mac only: the writer on this Mac reads the words again, the cloud nothing",
              "local \(backLocal), cloud \(backCloud)")
        try store.setSummaryWriter("off")
        let offCloud = await reads(live.port(audience: .cloud))
        check(!offCloud, "bug4 summaries off: the cloud port gets no typed words")
        await writer.shutdown()
    }

    // MARK: bug 5: a permission turned on while setup is open shows Allowed by itself

    /// The page's poll is 2 s, plus its settle read; 3 s is the bound a person waits.
    static let pollBound = 3.0

    static func setupPoll() {
        let appURL = fixtureApp(home)
        // 1. Setup's card (as setup draws it: embedded, side by side) on its own, Accessibility then Input Monitoring.
        for permission in CardPermission.allCases {
            final class Reads { var a = false, i = false, reported: [(Bool, Bool)] = [] }
            let reads = Reads()
            if permission == .inputMonitoring { reads.a = true }
            let view = PermissionGrantView(enabled: true, appURL: appURL, readAccessibility: { reads.a }, readInputMonitoring: { reads.i },
                                           embedded: true, showsRelaunchRow: false, known: PermissionSnapshot(), allowedBefore: false,
                                           onStatusChange: { reads.reported.append(($0, $1)) }, sideBySide: true)
            let page = Hosted(view, requests: PermissionRequestActions(quitAndReopen: nil, inputMonitoringAtLaunch: true))
            let key = "open." + permission.rawValue
            _ = waitFor(2) { page.host.layoutSubtreeIfNeeded(); return page.elements[key] != nil }
            check(page.elements[key] != nil, "bug5 setup-poll harness: \(permission.title) starts off (its Open System Settings button drawn)", "\(page.elements.keys.sorted())")
            let t0 = Date()
            if permission == .accessibility { reads.a = true } else { reads.i = true }
            // No click, no notification, no app switch: only time passes.
            let shown = waitFor(pollBound) { page.host.layoutSubtreeIfNeeded(); return page.elements[key] == nil && reads.reported.last.map { permission == .accessibility ? $0.0 : $0.1 } == true }
            check(shown, "bug5 setup card: \(permission.title) turned on while setup is open shows Allowed within \(Int(pollBound)) s with no click (\(ms(Date().timeIntervalSince(t0))))",
                  "buttons \(page.buttons), reports \(reads.reported.count)")
            page.close()
        }
        // 1b. The same card inside a parent that redraws every second (as setup does: its own reads, the model's status).
        do {
            final class Reads { var a = false }
            let reads = Reads()
            struct Redrawing: View {
                let reads: Reads
                let appURL: URL
                @State private var tick = 0
                private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
                var body: some View {
                    VStack {
                        Text("\(tick)").opacity(0)
                        PermissionGrantView(enabled: true, appURL: appURL, readAccessibility: { reads.a }, readInputMonitoring: { false },
                                            embedded: true, showsRelaunchRow: false, known: PermissionSnapshot(), allowedBefore: false, sideBySide: true)
                    }
                    .onReceive(clock) { _ in tick += 1 }
                }
            }
            let page = Hosted(Redrawing(reads: reads, appURL: appURL), requests: PermissionRequestActions(quitAndReopen: nil, inputMonitoringAtLaunch: true))
            _ = waitFor(2) { page.host.layoutSubtreeIfNeeded(); return page.elements["open.accessibility"] != nil }
            let t0 = Date()
            reads.a = true
            let shown = waitFor(pollBound) { page.host.layoutSubtreeIfNeeded(); return page.elements["open.accessibility"] == nil }
            let took = Date().timeIntervalSince(t0)
            var later = ""
            if !shown {
                let shownLater = waitFor(12) { page.host.layoutSubtreeIfNeeded(); return page.elements["open.accessibility"] == nil }
                later = shownLater ? "Allowed only after \(ms(Date().timeIntervalSince(t0)))" : "still not Allowed after \(ms(Date().timeIntervalSince(t0)))"
            }
            check(shown, "bug5 setup card in a parent that redraws every second: Accessibility shows Allowed within \(Int(pollBound)) s, no click (\(ms(took)))", later)
            page.close()
        }
        // 2. The real setup window: a first setup on Permissions; Accessibility turned on in System Settings meanwhile.
        UserDefaults.standard.removeObject(forKey: DaydreamSetupVersion.key)
        UserDefaults.standard.set(false, forKey: MemoryViewModel.setupCompletedKey)
        Perm.set(false, false)
        let o = openModel(out, "poll-setup")
        let setup = Hosted(DaydreamOnboarding(model: o.model), requests: PermissionRequestActions(quitAndReopen: nil, inputMonitoringAtLaunch: false))
        _ = waitFor(3) { setup.host.layoutSubtreeIfNeeded(); return setup.elements["open.accessibility"] != nil }
        check(DaydreamOnboarding.drawnForChecks?.page == .permissions && setup.elements["open.accessibility"] != nil,
              "bug5 setup-poll harness: a first setup opens on Permissions with Accessibility off", "\(setup.elements.keys.sorted())")
        let t0 = Date()
        Perm.set(true, false)
        let allowed = waitFor(pollBound) { o.wake.runDue(); setup.host.layoutSubtreeIfNeeded(); return setup.elements["open.accessibility"] == nil }
        let took = Date().timeIntervalSince(t0)
        var later = "", buttonsThen = setup.buttons
        if !allowed {
            // How long it really takes, for the report (no click, no notification): up to 12 s more.
            let shownLater = waitFor(12) { o.wake.runDue(); setup.host.layoutSubtreeIfNeeded(); return setup.elements["open.accessibility"] == nil }
            later = shownLater ? "; Allowed only after \(ms(Date().timeIntervalSince(t0)))" : "; still not Allowed after \(ms(Date().timeIntervalSince(t0)))"
            if !shownLater { buttonsThen = setup.buttons }
        }
        check(allowed && setup.elements["open.inputMonitoring"] != nil && DaydreamOnboarding.drawnForChecks?.page == .permissions,
              "bug5 setup window: Accessibility allowed in System Settings shows Allowed on setup's card within \(Int(pollBound)) s, no click (\(ms(took)))",
              "buttons \(buttonsThen)\(later)")
        setup.close()
        Perm.set(true, true)
    }

    // MARK: bug 12: Start Recording never does nothing

    /// One setup, walked to its last page with everything fine, then `inject` (the state), then Start Recording (Return).
    enum Outcome: String { case changes = "changes state", says = "says why, with one fixing button" }
    enum Current { nonisolated(unsafe) static weak var model: MemoryViewModel? }

    /// One setup, walked to its last page with everything fine (or left where it opens: `walk` false), then `inject` (the
    /// state), then its main button (Return). `want`: what must happen; never nothing.
    static func startCase(_ name: String, want: Outcome, walk: Bool = true, launch: LaunchLocation = .applications,
                          requests: PermissionRequestActions? = nil, inject: (Opened) -> Void, expect: String) {
        UserDefaults.standard.removeObject(forKey: DaydreamSetupVersion.key)
        UserDefaults.standard.set(false, forKey: MemoryViewModel.setupCompletedKey)
        MemoryViewModel.readLaunchLocation = { launch }
        defer { MemoryViewModel.readLaunchLocation = { .applications } }
        Perm.set(true, true)
        let o = openModel(out, "start-" + name.replacingOccurrences(of: " ", with: "-"))
        Current.model = o.model
        let reqs = requests ?? PermissionRequestActions(quitAndReopen: nil, inputMonitoringAtLaunch: true)
        let setup = Hosted(DaydreamOnboarding(model: o.model), requests: reqs)
        if walk {
            _ = waitFor(6) { setup.settle(0.05); return DaydreamOnboarding.drawnForChecks?.page == .apps && RealismReview.drawn?.enabled == true }
            setup.pressReturn()
            let onReview = waitFor(6) { setup.settle(0.05); return DaydreamOnboarding.drawnForChecks?.page == .review }
            guard onReview else {
                check(false, "bug12 Start (\(name)): harness reached the last page", "page \(String(describing: DaydreamOnboarding.drawnForChecks?.page)) \(RealismReview.drawn.map { "\($0)" } ?? "")")
                setup.close(); o.model.stopCapture(); return
            }
        } else {
            _ = waitFor(6) { setup.settle(0.05); return RealismReview.drawn?.page != nil }
        }
        inject(o)
        o.run(2.4) { false }  // the page's 2 s reads take the injected state
        setup.settle(0.2)
        let before = RealismReview.drawn, recordingBefore = o.model.recording
        setup.pressReturn()
        o.run(1.2)
        setup.settle(0.3)
        let after = RealismReview.drawn
        var changes: [String] = []
        if after?.page != before?.page { changes.append("page \(before?.page.map { "\($0)" } ?? "-") -> \(after?.page.map { "\($0)" } ?? "-")") }
        if o.model.recording && !recordingBefore { changes.append("recording started") }
        if Counters.reopens > 0 { changes.append("Quit & Reopen ran") }
        let line = after?.error ?? after?.message
        let fixes = (after?.enabled == true ? 1 : 0) + (after?.openSettings == true ? 1 : 0)
        let said = plainWords(line) && fixes == 1
        let detail = "before: \(before.map { "\($0.page.map { "\($0)" } ?? "-") \($0.button) enabled=\($0.enabled) msg=\($0.message ?? "-")" } ?? "-"); after: \(after.map { "\($0.page.map { "\($0)" } ?? "-") \($0.button) enabled=\($0.enabled) settings=\($0.openSettings)" } ?? "-") line=\(line ?? "-"); changes=\(changes)"
        let ok = want == .changes ? !changes.isEmpty : (changes.isEmpty && said)
        check(ok, "bug12 Start Recording (\(name)): \(want.rawValue): \(expect)", detail)
        check(!changes.isEmpty || said, "bug12 Start Recording (\(name)): never a silent no-op", detail)
        print("  \(name): \(changes.isEmpty ? "said: \(line ?? "nothing") (\(fixes) fixing button)" : changes.joined(separator: ", "))")
        Counters.reopens = 0
        Current.model = nil
        setup.close()
        o.model.stopCapture()
        o.run(0.2)
    }
    enum Counters { nonisolated(unsafe) static var reopens = 0 }

    static func setupStart() {
        let reopen = PermissionRequestActions(quitAndReopen: { Counters.reopens += 1 }, inputMonitoringAtLaunch: true)
        // Everything fine and recording starts (the input seam starts without an event tap).
        MemoryViewModel.startInput = { _ in true }
        startCase("everything allowed", want: .changes, inject: { _ in }, expect: "recording starts")
        // Recording refused to start (the check build's refusal stands in a start that fails).
        MemoryViewModel.refuseCaptureForChecks = true
        startCase("recording did not start", want: .says, inject: { _ in }, expect: "\"Recording didn't start. Try again.\" with Start Recording")
        MemoryViewModel.refuseCaptureForChecks = false
        // The event tap would not install (macOS applies Input Monitoring only after a reopen): EventCapture's own
        // failure, as it writes it (the session paused "Input event tap unavailable"), then one line and Quit & Reopen.
        MemoryViewModel.startInput = { _ in
            MainActor.assumeIsolated { Current.model?.coordinator?.pause("Input event tap unavailable. No recording started.") }
            return false
        }
        MemoryViewModel.canReopen = { true }
        startCase("keyboard and mouse not reaching DayDream", want: .says, requests: reopen, inject: { _ in },
                  expect: "\"\(RecordingCopy.inputUnreachable)\" with Quit & Reopen")
        MemoryViewModel.canReopen = { false }
        MemoryViewModel.startInput = { _ in true }
        // Each permission turned off in System Settings while setup sat on its last page.
        startCase("Accessibility turned off", want: .changes, inject: { _ in Perm.set(false, true) }, expect: "goes to Permissions (Allow Permissions)")
        startCase("Input Monitoring turned off", want: .changes, inject: { _ in Perm.set(true, false) }, expect: "goes to Permissions (Allow Permissions)")
        startCase("both permissions turned off", want: .changes, inject: { _ in Perm.set(false, false) }, expect: "goes to Permissions (Allow Permissions)")
        Perm.set(true, true)
        // Input Monitoring turned on after DayDream opened: setup's main button is Quit & Reopen, which reopens.
        startCase("Input Monitoring granted after launch", want: .changes, walk: false,
                  requests: PermissionRequestActions(quitAndReopen: { Counters.reopens += 1 }, inputMonitoringAtLaunch: false),
                  inject: { _ in }, expect: "Quit & Reopen reopens")
        // Opened from the download window: recording can't start there; one line and Open Settings.
        startCase("opened from the disk image", want: .says, launch: .diskImage, inject: { _ in }, expect: "one line and Open Settings")
        // A store change: the app choices were changed by another window (or the command line) while setup was open.
        startCase("app choices changed elsewhere", want: .changes, inject: { o in
            guard let store = try? MemoryStore(home: o.memory, writable: true, automaticallySyncSearch: false), let p = try? store.policy() else {
                check(false, "bug12 harness: a second handle on the synthetic history"); return
            }
            _ = try? store.savePreferences(MemoryPreferences(blockedApps: p.blockedApps + ["com.example.elsewhere"], nativeTyping: p.captureText, typingChoiceShown: true),
                                           expectedRevision: p.revision)
            check((try? store.policy().blockedApps.contains("com.example.elsewhere")) == true, "bug12 harness: another handle saved a changed app list")
        }, expect: "starts with the saved list, or goes back to the app choices")
    }

    // MARK: bug 3 and the TCC matrix

    enum TCCState: String, CaseIterable {
        case off, on
        case onInSettingsNotEffective = "on in System Settings but not effective"
        case grantedAfterLaunch = "granted after launch (needs a reopen)"
        case revokedWhileRecording = "revoked while recording"
    }

    static func tccStates() {
        let appURL = fixtureApp(home)
        for permission in CardPermission.allCases {
            for state in TCCState.allCases { cardState(permission, state, appURL: appURL) }
        }
        for state in TCCState.allCases { chromeState(state, appURL: appURL) }
    }

    static func label(_ permission: String, _ state: TCCState) -> String {
        (state == .onInSettingsNotEffective ? "bug3 " : "tcc ") + "\(permission) \(state.rawValue)"
    }

    static func cardState(_ permission: CardPermission, _ state: TCCState, appURL: URL) {
        let kind: PermissionKind = permission == .accessibility ? .accessibility : .inputMonitoring
        let name = label(permission.title, state)
        if state == .revokedWhileRecording {
            // Recording, then the permission is turned off in System Settings: the status says which, with one action.
            Perm.set(true, true)
            UserDefaults.standard.register(defaults: [MemoryViewModel.setupCompletedKey: true])
            let o = openModel(out, "revoke-\(permission.rawValue)")
            o.model.startCapture()
            o.run(0.6)
            check(o.model.recording, "\(name): harness is recording")
            if permission == .accessibility { Perm.set(false, true) } else { Perm.set(true, false) }
            o.model.refreshCaptureStatus()
            o.run(3.5) { o.model.recordingState.kind == .needsPermission }
            let shown = o.model.recordingState
            let detail = shown.detail(now: Date(), timeZone: .current)
            check(shown == .needsPermission(missing: [kind]) && detail == "\(kind.title) is off in System Settings." && plainWords(detail)
                  && shown.primaryAction == .openSystemSettings && shown.title == kind.turnOnTitle,
                  "\(name): the status says \"\(detail ?? "-")\" with one action, \(shown.title)", "\(shown)")
            o.model.stopCapture(); o.run(0.1)
            Perm.set(true, true)
            return
        }
        let on = state == .on || state == .grantedAfterLaunch
        final class Reads { var a = true, i = true }
        let reads = Reads()
        if permission == .accessibility { reads.a = on } else { reads.i = on }
        let opened: [String: Date] = state == .onInSettingsNotEffective ? [permission.rawValue: Date().addingTimeInterval(-10)] : [:]
        // Granted after launch: the permissions window (it draws Quit & Reopen as a row); the others as setup draws them.
        let window = state == .grantedAfterLaunch
        let reopen = PermissionRequestActions(quitAndReopen: { Counters.reopens += 1 },
                                              inputMonitoringAtLaunch: state == .grantedAfterLaunch && permission == .inputMonitoring ? false : true)
        let view = PermissionGrantView(enabled: true, appURL: appURL, readAccessibility: { reads.a }, readInputMonitoring: { reads.i },
                                       embedded: true, showsRelaunchRow: window, dragHint: PermissionDragHint(opened: opened),
                                       known: PermissionSnapshot(), allowedBefore: false, sideBySide: !window)
        let page = Hosted(view, requests: reopen)
        _ = waitFor(2.6) { page.host.layoutSubtreeIfNeeded(); return state != .onInSettingsNotEffective || page.elements["dragHint"] != nil }
        page.settle(0.2)
        let buttons = page.buttons
        switch state {
        case .off:
            Perm.set(permission != .accessibility, permission != .inputMonitoring)
            let o = openModel(out, "off-\(permission.rawValue)")
            // Off is shown once the reads settle on off (one false read is not a stop): the same bound as a revoke.
            o.model.refreshCaptureStatus()
            o.run(3.5) { o.model.recordingState.kind == .needsPermission }
            let shown = o.model.recordingState, detail = shown.detail(now: Date(), timeZone: .current)
            check(buttons == ["open." + permission.rawValue] && shown == .needsPermission(missing: [kind]) && plainWords(detail) && shown.primaryAction == .openSystemSettings,
                  "\(name): \"\(detail ?? "-")\" and exactly one fixing button (Open System Settings on its card)", "buttons \(buttons), state \(shown)")
            o.model.stopCapture(); Perm.set(true, true)
        case .on:
            check(buttons.isEmpty, "\(name): Allowed, and no fixing button", "buttons \(buttons)")
        case .onInSettingsNotEffective:
            let line = PermissionRowHelp.dragHint(appName: PermissionRowHelp.appName(appURL: appURL))
            check(page.elements["dragHint"] != nil && buttons == ["open." + permission.rawValue] && line.contains("Already listed but off here?")
                  && line.contains("Remove it") && plainWords(line),
                  "\(name): one plain-words fix (\"Already listed but off here? Remove it ... first\") and exactly one fixing button", "buttons \(buttons), elements \(page.elements.keys.sorted())")
        case .grantedAfterLaunch:
            let needsReopen = permission == .inputMonitoring
            let pending = DaydreamOnboarding.relaunchPending(available: true, accessibility: true, inputMonitoring: true, canReopen: true,
                                                            inputMonitoringAtLaunch: needsReopen ? false : true, inputNeedsReopen: false)
            if needsReopen {
                check(buttons == ["quitAndReopen"] && pending, "\(name): exactly one fixing button, Quit & Reopen (setup's main button says it too)", "buttons \(buttons), setup \(pending)")
            } else {
                check(buttons.isEmpty && !pending, "\(name): Allowed at once with no button (macOS applies it without a reopen)", "buttons \(buttons), setup \(pending)")
            }
        case .revokedWhileRecording: break
        }
        page.close()
        Counters.reopens = 0
    }

    static func chromeState(_ state: TCCState, appURL: URL) {
        let name = label("Chrome automation", state)
        Perm.set(true, true)
        UserDefaults.standard.register(defaults: [MemoryViewModel.setupCompletedKey: true])
        let o = openModel(out, "chrome-\(state)".replacingOccurrences(of: " ", with: "-"))
        func read(_ status: OSStatus) {
            o.chrome.status = status
            o.model.chromeAccessEnvironment = o.chrome.environment
            o.model.checkChromeAccess()
            o.run(1.0) { o.model.chromeAccess != .checking }
        }
        func row(_ access: ChromeAccessState) -> (buttons: [String], subtitle: String) {
            let chromeRow = PermissionChromeRow(icon: nil, access: access, asked: false, allow: {}, openSettings: {}, typing: true, opensChrome: false, askAgain: {})
            let view = PermissionGrantView(enabled: true, appURL: appURL, readAccessibility: { true }, readInputMonitoring: { true }, embedded: true,
                                           showsRelaunchRow: false, known: PermissionSnapshot(accessibility: true, inputMonitoring: true),
                                           allowedBefore: true, chromeRow: chromeRow, sideBySide: true)
            let page = Hosted(view, requests: PermissionRequestActions(quitAndReopen: nil, inputMonitoringAtLaunch: true))
            page.settle(0.4)
            defer { page.close() }
            return (page.buttons, PermissionChromeRow.subtitle(access: access, typing: true, opensChrome: false))
        }
        switch state {
        case .off:
            read(-1744)  // errAEEventWouldRequireUserConsent: never asked
            let r = row(o.model.chromeRowAccess)
            check(o.model.chromeRowAccess == .notAsked && r.buttons == ["allow.chrome"] && plainWords(r.subtitle),
                  "\(name): \"\(r.subtitle)\" and exactly one fixing button (Allow)", "access \(o.model.chromeRowAccess), buttons \(r.buttons)")
        case .on:
            read(0)
            let r = row(o.model.chromeRowAccess)
            check(o.model.chromeRowAccess == .allowed && r.buttons.isEmpty, "\(name): Allowed, and no fixing button", "access \(o.model.chromeRowAccess), buttons \(r.buttons)")
        case .onInSettingsNotEffective:
            read(-1743)  // errAENotPermitted: the switch shows on for an older copy's row; this copy is refused
            let r = row(o.model.chromeRowAccess)
            check(o.model.chromeRowAccess == .denied && r.buttons == ["askagain.chrome"] && plainWords(r.subtitle),
                  "\(name): \"\(r.subtitle)\" and exactly one fixing button (Ask again)", "access \(o.model.chromeRowAccess), buttons \(r.buttons)")
        case .grantedAfterLaunch:
            read(-1743)
            let before = o.model.chromeRowAccess
            read(0)  // the next read (setup reads again when DayDream comes back to the front): no reopen
            let r = row(o.model.chromeRowAccess)
            check(before == .denied && o.model.chromeRowAccess == .allowed && r.buttons.isEmpty,
                  "\(name): Allowed on the next read with no reopen and no button", "before \(before), after \(o.model.chromeRowAccess), buttons \(r.buttons)")
        case .revokedWhileRecording:
            o.model.saveOnboardingPreferences(excluded: [], typedText: o.model.captureText, browserPages: true)
            o.run(1.0) { !o.model.preferencesUnresolved }
            o.model.startCapture()
            o.run(0.6)
            read(0)
            let wasOn = o.model.presentation.browserHistory
            read(-1743)
            let line = o.model.presentation.browserHistory
            check(o.model.recording && wasOn == .on && line == .needsAccess && line.text == ChromeAccessNotice.line && plainWords(line.text)
                  && !ChromeAccessNotice.title(askAgain: o.model.chromeLineAccess == .denied).isEmpty,
                  "\(name): \"\(line.text ?? "-")\" with one button (\(ChromeAccessNotice.title(askAgain: o.model.chromeLineAccess == .denied)))",
                  "recording \(o.model.recording), before \(wasOn), after \(line), access \(o.model.chromeLineAccess)")
        }
        o.model.stopCapture()
        o.run(0.1)
    }

    // MARK: bug 6: dragging the card copies nothing

    /// The card's view, as AppKit sees it: records the drag it is asked to begin and hands back an inert session (no
    /// drag loop runs, no window server drag, nothing on screen).
    final class RecordingAnchor: NSView {
        var items: [NSDraggingItem] = []
        static let inert: NSDraggingSession = class_createInstance(NSDraggingSession.self, 0) as! NSDraggingSession
        override func beginDraggingSession(with items: [NSDraggingItem], event: NSEvent, source: NSDraggingSource) -> NSDraggingSession {
            self.items += items
            return Self.inert
        }
    }

    static func files(under url: URL) -> [String: Int] {
        var out: [String: Int] = [:]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) else { return out }
        for case let f as URL in e { out[f.path] = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return out
    }

    static func dragCaches() {
        let appURL = fixtureApp(home)
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let before = files(under: caches)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 420, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = RecordingAnchor(frame: NSRect(x: 0, y: 0, width: 420, height: 80))
        window.contentView = anchor
        var started = 0
        var urls: [URL] = []
        for n in 1...5 {
            guard let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 40 + n, y: 30), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: n, clickCount: 1, pressure: 1) else { stop("no drag event") }
            if PermissionCardDrag.shared.begin(appURL: appURL, enabled: true, guides: false, anchor: anchor, event: event) { started += 1 }
            // What System Settings does with the drop: reads the file URL off the pasteboard (a private one here).
            if let writer = anchor.items.last?.item as? NSPasteboardWriting {
                let board = NSPasteboard(name: NSPasteboard.Name("realism-drag-\(UUID().uuidString)"))
                board.clearContents()
                board.writeObjects([writer])
                if let read = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] { urls += read }
                board.releaseGlobally()
            }
            PermissionCardDrag.shared.draggingSession(RecordingAnchor.inert, endedAt: .zero, operation: [])
            pump(0.05)
        }
        let after = files(under: caches)
        let added = after.filter { before[$0.key] != $0.value }.keys.sorted()
        check(started == 5 && anchor.items.count == 5, "bug6 the DayDream card's drag started 5 times in a row", "started \(started), items \(anchor.items.count)")
        check(added.isEmpty, "bug6 five drags of the DayDream card write nothing under Library/Caches (no copy of the app)",
              "\(added.count) new: \(added.prefix(3).joined(separator: ", "))")
        let installed = appURL.resolvingSymlinksInPath().standardizedFileURL
        check(urls.count == 5 && urls.allSatisfy { $0.resolvingSymlinksInPath().standardizedFileURL == installed },
              "bug6 what the card carries is the installed app's own URL (\(installed.lastPathComponent)), every time", urls.map(\.path).joined(separator: ", "))
        check(!window.isVisible, "bug6 the drag's window was never shown")
        window.contentView = nil
        cardDrags(appURL: appURL, caches: caches)
    }

    /// The drags AppKit was asked to begin from setup's own cards (PermissionCardPressView's beginDraggingSession, stood
    /// in for below: no drag loop, no window server drag).
    static var cardItems: [NSDraggingItem] = []

    /// Bug 6 as the owner hit it: setup's Accessibility card, pressed and dragged five times in a row. The presses go
    /// through the card's own press view (`PermissionCardPress`, what a real press reaches first), so a card that drags
    /// some other way (SwiftUI's onDrag, which copied the app) starts no drag here and fails.
    static func cardDrags(appURL: URL, caches: URL) {
        let sel = #selector(NSView.beginDraggingSession(with:event:source:))
        if let method = class_getInstanceMethod(NSView.self, sel) {
            let block: @convention(block) (NSView, [NSDraggingItem], NSEvent, NSDraggingSource) -> NSDraggingSession = { _, items, _, _ in
                MainActor.assumeIsolated { cardItems += items }
                return RecordingAnchor.inert
            }
            class_addMethod(PermissionCardPressView.self, sel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
        let before = files(under: caches)
        let view = PermissionGrantView(enabled: true, appURL: appURL, readAccessibility: { false }, readInputMonitoring: { false },
                                       embedded: true, showsRelaunchRow: false, known: PermissionSnapshot(accessibility: false, inputMonitoring: false),
                                       allowedBefore: false, sideBySide: true)
        let page = Hosted(view, requests: PermissionRequestActions(quitAndReopen: nil, inputMonitoringAtLaunch: true))
        _ = waitFor(2) { page.host.layoutSubtreeIfNeeded(); return page.elements["card.accessibility"] != nil }
        func pressViews(_ v: NSView) -> [PermissionCardPressView] { ((v as? PermissionCardPressView).map { [$0] } ?? []) + v.subviews.flatMap(pressViews) }
        let cards = pressViews(page.host).filter { !$0.keepOut && $0.enabled }
        let card = cards.min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        check(card != nil, "bug6 setup's Accessibility card draws its draggable press view", "\(cards.count) draggable cards, elements \(page.elements.keys.sorted())")
        var started = 0
        if let card {
            let p = card.convert(NSPoint(x: card.bounds.minX + 30, y: card.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType, _ at: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: page.window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            }
            for n in 1...5 {
                let sessions = PermissionCardDrag.shared.sessions
                for e in [event(.leftMouseDown, p), event(.leftMouseDragged, NSPoint(x: p.x + 8, y: p.y + CGFloat(n))),
                          event(.leftMouseDragged, NSPoint(x: p.x + 60, y: p.y + CGFloat(n))), event(.leftMouseUp, NSPoint(x: p.x + 60, y: p.y + CGFloat(n)))] {
                    _ = PermissionCardPress.shared.handle(e)
                }
                if PermissionCardDrag.shared.sessions == sessions + 1 { started += 1 }
                PermissionCardDrag.shared.draggingSession(RecordingAnchor.inert, endedAt: .zero, operation: [])
                pump(0.05)
            }
        }
        var urls: [URL] = []
        for item in cardItems {
            guard let writer = item.item as? NSPasteboardWriting else { continue }
            let board = NSPasteboard(name: NSPasteboard.Name("realism-card-drag-\(UUID().uuidString)"))
            board.clearContents(); board.writeObjects([writer])
            urls += (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            board.releaseGlobally()
        }
        let added = files(under: caches).filter { before[$0.key] != $0.value }.keys.sorted()
        let installed = appURL.resolvingSymlinksInPath().standardizedFileURL
        check(started == 5 && cardItems.count == 5, "bug6 setup's card, pressed and dragged 5 times in a row, starts 5 AppKit drags (never SwiftUI's onDrag)",
              "started \(started), items \(cardItems.count)")
        check(urls.count == 5 && urls.allSatisfy { $0.resolvingSymlinksInPath().standardizedFileURL == installed } && added.isEmpty,
              "bug6 each drag from setup's card carries the installed app's own URL and writes nothing under Library/Caches",
              "urls \(urls.map(\.path)), \(added.count) new under Caches")
        page.close()
    }

    // MARK: Window placement on display layouts

    static func rect(_ a: Any?) -> CGRect {
        let v = (a as? [NSNumber])?.map { CGFloat($0.doubleValue) } ?? [0, 0, 0, 0]
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    static func windowLayouts(_ fixture: String) throws {
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixture))) as? [String: Any],
              let layouts = json["layouts"] as? [[String: Any]], let s = json["setup"] as? [NSNumber], let g = json["guide"] as? [NSNumber] else {
            stop("display layouts fixture unreadable")
        }
        let setupSize = CGSize(width: CGFloat(s[0].doubleValue), height: CGFloat(s[1].doubleValue))
        let guide = NSSize(width: CGFloat(g[0].doubleValue), height: CGFloat(g[1].doubleValue))
        check(layouts.count >= 3, "layouts fixture: \(layouts.count) display layouts (at least 3)")
        func inside(_ r: CGRect, _ room: CGRect) -> Bool { r.minX >= room.minX - 0.5 && r.minY >= room.minY - 0.5 && r.maxX <= room.maxX + 0.5 && r.maxY <= room.maxY + 0.5 }
        for layout in layouts {
            let name = layout["name"] as? String ?? "?"
            let visible = rect(layout["visible"]), screen = rect(layout["screen"]), settings = rect(layout["settings"])
            let stage = layout["stageManager"] as? Bool ?? false, primaryHeight = CGFloat((layout["primaryHeight"] as? NSNumber)?.doubleValue ?? 0)
            let room = PermissionPair.usable(visible: visible, stageManager: stage)
            // Input Monitoring step (Accessibility allowed): both windows placed as a pair.
            let pair = PermissionPair.place(setup: CGRect(origin: .zero, size: setupSize), settings: settings, visible: visible, stageManager: stage)
            let listOf = { (w: CGRect) in PermissionPair.zone(list: nil, settingsWindow: w) }
            let pairList = listOf(pair.settings)
            check(inside(pair.setup, room) && inside(pair.settings, room), "layout \(name): setup and System Settings both placed on that display's usable frame",
                  "setup \(pair.setup), settings \(pair.settings), room \(room)")
            check(pair.setup.minY == pair.settings.minY, "layout \(name): the pair's tops line up", "setup \(pair.setup.minY), settings \(pair.settings.minY)")
            check(!pair.setup.intersects(pairList), "layout \(name): setup never covers System Settings' list (\(pair.option.rawValue), overlap \(Int(pair.overlap)) pt)",
                  "setup \(pair.setup), list \(pairList)")
            if pair.option == .centered { check(pair.settings.minX - pair.setup.maxX == PermissionPair.gap, "layout \(name): centered pair, 16 pt apart") }
            // Accessibility step (System Settings can't be moved): setup follows it.
            // rc-018 RC3 B7: setup may hang off the screen's left edge by less than the cards' text inset (or off the right edge
            // by at most the shell's margin), so the cards' titles and lines stay on screen; when even that doesn't fit, the
            // compact drag panel (the card alone) stands in for setup and must be on the display.
            let beside = PermissionPair.beside(setup: setupSize, settings: settings, visible: visible, stageManager: stage)
            let follow = beside.frame
            check(follow == PermissionPair.follow(setup: setupSize, settings: settings, visible: visible, stageManager: stage),
                  "layout \(name): follow is beside's frame")
            if beside.compact {
                let panel = PermissionPair.compact(size: CGSize(width: PermissionPair.compactWidth, height: 74), settings: settings, visible: visible, stageManager: stage)
                check(inside(panel, visible), "layout \(name): no room for setup beside System Settings: the compact drag panel stands in, on its display's visible frame",
                      "panel \(panel), visible \(visible)")
            } else {
                let textOn = follow.minX + PermissionPair.textInset >= visible.minX - 0.5 && follow.maxX - PermissionPair.shellMargin <= visible.maxX + 0.5
                    && follow.minY >= visible.minY - 0.5 && follow.maxY <= visible.maxY + 0.5
                check(textOn, "layout \(name): setup follows System Settings with its cards' text on its display's visible frame", "setup \(follow), visible \(visible)")
            }
            // Where there is room beside System Settings, setup doesn't touch it; where there isn't (it can't be moved on the
            // Accessibility step), setup goes where it covers the least of the list (the screen edge away from it).
            let list = listOf(settings)
            func covered(_ r: CGRect) -> CGFloat { max(0, min(r.maxX, list.maxX) - max(r.minX, list.minX)) }
            let roomBeside = settings.minX - PermissionPair.gap - setupSize.width >= room.minX - 0.5 || settings.maxX + PermissionPair.gap + setupSize.width <= room.maxX + 0.5
            let edges = [CGRect(x: room.minX, y: follow.minY, width: setupSize.width, height: setupSize.height),
                         CGRect(x: room.maxX - setupSize.width, y: follow.minY, width: setupSize.width, height: setupSize.height)]
            let least = edges.map(covered).min() ?? 0
            if roomBeside {
                check(!follow.intersects(settings), "layout \(name): setup follows System Settings beside it, never over it", "setup \(follow), settings \(settings)")
            } else {
                check(covered(follow) <= least + 0.5, "layout \(name): no room beside System Settings: setup covers the least of its list possible (\(Int(covered(follow))) of \(Int(list.width)) pt)",
                      "setup \(follow), list \(list), least \(least)")
            }
            let flippedSettings = PermissionPair.flipped(settings, primaryHeight: primaryHeight)
            check(PermissionPair.flipped(flippedSettings, primaryHeight: primaryHeight) == settings, "layout \(name): AppKit and window-server rects flip back exactly")
            // The Chrome guide beside System Settings (AppKit coordinates of the display System Settings is on).
            let appKitVisible = PermissionPair.flipped(visible, primaryHeight: primaryHeight)
            let origin = ChromeGuidePlacement.origin(guide: guide, settings: flippedSettings, screen: appKitVisible)
            let guideRect = CGRect(origin: origin, size: guide)
            let guideRoom = flippedSettings.minX - appKitVisible.minX >= guide.width + ChromeGuidePlacement.gap + 8
                || appKitVisible.maxX - flippedSettings.maxX >= guide.width + ChromeGuidePlacement.gap + 8
            check(inside(guideRect, appKitVisible) && (!guideRoom || !guideRect.intersects(flippedSettings.insetBy(dx: 1, dy: 1))),
                  "layout \(name): the Chrome guide sits on System Settings' display, beside it where there is room", "guide \(guideRect), settings \(flippedSettings), screen \(appKitVisible)")
            _ = screen
        }
    }
}
