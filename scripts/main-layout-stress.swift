import AppKit
import SwiftUI
import MemoryUI
import MemoryCore

@main struct LayoutStress {
    @MainActor static func main() throws {
        _=NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let focus=CommandLine.arguments.contains("focus")
        DispatchQueue.global().asyncAfter(deadline:.now()+(focus ? 90:35)) {
            FileHandle.standardError.write(Data("FAIL: synthetic layout watchdog expired\n".utf8))
            exit(2)
        }
        func log(_ text:String) {FileHandle.standardOutput.write(Data((text+"\n").utf8))}
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=TimeZone(secondsFromGMT:0)!
        let base=ActivityUIFixtures.items()[0]
        let start=timestamp("2026-09-22T08:00:00Z")!
        let items=(0..<120).map {index -> MemoryItem in
            var item=base
            item.id="synthetic-\(index)";item.evidence.id=item.id
            item.evidence.at=iso(start.addingTimeInterval(-Double(index/24)*86400+Double(index%24)*600))
            item.evidence.app="Synthetic app";item.evidence.bundle=""
            item.evidence.title="Synthetic activity \(index)"
            item.evidence.text=String(repeating:"Variable length synthetic history. ",count:1+index%5)
            return item
        }
        let browser=ActivityBrowser(items:items,calendar:calendar)
        let actualShape=CommandLine.arguments.contains("actualshape")
        let noteCount=actualShape ? 4:CommandLine.arguments.contains("dense") ? 500:24
        if CommandLine.arguments.contains("canonical") {
            browser.loadCanonicalDay = { day,_ in
                let records=(0..<(actualShape ? 200:min(noteCount,200))).map {index -> [String:Any] in
                    ["id":"\(day)-\(index)","evidenceIDs":[],"at":day+"T08:00:00Z","kind":"window.observed",
                     "app":"Synthetic app","bundle":"","site":"","title":"Synthetic activity",
                     "description":"Synthetic observation","state":"observed","revision":"fixture",
                     "subject":"Synthetic subject","observationKey":"fixture-\(index)"]
                }
                let notes=(0..<noteCount).map {index -> [String:Any] in
                    let ids=actualShape && index==0 ? (0..<597).map {"\(day)-\($0)"}:["\(day)-\(index)"]
                    var note:[String:Any]=["id":"note-\(day)-\(index)","day":day,"timezone":"UTC","subject":String(repeating:"Synthetic note. ",count:1+index%5),
                     "actionIDs":ids,"apps":["Synthetic app"],"sites":[],"start":day+"T08:00:00Z",
                     "end":day+"T08:01:00Z","clusters":[],"inputRevision":"fixture","status":"pending"]
                    if actualShape && index==1 {
                        note["generated"]=["id":"generated-\(day)","version":1,"schemaVersion":1,"generatedAt":day+"T09:00:00Z","inputRevision":"fixture","actionIDs":ids,"status":"generated_unverified",
                                           "output":["requestID":"fixture","title":"Synthetic multiline note","bullets":(0..<10).map {bullet in ["text":String(repeating:"Synthetic bullet \(bullet). ",count:1+bullet%4),"actionIDs":ids,"assertion":"observed"]},"generator":"fixture","generatorVersion":"1"]]
                    }
                    return note
                }
                let today=try DayScope.key(Date(),timezone:"UTC")
                let value:[String:Any]=[
                    "summary":["day":day,"timezone":"UTC","start":day+"T00:00:00Z","end":day+"T23:59:59Z",
                               "activityIDs":notes.map {$0["id"] as! String},"actionCount":noteCount,"countIsComplete":true,"inputRevision":"fixture","status":"pending"],
                    "activities":notes,"actions":["actions":records,"revision":"fixture","snapshot":["epoch":"fixture","highWater":noteCount],"candidates":noteCount],
                    "defaultLayer":actualShape && day != today ? "day_summary":"activity_notes","partial":false]
                return try JSONDecoder().decode(ActionDay.self,from:JSONSerialization.data(withJSONObject:value))
            }
        }
        // `focus` (A1b): the Focus List on a realistic canonical fixture at a fixed clock, with the probe
        // reporting its row frames, expanded sources and detail actions.
        let probe=FocusListProbe()
        if focus {
            precondition(CommandLine.arguments.contains("canonical"),"focus needs canonical")
            browser.now={FocusFixture.now}
            browser.loadCanonicalDay={day,_ in try FocusFixture.day(day)}
        }
        let shell=MemoryShell(browser:browser,state:CapturePresentation(title:"Synthetic preview"),actions:CaptureActions(),demo:true)
            .environment(\.daydreamFocusListProbe,focus ? probe:nil)
        let view:AnyView
        if CommandLine.arguments.contains("bounded") {
            view=AnyView(GeometryReader {geometry in
                VStack(spacing:0) {shell}
                    .frame(width:geometry.size.width.isFinite ? max(560,geometry.size.width):560,
                           height:geometry.size.height.isFinite ? max(340,geometry.size.height):340)
            }.frame(minWidth:560,maxWidth:.infinity,minHeight:340,maxHeight:.infinity))
        } else {view=AnyView(shell.frame(minWidth:560,minHeight:340))}
        let host=NSHostingView(rootView:view)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:887,height:490),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        defer {window.orderOut(nil)}
        window.contentView=host
        window.makeKeyAndOrderFront(nil)
        log("BEGIN default NSHostingView sizingOptions=\(host.sizingOptions.rawValue)")
        func tick() {RunLoop.main.run(until:Date().addingTimeInterval(0.025));host.layoutSubtreeIfNeeded()}
        tick()
        func scrolls(_ view:NSView)->[NSScrollView] {
            (view as? NSScrollView).map {[$0]} ?? view.subviews.flatMap(scrolls)
        }
        var maximum=0.0
        var retainedOffsets=0
        let iterations=CommandLine.arguments.contains("dense") ? 2:12
        for step in 0..<iterations {
            let begin=Date()
            let viewport=NSSize(width:[887,560,900][step%3],height:[490,600][step%2])
            window.setContentSize(viewport)
            tick()
            if host.bounds.size != viewport {log("Viewport debug: mask \(host.autoresizingMask.rawValue), min \(window.minSize), max \(window.maxSize), intrinsic \(host.intrinsicContentSize), fitting \(host.fittingSize), screen \(String(describing:window.screen?.visibleFrame)), window frame \(window.frame)")}
            precondition(host.bounds.size==viewport,"Native host changed the requested viewport: requested \(viewport), actual \(host.bounds.size), window \(window.contentLayoutRect.size)")
            if CommandLine.arguments.contains("check-indicators") {
                for scroll in scrolls(host) {
                    precondition(!scroll.hasVerticalScroller || scroll.verticalScroller?.isHidden != false,"Visible vertical indicator")
                    precondition(!scroll.hasHorizontalScroller || scroll.horizontalScroller?.isHidden != false,"Visible horizontal indicator")
                }
            }
            let scroll=scrolls(host).max(by:{($0.documentView?.frame.height ?? 0)<($1.documentView?.frame.height ?? 0)})
            if let scroll {
                let extent=max(0,(scroll.documentView?.frame.height ?? 0)-scroll.contentView.bounds.height)
                scroll.contentView.scroll(to:NSPoint(x:0,y:extent*Double(step%4)/3))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            let offset=scroll?.contentView.bounds.origin.y
            if step%4==0 {browser.items=items}
            if step%6==0 {browser.query=""}
            tick()
            if let scroll,let offset {
                precondition(abs(scroll.contentView.bounds.origin.y-offset)<1,"Refresh moved the selected scroll position")
                retainedOffsets += 1
            }
            let elapsed=Date().timeIntervalSince(begin)
            maximum=max(maximum,elapsed)
            log(String(format:"STEP %d %.3fs",step,elapsed))
        }
        if !CommandLine.arguments.contains("canonical") {
            let scroll=scrolls(host).max(by:{($0.documentView?.frame.height ?? 0)<($1.documentView?.frame.height ?? 0)})!
            let expandedHeight=scroll.documentView!.frame.height
            browser.collapsedDays=Set(browser.days.map(\.date));tick()
            precondition(scroll.documentView!.frame.height<expandedHeight,"Day collapse did not shrink history")
            browser.collapsedDays=[];tick()
            precondition(abs(scroll.documentView!.frame.height-expandedHeight)<1,"Expanding days changed original content height")
            scroll.contentView.scroll(to:NSPoint(x:0,y:200));scroll.reflectScrolledClipView(scroll.contentView);tick()
            let offset=scroll.contentView.bounds.origin.y
            let activity=browser.days[0].activities[0]
            browser.select(activity.apps[0],in:activity);tick();browser.back();tick()
            precondition(abs(scroll.contentView.bounds.origin.y-offset)<1,"Activity detail return moved history")
            log("PASS: day collapse/expand and detail return preserve history geometry/scroll")
        }
        if focus {FocusChecks.run(host:host,window:window,browser:browser,probe:probe,items:items,log:log)}
        log("PASS: \(retainedOffsets) scroll offsets retained; every native viewport stayed fixed")
        log(String(format:"PASS:%d synthetic resize/scroll/refresh iterations; slowest %.3fs",iterations,maximum))
    }
}


