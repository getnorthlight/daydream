import AppKit
import SwiftUI
import ApplicationServices
import CoreGraphics
#if DEBUG || DAYDREAM_LIVETEST
import os
#endif

// rel-018 v2: setup's Accessibility and Input Monitoring steps. When one of setup's two cards opens System Settings, the
// two windows become an adjacent pair. With Accessibility allowed (the Input Monitoring step) the pair is centered on the
// screen: setup and System Settings 16 pt apart, tops lined up (or overlapping only System Settings' sidebar on a small
// screen). Without it (the Accessibility step) System Settings can't be moved, so setup moves next to wherever System
// Settings is; setup always ends next to System Settings' actual frame, so the pair forms even when System Settings
// ignores the move. A click-through
// overlay draws a short demo (no words, no ring; owner 10/8: "Just get rid of the blue ring"): the Mac's own grab hand
// picks up an exact image of the real card, carries it into the pane's list and lets go (three plays, then one every
// 6 s). The moment the person grabs the real card the demo goes, and a green check appears on DayDream's row once
// System Settings lists it.
//
// Nothing here asks macOS for a permission (scripts/recording-permission-checks.swift): it reads Accessibility
// (`AXIsProcessTrusted`) and Input Monitoring (`CGPreflightListenEventAccess`, passed in by the page). Window frames come
// from the window server (CGWindowList, no permission needed); with Accessibility already allowed (setup's first card)
// it moves System Settings' window through `SettingsWindowAX.setFrame` (position and size only), and only while it is
// placing the pair: once the pair settled, a System Settings that moves is the person's doing and is never moved again.
// No click, key or synthetic event ever goes to System Settings: the person does the drag. Every step that can fail
// falls back to less, and none of it ever stops setup.

/// Where the two windows go, the list's zone and the demo's path. Pure (scripts/permission-drag-guide-checks.swift).
/// Rects here are top-left-origin global (the window server's and Accessibility's); AppKit rects go through `flipped`,
/// and anything drawn goes through `local` (the overlay window's own top-left coordinates).
public enum PermissionPair {
    /// Space between the two windows, the screen margin kept free, System Settings' sidebar (what setup may cover on a
    /// small screen) and the height System Settings won't go below.
    public static let gap: CGFloat = 16, margin: CGFloat = 8, sidebar: CGFloat = 215, minHeight: CGFloat = 470
    /// Stage Manager's strip on the left of the screen.
    public static let stageManagerStrip: CGFloat = 96

    public enum Option: String, Equatable, Sendable {
        /// The pair centered on the screen (owner 10/7: "both of them near the center"); the pair at the screen's two
        /// edges, setup over System Settings' sidebar, when the screen is too narrow for both.
        case centered, overlap
    }

    public struct Placement: Equatable, Sendable {
        public var setup: CGRect
        public var settings: CGRect
        public var option: Option
        /// How far setup covers System Settings (0 when they don't touch).
        public var overlap: CGFloat { max(0, min(setup.maxX, settings.maxX) - max(setup.minX, settings.minX)) }
    }

    /// AppKit (bottom-left origin) and top-left-origin rects; the same flip both ways. `primaryHeight`: the top of the
    /// primary screen (the menu bar's, `NSScreen.screens[0].frame.maxY`), never the overlay's screen or a visible frame.
    public static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// An AppKit global rect in a window's own top-left coordinates (what a SwiftUI view filling `window`, an AppKit
    /// frame, draws in).
    public static func local(appKit rect: CGRect, in window: CGRect) -> CGRect {
        CGRect(x: rect.minX - window.minX, y: window.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A top-left-origin global rect (window server, Accessibility) in a window's own top-left coordinates.
    public static func local(topLeft rect: CGRect, in window: CGRect, primaryHeight: CGFloat) -> CGRect {
        local(appKit: flipped(rect, primaryHeight: primaryHeight), in: window)
    }

    /// A top-left-origin global point in a window's own top-left coordinates, and back.
    public static func local(topLeft point: CGPoint, in window: CGRect, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x - window.minX, y: window.maxY - (primaryHeight - point.y))
    }
    public static func global(local point: CGPoint, in window: CGRect, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x + window.minX, y: primaryHeight - (window.maxY - point.y))
    }

    /// The room the pair may use: the screen's visible frame inside the margin, less Stage Manager's strip when it is on.
    public static func usable(visible: CGRect, stageManager: Bool) -> CGRect {
        var room = visible.insetBy(dx: margin, dy: margin)
        if stageManager { room.origin.x += stageManagerStrip; room.size.width -= stageManagerStrip }
        return room
    }

    /// Where the pair goes. `setup`: setup's window (it is never resized). `settings`: System Settings' window as read
    /// (its width is kept: System Settings won't take another). `visible`: the visible frame of setup's screen. The pair
    /// centered on it (total width setup + 16 + System Settings, the taller window centered vertically, tops aligned),
    /// else the pair at the screen's edges.
    public static func place(setup: CGRect, settings: CGRect, visible: CGRect, stageManager: Bool) -> Placement {
        let room = usable(visible: visible, stageManager: stageManager)
        let width = settings.width
        let height = min(max(setup.height, minHeight), room.height)
        /// System Settings' rect at `x` with its top at `top`: `height`, cut to fit the room below its top.
        func settingsRect(_ x: CGFloat, top: CGFloat) -> CGRect {
            var top = max(room.minY, top)
            if room.maxY - top < min(height, minHeight) { top = max(room.minY, room.maxY - height) }
            return CGRect(x: x, y: top, width: width, height: min(height, room.maxY - top))
        }
        let pairHeight = max(setup.height, height)
        let top = min(max(room.minY, (room.midY - pairHeight / 2).rounded()), max(room.minY, room.maxY - pairHeight))
        let total = setup.width + gap + width
        if total <= room.width {
            let x0 = (room.midX - total / 2).rounded()
            return Placement(setup: CGRect(x: x0, y: top, width: setup.width, height: setup.height),
                             settings: settingsRect(x0 + setup.width + gap, top: top), option: .centered)
        }
        // Not enough room: setup at the left edge, System Settings at the right; setup covers its sidebar first (the
        // list starts 243 pt in, so it stays in view).
        return Placement(setup: CGRect(x: room.minX, y: top, width: setup.width, height: setup.height),
                         settings: settingsRect(room.maxX - width, top: top), option: .overlap)
    }

    /// Setup's window next to where System Settings actually is (`settings`, as the window server reads it): left of it
    /// with the gap, else right of it, else at the screen edge away from it. Needs no Accessibility, so the pair forms
    /// even when System Settings ignored every move. Tops aligned whenever setup fits on the visible frame there, also
    /// when it already sits beside System Settings; the top is held only by the visible frame itself (not the 8 pt
    /// margin), so a pair by the Dock stays as level as the screen allows (owner's 10/8 run: System Settings at y 725,
    /// 624 tall, setup 632 tall over a visible frame ending at 1350: setup at y 718, not 710).
    public static func follow(setup size: CGSize, settings: CGRect, visible: CGRect, stageManager: Bool) -> CGRect {
        beside(setup: size, settings: settings, visible: visible, stageManager: stageManager).frame
    }

    /// rc-018 RC3 B7: how far into setup's window the cards' titles and lines start (the shell's 36 pt margin, the card's
    /// 26 pt, its 44 pt icon and 14 pt): setup may hang off the screen's left edge by less than this.
    public static let textInset: CGFloat = 120
    /// The shell's margin right of the cards: setup may hang off the screen's right edge by this much.
    public static let shellMargin: CGFloat = 36
    /// The compact drag panel (the card and its line, alone) when setup can't sit beside System Settings.
    public static let compactWidth: CGFloat = 360

    /// `follow`, and whether setup must give way to the compact drag panel. Rule 7: setup never covers System Settings'
    /// list. Left of it with the gap, else right of it, else over its sidebar at most (`sidebar`, never further: the list
    /// starts 243 pt in), hanging off the screen's left edge if it must while the cards' text stays on screen, else right
    /// of it hanging off the right edge by at most the shell's margin; when none of these fits (a 1280 pt screen with
    /// System Settings in the middle) `compact` is true and `frame` is where setup would have gone.
    public static func beside(setup size: CGSize, settings: CGRect, visible: CGRect, stageManager: Bool) -> (frame: CGRect, compact: Bool) {
        let room = usable(visible: visible, stageManager: stageManager)
        let top = size.height >= visible.height ? visible.minY : min(max(settings.minY, visible.minY), visible.maxY - size.height)
        func at(_ x: CGFloat) -> CGRect { CGRect(x: x, y: top, width: size.width, height: size.height) }
        let left = settings.minX - gap - size.width
        if left >= room.minX - 0.5 { return (at(left), false) }
        let right = settings.maxX + gap
        if right + size.width <= room.maxX + 0.5 { return (at(right), false) }
        let overSidebar = min(room.minX, settings.minX + sidebar - size.width)
        if overSidebar + textInset >= visible.minX - 0.5 { return (at(overSidebar), false) }
        let hanging = max(room.maxX - size.width, right)
        if hanging + size.width - shellMargin <= visible.maxX + 0.5 { return (at(hanging), false) }
        return (at(overSidebar), true)
    }

    /// The compact drag panel's place: level with the top of System Settings' list, left of System Settings with the gap,
    /// else over its sidebar at most (into Stage Manager's strip if it must), else right of it, else at the screen's edge
    /// away from it.
    public static func compact(size: CGSize, settings: CGRect, visible: CGRect, stageManager: Bool) -> CGRect {
        let room = usable(visible: visible, stageManager: stageManager)
        let y = min(max(settings.minY + 100, room.minY), room.maxY - size.height)
        func at(_ x: CGFloat) -> CGRect { CGRect(x: x, y: y, width: size.width, height: size.height) }
        let left = settings.minX - gap - size.width
        if left >= room.minX - 0.5 { return at(left) }
        let overSidebar = min(room.minX, settings.minX + sidebar - size.width)
        if overSidebar >= visible.minX - 0.5 { return at(overSidebar) }
        let right = settings.maxX + gap
        if right + size.width <= visible.maxX + 0.5 { return at(right) }
        return at(settings.midX >= room.midX ? room.minX : room.maxX - size.width)
    }

    /// Whether System Settings may be moved at all: never in full screen (its window fills its screen), minimized, or
    /// without Accessibility.
    public static func writesSettings(settings: CGRect, screen: CGRect, minimized: Bool, trusted: Bool) -> Bool {
        let fullScreen = abs(settings.minX - screen.minX) <= 1 && abs(settings.minY - screen.minY) <= 1
            && abs(settings.width - screen.width) <= 1 && abs(settings.height - screen.height) <= 1
        return trusted && !minimized && !fullScreen
    }

