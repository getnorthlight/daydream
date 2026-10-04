import SwiftUI
import AppKit
import MemoryCore
import PrivacyPolicy

// Safe typing, the screens (typesafe SPEC 9.2 with the owner decisions in typeall SPEC-LATER):
// the "Remember what you type" screen (onboarding and Settings), the Typing card in
// Settings ▸ Apps to remember, and the typing rows at the top of the menu bar card.
// Values only: the host (MacMemApp's `TypingModel`) passes what is saved and gets the
// person's choices back through closures. Nothing here reads the store, the Keychain
// or the system.
//
// Owner decisions reflected here:
// - 4: no "Let <App> see the exact words you typed" row; AI apps get the short note only.
// - 8 (reversed 2026-09-27): summaries read typed words, on this Mac or, with Cloud chosen, through the
//      summary service. writer/v2 removed the old summaries-read picker; one consent
//      bullet says it (summaries/v3, spec §13), nothing on the card.
// - 3: the "Other websites" checkbox exists in every release (DAYDREAM_OWNER_TYPING, which
//      developer-id-release.py stage always passes); only unflagged local builds leave it out.
// The app lists under each category come from the release gate of the running build, so a
// narrow build lists only Notes and TextEdit. The full-typing build (the one every release
// stage makes) also names the websites in Google Chrome each category covers.

/// Every typing string, fixed here so the checks read what the views draw.
public enum TypingSettingsText {
    public static let title = "Remember what you type"
    /// "Not each key" is folded in here; the Off state is said by the switch and the Turn on button.
    public static let body = "DayDream can save what you finish typing (not each key), so notes can say what you asked or sent."
    /// The four facts under Details before "Turn on typing" (after where it works, `introBullets`). The 7-day deletion
    /// and "AI apps see only the note" stay there, before consent (owner decision 4): Limits and the Keep picker appear
    /// only after typing is on. "Looks like" keeps the password line
    /// true: ordinary passwords in normal boxes can't always be recognized (Limits).
    public static let bullets = [
        "Encrypted on this Mac with a key in your Keychain.",
        "Skips password fields, private browser windows, and text that looks like a password, card number or code.",
        "Deletes the exact words after 7 days and keeps a short note.",
        // fix/sx-all round 3: AI apps read summaries too, and a summary can say what a message was about; "Cloud" was
        // never the switch's name.
        "AI apps see a short note and your summaries, never the saved words.",
        "Summaries read the words, so a note can say what a message was about. With an OpenRouter key, they're sent to OpenRouter to write your notes.",
        "Anyone typing on this Mac account is recorded as you.",
    ]
    public static let turnOn = "Turn on typing"
    public static let notNow = "Not now"
    /// The short warning shown before "Turn on typing" (sat5: the owner wanted a short warning, not a page of it): what it
    /// saves, what it skips, where the words are and when they go. Where exactly it records (`consentWhere`), what AI
    /// apps see and the Mac-account line are one click away under `detailsTitle` (setup's sheet). "Password fields",
    /// never "passwords": an ordinary password in a normal box can be missed (Limits, typed-claim-checks).
    public static func short(websites: Bool = TypingSettingsText.websiteTyping) -> String {
        websites ? "Saves what you type in apps and on websites in Chrome, except password fields and private windows. Encrypted on this Mac; the words are deleted after 7 days."
            : "Saves what you type in \(allowedAppsPhrase()), except password fields. Encrypted on this Mac; the words are deleted after 7 days."
    }
    /// Setup's one line under the typing switch (opt-out, owner 9/27): what it saves, what it skips, where the words go.
    public static func setupLine(websites: Bool = TypingSettingsText.websiteTyping) -> String {
        websites ? "Saves what you type in apps and on websites in Chrome, except password fields and private windows. Encrypted on this Mac, deleted after 7 days; your summaries read it."
            : "Saves what you type in \(allowedAppsPhrase()), except password fields. Encrypted on this Mac, deleted after 7 days; your summaries read it."
    }
    /// Settings: the switch turns typing on at once (owner 9/28: no second question). Before it is on, the card shows
    /// setup's one line (`setupLine`) and Learn more holds the rest (`consentWhere`, then `introBullets`).
    public static let learnMore = "Learn more"
    public static let showLess = "Show less"
    /// Says what went wrong in plain words (the owner's rule for errors), beside its one fix, Try again.
    public static let keyError = "DayDream couldn't create its typing key in your Keychain, so typing stays off."
    public static let tryAgain = "Try again"
    public static let locked = "Typing is paused until you unlock your Mac."
    public static let keyLost = "DayDream couldn't find its typing key, so the exact words you typed before are gone. Summaries are kept."
    public static let switchLabel = "Remember what you type"
    public static let footer = TypingCategories.footer
    public static let keepTitle = "Keep exact words"
    public static let keepHelp = "After this, DayDream deletes the exact words and keeps a short note."
    public static let delete = "Delete"
    public static let cancel = "Cancel"
    public static let forget = "Forget what I typed…"
    /// Forget also turns the typing switch off (the host saves it), so nothing is left half on.
    public static let forgetConfirmation = "Delete everything DayDream saved from your typing, including summaries, and turn typing off? This can't be undone."
    public static let pause = TypingPauseShortcut.settingsTitle
    public static let resume = TypingPauseShortcut.resumeTitle
    public static let shortcutTitle = "Pause shortcut"
    public static let shortcutTaken = TypingPauseShortcut.taken
    public static let shortcutFailed = "macOS didn't accept this shortcut. Pick another."
    public static let limitsTitle = "Limits"
    /// The disclosure's title while it also holds the pause shortcut.
    public static let moreTitle = "Shortcut and limits"
    public static let notSaved = "Not saved. Try again."
    public static let unavailable = "Typing settings are unavailable in this build."

