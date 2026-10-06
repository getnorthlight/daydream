// DD-RECIPE: APP
// Recording is never stuck on preferences (ux/blocker). Synthetic legacy stores, one per trigger, opened by a real
// MemoryViewModel (production mode, no Info.plist: no updater, no search runtime, no typing key):
//   A.  typed-text switch on without typed-text consent (the owner's case)       A2. with another consent version
//   B.  A plus an old app entry today's rule refuses ("Slack App")
//   C.  old site entries: "www.Example.com" (rewritten), "foo bar" and "intranet_host" (kept as saved: no site is removed)
//   C2. entries the site rule refuses but the stored-history matcher still uses ("me@x.org", "x.org?y=1", "x.org#y",
//       "bücher.de/x"): kept, and the same events are still dropped after the migration (Privacy.sanitized)
//   D.  "Web pages in Chrome" with another text's consent (the owner build asks consent 2 for its text)
//   E.  a capture state left at "recording" by a crash or a replaced app
//   F.  retention changed outside the app, then Use saved choices
//   G.  a revision conflict: one sentence, one button, and Start goes to setup's Apps page until it is fixed
//   H.  a change still in its short save delay when Start is pressed
//   I.  Start goes through setup: never finished, a permission missing, or ready
//   M.  migration never turns anything on, on a matrix of switch and consent states
//   S.  sources: the old wording is gone and every Start control goes through `requestStart` (`--sources-only` runs S
//       alone, touching nothing: the suite's preference-blocker-sources step)
// Each store is new and synthetic. Like every APP-recipe check it runs with HOME and CFFIXED_USER_HOME in scratch (it
// refuses otherwise), so UserDefaults, the setup flag and any keychain lookup stay there. Nothing records: it never calls
// startCapture or requestStart in a state where Start would run, reads permissions only through the substituted
// `MemoryViewModel.permissionsGranted`, and opens no window (the menu bar routes are recorders).
// Built with -D LEGACY_BASELINE against owner/v1 (its sources and objects), the same fixtures run through the old
// code and the trigger checks FAIL there: that is the proof the old stuck states are real.
import AppKit
import SwiftUI
import MemoryCore
import MemoryUI
import PrivacyPolicy

nonisolated(unsafe) var failures: [String] = []
func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    if ok { print("PASS: \(label)") } else { print("FAIL: \(label)" + (detail().isEmpty ? "" : " — \(detail())")); failures.append(label) }
    fflush(stdout)
}
func fatal(_ message: String) -> Never {
    fflush(stdout)
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}
@MainActor func tick(_ seconds: Double = 0.05) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
func makePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}
@MainActor func thrownMessage(_ body: () throws -> Void) -> String? {
    do { try body(); return nil }
    catch MemError.invalid(let message) { return message }
    catch { return "\(error)" }
}

@main @MainActor struct PreferenceBlockerChecks {
    static var out = URL(fileURLWithPath: "/")
    static let setupKey = "DaydreamOnboardingCompletedV1"
    static let noticeKey = "DaydreamPreferenceNoticeV1"
    #if LEGACY_BASELINE
    static let mode = "owner/v1 (without the fix)"
    #else
    static let mode = "ux/blocker"
    #endif

