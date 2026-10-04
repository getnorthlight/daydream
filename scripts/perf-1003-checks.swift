// DD-RECIPE: CORE+UI (MemoryCore, HistoryCore, PrivacyPolicy and MemoryUI objects; run-extras / run-checks "perf-1003")
// claude/perf2-1003 (owner 10/03: "make sure this app is more performant"). Headless benchmarks of the code paths new in
// 0.1.4 (int-1003 8cfa725), each with what it costs the MAIN thread per call:
//   A. OwnerTypedSearch (3,000-row cap, 0.8 s budget), run off the main thread on the app's own store, as the app runs it
//      (`StoreWait.lettingMainIn`): its wall/CPU time, its longest single statement, and the main thread's longest wait for
//      the store while it runs.
//   B. The Typesense index sync after the folder move (55ad85a gave the moved history its index back, so the app's own
//      store syncs again on every save): one rebuild page, one steady-state page (nothing changed), the page's id scan,
//      and the main thread's longest store wait while the app-store pages run.
//   C. droppingTitleTicks during day assembly on a 3,000-row title flood (a Claude Code spinner day).
//   D. MomentDetailFold (MomentHistoryCondense.lines + the fold): computed in SwiftUI bodies on the main thread.
//   E. The catch-up writer's discovery: 7 past days read on the app's store (WriterQueueSource), main-thread store wait.
//   F. Privacy.secret (per word of every searched typed row and every record read): compiled once, the same answers.
//   G. The search supervisor's pacing once ready (SearchSweepPacing): pages in 30 quiet minutes.
// Synthetic stores under DD_CHECK_OUT or TMPDIR only; fictional words; no app, window, Keychain, network or person's data.
// Thresholds are generous ceilings (a loaded machine moves wall time); the numbers are printed as BENCH lines.
import Foundation
import SQLite3
import PrivacyPolicy
@testable import MemoryCore
@testable import MemoryUI