    /// "Other websites" (owner decision 3). Every release stage compiles it in (developer-id-release.py
    /// OWNER_SWIFT_FLAGS); only an unflagged local build (plain swift build, package.sh without
    /// DAYDREAM_OWNER_TYPING=1) leaves it out.
    #if DAYDREAM_OWNER_TYPING
    public static let otherWebsites: (title: String, help: String)? =
        ("Other websites", "Websites not listed above, except blocked sites. Never in Incognito or Guest windows. Needs Web pages in Chrome. Message boxes, webmail, and every page of social and messaging sites like Facebook, LinkedIn and X also need Messages and email.")
    #else
    public static let otherWebsites: (title: String, help: String)? = nil
    #endif
    public static var ownerBuild: Bool { OwnerTyping.enabled }
    /// Whether this build types on websites: the full-typing build, with Chrome page history in the
    /// release (website typing needs Web pages in Chrome, which `ReleaseFeatures` can leave out).
    public static var websiteTyping: Bool { ownerBuild && ReleaseFeatures.chromePageHistory }

    /// Where typing works in this build, first on the setup screen (owner/v1 review F2 and F4): the
    /// apps, and in owner builds websites in Google Chrome. "Turn on typing" accepts exactly these
    /// places; a later build that records typing in more places asks again.
    public static func scope(expanded: Bool = TypingRelease.open, captureAllowlist: Set<String> = CaptureGate.nativeApps,
                             websites: String? = DaydreamAppsContent.websiteTypingBullet) -> [String] {
        ["Works in \(allowedAppsPhrase(expanded: expanded, captureAllowlist: captureAllowlist))."] + (websites.map { [$0] } ?? [])
    }
    /// Every bullet the setup screen shows: where typing works, then the six.
    public static var introBullets: [String] { scope() + bullets }
    /// Above the setup screen when typing was turned on for fewer places than this build records. Settings no longer
    /// draws it (fix/typing-e2e): its switch turns typing on for this build's places in one click.
    public static let scopeWidened = "This version can record typing in more places than you turned it on for, so typing is off. Read where it works, then turn it on again."

    /// The key place line, or nil while the key's place isn't known. Input methods are refused in
    /// apps and on websites alike (review G71: website typing needs the US, ABC or British layout too,
    /// `WebTypingRoute.join`). A build that records terminals says the prompt latch can miss a password
    /// prompt, and how long the ssh rule lasts (`remoteLimit`).
    public static func limits(keyPlace: TypedKeyPlace?, terminals: Bool = TypingSettingsText.recordsTerminals()) -> [String] {
        [TypedLimitsText.inputMethods, TypedLimitsText.ordinaryPasswords] + (terminals ? [TypingCategories.terminalLimit, TypingCategories.remoteLimit] : [])
            + [TypedLimitsText.incognito, TypedLimitsText.backups,
               TypedLimitsText.timeMachine] + (keyPlace.map { [TypedLimitsText.key($0)] } ?? [])
            + [TypedLimitsText.searchPages, TypedLimitsText.history]
    }
    /// Whether this build records typing in a terminal (an app that needs the prompt latch).
    public static func recordsTerminals(expanded: Bool = TypingRelease.open, captureAllowlist: Set<String> = CaptureGate.nativeApps) -> Bool {
        TypingCategories.apps.contains { $0.promptLatch && TypingCategories.releaseAllows($0, expanded: expanded) && captureAllowlist.contains($0.bundle) }
    }