/// The `focus` fixture: 24 moments a day, 7:00 AM to 4:47 PM UTC, 1-4 actions each, every third one
/// summarized. Two moments are built from evidence through `ActionProjection`, as the store builds
/// actions: #15 touches five different windows and pages; #16 is the legacy fixture's five visits of
/// one page (`ActivityUIFixtures.fiveActions`, today with its exact evidence ids). `grown` adds one
/// Notes window to that moment a minute after it starts (a refresh that grows an expanded card).
enum FocusFixture {
    static let now=timestamp("2026-09-22T20:00:00Z")!
    static let today="2026-09-22"
    static let count=24
    nonisolated(unsafe) static var grown:Int?=nil
    static func noteID(_ day:String,_ index:Int)->String {"note-\(day)-\(index)"}

    static func distinct(_ day:String)->[Evidence] {[
        Evidence(id:"\(day)-source-0",at:day+"T13:15:00Z",kind:"window.changed",app:"Safari",bundle:"com.apple.Safari",title:"Sensor research",url:"https://example.org/sensors",synthetic:true),
        Evidence(id:"\(day)-source-1",at:day+"T13:16:00Z",kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Bench notes",synthetic:true),
        Evidence(id:"\(day)-source-2",at:day+"T13:17:00Z",kind:"window.changed",app:"Safari",bundle:"com.apple.Safari",title:"Calibration guide",url:"https://docs.example.com/calibration",synthetic:true),
        Evidence(id:"\(day)-source-3",at:day+"T13:18:00Z",kind:"window.changed",app:"Notes",bundle:"com.apple.Notes",title:"Sensor checklist",synthetic:true),
        Evidence(id:"\(day)-source-4",at:day+"T13:19:00Z",kind:"window.changed",app:"Google Chrome",bundle:"com.google.Chrome",title:"sensors repository",url:"https://github.com/example/sensors",synthetic:true),
    ]}
    static func visits(_ day:String)->[Evidence] {
        ActivityUIFixtures.fiveActions().enumerated().map {i,item in
            var e=item.evidence
            e.at=day+"T13:4\(i):00Z"
            if day != today {e.id=day+"-"+e.id}
            return e
        }
    }

    static func day(_ day:String) throws -> ActionDay {
        func object(_ a:CanonicalAction) throws -> [String:Any] {try JSONSerialization.jsonObject(with:JSONEncoder().encode(a)) as! [String:Any]}
        let base=timestamp(day+"T07:00:00Z")!
        var actions:[[String:Any]]=[]
        var notes:[[String:Any]]=[]
        for index in 0..<count {
            let id=noteID(day,index)
            let start=base.addingTimeInterval(Double(index)*1500)
            var ids:[String]=[], apps=["TextEdit"], bundles=["com.apple.TextEdit"], sites:[String]=[]
            var first=start, last=start.addingTimeInterval(720)
            var counts=["com.apple.TextEdit":0]
            if index==15 || index==16 {
                let projected=(index==15 ? distinct(day):visits(day)).map(ActionProjection.make)
                actions += try projected.map(object)
                ids=projected.map(\.id)
                apps=Array(Set(projected.map(\.app))).sorted()
                bundles=Array(Set(projected.map(\.bundle))).sorted()
                sites=Array(Set(projected.map(\.site).filter {!$0.isEmpty})).sorted()
                counts=Dictionary(projected.map {($0.bundle,1)},uniquingKeysWith:+)
                first=timestamp(projected.first!.at)!; last=timestamp(projected.last!.at)!
            } else {
                for j in 0..<(1+index%4) {
                    let actionID="\(id)-a\(j)"
                    ids.append(actionID)
                    actions.append(["id":actionID,"evidenceIDs":[actionID+"-e"],"at":iso(start.addingTimeInterval(Double(j)*180)),
                                    "kind":"window.changed","app":"TextEdit","bundle":"com.apple.TextEdit","site":"",
                                    "title":"Synthetic document \(index)","description":"Observed Synthetic document \(index) in TextEdit",
                                    "state":"observed","revision":"fixture","subject":"Synthetic document \(index)","observationKey":actionID])
                }
                counts["com.apple.TextEdit"]=ids.count
                last=start.addingTimeInterval(Double(ids.count-1)*180)
                if grown==index {
                    let actionID="\(id)-grown"
                    ids.append(actionID)
                    actions.append(["id":actionID,"evidenceIDs":[actionID+"-e"],"at":iso(start.addingTimeInterval(60)),
                                    "kind":"window.changed","app":"Notes","bundle":"com.apple.Notes","site":"",
                                    "title":"Grown notes \(index)","description":"Observed Grown notes \(index) in Notes",
                                    "state":"observed","revision":"fixture","subject":"Grown notes \(index)","observationKey":actionID])
                    apps=["Notes","TextEdit"]; bundles=["com.apple.Notes","com.apple.TextEdit"]; counts["com.apple.Notes"]=1
                }
            }
            var note:[String:Any]=["id":id,"day":day,"timezone":"UTC","subject":index==15 ? "Sensor research":"Synthetic document \(index)",
                                   "actionIDs":ids,"apps":apps,"sites":sites,"start":iso(first),"end":iso(last),
                                   "clusters":[["actionIDs":ids,"firstObservedAt":iso(first),"lastObservedAt":iso(last)]],
                                   "inputRevision":"fixture","status":"pending","bundles":bundles,"bundleActionCounts":counts]
            if index%3==0 {
                note["status"]="ready"
                note["generated"]=["id":"generated-\(id)","version":1,"schemaVersion":1,"generatedAt":iso(last.addingTimeInterval(120)),
                                   "inputRevision":"fixture","actionIDs":ids,"status":"generated_unverified",
                                   "output":["requestID":"fixture-\(id)","title":"Synthetic moment \(index)",
                                             "bullets":(0..<(1+index%5)).map {["text":"Synthetic bullet \($0) of moment \(index).","actionIDs":[ids[0]],"assertion":"observed"]},
                                             "generator":"local/qwen3.5-4b-q4_k_m","generatorVersion":"1"]]
            }
            notes.append(note)
        }
        actions.sort {($0["at"] as! String,$0["id"] as! String)<($1["at"] as! String,$1["id"] as! String)}
        let value:[String:Any]=[
            "summary":["day":day,"timezone":"UTC","start":day+"T00:00:00Z","end":day+"T23:59:59Z","activityIDs":notes.map {$0["id"] as! String},
                       "actionCount":actions.count,"countIsComplete":true,"inputRevision":"fixture","status":"pending"],
            "activities":notes,"actions":["actions":actions,"revision":"fixture","snapshot":["epoch":"fixture","highWater":actions.count],"candidates":actions.count],
            "defaultLayer":"activity_notes","partial":false]
        return try JSONDecoder().decode(ActionDay.self,from:JSONSerialization.data(withJSONObject:value))
    }
}

/// `canonical focus bounded check-indicators` (plan §5 A1 checks, amendments A1b), on the Focus List
/// in the whole shell at 887×490: (a) expand/collapse restores the document height and only one row
/// is expanded at a time; (b) an expanded card above the visible area that grows (a refresh adds a
/// window to it) or collapses (Esc) keeps the rows on screen fixed (the expansion anchor); (c) ⌘[ then
/// ⌘] restores the offset and the selection; (d) the detail round trip restores the offset; (e) a
/// refresh keeps the offset and the expanded row; five windows and pages list in order with their
/// exact evidence, in the expanded row and in its detail, whose scroll reaches its last action row; a
/// row another surface expands (same day, or with the day) is scrolled into view; a failed action's
/// notice shows in view (in the expanded card, or above the list); scrolling reaches the last row; the
/// tallest scroll view is the list (`canonical-history`).
@MainActor enum FocusChecks {
    static func run(host:NSView,window:NSWindow,browser:ActivityBrowser,probe:FocusListProbe,items:[MemoryItem],log:(String)->Void) {
        func tick() {RunLoop.main.run(until:Date().addingTimeInterval(0.025));host.layoutSubtreeIfNeeded()}
        func wait(_ what:String,_ timeout:Double=5,_ done:()->Bool) {
            let end=Date().addingTimeInterval(timeout)
            while !done() {precondition(Date()<end,"Timed out waiting for \(what)");tick()}
        }
        func scrolls(_ view:NSView)->[NSScrollView] {(view as? NSScrollView).map {[$0]} ?? view.subviews.flatMap(scrolls)}
        func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(views)}
        let today=FocusFixture.today, yesterday="2026-09-21"
        func id(_ index:Int)->String {FocusFixture.noteID(today,index)}

