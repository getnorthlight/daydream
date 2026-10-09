import SwiftUI
import AppKit
// Collect, then report: a failed check prints FAIL and the run goes on; the process exits 1 at the end if any failed
// (an atexit handler, so every return path of main reports). stdout is line-buffered so FAIL lines survive a crash.
var ddFailures = 0
func ddFail(_ label: String) { ddFailures += 1; print("FAIL " + label) }
func ddReportAtExit() {
    setvbuf(stdout, nil, _IOLBF, 0)
    atexit { if ddFailures > 0 { print("\(ddFailures) failed"); fflush(stdout); _exit(1) } }
}
func ddCheck(_ ok: Bool, _ label: String) { if !ok { ddFail(label) } }

@main struct PermissionWindowChecks {
    @MainActor static func main() async throws {
        ddReportAtExit()
        let app = URL(fileURLWithPath: "/Users/someone/Applications/DayDream.app")
        // rel-018: the drag carries the URL itself (NSURL writes public.file-url), never a file promise or a copy.
        if let writer = PermissionDragPayload.writer(appURL: app, enabled: true) {
            let board = NSPasteboard(name: NSPasteboard.Name("daydream-permission-window-checks-\(getpid())"))
            board.clearContents()
            ddCheck(board.writeObjects([writer]), "the enabled drag writes to a pasteboard")
            let types = board.types?.map(\.rawValue) ?? []
            ddCheck(types.contains("public.file-url") && !types.contains { $0.localizedCaseInsensitiveContains("promise") },
                    "an enabled drag offers a file URL and no file promise")
            ddCheck(NSURL(string: board.string(forType: .fileURL) ?? "") as URL? == app, "Drag must carry the exact installed application")
            board.releaseGlobally()
        } else {
            ddFail("no drag for the installed app")
        }
        ddCheck(PermissionDragPayload.writer(appURL: app, enabled: false) == nil, "a disabled drag offers nothing")
        ddCheck(PermissionDragPayload.writer(appURL: URL(string: "https://example.com/DayDream.app")!, enabled: true) == nil, "a non-file app URL offers nothing")
        print("PASS: exact app file URL drag round-trip; disabled and non-file drags withheld")

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let renderOnly = CommandLine.arguments.contains("--render-only")
        let output = URL(fileURLWithPath: "/private/tmp/daydream-permission-window-renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        var bounds: [Bool: [NSSize]] = [:]
        for expanded in [false, true] { for dark in [false, true] {
            for state in 0...2 {
                let view = PermissionGrantView(appURL: app, readAccessibility: { state >= 1 }, readInputMonitoring: { state == 2 }, recoveryExpandedInitially: expanded)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let host = NSHostingView(rootView: view)
                window.contentView = host
                // fix/setup-tweaks: measured once SwiftUI applied the injected permission results (the view's first read).
                // With one-line cards nothing else changes size between states, so a size taken at once could still be the
                // page before its first read.
                try await Task.sleep(nanoseconds: 200_000_000)
                host.layoutSubtreeIfNeeded()
                let size = host.fittingSize
                // The standalone view (header and two cards; nothing else when both are allowed).
                ddCheck(size.width == 660 && size.height > 250 && size.height < 600, "Keep the dialog compact (\(state), \(dark ? "dark" : "light"): \(size))")
                bounds[expanded, default: []].append(size)
                window.setContentSize(size)
                if !renderOnly { window.makeKeyAndOrderFront(nil) }
                host.frame = NSRect(origin: .zero, size: size)
                // Let SwiftUI apply the injected permission results before rendering.
                try await Task.sleep(nanoseconds: 200_000_000)
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Empty permission view") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("permissions-\(state)\(expanded ? "-recovery" : "")-\(dark ? "dark" : "light").png"))
            }
        }}
        // Sizes in order: light 0, 1, 2, dark 0, 1, 2. Light and dark match; the missing states differ only by a card
        // line wrapping beside the wider button; allowed drops the hint and recovery line and is never taller.
        // Every host window is fixed-size, so nothing resizes a window.
        ddCheck(bounds.values.allSatisfy { sizes in
            sizes[0] == sizes[3] && sizes[1] == sizes[4] && sizes[2] == sizes[5]
                && abs(sizes[0].height - sizes[1].height) <= 20 && sizes[2].height <= min(sizes[0].height, sizes[1].height)
        }, "Permission results must not jump the layout")
        print("PASS: 12 light/dark permission renders with compact recovery disclosure; light and dark match, missing states within one line, allowed never taller")
    }
}
