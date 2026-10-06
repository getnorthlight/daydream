import Foundation

// Safe typing E: choose by type of app. A pure, shipped table of the apps
// typing may ever be recorded in, grouped into four categories (websites are
// in TypingSites.swift).
//
// Apps not in the table never get typing. The capture gate's allowlist
// (`CaptureGate.nativeApps`) is this table's allowed set with every category
// on; the capture binding then adds every table app that is not permitted
// right now (its category is off) to `CapturePolicy.excludedApps`.
//
// Legal gate: `TypingRelease.expandedApproved` is false. While it is false
// only Notes and TextEdit (build 4's set) are allowed, whatever the table or
// the person's category choices say. The owner flips it in a reviewed commit
// after the lawyer session (launch checklist decisions 12-13). The owner
// build (`OwnerTyping`) opens the table for the owner's own device test.

/// The four kinds of apps a person chooses between.
public enum TypingCategory: String, CaseIterable, Codable, Sendable {
    case searchAndAI, writing, code, messagesAndEmail

    /// On once typing itself is turned on, all four (opt-out, owner 9/28): the
    /// person turns one off in Settings with one click. None of them does
    /// anything while typing is off.
    public var defaultOn: Bool { true }

    /// Settings checkbox title.
    public var title: String {
        switch self {
        case .searchAndAI: return "Search boxes and AI prompts"
        case .writing: return "Writing apps"
        case .code: return "Code"
        case .messagesAndEmail: return "Messages and email"
        }
    }
    /// Settings help under the checkbox.
    public var help: String {
        switch self {
        case .searchAndAI: return "Searches and questions you type in apps like Spotlight and Claude."
        case .writing: return "Notes and TextEdit."
        // Remote ssh sessions are said under Limits (`remoteLimit`), which says how long the rule lasts.
        case .code: return "Editors and terminals. Skips passwords after sudo, ssh and similar commands."
        case .messagesAndEmail: return "Your own messages only, never the conversation."
        }
    }
}

/// How far an app's typing can be read today.
public enum TypingSupport: String, CaseIterable, Sendable {
    /// Passes today's native Accessibility proof (build 4).
    case native
    /// Native UI, but not yet checked on a device.
    case nativeNeedsProbe
    /// Electron, Chromium or WebKit editor: read through the "vendor app with
    /// web content" proof (`TypingWebContent`), not yet checked on a device.
    case embeddedWeb
    /// Websites, through the Chrome join (compiled out of public builds).
    case browserJoin
    /// Text is not exposed to Accessibility (or is drawn on a canvas).
    case notSupportable

    /// A capture proof exists for this kind of row: the native proof
    /// (`native`, `nativeNeedsProbe`) or the web-content proof (`embeddedWeb`).
    public var hasAppProof: Bool { self == .native || self == .nativeNeedsProbe || self == .embeddedWeb }
    /// Checked on a device (build 4's Notes and TextEdit). Every other row
    /// waits for the MacBook device test, which moves it to `native`.
    public var deviceProbed: Bool { self == .native }
}

/// Who must have signed the app. A bundle ID alone is never trusted.
public enum TypingSigner: Equatable, Sendable {
    /// Apple's own signature (the apps that come with macOS).
    case apple
    /// A Mac App Store copy: Apple signs it for the store, which keeps bundle
    /// IDs unique, so the identifier plus the store's mark names the app.
    /// (Pages on this Mac: "Apple Mac OS Application Signing".)
    case appStore
    /// A Developer ID team, read from the app on a Mac that has it.
    case team(String)
    /// Not read yet. Such a row can never be enabled.
    case unconfirmed
}

