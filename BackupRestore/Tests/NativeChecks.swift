import Foundation
import Darwin
@testable import MemoryCore
@testable import BackupRestore

@main struct NativeChecks {
    static var count = 0
    static func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1; print("PASS " + label) }
    static func reject(_ label: String, _ work: () throws -> Void) {
        do { try work(); fatalError("Unexpected success: " + label) } catch { check(true, label) }
    }
    static func main() throws {
        setbuf(stdout, nil)
        // Entire test tree stays inside the authorized module, synthetic only.
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("BackupRestore/.build/check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        func at(_ name: String) -> URL { root.appendingPathComponent(name) }
        let source = try MemoryStore(home: at("source"), writable: true, automaticallySyncSearch: false)
        let now = Date()
        try source.exec("PRAGMA journal_mode=WAL")
        for i in 0..<4 { _ = try source.ingest(Evidence(id: "a\(i)", at: iso(now), kind: "window.changed", app: "Notes", title: "Synthetic backup", synthetic: true), now: now) }
        _ = try source.correctAction(id: "a0", text: "Persistent correction", expectedRevision: source.action("a0")!.revision)
        try source.exec("INSERT INTO grants VALUES('fixture-grant','secret-not-exported')")
        try source.exec("INSERT INTO metadata VALUES('fixture-secret','secret-not-exported')")
        let backup = at("backup")
        let seal = try NativeBackup.export(source: source, destination: backup, build: "synthetic", version: "1")
        check(seal.manifest.audit.counts["records"] == 4, "actual canonical WAL projection")
        let clean = try MemoryStore(home: backup, automaticallySyncSearch: false)
        check(try clean.rows("SELECT * FROM grants").isEmpty, "no grants in backup")
        check(try clean.rows("SELECT * FROM metadata WHERE id='fixture-secret'").isEmpty, "no runtime secrets")
        check(try clean.action("a0")!.description.contains("Persistent correction"), "persistent correction survives")
        reject("exclusive destination") { _ = try NativeBackup.export(source: source, destination: backup, build: "test", version: "1") }
        reject("wrong manifest pin") { _ = try NativeBackup.prepare(source: source, backup: backup, manifestSHA256: "bad", staging: at("wrong-pin")) }
        try source.delete("a1")
        let original = try source.rows("SELECT body FROM records WHERE id='a0'")
        _ = try source.correctAction(id: "a0", text: "Current correction wins", expectedRevision: source.action("a0")!.revision)
        try source.exec("DELETE FROM records WHERE id='a3'"); try source.invalidateDisclosure()
        let prepared = try NativeBackup.prepare(source: source, backup: backup, manifestSHA256: seal.manifestSHA256, staging: at("preview"))
        check(prepared.preview.addedActionIDs == ["a3"], "exact preview reconciles current deletion")
        let corrected = try MemoryStore(home: at("preview"), automaticallySyncSearch: false)
        check(try corrected.action("a0")!.description.contains("Current correction wins"), "current correction replaces older backup presentation")
        check(try corrected.rows("SELECT body FROM records WHERE id='a0'") == original, "reconciliation preserves immutable original")
        let sidecar = try NativeBackup.prepare(source: source, backup: backup, manifestSHA256: seal.manifestSHA256, staging: at("sidecar"))
        try Data().write(to: at("sidecar/memory.sqlite-wal"))
        reject("unverified SQLite sidecar refused before reopen") { _ = try NativeBackup.confirm(source: source, prepared: sidecar, confirmed: true) }
        let changed = try NativeBackup.prepare(source: source, backup: backup, manifestSHA256: seal.manifestSHA256, staging: at("changed-preview"))
        try Data("tampered candidate".utf8).write(to: at("changed-preview/memory.sqlite"))
        reject("candidate bytes pinned before reopening SQLite") { _ = try NativeBackup.confirm(source: source, prepared: changed, confirmed: true) }
        reject("explicit confirmation required") { _ = try NativeBackup.confirm(source: source, prepared: prepared, confirmed: false) }
        _ = try source.ingest(Evidence(id: "late", at: iso(now), kind: "window.changed", app: "Notes", synthetic: true))
        reject("stale preview cannot merge") { _ = try NativeBackup.confirm(source: source, prepared: prepared, confirmed: true) }
        let fresh = try NativeBackup.prepare(source: source, backup: backup, manifestSHA256: seal.manifestSHA256, staging: at("fresh"))
        try source.exec("CREATE TRIGGER reject_restore BEFORE INSERT ON records WHEN NEW.id='a3' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
        reject("transaction failure rolls back") { _ = try NativeBackup.confirm(source: source, prepared: fresh, confirmed: true) }
        check(try source.action("a3") == nil, "failed merge leaves current records intact")
        try source.exec("DROP TRIGGER reject_restore")
        let receipt = try NativeBackup.confirm(source: source, prepared: fresh, confirmed: true)
        check(receipt.addedActionIDs == ["a3"], "actual canonical merge round trip")
        check(try NativeBackup.confirm(source: source, prepared: fresh, confirmed: true).revision == receipt.revision, "lost confirmation reply retries existing core receipt")
        check(try source.action("a1") == nil && source.action("late") != nil, "deleted evidence stays deleted and new evidence survives")
        check(try source.captureStatus()["state"] == "off", "restore leaves recording OFF")
        check(try source.rows("SELECT * FROM grants").isEmpty, "restore grants remain absent")
        check(try Data(contentsOf: backup.appendingPathComponent("manifest.json")) == NativeBackup.encoded(seal.manifest), "original backup unchanged")
        func variant(_ name: String, change: (URL, inout BackupManifest) throws -> Void) throws -> (URL, String) {
            let dest = at(name); try FileManager.default.copyItem(at: backup, to: dest)
            var manifest = seal.manifest; try change(dest, &manifest)
            let bytes = try NativeBackup.encoded(manifest); try bytes.write(to: dest.appendingPathComponent("manifest.json"))
            return (dest, NativeBackup.hash(bytes))
        }
        for name in ["tamper", "traversal", "oversize", "missing", "extra", "symlink", "hardlink", "schema"] {
            let (bad, pin) = try variant(name) { dir, manifest in
                let db = dir.appendingPathComponent("memory.sqlite")
                switch name {
                case "tamper": try Data("not SQLite".utf8).write(to: db)
                case "traversal": manifest.files[0].name = "../memory.sqlite"
                case "oversize": manifest.files[0].bytes = BackupLimits().bytes+1
                case "missing": try FileManager.default.removeItem(at: db)
                case "extra": try Data().write(to: dir.appendingPathComponent("unexpected"))
                case "symlink": try FileManager.default.removeItem(at: db); try FileManager.default.createSymbolicLink(at: db, withDestinationURL: backup.appendingPathComponent("memory.sqlite"))
                case "hardlink": try FileManager.default.removeItem(at: db); try FileManager.default.linkItem(at: backup.appendingPathComponent("memory.sqlite"), to: db)
                default: manifest.audit.schema = "unknown"
                }
            }
            reject(name + " rejected before staging") { _ = try NativeBackup.prepare(source: source, backup: bad, manifestSHA256: pin, staging: at("rejected-"+name)) }
            check(!FileManager.default.fileExists(atPath: at("rejected-"+name).path), name + " did not open untrusted database")
            // Remove this test's hardlink so the original remains single-link.
            if name == "hardlink" { try FileManager.default.removeItem(at: bad.appendingPathComponent("memory.sqlite")) }
        }
        var calls = 0
        let cancellation = BackupBudget(cancelled: { calls += 1; return calls > 3 })
        reject("interrupted export") { _ = try NativeBackup.export(source: source, destination: at("interrupted"), build: "test", version: "1", budget: cancellation) }
        check(!FileManager.default.fileExists(atPath: at("interrupted/manifest.json").path), "interrupted copy has no completion seal")
        _ = try NativeBackup.export(source: source, destination: at("retry"), build: "test", version: "1")
        check(true, "retry uses fresh destination")

        // Actual canonical attachment rows and owned hash-addressed content.
        try source.exec("CREATE TABLE IF NOT EXISTS migration_originals(id TEXT PRIMARY KEY, body TEXT NOT NULL, raw_hash TEXT NOT NULL, policy_hash TEXT NOT NULL)")
        try source.exec("CREATE TABLE IF NOT EXISTS migration_batches(id TEXT PRIMARY KEY, policy_hash TEXT NOT NULL, next INTEGER NOT NULL)")
        let bytes = Data("synthetic attachment".utf8), digest = NativeBackup.hash(bytes)
        let owned = source.home.appendingPathComponent("migration-attachments")
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try bytes.write(to: owned.appendingPathComponent(digest))
        let evidence = Evidence(id: "asset", at: iso(now), kind: "window.changed", app: "Notes", synthetic: true)
        _ = try source.ingest(evidence)
        let entry = MigrationEntry(id: "asset", sourceID: "original", family: "collector-event", format: "history-segment-v1", at: iso(now), epochNanos: "0", timezone: "UTC", raw: "{}", rawSHA256: fingerprint("{}"), deleted: false, evidence: evidence, summary: nil, end: nil, attachments: [.init(path: "attachments/"+digest, sha256: digest, bytes: bytes.count)])
        try source.exec("INSERT INTO migration_originals VALUES(?,?,?,?)", [entry.id, json(entry), entry.rawSHA256, "synthetic-policy"])
        let assets = try NativeBackup.export(source: source, destination: at("assets"), build: "test", version: "1")
        check(assets.manifest.audit.assets == [digest], "fenced canonical asset export")
        try source.exec("DELETE FROM migration_originals WHERE id='asset'"); try source.exec("DELETE FROM records WHERE id='asset'"); try source.invalidateDisclosure()
        try FileManager.default.removeItem(at: owned.appendingPathComponent(digest))
        let assetPreview = try NativeBackup.prepare(source: source, backup: at("assets"), manifestSHA256: assets.manifestSHA256, staging: at("asset-preview"))
        _ = try NativeBackup.confirm(source: source, prepared: assetPreview, confirmed: true)
        check(try Data(contentsOf: owned.appendingPathComponent(digest)) == bytes, "native asset stage and core adoption")
        try FileManager.default.removeItem(at: at("assets/asset-"+digest))
        reject("missing required asset") { _ = try NativeBackup.prepare(source: source, backup: at("assets"), manifestSHA256: assets.manifestSHA256, staging: at("missing-asset")) }

        let worker = BackupWorker(), executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let request = try JSONSerialization.data(withJSONObject: ["operation": "export", "source": source.home.path, "destination": at("worker-export").path, "build": "synthetic", "version": "1"])
        let reply = try worker.run(executable: executable, request: request)
        let workerSeal = try JSONDecoder().decode(BackupSeal.self, from: reply)
        check(workerSeal.manifest.audit.capture == "off", "runnable native helper uses actual core")
        reject("worker cancellation waits for exit") { _ = try worker.run(executable: executable, request: request, cancelled: { true }) }
        reject("worker hard deadline") { _ = try worker.run(executable: executable, request: request, seconds: 0.000001) }
        try source.exec("BEGIN IMMEDIATE")
        let blocked = try JSONSerialization.data(withJSONObject: ["operation": "export", "source": source.home.path, "destination": at("blocked-worker").path, "build": "synthetic", "version": "1"])
        let start = ProcessInfo.processInfo.systemUptime
        reject("blocking canonical SQLite work killed within budget") { _ = try worker.run(executable: executable, request: blocked, seconds: 0.1) }
        check(ProcessInfo.processInfo.systemUptime-start < 1, "hard timeout does not wait for SQLite busy timeout")
        try source.exec("ROLLBACK")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            _ = try? worker.run(executable: executable, request: blocked, cancelled: { entered.signal(); release.wait(); return true })
        }
        guard entered.wait(timeout: .now()+3) == .success else { fatalError("worker did not enter") }
        reject("concurrent caller cannot steal worker lease") { _ = try worker.run(executable: executable, request: request) }
        release.signal()
        check(done.wait(timeout: .now()+3) == .success, "cancelled child exits before lease released")
        let retryRequest = try JSONSerialization.data(withJSONObject: ["operation": "export", "source": source.home.path, "destination": at("worker-retry").path, "build": "synthetic", "version": "1"])
        _ = try worker.run(executable: executable, request: retryRequest)
        check(true, "worker lease recovers after process termination")
        try source.exec("DELETE FROM records WHERE id='a2'"); try source.invalidateDisclosure()
        let prepareRequest = try JSONSerialization.data(withJSONObject: ["operation": "prepare", "source": source.home.path, "backup": at("worker-export").path, "manifestSHA256": workerSeal.manifestSHA256, "destination": at("worker-preview").path])
        let workerPrepared = try JSONDecoder().decode(BackupPrepared.self, from: worker.run(executable: executable, request: prepareRequest))
        check(workerPrepared.preview.addedActionIDs == ["a2"], "helper prepare returns canonical exact preview")
        let preparedObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(workerPrepared))
        let confirmRequest = try JSONSerialization.data(withJSONObject: ["operation": "confirm", "source": source.home.path, "prepared": preparedObject, "confirmed": true])
        let workerReceipt = try JSONDecoder().decode(CanonicalRestoreReceipt.self, from: worker.run(executable: executable, request: confirmRequest))
        check(try workerReceipt.addedActionIDs == ["a2"] && source.action("a2") != nil, "helper confirm merges into actual core")
        let retriedReceipt = try JSONDecoder().decode(CanonicalRestoreReceipt.self, from: worker.run(executable: executable, request: confirmRequest))
        check(retriedReceipt.revision == workerReceipt.revision, "helper confirmation retry recovers receipt")
        print("\(count) native backup checks passed")
    }
}
