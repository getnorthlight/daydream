import Foundation
import CryptoKit
import Darwin
import MemoryCore

/// An owner-reviewed inventory, not discovery or an authorization grant. Never
/// infer this inventory from installed apps or substitute example settings.
struct ReplacementConsumerConfiguration: Codable {
    struct Route: Codable {
        var id: String
        var kind: String
        var executable: String
        var executableSHA256: String
        var home: String
        var client: String
        var recipient: String
        var capabilityEnvironment: String
        var capabilitySHA256: String
    }
    var version: Int
    var requiredConsumers: [String]
    var routes: [Route]
}

/// Presentation contract only. A green setup row is never authority to record,
/// stop a collector, or replace the app's existing OS/focus/privacy checks.
struct ReplacementSetupReadiness: Codable, Equatable {
    enum ReplacementPresence: String, Codable { case unknown, absent, present }
    enum TrialNextStep: String, Codable {
        case developmentCaptureOff, inspectKnownCollectorMetadata
        case reviewCollectorConflict, reviewExistingReplacement, useNormalStartChecks
    }
    enum ConsumerNextStep: String, Codable {
        case collectScopedInventory, reviewInventory, correctConfiguration
        case verifyExistingCredentialsAndReadBack
    }
    var trialNextStep: TrialNextStep
    var consumerNextStep: ConsumerNextStep
    var consumerCode: String
    var missingInputs: [String]
    let browserCoverage = "unsupported"
    enum CodingKeys: String, CodingKey {
        case trialNextStep, consumerNextStep, consumerCode, missingInputs, browserCoverage
    }

    /// App calls this with its actual current-home scoped presence check. Nil
    /// means unknown, not empty. No launchd/private records/credential reads.
    static func inspectKnownCollectorMetadata() -> LegacyFootprint {
        InstallationReview.legacy(at: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func assess(store: MemoryStore?, developmentEnforcedOff: Bool,
                       knownLegacy: LegacyFootprint?, replacementState: ReplacementPresence,
                       reviewedConfiguration: Data?, approvedSHA256: String?) -> Self {
        let trial: TrialNextStep
        if developmentEnforcedOff { trial = .developmentCaptureOff }
        else if replacementState != .absent { trial = .reviewExistingReplacement }
        else if let legacy = knownLegacy { trial = legacy.requiresMigration ? .reviewCollectorConflict : .useNormalStartChecks }
        else { trial = .inspectKnownCollectorMetadata }
        // Consumer setup is independent: it does not block a trial which passes
        // the existing real-home collector, permission, storage and focus gates.
        guard let reviewedConfiguration else {
            return Self(trialNextStep: trial, consumerNextStep: .collectScopedInventory,
                        consumerCode: "consumer_inventory_missing", missingInputs: ["requiredConsumers", "routes"])
        }
        guard let approvedSHA256 else {
            return Self(trialNextStep: trial, consumerNextStep: .reviewInventory,
                        consumerCode: "consumer_inventory_review_missing", missingInputs: ["ownerReviewedInventorySHA256"])
        }
        guard let store else {
            return Self(trialNextStep: trial, consumerNextStep: .correctConfiguration,
                        consumerCode: "canonical_store_unavailable", missingInputs: ["canonicalStore"])
        }
        do {
            _ = try ReplacementComposition(store: store, control: NoLauncherInspection(),
                                           reviewedConfiguration: reviewedConfiguration, approvedSHA256: approvedSHA256)
            return Self(trialNextStep: trial, consumerNextStep: .verifyExistingCredentialsAndReadBack,
                        consumerCode: "reviewed_inventory_not_yet_verified", missingInputs: [])
        } catch {
            let code = (error as? ReplacementCompositionError)?.description ?? "consumer_inventory_invalid"
            return Self(trialNextStep: trial, consumerNextStep: .correctConfiguration,
                        consumerCode: code, missingInputs: code == "required_consumer_transport_unsupported" ? ["requiredConsumerAdapter"] : ["correctedReviewedInventory"])
        }
    }

    /// Build the owner review screen from native fields supplied by known scoped
    /// settings. This creates a DRAFT, never a saved approval or credential.
    static func draft(_ configuration: ReplacementConsumerConfiguration) throws -> (bytes: Data, sha256: String) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(configuration)
        guard bytes.count <= 65_536 else { throw ReplacementCompositionError.blocked("consumer_inventory_too_large") }
        return (bytes, ReplacementComposition.sha256(bytes))
    }
}
private struct NoLauncherInspection: LauncherControl {
    func inspect(_ launcher: LegacyLauncher) throws -> LauncherState { throw MemError.denied }
    func stopAndDisable(_ launcher: LegacyLauncher) throws { throw MemError.denied }
    func restore(_ launcher: LegacyLauncher, previous: LauncherState) throws { throw MemError.denied }
}

enum ReplacementCompositionError: Error, CustomStringConvertible {
    case blocked(String)
    var description: String { switch self { case .blocked(let reason): return reason } }
}

/// The caller supplies the exact reviewed bytes/hash and current credential
/// environment on explicit prepare/commit only. No implicit filesystem/keychain
/// discovery, credentials in saved intent, new grants, or launcher changes here.
final class ReplacementComposition {
    private let store: MemoryStore
    private let control: any LauncherControl
    private let configuration: ReplacementConsumerConfiguration
    private let digest: String

