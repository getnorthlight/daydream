import SwiftUI
import Sparkle
import MemoryCore
import MemoryUI

/// Sparkle updates from DayDream's website (https://getdaydream.app/appcast.xml, packaging/updates.json).
///
/// - A build without the update keys in Info.plist (every development build, the owner's copy, the private QA copy)
///   never creates Sparkle, so it never checks, downloads or installs anything. The QA and Live Test binaries refuse
///   even with the keys (`UpdateConfiguration.compiledOff`).
/// - Release builds (scripts/developer-id-release.py stage) check once a day (SUEnableAutomaticChecks,
///   SUScheduledCheckInterval 86400) and download a found update quietly (SUAutomaticallyUpdate,
///   SUAllowsAutomaticUpdates). Nothing pops up: the update waits (`waiting`) for the next quit, log out or restart,
///   or for Restart to Update in the menu bar menu, the app menu or Settings, whichever comes first. One switch turns
///   checking and downloading on and off together; the first launch with quiet updates applies it once (0.1.3 and
///   earlier saved "never download" on every launch).
/// - An update Sparkle can't install by itself (it needs an administrator's password, for example) is offered the
///   same quiet way, as Update DayDream…, which opens Sparkle's window only when the person picks it.
/// - Every archive must be EdDSA-signed with the key whose public half is SUPublicEDKey,
///   the feed must be signed too (SURequireSignedFeed), and the archive is verified before
///   it is unpacked (SUVerifyUpdateBeforeExtraction).
/// - An update installs only after DayDream has quit (Sparkle replaces the app once it has exited). Nothing pauses
///   before then: the quit itself pauses recording and saves typed text, as every quit does (MacMemApp's
///   willTerminate). So an install that stops, or a quit that doesn't happen, leaves recording as it was.
/// - Restart to Update (and Sparkle's Install and Relaunch) closes Settings (and any other sheet) before Sparkle's
///   installer asks DayDream to quit (`prepareToQuit`), since AppKit refuses a quit under a sheet; the quit event goes
///   through AppQuit too.
/// - If recording was on and Sparkle relaunches DayDream, recording starts again at the relaunch (`UpdateResume`).
///   The marker is removed when the install stops, or when DayDream is still running a minute later.
/// - The status line answers Check Now. A scheduled check that can't reach or read the update page says nothing:
///   a copy whose update page isn't published yet would otherwise show an error for good.
@MainActor final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    @Published private(set) var status=UpdateText.notConfigured
    @Published var canCheck=false
    @Published var automaticChecks=false
    /// Check Now is running (Settings shows "Checking…" and disables the button).
    @Published private(set) var checking=false
    @Published private(set) var lastCheck:Date?
    /// An update waiting for the person (downloaded, or needing Sparkle's window); nil when there is none.
    @Published private(set) var waiting:UpdateWaiting?
    /// Sparkle's install-now block for the downloaded update (`waiting == .restart`).
    private var installNow:(()->Void)?
    private var controller:SPUStandardUpdaterController?
    private var configuration:UpdateConfiguration?
    private var observations:[NSKeyValueObservation]=[]
    var replacementInProgress:()->Bool = { false }
    /// Whether recording is on right now (the model's `recording`), read as Sparkle begins the relaunch.
    var isRecording:()->Bool = { false }
    /// Closes Settings and every other sheet before Sparkle's installer asks DayDream to quit. The checks pass their own.
    var prepareToQuit:()->Void = { AppQuit.prepare() }
    /// Where the relaunch marker lives (the checks pass a store of their own, never the real preferences).
    var defaults:UserDefaults = .standard
    /// How long DayDream may still be running after Sparkle began the relaunch before the relaunch counts as not
    /// happening (the marker is removed then).
    var relaunchGrace:TimeInterval=60
    /// A relaunch Sparkle began and that hasn't happened or stopped yet; a new one or an end makes older timers moot.
    private var relaunchToken=0
    private(set) var relaunchPending=false
    let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String
    /// Set at the first launch with quiet updates (see `start`).
    static let quietUpdatesKey="DaydreamQuietUpdatesV1"
    override init() {
        super.init()
    }
    func start() {
        guard controller == nil else { return }
        // Missing configuration means no Sparkle instance, scheduler or network.
        guard let config=try? UpdateConfiguration(info:Bundle.main.infoDictionary ?? [:]) else { return }
        configuration=config
        let controller=SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:self,userDriverDelegate:self)
        self.controller=controller
        let updater=controller.updater
        observations=[
            updater.observe(\.canCheckForUpdates,options:[.initial,.new]) { [weak self] updater,_ in
                Task { @MainActor in self?.canCheck=updater.canCheckForUpdates }
            },
            updater.observe(\.automaticallyChecksForUpdates,options:[.new]) { [weak self] _,_ in
                Task { @MainActor in self?.readSettings() }
            },
        ]
        do {
            try updater.start()
            // 0.1.3 and earlier saved "never download" at every launch. The first launch with quiet updates makes
            // downloads follow checks, once; after that the person's choice (the switch, or the checkbox in
            // Sparkle's window) stays.
            if !defaults.bool(forKey:Self.quietUpdatesKey) {
                updater.automaticallyDownloadsUpdates=updater.automaticallyChecksForUpdates
                defaults.set(true,forKey:Self.quietUpdatesKey)
            }
            readSettings()
            status=""
        } catch { status=UpdateText.checkFailed }
    }
    private func readSettings() {
        guard let updater=controller?.updater else { return }
        automaticChecks=updater.automaticallyChecksForUpdates
        lastCheck=updater.lastUpdateCheckDate
    }
    /// The menu's Check for Updates…: Sparkle's own window says what it found.
    func check() {
        guard configured else { return }
        guard !replacementInProgress() else { status=UpdateText.blockedByReplacement; return }
        guard waiting == nil else { actOnWaiting(); return }
        controller?.checkForUpdates(nil)
    }
    /// The one action for a waiting update (the menu bar row, the app menu item, the Settings button): Restart to
    /// Update installs the downloaded update and opens DayDream again; Update DayDream… opens Sparkle's window.
    func actOnWaiting() {
        guard configured, let waiting else { return }
        guard !replacementInProgress() else { status=UpdateText.blockedByReplacement; return }
        switch waiting {
        case .restart:
            // Sparkle quits DayDream (updaterWillRelaunchApplication: `relaunching` keeps recording's state for the
            // relaunch and closes the sheets), installs, and opens the new version.
            installNow?()
        case .review:
            controller?.checkForUpdates(nil)
        }
    }
    /// Settings' Check Now: the answer is the status line. A found update downloads quietly and waits like any other.
    func checkNow() {
        guard configured, let updater=controller?.updater else { return }
        guard !replacementInProgress() else { status=UpdateText.blockedByReplacement; return }
        guard waiting == nil else { actOnWaiting(); return }
        guard !updater.sessionInProgress else { return }
        checkStarted()
        updater.checkForUpdatesInBackground()
    }
    /// Check Now began: its answer, good or bad, becomes the status line (`finished`).
    func checkStarted() {
        checking=true
        status=UpdateText.checking
    }
    /// The page's one switch: checking and quiet downloading together. Off: nothing is checked or downloaded unasked.
    /// An update already downloaded still installs at the next quit (Sparkle always finishes one it has).
    func setChecks(_ value:Bool) {
        guard let updater=controller?.updater else { automaticChecks=false; return }
        updater.automaticallyChecksForUpdates=value
        updater.automaticallyDownloadsUpdates=value
        readSettings()
        status=""
    }
    /// The status line: a waiting update, else a check's result, else when the last one ran.
    var statusLine:String? { waiting?.statusLine ?? (status.isEmpty ? UpdateText.lastChecked(lastCheck,now:Date()) : status) }
    // MARK: SPUUpdaterDelegate
    func updaterShouldPromptForPermissionToCheck(forUpdates updater:SPUUpdater)->Bool { false }
    func feedURLString(for updater:SPUUpdater)->String? { configuration?.feed.absoluteString }
    func updater(_ updater:SPUUpdater,mayPerform updateCheck:SPUUpdateCheck) throws {
        guard configuration != nil else { throw MemError.invalid("Updates aren't set up in this copy of DayDream.") }
        guard !replacementInProgress() else { throw MemError.invalid(UpdateText.blockedByReplacement) }
    }
    func updater(_ updater:SPUUpdater,shouldProceedWithUpdate item:SUAppcastItem,updateCheck:SPUUpdateCheck) throws {
        guard configuration?.permitsArchive(item.fileURL) == true,
              UpdateConfiguration.newer(item.versionString,than:Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "") else { throw MemError.invalid("Update rejected: unexpected archive or non-increasing build.") }
        guard !replacementInProgress() else { throw MemError.invalid(UpdateText.blockedByReplacement) }
    }
    func updater(_ updater:SPUUpdater,didFindValidUpdate item:SUAppcastItem) { checking=false; status=UpdateText.available(item.displayVersionString) }
    func updaterDidNotFindUpdate(_ updater:SPUUpdater) { checking=false; status=UpdateText.upToDate; lastCheck=updater.lastUpdateCheckDate }
    // No willInstallUpdate: the install happens after DayDream quits, and the quit pauses recording (see the top).
    func updaterWillRelaunchApplication(_ updater:SPUUpdater) { relaunching() }
    /// A quietly downloaded update is ready. DayDream takes it (true): nothing is shown, it installs at the next quit,
    /// log out or restart, or now if the person picks Restart to Update (`actOnWaiting`).
    func updater(_ updater:SPUUpdater,willInstallUpdateOnQuit item:SUAppcastItem,immediateInstallationBlock immediateInstallHandler:@escaping ()->Void)->Bool {
        installNow=immediateInstallHandler
        updateWaiting(.restart(version:item.displayVersionString))
        return true
    }
    /// What the menus and Settings offer for an update, and the status line that says so. Check Now is answered.
    func updateWaiting(_ value:UpdateWaiting?) {
        waiting=value
        if value != nil { checking=false; status="" }
    }
    func updater(_ updater:SPUUpdater,didFinishUpdateCycleFor updateCheck:SPUUpdateCheck,error:Error?) {
        // Sparkle reports an abort before the cycle ends; if a cycle ends with its error first, it is the same answer.
        if let error { finished(error:error as NSError) }
        checking=false
        // A check never stays "Checking…".
        if status == UpdateText.checking { status="" }
    }
    func updater(_ updater:SPUUpdater,didAbortWithError error:Error) { finished(error:error as NSError) }
    /// A check or install that stopped with `error`. Check Now's failure is the status line; a scheduled check that
    /// can't reach or read the update page changes nothing, and a cancelled install is not a failure
    /// (`UpdateText.failureLine`). An install that stopped won't relaunch DayDream.
    func finished(error:NSError) {
        let asked=checking
        checking=false
        // "No update found" also arrives here; updaterDidNotFindUpdate already said so.
        if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue) { return }
        relaunchEnded()
        if replacementInProgress() { status=UpdateText.blockedByReplacement; return }
        let underlying=error.userInfo[NSUnderlyingErrorKey] as? NSError
        if let line=UpdateText.failureLine(asked:asked,domain:error.domain,code:error.code,underlyingDomain:underlying?.domain) { status=line }
        else if status == UpdateText.checking { status="" }
    }
    /// Sparkle is relaunching DayDream after installing. If recording is on, leave the marker the next launch reads
    /// once (`UpdateResume`). Then close the sheets, so the installer's quit isn't refused. If DayDream is still running
    /// `relaunchGrace` later, the relaunch didn't happen: the marker goes, and recording simply carries on.
    func relaunching(now:Date=Date()) {
        relaunchToken += 1
        let token=relaunchToken
        relaunchPending=true
        if isRecording() {
            UpdateResume.record(defaults,build:Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown",at:now)
        } else {
            UpdateResume.clear(defaults)
        }
        prepareToQuit()
        DispatchQueue.main.asyncAfter(deadline:.now()+relaunchGrace) { [weak self] in
            MainActor.assumeIsolated { if self?.relaunchToken == token { self?.relaunchEnded() } }
        }
    }
    /// The relaunch Sparkle began won't happen (the install stopped, or DayDream is still running): no launch after
    /// this one starts recording because of it.
    func relaunchEnded() {
        guard relaunchPending else { return }
        relaunchPending=false
        relaunchToken += 1
        UpdateResume.clear(defaults)
    }
    var configured:Bool { configuration != nil && controller != nil }
    // MARK: SPUStandardUserDriverDelegate (Sparkle calls it on the main thread)
    // Never interrupts: a scheduled update Sparkle would show in a window (one it can't download and install by itself)
    // is offered quietly instead, as Update DayDream… (`waiting == .review`). A check the person started (Check for
    // Updates…) is still answered by Sparkle's window, as they asked.
    var supportsGentleScheduledUpdateReminders:Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update:SUAppcastItem,andInImmediateFocus immediateFocus:Bool)->Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate:Bool,forUpdate update:SUAppcastItem,state:SPUUserUpdateState) {
        if handleShowingUpdate { status=UpdateText.available(update.displayVersionString) }
        else if waiting == nil { updateWaiting(.review(version:update.displayVersionString)) }
    }
    /// The person opened Sparkle's window for it (or chose in it): Update DayDream… has done its job.
    func standardUserDriverDidReceiveUserAttention(forUpdate update:SUAppcastItem) { if case .review = waiting { updateWaiting(nil) } }
    func standardUserDriverWillFinishUpdateSession() { if case .review = waiting { updateWaiting(nil) } }
}

