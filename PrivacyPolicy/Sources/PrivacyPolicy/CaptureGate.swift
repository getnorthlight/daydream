import Foundation

public enum PrivacyOutcome: String, Sendable { case allowed, blocked, unknown }
public enum PrivacyReason: String, Sendable {
    case permitted, typingOff, excludedApp, excludedSite, passwordManager, secureInput, privateContext, highRiskPage, unknownFocus, staleProof, generationChanged, unknownApp, browserTypingOff, browserStateUnknown, sensitiveField, malformedMetadata, sensitiveURL, compositionPending, oversizedBurst, credentialPattern, privateKey, paymentIdentifier, identityIdentifier, sensitiveContext, ambiguousNumeric, suspiciousOpaque, classifierDeny, invalidated, departureDenied, unconfirmedFocus, terminalPrompt
}
public struct PrivacyDecision: Sendable, Equatable {
    public let outcome: PrivacyOutcome
    public let reason: PrivacyReason
    public let generation: UInt64
    public let policyVersion: UInt64
    public let classifierVersion = "sensitive-typing/v2"
}
public enum AppSurface: Sendable { case native, browser, embeddedWeb, unknown }
public enum VerifiedFlag: Sendable { case yes, no, unknown }
public struct CapturePolicy: Sendable {
    public var typedText=false
    public var version: UInt64=1
    public var excludedApps: Set<String>=[]
    public var excludedDomains: Set<String>=[]
    public init() {}
}
/// Trusted adapter metadata, never candidate text. Page attributes can add denies
/// only. Fields/identities must be corroborated by the native/extension bridge.
public struct FocusProof: Sendable {
    public var generation:UInt64=0, policyVersion:UInt64=0, checkedAt:UInt64=0
    public var bundle="", windowID="", focusID="", role="", subrole=""
    public var surface:AppSurface = .unknown
    public var secureInput:VerifiedFlag = .unknown, privateMode:VerifiedFlag = .unknown
    public var verified=false, fieldStateVerified=false, frameAccessible=false, navigationStable=false
    public var tabID="", documentID="", frameID=""
    public var url="", fieldType="", autocomplete="", fieldLabel=""
    /// The field's deny-only label (placeholder, description, DOM id and classes), read in full before `fieldLabel` was
    /// clipped for storage, named a sensitive or terminal field (gold/int S2: a word past the clip still refuses).
    public var fieldLabelDenied=false
    public var highRiskPage=false
    /// The window title the capture layer read with this proof ("Untitled 3",
    /// "Terminal — zsh"). Metadata, never field content: not part of the field
    /// identity or the gate except Messages' validated body recipient boundary.
    /// A typed row keeps it as its place label after the
    /// store's title rules and secret scrubber; terminals arm
    /// `TerminalPromptLatch` from it. "" when not read.
    public var place=""
    /// summaries/v3 (spec §2-§4): the field's class (`SendRules.fieldClass`) and a chat composer's channel or person
    /// (`SendRules.composerPlace`), derived from labels the join already reads. Not part of the field's identity or the
    /// gate; stored only as a typed unit's send facts. "" when unknown.
    public var sendField="", sendPlace=""
    /// messages-1003: a native field's own labels (description, placeholder, help, identifier; never its value or
    /// title), read only where the build classifies fields by them (Messages: `SendRules.messagesField`). Not part of
    /// the field's identity or the gate. Empty when not read.
    public var nativeLabels:[String]=[]
    public init() {}
}
public enum CaptureGate {
    public static let ttlNanoseconds:UInt64=1_000_000_000
    /// The build's typing allowlist: the category table's allowed apps with
    /// every category on (typing-all SPEC-LATER 4.1). Public builds: exactly
    /// Notes and TextEdit (the legal gate). The person's category choices are
    /// applied per context, as excluded apps.
    public static let nativeApps:Set<String>=TypingCategories.allowedBundles(on:{_ in true},expanded:TypingRelease.open)
    /// Of those, the apps read through the "vendor app with web content"
    /// proof, and the launcher panels (Spotlight). Empty in public builds.
    /// Fail-closed: app web content is read only where the web terminal refusal (`webTerminalWords`) is
    /// compiled in, so opening the table any other way can't read a terminal in an app's page.
    public static let webContentApps:Set<String>=webTerminalWords.isEmpty ? [] : TypingCategories.captureApps().webContent
    public static let keyPanelApps:Set<String>=TypingCategories.captureApps().keyPanels
    public static let passwordManagers:Set<String>=["com.apple.Passwords","com.apple.keychainaccess","com.1password.1password","com.agilebits.onepassword7","com.bitwarden.desktop","com.lastpass.LastPass","com.dashlane.Dashlane"]
    /// Copy of `HistoryCore.KnownBrowsers.patterns`, which this package cannot
    /// import. Keep the two identical, entry for entry; `Checks/CaptureChecks.swift`
    /// fails when they or their matching differ. An entry ending in `*` is a
    /// case-insensitive prefix; any other entry is a case-insensitive exact match.
    public static let browserPatterns:[String]=[
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
    private static let browserNormalized:[String]=browserPatterns.map{$0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()}
    private static let browserExact:Set<String>=Set(browserNormalized.filter{!$0.hasSuffix("*") && !$0.isEmpty})
    private static let browserPrefixes:[String]=browserNormalized.filter{$0.hasSuffix("*")}.map{String($0.dropLast())}.filter{!$0.isEmpty}
    /// Every browser, channel and web app on the shared list, by prefix.
    public static func isBrowser(_ bundle:String)->Bool {
        let id=bundle.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        return !id.isEmpty && (browserExact.contains(id) || browserPrefixes.contains{id.hasPrefix($0)})
    }
    public static let sensitiveDomains:Set<String>=["1password.com","bitwarden.com","passwords.google.com","chase.com","bankofamerica.com","wellsfargo.com","citi.com","fidelity.com","schwab.com","paypal.com","venmo.com"]
    static func result(_ outcome:PrivacyOutcome,_ reason:PrivacyReason,_ proof:FocusProof) -> PrivacyDecision {
        PrivacyDecision(outcome:outcome,reason:reason,generation:proof.generation,policyVersion:proof.policyVersion)
    }
    static func common(_ p:FocusProof,policy:CapturePolicy,generation:UInt64,now:UInt64) -> PrivacyDecision? {
        if policy.excludedApps.contains(p.bundle) {return result(.blocked,.excludedApp,p)}
        if passwordManagers.contains(p.bundle) {return result(.blocked,.passwordManager,p)}
        if p.secureInput == .yes {return result(.blocked,.secureInput,p)}
        if p.privateMode == .yes {return result(.blocked,.privateContext,p)}
        if p.highRiskPage {return result(.blocked,.highRiskPage,p)}
        guard p.generation == generation, p.policyVersion == policy.version else {return result(.unknown,.generationChanged,p)}
        guard now >= p.checkedAt, now-p.checkedAt <= ttlNanoseconds else {return result(.unknown,.staleProof,p)}
        guard p.verified, !p.windowID.isEmpty, !p.focusID.isEmpty, p.secureInput == .no, p.privateMode == .no else {return result(.unknown,.unknownFocus,p)}
        guard [p.bundle,p.windowID,p.focusID,p.role,p.subrole,p.tabID,p.documentID,p.frameID,p.fieldType,p.autocomplete,p.fieldLabel].allSatisfy({$0.utf8.count<=256}),p.url.utf8.count<=2048 else {return result(.unknown,.malformedMetadata,p)}
        if !p.url.isEmpty {
            guard let u=URLComponents(string:p.url),let host=u.host?.lowercased(),!host.isEmpty,["https","http"].contains(u.scheme?.lowercased() ?? ""),u.user==nil,u.password==nil else {return result(.blocked,.sensitiveURL,p)}
            let canonicalHost=host.trimmingCharacters(in:CharacterSet(charactersIn:"."))
            if policy.excludedDomains.union(sensitiveDomains).contains(where:{
                let domain=$0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"."))
                return !domain.isEmpty && (canonicalHost == domain || canonicalHost.hasSuffix("."+domain))
            }) {return result(.blocked,.excludedSite,p)}
            // URL query/fragment are never activity content. Reject rather than
            // preserve supposedly harmless search parameters containing secrets.
            if u.query != nil || u.fragment != nil {return result(.blocked,.sensitiveURL,p)}
            let path=(u.percentEncodedPath.removingPercentEncoding ?? u.path).lowercased()
            if ["login","signin","sign-in","oauth","password","checkout","payment","wallet","bank"].contains(where:(host+path).contains) {return result(.blocked,.highRiskPage,p)}
            if TextClassifier.sensitiveReason(host+" "+path) != nil {return result(.blocked,.sensitiveURL,p)}
        }
        return nil
    }
    public static func typing(_ p:FocusProof,policy:CapturePolicy,generation:UInt64,now:UInt64) -> PrivacyDecision {
        typing(p,policy:policy,generation:generation,now:now,apps:TypingCaptureApps(all:nativeApps,webContent:webContentApps,keyPanels:keyPanelApps))
    }
    /// The same gate for one build's allowlists (checks pass the owner build's).
    public static func typing(_ p:FocusProof,policy:CapturePolicy,generation:UInt64,now:UInt64,apps:TypingCaptureApps) -> PrivacyDecision {
        if let denied=common(p,policy:policy,generation:generation,now:now) {return denied}
        guard policy.typedText else {return result(.blocked,.typingOff,p)}
        if sensitiveField(p) {return result(.blocked,.sensitiveField,p)}
        if p.surface == .browser || isBrowser(p.bundle) {return result(.blocked,.browserTypingOff,p)}
        // Web content only in an app this build reads through the web-content proof.
        if p.surface == .embeddedWeb {
            guard apps.webContent.contains(p.bundle) else {return result(.blocked,.browserTypingOff,p)}
        } else {
            guard p.surface == .native else {return result(.unknown,.unknownApp,p)}
        }
        guard apps.all.contains(p.bundle) else {return result(.unknown,.unknownApp,p)}
        // Mail's editable message body is a web area itself; elsewhere only text fields.
        let bodyEditor=p.surface == .embeddedWeb && TypingCategories.app(p.bundle)?.web?.webAreaEditor == true
        guard p.url.isEmpty,p.fieldStateVerified,p.frameAccessible,p.navigationStable,
              ["AXTextField","AXTextArea"].contains(p.role) || (bodyEditor && p.role == "AXWebArea") else {return result(.unknown,.unknownFocus,p)}
        return result(.allowed,.permitted,p)
    }
    public static func metadata(_ p:FocusProof,policy:CapturePolicy,generation:UInt64,now:UInt64) -> PrivacyDecision {
        if let denied=common(p,policy:policy,generation:generation,now:now) {return denied}
        if sensitiveField(p) {return result(.blocked,.sensitiveField,p)}
        if p.surface == .browser || isBrowser(p.bundle) {
            guard p.bundle == "com.google.Chrome",p.navigationStable,p.frameAccessible,!p.tabID.isEmpty,!p.documentID.isEmpty,!p.frameID.isEmpty,
                  ["AXButton","AXLink","AXStaticText","AXCheckBox","AXRadioButton","AXMenuItem"].contains(p.role) else {return result(.unknown,.browserStateUnknown,p)}
        } else if p.surface != .native {return result(.unknown,.unknownApp,p)}
        return result(.allowed,.permitted,p)
    }
    static func sensitiveField(_ p:FocusProof) -> Bool {
        let tokens=p.autocomplete.lowercased().split(whereSeparator:{$0.isWhitespace})
        return p.fieldLabelDenied || p.subrole == "AXSecureTextField" || p.fieldType.lowercased() == "password" || tokens.contains(where:{$0 == "current-password" || $0 == "new-password" || $0 == "one-time-code" || $0.hasPrefix("cc-")}) || TextClassifier.sensitiveLabel(p.fieldLabel)
            || p.surface == .embeddedWeb && webTerminalField(p.fieldLabel)
    }
    /// A terminal or code editor inside an app's web content: an xterm.js terminal (ChatGPT's
    /// integrated terminal: aria-label "Terminal input", class `xterm-helper-textarea`) or a Monaco
    /// editor. Refused and discarded like the Chrome join's web terminals (`BrowserTypingFieldRules`
    /// denies these words too, but judges "editor content" in labels only, never in the DOM id or class
    /// list, where Draft.js names every editor; this gate is stricter): its input is an ordinary editable
    /// text area, and the terminal prompt
    /// latch covers only native terminals, so a password typed at a prompt there would otherwise be
    /// kept. The label is the placeholder, description, DOM id and class list. The words live with the
    /// owner switch: only the full-typing build (every release) reads app web content at all.
    public static var webTerminalWords:[String] {OwnerTyping.webTerminalWords}
    /// gold/int S2: the deny-only label, judged in full (every component, before anything is clipped for storage):
    /// a sensitive word anywhere, or in app web content a terminal or code editor, refuses the field.
    public static func deniesFieldLabel(_ label:String,embeddedWeb:Bool) -> Bool {
        TextClassifier.sensitiveLabel(label) || embeddedWeb && webTerminalField(label)
    }
    static func webTerminalField(_ label:String) -> Bool {
        let s=TextClassifier.normalized(label).lowercased()
        return webTerminalWords.contains(where:s.contains)
    }
    /// Gate refusals that are privacy boundaries: everything pending is
    /// discarded, never committed. Any other refusal (unknown or stale focus,
    /// unsupported app) only ends the typed unit, which is then judged by
    /// where focus went.
    public static let typingDenyReasons:Set<PrivacyReason>=[.secureInput,.sensitiveField,.passwordManager,.excludedApp,.excludedSite,.typingOff,.privateContext,.highRiskPage,.sensitiveURL]
}