    init(store: MemoryStore, control: any LauncherControl,
         reviewedConfiguration: Data, approvedSHA256: String) throws {
        guard reviewedConfiguration.count <= 65_536,
              Self.sha256(reviewedConfiguration) == approvedSHA256 else {
            throw ReplacementCompositionError.blocked("consumer_inventory_review_missing_or_changed")
        }
        let config: ReplacementConsumerConfiguration
        do { config = try JSONDecoder().decode(ReplacementConsumerConfiguration.self, from: reviewedConfiguration) }
        catch { throw ReplacementCompositionError.blocked("consumer_inventory_invalid") }
        guard config.version == 1, !config.requiredConsumers.isEmpty,
              config.requiredConsumers.count <= 16,
              Set(config.requiredConsumers).count == config.requiredConsumers.count,
              config.routes.count == config.requiredConsumers.count,
              Set(config.routes.map(\.id)) == Set(config.requiredConsumers) else {
            throw ReplacementCompositionError.blocked("exact_nonempty_consumer_inventory_required")
        }
        for route in config.routes {
            guard route.kind == "local-canonical-cli-v1" else {
                throw ReplacementCompositionError.blocked("required_consumer_transport_unsupported")
            }
            guard [route.id, route.client, route.recipient].allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 100 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }), Self.isHash(route.executableSHA256), Self.isHash(route.capabilitySHA256),
            route.capabilityEnvironment.range(of: "^[A-Z][A-Z0-9_]{0,99}$", options: .regularExpression) != nil,
            Self.canonical(route.home) == Self.canonical(store.home.path),
            Self.canonical(route.home) == route.home,
            Self.canonical(route.executable) == route.executable else {
                throw ReplacementCompositionError.blocked("consumer_scope_or_reference_invalid")
            }
        }
        self.store = store; self.control = control; configuration = config; digest = approvedSHA256
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func isHash(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
    fileprivate static func canonical(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    private func identity(_ route: ReplacementConsumerConfiguration.Route) -> String { route.id + ":" + digest }

    /// Pure inventory output; not a success receipt and does not resolve secrets.
    var requiredConsumers: [String] { configuration.routes.map(\.id) }

    private func resolvedProbes(environment: [String: String]) throws -> [any ReplacementConsumerProbe] {
        try configuration.routes.map { route -> any ReplacementConsumerProbe in
            guard let capability = environment[route.capabilityEnvironment], !capability.isEmpty,
                  capability.utf8.count <= 4096,
                  Self.sha256(Data(capability.utf8)) == route.capabilitySHA256 else {
                throw ReplacementCompositionError.blocked("reviewed_consumer_credential_missing_or_changed")
            }
            return try PinnedLocalCLIConsumer(route: route, identity: identity(route), capability: capability)
        }
    }
    private func flow(environment: [String: String]) throws -> Switchover {
        Switchover(store: store, control: control, probes: try resolvedProbes(environment: environment),
                          requiredConsumers: configuration.routes.map(identity))
    }

    /// Run off the UI thread. The checkbox cannot substitute for these reads.
    func prepare(_ launcher: LegacyLauncher, approved: Bool, credentialEnvironment: [String: String]) throws {
        guard approved else { throw MemError.denied }
        try flow(environment: credentialEnvironment).prepare(launcher, approved: true, compatibilityReady: true)
    }
    func commit(credentialEnvironment: [String: String]) throws {
        try flow(environment: credentialEnvironment).commit()
    }
    /// Call only on the owner's explicit Start action, before starting capture.
    /// The read-only permitsStart below describes saved proof, not live grants.
    func verifyBeforeStart(credentialEnvironment: [String: String]) throws -> Bool {
        guard try permitsStart() else { return false }
        let probes = try resolvedProbes(environment: credentialEnvironment)
        _ = try store.verifyReplacementConsumers(probes, required: configuration.routes.map(identity))
        return try permitsStart()
    }
    func permitsStart() throws -> Bool {
        let recovery = Self.recovery(store: store, control: control)
        guard let receipts = try recovery.record()?.consumerReceipts,
              Set(receipts.map(\.identity)) == Set(configuration.routes.map(identity)) else { return false }
        return try recovery.permitsStart()
    }

    /// Recovery is deliberately independent of missing/changed consumer config.
    /// Exposes no prepare/commit method and cannot accidentally stop the old job.
    static func recovery(store: MemoryStore, control: any LauncherControl) -> ReplacementRecovery {
        ReplacementRecovery(store: store, control: control)
    }
}

struct ReplacementRecovery {
    private let flow: Switchover
    fileprivate init(store: MemoryStore, control: any LauncherControl) {
        // A denial probe also keeps accidental future mutation fail-closed.
        flow = Switchover(store: store, control: control, probes: [RecoveryOnlyProbe()], requiredConsumers: ["recovery-only"])
    }
    func record() throws -> SwitchRecord? { try flow.record() }
    fileprivate func permitsStart() throws -> Bool { try flow.permitsStart() }
    func rollback(approved: Bool, stopNew: () throws -> Void, newIsStopped: () throws -> Bool) throws {
        try flow.rollback(approved: approved, stopNew: stopNew, newIsStopped: newIsStopped)
    }
}
private struct RecoveryOnlyProbe: ReplacementConsumerProbe {
    let identity = "recovery-only", client = "", recipient = "", capability = ""
    func read(resource: String, nonce: String, deadline: Date) throws -> ConsumerReadback { throw MemError.denied }
}

/// Invokes the configured native reader, never --local or a shell. This proves
/// this CLI route only, not a remote relay or another application's before-turn.
final class PinnedLocalCLIConsumer: ReplacementConsumerProbe {
    let identity: String, client: String, recipient: String, capability: String
    private let route: ReplacementConsumerConfiguration.Route
    init(route: ReplacementConsumerConfiguration.Route, identity: String, capability: String) throws {
        self.route = route; self.identity = identity; self.client = route.client
        self.recipient = route.recipient; self.capability = capability
        try validateExecutable()
    }
    private func validateExecutable() throws {
        let url = URL(fileURLWithPath: route.executable)
        let attributes = try FileManager.default.attributesOfItem(atPath: route.executable)
        guard ReplacementComposition.canonical(route.home) == route.home,
              ReplacementComposition.canonical(route.executable) == route.executable,
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 128 * 1024 * 1024,
              FileManager.default.isExecutableFile(atPath: route.executable),
              ReplacementComposition.sha256(try Data(contentsOf: url)) == route.executableSHA256 else {
            throw ReplacementCompositionError.blocked("reviewed_consumer_executable_missing_or_changed")
        }
    }
    func read(resource: String, nonce: String, deadline: Date) throws -> ConsumerReadback {
        guard !nonce.isEmpty, nonce.utf8.count <= 200,
              resource == "macmem://current-context" || resource.range(of: "^macmem://actions/[A-Za-z0-9_-]{1,600}\\.json$", options: .regularExpression) != nil else {
            throw ReplacementCompositionError.blocked("consumer_resource_not_allowed")
        }
        try validateExecutable()
        let remaining = min(2, deadline.timeIntervalSinceNow)
        guard remaining > 0 else { throw ReplacementCompositionError.blocked("consumer_read_timeout") }
        let end = ProcessInfo.processInfo.systemUptime + remaining
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: route.executable)
        process.arguments = ["--home", route.home, "--client", client, "--recipient", recipient] +
            (resource == "macmem://current-context" ? ["current-context"] : ["open", resource])
        // Deliberately do not inherit DYLD, shell, search, or other credentials.
        process.environment = ["MAC_MEM_CAPABILITY": capability, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice // Never surface potentially secret child diagnostics.
        let fd = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw ReplacementCompositionError.blocked("consumer_pipe_unavailable") }
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        do { try process.run() } catch { throw ReplacementCompositionError.blocked("consumer_launch_failed") }
        try? pipe.fileHandleForWriting.close()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        var output = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        var eof = false
        while !eof || process.isRunning {
            guard ProcessInfo.processInfo.systemUptime < end else { throw ReplacementCompositionError.blocked("consumer_read_timeout") }
            let n = Darwin.read(fd, &bytes, bytes.count)
            if n > 0 {
                output.append(contentsOf: bytes.prefix(n))
                guard output.count <= 64_000 else { throw ReplacementCompositionError.blocked("consumer_response_too_large") }
            } else if n == 0 { eof = true }
            else if errno != EAGAIN && errno != EINTR { throw ReplacementCompositionError.blocked("consumer_read_failed") }
            if n <= 0 { usleep(2_000) }
        }
        guard process.terminationStatus == 0, let body = String(data: output, encoding: .utf8) else {
            throw ReplacementCompositionError.blocked("consumer_read_failed")
        }
        try validateExecutable()
        // Bind this fresh process response to the request; core compares the
        // decoded action/context, source revisions and grants independently.
        return ConsumerReadback(nonce: nonce, resource: resource, body: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
