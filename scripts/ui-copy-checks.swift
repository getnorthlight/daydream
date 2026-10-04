// DD-RECIPE: APP
// ui-copy (golden test 5): the words and routes a person sees when recording stops, and the Report a Problem log.
// Pure functions, the app's own statics and source scans only. No MemoryViewModel is built (its launch wiring reaches
// the Keychain), and nothing records, prompts, relaunches or opens a window.
//   G11      every reason the sources can write into the capture session has a plain-words line; a Start that
//            couldn't reach the keyboard and mouse says so once, and Resume goes to the one button that fixes it.
//   G37/G67  the orange attention line and Review… open the Settings page that fixes the problem, and say which.
//   G38      the Settings card's Open Apps to remember matches the words the app sets.
//   G50      Report a Problem keeps every kind of line for hours: status churn is coalesced, no kind crowds out another.
//   G66      the Settings card never reads "Paused · By you" or "Paused · For an update.".
//   G68      every setup page whose Continue waits for Stop says why.
//   G69      the permission window stops floating once another app is in front.
//   R2-1     (gold/r2-copy-checks) every operational issue the app can raise, found in its sources, reaches the menu bar,
//            the status popover, the toolbar gear and the Settings card in its own plain words, with the one button that
//            fixes it (the same in each place), and clears by itself.
//   R2-2     every recording notice, for every stop cause and state: plain words, the state the menu bar shows (never
//            "stopped" beside Paused), and a control the menu bar panel really has, enabled, in that state.
//   R2-3     a restore preview after a repair that couldn't read back every deletion says why fewer actions are added.
// -D BASE_SHIM leaves out what needs this stream's new symbols, so the behavioural parts also run on a tree without
// them (the base, a6944d3) and print their FAIL lines there.
// Run from the tree's root (the source scans read Sources/), or set DD_SRC_ROOT.
import AppKit
import Foundation
import MemoryCore
import MemoryUI

