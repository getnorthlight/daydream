import Foundation
import CoreGraphics

/// Entirely fictional activity. Compile with TimelineSessionGrouping.swift; no UI or history store.
@main enum LocalBlockGroupingChecks {
    struct Detail: Equatable { let title: String; let actions: [String] }
    typealias Member = TimelineSessionMember<Detail>
    static func main() {
        var checks = 0
        func require(_ condition: Bool, _ reason: String) { precondition(condition, reason); checks += 1 }
        func member(_ id: String, _ start: Double, _ end: Double, _ channel: TimelineSessionChannel?,
                    _ person: String? = nil, title: String = "Fictional activity", alias: Bool = true, day: String = "2001-01-01") -> Member {
            Member(id: id, dayKey: day, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end), channel: channel,
                   detail: Detail(title: title, actions: [id + ":source-action"]), conversation: person, allowsGenericAlias: alias)
        }
        func group(_ rows: [Member], _ block: String = "fictional-block") -> [TimelineSession<Detail>] {
            TimelineSessionGrouping.group(rows, withinSection: true, sectionID: block)
        }
        let named = member("read", 10, 15, .messages, "Avery Example")
        let generic = member("generic", 16, 17, .messages)
        let typed = member("draft", 18, 19, .messages, "Avery Example", title: "Fictional thank-you draft")
        let conversation = group([typed, generic, named])
        require(conversation.count == 1 && conversation[0].members.count == 3, "Same recorded conversation and unambiguous generic alias share one card")
        require(conversation[0].label == "Texts with Avery Example", "Card header names recorded identity")
        require(conversation[0].start == named.start && conversation[0].end == typed.end, "Full observed range retained")
        require(conversation[0].members.map(\.id) == ["draft", "generic", "read"], "Children latest observed first")
        require(conversation[0].members.map(\.detail).contains(typed.detail), "Typed draft detail retained verbatim, never merged")
        let other = member("other", 20, 21, .messages, "Jordan Sample")
        let ambiguous = group([named, generic, typed, other])
        require(ambiguous.count == 3, "Different contacts and ambiguous generic remain three cards")
        require(ambiguous.allSatisfy { !($0.members.contains { $0.id == "other" } && $0.members.contains { $0.id == "draft" }) }, "No false merge across contacts")
        require(ambiguous.first { $0.members.contains { $0.id == "generic" } }?.conversation == nil, "Ambiguous alias gains no invented recipient")
        let unknown = member("unreadable-name", 22, 23, .messages, nil, alias: false)
        require(group([named, unknown]).count == 2, "Unrecognized non-generic identity is not a generic alias")
        let caseAlias = member("case", 24, 25, .messages, "AVERY EXAMPLE")
        require(group([named, caseAlias]).count == 1, "Exact case-normalized recorded name shares identity")
        let groupChat = member("group-chat", 26, 27, .messages, "Avery Example, Jordan Sample")
        require(group([named, groupChat]).count == 2, "Group conversation does not collapse into first participant")
        let settingsA = member("settings-a", 100, 101, .systemSettings)
        let settingsB = member("settings-b", 900, 901, .systemSettings)
        require(group([settingsA, settingsB]).count == 1, "System Settings groups throughout existing block, beyond nearby gap")
        require(group([settingsA, settingsB])[0].label == "System Settings", "Settings header stays concrete")
        let xA = member("x-search", 30, 40, .x, title: "Fictional search for lanterns")
        let xB = member("x-post", 45, 50, .x, title: "Fictional post about cups")
        let x = group([xA, xB])
        require(x.count == 1 && x[0].members.count == 2, "Same X channel shares one presentation card")
        require(Set(x[0].members.map(\.detail.title)).count == 2, "Distinct searches/posts retain their own subjects")
        require(x[0].members.flatMap(\.detail.actions) == ["x-post:source-action", "x-search:source-action"], "All source actions retained")
        let oldLong = member("old-long", 1, 200, nil)
        let newShort = member("new-short", 150, 160, nil)
        require(group([newShort, oldLong]).first?.members.first?.id == "old-long", "Sort by latest persisted activity, not moment start")
        let mix = [xA, typed, settingsA, xB, generic, named]
        let result = group(mix)
        require(result.map(\.latestObserved) == result.map(\.latestObserved).sorted(by: >), "Groups latest descending")
        require(group(Array(mix.reversed())).map(\.id) == result.map(\.id), "Callback/input order does not shuffle groups")
        require(group(Array(mix.reversed())).map { $0.members.map(\.id) } == result.map { $0.members.map(\.id) }, "Callback/input order does not shuffle children")
        let changedTitle = member("draft", 18, 19, .messages, "Avery Example", title: "Late fictional summary title")
        require(group([named, generic, changedTitle]).map(\.id) == conversation.map(\.id), "Late summary/title arrival cannot change identity")
        require(group([named, generic, changedTitle]).map(\.latestObserved) == conversation.map(\.latestObserved), "Late summary/title arrival cannot affect latest sort")
        let laterDraft = member("draft", 18, 1000, .messages, "Avery Example")
        require(group([named, generic, laterDraft])[0].id == conversation[0].id, "Persisted activity extends range without replacing group identity")
        let olderAdded = member("older", 0, 1, .messages, "Avery Example")
        require(group([named, generic, typed, olderAdded])[0].id == conversation[0].id, "Late older child does not replace group ID")
        require(group([named])[0].id == conversation[0].id, "Eligible singleton and later grouped card share stable identity")
        require(group([named], "other-block")[0].id != group([named])[0].id, "Same conversation in separate existing blocks has separate frame identity")
        let tieA = member("a-tie", 0, 100, nil), tieB = member("b-tie", 0, 100, nil)
        require(group([tieA, tieB]).map(\.id) == group([tieB, tieA]).map(\.id), "Equal activity timestamps have deterministic tie-break")
        let nextDay = member("next-day", 10, 20, .messages, "Avery Example", day: "2001-01-02")
        require(group([named, nextDay]).count == 2, "No cross-day alias")
        let invalid = member("invalid", 100, 1, .systemSettings)
        require(group([invalid, settingsA]).count == 2, "Invalid range stays separate")
        require(group([]).isEmpty, "Empty section has no fabricated group")
        require(TimelineSessionChannel.recorded(sites: [], bundles: ["com.apple.systempreferences"]) == .systemSettings, "Settings needs recorded bundle")
        require(TimelineSessionChannel.recorded(sites: [], bundles: ["com.apple.systempreferences", "com.apple.MobileSMS"]) == nil, "Mixed apps stay separate")
        require(TimelineSessionChannel.recorded(sites: ["x.com", "instagram.com"], bundles: ["com.google.Chrome"]) == nil, "Different sites stay separate")
        let visible = CGRect(x: 0, y: 100, width: 500, height: 300)
        let frames: [String: CGRect] = ["header": CGRect(x: 0, y: 80, width: 500, height: 52),
                                       "expanded": CGRect(x: 0, y: 180, width: 500, height: 200),
                                       "offscreen": CGRect(x: 0, y: 700, width: 500, height: 52)]
        let anchor = TimelineVisibleAnchor.select(frames: frames, visible: visible, preferredIDs: ["expanded"])
        require(anchor?.id == "expanded" && anchor?.offset == 80, "Visible expanded child remains anchor over group header")
        require(TimelineVisibleAnchor.select(frames: frames, visible: visible, preferredIDs: ["offscreen"])?.id == "header", "Offscreen selection does not jump viewport")
        require(TimelineVisibleAnchor.select(frames: frames, visible: visible, preferredIDs: ["header", "expanded"])?.id == "header", "Visible preferred selection priority deterministic")
        let moved = CGRect(x: 0, y: 240, width: 500, height: 200)
        require(moved.minY - anchor!.offset == 160, "Existing anchor delta preserves child's visible offset after reordering")
        require(TimelineVisibleAnchor.select(frames: frames, visible: CGRect(x: 0, y: 0, width: 500, height: 300), preferredIDs: ["expanded"]) == nil, "Top of list keeps new latest activity visible")
        let singletonMember = member("a-singleton", 30, 40, .x)
        let singleton = group([singletonMember])[0]
        let singletonFrame = CGRect(x: 0, y: 120, width: 500, height: 52)
        let singletonFrames = [singletonMember.id: singletonFrame, singleton.id: singletonFrame]
        let transitionAnchor = TimelineVisibleAnchor.select(frames: singletonFrames, visible: visible, preferredIDs: [])
        require(transitionAnchor?.id == singleton.id, "Unselected singleton prefers stable presentation frame over original child frame")
        require(group([singletonMember, xB])[0].id == singleton.id, "Singleton's frame key survives second-member grouped transition")
        let collapsedGroupFrames = [group([singletonMember, xB])[0].id: CGRect(x: 0, y: 200, width: 500, height: 52)]
        require(collapsedGroupFrames[transitionAnchor!.id] != nil, "Collapsed new group retains old viewport anchor without forcing child open")
        require(collapsedGroupFrames[transitionAnchor!.id]!.minY - transitionAnchor!.offset == 180, "New grouped header preserves singleton's prior screen offset")
        require(TimelineVisibleAnchor.select(frames: singletonFrames, visible: visible, preferredIDs: [singletonMember.id])?.id == singletonMember.id, "Selected singleton still anchors original child; its group opens on selection")
        var visits = 0
        require(TimelineVisibleAnchor.select(frames: frames, visible: visible, preferredIDs: ["expanded"], examined: { visits = $0 })?.id == "expanded" && visits == 1, "Visible selection anchors with one lookup instead of full frame scan")
        require(TimelineVisibleAnchor.select(frames: frames, visible: visible, preferredIDs: [], previousID: "expanded", examined: { visits = $0 })?.id == "expanded" && visits == 1, "Small scroll retains visible anchor with one lookup")
        require(TimelineVisibleAnchor.select(frames: frames, visible: visible, preferredIDs: [], previousID: "offscreen")?.id == "header", "Retained anchor leaving viewport falls back to visible row")
        require(TimelineVisibleAnchor.select(frames: frames, visible: visible, preferredIDs: ["header"], previousID: "expanded")?.id == "header", "Visible requested selection overrides retained anchor")
        let cache = TimelineSessionLayoutCache<Detail>()
        let firstCached = cache.sessions([named, generic, typed], sectionID: "fictional-block")
        let freshCached = cache.sessions([named, generic, changedTitle], sectionID: "fictional-block")
        require(cache.builds == 1 && cache.hits == 1, "Title callback reuses grouping/order plan")
        require(freshCached[0].members.first?.detail.title == changedTitle.detail.title, "Cache hydrates fresh current detail instead of retaining old summary")
        require(firstCached[0].id == freshCached[0].id, "Cached title callback retains stable presentation ID")
        _ = cache.sessions([named, generic, laterDraft], sectionID: "fictional-block")
        require(cache.builds == 2, "Persisted observed timestamp changes invalidate plan")
        _ = cache.sessions([named, generic, laterDraft], sectionID: "other-block")
        require(cache.builds == 3, "Section change invalidates plan")
        let deleted = cache.sessions([named], sectionID: "other-block")
        require(cache.builds == 4 && deleted.flatMap(\.members).map(\.id) == [named.id], "Removed child drops cached membership immediately")
        print("PASS \(checks) fictional within-block grouping/ordering checks")
    }
}
