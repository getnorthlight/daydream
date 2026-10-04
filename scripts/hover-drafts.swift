// DD-RECIPE: APP
// Design drafts for the timeline hover popup (owner review before it ships): the preview sample's multitasking day, its
// day card (headline, bullets, timeline) with the pointer over one span and three popup designs, rendered offscreen with
// ImageRenderer to PNGs in DD_CHECK_OUT. Never launches the app, never shows a window.
import AppKit
import SwiftUI
import MemoryCore
import MemoryUI

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
@MainActor func pump(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
@MainActor func wait(_ timeout: Double, _ done: () -> Bool) {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { pump(0.05) }
}

struct Hover {
    let segment: RibbonSegment
    let moment: MomentSlice
    let thread: String?
    let tz: TimeZone
    var app: String { moment.primaryApp ?? segment.label }
    var time: String { DaydreamFormat.range(segment.start, segment.end, tz) }
    /// The moment's title without the app it names ("WeeklySummaryExport.swift in Xcode" shows the app beside it).
    var title: String {
        let t = moment.title
        for suffix in [" in \(app)", " on \(app)"] where t.hasSuffix(suffix) { return String(t.dropLast(suffix.count)) }
        return t
    }
    var minutes: String { "\(max(1, Int((segment.end.timeIntervalSince(segment.start) / 60).rounded()))) min" }
}

enum Variant: String, CaseIterable { case a = "A-compact", b = "B-card", c = "C-thread" }

struct Fill {
    let scheme: ColorScheme
    var card: Color { scheme == .dark ? Color(white: 0.16) : .white }
    var page: Color { scheme == .dark ? Color(white: 0.10) : Color(red: 0.925, green: 0.93, blue: 0.945) }
    var bubble: Color { scheme == .dark ? Color(red: 0.285, green: 0.285, blue: 0.30) : Color(red: 0.988, green: 0.99, blue: 0.994) }
    var stroke: Color { scheme == .dark ? Color.white.opacity(0.17) : Color.black.opacity(0.13) }
    var shadow: Color { scheme == .dark ? Color.black.opacity(0.6) : Color.black.opacity(0.22) }
}

/// (A) Native-tooltip style: one line, small, a caret down to the span.
struct PopupA: View {
    let h: Hover; let f: Fill
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                MomentIcon(moment: h.moment, size: 14)
                Text("\(h.app) · \(h.title) · \(h.time)").font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(f.bubble, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(f.stroke, lineWidth: 0.5))
            Caret().fill(f.bubble).frame(width: 12, height: 6).overlay(Caret().stroke(f.stroke, lineWidth: 0.5)).offset(y: -0.5)
        }
        .compositingGroup().shadow(color: f.shadow.opacity(0.7), radius: 5, y: 2)
    }
}

/// (B) A small card: the app icon on the left, the title bold, the time and app in secondary text.
struct PopupB: View {
    let h: Hover; let f: Fill
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            MomentIcon(moment: h.moment, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(h.time) · \(h.app)").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }.fixedSize()
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(f.bubble, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(f.stroke, lineWidth: 0.5))
        .shadow(color: f.shadow, radius: 12, y: 6)
    }
}

/// (C) The card from B plus where the span belongs: a quiet line naming the thread (the headline or a side-thread
/// bullet it is part of), and the span's own minutes. Its thread's other spans stay lit on the bar (the rest dim).
struct PopupC: View {
    let h: Hover; let f: Fill
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 10) {
                MomentIcon(moment: h.moment, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(h.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(h.app) · \(h.time) · \(h.minutes)").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let thread = h.thread {
                Rectangle().fill(f.stroke).frame(height: 0.5)
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
                    Text("Part of ").foregroundStyle(.secondary) + Text(thread).fontWeight(.medium)
                }.font(.system(size: 11.5)).lineLimit(1)
            }
        }
        .fixedSize()
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(f.bubble, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(f.stroke, lineWidth: 0.5))
        .shadow(color: f.shadow, radius: 12, y: 6)
    }
}

struct Caret: Shape {
    func path(in r: CGRect) -> Path { Path { p in p.move(to: .init(x: r.minX, y: r.minY)); p.addLine(to: .init(x: r.midX, y: r.maxY)); p.addLine(to: .init(x: r.maxX, y: r.minY)) } }
}

struct Draft: View {
    let variant: Variant
    let scheme: ColorScheme
    let title: String
    let headlineTime: String?
    let bullets: [String]
    let model: RibbonModel
    let hover: Hover
    let hoverGroups: Set<String>
    let calendar: Calendar
    let cardWidth: CGFloat = 900
    let pad: CGFloat = 18

