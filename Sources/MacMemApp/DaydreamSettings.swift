import SwiftUI
import MemoryCore
import MemoryUI

struct MemorySettings: View {
    @ObservedObject var model: MemoryViewModel
    @ObservedObject private var writer: WriterIntegration
    @Environment(\.openWindow) private var openWindow
    @State private var navigation: DaydreamSettingsNavigation
    @State private var forgettingRange = false
    private var page: DaydreamSettingsPage { navigation.page }

    /// The sheet's height for full pages (nil: the page's own, as in checks and renders). A page that fits its content
    /// (`DaydreamSettingsPage.fitsContent`) makes the sheet only as tall as its rows.
    private let height: CGFloat?

    init(model: MemoryViewModel, height: CGFloat? = nil) {
        self.model = model
        self.height = height
        writer = model.noteWriter
        _navigation = State(initialValue: DaydreamSettingsNavigation(section: model.settingsSection))
    }

    var body: some View {
        DaydreamSettingsFrame(title: page.title, back: page == .overview ? nil : back,
                              advanced: page == .overview ? { show(.advanced) } : nil, close: close) {
            if let unavailable = unavailableMessage {
                Text(unavailable).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                detail
            }
        }
        .frame(minWidth: 600, minHeight: fits ? nil : DaydreamSettingsLayout.minHeight)
        .frame(width: height == nil ? nil : DaydreamSettingsLayout.width, height: fits ? nil : height)
        .fixedSize(horizontal: false, vertical: fits)
    }

    /// This page is drawn at its own height (only when it isn't replaced by the unavailable line).
    private var fits: Bool { page.fitsContent && unavailableMessage == nil }

    private var unavailableMessage: String? {
        if model.recordingTrial && [.summaries, .connections, .history, .updates].contains(page) {
            return "\(page.title) is unavailable in this app build. Your current settings are unchanged."
        }
        if model.development != nil && [.summaries, .connections, .history, .updates].contains(page) {
            return "This action is unavailable in the developer preview."
        }
        return nil
    }

    @ViewBuilder private var detail: some View {
        switch page {
        case .overview:
            DaydreamSettingsOverviewHost(model: model, select: show)
        case .permissions:
            DaydreamSettingsScroll { DaydreamSettingsPermissions(model: model) }
        case .summaries:
            // r2: no initialMode here. The Cloud summaries switch shows the real mode (on only while cloud is on), never
            // "on" with a key field while summaries are off (a build without the local model used to open that way).
            WriterPreferences(writer: writer, mayChange: {
                model.development == nil && !model.history.busy && !model.backups.busy &&
                model.backups.prepared == nil && !model.replacementBusy && !model.writerControlsBusy
            }, controlBusy: { model.writerControlsBusy = $0 }, available: model.development == nil)
        case .apps:
            DaydreamSettingsScroll { DaydreamAppSettings(model: model) }
        case .connections:
            ConnectionSettings(model: model.connection)
        case .advanced:
            advanced
        case .updates:
            SettingsSurface("App updates") { SettingsCard { UpdateSettings(updates: model.updates) } }
        case .history:
            MemoryHistorySettings(flow: model.history)
        case .backup:
            BackupSettingsView(model: model.backups)
        }
    }