/// Settings › App updates (sat5): one card. The status line (the version, then the last check's result) with
/// Check Now, and one switch for automatic updates with the network fact under it. While an update waits, the
/// button is its one action (Restart to Update).
struct UpdateSettings: View {
    @ObservedObject var updates:Updates
    var body:some View {
        if updates.configured {
            VStack(alignment:.leading,spacing:0) {
                SettingsRow(UpdateText.versionTitle(updates.version),secondary:updates.statusLine) {
                    if let waiting=updates.waiting {
                        Button(waiting.title) { updates.actOnWaiting() }
                            .accessibilityIdentifier("updates-restart")
                    } else {
                        Button(UpdateText.checkTitle) { updates.checkNow() }
                            .disabled(!updates.canCheck || updates.checking)
                            .accessibilityIdentifier("updates-check-now")
                    }
                }
                .accessibilityIdentifier("updates-status")
                Divider().padding(.vertical,6)
                Toggle(isOn:Binding(get:{updates.automaticChecks},set:updates.setChecks)) {
                    VStack(alignment:.leading,spacing:3) {
                        Text(UpdateText.switchTitle).font(.system(size:13))
                        Text(UpdateText.sourceNote).font(.system(size:12)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(ReferenceToggleStyle()).frame(minHeight:52)
                .accessibilityIdentifier("updates-automatic")
            }
        } else {
            // No check can run in this copy, so there is nothing to switch and no network fact to state.
            Text(UpdateText.notConfigured).font(.system(size:13)).foregroundStyle(.secondary)
                .fixedSize(horizontal:false,vertical:true)
        }
    }
}