    var body: some View {
        let f = Fill(scheme: scheme)
        let w = cardWidth - 2 * pad
        let span = model.range.upperBound.timeIntervalSince(model.range.lowerBound)
        let mid = hover.segment.start.addingTimeInterval(hover.segment.end.timeIntervalSince(hover.segment.start) / 2)
        let px = pad + CGFloat(mid.timeIntervalSince(model.range.lowerBound) / span) * w
        // C keeps the whole thread lit: pass a synthetic group to the ribbon by re-grouping the thread's segments.
        var lit = model
        if variant == .c {
            lit.segments = model.segments.map { s in
                RibbonSegment(id: s.id, start: s.start, end: s.end, tint: s.tint, pending: s.pending, label: s.label, title: s.title,
                              group: hoverGroups.contains(s.group) ? "__thread" : s.group, band: s.band)
            }
        }
        let hovered = variant == .c ? "__thread" : hover.segment.group
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                (Text(title).font(.system(size: 17, weight: .semibold)) + Text("  " + (headlineTime ?? "")).font(.system(size: 13)).foregroundColor(.secondary))
                ForEach(bullets, id: \.self) { b in
                    HStack(spacing: 8) { Circle().fill(Color.purple.opacity(0.8)).frame(width: 4.5, height: 4.5); Text(b).font(.system(size: 12.5)) }
                        .padding(.leading, 6)
                }
            }
            .padding(pad)
            Rectangle().fill(f.stroke.opacity(0.6)).frame(height: 0.5)
            DDRibbon(model: lit, height: .h8, axis: true, hovered: hovered, calendar: calendar, nowClock: false, showsBands: true)
                .padding(.horizontal, pad).padding(.top, 16).padding(.bottom, 14)
        }
        .frame(width: cardWidth)
        .background(f.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            // The popup sits above the bar at the pointer (it follows the pointer along the bar), never over the span.
            let popup = Group {
                switch variant {
                case .a: PopupA(h: hover, f: f)
                case .b: PopupB(h: hover, f: f)
                case .c: PopupC(h: hover, f: f)
                }
            }
            popup.fixedSize()
                .alignmentGuide(.leading) { d in variant == .a ? d.width / 2 - px : 14 - px }
                .alignmentGuide(.bottom) { d in d.height + (variant == .a ? 48 : 56) }
        }
        .overlay(alignment: .bottomLeading) {
            Image(nsImage: NSCursor.arrow.image)
                .alignmentGuide(.leading) { _ in -(px - NSCursor.arrow.hotSpot.x) }
                .alignmentGuide(.bottom) { _ in NSCursor.arrow.hotSpot.y + 39 }
        }
        .padding(28)
        .background(f.page)
        .environment(\.colorScheme, scheme)
    }
}

@main struct HoverDrafts {
    @MainActor static func main() throws {
        guard let out = ProcessInfo.processInfo.environment["DD_CHECK_OUT"], !out.isEmpty else { fail("DD_CHECK_OUT is required") }
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil else { fail("CFFIXED_USER_HOME must point at a scratch folder") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { fail("timed out") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        // Seeded here on the main thread (the launch session seeds on a queue; see the report about its flaky seed).
        PreviewLaunch.pointHome()
        let trial: DevelopmentTrial
        do { trial = try PreviewLaunch.prepare(reuse: false) } catch { fail("preview seed: \(error)") }
        let model = MemoryViewModel(development: trial)
        let memoryHome = ProcessInfo.processInfo.environment["MAC_MEM_HOME"] ?? ""
        let browser = model.activity
        let zone = browser.calendar.timeZone.identifier
        let reader = try MemoryStore(home: URL(fileURLWithPath: memoryHome))
        let reportURL = URL(fileURLWithPath: memoryHome).deletingLastPathComponent().appendingPathComponent("seed-report.json")
        guard let report = try? JSONDecoder().decode(PreviewSample.Report.self, from: Data(contentsOf: reportURL)) else { fail("no seed report") }
        guard let day = try report.days.reversed().first(where: { try reader.dayLevels(day: $0, timezone: zone).day?.title == "Q3 investor update" }) else { fail("no threads day") }
        var snap: TodaySnapshot?
        Task { @MainActor in
            if let d = try? await browser.dayCache.day(day) { snap = TodaySnapshot.make(day: d, summaries: browser.summaries, calendar: browser.calendar, now: Date()) }
        }
        wait(30) { snap?.levels != nil }
        guard let snap, let levels = snap.levels else { fail("the day never loaded") }
        let ribbon = RibbonModel.make(snapshot: snap, state: nil, now: Date(), calendar: browser.calendar, isToday: false).dayCard
        // The pointer rests on the Xcode span: its title is the file, its thread is the pull request.
        guard let moment = snap.moments.first(where: { $0.title.localizedCaseInsensitiveContains("WeeklySummaryExport") }) ?? snap.moments.first,
              let seg = ribbon.segments.filter({ $0.group == moment.id }).max(by: { $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start) }) else { fail("no span to hover") }
        var thread: String? = nil
        var groups: Set<String> = [moment.id]
        for b in levels.blocks where b.momentIDs.contains(moment.id) {
            if b.mainMoments.contains(moment.id) { thread = b.name; groups = Set(b.mainMoments) }
            else if let i = b.sideThreadMoments.firstIndex(where: { $0.contains(moment.id) }) {
                thread = b.sideThreads[i].components(separatedBy: ", ~").first; groups = Set(b.sideThreadMoments[i])
            }
        }
        let hover = Hover(segment: seg, moment: moment, thread: thread, tz: browser.calendar.timeZone)
        print("hover: \(hover.app) · \(moment.title) · \(hover.time) · thread \(thread ?? "-")")
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bullets = Array(levels.dayBullets.prefix(3).map(\.text))
        func render(_ v: Variant, _ scheme: ColorScheme, _ name: String) throws {
            let view = Draft(variant: v, scheme: scheme, title: levels.dayTitle ?? "", headlineTime: levels.headlineDuration, bullets: bullets, model: ribbon, hover: hover,
                             hoverGroups: groups, calendar: browser.calendar)
            let r = ImageRenderer(content: view); r.scale = 2
            var image: NSImage?
            NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { image = r.nsImage }
            guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { fail("no image for \(name)") }
            let url = dir.appendingPathComponent(name + ".png")
            try png.write(to: url)
            print("PASS: rendered \(url.path)")
        }
        for v in Variant.allCases { try render(v, .light, "hover-\(v.rawValue)-light") }
        try render(.c, .dark, "hover-C-thread-dark")
        try render(.b, .dark, "hover-B-card-dark")
    }
}