    /// Advanced (declutter): Import, Backup and Updates; the rename move's notice and the recorder
    /// replacement only when they apply; a retention line only when history expires; Uninstall DayDream….
    /// The old Privacy, Recording requirements and Diagnostics pages are gone: their facts are in PRIVACY.md,
    /// the Permissions, Apps and Connections pages, and Help › Report a Problem. Recording controls are in the
    /// toolbar, the Recording menu and the menu bar; File › Set Up DayDream… reopens setup.
    private var advanced: some View {
        MacMemSetupView(pause: { model.pauseCapture("Paused for uninstall") },
            replacement: AnyView(ReplacementControls(model: model)), canUninstall: {
                do { return try !model.replacementBusy && (model.replacement?.record().map { $0.phase == "rolled_back" } ?? true) }
                catch { return false }
            }, replacementInProgress: model.replacementNeedsReview,
            // The developer preview can't uninstall: the sheet then says nothing can be removed.
            uninstaller: model.development == nil ? DaydreamUninstaller(model: model) : nil, legacyMove: DaydreamLaunchSession.legacyMove,
            links: AnyView(VStack(alignment: .leading, spacing: 14) {
                // Open at login: one switch, no subtext (owner, test 5). Only for the app in Applications.
                if model.openAtLoginAvailable {
                    SettingsCard {
                        Toggle(isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) })) {
                            Text(Self.openAtLoginTitle).font(.system(size: 13))
                        }
                        .toggleStyle(ReferenceToggleStyle()).frame(minHeight: 36)
                        .accessibilityIdentifier("settings-open-at-login")
                    }
                }
                // Forget a time range (the privacy control that was asked for here): its own sheet over Settings.
                if model.activity.canForgetRange {
                    SettingsListCard {
                        LinkRow(ForgetRangeText.menuTitle, area: .module(.retention)) { forgettingRange = true }
                            .accessibilityIdentifier("settings-forget-range")
                    }
                }
                SettingsListCard {
                    LinkRow(Self.importHistoryTitle, area: .summaries) { importHistory() }
                    LinkRow(DaydreamSettingsPage.backup.title, area: .module(.backup)) { show(.backup) }
                    LinkRow(DaydreamSettingsPage.updates.title, area: .module(.updates)) { show(.updates) }
                    // Fabricated examples: a developer-preview tool, never in the shipped app's Settings.
                    if model.development != nil {
                        #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
                        LinkRow("Open synthetic preview", area: .module(.diagnostics)) { openWindow(id: "demo") }
                        #endif
                    }
                }
            }),
            retention: AdvancedText.retention(days: model.retention))
        .forgetRangeSheet(browser: model.activity, isPresented: $forgettingRange)
    }

    private func show(_ next: DaydreamSettingsPage) {
        navigation.show(next)
    }

    /// Advanced's import row: it opens the file picker itself (declutter), so importing is one click.
    static let importHistoryTitle = "Import History…"
    /// Advanced's one switch (`MemoryViewModel.setOpenAtLogin`).
    static let openAtLoginTitle = "Open at login"

    /// The History page opens only when there is something to see there: an import already running or waiting
    /// for review, a preview to check, or a message (a refusal or a failure). A cancelled picker stays on
    /// Advanced. Where importing is unavailable (the recording trial, the developer preview) the page says so.
    private func importHistory() {
        let flow = model.history
        guard !model.recordingTrial, model.development == nil, !flow.busy, flow.session == nil else { show(.history); return }
        flow.choose()
        if flow.busy || flow.session != nil || flow.status != MemoryFlows.pickerCancelled { show(.history) }
    }

    private func back() { navigation.back() }

    private func close() {
        model.settingsSection = "General"
        model.settingsPresented = false
    }
}

/// The overview with its live status line (plan §5 A5): the recording state and the rows' values.
/// Nothing here prompts or writes; the status line's button (Start or Resume Recording, Allow… for
/// DayDream's drag cards on Permissions, a page, the Applications folder) and Learn more run only when pressed.
private struct DaydreamSettingsOverviewHost: View {
    @ObservedObject var model: MemoryViewModel
    @ObservedObject private var activity: ActivityBrowser
    @ObservedObject private var connection: ConnectionSettingsModel
    let select: (DaydreamSettingsPage) -> Void
    @Environment(\.openWindow) private var openWindow
    /// FileVault's state, read once when the overview appears (nil until read, or when the read fails:
    /// the privacy line then leaves FileVault out; it asks for FileVault only when it reads as off).
    @State private var fileVaultOn: Bool?

    init(model: MemoryViewModel, select: @escaping (DaydreamSettingsPage) -> Void) {
        self.model = model
        activity = model.activity
        connection = model.connection
        self.select = select
    }