    static func main() async throws {
        // gold/r2-copy-checks: `--sources-only` runs S alone (a scan of the tree's sources) and nothing else: no model,
        // no store, no UserDefaults, no Keychain, so the suite runs it (run-checks.sh preference-blocker-sources). The
        // rest of this check builds production models that write UserDefaults and read the Keychain; it runs only in a
        // scratch account.
        if CommandLine.arguments.contains("--sources-only") {
            try sources()
            print(failures.isEmpty ? "ALL PASS (S, sources only)" : "\(failures.count) FAILED (S, sources only): \(failures.joined(separator: "; "))")
            exit(failures.isEmpty ? 0 : 1)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
            FileHandle.standardError.write(Data("FAIL: preference-blocker-checks watchdog expired after 120s\n".utf8))
            exit(2)
        }
        // Codex's shared roots, spelled so run-checks.sh's rewrite of the literal prefix leaves them intact.
        let shared = ["/private/tmp/" + "day" + "dream-", "/tmp/" + "day" + "dream-"]
        guard let outPath = ProcessInfo.processInfo.environment["DD_CHECK_OUT"], outPath.hasPrefix("/"),
              !shared.contains(where: { outPath.hasPrefix($0) }) else {
            fatal("DD_CHECK_OUT is not a private output directory")
        }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        guard home == ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              !home.isEmpty, home != (getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? "") else {
            fatal("HOME is not a scratch folder (UserDefaults and the setup flag must stay out of the real account): \(home)")
        }
        out = URL(fileURLWithPath: outPath, isDirectory: true)
        try makePrivateDirectory(out)
        print("mode: \(mode); owner typing \(OwnerTyping.enabled); Chrome page history \(ReleaseFeatures.chromePageHistory); Chrome consent current \(PrivacySettings.browserPagesConsentCurrent)")
        #if !LEGACY_BASELINE
        MemoryViewModel.permissionsGranted = { true }
        #endif
        UserDefaults.standard.set(true, forKey: setupKey)

        try await staleTyping(consent: nil, label: "A")
        try await staleTyping(consent: 2, label: "A2")
        try await staleTypingAndOldApp()
        try await oldSites()
        #if !LEGACY_BASELINE
        try keptSites()
        #endif
        try await oldChromeConsent()
        try await staleCaptureState()
        try await retentionChangedOutside()
        #if !LEGACY_BASELINE
        try await revisionConflict()
        #endif
        try await waitingChange()
        #if !LEGACY_BASELINE
        try await startGoesThroughSetup()
        try migrationMatrix()
        problemsAndNotices()
        #endif
        try sources()

        UserDefaults.standard.removeObject(forKey: setupKey)
        UserDefaults.standard.removeObject(forKey: noticeKey)
        print(failures.isEmpty ? "ALL PASS (\(mode))" : "\(failures.count) FAILED (\(mode)): \(failures.joined(separator: "; "))")
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: Fixtures

    /// A new private store with the policy `edit` leaves (written as an older build would have), and optionally a
    /// capture state left behind.
    static func fixture(_ name: String, capture: String? = nil, _ edit: (inout PrivacySettings) -> Void) throws -> URL {
        let home = out.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        let memory = home.appendingPathComponent("memory", isDirectory: true)
        try makePrivateDirectory(home); try makePrivateDirectory(memory)
        let store = try MemoryStore(home: memory, writable: true, automaticallySyncSearch: false)
        var policy = try store.policy()
        edit(&policy)
        try store.updatePolicy(policy)
        if let capture { try store.setCaptureState(capture, reason: "Recording (left behind by a build that stopped)") }
        return memory
    }
    static func open(_ memory: URL) async throws -> MemoryViewModel {
        UserDefaults.standard.removeObject(forKey: noticeKey)
        setenv("MAC_MEM_HOME", memory.path, 1)
        let model = MemoryViewModel()
        try await tick()
        guard model.development == nil, !model.recordingTrial, model.preferencesAvailable else { fatal("the model did not open \(memory.path): \(model.status)") }
        guard !model.recording else { fatal("a model is recording") }
        return model
    }
    static func saved(_ memory: URL) throws -> PrivacySettings {
        try MemoryStore(home: memory, automaticallySyncSearch: false).policy()
    }
    /// Recording can start as far as preferences go: nothing unresolved (startCapture's own guard), and, with the
    /// fix, Start doesn't go to setup (permissions substituted as allowed, setup finished).
    static func startsClean(_ model: MemoryViewModel) -> Bool {
        #if LEGACY_BASELINE
        return !model.preferencesUnresolved
        #else
        return !model.preferencesUnresolved && model.preferenceProblem == nil && model.setupStepForStart() == nil
        #endif
    }
    static func notice(_ model: MemoryViewModel) -> String? {
        #if LEGACY_BASELINE
        return nil
        #else
        return model.preferenceNotice
        #endif
    }

    // MARK: A, A2. Typed-text switch on without typed-text consent

    static func staleTyping(consent: Int?, label: String) async throws {
        let memory = try fixture("typing-\(label)") { p in p.captureText = true; p.typedConsentVersion = consent; p.blockedApps = ["com.example.editor"] }
        let before = try saved(memory)
        let model = try await open(memory)
        check(startsClean(model), "\(label): a store with the typed-text switch on and consent \(consent.map(String.init) ?? "missing") loads clean; recording can start",
              "unresolved \(model.preferencesUnresolved) status \(model.privacySaveStatus)")
        let after = try saved(memory)
        check(!after.captureText && after.typedConsentVersion == nil && !model.captureText,
              "\(label): typing is saved off (it never counted without consent); nothing turned on", "\(after.captureText) \(String(describing: after.typedConsentVersion))")
        check(after.blockedApps == before.blockedApps && after.blockedDomains == before.blockedDomains && after.retention == before.retention,
              "\(label): apps, sites and retention are unchanged")
        check(notice(model) == "Typing was turned off after the update. Turn it on again below if you want it.",
              "\(label): one plain notice says typing was turned off", notice(model) ?? "none")
        model.reloadPreferences()
        check(!model.preferencesUnresolved, "\(label): Use saved choices (reload) leaves nothing unresolved")
    }

    // MARK: B. Stale typing plus an old app entry today's rule refuses

    static func staleTypingAndOldApp() async throws {
        let memory = try fixture("typing-oldapp") { p in p.captureText = true; p.blockedApps = ["Slack App", "com.example.editor"] }
        let model = try await open(memory)
        check(startsClean(model), "B: a store with stale typing and the old app entry \"Slack App\" loads clean; recording can start")
        let message = thrownMessage { try model.excludeApp("dev.zed.Zed") }
        let after = try saved(memory)
        check(message == nil && after.blockedApps.contains("dev.zed.Zed") && after.blockedApps.contains("Slack App") && !after.captureText,
              "B: an unrelated save lands and keeps the old entry skipped", message ?? "\(after.blockedApps)")
        check(!model.preferencesUnresolved, "B: nothing is left unresolved after the save")
        #if !LEGACY_BASELINE
        // A new entry that breaks the rule is still refused, with one sentence and Undo.
        model.exclusionPreference.wrappedValue = model.blockedApps + ", Not An App"
        model.saveWaitingChoices()
        check(model.preferenceProblem == .invalidApp && model.preferenceProblem?.buttonTitle == "Undo" && (try? saved(memory).blockedApps.contains("Not An App")) == false,
              "B: a new app entry the rule refuses is not saved; one sentence and Undo", model.preferenceProblem?.text ?? "no problem")
        check(model.setupStepForStart() == .apps, "B: while it stands, Start goes to setup's Apps page")
        model.fixPreferenceProblem()
        check(startsClean(model) && model.blockedApps.contains("Slack App") && !model.blockedApps.contains("Not An App"),
              "B: Undo shows the saved choices and recording can start")
        #endif
    }

    // MARK: C. Old site entries

    static func oldSites() async throws {
        let memory = try fixture("sites") { p in p.blockedDomains = ["www.Example.com", "foo bar", "intranet_host", "news.example.org"] }
        let model = try await open(memory)
        check(startsClean(model), "C: a store with old site entries loads clean; recording can start")
        let message = thrownMessage { try model.addSite("example.net") }
        let after = try saved(memory)
        check(message == nil && after.blockedDomains.contains("example.net"), "C: adding a site saves (no invalid-sites refusal)", message ?? "\(after.blockedDomains)")
        #if !LEGACY_BASELINE
        check(Set(after.blockedDomains) == ["example.com", "example.net", "foo bar", "intranet_host", "news.example.org"],
              "C: \"www.Example.com\" became \"example.com\" (the same site and its subdomains); \"foo bar\" and \"intranet_host\" kept as saved", "\(after.blockedDomains)")
        for host in ["example.com", "www.example.com", "shop.example.com"] {
            check(BrowserSites.pageDecision("https://\(host)/", userBlocked: after.blockedDomains) == .blocked, "C: \(host) is still not recorded")
        }
        check(notice(model) == nil, "C: nothing was removed or turned off, so there is no notice", notice(model) ?? "none")
        #endif
    }

    // MARK: C2. Entries the site rule refuses are never removed

    /// The stored-history matcher (`ObservationPolicy`, through `Privacy.sanitized`) reads a host from entries the
    /// site rule refuses. The migration keeps them, so the same events stay out of history after the update.
    static func keptSites() throws {
        let entries = ["me@acme-clinic.org", "acme-clinic.org?ref=1", "acme-clinic.org#top", "b\u{FC}cher.de/x"]
        let memory = try fixture("kept-sites") { p in p.blockedDomains = entries }
        let store = try MemoryStore(home: memory, writable: true, automaticallySyncSearch: false)
        let now = Date()
        let at = ISO8601DateFormatter().string(from: now.addingTimeInterval(-5))
        func kept(_ url: String, _ settings: PrivacySettings) -> Bool {
            Privacy.sanitized(Evidence(id: UUID().uuidString, at: at, kind: "window", app: "Some App", bundle: "com.example.someapp",
                                       title: "Results", url: url), settings: settings, now: now) != nil
        }
        let urls = ["https://portal.acme-clinic.org/visit", "https://acme-clinic.org/", "https://xn--bcher-kva.de/"]
        let before = try store.policy()
        let droppedBefore = urls.filter { !kept($0, before) }
        let settled = try store.settleLegacyPreferences()
        let after = try store.policy()
        check(settled == LegacyPreferenceSettlement() && Set(after.blockedDomains) == Set(entries) && after.revision == before.revision,
              "C2: entries the site rule refuses are kept exactly as saved (no rewrite, no new revision)", "\(after.blockedDomains)")
        check(!droppedBefore.isEmpty && urls.filter { !kept($0, after) } == droppedBefore,
              "C2: every event the entries kept out of history before the migration is still kept out", "before \(droppedBefore)")
        for url in droppedBefore { check(!kept(url, after), "C2: \(url) is still not recorded") }
    }

    // MARK: D. Web pages in Chrome with another text's consent

    static func oldChromeConsent() async throws {
        let memory = try fixture("chrome") { p in p.browserPages = true; p.browserPagesConsentVersion = 1 }
        let stale = ReleaseFeatures.chromePageHistory && PrivacySettings.browserPagesConsentCurrent != 1
        let model = try await open(memory)
        check(startsClean(model), "D: a store with Web pages in Chrome on under consent 1 loads clean; recording can start")
        let after = try saved(memory)
        if stale {
            check(!after.browserPages && after.browserPagesConsentVersion == nil && !model.browserPages && !model.browserPagesSaved,
                  "D: the switch is saved off at launch (its consent was for another text), not on the first unrelated save")
            #if !LEGACY_BASELINE
            check(notice(model) == "Web pages in Chrome was turned off after the update. Turn it on again below if you want it.",
                  "D: one plain notice says Web pages in Chrome was turned off", notice(model) ?? "none")
            #endif
        } else {
            check(after.browserPages && after.browserPagesOn && notice(model) == nil, "D: consent 1 is this build's consent: nothing changes, no notice")
        }
    }

    // MARK: E. A capture state left at "recording"

    static func staleCaptureState() async throws {
        let memory = try fixture("capture", capture: "recording") { p in p.blockedApps = ["com.example.editor"] }
        let before = try MemoryStore(home: memory, automaticallySyncSearch: false).captureStatus()["state"]
        let model = try await open(memory)
        let state = try MemoryStore(home: memory, automaticallySyncSearch: false).captureStatus()["state"]
        check(before == "recording" && state == "off" && !model.recording, "E: a capture state left at \"recording\" reads as stopped once this app holds the recorder",
              "\(before ?? "nil") → \(state ?? "nil")")
        let message = thrownMessage { try model.excludeApp("dev.zed.Zed") }
        check(message == nil && startsClean(model), "E: saving is not refused as \"recording\", and recording can start", message ?? "")
    }

    // MARK: F. Retention changed outside the app

    static func retentionChangedOutside() async throws {
        let memory = try fixture("retention") { _ in }
        let model = try await open(memory)
        // What `mac-mem` does: a reviewed, confirmed retention change on its own store handle.
        let other = try MemoryStore(home: memory, writable: true, automaticallySyncSearch: false)
        let review = try other.prepareRetentionChange(.days(30))
        _ = try other.confirmRetentionChange(review.id, confirmed: true)
        model.reloadPreferences()
        check(startsClean(model) && model.retention == 30, "F: after retention changed outside the app, Use saved choices leaves nothing unresolved",
              "retention \(String(describing: model.retention)) unresolved \(model.preferencesUnresolved)")
    }

    #if !LEGACY_BASELINE
    // MARK: G. A revision conflict

    static func revisionConflict() async throws {
        let memory = try fixture("conflict") { p in p.blockedApps = ["com.example.editor"] }
        let model = try await open(memory)
        let other = try MemoryStore(home: memory, writable: true, automaticallySyncSearch: false)
        _ = try other.savePreferences(MemoryPreferences(blockedApps: ["com.example.editor", "com.example.elsewhere"], nativeTyping: false),
                                      expectedRevision: try other.policy().revision)
        let message = thrownMessage { try model.excludeApp("com.example.third") }
        check(message == "Your app choices changed in another window, so this change didn't save." && model.preferenceProblem == .conflict
              && model.preferenceProblem?.buttonTitle == "Use saved choices", "G: a conflict is one sentence and one button", message ?? "no error")
        check((try? saved(memory).blockedApps.contains("com.example.third")) == false && !model.recording, "G: the conflicting change saved nothing and nothing records")
        check(model.setupStepForStart() == .apps, "G: while it stands, Start goes to setup's Apps page")
        var opened = 0
        model.requestStart { opened += 1 }
        check(opened == 1 && model.setupRequest == .apps && !model.recording, "G: requestStart opens setup at Apps and starts nothing")
        model.setupRequest = nil
        model.fixPreferenceProblem()
        check(model.preferenceProblem == nil && startsClean(model) && model.blockedApps.contains("com.example.elsewhere"),
              "G: its one button fixes it and recording can start")
        // Allow Permissions (Needs Permission in the menu bar or the main window): DayDream's drag cards, never System
        // Settings on its own. Setup's Permissions page until setup is finished, then Settings › Permissions.
        let completed = UserDefaults.standard.object(forKey: MemoryViewModel.setupCompletedKey)
        defer { UserDefaults.standard.set(completed, forKey: MemoryViewModel.setupCompletedKey) }
        var setupOpened = 0, mainOpened = 0
        UserDefaults.standard.set(false, forKey: MemoryViewModel.setupCompletedKey)
        model.settingsPresented = false
        model.showPermissionCards(openSetup: { setupOpened += 1 }, openMain: { mainOpened += 1 })
        check(setupOpened == 1 && mainOpened == 0 && model.setupRequest == .permissions && !model.settingsPresented && !model.recording,
              "G: Allow Permissions before setup is finished opens setup at its drag cards")
        model.setupRequest = nil
        UserDefaults.standard.set(true, forKey: MemoryViewModel.setupCompletedKey)
        model.showPermissionCards(openSetup: { setupOpened += 1 }, openMain: { mainOpened += 1 })
        check(setupOpened == 1 && mainOpened == 1 && model.setupRequest == nil && model.settingsPresented && model.settingsSection == "Permissions",
              "G: Allow Permissions after setup opens Settings › Permissions (the same drag cards)")
        model.settingsPresented = false; model.settingsSection = "General"
    }
    #endif

    // MARK: H. A change still in its short save delay

    static func waitingChange() async throws {
        let memory = try fixture("waiting") { p in p.blockedApps = ["com.example.editor"] }
        let model = try await open(memory)
        model.exclusionPreference.wrappedValue = model.blockedApps + ", dev.zed.Zed"
        #if LEGACY_BASELINE
        check(!model.preferencesUnresolved, "H: Start pressed within the save delay is not refused")
        #else
        check(model.preferencesUnresolved && model.preferenceProblem == nil, "H: a change in its save delay is waiting, not a problem")
        check(model.setupStepForStart() == nil && !model.preferencesUnresolved && (try? saved(memory).blockedApps.contains("dev.zed.Zed")) == true,
              "H: Start saves the waiting change first, and recording can start")
        #endif
        try await tick(0.3)
    }

    #if !LEGACY_BASELINE
    // MARK: I. Start goes through setup

    static func startGoesThroughSetup() async throws {
        let memory = try fixture("setup") { _ in }
        let model = try await open(memory)
        var routes: [String] = []
        let recorder = DaydreamMenuBarRoutes(openWindow: { routes.append("open:" + $0) }, activate: { routes.append("activate") },
                                             openURL: { routes.append("url:" + $0.absoluteString) }, terminate: { routes.append("terminate") })
        UserDefaults.standard.set(false, forKey: setupKey)
        check(model.setupStepForStart() == .summaries, "I: setup never finished: Start goes to setup")
        DaydreamMenuBarPanel.actions(model: model, routes: recorder).resume()
        check(routes == ["open:onboarding", "activate"] && model.setupRequest == .summaries && !model.recording,
              "I: the menu bar's Start opens setup and starts nothing", "\(routes)")
        model.setupRequest = nil
        model.captureActions.resume()
        check(model.setupRequest == .summaries && !model.recording, "I: the main window's Start asks for setup and starts nothing")
        model.setupRequest = nil
        UserDefaults.standard.set(true, forKey: setupKey)
        MemoryViewModel.permissionsGranted = { false }
        check(model.setupStepForStart() == .permissions, "I: a permission missing: Start goes to setup's Permissions page")
        routes = []
        DaydreamMenuBarPanel.actions(model: model, routes: recorder).resume()
        check(routes == ["open:onboarding", "activate"] && model.setupRequest == .permissions && !model.recording, "I: the menu bar's Start opens Permissions")
        model.setupRequest = nil
        MemoryViewModel.permissionsGranted = { true }
        check(model.setupStepForStart() == nil && startsClean(model), "I: setup finished, both permissions and saved choices: Start starts (not called here)")
    }

    // MARK: M. Migration never turns anything on

    static func migrationMatrix() throws {
        var cases = 0
        for text in [false, true] { for textConsent in [nil, 1, 2] as [Int?] { for pages in [false, true] { for pagesConsent in [nil, 1, 2] as [Int?] {
            let memory = try fixture("matrix") { p in
                p.captureText = text; p.typedConsentVersion = textConsent; p.browserPages = pages; p.browserPagesConsentVersion = pagesConsent
                p.blockedApps = ["Old App", "com.example.editor"]; p.blockedDomains = ["www.Example.com", "a b", "intranet_host"]
            }
            let store = try MemoryStore(home: memory, writable: true, automaticallySyncSearch: false)
            let before = try store.policy()
            let settled = try store.settleLegacyPreferences()
            let after = try store.policy()
            let label = "text \(text)/\(textConsent.map(String.init) ?? "nil") pages \(pages)/\(pagesConsent.map(String.init) ?? "nil")"
            check((!after.captureText || before.captureText) && (!after.typingOn || before.typingOn)
                  && (!after.browserPages || before.browserPages) && (!after.browserPagesOn || before.browserPagesOn),
                  "M: \(label): nothing turned on")
            check(after.typingOn == before.typingOn && after.browserPagesOn == before.browserPagesOn,
                  "M: \(label): what records is unchanged (only switches that already counted as off are saved off)")
            check(after.blockedApps == before.blockedApps, "M: \(label): app entries untouched")
            check(Set(after.blockedDomains) == ["example.com", "a b", "intranet_host"] && settled.sitesRewritten == ["www.Example.com"], "M: \(label): sites", "\(after.blockedDomains)")
            check(settled.changed && after.revision != before.revision && (try? store.settleLegacyPreferences()) == LegacyPreferenceSettlement(),
                  "M: \(label): a new revision once; settling again changes nothing")
            cases += 1
        } } } }
        let fresh = try fixture("fresh") { _ in }
        let store = try MemoryStore(home: fresh, writable: true, automaticallySyncSearch: false)
        let revision = try store.policy().revision
        check((try? store.settleLegacyPreferences()) == LegacyPreferenceSettlement() && (try? store.policy().revision) == revision,
              "M: a current store is left exactly as it is (\(cases) legacy cases checked)")
        let reader = try MemoryStore(home: fresh, automaticallySyncSearch: false)
        check((try? reader.settleLegacyPreferences()) == LegacyPreferenceSettlement(), "M: a read-only store is never rewritten")
    }

    // MARK: Problems and notices say one thing each

    static func problemsAndNotices() {
        let errors: [PreferenceSaveError?] = [.revisionConflict, .invalidApps, .invalidDomains, .captureMustBeStopped, .storageUnavailable, nil]
        for error in errors {
            guard let problem = PreferenceProblem.make(error: error, differsFromSaved: true, waiting: false) else { check(false, "problem for \(String(describing: error))"); continue }
            let sentences = problem.text.filter { $0 == "." }.count
            check(sentences == 1 && problem.text.hasSuffix(".") && !problem.buttonTitle.isEmpty && !problem.text.contains("preference"),
                  "problem \(String(describing: error)): one plain sentence and one button (\(problem.buttonTitle))", problem.text)
        }
        check(PreferenceProblem.make(error: nil, differsFromSaved: true, waiting: true) == nil && PreferenceProblem.make(error: nil, differsFromSaved: false, waiting: false) == nil,
              "a change in its save delay, or nothing different, is no problem")
        var both = LegacyPreferenceSettlement(); both.typingTurnedOff = true; both.chromePagesTurnedOff = true
        check(MemoryViewModel.noticeText(both) == "Typing and Web pages in Chrome were turned off after the update. Turn them on again below if you want them.",
              "notice: typing and Chrome together")
        var rewritten = LegacyPreferenceSettlement(); rewritten.sitesRewritten = ["www.Example.com"]
        check(MemoryViewModel.noticeText(rewritten) == nil, "notice: a site only rewritten to the same site says nothing")
    }
    #endif

    // MARK: S. Sources

    static func sources() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceDirs = ["Sources/MacMemApp", "Sources/MemoryUI", "Sources/MemoryCore"]
        var all = ""
        for dir in sourceDirs {
            for name in try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path) where name.hasSuffix(".swift") {
                all += try String(contentsOf: root.appendingPathComponent(dir).appendingPathComponent(name), encoding: .utf8)
            }
        }
        check(!all.contains("Resolve unsaved preferences before recording"), "S: the old \"Resolve unsaved preferences\" wording is gone")
        check(!all.contains("\"Retry saving\"") && !all.contains("\"Reload saved choices\""), "S: no Retry saving / Reload saved choices pair")
        let app = try String(contentsOf: root.appendingPathComponent("Sources/MacMemApp/MacMemApp.swift"), encoding: .utf8)
        let menu = try String(contentsOf: root.appendingPathComponent("Sources/MacMemApp/MenuBarContent.swift"), encoding: .utf8)
        let commands = try String(contentsOf: root.appendingPathComponent("Sources/MacMemApp/AppCommands.swift"), encoding: .utf8)
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/MacMemApp/DaydreamSettings.swift"), encoding: .utf8)
        let onboarding = try String(contentsOf: root.appendingPathComponent("Sources/MacMemApp/DaydreamOnboarding.swift"), encoding: .utf8)
        check(menu.contains("resume: { model.requestStart { routes.openWindow(\"onboarding\"); routes.activate() } }"), "S: the menu bar's Start goes through requestStart")
        check(commands.contains("model.requestStart { openWindow(id: \"onboarding\")"), "S: the app menu's Start goes through requestStart")
        check(app.contains("actions.resume={ [model,openWindow] in model.requestStart { openWindow(id:\"onboarding\") } }"), "S: the main window's Start goes through requestStart")
        // Settings has no Start of its own (Advanced lost its second Start/Stop): every Start is one of the three above.
        check(!settings.contains("RecordingMasterControl(") && !settings.contains("DisclosureGroup(\"Recording controls\")")
              && !settings.contains("Launch at login"), "S: Settings has no second Start/Stop and no greyed-out Launch at login")
        if let coordinator = app.range(of: "coordinator = try Coordinator(store:store)"), let settle = app.range(of: "store.settleLegacyPreferences()") {
            check(coordinator.lowerBound < settle.lowerBound, "S: choices are settled only after this app holds the recorder lock")
        } else { check(false, "S: MacMemApp settles legacy choices at launch") }
        // Each row on setup's last page is one click back to the page that changes it, with no "Edit" text.
        // fix/setup-status: Summaries goes to its page, or carries its one fixing button. Owner 10/5: it is the last page's
        // only row (Connect your AI); Typed text and Web pages in Chrome were chosen on the page before.
        check(onboarding.contains("edit: button == nil ? { show(.summaries) } : nil, button: button")
              && !onboarding.contains("\"Edit\""),
              "S: setup's last page rows are one click to the page that changes them")
        // Setup can't be skipped past Permissions: no Set up later there (closing the window is later).
        check(!onboarding.contains("secondaryTitle") && !onboarding.contains("\"Set up later\" }"), "S: setup's Permissions page has no Set up later")
        check(!onboarding.contains("Recording is off. Your choices are saved."), "S: setup's last page has no standing message")
        // Owner 10/5: the last page is Connect your AI, a title that claims nothing about what's left; the button or the
        // status row names what's left (fix/setup-status: never "You're all set" while something is).
        check(onboarding.contains("case .review: return Self.connectTitle") && !onboarding.contains("allSetTitle"),
              "S: setup's last page is Connect your AI and never says You're all set")
    }
}