/// How an app that shows web content is read: the "vendor app with web
/// content" proof (`WebContentFocusWitness`). The vendor's signed process, its
/// own page (one web area, loaded from the vendor's own scheme or hosts), an
/// editable field that is not a password field. Anything else in the app (a
/// built-in browser, a link preview, an embedded frame) is refused.
public struct TypingWebContent: Equatable, Sendable {
    /// Electron and Chromium build their Accessibility tree only after
    /// `AXManualAccessibility` is set on the app. DayDream sets it once per
    /// process. WebKit (Mail) needs neither.
    public let manualAccessibility: Bool
    /// chatgpt-capture: the app has no `AXManualAccessibility` (read and set both "unsupported"), so its Chromium builds
    /// a web tree only when `AXEnhancedUserInterface` is on, the attribute VoiceOver sets. DayDream then sets that one,
    /// once per process, and only while recording, typing for this app and its signature all hold
    /// (`AccessibilityReader.prepareAppTree`); it turns it back off when they stop holding. Trade-off: with it on,
    /// Chromium keeps a full Accessibility tree (some CPU and memory while the app runs) and animates window frame
    /// changes, so window managers that move windows through Accessibility (Rectangle, Magnet) are slower there;
    /// Rectangle already turns it off around each move and back on after. Only rows listed in
    /// `TypingCategories.enhancedUserInterfaceApps` (ChatGPT) may set it; a check keeps that list to one app.
    public let enhancedUserInterface: Bool
    /// Non-web schemes the vendor's own UI is loaded from.
    public let schemes: Set<String>
    /// https hosts the vendor serves its own UI from (a subdomain counts).
    public let hosts: Set<String>
    /// The vendor's page has no URL at all (Mail's message body).
    public let urlless: Bool
    /// The editable web area itself takes focus (Mail's message body).
    public let webAreaEditor: Bool
    public init(manualAccessibility: Bool, schemes: Set<String> = ["file", "app"], hosts: Set<String> = [],
                urlless: Bool = false, webAreaEditor: Bool = false, enhancedUserInterface: Bool = false) {
        self.manualAccessibility = manualAccessibility; self.schemes = schemes; self.hosts = hosts
        self.urlless = urlless; self.webAreaEditor = webAreaEditor; self.enhancedUserInterface = enhancedUserInterface
    }
    /// Whether the web area's URL (`AXURL`, read with the proof) is the
    /// vendor's own UI. nil or "" = the page has no URL. Plain http, other
    /// hosts, credentials in the URL and unknown schemes are refused.
    public func admits(url: String?) -> Bool {
        guard let url, !url.isEmpty else { return urlless }
        guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(), !scheme.isEmpty,
              parts.user == nil, parts.password == nil else { return false }
        switch scheme {
        case "https":
            guard let host = parts.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), !host.isEmpty else { return false }
            return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        case "http", "data", "blob", "javascript", "about", "ftp", "ws", "wss": return false
        default: return schemes.contains(scheme)
        }
    }
    /// Electron or Chromium with its UI in bundled files.
    public static let electron = TypingWebContent(manualAccessibility: true)
    /// Electron with its UI served from the vendor's own https hosts.
    public static func electron(hosts: Set<String>) -> TypingWebContent { TypingWebContent(manualAccessibility: true, hosts: hosts) }
    /// chatgpt-capture: an Electron fork without `AXManualAccessibility` (ChatGPT's "Codex Framework", Chromium 154):
    /// its UI in bundled files, its web tree built only with `AXEnhancedUserInterface` (`enhancedUserInterface`).
    public static let electronWithoutManualSwitch = TypingWebContent(manualAccessibility: true, enhancedUserInterface: true)
}

public struct TypingApp: Equatable, Sendable {
    public let bundle: String
    public let name: String
    public let category: TypingCategory
    public let signer: TypingSigner
    public let support: TypingSupport
    /// false when the bundle ID itself was not read from the app yet.
    public let bundleConfirmed: Bool
    /// Terminals and editors with a built-in terminal: `TerminalPromptLatch` applies.
    public let promptLatch: Bool
    /// `embeddedWeb` rows: how the web-content proof reads the app. nil for
    /// every other row (an `embeddedWeb` row without it is never allowed).
    public let web: TypingWebContent?
    /// A launcher panel that takes key focus while the app behind it stays
    /// frontmost (Spotlight). Its keys are proved against the panel's own
    /// process, never the frontmost app.
    public let keyPanel: Bool
    public init(_ bundle: String, _ name: String, _ category: TypingCategory, _ signer: TypingSigner, _ support: TypingSupport,
                bundleConfirmed: Bool = true, promptLatch: Bool = false, web: TypingWebContent? = nil, keyPanel: Bool = false) {
        self.bundle = bundle; self.name = name; self.category = category; self.signer = signer; self.support = support
        self.bundleConfirmed = bundleConfirmed; self.promptLatch = promptLatch; self.web = web; self.keyPanel = keyPanel
    }
}

