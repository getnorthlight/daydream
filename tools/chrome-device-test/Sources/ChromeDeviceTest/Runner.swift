import AppKit
import ApplicationServices
import ChromeProbeCore

/// Result of the preflight checks. Nothing here reads Chrome content.
struct Preflight {
    var profile: ProfileGate.Verdict = .notRunning
    var profileOK = false
    var profileNote = ""
    var app: NSRunningApplication?
    var pid: pid_t = 0
    var version: String?
    var major: Int?
    var signatureOK: Bool?
    var axTrusted = false
    var automation = "unchecked"

    var ready: Bool { profileOK && axTrusted && automation == "granted" }

    static func run(_ opts: Options) -> Preflight {
        var p = Preflight()
        let apps = System.chromeApps()
        let args = apps.count == 1 ? System.arguments(pid: apps[0].processIdentifier) : nil
        p.profile = ProfileGate.evaluate(chromeCount: apps.count, args: args, home: NSHomeDirectory())
        if p.profile.ok {
            p.profileOK = true; p.profileNote = p.profile.message
        } else if p.profile == .argumentsUnreadable && opts.skipProfileCheck {
            p.profileOK = true; p.profileNote = "UNVERIFIED: launch arguments unreadable, --skip-profile-check given"
        } else {
            p.profileNote = p.profile.message
        }
        print("Chrome profile:  \(p.profileNote)")
        // Refuse before any Apple Event, Accessibility read or permission request.
        guard p.profileOK, let app = apps.first else { return p }
        p.app = app
        p.pid = app.processIdentifier
        p.version = System.version(of: app)
        p.major = p.version.flatMap { Int($0.split(separator: ".").first ?? "") }
        p.signatureOK = System.chromeSignatureOK(pid: p.pid)
        print("Chrome:          pid \(p.pid), version \(p.version ?? "unknown")\((p.major ?? 0) >= Harness.minimumChromeMajor ? "" : " (older than \(Harness.minimumChromeMajor)!)"), Google signature \(p.signatureOK == true ? "ok" : "FAILED")")

        p.axTrusted = AXIsProcessTrusted()
        print("Accessibility:   \(p.axTrusted ? "on" : "OFF") for the app running this command (Terminal)")
        if !p.axTrusted {
            print("                 Add Terminal in System Settings > Privacy & Security > Accessibility (README step 5).")
            print("                 This harness never shows the Accessibility prompt itself.")
        }

        let status: OSStatus
        if opts.requestPermission {
            print("Automation:      asking macOS now (\"Terminal wants access to control Google Chrome\"). Click Allow / OK.")
            status = Automation.requestAutomationPermission(pid: p.pid)
        } else {
            status = Automation.status(pid: p.pid)
        }
        p.automation = Automation.describe(status)
        print("Automation:      \(p.automation)")
        if p.automation == "not decided" {
            print("                 Run: chrome-device-test preflight --request-permission")
        } else if p.automation == "denied" {
            print("                 Turn it on in System Settings > Privacy & Security > Automation > Terminal > Google Chrome.")
        }
        return p
    }
}

/// Everything one command needs to talk to the throwaway Chrome.
final class Session {
    let opts: Options
    let pre: Preflight
    let audit = ReadAudit()
    let timings = TimingLog()
    let ae: AuditedPort
    let ax: LiveAX
    let join: ChromeJoin<AXUIElement>

    init(_ opts: Options, _ pre: Preflight) {
        self.opts = opts
        self.pre = pre
        ae = AuditedPort(LiveAppleEvents(pid: pre.pid, timeoutMs: opts.aeTimeoutMs), audit: audit, timings: timings)
        ax = LiveAX(chromePID: pre.pid, timeoutMs: opts.axTimeoutMs)
        join = ChromeJoin(chromePID: pre.pid, ae: ae, audit: audit, ax: ax.access(probeLabels: opts.probeLabels), timings: timings, now: System.now)
        join.probeLabels = opts.probeLabels
        join.keepReads = opts.verbose
        if opts.verbose { timings.echo = { print(String(format: "      %@ %.2f ms  %@", $0.kind.rawValue, $0.ms, $0.label)) } }
    }

