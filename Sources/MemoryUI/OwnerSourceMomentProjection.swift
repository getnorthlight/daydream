import Foundation
import MemoryCore

/// Pure projections of already-filtered, selected owner previews. No hydration,
/// persistence, model input or cross-moment cache lives here.
enum OwnerSourceMomentProjection {
    enum Section: String, CaseIterable { case summary, whatHappened }
    static let sectionOrder: [Section] = [.summary, .whatHappened]
    static let excerptLimit = 5
    static let excerptCharacterLimit = 160
    /// The longest source a summary stand-in quotes (the owner source bound before claude/terminal-details-1003).
    static let standInSourceLimit = 400
    struct Excerpt: Identifiable, Equatable {
        let id: String
        let at: String
        let lead: String
        let label: String
        let text: String
    }
    /// One merged excerpt per observed run; exact repeats appear once, newest first.
    /// Summary excerpts never decide which historical actions or parts are shown.
    static func standIn(_ previews: [OwnerSourcePreview], actions: [CanonicalAction] = []) -> [Excerpt] {
        var seen = Set<String>()
        var shown = Set<String>()
        let times = Dictionary(actions.map { ($0.id, $0.at) }, uniquingKeysWith: { first, _ in first })
        func latest(_ preview: OwnerSourcePreview) -> String {
            preview.actionIDs.compactMap { times[$0] }.max() ?? preview.at
        }
        return previews.sorted { (latest($0), $0.id) > (latest($1), $1.id) }.compactMap { preview in
            guard preview.runID != nil, !preview.parts.isEmpty else { return nil }
            let words = preview.parts.map(\.text).joined(separator: "\n")
            // claude/terminal-details-1003: the detail now opens whole prompts; a stand-in still quotes short sources only.
            guard words.count <= standInSourceLimit else { return nil }
            let normalized = words.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            let short = words.count <= excerptCharacterLimit ? words
                : String(words.prefix(excerptCharacterLimit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
            // Long requests with the same visible prefix share an excerpt; their
            // complete, different captured wording still has separate history rows.
            let visible = short.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            guard shown.insert(visible).inserted else { return nil }
            let app = preview.lead.lowercased()
            let aiOrTerminal = ["ghostty", "terminal", "iterm", "claude", "chatgpt", "codex"]
                .contains { app.contains(" in " + $0) }
            let label = aiOrTerminal && preview.state == "submitted" ? "Asked:" : "Wrote:"
            return Excerpt(id: preview.id, at: latest(preview), lead: preview.lead, label: label, text: short)
        }.prefix(excerptLimit).map { $0 }
    }
    static func summaryExcerpts(_ previews: [OwnerSourcePreview], modelReady: Bool, actions: [CanonicalAction] = []) -> [Excerpt] {
        modelReady ? [] : standIn(previews, actions: actions)
    }
    /// Every real action gets its own chronological row, even thirteen prompts in
    /// the same terminal. A repeated request remains a real history event.
    static func history(_ actions: [CanonicalAction], previews: [OwnerSourcePreview], typed: MomentTypedLoad = .empty) -> [MomentDetailEntry] {
        var captured = [String: (String, String)]()
        var withheld = [String: String]()
        for preview in previews {
            for part in preview.parts { captured[part.actionID] = (part.text, part.state) }
            if let reason = preview.withheldReason, let id = preview.actionIDs.first { withheld[id] = reason }
        }
        let legacyBlocks = Dictionary(typed.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return actions.sorted { (timestamp($0.at) ?? .distantPast, $0.id) < (timestamp($1.at) ?? .distantPast, $1.id) }
            .filter { $0.kind != "idle" && !($0.app.isEmpty && $0.bundle.isEmpty && $0.site.isEmpty) }
            .map { action in
                let app = AppNames.display(app: action.app, bundle: action.bundle)
                let host = action.site.isEmpty ? "" : KitBrowsers.host(action.site)
                // A withheld title is named by its app or site, never "[sensitive title omitted]" row after row.
                let title = TerminalTitle.display(action.title.isEmpty || action.title == MomentHistoryCondense.withheldTitle
                    ? (host.isEmpty ? app : host) : action.title, bundle: action.bundle, app: app)
                let wording = captured[action.id]
                let blocks = wording.map { words in [MomentTypedBlock(id: action.id, at: action.at,
                    app: app, bundle: action.bundle, host: host, title: title, text: words.0,
                    send: words.1 == "submitted" ? "Submission observed" : "Drafted text")] }
                    ?? legacyBlocks[action.id].map { [$0] } ?? []
                // page-links-1003 (owner 10/03): a page shows its short link ("youtube.com/watch…"), else its site, and a page
                // view says nothing more: "Observed <title> on <site>" only said the title again.
                let place = action.link.flatMap(BrowserSites.shortLink) ?? host
                let location = host.isEmpty ? (app == title ? "" : app) : (place == title ? "" : place)
                // The evidence hedges ("reading is not established") stay internal (owner 10/2): the detail says it plainly.
                let operation = MomentHistoryCondense.pageView(action) ? ""
                    : action.description.isEmpty ? action.kind.replacingOccurrences(of: ".", with: " ")
                    : MomentHistoryCondense.plain(action.description, app: app)
                var entry = MomentDetailEntry(id: action.id, bundle: action.bundle, app: app, host: host, title: title,
                    detail: [location, operation].filter { !$0.isEmpty }.joined(separator: " · "),
                    first: timestamp(action.at), last: timestamp(action.at), actionIDs: [action.id],
                    openActionID: host.isEmpty ? nil : action.id,
                    sends: typed.sends[action.id].map { [$0] } ?? [], typed: blocks)
                entry.link = host.isEmpty ? nil : action.link
                // claude/terminal-details-1003: only a privacy reason is shown (owner 10/03), never a default "unavailable".
                entry.withheldReason = action.kind == "keyboard.text_input" && blocks.isEmpty ? withheld[action.id] : nil
                entry.capturedWordingUnavailable = entry.withheldReason != nil
                return entry
            }
    }
}

/// The expanded card's condensed "What happened" and its plain words (owner 10/2). `history` stays one entry per real
/// action (the pushed detail and the checks read it); the card shows this: runs of views, clicks and app switches in one
/// app and window become one line with counts and a time range, identical lines never repeat, typed, sent and drafted
/// rows keep their own lines and their quoted blocks, and the evidence hedges ("reading is not established") stay
/// internal. Every action stays reachable: each line keeps the IDs of all the actions it stands for.
enum MomentHistoryCondense {
    /// What `MemoryCore` writes for a title it withholds.
    static let withheldTitle = "[sensitive title omitted]"
    /// Looking at a window or page.
    static let viewKinds: Set<String> = ["window.changed", "window.observed", "focus.observed", "browser.snapshot",
                                         "browser.observed", "browser.extension_observed", "browser.extension_tab_visited",
                                         "browser.tab_visited", "browser.tab_opened"]
    static let clickKinds: Set<String> = ["mouse.click"]
    static let rightClickKinds: Set<String> = ["mouse.context_menu"]
    static let switchKinds: Set<String> = ["app.activated"]
    static var passiveKinds: Set<String> { viewKinds.union(clickKinds).union(rightClickKinds).union(switchKinds) }

    /// page-links-1003: a page seen in a browser (a page row: its description only repeats the page's title and site).
    static func pageView(_ a: CanonicalAction) -> Bool { a.kind == "window.changed" && !a.site.isEmpty }

    /// The evidence hedges, said plainly or not at all. A description keeps what happened ("Pressed Return").
    static func plain(_ description: String, app: String) -> String {
        var text = description
        for hedge in ["; submission and reading are not established", "; reading is not established",
                      "; sending is not established", "; authorship is not established",
                      " Authorship and completion are not established."] {
            text = text.replacingOccurrences(of: hedge, with: "")
        }
        for (from, to) in [("Recorded a mouse click", "Clicked"), ("Recorded a keyboard shortcut", "Used a keyboard shortcut"),
                           ("Recorded a Return key press", "Pressed Return"), ("Recorded an app activation in", "Switched to")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        text = text.replacingOccurrences(of: withheldTitle + " ", with: "").replacingOccurrences(of: withheldTitle, with: "")
        // The entry already names its app: "Pressed Return in ChatGPT." is "Pressed Return".
        if !app.isEmpty, text.hasSuffix(" in " + app + ".") { text = String(text.dropLast(app.count + 5)) }
        else if !app.isEmpty, text.hasSuffix(" in " + app) { text = String(text.dropLast(app.count + 4)) }
        while text.hasSuffix(".") { text.removeLast() }
        if text.hasPrefix("Observed ") {
            text = String(text.dropFirst(9)); text = text.prefix(1).uppercased() + text.dropFirst()
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Apps whose Return runs a command.
    static let terminalBundles: Set<String> = ["com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2",
                                               "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper"]

    /// A line of its own: what was typed, sent or drafted (with its words), a command run (Return in a terminal), a
    /// Return elsewhere, a page visit. Views, clicks, shortcuts and app switches are not.
    static func signal(_ e: MomentDetailEntry, kinds: [String: String]) -> Bool {
        if !e.typed.isEmpty || !e.sends.isEmpty || e.capturedWordingUnavailable || e.isWeb || e.message != nil { return true }
        return e.actionIDs.contains { !passiveKinds.contains(kinds[$0] ?? "") && kinds[$0] != "keyboard.shortcut" && kinds[$0] != "idle" }
    }

    /// The quiet line for a run of noise in one app: "Worked in Terminal", "4 min · 5:14–5:18 PM".
    static func workedLine(_ run: [MomentDetailEntry], timeZone: TimeZone) -> MomentDetailEntry {
        let head = run[0]
        let first = run.compactMap(\.first).min(), last = run.compactMap(\.last).max()
        var detail = ""
        if let first, let last {
            let minutes = DaydreamFormat.duration(from: first, to: last)
            let range = DaydreamFormat.range(first, last, timeZone)
            detail = [minutes, range == DaydreamFormat.time(first, timeZone) ? nil : range].compactMap { $0 }.joined(separator: " · ")
        }
        let app = head.app.isEmpty ? (head.host.isEmpty ? "an app" : head.host) : head.app
        var e = MomentDetailEntry(id: "worked:" + head.id, bundle: head.bundle, app: head.app, host: "", title: "Worked in " + app,
            detail: detail, first: first, last: last, actionIDs: run.flatMap(\.actionIDs), openActionID: nil, sends: [], typed: [])
        e.quiet = true
        return e
    }

    /// The card's What happened (owner 10/2, after the mockup): signal only. Typed, sent and drafted rows (with their
    /// blocks), commands run, Returns and page visits keep their own lines; every other run in one app is ONE quiet
    /// line, "Worked in Terminal · 4 min". A card with nothing but noise is that one line. Identical neighbouring
    /// lines say it once ("3 times"). Every line keeps the IDs of all the actions it stands for.
    static func lines(_ entries: [MomentDetailEntry], actions: [CanonicalAction], timeZone: TimeZone,
                      compose: [String: ComposeLine] = [:]) -> [MomentDetailEntry] {
        let kinds = Dictionary(actions.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        let descriptions = Dictionary(actions.map { ($0.id, $0.description) }, uniquingKeysWith: { first, _ in first })
        // `history` already cleaned terminal titles; a withheld title is its app.
        func title(_ e: MomentDetailEntry) -> String {
            e.title == withheldTitle || e.title.isEmpty ? (e.app.isEmpty ? e.host : e.app) : e.title
        }
        let byID = Dictionary(actions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func plainDetail(_ e: MomentDetailEntry) -> String {
            // page-links-1003: a page's short link, else its site; never the title again.
            let location = e.host.isEmpty ? (e.app == title(e) ? "" : e.app) : (e.place == title(e) ? "" : e.place)
            // claude/int-1002: terminal-1002 saves a line run with Return as a submitted unit described "Ran a command in
            // <app> (<bucket>)."; it is a command like a bare Return, and both read `TypedWords.ranCommandLabel`.
            let ran = TypedWords.ranCommandLabel + " in "
            let command = terminalBundles.contains(e.bundle) && !e.actionIDs.isEmpty
                && e.actionIDs.allSatisfy { kinds[$0] == "keyboard.submit" || (descriptions[$0]?.hasPrefix(ran) ?? false) }
            let view = e.actionIDs.first.flatMap { byID[$0] }.map(pageView) ?? false
            let what = command ? TypedWords.ranCommandLabel : view ? ""
                : e.actionIDs.first.flatMap { descriptions[$0] }.map { plain($0, app: e.app) } ?? ""
            return [location, what].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        var out: [MomentDetailEntry] = []
        var run: [MomentDetailEntry] = []
        func flush() { if !run.isEmpty { out.append(workedLine(run, timeZone: timeZone)); run = [] } }
        // Owner 10/3: Messages typed units are message lines ("Sent to Jamie", its words; no "Pressed Return" row for a send;
        // a message typed in pieces is one line and one quote). `MessagesTypedFold`.
        // claude/cc-label-1003 (owner 10/03): a terminal line's compose outcome is "Ran a command" (surface "code") or a
        // draft, whatever ran in the window, so a prompt to Claude Code read "Ran a command" with its time twice.
        // Terminal lines are MomentDetailFold's (one line per Return, "Asked Claude Code" / "Ran a command").
        let bundles = Dictionary(actions.map { ($0.id, $0.bundle) }, uniquingKeysWith: { first, _ in first })
        let compose = compose.filter { !terminalBundles.contains(bundles[$0.key] ?? "") }
        for e in MessagesTypedFold.fold(entries, actions: actions, compose: compose) {
            if e.message != nil { flush(); out.append(e); continue }
            if signal(e, kinds: kinds) {
                flush()
                var line = MomentDetailEntry(id: e.id, bundle: e.bundle, app: e.app, host: e.host, title: title(e),
                    detail: plainDetail(e), first: e.first, last: e.last, actionIDs: e.actionIDs,
                    openActionID: e.openActionID, sends: e.sends, typed: e.typed)
                line.capturedWordingUnavailable = e.capturedWordingUnavailable
                line.link = e.link
                out.append(line)
            } else {
                if let head = run.first, head.bundle + "|" + head.app != e.bundle + "|" + e.app { flush() }
                run.append(e)
            }
        }
        flush()
        // Identical neighbouring signal lines (no words of their own) say it once, with how many times.
        var result: [MomentDetailEntry] = []
        func base(_ detail: String) -> String {
            detail.components(separatedBy: " · ").filter { !$0.hasSuffix(" times") && !$0.contains("\u{2013}") }.joined(separator: " · ")
        }
        func repeatable(_ e: MomentDetailEntry) -> Bool { !e.quiet && e.typed.isEmpty && e.sends.isEmpty && !e.capturedWordingUnavailable && e.message == nil }
        for e in out {
            if let last = result.last, repeatable(last), repeatable(e), last.title == e.title, last.bundle == e.bundle, last.host == e.host,
               last.link == e.link, base(last.detail) == base(e.detail) {
                let ids = last.actionIDs + e.actionIDs, n = ids.count
                let first = [last.first, e.first].compactMap { $0 }.min(), lastAt = [last.last, e.last].compactMap { $0 }.max()
                let range = first.flatMap { f in lastAt.map { DaydreamFormat.range(f, $0, timeZone) } }
                var merged = MomentDetailEntry(id: last.id, bundle: last.bundle, app: last.app, host: last.host, title: last.title,
                    detail: ([base(last.detail), "\(n) times"] + (range.map { [$0] } ?? [])).filter { !$0.isEmpty }.joined(separator: " · "),
                    first: first, last: lastAt, actionIDs: ids, openActionID: e.openActionID ?? last.openActionID, sends: [], typed: [])
                merged.capturedWordingUnavailable = false
                merged.link = e.link
                result[result.count - 1] = merged
            } else {
                result.append(e)
            }
        }
        return MomentDetailFold.fold(result, entries: entries, actions: actions, timeZone: timeZone)
    }
}

/// Terminal window titles as people read them (owner 10/2): "fixture-user — -zsh — 120×30" says nothing. The user name,
/// the size and the login shell's leading "-" go; the line is "zsh · ~/folder" when the folder is in the title, else the
/// app's name, unless TitleClean's terminal rule finds a name (a tool's session title). Other apps' titles pass through.
enum TerminalTitle {
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "tcsh", "ksh", "nu", "login"]

    static func display(_ title: String, bundle: String, app: String, user: String = NSUserName()) -> String {
        guard MomentHistoryCondense.terminalBundles.contains(bundle) else { return title }
        let fallback = app.isEmpty ? "Terminal" : app
        if title.isEmpty || title.contains(MomentHistoryCondense.withheldTitle) { return fallback }
        var parts = title.components(separatedBy: CharacterSet(charactersIn: "\u{2014}\u{2013}"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count == 1 { parts = title.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) } }
        // Spinner and bell marks some shells put first ("◐ ", "* ", "🔔 ").
        parts = parts.map { p in
            var t = p
            while let c = t.unicodeScalars.first, !(CharacterSet.alphanumerics.contains(c) || "~/-.".unicodeScalars.contains(c)) {
                t = String(t.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            return t
        }.filter { !$0.isEmpty }
        var folder: String?, command: String?
        for p in parts {
            if p.range(of: #"^\d+\s*[×x]\s*\d+$"#, options: .regularExpression) != nil { continue }
            if !user.isEmpty, p == user { continue }
            // "user@host: ~/x" or "user@host:~/x"
            if let colon = p.firstIndex(of: ":"), p[..<colon].contains("@") {
                let rest = p[p.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("~") || rest.hasPrefix("/") { folder = folder ?? rest }
                continue
            }
            if p.hasPrefix("~") || p.hasPrefix("/") { folder = folder ?? p; continue }
            var c = p
            while c.hasPrefix("-") { c.removeFirst() }
            if c.isEmpty { continue }
            // The shell wins over a bare first word (the user or folder name Terminal puts first).
            if shells.contains(c.lowercased()) { command = c } else if command == nil { command = c }
        }
        // claude/int-1002: no folder: TitleClean's terminal rule (ready-1002), so a tool's session title ("✳ Daydream app
        // design review", "claude --resume" -> "Claude Code") reads the same here as in summaries; a bare shell or the
        // account name is "", the app's name.
        guard let folder else {
            let named = TitleClean.terminalName(title, user: user.isEmpty ? nil : user)
            return named.isEmpty ? fallback : named
        }
        return [command, folder].compactMap { $0 }.joined(separator: " · ")
    }
    /// The folder a terminal title shows ("~/Projects/tally"), else nil.
    static func folder(_ title: String, bundle: String, user: String = NSUserName()) -> String? {
        let shown = display(title, bundle: bundle, app: "\u{0}", user: user)
        guard shown != "\u{0}", MomentHistoryCondense.terminalBundles.contains(bundle) else { return nil }
        return shown.components(separatedBy: " · ").last
    }
}

/// A card title never shows a withheld title (owner 10/2: "[sensitive title omitted] code"), nor a terminal's raw window
/// title: its summary line, else its apps' names.
enum CardTitle {
    static let withheld = [MomentHistoryCondense.withheldTitle, "[sensitive app omitted]"]
    static func safe(_ raw: String, moment m: MomentSlice) -> String {
        var title = raw
        if withheld.contains(where: { title.contains($0) }) {
            let line = m.bullets.first { !$0.correction }?.text ?? m.firstBullet ?? m.live?.sends.first
            if let line, !line.isEmpty, !withheld.contains(where: { line.contains($0) }) { return MenuBarMenu.sentence(line) }
            let names = m.apps.filter { !$0.isEmpty && !DaydreamAppDirectory.looksLikeBundleID($0) }
            return names.isEmpty ? (m.primaryApp ?? "Activity") : names.joined(separator: ", ")
        }
        if let bundle = m.primaryBundle ?? m.bundles.first, MomentHistoryCondense.terminalBundles.contains(bundle) {
            title = TerminalTitle.display(title, bundle: bundle, app: m.primaryApp ?? m.apps.first ?? "")
        }
        return title
    }
}

/// The expanded card's Summary, only when it says something (owner 10/2: a Terminal card's Summary said only "~1 min").
enum MomentSummaryWorth {
    /// A line that says only how long (and maybe which app): "~1 min", "Terminal, ~1 min", "About 5 minutes".
    static func isFiller(_ line: String, names: [String]) -> Bool {
        var text = line.lowercased()
        for name in names where !name.isEmpty { text = text.replacingOccurrences(of: name.lowercased(), with: " ") }
        let pattern = #"(~|about|around|roughly|nearly|almost|over|under|less than|a few|few|an?|\d+(\.\d+)?|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s|and|open|had|in|for|[\s,.;:·•\-–—()])+"#
        guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$") else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return text.trimmingCharacters(in: .whitespaces).isEmpty || regex.firstMatch(in: text, range: range) != nil
    }

    /// What the card's summary area draws: a "Summary" header only over a real summary or a status; captured wording
    /// (excerpts) is never labelled Summary; lines that only say how long become one factual line with no header.
    struct Shape: Equatable { let header: Bool; let factual: Bool }
    static func shape(excerpts: Bool, status: Bool, corrections: Bool, lines: [String], names: [String]) -> Shape {
        if excerpts { return Shape(header: false, factual: false) }
        if status { return Shape(header: true, factual: false) }
        let informative = lines.contains { !isFiller($0, names: names) }
        if informative { return Shape(header: true, factual: false) }
        return Shape(header: corrections, factual: true)
    }

    /// The one factual line in place of a filler summary: "Terminal · 12 views over 5 min", from the actions read
    /// (their kinds); before they are read, the moment's own count.
    static func factualLine(app: String, actions: [CanonicalAction], actionCount: Int, start: Date, end: Date) -> String {
        let kinds = actions.map(\.kind)
        func n(_ set: Set<String>) -> Int { kinds.filter { set.contains($0) }.count }
        let views = n(MomentHistoryCondense.viewKinds), clicks = n(MomentHistoryCondense.clickKinds)
        let switches = n(MomentHistoryCondense.switchKinds)
        let typed = kinds.filter { $0 == "keyboard.text_input" }.count
        var counts: [String] = []
        if actions.isEmpty {
            counts.append(actionCount == 1 ? "1 action" : "\(actionCount) actions")
        } else {
            if views > 0 { counts.append(views == 1 ? "1 view" : "\(views) views") }
            if typed > 0 { counts.append(typed == 1 ? "typed once" : "typed \(typed) times") }
            if clicks > 0 { counts.append(clicks == 1 ? "1 click" : "\(clicks) clicks") }
            if switches > 0 { counts.append(switches == 1 ? "1 switch" : "\(switches) switches") }
            let other = actions.count - views - clicks - switches - typed
            if counts.isEmpty { counts.append(actions.count == 1 ? "1 action" : "\(actions.count) actions") }
            else if other > 0 { counts.append(other == 1 ? "1 other action" : "\(other) other actions") }
        }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded(.down))
        let over = minutes < 1 ? "in under a minute" : minutes < 60 ? "over \(minutes) min"
            : "over " + (DaydreamFormat.duration(end.timeIntervalSince(start)) ?? "\(minutes) min")
        return [app, counts.joined(separator: ", ") + " " + over].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
