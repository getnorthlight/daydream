// DD-RECIPE: UI
//
// Pictures for docs/install.md and the README, drawn from DayDream's own SwiftUI views
// (MemoryUI) with made-up sample data. Never a screenshot of the running app: nothing here
// opens a history, starts recording, asks macOS for a permission, reads a permission (the
// permission cards get fixed answers), talks to Chrome or touches the network.
//
// Usage (see docs/install.md, "Updating the pictures"):
//   docs-install-render <output folder> <scratch folder> <repository root> <dmg background.tiff>
// It writes the PNG files named in `DocsPictures.names` into <output folder>, at 2x.
// <scratch folder> gets one plain folder with DayDream's icon, used only as the icon the
// setup screens draw. <dmg background.tiff> comes from scripts/dmg-background.swift, so the
// install-window picture uses the real disk image background.
import AppKit
import SwiftUI
import MemoryCore
import MemoryUI

enum DocsPictures {
    static let names = ["install-drag-to-applications", "setup-permissions", "setup-apps", "setup-review",
                        "menu-bar", "settings-chrome-pages"]
}

@main @MainActor enum DocsInstallRender {
    nonisolated static func fail(_ text: String) -> Never {
        FileHandle.standardError.write(Data(("FAIL: " + text + "\n").utf8)); exit(1)
    }

    /// Answers "active" for the menu bar picture, whose window is made key: the open panel is the key window of the
    /// active menu bar app, so its switch draws blue there. The other pictures' window is not key then, so they draw
    /// as before. (Rendering only: this process never activates or takes focus from the app in front.)
    final class RenderApp: NSApplication { override var isActive: Bool { true } }
    /// `retina`: draws at 2x on any display (the menu bar picture, the README's first), where a 1x display would
    /// otherwise give 1x text scaled up. Off for the other pictures, so they draw as before.
    final class RenderWindow: NSWindow {
        var retina = false
        override var backingScaleFactor: CGFloat { retina ? 2 : super.backingScaleFactor }
    }

    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5 else { fail("usage: docs-install-render <output> <scratch> <repository root> <dmg background.tiff>") }
        let output = URL(fileURLWithPath: args[1], isDirectory: true)
        let scratch = URL(fileURLWithPath: args[2], isDirectory: true)
        let root = URL(fileURLWithPath: args[3], isDirectory: true)
        let background = URL(fileURLWithPath: args[4])
        for folder in [output, scratch] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        _ = RenderApp.shared
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { fail("render timed out") }

        guard let appIcon = NSImage(contentsOf: root.appendingPathComponent("packaging/Daydream.icns")) else { fail("no packaging/Daydream.icns") }
        // A plain folder (not an app bundle, so nothing is registered with macOS) that carries
        // DayDream's icon, because the setup screens draw the icon of the file at `appURL`.
        let iconHolder = scratch.appendingPathComponent("DayDream", isDirectory: true)
        try FileManager.default.createDirectory(at: iconHolder, withIntermediateDirectories: true)
        guard NSWorkspace.shared.setIcon(appIcon, forFile: iconHolder.path, options: []) else { fail("could not set the sample icon") }
        let appURL = iconHolder

