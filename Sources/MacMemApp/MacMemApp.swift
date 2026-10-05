import SwiftUI
import Combine
import MemoryCore
import MemoryUI
import WriterBackend

@MainActor final class MemoryViewModel: ObservableObject {
    let updates=Updates()
    let noteWriter:WriterIntegration
    let activity = ActivityBrowser(phase:.loading)
    let connection:ConnectionSettingsModel
    let development:DevelopmentTrial?
    let recordingTrial:Bool
    let functionalTrial:Bool
    @Published var trialStartedAt:Date?
    @Published var nativeCommitReceipt:NativeCaptureReceipt?
    /// Its look for a paused import runs once this app knows it holds the history (init, after the recorder lock check).
    let history=MemoryFlows(home:MemPaths.home(),recoverNow:false)
    let backups=BackupSettingsModel(home:MemPaths.home())
    /// The typing indicator and settings (menu and Settings read it).
    let typing=TypingModel()
    /// Typed words past the kept period are deleted at launch and hourly.
    private var typedExpiry:TypedTextExpiryTimer?
    /// claude/summary-1003 (owner decision 2026-10-03): carries typed words to connected AI apps while "Let AI apps
    /// read what you typed" is on (`AssistantTypedBridge`); the setting and the AI app's key are checked per request.
    private var aiReadBridge:AssistantTypedBridgeServer?
    @Published var writerControlsBusy=false
    @Published var settingsPresented=false
    var settingsSection="General"
    @Published private var summaryJobs=0
    @Published var items: [MemoryItem] = []
    @Published var query = ""
    @Published var status = "Capture OFF. Local memory."
    @Published var recording = false
    @Published var captureText = false
    @Published var privacySaveStatus=""
    @Published var searchIndexingLine:String?
    @Published var searchBackendStatus="SQLite fallback"
    private var preferenceSave:PreferenceAutosave?
    private var productionSearch:AppSearchBinding?
    var preferencesAvailable:Bool {preferenceSave != nil}
    var preferenceConflict:Bool {preferenceSave?.error == .revisionConflict}
    var preferencesUnresolved:Bool {privacyDirty || preferenceSave?.draft != nil || preferenceSave?.error != nil}
    /// A change that didn't save, in one sentence, and its one fix (PreferenceProblem.swift); nil while nothing
    /// stands. A change still waiting for its short save delay is not one: Start saves it first.
    var preferenceProblem:PreferenceProblem? {
        guard let preferenceSave else {return nil}
        return PreferenceProblem.make(error:preferenceSave.error,differsFromSaved:privacyDirty,waiting:preferenceSave.draft != nil)
    }
    /// Saves a change still waiting for its short save delay now. A failed save stays failed (its problem shows).
    func saveWaitingChoices() {
        if preferenceSave?.draft != nil,preferenceSave?.error == nil {preferenceSave?.flush()}
    }
    /// The problem's one button: saves the same change again, or shows the saved choices.
    func fixPreferenceProblem() {
        guard let problem=preferenceProblem else {return}
        switch problem.fix {
        case .saveAgain: if preferenceSave?.draft != nil {preferenceSave?.flush()} else {savePolicy()}
        case .useSaved,.undo: reloadPreferences()
        }
    }
    /// Choices an older version saved that this one had to turn off or drop at launch (LegacyPreferences.swift),
    /// in one line. Kept until the person has seen it on an Apps page.
    @Published private(set) var preferenceNotice:String?
    static let preferenceNoticeKey="DaydreamPreferenceNoticeV1"
    var typingPreference:Binding<Bool> {Binding(get:{self.captureText},set:{value in
        guard self.development == nil else {return}
        self.captureText=value;self.queuePreferences()
    })}
    var exclusionPreference:Binding<String> {Binding(get:{self.blockedApps},set:{value in
        self.blockedApps=value;self.queuePreferences()
    })}
    /// "Web pages in Chrome" (the draft; the saved switch is `browserPagesSaved`).
    var browserPagesPreference:Binding<Bool> {Binding(get:{self.browserPages},set:{self.setBrowserPages($0)})}
    /// email-1003: "Save email subjects" (the draft; saved through `queuePreferences` like the Chrome switch).
    var emailSubjectsPreference:Binding<Bool> {Binding(get:{self.emailSubjects},set:{value in
        guard self.development == nil else {return}
        self.emailSubjects=value;self.queuePreferences()
    })}
    @Published private var savedPrivacy=PrivacySettings()
    var privacyDirty:Bool {
        captureText != savedPrivacy.typingOn || blockedApps != savedPrivacy.blockedApps.joined(separator:", ") || blockedDomains != savedPrivacy.blockedDomains.joined(separator:", ") || retention != savedPrivacy.retentionDays
            || browserPages != savedPrivacy.browserPagesOn || emailSubjects != savedPrivacy.emailSubjects
    }
    /// Chrome page history: the saved switch, and the owner's own "Sites not recorded".
    var browserPagesSaved:Bool {savedPrivacy.browserPagesOn}
    /// Google Chrome itself is excluded: nothing is saved from it, whatever the switch says.
    var chromeExcluded:Bool {savedPrivacy.blockedApps.contains(ChromePageTarget.bundleID)}
    var savedSites:[String] {savedPrivacy.blockedDomains}
    @Published var selected: String?
    @Published var blockedApps = ""
    @Published var blockedDomains = ""
    /// "Web pages in Chrome", the draft the switch shows. Saved only through `queuePreferences`.
    @Published var browserPages = false
    /// "Save email subjects", the draft the switch shows (email-1003, default on).
    @Published var emailSubjects = true
    /// Whether DayDream may read Chrome's page in front (Automation). Read without a prompt; only
    /// `allowChromeAccess()` lets macOS ask.
    @Published var chromeAccess:ChromeAccessState = .unknown {didSet {
        if chromeAccess != .checking {chromeAccessShown=chromeAccess}
        if let answer=ChromeAccessMemory.answer(chromeAccess) {chromeAccessAnswered(answer,was:oldValue)}
        if chromeAskingAgain,chromeAccess != .checking,chromeAccess != .unknown {chromeAskedAgain(chromeAccess)}
    }}
    /// The menu bar's Chrome line reads the last answer, never `.checking` (review G30).
    private(set) var chromeAccessShown:ChromeAccessState = .unknown
    /// chromeask-1005: macOS's last answer about Chrome (allowed, not asked, refused), kept across launches. A read with
    /// Chrome closed can't ask macOS (it answers only for a running Chrome), so "Chrome pages aren't being saved" keeps
    /// showing until a read of a running Chrome says otherwise.
    private(set) var chromeLastAnswer:ChromeAccessState?=ChromeAccessMemory.saved()
    /// chromeask-1005: a pane opened from a Fix or Open System Settings press: Chrome's status is read every few
    /// seconds (a read, never a question) until it is allowed, so turning the switch on is picked up with no restart.
    private var chromeRecoveryWatch:Timer?
    private var chromeRecoveryUntil:Date?
    /// The one in-app reminder when Chrome is used while access is refused (once ever, `ChromeAccessMemory.reminderKey`).
    var chromeReminder=ChromeAccessReminder.live
    /// Ask again's fallback: the guide beside System Settings (`ChromeAccessGuide`).
    var chromeGuide=ChromeAccessGuide.live
    /// Ask again: DayDream's own Automation answer is being cleared (`ChromeAutomationReset`), then macOS asks again.
    private(set) var chromeResetting=false
    /// Ask again's question is in flight: an answer with no question on screen opens the guide.
    private(set) var chromeAskingAgain=false
    /// The reset couldn't run this session: Ask again goes straight to the guide.
    private(set) var chromeResetFailed=false
    /// What the access checks ask the system; the checks substitute fakes (no Apple Event reaches Chrome).
    var chromeAccessEnvironment=ChromeAccessEnvironment.live
    private var chromeAccessGeneration=0
    private var askingChromeAccess=false
    /// Allow… came back refused with no question from macOS: later reads that say "not asked" or "turned off" keep
    /// pointing to System Settings until Chrome access is allowed.
    private var chromeAskFailed=false
    private var chromeUpgradeCheckWaiting=false
    /// An answer to Allow… faster than this came with no question on screen.
    static let chromeAskQuick:TimeInterval=1.0
    /// Setup's Chrome step asked (`askChromeAccessInSetup`): once macOS answered there, finishing setup asks nothing more.
    private(set) var chromeSetupAsked=false
    /// The Chrome card for an upgrade (`DaydreamChromeCard`): setup's Permissions card opens once, by itself.
    @Published var chromeCardRequested=false
    /// Opens the setup window (set by the main window; the card waits for it otherwise).
    var openSetupWindow:(()->Void)?
    /// Setup's Chrome step is opening Google Chrome to ask (one open at a time).
    private var chromeOpeningForSetup=false
    @Published var retention: Int? = nil
    @Published var busy = false
    @Published var replacementBusy = false
    /// The end of the person's timed pause; saved as the launch intent too (`LaunchResume`).
    @Published var pauseUntil:Date? { didSet { if pauseUntil != oldValue {saveLaunchIntent()} } }
    @Published var stopped = true
    @Published var resumeUnavailable:String? = "Setup required"
    /// A problem the state doesn't say, as one orange line in its own plain words (`RecordingCopy.issue`). Each value clears
    /// itself: unsaved choices once they save or are undone, the summary writer's once a job succeeds (one runs after every
    /// save and every minute), a failed deletion's once that deletion goes through (it is tried again every minute).
    @Published var operationalIssue:String?
    /// The resume blocker while an import or backup runs: it clears itself when that ends.
    static let operationBlocker="Import or backup running"
    /// The resume blocker while a restore preview waits for Confirm or Cancel (Settings › Backup and restore).
    static let restoreBlocker=RecordingStopCause.restoreBlocker
    /// Another DayDream (often a second copy of the app, such as one still open in the download window) holds the
    /// recorder lock, so this one could not open the history. Not a storage problem.
    private(set) var anotherCopyOpen=false
    static let anotherCopyBlocker="Another copy of DayDream is open"
    /// gold r2: the copy holding the lock runs from the download window and steps aside for this one (OtherCopy.swift):
    /// a moment, not a problem, so nothing is said for `anotherCopyGrace`.
    private var anotherCopyStepsAside=false
    private var anotherCopySince:Date?
    private var anotherCopyToken=0
    /// How often a copy that found the lock held reads it again, and how long one stepping aside is waited for quietly.
    static let anotherCopyRecheck:TimeInterval=2
    static let anotherCopyGrace:TimeInterval=8
    /// gold r2 (ADV-8): the history couldn't open because another connection held the file for a moment. It opens again
    /// by itself, on StorageRetry's waits (2, 5, 15, 30, then 60 s), and the launch intent waits for it. nil while no
    /// open is being tried again.
    @Published private(set) var historyOpenRetry:StorageRetry?
    private var historyOpenToken=0
    /// The history an open is being tried again for (a check that moves on to another history ends the tries).
    private var openingHome:URL?
    /// The launch intent, read once while the history couldn't open yet, for when it does.
    private var launchPlan:LaunchResume.Plan?
    /// The person started, paused or stopped while the history was being opened: that is the intent saved once it opens.
    private var personActedWhileOpening=false
    /// The history isn't open yet and opens by itself: a busy moment, or a copy in the download window stepping aside.
    /// Not a problem to show: the state is Off, or with the launch intent the calm "trying again" pause.
    var historyOpening:Bool { historyOpenRetry != nil || anotherCopyStepsAside }
    /// A saved change to Apps to remember disconnected the AI apps that were connected (this run). Only the
    /// choices saved through PreferenceSave do: the app list, the typing switch and (with page history) Web pages in
    /// Chrome. The Typing card's other choices apply at once and don't.
    @Published private(set) var aiAppsDisconnected=false
    /// Apps to remember's one line after such a save, next to its Reconnect button.
    static func aiAppsDisconnectedLine(_ names:[String])->String {
        let list=names.count < 2 ? names.joined() : names.dropLast().joined(separator:", ")+" and "+names[names.count-1]
        return list+(names.count == 1 ? " was disconnected." : " were disconnected.")
    }
    /// A save stopped recording the person had on: it starts again once the save is done (`preferencesChanged`),
    /// so a change on Apps to remember never leaves recording off. Pause or Stop in the meantime cancels it.
    private var resumeAfterSave=false
    private var resumeExplanation=""
    private var timedPause=TimedPause()
    private var resumeTimer:Timer?
    private var schedulingPause=false
    private var awake=true
    /// Sleep, screen lock and user switching (WakeResume.swift, SPEC 6.3 R1). Its plan is part of the launch intent.
    private(set) var wake=WakeResumeMachine() { didSet { if wake.plan != oldValue.plan {saveLaunchIntent()} } }
    /// The lock, console and delay reads the wake rules use; the checks substitute fakes.
    var wakeSystem=WakeSystem.live
    /// The one "DayDream stopped recording" notification; silent outside the app bundle.
    var noticeCenter=RecordingNoticeCenter.live
    /// The person wants recording on: set whenever recording starts, cleared when they pause or stop (or a setting
    /// they saved stops it) and when recording stops on its own. Sleep, a screen lock, a user switch and quitting
    /// leave it on, so recording starts again afterwards (at the next launch too: `LaunchResume`).
    private(set) var recordingWanted=false { didSet { if recordingWanted != oldValue {saveLaunchIntent()} } }
    /// Where the launch intent is saved; nil in previews, trials and the checks (unless one injects its own).
    private let intentDefaults:UserDefaults?
    /// The launch intent has been read and this app holds the recorder lock: changes are saved from now on.
    private var intentLive=false
    /// DayDream is quitting or installing an update: the pause that follows is not the person's, so the saved intent
    /// stays as it was (recording starts again at the next launch).
    private var leaving=false
    /// The UserDefaults the launch intent uses (`LaunchResume`); the checks inject their own. Check builds read and
    /// save nothing unless a check sets one, so no check model ever starts at launch because of another.
    #if DEVELOPMENT_SOURCE_CHECKS
    static var launchIntentDefaults:UserDefaults? = nil
    #else
    static var launchIntentDefaults:UserDefaults? = .standard
    #endif
    /// An automatic start (a timed pause ending, a wake, a save retry, launch) found an import or backup still running:
    /// recording is still wanted and starts once that ends (`operationsChanged`). Shown as a pause that says so.
    @Published private(set) var startWhenFree=false
    /// The session reason the state shows while `startWhenFree` waits (RecordingCopy: "Paused until your import or backup finishes.").
    static let waitingReason="Waiting for an import or backup to finish."
    /// A start is running. A stop it causes at once (keyboard and mouse that couldn't start) is never a "stopped
    /// recording" notice: an automatic start's caller retries or says why, once (a wake retry, the timed pause's notice,
    /// a save retry, launch), and the person's own Start shows it in the state they are looking at.
    private var starting=Starting.no
    private enum Starting {case no,automatic,person}
    /// An automatic start that read a permission off, waiting to read again (gold G33, final review): macOS's privacy
    /// service can answer "not allowed" for a moment, right after wake say. nil when none waits. `holdForPermission`.
    /// When the hold began (gold r3: a time, not `SettledPermission`'s second: see `permissionHoldQuiet`).
    private var permissionHoldSince:Date?
    private var permissionHoldToken=0
    /// The start an automatic start runs again once the permissions read again (set while `automaticStart` runs).
    private var automaticAgain:(()->Void)?
    /// A hold's loss held: the start it runs again takes the off read as the answer (the session says so, and the
    /// caller's one notice goes out).
    private var permissionLossSettled=false
    /// How often a held start reads the permissions again.
    static let permissionRecheck:TimeInterval=0.5
    /// gold r3 (gate item 3): how long a held start keeps reading quietly before it takes the off read as the answer
    /// (and its caller says so once). Was about a second, so a 1-2 s "not allowed" over an unlock's start read stopped
    /// recording with a notice saying both permissions were off.
    static let permissionHoldQuiet:TimeInterval=4
    /// gold r3 (gate item 3): after an automatic start or recording stopped because a permission read off, the reads go on
    /// every `permissionComebackEvery` for `permissionComebackFor`. Both on again (awake, unlocked, on this user's
    /// screen): recording starts by itself, as it would have, and the notice goes. Was: nothing read again, so a moment's
    /// "not allowed" stopped recording for good and "2 permissions are off" stayed with both on.
    static let permissionComebackEvery:TimeInterval=2
    static let permissionComebackFor:TimeInterval=600
    /// Until when a permission stop still starts recording by itself once both read on; nil when none waits.
    private var permissionComebackUntil:Date?
    /// gold/int r3 review: the person's timed pause a wake couldn't pick up because a permission read off (the comeback
    /// waiting behind it). Both on again before it ends, the comeback picks the pause up until the same time instead of
    /// recording early; after it ends, it starts recording, as the pause's end would have.
    private var comebackPauseUntil:Date?
    /// Reads the permissions every `permissionComebackEvery` while recording is off and either a comeback waits or the
    /// state says a permission is off (so that line can't outlive its cause). Common modes: an open menu doesn't hold it.
    private var permissionWatch:Timer?
    /// gold r3 (gate item 2): Input Monitoring reads in the first `InputMonitoringWatch.afterWake` after a wake, an unlock or
    /// a switch back don't count toward `InputMonitoringWatch` (the privacy service can say "not allowed" then).
    private var inputWatchQuietUntil:Date?
    /// The first permission read had Input Monitoring off, and nothing has confirmed it yet (`readPermissions`). While
    /// set, a read that says on means it was on at launch (the privacy service answered "not allowed" for a moment); a
    /// read at least `InputMonitoringWatch.confirmAfter` later, awake and unlocked, that still says off confirms it.
    private var launchReadUnconfirmedSince:Date?
    /// Summary jobs that failed in a row; the orange line shows only once they keep failing.
    private var summaryFailures=0
    /// Why the stop about to happen happens, when this model causes it; nil lets the session say.
    private var stopIntent:RecordingStopCause?
    private var lastRecording=false
    private var noticePrepared=false
    /// Why recording stopped on its own and how to start again, until it starts again or the person acts.
    /// The menu bar shows it as the orange line; the same text went out as the notification.
    @Published private(set) var stopNotice:RecordingNotice?
    private var wakeReconcileTimer:Timer?
    /// Screen lock and unlock, delivered while DayDream is in the background too (ScreenLockObserver).
    private var lockObserver:ScreenLockObserver?
    /// While something is live, reads the lock and console state every 2 s in case a notice is late (`syncLockWatch`).
    private var lockWatch:Timer?
    /// A failed save's retries (WakeResume.swift): recording stays wanted and starts again by itself.
    @Published private(set) var storageRetry=StorageRetry()
    /// Bumped to cancel a scheduled retry.
    private var storageRetryToken=0
    /// Where DayDream runs from. From the download window (a disk image or a translocated copy) it records
    /// nothing until moved (SPEC 6.3 R3).
    let launchLocation:LaunchLocation
    /// Reads the launch location once per model; the checks substitute a location.
    static var readLaunchLocation:()->LaunchLocation = { LaunchLocation.read() }
    /// Check builds only: the typing keyring for a history, in memory (the app attaches the Keychain one). Kept per
    /// history id for the process, so a history reopened in a check finds its key.
    #if DEVELOPMENT_SOURCE_CHECKS
    static var typedKeyStore:(String)->TypedKeyStore = { id in
        if let known=checkTypedKeys[id] {return known}
        let made=InMemoryTypedKeyStore(); checkTypedKeys[id]=made; return made
    }
    private static var checkTypedKeys:[String:InMemoryTypedKeyStore]=[:]
    #endif
    /// Starts the keyboard and mouse recorder (installs its event tap). The checks substitute a start that installs
    /// nothing.
    static var startInput:(EventCapture)->Bool = { $0.start() }
    /// A permission read the checks substitute (both preflight reads); nil reads macOS (`readPermissions`).
    static var permissionRead:(()->PermissionSnapshot)?
    #if DEVELOPMENT_SOURCE_CHECKS
    /// Check builds only: the recording state setup's checks draw (nothing records). nil reads the recorder.
    var recordingForChecks:Bool? {didSet {refreshCaptureStatus()}}
    /// Check builds only: `startCapture` returns at once and counts the call (setup's checks never record).
    static var refuseCaptureForChecks=false
    static var refusedCaptureStarts=0
    #endif
    /// DayDream's login item (LoginItem.swift). Check builds get one that registers nothing.
    #if DEVELOPMENT_SOURCE_CHECKS
    static var loginItem=LoginItemControl.inert
    #else
    static var loginItem=LoginItemControl.live
    #endif
    /// The "Move DayDream to Applications first." alert over the main window.
    @Published var launchWarningPresented=false
    /// When recording last started, paused and stopped, for this run only: capture always starts Off,
    /// so all three are nil at launch. Never `CaptureSession.checked_at`, which is a heartbeat.
    @Published private(set) var transitions=CaptureTransitionDates()
    var recordingSince:Date? {transitions.recordingSince}
    var pausedAt:Date? {transitions.pausedAt}
    var stoppedAt:Date? {transitions.stoppedAt}
    /// The permissions as every surface shows them: the reads (`AXIsProcessTrusted`, `CGPreflightListenEventAccess`;
    /// never a request API), settled (claude/permflash-015, `PermissionSettle`): a read that says allowed shows at once,
    /// one that says not allowed only once the reads have stayed that way, and nil until something is known. So a
    /// moment's "not allowed" from macOS never draws Needs Permission, a "… needed" row or the permission page.
    /// Unread in the Development Trial. What recording does follows its own reads, never this.
    @Published private(set) var permissionSnapshot=PermissionSnapshot()
    /// The settling behind `permissionSnapshot`. Someone who finished setup had both allowed once; before that the
    /// first off read is the answer at once (a new install's first launch shows what to allow with no wait).
    private var permissionShown=ShownPermissions(allowedBefore:UserDefaults.standard.bool(forKey:MemoryViewModel.setupCompletedKey))
    /// Setup was finished once, so both permissions were allowed then: a permission page that opens holds a first off
    /// read until it settles, as this model does (`PermissionGrantView`).
    var permissionsAllowedBefore:Bool {development == nil && UserDefaults.standard.bool(forKey:Self.setupCompletedKey)}
    /// The last read as macOS gave it: what a stop's notice names (`currentStopCause`), never what is shown.
    private var lastPermissionRead=PermissionSnapshot()
    /// The person's own Start read a permission off: the next read is shown as it is (`PermissionSettle.take`).
    private var permissionReadAsIs=false
    /// A read is set to run once the off reads now waiting have had time to hold (`readPermissions`).
    private var permissionSettleReadSet=false
    @Published private(set) var permissionsCheckedAt:Date?
    /// The first permission read in this process. macOS applies Input Monitoring turned on after this only once
    /// DayDream reopens, so the permission page offers Quit & Reopen then (`PermissionRelaunch`). Input Monitoring
    /// read off later in this run (`InputMonitoringWatch`) counts as off here: on again, it needs the reopen too.
    private(set) var permissionsAtLaunch:PermissionSnapshot?
    private var inputMonitoringWatch=InputMonitoringWatch()
    /// perm-1004 (owner 10/3: one click): the permission a `Turn on …` press asked for. The drag-card page that shows
    /// next opens its System Settings pane once and clears this (`PermissionRequestActions.paneRequest`).
    @Published var permissionPaneRequest:PermissionKind?
    /// perm-1004 (owner: no manual restart): Input Monitoring was turned on after launch and both permissions read on,
    /// so DayDream restarts itself in `PermissionRelaunch.autoDelay` (the page says so in one line).
    @Published private(set) var permissionAutoRelaunch=false
    /// When DayDream last restarted itself for Input Monitoring (`PermissionRelaunch.autoCooldown`: never a loop).
    static let autoRelaunchKey="DaydreamPermissionAutoRelaunchAt"
    /// The restart itself (the permission page's Quit & Reopen); false when DayDream can't reopen itself. The checks
    /// substitute a recorder.
    static var performAutoRelaunch:(MemoryViewModel)->Bool = { model in
        guard let reopen=model.permissionRequests?.quitAndReopen else {return false}
        reopen();return true
    }
    /// Where the last automatic restart's time is kept. The checks substitute an in-memory store.
    static var autoRelaunchDefaults:UserDefaults = .standard
    /// The day data every redesigned surface reads. This model decides when it is stale.
    var dayData=DayDataHooks()
    private var presentedKind:DaydreamCaptureState?
    private var commitRefresh:Task<Void,Never>?
    private var sinks=Set<AnyCancellable>()
    var shortState:String {
        if development?.preview == true {return "Preview · not recording"}
        if development != nil {return "Development Trial · OFF"}
        if recording { return "Recording" }
        if presentedBlocker != nil { return "Setup required" }
        if let pauseUntil { return "Paused until " + pauseUntil.formatted(date:.omitted,time:.shortened) }
        return stopped && !startWhenFree ? "Stopped" : "Paused"
    }
    /// The blocker the surfaces show. Not the wait while the Mac sleeps, is locked or is switched away (behind the lock
    /// screen the pause line says why; Start stays refused), nor an import or backup an automatic start waits on (the
    /// pause line says that) or a timed pause outlasts (Paused until its end, which waits for it too): something that
    /// ends by itself is never an orange warning beside a pause.
    private var shownBlocker:String? {
        guard let blocker=resumeUnavailable, blocker != "Resume after waking", !permissionBlockerUnsettled else {return nil}
        return blocker == Self.operationBlocker && (startWhenFree || pauseUntil != nil) ? nil : blocker
    }
    /// claude/permflash-015: the blocker says the permissions are off, but what is shown of them hasn't settled on off
    /// (`permissionSnapshot`: a moment's "not allowed", or nothing known yet). No surface says a permission is off then:
    /// the state is what it would be without it (Off, Paused), and Start stays there (pressed, it takes its own read).
    private var permissionBlockerUnsettled:Bool {
        resumeUnavailable == RecordingCopy.permissionBlocker && permissionSnapshot.missing.isEmpty
    }
    /// The blocker the surfaces show, with the permissions as shown: once a permission's reads have settled on off and
    /// nothing records, the state is Needs Permission whether or not the recorder's own settled read says so yet (the
    /// two used to disagree for a read or two: a "… needed" row beside Off).
    private var presentedBlocker:String? {
        shownBlocker ?? (!recording && development == nil && !permissionSnapshot.missing.isEmpty ? RecordingCopy.permissionBlocker : nil)
    }
    private var store: MemoryStore?
    /// The open history's `core_store_id`, which names its typing key (Remove everything deletes that key).
    var historyStoreID: String? { (try? store?.coreStoreID()) ?? nil }
    private var writer: SummaryWorker?
    /// Read by scripts/recording-model-checks.swift, which drives its failed-save hooks on a synthetic store.
    private(set) var coordinator: Coordinator?
    private var capture: EventCapture?
    private var observers: [NSObjectProtocol] = []
    private var timeZoneObserver: NSObjectProtocol?
    private var dayChangeObserver: NSObjectProtocol?
    private var copyLaunchObserver: NSObjectProtocol?
    /// The installed-app catalog read in flight, and when the last one landed (`refreshBundleNames`).
    private var bundleCatalogReading=false
    private var bundleCatalogReadAt:Date?
    private var maintenance: Timer?
    var replacement: Switchover? { store.map { Switchover(store:$0,control:LaunchctlControl()) } }
    /// What launch did to the history before this model (`prepared` below). Kept for every open, not only the first:
    /// the history can open again by itself later (a busy file at launch, ADV-8), and that open doesn't look again either.
    private let launchPrepared:HistoryPreparation.Outcome?
    /// `prepared`: what launch already did to the history off the main thread before this model (DaydreamLaunchSession,
    /// HistoryPreparation: a damaged history's repair, the one-time time indexes); nil when launch had nothing to do.
    init(development:DevelopmentTrial?=nil,recordingTrial:Bool=false,functionalTrial:Bool=false,prepared:HistoryPreparation.Outcome?=nil) {
        self.development=development
        self.recordingTrial=recordingTrial && development == nil
        self.functionalTrial=functionalTrial && development == nil && !recordingTrial
        launchPrepared=prepared
        // Only the app itself saves and reads the launch intent (never a preview or a trial).
        intentDefaults=development == nil && !recordingTrial && !self.functionalTrial ? Self.launchIntentDefaults : nil
        launchLocation=development == nil ? Self.readLaunchLocation() : .notAnApp
        connection=development == nil ? ConnectionSettingsModel.remembered():ConnectionSettingsModel()
        let writerHome=MemPaths.home()
        LaunchTrace.mark("model.init")
        #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
        let testingWriter=CommandLine.arguments.contains("--synthetic-writer-check") || CommandLine.arguments.contains("--synthetic-writer-restart-check")
        if development != nil || recordingTrial {
            noteWriter=WriterIntegration(modelRoot:writerHome.appendingPathComponent("Models"),keyStore:TrialForbiddenKeys(),send:{_ in throw WriterFailure.denied})
        } else if testingWriter,let physical=try? physicalDirectory(writerHome),physical.path.hasPrefix("/private/tmp/daydream-trial-"),
           (try? String(contentsOf:physical.appendingPathComponent("TRIAL-ONLY"),encoding:.utf8))=="synthetic-only\n" {
            noteWriter=WriterIntegration(modelRoot:writerHome.appendingPathComponent("Models"),keyStore:TrialForbiddenKeys(),send:{_ in throw WriterFailure.denied})
        } else {noteWriter=WriterIntegration(modelRoot:writerHome.appendingPathComponent("Models"),environment:.app)}
        #else
        if development != nil {
            noteWriter=WriterIntegration(modelRoot:writerHome.appendingPathComponent("Models"),keyStore:TrialForbiddenKeys(),send:{_ in throw WriterFailure.denied})
        } else {noteWriter=WriterIntegration(modelRoot:writerHome.appendingPathComponent("Models"),environment:.app)}
        #endif
        // Read as Sparkle begins the relaunch: recording on then starts again at the relaunch (UpdateResume). Nothing
        // pauses for the update before DayDream quits; the quit pauses it (willTerminate, below).
        updates.isRecording={ [weak self] in self?.recording == true }
        updates.replacementInProgress={ [weak self] in
            guard let self, self.store != nil else { return true }
            do { return !UpdateConfiguration.replacementAllowsUpdate(phase:try self.replacement?.record()?.phase,busy:self.replacementBusy) }
            catch { return true }
        }
        // Not in a second copy, which opened nothing (Sparkle belongs to the copy that holds the history).
        defer { if development == nil && !recordingTrial && !anotherCopyOpen {updates.start()} }
        observeWriterAndPrivacy()
        dayData=DayDataHooks(invalidate:{ [activity] in activity.dayCache.invalidate($0) },
                             invalidateAll:{ [activity] in activity.dayCache.invalidateAll() },
                             notesChanged:{ [activity] in activity.dayCache.notesChanged() },
                             noteDaysChanged:{ [activity] in activity.dayCache.notesChanged(days:$0) },
                             refreshToday:{ [activity] in activity.today.refresh(force:$0) },
                             refreshTodayIfStale:{ [activity] in activity.today.refreshIfStale(maxAge:$0) },
                             reviewChanged:{ [activity] in activity.today.reviewChanged($0) })
        activity.openSettingsSection = { [weak self] in self?.openSettings($0) }
        // Quitting closes the Settings sheet first (AppKit won't quit while a sheet is open).
        AppQuit.willQuit = { [weak self] in self?.settingsPresented=false }
        // The browser follows the system time zone (F0b contract request 3). Set here, synchronously: the day cache
        // handles the same notification on the next main-queue turn and must already see the new zone.
        timeZoneObserver=NotificationCenter.default.addObserver(forName:.NSSystemTimeZoneDidChange,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemTimeZoneChanged() }
        }
        dayChangeObserver=NotificationCenter.default.addObserver(forName:.NSCalendarDayChanged,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.calendarDayChanged() }
        }
        // gold r2: a copy in the download window steps aside when a copy that can record opens (OtherCopy.swift).
        if development == nil && !self.recordingTrial && !self.functionalTrial && launchLocation.blocksRecording, let id=Bundle.main.bundleIdentifier {
            copyLaunchObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didLaunchApplicationNotification,object:nil,queue:.main) { [weak self] note in
                guard let app=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.bundleIdentifier == id,
                      app.processIdentifier != getpid(), let url=app.bundleURL else {return}
                let location=LaunchLocation.read(bundleURL:url)
                MainActor.assumeIsolated { self?.otherCopyOpened(location) }
            }
        }
        // gold/int round 2: launch may have prepared the history for seconds before this model existed (HistoryPreparation),
        // with nothing watching for a copy that can record. One opened meanwhile is stepped aside for now, on the next turn,
        // the same way; it waits quietly for this copy's lock meanwhile (`anotherCopyHoldsHistory`).
        if development == nil && !self.recordingTrial && !self.functionalTrial && launchLocation.blocksRecording, let later=OtherCopy.current.openedLater() {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.otherCopyOpened(later) } }
        }
        LaunchTrace.mark("model.wired")
        openHistory()
    }
    /// Opens the history and wires everything that reads it: at launch, and again by itself when another connection held
    /// the file for a moment (gold r2, ADV-8) or another copy that had it open let go (`anotherCopyHoldsHistory`).
    private func openHistory() {
        do {
            // A second copy of DayDream finds the recorder lock held before it opens the history, attaches the typing
            // key or starts any timer (Coordinator takes the lock itself below).
            if development == nil, Self.recorderLockHeld(home:MemPaths.home()) { throw MemError.invalid(Coordinator.lockHeld) }
            // A history SQLite reported damaged is repaired before it opens; a damaged file that lost rows is kept (G45).
            // Launch did that already, off the main thread, when it prepared the history (r2-store-perf), with the time
            // indexes: this open looks for neither again and builds nothing on the main thread (`.prepared`). A repair
            // that lost something is said as the history opens, from the new file itself (`openHistory`).
            let syncSearch=development == nil && !recordingTrial
            let prepared=launchPrepared
            store = try Self.openHistory(MemPaths.home(),repairs:prepared?.prepared != true,kept:{ [backups] in backups.noteHistorySetAside() }) {
                try MemoryStore(home:MemPaths.home(),writable:true,automaticallySyncSearch:syncSearch,launchWork:prepared?.prepared == true ? .prepared : .here,liveHistory:development == nil)
            }
            // gold r2 (ADV-8): every read that can meet a busy file (the store, the Coordinator, the settlement, the choices,
            // the saver) comes before `historyOpened` wires anything, so a moment's busy file closes what half opened
            // (`closeHalfOpenHistory`) and the history is opened again by itself (`historyOpenFailed`).
            guard let opened=store else {throw MemError.missing}
            LaunchTrace.mark("history.opened")
            if development == nil {
            writer = store.map { SummaryWorker(store:$0) }
            if let store {
                // Typed text: attach this store's Keychain keyring, settle build 4
                // plain-text rows, then run expiry now and every hour.
                #if DEVELOPMENT_SOURCE_CHECKS
                typedExpiry=TypedTextLaunch.wire(store:store,keys:Self.typedKeyStore).timer
                #else
                TypedTextExpiryTimer.runsOffMain=true
                typedExpiry=TypedTextLaunch.wire(store:store,keys:{KeychainTypedKeyStore.forStore($0)}).timer
                #endif
                LaunchTrace.mark("typing.key.wired")
                let bridge=AssistantTypedBridgeServer(home:store.home) { [weak store] request in
                    store?.assistantBridgeAnswer(request,enabled:AIReadsTypedSetting.isOn()) ?? ["status":"error"]
                }
                if bridge.start() {aiReadBridge=bridge}
                typing.keyPanel = { NativeTypingRoute.keyPanelBundle() }
                // The typing pause decides the recorder's late keys before it is saved (gold/r3-typing).
                typing.willPause = { [weak self] chordAt in self?.capture?.typingWillPause(chordAt: chordAt) }
                // fix/typing-e2e: Turn on / Turn off save the typing switch through the preference path.
                typing.saveSwitch = { [weak self] on in self?.typingPreference.wrappedValue = on }
                typing.attach(store)
                #if DEVELOPMENT_SOURCE_CHECKS
                // The checks' permission read (`permissionsGranted`), so a check model can record without macOS.
                let granted=Self.permissionsGranted
                coordinator = try Coordinator(store:store,permissions:granted) { [weak self] in
                    self?.scheduleLegacySummaries()
                    self?.captureCommitted()
                }
                #else
                coordinator = try Coordinator(store:store) { [weak self] in
                    self?.scheduleLegacySummaries()
                    self?.captureCommitted()
                }
                #endif
                coordinator?.onStateChanged = { [weak self] in self?.refreshCaptureStatus() }
                // claude/perf3-1005: the heartbeat's typing reads go with it, off the main thread.
                coordinator?.beatReads = { [weak self] in self?.typing.beatReads() }
                // A failed save pauses recording; it starts again by itself (StorageRetry). A good heartbeat ends that.
                coordinator?.onStorageFault = { [weak self] in
                    // Only recording the person has on starts again: a late write failing after their Pause changes nothing.
                    guard let self, self.recordingWanted || self.recording else {return}
                    self.storageFaulted()
                }
                // Only while recording: a heartbeat that saves while paused for the failed save is not a recovery, and
                // ending the retry then would leave recording paused with nothing trying again.
                coordinator?.onHealthy = { [weak self] in guard let self, self.recording else {return}; self.storageRecovered() }
                // The dot follows key focus into Spotlight (it never becomes the frontmost app).
                coordinator?.onKeyTarget = { [weak self] bundle in self?.typing.keyTargetSeen(bundle) }
                coordinator?.onNativeCommitted = { [weak self] receipt in self?.nativeCommitReceipt=receipt }
            }
            }
            // This app now holds the recorder lock and nothing records (the session was just written Off). Choices an older
            // version saved in a form this one reads as off are saved off, once; nothing is turned on. Settled before the
            // choices are read (gold r2 review 1): the model and its saver read the settled choices and revision, so the
            // first save after this launch lands (not "changed in another window") and setup's Start isn't held back.
            let settled=development == nil ? try Self.settleLegacyChoices(opened) : nil
            let policy=try opened.policy()
            let saver=try PreferenceAutosave(store:opened,stopProducer:{ [weak self] in
                guard let self else {return}
                // gold r2: a save stops what records; it never ends a pause that promised something (a timed pause,
                // the one for a lock): nothing records during it, and the store takes a paused session.
                if self.pauseOutlastsSave() {return}
                let wasOff=self.stopped && !self.recording
                if self.recording {self.resumeAfterSave=true}
                // A setting the person saved stops recording: their choice, so no notification.
                self.withStopIntent(.person) {
                    self.cancelTimedPause()
                    self.coordinator?.stopForPreferences(capture:self.capture)
                    if !wasOff {self.transitions.stopped(at:self.activity.now())}
                    self.capture=nil;self.stopped=true;self.refreshCaptureStatus()
                }
            })
            LaunchTrace.mark("history.wired")
            historyOpened(policy:policy,saver:saver,settled:settled)
            LaunchTrace.mark("history.ready")
        } catch MemError.invalid(let message) where message == Coordinator.lockHeld {
            // Nothing of this copy's stays open (the lock was taken between the check above and the Coordinator).
            closeHalfOpenHistory()
            anotherCopyHoldsHistory()
        } catch MemError.invalid(let message) where message == MemoryStore.newerStore {
            // G61: a newer DayDream saved this history. Say so, rather than "storage unavailable"; nothing reads it.
            closeHalfOpenHistory()
            endHistoryOpenRetry();endAnotherCopyWait()
            status = "Update DayDream to open your history. No capture started."; activity.phase = .failed(message)
            resumeUnavailable = "Storage unavailable"
        } catch where development == nil && CaptureFault.busy(error) {
            // gold r2 (ADV-8): another connection held the file for a moment. Not a broken history: it opens again by
            // itself, with the launch intent kept, and the state is the calm "trying again" meanwhile.
            closeHalfOpenHistory()
            endAnotherCopyWait()
            historyOpenFailed(error)
        } catch {
            closeHalfOpenHistory()
            endHistoryOpenRetry();endAnotherCopyWait()
            status = "Storage unavailable. No capture started."; activity.phase = .failed("Local storage could not be opened. No capture was started.")
            // The store, the recorder lock or the saved policy failed, so no observer ever refreshes the
            // capture status: the launch value "Setup required" would read as unfinished setup.
            resumeUnavailable = "Storage unavailable"
        }
    }
    /// The history opened: everything that reads it is wired, once (nothing here throws).
    private func historyOpened(policy:PrivacySettings,saver:PreferenceAutosave,settled:LegacyPreferenceSettlement?) {
            let reopened=anotherCopyOpen || historyOpening
            endAnotherCopyWait()
            endHistoryOpenRetry()
            openingHome=nil
            // The "can't save right now" notice a long busy open posted: the history is open now.
            if stopNotice == .storageRetrying {clearStopNotice()}
            // Its look for a paused import runs once this app holds the history.
            history.recover()
            if development == nil {
            if let store {
                // Recording was on when DayDream or the Mac last quit (a restart, a logout, a crash, an update, a quit), or a
                // timed pause was running: start again on the next turn, once the rest of launch has run, through the
                // same guards as Start (`resumeAtLaunch`). sat5's update marker counts too (an older build wrote it).
                // A restore preview saved before DayDream quit that can no longer be confirmed (they last five minutes)
                // is closed, so it doesn't hold recording back. Nothing is restored.
                if let closed=backups.closeExpiredPreview(now:Date()) {try? store.cancelCanonicalRestore(closed)}
                // A copy in the download window records nothing (its alert says so), so it leaves the launch intent and
                // the update marker for the copy in Applications, and saves nothing: opening it by mistake loses nothing.
                if let intentDefaults, !launchLocation.blocksRecording {
                    // A history opened again after a busy moment keeps the plan read then (`launchPlan`), or the person's
                    // choice since; the update marker is removed now either way (it counts once).
                    let read=Self.readLaunchPlan(intentDefaults)
                    let plan=launchPlan ?? read
                    launchPlan=nil
                    // A timed pause is picked up as it was (`resumeAtLaunch`), not as recording wanted meanwhile; set
                    // before saving starts, so nothing is saved for it.
                    if case .timedPause = plan {recordingWanted=false}
                    intentLive=true
                    // The person stopped or started while the history was being opened: that choice is the intent now.
                    if personActedWhileOpening {personActedWhileOpening=false;saveLaunchIntent()}
                    if plan != .none {
                        RecordingLog.note("Recording was on when DayDream last quit; starting again.")
                        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.resumeAtLaunch(plan) } }
                    }
                    // Setup was finished before this version: DayDream opens at login from now on (asked once).
                    if UserDefaults.standard.bool(forKey:Self.setupCompletedKey) {offerOpenAtLogin()}
                    readOpenAtLogin()
                }
                // What launch settled before the choices were read (`openHistory`): its one notice, if any.
                if !recordingTrial {
                    if let settled,let notice=Self.noticeText(settled) {UserDefaults.standard.set(notice,forKey:Self.preferenceNoticeKey)}
                    preferenceNotice=Self.readPreferenceNotice()
                }
            }
            // Sleep, a screen lock and a user switch pause recording. Once all of them have ended, recording
            // starts again by itself if it was on before (WakeResume.swift). A permission granted back never starts it;
            // launch does only if recording was on when DayDream last quit (LaunchResume).
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend(.sleep) }
            })
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.unsuspend(.sleep) }
            })
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.sessionDidResignActiveNotification,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend(.userSwitch) }
            })
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.sessionDidBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.unsuspend(.userSwitch) }
            })
            // Delivered at once even while DayDream is in the background (AppKit suspends the distributed center for an
            // inactive app, and the block observers used to get the lock only when the person next clicked into DayDream).
            lockObserver=ScreenLockObserver(locked:{ [weak self] in MainActor.assumeIsolated { self?.suspend(.screenLock) } },
                                            unlocked:{ [weak self] in MainActor.assumeIsolated { self?.unsuspend(.screenLock) } })
            // Quitting (a restart and a logout too) keeps what the person had on: it starts again at the next launch.
            observers.append(NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.productionSearch?.stop();self?.leaving=true;self?.withStopIntent(.person) { self?.pauseCapture("App closed.",commitTyping:true) } }
            })
            observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshCaptureStatus(); self?.refreshBundleNames(); self?.readOpenAtLogin()
                    // Chrome access may have changed; an unanswered upgrade requests once for this version.
                    if self?.browserPagesSaved == true {self?.checkChromeAccess()}
                }
            })
            maintenance = Timer.scheduledTimer(withTimeInterval:60,repeats:true) { [weak self] _ in
                // The summary job and a deletion that failed each run again, so their orange lines clear by themselves.
                Task { @MainActor in self?.scheduleLegacySummaries(); self?.retryFailedDeletions() }
            }
            }
            if let store {
                let memoryHome = store.home
                preferenceSave=saver
                preferenceSave?.onChange={ [weak self] in self?.preferencesChanged() }
                if development == nil {
                    let search=AppSearchBinding(store:store)
                    productionSearch=search
                    search.begin(bundle:Bundle.main.bundleURL) { [weak self] state in
                        MainActor.assumeIsolated {
                            self?.searchIndexingLine=state.indexingLine
                            self?.searchBackendStatus=["ready","indexing"].contains(state.phase) ? "Local index: \(state.phase)" : "SQLite fallback · \(state.advancedReason)"
                        }
                    }
                }
                if development == nil,!recordingTrial,backups.prepared == nil {noteWriter.configure(store:store)}
                backups.onResolved = { [weak self] in if self?.development == nil,self?.recordingTrial == false {self?.noteWriter.configure(store:store)};self?.dayData.invalidateAll();self?.refresh() }
                backups.closeHere = { id in try store.cancelCanonicalRestore(id) }
                if let development {backups.allowedPath=development.allowsBackup;backups.requiresKnownBackup=true;backups.trialBackupDirectory=development.root.appendingPathComponent("backups")}
                history.permitsImport = { [weak self] in self?.recording == false && self?.replacementBusy == false && self?.backups.busy == false && self?.backups.prepared == nil && self?.noteWriter.provider == "off" && self?.noteWriter.busy == false && self?.writerControlsBusy == false && self?.summaryJobs == 0 }
                backups.permitted = { [weak self] in self?.recording == false && self?.replacementBusy == false && self?.history.busy == false && self?.privacyDirty == false && self?.noteWriter.busy == false && self?.noteWriter.provider == "off" && self?.writerControlsBusy == false && self?.summaryJobs == 0 }
                let searchBinding=productionSearch
                activity.searchCanonical = { query,cursor in
                    if let searchBinding {return try await searchBinding.search(MemorySearchQuery(query,limit:50,after:cursor))}
                    return try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos:.userInitiated).async {
                            continuation.resume(with:Result {try MemoryStore(home:memoryHome).searchResult(MemorySearchQuery(query,limit:50,after:cursor))})
                        }
                    }
                }
                // The same backend and page size as searchCanonical, keeping the caller's filters and cursor.
                activity.searchCanonicalQuery = { query in
                    let text=query.text,app=query.app,start=query.start,end=query.end,site=query.site,after=query.after
                    if let searchBinding {return try await searchBinding.search(MemorySearchQuery(text,app:app,start:start,end:end,limit:50,site:site,after:after))}
                    return try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos:.userInitiated).async {
                            continuation.resume(with:Result {try MemoryStore(home:memoryHome).searchResult(MemorySearchQuery(text,app:app,start:start,end:end,limit:50,site:site,after:after))})
                        }
                    }
                }
                activity.searchDirectPreview = { query in
                    try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos:.userInitiated).async {
                            continuation.resume(with:Result {try MemoryStore(home:memoryHome).directSearchPreview(query)})
                        }
                    }
                }
                // fix/search-1003 (owner, 2026-09-29): what the person typed is searchable in their own app. The words open
                // on the app's own store (its ready key) through the details page's owner gate; nothing is written, and no
                // MCP, CLI or index ever holds them (MemoryStore.ownerTypedSearch).
                // claude/perf2-1003: a superseded search (the next letter typed) stops its pass at the next row.
                activity.searchOwnerTyped = { query in
                    let stop=OwnerTypedSearchStop()
                    return try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { continuation in
                            DispatchQueue.global(qos:.userInitiated).async {
                                continuation.resume(with:Result {try StoreWait.lettingMainIn {try store.ownerTypedSearch(query,stop:stop)}})
                            }
                        }
                    } onCancel: {stop.request()}
                }
                activity.reconcileSearchPreview = { query,ids,page in
                    try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos:.userInitiated).async {
                            continuation.resume(with:Result {try MemoryStore(home:memoryHome).reconcileDirectPreview(query,ids:ids,with:page)})
                        }
                    }
                }
                // summaries/v3 levels: Recall's note rows (every level; the same match as the MCP recall search).
                activity.searchNotes = { [weak activity] query in
                    let zone=(activity?.calendar ?? Calendar.current).timeZone.identifier
                    return try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos:.userInitiated).async {
                            continuation.resume(with:Result {try MemoryStore(home:memoryHome).noteSearch(query,timezone:zone)})
                        }
                    }
                }
                // Activates the app only; nothing is opened inside it.
                activity.openApp = { bundle in
                    guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundle) else {return}
                    let configuration=NSWorkspace.OpenConfiguration();configuration.activates=true
                    NSWorkspace.shared.openApplication(at:url,configuration:configuration)
                }
                activity.reopenCanonical = { [development] id in
                    guard development == nil else {throw MemError.denied}
                    let link:OriginalSourceLink = try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos:.userInitiated).async {
                            continuation.resume(with:Result {try MemoryStore(home:memoryHome).originalSourceLink(actionID:id,verifier:OriginalHEADVerifier())})
                        }
                    }
                    guard let text=link.url,let url=URL(string:text),let action=try store.action(id),action.revision == link.sourceRevision else {throw MemError.denied}
                    // fix/show-all: a page seen in Chrome opens in Chrome (the owner's browser for it), else the default browser.
                    if action.bundle == ChromePageTarget.bundleID,let chrome=NSWorkspace.shared.urlForApplication(withBundleIdentifier:ChromePageTarget.bundleID) {
                        let configuration=NSWorkspace.OpenConfiguration();configuration.activates=true
                        _ = try await NSWorkspace.shared.open([url],withApplicationAt:chrome,configuration:configuration)
                        return
                    }
                    guard NSWorkspace.shared.open(url) else {throw MemError.invalid("No browser opened the verified source")}
                }
                activity.correctCanonical = { [weak self] scope,text,revision in
                    if scope.kind == "action", let id=scope.id { _ = try store.correctAction(id:id,text:text,expectedRevision:revision) }
                    else { _ = try store.correctNote(scope:scope,text:text,expectedRevision:revision) }
                    self?.memoryChanged(day:scope.day,timezone:scope.timezone)
                }
                activity.previewCanonicalDelete = { try store.prepareDeletion(scope:$0) }
                // gold r3-store (gate item 5): the Forget alerts prepare it off the main thread (the day's assembly after a
                // Correct held it 280-520 ms); prepareDeletion reads the scope in short statements, so the recorder's
                // saves and heartbeat go on between them.
                activity.previewCanonicalDeleteOffMain = { scope in
                    try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos:.userInitiated).async {
                            continuation.resume(with:Result {try StoreWait.lettingMainIn {try store.prepareDeletion(scope:scope)}})
                        }
                    }
                }
                // A preview can span actions of several days; drop every cached day once it commits.
                activity.confirmCanonicalDelete = { [weak self] in _ = try store.executeDeletion(previewID:$0,confirmed:true);self?.memoryChanged(day:nil,timezone:nil) }
                // gold r3-store: the Forget alerts commit it off the main thread too (the transaction checks the scope
                // again, a day's assembly); the cached days are dropped on the main thread once it lands.
                activity.confirmCanonicalDeleteOffMain = { [weak self] id in
                    try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                        DispatchQueue.global(qos:.userInitiated).async {
                            continuation.resume(with:Result {_ = try StoreWait.lettingMainIn {try store.executeDeletion(previewID:id,confirmed:true)}})
                        }
                    }
                    self?.memoryChanged(day:nil,timezone:nil)
                }
                activity.cancelCanonicalDelete = { try store.cancelDeletion($0) }
                // Forget a time range: its own writable connection off the main thread (a long range holds the write
                // lock for a while; nothing on the main thread waits on it). In DayDream Preview that is the sample
                // history (MAC_MEM_HOME), as for every other forget.
                activity.previewRangeDelete = { scope in
                    try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos:.userInitiated).async {
                            continuation.resume(with:Result {try MemoryStore(home:memoryHome,writable:true).prepareDeletion(scope:scope)})
                        }
                    }
                }
                activity.confirmRangeDelete = { [weak self] id in
                    let _:DeletionReceipt = try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos:.userInitiated).async {
                            continuation.resume(with:Result {try MemoryStore(home:memoryHome,writable:true).executeDeletion(previewID:id,confirmed:true)})
                        }
                    }
                    await MainActor.run { self?.memoryChanged(day:nil,timezone:nil) }
                }
                activity.generateCanonicalNote = { [weak self] day,zone,id,last in
                    guard let self,!self.history.busy,!self.backups.busy,self.backups.prepared == nil else { throw MemError.missing }
                    self.noteWriterStarted()
                    defer { self.noteWriterFinished(day:day,timezone:zone) }
                    try await self.noteWriter.generate(day:day,timezone:zone,activityID:id,lastActivity:last)
                }
                // Both read the display calendar when called, not when created: it follows the system time zone.
                activity.loadCanonicalDay = { [weak activity] day, cursor in
                    let zone=(activity?.calendar ?? Calendar.current).timeZone.identifier
                    return try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos:.userInitiated).async {
                            continuation.resume(with:Result {
                                let reader=try MemoryStore(home:memoryHome)
                                var read=try reader.dayLayers(day:day,timezone:zone,after:cursor,limit:200)
                                // summaries/v3 levels: the day's blocks, day note and week note ride along (one small read).
                                read.levels=try? reader.dayLevels(day:day,timezone:zone)
                                // claude/day-review-1003: the review's quotes, the person's own words, open in this process only
                                // (the owner disclosure, typing on, a ready key), as the timeline's asks do. Held in memory for
                                // the card; never encoded, stored, logged or handed on.
                                if store.typingUnlocked,let ids=read.levels?.review?.quoteIDs,!ids.isEmpty {
                                    read.levels?.review?.quotes=(try? StoreWait.lettingMainIn {try store.ownerReviewQuotes(ids)}) ?? [:]
                                }
                                return read
                            })
                        }
                    }
                }
                // perf-1005: a card's What happened and its details page read the moment's actions in one read, off the main
                // thread (they walked the day's pages, a whole day assembly each: 13-20 s for a late card on a big day).
                activity.loadMemberActions = { [weak activity] day, ids in
                    let zone=(activity?.calendar ?? Calendar.current).timeZone.identifier
                    return try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos:.userInitiated).async {
                            continuation.resume(with:Result { try MemoryStore(home:memoryHome).memberActions(day:day,timezone:zone,ids:ids) })
                        }
                    }
                }
                // claude/day-review-1003 perf pass: the hero card's review after a clause is saved: the store's cached facts
                // with the new clause (no day read), and the quotes opened again in this process only, as for a day read.
                activity.loadDayReview = { [weak activity] day in
                    let zone=(activity?.calendar ?? Calendar.current).timeZone.identifier
                    return await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos:.utility).async {
                            var review:DayReviewFacts?=(try? MemoryStore(home:memoryHome).cachedDayReview(day:day,timezone:zone)) ?? nil
                            if store.typingUnlocked,let ids=review?.quoteIDs,!ids.isEmpty {
                                review?.quotes=(try? StoreWait.lettingMainIn {try store.ownerReviewQuotes(ids)}) ?? [:]
                            }
                            continuation.resume(returning:review)
                        }
                    }
                }
                // Previous/Next Day step between days with records: their local days, from the records' hours only.
                activity.loadRecordedDays = { zone in
                    try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos:.userInitiated).async {
                            continuation.resume(with:Result {try MemoryStore(home:memoryHome).recordedDays(timezone:zone)})
                        }
                    }
                }
                // fix/prompt-row: each AI-app moment's ask for the timeline row, on this Mac only. Which rows are asks is
                // metadata, read on a reader connection; the words open in this process only (`ownerMomentPrompts`:
                // the owner disclosure, typing on, a ready key), under `lettingMainIn` so a capture save never waits.
                // Nothing is stored, logged or handed on: the result goes to the timeline's memory and nowhere else.
                activity.loadMomentPrompts = { requests in
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos:.utility).async {
                            var prompts=[String:String]()
                            if store.typingUnlocked,let asks=try? MemoryStore(home:memoryHome).momentPromptRows(requests),!asks.isEmpty {
                                prompts=(try? StoreWait.lettingMainIn {try store.ownerMomentPrompts(asks)}) ?? [:]
                            }
                            continuation.resume(returning:prompts)
                        }
                    }
                }
                // Selected detail metadata only: a typing submission gesture is
                // never confirmation of delivery. Exact source text uses the
                // independently verified, short-run owner projection below.
                activity.loadMomentTyped = { ids,label in
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos:.userInitiated).async {
                            let rows=(try? MemoryStore(home:memoryHome).momentTypedRows(ids,label:label)) ?? []
                            var sends=[String:String]()
                            for row in rows { if row.send != nil { sends[row.id]="Submission observed" } }
                            // Exact short content now has a separate, verified source
                            // projection. Long/partial/unknown content keeps its summary.
                            continuation.resume(returning:MomentTypedLoad(sends:sends))
                        }
                    }
                }
                // compose-send/v1: each typed row's compose line ("Sent to Jamie", "Replied to Ada's post on X"), metadata only.
                activity.loadComposeLines = { ids in
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos:.userInitiated).async {
                            let outcomes=(try? MemoryStore(home:memoryHome).composeOutcomes(ids)) ?? [:]
                            continuation.resume(returning:outcomes.mapValues(ComposeLine.init))
                        }
                    }
                }
                activity.loadOwnerSourcePreviews = { ids in
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos:.userInitiated).async {
                            let previews = (try? StoreWait.lettingMainIn {
                                try store.ownerSourceMomentPreviewsForActions(ids)
                            }) ?? []
                            continuation.resume(returning:previews)
                        }
                    }
                }
                activity.ownerSourcePreviewRevision = { deadline in
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos:.utility).async {
                            let revision = try? StoreWait.lettingMainIn {
                                try store.ownerSourcePreviewRevision(expiresAt:deadline)
                            }
                            continuation.resume(returning:revision ?? nil)
                        }
                    }
                }
                activity.loadDay = { [weak activity] date in
                    let end = (activity?.calendar ?? Calendar.current).date(byAdding:.day,value:1,to:date)!
                    return try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos:.userInitiated).async {
                            continuation.resume(with:Result {
                                let reader = try MemoryStore(home:memoryHome)
                                return try reader.activityDay(start:date,end:end)
                            })
                        }
                    }
                }
            }
            if development != nil {history.permitsImport={false};activity.reopenCanonical=nil;activity.generateCanonicalNote=nil;activity.openApp=nil;activity.excludeApp=nil}
            if development?.preview == true {activity.previewLine=PreviewSample.line}
            if recordingTrial {history.permitsImport={false};activity.generateCanonicalNote=nil;activity.openApp=nil;activity.excludeApp=nil}
            let p = policy; blockedApps = p.blockedApps.joined(separator:", "); blockedDomains = p.blockedDomains.joined(separator:", "); retention = p.retentionDays
            savedPrivacy=p; captureText=p.typingOn; browserPages=p.browserPagesOn; emailSubjects=p.emailSubjects
            syncExcludeHook()
            refreshAtLaunch()
            scheduleLegacySummaries()
            refreshBundleNames()
            // A copy that waited for the history (another copy had it, or the file was busy): its first look now.
            if reopened {
                if development == nil && !recordingTrial {updates.start()}
                refreshCaptureStatus()
            }
    }
    /// The launch intent (`LaunchResume`). `consume`: the update marker is removed (it counts once), which happens only
    /// once the history is open; an earlier look leaves it.
    static func readLaunchPlan(_ defaults:UserDefaults,consume:Bool=true)->LaunchResume.Plan {
        let updated=consume ? UpdateResume.consume(defaults,now:Date()) : UpdateResume.shouldResume(marker:defaults.dictionary(forKey:UpdateResume.key),now:Date())
        return LaunchResume.plan(saved:defaults.dictionary(forKey:LaunchResume.key),updated:updated,now:Date())
    }
    /// `settleLegacyPreferences`, as launch has always run it: a settlement that fails leaves the choices as saved (they
    /// read as off) and launch goes on. Only a busy file is an open that failed: the history opens again by itself
    /// (ADV-8), and settles then.
    private static func settleLegacyChoices(_ store:MemoryStore) throws -> LegacyPreferenceSettlement? {
        do {return try store.settleLegacyPreferences()}
        catch where CaptureFault.busy(error) {throw error}
        catch {return nil}
    }
    /// Nothing of an open that failed stays open (the recorder lock goes with the Coordinator).
    private func closeHalfOpenHistory() {
        typedExpiry?.stop();typedExpiry=nil;aiReadBridge?.stop();aiReadBridge=nil;writer=nil;coordinator=nil;store=nil
    }
    /// gold r2 (ADV-8): another connection held the history for a moment as it opened. It opens again by itself; the
    /// launch intent is read now (nothing is saved or consumed) so the state says what happens: recording that was on is
    /// the calm "Couldn't save for a moment. Trying again." pause, and starts once the history opens. Nothing latches:
    /// after two minutes the one "can't save" notice goes out, as for a save that keeps failing, and the tries go on.
    private func historyOpenFailed(_ error:Error) {
        RecordingLog.note("History open failed: \(RecordingLog.name(error)); opening again.")
        let home=MemPaths.home()
        if openingHome != home {historyOpenRetry=nil}
        openingHome=home
        if launchPlan == nil, !intentLive, let intentDefaults, !launchLocation.blocksRecording {
            launchPlan=Self.readLaunchPlan(intentDefaults,consume:false)
        }
        if let launchPlan, launchPlan != .none {recordingWanted=true}
        activity.phase = .loading
        let now=Date()
        var retry=historyOpenRetry ?? StorageRetry()
        if retry.failed(now:now) && recordingWanted {
            RecordingLog.note("The history has been busy for \(Int(StorageRetry.persistentAfter)) s; notice posted.")
            showStopNotice(.storageRetrying)
        }
        historyOpenRetry=retry
        historyOpenToken += 1
        let token=historyOpenToken
        DispatchQueue.main.asyncAfter(deadline:.now()+retry.nextDelay(now:now)) { [weak self] in
            MainActor.assumeIsolated { self?.retryHistoryOpen(token) }
        }
        refreshCaptureStatus()
    }
    private func retryHistoryOpen(_ token:Int) {
        guard token == historyOpenToken, historyOpenRetry != nil, store == nil, openingHome == MemPaths.home() else {return}
        openHistory()
    }
    private func endHistoryOpenRetry() {
        historyOpenRetry=nil
        historyOpenToken += 1
    }
    /// The person's Start while the history is still opening: tried now. Opened, the ordinary Start follows (setup
    /// first, where it must); still held, recording starts once it opens, through launch's own guards.
    private func personStartWhileOpening() {
        launchPlan = LaunchResume.Plan.none
        personActedWhileOpening=true
        // Wanted once it records (`recordingBegan`); setup that must come first leaves it as the person left it.
        recordingWanted=false
        if anotherCopyStepsAside {anotherCopyRechecked(anotherCopyToken)} else {openHistory()}
        guard coordinator == nil else {return}
        launchPlan = .record
        recordingWanted=true
        refreshCaptureStatus()
    }
    /// Another DayDream holds the recorder lock, so this copy opened nothing (the copy that was running comes forward at
    /// launch and this one exits, OtherCopy.swift; this is when that couldn't happen). The lock is read again every
    /// `anotherCopyRecheck`, and the history opens by itself once it is free. A copy in the download window stepping
    /// aside is waited for quietly; otherwise, or once that has taken `anotherCopyGrace`, one short line says DayDream is
    /// already open, and tells nobody to quit anything.
    private func anotherCopyHoldsHistory() {
        endHistoryOpenRetry()
        let now=Date()
        if anotherCopySince == nil || openingHome != MemPaths.home() {anotherCopySince=now}
        openingHome=MemPaths.home()
        let other=development == nil ? OtherCopy.current.find() : nil
        let steppingAside=other.map {OtherCopy.decide(mine:launchLocation,other:$0) == .open} ?? false
        anotherCopyStepsAside=steppingAside && now.timeIntervalSince(anotherCopySince ?? now) < Self.anotherCopyGrace
        if anotherCopyStepsAside {
            anotherCopyOpen=false
            activity.phase = .loading
        } else if !anotherCopyOpen {
            RecordingLog.note("Another DayDream holds the history; waiting for it.")
            anotherCopyOpen=true
            // The window says only the one line, with nothing to press (it clears by itself once the history opens).
            status = "Another copy of DayDream is open. No capture started."; activity.phase = .held(RecordingCopy.anotherCopy)
        }
        anotherCopyToken += 1
        let token=anotherCopyToken
        DispatchQueue.main.asyncAfter(deadline:.now()+Self.anotherCopyRecheck) { [weak self] in
            MainActor.assumeIsolated { self?.anotherCopyRechecked(token) }
        }
        if anotherCopyStepsAside {refreshCaptureStatus()} else if resumeUnavailable != Self.anotherCopyBlocker {resumeUnavailable = Self.anotherCopyBlocker}
    }
    private func endAnotherCopyWait() {
        anotherCopyOpen=false;anotherCopyStepsAside=false;anotherCopySince=nil;anotherCopyToken += 1
    }
    private func anotherCopyRechecked(_ token:Int) {
        guard token == anotherCopyToken, anotherCopyOpen || anotherCopyStepsAside, store == nil, openingHome == MemPaths.home() else {return}
        if Self.recorderLockHeld(home:MemPaths.home()) {anotherCopyHoldsHistory();return}
        RecordingLog.note("The other DayDream let go of the history; opening it.")
        openHistory()
    }
    /// gold r2: a copy that can record opened while this one runs from the download window. This one records and saves
    /// nothing, so it steps aside (quits) and that copy opens the history. Not while an import or a backup runs here:
    /// then it asks again every `anotherCopyRecheck` while that copy still runs, and steps aside once the work here ends
    /// (gold/int round 2; launch's own look for a paused import is such work, right as the model opens the history).
    func otherCopyOpened(_ location:LaunchLocation) {
        guard development == nil, !recordingTrial, !functionalTrial, launchLocation.blocksRecording,
              !location.blocksRecording, location != .notAnApp else {return}
        guard !history.busy, !backups.busy, backups.prepared == nil else {stepAsideLater();return}
        RecordingLog.note("A copy that can record opened; this one steps aside.")
        launchWarningPresented=false
        OtherCopy.current.stepAside()
    }
    private var stepAsideAsked=false
    private func stepAsideLater() {
        guard !stepAsideAsked else {return}
        stepAsideAsked=true
        DispatchQueue.main.asyncAfter(deadline:.now()+Self.anotherCopyRecheck) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {return}
                self.stepAsideAsked=false
                if let later=OtherCopy.current.openedLater() {self.otherCopyOpened(later)}
            }
        }
    }
    /// The timeline (`items`) read again. gold r3-store (golden test 5, gate item 5): read off the main thread, as launch
    /// reads it (gold r2-store-perf): decoding 1000 rows held the main thread 115-240 ms after every preference save,
    /// deletion, restore and import. The newest read wins; what shows meanwhile is the last read (a deletion already
    /// took its item out, `remove`). The trials and the Development Trial read at once, as before (the trials'
    /// first-run rule reads `items` as the window appears).
    func refresh() {
        // A second copy opened nothing: its one line stays ("DayDream is already open."). A history still opening by
        // itself shows as loading until it opens (gold r2).
        guard !anotherCopyOpen, !historyOpening else {return}
        guard development == nil,!recordingTrial,!functionalTrial,let store else {refreshNow();return}
        readTimeline(store)
        refreshCaptureStatus()
    }
    /// `refresh`, read on the main thread and done when it returns (the packaged trial's check reads `items` at once).
    func refreshNow() {
        guard !anotherCopyOpen, !historyOpening else {return}
        timelineRead=nil
        refreshed(Result { guard let store else { throw MemError.missing }; return try store.timeline(limit:1000) })
    }
    /// Launch's `refresh` (gold r2-store-perf): the window says "Loading local activity…" until the read lands;
    /// recording's status doesn't wait for it.
    private func refreshAtLaunch() {
        guard development == nil,!recordingTrial,!functionalTrial,!anotherCopyOpen,let store else {refreshNow();return}
        readTimeline(store)
        refreshCaptureStatus()
    }
    /// One timeline read off the main thread. A read another connection held the history for is read again a moment
    /// later (a few times), unless a newer read has started.
    private func readTimeline(_ store:MemoryStore,attempt:Int=0) {
        let read=UUID()
        timelineRead=read
        DispatchQueue.global(qos:.userInitiated).async {
            let result=Result { try StoreWait.lettingMainIn { try store.timeline(limit:1000) } }
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
                guard let self,self.timelineRead == read else {return}
                if case .failure(let error)=result,CaptureFault.busy(error),attempt < Self.timelineReadTries,self.store === store {
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { MainActor.assumeIsolated { [weak self] in
                        guard let self,self.timelineRead == read,self.store === store else {return}
                        self.readTimeline(store,attempt:attempt+1)
                    } }
                    return
                }
                self.timelineRead=nil
                self.refreshed(result)
            } }
        }
    }
    static let timelineReadTries=5
    /// The timeline read in flight (`readTimeline`); a newer read (or `refreshNow`) replaces it, so the older is dropped.
    private var timelineRead:UUID?
    private func refreshed(_ read:Result<[MemoryItem],Error>) {
        guard !anotherCopyOpen else {return}
        do {
            items = try read.get()
            activity.items = items; activity.phase = .ready
            if activity.scope?.wholeDay == true { activity.showDay() }
            refreshCaptureStatus()
            dayData.refreshToday(false)
        }
        catch {
            // A read that failed (another connection held the file, say) never stops recording or leaves a problem line:
            // the next commit or refresh reads again. Only a timeline that never loaded says it couldn't read.
            RecordingLog.note("Timeline read failed: \(RecordingLog.name(error)); recording unchanged.")
            if case .ready = activity.phase {} else { activity.phase = .failed("Local activity could not be read. Try again.") }
        }
    }
    /// The 1000 most recent timeline items, read off the main thread when a page needs them (Settings › Apps ranks
    /// apps by recent use). `items` itself is loaded at launch and after history changes (`refresh`).
    func recentUsage() async -> [MemoryItem] {
        guard let store, development == nil else {return items}
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos:.utility).async { continuation.resume(returning:(try? store.timeline(limit:1000)) ?? []) }
        }
    }
    private func scheduleLegacySummaries() {
        guard development == nil,!recordingTrial else {return}
        guard !history.busy,!backups.busy,backups.prepared==nil,summaryJobs==0,let writer else {return}
        summaryJobs += 1
        writer.schedule { [weak self] result in Task { @MainActor in
            // No reload here: a summary job changes nothing any view shows (the day's moments read the actions and
            // notes; Settings › Apps reads recent use when it opens, `recentUsage`), and reloading 1000 timeline rows
            // on the main thread after every captured event was what froze the menu bar and dropped typed keys.
            guard let self else {return};self.summaryJobs -= 1
            // One failed job (another connection held the file, say) says nothing and changes nothing: the next one, within
            // a minute, tries again. Three in a row show the line; the next job that works clears it.
            if case .failure = result {
                self.summaryFailures += 1
                if self.summaryFailures >= Self.summaryFailuresShown {self.operationalIssue=Self.summaryIssue}
            } else {
                self.summaryFailures=0
                if self.operationalIssue == Self.summaryIssue {self.operationalIssue=nil}
            }
        }}
    }
    func refreshCaptureStatus() {
        // gold r3-store: every state change runs this on the main thread (a failed save, a pause, the heartbeat), so its
        // reads wait at most a moment for another connection's lock. A read given up that way keeps what it showed (the
        // label's summary setting, typing's state) or holds nothing back (the replacement read, as a failed one did).
        _ = StoreWait.bounded(Coordinator.mainWaitBudget) { refreshCaptureStatusBounded() }
    }
    private func refreshCaptureStatusBounded() {
        if development != nil {recording=false;resumeUnavailable="Disabled in Development Trial";status=development?.preview == true ? PreviewSample.line : "Development Trial · synthetic data · capture and writers OFF";return}
        // One false permission read is not a stop (Coordinator.recordingSettled): it would flash a stop notice and lose
        // the start time. This runs on every 0.5 s heartbeat while recording. It reads no history (no count, no scan),
        // and it writes a published field only when the value changed: every write redraws each view watching this
        // model, the menu bar label and the Recording menu included.
        #if DEVELOPMENT_SOURCE_CHECKS
        // The setup checks draw setup "while recording" without starting anything (setup-upgrade-checks).
        let running = recordingForChecks ?? coordinator?.recordingSettled ?? false
        #else
        let running = coordinator?.recordingSettled ?? false
        #endif
        if recording != running { recording = running }
        // A recorder that stopped itself (a failed save, a lost tap) is not live: drop it, so a lock that follows never
        // pauses it again with "Resumes after unlock" (EventCapture.onStopped does the same at once).
        if capture?.isStopped == true {capture=nil}
        // Keyboard and mouse input that stopped is the pause's own line ("…input was interrupted"), never a second one.
        if operationalIssue != nil, operationalIssue == Self.choicesUnsavedIssue, !preferencesUnresolved {operationalIssue=nil}
        let blocker = recording ? nil : resumeBlocker(waiting:true)
        if resumeUnavailable != blocker { resumeUnavailable = blocker }
        // A timed pause keeps its promise while something stands in the way: at its end it tries, and says why if it
        // can't (`armTimedPause`). Only a session that is no longer paused (a Stop, a saved setting) ends it here. A
        // pause whose write failed for a moment (the session reads "error") is still the person's pause: nothing
        // records, and its end tries again, where a save that still fails is retried by itself (StorageRetry).
        if !schedulingPause, pauseUntil != nil, let state=coordinator?.session.state, state != "paused", state != "error" { cancelTimedPause() }
        // The session's state and reason are in this line (`Coordinator.label`), so a change there still redraws the
        // views that derive from them.
        // claude/permflash-015: read first, so the line below already follows what is shown of the permissions.
        readPermissions()
        var line = coordinator?.label ?? (historyOpening ? "Capture OFF. Opening the history again." : "Capture OFF. Storage unavailable.")
        if let resumeUnavailable, !permissionBlockerUnsettled { line += " " + resumeUnavailable + ". " + resumeExplanation }
        if let operationalIssue { line += " " + operationalIssue + ". Original local evidence remains available unless storage itself is unavailable." }
        if recording { line += " " + AccessibilityReader.status }
        if status != line { status = line }
        noteRecording(recording)
        // Once recording is off its start time no longer applies. A later start that skips startCapture
        // (a permission granted back while the session still says recording) then shows no time.
        if !recording && transitions.recordingSince != nil {transitions.notRecording()}
        let kind=recordingState.kind
        if kind != presentedKind {presentedKind=kind;dayData.refreshToday(false)}
        // claude/perf3-1005: a heartbeat read typing off the main thread just now (`TypingModel.beatReads`).
        if !typing.takeBeatRefresh() {typing.refresh(frontmostBundle:NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")}
        syncLockWatch()
        syncPermissionWatch()
    }
    /// Preflight reads only; neither call prompts.
    private func readPermissions() {
        let read=Self.permissionRead?() ?? PermissionSnapshot(accessibility:AXIsProcessTrusted(),inputMonitoring:CGPreflightListenEventAccess())
        if permissionsAtLaunch == nil {
            permissionsAtLaunch=read
            if read.inputMonitoring == false {
                // gold r2 (V1): a read decides, not a deadline. The one read that follows at a launch with nothing to
                // resume is this one, `confirmAfter` later; it refreshes the state too, so a launch blip leaves no Needs
                // Permission behind.
                launchReadUnconfirmedSince=Date()
                DispatchQueue.main.asyncAfter(deadline:.now()+InputMonitoringWatch.confirmAfter+0.1) { [weak self] in
                    MainActor.assumeIsolated { self?.refreshCaptureStatus() }
                }
            }
        } else if let since=launchReadUnconfirmedSince, let on=read.inputMonitoring {
            // gold G33 (final review): an off read at launch that reads on again before anything confirms it was a
            // moment's "not allowed", not Input Monitoring turned on after launch (which would need Quit & Reopen).
            if on {permissionsAtLaunch?.inputMonitoring=true;launchReadUnconfirmedSince=nil}
            else if awake && !wake.suspended && Date().timeIntervalSince(since) >= InputMonitoringWatch.confirmAfter {launchReadUnconfirmedSince=nil}
        }
        noteInputMonitoring(read)
        lastPermissionRead=read
        showPermissions(read)
        considerAutoRelaunch(read)
        // Only whether a read happened is shown (`presentation.permissions`); a new time on every tick redrew everything.
        if permissionsCheckedAt == nil {permissionsCheckedAt=activity.now()}
    }
    /// claude/permflash-015: what the surfaces show of a read (`permissionSnapshot`). Asleep, locked or switched away, an
    /// off read says nothing; in the first seconds after that ends it must hold for longer (`settleAfterWake`). While an
    /// off read waits to hold, one more read runs once it has had the time, so a permission really turned off shows by
    /// itself about `PermissionSettle.settle` after its first off read, with nothing else refreshing.
    private func showPermissions(_ read:PermissionSnapshot) {
        let now=Date()
        let afterWake=inputWatchQuietUntil.map { now < $0 } ?? false
        let settle=afterWake ? PermissionSettle.settleAfterWake : PermissionSettle.settle
        let shown:PermissionSnapshot
        if permissionReadAsIs {permissionReadAsIs=false;shown=permissionShown.take(read)}
        else {shown=permissionShown.read(read,at:now,settle:settle,counts:awake && !wake.suspended)}
        if shown != permissionSnapshot {permissionSnapshot=shown}
        guard permissionShown.unsettled,!permissionSettleReadSet else {return}
        permissionSettleReadSet=true
        DispatchQueue.main.asyncAfter(deadline:.now()+settle+0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {return}
                self.permissionSettleReadSet=false
                if self.permissionShown.unsettled {self.refreshCaptureStatus()}
            }
        }
    }
    /// perm-1004: Input Monitoring turned on after launch needs DayDream to reopen. Once both permissions read on,
    /// DayDream restarts itself, once (`PermissionRelaunch.restartsByItself`), after the page's one line has shown for
    /// `autoDelay`; the conditions are read again just before it does.
    private func considerAutoRelaunch(_ read:PermissionSnapshot) {
        guard development == nil,!recordingTrial,!functionalTrial,!permissionAutoRelaunch,autoRelaunchAllowed(read) else {return}
        permissionAutoRelaunch=true
        RecordingLog.note("Input Monitoring turned on after launch; DayDream restarts itself to use it.")
        DispatchQueue.main.asyncAfter(deadline:.now()+PermissionRelaunch.autoDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {return}
                let again=Self.permissionRead?() ?? PermissionSnapshot(accessibility:AXIsProcessTrusted(),inputMonitoring:CGPreflightListenEventAccess())
                guard self.autoRelaunchAllowed(again) else {self.permissionAutoRelaunch=false;return}
                Self.autoRelaunchDefaults.set(Date(),forKey:Self.autoRelaunchKey)
                // A restart that couldn't start leaves the page's Quit & Reopen (the line would be untrue).
                if !Self.performAutoRelaunch(self) {self.permissionAutoRelaunch=false}
            }
        }
    }
    private func autoRelaunchAllowed(_ read:PermissionSnapshot)->Bool {
        PermissionRelaunch.restartsByItself(inputMonitoringAtLaunch:permissionsAtLaunch?.inputMonitoring,
                                            launchReadSettled:launchReadUnconfirmedSince == nil,
                                            accessibility:read.accessibility,inputMonitoring:read.inputMonitoring,
                                            recording:recording,canReopen:Self.canReopen(),
                                            lastAutoRestart:Self.autoRelaunchDefaults.object(forKey:Self.autoRelaunchKey) as? Date,now:Date())
    }
    /// An off read is read again `confirmAfter` later; still off, it counts as off at launch.
    private func noteInputMonitoring(_ read:PermissionSnapshot) {
        guard let on=read.inputMonitoring else {return}
        let now=Date()
        let counts=awake && !wake.suspended && inputWatchQuietUntil.map { now >= $0 } ?? true
        if inputMonitoringWatch.read(inputMonitoring:on,at:now,counts:counts) {
            DispatchQueue.main.asyncAfter(deadline:.now()+InputMonitoringWatch.confirmAfter+0.1) { [weak self] in
                MainActor.assumeIsolated { self?.readPermissions() }
            }
        }
        if inputMonitoringWatch.seenOff,permissionsAtLaunch?.inputMonitoring == true {permissionsAtLaunch?.inputMonitoring=false}
    }
    /// gold r3 (gate item 2): a key reached the input tap, so Input Monitoring works in this run whatever the reads said.
    /// An off read at launch or later (`InputMonitoringWatch`) no longer sends Start to Quit & Reopen. A tap macOS won't
    /// feed gets no keys, so this never clears a reopen that is really needed (capture-input G32).
    private func keysArrived() {
        guard development == nil,permissionsAtLaunch?.inputMonitoring == false || inputMonitoringWatch.seenOff || launchReadUnconfirmedSince != nil else {return}
        RecordingLog.note("Keys reach DayDream; Input Monitoring works.")
        inputMonitoringWatch.provedOn()
        launchReadUnconfirmedSince=nil
        permissionsAtLaunch?.inputMonitoring=true
    }
    /// claude/typing-1004 (owner laptop, public 0.1.4): recording, yet keys the Mac counted never reached the input tap
    /// (`KeyArrivalWatch`): macOS feeds the tap only after DayDream reopens (Input Monitoring turned on, or its row
    /// changed, after launch), whatever the permission reads say. DayDream restarts itself once, as perm-1004 does for
    /// Input Monitoring turned on after launch (recording was on, so it starts again after the restart: the quit keeps the
    /// launch intent). A restart within `PermissionRelaunch.autoCooldown`, or one DayDream can't make, isn't tried: the
    /// recording stops with the tap's reason, so Start goes to the Permissions page and its Quit & Reopen
    /// (`inputNeedsReopen`) instead of showing Recording while no key is saved.
    private func keysNotArriving() {
        guard development == nil,!recordingTrial,!functionalTrial,recording else {return}
        let now=Date()
        let last=Self.autoRelaunchDefaults.object(forKey:Self.autoRelaunchKey) as? Date
        let cooled=last.map { now < $0 || now.timeIntervalSince($0) >= PermissionRelaunch.autoCooldown } ?? true
        if cooled,Self.canReopen(),!permissionAutoRelaunch {
            RecordingLog.note("No key reached the input tap; DayDream restarts itself to use Input Monitoring.")
            permissionAutoRelaunch=true
            Self.autoRelaunchDefaults.set(now,forKey:Self.autoRelaunchKey)
            if Self.performAutoRelaunch(self) {return}
            permissionAutoRelaunch=false
        }
        RecordingLog.note("No key reached the input tap; recording stopped until DayDream reopens.")
        // EventCapture's own reason for a tap that can't reach the keyboard: "Keyboard and mouse aren't reaching
        // DayDream." in the app, and its "Input event tap" prefix sends Start to Quit & Reopen (`inputNeedsReopen`).
        capture?.stop(reason:"Input event tap unavailable. No recording started.")
        capture=nil
        refreshCaptureStatus()
    }
    /// A sleep, lock or user switch began or ended: an Input Monitoring off read before it confirms nothing after it, and
    /// reads in the first `InputMonitoringWatch.afterWake` after it ends don't count.
    private func inputWatchInterrupted() {
        inputMonitoringWatch.interrupted()
        permissionShown.interrupted()
        inputWatchQuietUntil=Date().addingTimeInterval(InputMonitoringWatch.afterWake)
    }
    /// "Check Again": re-reads permissions and the recording state. Never prompts.
    func checkPermissions() {refreshCaptureStatus()}
    /// Why Start can't record now, or nil. An import or backup still running ends by itself, so it counts only with
    /// `waiting` (what the surfaces show); an automatic start waits for it instead (`startWhenFree`). It is checked last,
    /// so nothing else stands when it is the answer.
    func resumeBlocker(waiting:Bool=false,permission:Bool=true)->String? {
        if development != nil {return "Disabled in Development Trial"}
        resumeExplanation="Review Setup in Settings. No recording or permission request was started."
        if launchLocation.blocksRecording { resumeExplanation=LaunchLocation.detail; return LaunchLocation.blockerValue }
        guard awake else { return "Resume after waking" }
        // gold r2: a history still opening by itself is not a blocker (Start tries it at once).
        guard store != nil, coordinator != nil else { return historyOpening ? nil : anotherCopyOpen ? Self.anotherCopyBlocker : "Storage unavailable" }
        // A save that failed earlier never blocks Start: Start is how it tries again.
        guard !replacementBusy else { return "Replacement in progress" }
        do {
            if try replacement?.record() != nil {
                if try replacement?.permitsStart() != true { return "Review replacement" }
            } else if let explanation=InstallationReview.captureBlocker(InstallationReview.legacy(at:FileManager.default.homeDirectoryForCurrentUser)) {
                resumeExplanation=explanation; return "Review replacement"
            }
        } catch {
            // A read that failed for a moment (another connection held the file) is not a replacement to review: Start
            // reads it again and records nothing unless that read says it may (a failed one is a failed save).
            RecordingLog.note("Replacement read failed: \(RecordingLog.name(error)).")
        }
        if backups.prepared != nil {
            // One whose five minutes ran out can't be confirmed any more: it is closed, as Cancel does, and holds nothing back.
            guard let closed=backups.closeExpiredPreview(now:Date()) else { return Self.restoreBlocker }
            try? store?.cancelCanonicalRestore(closed)
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.backups.onResolved() } }
        }
        // One read, settled like recording's own (gold/save-path G33): a single false read never cancels a timed pause.
        // An automatic start leaves the permissions to its own read (`permission` false: `holdForPermission`).
        guard !permission || coordinator?.permittedSettled() ?? Self.permissionsGranted() else {
            resumeExplanation="Accessibility and Input Monitoring are required. Review macOS permissions in Setup; permission requests remain explicit."
            return "Permissions required"
        }
        if waiting && waitingOnOperation { return Self.operationBlocker }
        return nil
    }
    /// An import or backup is running (history recovery at launch is only a read and holds nothing back).
    private var waitingOnOperation:Bool { history.blocksRecording || backups.busy }
    func cancelTimedPause() { timedPause.cancel(); resumeTimer?.invalidate(); resumeTimer=nil; pauseUntil=nil }
    func pauseFor(minutes:Int) {
        let wasRecording=recording
        personActed()
        withStopIntent(.person) { pauseCapture("Paused by you",commitTyping:true) }
        guard resumeBlocker() == nil else { return }
        guard let ticket=timedPause.begin(minutes:minutes,wasRecording:wasRecording,now:Date()) else { return }
        pauseUntil=ticket.deadline
        armTimedPause(ticket)
    }
    /// The timed pause's one-second timer: at the deadline it resumes through startCapture, once, or says
    /// why it couldn't (the notice is the same one a stop on its own gets). It resumes whichever app is in
    /// front, like Resume: every event is still filtered as it is recorded. The timer runs in the common
    /// run-loop modes, so an open menu or a tracking loop doesn't hold the resume back. What stands in the way is
    /// read at the deadline only: something that passes meanwhile (a read that failed for a moment) never ends the
    /// pause early, and an import or backup still running then holds the start until it ends (`startWhenFree`).
    private func armTimedPause(_ ticket:TimedPause.Ticket) {
        resumeTimer?.invalidate()
        let timer=Timer(timeInterval:1,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.timedPause.ticket == ticket else { return }
                guard Date() >= ticket.deadline else { return }
                let resume=self.timedPause.expire(ticket,now:Date(),permitted:self.coordinator?.permittedSettled() ?? Self.permissionsGranted(),replacementSafe:self.resumeBlocker() == nil,awake:self.awake)
                self.cancelTimedPause()
                if resume { self.timedPauseEnded(); return }
                self.starting = .automatic
                self.pauseCapture("Resume canceled: prerequisites changed. Review Settings.")
                self.starting = .no
                if !self.recording { self.timedResumeFailed() }
            }
        }
        timer.tolerance=0.2
        RunLoop.main.add(timer,forMode:.common)
        resumeTimer=timer
    }
    /// A timed pause's end starts recording as Resume does (an import or backup still running holds it until it ends; a
    /// permission read off for a moment reads again first), or says why it couldn't.
    private func timedPauseEnded() {
        guard automaticStart(again:{ [weak self] in self?.timedPauseEnded() }) == .ran else { return }
        if !recording { timedResumeFailed() }
    }
    /// A timed pause ended and recording didn't start again: one notice with why and how.
    private func timedResumeFailed() {
        let cause=currentStopCause()
        // A failed save: StorageRetry starts recording, as the pause promised, once it can save.
        if cause == .storage {storageFaulted();return}
        recordingWanted=false
        showStopNotice(.timedPauseEnded(cause:cause,resumeTitle:resumeTitle))
    }
    func stopCapture() {
        let wasOff=stopped && !recording
        personActed()
        cancelTimedPause()
        let finish = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.withStopIntent(.person) {
                    self.coordinator?.stop(); self.capture?.stop(reason:"Stopped by you"); self.capture=nil
                    if !wasOff { self.transitions.stopped(at:self.activity.now()) }
                    self.stopped=true; self.refreshCaptureStatus()
                }
            }
        }
        guard let ending=capture else { finish(); return }
        ending.finishPendingTyping { [weak self, weak ending] in
            MainActor.assumeIsolated {
                guard let self, let ending, self.capture === ending else { return }
                finish()
            }
        }
    }
    func startCapture() {
        guard development == nil else {return}
        #if DEVELOPMENT_SOURCE_CHECKS
        // setup-upgrade-checks and the setup renders: nothing ever records; a start is only counted.
        if Self.refuseCaptureForChecks {Self.refusedCaptureStarts += 1;return}
        #endif
        // From the download window nothing records: say so again instead (SPEC 6.3 R3).
        guard !launchLocation.blocksRecording else {launchWarningPresented=true;refreshCaptureStatus();return}
        if starting == .no {starting = .person}
        defer {if starting == .person {starting = .no}}
        // The person's own Start replaces an automatic start still waiting to read the permissions again.
        if starting == .person {endPermissionHold();endPermissionComeback()}
        // gold r2 (ADV-8): the history is still opening. The person's Start tries it now; an automatic start (a wake)
        // leaves recording wanted, and it starts once the history opens.
        if historyOpening, coordinator == nil {
            if starting == .person {personStartWhileOpening()} else {recordingWanted=true;refreshCaptureStatus()}
            if coordinator == nil {return}
        }
        // Every false → true transition, including a timed pause resuming itself (resumeTimer calls startCapture).
        let wasRecording=recording
        defer {if recording && !wasRecording {transitions.recordingStarted(at:activity.now())}}
        // A choice still waiting for its short save delay is saved now, so Start never trips over it.
        saveWaitingChoices()
        // A change saving by itself after a busy moment didn't fail: recording starts once it lands (preferencesChanged;
        // trials keep their own Start).
        if preferenceSave?.saving == true,!recordingTrial,!functionalTrial {resumeAfterSave=true;refreshCaptureStatus();return}
        guard !privacyDirty,preferenceSave?.draft == nil,preferenceSave?.error == nil else {operationalIssue=Self.choicesUnsavedIssue;return}
        if operationalIssue == Self.choicesUnsavedIssue {operationalIssue=nil}
        // An import, a backup or a restore preview: the state already says so (`resumeBlocker`), and it clears itself.
        guard !waitingOnOperation,backups.prepared == nil else {refreshCaptureStatus();return}
        cancelTimedPause()
        stopped=false
        guard !replacementBusy else { return }
        guard let coordinator, let store else { return }
        do {
            if try replacement?.record() != nil {
                guard try replacement?.permitsStart() == true else {
                    pauseCapture("Resolve replacement or rollback before recording."); return
                }
            } else if let blocker = InstallationReview.captureBlocker(InstallationReview.legacy(at:FileManager.default.homeDirectoryForCurrentUser)) {
                pauseCapture(blocker); return
            }
            // One read decides the start (gold G33, final review: a second read inside the start could disagree). An
            // automatic start that reads a permission off waits and reads again (`holdForPermission`): a moment's "not
            // allowed" never stops recording for good. The person's own Start takes the read as it is.
            let permitted=Self.permissionsGranted()
            if !permitted {
                if starting == .automatic, !permissionLossSettled, let again=automaticAgain { holdForPermission(again); return }
                // claude/permflash-015: the person's own Start is shown as it read, at once (nothing waits to settle).
                if starting == .person {permissionReadAsIs=true}
                try coordinator.start(permitted:false); refreshCaptureStatus(); return
            }
            // Both read on: any start still waiting to read them again is this one.
            endPermissionHold()
            if recordingTrial {trialStartedAt=Date()}
            capture?.stop(reason:"Replacing stopped capture"); capture = nil
            // Starting must not silently rewrite/delete historical evidence.
            // A stored privacy prohibition still wins over a runtime choice.
            let savedPolicy = try store.policy()
            captureText = captureText && savedPolicy.captureText
            coordinator.captureText = captureText
            coordinator.resolveBrowserProvider(bundle:Bundle.main)
            try coordinator.start(permitted:permitted)
            guard coordinator.recordingSettled else { refreshCaptureStatus(); return }
            let next = EventCapture(coordinator:coordinator)
            next.pages.onAccess = { [weak self] access in MainActor.assumeIsolated { self?.chromeAccessFromPages(access) } }
            next.onKeyInput = { [weak self] in MainActor.assumeIsolated { self?.keysArrived() } }
            next.onKeysNotArriving = { [weak self] in MainActor.assumeIsolated { self?.keysNotArriving() } }
            // A recorder that stops itself is dropped at once: it is no longer live. It stops on the main thread (its
            // timer, the tap, a pause); refreshCaptureStatus drops a stopped one too.
            next.onStopped = { [weak self, weak next] in
                guard Thread.isMainThread else {return}
                MainActor.assumeIsolated { if let self, let next, self.capture === next { self.capture=nil } }
            }
            capture = next
            // A tap that couldn't be installed pauses the session with its own reason, which the state shows.
            if !Self.startInput(next) { capture = nil }
            refreshCaptureStatus()
        } catch {
            // The start couldn't save. Recording stays wanted and StorageRetry tries again by itself; Start (Resume)
            // tries at once.
            RecordingLog.note("Start failed: \(RecordingLog.name(error)).")
            withStopIntent(.storage) { pauseCapture(CaptureFault.retryReason) }
            storageFaulted()
        }
    }
    /// Ordinary user pause drains admitted drafts while authority is live.
    /// Chrome drafts at sleep/lock and privacy pauses discard immediately;
    /// they never wait for a proof or continue a drain after suspension.
    func pauseCapture(_ reason: String = "Paused by you", commitTyping: Bool = false) {
        if stopIntent == .person || RecordingStopCause.personReasons.contains(reason) || reason.hasPrefix("Paused for uninstall") {endPermissionComeback()}
        cancelTimedPause()
        if commitTyping, reason == "Paused by you", let ending=capture {
            let intent=stopIntent
            ending.finishPendingTyping { [weak self, weak ending] in
                MainActor.assumeIsolated {
                    guard let self, let ending, self.capture === ending else { return }
                    self.withStopIntent(intent) { self.finishPauseCapture(reason) }
                }
            }
            return
        }
        // The legacy native-only quit/update flush stays synchronous. An OS
        // suspension cannot start an asynchronous Chrome read or keep a drain alive.
        if commitTyping { capture?.commitPendingTyping() }
        finishPauseCapture(reason)
    }
    private func finishPauseCapture(_ reason: String) {
        let alreadyStopped=stopped && !recording
        let wasRecording=recording
        stopped=alreadyStopped
        schedulingPause=true
        if alreadyStopped { coordinator?.stop() } else { coordinator?.pause(reason) }
        capture?.stop(reason:reason); capture = nil
        schedulingPause=false
        if !alreadyStopped {transitions.paused(fromRecording:wasRecording,at:activity.now())}
        refreshCaptureStatus()
    }
    /// A failed deletion is its own line, never a change to recording (a timed pause keeps running). DayDream keeps what
    /// the person asked to delete and tries it again every minute (`retryFailedDeletions`) and on Try Again; the line
    /// clears once every deletion that failed has gone through (another deletion working says nothing about this one).
    func remove() {
        guard let selected else { return }
        do { try store?.delete(selected); self.selected = nil; deletionWorked(selected); deleted(selected) } catch { deletionFailed(selected) }
    }
    func removeSource(_ id: String) {
        do { try store?.delete(id); deletionWorked(id); deleted(id) } catch { deletionFailed(id) }
    }
    /// A deletion went through: its item leaves what shows now (gold r3-store: the timeline is read again off the main
    /// thread, so nothing deleted shows meanwhile).
    private func deleted(_ id:String) {
        if items.contains(where:{ $0.id == id }) { items.removeAll { $0.id == id }; activity.items = items }
        dayData.invalidateAll(); refresh()
    }
    private func deletionFailed(_ id:String) { status = "Deletion failed."; failedDeletions.insert(id); operationalIssue=Self.deletionIssue }
    private func deletionWorked(_ id:String) {
        failedDeletions.remove(id)
        guard failedDeletions.isEmpty else {return}
        if operationalIssue == Self.deletionIssue {operationalIssue=nil}
    }
    /// What the person asked to delete that didn't go through yet (ids only; nothing is shown or logged).
    private var failedDeletions=Set<String>()
    /// Every minute (the maintenance timer) and on Try Again: each deletion that failed, once more.
    private func retryFailedDeletions() {
        guard store != nil else {return}   // no history open: nothing can be deleted, so nothing is dropped either
        for id in failedDeletions.sorted() {removeSource(id)}
    }
    /// Try Again beside the orange line (the menu bar panel, the status popover, the Settings card): the job the line is
    /// about, now. Only the history upkeep and a failed deletion have one (`RecordingCopy.retriedIssues`); recording is
    /// never started, paused or stopped here.
    func retryIssue() {
        switch operationalIssue {
        case Self.summaryIssue?: scheduleLegacySummaries()
        case Self.deletionIssue?: retryFailedDeletions()
        default: break
        }
    }
    static let deletionIssue="Deletion failed"
    static let summaryIssue="Summary writer needs attention"
    /// Summary jobs that must fail in a row (one a minute) before the line shows.
    static let summaryFailuresShown=3
    func savePolicy() {
        // Compatibility action for existing views. Never updatePolicy, retention,
        // domains, grant creation or capture activation.
        guard retention == savedPrivacy.retentionDays,blockedDomains == savedPrivacy.blockedDomains.joined(separator:", ") else {
            privacySaveStatus="Retention and domain changes require separate review.";return
        }
        if preferenceSave?.draft == nil {queuePreferences()}
        preferenceSave?.flush()
    }
    /// Setup's Apps page, also while recording (owner 9/28): the same save Settings makes (PreferenceAutosave), which
    /// sets recording down for the save and starts it again with the saved choices.
    func saveOnboardingPreferences(excluded:Set<String>,typedText:Bool,browserPages pages:Bool?=nil) {
        // A change still waiting for its short save delay (the typing switch `TypingModel.turnOn` just saved) is folded
        // into this one save; a failed save stays failed (its problem shows).
        guard development == nil,preferencesAvailable,preferenceSave?.error == nil else {return}
        blockedApps=excluded.sorted().joined(separator:", ")
        captureText=typedText
        // Setup's "Web pages in Chrome" switch (opt-out); a release without Chrome page history keeps it off.
        if let pages {browserPages=pages && ReleaseFeatures.chromePageHistory}
        queuePreferences(typingChoiceShown:true)
        preferenceSave?.flush()
    }
    var onboardingPreferencesCurrent:Bool {
        guard let store,let preferenceSave else {return false}
        return (try? store.policy().revision) == preferenceSave.policy.revision
    }
    /// The switches the person explicitly set (SetupChoices, shared with Settings): nil fields were never chosen, so setup
    /// and what's-new show them on.
    func setupChoicesRead()->SetupChoices {
        guard development == nil,let store else {return SetupChoices()}
        return (try? store.setupChoices()) ?? SetupChoices()
    }
    /// Setup's Apps page saved both switches: each is now the person's explicit choice (Messages and email keeps its own).
    func recordSetupChoices(typing:Bool,chromePages:Bool) {
        guard development == nil,let store else {return}
        var choices=(try? store.setupChoices()) ?? SetupChoices()
        choices.typing=typing ? .on:.off
        choices.chromePages=chromePages ? .on:.off
        choices.at=ISO8601DateFormatter().string(from:Date())
        do {try store.saveSetupChoices(choices)} catch {RecordingLog.note("Setup choices not saved: \(RecordingLog.name(error)).")}
    }
    var onboardingTypingChoicePending:Bool {
        guard development == nil,let store else {return false}
        return (try? store.nativeTypingChoicePending()) == true
    }
    /// `typingChoiceShown`: the save comes from setup's apps page, which shows the typing switch (fix/typing-e2e L3).
    private func queuePreferences(typingChoiceShown:Bool=false) {
        guard let preferenceSave else {return}
        // The owner's sites go only when they changed: nil keeps the saved list, so an older entry the site
        // rule no longer accepts can never block saving an unrelated choice.
        let domains=parsedDomains
        preferenceSave.submit(MemoryPreferences(blockedApps:blockedApps.split(separator:",").map {$0.trimmingCharacters(in:.whitespaces)},nativeTyping:development == nil && captureText,
                                                blockedDomains:Set(domains) == Set(savedPrivacy.blockedDomains) ? nil:domains,
                                                browserPages:development == nil && browserPages,typingChoiceShown:typingChoiceShown,
                                                emailSubjects:emailSubjects == savedPrivacy.emailSubjects ? nil:emailSubjects))
    }
    /// The draft site list: `blockedDomains` split on commas, trimmed, without empty entries.
    var parsedDomains:[String] {blockedDomains.split(separator:",").map {$0.trimmingCharacters(in:.whitespaces)}.filter {!$0.isEmpty}}
    func reloadPreferences() {preferenceSave?.reload()}

    // MARK: Start goes through setup when something there must be done first

    /// What `startCapture` says when a change that didn't save stops it (a timed pause or a wake starting again;
    /// every Start control goes to setup's Apps page first).
    static let choicesUnsavedIssue=RecordingCopy.choicesUnsaved
    /// `@AppStorage` in the setup, the main window and the menu bar.
    static let setupCompletedKey="DaydreamOnboardingCompletedV1"
    /// Launch (G45): opens the history, repairing it first when SQLite reported it damaged (StoreIntegrity). A usual
    /// launch reads nothing extra (one file lookup). An open that SQLite itself says failed on damage is repaired and
    /// tried once more, so a damaged file never leaves "Storage unavailable" for good. `kept` runs when the repair kept
    /// the damaged file because some rows couldn't be read (the menu's line, Backup and restore's button).
    /// `repairs` false: launch already looked before the model existed (HistoryPreparation), so the open doesn't look again
    /// (a whole-file check it couldn't finish would otherwise run again here, on the main thread).
    static func openHistory(_ home:URL,defaults:UserDefaults = .standard,repairs:Bool=true,kept:()->Void,opening:() throws->MemoryStore) throws->MemoryStore {
        func repair() { _=repairDamagedHistory(home,defaults:defaults) }
        if repairs {repair()}
        let store:MemoryStore
        do {store=try opening()}
        catch where StoreIntegrity.damageNoted(home) {repair();store=try opening()}
        sayRepair(store,defaults:defaults,kept:kept)
        return store
    }
    /// A repair that lost something, said as the history opens, from the new file itself (`MemoryStore.unsaidRepair`,
    /// written there by the repair and put in place with it): whichever launch made it (this open's, or launch's
    /// preparation off the main thread) and however that launch ended, a quit or a second copy before the model existed
    /// included (gold r2-store-perf review round 1). Choices that couldn't be read back send Start through setup again,
    /// and the kept damaged file gets the menu's line. Then it is cleared, so it is said once.
    static func sayRepair(_ store:MemoryStore,defaults:UserDefaults = .standard,kept:()->Void) {
        guard let unsaid=store.unsaidRepair() else {return}
        if !unsaid.keptChoices {defaults.set(false,forKey:setupCompletedKey)}
        kept()
        store.repairSaid()
    }
    /// The repair itself, only while no other copy records into the history: the recorder lock (Coordinator's
    /// capture.lock) is held for it, and a copy that holds it keeps its history as it is (this one then says another copy
    /// is open). Every row SQLite can read is kept with the same choices; choices that couldn't be read back mean setup
    /// asks for them again before anything records (a new file's defaults leave out none of the apps and sites the person
    /// left out). nil when nothing changed.
    static func repairDamagedHistory(_ home:URL,defaults:UserDefaults = .standard)->StoreIntegrity.Repair? {
        guard let repair=HistoryPreparation.repair(home:home) else {return nil}
        if !repair.keptChoices {defaults.set(false,forKey:setupCompletedKey)}
        return repair
    }
    /// Both recording permissions, read without a prompt. The checks substitute a read.
    static var permissionsGranted:()->Bool = { Coordinator.permitted }
    /// This process can quit and open itself again (an app bundle). The checks substitute an answer.
    static var canReopen:()->Bool = { PermissionRequests.canRelaunch(Bundle.main.bundleURL) }
    /// The setup page a Start control asked for; the setup window shows it and clears it.
    @Published var setupRequest:DaydreamOnboardingPage?
    /// Where Start must go first, or nil when it can start: setup never finished or a permission missing →
    /// setup (Permissions, or wherever setup is when both are allowed); a change that didn't save → Apps.
    /// A change still waiting for its short save delay is saved here. Previews, trials and a history that
    /// could not open have no setup to go to (their Start says why itself).
    /// `permission` false (an automatic start): the permissions are left to the start's own read (`holdForPermission`),
    /// and an Input Monitoring off read at launch not yet confirmed doesn't count.
    func setupStepForStart(permission:Bool=true)->DaydreamOnboardingPage? {
        guard development == nil,!recordingTrial,!functionalTrial,store != nil,coordinator != nil,!launchLocation.blocksRecording else {return nil}
        let permitted = !permission || Self.permissionsGranted()
        // A failed event tap (ui-copy G11, `inputNeedsReopen`) or Input Monitoring turned on while DayDream was open
        // (capture-input) works only once DayDream reopens: setup's Permissions page, whose one button is then Quit &
        // Reopen (where DayDream can reopen itself).
        if !permitted || inputNeedsReopen {return .permissions}
        // An off launch read not confirmed yet: read now, so a read that says on settles it first (V1).
        if launchReadUnconfirmedSince != nil {readPermissions()}
        if permission || launchReadUnconfirmedSince == nil,
           PermissionRelaunch.reason(inputMonitoringAtLaunch:permissionsAtLaunch?.inputMonitoring,accessibility:true,inputMonitoring:true) != nil,
           Self.canReopen() {return .permissions}
        if !UserDefaults.standard.bool(forKey:Self.setupCompletedKey) {return .summaries}
        saveWaitingChoices()
        return preferencesUnresolved ? .apps : nil
    }
    /// The last Start couldn't reach the keyboard and mouse although both permissions read as allowed (EventCapture
    /// couldn't install its event tap): macOS applies Input Monitoring to DayDream only after it reopens. Start and Resume
    /// then go to setup's Permissions page, whose one button is Quit & Reopen, instead of failing the same way again.
    /// Only where DayDream can reopen itself (never a development binary, which would be stuck).
    var inputNeedsReopen:Bool {
        guard development == nil,!recording,let session=coordinator?.session else {return false}
        return Self.inputNeedsReopen(state:session.state,reason:session.reason,canReopen:Self.canReopen())
    }
    /// The rule itself, for the checks: a pause EventCapture wrote because its event tap wouldn't install.
    static func inputNeedsReopen(state:String,reason:String,canReopen:@autoclosure ()->Bool)->Bool {
        state == "paused" && reason.hasPrefix("Input event tap") && canReopen()
    }
    /// At launch (`LaunchResume`): recording was on, or a timed pause was running, when DayDream or the Mac last quit.
    /// It starts again the way Start does, but only when nothing stands in the way: setup finished with the choices
    /// saved (`setupStepForStart`) and `resumeBlocker()` nil. Permissions are a preflight read (never a request): macOS
    /// keeps them across an update signed by the same team, and a copy it no longer trusts stays off and says why.
    /// Behind a locked screen or another user, the wake rules start it once that ends. Anything else that stands
    /// gets one notice (`RecordingNotice.reopenFailed`). Nothing opens.
    func resumeAtLaunch(_ plan:LaunchResume.Plan) {
        // A copy in the download window never gets here (it leaves the intent for the copy in Applications).
        guard development == nil,!recordingTrial,!functionalTrial,!recording,coordinator != nil,plan != .none,!launchLocation.blocksRecording else {return}
        // gold r2 review 1: the history opened (after a busy moment, or once another copy let go) while the Mac sleeps, the
        // screen is locked or another user is on screen. As for a launch behind the lock screen, the end of that runs the
        // plan (the wake rules, with their own tries: a timed pause is picked up until the same time); until then the
        // state is that suspension's pause, and nothing is said.
        if wake.suspended, setupStepForStart(permission:false) == nil {
            switch plan {
            case .record: recordingWanted=true;wake.adopt(.record)
            case .timedPause(let until): wake.adopt(.timedPause(until:until))
            case .none: return
            }
            pauseBehindSuspension()
            return
        }
        let ready=setupStepForStart(permission:false) == nil && resumeBlocker(permission:false) == nil
        if case .timedPause(let until)=plan, ready {
            // The person's pause, picked up until the same time: paused as it was, and it ends by itself.
            stopped=false
            schedulingPause=true
            coordinator?.pause("Paused by you")
            schedulingPause=false
            transitions.paused(fromRecording:false,at:activity.now())
            if resumeTimedPause(until:until) {
                refreshCaptureStatus()
                if wakeSystem.screenLocked() || !wakeSystem.onConsole() {catchUpSuspension()}
                return
            }
        }
        recordingWanted=true
        if wakeSystem.screenLocked() || !wakeSystem.onConsole() {
            // Opened at login behind the lock screen, or for another user: recording starts when that ends. Until then the
            // state is that pause ("Paused while your screen was locked."), not Off (gold r2 review 1).
            catchUpSuspension(); pauseBehindSuspension(); return
        }
        if ready {
            guard automaticStart(again:{ [weak self] in self?.resumeAtLaunch(.record) }) == .ran else {return}
            if recording {return}
        }
        automaticStartFailed { .reopenFailed(cause:$0,resumeTitle:$1) }
    }
    /// sat5's name for the launch resume after an update (the marker `UpdateResume` reads).
    func resumeAfterUpdate() { resumeAtLaunch(.record) }

    /// An automatic start (launch, a timed pause ending, a wake, a save retry, an import or backup ending): the ordinary
    /// Start, except that an import or backup still running holds it until that ends, with recording still wanted
    /// (`startWhenFree`), and a permission read off waits a moment and reads again, when `again` runs the start again
    /// (`holdForPermission`). A stop it causes (keyboard and mouse that couldn't start) is its caller's to report.
    private enum AutomaticStart {case ran,waitsForOperation,waitsForPermission,waitsForSave,waitsForHistory}
    private func automaticStart(again:@escaping ()->Void) -> AutomaticStart {
        if waitingOnOperation { waitForOperation(); return .waitsForOperation }
        // gold r2 review 1: the history is still opening by itself (a file busy at launch, or a copy in the download window
        // stepping aside). Nothing failed: recording stays wanted and starts once the history opens (`historyOpened` runs
        // the launch plan, kept meanwhile), so no caller counts this as a start that didn't happen or says anything, and
        // the state stays what it was (for a busy file, the calm "trying again" pause).
        if !recording, historyOpening, coordinator == nil {recordingWanted=true;refreshCaptureStatus();return .waitsForHistory}
        startWhenFree=false
        starting = .automatic
        automaticAgain=again
        defer {starting = .no;automaticAgain=nil}
        if !recording {startCapture()}
        // gold r2: a saved choice still saving by itself after a busy moment: recording starts once it lands
        // (`preferencesChanged`), so this start neither failed nor needs a notice.
        if !recording, resumeAfterSave, preferenceSave?.saving == true {recordingWanted=true;return .waitsForSave}
        return !recording && permissionHoldSince != nil ? .waitsForPermission : .ran
    }
    /// An automatic start read a permission off (gold G33, final review). macOS's privacy service can answer "not
    /// allowed" for a moment (right after wake, say), and that used to stop recording for good with a notice saying both
    /// permissions were off. Now recording stays wanted, nothing is written or said, and both are read again every half
    /// second: on again, the start runs again (`again`); a loss that holds for `permissionHoldQuiet` runs it once more with
    /// the off read as the answer, so a permission really turned off still never starts recording and still gets its one
    /// notice. The reads then go on (`armPermissionComeback`): both on again, recording starts by itself.
    private func holdForPermission(_ again:@escaping ()->Void) {
        if permissionHoldSince == nil {
            permissionHoldSince=wakeSystem.now()
            RecordingLog.note("A permission read off as recording started again; reading again.")
        }
        recordingWanted=true
        permissionHoldToken += 1
        let token=permissionHoldToken
        wakeSystem.after(Self.permissionRecheck) { [weak self] in MainActor.assumeIsolated { self?.permissionRechecked(token,again) } }
        refreshCaptureStatus()
    }
    private func permissionRechecked(_ token:Int,_ again:@escaping ()->Void) {
        guard token == permissionHoldToken, let since=permissionHoldSince else {return}
        let permitted=Self.permissionsGranted()
        // Asleep, locked or switched away: recording is still wanted, so the wake rules start it once that ends.
        if wake.suspended || !awake {endPermissionHold();return}
        if wakeSystem.screenLocked() || !wakeSystem.onConsole() {endPermissionHold();catchUpSuspension();return}
        if permitted {
            RecordingLog.note("Permissions read on again; starting recording.")
            endPermissionHold();again();refreshCaptureStatus();return
        }
        if wakeSystem.now().timeIntervalSince(since) < Self.permissionHoldQuiet {
            permissionHoldToken += 1
            let next=permissionHoldToken
            wakeSystem.after(Self.permissionRecheck) { [weak self] in MainActor.assumeIsolated { self?.permissionRechecked(next,again) } }
            refreshCaptureStatus()
            return
        }
        RecordingLog.note("A permission stayed off; recording didn't start.")
        endPermissionHold()
        permissionLossSettled=true
        again()
        permissionLossSettled=false
        // Its caller said why, once. The reads go on: both on again, recording starts by itself (gold r3).
        armPermissionComeback()
        refreshCaptureStatus()
    }
    /// No held start reads again (it started, the person acted, or a suspension began: the wake rules take it).
    private func endPermissionHold() {
        guard permissionHoldSince != nil else {return}
        permissionHoldSince=nil
        permissionHoldToken += 1
    }
    /// gold r3 (gate item 3): recording is off because a permission read off (an automatic start's loss held, or recording
    /// stopped on its own), and the one notice went out. Reading goes on (`permissionWatchTick`); both on again within
    /// `permissionComebackFor`, recording starts by itself. The person's own Pause, Stop or Start ends it.
    private func armPermissionComeback() {
        guard development == nil,!recording,case .permission=currentStopCause() else {return}
        if permissionComebackUntil == nil {RecordingLog.note("A permission is off; reading it again for a while.")}
        permissionComebackUntil=wakeSystem.now().addingTimeInterval(Self.permissionComebackFor)
        syncPermissionWatch()
    }
    private func endPermissionComeback() {
        comebackPauseUntil=nil
        guard permissionComebackUntil != nil else {return}
        permissionComebackUntil=nil
        syncPermissionWatch()
    }
    /// The permission reads run while recording is off and a comeback waits or the state says a permission is off.
    private func syncPermissionWatch() {
        let live=development == nil && !recording && (permissionComebackUntil != nil || recordingState.kind == .needsPermission)
        if live && permissionWatch == nil {
            let timer=Timer(timeInterval:Self.permissionComebackEvery,repeats:true) { [weak self] t in
                MainActor.assumeIsolated { if let self {self.permissionWatchTick()} else {t.invalidate()} }
            }
            timer.tolerance=0.3
            RunLoop.main.add(timer,forMode:.common)
            permissionWatch=timer
        } else if !live, let timer=permissionWatch {timer.invalidate();permissionWatch=nil}
    }
    private func permissionWatchTick() {
        guard development == nil,!recording else {endPermissionComeback();syncPermissionWatch();return}
        let before=permissionSnapshot
        readPermissions()
        // The state follows the reads: a new read, or both on while a line still says a permission is off (another read
        // updated the snapshot first), refreshes it, so "permissions are off" never outlives its cause.
        let stale=permissionSnapshot.allGranted == true && (resumeUnavailable == RecordingCopy.permissionBlocker || recordingState.kind == .needsPermission)
            && Self.permissionsGranted()
        if permissionSnapshot != before || stale {refreshCaptureStatus()}
        guard !recording else {return}
        if let until=permissionComebackUntil {
            if wakeSystem.now() >= until {
                RecordingLog.note("A permission stayed off; no longer reading it again.")
                endPermissionComeback()
            } else if awake,!wake.suspended,permissionHoldSince == nil,!wakeSystem.screenLocked(),wakeSystem.onConsole(),Self.permissionsGranted() {
                RecordingLog.note("Permissions read on again; starting recording.")
                permissionComebackUntil=nil
                comebackStart()
                return
            }
        }
        syncPermissionWatch()
    }
    /// Both permissions read on again after a permission stop: the start recording would have had (an automatic start).
    private func comebackStart() {
        guard development == nil,!recording else {return}
        // The person's timed pause, still running: it goes on until the same time (never record before it ends).
        if let until=comebackPauseUntil {
            comebackPauseUntil=nil
            if until > wakeSystem.now(), resumeTimedPause(until:until) {
                RecordingLog.note("Permissions read on again; the timed pause goes on until it ends.")
                clearStopNotice()
                refreshCaptureStatus()
                return
            }
        }
        if setupStepForStart(permission:false) == nil && resumeBlocker(permission:false) == nil {
            switch automaticStart(again:{ [weak self] in self?.comebackStart() }) {
            case .ran: if recording {return}
            // Waiting for an import, a save or the history: it starts by itself then, and the permission notice is stale.
            case .waitsForOperation,.waitsForSave,.waitsForHistory: clearStopNotice();refreshCaptureStatus();return
            // Off again for a moment: the hold reads again (and comes back here).
            case .waitsForPermission: return
            }
        }
        let cause=currentStopCause()
        if cause == .storage {storageFaulted();return}
        // Input Monitoring turned on after launch (or off and on) with no key since: macOS feeds it only once DayDream
        // reopens, so nothing starts; the permission notice is stale now, and Start goes to Quit & Reopen as it says.
        let permissionOff:Bool = { if case .permission=cause {return true}; return false }()
        if !permissionOff, setupStepForStart() == .permissions, !inputNeedsReopen {
            recordingWanted=false
            notResumed()
            clearStopNotice()
            refreshCaptureStatus()
            return
        }
        // Still a permission: keep reading (the notice already said it).
        if permissionOff {recordingWanted=false;armPermissionComeback();refreshCaptureStatus();return}
        // Something else stands in the way now: said once instead, as any automatic start that didn't record.
        recordingWanted=false
        notResumed()
        if let notice=RecordingNotice.stopped(cause,resumeTitle:resumeTitle) {showStopNotice(notice)} else {clearStopNotice()}
        refreshCaptureStatus()
    }
    /// An import or backup is running: recording starts once it ends (`operationsChanged`), and is still wanted meanwhile
    /// (at the next launch too). No notice: nothing went wrong.
    private func waitForOperation() {
        RecordingLog.note("Import or backup running; recording starts when it ends.")
        recordingWanted=true
        startWhenFree=true
        refreshCaptureStatus()
    }
    /// An import or backup changed (it started, ended, or a restore preview was made or closed): the state follows, and
    /// recording that waited for it starts now.
    private func operationsChanged() {
        guard development == nil else {return}
        refreshCaptureStatus()
        guard startWhenFree, !recording, !waitingOnOperation else {return}
        // Asleep, locked or switched away: the wake rules start it once that ends (recording is still wanted).
        if wake.suspended || !awake {return}
        if wakeSystem.screenLocked() || !wakeSystem.onConsole() {catchUpSuspension();return}
        RecordingLog.note("Import or backup finished; starting recording again.")
        startAfterOperation()
    }
    private func startAfterOperation() {
        let ready=setupStepForStart(permission:false) == nil && resumeBlocker(permission:false) == nil
        if ready {
            guard automaticStart(again:{ [weak self] in self?.startAfterOperation() }) == .ran else {return}
            if recording {return}
        }
        startWhenFree=false
        automaticStartFailed { .afterOperation(cause:$0,resumeTitle:$1) }
    }
    /// An automatic start didn't record: a failed save keeps trying by itself (StorageRetry, no notice); anything else is
    /// said once, and recording is no longer wanted.
    private func automaticStartFailed(_ notice:(RecordingStopCause,String)->RecordingNotice) {
        refreshCaptureStatus()
        let cause=currentStopCause()
        if cause == .storage {storageFaulted();return}
        recordingWanted=false
        notResumed()
        showStopNotice(notice(cause,resumeTitle))
        refreshCaptureStatus()
    }
    /// The launch intent, saved whenever what the person wants changes (`LaunchResume`). Not while quitting or installing
    /// an update: that pause is DayDream's, not theirs.
    private func saveLaunchIntent() {
        guard intentLive,!leaving,let intentDefaults else {return}
        // A sleep, lock or user switch keeps what it paused: recording, or the timed pause until its end.
        var until=pauseUntil
        if until == nil, case .timedPause(let end)=wake.plan {until=end}
        if let value=LaunchResume.value(wanted:recordingWanted || wake.plan == .record,pauseUntil:until) {intentDefaults.set(value,forKey:LaunchResume.key)}
        else {intentDefaults.removeObject(forKey:LaunchResume.key)}
    }
    /// Another DayDream holds the recorder lock on `home` (flock, released at once when free). A home that can't be
    /// opened yet is not held: the store reports it.
    static func recorderLockHeld(home:URL) -> Bool {
        let fd=open(home.appendingPathComponent("capture.lock").path,O_CREAT | O_RDWR,0o600)
        guard fd >= 0 else {return false}
        defer {close(fd)}
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else {return errno == EWOULDBLOCK}
        flock(fd,LOCK_UN)
        return false
    }

    // MARK: Open at login (SMAppService, LoginItem.swift)

    /// Settings › Advanced's one switch: DayDream opens at login. Read from macOS; on only once macOS allows it.
    @Published private(set) var openAtLogin=false
    /// The switch shows only for the app in Applications (not a preview, a trial, a development build, the download
    /// window or a second copy).
    var openAtLoginAvailable:Bool {
        development == nil && !recordingTrial && !functionalTrial && launchLocation == .applications && !anotherCopyOpen && store != nil
    }
    /// Setup (or this version's first launch after it) turned Open at login on once; the person's switch rules after.
    static let openAtLoginOfferedKey="DaydreamOpenAtLoginOfferedV1"
    /// Setup finished (its last page started recording, or what's-new's Done): DayDream opens at login from now on, and
    /// neither setup nor what's-new opens by itself again (`DaydreamSetupVersion`).
    func setupFinished() {
        let defaults=UserDefaults.standard
        defaults.set(true,forKey:Self.setupCompletedKey)
        defaults.set(DaydreamSetupVersion.current,forKey:DaydreamSetupVersion.key)
        defaults.removeObject(forKey:DaydreamSetupVersion.whatsNewShownKey)
        offerOpenAtLogin()
    }
    /// Which setup opens by itself at this launch. `counting`: a what's-new that opens is counted (it opens by itself at
    /// most `DaydreamSetupVersion.whatsNewShows` times until it is finished).
    func setupLaunch(counting:Bool)->DaydreamSetupVersion.Launch {
        let defaults=UserDefaults.standard
        let shown=defaults.integer(forKey:DaydreamSetupVersion.whatsNewShownKey)
        // claude/livefix-1004 (d): a history whose Typing question is still pending reopens the full setup.
        let launch=DaydreamSetupVersion.launch(completed:defaults.bool(forKey:Self.setupCompletedKey),
                                               version:defaults.integer(forKey:DaydreamSetupVersion.key),whatsNewShown:shown,
                                               typingPending:onboardingTypingChoicePending)
        if launch == .whatsNew && counting {defaults.set(shown+1,forKey:DaydreamSetupVersion.whatsNewShownKey)}
        return launch
    }
    /// Setup, however it opened, is the short what's-new while a finished setup predates this version.
    var setupIsWhatsNew:Bool {
        DaydreamSetupVersion.whatsNew(completed:UserDefaults.standard.bool(forKey:Self.setupCompletedKey),
                                      version:UserDefaults.standard.integer(forKey:DaydreamSetupVersion.key),
                                      typingPending:onboardingTypingChoicePending)
    }
    private func offerOpenAtLogin() {
        guard openAtLoginAvailable,let intentDefaults,!intentDefaults.bool(forKey:Self.openAtLoginOfferedKey) else {return}
        intentDefaults.set(true,forKey:Self.openAtLoginOfferedKey)
        // Never opens System Settings by itself: if macOS wants approval, the switch reads off until they allow it.
        setOpenAtLogin(true,asked:false)
    }
    func readOpenAtLogin() {
        let item=Self.loginItem
        guard openAtLoginAvailable,item.statusOffMain else {
            let on=openAtLoginAvailable && item.status() == .enabled
            if on != openAtLogin {openAtLogin=on}
            return
        }
        // perf2-1005: macOS's answer off the main thread; only the latest read lands.
        loginReads &+= 1
        let read=loginReads
        DispatchQueue.global(qos:.userInitiated).async {
            let on=item.status() == .enabled
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,read == self.loginReads,self.openAtLoginAvailable else {return}
                    if on != self.openAtLogin {self.openAtLogin=on}
                }
            }
        }
    }
    private var loginReads:UInt64=0
    /// The switch. Turning it on registers DayDream; if macOS wants the person's approval first, System Settings opens
    /// at Login Items, where they allow it.
    func setOpenAtLogin(_ on:Bool,asked:Bool=true) {
        guard openAtLoginAvailable else {return}
        do {
            if on {
                try Self.loginItem.register()
                if asked && Self.loginItem.status() == .requiresApproval {Self.loginItem.openSettings()}
            } else {try Self.loginItem.unregister()}
        } catch {RecordingLog.note("Open at login not changed: \(RecordingLog.name(error)).")}
        readOpenAtLogin()
    }
    /// Every Start and Resume control: into setup at the step that fixes what stands, otherwise Start.
    /// `openSetup` brings the setup window forward; it shows `setupRequest`.
    func requestStart(openSetup:()->Void) {
        // The Development Trial and the preview never record, and never open setup or a permission page.
        guard development == nil else {refreshCaptureStatus();return}
        // gold r2 (ADV-8): the history is still opening: tried now, so Start then goes through setup as it would have.
        if historyOpening, coordinator == nil {personStartWhileOpening(); if coordinator == nil {return}}
        guard let step=setupStepForStart() else {startCapture();return}
        // claude/permflash-015: Start goes to the Permissions page: what it read is shown as it is, at once, so the page
        // opens on what to allow (nothing waits to settle after the person's own Start).
        if step == .permissions {permissionReadAsIs=true;readPermissions()}
        setupRequest=step
        openSetup()
    }
    /// Allow Permissions (Needs Permission, outside setup): DayDream's drag cards, never System Settings on its own.
    /// Setup's Permissions page while setup isn't finished (it moves on by itself once both are allowed), otherwise
    /// Settings › Permissions (`openMain` brings the main window forward). A permission is never requested.
    /// perm-1004: `kind`, the permission a `Turn on …` press named: the page opens its System Settings pane once.
    func showPermissionCards(_ kind:PermissionKind?=nil,openSetup:()->Void,openMain:()->Void={}) {
        if development == nil, let kind {permissionPaneRequest=kind}
        if development == nil && !UserDefaults.standard.bool(forKey:Self.setupCompletedKey) {setupRequest = .permissions;openSetup();return}
        openMain();openSettings("Permissions")
    }

    /// The launch notice for what `settleLegacyPreferences` changed; nil when nothing needs saying. Sites that
    /// were only rewritten to the form the rule keeps skip at least as much as before, so they aren't named (and no
    /// site is ever removed).
    static func noticeText(_ settled:LegacyPreferenceSettlement)->String? {
        switch (settled.typingTurnedOff,settled.chromePagesTurnedOff) {
        case (true,true): return "Typing and Web pages in Chrome were turned off after the update. Turn them on again below if you want them."
        case (true,false): return "Typing was turned off after the update. Turn it on again below if you want it."
        case (false,true): return "Web pages in Chrome was turned off after the update. Turn it on again below if you want it."
        case (false,false): return nil
        }
    }
    static func readPreferenceNotice()->String? {
        let text=UserDefaults.standard.string(forKey:preferenceNoticeKey)
        return text?.isEmpty == false ? text : nil
    }
    /// An Apps page showing the notice closed: it has been seen.
    func preferenceNoticeSeen() {
        guard preferenceNotice != nil else {return}
        preferenceNotice=nil
        UserDefaults.standard.removeObject(forKey:Self.preferenceNoticeKey)
    }
    private func preferencesChanged() {
        guard let preferenceSave else {return}
        defer {syncExcludeHook()}
        if let error=preferenceSave.error {
            // The status line (Help › Report a Problem reads it). The pages show `preferenceProblem`.
            privacySaveStatus=error == .revisionConflict ? "Not saved. Your app choices changed in another window. Recording is stopped." : "Not saved. Recording is stopped."
        } else if preferenceSave.draft != nil {privacySaveStatus="Unsaved changes. Recording is stopped."}
        else {
            // A new policy re-filters what every day shows (excluded apps drop out of moments).
            if preferenceSave.policy.revision != savedPrivacy.revision {dayData.invalidateAll()}
            // gold r3-store: the recorder judges events by the saved choices it keeps; these are the new ones.
            if preferenceSave.policy.revision != savedPrivacy.revision {coordinator?.policyChanged();noteWriter.sourceChanged()}
            savedPrivacy=preferenceSave.policy
            blockedApps=savedPrivacy.blockedApps.joined(separator:", ")
            captureText=savedPrivacy.typingOn
            blockedDomains=savedPrivacy.blockedDomains.joined(separator:", ")
            browserPages=savedPrivacy.browserPagesOn
            emailSubjects=savedPrivacy.emailSubjects
            // Retention changes only outside the app (`mac-mem`); a reload takes the saved value too.
            retention=savedPrivacy.retentionDays
            if operationalIssue == Self.choicesUnsavedIssue {operationalIssue=nil}
            if preferenceSave.changedOnLastSave {
                // A save that shares more revoked every AI app's key (one that only hides more keeps them): re-read the
                // connections so Settings stops naming them as connected, and say so on Apps to remember (one line, with Reconnect).
                if preferenceSave.revokedOnLastSave > 0 {aiAppsDisconnected=true;connection.disconnectedByAppsChange=true}
                connection.refresh()
            }
            refresh()
            // Recording the person had on starts again with the saved choices, through the normal Start path
            // (it stays off when something there stands, such as a missing permission; trials keep their own Start).
            let resume=resumeAfterSave
            resumeAfterSave=false
            if resume && !recordingTrial && !functionalTrial && setupStepForStart() == nil {
                // gold/int (save-path CRITIC-GAP-autosave): a save that lands while the Mac sleeps, the screen is locked
                // or another user is on screen never starts recording behind it. Recording stays wanted and the wake
                // rules start it once that ends; a lock whose notice hasn't come yet is handled now.
                // gold r2: meanwhile the state is that pause ("Paused while your screen was locked."), not Off.
                if wake.suspended || !awake {recordingWanted=true;wake.wantsRecording();pauseBehindSuspension()}
                else if wakeSystem.screenLocked() || !wakeSystem.onConsole() {recordingWanted=true;catchUpSuspension();pauseBehindSuspension()}
                else {startCapture()}
            }
            privacySaveStatus="Saved preferences." + (recording ? "" : " Recording is stopped.") + (preferenceSave.revokedOnLastSave > 0 ? " Connections need separate approval again." : "")
        }
    }
    /// A pause a preference save leaves as it is (gold r2): the person's timed pause, which ends when it said, and the
    /// pause for sleep, a lock or a user switch that starts recording (or picks a timed pause up) when it ends. Nothing
    /// records during either, and the store saves while the session is paused. Stopping it instead wrote Off: a timed
    /// pause then ended as Off at the save, and a lock's pause at the unlock. A pause whose write failed for a moment (the
    /// session reads "error") is written again first, so the store sees it paused; if that fails too, the save tries again
    /// by itself (PreferenceAutosave) and the pause still stands.
    private func pauseOutlastsSave() -> Bool {
        guard !recording, capture == nil, let coordinator else {return false}
        let promised = pauseUntil != nil || (wake.suspended && wake.plan != .nothing)
        guard promised else {return false}
        if coordinator.session.state == "paused" {return true}
        guard coordinator.session.state == "error", pauseUntil != nil else {return false}
        schedulingPause=true
        coordinator.pause("Paused by you")
        schedulingPause=false
        return true
    }
    /// A save that stopped recording landed while the Mac sleeps, the screen is locked or another user is on screen, and
    /// recording starts when that ends (the wake rules' plan). Until then the state is the pause that suspension writes
    /// for recording that was on ("Paused while your screen was locked."), the one the unlock or wake ends, not Off.
    private func pauseBehindSuspension() {
        defer {refreshCaptureStatus()}
        guard let coordinator, !recording, wake.suspended, wake.plan != .nothing else {return}
        let suspension:WakeSuspension = wake.active.contains(.screenLock) ? .screenLock : wake.active.contains(.userSwitch) ? .userSwitch : .sleep
        stopped=false
        schedulingPause=true
        coordinator.pause(suspension.pauseReason)
        schedulingPause=false
        transitions.paused(fromRecording:false,at:activity.now())
    }
    func trialSavedAction(now:Date=Date()) throws -> CanonicalAction? {
        guard development == nil,let store,let coordinator else {nativeCommitReceipt=nil;return nil}
        // A loss that holds, not one false read: that would take save authority from the recorder that goes on recording.
        guard coordinator.recordingSettled else {coordinator.nativeReceipts.invalidate();nativeCommitReceipt=nil;return nil}
        guard let (receipt,action)=try coordinator.nativeReceipts.validated(store:store,now:now) else {nativeCommitReceipt=nil;return nil}
        nativeCommitReceipt=receipt
        return action
    }

    // MARK: Sleep, screen lock, user switching and stops on their own (SPEC 6.3 R1)

    /// Runs `body` with the reason for any stop it causes (the person's own, or a suspension).
    private func withStopIntent(_ cause:RecordingStopCause?,_ body:()->Void) {
        let previous=stopIntent
        stopIntent=cause
        body()
        stopIntent=previous
    }
    /// The person paused or stopped: their choice replaces any pending resume, and the stop notice goes. It is saved as
    /// the launch intent every time, also after a pause that was DayDream's own (an update pause whose quit AppKit
    /// refused, with the Settings sheet open): `leaving` ends first, and the save doesn't depend on a value changing.
    private func personActed() {
        leaving=false
        endPermissionHold()
        endPermissionComeback()
        wake.personActed()
        recordingWanted=false
        resumeAfterSave=false
        startWhenFree=false
        // sat5's update marker (left as Sparkle relaunches) no longer describes what they want: their choice wins.
        if intentLive {intentDefaults?.removeObject(forKey:UpdateResume.key)}
        // gold r2: while the history is still opening, their choice is the intent saved once it opens.
        if historyOpening {launchPlan = LaunchResume.Plan.none;personActedWhileOpening=true}
        saveLaunchIntent()
        endStorageRetry()
        clearStopNotice()
    }
    /// The menu's name for starting again in the current state.
    var resumeTitle:String { recordingState.kind == .paused ? "Resume Recording" : "Start Recording" }
    /// Why recording is not on now, from the session, the permission reads and the resume blocker.
    func currentStopCause()->RecordingStopCause {
        RecordingStopCause.infer(sessionState:coordinator?.session.state,sessionReason:coordinator?.session.reason,
                                 accessibility:lastPermissionRead.accessibility,inputMonitoring:lastPermissionRead.inputMonitoring,
                                 blocker:resumeUnavailable,suspended:wake.suspended || !awake || wakeSystem.screenLocked())
    }
    /// Every status refresh reports whether recording is on; a change is where a stop is noticed. The
    /// checks call it directly (they never start capture).
    func noteRecording(_ on:Bool) {
        let was=lastRecording
        lastRecording=on
        if on && !was {recordingBegan()}
        if was && !on {recordingEnded()}
    }
    /// Recording went from off to on (any path: Start, Resume, a timed pause or a wake resume).
    private func recordingBegan() {
        leaving=false
        endPermissionHold()
        endPermissionComeback()
        startWhenFree=false
        recordingWanted=true
        saveLaunchIntent()
        storageRecovered()
        clearStopNotice()
        if browserPagesSaved,chromeAccessEnvironment.version() != nil {checkChromeAccess()}
        // The first start lets macOS ask once whether DayDream may show its "stopped recording" notice.
        if !noticePrepared {noticePrepared=true;noticeCenter.prepare()}
    }
    /// Recording went from on to off. The person's own stops and suspensions say nothing; any other stop
    /// gets one notice once the recorder has settled.
    private func recordingEnded() {
        let cause=stopIntent ?? currentStopCause()
        RecordingLog.note("Recording stopped: \(cause.logName).")
        switch cause {
        case .suspension:
            // Stopped while the screen was locked or another user was on screen, before that notice was handled:
            // handle it now, so recording starts again when it ends.
            if stopIntent == nil { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.catchUpSuspension() } } }
            return
        case .person: recordingWanted=false
        case .storage:
            // A failed save: recording stays wanted and starts again by itself. No notice unless it keeps failing.
            storageFaulted()
        case .input where starting == .no:
            // The input tap was turned off while recording and couldn't be turned back on or made again (EventCapture
            // tries both first). Recording stays wanted, so the wake rules start it again after the next sleep or lock;
            // the notice says how to start it now. (A tap that can't be installed by a start is the start's own
            // failure: the rule below, gold/lifecycle G56/G36.)
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.announceStop(cause) } }
        default:
            // A start that stopped at once (keyboard and mouse couldn't start): an automatic start's caller retries or
            // says why, once; the person's own Start shows it in its state (Paused, "Keyboard and mouse aren't reaching
            // DayDream."; its Resume goes to Quit & Reopen where DayDream can reopen itself, ui-copy G11).
            if starting == .automatic {return}
            recordingWanted=false
            if starting == .person {return}
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.announceStop(cause) } }
            // gold r3 (gate item 3): a permission that read off while recording: both on again, it starts by itself.
            if case .permission=cause {armPermissionComeback()}
        }
    }
    private func announceStop(_ cause:RecordingStopCause) {
        guard !recording,let notice=RecordingNotice.stopped(cause,resumeTitle:resumeTitle) else {return}
        showStopNotice(notice)
    }
    private func showStopNotice(_ notice:RecordingNotice) {
        stopNotice=notice
        noticeCenter.post(notice)
        // gold r3 (gate item 3): a stop said because a permission read off (any automatic start's notice, or a stop on its
        // own): the reads go on, and both on again start recording by itself (`armPermissionComeback`).
        armPermissionComeback()
    }
    private func clearStopNotice() {
        guard stopNotice != nil else {return}
        stopNotice=nil
        noticeCenter.clear()
    }

    /// The Mac is going to sleep, the screen locked or the person switched users.
    func suspend(_ suspension:WakeSuspension) {
        guard development == nil else {return}
        // Only what is live pauses: recording, or a timed pause. A recorder that already stopped on its own is not
        // live, and pausing it would write "Resumes after unlock" over why it stopped.
        let active=recording || pauseUntil != nil
        RecordingLog.note("Suspended: \(suspension.rawValue)\(active ? ", pausing" : "").")
        // A start waiting to read the permissions again: recording is still wanted, so the wake rules start it after this.
        endPermissionHold()
        inputWatchInterrupted()
        let effects=wake.begin(suspension,wantsRecording:recordingWanted,timedPauseUntil:pauseUntil,recorderActive:active)
        awake=false
        runWake(effects)
        refreshCaptureStatus()
        if suspension != .sleep {startWakeReconcile()}
    }
    /// The Mac woke, the screen unlocked or the person switched back.
    func unsuspend(_ suspension:WakeSuspension) {
        guard development == nil else {return}
        RecordingLog.note("Suspension ended: \(suspension.rawValue).")
        let effects=wake.end(suspension)
        inputWatchInterrupted()
        if !wake.suspended {awake=true;stopWakeReconcile()}
        runWake(effects)
        refreshCaptureStatus()
    }
    private func runWake(_ effects:[WakeResumeMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .pause(let suspension):
                withStopIntent(.suspension) { pauseCapture(suspension.pauseReason,commitTyping:true) }
            case .settle(let delay,let token):
                wakeSystem.after(delay) { [weak self] in MainActor.assumeIsolated { self?.wakeSettled(token) } }
            case .start:
                if !recording {
                    switch automaticStart(again:{ [weak self] in self?.runWake([.start]) }) {
                    // An import or backup still running: recording starts once it ends, not through the wake rules.
                    case .waitsForOperation: wake.handedOff();refreshCaptureStatus();continue
                    // A permission read off for a moment: this start runs again once they read again (the plan stays).
                    case .waitsForPermission: refreshCaptureStatus();continue
                    // A saved choice still saving: recording starts once it lands, not through the wake rules.
                    case .waitsForSave: wake.handedOff();refreshCaptureStatus();continue
                    // The history still opening by itself: recording starts once it opens, not through the wake rules.
                    case .waitsForHistory: wake.handedOff();refreshCaptureStatus();continue
                    case .ran: break
                    }
                }
                refreshCaptureStatus()
                runWake(wake.started(succeeded:recording,cause:currentStopCause(),resumeTitle:resumeTitle))
            case .resumeTimedPause(let until):
                let resumed = !recording && resumeBlocker() == nil && resumeTimedPause(until:until)
                refreshCaptureStatus()
                // gold/int r3 review: a permission stop's comeback (armed by the notice that may follow) must keep this
                // pause, not start recording before it ends.
                if !resumed && !recording {comebackPauseUntil=until}
                runWake(wake.started(succeeded:resumed || recording,cause:currentStopCause(),resumeTitle:resumeTitle))
                if permissionComebackUntil == nil {comebackPauseUntil=nil}
            case .notify(let notice):
                recordingWanted=false
                notResumed()
                showStopNotice(notice)
            case .retryStorage:
                storageFaulted()
            }
        }
    }
    private func wakeSettled(_ token:Int) {
        let effects=wake.settled(token:token,screenLocked:wakeSystem.screenLocked(),onConsole:wakeSystem.onConsole(),now:wakeSystem.now())
        // Woke to a locked screen or to another user: wait for that too.
        if wake.suspended {awake=false;startWakeReconcile()}
        runWake(effects)
        refreshCaptureStatus()
    }
    /// Picks up a timed pause a suspension interrupted, until the same deadline.
    private func resumeTimedPause(until deadline:Date) -> Bool {
        guard let ticket=timedPause.resume(until:deadline,now:wakeSystem.now()) else {return false}
        pauseUntil=ticket.deadline
        armTimedPause(ticket)
        return true
    }
    /// While the screen is locked or another user is on screen, re-reads both every 15 seconds, in case the
    /// unlock or switch-back notice never arrives.
    private func startWakeReconcile() {
        guard wakeReconcileTimer == nil else {return}
        wakeReconcileTimer=Timer.scheduledTimer(withTimeInterval:15,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.wakeReconcile() }
        }
    }
    private func stopWakeReconcile() {wakeReconcileTimer?.invalidate();wakeReconcileTimer=nil}
    /// While something is live (recording, or a timed pause), reads the lock and console state every 2 s, in case a
    /// lock or user-switch notice is late or never comes: nothing records behind the lock screen. Common modes, so an
    /// open menu doesn't hold it back.
    private func syncLockWatch() {
        let live=development == nil && (recording || pauseUntil != nil)
        if live && lockWatch == nil {
            let timer=Timer(timeInterval:2,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.lockWatchTick() } }
            timer.tolerance=0.5
            RunLoop.main.add(timer,forMode:.common)
            lockWatch=timer
        } else if !live, let timer=lockWatch {timer.invalidate();lockWatch=nil}
    }
    private func lockWatchTick() {
        guard recording || pauseUntil != nil else {syncLockWatch();return}
        catchUpSuspension()
    }
    /// A screen lock or user switch the system reports, but whose notice this model hasn't handled: handle it now.
    private func catchUpSuspension() {
        guard development == nil else {return}
        if wakeSystem.screenLocked() && !wake.active.contains(.screenLock) {
            RecordingLog.note("Screen lock read before its notice.");suspend(.screenLock)
        } else if !wakeSystem.onConsole() && !wake.active.contains(.userSwitch) {
            RecordingLog.note("User switch read before its notice.");suspend(.userSwitch)
        }
    }

    // MARK: A save that failed: recording starts again by itself (StorageRetry)

    /// The session reason the state shows while a failed save is retried (RecordingCopy maps it to its line).
    var storageRetryReason:String {
        if coordinator?.storageFull == true {return CaptureFault.fullReason}
        return (historyOpenRetry ?? storageRetry).persistent(now:wakeSystem.now()) ? CaptureFault.persistentReason : CaptureFault.retryReason
    }
    /// A save failed and recording paused, or a start couldn't save. Recording stays wanted, and the ordinary Start runs
    /// again after the next wait. One notice goes out only once it has failed for two minutes. Reported by more than
    /// one path at once (the session, the coordinator, the wake rules), it counts once.
    func storageFaulted() {
        guard development == nil,coordinator != nil else {return}
        recordingWanted=true
        let now=wakeSystem.now()
        let wasActive=storageRetry.active,before=storageRetry.failures
        if storageRetry.failed(now:now) {
            RecordingLog.note("Saving has failed for \(Int(StorageRetry.persistentAfter)) s; notice posted.")
            showStopNotice(.storageRetrying)
        }
        // The same failure reported again by another path (the session, the heartbeat, the wake rules) keeps the try
        // already set.
        if wasActive && storageRetry.failures == before {return}
        storageRetryToken += 1
        let token=storageRetryToken,delay=storageRetry.nextDelay(now:now)
        RecordingLog.note("Save failed; trying again in \(Int(delay)) s.")
        wakeSystem.after(delay) { [weak self] in MainActor.assumeIsolated { self?.retryStorage(token) } }
    }
    /// A due try: the ordinary Start, only when nothing stands in its way. Asleep, locked or switched away, the wake
    /// rules start recording when that ends (a start that fails on a save comes back to `storageFaulted`).
    private func retryStorage(_ token:Int) {
        // gold r3-store: a try's reads and writes wait at most a moment on the main thread for another connection's
        // lock. A try that meets a history still held fails at once instead of after 1.5 s a statement (the replacement
        // read, then the start's writes), and the next try follows as before.
        _ = StoreWait.bounded(Coordinator.mainWaitBudget) { retryStorageBounded(token) }
    }
    private func retryStorageBounded(_ token:Int) {
        guard token == storageRetryToken else {return}
        let blocked=setupStepForStart() != nil || resumeBlocker() != nil
        // A lock or user switch whose notice hasn't been handled counts too: nothing starts behind the lock screen.
        let away=wakeSystem.screenLocked() || !wakeSystem.onConsole()
        switch storageRetry.step(recording:recording,wanted:recordingWanted,suspended:wake.suspended || !awake || away,blocked:blocked) {
        case .none:
            return
        case .leaveToWake:
            // Handled now, so the wake rules start recording when it ends.
            if away {catchUpSuspension()}
            return
        case .wait:
            // Something the person must fix (a permission, unsaved choices): look again in a minute.
            storageRetryToken += 1
            let next=storageRetryToken
            wakeSystem.after(StorageRetry.waitDelay) { [weak self] in MainActor.assumeIsolated { self?.retryStorage(next) } }
        case .start:
            RecordingLog.note("Trying to record again.")
            // An import or backup still running is not a failed save: recording starts once it ends (no try, no count).
            // A permission read off for a moment: this try runs again once they read again.
            guard automaticStart(again:{ [weak self] in self?.retryStorage(token) }) == .ran else {return}
            // Recording again (recordingBegan ended the retries).
            guard !recording else {return}
            // It didn't record. A start that failed on a save counted it and set the next try (the token moved): leave
            // that try. gold/int (lifecycle G56 review): a start that began and stopped at once (keyboard and mouse that
            // can't be reached) also moved the token (recordingBegan ended the retries), so the token alone no longer
            // says a later try covers it. Any other reason is now why recording is off, said once, as any stop on its
            // own is.
            let cause=currentStopCause()
            if cause == .storage {if token == storageRetryToken {storageFaulted()};return}
            recordingWanted=false
            notResumed()
            if let notice=RecordingNotice.stopped(cause,resumeTitle:resumeTitle) {showStopNotice(notice)}
            refreshCaptureStatus()
        }
    }
    /// Recording started again, or a heartbeat saved after a fault: no try is due, and the notice goes if it was out.
    /// A save that fails again within a minute continues the same run of failures (StorageRetry.stableAfter).
    func storageRecovered() {
        guard storageRetry.active else {return}
        RecordingLog.note("Saving works again.")
        if storageRetry.succeeded(now:wakeSystem.now()), stopNotice == .storageRetrying {clearStopNotice()}
        storageRetryToken += 1
    }
    /// Recording won't start again by itself: the wake rules or the save retries gave up (their one notice says why).
    /// A pause line that promised it would ("Paused while your screen was locked.", "Trying again.") now says it
    /// didn't, and the reason Start refused (an operational issue, say) is the orange line beside it.
    private func notResumed() {
        endStorageRetry()
        guard !recording, let coordinator, coordinator.session.state == "paused",
              RecordingStopCause.resumesByItself.contains(coordinator.session.reason) else {return}
        RecordingLog.note("Recording didn't start again by itself.")
        coordinator.pause(RecordingStopCause.notResumedReason)
    }
    /// The person paused, stopped or quit: no more tries.
    private func endStorageRetry() {
        guard storageRetry.firstFailure != nil else {return}
        storageRetry.personActed()
        storageRetryToken += 1
    }
    private func wakeReconcile() {
        guard wake.suspended else {stopWakeReconcile();return}
        let effects=wake.reconcile(screenLocked:wakeSystem.screenLocked(),onConsole:wakeSystem.onConsole())
        guard !effects.isEmpty || !wake.suspended else {return}
        if !wake.suspended {awake=true;inputWatchInterrupted();stopWakeReconcile()}
        runWake(effects)
        refreshCaptureStatus()
    }

    // MARK: Permission buttons and the download window (SPEC 6.3 R2, R3)

    /// The permission page's actions (`\.daydreamPermissionRequests`); nil in the Development Trial, where
    /// nothing records.
    var permissionRequests:PermissionRequestActions? {
        guard development == nil else {return nil}
        var actions=PermissionRequests.actions(.live,location:launchLocation,inputMonitoringAtLaunch:permissionsAtLaunch?.inputMonitoring)
        actions.paneRequest=permissionPaneRequest?.rawValue
        actions.paneRequestHandled={ [weak self] in self?.permissionPaneRequest=nil }
        actions.autoRelaunch=permissionAutoRelaunch
        return actions
    }
    /// Opens the Applications folder; nil unless DayDream runs from the download window.
    var openApplicationsAction:(()->Void)? {
        launchLocation.blocksRecording ? { _ = NSWorkspace.shared.open(LaunchLocation.applicationsFolder) } : nil
    }

    // MARK: Redesign plumbing (plan §5 F2). No views here: surfaces read it through
    // ActivityBrowser and CapturePresentation.

    /// Everything `RecordingState.derive` reads, taken from this model's own fields.
    var recordingInputs:RecordingStateInputs {
        let session=coordinator?.session
        // CaptureSession keeps a denied start until the next explicit start. Once both reads say granted it
        // describes nothing: nothing records and Start succeeds, so it reads as Off, not a missing permission.
        let staleDenial = !recording && session?.state == "permission_denied" && permissionSnapshot.allGranted == true
        // While a failed save is being retried: Paused, with one calm line that says so, whatever the session could
        // write. A real blocker (a permission, say) still wins, and Resume tries at once.
        // Waiting for an import or backup to end: Paused, with one line that says so (it starts by itself then).
        let waiting = !recording && startWhenFree && resumeUnavailable == Self.operationBlocker
        // gold r2 (ADV-8): a history opening again after a busy moment, with recording wanted, is the same calm pause. Not
        // a copy in the download window stepping aside (review round 1): nothing failed to save there.
        let retrying = !waiting && !recording && recordingWanted && (storageRetry.active || historyOpenRetry != nil)
        let held=retrying || waiting
        var inputs=RecordingStateInputs(recording:recording,stopped:held ? false:stopped || staleDenial,development:development != nil,
                                    pauseUntil:pauseUntil,pausedAt:pausedAt,recordingSince:recordingSince,stoppedAt:stoppedAt,
                                    resumeUnavailable:presentedBlocker,sessionState:held ? "paused":staleDenial ? nil:session?.state,
                                    sessionReason:waiting ? Self.waitingReason:retrying ? storageRetryReason:staleDenial ? nil:session?.reason,
                                    accessibilityGranted:permissionSnapshot.accessibility,inputMonitoringGranted:permissionSnapshot.inputMonitoring,
                                    operationalIssue:shownIssue ?? (resumeUnavailable == nil ? historySetAsideIssue : nil))
        inputs.preview=development?.preview == true
        return inputs
    }
    /// The orange line: an operational problem the state doesn't say (a Start refused over unsaved choices, a busy
    /// history job, the summary writer). A stop notice is never one: the state's own line already says why recording
    /// isn't on (Paused and its reason, Needs Permission, Off and its blocker), and the notification was the one-time
    /// alert. One state, one explanation.
    var shownIssue:String? { operationalIssue }
    /// After a launch repaired a damaged history and some of it couldn't be read (G45): the menu's orange line, leading
    /// to Backup and restore, until that page has been seen or a backup restored. An operational problem or a blocker is
    /// shown first.
    var historySetAsideIssue:String? { backups.historySetAside ? MenuBarMenu.historySetAsideLine : nil }
    var recordingState:RecordingState {.derive(recordingInputs)}

    /// Opens the settings sheet at a legacy section string ("General", "Recording", …).
    func openSettings(_ section:String="General") {settingsSection=section;settingsPresented=true}

    /// "Exclude <App> from Recording…" and "Don't Record <site>…" are offered only while the save can run
    /// now; a nil hook hides them.
    var canExcludeApps:Bool {development == nil && !recordingTrial && preferencesAvailable && !preferencesUnresolved}
    private func syncExcludeHook() {
        let can=canExcludeApps
        guard can != (activity.excludeApp != nil) || can != (activity.excludeSite != nil) else {return}
        activity.objectWillChange.send()
        activity.excludeApp = can ? { @MainActor [weak self] bundle in
            guard let self else {throw MemError.missing}
            try await self.excludeAppSaved(bundle)
        } : nil
        activity.excludeSite = can ? { @MainActor [weak self] site in
            guard let self else {throw MemError.missing}
            try await self.excludeSiteSaved(site)
        } : nil
    }
    /// Adds one app to Excluded by you through the Settings save path. Saving stops recording first
    /// (PreferenceAutosave stops the recorder) and is flushed now, like savePolicy(). Recording the person had
    /// on starts again afterwards (`resumeAfterSave`). A save that did not land throws the problem line the pages
    /// show; a save being tried again quietly after a busy moment is saving, not a failure (`excludeAppSaved` waits).
    func excludeApp(_ bundle:String) throws {
        guard development == nil,preferencesAvailable else {throw MemError.invalid("Preferences can't be saved here. Nothing was excluded.")}
        try choicesMaySave(" Nothing was excluded.")
        let bundle=bundle.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !PrivacySettings.sensitiveApps.contains(bundle) else {throw MemError.invalid("This app is always private.")}
        // The store's own rule for app identifiers; checked first so a bad value never becomes a stuck draft.
        guard bundle.utf8.count <= 256,bundle.range(of:"^[A-Za-z0-9][A-Za-z0-9.-]*$",options:.regularExpression) != nil else {
            throw MemError.invalid("This app can't be excluded. Nothing was saved.")
        }
        guard !savedPrivacy.blockedApps.contains(bundle) else {return}
        blockedApps=(savedPrivacy.blockedApps+[bundle]).joined(separator:", ")
        queuePreferences()
        preferenceSave?.flush()
        if preferenceSave?.failed == true {throw MemError.invalid((preferenceProblem ?? .notSaved).text)}
    }
    /// Exclude App from a moment or Recall (`activity.excludeApp`): says what happened only once it is known. A change
    /// still saving by itself (an earlier one, or this one after a busy moment) is waited for, so the caller never
    /// shows a line the save then contradicts: it returns once the app is excluded, or throws the problem line.
    func excludeAppSaved(_ bundle:String) async throws {
        await preferenceSave?.settled()
        try excludeApp(bundle)
        await preferenceSave?.settled()
        let bundle=bundle.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !savedPrivacy.blockedApps.contains(bundle) else {return}
        throw MemError.invalid((preferenceProblem ?? .notSaved).text)
    }
    /// "Don't Record <site>…" from a moment: `excludeSite`, said once known, the same way as `excludeAppSaved`.
    func excludeSiteSaved(_ host:String) async throws {
        await preferenceSave?.settled()
        try excludeSite(host)
        await preferenceSave?.settled()
        guard let entry=BrowserSites.siteEntry(host),!savedPrivacy.blockedDomains.contains(entry),!BrowserSites.blockedByDefault(host:entry) else {return}
        throw MemError.invalid((preferenceProblem ?? .notSaved).text)
    }
    /// A change still waiting for its short save delay is saved first; anything that still stands is the one
    /// sentence the pages show, plus `outcome`.
    private func choicesMaySave(_ outcome:String) throws {
        saveWaitingChoices()
        guard !preferencesUnresolved else {throw MemError.invalid((preferenceProblem ?? .notSaved).text+outcome)}
    }

    // MARK: Chrome page history (Settings ▸ Apps to remember ▸ Web pages in Chrome)

    /// The switch: saved through the autosave path like the typing switch (debounced; recording stops, and turning it
    /// on disconnects AI apps once the change is saved).
    func setBrowserPages(_ on:Bool) {
        // A release without Chrome page history (ReleaseFeatures) can't turn it on.
        guard development == nil,!on || ReleaseFeatures.chromePageHistory else {return}
        browserPages=on;queuePreferences()
    }
    /// Adds a site to "Sites not recorded" and saves now. Throws the text to show under the field.
    func addSite(_ text:String) throws {
        try sitesMaySave()
        guard let entry=BrowserSites.siteEntry(text) else {throw ChromeSiteMessage.invalid}
        guard !savedPrivacy.blockedDomains.contains(entry) else {throw ChromeSiteMessage.alreadyListed}
        guard !BrowserSites.blockedByDefault(host:entry) else {throw ChromeSiteMessage.alreadySkipped}
        guard savedPrivacy.blockedDomains.count < 256 else {throw ChromeSiteMessage.full}
        try saveSites(savedPrivacy.blockedDomains+[entry])
    }
    /// Records the site again: removes it from "Sites not recorded" and saves now.
    func removeSite(_ host:String) throws {
        try sitesMaySave()
        guard savedPrivacy.blockedDomains.contains(host) else {return}
        try saveSites(savedPrivacy.blockedDomains.filter {$0 != host})
    }
    /// "Don't Record <site>…": adds the site (and its subdomains) through the same save path as Exclude App.
    /// Its saved pages are hidden at once (every read applies the list). A site already skipped is left alone.
    func excludeSite(_ host:String) throws {
        try sitesMaySave()
        guard let entry=BrowserSites.siteEntry(host) else {throw MemError.invalid("This site can't be skipped. Nothing was saved.")}
        guard !savedPrivacy.blockedDomains.contains(entry),!BrowserSites.blockedByDefault(host:entry) else {return}
        guard savedPrivacy.blockedDomains.count < 256 else {throw ChromeSiteMessage.full}
        try saveSites(savedPrivacy.blockedDomains+[entry])
    }
    /// Excluding apps' guards: saving must be possible now and nothing else may be pending.
    private func sitesMaySave() throws {
        guard development == nil,preferencesAvailable else {throw MemError.invalid("Preferences can't be saved here. Nothing was changed.")}
        try choicesMaySave(" Nothing was changed.")
    }
    /// Saves now. A save being tried again quietly after a busy moment is saving, not a failure: the Settings card
    /// waits disabled and lists the site once it lands; the page's problem line shows if it can't.
    private func saveSites(_ sites:[String]) throws {
        blockedDomains=Array(Set(sites)).sorted().joined(separator:", ")
        queuePreferences()
        preferenceSave?.flush()
        if preferenceSave?.failed == true {throw MemError.invalid((preferenceProblem ?? .notSaved).text)}
    }
    /// Reads Chrome access off the main thread on appearance, activation and Try Again. An unanswered
    /// upgrade may request once for this app version; ordinary capture reads never prompt.
    func checkChromeAccess() {
        guard development == nil,!askingChromeAccess else {return}
        let env=chromeAccessEnvironment
        chromeAccessGeneration += 1
        let generation=chromeAccessGeneration
        guard let pid=env.running() else {
            chromeAccess = .chromeNotRunning
            if browserPagesSaved,!chromeExcluded,env.version() != nil,!chromeUpgradeCheckWaiting {
                chromeUpgradeCheckWaiting=true
                env.onNextChromeActivation { [weak self] in MainActor.assumeIsolated {
                    guard let self else {return}
                    self.chromeUpgradeCheckWaiting=false
                    if self.browserPagesSaved,!self.chromeExcluded {self.checkChromeAccess()}
                } }
            }
            return
        }
        let copies=env.copies()
        chromeAccess = .checking
        env.background {
            var state:ChromeAccessState=env.verify(pid) ? .from(status:env.status(pid)) : .unverified
            // Two of the person's own Chromes: the one in front was checked, and nothing is read until one quits.
            if copies > 1, state == .allowed {state = .twoCopies}
            env.main { [weak self] in MainActor.assumeIsolated { self?.chromeAccessRead(state,generation:generation) } }
        }
    }
    /// "Allow…": the only path to the macOS prompt. On the serial Chrome queue: Chrome is running, then
    /// Google's signature, then macOS asks. The state is updated on the main thread with macOS's answer.
    func allowChromeAccess(onlyIfUndetermined:Bool=false) {
        guard development == nil,!askingChromeAccess else {return}
        let env=chromeAccessEnvironment
        chromeAccessGeneration += 1
        let generation=chromeAccessGeneration
        guard let pid=env.running() else {chromeAccess = .chromeNotRunning;return}
        askingChromeAccess=true
        chromeAccess = .checking
        env.background {
            var state:ChromeAccessState
            if !env.verify(pid) {state = .unverified}
            else {
                let current=onlyIfUndetermined ? env.status(pid) : OSStatus(-1744)
                if current != -1744 {state = .from(status:current)}
                else {
                    // Live test (build 7): macOS may answer "turned off" at once with no question (it asks once per app;
                    // a reset or a dismissed question leaves nothing to ask). Say where to allow it instead of nothing.
                    let started=env.uptime()
                    if let version=env.version() {env.markPromptVersion(version)}
                    let status=env.ask?(pid) ?? ChromeEventSender.askForChromeAccess(pid:pid)
                    RecordingLog.note("Chrome access request OSStatus=\(status).")
                    state = .from(status:status)
                    if status == -1744 || (status == -1743 && env.uptime()-started < Self.chromeAskQuick) {state = .askFailed}
                }
            }
            env.main { [weak self] in MainActor.assumeIsolated {
                guard let self else {return}
                self.askingChromeAccess=false
                self.chromeAccessRead(state,generation:generation)
                // Owner, 10/2: access granted from the press turns "Save web pages in Google Chrome" on if it was off.
                if generation == self.chromeAccessGeneration,
                   DaydreamChromeGrant.turnsOnPages(allowed:self.chromeAccess == .allowed,pagesOn:self.browserPages,release:ReleaseFeatures.chromePageHistory) {
                    RecordingLog.note("Chrome access allowed: saving web pages in Chrome turned on.")
                    self.setBrowserPages(true)
                }
            } }
        }
    }
    /// Setup's Chrome row (`DaydreamOnboardingChromeRow`): its one button. The same `allowChromeAccess` as Settings'
    /// Allow…; with Google Chrome closed, Chrome opens first (in the background, from the person's click, as the row's
    /// line says before the press) and macOS asks once it runs. chromeask-1005 (owner 10/5): this press is the only
    /// place setup lets macOS ask; nothing asks after setup or when Chrome next comes forward. Nothing here reads a page.
    func askChromeAccessInSetup() {
        // The row shows before Apps saves Web pages in Chrome: the press asks whatever the switch (a question, nothing read).
        guard development == nil,ReleaseFeatures.chromePageHistory,!chromeExcluded,!askingChromeAccess,!chromeOpeningForSetup else {return}
        chromeSetupAsked=true
        let env=chromeAccessEnvironment
        if env.running() != nil {allowChromeAccess();return}
        guard env.installed() else {chromeAccess = .chromeNotRunning;return}
        chromeAccessGeneration += 1
        let generation=chromeAccessGeneration
        chromeAccess = .checking
        chromeOpeningForSetup=true
        env.openChrome { [weak self] opened in MainActor.assumeIsolated {
            guard let self else {return}
            self.chromeOpeningForSetup=false
            // Owner, 10/2: the card's Allow asks with recording Chrome off too; access granted then turns it on.
            guard opened,self.development == nil,!self.chromeExcluded else {
                if generation == self.chromeAccessGeneration {self.chromeAccess = .chromeNotRunning}
                return
            }
            self.allowChromeAccess()
        } }
    }
    /// Setup's Chrome step: whether Google Chrome is on this Mac (no prompt, nothing opened).
    var chromeInstalled:Bool {chromeAccessEnvironment.installed()}
    /// macOS answered the Chrome question (or it was allowed before): setup's Chrome step moves on.
    static func chromeAnswered(_ state:ChromeAccessState)->Bool {state == .allowed || state == .denied || state == .askFailed}
    private func chromeAccessRead(_ state:ChromeAccessState,generation:Int) {
        guard generation == chromeAccessGeneration else {return}
        chromeAccess=afterAsk(state)
        // Owner, 10/2: a read never asks. Someone who finished setup before the Chrome row, whose verified Chrome reads
        // "not asked" (-1744), gets setup's Permissions card once (`DaydreamChromeCard`); its Allow is the question.
        let env=chromeAccessEnvironment
        if let version=env.version(),!version.isEmpty,
           DaydreamChromeCard.opens(setupCompleted:env.setupFinished(),alreadyShown:env.cardShown(),notAsked:chromeAccess == .notAsked,
                                    release:ReleaseFeatures.chromePageHistory,pagesOn:browserPagesSaved,chromeExcluded:chromeExcluded,
                                    installed:env.installed()) {
            env.markCardShown()
            chromeCardRequested=true
            openSetupWindow?()
        }
    }
    /// After an Allow… macOS refused without asking, "not asked" and "turned off" still mean: allow it in System
    /// Settings. Allowed clears it.
    private func afterAsk(_ state:ChromeAccessState)->ChromeAccessState {
        if state == .askFailed {chromeAskFailed=true}
        if state == .allowed {chromeAskFailed=false}
        return chromeAskFailed && (state == .notAsked || state == .denied) ? .askFailed : state
    }
    /// Page history's own reads (review G30): what a read just learned about Chrome access is newer than any check.
    func chromeAccessFromPages(_ access:ChromePageRecorder.Access) {
        guard development == nil,!askingChromeAccess else {return}
        let state:ChromeAccessState
        switch access {case .unverified: state = .unverified; case .status(let status): state = afterAsk(.from(status:status)); case .twoCopies: state = .twoCopies}
        remindChromeOff(state)
        guard state != chromeAccess else {return}
        chromeAccessGeneration += 1
        chromeAccess=state
    }
    /// Privacy & Security › Automation. Opening it changes nothing.
    func openChromeAutomationSettings() {
        chromeAccessEnvironment.openPane()
        watchChromeRecovery()
    }
    /// chromeask-1005: "Chrome pages aren't being saved." (menu bar, Settings, the status popover, the reminder).
    /// Refused: Ask again (`askChromeAgain`). Not asked yet: Fix opens the setup card with the Chrome row
    /// (`DaydreamChromeCard`), whose Allow is where macOS asks.
    func fixChromeAccess(openSetup:(()->Void)?=nil) {
        chromeReminder.dismiss()
        if ChromeAccessMemory.fix(lineAccess:chromeLineAccess) == .askAgain {askChromeAgain();return}
        guard development == nil else {return}
        chromeCardRequested=true
        if let openSetup {openSetup()} else {openSetupWindow?()}
    }
    /// The access the Chrome line reads: the last answer while Chrome is closed (or not read yet), else the newest read.
    var chromeLineAccess:ChromeAccessState {
        switch chromeAccessShown {
        case .chromeNotRunning,.unknown,.checking: return chromeLastAnswer ?? chromeAccessShown
        default: return chromeAccessShown
        }
    }
    /// Ask again (owner 10/5; setup's and Settings' Chrome row, the Chrome line, the reminder): macOS never asks again
    /// after Don't Allow, so DayDream clears its own Automation answer (`ChromeAutomationReset`: AppleEvents, its own
    /// bundle id, nothing else) and asks again at once, from this press (opening a closed Chrome in the background, as
    /// setup's Allow does). Where the reset can't run, or macOS answers with no question on screen, the guide beside
    /// System Settings shows the switch instead.
    func askChromeAgain() {
        guard development == nil,ReleaseFeatures.chromePageHistory,!chromeExcluded,!askingChromeAccess,!chromeOpeningForSetup,
              !chromeResetting else {return}
        chromeReminder.dismiss()
        let env=chromeAccessEnvironment
        guard env.installed() else {return}
        guard ChromeAccessMemory.refused(chromeLineAccess) || ChromeAccessMemory.refused(chromeAccess) else {
            askChromeAccessInSetup();return
        }
        guard !chromeResetFailed,let arguments=ChromeAutomationReset.arguments(ownBundleID:env.ownBundleID()) else {
            showChromeGuide();return
        }
        chromeResetting=true
        objectWillChange.send()
        env.background {
            let status=env.resetAutomation(arguments)
            env.main { [weak self] in MainActor.assumeIsolated {
                guard let self else {return}
                self.chromeResetting=false
                RecordingLog.note("Ask again: Chrome access answer cleared, exit \(status).")
                guard status == 0,self.development == nil,!self.chromeExcluded else {
                    self.chromeResetFailed=true
                    self.objectWillChange.send()
                    self.showChromeGuide()
                    return
                }
                // macOS has no answer now: the question comes back on this ask.
                self.chromeAskFailed=false
                self.chromeLastAnswer = .notAsked;ChromeAccessMemory.save(.notAsked)
                self.chromeAskingAgain=true
                self.askChromeAccessInSetup()
                if !self.askingChromeAccess && !self.chromeOpeningForSetup {self.chromeAskingAgain=false}
            } }
        }
    }
    /// Ask again's question answered: an answer with no question on screen (macOS asks no more: a managed Mac, an older
    /// macOS) opens the guide. Allowed, refused in the question, or Chrome didn't open: nothing more.
    private func chromeAskedAgain(_ state:ChromeAccessState) {
        chromeAskingAgain=false
        if state == .askFailed {showChromeGuide()}
    }
    /// The fallback: System Settings at Privacy & Security › Automation with the guide beside it, and the recovery watch
    /// (turning the switch on is picked up with no restart; the guide then shows a check and closes).
    private func showChromeGuide() {
        guard development == nil else {return}
        RecordingLog.note("Ask again: macOS can't ask, the guide shows the switch.")
        openChromeAutomationSettings()
        chromeGuide.show()
    }
    /// A new answer from macOS (a read or the question). Refused to allowed: the recorder reads Chrome again now
    /// (no restart), and the reminder, the guide and the recovery watch end.
    private func chromeAccessAnswered(_ answer:ChromeAccessState,was:ChromeAccessState) {
        let before=chromeLastAnswer
        if before != answer {chromeLastAnswer=answer;ChromeAccessMemory.save(answer)}
        guard answer == .allowed else {return}
        chromeRecoveryWatch?.invalidate();chromeRecoveryWatch=nil;chromeRecoveryUntil=nil
        chromeReminder.dismiss()
        chromeGuide.done()
        chromeResetFailed=false
        if before != nil && before != .allowed {
            RecordingLog.note("Chrome access turned on: Chrome pages are read again.")
            capture?.pages.reset()
            capture?.pages.trigger(.rerun)
        }
    }
    /// Reads Chrome's status every 2 s (no question; Chrome must be running for macOS to answer) for up to 10 minutes,
    /// or until it is allowed. Coming back to DayDream reads it too (the activation read).
    private func watchChromeRecovery() {
        guard development == nil,chromeAccess != .allowed else {return}
        chromeRecoveryUntil=Date().addingTimeInterval(ChromeAccessMemory.recoveryWindow)
        guard chromeRecoveryWatch == nil else {return}
        chromeRecoveryWatch=Timer.scheduledTimer(withTimeInterval:ChromeAccessMemory.recoveryPeriod,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {return}
                if self.chromeAccess == .allowed || (self.chromeRecoveryUntil.map {Date() > $0} ?? true) {
                    self.chromeRecoveryWatch?.invalidate();self.chromeRecoveryWatch=nil;self.chromeRecoveryUntil=nil;return
                }
                self.rereadChromeAccessQuietly()
            }
        }
    }
    /// The recovery watch's read: Chrome's status only (no question, no spinner, no signature check), and a full
    /// `checkChromeAccess` only once it changed, so a row showing "Chrome is off" never flickers while it waits.
    private func rereadChromeAccessQuietly() {
        let env=chromeAccessEnvironment
        guard development == nil,!askingChromeAccess,let pid=env.running() else {return}
        let shown=chromeLineAccess
        env.background {
            let state=ChromeAccessState.from(status:env.status(pid))
            env.main { [weak self] in MainActor.assumeIsolated {
                guard let self,!self.askingChromeAccess,state != .unknown,state != .chromeNotRunning else {return}
                let mapped:ChromeAccessState=self.chromeAskFailed && (state == .notAsked || state == .denied) ? .askFailed : state
                if mapped != shown {self.checkChromeAccess()}
            } }
        }
    }
    /// The access setup's and Settings' Chrome rows draw: macOS's last refusal or permission while Chrome is closed, a
    /// read hasn't come back yet or one is running, so a refused row never turns back into "macOS will ask once" (macOS
    /// won't) and never flickers while it is read again. A question in flight (`askingChromeAccess`) shows its spinner.
    var chromeRowAccess:ChromeAccessState {
        // Ask again clearing DayDream's answer: the question is on its way (the spinner, the drawing of the question).
        if chromeResetting {return .checking}
        switch chromeAccess {
        case .chromeNotRunning,.unknown,.checking:
            if !askingChromeAccess,!chromeOpeningForSetup,let answer=chromeLastAnswer,answer != .notAsked {return answer}
            return chromeAccess
        default: return chromeAccess
        }
    }
    /// Google Chrome is running now (no prompt; the setup row says Allow opens it in the background otherwise).
    var chromeRunning:Bool {chromeAccessEnvironment.running() != nil}
    /// chromeask-1005: page history read Chrome in front while access is refused, after setup: one calm in-app line,
    /// once ever, with Fix. Not while Chrome is excluded or Web pages in Chrome is off (nothing reads then).
    private func remindChromeOff(_ state:ChromeAccessState) {
        guard development == nil,state == .denied || state == .askFailed,browserPagesSaved,!chromeExcluded,
              chromeAccessEnvironment.setupFinished(),!ChromeAccessMemory.reminded() else {return}
        ChromeAccessMemory.markReminded()
        RecordingLog.note("Chrome access is off: one reminder shown.")
        chromeReminder.show { [weak self] in self?.fixChromeAccess() }
    }
    /// Settings ▸ Diagnostics: "Web pages in Chrome". Never a page, a site or a window's mode.
    var chromePagesDiagnostics:String {ChromeAccessState.diagnostics(on:browserPagesSaved,access:chromeAccess,chromeExcluded:chromeExcluded)}

    /// Midnight under a retention limit (F0b contract request 4, retention). Reads apply the retention cutoff as it
    /// is now, but a cached past day is final until invalidated, so the oldest kept day would keep showing actions
    /// that have since expired. The app itself never purges on disk (the CLI writer does); retention changes made
    /// in Settings already invalidate through the policy revision.
    func calendarDayChanged() { calendarDayChanged(retentionDays:savedPrivacy.retentionDays) }
    func calendarDayChanged(retentionDays:Int?) {
        guard retentionDays != nil else {return}
        dayData.invalidateAll()
    }

    /// The system time zone changed. The display calendar moves with it, so day keys, row times and day reads all
    /// use the new zone; the day cache then drops every day it holds (its own observer, a turn later).
    func systemTimeZoneChanged() {
        let zone=Self.readSystemTimeZone()
        guard activity.calendar.timeZone != zone else {return}
        activity.objectWillChange.send()
        activity.calendar.timeZone=zone
    }

    /// The system time zone, re-read (the cached value is dropped first). The checks substitute a zone here:
    /// `NSTimeZone.default` does not reach `TimeZone.current`, and the real system zone can't be changed in a check.
    static var readSystemTimeZone:()->TimeZone = { NSTimeZone.resetSystemTimeZone(); return TimeZone.current }

    /// Installed apps' names for bundles the loaded actions leave unnamed (F0b contract request 2): read off the main
    /// thread (bundle metadata only, `LocalApp.catalog`) at launch and when DayDream becomes active, at most every
    /// 10 minutes. Not in the Development Trial, whose synthetic days name their own apps.
    func refreshBundleNames() {
        guard development == nil,!bundleCatalogReading else {return}
        if let last=bundleCatalogReadAt,Date().timeIntervalSince(last) < 600 {return}
        bundleCatalogReading=true
        Task.detached(priority:.utility) { [weak self] in
            let names=Dictionary(LocalApp.catalog().map {($0.id,$0.name)},uniquingKeysWith:{first,_ in first})
            await self?.bundleNamesRead(names)
        }
    }
    private func bundleNamesRead(_ names:[String:String]) {
        bundleCatalogReading=false;bundleCatalogReadAt=Date()
        let cache=activity.dayCache
        guard cache.bundleNames != names else {return}
        cache.bundleNames=names
        // Digests and today's snapshot already built used the old names. The cache itself, not `dayData`:
        // stored memory did not change, and the names land at an arbitrary moment after launch.
        cache.invalidateAll();activity.today.refresh(force:false)
    }

    /// Every recording control's closures, for the toolbar capsule, its popover and the Focus List (plan §5 I1).
    var captureActions:CaptureActions {
        // Start goes through setup when something there must be done first (MemoryWindow also opens the window).
        var actions=CaptureActions(pause:pauseFor,resume:{ [weak self] in self?.requestStart(openSetup:{}) },stop:stopCapture,settings:{ [weak self] in self?.openSettings() })
        // DayDream's drag cards (MemoryWindow opens the setup window when setup isn't finished).
        actions.openSystemSettings={ [weak self] kind in self?.showPermissionCards(kind,openSetup:{}) }
        actions.checkPermissions={ [weak self] in self?.checkPermissions() }
        actions.openApplications=openApplicationsAction
        actions.openSettingsSection={ [weak self] in self?.openSettings($0) }
        actions.retryIssue={ [weak self] in self?.retryIssue() }
        actions.fixChrome={ [weak self] in self?.fixChromeAccess() }
        actions.openRecall={ [weak self] in
            guard let activity=self?.activity,activity.canSearch else {return}
            activity.recallPresented=true
        }
        return actions
    }

    /// Foreground generations retain committed scopes until their final read.
    private var foregroundNotes=0,foregroundCommitScopes=Set<NoteCommitScope>(),foregroundUnknownCommit=false
    /// A foreground generation began. Its own commit waits for its finish.
    func noteWriterStarted() {foregroundNotes += 1}
    /// A generation can change the selected note's state even without a committed model answer.
    func noteWriterFinished(day:String,timezone:String) {
        if foregroundNotes > 0 {foregroundNotes -= 1}
        foregroundCommitScopes.insert(NoteCommitScope(day:day,timezone:timezone))
        guard foregroundNotes == 0 else {return}
        let scopes=foregroundUnknownCommit ? nil:Array(foregroundCommitScopes)
        foregroundCommitScopes.removeAll();foregroundUnknownCommit=false
        refreshCommittedNotes(scopes)
    }
    /// Stored note metadata, independent of pending/retry/status text.
    private func notesCommitted(_ scopes:[NoteCommitScope]?) {
        guard foregroundNotes == 0 else {
            if let scopes {foregroundCommitScopes.formUnion(scopes)} else {foregroundUnknownCommit=true}
            return
        }
        refreshCommittedNotes(scopes)
    }
    private func refreshCommittedNotes(_ scopes:[NoteCommitScope]?) {
        let zone=activity.calendar.timeZone.identifier
        let plan=NoteCommitInvalidation.make(scopes:scopes,timezone:zone,
            today:try? DayScope.key(activity.now(),timezone:zone))
        if let days=plan.days {if !days.isEmpty {dayData.noteDaysChanged(days)}} else {dayData.notesChanged()}
        if plan.refreshToday {dayData.refreshToday(true)}
    }
    /// A level note was written: a block or day note changes its day's page; a week note changes the week line of each
    /// of its seven days (a past day's cached page is kept for good otherwise). A month shows on no day page.
    func levelCommitted(_ note:LevelNote) {
        switch note.level {
        case .block,.day: memoryChanged(day:note.period,timezone:note.timezone,sourceChanged:false)
        case .week:
            if note.timezone == activity.calendar.timeZone.identifier {
                let days=MemoryStore.days(week:note.period,timezone:note.timezone)
                if days.isEmpty {dayData.invalidateAll()} else {days.forEach {dayData.invalidate($0)}}
            } else {dayData.invalidateAll()}
            dayData.refreshToday(true)
        case .month: break
        }
    }
    /// Reviewed history landed (MemoryFlows.adopt): past days gained actions and summaries.
    private func historyAdded() {noteWriter.sourceChanged();dayData.invalidateAll();refresh()}
    /// Stored memory changed for one day, or for unknown days (nil). A day keyed in another time zone than
    /// the display calendar maps onto different day keys, so it drops every cached day too.
    func memoryChanged(day:String?,timezone:String?,sourceChanged:Bool=true) {
        if sourceChanged {noteWriter.sourceChanged()}
        if let day,timezone == nil || timezone == activity.calendar.timeZone.identifier {dayData.invalidate(day)}
        else {dayData.invalidateAll()}
        dayData.refreshToday(true)
    }
    /// A capture commit while recording: Today catches up at most every 2 s, and only when older than 10 s.
    private func captureCommitted() {
        noteWriter.sourceChanged()
        guard recording,commitRefresh == nil else {return}
        commitRefresh=Task { [weak self] in
            try? await Task.sleep(nanoseconds:2_000_000_000)
            guard let self else {return}
            self.commitRefresh=nil
            // fix/perf7: while no memory window shows today, at most once a minute. Each reread is the day's actions
            // and levels off the main thread plus Today's snapshot on it (about 290 ms on a 2,400-action day, debug),
            // and it ran up to every 10 s all day while recording. The window rereads when it appears (10 s) and the
            // menu bar panel when it opens (10 s); AI apps read the history themselves (MCP), not this snapshot.
            self.dayData.refreshTodayIfStale(ShellPresence.shared.isMounted(self.activity) ? 10 : 60)
        }
    }
    /// WriterIntegration.tick's status after it commits a note (local, or "… Written through OpenRouter by a model host asked not to keep it.").
    static let noteSavedStatus="Generated note saved"
    /// MemoryFlows.adopt's status once reviewed history is added to memory.
    static let historyAddedStatus="Reviewed history added"
    /// Keeps ActivityBrowser.summaries, .exclusions and the Exclude hook in step with the writer and the policy.
    private func observeWriterAndPrivacy() {
        let activity=activity
        noteWriter.$provider.combineLatest(noteWriter.$busy,noteWriter.$progress,noteWriter.$cloudCutoff)
            .combineLatest(noteWriter.$phase,noteWriter.$skippedMoments,noteWriter.$queue)
            .map { values,phase,skipped,queue -> SummaryAvailability in
                let (provider,busy,progress,cutoff)=values
                // Download progress only ever comes from a real writer value; nil hides the indicator. fix/day-card: under
                // the cloud, moments before it was turned on are never written (writesFrom). fix/sx-all: the writer's own
                // phase (fix/engine-battery) is the one state the Today card shows (fix/setup-status wiring).
                return SummaryAvailability(provider:SummaryAvailability.Provider(rawValue:provider) ?? .off,busy:busy,downloadProgress:progress,
                                           phase:phase,writesFrom:provider == "cloud" ? cutoff : nil,skipped:skipped,
                                           queue:provider == "off" ? nil : queue)
            }
            .removeDuplicates()
            .sink { value in if activity.summaries != value {activity.summaries=value} }
            .store(in:&sinks)
        // The Today card's one fixing button: Add Credits opens OpenRouter, Change Key opens Settings › Summarizer,
        // anything else is the writer's Try Again.
        activity.fixSummaries={ [weak self] problem in
            guard let self else {return}
            switch problem {
            case .cloudCredits: NSWorkspace.shared.open(CloudSummariesText.creditsURL)
            case .cloudKey, .noMemory: self.openSettings("Summaries")
            default: self.noteWriter.retry()
            }
        }
        // The status line names the saved summary setting (Coordinator.label). The store is written in the
        // writer's didSet, after this publishes, so the refresh waits for the next main run loop turn.
        noteWriter.$provider.removeDuplicates().dropFirst().receive(on:RunLoop.main)
            .sink { [weak self] _ in self?.coordinator?.summaryWriterChanged(); self?.refreshCaptureStatus() }
            .store(in:&sinks)
        $savedPrivacy.map(\.blockedApps).removeDuplicates()
            .sink { apps in
                let exclusions=ExclusionSummary.make(blockedApps:apps) {NSWorkspace.shared.urlForApplication(withBundleIdentifier:$0) != nil}
                if activity.exclusions != exclusions {activity.exclusions=exclusions}
            }
            .store(in:&sinks)
        // Main-actor committed scope notification; status/pending/retry text is not a write receipt.
        noteWriter.onNotesCommitted={ [weak self] scopes in self?.notesCommitted(scopes) }
        // Level notes (blocks, days, weeks) never set that status: the writer names each one, so its days are dropped.
        noteWriter.onLevelCommitted={ [weak self] note in self?.levelCommitted(note) }
        // claude/day-review-1003: a clause changes only its day's review.
        // Perf pass: only the hero card's review is refreshed (from the store's cache), never the whole Today read.
        noteWriter.onReviewClauseCommitted={ [weak self] day,zone in
            guard let self else {return}
            if zone == self.activity.calendar.timeZone.identifier {self.dayData.reviewChanged(day)} else {self.dayData.invalidate(day)}
        }
        // An import, a backup or a restore preview holds recording back while it runs; the state follows it, and a start
        // that waited for it runs once it ends (`operationsChanged`). Next turn, once both flags have settled.
        Publishers.Merge3(history.$busy.map {_ in},backups.$busy.map {_ in},backups.$prepared.map {_ in})
            .dropFirst(3)
            .receive(on:DispatchQueue.main)
            .sink { [weak self] in self?.operationsChanged() }
            .store(in:&sinks)
        // A history import adds past days; nothing else reports it. Next turn, once the import has settled.
        history.$status.filter {$0.hasPrefix(Self.historyAddedStatus)}
            .receive(on:DispatchQueue.main)
            .sink { [weak self] _ in self?.historyAdded() }
            .store(in:&sinks)
        // Published values change after their willSet, so re-check on the next main-queue turn.
        Publishers.Merge5($captureText.map {_ in},$blockedApps.map {_ in},$blockedDomains.map {_ in},$retention.map {_ in},$savedPrivacy.map {_ in})
            .merge(with:$browserPages.map {_ in})
            .receive(on:DispatchQueue.main)
            .sink { [weak self] in self?.syncExcludeHook() }
            .store(in:&sinks)
    }

    /// Reaches the shared day data (plan §4.4: `DaydreamDayCache` and `TodayDigest`, owned by
    /// ActivityBrowser). This model decides when that data is stale; the hooks act on it.
    struct DayDataHooks {
        var invalidate:@MainActor(String)->Void = {_ in}
        var invalidateAll:@MainActor()->Void = {}
        var notesChanged:@MainActor()->Void = {}
        var noteDaysChanged:@MainActor(Set<String>)->Void = {_ in}
        var refreshToday:@MainActor(_ force:Bool)->Void = {_ in}
        var refreshTodayIfStale:@MainActor(_ maxAge:TimeInterval)->Void = {_ in}
        /// claude/day-review-1003 perf pass: a day's review clause was saved (Today's hero card only).
        var reviewChanged:@MainActor(String)->Void = {_ in}
    }
    /// Transition times for this run, as one pure rule set for the button, timer and save paths.
    struct CaptureTransitionDates:Equatable {
        private(set) var recordingSince:Date?,pausedAt:Date?,stoppedAt:Date?
        /// Recording started (false → true): Start, Resume, or a timed pause resuming itself.
        mutating func recordingStarted(at now:Date) {recordingSince=now;pausedAt=nil;stoppedAt=nil}
        /// A pause took effect. A pause that follows another one (sleep then wake, a timed pause that
        /// could not resume) keeps the time the first began.
        mutating func paused(fromRecording:Bool,at now:Date) {
            if fromRecording || pausedAt == nil {pausedAt=now}
            recordingSince=nil;stoppedAt=nil
        }
        /// Recording or a pause ended in Off: Stop, or a preference save stopping the recorder.
        mutating func stopped(at now:Date) {stoppedAt=now;recordingSince=nil;pausedAt=nil}
        /// Recording is off without a transition this model made, so its start time no longer applies.
        mutating func notRecording() {recordingSince=nil}
    }
}