    // MARK: App lists (what the running build can record)

    /// The apps in `category` this build can record typing in: the release gate
    /// (`TypingRelease.open`) and the capture allowlist, in table order.
    public static func allowedApps(_ category: TypingCategory, expanded: Bool = TypingRelease.open,
                                   captureAllowlist: Set<String> = CaptureGate.nativeApps) -> [String] {
        // fix/sx-all round 3: one name once ("ChatGPT" is two apps: the Electron one and the native one).
        var seen = Set<String>()
        return TypingCategories.apps(in: category)
            .filter { TypingCategories.releaseAllows($0, expanded: expanded) && captureAllowlist.contains($0.bundle) }
            .map(\.name).filter { seen.insert($0).inserted }
    }
    /// Every app this build can record typing in ("Notes and TextEdit" in public builds).
    public static func allowedAppsPhrase(expanded: Bool = TypingRelease.open, captureAllowlist: Set<String> = CaptureGate.nativeApps) -> String {
        list(TypingCategory.allCases.flatMap { allowedApps($0, expanded: expanded, captureAllowlist: captureAllowlist) })
    }
    /// "Notes", "Notes and TextEdit", "Notes, TextEdit and Pages".
    public static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    /// The help under a category checkbox. Lines that name apps name only apps this build records, once:
    /// Search and Writing name them in the help itself (declutter: "apps like Spotlight and Claude. Spotlight,
    /// Claude, ChatGPT." said them twice).
    public static func help(_ category: TypingCategory, expanded: Bool = TypingRelease.open,
                            captureAllowlist: Set<String> = CaptureGate.nativeApps) -> String {
        let names = allowedApps(category, expanded: expanded, captureAllowlist: captureAllowlist)
        switch category {
        case .searchAndAI:
            if names.isEmpty { return "Searches and questions you type in search boxes and AI apps." }
            return "Searches and questions in " + list(names) + "."
        case .writing:
            // Only the apps this build records: never a promise of more.
            guard !names.isEmpty else { return "Writing apps." }
            return list(names) + "."
        case .code, .messagesAndEmail:
            return category.help
        }
    }
    /// The supported apps under a category (Search and Writing name them in their help line instead), or nil.
    public static func appsLine(_ category: TypingCategory, expanded: Bool = TypingRelease.open,
                                captureAllowlist: Set<String> = CaptureGate.nativeApps) -> String? {
        guard category != .writing && category != .searchAndAI else { return nil }
        let names = allowedApps(category, expanded: expanded, captureAllowlist: captureAllowlist)
        return names.isEmpty ? nil : names.joined(separator: ", ") + "."
    }
    /// One line under a category checkbox: what it is, then its apps, then (full-typing build) its websites in Chrome.
    public static func line(_ category: TypingCategory, expanded: Bool = TypingRelease.open,
                            captureAllowlist: Set<String> = CaptureGate.nativeApps, websites: Bool = TypingSettingsText.websiteTyping) -> String {
        [help(category, expanded: expanded, captureAllowlist: captureAllowlist),
         appsLine(category, expanded: expanded, captureAllowlist: captureAllowlist),
         sitesLine(category, websites: websites)].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: Websites (the full-typing build)

    /// The websites in Google Chrome a category's checkbox also covers (`BrowserTypingSites.rule`:
    /// the host table in `TypingSites.swift` plus Chrome page history's common search, email and
    /// chat sites). nil where the build has no website typing (`websiteTyping` false) and for Code,
    /// which covers no website (web terminals are blocked sites).
    public static func sitesLine(_ category: TypingCategory, websites: Bool = TypingSettingsText.websiteTyping) -> String? {
        guard websites else { return nil }
        switch category {
        case .searchAndAI: return "Websites in Chrome: search engines and AI chats."
        case .writing: return "Websites in Chrome: Notion."
        case .code: return nil
        case .messagesAndEmail: return "Websites in Chrome: email and chat sites, and social sites with chat, like Facebook and LinkedIn."
        }
    }

    // MARK: Where typing records, in one line (setup)

    /// A few of the apps this build records typing in, one per kind ("Notes, Spotlight and Terminal").
    static func exampleApps(expanded: Bool = TypingRelease.open, captureAllowlist: Set<String> = CaptureGate.nativeApps) -> String {
        list([TypingCategory.writing, .searchAndAI, .code].compactMap { allowedApps($0, expanded: expanded, captureAllowlist: captureAllowlist).first })
    }
    /// The consent card's "where" line, drawn before "Turn on typing" in setup and in Settings: every app
    /// this build records typing in, and, in the full-typing build, every website in Chrome except blocked
    /// sites (Other websites is on by default), with what stays off. Built from the release gate, so it
    /// can't name more or fewer apps than the build records.
    public static func consentWhere(websites: Bool = TypingSettingsText.websiteTyping, expanded: Bool = TypingRelease.open,
                                    captureAllowlist: Set<String> = CaptureGate.nativeApps) -> String {
        // fix/typing-e2e: every category is on by default, Messages and email too (one click turns one off).
        let on = TypingCategory.allCases.filter(\.defaultOn).flatMap { allowedApps($0, expanded: expanded, captureAllowlist: captureAllowlist) }
        guard websites else { return "Records only in \(list(on))." }
        return "Records in \(list(on)), and, while Web pages in Chrome is on, on every website in Chrome except blocked sites."
    }
    /// Setup's name for the typing switch: it covers websites too in the full-typing build.
    public static func setupTitle(websites: Bool = TypingSettingsText.websiteTyping) -> String {
        websites ? "Typed text" : "Typed text in apps"
    }
    /// The switch's VoiceOver label.
    public static func setupLabel(websites: Bool = TypingSettingsText.websiteTyping) -> String {
        websites ? "Include typed text in apps and on websites in Chrome" : "Include typed text in \(allowedAppsPhrase())"
    }
    /// Where typed text is supported, for a sentence ("Optional typed text is supported in …").
    public static func supportedPlaces(websites: Bool = TypingSettingsText.websiteTyping) -> String {
        websites ? "apps like \(exampleApps()), and on every website in Chrome except blocked sites while Web pages in Chrome is on" : allowedAppsPhrase()
    }
}

// MARK: - Menu rows

/// The typing line under the menu bar panel's status and the typing item of its Pause submenu, as data (the
/// checks read what the panel draws).
public struct TypingMenuRows: Equatable {
    public enum Action: Equatable, Sendable { case pause, resume, openSettings }

