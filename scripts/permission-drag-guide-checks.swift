// DD-RECIPE: UI (MemoryUI MemoryCore HistoryCore PrivacyPolicy objects, no app sources)
// rel-018 v2: setup's Accessibility and Input Monitoring steps (`PermissionDragGuide`, Sources/MemoryUI/PermissionDragGuide.swift).
//   A. Placement (`PermissionPair`): the pair centered on the screen, 16 pt apart, tops aligned (2560x1440 with a Dock:
//      setup at x 581, System Settings at x 1257), the sidebar overlap on a small screen; setup always follows System
//      Settings' actual frame; full screen, minimized or no Accessibility: no writes; settling and read-back tolerances;
//      the list's zone never above the list's top edge minus 6 pt; the drop point inside the list. A2: top-left rects into the
//      overlay's coordinates on the primary screen's top (the mini's screen with its Dock, and a second display).
//   B. When it ends: granted, DayDream listed (only when it wasn't at the start), System Settings closed, pane changed.
//   C. The demo: its timeline and schedule (3 plays, then one every 6 s); the canvas draws no ring (owner 10/8), only
//      the card's image and the system grab hand (renders into DD_CHECK_OUT).
//   D. Source rules: never a permission request API, System Settings written only by the 3-write setFrame, a
//      click-through overlay with no words, no fake switch or "Turn this on" tip, Reduce Motion, the card's one line.
//   E. Live, without System Settings: a granted read ends it at once and touches nothing.
//   F. The card's drag: the installed app's URL itself on the pasteboard (AppKit), no item provider, file promise or copy
//      (no new ~/Library/Caches/com.apple.SwiftUI.Drag-* folder).
//   G. Reads into the card: a read of allowed shows Allowed on that tick, the helper running or not.
//   H. The first press (owner 10/8 21:30: "I have to click like twice to drag"): the real page in a window that is not
//      key, DayDream inactive (System Settings in front): one press and a 3 pt move start exactly one drag session; a
//      click, a press on the button, a Control-press or a card that can't drag start none; every event goes on
//      unchanged and a button on a card still answers its click. (AppKit's session is stood in for: nothing is dragged.)
//   I. One click (rc-018 RC3, owner 10/9: "after restart had to click the connect the chrome button twice"): setup's
//      page in a window that is not key, DayDream inactive: one click on the Chrome row's Allow, Continue or Back acts
//      exactly once; DayDream becoming active with the press (a read of Chrome's access starts) keeps Allow under it
//      and the click still presses it once; only a question in flight shows the spinner.
//   J. rc-018 RC3 B1/B2/B3/B10: the drag image is the app's icon (60 pt) centred on the pointer; a copy only, modifier
//      keys ignored; how a drag ended goes to the card (outside System Settings, the app moved); a drop on System
//      Settings brings it forward; an Allowed card doesn't drag; a lost session never holds the next drag.
//   K. B4/B8: the guided card's line for each row state (none, off, on but stale), the Accessibility step's one line and
//      its remove-and-add-again step, the password prompt dismissed (its line stands until the next grab), only a drop
//      System Settings took starts the 8 s (review 10/9); the re-add step under the cards, never above.
//   L. B5: no window moves while a press or a drag is on; the move goes once it's over.
//   M. B6: either card's first grab ends the demo for the run; the demo never lands on a row or its switch.
//   N. B7: at 1280, 1440 and 1470 pt setup never covers System Settings' list (clamped over its sidebar, else the compact
//      drag panel); the covered part is cut out of the drop zone.
//   O. B9: a sheet and its parent never float; a `Turn on …` press after setup opens the small permissions window, and
//      so does a card's Open System Settings in Settings › Permissions (review 10/9).
// Nothing here opens System Settings, moves a window of another app or asks for a permission. Every window is an
// `OffscreenWindow` (never pulled onto the screen); the move checks use a virtual screen far off every real one.
import AppKit
import SwiftUI
import MemoryUI

var passed = 0, failed = 0
/// Every window here stays off every screen: AppKit pulls a titled window ordered in at -4000 back onto the screen unless
/// it refuses (`constrainFrameRect`), as chrome-ask-checks' KeyWindow does (rc-018 RC3: the owner saw these windows).
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    /// macOS 26 already moves a window made at -4000 onto the screen in `init` (480,160 on this Mac, probe 10/9), before
    /// `constrainFrameRect` is ever asked: put it back off screen right away (a window asked for on screen, as a sheet's
    /// placeholder at 0,0, goes to -5000 too; AppKit places an attached sheet by its off-screen parent).
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        let off = contentRect.minX <= -1000 && contentRect.minY <= -1000 ? contentRect.origin : NSPoint(x: -5000, y: -5000)
        setFrameOrigin(off)
    }
}
func check(_ ok: Bool, _ name: String) { if ok { passed += 1; print("PASS " + name) } else { failed += 1; print("FAIL " + name) } }
func near(_ a: CGFloat, _ b: CGFloat, _ by: CGFloat = 0.6) -> Bool { abs(a - b) < by }