    /// Two reads of System Settings' window in a row agree (within 1 pt) and it is past its opening size.
    public static func settled(_ previous: CGRect?, _ current: CGRect?) -> Bool {
        guard let previous, let current, current.height > 200 else { return false }
        return abs(previous.minX - current.minX) <= 1 && abs(previous.minY - current.minY) <= 1
            && abs(previous.width - current.width) <= 1 && abs(previous.height - current.height) <= 1
    }

    /// A move took: the read-back is within 2 pt of the target (left, top, height; the width is System Settings' own).
    public static func took(_ target: CGRect, _ actual: CGRect) -> Bool {
        abs(target.minX - actual.minX) <= 2 && abs(target.minY - actual.minY) <= 2 && abs(target.height - actual.height) <= 2
    }

    /// The list's place when Accessibility can't find it: System Settings' right pane, under the pane's description
    /// (a 215 pt sidebar plus margins, the title bar and the description above the list; measured on its Input
    /// Monitoring pane: rows from 105 pt down, 243 pt in).
    public static func estimatedList(settingsWindow window: CGRect) -> CGRect {
        let left: CGFloat = window.width >= 560 ? 243 : 16, right: CGFloat = 20, top: CGFloat = 105
        let height = min(170, max(60, window.height - top - 24))
        return CGRect(x: window.minX + left, y: window.minY + top, width: max(80, window.width - left - right), height: height)
    }

    /// The list's zone (nothing draws it): the list (or the estimate) grown 6 pt, inside System Settings' window, and
    /// never more than 6 pt above the list's top edge, so the demo's card never lands on the pane's description. The
    /// demo lands inside it; a real drag over it counts as over the list.
    public static func zone(list: CGRect?, settingsWindow window: CGRect) -> CGRect {
        let base = list.flatMap { $0.width >= 40 && $0.height >= 20 ? $0 : nil } ?? estimatedList(settingsWindow: window)
        var zone = base.insetBy(dx: -6, dy: -6)
        let inside = zone.intersection(window.insetBy(dx: 4, dy: 4))
        if !inside.isNull, !inside.isEmpty { zone = inside }
        if zone.minY < base.minY - 6 { zone.size.height -= base.minY - 6 - zone.minY; zone.origin.y = base.minY - 6 }
        return zone
    }

    /// rc-018 RC3 B6: where the demo lets go, never on a row or its switch: the list's empty space under its last row
    /// (28 pt or more), else the + area under the list's left edge, else (no rows: "No Items") the list's zone. `rows`:
    /// the list's rows, top-left global like `list`. UNVERIFIED: whether System Settings takes a drop on its + area.
    public static func demoZone(list: CGRect, rows: [CGRect], settingsWindow window: CGRect) -> CGRect {
        let whole = zone(list: list, settingsWindow: window)
        guard let last = rows.filter({ $0.width > 0 && $0.height > 0 }).map(\.maxY).max() else { return whole }
        let inner = window.insetBy(dx: 4, dy: 4)
        if list.maxY - last >= 28 {
            let empty = CGRect(x: list.minX, y: last + 2, width: list.width, height: list.maxY - last - 2).intersection(inner)
            if !empty.isNull, empty.height >= 24 { return empty }
        }
        let plus = CGRect(x: list.minX, y: list.maxY + 2, width: min(list.width, 160), height: 32).intersection(inner)
        return plus.isNull || plus.height < 16 || plus.width < 40 ? whole : plus
    }

    /// rc-018 RC3 B7: `zone` without the part setup's window (`setup`, both top-left global) covers: the side of it away
    /// from setup. A zone setup covers whole stays as it is (nothing better to aim at).
    public static func uncovered(_ zone: CGRect, by setup: CGRect?) -> CGRect {
        guard let setup, zone.intersects(setup) else { return zone }
        var out = zone
        if setup.midX <= zone.midX {
            let left = max(zone.minX, setup.maxX + 4)
            out.origin.x = left; out.size.width = zone.maxX - left
        } else {
            out.size.width = min(zone.maxX, setup.minX - 4) - zone.minX
        }
        return out.width >= 24 ? out : zone
    }

    /// Where the demo drops the card: 72 pt into the list, on its first row (or its middle), 12 pt inside it.
    public static func dropPoint(list: CGRect, firstRow: CGRect?) -> CGPoint {
        let inner = list.insetBy(dx: min(12, list.width / 2), dy: min(12, list.height / 2))
        let y = firstRow.map { $0.midY } ?? list.midY
        return CGPoint(x: min(max(list.minX + 72, inner.minX), inner.maxX), y: min(max(y, inner.minY), inner.maxY))
    }

    /// The demo's arc: the control point over the chord's middle, raised min(8, 18% of the distance), so the card
    /// stays within 4 pt of the straight line and never sweeps up over setup's title.
    public static func arcControl(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let distance = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - min(8, distance * 0.18))
    }

    /// The grab point on the card: where the hand holds it (the card's top-left plus this).
    public static let grabOffset = CGSize(width: 48, height: 37)
    /// How much the card's image grows when the demo lifts it.
    public static let lift: CGFloat = 1.03

    /// Where the demo lets go and how far the card's image has shrunk there (it shrinks as it travels): small enough that
    /// the lifted image fits inside the list's zone with 6 pt to spare, held at the grab point; the drop point moved only
    /// as far as it takes to keep the image inside the zone (so it never hangs out of System Settings or over the pane's text).
    public static func landing(card: CGSize, zone: CGRect, drop: CGPoint) -> (point: CGPoint, scale: CGFloat) {
        guard card.width > 0, card.height > 0, zone.width > 24, zone.height > 12 else { return (drop, 1) }
        let fit = min(1, (zone.width - 24) / (card.width * lift), (zone.height - 12) / (card.height * lift))
        let s = fit * lift
        let x = min(max(drop.x, zone.minX + 6 + grabOffset.width * s), zone.maxX - 6 - (card.width - grabOffset.width) * s)
        let y = min(max(drop.y, zone.minY + 6 + grabOffset.height * s), zone.maxY - 6 - (card.height - grabOffset.height) * s)
        return (CGPoint(x: x, y: y), fit)
    }

    /// The card's image held by its grab point at `held`, at `scale`.
    public static func ghostRect(card: CGSize, held: CGPoint, scale: CGFloat) -> CGRect {
        CGRect(x: held.x - grabOffset.width * scale, y: held.y - grabOffset.height * scale, width: card.width * scale, height: card.height * scale)
    }

    /// Reduce Motion's still arrow: from beside the card (its trailing edge, or its leading edge when System Settings
    /// is on setup's left) to just outside the list's zone, level with the drop point, bowing down a little: it stays off
    /// the cards' text and off System Settings' sidebar header and rows' names.
    public static func stillArrow(card: CGRect, zone: CGRect, drop: CGPoint) -> (from: CGPoint, control: CGPoint, to: CGPoint) {
        let leftward = zone.midX < card.midX
        let y = min(max(drop.y, zone.minY + 12), zone.maxY - 12)
        let a = CGPoint(x: leftward ? card.minX - 8 : card.maxX + 8, y: card.midY)
        let b = CGPoint(x: leftward ? zone.maxX + 6 : zone.minX - 6, y: y)
        let distance = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
        return (a, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + min(40, distance * 0.08)), b)
    }
}

/// The demo's timing. Pure (the checks pin it).
public enum PermissionDemo {
    /// One play; plays back to back at first; then one play every `period`; the first starts this long after placement.
    public static let play: Double = 3.2, firstPlays = 3, period: Double = 6, firstDelay: Double = 0.4

    /// Time inside the current play for `elapsed` seconds since placement, or nil while resting between plays.
    public static func local(_ elapsed: Double) -> Double? {
        let t = elapsed - firstDelay
        guard t >= 0 else { return nil }
        if t < play * Double(firstPlays) { return t.truncatingRemainder(dividingBy: play) }
        let r = (t - play * Double(firstPlays)).truncatingRemainder(dividingBy: period)
        return r < play ? r : nil
    }

    public struct Frame: Equatable, Sendable {
        public var hand: Double = 0, closed = false, ghost: Double = 0, scale: Double = 1, shadow: Double = 6
        /// Along the path, 0 (the card) to 1 (the drop point).
        public var progress: Double = 0
    }

    /// cubic-bezier(.42, 0, .58, 1).
    public static func ease(_ u: Double) -> Double {
        let u = min(max(u, 0), 1)
        func bez(_ s: Double, _ p1: Double, _ p2: Double) -> Double { 3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s }
        var lo = 0.0, hi = 1.0
        for _ in 0..<30 { let mid = (lo + hi) / 2; if bez(mid, 0.42, 0.58) < u { lo = mid } else { hi = mid } }
        return bez((lo + hi) / 2, 0, 1)
    }

    /// One moment of a play (`t` seconds in): hand in (0-0.3), grab and lift (0.3-0.5), travel (0.5-1.8), drop (1.8-2.1), hand out (2.1-2.4), rest (2.4-3.2).
    public static func frame(_ t: Double) -> Frame {
        var f = Frame()
        switch t {
        case ..<0.3:
            f.hand = max(0, t) / 0.3
        case ..<0.5:
            let u = (t - 0.3) / 0.2
            f.hand = 1; f.closed = true; f.ghost = 0.92 * u; f.scale = 1 + 0.03 * u; f.shadow = 6 + 12 * u
        case ..<1.8:
            let u = (t - 0.5) / 1.3
            f.hand = 1; f.closed = true; f.ghost = 0.92; f.scale = 1.03; f.shadow = 18
            f.progress = ease(u)
        case ..<2.1:
            let d = (t - 1.8) / 0.3
            f.hand = 1; f.closed = d < 0.34; f.progress = 1
            f.ghost = 0.92 * (1 - d); f.scale = 1.03 - 0.07 * d; f.shadow = 18
        case ..<2.4:
            f.hand = 1 - (t - 2.1) / 0.3; f.progress = 1
        default:
            break
        }
        return f
    }

    /// A point on the demo's arc.
    public static func point(_ progress: Double, from a: CGPoint, to b: CGPoint) -> CGPoint {
        let c = PermissionPair.arcControl(from: a, to: b), e = CGFloat(progress)
        return CGPoint(x: (1 - e) * (1 - e) * a.x + 2 * (1 - e) * e * c.x + e * e * b.x,
                       y: (1 - e) * (1 - e) * a.y + 2 * (1 - e) * e * c.y + e * e * b.y)
    }
}

