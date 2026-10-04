import Foundation

public enum Grade: String, Codable { case pass = "PASS", fail = "FAIL", fix = "FIX", info = "INFO", notRun = "NOT RUN" }

/// GATE: the run doesn't count unless it passes. ABANDON: a FAIL stops Chrome
/// typing work until after launch. FIX: must be fixed while building, not a
/// reason to stop. INFO: recorded for the build.
public enum Severity: String, Codable { case gate = "GATE", abandon = "ABANDON", fix = "FIX", info = "INFO" }

public struct CriterionResult: Codable {
    public var id: String
    public var severity: Severity
    public var title: String
    public var grade: Grade
    public var evidence: String
}

/// Facts from preflight and the whole run that aren't tied to one step.
public struct RunFacts: Codable {
    public var profileOK: Bool
    public var profileNote: String
    public var accessibilityTrusted: Bool
    public var automation: String
    public var chromeVersion: String?
    public var chromeMajor: Int?
    public var signatureOK: Bool?
    public var probeLabels: Bool
    public var auditViolations: Int
    public var aeReadStats: Stats?
    public var axReadStats: Stats?
    /// Descriptor types of every successful Apple Event reply, by property (F9).
    public var replyTypes: [String: [String]]?
    public init(profileOK: Bool, profileNote: String, accessibilityTrusted: Bool, automation: String, chromeVersion: String?, chromeMajor: Int?,
                signatureOK: Bool?, probeLabels: Bool, auditViolations: Int, aeReadStats: Stats?, axReadStats: Stats?,
                replyTypes: [String: [String]]? = nil) {
        self.profileOK = profileOK; self.profileNote = profileNote; self.accessibilityTrusted = accessibilityTrusted
        self.automation = automation; self.chromeVersion = chromeVersion; self.chromeMajor = chromeMajor
        self.signatureOK = signatureOK; self.probeLabels = probeLabels; self.auditViolations = auditViolations
        self.aeReadStats = aeReadStats; self.axReadStats = axReadStats; self.replyTypes = replyTypes
    }
}

public enum Criteria {
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea"]
    /// Steps where a field in a normal window should be accepted.
    public static let allowSteps = ["plain-input", "textarea", "contenteditable", "typing", "two-windows-new", "two-windows-old"]

