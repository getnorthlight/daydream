import AppKit
import SwiftUI
import MemoryCore
import MemoryUI

// Forget a time range: offscreen renders of the sheet (quick choice, custom range, nothing saved, dark), and the
// sheet's model driven against a synthetic store (preview, a refused commit prepared again, the commit). The window
// is never ordered in; no app, no permission, no real history.
@main struct ForgetRangeRender {
    static var passed = 0
    static func check(_ ok: Bool, _ name: String) throws {
        guard ok else { throw MemError.invalid("FAIL: " + name) }
        passed += 1; print("PASS: " + name)
    }
    @MainActor static func settle(_ seconds: Double = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    @MainActor static func main() throws {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 2 else { throw MemError.invalid("Pass an output directory") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { FileHandle.standardError.write(Data("render timed out\n".utf8)); exit(2) }

        let zone = TimeZone(identifier: "America/Los_Angeles")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        // Sunday, September 27 2026, 3:05 PM in Los Angeles.
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 15, minute: 5))!

        // MARK: strings
        func fake(_ moments: Int?, _ actions: Int, _ s: Date, _ e: Date) -> DeletionPreview {
            DeletionPreview(id: UUID().uuidString, scope: .range(start: s, end: e, timezone: zone.identifier), actionIDs: [], actionCount: actions,
                            revision: "r", expiresAt: iso(now.addingTimeInterval(300)), warning: DeletionPreview.rangeEdges + " " + DeletionPreview.notRecalled,
                            momentCount: moments, rangeStart: MemoryActionScope.range(start: s, end: e, timezone: zone.identifier).start, rangeEnd: MemoryActionScope.range(start: s, end: e, timezone: zone.identifier).end)
        }
        let hourStart = now.addingTimeInterval(-3600)
        try check(ForgetRangeText.question(fake(12, 80, hourStart, now), start: hourStart, end: now, timeZone: zone, now: now) == "Forget 12 moments from 2:05 PM to 3:05 PM?", "question: moments and today's times")
        try check(ForgetRangeText.question(fake(1, 1, hourStart, now), start: hourStart, end: now, timeZone: zone, now: now) == "Forget 1 moment from 2:05 PM to 3:05 PM?", "question: one moment")
        try check(ForgetRangeText.question(fake(0, 3, hourStart, now), start: hourStart, end: now, timeZone: zone, now: now) == "Forget 3 actions from 2:05 PM to 3:05 PM?", "question: actions when no moment shows them")
        let lateStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 23, minute: 30))!, lateEnd = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 0, minute: 30))!
        try check(ForgetRangeText.span(lateStart, lateEnd, timeZone: zone, now: now) == "Sep 25, 11:30 PM to Sep 26, 12:30 AM", "another day's range carries its dates")
        try check(ForgetRangeChoice.today.range(now: now, calendar: calendar, customStart: now, customEnd: now)?.start == calendar.startOfDay(for: now), "Today starts at local midnight and ends now")
        try check(ForgetRangeChoice.last15.range(now: now, calendar: calendar, customStart: now, customEnd: now)?.duration == 900, "Last 15 minutes is 15 minutes to now")
        try check(ForgetRangeChoice.custom.range(now: now, calendar: calendar, customStart: now, customEnd: hourStart) == nil, "a custom range ending before it starts is refused")

        // MARK: renders
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 460, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        func render(_ name: String, _ model: ForgetRangeModel, dark: Bool = false) throws {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: ForgetRangeSheet(model: model, now: now, close: {}).background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = host
            let size = host.fittingSize
            window.setContentSize(size); host.frame = NSRect(origin: .zero, size: size)
            settle(); host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw MemError.invalid("no bitmap") }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { throw MemError.invalid("no png") }
            let url = output.appendingPathComponent(name + ".png")
            try data.write(to: url)
            print("RENDER: " + url.path)
        }
        func still(_ choice: ForgetRangeChoice) -> ForgetRangeModel {
            ForgetRangeModel(calendar: calendar, now: { now }, choice: choice, prepare: { _ in throw MemError.missing }, commit: { _ in }, release: { _ in })
        }
        let hour = still(.lastHour)
        hour.show(.ready(fake(12, 80, hourStart, now)), range: DateInterval(start: hourStart, end: now))
        try render("forget-range-last-hour", hour)
        try render("forget-range-last-hour-dark", hour, dark: true)
        let custom = still(.custom)
        custom.customStart = lateStart; custom.customEnd = lateEnd
        custom.show(.ready(fake(4, 23, lateStart, lateEnd)), range: DateInterval(start: lateStart, end: lateEnd))
        try render("forget-range-custom", custom)
        let empty = still(.last15)
        empty.show(.empty, range: DateInterval(start: now.addingTimeInterval(-900), end: now))
        try render("forget-range-nothing", empty)

        // MARK: the model against a synthetic store
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("forget-range-render-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        for (i, minutes) in [70, 50, 20, 10].enumerated() {
            _ = try store.ingest(Evidence(id: "e\(i)", at: iso(now.addingTimeInterval(Double(-minutes * 60))), kind: "window.changed", app: "Safari", bundle: "com.apple.Safari",
                                          title: "Page \(i)", synthetic: true), now: now)
        }
        var commits = 0, lateAdded = false
        let model = ForgetRangeModel(calendar: calendar, now: { now }, choice: .lastHour,
                                     prepare: { scope in try store.prepareDeletion(scope: scope, now: now) },
                                     commit: { id in
                                         commits += 1
                                         // The first commit meets an action saved into the range after its preview.
                                         if !lateAdded { lateAdded = true; _ = try store.ingest(Evidence(id: "late", at: iso(now.addingTimeInterval(-60)), kind: "window.changed", app: "Safari", bundle: "com.apple.Safari", title: "Late", synthetic: true), now: now) }
                                         _ = try store.executeDeletion(previewID: id, confirmed: true, now: now)
                                     },
                                     release: { try? store.cancelDeletion($0) })
        model.refresh(); settle()
        try check(model.preview?.actionIDs == ["e1", "e2", "e3"], "Last hour previews the hour's actions (the one 70 minutes ago stays out)")
        var finished = false
        model.forget { finished = true }; settle()
        try check(!finished && model.notice == ForgetRangeText.changed && model.preview?.actionIDs == ["e1", "e2", "e3", "late"] && (try store.action("e1", now: now)) != nil,
                  "a commit refused because the range changed deletes nothing and asks again with the new count")
        try render("forget-range-changed", model)
        model.forget { finished = true }; settle()
        try check(finished && commits == 2 && model.phase == .done, "the second Forget commits")
        try check((try store.action("e1", now: now)) == nil && (try store.action("late", now: now)) == nil && (try store.action("e0", now: now)) != nil, "the hour is forgotten; the action before it stays")
        let cancelled = ForgetRangeModel(calendar: calendar, now: { now }, choice: .today, prepare: { scope in try store.prepareDeletion(scope: scope, now: now) }, commit: { _ in }, release: { try? store.cancelDeletion($0) })
        cancelled.refresh(); settle()
        try check(cancelled.preview?.actionIDs == ["e0"], "Today holds what is left of today")
        cancelled.dismiss()
        try check((try store.action("e0", now: now)) != nil, "Cancel deletes nothing")
        // r1 forget-range: Cancel is off while a Forget commits (it can't stop it), and a refused Forget never leaves
        // the sheet stuck with Forget disabled.
        var release: CheckedContinuation<Void, Never>?
        let slow = ForgetRangeModel(calendar: calendar, now: { now }, choice: .today, prepare: { scope in try store.prepareDeletion(scope: scope, now: now) },
                                    commit: { _ in await withCheckedContinuation { release = $0 } }, release: { try? store.cancelDeletion($0) })
        slow.refresh(); settle()
        slow.forget {}; settle()
        try check(slow.phase == .forgetting && !slow.canCancel, "Cancel is off while a Forget commits")
        slow.dismiss()
        try check(slow.phase == .forgetting, "Cancel does nothing while a Forget commits (the delete can't be stopped)")
        release?.resume(); settle()
        try check(slow.phase == .done, "the Forget finishes")
        var refusals = 0
        let refusing = ForgetRangeModel(calendar: calendar, now: { now }, choice: .today, prepare: { scope in try store.prepareDeletion(scope: scope, now: now) },
                                        commit: { _ in refusals += 1; throw MemError.invalid("Deletion scope changed, expired or cancelled; review a new preview") },
                                        release: { try? store.cancelDeletion($0) })
        _ = try store.ingest(Evidence(id: "again", at: iso(now.addingTimeInterval(-30)), kind: "window.changed", app: "Safari", bundle: "com.apple.Safari", title: "Again", synthetic: true), now: now)
        refusing.refresh(); settle()
        for _ in 0..<3 { refusing.forget {}; settle() }
        try check(refusals == 3 && refusing.preview != nil && refusing.canCancel, "every refused Forget asks again with a fresh question; Forget is never left disabled")
        refusing.show(.failed(ForgetRangeText.unavailable), range: nil)
        try check(refusing.canRetry, "a failed question offers Try Again")
        refusing.refresh(); settle()
        try check(refusing.preview != nil, "Try Again prepares the question again")
        print("forget-range render: \(passed) passed")
    }
}