        let window = RenderWindow(contentRect: NSRect(x: -4000, y: -4000, width: 660, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        var written: [String] = []
        func save(_ rep: NSBitmapImageRep, _ name: String) throws {
            guard DocsPictures.names.contains(name) else { fail("unlisted picture " + name) }
            guard let png = rep.representation(using: .png, properties: [:]) else { fail("PNG failed for " + name) }
            try png.write(to: output.appendingPathComponent(name + ".png"))
            written.append(name)
            print("PASS rendered \(name).png (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        }
        func render<V: View>(_ name: String, _ view: V, size: NSSize? = nil, key: Bool = false) async throws {
            let host = NSHostingView(rootView: AnyView(view.environment(\.daydreamStatic, true)
                .environment(\.controlActiveState, key ? .key : .active).transaction { $0.disablesAnimations = true }))
            window.retina = key
            window.contentView = host
            if key { window.makeKey() }
            let fit = size ?? host.fittingSize
            guard fit.width > 100, fit.height > 100 else { fail(name + " has no size") }
            window.setContentSize(fit)
            host.frame = NSRect(origin: .zero, size: fit)
            try await Task.sleep(nanoseconds: 300_000_000)
            host.layoutSubtreeIfNeeded()
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(fit.width * 2), pixelsHigh: Int(fit.height * 2),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fail("no bitmap") }
            rep.size = fit
            host.cacheDisplay(in: host.bounds, to: rep)
            try save(rep, name)
        }

        // 1. The disk image window: the real background, DayDream's icon and Applications,
        //    where scripts/dmg-layout.py puts them (128-point icons centred at x 170 and 470, y 170).
        guard let dmgBackground = NSImage(contentsOf: background) else { fail("no dmg background at " + background.path) }
        do {
            let width = 640, height = 400, bar = 28
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: (height + bar) * 2, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: width, height: height + bar)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            dmgBackground.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            // A plain title bar, so the picture reads as a window. Drawn, not captured.
            NSColor(calibratedWhite: 0.91, alpha: 1).setFill()
            NSRect(x: 0, y: height, width: width, height: bar).fill()
            NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
            NSRect(x: 0, y: height, width: width, height: 1).fill()
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12 + i * 20, y: height + 8, width: 12, height: 12)).fill()
            }
            let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor(calibratedWhite: 0.3, alpha: 1)]
            let title = "DayDream" as NSString
            let titleSize = title.size(withAttributes: titleAttributes)
            title.draw(at: NSPoint(x: (CGFloat(width) - titleSize.width) / 2, y: CGFloat(height) + (CGFloat(bar) - titleSize.height) / 2), withAttributes: titleAttributes)
            let folder = NSWorkspace.shared.icon(forFile: "/Applications")
            for (label, x, image) in [("DayDream", 170.0, appIcon), ("Applications", 470.0, folder)] {
                image.draw(in: NSRect(x: x - 64, y: Double(height) - 170 - 64, width: 128, height: 128))
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black]
                let text = label as NSString
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: x - size.width / 2, y: Double(height) - 170 - 64 - 24), withAttributes: attributes)
            }
            NSGraphicsContext.restoreGraphicsState()
            try save(rep, "install-drag-to-applications")
        }

        // 2. Setup, first page: the two permission cards, not yet allowed (fixed answers, never read). Each card's
        // Open System Settings button and drag are the app's own; nothing here presses them.
        try await render("setup-permissions", DaydreamOnboardingShell(
            title: "Grant DayDream Permissions",
            appURL: appURL, canContinue: false, continueAction: {}) {
                PermissionGrantView(enabled: true, appURL: appURL, readAccessibility: { false }, readInputMonitoring: { false }, embedded: true)
                    .environment(\.daydreamPermissionRequests, PermissionRequestActions(quitAndReopen: {}))
            })

        // 3. Setup, apps page: typed text left off. Apple's own apps, read from their fixed system paths.
        let apps = [
            LocalApp(id: "com.apple.Notes", name: "Notes", path: "/System/Applications/Notes.app"),
            LocalApp(id: "com.apple.TextEdit", name: "TextEdit", path: "/System/Applications/TextEdit.app"),
            LocalApp(id: "com.apple.iCal", name: "Calendar", path: "/System/Applications/Calendar.app"),
            LocalApp(id: "com.apple.mail", name: "Mail", path: "/System/Applications/Mail.app"),
            LocalApp(id: "com.apple.Preview", name: "Preview", path: "/System/Applications/Preview.app"),
        ]
        try await render("setup-apps", DaydreamOnboardingShell(title: "Apps to remember", appURL: appURL, back: {}, continueAction: {}) {
            DaydreamAppsContent(apps: apps, excluded: [], query: .constant(""), typedText: .constant(false),
                                loaded: true, enabled: true, allowTyping: true, toggle: { _ in })
        })

        // 4. Setup, last page: the review, with summaries left for later and typed text off.
        // As the app shows it with nothing standing in the way: one value per row (each row is one click back to its
        // page), no message, one Start Recording. FileVault is on in the picture, so its line isn't drawn.
        try await render("setup-review", DaydreamOnboardingShell(
            title: "You're all set",
            appURL: appURL, back: {}, continueTitle: "Start Recording", continueAction: {}) {
                DaydreamReviewContent(rows: [
                    DaydreamReviewRow(id: "permissions", title: "Permissions", value: "Allowed", systemImage: "checkmark.shield", edit: {}),
                    DaydreamReviewRow(id: "summaries", title: "Summaries", value: "Set up later", systemImage: "text.alignleft", edit: {}),
                    DaydreamReviewRow(id: "apps", title: "Apps to remember", value: "5 apps", systemImage: "square.grid.2x2", edit: {}),
                    DaydreamReviewRow(id: "typing", title: "Typed text", value: "Off", systemImage: "keyboard", edit: {}),
                ])
            })

        // 5. The menu bar panel while recording, with a made-up morning in Apple's own apps (rendered last, below).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        func at(_ h: Int, _ m: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: h, minute: m))! }
        func moment(_ id: String, _ h0: Int, _ m0: Int, _ h1: Int, _ m1: Int, _ bundle: String, _ app: String, _ title: String) -> MomentSlice {
            MomentSlice(id: id, dayKey: "2026-09-22", start: at(h0, m0), end: at(h1, m1), title: title, subject: title,
                        firstBullet: nil, bullets: [], apps: [app], primaryBundle: bundle, bundles: [bundle], sites: [],
                        actionIDs: (0..<8).map { "\(id)-\($0)" }, actionCount: 8, clusters: [at(h0, m0)...at(h1, m1)],
                        summary: .pending, hasCorrection: false, primaryApp: app)
        }
        let moments = [
            moment("m1", 8, 40, 9, 5, "com.apple.mail", "Mail", "Trip plans"),
            moment("m2", 9, 10, 10, 20, "com.apple.Pages", "Pages", "Garden club newsletter"),
            moment("m3", 10, 25, 10, 50, "com.apple.Notes", "Notes", "Grocery list"),
            moment("m4", 11, 0, 11, 30, "com.apple.iCal", "Calendar", "Week ahead"),
        ]
        let tallies = [AppTally(id: "com.apple.Pages", bundle: "com.apple.Pages", name: "Pages", moments: 1, actions: 42),
                       AppTally(id: "com.apple.mail", bundle: "com.apple.mail", name: "Mail", moments: 1, actions: 18),
                       AppTally(id: "com.apple.Notes", bundle: "com.apple.Notes", name: "Notes", moments: 1, actions: 11),
                       AppTally(id: "com.apple.iCal", bundle: "com.apple.iCal", name: "Calendar", moments: 1, actions: 7)]
        let today = TodaySnapshot(dayKey: "2026-09-22", loadedAt: at(11, 32), momentCount: moments.count, actionCount: 78, countComplete: true,
                                  partial: false, moments: moments, headline: nil, headlineBullets: [], headlineGeneratedAt: nil, headlineLocal: nil,
                                  firstObserved: moments.first?.start, lastObserved: moments.last?.end, topApps: tallies, latest: moments.last,
                                  summaries: SummaryAvailability(provider: .off, busy: false), readyCount: 0, pendingCount: moments.count,
                                  tooLongCount: 0, appCount: tallies.count)

        // 6. Settings: the Web pages in Chrome card, off (as it starts): the switch, one line and Learn more.
        let chrome = ChromePagesCard(on: .constant(false), savedOn: false, access: .unknown, sites: [], enabled: true,
                                     add: { _ in }, remove: { _ in }, allow: {}, openSystemSettings: {}, checkAccess: {})
        // The off card is one row now, so the picture gets a wider top and bottom margin.
        try await render("settings-chrome-pages", chrome.padding(.horizontal, 20).padding(.vertical, 28).frame(width: 620)
            .background(Color(nsColor: .windowBackgroundColor)))

        // 5 (drawn last: its window is made key, and no later picture should draw as key). The panel: status line,
        // the one switch, Pause ›, today's line and the usual items.
        let panel = MenuBarMenu(presentation: CapturePresentation(state: .recording(since: at(8, 38)), canResume: true, canStop: true),
                                actions: CaptureActions(), snapshot: today, now: at(11, 32), calendar: calendar, openToday: {}, openSetUp: {})
        try await render("menu-bar", panel.environment(\.daydreamNow, at(11, 32)).padding(.vertical, 2)
            .background(Color(nsColor: .windowBackgroundColor)), key: true)

        guard Set(written) == Set(DocsPictures.names), written.count == DocsPictures.names.count else { fail("rendered \(written), expected \(DocsPictures.names)") }
        print("PASS \(written.count) documentation pictures from DayDream's own views, sample data only")
    }
}
