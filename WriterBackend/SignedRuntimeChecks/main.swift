import Foundation
import Darwin
import CLlamaBridge
import Security

@main struct Checks {
    static func main() async throws {
        let cancelled = TrustProvisioningResult()
        cancelled.finish(.failure(CancellationError()))
        cancelled.finish(.success(()))
        do {
            try await withCheckedThrowingContinuation { cancelled.attach($0) }
            fatalError("pre-attachment cancellation lost")
        } catch is CancellationError {} // Late success cannot undo cancellation.
        let expired = TrustProvisioningResult()
        do {
            try await withCheckedThrowingContinuation { continuation in
                expired.attach(continuation)
                expired.finish(.failure(WriterFailure.trustEvidenceUnavailable))
                expired.finish(.success(()))
            }
            fatalError("timeout replaced by late success")
        } catch WriterFailure.trustEvidenceUnavailable {}
        let retry = TrustProvisioningResult()
        try await withCheckedThrowingContinuation { continuation in
            retry.attach(continuation); retry.finish(.success(())); retry.finish(.failure(WriterFailure.denied))
        }
        // This harness has no app bundle/enrolled identity; must fail before network.
        do {try await RuntimeTrustProvisioning.prepareForExplicitLocalSetup();fatalError("unapproved host provisioned")}
        catch WriterFailure.denied {}
        print("PASS provisioning cancellation/timeout/late callback/independent retry and unapproved host pre-network refusal")
        try regressionChecks()
    }
    static func regressionChecks() throws {
        let cert = String(repeating: "a", count: 64)
        let signature = RuntimeSignatureEvidence(validDeveloperIDChain: true, teamID: "TESTTEAM01", certificateSHA256: cert, identifier: "fixture", hardenedRuntime: true, adHoc: false, entitlementKeys: [])
        let files = CompatibleInstallation.runtimeFiles.enumerated().map { index, file in
            SignedRuntimeManifest.File(name: file.output, upstreamSHA256: file.hash, signedSHA256: String(repeating: String(index + 1), count: 64), signedBytes: 123, signingIdentifier: "fixture")
        }
        let manifest = SignedRuntimeManifest(schema: "daydream-signed-runtime/v1", distributionID: "synthetic-only", upstreamArchiveSHA256: WriterCandidates.llamaARM64.sha256, teamID: signature.teamID, certificateSHA256: cert, files: files)
        let observed = Dictionary(uniqueKeysWithValues: files.map { ($0.name, (hash: $0.signedSHA256, bytes: $0.signedBytes, signature: signature)) })
        try SignedRuntimePolicy.check(manifest, host: signature, observed: observed)
        let rebuiltFiles=MacOS15Runtime.files.enumerated().map {index,file in SignedRuntimeManifest.File(name:file.name,upstreamSHA256:file.hash,signedSHA256:String(repeating:String(index+1),count:64),signedBytes:123,signingIdentifier:"fixture")}
        let rebuilt=SignedRuntimeManifest(schema:MacOS15Runtime.signedSchema,distributionID:"synthetic-macos15",upstreamArchiveSHA256:MacOS15Runtime.archiveSHA256,teamID:signature.teamID,certificateSHA256:cert,files:rebuiltFiles)
        let rebuiltObserved=Dictionary(uniqueKeysWithValues:rebuiltFiles.map {($0.name,(hash:$0.signedSHA256,bytes:$0.signedBytes,signature:signature))})
        try SignedRuntimePolicy.check(rebuilt,host:signature,observed:rebuiltObserved)
        precondition(MacOS15Runtime.supports(osMajor:15,architecture:"arm64") && !MacOS15Runtime.supports(osMajor:14,architecture:"arm64") && !MacOS15Runtime.supports(osMajor:15,architecture:"x86_64"))
        // Exactly one compiled pin: the dead 2026-09-14 trial entry until the signed public runtime
        // (scripts/writer_payload.py ID) replaces it in one line. Its value must be a lowercase SHA-256.
        precondition(SignedRuntimePolicy.approvedManifestSHA256.count == 1)
        let (enrolledID, enrolledHash) = SignedRuntimePolicy.approvedManifestSHA256.first!
        let knownEnrollments = ["daydream-qwen35-b9723-macos15-20260914", "daydream-qwen35-b9723-macos15-v2"]
        precondition(knownEnrollments.contains(enrolledID) && SignedRuntimeLoader.validID(enrolledID))
        precondition(enrolledHash.count == 64 && enrolledHash.allSatisfy { "0123456789abcdef".contains($0) })
        precondition(enrolledID != knownEnrollments[0] || enrolledHash == "f96202ce0b1d60476d0b80c588278c9d8abf65afacfb29a52e6b0b5973b847a9")
        precondition(SignedRuntimePolicy.isApproved(distributionID: enrolledID, manifestSHA256: enrolledHash))
        precondition(!SignedRuntimePolicy.isApproved(distributionID: enrolledID, manifestSHA256: cert))
        precondition(!SignedRuntimePolicy.isApproved(distributionID: "synthetic-macos15", manifestSHA256: enrolledHash))
        if CommandLine.arguments.count == 3 {
            let data = try BoundedRuntimeFile.read(URL(fileURLWithPath: CommandLine.arguments[1]))
            let actual = try RuntimeManifestReader.read(data)
            precondition(SignedRuntimePolicy.isApproved(distributionID: actual.distributionID, manifestSHA256: SignedRuntimeLoader.digest(data)))
            let allowed = Set(actual.files.map(\.name))
            for file in actual.files {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(file.name))
                precondition(SignedRuntimeLoader.digest(bytes) == file.signedSHA256 && Int64(bytes.count) == file.signedBytes)
                try RuntimeMachO.check(bytes, allowed: allowed)
            }
            print("PASS actual enrolled manifest and seven production Mach-O parser checks; no dlopen")
        }
        var count = 1
        func deny(_ body: () throws -> Void) {
            do { try body(); fatalError("unexpected allow") } catch { count += 1 }
        }
        var mixed=rebuilt;mixed.upstreamArchiveSHA256=WriterCandidates.llamaARM64.sha256
        deny {try SignedRuntimePolicy.check(mixed,host:signature,observed:rebuiltObserved)}
        mixed=rebuilt;mixed.files[0].upstreamSHA256=CompatibleInstallation.runtimeFiles[0].hash
        deny {try SignedRuntimePolicy.check(mixed,host:signature,observed:rebuiltObserved)}
        print("PASS exact reviewed enrollment; wrong hash/ID denied; synthetic v2 policy and legacy mixing checks; no trusted load")
        for mutation in 0..<7 {
            var value = manifest
            switch mutation {
            case 0: value.schema = "upstream-v1"
            case 1: value.upstreamArchiveSHA256 = cert
            case 2: value.files.removeLast()
            case 3: value.files.append(value.files[0])
            case 4: value.files[0].upstreamSHA256 = cert
            case 5: value.files[0].signedSHA256 = cert
            default: value.files[0].signedBytes += 1
            }
            deny { try SignedRuntimePolicy.check(value, host: signature, observed: observed) }
        }
        for mutation in 0..<7 {
            var bad = signature
            switch mutation {
            case 0: bad.validDeveloperIDChain = false
            case 1: bad.adHoc = true
            case 2: bad.hardenedRuntime = false
            case 3: bad.teamID = "OTHERTEAM1"
            case 4: bad.certificateSHA256 = String(repeating: "b", count: 64)
            case 5: bad.identifier = "wrong"
            default: bad.entitlementKeys = ["com.apple.security.cs.disable-library-validation"]
            }
            var values = observed; values[files[0].name]!.signature = bad
            deny { try SignedRuntimePolicy.check(manifest, host: signature, observed: values) }
        }
        for key in ["com.apple.security.cs.allow-jit", "com.apple.security.cs.allow-unsigned-executable-memory", "com.apple.security.cs.disable-library-validation", "com.apple.security.get-task-allow"] {
            var host = signature; host.entitlementKeys = [key]
            deny { try SignedRuntimePolicy.check(manifest, host: host, observed: observed) }
        }
        precondition(!SignedRuntimePolicy.isApproved(distributionID: manifest.distributionID, manifestSHA256: cert))
        precondition(!WriterRuntimeAdmission.requiresSignedDistribution(adHoc:true,hasTeam:false))
        precondition(WriterRuntimeAdmission.requiresSignedDistribution(adHoc:false,hasTeam:true))
        precondition(WriterRuntimeAdmission.requiresSignedDistribution(adHoc:true,hasTeam:true))
        _ = try RuntimeManifestReader.read(JSONEncoder().encode(manifest)); count += 1
        for json in ["{\"schema\":1,\"schema\":2}", "{\"schema\":1,\"\\u0073chema\":2}", "{\"files\":[{\"name\":1,\"name\":2}]}", "{}{}", "{\"a\":[[[[[[[[[[0]]]]]]]]]]}"] {
            deny { _ = try RuntimeManifestReader.read(Data(json.utf8)) }
        }
        deny { _ = try RuntimeManifestReader.read(Data(repeating: 32, count: 32_769)) }
        deny { _ = try SignedRuntimeLoader.validate(model: URL(fileURLWithPath: "/nonexistent"), distributionID: "synthetic-only") }
        deny { try RuntimeMachO.check(Data([0,1,2]), allowed: []) }
        deny { try RuntimeMachO.check(Data(repeating: 255, count: 64), allowed: []) }
        precondition(!SignedRuntimeLoader.validID("../escape"))
        // Reproduces old 0775 mask failure; new exact anchor policy accepts only root/admin.
        precondition(0o775 & 0o022 != 0)
        precondition(SignedRuntimeLoader.permissionsAllowed(path: "/Applications", uid: 0, gid: 80, mode: 0o775))
        precondition(!SignedRuntimeLoader.permissionsAllowed(path: "/Applications", uid: 501, gid: 80, mode: 0o775))
        precondition(!SignedRuntimeLoader.permissionsAllowed(path: "/Applications", uid: 0, gid: 80, mode: 0o777))
        precondition(!SignedRuntimeLoader.permissionsAllowed(path: "/untrusted", uid: 0, gid: 80, mode: 0o775))
        let fixture = URL(fileURLWithPath: "/private/tmp/writer-file-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {try? FileManager.default.removeItem(at: fixture)}
        let regular = fixture.appendingPathComponent("regular")
        try Data("valid".utf8).write(to: regular)
        let readBack = try BoundedRuntimeFile.read(regular); precondition(readBack == Data("valid".utf8))
        let fifo = fixture.appendingPathComponent("fifo"); precondition(mkfifo(fifo.path, 0o600) == 0)
        deny {_ = try BoundedRuntimeFile.read(fifo)}
        deny {_ = try BoundedRuntimeFile.read(fixture)}
        let link = fixture.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        deny {_ = try BoundedRuntimeFile.read(link)}
        try Data(repeating: 1, count: 32_769).write(to: regular)
        deny {_ = try BoundedRuntimeFile.read(regular)}
        try Data("truncate".utf8).write(to: regular)
        deny {_ = try BoundedRuntimeFile.read(regular, opened: {_ in try Data().write(to: regular)})}
        let cancelled = LoadAttempt(); cancelled.cancel()
        deny {try cancelled.check()}
        let runtime = wr_create()!; defer {wr_destroy(runtime)}
        precondition(wr_load_attempt(runtime, "/missing", "/missing", cancelled.ticket, nil, nil) == 5)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let first = LoadAttempt()
        first.preflight = {entered.signal(); release.wait(); throw WriterFailure.denied}
        DispatchQueue.global().async {
            _ = wr_load_attempt(runtime, "/missing", "/missing", first.ticket, LoadAttempt.callback, Unmanaged.passUnretained(first).toOpaque())
            finished.signal()
        }
        precondition(entered.wait(timeout: .now() + 2) == .success)
        let waiting = LoadAttempt(); let other = wr_create()!; defer {wr_destroy(other)}
        let waiterDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            precondition(wr_load_attempt(other, "/missing", "/missing", waiting.ticket, nil, nil) == 5)
            waiterDone.signal()
        }
        let waitDeadline = Date().addingTimeInterval(2)
        while wr_load_ticket_phase(waiting.ticket) != 1 && Date() < waitDeadline {Thread.sleep(forTimeInterval: 0.001)}
        precondition(wr_load_ticket_phase(waiting.ticket) == 1)
        waiting.cancel()
        precondition(waiterDone.wait(timeout: .now() + 2) == .success)
        release.signal(); precondition(finished.wait(timeout: .now() + 2) == .success)
        let retry = LoadAttempt(); retry.preflight = {throw WriterFailure.denied}
        precondition(wr_load_attempt(other, "/missing", "/missing", retry.ticket, LoadAttempt.callback, Unmanaged.passUnretained(retry).toOpaque()) == 12)
        let hashAttempt = LoadAttempt(); var chunks = 0
        try Data(repeating: 7, count: 2_097_152).write(to: regular)
        deny {try CompatibleInstallation.verify(regular, bytes: 2_097_152, hash: cert, checkCancellation: {chunks += 1; hashAttempt.cancel(); try hashAttempt.check()})}
        precondition(chunks == 1)
        let imageA = fixture.appendingPathComponent("libggml.0.dylib")
        try Data([1]).write(to: imageA)
        let imageBDir = fixture.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: imageBDir, withIntermediateDirectories: false)
        let imageB = imageBDir.appendingPathComponent("libggml.0.dylib"); try Data([1]).write(to: imageB)
        let intended = fixture.appendingPathComponent("libllama.0.dylib")
        precondition(wr_runtime_image_conflicts(imageA.path, intended.path) == 0)
        precondition(wr_runtime_image_conflicts(imageB.path, intended.path) == 1)
        precondition(wr_runtime_image_conflicts("/usr/lib/libSystem.B.dylib", intended.path) == 0)
        if case .trustEvidenceUnavailable = RuntimeSignatureVerifier.trustFailure(nil) {} else {fatalError("missing evidence must be recoverable")}
        if case .trustEvidenceUnavailable = RuntimeSignatureVerifier.trustFailure(Int(errSecIncompleteCertRevocationCheck)) {} else {fatalError("expired/missing response must not allow")}
        if case .denied = RuntimeSignatureVerifier.trustFailure(Int(errSecCertificateRevoked)) {} else {fatalError("revoked must deny")}
        print("PASS descriptor FIFO/directory/symlink/oversize/truncation/regular checks, anchor policy, per-load prestart/hash/mutex cancellation and independent retry preflight. No dlopen in these fixtures.")
        print("PASS \(count + 1) synthetic manifest/signature-policy/closed-loader checks. No trusted artifact loading.")
        if CommandLine.arguments.count == 2 {
            let runtime = URL(fileURLWithPath: CommandLine.arguments[1])
            for file in CompatibleInstallation.runtimeFiles {
                let path = runtime.appendingPathComponent(file.output)
                try CompatibleInstallation.verify(path, bytes: Int64(file.bytes), hash: file.hash)
                try RuntimeMachO.check(Data(contentsOf: path), allowed: Set(CompatibleInstallation.runtimeFiles.map(\.output)), allowUpstreamRpath: true)
            }
            deny {try RuntimeMachO.check(Data(contentsOf: runtime.appendingPathComponent("libllama.0.dylib")), allowed: Set(CompatibleInstallation.runtimeFiles.map(\.output)))}
            var changed = try Data(contentsOf: runtime.appendingPathComponent("libllama.0.dylib"))
            if let range = changed.range(of: Data("@loader_path".utf8)) {
                changed.replaceSubrange(range, with: Data("@other__path".utf8))
                deny { try RuntimeMachO.check(changed, allowed: Set(CompatibleInstallation.runtimeFiles.map(\.output))) }
            } else { fatalError("expected local rpath") }
            deny { _ = try RuntimeSignatureVerifier.inspect(runtime.appendingPathComponent("libllama.0.dylib")) }
            print("PASS actual seven pinned Mach-O audits, in-memory altered-rpath refusal and Security.framework refusal of upstream ad-hoc dylib. Read-only inspection, no dlopen or identity access.")
        }
    }
}
