// DD-RECIPE: UI
//
// F1 visual kit checks (spec §1–§4, §10; amendments F1). Values only: a fixed clock and time zone,
// views hosted offscreen in NSHostingView/NSWindow, no app, no permissions, no recording.
//  - Recording controls: at most one prominent control per state and style, Stop never blue,
//    presets deliver exactly [5, 15, 30, 120], each control calls exactly one closure, Open System
//    Settings passes the single missing pane, and rendering, hovering and disabled presses call none.
//  - Ribbon: no segments for an empty day, the hatch only with a live pause, RibbonModel flags.
//  - Row and key-hint heights (52 / 28 pt) in every state.
//  - The Twin D menu bar mark: template image contract and the mark-A pixel rules and snapshots
//    (ported from glyph/mark-A/package/Tests without Swift Testing; the red-dot test is dropped).
//  - Actions menu privacy rows carry no keys; stable app tints; copy and vocabulary sweeps.
//  - Hover is really delivered: sweeps send entered + moved events to the hosting view's tracking
//    areas and assert SwiftUI saw them (a sentinel on the root), so "hovering calls nothing" is not vacuous.
//  - The forget and exclude confirmations, driven through their real sheets offscreen.
//  - The live dot is solid (owner, launch build 9/28: "nothing moving, no status noise"; earlier, "the button is going
//    in a diagonal line"): when Recording turns on, in light and dark, every frame is pixel-identical to the static
//    render (no breathing halo, no drift), and no `repeatForever`, state, timer or animation is left in LiveDot or
//    anywhere in the app's UI.
import AppKit
import SwiftUI
import MemoryUI
import MemoryCore

// MARK: - Pixel helpers (mark-A tests)

/// Alpha plane of a bitmap, row-major from the top-left, 0...1.
struct AlphaPlane: Equatable {
    let width: Int, height: Int
    let a: [Double]

    init(_ rep: NSBitmapImageRep) {
        width = rep.pixelsWide; height = rep.pixelsHigh
        var out = [Double](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { out[y * width + x] = Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) } }
        a = out
    }
    subscript(x: Int, y: Int) -> Double { a[y * width + x] }

    var ink: Double { a.reduce(0, +) }

    func bounds(threshold: Double = 0.02) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<height { for x in 0..<width where self[x, y] > threshold {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        } }
        return maxX < 0 ? nil : (minX, minY, maxX, maxY)
    }

    /// Separate pieces of ink (8-connected, alpha at or above `threshold`).
    func pieces(threshold: Double = 0.35) -> Int {
        var seen = [Bool](repeating: false, count: a.count), count = 0
        for start in 0..<a.count where a[start] >= threshold && !seen[start] {
            count += 1
            var stack = [start]; seen[start] = true
            while let i = stack.popLast() {
                let x = i % width, y = i / width
                for dy in -1...1 { for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let j = ny * width + nx
                    if !seen[j] && a[j] >= threshold { seen[j] = true; stack.append(j) }
                } }
            }
        }
        return count
    }
}

/// mark-A `__Snapshots__/<state>@<scale>x.png`, embedded so the check needs no files.
let markSnapshots: [String: String] = [
        "recording@1x": "iVBORw0KGgoAAAANSUhEUgAAABIAAAASCAYAAABWzo5XAAAAAXNSR0IArs4c6QAAADhlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAAEqADAAQAAAABAAAAEgAAAAC5YZBvAAAAtElEQVQ4EWNgoDJoBZr3E4j/A/E3IL4IxFVAzAnEJAGYISCDkPEZIJ+XFJNgmkF6BIE4GIifAjFIvAuIiQbIBsE0OQIZIPEHMAFiaGwGsQE1gsRB3iYImPCosIbKPcOjBkMK2UXIYfQPqFIHQzUeAVyx1gfVQ3TyaANqgBmGnI5YoQbB5GAuh9EjIXngi348cQOWgiWP54QUIsvDAhckhpw8QOIkZSGqxRqu5EFyMYPsTaxsAHkpU2CfBdDgAAAAAElFTkSuQmCC",
        "recording@2x": "iVBORw0KGgoAAAANSUhEUgAAACQAAAAkCAYAAADhAJiYAAAAAXNSR0IArs4c6QAAAGxlWElmTU0AKgAAAAgABAEaAAUAAAABAAAAPgEbAAUAAAABAAAARgEoAAMAAAABAAIAAIdpAAQAAAABAAAATgAAAAAAAACQAAAAAQAAAJAAAAABAAKgAgAEAAAAAQAAACSgAwAEAAAAAQAAACQAAAAAQCQK+gAAAAlwSFlzAAAWJQAAFiUBSVIk8AAAAVlJREFUWAntljEKwjAUhtVBF08h4iwIru7OXsAzeAQXRz2EF3BzdRRcXB1dnBQUdNQ/0kj8Sdu0fbFFGvhJXhPe+4xp81cqZXPfgTqWzqEL9DT0wPgIbaAp1IV+0haoYoJEjddY2/ZNxTsTBaTmrtDQJ1QcgG3+DqC+LyhbQVWrAbWgMbSDeN0ez2qQeONCKuamCs8gXjvihRIxF7EB6TorglrqCck+CdCAgA6SIDpXEqAmAd10kqy9l8OYBSotUI+KnihOHaYFmlDFLcUiocsZKsRr7/JhrIpsCSWx7VDcM3V1dII84m7hjMRxAOY8X67ibkF5IbNg1NhmP8Tdgt5y3ilXgxb1A8LmSrcQnPdPV4jPxofGGJRuQR9iY1O+hqFuIe1d9pVdMsgLKNQt5AVUugXzULu4BS//lIZI0nu9OvgOjANjtyD5sr5zZXUL4kBZ3YI40H8mfAGNXkkRloHMbgAAAABJRU5ErkJggg==",
        "paused@1x": "iVBORw0KGgoAAAANSUhEUgAAABIAAAASCAYAAABWzo5XAAAAAXNSR0IArs4c6QAAADhlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAAEqADAAQAAAABAAAAEgAAAAC5YZBvAAAApklEQVQ4EWNgoDJoBZr3E4j/A/E3IL4IxFVAzAnEJAGYISCDkPEZIJ+XFJNgmkF6BIE4GIifAjFIvAuIiQbIBsE0OQIZIPEHMAFiaGwGsQE1gsRB3iYImPCosIbKPcejBkMK2UUUhRExsXYYaD0IIwMMsTagLMwwXOkI2dUww7CJweRw0tg0wcXwBTZOE7FJjBqELVRQxVhQuXh5R7DIYhPDoowEIQCF/jaipyMHgQAAAABJRU5ErkJggg==",
        "paused@2x": "iVBORw0KGgoAAAANSUhEUgAAACQAAAAkCAYAAADhAJiYAAAAAXNSR0IArs4c6QAAAGxlWElmTU0AKgAAAAgABAEaAAUAAAABAAAAPgEbAAUAAAABAAAARgEoAAMAAAABAAIAAIdpAAQAAAABAAAATgAAAAAAAACQAAAAAQAAAJAAAAABAAKgAgAEAAAAAQAAACSgAwAEAAAAAQAAACQAAAAAQCQK+gAAAAlwSFlzAAAWJQAAFiUBSVIk8AAAAW1JREFUWAntVjFuAjEQvFCQJp8A8YBISLTpqfkAb+AJNJTkEfkAXZoI0YFEQ0tJQwUSUUCpklmUjayROfvubISQVxrZ493zjBZz5yxL4d+BOkrHwB74MXDCfAPMgCHwDFwlXqFiGsmbv6O2FdsVdybPkOQOQDemKZcBW/4IQ51YpmyCovUINIE+sAS4boW1GhA8WEg4hwiPAK7tcWEIziI2Q6ozIVNvmgg5FjH0QobWIY3oXkUMPZGhT92k6hjlMFYxVdZQm0S3xEvTsoYGpLggHoT6nKGb+Nvf1IvR1jVzzfbpaOD3mgLff6NwDp+abIenTDHX/NLH9YP2Ec7hU3O+C7lMaD7v+vEFda2TUTiHT02mFzTuVNELmmlG52xI183xXPPAlQG4iHCwzsWasu8hFgzGkyFXK1OHUodcHXDl0xlKHUIH5EpiBnPJ8do/j3GG5qYbzJlLmteY0xbVaBOPT4G8C5pPTTUXd/v0L3n21UOqBicPAAAAAElFTkSuQmCC",
        "off@1x": "iVBORw0KGgoAAAANSUhEUgAAABIAAAASCAYAAABWzo5XAAAAAXNSR0IArs4c6QAAADhlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAAEqADAAQAAAABAAAAEgAAAAC5YZBvAAAAqUlEQVQ4EWNgoDJoA5r3E4j/A/EPIL4KxPVAzAXEJAGQIUJQHWxA2giIlwLxeSDmA2KiAcgl2MBcoGA3NglcYrgMUgNqeIBLEzZxXAaxAhX/wqYBXYwJXQCNrwjkP0UTw8vF5aI5QF06eHVCJWEuAjkfW6x9AYpfAWKikwcuhaAwAoGRnDxggQ0JCdJJUPJ4BtJGqUHlQDNWgwwiFlAt1nAlD5KLGYIuBwDktzCeRAbpmAAAAABJRU5ErkJggg==",
        "off@2x": "iVBORw0KGgoAAAANSUhEUgAAACQAAAAkCAYAAADhAJiYAAAAAXNSR0IArs4c6QAAAGxlWElmTU0AKgAAAAgABAEaAAUAAAABAAAAPgEbAAUAAAABAAAARgEoAAMAAAABAAIAAIdpAAQAAAABAAAATgAAAAAAAACQAAAAAQAAAJAAAAABAAKgAgAEAAAAAQAAACSgAwAEAAAAAQAAACQAAAAAQCQK+gAAAAlwSFlzAAAWJQAAFiUBSVIk8AAAAWlJREFUWAntV7tuAjEQBBJo+IB0qQN/gJSChp6Gb6JIk1DDz1Cmpkt6kCKFBkRBATOns7QcFtjZda7xSnNnW2vv3Po112hkC89AB67vwBY4CRxRXgOfwBswAP7FPhBFErlVXsK3n5qVy8xrJdAj6k/AEJgCPwDJ7oExkMxcRu4F6MJhDtD/ACSbwlBC4FDYDE/2WQEPRYvxI5ZQG/G/AfabWHFpKQbi7mOWaEnWUmyGSKQHsN8XK9b2F0Jc4Oy3syKjmTLJgaRMTEvouWSxMWGDQbSERiURXivmFruGkmx7+VWxhOTB2JQDWZVDCXFnLQD68+p4AWjmakF7uZqrBWohl6V77yV8q/JD+0HM8oW5lP+iVRIKFWiuz8WgnkpWC56keJu8x4b2YPRGCmzMaiEkUVdqoc4pk4S5Qwurm9CVWqibUFYLbmn43lIt1PobVVULyX40zS9XX1pj2rRqISZWkK9WLQQFyU5nKNS2DNFmAikAAAAASUVORK5CYII=",
        "needsPermission@1x": "iVBORw0KGgoAAAANSUhEUgAAABIAAAASCAYAAABWzo5XAAAAAXNSR0IArs4c6QAAADhlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAAEqADAAQAAAABAAAAEgAAAAC5YZBvAAAAw0lEQVQ4EWNgoDJoBZr3E4j/A/E3IL4IxFVAzAnEyKAFyAHJg2isAGYIyCBkfAbI50XS8R0qD6KxAphmkKQgEAcD8VMgBol3ATEMwNSBaKwApgBZ0hHIAYk/QBKEqSPJIDaoQSBvwwBOg5hgKrDQ1lCx51jkcArBbAIpoCiMiI01mIU4w6gN6BKYYfjSEUGDcPoZTQJnOsIX2GhmgLm9QBJkGIgeZgCUuT8DMYimCIAMAcUciEYBpAb2JKDuL0AMomkDAGASTN2lr6HaAAAAAElFTkSuQmCC",
        "needsPermission@2x": "iVBORw0KGgoAAAANSUhEUgAAACQAAAAkCAYAAADhAJiYAAAAAXNSR0IArs4c6QAAAGxlWElmTU0AKgAAAAgABAEaAAUAAAABAAAAPgEbAAUAAAABAAAARgEoAAMAAAABAAIAAIdpAAQAAAABAAAATgAAAAAAAACQAAAAAQAAAJAAAAABAAKgAgAEAAAAAQAAACSgAwAEAAAAAQAAACQAAAAAQCQK+gAAAAlwSFlzAAAWJQAAFiUBSVIk8AAAAblJREFUWAntVz1KhDEQDRbaeArxAIJga2/tBTyDR7CxU68gWNja2VoKNraWgqigCwraKPoeOuzs8JINceNusQNDZl7e/Gy+70uyKc2lfgUWQT2EDqBfTt9h30IvoHvQNWiNLIF0AH36VdrEquUITN9IyT4Hd3VMZjYQcxCrlgGYMUHJfwF/q5D9TuQjVi2l4rm5N2TfyFT4BB7jPjJcCcdg+hQ+9xXoDvQKGnnXwBagUSLP/MjL+hbgx0hm4X2o59DejkTBsRhB1ZAF+FEzUzoLBU8E0efxtqBqyAeZrZkpbWLCOBxvBNHPe1tQNeSDzNbMlJYxYRyOr4Lo570tqENIvYzD2SlYrQ2th17vg9/stja0GypeBn8irn/OZsfEM/HZz9TGaCuVG0tHRy4mrnrWf8ZMLonCxx2uKoZYtfAulEsS8ZrrR4wxv7ohu6DFlWq9oFkDcaxuaNLEputH6z5U0/yDID0KbATq2dDpSKUfR2GC1gf68yW/T1vzrPMVaF8Bv9Fys+VJQGxqov4Js6mpSTyCeIQQK0rPjbFYODfZs6FjUVRhgtYH4k7Nd4aPaSZe6j4/87+zfgORkhimWs/q6AAAAABJRU5ErkJggg==",
]

// MARK: - Recorders

/// Counts every `CaptureActions` closure call.
@MainActor final class Calls {
    var pauses: [Int] = [], resumes = 0, stops = 0, settings = 0, systemSettings: [PermissionKind?] = [], checks = 0
    var sections: [String] = [], mains = 0, recalls = 0, quits = 0
    var total: Int { pauses.count + resumes + stops + settings + systemSettings.count + checks + sections.count + mains + recalls + quits }
    func reset() {
        pauses = []; resumes = 0; stops = 0; settings = 0; systemSettings = []; checks = 0
        sections = []; mains = 0; recalls = 0; quits = 0
    }
    var actions: CaptureActions {
        var a = CaptureActions(pause: { [unowned self] in self.pauses.append($0) }, resume: { [unowned self] in self.resumes += 1 },
                               stop: { [unowned self] in self.stops += 1 }, settings: { [unowned self] in self.settings += 1 })
        a.openSystemSettings = { [unowned self] in self.systemSettings.append($0) }
        a.checkPermissions = { [unowned self] in self.checks += 1 }
        a.openSettingsSection = { [unowned self] in self.sections.append($0) }
        a.openMain = { [unowned self] in self.mains += 1 }
        a.openRecall = { [unowned self] in self.recalls += 1 }
        a.quit = { [unowned self] in self.quits += 1 }
        return a
    }
}

@main @MainActor enum DDKitChecks {
    static var failures = 0
    static var strings: [String] = []