    var body: some View {
        let status = snapshot
        DaydreamSettingsOverview(status: status, rows: rows(status), calendar: activity.calendar,
            select: select,
            act: { action in
                switch action {
                // Start goes through setup when something there must be done first (the setup window opens at that step).
                case .start, .resume: model.requestStart { openWindow(id: "onboarding") }
                case .openApplications: model.openApplicationsAction?()
                case .open(let page): select(page)
                case .retry: model.retryIssue()
                }
            },
            learnMore: { NSWorkspace.shared.open(PrivacyPromise.policyURL) },
            fileVaultOn: fileVaultOn)
            .task { if fileVaultOn == nil { fileVaultOn = await FileVaultStatus.current() } }
    }

    private var snapshot: SettingsStatusSnapshot {
        let presentation = model.presentation
        let connections = connection.phaseLabel
        return SettingsStatusSnapshot(state: presentation.state, issue: presentation.issue,
            permissions: presentation.permissions, summaries: activity.summaries, exclusions: activity.exclusions,
            connections: connections == "Not connected" ? nil : connections, canResume: presentation.canResume)
    }

    /// The Apps row counts only a policy that was read and saved: before the store's policy is
    /// available, or while a change is unsaved, the row shows no accessory instead of a guessed
    /// "None excluded".
    private func rows(_ status: SettingsStatusSnapshot) -> SettingsRowsSnapshot {
        var rows = SettingsRowsSnapshot(status)
        if !model.preferencesAvailable || model.preferencesUnresolved { rows.exclusions = nil }
        return rows
    }
}

private struct DaydreamAppSettings: View {
    @ObservedObject var model: MemoryViewModel
    @ObservedObject private var connection: ConnectionSettingsModel
    @State private var apps: [LocalApp] = []
    @State private var loaded = false
    @State private var query = ""
    /// Which of the page's rows are open, kept while DayDream runs (owner decision 2026-10-03).
    @ObservedObject private var expansion = SettingsExpansion.session

    init(model: MemoryViewModel) {
        self.model = model
        connection = model.connection
    }

