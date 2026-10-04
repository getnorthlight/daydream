import Foundation

/// SYNTHETIC (made up; no real data): a multitasking Monday for the preview and the threads checks (Preview 4). The
/// sample founder writes the Q3 investor update most of the morning while texting Maya and Sam, a Slack channel and a
/// DM ping, a Claude chat about the update's metrics and a metrics sheet cut in; a weekly sync with notes, a YouTube
/// break; after lunch a GitHub pull request review with the code open in Xcode; then the update again, and emailing it.
/// The morning starts with email triage. Its rows have the week fixture's shape (`PreviewSampleFixture`), dated
/// Monday 2026-09-21 in the fixture's zone (sample day 7), and its moment notes are written like the local writer's.
/// Typed rows carry made-up words, sealed at ingest like any typed row; no note or level copies them.
public enum PreviewThreadsDay {
    public static let day = "2026-09-21"
    /// The fixture's zone is America/Los_Angeles: 7 hours behind UTC in September.
    static let utcOffsetHours = 7

    public struct Note { public var ids: [String]; public var title: String; public var bullets: [(text: String, ids: [String], assertion: String)] }

    /// (rows in the fixture's JSON shape, moment notes).
    public static func make() -> (rows: [[String: Any]], notes: [Note]) {
        var rows = [[String: Any]](), counter = 0
        func at(_ hm: String, plus seconds: Int = 0) -> String {
            let p = hm.split(separator: ":").compactMap { Int($0) }
            let total = (p[0] + utcOffsetHours) * 3600 + p[1] * 60 + seconds
            return String(format: "%@T%02d:%02d:%02dZ", day, total / 3600, (total % 3600) / 60, total % 60)
        }
        func nextID() -> String { counter += 1; return String(format: "thr-%04d", counter) }
        func row(_ kind: String, _ time: String, _ app: String, _ bundle: String, _ title: String, _ url: String) -> String {
            let id = nextID()
            rows.append(["id": id, "at": time, "kind": kind, "app": app, "bundle": bundle, "title": title, "url": url, "text": "",
                         "secure": false, "privateWindow": false, "synthetic": true])
            return id
        }
        /// A window used from `from` for `minutes`: opened, a click, then a sample every 2 minutes.
        func stretch(_ app: String, _ bundle: String, _ title: String, _ url: String, _ from: String, _ minutes: Int) -> [String] {
            var ids = [row("window.changed", at(from), app, bundle, title, url), row("mouse.click", at(from, plus: 10), app, bundle, title, url)]
            var s = 120
            while s < minutes * 60 { ids.append(row("window.observed", at(from, plus: s), app, bundle, title, url)); s += 120 }
            return ids
        }
        /// A typed unit (made-up words), with its send key when `to` is given, `seconds` after `from`.
        func typed(_ app: String, _ bundle: String, _ title: String, _ from: String, _ seconds: Int, surface: String, to: String?, words: String) -> [String] {
            let time = at(from, plus: seconds), id = nextID(), send = to != nil
            var unit: [String: Any] = ["part": 1, "runID": "thr-run-\(counter)", "sealReason": send ? "submit" : "idle", "send": send ? "detected" : "none",
                                       "startedAt": at(from, plus: max(0, seconds - 40)), "surface": surface, "version": "typed-unit/v3", "withheld": 0,
                                       "keys": NSNull(), "edits": NSNull()]
            if send { unit["sendBy"] = surface == "email" ? "mailSend" : "return" }
            if surface == "text" { unit["field"] = "message" } // fabricated positively identified body, B2
            if let to { unit["to"] = to }
            rows.append(["id": id, "at": time, "kind": "keyboard.text_input", "app": app, "bundle": bundle, "title": title, "url": "", "text": words,
                         "secure": false, "privateWindow": false, "synthetic": true,
                         "captureProvenance": ["checkedAt": time, "classifierVersion": "sensitive-typing/v2", "focusID": "f", "generation": 1,
                                               "policyRevision": "synthetic", "unit": unit, "windowID": "w"] as [String: Any]])
            var ids = [id]
            if send { ids.append(row("keyboard.submit", at(from, plus: seconds + 1), app, bundle, title, "")) }
            return ids
        }
        let mail = ("Mail", "com.apple.mail"), chrome = ("Chrome", "com.google.Chrome"), messages = ("Messages", "com.apple.MobileSMS")
        let docTitle = "Q3 investor update - Google Docs", docURL = "https://docs.google.com"
        let slackURL = "https://app.slack.com"
        var notes = [Note]()
        func note(_ title: String, _ ids: [String], _ bullets: [(String, [String], String)]) {
            notes.append(Note(ids: ids, title: title, bullets: bullets.map { (text: $0.0, ids: $0.1, assertion: $0.2) }))
        }

        // 8:40 email triage.
        let inbox = stretch(mail.0, mail.1, "Inbox – iCloud (14 messages)", "", "08:40", 3)
        note("Morning inbox", inbox, [("Had the iCloud inbox open in Mail.", inbox, "observed")])
        let pilot = stretch(mail.0, mail.1, "Re: Pilot with Northwind", "", "08:43", 4)
        let pilotSend = typed(mail.0, mail.1, "Re: Pilot with Northwind", "08:43", 170, surface: "email", to: "Dana",
                              words: "Hi Dana, Thursday works for the pilot kickoff. I'll bring the rollout plan.")
        note("Northwind pilot reply", pilot + pilotSend, [("Had the Northwind pilot thread open in Mail.", pilot, "observed"),
                                                          ("Emailed Dana about the Northwind pilot kickoff.", pilotSend, "submitted")])
        let invoice = stretch(mail.0, mail.1, "Invoice #3107 from Hostwell", "", "08:47", 2)
        note("Hostwell invoice", invoice, [("Had the Hostwell invoice email open in Mail.", invoice, "observed")])
        let board = stretch(mail.0, mail.1, "Re: Q3 numbers for the board", "", "08:49", 6)
        let boardSend = typed(mail.0, mail.1, "Re: Q3 numbers for the board", "08:49", 250, surface: "email", to: "Priya",
                              words: "Priya, final numbers go out with the update this afternoon.")
        note("Q3 numbers for the board", board + boardSend, [("Had the Q3 numbers thread open in Mail.", board, "observed"),
                                                             ("Emailed Priya about the Q3 numbers for the board.", boardSend, "submitted")])

        // 8:55 to 11:10 the investor update, with texts, Slack, Claude and a sheet cut in.
        var doc = stretch(chrome.0, chrome.1, docTitle, docURL, "08:55", 23)
        let maya1 = stretch(messages.0, messages.1, "Maya", "", "09:18", 3)
        let maya1Send = typed(messages.0, messages.1, "Maya", "09:18", 100, surface: "text", to: "Maya", words: "Running ten late for lunch, save me a seat")
        note("Maya in Messages", maya1 + maya1Send, [("Had Messages open with Maya.", maya1, "observed"), ("Texted Maya about lunch.", maya1Send, "submitted")])
        doc += stretch(chrome.0, chrome.1, docTitle, docURL, "09:21", 14)
        let eng1 = stretch(chrome.0, chrome.1, "#eng (Channel) - Tallybird - Slack", slackURL, "09:35", 5)
        note("Eng channel in Slack", eng1, [("Had the eng channel open in Slack.", eng1, "observed")])
        doc += stretch(chrome.0, chrome.1, docTitle, docURL, "09:40", 12)
        let sam1 = stretch(messages.0, messages.1, "Sam", "", "09:52", 4)
        let sam1Send = typed(messages.0, messages.1, "Sam", "09:52", 170, surface: "text", to: "Sam", words: "Can you send the churn chart before noon?")
        note("Sam in Messages", sam1 + sam1Send, [("Had Messages open with Sam.", sam1, "observed"), ("Texted Sam asking for the churn chart.", sam1Send, "submitted")])
        doc += stretch(chrome.0, chrome.1, docTitle, docURL, "09:56", 9)
        let claude = stretch("Claude", "com.anthropic.claudefordesktop", "Investor update metrics", "", "10:05", 7)
        let claudeAsk = typed("Claude", "com.anthropic.claudefordesktop", "Investor update metrics", "10:05", 150, surface: "ai", to: "Claude",
                              words: "Which three metrics should lead a seed-stage investor update?")
        note("Investor update metrics", claude + claudeAsk, [("Asked Claude which metrics should lead the investor update.", claudeAsk, "submitted"),
                                                             ("Had the Investor update metrics chat open in Claude.", claude, "observed")])
        doc += stretch(chrome.0, chrome.1, docTitle, docURL, "10:12", 8)
        let maya2 = stretch(messages.0, messages.1, "Maya", "", "10:20", 2)
        note("Maya in Messages", maya2, [("Had Messages open with Maya.", maya2, "observed")])
        doc += stretch(chrome.0, chrome.1, docTitle, docURL, "10:22", 8)
        let sheet = stretch(chrome.0, chrome.1, "Q3 metrics - Google Sheets", docURL, "10:30", 8)
        note("Q3 metrics sheet", sheet, [("Had the Q3 metrics sheet open in Google Sheets.", sheet, "observed")])
        doc += stretch(chrome.0, chrome.1, docTitle, docURL, "10:38", 7)
        let sam2 = stretch(messages.0, messages.1, "Sam", "", "10:45", 3)
        note("Sam in Messages", sam2, [("Had Messages open with Sam.", sam2, "observed")])
        let priya = stretch(chrome.0, chrome.1, "Priya (DM) - Tallybird - Slack", slackURL, "10:48", 4)
        note("Priya in Slack", priya, [("Had a Slack DM with Priya open.", priya, "observed")])
        doc += stretch(chrome.0, chrome.1, docTitle, docURL, "10:52", 18)
        note("Q3 investor update", doc, [("Had the Q3 investor update open in Google Docs.", doc, "observed")])

        // 11:30 the weekly sync, notes in it; then a YouTube break.
        var sync = stretch("Zoom", "us.zoom.xos", "Weekly sync - Tallybird", "", "11:30", 10)
        let syncNotes = stretch("Notes", "com.apple.Notes", "Weekly sync notes", "", "11:40", 4)
        let syncTyped = typed("Notes", "com.apple.Notes", "Weekly sync notes", "11:40", 200, surface: "writing", to: nil,
                              words: "ship export beta wed, Sam owns churn chart, pricing page after launch")
        note("Weekly sync notes", syncNotes + syncTyped, [("Wrote notes for the weekly sync in Notes.", syncTyped, "draft"),
                                                          ("Had Weekly sync notes open in Notes.", syncNotes, "observed")])
        sync += stretch("Zoom", "us.zoom.xos", "Weekly sync - Tallybird", "", "11:44", 6)
        let maya3 = stretch(messages.0, messages.1, "Maya", "", "11:50", 1)
        note("Maya in Messages", maya3, [("Had Messages open with Maya.", maya3, "observed")])
        sync += stretch("Zoom", "us.zoom.xos", "Weekly sync - Tallybird", "", "11:51", 9)
        note("Weekly sync", sync, [("Had the Tallybird weekly sync open in Zoom.", sync, "observed")])
        var youtube = stretch(chrome.0, chrome.1, "How Linear builds product - YouTube", "https://www.youtube.com", "12:00", 6)
        let sam3 = stretch(messages.0, messages.1, "Sam", "", "12:06", 1)
        note("Sam in Messages", sam3, [("Had Messages open with Sam.", sam3, "observed")])
        youtube += stretch(chrome.0, chrome.1, "How Linear builds product - YouTube", "https://www.youtube.com", "12:07", 7)
        note("How Linear builds product", youtube, [("Watched How Linear builds product on YouTube.", youtube, "observed")])

        // 1:00 PM a pull request review, the code in Xcode.
        let prTitle = "Add weekly summaries export by sam · Pull Request #418 · tallybird/tallybird"
        let pr1 = stretch(chrome.0, chrome.1, prTitle, "https://github.com", "13:00", 25)
        let eng2 = stretch(chrome.0, chrome.1, "#eng (Channel) - Tallybird - Slack", slackURL, "13:25", 4)
        note("Eng channel in Slack", eng2, [("Had the eng channel open in Slack.", eng2, "observed")])
        let xcode = stretch("Xcode", "com.apple.dt.Xcode", "WeeklySummaryExport.swift — Tallybird", "", "13:29", 18)
        note("WeeklySummaryExport.swift in Xcode", xcode, [("Had WeeklySummaryExport.swift open in Xcode.", xcode, "observed")])
        let maya4 = stretch(messages.0, messages.1, "Maya", "", "13:47", 2)
        note("Maya in Messages", maya4, [("Had Messages open with Maya.", maya4, "observed")])
        let pr2 = stretch(chrome.0, chrome.1, prTitle, "https://github.com", "13:49", 11)
        note("Weekly summaries export pull request", pr1, [("Had pull request 418 open on GitHub.", pr1, "observed")])
        note("Weekly summaries export pull request", pr2, [("Had pull request 418 open on GitHub.", pr2, "observed")])

        // 2:00 PM the update again, then emailing it.
        var doc2 = stretch(chrome.0, chrome.1, docTitle, docURL, "14:00", 12)
        let sam4 = stretch(messages.0, messages.1, "Sam", "", "14:12", 3)
        note("Sam in Messages", sam4, [("Had Messages open with Sam.", sam4, "observed")])
        doc2 += stretch(chrome.0, chrome.1, docTitle, docURL, "14:15", 10)
        note("Q3 investor update", doc2, [("Had the Q3 investor update open in Google Docs.", doc2, "observed")])
        let email = stretch(mail.0, mail.1, "Q3 investor update", "", "14:25", 13)
        let emailSend = typed(mail.0, mail.1, "Q3 investor update", "14:25", 720, surface: "email", to: "Investors",
                              words: "Hi all, here is our Q3 update. Revenue grew and the export beta ships next week.")
        note("Q3 investor update email", email + emailSend, [("Emailed Investors the Q3 investor update.", emailSend, "submitted"),
                                                             ("Had the Q3 investor update email open in Mail.", email, "observed")])
        return (rows, notes)
    }
}
