// fix/chrome-root: the always-on website typing tally (`WebTypingRefusals`), compiled in every build (the CLI reads it).
import Foundation
import MemoryCore

func runWebTypingRefusalsChecks() throws {
    let t = WebTypingRefusals()
    var saved: [String: Int] = [:]
    t.persist = { counts, _ in saved = counts }
    // Episodes, never keys: 34 refused keys with the same answer count once.
    for _ in 0..<34 { t.join(denial: "timeout") }
    try check(t.snapshot()["join.timeout"] == 1, "tally: 34 keys refused for the same reason count once (an episode, never a length)")
    t.join(denial: nil); t.join(denial: nil); t.join(denial: "timeout")
    try check(t.snapshot()["join.allowed"] == 1 && t.snapshot()["join.timeout"] == 2, "tally: a new episode counts when the answer changes")
    // Privacy refusals are one name.
    for d in ["notNormal", "sensitiveField", "blockedSite"] { t.join(denial: d); t.join(denial: "field") }
    try check(t.snapshot()["join.privacy"] == 3 && t.snapshot().keys.allSatisfy { !["join.notNormal", "join.sensitiveField", "join.blockedSite"].contains($0) },
              "tally: Incognito, sensitive fields and blocked sites are one name, join.privacy")
    // Apple Event failures: counted with a join, once per run of failing joins.
    t.transportFailed(); t.join(denial: "notNormal"); t.transportFailed(); t.join(denial: "notNormal"); t.join(denial: nil); t.transportFailed(); t.join(denial: "windowList")
    try check(t.snapshot()["appleEvent.failed"] == 2, "tally: failed Apple Events count once per run of joins that had one")
    // Streams are separate: a drop between joins doesn't restart the join episode.
    t.join(denial: "changed"); t.note("drop.late"); t.join(denial: "changed"); t.note("drop.late")
    try check(t.snapshot()["join.changed"] == 1 && t.snapshot()["drop.late"] == 1, "tally: joins and drops are separate streams")
    // Rows count one by one; unknown names are ignored.
    t.saved(); t.saved()
    try check(t.snapshot()["saved"] == 2, "tally: saved rows count one by one")
    let size = t.snapshot().count
    t.join(denial: "somethingNew")
    try check(t.snapshot().count == size, "tally: a name outside the list is never kept")
    // Every name is a fixed literal, none a key, word, site or length.
    try check(WebTypingRefusals.names.allSatisfy { $0.allSatisfy { $0.isLetter || $0 == "." } } && WebTypingRefusals.names.count < 64,
              "tally: names are fixed words only")
    for d in ["disabled", "untrustedTarget", "noPermission", "notFocused", "windowList", "window", "unlistedWindow", "ambiguousWindow",
              "field", "frame", "url", "changed", "timeout"] {
        try check(WebTypingRefusals.names.contains("join." + d), "tally: the join's \(d) refusal has a name")
    }
    // The defaults round trip keeps known names only.
    t.flush()
    try check(saved == t.snapshot() && !saved.isEmpty, "tally: flush hands the counts to the store once changed")
    saved = [:]; t.flush()
    try check(saved.isEmpty, "tally: nothing changed, nothing written")
    var encoded = WebTypingRefusals.encoded(t.snapshot(), since: Date(timeIntervalSince1970: 1_790_000_000))
    encoded["typed words"] = 5; encoded["join.timeout"] = "x"
    let back = WebTypingRefusals.decoded(encoded)
    try check(back?.counts["typed words"] == nil && back?.counts["join.timeout"] == nil && back?.counts["saved"] == 2 && back?.since != nil,
              "tally: reading back keeps known names and whole counts only")
    // The app's wiring to a defaults suite, and the CLI's read of that domain.
    let suite = "com.getnorthlight.daydream.checks.tally." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    let app = WebTypingRefusals(); app.persistToDefaults(defaults)
    app.join(denial: "timeout"); app.flush()
    defaults.synchronize()
    try check(WebTypingRefusals.read(domain: suite)?.counts["join.timeout"] == 1, "tally: the CLI reads what the app wrote to its defaults")
    let relaunched = WebTypingRefusals(); relaunched.persistToDefaults(defaults)
    relaunched.join(denial: "timeout"); relaunched.flush()
    try check(WebTypingRefusals.read(domain: suite)?.counts["join.timeout"] == 2, "tally: counting goes on across a relaunch")
    defaults.removePersistentDomain(forName: suite)
}
