// DD-RECIPE: UI
// Saturday honesty track: what setup and Settings tell people (checklist items 19-24).
//   A. the fixed wording: password managers, cloud summaries, FileVault (read with fdesetup), own Mac, the privacy
//      promise;
//   B. setup's summaries page: "Summaries on this Mac", then "Use an OpenRouter key instead" with its one line (both off is Off),
//      and "Summaries on this Mac" offered in a build with the runtime inside (every release, writer/v2) and hidden in a
//      test build without it;
//   C. setup's review page always shows the own-Mac notice, and the FileVault notice exactly when FileVault is off;
//   D. no user-facing source still says activity "stays on this Mac" or names zero data retention;
//   E. the visible cloud line against the request CloudWriter really sends (a stub transport, no network): typed words
//      are in the body exactly when the switch is on with the version-2 notice recorded, and nothing is sent otherwise.
// Views are hosted offscreen. No app, permission, recording, network or Apple Event.
import AppKit
import SwiftUI
import MemoryCore
import MemoryUI
import WriterBackend

@MainActor @main struct HonestyUIChecks {
    static var passed = 0
    static func check(_ condition: Bool, _ name: String) {
        guard condition else { fflush(stdout); FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8)); exit(1) }
        passed += 1; print("PASS: " + name); fflush(stdout)
    }
    static func pump(_ s: Double = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    static let window: NSWindow = {
        // Offscreen, as dd-kit-checks does: SwiftUI builds the accessibility tree only for a window on screen.
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 660, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        w.orderFrontRegardless()
        return w
    }()
    static func host<V: View>(_ view: V) -> NSView {
        let h = NSHostingView(rootView: view.frame(width: 600))
        window.contentView = h
        h.frame = NSRect(x: 0, y: 0, width: 600, height: 620)
        pump(); h.layoutSubtreeIfNeeded(); pump(0.05)
        return h
    }
    static func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) } }
    static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) } }

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        // A. Fixed wording.
        check(DaydreamSetupText.passwordManagers == "Common password managers are skipped. Add others in Settings.",
              "password managers: says common ones are skipped and how to add others")
        check(TrustFooter.text(includePrivateWindows: false) == DaydreamSetupText.passwordManagers, "the trust footer uses the same password manager line")
        // ux/declutter: the status popover's footer is the short form (the long one clipped mid-word at its width). It
        // still says only common ones are skipped (never "never recorded"); setup's permission step keeps the long line.
        check(TrustFooter.shortText == "Common password managers are skipped." && DaydreamSetupText.passwordManagers.hasPrefix(TrustFooter.shortText),
              "the popover's short trust footer keeps 'Common' and is the start of the setup line")
        let popoverSource = (try? String(contentsOfFile: "Sources/MemoryUI/StatusPopover.swift", encoding: .utf8)) ?? ""
        check(popoverSource.contains("TrustFooter(short: true)"), "the status popover draws the short trust footer")
        // Integration: ux/perms and ux/v1 (owner request) made setup's permission step only its two drag cards, so the
        // long line (how to add others) is no longer drawn there; ux/declutter had kept it. The popover's short line
        // stays, and the long one stays the trust footer's text.
        let setupSource = (try? String(contentsOfFile: "Sources/MemoryUI/PermissionSetup.swift", encoding: .utf8)) ?? ""
        check(!setupSource.isEmpty && !setupSource.contains("DaydreamSetupText.passwordManagers") && !setupSource.contains("PrivacyPromise"),
              "setup's permission step is only its cards (owner request): no promise or password manager line")
        check(DaydreamSetupText.fileVault == "Your history isn't encrypted yet. Turn on FileVault.", "FileVault line")
        check(DaydreamSetupText.ownMac == "Use DayDream only to record yourself, on your own Mac account.", "own Mac line")
        // FileVault is read without a prompt or administrator rights: `fdesetup isactive` exits 0 when on, 1 when off.
        check(FileVaultStatus.tool == "/usr/bin/fdesetup" && FileVaultStatus.reading(exitStatus: 0) == true
              && FileVaultStatus.reading(exitStatus: 1) == false && FileVaultStatus.reading(exitStatus: 2) == nil
              && FileVaultStatus.read(tool: "/nonexistent/fdesetup") == nil,
              "FileVault: on, off or unknown from fdesetup isactive; unknown when the tool is missing")
        let cloudTexts = [CloudSummariesText.line, DaydreamSetupText.cloudShort, CloudActivation.disclosure, CloudActivation.destination,
                          PrivacyPromise.sentence, SettingsHubContentFooter.storage, SettingsHubContentFooter.storageFileVaultOff]
        check(cloudTexts.allSatisfy { $0.contains("OpenRouter") }, "cloud summaries: every description names OpenRouter")
        check(CloudSummariesText.line.contains("Zero-retention hosts requested") && CloudSummariesText.zeroRetention == CanonicalCloudWriter.enforcedModeLabel
              && [CloudActivation.disclosure, CloudActivation.destination].allSatisfy { $0.contains("told to use only model hosts that don't keep your data") },
              "cloud summaries: says zero-retention hosts are requested (a request, not a promise), in the note label's words")
        // summaries/v3: the v2 notice (spec §13) says what OpenRouter itself keeps.
        check(CloudActivation.disclosure.hasPrefix("Cloud summaries send what DayDream records, including the words you type when typing is on, through OpenRouter to write your notes.")
              && CloudActivation.disclosure.contains("keeps the text only if logging is on in your OpenRouter account") && CloudActivation.disclosureVersion == 3,
              "cloud notice v2: the words you type go to the summary service; OpenRouter's own logging is named")
        // summaries/v3 (owner 2026-09-27, decision 8 reversed): cloud summaries read the words you type when you chose
        // Cloud. Every description says so, and none says "never the words" about the cloud.
        // summaries/v3 (owner 9/28): no consent sheet, so the switch's one line must say it: the words you type are sent.
        // It fails if the line denies the typed words ("never", "not", "except") or leaves them out.
        // fix/setup-status (owner 9/28): the switch is "Use an OpenRouter key instead", its line says what is sent.
        let line = CloudSummariesText.line
        check(line == "From now on, window titles, page titles and what you type go to OpenRouter. Zero-retention hosts requested."
              && CloudSummariesText.title == "Use an OpenRouter key instead" && DaydreamSetupText.cloudShort == line
              && !line.lowercased().contains("never") && !line.lowercased().contains("not the words") && !line.lowercased().contains("except what you type"),
              "the OpenRouter line says window titles, page titles and typed words are sent, and denies nothing")
        check(["app names", "window titles", "Chrome page titles and sites", "the words you type"].allSatisfy { CloudActivation.disclosure.contains($0) }
              && CloudActivation.disclosure.contains("the words you type") && CloudActivation.disclosure.contains("Chrome page titles and sites (without web addresses or unread counts)")
              && ![DaydreamSetupText.cloudShort, CloudActivation.disclosure, CloudActivation.destination, PrivacyPromise.cloudLimit].contains { $0.contains("never the words") || $0.contains("Never the words") || $0.contains("never get") && $0.contains("words") && !$0.contains("get the words") }
              && ((try? String(contentsOfFile: "Sources/MemoryCore/AssistantView.swift", encoding: .utf8)) ?? "").contains("Chrome page titles and sites (never web addresses), the words the person typed, and the owner's corrections"),
              "cloud summaries: says what is sent, the typed words included")
        // Corrections the person writes to notes go into cloud requests too (adapters/CoreWriterBinding.swift).
        check(CloudActivation.disclosure.contains("corrections you write to notes")
              && ((try? String(contentsOfFile: "adapters/CoreWriterBinding.swift", encoding: .utf8)) ?? "").contains("User correction to related note")
              && ((try? String(contentsOfFile: "Sources/MemoryCore/AssistantView.swift", encoding: .utf8)) ?? "").contains("corrections to notes through OpenRouter"),
              "cloud summaries: the notice says corrections you write to notes are sent")
        check(!CloudActivation.disclosure.contains("never sent") && !CloudActivation.destination.contains("never sent")
              && PrivacyPromise.cloudLimit == "Cloud summaries get window titles, page titles and the words you type.",
              "cloud summaries: the notice says Chrome page titles are sent (fix/sx-all, owner 9/28) and denies nothing")
        for text in cloudTexts + [DaydreamSetupText.localUnavailable] {
            let lower = text.lowercased()
            check(!lower.contains("zero data retention") && !text.contains("ZDR") && !lower.contains("stays on this mac") && !lower.contains("never leaves"),
                  "no overclaim in: " + String(text.prefix(40)))
        }
        check(DaydreamSetupText.localUnavailable.hasPrefix("Not in this version."), "On this Mac, when missing, says it's not in this version")
        // writer/v1: what's missing in a build without it is the runtime, never the model (which downloads on request).
        check(!DaydreamSetupText.localUnavailable.lowercased().contains("model") && !DaydreamSetupText.localUnavailable.lowercased().contains("download"),
              "On this Mac, when missing, doesn't blame the model or the download")

        // B. The summaries page (fix/setup-status, owner 9/28): "Summaries on this Mac" first (only where the build has the
        // runtime), then "Use an OpenRouter key instead" with its one line. One at a time; both off is Off (`later`); the
        // key field shows only while the OpenRouter row is on. No card, sheet or second question.
        check(DaydreamSummaryChoice.allCases.contains(.later), "summaries: both switches off is Off")
        for available in [false, true] {
            var selection = available ? DaydreamSummaryChoice.local : .cloud
            var key = ""
            func render() -> NSView {
                host(DaydreamSummariesContent(choice: Binding(get: { selection }, set: { selection = $0 }), cloudKey: Binding(get: { key }, set: { key = $0 }),
                                              localAvailable: available))
            }
            var view = render()
            var switches = views(NSSwitch.self, in: view)
            check(switches.count == (available ? 2 : 1) && switches.allSatisfy(\.isEnabled) && switches[0].state == .on && switches.dropFirst().allSatisfy { $0.state == .off },
                  "summaries: \(available ? "Summaries on this Mac on, the OpenRouter row off" : "only the OpenRouter row, on"), all usable (available: \(available))")
            check(views(NSSecureTextField.self, in: view).count == (available ? 0 : 1), "summaries: the key field only while the OpenRouter row is on (available: \(available))")
            if available {
                switches[1].performClick(nil); pump()
                check(selection == .cloud, "summaries: the OpenRouter switch turns this Mac off (\(selection))")
                view = render()
                switches = views(NSSwitch.self, in: view)
                check(views(NSSecureTextField.self, in: view).count == 1 && switches[1].state == .on && switches[0].state == .off,
                      "summaries: the OpenRouter row on shows the key field")
                switches[1].performClick(nil); pump()
                check(selection == .later, "summaries: both off is Off (\(selection))")
            }
        }
        var switchBody = ""
        dump(CloudSummariesSwitch(isOn: .constant(false), key: .constant(""), showsKey: false).body, to: &switchBody)
        check(switchBody.contains(CloudSummariesText.line) && switchBody.contains(CloudSummariesText.title),
              "the switch draws its title and the one line (what is sent)")

        // C. The review page: the view's body, dumped, holds the own-Mac notice whatever the rows are, and the
        // FileVault notice only when FileVault reads as off (never a false "isn't encrypted").
        for rows in [[], [DaydreamReviewRow(id: "summaries", title: "Summaries", value: "Off", systemImage: "text.alignleft")]] {
            for off in [false, true] {
                var body = ""
                dump(DaydreamReviewContent(rows: rows, message: rows.isEmpty ? nil : "Fabricated message", fileVaultOff: off).body, to: &body)
                // dump() prints strings as debug text, which escapes the apostrophes.
                func dumped(_ text: String) -> String { String(String(reflecting: text).dropFirst().dropLast()) }
                check(body.contains(dumped(DaydreamSetupText.ownMac)) && body.contains(dumped(DaydreamSetupText.fileVault)) == off,
                      "review: own-Mac notice always, FileVault notice \(off ? "shown when off" : "hidden when on or unknown") (\(rows.count) rows)")
            }
        }
        _ = host(DaydreamReviewContent(rows: []))

        // D. Sources: the app wires these, and no user-facing text overclaims.
        func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
        let onboarding = source("Sources/MacMemApp/DaydreamOnboarding.swift")
        check(onboarding.contains("fileVaultOff = await FileVaultStatus.current() == false") && onboarding.contains("fileVaultOff: fileVaultOff"),
              "setup reads FileVault off the main thread and says it isn't on only when it reads as off")
        // summaries/v3 (owner 9/28): no consent sheet anywhere. Setup and Settings draw the same switch and line; setup turns
        // cloud on at Start Recording and Settings at once, both recording the version-2 notice (the writer refuses
        // without it). Nothing else asks: the Start Recording path has no cloud question.
        let settingsSource = source("Sources/MacMemApp/WriterPreferences.swift")
        let screens = source("Sources/MemoryUI/OnboardingScreens.swift")
        // r2: Settings opens the Cloud summaries switch on the real mode. The production call passes no initialMode (only
        // renders and checks do), so the switch is on, with the key field, only while cloud is on.
        let hostSource = source("Sources/MacMemApp/DaydreamSettings.swift")
        let summariesCall = hostSource.range(of: "case .summaries:").map { String(hostSource[$0.upperBound...].prefix(900)) } ?? ""
        check(summariesCall.contains("WriterPreferences(writer: writer") && !summariesCall.contains("initialMode:")
              && settingsSource.contains("_pendingCloud=State(initialValue:initialMode==Self.cloudMode)") && settingsSource.contains("initialMode:String=\"\""),
              "r2: Settings > Summaries shows Cloud summaries off (no key field) while summaries are off, on every build")
        check(!FileManager.default.fileExists(atPath: "Sources/MemoryUI/CloudConsentSheet.swift")
              && !onboarding.contains("CloudConsentSheet") && !settingsSource.contains("CloudConsentSheet") && !onboarding.contains("cloudReview")
              && !settingsSource.contains(".sheet(") && !onboarding.contains(".sheet("),
              "no cloud consent sheet: setup and Settings have no sheet at all")
        check(screens.contains("CloudSummariesSwitch(isOn:") && settingsSource.contains("CloudSummariesSwitch(isOn:")
              && source("Sources/MemoryUI/CloudSummariesSwitch.swift").contains("Text(CloudSummariesText.line)"),
              "setup and Settings draw the same Cloud summaries switch with its one line")
        // fix/setup-status: setup (at Continue) and Settings (at once) turn it on through the writer's chooseCloud, which
        // records the notice (fix/engine-battery's WriterIntegration.chooseCloud; the setup shim is gone at fix/sx-all).
        let chooser = source("Sources/MacMemApp/WriterIntegration.swift")
        let chooseCloud = chooser.range(of: "func chooseCloud(key").map { String(chooser[$0.lowerBound...].prefix(2600)) } ?? ""
        check(onboarding.contains("await SummaryControls.current.chooseCloud(writer,") && settingsSource.contains("await SummaryControls.current.chooseCloud(writer,")
              && settingsSource.contains("chooseCloud: { await $0.chooseCloud(key: $1) }")
              && chooseCloud.replacingOccurrences(of: " ", with: "").contains("enableCloud(acceptedDisclosureVersion:")
              && chooseCloud.contains("cloudDisclosureVersion)")
              && source("Sources/MacMemApp/WriterIntegration.swift").contains("static let cloudDisclosureVersion=CloudActivation.disclosureVersion")
              && CloudActivation.disclosureVersion == 3,
              "turning the switch on records the version-3 notice, the one that says typed words and page titles are sent")
        // Consent audit 9/28: the switch stays on across relaunches and privacy changes, and a notice-version bump resets
        // it to off without asking. The launch reads the saved key only to turn the saved switch back on.
        let writerSource = source("Sources/MacMemApp/WriterIntegration.swift")
        check(writerSource.contains("guard version==Self.cloudDisclosureVersion else {try? await scheduler.setResumeCloud(nil);return}")
              && writerSource.contains("try await scheduler.setResumeCloud(acceptedDisclosureVersion,cutoff:cutoff)")
              && writerSource.contains("try await scheduler?.setResumeLocal(false);try await scheduler?.setResumeCloud(nil)")
              && writerSource.contains("if provider==\"off\" && !Task.isCancelled {await resumeCloud()}")
              && writerSource.contains("await stopProvider(persistStop:false)\n                    Task { [weak self] in await self?.resumeCloud() }")
              && !writerSource.contains("Cloud requires a new explicit enable"),
              "cloud stays on across a relaunch and a privacy change (current notice only); turning it off, a key change or a new notice clears it")
        // The typed words go to the cloud only under that notice: the app's saved writer is cloud (TypedAccess .cloudWriter).
        check(source("Sources/MemoryCore/TypedAccess.swift").contains("case .cloudWriter: return try typedTextPolicy().readConsented && summaryWriter()?.mode == \"cloud\""),
              "typed words are opened for the cloud writer only while typing is on and cloud summaries are on")
        // Integration: Advanced › Privacy and retention is gone (ux/declutter). The overview's footer says where history is
        // kept and who can send parts of it out, with Learn more to PRIVACY.md; the cloud limit is in the notice shown
        // before cloud summaries turn on (checked in A).
        check(source("Sources/MacMemApp/DaydreamSettings.swift").contains("learnMore: { NSWorkspace.shared.open(PrivacyPromise.policyURL) }")
              && PrivacyPromise.policyURL.absoluteString.hasSuffix("/PRIVACY.md")
              && source("Sources/MemoryUI/SettingsHub.swift").contains("let line = Self.footer(fileVaultOn: fileVaultOn)"),
              "Settings says where history is kept and who can send it out, with Learn more to PRIVACY.md")
        // fix/setup-status: On this Mac is shown only where the build has it, and is the default only on a Mac that runs it.
        check(onboarding.contains("localAvailable: writer.localOffered") && onboarding.contains("return localOffered && qualifies ? .local : .cloud")
              && onboarding.contains("if SummaryPhaseReading.localOn(phase) && localOffered { return .local }"),
              "setup: On this Mac only where this build has it, the default only on a Mac that can run it")
        let integration = source("Sources/MacMemApp/WriterIntegration.swift")
        check(integration.contains("guard localOffered else") && integration.contains("status=DaydreamSetupText.localUnavailable")
              && integration.contains("statusStore?.setSummaryWriter(provider)"),
              "summaries: setup is refused in a build without the runtime, and the mode is reported to AI apps")
        let settings = source("Sources/MacMemApp/WriterPreferences.swift")
        // fix/setup-status: Settings › Summarizer is one switch per way (the local row only where the build has it) and one
        // state line; no Download or Turn on button, and a certificate check that failed is one plain line with Try Again.
        check(settings.contains("if writer.localOffered {") && settings.contains("CloudSummariesSwitch(") && settings.contains("DaydreamSummariesContent.localTitle"),
              "Settings › Summarizer uses the same switches and wording as setup")
        check(!settings.contains("\"Download\"") && !settings.contains("\"Turn on\"") && settings.contains("private var localLine:String? {localOn ? phase.line ?? (writer.retryWaitsForPower && phase == .on(.local) ? Self.waitsForPowerLine:nil):nil}"),
              "Settings: no Download or Turn on button; the local row's only line is the state's own (or, on, that a retry waits for power)")
        check(SummaryProblem.appleCheck.line == "DayDream couldn't check its signature with Apple." && SummaryProblem.appleCheck.button == "Try Again"
              && integration.contains("static let appleCheckLine=\"On this Mac is off until DayDream checks its signature with Apple.\""),
              "Settings: a failed certificate check shows one plain line and Try Again")
        check(RuntimeTrustProvisioning.disclosure == "Checking DayDream's signature with Apple. Nothing from your history is sent.",
              "the certificate check says what it does in plain words")
        // WriterStatusText's `s.hasPrefix(...)`/`s.contains(...)` lines match the writer's own strings to rewrite them; those
        // inputs are never shown, so they are left out (they made this check fail on the base, 621ac09).
        let shownSettings = settings.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("s.hasPrefix(") && !$0.contains("s.contains(") }.joined(separator: "\n")
        let shownWriterText = integration + shownSettings + source("Sources/MemoryUI/OnboardingScreens.swift")
        let stale = ["compatible verified runtime", "fresh evidence", "Signed local assets", "Verified assets", "Writer setup unavailable",
                     "Automatic notes are OFF", "Model names are candidates", "macOS 26", "doesn't include the model", "certificate authorities"]
        check(stale.allSatisfy { !shownWriterText.contains($0) } && !RuntimeTrustProvisioning.disclosure.contains("certificate authorities"),
              "no jargon or untrue writer status left: " + stale.filter { shownWriterText.contains($0) }.joined(separator: ", "))
        // writer/v2: summaries on this Mac read typed words while typing is on (one binding made for the local
        // writer); the cloud writer always takes the cloud-audience port, which never opens them. The Typing
        // card's one line says exactly that.
        let app = ((try? FileManager.default.contentsOfDirectory(atPath: "Sources/MacMemApp")) ?? []).filter { $0.hasSuffix(".swift") }
            .map { source("Sources/MacMemApp/" + $0) }.joined(separator: "\n")
        check(integration.contains("coreBinding=Self.makeCoreBinding(store:store)") && integration.contains("CoreWriterBinding(store:store,typedWriter:.local)")
              && app.components(separatedBy: "CoreWriterBinding(").count == 2 && app.components(separatedBy: "coreBinding.port(").count == 4
              && integration.contains("port=coreBinding.port()") && integration.contains("port=coreBinding.port(audience:.cloud)")
              // fix/sx-all round 2: the code pass (summaries off) writes code notes on this Mac through the local port.
              && integration.contains("let adapter=CoreWriterAdapter(core:coreBinding.port(),generate:{request,actions in"),
              "summaries on this Mac get the typed-words reader; the cloud writer only ever gets the cloud-audience port")
        check(TypingSettingsText.bullets.contains("Summaries read the words, so a note can say what a message was about. With an OpenRouter key, they're sent to OpenRouter to write your notes.")
              && !source("Sources/MemoryUI/TypingSettings.swift").contains("summariesNote"),
              "typing consent: one bullet says summaries read the words and, with an OpenRouter key, send them to OpenRouter; no line on the card")
        var overclaims: [String] = []
        for dir in ["Sources/MemoryUI", "Sources/MacMemApp", "Sources/MemoryCore", "WriterBackend/Sources/WriterBackend"] {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".swift") {
                for (n, line) in source(dir + "/" + file).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let code = line.components(separatedBy: "//").first ?? ""
                    // Quoted text only: identifiers such as `processedUsingZDR` are not user-facing.
                    for quoted in code.components(separatedBy: "\"").enumerated().filter({ $0.offset % 2 == 1 }).map(\.element) {
                        let lower = quoted.lowercased()
                        if lower.contains("stays on this mac") || lower.contains("zero data retention") || quoted.contains("Processed Using ZDR") {
                            overclaims.append("\(dir)/\(file):\(n + 1): \(quoted)")
                        }
                    }
                }
            }
        }
        // The note label in the writer's own contract is internal (never shown); every shown status was rewritten.
        overclaims.removeAll { $0.hasPrefix("WriterBackend/Sources/WriterBackend/Contract.swift") || $0.hasPrefix("WriterBackend/Sources/WriterBackend/CanonicalNotes.swift") }
        check(overclaims.isEmpty, "no shown text says stays on this Mac or zero data retention: " + overclaims.joined(separator: "; "))

        // E. The visible line against the sent payload (stub transport, no network, no Keychain).
        let sem = DispatchSemaphore(value: 0)
        let box = PayloadResults()
        Task.detached { box.set(await CloudPayloadProbe.run()); sem.signal() }
        sem.wait()
        for (ok, name) in box.value { check(ok, name) }
        print("\(passed) honesty UI checks passed. Offscreen views only.")
    }
}