/// The legal gate (SPEC 11). A code constant; a check asserts it is false.
public enum TypingRelease {
    public static let expandedApproved = false
    /// What the running build allows: the legal gate, or the owner build
    /// (`OwnerTyping`, the compile flag every release stage passes). Every
    /// `expanded:` default reads this, never the flag itself.
    public static var open: Bool { expandedApproved || OwnerTyping.enabled }
    /// The device-test build. Rows whose proof is built but not yet checked
    /// on a device (`nativeNeedsProbe`, `embeddedWeb`) open only in the owner
    /// build, which is the build the MacBook device test runs. The lawyer's
    /// constant alone opens only device-probed (`native`) rows; the device
    /// test moves each row that passes to `native`.
    public static var probeBuild: Bool { OwnerTyping.enabled }
    /// Build 4's set: the only apps typing works in until the gate is flipped.
    public static let buildFourApps: Set<String> = ["com.apple.Notes", "com.apple.TextEdit"]
}

public enum TypingCategories {
    /// The shipped table (SPEC 6.2). Signers and bundle IDs were read from
    /// the apps on this Mac with `codesign -dv` (scripts/read-typing-signers.sh):
    /// Claude Q6L2SF6YDW, ChatGPT/Codex 2DC432GLL2, Ghostty 24VZTF6M5V, Zed
    /// MQ55VZLNZQ, Pages (Mac App Store, `com.apple.Pages`), and Apple's
    /// Spotlight, Terminal, Mail and Messages. Read by the owner on his laptop
    /// (2026-09-28): WhatsApp 57T9237FN3, Obsidian 6JSW4SJWN9 and Cursor
    /// VDXQ22DGB9. Xcode is not on this Mac; its row
    /// names Apple's signature, so a copy Apple did not sign fails the check.
    /// Every other third-party team is UNCONFIRMED until read on a Mac that
    /// has the app; such a row stays off.
    public static let apps: [TypingApp] = [
        // Writing
        TypingApp("com.apple.Notes", "Notes", .writing, .apple, .native),
        TypingApp("com.apple.TextEdit", "TextEdit", .writing, .apple, .native),
        // Pages as the Mac App Store ships it now ("Pages Creator Studio" on
        // this Mac): bundle com.apple.Pages, signed for the App Store.
        TypingApp("com.apple.Pages", "Pages", .writing, .appStore, .nativeNeedsProbe),
        // Older Pages releases used com.apple.iWork.Pages; not read on this Mac.
        TypingApp("com.apple.iWork.Pages", "Pages", .writing, .apple, .nativeNeedsProbe, bundleConfirmed: false),
        TypingApp("com.microsoft.Word", "Microsoft Word", .writing, .unconfirmed, .nativeNeedsProbe),
        TypingApp("notion.id", "Notion", .writing, .unconfirmed, .embeddedWeb, web: .electron(hosts: ["notion.so"])),
        // Read on the owner's laptop (2026-09-28): md.obsidian, "Developer ID Application: Dynalist Inc. (6JSW4SJWN9)".
        // Electron; its UI is app://obsidian.md (bundled files).
        TypingApp("md.obsidian", "Obsidian", .writing, .team("6JSW4SJWN9"), .embeddedWeb, web: .electron),
        // Search boxes and AI prompts
        TypingApp("com.apple.Spotlight", "Spotlight", .searchAndAI, .apple, .nativeNeedsProbe, keyPanel: true),
        // Claude's window shows claude.ai.
        TypingApp("com.anthropic.claudefordesktop", "Claude", .searchAndAI, .team("Q6L2SF6YDW"), .embeddedWeb, web: .electron(hosts: ["claude.ai"])),
        // Electron (app.asar) with its UI in bundled files; its built-in
        // browser pages are https pages on other hosts, so they are refused.
        // chatgpt-capture: its framework (an Electron fork, "Codex Framework") has no AXManualAccessibility, so with
        // nothing else on (VoiceOver) it exposes no web tree and no key was ever proved (owner's laptop, 26.930.51102:
        // no focused element). It is the one row that may turn AXEnhancedUserInterface on (`enhancedUserInterfaceApps`).
        TypingApp("com.openai.codex", "ChatGPT", .searchAndAI, .team("2DC432GLL2"), .embeddedWeb, web: .electronWithoutManualSwitch),
        // fix/sx-all round 3: OpenAI's native ChatGPT app (com.openai.chat, AppKit/SwiftUI text fields). Same developer as
        // com.openai.codex above (team 2DC432GLL2, read on this Mac); the requirement pins that team, so a copy signed by
        // anyone else is refused. Native fields, each checked fresh before a character is read.
        TypingApp("com.openai.chat", "ChatGPT", .searchAndAI, .team("2DC432GLL2"), .nativeNeedsProbe),
        // Raycast 2.0 is WKWebView: no manual switch.
        TypingApp("com.raycast.macos", "Raycast", .searchAndAI, .unconfirmed, .embeddedWeb, web: TypingWebContent(manualAccessibility: false), keyPanel: true),
        TypingApp("ai.perplexity.mac", "Perplexity", .searchAndAI, .unconfirmed, .nativeNeedsProbe, bundleConfirmed: false),
        // Code
        TypingApp("com.apple.Terminal", "Terminal", .code, .apple, .nativeNeedsProbe, promptLatch: true),
        TypingApp("com.googlecode.iterm2", "iTerm2", .code, .unconfirmed, .nativeNeedsProbe, promptLatch: true),
        TypingApp("com.mitchellh.ghostty", "Ghostty", .code, .team("24VZTF6M5V"), .nativeNeedsProbe, promptLatch: true),
        TypingApp("com.apple.dt.Xcode", "Xcode", .code, .apple, .nativeNeedsProbe),
        TypingApp("com.microsoft.VSCode", "Visual Studio Code", .code, .unconfirmed, .embeddedWeb, promptLatch: true,
                  web: TypingWebContent(manualAccessibility: true, schemes: ["vscode-file"])),
        // Read on the owner's laptop (2026-09-28): com.todesktop.230313mzl4w4u92, "Developer ID Application: Hilary Stout
        // (VDXQ22DGB9)". Cursor is built by ToDesktop, so the leaf names a person; the requirement pins the team
        // (leaf[subject.OU]), never the name. A VS Code fork: its integrated terminal (xterm.js) and its Monaco editor are
        // refused by label (`CaptureGate.webTerminalField`), like VS Code's.
        TypingApp("com.todesktop.230313mzl4w4u92", "Cursor", .code, .team("VDXQ22DGB9"), .embeddedWeb, promptLatch: true,
                  web: TypingWebContent(manualAccessibility: true, schemes: ["vscode-file"])),
        TypingApp("dev.zed.Zed", "Zed", .code, .team("MQ55VZLNZQ"), .notSupportable),
        TypingApp("dev.warp.Warp-Stable", "Warp", .code, .unconfirmed, .notSupportable, bundleConfirmed: false),
        // Messages and email
        TypingApp("com.apple.MobileSMS", "Messages", .messagesAndEmail, .apple, .nativeNeedsProbe),
        // Mail: To and Subject are native fields; the message body is an
        // editable WebKit area with no URL.
        TypingApp("com.apple.mail", "Mail", .messagesAndEmail, .apple, .embeddedWeb,
                  web: TypingWebContent(manualAccessibility: false, schemes: [], urlless: true, webAreaEditor: true)),
        TypingApp("com.tinyspeck.slackmacgap", "Slack", .messagesAndEmail, .unconfirmed, .embeddedWeb, web: .electron(hosts: ["app.slack.com"])),
        TypingApp("com.hnc.Discord", "Discord", .messagesAndEmail, .unconfirmed, .embeddedWeb, web: .electron(hosts: ["discord.com"])),
        // Read on the owner's laptop (2026-09-28): net.whatsapp.WhatsApp, "Developer ID Application: WhatsApp Inc. (57T9237FN3)".
        // The window title names no chat, so a send names nobody (known gap).
        TypingApp("net.whatsapp.WhatsApp", "WhatsApp", .messagesAndEmail, .team("57T9237FN3"), .nativeNeedsProbe),
        TypingApp("com.microsoft.Outlook", "Microsoft Outlook", .messagesAndEmail, .unconfirmed, .embeddedWeb, web: TypingWebContent(manualAccessibility: false)),
    ]

