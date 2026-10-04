// DD-RECIPE: UI
//
// fix/expanded-summary renders: the real Today view (`CanonicalTimeline`, whose open card is `FocusListExpanded`) over a
// made-up scratch day, offscreen (a window that is never ordered on screen, `cacheDisplay`, as the show-all and setup
// renders do), light and dark, at 2x:
// - `card-gmail-*`: "Email in Gmail", a one-bullet note whose bullet is the collapsed row's subtitle, open;
// - `card-chatgpt-*`: "Clarifying vision and delta with ChatGPT", a two-bullet note, open;
// - `rows-*`: both rows collapsed (the collapsed subtitles are unchanged).
// SYNTHETIC ONLY: window rows seeded through the normal store under $TMPDIR, notes committed through prepareNote/
// commitNote as the writer does (generator "code/render-fixture"); icons are the installed apps' own (NSWorkspace). No app
// launch, permission, recording, Keychain, model or network. These are offscreen renders of the production views, not
// screenshots of the built app.
//
// Usage: expanded-summary-render <out-dir> <label>   (<out-dir> under $DD_RENDER_OUT; HOME, CFFIXED_USER_HOME and TMPDIR must be scratch folders)
import AppKit
import SwiftUI
import MemoryUI
import MemoryCore

final class KeyLookingWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@main @MainActor enum ExpandedSummaryRender {
    static func fail(_ m: String) -> Never { fflush(stdout); FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }
    static func pump(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    @discardableResult static func wait(_ t: Double, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(t); while !done() && Date() < end { pump(0.03) }; return done()
    }

    nonisolated static let zone = "America/Chicago"
    nonisolated static let tz = TimeZone(identifier: zone)!
    nonisolated static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c }
    nonisolated static func date(_ h: Int, _ m: Int, _ s: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: h, minute: m, second: s))! }
    static let now = date(23, 30)
    nonisolated static func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d) }

    static let chrome = "com.google.Chrome", chatgpt = "com.openai.chat"
    static let gmailTitle = "Email in Gmail", chatTitle = "Clarifying vision and delta with ChatGPT"

    static func seed(_ home: URL) throws {
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        var n = 0
        func add(_ app: String, _ bundle: String, _ title: String, _ at: Date, kind: String = "window.changed", url: String = "") throws {
            n += 1
            let e = Evidence(id: String(format: "r-%05d", n), at: iso(at), kind: kind, app: app, bundle: bundle, title: title, url: url, synthetic: true)
            _ = try store.ingest(e, now: at.addingTimeInterval(1))
        }
        // A ChatGPT chat, 9:40–9:52 PM.
        var at = date(21, 40)
        while at < date(21, 52) {
            try add("ChatGPT", chatgpt, "ChatGPT", at)
            try add("ChatGPT", chatgpt, "ChatGPT", at.addingTimeInterval(9), kind: "mouse.click")
            at = at.addingTimeInterval(40)
        }
        // The Gmail inbox in Chrome, 10:30–10:36 PM.
        at = date(22, 30)
        while at < date(22, 36) {
            try add("Google Chrome", chrome, "Inbox (3) - Gmail", at, url: "https://mail.google.com")
            try add("Google Chrome", chrome, "Inbox (3) - Gmail", at.addingTimeInterval(11), kind: "mouse.click", url: "https://mail.google.com")
            at = at.addingTimeInterval(45)
        }
        let key = try DayScope.key(now, timezone: zone)
        for m in try store.dayLayers(day: key, timezone: zone, limit: 200, now: now).activities {
            let gmail = m.apps.contains("Google Chrome")
            let request = try store.prepareNote(kind: "activity", day: key, timezone: zone, activityID: m.id, now: now)
            let ids = request.actions.map(\.id)
            let bullets = gmail ? [NoteBullet(text: "Went through the Gmail inbox.", actionIDs: ids, assertion: "observed")]
                : [NoteBullet(text: "Asked ChatGPT to sharpen the product vision for the launch.", actionIDs: Array(ids.prefix(4)), assertion: "observed"),
                   NoteBullet(text: "Compared the delta between the current build and the plan.", actionIDs: Array(ids.suffix(4)), assertion: "observed")]
            _ = try store.commitNote(NoteWriterOutput(requestID: request.id, title: gmail ? gmailTitle : chatTitle, bullets: bullets,
                                                      generator: "code/render-fixture", generatorVersion: "1"), now: now)
        }
    }

    static func main() async {
        setbuf(stdout, nil)
        let env = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.count == 3 else { fail("usage: expanded-summary-render <out-dir> <label>") }
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true), label = CommandLine.arguments[2]
        guard let renders = env["DD_RENDER_OUT"], renders.hasPrefix("/"), out.path.hasPrefix(renders) else { fail("out must be under DD_RENDER_OUT") }
        let tmp = URL(fileURLWithPath: env["TMPDIR"] ?? "/nonexistent", isDirectory: true)
        let realHome = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? ""  // NSHomeDirectory follows CFFIXED_USER_HOME
        for k in ["HOME", "CFFIXED_USER_HOME"] where (env[k] ?? "").isEmpty || env[k] == realHome { fail("\(k) must be a scratch folder") }
        guard env["TMPDIR"] != nil, !tmp.path.hasPrefix("/var/folders/"), !tmp.path.hasPrefix("/private/var/folders/"), !["/tmp", "/private/tmp"].contains(tmp.path) else { fail("TMPDIR must be scratch: \(tmp.path)") }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let home = tmp.appendingPathComponent("expanded-summary-render-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        do { try seed(home) } catch { fail("seed: \(error)") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        var index: [[String: String]] = []
        for view in ["card-gmail", "card-chatgpt", "rows"] {
            for dark in [false, true] {
                let browser = ActivityBrowser(calendar: cal)
                browser.now = { now }
                browser.summaries = SummaryAvailability(provider: .local, busy: false)
                browser.reopenCanonical = { _ in }
                browser.openApp = { _ in }
                // Each render reopens the history (a new read-only store per read), as the app's day reads do.
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
                let width = 1000.0, h = 620.0
                let window = KeyLookingWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: h), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let host = NSHostingView(rootView: AnyView(CanonicalTimeline(browser: browser)
                    .frame(width: width, height: h, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.daydreamNow, now).environment(\.daydreamStatic, true)))
                host.frame = NSRect(x: 0, y: 0, width: width, height: h)
                window.contentView = host
                guard wait(20, { (browser.today.snapshot?.moments.count ?? 0) >= 2 }) else { fail("today's rows didn't load") }
                let moments = browser.today.snapshot?.moments ?? []
                guard let gmail = moments.first(where: { $0.title == gmailTitle }),
                      let chat = moments.first(where: { $0.title == chatTitle }) else { fail("fixture moments missing: \(moments.map(\.title))") }
                print("MOMENT \(gmail.title): subtitle=\"\(MomentSubtitle.text(for: gmail))\" bullets=\(gmail.bullets.count) showsSummary=\(FocusListExpanded.showsSummary(gmail))")
                print("MOMENT \(chat.title): subtitle=\"\(MomentSubtitle.text(for: chat))\" bullets=\(chat.bullets.count) showsSummary=\(FocusListExpanded.showsSummary(chat))")
                switch view {
                case "card-gmail": browser.selectedMomentID = gmail.id; browser.expandedMomentID = gmail.id
                case "card-chatgpt": browser.selectedMomentID = chat.id; browser.expandedMomentID = chat.id
                default: break
                }
                _ = wait(3, { false }) // the card's sources read and the icons land off the main thread, then redraw
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
        let meta: [String: Any] = ["source": "fix/expanded-summary (\(label)): offscreen renders of the production CanonicalTimeline/FocusListExpanded views over a made-up scratch day (9/29), 2x",
                                   "note": "Not screenshots of the built app; the built-app check happens on the signed candidate. Notes are synthetic (code/render-fixture); icons are the installed apps' own.",
                                   "images": index]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: out.appendingPathComponent("index-\(label).json")) }
        print("DONE \(index.count) renders")
    }
}