@main struct PermissionDragGuideChecks {
    @MainActor static func main() {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        typealias Pair = PermissionPair

        // A. The Mac mini's 2560x1440 screen (menu bar 30 pt, Dock 90 pt): its visible frame, top-left origin.
        let mini = Pair.flipped(CGRect(x: 0, y: 90, width: 2560, height: 1320), primaryHeight: 1440)
        check(mini == CGRect(x: 0, y: 30, width: 2560, height: 1320)
              && Pair.flipped(Pair.flipped(mini, primaryHeight: 1440), primaryHeight: 1440) == mini,
              "A: AppKit and top-left rects flip on the primary screen's height, both ways")
        let settings = CGRect(x: 918, y: 408, width: 723, height: 625)  // where System Settings opened on the mini
        let setup = CGRect(x: 950, y: 404, width: 660, height: 632)
        let a = Pair.place(setup: setup, settings: settings, visible: mini, stageManager: false)
        check(a.option == .centered && a.setup.minX == 581 && a.settings.minX == 581 + 660 + 16 && near((a.setup.minX + a.settings.maxX) / 2, 1280, 1),
              "A: 2560x1440: the pair centered on the screen, setup at x 581, System Settings 16 pt right of it: \(a.setup) \(a.settings)")
        check(a.settings.minY == a.setup.minY && near(a.setup.midY, mini.midY, 1) && a.settings.width == 723 && a.settings.height == 632 && a.overlap == 0
              && a.setup.size == setup.size,
              "A: tops aligned and the taller centered on the visible frame (Dock and menu bar left out); widths kept: \(a.setup) \(a.settings)")
        // Where the owner's test left them (10/7): adjacent but low, by the Dock. Placement now ignores where setup was.
        let lowStart = Pair.place(setup: CGRect(x: 1056, y: 710, width: 660, height: 632), settings: CGRect(x: 1732, y: 725, width: 723, height: 624),
                                  visible: mini, stageManager: false)
        check(lowStart.setup.minY == 374 && lowStart.settings.minY == 374 && lowStart.setup.minX == 581,
              "A: from the owner's low pair (setup y 710, System Settings y 725) both go to the middle, y 374: \(lowStart.setup) \(lowStart.settings)")
        let short = Pair.place(setup: CGRect(x: 950, y: 404, width: 660, height: 400), settings: settings, visible: mini, stageManager: false)
        check(short.settings.height == Pair.minHeight, "A: never shorter than System Settings' 470 pt minimum: \(short.settings.height)")
        let low = Pair.place(setup: CGRect(x: 950, y: 1000, width: 660, height: 340), settings: settings, visible: mini, stageManager: false)
        check(low.settings.maxY <= mini.maxY - Pair.margin + 0.5 && low.settings.height >= Pair.minHeight && low.settings.minY == low.setup.minY
              && near(low.settings.midY, mini.midY, 1),
              "A: a short setup: System Settings (the taller) is centered, tops aligned: \(low.setup) \(low.settings)")
        let rightEdge = Pair.place(setup: CGRect(x: 1800, y: 404, width: 660, height: 632), settings: settings, visible: mini, stageManager: false)
        check(rightEdge == a, "A: wherever setup starts, the pair ends in the same centered place")
        let mid = Pair.flipped(CGRect(x: 0, y: 0, width: 1600, height: 1000), primaryHeight: 1000)
        let centered = Pair.place(setup: CGRect(x: 500, y: 200, width: 660, height: 600), settings: CGRect(x: 400, y: 150, width: 723, height: 625),
                                  visible: mid, stageManager: false)
        check(centered.option == .centered && near((centered.setup.minX + centered.settings.maxX) / 2, 800, 1)
              && centered.settings.minX - centered.setup.maxX == 16 && centered.setup.minY == centered.settings.minY,
              "A: room on neither side: the pair centered, 16 pt apart, tops aligned: \(centered.setup) \(centered.settings)")
        let air = Pair.flipped(CGRect(x: 0, y: 0, width: 1470, height: 923), primaryHeight: 956)
        let airPair = Pair.place(setup: CGRect(x: 405, y: 150, width: 660, height: 632), settings: CGRect(x: 373, y: 160, width: 723, height: 625),
                                 visible: air, stageManager: false)
        check(airPair.option == .centered && airPair.overlap == 0, "A: 1470x956 fits the pair side by side: \(airPair.option)")
        let stage = Pair.place(setup: CGRect(x: 405, y: 150, width: 660, height: 632), settings: CGRect(x: 373, y: 160, width: 723, height: 625),
                               visible: air, stageManager: true)
        check(stage.option == .overlap && stage.overlap > 0 && stage.overlap <= Pair.sidebar && stage.setup.minX >= 8 + 96
              && stage.settings.maxX <= 1470 - 8 && stage.setup.maxX <= stage.settings.minX + 243,
              "A: 1470x956 with Stage Manager: setup covers at most the 215 pt sidebar, the list stays in view: overlap \(stage.overlap)")
        // Setup follows System Settings' actual frame (no Accessibility needed).
        let ignored = CGRect(x: 1732, y: 725, width: 723, height: 625)
        let follow = Pair.follow(setup: CGSize(width: 660, height: 632), settings: ignored, visible: mini, stageManager: false)
        check(follow.maxX == ignored.minX - 16 && follow.minY == min(ignored.minY, mini.maxY - 632) && mini.contains(follow),
              "A: System Settings ignored the move: setup goes 16 pt left of it, tops aligned as far as the visible frame allows: \(follow)")
        // The owner's 10/8 Accessibility run: setup (1056,710 660x632) already 16 pt left of System Settings
        // (1732,725 723x624), tops 15 pt apart, visible frame y 30..1350. Already adjacent still lines the tops up, as far
        // as the visible frame allows (725 + 632 = 1357 would hang 7 pt under the Dock): y 718, bottoms within 1 pt.
        let ownerSettings = CGRect(x: 1732, y: 725, width: 723, height: 624)
        let ownerFollow = Pair.follow(setup: CGSize(width: 660, height: 632), settings: ownerSettings, visible: mini, stageManager: false)
        check(ownerFollow == CGRect(x: 1056, y: 718, width: 660, height: 632) && mini.contains(ownerFollow) && ownerFollow.maxY == mini.maxY
              && abs(ownerFollow.minY - ownerSettings.minY) < abs(710 - ownerSettings.minY),
              "A: owner's 10/8 geometry (already adjacent, tops 15 pt apart): setup moves down to y 718, on the visible frame: \(ownerFollow)")
        let ownerFits = Pair.follow(setup: CGSize(width: 660, height: 620), settings: ownerSettings, visible: mini, stageManager: false)
        check(ownerFits.minX == 1056 && ownerFits.minY == ownerSettings.minY && mini.contains(ownerFits),
              "A: the same pair when setup fits below System Settings' top: tops exactly aligned (y 725): \(ownerFits)")
        let atLeft = Pair.follow(setup: CGSize(width: 660, height: 632), settings: CGRect(x: 20, y: 100, width: 723, height: 625), visible: mini, stageManager: false)
        check(atLeft.minX == 20 + 723 + 16 && atLeft.minY == 100, "A: System Settings at the left edge: setup 16 pt right of it: \(atLeft)")
        let placed = Pair.follow(setup: setup.size, settings: a.settings, visible: mini, stageManager: false)
        check(placed == a.setup, "A: once System Settings took the move, setup's follow lands on the centered spot: \(placed)")
        let offCenter = Pair.follow(setup: CGSize(width: 660, height: 632), settings: CGRect(x: 1300, y: 200, width: 723, height: 624), visible: mini, stageManager: false)
        check(offCenter.maxX == 1300 - 16 && offCenter.minY == 200 && mini.contains(offCenter),
              "A: Accessibility step (System Settings can't move): setup left of it, tops aligned, on the visible frame: \(offCenter)")
        let tight = Pair.follow(setup: CGSize(width: 660, height: 632), settings: stage.settings, visible: air, stageManager: true)
        check(tight.minX == 8 + 96 && tight.maxX - stage.settings.minX <= Pair.sidebar, "A: no room either side: setup at the edge away from it, over the sidebar: \(tight)")
        check(!Pair.writesSettings(settings: CGRect(x: 0, y: 0, width: 2560, height: 1440), screen: CGRect(x: 0, y: 0, width: 2560, height: 1440), minimized: false, trusted: true)
              && !Pair.writesSettings(settings: settings, screen: CGRect(x: 0, y: 0, width: 2560, height: 1440), minimized: true, trusted: true)
              && !Pair.writesSettings(settings: settings, screen: CGRect(x: 0, y: 0, width: 2560, height: 1440), minimized: false, trusted: false)
              && Pair.writesSettings(settings: settings, screen: CGRect(x: 0, y: 0, width: 2560, height: 1440), minimized: false, trusted: true),
              "A: full screen, minimized or no Accessibility: System Settings is never written")
        check(Pair.settled(CGRect(x: 10, y: 10, width: 723, height: 625), CGRect(x: 10.8, y: 10, width: 723, height: 625))
              && !Pair.settled(CGRect(x: 10, y: 10, width: 723, height: 625), CGRect(x: 14, y: 10, width: 723, height: 625))
              && !Pair.settled(CGRect(x: 10, y: 10, width: 723, height: 150), CGRect(x: 10, y: 10, width: 723, height: 150)) && !Pair.settled(nil, settings),
              "A: settled = two reads within 1 pt, taller than 200 pt")
        check(Pair.took(a.settings, a.settings.offsetBy(dx: 1, dy: -1)) && !Pair.took(a.settings, a.settings.offsetBy(dx: 3, dy: 0))
              && !Pair.took(a.settings, CGRect(x: 1626, y: 404, width: 723, height: 625)), "A: a move took when the read-back is within 2 pt")
        // The list's zone (where the demo lands; never drawn): around the list, never above its top edge minus 6 pt.
        let window = CGRect(x: 1626, y: 404, width: 723, height: 632)
        let list = CGRect(x: 1869, y: 509, width: 460, height: 128)
        let zone = Pair.zone(list: list, settingsWindow: window)
        check(zone.contains(list) && window.contains(zone) && zone.minY >= list.minY - 6, "A: the list's zone surrounds the list inside the window, its top >= the list's - 6: \(zone)")
        let estimate = Pair.estimatedList(settingsWindow: window)
        let estimated = Pair.zone(list: nil, settingsWindow: window)
        check(estimate.minX == window.minX + 243 && estimate.minY == window.minY + 105 && estimated.minY >= estimate.minY - 6 && window.contains(estimated),
              "A: no list found: the zone around the estimate, under the description: \(estimated)")
        check(Pair.zone(list: CGRect(x: 1869, y: 509, width: 10, height: 5), settingsWindow: window) == estimated, "A: an unusable list falls back to the estimate")
        let hugging = Pair.zone(list: CGRect(x: 1869, y: 406, width: 460, height: 128), settingsWindow: window)
        check(hugging.minY >= 406 - 6, "A: a list at the window's top keeps the rule: \(hugging)")
        let drop = Pair.dropPoint(list: list, firstRow: CGRect(x: 1869, y: 509, width: 460, height: 24))
        check(drop == CGPoint(x: list.minX + 72, y: 521), "A: the demo drops 72 pt into the list on its first row: \(drop)")
        let dropTiny = Pair.dropPoint(list: CGRect(x: 0, y: 0, width: 60, height: 40), firstRow: nil)
        check(dropTiny.x <= 60 - 12 && dropTiny.y == 20, "A: the drop point stays 12 pt inside the list: \(dropTiny)")
        let c = Pair.arcControl(from: CGPoint(x: 0, y: 500), to: CGPoint(x: 2000, y: 500))
        check(c == CGPoint(x: 1000, y: 492), "A: the arc rises at most 8 pt (4 pt above the line), never over setup's title: \(c)")

        // A2. Into the overlay's coordinates. The mini: one 2560x1440 screen, visible frame y 90..1410 (AppKit), the overlay
        // over the whole screen. Everything flips on the primary screen's top (1440), never on the visible frame.
        let miniScreen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let owner = CGRect(x: 1732, y: 725, width: 723, height: 624)  // System Settings, window server, the owner's run
        check(Pair.local(topLeft: owner, in: miniScreen, primaryHeight: 1440) == owner,
              "A2: on the primary screen the overlay's coordinates are the window server's: \(Pair.local(topLeft: owner, in: miniScreen, primaryHeight: 1440))")
        // Setup at window-server y 710 is AppKit y 98 (1440 - 710 - 632); a card 400 pt down its window, 74 tall.
        let cardAppKit = CGRect(x: 1092, y: 98 + 632 - 400 - 74, width: 588, height: 74)
        check(Pair.local(appKit: cardAppKit, in: miniScreen) == CGRect(x: 1092, y: 710 + 400, width: 588, height: 74),
              "A2: the card (AppKit) lands 400 pt under setup's top in the overlay: \(Pair.local(appKit: cardAppKit, in: miniScreen))")
        let visibleTL = Pair.flipped(CGRect(x: 0, y: 90, width: 2560, height: 1320), primaryHeight: 1440)
        check(Pair.local(topLeft: visibleTL, in: miniScreen, primaryHeight: 1440) == CGRect(x: 0, y: 30, width: 2560, height: 1320)
              && Pair.local(topLeft: owner, in: miniScreen, primaryHeight: 1440 - 90) != owner,
              "A2: the Dock and menu bar don't shift anything (flipping on the visible frame's height would be 90 pt off)")
        let p = CGPoint(x: 1975, y: 830)
        check(Pair.global(local: Pair.local(topLeft: p, in: miniScreen, primaryHeight: 1440), in: miniScreen, primaryHeight: 1440) == p
              && Pair.local(topLeft: p, in: miniScreen, primaryHeight: 1440) == p, "A2: points go into the overlay and back")
        // A second display, 1920x1080, right of the primary and 200 pt up (AppKit (2560, 200)): window server y 160..1240.
        let second = CGRect(x: 2560, y: 200, width: 1920, height: 1080)
        check(Pair.flipped(second, primaryHeight: 1440) == CGRect(x: 2560, y: 160, width: 1920, height: 1080), "A2: the second display's top-left frame")
        let onSecond = CGRect(x: 2900, y: 300, width: 723, height: 632)
        check(Pair.local(topLeft: onSecond, in: second, primaryHeight: 1440) == CGRect(x: 340, y: 140, width: 723, height: 632)
              && Pair.local(topLeft: onSecond, in: second, primaryHeight: 1080) != CGRect(x: 340, y: 140, width: 723, height: 632),
              "A2: on the second display: 340, 140 into its overlay (its own height, 1080, would be wrong): \(Pair.local(topLeft: onSecond, in: second, primaryHeight: 1440))")
        let secondCard = Pair.flipped(CGRect(x: 3000, y: 500, width: 588, height: 74), primaryHeight: 1440)  // AppKit
        check(Pair.local(appKit: secondCard, in: second) == CGRect(x: 440, y: 340, width: 588, height: 74),
              "A2: a card on the second display: \(Pair.local(appKit: secondCard, in: second))")
        // A display left of the primary and lower (negative x, AppKit y -300).
        let leftLow = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        check(Pair.local(topLeft: CGRect(x: -1500, y: 800, width: 100, height: 100), in: leftLow, primaryHeight: 1440) == CGRect(x: 420, y: 140, width: 100, height: 100),
              "A2: a display left of and below the primary")

        // B. When it ends.
        typealias End = PermissionDragGuideEnd
        func end(granted: Bool = false, running: Bool = true, missing: TimeInterval = 0, listed: Bool = false, atStart: Bool? = false,
                 title: String? = "Input Monitoring", first: String? = "Input Monitoring") -> End? {
            End.check(granted: granted, settingsRunning: running, windowMissingFor: missing, listedNow: listed, listedAtStart: atStart, title: title, firstTitle: first)
        }
        check(end() == nil, "B: nothing changed: it keeps showing")
        check(end(granted: true) == .granted, "B: Input Monitoring reads allowed: it ends")
        // rc-018 RC3 B4: a row that appears without the permission reading allowed (added off, or an older copy's) never
        // ends it or celebrates: the card says "Turn on …" instead.
        check(end(listed: true) == nil && end(listed: true, atStart: false) == nil, "B: DayDream appears in the list, still off: it keeps going (no celebration)")
        check(end(listed: true, atStart: true) == nil, "B: a DayDream row already listed at the start (an older copy) doesn't end it")
        check(end(listed: true, atStart: nil) == nil, "B: a row seen before the list was known doesn't end it")
        check(end(running: false) == .settingsClosed && end(missing: 1.6) == .settingsClosed && end(missing: 1.0) == nil,
              "B: System Settings quits, or its window is gone 1.5 s: it ends (a moment's miss doesn't)")
        check(end(title: "Accessibility") == .paneChanged && end(title: "Accessibility", first: nil) == nil && end(title: "", first: "Input Monitoring") == nil,
              "B: another pane in System Settings ends it (only once the first pane was known)")
        check(end(granted: true, running: false) == .granted, "B: granted wins")

        // C. The demo.
        typealias Demo = PermissionDemo
        check(Demo.play == 3.2 && Demo.firstPlays == 3 && Demo.period == 6 && Demo.firstDelay == 0.4, "C: 3.2 s plays, 3 back to back, then every 6 s, first after 0.4 s")
        check(Demo.local(0.2) == nil && near(Demo.local(0.5)!, 0.1, 0.001) && near(Demo.local(0.4 + 3.2 + 1)!, 1, 0.001) && near(Demo.local(0.4 + 6.4 + 3)!, 3, 0.001),
              "C: three plays back to back")
        check(Demo.local(0.4 + 9.6 + 4) == nil && near(Demo.local(0.4 + 9.6 + 6 + 1)!, 1, 0.001) && Demo.local(0.4 + 9.6 + 3.3) == nil,
              "C: then one play every 6 s, resting between")
        let f0 = Demo.frame(0.15), grab = Demo.frame(0.45), travel = Demo.frame(1.0), late = Demo.frame(1.75), dropF = Demo.frame(1.95), gone = Demo.frame(2.8)
        check(f0.hand > 0 && !f0.closed && f0.ghost == 0 && f0.progress == 0, "C: 0-0.3 s: the open hand fades in, no card yet")
        check(grab.closed && grab.ghost > 0 && grab.scale > 1 && grab.progress == 0, "C: 0.3-0.5 s: the hand closes, the card lifts where it is")
        check(travel.closed && travel.progress > 0 && travel.progress < 1 && late.progress > travel.progress && near(Demo.frame(1.8).progress, 1, 0.001),
              "C: 0.5-1.8 s: it travels")
        check(dropF.progress == 1 && dropF.scale < 1.03 && dropF.ghost < 0.92 && !dropF.closed, "C: 1.8-2.1 s: the drop: the card shrinks and fades, the hand opens")
        check(gone.hand == 0 && gone.ghost == 0, "C: 2.4-3.2 s: rest, nothing drawn")
        check(near(Demo.ease(0.5), 0.5, 0.001) && Demo.ease(0.1) < 0.1 && Demo.ease(0.9) > 0.9, "C: ease in-out (cubic-bezier .42,0,.58,1)")
        let arcMid = Demo.point(0.5, from: CGPoint(x: 0, y: 500), to: CGPoint(x: 1000, y: 300))
        check(arcMid.y < 400, "C: the card travels on an arc: \(arcMid)")
        let out = ProcessInfo.processInfo.environment["DD_CHECK_OUT"].map { URL(fileURLWithPath: $0).appendingPathComponent("drag-guide-renders") }
        if let out { try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        let ghost = NSImage(size: NSSize(width: 588, height: 74), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); NSColor.systemBlue.setFill(); NSRect(x: 26, y: 15, width: 44, height: 44).fill(); return true }
        let cardRect = CGRect(x: 40, y: 380, width: 588, height: 74), zoneRect = CGRect(x: 700, y: 140, width: 472, height: 140)
        for (name, time, still, mode) in [("grab", 0.45, false, PermissionDragGuideCanvas.Mode.idle), ("travel", 1.15, false, .idle), ("drop", 1.8, false, .idle),
                                          ("rest", 2.8, false, .idle), ("success", 2.8, false, .success), ("reduce-motion", 0.0, true, .idle)] {
            let canvas = PermissionDragGuideCanvas(zone: zoneRect, card: cardRect, drop: CGPoint(x: 772, y: 170), ghost: ghost, reduceMotion: still,
                                                   mode: mode, check: CGPoint(x: 706, y: 170), time: time)
            let host = NSHostingView(rootView: canvas.frame(width: 1200, height: 600))
            host.frame = NSRect(x: 0, y: 0, width: 1200, height: 600)
            host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            // No ring (owner 10/8): the same moment drawn without the card (so no image or hand crosses it) puts nothing on
            // the zone's edges. (The old ring's stroke was at least 55% opaque; the success check at (706, 170) is left out.)
            let bareHost = NSHostingView(rootView: PermissionDragGuideCanvas(zone: zoneRect, card: .zero, drop: CGPoint(x: 772, y: 170), ghost: ghost,
                                                                             reduceMotion: still, mode: mode, check: CGPoint(x: 706, y: 170), time: time)
                                                    .frame(width: 1200, height: 600))
            bareHost.frame = NSRect(x: 0, y: 0, width: 1200, height: 600)
            bareHost.layoutSubtreeIfNeeded()
            let bare = bareHost.bitmapImageRepForCachingDisplay(in: bareHost.bounds)!
            bareHost.cacheDisplay(in: bareHost.bounds, to: bare)
            func edge(_ x: Int, _ y: Int) -> Bool { hypot(CGFloat(x - 706), CGFloat(y - 170)) > 16 && (bare.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 }
            var ringDrawn = false
            for x in stride(from: 701, to: 1171, by: 2) where [141, 142, 278, 279].contains(where: { edge(x, $0) }) { ringDrawn = true; break }
            for y in stride(from: 150, to: 270, by: 2) where [701, 702, 1170, 1171].contains(where: { edge($0, y) }) { ringDrawn = true; break }
            check(!ringDrawn, "C: the \(name) render draws no ring around the list")
            if name == "grab" {
                // The card's image over the card (no pill chip): its blue square at the card's icon.
                let px = rep.colorAt(x: 40 + 48, y: 380 + 37 - 6)
                check((px?.alphaComponent ?? 0) > 0.3, "C: the \(name) render draws the card's image over the card")
            }
            if name == "success" {
                let px = rep.colorAt(x: 706, y: 170)
                check((px?.alphaComponent ?? 0) > 0.3, "C: the success render draws the green check")
            }
            if name == "rest" {
                var any = false
                for y in stride(from: 0, to: 600, by: 4) { for x in stride(from: 0, to: 1200, by: 4) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { any = true; break }; if any { break } }
                check(!any, "C: resting between plays the overlay is empty (no ring)")
            }
            if name == "reduce-motion" {
                // No second copy of the card over the real one: the card's middle stays clear.
                let px = rep.colorAt(x: 40 + 400, y: 380 + 37)
                check((px?.alphaComponent ?? 1) < 0.05, "C: Reduce Motion draws no still copy of the card over the card")
            }
            if let out { try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("guide-\(name).png")) }
        }

        // C3. The live path (TimelineView, as the overlay draws it), mid-grab: the card's image and the hand are on the
        // card, not a slice of the screen lower (owner 10/7: "the animation is way below").
        do {
            let liveCard = CGRect(x: 100, y: 700, width: 588, height: 74), liveZone = CGRect(x: 900, y: 300, width: 472, height: 140)
            let canvas = PermissionDragGuideCanvas(zone: liveZone, card: liveCard, drop: CGPoint(x: 972, y: 330), ghost: ghost, reduceMotion: false,
                                                   demoStart: Date().addingTimeInterval(-(Demo.firstDelay + 0.48)))
            let window = OffscreenWindow(contentRect: NSRect(x: -9000, y: -9000, width: 1440, height: 1200), styleMask: [.borderless], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: canvas)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            let sx = CGFloat(rep.pixelsWide) / 1440, sy = CGFloat(rep.pixelsHigh) / 1200
            func blue(_ x: CGFloat, _ y: CGFloat) -> Bool {
                guard let c = rep.colorAt(x: Int(x * sx), y: Int(y * sy))?.usingColorSpace(.sRGB) else { return false }
                return c.alphaComponent > 0.3 && c.blueComponent > c.redComponent + 0.3
            }
            // The image's blue square (26..70, 15..59 in the card) is within 40 pt of the card (it may have started to
            // travel by the time this draws); nothing of it 400 pt lower, where TimelineView's stack put it.
            func blueNear(_ r: CGRect) -> Bool {
                for y in stride(from: r.minY, to: r.maxY, by: 3) { for x in stride(from: r.minX, to: r.maxX, by: 3) where blue(x, y) { return true } }
                return false
            }
            let onCard = blueNear(liveCard.insetBy(dx: -40, dy: -40)), below = blueNear(liveCard.insetBy(dx: -40, dy: -40).offsetBy(dx: 0, dy: 400))
            var ringTop = false
            for x in stride(from: 910, to: 1360, by: 3) where (rep.colorAt(x: Int(CGFloat(x) * sx), y: Int(301 * sy))?.alphaComponent ?? 0) > 0.3 { ringTop = true; break }
            check(onCard && !below && !ringTop, "C3: live (TimelineView) mid-grab: the card's image is on the card (\(onCard)), not below it (\(below)); no ring (\(ringTop))")
            if let out { try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("guide-live-grab.png")) }
        }