/// The Settings footer line, read through the public view type.
enum SettingsHubContentFooter {
    static let storage = DaydreamSettingsOverview.storageFooter
    static let storageFileVaultOff = DaydreamSettingsOverview.storageFooterFileVaultOff
}

final class PayloadResults: @unchecked Sendable {
    private let lock = NSLock(); private var results: [(Bool, String)] = []
    func set(_ value: [(Bool, String)]) { lock.lock(); results = value; lock.unlock() }
    var value: [(Bool, String)] { lock.lock(); defer { lock.unlock() }; return results }
}

/// E: CloudWriter's real request, captured by a stub transport. The typed words and the website typing row are what
/// CoreWriterBinding hands the cloud writer (words in the description, the website row's place is the site alone).
enum CloudPayloadProbe {
    actor Keys: WriterSecureKeyStore {
        var value = ""
        func readSecret() async throws -> String { value }
        func saveSecret(_ input: String) async throws { value = input }
        func removeSecret() async throws { value = "" }
    }
    final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var date = Date(timeIntervalSince1970: 1_900_000_000)
        func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance() { lock.lock(); date = date.addingTimeInterval(60); lock.unlock() }
    }
    final class Wire: @unchecked Sendable {
        private let lock = NSLock(); private var bodies: [Data] = []
        func send(_ request: URLRequest) -> CloudHTTPResponse {
            lock.lock(); bodies.append(request.httpBody ?? Data()); lock.unlock()
            // Any reply: only what was sent matters here (a reply the grounding refuses is fine). Not a 5xx: those are
            // tried again (fix/sx-engine-battery), and this counts the requests one note makes.
            return CloudHTTPResponse(status: 200, body: Data("{}".utf8))
        }
        var sent: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
    }
    static let typedWords = "ask Dana to move the budget review to Thursday"
    static let webWords = "ship the launch checklist tonight"
    static let site = "docs.example.com"

    static func request(at date: Date) throws -> CanonicalNoteRequest {
        let at = ISO8601DateFormatter().string(from: date)
        func action(_ id: String, app: String, site: String, title: String, description: String) -> [String: String] {
            ["id": id, "at": at, "kind": "keyboard.text_input", "app": app, "site": site, "title": title, "description": description, "state": "draft", "revision": "1"]
        }
        let actions = [action("typed-app", app: "Notes", site: "", title: "Budget", description: "Typed a draft in Notes. " + typedWords),
                       action("typed-web", app: "Google Chrome", site: site, title: site, description: "Typed a draft in Google Chrome. " + webWords)]
        let json: [String: Any] = ["id": "req", "schemaVersion": 1, "targetKind": "activity", "targetID": "act", "day": "2030-03-17", "timezone": "UTC",
                                   "inputRevision": "1", "policyRevision": "p1", "expiresAt": "2099-01-01T00:00:00Z", "actions": actions, "actionCount": actions.count]
        return try JSONDecoder().decode(CanonicalNoteRequest.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func run() async -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        var stage = "payload"
        do {
            let clock = Clock(), keys = Keys(), wire = Wire()
            let activation = CloudActivation(store: keys, now: { clock.read() })
            func attempt() async throws {
                let bindings = await activation.bindings()
                let writer = CanonicalCloudWriter(consent: bindings.consent, key: bindings.key, policy: bindings.permits, send: { wire.send($0) })
                let req = try request(at: clock.read())
                _ = try? await writer.generate(req, completeActions: req.actions)
            }
            // Switch off: nothing is sent, even with a key saved.
            clock.advance(); try await attempt()
            try await activation.pasteKey("synthetic-only-key")
            clock.advance(); try await attempt()
            out.append((wire.sent.isEmpty, "E: switch off (no key, then a key saved): nothing is sent"))
            // The old version-1 notice (it said typed words never go) can't turn cloud on.
            var refused = false
            do { try await activation.enable(acceptedDisclosureVersion: 1, currentPolicyRevision: "p1") } catch { refused = true }
            clock.advance(); try await attempt()
            out.append((refused && wire.sent.isEmpty, "E: the version-1 notice is refused and still nothing is sent"))
            // The switch on: the app records the version-2 notice (WriterIntegration.enableCloud).
            try await activation.enable(acceptedDisclosureVersion: CloudActivation.disclosureVersion, currentPolicyRevision: "p1")
            clock.advance(); try await attempt()
            let bodies = wire.sent
            out.append((bodies.count == 1, "E: switch on with the current notice: one request is sent (\(bodies.count))"))
            let json = bodies.first.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let user = ((json["messages"] as? [[String: String]]) ?? []).last?["content"] ?? ""
            let provider = json["provider"] as? [String: Any] ?? [:]
            out.append((user.contains(typedWords) && user.contains(webWords), "E: the sent body holds the words typed in an app and on a website"))
            out.append((user.contains(site), "E: the website typing is sent with its site name"))
            out.append((provider["zdr"] as? Bool == true && provider["data_collection"] as? String == "deny",
                        "E: the request asks for zero-retention hosts (zdr, data_collection deny), as the line says"))
            // What the person reads matches: the line says typed words are sent, and they were.
            let line = CloudSummariesText.line
            out.append((line.contains("what you type") == user.contains(typedWords) && line.contains(CloudSummariesText.zeroRetention),
                        "E: the visible line's claim (typed words included, zero-retention requested) matches the payload"))
            // The switch off again: nothing more.
            await activation.disable()
            clock.advance(); try await attempt()
            out.append((wire.sent.count == 1, "E: switch off again: nothing more is sent (\(wire.sent.count))"))

            // The switch stays on across a relaunch for this notice only (consent audit 9/28): the ledger keeps the version.
            let tmp = realpath(FileManager.default.temporaryDirectory.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? NSTemporaryDirectory()
            let dir = URL(fileURLWithPath: tmp, isDirectory: true).appendingPathComponent("honesty-resume-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("pending-v1.json")
            stage = "first open"
            do { let first = try PendingNoteScheduler(file: file); stage = "save"; try await first.setResumeCloud(CloudActivation.disclosureVersion) }
            stage = "reopen"
            let reopened = try PendingNoteScheduler(file: file)
            let kept = await reopened.resumeCloudPreference()
            try await reopened.setResumeCloud(nil)
            let cleared = await reopened.resumeCloudPreference()
            out.append((kept == CloudActivation.disclosureVersion && cleared == nil, "E: the Cloud summaries switch's notice version survives a relaunch, and off clears it"))
        } catch {
            out.append((false, "E: payload probe threw \(error) at \(stage)"))
        }
        return out
    }
}