        window.setContentSize(NSSize(width:887,height:490));tick()
        wait("today's rows") {(0..<FocusFixture.count).allSatisfy {probe.rowFrames[id($0)] != nil}}
        guard let list=scrolls(host).max(by:{($0.documentView?.frame.height ?? 0)<($1.documentView?.frame.height ?? 0)}),let document=list.documentView
        else {preconditionFailure("No scroll view")}
        // The list's scroll view carries the Focus List's scroll probe; no other scroll view does.
        let probeView={(v:NSScrollView) in views(v).contains {String(describing:type(of:$0)).contains("FocusScrollProbeView")}}
        precondition(probeView(list),"The tallest scroll view is not canonical-history")
        precondition(scrolls(host).filter(probeView).count==1,"More than one Focus List scroll view")
        log("PASS: the tallest scroll view is canonical-history (\(Int(document.frame.height)) pt)")
        let clip=list.contentView
        func height()->CGFloat {document.frame.height}
        func offset()->CGFloat {clip.bounds.origin.y}
        func extent()->CGFloat {max(0,height()-clip.bounds.height)}
        /// Waits until the document height and offset hold still for 6 ticks.
        func settle() {
            var still=0, last=(height(),offset())
            wait("the layout to settle") {
                let now=(height(),offset())
                still=abs(now.0-last.0)<0.01 && abs(now.1-last.1)<0.01 ? still+1:0
                last=now
                return still>=6
            }
        }
        func scroll(_ y:CGFloat) {clip.scroll(to:NSPoint(x:0,y:min(max(0,y),extent())));list.reflectScrolledClipView(clip);settle()}
        func frame(_ row:String)->CGRect {probe.rowFrames[row] ?? .null}
        func onScreen()->[String:CGFloat] {
            let top=offset(), bottom=top+clip.bounds.height
            return probe.rowFrames.filter {$0.value.maxY>top+0.5 && $0.value.minY<bottom-0.5}.mapValues {$0.minY-top}
        }
        func expand(_ row:String?) {
            browser.selectedMomentID=row ?? browser.selectedMomentID
            browser.expandedMomentID=row
            if let row {wait("\(row)'s sources") {probe.sources[row] != nil}}
            settle()
        }
        func samePlaces(_ before:[String:CGFloat],_ what:String) {
            for (row,y) in before {
                let now=frame(row).minY-offset()
                precondition(abs(now-y)<1,"\(what): \(row) moved from \(y) to \(now)")
            }
        }
        settle()
        let order=probe.rowFrames.filter {$0.key.hasPrefix("note-\(today)-")}.sorted {$0.value.minY<$1.value.minY}.map(\.key)
        precondition(order.count==FocusFixture.count,"Expected \(FocusFixture.count) rows, found \(order.count)")
        precondition(extent()>400,"The list is too short to scroll: \(height()) pt")

