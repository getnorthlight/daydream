import AppKit
import SwiftUI

/// Click-to-reference (Preview 4): a summary line, the headline, a timeline span or Search's "Show in Today" names the
/// moments it is about. Today scrolls to the first one, tints them, dims the rest and lights their spans on the day
/// card's timeline. The moments always come from membership (the level notes' threads and children, a span's
/// thread), never from matching text.
///
/// It clears on any other click, on a scroll the person makes (a programmatic scroll sends no scroll-wheel event, so it
/// never clears), on Esc, and on clicking the same line again.
public struct MomentReference: Equatable, Sendable {
    /// What was clicked: "headline", "bullet:2", "span:<moment id>", "block:<id>", "moment:<id>". Clicking the same
    /// key again clears the highlight.
    public let key: String
    /// The day it is on (the day key).
    public let day: String
    /// The moments, in order (the first is scrolled to). Empty with `block` set: the block's moments once its day is read.
    public let moments: [String]
    /// Search's "Show in Today" on a block note: the block whose moments to light.
    public let block: String?
    public init(key: String, day: String, moments: [String], block: String? = nil) {
        self.key = key; self.day = day; self.moments = moments; self.block = block
    }

    /// The moments to light on a day, in the day's order: `moments`, else the block's (by membership).
    public func resolved(in levels: DayLevelSlice?, order: [String]) -> [String] {
        var ids = moments
        if ids.isEmpty, let block, let b = levels?.blocks.first(where: { $0.id == block }) { ids = b.momentIDs }
        let set = Set(ids)
        let ordered = order.filter { set.contains($0) }
        return ordered.isEmpty ? ids : ordered
    }

    /// A span's reference: the thread the moment is in (its block's main thread or one of its side threads), else the
    /// moment alone.
    public static func span(_ momentID: String, day: String, levels: DayLevelSlice?) -> MomentReference {
        for b in levels?.blocks ?? [] where b.momentIDs.contains(momentID) {
            if let i = b.sideThreadMoments.firstIndex(where: { $0.contains(momentID) }), !b.sideThreadMoments[i].isEmpty {
                return MomentReference(key: "span:" + momentID, day: day, moments: b.sideThreadMoments[i])
            }
            if b.mainMoments.contains(momentID) { return MomentReference(key: "span:" + momentID, day: day, moments: b.mainMoments) }
        }
        return MomentReference(key: "span:" + momentID, day: day, moments: [momentID])
    }

    /// The day card's headline: the main thread's moments.
    public static func headline(day: String, levels: DayLevelSlice) -> MomentReference? {
        levels.headlineMoments.isEmpty ? nil : MomentReference(key: "headline", day: day, moments: levels.headlineMoments)
    }

    /// The day card's line `index`: the moments it carries.
    public static func bullet(_ index: Int, day: String, levels: DayLevelSlice) -> MomentReference? {
        guard levels.dayBullets.indices.contains(index), !levels.dayBullets[index].moments.isEmpty else { return nil }
        return MomentReference(key: "bullet:\(index)", day: day, moments: levels.dayBullets[index].moments)
    }
}

/// The highlight's state and its clearing rules (kept apart from the view so the checks can drive it).
@MainActor public final class MomentReferenceState {
    /// The key a mouse-down just cleared: a click that lands on the same line then leaves it cleared (a toggle), instead
    /// of setting it again on the button's mouse-up.
    private var clearedKey: String?
    private var clearedAt = Date.distantPast
    public init() {}

    /// A click on a line (or span) with this reference: sets it, or clears it when it is the one already lit.
    public func click(_ next: MomentReference, current: MomentReference?) -> MomentReference? {
        if current?.key == next.key { return nil }
        if clearedKey == next.key, Date().timeIntervalSince(clearedAt) < 1 { clearedKey = nil; return nil }
        clearedKey = nil
        return next
    }

    /// Any mouse-down, a scroll-wheel event or Esc: clears. Remembers what a mouse-down cleared (see `click`).
    public func cleared(_ current: MomentReference?, byMouseDown: Bool) -> MomentReference? {
        if byMouseDown, let current { clearedKey = current.key; clearedAt = Date() }
        return nil
    }
}

/// Watches the window's own events while a highlight shows: a mouse-down anywhere, a scroll-wheel event (the person
/// scrolling; programmatic scrolls send none) and Esc clear it. Installed only while there is something to clear.
struct MomentReferenceMonitor: NSViewRepresentable {
    let active: Bool
    let clear: (_ byMouseDown: Bool) -> Void

    final class Coordinator {
        var monitor: Any?
        var clear: ((Bool) -> Void)?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        let c = context.coordinator
        c.clear = clear
        if active, c.monitor == nil {
            c.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak view, weak c] event in
                guard let view, event.window === view.window else { return event }
                switch event.type {
                case .leftMouseDown, .rightMouseDown: c?.clear?(true)
                case .scrollWheel: c?.clear?(false)
                case .keyDown where event.keyCode == 53: c?.clear?(false)
                default: break
                }
                return event
            }
        } else if !active, let monitor = c.monitor {
            NSEvent.removeMonitor(monitor); c.monitor = nil
        }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor); coordinator.monitor = nil }
    }
}

/// The lit moments, for rows and the ribbon: nil when nothing is referenced.
private struct ReferencedMomentsKey: EnvironmentKey { static let defaultValue: Set<String>? = nil }
private struct ReferenceClickKey: EnvironmentKey { static let defaultValue: ReferenceClickAction? = nil }

/// Today's click handler for a reference, equal to another made by the same owner (fix/scroll-perf). A bare closure is
/// never equal to the next one, so every redraw of the list changed the environment under the day card, which then
/// redrew in full (its ribbon too) on every selection. The owner's `run` must read its live state, not a snapshot.
public struct ReferenceClickAction: Equatable {
    private let owner: ObjectIdentifier
    private let run: (MomentReference) -> Void
    public init(owner: AnyObject, _ run: @escaping (MomentReference) -> Void) { self.owner = ObjectIdentifier(owner); self.run = run }
    public func callAsFunction(_ reference: MomentReference) { run(reference) }
    public static func == (a: Self, b: Self) -> Bool { a.owner == b.owner }
}
extension EnvironmentValues {
    public var daydreamReferenced: Set<String>? {
        get { self[ReferencedMomentsKey.self] } set { self[ReferencedMomentsKey.self] = newValue }
    }
    /// Today's click handler for a reference (the day card's lines and the ribbon's spans).
    public var daydreamReferenceClick: ReferenceClickAction? {
        get { self[ReferenceClickKey.self] } set { self[ReferenceClickKey.self] = newValue }
    }
}

public enum ReferenceStyle {
    /// The referenced rows' tint and the others' opacity.
    public static let tint = Color.accentColor.opacity(0.10)
    public static let dimmed: Double = 0.4
    /// ~250 ms, none with Reduce Motion.
    public static func animation(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .easeInOut(duration: 0.25) }
}