/// When the helper goes away. Pure, so the checks pin it.
public enum PermissionDragGuideEnd: String, Equatable, Sendable {
    /// `listed` is kept for the record but never ends the helper (rc-018 RC3 B4): a row that appeared without the
    /// permission reading allowed (added off, or an older copy's) is the card's next line, "Turn on …".
    case granted, listed, settingsClosed, paneChanged, left
    /// One read of the helper's tick. Only the permission read ends it from System Settings' side; DayDream's row
    /// (`listedNow`, `listedAtStart`) never does. `title`/`firstTitle`: System Settings' window title now and when the
    /// zone was found (the pane's name, in any language).
    public static func check(granted: Bool, settingsRunning: Bool, windowMissingFor: TimeInterval, listedNow: Bool,
                             listedAtStart: Bool?, title: String?, firstTitle: String?) -> PermissionDragGuideEnd? {
        if granted { return .granted }
        if !settingsRunning || windowMissingFor >= 1.5 { return .settingsClosed }
        if let title, let firstTitle, !title.isEmpty, title != firstTitle { return .paneChanged }
        return nil
    }
}

/// The helper's one line on the card it runs for (Accessibility's or Input Monitoring's). The overlay itself has no words.
public enum PermissionDragGuideText {
    public static let cardLine = "Drag this card into the list."
}

/// rc-018 RC3 B4: DayDream's row in System Settings' list, as Accessibility reads it (the Input Monitoring step only:
/// in the Accessibility step DayDream can't read System Settings). `unknown`: not read (yet).
public enum PermissionListRow: String, Equatable, Sendable {
    case unknown, none, off, on
}

/// rc-018 RC3 B2/B4/B8: the one line on the card the helper runs for (and on any card whose drag ended badly). Pure.
public enum PermissionCardLine: String, Equatable, Sendable {
    case drag, dragOrTurnOn, turnOn, reAdd, password, passwordOrTurnOn, droppedOutside, appMoved

    /// A row on in System Settings while the permission still reads off this long: the row is an older copy's (its code
    /// requirement no longer matches): remove it and add DayDream again.
    public static let rowOnWait: TimeInterval = 3
    /// The Accessibility step (no row to read): this long after a drop on System Settings without the permission
    /// reading allowed, the remove-and-add-again step.
    public static let afterDropWait: TimeInterval = 8

    /// Since when DayDream's row has read on with the permission still off (`rowOnFor` counts from it). The clock runs only
    /// while no password prompt or sheet is up: a switch that reads on while macOS still asks for the password (or shows
    /// its own sheet) is not a stale row, so the remove-and-add-again step never shows over the prompt (UNVERIFIED how
    /// long System Settings shows the switch on before the grant lands; this holds either way). Pure.
    public static func rowOnClock(row: PermissionListRow, promptUp: Bool, since: Date?, now: Date) -> Date? {
        guard row == .on, !promptUp else { return nil }
        return since ?? now
    }

    /// The Accessibility step's drop clock (`sinceDrop` counts from it): while a password or Touch ID prompt is up it
    /// starts over, so the 8 s run from the moment the prompt went, never while the person is still typing. Pure.
    public static func dropClock(droppedAt: Date?, promptUp: Bool, now: Date) -> Date? {
        guard droppedAt != nil, promptUp else { return droppedAt }
        return now
    }

    /// rc-018 RC3 review: a drop starts that clock only when System Settings took it (an operation, not a drop that
    /// missed the list), and never once a password prompt was dismissed: the password line then stands until the next
    /// grab, never replaced by a step to remove a row that may not exist. Pure.
    public static func dropStartsClock(_ outcome: PermissionDropOutcome, operation: NSDragOperation, promptDismissed: Bool) -> Bool {
        outcome == .intoSettings && !operation.isEmpty && !promptDismissed
    }

    public func text(appName: String) -> String {
        switch self {
        case .drag: return PermissionDragGuideText.cardLine
        case .dragOrTurnOn: return "Drag this card into the list, or turn \(appName) on if it\u{2019}s already there."
        case .turnOn: return "Turn on \(appName) in the list."
        case .reAdd: return "Select \(appName), remove it with the minus (\u{2212}) button, then drag this card in again."
        case .password: return "macOS needs your Mac\u{2019}s administrator password to add \(appName). Drag it again."
        case .passwordOrTurnOn:
            return "macOS needs your Mac\u{2019}s administrator password to add \(appName). Drag it again, or turn it on if it\u{2019}s listed."
        case .droppedOutside: return "Dropped outside System Settings. Drag this card into its list."
        case .appMoved: return "\(appName) was moved. Put it back, then drag this card again."
        }
    }

    /// Something went wrong (drawn orange, not blue).
    public var warns: Bool {
        switch self {
        case .password, .passwordOrTurnOn, .droppedOutside, .appMoved: return true
        case .drag, .dragOrTurnOn, .turnOn, .reAdd: return false
        }
    }

    /// The guided card's line. `canReadRow`: Accessibility reads System Settings' list (the Input Monitoring step);
    /// `row`: DayDream's row there; `rowOnFor`: how long it has read on with the permission still off; `returns`: comings
    /// back to DayDream for this permission (`PermissionReturns`); `sinceDrop`: since the last drop on System Settings;
    /// `promptDismissed`: a password or Touch ID prompt went away with no row and no grant. nil: keep the line shown.
    /// Without a row to read (the Accessibility step), the line says both ways on, since a drop may have added the row
    /// switched off (UNVERIFIED which way System Settings adds it).
    public static func of(canReadRow: Bool, row: PermissionListRow, rowOnFor: TimeInterval, returns: Int, sinceDrop: TimeInterval?,
                          promptDismissed: Bool) -> PermissionCardLine? {
        if canReadRow {
            switch row {
            case .off: return .turnOn
            case .on: return rowOnFor >= rowOnWait ? .reAdd : nil
            case .none, .unknown: return promptDismissed ? .password : .drag
            }
        }
        // B8 (review): a dismissed password prompt's line wins until the next grab (no row may have been added).
        if promptDismissed { return .passwordOrTurnOn }
        if returns >= PermissionReturns.threshold || (sinceDrop ?? 0) >= afterDropWait { return .reAdd }
        return .dragOrTurnOn
    }
}

/// Whether the helper is running, for the card's line (`PermissionGrantView`).
public final class PermissionDragGuideStatus: ObservableObject, @unchecked Sendable {
    public static let shared = PermissionDragGuideStatus()
    /// Set by the helper; the renders set it to draw the card as it looks while the helper runs.
    @Published public var running = false
    /// The card it runs for: Accessibility's (true) or Input Monitoring's.
    @Published public var forAccessibility = false
    /// rc-018 RC3 B5: the pair is placed (setup moved beside System Settings): only then does the card say its line.
    @Published public var placed = false
    /// The guided card's line (`PermissionCardLine.of`, each tick).
    @Published public var line: PermissionCardLine = .drag
    /// B7: setup gave way to the compact drag panel.
    @Published public var compact = false
    /// B2: a drag that ended outside System Settings, or with the app moved, and the card it came from
    /// (`DaydreamPermission.rawValue`), until the next grab.
    @Published public var drop: PermissionDropOutcome?
    public private(set) var dropCard = ""
    /// Comings back to DayDream per permission (the page's `PermissionReturns`), for the line.
    public var returns: [String: Int] = [:]

    /// The line a card shows for how its last drag ended, if any.
    public func dropLine(card: String) -> PermissionCardLine? {
        guard dropCard == card else { return nil }
        switch drop {
        case .outside?: return .droppedOutside
        case .appMoved?: return .appMoved
        default: return nil
        }
    }
    func grabbed() { if drop != nil { drop = nil } }
    func dropped(_ outcome: PermissionDropOutcome, card: String) {
        let shown: PermissionDropOutcome? = outcome == .outside || outcome == .appMoved ? outcome : nil
        dropCard = card
        if drop != shown { drop = shown }
    }
}

/// Test builds only (Live Test, debug): where the helper put things, in screen coordinates (top-left origin), so a live
/// run can be checked without a screenshot (`log stream --predicate 'category == "drag-guide"'`). Rects and points
/// only, never a name or a title.
enum PermissionDragGuideLog {
    #if DEBUG || DAYDREAM_LIVETEST
    static let log = Logger(subsystem: "com.getnorthlight.daydream", category: "drag-guide")
    static let permReadLog = Logger(subsystem: "com.getnorthlight.daydream", category: "perm-read")
    #endif
    /// The permission page's reads (`PermissionGrantView.refresh`): AXIsProcessTrusted / CGPreflightListenEventAccess
    /// results and what the cards show, each tick. Booleans only.
    static func permRead(_ line: @autoclosure () -> String) {
        #if DEBUG || DAYDREAM_LIVETEST
        let text = line()
        permReadLog.notice("\(text, privacy: .public)")
        #endif
    }
    static func note(_ line: @autoclosure () -> String) {
        #if DEBUG || DAYDREAM_LIVETEST
        let text = line()
        log.notice("\(text, privacy: .public)")
        #endif
    }
    static func r(_ rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return String(format: "(%.0f,%.0f %.0fx%.0f)", rect.minX, rect.minY, rect.width, rect.height)
    }
    static func p(_ point: CGPoint) -> String { String(format: "(%.0f,%.0f)", point.x, point.y) }
}

/// System Settings through the Accessibility API, read and moved; nothing else in it is touched.
enum SettingsWindowAX {
    static let bundle = PermissionWindowFloat.systemSettingsBundle

    static func running() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first { !$0.isTerminated }
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// System Settings' window (top-left-origin rects), nil until it exists. A window whose role isn't AXWindow
    /// (as while the screen is locked) doesn't count.
    static func window(pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }  // never an Accessibility call without it (permission-prompt-checks)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var candidates: [AXUIElement] = []
        if let main = attribute(app, kAXMainWindowAttribute), CFGetTypeID(main) == AXUIElementGetTypeID() { candidates.append(main as! AXUIElement) }
        candidates += (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let found = candidates.first { (attribute($0, kAXRoleAttribute) as? String) == kAXWindowRole as String && frame($0) != nil }
        if let found { AXUIElementSetMessagingTimeout(found, 0.3) }
        return found
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    static func title(_ element: AXUIElement) -> String? { attribute(element, kAXTitleAttribute) as? String }

    static func minimized(_ element: AXUIElement) -> Bool { (attribute(element, kAXMinimizedAttribute) as? Bool) ?? false }

    /// An authentication sheet over the window (System Settings asks for a password before some changes).
    static func hasSheet(_ element: AXUIElement) -> Bool {
        ((attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).contains { (attribute($0, kAXRoleAttribute) as? String) == "AXSheet" }
    }

    /// Moves and sizes the window (top-left-origin rect); true when the move took.
    static func setFrame(_ element: AXUIElement, _ rect: CGRect) -> Bool {
        var point = rect.origin, size = rect.size
        guard let position = AXValueCreate(.cgPoint, &point), let extent = AXValueCreate(.cgSize, &size) else { return false }
        let moved = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position) == .success
        _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, extent)
        // Again: a window that grew first may have been held back by the screen edge.
        _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        return moved
    }

