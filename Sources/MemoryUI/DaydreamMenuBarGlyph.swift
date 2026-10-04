//  DaydreamMenuBarGlyph.swift
//  DayDream menu bar mark "Twin D" (mark A, the chosen mark). macOS 13+, SwiftUI + AppKit.
//
//  The app icon's two D's, rear D upper-left and front D lower-right, drawn as one monochrome
//  template glyph. The rear D never moves or changes shape (Off only thins it to an outline).
//  The front D is the status slot:
//
//      Recording         both letters solid                         D D
//      Paused            the front D becomes pause bars             D ‖
//      Off               both letters drop to a 1 pt outline        D D, outlined
//      Needs Permission  the front D becomes a tall "!"             D !
//
//  The "!" also shows while recording is Off until something is done (setup isn't finished, DayDream runs from
//  the download window, storage or a replacement needs review, another copy is open): exactly while the panel's
//  status line is orange. With a typing badge on top, the "!" is drawn without its dot, and the badge sits there.
//  When the recording state is unavailable (no model yet, isolated preview), the Off drawing is used.
//
//  Typing badge (safe typing F), at the lower right over the front D:
//
//      a 4 pt filled dot   only while what you type in the front app is recorded (`TypingIndicatorState.showsDot`)
//      a hollow ring       while typing is paused (`showsRing`)
//      nothing             otherwise
//
//  Both sit in a 1 pt clear gap cut into the letter, so they read at 1x. The badge is part of the same
//  template image: the system tints it with the glyph (a template image has no colour of its own).
//
//  Usage with MenuBarExtra (the app target owns the observing wrapper):
//
//      MenuBarExtra { … } label: {
//          DaydreamMenuBarLabelImage(state: model.recordingState, now: now, timeZone: .current)
//      }
//      .menuBarExtraStyle(.window)
//
//  The image is always a template (isTemplate = true), so the system tints it for light, dark,
//  tinted and wallpaper-transparent menu bars and for the pressed state. There is no coloured variant.

import SwiftUI
import AppKit
import MemoryCore

// MARK: - Geometry

/// Metrics of the mark on an 18 x 18 pt canvas, y pointing down. Every straight edge sits on a
/// whole point, so it lands on a pixel boundary at 1x and 2x. The live area is 16 x 16 pt, centred.
public struct DaydreamMarkGeometry: Sendable {
    public var canvas: CGFloat = 18
    /// Rear letter (the blue-to-purple D in the app icon). Never moves; Off only thins it to an outline.
    public var back = CGRect(x: 1, y: 1, width: 8, height: 9)
    /// Front letter (the pink-to-orange D in the app icon) and the status slot. Its top-left corner
    /// tucks under the rear bowl, so the front sits in front of the rear while both letters stay whole.
    public var front = CGRect(x: 9, y: 8, width: 8, height: 9)
    /// Letter weights: stem (left), arm (top and bottom), bowl (right, at its widest).
    public var stem: CGFloat = 2.5
    public var arm: CGFloat = 2
    public var bowl: CGFloat = 2
    /// Off: outline weight. Half the bold weight so outline and solid differ at 1x and 2x.
    public var hairline: CGFloat = 1
    /// Clear space cut around the front letter where it passes in front of the rear one.
    public var gap: CGFloat = 1
    /// The gap runs around curves, so it is a clearance rather than a pixel-aligned edge. At 1x it
    /// widens to this many pixels so the diagonal tuck of the front corner never touches the rear bowl.
    public var minimumGapPixels: CGFloat = 1.5
    /// Radius of the stem's outer corners.
    public var corner: CGFloat = 1.5
    /// Horizontal radius of the bowl, as a share of the letter width.
    public var reach: CGFloat = 0.62
    /// Bezier handle length for the bowl (0.552 is a true ellipse; higher is squarer).
    public var roundness: CGFloat = 0.6
    /// Paused: bar width, and how far the left bar sits inside the slot so it clears the rear bowl.
    public var barWidth: CGFloat = 2.5
    public var barInset: CGFloat = 1
    /// Needs Permission: "!" width, its space from the rear D, and the space above its dot.
    public var bangWidth: CGFloat = 3
    public var bangSpace: CGFloat = 2
    public var bangDotSpace: CGFloat = 2
    /// Typing badge: a 4 pt dot (or ring) centred here, with `gap` cleared around it.
    public var badgeCenter = CGPoint(x: 15.5, y: 15.5)
    public var badgeRadius: CGFloat = 2
    /// Ring weight.
    public var ringWidth: CGFloat = 1

