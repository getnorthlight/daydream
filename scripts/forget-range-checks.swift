import Foundation
import Darwin
@testable import MemoryCore

/// Forget a time range, the search index side: after a range commit the next index sync removes every forgotten
/// action's document and its ledger row, and keeps the rest. A fake Typesense in memory; a synthetic store only.
/// (The store side lives in Checks/ForgetRangeChecks.swift, run by MacMemChecks.)
private final class FakeIndex: TypesenseTransport {
    var docs = [String: SearchDocument](); var exists = false
    func request(_ method: String, _ path: String, query: [URLQueryItem], body: Data?, deadline: Date) throws -> TypesenseResponse {
        func response(_ status: Int, _ object: Any) throws -> TypesenseResponse { TypesenseResponse(status: status, data: try JSONSerialization.data(withJSONObject: object)) }
        if path == "/collections" { exists = true; return try response(201, [:]) }
        if path.hasSuffix("/documents/import") {
            let rows = String(decoding: body!, as: UTF8.self).split(separator: "\n")
            for row in rows { let doc = try JSONDecoder().decode(SearchDocument.self, from: Data(row.utf8)); docs[doc.id] = doc }
            return TypesenseResponse(status: 200, data: Data(rows.map { _ in "{\"success\":true}" }.joined(separator: "\n").utf8))
        }
        if path.hasSuffix("/documents/search") {
            // Every document answers, as a stale index would: search must drop the forgotten ones itself.
            return try response(200, ["found": docs.count, "hits": docs.values.map { ["document": ["source_id": $0.source_id, "revision": $0.revision, "summary": "UNTRUSTED_INDEX_SNIPPET"]] }])
        }
        if path.contains("/documents/") { docs.removeValue(forKey: String(path.split(separator: "/").last!)); return try response(200, [:]) }
        return try response(exists ? 200 : 404, [:])
    }
}

@main struct ForgetRangeSearchChecks {
    static var count = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { throw MemError.invalid("FAIL: " + name) }
        count += 1; print("PASS: " + name)
    }
    static func main() throws {
        setbuf(stdout, nil)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macmem-forget-range-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        let review = try store.prepareRetentionChange(.days(30), now: now)
        _ = try store.confirmRetentionChange(review.id, confirmed: true, now: now)
        let config = TypesenseConfiguration(home: home, port: 28108, searchKeyFile: home.appendingPathComponent("search.key").path, syncKeyFile: home.appendingPathComponent("sync.key").path, enabled: true)
        for (path, data) in [(config.searchKeyFile, Data(UUID().uuidString.utf8)), (config.syncKeyFile, Data(UUID().uuidString.utf8)),
                             (home.appendingPathComponent("search-typesense.json").path, try JSONEncoder().encode(config))] {
            try data.write(to: URL(fileURLWithPath: path)); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        let start = now.addingTimeInterval(-3600), end = now.addingTimeInterval(-1800)
        let rows: [(String, Date, String)] = [("before", start.addingTimeInterval(-60), "Garden sensor"), ("at-start", start, "Walrus invoice"),
                                              ("inside", start.addingTimeInterval(600), "Marimba lessons"), ("at-end", end, "Garden sensor")]
        for (id, at, title) in rows {
            _ = try store.ingest(Evidence(id: id, at: iso(at), kind: "window.changed", app: "Safari", bundle: "com.apple.Safari", title: title, synthetic: true), now: now)
        }
        let index = FakeIndex()
        _ = try store.syncSearchIndex(config: config, transport: index, now: now)
        try check(index.docs.count == 4 && (try store.rows("SELECT count(*) FROM search_index_state").first?.first) == "4", "fixture: every action is indexed")
        let preview = try store.prepareDeletion(scope: .range(start: start, end: end, timezone: "UTC"), now: now)
        try check(preview.actionIDs == ["at-start", "inside"], "the index fixture's range holds the start and the inside action")
        let receipt = try store.executeDeletion(previewID: preview.id, confirmed: true, now: now)
        try check(receipt.searchCleanup == "pending_source_reads_already_blocked", "until the index syncs, the receipt says its entries are pending and reads are already blocked")
        let stale = try store.indexedSearch(MemorySearchQuery("Walrus"), config: config, transport: index, now: now).items.map(\.id)
        try check(!stale.isEmpty && !stale.contains("at-start") && !stale.contains("inside"), "before the sync, search already drops the forgotten hits a stale index returns")
        var guardCount = 0
        while guardCount < 10, try store.syncSearchIndex(config: config, transport: index, now: now).cycleComplete == false { guardCount += 1 }
        try check(index.docs[fingerprint("at-start")] == nil && index.docs[fingerprint("inside")] == nil, "the next sync deletes the forgotten documents from the index")
        try check(index.docs[fingerprint("before")] != nil && index.docs[fingerprint("at-end")] != nil, "the kept documents stay indexed")
        try check(try store.rows("SELECT id FROM search_index_state ORDER BY id").map { $0[0] } == ["at-end", "before"], "the index ledger keeps no forgotten id")
        try check(try store.deletionReceipt(previewID: preview.id)?.searchCleanup == "no_tracked_index_entries", "the receipt then says the index holds nothing of them")
        let indexed = try index.docs.values.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try check(indexed.allSatisfy { !$0.contains("Walrus") && !$0.contains("Marimba") }, "no indexed document carries a forgotten word")
        print("forget-range search checks: \(count) passed")
    }
}
