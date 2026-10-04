import AppKit
import SwiftUI
import MemoryUI
import MemoryCore

// Renders the actual native view without opening a database, capturing the
// desktop, installing the app, requesting permissions or starting a collector.
@MainActor func renderChecks() throws {
    guard CommandLine.arguments.count == 2 else { throw MemError.invalid("Pass an explicit render output directory") }
    let output = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    _ = NSApplication.shared
    DispatchQueue.global().asyncAfter(deadline:.now()+25) {
        FileHandle.standardError.write(Data("Native UI test timed out\n".utf8)); exit(2)
    }
    NSApp.setActivationPolicy(.accessory)
    var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(secondsFromGMT:0)!
    let browser = ActivityBrowser(items:ActivityUIFixtures.items(),calendar:calendar)
    let view = ActivityTimelineView(browser:browser)
    var host = NSHostingView(rootView:AnyView(view))
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:1400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    window.title = "DayDream · synthetic UI check"
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps:true)
    defer { window.orderOut(nil) }
    func tick() { RunLoop.main.run(until:Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded() }
    func snapshot(_ name: String, dark: Bool = false, width: CGFloat = 1100, height: CGFloat = 1400) throws {
        window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width:width,height:height)); host.frame = NSRect(x:0,y:0,width:width,height:height)
        tick()
        guard let rep = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw MemError.invalid("No native bitmap") }
        host.cacheDisplay(in:host.bounds,to:rep)
        guard let data = rep.representation(using:.png,properties:[:]) else { throw MemError.invalid("PNG render failed") }
        try data.write(to:output.appendingPathComponent(name+".png"))
        print("RENDER: " + name)
    }
    func check(_ condition: Bool, _ label: String) throws {
        if !condition { throw MemError.invalid("FAILED: "+label) }; print("PASS: "+label)
    }
    try check(browser.days.count == 2,"two day groups")
    try check(browser.days[0].activities.count == 3,"three activities on first day")
    let day = browser.days[0], activity = day.activities[0]
    let safari = activity.apps.first { $0.bundle == "com.apple.Safari" }!
    try snapshot("timeline-light")
    try snapshot("timeline-dark",dark:true)
    try snapshot("timeline-narrow",width:700,height:950)
    browser.collapsedDays.insert(browser.days[1].date)
    try snapshot("day-collapsed")
    browser.select(safari,in:activity)
    try check(browser.scopedItems.count == 1,"app scope excludes other apps and activities")
    try check(ActivityWords.narrative(browser.scopedItems).contains("moisture"),"app summary describes search purpose")
    try snapshot("app-activity",width:900,height:800)
    browser.showDay()
    try check(browser.scopedItems.count == 2,"app day includes both activities, no other app")
    try snapshot("app-day",width:900,height:800)
    browser.evidenceOpen = true
    try snapshot("app-evidence",width:900,height:1000)
    browser.back()
    try check(browser.collapsedDays.contains(browser.days[1].date),"collapsed day survives return")
    try check(browser.scope == nil && !browser.evidenceOpen,"return closes detail and evidence")
    try snapshot("returned-timeline")
    func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
    }
    browser.collapsedDays.removeAll()
    window.setContentSize(NSSize(width:700,height:650)); host.frame = NSRect(x:0,y:0,width:700,height:650); tick()
    if let scroll = scrollViews(host).first(where: { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 200 }) {
        scroll.contentView.scroll(to:NSPoint(x:0,y:280)); scroll.reflectScrolledClipView(scroll.contentView); tick()
        let before = scroll.contentView.bounds.origin.y
        browser.select(safari,in:activity); tick(); browser.showDay(); tick(); browser.back(); tick()
        try check(abs(scroll.contentView.bounds.origin.y-before)<1,"native scroll offset survives app/day/return")
    } else { throw MemError.invalid("Native vertical scroll view not found") }
    func accessibilityNodes(_ object: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 16, let node = object as? any NSAccessibilityProtocol else { return [] }
        return [node] + (node.accessibilityChildren() ?? []).flatMap { accessibilityNodes($0,depth:depth+1) }
    }
    let nodes = accessibilityNodes(host)
    print("Host children types: " + (host.accessibilityChildren() ?? []).map { String(describing:type(of:$0)) }.joined(separator:", "))
    print("Native accessibility nodes: " + String(nodes.count))
    func nativeButtons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { nativeButtons($0) }
    }
    let buttons: [any NSAccessibilityProtocol] = nodes.filter { $0.accessibilityRole() == .button } + nativeButtons(host)
    print("Native accessibility buttons: " + String(buttons.count))
    if let button = buttons.first(where: { ($0.accessibilityLabel() ?? "").contains("Safari,") }) {
        try check(button.accessibilityPerformPress(),"native accessibility app button press")
        tick(); try check(browser.scope?.app.bundle == "com.apple.Safari","native button opens matching app")
        browser.back(); tick()
    } else { print("LIMIT: SwiftUI accessibility children unavailable in this harness; VoiceOver activation not verified") }
    window.setContentSize(NSSize(width:1100,height:1400)); host.frame = NSRect(x:0,y:0,width:1100,height:1400); tick()
    for scroll in scrollViews(host) where (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height {
        scroll.contentView.scroll(to:.zero); scroll.reflectScrolledClipView(scroll.contentView)
    }
    tick()
    guard let iconButton=nativeButtons(host).first(where:{($0.accessibilityLabel() ?? "").contains("Safari,")}) else { throw MemError.invalid("App button unavailable") }
    let iconPoint = iconButton.convert(NSPoint(x:iconButton.bounds.midX,y:iconButton.bounds.midY),to:nil)
    let mouseUp = NSEvent.mouseEvent(with:.leftMouseUp,location:iconPoint,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:0)!
    let mouseDown = NSEvent.mouseEvent(with:.leftMouseDown,location:iconPoint,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
    // NSButton tracks synchronously during mouseDown; queue the matching release
    // first instead of waiting for mouseDown to return before delivering it.
    NSApp.postEvent(mouseUp,atStart:true); window.sendEvent(mouseDown)
    tick()
    try check(browser.scope?.app.bundle == "com.apple.Safari","native mouse app selection")
    if let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53) { _ = host.performKeyEquivalent(with:event) }
    tick()
    try check(browser.scope == nil,"Escape returns from app detail")
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        if let event = NSEvent.keyEvent(with:type,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:" ",charactersIgnoringModifiers:" ",isARepeat:false,keyCode:49) { window.sendEvent(event) }
    }
    tick()
    if browser.scope?.app.bundle == "com.apple.Safari" { print("PASS: Space activates restored app focus") }
    else { print("LIMIT: Space activation of restored focus was not observed in this harness") }
    browser.back()
    browser.collapsedDays.removeAll()
    let pending = browser.days[1].activities[0]
    browser.select(pending.apps[0],in:pending)
    try snapshot("summary-pending",width:900,height:650)
    browser.back(); browser.phase = .loading
    try snapshot("loading",width:800,height:600)
    browser.phase = .failed("Synthetic storage failure. No personal data was read.")
    try snapshot("error",width:800,height:600)
    browser.phase = .ready; browser.items = []
    try snapshot("empty",width:800,height:600)
    let request = ActivityUIFixtures.items().first { $0.id == "recipe-request" }!
    try check(ActivityWords.narrative([request]).contains("No completed action"),"request never claims completion")
    let report = ActivityUIFixtures.items().first { $0.id == "report" }!
    try check(ActivityWords.narrative([report]).contains("(not verified)"),"assistant outcome is reported, not verified")
    // The recording controls the app draws (plan §6 "UIRender main L129-133", amendments I2): the toolbar's status
    // capsule, with Start Recording beside it while Off, over the popover's RecordingControls. Every state is a
    // fixed-clock value (§8.1 copy); the actions only count, and drawing must call none of them.
    var captureCalls=0
    var countingActions=CaptureActions(pause:{_ in captureCalls += 1},resume:{captureCalls += 1},stop:{captureCalls += 1},settings:{captureCalls += 1})
    countingActions.openSystemSettings={_ in captureCalls += 1}; countingActions.checkPermissions={captureCalls += 1}
    let zone=TimeZone(identifier:"America/Los_Angeles")!
    var zoned=Calendar(identifier:.gregorian); zoned.timeZone=zone
    let clock=zoned.date(from:DateComponents(year:2026,month:9,day:22,hour:16,minute:21))!
    let captureStates:[(String,RecordingStateInputs)]=[
        ("capture-off",RecordingStateInputs(stoppedAt:clock.addingTimeInterval(-120),accessibilityGranted:true,inputMonitoringGranted:true)),
        ("capture-recording",RecordingStateInputs(recording:true,stopped:false,recordingSince:zoned.date(bySettingHour:8,minute:40,second:0,of:clock),accessibilityGranted:true,inputMonitoringGranted:true)),
        ("capture-denied",RecordingStateInputs(stoppedAt:clock.addingTimeInterval(-120),resumeUnavailable:"Permissions required",accessibilityGranted:false,inputMonitoringGranted:false)),
        ("capture-paused",RecordingStateInputs(stopped:false,pausedAt:clock.addingTimeInterval(-180),sessionReason:"Paused for sleep. Resume explicitly after waking.",accessibilityGranted:true,inputMonitoringGranted:true)),
    ]
    for (name,inputs) in captureStates {
        let presentation=CapturePresentation(inputs:inputs,permissions:PermissionSnapshot(accessibility:inputs.accessibilityGranted,inputMonitoring:inputs.inputMonitoringGranted))
        let state=presentation.state
        let controls=VStack(alignment:.trailing,spacing:12) {
            HStack(spacing:8) {
                if state.kind == .off { StartRecordingButton { countingActions.perform(.start) } }
                StatusCapsule(state:state,canStart:presentation.canResume,timeZone:zone)
            }
            RecordingControls(presentation:presentation,actions:countingActions,style:.popover)
                .padding(16).frame(width:StatusPopover.width,alignment:.leading)
                .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12,style:.continuous))
                .overlay(RoundedRectangle(cornerRadius:12,style:.continuous).strokeBorder(Color.primary.opacity(0.1)))
        }
        host = NSHostingView(rootView:AnyView(controls.padding(20).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topTrailing)
            .environment(\.daydreamNow,clock).environment(\.daydreamStatic,true).background(Color(nsColor:.windowBackgroundColor))))
        window.contentView = host
        try snapshot(name,width:740,height:state.kind == .needsPermission ? 320 : 220)
    }
    try check(captureCalls == 0,"status capsule and recording controls render without calling a capture action")
    // A fixed legacy footprint: the check must not depend on a recorder installed on this Mac.
    host = NSHostingView(rootView:AnyView(MacMemSetupView(pause:{},reviewLegacy:{LegacyFootprint(socketPresent:false,services:[])})))
    window.contentView = host
    try snapshot("setup-review",width:650,height:650)
    // Since the settings restyle the details fit a 650 pt window, so nothing scrolls there and the old premise (the
    // page overflows at 650) no longer holds. The app shows this page as Settings ▸ Requirements, in the fixed
    // 760×600 Settings sheet, whose page area is 432 pt tall (600 − 26/28 frame padding − 38 title row − 36 footer
    // − 2×20 spacing). Scrolling is checked at that height; the document must really overflow there, else this
    // still throws.
    let shortHeight:CGFloat=432
    window.setContentSize(NSSize(width:650,height:shortHeight)); host.frame=NSRect(x:0,y:0,width:650,height:shortHeight); tick()
    if let scroll=scrollViews(host).first(where:{ ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height }) {
        let end=max(0,(scroll.documentView?.frame.height ?? 0)-scroll.contentView.bounds.height)
        scroll.contentView.scroll(to:NSPoint(x:0,y:end))
        scroll.reflectScrolledClipView(scroll.contentView); tick()
        try check(scroll.contentView.bounds.origin.y > 0,"setup support/permission/pending details remain scrollable")
        try check(abs(scroll.contentView.bounds.origin.y-end) < 2,"setup details scroll to the last row")
        try snapshot("setup-details",width:650,height:shortHeight)
    } else { throw MemError.invalid("Setup details not scrollable") }
    print("Native UI render checks complete; all data was in memory. Setup action buttons were not executed.")
}
do { try MainActor.assumeIsolated {
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--whole" { try wholeWindowChecks(output:URL(fileURLWithPath:CommandLine.arguments[2])) }
    else { try renderChecks() }
} } catch { FileHandle.standardError.write(Data((String(describing:error)+"\n").utf8)); exit(1) }