    private var excluded: Set<String> {
        Set(model.blockedApps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
                // A change that didn't save: one sentence and the one button that fixes it.
                if let problem = model.preferenceProblem {
                    ChoiceProblemLine(text: problem.text, buttonTitle: problem.buttonTitle, action: model.fixPreferenceProblem)
                } else if !model.preferencesAvailable {
                    Text("App choices are unavailable until safe saving is ready.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let notice = model.preferenceNotice { ChoiceNoticeLine(text: notice) }
                // A save here (the app list, the typing switch, Web pages in Chrome) stops recording while it saves and
                // starts it again after (MemoryViewModel.resumeAfterSave); one that shares more turns every AI app's key
                // off (hiding more keeps them). The apps that lost theirs get one line and one Reconnect; approval stays
                // a click by the person. The Typing card's other choices (TypingModel) do neither.
                if model.aiAppsDisconnected, !disconnected.isEmpty {
                    ChoiceNoticeLine(text: MemoryViewModel.aiAppsDisconnectedLine(disconnected.map(\.app.name)),
                                     buttonTitle: disconnected.contains { $0.running != nil } ? "Reconnect & Restart" : "Reconnect",
                                     action: reconnect)
                        .disabled(!connection.enabled(.connect))
                }
                // Owner decision 2026-10-03: the app list stays in sight; under it, "Web pages in Chrome" and "Remember what
                // you type" are each a title row with its switch, and a click on the row opens that row's own settings
                // (remembered while DayDream runs, SettingsExpansion).
                SettingsAppsContent(apps: apps, excluded: excluded, query: $query,
                    typedText: model.typingPreference, loaded: loaded,
                    enabled: model.preferencesAvailable, allowTyping: model.development == nil,
                    // A release without Chrome page history (ReleaseFeatures) hides the card entirely.
                    browserPages: model.browserPagesSaved, chromePages: ReleaseFeatures.chromePageHistory ? AnyView(chromePages) : nil,
                    typing: AnyView(DaydreamTypingSettings(model: model, expanded: expansion.binding(.typing))),
                    toggle: toggleApp)
        }.padding(4)
        // The launch notice has been seen once this page closes.
        .onDisappear { model.preferenceNoticeSeen() }
        .task {
            guard !loaded else { return }
            let usage = await model.recentUsage()
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            let catalog = await Task.detached(priority: .utility) { LocalApp.catalog() }.value
            guard !Task.isCancelled else { return }
            apps = LocalApp.ranked(LocalApp.includingMissing(catalog, excluded: excluded), usage: usage, running: running)
            loaded = true
        }
        .onChange(of: model.blockedApps) { _ in
            apps = LocalApp.includingMissing(apps, excluded: excluded)
        }
        .onAppear { if model.aiAppsDisconnected { connection.refresh() } }
    }

    /// AI apps whose key a save turned off (this run), still on this Mac.
    private var disconnected: [ConnectionSettingsModel.Row] {
        connection.rows.filter { $0.installed && $0.state == .needsAttention(.keyStopped) }
    }

    /// Reconnect: Connect for each, one after another (a running app quits and opens again, as on Connections).
    private func reconnect() {
        let apps = disconnected.map(\.app)
        Task { for app in apps { await connection.connect(app) } }
    }

    /// "Web pages in Chrome". Allow… is the only way to the macOS prompt (`allowChromeAccess`); the card
    /// itself only reads access (`checkChromeAccess`, no prompt).
    private var chromePages: some View {
        ChromePagesCard(on: model.browserPagesPreference, savedOn: model.browserPagesSaved, access: model.chromeAccess, chromeExcluded: model.chromeExcluded,
                        sites: model.savedSites,
                        enabled: model.preferencesAvailable && model.development == nil && !model.preferencesUnresolved,
                        // The page says why above (the problem line, or that choices are unavailable); the card adds no second reason.
                        unavailableNote: false, emailSubjects: model.emailSubjectsPreference, expanded: expansion.binding(.chromePages),
                        add: { try model.addSite($0) }, remove: { try model.removeSite($0) },
                        allow: { model.allowChromeAccess() }, openSystemSettings: { model.openChromeAutomationSettings() },
                        checkAccess: { model.checkChromeAccess() })
    }

    private func toggleApp(_ id: String) {
        guard model.preferencesAvailable, !PrivacySettings.sensitiveApps.contains(id) else { return }
        var next = excluded
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        model.exclusionPreference.wrappedValue = next.sorted().joined(separator: ", ")
    }
}

/// Settings ▸ Apps to remember ▸ Typing, on the app model. The switch is the saved typing
/// preference (`captureText`, saved like every app choice, which stops recording while it saves);
/// "Turn on typing", the categories, the kept period, summaries and Forget act on the typed
/// settings through `TypingModel`. Nothing here reads the Keychain: the key's place comes from the
/// key store the app made at launch, and only while the vault is ready.
struct DaydreamTypingSettings: View {
    @ObservedObject var model: MemoryViewModel
    @ObservedObject private var typing: TypingModel
    /// Settings' open/closed row; nil shows every setting.
    private let expanded: Binding<Bool>?

    init(model: MemoryViewModel, expanded: Binding<Bool>? = nil) {
        self.model = model
        self.expanded = expanded
        _typing = ObservedObject(wrappedValue: model.typing)
    }

    var body: some View {
        TypingSettingsCard(values: Self.values(model: model, typing: typing), actions: Self.actions(model: model, typing: typing), expanded: expanded)
            .onAppear { typing.refresh() }
    }

    static func values(model: MemoryViewModel, typing: TypingModel, keyPlace: TypedKeyPlace? = KeychainTypedKeyStore.currentPlace) -> TypingSettingsValues {
        TypingSettingsValues(switchOn: model.captureText, policy: typing.policy, vault: typing.vault, keyLost: typing.keyLost,
                             keyPlace: typing.vault == .ready ? keyPlace : nil, shortcut: shortcut(typing.hotkey),
                             setupFailed: typing.setupFailed, saveFailed: typing.saveFailed,
                             enabled: model.development == nil && model.preferencesAvailable && typing.attached)
    }

    /// The pause shortcut row: nil when no shortcut is registered in this process.
    static func shortcut(_ status: TypingHotkeyStatus) -> TypingSettingsValues.Shortcut? {
        guard let chord = status.chord else { return nil }
        let message: String?
        switch status {
        case .taken: message = TypingSettingsText.shortcutTaken
        case .failed: message = TypingSettingsText.shortcutFailed
        case .registered, .notInstalled: message = nil
        }
        return .init(choices: TypingPauseChord.allCases.map(\.display), selected: TypingPauseChord.allCases.firstIndex(of: chord) ?? 0, message: message)
    }

    static func actions(model: MemoryViewModel, typing: TypingModel) -> TypingSettingsActions {
        TypingSettingsActions(
            // fix/typing-e2e: the switch is an explicit choice (SetupChoices); on is the one ON path, which also saves
            // the switch on (TypingModel.saveSwitch), off is remembered and saved off.
            setSwitch: { on in if on { typing.turnOn() } else { typing.turnOff() } },
            turnOn: { _ = typing.turnOn() },
            setCategory: { typing.setCategory($0, on: $1) },
            setOtherWebsites: { typing.setOtherWebsites($0) },
            needsConfirmation: { typing.needsConfirmation($0) },
            setRetention: { _ = typing.setRetention($0, confirmed: $1) },
            pause: { _ = try? typing.snooze(frontmostBundle: typing.frontmostBundle()) },
            resume: { try? typing.resume(frontmostBundle: typing.frontmostBundle()) },
            // Forget also turns the saved typing switch off (the confirmation says so): consent is gone, so
            // a switch left on would only show a lock in the menu with no way to turn it off here.
            forget: { if typing.forget() && model.captureText { typing.turnOff() } },
            chooseShortcut: { index in
                guard TypingPauseChord.allCases.indices.contains(index) else { return }
                typing.choose(TypingPauseChord.allCases[index])
            },
            retryUnlock: { typing.retryUnlock() })
    }
}

/// Settings › Permissions (owner, 10/2): Accessibility and Input Monitoring, and Google Chrome as a row like them whenever
/// Chrome is installed (recording Chrome is on by default). Allow is the app's one ask path (`allowChromeAccess`), only on
/// a press; access granted turns "Save web pages in Google Chrome" on. Allowed with that off: one Turn On.
struct DaydreamSettingsPermissions: View {
    @ObservedObject var model: MemoryViewModel
    @State private var installed = false
    @State private var icon: NSImage?
    @State private var pressed = false

    var body: some View {
        PermissionGrantView(enabled: model.development == nil, embedded: true, style: .settings, chromeRow: chromeRow)
            .onAppear(perform: read)
    }

    private var chromeRow: PermissionChromeRow? {
        guard model.development == nil, DaydreamChromeGrant.settingsRowShown(release: ReleaseFeatures.chromePageHistory, installed: installed) else { return nil }
        return PermissionChromeRow(icon: icon, access: model.chromeAccess, asked: pressed,
                                   allow: { pressed = true; model.allowChromeAccess() },
                                   openSettings: { model.openChromeAutomationSettings() },
                                   pagesOn: model.browserPages, turnOn: { model.setBrowserPages(true) }, settings: true)
    }

    /// Whether Chrome is installed (and its icon), and a read of its access: never a question.
    private func read() {
        guard model.development == nil, ReleaseFeatures.chromePageHistory else { return }
        installed = model.chromeInstalled
        guard installed else { return }
        if icon == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ChromePageTarget.bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        model.checkChromeAccess()
    }
}
