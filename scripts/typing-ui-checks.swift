// DD-RECIPE: APP
// Safe typing, ui track (typesafe SPEC 9.2 and 12.2 items 6-7, typeall SPEC-LATER 4.3):
//   A. every string the typing screens show, with the owner decisions (no "This Mac and cloud",
//      no exact-words row for AI apps, "open source"), and app lists that match the build;
//   B. the menu-bar glyph: the 4 pt dot exactly while `showsDot`, the hollow ring while paused, in
//      rendered pixels, and the VoiceOver label;
//   C. the menu rows for every typing state, and the typing tile in the Now card;
//   D. the Control-Option-Command-T shortcut through a fake registrar standing in for Carbon
//      `RegisterEventHotKey`: exact key and modifiers, the conflict message, the chosen chord;
//   E. `TypingModel` on a private store with an in-memory key store: "Turn on typing" with the
//      Keychain error and "Try again", the shortcut pause (toast, no extension), the kept period
//      with its confirmation, categories, locked, Forget;
//   F. the hosted views (Typing card in every phase, the setup screen, Apps to remember);
//   G. the app wiring on a Development Trial model (label, menu rows, Settings values);
//   H. source guarantees (Carbon only, no permission request, public builds carry no website typing UI).
// It never registers a real hot key, reads the Keychain, starts capture, opens an app or requests a
// permission: the registrar, the key store, the toast and the timers are fakes.
import AppKit
import Carbon
import SwiftUI
import MemoryCore
import MemoryUI
import PrivacyPolicy

func fail(_ message: String) -> Never {
    fflush(stdout)
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}
var checks = 0
func expect(_ condition: Bool, _ message: @autoclosure () -> String) { checks += 1; if !condition { fail(message()) } }
func pass(_ message: String) { print("PASS: \(message)"); fflush(stdout) }
func source(_ path: String) -> String {
    guard let text = try? String(contentsOfFile: FileManager.default.currentDirectoryPath + "/" + path, encoding: .utf8) else { fail("source: \(path) not readable") }
    return text
}

/// Stands in for Carbon: records every registration and keeps the handler.
final class FakeRegistrar: TypingHotkeyRegistrar {
    var answer: TypingHotkeyRegistration = .registered
    var calls: [[UInt32]] = []
    var unregisters = 0
    var handler: (() -> Void)?
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> TypingHotkeyRegistration {
        calls.append([keyCode, modifiers]); self.handler = handler; return answer
    }
    func unregister() { unregisters += 1 }
}