    /// The Input Monitoring list (or its "No Items" text) in the window's right pane: the largest table, outline or
    /// list right of the sidebar. Bounded: at most 800 elements, 24 levels, 0.3 s per call; it stops at "No Items" (a new
    /// Mac's empty list). `root`: where to look (the window, or the empty list's container found before). `empty`: the
    /// container of "No Items" when the list is empty (`element` is then nil), for the next scan to read only that.
    static func list(in root: AXUIElement, windowFrame: CGRect) -> (frame: CGRect, element: AXUIElement?, empty: AXUIElement?)? {
        var best: (frame: CGRect, element: AXUIElement)?
        var queue: [(AXUIElement, Int)] = [(root, 0)], visited = 0
        let paneLeft = windowFrame.minX + min(200, windowFrame.width * 0.25)
        while !queue.isEmpty, visited < 800 {
            let (element, depth) = queue.removeFirst(); visited += 1
            AXUIElementSetMessagingTimeout(element, 0.3)
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            if ["AXTable", "AXOutline", "AXList"].contains(role), let f = frame(element), f.minX >= paneLeft, f.width >= 40, f.height >= 20 {
                if best == nil || f.width * f.height > best!.frame.width * best!.frame.height { best = (f, element) }
                continue
            }
            if best == nil, role == "AXStaticText", (attribute(element, kAXValueAttribute) as? String) == "No Items", let text = frame(element), text.minX >= paneLeft {
                // An empty list: the box around "No Items", as wide as the pane.
                let container = attribute(element, kAXParentAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
                return (CGRect(x: paneLeft + 40, y: text.midY - 30, width: windowFrame.maxX - 20 - (paneLeft + 40), height: 60), nil, container ?? root)
            }
            if depth < 24 { for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { queue.append((child, depth + 1)) } }
        }
        return best.map { ($0.frame, $0.element, nil) }
    }

    /// The list's rows (for the demo's landing, which never lands on one), at most 60.
    static func rows(in list: AXUIElement) -> [CGRect] {
        ((attribute(list, kAXRowsAttribute) as? [AXUIElement]) ?? []).prefix(60).compactMap(frame)
    }

    /// The row that says exactly `name` (DayDream's row: dragged in, or an older copy's), nil when none: its frame
    /// (`.zero` when unreadable), and its switch's frame and value (rc-018 RC3 B4; nil when no switch was found).
    static func row(named name: String, in list: AXUIElement) -> (frame: CGRect, switchFrame: CGRect?, on: Bool?)? {
        func says(_ root: AXUIElement) -> AXUIElement? {
            var queue: [(AXUIElement, Int)] = [(root, 0)], visited = 0
            while !queue.isEmpty, visited < 400 {
                let (element, depth) = queue.removeFirst(); visited += 1
                for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] where (attribute(element, key) as? String) == name { return element }
                if depth < 8 { for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { queue.append((child, depth + 1)) } }
            }
            return nil
        }
        for row in ((attribute(list, kAXRowsAttribute) as? [AXUIElement]) ?? []).prefix(60) where says(row) != nil {
            let control = toggle(in: row)
            return (frame(row) ?? .zero, control.flatMap(frame), control.flatMap(isOn))
        }
        guard let text = says(list) else { return nil }
        // No rows attribute: the name's own row is its parent (as far as the switch goes).
        let parent = attribute(text, kAXParentAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        let control = parent.flatMap(toggle(in:))
        return (frame(text) ?? .zero, control.flatMap(frame), control.flatMap(isOn))
    }

    /// The switch in a row (a check box, or a switch): read only, never pressed.
    static func toggle(in row: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(row, 0)], visited = 0
        while !queue.isEmpty, visited < 80 {
            let (element, depth) = queue.removeFirst(); visited += 1
            AXUIElementSetMessagingTimeout(element, 0.3)
            if (attribute(element, kAXRoleAttribute) as? String) == "AXCheckBox" || (attribute(element, kAXSubroleAttribute) as? String) == "AXSwitch" { return element }
            if depth < 6 { for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { queue.append((child, depth + 1)) } }
        }
        return nil
    }

    /// A switch's value: on (1) or off (0); nil when it says neither.
    static func isOn(_ control: AXUIElement) -> Bool? {
        guard let value = attribute(control, kAXValueAttribute) else { return nil }
        if let number = value as? NSNumber { return number.intValue != 0 }
        return nil
    }

    /// What the window server says (top-left origin; needs no permission): System Settings' main window (layer 0, at
    /// least 200 pt each way, the largest), and whether an authentication window is on screen.
    static func server(pid: pid_t?) -> (frame: CGRect?, auth: Bool, id: CGWindowID?) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return (nil, false, nil) }
        var best: CGRect?, auth = false, id: CGWindowID?
        for info in list {
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            if owner == "SecurityAgent" || owner == "coreautha" { auth = true }
            guard let pid, (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 200, rect.height > 200 else { continue }
            if best == nil || rect.width * rect.height > best!.width * best!.height {
                best = rect; id = (info[kCGWindowNumber as String] as? Int).map(CGWindowID.init)
            }
        }
        return (best, auth, id)
    }

    /// Only that one window (the 60 Hz path while a button is down or it moves): its frame while it is on screen.
    static func server(window id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: bounds),
              rect.width >= 200, rect.height > 200 else { return nil }
        return rect
    }
}

/// What the overlay draws, in the overlay's own coordinates (top-left origin).
@MainActor final class PermissionDragGuideModel: ObservableObject {
    @Published var zone: CGRect = .zero
    @Published var card: CGRect = .zero
    @Published var drop: CGPoint = .zero
    @Published var ghost: NSImage?
    @Published var reduceMotion = false
    @Published var mode: PermissionDragGuideCanvas.Mode = .idle
    @Published var check: CGPoint?
    /// When the demo's clock started; nil hides the demo (the person is dragging, or it is resting before it resumes).
    @Published var demoStart: Date?
    @Published var fade: Double = 1
    /// rc-018 RC3 B4: DayDream's row is listed but off: the pointing hand at its switch (nothing else drawn).
    @Published var pointAt: CGPoint?
}

/// The helper: one at a time, started by setup's Accessibility or Input Monitoring card (`PermissionGrantView`) and ended
/// by it.
@MainActor public final class PermissionDragGuide {
    public static let shared = PermissionDragGuide()

    /// The reads it makes; the checks pass their own.
    public struct Reads {
        public var accessibility: () -> Bool
        public var inputMonitoring: () -> Bool
        public var reduceMotion: () -> Bool
        /// rc-018 RC3 B5: a left button is down or a card's drag runs: no window moves until it's over.
        public var pressed: () -> Bool
        public init(accessibility: @escaping () -> Bool = { AXIsProcessTrusted() },
                    inputMonitoring: @escaping () -> Bool = { CGPreflightListenEventAccess() },
                    reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
                    pressed: @escaping () -> Bool = { PermissionDragGuide.pressedOrDragging() }) {
            self.accessibility = accessibility; self.inputMonitoring = inputMonitoring; self.reduceMotion = reduceMotion; self.pressed = pressed
        }
    }

    public private(set) var active = false
    /// How it ended last (nil while running or never run). The checks read it.
    public private(set) var lastEnd: PermissionDragGuideEnd?
    /// System Settings took the move next to setup (false: only setup moved, next to where System Settings is).
    public private(set) var movedSettings = false
    /// How many times it wrote System Settings' frame (each `setFrame`), and the placement it aimed for.
    public private(set) var settingsWrites = 0
    public private(set) var placement: PermissionPair.Option?
    /// The list's zone came from the list Accessibility found (false: the estimate).
    public private(set) var zoneFromList = false
    /// Where it last put the list's zone and found the card (AppKit coordinates). The checks and renders read them.
    public private(set) var zoneOnScreen: CGRect?
    public private(set) var cardOnScreen: CGRect?

    private weak var ownWindow: NSWindow?
    private var source: () -> CGRect? = { nil }
    private var appURL = Bundle.main.bundleURL
    private var appName = "DayDream"
    private var reads = Reads()
    /// The card it runs for (Accessibility's or Input Monitoring's) and that permission's read: allowed ends it.
    public private(set) var forAccessibility = false
    private var granted: () -> Bool { forAccessibility ? reads.accessibility : reads.inputMonitoring }
    /// The last layout it logged (test builds), so a line goes out only when something moved.
    private var loggedLayout = ""
    private var overlay: NSPanel?
    private let model = PermissionDragGuideModel()
    private var timer: Timer?
    private var startedAt = Date()
    private var generation = 0
    private var settingsPID: pid_t?
    private var settingsWindow: AXUIElement?
    /// System Settings' window number (the window server's), for the one-window read at 60 Hz.
    private var settingsWindowID: CGWindowID?
    private var listElement: AXUIElement?
    /// The empty list's container ("No Items"): later scans read only it until it holds no list.
    private var emptyScope: AXUIElement?
    /// System Settings' title when the helper started (it was open on another pane) and at the last scan: the pane
    /// counts as Input Monitoring's only once its title held still (`paneSettled`).
    private var titleAtStart: String?
    private var lastScanTitle: String?
    /// System Settings' window as last read (top-left origin), and when the waiting first saw it.
    private var settingsFrame: CGRect?
    private var firstSeen: Date?
    private var lastSettingsMove = Date.distantPast
    /// The list (or the estimate) relative to System Settings' window origin, and its rows likewise.
    private var listOffset: CGRect?
    private var rowsOffset: [CGRect] = []
    private var listedAtStart: Bool?
    private var firstTitle: String?
    private var missingSince: Date?
    private var lastScan = Date.distantPast
    private var lastSlow = Date.distantPast
    private var terminateObserver: NSObjectProtocol?
    /// Running: placement finished and the overlay may show.
    private var placed = false
    /// After placement: the frame it placed System Settings at and until when it may redo the move once (System
    /// Settings re-centering itself); nil once the person moved it (then never again).
    private var placedFrame: CGRect?
    private var watchUntil: Date?
    private var hidden = false
    /// The real drag: the card is held, the pointer was last over the list, and the wait for the row after a drop.
    private var dragging = false
    private var pointerInside = false
    private var awaitingRowUntil: Date?
    private var resumeDemoAt: Date?
    private var celebrating = false
    /// Where the button went down on the card (AppKit coordinates): a grab only once it moved 4 pt (a click is no grab).
    private var pressedAt: CGPoint?
    private var buttonWasDown = false
    /// rc-018 RC3 B6: the card was grabbed in this run: the demo never plays again.
    public private(set) var demoDone = false
    /// B4: DayDream's row as last read, since when it reads on (the permission still off), and whether the list can be
    /// read at all (Accessibility on, the list found or still being looked for).
    public private(set) var row: PermissionListRow = .unknown
    private var rowOnSince: Date?
    private var switchOffset: CGRect?
    private var placedAt: Date?
    /// B8: a password or Touch ID prompt (System Settings' sheet, or macOS's authentication window) is up, when the last
    /// one went away, and that it went away with no row and no grant.
    private var promptUp = false
    private var promptEndedAt: Date?
    private var promptDismissed = false
    /// B4: the last drop on System Settings' window.
    private var droppedAt: Date?
    /// B5: a move of setup held back while a press or a drag was on (System Settings' frame to go next to).
    private var pendingMove: CGRect?
    /// B7: the compact drag panel (setup's card alone) while setup can't sit beside System Settings, and setup hidden for it.
    private var compactPanel: NSPanel?
    private let compactCard = PermissionCardAnchorBox()
    private var hidSetup = false

