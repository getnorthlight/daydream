// DD-RECIPE: UI
//
// fix/show-all renders: the real Today view (`CanonicalTimeline`) over a made-up scratch day, offscreen (a window that is
// never ordered on screen, `cacheDisplay`, as the prompt-row and setup renders do), light and dark, at 2x:
// - `show-all-claude-*`: a Claude chat's full view ("Show All"): the summary, then What happened with what was typed and
//   sent under each entry;
// - `show-all-pending-*`: a moment whose summary isn't written yet (the full view says so);
// - `card-xcom-*`: an x.com page's open card (no pill, no Open Original button: the page entry opens the page).
// Built twice: against 18ec176 (fix/prompt-row, "before") and with -D SHOW_ALL against fix/show-all ("after").
// SYNTHETIC ONLY: window rows seeded through the normal store under $TMPDIR; what was typed comes from a stand-in loader
// (public builds record typing in Notes and TextEdit only, so the store can't hold words typed in Claude here); the
// owner-only open is covered by MacMemChecks (MomentShowAllChecks) and core-adapter-checks. Icons are the installed apps'
// own (NSWorkspace). No app launch, permission, recording, Keychain, model or network.
//
// Usage: show-all-render <out-dir> <before|after>   (<out-dir> under $DD_RENDER_OUT; HOME, CFFIXED_USER_HOME and TMPDIR must be scratch folders)
import AppKit
import SwiftUI
import MemoryUI
import MemoryCore

