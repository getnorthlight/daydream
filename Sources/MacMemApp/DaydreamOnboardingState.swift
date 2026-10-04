import Foundation

enum DaydreamOnboardingPage: Int, CaseIterable {
    case permissions, summaries, apps, review
    /// Back: the page before; nil on the first page.
    var previous: DaydreamOnboardingPage? { DaydreamOnboardingPage(rawValue: rawValue - 1) }
}

/// Setup's Google Chrome row (owner, 10/2): a row on the Permissions card, in the style of Accessibility and Input
/// Monitoring, never a page of its own. Shown while Google Chrome is installed (and not excluded) and its access isn't
/// decided; once it was shown, it stays and shows its answer like the other rows. Its Allow asks macOS on the press
/// only. It never holds Continue, but the page doesn't move on by itself while it is still waiting for a press.
enum DaydreamOnboardingChromeRow {
    /// `answered`: allowed, refused, or refused without a question. `reading`: a read is still running (nothing shows yet).
    static func shown(release: Bool, installed: Bool, chromeExcluded: Bool, answered: Bool, reading: Bool, latched: Bool) -> Bool {
        guard release, installed, !chromeExcluded else { return false }
        return latched || (!answered && !reading)
    }
    /// The Permissions page stays put (Continue still works) while the row waits for its press.
    static func holdsPage(shown: Bool, pressed: Bool, answered: Bool) -> Bool { shown && !pressed && !answered }
}

/// The Chrome card for people who finished setup before the row existed (owner, 10/2): setup's Permissions card opens
/// once, by itself, when a read finds Chrome access not asked yet. Nothing else asks: the automatic ask at activation or
/// recording start is gone, so macOS's question never comes without the card. Allowed, refused, not installed, excluded
/// or page history off: nothing opens.
/// Owner, 10/2: Chrome access and "Save web pages in Google Chrome". Access granted from a press (Settings › Permissions'
/// row or setup's card) turns recording Chrome on when it was off; already on stays on; a refusal changes nothing. Turning
/// recording off never revokes access. Settings › Permissions shows the row whenever Chrome is installed (recording Chrome
/// is on by default).
enum DaydreamChromeGrant {
    static func turnsOnPages(allowed: Bool, pagesOn: Bool, release: Bool) -> Bool { release && allowed && !pagesOn }
    static func settingsRowShown(release: Bool, installed: Bool) -> Bool { release && installed }
}

enum DaydreamChromeCard {
    /// UserDefaults: the card opened once (it never opens by itself again).
    static let shownKey = "DaydreamChromePermissionCardShownV1"
    static func opens(setupCompleted: Bool, alreadyShown: Bool, notAsked: Bool, release: Bool, pagesOn: Bool,
                      chromeExcluded: Bool, installed: Bool) -> Bool {
        setupCompleted && !alreadyShown && notAsked && release && pagesOn && !chromeExcluded && installed
    }
}

struct DaydreamOnboardingRoute {
    private(set) var page: DaydreamOnboardingPage = .permissions
    private var advancesAfterPermissionGrant = true
    /// Where the page goes once both permissions are allowed: Summaries on a setup, the last page when Start sent
    /// someone who already finished setup back for a permission (their choices are already made).
    private let afterPermissions: DaydreamOnboardingPage

    /// `advances` false: the page never moves on by itself (the Chrome card for an upgrade, `DaydreamChromeCard`).
    init(afterPermissions: DaydreamOnboardingPage = .summaries, advances: Bool = true) {
        self.afterPermissions = afterPermissions
        advancesAfterPermissionGrant = advances
    }

    /// `relaunchPending`: Input Monitoring was turned on while DayDream was open and works only after DayDream
    /// reopens. The page waits (its main button is Quit & Reopen); after the relaunch setup opens again and moves on.
    /// `waitsForChrome`: the Chrome row still waits for its press (`DaydreamOnboardingChromeRow.holdsPage`); Continue moves on.
    mutating func permissionsChanged(accessibility: Bool, inputMonitoring: Bool, relaunchPending: Bool = false, waitsForChrome: Bool = false) {
        guard page == .permissions, advancesAfterPermissionGrant,
              accessibility, inputMonitoring, !relaunchPending, !waitsForChrome else { return }
        page = afterPermissions
        advancesAfterPermissionGrant = false
    }

    mutating func show(_ next: DaydreamOnboardingPage) {
        page = next
        // Returning to permissions is an intentional review, not a new setup.
        advancesAfterPermissionGrant = false
    }
}

/// Typing is on by default (owner, 9/27-9/28): setup and what's-new show the switch ON, with its one line, unless the
/// person explicitly turned it off (`SetupChoices.typing == .off`, saved by setup's Apps page and Settings) and it is
/// off now. One click turns it off. Nothing records until Start Recording (or, while recording, until Continue saves).
enum DaydreamOnboardingTyping {
    static func initialSwitch(savedConsent: Bool, explicitlyOff: Bool) -> Bool {
        savedConsent || !explicitlyOff
    }
    /// The typing switch after Continue tried to set typing up (its key): off when the key couldn't be made, so the switch
    /// matches "typing stays off" (fix/setup-tweaks).
    static func switchAfterTurnOn(ready: Bool, switchOn: Bool) -> Bool { switchOn && ready }
}

