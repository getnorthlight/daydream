import SwiftUI
import ApplicationServices
import CoreGraphics
import MemoryCore
import MemoryUI
import WriterBackend

/// Setup (owner, 9/28): forced and proper, and every page works while recording.
/// - A first setup: Permissions, Summaries, Apps, then the review, whose Start Recording starts recording at once. The
///   Permissions card has a Google Chrome row while Chrome is installed and its access isn't decided
///   (`DaydreamOnboardingChromeRow`, owner 10/2); its Allow asks macOS on the press, and it never holds Continue.
/// - Once, for someone who finished setup before that row (`DaydreamChromeCard`): the Permissions card alone, with Done.
/// - After an update from a test build whose setup was finished before version 2 (`DaydreamSetupVersion`): the short
///   "What's new", from Summaries (Permissions only while one is missing), then Apps, then the review with Done.
/// Summaries turn on at the Summaries page's Continue: on this Mac the download runs in the background and the writer
/// turns summaries on once the model is verified, even if this window closes; an OpenRouter key is tried at Continue.
/// Typing and Web pages in Chrome are on unless the person turned them off (`SetupChoices`); Continue on Apps saves both.
struct DaydreamOnboarding: View {
    @ObservedObject var model: MemoryViewModel
    @ObservedObject private var writer: WriterIntegration
    @ObservedObject private var typing: TypingModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.daydreamPermissionRequests) private var requests
    @AppStorage("DaydreamOnboardingCompletedV1") private var completed = false
    @State private var route = DaydreamOnboardingRoute()
    /// The short what's-new for an upgrade (set as setup opens).
    @State private var whatsNew: Bool
    @State private var choice: DaydreamSummaryChoice
    /// fix/bugs7: the person picked a summaries row. Until then the rows follow the writer as its state settles: at launch
    /// a saved OpenRouter choice reads as Checking (the local row's state) until the cloud is back on, and Continue on that
    /// stale row turned OpenRouter off and started the 2.7 GB download.
    @State private var choiceTouched = false
    @State private var key = ""
    /// The answer to the key Continue tried (its line and one button under the field; the page stays).
    @State private var cloudProblem: SummaryProblem?
    @State private var focusKey = 0
    @State private var exclusions: Set<String>
    @State private var typedText: Bool
    /// "Web pages in Chrome" (on unless turned off, like typing).
    @State private var chromePages: Bool
    /// "Messages and email" (opt-out, owner 9/28): the saved checkbox, which is on unless the person turned it off. Setup
    /// draws no switch for it (fix/setup-2switch): it follows typing, so this never moves from its seed.
    @State private var messages: Bool
    @State private var seedMessages: Bool
    @State private var baselineExclusions: Set<String>
    @State private var baselineTypedText: Bool
    @State private var baselineChromePages: Bool
    /// What the two switches were set to when the page read the saved choices: the page's own edits are measured from
    /// these, so an untouched page has none.
    @State private var seedTypedText: Bool
    @State private var seedChromePages: Bool
    @State private var apps: [LocalApp] = []
    @State private var appsLoaded = false
    @State private var query = ""
    @State private var accessibility = false
    @State private var inputMonitoring = false
    @State private var error: String?
    @State private var working = false
    @State private var startTask: Task<Void, Never>?
    @State private var starter = DaydreamOnboardingStarter()
    /// FileVault reads as off (`FileVaultStatus`): only then does the last page say the history isn't encrypted.
    @State private var fileVaultOff = false
    /// The Chrome row was shown on this card: it stays, showing its answer (`DaydreamOnboardingChromeRow`).
    @State private var chromeRowLatched = false
    /// Google Chrome is on this Mac (read as the card opens; nothing is opened or asked).
    @State private var chromeInstalled = false
    /// The Chrome row's Allow was pressed (macOS was asked, or Chrome was opened to ask).
    @State private var chromeAsked = false
    @State private var chromeIcon: NSImage?
    /// The Permissions card alone, once, for someone who finished setup before the Chrome row (`DaydreamChromeCard`).
    @State private var chromeCard = false
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Both recording permissions, each read without a prompt. The checks stand in a read.
    static var readPermissions: () -> (accessibility: Bool, inputMonitoring: Bool) = { (AXIsProcessTrusted(), CGPreflightListenEventAccess()) }
    /// This Mac can run the model: Apple silicon with 8 GB of memory (`WriterCandidates.recommended`). Otherwise the
    /// OpenRouter row is setup's default.
    #if DEVELOPMENT_SOURCE_CHECKS
    /// A saved OpenRouter choice (setup-upgrade-checks); nil reads the writer.
    static var cloudChosenForChecks: Bool?
    #endif
    static func cloudChosen(_ writer: WriterIntegration) -> Bool {
        #if DEVELOPMENT_SOURCE_CHECKS
        if let cloudChosenForChecks { return cloudChosenForChecks }
        #endif
        return writer.cloudIntended
    }
    static var macQualifies: Bool {
        #if DEVELOPMENT_SOURCE_CHECKS
        if let qualifiesForChecks { return qualifiesForChecks }
        #endif
        #if arch(arm64)
        return ProcessInfo.processInfo.physicalMemory >= (WriterCandidates.recommended?.minimumMemory ?? 8_589_934_592)
        #else
        return false
        #endif
    }
    #if DEVELOPMENT_SOURCE_CHECKS
    /// A Mac that can't run the model (setup-upgrade-checks); nil reads this Mac.
    static var qualifiesForChecks: Bool?
    #endif
    /// The model's size, as the line says it ("2.7 GB").
    static var modelSize: String { SummaryPhaseReading.gigabytes(WriterCandidates.recommended?.asset.bytes ?? 2_740_937_888) }

    init(model: MemoryViewModel) {
        self.model = model
        writer = model.noteWriter
        typing = model.typing
        _whatsNew = State(initialValue: model.setupIsWhatsNew)
        _choice = State(initialValue: Self.initialChoice(phase: SummaryControls.phase(model.noteWriter), localOffered: model.noteWriter.localOffered,
                                                         qualifies: Self.macQualifies, cloudChosen: Self.cloudChosen(model.noteWriter)))
        let excluded = Self.appIDs(model.blockedApps)
        _exclusions = State(initialValue: excluded)
        _baselineExclusions = State(initialValue: excluded)
        let seeds = Self.seeds(model)
        _typedText = State(initialValue: seeds.typing)
        _seedTypedText = State(initialValue: seeds.typing)
        _baselineTypedText = State(initialValue: model.captureText)
        _chromePages = State(initialValue: seeds.chrome)
        _seedChromePages = State(initialValue: seeds.chrome)
        _baselineChromePages = State(initialValue: model.browserPages)
        let seededMessages = Self.savedMessages(model)
        _messages = State(initialValue: seededMessages)
        _seedMessages = State(initialValue: seededMessages)
    }

    /// The saved Messages and email checkbox (on unless turned off); on in Preview.
    private static func savedMessages(_ model: MemoryViewModel) -> Bool {
        DaydreamOnboardingMessages.initialSwitch(saved: model.typing.policy.categories.messagesAndEmail,
                                                 preview: model.development?.preview == true)
    }

    /// Where the summaries switches start: what is on (or downloading) now; else "Summaries on this Mac" where this Mac
    /// can run it, and the OpenRouter row where it can't.
    /// fix/sx-all round 2: a person who chose OpenRouter with a saved key (`WriterIntegration.cloudIntended`) starts on the
    /// OpenRouter row, also while the key is still being checked at launch (drawn as `.checking`) or cloud stopped after
    /// an update; never on "Summaries on this Mac", which would turn their choice off at Continue.
    static func initialChoice(phase: SummaryPhase, localOffered: Bool, qualifies: Bool, cloudChosen: Bool = false) -> DaydreamSummaryChoice {
        if SummaryPhaseReading.cloudOn(phase) { return .cloud }
        if cloudChosen && phase != .on(.local) { return .cloud }
        if SummaryPhaseReading.localOn(phase) && localOffered { return .local }
        return localOffered && qualifies ? .local : .cloud
    }

    /// Both switches on, unless the person turned one off (SetupChoices) and it is off now. DayDream Preview: both on.
    private static func seeds(_ model: MemoryViewModel) -> (typing: Bool, chrome: Bool) {
        let choices = model.development == nil ? model.setupChoicesRead() : SetupChoices()
        return (DaydreamOnboardingTyping.initialSwitch(savedConsent: model.captureText, explicitlyOff: choices.typing == .off),
                DaydreamOnboardingChromePages.initialSwitch(saved: model.browserPages, explicitlyOff: choices.chromePages == .off,
                                                            available: ReleaseFeatures.chromePageHistory))
    }

    private var page: DaydreamOnboardingPage { route.page }
    private var permitted: Bool { accessibility && inputMonitoring }
    private var available: Bool { model.development == nil }
    /// DayDream Preview: setup to click through. Its switches and pages work, but nothing is saved, no permission is
    /// asked for and Start Recording only closes it (`PreviewSample`).
    private var preview: Bool { model.development?.preview == true }
    private var summariesAvailable: Bool { available && !model.recordingTrial }
    private var phase: SummaryPhase { SummaryControls.phase(writer) }
    /// A key is already saved and cloud summaries are on with it (nothing reads the Keychain to find out).
    private var savedKey: Bool { phase == .on(.cloud) }
    /// fix/sx-all round 2: OpenRouter was chosen with a key that is still saved (cloud may be off after an update, or still
    /// being checked): Continue with the field empty tries that key (`chooseCloud` with no key uses the saved one).
    private var keyKept: Bool { Self.cloudChosen(writer) }

    #if DEVELOPMENT_SOURCE_CHECKS
    /// What the page drew last (setup-upgrade-checks and the renders read it: offscreen SwiftUI text has no
    /// accessibility tree to read).
    struct Drawn {
        var page: DaydreamOnboardingPage
        var title: String
        var button: String
        var back: Bool
        var localLine: String
        var cloudProblem: SummaryProblem?
        /// The line at the top of the page (a problem Continue ran into), and the typing switch.
        var error: String?
        var typedText: Bool
        var rows: [(title: String, value: String, button: String?)]
    }
    static var drawnForChecks: Drawn?
    /// The Permissions page's drag hint as it starts (the renders: a card's pane already opened); nil starts hidden.
    static var dragHintForChecks: PermissionDragHint?
    #endif

    /// How the Permissions page's "Drag the card into the list" starts: hidden until a card's pane opens.
    private var dragHintInitially: PermissionDragHint {
        #if DEVELOPMENT_SOURCE_CHECKS
        return Self.dragHintForChecks ?? PermissionDragHint()
        #else
        return PermissionDragHint()
        #endif
    }

    var body: some View {
        #if DEVELOPMENT_SOURCE_CHECKS
        let _ = Self.drawnForChecks = Drawn(page: page, title: title, button: continueTitle, back: backAction != nil, localLine: localLine,
                                            cloudProblem: cloudProblem, error: error, typedText: typedText,
                                            rows: page == .review ? reviewRows.map { ($0.title, $0.value, $0.button?.title) } : [])
        #endif
        DaydreamOnboardingShell(
            title: title, subtitle: nil,
            back: backAction,
            continueTitle: continueTitle,
            canContinue: canContinue, working: working,
            // The icon opens and closes setup; the summaries and apps steps use its room for their controls.
            showsIcon: page == .permissions || page == .review,
            continueAction: proceed
        ) {
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(error)
            }
            pageContent
        }
        .onAppear { resetForReview(); applySetupRequest(); readChrome(); applyChromeCard(); refreshPermissions() }
        .onChange(of: model.chromeCardRequested) { _ in applyChromeCard() }
        // A Start control elsewhere sent the person here (MemoryViewModel.requestStart).
        .onChange(of: model.setupRequest) { _ in applySetupRequest() }
        .onChange(of: page) { _ in settleUneditedChoices() }
        .onReceive(permissionTimer) { _ in refreshPermissions(); settleUneditedChoices() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermissions() }
        .onChange(of: choice) { _ in error = nil; cloudProblem = nil }
        // The Chrome row, once shown, stays and shows its answer.
        .onChange(of: model.chromeAccess) { _ in latchChromeRow() }
        .onChange(of: phase) { _ in followPhase() }
        // Typing switched on again after the key failed: the "typing stays off" line no longer matches the switch.
        .onChange(of: typedText) { on in if on && error == TypingSettingsText.keyError { error = nil } }
        .task { fileVaultOff = await FileVaultStatus.current() == false }
        .onDisappear {
            key = ""
            startTask?.cancel()
            // Closing setup never stops summaries: a download that started runs on, and the writer turns summaries on
            // once the model is verified.
        }
        .task {
            guard !appsLoaded else { return }
            let catalog = await Task.detached(priority: .utility) { LocalApp.catalog() }.value
            guard !Task.isCancelled else { return }
            apps = LocalApp.includingMissing(catalog, excluded: exclusions)
            appsLoaded = true
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .permissions:
            // Quit & Reopen, when macOS needs it, is this page's main button instead of a row.
            PermissionGrantView(enabled: available, readAccessibility: { Self.readPermissions().accessibility },
                                readInputMonitoring: { Self.readPermissions().inputMonitoring }, embedded: true, showsRelaunchRow: false,
                                dragHint: dragHintInitially, chromeRow: chromeRow, showsAIReadsToggle: true, onStatusChange: permissionChanged)
        case .summaries:
            DaydreamSummariesContent(choice: Binding(get: { choice }, set: { choice = $0; choiceTouched = true }), cloudKey: $key, localAvailable: writer.localOffered, localLine: localLine,
                                     savedKey: savedKey || keyKept, problem: cloudProblem, fix: fixCloudProblem, focusRequest: focusKey)
                .disabled(!(summariesAvailable || preview) || working)
            if !summariesAvailable && !preview {
                Text("Summaries are unavailable in this recording-only preview. You can continue without changing them.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .apps:
            // The launch notice has been seen once this page closes.
            if let notice = model.preferenceNotice { ChoiceNoticeLine(text: notice).onDisappear { model.preferenceNoticeSeen() } }
            // A change that didn't save: one sentence and the one button that fixes it.
            if let problem = appsProblem {
                ChoiceProblemLine(text: problem.text, buttonTitle: problem.buttonTitle, action: fixAppsProblem)
            }
            DaydreamAppsContent(apps: apps, excluded: exclusions, query: $query,
                browserPages: model.browserPagesSaved,
                chromePages: ReleaseFeatures.chromePageHistory ? $chromePages : nil,
                typedText: $typedText, loaded: appsLoaded,
                enabled: preview || (available && model.preferencesAvailable && !working),
                allowTyping: available || preview, compact: model.preferenceNotice != nil || appsProblem != nil, toggle: toggleApp)
        case .review:
            // A blocker setup fixes is said by the button ("Allow Permissions"); only the others need a sentence.
            DaydreamReviewContent(rows: reviewRows, message: startBlocker.flatMap { $0.fix == nil ? $0.text : nil },
                                  fileVaultOff: fileVaultOff)
            // Only what setup can't fix itself goes to Settings; Start Recording goes to every other fix.
            if let issue = startBlocker, issue.settings {
                Button(Self.openSettingsTitle) { showSettings(Self.settingsSection(for: issue.text)) }
                    .buttonStyle(.plain).font(.system(size: 12))
            }
        }
    }

    // MARK: Words

    static let whatsNewTitle = "What's new"
    static let allSetTitle = "You're all set"
    static let almostReadyTitle = "Almost ready"

    private var title: String {
        switch page {
        case .permissions: return "Grant DayDream Permissions"
        case .summaries: return whatsNew ? Self.whatsNewTitle : "Set up summaries"
        case .apps: return "Apps to remember"
        // "You're all set" only when summaries aren't off, nothing failed and nothing stands in the way.
        case .review: return allSet ? Self.allSetTitle : Self.almostReadyTitle
        }
    }

    private var allSet: Bool {
        guard startBlocker == nil else { return false }
        if preview { return true }
        switch phase {
        case .off, .failed: return false
        default: return true
        }
    }

    /// Row 1's one line: the size before anything is downloaded, the download's own state while it runs, or where it
    /// runs once the model is here.
    private var localLine: String {
        switch phase {
        // A saved OpenRouter choice being checked at launch is the key's check, not this Mac's model.
        case .checking where keyKept: return writer.modelOnMac ? DaydreamSummariesContent.localReadyLine : DaydreamSummariesContent.localLine(size: Self.modelSize)
        case .downloading, .checking: return phase.line ?? DaydreamSummariesContent.localReadyLine
        case .on(.local): return DaydreamSummariesContent.localReadyLine
        case .failed(let problem) where !SummaryPhaseReading.isCloud(problem): return problem.line
        default: return writer.modelOnMac ? DaydreamSummariesContent.localReadyLine : DaydreamSummariesContent.localLine(size: Self.modelSize)
        }
    }

    // MARK: Buttons

    /// Back, except on setup's first page (Permissions, or what's-new's Summaries).
    private var backAction: (() -> Void)? {
        if page == .permissions { return nil }
        if whatsNew && page == .summaries { return nil }
        return { goBack() }
    }

    private var canContinue: Bool {
        guard !working else { return false }
        if preview { return true }
        if relaunchPending && (page == .permissions || page == .review) { return true }
        switch page {
        // The Chrome row never holds Continue; the Chrome card alone (permissions already settled) always has Done.
        case .permissions: return permitted || chromeCard
        // fix/sx-all round 1: the key switch on with no key pasted (and none saved) can't continue: before, Continue went
        // on and the review said Summaries Off. Turning the switch off (or pasting a key) is the way on.
        case .summaries: return !(summariesAvailable && choice == .cloud && key.isEmpty && !savedKey && !keyKept && !SummaryPhaseReading.cloudOn(phase))
        case .apps: return available && appsLoaded && model.preferencesAvailable && appsProblem == nil
        // Start Recording also runs when setup can fix what stands: it goes to that page. Done always runs.
        case .review: return model.recording || (startBlocker.map { $0.fix != nil } ?? true)
        }
    }

    /// Input Monitoring was turned on while DayDream was open, so it works only after DayDream reopens (macOS
    /// says so too). Once Accessibility is allowed too (so one reopen is enough), the Permissions page and the last
    /// page have one button, Quit & Reopen; setup opens again after the relaunch (it isn't finished) and moves on by
    /// itself. No Quit & Reopen where DayDream can't reopen itself (a development binary).
    /// The same once Start couldn't reach the keyboard and mouse (`MemoryViewModel.inputNeedsReopen`): Resume sent the
    /// person here, and Quit & Reopen is the one fix.
    private func relaunchPending(accessibility: Bool, inputMonitoring: Bool) -> Bool {
        Self.relaunchPending(available: available, accessibility: accessibility, inputMonitoring: inputMonitoring,
                             canReopen: requests?.quitAndReopen != nil, inputMonitoringAtLaunch: requests?.inputMonitoringAtLaunch,
                             inputNeedsReopen: model.inputNeedsReopen)
    }
    static func relaunchPending(available: Bool, accessibility: Bool, inputMonitoring: Bool, canReopen: Bool,
                                inputMonitoringAtLaunch: Bool?, inputNeedsReopen: Bool) -> Bool {
        guard available, accessibility, canReopen else { return false }
        if inputNeedsReopen && inputMonitoring { return true }
        return PermissionRelaunch.reason(inputMonitoringAtLaunch: inputMonitoringAtLaunch,
                                         accessibility: accessibility, inputMonitoring: inputMonitoring) == .inputMonitoringTurnedOn
    }
    private var relaunchPending: Bool { !model.recording && relaunchPending(accessibility: accessibility, inputMonitoring: inputMonitoring) }

    /// The one main button. Setup has no way past Permissions but allowing them: closing the window is "later".
    private var continueTitle: String {
        if relaunchPending && (page == .permissions || page == .review) { return PermissionRequestActions.quitAndReopenTitle }
        if chromeCard && page == .permissions { return Self.doneTitle }
        guard page == .review else { return "Continue" }
        // Recording is already on (what's-new, or setup opened from the File menu): Done.
        if model.recording { return Self.doneTitle }
        switch startBlocker?.fix {
        case .permissions?: return "Allow Permissions"
        case .apps?: return "Review App Choices"
        default: return "Start Recording"
        }
    }
    static let doneTitle = "Done"

    private func show(_ next: DaydreamOnboardingPage) {
        guard !working else { return }
        error = nil
        route.show(next)
    }

    private func goBack() {
        guard let previous = page.previous else { return }
        show(previous)
    }

    private func proceed() {
        guard canContinue else { return }
        error = nil
        if relaunchPending && (page == .permissions || page == .review) { requests?.quitAndReopen?(); return }
        if preview {
            // Click-through only: no download, no save, no permission, no recording.
            switch page {
            case .permissions: show(.summaries)
            case .summaries: show(.apps)
            case .apps: show(.review)
            case .review: dismiss()
            }
            return
        }
        switch page {
        case .permissions:
            if chromeCard { finishChromeCard(); return }
            show(.summaries)
        case .summaries: continueSummaries()
        case .apps: saveApps()
        case .review:
            if model.recording { finish() }
            else if let fix = startBlocker?.fix { show(fix) }
            else { startRecording() }
        }
    }

    // MARK: Summaries

    /// Continue on Summaries. On this Mac: the download starts (or the model is checked) and the page moves on at once.
    /// OpenRouter: the key is tried here, with a spinner on Continue; a problem shows under the field with its one button
    /// and the page stays. An empty field (no key saved) leaves summaries off: the review says so, with Add Key.
    private func continueSummaries() {
        guard summariesAvailable else { show(.apps); return }
        cloudProblem = nil
        switch choice {
        case .local:
            guard writer.localOffered else { error = DaydreamSetupText.localUnavailable; return }
            // Already on, downloading or checking: nothing to start. A problem is tried again.
            if !SummaryPhaseReading.localOn(phase) || SummaryPhaseReading.problem(phase) != nil { SummaryControls.current.chooseLocal(writer) }
            show(.apps)
        case .cloud:
            if key.isEmpty && savedKey { show(.apps); return }
            guard key.utf8.count <= 4096, !key.contains("\n"), !key.contains("\r") else {
                error = "Enter an OpenRouter API key on a single line."
                return
            }
            if key.isEmpty && !keyKept {
                // No key: summaries are off (turning this row on turned the other off).
                if phase != .off { SummaryControls.current.turnOff(writer) }
                show(.apps)
                return
            }
            let secret = key
            working = true
            model.writerControlsBusy = true
            Task { @MainActor in
                let problem = await SummaryControls.current.chooseCloud(writer, secret)
                working = false
                model.writerControlsBusy = false
                if let problem {
                    cloudProblem = problem
                    if problem == .cloudKey { focusKey += 1 }
                } else {
                    key = ""
                    show(.apps)
                }
            }
        case .later:
            if phase != .off { SummaryControls.current.turnOff(writer) }
            show(.apps)
        }
    }

    /// A problem's one button under the key field: Change Key puts the cursor in the field; Add Credits opens OpenRouter;
    /// Try Again tries the key again.
    private func fixCloudProblem(_ problem: SummaryProblem) {
        switch problem {
        case .cloudKey: key = ""; focusKey += 1
        case .cloudCredits: NSWorkspace.shared.open(CloudSummariesText.creditsURL)
        default: continueSummaries()
        }
    }

    // MARK: Apps

    private var preferencesChangedElsewhere: Bool {
        baselineExclusions != Self.appIDs(model.blockedApps) || baselineTypedText != model.captureText || baselineChromePages != model.browserPages
    }

    private func toggleApp(_ id: String) {
        if preview { if exclusions.contains(id) { exclusions.remove(id) } else { exclusions.insert(id) }; return }
        guard !PrivacySettings.sensitiveApps.contains(id), !working, model.preferencesAvailable else { return }
        if exclusions.contains(id) { exclusions.remove(id) } else { exclusions.insert(id) }
    }

    /// The page's own edits: choices that differ from what it read, the switches from what they were set to, so an
    /// untouched page is not an edit.
    private var pageEdited: Bool {
        exclusions != baselineExclusions || typedText != seedTypedText || chromePages != seedChromePages || messages != seedMessages
    }

    /// Sets both switches from the saved choices the way setup opens: on unless explicitly turned off.
    private func seedSwitches() {
        let seeds = Self.seeds(model)
        typedText = seeds.typing
        chromePages = seeds.chrome
        seedTypedText = typedText
        seedChromePages = chromePages
        messages = Self.savedMessages(model)
        seedMessages = messages
    }

    /// The saved choices changed in another window (or through `mac-mem`) after this page read them.
    private var savedChoicesMoved: Bool { preferencesChangedElsewhere || !model.onboardingPreferencesCurrent }

    /// What stops this page saving, with its one fix: a change that didn't save, or saved choices that changed
    /// elsewhere while this page has edits of its own (so no edit is ever silently rebased). Without edits the page
    /// just takes the saved choices (`settleUneditedChoices`) and nothing is shown.
    private var appsProblem: PreferenceProblem? {
        if let problem = model.preferenceProblem { return problem }
        if model.preferencesUnresolved { return nil } // A change waiting for its short save delay.
        return savedChoicesMoved && pageEdited ? .changedElsewhere : nil
    }

    /// Saved choices moved while the page has no edits of its own: show the saved choices, without a question.
    private func settleUneditedChoices() {
        guard available, !working, model.preferenceProblem == nil, !model.preferencesUnresolved,
              !pageEdited, savedChoicesMoved else { return }
        reloadChoices()
    }

    private func fixAppsProblem() {
        guard !working else { return }
        if model.preferenceProblem != nil { model.fixPreferenceProblem() }
        // Saved again, or the saved choices shown: this page starts again from them.
        if model.preferenceProblem == nil { reloadChoices() }
    }

    /// A Start control elsewhere asked for a page (`MemoryViewModel.setupStepForStart`). Permissions starts a
    /// fresh setup (it moves on by itself once both are allowed); "finish setup" leaves an open setup where it
    /// is; any other page is shown.
    private func applySetupRequest() {
        guard let request = model.setupRequest, !working else { return }
        model.setupRequest = nil
        switch request {
        // Setup already finished: once both are allowed, straight to the last page (the choices are kept).
        case .permissions: route = DaydreamOnboardingRoute(afterPermissions: completed && !whatsNew ? .review : .summaries)
        case .summaries: break
        default: show(request)
        }
    }

    /// Continue on Apps, also while recording (the same save Settings makes). The typing switch on sets typing up (its
    /// key) first, so a switch that says on is on; both switches are saved as the person's explicit choice.
    private func saveApps() {
        guard model.preferencesAvailable else {
            error = "Resolve local storage before saving app choices."
            return
        }
        settleUneditedChoices()
        model.saveWaitingChoices()
        guard appsProblem == nil, !model.preferencesUnresolved else { return }
        // fix/sx-all: typing on runs the one ON path (fix/typing-e2e `TypingModel.turnOn`) unless it already ran for this
        // choice, so an upgrader whose earlier build left typing set up with Messages and email off (or the switch off)
        // gets every category on with this one click, the same as a fresh install.
        if typedText && (!typing.setUp || (model.development == nil && (!model.captureText || model.setupChoicesRead().typing != .on))) {
            // The typing key couldn't be made (the Keychain refused it): typing stays off, and the switch says so with the
            // line (fix/setup-tweaks). Continue again saves it off; switched on again, Continue tries the key again.
            let ready = typing.turnOn() && typing.setUp
            typedText = DaydreamOnboardingTyping.switchAfterTurnOn(ready: ready, switchOn: typedText)
            guard ready else { error = TypingSettingsText.keyError; return }
            // turnOn's switch waits for its short save delay: the one save below takes it along (saveOnboardingPreferences,
            // or saveWaitingChoices), so this Continue lands with one save and one restart while recording.
        }
        // Messages and email, with typing on: saved when its switch moved (one click off, or on again). After turnOn, so
        // an untouched switch matches what turnOn left (on unless SetupChoices says off) and saves nothing.
        if DaydreamOnboardingMessages.mustSave(typedText: typedText, messages: messages, saved: typing.policy.categories.messagesAndEmail) {
            typing.setCategory(.messagesAndEmail, on: messages)
            guard !typing.saveFailed else { error = TypingSettingsText.notSaved; return }
        }
        let pages = chromePages && ReleaseFeatures.chromePageHistory
        if exclusions != baselineExclusions || typedText != model.captureText || pages != model.browserPages || model.onboardingTypingChoicePending {
            // Cloud summaries stay on through a privacy change (summaries/v3): the writer turns them on again itself.
            model.saveOnboardingPreferences(excluded: exclusions, typedText: typedText, browserPages: pages)
        } else {
            // fix/sx-all: turnOn saved the typing switch through the short save delay: it saves now, so one Continue
            // lands (one save, one restart while recording).
            model.saveWaitingChoices()
        }
        // The problem line says what didn't save and fixes it.
        guard !model.preferencesUnresolved else { return }
        model.recordSetupChoices(typing: typedText, chromePages: pages)
        baselineExclusions = Self.appIDs(model.blockedApps)
        baselineTypedText = model.captureText
        baselineChromePages = model.browserPages
        exclusions = baselineExclusions
        typedText = baselineTypedText
        chromePages = baselineChromePages
        seedTypedText = typedText
        seedChromePages = chromePages
        messages = Self.savedMessages(model)
        seedMessages = messages
        show(.review)
    }

    private func reloadChoices() {
        guard !working else { return }
        model.reloadPreferences()
        guard !model.preferencesUnresolved else { return }
        baselineExclusions = Self.appIDs(model.blockedApps)
        baselineTypedText = model.captureText
        baselineChromePages = model.browserPages
        exclusions = baselineExclusions
        seedSwitches()
        apps = LocalApp.includingMissing(apps.filter { !$0.path.isEmpty }, excluded: exclusions)
        error = nil
    }

    // MARK: Review

    /// Summaries, Typed text and Web pages in Chrome, one value each; each row is one click back to its page. Summaries
    /// says the state live (Downloading 1.2 of 2.7 GB, On this Mac, OpenRouter, Off or a problem); Off and a problem carry
    /// their one button.
    private var reviewRows: [DaydreamReviewRow] {
        [
            summariesRow,
            DaydreamReviewRow(id: "typing", title: "Typed text", value: typedText ? "On" : "Off", systemImage: "keyboard",
                              edit: { show(.apps) })
        ] + (ReleaseFeatures.chromePageHistory ? [
            DaydreamReviewRow(id: "chrome-pages", title: ChromePagesCard.title, value: chromePages ? "On" : "Off", systemImage: "globe",
                              edit: { show(.apps) })
        ] : [])
    }

    static let addKeyTitle = "Add Key"
    static let turnOnTitle = "Turn On"

    private var summariesRow: DaydreamReviewRow {
        let value = preview ? SummaryPhaseReading.localValue : SummaryPhaseReading.value(phase)
        var button: (title: String, action: () -> Void)?
        if !preview && summariesAvailable {
            switch phase {
            case .off:
                // A Mac that can't run the model (Intel, under 8 GB) is offered the key, never a Turn On that can't work.
                button = choice == .cloud || !writer.localOffered || !Self.macQualifies
                    ? (Self.addKeyTitle, { choice = .cloud; show(.summaries); focusKey += 1 })
                    : (Self.turnOnTitle, { show(.summaries) })
            case .failed(let problem):
                button = (problem.button, { reviewFix(problem) })
            default: break
            }
        }
        return DaydreamReviewRow(id: "summaries", title: "Summaries", value: value, systemImage: "text.alignleft",
                                 edit: button == nil ? { show(.summaries) } : nil, button: button)
    }

    private func reviewFix(_ problem: SummaryProblem) {
        switch problem {
        case .cloudKey, .noMemory: choice = .cloud; key = ""; show(.summaries); focusKey += 1
        case .cloudCredits: NSWorkspace.shared.open(CloudSummariesText.creditsURL)
        default: SummaryControls.current.retry(writer)
        }
    }

    /// Why recording can't start from the last page yet; nil when Start Recording starts it (or recording is on).
    private var startIssue: String? { startBlocker?.text }
    private var startBlocker: StartBlocker? { model.recording && !preview ? nil : prerequisite() }

    /// Why recording can't start, and where it is fixed: a setup page (`fix`, where Start Recording goes),
    /// Settings (`settings`), or nothing but waiting. Summaries never stand in the way.
    private struct StartBlocker {
        let text: String
        var fix: DaydreamOnboardingPage? = nil
        var settings = false
    }

    private func prerequisite() -> StartBlocker? {
        if preview { return StartBlocker(text: Self.previewNote) }
        if !available { return StartBlocker(text: "Recording is unavailable in this preview.") }
        if !model.preferencesAvailable { return StartBlocker(text: "Local storage must be available before recording.") }
        if model.preferencesUnresolved || preferencesChangedElsewhere || !model.onboardingPreferencesCurrent || exclusions != baselineExclusions || typedText != baselineTypedText || chromePages != baselineChromePages {
            return StartBlocker(text: "Review and save your app choices before recording.", fix: .apps)
        }
        if model.history.busy || model.backups.busy || model.backups.prepared != nil || model.replacementBusy {
            return StartBlocker(text: "Finish the current history, backup, or replacement operation first.")
        }
        if !MemoryViewModel.permissionsGranted() { return StartBlocker(text: "Allow Accessibility and Input Monitoring before recording.", fix: .permissions) }
        // The blocker in the words every other surface uses; Open Settings goes to the page that deals with it.
        if let blocker = model.resumeBlocker() { return StartBlocker(text: RecordingCopy.blocker(blocker), settings: true) }
        return nil
    }

    /// Start Recording: recording starts first, at once; summaries never hold it back (their state is on the review
    /// and the Today card with its one button).
    private func startRecording() {
        guard !working else { return }
        if let issue = startIssue { error = issue; return }
        let savedExclusions = baselineExclusions
        let savedTyping = baselineTypedText
        let savedChromePages = baselineChromePages
        working = true
        startTask = Task { @MainActor in
            defer { working = false; startTask = nil }
            do {
                let started = try await starter.start(operations: DaydreamOnboardingStartOperations(
                    validate: {
                        guard Self.appIDs(model.blockedApps) == savedExclusions, model.captureText == savedTyping, model.browserPages == savedChromePages else {
                            throw DaydreamOnboardingStartError.unavailable("Your app choices changed. Review them before starting.")
                        }
                        if let issue = prerequisite()?.text { throw DaydreamOnboardingStartError.unavailable(issue) }
                    },
                    startCapture: { model.startCapture(); model.refreshCaptureStatus(); return model.recording }
                ))
                if started { finish() }
            } catch is CancellationError {
                error = "Setup was canceled. Recording was not started."
            } catch let issue as DaydreamOnboardingStartError {
                // Start couldn't reach the keyboard and mouse: say so; the main button is now Quit & Reopen.
                error = model.inputNeedsReopen ? RecordingCopy.inputUnreachable : issue.localizedDescription
            } catch {
                self.error = DaydreamOnboardingStartError.captureDidNotStart.localizedDescription
            }
        }
    }

    /// Start Recording started it, or Done (recording already on): setup is finished for this version, and never opens by
    /// itself again. With Web pages in Chrome on, macOS's Automation question for Chrome comes now (or when Chrome first
    /// comes forward), once: macOS asks only while it hasn't been answered.
    private func finish() {
        guard !preview else { dismiss(); return }
        guard !model.preferencesUnresolved else { show(.apps); return }
        completed = true
        model.setupFinished()
        whatsNew = false
        model.askChromeAccessAfterSetup()
        dismiss()
    }

    // MARK: Google Chrome (a row on the Permissions card)

    /// The row: Chrome installed and not excluded, access not decided (or the row was already shown here). Never in Preview.
    private var chromeRowShown: Bool {
        guard available, !preview else { return false }
        return DaydreamOnboardingChromeRow.shown(release: ReleaseFeatures.chromePageHistory, installed: chromeInstalled,
                                                 chromeExcluded: model.chromeExcluded, answered: MemoryViewModel.chromeAnswered(model.chromeAccess),
                                                 reading: model.chromeAccess == .checking, latched: chromeRowLatched)
    }
    private var chromeRow: PermissionChromeRow? {
        guard chromeRowShown else { return nil }
        return PermissionChromeRow(icon: chromeIcon, access: model.chromeAccess, asked: chromeAsked,
                                   allow: { chromeRowLatched = true; chromeAsked = true; model.askChromeAccessInSetup() },
                                   openSettings: { model.openChromeAutomationSettings() })
    }
    private func latchChromeRow() { if chromeRowShown { chromeRowLatched = true } }
    /// As the card opens: whether Chrome is installed (and its icon), and a read of its access (never a question).
    private func readChrome() {
        guard available, !preview, ReleaseFeatures.chromePageHistory else { return }
        chromeInstalled = model.chromeInstalled
        if chromeInstalled, chromeIcon == nil,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ChromePageTarget.bundleID) {
            chromeIcon = NSWorkspace.shared.icon(forFile: url.path)
        }
        if chromeInstalled, !MemoryViewModel.chromeAnswered(model.chromeAccess) { model.checkChromeAccess() }
    }
    /// The Chrome card for an upgrade (`DaydreamChromeCard`): the Permissions card alone, with Done. A first setup still
    /// in progress has the row already, so the request only clears.
    private func applyChromeCard() {
        guard model.chromeCardRequested, !working else { return }
        model.chromeCardRequested = false
        guard completed, !whatsNew, !preview else { return }
        chromeCard = true
        chromeRowLatched = true
        route = DaydreamOnboardingRoute(afterPermissions: .review, advances: false)
        readChrome()
    }
    /// Done on the Chrome card: nothing else changes (setup was finished before); the window closes.
    private func finishChromeCard() {
        chromeCard = false
        dismiss()
    }

    // MARK: Permissions

    private func permissionChanged(_ accessibility: Bool, _ inputMonitoring: Bool) {
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
        guard !working else { return }
        latchChromeRow()
        route.permissionsChanged(accessibility: accessibility, inputMonitoring: inputMonitoring,
                                 relaunchPending: relaunchPending(accessibility: accessibility, inputMonitoring: inputMonitoring),
                                 waitsForChrome: DaydreamOnboardingChromeRow.holdsPage(shown: chromeRowShown, pressed: chromeAsked,
                                                                                       answered: MemoryViewModel.chromeAnswered(model.chromeAccess)))
    }

    /// fix/bugs7: an untouched summaries choice follows the writer's settled state (see `choiceTouched`).
    private func followPhase() {
        guard !choiceTouched, !working else { return }
        choice = Self.initialChoice(phase: phase, localOffered: writer.localOffered, qualifies: Self.macQualifies, cloudChosen: Self.cloudChosen(writer))
    }

    private func resetForReview() {
        guard !working else { return }
        whatsNew = model.setupIsWhatsNew
        route = DaydreamOnboardingRoute()
        choiceTouched = false
        choice = Self.initialChoice(phase: phase, localOffered: writer.localOffered, qualifies: Self.macQualifies, cloudChosen: Self.cloudChosen(writer))
        key = ""
        cloudProblem = nil
        baselineExclusions = Self.appIDs(model.blockedApps)
        baselineTypedText = model.captureText
        baselineChromePages = model.browserPages
        exclusions = baselineExclusions
        seedSwitches()
        query = ""
        error = nil
        chromeAsked = false
        chromeRowLatched = false
        chromeCard = false
    }

    private func refreshPermissions() {
        guard available else { return }
        let read = Self.readPermissions()
        permissionChanged(read.accessibility, read.inputMonitoring)
        model.refreshCaptureStatus()
    }

    private func showSettings(_ section: String) {
        guard !working else { return }
        model.settingsSection = section
        model.settingsPresented = true
        // Brings the one main window forward: openWindow(id:) always adds another, and every main window
        // shows the same Settings sheet.
        DaydreamMainWindow.show(openWindow)
    }

    /// The last page's line in DayDream Preview (its Start Recording only closes setup).
    static let previewNote = "Preview: nothing here is saved or recorded. Start Recording closes setup."
    /// The review page's link to Settings when something stops recording.
    static let openSettingsTitle = "Open Settings"

    /// The Settings page for a start issue: unsaved app choices go to Apps to remember, a history, backup or replacement
    /// operation (or a replacement to review) to Advanced; everything else (the download window, a blocker, storage) to
    /// the overview, whose status line says what stops recording and holds the one button that fixes it.
    static func settingsSection(for issue: String?) -> String {
        guard let issue else { return "General" }
        if issue.hasPrefix("Review and save your app choices") { return "Recording" }
        if issue.hasPrefix("Finish the current history, backup, or replacement operation") || issue == RecordingCopy.replacementReview { return "Advanced" }
        return "General"
    }

    private static func appIDs(_ value: String) -> Set<String> {
        Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }
}