/// Where focus went when a typed unit is resolved without a fresh typing proof
/// for a permitted field. Metadata only: the OS secure-input state, the
/// frontmost bundle and the focused element's role/subrole. Never a value,
/// title or selection.
public struct DepartureState: Sendable, Equatable {
    public var secureInput:VerifiedFlag = .unknown
    public var bundle=""
    /// .yes when the focused role or subrole names a secure field, .no when
    /// both were read and neither does, .unknown when not read (browsers are
    /// never AX-read) or unreadable.
    public var focusSecure:VerifiedFlag = .unknown
    public init() {}
    public init(secureInput:VerifiedFlag,bundle:String,focusSecure:VerifiedFlag) {
        self.secureInput=secureInput;self.bundle=bundle;self.focusSecure=focusSecure
    }
}
extension CaptureGate {
    /// A unit whose field was left may be committed only if focus did not go
    /// to a secure context. Inside the same app the new focus must be
    /// positively non-secure (a username field followed by a password field
    /// in one window is discarded when the second cannot be read).
    public static func departureAllows(_ d:DepartureState,from p:FocusProof) -> Bool {
        guard d.secureInput == .no,!d.bundle.isEmpty,!passwordManagers.contains(d.bundle),d.focusSecure != .yes else {return false}
        return d.bundle != p.bundle || d.focusSecure == .no
    }
}