    static func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "0/0" : "\(n)/\(d)" }
    static func ratioOK(_ n: Int, _ d: Int) -> Bool { d > 0 && Double(n) / Double(d) >= Harness.requiredRatio }
    /// Joins after the first two (the first ones pay for Chrome waking its accessibility up).
    static func warm(_ j: [JoinReport]) -> [JoinReport] { j.count > 3 ? Array(j.dropFirst(2)) : j }

    public static func grade(_ steps: [String: StepResult], _ f: RunFacts) -> [CriterionResult] {
        var out: [CriterionResult] = []
        func add(_ id: String, _ sev: Severity, _ title: String, _ g: Grade, _ ev: String) {
            out.append(CriterionResult(id: id, severity: sev, title: title, grade: g, evidence: ev))
        }
        func ran(_ id: String) -> StepResult? { steps[id].flatMap { $0.ran ? $0 : nil } }
        let allJoins = steps.values.filter(\.ran).flatMap(\.joins)

        // Gates
        add("G1", .gate, "Throwaway Chrome profile, one Chrome instance", f.profileOK ? .pass : .fail, f.profileNote)
        add("G2", .gate, "Accessibility trusted and Automation granted (for Terminal)",
            f.accessibilityTrusted && f.automation == "granted" ? .pass : .fail,
            "Accessibility \(f.accessibilityTrusted ? "on" : "off"), Automation \(f.automation)")
        let pauseLeaks = allJoins.filter { $0.verdict == .strictPause && ($0.aeContentReads > 0 || $0.axContentReads > 0) }.count
        add("G3", .gate, "Harness integrity: no title/URL/AX-content read while a non-normal window existed",
            f.auditViolations == 0 && pauseLeaks == 0 ? .pass : .fail,
            "\(f.auditViolations) audit violations, \(pauseLeaks) paused joins with content reads")

        // G4: the frontmost-app reading must be live. Focus in Chrome while
        // macOS says another app is frontmost is not a real state; if it shows
        // up, NSWorkspace was stale and the deny reasons can't be trusted.
        let allowJoins = allowSteps.compactMap { ran($0) }.flatMap(\.joins)
        let stale = allowJoins.filter { $0.focusedAppIsChrome && !$0.frontmostIsChrome }.count
        add("G4", .gate, "Frontmost-app reading is live (no Chrome-focused join says Chrome is not frontmost)",
            allowJoins.isEmpty ? .notRun : (Double(stale) <= 0.1 * Double(allowJoins.count) ? .pass : .fail),
            "\(stale)/\(allowJoins.count) joins disagree")

        // A1 window list and mode
        if let d = ran("descriptor")?.descriptor {
            let badListing = allJoins.filter { $0.listing == "failed" }.count
            let badMode = allJoins.filter { $0.modes.contains("(unreadable)") }.count
            let ok = d.listingWorks && d.fixedWorks && badListing == 0 && badMode == 0
            var ev = "every-window listing \(d.everyIDs != nil ? "works" : "FAILS"), indexed \(d.indexedIDs != nil ? "works" : "fails"), fixed first-window descriptor \(d.fixedWorks ? "works" : "FAILS")"
            ev += "; \(badListing) failed listings, \(badMode) unreadable modes in \(allJoins.count) joins"
            add("A1", .abandon, "Every window listed; mode read by window ID", ok ? .pass : .fail, ev)
        } else {
            add("A1", .abandon, "Every window listed; mode read by window ID", .notRun, "descriptor step not run")
        }

        // A2 Incognito detected, strict pause with it in front and behind
        let race = ran("incognito-race")?.race
        let raceJoins = ran("incognito-race")?.joins ?? []
        let bgJoins = ran("incognito-background")?.joins ?? []
        let raceOK: Bool? = race.map { $0.newWindowMode == "incognito" && raceJoins.allSatisfy { $0.verdict == .strictPause } }
        let bgOK: Bool? = ran("incognito-background").map { _ in !bgJoins.isEmpty && bgJoins.allSatisfy { $0.verdict == .strictPause && $0.modes.contains("incognito") } }
        let a2: Grade = (raceOK == false || bgOK == false) ? .fail : ((raceOK == nil || bgOK == nil) ? .notRun : .pass)
        add("A2", .abandon, "Incognito window reports \"incognito\"; strict pause in front and behind", a2,
            "new window mode: \(race?.newWindowMode ?? "not seen"); paused in front \(pct(raceJoins.filter { $0.verdict == .strictPause }.count, raceJoins.count)), behind \(pct(bgJoins.filter { $0.verdict == .strictPause }.count, bgJoins.count))")

        // A3 Guest
        if let gs = ran("guest"), gs.guestConfirmed == true {
            let paused = gs.joins.filter { $0.verdict == .strictPause && $0.modes.contains("incognito") }.count
            add("A3", .abandon, "Guest window reports \"incognito\" (strict pause)", paused == gs.joins.count && paused > 0 ? .pass : .fail,
                "paused \(pct(paused, gs.joins.count)); modes seen: \(Set(gs.joins.flatMap(\.modes)).sorted().joined(separator: ","))")
        } else {
            add("A3", .abandon, "Guest window reports \"incognito\" (strict pause)", .notRun, "Guest window not confirmed open")
        }

        // A4 Incognito listing lag (review I1). Between focus moving to the
        // new window and Apple Events listing it, keys go to an unlisted
        // window. That gap is safe only if the join's window count sees the
        // extra AX window in every sample of it; lag alone is no longer a pass.
        let a4Title = "New Incognito window: every moment before it is listed, the AX window count denies"
        if let r = race {
            let g: Grade
            let ev: String
            switch (r.axChangedMs, r.aeListedMs) {
            case (nil, nil): g = .notRun; ev = "no new window seen (was Cmd+Shift+N pressed after the beep?)"
            case (_?, nil): g = .fail; ev = "focus moved to a new window that never appeared in the Apple Events list"
            case (nil, _?): g = .pass; ev = "listed; focus change not seen, so no gap"
            case (_?, _?):
                let lag = r.lagMs ?? 0
                let gap = r.dangerousSamples, missed = r.uncaughtSamples
                if lag == 0 {
                    g = .pass; ev = "listed before or as focus moved (no gap)"
                } else if gap == 0 {
                    g = .fail; ev = String(format: "listed %.0f ms after focus moved, but no sample fell in the gap: the window count is unproven", lag)
                } else if missed > 0 {
                    g = .fail; ev = String(format: "listed %.0f ms after focus moved; in %d of %d samples of the gap AX showed no extra window (a same-frame Incognito window would be accepted)", lag, missed, gap)
                } else {
                    g = lag <= Harness.incognitoLagAbandonMs ? .pass : .fix
                    ev = String(format: "listed %.0f ms after focus moved; the AX window count denied in all %d samples of the gap%@", lag, gap,
                                lag <= Harness.incognitoLagAbandonMs ? "" : String(format: " (gap over %.0f ms: FIX)", Harness.incognitoLagAbandonMs))
                }
            }
            add("A4", .abandon, a4Title, g, ev)
        } else {
            add("A4", .abandon, a4Title, .notRun, "race step not run")
        }

        // A5/A6 basic-mode Accessibility
        func fieldVisible(_ id: String) -> (Bool?, String) {
            guard let s = ran(id) else { return (nil, "\(id) not run") }
            let good = s.joins.filter { textBox($0) && $0.webAreaCount == 1 && !$0.reasons.contains(.webAreaURLUnreadable) }.count
            let roles = Set(s.joins.compactMap(\.fieldRole)).sorted().joined(separator: ",")
            return (good > 0, "\(id): role \(roles.isEmpty ? "none" : roles), one web area with AXURL in \(pct(good, s.joins.count))")
        }
        let (p1, e1) = fieldVisible("plain-input"), (p2, e2) = fieldVisible("textarea")
        let a5: Grade = (p1 == false || p2 == false) ? .fail : (p1 == nil || p2 == nil ? .notRun : .pass)
        add("A5", .abandon, "Basic-mode AX shows input/textarea role, one AXWebArea and AXURL", a5, e1 + "; " + e2)
        let (p3, e3) = fieldVisible("contenteditable")
        add("A6", .abandon, "Basic-mode AX shows the contenteditable editor as a text field", p3 == nil ? .notRun : (p3! ? .pass : .fail), e3)

        // A7 AE <-> AX window match
        var a7Parts: [String] = [], a7Fail = false, a7Missing = false
        for id in ["plain-input", "two-windows-new", "two-windows-old"] {
            guard let s = ran(id) else { a7Missing = true; a7Parts.append("\(id) not run"); continue }
            let j = s.joins
            let bounds = j.filter { $0.boundsMatchFront == true }.count
            let title = j.filter { $0.titleMatch.acceptable }.count
            let url = j.filter { $0.urlComparison == "same" }.count
            let all = j.filter { $0.boundsMatchFront == true && $0.titleMatch.acceptable && $0.urlComparison == "same" }.count
            if id != "plain-input" && (j.map(\.windowCount).max() ?? 0) < 2 { a7Missing = true; a7Parts.append("\(id): only one window was open"); continue }
            if !ratioOK(all, j.count) { a7Fail = true }
            a7Parts.append("\(id): bounds \(pct(bounds, j.count)), title \(pct(title, j.count)), URL \(pct(url, j.count))")
        }
        add("A7", .abandon, "AE window = AX window (bounds, title, URL) in >=90% of joins", a7Fail ? .fail : (a7Missing ? .notRun : .pass), a7Parts.joined(separator: "; "))

        // A8 stability while typing
        if let s = ran("typing") {
            let allow = s.joins.filter { $0.verdict == .allow }.count
            let stable = s.elementStable.filter { $0 }.count
            let why = Set(s.joins.filter { $0.verdict != .allow }.flatMap(\.reasons)).map(\.rawValue).sorted()
            add("A8", .abandon, "While typing: join allows and the AX field object stays the same (>=90%)",
                ratioOK(allow, s.joins.count) && ratioOK(stable, s.elementStable.count) ? .pass : .fail,
                "allowed \(pct(allow, s.joins.count)), same element \(pct(stable, s.elementStable.count))" + (why.isEmpty ? "" : "; deny reasons \(why.joined(separator: ","))"))
        } else {
            add("A8", .abandon, "While typing: join allows and the AX field object stays the same (>=90%)", .notRun, "typing step not run")
        }

        // A9 150 ms budget (median); F7 (p90)
        var a9Parts: [String] = [], a9Fail = false, f7Fail = false, a9Any = false
        for id in allowSteps {
            guard let s = ran(id), let st = Stats.of(warm(s.joins).map(\.totalMs)) else { continue }
            a9Any = true
            if st.median > Harness.joinBudgetMs { a9Fail = true }
            if st.p90 > Harness.joinBudgetMs { f7Fail = true }
            a9Parts.append(String(format: "%@ %.0f/%.0f", id, st.median, st.p90))
        }
        add("A9", .abandon, "Warm full join median <= 150 ms (median/p90 ms per step)", a9Any ? (a9Fail ? .fail : .pass) : .notRun, a9Parts.joined(separator: ", "))

        // A10 Spotlight
        if let fs = ran("spotlight")?.focus {
            let g: Grade
            if fs.leaks > 0 { g = .fail }
            else if fs.panelWhileChromeFront > 0 { g = .pass }
            else if fs.focusElsewhereWhileChromeFront > 0 && fs.focusedBundles["com.apple.Spotlight"] != nil { g = .pass }
            else { g = .notRun }
            add("A10", .abandon, "Spotlight focus detected via system-wide focused app", g,
                "Spotlight on screen with Chrome frontmost: \(fs.panelWhileChromeFront) samples, missed \(fs.leaks); focus elsewhere seen \(fs.focusElsewhereWhileChromeFront)")
        } else {
            add("A10", .abandon, "Spotlight focus detected via system-wide focused app", .notRun, "spotlight step not run")
        }

        // A11 iframes
        var a11Parts: [String] = [], a11Fail = false, a11Missing = false
        for id in ["iframe-same", "iframe-cross"] {
            guard let s = ran(id), !s.joins.isEmpty else { a11Missing = true; a11Parts.append("\(id) not run"); continue }
            let distinct = s.joins.filter { $0.webAreaCount != 1 || ($0.nearestFrameVsTab != "same" && $0.nearestFrameVsTab != "unread") }.count
            let allowed = s.joins.filter { $0.verdict == .allow }.count
            if allowed > 0 || distinct < s.joins.count { a11Fail = true }
            a11Parts.append("\(id): web areas \(Set(s.joins.map(\.webAreaCount)).sorted().map(String.init).joined(separator: ",")), distinguishable \(pct(distinct, s.joins.count)), allowed \(allowed)")
        }
        add("A11", .abandon, "Fields inside iframes are told apart and denied", a11Fail ? .fail : (a11Missing ? .notRun : .pass), a11Parts.joined(separator: "; "))

        // A12 hidden password
        if let s = ran("password-hidden"), !s.joins.isEmpty {
            let secure = s.joins.filter { $0.secureInput || ($0.fieldSubrole ?? "").lowercased().contains("secure") }.count
            add("A12", .abandon, "Hidden password: secure subrole or macOS secure input", secure == s.joins.count ? .pass : .fail,
                "secure \(pct(secure, s.joins.count)); subrole \(Set(s.joins.compactMap(\.fieldSubrole)).sorted().joined(separator: ",")); secure input \(s.joins.filter(\.secureInput).count)")
        } else {
            add("A12", .abandon, "Hidden password: secure subrole or macOS secure input", .notRun, "password-hidden not run")
        }

        // A13 address bar
        if let s = ran("address-bar"), !s.joins.isEmpty {
            let allowed = s.joins.filter { $0.verdict == .allow }.count
            add("A13", .abandon, "Address bar is never accepted", allowed == 0 ? .pass : .fail,
                "allowed \(allowed)/\(s.joins.count); reasons \(Set(s.joins.flatMap(\.reasons)).map(\.rawValue).sorted().joined(separator: ","))")
        } else {
            add("A13", .abandon, "Address bar is never accepted", .notRun, "address-bar not run")
        }

        // A14 Incognito window closing behind a "Leave site?" dialog (review I1).
        // Apple Events may drop a closing window while it is still on screen.
        // Every join must then pause or stop before any content read.
        let a14Title = "Closing Incognito window (Leave site? dialog): every join pauses or stops before content"
        if let s = ran("incognito-closing"), let c = s.closing, c.dialogConfirmed == true, !s.joins.isEmpty {
            let safe = { (j: JoinReport) in j.verdict == .strictPause || (j.verdict == .deny && j.stoppedBeforeContent) }
            let unsafe = s.joins.filter { !safe($0) }.count
            let dropped = zip(s.joins, c.incognitoListed).filter { !$0.1 }.map(\.0)
            let reasons = Set(dropped.flatMap(\.reasons)).map(\.rawValue).sorted()
            var ev = c.aeDroppedMs.map { String(format: "Apple Events dropped the closing window after %.0f ms", $0) } ?? "the closing window stayed in the Apple Events list"
            ev += "; unsafe joins \(pct(unsafe, s.joins.count))"
            if !dropped.isEmpty { ev += "; after the drop: paused \(dropped.filter { $0.verdict == .strictPause }.count), stopped before content \(dropped.filter { $0.stoppedBeforeContent }.count) of \(dropped.count) [\(reasons.joined(separator: ","))]" }
            add("A14", .abandon, a14Title, unsafe == 0 ? .pass : .fail, ev)
        } else {
            let why = ran("incognito-closing") == nil ? "incognito-closing not run" : "the Leave site? dialog was not confirmed open until the Glass sound"
            add("A14", .abandon, a14Title, .notRun, why)
        }

        // F1 legacy descriptor
        if let d = ran("descriptor")?.descriptor {
            // The app already sends the abso form (0584e30). A failing enum form
            // confirms that fix was needed; a working one means it was harmless.
            add("F1", .fix, "Pre-fix first-window descriptor (enum form, 6f26d15 ChromeModeReader.swift:39)", d.legacyWorks ? .info : .pass,
                d.legacyWorks ? "enum form works too: the 0584e30 fix was harmless, not needed"
                    : "enum form fails (status \(d.firstLegacyEnumStatus)): confirms the 0584e30 abso fix was needed")
        } else {
            add("F1", .fix, "Pre-fix first-window descriptor (enum form, 6f26d15 ChromeModeReader.swift:39)", .notRun, "descriptor step not run")
        }

        // F2 shown password
        if let s = ran("password-shown"), !s.joins.isEmpty {
            let allowed = s.joins.filter { $0.verdict == .allow }.count
            let layers = [s.joins.contains { $0.secureInput } ? "secure input" : nil,
                          s.joins.contains { ($0.fieldSubrole ?? "").lowercased().contains("secure") } ? "secure subrole" : nil,
                          s.joins.contains { !($0.labelDeny ?? []).isEmpty } ? "label/id" : nil].compactMap { $0 }
            add("F2", .fix, "Shown password still denied by some layer", allowed == 0 ? .pass : .fix,
                "allowed \(allowed)/\(s.joins.count); layers: \(layers.isEmpty ? "none" : layers.joined(separator: ", "))\(f.probeLabels ? "" : " (labels not probed)")")
        } else {
            add("F2", .fix, "Shown password still denied by some layer", .notRun, "password-shown not run")
        }

        // F3 card / OTP labels
        var f3Parts: [String] = [], f3Fix = false, f3Missing = false
        for id in ["card", "otp"] {
            guard let s = ran(id), !s.joins.isEmpty else { f3Missing = true; f3Parts.append("\(id) not run\(f.probeLabels ? "" : " (needs --probe-labels)")"); continue }
            let denied = s.joins.filter { !($0.labelDeny ?? []).isEmpty }.count
            if denied < s.joins.count { f3Fix = true }
            f3Parts.append("\(id): label/id deny \(pct(denied, s.joins.count)) [\(Set(s.joins.flatMap { $0.labelDeny ?? [] }).sorted().joined(separator: ","))]")
        }
        add("F3", .fix, "Card and one-time-code fields denied by label or id", f3Fix ? .fix : (f3Missing ? .notRun : .pass), f3Parts.joined(separator: "; "))

        // F4 parent of the top web area
        let tops = allowSteps.compactMap { ran($0) }.flatMap(\.joins).filter { $0.webAreaCount == 1 }.compactMap(\.topWebAreaParentRole)
        add("F4", .fix, "Top AXWebArea's parent is AXScrollArea", tops.isEmpty ? .notRun : (Set(tops) == ["AXScrollArea"] ? .pass : .fix),
            "parents seen: \(Set(tops).sorted().joined(separator: ","))")

        // F5 light check
        if let s = ran("plain-input"), let st = Stats.of(s.lightMs) {
            add("F5", .fix, "Light per-key check p95 <= 30 ms", st.p95 <= Harness.lightCheckBudgetMs ? .pass : .fix,
                "\(st); still valid \(pct(s.lightOK, s.lightMs.count))")
        } else {
            add("F5", .fix, "Light per-key check p95 <= 30 ms", .notRun, "plain-input not run")
        }

        // F6 per-read budgets
        if let ae = f.aeReadStats, let ax = f.axReadStats {
            add("F6", .fix, "Per read p95: Apple Event <= 20 ms, AX <= 25 ms",
                ae.p95 <= Harness.aeEventBudgetMs && ax.p95 <= Harness.axReadBudgetMs ? .pass : .fix,
                String(format: "AE p95 %.1f max %.1f (n=%d); AX p95 %.1f max %.1f (n=%d)", ae.p95, ae.max, ae.count, ax.p95, ax.max, ax.count))
        } else {
            add("F6", .fix, "Per read p95: Apple Event <= 20 ms, AX <= 25 ms", .notRun, "no reads")
        }

        add("F7", .fix, "Warm full join p90 <= 150 ms", a9Any ? (f7Fail ? .fix : .pass) : .notRun, a9Parts.joined(separator: ", "))

        // F8 Chrome identity
        let major = f.chromeMajor ?? 0
        add("F8", .fix, "Chrome signature requirement passes and version >= 151",
            f.signatureOK == true && major >= Harness.minimumChromeMajor ? .pass : .fix,
            "signature \(f.signatureOK.map { $0 ? "ok" : "FAILED" } ?? "unchecked"), version \(f.chromeVersion ?? "unknown")")

        // F9 Apple Event reply types the app accepts (review C4). The harness
        // reads looser types; the app denies anything else, so a type outside
        // its set would make the app deny every key while this run passes.
        if let types = f.replyTypes, !types.isEmpty {
            var bad: [String] = [], parts: [String] = []
            for (kind, accepted) in Harness.appAcceptedReplyTypes.sorted(by: { $0.key < $1.key }) {
                let seen = Set(types[kind] ?? [])
                guard !seen.isEmpty else { continue }
                parts.append("\(kind) \(seen.sorted().joined(separator: "/"))")
                if !seen.isSubset(of: accepted) { bad.append("\(kind) \(seen.subtracting(accepted).sorted().joined(separator: "/")) (app accepts \(accepted.sorted().joined(separator: "/")))") }
            }
            add("F9", .fix, "Apple Event reply types are ones the app's decoder accepts", parts.isEmpty ? .notRun : (bad.isEmpty ? .pass : .fix),
                bad.isEmpty ? parts.joined(separator: ", ") : "outside the app's set: " + bad.joined(separator: "; "))
        } else {
            add("F9", .fix, "Apple Event reply types are ones the app's decoder accepts", .notRun, "no replies recorded")
        }

        // F10 web terminal input
        if let s = ran("terminal"), !s.joins.isEmpty {
            let denied = s.joins.filter { !($0.labelDeny ?? []).isEmpty }.count
            add("F10", .fix, "Web terminal input (xterm-like) denied by label, id or class", denied == s.joins.count ? .pass : .fix,
                "label/id/class deny \(pct(denied, s.joins.count)) [\(Set(s.joins.flatMap { $0.labelDeny ?? [] }).sorted().joined(separator: ","))]")
        } else {
            add("F10", .fix, "Web terminal input (xterm-like) denied by label, id or class", .notRun, "terminal not run\(f.probeLabels ? "" : " (needs --probe-labels)")")
        }

        // F11 zoomed twins: the same-frame rule is expected to deny (a known
        // usability cost). An allow means AXWindows did not show both windows.
        if let s = ran("two-windows-zoomed"), !s.joins.isEmpty {
            let twins = s.joins.compactMap(\.sameFrameWindows).max() ?? 0
            let denied = s.joins.filter { $0.reasons.contains(.sameFrameTwin) && $0.stoppedBeforeContent }.count
            let g: Grade = twins < 2 && denied == 0 ? .notRun : (denied == s.joins.count ? .pass : .fix)
            add("F11", .fix, "Two zoomed windows with one frame: denied before content (same-frame rule)", g,
                twins < 2 && denied == 0 ? "the windows did not share a frame; zoom both and re-run" : "denied \(pct(denied, s.joins.count)); allowed \(s.joins.filter { $0.verdict == .allow }.count) (typing in same-frame windows is not recorded)")
        } else {
            add("F11", .fix, "Two zoomed windows with one frame: denied before content (same-frame rule)", .notRun, "two-windows-zoomed not run")
        }

        // F12 a minimized window still pairs with its listed bounds.
        if let s = ran("minimized-window"), !s.joins.isEmpty {
            let allow = s.joins.filter { $0.verdict == .allow }.count
            let why = Set(s.joins.filter { $0.verdict != .allow }.flatMap(\.reasons)).map(\.rawValue).sorted()
            let two = (s.joins.map(\.windowCount).max() ?? 0) >= 2
            add("F12", .fix, "A minimized window does not block the window in use", two ? (ratioOK(allow, s.joins.count) ? .pass : .fix) : .notRun,
                two ? "allowed \(pct(allow, s.joins.count))" + (why.isEmpty ? "" : " [\(why.joined(separator: ","))]") : "only one window was listed")
        } else {
            add("F12", .fix, "A minimized window does not block the window in use", .notRun, "minimized-window not run")
        }

        // F13 many windows (review C5): join time and allows with 10 windows.
        if let s = ran("many-windows"), !s.joins.isEmpty {
            let n = s.joins.map(\.windowCount).max() ?? 0
            let allow = s.joins.filter { $0.verdict == .allow }.count
            if n < Harness.manyWindows {
                add("F13", .fix, "Ten windows: join p90 <= 150 ms and the field allowed", .notRun, "only \(n) windows were open")
            } else {
                let st = Stats.of(warm(s.joins).map(\.totalMs))
                let ok = (st?.p90 ?? .infinity) <= Harness.joinBudgetMs && ratioOK(allow, s.joins.count)
                add("F13", .fix, "Ten windows: join p90 <= 150 ms and the field allowed", ok ? .pass : .fix,
                    String(format: "%d windows: median %.0f p90 %.0f ms, %.0f Apple Events per join; allowed %@", n, st?.median ?? 0, st?.p90 ?? 0,
                           Double(s.joins.map(\.aeReads).reduce(0, +)) / Double(s.joins.count), pct(allow, s.joins.count)))
            }
        } else {
            add("F13", .fix, "Ten windows: join p90 <= 150 ms and the field allowed", .notRun, "many-windows not run")
        }

        // F14 native editors (review C10): the system-wide focused app the
        // native witness relies on equals the frontmost editor, and is fast.
        if let fs = ran("native-editors")?.focus, fs.nativeFront > 0 {
            let fast = (fs.focusReadStats?.p95 ?? 0) <= Harness.axReadBudgetMs
            add("F14", .fix, "TextEdit/Notes: system-wide focused app = frontmost app (>=90%), read p95 <= 25 ms",
                ratioOK(fs.nativeAgree, fs.nativeFront) && fast ? .pass : .fix,
                "agree \(pct(fs.nativeAgree, fs.nativeFront)) in \(fs.nativeFrontBundles.joined(separator: ",")); focus read \(fs.focusReadStats.map(\.description) ?? "-")")
        } else {
            add("F14", .fix, "TextEdit/Notes: system-wide focused app = frontmost app (>=90%), read p95 <= 25 ms", .notRun, "native-editors not run, or TextEdit/Notes never frontmost")
        }

        // A15 (fix/web-textbox): a password `<input role=combobox>` (box 13, no label). Chromium reports it as
        // AXComboBox, possibly with no secure subrole; the guard is macOS secure input (Chrome turns it on for
        // any password input), and every join must deny.
        if let s = ran("password-combo"), !s.joins.isEmpty {
            let secure = s.joins.filter { $0.secureInput || ($0.fieldSubrole ?? "").lowercased().contains("secure") }.count
            let allowed = s.joins.filter { $0.verdict == .allow }.count
            add("A15", .abandon, "Password input with role=combobox: macOS secure input (or a secure subrole), never accepted",
                secure == s.joins.count && allowed == 0 ? .pass : .fail,
                "secure \(pct(secure, s.joins.count)); allowed \(allowed); role \(Set(s.joins.compactMap(\.fieldRole)).sorted().joined(separator: ",")); subrole \(Set(s.joins.compactMap(\.fieldSubrole)).sorted().joined(separator: ",")); secure input \(s.joins.filter(\.secureInput).count)")
        } else {
            add("A15", .abandon, "Password input with role=combobox: macOS secure input (or a secure subrole), never accepted", .notRun, "password-combo not run")
        }
        // F15 (fix/web-textbox): an unlabelled search box with suggestions (`<input role=combobox>`, box 12) is
        // AXComboBox and its own editable root, so it is accepted like the app accepts it.
        if let s = ran("combo-input"), !s.joins.isEmpty {
            let own = s.joins.filter { $0.fieldRole == "AXComboBox" && $0.fieldEditableSelf == true }.count
            let allowed = s.joins.filter { $0.verdict == .allow }.count
            add("F15", .fix, "Unlabelled search box (input role=combobox) is AXComboBox, its own editable root, and accepted",
                ratioOK(own, s.joins.count) && ratioOK(allowed, s.joins.count) ? .pass : .fix,
                "role \(Set(s.joins.compactMap(\.fieldRole)).sorted().joined(separator: ",")); own editable root \(pct(own, s.joins.count)); allowed \(pct(allowed, s.joins.count))")
        } else {
            add("F15", .fix, "Unlabelled search box (input role=combobox) is AXComboBox, its own editable root, and accepted", .notRun, "combo-input not run")
        }

        // Info
        if let w = ran("plain-input")?.warmupMs {
            add("I1", .info, "Chrome accessibility warm-up (first read until a web area appears)", .info, String(format: "%.0f ms", w))
        }
        let titles = Set(allowSteps.compactMap { ran($0) }.flatMap(\.joins).map(\.titleMatch.rawValue)).sorted()
        if !titles.isEmpty { add("I2", .info, "AX title vs Apple Events window name", .info, titles.joined(separator: ",")) }
        if let d = ran("descriptor")?.descriptor {
            add("I3", .info, "Apple Events reply types (list, bounds)", .info, "\(d.listReplyType ?? "?"), \(d.boundsRawType ?? "?")")
        }
        return out
    }

    public static func overall(_ c: [CriterionResult]) -> String {
        // A gate that could not be measured (G4 in an --only run) does not
        // invalidate; the missing abandon criteria make the run INCOMPLETE.
        if c.contains(where: { $0.severity == .gate && $0.grade == .fail }) {
            return "RUN INVALID: a gate did not pass. Fix it and run again; these results don't count."
        }
        let abandon = c.filter { $0.severity == .abandon && $0.grade == .fail }.map(\.id)
        if !abandon.isEmpty {
            return "ABANDON (\(abandon.joined(separator: ", "))): stop Chrome typing work until after launch (plan section 6, row 7)."
        }
        let missing = c.filter { $0.severity == .abandon && $0.grade == .notRun }.map(\.id)
        if !missing.isEmpty { return "INCOMPLETE: \(missing.joined(separator: ", ")) not run. Re-run those steps with --only." }
        let fixes = c.filter { $0.grade == .fix }.map(\.id)
        return "CONTINUE: no abandon criterion failed." + (fixes.isEmpty ? "" : " Fix while building: \(fixes.joined(separator: ", ")).")
    }
}

extension Criteria {
    /// fix/web-textbox: the app's text boxes (`ChromeAXAccess.textBox`): a
    /// text field, a text area, or a combo box that is its own editable root.
    static func textBox(_ j: JoinReport) -> Bool { textRoles.contains(j.fieldRole ?? "") || (j.fieldRole == "AXComboBox" && j.fieldEditableSelf == true) }
}
