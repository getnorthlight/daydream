import Foundation
import MemoryCore

/// fix/welcome-prompt: the setup check an AI app reads in `status` to answer the connection starter. Each state reads
/// the way the person's situation is: an empty new install is ready (never a failure), capture off and paused say how
/// to start, typing switched on is not typing verified until a typed row is saved, and a missing or stopped
/// connection says so. Read through a second, read-only open with no typing key, as the MCP server reads.
func runReadinessChecks(home: URL) throws {
    let now = Date()
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    let reader = try MemoryStore(home: home)
    let client = "claude-desktop", recipient = "daydream-connect"
    let secrets = ["zebrafjordsecret", "Quarterly pricing draft", "https://example.com/private/path?token=abc", "example.com/private"]
    func connected() throws -> (AssistantAccess, [String:String]) {
        let key = try store.grant(client: client, recipient: recipient, scopes: MemoryStore.assistantScopes)
        let access = reader.assistantAccess(client: client, recipient: recipient, capability: key)
        return (access, try reader.assistantStatus(now: now, access: access))
    }
    func clean(_ status: [String:String], _ name: String) throws {
        let text = try json(status)
        try check(!secrets.contains { text.contains($0) }, "readiness (\(name)): no typed words, titles or web addresses")
    }
    let keys = ["setup", "connected", "recording", "typing", "typing_verified", "chrome_pages", "summaries", "examples"]

    // 1. Empty store on a new install: capture never started, nothing recorded. Not a failure.
    var (access, status) = try connected()
    try check(access == .connected && keys.allSatisfy { status[$0] != nil }, "readiness: every field is there, and a fresh grant reads as connected")
    try check(status["connected"]?.hasPrefix("yes:") == true && status["last_activity"] == "Nothing recorded yet."
              && status["setup"] == "Connected, but recording is off. The person can turn DayDream on in the menu bar. Nothing has been recorded yet.",
              "readiness (empty, capture off): connected, recording off, nothing recorded yet")
    try store.setCaptureState("recording", reason: "check", now: now)
    (access, status) = try connected()
    try check(status["recording"] == "on" && status["setup"]?.hasPrefix("Ready: DayDream is connected and recording. Nothing has been recorded yet, which is normal right after setup") == true
              && status["examples"]?.hasSuffix("(These work once there is some activity.)") == true,
              "readiness (empty, recording): ready, nothing recorded yet is normal, examples say they need activity")
    for word in ["fail", "error", "broken", "not working", "problem"] {
        try check(status["setup"]?.lowercased().contains(word) == false, "readiness (empty): the setup line never says \"\(word)\"")
    }
    try check(status["typing"]?.hasPrefix("off:") == true && status["typing_verified"] == "no", "readiness (empty): typing off, not verified")

    // 2. Capture off, with earlier activity.
    try check(try store.ingest(Evidence(id: "w-1", at: iso(now.addingTimeInterval(-600)), kind: "window.changed", app: "Pages", bundle: "com.apple.iWork.Pages",
                                        title: "Quarterly pricing draft", url: "https://example.com/private/path?token=abc", synthetic: true), now: now),
              "fixture: one window")
    try store.setCaptureState("off", reason: "check", now: now)
    (access, status) = try connected()
    try check(status["recording"] == "off" && status["setup"] == "Connected, but recording is off. The person can turn DayDream on in the menu bar."
              && status["last_activity"] != "Nothing recorded yet." && status["examples"]?.contains("once there is some activity") == false,
              "readiness (capture off): says recording is off and how to turn it on")
    try clean(status, "capture off")

    // 3. Paused.
    try store.setCaptureState("paused", reason: "check", now: now)
    (access, status) = try connected()
    try check(status["recording"] == "paused" && status["setup"]?.hasPrefix("Connected, but recording is paused") == true && status["setup"]?.contains("Resume Now") == true,
              "readiness (paused): says paused and where to resume")
    try store.setCaptureState("recording", reason: "check", now: now)

    // 4. Typing switched on, no typed rows: on is not verified.
    _ = try attachTestVault(store)
    var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try store.updatePolicy(policy, now: now)
    (access, status) = try connected()
    try check(status["typing"]?.hasPrefix("switched on, not confirmed yet") == true && status["typing_verified"] == "no",
              "readiness (typing on, no typed rows): switched on, not confirmed")
    // A typed row older than the window doesn't verify it either.
    try check(try store.ingest(Evidence(id: "t-old", at: iso(now.addingTimeInterval(-MemoryStore.typingVerifiedWindow - 3600)), kind: "keyboard.text_input", app: "Notes",
                                        bundle: "com.apple.Notes", title: "Quarterly pricing draft", text: "zebrafjordsecret old words", synthetic: true), now: now),
              "fixture: a typed row from over a day ago")
    (access, status) = try connected()
    try check(status["typing_verified"] == "no", "readiness: typing saved over 24 hours ago doesn't verify typing")
    // Paused typing.
    try store.snoozeTyping(minutes: 10, now: now)
    (access, status) = try connected()
    try check(status["typing"]?.hasPrefix("paused until") == true && status["typing_verified"] == "no", "readiness (typing paused): says until when")
    try store.resumeTyping(now: now)

    // 5. Typing verified: a typed row saved lately.
    try check(try store.ingest(Evidence(id: "t-new", at: iso(now.addingTimeInterval(-120)), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes",
                                        title: "Quarterly pricing draft", text: "zebrafjordsecret pricing words", synthetic: true), now: now),
              "fixture: a typed row two minutes ago")
    (access, status) = try connected()
    try check(status["typing"]?.hasPrefix("on and working: DayDream last saved typing") == true && status["typing_verified"] == "yes",
              "readiness (typing verified): on and working, with a time")
    try clean(status, "typing verified")
    // Hidden rows don't count: excluding the app hides its typing, and it no longer verifies.
    policy = try store.policy(); policy.blockedApps = ["com.apple.Notes"]; try store.updatePolicy(policy, now: now)
    (access, status) = try connected()
    try check(status["typing_verified"] == "no", "readiness: typing in an excluded app doesn't verify typing")
    policy = try store.policy(); policy.blockedApps = []; try store.updatePolicy(policy, now: now)

    // 6. Grant missing, key stopped, partial, and no key at hand.
    try store.revoke(client: client, recipient: recipient)
    access = reader.assistantAccess(client: client, recipient: recipient, capability: "not-a-key")
    status = try reader.assistantStatus(now: now, access: access)
    try check(access == .missing && status["connected"]?.hasPrefix("no: this AI app isn't connected to DayDream") == true
              && status["setup"]?.hasPrefix("Not ready: this AI app isn't connected") == true && status["setup"]?.contains("Settings › Connections") == true,
              "readiness (grant missing): not ready, and where to connect")
    try check(status["typing_verified"] == "yes" && status["recording"] == "on", "readiness (grant missing): the rest of the check still reads")
    try check(reader.assistantAccess(client: client, recipient: recipient, capability: "") == .missing, "readiness: no key reads as not connected")
    _ = try store.grant(client: client, recipient: recipient, scopes: MemoryStore.assistantScopes)
    try check(reader.assistantAccess(client: client, recipient: recipient, capability: "an-old-key") == .keyStopped
              && (try reader.assistantStatus(now: now, access: .keyStopped))["connected"]?.contains("key no longer works") == true,
              "readiness (key stopped): the connection is on record but this key doesn't work")
    let narrow = try store.grant(client: client, recipient: recipient, scopes: ["search"])
    try check(reader.assistantAccess(client: client, recipient: recipient, capability: narrow) == .partial(["context", "detail"]),
              "readiness: a connection missing scopes names them")
    let unknown = try reader.assistantStatus(now: now)
    try check(unknown["connected"] == nil && unknown["setup"] == "Ready: DayDream is recording.", "readiness without a key says nothing about a connection")

    // 7. Chrome pages and summaries follow the saved settings; the examples only offer what works.
    (access, status) = try connected()
    try check(status["chrome_pages"]?.hasPrefix(ReleaseFeatures.chromePageHistory ? "off:" : "not in this version") == true
              && status["examples"]?.contains("Chrome") == false, "readiness: Chrome pages off, and no Chrome example")
    try check(status["summaries"]?.hasPrefix("unknown") == true && status["examples"]?.contains("this week") == false,
              "readiness: summaries unknown, and no example that needs notes")
    if ReleaseFeatures.chromePageHistory {
        policy = try store.policy(); policy.browserPages = true; policy.browserPagesConsentVersion = PrivacySettings.browserPagesConsentCurrent
        try store.updatePolicy(policy, now: now)
        (access, status) = try connected()
        try check(status["chrome_pages"]?.hasPrefix("on:") == true && status["examples"]?.contains("Chrome") == true, "readiness: Chrome pages on, with a Chrome example")
    }
    // claude/recall-1004: "starting" (the person's choice is on and kept; the writer isn't running yet) never reads as off.
    for (mode, prefix) in [("local", "on this Mac:"), ("cloud", "cloud:"), ("starting", "turned on, starting:"), ("off", "off:")] {
        try store.setSummaryWriter(mode, now: now)
        (access, status) = try connected()
        try check(status["summaries"]?.hasPrefix(prefix) == true && (status["examples"]?.contains("this week") == true) == (mode == "local" || mode == "cloud"),
                  "readiness: summaries \(mode) read as \"\(prefix)\", with note examples only when notes are written")
    }
    try clean(status, "summaries")
    let text = try json(status)
    try check(!text.contains("macmem://activities") && !text.contains("w-1") && !text.contains("t-new"), "readiness: no ids or moment links")
}