struct MemoryWindow: View {
    @ObservedObject var model: MemoryViewModel
    /// `.windowToolbar` in the app (the memory scene); `.inline` where no scene toolbar style applies
    /// (PackagedTrial and the offscreen checks host this view in a bare NSHostingView).
    var chrome: ShellChrome = .windowToolbar
    @Environment(\.openWindow) private var openWindow
    @State private var browsing=false
    @State private var consideredOnboarding=false
    @State private var consideredLaunchWarning=false
    /// The window's content height: the Settings sheet is never taller than the window it hangs from.
    @State private var contentHeight:CGFloat?
    @AppStorage("DaydreamOnboardingCompletedV1") private var onboardingCompleted=false
    var body: some View {
      // Scroll content fills the viewport instead of sizing the native window.
      GeometryReader { geometry in
        VStack(spacing:0) {
          #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
          if (model.recordingTrial || model.functionalTrial) && !browsing {
              RecordingTrialReadiness(model:model,browse:{browsing=true},settings:{model.settingsSection="Recording";model.settingsPresented=true})
          } else {
          if model.recordingTrial || model.functionalTrial {Button("Back to recording trial") {browsing=false}.padding(8)}
          MemoryShell(browser:model.activity,state:model.presentation,actions:captureActions,retry:model.refresh,delete:model.removeSource,indexingLine:model.searchIndexingLine,chrome:chrome)
              .task { await PackagedTrial.runIfRequested(model:model) }
          }
          #else
          MemoryShell(browser:model.activity,state:model.presentation,actions:captureActions,retry:model.refresh,delete:model.removeSource,indexingLine:model.searchIndexingLine,chrome:chrome)
          #endif
        }
        .frame(width:geometry.size.width.isFinite ? max(560,geometry.size.width):560,
               height:geometry.size.height.isFinite ? max(340,geometry.size.height):340)
        .onAppear {contentHeight=geometry.size.height;LaunchTrace.mark("window.memory")}
        .onChange(of:geometry.size.height) {contentHeight=$0}
      }
      .frame(minWidth:560,maxWidth:.infinity,minHeight:340,maxHeight:.infinity)
      .sheet(isPresented:$model.settingsPresented) {
          MemorySettings(model:model,height:DaydreamSettingsLayout.height(windowContentHeight:contentHeight))
              .font(.system(size:14)).buttonStyle(ReferenceButtonStyle())
              .environment(\.daydreamPermissionRequests,model.permissionRequests)
      }
      // The download-window warning (SPEC 6.3 R3): at launch, and again whenever recording is asked to start.
      .alert(LaunchLocation.warning,isPresented:$model.launchWarningPresented) {
          Button(PermissionRequestActions.openApplicationsTitle) { model.openApplicationsAction?() }
          // The copy in the download window holds the recorder lock until it quits.
          Button(LaunchLocation.quitTitle) { AppQuit.terminate() }
          Button("Not Now",role:.cancel) {}
      } message: {
          Text(LaunchLocation.detail)
      }
      .onAppear {
          if !consideredLaunchWarning {
              consideredLaunchWarning=true
              if model.launchLocation.blocksRecording {model.launchWarningPresented=true}
          }
          considerOnboarding()
          model.openSetupWindow={ [openWindow] in openWindow(id:"onboarding") }
          if model.chromeCardRequested && model.development == nil {openWindow(id:"onboarding")}
      }
      // gold r2: a history that opened late (a busy moment, or another copy stepping aside) is considered once it opens.
      .onChange(of: model.preferencesAvailable) { available in if available {considerOnboarding()} }
    }
    /// Setup opens by itself at a first launch, once, when the history is open (a copy that waited for another copy to
    /// let go of the history is considered once it opens it).
    private func considerOnboarding() {
        guard !consideredOnboarding, !model.historyOpening, !model.anotherCopyOpen else {return}
        consideredOnboarding=true
        let requested=CommandLine.arguments.contains("--onboarding")
        // Setup opens until it has been finished once; after an update from a test build whose setup was finished
        // before version 2, the short what's-new opens instead (DaydreamSetupVersion), also while recording: its pages
        // work then. The trials keep the first-run rule (their own page starts recording).
        let opens:Bool
        if model.recordingTrial || model.functionalTrial {
            opens = !onboardingCompleted && !model.recording && model.preferencesAvailable && model.items.isEmpty && model.noteWriter.provider == "off"
        } else {
            opens = model.preferencesAvailable && model.setupLaunch(counting:model.development == nil) != .none
        }
        if model.development == nil && (requested || opens) {openWindow(id:"onboarding")}
        // DayDream Preview: `--preview-setup` opens setup to click through (File › Set Up DayDream… does too).
        if model.development?.preview == true && CommandLine.arguments.contains(PreviewSample.setupArgument) {openWindow(id:"onboarding")}
    }
    /// The model's controls, with Start going through setup when something there must be done first.
    private var captureActions:CaptureActions {
        var actions=model.captureActions
        actions.resume={ [model,openWindow] in model.requestStart { openWindow(id:"onboarding") } }
        actions.openSystemSettings={ [model,openWindow] kind in model.showPermissionCards(kind) { openWindow(id:"onboarding") } }
        return actions
    }
}
extension MemoryViewModel {
    var replacementNeedsReview:Bool {
        do { return try replacement?.record().map { $0.phase != "rolled_back" } ?? false }
        catch { return true }
    }
    var presentation:CapturePresentation {
        // Stop only while there is something to stop: Recording or Paused (a timed pause, a failed save's retries, a wait
        // for an import), never Off or Needs Permission. A history set aside at launch (G45) shows only with no blocker.
        let kind=recordingState.kind
        var presentation=CapturePresentation(title:shortState,issue:shownIssue ?? presentedBlocker ?? (resumeUnavailable == nil ? historySetAsideIssue : nil),
                                             recording:recording,canResume:resumeUnavailable == nil || permissionBlockerUnsettled,
                                             canStop:kind == .recording || kind == .paused)
        // Redesigned surfaces read the four-state model; legacy views keep reading the title above.
        presentation.state=recordingState
        presentation.permissions=permissionsCheckedAt == nil ? nil:permissionSnapshot
        presentation.browserHistory=BrowserHistoryLine.make(recording:recording,pagesOn:browserPagesSaved,access:chromeLineAccess,chromeExcluded:chromeExcluded)
        presentation.chromeAskAgain=ChromeAccessMemory.refused(chromeLineAccess)
        return presentation
    }
}
/// What Settings' Chrome access row asks the system (Chrome page history). Injectable: the checks use fakes,
/// so no Apple Event reaches Chrome from them. The only prompt is `allowChromeAccess()`'s.
struct ChromeAccessEnvironment {
    /// Main thread: the person's running Google Chrome process (the frontmost one, else the newest; never a headless
    /// or automation Chrome, `ChromeProcesses`); nil when none is running.
    var running:()->pid_t?
    /// Main thread: how many of the person's own Chrome processes run (two with a second profile folder open).
    var copies:()->Int = {1}
    /// Background: Google's signature on that process (cached by launch identity).
    var verify:(pid_t)->Bool
    /// Current app version and persistent request receipt; nil disables upgrade prompting in fixtures.
    var version:()->String? = {nil}
    var promptedVersions:()->[String] = {[]}
    var markPromptVersion:(String)->Void = {_ in}
    static let promptVersionKey="DaydreamChromeAccessPromptVersions"
    /// Setup was finished once (the Chrome card is for upgrades only), and the Chrome card's one showing (`DaydreamChromeCard`).
    var setupFinished:()->Bool = {false}
    var cardShown:()->Bool = {true}
    var markCardShown:()->Void = {}
    /// Background: Automation status for Chrome. Never asks.
    var status:(pid_t)->OSStatus
    /// Background: stands in for the macOS prompt in the checks. nil (live) lets macOS ask.
    var ask:((pid_t)->OSStatus)?
    var background:(@escaping ()->Void)->Void
    var main:(@escaping ()->Void)->Void
    /// Main thread: runs the closure once, the next time Google Chrome comes to the front (an upgrade's access read,
    /// `checkChromeAccess`; never a question). The checks stand in a fake; nothing asks from here.
    var onNextChromeActivation:(@escaping ()->Void)->Void = {_ in}
    /// Any thread: seconds since boot, to tell an Allow… answered at once (no question shown) from one a person answered.
    var uptime:()->TimeInterval = {ProcessInfo.processInfo.systemUptime}
    /// Main thread: Google Chrome is installed (Launch Services; nothing opens). The checks stand in a fake.
    var installed:()->Bool = {false}
    /// Main thread: opens Google Chrome in the background for setup's Chrome step, then calls back on the main thread
    /// with whether it opened. Only `askChromeAccessInSetup` (the person's click) calls it. The checks stand in a fake.
    var openChrome:(@escaping (Bool)->Void)->Void = {$0(false)}
    /// Main thread: opens Privacy & Security › Automation (`ChromeAccessState.systemSettingsURL`; opening it changes
    /// nothing), only from a press (Open System Settings, Fix). The checks stand in a counter.
    var openPane:()->Void = {}
    /// Ask again: the running app's bundle id (`ChromeAutomationReset` resets only DayDream's own).
    var ownBundleID:()->String? = {Bundle.main.bundleIdentifier}
    /// Any thread: runs `/usr/bin/tccutil` with exactly `reset AppleEvents <DayDream's id>` and returns its exit status
    /// (`ChromeAutomationReset.runLive` refuses anything else). The checks stand in a recorder; nothing resets there.
    var resetAutomation:([String])->Int32 = {_ in -1}
    static var live:ChromeAccessEnvironment {
        ChromeAccessEnvironment(
            running:{ChromeEventSender.chosenProcess()},
            copies:{ChromeEventSender.userProcessCount()},
            verify:{ChromeEventSender.signatureValid(pid:$0,refresh:true)},
            version:{
                #if DEVELOPMENT_SOURCE_CHECKS
                return nil
                #else
                return Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String
                #endif
            },
            promptedVersions:{UserDefaults.standard.stringArray(forKey:promptVersionKey) ?? []},
            markPromptVersion:{version in
                let defaults=UserDefaults.standard
                var versions=defaults.stringArray(forKey:promptVersionKey) ?? []
                if !versions.contains(version) {versions.append(version);defaults.set(versions,forKey:promptVersionKey)}
            },
            setupFinished:{UserDefaults.standard.bool(forKey:MemoryViewModel.setupCompletedKey)},
            cardShown:{UserDefaults.standard.bool(forKey:DaydreamChromeCard.shownKey)},
            markCardShown:{UserDefaults.standard.set(true,forKey:DaydreamChromeCard.shownKey)},
            status:{ChromeEventSender.permissionStatus(pid:$0)},
            ask:nil,
            background:{ChromePageEnvironment.queue.async(execute:$0)},
            main:{DispatchQueue.main.async(execute:$0)},
            onNextChromeActivation:{action in
                let center=NSWorkspace.shared.notificationCenter
                var token:NSObjectProtocol?
                token=center.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) {note in
                    guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier==ChromePageTarget.bundleID else {return}
                    if let token {center.removeObserver(token)};token=nil
                    action()
                }
            },
            installed:{NSWorkspace.shared.urlForApplication(withBundleIdentifier:ChromePageTarget.bundleID) != nil},
            openChrome:{done in
                guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:ChromePageTarget.bundleID) else {done(false);return}
                let configuration=NSWorkspace.OpenConfiguration()
                configuration.activates=false
                configuration.addsToRecentItems=false
                NSWorkspace.shared.openApplication(at:url,configuration:configuration) {app,error in
                    DispatchQueue.main.async {
                        guard let app,error == nil else {done(false);return}
                        // Ask once Chrome has finished launching (at most ~10 s): an Apple Event to a Chrome still
                        // starting finds no process (-600) and the step would end without macOS's question.
                        func settle(_ tries:Int) {
                            if app.isTerminated {done(false);return}
                            if app.isFinishedLaunching || tries >= 40 {done(true);return}
                            DispatchQueue.main.asyncAfter(deadline:.now()+0.25) {settle(tries+1)}
                        }
                        settle(0)
                    }
                }
            },
            openPane:{NSWorkspace.shared.open(ChromeAccessState.systemSettingsURL)},
            resetAutomation:{ChromeAutomationReset.runLive($0)})
    }
}
/// The memory window's content for the launch session: "Getting ready…" while launch prepares the history, then the
/// memory window (whose toolbar arrives in a window already laid out). Outside the `@main` scene so the first-launch
/// check (dd-first-launch-checks) hosts exactly this.
struct DaydreamMainWindowContent: View {
    @ObservedObject var session: DaydreamLaunchSession
    var body: some View {
        #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
        if session.signedWriterAcceptance {
            Text("Signed writer acceptance · Recording OFF").padding().task {await SignedWriterTrial.run()}
        } else if let model=session.model {MemoryWindow(model:model)} else if let failure=session.failure {Text(failure).padding()}
        else if session.preparing {DaydreamPreparingWindow().onAppear {session.windowShown()}} else {SyntheticWindow()}
        #else
        if let model=session.model {MemoryWindow(model:model)} else if let failure=session.failure {Text(failure).padding()}
        else {DaydreamPreparingWindow().onAppear {session.windowShown()}}
        #endif
    }
}
/// The window while launch prepares the history (DaydreamLaunchSession.preparing): the menu bar's line, nothing else. The
/// memory window takes its place when the history is ready, and setup opens then if it isn't finished.
struct DaydreamPreparingWindow:View {
    var body:some View {
        VStack(spacing:12) { ProgressView(); Text(MenuBarMenu.preparingLine).font(.system(size:13)).foregroundStyle(.secondary) }
            .onAppear {LaunchTrace.mark("window.preparing")}
            .accessibilityElement(children:.combine)
            .frame(minWidth:560,maxWidth:.infinity,minHeight:340,maxHeight:.infinity)
    }
}
#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
struct SyntheticWindow:View {
    var chrome:ShellChrome = .windowToolbar
    @StateObject private var browser=ActivityBrowser(items:ActivityUIFixtures.items())
    var body:some View {
        GeometryReader { geometry in
            MemoryShell(browser:browser,state:CapturePresentation(title:"Synthetic preview"),actions:CaptureActions(),demo:true,chrome:chrome)
                // Nothing real feeds the popover's permission and summary reads here (contract request W2-24).
                .environment(\.daydreamStatusPreview,true)
                .frame(width:geometry.size.width.isFinite ? max(560,geometry.size.width):560,
                       height:geometry.size.height.isFinite ? max(340,geometry.size.height):340)
        }.frame(minWidth:560,maxWidth:.infinity,minHeight:340,maxHeight:.infinity)
    }
}
#endif
/// perm-1004: the permission page's actions, read again whenever the model changes (a `Turn on …` press's pane request,
/// the automatic restart's line). A scene's body doesn't follow the model, so the windows set them through this view.
struct PermissionRequestsHost<Content:View>: View {
    @ObservedObject var model:MemoryViewModel
    @ViewBuilder let content:()->Content
    var body:some View {content().environment(\.daydreamPermissionRequests,model.permissionRequests)}
}
/// A4's menu bar panel with the app's routes (`DaydreamMainWindow.menuBarRoutes`): the card's Open DayDream, Search…,
/// Settings… and today line bring the one memory window forward. The panel's default route is
/// `openWindow(id:)`, which for a WindowGroup always adds a window over the same browser.
struct DaydreamAppMenuBarPanel: View {
    let model: MemoryViewModel
    @Environment(\.openWindow) private var openWindow
    var body: some View { DaydreamMenuBarPanel(model: model, routes: DaydreamMainWindow.menuBarRoutes(openWindow)) }
}
#if !DEVELOPMENT_SOURCE_CHECKS
struct MacMemApplication: App {
    @StateObject private var session = DaydreamLaunchSession(deferModel:ProcessInfo.processInfo.environment["DAYDREAM_LAUNCH_SYNC_MODEL"] != "1")
    #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
    @MainActor static func main() {
        if ChromeNormalMainProbeAdmission.requested(CommandLine.arguments) {
            // Protected metadata admission precedes every QA Scene/property initializer.
            if ChromeNormalMainProbeRuntime.prepare(arguments: CommandLine.arguments, info: Bundle.main.infoDictionary ?? [:]) {
                ChromeNormalMainProbeApplication.main()
            }
        } else {
            // App.main is an extension, not an App requirement: generic dispatch uses SwiftUI's entry.
            daydreamDefaultSwiftUIAppMain(Self.self)
        }
    }
    #endif
    var body: some Scene {
        WindowGroup(session.preview ? (Bundle.main.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String).flatMap {$0.hasPrefix("DayDream Preview") ? $0 : nil} ?? "DayDream Preview" : session.development ? "DayDream · Development Trial" : session.isolated ? "DayDream · Isolated preview" : "DayDream",id:"memory") {
            DaydreamMainWindowContent(session:session)
        }
            // A scene modifier, so the style is set before the toolbar exists (A3: setting it on the NSWindow later
            // breaks NSToolbar's item layout on macOS 26.5). The window title stays for the Window menu and VoiceOver.
            .windowToolbarStyle(.unified(showsTitle:false))
            .defaultSize(width:1100,height:720)
            .commands { AppCommands(session:session) }
        // The windows below open from their own controls (Settings, the permission rows, File ▸ Set Up DayDream…,
        // onboarding), so none adds a Window-menu item (`commandsRemoved`): that item would also bypass the
        // Development Trial's disabled Set Up DayDream….
        #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
        Window("DayDream · Synthetic preview",id:"demo") { SyntheticWindow() }
            .windowToolbarStyle(.unified(showsTitle:false))
            .defaultSize(width:900,height:600)
            .commandsRemoved()
        #endif
        Window("DayDream permissions",id:"permissions") {
            if let model=session.model {
                PermissionRequestsHost(model:model) {
                    DaydreamPermissionSettings(enabled:model.development == nil,known:model.permissionSnapshot,allowedBefore:model.permissionsAllowedBefore)
                }
            } else {DaydreamPermissionSettings(enabled:false)}
        }.windowResizability(.contentSize)
            .commandsRemoved()
        Window("Set up DayDream",id:"onboarding") {
            if let model=session.model {PermissionRequestsHost(model:model) {DaydreamOnboarding(model:model)}}
            else {Text("DayDream setup is unavailable in this preview.").padding()}
        }.windowResizability(.contentSize)
            .commandsRemoved()
        // A4's panel (MenuBarContent.swift), with the app's window routes. The label is its own observing view: this
        // body observes only `session`.
        MenuBarExtra {
            if let model = session.model { DaydreamAppMenuBarPanel(model: model) }
            else { DaydreamMenuBarIsolatedPanel(line: session.preparing ? MenuBarMenu.preparingLine : MenuBarMenu.isolatedLine) }
        } label: {
            if let model = session.model { DaydreamMenuBarLabel(model: model) }
            else { DaydreamMenuBarIsolatedLabel() }
        }
        .menuBarExtraStyle(.window)
    }
}
#endif
