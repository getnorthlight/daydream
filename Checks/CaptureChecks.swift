import Foundation
import MemoryCore
import HistoryCore
import PrivacyPolicy

func runCaptureChecks(home: URL, now: Date) throws {
    let store = try MemoryStore(home:home,writable:true)
    var consent=try store.policy(); consent.captureText=true; try store.updatePolicy(consent,now:now)
    _ = try attachTestVault(store)
    let session = try CaptureSession(store:store)
    var source = Evidence(id:"mock-native-1",at:iso(now),kind:"keyboard.text_input",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Fabricated garden notes",text:"Please draft a comparison of two garden sensors",synthetic:true)
    try check(session.state == "off", "recorder initializes OFF")
    try check(try !session.record(source,focusedFieldKnown:true,permitted:true,now:now), "OFF rejects events even with permission")
    try session.start(permitted:false,now:now)
    try check(session.state == "permission_denied", "denial does not start recorder")
    try session.health(permitted:true,now:now)
    try check(session.state == "permission_denied", "grant restoration does not auto-resume")
    try session.start(permitted:true,now:now)
    try check(try !session.record(source,focusedFieldKnown:false,permitted:true,now:now), "unknown focus fails closed")
    source.secure = true
    try check(try !session.record(source,focusedFieldKnown:true,permitted:true,now:now), "secure native event never persists")
    source.secure = false; source.privateWindow = true
    try check(try !session.record(source,focusedFieldKnown:true,permitted:true,now:now), "private native event never persists")
    source.privateWindow = false; source.bundle = "com.apple.Safari"
    try check(try !session.record(source,focusedFieldKnown:true,permitted:true,now:now), "unknown browser privacy fails closed even without private marker")
    source.bundle = "org.torproject.torbrowser"
    try check(try !session.record(source,focusedFieldKnown:true,permitted:true,now:now), "Tor bundle excluded before persistence")
    source.bundle = "unknown.browser"; source.title = "Private Browsing"
    try check(try !session.record(source,focusedFieldKnown:true,permitted:true,now:now), "private title suppresses unrecognized app too")
    source.title = "Fabricated garden notes"
    // Browsers that were missing from the three old lists, plus channels and web apps.
    // Each must be skipped as a browser: no record, hidden at read time, private titles
    // detected, and never a native typing target.
    let formerlyUnlisted = [
        "org.chromium.Chromium", "org.chromium.Thorium", "com.google.chrome.for.testing", "com.google.Chrome.canary",
        "com.google.Chrome.app.Default-abcdefghijklmnopabcdefghijklmnop", "com.kagi.kagimacOS", "app.zen-browser.zen",
        "com.operasoftware.OperaGX", "com.operasoftware.OperaAir", "com.operasoftware.OperaNext", "com.brave.Browser.beta",
        "com.brave.Browser.nightly", "com.vivaldi.Vivaldi.snapshot", "com.microsoft.edgemac.app.fixture",
        "com.apple.Safari.WebApp.0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0", "company.thebrowser.Browser", "company.thebrowser.dia",
        "org.mozilla.nightly", "net.librewolf.librewolf", "net.mullvad.mullvadbrowser", "net.waterfox.waterfox",
        "net.imput.helium", "ai.perplexity.comet", "com.openai.atlas", "ru.yandex.desktop.yandex-browser", "COM.GOOGLE.CHROME",
        // Review C11 (UNCONFIRMED identifiers).
        "com.coccoc.Coccoc", "org.qutebrowser.qutebrowser", "com.maxthon.mac.Maxthon", "org.ferdium.ferdium-app", "com.meetfranz.franz",
        "com.grupovrs.ramboxce", "com.rambox.app", "org.efounders.BrowserX",
    ]
    for bundle in formerlyUnlisted {
        source.bundle = bundle
        try check(CaptureSession.excludedBrowsers.contains(bundle) && ObservationPolicy.browserBundleIdentifiers.contains(bundle), "shared browser list covers " + bundle)
        try check(try !session.record(source,focusedFieldKnown:true,permitted:true,now:now), "unlisted-browser gap closed before persistence: " + bundle)
        var stored = source; stored.synthetic = false
        try check(Privacy.sanitized(stored,settings:try store.policy(),now:now) == nil, "read time hides earlier rows from " + bundle)
        try check(ObservationPolicy.isPrivateBrowsing(bundleIdentifier:bundle,title:"New Private Window"), "private title detected for " + bundle)
        try check(!PreCapturePrivacy.nativeTypingAllowed(bundle:bundle,role:"AXTextArea",url:"",secure:false,settings:try store.policy()), "never a native typing target: " + bundle)
    }
    // Old exact entries stay covered.
    for bundle in ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
                   "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Canary", "com.microsoft.edgemac.Dev",
                   "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "com.brave.Browser", "com.vivaldi.Vivaldi",
                   "com.operasoftware.Opera", "org.torproject.torbrowser", "org.mozilla.torbrowser", "com.duckduckgo.macos.browser",
                   "org.mozilla.librewolf"] {
        try check(CaptureSession.excludedBrowsers.contains(bundle), "previous browser entry still skipped: " + bundle)
    }
    // Prefixes are anchored at the start and exact entries stay exact.
    for bundle in ["com.apple.TextEdit", "com.apple.Notes", "com.google.drivefs.shortcuts.docs", "com.apple.Safarix",
                   "com.operasoftwarex.app", "evil.com.google.Chrome", "com.googlecode.iterm2", "", "   "] {
        try check(!CaptureSession.excludedBrowsers.contains(bundle), "not treated as a browser: '" + bundle + "'")
    }
    try check(!BrowserBundleList(["*", " * "]).contains("com.apple.TextEdit"), "a bare * entry never matches everything")
    // Review C6: the app-wide sensitive domains exist twice (MemoryCore cannot
    // import PrivacyPolicy's copy). They must be the same list.
    try check(Set(PrivacySettings.sensitiveDomains) == CaptureGate.sensitiveDomains && PrivacySettings.sensitiveDomains.count == CaptureGate.sensitiveDomains.count,
              "PrivacySettings and CaptureGate sensitive domains are identical")
    // PrivacyPolicy cannot import HistoryCore, so CaptureGate keeps a copy. It must be identical.
    try check(CaptureGate.browserPatterns == KnownBrowsers.patterns, "CaptureGate browser list is identical to the shared list")
    for bundle in formerlyUnlisted + ["com.apple.TextEdit", "com.apple.Notes", "com.apple.Safarix", "evil.com.google.Chrome", ""] {
        try check(CaptureGate.isBrowser(bundle) == KnownBrowsers.contains(bundle), "CaptureGate and shared list agree on '" + bundle + "'")
    }
    source.bundle = "com.apple.TextEdit"
    var commits = 0; session.onCommitted = { commits += 1 }
    try check(try session.record(source,focusedFieldKnown:true,permitted:true,now:now), "accepted mock native record commits")
    try check(try !session.record(source,focusedFieldKnown:true,permitted:true,now:now) && commits == 1, "duplicate source does not rewrite or schedule writer")
    let reader = try MemoryStore(home:home)
    try check(try reader.read(source.id,now:now)?.writer == "pending-local-writer", "committed evidence survives absent writer")
    var writerFailed = false
    do { _ = try reader.writePending(now:now) } catch { writerFailed = true }
    source.id = "mock-native-2"
    try check(writerFailed && (try session.record(source,focusedFieldKnown:true,permitted:true,now:now)), "writer failure is independent of subsequent capture")
    _ = try store.writePending(now:now)
    // The words are sealed, so the summary can't quote or classify them; it
    // stays a typed draft, never a request that was sent or completed.
    try check(try reader.read(source.id,now:now)?.actionState == "typed" && reader.read(source.id,now:now)?.summary.contains("garden") == false, "native request is not sent or completed")
    try check(try reader.read(source.id,now:now)?.evidence.bundle == "com.apple.TextEdit", "summary preserves source app identity")
    var observed = source; observed.kind = "selection.changed"
    try check(IntentWriter.write(observed,now:now).actionState == "observed", "selected text is not authored work")
    try session.pause("Sleep",now:now)
    source.id = "during-sleep"
    try check(try !session.record(source,focusedFieldKnown:true,permitted:true,now:now), "sleep pause rejects events")
    try session.health(permitted:true,now:now.addingTimeInterval(30))
    try check(session.state == "paused", "wake and health check do not resume")
    try session.start(permitted:true,now:now)
    try check(try !session.record(source,focusedFieldKnown:true,permitted:false,now:now) && session.state == "permission_denied", "revocation blocks intake immediately")
    try session.start(permitted:true,now:now)
    var policy = try store.policy(); policy.blockedApps = ["com.apple.TextEdit"]
    try store.updatePolicy(policy,now:now)
    try check(try !session.record(source,focusedFieldKnown:true,permitted:true,now:now), "changed exclusion applied before persistence")
    try check(try reader.read("mock-native-1",now:now) == nil && reader.read("mock-native-2",now:now) == nil, "exclusion hides original and derived evidence")
    policy.blockedApps = []; try store.updatePolicy(policy,now:now)
    source.id = "deleted-native"
    _ = try session.record(source,focusedFieldKnown:true,permitted:true,now:now)
    _ = try store.writePending(now:now); try store.delete(source.id)
    _ = try store.writePending(now:now)
    try check(try reader.read(source.id,now:now) == nil && !session.record(source,focusedFieldKnown:true,permitted:true,now:now), "delete plus retry cannot resurrect original or summary")
    try check(try store.captureStatus(now:now.addingTimeInterval(6))["state"] == "unavailable", "stale recorder heartbeat never claims live")
    let restarted = try CaptureSession(store:store)
    try check(restarted.state == "off", "restart resets prior recording state to OFF")
    let failing = try CaptureSession(store:store,persist:{ _,_ in throw MemError.database("injected write failure (code 10)") })
    try failing.start(permitted:true,now:now)
    var failed = false
    do { _ = try failing.record(source,focusedFieldKnown:true,permitted:true,now:now) } catch { failed = true }
    // A failed write stops intake at once, as a pause the app starts again by itself: never an "error" state that only
    // quitting and reopening DayDream cleared.
    try check(failed && failing.state == "paused" && failing.reason == CaptureFault.retryReason, "durable write failure pauses the recorder for a retry")
    try check(try store.captureStatus(now:now)["reason"] == CaptureFault.retryReason, "the retry pause is saved")
    try check(try !failing.record(source,focusedFieldKnown:true,permitted:true,now:now), "a paused recorder takes nothing more")
    // Another connection holding the file for a moment drops only that unit: recording goes on.
    let busy = try CaptureSession(store:store,persist:{ _,_ in throw MemError.busy("write failed (code 5)") })
    try busy.start(permitted:true,now:now)
    failed = false
    do { _ = try busy.record(source,focusedFieldKnown:true,permitted:true,now:now) } catch { failed = CaptureFault.busy(error) }
    try check(failed && busy.state == "recording", "a busy write drops the unit and recording goes on")
    try busy.stop(now:now)
    var burst = CaptureBurst()
    burst.append("prior draft",context:"app-a/field-a",safe:true)
    burst.append("unsafe",context:nil,safe:false)
    try check(burst.drain(context:"app-a/field-a",safe:true) == nil, "secure or unknown transition discards pending text")
    burst.append("app a",context:"app-a/field-a",safe:true)
    burst.append("app b",context:"app-b/field-b",safe:true)
    try check(burst.drain(context:"app-b/field-b",safe:true) == "app b", "app transition cannot mix bursts")
    burst.append("unsent",context:"app-b/field-b",safe:true)
    try check(burst.drain(context:"app-b/field-c",safe:true) == nil, "delayed flush validates current focused field")
    burst.append("paused",context:"app-b/field-b",safe:true); burst.discard()
    try check(burst.drain(context:"app-b/field-b",safe:true) == nil, "pause discards buffered characters")
    print("Capture checks use mocked events and permissions. No native capture was activated.")
}