    /// The overlay's level: above DayDream's floating permission window and System Settings.
    public static let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    /// How long it waits for System Settings' window.
    public static let windowWait: TimeInterval = 4

    /// `window`: DayDream's setup window. `source`: the card on screen (AppKit coordinates). `forAccessibility`: the
    /// Accessibility card started it (System Settings can't be moved then: only setup moves, next to it).
    public func start(window: NSWindow?, appURL: URL, appName: String, source: @escaping () -> CGRect?, reads: Reads = Reads(),
                      forAccessibility: Bool = false) {
        stop(.left)
        lastEnd = nil; movedSettings = false; settingsWrites = 0; placement = nil; zoneFromList = false; zoneOnScreen = nil; cardOnScreen = nil
        active = true; startedAt = Date(); generation += 1; loggedLayout = ""
        self.forAccessibility = forAccessibility
        let status = PermissionDragGuideStatus.shared
        status.forAccessibility = forAccessibility
        status.placed = false
        status.line = PermissionCardLine.of(canReadRow: reads.accessibility(), row: .unknown, rowOnFor: 0,
                                            returns: status.returns[forAccessibility ? "accessibility" : "inputMonitoring"] ?? 0,
                                            sinceDrop: nil, promptDismissed: false) ?? .drag
        status.running = true
        ownWindow = window; self.source = source; self.appURL = appURL; self.appName = appName; self.reads = reads
        demoDone = false; row = .unknown; rowOnSince = nil; switchOffset = nil; placedAt = nil
        promptUp = false; promptEndedAt = nil; promptDismissed = false; droppedAt = nil; pendingMove = nil
        settingsWindow = nil; settingsWindowID = nil; listElement = nil; emptyScope = nil; listOffset = nil; rowsOffset = []
        lastScan = .distantPast; lastSlow = .distantPast; lastScanTitle = nil
        listedAtStart = nil; firstTitle = nil; missingSince = nil; settingsPID = nil; settingsFrame = nil; firstSeen = nil
        placed = false; placedFrame = nil; watchUntil = nil; hidden = false; dragging = false; pointerInside = false
        awaitingRowUntil = nil; resumeDemoAt = nil; celebrating = false; pressedAt = nil; buttonWasDown = false
        // System Settings already open (setup's Accessibility card opened it): its pane now, which the deep link replaces.
        titleAtStart = reads.accessibility() ? SettingsWindowAX.running().flatMap { SettingsWindowAX.window(pid: $0.processIdentifier) }.flatMap(SettingsWindowAX.title) : nil
        model.reduceMotion = reads.reduceMotion(); model.mode = .idle; model.check = nil; model.demoStart = nil; model.fade = 1; model.ghost = nil
        model.pointAt = nil
        // Nothing moves before System Settings' window exists (it may open on another display or Space, or late).
        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == SettingsWindowAX.bundle else { return }
            MainActor.assumeIsolated { PermissionDragGuide.shared.stop(.settingsClosed) }
        }
        timer = Self.commonTimer(0.1) { PermissionDragGuide.shared.waitForSettings() }
    }

    /// Ends the helper: the overlay goes away. Safe to call any time.
    public func stop(_ reason: PermissionDragGuideEnd = .left) {
        timer?.invalidate(); timer = nil
        generation += 1
        if let terminateObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver) }
        terminateObserver = nil
        overlay?.orderOut(nil); overlay = nil
        hideCompact()
        if active { lastEnd = reason }
        active = false
        if PermissionDragGuideStatus.shared.running { PermissionDragGuideStatus.shared.running = false }
        if PermissionDragGuideStatus.shared.placed { PermissionDragGuideStatus.shared.placed = false }
    }

    /// rc-018 RC3 B5: the left button is down, or a card's drag runs.
    public nonisolated static func pressedOrDragging() -> Bool {
        NSEvent.pressedMouseButtons & 1 != 0 || (Thread.isMainThread && MainActor.assumeIsolated { PermissionCardDrag.shared.dragging })
    }

    /// A card's drag ended (`PermissionCardDrag`): a drop System Settings took starts the Accessibility step's wait for
    /// the remove-and-add-again line (B4), unless a dismissed password prompt's line stands (`dropStartsClock`).
    nonisolated static func noteDrop(_ outcome: PermissionDropOutcome, operation: NSDragOperation) {
        let at = Date()
        let note = { MainActor.assumeIsolated { PermissionDragGuide.shared.dropped(outcome, operation: operation, at: at) } }
        if Thread.isMainThread { note() } else { DispatchQueue.main.async { note() } }
    }
    func dropped(_ outcome: PermissionDropOutcome, operation: NSDragOperation, at: Date) {
        guard PermissionCardLine.dropStartsClock(outcome, operation: operation, promptDismissed: promptDismissed) else { return }
        droppedAt = at
    }
    /// The checks: when the last drop's clock started (nil: none runs).
    public var dropClockForChecks: Date? { droppedAt }

    /// The page's returns changed (`PermissionDragGuideStatus.returns`): the line follows now, not at the next tick.
    public func returnsChanged() { if active, placed { updateLine() } }

    /// The card's drag began (`PermissionCardDrag.begin`, any thread): the demo goes at once.
    public nonisolated static func noteGrab() {
        if Thread.isMainThread { MainActor.assumeIsolated { PermissionDragGuide.shared.grabbed() } }
        else { DispatchQueue.main.async { MainActor.assumeIsolated { PermissionDragGuide.shared.grabbed() } } }
    }

    /// The person grabbed the real card (either card): the demo goes, for the rest of this run (rc-018 RC3 B6).
    public func grabbed() {
        guard active, !celebrating else { return }
        dragging = true; resumeDemoAt = nil; awaitingRowUntil = nil; pressedAt = nil; demoDone = true
        promptDismissed = false; promptEndedAt = nil; droppedAt = nil
        if model.demoStart != nil { model.demoStart = nil }
    }

    /// The top of the primary screen (the one with the menu bar, `NSScreen.screens[0]`): every top-left-origin rect
    /// (window server, Accessibility) flips on it, whatever screen the overlay is on.
    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
    private func appKit(_ rect: CGRect) -> CGRect { PermissionPair.flipped(rect, primaryHeight: primaryHeight) }

    /// The screen holding a top-left-origin rect's center (else setup's, else the main one).
    private func screen(holding rect: CGRect?) -> NSScreen? {
        if let rect {
            let center = appKit(rect)
            if let s = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: center.midX, y: center.midY)) }) { return s }
            if let s = NSScreen.screens.first(where: { $0.frame.intersects(center) }) { return s }
        }
        return ownWindow?.screen ?? NSScreen.main
    }

    private static var stageManager: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.integer(forKey: "GloballyEnabled") == 1
    }

    /// Waits (100 ms reads, at most 4 s) for System Settings' window to settle: two equal reads in a row, or 600 ms
    /// after it first appeared. Not on screen (another Space) counts as not there yet.
    private func waitForSettings() {
        guard active else { return }
        if granted() { stop(.granted); return }
        let waited = Date().timeIntervalSince(startedAt)
        guard let app = SettingsWindowAX.running() else {
            if waited > Self.windowWait { stop(.settingsClosed) }
            return
        }
        settingsPID = app.processIdentifier
        let read = SettingsWindowAX.server(pid: app.processIdentifier)
        let now = read.frame
        if let id = read.id { settingsWindowID = id }
        let previous = settingsFrame
        settingsFrame = now
        if now != nil, firstSeen == nil { firstSeen = Date() }
        let settled = PermissionPair.settled(previous, now) || (now != nil && firstSeen.map { Date().timeIntervalSince($0) >= 0.6 } == true)
        guard settled, let frame = now else {
            if waited > Self.windowWait { stop(.settingsClosed) }
            return
        }
        timer?.invalidate(); timer = nil
        let run = generation
        Task { @MainActor in await self.place(frame, run: run) }
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    /// Steps d-h: System Settings beside setup (when it may be moved), read back and retried; then setup next to where
    /// System Settings actually is; then the overlay.
    private func place(_ first: CGRect, run: Int) async {
        guard active, run == generation, let pid = settingsPID else { return }
        var actual = first
        let trusted = reads.accessibility()
        if trusted { settingsWindow = SettingsWindowAX.window(pid: pid) }
        if let own = ownWindow, let window = settingsWindow, let ownScreen = own.screen ?? NSScreen.main,
           let sScreen = screen(holding: actual),
           PermissionPair.writesSettings(settings: actual, screen: appKit(sScreen.frame), minimized: SettingsWindowAX.minimized(window), trusted: trusted) {
            let visible = appKit(ownScreen.visibleFrame), stage = Self.stageManager
            var target = PermissionPair.place(setup: appKit(own.frame), settings: actual, visible: visible, stageManager: stage)
            placement = target.option
            for wait in [0.0, 0.25, 0.5, 1.0] {
                if wait > 0 { await pause(wait) }
                // rc-018 RC3 B5: never while a press or a drag is on.
                guard await released(run) else { return }
                settingsWrites += 1
                _ = SettingsWindowAX.setFrame(window, target.settings)
                await pause(0.12)
                guard active, run == generation else { return }
                actual = SettingsWindowAX.server(pid: pid).frame ?? SettingsWindowAX.frame(window) ?? actual
                if PermissionPair.took(target.settings, actual) { movedSettings = true; break }
                if abs(actual.width - target.settings.width) > 1 {
                    // It took another width: aim again with the width it has now.
                    target = PermissionPair.place(setup: appKit(own.frame), settings: actual, visible: visible, stageManager: stage)
                    placement = target.option
                }
            }
            if movedSettings { placedFrame = actual; watchUntil = Date().addingTimeInterval(1.5) }
        }
        guard await released(run) else { return }
        settingsFrame = actual
        let setupBefore = ownWindow.map { appKit($0.frame) }
        moveSetup(nextTo: actual)
        await pause(0.3 + 0.15)
        guard active, run == generation else { return }
        PermissionDragGuideLog.note("placed step=\(forAccessibility ? "accessibility" : "inputMonitoring") trusted=\(trusted) option=\(placement?.rawValue ?? "none") "
            + "writes=\(settingsWrites) movedSettings=\(movedSettings) screen=\(PermissionDragGuideLog.r(screen(holding: actual).map { appKit($0.frame) })) "
            + "visible=\(PermissionDragGuideLog.r(screen(holding: actual).map { appKit($0.visibleFrame) })) settingsFirst=\(PermissionDragGuideLog.r(first)) "
            + "settings=\(PermissionDragGuideLog.r(actual)) setupBefore=\(PermissionDragGuideLog.r(setupBefore)) setup=\(PermissionDragGuideLog.r(ownWindow.map { appKit($0.frame) }))")
        placed = true; placedAt = Date()
        PermissionDragGuideStatus.shared.placed = true
        showOverlay()
        lastSlow = .distantPast
        frame()
        // The demo's clock: the first play starts `PermissionDemo.firstDelay` after placement (never once the card was
        // grabbed, or DayDream's row is already listed).
        if !demoDone, row != .off, row != .on { model.demoStart = Date() }
        timer = Self.commonTimer(1.0 / 60) { PermissionDragGuide.shared.frame() }
    }

    /// Waits while a press or a drag is on (rc-018 RC3 B5); false once this run ended.
    private func released(_ run: Int) async -> Bool {
        while active, run == generation, reads.pressed() { await pause(0.05) }
        return active && run == generation
    }

    /// A repeating main run loop timer in the common modes: it keeps firing while the person drags the card (DayDream is
    /// the drag source, so AppKit runs its run loop in event-tracking mode, where default-mode timers stop).
    private static func commonTimer(_ interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Step f: setup's window next to System Settings' actual frame, on its display (and Space), animated. rc-018 RC3:
    /// never during a press or a drag (B5: held until it's over); never over System Settings' list (B7: the compact drag
    /// panel instead, when setup can't fit beside it).
    private func moveSetup(nextTo settings: CGRect) {
        guard let own = ownWindow, let visible = visibleForChecks ?? screen(holding: settings).map({ appKit($0.visibleFrame) }) else { return }
        guard !reads.pressed() else { pendingMove = settings; return }
        pendingMove = nil
        let stage = visibleForChecks == nil && Self.stageManager
        let beside = PermissionPair.beside(setup: own.frame.size, settings: settings, visible: visible, stageManager: stage)
        if beside.compact { showCompact(settings: settings, visible: visible, stageManager: stage); return }
        hideCompact()
        let target = appKit(beside.frame)
        if !own.isOnActiveSpace {
            let behavior = own.collectionBehavior
            own.collectionBehavior.insert(.moveToActiveSpace)
            own.orderFront(nil)
            own.collectionBehavior = behavior
        }
        guard abs(target.minX - own.frame.minX) > 0.5 || abs(target.minY - own.frame.minY) > 0.5 else { return }
        if model.reduceMotion { own.setFrame(target, display: true); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            own.animator().setFrame(target, display: true)
        }
    }

    /// The checks only: setup's move next to System Settings at `settings` (top-left origin), as placement makes it,
    /// with `pressed` as the press read (no animation). True when `window` moved. The helper must not be running.
    /// `visible` (top-left origin) stands in for the screen's visible frame, so the window goes only where the check puts
    /// it (off every screen), never onto the Mac's own. The helper must not be running.
    public func moveForChecks(window: NSWindow, nextTo settings: CGRect, visible: CGRect, pressed: @escaping () -> Bool) -> Bool {
        guard !active else { return false }
        let before = window.frame
        ownWindow = window; model.reduceMotion = true; visibleForChecks = visible
        reads = Reads(accessibility: { false }, inputMonitoring: { false }, reduceMotion: { true }, pressed: pressed)
        moveSetup(nextTo: settings)
        let moved = window.frame != before
        hideCompact(); ownWindow = nil; reads = Reads(); visibleForChecks = nil
        return moved
    }
    /// Where the compact panel last went (top-left origin; the checks read it).
    public private(set) var lastCompactFrame: CGRect?

    /// The checks only: a move held back by a press goes once the button is up (the 60 Hz tick's step).
    public func releaseForChecks(window: NSWindow, visible: CGRect, pressed: @escaping () -> Bool) -> Bool {
        guard !active, let settings = pendingMove else { return false }
        let before = window.frame
        ownWindow = window; model.reduceMotion = true; visibleForChecks = visible
        reads = Reads(accessibility: { false }, inputMonitoring: { false }, reduceMotion: { true }, pressed: pressed)
        if !reads.pressed() { moveSetup(nextTo: settings) }
        let moved = window.frame != before
        hideCompact(); pendingMove = nil; ownWindow = nil; reads = Reads(); visibleForChecks = nil
        return moved
    }
    private var visibleForChecks: CGRect?

    /// B7: setup's card alone beside System Settings, at the compact panel's place; setup is hidden until the helper ends.
    private func showCompact(settings: CGRect, visible: CGRect, stageManager: Bool) {
        let panel: NSPanel
        if let compactPanel { panel = compactPanel } else {
            let card = PermissionCompactCard(appURL: appURL, appName: appName, forAccessibility: forAccessibility, box: compactCard)
            let host = NSHostingView(rootView: card)
            let size = host.fittingSize
            panel = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: PermissionPair.compactWidth, height: max(74, size.height))),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.contentView = host
            compactPanel = panel
        }
        let place = PermissionPair.compact(size: panel.frame.size, settings: settings, visible: visible, stageManager: stageManager)
        lastCompactFrame = place
        panel.setFrame(appKit(place), display: true)
        panel.orderFrontRegardless()
        if let own = ownWindow, own.isVisible { own.orderOut(nil); hidSetup = true }
        if !PermissionDragGuideStatus.shared.compact { PermissionDragGuideStatus.shared.compact = true }
    }

    /// The compact panel goes, and setup comes back where it was (never activating DayDream).
    private func hideCompact() {
        compactPanel?.orderOut(nil); compactPanel = nil
        if hidSetup { hidSetup = false; ownWindow?.orderFront(nil) }
        if PermissionDragGuideStatus.shared.compact { PermissionDragGuideStatus.shared.compact = false }
    }

    /// The card on screen (AppKit coordinates): the compact panel's while it shows, else setup's.
    private func cardFrame() -> CGRect? {
        if let compactPanel, let view = compactCard.view, view.window === compactPanel {
            return compactPanel.convertToScreen(view.convert(view.bounds, to: nil))
        }
        return source()
    }

    private func showOverlay() {
        guard overlay == nil else { return }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Click-through: it can never take the drop meant for System Settings' list, or any click.
        panel.ignoresMouseEvents = true
        panel.level = Self.overlayLevel
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.contentView = NSHostingView(rootView: PermissionDragGuideOverlay(model: model))
        overlay = panel
    }

    /// Every frame (60 Hz) once placed: the pointer during a real drag, System Settings' frame while it moves; the
    /// rest (the list, the end, the hiding) every 0.25 s.
    private func frame() {
        guard active, placed, let pid = settingsPID else { return }
        let now = Date()
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        let pointer = NSEvent.mouseLocation
        // The card pressed and moved 4 pt (a drag starting; a click on it is no grab): the demo goes in the same frame.
        let pressed = buttonDown && !buttonWasDown
        buttonWasDown = buttonDown
        if !buttonDown { pressedAt = nil }
        else if !dragging, !celebrating {
            if let at = pressedAt {
                if hypot(pointer.x - at.x, pointer.y - at.y) > 4 { pressedAt = nil; grabbed() }
            } else if pressed, let card = cardFrame(), card.contains(pointer) { pressedAt = pointer }
        }
        // rc-018 RC3 B5: a move held back by a press or a drag goes once it's over.
        if let held = pendingMove, !reads.pressed() { moveSetup(nextTo: held) }
        // System Settings' frame: every frame while it moves (or a button is down), else with the slow tick. The fast
        // reads look at its one window; the full window list (and the authentication check) only at 4 Hz.
        let slow = now.timeIntervalSince(lastSlow) >= 0.25
        if slow || buttonDown || now.timeIntervalSince(lastSettingsMove) < 0.4 {
            var read: (frame: CGRect?, auth: Bool, id: CGWindowID?) = (nil, false, nil)
            if slow || settingsWindowID == nil {
                read = SettingsWindowAX.server(pid: pid)
                if let id = read.id { settingsWindowID = id }
            } else if let id = settingsWindowID {
                read.frame = SettingsWindowAX.server(window: id)
            }
            let frame = read.frame ?? settingsWindow.flatMap(SettingsWindowAX.frame)
            if let frame, let old = settingsFrame, !PermissionPair.settled(old, frame) || abs(old.height - frame.height) > 1 { lastSettingsMove = now }
            if frame == nil { missingSince = missingSince ?? now } else { missingSince = nil }
            if let frame { settingsFrame = frame }
            if slow { slowTick(authOnScreen: read.auth) }
            guard active else { return }
            watchPlacement(buttonDown: buttonDown)
            layout()
        }
        // The real drag.
        if dragging {
            // Over the list's zone grown 12 pt (AppKit coordinates, as the pointer's).
            let inside = zoneOnScreen.map { $0.insetBy(dx: -12, dy: -12).contains(pointer) } ?? false
            if buttonDown {
                if inside != pointerInside {
                    pointerInside = inside
                    if inside { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                }
            } else {
                // Let go. rc-018 RC3 B6: the demo doesn't come back (it played until the first grab).
                dragging = false
                if pointerInside { awaitingRowUntil = now.addingTimeInterval(2.5); lastScan = .distantPast }
                pointerInside = false
            }
        }
        if let until = awaitingRowUntil, now > until, !celebrating { awaitingRowUntil = nil }
    }

    /// System Settings moved within 1.5 s of placement without the person: it re-centered itself; place it once more.
    /// The person moving it (a button down) or any move later: never written again.
    private func watchPlacement(buttonDown: Bool) {
        guard let placedFrame, let until = watchUntil, let frame = settingsFrame else { return }
        let moved = abs(frame.minX - placedFrame.minX) > 4 || abs(frame.minY - placedFrame.minY) > 4
        if Date() > until || (moved && buttonDown) { watchUntil = nil; return }
        guard moved, !reads.pressed(), let window = settingsWindow, let own = ownWindow, let ownScreen = own.screen else { return }
        watchUntil = nil
        let target = PermissionPair.place(setup: appKit(own.frame), settings: frame, visible: appKit(ownScreen.visibleFrame), stageManager: Self.stageManager)
        settingsWrites += 1
        _ = SettingsWindowAX.setFrame(window, target.settings)
        let run = generation
        Task { @MainActor in
            await self.pause(0.12)
            guard self.active, run == self.generation, let pid = self.settingsPID, let actual = SettingsWindowAX.server(pid: pid).frame else { return }
            self.settingsFrame = actual
            self.moveSetup(nextTo: actual)
        }
    }

    /// The list, the end conditions and whether the overlay shows.
    private func slowTick(authOnScreen: Bool) {
        lastSlow = Date()
        let running = SettingsWindowAX.running() != nil
        var listedNow = false
        var rowFrame: CGRect?
        let spacing: TimeInterval = awaitingRowUntil != nil ? 0.25 : listElement == nil ? 0.5 : 1
        if let window = settingsWindow, let frame = settingsFrame, Date().timeIntervalSince(lastScan) >= spacing {
            lastScan = Date()
            // The pane is Input Monitoring's once its title held still across two scans, 0.8 s after the start, and
            // (when System Settings was already open on another pane) changed or 2.5 s went by: only then are the
            // pane's title and whether DayDream was listed taken as the start's.
            let title = SettingsWindowAX.title(window)
            let since = Date().timeIntervalSince(startedAt)
            let paneSettled = title != nil && title == lastScanTitle && since >= 0.8 && (titleAtStart == nil || title != titleAtStart || since >= 2.5)
            lastScanTitle = title
            var found = emptyScope.flatMap { SettingsWindowAX.list(in: $0, windowFrame: frame) }
            if found == nil { emptyScope = nil; found = SettingsWindowAX.list(in: window, windowFrame: frame) }
            if let found {
                listOffset = found.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
                zoneFromList = true
                if firstTitle == nil, paneSettled { firstTitle = title }
                if let list = found.element {
                    listElement = list; emptyScope = nil
                    rowsOffset = SettingsWindowAX.rows(in: list).map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
                    let read = SettingsWindowAX.row(named: appName, in: list)
                    rowFrame = read?.frame
                    listedNow = read != nil
                    // rc-018 RC3 B4: the row's switch. A row whose switch can't be read counts as off ("Turn on …").
                    row = read == nil ? .none : read?.on == true ? .on : .off
                    switchOffset = read?.switchFrame.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
                    if listedAtStart == nil, paneSettled { listedAtStart = listedNow }
                } else {
                    // "No Items": DayDream isn't listed yet.
                    listElement = nil; rowsOffset = []; emptyScope = found.empty; row = .none; switchOffset = nil
                    if listedAtStart == nil, paneSettled { listedAtStart = false }
                }
            }
        }
        if let end = PermissionDragGuideEnd.check(granted: granted(), settingsRunning: running,
                                                  windowMissingFor: missingSince.map { Date().timeIntervalSince($0) } ?? 0,
                                                  listedNow: listedNow, listedAtStart: listedAtStart,
                                                  title: settingsWindow.flatMap(SettingsWindowAX.title), firstTitle: firstTitle) {
            // rc-018 RC3 B4: only a grant celebrates; a row that appeared without one is the "Turn on …" line below.
            if end == .granted { celebrate(end, row: rowFrame) } else { stop(end) }
            return
        }
        // Hidden, not ended: while an authentication sheet is up, or another app is in front.
        let front = NSWorkspace.shared.frontmostApplication
        let sheet = authOnScreen || settingsWindow.map(SettingsWindowAX.hasSheet) == true
        notePrompt(up: sheet)
        let shows = settingsFrame != nil && !sheet
            && PermissionWindowFloat.keepsFloating(frontBundle: front?.bundleIdentifier, frontPID: front?.processIdentifier)
        hidden = !shows
        if shows { overlay?.orderFrontRegardless() } else { overlay?.orderOut(nil) }
        // The compact panel stands in for setup: it goes behind another app with the overlay, never behind a prompt.
        if let compactPanel {
            let panelShows = settingsFrame != nil
                && PermissionWindowFloat.keepsFloating(frontBundle: front?.bundleIdentifier, frontPID: front?.processIdentifier)
            if panelShows { compactPanel.orderFrontRegardless() } else { compactPanel.orderOut(nil) }
        }
        updateLine()
        // The ghost: the card as it looks now, taken again every slow tick while no ghost is on screen (so a late
        // re-render, a light/dark switch or a changed card never leaves an old image).
        let ghostShown = model.demoStart.flatMap { PermissionDemo.local(Date().timeIntervalSince($0)) }.map { PermissionDemo.frame($0).ghost > 0 } ?? false
        if !ghostShown || model.ghost == nil, !dragging, let card = cardFrame(), let image = snapshotCard(card) { model.ghost = image }
    }

    /// B8: the prompt's comings and goings. Gone 1.5 s with no row (or none readable) and no grant: it was dismissed.
    private func notePrompt(up: Bool) {
        let now = Date()
        if up { promptUp = true; promptEndedAt = nil; return }
        if promptUp { promptUp = false; promptEndedAt = now }
        if let ended = promptEndedAt, now.timeIntervalSince(ended) >= 1.5 {
            promptEndedAt = nil
            if !granted(), row == .none || row == .unknown { promptDismissed = true; droppedAt = nil }
        }
        if row == .on || row == .off { promptDismissed = false }
    }

    /// The guided card's line (`PermissionCardLine.of`), the demo and the pointing hand from DayDream's row (B4).
    private func updateLine() {
        let now = Date()
        rowOnSince = PermissionCardLine.rowOnClock(row: row, promptUp: promptUp, since: rowOnSince, now: now)
        droppedAt = PermissionCardLine.dropClock(droppedAt: droppedAt, promptUp: promptUp, now: now)
        // The list can be read: Accessibility on and the list found, or still looked for in the first 3 s after placement.
        let canRead = settingsWindow != nil && (zoneFromList || placedAt.map { now.timeIntervalSince($0) < 3 } ?? true)
        let status = PermissionDragGuideStatus.shared
        let key = forAccessibility ? "accessibility" : "inputMonitoring"
        let line = PermissionCardLine.of(canReadRow: canRead, row: canRead ? row : .unknown, rowOnFor: rowOnSince.map { now.timeIntervalSince($0) } ?? 0,
                                         returns: status.returns[key] ?? 0, sinceDrop: droppedAt.map { now.timeIntervalSince($0) },
                                         promptDismissed: promptDismissed) ?? status.line
        if status.line != line { status.line = line }
        // Listed already (off, or on but not working): no demo; off: the pointing hand at its switch.
        if row == .off || row == .on, model.demoStart != nil { model.demoStart = nil }
        var point: CGPoint?
        if row == .off, let frame = settingsFrame, let box = overlay?.frame, let control = switchOffset, control.width > 0 {
            let at = control.offsetBy(dx: frame.minX, dy: frame.minY)
            point = PermissionPair.local(topLeft: CGPoint(x: at.midX, y: at.midY), in: box, primaryHeight: primaryHeight)
        }
        if model.pointAt != point { model.pointAt = point }
    }

    /// The real card from the window it's in (setup's, or the compact panel's), pixel for pixel (nil while it isn't laid
    /// out, or blank).
    private func snapshotCard(_ card: CGRect) -> NSImage? {
        guard let window = compactPanel ?? ownWindow, let view = window.contentView, card.width > 20, card.height > 20 else { return nil }
        let rect = view.convert(window.convertFromScreen(card), from: nil).intersection(view.bounds)
        guard !rect.isEmpty, let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        guard (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 else { return nil }
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    /// The list's zone, the card and the drop point in the overlay's own coordinates (top-left origin; the overlay covers
    /// System Settings' screen). Window server rects flip on the primary screen's top, then go into the overlay's
    /// actual frame (`PermissionPair.local`), so they land right on any screen, with the Dock anywhere.
    private func layout() {
        guard let overlay, let frame = settingsFrame, let screen = screen(holding: frame) else { return }
        if overlay.frame != screen.frame { overlay.setFrame(screen.frame, display: false) }
        let box = overlay.frame, top = primaryHeight
        let list = listOffset.map { $0.offsetBy(dx: frame.minX, dy: frame.minY) }
        // rc-018 RC3 B7: nothing under setup's window counts (setup may cover System Settings' sidebar).
        let covered = (compactPanel ?? ownWindow).map { appKit($0.frame) }
        let zone = PermissionPair.uncovered(PermissionPair.zone(list: list, settingsWindow: frame), by: covered)
        let base = list ?? PermissionPair.estimatedList(settingsWindow: frame)
        // B6: the demo lets go in the list's empty space or on its + area, never on a row or its switch.
        let rows = rowsOffset.map { $0.offsetBy(dx: frame.minX, dy: frame.minY) }
        let demo = PermissionPair.uncovered(PermissionPair.demoZone(list: base, rows: rows, settingsWindow: frame), by: covered)
        let drop = PermissionPair.dropPoint(list: demo, firstRow: nil)
        // A real drag over the list or the demo's spot counts as over the list.
        zoneOnScreen = appKit(zone.union(demo))
        let newZone = PermissionPair.local(topLeft: demo, in: box, primaryHeight: top)
        let newDrop = PermissionPair.local(topLeft: drop, in: box, primaryHeight: top)
        if model.zone != newZone { model.zone = newZone }
        if model.drop != newDrop { model.drop = newDrop }
        if let card = cardFrame() {
            cardOnScreen = card
            let newCard = PermissionPair.local(appKit: card, in: box)
            if model.card != newCard { model.card = newCard }
        }
        logLayout(list: base, fromList: list != nil, zone: demo, box: box)
    }

    /// Test builds: the card, the list, its zone and the demo's start and end, in screen coordinates (top-left origin),
    /// each time one of them moved.
    private func logLayout(list: CGRect, fromList: Bool, zone: CGRect, box: CGRect) {
        #if DEBUG || DAYDREAM_LIVETEST
        let top = primaryHeight, card = model.card
        let land = PermissionPair.landing(card: card.size, zone: model.zone, drop: model.drop)
        let start = PermissionPair.global(local: CGPoint(x: card.minX + PermissionPair.grabOffset.width, y: card.minY + PermissionPair.grabOffset.height), in: box, primaryHeight: top)
        let end = PermissionPair.global(local: land.point, in: box, primaryHeight: top)
        let ghostEnd = PermissionPair.ghostRect(card: card.size, held: end, scale: land.scale)
        typealias L = PermissionDragGuideLog
        let line = "layout step=\(forAccessibility ? "accessibility" : "inputMonitoring") overlay=\(L.r(appKit(box))) primaryTop=\(Int(top)) "
            + "card=\(L.r(cardOnScreen.map(appKit))) list=\(L.r(list)) listFrom=\(fromList ? "accessibility" : "estimate") zone=\(L.r(zone)) "
            + "settings=\(L.r(settingsFrame)) ghostStart=\(L.p(start)) ghostEnd=\(L.p(end)) ghostEndRect=\(L.r(ghostEnd)) "
            + "endInList=\(list.insetBy(dx: -1, dy: -1).contains(end)) startOnCard=\(cardOnScreen.map { appKit($0).contains(start) } ?? false)"
        if line != loggedLayout { loggedLayout = line; L.note(line) }
        #endif
    }

    /// DayDream's row appeared (or the permission reads allowed): a green check at the row, then it ends.
    private func celebrate(_ end: PermissionDragGuideEnd, row: CGRect?) {
        guard !celebrating else { return }
        celebrating = true; dragging = false; awaitingRowUntil = nil; resumeDemoAt = nil
        timer?.invalidate(); timer = nil
        model.demoStart = nil
        if let box = overlay?.frame {
            model.check = row.flatMap { $0.width > 0 ? PermissionPair.local(topLeft: CGPoint(x: $0.minX, y: $0.midY), in: box, primaryHeight: primaryHeight) : nil }
                ?? CGPoint(x: model.zone.minX, y: model.zone.midY)
        }
        let animation: Animation = model.reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.6)
        withAnimation(animation) { model.mode = .success }
        let run = generation
        Task { @MainActor in
            await self.pause(0.6)
            guard run == self.generation else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.model.fade = 0 }
            await self.pause(0.3)
            guard run == self.generation else { return }
            self.stop(end)
            // rc-018 RC3 (A1, A5): no activation here. The app hands back to setup the moment the permission reads
            // Allowed (`SetupFocus.handBack`, once, never under macOS's Quit & Reopen sheet that Input Monitoring brings).
        }
    }
}