    public init() {}

    public static let standard = DaydreamMarkGeometry()

    /// Snaps weights to whole device pixels for bitmap rendering (ties go lighter). At 2x
    /// every weight is exact; at 1x the 2.5 pt stem and bars become 2 px, like the arms.
    public func hinted(forScale scale: CGFloat) -> DaydreamMarkGeometry {
        func snap(_ v: CGFloat) -> CGFloat { max(1, ((v * scale) - 0.01).rounded()) / scale }
        var g = self
        g.stem = snap(stem); g.arm = snap(arm); g.bowl = snap(bowl)
        g.hairline = snap(hairline); g.gap = max(gap, minimumGapPixels / scale)
        g.barWidth = snap(barWidth); g.bangWidth = snap(bangWidth)
        g.ringWidth = snap(ringWidth)
        return g
    }

    /// Bounding box of the ink in every state.
    public var liveArea: CGRect { back.union(front) }

    // MARK: Letter D

    /// Outer contour of a D in `r`: stem with rounded outer corners, elliptical bowl.
    public func silhouette(_ r: CGRect, corner c: CGFloat? = nil) -> Path {
        let c = c ?? corner
        let rx = r.width * reach, ry = r.height / 2, k = roundness
        var p = Path()
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - rx, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.midY),
                   control1: CGPoint(x: r.maxX - rx * (1 - k), y: r.minY),
                   control2: CGPoint(x: r.maxX, y: r.midY - ry * k))
        p.addCurve(to: CGPoint(x: r.maxX - rx, y: r.maxY),
                   control1: CGPoint(x: r.maxX, y: r.midY + ry * k),
                   control2: CGPoint(x: r.maxX - rx * (1 - k), y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: c)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: c)
        p.closeSubpath()
        return p
    }

    /// Counter of the bold D: square against the stem, following the bowl on the right.
    /// Wound opposite to `silhouette`, so the letter is correct under both fill rules.
    public func counter(_ r: CGRect) -> Path {
        let c = CGRect(x: r.minX + stem, y: r.minY + arm, width: r.width - stem - bowl, height: r.height - 2 * arm)
        let rx = min(c.width, max(0.01, r.width * reach - bowl)), ry = c.height / 2, k = roundness
        var p = Path()
        p.move(to: CGPoint(x: c.minX, y: c.minY))
        p.addLine(to: CGPoint(x: c.minX, y: c.maxY))
        p.addLine(to: CGPoint(x: c.maxX - rx, y: c.maxY))
        p.addCurve(to: CGPoint(x: c.maxX, y: c.midY),
                   control1: CGPoint(x: c.maxX - rx * (1 - k), y: c.maxY),
                   control2: CGPoint(x: c.maxX, y: c.midY + ry * k))
        p.addCurve(to: CGPoint(x: c.maxX - rx, y: c.minY),
                   control1: CGPoint(x: c.maxX, y: c.midY - ry * k),
                   control2: CGPoint(x: c.maxX - rx * (1 - k), y: c.minY))
        p.closeSubpath()
        return p
    }

    /// Bold letter: silhouette plus counter.
    public func letter(_ r: CGRect) -> Path {
        var p = silhouette(r); p.addPath(counter(r)); return p
    }

    /// Outline letter whose outer edge matches the bold silhouette. The stroke is centred half a
    /// weight inside the edge, so at 1x a 1 px line runs down pixel centres and stays crisp.
    public func outlineLetter(_ r: CGRect) -> Path {
        let h = hairline / 2
        return silhouette(r.insetBy(dx: h, dy: h), corner: max(0.5, corner - h))
            .strokedPath(StrokeStyle(lineWidth: hairline, lineJoin: .round))
    }

    // MARK: Status shapes (drawn in the front letter's slot)

    /// Paused: two full-height bars in the front slot, clear of the rear D.
    public func pauseBars() -> Path {
        let r = front, radius = min(corner, barWidth / 2)
        let size = CGSize(width: radius, height: radius)
        var p = Path()
        p.addRoundedRect(in: CGRect(x: r.minX + barInset, y: r.minY, width: barWidth, height: r.height), cornerSize: size)
        p.addRoundedRect(in: CGRect(x: r.maxX - barWidth, y: r.minY, width: barWidth, height: r.height), cornerSize: size)
        return p
    }

    /// Needs Permission: a tall "!". Its top lines up with the rear D's cap and its dot sits on
    /// the mark's baseline, so the glyph keeps the same box as every other state. `dot: false` draws the
    /// stem alone: the typing badge then takes the dot's place, so the badge's clear gap never cuts the
    /// "!"'s own dot into a crescent.
    public func bang(dot: Bool = true) -> Path {
        let w = bangWidth, x = back.maxX + bangSpace
        let top = back.minY, bottom = front.maxY
        var p = Path()
        p.addRoundedRect(in: CGRect(x: x, y: top, width: w, height: bottom - top - w - bangDotSpace),
                         cornerSize: CGSize(width: w / 2, height: w / 2))
        if dot { p.addEllipse(in: CGRect(x: x, y: bottom - w, width: w, height: w)) }
        return p
    }
    /// The "!"'s dot alone (the checks find it by its centre).
    public var bangDotCenter: CGPoint {
        CGPoint(x: back.maxX + bangSpace + bangWidth / 2, y: front.maxY - bangWidth / 2)
    }

    /// The typing badge's disc (dot) or its outline (ring).
    public func badgeDisc(inset: CGFloat = 0) -> Path {
        let r = badgeRadius - inset
        return Path(ellipseIn: CGRect(x: badgeCenter.x - r, y: badgeCenter.y - r, width: 2 * r, height: 2 * r))
    }
    public func badgeRing() -> Path {
        badgeDisc(inset: ringWidth / 2).strokedPath(StrokeStyle(lineWidth: ringWidth))
    }
}