@main @MainActor struct TypingUIChecks {
    static let window: NSWindow = {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        return NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    }()
    static let utc = TimeZone(identifier: "UTC")!
    static let us = Locale(identifier: "en_US")
    /// 2026-09-24 15:32:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_790_263_920)

    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
            FileHandle.standardError.write(Data("FAIL: typing-ui-checks watchdog expired after 120s\n".utf8))
            exit(2)
        }
        let shared = ["/private/tmp/" + "day" + "dream-", "/tmp/" + "day" + "dream-"]
        guard let outPath = ProcessInfo.processInfo.environment["DD_CHECK_OUT"], outPath.hasPrefix("/"),
              !shared.contains(where: { outPath.hasPrefix($0) }) else {
            fail("DD_CHECK_OUT is not a private output directory; run this check through run-checks.sh")
        }
        print("BEGIN typing-ui-checks on macOS \(ProcessInfo.processInfo.operatingSystemVersionString), owner build: \(OwnerTyping.enabled)")
        if let want = ProcessInfo.processInfo.environment["DD_EXPECT_OWNER"] {
            expect((want == "1") == OwnerTyping.enabled, "compiled for the build the runner expects (DD_EXPECT_OWNER=\(want))")
        }
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        strings()
        try browserRule(out: out)
        pageNotes()
        buildLines()
        glyph()
        menuRows()
        hotkey()
        try model(out: out)
        views()
        consentKeys()
        try await appWiring(shared: shared)
        sources()
        print("\(checks) typing ui checks passed. No hot key, Keychain, capture, app launch or permission request.")
    }

    // MARK: A. Strings

    static func strings() {
        let t = TypingSettingsText.self
        expect(t.title == "Remember what you type", "title")
        // ux/declutter: "not each key" folded into the body; the short-note and AI-apps bullets merged (still said
        // before Turn on typing, decision 4). public-typing review: the example is on by default (Messages and email
        // is off), and private windows are browser windows.
        // summaries/v3 (N3, spec §13): nothing finds typed words later; notes say what you asked or sent.
        expect(t.body == "DayDream can save what you finish typing (not each key), so notes can say what you asked or sent.", "body")
        expect(t.bullets == ["Encrypted on this Mac with a key in your Keychain.",
                             "Skips password fields, private browser windows, and text that looks like a password, card number or code.",
                             "Deletes the exact words after 7 days and keeps a short note.",
                             "AI apps see a short note and your summaries, never the saved words.",
                             "Summaries read the words, so a note can say what a message was about. With an OpenRouter key, they're sent to OpenRouter to write your notes.",
                             "Anyone typing on this Mac account is recorded as you."], "the six bullets (4: AI apps get the note and summaries, decision 4; 5: summaries read the words and OpenRouter gets them, round 3)")
        // fix/apps-declutter (owner 9/29): Settings' Typing card draws nothing under its title before typing is on.
        expect(TypingSettingsValues(switchOn: false, policy: TypedTextPolicy(), vault: .notSetUp).detail == nil,
               "before typing is set up the switch shows Off with no line under the title")
        expect(!t.bullets.joined().contains("unless you allow more"), "no bullet promises AI apps more than the note (no hand-off in this version)")
        expect(t.turnOn == "Turn on typing" && t.notNow == "Not now" && t.tryAgain == "Try again", "setup buttons")
        // Integration: ux/declutter shortened this to "Couldn't turn on typing."; the owner's rule is that an error says
        // what is wrong in plain words, so the Keychain sentence stays (Try again sits beside it).
        expect(t.keyError == "DayDream couldn't create its typing key in your Keychain, so typing stays off.", "Keychain error (Try again sits beside it)")
        expect(t.locked == "Typing is paused until you unlock your Mac." && t.keyLost == "DayDream couldn't find its typing key, so the exact words you typed before are gone. Summaries are kept.", "locked and key lost")
        expect(TypingCategory.allCases.map(\.title) == ["Search boxes and AI prompts", "Writing apps", "Code", "Messages and email"], "category titles")
        expect(t.footer == "Apps not listed here are never recorded.", "footer")
        expect(TypedRetention.allCases.map(\.label) == ["1 day", "7 days", "30 days", "Forever"], "Keep exact words choices")
        expect(t.keepTitle == "Keep exact words" && t.keepHelp == "After this, DayDream deletes the exact words and keeps a short note.", "Keep exact words help")
        expect(TypedRetention.day1.shorteningConfirmation == "This deletes the exact words older than 1 day now." && t.delete == "Delete" && t.cancel == "Cancel", "shortening confirmation")
        // writer/v2 + summaries/v3: no "Let summaries read what you type" picker, and no line on the card either: the
        // consent bullet above says it once (spec §13).
        expect(!source("Sources/MemoryUI/TypingSettings.swift").contains("summariesNote"), "summaries: no picker and no card line")
        expect(t.forget == "Forget what I typed…" && t.forgetConfirmation == "Delete everything DayDream saved from your typing, including summaries, and turn typing off? This can't be undone.", "Forget says it turns typing off")
        expect(t.pause == "Pause typing for 10 minutes" && t.resume == "Record typing again", "pause and resume")
        expect(t.shortcutTaken == "This shortcut is used by another app. Pick another." && TypingPauseShortcut.toast == "Typing paused for 10 minutes", "shortcut conflict and toast")
        pass("A1 fixed strings (SPEC 9.2 with decisions 4 and 8)")

        // App lists: what this build records. The same check runs in the public build and,
        // compiled with DAYDREAM_OWNER_TYPING, in the owner build (owner-typing-ui-checks).
        let owner = OwnerTyping.enabled
        expect(!TypingRelease.expandedApproved && TypingRelease.open == owner && t.ownerBuild == owner, "the screens read the build's one switch; the legal gate stays closed")
        let allowed = Set(TypingCategory.allCases.flatMap { t.allowedApps($0) })
        let gate = Set(TypingCategories.allowedBundles(on: { _ in true }).intersection(CaptureGate.nativeApps).compactMap { TypingCategories.app($0)?.name })
        expect(allowed == gate, "the listed apps are exactly what the release gate and the capture allowlist allow (\(allowed.sorted()) vs \(gate.sorted()))")
        expect(allowed.isSuperset(of: ["Notes", "TextEdit"]), "Notes and TextEdit are listed in every build")
        // The owner gate open (as in an owner build): the list follows the gate and the capture allowlist.
        let widened = Set(t.allowedApps(.writing, expanded: true, captureAllowlist: Set(TypingCategories.apps.map(\.bundle))))
        let ownerRows = Set(TypingCategories.apps(in: .writing).filter { TypingCategories.releaseAllows($0, expanded: true) }.map(\.name))
        expect(widened == ownerRows, "with the gate open the Writing list is the table rows the gate allows")
        expect(t.allowedApps(.writing, expanded: false, captureAllowlist: Set(TypingCategories.apps.map(\.bundle))) == ["Notes", "TextEdit"],
               "with the gate closed only Notes and TextEdit are listed, whatever capture admits")
        // Setup's typing switch: its title and VoiceOver label say where this build records typing (public-typing);
        // the line under it is short (ux/v1), and where typing works is on the Turn on typing sheet. No line anywhere
        // promises more later.
        let d = DaydreamAppsContent.self
        // Opt-out setup (owner, 9/27): one plain line under the switch says what it saves, what it skips and where the
        // words go; no On/Off line (the switch says that).
        // fix/setup-status (owner 9/28): setup's typing switch is one line, "Remember what you type (skips password fields)".
        expect(!source("Sources/MemoryUI/OnboardingScreens.swift").contains("typedTextDetail")
               && source("Sources/MemoryUI/OnboardingScreens.swift").contains("switchRow(Self.typingSwitchTitle, isOn: $typedText")
               && d.typingSwitchTitle == "Remember what you type (skips password fields)",
               "setup switch: one line that says passwords are never read; no On/Off line")
        let line = t.setupLine()
        expect(line.contains("except password fields") && line.contains("on this Mac") && line.contains("summaries read it"),
               "the setup line says passwords are skipped and where the words go")
        if owner {
            expect(d.typedTextTitle == "Typed text" && d.typedTextLabel == "Include typed text in apps and on websites in Chrome",
                   "full-typing setup switch title and label name apps and websites")
            expect(["Notes", "Spotlight", "Terminal"].allSatisfy(allowed.contains), "the setup examples are apps this build records")
        }
        expect(TypingCategory.allCases.allSatisfy { !t.help($0).contains("to come") && !$0.help.contains("to come") }, "no typing line promises more to come")
        // owner/v1 review F2: the setup screen starts with where typing works (what "Turn on typing" accepts).
        expect(t.introBullets == t.scope() + t.bullets && t.scope().first == "Works in \(t.allowedAppsPhrase()).",
               "the setup screen's first bullet names the build's apps")
        expect(t.scopeWidened == "This version can record typing in more places than you turned it on for, so typing is off. Read where it works, then turn it on again.",
               "the notice when typing was turned on for fewer places")
        // summaries/v3 (owner 9/28): no Turn on typing sheet or question. fix/apps-declutter (owner 9/29): Settings' card
        // has no Learn more; the bullets stay for docs and the privacy page.
        expect(t.introBullets.first == "Works in \(t.allowedAppsPhrase()).", "the bullets name the build's apps first")
        expect(t.learnMore == "Learn more" && t.showLess == "Show less", "Settings' Typing card: Learn more / Show less")
        expect(t.short().count <= 170 && t.short().contains("except password fields") && t.short().contains("Encrypted on this Mac")
               && t.short().contains("deleted after 7 days") && !t.short().contains("\n"),
               "the typing warning is short: what it saves, what it skips, where the words are and when they go (\(t.short().count) characters)")
        if !owner {
            expect(d.typedTextTitle == "Typed text in apps" && d.typedTextScope == "\(t.allowedAppsPhrase()) only"
                   && d.typedTextLabel == "Include typed text in \(t.allowedAppsPhrase())",
                   "public: the setup switch lines name the build's apps only")
            expect(d.websiteTypingBullet == nil && t.scope() == ["Works in Notes and TextEdit."] && !t.introBullets.joined().contains("website"),
                   "public: the setup screen names Notes and TextEdit and no website")
            expect(t.allowedApps(.writing) == ["Notes", "TextEdit"] && allowed == ["Notes", "TextEdit"], "public: Notes and TextEdit only")
            expect(t.help(.writing) == "Notes and TextEdit." && t.line(.writing) == "Notes and TextEdit.", "public Writing help line")
            expect(TypingCategory.allCases.allSatisfy { t.sitesLine($0) == nil && t.sitesLine($0, websites: false) == nil }, "narrow builds name no websites")
            for c in [TypingCategory.searchAndAI, .code, .messagesAndEmail] {
                expect(t.allowedApps(c).isEmpty && t.appsLine(c) == nil, "public \(c.rawValue): no apps listed")
            }
            expect(TypingSettingsValues(switchOn: true, policy: TypedTextPolicy(), vault: .ready).categories == [.writing],
                   "public: only Writing apps gets a checkbox (no checkbox for a category with no app)")
            expect(!t.limits(keyPlace: nil).contains(TypingCategories.remoteLimit), "public: no ssh limit (no terminal recorded)")
            expect(t.help(.searchAndAI) == "Searches and questions you type in search boxes and AI apps.", "public search help names no app the build doesn't record")
            expect(t.allowedAppsPhrase() == "Notes and TextEdit" && DaydreamAppsContent.typedTextLabel == "Include typed text in Notes and TextEdit", "the public app phrase")
            expect(t.consentWhere() == "Records only in Notes and TextEdit." && !t.recordsTerminals(), "narrow build: the consent card names Notes and TextEdit only")
            expect(t.otherWebsites == nil, "public builds carry no Other websites strings")
            expect(!TypingSettingsValues(switchOn: true, policy: TypedTextPolicy(), vault: .ready, ownerBuild: true).showsOtherWebsites,
                   "even a forced owner flag can't show Other websites in a public build")
            pass("A2 app lists match the public build (Notes, TextEdit), no Other websites row")
        } else {
            let writing = t.allowedApps(.writing)
            expect(t.help(.writing) == t.list(writing) + ".", "owner Writing help names exactly the allowed apps")
            // The websites each category covers (BrowserTypingSites.rule): Code covers none.
            expect(t.sitesLine(.searchAndAI) == "Websites in Chrome: search engines and AI chats."
                   && t.sitesLine(.writing) == "Websites in Chrome: Notion."
                   && t.sitesLine(.messagesAndEmail) == "Websites in Chrome: email and chat sites, and social sites with chat, like Facebook and LinkedIn."
                   && t.sitesLine(.code) == nil
                   && TypingCategory.allCases.allSatisfy { t.sitesLine($0, websites: false) == nil },
                   "full-typing build names the websites each category covers")
            expect(TypingCategories.site(host: "notion.so") == .category(.writing) && TypingCategories.site(host: "duckduckgo.com") == .category(.searchAndAI)
                   && TypingCategories.site(host: "mail.google.com") == .category(.messagesAndEmail)
                   && !TypingCategories.sites.contains { if case .category(.code) = $0.rule { return true }; return false },
                   "the website lines match the site table (no website counts as Code)")
            expect(ChromeAccessState.notAsked.helper == "macOS will ask to let DayDream control Google Chrome. DayDream only reads the page title, the address, where Chrome's windows are and whether a window is Incognito.",
                   "full-typing build: the Chrome access line also names the window positions the typing join reads")
            // The line under a checkbox ends with its websites in Chrome where this build types on websites.
            func sites(_ c: TypingCategory) -> String { t.sitesLine(c).map { " " + $0 } ?? "" }
            // ux/declutter review: Search names its apps once, in its help line (it used to say "apps like Spotlight and
            // Claude." and then list them again).
            let search = t.allowedApps(.searchAndAI)
            expect(t.help(.searchAndAI) == (search.isEmpty ? "Searches and questions you type in search boxes and AI apps." : "Searches and questions in " + t.list(search) + ".")
                   && t.appsLine(.searchAndAI) == nil && t.line(.searchAndAI) == t.help(.searchAndAI) + sites(.searchAndAI),
                   "owner search help names exactly the allowed apps, once")
            expect(t.line(.writing) == t.help(.writing) + sites(.writing), "owner Writing: one line, the apps then the websites")
            for c in TypingCategory.allCases where c != .writing && c != .searchAndAI {
                let names = t.allowedApps(c)
                expect(t.appsLine(c) == (names.isEmpty ? nil : names.joined(separator: ", ") + "."), "owner \(c.rawValue): the apps line lists the allowed apps")
                expect(t.line(c) == t.help(c) + (names.isEmpty ? "" : " " + names.joined(separator: ", ") + ".") + sites(c), "owner \(c.rawValue): one line under the checkbox")
            }
            expect(TypingSettingsValues(switchOn: true, policy: TypedTextPolicy(), vault: .ready).categories == TypingCategory.allCases.filter { !t.allowedApps($0).isEmpty },
                   "owner: a checkbox for each category with an app")
            expect(t.limits(keyPlace: nil).contains(TypingCategories.remoteLimit) == t.recordsTerminals(), "owner: the ssh limit shows while a terminal is recorded")
            expect(t.otherWebsites?.title == "Other websites" && t.otherWebsites?.help == "Websites not listed above, except blocked sites. Never in Incognito or Guest windows. Needs Web pages in Chrome. Message boxes, webmail, and every page of social and messaging sites like Facebook, LinkedIn and X also need Messages and email.",
                   "owner builds carry the Other websites row, which says it needs Web pages in Chrome, and which websites also need Messages and email")
            expect(TypingSettingsValues(switchOn: true, policy: TypedTextPolicy(), vault: .ready).showsOtherWebsites
                   && !TypingSettingsValues(switchOn: true, policy: TypedTextPolicy(), vault: .ready, ownerBuild: false).showsOtherWebsites,
                   "the Other websites row shows in the owner build only")
            expect(TypedTextPolicy().categories.otherWebsites, "Other websites defaults on (decision 3)")
            // public-typing review: the consent card says where typing records before anyone agrees, from the
            // same gate the lists use: every app on by default (Messages and Mail too, fix/typing-e2e L1), every website but
            // blocked sites.
            let where_ = t.consentWhere()
            expect(where_ == "Records in Spotlight, Claude, ChatGPT, Notes, TextEdit, Pages, Obsidian, Terminal, Ghostty, Xcode, Cursor, Messages, Mail and WhatsApp, and, while Web pages in Chrome is on, on every website in Chrome except blocked sites.",
                   "full-typing consent card names every app, Messages and Mail included, and every website but blocked ones (\(where_))")
            expect(TypingCategory.allCases.flatMap { t.allowedApps($0) }.allSatisfy(where_.contains), "the consent card names every app the build records")
            expect(t.recordsTerminals() && t.limits(keyPlace: nil).contains(TypingCategories.terminalLimit), "a build that records terminals says the prompt latch can miss a password prompt")
            let apps = t.allowedAppsPhrase()
            expect(d.typedTextScope == "\(apps), and websites in Google Chrome while Web pages in Chrome is on",
                   "owner: the typed-text switch names websites in Google Chrome, not the apps only (review F4)")
            let web = "Also saves what you type on websites in Google Chrome while Web pages in Chrome is on, except blocked sites. Never in Incognito or Guest windows."
            expect(d.websiteTypingBullet == web && t.scope() == ["Works in \(apps).", web] && t.introBullets.prefix(2) == ["Works in \(apps).", web]
                   && !d.typedTextLabel.contains(" only") && t.short().contains("websites in Chrome"), "owner: the safe-typing screen has the website bullet (review F4)")
            pass("A2 app lists match the owner build (\(allowed.sorted().joined(separator: ", "))), Other websites row")
        }
        expect(t.list(["A"]) == "A" && t.list(["A", "B", "C"]) == "A, B and C", "the app phrase")
        expect(t.limits(keyPlace: nil).allSatisfy { !$0.contains("typing key") }, "no key place line until the place is known")
        expect(t.limits(keyPlace: .dataProtectionKeychain).contains(TypedLimitsText.key(.dataProtectionKeychain))
               && t.limits(keyPlace: .loginKeychain).contains(TypedLimitsText.key(.loginKeychain))
               && !t.limits(keyPlace: .loginKeychain).joined().contains("stays on this Mac"), "the key place line says only what holds")
        // Review G71: website typing refuses input methods too (WebTypingRoute.join needs the US, ABC or British layout),
        // so every build says input methods aren't recorded, and no line says website words can differ from what was typed.
        expect(t.limits(keyPlace: nil).first == TypedLimitsText.inputMethods && t.limits(keyPlace: .loginKeychain, terminals: true).first == TypedLimitsText.inputMethods
               && t.limits(keyPlace: nil, terminals: false).first == TypedLimitsText.inputMethods
               && !t.limits(keyPlace: .dataProtectionKeychain, terminals: true).joined(separator: " ").contains("can differ")
               && !t.limits(keyPlace: nil).joined(separator: " ").contains("In apps, input methods"),
               "G71 the input-methods line is the same in every build, and nothing says website words can differ")
        let route = (try? String(contentsOfFile: "Sources/MacMemApp/WebTypingRoute.swift", encoding: .utf8)) ?? ""
        expect(route.contains("guard environment.directKeyboardInput() else { diagnostics.count(\"web.inputMethod\"); WebTypingStatus.set(.denied); return .denied(.inputMethod) }"),
               "G71 the copy matches the code: website typing refuses input methods")
        expect(t.limits(keyPlace: nil, terminals: false).allSatisfy { $0 != TypingCategories.terminalLimit } && t.limits(keyPlace: nil, terminals: true).contains(TypingCategories.terminalLimit),
               "the terminal prompt limit shows only where terminals are typed")
        expect(t.limits(keyPlace: nil).contains(TypedLimitsText.timeMachine) && t.limits(keyPlace: nil).contains(TypedLimitsText.incognito), "limits name Time Machine and incognito chats")
        // owner/v1 merge: the Saturday honesty rule forbids "stays on this Mac" in shown text, so the promise
        // says "kept" and names OpenRouter; it is still pinned exactly and is the Settings footer too.
        // ux/declutter: the Settings footer is one shorter line with Learn more to PRIVACY.md. Both say kept (never
        // "stays"), AI apps and OpenRouter. The footer asks for FileVault only when FileVault is known to be off
        // (unknown says nothing about it, as setup).
        expect(PrivacyPromise.sentence == "Your history is kept on this Mac. AI apps you connect can read it and send what they read to their AI provider. Cloud summaries, if you turn them on, send the activity they summarize to OpenRouter."
               && DaydreamSettingsOverview.storageFooter == "Your history is kept on this Mac, and DayDream doesn't encrypt it. Connected AI apps and cloud summaries (OpenRouter) can send parts of it out."
               && DaydreamSettingsOverview.storageFooterFileVaultOff == "Your history is kept on this Mac, and DayDream doesn't encrypt it: turn on FileVault. Connected AI apps and cloud summaries (OpenRouter) can send parts of it out."
               && DaydreamSettingsOverview.footer(fileVaultOn: true) == DaydreamSettingsOverview.storageFooter
               && DaydreamSettingsOverview.footer(fileVaultOn: false) == DaydreamSettingsOverview.storageFooterFileVaultOff
               && DaydreamSettingsOverview.footer(fileVaultOn: nil) == DaydreamSettingsOverview.storageFooter,
               "privacy promise fix")
        // fix/setup-status (owner 9/28): cloud summaries get window titles, page titles and the words you type, as the
        // switch's own line says (the same sentence honesty-ui-checks pins).
        expect(PrivacyPromise.cloudLimit == "Cloud summaries get window titles, page titles and the words you type."
               && !PrivacyPromise.cloudLimit.contains("never get") && !PrivacyPromise.cloudLimit.contains("exact words"),
               "cloud limit says what is sent: window titles, page titles and typed words")
        expect(TypedClaim.openSourcePublished && TypedClaim.sentence.hasSuffix(", and it's all open source.") && TypedClaim.short.contains("open source (MIT)") && !TypedClaim.short.contains("Apache"),
               "open source is claimed (decision 5)")
        pass("A3 owner-only rows, limits, privacy promise and the open-source claim")
    }

    // MARK: A4. One rule for browser look-alikes and typing (owner/v1 review)

    /// Every typing-table app is given a fake installed copy that opens web links (as ChatGPT does), so
    /// Launch Services is never asked. An app this build types in is known by name: recorded, listed as
    /// Included (so it can be excluded), never skipped as an unknown browser. Any other table app that opens
    /// web links is still skipped as a browser. Public builds: only Notes and TextEdit are typed in, so ChatGPT
    /// stays skipped exactly as in sat/v1.
    static func browserRule(out: URL) throws {
        let apps = out.appendingPathComponent("lookalike-apps", isDirectory: true)
        var paths: [String: URL] = [:]
        for row in TypingCategories.apps {
            let app = apps.appendingPathComponent(row.bundle + ".app"), contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": row.bundle, "CFBundleURLTypes": [["CFBundleURLName": "Web", "CFBundleURLSchemes": ["http", "https"]]]]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            paths[row.bundle] = app
        }
        let savedLocate = BrowserLookalike.locate
        defer { BrowserLookalike.locate = savedLocate; BrowserLookalike.reset() }
        BrowserLookalike.locate = { id in paths[id].map { [$0] } ?? [] }
        BrowserLookalike.reset()
        let settings = PrivacySettings()
        let now = Date()
        for row in TypingCategories.apps {
            let typed = CaptureGate.nativeApps.contains(row.bundle), path = paths[row.bundle]!.path
            expect(BrowserLookalike.opensWebLinks(appAt: paths[row.bundle]!), "\(row.name): the fake copy opens web links")
            expect(BrowserLookalike.isUnknownBrowser(row.bundle) == !typed && BrowserLookalike.skips(row.bundle) == !typed
                   && BrowserLookalike.skips(row.bundle, appURL: paths[row.bundle]!) == !typed,
                   "\(row.name): \(typed ? "typed in this build, so never an unknown browser" : "not typed in this build, so skipped as a browser")")
            let group = SettingsAppsContent.group(row.bundle, excluded: [], path: path)
            if typed {
                expect(group != .notRecorded && SettingsAppsContent.group(row.bundle, excluded: [row.bundle], path: path) == .excludedByYou,
                       "\(row.name): Apps to remember doesn't list a typed app as a web browser, and it can be excluded (\(group.rawValue))")
            } else {
                expect(group == .notRecorded || group == .alwaysPrivate, "\(row.name): listed as a web browser, not recorded (\(group.rawValue))")
            }
        }
        // No bundle is both skipped as a browser and in the typing allowlist.
        expect(CaptureGate.nativeApps.allSatisfy { !BrowserLookalike.skips($0) && !BrowserLookalike.skips($0, appURL: paths[$0]) }, "no typed app is skipped as a browser")
        let chatGPT = "com.openai.codex"
        let window = Evidence(id: "lookalike", at: iso(now), kind: "window.changed", app: "ChatGPT", bundle: chatGPT, title: "New chat", synthetic: true)
        let ownerTyped = OwnerTyping.enabled && CaptureGate.nativeApps.contains(chatGPT)
        expect(CaptureSession.accepts(window, focusedFieldKnown: true, settings: settings, now: now) == ownerTyped
               && (SettingsAppsContent.group(chatGPT, excluded: [], path: paths[chatGPT]!.path) == .included) == ownerTyped,
               ownerTyped ? "owner: ChatGPT is typed, recorded and listed as Included" : "public: ChatGPT opens web links, so it is skipped and listed as a web browser (as in sat/v1)")
        if !OwnerTyping.enabled { expect(CaptureGate.nativeApps == TypingRelease.buildFourApps, "public: only Notes and TextEdit are typed in, so the rule changes nothing") }
        // The "Web pages in Chrome" card says what its build saves: public builds keep consent text 1 ("never ...
        // what you type"); the owner build, which saves website typing, shows its own text as consent 2.
        let explanation = ChromePagesCard.explanation.joined(separator: "\n")
        var pages = PrivacySettings(); pages.browserPages = true; pages.browserPagesConsentVersion = 1
        #if DAYDREAM_OWNER_TYPING
        expect(PrivacySettings.browserPagesConsentCurrent == 2 && explanation.contains(WebTypingText.chromeCard)
               && !explanation.contains("what you type") && explanation.contains("What you type on websites in Google Chrome is saved while typing is on"),
               "owner: the Chrome card says website typing is saved, and never that typing isn't")
        expect(!pages.browserPagesOn, "owner: a consent given to the public Chrome text (1) doesn't count")
        pages.browserPagesConsentVersion = 2
        expect(pages.browserPagesOn == ReleaseFeatures.chromePageHistory, "owner: consent to the owner text (2) counts")
        #else
        expect(PrivacySettings.browserPagesConsentCurrent == 1 && ChromePagesCard.explanation.count == 8
               && ChromePagesCard.explanation[0].hasSuffix("It never saves what's on the page, what you type, or your clicks.")
               && !explanation.contains("What you type on websites"), "public: the Chrome card keeps consent text 1")
        expect(pages.browserPagesOn == ReleaseFeatures.chromePageHistory, "public: consent 1 counts")
        #endif
        pass("A4 one rule: an app the build types in is never a browser look-alike (\(OwnerTyping.enabled ? "owner" : "public") build)")
    }

    // MARK: A5. Apps to remember: no standing paragraphs; recording comes back, and a disconnect gets one line (ux/v1)

    /// The app list, the typing switch and Web pages in Chrome save through PreferenceSave: recording stops while the
    /// change saves (unchanged) and starts again after it, and every grant is revoked (unchanged). The page says only
    /// what happened: which AI apps were disconnected, with one Reconnect. The Typing card's other choices save through
    /// TypingModel, which does neither.
    static func pageNotes() {
        let settings = source("Sources/MacMemApp/DaydreamSettings.swift"), typingModel = source("Sources/MacMemApp/TypingModel.swift")
        let app = source("Sources/MacMemApp/MacMemApp.swift"), autosave = source("Sources/MacMemApp/PreferenceAutosave.swift")
        expect(MemoryViewModel.aiAppsDisconnectedLine(["Claude Desktop"]) == "Claude Desktop was disconnected."
               && MemoryViewModel.aiAppsDisconnectedLine(["Claude Desktop", "Cursor"]) == "Claude Desktop and Cursor were disconnected."
               && MemoryViewModel.aiAppsDisconnectedLine(["Claude Desktop", "Cursor", "Windsurf"]) == "Claude Desktop, Cursor and Windsurf were disconnected.",
               "the disconnect line names the apps")
        expect(!settings.contains("stopNote") && !settings.contains("aiAppsDisconnectedNote") && !app.contains("aiAppsDisconnectedNote")
               && settings.contains("MemoryViewModel.aiAppsDisconnectedLine(disconnected.map(\\.app.name))") && settings.contains("action: reconnect")
               && settings.contains("await connection.connect(app)"),
               "no standing paragraphs; one line and one Reconnect (Connect, the person's own click) after a save disconnected AI apps")
        // Stop-before-save and the grant revocation are unchanged; only a stop of recording the person had on is undone.
        expect(autosave.contains("stopProducer() // Synchronous, before debounce, including restrictive failures.")
               && app.contains("if self.recording {self.resumeAfterSave=true}")
               // gold/int: behind a lock or asleep the wake rules start it instead (save-path CRITIC-GAP-autosave).
               && app.contains("if resume && !recordingTrial && !functionalTrial && setupStepForStart() == nil {")
               && app.contains("else {startCapture()}")
               && app.components(separatedBy: "private func personActed() {")[1].components(separatedBy: "}")[0].contains("resumeAfterSave=false"),
               "recording the person had on starts again after the save, through startCapture; Pause or Stop cancels that")
        expect(!["revoke(", "queuePreferences", "stopForPreferences", "savePolicy", "PreferenceSave"].contains(where: typingModel.contains),
               "the Typing card's own choices (TypingModel) neither stop recording nor disconnect AI apps")
        pass("A5 apps page: no paragraphs, recording comes back after a save, a disconnect gets one line and Reconnect")
    }

    // MARK: A6. Shared lines say what their build types in (owner/v1 review)

    /// Help › Report a Problem and the Input Monitoring purpose name Notes and TextEdit only in public builds.
    /// An owner build says it is one, so a triager knows typing can happen in more apps and on websites.
    static func buildLines() {
        let snapshot = DiagnosticsSnapshot(version: "0.1.0", build: "7", macOS: "26.0.0", architecture: "Apple silicon", appLocation: "/Applications/DayDream.app",
                                           dataFolder: "/Users/someone/Library/Application Support/DayDream", databaseBytes: nil, recording: "Off", problem: nil,
                                           accessibility: true, inputMonitoring: true, typedText: true, chromePages: "Off", summaries: "Off", connectedApps: [])
        let report = Diagnostics.report(snapshot, log: [], userHome: "/Users/someone", redactions: [])
        let lines = report.split(separator: "\n").map(String.init)
        let permissions = source("Sources/MemoryUI/PermissionSetup.swift")
        let gated = permissions.components(separatedBy: "#if DAYDREAM_OWNER_TYPING")
        expect(gated.count == 2 && gated[1].components(separatedBy: "#else")[0].contains("typing in the apps and websites you turn typing on for")
               && gated[1].components(separatedBy: "#else")[1].components(separatedBy: "#endif")[0].contains("typing in Notes and TextEdit only if you turn typed text on")
               && permissions.components(separatedBy: "Notes and TextEdit").count == 3, "the Input Monitoring lines name Notes and TextEdit only in the public branch")
        if OwnerTyping.enabled {
            // ux/declutter: the label is "Typed text"; the Typing build line right under App: says typing reaches more
            // apps and websites (it never says "Owner build").
            expect(lines.contains("Typed text: on") && !report.contains("Notes and TextEdit")
                   && lines.firstIndex(of: "Typing build: more apps and websites in Google Chrome (each off until turned on)") == (lines.firstIndex { $0.hasPrefix("App: ") } ?? -9) + 1
                   && !report.contains("Owner build"),
                   "full typing: the report names the typing build and doesn't limit typing to Notes and TextEdit")
        } else {
            expect(lines.contains("Typed text (Notes and TextEdit): on") && !report.contains("Typing build") && !report.contains("Owner build"), "narrow build: the report's typing line is unchanged and names no typing build")
        }
        pass("A6 report and permission lines match the \(OwnerTyping.enabled ? "owner" : "public") build")
    }

    // MARK: B. Glyph

    static func alpha(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat, scale: CGFloat) -> CGFloat {
        rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.alphaComponent ?? 0
    }

    static func glyph() {
        let states: [TypingIndicatorState] = [.off, .locked(.notAccepted), .locked(.keychainLocked), .snoozed(until: now), .snoozed(until: nil), .notHere, .recording(app: "Notes")]
        for s in states {
            let badge = DaydreamTypingBadge(s)
            expect((badge == .dot) == s.showsDot && (badge == .ring) == s.showsRing, "badge for \(s): dot exactly while showsDot, ring exactly while showsRing")
        }
        expect(DaydreamTypingBadge(nil) == .none, "no typing state: no badge")
        for state in DaydreamCaptureState.allCases {
            for scale in [1, 2] as [CGFloat] {
                guard let base = DaydreamMenuBarMark.bitmap(state, scale: scale), let none = DaydreamMenuBarMark.bitmap(state, badge: .none, scale: scale),
                      let dot = DaydreamMenuBarMark.bitmap(state, badge: .dot, scale: scale), let ring = DaydreamMenuBarMark.bitmap(state, badge: .ring, scale: scale) else { fail("bitmap") }
                expect(base.bitmapData.map { Data(bytes: $0, count: base.bytesPerPlane) } == none.bitmapData.map { Data(bytes: $0, count: none.bytesPerPlane) },
                       "\(state) @\(scale)x: no badge draws the mark unchanged")
                let c = DaydreamMarkGeometry.standard.badgeCenter
                expect(alpha(dot, c.x, c.y, scale: scale) > 0.9, "\(state) @\(scale)x: the dot is solid at its centre")
                expect(alpha(ring, c.x, c.y, scale: scale) < 0.1, "\(state) @\(scale)x: the ring is hollow")
                expect(alpha(ring, c.x - 1.6, c.y, scale: scale) > 0.5 || alpha(ring, c.x - 1.4, c.y, scale: scale) > 0.5, "\(state) @\(scale)x: the ring has ink")
                if scale == 2 {
                    // Clear space around the badge: 2.5 pt from its centre is inside the 1 pt gap.
                    expect(alpha(dot, c.x - 2.6, c.y, scale: scale) < 0.1 && alpha(ring, c.x - 2.6, c.y, scale: scale) < 0.1, "\(state): the badge sits in a clear gap")
                }
            }
            expect(DaydreamMenuBarMark.image(for: state, badge: .dot).isTemplate && DaydreamMenuBarMark.image(for: state, badge: .ring).isTemplate, "\(state): badge images stay template images")
        }
        let recording = RecordingState.recording(since: now.addingTimeInterval(-600))
        let dotLabel = DaydreamMenuBarLabelImage(state: recording, now: now, timeZone: utc, typing: .recording(app: "Notes"))
        expect(dotLabel.badge == .dot && dotLabel.label == "DayDream: Recording. DayDream is recording what you type", "label with the dot: \(dotLabel.label)")
        let ringLabel = DaydreamMenuBarLabelImage(state: recording, now: now, timeZone: utc, typing: .snoozed(until: now.addingTimeInterval(600)))
        expect(ringLabel.badge == .ring && ringLabel.label.hasPrefix("DayDream: Recording. Typing paused until"), "label with the ring: \(ringLabel.label)")
        for s in [TypingIndicatorState.off, .notHere, .locked(.notAccepted)] {
            let plain = DaydreamMenuBarLabelImage(state: recording, now: now, timeZone: utc, typing: s)
            expect(plain.badge == .none && plain.label == "DayDream: Recording", "no dot or ring for \(s)")
        }
        pass("B the dot and the ring on the glyph, in pixels at 1x and 2x, and the VoiceOver label")
    }

    // MARK: C. Menu rows

    static func menuRows() {
        func rows(_ s: TypingIndicatorState, _ shortcut: String? = "⌃⌥⌘T") -> TypingMenuRows { TypingMenuRows(state: s, shortcut: shortcut, timeZone: utc, locale: us) }
        let recording = rows(.recording(app: "Notes"))
        // The line under the panel's status, and the typing item of its Pause submenu (title, the shortcut drawn beside it).
        expect(recording.line == "Recording what you type in Notes" && recording.menuItem?.title == "Pause Typing for 10 Minutes"
               && recording.menuItem?.keys == "⌃⌥⌘T" && recording.menuItem?.action == .pause && recording.lineAction == nil, "recording rows")
        expect(TypingPauseShortcut.display == "⌃⌥⌘T" && TypingPauseShortcut.minutes == 10, "the pause shortcut and length the item names")
        let notHere = rows(.notHere)
        expect(notHere.line == "Not recording typing in this app" && notHere.menuItem?.action == .pause, "not here rows")
        let until = Date(timeIntervalSince1970: 1_790_264_520) // 15:42 UTC
        let snoozed = rows(.snoozed(until: until))
        // While typing is paused the line itself resumes: it ends in Resume, one click, and Pause › only pauses.
        expect(snoozed.line == "Typing paused until 3:42 PM" && snoozed.lineAction == .resume && snoozed.lineActionTitle == "Resume"
               && snoozed.lineActionHint == "Resumes recording what you type" && snoozed.menuItem == nil, "snoozed rows: \(snoozed.line ?? "nil")")
        expect(rows(.snoozed(until: nil)).lineAction == .resume && rows(.snoozed(until: nil)).menuItem == nil, "snoozed with no end: the line resumes")
        expect(recording.lineActionTitle == nil && recording.lineActionHint == nil && notHere.lineAction == nil && notHere.lineActionTitle == nil,
               "recording and not-here lines only say what happens")
        let locked = rows(.locked(.notAccepted))
        expect(locked.line == "Typing is locked: turn it on in Settings" && locked.lineAction == .openSettings && locked.menuItem == nil
               && locked.lineActionTitle == nil && locked.lineActionHint == "Opens Apps to remember in DayDream Settings", "locked rows")
        expect(rows(.locked(.keychainLocked)).line == "Typing is paused until you unlock your Mac.", "Keychain locked row")
        expect(!rows(.off).shown && rows(.off).menuItem == nil, "typing off: no rows")
        expect(rows(.recording(app: "Notes"), nil).menuItem?.keys == nil && rows(.recording(app: "Notes"), nil).menuItem?.title == "Pause Typing for 10 Minutes",
               "no shortcut shown when none is registered")
        // The Pause submenu carries the item after the recording lengths, one click from the panel.
        let items = MenuBarMenu.pauseItems(typing: recording)
        expect(items.count == 5 && items[4].title == "Pause Typing for 10 Minutes" && items[4].keys == "⌃⌥⌘T" && items[4].action == .typing(.pause)
               && items[4].separatorBefore, "Pause ›: Pause Typing for 10 Minutes ⌃⌥⌘T after the lengths")
        expect(MenuBarMenu.pauseItems(typing: snoozed).count == 4 && !MenuBarMenu.pauseItems(typing: snoozed).contains { $0.action == .typing(.resume) },
               "Pause ›: only pauses while typing is paused (Resume is on the typing line)")
        expect(MenuBarMenu.pauseItems(typing: locked).count == 4 && MenuBarMenu.pauseItems(typing: rows(.off)).count == 4, "Pause ›: no typing item while typing is off or locked")
        var ran: [String] = []
        let actions = TypingMenuActions(pause: { ran.append("pause") }, resume: { ran.append("resume") }, openSettings: { ran.append("settings") })
        actions.perform(.pause); actions.perform(.resume); actions.perform(.openSettings)
        expect(ran == ["pause", "resume", "settings"], "each row runs exactly its action")

        // The panel: one quiet line under the status only while typing is on (the typing state is never hidden).
        let presentation = CapturePresentation(state: .recording(since: now.addingTimeInterval(-600)), canResume: true, canStop: true)
        func height(_ r: TypingMenuRows?) -> NSSize {
            NSHostingView(rootView: MenuBarMenu(presentation: presentation, actions: CaptureActions(), snapshot: nil, now: now,
                                                typing: r).environment(\.daydreamStatic, true)).fittingSize
        }
        let bare = height(nil), off = height(rows(.off)), on = height(recording), paused = height(snoozed), lockedSize = height(locked)
        expect(bare.width == 320 && on.width == 320 && paused.width == 320 && lockedSize.width == 320, "the panel stays 320 pt wide with the typing line")
        expect(off.height == bare.height && on.height > bare.height + 10 && paused.height > bare.height + 10 && lockedSize.height > bare.height + 10,
               "the typing line shows only while typing is on (\(bare.height) \(off.height) \(on.height))")
        pass("C menu rows for every typing state and the panel's typing line")
    }

    // MARK: D. Shortcut

    static func hotkey() {
        let fake = FakeRegistrar()
        var pressed = 0
        let status = TypingHotkey.register(.t, registrar: fake) { pressed += 1 }
        expect(status == .registered(.t) && fake.calls == [[17, 0x1900]], "registered once: kVK_ANSI_T with exactly controlKey|optionKey|cmdKey (\(fake.calls))")
        expect(UInt32(controlKey | optionKey | cmdKey) == 0x1900 && TypingPauseChord.carbonModifiers == 0x1900, "Carbon modifiers: Control, Option, Command, no Shift")
        fake.handler?()
        expect(pressed == 1, "the registered handler runs the pause")
        expect(status.activeDisplay == "⌃⌥⌘T", "the menu shows ⌃⌥⌘T while it is registered")
        fake.answer = .taken
        let taken = TypingHotkey.register(.t, registrar: fake) {}
        expect(taken == .taken(.t) && taken.activeDisplay == nil, "a chord another app holds is reported, and the menu shows no shortcut")
        let row = DaydreamTypingSettings.shortcut(taken)
        expect(row?.message == "This shortcut is used by another app. Pick another." && row?.choices == ["⌃⌥⌘T", "⌃⌥⌘Y", "⌃⌥⌘P"] && row?.selected == 0,
               "Settings: the conflict message and the other shortcuts to pick")
        expect(DaydreamTypingSettings.shortcut(.failed(.y))?.message == TypingSettingsText.shortcutFailed && DaydreamTypingSettings.shortcut(.registered(.p))?.message == nil
               && DaydreamTypingSettings.shortcut(.registered(.p))?.selected == 2 && DaydreamTypingSettings.shortcut(.notInstalled) == nil, "Settings shortcut row per status")
        fake.answer = .registered
        _ = TypingHotkey.register(.y, registrar: fake) {}
        expect(fake.calls.last == [16, 0x1900] && TypingHotkey.chord == .y, "another letter registers that letter")
        expect(TypingHotkey.isPauseChord(KeyStroke(keyCode: 16, command: true, control: true, option: true))
               && !TypingHotkey.isPauseChord(KeyStroke(keyCode: 17, command: true, control: true, option: true)), "EventCapture skips the marker for the chosen chord only")
        _ = TypingHotkey.register(.t, registrar: fake) {}
        expect(TypingHotkey.isPauseChord(KeyStroke(keyCode: 17, command: true, control: true, option: true))
               && !TypingHotkey.isPauseChord(KeyStroke(keyCode: 17, command: true, control: true, option: true, shift: true)), "back to ⌃⌥⌘T")
        expect(TypingHotkey.appRegistrar() == nil, "this check program is not an app bundle: the production default registers no real shortcut")
        let fakeApp = ProcessInfo.processInfo.environment["DD_CHECK_OUT"]! + "/Fake-\(UUID().uuidString).app"
        try? FileManager.default.createDirectory(atPath: fakeApp, withIntermediateDirectories: true)
        let appBundle = Bundle(path: fakeApp)
        expect(appBundle.map { TypingHotkey.appRegistrar(bundle: $0) is CarbonTypingHotkeyRegistrar } == true, "inside an .app the default is Carbon (constructed, never registered here)")
        pass("D the shortcut: Carbon key and modifiers, the conflict message, the chosen chord")
    }

    // MARK: E. TypingModel on a private store

    static func model(out: URL) throws {
        let home = out.appendingPathComponent("typing-ui-" + UUID().uuidString, isDirectory: true).appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        let keys = InMemoryTypedKeyStore()
        try store.attachVault(TypedTextVault(keyStore: keys), now: now)
        let defaults = UserDefaults(suiteName: "typing-ui-checks-" + UUID().uuidString)!
        let model = TypingModel(now: { now })
        var front = "com.apple.Notes"
        var toasts: [String] = []
        var waits: [TimeInterval] = []
        var scheduled: [() -> Void] = []
        model.frontmostBundle = { front }
        model.presentToast = { toasts.append($0) }
        model.after = { seconds, work in waits.append(seconds); scheduled.append(work); return DispatchWorkItem {} }
        model.defaults = defaults
        let fake = FakeRegistrar()
        model.attach(store, hotkeys: fake)
        expect(model.hotkey == .notInstalled && fake.calls.isEmpty, "typing not turned on: the shortcut is not taken from other apps")
        model.refresh()
        func values() -> TypingSettingsValues {
            TypingSettingsValues(switchOn: (try? store.policy().captureText) ?? false, policy: model.policy, vault: model.vault, keyLost: model.keyLost,
                                 shortcut: DaydreamTypingSettings.shortcut(model.hotkey), setupFailed: model.setupFailed, now: now)
        }
        expect(model.indicator == .off && values().phase == .intro && !model.setUp, "a new store: typing off, the setup screen")

        keys.failSaves = true
        expect(!model.turnOn() && model.setupFailed && model.vault != .ready && values().phase == .intro, "the key can't be made: the Keychain error, typing stays off")
        expect(!store.typingUnlocked && model.hotkey == .notInstalled && fake.calls.isEmpty, "no key, no typing, no shortcut")
        keys.failSaves = false
        expect(model.turnOn() && !model.setupFailed && model.vault == .ready && model.policy.consented && model.setUp, "Try again makes the key and records the answer")
        expect(model.hotkey == .registered(.t) && fake.calls == [[17, 0x1900]], "typing on: ⌃⌥⌘T is registered once through the registrar it is given")
        model.refresh(); model.refresh()
        expect(fake.calls.count == 1, "refreshing does not register again")
        expect(values().phase == .off, "set up, switch still off")
        _ = try store.savePreferences(MemoryPreferences(blockedApps: [], nativeTyping: true), expectedRevision: try store.policy().revision)
        try store.setCaptureState("recording", reason: "synthetic fixture", now: now)
        model.refresh()
        expect(values().phase == .on && model.indicator == .recording(app: "Notes") && model.indicator.showsDot, "on and recording in Notes: the dot")
        front = "com.apple.TextEdit"; model.refresh()
        expect(model.indicator == .recording(app: "TextEdit"), "front app follows")
        front = "com.example.NotInTheTypingTable"; model.refresh()
        expect(model.indicator == .notHere && !model.indicator.showsDot, "an app no build records: no dot")
        // typing-all final review: Spotlight holds key focus in front of an app
        // no build records, and never becomes the frontmost app. The dot is
        // judged for where the keys go.
        model.keyPanel = { "com.apple.Spotlight" }; model.refresh()
        if OwnerTyping.enabled {
            expect(model.indicator == .recording(app: "Spotlight") && model.indicator.showsDot && model.judgedBundle == "com.apple.Spotlight",
                   "owner: Spotlight over an unrecorded app shows the dot (\(model.indicator))")
        } else {
            expect(model.indicator == .notHere && !model.indicator.showsDot, "public: Spotlight is never recorded, no dot")
        }
        model.keyPanel = { nil }
        model.keyTargetSeen("com.example.NotInTheTypingTable")
        expect(model.indicator == .notHere && model.judgedBundle == "com.example.NotInTheTypingTable", "Spotlight closed: the front app is judged again")
        front = "com.apple.Notes"

        // The shortcut: pause typing for 10 minutes once; pressing again doesn't extend it.
        // gold/r3-typing: the recorder decides its late keys (`willPause`) before the pause is saved, with the time the
        // Carbon handler noted for that press.
        var willPause: [(UInt64?, Bool)] = []
        model.willPause = { at in willPause.append((at, ((try? store.typedTextPolicy())?.snoozed(now: now)) ?? true)) }
        TypingHotkey.notePress(at: 4_242)
        fake.handler?()
        expect(willPause.count == 1 && willPause[0].0 == 4_242 && willPause[0].1 == false,
               "the shortcut lets the recorder decide its late keys first, with the chord's press time, before the pause is saved (\(willPause))")
        expect(model.indicator == .snoozed(until: now.addingTimeInterval(600)) && model.indicator.showsRing, "the shortcut pauses typing for 10 minutes: the ring")
        expect(toasts == ["Typing paused for 10 minutes"] && model.toast == "Typing paused for 10 minutes", "the toast shows once")
        expect(waits.contains(2) && waits.contains(where: { abs($0 - 600.5) < 0.01 }) && model.refreshAt == now.addingTimeInterval(600),
               "the toast hides after 2 s and the model reads again when the pause ends (\(waits))")
        let saved = model.policy.snoozeUntil
        TypingHotkey.notePress(at: 5_353)
        fake.handler?()
        expect(toasts.count == 1 && model.policy.snoozeUntil == saved, "pressing it again while paused does nothing")
        expect(willPause.count == 1 && TypingHotkey.takePress() == nil, "pressing it again while paused decides nothing, and its press time is used up")
        scheduled.forEach { $0() }
        expect(model.toast == nil, "the toast clears")
        try model.resume(frontmostBundle: front)
        expect(model.indicator == .recording(app: "Notes") && model.refreshAt == nil, "Record typing again")
        // The menu's and Settings' pause (no chord): the recorder decides first too, with no press time.
        try model.snooze(frontmostBundle: front)
        expect(willPause.count == 2 && willPause[1].0 == nil && willPause[1].1 == false, "the menu's pause lets the recorder decide first, with no chord time (\(willPause))")
        try model.resume(frontmostBundle: front)
        model.willPause = { _ in }
        try store.setCaptureState("off", reason: "synthetic fixture", now: now)
        fake.handler?()
        expect(model.indicator == .off && !model.snoozed && toasts.count == 1, "recording off: the shortcut pauses nothing and shows nothing")
        try store.setCaptureState("recording", reason: "synthetic fixture", now: now)
        model.refresh()

        // Keep exact words: shorter needs the confirmation first.
        expect(model.needsConfirmation(.day1) && !model.needsConfirmation(.days30), "shorter needs a confirmation, longer doesn't")
        expect(!model.setRetention(.day1, confirmed: false) && model.policy.retention == .days7, "not confirmed: nothing changes")
        expect(model.setRetention(.day1, confirmed: true) && model.policy.retention == .day1, "Delete: 1 day")
        expect(model.setRetention(.days30, confirmed: false) && model.policy.retention == .days30, "longer saves at once")
        // Summaries: no choice to save (writer/v2); the stored value stays the default and is ignored.
        expect(model.policy.shareWithSummaries == .off, "no summaries choice is saved")
        // Categories.
        model.setCategory(.messagesAndEmail, on: true)
        expect(model.policy.categories.messagesAndEmail && !model.saveFailed, "Messages and email on")
        model.setCategory(.writing, on: false); model.refresh()
        expect(model.indicator == .notHere, "Writing off: not recording in Notes")
        model.setCategory(.writing, on: true); model.setCategory(.messagesAndEmail, on: false); model.refresh()
        expect(model.indicator == .recording(app: "Notes"), "Writing on again")
        model.setOtherWebsites(false)
        expect(!model.policy.categories.otherWebsites, "Other websites saves (owner builds show it)")
        model.setOtherWebsites(true)

        // Locked Keychain.
        keys.locked = true; _ = try store.reconcileTypedVault(now: now); model.refresh()
        expect(values().phase == .locked && model.indicator == .locked(.keychainLocked) && !model.indicator.showsDot, "locked Keychain: paused, no dot")
        keys.locked = false; _ = try store.reconcileTypedVault(now: now); model.refresh()
        expect(model.indicator == .recording(app: "Notes"), "unlocked again")

        // The chosen chord is remembered here only.
        model.choose(.p)
        expect(model.hotkey == .registered(.p) && fake.calls.last == [35, 0x1900] && TypingPauseChord.saved(defaults) == .p, "another shortcut is registered and remembered")
        model.choose(.t)
        expect(model.hotkey == .registered(.t) && TypingPauseChord.saved(defaults) == .t && defaults.string(forKey: TypingPauseChord.defaultsKey) == nil, "back to the default")

        // Forget.
        expect(model.forget() && !model.policy.consented && values().phase == .intro && model.indicator == .locked(.notAccepted), "Forget: typing is off until turned on again")
        // public-typing review, then fix/typing-e2e: the saved switch is still on here, but typing records nothing, so the
        // card draws the switch off (one click turns typing on again), never on; the host turns it off after Forget
        // (section H), which leaves the menu off, not locked.
        expect(!values().showsSwitch && values().phase == .intro, "after Forget with the switch still saved on, the card draws the switch off, as typing is")
        // The host's preference save stops recording first (queuePreferences); the store refuses otherwise.
        try store.setCaptureState("off", reason: "synthetic fixture", now: now)
        _ = try store.savePreferences(MemoryPreferences(blockedApps: [], nativeTyping: false), expectedRevision: try store.policy().revision)
        model.refresh()
        expect(model.indicator == .off && !values().showsSwitch, "Forget with the switch turned off: the menu shows typing off, not a lock")
        expect(model.hotkey == .notInstalled && fake.unregisters >= 1, "Forget lets the shortcut go")
        model.choose(.y)
        expect(model.hotkey == .notInstalled && fake.calls.last == [17, 0x1900], "no shortcut can be chosen while typing is off")
        // The checks below start from the typing switch on and recording, as before the switch was turned off above
        // (integration: the public-typing review's switch-off step now comes first).
        _ = try store.savePreferences(MemoryPreferences(blockedApps: [], nativeTyping: true), expectedRevision: try store.policy().revision)
        try store.setCaptureState("recording", reason: "synthetic fixture", now: now)
        // owner/v1 review F2: a consent saved for fewer places than this build records (an older
        // build's, or a narrower one) keeps typing locked until "Turn on typing" accepts the new scope.
        try store.acceptSafeTyping(now: now, scope: TypedConsentScope(apps: ["com.apple.Notes"], websites: false))
        model.refresh()
        expect(!model.policy.consented && model.policy.scopeWidened && values().phase == .intro && values().scopeWidened && !values().showsSwitch && !model.setUp
               && model.indicator == .locked(.notAccepted) && !model.indicator.showsDot, "consent for fewer places: typing locked, the switch drawn off (fix/typing-e2e: no notice)")
        expect(model.turnOn() && model.policy.consented && !model.policy.scopeWidened && model.policy.acceptedScope == .current && model.setUp
               && model.indicator == .recording(app: "Notes"), "Turn on typing accepts this build's scope and typing resumes")
        // typingfix review: the same while the Keychain is locked. Settings keeps the locked card (Try again), the menu asks
        // for the unlock, and Turn on typing writes nothing, so the settings keep their signature and the owner's choices.
        var owned = try store.typedTextPolicy(); owned.retention = .forever; owned.categories.messagesAndEmail = true; owned.shareWithSummaries = .localOnly
        _ = try store.updateTypedTextPolicy(owned, now: now)
        // fix/typing-e2e: the Messages and email checkbox also remembers its choice (it was turned off above), and
        // Turn on typing keeps an explicit choice.
        try store.rememberMessagesChoice(true, now: now)
        let narrow = TypedConsentScope(apps: ["com.apple.Notes"], websites: false)
        try store.acceptSafeTyping(now: now, scope: narrow)
        let signed = try store.typedTextPolicy()
        keys.locked = true; _ = try store.reconcileTypedVault(now: now); model.refresh()
        // ux/declutter: the locked text is said once, beside Try again (the locked card), so the header adds no line.
        expect(model.policy.scopeWidened && model.vault == .locked && values().phase == .locked && values().detail == nil
               && model.indicator == .locked(.keychainLocked), "consent for fewer places, Keychain locked: the locked card with Try again, never Turn on typing")
        expect(!model.turnOn() && model.setupFailed && store.typedVaultState == .locked, "Turn on typing while the Keychain stays locked is refused")
        keys.locked = false; model.retryUnlock()
        expect(try model.vault == .ready && store.typedTextPolicyVerified() && store.typedTextPolicy() == signed && model.policy.retention == .forever
               && model.policy.categories.messagesAndEmail && model.policy.shareWithSummaries == .localOnly,
               "after the unlock the settings still carry their signature: retention, categories and sharing unchanged")
        expect(values().phase == .intro && values().scopeWidened && !values().showsSwitch && model.indicator == .locked(.notAccepted), "after the unlock: the switch drawn off, one click turns typing on")
        expect(model.turnOn() && model.policy.consented && model.policy.retention == .forever && model.policy.categories.messagesAndEmail
               && model.policy.shareWithSummaries == .localOnly, "Turn on typing after the unlock keeps the owner's settings")
        // A Keychain unlocked since the last read: Turn on typing reads it again first, then accepts.
        try store.acceptSafeTyping(now: now, scope: narrow)
        keys.locked = true; _ = try store.reconcileTypedVault(now: now); model.refresh(); keys.locked = false
        expect(try values().phase == .locked && model.turnOn() && model.vault == .ready && model.policy.consented && model.policy.retention == .forever
               && store.typedTextPolicyVerified(), "Turn on typing reads a Keychain unlocked meanwhile, then accepts with the settings kept")
        // fix/sx-all round 2: every category checkbox turned off stays off when typing is turned on again, from the Settings
        // switch or setup and what's-new Continue (both `TypingModel.turnOn` -> `MemoryStore.turnOnTyping`).
        model.setCategory(.code, on: false); model.setOtherWebsites(false)
        model.turnOff()
        expect(model.turnOn() && !model.policy.categories.code && !model.policy.categories.otherWebsites && model.policy.categories.writing
               && model.policy.categories.messagesAndEmail, "Settings switch on again: Code and Other websites, turned off, stay off")
        let seeded = try store.turnOnTyping(now: now)
        expect(!seeded.categories.code && !seeded.categories.otherWebsites && seeded.categories.searchAndAI, "what's-new Continue keeps each category turned off")
        model.setCategory(.code, on: true); model.setOtherWebsites(true)
        expect(try store.turnOnTyping(now: now).categories.code && store.setupChoices().categories?["otherWebsites"] == .on, "a category turned on again is remembered on")
        pass("E TypingModel: setup and Keychain error, shortcut pause, kept period, summaries, categories, locked, Forget")
    }

    // MARK: F. Hosted views

    static func views() {
        func size<V: View>(_ view: V, width: CGFloat = 560) -> NSSize {
            let host = NSHostingView(rootView: view.frame(width: width).environment(\.daydreamStatic, true))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        var consented = TypedTextPolicy(); consented.consentVersion = TypedTextPolicy.currentConsentVersion; consented.acceptedScope = .current
        expect(consented.consented, "the fixture: consent recorded for this build's scope")
        let shortcut = TypingSettingsValues.Shortcut(choices: ["⌃⌥⌘T", "⌃⌥⌘Y", "⌃⌥⌘P"], selected: 0, message: TypingSettingsText.shortcutTaken)
        let intro = size(TypingSettingsCard(values: .init(switchOn: false, policy: TypedTextPolicy(), vault: .notSetUp), actions: .init()))
        let failed = size(TypingSettingsCard(values: .init(switchOn: false, policy: TypedTextPolicy(), vault: .notSetUp, setupFailed: true), actions: .init()))
        let lost = size(TypingSettingsCard(values: .init(switchOn: true, policy: TypedTextPolicy(), vault: .keyLost, keyLost: true), actions: .init()))
        let locked = size(TypingSettingsCard(values: .init(switchOn: true, policy: consented, vault: .locked), actions: .init()))
        let off = size(TypingSettingsCard(values: .init(switchOn: false, policy: consented, vault: .ready), actions: .init()))
        let on = size(TypingSettingsCard(values: .init(switchOn: true, policy: consented, vault: .ready, shortcut: shortcut), actions: .init()))
        expect(failed.height > intro.height && lost.height > intro.height, "the Keychain error and the key-lost line add a line (\(intro.height) \(failed.height) \(lost.height))")
        // Before typing is set up the card is its header: the title and the switch (fix/apps-declutter, owner 9/29: no line,
        // no Learn more). No confirmation (owner 9/28): the switch turns typing on.
        let introValues = TypingSettingsValues(switchOn: false, policy: TypedTextPolicy(), vault: .notSetUp)
        expect(introValues.detail == nil && intro.height < 70 && locked.height > 40 && off.height < on.height && on.height > 40,
               "each phase draws its own content; the intro is the header with its one line (\(intro.height) \(locked.height) \(off.height) \(on.height))")
        let typingSource = source("Sources/MemoryUI/TypingSettings.swift")
        expect(!typingSource.contains("confirmingTurnOn") && !typingSource.contains("confirmTitle") && !typingSource.contains("TypingIntroCard")
               && typingSource.contains("set: { if $0 { actions.turnOn() } }"),
               "Settings turns typing on from the switch, with no question")
        expect(typingSource.contains(".confirmationDialog(TypingSettingsText.forgetConfirmation, isPresented: $confirmingForget")
               && typingSource.contains(".alert(pendingRetention?.shorteningConfirmation"),
               "destructive changes still ask: Forget, and a shorter Keep that deletes words now")
        // owner/v1 review F2, then fix/typing-e2e: consent for fewer places shows the switch off, with no notice (one click
        // turns typing on for this build's places).
        var narrow = consented; narrow.acceptedScope = TypedConsentScope(apps: ["com.apple.Notes"], websites: false)
        let widenedValues = TypingSettingsValues(switchOn: true, policy: narrow, vault: .ready)
        let widened = size(TypingSettingsCard(values: widenedValues, actions: .init()))
        expect(widenedValues.phase == .intro && widenedValues.scopeWidened && abs(widened.height - intro.height) < 1,
               "consent for fewer places: the same card as before typing was turned on, no notice (\(intro.height) \(widened.height))")
        let apps = size(SettingsAppsContent(apps: [], excluded: [], query: .constant(""), typedText: .constant(false), loaded: true, enabled: true,
                                            chromePages: AnyView(Text("Chrome")), typing: AnyView(Text("Typing card")), toggle: { _ in }), width: 600)
        expect(apps.width == 600, "Apps to remember hosts the Typing card next to Web pages in Chrome")
        let switchedOn = size(DaydreamAppsContent(apps: [], excluded: [], query: .constant(""), typedText: .constant(true), loaded: true, enabled: true, toggle: { _ in }), width: 600)
        let switchedOff = size(DaydreamAppsContent(apps: [], excluded: [], query: .constant(""), typedText: .constant(false), loaded: true, enabled: true, toggle: { _ in }), width: 600)
        expect(abs(switchedOn.height - switchedOff.height) < 2, "setup's Apps page doesn't grow when the switch goes on: its one line is the choice")
        // fix/typing-e2e: before consent the saved switch is never drawn (it would say on while nothing records); the card
        // draws the switch off, whose one click turns typing on. A lost key can still delete the kept summaries.
        let afterForget = TypingSettingsValues(switchOn: true, policy: TypedTextPolicy(), vault: .ready)
        expect(afterForget.phase == .intro && !afterForget.showsSwitch && !TypingSettingsValues(switchOn: false, policy: TypedTextPolicy(), vault: .notSetUp).showsSwitch
               && !TypingSettingsValues(switchOn: true, policy: consented, vault: .locked).showsSwitch, "before consent the saved switch is never drawn on")
        window.contentView = nil
        pass("F hosted Typing card in every phase, the setup screen, Apps to remember and setup")
    }

    // MARK: F2. Consent is a click, and the consent card can be seen (public-typing review)

    /// Hosts `view` in its own ordered-front offscreen window of `size`, lets it settle (and any scroll
    /// animation finish), then sends one Return key equivalent. Returns what ran, and the host.
    static func hosted<V: View>(_ view: V, size: NSSize, fired: @escaping () -> [String]) -> (fired: [String], host: NSView, window: NSWindow) {
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view.environment(\.daydreamStatic, true))
        w.contentView = host
        w.orderFrontRegardless()
        for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
        let before = fired()
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: w.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                     isARepeat: false, keyCode: 36)!
        _ = w.performKeyEquivalent(with: event)
        for _ in 0..<3 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return (Array(fired().dropFirst(before.count)), host, w)
    }

    static func consentKeys() {
        var fired: [String] = []
        let apps = ["Notes", "Mail", "Safari", "Google Chrome", "Xcode", "Terminal", "Slack", "Calendar", "Messages", "Music"].enumerated().map {
            LocalApp(id: "com.example.app\($0.offset)", name: $0.element) }
        let chrome = ChromePagesCard(on: .constant(false), savedOn: false, access: .unknown, sites: [], enabled: true,
                                     add: { _ in }, remove: { _ in }, allow: {}, openSystemSettings: {}, checkAccess: {})
        func settings(_ values: TypingSettingsValues) -> some View {
            DaydreamSettingsFrame(title: "Apps to remember", back: {}, close: { fired.append("Done") }) {
                SettingsAppsContent(apps: apps, excluded: [], query: .constant(""), typedText: .constant(values.switchOn), loaded: true, enabled: true,
                                    chromePages: AnyView(chrome),
                                    typing: AnyView(TypingSettingsCard(values: values, actions: .init(turnOn: { fired.append("Turn on typing") }))),
                                    toggle: { _ in })
            }.frame(width: 760, height: 600)
        }
        // Settings (the real 760x600 sheet), before typing is set up and again after Forget: Return is Done, never consent.
        let control = hosted(DaydreamSettingsFrame(title: "Apps to remember", back: {}, close: { fired.append("Done") }) { Text("page") }.frame(width: 760, height: 600),
                             size: NSSize(width: 760, height: 600)) { fired }
        expect(control.fired == ["Done"], "control: Return presses Done in the Settings frame (\(control.fired))")
        control.window.orderOut(nil)
        for (name, values) in [("before typing is set up", TypingSettingsValues(switchOn: false, policy: TypedTextPolicy(), vault: .notSetUp)),
                               ("after Forget", TypingSettingsValues(switchOn: true, policy: TypedTextPolicy(), vault: .ready)),
                               ("after a Keychain error", TypingSettingsValues(switchOn: false, policy: TypedTextPolicy(), vault: .notSetUp, setupFailed: true))] {
            let run = hosted(settings(values), size: NSSize(width: 760, height: 600)) { fired }
            expect(run.fired == ["Done"], "Settings \(name): Return closes Settings and never turns typing on (\(run.fired))")
            run.window.orderOut(nil)
        }
        // Offscreen SwiftUI exposes no accessibility tree here (see dd-status-surfaces-safety-checks), so the switch is
        // checked in pixels. fix/typing-e2e: before typing is set up (after Forget, with a lost key) the switch is drawn
        // off, as typing is, whatever was saved: a card drawn with the saved switch on is the same as one drawn with it
        // off (never a switch that says on while nothing records), and one click on it turns typing on.
        func pixels(_ values: TypingSettingsValues) -> Data {
            let run = hosted(TypingSettingsCard(values: values, actions: .init()).frame(width: 560, height: 420, alignment: .top),
                             size: NSSize(width: 560, height: 420)) { fired }
            defer { run.window.orderOut(nil) }
            guard let rep = run.host.bitmapImageRepForCachingDisplay(in: run.host.bounds) else { return Data() }
            run.host.cacheDisplay(in: run.host.bounds, to: rep)
            return rep.tiffRepresentation ?? Data()
        }
        for (name, lost) in [("after Forget", false), ("with a lost key", true)] {
            let vault: TypedVaultState = lost ? .keyLost : .ready
            let on = pixels(TypingSettingsValues(switchOn: true, policy: TypedTextPolicy(), vault: vault, keyLost: lost))
            let off = pixels(TypingSettingsValues(switchOn: false, policy: TypedTextPolicy(), vault: vault, keyLost: lost))
            expect(!on.isEmpty && on == off, "Settings \(name): the typing switch is drawn off, as typing is, whatever was saved")
            expect(!TypingSettingsValues(switchOn: true, policy: TypedTextPolicy(), vault: vault, keyLost: lost).showsSwitch,
                   "Settings \(name): the saved switch is not drawn; the off switch there turns typing on in one click")
        }
        // Setup (660x600): no Turn on typing sheet any more (owner 9/28); the Apps page's switch and its one line are the
        // choice, and Return there is the page's own Continue (the host's), never a typing button.
        let page = hosted(DaydreamAppsContent(apps: apps, excluded: [], query: .constant(""), typedText: .constant(true), loaded: true, enabled: true,
                                              toggle: { _ in }).frame(width: 588), size: NSSize(width: 660, height: 600)) { fired }
        expect(page.fired.isEmpty, "setup: Return on the Apps page runs nothing of the page's own (\(page.fired))")
        page.window.orderOut(nil)
        expect(!fired.contains { $0.hasPrefix("Turn on typing") }, "no Return anywhere turned typing on")
        pass("F2 Return never consents (Settings: Done; setup: nothing), and the switch after Forget is drawn off, as typing is")
    }

    // MARK: G. App wiring (Development Trial model, private store)

    static func appWiring(shared: [String]) async throws {
        let root = URL(fileURLWithPath: "/private/tmp/daydream-development-trial-" + UUID().uuidString)
        guard !shared.contains(where: { root.path.hasPrefix($0) }) else { fail("development root is not redirected to the private checks tree") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for name in ["memory", "preferences", "backups"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        try Data("synthetic-only\n".utf8).write(to: root.appendingPathComponent("DEVELOPMENT-ONLY"))
        setenv("DAYDREAM_DEVELOPMENT_ROOT", root.path, 1)
        setenv("MAC_MEM_HOME", root.appendingPathComponent("memory").path, 1)
        setenv("CFFIXED_USER_HOME", root.appendingPathComponent("preferences").path, 1)
        let trial = try DevelopmentTrial.validate()
        try trial.prepare()
        let model = MemoryViewModel(development: trial)
        for _ in 0..<100 { if !model.history.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        expect(!model.typing.attached && model.typing.hotkey == .notInstalled, "a Development Trial attaches no typing store and registers no shortcut")
        let bare = DaydreamMenuBarLabel(model: model).body as? DaydreamMenuBarLabelImage
        expect(bare?.badge == DaydreamTypingBadge.none, "no typing: the label has no badge")

        // A private typing store attached by hand: the label and the rows follow the model.
        let home = root.appendingPathComponent("typing", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        let keys = InMemoryTypedKeyStore()
        try store.attachVault(TypedTextVault(keyStore: keys), now: Date())
        model.typing.frontmostBundle = { "com.apple.Notes" }
        model.typing.presentToast = { _ in }
        let fake = FakeRegistrar()
        model.typing.attach(store, hotkeys: fake)
        expect(model.typing.turnOn(), "turn on (in-memory key)")
        _ = try store.savePreferences(MemoryPreferences(blockedApps: [], nativeTyping: true), expectedRevision: try store.policy().revision)
        try store.setCaptureState("recording", reason: "synthetic fixture")
        model.typing.refresh()
        expect(model.typing.indicator == .recording(app: "Notes"), "fixture: recording in Notes")
        let label = DaydreamMenuBarLabel(model: model).body as? DaydreamMenuBarLabelImage
        expect(label?.badge == .dot && label?.label.hasSuffix("DayDream is recording what you type") == true, "the live label draws the dot")
        let rows = DaydreamMenuBarPanel.typingRows(model.typing, timeZone: utc)
        expect(rows.line == "Recording what you type in Notes" && rows.menuItem?.title == "Pause Typing for 10 Minutes", "the live menu rows")
        let settings = DaydreamTypingSettings.values(model: model, typing: model.typing, keyPlace: .loginKeychain)
        expect(settings.phase == .off && !settings.enabled && settings.keyPlace == .loginKeychain && settings.shortcut?.message == nil,
               "Settings values from the model (development: read only; the key place only while ready)")
        keys.locked = true; _ = try store.reconcileTypedVault(); model.typing.refresh()
        expect(DaydreamTypingSettings.values(model: model, typing: model.typing, keyPlace: .loginKeychain).keyPlace == nil, "no key place line while the key can't be read")
        keys.locked = false; _ = try store.reconcileTypedVault(); model.typing.refresh()
        var routes: [String] = []
        let actions = DaydreamMenuBarPanel.typingActions(model: model, routes: DaydreamMenuBarRoutes(openWindow: { routes.append("window:" + $0) }, activate: { routes.append("activate") },
                                                                                                    openURL: { _ in }, terminate: { routes.append("terminate") }))
        actions.pause()
        expect(model.typing.snoozed && model.typing.indicator.showsRing, "the menu row pauses typing (the ring)")
        let ring = DaydreamMenuBarLabel(model: model).body as? DaydreamMenuBarLabelImage
        expect(ring?.badge == .ring, "the live label draws the ring while paused")
        actions.resume()
        expect(!model.typing.snoozed && model.typing.indicator.showsDot, "Record typing again")
        actions.openSettings()
        expect(routes == ["window:memory", "activate"] && model.settingsPresented && DaydreamSettingsPage(section: model.settingsSection) == .apps, "the locked row opens Settings ▸ Apps to remember (\(routes))")
        model.settingsPresented = false
        try store.setCaptureState("off", reason: "synthetic fixture")
        model.typing.refresh()
        expect(!model.recording && model.stopped, "nothing started")
        pass("G app wiring: label, menu rows and Settings values follow TypingModel")
    }

    // MARK: H. Sources

    static func sources() {
        let hotkey = source("Sources/MacMemApp/TypingHotkey.swift"), model = source("Sources/MacMemApp/TypingModel.swift")
        let settings = source("Sources/MemoryUI/TypingSettings.swift"), glyph = source("Sources/MemoryUI/DaydreamMenuBarGlyph.swift")
        let menu = source("Sources/MacMemApp/MenuBarContent.swift"), host = source("Sources/MacMemApp/DaydreamSettings.swift")
        let onboarding = source("Sources/MacMemApp/DaydreamOnboarding.swift"), screens = source("Sources/MemoryUI/OnboardingScreens.swift")
        let card = source("Sources/MemoryUI/MenuBarMenu.swift"), apps = source("Sources/MemoryUI/AppExclusions.swift")
        expect(hotkey.contains("RegisterEventHotKey(keyCode, modifiers") && hotkey.contains("OptionBits(kEventHotKeyExclusive)")
               && hotkey.contains("eventHotKeyExistsErr") && hotkey.contains("UnregisterEventHotKey("), "Carbon RegisterEventHotKey, exclusive, with the conflict answer")
        for (name, text) in [("TypingHotkey", hotkey), ("TypingModel", model), ("TypingSettings", settings)] {
            for banned in ["tapCreate", "CGEventTap", "AXIsProcessTrustedWithOptions", "CGRequestListenEventAccess", "IOHIDRequestAccess", "SecItem", "KeychainTypedKeyStore" + "("] {
                expect(!text.contains(banned), "\(name) never uses \(banned)")
            }
        }
        expect(model.contains("hotkeys: TypingHotkeyRegistrar? = TypingHotkey.appRegistrar()") && hotkey.contains("pathExtension == \"app\" ? CarbonTypingHotkeyRegistrar() : nil"),
               "the app bundle registers through Carbon; bare check executables register nothing")
        expect(source("Sources/MacMemApp/MacMemApp.swift").contains("typing.attach(store)"), "the app attaches the typing model (and so the shortcut) outside development trials")
        let owner = settings.components(separatedBy: "#if DAYDREAM_OWNER_TYPING")
        expect(owner.count == 2 && owner[1].components(separatedBy: "#else")[0].contains("Websites not listed above, except blocked sites. Never in Incognito or Guest windows.")
               && settings.components(separatedBy: "Websites not listed above").count == 2, "the Other websites strings exist only in owner builds")
        expect(menu.contains("typing: typing.indicator") && menu.contains("typing: Self.typingRows(typing"), "the label and the panel read TypingModel")
        // Owner decision 2026-10-03: the card's settings open from its title row, remembered while DayDream runs.
        expect(host.contains("typing: AnyView(DaydreamTypingSettings(model: model, expanded: expansion.binding(.typing)))"), "Settings ▸ Apps to remember hosts the Typing card")
        // public-typing review: Forget also turns the saved switch off; no consent button answers Return; the
        // Chrome and Typing cards fade at the bottom like the app list (since sat3 they sit on the Apps page,
        // which scrolls as a whole inside DaydreamSettingsScroll and its fade).
        // fix/typing-e2e: through the one OFF path (TypingModel.turnOff: remembered as an explicit Off, then saved off).
        expect(host.contains("forget: { if typing.forget() && model.captureText { typing.turnOff() } }"), "Settings: Forget also turns typing off")
        // summaries/v3 (owner 9/28): no Turn on typing card or question; no typing button answers Return (Return belongs
        // to Done or Continue).
        expect(!settings.contains("public struct TypingIntroCard") && !settings.contains(".keyboardShortcut("),
               "no typing consent card or question, and no typing button answers Return")
        // writer/v2 + summaries/v3: the summaries picker is gone from the card, the host and the model. What summaries
        // read is said once, as a consent bullet (spec §13), not as a line on the card.
        expect(!settings.contains("Let summaries read what you type") && !settings.contains("setSharing")
               && !host.contains("setSharing") && !model.contains("setSharing") && !settings.contains("Picker(TypingSettingsText.summaries"),
               "Typing card: no summaries picker")
        let scroller = source("Sources/MemoryUI/SettingsHub.swift").components(separatedBy: "public struct DaydreamSettingsScroll").dropFirst().first ?? ""
        expect(host.contains("DaydreamSettingsScroll { DaydreamAppSettings(model: model) }") && !apps.contains(".accessibilityLabel(\"Web pages and typed text\")")
               && scroller.contains("LinearGradient(colors: [DaydreamOnboardingTheme.window.opacity(0), DaydreamOnboardingTheme.window]"),
               "the Chrome and Typing cards scroll with the Apps page, which fades at the bottom, so the page reads as going on")
        expect(!screens.contains("typingPendingHint") && !screens.contains("ScrollViewReader") && !screens.contains("DaydreamTypingSheet"),
               "setup: no consent card or sheet to scroll to or point at")
        // fix/apps-declutter (owner 9/29, "too cluttered"): Settings before typing is on is the title and the switch; the
        // card draws no category lines, footer, website line or Keep help.
        expect(settings.contains("case .intro: return nil") && !settings.contains("learnMoreShown")
               && !settings.contains("Text(TypingSettingsText.consentWhere())") && !settings.contains("Text(TypingSettingsText.keepHelp)")
               && !settings.contains("Text(TypingSettingsText.footer)")
               && !settings.contains("Text(TypingSettingsText.line(category"),
               "the Typing card: no line, Learn more, category lines, footer or Keep help")
        let introPhase = settings.components(separatedBy: "private var introProblems: some View {").dropFirst().first?.components(separatedBy: "private var offContent").first ?? ""
        expect(settings.contains("case .intro:\n                        introProblems") && introPhase.contains("if values.keyLost {")
               && introPhase.contains("Button(TypingSettingsText.forget) { confirmingForget = true }"),
               "a lost key: Forget what I typed is offered without turning typing on again")
        // typing-all final review: the locked Keychain phase has Try again, and the app reads the Keychain again after an unlock.
        // The card's phase switch (any indentation): from `case .locked:` + VStack up to `case .off:`.
        let lockedStart = settings.range(of: #"case \.locked:\n\s*VStack"#, options: .regularExpression)
        let lockedPhase = lockedStart.map { String(settings[$0.upperBound...]) }?.components(separatedBy: "case .off:").first ?? ""
        expect(lockedPhase.contains("TypingSettingsText.locked") && lockedPhase.contains("actions.retryUnlock()") && host.contains("retryUnlock: { typing.retryUnlock() }")
               && model.contains("com.apple.screenIsUnlocked") && model.contains("retryLockedTypedVault"), "locked Keychain: Try again, and an unlock reads the key again")
        let app = source("Sources/MacMemApp/MacMemApp.swift")
        expect(app.contains("typing.keyPanel = { NativeTypingRoute.keyPanelBundle() }") && app.contains("coordinator?.onKeyTarget = { [weak self] bundle in self?.typing.keyTargetSeen(bundle) }"),
               "the dot follows key focus into Spotlight")
        let capture = source("Sources/MacMemApp/EventCapture.swift")
        let mouse = capture.components(separatedBy: "private func handleNativeMouseDown(at eventAt:UInt64)").dropFirst().first?.components(separatedBy: "\n    }").first ?? ""
        let front = capture.components(separatedBy: "func switchFrontmost(pid: pid_t").dropFirst().first?.components(separatedBy: "resetObservation()").first ?? ""
        // Saturday test 5: the mouse-down also reports TypingPointer first, so website typing saves its unfinished words.
        expect(mouse.contains("TypingPointer.down(at:eventAt)") && mouse.contains("TypingFocus.mayHaveMoved()") && front.contains("TypingFocus.mayHaveMoved()")
               && model.contains("forName: .typingIndicatorInputsChanged"), "a click or an app switch drops the website dot's judgement, and the menu refreshes")
        // Opt-out setup (owner, 9/27-9/28): Continue with the switch on sets typing up, also after a widened scope or a
        // lost key; the page says why typing was off in one line (no sheet, no second question).
        let saveApps = onboarding.components(separatedBy: "private func saveApps() {").dropFirst().first?.components(separatedBy: "private func reloadChoices()").first ?? ""
        expect(!onboarding.contains("DaydreamTypingSheet(") && !onboarding.contains(".sheet(") && !onboarding.contains("typingNeedsAcceptance")
               && saveApps.contains("let ready = typing.turnOn() && typing.setUp")
               && saveApps.contains("typedText = DaydreamOnboardingTyping.switchAfterTurnOn(ready: ready, switchOn: typedText)")
               && saveApps.contains("guard ready else { error = TypingSettingsText.keyError; return }"),
               "setup: no sheet; the switch on turns typing on at Continue (also after a widened scope or a lost key); a key it can't make turns the switch off")
        // Reading the saved choices again seeds the switches as setup opens (on in a first setup); the page's edits are
        // measured from those seeds, so an untouched first setup is never 'changed elsewhere' and never turned off.
        let reload = onboarding.components(separatedBy: "private func reloadChoices() {").dropFirst().first?.components(separatedBy: "\n    }\n").first ?? ""
        let reset = onboarding.components(separatedBy: "private func resetForReview() {").dropFirst().first?.components(separatedBy: "\n    }\n").first ?? ""
        expect(reload.contains("seedSwitches()") && !reload.contains("typedText = baselineTypedText") && !reload.contains("chromePages = baselineChromePages")
               && reset.contains("seedSwitches()")
               // fix/messaging-default adds the Messages and email switch to the page's edits (measured from its seed too).
               && (onboarding.contains("private var pageEdited: Bool { exclusions != baselineExclusions || typedText != seedTypedText || chromePages != seedChromePages }")
                   || onboarding.contains("exclusions != baselineExclusions || typedText != seedTypedText || chromePages != seedChromePages || messages != seedMessages"))
               && onboarding.contains("DaydreamOnboardingTyping.initialSwitch(savedConsent: model.captureText, explicitlyOff: choices.typing == .off)"),
               "reloading setup's choices keeps a first setup's switches on, and an untouched first setup has no edits")
        // ux/v1: each setup Review row shows one value; the typed-text row says only On or Off, so it names no places
        // and can't name fewer than the build records (typingfix review).
        expect(onboarding.contains("DaydreamReviewRow(id: \"typing\", title: \"Typed text\", value: typedText ? \"On\" : \"Off\"") && !onboarding.contains("\"Included in "),
               "the setup Review step's typed-text row is On or Off, with no scope line to fall behind the build (typingfix review)")
        // owner/v1 review F2 and F4: both switches read the build's scope strings, and the Typing screen draws where
        // typing works and the re-acceptance notice in setup (the sheet); Settings shows the notice with its one
        // button, the Turn on typing question, whose message is the Typing screen.
        expect(apps.contains("DaydreamAppsContent.typedTextTitle, detail: DaydreamAppsContent.typedTextScope") && !apps.contains("\"Typed text in apps\"")
               && screens.contains("switchRow(Self.typingSwitchTitle, isOn: $typedText, label: Self.typedTextLabel") && !screens.contains("Text(\"Typed text in apps\")"),
               "the typed-text switches name the build's scope")
        let problems = settings.components(separatedBy: "private var introProblems: some View {").dropFirst().first?.components(separatedBy: "private var offContent").first ?? ""
        expect(!problems.contains("if values.scopeWidened {") && !settings.contains("Text(TypingSettingsText.scopeWidened)")
               && !settings.contains("Button(TypingSettingsText.turnOn)") && settings.contains("set: { if $0 { actions.turnOn() } }"),
               "a widened scope: Settings shows no notice, only the switch off whose click turns typing on (fix/typing-e2e); setup's Continue turns it on (fix/setup-status)")
        let text = screens.components(separatedBy: "#if DAYDREAM_OWNER_TYPING")
        expect(text.count == 2 && text[1].components(separatedBy: "#else")[0].contains("websites in Google Chrome")
               && screens.components(separatedBy: "websites in Google Chrome").count == 3, "the website switch strings exist only in owner builds")
        expect(card.contains("if let typing, typing.shown { typingLine(typing) }") && card.contains("Self.pauseItems(typing: typing)"),
               "the panel draws the typing line under the status and the typing item in Pause ›")
        expect(glyph.contains("typing.showsDot ? .dot : typing.showsRing ? .ring : .none"), "the badge is exactly showsDot / showsRing")
        for (name, text) in [("TypingSettings", settings), ("MenuBarContent", menu), ("DaydreamSettings", host), ("OnboardingScreens", screens), ("AppExclusions", apps), ("TypingModel", model)] {
            expect(!text.lowercased().contains("coming soon"), "\(name): no \"coming soon\"")
        }
        for dir in ["Sources/MemoryUI", "Sources/MacMemApp"] {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.currentDirectoryPath + "/" + dir)) ?? []
            expect(files.count > 20, "\(dir) listed")
            for file in files where file.hasSuffix(".swift") {
                // Code only: comments may name the removed choice.
                let text = source(dir + "/" + file).split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
                expect(!text.contains("\"This Mac and cloud\""), "\(file): no This Mac and cloud choice (decision 8)")
                expect(!text.contains("see the exact words you typed"), "\(file): no exact-words row for AI apps (decision 4)")
            }
        }
        expect(!source("Sources/MemoryUI/SettingsHub.swift").contains("Memory is kept on this Mac") && !source("Sources/MemoryUI/PermissionSetup.swift").contains("\"Kept on this Mac\""),
               "the old privacy promise is gone")
        // ux/perms (owner request): the permissions page is only its two cards. ux/declutter: the overview's footer is
        // one shorter line (`storageFooter` or, only when FileVault is known to be off, `storageFooterFileVaultOff`; both
        // checked in A3) with Learn more to PRIVACY.md. Advanced › Privacy and retention is gone (ux/declutter), so the
        // cloud limit is said where cloud summaries are turned on (CloudActivation.disclosure, honesty-ui-checks).
        expect(source("Sources/MemoryUI/SettingsHub.swift").contains("let line = Self.footer(fileVaultOn: fileVaultOn)")
               && source("Sources/MemoryUI/SettingsHub.swift").contains("(Text(line + \" \")")
               && !source("Sources/MemoryUI/PermissionSetup.swift").contains("PrivacyPromise"),
               "the Settings overview shows its short promise with Learn more; the permissions page shows only its cards")
        expect(source("LICENSE").hasPrefix("MIT License\n") && source("LICENSE").contains("Copyright (c) 2026 The DayDream Authors")
               && !source("LICENSE").contains("Apache"), "the MIT LICENSE backs the open-source claim")
        pass("H sources: Carbon only, no permission or Keychain call, owner-only website strings, no cloud or exact-words choice")
    }
}
