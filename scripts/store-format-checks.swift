// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// Two ways a history used to fail without end, on synthetic stores in a scratch folder:
//
// A. (gold G61) A history a newer DayDream saved is refused with words that say so, and left as it was; it is never
//    read by rules that don't fit it. Older histories open as ever and are marked with this build's format.
// B. (gold G62) A file the attachment folder can't vouch for (an interrupted restore's, a stray one) never fails the
//    summaries or a deletion that already committed. It stays where it is for review; nothing is removed that
//    shouldn't be, and a file that should be removed still is.
//
// Uses only what every build has, so it runs against older builds too.
import Foundation
import CryptoKit
import CSQLite
@testable import MemoryCore

/// The scratch folder: under $TMPDIR when it is set (the check runners point it into their own folder, and
/// Foundation's temporaryDirectory ignores it), else the system's. Removed before the check exits, pass or fail.
var scratchRoot = URL(fileURLWithPath: "/nonexistent")
func scratch(_ prefix: String) -> URL {
    let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent(prefix + UUID().uuidString)
}
func finishScratch(_ code: Int32) -> Never { try? FileManager.default.removeItem(at: scratchRoot); exit(code) }

@main struct StoreFormatChecks {
    static var passes = 0, failures = 0
    static func check(_ value: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if value { passes += 1; print("PASS " + name) } else { failures += 1; print("FAIL " + name + { let d = detail(); return d.isEmpty ? "" : ": " + d }()) }
    }
    static func sha(_ url: URL) -> String {
        SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    /// A raw SQLite statement on the file, outside DayDream (as another build would).
    static func raw(_ file: URL, _ sql: String) -> String? {
        var db: OpaquePointer?, stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt); sqlite3_close(db) }
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return "" }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }

    static func main() throws {
        setbuf(stdout, nil)
        let root = scratch("daydream-store-format-"); scratchRoot = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try format(root.appendingPathComponent("format"))
        try attachments(root.appendingPathComponent("attachments"))
        print("\(passes) store format checks passed, \(failures) failed. Synthetic histories only.")
        finishScratch(failures == 0 ? 0 : 1)
    }

    // MARK: A. The format

    static func format(_ root: URL) throws {
        let now = Date()
        // A new history is marked with this build's format.
        let fresh = root.appendingPathComponent("fresh")
        _ = try MemoryStore(home: fresh, writable: true, automaticallySyncSearch: false)
        check(raw(fresh.appendingPathComponent("memory.sqlite"), "PRAGMA user_version") == "1", "a new history is marked with format 1",
              raw(fresh.appendingPathComponent("memory.sqlite"), "PRAGMA user_version") ?? "nil")

        // A history from before the mark (0) opens read-only as it is, and a writable open marks it.
        let older = root.appendingPathComponent("older")
        do {
            let store = try MemoryStore(home: older, writable: true, automaticallySyncSearch: false)
            _ = try store.ingest(Evidence(id: "old-1", at: iso(now), kind: "window.changed", app: "Notes", title: "Older build", synthetic: true), now: now)
        }
        _ = raw(older.appendingPathComponent("memory.sqlite"), "PRAGMA user_version=0")
        let reader = try? MemoryStore(home: older)
        check((try? reader?.action("old-1", now: now)) != nil, "a history from an older build opens and reads (read-only)")
        check(raw(older.appendingPathComponent("memory.sqlite"), "PRAGMA user_version") == "0", "…and a read-only open changes nothing in it")
        _ = try MemoryStore(home: older, writable: true, automaticallySyncSearch: false)
        check(raw(older.appendingPathComponent("memory.sqlite"), "PRAGMA user_version") == "1", "a writable open marks an older history with format 1")

        // A history a newer DayDream saved (format 2): refused, clearly, and left exactly as it was.
        let newer = root.appendingPathComponent("newer")
        do {
            let store = try MemoryStore(home: newer, writable: true, automaticallySyncSearch: false)
            _ = try store.ingest(Evidence(id: "new-1", at: iso(now), kind: "window.changed", app: "Notes", title: "Newer build", synthetic: true), now: now)
        }
        let file = newer.appendingPathComponent("memory.sqlite")
        _ = raw(file, "PRAGMA user_version=2")
        let before = sha(file)
        for writable in [false, true] {
            let label = writable ? "the app's writable open" : "a reader's open (AI apps, the CLI)"
            do {
                _ = try MemoryStore(home: newer, writable: writable, automaticallySyncSearch: false)
                check(false, "\(label) refuses a history a newer DayDream saved", "it opened")
            } catch {
                let words = AssistantCatalog.errorMessage(error)
                check(words.contains("newer DayDream") && words.contains("Update DayDream"), "\(label) refuses a history a newer DayDream saved, and says to update", words)
                check(!words.contains(root.path) && !words.lowercased().contains("sqlite"), "…in plain words, with no path", words)
            }
        }
        check(sha(file) == before && raw(file, "PRAGMA user_version") == "2", "the newer history is left exactly as it was")
    }

    // MARK: B. The attachment folder

    static func attachments(_ root: URL) throws {
        let now = Date()
        func store(_ name: String, events: Int) throws -> MemoryStore {
            let s = try MemoryStore(home: root.appendingPathComponent(name), writable: true, automaticallySyncSearch: false)
            for n in 0..<events {
                _ = try s.ingest(Evidence(id: "\(name)-\(n)", at: iso(now.addingTimeInterval(-Double(n) - 5)), kind: "window.changed", app: "Notes",
                                          title: "Plan \(n)", synthetic: true), now: now)
            }
            return s
        }
        func summaries(_ s: MemoryStore) -> Int { Int((try? s.rows("SELECT count(*) FROM summaries"))?.first?.first ?? "") ?? -1 }

        // No ledger, one untracked file (the state an interrupted restore leaves).
        let untracked = try store("untracked", events: 3)
        let folder = untracked.home.appendingPathComponent("migration-attachments")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stray = folder.appendingPathComponent("untracked-fixture")
        try Data("keep this synthetic file".utf8).write(to: stray)
        do {
            let written = try untracked.writePending(now: now)
            check(written == 3 && summaries(untracked) == 3, "summaries are written though the attachment folder holds a file it can't vouch for", "\(written)")
        } catch { check(false, "summaries are written though the attachment folder holds a file it can't vouch for", "writePending threw \(error)") }
        do {
            let again = try untracked.writePending(now: now)
            check(again == 0, "…and the next pass is quiet, not a failure every time")
        } catch { check(false, "…and the next pass is quiet, not a failure every time", "threw \(error)") }
        do {
            try untracked.delete("untracked-1")
            check(try untracked.action("untracked-1", now: now) == nil, "deleting a moment works and says so (no \"Deletion failed\" after it worked)")
        } catch { check(false, "deleting a moment works and says so (no \"Deletion failed\" after it worked)", "delete threw \(error) after it committed") }
        check((try? String(contentsOf: stray, encoding: .utf8)) == "keep this synthetic file", "the file stays where it is, for review")
        check((try? untracked.cleanupMigrationAttachments()) == nil, "the strict cleanup still refuses to guess about it")

        // A ledger, and a file named like an attachment whose bytes don't match its name.
        let mismatch = try store("mismatch", events: 2)
        try mismatch.exec("CREATE TABLE IF NOT EXISTS migration_originals(id TEXT PRIMARY KEY, body TEXT NOT NULL, raw_hash TEXT NOT NULL, policy_hash TEXT NOT NULL)")
        let assets = mismatch.home.appendingPathComponent("migration-attachments")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let odd = assets.appendingPathComponent(String(repeating: "ab", count: 32))
        try Data("not what the name says".utf8).write(to: odd)
        let orphanBytes = Data("an attachment nothing refers to any more".utf8)
        let orphan = assets.appendingPathComponent(SHA256.hash(data: orphanBytes).map { String(format: "%02x", $0) }.joined())
        do {
            let written = try mismatch.writePending(now: now)
            check(written == 2, "summaries are written though an attachment's bytes don't match its name", "\(written)")
        } catch { check(false, "summaries are written though an attachment's bytes don't match its name", "writePending threw \(error)") }
        check(FileManager.default.fileExists(atPath: odd.path), "the mismatched file is kept for review")
        try FileManager.default.removeItem(at: odd)
        try orphanBytes.write(to: orphan)
        _ = try? mismatch.writePending(now: now)
        check(!FileManager.default.fileExists(atPath: orphan.path), "an attachment nothing refers to is still removed when its bytes match")
    }
}