@main @MainActor enum PerfChecks1003 {
static func main() throws {
setvbuf(stdout, nil, _IOLBF, 0)
var failures = 0
func check(_ ok: Bool, _ label: String, _ got: @autoclosure () -> String = "") {
    print("\(ok ? "PASS" : "FAIL") \(label)\(ok ? "" : " :: " + got())")
    if !ok { failures += 1 }
}
func bench(_ label: String, _ value: String) { print("BENCH \(label): \(value)") }
func cpuNow() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
func wallNow() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ ns: UInt64) -> Double { Double(ns) / 1e6 }
func f1(_ x: Double) -> String { String(format: "%.1f", x) }
func f2(_ x: Double) -> String { String(format: "%.2f", x) }
func best(_ runs: Int = 5, _ body: () throws -> Void) rethrows -> (wall: Double, cpu: Double) {
    var w = Double.infinity, c = Double.infinity
    for _ in 0..<runs { let a = wallNow(), b = cpuNow(); try body(); w = min(w, ms(wallNow() - a)); c = min(c, ms(cpuNow() - b)) }
    return (w, c)
}
let root: URL = {
    let base = ProcessInfo.processInfo.environment["DD_CHECK_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("claude-perf-1003-\(getpid())", isDirectory: true)
    return base.appendingPathComponent("perf-1003", isDirectory: true)
}()
try? FileManager.default.removeItem(at: root)
let zone = "America/Chicago"
let now = Date()
check(Thread.isMainThread, "the benchmark's driver runs on the main thread (the store lock sees a main-thread waiter)")

/// The main thread's waits for the store while `work` runs on a background thread: a light store read (the policy row)
/// every 2 ms, as a capture save or a heartbeat would ask. Returns the longest and the 99th percentile wait, in ms.
func mainWaits(_ store: MemoryStore, label: String, _ work: @escaping @Sendable () -> Void) -> (max: Double, p99: Double, reads: Int, work: Double) {
    let flag = NSLock(); var done = false; var workMs = 0.0
    DispatchQueue.global(qos: .userInitiated).async {
        let t = wallNow(); work(); let d = ms(wallNow() - t)
        flag.lock(); done = true; workMs = d; flag.unlock()
    }
    var waits: [Double] = []
    while true {
        flag.lock(); let finished = done; flag.unlock()
        if finished { break }
        let t = wallNow(); _ = try? store.policy(); waits.append(ms(wallNow() - t))
        usleep(2000)
    }
    waits.sort()
    let p99 = waits.isEmpty ? 0 : waits[min(waits.count - 1, Int(Double(waits.count) * 0.99))]
    return (waits.last ?? 0, p99, waits.count, workMs)
}
func idleWait(_ store: MemoryStore) -> Double {
    var waits: [Double] = []
    for _ in 0..<200 { let t = wallNow(); _ = try? store.policy(); waits.append(ms(wallNow() - t)) }
    return waits.max() ?? 0
}

// MARK: F. Privacy.secret: compiled once, the same answers
/// `Privacy.secret` as it was before claude/perf2-1003 (each pattern compiled on every call), the reference.
func secretBefore(_ value: String) -> Bool {
    let patterns = [
        "(?i)(password|passwd|pwd|secret|token|api[_-]?key)\\s*[:=]",
        "(?i)(sk-|sk_live_|ghp_|github_pat_|xox[bap]-|AKIA|AIza|Bearer\\s+)[A-Za-z0-9_./+-]{6,}",
        "-----BEGIN [A-Z ]*(PRIVATE KEY|CERTIFICATE)",
        "eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.",
        "(?<![0-9])(?:[0-9][ -]?){13,19}(?![0-9])",
        "^\\d{4,8}$",
    ]
    if patterns.contains(where: { value.range(of: $0, options: .regularExpression) != nil }) { return true }
    let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if !ContactShape.email(v), !ContactShape.phone(v), !v.contains(" "), (8...80).contains(v.count), !v.contains("://") {
        let classes = ["[a-z]", "[A-Z]", "[0-9]", "[^A-Za-z0-9]"].filter { v.range(of: $0, options: .regularExpression) != nil }.count
        if classes >= 3 { return true }
    }
    return false
}
do {
    check(Privacy.secretPatterns.count == 6 && Privacy.secretClassPatterns.count == 4, "F the same six patterns and four classes")
    var corpus: [String] = [
        "", " ", "password: hunter2", "PASSWORD=x", "my pwd is", "api_key=abc", "API-KEY : z", "token=", "secret:",
        "sk-abcdef123456", "sk_live_ABCDEF12", "ghp_123456789012", "github_pat_ABCDEFG", "xoxb-1234567", "AKIAABCDEFGH", "AIzaSyABCDEF",
        "Bearer abcdef.ghij", "-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN CERTIFICATE-----", "eyJhbGciOi.eyJzdWIi.sig",
        "4111 1111 1111 1111", "4111-1111-1111-1111", "4111111111111111", "12345678901234567890", "1234", "123456", "12345678", "123456789",
        "a1234", "\n1234\n", "1234\n", "Hunter2!", "hunter22", "Hunter22", "hunter2!", "HUNTER2!", "abc@example.com", "pat.quill@example.co.uk",
        "(312) 555-0123", "+1 312-555-0123", "312.555.0123", "https://example.com/Path1", "Fixture Notes", "◐ Fixture parser review",
        "✳ Claude Code", "Ünïcödé1!", "日本語テキスト123", "emoji😀Abc1", "tab\tSep1A", "a\u{0}b1C", "Grüße123", "ÅÄÖ-åäö-123",
        String(repeating: "a", count: 81) + "B1", "aB1" + String(repeating: "-", count: 77), "aB1" + String(repeating: "-", count: 78),
    ]
    var rng = SystemRandomNumberGenerator()
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_.:=/+@!#$%&*()[]{}\n\téüß日😀\u{2733}\u{25D0}")
    for _ in 0..<30000 {
        let n = Int.random(in: 0...40, using: &rng)
        corpus.append(String((0..<n).map { _ in alphabet.randomElement(using: &rng)! }))
    }
    // Text the String API reads differently from a plain expression: combining marks, a final newline, CR LF, Unicode
    // digits, case-folding letters (long s, Kelvin sign, dotted I), wide forms, emoji and flags; spaceless tokens of
    // 8-80 characters reach the character-class rule.
    let tricky = Array("aZ09-_:=./+@!\r\n\t\u{00A0}\u{2028}\u{0085}\u{0661}\u{FF11}\u{1D7D8}\u{0130}\u{0131}\u{017F}\u{212A}ßÅé\u{0301}\u{0308}😀🇺🇸Ｐ")
    for _ in 0..<30000 {
        let n = Int.random(in: 0...24, using: &rng)
        corpus.append(String((0..<n).map { _ in tricky.randomElement(using: &rng)! }))
    }
    for word in ["password:", "PASSWORD =", "\u{017F}ecret:", "api_key=", "Token\u{00A0}:", "s\u{212A}-", "1234", "١٢٣٤٥", "１２３４"] {
        for tail in ["", "\n", "\r\n", "\u{0301}", " x", "abcDEF123"] { corpus.append(word + tail); corpus.append("Ab1" + word + tail) }
    }
    for _ in 0..<20000 {   // spaceless tokens for the class rule, mostly ASCII
        let n = Int.random(in: 6...82, using: &rng)
        let pool = Int.random(in: 0...3, using: &rng) == 0 ? tricky : Array("abcxyzABCXYZ0189-_.!#\r\n\t")
        corpus.append(String((0..<n).map { _ in pool.randomElement(using: &rng)! }))
    }
    for _ in 0..<5000 {   // near-misses around each pattern
        let digits = String((0..<Int.random(in: 3...21, using: &rng)).map { _ in "0123456789 -".randomElement(using: &rng)! })
        corpus.append(digits)
        corpus.append(["sk-", "ghp_", "AKIA", "eyJ", "Bearer ", "token", "pwd"].randomElement(using: &rng)! + digits + ["", ":", "=", ".x.", "abcDEF"].randomElement(using: &rng)!)
    }
    var mismatches: [String] = []
    for value in corpus where Privacy.secret(value) != secretBefore(value) { mismatches.append(value.debugDescription) }
    check(mismatches.isEmpty, "F Privacy.secret answers exactly as before for \(corpus.count) strings (fixed + fuzz)", "\(mismatches.prefix(5))")
    let sample = Array(corpus.prefix(4000))
    let old = best(3) { for v in sample { _ = secretBefore(v) } }, new = best(3) { for v in sample { _ = Privacy.secret(v) } }
    bench("F Privacy.secret per call", "before \(f2(old.cpu * 1000 / Double(sample.count))) µs, after \(f2(new.cpu * 1000 / Double(sample.count))) µs")
    check(new.cpu * 2 < old.cpu, "F Privacy.secret is at least twice as cheap", "before \(f1(old.cpu)) ms after \(f1(new.cpu)) ms per \(sample.count)")
}

// MARK: A. OwnerTypedSearch
func typedEvidence(_ id: String, _ text: String, at: Date) -> Evidence {
    var e = Evidence(id: id, at: iso(at), kind: "keyboard.text_input", app: "TextEdit", bundle: "com.apple.TextEdit",
                     title: "Fixture notes \(id.hashValue & 7)", text: text, synthetic: true)
    var unit = TypedUnitProvenance(runID: "run-" + id, part: 1, sealReason: "idle", startedAt: iso(at.addingTimeInterval(-4)),
                                   keys: 30, edits: 0, withheld: 0)
    unit.surface = "text"; unit.field = "message"; unit.send = "none"; unit.version = TypedUnitProvenance.sendFactsVersion
    e.captureProvenance = NativeCaptureProvenance(policyRevision: "r", classifierVersion: "sensitive-typing/v2+typed-scrub/v1", windowID: "w-" + id,
                                                  focusID: "f-" + id, checkedAt: iso(at), generation: 1, unit: unit)
    return e
}
let words = ["harbor", "lantern", "meadow", "copper", "violet", "summit", "pebble", "orchard", "canvas", "thistle", "ember", "quarry"]
func sentence(_ n: Int) -> String { (0..<9).map { words[(n * 7 + $0 * 5) % words.count] }.joined(separator: " ") + " fixture line \(n)" }

let typedRows = Int(ProcessInfo.processInfo.environment["PERF_TYPED_ROWS"] ?? "") ?? 6000
let typedHome = root.appendingPathComponent("typed", isDirectory: true)
try FileManager.default.createDirectory(at: typedHome, withIntermediateDirectories: true)
let typedStore = try MemoryStore(home: typedHome, writable: true, automaticallySyncSearch: false)
try typedStore.exec("PRAGMA synchronous=OFF")
do {
    var policy = try typedStore.policy(); policy.captureText = true; policy.typedConsentVersion = 1
    try typedStore.updatePolicy(policy, now: now)
    try typedStore.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore()), now: now)
    try typedStore.acceptSafeTyping(now: now); try typedStore.setUpTypedVault(now: now)
    let t = wallNow()
    var saved = 0
    for i in 0..<typedRows {
        let at = now.addingTimeInterval(-Double(typedRows - i) * 240)   // one every 4 min, ~16 days back for 6,000
        if i % 2 == 0 {
            _ = try typedStore.ingest(Evidence(id: "win-\(i)", at: iso(at.addingTimeInterval(-30)), kind: "window.changed", app: "TextEdit",
                                               bundle: "com.apple.TextEdit", title: "Fixture notes \(i % 40)", synthetic: true), now: now)
        }
        if try typedStore.ingest(typedEvidence("typed-\(i)", sentence(i), at: at), now: now) { saved += 1 }
    }
    bench("A fixture", "\(saved) typed rows saved of \(typedRows) (+\(typedRows / 2) window rows) in \(f1(ms(wallNow() - t) / 1000)) s")
    check(saved > typedRows / 2, "A fixture: the typed rows save (TextEdit typing)", "\(saved)")
}
if typedStore.typedVaultState == .ready {
    // The candidate scan alone (the pass's one long statement): every typed row's JSON, sorted by time.
    let floor = "0001-01-01T00:00:00Z", end = "9999-12-31T00:00:00Z"
    let scanSQL = """
        SELECT r.id FROM typed_text t JOIN records r ON r.id=t.id
        WHERE json_extract(r.body,'$.kind')='keyboard.text_input' AND coalesce(json_extract(r.body,'$.secure'),0) IN (0,'false')
          AND julianday(json_extract(r.body,'$.at'))>=julianday(?) AND julianday(json_extract(r.body,'$.at'))<julianday(?)
          AND (?='' OR json_extract(r.body,'$.app')=? OR json_extract(r.body,'$.bundle')=?)
        ORDER BY julianday(json_extract(r.body,'$.at')) DESC, r.id DESC LIMIT ?
        """
    let scan = try best(3) { _ = try typedStore.rows(scanSQL, [floor, end, "", "", "", "3001"]) }
    bench("A candidate scan (\(typedRows) typed rows, one statement under the store lock)", "\(f1(scan.wall)) ms wall, \(f1(scan.cpu)) ms CPU")
    for (label, text) in [("no hit", "zzqxnohit"), ("hit", "lantern copper")] {
        let q = MemorySearchQuery(text, limit: 50)
        var result = OwnerTypedSearchResult()
        let t = wallNow(), c = cpuNow()
        result = try StoreWait.lettingMainIn { try typedStore.ownerTypedSearch(q, now: now) }
        let wall = ms(wallNow() - t), cpu = ms(cpuNow() - c)
        bench("A ownerTypedSearch \(label)", "\(f1(wall)) ms wall, \(f1(cpu)) ms CPU, \(result.items.count) items, complete \(result.complete)")
        check(wall < 4000, "A ownerTypedSearch \(label) stays near its 0.8 s budget", "\(f1(wall)) ms")
        let w = mainWaits(typedStore, label: "A") {
            _ = try? StoreWait.lettingMainIn { try typedStore.ownerTypedSearch(q, now: now) }
        }
        bench("A main-thread store wait during ownerTypedSearch \(label)", "max \(f1(w.max)) ms, p99 \(f2(w.p99)) ms over \(w.reads) reads; search \(f1(w.work)) ms off main")
    }
    bench("A idle main-thread store read", "max \(f2(idleWait(typedStore))) ms")
    // A superseded search (the next letter typed in Recall) stops at its next row.
    do {
        let stop = OwnerTypedSearchStop()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { stop.request() }
        let t = wallNow()
        let r = try StoreWait.lettingMainIn { try typedStore.ownerTypedSearch(MemorySearchQuery("zzqxnohit", limit: 50), now: now, stop: stop) }
        let d = ms(wallNow() - t)
        bench("A ownerTypedSearch stopped 50 ms in", "\(f1(d)) ms, \(r.items.count) items")
        check(d < 300 && r.items.isEmpty && !r.complete, "A a stopped typed pass ends at its next row with nothing", "\(f1(d)) ms")
    }
} else {
    print("NOTE A skipped: the typed vault is not ready in this build")
}