/// "Web pages in Chrome" is on by default too: ON unless explicitly turned off, where the release has Chrome page history.
enum DaydreamOnboardingChromePages {
    static func initialSwitch(saved: Bool, explicitlyOff: Bool, available: Bool) -> Bool {
        available && (saved || !explicitlyOff)
    }
}

/// "Messages and email" has no switch in setup (owner, 9/28: "we can do 2 settings"; fix/setup-2switch): the Apps page
/// (and what's-new's) shows typing and Web pages in Chrome only. It follows the typing switch: typing on (the default)
/// means Messages and email on, unless SetupChoices records an explicit off from before (`MemoryStore.turnOnTyping`
/// keeps it: `SetupChoices.messagesSeed`); typing off records no typing at all. Setup never saves it on its own, so a
/// Continue that moved nothing writes nothing; the Settings checkbox stays the one-click way to turn it off.
enum DaydreamOnboardingMessages {
    /// The switches setup's Apps page draws, in order.
    static let setupSwitches = ["typing", "chromePages"]
    /// Whether typing records Messages and email after setup: with typing, unless it was explicitly turned off before.
    static func recorded(typing: Bool, explicitlyOff: Bool) -> Bool { typing && !explicitlyOff }
    /// The saved checkbox setup starts from (on unless turned off; on in Preview). Nothing in setup moves it.
    static func initialSwitch(saved: Bool, preview: Bool) -> Bool { preview || saved }
    /// Whether setup's Continue saves Messages and email itself: never, since setup has no switch for it (turnOnTyping
    /// already set it with typing), so a Continue that moved nothing writes nothing.
    static func mustSave(typedText: Bool, messages: Bool, saved: Bool) -> Bool { false }
}

enum DaydreamOnboardingStartError: LocalizedError {
    case unavailable(String)
    case captureDidNotStart

    var errorDescription: String? {
        switch self {
        case .unavailable(let explanation): return explanation
        // Plain words, naming no page that doesn't exist. When the keyboard and mouse can't reach DayDream, setup says
        // that instead and its button becomes Quit & Reopen.
        case .captureDidNotStart: return "Recording didn't start. Try again."
        }
    }
}

/// Start Recording (owner, 9/28): recording starts first and never waits for summaries. Summaries were chosen on their
/// own page (Continue turned them on, and a download runs in the background); a problem there shows on the review and
/// the Today card with its one button, never as a reason recording didn't start.
@MainActor struct DaydreamOnboardingStartOperations {
    let validate: () throws -> Void
    let startCapture: () -> Bool
}

@MainActor final class DaydreamOnboardingStarter {
    private(set) var running = false

    /// Only the final, explicit Start action calls this: the prerequisites are read, then recording starts.
    func start(operations: DaydreamOnboardingStartOperations) async throws -> Bool {
        guard !running else { return false }
        running = true
        defer { running = false }
        try Task.checkCancellation()
        try operations.validate()
        guard operations.startCapture() else { throw DaydreamOnboardingStartError.captureDidNotStart }
        return true
    }
}

/// Which setup opens by itself at launch (owner, 9/28). A first setup until it is finished once. After an update from a
/// test build whose setup was finished before version 2, a short "What's new" (Summaries, Apps, then Done) that opens
/// at launch even while recording, until it is finished, at most `whatsNewShows` times in all. Finishing either writes
/// version 2, so it never opens by itself again.
enum DaydreamSetupVersion {
    /// UserDefaults: the setup version last finished (absent before version 2).
    static let key = "DaydreamSetupVersion"
    /// UserDefaults: how many times what's-new opened by itself without being finished.
    static let whatsNewShownKey = "DaydreamSetupWhatsNewShown"
    static let current = 2
    /// The first time, then at most 2 more launches.
    static let whatsNewShows = 3

    enum Launch: Equatable { case none, setup, whatsNew }

    /// claude/livefix-1004 (d): `typingPending`, the history's own Typing question is still unanswered
    /// (`MemoryStore.nativeTypingChoicePending`: a history made fresh, typing off, while this Mac's defaults still say
    /// setup was finished). Only setup's Apps page answers it, so the full setup opens, in every build, rather than
    /// recording with typing silently off.
    static func launch(completed: Bool, version: Int, whatsNewShown: Int, typingPending: Bool = false) -> Launch {
        if !completed || typingPending { return .setup }
        return version < current && whatsNewShown < whatsNewShows ? .whatsNew : .none
    }

    /// Setup, however it opened, is the short what's-new while a finished setup predates this version (never while the
    /// history's Typing question is pending: the full setup asks it).
    static func whatsNew(completed: Bool, version: Int, typingPending: Bool = false) -> Bool { completed && version < current && !typingPending }
}