    /// Checked before any category: never recorded, not a setting. Password
    /// managers (the capture gate's list), Passwords, Keychain Access, System
    /// Settings, the system password dialogs and DayDream itself (both app IDs). The store adds the person's block list
    /// and `PrivacySettings.sensitiveApps` (a check keeps them covered here).
    public static let alwaysBlocked: Set<String> = CaptureGate.passwordManagers.union([
        "com.apple.Passwords", "com.apple.keychainaccess", "com.apple.systempreferences",
        "com.apple.SecurityAgent", "com.apple.loginwindow", "com.getnorthlight.daydream", "com.macmem.app",
        // Copy of MemoryCore's `PasswordManagerApps.bundleIDs` (the saturday list), which this package
        // cannot import; Checks/TypingCategoryChecks.swift fails when any of them is missing here.
        "com.agilebits.onepassword-osx", "com.agilebits.onepassword4", "com.lastpass.lastpassmacdesktop",
        "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc", "me.proton.pass.electron", "me.proton.pass.catalyst",
        "in.sinew.Enpass-Desktop", "in.sinew.Enpass-Desktop.App", "com.nordsec.nordpass", "com.keepersecurity.passwordmanager",
        "com.callpod.keepermac", "com.siber.RoboForm", "com.siber.roboform.mac", "com.markmcguill.strongbox.mac",
        "com.markmcguill.strongbox.mac.pro", "com.keepassium.ios", "com.hicknhacksoftware.MacPass", "pw.buttercup.desktop",
        "com.outercorner.Secrets",
    ])

