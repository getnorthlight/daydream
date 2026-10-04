import Foundation
import MemoryCore
import PrivacyPolicy
import Security

/// typing-all apps track (typesafe SPEC 12.2 item 4): capture expansion per
/// category. The owner set, the release gate for every row, the signers read
/// on this Mac, and the per-app signing requirement checked by the Security
/// framework against this check's own (ad hoc, linker-signed) process: a
/// process with the right bundle ID and the wrong signer is refused.
/// The full-typing build's set (every release stage since 2026-09-25): every row with a proof, a
/// confirmed bundle ID and a signer read on a Mac. `scripts/typing-release-gate-checks.py` (OWNER_SET)
/// and the README's Typed text table name the same apps.
let typingOwnerSet: Set<String> = ["com.apple.Notes", "com.apple.TextEdit", "com.apple.Pages", "com.apple.Spotlight", "com.anthropic.claudefordesktop",
                                   "com.openai.codex", "com.openai.chat", "com.apple.Terminal", "com.mitchellh.ghostty", "com.apple.dt.Xcode", "com.apple.MobileSMS", "com.apple.mail",
                                   // fix/signers: read on the owner's laptop (2026-09-28).
                                   "net.whatsapp.WhatsApp", "md.obsidian", "com.todesktop.230313mzl4w4u92"]