    public let state: TypingIndicatorState
    /// The pause shortcut, only while it is registered ("⌃⌥⌘T").
    public let shortcut: String?
    public let timeZone: TimeZone
    public let locale: Locale

    public init(state: TypingIndicatorState, shortcut: String?, timeZone: TimeZone = .current, locale: Locale = .current) {
        self.state = state; self.shortcut = shortcut; self.timeZone = timeZone; self.locale = locale
    }

    /// Whether the panel shows the typing line at all (not while typing is off).
    public var shown: Bool { line != nil }
    /// "Recording what you type in Notes", "Not recording typing in this app",
    /// "Typing paused until 3:42 PM", "Typing is locked: turn it on in Settings".
    public var line: String? { state.menuTitle(timeZone: timeZone, locale: locale) }
    /// What a click on the line does: while typing is paused it resumes (the line ends in Resume, as the old panel's
    /// Record typing again did); a locked line opens Settings ▸ Apps to remember, where typing is turned on. nil: the
    /// line only says what happens.
    public var lineAction: Action? {
        switch state {
        case .snoozed: return .resume
        case .locked: return .openSettings
        case .off, .notHere, .recording: return nil
        }
    }
    /// The words at the end of a line that acts (nil: a chevron, or nothing when the line doesn't act).
    public var lineActionTitle: String? { lineAction == .resume ? Self.resumeTitle : nil }
    public static let resumeTitle = "Resume"
    /// What the line's action does, for VoiceOver.
    public var lineActionHint: String? {
        switch lineAction {
        case .resume?: return "Resumes recording what you type"
        case .openSettings?: return "Opens Apps to remember in DayDream Settings"
        case .pause?, nil: return nil
        }
    }
    /// The Pause submenu's typing item: "Pause Typing for 10 Minutes" with "⌃⌥⌘T" beside it while the shortcut is
    /// registered. nil while typing is off, locked or already paused (the paused line carries Resume).
    public var menuItem: (title: String, keys: String?, action: Action)? {
        switch state {
        case .recording, .notHere: return ("Pause Typing for \(TypingPauseShortcut.minutes) Minutes", shortcut, .pause)
        case .off, .locked, .snoozed: return nil
        }
    }
    public var symbol: String {
        switch state {
        case .recording: return "keyboard.fill"
        case .snoozed: return "pause.circle"
        case .locked: return "lock"
        case .off, .notHere: return "keyboard"
        }
    }
    public static func == (a: TypingMenuRows, b: TypingMenuRows) -> Bool {
        a.state == b.state && a.shortcut == b.shortcut && a.timeZone == b.timeZone && a.locale == b.locale
    }
}

/// What the typing line and the typing item run.
public struct TypingMenuActions {
    public var pause: () -> Void
    public var resume: () -> Void
    public var openSettings: () -> Void
    public init(pause: @escaping () -> Void = {}, resume: @escaping () -> Void = {}, openSettings: @escaping () -> Void = {}) {
        self.pause = pause; self.resume = resume; self.openSettings = openSettings
    }
    public func perform(_ action: TypingMenuRows.Action) {
        switch action {
        case .pause: pause()
        case .resume: resume()
        case .openSettings: openSettings()
        }
    }
}

// MARK: - Settings values

/// What the Typing card and the setup screen show.
public struct TypingSettingsValues: Equatable {
    public enum Phase: Equatable, Sendable {
        /// Not set up: the "Remember what you type" screen with "Turn on typing".
        case intro
        /// Set up, but the Keychain is locked.
        case locked
        /// Set up and the switch is off.
        case off
        /// Set up and on.
        case on
    }
    /// The pause shortcut row: the letters on offer, the one chosen, and a problem, if any.
    public struct Shortcut: Equatable {
        public var choices: [String]
        public var selected: Int
        /// nil while the chosen shortcut works.
        public var message: String?
        public init(choices: [String], selected: Int, message: String?) {
            self.choices = choices; self.selected = selected; self.message = message
        }
    }