@MainActor @main enum UICopyChecks {
    static var failures = 0
    static var passes = 0
    static func check(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        if ok { passes += 1; print("PASS " + name) } else {
            failures += 1
            print("FAIL: " + name + (got().isEmpty ? "" : " (got: " + got() + ")"))
        }
        fflush(stdout)
    }
    static func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) { check(got == want, name, "\(got)") }

    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let zone = TimeZone(identifier: "America/Los_Angeles")!

    static func main() {
        reasonBranchChecks()
        reasonScan()
        inputUnreachable()
        attentionRoutes()
        choicesUnsaved()
        cardPauseLines()
        reportLog()
        setupWhileRecording()
        permissionWindow()
        issueLines()
        noticeLines()
        restorePreviewLine()
        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: sources

    static let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DD_SRC_ROOT"] ?? FileManager.default.currentDirectoryPath)
    static func source(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    static func swiftFiles(_ dir: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)) ?? []
        return names.filter { $0.hasSuffix(".swift") }.sorted().map { dir + "/" + $0 }
    }
    /// The file without comment lines (a doc comment may quote a call).
    static func code(_ path: String) -> [String] {
        source(path).components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }
    /// Exclude only a branch whose explicit conjunction requires the private QA flag.
    /// Unknown expressions, negative guards and alternate branches stay in the production scan.
    /// This is deliberately not a Swift preprocessor: ambiguous lexical input or nesting keeps all lines.
    static func productionReasonLines(_ text: String) -> [String] {
        let original = text.components(separatedBy: "\n")
        // A directive-looking line could be literal/comment content; keep the existing scan in that case.
        guard !text.contains("\"\"\""), !text.contains("/*") else { return original }
        func qaOnly(_ condition: String) -> Bool {
            let terms = condition.components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespaces) }
            return terms.contains("DAYDREAM_QA_HARNESS") && terms.allSatisfy {
                $0.range(of: #"^!?[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
            }
        }
        var frames: [(qaOnly: Bool, sawElse: Bool)] = [], kept: [String] = []
        for line in original {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            let directive = parts.first.map(String.init) ?? ""
            switch directive {
            case "#if":
                guard parts.count == 2 else { return original }
                frames.append((qaOnly(String(parts[1])), false))
            case "#elseif":
                guard parts.count == 2, let frame = frames.last, !frame.sawElse else { return original }
                frames[frames.count - 1].qaOnly = qaOnly(String(parts[1]))
            case "#else":
                guard parts.count == 1, let frame = frames.last, !frame.sawElse else { return original }
                frames[frames.count - 1] = (false, true)
            case "#endif":
                guard parts.count == 1, !frames.isEmpty else { return original }
                frames.removeLast()
            default:
                kept.append(frames.contains(where: { $0.qaOnly }) ? "" : line)
                continue
            }
            kept.append("")
        }
        return frames.isEmpty ? kept : original
    }
    static func reasonCode(_ path: String) -> [String] {
        productionReasonLines(source(path)).map {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : $0
        }
    }
    static func reasonBranchChecks() {
        let qa = "#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING\nqa\n#else\nproduction\n#endif"
        check(productionReasonLines(qa).joined().contains("production") && !productionReasonLines(qa).joined().contains("qa"),
              "G11 reason scan excludes only the explicitly positive QA branch")
        for condition in ["!DAYDREAM_QA_HARNESS", "DAYDREAM_QA_HARNESS || PRODUCT", "(DAYDREAM_QA_HARNESS)", "DAYDREAM_OWNER_TYPING"] {
            check(productionReasonLines("#if " + condition + "\nproduction\n#endif").contains("production"),
                  "G11 reason scan keeps unknown or non-QA-only condition: " + condition)
        }
        let alternate = "#if PRODUCT\none\n#elseif DAYDREAM_QA_HARNESS\nqa\n#elseif OTHER\ntwo\n#else\nthree\n#endif"
        let lines = productionReasonLines(alternate)
        check(lines.contains("one") && lines.contains("two") && lines.contains("three") && !lines.contains("qa"),
              "G11 reason scan retains every non-QA alternate branch")
        let nested = "#if DAYDREAM_QA_HARNESS\n#if OTHER\nqa\n#else\nqaAlternate\n#endif\n#endif\nproduction"
        check(productionReasonLines(nested).contains("production") && !productionReasonLines(nested).contains("qaAlternate"),
              "G11 reason scan excludes nested content only under an explicit positive QA guard")
        for ambiguous in ["#if DAYDREAM_QA_HARNESS\nproduction", "#else\nproduction", "#if DAYDREAM_QA_HARNESS\n#else\n#else\nproduction\n#endif",
                          "\"\"\"\n#if DAYDREAM_QA_HARNESS\nproduction\n#endif\n\"\"\"", "/*\n#if DAYDREAM_QA_HARNESS\nproduction\n#endif\n*/"] {
            check(productionReasonLines(ambiguous) == ambiguous.components(separatedBy: "\n"),
                  "G11 reason scan keeps all lines for ambiguous literals, comments or directives")
        }
    }

    static func groups(_ pattern: String, _ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
    /// The text of a block that starts at `start` and ends at the first `end` after it.
    static func block(_ text: String, from start: String, to end: String) -> String {
        guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex) else { return "" }
        return String(text[a.lowerBound..<b.upperBound])
    }
    /// The first argument of each call `name(` on `line` (up to its top-level comma or closing parenthesis).
    static func firstArguments(_ name: String, _ line: String) -> [String] {
        var found: [String] = []
        var search = line.startIndex
        while let r = line.range(of: name + "(", range: search..<line.endIndex) {
            search = r.upperBound
            if r.lowerBound > line.startIndex {
                let before = line[line.index(before: r.lowerBound)]
                if before.isLetter || before.isNumber || before == "_" { continue }
            }
            var depth = 0, arg = ""
            for ch in line[r.upperBound...] {
                if ch == "(" || ch == "[" { depth += 1 }
                if ch == ")" || ch == "]" { if depth == 0 { break }; depth -= 1 }
                if ch == "," && depth == 0 { break }
                arg.append(ch)
            }
            found.append(arg.trimmingCharacters(in: .whitespaces))
        }
        return found
    }

    static let literal = #""((?:[^"\\]|\\.)*)""#

    /// Every reason the app and core can write into the capture session: literals passed to a pause, a stop or a
    /// finish, default reasons, the session's own reasons, the named reasons (CaptureFault, WakeResume, the
    /// coordinator), the sleep/lock/user-switch reasons and the older-collector blocker.
    static func sessionReasons() -> (reasons: Set<String>, unresolved: [String]) {
        var reasons = Set<String>(), unresolved: [String] = []
        // Arguments that aren't literals, each resolved below to the literals it can carry.
        let resolved: Set<String> = [
            "reason", "why",                                        // passed through from a caller scanned here
            "blocker",                                              // InstallationReview.captureBlocker
            "CaptureFault.retryReason",                             // CaptureFault's static reasons
            "storageFull ? CaptureFault.fullReason : Self.storageRetryReason",
            "RecordingStopCause.notResumedReason",                  // WakeResume's static reasons
            "suspension.pauseReason", "suspension", "let suspension", "WakeSuspension", // WakeSuspension.pauseReason
        ]
        for path in swiftFiles("Sources/MacMemApp") + swiftFiles("Sources/MemoryCore") {
            let lines = reasonCode(path)
            for (n, line) in lines.enumerated() {
                for m in groups(#"\b(?:pause|pauseCapture)\(\s*"# + literal, line) { reasons.insert(m) }
                for m in groups(#"\b(?:stop|finish)\(\s*reason:\s*"# + literal, line) { reasons.insert(m) }
                for m in groups(#"func (?:pause|pauseCapture)\(_ \w+: String = "# + literal, line) { reasons.insert(m) }
                if line.contains("func pause") || line.contains("func finish") || line.contains("func stop") { continue }
                for name in ["pause", "pauseCapture"] {
                    for arg in firstArguments(name, line) where !arg.isEmpty && !arg.hasPrefix("\"") {
                        if !resolved.contains(arg) { unresolved.append("\(path):\(n + 1) \(name)(\(arg))") }
                    }
                }
                for name in ["stop", "finish"] {
                    for arg in firstArguments(name, line) where arg.hasPrefix("reason:") {
                        let value = arg.dropFirst("reason:".count).trimmingCharacters(in: .whitespaces)
                        if !value.hasPrefix("\"") && !resolved.contains(value) { unresolved.append("\(path):\(n + 1) \(name)(reason: \(value))") }
                    }
                }
            }
        }
        // The session's own reasons: every literal on a line that sets `reason` (a condition's other branch included).
        for line in reasonCode("Sources/MemoryCore/CaptureSession.swift") {
            guard let set = line.range(of: #"\breason\s*=[^=]"#, options: .regularExpression) else { continue }
            let statement = line[set.lowerBound...].prefix { $0 != ";" }
            groups(literal, String(statement)).forEach { reasons.insert($0) }
        }
        for path in ["Sources/MemoryCore/CaptureFault.swift", "Sources/MacMemApp/WakeResume.swift", "Sources/MacMemApp/Coordinator.swift"] {
            groups(#"static let \w*[Rr]eason\s*=\s*"# + literal, reasonCode(path).joined(separator: "\n")).forEach { reasons.insert($0) }
        }
        let wake = reasonCode("Sources/MacMemApp/WakeResume.swift").joined(separator: "\n")
        groups(literal, block(wake, from: "var pauseReason: String {", to: "\n    }")).forEach { reasons.insert($0) }
        // Every reason the stop-cause rules name (a person's own, the storage ones).
        for set in ["static let personReasons", "static let storageReasons", "static let resumesByItself"] {
            groups(literal, block(wake, from: set, to: "]")).forEach { reasons.insert($0) }
        }
        groups(#"requiresMigration \? "# + literal, source("Sources/MemoryCore/InstallationReview.swift")).forEach { reasons.insert($0) }
        return (reasons, unresolved)
    }

    /// Words that belong to the code, not to a person.
    static let engineering = ["explicitly", "capture", "event tap", "input tap", "footprint", "legacy", "collector",
                              "persisted", "durable", "proof", "prerequisite", "session", "restart never",
                              "no recording started", "quit", "reopen", "off next time", "rollback", "uninstall",
                              "resolve", "preference", "unavailable"]
    static func engineeringWords(_ line: String) -> [String] {
        let lower = line.lowercased()
        return engineering.filter { lower.contains($0) }
    }

    // MARK: G11

    static func reasonScan() {
        let (reasons, unresolved) = sessionReasons()
        check(reasons.count >= 30, "G11 the scan finds the session reasons (\(reasons.count))", reasons.sorted().joined(separator: " | "))
        for must in ["Input event tap unavailable. No recording started.", "Recording stopped", "Paused for uninstall",
                     "Paused for explicit rollback", "Resolve replacement or rollback before recording.",
                     "Stopped by you. Resume explicitly.", "Paused for screen lock. Resumes after unlock.",
                     // gold/int: lifecycle's CaptureSession starts at "Recording is off." (it was "Start recording explicitly.
                     // Restart never resumes capture."); the older words keep their plain line in RecordingCopy.
                     "Storage write failed. Retrying automatically.", "Recording is off."] {
            check(reasons.contains(must), "G11 the scan finds \"\(must)\"")
        }
        check(unresolved.isEmpty, "G11 every reason passed to a pause or stop is a literal or a known named reason",
              unresolved.joined(separator: " | "))
        let details = Set(RecordingCopy.pauseDetails)
        for reason in reasons.sorted() {
            let ui = RecordingCopy.pauseReason(reason) ?? ""
            check(ui != reason || reason == "Paused by you", "G11 \"\(reason)\" has its own words", ui)
            check(details.contains(ui), "G11 \"\(reason)\" → a line the menu fit checks cover (RecordingCopy.pauseDetails)", ui)
            check(engineeringWords(ui).isEmpty, "G11 \"\(reason)\" → \"\(ui)\": no engineering words", engineeringWords(ui).joined(separator: ", "))
            check(!ui.hasPrefix("Paused ") || ui == "Paused by you" || ui.hasPrefix("Paused while ") || ui.hasPrefix("Paused until "),
                  "G11/G66 \"\(ui)\": a Paused line is Paused by you, Paused while … or Paused until …")
            let state = RecordingState.derive(RecordingStateInputs(stopped: false, sessionState: "paused", sessionReason: reason))
            let header = MenuBarMenu.header(CapturePresentation(state: state, canResume: true, canStop: true), now: now, timeZone: zone,
                                            canSetUp: true, canOpenApplications: true)
            let spoken = header.status.text + " " + (header.status.detail ?? "")
            check(engineeringWords(spoken).isEmpty, "G11 menu bar for \"\(reason)\": \(header.status.text)", spoken)
            let card = SettingsStatusCardModel(SettingsStatusSnapshot(state: state, canResume: true), calendar: calendar, now: now)
            check(card.stateLine.range(of: #"· (By|For|Paused) "#, options: .regularExpression) == nil && engineeringWords(card.stateLine).isEmpty,
                  "G11/G66 Settings card for \"\(reason)\": \(card.stateLine)")
        }
        // The same words wherever an issue line is built from a pause reason.
        equal(RecordingCopy.issue("Paused for update. Start recording explicitly after restart."), "Paused while DayDream updates.",
              "G11 the update pause: Paused while DayDream updates.")
    }

    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c }

    /// A Start that couldn't install its event tap: one line that says so, no second orange line, and Resume goes to
    /// setup's Permissions page, whose one button is Quit & Reopen.
    static func inputUnreachable() {
        let tap = "Input event tap unavailable. No recording started."
        let words = "Keyboard and mouse aren't reaching DayDream."
        let state = RecordingState.derive(RecordingStateInputs(stopped: false, sessionState: "paused", sessionReason: tap,
                                                                operationalIssue: "Input capture needs attention"))
        equal(state, .paused(until: nil, since: nil, reason: words), "G11 a failed tap: Paused · \(words)")
        let p = CapturePresentation(state: state, issue: "Input capture needs attention", canResume: true, canStop: true)
        equal(p.attentionLine(now: now, timeZone: zone), nil, "G11 a failed tap: one line, no orange line repeating it")
        let h = MenuBarMenu.header(p, now: now, timeZone: zone, canSetUp: true, canOpenApplications: true)
        equal(h.status.text, "Paused · can't see keys or clicks", "G11 a failed tap in the menu bar: one short line")
        equal(h.status.detail, words, "G11 a failed tap in the menu bar: the whole sentence as its detail")
        let card = SettingsStatusCardModel(SettingsStatusSnapshot(state: state, issue: "Input capture needs attention", canResume: true),
                                           calendar: calendar, now: now)
        equal(card.stateLine, "Paused · " + words, "G11 a failed tap in Settings: the state line")
        equal(card.attention, nil, "G11 a failed tap in Settings: no second line")
        equal(card.button, SettingsStatusButton("Resume Recording", .resume), "G11 a failed tap in Settings: Resume Recording")
        // A tap macOS turned off while recording starts again with Resume: its own line, no reopen.
        let lost = RecordingState.derive(RecordingStateInputs(stopped: false, sessionState: "paused",
                                                               sessionReason: "Input tap was disabled. Resume explicitly."))
        equal(lost, .paused(until: nil, since: nil, reason: "Keyboard and mouse input was interrupted. Resume when you're ready."),
              "G11 a tap turned off while recording: interrupted, Resume")
        // Every Resume and Start goes through setupStepForStart, which sends a failed tap to the Permissions page.
        let app = source("Sources/MacMemApp/MacMemApp.swift")
        let step = block(app, from: "func setupStepForStart(permission:Bool=true)", to: "\n    }")
        check(step.contains("if !permitted || inputNeedsReopen {return .permissions}"),
              "G11 Start and Resume after a failed tap go to setup's Permissions page", step)
        // gold r2 (ADV-8): a history still opening is tried first, so the setup question is asked of the opened history.
        let request = block(app, from: "func requestStart(openSetup:()->Void) {", to: "\n    }")
        check(request.contains("guard let step=setupStepForStart() else {startCapture();return}")
              && request.components(separatedBy: "startCapture()").count == 2, "G11 requestStart asks setupStepForStart before it starts")
        check(source("Sources/MacMemApp/MenuBarContent.swift").contains("resume: { model.requestStart {")
              && source("Sources/MacMemApp/DaydreamSettings.swift").contains("case .start, .resume: model.requestStart")
              && app.contains("resume:{ [weak self] in self?.requestStart(openSetup:{}) }"),
              "G11 the menu bar, the Settings card and the toolbar Resume all go through requestStart")
        let onboarding = source("Sources/MacMemApp/DaydreamOnboarding.swift")
        check(onboarding.contains("inputNeedsReopen: model.inputNeedsReopen"),
              "G11 setup's Permissions page turns its button into Quit & Reopen after a failed tap")
        check(onboarding.contains("if relaunchPending && (page == .permissions || page == .review) { return PermissionRequestActions.quitAndReopenTitle }"),
              "G11 the page's one button is Quit & Reopen while a reopen is pending")
        check(onboarding.contains("error = model.inputNeedsReopen ? RecordingCopy.inputUnreachable : issue.localizedDescription"),
              "G11 setup's Start says the keyboard and mouse can't reach DayDream")
        let startError = DaydreamOnboardingStartError.captureDidNotStart.localizedDescription
        check(!startError.lowercased().contains("requirements") && engineeringWords(startError).isEmpty,
              "G11/G67 a Start that didn't begin: no page that doesn't exist", startError)
        // The Permissions page waits (it never moves on by itself while a reopen is pending).
        var route = DaydreamOnboardingRoute(afterPermissions: .review)
        route.permissionsChanged(accessibility: true, inputMonitoring: true, relaunchPending: true)
        equal(route.page, .permissions, "G11 the Permissions page stays while Quit & Reopen is its button")
        #if !BASE_SHIM
        check(MemoryViewModel.inputNeedsReopen(state: "paused", reason: tap, canReopen: true),
              "G11 a failed tap needs a reopen")
        check(!MemoryViewModel.inputNeedsReopen(state: "paused", reason: tap, canReopen: false),
              "G11 never where DayDream can't reopen itself (a development binary)")
        check(!MemoryViewModel.inputNeedsReopen(state: "paused", reason: "Input tap was disabled. Resume explicitly.", canReopen: true)
              && !MemoryViewModel.inputNeedsReopen(state: "paused", reason: "Paused by you", canReopen: true)
              && !MemoryViewModel.inputNeedsReopen(state: "recording", reason: tap, canReopen: true)
              && !MemoryViewModel.inputNeedsReopen(state: "off", reason: tap, canReopen: true),
              "G11 only a paused failed tap needs a reopen")
        func pending(_ needs: Bool, im: Bool = true, ax: Bool = true, reopen: Bool = true, atLaunch: Bool? = true) -> Bool {
            DaydreamOnboarding.relaunchPending(available: true, accessibility: ax, inputMonitoring: im, canReopen: reopen,
                                               inputMonitoringAtLaunch: atLaunch, inputNeedsReopen: needs)
        }
        check(pending(true), "G11 after a failed tap, Quit & Reopen is the page's one button")
        check(!pending(false), "G11 without a failed tap nothing changes (Input Monitoring was on at launch)")
        check(pending(false, atLaunch: false), "G11 Input Monitoring turned on while open still asks for the reopen")
        check(!pending(true, reopen: false) && !pending(true, ax: false) && !pending(true, im: false),
              "G11 no Quit & Reopen where it can't help (no bundle, a permission still off)")
        equal(RecordingCopy.inputUnreachable, words, "G11 RecordingCopy.inputUnreachable")
        check(RecordingCopy.pauseDetails.allSatisfy { !$0.contains("Quit") && !$0.lowercased().contains("reopen") },
              "G11 no pause line tells the person to quit and reopen (the button does it)")
        #endif
    }

    // MARK: G37 / G67

    static func attentionRoutes() {
        // gold/r2-copy-checks: the summary writer's and a failed deletion's lines no longer open a page (Summaries can't
        // fix the upkeep; nothing could fix a deletion): they end in Try Again. R2-1 covers every issue's words and button.
        let routes: [(String, String)] = [
            ("Keyboard and mouse recording needs attention", "General"),
            ("Keyboard and mouse need attention", "General"),
            ("Your app choices didn't save", "Apps to remember"),
            ("Finish history operation before recording", "Advanced"),
            ("Review the replacement in Settings before recording.", "Advanced"),
            ("Some history couldn't be read", "Backup"),
            ("Memory read failed", "General"),
        ]
        for (line, section) in routes {
            equal(MenuBarMenu.attentionSection(line), section, "G37 the orange line \"\(line)\" opens \(section)")
        }
        // Every issue the app model can raise reaches a page that deals with it: Advanced only for history, backup or
        // replacement work (Advanced holds Import, Backup and the replacement controls, nothing else that fixes).
        let app = source("Sources/MacMemApp/MacMemApp.swift")
        // gold/int: lifecycle names its issues (operationalIssue=Self.summaryIssue, Self.deletionIssue,
        // Self.choicesUnsavedIssue = RecordingCopy.choicesUnsaved), and moved "Input capture needs attention" and
        // "Finish history operation before recording" out of operationalIssue (the tap and the running operation
        // now pause with their own reason), so the scan resolves the named issues and expects at least three.
        var issues = Set(groups(#"operationalIssue\s*=\s*"# + literal, app))
        for name in groups(#"operationalIssue\s*=\s*Self\.(\w+)"#, app) {
            let named = groups(#"static let "# + name + #"\s*=\s*"# + literal, app)
            if let value = named.first { issues.insert(value) }
            else if app.contains("static let \(name)=RecordingCopy.choicesUnsaved") { issues.insert(RecordingCopy.choicesUnsaved) }
            else { check(false, "G37 the named issue Self.\(name) resolves to its words") }
        }
        check(issues.count >= 3, "G37 the scan finds the app's issues (\(issues.count))", issues.sorted().joined(separator: " | "))
        let expected: [String: DaydreamSettingsPage] = [
            "Input capture needs attention": .overview,
            "Finish history operation before recording": .advanced,
            "Your app choices didn't save": .apps,
        ]
        // The history upkeep and a failed deletion end in Try Again, not a page (R2-1).
        let retried: Set<String> = ["Summary writer needs attention", "Deletion failed"]
        for issue in issues.union(["Your app choices didn't save"]).subtracting(retried).sorted() {
            let state = RecordingState.recording(since: nil)
            let line = CapturePresentation(state: state, issue: issue, canResume: false, canStop: true).attentionLine(now: now, timeZone: zone)
            let shown = MenuBarMenu.header(CapturePresentation(state: state, issue: issue, canResume: false, canStop: true),
                                           now: now, timeZone: zone, canSetUp: true, canOpenApplications: true).attention ?? line ?? issue
            let page = DaydreamSettingsPage(section: MenuBarMenu.attentionSection(shown))
            check(expected[issue] != nil, "G37 the issue \"\(issue)\" has a page it opens (add it here)")
            if let want = expected[issue] { equal(page, want, "G37 \"\(shown)\" opens \(want.title)") }
        }
        // Review… beside a replacement to review opens Advanced, where the replacement controls are.
        let off = CapturePresentation(state: .off(since: nil, reason: RecordingCopy.blocker("Review replacement")),
                                      issue: "Review replacement", canResume: false, canStop: false)
        let h = MenuBarMenu.header(off, now: now, timeZone: zone, canSetUp: true, canOpenApplications: true)
        equal(h.control, .fix(title: "Review…", fix: .settings("Advanced")), "G37 Replacement needs review: Review… opens Advanced")
        // The hint says the page it opens (G67): never a "Recording requirements" page that doesn't exist.
        equal(MenuBarMenu.fixHint(.settings("Setup")), "Opens DayDream Settings", "G67 Review…'s hint: Opens DayDream Settings")
        equal(MenuBarMenu.fixHint(.settings("Advanced")), "Opens Advanced in DayDream Settings", "G67 Review… to Advanced says so")
        for path in ["Sources/MemoryUI/MenuBarMenu.swift", "Sources/MacMemApp/DaydreamOnboarding.swift", "Sources/MacMemApp/DaydreamOnboardingState.swift"] {
            let text = source(path)
            check(!text.contains("Recording requirements") && !text.contains("recording requirements"),
                  "G67 \(path) never names a Recording requirements page")
        }
        check(!source("Sources/MacMemApp/DaydreamOnboarding.swift").contains("Review Recording settings before starting"),
              "G67 setup's start blocker names no Recording settings page")
        #if !BASE_SHIM
        equal(MenuBarMenu.settingsHint("General"), "Opens DayDream Settings", "G67 the overview's hint")
        equal(MenuBarMenu.settingsHint("Apps to remember"), "Opens Apps to remember in DayDream Settings", "G67 a page's hint")
        equal(MenuBarMenu.settingsHint(MenuBarMenu.attentionSection(MenuBarMenu.historySetAsideLine)),
              "Opens Backup and restore in DayDream Settings", "G67 the attention line's hint names its page")
        equal(DaydreamOnboarding.settingsSection(for: RecordingCopy.replacementReview), "Advanced",
              "G37 setup's Open Settings for a replacement: Advanced")
        #endif
    }

    // MARK: G38

    static func choicesUnsaved() {
        equal(SettingsStatusCardModel.fix(for: MemoryViewModel.choicesUnsavedIssue), SettingsStatusButton("Open Apps to remember", .open(.apps)),
              "G38 app choices that didn't save: Open Apps to remember")
        equal(MemoryViewModel.choicesUnsavedIssue, "Your app choices didn't save", "G38 the app's words")
        check(!source("Sources/MemoryUI/SettingsStatusCard.swift").contains("Resolve unsaved preferences before recording"),
              "G38 the card matches no string the app never sets")
        #if !BASE_SHIM
        equal(MemoryViewModel.choicesUnsavedIssue, RecordingCopy.choicesUnsaved, "G38 one shared constant")
        #endif
    }

    // MARK: G66

    static func cardPauseLines() {
        func line(_ reason: String?) -> String {
            SettingsStatusCardModel(SettingsStatusSnapshot(state: .paused(until: nil, since: nil, reason: reason), canResume: true),
                                    calendar: calendar, now: now).stateLine
        }
        equal(line("Paused by you"), "Paused · Until you resume", "G66 the person's own pause: Paused · Until you resume")
        equal(line(nil), "Paused · Until you resume", "G66 no reason: Paused · Until you resume")
        equal(line(RecordingCopy.pauseReason("Paused for update. Start recording explicitly after restart.")),
              "Paused · While DayDream updates.", "G66 the update pause: Paused · While DayDream updates.")
        equal(line(RecordingCopy.pauseReason("Paused for uninstall")), "Paused · Until you resume", "G66 an uninstall's pause")
        equal(line(RecordingCopy.pauseReason("Paused for explicit rollback")), "Paused · Until you resume", "G66 a rollback's pause")
        equal(line("Paused while your Mac slept."), "Paused · While your Mac slept.", "G66 a Paused while line drops its own Paused")
        // gold/int: lifecycle's wait for an import or backup.
        equal(line(RecordingCopy.waitingForOperation), "Paused · Until your import or backup finishes.",
              "G66 a Paused until line drops its own Paused")
        for detail in RecordingCopy.pauseDetails {
            let l = line(detail)
            check(l.range(of: #"· (By|For|Paused) "#, options: .regularExpression) == nil, "G66 no fragment: \(l)")
        }
    }

    // MARK: G50

    static func reportLog() {
        var tick = 0.0
        let log = DiagnosticsLog(limit: 200) { tick += 1; return Date(timeIntervalSince1970: 1_790_000_000 + tick) }
        log.record("Recording: Suspended: screenLock, pausing.")
        log.record("Recording: Recording.")
        // Hours of a recording day: the summary count and the status change after nearly every save.
        for i in 0..<20_000 {
            log.record("Summaries: \(i % 7) pending.")
            log.record("Status: Recording apps. Summaries pending: \(i % 5).")
        }
        let recent = log.recent(50)
        equal(recent.count, 50, "G50 the report shows 50 lines")
        check(recent.contains { $0.hasSuffix("Recording: Suspended: screenLock, pausing.") },
              "G50 a recording line from hours ago is still in the report", recent.prefix(3).joined(separator: " | "))
        check(recent.contains { $0.hasSuffix("Recording: Recording.") }, "G50 the latest recording line too")
        check(recent.contains { $0.contains("Summaries: ") } && recent.contains { $0.contains("Status: ") },
              "G50 the busy kinds keep their share")
        // A line equal to the last line of its kind is skipped, whatever came between.
        let quiet = DiagnosticsLog(limit: 200)
        for _ in 0..<100 { quiet.record("Status: Paused."); quiet.record("Summaries: idle.") }
        equal(quiet.recent(50).count, 2, "G50 a repeated line of a kind is logged once")
        // Lines stay oldest first.
        let ordered = DiagnosticsLog(limit: 200) { tick += 1; return Date(timeIntervalSince1970: 1_790_000_000 + tick) }
        ["Recording: a.", "Status: b.", "Recording: c."].forEach(ordered.record)
        equal(ordered.recent(50).map { String($0.dropFirst(9)) }, ["Recording: a.", "Status: b.", "Recording: c."], "G50 oldest first")
        check(!block(source("Sources/MemoryCore/Diagnostics.swift"), from: "public func record(", to: "\n    }").contains("DateFormatter()"),
              "G50 no DateFormatter made per line")
        #if !BASE_SHIM
        equal(DiagnosticsLog.kind("Recording: Suspended: sleep."), "Recording", "G50 a line's kind is its label")
        equal(DiagnosticsLog.kind("DayDream 1.0 (build 5) started."), "other", "G50 a line without a label")
        let front = "Front app: Safari."
        equal(ReportProblemLog.statusLine("Recording apps. Summaries pending: 3. Writer idle. " + front, frontNote: front),
              "Recording apps.", "G50 the status line drops the pending count and the front-app note")
        equal(ReportProblemLog.statusLine("Capture OFF. Storage unavailable.", frontNote: nil), "Capture OFF. Storage unavailable.",
              "G50 a status line with nothing moving is kept whole")
        #endif
        let report = source("Sources/MacMemApp/ReportProblem.swift")
        check(block(report, from: "func watch<P: Publisher>", to: "}.store(in: &sinks)").contains("guard text != last"),
              "G50 each watcher logs only when its own line changes")
    }

    // MARK: G68

    static func setupWhileRecording() {
        // fix/setup-status (owner 9/28): setup works while recording (what's-new opens then). No "stop recording first"
        // note; Summaries and Apps stay usable and save; the last page's button is Done.
        let onboarding = source("Sources/MacMemApp/DaydreamOnboarding.swift")
        check(!onboarding.contains("Stop recording before changing setup") && !onboarding.contains("recordingNote"),
              "G68 setup never asks to stop recording first")
        check(!block(onboarding, from: "case .summaries:\n", to: "case .apps:").contains("|| model.recording)"),
              "G68 the summary choices can be changed while recording")
        check(onboarding.contains("if model.recording { return Self.doneTitle }"),
              "G68 while recording the last page's one button is Done")
    }

    // MARK: G69

    static func permissionWindow() {
        let setup = source("Sources/MemoryUI/PermissionSetup.swift")
        check(setup.contains("didActivateApplicationNotification"), "G69 the window hears when another app comes to the front")
        check(setup.contains("didTerminateApplicationNotification"), "G69 the window hears when System Settings quits")
        #if !BASE_SHIM
        let me: pid_t = 4242, other: pid_t = 777
        check(PermissionWindowFloat.keepsFloating(frontBundle: "com.apple.systempreferences", frontPID: other, ownPID: me),
              "G69 floats over System Settings (the drag cards)")
        check(PermissionWindowFloat.keepsFloating(frontBundle: "com.example.day", frontPID: me, ownPID: me),
              "G69 floats while DayDream itself is in front (a drag)")
        check(!PermissionWindowFloat.keepsFloating(frontBundle: "com.apple.Safari", frontPID: other, ownPID: me),
              "G69 lowers when another app is in front")
        check(PermissionWindowFloat.lowers(allowedNow: true, frontBundle: "com.apple.systempreferences", frontPID: other, ownPID: me),
              "G69 lowers once the permission is allowed")
        check(PermissionWindowFloat.lowers(allowedNow: false, frontBundle: "com.apple.finder", frontPID: other, ownPID: me),
              "G69 the 2 s refresh lowers it over a third app")
        check(!PermissionWindowFloat.lowers(allowedNow: false, frontBundle: nil, frontPID: nil, ownPID: me),
              "G69 an unknown front app changes nothing")
        check(!PermissionWindowFloat.lowers(allowedNow: false, frontBundle: "com.apple.systempreferences", frontPID: other, ownPID: me),
              "G69 still floats over System Settings until allowed")
        #endif
    }

    // MARK: R2-1 (gold/r2-copy-checks): every operational issue

    #if BASE_SHIM
    // The base has no retry action: every line opens a page.
    enum Attention: Equatable { case open(String), retry }
    static func attentionAction(_ line: String?) -> Attention { .open(MenuBarMenu.attentionSection(line)) }
    #else
    static func attentionAction(_ line: String?) -> MenuBarMenu.AttentionAction { MenuBarMenu.attentionAction(line) }
    #endif

    /// Words an issue line never uses: the code's names for things and the tone of an error report.
    static let issueBanned = ["writer", "failed", "fail", "needs attention", "error", "summary", "deletion", "operation"]

    static func issueLines() {
        let app = source("Sources/MacMemApp/MacMemApp.swift")
        // Every value `operationalIssue` can take, a literal or a named constant, found in the app's own source.
        var issues = Set(groups(#"operationalIssue\s*=\s*"# + literal, app))
        var named: [String: String] = [:]
        for name in Set(groups(#"operationalIssue\s*=\s*Self\.(\w+)"#, app)).sorted() {
            if let value = groups(#"static let "# + name + #"\s*=\s*"# + literal, app).first { issues.insert(value); named[value] = name }
            else if app.contains("static let \(name)=RecordingCopy.choicesUnsaved") {
                issues.insert(RecordingCopy.choicesUnsaved); named[RecordingCopy.choicesUnsaved] = name
            } else { check(false, "R2-1 the named issue Self.\(name) resolves to its words") }
        }
        for must in ["Summary writer needs attention", "Deletion failed", RecordingCopy.choicesUnsaved] {
            check(issues.contains(must), "R2-1 the scan finds the issue \"\(must)\"", issues.sorted().joined(separator: " | "))
        }
        // The presentation's other issue: a history set aside at launch (G45), shown when nothing else is.
        check(app.contains("var historySetAsideIssue:String? { backups.historySetAside ? MenuBarMenu.historySetAsideLine : nil }")
              && app.contains("operationalIssue:shownIssue ?? (resumeUnavailable == nil ? historySetAsideIssue : nil)"),
              "R2-1 the history set aside at launch is the only other issue a surface is given")
        issues.insert(MenuBarMenu.historySetAsideLine)
        // The jobs that run again by themselves, and what Try Again runs (MemoryViewModel.retryIssue).
        let maintenance = block(app, from: "maintenance = Timer.scheduledTimer(withTimeInterval:60,repeats:true)", to: "\n            }")
        let retry = block(app, from: "func retryIssue() {", to: "\n    }")
        let jobs = ["summaryIssue": "scheduleLegacySummaries()", "deletionIssue": "retryFailedDeletions()"]
        let backup = source("Sources/MacMemApp/BackupSettings.swift")
        let states: [(String, RecordingState)] = [("Recording", .recording(since: nil)), ("Paused", .paused(until: nil, since: nil, reason: RecordingCopy.pausedByYou)),
                                                  ("Off", .off(since: nil, reason: nil))]
        for raw in issues.sorted() {
            let words = RecordingCopy.issue(raw)
            let lower = words.lowercased()
            let bad = engineeringWords(words) + issueBanned.filter { lower.contains($0) }
            check(bad.isEmpty, "R2-1 \"\(raw)\" reaches a surface as \"\(words)\": plain words", bad.joined(separator: ", "))
            check(words.count <= 40 && !words.dropLast().contains("."), "R2-1 \"\(words)\": one short line")
            for (name, state) in states {
                let p = CapturePresentation(state: state, issue: raw, canResume: true, canStop: name != "Off")
                let h = MenuBarMenu.header(p, now: now, timeZone: zone, canSetUp: true, canOpenApplications: true)
                equal(h.attention, words, "R2-1 menu bar, \(name): the orange line says \"\(words)\"")
                equal(p.attentionLine(now: now, timeZone: zone), words, "R2-1 status popover, \(name): the same line")
                equal(SettingsGearButton.help(for: p, now: now, timeZone: zone), "Settings · " + words, "R2-1 toolbar gear, \(name): the same words")
                let card = SettingsStatusCardModel(SettingsStatusSnapshot(state: state, issue: raw, canResume: true), calendar: calendar, now: now)
                equal(card.attention, words, "R2-1 Settings card, \(name): the same line")
                // One button that fixes it, the same wherever the line is: Try Again, or the page that fixes it.
                switch attentionAction(h.attention) {
                case .retry:
                    check(card.button?.title == "Try Again" && card.button.map { "\($0.action)" } == "retry",
                          "R2-1 \(name): \"\(words)\" ends in Try Again in the menu bar, and the card's one button is Try Again",
                          card.button.map { "\($0.title) \($0.action)" } ?? "no button")
                case .open(let section):
                    let page = DaydreamSettingsPage(section: section)
                    check(page != .overview, "R2-1 \(name): \"\(words)\" opens the page that fixes it (not the overview it is already on)", section)
                    check(card.button?.action == .open(page) && card.button?.title == "Open " + page.title,
                          "R2-1 \(name): the card's one button opens the same page (\(page.title))",
                          card.button.map { "\($0.title) \($0.action)" } ?? "no button")
                }
            }
            // It clears by itself when the problem is gone.
            if raw == MenuBarMenu.historySetAsideLine {
                check(backup.contains(".onDisappear {model.historySetAsideSeen()}") && backup.contains("historySetAside=false"),
                      "R2-1 \"\(words)\" clears once Backup and restore has been seen")
                continue
            }
            guard let name = named[raw] else { check(false, "R2-1 \"\(raw)\" is a named issue with a clearing line"); continue }
            check(app.contains("if operationalIssue == Self.\(name) {operationalIssue=nil}") || app.contains("if self.operationalIssue == Self.\(name) {self.operationalIssue=nil}"),
                  "R2-1 \"\(words)\" has a line that clears it")
            if let job = jobs[name] {
                check(maintenance.contains(job), "R2-1 \"\(words)\": its job runs again every minute by itself (\(job))", maintenance)
                check(retry.contains("case Self.\(name)?: \(job)"), "R2-1 \"\(words)\": Try Again runs its job now", retry)
            }
        }
        // A deletion's line clears only when that deletion went through, never when some other one did.
        let worked = block(app, from: "private func deletionWorked(", to: "\n    }")
        check(worked.contains("failedDeletions.remove(id)") && worked.contains("guard failedDeletions.isEmpty else {return}"),
              "R2-1 a failed deletion's line clears when that deletion goes through", worked)
        // Every surface draws the line through the same action, and every host wires Try Again to the model.
        let menu = source("Sources/MemoryUI/MenuBarMenu.swift"), popover = source("Sources/MemoryUI/StatusPopover.swift")
        check(menu.contains("switch Self.attentionAction(line)") && menu.contains("run: { actions.retryIssue() }"),
              "R2-1 the menu bar's orange line does what attentionAction says")
        check(popover.contains("Self.attentionButton(line, actions: actions)") && popover.contains("case .retry: actions.retryIssue()")
              && popover.contains("case .open(let section): actions.openSettingsSection(section)"),
              "R2-1 the status popover's orange line is the same one click")
        check(source("Sources/MacMemApp/MenuBarContent.swift").contains("actions.retryIssue = { model.retryIssue() }")
              && app.contains("actions.retryIssue={ [weak self] in self?.retryIssue() }")
              && source("Sources/MacMemApp/DaydreamSettings.swift").contains("case .retry: model.retryIssue()")
              && source("Sources/MemoryUI/DaydreamToolbar.swift").contains("out.retryIssue = { dismiss(); base.retryIssue() }"),
              "R2-1 the menu bar, the main window, its popover and the Settings card all run the model's retryIssue")
        check(retry.contains("default: break") && !retry.contains("startCapture") && !retry.contains("requestStart")
              && !retry.contains("pause") && !retry.contains("stop"), "R2-1 Try Again never starts, pauses or stops recording", retry)
    }

    // MARK: R2-2 (gold/r2-copy-checks): every recording notice

    static func noticeLines() {
        let r = "Resume Recording", s = "Start Recording"
        // What recording looks like when each notice goes out: the cause and the menu's name for starting again.
        func presentation(_ cause: RecordingStopCause, _ title: String, reason: String?) -> CapturePresentation {
            switch cause {
            case .permission(let a, let i):
                return CapturePresentation(inputs: RecordingStateInputs(resumeUnavailable: "Permissions required",
                                                                        accessibilityGranted: !a, inputMonitoringGranted: !i))
            case .moveApp: return CapturePresentation(inputs: RecordingStateInputs(resumeUnavailable: "Move DayDream to Applications first"))
            case .restore: return CapturePresentation(inputs: RecordingStateInputs(resumeUnavailable: "Restore waiting for review"))
            default:
                return CapturePresentation(inputs: title == r ? RecordingStateInputs(stopped: false, sessionState: "paused", sessionReason: reason)
                                                              : RecordingStateInputs(stopped: true))
            }
        }
        let reasons: [String: [String]] = [
            "input": ["Input tap was disabled. Resume explicitly.", "Input event tap unavailable. No recording started."],
            "other": ["Recording stopped"], "person": ["Paused by you"], "suspension": [RecordingStopCause.notResumedReason],
            "storage": ["Storage write failed. Retrying automatically."],
        ]
        var cases: [(RecordingStopCause, String, String)] = []
        for cause in [RecordingStopCause.person, .suspension, .storage, .input, .other] { for title in [r, s] { cases.append((cause, title, "\(cause)")) } }
        for cause in [RecordingStopCause.permission(accessibility: true, inputMonitoring: false), .permission(accessibility: false, inputMonitoring: true),
                      .permission(accessibility: true, inputMonitoring: true), .permission(accessibility: false, inputMonitoring: false), .moveApp, .restore] {
            cases.append((cause, s, "\(cause)"))
        }
        var seen = 0
        for (cause, title, name) in cases {
            var notices: [(String, RecordingNotice)] = []
            if let n = RecordingNotice.stopped(cause, resumeTitle: title) { notices.append(("stopped", n)) }
            for episode in [WakeSuspension.sleep, .screenLock, .userSwitch] {
                notices.append(("after \(episode)", RecordingNotice.resumeFailed(after: [episode], cause: cause, resumeTitle: title)))
            }
            notices.append(("timed pause", RecordingNotice.timedPauseEnded(cause: cause, resumeTitle: title)))
            notices.append(("launch", RecordingNotice.reopenFailed(cause: cause, resumeTitle: title)))
            notices.append(("after an import", RecordingNotice.afterOperation(cause: cause, resumeTitle: title)))
            let key = String(name.prefix { $0 != "(" })
            // A permission, a download-window copy or a restore sets its own state; the others read the session's reason.
            for reason in reasons[key] ?? [""] {
                let p = presentation(cause, title, reason: reason.isEmpty ? nil : reason)
                let h = MenuBarMenu.header(p, now: now, timeZone: zone, canSetUp: true, canOpenApplications: true, canOpenPermissions: true)
                for (kind, n) in notices {
                    seen += 1
                    let label = "R2-2 \(kind) notice, \(name), \(title == r ? "Paused" : "not paused")" + (reason.isEmpty ? "" : " (\(reason))")
                    let body = n.body
                    let text = (n.title + " " + body).replacingOccurrences(of: "Input Monitoring", with: "")
                    let bad = engineeringWords(text) + ["input", "tap", "error", "failed"].filter { text.lowercased().contains($0) }
                    check(bad.isEmpty, "\(label): plain words", bad.joined(separator: ", ") + " in: " + body)
                    if h.status.tone == .paused {
                        check(!n.title.contains("stopped recording") && !body.hasPrefix("Recording stopped"),
                              "\(label): the menu bar says Paused, so the notice never says stopped", n.title + " / " + body)
                    }
                    // The control the notice names is one the menu bar panel has, enabled, in that state.
                    if n == RecordingNotice.storageRetrying { continue }
                    if let named = groups(#"Choose (.+?) from DayDream in the menu bar\."#, body).first {
                        let has: Bool
                        switch h.control {
                        case .fix(let fixTitle, _) where fixTitle == named: has = true
                        default: has = named == "Resume Now" && h.stateRow == .resume(enabled: true)
                        }
                        check(has, "\(label): names \(named), which the menu bar shows then", "\(h.control) \(String(describing: h.stateRow))")
                    } else if body.hasSuffix("Turn DayDream on in the menu bar.") {
                        check(h.control == .toggle(on: false, enabled: true), "\(label): names the switch, which is off and can be turned on", "\(h.control)")
                    } else if body.hasSuffix("Move DayDream to Applications first, then open it from there.") {
                        check(h.control == .fix(title: "Open Applications", fix: .applications), "\(label): the menu bar offers Open Applications", "\(h.control)")
                    } else {
                        check(false, "\(label): says what to do with a control the menu bar has", body)
                    }
                }
            }
        }
        // 18 situations (16 causes and titles; the input cause read with both of its reasons) × the six notices every
        // situation has, plus each "stopped" notice that goes out (120 today).
        check(seen >= 18 * 6, "R2-2 every notice was read (\(seen))")
        // The one text the panel draws for Resume Now is the name the notices use.
        check(block(source("Sources/MemoryUI/MenuBarMenu.swift"), from: "case .resume(let enabled):", to: "accessibilityIdentifier(\"menubar-resume\")")
              .contains("let id = \"Resume Now\""), "R2-2 the menu bar's row is titled Resume Now")
    }

    // MARK: R2-3 (gold/r2-copy-checks): the restore preview after a repair that couldn't read back every deletion

    static func restorePreviewLine() {
        let view = source("Sources/MacMemApp/BackupSettings.swift")
        let count = "Text(\"\\(prepared.preview.addedActionIDs.count) actions to add\")"
        let preview = block(view, from: "if let prepared=model.prepared {", to: "Button(\"Confirm Restore\"")
        check(preview.contains(count), "R2-3 the preview shows its count", preview)
        check(preview.contains("if let why=BackupSettingsModel.heldBackLine(prepared.preview.heldBackBefore) {Text(why)"),
              "R2-3 under the count, a line says why when a repair held some of the backup back", preview)
        let core = source("Sources/MemoryCore/CanonicalBackupBinding.swift")
        check(core.contains("public var heldBackBefore:String?=nil") && core.contains("else {heldBack+=1;continue}")
              && core.contains("if heldBack>0 {preview.heldBackBefore=marker}"),
              "R2-3 the preview records the repair's marker only when it held an action back (store-integrity E1, E3 run it)")
        #if !BASE_SHIM
        let line = BackupSettingsModel.heldBackLine("2026-09-27T14:03:00Z")
        equal(line, "Older actions aren't added, in case you deleted them.", "R2-3 the reason, in plain words")
        equal(BackupSettingsModel.heldBackLine(nil), nil, "R2-3 every other preview says nothing more")
        if let line { check(engineeringWords(line).isEmpty && line.count <= 60, "R2-3 one short plain line", line) }
        #endif
    }
}