/// rc-018 RC3 B7: the compact drag panel's card: the app's icon, the permission's name and the card's line, about
/// `PermissionPair.compactWidth` wide. It drags exactly as setup's card does (`PermissionCardAnchor`, the press monitor).
struct PermissionCompactCard: View {
    let appURL: URL
    let appName: String
    let forAccessibility: Bool
    let box: PermissionCardAnchorBox
    @ObservedObject private var status = PermissionDragGuideStatus.shared
    private var permission: String { forAccessibility ? "accessibility" : "inputMonitoring" }

    var body: some View {
        let line = status.dropLine(card: permission) ?? status.line
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path)).resizable().interpolation(.high)
                .frame(width: 40, height: 40).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(forAccessibility ? "Accessibility" : "Input Monitoring").font(.system(size: 14, weight: .semibold))
                Text(line.text(appName: appName)).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(line.warns ? Color(nsColor: .systemOrange) : Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: PermissionPair.compactWidth).frame(minHeight: 74)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(PermissionCardAnchor(box: box, appURL: appURL, enabled: true, guides: true, permission: permission))
        .gesture(DragGesture(minimumDistance: 3).onChanged { _ in
            PermissionCardDrag.shared.begin(appURL: appURL, enabled: true, guides: true, anchor: box.view, card: permission)
        })
        .pointerStyle(.grabIdle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel((forAccessibility ? "Accessibility" : "Input Monitoring") + " permission")
        .accessibilityHint(line.text(appName: appName))
    }
}

