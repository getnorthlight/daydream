import Foundation
import MemoryCore
import HistoryCore
import PrivacyPolicy

/// Saturday honesty track: what DayDream says it records must match what it records.
/// Synthetic store and fake app folders under TMPDIR only. Launch Services is never
/// asked about the made-up apps: `BrowserLookalike.locate` is replaced for these checks.
func runHonestyChecks(home: URL, now: Date) throws {
    let store = try MemoryStore(home:home,writable:true)
    let settings = try store.policy()
    func window(_ bundle:String, app:String, title:String="Fabricated window") -> Evidence {
        Evidence(id:"h-"+UUID().uuidString,at:iso(now),kind:"window.changed",app:app,bundle:bundle,title:title,synthetic:true)
    }
    try check(CaptureSession.accepts(window("com.apple.TextEdit",app:"TextEdit"),focusedFieldKnown:true,settings:settings,now:now),
              "honesty: an ordinary app window is still recorded (control)")

    // H2: every password manager named in the list is skipped before anything is saved.
    try check(PasswordManagerApps.apps.count >= 15 && PasswordManagerApps.bundleIDs.count == Set(PasswordManagerApps.bundleIDs).count,
              "honesty: the password manager list names at least 15 apps with no repeated identifiers")
    for (name, ids) in PasswordManagerApps.apps {
        try check(!ids.isEmpty && ids.allSatisfy { PrivacySettings.sensitiveApps.contains($0) }, "honesty: \(name) is on the always-private list")
        for id in ids {
            try check(!CaptureSession.accepts(window(id,app:name),focusedFieldKnown:true,settings:settings,now:now),
                      "honesty: \(name) (\(id)) is skipped before saving")
        }
    }
    for id in ["com.1password.1password","com.agilebits.onepassword7","com.bitwarden.desktop","com.apple.Passwords","com.apple.keychainaccess",
               "com.lastpass.LastPass","com.dashlane.Dashlane"] {
        try check(PasswordManagerApps.bundleIDs.contains(id), "honesty: earlier password manager entry kept: " + id)
    }
    for name in ["KeePassXC","Proton Pass","Enpass","NordPass","Keeper","RoboForm","Strongbox","MacPass"] {
        try check(PasswordManagerApps.apps.contains { $0.name == name }, "honesty: previously missing password manager added: " + name)
    }

    // H8: a browser DayDream doesn't know by name. Fake app folders; Launch Services is not asked.
    let apps = home.appendingPathComponent("fake-apps")
    func fakeApp(_ name:String, schemes:[String]) throws -> URL {
        let app = apps.appendingPathComponent(name+".app"), contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at:contents,withIntermediateDirectories:true)
        let info:[String:Any] = ["CFBundleName":name,"CFBundleURLTypes":[["CFBundleURLName":"Web","CFBundleURLSchemes":schemes]]]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:contents.appendingPathComponent("Info.plist"))
        return app
    }
    let madeUpID = "com.example.madeupbrowser", madeUpUpperID = "com.example.madeupbrowser.upper", notesID = "com.example.madeupnotes"
    let browserApp = try fakeApp("Made Up Browser", schemes:["http","https","ftp"])
    let upperApp = try fakeApp("Made Up Upper", schemes:[" HTTPS "])
    let notesApp = try fakeApp("Made Up Notes", schemes:["madeupnotes"])
    try check(!KnownBrowsers.contains(madeUpID) && !KnownBrowsers.contains(notesID), "honesty: the made-up bundle IDs are not on the known browser list")
    let savedLocate = BrowserLookalike.locate
    defer { BrowserLookalike.locate = savedLocate; BrowserLookalike.reset() }
    var asked:[String] = []
    BrowserLookalike.locate = { id in
        asked.append(id)
        switch id { case madeUpID: return [browserApp]; case madeUpUpperID: return [upperApp]; case notesID: return [notesApp]; default: return [] }
    }
    BrowserLookalike.reset()
    try check(BrowserLookalike.isUnknownBrowser(madeUpID) && BrowserLookalike.isUnknownBrowser(madeUpUpperID),
              "honesty: an unknown app that opens http or https links is treated as a browser")
    try check(!BrowserLookalike.isUnknownBrowser(notesID) && !BrowserLookalike.isUnknownBrowser("com.example.notinstalled"),
              "honesty: an unknown app without web links, or not installed, is not treated as a browser")
    let pageTitle = "Fabricated bank statement - Made Up Browser"
    try check(!CaptureSession.accepts(window(madeUpID,app:"Made Up Browser",title:pageTitle),focusedFieldKnown:true,settings:settings,now:now),
              "honesty: page titles from an unknown browser are skipped before saving")
    try check(CaptureSession.accepts(window(notesID,app:"Made Up Notes"),focusedFieldKnown:true,settings:settings,now:now),
              "honesty: an unknown app that is not a browser is still recorded")
    let session = try CaptureSession(store:store)
    try session.start(permitted:true,now:now)
    var e = window(madeUpID,app:"Made Up Browser",title:pageTitle); e.id = "h-unknown-browser"
    try check(try !session.record(e,focusedFieldKnown:true,permitted:true,now:now) && store.read("h-unknown-browser",now:now) == nil,
              "honesty: the recorder saves nothing from the made-up browser")
    asked.removeAll()
    _ = BrowserLookalike.isUnknownBrowser(madeUpID); _ = BrowserLookalike.isUnknownBrowser(madeUpID)
    try check(asked.isEmpty, "honesty: the answer for a bundle ID is remembered (Launch Services asked once)")
    try check(!BrowserLookalike.isUnknownBrowser("com.google.Chrome") && BrowserLookalike.skips("com.google.Chrome")
              && BrowserLookalike.skips(madeUpID) && !BrowserLookalike.skips(notesID)
              && BrowserLookalike.skips("com.example.other", appURL:browserApp) && !BrowserLookalike.skips("com.example.other", appURL:notesApp),
              "honesty: skips() covers known browsers, made-up browsers and an app folder read directly")
    try check(!BrowserLookalike.isUnknownBrowser("") && !BrowserLookalike.isUnknownBrowser("   "), "honesty: an empty bundle ID is never looked up")

    // H7: the release switch. Chrome pages count only when the release has them.
    var saved = PrivacySettings(); saved.browserPages = true; saved.browserPagesConsentVersion = PrivacySettings.browserPagesConsentCurrent
    try check(saved.browserPagesOn == ReleaseFeatures.chromePageHistory, "honesty: a saved Chrome pages choice counts only when the release switch is on")
    try check(ReleaseFeatures.chromePageHistory
              ? CaptureSession.recordingReason.contains("Chrome page titles")
              : !CaptureSession.recordingReason.contains("Chrome") && CaptureSession.recordingReason.contains("Web browsers are skipped"),
              "honesty: the recording status names Chrome pages only when the release has them")

    // H1: what AI apps read about the web.
    let instructions = AssistantCatalog.instructions
    // The full-typing build (every release stage) types in more apps and on websites; a narrow build in Notes and TextEdit only.
    try check(instructions.count <= 2200 && !instructions.contains("key presses") && !instructions.contains("websites were in front")
              && (TypingRelease.open ? instructions.contains("in the apps and websites they turned typing on for") && !instructions.contains("Notes or TextEdit")
                                     : instructions.contains("Notes or TextEdit")),
              TypingRelease.open ? "honesty: AI app instructions claim no key presses, and typing only where the person turned it on (summary only)"
                                 : "honesty: AI app instructions claim no website recording, no key presses, and typing only in Notes or TextEdit")
    try check(ReleaseFeatures.chromePageHistory
              ? instructions.contains("Chrome pages (title and site, if turned on; other browsers are not recorded)")
              : instructions.contains("(web browsers are not recorded)") && !instructions.contains("Chrome"),
              "honesty: AI app instructions say which browsers are recorded")

    // H2/H3: the cloud status AI apps read is the app's last reported setting, never a guess.
    let statusHome = home.appendingPathComponent("status")
    let status = try MemoryStore(home:statusHome,writable:true)
    try check(try status.status()["cloud"] == "unknown" && status.assistantStatus(now:now)["cloud_summaries"]?.hasPrefix("unknown") == true
              && status.assistantStatus(now:now)["privacy"] == AssistantView.privacy,
              "honesty: before the app reports, cloud summaries read as unknown and the privacy line is unchanged")
    try status.setSummaryWriter("cloud",now:now)
    let on = try status.assistantStatus(now:now)
    try check(try status.status()["cloud"] == "on" && on["cloud_summaries"]?.hasPrefix("on since") == true
              && on["privacy"]?.contains("OpenRouter") == true && on["privacy"]?.contains("asking for model hosts that don't keep data") == true
              && on["privacy"]?.contains("the words the person typed") == true && on["privacy"]?.contains("never the words") == false
              && on["privacy"]?.contains("Chrome page titles and sites") == true && on["privacy"]?.contains("never sent") == false && on["privacy"]?.lowercased().contains("zero data retention") == false,
              "honesty: with cloud summaries on, AI apps are told what is sent (the typed words too), to OpenRouter, which is asked for hosts that don't keep data (summaries/v3)")
    try status.setSummaryWriter("local",now:now)
    try check(try status.status()["cloud"] == "off" && status.assistantStatus(now:now)["cloud_summaries"]?.hasPrefix("off: notes are written on this Mac") == true,
              "honesty: local summaries read as cloud off")
    try status.setSummaryWriter("off",now:now)
    try check(try status.status()["cloud"] == "off" && status.assistantStatus(now:now)["privacy"] == AssistantView.privacy,
              "honesty: summaries off read as cloud off with the plain privacy line")
    var refused = false
    do { try status.setSummaryWriter("maybe",now:now) } catch { refused = true }
    try check(refused && status.summaryWriter()?.mode == "off", "honesty: an unknown summary mode is refused and the last one is kept")
    let reader = try MemoryStore(home:statusHome)
    try check(try reader.status()["cloud"] == "off", "honesty: a read-only reader (the CLI and MCP) sees the same cloud setting")
}