        // C2. The demo lands inside the list's zone; Reduce Motion's arrow ends outside it.
        for (zoneR, cardS, dropP) in [(zoneRect, cardRect.size, CGPoint(x: 772, y: 170)),
                                      (CGRect(x: 1863, y: 301, width: 472, height: 139), CGSize(width: 588, height: 74), CGPoint(x: 1941, y: 328)),
                                      (CGRect(x: 1863, y: 301, width: 300, height: 70), CGSize(width: 588, height: 74), CGPoint(x: 1890, y: 300))] {
            let land = Pair.landing(card: cardS, zone: zoneR, drop: dropP)
            let atDrop = Pair.ghostRect(card: cardS, held: Demo.point(1, from: CGPoint(x: 100, y: 400), to: land.point), scale: land.scale * CGFloat(Demo.frame(1.8).scale))
            check(land.scale < 1 && zoneR.contains(atDrop) && atDrop.minY >= zoneR.minY,
                  "C: at progress 1 the card's image lies inside the list's zone (\(atDrop) in \(zoneR))")
            let dropping = Pair.ghostRect(card: cardS, held: land.point, scale: land.scale * CGFloat(Demo.frame(1.95).scale))
            check(zoneR.contains(dropping), "C: while it drops the image stays inside the list's zone")
            let card = zoneR.minX > 1000 ? CGRect(x: 986, y: 420, width: 588, height: 74) : cardRect
            let arrow = Pair.stillArrow(card: card, zone: zoneR, drop: dropP)
            check(arrow.to.x <= zoneR.minX && arrow.from.x >= card.maxX && arrow.control.y >= (arrow.from.y + arrow.to.y) / 2,
                  "C: Reduce Motion's arrow runs from beside the card to just outside the list, bowing down")
        }
        let leftArrow = Pair.stillArrow(card: CGRect(x: 1700, y: 420, width: 588, height: 74), zone: CGRect(x: 300, y: 300, width: 460, height: 130), drop: CGPoint(x: 380, y: 330))
        check(leftArrow.to.x >= 760 && leftArrow.from.x <= 1700, "C: with System Settings on setup's left the arrow runs left, ending outside the list")

        // D. Source rules.
        let guide = (try? String(contentsOfFile: "Sources/MemoryUI/PermissionDragGuide.swift", encoding: .utf8)) ?? ""
        let setupSource = (try? String(contentsOfFile: "Sources/MemoryUI/PermissionSetup.swift", encoding: .utf8)) ?? ""
        let onboarding = (try? String(contentsOfFile: "Sources/MacMemApp/DaydreamOnboarding.swift", encoding: .utf8)) ?? ""
        let settingsPage = (try? String(contentsOfFile: "Sources/MacMemApp/DaydreamSettings.swift", encoding: .utf8)) ?? ""
        check(!guide.isEmpty && !setupSource.isEmpty && !onboarding.isEmpty, "D: the sources are readable from the repo root")
        let banned = ["AXIsProcessTrustedWithOptions", "CGRequestListenEventAccess", "kAXTrustedCheckOptionPrompt", "CGRequestPostEventAccess", "IOHIDRequestAccess"]
        check(!banned.contains(where: guide.contains) && !banned.contains(where: setupSource.contains), "D: the helper calls no permission request API (reads only)")
        check(guide.components(separatedBy: "AXUIElementSetAttributeValue(").count - 1 == 3
              && guide.components(separatedBy: "SettingsWindowAX.setFrame(").count - 1 == 2
              && !guide.contains("CGEvent(") && !guide.contains("CGEventPost") && !guide.contains("AXUIElementPerformAction"),
              "D: System Settings is written only by setFrame's 3 writes (placement and the one redo); no clicks or events")
        check(!guide.contains("moveOwnWindowLeft") && !guide.contains("halves(of"), "D: nothing moves before System Settings exists (no left/right halves)")
        check(guide.contains("panel.ignoresMouseEvents = true") && guide.contains("NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)")
              && guide.contains("panel.hidesOnDeactivate = false") && guide.contains("[.borderless, .nonactivatingPanel]"),
              "D: the overlay is borderless, click-through and above DayDream's floating window")
        check(PermissionDragGuide.overlayLevel.rawValue > NSWindow.Level.floating.rawValue, "D: the overlay's level is above floating")
        let canvasSource = guide.components(separatedBy: "public struct PermissionDragGuideCanvas").last ?? ""
        check(!canvasSource.contains("Text(") && !guide.contains("dropLabel") && !guide.contains("Drop DayDream here"), "D: the overlay has no words (no drop label)")
        check(!guide.contains("Toggle(") && !guide.contains(".toggleStyle") && !guide.contains("Turn this on") && !guide.lowercased().contains("switch animation"),
              "D: no fake switch and no \"Turn this on\" tip")
        check(guide.contains("NSCursor.closedHand") && guide.contains("NSCursor.openHand") && guide.contains("bitmapImageRepForCachingDisplay")
              && guide.contains("cacheDisplay(in: rect, to: rep)"), "D: the demo uses the system grab hands and an image of the real card")
        check(guide.contains("accessibilityDisplayShouldReduceMotion") && guide.contains("if reduceMotion { still }") && guide.contains(".easeInOut(duration: 0.15)")
              && guide.contains("if model.reduceMotion { own.setFrame(target, display: true); return }"),
              "D: Reduce Motion draws a still hand and arc; state changes crossfade; setup's window jumps instead of sliding")
        check(guide.contains("RunLoop.main.add(timer, forMode: .common)") && !guide.contains("Timer.scheduledTimer("),
              "D: its timers run in the common modes, so they keep firing during the real drag (event tracking)")
        check(guide.contains("hypot(pointer.x - at.x, pointer.y - at.y) > 4") && setupSource.contains("PermissionDragGuide.noteGrab()")
              && !setupSource.contains("if guides { PermissionDragGuide.noteGrab() }") && setupSource.contains("guides: permission == guidePermission"),
              "D: a click on the card is no grab (4 pt of movement is); either card's drag hides the demo as it begins (rc-018 RC3 B6)")
        check(setupSource.contains("guideLine: permission == guidePermission && guideLine)") && setupSource.contains("guard permission == guidePermission, guideLine, guideStatus.placed else { return nil }")
              && setupSource.contains("case .guideLine:")
              && setupSource.contains("forAccessibility: permission == .accessibility") && !setupSource.contains("guard permission == .inputMonitoring else { PermissionDragGuide.shared.stop"),
              "D: both cards start it (owner 10/7); while it runs its card says the line and has no Open System Settings button")
        check(guide.contains("return ZStack(alignment: .topLeading) {\n            if card.width > 0, f.ghost > 0")
              && guide.contains("PermissionPair.local(topLeft: demo, in: box, primaryHeight: top)") && guide.contains("NSScreen.screens.first?.frame.maxY")
              && !guide.contains("let origin = CGPoint(x: screen.frame.minX"),
              "D: the demo's layers share one ZStack (not TimelineView's stack); rects go into the overlay's own frame on the primary screen's top")
        check(guide.contains("#if DEBUG || DAYDREAM_LIVETEST\n    static let log = Logger(") && guide.contains("privacy: .public")
              && guide.contains("endInList=\\(list.insetBy(dx: -1, dy: -1).contains(end))") && !guide.contains("endInRing"),
              "D: the layout log is in test builds only (rects and points, no names); it reports endInList")
        check(!guide.contains("ringView") && !guide.contains("strokeBorder") && !guide.contains("case idle, hot") && !guide.contains("heat")
              && !guide.contains("setMode(") && !guide.contains("PermissionPair.ring("),
              "D: no ring anywhere (owner 10/8: \"Just get rid of the blue ring\"): no ring view, no hot mode, no heat")
        check(guide.contains("SettingsWindowAX.server(window: id)") && guide.contains("CGWindowListCopyWindowInfo(.optionIncludingWindow, id)"),
              "D: the 60 Hz reads look at System Settings' one window; the full window list only at 4 Hz")
        check(guide.contains("AXUIElementSetMessagingTimeout(element, 0.3)") && guide.contains("emptyScope"),
              "D: the list scan stops at \"No Items\", rescans only its container and never waits more than 0.3 s a call")
        check(guide.contains("paneSettled") && guide.contains("titleAtStart"),
              "D: the pane's title and the row at the start are taken only once the pane settled (System Settings already open elsewhere)")
        check(guide.contains("SettingsWindowAX.server(") && guide.contains("Self.windowWait") && guide.contains("PermissionPair.took("),
              "D: frames are read back from the window server, after a bounded wait")
        check(guide.contains("if trusted { settingsWindow = SettingsWindowAX.window(pid: pid) }") && guide.contains("moveSetup(nextTo: actual)"),
              "D: without Accessibility System Settings is left alone and setup moves next to it")
        check(guide.contains("if Date() > until || (moved && buttonDown) { watchUntil = nil; return }"), "D: never fights the person: a moved System Settings isn't written again")
        check(guide.contains("authOnScreen || settingsWindow.map(SettingsWindowAX.hasSheet) == true"), "D: hidden (not ended) while an authentication sheet is up")
        check(guide.contains("if end == .granted { celebrate(end, row: rowFrame) } else { stop(end) }") && !guide.contains("end == .listed ||"),
              "D: the check appears only once the permission reads allowed (a listed row alone is \"Turn on …\", rc-018 RC3 B4)")
        check(PermissionDragGuideText.cardLine == "Drag this card into the list.", "D: the card's one line")
        check(!PermissionDragGuideText.cardLine.lowercased().contains("draft"), "D: no \"draft\" in what it says")
        check(setupSource.contains("if guided { startGuide(permission, window: pressed) }") && setupSource.contains("PermissionDragGuide.shared.stop(.left)")
              && setupSource.contains("Text(line.text(appName: appName))") && setupSource.contains("guideStatus.running")
              && setupSource.contains("guard permission == guidePermission, guideLine, guideStatus.placed else { return nil }")
              && setupSource.contains("PermissionDragGuide.noteGrab()"),
              "D: the card starts it, says its line only while it runs and once placed (rc-018 RC3 B5); the page's disappearance ends it")
        let screens = (try? String(contentsOfFile: "Sources/MemoryUI/OnboardingScreens.swift", encoding: .utf8)) ?? ""
        check(onboarding.contains("sideBySide: true") && !settingsPage.contains("sideBySide: true") && !settingsPage.contains("guided: true")
              && screens.contains("known: known, allowedBefore: allowedBefore, guided: true)"),
              "D: setup and the small permissions window turn it on (rc-018 RC3 B9); Settings' sheet doesn't")