        // (a) Expand and collapse restore the document height; one row is expanded at a time.
        scroll(0)
        let base=height()
        expand(order[1])
        precondition(height()>base+40 && frame(order[1]).height>100,"Expanding a row did not open its card")
        expand(order[3])
        precondition(abs(frame(order[1]).height-52)<1,"Expanding B left A expanded (\(frame(order[1]).height) pt)")
        let both=height()
        expand(nil)
        precondition(abs(height()-base)<1,"Collapsing did not restore the document height: \(base) → \(height())")
        expand(order[3])
        precondition(abs(height()-both)<1,"Expanding B after A added more than B's own card: \(both) vs \(height())")
        // The row's frame and the document height are each rounded to whole pixels, so they agree within 1 pt.
        precondition(abs(frame(order[3]).height-52-(height()-base))<=1,"The height change is not B's card alone: row \(frame(order[3])), document \(base) → \(height())")
        expand(nil)
        precondition(abs(height()-base)<1,"Collapsing B did not restore the document height")
        log(String(format:"PASS: (a) expand/collapse restores the document height; one row expanded at a time (B adds %.0f pt)",both-base))

        // (b) An expanded card above the visible area that grows or collapses keeps the rows on screen where
        // they are. (An expansion asked for by another surface is scrolled into view instead: see below.)
        let topRow=order[0]
        guard let topIndex=Int(topRow.split(separator:"-").last ?? "") else {preconditionFailure("Unexpected row id \(topRow)")}
        scroll(0)
        expand(topRow)
        let cardBefore=frame(topRow).height
        precondition(cardBefore>100 && (probe.sources[topRow] ?? []).count==1,"The first row did not open with its one window")
        scroll(frame(topRow).maxY+160)
        precondition(offset()>frame(topRow).maxY+1,"Could not scroll the first row's card out of view")
        let before=onScreen(), startOffset=offset(), startHeight=height()
        precondition(before.count>=4,"Too few rows on screen: \(before.count)")
        FocusFixture.grown=topIndex
        browser.send(.refresh)
        wait("the grown card's second window") {(probe.sources[topRow] ?? []).count==2};settle()
        precondition(height()>startHeight+30 && frame(topRow).height>cardBefore+30,"The card above did not grow: \(startHeight) → \(height())")
        samePlaces(before,"(b) a card above the visible area growing")
        precondition(abs((offset()-startOffset)-(height()-startHeight))<1,"(b) the offset did not follow the card growing above")
        expand(nil)
        samePlaces(before,"(b) collapsing a card above the visible area")
        precondition(abs((offset()-startOffset)-(height()-startHeight))<1,"(b) the offset did not follow the card collapsing above")
        FocusFixture.grown=nil
        browser.send(.refresh);RunLoop.main.run(until:Date().addingTimeInterval(0.2));settle()
        precondition(abs(frame(topRow).height-52)<1,"The first row did not close")
        log(String(format:"PASS: (b) a card above the visible area growing and collapsing keeps %d on-screen rows fixed within 1 pt",before.count))