// MARK: - Typing badge

/// The small mark over the glyph's lower right that says what happens to typing.
public enum DaydreamTypingBadge: String, CaseIterable, Sendable {
    case none, dot, ring

    /// The dot exactly while `showsDot`, the ring exactly while `showsRing`.
    public init(_ typing: TypingIndicatorState?) {
        guard let typing else { self = .none; return }
        self = typing.showsDot ? .dot : typing.showsRing ? .ring : .none
    }

    /// Clear space around the badge, then the dot or the ring. `none` adds nothing.
    public func layers(geometry g: DaydreamMarkGeometry = .standard) -> [DaydreamMarkLayer] {
        switch self {
        case .none: return []
        case .dot: return [DaydreamMarkLayer(path: g.badgeDisc(inset: -g.gap), erase: true), DaydreamMarkLayer(path: g.badgeDisc())]
        case .ring: return [DaydreamMarkLayer(path: g.badgeDisc(inset: -g.gap), erase: true), DaydreamMarkLayer(path: g.badgeRing())]
        }
    }

    /// Added to the glyph's VoiceOver label: "DayDream is recording what you type" with the dot,
    /// the pause line with the ring.
    public static func accessibilitySuffix(_ typing: TypingIndicatorState?, timeZone: TimeZone = .current) -> String? {
        guard let typing else { return nil }
        if let label = typing.accessibilityLabel { return label }
        if typing.showsRing { return typing.menuTitle(timeZone: timeZone) }
        return nil
    }
}

// MARK: - Composition

/// One drawing step: fill `path`, or erase it from what has been drawn so far.
public struct DaydreamMarkLayer {
    public var path: Path
    public var evenOdd: Bool
    public var erase: Bool
    public init(path: Path, evenOdd: Bool = false, erase: Bool = false) {
        self.path = path; self.evenOdd = evenOdd; self.erase = erase
    }
}

public enum DaydreamMark {
    /// Ordered fill and erase steps for `state`. The only erase is the 1 pt gap that the front
    /// letter cuts into the rear bowl in Recording and Off. Paused and Needs Permission draw no
    /// erase at all: their shapes clear the rear D by at least 1 pt, so the rear D stays whole.
    public static func layers(for state: DaydreamCaptureState, geometry g: DaydreamMarkGeometry = .standard) -> [DaydreamMarkLayer] {
        layers(for: state, bangDot: true, geometry: g)
    }
    /// `bangDot: false` draws Needs Permission's "!" without its dot (a typing badge stands in its place).
    static func layers(for state: DaydreamCaptureState, bangDot: Bool, geometry g: DaydreamMarkGeometry) -> [DaydreamMarkLayer] {
        var out: [DaydreamMarkLayer] = []
        func fill(_ p: Path, evenOdd: Bool = false) { out.append(DaydreamMarkLayer(path: p, evenOdd: evenOdd)) }
        func cut(_ p: Path, gap: CGFloat) {
            out.append(DaydreamMarkLayer(path: p, erase: true))
            out.append(DaydreamMarkLayer(path: p.strokedPath(StrokeStyle(lineWidth: gap * 2, lineCap: .round, lineJoin: .round)), erase: true))
        }
        switch state {
        case .recording:
            fill(g.letter(g.back), evenOdd: true)
            cut(g.silhouette(g.front), gap: g.gap)
            fill(g.letter(g.front), evenOdd: true)
        case .paused:
            fill(g.letter(g.back), evenOdd: true)
            fill(g.pauseBars())
        case .off:
            fill(g.outlineLetter(g.back))
            cut(g.silhouette(g.front), gap: g.gap)
            fill(g.outlineLetter(g.front))
        case .needsPermission:
            fill(g.letter(g.back), evenOdd: true)
            fill(g.bang(dot: bangDot))
        }
        return out
    }

