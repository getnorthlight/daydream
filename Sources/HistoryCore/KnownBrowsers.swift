// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.

import Foundation

/// A bundle-identifier list with exact and prefix entries.
///
/// An entry matches a bundle identifier when the two are equal, or, for an
/// entry ending in `*`, when the identifier starts with the text before the
/// `*`. Matching ignores case and surrounding whitespace, because macOS treats
/// bundle identifiers case-insensitively (Chrome for Testing ships as
/// `com.google.chrome.for.testing`, and macOS records Chrome web apps as
/// `com.google.chrome.app.*`). An empty identifier never matches, and an entry
/// that is only `*` is ignored rather than matching everything.
public struct BrowserBundleList: Sendable, Equatable {
    public let patterns: [String]
    private let exact: Set<String>
    private let prefixes: [String]

    public init(_ patterns: [String]) {
        self.patterns = patterns
        var exact = Set<String>(), prefixes = [String]()
        for raw in patterns {
            let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if pattern.hasSuffix("*") {
                let stem = String(pattern.dropLast())
                if !stem.isEmpty { prefixes.append(stem) }
            } else if !pattern.isEmpty {
                exact.insert(pattern)
            }
        }
        self.exact = exact
        self.prefixes = prefixes
    }

    public func contains(_ bundleIdentifier: String) -> Bool {
        let id = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return false }
        return exact.contains(id) || prefixes.contains { id.hasPrefix($0) }
    }

    public static func == (lhs: BrowserBundleList, rhs: BrowserBundleList) -> Bool { lhs.patterns == rhs.patterns }
}