    /// The typing switch (`captureText`).
    public var switchOn: Bool
    public var policy: TypedTextPolicy
    public var vault: TypedVaultState
    public var keyLost: Bool
    public var keyPlace: TypedKeyPlace?
    /// nil: no shortcut in this process (development trials).
    public var shortcut: Shortcut?
    public var setupFailed: Bool
    public var saveFailed: Bool
    /// False while settings can't be saved (preferences unavailable, development trial).
    public var enabled: Bool
    public var ownerBuild: Bool
    public var now: Date

    public init(switchOn: Bool, policy: TypedTextPolicy, vault: TypedVaultState, keyLost: Bool = false, keyPlace: TypedKeyPlace? = nil,
                shortcut: Shortcut? = nil, setupFailed: Bool = false, saveFailed: Bool = false, enabled: Bool = true,
                ownerBuild: Bool = TypingSettingsText.ownerBuild, now: Date = Date()) {
        self.switchOn = switchOn; self.policy = policy; self.vault = vault; self.keyLost = keyLost; self.keyPlace = keyPlace
        self.shortcut = shortcut; self.setupFailed = setupFailed; self.saveFailed = saveFailed; self.enabled = enabled
        self.ownerBuild = ownerBuild; self.now = now
    }

    /// Typing was accepted for fewer places than this build records: the setup screen asks again.
    public var scopeWidened: Bool { policy.scopeWidened }
    public var phase: Phase {
        // A Keychain that is locked keeps the locked card, with Try again, whenever typing was turned on,
        // also when this build records in more places: "Turn on typing" can't sign the settings until
        // the key is read (typingfix review), so the scope notice waits for the unlock.
        if policy.consentVersion >= TypedTextPolicy.currentConsentVersion && vault == .locked { return .locked }
        guard policy.consented && vault == .ready else { return .intro }
        return switchOn ? .on : .off
    }
    /// The line under the card's title, or nil. The switch shows On and Off, so they aren't repeated: it is
    /// drawn in every phase but locked, also before typing is set up (ux/v1: on asks first). The locked text is
    /// said once, beside Try again.
    public var detail: String? {
        switch phase {
        // Before typing is on: nothing under the title (fix/apps-declutter, owner 9/29: no line, no Learn more).
        case .intro: return nil
        case .locked: return nil
        case .off: return nil
        case .on: return policy.snoozed(now: now) ? "On, paused for now" : nil
        }
    }
    /// The saved switch, once typing is set up. Before that (also when the saved switch is on but typing can't record:
    /// consent for fewer places than this build, a lost key) the header draws the switch off, as typing is, and one
    /// click turns typing on (fix/typing-e2e: one state at a time, never a switch that says on while nothing records).
    public var showsSwitch: Bool { phase == .on || phase == .off }
    /// The categories whose checkboxes are drawn, in order: those with an app this build records typing in.
    /// (A public build records only Notes and TextEdit, so it has no dead checkboxes.)
    public var categories: [TypingCategory] {
        TypingCategory.allCases.filter { !TypingSettingsText.allowedApps($0).isEmpty }
    }
    /// The website row: "Other websites" in owner builds, else the "not recorded" line.
    public var showsOtherWebsites: Bool { ownerBuild && TypingSettingsText.otherWebsites != nil }
}

/// What the Typing card runs.
public struct TypingSettingsActions {
    public var setSwitch: (Bool) -> Void
    public var turnOn: () -> Void
    /// Onboarding only: turns the typing switch back off.
    public var notNow: (() -> Void)?
    public var setCategory: (TypingCategory, Bool) -> Void
    public var setOtherWebsites: (Bool) -> Void
    /// True when a period deletes words now (the confirmation comes first).
    public var needsConfirmation: (TypedRetention) -> Bool
    public var setRetention: (TypedRetention, Bool) -> Void
    public var pause: () -> Void
    public var resume: () -> Void
    public var forget: () -> Void
    public var chooseShortcut: (Int) -> Void
    /// "Try again" while the Keychain is locked: reads the typing key again.
    public var retryUnlock: () -> Void
    public init(setSwitch: @escaping (Bool) -> Void = { _ in }, turnOn: @escaping () -> Void = {}, notNow: (() -> Void)? = nil,
                setCategory: @escaping (TypingCategory, Bool) -> Void = { _, _ in }, setOtherWebsites: @escaping (Bool) -> Void = { _ in },
                needsConfirmation: @escaping (TypedRetention) -> Bool = { _ in false },
                setRetention: @escaping (TypedRetention, Bool) -> Void = { _, _ in },
                pause: @escaping () -> Void = {},
                resume: @escaping () -> Void = {}, forget: @escaping () -> Void = {}, chooseShortcut: @escaping (Int) -> Void = { _ in },
                retryUnlock: @escaping () -> Void = {}) {
        self.setSwitch = setSwitch; self.turnOn = turnOn; self.notNow = notNow; self.setCategory = setCategory
        self.setOtherWebsites = setOtherWebsites; self.needsConfirmation = needsConfirmation; self.setRetention = setRetention
        self.pause = pause; self.resume = resume; self.forget = forget; self.chooseShortcut = chooseShortcut
        self.retryUnlock = retryUnlock
    }
}

// MARK: - Settings ▸ Apps to remember ▸ Typing

/// The Typing card: until typing is set up, only its switch (turning it on asks first, with the Typing screen
/// as the message); then the switch, categories with their apps, how long exact words are kept, Forget, and one
/// disclosure with the pause shortcut and the limits. What summaries read is a consent bullet (summaries/v3).
/// In Settings (owner decision 2026-10-03) the settings under the switch open and close with a click on the title row;
/// what went wrong (a locked Keychain, a lost key, a failed setup or save, a shortcut macOS refused) shows either way.
public struct TypingSettingsCard: View {
    public static let identifier = "settings-typing"
    let values: TypingSettingsValues
    let actions: TypingSettingsActions
    /// Settings' open/closed row. nil: the settings are always shown (setup, renders and checks).
    let expanded: Binding<Bool>?
    @State private var pendingRetention: TypedRetention?
    @State private var confirmingForget = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(values: TypingSettingsValues, actions: TypingSettingsActions, expanded: Binding<Bool>? = nil) {
        self.values = values; self.actions = actions; self.expanded = expanded
    }