        // (c) ⌘[ then ⌘] restores Today's offset and selection.
        scroll(300)
        let selected=onScreen().sorted {$0.value<$1.value}[1].key
        expand(selected)
        let dayOffset=offset()
        browser.send(.previousDay)
        wait("yesterday's rows") {probe.rowFrames[FocusFixture.noteID(yesterday,0)] != nil};settle()
        precondition(browser.focusedDay==yesterday,"⌘[ did not show yesterday")
        browser.send(.nextDay)
        wait("today's rows again") {probe.rowFrames[id(0)] != nil};settle()
        precondition(abs(offset()-dayOffset)<1,"(c) the day round trip moved Today from \(dayOffset) to \(offset())")
        precondition(browser.selectedMomentID==selected && browser.expandedMomentID==selected,"(c) the day round trip lost the selection")
        log("PASS: (c) previousDay/nextDay restores the offset within 1 pt and keeps the selection")

        // (e) A refresh keeps the offset and the expanded row.
        let refreshOffset=offset(), refreshPlaces=onScreen()
        browser.items=items;browser.query="";browser.send(.refresh)
        RunLoop.main.run(until:Date().addingTimeInterval(0.2));settle()
        precondition(abs(offset()-refreshOffset)<1,"(e) the refresh moved the list")
        samePlaces(refreshPlaces,"(e) refresh")
        precondition(browser.expandedMomentID==selected,"(e) the refresh collapsed the row")
        log("PASS: (e) refresh keeps the offset and the expanded row")
        expand(nil)