/// The one browser list for every capture path: private-window detection
/// (`ObservationPolicy`), the intake skip list (`CaptureSession`), the
/// snapshot, URL and click paths, native receipts, pre-capture typing checks
/// and read-time sanitising. A bundle on this list is skipped entirely (no
/// window titles, page addresses, clicks or typing) unless a separate verified
/// browser provider accepts that exact record.
///
/// Matching too much only skips an app. Matching too little records a browser
/// as an ordinary app, including page titles of private windows, so families
/// are listed by prefix.
///
/// `PrivacyPolicy.CaptureGate.browserPatterns` must stay identical: that
/// package cannot import HistoryCore. `Checks/CaptureChecks.swift` fails when
/// the two lists or their matching differ.
///
/// Sources: bundle identifiers marked "cask" come from the `:quit` or
/// `~/Library/Preferences/<id>.plist` entries of the Homebrew cask metadata
/// (API cache of 2026-09-11). Entries marked UNCONFIRMED have no such record.
public enum KnownBrowsers {
    public static let patterns: [String] = [
        // Chromium family
        "com.google.Chrome*",            // Chrome, .beta, .dev, .canary (cask); web-app shims com.google.Chrome.app.* (cask zap: com.google.chrome.app.*)
        "com.google.chrome.for.testing", // Chrome for Testing; also covered by the prefix above. Not in the cask data: UNCONFIRMED locally
        "org.chromium.*",                // Chromium, ungoogled-chromium: org.chromium.Chromium; Thorium: org.chromium.Thorium (cask)
        "com.microsoft.edgemac*",        // Edge, .Beta, .Dev, .Canary (cask); Edge web apps com.microsoft.edgemac.app.* UNCONFIRMED
        "com.brave.Browser*",            // Brave, .beta, .nightly, .origin* (cask); Brave web apps UNCONFIRMED
        "com.operasoftware.*",           // Opera, OperaGX, OperaNext (beta), OperaDeveloper, OperaAir (cask)
        "com.vivaldi.*",                 // Vivaldi, Vivaldi.snapshot (cask)
        "company.thebrowser.*",          // Arc: company.thebrowser.Browser; Dia: company.thebrowser.dia (cask)
        "ru.yandex.desktop.yandex-browser*", // Yandex Browser (cask)
        "com.naver.Whale*",              // Naver Whale (cask)
        "com.hiddenreflex.Epic*",        // Epic (cask)
        "de.iridiumbrowser*",            // Iridium (cask)
        "ai.perplexity.comet*",          // Comet (cask)
        "com.openai.atlas*",             // ChatGPT Atlas and its web helper (cask)
        "net.imput.helium*",             // Helium (cask)
        "com.pushplaylabs.sidekick*",    // Sidekick (cask)
        "io.wavebox.wavebox*",           // Wavebox (cask quit)
        "com.bookry.wavebox*",           // Wavebox, older identifier (cask)
        "com.ghostbrowser.*",            // Ghost Browser (cask)
        "com.sigmaos.sigmaos.macos*",    // SigmaOS (cask)
        "org.blisk.Blisk*",              // Blisk (cask)
        "com.avast.AvastSecureBrowser*", // Avast Secure Browser (cask)
        "com.avast.browser*",            // Avast Secure Browser, older identifier (cask)
        "com.alohabrowser.*",            // Aloha (cask)
        "com.browseros.*",               // BrowserOS (cask)
        "com.primeum.Browser*",          // Ulaa (cask quit)
        "com.zoho.ulaa*",                // Ulaa, older identifier (cask)
        "at.studio.AsideBrowser*",       // Aside (cask quit)
        "io.browsewithnook.*",           // Nook (cask)
        "com.webcatalog.singlebox*",     // Singlebox (cask)
        "com.electron.min*",             // Min (cask saved-state name)
        // WebKit family
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview", // (cask quit)
        "com.apple.Safari.WebApp.*",     // Safari web apps added to the Dock UNCONFIRMED
        "com.kagi.kagimacOS*",           // Orion (cask quit); Orion RC under the same prefix UNCONFIRMED
        "com.duckduckgo.macos.browser*", // DuckDuckGo (cask)
        "de.icab.iCab*",                 // iCab (cask)
        // Gecko family
        "org.mozilla.*",                 // Firefox, firefoxdeveloperedition, nightly (cask); older Tor, LibreWolf, Zen and Glide IDs. Also matches Thunderbird, which is then skipped too.
        "org.torproject.*",              // Tor Browser: org.torproject.torbrowser (cask)
        "app.zen-browser.*",             // Zen, Zen Twilight: app.zen-browser.zen (cask quit)
        "io.gitlab.librewolf-community*",// LibreWolf (cask)
        "net.librewolf.*",               // LibreWolf, newer identifier (cask)
        "net.waterfox.*",                // Waterfox (cask quit)
        "org.waterfoxproject.*",         // Waterfox, Waterfox Classic (cask)
        "net.mullvad.mullvadbrowser*",   // Mullvad Browser (cask quit)
        "one.ablaze.floorp*",            // Floorp (cask records only "*.floorp") UNCONFIRMED
        "app.glide-browser.*",           // Glide (cask)
        // Other
        "org.safeexambrowser.*",         // Safe Exam Browser (cask quit)
        // Less common browsers and multi-service web wrappers (review C11).
        // No local cask record for any of these: all UNCONFIRMED.
        "com.coccoc.*",                  // Coc Coc UNCONFIRMED
        "org.qutebrowser.*",             // qutebrowser UNCONFIRMED
        "com.maxthon.*",                 // Maxthon UNCONFIRMED
        "org.ferdium.*",                 // Ferdium (web-app wrapper) UNCONFIRMED
        "com.meetfranz.*",               // Franz (web-app wrapper) UNCONFIRMED
        "com.grupovrs.ramboxce*",        // Rambox CE (web-app wrapper) UNCONFIRMED
        "com.rambox.*",                  // Rambox (web-app wrapper) UNCONFIRMED
        "org.efounders.BrowserX*",       // BrowserX UNCONFIRMED
    ]

    public static let list = BrowserBundleList(patterns)

    public static func contains(_ bundleIdentifier: String) -> Bool { list.contains(bundleIdentifier) }
}