/// The live overlay: the canvas, animated.
struct PermissionDragGuideOverlay: View {
    @ObservedObject var model: PermissionDragGuideModel
    var body: some View {
        PermissionDragGuideCanvas(zone: model.zone, card: model.card, drop: model.drop, ghost: model.ghost, reduceMotion: model.reduceMotion,
                                  mode: model.mode, check: model.check, demoStart: model.demoStart, pointAt: model.pointAt)
            .opacity(model.fade)
            .ignoresSafeArea()
    }
}

/// What the helper draws (overlay coordinates, top-left origin), with no words and no ring around the list (owner
/// 10/8): the demo (the grab hand carrying the card's image into the list, `zone`), and the green check at the end.
/// With Reduce Motion: the closed hand on the card and a dotted arc to the list. Nothing else (no switch, no tip). `time` (seconds into a play)
/// draws one moment, for the renders; nil animates from `demoStart`.
public struct PermissionDragGuideCanvas: View {
    public enum Mode: Equatable, Sendable { case idle, success }
    let zone: CGRect, card: CGRect, drop: CGPoint, ghost: NSImage?, reduceMotion: Bool, mode: Mode, check: CGPoint?
    let demoStart: Date?, time: Double?
    /// rc-018 RC3 B4: DayDream's row is listed but off: the system's pointing hand at its switch, and no demo.
    let pointAt: CGPoint?
    public init(zone: CGRect, card: CGRect, drop: CGPoint, ghost: NSImage?, reduceMotion: Bool, mode: Mode = .idle, check: CGPoint? = nil,
                demoStart: Date? = nil, time: Double? = nil, pointAt: CGPoint? = nil) {
        self.zone = zone; self.card = card; self.drop = drop; self.ghost = ghost; self.reduceMotion = reduceMotion; self.mode = mode
        self.check = check; self.demoStart = demoStart; self.time = time; self.pointAt = pointAt
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if let pointAt, mode != .success {
                pointer(at: pointAt)
            } else if zone.width > 0 {
                if reduceMotion { still }
                else if let time { content(PermissionDemo.frame(time)) }
                else if let demoStart, mode != .success {
                    TimelineView(.animation) { context in
                        content(PermissionDemo.local(context.date.timeIntervalSince(demoStart)).map(PermissionDemo.frame) ?? PermissionDemo.Frame())
                    }
                } else { content(PermissionDemo.Frame()) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The grab point on the card: where the hand holds it.
    var grab: CGPoint { CGPoint(x: card.minX + PermissionPair.grabOffset.width, y: card.minY + PermissionPair.grabOffset.height) }

    /// One moment of the demo. Its layers share one top-left ZStack: inside `TimelineView` loose views are stacked like
    /// a VStack, each `.position` measured from its own slice of the screen, which put the card and the hand a third and
    /// two thirds of the screen below where they belong (owner 10/7: "the animation is way below the screen").
    private func content(_ f: PermissionDemo.Frame) -> some View {
        // The image shrinks as it travels so that it lands inside the list; it scales around the grab point, so the
        // hand never slips on it.
        let land = PermissionPair.landing(card: card.size, zone: zone, drop: drop)
        let held = PermissionDemo.point(f.progress, from: grab, to: land.point)
        let scale = CGFloat(f.scale) * (1 + (land.scale - 1) * CGFloat(f.progress))
        return ZStack(alignment: .topLeading) {
            if card.width > 0, f.ghost > 0, let ghost {
                ghostView(ghost, opacity: f.ghost, shadow: f.shadow)
                    .scaleEffect(scale, anchor: UnitPoint(x: PermissionPair.grabOffset.width / card.width, y: PermissionPair.grabOffset.height / card.height))
                    .position(x: held.x - PermissionPair.grabOffset.width + card.width / 2, y: held.y - PermissionPair.grabOffset.height + card.height / 2)
            }
            if card.width > 0, f.hand > 0 { hand(closed: f.closed, at: held).opacity(f.hand) }
            checkView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Reduce Motion: nothing moves. The closed hand on the real card and an arrow to the list (no second copy of the card).
    private var still: some View {
        ZStack(alignment: .topLeading) {
            if card.width > 0 {
                arrow
                hand(closed: true, at: grab)
            }
            checkView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func ghostView(_ image: NSImage, opacity: Double, shadow: Double) -> some View {
        Image(nsImage: image).resizable().interpolation(.high)
            .frame(width: card.width, height: card.height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: shadow, y: shadow * 10 / 18)
            .opacity(opacity)
    }

    /// The system's pointing hand, 1.25x, its fingertip just left of the switch's middle (the switch stays in view).
    private func pointer(at point: CGPoint) -> some View {
        let cursor = NSCursor.pointingHand
        let size = CGSize(width: cursor.image.size.width * 1.25, height: cursor.image.size.height * 1.25)
        let hot = CGPoint(x: cursor.hotSpot.x * 1.25, y: cursor.hotSpot.y * 1.25)
        let tip = CGPoint(x: point.x - 14, y: point.y + 6)
        return Image(nsImage: cursor.image).resizable().interpolation(.high)
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1.5)
            .position(x: tip.x - hot.x + size.width / 2, y: tip.y - hot.y + size.height / 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The system's own open and closed hand pointers, 1.25x, with the hot spot on `point`.
    private func hand(closed: Bool, at point: CGPoint) -> some View {
        let cursor = closed ? NSCursor.closedHand : NSCursor.openHand
        let size = CGSize(width: cursor.image.size.width * 1.25, height: cursor.image.size.height * 1.25)
        let hot = CGPoint(x: cursor.hotSpot.x * 1.25, y: cursor.hotSpot.y * 1.25)
        return Image(nsImage: cursor.image).resizable().interpolation(.high)
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1.5)
            .position(x: point.x - hot.x + size.width / 2, y: point.y - hot.y + size.height / 2)
    }

    @ViewBuilder private var checkView: some View {
        if mode == .success, let check {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 22, weight: .semibold))
                .symbolRenderingMode(.palette).foregroundStyle(.white, Color(nsColor: .systemGreen))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                .position(check)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
        }
    }

    /// Reduce Motion: a still dotted arc from beside the card to just outside the list, with an arrowhead (`stillArrow`).
    private var arrow: some View {
        let path = PermissionPair.stillArrow(card: card, zone: zone, drop: drop)
        let a = path.from, b = path.to, control = path.control
        let tip = CGPoint(x: b.x - control.x, y: b.y - control.y)
        let length = max(1, (tip.x * tip.x + tip.y * tip.y).squareRoot())
        let ux = tip.x / length, uy = tip.y / length
        return ZStack {
            Path { p in p.move(to: a); p.addQuadCurve(to: b, control: control) }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 6]))
            Path { p in
                p.move(to: CGPoint(x: b.x - 10 * ux + 6 * uy, y: b.y - 10 * uy - 6 * ux))
                p.addLine(to: b)
                p.addLine(to: CGPoint(x: b.x - 10 * ux - 6 * uy, y: b.y - 10 * uy + 6 * ux))
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The window a view is in (setup's window, for the helper), kept weakly.
final class HostWindowBox { weak var window: NSWindow? }

struct HostWindowReader: NSViewRepresentable {
    let box: HostWindowBox
    final class Reader: NSView {
        var box: HostWindowBox?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); box?.window = window }
    }
    func makeNSView(context: Context) -> Reader { let view = Reader(); view.box = box; return view }
    func updateNSView(_ view: Reader, context: Context) { view.box = box; if let window = view.window { box.window = window } }
}
