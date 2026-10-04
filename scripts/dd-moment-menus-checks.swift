// DD-RECIPE: APP
// Secondary click on a moment and the day ribbon's hover tip (owner, Preview 3), on the preview sample through the real
// launch path (a new sample in a scratch temporary folder), in the real window content (`MemoryWindow`, offscreen):
//   A. a Recall result row's context menu is the ⌘K Actions menu for that row (same items, order, enabled states);
//   B. a Focus List row's and a ribbon span's context menus are the moment's actions (`MomentActions.items`, the
//      Focus List's), the same for the row and its span; an item runs the row's action;
//   C. the ribbon's hover tip (design B): the moment's icon, its clean title (no unread counts, no addresses, no
//      " in <App>") over `1:31–1:45 PM · Xcode`; it comes up after 0.3 s.
// The menus are read the way AppKit asks for them (`NSView.menu(for:)` with a right-mouse-down event), never shown.
// PNGs in DD_CHECK_OUT/moment-menus: each menu drawn beside what was clicked, and the tip over a span.
// Never launches the app, never orders a window on screen, never requests a permission, never records.
import AppKit
import SwiftUI
import MemoryCore
import MemoryUI

func fail(_ message: String) -> Never {
    fflush(stdout)
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}
@MainActor func expect(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { fail(message()) } else { print("PASS: \(message())"); fflush(stdout) } }
@MainActor func pump(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
@MainActor @discardableResult func wait(_ timeout: Double, _ done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { pump(0.05) }
    return done()
}

/// A menu as lines: `Title`, `Title (off)` for a disabled item, `---` for a divider.
func lines(_ entries: [MomentContextMenu.Entry]) -> [String] {
    entries.map { entry in
        switch entry {
        case .action(let item): return item.title + (item.enabled ? "" : " (off)")
        case .site(let request): return request.menuTitle
        case .divider: return "---"
        }
    }
}
func lines(_ menu: NSMenu?) -> [String] {
    (menu?.items ?? []).map { $0.isSeparatorItem ? "---" : $0.title + ($0.isEnabled ? "" : " (off)") }
}

@main struct MomentMenusChecks {
    @MainActor static func main() throws {
        guard let out = ProcessInfo.processInfo.environment["DD_CHECK_OUT"], !out.isEmpty else { fail("DD_CHECK_OUT is required") }
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil else { fail("CFFIXED_USER_HOME must point at a scratch folder") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { fail("timed out") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let shots = URL(fileURLWithPath: out).appendingPathComponent("moment-menus", isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)

        // C (values first). The tip's words, from the segment alone.
        let tz = TimeZone.current
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let at = { (h: Int, m: Int) in cal.date(bySettingHour: h, minute: m, second: 0, of: Date())! }
        let r = { (a: Date, b: Date) in DaydreamFormat.range(a, b, tz) }
        var docs = RibbonSegment(id: "d", start: at(16, 5), end: at(16, 38), tint: .blue, label: "Google Chrome", title: "Investor update")
        docs.bundle = "com.google.Chrome"; docs.site = "docs.google.com"
        expect(RibbonTooltip.title(docs) == "Investor update" && RibbonTooltip.detail(docs, timeZone: tz) == r(at(16, 5), at(16, 38)) + " · Google Chrome",
               "the tip is the title over its time and app (\(RibbonTooltip.line(docs, timeZone: tz)))")
        var mail = RibbonSegment(id: "m", start: at(9, 0), end: at(9, 20), tint: .blue, label: "Mail", title: ThreadEntities.clean("(12) Inbox - maya@example.com"))
        mail.bundle = "com.apple.mail"
        let mailLine = RibbonTooltip.line(mail, timeZone: tz)
        expect(mailLine == "Inbox · " + r(at(9, 0), at(9, 20)) + " · Mail", "a window title's unread count and address never reach the tip (\(mailLine))")
        let code = RibbonSegment(id: "x", start: at(13, 31), end: at(13, 45), tint: .blue, label: "Xcode", title: "WeeklySummaryExport.swift in Xcode")
        expect(RibbonTooltip.title(code) == "WeeklySummaryExport.swift", "the title drops the \" in <App>\" the second line already says")
        let bare = RibbonSegment(id: "y", start: at(10, 0), end: at(10, 5), tint: .blue, label: "Zed")
        expect(RibbonTooltip.title(bare) == "Zed", "no title: the app names the span")
        expect(DDRibbon.tipDelay == 300_000_000, "the tip comes up 0.3 s after the pointer reaches a span")

        // The preview's model, on a new sample in a scratch folder.
        let scratch = URL(fileURLWithPath: out).appendingPathComponent("moment-menus-temp", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let session = DaydreamLaunchSession(arguments: ["DayDream", "--preview-sample", PreviewSample.reseedArgument], previewTemporaryDirectory: scratch)
        wait(240) { !session.preparing }
        guard let model = session.model else { fail("no preview model: \(session.failure ?? "")") }
        let browser = model.activity
        // Stand-ins so the menus carry every action; nothing here opens, excludes or forgets anything.
        var opened: [String] = []
        browser.openApp = { opened.append($0) }
        browser.excludeApp = { _ in }
        browser.previewCanonicalDelete = { _ in throw MemError.invalid("check") }
        browser.confirmCanonicalDelete = { _ in }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AnyView(MemoryWindow(model: model, chrome: .inline)))
        window.contentView = host
        func settle(_ s: Double = 1.0) { window.setContentSize(NSSize(width: 1180, height: 800)); pump(s); host.layoutSubtreeIfNeeded(); pump(0.2) }
        wait(30) { browser.today.snapshot?.levels != nil }
        settle(2.0)
        // Before the busiest sample day fits into today (early morning), the sample moves it to yesterday: open that day.
        var loaded = browser.today.snapshot
        if loaded?.moments.isEmpty ?? true, let y = browser.calendar.date(byAdding: .day, value: -1, to: Date()),
           let key = try? DayScope.key(y, timezone: browser.calendar.timeZone.identifier) {
            browser.focusedDay = key
            Task { @MainActor in
                if let d = try? await browser.dayCache.day(key) { loaded = TodaySnapshot.make(day: d, summaries: browser.summaries, calendar: browser.calendar, now: Date()) }
            }
            wait(30) { loaded?.levels != nil && loaded?.dayKey == key }
            settle(2.0)
        }
        guard let snap = loaded, !snap.moments.isEmpty else { fail("the sample day has no moments") }

        /// The menu AppKit would show for a secondary click at `p` (host coordinates).
        func menu(at p: NSPoint) -> NSMenu? {
            guard let e = NSEvent.mouseEvent(with: .rightMouseDown, location: host.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
            var view: NSView? = host.hitTest(p) ?? host
            while let v = view { if let m = v.menu(for: e) { return m }; view = v.superview }
            return nil
        }
        func bitmap(_ view: NSView) -> NSBitmapImageRep {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fail("no bitmap") }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        func save(_ rep: NSBitmapImageRep, _ name: String) {
            do { try rep.representation(using: .png, properties: [:])!.write(to: shots.appendingPathComponent(name + ".png")) } catch { fail("\(name): \(error)") }
            print("PNG: " + shots.appendingPathComponent(name + ".png").path)
        }
        /// The window with the menu's lines drawn as a menu at `p`, where AppKit would open it.
        func renderMenu(_ name: String, _ menuLines: [String], at p: NSPoint) {
            let drawn = VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(menuLines.enumerated()), id: \.offset) { _, line in
                    if line == "---" { Divider().padding(.vertical, 5).padding(.horizontal, 10) }
                    else {
                        Text(line.replacingOccurrences(of: " (off)", with: "")).font(.system(size: 13))
                            .foregroundStyle(line.hasSuffix(" (off)") ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                            .padding(.horizontal, 14).frame(height: 22, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, 5).frame(minWidth: 220, alignment: .leading).fixedSize()
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5))
            let menuHost = NSHostingView(rootView: drawn)
            menuHost.frame = NSRect(origin: .zero, size: menuHost.fittingSize)
            let menuRep = bitmap(menuHost)
            let base = bitmap(host)
            let w = base.pixelsWide, h = base.pixelsHigh, scale = CGFloat(w) / host.bounds.width
            guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fail("no canvas") }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
            base.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            // Host coordinates are flipped; the canvas is not. The menu's top-left sits at the click.
            let mw = CGFloat(menuRep.pixelsWide), mh = CGFloat(menuRep.pixelsHigh)
            let x = min(p.x * scale, CGFloat(w) - mw), top = CGFloat(h) - p.y * scale
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.shadowBlurRadius = 14 * scale
            shadow.shadowOffset = NSSize(width: 0, height: -5 * scale); shadow.set()
            let menuImage = NSImage(size: NSSize(width: mw, height: mh)); menuImage.addRepresentation(menuRep)
            let frame = NSRect(x: x, y: max(0, top - mh), width: mw, height: mh)
            NSBezierPath(roundedRect: frame, xRadius: 9 * scale, yRadius: 9 * scale).addClip()
            menuImage.draw(in: frame)
            // The pointer's spot.
            NSGraphicsContext.restoreGraphicsState(); NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
            NSColor.systemRed.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x * scale - 5, y: CGFloat(h) - p.y * scale - 5, width: 10, height: 10)).fill()
            NSGraphicsContext.restoreGraphicsState()
            save(out, name)
        }

        let caps = MomentActions.Capabilities(browser: browser)
        func focusMenu(_ m: MomentSlice) -> [String] {
            lines(MomentContextMenu.entries(MomentActions.items(for: m, context: .focusList, browser: caps), sites: MomentActions.siteRequests(for: m, browser: caps)))
        }

        // Where things are: the day card's ribbon reports its frame (a check hook); rows are found by asking for the
        // menu down the list's middle (the preview's window has no accessibility client to ask).
        guard let ribbonGlobal = DDRibbon.dayCardFrameForTesting, ribbonGlobal.width > 100 else { fail("the day card's ribbon has no frame") }
        // SwiftUI's global space is the window's (top-left, the title bar included); the host is the content below it.
        let ribbonRect = ribbonGlobal.offsetBy(dx: 0, dy: -(window.frame.height - host.bounds.height))
        func firstMenu(x: CGFloat, from y0: CGFloat, to y1: CGFloat, where ok: ([String]) -> Bool) -> (NSMenu, NSPoint)? {
            var y = y0
            while y < y1 {
                let p = NSPoint(x: x, y: y)
                if let m = menu(at: p), ok(lines(m)) { return (m, NSPoint(x: x, y: y + 12)) }
                y += 4
            }
            return nil
        }

        // B. A Focus List row: its menu is its moment's actions. Which moment: the one its Open <App> item opens.
        guard let (rowMenu0, rowPoint) = firstMenu(x: ribbonRect.midX, from: ribbonRect.maxY + 40, to: host.bounds.height - 10,
                                                   where: { $0.contains { $0.hasPrefix("Open ") } && $0.contains("Copy Summary") }) else { fail("no Focus List row with a menu") }
        let rowMenu = menu(at: rowPoint) ?? rowMenu0
        let rowLines = lines(rowMenu)
        guard let openIndex = rowMenu.items.firstIndex(where: { $0.title.hasPrefix("Open ") && $0.isEnabled }) else { fail("the row menu has no Open item") }
        rowMenu.performActionForItem(at: openIndex); pump(0.3)
        guard let rowMoment = snap.moments.first(where: { $0.id == browser.selectedMomentID }) else { fail("the row menu's Open selected no moment") }
        print("row \"\(rowMoment.title)\": \(rowLines)")
        expect(opened.last == rowMoment.primaryBundle, "the row menu's \(rowMenu.items[openIndex].title) opens its moment's app (\(opened.last ?? "nothing"))")
        expect(rowLines == focusMenu(rowMoment) + (browser.canForgetRange ? [ForgetRangeText.menuTitle] : []), "a Focus List row's secondary click shows its moment's actions: \(rowLines.joined(separator: " | "))")
        expect(rowLines.contains("Copy Summary") && rowLines.contains { $0.hasPrefix("Find Related") } && rowLines.contains { $0.hasPrefix("Forget") },
               "the row's menu has Open, Copy Summary, Find Related and Forget")
        renderMenu("focus-row-menu", rowLines, at: rowPoint)

        // B. A span on the day card's ribbon: the same menu as its moment's row.
        let ribbon = RibbonModel.make(snapshot: snap, state: model.recordingState, now: Date(), calendar: browser.calendar, isToday: browser.focusedDay == nil).dayCard
        let span = max(1, ribbon.range.upperBound.timeIntervalSince(ribbon.range.lowerBound))
        func sx(_ d: Date) -> CGFloat { ribbonRect.minX + CGFloat(min(max(d.timeIntervalSince(ribbon.range.lowerBound) / span, 0), 1)) * ribbonRect.width }
        let widest = ribbon.segments.filter { seg in snap.moments.contains { $0.id == seg.group && $0.primaryApp != nil } }
            .max { sx($0.end) - sx($0.start) < sx($1.end) - sx($1.start) }
        guard let seg = widest, let segMoment = snap.moments.first(where: { $0.id == seg.group }) else { fail("no span with an app") }
        // With bands the slim bar sits 7 pt down; the bar is 8 pt.
        let spanPoint = NSPoint(x: (sx(seg.start) + sx(seg.end)) / 2, y: ribbonRect.minY + 7 + 4)
        let spanLines = lines(menu(at: spanPoint))
        print("span \"\(segMoment.title)\" at \(Int(spanPoint.x)),\(Int(spanPoint.y)): \(spanLines)")
        expect(!spanLines.isEmpty && spanLines == focusMenu(segMoment), "a ribbon span's secondary click shows its moment's actions: \(spanLines.joined(separator: " | "))")
        renderMenu("ribbon-span-menu", spanLines, at: spanPoint)
        // Past the last span (the track's far end): no menu.
        let gap = NSPoint(x: ribbonRect.maxX - 2, y: spanPoint.y)
        if !ribbon.segments.contains(where: { sx($0.start) - 4 <= gap.x && gap.x <= sx($0.end) + 4 }) {
            expect(lines(menu(at: gap)).isEmpty, "the bar away from the spans has no menu")
        }

        // C. The tip over a span in the day card (pinned: no pointer over a render). A web moment when there is one.
        let tipSeg = ribbon.segments.filter { $0.title?.contains("WeeklySummaryExport") == true }.max { $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start) }
            ?? ribbon.segments.first { $0.site == "docs.google.com" } ?? seg
        for s in ribbon.segments {
            guard let m = snap.moments.first(where: { $0.id == s.group }) else { continue }
            let clean = ThreadEntities.clean(m.title)
            if s.title != (clean.isEmpty ? nil : clean) { fail("span \(s.id)'s title is not the moment's clean title (\(s.title ?? "nil") vs \(clean))") }
            let line = RibbonTooltip.line(s, timeZone: browser.calendar.timeZone)
            if line.contains("@") || line.range(of: "\\(\\d+\\+?\\)", options: .regularExpression) != nil { fail("a tip carries window-title noise: \(line)") }
        }
        expect(true, "every span's tip is its moment's clean title (\(ribbon.segments.count) spans), no counts or addresses")
        print("tip: " + RibbonTooltip.line(tipSeg, timeZone: browser.calendar.timeZone))
        host.rootView = AnyView(MemoryWindow(model: model, chrome: .inline).environment(\.daydreamRibbonTip, tipSeg.group))
        settle(1.0)
        save(bitmap(host), "ribbon-tip")
        // The day card alone, for a closer look.
        let card = NSRect(x: max(0, ribbonRect.minX - 30), y: max(0, ribbonRect.minY - 110), width: min(ribbonRect.width + 60, host.bounds.width), height: 160)
        if let rep = host.bitmapImageRepForCachingDisplay(in: card) { host.cacheDisplay(in: card, to: rep); save(rep, "ribbon-tip-card") }
        host.rootView = AnyView(MemoryWindow(model: model, chrome: .inline).environment(\.daydreamRibbonTip, tipSeg.group)
            .environment(\.colorScheme, .dark))
        window.appearance = NSAppearance(named: .darkAqua)
        settle(1.0)
        save(bitmap(host), "ribbon-tip-dark")
        if let rep = host.bitmapImageRepForCachingDisplay(in: card) { host.cacheDisplay(in: card, to: rep); save(rep, "ribbon-tip-card-dark") }
        window.appearance = NSAppearance(named: .aqua)
        host.rootView = AnyView(MemoryWindow(model: model, chrome: .inline))
        settle(0.5)

        // A. Recall: a result row's secondary click is the ⌘K Actions menu for that row.
        browser.recallPresented = true
        let recall = browser.recallModel
        var found = false
        for q in ["investor", "export", "pricing", "email"] {
            browser.query = ""; pump(0.3)
            browser.query = q
            wait(20) { !recall.busy && recall.displayRows.contains { $0.moment?.primaryApp != nil } }
            if recall.displayRows.contains(where: { $0.moment?.primaryApp != nil }) { found = true; break }
        }
        expect(found, "Recall finds moments in the sample")
        settle(1.5)
        // The first result row with a moment: its menu leads with Open Moment. Which row: the one Open Moment opens.
        guard let (recallMenu, recallPoint) = firstMenu(x: host.bounds.width / 2 - 120, from: 60, to: host.bounds.height - 10,
                                                        where: { $0.first == "Open Moment" && $0.contains("Copy Summary") }) else { fail("no Recall row with a moment menu") }
        let contextLines = lines(menu(at: recallPoint) ?? recallMenu)
        let openMoment = (menu(at: recallPoint) ?? recallMenu)
        guard let oi = openMoment.items.firstIndex(where: { $0.title == "Open Moment" }) else { fail("no Open Moment") }
        openMoment.performActionForItem(at: oi); pump(0.4)
        guard let rowID = recall.detailRowID, let recallRow = recall.displayRows.first(where: { $0.id == rowID }) else { fail("Open Moment opened no row") }
        expect(true, "the Recall row menu's Open Moment opens that row (\(recallRow.title))")
        recall.back(); pump(0.3)
        recall.select(rowID); pump(0.3)
        recall.toggleMenu(); pump(0.2)
        expect(recall.menuOpen, "⌘K opens the Actions menu for the selected row")
        let commandK = lines(MomentContextMenu.entries(recall.visibleMenuItems))
        print("recall \"\(recallRow.title)\": context \(contextLines) · ⌘K \(commandK)")
        expect(!contextLines.isEmpty && contextLines == commandK, "a Recall row's secondary click shows the ⌘K Actions menu's items: \(contextLines.joined(separator: " | "))")
        expect(contextLines.contains { $0.hasPrefix("Show in ") } && contextLines.contains { $0.hasPrefix("Forget") }, "it offers Show in <Day> and Forget, as ⌘K does")
        recall.closeMenu(); pump(0.2)
        renderMenu("recall-row-menu", contextLines, at: recallPoint)
        // Search is flat and shows moments in context (owner, 9/30): no row is a note, and no row offers Find Related.
        expect(recall.displayRows.allSatisfy { $0.moment != nil || $0.kind == .action }, "every Recall row is one moment or one hit")
        expect(!recall.displayRows.contains { row in recall.menuItems(for: row).contains { $0.id == .findRelated } },
               "no Recall row's menu offers Find Related Moments")
        browser.query = ""; browser.recallPresented = false
        window.contentView = nil
        print("Moment menu checks: offscreen only. No app launched, no permission requested, nothing recorded.")
        exit(0)
    }
}
