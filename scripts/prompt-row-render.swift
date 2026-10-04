// DD-RECIPE: UI
//
// fix/prompt-row renders: the real Today view (`CanonicalTimeline`) over a scratch history, with AI-app rows showing
// what was typed, light and dark, at 2x, offscreen (a window that is never ordered on screen, `cacheDisplay`, as the
// setup renders do). SYNTHETIC ONLY: window rows seeded through the normal store under $TMPDIR; the asks come from a
// stand-in loader (public builds record typing in Notes and TextEdit only, so the store can't hold an ask typed in
// ChatGPT here) that returns fixture text through the real `MomentPromptText.clean`; the pick and the owner-only open
// are covered by MacMemChecks (MomentPromptChecks) and core-adapter-checks. Icons are the installed apps' own
// (NSWorkspace). No app launch, permission, recording, Keychain, model or network.
//
// Usage: prompt-row-render <out-dir>   (<out-dir> under $DD_RENDER_OUT; HOME, CFFIXED_USER_HOME and TMPDIR must be scratch folders)
import AppKit
import SwiftUI
import MemoryUI
import MemoryCore

final class KeyLookingWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@main @MainActor enum PromptRowRender {
    static func fail(_ m: String) -> Never { fflush(stdout); FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }
    static func pump(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    @discardableResult static func wait(_ t: Double, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(t); while !done() && Date() < end { pump(0.03) }; return done()
    }

    nonisolated static let zone = "America/Los_Angeles"
    nonisolated static let la = TimeZone(identifier: zone)!
    nonisolated static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = la; return c }
    nonisolated static func date(_ h: Int, _ m: Int, _ s: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: h, minute: m, second: s))! }
    static let now = date(13, 5)
    static func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d) }

    struct Stretch { let app: String; let bundle: String; let url: String; let title: String; let start: Date; let minutes: Int; let ask: String? }
    nonisolated static let long = """
        I have a SwiftUI list with about 2,000 rows and scrolling stutters when the rows have images.

        Here's what I tried:
          - LazyVStack instead of List
          - caching the NSImage per bundle ID
        but the frame time is still 40 ms on the first scroll. Can you walk me through how to profile this in Instruments and what the usual culprits are?
        """
    nonisolated static let stretches: [Stretch] = [
        Stretch(app: "ChatGPT", bundle: "com.openai.codex", url: "", title: "ChatGPT", start: date(9, 5), minutes: 9, ask: "fix the flaky login test"),
        Stretch(app: "Google Chrome", bundle: "com.google.Chrome", url: "https://chatgpt.com/c/68d9", title: "ChatGPT", start: date(9, 40), minutes: 12, ask: long),
        Stretch(app: "Claude", bundle: "com.anthropic.claudefordesktop", url: "", title: "Claude", start: date(10, 20), minutes: 8, ask: "Rewrite this FAQ answer so it's two sentences, plain words"),
        Stretch(app: "Google Chrome", bundle: "com.google.Chrome", url: "https://www.perplexity.ai/page/standing-desks", title: "Perplexity", start: date(11, 0), minutes: 7, ask: "best standing desk under $500 2026"),
        Stretch(app: "Xcode", bundle: "com.apple.dt.Xcode", url: "", title: "ExportView.swift", start: date(11, 40), minutes: 14, ask: nil),
        Stretch(app: "Google Chrome", bundle: "com.google.Chrome", url: "https://claude.ai/chat/1", title: "Claude", start: date(12, 25), minutes: 10,
                ask: "ok now split the export into smaller batches so it doesn't time out"),
    ]
    /// The one moment with a written note (its line wins over the ask).
    static let noted = "https://claude.ai/chat/1"

    /// The fixture ask typed in a moment's app (native) or on its site (Chrome).
    nonisolated static func askFor(_ r: MomentPromptRequest) -> String? {
        let site = (r.site ?? "").lowercased()
        return stretches.first { s in
            guard s.bundle == r.primaryBundle else { return false }
            guard let host = URL(string: s.url)?.host?.replacingOccurrences(of: "www.", with: "") else { return true }
            return site.contains(host)
        }?.ask
    }

    static func seed(_ home: URL) throws {
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        var n = 0
        for s in stretches {
            var at = s.start, first = true
            let stop = s.start.addingTimeInterval(Double(s.minutes * 60))
            while at < stop {
                n += 1
                let e = Evidence(id: String(format: "r-%05d", n), at: iso(at), kind: first ? "window.changed" : "mouse.click", app: s.app, bundle: s.bundle,
                                 title: s.title, url: s.url, synthetic: true)
                _ = try store.ingest(e, now: at.addingTimeInterval(1))
                first = false
                at = at.addingTimeInterval(9)
            }
        }
        let key = try DayScope.key(now, timezone: zone)
        for m in try store.dayLayers(day: key, timezone: zone, limit: 1, now: now).activities where m.sites.contains(where: { $0.contains("claude.ai") }) {
            let request = try store.prepareNote(kind: "activity", day: key, timezone: zone, activityID: m.id, now: now)
            let ids = request.actions.map(\.id)
            _ = try store.commitNote(NoteWriterOutput(requestID: request.id, title: "Export batching", bullets: [
                NoteBullet(text: "Asked Claude how to split the export into smaller batches.", actionIDs: ids, assertion: "observed")],
                generator: "code/render-fixture", generatorVersion: "1"), now: now)
        }
    }

    static func main() async {
        setbuf(stdout, nil)
        let env = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.count == 2 else { fail("usage: prompt-row-render <out-dir>") }
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard let renders = env["DD_RENDER_OUT"], renders.hasPrefix("/"), out.path.hasPrefix(renders) else { fail("out must be under DD_RENDER_OUT") }
        let tmp = URL(fileURLWithPath: env["TMPDIR"] ?? "/nonexistent", isDirectory: true)
        let realHome = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? ""  // NSHomeDirectory follows CFFIXED_USER_HOME
        for k in ["HOME", "CFFIXED_USER_HOME"] where (env[k] ?? "").isEmpty || env[k] == realHome { fail("\(k) must be a scratch folder") }
        guard env["TMPDIR"] != nil, !tmp.path.hasPrefix("/var/folders/"), !tmp.path.hasPrefix("/private/var/folders/"), !["/tmp", "/private/tmp"].contains(tmp.path) else { fail("TMPDIR must be scratch: \(tmp.path)") }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let home = tmp.appendingPathComponent("prompt-row-render-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        do { try seed(home) } catch { fail("seed: \(error)") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        var index: [[String: String]] = []
        for (typing, label) in [(true, "typing-on"), (false, "typing-off")] {
            for dark in [false, true] {
                for (width, size) in [(1000.0, "wide"), (640.0, "narrow")] where !(size == "narrow" && !typing) {
                    let browser = ActivityBrowser(calendar: cal)
                    browser.now = { now }
                    browser.summaries = SummaryAvailability(provider: .local, busy: false)
                    browser.loadCanonicalDay = { key, cursor in
                        try await withCheckedThrowingContinuation { continuation in
                            DispatchQueue.global(qos: .userInitiated).async {
                                continuation.resume(with: Result {
                                    let r = try MemoryStore(home: home)
                                    var read = try r.dayLayers(day: key, timezone: zone, after: cursor, limit: 200, now: now)
                                    read.levels = try? r.dayLevels(day: key, timezone: zone, now: now)
                                    return read
                                })
                            }
                        }
                    }
                    // Stand-in for the app's loader: the ask typed in each AI moment's app or site, cleaned to one line.
                    if typing {
                        browser.loadMomentPrompts = { requests in
                            var out = [String: String]()
                            for r in requests { if let ask = askFor(r) { out[r.momentID] = MomentPromptText.clean(ask) } }
                            return out
                        }
                    }
                    let h = 1180.0
                    let window = KeyLookingWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: h), styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let host = NSHostingView(rootView: AnyView(CanonicalTimeline(browser: browser)
                        .frame(width: width, height: h, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.daydreamNow, now).environment(\.daydreamStatic, true)))
                    host.frame = NSRect(x: 0, y: 0, width: width, height: h)
                    window.contentView = host
                    guard wait(20, { (browser.today.snapshot?.moments.count ?? 0) >= 5 }) else { fail("today's rows didn't load") }
                    if typing { _ = wait(10, { (browser.today.snapshot?.moments.filter { $0.prompt != nil }.count ?? 0) >= 5 }) }
                    _ = wait(3, { false }) // icons load off the main thread, then redraw
                    host.layoutSubtreeIfNeeded(); pump(0.3)
                    let moments = browser.today.snapshot?.moments ?? []
                    let lines = moments.map { "\($0.title) | \(MomentSubtitle.rowText(for: $0))" }
                    let file = "prompt-rows-\(label)-\(size)-\(dark ? "dark" : "light").png"
                    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(h * 2), bitsPerSample: 8,
                                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                     bytesPerRow: 0, bitsPerPixel: 0) else { fail("no bitmap") }
                    rep.size = NSSize(width: width, height: h)
                    NSAppearance.current = window.appearance
                    host.cacheDisplay(in: host.bounds, to: rep)
                    do { try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(file)) } catch { fail("write: \(error)") }
                    print("PNG \(file)"); lines.forEach { print("  row: \($0)") }
                    index.append(["file": file, "typing": typing ? "on" : "off", "appearance": dark ? "dark" : "light", "width": "\(Int(width))",
                                  "rows": lines.joined(separator: "\n")])
                    window.contentView = nil
                    window.close()
                }
            }
        }
        let meta: [String: Any] = ["source": "fix/prompt-row, CanonicalTimeline offscreen over a synthetic scratch day (9/28), 2x",
                                   "note": "Asks come from a stand-in loader through MomentPromptText.clean (public builds record typing only in Notes/TextEdit); icons are the installed apps' own.",
                                   "images": index]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: out.appendingPathComponent("index.json")) }
        print("DONE \(index.count) renders")
    }
}