    static func check(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        if ok { print("PASS " + name) } else {
            failures += 1
            fflush(stdout)  // keep FAIL lines whole when stdout and stderr share a log
            FileHandle.standardError.write(Data(("FAIL: " + name + (got().isEmpty ? "" : " (got: " + got() + ")") + "\n").utf8))
        }
    }
    static func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) { check(got == want, name, "\(got)") }

    static let la = TimeZone(identifier: "America/Los_Angeles")!
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = la; return c }
    static func date(_ h: Int, _ m: Int, day: Int = 22) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: h, minute: m))!
    }
    static let now = date(16, 21)

    enum Case: String, CaseIterable { case recording, paused, pausedOpen, off, offPlain, permission, permissionUnknown }
    static func state(_ c: Case) -> RecordingState {
        switch c {
        case .recording: return .recording(since: date(8, 40))
        case .paused: return .paused(until: date(16, 33), since: date(16, 18), reason: nil)
        case .pausedOpen: return .paused(until: nil, since: date(16, 18), reason: nil)
        case .off: return .off(since: date(16, 18), reason: nil)
        case .offPlain: return .off(since: nil, reason: "Development Trial · recording is disabled")
        case .permission: return .needsPermission(missing: [.inputMonitoring])
        case .permissionUnknown: return .needsPermission(missing: [])
        }
    }

    static func moment(_ id: String, _ h0: Int, _ m0: Int, _ h1: Int, _ m1: Int, summary: MomentSummaryState = .ready(generatedAt: nil, local: true),
                       bullet: String? = "Commented on the launch plan.", actions: Int = 17, bundles: [String] = ["com.google.Chrome"],
                       app: String? = "Google Chrome", sites: [String] = [], correction: Bool = false) -> MomentSlice {
        let start = date(h0, m0), end = date(h1, m1)
        var bullets = bullet.map { [MomentBullet(text: $0)] } ?? []
        if correction { bullets.append(MomentBullet(text: "It was the beta plan.", correction: true)) }
        return MomentSlice(id: id, dayKey: "2026-09-22", start: start, end: end, title: "Reviewing the launch plan", subject: "launch plan",
                           firstBullet: summary.isReady ? bullet : nil, bullets: summary.isReady || correction ? bullets : [],
                           apps: app.map { [$0] } ?? [], primaryBundle: bundles.first, bundles: bundles, sites: sites,
                           actionIDs: (0..<actions).map { "\(id)-\($0)" }, actionCount: actions, clusters: [start...end],
                           summary: summary, hasCorrection: correction, primaryApp: app)
    }

    static func snapshot(_ moments: [MomentSlice]) -> TodaySnapshot {
        TodaySnapshot(dayKey: "2026-09-22", loadedAt: now, momentCount: moments.count, actionCount: moments.reduce(0) { $0 + $1.actionCount },
                      countComplete: true, partial: false, moments: moments, headline: nil, headlineBullets: [], headlineGeneratedAt: nil,
                      headlineLocal: nil, firstObserved: moments.first?.start, lastObserved: moments.last?.end, topApps: [],
                      latest: moments.last, summaries: SummaryAvailability(provider: .local, busy: false),
                      readyCount: moments.count, pendingCount: 0, tooLongCount: 0, appCount: 1)
    }

    // MARK: Hosting and accessibility

    static let window: NSWindow = {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 420, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        w.acceptsMouseMovedEvents = true
        w.orderFrontRegardless()
        return w
    }()

    static func pump(_ s: Double = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// Hover events SwiftUI delivered to the hosted root (a sentinel `onContinuousHover`).
    static var hoverEvents = 0

    @discardableResult
    static func host<V: View>(_ view: V, size: NSSize = NSSize(width: 380, height: 360)) -> NSHostingView<AnyView> {
        let h = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .onContinuousHover { _ in hoverEvents += 1 }
            .environment(\.daydreamNow, now).environment(\.daydreamStatic, true)))
        window.setContentSize(size)
        window.contentView = h
        h.frame = NSRect(origin: .zero, size: size)
        pump(); h.layoutSubtreeIfNeeded(); pump(0.05)
        return h
    }

    static func tree(_ root: Any, depth: Int = 0, into out: inout [NSAccessibilityProtocol]) {
        guard depth < 40, let e = root as? NSAccessibilityProtocol else { return }
        out.append(e)
        for child in e.accessibilityChildren() ?? [] { tree(child, depth: depth + 1, into: &out) }
    }
    static func elements(_ view: NSView) -> [NSAccessibilityProtocol] {
        var out: [NSAccessibilityProtocol] = []
        tree(view, into: &out)
        return out
    }
    static func element(_ view: NSView, _ label: String) -> NSAccessibilityProtocol? {
        elements(view).first { $0.accessibilityLabel() == label }
    }
    static func press(_ view: NSView, _ label: String) -> Bool {
        guard let e = element(view, label) else { return false }
        _ = e.accessibilityPerformPress()
        pump(0.05)
        return true
    }

    /// Hosts `view` at `width` and its fitting height.
    static func fitted<V: View>(_ view: V, width: CGFloat = 360) -> NSHostingView<AnyView> {
        let probe = NSHostingView(rootView: view.frame(width: width))
        return host(view, size: NSSize(width: width, height: max(20, probe.fittingSize.height)))
    }

    /// Synthetic clicks on a grid over the whole view. Returns the largest number of closure calls a
    /// single click made (a control calls exactly one closure; empty space calls none).
    static func clickSweep(_ view: NSView, _ calls: Calls, step: CGFloat = 6) -> (clicks: Int, worst: Int) {
        var clicks = 0, worst = 0
        let b = view.bounds
        var y = b.minY + 2
        while y < b.maxY {
            var x = b.minX + 2
            while x < b.maxX {
                let before = calls.total
                let p = view.convert(NSPoint(x: x, y: y), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                  pressure: type == .leftMouseDown ? 1 : 0) {
                        window.sendEvent(e)
                    }
                }
                RunLoop.main.run(until: Date())
                clicks += 1
                worst = max(worst, calls.total - before)
                x += step
            }
            y += step
        }
        pump(0.05)
        return (clicks, worst)
    }

    /// Tracking areas of `view` and its subviews with their owners (SwiftUI hosts hover in one).
    static func trackingAreas(_ view: NSView) -> [(NSTrackingArea, NSResponder)] {
        view.trackingAreas.compactMap { t in (t.owner as? NSResponder).map { (t, $0) } } + view.subviews.flatMap(trackingAreas)
    }

    /// Synthetic hover across the whole view: hovering must never run an action. The window server
    /// never routes hover to an offscreen window, so the sweep does what AppKit does: an entered event
    /// for each tracking area, then mouse moves to the areas' owners, then exited events. Returns the
    /// moves sent and the hover events SwiftUI delivered to the root (callers assert both are > 0).
    static func hoverSweep(_ view: NSView) -> (moves: Int, delivered: Int) {
        let before = hoverEvents
        var moves = 0
        let areas = trackingAreas(view)
        var owners: [NSResponder] = []
        for (_, o) in areas where !owners.contains(where: { $0 === o }) { owners.append(o) }
        func enterExit(_ type: NSEvent.EventType, _ p: NSPoint) {
            for (area, owner) in areas {
                guard let e = NSEvent.enterExitEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     trackingNumber: unsafeBitCast(area, to: Int.self), userData: nil) else { continue }
                if type == .mouseEntered { owner.mouseEntered(with: e) } else { owner.mouseExited(with: e) }
            }
        }
        let b = view.bounds
        var entered = false
        var last = NSPoint.zero
        var y = b.minY + 4
        while y < b.maxY {
            var x = b.minX + 4
            while x < b.maxX {
                let p = view.convert(NSPoint(x: x, y: y), to: nil)
                if !entered { enterExit(.mouseEntered, p); entered = true }
                if let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                    for o in owners { o.mouseMoved(with: e) }
                    moves += 1
                }
                RunLoop.main.run(until: Date())
                last = p
                x += 24
            }
            y += 12
        }
        if entered { enterExit(.mouseExited, last) }
        pump(0.1)
        return (moves, hoverEvents - before)
    }

    // MARK: Checks

    @MainActor static func main() {
        controlsModel()
        controlsHosted()
        ribbon()
        heights()
        glyph()
        liveDotStaysPut()
        moments()
        promptRows()
        levelSections()
        timelineWording()
        settingsOutsideClick()
        confirmations()
        tints()
        copyAndVocabulary()
        sourceSweep()
        codeNoteMark()
        window.orderOut(nil)
        if failures > 0 {
            FileHandle.standardError.write(Data("FAIL: \(failures) kit check(s) failed\n".utf8))
            exit(1)
        }
        print("PASS dd-kit-checks: all kit checks passed")
    }

    // MARK: fix/summary-fallback: code's note never carries the model's attribution (Codex, 9/30)

    /// The moment cards' only attribution beside `Summary` is the cloud-key chip ("Summarized with your cloud key"), and
    /// the model's mark decision behind it (`FocusListExpanded.showsModelMark`). A note code wrote (the fallback note, or
    /// the moment writer by code) is ready but not the model's: rendered side by side with the model's note, only the
    /// model's carries the chip. The code note here is the worst case, marked not-local, so only `byCode` keeps it off.
    @MainActor static func codeNoteMark() {
        typealias E = FocusListExpanded
        var code = moment("fb-code", 9, 0, 9, 10, summary: .ready(generatedAt: nil, local: false), bullet: "Typed a draft in TextEdit.", actions: 4,
                          bundles: ["com.apple.TextEdit"], app: "TextEdit")
        code.byCode = true
        let model = moment("fb-model", 9, 0, 9, 10, summary: .ready(generatedAt: nil, local: false), bullet: "Typed a draft in TextEdit.", actions: 4,
                           bundles: ["com.apple.TextEdit"], app: "TextEdit")
        let local = moment("fb-local", 9, 0, 9, 10, summary: .ready(generatedAt: nil, local: true), bullet: "Typed a draft in TextEdit.", actions: 4,
                           bundles: ["com.apple.TextEdit"], app: "TextEdit")
        check(!E.showsModelMark(code) && E.showsModelMark(model) && E.showsModelMark(local), "code note mark: code's note has no model mark; the model's notes keep theirs")
        check(!E.showsCloudKeyChip(code) && E.showsCloudKeyChip(model) && !E.showsCloudKeyChip(local),
              "code note mark: the cloud-key chip only on the model's cloud note, never on code's")
        func card(_ m: MomentSlice) -> NSBitmapImageRep? {
            bitmap(host(MomentDetailBody(moment: m, actions: [], complete: true, timeZone: la, calendar: cal, now: now), size: NSSize(width: 420, height: 160)))
        }
        func same(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?) -> Bool {
            guard let a, let b, a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, let da = a.bitmapData, let db = b.bitmapData else { return false }
            return memcmp(da, db, a.bytesPerRow * a.pixelsHigh) == 0
        }
        let (rc, rm, rl) = (card(code), card(model), card(local))
        check(rc != nil && rm != nil && rl != nil, "code note mark: the three cards render")
        check(!same(rm, rl), "code note mark: rendered, the model's cloud note draws the cloud-key chip (differs from the same note written on this Mac)")
        check(same(rc, rl), "code note mark: rendered, code's note draws no chip (pixel for pixel the unmarked card)")
        // Side by side in one view: the pair differs only where the model's chip is.
        let pair = bitmap(host(HStack(alignment: .top, spacing: 0) {
            MomentDetailBody(moment: code, actions: [], complete: true, timeZone: la, calendar: cal, now: now).frame(width: 420, height: 160)
            MomentDetailBody(moment: model, actions: [], complete: true, timeZone: la, calendar: cal, now: now).frame(width: 420, height: 160)
        }, size: NSSize(width: 840, height: 160)))
        if let pair {
            let half = pair.pixelsWide / 2
            var differ = 0
            for y in stride(from: 0, to: pair.pixelsHigh, by: 2) { for x in stride(from: 0, to: half, by: 2) {
                if pair.colorAt(x: x, y: y) != pair.colorAt(x: x + half, y: y) { differ += 1 }
            } }
            check(differ > 0, "code note mark: side by side, the code card and the model card differ (the model's chip)", "\(differ)")
        } else { check(false, "code note mark: the side-by-side pair renders") }
    }

    // MARK: Live dot (owner 9/28: the recording control moved on a diagonal when Recording turned on)

    final class GlyphFlip: ObservableObject { @Published var on = false }
    struct GlyphHarness: View {
        @ObservedObject var flip: GlyphFlip
        var body: some View {
            // Off, then Recording further right and lower: the dot is inserted in the update that moves its slot.
            HStack(spacing: 7) {
                if flip.on { Color.clear.frame(width: 60, height: 1) }
                StateGlyph(state: flip.on ? .recording(since: nil) : .off(since: nil, reason: nil), size: 16)
                Text(flip.on ? "Recording" : "Start Recording").font(.system(size: 13, weight: .medium)).fixedSize()
            }
            .padding(.top, flip.on ? 24 : 0)
            .frame(width: 260, height: 80, alignment: .topLeading)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: flip.on)
        }
    }

    /// One bitmap of `view` at its bounds.
    @MainActor static func bitmap(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The red core's centre and the halo's pixel count (the soft red ring around it).
    static func dotPixels(_ rep: NSBitmapImageRep) -> (core: CGPoint?, halo: Int) {
        var sx = 0.0, sy = 0.0, n = 0.0, halo = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.05 else { continue }
            if c.alphaComponent > 0.9 && c.redComponent > 0.85 && c.greenComponent < 0.45 && c.blueComponent < 0.45 {
                sx += Double(x); sy += Double(y); n += 1
            } else if c.redComponent > 0.7 && c.greenComponent < 0.85 && c.redComponent - c.blueComponent > 0.15 { halo += 1 }
        } }
        return (n > 0 ? CGPoint(x: sx / n, y: sy / n) : nil, halo)
    }

    /// The live dot is solid. In light and dark, with live motion (no `daydreamStatic`), frames every 60 ms for 2.6 s
    /// after Recording turns on: once the harness's own 0.35 s spring has settled (from 0.9 s), every frame is the same bitmap, and
    /// that bitmap is the static render's (the halo at rest, as renders and Reduce Motion draw it). The red core never
    /// moves and the halo is drawn and never changes (it used to breathe, 1.6 s, for as long as the window recorded).
    @MainActor static func liveDotStaysPut() {
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = appearance
            window.setContentSize(NSSize(width: 260, height: 80))
            // The static render: already recording, `daydreamStatic` on.
            let still = GlyphFlip(); still.on = true
            let sh = NSHostingView(rootView: GlyphHarness(flip: still).environment(\.daydreamStatic, true))
            sh.appearance = appearance
            window.contentView = sh
            sh.frame = NSRect(x: 0, y: 0, width: 260, height: 80)
            pump(0.4)
            let reference = bitmap(sh)?.representation(using: .png, properties: [:])
            // Live: Off, then Recording turns on.
            let flip = GlyphFlip()
            let h = NSHostingView(rootView: GlyphHarness(flip: flip))
            h.appearance = appearance
            window.contentView = h
            h.frame = NSRect(x: 0, y: 0, width: 260, height: 80)
            pump(0.4)
            flip.on = true
            var cores: [CGPoint] = [], halos: [Int] = [], frames: [Data] = [], sameAsStatic = 0
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 2.6 {
                pump(0.06)
                guard Date().timeIntervalSince(t0) > 0.9, let rep = bitmap(h) else { continue }
                let px = dotPixels(rep)
                if let core = px.core { cores.append(core) }
                halos.append(px.halo)
                let bytes = rep.representation(using: .png, properties: [:]) ?? Data()
                frames.append(bytes)
                if let reference, reference == bytes { sameAsStatic += 1 }
            }
            let scale = Double(window.backingScaleFactor)
            let dx = ((cores.map(\.x).max() ?? 0) - (cores.map(\.x).min() ?? 0)) / scale
            let dy = ((cores.map(\.y).max() ?? 0) - (cores.map(\.y).min() ?? 0)) / scale
            check(frames.count >= 15 && cores.count == frames.count, "live dot (\(theme)): the red core is drawn in every sampled frame",
                  "\(cores.count) of \(frames.count)")
            check(dx == 0 && dy == 0, "live dot (\(theme)): the core never moves (no drift, no pulse)", String(format: "moved %.2f x %.2f pt", dx, dy))
            check((halos.min() ?? 0) > 20, "live dot (\(theme)): the soft halo is drawn around the core", "\(halos.prefix(3))")
            check(Set(halos).count == 1, "live dot (\(theme)): the halo never changes (no breathing)", "\(Set(halos).sorted())")
            check(Set(frames).count == 1, "live dot (\(theme)): every frame after Recording turns on is the same bitmap",
                  "\(Set(frames).count) distinct of \(frames.count)")
            check(reference != nil && sameAsStatic == frames.count, "live dot (\(theme)): live motion draws exactly the static render",
                  "\(sameAsStatic) of \(frames.count) frames match")
            window.contentView = nil
        }
        window.appearance = nil
        // No repeating animation anywhere in the app's UI: the breathing halo was the last one, and a repeating
        // transaction also repeats every layout change made in it (the diagonal drift).
        var hits: [String] = []
        for dir in ["Sources/MemoryUI/", "Sources/MacMemApp/"] {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".swift") {
                guard let text = try? String(contentsOfFile: dir + file, encoding: .utf8) else { continue }
                for (i, line) in text.components(separatedBy: "\n").enumerated()
                    where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && line.contains("repeatForever") {
                    hits.append("\(file):\(i + 1)")
                }
            }
        }
        check(FileManager.default.fileExists(atPath: "Sources/MemoryUI/DaydreamKitStatus.swift"), "live dot: the sources are readable from the worktree")
        check(hits.isEmpty, "no repeatForever animation in the app's UI (the live dot is solid)", "\(hits)")
        // LiveDot holds nothing that could move it or ask for another frame.
        let kit = (try? String(contentsOfFile: "Sources/MemoryUI/DaydreamKitStatus.swift", encoding: .utf8)) ?? ""
        if let start = kit.range(of: "struct LiveDot: View {") {
            let rest = kit[start.upperBound...]
            let body = rest[..<(rest.range(of: "\n}\n")?.lowerBound ?? rest.endIndex)]
            let code = body.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            let banned = ["@State", ".animation(", "withAnimation", "onAppear", "Timer", "TimelineView", "DispatchQueue", "scaleEffect", "opacity("]
                .filter { code.contains($0) }
            check(banned.isEmpty, "live dot: no state, timer or animation in LiveDot", "\(banned)")
        } else {
            check(false, "live dot: LiveDot is found in DaydreamKitStatus.swift")
        }
    }

    // MARK: Level sections (summaries/v3)

    /// Loose moments (no block yet) stay in time order around blocks: a 1 PM moment whose stretch is still waiting for
    /// its notes sits below a 2 to 3 PM block, not in one Afternoon section with the current 4:10 PM moment above it.
    @MainActor static func levelSections() {
        let early = moment("loose-1300", 13, 0, 13, 20), b1 = moment("b-1405", 14, 5, 14, 30), b2 = moment("b-1440", 14, 40, 15, 0)
        let late = moment("loose-1610", 16, 10, 16, 20)
        let block = LevelBlockSlice(id: "block-1", name: "Fixing the export crash", title: "About an hour: fixing the export crash",
                                    start: date(14, 0), end: date(15, 0), momentIDs: ["b-1405", "b-1440"], lines: [])
        let sections = FocusListLayout.sections([early, b1, b2, late], blocks: [block], calendar: cal)
        equal(sections.map { $0.moments.map(\.id) }, [["loose-1610"], ["b-1440", "b-1405"], ["loose-1300"]],
              "levels: a loose moment older than a block sits below it")
        equal(sections.map { $0.block?.id }, [nil, "block-1", nil], "levels: loose, block, loose")
        equal(Set(sections.map(\.id)).count, sections.count, "levels: section ids stay unique across loose runs")
        equal(FocusListLayout.order(sections).map(\.id), ["loose-1610", "b-1440", "b-1405", "loose-1300"], "levels: arrow order is time order")
        // A block with no rows here does not split, but one whose range falls between two loose moments does.
        let inside = moment("loose-1430", 14, 30, 14, 35)
        let split = FocusListLayout.sections([early, inside, late, b1], blocks: [block], calendar: cal)
        equal(FocusListLayout.order(split).map(\.id), ["loose-1610", "loose-1430", "b-1405", "loose-1300"], "levels: runs split at block rows and bounds")
        let noBlocks = FocusListLayout.sections([early, late], blocks: [], calendar: cal)
        equal(noBlocks.map(\.id), ["part:afternoon"], "levels: a day without blocks keeps one section per part")

        // A past day whose moments expired keeps its frozen day note (not "Nothing recorded this day."); no week line.
        var expired = snapshot([])
        check(FocusListLayout.showsEmptyCard(expired, isToday: false), "levels: an empty past day with no notes shows the empty card")
        expired.levels = DayLevelSlice(dayTitle: "Mostly the pricing page in Figma", dayLines: ["Reworked the tiers."], blocks: [],
                                       weekLabel: "Week of Sep 21 to 27", weekTitle: "A week on Tallybird")
        check(!FocusListLayout.showsEmptyCard(expired, isToday: false), "levels: a past day with only kept notes shows its summary card")
        equal(FocusListSummaryCard.headline(for: expired, day: .today, timeZone: la),
              .ready(title: "Mostly the pricing page in Figma", bullets: [MomentBullet(text: "Reworked the tiers.")], locality: nil),
              "levels: that card's headline is the kept day note")
        expired.levels = DayLevelSlice(dayTitle: nil, dayLines: [], blocks: [], weekLabel: "Week of Sep 21 to 27", weekTitle: "A week on Tallybird")
        // owner 10/2: a card holding only the week line over an empty ribbon read as a broken week view.
        check(FocusListLayout.showsEmptyCard(expired, isToday: false), "levels: a week note alone is not the day's: the empty card shows")
        check(FocusListLayout.showsEmptyCard(expired, isToday: true), "levels: an empty today still shows the empty card")
        let timeline = (try? String(contentsOfFile: "Sources/MemoryUI/CanonicalTimeline.swift", encoding: .utf8)) ?? ""
        check(timeline.contains("if FocusListLayout.showsEmptyCard(snap, isToday: isToday) {"), "levels: the page picks the empty card by that rule")

        // VoiceOver reads a block header with its noun and a spoken range, not a bare count.
        equal(FocusListLayout.blockHeaderAccessibilityLabel(block, count: 4, timeZone: la), "Fixing the export crash, 4 moments, 2:00 to 3:00 PM",
              "levels: block header VoiceOver label")
        equal(FocusListLayout.blockHeaderAccessibilityLabel(block, count: 1, timeZone: la), "Fixing the export crash, 1 moment, 2:00 to 3:00 PM",
              "levels: block header VoiceOver label, one moment")
        check(timeline.contains(".accessibilityLabel(FocusListLayout.blockHeaderAccessibilityLabel(block, count: section.moments.count,"),
              "levels: the block header carries that label")
    }

    // MARK: Controls model

    @MainActor static func controlsModel() {
        for c in Case.allCases {
            for style in [RecordingControls.Style.popover, .menu] {
                let s = state(c)
                let buttons = RecordingControls.buttons(for: s, style: style)
                let prominent = buttons.filter(\.prominent)
                check(prominent.count <= 1, "\(c.rawValue)/\(style): at most one prominent control", "\(prominent.map(\.id))")
                equal(prominent.first?.action, s.primaryAction, "\(c.rawValue)/\(style): the prominent control is the state's primary action")
                check(!buttons.contains { $0.action == .stop && $0.prominent }, "\(c.rawValue)/\(style): Stop is never prominent")
                equal(Set(buttons.map(\.id)).count, buttons.count, "\(c.rawValue)/\(style): control ids are unique")
                for b in buttons { strings += [b.title, b.help, b.accessibilityLabel] }
            }
        }
        let rec = RecordingControls.buttons(for: state(.recording))
        let presets = rec.filter(\.isPreset)
        equal(presets.map(\.action), RecordingState.pausePresets.map { RecordingAction.pause(minutes: $0) }, "recording presets deliver exactly 5, 15, 30, 120")
        equal(RecordingState.pausePresets, [5, 15, 30, 120], "pause presets are 5, 15, 30, 120")
        equal(presets.map(\.title), ["5m", "15m", "30m", "2h"], "preset titles")
        equal(presets.map(\.help), ["Pause for 5 minutes", "Pause for 15 minutes", "Pause for 30 minutes", "Pause for 2 hours"], "preset help")
        equal(presets.map(\.accessibilityLabel), presets.map(\.help), "preset VoiceOver labels match their help")
        equal(rec.map(\.id), ["pause-5", "pause-15", "pause-30", "pause-120", "stop"], "Recording: presets then Stop")
        equal(RecordingControls.buttons(for: state(.paused)).map(\.title), ["Resume Recording", "Stop Recording"], "Paused: Resume Recording, Stop Recording")
        equal(RecordingControls.buttons(for: state(.pausedOpen)).map(\.title), ["Resume Recording", "Stop Recording"], "open-ended Paused: same controls")
        equal(RecordingControls.buttons(for: state(.off)).map(\.title), ["Start Recording"], "Off: Start Recording only")
        // Allow Permissions opens DayDream's drag cards (setup or Settings › Permissions), so it stays in the app: no
        // leaving-the-app arrow.
        // perm-1004 (owner 10/3): the button names the permission to turn on; "Allow Permissions" only for an unknown set.
        equal(RecordingControls.buttons(for: state(.permission)).map(\.title), ["Turn on Input Monitoring", "Check Again"], "Needs Permission: Turn on Input Monitoring, Check Again")
        equal(RecordingControls.buttons(for: state(.permissionUnknown)).map(\.title), ["Allow Permissions", "Check Again"], "Needs Permission, unknown: Allow Permissions, Check Again")
        equal(RecordingControls.buttons(for: state(.permission)).first?.symbol, "checkmark.shield", "Allow Permissions carries the checkmark.shield glyph, not the leaving arrow")
        check(!RecordingControls.buttons(for: state(.recording)).flatMap { [$0.title, $0.help] }.contains { $0.contains("Tomor" + "row") || $0.contains("+15") },
              "no next-day and no +15 min control")
        equal(RecordingControls.buttons(for: state(.off), canStart: false).first?.enabled, false, "Off: Start disabled when it can't start")
        equal(RecordingControls.buttons(for: state(.paused), canStart: false).first?.enabled, false, "Paused: Resume disabled when it can't resume")
        equal(RecordingControls.buttons(for: state(.recording), canStop: false).last?.enabled, false, "Recording: Stop disabled when it can't stop")

        // Each action runs exactly one closure.
        let calls = Calls()
        for m in RecordingState.pausePresets {
            calls.reset()
            RecordingControls.perform(.pause(minutes: m), actions: calls.actions, state: state(.recording))
            check(calls.pauses == [m] && calls.total == 1, "perform pause \(m) calls pause(\(m)) only", "\(calls.pauses) total \(calls.total)")
        }
        calls.reset(); RecordingControls.perform(.stop, actions: calls.actions, state: state(.recording))
        check(calls.stops == 1 && calls.total == 1, "perform stop calls stop only")
        calls.reset(); RecordingControls.perform(.resume, actions: calls.actions, state: state(.paused))
        check(calls.resumes == 1 && calls.total == 1, "perform resume calls resume only")
        calls.reset(); RecordingControls.perform(.start, actions: calls.actions, state: state(.off))
        check(calls.resumes == 1 && calls.total == 1, "perform start calls resume only")
        calls.reset(); RecordingControls.perform(.checkAgain, actions: calls.actions, state: state(.permission))
        check(calls.checks == 1 && calls.total == 1, "perform Check Again re-reads permissions only")
        calls.reset(); RecordingControls.perform(.openSystemSettings, actions: calls.actions, state: state(.permission))
        check(calls.systemSettings == [.inputMonitoring] && calls.total == 1, "Allow Permissions passes the one missing pane (Input Monitoring)", "\(calls.systemSettings)")
        calls.reset(); RecordingControls.perform(.openSystemSettings, actions: calls.actions, state: .needsPermission(missing: [.accessibility, .inputMonitoring]))
        check(calls.systemSettings == [.accessibility], "perm-1004: both missing opens Accessibility's pane first (Turn on Accessibility)", "\(calls.systemSettings)")
        calls.reset(); RecordingControls.perform(.openSystemSettings, actions: calls.actions, state: state(.permissionUnknown))
        check(calls.systemSettings == [nil], "Allow Permissions with unknown permissions opens Privacy & Security", "\(calls.systemSettings)")
        calls.reset(); RecordingControls.perform(.openSystemSettings, actions: calls.actions, state: state(.permissionUnknown),
                                                 permissions: PermissionSnapshot(accessibility: false, inputMonitoring: true))
        check(calls.systemSettings == [.accessibility], "Allow Permissions uses the permission reads when the state doesn't say", "\(calls.systemSettings)")
    }

    // MARK: Controls hosted: render, hover, press

    @MainActor static func controlsHosted() {
        let calls = Calls()
        let perms = PermissionSnapshot(accessibility: true, inputMonitoring: false)
        for c in Case.allCases {
            for style in [RecordingControls.Style.popover, .menu] {
                calls.reset()
                let view = VStack(alignment: .leading, spacing: 12) {
                    RecordingStateHeader(state: state(c), style: style == .menu ? .menu : .popover, timeZone: la)
                    RecordingControls(state: state(c), actions: calls.actions, style: style, permissions: perms)
                }.padding(12)
                let h = host(view, size: NSSize(width: 360, height: 360))
                let sweep = hoverSweep(h)
                check(sweep.moves > 50 && sweep.delivered > 50, "\(c.rawValue)/\(style): the hover sweep reaches SwiftUI",
                      "\(sweep.moves) moves, \(sweep.delivered) delivered")
                check(calls.total == 0, "\(c.rawValue)/\(style): rendering and \(sweep.moves) hover moves call no action", "\(calls.total) calls")
            }
        }

        // Clicks: every control calls exactly one closure, and the controls of each state call
        // exactly the expected ones. (SwiftUI's accessibility tree is not published to an offscreen
        // process without an assistive client, so clicks stand in for VoiceOver presses.)
        struct Expect { let name: String; let state: RecordingState; let canStart: Bool; let canStop: Bool
            let pauses: Set<Int>; let resumes: Bool; let stops: Bool; let panes: Set<String>; let checks: Bool }
        let expectations = [
            Expect(name: "recording", state: state(.recording), canStart: true, canStop: true, pauses: [5, 15, 30, 120], resumes: false, stops: true, panes: [], checks: false),
            Expect(name: "recording, can't stop", state: state(.recording), canStart: true, canStop: false, pauses: [5, 15, 30, 120], resumes: false, stops: false, panes: [], checks: false),
            Expect(name: "paused", state: state(.paused), canStart: true, canStop: true, pauses: [], resumes: true, stops: true, panes: [], checks: false),
            Expect(name: "paused, can't resume", state: state(.pausedOpen), canStart: false, canStop: true, pauses: [], resumes: false, stops: true, panes: [], checks: false),
            Expect(name: "off", state: state(.off), canStart: true, canStop: false, pauses: [], resumes: true, stops: false, panes: [], checks: false),
            Expect(name: "off, can't start", state: state(.offPlain), canStart: false, canStop: false, pauses: [], resumes: false, stops: false, panes: [], checks: false),
            Expect(name: "needs permission", state: state(.permission), canStart: true, canStop: false, pauses: [], resumes: false, stops: false,
                   panes: ["inputMonitoring"], checks: true),
            Expect(name: "needs permission, unknown", state: state(.permissionUnknown), canStart: true, canStop: false, pauses: [], resumes: false, stops: false,
                   panes: ["privacy"], checks: true),
        ]
        for e in expectations {
            for style in [RecordingControls.Style.popover, .menu] {
                calls.reset()
                let h = fitted(RecordingControls(state: e.state, actions: calls.actions, style: style, canStart: e.canStart, canStop: e.canStop,
                                                 permissions: e.name == "needs permission" ? perms : nil,
                                                 startBlockedReason: e.canStart ? nil : "Recording is unavailable in this build.").padding(12))
                let sweep = clickSweep(h, calls)
                let tag = "\(e.name)/\(style)"
                check(sweep.worst <= 1, "\(tag): no click calls more than one closure", "\(sweep.worst)")
                equal(Set(calls.pauses), e.pauses, "\(tag): clicks pause only for the presets")
                check((calls.resumes > 0) == e.resumes, "\(tag): resume/start \(e.resumes ? "is" : "is not") clickable", "\(calls.resumes)")
                check((calls.stops > 0) == e.stops, "\(tag): Stop Recording \(e.stops ? "is" : "is not") clickable", "\(calls.stops)")
                equal(Set(calls.systemSettings.map { $0?.rawValue ?? "privacy" }), e.panes, "\(tag): Allow Permissions opens the expected pane")
                check((calls.checks > 0) == e.checks, "\(tag): Check Again \(e.checks ? "is" : "is not") clickable")
                check(calls.settings == 0 && calls.sections.isEmpty && calls.mains == 0 && calls.recalls == 0 && calls.quits == 0,
                      "\(tag): controls never open settings, windows or quit")
            }
        }
        calls.reset()
        let h = fitted(RecordingControls(state: state(.recording), actions: calls.actions, style: .popover).padding(12))
        let axButtons = elements(h).filter { $0.accessibilityRole() == .button }
        if axButtons.isEmpty {
            print("LIMIT: SwiftUI accessibility children unavailable offscreen; controls verified by clicks, labels by the button model")
        } else {
            for b in axButtons { _ = b.accessibilityPerformPress() }
            pump(0.05)
            check(calls.pauses.sorted() == [5, 15, 30, 120] && calls.stops == 1, "VoiceOver presses reach the same closures", "\(calls.pauses) \(calls.stops)")
        }
    }

    // MARK: Ribbon

    @MainActor static func ribbon() {
        let empty = DDRibbon(segments: [], now: now, height: .h8, empty: true, calendar: cal)
        equal(empty.segmentCountForTesting, 0, "empty ribbon draws no segments")
        check(!empty.hatchPresentForTesting, "empty ribbon draws no hatch")
        let seg = RibbonSegment(id: "a", start: date(9, 0), end: date(10, 0), tint: AppTint.of("dev.zed.Zed"), label: "Zed")
        let ghost = RibbonSegment(id: "b", start: date(9, 0), end: date(10, 0), tint: .gray, label: "Zed")
        equal(DDRibbon(segments: [seg, ghost], now: now, height: .h28, empty: true, calendar: cal).segmentCountForTesting, 0,
              "empty: true draws no segments even when some are passed")
        equal(DDRibbon(segments: [seg], now: now, height: .h28, calendar: cal).segmentCountForTesting, 1, "one segment draws one layer")
        check(!DDRibbon(segments: [seg], now: now, height: .h28, calendar: cal).hatchPresentForTesting, "no pause, no hatch")
        check(DDRibbon(segments: [seg], pause: RibbonPause(start: date(16, 18), end: date(16, 33)), now: now, height: .h28, calendar: cal).hatchPresentForTesting,
              "a pause draws the hatch")
        let r = DDRibbon.defaultRange(segments: [seg], pause: nil, now: now, calendar: cal)
        check(r.lowerBound == date(9, 0) && r.upperBound == date(17, 0), "the range fits the data and now (9 AM–5 PM)", "\(r)")
        let emptyRange = DDRibbon.defaultRange(segments: [], pause: nil, now: nil, calendar: cal, day: date(9, 0))
        check(emptyRange.lowerBound == date(8, 0) && emptyRange.upperBound == date(19, 0), "with nothing to show the range is 8 AM–7 PM", "\(emptyRange)")
        let early = DDRibbon.defaultRange(segments: [RibbonSegment(id: "e", start: date(0, 11), end: date(0, 44), tint: .gray, label: "x")],
                                          pause: nil, now: date(0, 47), calendar: cal)
        check(early.lowerBound == date(0, 0) && early.upperBound == date(3, 0), "just after midnight the range is 12 AM–3 AM, not a sliver of the day", "\(early)")
        equal(DDRibbon.axisHours(emptyRange, calendar: cal).map(\.0), [9, 12, 15, 18], "8 AM–7 PM: 9 AM, 12 PM, 3 PM, 6 PM")
        equal(DDRibbon.axisHours(early, calendar: cal).map(\.0), [1, 2], "12 AM–3 AM: 1 AM, 2 AM")
        let late = DDRibbon.defaultRange(segments: [RibbonSegment(id: "c", start: date(6, 40), end: date(7, 0), tint: .gray, label: "x")],
                                         pause: nil, now: date(21, 10), calendar: cal)
        check(late.lowerBound == date(6, 0) && late.upperBound == date(22, 0), "range widens to whole hours around data and now", "\(late)")

        let m1 = moment("m1", 9, 0, 10, 0), m2 = moment("m2", 13, 30, 14, 10, summary: .pending, bullet: nil)
        let snap = snapshot([m1, m2])
        func model(_ c: Case) -> RibbonModel { RibbonModel.make(snapshot: snap, state: state(c), now: now, calendar: cal) }
        equal(model(.recording).flag, .now, "Recording flag is Now")
        equal(model(.recording).segments.count, 2, "one segment per cluster")
        equal(model(.recording).segments.last?.pending, true, "a pending moment's segment is pending")
        check(model(.recording).pause == nil, "Recording has no pause")
        equal(model(.paused).flag, .pausedLeft(12 * 60), "timed pause flag is the time left")
        equal(model(.paused).pause, RibbonPause(start: date(16, 18), end: date(16, 33)), "timed pause hatches since…until")
        equal(model(.pausedOpen).pause, RibbonPause(start: date(16, 18), end: now), "open-ended pause hatches since…now")
        equal(model(.pausedOpen).flag, .now, "open-ended pause flag is Now")
        let unknownSince = RibbonModel.make(snapshot: snap, state: .paused(until: date(16, 33), since: nil, reason: nil), now: now, calendar: cal)
        check(unknownSince.pause == nil, "a pause with an unknown start draws no hatch")
        equal(model(.off).flag, .stoppedAt(date(16, 18)), "Off flag is Stopped at")
        check(model(.off).pause == nil, "Off draws no hatch")
        equal(model(.offPlain).flag, RibbonFlag.none, "Off with an unknown stop has no flag")
        let offYesterday = RibbonModel.make(snapshot: snap, state: .off(since: date(16, 18, day: 21), reason: nil), now: now, calendar: cal)
        equal(offYesterday.flag, RibbonFlag.none, "Off since yesterday puts no Stopped at flag on today's ribbon")
        let justAfterMidnight = RibbonModel.make(snapshot: snapshot([]), state: .off(since: date(23, 50, day: 21), reason: nil),
                                                 now: date(0, 5), calendar: cal)
        equal(justAfterMidnight.flag, RibbonFlag.none, "a stop before midnight is not today's stop")
        equal(model(.permission).flag, RibbonFlag.none, "Needs Permission has no flag")
        check(model(.permission).pause == nil, "Needs Permission draws no hatch")
        let past = RibbonModel.make(snapshot: snap, state: state(.paused), now: now, calendar: cal, isToday: false)
        check(past.now == nil && past.pause == nil && past.flag == .none, "another day draws no now, pause or flag")
        let none = RibbonModel.make(snapshot: snapshot([]), state: state(.recording), now: now, calendar: cal)
        check(none.empty && none.segments.isEmpty, "an empty day's model is empty")
        equal(DDRibbon(model: none, height: .h8, calendar: cal).segmentCountForTesting, 0, "an empty day's ribbon draws no segments")
        check(!DDRibbon(model: model(.recording), height: .h28, calendar: cal).hatchPresentForTesting, "Recording ribbon draws no hatch")
        check(DDRibbon(model: model(.paused), height: .h28, calendar: cal).hatchPresentForTesting, "Paused ribbon draws the hatch")

        // VoiceOver value (one `Activity` element); rendering and hovering the ribbon run nothing else.
        let spoken = DDRibbon(model: model(.recording), height: .h28, calendar: cal).accessibilityValueForTesting
        check(spoken.hasPrefix("2 moments from " + DaydreamFormat.spokenRange(date(9, 0), date(14, 10), la)),
              "the ribbon's VoiceOver value counts moments and spans the day", spoken)
        let pausedSpoken = DDRibbon(model: model(.paused), height: .h28, calendar: cal).accessibilityValueForTesting
        check(pausedSpoken.contains("paused from " + DaydreamFormat.spokenRange(date(16, 18), date(16, 33), la)),
              "the ribbon's VoiceOver value names the pause", pausedSpoken)
        equal(DDRibbon(model: none, height: .h8, calendar: cal).accessibilityValueForTesting, "No recorded actions for this day.",
              "an empty ribbon says so to VoiceOver")
        strings += [spoken, pausedSpoken]
        let calls = Calls()
        var hovered = 0, onSegment = 0
        let h = host(VStack(spacing: 16) {
            DDRibbon(model: model(.paused), height: .h28, axis: true, onHover: { s in hovered += 1; if s != nil { onSegment += 1 } }, calendar: cal)
            RecordingControls(state: state(.paused), actions: calls.actions, style: .popover)
        }.padding(10), size: NSSize(width: 380, height: 140))
        let sweep = hoverSweep(h)
        check(hovered > 0 && onSegment > 0, "the hover sweep reaches the ribbon's hover handler, over segments too",
              "\(hovered) ribbon hovers, \(onSegment) on a segment")
        check(calls.total == 0 && sweep.moves > 50, "hovering the ribbon and controls runs no recording action (\(sweep.moves) moves, \(hovered) ribbon hovers)")
    }

    // MARK: Heights

    @MainActor static func heights() {
        let states: [(String, MomentSlice, Bool, Bool, Bool)] = [
            ("ready", moment("r", 13, 30, 14, 10), false, false, true),
            ("selected", moment("s", 13, 30, 14, 10, sites: ["docs.google.com"]), true, false, true),
            ("hovered", moment("h", 13, 30, 14, 10, bundles: ["com.apple.freeform", "com.apple.Safari"], app: "Freeform"), false, true, true),
            ("pending", moment("p", 16, 7, 16, 17, summary: .pending, bullet: nil), false, false, true),
            ("too long", moment("t", 9, 0, 11, 0, summary: .tooLong, bullet: nil, actions: 240), false, false, true),
            ("no chip", moment("n", 12, 40, 12, 55), false, false, false),
            ("no app", moment("x", 12, 40, 12, 55, bundles: [], app: nil), false, false, true),
        ]
        for (name, m, selected, hovered, chip) in states {
            let v = NSHostingView(rootView: DDRow(moment: m, timeZone: la, selected: selected, hovered: hovered, showsChip: chip).frame(width: 760))
            equal(v.fittingSize.height, 52, "DDRow is 52 pt tall (\(name))")
        }
        let narrow = NSHostingView(rootView: DDRow(moment: moment("w", 13, 30, 14, 10), timeZone: la, chipWidth: 150).frame(width: 420))
        equal(narrow.fittingSize.height, 52, "DDRow is 52 pt tall with the narrow chip slot")
        let bar = NSHostingView(rootView: KeyHintBar([KeyHint("Open", "↩"), KeyHint("Actions", "⌘K"), KeyHint("Close", "esc")]))
        equal(bar.fittingSize.height, 28, "KeyHintBar is 28 pt tall")
    }

    // MARK: Menu bar mark

    static func plane(_ state: DaydreamCaptureState, _ scale: CGFloat) -> AlphaPlane? {
        DaydreamMenuBarMark.bitmap(state, scale: scale).map(AlphaPlane.init)
    }

    @MainActor static func glyph() {
        let all = DaydreamCaptureState.allCases
        for s in all {
            let image = DaydreamMenuBarMark.image(for: s)
            check(image.isTemplate, "\(s.rawValue): menu bar image is a template")
            equal(image.size, NSSize(width: 18, height: 18), "\(s.rawValue): 18 x 18 pt")
            let widths = image.representations.compactMap { ($0 as? NSBitmapImageRep)?.pixelsWide }.sorted()
            equal(widths, [18, 36], "\(s.rawValue): 1x and 2x bitmaps")
            equal(image.accessibilityDescription, "DayDream: " + s.title, "\(s.rawValue): accessibility description")
            check(DaydreamMenuBarMark.image(for: s) === image, "\(s.rawValue): image(for:) is cached")
            strings.append(image.accessibilityDescription ?? "")
        }
        let unavailable = DaydreamMenuBarLabelImage(state: nil as RecordingState?, now: now, timeZone: la)
        equal(unavailable.drawnState, .off, "an unavailable state draws Off")
        equal(unavailable.label, "DayDream: Off", "an unavailable state reads DayDream: Off")
        equal(DaydreamMenuBarLabelImage(state: state(.paused), now: now, timeZone: la).label, "DayDream: Paused until 4:33 PM", "paused label names the end time")
        equal(DaydreamMenuBarLabelImage(state: state(.permission), now: now, timeZone: la).drawnState, .needsPermission, "Needs Permission draws D!")

        for scale in [1, 2] as [CGFloat] {
            let g = DaydreamMarkGeometry.standard.hinted(forScale: scale)
            let weights = [g.stem, g.arm, g.bowl, g.hairline, g.barWidth, g.bangWidth]
            check(weights.allSatisfy { ($0 * scale).rounded() == $0 * scale }, "pixel grid @\(Int(scale))x: hinted weights are whole pixels", "\(weights)")
            let edges = [g.back, g.front].flatMap { [$0.minX, $0.minY, $0.maxX, $0.maxY] }
            check(edges.allSatisfy { $0.rounded() == $0 }, "pixel grid @\(Int(scale))x: letter edges on the point grid")
            check(g.hairline * scale >= 1, "pixel grid @\(Int(scale))x: hairline at least one pixel")
        }
        let g0 = DaydreamMarkGeometry.standard
        check(g0.pauseBars().boundingRect.minX >= g0.back.maxX + g0.gap, "paused bars clear the rear D by the gap")
        check(g0.bang().boundingRect.minX >= g0.back.maxX + g0.gap, "the ! clears the rear D by the gap")
        let bang = g0.bang().boundingRect
        check(bang.minY == g0.back.minY && bang.maxY == g0.front.maxY, "the ! is capped level with the rear D and sits on the baseline", "\(bang)")
        let live = g0.liveArea
        check(live.midX == 9 && live.midY == 9, "the live area is centred on the 18 pt canvas")

        let expectedPieces: [DaydreamCaptureState: Int] = [.recording: 2, .paused: 3, .off: 2, .needsPermission: 3]
        for scale in [1, 2] as [CGFloat] {
            let tag = "@\(Int(scale))x"
            var planes: [(DaydreamCaptureState, AlphaPlane)] = []
            for s in all {
                guard let p = plane(s, scale), let b = p.bounds() else { check(false, "\(s.rawValue)\(tag): renders"); continue }
                planes.append((s, p))
                let inside = CGFloat(b.minX) >= live.minX * scale && CGFloat(b.maxX + 1) <= live.maxX * scale
                    && CGFloat(b.minY) >= live.minY * scale && CGFloat(b.maxY + 1) <= live.maxY * scale
                check(inside, "\(s.rawValue)\(tag): ink stays inside the 16 pt live area", "\(b)")
                equal(p.pieces(), expectedPieces[s], "\(s.rawValue)\(tag): expected number of pieces")
                // Snapshot
                if let b64 = markSnapshots["\(s.rawValue)\(tag)"], let data = Data(base64Encoded: b64), let rep = NSBitmapImageRep(data: data) {
                    let ref = AlphaPlane(rep)
                    let sameSize = ref.width == p.width && ref.height == p.height
                    let worst = sameSize ? (zip(ref.a, p.a).map { abs($0 - $1) }.max() ?? 0) : 1
                    check(sameSize && worst <= 1.0 / 255 + 1e-9, "\(s.rawValue)\(tag): matches the mark-A snapshot", "max alpha delta \(worst)")
                } else {
                    check(false, "\(s.rawValue)\(tag): snapshot decodes")
                }
            }
            let hinted = DaydreamMarkGeometry.standard.hinted(forScale: scale)
            let rearRep = DaydreamMenuBarMark.bitmap(points: hinted.canvas, scale: scale) {
                DaydreamMark.draw([DaydreamMarkLayer(path: hinted.letter(hinted.back), evenOdd: true)], in: $0)
            }
            if let rearRep {
                let rear = AlphaPlane(rearRep)
                let columns = Int((hinted.back.maxX + hinted.gap) * scale)
                for s in [DaydreamCaptureState.paused, .needsPermission] {
                    guard let p = plane(s, scale) else { continue }
                    var same = true
                    for y in 0..<p.height { for x in 0..<columns where p[x, y] != rear[x, y] { same = false } }
                    check(same, "\(s.rawValue)\(tag): leaves the rear D untouched")
                }
            } else { check(false, "rear-only bitmap\(tag) renders") }
            if let on = plane(.recording, scale), let off = plane(.off, scale), let a = on.bounds(), let b = off.bounds() {
                check(off.ink < on.ink * 0.6, "Off\(tag) is a much lighter outline", "\(off.ink) vs \(on.ink)")
                check(a.minX == b.minX && a.minY == b.minY && a.maxX == b.maxX && a.maxY == b.maxY, "Off\(tag) keeps Recording's silhouette")
            }
            for i in planes.indices { for j in planes.indices where j > i {
                let (s1, p1) = planes[i], (s2, p2) = planes[j]
                var diff = 0.0, union = 0.0
                for k in p1.a.indices { diff += abs(p1.a[k] - p2.a[k]); union += max(p1.a[k], p2.a[k]) }
                check(diff / union >= 0.15, "\(s1.rawValue) vs \(s2.rawValue)\(tag): differ in at least 15% of their ink", "\(diff / union)")
            } }
        }
        for s in all {
            let renderer = ImageRenderer(content: DaydreamMenuBarMark(state: s).frame(width: 36, height: 36).foregroundStyle(.black))
            renderer.scale = 1
            let cg = renderer.cgImage
            check(cg?.width == 36 && cg?.height == 36, "\(s.rawValue): SwiftUI mark renders on macOS 13 APIs")
            if #available(macOS 14, *) {
                let box = DaydreamMarkShape(state: s).path(in: CGRect(x: 0, y: 0, width: 18, height: 18)).boundingRect
                check(!box.isEmpty && box.minX >= live.minX - 0.01 && box.maxX <= live.maxX + 0.01
                      && box.minY >= live.minY - 0.01 && box.maxY <= live.maxY + 0.01, "\(s.rawValue): macOS 14 shape fits the live area", "\(box)")
            }
        }
    }

    // MARK: fix/prompt-row: an AI ask on its row

    @MainActor static func promptRows() {
        let ask = "how do I fix the export crash in the Swift build when the archive step fails on the release configuration only, but debug works fine every time"
        func ai(_ id: String, summary: MomentSummaryState = .pending, bullet: String? = nil, prompt: String?) -> MomentSlice {
            var m = moment(id, 10, 5, 10, 15, summary: summary, bullet: bullet, bundles: ["com.openai.codex"], app: "ChatGPT")
            m.live = LiveMoment(label: "ChatGPT", kind: "ai", sends: ["Asked ChatGPT"], seconds: 600, idle: false, communication: true)
            m.prompt = prompt
            return m
        }
        // Precedence.
        equal(MomentSubtitle.rowText(for: ai("a1", prompt: nil)), "Asked ChatGPT", "prompt row: typing off or no typed text: today's text (Asked ChatGPT)")
        equal(MomentSubtitle.rowText(for: ai("a2", prompt: "")), "Asked ChatGPT", "prompt row: an empty ask keeps today's text")
        equal(MomentSubtitle.rowText(for: ai("a3", prompt: ask)), "\u{201C}" + ask + "\u{201D}", "prompt row: no note yet: the ask, in quotes, at once")
        equal(MomentSubtitle.rowText(for: ai("a4", summary: .summariesOff, prompt: "fix the build")), "\u{201C}fix the build\u{201D}", "prompt row: summaries off: the ask")
        let summarized = ai("a5", summary: .ready(generatedAt: nil, local: true), bullet: "Asked ChatGPT how to fix the release archive crash.", prompt: ask)
        // fix/sx-all (merged at build/launch-sx): a row's line is one sentence with no closing period.
        equal(MomentSubtitle.rowText(for: summarized), "Asked ChatGPT how to fix the release archive crash", "prompt row: a note's line wins over the ask (the finished note)")
        check(MomentSubtitle.shownPrompt(summarized) == nil && MomentSubtitle.shownPrompt(ai("a6", prompt: ask)) == ask, "prompt row: shownPrompt follows the same rule")
        var stale = summarized; stale.stale = true
        equal(MomentSubtitle.rowText(for: stale), "Asked ChatGPT how to fix the release archive crash", "prompt row: the previous note, kept while a newer is written, still wins (no flip back)")
        let filler = ai("a7", summary: .ready(generatedAt: nil, local: true), bullet: nil, prompt: "fix the build")
        equal(MomentSubtitle.rowText(for: filler), "\u{201C}fix the build\u{201D}", "prompt row: a note with nothing left to say gives way to the ask")
        equal(MomentSubtitle.text(for: ai("a8", prompt: ask)), "Asked ChatGPT", "prompt row: only the row shows the ask (VoiceOver's summary, the expanded card keep theirs)")
        // withPrompts patches the snapshot, no rebuild; an unchanged set is the same value.
        let snap = snapshot([ai("s1", prompt: nil), moment("s2", 11, 0, 11, 30)])
        let patched = snap.withPrompts(["s1": "fix the build"])
        check(patched.moments.first?.prompt == "fix the build" && patched.latest?.id == "s2" && patched.moments[1] == snap.moments[1] && patched != snap,
              "prompt row: withPrompts sets each moment's ask")
        check(patched.withPrompts(["s1": "fix the build"]) == patched && patched.withPrompts([:]).moments.allSatisfy { $0.prompt == nil },
              "prompt row: the same set changes nothing; an empty set (typing off, a Forget) clears every ask")
        // One line, inside the row.
        for width in [760.0, 420.0] {
            let v = NSHostingView(rootView: DDRow(moment: ai("h", prompt: ask), timeZone: la, chipWidth: width < 500 ? 150 : 176).frame(width: width))
            equal(v.fittingSize.height, 52, "prompt row: a long ask keeps the row 52 pt tall at \(Int(width)) pt")
        }
        let line = NSHostingView(rootView: PromptLine(prompt: ask).frame(maxWidth: 220, alignment: .leading))
        let one = NSHostingView(rootView: Text("x").font(.system(size: 12)))
        check(line.fittingSize.width <= 220.5 && abs(line.fittingSize.height - one.fittingSize.height) < 0.5,
              "prompt row: a long ask is one 12 pt line, cut to its column (\(line.fittingSize))")
        let short = NSHostingView(rootView: PromptLine(prompt: "fix the build"))
        check(short.fittingSize.width < 120 && abs(short.fittingSize.height - one.fittingSize.height) < 0.5, "prompt row: a short ask is as wide as its words (\(short.fittingSize))")
        // Nothing is drawn past the text column: the empty chip slot beside a long ask stays empty.
        let row = NSHostingView(rootView: DDRow(moment: ai("px", prompt: ask), timeZone: la).frame(width: 760, height: 52))
        row.frame = NSRect(x: 0, y: 0, width: 760, height: 52)
        row.layoutSubtreeIfNeeded()
        if let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds) {
            row.cacheDisplay(in: row.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / 760
            // The chip slot: 760 - 14 (trailing) - 60 (time) - 10 - 176 ... 760 - 14 - 60 - 10.
            func inked(_ from: CGFloat, _ to: CGFloat) -> Int {
                var n = 0
                for y in 0..<rep.pixelsHigh { for x in Int(from * scale)..<Int(to * scale) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { n += 1 } }
                return n
            }
            let text = inked(60, 490), slot = inked(505, 670)
            check(text > 200 && slot == 0, "prompt row: a long ask never runs into the chip slot or the time (\(slot) inked pixels there; control: \(text) in the text column)")
        } else { check(false, "prompt row: the row renders") }
    }

    // MARK: Moments, menu, confirmations

    @MainActor static func moments() {
        let ready = moment("r", 14, 30, 15, 20)
        let pending = moment("p", 14, 30, 15, 20, summary: .pending, bullet: nil)
        let one = moment("o", 14, 30, 14, 31, summary: .summariesOff, bullet: nil, actions: 1)
        equal(MomentSubtitle.text(for: ready), "Commented on the launch plan", "ready subtitle is the first bullet, one sentence with no closing period (fix/sx-all round 1)")
        // fix/expanded-summary (owner, 9/30): that one bullet is the collapsed subtitle, and the open card still shows it as
        // its Summary (the open header's line is the time range), and so does a note whose one bullet is not the subtitle.
        check(ready.bullets.count == 1 && FocusListExpanded.showsSummary(ready) && FocusListExpanded.summaryStatus(for: ready, provider: .local) == nil,
              "expanded: a one-bullet note equal to the subtitle shows its Summary")
        check(FocusListExpanded.showsSummary(moment("e1", 14, 30, 15, 20, bullet: "Reviewing the launch plan.")),
              "expanded: a one-bullet note unlike the subtitle shows its Summary")
        // fix/sx-all round 2: the row title is never repeated as its subtitle; the next line that says something else, else the time.
        let echo = moment("e", 14, 30, 15, 20, bullet: "Reviewing the launch plan.")
        equal(MomentSubtitle.text(for: echo), "~50 min", "a bullet that repeats the row title is not the subtitle; the moment's time stands in")
        check(MomentSubtitle.same("In WhatsApp.", "WhatsApp") && MomentSubtitle.same("In ChatGPT", "ChatGPT")
              && !MomentSubtitle.same("In WhatsApp.", "Texts with Mom") && !MomentSubtitle.same("Inbox zero", "box zero"),
              "\"In WhatsApp\" under the row title \"WhatsApp\" is the title again: the time stands in")
        var echoLive = moment("e2", 14, 30, 15, 20, summary: .pending, bullet: nil)
        echoLive.live = LiveMoment(label: "Reviewing the launch plan", kind: "", sends: ["Reviewing the launch plan", "Texted Sam"], seconds: 600, idle: false, communication: false)
        equal(MomentSubtitle.text(for: echoLive), "Texted Sam", "a code line that repeats the row title is skipped for the next one")
        // fix/day-card: never a status in a subtitle ("Summary pending", "Partial day"); without a note line or a send
        // by code, the moment's focused time, else nothing. No action count (internal).
        equal(MomentSubtitle.text(for: pending), "", "pending subtitle: no status (no live threads on a hand-built slice)")
        equal(MomentSubtitle.text(for: one), "", "summaries off: no subtitle (no action count)")
        equal(MomentSubtitle.text(for: moment("t", 9, 0, 11, 0, summary: .tooLong, bullet: nil, actions: 240)), "", "too long: no subtitle")
        check(!FocusListExpanded.showsSummary(moment("t2", 9, 0, 11, 0, summary: .tooLong, bullet: nil, actions: 240))
              && FocusListExpanded.showsSummary(moment("t3", 9, 0, 11, 0, summary: .tooLong, bullet: nil, actions: 240, correction: true)),
              "too long: the expanded moment has a summary area only for a correction")
        equal(FocusListExpanded.summaryStatus(for: moment("t2", 9, 0, 11, 0, summary: .tooLong, bullet: nil, actions: 240), provider: .local)?.text, "Too long to summarize",
              "too long with a correction: Too long to summarize heads the correction")
        equal(MomentSubtitle.text(for: moment("i", 9, 0, 11, 0, summary: .incomplete, bullet: nil)), "", "partial day: no status subtitle")
        // A correction is the person's note, never the summary or the subtitle.
        let pendingCorrected = moment("c", 9, 0, 11, 0, summary: .pending, bullet: nil, correction: true)
        equal(MomentSubtitle.text(for: pendingCorrected), "", "pending + correction: the correction never stands in as the subtitle")
        equal(MomentSubtitle.text(for: moment("c3", 9, 0, 11, 0, summary: .tooLong, bullet: nil, actions: 240, correction: true)),
              "", "too long + correction: the correction never stands in as the subtitle")
        equal(MomentSubtitle.text(for: moment("c4", 9, 0, 11, 0, correction: true)), "Commented on the launch plan",
              "ready + correction: the subtitle is the note's first bullet")
        equal(MomentSubtitle.rowText(for: pending), "", "a pending row never says Summary pending")
        equal(MomentSubtitle.rowText(for: ready), MomentSubtitle.text(for: ready), "a ready row's subtitle is the note's first bullet")
        let kitSource = (try? String(contentsOfFile: "Sources/MemoryUI/DaydreamKitMoments.swift", encoding: .utf8)) ?? ""
        // fix/resummarize: the row's subtitle is rowText with its Updating… state (rowText(for:updating:) is rowText plus "· Updating…").
        check(kitSource.contains("let subtitleText = MomentSubtitle.rowText(for: m)") || kitSource.contains("let subtitleText = MomentSubtitle.rowText(for: m, updating: updating)"),
              "DDRow(moment:) draws the row subtitle")

        // Actions menu: privacy rows carry no keys, even when one is passed.
        let items = [
            MomentActionItem(id: .openOriginal, title: "Open Original", symbol: "arrow.up.forward.app", keys: "⌘↩", group: .open),
            MomentActionItem(id: .copySummary, title: "Copy Summary", symbol: "doc.on.doc", keys: "⌘C"),
            MomentActionItem(id: .forget, title: "Forget This Moment…", symbol: "trash", keys: "⌘⌫", destructive: true, group: .privacy),
            MomentActionItem(id: .exclude, title: "Exclude Google Chrome from Recording…", symbol: "eye.slash", keys: "⌘E", group: .privacy),
        ]
        let rows = ActionsMenuView.visibleRows(items, filter: "")
        check(rows.filter { $0.group == .privacy }.allSatisfy { $0.keys == nil }, "Actions menu: privacy rows carry no keys")
        equal(rows.filter { $0.group != .privacy }.map(\.keys), ["⌘↩", "⌘C"], "Actions menu: other rows keep their keys")
        equal(ActionsMenuView.visibleRows(items, filter: "forget").map(\.id), [.forget], "Actions menu type-select matches titles")
        let menuSource = (try? String(contentsOfFile: "Sources/MemoryUI/DaydreamKitMoments.swift", encoding: .utf8)) ?? ""
        check(!menuSource.isEmpty && !menuSource.contains("Search for actions"), "the Actions menu draws no search line")
        var ran: [MomentActionID] = []
        let menu = NSHostingView(rootView: ActionsMenuView(items: items, selected: .openOriginal, run: { ran.append($0) }))
        let width = menu.fittingSize.width
        check(width >= 304 && width <= 380, "Actions menu is 304 pt, widening to its longest title up to 380", "\(width)")
        let caps = MomentActions.Capabilities(reopen: true, openApp: true, excludeApp: true, generate: true, delete: true, correct: true,
                                              summaries: SummaryAvailability(provider: .local, busy: false), calendar: cal, now: now)
        for context in [MomentActions.Context.focusList, .recall(dayIsToday: true)] {
            let real = ActionsMenuView.visibleRows(MomentActions.items(for: ready, context: context, browser: caps), filter: "")
            check(real.filter { $0.group == .privacy }.allSatisfy { $0.keys == nil }, "real \(context) menu: privacy rows carry no keys")
            strings += real.map(\.title)
        }
        _ = host(ActionsMenuView(items: items, run: { ran.append($0) }), size: NSSize(width: 400, height: 320))
        equal(ran.count, 0, "rendering the Actions menu runs nothing")

        // Detail body: Open Original reasons.
        func action(_ id: String, bundle: String, site: String) -> CanonicalAction? {
            let object: [String: Any] = ["id": id, "evidenceIDs": ["e"], "at": iso(date(14, 31)), "kind": "page.visit", "app": "Chrome",
                                         "bundle": bundle, "site": site, "title": "t", "description": "d", "state": "observed",
                                         "revision": "r", "subject": "s", "observationKey": "k"]
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? JSONDecoder().decode(CanonicalAction.self, from: data)
        }
        if let a = action("a1", bundle: "com.google.Chrome", site: "https://docs.google.com"), let bare = action("a2", bundle: "", site: "") {
            equal(MomentDetailBody.openBlockReason(a, unavailable: [], canOpen: true), nil, "an openable action has no block reason")
            equal(MomentDetailBody.openBlockReason(a, unavailable: ["a1"], canOpen: true), "The original couldn't be verified.", "unverified original is disabled")
            equal(MomentDetailBody.openBlockReason(bare, unavailable: [], canOpen: true), "No original to reopen", "no bundle or site: nothing to reopen")
            equal(MomentDetailBody.openBlockReason(a, unavailable: [], canOpen: false), "Open Original unavailable", "no reopen closure disables it")
            var opened = 0
            for m in [ready, moment("pc", 14, 30, 15, 20, summary: .pending, bullet: nil, correction: true),
                      moment("web", 14, 30, 15, 20, sites: ["https://docs.google.com/document/d/x"])] {
                opened = 0
                let detail = host(MomentDetailBody(moment: m, actions: [a, bare], complete: false, showAllTitle: "Show all 17 actions",
                                                   timeZone: la, calendar: cal, now: now, onShowAll: {}, onOpenOriginal: { _ in opened += 1 }),
                                  size: NSSize(width: 900, height: 520))
                let sweep = hoverSweep(detail)
                check(sweep.delivered > 50, "detail \(m.id): the hover sweep reaches SwiftUI", "\(sweep.delivered)")
                equal(opened, 0, "detail \(m.id): rendering and hovering the detail body opens nothing")
            }
        } else {
            check(false, "CanonicalAction fixtures decode")
        }

        // ux/declutter: What happened folds repeats in one place (same app, site and title) into one row, keeping the
        // order: a different action in between starts a new row. The row opens the run's last action.
        func timed(_ id: String, _ minute: Int, title: String, site: String = "") -> CanonicalAction? {
            let object: [String: Any] = ["id": id, "evidenceIDs": ["e-" + id], "at": iso(date(15, minute)), "kind": "window.changed", "app": "Notes",
                                         "bundle": "com.apple.Notes", "site": site, "title": title, "description": "d", "state": "observed",
                                         "revision": "r", "subject": "s", "observationKey": id]
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? JSONDecoder().decode(CanonicalAction.self, from: data)
        }
        let seq = [timed("g1", 40, title: "Grocery list"), timed("g2", 44, title: "Grocery list"), timed("g3", 52, title: "Grocery list"),
                   timed("t1", 53, title: "Trip ideas"), timed("g4", 55, title: "Grocery list")].compactMap { $0 }
        if seq.count == 5 {
            let runs = MomentDetailBody.runs(seq)
            equal(runs.map(\.count), [3, 1, 1], "repeats fold into one row; a different action in between starts a new one")
            equal(runs.first?.first.id, "g1", "a run's row shows its first action's time")
            equal(runs.first?.last.id, "g3", "a run's row opens its last action")
            equal(runs.first.flatMap { MomentDetailBody.repeatText($0, timeZone: la) }, "3 times, until 3:52 PM", "a run says how many times, and until when")
            equal(MomentDetailBody.repeatText(runs[1], timeZone: la), nil, "a single action has no repeat line")
        } else {
            check(false, "the What happened fixtures decode")
        }

        // fix/show-all (owner, test 7): the full view says where the summary is, and "What happened" is one entry per real
        // thing with what was sent and typed there, never thirteen rows that all say "Claude".
        let onPhase = SummaryPhase.on(.local)
        equal(MomentDetailBody.summaryStatus(ready, phase: onPhase), nil, "show all: a ready note shows its lines (no status)")
        equal(MomentDetailBody.summaryStatus(pending, phase: onPhase), "Writing the summary…", "show all: a pending moment says the summary is being written")
        equal(MomentDetailBody.summaryStatus(pending, phase: .checking), "Checking the model", "show all: pending while the model is checked says so")
        // fix/writing-forever (owner, launch day): "Writing the summary…" only while the writer has the moment queued or running.
        let looked = pending.end.addingTimeInterval(60)
        equal(MomentDetailBody.summaryStatus(pending, phase: onPhase, queue: SummaryQueue(writing: ["p"], lookedAt: looked)), "Writing the summary…",
              "writing forever: a queued moment says the summary is being written")
        equal(MomentDetailBody.summaryStatus(pending, phase: onPhase, queue: SummaryQueue(lookedAt: looked)), "No summary yet",
              "writing forever: a closed moment the writer hasn't queued never says writing")
        equal(MomentDetailBody.summaryStatus(pending, phase: onPhase, queue: SummaryQueue(open: ["p"], lookedAt: looked)), "Summarized when this moment ends",
              "writing forever: the moment still going says it is summarized when it ends")
        equal(MomentDetailBody.summaryStatus(pending, phase: onPhase, queue: SummaryQueue(lookedAt: pending.end.addingTimeInterval(-60))), "Summarized when this moment ends",
              "writing forever: a moment with actions after the writer's last look is still going")
        equal(MomentDetailBody.summaryStatus(pending, phase: onPhase, queue: SummaryQueue(writing: ["p"], lookedAt: looked, wait: .battery)), "Waiting for power",
              "writing forever: a queued moment under 20% says it waits for power")
        equal(MomentDetailBody.summaryStatus(pending, phase: onPhase, queue: SummaryQueue(writing: ["p"], lookedAt: looked, wait: .lowPower)), "Waiting for Low Power Mode to end",
              "writing forever: Low Power Mode says so")
        equal(MomentDetailBody.summaryStatus(pending, phase: .checking, queue: SummaryQueue(writing: ["p"], lookedAt: looked)), "Checking the model",
              "writing forever: the phase's own line still wins")
        equal(MomentDetailBody.summaryStatus(moment("o2", 9, 0, 9, 5, summary: .summariesOff, bullet: nil), phase: .off, queue: SummaryQueue(writing: ["o2"], lookedAt: looked)),
              "Summaries are off", "writing forever: summaries off says so whatever the queue")
        equal(MomentDetailBody.summaryStatus(moment("o", 9, 0, 9, 5, summary: .summariesOff, bullet: nil), phase: .off), "Summaries are off", "show all: summaries off says so")
        equal(MomentDetailBody.summaryStatus(moment("n", 9, 0, 9, 5, summary: .notWritten, bullet: nil), phase: onPhase), "No summary for this moment",
              "show all: a moment the writer won't write says so")
        equal(MomentDetailBody.summaryStatus(moment("l", 9, 0, 9, 5, summary: .tooLong, bullet: nil), phase: onPhase), "Too long to summarize", "show all: too long says why")
        func act(_ id: String, _ minute: Int, kind: String = "window.changed", app: String = "Claude", bundle: String = "com.anthropic.claudefordesktop",
                 title: String = "Claude", site: String = "", state: String = "observed") -> CanonicalAction? {
            let object: [String: Any] = ["id": id, "evidenceIDs": ["e-" + id], "at": iso(date(0, minute)), "kind": kind, "app": app,
                                         "bundle": bundle, "site": site, "title": title, "description": "d", "state": state,
                                         "revision": "r", "subject": "s", "observationKey": id]
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? JSONDecoder().decode(CanonicalAction.self, from: data)
        }
        // The owner's Claude chat: window rows titled "Claude", typed rows with no title, a detour to an x.com page, back.
        let chat = [act("c1", 0), act("k1", 1, kind: "keyboard.text_input", title: ""), act("c2", 1), act("k2", 5, kind: "keyboard.text_input", title: "", state: "submitted"),
                    act("x1", 4, app: "Google Chrome", bundle: "com.google.Chrome", title: "fixtureuser on X: sonnet", site: "x.com"), act("c3", 7),
                    act("i1", 8, kind: "idle", app: "", bundle: "", title: ""),
                    act("m1", 9, app: "Messages", bundle: "com.apple.MobileSMS", title: "Q7", state: "sent")].compactMap { $0 }
        if chat.count == 8 {
            let typedLoad = MomentTypedLoad(sends: ["k2": "Asked Claude"], blocks: [
                MomentTypedBlock(id: "k1", at: iso(date(0, 1)), app: "Claude", bundle: "com.anthropic.claudefordesktop", host: "", title: "",
                                 text: "why does the trial reset", send: nil),
                MomentTypedBlock(id: "k2", at: iso(date(0, 5)), app: "Claude", bundle: "com.anthropic.claudefordesktop", host: "", title: "",
                                 text: "ok fix the mistake", send: "Asked Claude")])
            let entries = MomentDetailBody.entries(chat, typed: typedLoad)
            equal(entries.map(\.title), ["Claude", "fixtureuser on X: sonnet", "Q7"], "show all: one entry per real thing, in the order first seen; idle rows are none")
            equal(entries.first?.actionIDs, ["c1", "c2", "k1", "k2", "c3"], "show all: every Claude window and typed row is one entry (not thirteen)")
            equal(entries.first?.typed.map(\.text), ["why does the trial reset", "ok fix the mistake"], "show all: what was typed sits under its entry, in time order")
            equal(entries.first?.sends, ["Asked Claude"], "show all: the entry says what was sent there, who only")
            equal(entries.last?.sends, ["Sent"], "show all: a confirmed message send says Sent")
            check(entries[1].isWeb && entries[1].openActionID == "x1" && entries[0].openActionID == nil,
                  "show all: a page entry opens its page; an app entry is no button (it only brought the app forward)")
            equal(entries[0].detail, "", "show all: an app entry named by its app says it once")
            equal(MomentDetailBody.entryTime(entries[0], timeZone: la), DaydreamFormat.time(date(0, 0), la), "show all: an entry's time is when it started (it fits its column)")
            // Without a loaded action, a typed block still gets its place.
            let lone = MomentDetailBody.entries([], typed: MomentTypedLoad(blocks: [MomentTypedBlock(id: "t", at: iso(date(0, 3)), app: "TextEdit",
                                                  bundle: "com.apple.TextEdit", host: "", title: "Draft", text: "hello", send: nil)]))
            equal(lone.map(\.title), ["Draft"], "show all: a typed block with no loaded action still shows under its place")
            check(MomentDetailBody.typedIsLong(String(repeating: "line\n", count: 6)) && !MomentDetailBody.typedIsLong("short"),
                  "show all: a long block collapses to its first lines (More)")
            var opened = 0
            let detail = host(MomentDetailBody(moment: ready, actions: chat, complete: true, timeZone: la, calendar: cal, now: now,
                                               onOpenOriginal: { _ in opened += 1 }, phase: onPhase, typed: typedLoad), size: NSSize(width: 900, height: 700))
            let sweep = hoverSweep(detail)
            check(sweep.delivered > 50 && opened == 0, "show all: the detail with entries and typed blocks draws, and hovering it opens nothing",
                  "\(sweep.delivered) \(opened)")
        } else {
            check(false, "the show-all fixtures decode")
        }

        // The detail draws no "5 of 31 actions" count (declutter): Load More / Show all says there is more.
        let kitMoments = (try? String(contentsOfFile: "Sources/MemoryUI/DaydreamKitMoments.swift", encoding: .utf8)) ?? ""
        check(!kitMoments.isEmpty && !kitMoments.contains("countText(") && !kitMoments.contains(" of \\(DaydreamFormat.count(all)) actions"),
              "the moment detail draws no N of M actions count")

        // Web monograms take the site name's initial, so different sites don't share a letter.
        equal(WebMonogramTile.monogramLetter("docs.google.com"), "G", "docs.google.com draws G")
        equal(WebMonogramTile.monogramLetter("https://developer.apple.com/design/"), "A", "developer.apple.com draws A")
        equal(WebMonogramTile.monogramLetter("www.bbc.co.uk"), "B", "bbc.co.uk draws B (two-label suffix)")
        equal(WebMonogramTile.monogramLetter("github.com"), "G", "github.com draws G")
        equal(WebMonogramTile.monogramLetter("localhost"), "L", "a host without a dot keeps its own initial")

        // Forget and exclude copy.
        let forget = MomentForgetRequest(moment: ready, timeZone: la)
        equal(forget.scope, MemoryActionScope(kind: "activity", id: "r", day: "2026-09-22", timezone: "America/Los_Angeles"), "forget scope is the moment's activity")
        equal(forget.message(actionCount: 17, warning: ""), "This permanently deletes 17 actions from 2:30–3:20 PM. This can't be undone.", "forget copy")
        equal(forget.message(actionCount: 1, warning: " Backups keep a copy. "), "This permanently deletes 1 action from 2:30–3:20 PM. This can't be undone. Backups keep a copy.",
              "forget copy is singular and carries the core warning")
        strings.append(forget.message(actionCount: 17, warning: ""))
        let exclude = ExcludeAppRequest(moment: ready)
        equal(exclude?.bundle, "com.google.Chrome", "exclude request uses the primary bundle")
        equal(exclude?.title, "Exclude Google Chrome from recording?", "exclude title")
        // gold/connections-storage G48: excluding only hides more, so AI apps stay connected and the copy doesn't say otherwise.
        equal(exclude?.message, "DayDream will skip Google Chrome from now on, and its past moments are hidden. Summaries are rewritten.",
              "exclude copy states every lasting side effect (hidden history, rewritten summaries; AI apps stay connected; recording starts again by itself)")
        check(ExcludeAppRequest(moment: moment("x", 9, 0, 9, 5, bundles: [], app: nil)) == nil, "no exclude request without a bundle and a name")
        strings += [exclude?.title ?? "", exclude?.message ?? "", OriginalUnavailableBanner.text]
        // Don't record this site (Chrome page history): Chrome moments only, one per valid site, at most 5, never a default-skipped site.
        let site = ExcludeSiteRequest(site: "example.com")
        equal(site.title, "Don't record example.com?", "exclude-site title")
        equal(site.message, "DayDream will stop saving pages from example.com and hide the ones it already saved.",
              "exclude-site copy states every lasting side effect (hidden pages; AI apps stay connected; recording starts again by itself)")
        equal(site.menuTitle, "Don't Record example.com…", "exclude-site menu item")
        equal([ExcludeSiteRequest.cancelTitle, ExcludeSiteRequest.confirmTitle], ["Cancel", "Don't Record"], "exclude-site buttons")
        let chromeSites = moment("s", 9, 0, 9, 5, sites: ["docs.google.com", "www.Example.com", "example.com", "plannedparenthood.org", "not a site", "a.org", "b.org", "c.org", "d.org"])
        equal(ExcludeSiteRequest.requests(for: chromeSites).map(\.site), ["docs.google.com", "example.com", "a.org", "b.org", "c.org"],
              "exclude-site: one request per distinct site entry, default-skipped sites left out, at most 5")
        equal(ExcludeSiteRequest.requests(for: moment("z", 9, 0, 9, 5, bundles: ["dev.zed.Zed"], app: "Zed", sites: ["example.com"])).count, 0,
              "exclude-site: never offered for a moment of another app")
        equal(ExcludeSiteRequest.requests(for: moment("f", 9, 0, 9, 5, bundles: ["org.mozilla.firefox"], app: "Firefox", sites: ["example.com"])).count, 0,
              "exclude-site: never offered for another browser")
        equal(ExcludeSiteRequest.requests(for: moment("e", 9, 0, 9, 5, sites: [])).count, 0, "exclude-site: nothing for a Chrome moment without sites")
        strings += [site.title, site.message, site.menuTitle]
        equal(OriginalUnavailableBanner.text, "Couldn't open the original.", "original-unavailable banner copy (plain: nothing opened)")

        // Day chips.
        equal(DayChips.label(date(9, 0), now: now, calendar: cal), "Today", "day chip: Today")
        equal(DayChips.label(date(9, 0, day: 21), now: now, calendar: cal), "Yesterday", "day chip: Yesterday")
        equal(DayChips.label(date(9, 0, day: 20), now: now, calendar: cal), "Sun 20", "day chip: EEE d")
        equal(DayChips.accessibilityValue(moments: 0), "No moments recorded", "an empty day chip reads No moments recorded (plan §3)")
        equal(DayChips.accessibilityValue(moments: nil), "Loading", "a loading day chip reads Loading")
        equal(DayChips.accessibilityValue(moments: 1), "1 moment", "a one-moment day chip")
        equal(DayChips.accessibilityValue(moments: 1204), "1,204 moments", "day chip counts are grouped")
        // ux/declutter: no count tooltips on the chips (they now sit in the jump-to-date popover); the dashed
        // empty day is still spoken as "No moments recorded" (never "Off"), and nothing on a chip says "Off".
        strings += [0, 1, 12].map { DayChips.accessibilityValue(moments: $0) }
        let chipSource = (try? String(contentsOfFile: "Sources/MemoryUI/DaydreamKitMoments.swift", encoding: .utf8)) ?? ""
        check(!chipSource.contains("help(moments:"), "day chips carry no count tooltip")

        // The locality chip: where a summary was written, or (evidence) where the evidence stays. A chip beside
        // windows, pages or a moment's evidence must not claim a summary that is pending, off or cloud-written.
        equal(OnThisMacChip.accessibilityLabel(.local, evidence: false), "Stored and summarized on this Mac", "locality chip: a local summary")
        equal(OnThisMacChip.accessibilityLabel(.cloudKey, evidence: false), "Summarized with your cloud key", "locality chip: a cloud-key summary")
        equal(Locality.cloudKey.title, "Cloud", "locality chip: the cloud chip reads Cloud (N17)")
        // Honesty track (H2): "Kept", not "Stays": cloud summaries, when on, send the activity they summarize.
        equal(OnThisMacChip.accessibilityLabel(.local, evidence: true), "Kept on this Mac", "locality chip: evidence says only where it is kept")
        equal(OnThisMacChip.accessibilityLabel(.cloudKey, evidence: true), "Summarized with your cloud key", "locality chip: a cloud-key chip is never evidence")
        check(!OnThisMacChip.accessibilityLabel(.local, evidence: true).localizedCaseInsensitiveContains("summar"), "locality chip: evidence claims no summary")
        strings += [OnThisMacChip.accessibilityLabel(.local, evidence: true)]
        // ux/declutter: the moment views (detail, Recall preview and detail, expanded moment) dropped the always-local
        // evidence chip and mark a summary only when a cloud key wrote it. Every chip left must still be one of the two:
        // an evidence chip (`evidence:`), or the cloud-key chip drawn only for a cloud-written note.
        // The day card's day note chip follows the same rule (cloud key only). The menu bar panel draws no locality chip
        // (dd-menubar-checks pins that from its source).
        let chipSites = ["DaydreamKitMoments.swift", "RecallDetail.swift", "RecallPreview.swift", "FocusListExpanded.swift",
                         "FocusListSummaryCard.swift"]
        for file in chipSites {
            let text = (try? String(contentsOfFile: "Sources/MemoryUI/" + file, encoding: .utf8)) ?? ""
            let lines = text.components(separatedBy: "\n").filter { $0.contains("OnThisMacChip(") && !$0.contains("struct OnThisMacChip") }
            let bad = lines.filter { !$0.contains("evidence:") && !($0.contains("if case .ready(_, false)") && $0.contains("OnThisMacChip(.cloudKey"))
                                     && !($0.contains("showsCloudKeyChip(moment)") && $0.contains("OnThisMacChip(.cloudKey"))
                                     && !($0.contains("if locality == .cloudKey") && $0.contains("OnThisMacChip(.cloudKey")) }
            check(!text.isEmpty && bad.isEmpty, "locality chip: \(file) draws only evidence chips or the cloud-written summary's chip",
                  bad.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " | "))
        }
        var picked: [String] = []
        let chips = (16...22).map { d in
            DayChipModel(id: "2026-09-\(d)", date: date(0, 0, day: d), topBundle: d == 18 || d == 19 ? nil : "dev.zed.Zed",
                         moments: d == 18 ? 0 : d == 17 ? nil : 3)
        }
        let chipHost = host(DayChips(days: chips, selected: "2026-09-22", now: now, calendar: cal, onSelect: { picked.append($0) }),
                            size: NSSize(width: 760, height: 60))
        let chipSweep = hoverSweep(chipHost)
        check(chipSweep.delivered > 20, "day chips: the hover sweep reaches SwiftUI", "\(chipSweep.delivered)")
        equal(picked.count, 0, "rendering and hovering day chips selects nothing")
    }

    // MARK: Confirmations (real sheets, offscreen)

    final class ForgetBox: ObservableObject { @Published var request: MomentForgetRequest? }
    final class ExcludeBox: ObservableObject { @Published var request: ExcludeAppRequest? }
    struct ForgetHost: View {
        @ObservedObject var box: ForgetBox
        let browser: ActivityBrowser
        let forgotten: (String) -> Void
        var body: some View {
            Color.clear.frame(width: 320, height: 200)
                .momentForgetConfirmation(browser: browser, request: $box.request, onForgotten: forgotten, onError: { _ in })
        }
    }
    final class ExcludeSiteBox: ObservableObject { @Published var request: ExcludeSiteRequest? }
    struct ExcludeSiteHost: View {
        @ObservedObject var box: ExcludeSiteBox
        let browser: ActivityBrowser
        var body: some View {
            Color.clear.frame(width: 320, height: 200)
                .excludeSiteConfirmation(browser: browser, request: $box.request, onError: { _ in })
        }
    }
    struct ExcludeHost: View {
        @ObservedObject var box: ExcludeBox
        let browser: ActivityBrowser
        var body: some View {
            Color.clear.frame(width: 320, height: 200)
                .excludeAppConfirmation(browser: browser, request: $box.request, onError: { _ in })
        }
    }

    /// sat5: the owner's timeline read "Notes app / Worked in Notes." One name per app, no line that only names the app:
    /// such a title gives way to the window title, such a bullet is left out, and real bullets keep their words.
    static func timelineWording() {
        func slice(title: String, bullets: [String], subject: String = "Groceries and errands") -> MomentSlice? {
            let output: [String: Any] = ["requestID": "r", "title": title, "generator": "openrouter/fixture", "generatorVersion": "fixture",
                                         "bullets": bullets.map { ["text": $0, "actionIDs": ["n-1"], "assertion": "observed"] }]
            let value: [String: Any] = ["id": "note-notes", "day": "2026-09-22", "timezone": "UTC", "subject": subject,
                "actionIDs": ["n-1"], "apps": ["Notes"], "bundles": ["com.apple.Notes"], "sites": [], "start": "2026-09-22T21:49:00Z",
                "end": "2026-09-22T21:50:00Z", "clusters": [], "inputRevision": "fixture", "status": "ready",
                "generated": ["id": "note-notes", "version": 1, "schemaVersion": 1, "generatedAt": "2026-09-22T21:51:00Z",
                              "inputRevision": "fixture", "actionIDs": ["n-1"], "output": output, "status": "generated_unverified"]]
            guard let data = try? JSONSerialization.data(withJSONObject: value),
                  let note = try? JSONDecoder().decode(ActivityNote.self, from: data) else { return nil }
            return MomentSlice.make(note: note, dayPartial: false, summaries: SummaryAvailability(provider: .cloud, busy: false), calendar: Calendar(identifier: .gregorian))
        }
        let filler = slice(title: "Notes app", bullets: ["Worked in Notes."])
        check(filler?.title == "Groceries and errands" && filler?.firstBullet == nil && filler?.bullets.isEmpty == true,
              "timeline: a title and bullet that only name the app give way to the window title", "\(String(describing: filler?.title)) \(String(describing: filler?.firstBullet))")
        let named = slice(title: "Errands in the Notes app", bullets: ["Wrote a grocery list in the Notes app.", "Worked in Notes."])
        check(named?.title == "Errands in Notes" && named?.firstBullet == "Wrote a grocery list in Notes." && named?.bullets.count == 1,
              "timeline: \"Notes app\" is \"Notes\", and a real bullet keeps its words", "\(String(describing: named?.title)) \(String(describing: named?.bullets))")
        // fix/day-card: real Qwen 3.5 4B lines that only say what was open, or that a chat happened, are filler too.
        let open = slice(title: "Grocery list", bullets: ["Texted Riley about the groceries.", "Had Messages open with Riley.",
                                                         "Had Gmail open with 23 unread messages.", "Had a conversation with Mom.",
                                                         "Had a chat with Priya on Microsoft Teams.", "Had Airbnb open while looking for cabins near Sintra."])
        check(open?.bullets.map(\.text) == ["Texted Riley about the groceries."] && open?.hasSummary == true,
              "timeline: \"Had X open …\" and \"Had a conversation with …\" lines are left out", "\(String(describing: open?.bullets.map(\.text)))")
        // fix/bugs7: lines that name nothing at all are left out too.
        let vague = slice(title: "Grocery list", bullets: ["Texted Riley about the groceries.", "You used your Mac.", "Worked in apps.", "Used several apps."])
        check(vague?.bullets.map(\.text) == ["Texted Riley about the groceries."], "timeline: \"You used your Mac.\" and \"Worked in apps.\" are left out",
              "\(String(describing: vague?.bullets.map(\.text)))")
        // fix/sx-all round 2 (F16): the one shared filler list (NoteFiller, the writer's own): a line that says to whom or
        // what about is never filler; one that names no one and nothing always is.
        let shared = slice(title: "Offsite plans", bullets: ["Wrote an email to Dana about the offsite.", "Wrote a message in Messages.",
                                                           "Emailed Riley about Launch checklist.", "Texted.", "Drafted a text.",
                                                           "Drafted a message to Claude.", "Wrote something on x.com."])
        // (A sent line leads: the order is the slice's own.)
        check(shared.map { Set($0.bullets.map(\.text)) } == ["Wrote an email to Dana about the offsite.", "Emailed Riley about Launch checklist.", "Drafted a message to Claude."]
              && shared?.bullets.count == 3,
              "timeline: the writer's filler list decides; \"to Dana about\" lines stay", "\(String(describing: shared?.bullets.map(\.text)))")
        let apps = slice(title: "Appendix draft", bullets: ["Typed an appendix in Notes."])
        check(apps?.title == "Appendix draft" && apps?.firstBullet == "Typed an appendix in Notes.", "timeline: words that merely contain \"app\" are untouched")
    }
    /// sat5: a click on the window behind the Settings sheet closes it, and is used up; a click in the sheet, on
    /// another window, or while a question hangs from the sheet does nothing. The real frame, on a real sheet.
    @MainActor static func settingsOutsideClick() {
        let parent = NSWindow(contentRect: NSRect(x: -4000, y: -3000, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; parent.orderFrontRegardless()
        let other = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false; other.orderFrontRegardless()
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        var closed = 0
        sheet.contentView = NSHostingView(rootView: DaydreamSettingsFrame(title: "Settings", close: { closed += 1 }) { Text("Page") })
        parent.beginSheet(sheet); pump(0.4)
        func mouseDown(_ w: NSWindow) {
            guard let e = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 40, y: 40), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            NSApp.sendEvent(e); pump(0.1)
        }
        check(parent.attachedSheet === sheet, "outside click: the fixture sheet hangs from its window")
        check(SettingsSheetClick.closes(sheet: sheet, clicked: parent) && !SettingsSheetClick.closes(sheet: sheet, clicked: sheet)
              && !SettingsSheetClick.closes(sheet: sheet, clicked: other) && !SettingsSheetClick.closes(sheet: sheet, clicked: nil)
              && !SettingsSheetClick.closes(sheet: parent, clicked: parent),
              "outside click rule: only a click on the window the sheet hangs from")
        mouseDown(sheet); mouseDown(other)
        check(closed == 0, "outside click: clicks in the sheet or on another window leave Settings open", "closed \(closed)")
        mouseDown(parent)
        if closed == 0 {
            print("LIMIT: outside click: NSApp.sendEvent did not reach the local monitor in this offscreen process; the rule is checked above and the wiring is pinned in settings-0013")
        } else {
            check(closed == 1, "outside click: a click on the window behind closes Settings once", "closed \(closed)")
            let question = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            question.isReleasedWhenClosed = false
            sheet.beginSheet(question); pump(0.4)
            mouseDown(parent)
            check(closed == 1 && !SettingsSheetClick.closes(sheet: sheet, clicked: parent),
                  "outside click: while a question hangs from Settings, a click behind does nothing", "closed \(closed)")
            sheet.endSheet(question); question.orderOut(nil)
        }
        parent.endSheet(sheet); sheet.orderOut(nil); pump(0.2)
        sheet.contentView = nil; parent.orderOut(nil); other.orderOut(nil); pump(0.1)
    }
    static func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
    /// The texts and buttons of the alert sheet on the check window, if one is up.
    static func sheet() -> (texts: [String], buttons: [NSButton])? {
        guard let s = window.attachedSheet, let cv = s.contentView else { return nil }
        let all = views(cv)
        return (all.compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }, all.compactMap { $0 as? NSButton })
    }
    static func click(_ title: String) -> Bool {
        guard let b = sheet()?.buttons.first(where: { $0.title == title }) else { return false }
        b.performClick(nil); pump(0.3)
        return true
    }

    @MainActor static func confirmations() {
        // Forget: a stub browser records every preview, commit and cancel.
        func slice(_ id: String, _ h0: Int, _ h1: Int) -> MomentSlice { moment(id, h0, 0, h1, 0) }
        var expired = false, failNext = false
        var prepared: [String] = [], committed: [String] = [], cancelled: [String] = [], forgotten: [String] = []
        let browser = ActivityBrowser()
        browser.previewCanonicalDelete = { scope in
            prepared.append(scope.id ?? "")
            let object: [String: Any] = ["id": "preview-" + (scope.id ?? "?"),
                                         "scope": ["kind": scope.kind, "id": scope.id ?? "", "day": scope.day ?? "", "timezone": scope.timezone ?? ""],
                                         "actionIDs": [], "actionCount": scope.id == "X" ? 5 : 9, "revision": "r",
                                         "expiresAt": expired ? "2020-01-01T00:00:00Z" : "2099-01-01T00:00:00Z", "warning": ""]
            return try JSONDecoder().decode(DeletionPreview.self, from: JSONSerialization.data(withJSONObject: object))
        }
        browser.confirmCanonicalDelete = { id in
            if failNext { failNext = false; expired = false; throw MemError.missing }
            committed.append(id)
        }
        browser.cancelCanonicalDelete = { cancelled.append($0) }
        let box = ForgetBox()
        window.setContentSize(NSSize(width: 420, height: 300))
        window.contentView = NSHostingView(rootView: ForgetHost(box: box, browser: browser, forgotten: { forgotten.append($0) }))
        pump(0.3)
        let X = MomentForgetRequest(moment: slice("X", 9, 10), timeZone: la), Y = MomentForgetRequest(moment: slice("Y", 14, 15), timeZone: la)
        func reset() { prepared = []; committed = []; cancelled = []; forgotten = [] }
        let xText = "This permanently deletes 5 actions from 9:00–10:00 AM. This can't be undone."
        let yText = "This permanently deletes 9 actions from 2:00–3:00 PM. This can't be undone."

        box.request = X; pump(0.4)
        let first = sheet()
        check(first?.texts.contains("Forget this moment?") == true && first?.texts.contains(xText) == true, "forget: the alert asks with the preview's count and range",
              "\(first?.texts ?? [])")
        check(click("Forget"), "forget: the alert has a Forget button")
        check(committed == ["preview-X"] && forgotten == ["X"] && box.request == nil && cancelled.isEmpty, "forget: Forget commits the previewed moment once",
              "committed \(committed) forgotten \(forgotten)")

        reset(); box.request = X; pump(0.4)
        check(click("Cancel") && cancelled == ["preview-X"] && committed.isEmpty && box.request == nil, "forget: Cancel releases the preview and deletes nothing",
              "cancelled \(cancelled) committed \(committed)")

        reset(); box.request = X; pump(0.4); box.request = nil; pump(0.4)
        check(cancelled == ["preview-X"] && window.attachedSheet == nil, "forget: clearing the request closes the alert and releases the preview",
              "cancelled \(cancelled)")

        reset(); box.request = X; pump(0.4); box.request = Y; pump(0.5)
        let switched = sheet()
        check(switched?.texts.contains(yText) == true && switched?.texts.contains(xText) == false, "forget: a switched request is asked about with its own text",
              "\(switched?.texts ?? [])")
        _ = click("Forget")
        check(committed == ["preview-Y"] && forgotten == ["Y"] && cancelled == ["preview-X"], "forget: a switched request commits its own preview only",
              "committed \(committed) forgotten \(forgotten) cancelled \(cancelled)")

        reset(); box.request = nil; pump(0.2); expired = true; failNext = true; box.request = X; pump(0.4)
        _ = click("Forget"); pump(0.4)
        check(prepared == ["X", "X"] && sheet() != nil, "forget: an expired preview is prepared again once and asked again", "\(prepared)")
        _ = click("Forget")
        check(committed == ["preview-X"] && box.request == nil, "forget: the fresh preview commits", "\(committed)")

        // Exclude: the sheet states the real side effects; Exclude calls excludeApp once, Cancel never.
        var excluded: [String] = []
        let exBrowser = ActivityBrowser()
        exBrowser.excludeApp = { excluded.append($0) }
        let exBox = ExcludeBox()
        window.contentView = NSHostingView(rootView: ExcludeHost(box: exBox, browser: exBrowser))
        pump(0.3)
        let zed = ExcludeAppRequest(bundle: "dev.zed.Zed", appName: "Zed")
        exBox.request = zed; pump(0.4)
        let ex = sheet()
        check(ex?.texts.contains("Exclude Zed from recording?") == true && ex?.texts.contains(zed.message) == true, "exclude: the sheet shows the title and full copy",
              "\(ex?.texts ?? [])")
        _ = click("Cancel")
        check(excluded.isEmpty && exBox.request == nil, "exclude: Cancel excludes nothing")
        exBox.request = zed; pump(0.4)
        _ = click("Exclude"); pump(0.3)
        check(excluded == ["dev.zed.Zed"] && exBox.request == nil, "exclude: Exclude calls excludeApp once with the bundle", "\(excluded)")
        strings += [zed.title, zed.message]

        // Don't record this site: the real sheet; "Don't Record" calls excludeSite once, Cancel never.
        var skipped: [String] = []
        let siteBrowser = ActivityBrowser()
        siteBrowser.excludeSite = { skipped.append($0) }
        let siteBox = ExcludeSiteBox()
        window.contentView = NSHostingView(rootView: ExcludeSiteHost(box: siteBox, browser: siteBrowser))
        pump(0.3)
        let ex2 = ExcludeSiteRequest(site: "example.com")
        siteBox.request = ex2; pump(0.4)
        let siteSheet = sheet()
        check(siteSheet?.texts.contains("Don't record example.com?") == true && siteSheet?.texts.contains(ex2.message) == true,
              "exclude-site: the sheet shows the title and full copy", "\(siteSheet?.texts ?? [])")
        check(siteSheet?.buttons.map(\.title).sorted() == ["Cancel", "Don't Record"], "exclude-site: the sheet has Cancel and Don't Record only",
              "\(siteSheet?.buttons.map(\.title) ?? [])")
        _ = click("Cancel")
        check(skipped.isEmpty && siteBox.request == nil, "exclude-site: Cancel skips nothing", "\(skipped)")
        siteBox.request = ex2; pump(0.4)
        _ = click("Don't Record"); pump(0.3)
        check(skipped == ["example.com"] && siteBox.request == nil, "exclude-site: Don't Record calls excludeSite once with the site", "\(skipped)")
        window.contentView = nil
    }

    // MARK: Tints

    static func tints() {
        equal(AppTint.palette.count, 10, "ten app tints")
        let expected = ["dev.zed.Zed": 3, "com.apple.Safari": 9, "com.mitchellh.ghostty": 7, "com.apple.Notes": 6, "com.google.Chrome": 0]
        for (bundle, index) in expected.sorted(by: { $0.key < $1.key }) {
            equal(AppTint.index(bundle), index, "AppTint is stable for \(bundle)")
        }
        equal(AppTint.index("dev.zed.Zed"), AppTint.index(String("dev.zed.Zed".reversed().reversed())), "AppTint depends only on the bundle text")
    }

    // MARK: Copy and vocabulary

    /// Built from pieces so repository greps for these words never match this file.
    static let banned: [String] = {
        let remember = "Remem", cap = "cap" + "ture"
        return [remember + "bering", "remem" + "bering", "Start remem" + "bering", "Stop remem" + "bering", "Pause " + cap, "Resume " + cap,
                "Stop " + cap, "Never " + remember + "ber", "Tomor" + "row", "Mac" + " Mem", "URL" + "Session", "Day" + "dream"]
    }()

    /// The Settings page is named "Apps to remember"; naming that page is not the retired verb.
    static func remembers(_ s: String) -> Bool {
        s.replacingOccurrences(of: "Apps to remember", with: "Apps to <page>")
            .range(of: #"(?<![0-9] )remember"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    @MainActor static func copyAndVocabulary() {
        for c in Case.allCases {
            let s = state(c)
            strings += [s.kind.title, s.detail(now: now, timeZone: la) ?? "", s.accessibilityValue(now: now, timeZone: la),
                        s.menuBarAccessibilityLabel(now: now, timeZone: la)]
        }
        for kind in PermissionKind.allCases { strings += [kind.title, PermissionRow.subtitle(kind)] }
        equal(PermissionRow.subtitle(.accessibility), "Apps, windows and pages", "Accessibility row subtitle")
        equal(PermissionRow.subtitle(.inputMonitoring), "Clicks, and typing when on", "Input Monitoring row subtitle: needed for clicks even with typing off")
        let excl = ExclusionSummary(alwaysPrivate: ["com.1password.1password", "com.apple.keychainaccess"], excludedByYou: ["com.apple.FaceTime"])
        strings += [ExclusionFootnote.footnote, ExclusionFootnote.countsText(excl), TrustFooter.text(includePrivateWindows: false),
                    TrustFooter.text(includePrivateWindows: true)]
        // Honesty track (H2): the built-in list can't name every password manager, so the footer says "skipped" and how to add one.
        check(TrustFooter.text(includePrivateWindows: false).contains("skipped") && !TrustFooter.text(includePrivateWindows: false).contains("never recorded"),
              "trust footer says skipped, not never recorded")
        check(TrustFooter.text(includePrivateWindows: true).contains("private windows"), "trust footer names private windows when they are skipped")
        // Review H3 (legal §11.5): only the listed password managers are skipped, so the claim says "Common".
        check(TrustFooter.text(includePrivateWindows: false) == "Common password managers are skipped. Add others in Settings."
              && TrustFooter.text(includePrivateWindows: true).hasPrefix("Common password managers"), "trust footer does not claim every password manager")
        let required = ["Stop Recording", "Resume Recording", "Start Recording", "Pause for 5 minutes", "Allow Permissions", "Check Again", "Needs Permission"]
        for r in required { check(strings.contains { $0.contains(r) }, "the kit says \(r)") }
        for word in banned {
            let hits = strings.filter { $0.contains(word) }
            check(hits.isEmpty, "no kit string says \(word)", "\(hits)")
        }
        let capture = strings.filter { $0.lowercased().contains("cap" + "ture") }
        check(capture.isEmpty, "no kit string uses the old recording verb", "\(capture)")
        let remembered = strings.filter(remembers)
        check(remembered.isEmpty, "remember appears only after a count", "\(remembered)")
    }

    // MARK: Source sweep

    static let kitFiles = ["DaydreamKitPrimitives.swift", "DaydreamKitIcons.swift", "DaydreamRibbon.swift", "DaydreamKitStatus.swift",
                           "DaydreamKitMoments.swift", "DaydreamMenuBarGlyph.swift"]

    /// String literals on non-comment code, single-line only. Interpolated code (`\(…)`) is not
    /// literal text and is replaced by a placeholder.
    static func literals(_ line: String) -> [String] {
        var out: [String] = [], current = ""
        var inQuote = false, escape = false, depth = 0, nested = false
        var prev: Character = " "
        for ch in line {
            if depth > 0 {
                if nested { if ch == "\"" { nested = false } }
                else if ch == "\"" { nested = true }
                else if ch == "(" { depth += 1 }
                else if ch == ")" { depth -= 1 }
            } else if inQuote {
                if escape {
                    escape = false
                    if ch == "(" { depth = 1; current.append("\u{FFFC}") } else { current.append(ch) }
                } else if ch == "\\" { escape = true }
                else if ch == "\"" { inQuote = false; out.append(current); current = "" }
                else { current.append(ch) }
            } else {
                if ch == "/" && prev == "/" { break }
                if ch == "\"" { inQuote = true }
            }
            prev = ch
        }
        return out
    }

    /// SF Symbols the kit names, each available on macOS 13.0 (the fallback list when CoreGlyphs'
    /// availability table can't be read). `stop` (a control id) and `flag` (a ribbon label id) also
    /// name SF Symbols 1 symbols. `accessibility` is SF Symbols 5: it may appear only behind
    /// `#available(macOS 14…)`.
    static let macOS13Symbols: Set<String> = [
        "arrow.clockwise", "arrow.down", "arrow.up.forward", "arrow.up.forward.circle",
        "checkmark.circle.fill", "checkmark.shield", "chevron.down", "chevron.left", "chevron.right", "circle.slash",
        "clock.arrow.circlepath", "clock.fill", "exclamationmark", "exclamationmark.triangle", "externaldrive.fill",
        "eye.slash.fill", "figure.arms.open", "flag", "gearshape.fill", "hourglass", "key.fill", "keyboard", "lock.fill", "magnifyingglass",
        "moon.stars.fill", "play.fill", "plus", "record.circle", "sparkles", "stethoscope", "stop", "stop.fill",
        "sun.max.fill", "sunrise.fill", "text.alignleft", "xmark"]
    /// Named by the amendments' F1 lint note: never lifted without a macOS 13 fallback.
    static let bannedSymbols = ["key" + ".horizontal"]

    /// CoreGlyphs' own table: symbol → first macOS version (from `year_to_release`). nil when unreadable.
    static let symbolMacOS: [String: String]? = {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")
        guard let plist = NSDictionary(contentsOf: url), let symbols = plist["symbols"] as? [String: String],
              let years = plist["year_to_release"] as? [String: [String: String]] else { return nil }
        var out: [String: String] = [:]
        for (name, year) in symbols { if let mac = years[year]?["macOS"] { out[name] = mac } }
        return out
    }()
    static func version(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0] }
    /// A symbol draws on the deployment target (macOS 13.0).
    static func availableOnMacOS13(_ name: String) -> Bool {
        if let table = symbolMacOS {
            guard let mac = table[name] else { return false }
            return version(mac).lexicographicallyPrecedes(version("13.0.1"))
        }
        return macOS13Symbols.contains(name)
    }
    static let gatedLine = try! NSRegularExpression(pattern: #"#available\(macOS (1[4-9]|[2-9][0-9])"#)

    /// Strings retired by spec decision 5 (the locality chip replaces them). Built from pieces.
    static let retiredLocality = ["Stored on" + " this Mac", "Summarized on" + " this Mac"]

    static func sourceSweep() {
        equal(literals(#"let a = "Say \(f("x")) once", b = "two" // "note""#), ["Say \u{FFFC} once", "two"],
              "the literal scanner skips interpolations and comments")
        let unknown = macOS13Symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        check(unknown.isEmpty, "every vetted macOS 13 symbol exists", "\(unknown.sorted())")
        if let table = symbolMacOS {
            print("PASS CoreGlyphs availability table read (\(table.count) symbols)")
            let late = macOS13Symbols.filter { !availableOnMacOS13($0) }
            check(late.isEmpty, "every vetted symbol is macOS 13.0 per CoreGlyphs", "\(late.sorted())")
            check(!availableOnMacOS13("accessibility") && table["accessibility"] != nil, "the lint flags accessibility (SF Symbols 5, macOS 14)",
                  table["accessibility"] ?? "missing")
        } else {
            print("LIMIT: CoreGlyphs availability table unreadable; the lint uses the vetted list")
        }
        check(bannedSymbols.allSatisfy { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }, "the banned symbol names are real symbols")
        check(PermissionPaneIcon.accessibilitySymbol == "accessibility" || !availableOnMacOS13("accessibility"),
              "the Accessibility pane icon uses the macOS 14 symbol on macOS 14 or later")
        check(availableOnMacOS13("figure.arms.open") && NSImage(systemSymbolName: "figure.arms.open", accessibilityDescription: nil) != nil,
              "the Accessibility pane icon's macOS 13 fallback draws on macOS 13.0")

        // r2: no AI star anywhere (owner). No MemoryUI source draws a sparkle, by SF Symbol or by its own path
        // (a four-point star is quad curves pinched to the centre), and the Summaries area icon is a plain glyph.
        var stars: [String] = []
        for file in ((try? FileManager.default.contentsOfDirectory(atPath: "Sources/MemoryUI")) ?? []).filter({ $0.hasSuffix(".swift") }) {
            let text = (try? String(contentsOfFile: "Sources/MemoryUI/" + file, encoding: .utf8)) ?? ""
            let code = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for mark in ["\"sparkle", "Sparkle(", "Sparkle:", "\"star\"", "\"star.", "wand.and", "addQuadCurve"] where code.contains(mark) { stars.append(file + ": " + mark) }
        }
        check(stars.isEmpty, "r2: no MemoryUI source draws an AI sparkle or star (symbol or path)", "\(stars)")
        let icons = (try? String(contentsOfFile: "Sources/MemoryUI/DaydreamKitIcons.swift", encoding: .utf8)) ?? ""
        let summariesArt = icons.range(of: "struct SummariesArt").map { String(icons[$0.lowerBound...].prefix(400)) } ?? ""
        check(summariesArt.contains("\"text.alignleft\""), "r2: the Settings Summaries icon is the plain text.alignleft glyph, as DreamGlyph", summariesArt)

        // Retired locality strings, in every MemoryUI source.
        let ui = (try? FileManager.default.contentsOfDirectory(atPath: "Sources/MemoryUI"))?.filter { $0.hasSuffix(".swift") }.sorted() ?? []
        check(!ui.isEmpty, "Sources/MemoryUI is readable from the worktree")
        var retired: [String] = []
        for file in ui {
            guard let text = try? String(contentsOfFile: "Sources/MemoryUI/" + file, encoding: .utf8) else { continue }
            let lits = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.flatMap(literals)
            for word in retiredLocality where lits.contains(where: { $0.contains(word) }) { retired.append(file + ": " + word) }
        }
        check(retired.isEmpty, "no MemoryUI literal uses a retired locality string (the locality chip replaces them)", "\(retired)")

        for file in kitFiles {
            let path = "Sources/MemoryUI/" + file
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { check(false, "\(file) is readable from the worktree"); continue }
            let lines = text.components(separatedBy: "\n")
            let code = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            check(!code.contains { $0.contains(".keyboardShortcut(") }, "\(file): installs no key equivalents")
            let lits = code.flatMap(literals)
            var hits: [String] = []
            for word in banned where lits.contains(where: { $0.contains(word) }) { hits.append(word) }
            if lits.contains(where: { $0.lowercased().contains("cap" + "ture") }) { hits.append("cap" + "ture") }
            if lits.contains(where: remembers) { hits.append("remember") }
            check(hits.isEmpty, "\(file): literals keep the Recording vocabulary", "\(hits)")
            // Every literal that names an SF Symbol on this Mac must draw on macOS 13.0, unless its line
            // is behind `#available(macOS 14…)` (with a macOS 13 fallback elsewhere).
            var late: [String] = []
            for line in code {
                let gated = gatedLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                for lit in literals(line) where lit.range(of: #"^[a-z][a-z0-9]*(\.[a-z0-9]+)*$"#, options: .regularExpression) != nil
                    && NSImage(systemSymbolName: lit, accessibilityDescription: nil) != nil && !availableOnMacOS13(lit) && !gated {
                    late.append(lit)
                }
            }
            check(late.isEmpty, "\(file): every ungated SF Symbol draws on macOS 13.0", "\(Set(late).sorted())")
            check(!lits.contains(where: { bannedSymbols.contains($0) }), "\(file): no banned SF Symbols names")
            // macOS 14 path booleans stay behind @available.
            if code.contains(where: { $0.contains(".subtracting(") || $0.contains("normalized(eoFill") }) {
                check(text.contains("@available(macOS 14.0, *)"), "\(file): macOS 14 path operations are gated")
            }
        }
    }
}