final class KeyLookingWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@main @MainActor enum ShowAllRender {
    static func fail(_ m: String) -> Never { fflush(stdout); FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }
    static func pump(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    @discardableResult static func wait(_ t: Double, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(t); while !done() && Date() < end { pump(0.03) }; return done()
    }

    nonisolated static let zone = "America/Los_Angeles"
    nonisolated static let la = TimeZone(identifier: zone)!
    nonisolated static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = la; return c }
    nonisolated static func date(_ h: Int, _ m: Int, _ s: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: h, minute: m, second: s))! }
    static let now = date(1, 30)
    nonisolated static func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d) }

    static let claude = "com.anthropic.claudefordesktop", chrome = "com.google.Chrome", messages = "com.apple.MobileSMS"
    static let xTitle = "fixtureuser on X: \"a long thread about release notes\""

    static func seed(_ home: URL) throws {
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        var n = 0
        func add(_ app: String, _ bundle: String, _ title: String, _ at: Date, kind: String = "window.changed", url: String = "", page: String? = nil) throws {
            n += 1
            var e = Evidence(id: String(format: "r-%05d", n), at: iso(at), kind: kind, app: app, bundle: bundle, title: title, url: url, synthetic: true)
            #if SHOW_ALL
            e.page = page
            #endif
            _ = page
            _ = try store.ingest(e, now: at.addingTimeInterval(1))
        }
        // A Claude chat, 12:00–12:11 AM: the window says "Claude"; typing and clicks in between (as the owner's day had).
        var at = date(0, 0)
        while at < date(0, 11, 30) {
            try add("Claude", claude, "Claude", at)
            try add("Claude", claude, "", at.addingTimeInterval(7), kind: "mouse.click")
            at = at.addingTimeInterval(20)
        }
        // An x.com post in Chrome, 12:04.
        try add("Google Chrome", chrome, xTitle, date(0, 12, 20), url: "https://x.com", page: "https://x.com/fixtureuser/status/1839123456789012344")
        try add("Google Chrome", chrome, xTitle, date(0, 12, 50), kind: "mouse.click", url: "https://x.com", page: "https://x.com/fixtureuser/status/1839123456789012344")
        // Texts with Q7, 12:40: no summary yet.
        try add("Messages", messages, "Q7", date(0, 40))
        try add("Messages", messages, "Q7", date(0, 41), kind: "mouse.click")
        let key = try DayScope.key(now, timezone: zone)
        for m in try store.dayLayers(day: key, timezone: zone, limit: 1, now: now).activities {
            let text: String
            if m.apps.contains("Claude") { text = "Asked Claude about the app trial, then corrected the mistake." }
            else if m.apps.contains("Google Chrome") { text = "Read fixtureuser's post on X about release notes." }
            else { continue }
            let request = try store.prepareNote(kind: "activity", day: key, timezone: zone, activityID: m.id, now: now)
            _ = try store.commitNote(NoteWriterOutput(requestID: request.id, title: m.apps.contains("Claude") ? "Clarifying the app trial" : xTitle,
                                                      bullets: [NoteBullet(text: text, actionIDs: request.actions.map(\.id), assertion: "observed")],
                                                      generator: "code/render-fixture", generatorVersion: "1"), now: now)
        }
    }

    #if SHOW_ALL
    /// Stand-in for the app's loader: what was typed in the Claude chat and to Q7 (made up), as the detail receives it.
    nonisolated static func typed(_ ids: [String]) -> MomentTypedLoad {
        func block(_ id: String, _ at: Date, _ app: String, _ bundle: String, _ title: String, _ text: String, _ send: String?) -> MomentTypedBlock {
            MomentTypedBlock(id: id, at: iso(at), app: app, bundle: bundle, host: "", title: title, text: MomentTypedText.clean(text), send: send)
        }
        if ids.count > 20 {
            return MomentTypedLoad(blocks: [
                block("t1", date(0, 1), "Claude", claude, "", "why does my app's free trial reset every time I reinstall it? I thought it was saved", "Asked Claude"),
                block("t2", date(0, 5), "Claude", claude, "", """
                    no, that's not it. The trial start date is in the Keychain under the app's bundle ID, not in UserDefaults, so deleting \
                    the app shouldn't touch it. Here's the code that reads it on launch. Can you look again and tell me what actually resets it? \
                    I'm on macOS 26 and the app is notarized, sandboxed, with a keychain access group.
                    """, "Asked Claude"),
                block("t3", date(0, 9), "Claude", claude, "", "ok that fixed it. write me a two-line note for the changelog", "Asked Claude"),
            ])
        }
        if ids.contains("r-00073") {
            return MomentTypedLoad(blocks: [block("t4", date(0, 41), "Messages", messages, "Q7", "running 10 min late, save me a seat", "Texted Q7")])
        }
        return MomentTypedLoad()
    }
    #endif

    static func main() async {
        setbuf(stdout, nil)
        let env = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.count == 3, ["before", "after"].contains(CommandLine.arguments[2]) else { fail("usage: show-all-render <out-dir> <before|after>") }
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true), label = CommandLine.arguments[2]
        guard let renders = env["DD_RENDER_OUT"], renders.hasPrefix("/"), out.path.hasPrefix(renders) else { fail("out must be under DD_RENDER_OUT") }
        let tmp = URL(fileURLWithPath: env["TMPDIR"] ?? "/nonexistent", isDirectory: true)
        let realHome = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? ""  // NSHomeDirectory follows CFFIXED_USER_HOME
        for k in ["HOME", "CFFIXED_USER_HOME"] where (env[k] ?? "").isEmpty || env[k] == realHome { fail("\(k) must be a scratch folder") }
        guard env["TMPDIR"] != nil, !tmp.path.hasPrefix("/var/folders/"), !tmp.path.hasPrefix("/private/var/folders/"), !["/tmp", "/private/tmp"].contains(tmp.path) else { fail("TMPDIR must be scratch: \(tmp.path)") }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let home = tmp.appendingPathComponent("show-all-render-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        do { try seed(home) } catch { fail("seed: \(error)") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        var index: [[String: String]] = []
        for view in ["show-all-claude", "show-all-pending", "card-xcom"] {
            for dark in [false, true] {
                let browser = ActivityBrowser(calendar: cal)
                browser.now = { now }
                browser.summaries = SummaryAvailability(provider: .local, busy: false)
                browser.reopenCanonical = { _ in }
                browser.openApp = { _ in }
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
                #if SHOW_ALL
                browser.loadMomentTyped = { ids, _ in typed(ids) }
                #endif
                let width = 1000.0, h = view == "card-xcom" ? 760.0 : 1060.0
                let window = KeyLookingWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: h), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let host = NSHostingView(rootView: AnyView(CanonicalTimeline(browser: browser)
                    .frame(width: width, height: h, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.daydreamNow, now).environment(\.daydreamStatic, true)))
                host.frame = NSRect(x: 0, y: 0, width: width, height: h)
                window.contentView = host
                guard wait(20, { (browser.today.snapshot?.moments.count ?? 0) >= 3 }) else { fail("today's rows didn't load") }
                let moments = browser.today.snapshot?.moments ?? []
                guard let claudeMoment = moments.first(where: { $0.bundles.contains(claude) }),
                      let xMoment = moments.first(where: { $0.bundles.contains(chrome) }),
                      let textMoment = moments.first(where: { $0.bundles.contains(messages) }) else { fail("fixture moments missing: \(moments.map(\.title))") }
                switch view {
                case "show-all-claude": browser.selectedCanonicalActivity = claudeMoment.id
                case "show-all-pending": browser.selectedCanonicalActivity = textMoment.id
                default: browser.selectedMomentID = xMoment.id; browser.expandedMomentID = xMoment.id
                }
                _ = wait(4, { false }) // the detail's reads and the icons land off the main thread, then redraw
                host.layoutSubtreeIfNeeded(); pump(0.3)
                let file = "\(label)-\(view)-\(dark ? "dark" : "light").png"
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(h * 2), bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0) else { fail("no bitmap") }
                rep.size = NSSize(width: width, height: h)
                NSAppearance.current = window.appearance
                host.cacheDisplay(in: host.bounds, to: rep)
                do { try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(file)) } catch { fail("write: \(error)") }
                print("PNG \(file)")
                index.append(["file": file, "build": label, "view": view, "appearance": dark ? "dark" : "light"])
                window.contentView = nil
                window.close()
            }
        }
        let meta: [String: Any] = ["source": "fix/show-all (\(label)), CanonicalTimeline offscreen over a made-up scratch day (9/29), 2x",
                                   "note": "Typed words come from a stand-in loader (public builds record typing only in Notes/TextEdit); icons are the installed apps' own.",
                                   "images": index]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: out.appendingPathComponent("index-\(label).json")) }
        print("DONE \(index.count) renders")
    }
}
