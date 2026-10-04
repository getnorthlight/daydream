import Foundation

@MainActor @main struct OnboardingFlowChecks {
    static var count = 0

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label)
        count += 1
        print("PASS " + label)
    }

    enum FixtureFailure: Error { case validation }

    @MainActor final class Fixture {
        var events: [String] = []
        var failValidation = false
        var capturesSuccessfully = true
        var accessibilityAllowed = true
        var inputMonitoringAllowed = true

        var operations: DaydreamOnboardingStartOperations {
            DaydreamOnboardingStartOperations(
                validate: {
                    self.events.append("validate")
                    guard self.accessibilityAllowed && self.inputMonitoringAllowed, !self.failValidation else { throw FixtureFailure.validation }
                },
                startCapture: {
                    self.events.append("capture")
                    return self.capturesSuccessfully
                }
            )
        }
    }

    static func main() async throws {
        setbuf(stdout, nil)
        routeChecks()
        typingDefaultChecks()
        try await finishChecks()
        print("\(count) onboarding checks passed. Simulated callbacks only; no permissions, capture, downloads, keys, or cloud requests.")
    }

    static func typingDefaultChecks() {
        // Opt-out (owner, 9/28): typing and Web pages in Chrome are ON unless the person turned them off in a setup
        // (SetupChoices .off); an upgrade whose older setup saved typing Off at that build's default shows them ON.
        check(DaydreamOnboardingTyping.initialSwitch(savedConsent: false, explicitlyOff: false),
              "setup shows typed text On unless it was turned off in a setup (an older build's default Off included)")
        check(!DaydreamOnboardingTyping.initialSwitch(savedConsent: false, explicitlyOff: true),
              "typed text turned off in a setup stays Off")
        // fix/setup-tweaks: a typing key the Keychain refused turns the switch off, to match "typing stays off".
        check(!DaydreamOnboardingTyping.switchAfterTurnOn(ready: false, switchOn: true), "a typing key that couldn't be made turns the typing switch off")
        check(DaydreamOnboardingTyping.switchAfterTurnOn(ready: true, switchOn: true), "a typing key that was made keeps the typing switch on")
        check(DaydreamOnboardingTyping.initialSwitch(savedConsent: true, explicitlyOff: false),
              "saved On stays On")
        check(DaydreamOnboardingChromePages.initialSwitch(saved: false, explicitlyOff: false, available: true),
              "setup shows Web pages in Chrome On unless it was turned off in a setup")
        check(!DaydreamOnboardingChromePages.initialSwitch(saved: false, explicitlyOff: true, available: true),
              "Web pages in Chrome turned off in a setup stays Off")
        check(!DaydreamOnboardingChromePages.initialSwitch(saved: true, explicitlyOff: false, available: false),
              "a release without Chrome page history never shows it On")
        // Which setup opens by itself at launch (setup version 2).
        check(DaydreamSetupVersion.launch(completed: false, version: 0, whatsNewShown: 0) == .setup, "an unfinished setup opens at launch")
        check(DaydreamSetupVersion.launch(completed: true, version: 0, whatsNewShown: 0) == .whatsNew,
              "a setup finished before version 2 gets what's-new at launch")
        check(DaydreamSetupVersion.launch(completed: true, version: 0, whatsNewShown: 2) == .whatsNew
              && DaydreamSetupVersion.launch(completed: true, version: 0, whatsNewShown: 3) == .none,
              "what's-new closed unfinished opens again at most 2 more times")
        check(DaydreamSetupVersion.launch(completed: true, version: 2, whatsNewShown: 0) == .none, "a finished version-2 setup never opens by itself")
        check(DaydreamSetupVersion.whatsNew(completed: true, version: 1) && !DaydreamSetupVersion.whatsNew(completed: false, version: 0)
              && !DaydreamSetupVersion.whatsNew(completed: true, version: 2), "setup is the short what's-new only after an older finished setup")
        // claude/livefix-1004 (d): a history made fresh while this Mac's defaults still say setup was finished: its
        // Typing question is pending (typing off) and only setup's Apps page answers it, so the full setup opens.
        check(DaydreamSetupVersion.launch(completed: true, version: 2, whatsNewShown: 0, typingPending: true) == .setup
              && DaydreamSetupVersion.launch(completed: true, version: 0, whatsNewShown: 3, typingPending: true) == .setup
              && DaydreamSetupVersion.launch(completed: false, version: 0, whatsNewShown: 0, typingPending: true) == .setup,
              "a pending Typing question opens the full setup at launch, whatever the defaults say")
        check(!DaydreamSetupVersion.whatsNew(completed: true, version: 1, typingPending: true),
              "with the Typing question pending, setup is the full setup, never the short what's-new")
        check(DaydreamSetupVersion.launch(completed: true, version: 2, whatsNewShown: 0, typingPending: false) == .none,
              "answered (or an older history): a finished setup still never opens by itself")
        if let app = try? String(contentsOfFile: "Sources/MacMemApp/MacMemApp.swift", encoding: .utf8) {
            check(app.contains("whatsNewShown:shown,\n                                               typingPending:onboardingTypingChoicePending)")
                  && app.contains("typingPending:onboardingTypingChoicePending)"),
                  "setupLaunch and setupIsWhatsNew pass the history's pending Typing question")
        } else { check(false, "MacMemApp.swift readable from the checkout") }
        // Messages and email (owner, 9/28 evening, fix/setup-2switch): no row in setup; it follows typing.
        check(DaydreamOnboardingMessages.setupSwitches == ["typing", "chromePages"] && !DaydreamOnboardingMessages.setupSwitches.contains("messages"),
              "no Messages and email row in setup: two switches, typing and Web pages in Chrome")
        check(DaydreamOnboardingMessages.recorded(typing: true, explicitlyOff: false), "typing on implies Messages and email on")
        check(!DaydreamOnboardingMessages.recorded(typing: true, explicitlyOff: true), "an explicit off in SetupChoices stays off with typing on")
        check(!DaydreamOnboardingMessages.recorded(typing: false, explicitlyOff: false), "typing off records no Messages and email (no typing at all)")
        check([(true, true, true), (true, false, true), (true, true, false), (false, false, true)].allSatisfy {
                  !DaydreamOnboardingMessages.mustSave(typedText: $0.0, messages: $0.1, saved: $0.2) },
              "setup never saves the Messages and email choice itself: a Continue that moved nothing writes nothing")
        check(DaydreamOnboardingMessages.initialSwitch(saved: true, preview: false) && !DaydreamOnboardingMessages.initialSwitch(saved: false, preview: false),
              "setup starts from the saved checkbox (an explicit off stays off)")
    }

    static func routeChecks() {
        check(DaydreamOnboardingPage.allCases == [.permissions, .summaries, .apps, .review], "four setup pages: Chrome is a row on Permissions (owner, 10/2)")
        check(DaydreamOnboardingPage.review.previous == .apps && DaydreamOnboardingPage.apps.previous == .summaries
              && DaydreamOnboardingPage.permissions.previous == nil, "Back goes one page back; none on the first page")
        // The Chrome row: installed, not excluded, access not decided; once shown it stays and shows the answer.
        typealias Row = DaydreamOnboardingChromeRow
        check(Row.shown(release: true, installed: true, chromeExcluded: false, answered: false, reading: false, latched: false),
              "Chrome row: shown with Chrome installed and access not decided")
        check(!Row.shown(release: true, installed: false, chromeExcluded: false, answered: false, reading: false, latched: false)
              && !Row.shown(release: true, installed: true, chromeExcluded: true, answered: false, reading: false, latched: false)
              && !Row.shown(release: false, installed: true, chromeExcluded: false, answered: false, reading: false, latched: false),
              "Chrome row: never without Chrome, with Chrome excluded, or without page history")
        check(!Row.shown(release: true, installed: true, chromeExcluded: false, answered: true, reading: false, latched: false)
              && !Row.shown(release: true, installed: true, chromeExcluded: false, answered: false, reading: true, latched: false),
              "Chrome row: not for access already decided, nor before the first read finishes")
        check(Row.shown(release: true, installed: true, chromeExcluded: false, answered: true, reading: false, latched: true)
              && Row.shown(release: true, installed: true, chromeExcluded: false, answered: false, reading: true, latched: true),
              "Chrome row: once shown it stays, showing its answer (or macOS asking)")
        check(Row.holdsPage(shown: true, pressed: false, answered: false) && !Row.holdsPage(shown: true, pressed: true, answered: false)
              && !Row.holdsPage(shown: true, pressed: false, answered: true) && !Row.holdsPage(shown: false, pressed: false, answered: false),
              "Chrome row: the page waits for it only before its press or an answer")
        var held = DaydreamOnboardingRoute()
        held.permissionsChanged(accessibility: true, inputMonitoring: true, waitsForChrome: true)
        check(held.page == .permissions, "both permissions allowed while the Chrome row waits: the page stays (Continue moves on)")
        held.permissionsChanged(accessibility: true, inputMonitoring: true)
        check(held.page == .summaries, "the Chrome row answered or pressed: the page moves on by itself")
        var card = DaydreamOnboardingRoute(afterPermissions: .review, advances: false)
        card.permissionsChanged(accessibility: true, inputMonitoring: true)
        check(card.page == .permissions, "the upgrade's Chrome card never moves on by itself")
        // The upgrade card: once, only for a finished setup whose Chrome access reads "not asked".
        // Owner, 10/2: a grant turns recording Chrome on when off; already on, or a refusal, changes nothing.
        check(DaydreamChromeGrant.turnsOnPages(allowed: true, pagesOn: false, release: true), "grant with Save web pages off turns it on")
        check(!DaydreamChromeGrant.turnsOnPages(allowed: true, pagesOn: true, release: true), "grant with Save web pages on leaves it unchanged")
        check(!DaydreamChromeGrant.turnsOnPages(allowed: false, pagesOn: false, release: true), "a refusal leaves Save web pages unchanged")
        check(!DaydreamChromeGrant.turnsOnPages(allowed: true, pagesOn: false, release: false), "a release without Chrome page history never turns it on")
        check(DaydreamChromeGrant.settingsRowShown(release: true, installed: true) && !DaydreamChromeGrant.settingsRowShown(release: true, installed: false),
              "Settings › Permissions shows the Chrome row whenever Chrome is installed")
        typealias Card = DaydreamChromeCard
        check(Card.opens(setupCompleted: true, alreadyShown: false, notAsked: true, release: true, pagesOn: true, chromeExcluded: false, installed: true),
              "upgrade (setup v2 finished, Chrome not asked): the card opens")
        check(!Card.opens(setupCompleted: true, alreadyShown: true, notAsked: true, release: true, pagesOn: true, chromeExcluded: false, installed: true),
              "upgrade: the card opens once only")
        check(!Card.opens(setupCompleted: true, alreadyShown: false, notAsked: false, release: true, pagesOn: true, chromeExcluded: false, installed: true),
              "upgrade with Chrome allowed or denied: nothing opens")
        check(!Card.opens(setupCompleted: true, alreadyShown: false, notAsked: true, release: true, pagesOn: true, chromeExcluded: false, installed: false),
              "upgrade without Chrome installed: nothing opens")
        check(!Card.opens(setupCompleted: false, alreadyShown: false, notAsked: true, release: true, pagesOn: true, chromeExcluded: false, installed: true),
              "a first setup has the row itself: no separate card")
        check(!Card.opens(setupCompleted: true, alreadyShown: false, notAsked: true, release: true, pagesOn: false, chromeExcluded: false, installed: true)
              && !Card.opens(setupCompleted: true, alreadyShown: false, notAsked: true, release: true, pagesOn: true, chromeExcluded: true, installed: true),
              "page history off or Chrome excluded: nothing opens")
        var route = DaydreamOnboardingRoute()
        check(route.page == .permissions, "fresh setup opens permissions")
        route.permissionsChanged(accessibility: false, inputMonitoring: false)
        check(route.page == .permissions, "no permission keeps first page")
        route.permissionsChanged(accessibility: true, inputMonitoring: false)
        check(route.page == .permissions, "Accessibility alone does not advance")
        route.permissionsChanged(accessibility: false, inputMonitoring: true)
        check(route.page == .permissions, "Input Monitoring alone does not advance")
        route.permissionsChanged(accessibility: true, inputMonitoring: true)
        check(route.page == .summaries, "both actual permissions advance to summaries")
        route.permissionsChanged(accessibility: true, inputMonitoring: true)
        check(route.page == .summaries, "repeated grant refresh does not skip summaries")
        route.show(.permissions)
        route.permissionsChanged(accessibility: true, inputMonitoring: true)
        check(route.page == .permissions, "Back can review granted permissions without bounce")
        route.permissionsChanged(accessibility: false, inputMonitoring: false)
        route.permissionsChanged(accessibility: true, inputMonitoring: true)
        check(route.page == .permissions, "intentional permission review stays put after regrant")
        route.show(.summaries)
        check(route.page == .summaries, "explicit Continue exits permission review")
        route.show(.apps)
        route.permissionsChanged(accessibility: false, inputMonitoring: false)
        check(route.page == .apps, "background permission refresh does not redirect app choices")
        route.show(.review)
        check(route.page == .review, "review remains a separate final page")
        route.show(.apps)
        check(route.page == .apps, "review can return to apps")
        let reopened = DaydreamOnboardingRoute()
        check(reopened.page == .permissions, "new setup session resets route")
        var waiting = DaydreamOnboardingRoute()
        waiting.permissionsChanged(accessibility: true, inputMonitoring: true, relaunchPending: true)
        check(waiting.page == .permissions, "Input Monitoring that works only after DayDream reopens: the page waits (Quit & Reopen)")
        waiting.permissionsChanged(accessibility: true, inputMonitoring: true)
        check(waiting.page == .summaries, "after the relaunch, both allowed moves on to Summaries by itself")
        var again = DaydreamOnboardingRoute(afterPermissions: .review)
        again.permissionsChanged(accessibility: false, inputMonitoring: true)
        check(again.page == .permissions, "a finished setup sent back for a permission waits for both")
        again.permissionsChanged(accessibility: true, inputMonitoring: true)
        check(again.page == .review, "…then goes straight to the last page: the choices made before are kept")

        let permissions = [(false, false), (true, false), (false, true), (true, true)]
        var checkedSequences = 0
        for sequenceLength in 1...5 {
            let sequenceCount = Int(pow(4.0, Double(sequenceLength)))
            for sequence in 0..<sequenceCount {
                var scenario = DaydreamOnboardingRoute()
                var remaining = sequence
                var encounteredFullGrant = false
                for _ in 0..<sequenceLength {
                    let state = permissions[remaining % 4]
                    remaining /= 4
                    encounteredFullGrant = encounteredFullGrant || (state.0 && state.1)
                    scenario.permissionsChanged(accessibility: state.0, inputMonitoring: state.1)
                    precondition(scenario.page == (encounteredFullGrant ? .summaries : .permissions), "permission refresh must advance exactly once after both actual grants")
                }
                checkedSequences += 1
            }
        }
        check(checkedSequences == 1364, "all 1,364 permission callback sequences through five refreshes advance only after both grants")
        for destination in DaydreamOnboardingPage.allCases {
            var reviewed = DaydreamOnboardingRoute()
            reviewed.show(destination)
            for state in permissions {
                reviewed.permissionsChanged(accessibility: state.0, inputMonitoring: state.1)
                precondition(reviewed.page == destination, "intentional review must not be redirected by permission refresh")
            }
        }
        check(true, "manual review pages never redirect after partial grants, revocation, or regrant")
    }

    static func finishChecks() async throws {
        // Start Recording (owner, 9/28): recording starts first; summaries never hold it back or roll back.
        do {
            let fixture = Fixture(), starter = DaydreamOnboardingStarter()
            let started = try await starter.start(operations: fixture.operations)
            check(started, "successful final action reports recording")
            check(fixture.events == ["validate", "capture"], "the prerequisites are read, then recording starts (nothing about summaries in between)")
            check(!starter.running, "successful final action clears running state")
        }
        do {
            let fixture = Fixture(), starter = DaydreamOnboardingStarter()
            fixture.failValidation = true
            do {
                _ = try await starter.start(operations: fixture.operations)
                preconditionFailure("invalid prerequisites must throw")
            } catch FixtureFailure.validation {}
            check(fixture.events == ["validate"], "invalid prerequisites never start capture")
            check(!starter.running, "validation failure clears running state")
        }
        do {
            let fixture = Fixture(), starter = DaydreamOnboardingStarter()
            fixture.capturesSuccessfully = false
            do {
                _ = try await starter.start(operations: fixture.operations)
                preconditionFailure("capture refusal must throw")
            } catch DaydreamOnboardingStartError.captureDidNotStart {}
            check(fixture.events == ["validate", "capture"], "capture refusal never claims completion")
            check(!starter.running, "capture refusal permits explicit retry")
        }
        do {
            let fixture = Fixture(), starter = DaydreamOnboardingStarter()
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await starter.start(operations: fixture.operations)
            }
            do {
                _ = try await cancelled.value
                preconditionFailure("pre-cancelled task must not start")
            } catch is CancellationError {}
            check(fixture.events.isEmpty, "cancelled final action has no side effects")
        }
        for grants in [(false, false), (true, false), (false, true)] {
            let fixture = Fixture(), starter = DaydreamOnboardingStarter()
            fixture.accessibilityAllowed = grants.0
            fixture.inputMonitoringAllowed = grants.1
            do {
                _ = try await starter.start(operations: fixture.operations)
                preconditionFailure("both permissions are required at final Start")
            } catch FixtureFailure.validation {}
            check(fixture.events == ["validate"], "missing permission pair \(grants) blocks final Start before capture")
        }
    }
}
