import Foundation
@testable import MemoryCore
@testable import MemoryUI

/// Pure, fictional projections only. No app, view hosting, window, model or capture.
@main @MainActor enum TimelineFoldProjectionChecks {
    static func main() throws {
        var checks = 0
        func require(_ value: Bool, _ reason: String) {
            precondition(value, reason); checks += 1
        }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func action(_ id: String, _ minute: Double, title: String, bundle: String = "com.apple.TextEdit", site: String = "") -> CanonicalAction {
            CanonicalAction(id: id, evidenceIDs: [id], at: iso(start.addingTimeInterval(minute * 60)), kind: "window.changed",
                app: bundle == "com.google.Chrome" ? "Google Chrome" : "TextEdit", bundle: bundle,
                site: site, title: title, description: "Window observed", state: "observed",
                revision: "fictional", subject: title, observationKey: id)
        }
        let actions = [action("a", 0, title: "First notes"), action("b", 1, title: "Second notes"),
            action("c", 2, title: "Third notes"), action("d", 3, title: "Fourth notes"),
            action("e", 4, title: "Second notes"), action("f", 5, title: "Third notes"),
            action("g", 6, title: "Fourth notes")]
        let sources = FocusListExpanded.sources(from: actions.reversed())
        require(FocusListExpanded.sourceLimit == 3 && sources.count == 3, "Expanded Windows and pages has at most three sources")
        require(sources.map(\.openActionID) == ["e", "f", "g"], "Most-used sources preserve first-observed order and reopen the latest real action")
        require(sources.map(\.count) == [2, 2, 2], "Source cap preserves actual visit counts")
        let history = OwnerSourceMomentProjection.history(actions.reversed(), previews: [])
        require(history.map(\.id) == actions.map(\.id), "Source cap never removes the seven chronological What happened entries")
        require(OwnerSourceMomentProjection.sectionOrder == [.summary, .whatHappened], "Summary remains above What happened")
        let input = [MomentBullet(text: "Reviewed the parser.", actionIDs: ["a"]),
            MomentBullet(text: "Reviewed  the parser.\n", interpretation: true, actionIDs: ["b", "a"]),
            MomentBullet(text: "Compared the queue.", actionIDs: ["c"])]
        let output = DaydreamNotes.distinctBullets(input)
        require(output.map(\.text) == [input[0].text, input[2].text], "Identical generated bullets appear once, preserving display order")
        require(output[0].actionIDs == ["a", "b"] && output[0].interpretation, "Dedup preserves all source ownership and the interpretation warning")
        require(DaydreamNotes.distinctBullets(output) == output && input.count == 3, "Projection is idempotent and does not mutate saved input")
        let corrected = DaydreamNotes.distinctBullets([input[0], MomentBullet(text: input[0].text, correction: true), input[1]])
        require(corrected.count == 2 && corrected[1].correction && corrected[0].actionIDs == ["a", "b"], "User corrections retain separate authorship while generated repeats still combine")
        let generated = GeneratedNote(id: "fictional-note", version: 1, schemaVersion: 1,
            generatedAt: iso(start), inputRevision: "fictional", actionIDs: actions.map(\.id),
            output: NoteWriterOutput(requestID: "fictional-request", title: "Parser review", bullets: [
                NoteBullet(text: "Reviewed TextEdit app parser.", actionIDs: ["a"], assertion: "interpretation"),
                NoteBullet(text: "Reviewed TextEdit parser.", actionIDs: ["b"], assertion: "interpretation")],
                generator: "local/fixture", generatorVersion: "1"), status: "ready")
        let note = ActivityNote(id: "fictional-moment", day: "2027-01-15", timezone: "UTC", subject: "Parser notes",
            actionIDs: actions.map(\.id), apps: ["TextEdit"], sites: [], start: iso(start), end: iso(start.addingTimeInterval(360)),
            clusters: [], inputRevision: "fictional", status: "ready", generated: generated, bundles: ["com.apple.TextEdit"])
        let slice = MomentSlice.make(note: note, dayPartial: false,
            summaries: SummaryAvailability(provider: .local, busy: false), calendar: Calendar(identifier: .gregorian), pageActions: actions)
        require(slice.bullets.count == 1 && slice.bullets[0].actionIDs == ["a", "b"], "Actual moment projection dedups after app-name cleanup and retains both cited actions")
        require(OwnerSourceMomentProjection.history(actions, previews: []) == history, "Model summary arrival preserves complete chronological history")
        require(note.generated?.output.bullets.count == 2 && note.actionIDs.count == 7, "Saved note and complete action membership remain unchanged")
        func message(_ id: String, _ subject: String, day: String = "2001-01-01") -> MomentSlice {
            MomentSlice(id: id, dayKey: day, start: start, end: start.addingTimeInterval(60),
                title: subject, subject: subject, firstBullet: nil, bullets: [], apps: ["Messages"],
                primaryBundle: "com.apple.MobileSMS", bundles: ["com.apple.MobileSMS"], sites: [],
                actionIDs: [id + ":action"], actionCount: 1, clusters: [], summary: .pending, hasCorrection: false)
        }
        let a = message("contact-a1", "Texts with Avery Example"), a2 = message("contact-a2", "Texts with Avery Example")
        let b = message("contact-b", "Texts with Jordan Sample")
        let grouped = FocusListLayout.sessions([a, b, a2], sectionID: "bracket-one")
        require(grouped.count == 1 && grouped[0].members.count == 3 && grouped[0].label == "Messages",
            "Same app shares one bracket display container with three separate original conversation moments")
        require(grouped[0].conversation == nil && Set(grouped[0].members.compactMap(\.conversation)) == ["Avery Example", "Jordan Sample"],
            "App container claims no recipient and preserves each member's recorded conversation identity")
        require(Set(grouped.flatMap(\.members).flatMap { $0.detail.actionIDs }) == Set([a, b, a2].flatMap(\.actionIDs)),
            "Folded display retains every original action and moment identity")
        require(FocusListLayout.sessions([a], sectionID: "bracket-one")[0].id != FocusListLayout.sessions([a], sectionID: "bracket-two")[0].id,
            "Compiled grouping uses distinct identities in separate brackets")
        require(FocusListLayout.sessions([a, message("next-day", a.subject, day: "2001-01-02")], sectionID: "bracket-one").count == 2,
            "Compiled grouping never crosses dates")
        let groupChat = message("group-chat", "Texts with Avery Example, Jordan Sample")
        let chatMembers = FocusListLayout.sessions([a, groupChat], sectionID: "bracket-one").flatMap(\.members)
        require(chatMembers.count == 2 && Set(chatMembers.map(\.detail.subject)) == [a.subject, groupChat.subject],
            "App folding never merges a group conversation's detail into its first participant")
        func appMoment(_ id: String, _ title: String, _ index: Int, bundle: String, name: String,
                       day: String = "2001-01-01", extraBundle: String? = nil, sites: [String] = []) -> MomentSlice {
            let at = start.addingTimeInterval(Double(index) * 60)
            return MomentSlice(id: id, dayKey: day, start: at, end: at.addingTimeInterval(20),
                title: title, subject: title, firstBullet: nil, bullets: [], apps: [name],
                primaryBundle: bundle, bundles: [bundle] + (extraBundle.map { [$0] } ?? []), sites: sites,
                actionIDs: [id + ":action"], actionCount: 1, clusters: [], summary: .pending, hasCorrection: false, primaryApp: name)
        }
        let ghostty = ["* Tallybird app design review", "◐ Tallybird app design review", "Tallybird app design review", "~", "cd", "🔔 ~"].enumerated().map {
            appMoment("ghostty-\($0.offset)", $0.element, $0.offset, bundle: "com.mitchellh.ghostty", name: "Ghostty")
        }
        let terminal = (0..<2).map {appMoment("terminal-\($0)", "Terminal in fixture-user", 6 + $0, bundle: "com.apple.Terminal", name: "Terminal")}
        let notes = appMoment("notes", ghostty[0].title, 8, bundle: "com.apple.Notes", name: "Notes")
        let mixed = (0..<2).map {appMoment("mixed-\($0)", "Ambiguous source", 9 + $0, bundle: "com.mitchellh.ghostty", name: "Ghostty", extraBundle: "com.apple.Terminal")}
        let screenRows = ghostty + terminal + [notes] + mixed
        let screen = FocusListLayout.sessions(screenRows, sectionID: "screenshot-bracket")
        require(screen.count == 5, "Screenshot shape: Ghostty, Terminal, Notes and two ambiguous singletons")
        let ghosttyGroup = screen.first {$0.displayAppID == "com.mitchellh.ghostty"}!
        let terminalGroup = screen.first {$0.displayAppID == "com.apple.Terminal"}!
        require(ghosttyGroup.isGrouped && ghosttyGroup.members.count == 6 && ghosttyGroup.label == "Ghostty",
            "Spinner, shell cd and tilde title changes remain in one Ghostty display group")
        require(terminalGroup.isGrouped && terminalGroup.members.count == 2 && terminalGroup.label == "Terminal",
            "Duplicate Terminal rows fold without using the fictional user's window title as app identity")
        require(ghosttyGroup.members.map(\.detail) == ghostty.reversed().map {$0},
            "Ghostty children retain original titles/details in persisted-activity order")
        require(Set(screen.flatMap(\.members).map(\.id)) == Set(screenRows.map(\.id)) && screen.flatMap(\.members).count == screenRows.count,
            "All eleven screenshot-shaped moments survive exactly once")
        require(Set(screen.flatMap(\.members).flatMap { $0.detail.actionIDs }) == Set(screenRows.flatMap(\.actionIDs)),
            "All original screenshot-shaped actions survive app folding")
        require(screen.filter {$0.members.contains {$0.id.hasPrefix("mixed-")}}.allSatisfy {!$0.isGrouped && $0.members.count == 1},
            "Multi-bundle ambiguity never chooses the primary app as authority")
        require(FocusListLayout.sessions(ghostty, sectionID: "other-bracket")[0].id != ghosttyGroup.id,
            "Same app in another existing bracket gets a separate display identity")
        let nextDay = appMoment("ghostty-next-day", ghostty[0].title, 12, bundle: "com.mitchellh.ghostty", name: "Ghostty", day: "2001-01-02")
        require(FocusListLayout.sessions(ghostty + [nextDay], sectionID: "screenshot-bracket").count == 2,
            "A same-app member on another date never enters this bracket's group")
        let mixedBrowser = (0..<2).map {appMoment("mixed-browser-\($0)", "Fictional X draft", 13 + $0,
            bundle: "com.google.Chrome", name: "Google Chrome", extraBundle: "com.apple.Safari", sites: ["x.com"])}
        // Owner 10/2 (corrected): a website is its own "app" in any browser, so x.com in Chrome and Safari is one X card.
        let browserCards = FocusListLayout.sessions(mixedBrowser, sectionID: "screenshot-bracket")
        require(browserCards.count == 1 && browserCards[0].members.count == 2 && browserCards[0].displayAppID == "site:x.com",
            "x.com moments in Chrome and Safari are one X card")
        func member(_ m: MomentSlice) -> TimelineSessionMember<MomentSlice> {
            TimelineSessionMember(id: m.id, dayKey: m.dayKey, start: m.start, end: m.end, channel: nil, detail: m,
                displayAppID: FocusListLayout.displayAppID(m), displayAppName: FocusListLayout.appName(m))
        }
        let cache = TimelineSessionLayoutCache<MomentSlice>()
        let cached = cache.sessions(ghostty.map(member), sectionID: "screenshot-bracket")
        let renamed = appMoment(ghostty[0].id, "◓ Updated design review", 0, bundle: "com.mitchellh.ghostty", name: "Ghostty")
        let fresh = cache.sessions(([renamed] + Array(ghostty.dropFirst())).map(member), sectionID: "screenshot-bracket")
        require(cache.hits == 1 && fresh[0].id == cached[0].id && fresh[0].members.first {$0.id == renamed.id}?.detail == renamed,
            "Late spinner/title update reuses stable app plan while hydrating fresh original detail")
        let deleted = cache.sessions(ghostty.dropFirst().map(member), sectionID: "screenshot-bracket")
        require(deleted.flatMap(\.members).count == 5 && !deleted.flatMap(\.members).contains {$0.id == ghostty[0].id},
            "Removing an original moment immediately removes its cached group member")
        // Owner 10/2 (mockup): a folded Terminal row never leads with a raw window title or a withheld one.
        let junkTerminal = [appMoment("tj-0", "fixture-user \u{2014} -zsh \u{2014} 120\u{00D7}30", 20, bundle: "com.apple.Terminal", name: "Terminal"),
                            appMoment("tj-1", "[sensitive title omitted] code", 21, bundle: "com.apple.Terminal", name: "Terminal")]
        let junkFold = FocusListLayout.sessions(junkTerminal, sectionID: "screenshot-bracket")
        require(junkFold.count == 1 && junkFold[0].isGrouped, "Terminal rows with junk titles still fold by app")
        // Owner 10/2 (Main.dc.html): one card per app, titled by the app; no "+N moments".
        let junkMembers = FocusAppCard.members(junkFold[0])
        require(FocusAppCard.title(junkMembers) == "Terminal", "The app card is titled by the app, never a raw or withheld title")
        require(junkMembers.first?.id == "tj-1", "The card's anchor is its newest member")
        require(FocusListLayout.order([FocusListSection(part: .evening, moments: junkTerminal)]).map(\.id) == ["tj-1"],
            "Arrow keys walk cards: one stop per app card")
        require(Set(junkFold.flatMap(\.members).map(\.id)) == ["tj-0", "tj-1"], "Cleaning a title never drops a member")
        print("PASS \(checks) timeline fold projection checks; no GUI or capture")
    }
}