        // E. Live without System Settings: a granted read ends it before anything is looked for.
        let guideObject = PermissionDragGuide.shared
        guideObject.start(window: nil, appURL: URL(fileURLWithPath: "/Applications/DayDream.app"), appName: "DayDream", source: { nil },
                          reads: PermissionDragGuide.Reads(accessibility: { false }, inputMonitoring: { true }, reduceMotion: { false }))
        check(guideObject.active && PermissionDragGuideStatus.shared.running, "E: it starts (the card's line shows)")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        check(!guideObject.active && guideObject.lastEnd == .granted && !guideObject.movedSettings && guideObject.settingsWrites == 0
              && !PermissionDragGuideStatus.shared.running, "E: a granted read ends it and moves nothing")
        guideObject.grabbed()
        guideObject.stop(.left)
        check(guideObject.lastEnd == .granted, "E: a grab or a stop afterwards changes nothing")
        // The Accessibility card's run ends on Accessibility's read (Input Monitoring still off), moving nothing.
        guideObject.start(window: nil, appURL: URL(fileURLWithPath: "/Applications/DayDream.app"), appName: "DayDream", source: { nil },
                          reads: PermissionDragGuide.Reads(accessibility: { true }, inputMonitoring: { false }, reduceMotion: { false }), forAccessibility: true)
        check(guideObject.active && guideObject.forAccessibility && PermissionDragGuideStatus.shared.forAccessibility, "E: the Accessibility card starts it for its own card")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        check(!guideObject.active && guideObject.lastEnd == .granted && guideObject.settingsWrites == 0,
              "E: an Accessibility read of allowed ends the Accessibility run and moves nothing")