    var chromeStillRunning: Bool { !(pre.app?.isTerminated ?? true) }

    // MARK: commands

    func windows() {
        audit.beginPass()
        guard let t = WindowPass.table(ae, names: true) else { print("Could not list Chrome windows (Apple Events failed)."); return }
        printTable(t)
    }

    func printTable(_ t: WindowTable) {
        print("Chrome windows, front to back (listing: \(t.listing.mode.rawValue)):")
        print("   #  id            mode        bounds (x,y wxh)        name")
        for (i, w) in t.windows.enumerated() {
            let name = w.name ?? (t.strictPause ? "(not read: a window is not normal)" : "(not read)")
            print(String(format: "  %2d  %-12@  %-10@  %-22@  %@", i + 1, w.id as NSString, (w.mode.isEmpty ? "(unreadable)" : w.mode) as NSString,
                         (w.bounds?.description ?? "?") as NSString, name as NSString))
        }
        if t.strictPause { print("  Strict mode: PAUSED. No window names, addresses or Accessibility content were read.") }
    }

    func joins(count: Int) {
        if opts.waitForChrome { System.waitForChromeFront(pid: pre.pid, ax: ax, settle: opts.settleSeconds) }
        var reports: [JoinReport] = []
        for i in 0..<count {
            let o = join.run()
            reports.append(o.report)
            print(String(format: "  join %d: %@  (%.1f ms, %d AE + %d AX reads)", i + 1, o.report.summary, o.report.totalMs, o.report.aeReads, o.report.axReads))
            System.sleep(0.15)
        }
        printJoinSummary(reports)
    }

    func focus(seconds: Double) {
        if opts.waitForChrome { System.waitForChromeFront(pid: pre.pid, ax: ax, settle: opts.settleSeconds) }
        System.go()
        let f = FocusSummary.of(sampleFocus(seconds: seconds))
        System.done()
        printFocus(f)
    }

    func sampleFocus(seconds: Double) -> [FocusSample] {
        let start = System.now(), watch = Set(opts.panelBundles)
        var samples: [FocusSample] = []
        while milliseconds(System.now() &- start) < seconds * 1000 {
            samples.append(System.focusSample(chromePID: pre.pid, ax: ax, watch: watch, since: start))
            System.sleep(0.1)
        }
        return samples
    }

    // MARK: printing