    /// chatgpt-capture: the rows whose app may get `AXEnhancedUserInterface` from DayDream (`TypingWebContent.enhancedUserInterface`).
    /// Exactly ChatGPT (`com.openai.codex`); Checks/TypingCategoryChecks.swift fails if any other row asks for it.
    public static let enhancedUserInterfaceApps: Set<String> = Set(apps.filter { $0.web?.enhancedUserInterface == true }.map(\.bundle))

    private static let byBundle: [String: TypingApp] = Dictionary(apps.map { ($0.bundle, $0) }, uniquingKeysWith: { a, _ in a })
    public static func app(_ bundle: String) -> TypingApp? { byBundle[bundle] }
    public static func apps(in category: TypingCategory) -> [TypingApp] { apps.filter { $0.category == category } }

    /// The code-signing requirement a running process must satisfy before its
    /// typing is read (checked in the later run's witness). nil when the
    /// signer was not read yet: such a row is never enabled.
    public static func signingRequirement(_ app: TypingApp) -> String? {
        switch app.signer {
        case .apple: return "anchor apple and identifier \"\(app.bundle)\""
        case .appStore: return "anchor apple generic and identifier \"\(app.bundle)\" and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"
        case .team(let team):
            guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
            return "anchor apple generic and identifier \"\(app.bundle)\" and certificate leaf[subject.OU] = \"\(team)\""
        case .unconfirmed: return nil
        }
    }

    /// Whether the release lets this row record typing at all. While the gate
    /// is closed: Notes and TextEdit only. Once open: rows with a capture
    /// proof, a known signer and a confirmed bundle ID; for terminals, only
    /// once the prompt latch is wired (`TerminalPromptLatch.wired`); and for
    /// rows not yet checked on a device, only in the device-test build
    /// (`TypingRelease.probeBuild`). Website and unsupportable rows never.
    /// `latchWired` can only close: checks pass false to prove that terminals
    /// are refused without the latch. It never opens a terminal on its own.
    public static func releaseAllows(_ app: TypingApp, expanded: Bool = TypingRelease.open,
                                     probeBuild: Bool = TypingRelease.probeBuild,
                                     latchWired: Bool = true) -> Bool {
        guard !alwaysBlocked.contains(app.bundle), app.support.hasAppProof, app.bundleConfirmed,
              signingRequirement(app) != nil,
              // A web-content row needs its web-content rules.
              app.support != .embeddedWeb || app.web != nil,
              // Terminals need the prompt latch in capture first.
              !app.promptLatch || TerminalPromptLatch.wired && latchWired else { return false }
        if TypingRelease.buildFourApps.contains(app.bundle) && app.support.deviceProbed { return true }
        return expanded && (app.support.deviceProbed || probeBuild)
    }