        // F. The card's drag (owner's Mac mini 10/8: every drag left a 191 MB copy of the app in
        // ~/Library/Caches/com.apple.SwiftUI.Drag-<UUID>/, and System Settings registered that copy, not the installed app).
        // The pasteboard carries the installed app's URL itself; no file representation, no file promise, no copy.
        let realHome = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        func dragCopies() -> Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: realHome.appendingPathComponent("Library/Caches").path)) ?? [])
                .filter { $0.hasPrefix("com.apple.SwiftUI.Drag-") }.count
        }
        let copiesBefore = dragCopies()
        let installed = URL(fileURLWithPath: "/Users/someone/Applications/DayDream Live Test.app")
        let writer = PermissionDragPayload.writer(appURL: installed, enabled: true)
        check(writer as URL? == installed && PermissionDragPayload.writer(appURL: installed, enabled: false) == nil
              && PermissionDragPayload.writer(appURL: URL(fileURLWithPath: "/tmp/build/debug/MacMem"), enabled: true) == nil,
              "F: the payload is the app bundle's own URL (an NSURL reference), none from the download window or for a bare binary")
        let board = NSPasteboard(name: NSPasteboard.Name("daydream-drag-payload-checks-\(getpid())"))
        board.clearContents()
        let wrote = writer.map { board.writeObjects([$0]) } ?? false
        let types = board.types?.map(\.rawValue) ?? []
        check(wrote && types.contains("public.file-url") && board.string(forType: .fileURL).flatMap(URL.init(string:)) == installed
              && !types.contains { $0.localizedCaseInsensitiveContains("promise") } && !types.contains("com.apple.application-bundle")
              && !types.contains("public.data"),
              "F: on the pasteboard the drag is the URL itself (public.file-url = the installed path), no file promise or file data: \(types)")
        board.releaseGlobally()
        let anchorWindow = OffscreenWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80)); anchorWindow.contentView = anchor
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: anchorWindow.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        check(!PermissionCardDrag.shared.begin(appURL: installed, enabled: true, guides: false, anchor: anchor, event: down)
              && !PermissionCardDrag.shared.begin(appURL: installed, enabled: true, guides: false, anchor: nil, event: nil)
              && !PermissionCardDrag.shared.begin(appURL: installed, enabled: false, guides: false, anchor: anchor, event: down)
              && !PermissionCardDrag.shared.dragging,
              "F: a drag starts only from a real mouse drag on the card (a click, no card or the download window start none)")
        check(dragCopies() == copiesBefore, "F: no new ~/Library/Caches/com.apple.SwiftUI.Drag-* folder (\(copiesBefore) before and after)")
        check(!setupSource.contains(".onDrag") && !setupSource.contains("NSItemProvider") && !setupSource.contains("NSFilePromiseProvider")
              && !setupSource.contains("registerFileRepresentation") && setupSource.contains("NSDraggingItem(pasteboardWriter: writer)")
              && setupSource.contains("return appURL as NSURL") && setupSource.contains("appURL: URL = Bundle.main.bundleURL")
              && setupSource.contains("PermissionCardDrag.shared.begin(appURL: appURL, enabled: draggable"),
              "F: sources: the card drags Bundle.main.bundleURL through AppKit (NSDraggingItem of the NSURL); no SwiftUI onDrag, item provider or file promise")

        // G. Reads into what the card shows (owner's Mac mini 10/8: Accessibility granted, the card didn't flip). A read of
        // allowed shows Allowed on that same tick, from a first setup or an earlier Allowed, with the helper running.
        for allowedBefore in [false, true] {
            var shownReads = ShownPermissions(known: PermissionSnapshot(), allowedBefore: allowedBefore)
            var axOn = false
            guideObject.start(window: nil, appURL: URL(fileURLWithPath: "/Applications/DayDream.app"), appName: "DayDream", source: { nil },
                              reads: PermissionDragGuide.Reads(accessibility: { axOn }, inputMonitoring: { false }, reduceMotion: { false }), forAccessibility: true)
            let t0 = Date()
            var trail: [PermissionCardTrailing] = []
            for (tick, on) in [false, false, true, true].enumerated() {
                axOn = on
                let now = t0.addingTimeInterval(Double(tick) * 2)  // the page's 2 s timer
                let shownAx = shownReads.read(PermissionSnapshot(accessibility: on, inputMonitoring: false), at: now).accessibility
                let running = PermissionDragGuideStatus.shared.running
                let allowed = shownAx == true
                // The view's guideLine: sideBySide, enabled, no move warning, pane opened, the helper running, not allowed.
                trail.append(PermissionCardTrailing.of(enabled: true, read: true, known: shownAx != nil, allowed: allowed,
                                                       guideLine: running && !allowed))
                if tick == 2 { check(running, "G: the helper is still running on the tick the allowed read arrives (allowedBefore \(allowedBefore))") }
            }
            let expected: [PermissionCardTrailing] = allowedBefore ? [.nothingYet, .guideLine, .allowed, .allowed] : [.guideLine, .guideLine, .allowed, .allowed]
            check(trail == expected, "G: reads false, false, true, true show \(expected) with the helper running (allowedBefore \(allowedBefore)): \(trail)")
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            check(!guideObject.active && guideObject.lastEnd == .granted, "G: the helper then ends on the same allowed read")
        }
        check(PermissionCardTrailing.of(enabled: true, read: true, known: true, allowed: true, guideLine: true) == .allowed
              && PermissionCardTrailing.of(enabled: true, read: true, known: true, allowed: false, guideLine: true) == .guideLine
              && PermissionCardTrailing.of(enabled: true, read: true, known: true, allowed: false, guideLine: false) == .openButton,
              "G: Allowed wins over the helper's line; a missing card shows the line while it runs, else its button")
        var settled = ShownPermissions(known: PermissionSnapshot(accessibility: false, inputMonitoring: false), allowedBefore: true)
        let s0 = Date()
        _ = settled.read(PermissionSnapshot(accessibility: false, inputMonitoring: false), at: s0)
        let flipped = settled.read(PermissionSnapshot(accessibility: true, inputMonitoring: true), at: s0.addingTimeInterval(0.01))
        check(flipped.accessibility == true && flipped.inputMonitoring == true, "G: an off card turns Allowed on the very next read (no settle on the way on)")
        check(setupSource.contains("PermissionDragGuideLog.permRead(\"perm-read ax=") && guide.contains("category: \"perm-read\"")
              && guide.contains("static func permRead(") && guide.components(separatedBy: "static func permRead(").last!.contains("#if DEBUG || DAYDREAM_LIVETEST"),
              "G: test builds log each read and what the cards show (perm-read, booleans only)")

        // H. The first press. Setup opens System Settings beside it, so the person reaches for the card while DayDream's
        // window is inactive; SwiftUI's hosting view doesn't take that first click (acceptsFirstMouse is false), so the
        // card's DragGesture never saw it and only a second press dragged. `PermissionCardPress` (a local monitor) starts
        // the drag from the first press. Synthetic events go through NSApp.sendEvent, as real ones do; AppKit's session is
        // stood in for (`sessionForChecks`), so nothing is dragged on this Mac.
        func pressViews(_ view: NSView) -> [PermissionCardPressView] {
            ((view as? PermissionCardPressView).map { [$0] } ?? []) + view.subviews.flatMap(pressViews)
        }
        // Off screen, ordered in (never key: this process can't be active). rc-018 RC3: an `OffscreenWindow`, so AppKit
        // never pulls it onto the screen (a plain titled NSWindow at -4000 showed up on the owner's screen).
        func hostInWindow<V: View>(_ root: V, size: NSSize) -> (NSWindow, NSView) {
            let w = OffscreenWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height), styleMask: [.titled],
                                    backing: .buffered, defer: false)
            let h = NSHostingView(rootView: root)
            w.contentView = h; h.frame = NSRect(origin: .zero, size: size)
            w.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2)); h.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            return (w, h)
        }
        var started: [(NSView, NSEvent.EventType)] = []
        PermissionCardDrag.shared.sessionForChecks = { view, event in started.append((view, event.type)) }
        let page = PermissionGrantView(appURL: installed, readAccessibility: { false }, readInputMonitoring: { false }, embedded: true,
                                       style: .settings, known: PermissionSnapshot(accessibility: false, inputMonitoring: false))
            .padding(20).frame(width: 600, height: 420, alignment: .top)
        let (pageWindow, pageHost) = hostInWindow(page, size: NSSize(width: 600, height: 420))
        let views = pressViews(pageHost)
        let cards = views.filter { !$0.keepOut }, buttons = views.filter(\.keepOut)
        check(cards.count == 2 && buttons.count == 2 && cards.allSatisfy { $0.enabled && $0.appURL == installed && $0.window === pageWindow }
              && PermissionCardPress.shared.watching,
              "H: each card has its press view (the installed app, draggable) and each Open System Settings button its room; the monitor is on: \(cards.count) cards, \(buttons.count) buttons")
        check(!pageWindow.isKeyWindow && !NSApp.isActive, "H: the page's window is not key and DayDream is not active (System Settings in front)")
        check(pageWindow.frame.minX <= -3000 && pageWindow.frame.minY <= -3000 && !NSScreen.screens.contains { $0.frame.intersects(pageWindow.frame) },
              "H: the page's window stayed off every screen once ordered in (an OffscreenWindow): \(pageWindow.frame)")
        func event(_ type: NSEvent.EventType, _ p: NSPoint, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow = pageWindow) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        /// Sends each event as AppKit does (NSApp.sendEvent: the local monitors, then the window).
        func send(_ events: [NSEvent]) { for e in events { NSApp.sendEvent(e) } }
        if cards.count == 2, buttons.count == 2 {
            let card = cards[0]
            // A point on the card left of its title (its icon), in the window.
            let p = card.convert(NSPoint(x: card.bounds.minX + 30, y: card.bounds.midY), to: nil)
            check(!buttons.contains { $0.convert($0.bounds, to: nil).contains(p) }, "H: the press point is on the card, not on its button")
            let sessionsBefore = PermissionCardDrag.shared.sessions
            send([event(.leftMouseDown, p), event(.leftMouseDragged, NSPoint(x: p.x + 2, y: p.y))])
            check(started.isEmpty && !PermissionCardDrag.shared.dragging, "H: a press that moved 2 pt is still a click: no drag yet")
            send([event(.leftMouseDragged, NSPoint(x: p.x + 6, y: p.y))])
            check(started.count == 1 && started.first?.0 === card && started.first?.1 == .leftMouseDragged && PermissionCardDrag.shared.dragging,
                  "H: the FIRST press, moved 6 pt, starts the drag from that card with the mouse-dragged event, the window still not key")
            send([event(.leftMouseDragged, NSPoint(x: p.x + 14, y: p.y + 3)), event(.leftMouseDragged, NSPoint(x: p.x + 40, y: p.y + 9))])
            let swiftUIPath = PermissionCardDrag.shared.begin(appURL: installed, enabled: true, guides: false, anchor: card,
                                                              event: event(.leftMouseDragged, NSPoint(x: p.x + 41, y: p.y + 9)))
            send([event(.leftMouseUp, NSPoint(x: p.x + 41, y: p.y + 9))])
            check(started.count == 1 && PermissionCardDrag.shared.sessions == sessionsBefore + 1 && !swiftUIPath,
                  "H: exactly one session: more movement, and the card's DragGesture path while it runs, start no second one")
            PermissionCardDrag.shared.endForChecks(); started = []
            // The monitor hands every event on unchanged (SwiftUI still sees each one).
            let pressEvents = [event(.leftMouseDown, p), event(.leftMouseDragged, NSPoint(x: p.x + 6, y: p.y)), event(.leftMouseUp, NSPoint(x: p.x + 6, y: p.y))]
            check(pressEvents.allSatisfy { PermissionCardPress.shared.handle($0) === $0 } && started.count == 1,
                  "H: every event of a press goes on unchanged, the drag's too")
            PermissionCardDrag.shared.endForChecks(); started = []
            // A plain click on the card: no drag.
            let click = [event(.leftMouseDown, p), event(.leftMouseUp, p)]
            check(click.allSatisfy { PermissionCardPress.shared.handle($0) === $0 } && started.isEmpty, "H: a click on the card (no movement) starts no drag and goes on unchanged")
            send(click)
            check(started.isEmpty, "H: …sent through AppKit too")
            // A press on the Open System Settings button that moves: the button's, never a drag.
            let b = buttons[0].convert(NSPoint(x: buttons[0].bounds.midX, y: buttons[0].bounds.midY), to: nil)
            let onButton = PermissionCardPress.shared.handle(event(.leftMouseDown, b))
            _ = PermissionCardPress.shared.handle(event(.leftMouseDragged, NSPoint(x: b.x + 10, y: b.y)))
            _ = PermissionCardPress.shared.handle(event(.leftMouseUp, NSPoint(x: b.x + 10, y: b.y)))
            check(started.isEmpty && onButton.type == .leftMouseDown, "H: a press on the card's button that moves 10 pt stays the button's: no drag")
            // A Control-press is the context menu's.
            send([event(.leftMouseDown, p, .control), event(.leftMouseDragged, NSPoint(x: p.x + 10, y: p.y), .control),
                  event(.leftMouseUp, NSPoint(x: p.x + 10, y: p.y), .control)])
            check(started.isEmpty, "H: a Control-press (the context menu) starts no drag")
            // A card that can't drag (the download window, a preview).
            card.enabled = false
            send([event(.leftMouseDown, p), event(.leftMouseDragged, NSPoint(x: p.x + 10, y: p.y)), event(.leftMouseUp, NSPoint(x: p.x + 10, y: p.y))])
            card.enabled = true
            check(started.isEmpty, "H: a card that can't drag starts no drag")
            // A press in another window, then a drag: none.
            let other = OffscreenWindow(contentRect: NSRect(x: -4000, y: -3000, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
            send([event(.leftMouseDown, p, in: other), event(.leftMouseDragged, NSPoint(x: p.x + 10, y: p.y), in: other)])
            check(started.isEmpty, "H: a press in another window starts no drag")
            _ = PermissionCardPress.shared.handle(event(.leftMouseUp, p, in: other))
            // The second card drags on its own first press too.
            let p2 = cards[1].convert(NSPoint(x: cards[1].bounds.minX + 30, y: cards[1].bounds.midY), to: nil)
            send([event(.leftMouseDown, p2), event(.leftMouseDragged, NSPoint(x: p2.x, y: p2.y - 5)), event(.leftMouseUp, NSPoint(x: p2.x, y: p2.y - 5))])
            check(started.count == 1 && started.first?.0 === cards[1], "H: the other card's first press drags it (its own view)")
            PermissionCardDrag.shared.endForChecks(); started = []
        }
        pageWindow.contentView = nil; pageWindow.orderOut(nil)
        // A button on a card still answers its click with the monitor on (the page's own button opens System Settings,
        // which a check never does: this card is built the same way, a press view behind it and a room on its button).
        struct PressView: NSViewRepresentable {
            let keepOut: Bool
            func makeNSView(context: Context) -> PermissionCardPressView {
                let v = PermissionCardPressView(); v.keepOut = keepOut; v.enabled = !keepOut
                v.appURL = URL(fileURLWithPath: "/Users/someone/Applications/DayDream Live Test.app"); return v
            }
            func updateNSView(_ view: PermissionCardPressView, context: Context) {}
        }
        var taps = 0
        let mirror = HStack { Color.gray.frame(width: 120, height: 60); Button("Open") { taps += 1 }.background(PressView(keepOut: true)) }
            .frame(width: 300, height: 80).background(PressView(keepOut: false))
        let (mirrorWindow, mirrorHost) = hostInWindow(mirror, size: NSSize(width: 300, height: 80))
        if let room = pressViews(mirrorHost).first(where: \.keepOut) {
            let b = room.convert(NSPoint(x: room.bounds.midX, y: room.bounds.midY), to: nil)
            NSApp.postEvent(event(.leftMouseUp, b, in: mirrorWindow), atStart: false)
            NSApp.sendEvent(event(.leftMouseDown, b, in: mirrorWindow))
            if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(queued) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            check(taps == 1 && started.isEmpty, "H: a click on a card's button still fires it (once), with the monitor on, and drags nothing: \(taps)")
        } else { check(false, "H: the mirror card's button has its room") }
        mirrorWindow.contentView = nil; mirrorWindow.orderOut(nil)
        PermissionCardDrag.shared.sessionForChecks = nil
        check(dragCopies() == copiesBefore, "H: still no new ~/Library/Caches/com.apple.SwiftUI.Drag-* folder")
        check(setupSource.contains("monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp])")
              && setupSource.contains(".background(PermissionCardAnchor(box: cardAnchors[permission]!, appURL: appURL, enabled: drags, guides: permission == guidePermission,")
              && setupSource.contains(".buttonStyle(PermissionButtonStyle(prominent: true)).disabled(!draggable)\n                        .background(PermissionCardKeepOut())")
              && setupSource.contains("PermissionCardDrag.shared.begin(appURL: card.appURL, enabled: card.enabled, guides: card.guides, anchor: card, event: event,")
              && setupSource.contains("guard !dragging, let writer"),
              "H: sources: every card (setup, the permissions window, Settings) has the press view; its button has its room; one `dragging` guard for both paths")
        check(setupSource.contains("let pressed = cardAnchors[permission]?.view?.window ?? NSApp.keyWindow"),
              "H: Open System Settings floats and side-by-sides the page's own window, key or not (a context-menu press on an inactive window)")

        // I. rc-018 RC3 (owner 10/9, Mac mini: "after restart had to click the connect the chrome button twice"). Setup's
        // real page (the shell, the cards and the Chrome row) in a window that is not key, DayDream not active. A click on
        // Allow that brings DayDream to the front also starts a read of Chrome's access (didBecomeActive: the app's
        // `checkChromeAccess` sets .checking); the row drew a spinner in place of Allow between the press and its release,
        // so that click did nothing. The row now keeps its last settled state through a read (`duringRead`, what the
        // app's `chromeRowAccess` draws); only a question in flight shows the spinner. One click acts exactly once.
        final class RowState: ObservableObject {
            @Published var current: ChromeAccessState = .notAsked
            var shown: ChromeAccessState = .notAsked
            var questionInFlight = false
        }
        struct SetupPage: View {
            @ObservedObject var state: RowState
            let appURL: URL
            let allow: () -> Void, next: () -> Void, back: () -> Void
            let frames: (([String: CGRect]) -> Void)
            var body: some View {
                // What the app model's `chromeRowAccess` draws (`PermissionChromeRow.duringRead`).
                let access = PermissionChromeRow.duringRead(current: state.current, shown: state.shown, questionInFlight: state.questionInFlight)
                DaydreamOnboardingShell(title: "Allow DayDream", back: back, continueAction: next) {
                    PermissionGrantView(appURL: appURL, readAccessibility: { true }, readInputMonitoring: { true }, embedded: true,
                                        showsRelaunchRow: false, known: PermissionSnapshot(accessibility: true, inputMonitoring: true),
                                        chromeRow: PermissionChromeRow(icon: nil, access: access, asked: false, allow: allow, openSettings: {}),
                                        sideBySide: true)
                }
                .onPreferenceChange(PermissionPageElements.self) { frames($0) }
            }
        }
        var allows = 0, nexts = 0, backs = 0, activations = 0
        var frames: [String: CGRect] = [:]
        let rowState = RowState()
        let setupPage = SetupPage(state: rowState, appURL: installed, allow: { allows += 1 }, next: { nexts += 1 }, back: { backs += 1 },
                                  frames: { frames = $0 })
        let (setupWindow, setupHost) = hostInWindow(setupPage, size: NSSize(width: 660, height: 600))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        // DayDream coming to the front, as the app answers it: setup's `rereadChrome` and the model's observer start a
        // read of Chrome's access (`checkChromeAccess`: .checking) on the main thread.
        let becameActive = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { activations += 1; rowState.current = .checking }
        }
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint, in window: NSWindow) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        /// One click as AppKit delivers it: the press through NSApp.sendEvent (the local monitors, then the window, which
        /// asks the view under it whether the click that makes the window key may act), then the release.
        func click(_ p: NSPoint, in window: NSWindow, betweenPressAndRelease: () -> Void = {}) {
            NSApp.sendEvent(mouse(.leftMouseDown, p, in: window))
            betweenPressAndRelease()
            NSApp.sendEvent(mouse(.leftMouseUp, p, in: window))
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        func takesFirstClick(_ p: NSPoint, in host: NSView, _ window: NSWindow) -> Bool {
            host.hitTest(p).map { $0.acceptsFirstMouse(for: mouse(.leftMouseDown, p, in: window)) } == true
        }
        /// A point on a drawn element where a click reaches its control, nearest its center, in the window's base
        /// coordinates (`.global` frames: the whole window, title bar included, from its top-left corner).
        func target(_ key: String, in host: NSView, _ window: NSWindow) -> NSPoint? {
            guard let f = frames[key] else { return nil }
            let r = NSRect(x: f.minX, y: window.frame.height - f.maxY, width: f.width, height: f.height).insetBy(dx: 2, dy: 2)
            let points = stride(from: r.minY, through: r.maxY, by: 2).flatMap { y in stride(from: r.minX, through: r.maxX, by: 2).map { NSPoint(x: $0, y: y) } }
            return points.sorted { hypot($0.x - r.midX, $0.y - r.midY) < hypot($1.x - r.midX, $1.y - r.midY) }.first { takesFirstClick($0, in: host, window) }
        }
        /// The first point along the bottom bar (y = 48: the shell's 36 pt buttons, 30 pt above its bottom edge) where a
        /// control takes the activating click, from the left (Back) or the right (Continue, Done).
        func barButton(in host: NSView, window: NSWindow, fromRight: Bool) -> NSPoint? {
            let xs = Array(stride(from: 20.0, through: 640.0, by: 4.0))
            return (fromRight ? xs.reversed() : xs).lazy.map { NSPoint(x: $0, y: 48) }.first { takesFirstClick($0, in: host, window) }
        }
        check(!setupWindow.isKeyWindow && !NSApp.isActive, "I: setup's window is not key and DayDream is not active (System Settings in front)")
        if let allowAt = target("allow.chrome", in: setupHost, setupWindow) {
            click(allowAt, in: setupWindow)
            check(allows == 1, "I: ONE click on the Chrome row's Allow, in the inactive window, presses it exactly once: \(allows)")
            // The click that brings DayDream forward: didBecomeActive arrives with the press (the app's activation), a read
            // of Chrome's access starts, the page draws, then the release.
            allows = 0
            click(allowAt, in: setupWindow) {
                NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                check(activations == 1 && rowState.current == .checking && frames["allow.chrome"] != nil,
                      "I: DayDream became active with the press and Chrome is being read again: Allow is still drawn under it (no spinner)")
            }
            check(allows == 1, "I: the click that brings DayDream forward and starts that read presses Allow, exactly once: \(allows)")
            rowState.current = .notAsked
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            // The press itself (macOS asking): the spinner.
            rowState.questionInFlight = true; rowState.current = .checking
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            check(frames["allow.chrome"] == nil, "I: while macOS asks (a question in flight), the row shows its spinner, not Allow")
            rowState.questionInFlight = false; rowState.current = .notAsked
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        } else { check(false, "I: setup's page drew the Chrome row's Allow where a click reaches it: \(frames.keys.sorted())") }
        NotificationCenter.default.removeObserver(becameActive)
        if let nextAt = barButton(in: setupHost, window: setupWindow, fromRight: true), let backAt = barButton(in: setupHost, window: setupWindow, fromRight: false) {
            click(nextAt, in: setupWindow)
            check(nexts == 1, "I: ONE click on Continue, in the inactive window, presses it exactly once: \(nexts)")
            click(backAt, in: setupWindow)
            check(backs == 1, "I: ONE click on Back, in the inactive window, presses it exactly once: \(backs)")
        } else { check(false, "I: setup's Back and Continue take the activating click") }
        setupWindow.contentView = nil; setupWindow.orderOut(nil)
        check(allows == 1 && nexts == 1 && backs == 1, "I: nothing pressed twice")
        // What the row draws during a read (the model's `chromeRowAccess`): every state with a button keeps it; nothing
        // shown yet, Allowed, or a question in flight reads as before.
        typealias Row = PermissionChromeRow
        check([ChromeAccessState.notAsked, .chromeNotRunning, .unverified, .twoCopies, .denied, .askFailed].allSatisfy {
                  Row.duringRead(current: .checking, shown: $0, questionInFlight: false) == $0 },
              "I: a read keeps Allow (not asked, Chrome closed, unverified, two copies) and Ask again (refused) where they were")
        check(Row.duringRead(current: .checking, shown: .unknown, questionInFlight: false) == .checking
              && Row.duringRead(current: .checking, shown: .allowed, questionInFlight: false) == .checking
              && Row.duringRead(current: .checking, shown: .notAsked, questionInFlight: true) == .checking
              && Row.duringRead(current: .denied, shown: .notAsked, questionInFlight: false) == .denied,
              "I: the first read (nothing shown), an Allowed row and a question in flight still show the spinner; an answer shows as it is")
        let appSource = (try? String(contentsOfFile: "Sources/MacMemApp/MacMemApp.swift", encoding: .utf8)) ?? ""
        check(appSource.contains("return PermissionChromeRow.duringRead(current:chromeAccess,shown:chromeAccessShown,\n                                                  questionInFlight:askingChromeAccess || chromeOpeningForSetup)")
              && appSource.contains("if chromeResetting {return .checking}")
              && appSource.contains("if chromeAccess != .checking {chromeAccessShown=chromeAccess}"),
              "I: sources: the app's Chrome row (setup and Settings) draws `duringRead` over the last settled state; Ask again's reset still spins")


        // J. rc-018 RC3 B1/B2/B3/B10 (owner 10/9: drops missed because the drag image was the whole card). The drag image
        // is the app's icon centred on the pointer; the drag offers a copy only, whatever keys are held; how it ended
        // goes to the card; System Settings comes forward after a drop on it; an Allowed card doesn't drag; a lost
        // session never holds the next drag.
        let jRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pdg-\(getpid())")
        let liveApp = jRoot.appendingPathComponent("DayDream Live Test.app")
        try? FileManager.default.createDirectory(at: liveApp.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        var jStarted: [(NSView, NSEvent.EventType)] = []
        PermissionCardDrag.shared.sessionForChecks = { view, event in jStarted.append((view, event.type)) }
        var jFrames: [String: CGRect] = [:]
        let jPage = PermissionGrantView(appURL: liveApp, readAccessibility: { true }, readInputMonitoring: { false }, embedded: true, style: .settings,
                                        known: PermissionSnapshot(accessibility: true, inputMonitoring: false))
            .padding(20).frame(width: 600, height: 420, alignment: .top)
            .onPreferenceChange(PermissionPageElements.self) { jFrames = $0 }
        let (jWindow, jHost) = hostInWindow(jPage, size: NSSize(width: 600, height: 420))
        let jCards = pressViews(jHost).filter { !$0.keepOut }
        let axCard = jCards.first { $0.permission == "accessibility" }, imCard = jCards.first { $0.permission == "inputMonitoring" }
        check(axCard?.enabled == false && imCard?.enabled == true, "J (B10): an Allowed card doesn't drag; a missing one does")
        if let axCard, let imCard {
            let pa = axCard.convert(NSPoint(x: axCard.bounds.minX + 30, y: axCard.bounds.midY), to: nil)
            send([event(.leftMouseDown, pa, in: jWindow), event(.leftMouseDragged, NSPoint(x: pa.x + 12, y: pa.y), in: jWindow),
                  event(.leftMouseUp, NSPoint(x: pa.x + 12, y: pa.y), in: jWindow)])
            check(jStarted.isEmpty && !PermissionCardDrag.shared.dragging, "J (B10): pressing and moving the Allowed card starts no drag")
            let pi = imCard.convert(NSPoint(x: imCard.bounds.minX + 30, y: imCard.bounds.midY), to: nil)
            let dragTo = NSPoint(x: pi.x + 7, y: pi.y)
            send([event(.leftMouseDown, pi, in: jWindow), event(.leftMouseDragged, dragTo, in: jWindow)])
            let pointer = imCard.convert(dragTo, from: nil)
            let image = PermissionCardDrag.shared.lastDragFrame ?? .zero, size = PermissionCardDrag.shared.lastImageSize ?? .zero
            check(jStarted.count == 1 && near(image.midX, pointer.x, 0.01) && near(image.midY, pointer.y, 0.01),
                  "J (B1): the drag image is centred on the pointer: \(image) around \(pointer)")
            check(image.width >= 56 && image.width <= 64 && image.height == image.width && size.width >= 56 && size.width <= 64
                  && image.width < imCard.bounds.width / 4,
                  "J (B1): the drag image is the app's icon, 56-64 pt (not the \(Int(imCard.bounds.width)) pt card): \(image.size) \(size)")
            // How it ended (B2, B3). System Settings' window (top-left origin) and points in it, as AppKit gives them.
            let ph = NSScreen.screens.first?.frame.maxY ?? 0
            let ss = CGRect(x: 1000, y: 300, width: 723, height: 600)
            func appKitPoint(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: ph - y) }
            var activations = 0
            PermissionCardDrag.shared.endForChecks(at: appKitPoint(1300, 500), operation: .copy, settingsWindow: ss, activate: { activations += 1 })
            check(!PermissionCardDrag.shared.dragging && activations == 1 && PermissionDragGuideStatus.shared.dropLine(card: "inputMonitoring") == nil,
                  "J (B3): a drop on System Settings' window brings System Settings forward (once), and says nothing")
            send([event(.leftMouseUp, dragTo, in: jWindow)])
            send([event(.leftMouseDown, pi, in: jWindow), event(.leftMouseDragged, dragTo, in: jWindow)])
            PermissionCardDrag.shared.endForChecks(at: appKitPoint(200, 200), operation: .copy, settingsWindow: ss, activate: { activations += 1 })
            send([event(.leftMouseUp, dragTo, in: jWindow)])
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            check(activations == 1 && PermissionDragGuideStatus.shared.dropLine(card: "inputMonitoring") == .droppedOutside
                  && PermissionDragGuideStatus.shared.dropLine(card: "accessibility") == nil,
                  "J (B2): a drop that something outside System Settings took (Finder, the Desktop) is the card's line; System Settings stays put")
            check(jFrames["guideLine"] != nil && jFrames["card.inputMonitoring"].map { c in jFrames["guideLine"].map { c.contains($0) } ?? false } == true,
                  "J (B2): the line is drawn on the Input Monitoring card itself: \(jFrames["guideLine"].map { "\($0)" } ?? "none")")
            send([event(.leftMouseDown, pi, in: jWindow), event(.leftMouseDragged, dragTo, in: jWindow)])
            check(PermissionDragGuideStatus.shared.drop == nil, "J (B2): the next grab clears it")
            PermissionCardDrag.shared.endForChecks(at: appKitPoint(200, 200), operation: [], settingsWindow: ss, activate: { activations += 1 })
            send([event(.leftMouseUp, dragTo, in: jWindow)])
            check(PermissionDragGuideStatus.shared.drop == nil && activations == 1, "J (B2): a cancelled drag says nothing")
            send([event(.leftMouseDown, pi, in: jWindow), event(.leftMouseDragged, dragTo, in: jWindow)])
            try? FileManager.default.removeItem(at: liveApp)
            PermissionCardDrag.shared.endForChecks(at: appKitPoint(1300, 500), operation: .copy, settingsWindow: ss, activate: { activations += 1 })
            send([event(.leftMouseUp, dragTo, in: jWindow)])
            check(PermissionDragGuideStatus.shared.dropLine(card: "inputMonitoring") == .appMoved && activations == 1,
                  "J (B2): the app no longer where it was: the card says so (and nothing comes forward)")
            try? FileManager.default.createDirectory(at: liveApp.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            // B10: a session whose end never came doesn't hold the next drag: the next press frees it.
            send([event(.leftMouseDown, pi, in: jWindow), event(.leftMouseDragged, dragTo, in: jWindow)])
            check(PermissionCardDrag.shared.dragging, "J (B10): a drag running (its end never comes)")
            let held = jStarted.count
            send([event(.leftMouseUp, dragTo, in: jWindow), event(.leftMouseDown, pi, in: jWindow), event(.leftMouseDragged, dragTo, in: jWindow)])
            check(jStarted.count == held + 1, "J (B10): the next press and move start a new drag (the lost one's guard cleared on the press)")
            PermissionCardDrag.shared.endForChecks(); send([event(.leftMouseUp, dragTo, in: jWindow)])
        }
        jWindow.contentView = nil; jWindow.orderOut(nil)
        PermissionCardDrag.shared.sessionForChecks = nil
        check(PermissionCardDrag.operationMask(.outsideApplication) == .copy && PermissionCardDrag.operationMask(.withinApplication) == []
              && PermissionCardDrag.ignoresModifierKeys,
              "J (B2): the drag offers a copy only (never move, link, generic or delete), and ignores the modifier keys")
        check(setupSource.contains("session.draggingFormation = .none")
              && setupSource.contains("public nonisolated func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { Self.ignoresModifierKeys }")
              && setupSource.contains("Self.operationMask(context)") && setupSource.contains("item.setDraggingFrame(frame, contents: icon)")
              && !setupSource.contains("[.copy, .link, .generic]"),
              "J (B1, B2): sources: the session draws the icon alone (no formation), copy only, modifier keys ignored")
        typealias Outcome = PermissionDropOutcome
        let ssWin = CGRect(x: 1000, y: 300, width: 723, height: 600)
        check(Outcome.of(operation: .copy, point: CGPoint(x: 1100, y: 400), settingsWindow: ssWin, appStillThere: true) == .intoSettings
              && Outcome.of(operation: [], point: CGPoint(x: 1100, y: 400), settingsWindow: ssWin, appStillThere: true) == .intoSettings
              && Outcome.of(operation: .copy, point: CGPoint(x: 900, y: 400), settingsWindow: ssWin, appStillThere: true) == .outside
              && Outcome.of(operation: [], point: CGPoint(x: 900, y: 400), settingsWindow: ssWin, appStillThere: true) == .none
              && Outcome.of(operation: .copy, point: CGPoint(x: 900, y: 400), settingsWindow: nil, appStillThere: true) == .outside
              && Outcome.of(operation: .copy, point: CGPoint(x: 1100, y: 400), settingsWindow: ssWin, appStillThere: false) == .appMoved,
              "J: how a drag ended: on System Settings' window, taken elsewhere, let go on nothing, or the app moved")
        try? FileManager.default.removeItem(at: jRoot)

        // K. rc-018 RC3 B4/B8: the guided card's line for each state of DayDream's row (owner 10/9: "Drag this card"
        // forever when the row already existed).
        typealias Line = PermissionCardLine
        func line(_ read: Bool, _ row: PermissionListRow, on: TimeInterval = 0, returns: Int = 0, drop: TimeInterval? = nil, prompt: Bool = false) -> Line? {
            Line.of(canReadRow: read, row: row, rowOnFor: on, returns: returns, sinceDrop: drop, promptDismissed: prompt)
        }
        check(line(true, .none) == .drag && line(true, .unknown) == .drag, "K: Input Monitoring step, no row (or not read yet): \"Drag this card into the list.\"")
        check(line(true, .off) == .turnOn && line(true, .off, returns: 5) == .turnOn, "K: the row is listed but off: \"Turn on … in the list.\"")
        check(line(true, .on, on: 1) == nil && line(true, .on, on: 3.1) == .reAdd,
              "K: the row reads on but the permission off: the line holds, then after 3 s the remove-and-add-again step")
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clockUp = Line.rowOnClock(row: .on, promptUp: true, since: t0, now: t0.addingTimeInterval(5))
        let clockAfter = Line.rowOnClock(row: .on, promptUp: false, since: clockUp, now: t0.addingTimeInterval(6))
        check(clockUp == nil && clockAfter == t0.addingTimeInterval(6)
              && Line.rowOnClock(row: .on, promptUp: false, since: t0, now: t0.addingTimeInterval(4)) == t0
              && Line.rowOnClock(row: .off, promptUp: false, since: t0, now: t0) == nil
              && guide.contains("rowOnSince = PermissionCardLine.rowOnClock(row: row, promptUp: promptUp, since: rowOnSince, now: now)"),
              "K: a switch that reads on while the password prompt (or a sheet) is up never counts toward the remove-and-add-again step; its 3 s start once the prompt is gone")
        check(Line.dropClock(droppedAt: t0, promptUp: true, now: t0.addingTimeInterval(20)) == t0.addingTimeInterval(20)
              && Line.dropClock(droppedAt: t0, promptUp: false, now: t0.addingTimeInterval(20)) == t0
              && Line.dropClock(droppedAt: nil, promptUp: true, now: t0) == nil
              && guide.contains("droppedAt = PermissionCardLine.dropClock(droppedAt: droppedAt, promptUp: promptUp, now: now)"),
              "K: Accessibility step: the 8 s after a drop never run while the password prompt is up (they start once it's gone)")
        check(line(false, .unknown) == .dragOrTurnOn && line(false, .unknown, returns: 1, drop: 7.5) == .dragOrTurnOn,
              "K: Accessibility step (nothing to read): one line for both cases")
        check(line(false, .unknown, returns: 2) == .reAdd && line(false, .unknown, drop: 8.1) == .reAdd,
              "K: Accessibility step: after two returns, or 8 s after a drop on System Settings, the remove-and-add-again step")
        check(line(true, .none, prompt: true) == .password && line(false, .unknown, prompt: true) == .passwordOrTurnOn
              && line(true, .off, prompt: true) == .turnOn,
              "K (B8): the password prompt dismissed with no row: the password line (a listed row is still \"Turn on\")")
        // Review 10/9: a cancelled password prompt added no row: its line stands until the next grab, never replaced 8 s
        // later by a step to remove a row that isn't there; and a drop that missed the list starts no clock at all.
        check(line(false, .unknown, drop: 30, prompt: true) == .passwordOrTurnOn && line(false, .unknown, returns: 3, drop: 30, prompt: true) == .passwordOrTurnOn,
              "K (B8): Accessibility step, the password prompt cancelled: the password line stays (8 s, 30 s, two returns later), never the remove-and-add-again step")
        check(Line.dropStartsClock(.intoSettings, operation: .copy, promptDismissed: false)
              && !Line.dropStartsClock(.intoSettings, operation: [], promptDismissed: false)
              && !Line.dropStartsClock(.intoSettings, operation: .copy, promptDismissed: true)
              && !Line.dropStartsClock(.outside, operation: .copy, promptDismissed: false) && !Line.dropStartsClock(.none, operation: [], promptDismissed: false),
              "K (B4): only a drop System Settings took starts the 8 s to the remove-and-add-again step (not one on its sidebar or a missed list, not after a cancelled prompt)")
        check(guide.contains("if !granted(), row == .none || row == .unknown { promptDismissed = true; droppedAt = nil }")
              && guide.contains("promptDismissed = false; promptEndedAt = nil; droppedAt = nil")
              && setupSource.contains("PermissionDragGuide.noteDrop(outcome, operation: operation)"),
              "K (B4, B8): sources: a cancelled prompt stops the drop clock, a grab clears it, the drop passes its operation")
        let liveName = "DayDream Live Test"
        let allLines: [Line] = [.drag, .dragOrTurnOn, .turnOn, .reAdd, .password, .passwordOrTurnOn, .droppedOutside, .appMoved]
        let lineBanned = ["draft", "never uploaded", "never leave", "a free memory for your mac", "error", "failed"]
        check(allLines.allSatisfy { l in let t = l.text(appName: liveName); return t.count <= 120 && !lineBanned.contains { t.lowercased().contains($0) } },
              "K: every card line is short (two lines at most, 120 characters with the Live Test's name) and plain: "
                + allLines.map { "\($0.text(appName: liveName).count)" }.joined(separator: ","))
        check(Line.turnOn.text(appName: liveName) == "Turn on DayDream Live Test in the list." && Line.drag.text(appName: liveName) == PermissionDragGuideText.cardLine
              && Line.reAdd.text(appName: liveName).contains("minus") && Line.password.text(appName: "DayDream").contains("administrator password")
              && [Line.password, .passwordOrTurnOn, .droppedOutside, .appMoved].allSatisfy(\.warns) && ![Line.drag, .turnOn, .reAdd, .dragOrTurnOn].contains(where: \.warns),
              "K: the lines name this copy; the ones about something that went wrong are drawn orange")
        check(guide.contains("row = read == nil ? .none : read?.on == true ? .on : .off") && guide.contains("\"AXCheckBox\"")
              && guide.contains("if row == .off || row == .on, model.demoStart != nil { model.demoStart = nil }"),
              "K: sources: the row's switch is read (never pressed); a listed row stops the demo")
        check(setupSource.contains("            ForEach(DaydreamPermission.allCases) { permission in permissionCard(permission) }\n            if let chromeRow { chromeCard(chromeRow) }\n            if showsReAdd { reAddBanner }")
              && !setupSource.contains("if showsReAddFirst { reAddBanner }"),
              "K: the remove-and-add-again step shows under the cards, never inserted above them")

        // L. rc-018 RC3 B5 (owner 10/9: windows moved mid-drag): no window moves while a press or a drag is on; the
        // move waits and goes once it's over. A virtual screen far off every real one: nothing lands on this Mac's screen.
        let virtual = CGRect(x: -30000, y: 20000, width: 2560, height: 1320)
        let moveWin = OffscreenWindow(contentRect: NSRect(x: -4000, y: -4000, width: 660, height: 632), styleMask: [.titled], backing: .buffered, defer: false)
        moveWin.orderFrontRegardless()
        let ssV = CGRect(x: -30000 + 1300, y: 20200, width: 723, height: 624)
        let start0 = moveWin.frame
        check(!guideObject.moveForChecks(window: moveWin, nextTo: ssV, visible: virtual, pressed: { true }) && moveWin.frame == start0,
              "L: a press is on: setup doesn't move")
        let ph = NSScreen.screens.first?.frame.maxY ?? 0
        check(guideObject.releaseForChecks(window: moveWin, visible: virtual, pressed: { false })
              && near(moveWin.frame.maxX, ssV.minX - 16, 0.6) && near(moveWin.frame.maxY, ph - ssV.minY, 0.6),
              "L: the button up: the held move goes, setup 16 pt left of System Settings, tops aligned: \(moveWin.frame)")
        moveWin.setFrame(start0, display: false)
        var lStarted = 0
        PermissionCardDrag.shared.sessionForChecks = { _, _ in lStarted += 1 }
        let lAnchorWin = OffscreenWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        let lAnchor = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80)); lAnchorWin.contentView = lAnchor
        let lDrag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 40, y: 40), modifierFlags: [], timestamp: 0, windowNumber: lAnchorWin.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        let lBegan = PermissionCardDrag.shared.begin(appURL: installed, enabled: true, guides: false, anchor: lAnchor, event: lDrag)
        check(lBegan && !guideObject.moveForChecks(window: moveWin, nextTo: ssV, visible: virtual, pressed: { PermissionDragGuide.pressedOrDragging() })
              && moveWin.frame == start0, "L: a card's drag is on (the app's own read): setup doesn't move")
        PermissionCardDrag.shared.endForChecks()
        _ = guideObject.releaseForChecks(window: moveWin, visible: virtual, pressed: { false })
        moveWin.setFrame(start0, display: false)
        check(guide.contains("guard !reads.pressed() else { pendingMove = settings; return }") && guide.contains("guard await released(run) else { return }")
              && guide.contains("guard moved, !reads.pressed(), let window = settingsWindow")
              && guide.contains("if let held = pendingMove, !reads.pressed() { moveSetup(nextTo: held) }"),
              "L: sources: placement's System Settings writes, setup's move and the one redo all wait for the press or drag to end")

        // M. rc-018 RC3 B6: the demo plays only until the first real grab in a run, either card's; it never lands on a row.
        guideObject.start(window: nil, appURL: installed, appName: "DayDream", source: { nil },
                          reads: PermissionDragGuide.Reads(accessibility: { false }, inputMonitoring: { false }, reduceMotion: { false }, pressed: { false }))
        check(guideObject.active && !guideObject.demoDone, "M: a run starts with its demo to play")
        let mBegan = PermissionCardDrag.shared.begin(appURL: installed, enabled: true, guides: false, anchor: lAnchor, event: lDrag)
        check(mBegan && guideObject.demoDone, "M: grabbing the OTHER card (not the guided one) ends the demo for the run")
        // K live (review 10/9): the running guide's drop clock, from real drag ends (System Settings' window stood in).
        let kph = NSScreen.screens.first?.frame.maxY ?? 0, kss = CGRect(x: 1000, y: 300, width: 723, height: 600)
        let kApp = FileManager.default.temporaryDirectory.appendingPathComponent("k-live-\(getpid())/DayDream Live Test.app")
        try? FileManager.default.createDirectory(at: kApp.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        PermissionCardDrag.shared.endForChecks()
        _ = PermissionCardDrag.shared.begin(appURL: kApp, enabled: true, guides: false, anchor: lAnchor, event: lDrag)
        PermissionCardDrag.shared.endForChecks(at: NSPoint(x: 1050, y: kph - 400), operation: [], settingsWindow: kss)
        let missed = guideObject.dropClockForChecks
        _ = PermissionCardDrag.shared.begin(appURL: kApp, enabled: true, guides: false, anchor: lAnchor, event: lDrag)
        PermissionCardDrag.shared.endForChecks(at: NSPoint(x: 1400, y: kph - 500), operation: .copy, settingsWindow: kss)
        let taken = guideObject.dropClockForChecks
        _ = PermissionCardDrag.shared.begin(appURL: kApp, enabled: true, guides: false, anchor: lAnchor, event: lDrag)
        let regrabbed = guideObject.dropClockForChecks
        check(missed == nil && taken != nil && regrabbed == nil,
              "K live: a drop on System Settings' sidebar that nothing took starts no clock; one it took does; the next grab clears it (\(String(describing: missed)), \(String(describing: taken)), \(String(describing: regrabbed)))")
        PermissionCardDrag.shared.endForChecks()
        try? FileManager.default.removeItem(at: kApp.deletingLastPathComponent())
        guideObject.stop(.left)
        PermissionCardDrag.shared.sessionForChecks = nil
        lAnchorWin.contentView = nil
        check(guide.contains("if !demoDone, row != .off, row != .on { model.demoStart = Date() }")
              && !guide.contains("model.demoStart = now.addingTimeInterval(-PermissionDemo.firstDelay)"),
              "M: sources: the demo starts only before any grab, and never comes back after a drop")
        let mList = CGRect(x: 1869, y: 509, width: 460, height: 128), mWindow = CGRect(x: 1626, y: 404, width: 723, height: 632)
        func ghostAtEnd(_ zone: CGRect) -> CGRect {
            let drop = Pair.dropPoint(list: zone, firstRow: nil)
            let land = Pair.landing(card: CGSize(width: 588, height: 74), zone: zone, drop: drop)
            return Pair.ghostRect(card: CGSize(width: 588, height: 74), held: land.point, scale: land.scale * 1.03)
        }
        let someRows = (0..<3).map { CGRect(x: mList.minX, y: mList.minY + CGFloat($0) * 28, width: mList.width, height: 28) }
        let roomy = Pair.demoZone(list: mList, rows: someRows, settingsWindow: mWindow)
        check(!someRows.contains { $0.intersects(ghostAtEnd(roomy)) } && mList.contains(ghostAtEnd(roomy)),
              "M: three rows and room under them: the demo lands in the list's empty space, on no row: \(ghostAtEnd(roomy))")
        let fullRows = (0..<4).map { CGRect(x: mList.minX, y: mList.minY + CGFloat($0) * 32, width: mList.width, height: 32) }
        let full = Pair.demoZone(list: mList, rows: fullRows, settingsWindow: mWindow)
        check(!fullRows.contains { $0.intersects(ghostAtEnd(full)) } && ghostAtEnd(full).minY >= mList.maxY && mWindow.contains(ghostAtEnd(full))
              && ghostAtEnd(full).maxX <= mList.minX + 160,
              "M: a full list: the demo lands on the + area under the list's left edge, never a row or its switch: \(ghostAtEnd(full))")
        check(Pair.demoZone(list: mList, rows: [], settingsWindow: mWindow) == Pair.zone(list: mList, settingsWindow: mWindow),
              "M: an empty list (\"No Items\"): the demo lands in it")

        // N. rc-018 RC3 B7: setup never covers System Settings' list, at 1280, 1440 and 1470 pt wide screens, wherever
        // System Settings is; where setup can't fit, the compact drag panel goes beside it instead.
        var nBad: [String] = [], compacts: [Int: Int] = [:]
        for (w, visibleTL) in [(1280, CGRect(x: 0, y: 25, width: 1280, height: 705)), (1440, CGRect(x: 0, y: 25, width: 1440, height: 805)),
                               (1470, CGRect(x: 0, y: 33, width: 1470, height: 853))] {
            for stageOn in [false, true] {
                for x in stride(from: CGFloat(0), through: CGFloat(w) - 723, by: 7) {
                    let ssN = CGRect(x: x, y: visibleTL.minY + 40, width: 723, height: 624)
                    let r = Pair.beside(setup: CGSize(width: 660, height: 632), settings: ssN, visible: visibleTL, stageManager: stageOn)
                    let coversList = r.frame.maxX > ssN.minX + Pair.sidebar + 0.5 && r.frame.minX < ssN.maxX - 0.5
                    if r.compact {
                        compacts[w, default: 0] += 1
                        let c = Pair.compact(size: CGSize(width: Pair.compactWidth, height: 86), settings: ssN, visible: visibleTL, stageManager: stageOn)
                        if (c.maxX > ssN.minX + Pair.sidebar + 0.5 && c.minX < ssN.maxX - 0.5) || c.minX < visibleTL.minX || c.maxX > visibleTL.maxX {
                            nBad.append("\(w) x\(Int(x)) stage \(stageOn): compact \(c)")
                        }
                    } else if coversList || r.frame.minX + Pair.textInset < visibleTL.minX - 0.5 || r.frame.maxX - Pair.shellMargin > visibleTL.maxX + 0.5 {
                        nBad.append("\(w) x\(Int(x)) stage \(stageOn): \(r.frame)")
                    }
                }
            }
        }
        check(nBad.isEmpty, "N: at 1280, 1440 and 1470 pt, System Settings anywhere, Stage Manager on or off: setup (or the compact panel) never covers the list, its text on screen: \(nBad.prefix(4))")
        let centered1280 = Pair.beside(setup: CGSize(width: 660, height: 632), settings: CGRect(x: 278, y: 65, width: 723, height: 624),
                                       visible: CGRect(x: 0, y: 25, width: 1280, height: 705), stageManager: false)
        let centered1440 = Pair.beside(setup: CGSize(width: 660, height: 632), settings: CGRect(x: 358, y: 65, width: 723, height: 624),
                                       visible: CGRect(x: 0, y: 25, width: 1440, height: 805), stageManager: false)
        check(centered1280.compact && !centered1440.compact && centered1440.frame.maxX <= 358 + Pair.sidebar && (compacts[1280] ?? 0) > 0,
              "N: System Settings in the middle: 1440 pt clamps setup over its sidebar (\(centered1440.frame)); 1280 pt takes the compact panel")
        // Live: the compact panel (off every screen here) stands in for setup, and setup comes back after.
        let v1280 = CGRect(x: -30000, y: 20025, width: 1280, height: 705)
        _ = guideObject.moveForChecks(window: moveWin, nextTo: CGRect(x: -30000 + 278, y: 20065, width: 723, height: 624), visible: v1280, pressed: { false })
        let cf = guideObject.lastCompactFrame ?? .zero
        check(cf.width == Pair.compactWidth && cf.maxX <= -30000 + 278 + Pair.sidebar + 0.5 && moveWin.isVisible && moveWin.frame == start0,
              "N: 1280 pt, System Settings in the middle: the compact panel goes left of the list (\(cf)); setup didn't move and is back")
        check(Pair.uncovered(CGRect(x: 500, y: 100, width: 400, height: 150), by: CGRect(x: 0, y: 0, width: 660, height: 600)) == CGRect(x: 664, y: 100, width: 236, height: 150)
              && Pair.uncovered(CGRect(x: 500, y: 100, width: 400, height: 150), by: CGRect(x: 1000, y: 0, width: 660, height: 600)) == CGRect(x: 500, y: 100, width: 400, height: 150)
              && guide.contains("let zone = PermissionPair.uncovered(PermissionPair.zone(list: list, settingsWindow: frame), by: covered)"),
              "N: the part of the list's zone under setup is cut out of the drop zone and the demo's spot")
        moveWin.orderOut(nil)

        // O. rc-018 RC3 B9: a sheet never floats, nor its parent (Settings' sheet over the memory window); a plain
        // permission window (setup, the small permissions window) floats and goes back.
        let parentWin = OffscreenWindow(contentRect: NSRect(x: -6000, y: -6000, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        parentWin.orderFrontRegardless()
        let sheetWin = OffscreenWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        parentWin.beginSheet(sheetWin) { _ in }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let sheetLevel = PermissionWindowLevel(); sheetLevel.window = sheetWin
        sheetLevel.set(floating: true)
        check(sheetWin.sheetParent === parentWin && parentWin.level == .normal && sheetWin.level.rawValue < NSWindow.Level.floating.rawValue
              && sheetLevel.raisedWindows.isEmpty,
              "O: a page in a sheet: neither the sheet nor its parent window floats")
        sheetLevel.set(floating: false)
        parentWin.endSheet(sheetWin)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let plainLevel = PermissionWindowLevel(); plainLevel.window = parentWin
        plainLevel.set(floating: true)
        let floated = parentWin.level == .floating
        plainLevel.set(floating: false)
        check(floated && parentWin.level == .normal, "O: a plain permission window floats beside System Settings and goes back")
        parentWin.orderOut(nil); sheetWin.orderOut(nil)
        let menuSource = (try? String(contentsOfFile: "Sources/MacMemApp/MenuBarContent.swift", encoding: .utf8)) ?? ""
        check(appSource.contains("if development == nil, let open=openPermissions ?? openPermissionsWindow {settingsPresented=false;open();return}")
              && appSource.contains("openPermissions:{ openWindow(id:\"permissions\") }")
              && menuSource.contains("openPermissions: { routes.openWindow(\"permissions\"); routes.activate() }"),
              "O: a `Turn on …` press after setup opens the small permissions window (its cards beside System Settings), not Settings' sheet")
        // O2 (review 10/9): Settings › Permissions is a sheet, so nothing stays beside System Settings there: its card's
        // Open System Settings opens the small permissions window instead. The real page and its real button (pressed
        // through Accessibility); opening a pane is stood in for, so System Settings never opens here.
        var routed: [String] = [], panes: [URL] = []
        let openPane = PermissionGrantView.openPane
        PermissionGrantView.openPane = { panes.append($0); return true }
        var routeActions = PermissionRequestActions(quitAndReopen: nil)
        routeActions.openInWindow = { routed.append($0) }
        let routePage = PermissionGrantView(appURL: installed, readAccessibility: { false }, readInputMonitoring: { false }, embedded: true,
                                            style: .settings, known: PermissionSnapshot(accessibility: false, inputMonitoring: false))
            .environment(\.daydreamPermissionRequests, routeActions)
            .padding(20).frame(width: 600, height: 420, alignment: .top)
        let (oWindow, oHost) = hostInWindow(routePage, size: NSSize(width: 600, height: 420))
        // Each card's Open System Settings button (its keep-out room), clicked once as AppKit delivers it.
        let openButtons = pressViews(oHost).filter(\.keepOut)
        var oClicks = 0
        for button in openButtons {
            let r = button.convert(button.bounds, to: nil).insetBy(dx: 2, dy: 2)
            let points = stride(from: r.minY, through: r.maxY, by: 2).flatMap { y in stride(from: r.minX, through: r.maxX, by: 2).map { NSPoint(x: $0, y: y) } }
            if let p = points.sorted(by: { hypot($0.x - r.midX, $0.y - r.midY) < hypot($1.x - r.midX, $1.y - r.midY) }).first(where: { takesFirstClick($0, in: oHost, oWindow) }) {
                click(p, in: oWindow); oClicks += 1
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check(openButtons.count == 2 && Set(routed) == ["accessibility", "inputMonitoring"] && routed.count == 2 && panes.isEmpty,
              "O2: Settings › Permissions: each card's Open System Settings opens the permissions window on its permission (routed \(routed)), never System Settings from the sheet (panes \(panes.count), buttons \(openButtons.count), clicked \(oClicks))")
        oWindow.contentView = nil; oWindow.orderOut(nil)
        PermissionGrantView.openPane = openPane
        check(setupSource.contains("if !guided, let openInWindow = requests?.openInWindow { openInWindow(permission.rawValue); return }")
              && setupSource.contains("if !guided, requests?.openInWindow != nil { return }")
              && appSource.contains("if openPermissionsWindow != nil {actions.openInWindow={ [weak self] raw in self?.showPermissionsWindow(for:raw) }}")
              && appSource.contains("model.openPermissionsWindow={ [openWindow] in openWindow(id:\"permissions\") }"),
              "O2: sources: Settings' page hands its presses and pane requests to the permissions window; the app wires it")

        print("\(failed == 0 ? "PASSED" : "FAILED") \(passed) permission drag guide checks, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
