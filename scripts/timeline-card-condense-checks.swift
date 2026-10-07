import Foundation
import SwiftUI
@testable import MemoryCore
@testable import MemoryUI
import PrivacyPolicy

/// The timeline card feedback (owner 10/2, Main.dc.html): one card per app in a bracket, writing-first summary bullets,
/// the side panel, the condensed What happened, and no filler Summary. Fictional, screenshot-shaped fixtures; projections and source pins
/// only. No app, window, view hosting, model, capture or owner data.
@main @MainActor enum TimelineCardCondenseChecks {
    static var checks = 0
    static func require(_ ok: Bool, _ reason: String, _ got: @autoclosure () -> String = "") {
        guard ok else { FileHandle.standardError.write(Data("FAIL: \(reason) \(got())\n".utf8)); exit(1) }
        checks += 1
    }
    static let tz = TimeZone(identifier: "America/Chicago")!
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c }
    static func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: h, minute: m, second: s))!
    }
    static func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    /// A real projection of fictional evidence, so the wording is the store's own.
    static func action(_ id: String, _ when: Date, _ kind: String, app: String, bundle: String, title: String, text: String = "") -> CanonicalAction {
        ActionProjection.make(Evidence(id: id, at: iso(when), kind: kind, app: app, bundle: bundle, title: title, text: text, synthetic: true))
    }

    static func main() {
        chatGPT()
        terminal()
        summaryWorth()
        messagesCard()
        terminalCard()
        chatGPTCard()
        newestAskCard()
        grouping()
        oldDayBracket()
        capturedWording()
        askLines()
        messagesFold()
        textsVerbatim()
        composeLines()
        cardLayout()
        redraws()
        footer()
        print("PASS: timeline-card-condense \(checks) checks; fictional fixtures, no windows")
    }

    /// ChatGPT: views and clicks alternating, an app switch, a typed ask, Return, then more views and clicks.
    static func chatGPT() {
        let app = "ChatGPT", bundle = "com.openai.chat"
        var actions: [CanonicalAction] = []
        var i = 0
        func add(_ when: Date, _ kind: String, title: String = "ChatGPT", text: String = "") {
            actions.append(action("c\(i)", when, kind, app: app, bundle: bundle, title: title, text: text)); i += 1
        }
        add(at(11, 37, 0), "app.activated")
        add(at(11, 37, 5), "window.changed")
        add(at(11, 37, 10), "mouse.click")
        add(at(11, 37, 20), "window.changed")
        add(at(11, 37, 30), "keyboard.shortcut")
        add(at(11, 37, 40), "mouse.click")
        add(at(11, 38, 10), "mouse.click")
        add(at(11, 38, 20), "keyboard.text_input", text: "Fictional question about parsers")
        add(at(11, 38, 21), "keyboard.submit")
        add(at(11, 39, 0), "window.changed")
        add(at(11, 42, 30), "mouse.click")
        let typedID = actions[7].id
        let typed = MomentTypedLoad(sends: [typedID: "Asked ChatGPT"], blocks: [MomentTypedBlock(id: typedID, at: actions[7].at, app: app,
            bundle: bundle, host: "", title: "ChatGPT", text: "Fictional question about parsers", send: "Asked ChatGPT")])
        let raw = OwnerSourceMomentProjection.history(actions, previews: [], typed: typed)
        require(raw.count == actions.count, "history keeps one entry per real action (the pushed detail)")
        require(actions.contains { $0.description.contains("reading is not established") }, "fixture: the stored descriptions carry the hedges the owner saw")
        require(!raw.contains { $0.detail.contains("not established") }, "the pushed detail's one-per-action rows drop the hedges too")
        let lines = MomentHistoryCondense.lines(raw, actions: actions, timeZone: tz)
        let text = lines.map { $0.title + " | " + $0.detail }
        // claude/terminal-details-1003 (owner 10/03): views, clicks and switches in the same app fold into the ask, and
        // the Return right after it is its send: ONE line, at the ask's own time.
        require(lines.count == 1, "ChatGPT: the ask is one line; no worked lines and no Return row beside it", "\(text)")
        require(lines[0].typed.map(\.text) == ["Fictional question about parsers"] && lines[0].sends == ["Asked ChatGPT"] && !lines[0].quiet,
                "the typed ask keeps its line and its quoted block")
        require(lines[0].first == at(11, 38, 20), "the line keeps the ask's time")
        let all = text.joined()
        require(!all.contains("not established") && !all.contains("click") && !all.contains("views") && !all.contains("switched"),
                "no evidence jargon and no counts on the card", "\(text)")
        require(Set(lines.flatMap(\.actionIDs)) == Set(actions.map(\.id)) && lines.flatMap(\.actionIDs).count == actions.count,
                "every real action stays reachable exactly once")
    }

    /// Terminal: 12 identical views of a withheld title, then commands.
    static func terminal() {
        let actions = (0..<12).map { n in
            action("t\(n)", at(14, 0 + n / 3, (n % 3) * 20), "window.changed", app: "Terminal", bundle: "com.apple.Terminal",
                   title: MomentHistoryCondense.withheldTitle)
        }
        let raw = OwnerSourceMomentProjection.history(actions, previews: [])
        require(raw.count == 12 && actions.allSatisfy { $0.description.contains("[sensitive title omitted]") }, "fixture: twelve identical withheld rows")
        require(!raw.contains { ($0.title + $0.detail).contains("sensitive title omitted") }, "the pushed detail never repeats the placeholder")
        let lines = MomentHistoryCondense.lines(raw, actions: actions, timeZone: tz)
        require(lines.count == 1, "a card with nothing but noise is one line", "\(lines.map(\.detail))")
        require(lines[0].title == "Worked in Terminal" && lines[0].detail == "3m · 2:00\u{2013}2:03 PM", "Worked in Terminal · how long",
                lines[0].title + " | " + lines[0].detail)
        require(lines[0].actionIDs.count == 12, "all twelve actions stay behind the line")
        // Its summary was "~1 min": no Summary header, one factual line.
        let shape = MomentSummaryWorth.shape(excerpts: false, status: false, corrections: false, lines: ["~1 min"], names: ["Terminal"])
        require(shape == .init(header: false, factual: true), "a duration-only summary gets no Summary header")
        let line = MomentSummaryWorth.factualLine(app: "Terminal", actions: actions, actionCount: 12, start: at(14, 0), end: at(14, 5))
        require(line == "Terminal · 12 views over 5 min", "the factual line", line)
        // Commands: Return in a terminal is "Ran a command", each its own line; identical neighbours say it once.
        let title = "fixture-user \u{2014} -zsh \u{2014} ~/Projects/tally \u{2014} 120\u{00D7}30"
        let returns = (0..<3).map { n in action("r\(n)", at(15, n), "keyboard.submit", app: "Terminal", bundle: "com.apple.Terminal", title: title) }
        let returnLines = MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(returns, previews: []), actions: returns, timeZone: tz)
        require(returnLines.count == 1 && returnLines[0].detail == "Terminal · Ran a command · 3 times · 3:00\u{2013}3:02 PM",
                "three identical command lines are one", returnLines.map { $0.title + " | " + $0.detail }.joined(separator: " / "))
        require(!returnLines[0].title.contains("fixture-user") && !returnLines[0].title.contains("120"), "the terminal title is cleaned", returnLines[0].title)
        // claude/int-1002: terminal-1002 saves the line a Return ran as a submitted unit ("Ran a command in Terminal (…)."):
        // the card says TypedWords.ranCommandLabel for it too, never "Typed in" or the bucket.
        var ran = action("ran", at(16, 0), "keyboard.text_input", app: "Terminal", bundle: "com.apple.Terminal", title: title)
        ran.description = TypedWords.ranDescription(app: "Terminal", words: 3)
        let ranLines = MomentHistoryCondense.lines(OwnerSourceMomentProjection.history([ran], previews: []), actions: [ran], timeZone: tz)
        require(ranLines.count == 1 && ranLines[0].detail.contains(TypedWords.ranCommandLabel) && !ranLines[0].detail.contains("words"),
                "a typed line run with Return is \"Ran a command\"", ranLines.map(\.detail).joined(separator: " / "))
        require(FocusAppCard.sentences(ranLines, start: at(16, 0), end: at(16, 0)) == ["Ran a command in Terminal."],
                "its What happened sentence", FocusAppCard.sentences(ranLines, start: at(16, 0), end: at(16, 0)).joined(separator: " / "))
        // Terminal window names.
        func t(_ raw: String, _ bundle: String = "com.apple.Terminal", _ app: String = "Terminal") -> String {
            TerminalTitle.display(raw, bundle: bundle, app: app, user: "fixture-user")
        }
        require(t("fixture-user \u{2014} -zsh \u{2014} 120\u{00D7}30") == "Terminal", "user, shell and size only: the app name")
        require(t("tally \u{2014} -zsh \u{2014} ~/Projects/tally \u{2014} 120\u{00D7}30") == "tally · ~/Projects/tally" ||
                t("fixture-user \u{2014} -zsh \u{2014} ~/Projects/tally \u{2014} 120\u{00D7}30") == "zsh · ~/Projects/tally",
                "folder known: command · folder", t("fixture-user \u{2014} -zsh \u{2014} ~/Projects/tally \u{2014} 120\u{00D7}30"))
        require(t("fixture-user \u{2014} -zsh \u{2014} ~/Projects/tally \u{2014} 120\u{00D7}30") == "zsh · ~/Projects/tally", "zsh · ~/folder")
        require(t("fixture-user@fixture-mac: ~/Notes") == "~/Notes", "user@host: folder")
        require(t("\u{25D0} ~/Projects", "com.mitchellh.ghostty", "Ghostty") == "~/Projects", "Ghostty's spinner mark goes")
        require(t("cd", "com.mitchellh.ghostty", "Ghostty") == "Ghostty", "no folder: the app name")
        require(t(MomentHistoryCondense.withheldTitle) == "Terminal", "withheld: the app name")
        require(TerminalTitle.display("Budget \u{2014} 120\u{00D7}30", bundle: "com.apple.TextEdit", app: "TextEdit", user: "fixture-user")
                == "Budget \u{2014} 120\u{00D7}30", "other apps' titles pass through")
    }

    static func summaryWorth() {
        for filler in ["~1 min", "Terminal, ~1 min", "About 5 minutes", "1h 5m", "Had Terminal open, ~2 min", "", "less than a minute"] {
            require(MomentSummaryWorth.isFiller(filler, names: ["Terminal"]), "filler: \"\(filler)\"")
        }
        for real in ["Reviewed the parser fixture.", "Texted Avery about the demo", "Asked ChatGPT about parsers, ~1 min"] {
            require(!MomentSummaryWorth.isFiller(real, names: ["Terminal", "ChatGPT"]), "informative: \"\(real)\"")
        }
        require(MomentSummaryWorth.shape(excerpts: true, status: false, corrections: false, lines: [], names: []).header == false,
                "captured wording is never labelled Summary")
        require(MomentSummaryWorth.shape(excerpts: false, status: false, corrections: false, lines: ["Reviewed the parser."], names: [])
                == .init(header: true, factual: false), "a real summary keeps its header")
        require(MomentSummaryWorth.factualLine(app: "Terminal", actions: [], actionCount: 3, start: at(9, 0), end: at(9, 0, 30))
                == "Terminal · 3 actions in under a minute", "before the actions are read: the moment's count")
    }

    static func slice(_ id: String, _ start: Date, _ end: Date, subject: String, app: String, bundle: String, bullets: [MomentBullet] = [],
                      actionIDs: [String], sites: [String] = []) -> MomentSlice {
        MomentSlice(id: id, dayKey: "2026-10-02", start: start, end: end, title: subject, subject: subject, firstBullet: bullets.first?.text,
            bullets: bullets, apps: [app], primaryBundle: bundle, bundles: [bundle], sites: sites, actionIDs: actionIDs,
            actionCount: actionIDs.count, clusters: [], summary: bullets.isEmpty ? .pending : .ready(generatedAt: nil, local: true),
            hasCorrection: false, primaryApp: app)
    }

    /// Owner 10/2 (Main.dc.html): Messages with 3 conversations written in and one only read is ONE "Texts" card.
    static func messagesCard() {
        let sms = "com.apple.MobileSMS"
        let m5 = slice("t-m5", at(17, 14), at(17, 16), subject: "Texts with Q7", app: "Messages", bundle: sms,
                       bullets: [MomentBullet(text: "Texted Q7 about moving dinner to 7:30.", actionIDs: ["m5:t"])], actionIDs: ["m5:v", "m5:t"])
        let alex = slice("t-alex", at(17, 17), at(17, 18), subject: "Texts with Alex", app: "Messages", bundle: sms,
                         bullets: [MomentBullet(text: "Texted Alex the restaurant link.", actionIDs: ["alex:t"])], actionIDs: ["alex:t"])
        let sam = slice("t-sam", at(17, 19), at(17, 20), subject: "Texts with Sam", app: "Messages", bundle: sms,
                        bullets: [MomentBullet(text: "Read Sam's reply.", actionIDs: ["sam:v"])], actionIDs: ["sam:v"])
        let jordan = slice("t-jordan", at(17, 20), at(17, 22), subject: "Texts with Jordan", app: "Messages", bundle: sms,
                           bullets: [MomentBullet(text: "Drafted a text to Jordan asking about the weekend (not sent).", actionIDs: ["jordan:t"])],
                           actionIDs: ["jordan:t"])
        let moments = [m5, alex, sam, jordan]
        require(moments.allSatisfy { FocusListLayout.recordedConversation($0) != nil }, "fixture: every conversation is recorded",
                "\(moments.map { FocusListLayout.recordedConversation($0) ?? "nil" })")
        let sessions = FocusListLayout.sessions(moments, sectionID: "block:dinner")
        require(sessions.count == 1 && sessions[0].members.count == 4, "four Messages moments in one bracket are ONE card", "\(sessions.count)")
        let members = FocusAppCard.members(sessions[0])
        require(members.first?.id == "t-jordan", "the newest is the card's anchor")
        require(FocusAppCard.title(members) == "Texts", "titled by the app's friendly name, never a thread", FocusAppCard.title(members))
        require(FocusAppCard.range(members, timeZone: tz) == "5:14\u{2013}5:22 PM", "the range under the title")
        let rows = source("Sources/MemoryUI/FocusListRows.swift")
        require(!rows.contains("+\\(others) moments") && !rows.contains("FoldedRow"), "no \"+4 moments\" fold")
        require(FocusListLayout.order([FocusListSection(part: .evening, moments: moments)]).map(\.id) == ["t-jordan"], "↑/↓ stop once per card")

        // Writing, not reading: the read-only conversation is left out, by its words before the actions are read and by
        // its cited actions after.
        let byWords = FocusAppCard.bullets(members).map(\.text)
        require(byWords == ["Drafted a text to Jordan asking about the weekend (not sent).", "Texted Alex the restaurant link.",
                            "Texted Q7 about moving dinner to 7:30."], "one bullet per conversation written in, newest first", "\(byWords)")
        let acts = [action("m5:v", at(17, 14), "window.changed", app: "Messages", bundle: sms, title: "Q7"),
                    action("m5:t", at(17, 15), "keyboard.text_input", app: "Messages", bundle: sms, title: "Q7", text: "fictional"),
                    action("alex:t", at(17, 17), "keyboard.text_input", app: "Messages", bundle: sms, title: "Alex", text: "fictional"),
                    action("sam:v", at(17, 19), "window.changed", app: "Messages", bundle: sms, title: "Sam"),
                    action("jordan:t", at(17, 21), "keyboard.text_input", app: "Messages", bundle: sms, title: "Jordan", text: "fictional")]
        let ids = FocusAppCard.writingIDs(acts)
        require(ids == ["m5:t", "alex:t", "jordan:t"], "writing: typed, sent, drafted", "\(ids.sorted())")
        require(FocusAppCard.bullets(members, writingIDs: ids).map(\.text) == byWords, "by cited actions: the same three")
        require(FocusAppCard.collapsedLine(members) == "Drafted a text to Jordan asking about the weekend (not sent).",
                "collapsed: the newest written summary line", FocusAppCard.collapsedLine(members))
        // Side panel: Conversations, the app's icon and each name written in; Sam (read only) is left out; no times.
        require(FocusAppCard.panelTitle(members) == "Conversations", "Messages' panel is Conversations")
        let panel = FocusAppCard.panelRows(members, sources: FocusListExpanded.allSources(from: acts), writingIDs: ids)
        require(panel.map(\.name) == ["Jordan", "Alex", "Q7"], "every conversation written in, once, newest first; none only read",
                "\(panel.map(\.name))")
        require(panel.allSatisfy { $0.bundle == sms && $0.site.isEmpty && $0.wrote }, "rows carry the app's icon (its bundle)")
        let copy = FocusAppCard.copyText(members, timeZone: tz) ?? ""
        require(copy.hasPrefix("Texts · 5:14\u{2013}5:22 PM\n• Drafted") && !copy.contains("Sam"), "Copy Summary copies the card's bullets", copy)

        // A card with nothing written falls back to reading.
        let readOnly = [sam]
        require(FocusAppCard.bullets(readOnly).map(\.text) == ["Read Sam's reply."], "no writing: the reading line")
        let samRows = FocusAppCard.panelRows(readOnly, sources: FocusListExpanded.allSources(from: [acts[3]]), writingIDs: [])
        require(samRows.map(\.name) == ["Sam"], "no writing: read conversations are listed", "\(samRows.map(\.name))")
        let unsummarized = slice("t-sam2", at(18, 0), at(18, 2), subject: "Texts with Sam", app: "Messages", bundle: sms, actionIDs: ["s2"])
        require(FocusAppCard.collapsedLine([unsummarized]) == "Read texts with Sam.", "no summary, nothing written: \"Read texts with Sam.\"",
                FocusAppCard.collapsedLine([unsummarized]))

        // More than 3 written windows: 3 shown and "Show more ›" (to the details page); 3 or fewer: "Show details ›".
        let notes = slice("n0", at(19, 0), at(19, 9), subject: "Notes", app: "Notes", bundle: "com.apple.Notes", actionIDs: ["n"])
        let many = (0..<5).map { n in action("w\(n)", at(19, n), "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes", title: "Plan \(n)", text: "x") }
        let manyRows = FocusAppCard.panelRows([notes], sources: FocusListExpanded.allSources(from: many), writingIDs: FocusAppCard.writingIDs(many))
        require(manyRows.count == 5 && FocusAppCard.shownRows(manyRows).map(\.name) == ["Plan 4", "Plan 3", "Plan 2"],
                "at most 3 shown, newest first", "\(manyRows.map(\.name))")
        require(FocusAppCard.panelLink(rows: 5) == "Show more" && FocusAppCard.panelLink(rows: 3) == "Show details", "Show more / Show details")
    }

    /// Terminal with only noise: no "~1 min" Summary; one sentence, "Worked in Terminal for 5 minutes."
    static func terminalCard() {
        let term = "com.apple.Terminal"
        let views = (0..<12).map { n in
            action("tn\(n)", at(14, 0 + n / 3, (n % 3) * 20), "window.changed", app: "Terminal", bundle: term, title: MomentHistoryCondense.withheldTitle)
        }
        let m = slice("term", at(14, 0), at(14, 5), subject: "[sensitive title omitted] code", app: "Terminal", bundle: term,
                      bullets: [MomentBullet(text: "~1 min")], actionIDs: views.map(\.id))
        let members = FocusAppCard.members(FocusListLayout.sessions([m], sectionID: "loose")[0])
        require(FocusAppCard.title(members) == "Terminal", "titled Terminal, never the withheld title")
        require(!FocusAppCard.hasSummary(members), "a \"~1 min\" summary is no summary")
        require(FocusAppCard.collapsedLine(members) == "Worked in Terminal for 5 minutes.", "collapsed line", FocusAppCard.collapsedLine(members))
        let lines = MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(views, previews: []), actions: views, timeZone: tz)
        let sentences = FocusAppCard.sentences(lines, start: m.start, end: m.end, members: members)
        require(sentences == ["Worked in Terminal for 5 minutes."], "the left column: one sentence over the card's range", "\(sentences)")
        require(FocusAppCard.panelTitle(members) == "Windows and pages", "a terminal's panel is Windows and pages")
        require(FocusAppCard.panelRows(members, sources: FocusListExpanded.allSources(from: views), writingIDs: []).map(\.name) == ["Terminal"],
                "a withheld window is the app's name")
        // Commands are writing: "Ran 3 commands in Terminal."
        let title = "fixture-user \u{2014} -zsh \u{2014} ~/Projects/tally \u{2014} 120\u{00D7}30"
        let returns = (0..<3).map { n in action("rc\(n)", at(15, n), "keyboard.submit", app: "Terminal", bundle: term, title: title) }
        let cmd = MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(returns, previews: []), actions: returns, timeZone: tz)
        require(FocusAppCard.sentences(cmd, start: at(15, 0), end: at(15, 2)) == ["Ran 3 commands in Terminal."], "commands as a sentence",
                "\(FocusAppCard.sentences(cmd, start: at(15, 0), end: at(15, 2)))")
        require(FocusAppCard.writingIDs(returns).count == 3, "a command run is writing")
    }

    /// ChatGPT with a summary: the bullet on the left, Conversations on the right.
    static func chatGPTCard() {
        let m = slice("gpt", at(11, 37), at(11, 43), subject: "ChatGPT", app: "ChatGPT", bundle: "com.openai.chat",
                      bullets: [MomentBullet(text: "Asked ChatGPT how to handle parser errors.", actionIDs: ["g1"]),
                                MomentBullet(text: "Viewed the chat.", actionIDs: ["g0"])], actionIDs: ["g0", "g1"])
        let members = FocusAppCard.members(FocusListLayout.sessions([m], sectionID: "loose")[0])
        require(FocusAppCard.title(members) == "ChatGPT" && FocusAppCard.range(members, timeZone: tz) == "11:37\u{2013}11:43 AM", "ChatGPT · range")
        require(FocusAppCard.bullets(members).map(\.text) == ["Asked ChatGPT how to handle parser errors."], "viewed-only line left out")
        require(FocusAppCard.collapsedLine(members) == "Asked ChatGPT how to handle parser errors.", "collapsed: the summary line")
        require(FocusAppCard.panelTitle(members) == "Windows and pages", "Conversations is Messages' only; ChatGPT: Windows and pages")
        let chrome = slice("web", at(9, 0), at(9, 5), subject: "GitHub", app: "Google Chrome", bundle: "com.google.Chrome", actionIDs: ["p"], sites: ["github.com"])
        require(FocusAppCard.panelTitle([chrome]) == "Windows and pages", "a browser: Windows and pages")
    }

    /// claude/livefix-1004 (owner, live test 10/3): an hour of Claude Code in one Ghostty window is one moment still going
    /// (no note). The card's line was an older moment's summary, so the asks just typed never showed. The newest member's
    /// ask leads, in quotes, until its note has a line; then the summary line again.
    static func newestAskCard() {
        let ghostty = "com.mitchellh.ghostty"
        let older = slice("g-old", at(19, 39), at(19, 54), subject: "~", app: "Ghostty", bundle: ghostty,
                          bullets: [MomentBullet(text: "Asked Claude Code to rename the export flag.", actionIDs: ["go1"])], actionIDs: ["go1"])
        var open = slice("g-open", at(19, 55), at(19, 59), subject: "Tallybird app design review", app: "Ghostty", bundle: ghostty,
                         actionIDs: ["gn1", "gn2"])
        open.live = LiveMoment(label: "Ghostty", kind: "code", sends: ["Asked Claude Code"], seconds: 240, idle: false, communication: true)
        let before = FocusAppCard.members(FocusListLayout.sessions([older, open], sectionID: "loose")[0])
        require(before.first?.id == "g-open", "the moment still going is the card's anchor")
        require(FocusAppCard.collapsedLine(before) == "Asked Claude Code to rename the export flag.",
                "control, no ask loaded: the older summary line (what the owner saw)", FocusAppCard.collapsedLine(before))
        open.prompt = "why is the today card not showing my newest prompt"
        let members = FocusAppCard.members(FocusListLayout.sessions([older, open], sectionID: "loose")[0])
        require(FocusAppCard.collapsedLine(members) == "\u{201C}why is the today card not showing my newest prompt\u{201D}",
                "the newest member's ask leads, in quotes, while it has no note", FocusAppCard.collapsedLine(members))
        require(FocusAppCard.accessibilityLabel(members, timeZone: tz).hasSuffix("\u{201C}why is the today card not showing my newest prompt\u{201D}"),
                "VoiceOver reads the same line")
        // Its note arrives: the summary line wins again (`MomentSubtitle.shownPrompt`).
        let noted = slice("g-open", at(19, 55), at(19, 59), subject: "Tallybird app design review", app: "Ghostty", bundle: ghostty,
                          bullets: [MomentBullet(text: "Asked Claude Code why the Today card hid new prompts.", actionIDs: ["gn2"])],
                          actionIDs: ["gn1", "gn2"])
        var notedWithAsk = noted; notedWithAsk.prompt = open.prompt
        let after = FocusAppCard.members(FocusListLayout.sessions([older, notedWithAsk], sectionID: "loose")[0])
        require(FocusAppCard.collapsedLine(after) == "Asked Claude Code why the Today card hid new prompts.",
                "with a note: the newest summary line, not the raw ask", FocusAppCard.collapsedLine(after))
        // An older member's ask never leads over the newest member.
        var olderAsk = older; olderAsk.prompt = "an older ask"
        let stale = FocusAppCard.members(FocusListLayout.sessions([olderAsk, noted], sectionID: "loose")[0])
        require(!FocusAppCard.collapsedLine(stale).contains("an older ask"), "an older member's ask never leads the card")
        let rows = source("Sources/MemoryUI/FocusListRows.swift")
        require(rows.contains("FocusAppCard.promptMember(members), let ask = MomentSubtitle.shownPrompt(lead)")
                && rows.contains("PromptLine(prompt: ask, lead: lead.promptLead, asks: FocusAppCard.cardAsks(members, lead: lead))"),
                "the collapsed header draws the ask as PromptLine (cut before its closing quote)")
        let cache = source("Sources/MemoryUI/MomentPromptCache.swift")
        // claude/int-017 (owner 10/06, 0.1.7): every moment asks for its newest ask ("Asked 5 questions · latest “…”").
        require(cache.contains("newestFirst: true"), "every moment asks for its newest ask")
    }

    /// Grouping (owner 10/2, corrected): one card per app per bracket, terminals included; each website its own card.
    /// Grouping (owner 10/2, corrected): one card per app per bracket, terminals included; each website its own "app".
    static func grouping() {
        let chrome = "com.google.Chrome", safari = "com.apple.Safari", ghostty = "com.mitchellh.ghostty", term = "com.apple.Terminal"
        func web(_ id: String, _ m: Int, _ site: String, bundle: String = "com.google.Chrome", app: String = "Google Chrome") -> MomentSlice {
            slice(id, at(10, m), at(10, m + 1), subject: site, app: app, bundle: bundle, actionIDs: [id], sites: ["https://" + site + "/x"])
        }
        // 3 separate x.com moments (one in Safari, one on twitter.com), not adjacent: ONE X card.
        let xs = [web("x1", 0, "x.com"), web("r1", 2, "www.reddit.com"), web("x2", 4, "mobile.twitter.com"),
                  web("x3", 6, "x.com", bundle: safari, app: "Safari")]
        let webCards = FocusListLayout.sessions(xs, sectionID: "block:web").map(FocusAppCard.members)
        require(webCards.count == 2, "x.com plus reddit.com: 2 cards", "\(webCards.map { $0.map(\.id) })")
        let x = webCards.first { $0.count == 3 } ?? []
        require(Set(x.map(\.id)) == ["x1", "x2", "x3"] && FocusAppCard.title(x) == "X", "every x.com moment is one X card", "\(x.map(\.id))")
        require(webCards.contains { FocusAppCard.title($0) == "reddit.com" }, "reddit.com is its own card")
        let three = FocusListLayout.sessions([web("a", 0, "x.com"), web("b", 3, "x.com"), web("c", 9, "x.com")], sectionID: "block:x")
        require(three.count == 1, "3 separate x.com moments: 1 X card")
        // Registrable domain, aliases and product hosts.
        for (raw, key) in [("https://www.reddit.com/r/x", "reddit.com"), ("old.reddit.com", "reddit.com"), ("twitter.com", "x.com"),
                           ("mail.google.com", "mail.google.com"), ("www.google.com", "google.com"), ("docs.google.com", "docs.google.com"),
                           ("news.bbc.co.uk", "bbc.co.uk"), ("gist.github.com", "github.com"), ("localhost", "localhost")] {
            require(FocusAppCard.siteKey(raw) == key, "site key \(raw) → \(key)", FocusAppCard.siteKey(raw))
        }
        // claude/catchup-1003: Outlook on the web under every Microsoft host is one "Outlook" card.
        for raw in ["https://outlook.cloud.microsoft/mail/", "outlook.office.com", "https://outlook.live.com/mail/0/", "outlook.office365.com"] {
            require(FocusAppCard.siteKey(raw) == "outlook.com", "site key \(raw) → outlook.com", FocusAppCard.siteKey(raw))
        }
        require(FocusAppCard.siteKey("teams.cloud.microsoft") == "cloud.microsoft" && FocusAppCard.siteKey("www.office.com") == "office.com",
                "only Outlook's hosts fold into Outlook", FocusAppCard.siteKey("teams.cloud.microsoft"))
        let outlook = FocusListLayout.sessions([web("o1", 20, "outlook.office.com"), web("o2", 22, "outlook.cloud.microsoft")], sectionID: "block:outlook")
            .map(FocusAppCard.members)
        require(outlook.count == 1 && FocusAppCard.title(outlook[0]) == "Outlook", "outlook.office.com + outlook.cloud.microsoft: one Outlook card",
                "\(outlook.map { FocusAppCard.title($0) })")
        let both = slice("both", at(10, 8), at(10, 9), subject: "x", app: "Google Chrome", bundle: chrome, actionIDs: ["b"],
                         sites: ["https://x.com/a", "https://reddit.com/b"])
        require(FocusAppCard.situation(both) == "site:x.com", "a moment over two sites joins its first site's card, never a combined card")
        // Terminal with 3 folders: 1 card; Ghostty its own card; the folders are in the side panel.
        func shell(_ id: String, _ m: Int, _ title: String, bundle: String = "com.apple.Terminal", app: String = "Terminal") -> MomentSlice {
            slice(id, at(11, m), at(11, m + 1), subject: title, app: app, bundle: bundle, actionIDs: [id])
        }
        let shells = [shell("t1", 0, "fixture-user \u{2014} -zsh \u{2014} ~/Projects/tally \u{2014} 80\u{00D7}24"),
                      shell("t2", 2, "fixture-user \u{2014} -zsh \u{2014} ~/Projects/notes \u{2014} 80\u{00D7}24"),
                      shell("t3", 4, "fixture-user \u{2014} -zsh \u{2014} ~/Desktop \u{2014} 80\u{00D7}24"),
                      shell("g1", 5, "\u{25D0} ~/Projects/tally", bundle: ghostty, app: "Ghostty"), shell("g2", 7, "cd", bundle: ghostty, app: "Ghostty")]
        let termCards = FocusListLayout.sessions(shells, sectionID: "block:code").map(FocusAppCard.members)
        require(termCards.count == 2, "Terminal with 3 folders: 1 card; Ghostty: 1 card", "\(termCards.map { $0.map(\.id) })")
        require(termCards.map(FocusAppCard.title).sorted() == ["Ghostty", "Terminal"], "titled by the terminal app", "\(termCards.map(FocusAppCard.title))")
        let folders = [("t1", "~/Projects/tally"), ("t2", "~/Projects/notes"), ("t3", "~/Desktop")].map { id, f in
            action(id + ":a", at(11, 0), "keyboard.submit", app: "Terminal", bundle: term, title: "fixture-user \u{2014} -zsh \u{2014} \(f) \u{2014} 80\u{00D7}24") }
        let terminalCard = termCards.first { FocusAppCard.title($0) == "Terminal" } ?? []
        let panel = FocusAppCard.panelRows(terminalCard, sources: FocusListExpanded.allSources(from: folders), writingIDs: FocusAppCard.writingIDs(folders))
        require(Set(panel.map(\.name)).count == 3 && panel.allSatisfy { $0.name.contains("~/") }, "the folders are in Windows and pages",
                "\(panel.map(\.name))")
        let gpt = (0..<3).map { n in slice("gpt\(n)", at(12, n * 2), at(12, n * 2 + 1), subject: "Chat \(n)", app: "ChatGPT",
                                          bundle: "com.openai.chat", actionIDs: ["gpt\(n)"]) }
        require(FocusListLayout.sessions(gpt, sectionID: "block:ai").count == 1, "chat apps: one card per app")
    }

    /// The owner's installed-build screenshot (an older day, notes already stored): the bracket "✳ Daydream app design
    /// review code · 7" held a "Messages / 3 moments" fold, then "Thanking the support team", two "Texts · Viewed texts"
    /// cards, "✳ Tallybird app design review" and "[sensitive title omitted] code". Now: one Texts card for every
    /// Messages moment (the viewed-only ones merged in, not cards), one card per terminal, and a clean bracket title.
    static func oldDayBracket() {
        let sms = "com.apple.MobileSMS"
        func text(_ id: String, _ m: Int, subject: String, bullet: String?, apps: [String] = ["Messages"], bundles: [String] = [sms]) -> MomentSlice {
            let b = bullet.map { [MomentBullet(text: $0)] } ?? []
            return MomentSlice(id: id, dayKey: "2026-09-28", start: at(13, m), end: at(13, m + 1), title: subject, subject: subject,
                firstBullet: bullet, bullets: b, apps: apps, primaryBundle: bundles.first, bundles: bundles, sites: [], actionIDs: [id],
                actionCount: 1, clusters: [], summary: b.isEmpty ? .pending : .ready(generatedAt: nil, local: true), hasCorrection: false,
                primaryApp: apps.first)
        }
        let moments = [
            text("fold-1", 0, subject: "Messages", bullet: nil), text("fold-2", 2, subject: "Messages", bullet: nil),
            text("fold-3", 4, subject: "Messages", bullet: nil),
            text("support", 6, subject: "Texts with Support", bullet: "Texted Support thanking the team for the refund."),
            text("viewed-1", 8, subject: "Texts with Avery", bullet: "Viewed texts with Avery."),
            text("viewed-2", 10, subject: "Texts", bullet: "Viewed texts.", apps: ["Texts"], bundles: []),
            slice("claude", at(13, 12), at(13, 30), subject: "\u{2733} Tallybird app design review", app: "Ghostty",
                  bundle: "com.mitchellh.ghostty", actionIDs: ["claude"]),
            slice("withheld", at(13, 31), at(13, 33), subject: "[sensitive title omitted] code", app: "Terminal",
                  bundle: "com.apple.Terminal", actionIDs: ["withheld"])]
        let block = LevelBlockSlice(id: "b", name: LevelWords.blockName("\u{2733} Tallybird app design review code"),
                                    title: "\u{2733} Tallybird app design review code", start: at(13, 0), end: at(13, 33),
                                    momentIDs: moments.map(\.id), lines: [])
        require(block.name == "Tallybird app design review", "bracket title: no ✳, no withheld, no trailing code", block.name)
        require(LevelWords.blockName("[sensitive title omitted] code") == "Activity", "a bracket title with nothing left is plain")
        require(LevelWords.blockName("About 2 hours: \u{2733} fixing the export crash") == "Fixing the export crash", "span titles still clean")
        require(LevelWords.blockName("Reviewing the code") == "Reviewing the code", "\"the code\" stays")
        let sections = FocusListLayout.sections(moments, blocks: [block], calendar: cal)
        require(sections.count == 1, "one bracket", "\(sections.count)")
        let cards = FocusListLayout.sessions(sections[0].moments, sectionID: sections[0].id).map(FocusAppCard.members)
        require(cards.count == 3, "Texts, Ghostty and Terminal: three cards", "\(cards.map { $0.map(\.id) })")
        guard let texts = cards.first(where: { FocusAppCard.title($0) == "Texts" }) else { require(false, "a Texts card"); return }
        require(Set(texts.map(\.id)) == ["fold-1", "fold-2", "fold-3", "support", "viewed-1", "viewed-2"],
                "every Messages moment, the viewed-only ones and the no-bundle one included, is in the one Texts card", "\(texts.map(\.id))")
        require(FocusAppCard.bullets(texts).map(\.text) == ["Texted Support thanking the team for the refund."],
                "the card's bullets are what was written; viewed lines are left out")
        require(cards.map(FocusAppCard.title).sorted() == ["Ghostty", "Terminal", "Texts"], "no withheld or spinner titles",
                "\(cards.map(FocusAppCard.title))")
        require(FocusListLayout.order(sections).count == 3, "↑/↓ stop once per card on old days too")
        require(FocusAppCard.latestTime(texts, timeZone: tz) == "1:11 PM", "the header shows the latest time only", FocusAppCard.latestTime(texts, timeZone: tz))
        let tl = source("Sources/MemoryUI/CanonicalTimeline.swift")
        require(tl.contains("FocusListRowsCard(moments: section.moments,") && tl.components(separatedBy: "FocusListRowsCard(").count == 2,
                "every day, today or older, renders through the one app-card path")
        let rows = source("Sources/MemoryUI/FocusListRows.swift")
        require(!rows.contains("FocusListSessionRow") && !rows.contains("@State private var open"), "no stored fold state left")
    }

    /// Before the summary: one message typed across interruptions is stitched; at most 2, quoted and clamped.
    static func capturedWording() {
        let place = "Messages to Q7"
        let five = [CapturedStitch.Fragment(place: place, at: "2026-10-02T22:23:01Z", text: "Hey are we still on for "),
                    CapturedStitch.Fragment(place: place, at: "2026-10-02T22:23:05Z", text: ". on for"),
                    CapturedStitch.Fragment(place: place, at: "2026-10-02T22:23:20Z", text: "dinner tonight?   I was thinking"),
                    CapturedStitch.Fragment(place: place, at: "2026-10-02T22:24:00Z", text: "\"we could move it to 7:30"),
                    CapturedStitch.Fragment(place: place, at: "2026-10-02T22:24:30Z", text: ", if that works\u{201D}")]
        let stitched = CapturedStitch.messages(five)
        require(stitched == ["Hey are we still on for dinner tonight? I was thinking we could move it to 7:30, if that works"]
                || stitched == ["Hey are we still on for dinner tonight? I was thinking we could move it to 7:30 if that works"],
                "five fragments stitch into one clean message", "\(stitched)")
        let other = CapturedStitch.Fragment(place: "ChatGPT", at: "2026-10-02T22:25:00Z", text: "fix the parser")
        require(CapturedStitch.messages(five + [other]).first == "fix the parser", "another field is another message, newest first")
        require(CapturedStitch.messages([CapturedStitch.Fragment(place: place, at: "1", text: "ok")]) == ["ok"], "a single short message stays")
        require(FocusAppCard.quote("ok") == "\u{201C}ok\u{201D}", "curly quotes")
        let long = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)
        let q = FocusAppCard.quote(long)
        require(q.count <= FocusAppCard.quoteLimit + 3 && q.hasSuffix("word\u{2026}\u{201D}"), "a long message is cut at a word, with … and the quote", q)
        let opened = FocusAppCard.quote(long, limit: FocusAppCard.openQuoteLimit)
        require(opened.count > q.count && opened.count <= FocusAppCard.openQuoteLimit + 3, "opened: up to 4 lines' worth", opened)
        require(FocusAppCard.earlierLine(2) == nil && FocusAppCard.earlierLine(5) == "+3 earlier messages" && FocusAppCard.earlierLine(3) == "+1 earlier message",
                "+N earlier messages")
        // Pending vs failed.
        var m = slice("p", at(17, 23), at(17, 26), subject: "Texts with Q7", app: "Messages", bundle: "com.apple.MobileSMS", actionIDs: ["p"])
        let queue = SummaryQueue(writing: ["p"], lookedAt: at(17, 30))
        require(FocusAppCard.summaryPending([m], phase: .on(.local), queue: queue), "queued: pending")
        require(!FocusAppCard.summaryPending([m], phase: .failed(.modelWontStart), queue: queue), "failed: not pending")
        require(!FocusAppCard.summaryPending([m], phase: .off, queue: queue), "summaries off: not pending")
        require(!FocusAppCard.summaryPending([m], phase: .on(.local), queue: SummaryQueue(lookedAt: at(17, 30))), "not queued: not pending")
        m.currentSummary = .tooLong
        require(!FocusAppCard.summaryPending([m], phase: .on(.local), queue: queue), "too long: not pending")
        // claude/notesfix-015 + claude/int-017 (owner 10/06, 0.1.7): "Summary" over the card's own lines; never "Summary pending" or "What you wrote".
        require(FocusAppCard.header(bullets: false, quotes: true, pending: true) == "Summary", "pending: \"Summary\", never \"Summary pending\"")
        require(FocusAppCard.header(bullets: false, quotes: true, pending: false) == "Summary", "failed: \"Summary\", never \"What you wrote\"")
        require(FocusAppCard.header(bullets: true, quotes: false, pending: false) == "Summary", "the summary: \"Summary\"")
        require(FocusAppCard.header(bullets: false, quotes: false, pending: false) == nil, "noise only: no header")
    }

    // MARK: Messages (owner 10/3)

    static let sms = "com.apple.MobileSMS"
    /// A Messages typed unit as the fixed capture saves it: surface text, field message, the conversation's name (nil:
    /// a New Message with an empty To), a detected Return send or an unsent draft. Fictional words only.
    static func smsUnit(_ id: String, _ when: Date, _ words: String, to: String?, sent: Bool, seal: String? = nil) -> CanonicalAction {
        ActionProjection.make(smsEvidence(id, when, words, to: to, sent: sent, seal: seal))
    }
    /// The unit's evidence (its window title is the conversation's: a name, or a fictional 555 number).
    static func smsEvidence(_ id: String, _ when: Date, _ words: String, to: String?, sent: Bool, seal: String? = nil,
                            title: String = "Messages") -> Evidence {
        var e = Evidence(id: id, at: iso(when), kind: "keyboard.text_input", app: "Messages", bundle: sms, title: title, text: words, synthetic: true)
        let unit = TypedUnitProvenance(runID: "run-" + id, part: 1, sealReason: seal ?? (sent ? "submit" : "idle"), startedAt: iso(when),
            keys: nil, edits: nil, withheld: 0, surface: "text", field: "message", send: sent ? "detected" : "unknown",
            sendBy: sent ? "return" : nil, to: to)
        e.captureProvenance = NativeCaptureProvenance(policyRevision: "synthetic", classifierVersion: "fixture", windowID: "w", focusID: "f",
                                                     checkedAt: iso(when), generation: 1, unit: unit)
        return e
    }
    /// Owner 10/6: a confirmed AI ask reads as a search does ("Searched “red boots”."): "Asked ChatGPT “…”.", plain; a draft
    /// keeps the bare italic quote; two typed pieces never run together ("thatWe").
    static func askLines() {
        // The join: a new line or sentence whose separator wasn't kept still gets its space; a mid-word cut still joins.
        require(MessagesTypedFold.join("Okay, I think that", "We should implement posthog.") == "Okay, I think that We should implement posthog."
                && MessagesTypedFold.join("wanna me", "et us") == "wanna meet us" && MessagesTypedFold.join("v2", "ok") == "v2ok",
                "join: \"that\" + \"We\" gets a space (never \"thatWe\"); a mid-word cut still joins", MessagesTypedFold.join("Okay, I think that", "We should"))
        let pieces = [CapturedStitch.Fragment(place: " in ChatGPT", at: "2026-10-06T10:00:00Z", text: "Okay, I think that"),
                      CapturedStitch.Fragment(place: " in ChatGPT", at: "2026-10-06T10:00:09Z", text: "We should implement posthog. However, I am not sure", sent: true)]
        require(CapturedStitch.messages(pieces) == ["Okay, I think that We should implement posthog. However, I am not sure"],
                "stitch: two pieces of one ask never run together", "\(CapturedStitch.messages(pieces))")
        // One preview of an ask typed in two parts (a part ended without its space): the parts join with one.
        let words = "why does the export crash when the file is over 2gb, and is it the same bug as the one in the import sheet last week"
        func preview(_ id: String, _ parts: [String], state: String) -> OwnerSourcePreview {
            OwnerSourcePreview(id: id, actionIDs: parts.indices.map { id + "-\($0)" }, at: "2026-10-06T10:01:00Z", runID: "run-" + id,
                parts: parts.indices.map { OwnerSourcePart(actionID: id + "-\($0)", text: parts[$0], state: $0 == parts.count - 1 ? state : "draft") },
                state: state, lead: (state == "submitted" ? "Submitted text" : "Drafted text") + " in ChatGPT", readAt: at(10, 2),
                disclosureRevision: "fixture", expiresAt: nil)
        }
        let joined = CapturedStitch.fragments([preview("p", ["Okay, I think that", "We should implement posthog."], state: "draft")]).map(\.text)
        require(joined == ["Okay, I think that We should implement posthog."], "a preview's parts join with a space", "\(joined)")
        // A confirmed ask (`ComposeLine` asked, a send detected): "Asked ChatGPT “…”.".
        let asked = ComposeLine(ComposeOutcome(kind: .asked, destination: ComposeDestination(service: "ChatGPT")))
        let sent = preview("g", [words], state: "submitted")
        let column = FocusAppCard.leftColumn([], previews: [sent], pending: true, compose: ["g-0": asked])
        let quote = FocusAppCard.quote(column.quotes.first ?? "")
        let line = FocusAppCard.askLine(column.action(0), quote: quote) ?? ""
        require(column.header == "Summary" && column.codeLines && column.action(0)?.lead == "Asked ChatGPT" && line.hasPrefix("Asked ChatGPT \u{201C}why does the export crash")
                && line.hasSuffix("\u{2026}\u{201D}.") && !line.contains(":"),
                "a confirmed ask reads \"Asked ChatGPT “…”.\" (no colon, a period) under \"Summary\" (code's own line)", "\(column.header ?? "nil") \(line)")
        // Owner 10/6: code's action lines read "Summary". claude/notesfix-015 + claude/int-017 (owner 10/06, 0.1.7): no Summarize Now on a card.
        require(!FocusAppCard.offersSummarizeNow(column, targets: 1, running: false) && !FocusAppCard.offersSummarizeNow(column, targets: 0, running: true),
                "code's action lines under \"Summary\": no Summarize Now")
        require(CardSummaryState.pending.label(column.header, codeLines: column.codeLines) == "Summary"
                && !CardSummaryState.violet(CardSummaryState.pending.label(column.header, codeLines: true))
                && CardSummaryState.working.label(column.header, codeLines: column.codeLines) == FocusAppCard.summarizingTitle
                && CardSummaryState.done.label("Summary") == "Summary" && CardSummaryState.working.label("Summary") == "Summary",
                "\"Summary\" (grey) over code's lines; \"Summarizing…\" while it runs; a note's Summary unchanged")
        let noted = slice("n", at(10, 0), at(10, 5), subject: "ChatGPT", app: "ChatGPT", bundle: "com.openai.chat",
                          bullets: [MomentBullet(text: "Asked ChatGPT why the export crashes on big files.", actionIDs: ["g-0"])], actionIDs: ["g-0"])
        let after = FocusAppCard.leftColumn([noted], previews: [sent], pending: false, compose: ["g-0": asked])
        // claude/notesfix-015 + claude/int-017 (owner 10/06, 0.1.7): a stored note never replaces the quotes.
        require(after.header == "Summary" && after.codeLines && after.quotes.count == 1 && after.bullets.isEmpty
                && !FocusAppCard.offersSummarizeNow(after, targets: 1, running: false),
                "once a note is stored: the ask line stays under Summary, no Summarize Now")
        // A bare quote beside the ask (a draft never sent) keeps the old header: raw words never sit under "Summary".
        let mixed = FocusAppCard.leftColumn([], previews: [sent, preview("h", ["and maybe the import too"], state: "draft")], pending: true,
                                            compose: ["g-0": asked])
        require(mixed.quotes.count == 2 && !mixed.codeLines && mixed.header == "Summary"
                && FocusAppCard.summaryLines(mixed).first == "\u{201C}and maybe the import too\u{201D}"
                && !FocusAppCard.offersSummarizeNow(mixed, targets: 1, running: false),
                "an ask beside a bare draft: both under Summary, the draft a bare quote (claude/int-017 (owner 10/06, 0.1.7))", "\(mixed.header ?? "nil") \(FocusAppCard.summaryLines(mixed))")
        require(FocusAppCard.askLine(.init(lead: "Asked Claude", sent: true), quote: FocusAppCard.quote("fix the parser")) == "Asked Claude \u{201C}fix the parser\u{201D}.",
                "the ask line: Asked <App> “…”.")
        // Not confirmed: a gesture alone ("submitted", no compose line) or a draft's compose line is no ask: the bare quote.
        let draft = ComposeLine(ComposeOutcome(kind: .draft, destination: ComposeDestination(service: "ChatGPT")))
        for (compose, why) in [([:], "a gesture alone"), (["g-0": draft], "a draft")] as [([String: ComposeLine], String)] {
            let c = FocusAppCard.leftColumn([], previews: [sent], pending: true, compose: compose)
            require(c.quotes.count == 1 && c.action(0) == nil && FocusAppCard.askLine(c.action(0), quote: quote) == nil,
                    "\(why): no \"Asked\", the bare quote as before")
        }
        // Another send (a text) is never an ask.
        let texted = ComposeLine(ComposeOutcome(kind: .sentMessage, destination: ComposeDestination(name: "Sam")))
        require(CapturedStitch.action(texted) == nil && CapturedStitch.action(asked)?.lead == "Asked ChatGPT", "only an AI ask is an ask")
        // The card and the details page draw it plain (regular, not italic); the collapsed row keeps its quoted ask.
        let expanded = source("Sources/MemoryUI/FocusListExpanded.swift"), detail = source("Sources/MemoryUI/DaydreamKitMoments.swift")
        // claude/int-017 (owner 10/06, 0.1.7): both draw the card's Summary lines ("Asked ChatGPT “…”." plain, one grey dot: `CardLine`).
        require(expanded.contains("FocusAppCard.summaryLines(column)") && detail.contains("FocusAppCard.summaryLines(column)")
                && expanded.contains("CardLine(line, size: 12.5)") && detail.contains("CardLine(line, size: 13)"),
                "the card and the details page draw the ask line plain (not italic)")
        require(source("Sources/MemoryUI/FocusAppCard.swift").contains("if let lead = promptMember(members), let line = MomentSubtitle.promptText(lead, asks: cardAsks(members, lead: lead)) { return line }")
                && PromptLine.text("fix the parser", lead: nil) == "\u{201C}fix the parser\u{201D}"
                && PromptLine.text("fix the parser", lead: nil, asks: 1) == "Asked \u{201C}fix the parser\u{201D}"
                && PromptLine.text("fix the parser", lead: nil, asks: 3) == "Asked 3 questions \u{00B7} latest \u{201C}fix the parser\u{201D}",
                "the collapsed line keeps its quoted ask; a sent one reads \"Asked “…”\" (claude/int-017 (owner 10/06, 0.1.7))")
        xLines()
    }

    /// Owner 10/6: X cards, most specific line first, never more than code saved; "Posted" and "Replied" only from a send
    /// code confirmed (`ComposeSend`: a gesture and a confirmation).
    static func xLines() {
        // 1. With the words: Posted / Replied only when confirmed sent, Typed for the rest (never Posted for a draft).
        func xLine(_ kind: ComposeKind, context: ComposeContext = .init()) -> ComposeLine {
            ComposeLine(ComposeOutcome(kind: kind, destination: ComposeDestination(service: "X"), context: context))
        }
        func xPreview(_ id: String, _ words: String, state: String) -> OwnerSourcePreview {
            OwnerSourcePreview(id: id, actionIDs: [id], at: "2026-10-06T11:00:00Z", runID: "run-" + id,
                parts: [OwnerSourcePart(actionID: id, text: words, state: state)], state: state,
                lead: (state == "submitted" ? "Submitted text" : "Drafted text") + " in Google Chrome", readAt: at(11, 1),
                disclosureRevision: "fixture", expiresAt: nil)
        }
        let words = "shipping the new export today"
        for (line, state, want) in [(xLine(.posted), "submitted", "Posted \u{201C}\(words)\u{201D} on X."),
                                    (xLine(.quoted), "submitted", "Posted \u{201C}\(words)\u{201D} on X."),
                                    (xLine(.replied, context: ComposeContext(author: "Ada")), "submitted", "Replied \u{201C}\(words)\u{201D} on X."),
                                    (xLine(.draft), "draft", "Typed \u{201C}\(words)\u{201D} on X."),
                                    // Return pressed but no confirmation: a draft, never "Posted".
                                    (xLine(.draft), "submitted", "Typed \u{201C}\(words)\u{201D} on X.")] as [(ComposeLine, String, String)] {
            let c = FocusAppCard.leftColumn([], previews: [xPreview("x1", words, state: state)], pending: false, compose: ["x1": line])
            let got = FocusAppCard.askLine(c.action(0), quote: FocusAppCard.quote(c.quotes.first ?? "")) ?? "-"
            require(got == want && c.header == "Summary" && c.codeLines && !FocusAppCard.offersSummarizeNow(c, targets: 1, running: false)
                    && FocusAppCard.summaryLines(c) == [want],
                    "X with words: \(line.kind) \(state) reads \"\(want)\" under \"Summary\", no Summarize Now (claude/int-017 (owner 10/06, 0.1.7))", got)
        }
        // A post the preview calls sent but code never confirmed has no compose "posted" line: no "Posted".
        let unconfirmed = FocusAppCard.leftColumn([], previews: [xPreview("x2", words, state: "submitted")], pending: false, compose: [:])
        require(unconfirmed.action(0) == nil, "X: a gesture alone is never \"Posted\"")
        // A confirmed post whose piece did not end the message (a later piece is still typing) is not "Posted".
        let later = CapturedStitch.quotes([CapturedStitch.Fragment(place: " in Google Chrome", at: "1", text: "first", sent: false,
                                                                   action: CapturedStitch.action(xLine(.posted)))])
        require(later.first?.action == nil, "X: \"Posted\" only when the confirmed piece ended the message")
        // Other sites keep their bare quote.
        let reddit = ComposeLine(ComposeOutcome(kind: .posted, destination: ComposeDestination(service: "Reddit")))
        require(CapturedStitch.action(reddit) == nil, "X lines are for X only")

        // 2. Without the words: the pages' own links (else titles); no search line (X searches keep the site only).
        require(XLines.pageLine(link: "https://x.com/ada/status/1840000000000000001", title: "Ada Lovelace on X: \"notes on the engine\"") == "Viewed @ada's post."
                && XLines.pageLine(link: "https://x.com/ada", title: "Ada Lovelace (@ada) / X") == "Viewed @ada on X."
                && XLines.pageLine(link: "https://x.com/ada/media", title: "") == "Viewed @ada on X."
                && XLines.pageLine(link: nil, title: "Ada Lovelace on X: \"notes\"") == "Viewed Ada Lovelace's post."
                && XLines.pageLine(link: nil, title: "Ada Lovelace (@ada)") == "Viewed @ada on X.",
                "X pages: a post is \"Viewed @ada's post.\", a profile \"Viewed @ada on X.\"")
        for (link, title) in [("https://x.com/home", "Home"), ("https://x.com/notifications", ""), ("https://x.com/i/bookmarks", ""),
                              ("https://x.com/explore", "Explore"), ("https://x.com/search", "")] as [(String?, String)] {
            require(XLines.pageLine(link: link, title: title) == nil, "X: \(link ?? title) names no one")
        }
        require(BrowserSites.pageDecision("https://x.com/search?q=red%20boots&src=typed_query", userBlocked: []) == .siteOnly(origin: "https://x.com")
                && BrowserSites.pageLink("https://x.com/search?q=red%20boots") == nil && SearchPage.engine(host: "x.com") == nil,
                "X searches keep the site only (no words, no link): no \"Searched … on X\" line")
        // DayDream only knows a post was in front, never that it was read.
        require(!source("Sources/MemoryUI/FocusAppCard.swift").contains("\"Read @") && !source("Sources/MemoryUI/FocusAppCard.swift").contains("return \"Read \\("),
                "X pages say \"Viewed\", never \"Read\"")
        // 3. The time line, then the specific lines, each once; page lines capped.
        let start = at(11, 0), end = at(11, 25)
        func page(_ id: String, _ link: String, _ title: String) -> MomentDetailEntry {
            var e = MomentDetailEntry(id: id, bundle: "com.google.Chrome", app: "Google Chrome", host: "x.com", title: title, detail: "",
                                      first: start, last: start, actionIDs: [id], openActionID: id, sends: [], typed: [])
            e.link = link
            return e
        }
        var posted = MomentDetailEntry(id: "p", bundle: "com.google.Chrome", app: "Google Chrome", host: "", title: "Posted on X", detail: "",
                                       first: start, last: start, actionIDs: ["p"], openActionID: nil, sends: [], typed: [])
        posted.message = MessagesTypedFold.Line(sent: true, returned: false, name: nil, title: "Posted on X", kind: ComposeKind.posted.rawValue)
        let lines = [page("h", "https://x.com/home", "Home"), page("a", "https://x.com/ada/status/1", "Ada on X: \"one\""),
                     page("a2", "https://x.com/ada/status/1", "Ada on X: \"one\""), page("b", "https://x.com/bob", "Bob (@bob) / X"),
                     posted, page("c", "https://x.com/cy/status/2", ""), page("d", "https://x.com/dee/status/3", "")]
        let said = XLines.sentences(lines, start: start, end: end)
        require(said == ["On X for 25 minutes.", "Viewed @ada's post.", "Viewed @bob on X.", "Posted on X.", "Viewed @cy's post."],
                "X without words: the time line, then posts, profiles and the send, each once (pages capped)", "\(said)")
        require(XLines.timeLine(from: start, to: start.addingTimeInterval(20)) == "On X for less than a minute.", "X time line under a minute")
        // Owner 10/6: an X card's own lines (no words, no note) read "Summary", with Summarize Now kept.
        let xCard = slice("xc", start, end, subject: "X", app: "Google Chrome", bundle: "com.google.Chrome", actionIDs: ["xa"], sites: ["x.com"])
        let xa = action("xa", start, "app.focus", app: "Google Chrome", bundle: "com.google.Chrome", title: "Home / X")
        let xColumn = FocusAppCard.leftColumn([xCard], previews: [], pending: true, actions: [xa])
        // claude/int-017 (owner 10/06, 0.1.7): the card draws its X lines as What happened sentences under "Summary" (`plainSentences`); the column
        // itself has no lines, so no header of its own and never "Summary pending"; no Summarize Now.
        require(XLines.card([xCard]) && xColumn.header == nil && xColumn.codeLines && xColumn.quotes.isEmpty
                && !FocusAppCard.offersSummarizeNow(xColumn, targets: 1, running: false)
                && FocusAppCard.plainSentences(said) == said,
                "X card's own lines: never \"Summary pending\", no Summarize Now, the X sentences kept", xColumn.header ?? "nil")
        let other = slice("tc", start, end, subject: "Terminal", app: "Terminal", bundle: "com.apple.Terminal", actionIDs: ["ta"])
        require(FocusAppCard.leftColumn([other], previews: [], pending: true, actions: [xa]).header == nil,
                "other cards without a note: never \"Summary pending\"")
        // Owner 10/6: the collapsed X row leads with its newest post or reply code confirmed sent, as the expanded card
        // says it ("Replied “…” on X."), the words cut as an AI ask's are (`MomentPromptText.clean`, then before the
        // closing quote); a draft never leads (the prompt pipeline hands X only confirmed sends, `promptLead` set).
        var xNewest = slice("xn", at(11, 20), at(11, 25), subject: "X", app: "Google Chrome", bundle: "com.google.Chrome", actionIDs: ["xn1"], sites: ["x.com"])
        var xOlder = slice("xo", at(11, 0), at(11, 10), subject: "X", app: "Google Chrome", bundle: "com.google.Chrome", actionIDs: ["xo1"], sites: ["x.com"])
        require(FocusAppCard.collapsedLine([xNewest, xOlder]) == "On X for 25 minutes.", "X row, no confirmed send: \"On X for 25 minutes.\"",
                FocusAppCard.collapsedLine([xNewest, xOlder]))
        xOlder.prompt = "yes, the fix is in 1.4.2"; xOlder.promptLead = "Replied"; xOlder.promptAt = "2026-10-02T16:08:00Z"
        require(FocusAppCard.collapsedLine([xNewest, xOlder]) == "Replied \u{201C}yes, the fix is in 1.4.2\u{201D} on X."
                && FocusAppCard.promptMember([xNewest, xOlder])?.id == "xo",
                "X row: the newest confirmed reply leads, \"Replied “…” on X.\" (a newer member without one doesn't hide it)",
                FocusAppCard.collapsedLine([xNewest, xOlder]))
        xNewest.prompt = "shipping the export fix today"; xNewest.promptLead = "Posted"; xNewest.promptAt = "2026-10-02T16:02:00Z"
        require(FocusAppCard.collapsedLine([xNewest, xOlder]).hasPrefix("Replied"),
                "X row: the most recent send leads even from an older member (moments interleave on X)")
        xNewest.promptAt = "2026-10-02T16:21:00Z"
        require(FocusAppCard.collapsedLine([xNewest, xOlder]) == "Posted \u{201C}shipping the export fix today\u{201D} on X."
                && MomentSubtitle.rowText(for: xNewest) == "Posted \u{201C}shipping the export fix today\u{201D} on X.",
                "X row: the most recent confirmed send leads (\"Posted “…” on X.\"), on the card and on a member row")
        var xDraft = xNewest; xDraft.promptLead = nil
        require(FocusAppCard.collapsedLine([xDraft]) == "On X for 5 minutes.", "X row: words without a confirmed send never lead (the time line)",
                FocusAppCard.collapsedLine([xDraft]))
        var xNoted = slice("xd", at(11, 20), at(11, 25), subject: "X", app: "Google Chrome", bundle: "com.google.Chrome",
                           bullets: [MomentBullet(text: "Posted about the export fix on X.", actionIDs: ["xd1"])], actionIDs: ["xd1"], sites: ["x.com"])
        xNoted.prompt = "shipping"; xNoted.promptLead = "Posted"
        require(FocusAppCard.collapsedLine([xNoted]) == "Posted about the export fix on X.", "X row with a note: the note's line wins, as for asks")
        require(MomentPromptText.split(MomentPromptText.sent(lead: "Replied", at: "t", words: "ok")) == .init(words: "ok", lead: "Replied", at: "t")
                && MomentPromptText.split("plain ask") == .init(words: "plain ask", lead: nil, at: nil)
                && PromptLine.text("ok", lead: "Replied") == "Replied \u{201C}ok\u{201D} on X."
                && source("Sources/MemoryUI/DaydreamTodayData.swift").contains("copy.promptLead = split[m.id]?.lead")
                && source("Sources/MemoryUI/DaydreamKitMoments.swift").contains("Text(Self.open).fixedSize()\n            Text(lead == nil && asks != nil ? FocusAppCard.shortQuoteWords(prompt) : prompt).lineLimit(1).truncationMode(.tail)"),
                "the row's value carries the lead; the words cut before the closing quote, as an ask's")
        // The card uses them for X members only; its collapsed line is the time line, never "Worked in X".
        let card = source("Sources/MemoryUI/FocusAppCard.swift")
        require(card.contains("if XLines.card(members) { return XLines.sentences(lines, start: start, end: end) }")
                && card.contains("if XLines.card(members) { return XLines.timeLine(from: start, to: end) }"),
                "X cards say these lines in What happened and the collapsed line")
    }

    /// The Return marker every Return in Messages also writes.
    static func smsReturn(_ id: String, _ when: Date, title: String = "Messages") -> CanonicalAction {
        action(id, when, "keyboard.submit", app: "Messages", bundle: sms, title: title)
    }
    /// The owner's previews of these units: one per unit (separate runs), as `ownerSourcePreviews` leads them.
    static func smsPreviews(_ units: [(CanonicalAction, String)], returned: Set<String> = []) -> [OwnerSourcePreview] {
        units.map { a, words in
            let to = a.title == "Messages" ? "" : " to " + a.title
            let lead = (a.state == "submitted" ? "Submitted text" : "Drafted text") + to + " in Messages"
            return OwnerSourcePreview(id: a.id, actionIDs: [a.id], at: a.at, runID: "run-" + a.id,
                parts: [OwnerSourcePart(actionID: a.id, text: words, state: a.state)], state: a.state, lead: lead,
                readAt: at(23, 0), disclosureRevision: "fixture", expiresAt: nil, sealedByReturn: returned.contains(a.id))
        }
    }
    /// What happened as the card and the details page draw it.
    static func smsLines(_ units: [(CanonicalAction, String)], extra: [CanonicalAction] = []) -> [MomentDetailEntry] {
        let actions = units.map(\.0) + extra
        return MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(actions.reversed(), previews: smsPreviews(units)),
                                           actions: actions, timeZone: tz)
    }
    static func describe(_ lines: [MomentDetailEntry]) -> String {
        "\(lines.map { [$0.title, $0.detail] + $0.typed.map { "[\($0.text)|\($0.send ?? "-")]" } })"
    }
    static func noOldWords(_ lines: [MomentDetailEntry]) -> Bool {
        !lines.contains { e in
            e.title.contains("Pressed Return") || e.detail.contains("Pressed Return") || e.detail.contains("Typed a draft")
                || e.typed.contains { ($0.send ?? "").contains("Drafted text") || ($0.send ?? "").contains("Submission observed") }
        }
    }

    static func messagesFold() {
        // 1. Three sends in one conversation, each with its Return marker a moment later.
        let s1 = smsUnit("s1", at(2, 29, 0), "me and my friends are going to the lake tmrw", to: "Sam", sent: true)
        let s2 = smsUnit("s2", at(2, 29, 20), "wanna meet us there?", to: "Sam", sent: true)
        let s3 = smsUnit("s3", at(2, 29, 40), "were gonna have a great time", to: "Sam", sent: true)
        require(s1.state == "submitted" && s1.title == "Sam", "fixture: a detected Messages send projects as submitted, titled by its recipient",
                s1.state + "/" + s1.title)
        let r = [smsReturn("r1", at(2, 29, 1)), smsReturn("r2", at(2, 29, 21)), smsReturn("r3", at(2, 29, 41))]
        let three = [(s1, "me and my friends are going to the lake tmrw"), (s2, "wanna meet us there?"), (s3, "were gonna have a great time")]
        let threeLines = smsLines(three, extra: r)
        require(threeLines.map(\.title) == ["Sent to Sam", "Sent to Sam", "Sent to Sam"], "three sends: three \"Sent to Sam\" lines, no Return rows",
                describe(threeLines))
        require(threeLines.map { $0.typed.map(\.text) } == [["me and my friends are going to the lake tmrw"], ["wanna meet us there?"],
                                                            ["were gonna have a great time"]], "each send's exact words are its one block", describe(threeLines))
        require(noOldWords(threeLines) && threeLines.allSatisfy { $0.typed.allSatisfy { $0.send == nil } && $0.sends.isEmpty },
                "no \"Pressed Return\", \"Typed a draft\", \"Drafted text\" or \"Submission observed\"", describe(threeLines))
        require(Set(threeLines.flatMap(\.actionIDs)) == ["s1", "s2", "s3", "r1", "r2", "r3"], "every action stays reachable (the Returns fold into their sends)")
        require(FocusAppCard.sentences(threeLines, start: at(2, 29), end: at(2, 30)) == ["Texted Sam (3 times)."],
                "the card's sentence: one \"Texted Sam\" line", "\(FocusAppCard.sentences(threeLines, start: at(2, 29), end: at(2, 30)))")
        let threeQuotes = CapturedStitch.messages(CapturedStitch.fragments(smsPreviews(three)))
        require(threeQuotes == ["were gonna have a great time", "wanna meet us there?", "me and my friends are going to the lake tmrw"],
                "three sends are three quotes, newest first, never one run-on", "\(threeQuotes)")
        // The pending card: "Summary pending" over the quotes, even with the send by code ("Texted Sam") on the moment.
        var moment = slice("sms", at(2, 29), at(2, 30), subject: "Texts with Sam", app: "Messages", bundle: sms, actionIDs: ["s1", "s2", "s3"])
        moment.live = LiveMoment(label: "Texts with Sam", kind: "texts", sends: ["Texted Sam"], seconds: 60, idle: false, communication: true)
        require(FocusAppCard.collapsedLine([moment]) == "Texted Sam", "collapsed card line: \"Texted Sam\"", FocusAppCard.collapsedLine([moment]))
        // claude/messages2-1003 (owner 10/3, "texting is nuanced and contextual"): a Texts card's Summary is each
        // conversation and the texts sent, verbatim, newest first; never "Summary pending" quotes or a model paraphrase.
        let column = FocusAppCard.leftColumn([moment], previews: smsPreviews(three), pending: true)
        require(column.header == "Summary" && column.bullets.isEmpty && column.quotes.isEmpty && column.threads.map(\.title) == ["Sam"]
                && column.threads.first?.texts == threeQuotes && column.threads.first?.more == 0 && column.threads.first?.gist == nil,
                "Texts card: \"Summary\" is Sam, then the three texts verbatim, newest first", "\(column)")
        let queue = SummaryQueue(writing: ["sms"], lookedAt: at(2, 31))
        let detail = MomentDetailBody.capturedColumn(moment, previews: smsPreviews(three), phase: .on(.local), queue: queue)
        require(detail.header == "Summary" && detail.threads == column.threads, "details page: the same conversations and texts", "\(detail)")
        require(MomentDetailBody.capturedColumn(moment, previews: smsPreviews(three), phase: .off, queue: queue).threads == column.threads,
                "details page, summaries off: the texts still show")
        let noted = slice("sms", at(2, 29), at(2, 30), subject: "Texts with Sam", app: "Messages", bundle: sms,
                          bullets: [MomentBullet(text: "Texted Sam about meeting at the lake.", actionIDs: ["s2"])], actionIDs: ["s1", "s2", "s3"])
        let after = FocusAppCard.leftColumn([noted], previews: smsPreviews(three), pending: false, actions: [s1, s2, s3])
        require(after.header == "Summary" && after.quotes.isEmpty && after.bullets.isEmpty && after.threads == column.threads,
                "after the summary: still the texts, no model paraphrase of them", "\(after)")

        // 2. A send, then an unsent draft in the same conversation.
        let d1 = smsUnit("d1", at(2, 31, 0), "see you at 5", to: "Sam", sent: true)
        let d2 = smsUnit("d2", at(2, 31, 30), "also bring the", to: "Sam", sent: false)
        let sendDraft = smsLines([(d1, "see you at 5"), (d2, "also bring the")], extra: [smsReturn("dr1", at(2, 31, 1))])
        require(sendDraft.map(\.title) == ["Sent to Sam", "Draft to Sam (not sent)"] && noOldWords(sendDraft),
                "a send then a draft: \"Sent to Sam\", \"Draft to Sam (not sent)\"", describe(sendDraft))
        require(FocusAppCard.sentences(sendDraft, start: at(2, 31), end: at(2, 32)) == ["Texted Sam.", "Drafted a text to Sam (not sent)."],
                "card sentences for a send and a draft", "\(FocusAppCard.sentences(sendDraft, start: at(2, 31), end: at(2, 32)))")
        require(CapturedStitch.messages(CapturedStitch.fragments(smsPreviews([(d1, "see you at 5"), (d2, "also bring the")])))
                == ["also bring the", "see you at 5"], "a draft after a send is its own quote")

        // 3. Shift-Return: a new line inside one message stays one message.
        let nl = smsUnit("nl", at(2, 33), "first line\nsecond line", to: "Maya", sent: true)
        let nlLines = smsLines([(nl, "first line\nsecond line")], extra: [smsReturn("nlr", at(2, 33, 1))])
        require(nlLines.count == 1 && nlLines[0].title == "Sent to Maya" && nlLines[0].typed.map(\.text) == ["first line\nsecond line"],
                "Shift-Return: one sent line, its new line kept in the block", describe(nlLines))
        require(CapturedStitch.messages(CapturedStitch.fragments(smsPreviews([(nl, "first line\nsecond line")]))) == ["first line second line"],
                "Shift-Return: one quote")

        // 4. New Message with an empty To: no name, never another conversation's.
        let n0 = smsUnit("n0", at(2, 35, 0), "hi there", to: "Sam", sent: true)
        let n1 = smsUnit("n1", at(2, 35, 30), "new thread hello", to: nil, sent: true)
        let n2 = smsUnit("n2", at(2, 36, 0), "half typed", to: nil, sent: false)
        require(n1.title == "Messages", "fixture: a unit with no To is titled Messages", n1.title)
        let newMsg = smsLines([(n0, "hi there"), (n1, "new thread hello"), (n2, "half typed")],
                              extra: [smsReturn("n0r", at(2, 35, 1), title: "Sam"), smsReturn("n1r", at(2, 35, 31))])
        require(newMsg.map(\.title) == ["Sent to Sam", "Sent to someone", "Draft (not sent)"] && noOldWords(newMsg),
                "no name: \"Sent to someone\" / \"Draft (not sent)\", never Sam's, never \"unknown\"", describe(newMsg))
        require(FocusAppCard.sentences(Array(newMsg.dropFirst()), start: at(2, 35), end: at(2, 36)) == ["Texted someone.", "Drafted a text (not sent)."],
                "card sentences with no name", "\(FocusAppCard.sentences(Array(newMsg.dropFirst()), start: at(2, 35), end: at(2, 36)))")
        require(!newMsg.contains { $0.title.lowercased().contains("unknown") }, "never \"unknown\"")

        // 5. Two conversations.
        let t1 = smsUnit("t1", at(2, 40, 0), "running late", to: "Sam", sent: true)
        let t2 = smsUnit("t2", at(2, 40, 30), "can you save me a seat", to: "Maya", sent: true)
        let two = [(t1, "running late"), (t2, "can you save me a seat")]
        let twoLines = smsLines(two, extra: [smsReturn("t1r", at(2, 40, 1), title: "Sam"), smsReturn("t2r", at(2, 40, 31), title: "Maya")])
        require(twoLines.map(\.title) == ["Sent to Sam", "Sent to Maya"], "two conversations: one line each, named", describe(twoLines))
        require(CapturedStitch.messages(CapturedStitch.fragments(smsPreviews(two))) == ["can you save me a seat", "running late"],
                "two conversations: two quotes")
        let twoMoment = slice("two", at(2, 40), at(2, 41), subject: "Messages", app: "Messages", bundle: sms, actionIDs: ["t1", "t2"])
        let twoActs = [t1, t2]
        let panel = FocusAppCard.panelRows([twoMoment], sources: FocusListExpanded.allSources(from: twoActs), writingIDs: FocusAppCard.writingIDs(twoActs))
        require(panel.map(\.name) == ["Maya", "Sam"], "the panel lists both conversations by name", "\(panel.map(\.name))")

        // 6. Interrupted mid-word: "wanna me" (sealed by a focus change) + "et us there?" (the send) is one message.
        let w1 = smsUnit("w1", at(2, 45, 0), "wanna me", to: "Sam", sent: false, seal: "focus")
        let click = action("wc", at(2, 45, 5), "mouse.click", app: "Messages", bundle: sms, title: "Sam")
        let w2 = smsUnit("w2", at(2, 45, 10), "et us there? ", to: "Sam", sent: true)
        let split = [(w1, "wanna me"), (w2, "et us there? ")]
        let splitLines = smsLines(split, extra: [click, smsReturn("wr", at(2, 45, 11), title: "Sam")]).filter { !$0.quiet }
        require(splitLines.count == 1 && splitLines[0].title == "Sent to Sam" && splitLines[0].typed.map(\.text) == ["wanna meet us there?"],
                "mid-word pieces: one \"Sent to Sam\" line, one block \"wanna meet us there?\"", describe(splitLines))
        // claude/messages2-1003 (owner 10/3): the click between the pieces folds into the send too (no "Worked in Messages" row).
        require(Set(splitLines[0].actionIDs) == ["w1", "w2", "wr", "wc"], "both pieces, the click and the Return are on the one line", "\(splitLines[0].actionIDs)")
        let splitQuotes = CapturedStitch.messages(CapturedStitch.fragments(smsPreviews(split)))
        require(splitQuotes == ["wanna meet us there?"], "mid-word pieces: one quote, no space inside the word", "\(splitQuotes)")
        // The send's words are the field's whole value at Return: the piece before it is not repeated.
        let whole = [(w1, "wanna me"), (w2, "wanna meet us there?")]
        require(CapturedStitch.messages(CapturedStitch.fragments(smsPreviews(whole))) == ["wanna meet us there?"]
                && smsLines(whole).filter { !$0.quiet }.flatMap { $0.typed.map(\.text) } == ["wanna meet us there?"],
                "a send that holds the earlier piece replaces it")
        // A cut between words keeps its space.
        let spaced = [(smsUnit("x1", at(2, 47, 0), "see you ", to: "Sam", sent: false, seal: "idle"), "see you "),
                      (smsUnit("x2", at(2, 47, 9), "tomorrow", to: "Sam", sent: true), "tomorrow")]
        require(CapturedStitch.messages(CapturedStitch.fragments(smsPreviews(spaced))) == ["see you tomorrow"]
                && smsLines(spaced).flatMap { $0.typed.map(\.text) } == ["see you tomorrow"], "a cut after a space keeps the space",
                "\(CapturedStitch.messages(CapturedStitch.fragments(smsPreviews(spaced)))) \(describe(smsLines(spaced)))")
        require(MessagesTypedFold.join("wanna me", "et us") == "wanna meet us" && MessagesTypedFold.join("there?", "were") == "there? were"
                && MessagesTypedFold.join("ok", "!") == "ok!", "join: mid-word, after punctuation, before punctuation")

        // 7. Older rows (before the composer was classified): drafts with no name, each followed by Return. Not called
        // sent, not "not sent"; their Return rows stay; the mid-word pieces still stitch.
        let o1 = smsUnit("o1", at(3, 0, 0), "first one", to: nil, sent: false, seal: "submit")
        let o2 = smsUnit("o2", at(3, 0, 20), "wanna me", to: nil, sent: false, seal: "focus")
        let o3 = smsUnit("o3", at(3, 0, 25), "et us there?", to: nil, sent: false, seal: "submit")
        let old = smsLines([(o1, "first one"), (o2, "wanna me"), (o3, "et us there?")],
                           extra: [smsReturn("o1r", at(3, 0, 1)), smsReturn("o3r", at(3, 0, 26))])
        // claude/messages2-1003 (owner 10/3: no separate "Messages · Pressed Return" row): each Return folds into its text.
        require(old.map(\.title) == ["Typed in Messages", "Typed in Messages"]
                && old.map { $0.typed.map(\.text) } == [["first one"], ["wanna meet us there?"]]
                && old.map { Set($0.actionIDs) } == [["o1", "o1r"], ["o2", "o3", "o3r"]],
                "older rows: \"Typed in Messages\", each Return folded into its text, the split message stitched", describe(old))

        // 8. The old "Captured wording · time / Wrote: …" layout is gone from every view.
        let views = ["Sources/MemoryUI/DaydreamKitMoments.swift", "Sources/MemoryUI/OwnerSourceDetailSection.swift",
                     "Sources/MemoryUI/FocusListExpanded.swift", "Sources/MemoryUI/MomentTypedSection.swift", "Sources/MemoryUI/RecallDetail.swift"]
        for path in views {
            let text = source(path)
            require(!text.isEmpty && !text.contains("Text(verbatim: [\"Captured wording\"") && !text.contains("OwnerSourceStandIn(")
                    && !text.contains("excerpt.label + "), "no old Captured wording / Wrote: view in \(path)")
        }
        let page = source("Sources/MemoryUI/DaydreamKitMoments.swift")
        require(page.contains("let column = Self.capturedColumn(moment, previews: sourcePreviews, phase: phase, queue: queue, compose: composeLines, actions: actions)")
                && page.contains("let lines = FocusAppCard.summaryLines(column)") && !page.contains("header == \"Summary pending\""),
                "details page: \"Summary\" over the card's lines (claude/int-017 (owner 10/06, 0.1.7); was violet \"Summary pending\" over italic quotes)")
    }

    // MARK: claude/messages2-1003 (owner 10/3): Texts keep their words; names, folds, the whole card on the details page

    static func smsLines(_ evidence: [Evidence], words: [String: String], returned: Set<String> = [], extra: [CanonicalAction] = [])
        -> (lines: [MomentDetailEntry], previews: [OwnerSourcePreview], compose: [String: ComposeLine], actions: [CanonicalAction]) {
        let units = evidence.map { (ActionProjection.make($0), words[$0.id] ?? "") }
        let actions = (units.map(\.0) + extra).sorted { ($0.at, $0.id) < ($1.at, $1.id) }
        let previews = smsPreviews(units, returned: returned), compose = ComposeLine.lines(evidence)
        let lines = MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(actions.reversed(), previews: previews),
                                                actions: actions, timeZone: tz, compose: compose)
        return (lines, previews, compose, actions)
    }

    static func textsVerbatim() {
        let number = "+1 (555) 010-0142"
        // 1. Five texts to Sam, then two to a conversation known only by its (fictional) number, each with its Return.
        let samWords = ["lake plan is on for saturday", "bring the blue cooler", "we leave at 9", "parking is cash only", "text me when you're up"]
        var ev: [Evidence] = [], words: [String: String] = [:], extra: [CanonicalAction] = []
        for (i, w) in samWords.enumerated() {
            let id = "sam\(i)"
            ev.append(smsEvidence(id, at(4, 0, i * 10), w, to: "Sam", sent: true)); words[id] = w
            extra.append(smsReturn(id + "r", at(4, 0, i * 10 + 1), title: "Sam"))
        }
        let numWords = ["does the plan still work", "have you seen any good movies"]
        for (i, w) in numWords.enumerated() {
            let id = "num\(i)"
            ev.append(smsEvidence(id, at(4, 2, i * 10), w, to: nil, sent: true, title: "+15550100142")); words[id] = w
            extra.append(smsReturn(id + "r", at(4, 2, i * 10 + 1), title: "+15550100142"))
        }
        let r1 = smsLines(ev, words: words, extra: extra)
        require(r1.compose["num0"]?.name == number && r1.compose["num0"]?.title == "Sent to " + number && r1.compose["sam0"]?.name == "Sam",
                "a conversation known only by its number: \"Sent to +1 (555) 010-0142\", formatted, never \"someone\"",
                "\(r1.compose["num0"].map { $0.title } ?? "nil")")
        require(r1.lines.map(\.title) == Array(repeating: "Sent to Sam", count: 5) + Array(repeating: "Sent to " + number, count: 2)
                && r1.lines.map { $0.typed.map(\.text) } == (samWords + numWords).map { [$0] } && noOldWords(r1.lines),
                "What happened: one row per sent text, its exact words, no Return rows", describe(r1.lines))
        require(Set(r1.lines.flatMap(\.actionIDs)) == Set(r1.actions.map(\.id)), "every action stays reachable")
        require(FocusAppCard.sentences(r1.lines, start: at(4, 0), end: at(4, 3)) == ["Texted Sam (5 times).", "Texted \(number) (2 times)."],
                "card sentences name the number", "\(FocusAppCard.sentences(r1.lines, start: at(4, 0), end: at(4, 3)))")
        let samIDs = (0..<5).map { "sam\($0)" }, numIDs = ["num0", "num1"]
        let m1 = slice("v1", at(4, 0), at(4, 3), subject: "Texts", app: "Messages", bundle: sms,
                       bullets: [MomentBullet(text: "Texted Sam about the Saturday lake plan.", actionIDs: samIDs),
                                 MomentBullet(text: "Texted \(number) asking about the plan and movies.", actionIDs: numIDs)],
                       actionIDs: r1.actions.map(\.id))
        let c1 = FocusAppCard.leftColumn([m1], previews: r1.previews, writingIDs: FocusAppCard.writingIDs(r1.actions), pending: false,
                                         compose: r1.compose, actions: r1.actions)
        require(c1.header == "Summary" && c1.bullets.isEmpty && c1.quotes.isEmpty && c1.threads.map(\.title) == [number, "Sam"],
                "Texts card: one conversation each, newest first, by name or number; no model bullets", "\(c1)")
        require(c1.threads[0].texts == numWords.reversed() && c1.threads[0].more == 0 && c1.threads[0].gist == nil,
                "the number's texts, verbatim, newest first; no gist for a short conversation", "\(c1.threads[0])")
        require(c1.threads[1].shown == Array(samWords.reversed().prefix(3)) && c1.threads[1].more == 2
                && FocusAppCard.moreLine(c1.threads[1].more) == "+2 more" && c1.threads[1].gist == "Texted Sam about the Saturday lake plan.",
                "Sam: the 3 newest texts verbatim, \"+2 more\", and the model's line only as a short gist", "\(c1.threads[1])")
        require(FocusAppCard.moreLine(0) == nil, "no \"+0 more\"")

        // 2. The 2:37 PM screenshot: a send; a stray Return; a text Return sealed whose send wasn't confirmed; a click; a
        //    send. Three rows, each its own words: never "…pretty good" + "home alone" run together, no Return or
        //    "Worked in Messages" row.
        let b0 = smsEvidence("b0", at(14, 37, 19), "on my way back now", to: "Sam", sent: true)
        let b1 = smsEvidence("b1", at(14, 37, 23), "that sounds pretty good", to: "Sam", sent: false, seal: "submit")
        let b2 = smsEvidence("b2", at(14, 37, 24), "home alone tonight", to: "Sam", sent: true)
        let r2 = smsLines([b0, b1, b2], words: ["b0": "on my way back now", "b1": "that sounds pretty good", "b2": "home alone tonight"],
                          returned: ["b1"],
                          extra: [smsReturn("b0r", at(14, 37, 19), title: "Sam"), smsReturn("bx", at(14, 37, 22), title: "Sam"),
                                  action("bc", at(14, 37, 23), "mouse.click", app: "Messages", bundle: sms, title: "Sam"),
                                  smsReturn("b2r", at(14, 37, 24), title: "Sam"),
                                  action("bw", at(14, 37, 30), "window.changed", app: "Messages", bundle: sms, title: "Sam")])
        require(r2.compose["b1"]?.sealedByReturn == true && r2.compose["b1"]?.sent == false, "fixture: the middle text was sealed by Return, send unconfirmed")
        require(r2.lines.map(\.title) == ["Sent to Sam", "Typed to Sam", "Sent to Sam"]
                && r2.lines.map { $0.typed.map(\.text) } == [["on my way back now"], ["that sounds pretty good"], ["home alone tonight"]] && noOldWords(r2.lines),
                "two texts never join: a Return-sealed text is its own row; no Return or Worked in row", describe(r2.lines))
        require(Set(r2.lines.flatMap(\.actionIDs)) == Set(r2.actions.map(\.id)) && r2.lines.allSatisfy { !$0.quiet },
                "the stray Return, the click and the window change fold into the texts")
        require(CapturedStitch.messages(CapturedStitch.fragments(r2.previews)) == ["home alone tonight", "that sounds pretty good", "on my way back now"],
                "quotes: three texts, never stitched", "\(CapturedStitch.messages(CapturedStitch.fragments(r2.previews)))")
        let c2 = FocusAppCard.leftColumn([slice("v2", at(14, 37), at(14, 38), subject: "Texts", app: "Messages", bundle: sms, actionIDs: r2.actions.map(\.id))],
                                         previews: r2.previews, pending: true, compose: r2.compose, actions: r2.actions)
        require(c2.threads.map(\.title) == ["Sam"] && c2.threads[0].texts == ["home alone tonight", "that sounds pretty good", "on my way back now"],
                "Texts card: the three texts, each whole", "\(c2)")

        // 3. A draft never sent is not on the card; a mid-word piece is the start of its text; no name is "Other texts".
        let d0 = smsEvidence("d0", at(5, 0, 0), "wanna me", to: "Sam", sent: false, seal: "focus")
        let d1 = smsEvidence("d1", at(5, 0, 5), "et us there?", to: "Sam", sent: true)
        let d2 = smsEvidence("d2", at(5, 0, 40), "also bring the", to: "Sam", sent: false)
        let d3 = smsEvidence("d3", at(5, 1, 0), "hello from a new thread", to: nil, sent: true)
        let r3 = smsLines([d0, d1, d2, d3], words: ["d0": "wanna me", "d1": "et us there?", "d2": "also bring the", "d3": "hello from a new thread"])
        let c3 = FocusAppCard.leftColumn([slice("v3", at(5, 0), at(5, 2), subject: "Texts", app: "Messages", bundle: sms, actionIDs: r3.actions.map(\.id))],
                                         previews: r3.previews, pending: false, compose: r3.compose, actions: r3.actions)
        require(c3.threads.map(\.title) == [FocusAppCard.otherTexts, "Sam"] && c3.threads[1].texts == ["wanna meet us there?"]
                && c3.threads[0].texts == ["hello from a new thread"],
                "an unsent draft isn't shown; pieces join as typed; an unnamed conversation is \"Other texts\", never Sam's", "\(c3.threads)")
        // A text whose words couldn't be opened keeps its summary line.
        let m3 = slice("v3", at(5, 0), at(5, 2), subject: "Texts", app: "Messages", bundle: sms,
                       bullets: [MomentBullet(text: "Texted Maya about the train.", actionIDs: ["gone"])], actionIDs: r3.actions.map(\.id) + ["gone"])
        let goneAct = ActionProjection.make(smsEvidence("gone", at(5, 1, 30), "", to: "Maya", sent: true))
        let c3b = FocusAppCard.leftColumn([m3], previews: r3.previews, pending: false, compose: r3.compose, actions: r3.actions + [goneAct])
        require(c3b.threads.count == 2 && c3b.bullets.map(\.text) == ["Texted Maya about the train."],
                "a text with no words to show keeps its summary line under the texts", "\(c3b)")
        // A card of another app keeps its bullets.
        let term = slice("term", at(6, 0), at(6, 5), subject: "Terminal", app: "Terminal", bundle: "com.apple.Terminal",
                         bullets: [MomentBullet(text: "Ran the tests.", actionIDs: ["t"])], actionIDs: ["t"])
        // claude/notesfix-015: a card's own previews' quotes stand over its lines for good, so the Terminal card is given
        // none of the Texts card's previews here (a card is only ever given its own).
        require(FocusAppCard.leftColumn([term], previews: [], pending: false).threads.isEmpty
                && FocusAppCard.leftColumn([term], previews: [], pending: false).bullets.map(\.text) == ["Ran the tests."],
                "a Terminal card is unchanged")

        // 4. A Messages moment with no typing reads as what it was, never a bare "Worked in Messages".
        func readOnly(_ title: String) -> [String] {
            let acts = [action("ra", at(7, 0), "app.activated", app: "Messages", bundle: sms, title: title),
                        action("rw", at(7, 0, 5), "window.changed", app: "Messages", bundle: sms, title: title)]
            return MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(acts.reversed(), previews: []), actions: acts, timeZone: tz).map(\.title)
        }
        require(readOnly("+15550100142") == ["Read texts with " + number] && readOnly("Sam") == ["Read texts with Sam"] && readOnly("Messages") == ["Read texts"],
                "reading only: \"Read texts with …\" or \"Read texts\"", "\(readOnly("+15550100142")) \(readOnly("Sam")) \(readOnly("Messages"))")
        require(MomentDetailFold.readingTitle(["A", "B", "C"]) == "Read texts with A, B and C"
                && MomentDetailFold.readingTitle(["A", "B", "C", "D"]) == "Read texts with A, B, C and others", "reading titles list up to 3 names")

        // 5. The details page is the whole card: every member's texts (owner: "earlier texts are missing").
        var older = slice("old", at(4, 0), at(4, 1), subject: "Texts", app: "Messages", bundle: sms,
                          bullets: [MomentBullet(text: "Texted Sam.", actionIDs: ["sam0"])], actionIDs: ["sam0", "sam0r"])
        older.stale = false
        var newer = slice("new", at(4, 2), at(4, 3), subject: "Texts", app: "Messages", bundle: sms, actionIDs: ["num0", "num0r"])
        newer.currentSummary = .pending
        let merged = FocusAppCard.detailMoment(newer, members: [newer, older])
        require(merged.id == "new" && merged.actionIDs == ["sam0", "sam0r", "num0", "num0r"] && merged.start == at(4, 0) && merged.end == at(4, 3)
                && merged.actionCount == 4 && merged.bullets.map(\.text) == ["Texted Sam."],
                "details page: the anchor with every member's actions, oldest first", "\(merged.actionIDs)")

        // 6. No writer schedule anywhere: a moment still going has no line; a previous summary at most "Updating…".
        require(SummaryQueue.openLine.isEmpty && SummaryQueue(lookedAt: at(4, 0)).line(for: newer, phase: .on(.local)) == ""
                && !source("Sources/MemoryUI/DaydreamTodayData.swift").contains("about every 10 minutes"),
                "the \"Local summary updates about every 10 minutes\" line is gone")
        var stale = slice("st", at(4, 0), at(4, 1), subject: "Texts", app: "Messages", bundle: sms,
                          bullets: [MomentBullet(text: "Texted Sam.", actionIDs: ["sam0"])], actionIDs: ["sam0"])
        stale.stale = true
        // claude/notesfix-015 + claude/int-017 (owner 10/06, 0.1.7): never "Updating…" on a card.
        require(stale.previousSummaryStatus(phase: .on(.local), queue: nil) == nil
                && stale.previousSummaryStatus(phase: .off, queue: nil) == nil
                && slice("fresh", at(4, 0), at(4, 1), subject: "Texts", app: "Messages", bundle: sms,
                         bullets: [MomentBullet(text: "Texted Sam.")], actionIDs: ["sam0"]).previousSummaryStatus(phase: .on(.local), queue: nil) == nil,
                "a previous summary: its bullets, never \"Updating…\"")
        require(!source("Sources/MemoryUI/DaydreamTodayData.swift").contains("Previous summary \u{00B7}")
                && !source("Sources/MemoryUI/DaydreamTodayData.swift").contains("\"Previous summary"), "never \"Previous summary · …\"")
    }

    // MARK: compose-send/v1 (owner 10/3): every composer's What happened row from its compose line

    struct Unit { var surface = "other"; var field = "message"; var sent = false; var sendBy: String? = nil; var control: String? = nil
                  var to: String? = nil; var handle: String? = nil; var community: String? = nil; var subject: String? = nil
                  var author: String? = nil; var excerpt: String? = nil }
    static func composeRow(_ id: String, _ when: Date, app: String, bundle: String, title: String, url: String = "", words: String, _ u: Unit) -> Evidence {
        var e = Evidence(id: id, at: iso(when), kind: "keyboard.text_input", app: app, bundle: bundle, title: title, url: url, text: words, synthetic: true)
        var unit = TypedUnitProvenance(runID: "run-" + id, part: 1, sealReason: u.sent ? (u.sendBy == "button" ? "pointer" : "submit") : "idle",
            startedAt: iso(when), keys: nil, edits: nil, withheld: 0, surface: u.surface, field: u.field, send: u.sent ? "detected" : "unknown",
            sendBy: u.sent ? (u.sendBy ?? "return") : nil, to: u.to)
        unit.sendControl = u.control; unit.handle = u.handle; unit.community = u.community; unit.subject = u.subject
        unit.contextAuthor = u.author; unit.contextExcerpt = u.excerpt; unit.confirm = u.sent ? "fieldCleared" : nil
        e.captureProvenance = NativeCaptureProvenance(policyRevision: "synthetic", classifierVersion: "fixture", windowID: "w", focusID: "f",
                                                     checkedAt: iso(when), generation: 1, unit: unit)
        return e
    }
    static func view(_ id: String, _ when: Date, app: String, bundle: String, title: String, url: String) -> CanonicalAction {
        ActionProjection.make(Evidence(id: id, at: iso(when), kind: "window.changed", app: app, bundle: bundle, title: title, url: url, text: "", synthetic: true))
    }
    /// What happened for typed rows (with their words) and other actions, titled by the rows' compose lines.
    static func composed(_ rows: [(Evidence, String)], extra: [CanonicalAction] = []) -> [MomentDetailEntry] {
        let units = rows.map { (ActionProjection.make($0.0), $0.1) }
        let actions = units.map(\.0) + extra
        return MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(actions.reversed(), previews: smsPreviews(units)),
                                           actions: actions, timeZone: tz, compose: ComposeLine.lines(rows.map(\.0)))
    }

    static func composeLines() {
        let chrome = "com.google.Chrome"
        // Messages ×3, titled by their compose lines: the same three "Sent to Sam" lines, the Returns folded in.
        let msgs = [("m1", "first text"), ("m2", "second text"), ("m3", "third text")].enumerated().map { i, p in
            (composeRow(p.0, at(4, 0, i * 20), app: "Messages", bundle: sms, title: "Sam", words: p.1,
                        Unit(surface: "text", field: "message", sent: true, to: "Sam")), p.1)
        }
        let msgLines = composed(msgs, extra: [smsReturn("m1r", at(4, 0, 1)), smsReturn("m2r", at(4, 0, 21)), smsReturn("m3r", at(4, 0, 41))])
        require(ComposeLine(evidence: msgs[0].0)?.title == "Sent to Sam", "ComposeView: a Messages send is \"Sent to Sam\"")
        require(msgLines.map(\.title) == ["Sent to Sam", "Sent to Sam", "Sent to Sam"] && noOldWords(msgLines)
                && msgLines.map { $0.typed.map(\.text) } == [["first text"], ["second text"], ["third text"]],
                "Messages ×3 by compose line: three sent lines, exact words, no Return rows", describe(msgLines))

        // X reply by the Reply button, on the post's own page: the page-visit row of that post is replaced.
        let postTitle = "Ada on X: \"Small tools beat big frameworks for most side projects\" / X"
        let postURL = "https://x.com/ada/status/1"
        let excerpt = "Small tools beat big frameworks for most side projects"
        let reply = composeRow("xr", at(5, 0, 10), app: "Google Chrome", bundle: chrome, title: postTitle, url: postURL, words: "agreed, fewer lines",
                               Unit(surface: "social", field: "body", sent: true, sendBy: "button", control: "reply", handle: "ada",
                                    author: "Ada", excerpt: excerpt))
        let seen = view("xv", at(5, 0, 0), app: "Google Chrome", bundle: chrome, title: postTitle, url: postURL)
        let xLines = composed([(reply, "agreed, fewer lines")], extra: [seen])
        require(xLines.count == 1 && xLines[0].title == "Replied to Ada's post on X" && xLines[0].typed.map(\.text) == ["agreed, fewer lines"]
                && xLines[0].context == "on: \u{201C}\(excerpt)\u{201D}",
                "X reply (button): \"Replied to Ada's post on X\", its words, the muted replied-to line", describe(xLines) + " \(xLines.map(\.context))")
        require(Set(xLines[0].actionIDs) == ["xr", "xv"] && xLines[0].isWeb, "the reply replaced the visit row of the same post; both stay reachable")
        require(FocusAppCard.sentences(xLines, start: at(5, 0), end: at(5, 1)) == ["Replied to Ada's post on X."], "card sentence for a reply")
        // X reply by Command-Return: its Return marker folds in.
        let reply2 = composeRow("xc", at(5, 2, 0), app: "Google Chrome", bundle: chrome, title: postTitle, url: postURL, words: "ship it",
                                Unit(surface: "social", field: "body", sent: true, sendBy: "commandReturn", control: "reply", author: "Ada", excerpt: excerpt))
        let cmdReturn = ActionProjection.make(Evidence(id: "xcr", at: iso(at(5, 2, 1)), kind: "keyboard.submit", app: "Google Chrome", bundle: chrome,
                                                       title: postTitle, url: postURL, text: "", synthetic: true))
        let xc = composed([(reply2, "ship it")], extra: [cmdReturn])
        require(xc.map(\.title) == ["Replied to Ada's post on X"] && Set(xc[0].actionIDs) == ["xc", "xcr"] && noOldWords(xc),
                "X reply (Command-Return): one line, the Return folded in", describe(xc))
        // An X post typed and discarded: a draft.
        let discarded = composeRow("xd", at(5, 5), app: "Google Chrome", bundle: chrome, title: "Home / X", url: "https://x.com/home",
                                   words: "hot take I thought better of", Unit(surface: "social", field: "body", sent: false))
        let xd = composed([(discarded, "hot take I thought better of")])
        require(xd.map(\.title) == ["Draft in X (not sent)"] && xd[0].typed.map(\.text) == ["hot take I thought better of"],
                "X post discarded: \"Draft in X (not sent)\"", describe(xd))

        // A Reddit comment.
        let comment = composeRow("rc", at(6, 0), app: "Google Chrome", bundle: chrome, title: "Why is my build slow? : r/swift",
                                 url: "https://www.reddit.com/r/swift/comments/abc/why/", words: "try a clean build first",
                                 Unit(surface: "social", field: "body", sent: true, sendBy: "button", control: "comment", community: "swift",
                                      excerpt: "Why is my build slow?"))
        let rc = composed([(comment, "try a clean build first")])
        require(rc.map(\.title) == ["Commented on r/swift"] && rc[0].context == "on: \u{201C}Why is my build slow?\u{201D}",
                "Reddit comment: \"Commented on r/swift\" with the post's title under it", describe(rc))

        // A Gmail send.
        let mail = composeRow("gm", at(7, 0), app: "Google Chrome", bundle: chrome, title: "Pricing - me@example.com - Gmail",
                              url: "https://mail.google.com/mail/u/0/", words: "numbers attached",
                              Unit(surface: "email", field: "body", sent: true, sendBy: "mailSend", to: "Sam", subject: "Pricing"))
        let gm = composed([(mail, "numbers attached")])
        require(gm.map(\.title) == ["Emailed Sam \u{2014} Pricing"] && gm[0].typed.map(\.text) == ["numbers attached"], "Gmail: \"Emailed Sam — Pricing\"",
                describe(gm))

        // An unknown composer: still sent or draft, with no destination; its Return folds in.
        let other = composeRow("uk", at(8, 0), app: "Fictional Chat", bundle: "com.example.fictional", title: "Room", words: "hello room",
                               Unit(surface: "other", field: "message", sent: true))
        let ukReturn = action("ukr", at(8, 0, 1), "keyboard.submit", app: "Fictional Chat", bundle: "com.example.fictional", title: "Room")
        let uk = composed([(other, "hello room")], extra: [ukReturn])
        require(uk.count == 1 && uk[0].title == "Sent in Fictional Chat" && Set(uk[0].actionIDs) == ["uk", "ukr"] && noOldWords(uk),
                "unknown composer: \"Sent in Fictional Chat\", Return folded in", describe(uk))
        let ukDraft = composed([(composeRow("ud", at(8, 5), app: "Fictional Chat", bundle: "com.example.fictional", title: "Room", words: "never mind",
                                            Unit(surface: "other", field: "message", sent: false)), "never mind")])
        require(ukDraft.map(\.title) == ["Draft in Fictional Chat (not sent)"], "unknown composer draft", describe(ukDraft))

        // Shift-Return: one unit, its new line kept, one sent line.
        let shift = composeRow("sr", at(9, 0), app: "Messages", bundle: sms, title: "Maya", words: "line one\nline two",
                               Unit(surface: "text", field: "message", sent: true, to: "Maya"))
        let sr = composed([(shift, "line one\nline two")], extra: [smsReturn("srr", at(9, 0, 1))])
        require(sr.count == 1 && sr[0].title == "Sent to Maya" && sr[0].typed.map(\.text) == ["line one\nline two"], "Shift-Return by compose line",
                describe(sr))

        // The views that render What happened pass the compose lines through.
        let card = source("Sources/MemoryUI/FocusListExpanded.swift"), detailPage = source("Sources/MemoryUI/FocusListDetail.swift")
        let body = source("Sources/MemoryUI/DaydreamKitMoments.swift"), row = source("Sources/MemoryUI/MomentTypedSection.swift")
        require(card.contains("compose: composeLines)") && card.contains("browser.loadComposeLines")
                && detailPage.contains("composeLines: composeLines)") && detailPage.contains("browser.loadComposeLines")
                && body.components(separatedBy: "compose: composeLines)").count == 3
                && row.contains("if let context = entry.context {"), "card, details page and entry row use the compose lines and the context line")
    }

    /// Source pins for what only a window shows: two columns, the panel's link, the footer, the header.
    static func cardLayout() {
        let card = source("Sources/MemoryUI/FocusListExpanded.swift")
        require(card.contains("HStack(alignment: .top, spacing: 18) {\n                    summary.frame(maxWidth: .infinity, alignment: .leading)\n                    panel.frame(width: Self.panelWidth)")
                && card.contains("VStack(alignment: .leading, spacing: 14) { summary; panel }"), "two columns; the panel stacks when narrow")
        require(card.contains("Button(action: showAll) {\n                HStack(spacing: 4) {\n                    Text(FocusAppCard.panelLink(rows: rows.count))"),
                "the panel's link opens the details page")
        require(!card.contains("detailsOpen") && !card.contains("MomentDetailEntries("), "nothing expands in place; no What happened list in the card")
        require(card.contains("AppIcon(bundle: row.bundle.isEmpty ? nil : row.bundle, name: row.name, size: 18)")
                && card.contains("WebMonogramTile(domain: row.site, browserBundle: nil, size: 18)"), "panel rows: the app's icon or the site's")
        require(card.contains("HStack(spacing: 8) {\n                ForEach(main) { button($0) }\n                if let extra { extra }\n                Spacer(minLength: 12)\n                ForEach(privacy) { privacyButton($0) }"),
                "Copy Summary on the left, Forget on the right")
        require(card.contains(".filter { $0.id != .summarizeNow }"), "the footer is Copy Summary and Forget only")
        // claude/int-017 (owner 10/06, 0.1.7): a grey "Summary" (never the model's violet "Summary pending") over code's lines, one grey dot each.
        require(!card.contains("CardSummaryState.violet(header)") && card.contains("Text(\"Summary\").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)"),
                "a grey \"Summary\", never the model's violet \"Summary pending\"")
        let rows = source("Sources/MemoryUI/FocusListRows.swift")
        require(rows.contains("FocusAppCardItem(session: session, context: context)"), "every card is an app card")
        require(rows.contains("Text(line).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)")
                && rows.contains("Text(range).font(.system(size: 12)).monospacedDigit()") && !rows.contains("chevron.down")
                && rows.contains("let range = FocusAppCard.latestTime(members, timeZone: context.timeZone)"),
                "header: title with the summary line under it, the latest time on the right, no chevron")
        // claude/int-017 (owner 10/06, 0.1.7): the Summary shows about 5 lines; "+N more" opens the rest inline ("Show less" closes them).
        require(card.contains("FocusAppCard.visibleSummary(shown, expanded: quotesOpen)") && card.contains("OverflowToggle(collapsed: FocusAppCard.summaryMore(shown), expanded: $quotesOpen"),
                "\"+N more\" opens the rest of the Summary inline")
        let detail = source("Sources/MemoryUI/DaydreamKitMoments.swift")
        require(detail.contains("MomentDetailEntries(entries: MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(actions, previews: sourcePreviews),"),
                "the details page keeps its layout with a condensed What happened")

        // Titles elsewhere (Recall, VoiceOver) are still never withheld.
        let term = "com.apple.Terminal"
        func moment(_ title: String, apps: [String], bundles: [String], bullet: String? = nil) -> MomentSlice {
            MomentSlice(id: "x", dayKey: "2026-10-02", start: at(17, 14), end: at(17, 22), title: title, subject: title, firstBullet: bullet,
                bullets: bullet.map { [MomentBullet(text: $0)] } ?? [], apps: apps, primaryBundle: bundles.first, bundles: bundles, sites: [],
                actionIDs: ["x:a"], actionCount: 1, clusters: [], summary: bullet == nil ? .pending : .ready(generatedAt: nil, local: true),
                hasCorrection: false, primaryApp: apps.first)
        }
        let both = moment("[sensitive title omitted] code", apps: ["Terminal", "Ghostty"], bundles: [term, "com.mitchellh.ghostty"])
        require(MomentSubtitle.rowTitle(both) == "Terminal, Ghostty", "withheld title: the apps' names", MomentSubtitle.rowTitle(both))
        require(FocusAppCard.title([both]) == "Terminal, Ghostty", "a moment over two apps: both named in the card title", FocusAppCard.title([both]))
        let withLine = moment("[sensitive title omitted] code", apps: ["Terminal"], bundles: [term], bullet: "Ran the parser tests.")
        require(MomentSubtitle.rowTitle(withLine) == "Ran the parser tests", "withheld title: the summary line", MomentSubtitle.rowTitle(withLine))
        require(source("Sources/MemoryUI/DaydreamKitIcons.swift").contains("if apps.count > 1 { badge(apps[1]) }"), "two apps: stacked icons")
    }

    /// perf (claude/perf-1002): the timeline skips app-model changes it doesn't read; a card redraws only for its own
    /// hover-light, selection or data, never for another card's.
    static func redraws() {
        let browser = ActivityBrowser(calendar: cal)
        func shell(_ title: String, recording: Bool, resume: Bool = false) -> ShellTimeline {
            ShellTimeline(browser: browser, state: CapturePresentation(title: title, recording: recording, canResume: resume), actions: CaptureActions())
        }
        require(shell("Recording", recording: true) == shell("Recording", recording: true), "an app-model change that keeps the recording state skips the timeline")
        require(shell("Recording", recording: true) != shell("Paused", recording: false, resume: true), "a recording-state change redraws it")
        require(ShellTimeline(browser: ActivityBrowser(calendar: cal), state: CapturePresentation(title: "Recording", recording: true), actions: CaptureActions())
                != shell("Recording", recording: true), "another browser redraws it")
        require(source("Sources/MemoryUI/MemoryShell.swift").contains("ShellTimeline(browser: browser, state: state, actions: actions).equatable()"),
                "the shell hosts the deduplicated timeline")

        let sms = "com.apple.MobileSMS"
        let a = slice("ca", at(9, 0), at(9, 1), subject: "Texts with Q7", app: "Messages", bundle: sms, actionIDs: ["ca"])
        let b = slice("cb", at(9, 30), at(9, 31), subject: "Notes", app: "Notes", bundle: "com.apple.Notes", actionIDs: ["cb"])
        let sessions = FocusListLayout.sessions([a, b], sectionID: "loose")
        let caps = MomentActions.Capabilities(browser: browser)
        func context(selected: String? = nil, linked: String? = nil, expanded: String? = nil) -> FocusListRowContext {
            FocusListRowContext(timeZone: tz, selectedID: selected, expandedID: expanded, narrow: false, compact: false,
                items: { _ in [] }, toggle: { _ in }, perform: { _, _ in }, expandedBody: { _, _ in AnyView(EmptyView()) },
                linked: linked, caps: caps)
        }
        guard let cardA = sessions.first(where: { $0.members.contains { $0.id == "ca" } }) else { require(false, "card A"); return }
        func item(_ c: FocusListRowContext) -> FocusAppCardItem { FocusAppCardItem(session: cardA, context: c) }
        require(item(context()) == item(context()), "nothing changed: no redraw")
        require(item(context(linked: "cb")) == item(context()), "the ribbon lighting another card: no redraw")
        require(item(context(selected: "cb")) == item(context(selected: nil)), "selecting another card: no redraw")
        require(item(context(linked: "ca")) != item(context()), "its own ribbon light redraws it")
        require(item(context(selected: "ca")) != item(context()), "its own selection redraws it")
        require(item(context(expanded: "ca")) != item(context(expanded: "ca")), "an open card always redraws (live loads)")
        let rows = source("Sources/MemoryUI/FocusListRows.swift")
        require(rows.contains("FocusAppCardItem(session: session, context: context).equatable()") && rows.contains("@State private var hovered = false"),
                "cards compare before redrawing; hover is each header's own state")
    }

    /// Owner 10/3: Copy Summary under the icon's left edge; Summarize Now beside it while the summary is pending or failed.
    static func footer() {
        let card = source("Sources/MemoryUI/FocusListExpanded.swift")
        require(card.contains("footer(items).padding(.leading, -Self.footerOutdent)") && FocusListExpanded.footerOutdent == 42,
                "the footer steps out 42 pt from the title column to the icon's left edge (54 - 12)")
        require(card.contains("ForEach(main) { button($0) }\n                if let extra { extra }\n                Spacer(minLength: 12)")
                && card.contains("summarizeButton\n                Spacer(minLength: 12)"), "Summarize Now right after Copy Summary; Forget stays right")
        require(card.contains("perform(.summarizeNow)") && card.contains("(.summarizeNow, m)"), "it runs the existing Summarize Now action")
        require(FocusAppCard.summarizeTitle == "Summarize Now" && FocusAppCard.summarizingTitle == "Summarizing\u{2026}", "titles")
        // When it shows.
        // claude/notesfix-015 + claude/int-017 (owner 10/06, 0.1.7): never on a card.
        require(!FocusAppCard.offersSummarizeNow(bullets: false, header: "Summary pending", targets: 1, running: false), "pending: not shown")
        require(!FocusAppCard.offersSummarizeNow(bullets: false, header: "What you wrote", targets: 2, running: false), "failed: not shown")
        require(!FocusAppCard.offersSummarizeNow(bullets: true, header: "Summary", targets: 1, running: false), "a summary exists: hidden")
        require(!FocusAppCard.offersSummarizeNow(bullets: false, header: nil, targets: 1, running: false), "noise-only card (no header): hidden")
        require(!FocusAppCard.offersSummarizeNow(bullets: false, header: "What you wrote", targets: 0, running: false),
                "nothing the existing Summarize Now could write: hidden")
        require(!FocusAppCard.offersSummarizeNow(bullets: false, header: "Summary pending", targets: 0, running: true), "running: not shown either")
        // Which members: every one without a summary that the existing action may write.
        let browser = ActivityBrowser(calendar: cal)
        browser.generateCanonicalNote = { _, _, _, _ in }
        browser.summaries = SummaryAvailability(provider: .local, busy: false)
        let caps = MomentActions.Capabilities(browser: browser)
        let sms = "com.apple.MobileSMS"
        let pendingA = slice("pa", at(9, 0), at(9, 1), subject: "Texts with Q7", app: "Messages", bundle: sms, actionIDs: ["pa"])
        let pendingB = slice("pb", at(9, 2), at(9, 3), subject: "Texts with Alex", app: "Messages", bundle: sms, actionIDs: ["pb"])
        let written = slice("w", at(9, 4), at(9, 5), subject: "Texts with Sam", app: "Messages", bundle: sms,
                            bullets: [MomentBullet(text: "Texted Sam about Friday.")], actionIDs: ["w"])
        var tooLong = slice("tl", at(9, 6), at(9, 7), subject: "Texts with Jo", app: "Messages", bundle: sms, actionIDs: ["tl"])
        tooLong = MomentSlice(id: tooLong.id, dayKey: tooLong.dayKey, start: tooLong.start, end: tooLong.end, title: tooLong.title,
            subject: tooLong.subject, firstBullet: nil, bullets: [], apps: tooLong.apps, primaryBundle: sms, bundles: [sms], sites: [],
            actionIDs: ["tl"], actionCount: 1, clusters: [], summary: .tooLong, hasCorrection: false, primaryApp: "Messages")
        let targets = FocusAppCard.summarizeTargets([pendingA, pendingB, written, tooLong], caps: caps).map(\.id)
        require(targets == ["pa", "pb"], "several pending moments: all of them, not the written or too-long ones", "\(targets)")
        let off = ActivityBrowser(calendar: cal)
        require(FocusAppCard.summarizeTargets([pendingA], caps: MomentActions.Capabilities(browser: off)).isEmpty,
                "the same gates as the existing Summarize Now (no writer: nothing)")
    }
}
