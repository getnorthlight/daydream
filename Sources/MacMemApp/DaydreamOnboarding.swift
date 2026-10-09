import SwiftUI
import ApplicationServices
import CoreGraphics
import MemoryCore
import MemoryUI
import WriterBackend

/// Setup (owner, 9/28): forced and proper, and every page works while recording.
/// - A first setup: Permissions, Apps, then Connect your AI (`.review`, owner 10/5: the AI apps on this Mac
///   with Connect, as in Settings › Connections), whose Start Recording starts recording at once. The
///   Permissions card has a Google Chrome row while Chrome is installed and its access isn't decided
///   (`DaydreamOnboardingChromeRow`, owner 10/2); its Allow asks macOS on the press, and it never holds Continue.
/// - Once, for someone who finished setup before that row (`DaydreamChromeCard`): the Permissions card alone, with Done.
/// - After an update from a test build whose setup was finished before version 2 (`DaydreamSetupVersion`): the short
///   "What's new", from Apps (Permissions only while one is missing), then the review with Done.
/// claude/setup-local-summaries (owner 10/7): setup has no summaries page. Once a first setup is past Permissions,
/// summaries on this Mac start by themselves for someone who never chose (`WriterIntegration.chooseLocalByDefault`: a
/// Mac that can run the model, 5 GB free or more): the download runs in the background, silently, and the writer turns
/// summaries on once the model is verified, even if this window closes. A choice already made (OpenRouter, on this Mac,
/// or off) is never touched. OpenRouter, and turning summaries on or off later, are in Settings › Summarizer.
/// Typing and Web pages in Chrome are on unless the person turned them off (`SetupChoices`); Continue on Apps saves both.
struct DaydreamOnboarding: View {
    @ObservedObject var model: MemoryViewModel
    @ObservedObject private var writer: WriterIntegration
    @ObservedObject private var typing: TypingModel
    /// The last page's Connect rows: the same model as Settings › Connections.
    @ObservedObject private var connection: ConnectionSettingsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.daydreamPermissionRequests) private var requests
    @AppStorage("DaydreamOnboardingCompletedV1") private var completed = false
    @State private var route = DaydreamOnboardingRoute()
    /// The short what's-new for an upgrade (set as setup opens).
    @State private var whatsNew: Bool
    /// This setup already asked the writer for summaries on this Mac by default (once per opening).
    @State private var defaultSummariesAsked = false
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
    @State private var accessibility: Bool
    @State private var inputMonitoring: Bool
    /// claude/permflash-015: setup's own reads, settled like the app's (`PermissionSettle`) and starting from what the
    /// app last showed: a moment's "not allowed" as setup opens never leaves it on the Permissions page.
    @State private var shownPermissions: ShownPermissions
    /// The page to show is decided (setup's first reads ran). Until then the window draws no page: setup always opens
    /// on Permissions and moves on once both read allowed, and that first page was drawn for a frame before the read.
    @State private var opened = false
    @State private var settleReadSet = false
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
    /// Google Chrome is running (read as the card opens and when Chrome opens or quits): Allow opens it otherwise.
    @State private var chromeRunning = true
    /// When the row turned Allowed: the page moves on by itself only after it has shown that for a moment.
    @State private var chromeAllowedAt: Date?
    /// The Permissions card alone, once, for someone who finished setup before the Chrome row (`DaydreamChromeCard`).
    @State private var chromeCard = false
    /// rc-018 RC3 (A5): setup's first permission reads ran, so a permission that turns Allowed from now on is a grant made
    /// beside setup (`SetupFocus.handBack`).
    @State private var handBackArmed = false
    /// A8: the running System Settings opened before this copy was installed (`SystemSettingsAge`).
    @State private var settingsStale = false
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Both recording permissions, each read without a prompt. The checks stand in a read.
    static var readPermissions: () -> (accessibility: Bool, inputMonitoring: Bool) = { (AXIsProcessTrusted(), CGPreflightListenEventAccess()) }
    /// This Mac can run the model: Apple silicon with 8 GB of memory (`WriterCandidates.recommended`). Otherwise setup
    /// starts nothing (summaries stay off; Settings › Summaries turns them on or takes a key).
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
    init(model: MemoryViewModel) {
        self.model = model
        writer = model.noteWriter
        typing = model.typing
        connection = model.connection
        _whatsNew = State(initialValue: model.setupIsWhatsNew)
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
        let known = model.development == nil ? model.permissionSnapshot : PermissionSnapshot()
        _accessibility = State(initialValue: known.accessibility == true)
        _inputMonitoring = State(initialValue: known.inputMonitoring == true)
        _shownPermissions = State(initialValue: ShownPermissions(known: known, allowedBefore: model.permissionsAllowedBefore))
    }

    /// The saved Messages and email checkbox (on unless turned off); on in Preview.
    private static func savedMessages(_ model: MemoryViewModel) -> Bool {
        DaydreamOnboardingMessages.initialSwitch(saved: model.typing.policy.categories.messagesAndEmail,
                                                 preview: model.development?.preview == true)
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

    #if DEVELOPMENT_SOURCE_CHECKS
    /// What the page drew last (setup-upgrade-checks and the renders read it: offscreen SwiftUI text has no
    /// accessibility tree to read).
    struct Drawn {
        var page: DaydreamOnboardingPage
        var title: String
        var button: String
        var back: Bool
        /// The line at the top of the page (a problem Continue ran into), and the typing switch.
        var error: String?
        var typedText: Bool
        /// chromeask-1005: the Chrome row as drawn (its words and its button's own closures; chrome-ask-checks presses it).
        var chromeRow: PermissionChromeRow? = nil
        /// rc-018 RC3: the main button can be pressed; the reopen line under the cards; the stale-System-Settings line
        /// (A8) and its Quit button's own action.
        var canContinue = true
        var reopenLine = false
        var settingsLine: String? = nil
        var quitSettings: (() -> Void)? = nil
    }
    static var drawnForChecks: Drawn?
    /// claude/permflash-015: the page of every draw, in order; nil for a draw before the page was decided
    /// (permission-flash-checks: setup never draws Permissions on its way to another page).
    static var drawnPagesForChecks: [DaydreamOnboardingPage?] = []
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
        let _ = Self.drawnForChecks = Drawn(page: page, title: title, button: continueTitle, back: backAction != nil,
                                            error: error, typedText: typedText,
                                            chromeRow: page == .permissions ? chromeRow : nil, canContinue: canContinue,
                                            reopenLine: page == .permissions && relaunchPending && !model.permissionAutoRelaunch,
                                            settingsLine: page == .permissions && settingsStale && !permitted ? SystemSettingsAge.line : nil,
                                            quitSettings: page == .permissions && settingsStale && !permitted ? quitSettingsPressed : nil)
        let _ = Self.drawnPagesForChecks.append(opened ? page : nil)
        #endif
        // Before the page is decided (`opened`): the window and nothing on it.
        DaydreamOnboardingShell(
            title: opened ? title : "", subtitle: opened && page == .review ? Self.connectSubtitle : nil,
            back: opened ? backAction : nil,
            continueTitle: continueTitle,
            canContinue: opened && canContinue, working: working,
            // The icon opens setup; the apps and connect steps use its room for their controls.
            showsIcon: opened && page == .permissions,
            continueAction: proceed
        ) {
            if opened {
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(error)
                }
                pageContent
            }
        }
        // rc-018 RC3: setup's window for the focus policy (`SetupFocus`): its page, and after DayDream's own relaunch, its
        // saved frame and the one activation that puts it in front, key (rule 5).
        .background(WindowReader { window in
            SetupFocus.shared.setupShown(window, page: page, unfinished: !completed && !preview)
            SetupFocus.shared.placeAfterRelaunch(window)
        })
        .onAppear {
            resetForReview(); applyRelaunchPage(); applySetupRequest(); readChrome(); applyChromeCard(); refreshPermissions(); readSettingsAge()
        }
        .onChange(of: model.chromeCardRequested) { _ in applyChromeCard() }
        // A Start control elsewhere sent the person here (MemoryViewModel.requestStart).
        .onChange(of: model.setupRequest) { _ in applySetupRequest() }
        .onChange(of: page) { next in
            SetupFocus.shared.setupShown(nil, page: next, unfinished: !completed && !preview)
            settleUneditedChoices(); if next != .permissions { startDefaultSummaries() }
        }
        .onReceive(permissionTimer) { _ in refreshPermissions(); settleUneditedChoices(); readSettingsAge() }
        // rc-018 RC3 (rule 8): the read that coming to the front starts applies once the press that brought DayDream
        // forward is over, so the page never moves on (or a switch flips) under that click.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            SetupFocus.shared.afterMouseUp { refreshPermissions() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in readSettingsAge() }
        // The Chrome row, once shown, stays and shows its answer.
        .onChange(of: model.chromeAccess) { access in
            latchChromeRow()
            if access == .allowed, chromeRowShown, chromeAllowedAt == nil { chromeAllowedAt = Date() }
        }
        // chromeask-1005: back from System Settings (or anywhere): read Chrome's access again (a read, never a question),
        // so a switch turned on there shows Allowed here with no restart.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in rereadChrome() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in readChromeRunning() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in readChromeRunning() }
        // Typing switched on again after the key failed: the "typing stays off" line no longer matches the switch.
        .onChange(of: typedText) { on in if on && error == TypingSettingsText.keyError { error = nil } }
        .task { fileVaultOff = await FileVaultStatus.current() == false }
        .onDisappear {
            SetupFocus.shared.setupClosed()
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
                                dragHint: dragHintInitially, known: shownPermissions.snapshot, allowedBefore: model.permissionsAllowedBefore,
                                chromeRow: chromeRow, onStatusChange: permissionChanged, sideBySide: true)
            // Under the cards, never above them (rule 8): the reopen line while DayDream won't restart by itself (its
            // cooldown, or no restart allowed now), and System Settings opened before this copy was installed (A8).
            if relaunchPending && !model.permissionAutoRelaunch {
                Text(PermissionRelaunch.inputMonitoringTurnedOn.text).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if settingsStale && !permitted {
                HStack(spacing: 10) {
                    Text(SystemSettingsAge.line).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(SystemSettingsAge.quitTitle) { quitSettingsPressed() }
                        .font(.system(size: 12))
                }
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
            connectRows
                .disabled(!available || working)
                .onAppear { connection.pageAppeared() }
                .onDisappear { connection.pageDisappeared() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in connection.refresh() }
                .connectionAlerts(connection)
                // Usage counts: an AI app connected on this page (its id only), once per app per install.
                .onChange(of: connection.connects) { _, _ in
                    if let app = connection.lastConnected { UsageReport.setupStep("ai_connected", ["ai_app": .text(UsageReport.aiApp(app))]) }
                }
            // A blocker setup fixes is said by the button ("Allow Permissions"); only the others need a sentence.
            // claude/setup-local-summaries (owner 10/7): no Summaries row here; summaries are in Settings › Summaries.
            DaydreamReviewContent(message: startBlocker.flatMap { $0.fix == nil ? $0.text : nil },
                                  fileVaultOff: fileVaultOff, comeBack: !model.recording, aiReads: true)
            // Only what setup can't fix itself goes to Settings; Start Recording goes to every other fix.
            if let issue = startBlocker, issue.settings {
                Button(Self.openSettingsTitle) { showSettings(Self.settingsSection(for: issue.text)) }
                    .buttonStyle(.plain).font(.system(size: 12))
            }
        }
    }

    /// The AI apps on this Mac, each with its one button (Settings › Connections' rows). An app that isn't installed
    /// isn't listed; with none at all, the page says what DayDream works with and how to get one.
    @ViewBuilder private var connectRows: some View {
        if !connection.loaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
        } else if connection.visibleRows.isEmpty {
            DaydreamNoAIApps(getApp: { NSWorkspace.shared.open(Self.getClaudeURL) },
                             otherApp: { NSWorkspace.shared.open(Self.connectByHandURL) })
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let unavailable = connection.unavailable {
                    Label { Text(unavailable).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                DaydreamConnectCard {
                    ForEach(Array(connection.visibleRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        AIAppRow(row: row, model: connection)
                    }
                }
            }
        }
    }

    // MARK: Words

    static let whatsNewTitle = "What's new"
    static let connectTitle = "Connect your AI"
    static let connectSubtitle = "DayDream works inside the AI apps you already use."
    static let getClaudeURL = URL(string: "https://claude.ai/download")!
    static let connectByHandURL = URL(string: "https://github.com/getnorthlight/daydream/blob/main/docs/install.md#connect-an-ai-app-by-hand")!

    private var title: String {
        switch page {
        case .permissions: return "Turn on DayDream"
        // What's-new opens on Apps (it has no summaries choice since claude/setup-local-summaries).
        case .apps: return whatsNew ? Self.whatsNewTitle : "Apps to remember"
        case .review: return Self.connectTitle
        }
    }

    // MARK: Buttons

    /// Back, except on setup's first page (Permissions, or what's-new's Apps).
    private var backAction: (() -> Void)? {
        if page == .permissions { return nil }
        if whatsNew && page == .apps { return nil }
        return { goBack() }
    }

    private var canContinue: Bool {
        guard !working else { return false }
        if preview { return true }
        // rc-018 RC3 (A2): DayDream is about to restart itself: "Restarting…", disabled.
        if restarting { return false }
        if relaunchPending && (page == .permissions || page == .review) { return true }
        switch page {
        // The Chrome row never holds Continue; the Chrome card alone (permissions already settled) always has Done.
        case .permissions: return permitted || chromeCard
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
        if restarting { return Self.restartingTitle }
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
    /// rc-018 RC3 (A2): the main button while DayDream restarts itself.
    static let restartingTitle = "Restarting…"
    /// DayDream decided to restart itself (`MemoryViewModel.permissionAutoRelaunch`), in a real setup.
    private var restarting: Bool { available && !preview && model.permissionAutoRelaunch }
    /// A8: quits System Settings, only from the person's press (the checks stand in a counter).
    static var quitSystemSettings: () -> Void = { SystemSettingsRead.quit() }
    /// A8: when the running System Settings opened (nil: it doesn't run), and this app's install dates. The checks stand in.
    static var settingsLaunchDate: () -> Date? = { SystemSettingsRead.launchDate() }
    static var bundleDates: () -> [Date?] = { SystemSettingsAge.bundleDates(Bundle.main.bundleURL) }

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
        guard opened, canContinue else { return }
        error = nil
        if relaunchPending && (page == .permissions || page == .review) { requests?.quitAndReopen?(); return }
        if preview {
            // Click-through only: no download, no save, no permission, no recording.
            switch page {
            case .permissions: show(.apps)
            case .apps: show(.review)
            case .review: dismiss()
            }
            return
        }
        switch page {
        case .permissions:
            if chromeCard { finishChromeCard(); return }
            show(.apps)
        case .apps: saveApps()
        case .review:
            if model.recording { finish() }
            else if let fix = startBlocker?.fix { show(fix) }
            else { startRecording() }
        }
    }

    // MARK: Summaries

    /// claude/setup-local-summaries (owner 10/7): once a first setup is past Permissions, summaries on this Mac start by
    /// themselves for someone who never chose (the writer decides: `WriterIntegration.chooseLocalByDefault`, which never
    /// touches a choice already made and skips a Mac that can't run the model or has under 5 GB free). Silent: nothing on
    /// these pages changes, and no page shows the download (Settings › Summaries does). Never in what's-new, the
    /// Chrome card, a setup already finished, Preview or a trial.
    private func startDefaultSummaries() {
        guard !defaultSummariesAsked, available, !preview, summariesAvailable, !completed, !whatsNew, !chromeCard else { return }
        defaultSummariesAsked = true
        switch SummaryControls.current.chooseLocalByDefault(writer, Self.macQualifies) {
        case .started: UsageReport.setupStep("summaries_chosen", ["summaries": .text("local")])
        case .lowSpace, .unavailable: UsageReport.setupStep("summaries_chosen", ["summaries": .text("off")])
        case .waiting, .alreadyChosen: break
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
        case .permissions: route = DaydreamOnboardingRoute(afterPermissions: completed && !whatsNew ? .review : .apps)
        // Setup not finished yet: an open setup stays where it is.
        case .apps where !completed: break
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

    // MARK: Status

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
    /// itself again. chromeask-1005 (owner 10/5): nothing asks macOS about Chrome here or later; the Chrome row's Allow
    /// was the place (an unanswered row is the menu bar's "Chrome pages aren't being saved. Fix", which opens it again).
    private func finish() {
        guard !preview else { dismiss(); return }
        guard !model.preferencesUnresolved else { show(.apps); return }
        completed = true
        model.setupFinished()
        UsageReport.setupStep("setup_done")
        whatsNew = false
        // rc-018 RC3 (rule 1): the memory window appears now, in front.
        SetupFocus.shared.setupFinished()
        dismiss()
    }

    // MARK: Google Chrome (a row on the Permissions card)

    /// The row: Chrome installed and not excluded, access not decided (or the row was already shown here). Never in Preview.
    private var chromeRowShown: Bool {
        guard available, !preview else { return false }
        return DaydreamOnboardingChromeRow.shown(release: ReleaseFeatures.chromePageHistory, installed: chromeInstalled,
                                                 chromeExcluded: model.chromeExcluded, answered: MemoryViewModel.chromeAnswered(chromeAccess),
                                                 reading: chromeAccess == .checking, latched: chromeRowLatched)
    }
    /// chromeask-1005 (owner 10/5): before the press the row says what macOS will ask (with typing in mind while
    /// setup's typing switch is on) and, with Chrome closed, that Allow opens it in the background to ask.
    private var chromeRow: PermissionChromeRow? {
        guard chromeRowShown else { return nil }
        var row = PermissionChromeRow(icon: chromeIcon, access: chromeAccess, asked: chromeAsked,
                                      allow: { chromeRowLatched = true; chromeAsked = true; model.askChromeAccessInSetup() },
                                      openSettings: { model.openChromeAutomationSettings() },
                                      // Once pressed, the line under the row says what to do instead.
                                      typing: typedText, opensChrome: !chromeRunning && !chromeAsked,
                                      askAgain: { chromeRowLatched = true; chromeAsked = true; model.askChromeAgain() })
        row.disabled = restarting
        return row
    }
    /// rc-018 RC3 (A7, state audit #5): a first setup reads Chrome's access from macOS alone; an answer saved by an earlier
    /// install or copy never decides its row (a finished setup's Chrome card keeps the saved answer). macOS's answer in
    /// this launch does: a refusal made here keeps Ask again after Chrome closes.
    private var chromeAccess: ChromeAccessState { model.chromeRowAccess(lastAnswer: completed || model.chromeAnsweredThisLaunch) }
    private func readChromeRunning() {
        guard available, !preview, ReleaseFeatures.chromePageHistory, chromeInstalled else { return }
        chromeRunning = model.chromeRunning
    }
    /// A read of Chrome's access while the row shows anything but Allowed (never a question; nothing while macOS asks).
    private func rereadChrome() {
        readChromeRunning()
        guard chromeRowShown, model.chromeAccess != .allowed, model.chromeAccess != .checking else { return }
        model.checkChromeAccess()
    }
    private func latchChromeRow() { if chromeRowShown { chromeRowLatched = true } }
    /// Allowed, and (when it turned Allowed here) shown as Allowed for a moment, so the person sees it before the page
    /// moves on.
    private var chromeAllowedSeen: Bool {
        chromeAccess == .allowed && (chromeAllowedAt.map { Date().timeIntervalSince($0) >= 1.5 } ?? true)
    }
    /// chromeask-1005: the first read of Chrome's access is still running for an installed, recorded Chrome: the page
    /// doesn't move on by itself yet (with both permissions already allowed it did, before the row could show).
    private var chromeRowReading: Bool {
        available && !preview && ReleaseFeatures.chromePageHistory && chromeInstalled && !model.chromeExcluded && chromeAccess == .checking
    }
    /// As the card opens: whether Chrome is installed (and its icon), and a read of its access (never a question).
    private func readChrome() {
        guard available, !preview, ReleaseFeatures.chromePageHistory else { return }
        chromeInstalled = model.chromeInstalled
        readChromeRunning()
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
        // rc-018 RC3 (rule 8, A5): a change read while the left button is down applies once it is up (at most 300 ms), so
        // the page never moves on to Apps under a click (a Toggle there would flip).
        if available && !preview && SetupFocus.shared.mouseDown() {
            SetupFocus.shared.afterMouseUp { applyPermissionChange(accessibility, inputMonitoring) }
            return
        }
        applyPermissionChange(accessibility, inputMonitoring)
    }
    private func applyPermissionChange(_ accessibility: Bool, _ inputMonitoring: Bool) {
        // A5: a permission turned Allowed beside setup (System Settings in front, no sheet): setup comes back, key, once.
        if handBackArmed && available && !preview {
            let reopen = relaunchPending(accessibility: accessibility, inputMonitoring: inputMonitoring)
            // Held back by a closing password window, a sheet or System Settings not in front yet: it waits for that to
            // clear while the permission still reads Allowed (review 10/9).
            if accessibility && !self.accessibility {
                SetupFocus.shared.handBack("accessibility", needsReopen: reopen, stillAllowed: { Self.readPermissions().accessibility })
            }
            if inputMonitoring && !self.inputMonitoring {
                SetupFocus.shared.handBack("inputMonitoring", needsReopen: reopen, stillAllowed: { Self.readPermissions().inputMonitoring })
            }
        }
        handBackArmed = true
        // Usage counts: each permission allowed during setup, once per install (UsageReport.setupStep).
        if available && !preview {
            if accessibility { UsageReport.setupStep("accessibility_allowed") }
            if inputMonitoring { UsageReport.setupStep("input_monitoring_allowed") }
        }
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
        guard !working else { return }
        latchChromeRow()
        route.permissionsChanged(accessibility: accessibility, inputMonitoring: inputMonitoring,
                                 relaunchPending: relaunchPending(accessibility: accessibility, inputMonitoring: inputMonitoring),
                                 waitsForChrome: DaydreamOnboardingChromeRow.holdsPage(shown: chromeRowShown || chromeRowReading,
                                                                                       allowed: chromeAllowedSeen))
    }

    /// rc-018 RC3 (rule 5): DayDream's own relaunch from setup goes back to the page it was on (Permissions moves on to
    /// Apps by itself once both are allowed).
    private func applyRelaunchPage() {
        guard let saved = SetupFocus.shared.takeRelaunchPage(), saved != .permissions, !working else { return }
        route = DaydreamOnboardingRoute(afterPermissions: saved)
    }
    /// A8: the person pressed Quit beside "Quit System Settings and open it again.".
    private func quitSettingsPressed() { Self.quitSystemSettings(); readSettingsAge() }
    /// A8: whether the running System Settings opened before this copy of DayDream was installed or replaced.
    private func readSettingsAge() {
        guard available, !preview else { return }
        let stale = SystemSettingsAge.stale(settingsLaunched: Self.settingsLaunchDate(), bundleDates: Self.bundleDates())
        if stale != settingsStale { settingsStale = stale }
    }

    private func resetForReview() {
        guard !working else { return }
        whatsNew = model.setupIsWhatsNew
        route = DaydreamOnboardingRoute()
        defaultSummariesAsked = false
        baselineExclusions = Self.appIDs(model.blockedApps)
        baselineTypedText = model.captureText
        baselineChromePages = model.browserPages
        exclusions = baselineExclusions
        seedSwitches()
        query = ""
        error = nil
        chromeAsked = false
        chromeRowLatched = false
        chromeAllowedAt = nil
        chromeCard = false
    }

    private func refreshPermissions() {
        guard available else { opened = true; return }
        let read = Self.readPermissions()
        var next = shownPermissions
        let shown = next.read(PermissionSnapshot(accessibility: read.accessibility, inputMonitoring: read.inputMonitoring), at: Date())
        if next != shownPermissions { shownPermissions = next }
        // Before the first page is decided, an off read still waiting to hold (someone who finished setup: it may be a
        // moment's "not allowed", or a permission really turned off as setup opens) decides nothing: no page is drawn
        // until a read says allowed or the off read has held, read again shortly. Deciding on what showed before would
        // move a really-off setup past Permissions, and nothing brings it back.
        if opened || (!next.unsettled && shown.accessibility != nil && shown.inputMonitoring != nil) {
            permissionChanged(shown.accessibility == true, shown.inputMonitoring == true)
            opened = true
        } else if !settleReadSet {
            settleReadSet = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settleReadSet = false; if !opened { refreshPermissions() } }
        }
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