        // (d) The detail round trip restores the offset.
        let shown=onScreen().sorted {$0.value<$1.value}[1].key
        let detailOffset=offset()
        browser.selectedCanonicalActivity=shown
        wait("the detail") {probe.detailMomentID==shown && !probe.detailActions.isEmpty};settle()
        browser.selectedCanonicalActivity=nil;settle()
        precondition(abs(offset()-detailOffset)<1,"(d) the detail return moved the list from \(detailOffset) to \(offset())")
        precondition(browser.expandedMomentID==shown,"(d) the detail's row is not the expanded one")
        log("PASS: (d) selectedCanonicalActivity → detail → nil restores the offset within 1 pt")
        expand(nil)

        // Five windows and pages: listed in the order first seen, each opening its own action with its exact evidence.
        let fiveID=id(15), five=FocusFixture.distinct(today)
        expand(fiveID)
        let sources=probe.sources[fiveID] ?? []
        precondition(sources.count==5,"Five windows and pages expected, got \(sources.count)")
        precondition(sources.map(\.openActionID)==five.map(\.id),"Sources are not chronological: \(sources.map(\.openActionID))")
        precondition(sources.map(\.evidenceIDs)==five.map {[$0.id]},"Sources lost their exact evidence")
        precondition(sources.map(\.first)==five.map {timestamp($0.at)!},"Sources lost their times")
        precondition(sources.map(\.title)==five.map(\.title),"Source titles differ: \(sources.map(\.title))")
        precondition(sources.map(\.site)==five.map {URL(string:$0.url)?.host ?? ""},"Source sites differ: \(sources.map(\.site))")
        browser.selectedCanonicalActivity=fiveID
        wait("the five-source detail") {probe.detailMomentID==fiveID && probe.detailActions.count==5};settle()
        let actions=probe.detailActions
        precondition(probe.detailComplete,"The detail says actions are missing")
        precondition(actions.map(\.id)==five.map(\.id),"Detail actions are not chronological")
        precondition(actions.map(\.evidenceIDs)==five.map {[$0.id]},"Detail actions lost their exact evidence")
        precondition(actions.map(\.at)==five.map(\.at) && actions.map(\.title)==five.map(\.title) && actions.map(\.bundle)==five.map(\.bundle),
                     "Detail actions differ from their evidence")
        precondition(actions==five.map(ActionProjection.make),"Detail actions are not the store's projection of their evidence")
        // The detail's last action row: at a shorter window the five rows overflow the card, and scrolling the
        // detail to its end shows the last one whole. `MomentDetailBody` ends its main column with its last row
        // (30 pt, then a hairline), `Load More Actions` (30 pt) when offered, and 20 pt of padding.
        window.setContentSize(NSSize(width:887,height:400));tick();RunLoop.main.run(until:Date().addingTimeInterval(0.2));tick()
        guard let detailScroll=scrolls(host).first(where:{$0 !== list && !probeView($0) && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor})
        else {preconditionFailure("No detail scroll view")}
        let detailClip=detailScroll.contentView
        let body=probe.detailBodySize.height
        precondition(abs(body-(detailScroll.documentView?.frame.height ?? 0))<1,"The detail body is not the detail's whole scroll content: \(body)")
        let lastBottom=body-20-(probe.detailCanLoadMore ? 30:0), lastTop=lastBottom-30.5
        precondition(lastBottom>detailClip.bounds.maxY+1,"The detail does not overflow, so its scroll proves nothing: last row ends at \(lastBottom), clip \(detailClip.bounds)")
        let end=max(0,(detailScroll.documentView?.frame.height ?? 0)-detailClip.bounds.height)
        detailClip.scroll(to:NSPoint(x:0,y:end));detailScroll.reflectScrolledClipView(detailClip);tick()
        precondition(abs(detailClip.bounds.minY-end)<2,"The detail scroll does not reach its end")
        precondition(lastTop>=detailClip.bounds.minY-0.5 && lastBottom<=detailClip.bounds.maxY+0.5,
                     "The detail's last action row (\(lastTop)…\(lastBottom)) is not visible at the end (\(detailClip.bounds.minY)…\(detailClip.bounds.maxY))")
        window.setContentSize(NSSize(width:887,height:490));tick()
        browser.selectedCanonicalActivity=nil;settle()
        expand(nil)
        log("PASS: five windows and pages list chronologically with their exact evidence, in the expanded row and its detail; scrolling the detail shows its last action row")

