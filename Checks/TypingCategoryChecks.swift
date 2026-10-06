import Foundation
import MemoryCore
import PrivacyPolicy

/// Safe typing E and F (categories slice), public API only: the shipped app
/// table, the legal release gate, the website table, category choices in the
/// store, the store-side refusal of typed rows, the typing pause, and the
/// menu-bar indicator. The capture binding's side (excluded apps, the pause
/// dropping the unfinished draft) runs in scripts/core-adapter-checks.swift.
func runTypingCategoryChecks(home: URL) throws {
    let all: (TypingCategory) -> Bool = { _ in true }
    let defaults = TypedCategoryChoices()
    let buildFour: Set<String> = ["com.apple.Notes", "com.apple.TextEdit"]
    // The full-typing build (both flags) is what every release stage makes since the owner's decision of
    // 2026-09-25; an unflagged local build still reads the closed gate. Checks about the lawyer's gate pass
    // `expanded:`/`probeBuild:` explicitly, so they hold in both; checks of the defaults follow the build.
    let shipped = OwnerTyping.enabled
    // fix/typing-e2e L1: Messages and email is on by default too, so the defaults allow the whole full-typing set.
    let fullDefaults = typingOwnerSet

    // MARK: Legal gate
    try check(TypingRelease.expandedApproved == false, "release gate: expanded typing is not approved (lawyer session first)")
    try check(TypingRelease.buildFourApps == buildFour, "release gate: build 4's set is Notes and TextEdit")
    try check(TypingCategories.allowedBundles(on: defaults.isOn, expanded: false) == buildFour, "release gate closed: with the default choices only Notes and TextEdit are allowed")
    try check(TypingCategories.allowedBundles(on: all, expanded: false) == buildFour, "release gate closed: every category on still allows only Notes and TextEdit")
    try check(TypingCategories.allowedBundles(on: { $0 == .messagesAndEmail }, expanded: false).isEmpty, "release gate closed: messages on (everything else off) allows no app")
    try check(TypingCategories.allowedBundles(on: all, expanded: true, probeBuild: false) == buildFour, "gate open today: only rows that pass the native proof with a known signer (still Notes and TextEdit)")
    try check(TypingCategories.apps.filter { TypingCategories.releaseAllows($0, expanded: true, probeBuild: false) }.allSatisfy { $0.support == .native && $0.bundleConfirmed && TypingCategories.signingRequirement($0) != nil },
              "gate open: probed, web-content, unsupported and unconfirmed rows stay off")
    // What this build's defaults allow: the full-typing set, or Notes and TextEdit in a narrow build.
    try check(TypingCategories.allowedBundles(on: defaults.isOn) == (shipped ? fullDefaults : buildFour)
              && TypingCategories.allowedBundles(on: all) == (shipped ? typingOwnerSet : buildFour)
              && TypingCategories.allowedBundles(on: { $0 == .messagesAndEmail }) == (shipped ? ["com.apple.MobileSMS", "com.apple.mail", "net.whatsapp.WhatsApp"] : []),
              shipped ? "full-typing build: the defaults allow every app with a confirmed signer, Messages and Mail included (their own switch starts on)"
                      : "narrow build: the defaults allow only Notes and TextEdit")
    let probedApple = TypingApp("com.apple.example.Native", "Example", .writing, .apple, .native)
    try check(!TypingCategories.releaseAllows(probedApple, expanded: false) && TypingCategories.releaseAllows(probedApple, expanded: true)
              && TypingCategories.releaseAllows(probedApple) == shipped, "a probed native Apple row waits for the gate, then is allowed")
    try check(!TypingCategories.releaseAllows(TypingApp("com.example.native", "Example", .code, .unconfirmed, .native), expanded: true), "an unconfirmed signer is never allowed, even with the gate open")
    try check(!TypingCategories.releaseAllows(TypingApp("com.example.native", "Example", .code, .team("ABCDE12345"), .native, bundleConfirmed: false), expanded: true), "an unconfirmed bundle ID is never allowed")
    try check(!TypingCategories.releaseAllows(TypingApp("com.example.native", "Example", .code, .team("not-a-team"), .native), expanded: true), "a malformed team ID gives no signing requirement and no typing")
    try check(!TypingCategories.releaseAllows(TypingApp("com.apple.keychainaccess", "Keychain Access", .writing, .apple, .native), expanded: true), "an always-blocked app is never allowed, whatever its row says")
    // Review finding: terminals need the prompt latch wired into capture first.
    // typing-all W0 wired it into TypingSession (PrivacyPolicy's
    // TypingWiringChecks tie `wired` to the session dropping the keys, and
    // typing-release-gate-checks.py to the source).
    try check(TerminalPromptLatch.wired, "the terminal prompt latch is wired into capture's typing session")
    try check(TypingCategories.releaseAllows(TypingApp("com.apple.Terminal", "Terminal", .code, .apple, .native, promptLatch: true), expanded: true)
              && !TypingCategories.releaseAllows(TypingApp("com.apple.Terminal", "Terminal", .code, .apple, .native, promptLatch: true), expanded: false),
              "a native terminal row: allowed with the gate open now that the latch is wired, never with it closed")
    // typing-all W0: the owner switch. Every release stage compiles it in (the full-typing build); an
    // unflagged local build never has it. The lawyer's constant stays false in both.
    if shipped {
        try check(TypingRelease.open && TypingRelease.probeBuild && !TypingRelease.expandedApproved, "full-typing build: the owner switch opens the gate; the lawyer's constant stays false")
        try check(TypingCategories.releaseAllows(probedApple) && TypingCategories.permitsSite(host: "example.org", on: all, other: true) && TypingCategories.permitsSite(host: "claude.ai", on: all)
                  && !TypingCategories.permitsSite(host: "example.org", on: all) && !TypingCategories.permitsSite(host: "chase.com", on: all, other: true),
                  "full-typing build: the defaults read the open gate (apps, and websites by their switches; never pages stay off)")
    } else {
        try check(!OwnerTyping.enabled && !TypingRelease.open, "public build: no owner switch, so the gate stays closed")
        try check(!TypingCategories.releaseAllows(probedApple) && !TypingCategories.permitsSite(host: "example.org", on: all) && !TypingCategories.permitsSite(host: "claude.ai", on: all),
                  "public build: the defaults read the closed gate (no expanded app, no website)")
    }
    try check(TypedCategoryChoices().otherWebsites && (try JSONDecoder().decode(TypedCategoryChoices.self, from: Data("{}".utf8))).otherWebsites
              && !(try JSONDecoder().decode(TypedCategoryChoices.self, from: Data(#"{"otherWebsites":false}"#.utf8))).otherWebsites,
              "\"Other websites\" is on by default (owner decision 3) and a saved off stays off")
    for support in [TypingSupport.nativeNeedsProbe, .embeddedWeb, .browserJoin, .notSupportable] {
        try check(!TypingCategories.releaseAllows(TypingApp("com.apple.example.\(support.rawValue)", "Example", .writing, .apple, support), expanded: true, probeBuild: false), "gate open: a \(support.rawValue) row is not allowed")
    }

    // MARK: The shipped table
    let bundles = TypingCategories.apps.map(\.bundle)
    try check(Set(bundles).count == bundles.count && bundles.allSatisfy { !$0.isEmpty && !$0.contains(" ") }, "table: bundle IDs are unique and well formed")
    for category in TypingCategory.allCases {
        try check(TypingCategories.apps(in: category).count >= 4, "table: \(category.title) lists its apps")
    }
    try check(Set(TypingCategories.apps(in: .messagesAndEmail).map(\.bundle)) == ["com.apple.MobileSMS", "com.apple.mail", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "net.whatsapp.WhatsApp", "com.microsoft.Outlook"], "table: Messages and email are Messages, Mail, Slack, Discord, WhatsApp and Outlook")
    try check(TypingCategories.app("com.apple.Notes")?.category == .writing && TypingCategories.app("com.apple.TextEdit")?.support == .native, "table: Notes and TextEdit are native Writing apps")
    try check(TypingCategories.app("com.apple.Terminal")?.category == .code && TypingCategories.app("com.apple.Terminal")?.promptLatch == true, "table: Terminal is Code, with the password-prompt latch")
    try check(TypingCategories.apps.filter(\.promptLatch).allSatisfy { $0.category == .code }, "table: only Code apps carry the prompt latch")
    try check(TypingCategories.app("com.anthropic.claudefordesktop")?.signer == .team("Q6L2SF6YDW") && TypingCategories.app("com.openai.codex")?.signer == .team("2DC432GLL2") && TypingCategories.app("com.openai.chat")?.signer == .team("2DC432GLL2") && TypingCategories.app("com.openai.chat")?.support == .nativeNeedsProbe && TypingCategories.app("com.mitchellh.ghostty")?.signer == .team("24VZTF6M5V"), "table: the three team IDs read on this Mac")
    try check(["com.microsoft.Word", "com.tinyspeck.slackmacgap", "com.microsoft.VSCode", "com.googlecode.iterm2"].allSatisfy { TypingCategories.app($0)?.signer == .unconfirmed }, "table: teams not read yet stay unconfirmed")
    // chatgpt-capture: AXEnhancedUserInterface (it slows window moves in Chromium apps) is for ChatGPT alone, whose
    // framework has no AXManualAccessibility; every other web-content row keeps the side-effect-free switch.
    try check(TypingCategories.enhancedUserInterfaceApps == ["com.openai.codex"]
              && TypingCategories.app("com.openai.codex")?.web == .electronWithoutManualSwitch
              && TypingCategories.app("com.openai.codex")?.web?.admits(url: "app://-/index.html?initialRoute=%2F") == true
              && TypingCategories.app("com.openai.codex")?.web?.admits(url: "https://chatgpt.com/") == false
              && TypingCategories.app("com.anthropic.claudefordesktop")?.web?.enhancedUserInterface == false,
              "table: only ChatGPT may get AXEnhancedUserInterface; its own page still only (bundled files, never chatgpt.com)")
    try check(["dev.zed.Zed", "dev.warp.Warp-Stable"].allSatisfy { TypingCategories.app($0)?.support == .notSupportable }, "table: Zed and Warp are marked not supportable")
    try check(TypingCategories.app("com.example.Unknown") == nil && TypingCategories.app("") == nil, "table: apps outside the table are unknown")
    try check(TypingCategories.apps.allSatisfy { !CaptureGate.isBrowser($0.bundle) } && TypingCategories.alwaysBlocked.allSatisfy { !CaptureGate.isBrowser($0) },
              "table: no browser is in the table or the always-blocked list (browser metadata gates are unaffected)")
    try check(TypingCategories.signingRequirement(TypingCategories.app("com.apple.Notes")!) == "anchor apple and identifier \"com.apple.Notes\"", "signing: Apple apps need Apple's anchor and their identifier")
    try check(TypingCategories.signingRequirement(TypingCategories.app("com.anthropic.claudefordesktop")!) == "anchor apple generic and identifier \"com.anthropic.claudefordesktop\" and certificate leaf[subject.OU] = \"Q6L2SF6YDW\"", "signing: other apps need their identifier and their team")
    try check(TypingCategories.apps.filter { $0.signer == .unconfirmed }.allSatisfy { TypingCategories.signingRequirement($0) == nil }, "signing: no requirement (so no typing) without a known signer; a bundle ID alone is never trusted")

    // MARK: Always blocked
    let blocked = TypingCategories.alwaysBlocked
    try check(blocked.isSuperset(of: CaptureGate.passwordManagers) && blocked.isSuperset(of: PrivacySettings.sensitiveApps), "always blocked: password managers and the sensitive apps list")
    try check(blocked.isSuperset(of: ["com.apple.Passwords", "com.apple.keychainaccess", "com.apple.systempreferences"]), "always blocked: Passwords, Keychain Access and System Settings")
    try check(TypingCategories.apps.allSatisfy { !blocked.contains($0.bundle) }, "always blocked apps are not in the table")
    try check(blocked.allSatisfy { !TypingCategories.permits(bundle: $0, on: all, expanded: true) }, "always blocked: never permitted, whatever the choices or gate")

    // MARK: Categories and defaults
    try check(TypingCategory.allCases.allSatisfy { defaults.isOn($0) == $0.defaultOn }, "defaults: the store's choices match the table's defaults")
    try check(defaults.enabled == [.searchAndAI, .writing, .code, .messagesAndEmail], "defaults once typing is on: every category on, Messages & email included (fix/typing-e2e L1)")
    try check(TypedTextPolicy().categories == defaults && !TypedTextPolicy().consented, "defaults: a fresh policy has default categories and typing locked (master off)")
    try check(TypingCategory.searchAndAI.title == "Search boxes and AI prompts" && TypingCategory.writing.title == "Writing apps" && TypingCategory.code.title == "Code" && TypingCategory.messagesAndEmail.title == "Messages and email", "strings: category titles")
    // ux/declutter: the checkbox shows Messages is off; the ssh line moved to Limits (`remoteLimit`). public-typing/v1:
    // that line says the ssh rule lasts only until the focus changes.
    try check(TypingCategory.messagesAndEmail.help == "Your own messages only, never the conversation." && TypingCategory.code.help.contains("Skips passwords after sudo, ssh")
              && TypingCategories.remoteLimit == "After you run ssh, DayDream stops recording in that terminal until you switch to another tab, window or app. If you come back to the remote session, what you type there can be recorded."
              && !TypingCategory.code.help.contains("Remote sessions over ssh aren't recorded") && !TypingCategories.remoteLimit.contains("Remote sessions over ssh aren't recorded"),
              "strings: category help (the ssh limit lasts until the focus changes, and says so)")
    // The ssh rule the limit describes: a remote session stops recording in that focus only.
    var latch = TerminalPromptLatch()
    _ = latch.key(.text, focusID: "ghostty-1")
    _ = latch.key(.submit(line: "ssh server"), focusID: "ghostty-1")
    try check(latch.remote && latch.key(.text, focusID: "ghostty-1") == .drop, "ssh: nothing more is recorded in that terminal while the focus stays")
    latch.titleObserved("sam@server: ~", focusID: "ghostty-2")
    try check(!latch.remote && latch.key(.text, focusID: "ghostty-2") == .record,
              "ssh: after the focus changes, a remote shell whose title doesn't name ssh is recorded again (the limit says so)")
    try check(TypingCategories.footer == "Apps not listed here are never recorded.", "strings: footer")
    let excludedDefault = TypingCategories.excludedBundles(on: defaults.isOn)
    try check(excludedDefault == Set(bundles).subtracting(shipped ? fullDefaults : buildFour).union(blocked),
              shipped ? "excluded (defaults): every table app the default choices don't allow, plus the always-blocked apps"
                      : "excluded (defaults): every table app but Notes and TextEdit, plus the always-blocked apps")
    var writingOff = defaults; writingOff.set(.writing, false)
    try check(TypingCategories.excludedBundles(on: writingOff.isOn).isSuperset(of: buildFour), "excluded: Writing off adds Notes and TextEdit")
    try check(TypingCategories.excludedBundles(on: all, expanded: true, probeBuild: false).isSuperset(of: TypingCategories.apps(in: .messagesAndEmail).map(\.bundle)), "excluded: messages apps stay excluded while they can't be supported")
    for bundle in bundles + ["com.example.Unknown", "com.apple.Safari"] {
        for choice in [defaults, writingOff, TypedCategoryChoices(searchAndAI: true, writing: true, code: true, messagesAndEmail: true)] {
            let permitted = TypingCategories.permits(bundle: bundle, on: choice.isOn)
            guard !permitted || !TypingCategories.excludedBundles(on: choice.isOn).contains(bundle) else { throw MemError.invalid("FAILED: permitted and excluded: \(bundle)") }
        }
    }
    try check(true, "permits and excluded never disagree for any table app and choice")

    // MARK: Websites (later website typing)
    let sites: [(String, String, TypingSiteRule)] = [
        ("google.com", "/search", .category(.searchAndAI)), ("WWW.Google.com.", "/search", .category(.searchAndAI)),
        ("google.com", "/maps", .other), ("mail.google.com", "/mail/u/0/", .category(.messagesAndEmail)),
        ("gemini.google.com", "/app", .category(.searchAndAI)), ("docs.google.com", "/document/d/1/edit", .never),
        ("accounts.google.com", "/", .never), ("bing.com", "/search", .category(.searchAndAI)), ("bing.com", "/maps", .other),
        ("duckduckgo.com", "/", .category(.searchAndAI)), ("claude.ai", "/new", .category(.searchAndAI)),
        ("chatgpt.com", "/", .category(.searchAndAI)), ("perplexity.ai", "/", .category(.searchAndAI)),
        ("app.slack.com", "/client", .category(.messagesAndEmail)), ("slack.com", "/", .other),
        ("discord.com", "/channels/1", .category(.messagesAndEmail)), ("web.whatsapp.com", "/", .category(.messagesAndEmail)),
        ("outlook.live.com", "/mail", .category(.messagesAndEmail)), ("notion.so", "/workspace", .category(.writing)),
        ("notion.so", "/login", .never), ("evilclaude.ai", "/", .other), ("claude.ai.evil.example", "/", .other),
        ("chase.com", "/", .never), ("secure.chase.com", "/", .never), ("example.com", "/checkout", .never),
        ("example.com", "/", .other), ("", "/", .never),
    ]
    for (host, path, rule) in sites {
        try check(TypingCategories.site(host: host, path: path) == rule, "sites: \(host.isEmpty ? "(empty)" : host)\(path) is \(rule)")
    }
    try check(sites.allSatisfy { !TypingCategories.permitsSite(host: $0.0, path: $0.1, on: all, expanded: false) }, "sites: no website is permitted while the gate is closed")
    try check(TypingCategories.permitsSite(host: "claude.ai", path: "/new", on: defaults.isOn, expanded: true) && TypingCategories.permitsSite(host: "mail.google.com", on: defaults.isOn, expanded: true)
              && !TypingCategories.permitsSite(host: "mail.google.com", on: { $0 != .messagesAndEmail }, expanded: true), "sites, gate open: AI prompts and webmail on by default; webmail follows Messages and email")
    // Owner decision 3: "Other websites" is its own switch (on by default in
    // the saved choices); never pages stay off whatever the switches say.
    try check(!TypingCategories.permitsSite(host: "docs.google.com", on: all, other: true, expanded: true) && !TypingCategories.permitsSite(host: "chase.com", on: all, other: true, expanded: true)
              && !TypingCategories.permitsSite(host: "example.com", on: all, other: false, expanded: true) && TypingCategories.permitsSite(host: "example.com", on: { _ in false }, other: true, expanded: true)
              && !TypingCategories.permitsSite(host: "example.com", on: all, other: true, expanded: false),
              "sites, gate open: never pages stay off; other websites follow their own switch; nothing with the gate closed")

    // MARK: The store: choices, ingest refusal, the pause
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    let fresh = try store.typedTextPolicy()
    try check(!fresh.consented && fresh.categories == defaults && fresh.excludedBundles() == excludedDefault, "store: a store with no typing row reads the locked defaults")
    var consent = try store.policy(); consent.captureText = true; consent.typedConsentVersion = 1; try store.updatePolicy(consent, now: now)
    func typed(_ id: String, _ bundle: String, _ text: String = "pricing page ships Friday", at: Date = now) -> Evidence {
        Evidence(id: id, at: iso(at), kind: "keyboard.text_input", app: TypingCategories.app(bundle)?.name ?? "App", bundle: bundle, title: "Draft", text: text, synthetic: true)
    }
    func refused(_ id: String) throws -> Bool { try store.read(id, now: now) == nil && store.typedCounts().sealed == sealedBefore }
    var sealedBefore = 0
    // The master switch: a ready key without the safe-typing screen saves nothing.
    try attachTestVault(store, accept: false)
    var notAccepted = false
    do { _ = try store.ingest(typed("c-consent", "com.apple.Notes"), now: now) } catch TypedTextError.notAccepted { notAccepted = true }
    try check(notAccepted && (try refused("c-consent")), "master off: without the safe-typing screen (consent v2) typed words are refused, nothing written")
    try check(try store.typingIndicator(frontmostBundle: "com.apple.Notes", now: now) == .off, "indicator: recorder not running reads off")
    try store.acceptSafeTyping(now: now)
    try check(try store.ingest(typed("c-notes", "com.apple.Notes"), now: now) && store.ingest(typed("c-textedit", "com.apple.TextEdit"), now: now), "writing on: Notes and TextEdit typed rows are sealed")
    // Terminal and Claude: kept in the full-typing build (Code and Search boxes and AI prompts are on by
    // default), refused by the release gate in a narrow build.
    let gated = [("c-terminal", "com.apple.Terminal"), ("c-claude", "com.anthropic.claudefordesktop")]
    if shipped {
        for (id, bundle) in gated {
            try check(try store.ingest(typed(id, bundle), now: now) && store.read(id, now: now) != nil, "full-typing build: ingest keeps typed words from \(bundle) (its category is on by default)")
        }
    }
    sealedBefore = try store.typedCounts().sealed
    for (id, bundle) in (shipped ? [] : gated) + [("c-slack", "com.tinyspeck.slackmacgap"),
                         ("c-unknown", "com.example.Unknown"), ("c-empty", ""), ("c-passwords", "com.apple.Passwords"), ("c-chrome", "com.google.Chrome")] {
        try check(try !store.ingest(typed(id, bundle), now: now) && refused(id), "ingest refuses typed words from \(bundle.isEmpty ? "an unnamed app" : bundle) (release gate or not in the table)")
    }
    let unpermitted = shipped ? "com.tinyspeck.slackmacgap" : "com.apple.Terminal"
    try check(try !store.ingest(typed("c-terminal-blank", unpermitted, ""), now: now) && refused("c-terminal-blank"), "ingest refuses even a typed row without words from an app that isn't permitted")
    var window = Evidence(id: "c-window", at: iso(now), kind: "window.changed", app: "Terminal", bundle: "com.apple.Terminal", title: "zsh", synthetic: true)
    try check(try store.ingest(window, now: now), "window rows from other apps are unaffected by typing categories")
    let beforeWriting = try store.policy().revision
    let off = try store.setTypingCategory(.writing, on: false, now: now)
    try check(!off.categories.writing && off.categories.searchAndAI && off.revision != fresh.revision && store.policy().revision == beforeWriting, "a category change is saved in the typing row only (the privacy revision is unchanged, notes kept)")
    try check(try store.typedExcludedBundles().isSuperset(of: buildFour), "Writing off: Notes and TextEdit join the excluded apps")
    try check(try !store.ingest(typed("c-notes-off", "com.apple.Notes"), now: now) && refused("c-notes-off"), "Writing off: ingest refuses Notes typing")
    try store.setTypingCategory(.messagesAndEmail, on: true, now: now)
    try check(try !store.ingest(typed("c-slack-on", "com.tinyspeck.slackmacgap"), now: now) && refused("c-slack-on"), "Messages on does not open Slack while the release gate is closed")
    try store.setTypingCategory(.writing, on: true, now: now)
    // fix/typing-e2e L1: Messages and email is on by default, so it stays on here.
    try check(try store.typedTextPolicy().categories == defaults && store.typedTextPolicy().consented, "choices back to the defaults; consent kept")
    var blockedNotes = try store.policy(); blockedNotes.blockedApps = ["com.apple.Notes"]; try store.updatePolicy(blockedNotes, now: now)
    try check(try !store.ingest(typed("c-blocked", "com.apple.Notes"), now: now) && refused("c-blocked") && !(try store.typedTextPolicy().permits(bundle: "com.apple.Notes", blockedApps: ["com.apple.Notes"])), "the person's block list comes first")
    blockedNotes.blockedApps = []; try store.updatePolicy(blockedNotes, now: now)

    // The pause: stored, typing-only, never extended, ends on time.
    let until = try store.snoozeTyping(minutes: TypingPauseShortcut.minutes, now: now)
    try check(until == now.addingTimeInterval(600), "pause: ten minutes")
    try check(try store.snoozeTyping(now: now.addingTimeInterval(300)) == until, "pause: pressing it again does not extend it")
    try check(try !store.ingest(typed("c-paused", "com.apple.Notes"), now: now.addingTimeInterval(1)) && refused("c-paused"), "pause: ingest refuses typed words while paused")
    try check(try !store.ingest(typed("c-paused-late", "com.apple.Notes", at: now.addingTimeInterval(599)), now: now.addingTimeInterval(599)) && refused("c-paused-late"), "pause: still refused one second before it ends")
    window.id = "c-window-paused"; window.at = iso(now.addingTimeInterval(2))
    try check(try store.ingest(window, now: now.addingTimeInterval(2)), "pause: other recording goes on (typing only)")
    let reopened = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    try check(try reopened.typedTextPolicy().snoozed(now: now.addingTimeInterval(10)), "pause: survives a relaunch (stored)")
    try check(try store.ingest(typed("c-after", "com.apple.Notes", at: now.addingTimeInterval(601)), now: now.addingTimeInterval(601)), "pause: typing records again when it ends")
    _ = try store.snoozeTyping(now: now.addingTimeInterval(700))
    try store.resumeTyping(now: now.addingTimeInterval(701))
    try check(try store.ingest(typed("c-resumed", "com.apple.Notes", at: now.addingTimeInterval(702)), now: now.addingTimeInterval(702)), "pause: \"Record typing again\" ends it at once")
    try check(try store.typedTextPolicy().snoozeUntil.isEmpty, "pause: resume clears the stored end time")

    // MARK: Indicator (pure)
    // Consent for everything this build records (typingfix review F2: a consent keeps its scope).
    var p = TypedTextPolicy(); p.consentVersion = TypedTextPolicy.currentConsentVersion; p.acceptedScope = .current
    func state(_ capture: String = "recording", on: Bool = true, policy: TypedTextPolicy? = nil, vault: TypedVaultState = .ready, front: String = "com.apple.Notes",
               blockedApps: [String] = [], at: Date = now, allowlist: Set<String> = CaptureGate.nativeApps) -> TypingIndicatorState {
        TypingIndicator.state(capture: capture, typingOn: on, policy: policy ?? p, vault: vault, frontmostBundle: front, blockedApps: blockedApps, now: at, captureAllowlist: allowlist)
    }
    try check(state() == .recording(app: "Notes") && state(front: "com.apple.TextEdit") == .recording(app: "TextEdit"), "indicator: recording in Notes and TextEdit")
    try check(state("paused") == .off && state("unavailable") == .off && state(on: false) == .off, "indicator: off while the recorder is stopped or typing is off")
    try check(state(policy: TypedTextPolicy()) == .locked(.notAccepted), "indicator: locked until the safe-typing screen is accepted")
    try check(state(vault: .locked) == .locked(.keychainLocked) && state(vault: .keyLost) == .locked(.keyLost) && state(vault: .notSetUp) == .locked(.notSetUp) && state(vault: .unavailable) == .locked(.unavailable), "indicator: locked for every vault state but ready")
    var paused = p; paused.snoozeUntil = iso(now.addingTimeInterval(600))
    try check(state(policy: paused) == .snoozed(until: now.addingTimeInterval(600)) && state(policy: paused, at: now.addingTimeInterval(600)) == .recording(app: "Notes"), "indicator: paused until the end time, then recording again")
    var unreadable = p; unreadable.snoozeUntil = "not a time"
    try check(state(policy: unreadable) == .snoozed(until: nil), "indicator: an unreadable end time stays paused (fails closed)")
    for front in (shipped ? [] : ["com.apple.Terminal", "com.anthropic.claudefordesktop"]) + ["com.tinyspeck.slackmacgap", "com.apple.Safari", "com.google.Chrome", "com.apple.Passwords", "com.example.Unknown", ""] {
        try check(state(front: front) == .notHere, "indicator: not here in \(front.isEmpty ? "an unnamed app" : front)")
    }
    if shipped {
        try check(state(front: "com.apple.Terminal") == .recording(app: "Terminal") && state(front: "com.anthropic.claudefordesktop") == .recording(app: "Claude")
                  && state(front: "com.apple.MobileSMS") == .recording(app: "Messages"), "full-typing build indicator: recording in Terminal, Claude and Messages (on by default)")
    }
    var writingPolicy = p; writingPolicy.categories.set(.writing, false)
    try check(state(policy: writingPolicy) == .notHere, "indicator: not here when the app's category is off")
    try check(state(blockedApps: ["com.apple.Notes"]) == .notHere, "indicator: not here in an app on the block list")
    try check(state(allowlist: ["com.apple.TextEdit"]) == .notHere, "indicator: not here when the build's capture gate can't read the app")
    let cases: [TypingIndicatorState] = [.off, .locked(.notAccepted), .locked(.keychainLocked), .snoozed(until: now), .snoozed(until: nil), .notHere, .recording(app: "Notes")]
    try check(cases.filter(\.showsDot) == [.recording(app: "Notes")] && cases.filter(\.showsRing).count == 2, "indicator: the dot only while recording, the ring only while paused")
    try check(cases.compactMap(\.accessibilityLabel) == ["DayDream is recording what you type"], "indicator: accessibility label only with the dot")
    let utc = TimeZone(identifier: "UTC")!, posix = Locale(identifier: "en_US_POSIX")
    let at342 = ISO8601DateFormatter().date(from: "2026-09-24T15:42:00Z")!
    try check(TypingIndicatorState.snoozed(until: at342).menuTitle(timeZone: utc, locale: posix) == "Typing paused until 3:42 PM", "menu: paused row names the end time")
    try check(TypingIndicatorState.recording(app: "Notes").menuTitle() == "Recording what you type in Notes" && TypingIndicatorState.notHere.menuTitle() == "Not recording typing in this app"
              && TypingIndicatorState.locked(.notAccepted).menuTitle() == "Typing is locked: turn it on in Settings" && TypingIndicatorState.locked(.keychainLocked).menuTitle() == "Typing is paused until you unlock your Mac."
              && TypingIndicatorState.off.menuTitle() == nil, "menu: row strings")
    try check(TypingIndicatorState.recording(app: "Notes").menuAction == "Don't record typing for 10 minutes  ⌃⌥⌘T" && TypingIndicatorState.snoozed(until: nil).menuAction == "Record typing again" && TypingIndicatorState.off.menuAction == nil, "menu: action strings")
    try check(TypingPauseShortcut.display == "⌃⌥⌘T" && TypingPauseShortcut.minutes == 10 && TypingPauseShortcut.toast == "Typing paused for 10 minutes", "shortcut: Control-Option-Command-T, ten minutes")
    try check(TypingPauseShortcut.matches(keyCode: 17, control: true, option: true, command: true, shift: false)
              && !TypingPauseShortcut.matches(keyCode: 17, control: true, option: true, command: true, shift: true)
              && !TypingPauseShortcut.matches(keyCode: 17, control: false, option: true, command: true, shift: false)
              && !TypingPauseShortcut.matches(keyCode: 15, control: true, option: true, command: true, shift: false), "shortcut: only the exact chord matches")
    // Indicator and the store agree: "recording" only where ingest would save.
    for bundle in bundles + ["com.example.Unknown"] {
        for choice in [defaults, writingOff] {
            var policy = p; policy.categories = choice
            if state(policy: policy, front: bundle).showsDot { try check(policy.permits(bundle: bundle), "agreement: the dot in \(bundle) means the store saves there") }
        }
    }
    try check(true, "agreement: the dot never shows where the store would refuse")
    // The store helper reads the saved state (real clock: the recorder heartbeat is live).
    try store.setCaptureState("recording", reason: "synthetic fixture")
    try check(try store.typingIndicator(frontmostBundle: "com.apple.Notes") == .recording(app: "Notes")
              && store.typingIndicator(frontmostBundle: "com.apple.Terminal") == (shipped ? .recording(app: "Terminal") : .notHere)
              && store.typingIndicator(frontmostBundle: "com.tinyspeck.slackmacgap") == .notHere,
              shipped ? "indicator from the store: recording in Notes and Terminal, not here in Slack" : "indicator from the store: recording in Notes, not here in Terminal")
    _ = try store.snoozeTyping()
    if case .snoozed = try store.typingIndicator(frontmostBundle: "com.apple.Notes") { try check(true, "indicator from the store: paused after the shortcut") } else { try check(false, "indicator from the store: paused after the shortcut") }
    try store.resumeTyping()
    let reader = try MemoryStore(home: home)
    try check(try reader.typingIndicator(frontmostBundle: "com.apple.Notes") == .locked(.unavailable), "indicator in a process without the key (CLI/MCP): locked, never recording")
    try store.setCaptureState("off", reason: "fixture done")
}