    private static let tint = DaydreamStyle.model

    /// Settings under the switch exist once typing is set up (on or off); before that the card is its switch.
    private var hasDetails: Bool { values.phase == .on || values.phase == .off }

    /// A problem with its one fix, shown with the row open or closed.
    private var problem: Bool {
        switch values.phase {
        case .intro: return values.keyLost || values.setupFailed
        case .locked: return true
        case .on: return values.shortcut?.message != nil
        case .off: return false
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if problem {
                rule
                Group {
                    switch values.phase {
                    case .intro:
                        introProblems
                    case .locked:
                        VStack(alignment: .leading, spacing: 8) {
                            Text(TypingSettingsText.locked).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            // Reads the Keychain again (typing also resumes by itself after an unlock).
                            Button(TypingSettingsText.tryAgain) { actions.retryUnlock() }
                                .buttonStyle(.bordered).controlSize(.small)
                                .accessibilityIdentifier("typing-locked-try-again")
                        }
                    case .on, .off:
                        shortcutProblem
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            if hasDetails && (expanded?.wrappedValue ?? true) {
                VStack(alignment: .leading, spacing: 0) {
                    rule
                    Group {
                        if values.phase == .on { onContent } else { offContent }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .transition(SettingsDisclosure.transition(reduceMotion: reduceMotion))
            }
            if values.saveFailed {
                Text(TypingSettingsText.notSaved).font(.system(size: 11)).foregroundStyle(DaydreamStyle.attention)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        // The card's edge cuts the settings while its height moves, so they never draw over what is below.
        .clipShape(RoundedRectangle(cornerRadius: DaydreamStyle.cardRadius))
        .daydreamCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.identifier)
        .alert(pendingRetention?.shorteningConfirmation ?? "", isPresented: Binding(get: { pendingRetention != nil },
                                                                                  set: { if !$0 { pendingRetention = nil } })) {
            Button(TypingSettingsText.delete, role: .destructive) {
                if let next = pendingRetention { actions.setRetention(next, true) }
                pendingRetention = nil
            }
            Button(TypingSettingsText.cancel, role: .cancel) { pendingRetention = nil }
        }
        .confirmationDialog(TypingSettingsText.forgetConfirmation, isPresented: $confirmingForget, titleVisibility: .visible) {
            Button(TypingSettingsText.delete, role: .destructive) { actions.forget() }
            Button(TypingSettingsText.cancel, role: .cancel) {}
        }
    }

    private var rule: some View {
        Rectangle().fill(DaydreamStyle.hairline).frame(height: 1).padding(.horizontal, 10).accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 12) {
            // The row, not the switch, opens and closes the settings under it.
            SettingsDisclosureLabel(open: expanded, hasDetails: hasDetails) {
                HStack(spacing: 12) {
                    Image(systemName: "keyboard").font(.system(size: 14, weight: .semibold)).foregroundStyle(Self.tint)
                        .frame(width: 32, height: 32)
                        .background(Self.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(TypingSettingsText.title).font(.system(size: 13, weight: .semibold))
                        if let detail = values.detail {
                            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                }
            }
            // Before typing is set up the switch shows off, as typing is, whatever was saved (fix/typing-e2e).
            if values.showsSwitch {
                Toggle(TypingSettingsText.switchLabel, isOn: Binding(get: { values.switchOn }, set: { actions.setSwitch($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!values.enabled).accessibilityLabel(TypingSettingsText.switchLabel)
            } else if values.phase == .intro {
                // Off until set up: on turns typing on at once (the line above says what it does; no second question).
                Toggle(TypingSettingsText.switchLabel, isOn: Binding(get: { false }, set: { if $0 { actions.turnOn() } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!values.enabled).accessibilityLabel(TypingSettingsText.switchLabel)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 52)
    }

    /// Before typing is set up: only what went wrong, with its one fix.
    private var introProblems: some View {
        VStack(alignment: .leading, spacing: 8) {
            if values.keyLost {
                Text(TypingSettingsText.keyLost).font(.system(size: 12)).foregroundStyle(DaydreamStyle.attention)
                    .fixedSize(horizontal: false, vertical: true)
                // The key was lost: the kept summaries can be deleted without turning typing on again.
                Button(TypingSettingsText.forget) { confirmingForget = true }.controlSize(.small).disabled(!values.enabled)
                    .accessibilityIdentifier("typing-key-lost-forget")
            }
            // fix/typing-e2e: no notice when typing was turned on for fewer places than this build records. The
            // header switch shows off with setup's one line, and one click turns typing on for this build's places.
            if values.setupFailed {
                Text(TypingSettingsText.keyError).font(.system(size: 12)).foregroundStyle(DaydreamStyle.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("typing-key-error")
                Button(TypingSettingsText.tryAgain, action: actions.turnOn).controlSize(.small).disabled(!values.enabled)
            }
        }
    }

    /// A shortcut macOS refused: said above the settings, so it shows with the row closed too.
    @ViewBuilder private var shortcutProblem: some View {
        if let message = values.shortcut?.message {
            Text(message).font(.system(size: 11)).foregroundStyle(DaydreamStyle.attention).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("typing-shortcut-message")
        }
    }

    private var offContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Keep exact words and its line under it say how long what you typed before is kept.
            keepWords
            // The same action as when typing is on, under the same name.
            Button(TypingSettingsText.forget) { confirmingForget = true }.controlSize(.small).disabled(!values.enabled)
        }
    }

    private var onContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            categories
            keepWords
            // Pausing for 10 minutes is in the menu bar and on the shortcut; the shortcut's picker is under
            // "Shortcut and limits". While paused, the way back is here too. A shortcut that failed says so above
            // these settings (`shortcutProblem`), outside both disclosures.
            if values.policy.snoozed(now: values.now) {
                Button(TypingSettingsText.resume) { actions.resume() }.controlSize(.small).disabled(!values.enabled)
            }
            Button(TypingSettingsText.forget) { confirmingForget = true }.controlSize(.small).disabled(!values.enabled)
            limits
        }
    }

    /// One checkbox per category, nothing under them (fix/apps-declutter, owner 9/29: too cluttered). Which apps and
    /// websites each covers stays in `TypingSettingsText.line` (docs, checks); the card draws only the titles.
    private var categories: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(values.categories, id: \.self) { category in
                Toggle(category.title, isOn: Binding(get: { values.policy.categories.isOn(category) },
                                                     set: { actions.setCategory(category, $0) }))
                    .toggleStyle(.checkbox).font(.system(size: 13)).disabled(!values.enabled)
            }
            if values.showsOtherWebsites, let row = TypingSettingsText.otherWebsites {
                Toggle(row.title, isOn: Binding(get: { values.policy.categories.otherWebsites }, set: { actions.setOtherWebsites($0) }))
                    .toggleStyle(.checkbox).font(.system(size: 13)).disabled(!values.enabled)
                    .help(row.help)
            }
        }
    }

    private var keepWords: some View {
        VStack(alignment: .leading, spacing: 3) {
            Picker(TypingSettingsText.keepTitle, selection: Binding(get: { values.policy.retention }, set: { next in
                guard next != values.policy.retention else { return }
                if actions.needsConfirmation(next) { pendingRetention = next } else { actions.setRetention(next, false) }
            })) {
                ForEach(TypedRetention.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu).font(.system(size: 13)).fixedSize().disabled(!values.enabled)
        }
    }


    private func shortcutRow(_ shortcut: TypingSettingsValues.Shortcut) -> some View {
        Picker(TypingSettingsText.shortcutTitle, selection: Binding(get: { shortcut.selected }, set: { actions.chooseShortcut($0) })) {
            ForEach(Array(shortcut.choices.enumerated()), id: \.offset) { index, title in Text(title).tag(index) }
        }
        .pickerStyle(.menu).font(.system(size: 13)).fixedSize()
    }

    /// The one disclosure: the pause shortcut (rarely changed) and the limits.
    private var limits: some View {
        DisclosureGroup(values.shortcut == nil ? TypingSettingsText.limitsTitle : TypingSettingsText.moreTitle) {
            VStack(alignment: .leading, spacing: 4) {
                if let shortcut = values.shortcut { shortcutRow(shortcut).padding(.bottom, 4) }
                ForEach(Array(TypingSettingsText.limits(keyPlace: values.keyPlace).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        }
        .font(.system(size: 12))
    }
}
