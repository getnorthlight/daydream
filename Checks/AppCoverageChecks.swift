import Foundation
import MemoryCore
import PrivacyPolicy

/// fix/app-coverage: the launch app matrix, one synthetic fixture per app class.
/// Each native row is an Accessibility proof shaped like the app's text box (a native text area or field, an Electron
/// or WebKit page's editable area, Mail's body web area) put through the capture gate with the full-typing build's
/// allowlists and every category on (build 7: Messages and email on by default). Each Chrome row is a site through
/// the website typing site rules, and (Chrome typing builds) a Chrome text box on that host through the website gate.
/// No app, window, permission or store is touched.
func runAppCoverageChecks() throws {
    let owner = TypingCategories.captureApps(expanded: true, probeBuild: true)
    let choices = TypedCategoryChoices()
    try check(choices.enabled == Set(TypingCategory.allCases), "app coverage: every typing category starts on, Messages and email included")
    var policy = CapturePolicy(); policy.typedText = true
    policy.excludedApps = TypingCategories.excludedBundles(on: choices.isOn, expanded: true, probeBuild: true)
    func proof(_ bundle: String, surface: AppSurface = .native, role: String = "AXTextArea", subrole: String = "", label: String = "") -> FocusProof {
        var p = FocusProof()
        p.bundle = bundle; p.surface = surface; p.windowID = "w-" + bundle; p.focusID = UUID().uuidString; p.role = role; p.subrole = subrole
        p.fieldLabel = label; p.checkedAt = 1_000; p.policyVersion = policy.version; p.secureInput = .no; p.privateMode = .no
        p.verified = true; p.fieldStateVerified = true; p.frameAccessible = true; p.navigationStable = true
        return p
    }
    func gate(_ p: FocusProof) -> PrivacyDecision { CaptureGate.typing(p, policy: policy, generation: 0, now: 1_000, apps: owner) }

    // Native apps: (bundle, AX shape of the text box, captured in build 7?). Not captured: the signer was not read on
    // a Mac yet (`TypingSigner.unconfirmed`), or the app is not in the table at all.
    let native: [(bundle: String, surface: AppSurface, role: String, captured: Bool, why: String)] = [
        ("com.apple.MobileSMS", .native, "AXTextArea", true, "Messages: the message box"),
        ("com.apple.mail", .native, "AXTextField", true, "Mail: To and Subject are native fields"),
        ("com.apple.mail", .embeddedWeb, "AXWebArea", true, "Mail: the body is an editable WebKit area"),
        ("com.apple.Notes", .native, "AXTextArea", true, "Notes"),
        ("com.apple.Pages", .native, "AXTextArea", true, "Pages (Mac App Store)"),
        ("com.apple.dt.Xcode", .native, "AXTextArea", true, "Xcode's editor"),
        ("com.apple.Terminal", .native, "AXTextArea", true, "Terminal (prompt latch wired)"),
        ("com.anthropic.claudefordesktop", .embeddedWeb, "AXTextArea", true, "Claude's prompt box (claude.ai page)"),
        ("com.openai.codex", .embeddedWeb, "AXTextArea", true, "ChatGPT's prompt box"),
        ("com.tinyspeck.slackmacgap", .embeddedWeb, "AXTextArea", false, "Slack: signer not read"),
        ("com.hnc.Discord", .embeddedWeb, "AXTextArea", false, "Discord: signer not read"),
        ("net.whatsapp.WhatsApp", .native, "AXTextArea", true, "WhatsApp's message box (signer read 2026-09-28)"),
        ("com.microsoft.Outlook", .embeddedWeb, "AXTextArea", false, "Outlook: signer not read"),
        ("com.microsoft.Word", .native, "AXTextArea", false, "Word: signer not read"),
        ("notion.id", .embeddedWeb, "AXTextArea", false, "Notion: signer not read"),
        ("md.obsidian", .embeddedWeb, "AXTextArea", true, "Obsidian's editor (signer read 2026-09-28)"),
        ("com.microsoft.VSCode", .embeddedWeb, "AXTextArea", false, "VS Code: signer not read"),
        ("com.todesktop.230313mzl4w4u92", .embeddedWeb, "AXTextArea", true, "Cursor's text boxes (signer and bundle read 2026-09-28)"),
        ("com.googlecode.iterm2", .native, "AXTextArea", false, "iTerm2: signer not read"),
        ("ai.perplexity.mac", .native, "AXTextArea", false, "Perplexity: signer and bundle not read"),
        ("ru.keepcoder.Telegram", .native, "AXTextArea", false, "Telegram: not in the table"),
        ("org.whispersystems.signal-desktop", .embeddedWeb, "AXTextArea", false, "Signal: not in the table"),
        ("com.microsoft.teams2", .embeddedWeb, "AXTextArea", false, "Teams: not in the table"),
        ("us.zoom.xos", .native, "AXTextArea", false, "Zoom: not in the table"),
        // fix/sx-all round 3: OpenAI's native ChatGPT app, pinned to OpenAI's team (2DC432GLL2, read from com.openai.codex
        // on the owner's Mac; com.openai.chat itself isn't installed there).
        ("com.openai.chat", .native, "AXTextArea", true, "ChatGPT's native app (com.openai.chat)"),
    ]
    for row in native {
        let decision = gate(proof(row.bundle, surface: row.surface, role: row.role))
        try check((decision.outcome == .allowed) == row.captured,
                  "app coverage: \(row.why) is \(row.captured ? "captured" : "not captured") in build 7 (\(decision.reason))")
    }
    // The owner set is exactly the captured rows above plus TextEdit, Spotlight and Ghostty.
    let captured = Set(native.filter(\.captured).map(\.bundle))
    try check(owner.all == captured.union(["com.apple.TextEdit", "com.apple.Spotlight", "com.mitchellh.ghostty"]),
              "app coverage: the full-typing build's apps are the matrix's captured rows plus TextEdit, Spotlight and Ghostty")
    // Every uncaptured table row is waiting for its signer or bundle ID, never for a rule.
    for row in native where !row.captured {
        guard let app = TypingCategories.app(row.bundle) else { continue }
        try check(TypingCategories.awaitingSigner.contains(app), "app coverage: \(row.why) opens once its signer is read (scripts/read-typing-signers.sh)")
    }

    // Protections that stay: a secure field, a sensitive or web-terminal label, a password manager, Keychain Access.
    try check(gate(proof("com.apple.MobileSMS", subrole: "AXSecureTextField")).reason == .sensitiveField,
              "app coverage: a secure text field in Messages is refused")
    var denied = proof("com.apple.mail", role: "AXTextField", label: "Verification code"); denied.fieldLabelDenied = true
    try check(gate(denied).reason == .sensitiveField, "app coverage: a field labelled as a code is refused in Mail")
    for bundle in ["com.1password.1password", "com.apple.keychainaccess", "com.bitwarden.desktop"] {
        try check(gate(proof(bundle)).outcome == .blocked, "app coverage: \(bundle) is always blocked")
    }
    try check(gate(proof("com.apple.mail", surface: .embeddedWeb, role: "AXTextArea")).outcome == .allowed
              && gate(proof("com.anthropic.claudefordesktop", surface: .embeddedWeb, role: "AXWebArea")).outcome != .allowed,
              "app coverage: only Mail's body may be the web area itself")
    // fix/signers: the rows read on the owner's laptop (2026-09-28) pin the team, not the leaf's name (Cursor is a
    // ToDesktop build whose leaf names a person), and keep every protection.
    for (bundle, team) in [("net.whatsapp.WhatsApp", "57T9237FN3"), ("md.obsidian", "6JSW4SJWN9"), ("com.todesktop.230313mzl4w4u92", "VDXQ22DGB9")] {
        let app = TypingCategories.app(bundle)
        try check(app?.signer == .team(team) && app?.bundleConfirmed == true && app.flatMap(TypingCategories.signingRequirement) ==
                  "anchor apple generic and identifier \"\(bundle)\" and certificate leaf[subject.OU] = \"\(team)\"",
                  "app coverage: \(bundle) needs its own identifier and team \(team)")
    }
    try check(TypingCategories.app("net.whatsapp.WhatsApp")?.category == .messagesAndEmail && TypingCategories.app("md.obsidian")?.category == .writing
              && TypingCategories.app("com.todesktop.230313mzl4w4u92")?.category == .code && TypingCategories.app("com.todesktop.230313mzl4w4u92")?.promptLatch == true,
              "app coverage: WhatsApp is Messages and email, Obsidian is Writing, Cursor is Code with the prompt latch")
    try check(gate(proof("net.whatsapp.WhatsApp", subrole: "AXSecureTextField")).reason == .sensitiveField
              && gate(proof("md.obsidian", surface: .embeddedWeb, subrole: "AXSecureTextField")).reason == .sensitiveField
              && gate(proof("com.todesktop.230313mzl4w4u92", surface: .embeddedWeb, role: "AXWebArea")).outcome != .allowed,
              "app coverage: a secure field in WhatsApp or Obsidian is refused, and Cursor's whole web area is not a field")
    var whatsappCode = proof("net.whatsapp.WhatsApp", label: "Verification code"); whatsappCode.fieldLabelDenied = true
    try check(gate(whatsappCode).reason == .sensitiveField, "app coverage: a field labelled as a code is refused in WhatsApp")
    // Cursor's integrated terminal is VS Code's xterm.js (helper textarea "xterm-helper-textarea", aria-label "Terminal
    // N, zsh ..."), and its code editor is Monaco ("inputarea monaco-mouse-cursor-text"): both refused by label and
    // discarded, like VS Code's and ChatGPT's (`CaptureGate.webTerminalField`). The words exist only in the full-typing
    // build, the only build that reads app web content.
    if OwnerTyping.enabled {
        for label in ["Terminal 1, zsh xterm-helper-textarea", "xterm-helper-textarea", "Terminal input", "inputarea monaco-mouse-cursor-text", "Editor content"] {
            var terminal = proof("com.todesktop.230313mzl4w4u92", surface: .embeddedWeb, label: label)
            terminal.fieldLabelDenied = CaptureGate.deniesFieldLabel(label, embeddedWeb: true)
            try check(terminal.fieldLabelDenied && gate(terminal).reason == .sensitiveField && CaptureGate.typingDenyReasons.contains(.sensitiveField),
                      "app coverage: Cursor's terminal or code editor is refused and its words discarded: \(label)")
        }
        var chat = proof("com.todesktop.230313mzl4w4u92", surface: .embeddedWeb, label: "Plan, search, build anything aislash-editor-input")
        chat.fieldLabelDenied = CaptureGate.deniesFieldLabel(chat.fieldLabel, embeddedWeb: true)
        try check(!chat.fieldLabelDenied && gate(chat).outcome == .allowed, "app coverage: Cursor's AI chat box (not a terminal or editor) is captured")
    }
    // Messages and email turned off (one click in Settings) excludes Messages and Mail again.
    var messagesOff = policy
    messagesOff.excludedApps = TypingCategories.excludedBundles(on: TypedCategoryChoices(messagesAndEmail: false).isOn, expanded: true, probeBuild: true)
    try check(CaptureGate.typing(proof("com.apple.MobileSMS"), policy: messagesOff, generation: 0, now: 1_000, apps: owner).reason == .excludedApp
              && CaptureGate.typing(proof("com.apple.Notes"), policy: messagesOff, generation: 0, now: 1_000, apps: owner).outcome == .allowed,
              "app coverage: Messages and email off excludes Messages; Notes stays")

    // WHO and WHAT each class saves as send facts (code-read, never the typed words).
    try check(SendRules.facts(bundle: "com.apple.MobileSMS", title: "Family", field: "textArea", seal: .submit).to == "Family",
              "app coverage: Messages saves the group name from the window title")
    try check(SendRules.facts(bundle: "com.apple.mail", title: "Pricing", field: "body", recipient: "Sam Lee", seal: .mailSend).to == "Sam Lee",
              "app coverage: Mail saves the To name (sealed by the store)")
    try check(SendRules.facts(bundle: "com.tinyspeck.slackmacgap", title: "general (Channel) - Acme - Slack", field: "textArea",
                              composerPlace: "#general", seal: .submit).to == "#general",
              "app coverage: the Slack app saves its composer's channel")
    try check(SendRules.facts(bundle: "com.google.Chrome", host: "app.slack.com", field: "message", composerPlace: "#launch", seal: .submit).to == "#launch",
              "app coverage: Slack in Chrome saves its composer's channel")
    try check(SendRules.facts(bundle: "com.google.Chrome", host: "mail.google.com", field: "body", seal: .submitChord).surface == "email"
              && SendRules.facts(bundle: "com.google.Chrome", host: "claude.ai", field: "textArea", seal: .submit).surface == "ai"
              && SendRules.facts(bundle: "com.anthropic.claudefordesktop", title: "Claude", field: "textArea", seal: .submit).surface == "ai"
              && SendRules.facts(bundle: "com.google.Chrome", host: "www.google.com", field: "search", seal: .submit).surface == "search"
              && SendRules.facts(bundle: "com.google.Chrome", host: "www.linkedin.com", field: "message", seal: .submit).surface == "social",
              "app coverage: Gmail is email, Claude (app and site) is AI, Google is search, LinkedIn is social")

    // Chrome rows: `checkAppCoverageSites` (Checks/WebTypingChecks.swift, Chrome typing builds only).
}