// MARK: B. Typesense index sync (fake local server: 2 ms per request)
final class FakeTypesense: TypesenseTransport {
    var requests = 0, imported = 0
    let lock = NSLock()
    func request(_ method: String, _ path: String, query: [URLQueryItem], body: Data?, deadline: Date) throws -> TypesenseResponse {
        lock.lock(); requests += 1; lock.unlock()
        usleep(2000)
        if method == "POST" && path.hasSuffix("/documents/import") {
            let n = body.map { String(decoding: $0, as: UTF8.self).split(separator: "\n").count } ?? 0
            lock.lock(); imported += n; lock.unlock()
            return TypesenseResponse(status: 200, data: Data(Array(repeating: "{\"success\":true}", count: n).joined(separator: "\n").utf8))
        }
        if method == "POST" && path == "/collections" { return TypesenseResponse(status: 201, data: Data("{}".utf8)) }
        return TypesenseResponse(status: 200, data: Data("{}".utf8))
    }
}
let syncRecords = Int(ProcessInfo.processInfo.environment["PERF_SYNC_RECORDS"] ?? "") ?? 30000
let syncHome = root.appendingPathComponent("sync", isDirectory: true)
try FileManager.default.createDirectory(at: syncHome, withIntermediateDirectories: true)
let syncStore = try MemoryStore(home: syncHome, writable: true, automaticallySyncSearch: false)
do {
    let t = wallNow()
    let apps = [("Safari", "com.apple.Safari"), ("Notes", "com.apple.Notes"), ("Ghostty", "com.mitchellh.ghostty"), ("Mail", "com.apple.mail")]
    try syncStore.exec("PRAGMA synchronous=OFF"); do {
        for i in 0..<syncRecords {
            let a = apps[i % apps.count]
            _ = try syncStore.ingest(Evidence(id: String(format: "rec-%07d", i), at: iso(now.addingTimeInterval(-Double(syncRecords - i) * 30)),
                                              kind: i % 3 == 0 ? "window.changed" : "mouse.click", app: a.0, bundle: a.1,
                                              title: "Fixture page \(i % 211)", synthetic: true), now: now)
        }
    }
    bench("B fixture", "\(syncRecords) records in \(f1(ms(wallNow() - t) / 1000)) s")
}
let config = TypesenseConfiguration(home: syncHome, port: 50999, searchKeyFile: "search.key", syncKeyFile: "sync.key", enabled: true)
let fake = FakeTypesense()
do {
    let path = syncHome.appendingPathComponent("search-typesense.json").path
    FileManager.default.createFile(atPath: path, contents: try JSONEncoder().encode(config), attributes: [.posixPermissions: 0o600])
    check(try TypesenseConfiguration.load(home: syncHome) == config, "B the fake index's configuration loads")
}
do {
    let idScan = "SELECT id FROM (SELECT id FROM records UNION SELECT id FROM search_index_state) WHERE id>? ORDER BY id LIMIT 100"
    // Rebuild: every page upserts 100 documents.
    var pages = 0, worst = 0.0, total = 0.0, first = true, cpuTotal = 0.0
    while true {
        let t = wallNow(), c = cpuNow()
        let r = try syncStore.syncSearchIndex(config: config, transport: fake, rebuild: first, now: now)
        let d = ms(wallNow() - t); cpuTotal += ms(cpuNow() - c)
        first = false; pages += 1; worst = max(worst, d); total += d
        if r.cycleComplete || pages > syncRecords / 50 { break }
    }
    bench("B rebuild (\(syncRecords) records)", "\(pages) pages, \(f1(total / 1000)) s wall, \(f1(cpuTotal / 1000)) s CPU, \(f1(total / Double(pages))) ms/page mean, \(f1(worst)) ms worst page; \(fake.imported) documents imported")
    check(fake.imported >= syncRecords, "B rebuild indexes every record", "\(fake.imported)")
    let scanStart = try best(3) { _ = try syncStore.rows(idScan, [""]) }
    let scanEnd = try best(3) { _ = try syncStore.rows(idScan, [String(format: "rec-%07d", syncRecords - 50)]) }
    bench("B page id scan before (records UNION index state, one statement)", "cursor at start \(f2(scanStart.wall)) ms, near end \(f2(scanEnd.wall)) ms")
    let mergedStart = try best(3) { _ = try syncStore.searchPageIDs(after: "") }
    let mergedEnd = try best(3) { _ = try syncStore.searchPageIDs(after: String(format: "rec-%07d", syncRecords - 50)) }
    bench("B page id scan after (searchPageIDs: two key-range reads, merged)", "cursor at start \(f2(mergedStart.wall)) ms, near end \(f2(mergedEnd.wall)) ms")
    check(try syncStore.searchPageIDs(after: "").map { Array($0.utf8) } == syncStore.rows(idScan, [""]).map { Array($0[0].utf8) }, "B the merged page ids equal the union statement's on the full store")
    check(mergedStart.wall * 5 < scanStart.wall, "B the page id scan no longer sorts the whole union", "\(f2(mergedStart.wall)) vs \(f2(scanStart.wall)) ms")
    // Differential on a store where the two tables differ (deleted records still indexed, records not yet indexed),
    // with ids whose byte order and Unicode order disagree (SQLite compares bytes).
    let idHome = root.appendingPathComponent("ids", isDirectory: true)
    try FileManager.default.createDirectory(at: idHome, withIntermediateDirectories: true)
    let idStore = try MemoryStore(home: idHome, writable: true, automaticallySyncSearch: false)
    var recordIDs = Set<String>(), indexIDs = Set<String>()
    var rng = SystemRandomNumberGenerator()
    let alphabet: [String] = "abcxyzABZ019-_.".map { String($0) } + ["\u{e9}", "e\u{301}", "\u{212B}", "\u{c5}", "\u{1F600}", "\u{ff21}", "\u{17f}"]
    for _ in 0..<700 {
        let id = (0..<Int.random(in: 1...4, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }.joined()
        switch Int.random(in: 0..<3, using: &rng) { case 0: recordIDs.insert(id); case 1: indexIDs.insert(id); default: recordIDs.insert(id); indexIDs.insert(id) }
    }
    for id in recordIDs { try idStore.exec("INSERT OR IGNORE INTO records VALUES(?,?,?)", [id, "{}", "r"]) }
    for id in indexIDs { try idStore.exec("INSERT OR IGNORE INTO search_index_state VALUES(?,?)", [id, "r"]) }
    var cursors = [""] + Array(recordIDs.union(indexIDs)) + ["\u{10FFFF}", "~", "e", "rec-"]
    cursors.shuffle(using: &rng)
    var same = 0, differ = [String]()
    for c in cursors {
        for limit in [100, 7] {
            let old = try idStore.rows("SELECT id FROM (SELECT id FROM records UNION SELECT id FROM search_index_state) WHERE id>? ORDER BY id LIMIT \(limit)", [c]).map { Array($0[0].utf8) }
            if try idStore.searchPageIDs(after: c, limit: limit).map({ Array($0.utf8) }) == old { same += 1 } else { differ.append(c) }
        }
    }
    check(differ.isEmpty, "B merged page ids equal the union statement's for \(same) cursor/limit pairs (\(recordIDs.count) records, \(indexIDs.count) indexed, mixed Unicode ids)", "\(differ.count) differ")
    // Steady state: a full cycle where nothing changed (what each save sets off on the app's own store).
    pages = 0; worst = 0; total = 0; cpuTotal = 0
    let before = fake.requests
    while true {
        let t = wallNow(), c = cpuNow()
        let r = try syncStore.syncOriginatingSearchIndex(config: config, transport: fake, now: now)
        let d = ms(wallNow() - t); cpuTotal += ms(cpuNow() - c)
        pages += 1; worst = max(worst, d); total += d
        if r.cycleComplete || pages > syncRecords / 50 { break }
    }
    bench("B steady cycle, nothing changed (app store, originating)", "\(pages) pages, \(f1(total)) ms wall, \(f1(cpuTotal)) ms CPU, \(f1(total / Double(pages))) ms/page, \(f1(worst)) ms worst, \(fake.requests - before) requests")
    let w = mainWaits(syncStore, label: "B") {
        for _ in 0..<40 { _ = try? syncStore.syncOriginatingSearchIndex(config: config, transport: fake, now: now) }
    }
    bench("B main-thread store wait during 40 app-store sync pages", "max \(f1(w.max)) ms, p99 \(f2(w.p99)) ms over \(w.reads) reads; pages \(f1(w.work)) ms off main")
    bench("B idle main-thread store read", "max \(f2(idleWait(syncStore))) ms")
}

// MARK: C. droppingTitleTicks on a 3,000-row title flood
let floodHome = root.appendingPathComponent("flood", isDirectory: true)
try FileManager.default.createDirectory(at: floodHome, withIntermediateDirectories: true)
let floodStore = try MemoryStore(home: floodHome, writable: true, automaticallySyncSearch: false)
let floodDay = try DayScope.key(now.addingTimeInterval(-86400), timezone: zone)
let floodStart = try DayScope.interval(day: floodDay, timezone: zone).start.addingTimeInterval(9 * 3600)
do {
    let topic = "Fixture parser review"
    let titles = ["\u{2733} " + topic, "\u{25D0} " + topic, "\u{25D1} " + topic]
    try floodStore.exec("PRAGMA synchronous=OFF"); do {
        for i in 0..<3000 {
            _ = try floodStore.ingest(Evidence(id: String(format: "tick-%05d", i), at: iso(floodStart.addingTimeInterval(Double(i) * 2)), kind: "window.changed",
                                               app: "Ghostty", bundle: "com.mitchellh.ghostty", title: titles[i % 3], synthetic: true), now: now)
            if i % 50 == 0 {
                _ = try floodStore.ingest(Evidence(id: String(format: "click-%05d", i), at: iso(floodStart.addingTimeInterval(Double(i) * 2 + 1)), kind: "mouse.click",
                                                   app: "Safari", bundle: "com.apple.Safari", title: "Fixture page \(i)", synthetic: true), now: now)
            }
        }
    }
}
do {
    // Cold assembly: a fresh connection each run, and the day cache cleared by a policy-neutral new row each time.
    var coldWall = Double.infinity, coldCPU = Double.infinity, moments = 0, visible = 0
    for n in 0..<3 {
        _ = try floodStore.ingest(Evidence(id: "nudge-\(n)", at: iso(floodStart.addingTimeInterval(7000 + Double(n))), kind: "mouse.click", app: "Safari",
                                           bundle: "com.apple.Safari", title: "Fixture nudge", synthetic: true), now: now)
        DayAssemblyCache.shared.removeAll()
        let reader = try MemoryStore(home: floodHome)
        let t = wallNow(), c = cpuNow()
        let day = try reader.dayLayers(day: floodDay, timezone: zone, limit: 200, now: now)
        coldWall = min(coldWall, ms(wallNow() - t)); coldCPU = min(coldCPU, ms(cpuNow() - c))
        moments = day.activities.count; visible = day.activities.reduce(0) { $0 + $1.actionIDs.count }
    }
    bench("C day assembly, 3,000 glyph ticks (cold, off main in the app)", "\(f1(coldWall)) ms wall, \(f1(coldCPU)) ms CPU; \(moments) moments, \(visible) visible actions")
    // The filter alone on the assembled rows.
    let rows: [DayRow] = (0..<3000).map { i in
        let e = Evidence(id: "r\(i)", at: iso(floodStart.addingTimeInterval(Double(i) * 2)), kind: "window.changed", app: "Ghostty",
                         bundle: "com.mitchellh.ghostty", title: "Fixture parser review", synthetic: true)
        return DayRow(rowid: Int64(i), id: e.id, at: e.at, time: timestamp(e.at), action: ActionProjection.make(e), statusGlyph: true)
    }
    var kept = 0
    let filter = best(10) { kept = MemoryStore.droppingTitleTicks(rows, edits: [:]).count }
    bench("C droppingTitleTicks alone (3,000 rows)", "\(f2(filter.wall)) ms wall, \(f2(filter.cpu)) ms CPU; kept \(kept)")
    check(kept == 1, "C a 3,000-tick flood folds to its first row", "\(kept)")
    let glyph = best(5) { for i in 0..<3000 { _ = TitleClean.statusless(i % 2 == 0 ? "\u{25D0} Fixture parser review" : "Fixture parser review") } }
    bench("C statusGlyph reads (TitleClean.statusless x3,000)", "\(f2(glyph.wall)) ms wall")
}

// MARK: D. MomentDetailFold (SwiftUI body, main thread)
func foldFixture(_ n: Int) -> (actions: [CanonicalAction], typed: MomentTypedLoad) {
    var evidence: [Evidence] = [], blocks: [MomentTypedBlock] = []
    let base = floodStart
    let topic = "Fixture parser review"
    for i in 0..<n {
        let at = iso(base.addingTimeInterval(Double(i) * 3))
        switch i % 10 {
        case 0, 1, 2, 3:
            evidence.append(Evidence(id: "t\(i)", at: at, kind: "window.changed", app: "Ghostty", bundle: "com.mitchellh.ghostty",
                                     title: (i % 2 == 0 ? "\u{25D0} " : "\u{2733} ") + topic, synthetic: true))
        case 4:
            var e = Evidence(id: "p\(i)", at: at, kind: "keyboard.text_input", app: "Ghostty", bundle: "com.mitchellh.ghostty",
                             title: "\u{2733} " + topic, text: "fixture prompt \(i)", synthetic: true)
            let unit = TypedUnitProvenance(runID: "r\(i / 20)", part: (i / 10) % 2 + 1, sealReason: i % 20 == 14 ? "submit" : "pointer", startedAt: at,
                                           keys: nil, edits: nil, withheld: 0, surface: "code", field: "textArea",
                                           send: i % 20 == 14 ? "detected" : "none", sendBy: i % 20 == 14 ? "return" : nil, to: nil)
            e.captureProvenance = NativeCaptureProvenance(policyRevision: "synthetic", classifierVersion: "sensitive-typing/v2",
                                                          windowID: "w", focusID: "f", checkedAt: at, generation: 1, unit: unit)
            evidence.append(e)
            blocks.append(MomentTypedBlock(id: e.id, at: e.at, app: "Ghostty", bundle: "com.mitchellh.ghostty", host: "", title: e.title, text: e.text, send: nil))
        case 5:
            evidence.append(Evidence(id: "k\(i)", at: at, kind: "keyboard.submit", app: "Ghostty", bundle: "com.mitchellh.ghostty", title: "", synthetic: true))
        case 6:
            evidence.append(Evidence(id: "m\(i)", at: at, kind: "app.activated", app: "Messages", bundle: "com.apple.MobileSMS", title: "Fixture chat", synthetic: true))
        case 7:
            evidence.append(Evidence(id: "w\(i)", at: at, kind: "page.visited", app: "Safari", bundle: "com.apple.Safari",
                                     title: "Fixture page \(i % 13)", url: "https://example.com/p\(i % 13)", synthetic: true))
        default:
            evidence.append(Evidence(id: "c\(i)", at: at, kind: "mouse.click", app: "Safari", bundle: "com.apple.Safari", title: "Fixture page \(i % 13)", synthetic: true))
        }
    }
    return (evidence.map(ActionProjection.make), MomentTypedLoad(blocks: blocks))
}
for n in [400, 3000] {
    let fx = foldFixture(n)
    let tz = TimeZone(identifier: zone)!
    var lines = 0
    let whole = best(5) {
        lines = MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(fx.actions, previews: [], typed: fx.typed), actions: fx.actions, timeZone: tz).count
    }
    let entries = OwnerSourceMomentProjection.history(fx.actions, previews: [], typed: fx.typed)
    let fold = best(5) { _ = MomentDetailFold.fold(entries, entries: entries, actions: fx.actions, timeZone: tz) }
    bench("D What happened for \(n) actions (history + condense + fold, per SwiftUI body)", "\(f2(whole.wall)) ms wall, \(f2(whole.cpu)) ms CPU; \(lines) lines; MomentDetailFold alone \(f2(fold.wall)) ms")
    if n == 400 { check(whole.cpu < 250, "D a 400-action card's What happened stays well under a few frames", "\(f1(whole.cpu)) ms") }
}

