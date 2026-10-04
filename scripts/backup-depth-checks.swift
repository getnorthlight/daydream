// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// A backup holds the whole history, not the first two weeks of it (gold G29, critic extra 5).
//
// A. Export past the old caps: 21,000 moments and 21,000 deletions (each kind of record used to stop at 20,000 rows,
//    64 MiB and eight seconds, so a backup failed after about two weeks of use, or after "Keep history 7 days").
// B. The same through the real helper (mac-mem-backup), as the app runs it: its time, size and reply limits.
// C. Restore puts back 8,000 lost moments through the helper: the preview and the receipt list every moment they add
//    (more than the old 256 KiB reply limit), and every one comes back.
// D. A failed export leaves no half-made folder behind, so trying again with the same name works.
//
// Arg: the built mac-mem-backup. Synthetic stores in a scratch folder only; nothing else is read or written.
import Foundation
import Darwin
@testable import MemoryCore
@testable import BackupRestore

/// The scratch folder (under $TMPDIR when it is set: the check runners point it into their own folder, and
/// Foundation's temporaryDirectory ignores it). Removed before the check exits, pass or fail.
var scratchRoot = URL(fileURLWithPath: "/nonexistent")
func finishScratch(_ code: Int32) -> Never { try? FileManager.default.removeItem(at: scratchRoot); exit(code) }