        // The legacy five visits of one page: one source (five actions) opening the latest visit; the
        // detail keeps all five chronological mappings and their exact evidence.
        let visitsID=id(16), visits=FocusFixture.visits(today)
        expand(visitsID)
        let page=probe.sources[visitsID] ?? []
        precondition(page.count==1 && page[0].count==5 && page[0].openActionID==visits[4].id && page[0].evidenceIDs==[visits[4].id],
                     "Five visits of one page should be one source opening the latest: \(page)")
        browser.selectedCanonicalActivity=visitsID
        wait("the five-visit detail") {probe.detailMomentID==visitsID && probe.detailActions.count==5};settle()
        precondition(probe.detailActions.map(\.id)==visits.map(\.id) && probe.detailActions.map(\.evidenceIDs)==visits.map {[$0.id]},
                     "The five-visit detail lost its chronological evidence mappings")
        browser.selectedCanonicalActivity=nil;settle()
        expand(nil)
        log("PASS: five visits of one page are one source opening the latest; the detail retains five chronological evidence mappings")

        // A row another surface expands is scrolled into view: a moment expanded on the shown day,
        // and Recall's Show in <Weekday> with the day (both directions), over each day's remembered offset.
        func shows(_ row:String)->Bool {
            let f=frame(row), top=offset(), bottom=top+clip.bounds.height
            return f.minY>=top-0.5 && (f.maxY<=bottom+0.5 || abs(f.minY-top)<1)
        }
        guard let bottomRow=order.last else {preconditionFailure("No rows")}
        scroll(0)
        precondition(!shows(bottomRow),"The last row is on screen at the top of the list")
        expand(bottomRow)
        precondition(shows(bottomRow),"A row expanded by another surface is not scrolled into view: \(frame(bottomRow)) at \(offset())")
        expand(nil);scroll(0)
        let yesterdayBottom=FocusFixture.noteID(yesterday,0)
        browser.focusedDay=yesterday;browser.selectedMomentID=yesterdayBottom;browser.expandedMomentID=yesterdayBottom
        wait("yesterday's handed-over row") {probe.rowFrames[yesterdayBottom].map {$0.height>100} == true && probe.sources[yesterdayBottom] != nil};settle()
        precondition(browser.focusedDay==yesterday && browser.expandedMomentID==yesterdayBottom,"The day handoff lost its moment")
        precondition(shows(yesterdayBottom),"A moment handed over with its day is not scrolled into view: \(frame(yesterdayBottom)) at \(offset())")
        browser.focusedDay=nil;browser.expandedMomentID=bottomRow
        wait("today's handed-over row") {probe.rowFrames[bottomRow].map {$0.height>100} == true};settle()
        precondition(browser.focusedDay==nil && browser.expandedMomentID==bottomRow,"The handoff back to today lost its moment")
        precondition(shows(bottomRow),"A moment handed over back to today is not scrolled into view: \(frame(bottomRow)) at \(offset())")
        expand(nil)
        log("PASS: a row another surface expands (the same day, or with its day) is scrolled into view")