/// Live test (build 7): "UserNotificationCenter ~4 min" was the day card's headline. macOS's alert, prompt and
/// system-UI processes are never an activity: not recorded, and a row already saved is not shown (read time runs the
/// same app rules). Not a setting, never listed as an excluded app.
func runSystemProcessChecks(now: Date) throws {
    let settings = PrivacySettings()
    func evidence(_ bundle: String, _ app: String, kind: String = "app.activated") -> Evidence {
        Evidence(id: "sys-" + app, at: iso(now), kind: kind, app: app, bundle: bundle, title: app, text: "", synthetic: true)
    }
    let system = [("com.apple.UserNotificationCenter", "UserNotificationCenter"), ("com.apple.loginwindow", "loginwindow"),
                  ("com.apple.SecurityAgent", "SecurityAgent"), ("com.apple.coreservices.uiagent", "CoreServicesUIAgent"),
                  ("com.apple.LocalAuthentication.UIAgent", "coreautha"), ("com.apple.accessibility.universalAccessAuthWarn", "universalAccessAuthWarn"),
                  ("com.apple.notificationcenterui", "Notification Center"), ("com.apple.dock", "Dock")]
    for (bundle, app) in system {
        for kind in ["app.activated", "window.changed", "mouse.click"] {
            try check(!CaptureSession.accepts(evidence(bundle, app, kind: kind), focusedFieldKnown: true, settings: settings, now: now),
                      "system process \(app) (\(kind)) is never recorded")
        }
        try check(Privacy.sanitized(evidence(bundle, app), settings: settings, now: now) == nil, "a saved \(app) row is not shown (read-time rules)")
        try check(SystemProcesses.excluded(bundle: bundle, regularApp: true), "\(app) is system noise even if it reports a regular policy")
        try check(!PrivacySettings.sensitiveApps.contains(bundle), "\(app) is not listed as an 'always private' app in Settings")
    }
    for (bundle, app) in [("com.apple.TextEdit", "TextEdit"), ("com.apple.MobileSMS", "Messages"), ("com.apple.finder", "Finder"), ("com.apple.systempreferences", "System Settings")] {
        try check(CaptureSession.accepts(evidence(bundle, app), focusedFieldKnown: true, settings: settings, now: now), "\(app) activity is still recorded")
        try check(!SystemProcesses.excluded(bundle: bundle, regularApp: true), "\(app) (a regular app) is an activity")
    }
    // The principled rule for anything not listed: a frontmost process that isn't a regular (Dock) app.
    try check(SystemProcesses.excluded(bundle: "com.example.menu-agent", regularApp: false), "an LSUIElement or background-only process in front is not an activity")
    try check(!SystemProcesses.excluded(bundle: "com.example.editor", regularApp: nil), "a stored row of an unknown app is judged by bundle ID alone")
}