    /// The one app rule: not always blocked, in the table, its category on,
    /// and allowed by the release. `on` answers the person's category choices.
    public static func permits(bundle: String, on: (TypingCategory) -> Bool, expanded: Bool = TypingRelease.open,
                               probeBuild: Bool = TypingRelease.probeBuild) -> Bool {
        guard !alwaysBlocked.contains(bundle), let app = app(bundle) else { return false }
        return on(app.category) && releaseAllows(app, expanded: expanded, probeBuild: probeBuild)
    }
    public static func allowedBundles(on: (TypingCategory) -> Bool, expanded: Bool = TypingRelease.open,
                                      probeBuild: Bool = TypingRelease.probeBuild) -> Set<String> {
        Set(apps.map(\.bundle).filter { permits(bundle: $0, on: on, expanded: expanded, probeBuild: probeBuild) })
    }
    /// The capture allowlists for one build: every allowed row with every
    /// category on (the person's category choices are applied later, as
    /// excluded apps), and which of them the web-content proof reads, and
    /// which are launcher panels. Public builds: Notes and TextEdit, no web
    /// content, no panel.
    public static func captureApps(expanded: Bool = TypingRelease.open, probeBuild: Bool = TypingRelease.probeBuild) -> TypingCaptureApps {
        let allowed = allowedBundles(on: { _ in true }, expanded: expanded, probeBuild: probeBuild)
        return TypingCaptureApps(all: allowed,
                                 webContent: allowed.filter { app($0)?.support == .embeddedWeb },
                                 keyPanels: allowed.filter { app($0)?.keyPanel == true })
    }
    /// Deny-only addition to `CapturePolicy.excludedApps`: every table app
    /// that is not permitted right now, plus the always-blocked apps.
    public static func excludedBundles(on: (TypingCategory) -> Bool, expanded: Bool = TypingRelease.open,
                                       probeBuild: Bool = TypingRelease.probeBuild) -> Set<String> {
        Set(apps.map(\.bundle).filter { !permits(bundle: $0, on: on, expanded: expanded, probeBuild: probeBuild) }).union(alwaysBlocked)
    }

    /// Apps whose signer or bundle ID was not read yet, by name: what the
    /// owner reads next (`scripts/read-typing-signers.sh`) to open them.
    public static var awaitingSigner: [TypingApp] {
        apps.filter { $0.support.hasAppProof && ($0.signer == .unconfirmed || !$0.bundleConfirmed) }
    }

    /// Settings footer and honest limits (SPEC 6.3, 9.2), plain words.
    public static let footer = "Apps not listed here are never recorded."
    /// Under Limits while the build records a terminal (moved from the Code help line). The remote-session rule
    /// lasts only until the focus changes (`TerminalPromptLatch.focusChanged`): back in the remote shell, whose title
    /// rarely names ssh, typing is recorded again, and the line says so.
    public static let remoteLimit = "After you run ssh, DayDream stops recording in that terminal until you switch to another tab, window or app. If you come back to the remote session, what you type there can be recorded."
    public static let incognitoLimit = "DayDream can't tell when a chat app is in incognito mode. Turn off AI prompts, or pause typing, before using it."
    public static let terminalLimit = "DayDream can't always tell when a terminal is asking for a password. Passwords after sudo, ssh and similar commands are skipped."
}

/// A build's capture allowlists (`CaptureGate.nativeApps` and friends).
public struct TypingCaptureApps: Equatable, Sendable {
    /// Every app typing may be read in (native and web-content proofs).
    public let all: Set<String>
    /// The subset read through the web-content proof (its native fields, like
    /// Mail's To and Subject, still go through the native rules).
    public let webContent: Set<String>
    /// Launcher panels proved against their own process (Spotlight).
    public let keyPanels: Set<String>
    public init(all: Set<String>, webContent: Set<String>, keyPanels: Set<String>) {
        self.all = all; self.webContent = webContent.intersection(all); self.keyPanels = keyPanels.intersection(all)
    }
}