        // A failed action's notice shows where the person is: in the expanded card (its bar or a menu command)
        // by the card's bottom edge, else above the list, scrolled into view either way.
        browser.reopenCanonical={_ in throw MemError.missing}
        func noticeShows()->Bool {
            guard let n=probe.noticeFrame else {return false}
            return n.minY>=offset()-0.5 && n.maxY<=offset()+clip.bounds.height+0.5
        }
        expand(fiveID)
        scroll(frame(fiveID).minY-clip.bounds.height/2)
        precondition(frame(fiveID).maxY>offset()+clip.bounds.height,"The card's bar is already on screen")
        browser.send(.openOriginal)
        wait("the card's notice") {probe.noticeFrame != nil};settle()
        let card=frame(fiveID), inCard=probe.noticeFrame ?? .null
        precondition(card.contains(inCard),"The failed Open Original's notice is not in its card: \(inCard) vs \(card)")
        precondition(noticeShows(),"The card's notice is not scrolled into view: \(inCard) at \(offset())")
        expand(nil)
        precondition(probe.noticeFrame==nil,"Closing the card kept its notice")
        precondition(browser.selectedMomentID==fiveID,"The selection moved")
        scroll(extent())
        browser.send(.openOriginal)
        wait("the list's notice") {probe.noticeFrame != nil};settle()
        precondition(noticeShows(),"The notice above the list is not scrolled into view: \(String(describing:probe.noticeFrame)) at \(offset())")
        browser.reopenCanonical=nil
        browser.send(.refresh);RunLoop.main.run(until:Date().addingTimeInterval(0.2));settle()
        precondition(probe.noticeFrame==nil,"A refresh kept the notice")
        log("PASS: a failed action's notice shows in its expanded card or above the list, scrolled into view")

        // Scrolling reaches the last row.
        scroll(extent())
        guard let lastRow=order.last else {preconditionFailure("No rows")}
        let last=frame(lastRow)
        precondition(last.minY>=offset()-0.5 && last.maxY<=offset()+clip.bounds.height+0.5,
                     "The last row is not fully visible at the end: \(last) in \(offset())…\(offset()+clip.bounds.height)")
        log("PASS: scrolling reaches the last row")
    }
}