    func printJoinSummary(_ j: [JoinReport], indent: String = "    ") {
        guard !j.isEmpty else { print(indent + "no joins"); return }
        let count = { (v: Verdict) in j.filter { $0.verdict == v }.count }
        var line = "\(j.count) joins: ALLOW \(count(.allow)), DENY \(count(.deny)), PAUSE \(count(.strictPause))"
        if let last = j.last(where: { $0.verdict != .strictPause }) {
            line += " | field \(last.fieldRole ?? "-")/\(last.fieldSubrole.map { $0.isEmpty ? "-" : $0 } ?? "?")"
            line += " | web areas \(last.webAreaCount) (top's parent \(last.topWebAreaParentRole ?? "-"))"
            if let o = last.origin { line += " | origin \(o)" }
        }
        print(indent + line)
        let nonPause = j.filter { $0.verdict != .strictPause }
        if !nonPause.isEmpty {
            print(indent + "window match: bounds \(nonPause.filter { $0.boundsMatchFront == true }.count)/\(nonPause.count), title \(Set(nonPause.map(\.titleMatch.rawValue)).sorted().joined(separator: ",")), URL \(Set(nonPause.map(\.urlComparison)).sorted().joined(separator: ","))")
        }
        let modes = Set(j.flatMap(\.modes)).sorted()
        print(indent + "window modes seen: \(modes.joined(separator: ", ")); windows: \(Set(j.map(\.windowCount)).sorted().map(String.init).joined(separator: ","))")
        let counted = j.filter { $0.axWindowCount != nil || $0.reasons.contains(.axWindowsUnreadable) }
        if !counted.isEmpty {
            print(indent + "AX windows (standard): \(Set(counted.map { $0.axStandardWindows.map(String.init) ?? "unreadable" }).sorted().joined(separator: ","))"
                  + "; not listed in \(counted.filter { ($0.unpairedAXWindows ?? 0) > 0 }.count), same frame in \(counted.filter { ($0.sameFrameWindows ?? 0) > 1 }.count)"
                  + "; stopped before content \(j.filter(\.stoppedBeforeContent).count)/\(j.count)")
        }
        let reasons = Dictionary(grouping: j.flatMap(\.reasons), by: { $0 }).map { "\($0.key.rawValue) x\($0.value.count)" }.sorted()
        if !reasons.isEmpty { print(indent + "deny reasons: " + reasons.joined(separator: ", ")) }
        if let st = Stats.of(j.map(\.totalMs)) { print(indent + "join time: \(st) (budget \(Int(Harness.joinBudgetMs)) ms)") }
        if j.contains(where: { $0.secureInput }) { print(indent + "macOS secure input was ON") }
        if let hits = j.compactMap(\.labelDeny).first(where: { !$0.isEmpty }) { print(indent + "label/id deny rules matched: \(hits.joined(separator: ", "))") }
        if let presence = j.compactMap(\.labelPresence).last {
            print(indent + "label attributes present (characters): " + presence.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        let paused = j.filter { $0.verdict == .strictPause }
        if !paused.isEmpty {
            let reads = paused.map { $0.aeContentReads + $0.axContentReads }.reduce(0, +)
            print(indent + "paused joins read \(reads) titles/URLs/AX content (must be 0)")
        }
        let v = j.flatMap(\.auditViolations)
        if !v.isEmpty { print(indent + "AUDIT VIOLATIONS: " + v.joined(separator: "; ")) }
    }

    func printFocus(_ f: FocusSummary, indent: String = "    ") {
        print(indent + "\(f.samples) samples, Chrome frontmost in \(f.chromeFront)")
        print(indent + "keys going to another app while Chrome was frontmost: \(f.focusElsewhereWhileChromeFront) samples")
        print(indent + "launcher panel on screen with Chrome frontmost: \(f.panelWhileChromeFront) samples, of which focus still said Chrome: \(f.leaks)")
        print(indent + "focused apps: " + f.focusedBundles.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", "))
    }

    // MARK: guided run

    func guided() -> Int32 {
        print("""

        Guided device test. Each step: read the instruction, press Return here, then do it in Chrome.
        Sounds: "Tink" = go (do the timed action now). "Glass" = step done, come back to Terminal.
        Type s + Return to skip a step, q + Return to stop early (the table still prints).
        The harness never reads what you type, field values or selected text.

        """)
        let selected = Steps.all.filter { opts.only.isEmpty || opts.only.contains($0.id) }
        var results: [StepResult] = []
        for (n, spec) in selected.enumerated() {
            print("Step \(n + 1)/\(selected.count)  [\(spec.id)]  \(spec.title)")
            if !spec.setup.isEmpty {
                print("  Before you press Return:")
                spec.setup.forEach { print("    " + $0) }
            }
            print("  Then, in Chrome:")
            spec.action.forEach { print("    " + $0) }
            var r = StepResult(id: spec.id)
            if spec.needsLabels && !opts.probeLabels {
                r.skippedReason = "needs --probe-labels"
                print("    skipped: run with --probe-labels to test the card/OTP deny rules.\n")
                results.append(r); continue
            }
            let answer = System.readLine(prompt: "    Press Return when ready (s = skip, q = quit): ").lowercased()
            if answer.hasPrefix("q") { break }
            if answer.hasPrefix("s") { r.skippedReason = "skipped by owner"; results.append(r); print(""); continue }
            guard chromeStillRunning else { print("    Chrome has quit. Stopping."); break }
            r.ran = true
            switch spec.kind {
            case .descriptor: stepDescriptor(&r)
            case .join, .strict: stepJoins(spec, &r)
            case .typing: stepTyping(&r)
            case .focus: stepFocus(&r)
            case .race: stepRace(spec, &r)
            case .guest: stepGuest(spec, &r)
            case .closing: stepClose(&r)
            case .nativeFocus: stepNativeFocus(&r)
            }
            r.notes.forEach { print("    note: " + $0) }
            print("")
            results.append(r)
        }
        return finish(results)
    }

    func stepDescriptor(_ r: inout StepResult) {
        audit.beginPass()
        let d = DescriptorResult.probe(ae)
        r.descriptor = d
        print("    every-window listing: \(d.everyIDs.map { "\($0.count) windows" } ?? "FAILED") (reply type \(d.listReplyType ?? "-"))")
        print("    indexed listing:      \(d.indexedIDs.map { "\($0.count) windows" } ?? "FAILED")")
        print("    first window (abso, the fix):          \(d.fixedWorks ? "works" : "FAILED (status \(d.firstAbsoluteStatus))")")
        print("    first window (enum, pre-fix ChromeModeReader.swift:39): \(d.legacyWorks ? "works" : "FAILED (status \(d.firstLegacyEnumStatus))")")
        print("    bounds reply type: \(d.boundsRawType ?? "-")")
        join.listingMode = d.everyIDs != nil ? .every : .indexed
        audit.beginPass()
        if let t = WindowPass.table(ae, prefer: join.listingMode, names: true) {
            printTable(t)
            r.windows = t.windows
            if t.windows.count != 1 { r.notes.append("expected exactly one normal window at this step; found \(t.windows.count)") }
        }
    }

    func stepJoins(_ spec: StepSpec, _ r: inout StepResult) {
        guard System.waitForChromeFront(pid: pre.pid, ax: ax, settle: opts.settleSeconds) else { r.ran = false; r.skippedReason = "Chrome never came to the front"; return }
        if spec.kind == .strict {
            // Strict joins need an Incognito window open. Window IDs and modes
            // only, as stepRace and stepClose read; no title, URL or AX read.
            audit.beginPass()
            if let base = WindowPass.list(ae, prefer: join.listingMode),
               let why = Steps.strictPrecondition(modes: base.ids.map { ae.send(.window(.id($0), .mode)).text ?? "" }) {
                r.ran = false
                r.skippedReason = "no Incognito window was open"
                r.notes.append(why)
                System.done()
                return
            }
        }
        if spec.id == "plain-input" {
            // Chrome builds its accessibility tree on first use: measure how long.
            let start = System.now()
            var tries = 0
            while milliseconds(System.now() &- start) < 3000 {
                tries += 1
                if join.run().report.webAreaCount > 0 { r.warmupMs = milliseconds(System.now() &- start); break }
                System.sleep(0.1)
            }
            r.notes.append(r.warmupMs.map { String(format: "web area visible after %.0f ms (%d tries)", $0, tries) } ?? "no web area after 3 s of tries")
        }
        var last: JoinOutcome<AXUIElement>?
        for _ in 0..<spec.joins {
            let o = join.run()
            r.joins.append(o.report)
            if o.report.verdict == .allow { last = o }
            System.sleep(0.15)
        }
        if spec.id == "plain-input", let last, let front = last.frontID {
            for _ in 0..<20 {
                let l = join.lightCheck(frontID: front, window: last.window, element: last.element)
                r.lightMs.append(l.ms)
                if l.ok { r.lightOK += 1 }
                System.sleep(0.05)
            }
            if let st = Stats.of(r.lightMs) { print("    light per-key check: \(st), still valid \(r.lightOK)/\(r.lightMs.count)") }
        }
        System.done()
        printJoinSummary(r.joins)
    }

    func stepTyping(_ r: inout StepResult) {
        guard System.waitForChromeFront(pid: pre.pid, ax: ax, settle: opts.settleSeconds) else { r.ran = false; r.skippedReason = "Chrome never came to the front"; return }
        System.go()
        let start = System.now()
        var previous: AXUIElement?
        while milliseconds(System.now() &- start) < 10_000 {
            let o = join.run()
            r.joins.append(o.report)
            if let e = o.element {
                if let p = previous { r.elementStable.append(CFEqual(p, e)) }
                previous = e
            }
            System.sleep(0.25)
        }
        System.done()
        print("    focused element unchanged between samples: \(r.elementStable.filter { $0 }.count)/\(r.elementStable.count)")
        printJoinSummary(r.joins)
    }

    func stepFocus(_ r: inout StepResult) {
        guard System.waitForChromeFront(pid: pre.pid, ax: ax, settle: opts.settleSeconds) else { r.ran = false; r.skippedReason = "Chrome never came to the front"; return }
        System.go()
        let f = FocusSummary.of(sampleFocus(seconds: opts.seconds))
        System.done()
        r.focus = f
        printFocus(f)
    }

    /// Cmd+Shift+N: how long until the new window is in the Apple Events list,
    /// and whether the join's window count (review I1) covers the gap. Reads
    /// only window IDs, the new window's mode, the identity of the focused AX
    /// window, and AXWindows' subroles (no title, no geometry of content, no URL).
    func stepRace(_ spec: StepSpec, _ r: inout StepResult) {
        guard System.waitForChromeFront(pid: pre.pid, ax: ax, settle: opts.settleSeconds) else { r.ran = false; r.skippedReason = "Chrome never came to the front"; return }
        audit.beginPass()
        guard let base = WindowPass.list(ae, prefer: join.listingMode) else { r.notes.append("could not list windows"); return }
        let baseModes = base.ids.map { ae.send(.window(.id($0), .mode)).text ?? "" }
        guard baseModes.allSatisfy({ $0 == "normal" }) else { r.notes.append("a non-normal window was already open; close it and re-run this step"); return }
        let baseWindow = ax.element(ax.app, .focusedWindow)
        System.go()
        let start = System.now()
        var axAt: Double?, aeAt: Double?, mode: String?
        var samples: [RaceSample] = []
        while milliseconds(System.now() &- start) < 20_000 {
            let t = milliseconds(System.now() &- start)
            var listedNow = base.ids.count
            if aeAt == nil, let ids = WindowPass.list(ae, prefer: join.listingMode)?.ids {
                listedNow = ids.count
                if let new = ids.first(where: { !base.ids.contains($0) }) {
                    aeAt = t
                    mode = ae.send(.window(.id(new), .mode)).text ?? "(unreadable)"
                }
            }
            let w = ax.element(ax.app, .focusedWindow)
            if axAt == nil {
                switch (w, baseWindow) {
                case (let a?, let b?): if !CFEqual(a, b) { axAt = t }
                case (nil, nil): break
                default: axAt = t
                }
            }
            // Only the gap matters: focus has moved and the window isn't listed.
            if axAt != nil && aeAt == nil {
                let c = ax.standardWindowCount(focused: w)
                samples.append(RaceSample(ms: t, aeListed: listedNow, axStandard: c.count, focusMoved: true, newListed: false, focusedInAXList: c.focusedListed))
            }
            if aeAt != nil && axAt != nil { break }
            System.sleep(0.01)
        }
        r.race = RaceResult(axChangedMs: axAt, aeListedMs: aeAt, newWindowMode: mode, timedOut: aeAt == nil || axAt == nil, samples: samples)
        print(String(format: "    new window mode: %@; focus moved at %@ ms; listed at %@ ms; lag %@ ms", mode ?? "not seen",
                     axAt.map { String(format: "%.0f", $0) } ?? "-", aeAt.map { String(format: "%.0f", $0) } ?? "-",
                     r.race?.lagMs.map { String(format: "%.0f", $0) } ?? "-"))
        if let race = r.race, race.dangerousSamples > 0 {
            print("    in the gap: the AX window count would deny in \(race.dangerousSamples - race.uncaughtSamples)/\(race.dangerousSamples) samples"
                  + "; focused window in AXWindows in \(race.samples.filter { $0.focusedInAXList == true }.count)")
        }
        System.sleep(0.5)
        for _ in 0..<spec.joins { r.joins.append(join.run().report); System.sleep(0.15) }
        System.done()
        printJoinSummary(r.joins)
    }

    /// Cmd+Shift+W on an Incognito page that asks "Leave site?". Joins run
    /// while the dialog is up; each must pause (still listed) or stop at the
    /// window count (dropped from the Apple Events list, still on screen).
    func stepClose(_ r: inout StepResult) {
        guard System.waitForChromeFront(pid: pre.pid, ax: ax, settle: opts.settleSeconds) else { r.ran = false; r.skippedReason = "Chrome never came to the front"; return }
        audit.beginPass()
        guard let base = WindowPass.list(ae, prefer: join.listingMode) else { r.notes.append("could not list windows"); return }
        let modes = base.ids.map { ae.send(.window(.id($0), .mode)).text ?? "" }
        guard let incognito = zip(base.ids, modes).first(where: { $0.1 == "incognito" })?.0 else {
            r.notes.append("no Incognito window is open; open one as the step says and re-run this step"); return
        }
        System.go()
        let start = System.now()
        var dropped: Double?
        var listed: [Bool] = []
        while milliseconds(System.now() &- start) < opts.seconds * 1000 {
            audit.beginPass()
            let still = WindowPass.list(ae, prefer: join.listingMode)?.ids.contains(incognito) ?? true
            if !still && dropped == nil { dropped = milliseconds(System.now() &- start) }
            listed.append(still)
            r.joins.append(join.run().report)
            System.sleep(0.2)
        }
        System.done()
        let confirmed = System.readLine(prompt: "    Did the \"Leave site?\" dialog stay open until the Glass sound? [y/N] ").lowercased().hasPrefix("y")
        r.closing = ClosingResult(aeDroppedMs: dropped, incognitoListed: listed, dialogConfirmed: confirmed)
        print("    Incognito window " + (dropped.map { String(format: "left the Apple Events list after %.0f ms", $0) } ?? "stayed in the Apple Events list"))
        printJoinSummary(r.joins)
        if !confirmed { r.notes.append("dialog not confirmed open; A14 is not graded. Re-run with --only incognito-closing") }
    }

    /// TextEdit / Notes: does the system-wide focused app (what the native
    /// witness uses) equal the frontmost editor, and how long does it take?
    /// Nothing is read from Chrome or the editors.
    func stepNativeFocus(_ r: inout StepResult) {
        guard System.waitForFront(bundles: Harness.nativeEditors, settle: opts.settleSeconds) else { r.ran = false; r.skippedReason = "TextEdit or Notes never came to the front"; return }
        System.go()
        let f = FocusSummary.of(sampleFocus(seconds: opts.seconds))
        System.done()
        r.focus = f
        print("    TextEdit/Notes frontmost in \(f.nativeFront) samples; system-wide focus agreed in \(f.nativeAgree); focus read \(f.focusReadStats.map(\.description) ?? "-")")
    }

    func stepGuest(_ spec: StepSpec, _ r: inout StepResult) {
        r.guestConfirmed = System.readLine(prompt: "    Is a Guest window open now? [y/N] ").lowercased().hasPrefix("y")
        guard r.guestConfirmed == true else { r.notes.append("Guest window not confirmed; step not measured"); return }
        for _ in 0..<spec.joins { r.joins.append(join.run().report); System.sleep(0.15) }
        System.done()
        printJoinSummary(r.joins)
    }

    func finish(_ results: [StepResult]) -> Int32 {
        let facts = RunFacts(profileOK: pre.profileOK, profileNote: pre.profileNote, accessibilityTrusted: pre.axTrusted, automation: pre.automation,
                             chromeVersion: pre.version, chromeMajor: pre.major, signatureOK: pre.signatureOK, probeLabels: opts.probeLabels,
                             auditViolations: audit.violations.count, aeReadStats: Stats.of(timings.ae), axReadStats: Stats.of(timings.ax),
                             replyTypes: ae.replyTypes.mapValues { $0.sorted() })
        let report = RunReport(macOS: System.macOS, facts: facts, steps: results)
        print("RESULTS (criteria agreed in README.md before the run)")
        print(Table.render(report.criteria))
        print("")
        print("OVERALL: " + report.overall)
        if !audit.violations.isEmpty { print("AUDIT VIOLATIONS:\n  " + audit.violations.joined(separator: "\n  ")) }
        if let path = opts.reportPath {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do { try report.json().write(to: url); print("Report written to \(url.path) (origins only; no titles, labels or typed text).") }
            catch { print("Could not write the report: \(error.localizedDescription)") }
        }
        print("Next, the clean-up: quit the throwaway Chrome and remove the permissions (README.md step 7; the kit's run.sh does it with you).")
        if report.overall.hasPrefix("RUN INVALID") { return 2 }
        if report.overall.hasPrefix("ABANDON") { return 3 }
        if report.overall.hasPrefix("INCOMPLETE") { return 4 }
        return 0
    }
}