// MARK: E. Catch-up discovery: 7 past days on the app's store
let catchHome = root.appendingPathComponent("catchup", isDirectory: true)
try FileManager.default.createDirectory(at: catchHome, withIntermediateDirectories: true)
let catchStore = try MemoryStore(home: catchHome, writable: true, automaticallySyncSearch: false)
var catchDays: [String] = []
do {
    let apps = [("Safari", "com.apple.Safari"), ("Notes", "com.apple.Notes"), ("Ghostty", "com.mitchellh.ghostty"), ("Mail", "com.apple.mail")]
    try catchStore.exec("PRAGMA synchronous=OFF"); do {
        for d in 1...7 {
            let day = try DayScope.key(now.addingTimeInterval(-Double(d) * 86400), timezone: zone)
            catchDays.append(day)
            let start = try DayScope.interval(day: day, timezone: zone).start.addingTimeInterval(8 * 3600)
            for i in 0..<3000 {
                let a = apps[(i / 60) % apps.count]
                _ = try catchStore.ingest(Evidence(id: "d\(d)-\(i)", at: iso(start.addingTimeInterval(Double(i) * 12)), kind: i % 4 == 0 ? "window.changed" : "mouse.click",
                                                   app: a.0, bundle: a.1, title: "Fixture doc \((i / 60) % 31)", synthetic: true), now: now)
            }
        }
    }
    DayAssemblyCache.shared.removeAll()
    let days = catchDays
    let w = mainWaits(catchStore, label: "E") {
        for day in days { _ = try? catchStore.dayLayers(day: day, timezone: zone, now: now) }
    }
    bench("E catch-up discovery read, 7 past days x 3,000 actions (cold, app store)", "\(f1(w.work)) ms off main; main-thread store wait max \(f1(w.max)) ms, p99 \(f2(w.p99)) ms over \(w.reads) reads")
    let warm = best(3) { for day in days { _ = try? catchStore.dayLayers(day: day, timezone: zone, now: now) } }
    bench("E the same 7 days warm (day cache)", "\(f1(warm.wall)) ms")
    check(DayAssemblyCache.capacity >= 7 + 1 + 3, "E the day cache keeps the 7 catch-up days, today and day navigation's 3", "\(DayAssemblyCache.capacity)")
    check(warm.wall * 5 < w.work, "E a second catch-up look over the same 7 days reads them from the day cache", "warm \(f1(warm.wall)) ms, cold \(f1(w.work)) ms")
}