@main struct BackupDepthChecks {
    static var passes = 0, failures = 0
    static func check(_ value: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if value { passes += 1; print("PASS " + name) } else { failures += 1; print("FAIL " + name + { let d = detail(); return d.isEmpty ? "" : ": " + d }()) }
    }
    /// Runs `body`; a throw is a FAIL for `name` (and every check after it in `body` is skipped).
    static func attempt(_ name: String, _ body: () throws -> Void) {
        do { try body() } catch { check(false, name, "threw \(error)") }
    }
    static func timed<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let start = Date(); defer { print(String(format: "  %@: %.1f s", label, Date().timeIntervalSince(start))) }
        return try body()
    }

    static func main() throws {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count > 1 else { print("usage: backup-depth-checks <mac-mem-backup>"); exit(2) }
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        // The container refuses a linked path component, so the scratch root is a physical path.
        let temp = URL(fileURLWithPath: String(cString: realpath((ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path), nil)!), isDirectory: true)
        let root = temp.appendingPathComponent("daydream-backup-depth-" + UUID().uuidString); scratchRoot = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        func at(_ name: String) -> URL { root.appendingPathComponent(name) }

        let source = try MemoryStore(home: at("history"), writable: true, automaticallySyncSearch: false)
        let now = Date(), count = 21_000, deletions = 21_000, lost = 8_000
        var ids: [String] = []
        try timed("populated \(count) moments and \(deletions) deletions") {
            try source.transaction {
                for n in 0..<count {
                    let id = UUID().uuidString
                    let e = Evidence(id: id, at: iso(now.addingTimeInterval(-Double(n) * 120 - 60)), kind: "window.changed", app: "Notes",
                                     bundle: "com.apple.Notes", title: "Plan budget \(n % 97)", synthetic: true)
                    let body = try json(e)
                    try source.exec("INSERT INTO records VALUES(?,?,?)", [id, body, fingerprint(body)])
                    ids.append(id)
                }
                for _ in 0..<deletions { try source.exec("INSERT INTO tombstones VALUES(?)", [UUID().uuidString]) }
                try source.invalidateDisclosure()
            }
        }

        // A. In process: the core projection and the container.
        attempt("a backup of \(count) moments and \(deletions) deletions is saved") {
            let seal = try timed("export") { try NativeBackup.export(source: source, destination: at("backup"), build: "synthetic", version: "1") }
            check(seal.manifest.audit.counts["records"] == count && seal.manifest.audit.counts["tombstones"] == deletions,
                  "a backup of \(count) moments and \(deletions) deletions is saved, all of them", "\(seal.manifest.audit.counts)")
            let copy = try MemoryStore(home: at("backup"), automaticallySyncSearch: false)
            check(try copy.rows("SELECT count(*) FROM records").first?.first == String(count), "the saved backup holds every moment")
        }

        // B. The real helper, the way the app runs it (its own limits, not the in-process defaults).
        let worker = BackupWorker()
        var helperSeal: BackupSeal?
        attempt("the helper saves a backup of the whole history") {
            let request = try JSONSerialization.data(withJSONObject: ["operation": "export", "source": source.home.path, "destination": at("helper-backup").path,
                                                                      "build": "synthetic", "version": "1"])
            let reply = try timed("helper export") { try worker.run(executable: helper, request: request) }
            let seal = try JSONDecoder().decode(BackupSeal.self, from: reply)
            helperSeal = seal
            check(seal.manifest.audit.counts["records"] == count, "the helper saves a backup of the whole history", "\(seal.manifest.audit.counts)")
        }

        // C. Lose 8,000 moments (the database is damaged, the Mac is new), then restore them through the helper.
        try source.transaction {
            for id in ids.prefix(lost) { try source.exec("DELETE FROM records WHERE id=?", [id]) }
            try source.invalidateDisclosure()
        }
        attempt("restore puts back \(lost) lost moments") {
            guard let seal = helperSeal else { check(false, "restore puts back \(lost) lost moments", "no backup to restore"); return }
            let prepare = try JSONSerialization.data(withJSONObject: ["operation": "prepare", "source": source.home.path, "backup": at("helper-backup").path,
                                                                      "manifestSHA256": seal.manifestSHA256, "destination": at("preview").path])
            let reply = try timed("helper restore preview") { try worker.run(executable: helper, request: prepare) }
            let prepared = try JSONDecoder().decode(BackupPrepared.self, from: reply)
            check(Set(prepared.preview.addedActionIDs) == Set(ids.prefix(lost)), "the restore preview lists exactly the \(lost) lost moments",
                  "\(prepared.preview.addedActionIDs.count) listed")
            print("  preview reply: \(reply.count / 1024) KiB")
            let confirm = try JSONSerialization.data(withJSONObject: ["operation": "confirm", "source": source.home.path,
                                                                      "prepared": JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared)), "confirmed": true])
            let receipt = try JSONDecoder().decode(CanonicalRestoreReceipt.self, from: timed("helper restore") { try worker.run(executable: helper, request: confirm) })
            check(receipt.addedActionIDs.count == lost, "the restore adds all \(lost)", "\(receipt.addedActionIDs.count)")
            check(try source.rows("SELECT count(*) FROM records").first?.first == String(count) && ids.prefix(lost).allSatisfy { (try? source.action($0)) != nil },
                  "restore puts back \(lost) lost moments: every one is in the history again")
        }

        // D. A failed export (here: cancelled) removes the folder it made; the same name works next time.
        attempt("a failed export leaves no folder behind") {
            var calls = 0
            let cancelled = BackupBudget(cancelled: { calls += 1; return calls > 3 })
            let failed = (try? NativeBackup.export(source: source, destination: at("again"), build: "synthetic", version: "1", budget: cancelled)) == nil
            check(failed, "the cancelled export stops")
            check(!FileManager.default.fileExists(atPath: at("again").path), "a failed export leaves no half-made folder behind",
                  (try? FileManager.default.contentsOfDirectory(atPath: at("again").path).sorted().description) ?? "")
            let seal = try NativeBackup.export(source: source, destination: at("again"), build: "synthetic", version: "1")
            check(seal.manifest.audit.counts["records"] == count, "trying again with the same name saves the backup")
        }
        print("\(passes) backup depth checks passed, \(failures) failed. Synthetic histories only.")
        finishScratch(failures == 0 ? 0 : 1)
    }
}
