import Foundation
import Darwin
import MemoryCore

private final class IsolatedLauncher: LauncherControl {
    var state = LauncherState(loaded: true, disabled: false)
    var stops = 0, restores = 0, inspections = 0
    var failStop = false
    func inspect(_ launcher: LegacyLauncher) throws -> LauncherState { inspections += 1; return state }
    func stopAndDisable(_ launcher: LegacyLauncher) throws {
        stops += 1; state = LauncherState(loaded: false, disabled: true)
        if failStop { throw MemError.invalid("synthetic stop failure") }
    }
    func restore(_ launcher: LegacyLauncher, previous: LauncherState) throws { restores += 1; state = previous }
}

@main struct CompositionChecks {
    static var count = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw MemError.invalid("FAILED: " + label) }
        count += 1; print("PASS " + label)
    }
    static func denied(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { try check(true, label); return }
        throw MemError.invalid("FAILED (accepted): " + label)
    }
    static func main() throws {
        // Synthetic adversarial child only. Normal positive tests run the actual
        // freshly built mac-mem CLI, not this fixture's fabricated responses.
        if let i = CommandLine.arguments.firstIndex(of: "--client") {
            switch CommandLine.arguments[i + 1] {
            case "slow": sleep(5); return
            case "huge": print(String(repeating: "x", count: 70_000)); return
            case "fail": fputs("synthetic-sensitive-child-error", stderr); exit(3)
            default: print("{}"); return
            }
        }
        guard CommandLine.arguments.count == 3 else { fatalError("CLI_PATH ISOLATED_TEST_ROOT required") }
        func physical(_ path: String) -> String {
            guard let resolved = realpath(path, nil) else { fatalError("fixture path missing") }
            defer { free(resolved) }; return String(cString: resolved)
        }
        let cli = physical(CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        guard root.path.hasPrefix("/private/tmp/"), !FileManager.default.fileExists(atPath: root.path) else { fatalError("new temporary fixture root required") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try MemoryStore(home: root.appendingPathComponent("new"), writable: true, automaticallySyncSearch: false)
        _ = try store.ingest(Evidence(id: "synthetic-consumer-action", at: iso(Date()), kind: "window.changed", app: "Fixture", title: "Read-back fixture", synthetic: true))
        let token = try store.grant(client: "fixture-local-cli", recipient: "fixture-recipient", scopes: ["context", "detail"])
        let route = ReplacementConsumerConfiguration.Route(id: "actual-local-reader", kind: "local-canonical-cli-v1", executable: cli,
            executableSHA256: ReplacementComposition.sha256(try Data(contentsOf: URL(fileURLWithPath: cli))),
            home: physical(store.home.path), client: "fixture-local-cli", recipient: "fixture-recipient",
            capabilityEnvironment: "FIXTURE_CAPABILITY", capabilitySHA256: ReplacementComposition.sha256(Data(token.utf8)))
        let config = ReplacementConsumerConfiguration(version: 1, requiredConsumers: [route.id], routes: [route])
        let fake = IsolatedLauncher()
        func composition(_ config: ReplacementConsumerConfiguration = config) throws -> ReplacementComposition {
            let bytes = try JSONEncoder().encode(config)
            return try ReplacementComposition(store: store, control: fake, reviewedConfiguration: bytes, approvedSHA256: ReplacementComposition.sha256(bytes))
        }
        let old = root.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        try Data("untouched synthetic legacy evidence".utf8).write(to: old.appendingPathComponent("sentinel"))
        let plist = root.appendingPathComponent("synthetic.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Label": "test.fixture.consumer", "Program": "/synthetic/not-a-real-service"], format: .xml, options: 0).write(to: plist)
        let launcher = LegacyLauncher(label: "test.fixture.consumer", plist: plist.path, executable: "/synthetic/not-a-real-service", historyHome: old.path)
        let composed = try composition(), environment = ["FIXTURE_CAPABILITY": token]
        func readiness(_ legacy: LegacyFootprint? = nil, development: Bool = false,
                       replacement: ReplacementSetupReadiness.ReplacementPresence = .absent,
                       bytes: Data? = nil, approval: String? = nil) -> ReplacementSetupReadiness {
            ReplacementSetupReadiness.assess(store: store, developmentEnforcedOff: development,
                knownLegacy: legacy, replacementState: replacement,
                reviewedConfiguration: bytes, approvedSHA256: approval)
        }
        let clear = LegacyFootprint(socketPresent: false, services: [])
        try check(readiness().trialNextStep == .inspectKnownCollectorMetadata, "unknown collector metadata cannot enable trial")
        try check(readiness(clear).trialNextStep == .useNormalStartChecks, "nonconflicting limited trial does not depend on consumer configuration")
        try check(readiness(clear).consumerCode == "consumer_inventory_missing", "missing inventory has machine-readable separate replacement status")
        try check(readiness(clear).missingInputs == ["requiredConsumers", "routes"], "app gets exact missing inventory fields")
        try check(readiness(clear, development: true).trialNextStep == .developmentCaptureOff, "development remains enforced OFF")
        try check(readiness(LegacyFootprint(socketPresent: true, services: [])).trialNextStep == .reviewCollectorConflict, "socket footprint blocks conflicting trial")
        try check(readiness(LegacyFootprint(socketPresent: false, services: ["synthetic-known-service"])).trialNextStep == .reviewCollectorConflict, "known service metadata blocks trial without stopping it")
        try check(readiness(clear, replacement: .unknown).trialNextStep == .reviewExistingReplacement, "failed replacement-state read cannot masquerade as absent")
        try check(readiness(clear, replacement: .present).trialNextStep == .reviewExistingReplacement, "existing transition keeps recovery gate")
        let draft = try ReplacementSetupReadiness.draft(config)
        try check(readiness(clear, bytes: draft.bytes).consumerNextStep == .reviewInventory, "native draft creation does not approve configuration")
        let prepared = readiness(clear, bytes: draft.bytes, approval: draft.sha256)
        try check(prepared.consumerNextStep == .verifyExistingCredentialsAndReadBack && prepared.consumerCode == "reviewed_inventory_not_yet_verified", "reviewed setup never claims real read-back before execution")
        try check(prepared.browserCoverage == "unsupported", "browser unsupported does not become parity or a narrow-trial blocker")
        try check(try JSONDecoder().decode(ReplacementSetupReadiness.self, from: JSONEncoder().encode(prepared)) == prepared, "readiness contract serializes for app without secrets")
        try check(fake.inspections == 0 && fake.stops == 0, "construction performs no launcher inspection/change")
        try check(composed.requiredConsumers == [route.id], "exact configured route exposed without secret resolution")
        try check(!composed.permitsStart(), "no recorded proof cannot permit start")
        try denied("unreviewed bytes rejected") { _ = try ReplacementComposition(store: store, control: fake, reviewedConfiguration: JSONEncoder().encode(config), approvedSHA256: String(repeating: "0", count: 64)) }
        var bad = config; bad.requiredConsumers = []; bad.routes = []
        try denied("empty inventory rejected") { _ = try composition(bad) }
        bad = config; bad.requiredConsumers.append("missing")
        try denied("missing required route rejected") { _ = try composition(bad) }
        bad = config; bad.routes.append(route); bad.requiredConsumers.append(route.id)
        try denied("duplicate inventory rejected") { _ = try composition(bad) }
        bad = config; bad.routes[0].kind = "horizon-remote-before-turn"
        try denied("unsupported remote route never substituted with local CLI") { _ = try composition(bad) }
        bad = config; bad.routes[0].home = root.appendingPathComponent("other").path
        try denied("wrong canonical home rejected") { _ = try composition(bad) }
        try denied("approval still required") { try composed.prepare(launcher, approved: false, credentialEnvironment: environment) }
        try denied("missing existing credential rejected") { try composed.prepare(launcher, approved: true, credentialEnvironment: [:]) }
        try denied("changed credential rejected") { try composed.prepare(launcher, approved: true, credentialEnvironment: ["FIXTURE_CAPABILITY": "wrong"]) }
        bad = config; bad.routes[0].recipient = "other-recipient"
        try denied("wrong recipient grant rejected before launcher changes") { try composition(bad).prepare(launcher, approved: true, credentialEnvironment: environment) }
        bad = config; bad.routes[0].executableSHA256 = String(repeating: "0", count: 64)
        try denied("changed executable rejected") { try composition(bad).prepare(launcher, approved: true, credentialEnvironment: environment) }
        try check(fake.stops == 0, "all invalid configurations leave old collector alone")
        let probe = try PinnedLocalCLIConsumer(route: route, identity: route.id, capability: token)
        let uri = ActionResources.actionURI("synthetic-consumer-action")
        let read = try probe.read(resource: uri, nonce: "fresh-local-read", deadline: Date().addingTimeInterval(2))
        try check(try decode(CanonicalAction.self, read.body).id == "synthetic-consumer-action", "actual CLI opens durable canonical action")
        try check(read.nonce == "fresh-local-read" && read.resource == uri, "fresh child response bound to exact request")
        try denied("arbitrary file resource denied") { _ = try probe.read(resource: "file:///private/fixture", nonce: "n", deadline: Date().addingTimeInterval(2)) }
        try denied("expired deadline denied") { _ = try probe.read(resource: uri, nonce: "n", deadline: Date().addingTimeInterval(-1)) }
        try composed.prepare(launcher, approved: true, credentialEnvironment: environment)
        let recovery = ReplacementComposition.recovery(store: store, control: fake)
        try check(try recovery.record()?.consumerReceipts?.count == 1 && fake.stops == 1, "actual CLI action and context checks precede fake stop")
        try check(try store.status()["capture"] == "off", "preparation leaves recording OFF")
        try check(try composed.permitsStart(), "verified exact inventory plus old stopped allows separate Start")
        try check(try composed.verifyBeforeStart(credentialEnvironment: environment), "explicit Start reruns current executable reads and grants")
        try denied("explicit Start cannot use saved receipts instead of credentials") { _ = try composed.verifyBeforeStart(credentialEnvironment: [:]) }
        bad = config; bad.routes[0].capabilityEnvironment = "CHANGED_REFERENCE"
        try check(try !composition(bad).permitsStart(), "changed reviewed credential reference invalidates stored start proof")
        try denied("new recording evidence still required for commit") { try composed.commit(credentialEnvironment: environment) }
        try denied("rollback protects active new recorder") { try recovery.rollback(approved: true, stopNew: {}, newIsStopped: { false }) }
        try recovery.rollback(approved: true, stopNew: {}, newIsStopped: { true })
        try check(fake.state == LauncherState(loaded: true, disabled: false), "recovery works without config or credentials")
        let restoreCount = fake.restores
        try recovery.rollback(approved: true, stopNew: {}, newIsStopped: { true })
        try check(fake.restores == restoreCount, "rollback retry idempotent")
        fake.failStop = true
        try denied("failed fake stop reported") { try composed.prepare(launcher, approved: true, credentialEnvironment: environment) }
        try check(try recovery.record()?.phase == "rolled_back" && fake.state.loaded, "failed stop rolls back exact old state")
        fake.failStop = false
        try composed.prepare(launcher, approved: true, credentialEnvironment: environment)
        let session = try CaptureSession(store: store)
        try session.start(permitted: true) // Synthetic core adapter only, no OS EventCapture.
        let now = Date()
        _ = try session.record(Evidence(id: "after-synthetic-start", at: iso(now), kind: "window.changed", app: "Fixture", title: "Synthetic health", synthetic: true), focusedFieldKnown: true, permitted: true, now: now)
        try composed.commit(credentialEnvironment: environment)
        try check(try recovery.record()?.phase == "committed", "commit reruns actual native CLI against fresh synthetic health")
        try store.revoke(client: route.client, recipient: route.recipient)
        try denied("explicit Start revalidation catches revoked grant after saved proof") { _ = try composed.verifyBeforeStart(credentialEnvironment: environment) }
        try recovery.rollback(approved: true, stopNew: { try session.pause("synthetic rollback") }, newIsStopped: { session.state != "recording" })
        let stopsBeforeRevoke = fake.stops
        try denied("revoked real grant denied") { try composed.prepare(launcher, approved: true, credentialEnvironment: environment) }
        try check(fake.stops == stopsBeforeRevoke, "revocation never stops old collector")
        try check(try String(contentsOf: old.appendingPathComponent("sentinel")) == "untouched synthetic legacy evidence", "legacy evidence unchanged")
        let selfPath = URL(fileURLWithPath: physical(CommandLine.arguments[0]))
        var hostile = route; hostile.executable = selfPath.path
        hostile.executableSHA256 = ReplacementComposition.sha256(try Data(contentsOf: selfPath))
        for mode in ["slow", "huge", "fail"] {
            hostile.client = mode
            let child = try PinnedLocalCLIConsumer(route: hostile, identity: mode, capability: "synthetic")
            let began = Date()
            try denied("bounded child \(mode) failure") { _ = try child.read(resource: uri, nonce: "n", deadline: Date().addingTimeInterval(0.2)) }
            try check(Date().timeIntervalSince(began) < 1, "\(mode) returns within bound")
        }
        let renewed = try store.grant(client: route.client, recipient: route.recipient, scopes: ["context", "detail"])
        let second = try store.grant(client: "second-reader", recipient: "second-recipient", scopes: ["context", "detail"])
        var multi = config
        multi.routes[0].capabilitySHA256 = ReplacementComposition.sha256(Data(renewed.utf8))
        var secondRoute = route
        secondRoute.id = "second-configured-reader"; secondRoute.client = "second-reader"; secondRoute.recipient = "second-recipient"
        secondRoute.capabilityEnvironment = "SECOND_CAPABILITY"
        secondRoute.capabilitySHA256 = ReplacementComposition.sha256(Data(second.utf8))
        multi.routes.append(secondRoute); multi.requiredConsumers.append(secondRoute.id)
        let multiEnvironment = ["FIXTURE_CAPABILITY": renewed, "SECOND_CAPABILITY": second]
        let multiFlow = try composition(multi)
        try denied("every required consumer needs its own credential") { try multiFlow.prepare(launcher, approved: true, credentialEnvironment: ["FIXTURE_CAPABILITY": renewed]) }
        try multiFlow.prepare(launcher, approved: true, credentialEnvironment: multiEnvironment)
        try check(try recovery.record()?.consumerReceipts?.count == 2, "two real configured CLI consumers produce two receipts")
        try recovery.rollback(approved: true, stopNew: {}, newIsStopped: { true })
        var mismatch = multi
        mismatch.routes[1].executable = selfPath.path; mismatch.routes[1].executableSHA256 = hostile.executableSHA256
        let priorStops = fake.stops
        try denied("second consumer bad body prevents whole replacement") { try composition(mismatch).prepare(launcher, approved: true, credentialEnvironment: multiEnvironment) }
        try check(fake.stops == priorStops, "first consumer success cannot bypass failing second consumer")
        let reopened = try MemoryStore(home: store.home, writable: true, automaticallySyncSearch: false)
        let restartedRecovery = ReplacementComposition.recovery(store: reopened, control: fake)
        try check(try restartedRecovery.record()?.phase == "rolled_back", "reopened store retains recovery phase without configured secrets")
        try check(try store.status()["capture"] != "recording", "fixture ends OFF")
        print("\(count) replacement composition checks passed; synthetic stores and launcher only")
    }
}