// MARK: G. The search supervisor's pacing once ready (SearchSweepPacing)
do {
    func page(_ scanned: Int, changed: Int = 0) -> SearchSyncResult {
        SearchSyncResult(status: "synced", scanned: scanned, upserted: changed, deleted: 0, cycleComplete: scanned < 100)
    }
    var p = SearchSweepPacing(), t0 = Date(timeIntervalSince1970: 1_000_000)
    check(p.page(page(100), ready: false, dirty: true, now: t0) == 0.1, "G indexing still pages every 0.1 s")
    check(p.page(page(100, changed: 3), ready: true, dirty: false, now: t0) == 1, "G a ready page that changed something waits 1 s, as before")
    check(p.page(page(100), ready: true, dirty: false, now: t0) == SearchSweepPacing.cleanPace, "G a ready page that changed nothing waits \(SearchSweepPacing.cleanPace) s")
    _ = p.page(page(40), ready: true, dirty: false, now: t0)
    check(!p.resting(ready: true, dirty: false, now: t0 + 1), "G a sweep that changed a page does not rest")
    _ = p.page(page(100), ready: true, dirty: false, now: t0)
    _ = p.page(page(40), ready: true, dirty: false, now: t0)
    check(p.resting(ready: true, dirty: false, now: t0 + 30), "G a clean ready sweep rests before the next")
    check(!p.resting(ready: true, dirty: false, now: t0 + SearchSweepPacing.restAfterCleanSweep + 0.1), "G the rest ends after \(SearchSweepPacing.restAfterCleanSweep) s")
    _ = p.page(page(40), ready: true, dirty: false, now: t0)
    check(!p.resting(ready: true, dirty: true, now: t0 + 1), "G a dirty store (disclosure or policy change) ends the rest at once")
    check(!p.resting(ready: true, dirty: false, now: t0 + 2), "G and the rest stays ended after it")
    var q = SearchSweepPacing()
    _ = q.page(page(40), ready: true, dirty: true, now: t0)
    check(!q.resting(ready: true, dirty: false, now: t0 + 1), "G a sweep that finished on a dirty store does not rest")
    _ = q.page(page(40), ready: false, dirty: false, now: t0)
    check(!q.resting(ready: false, dirty: false, now: t0 + 1), "G an indexing sweep never rests")
    // 30 virtual minutes of a quiet 13,400-record store (134 pages a sweep), the owner's at 15:30-16:00.
    func pages(_ paced: Bool) -> Int {
        var s = SearchSweepPacing(), now = t0, n = 0, i = 0
        while now < t0 + 1800 {
            if paced && s.resting(ready: true, dirty: false, now: now) { now += 1; continue }
            i += 1; n += 1
            let r = page(i % 134 == 0 ? 0 : 100)
            now += paced ? s.page(r, ready: true, dirty: false, now: now) : 1
        }
        return n
    }
    let before = pages(false), after = pages(true)
    bench("G supervisor pages in 30 quiet minutes, 13,400 records", "\(before) before, \(after) after (each page: one collection GET, a 100-id scan, 100 reads and 2 transactions)")
    check(after * 2 < before, "G a quiet store's supervisor pages at most half as often", "\(after) vs \(before)")
}

try? FileManager.default.removeItem(at: root)
print("perf-1003: \(failures == 0 ? "PASS" : "FAIL") (\(failures) failed); synthetic stores only, no windows")
exit(failures == 0 ? 0 : 1)
}
}