func runTypingAppsChecks() throws {
    let buildFour: Set<String> = ["com.apple.Notes", "com.apple.TextEdit"]
    let all: (TypingCategory) -> Bool = { _ in true }
    let ownerSet = typingOwnerSet
    let owner = TypingCategories.captureApps(expanded: true, probeBuild: true)
    // The build these checks run in: the full-typing build every release stage makes, or a narrow local build.
    let shipped = OwnerTyping.enabled
    let built: Set<String> = shipped ? ownerSet : buildFour

    // MARK: Release gate, every category and app
    try check(CaptureGate.nativeApps == built && TypingCategories.allowedBundles(on: all) == built,
              shipped ? "apps: full-typing build: typing is read in exactly the owner set" : "apps: public build: typing is read in Notes and TextEdit only")
    try check(CaptureGate.webContentApps == (shipped ? owner.webContent : []) && CaptureGate.keyPanelApps == (shipped ? ["com.apple.Spotlight"] : []),
              "apps: this build's web-content and launcher-panel allowlists")
    try check(PreCapturePrivacy.supportedTypingApps == CaptureGate.nativeApps, "apps: pre-capture typing apps are the capture gate's apps")
    try check(owner.all == ownerSet, "apps: owner build: the allowed set is exactly the rows with a proof and a confirmed signer (\(ownerSet.count) apps)")
    try check(ownerSet == Set(TypingCategories.apps.filter { $0.support.hasAppProof && $0.bundleConfirmed && $0.signer != .unconfirmed }.map(\.bundle)),
              "apps: the owner set equals the table rows with a confirmed signer")
    try check(owner.all.isStrictSuperset(of: buildFour), "apps: the owner set is larger than Notes and TextEdit")
    try check(owner.webContent == ["com.anthropic.claudefordesktop", "com.openai.codex", "com.apple.mail", "md.obsidian", "com.todesktop.230313mzl4w4u92"],
              "apps: owner build: Claude, ChatGPT, Mail, Obsidian and Cursor are read through the web-content proof")
    try check(TypingCategories.captureApps(expanded: true, probeBuild: false).all == buildFour,
              "apps: the lawyer's flip alone opens only device-probed rows (still Notes and TextEdit); the device test moves rows to native")
    try check(TypingCategories.captureApps(expanded: false, probeBuild: true).all == buildFour, "apps: the device-test switch alone opens nothing")
    for category in TypingCategory.allCases {
        for app in TypingCategories.apps(in: category) {
            try check(TypingCategories.permits(bundle: app.bundle, on: all) == built.contains(app.bundle),
                      "apps: \(shipped ? "full-typing" : "public") build: \(app.name) (\(category.title)) \(built.contains(app.bundle) ? "is" : "is not") allowed")
            try check(!TypingCategories.permits(bundle: app.bundle, on: { $0 != category }, expanded: true, probeBuild: true),
                      "apps: \(app.name) is off whenever \(category.title) is off")
        }
    }
    // Defaults once typing is on: every category on, Code and Messages and email too (fix/typing-e2e L1).
    let defaults = TypedCategoryChoices()
    let ownerDefaults = TypingCategories.allowedBundles(on: defaults.isOn, expanded: true, probeBuild: true)
    try check(ownerDefaults == ownerSet,
              "apps: owner build, default choices: every allowed app, Messages and Mail included")
    try check(["com.apple.Terminal", "com.mitchellh.ghostty", "com.apple.dt.Xcode"].allSatisfy(ownerDefaults.contains), "apps: Code apps are on by default")
    try check(!TypingCategories.excludedBundles(on: defaults.isOn, expanded: true, probeBuild: true).contains("com.apple.MobileSMS")
              && !TypingCategories.excludedBundles(on: defaults.isOn, expanded: true, probeBuild: true).contains("com.apple.mail")
              && TypingCategories.excludedBundles(on: { $0 != .messagesAndEmail }, expanded: true, probeBuild: true).isSuperset(of: ["com.apple.MobileSMS", "com.apple.mail"]),
              "apps: Messages and Mail are not excluded by default, and join the excluded apps when Messages and email is off")
    // Terminals: the latch rule stays in front of them.
    try check(TypingCategories.apps.filter(\.promptLatch).allSatisfy { !owner.all.contains($0.bundle) || TerminalPromptLatch.wired },
              "apps: a terminal is allowed only while the prompt latch is wired")
    let latchApps = TypingCategories.apps.filter(\.promptLatch)
    try check(latchApps.contains { $0.bundle == "com.apple.Terminal" } && latchApps.contains { $0.bundle == "com.mitchellh.ghostty" }
              && latchApps.allSatisfy { !TypingCategories.releaseAllows($0, expanded: true, probeBuild: true, latchWired: false) },
              "apps: owner build: Terminal, Ghostty and every other latch app are refused when the prompt latch is not wired")
    try check(["com.apple.Terminal", "com.mitchellh.ghostty"].allSatisfy { b in
                  TypingCategories.releaseAllows(TypingCategories.app(b)!, expanded: true, probeBuild: true, latchWired: true) },
              "apps: owner build: Terminal and Ghostty are allowed once the latch is wired")

    // MARK: Signers read on this Mac
    try check(TypingCategories.app("com.apple.Pages")?.signer == .appStore && TypingCategories.app("com.apple.Pages")?.bundleConfirmed == true,
              "apps: Pages is the Mac App Store app com.apple.Pages (read on this Mac)")
    try check(TypingCategories.signingRequirement(TypingCategories.app("com.apple.Pages")!) ==
              "anchor apple generic and identifier \"com.apple.Pages\" and certificate leaf[field.1.2.840.113635.100.6.1.9] exists",
              "apps: an App Store app needs the store's mark and its identifier")
    try check(TypingCategories.awaitingSigner.map(\.bundle).contains("com.tinyspeck.slackmacgap") && !TypingCategories.awaitingSigner.contains { ownerSet.contains($0.bundle) },
              "apps: the rows still waiting for a signer are listed, and none of them is allowed")
    for app in TypingCategories.apps {
        guard let text = TypingCategories.signingRequirement(app) else { continue }
        var requirement: SecRequirement?
        try check(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess && requirement != nil,
                  "apps: \(app.name) (\(app.bundle)): its signing requirement compiles")
        try check(text.contains("identifier \"\(app.bundle)\"") && (text.hasPrefix("anchor apple and") || text.contains("leaf[subject.OU]") || text.contains("1.2.840.113635.100.6.1.9")),
                  "apps: \(app.name) (\(app.bundle)): its requirement names its identifier and its signer")
    }

    // MARK: A spoofed bundle ID with the wrong signer is refused
    // This check's own process stands in for a copy that claims a table
    // app's bundle ID: its identifier matches, its signer does not.
    let own = try ownSigningIdentifier()
    try check(processSatisfies("identifier \"\(own)\""), "apps: signing: this process satisfies a bundle-ID-only requirement (what a copy could fake)")
    for signer in [TypingSigner.apple, .appStore, .team("Q6L2SF6YDW"), .team("2DC432GLL2"), .team("24VZTF6M5V"),
                   .team("57T9237FN3"), .team("6JSW4SJWN9"), .team("VDXQ22DGB9")] {
        let spoof = TypingApp(own, "Spoof", .code, signer, .native)
        try check(!processSatisfies(TypingCategories.signingRequirement(spoof)!), "apps: signing: the same bundle ID with the wrong signer (\(signer)) is refused")
    }
    try check(TypingCategories.signingRequirement(TypingApp(own, "Spoof", .code, .unconfirmed, .native)) == nil, "apps: signing: no signer read means no requirement, so no typing")
}

/// The identifier this check's own code signature carries (linker-signed).
private func ownSigningIdentifier() throws -> String {
    var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code, SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any], let id = dict[kSecCodeInfoIdentifier as String] as? String, !id.isEmpty
    else { throw MemError.invalid("FAILED: apps: this check's own signing identifier could not be read") }
    return id
}

/// The same Security calls `AccessibilityReader.trustedNativeProcess` makes,
/// for this process's PID.
private func processSatisfies(_ text: String) -> Bool {
    var code: SecCode?, requirement: SecRequirement?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: getpid()] as CFDictionary, [], &code) == errSecSuccess, let code,
          SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
}