    /// The glyph for `state` with the typing badge on top. With a badge, the "!" gives up its own dot: the typing dot
    /// or ring (the privacy indicator) is drawn whole, in its usual clear gap, where the "!"'s dot would sit.
    public static func layers(for state: DaydreamCaptureState, badge: DaydreamTypingBadge,
                              geometry g: DaydreamMarkGeometry = .standard) -> [DaydreamMarkLayer] {
        layers(for: state, bangDot: badge == .none, geometry: g) + badge.layers(geometry: g)
    }

    /// Draws `state` into a y-down context whose user space is in mark points.
    public static func draw(_ state: DaydreamCaptureState, geometry: DaydreamMarkGeometry, in ctx: CGContext) {
        draw(layers(for: state, geometry: geometry), in: ctx)
    }
    public static func draw(_ state: DaydreamCaptureState, badge: DaydreamTypingBadge, geometry: DaydreamMarkGeometry, in ctx: CGContext) {
        draw(layers(for: state, badge: badge, geometry: geometry), in: ctx)
    }

    /// Draws raw layers (fill, or clear for erase steps) in the current fill colour.
    public static func draw(_ layers: [DaydreamMarkLayer], in ctx: CGContext) {
        for layer in layers {
            ctx.setBlendMode(layer.erase ? .clear : .normal)
            ctx.addPath(layer.path.cgPath)
            ctx.fillPath(using: layer.evenOdd ? .evenOdd : .winding)
        }
        ctx.setBlendMode(.normal)
    }

    /// Accessibility description of the glyph: "DayDream: Recording", "DayDream: Off", …
    public static func accessibilityDescription(_ state: DaydreamCaptureState) -> String { "DayDream: " + state.title }
}

// MARK: - SwiftUI view

/// The mark as a SwiftUI view, for in-app use (panel header, onboarding, settings).
/// Draws in the current foreground style and scales to fit its frame (18 x 18 pt ideal).
/// Works on macOS 13: it composites the layers in a Canvas, with no boolean path operations.
public struct DaydreamMenuBarMark: View {
    public var state: DaydreamCaptureState
    public init(state: DaydreamCaptureState) { self.state = state }

    public var body: some View {
        Canvas { ctx, size in
            let g = DaydreamMarkGeometry.standard
            let k = min(size.width, size.height) / g.canvas
            ctx.translateBy(x: (size.width - g.canvas * k) / 2, y: (size.height - g.canvas * k) / 2)
            ctx.scaleBy(x: k, y: k)
            for layer in DaydreamMark.layers(for: state, geometry: g) {
                if layer.erase {
                    var eraser = ctx
                    eraser.blendMode = .destinationOut
                    eraser.fill(layer.path, with: .color(.black), style: FillStyle(eoFill: layer.evenOdd))
                } else {
                    ctx.fill(layer.path, with: .foreground, style: FillStyle(eoFill: layer.evenOdd))
                }
            }
        }
        .compositingGroup()
        .aspectRatio(1, contentMode: .fit)
        .frame(idealWidth: 18, idealHeight: 18)
        .accessibilityElement()
        .accessibilityLabel(DaydreamMark.accessibilityDescription(state))
    }
}

// MARK: - Menu bar label

/// The `MenuBarExtra` label: the template mark for the state and one VoiceOver label.
/// `state == nil` means the recording state is unavailable; it draws Off.
public struct DaydreamMenuBarLabelImage: View {
    public let state: DaydreamCaptureState?
    public let label: String
    /// The typing dot or ring drawn over the mark.
    public let badge: DaydreamTypingBadge

    public init(state: DaydreamCaptureState?, label: String, badge: DaydreamTypingBadge = .none) {
        self.state = state; self.label = label; self.badge = badge
    }

