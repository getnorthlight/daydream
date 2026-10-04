import AppKit
import SwiftUI
import MemoryUI
import MemoryCore

@MainActor private final class AppDraftFixture:ObservableObject {
    @Published var excluded="fixture.missing"
    @Published var typing=false
    @Published var saves=0
}
/// The legacy exclusion list as a person edits it: the `Excluded apps` list opened and saving available. The
/// view starts collapsed and read-only (`expandedInitially`, `persistenceAvailable` default to false), which left
/// no app button to reach; the production Apps page (`SettingsAppsContent`) is checked in settings-hub-checks.
private struct AppDraftRender:View {
    @ObservedObject var draft:AppDraftFixture
    let fixtures:[LocalApp]
    var body:some View {
        SettingsFrame(selection:.constant("General")) { _ in
            AppExclusionSettings(typing:$draft.typing,excluded:$draft.excluded,dirty:true,status:"Unsaved changes. Recording stays off.",fixtures:fixtures,persistenceAvailable:true,expandedInitially:true,save:{draft.saves += 1},review:{})
        }
    }
}

@MainActor func wholeWindowChecks(output:URL) throws {
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
    DispatchQueue.global().asyncAfter(deadline:.now()+45) { exit(2) }
    let browser=ActivityBrowser(items:ActivityUIFixtures.items())
    let state=CapturePresentation(title:"Setup required",issue:"Review replacement")
    var host=NSHostingView(rootView:AnyView(MemoryShell(browser:browser,state:state,actions:CaptureActions())))
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:600),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
    window.title="DayDream · synthetic render"; window.contentView=host; window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    func tick() { RunLoop.main.run(until:Date().addingTimeInterval(0.12)); host.layoutSubtreeIfNeeded() }
    func check(_ ok:Bool,_ name:String) throws { guard ok else {throw MemError.invalid(name)}; print("PASS: "+name) }
    func scrolls(_ view:NSView)->[NSScrollView] { (view as? NSScrollView).map{[$0]} ?? view.subviews.flatMap(scrolls) }
    func snapshot(_ name:String,_ width:CGFloat,_ height:CGFloat,_ dark:Bool=false) throws {
        window.appearance=NSAppearance(named:dark ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width:width,height:height)); host.frame=NSRect(x:0,y:0,width:width,height:height); tick()
        try check(abs(host.bounds.width-width)<1 && abs(host.bounds.height-height)<1,"whole-window bounds "+name)
        if name.hasPrefix("window-") {
            print("DENSITY \(name) documentHeight=\(scrolls(host).first?.documentView?.frame.height ?? 0)")
        }
        guard let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw MemError.invalid("No bitmap")}
        host.cacheDisplay(in:host.bounds,to:rep)
        try rep.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))
        if name == "window-680x480-light" || name == "window-1280x800-dark" {
            try check(window.title == "DayDream · synthetic render","Daydream native window title")
            if let frame=window.contentView?.superview,let full=frame.bitmapImageRepForCachingDisplay(in:frame.bounds) {
                frame.cacheDisplay(in:frame.bounds,to:full)
                try full.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+"-frame.png"))
            }
        }
    }
    for dark in [false,true] {
        for size in [(680,480),(900,600),(1280,800),(1600,1000)] {
            try snapshot("window-\(size.0)x\(size.1)-\(dark ? "dark" : "light")",CGFloat(size.0),CGFloat(size.1),dark)
        }
    }
    try snapshot("short-top",680,480)
    guard let scroll=scrolls(host).first(where:{($0.documentView?.frame.height ?? 0)>$0.contentView.bounds.height+100}) else {throw MemError.invalid("Timeline has no usable scroll")}
    let bottom=max(0,scroll.documentView!.frame.height-scroll.contentView.bounds.height)
    scroll.contentView.scroll(to:NSPoint(x:0,y:bottom)); scroll.reflectScrolledClipView(scroll.contentView); tick()
    try check(abs(scroll.contentView.bounds.minY-bottom)<2,"short window reaches timeline bottom")
    try snapshot("short-bottom",680,480)
    let original=scroll.contentView.bounds.origin.y, day=browser.days[0], activity=browser.days[0].activities[0]
    browser.collapsedDays.insert(browser.days.last!.date)
    browser.select(activity.apps[0],in:activity); tick()
    try snapshot("detail-short",680,480)
    browser.showDay(); browser.back(); tick()
    try check(browser.collapsedDays.contains(browser.days.last!.date),"whole-window day collapse preserved")
    // Collapse may clamp the bottom; verify return after a stable offset too.
    browser.collapsedDays.removeAll(); tick()
    scroll.contentView.scroll(to:NSPoint(x:0,y:min(original,180))); scroll.reflectScrolledClipView(scroll.contentView); tick()
    let anchor=scroll.contentView.bounds.origin.y
    browser.select(activity.apps[0],in:activity); tick(); browser.back(); tick()
    try check(abs(scroll.contentView.bounds.origin.y-anchor)<2,"whole-window detail return preserves scroll")
    _ = day
    let fixtureHome=FileManager.default.temporaryDirectory.appendingPathComponent("macmem-canonical-ui-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:fixtureHome) }
    let fixtureStore=try MemoryStore(home:fixtureHome,writable:true)
    let fixtureNow=Date()
    for var item in ActivityUIFixtures.fiveActions() {
        item.evidence.at=iso(fixtureNow)
        _ = try fixtureStore.ingest(item.evidence,now:fixtureNow)
    }
    let canonicalBrowser=ActivityBrowser()
    canonicalBrowser.loadCanonicalDay={ day,cursor in
        try fixtureStore.dayLayers(day:day,timezone:canonicalBrowser.calendar.timeZone.identifier,after:cursor,limit:200,now:fixtureNow)
    }
    let canonicalDay=try fixtureStore.dayLayers(day:DayScope.key(fixtureNow,timezone:canonicalBrowser.calendar.timeZone.identifier),timezone:canonicalBrowser.calendar.timeZone.identifier,now:fixtureNow)
    try check(canonicalDay.actions.actions.count == 5,"canonical UI fixture retains five actions")
    host=NSHostingView(rootView:AnyView(MemoryShell(browser:canonicalBrowser,state:state,actions:CaptureActions())))
    window.contentView=host; tick()
    for dark in [false,true] { for size in [(680,480),(900,600),(1280,800)] {
        try snapshot("canonical-\(size.0)x\(size.1)-\(dark ? "dark" : "light")",CGFloat(size.0),CGFloat(size.1),dark)
    } }
    // A typed query presents the Recall overlay over the day (plan §6 "WholeWindow L95-103"; the old inline
    // CanonicalSearch is gone). Same sizes and bounds; dd-recall asserts result identity.
    canonicalBrowser.searchCanonical={text,cursor in try fixtureStore.searchResult(MemorySearchQuery(text,limit:2,after:cursor))}
    func settle(_ done:()->Bool) { let end=Date().addingTimeInterval(4); while !done() && Date() < end { tick() } }
    canonicalBrowser.query="sensor"
    RunLoop.main.run(until:Date().addingTimeInterval(0.4))
    settle { canonicalBrowser.recallModel.searchedText == "sensor" && !canonicalBrowser.recallModel.busy }
    try snapshot("global-search-narrow",680,480)
    try check(canonicalBrowser.recallVisible && canonicalBrowser.recallModel.panelSize.width > 0 && canonicalBrowser.recallModel.panelSize.width <= 680,"query presents the Recall overlay inside the window")
    try check(canonicalBrowser.recallModel.searchedText == "sensor" && !canonicalBrowser.recallModel.items.isEmpty,"Recall shows the query's stored results")
    try snapshot("global-search-wide-dark",1280,800,true)
    canonicalBrowser.query="unmatched-fixture"
    RunLoop.main.run(until:Date().addingTimeInterval(0.4))
    settle { canonicalBrowser.recallModel.searchedText == "unmatched-fixture" && !canonicalBrowser.recallModel.busy }
    try snapshot("global-search-empty",680,480)
    try check(canonicalBrowser.recallModel.searchedText == "unmatched-fixture" && canonicalBrowser.recallModel.items.isEmpty,"Recall shows no results for an unmatched query")
    canonicalBrowser.query=""
    let five=ActivityUIFixtures.fiveActions()
    let fiveBrowser=ActivityBrowser(items:five)
    let fiveGroup=fiveBrowser.days[0].activities[0]
    try check(fiveBrowser.days[0].activities.count == 1,"five actions grouped in one short timeline activity")
    try check(!ActivityWords.narrative(five).contains("experiment 5"),"timeline overview bounded independently of stored actions")
    fiveBrowser.select(fiveGroup.apps[0],in:fiveGroup)
    try check(fiveBrowser.scopedItems.map(\.id) == five.map(\.id),"detail retains five chronological source mappings")
    try check(fiveBrowser.scopedItems.map(\.evidence) == five.map(\.evidence),"detail retains exact original evidence")
    host=NSHostingView(rootView:AnyView(ActivityTimelineView(browser:fiveBrowser)))
    window.contentView=host
    try snapshot("five-action-detail",680,480)
    if let detailScroll=scrolls(host).last {
        let end=max(0,(detailScroll.documentView?.frame.height ?? 0)-detailScroll.contentView.bounds.height)
        detailScroll.contentView.scroll(to:NSPoint(x:0,y:end)); detailScroll.reflectScrolledClipView(detailScroll.contentView); tick()
        try check(abs(detailScroll.contentView.bounds.minY-end)<2,"five-action detail scroll reaches last row")
    } else { throw MemError.invalid("Missing detail scroll") }
    try snapshot("five-action-bottom",680,480)
    host=NSHostingView(rootView:AnyView(MemoryShell(browser:browser,state:state,actions:CaptureActions())))
    window.contentView=host
    browser.query="zz-no-synthetic-match"; try snapshot("search-empty",680,480); browser.query=""
    host=NSHostingView(rootView:AnyView(SettingsFrame(selection:.constant("Setup")) {_ in MacMemSetupView(pause:{},reviewLegacy:{LegacyFootprint(socketPresent:false,services:[])})})); window.contentView=host
    try snapshot("setup-short-light",680,480)
    try snapshot("setup-short-dark",680,480,true)
    if let setup=scrolls(host).first { setup.contentView.scroll(to:NSPoint(x:0,y:max(0,(setup.documentView?.frame.height ?? 0)-setup.contentView.bounds.height))); setup.reflectScrolledClipView(setup.contentView); tick() }
    try snapshot("setup-bottom",680,480)
    host=NSHostingView(rootView:AnyView(SettingsFrame(selection:.constant("Setup")) {_ in MacMemSetupView(pause:{},replacement:AnyView(Text("Synthetic replacement controls; no service actions")),reviewLegacy:{LegacyFootprint(socketPresent:true,services:[])})})); window.contentView=host
    try snapshot("setup-existing-recorder",680,600)
    // The Privacy page was folded into Settings › Advanced (ux/declutter): no privacy-short screens.
    let draft=AppDraftFixture()
    let rankApps=[LocalApp(id:"z",name:"Zulu"),LocalApp(id:"a",name:"Alpha"),LocalApp(id:"b",name:"Beta")]
    try check(LocalApp.ranked(rankApps,usage:[],running:[]).map(\.id)==["a","b","z"],"no usage/running apps gives alphabetical fallback")
    try check(LocalApp.ranked(rankApps,usage:[],running:["z"]).map(\.id)==["z","a","b"],"running apps lead when usage absent")
    let rankedEvidence=[Evidence(id:"r1",at:iso(Date(timeIntervalSince1970:100)),kind:"window.changed",app:"Beta",bundle:"b",synthetic:true),Evidence(id:"r2",at:iso(Date(timeIntervalSince1970:200)),kind:"window.changed",app:"Zulu",bundle:"z",synthetic:true)]
    let usage=rankedEvidence.map { IntentWriter.write($0) }
    try check(LocalApp.ranked(rankApps,usage:usage,running:["a"]).map(\.id)==["z","b","a"],"sparse equal-frequency usage prefers recent observation")
    try check(LocalApp.ranked(rankApps,usage:usage+[usage[0]],running:[]).map(\.id)==["b","z","a"],"frequent observed app leads")
    try check(LocalApp.ranked(rankApps,usage:usage,running:[])==LocalApp.ranked(rankApps.reversed(),usage:usage,running:[]),"ranking deterministic independent of catalog enumeration")
    let fixtures=[LocalApp(id:"com.apple.TextEdit",name:"TextEdit",path:"/System/Applications/TextEdit.app"),LocalApp(id:"com.apple.Notes",name:"Notes",path:"/System/Applications/Notes.app"),LocalApp(id:"fixture.editor.a",name:"Editor"),LocalApp(id:"fixture.editor.b",name:"Editor"),LocalApp(id:"com.apple.Passwords",name:"Passwords")]
    try check(LocalApp.includingMissing(fixtures,excluded:["fixture.missing"]).contains{$0.id == "fixture.missing"},"uninstalled exclusion retained by stable ID")
    host=NSHostingView(rootView:AnyView(AppDraftRender(draft:draft,fixtures:fixtures))); window.contentView=host
    for dark in [false,true] {
        for size in [(680,480),(900,600),(1280,800),(1600,1000)] {
            try snapshot("apps-\(size.0)x\(size.1)-\(dark ? "dark" : "light")",CGFloat(size.0),CGFloat(size.1),dark)
        }
    }
    func buttons(_ view:NSView)->[NSButton] { (view as? NSButton).map{[$0]} ?? view.subviews.flatMap(buttons) }
    func nodes(_ value:Any,_ depth:Int=0)->[any NSAccessibilityProtocol] {
        guard depth < 24, let node=value as? any NSAccessibilityProtocol else { return [] }
        return [node] + (node.accessibilityChildren() ?? []).flatMap { nodes($0,depth+1) }
    }
    let controls:[any NSAccessibilityProtocol]=buttons(host)+nodes(host)
    if let button=controls.first(where:{($0.accessibilityLabel() ?? "").contains("TextEdit,")}) {
        try check(button.accessibilityPerformPress(),"app exclusion accessible button activates")
        tick(); try check(draft.excluded.contains("com.apple.TextEdit") && draft.saves == 0,"icon changes draft only, no implicit save")
        try check((button.accessibilityValue() as? String) == "Selected","selected state updates native accessibility value")
        if let native=button as? NSButton {
            let position=native.convert(native.bounds,to:host)
            try check(window.makeFirstResponder(native),"exclusion control receives keyboard focus")
            let space=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:" ",charactersIgnoringModifiers:" ",isARepeat:false,keyCode:49)!
            native.keyDown(with:space); tick()
            try check(native.convert(native.bounds,to:host)==position,"selection does not reorder app rows")
            try check(!draft.excluded.contains("com.apple.TextEdit"),"Space toggles exclusion off without save")
            native.keyDown(with:space); tick()
        }
    } else { throw MemError.invalid("App exclusion accessible button unavailable") }
    try snapshot("apps-draft",680,480)
    if let appScroll=scrolls(host).first {
        let end=max(0,(appScroll.documentView?.frame.height ?? 0)-appScroll.contentView.bounds.height)
        appScroll.contentView.scroll(to:NSPoint(x:0,y:end)); appScroll.reflectScrolledClipView(appScroll.contentView); tick()
        try check(abs(appScroll.contentView.bounds.minY-end)<2,"short app setup reaches Save")
    }
    try snapshot("apps-bottom",680,480)
    // The Recording menu rows the app installs (`MenuBarRecordingMenu`, plan §6 "WholeWindow L178-214"; the old
    // CaptureMenuRows / "Pause capture" menu is retired). Operational issue text never reaches a menu row, so no
    // state's rows may widen the menu, however long the issue.
    let menuNow=Date()
    let issue="Summary writer needs attention. The local model stopped responding; recording continues without summaries."
    let menuStates:[(RecordingState,Bool,Bool)]=[
        (.recording(since:menuNow.addingTimeInterval(-3600)),true,true),
        (.paused(until:menuNow.addingTimeInterval(14*60),since:menuNow.addingTimeInterval(-60),reason:nil),true,true),
        (.paused(until:nil,since:nil,reason:RecordingCopy.pauseReason("Paused for sleep. Resume explicitly after waking.")),true,true),
        (.off(since:nil,reason:RecordingCopy.blocker("Review replacement")),false,false),
        (.needsPermission(missing:[.accessibility,.inputMonitoring]),false,false),
    ]
    func menuRows(_ state:RecordingState,_ canResume:Bool,_ canStop:Bool,_ actions:CaptureActions=CaptureActions())->MenuBarRecordingMenu {
        MenuBarRecordingMenu(presentation:CapturePresentation(state:state,issue:issue,canResume:canResume,canStop:canStop),actions:actions)
    }
    var menuWidth:CGFloat=0
    for (state,canResume,canStop) in menuStates {
        host=NSHostingView(rootView:AnyView(VStack(alignment:.leading,spacing:9) {menuRows(state,canResume,canStop)}.padding(12).fixedSize(horizontal:true,vertical:true).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)))
        window.contentView=host; tick()
        menuWidth=max(menuWidth,host.fittingSize.width)
    }
    try check(menuWidth > 0 && menuWidth < 320,"longest menu state content width under 320 points")
    let rows=menuRows(menuStates[1].0,true,true)
    host=NSHostingView(rootView:AnyView(VStack(alignment:.leading,spacing:9) {rows}.padding(12).fixedSize(horizontal:true,vertical:true).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)))
    window.contentView=host; tick()
    try snapshot("menu-content",320,300)
    if #available(macOS 14.4,*) {
        let presets=RecordingState.pausePresets.map(MenuBarRecordingMenu.presetTitle)
        let nativeMenu=NSHostingMenu(rootView:rows)
        nativeMenu.update()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
            for menuWindow in NSApp.windows where menuWindow !== window && menuWindow.isVisible {
                guard let view=menuWindow.contentView, let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else { continue }
                view.cacheDisplay(in:view.bounds,to:bitmap)
                if let data=bitmap.representation(using:.png,properties:[:]) { try? data.write(to:output.appendingPathComponent("native-menu.png")) }
            }
            nativeMenu.cancelTracking()
        }
        nativeMenu.popUp(positioning:nil,at:NSPoint(x:30,y:100),in:host)
        try check(nativeMenu.size.width < 320,"actual NSHostingMenu width under 320 points")
        print("NATIVE MENU WIDTH: \(nativeMenu.size.width)")
        print("NATIVE MENU ITEMS: " + nativeMenu.items.map { $0.isSeparatorItem ? "|" : $0.title }.joined(separator:", "))
        let pauseItem=nativeMenu.items.first { $0.title == "Pause for" }
        try check(pauseItem?.submenu?.items.map(\.title) == presets && presets == ["5 Minutes","15 Minutes","30 Minutes","2 Hours"],"durations only in native Pause submenu")
        try check(!nativeMenu.items.contains{presets.contains($0.title)},"no top-level pause durations")
        try check(nativeMenu.items.first{$0.title == "Resume Recording"}?.isEnabled == true,"paused native menu permits explicit resume")
        try check(pauseItem?.submenu?.items.allSatisfy{!$0.isEnabled} == true,"pause choices disabled when already paused")
        try check(!nativeMenu.items.contains{$0.title == "Pause for 15 Minutes"},"one Pause for submenu, no separate Pause for 15 Minutes row")
        var pauses:[Int]=[], others=0
        let runningMenu=NSHostingMenu(rootView:menuRows(.recording(since:nil),true,true,CaptureActions(pause:{pauses.append($0)},resume:{others += 1},stop:{others += 1},settings:{others += 1})))
        runningMenu.update()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { runningMenu.cancelTracking() }
        runningMenu.popUp(positioning:nil,at:NSPoint(x:30,y:100),in:host)
        try check(!runningMenu.items.contains{$0.title == "Resume Recording"},"recording menu hides Resume")
        try check(runningMenu.items.first{$0.title == "Start Recording"}?.isEnabled == false,"recording menu disables Start Recording")
        if let submenu=runningMenu.items.first(where:{$0.title == "Pause for"})?.submenu {
            for index in submenu.items.indices { submenu.performActionForItem(at:index) }
        }
        try check(pauses == [5,15,30,120] && others == 0,"native pause actions deliver exact durations to inert callback")
    }
    print("Whole-window renders use only in-memory fixtures and inert actions. No capture or permission calls.")
}