    /// Label for a `RecordingState` ("DayDream: Paused until 4:36 PM"). nil → Off drawing, "DayDream: Off".
    /// `typing`: the typing indicator; its dot or ring is drawn and named in the label
    /// ("DayDream: Recording. DayDream is recording what you type").
    /// `setup`: the panel's orange line while recording can't start until something is done
    /// (`MenuBarMenu.Header.needsSetup`: exactly while the panel's status is orange); Off then draws the "!" and both
    /// name it ("DayDream: Off. Setup isn't finished", "DayDream: Off. DayDream is already open").
    public init(state: RecordingState?, now: Date, timeZone: TimeZone, typing: TypingIndicatorState? = nil, setup: String? = nil) {
        let kind = state?.kind
        self.state = kind == .off && setup != nil ? .needsPermission : kind
        var base = state?.menuBarAccessibilityLabel(now: now, timeZone: timeZone) ?? DaydreamMark.accessibilityDescription(.off)
        if state != nil, let setup, kind == .off || kind == .needsPermission { base += ". " + setup }
        self.label = DaydreamTypingBadge.accessibilitySuffix(typing, timeZone: timeZone).map { base + ". " + $0 } ?? base
        self.badge = DaydreamTypingBadge(typing)
    }

    /// The state that is drawn: unavailable draws Off.
    public var drawnState: DaydreamCaptureState { state ?? .off }

    public var body: some View {
        Image(nsImage: DaydreamMenuBarMark.image(for: drawnState, badge: badge))
            .accessibilityLabel(label)
    }
}

// MARK: - NSImage for the menu bar

extension DaydreamMenuBarMark {
    /// 18 x 18 pt template image with hinted 1x and 2x bitmaps. Cached per state.
    @MainActor public static func image(for state: DaydreamCaptureState, badge: DaydreamTypingBadge = .none) -> NSImage {
        let key = state.rawValue + "|" + badge.rawValue
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for scale in [1, 2] as [CGFloat] {
            if let rep = bitmap(state, badge: badge, scale: scale) { image.addRepresentation(rep) }
        }
        image.isTemplate = true
        image.accessibilityDescription = DaydreamMark.accessibilityDescription(state)
        cache[key] = image
        return image
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    /// One hinted bitmap of `state` at `scale` (1 or 2), black on clear. Safe off the main thread.
    nonisolated public static func bitmap(_ state: DaydreamCaptureState, badge: DaydreamTypingBadge = .none, scale: CGFloat) -> NSBitmapImageRep? {
        let g = DaydreamMarkGeometry.standard.hinted(forScale: scale)
        return bitmap(points: g.canvas, scale: scale) { DaydreamMark.draw(state, badge: badge, geometry: g, in: $0) }
    }

    /// Renders one bitmap of `points` x `points` at `scale`, with a y-down context in points.
    nonisolated public static func bitmap(points: CGFloat, scale: CGFloat, draw: (CGContext) -> Void) -> NSBitmapImageRep? {
        let px = Int((points * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        // Set the point size only after the context exists; otherwise the context inherits
        // a points-to-pixels scale on top of the one applied below.
        rep.size = NSSize(width: points, height: points)
        let ctx = gc.cgContext
        ctx.translateBy(x: 0, y: CGFloat(px))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setFillColor(NSColor.black.cgColor)
        draw(ctx)
        ctx.flush()
        return rep
    }
}

// MARK: - Single-path Shape (macOS 14+ only)

/// The same mark flattened into one Path with boolean operations, for strokes, masks and
/// hit-testing. It needs `Path.subtracting` / `union`, which are macOS 14+, so it is gated;
/// `image(for:)`, `DaydreamMenuBarMark` and `DaydreamMenuBarLabelImage` never use it and are
/// the macOS 13 path.
@available(macOS 14.0, *)
public struct DaydreamMarkShape: Shape {
    public var state: DaydreamCaptureState
    public init(state: DaydreamCaptureState) { self.state = state }

    public func path(in rect: CGRect) -> Path {
        let g = DaydreamMarkGeometry.standard
        var result = Path()
        for layer in DaydreamMark.layers(for: state, geometry: g) {
            // Boolean ops apply one fill rule to both operands, so resolve each layer first.
            let operand = layer.path.normalized(eoFill: layer.evenOdd)
            result = layer.erase ? result.subtracting(operand) : result.union(operand)
        }
        let k = min(rect.width, rect.height) / g.canvas
        return result.applying(CGAffineTransform(translationX: rect.midX - g.canvas * k / 2, y: rect.midY - g.canvas * k / 2).scaledBy(x: k, y: k))
    }
}
