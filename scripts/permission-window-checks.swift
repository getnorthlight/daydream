import SwiftUI
import AppKit

@main struct PermissionWindowChecks {
    @MainActor static func main() async throws {
        let app = URL(fileURLWithPath: "/Users/someone/Applications/DayDream.app")
        let provider = PermissionDragPayload.provider(appURL: app, enabled: true)
        precondition(provider.hasItemConformingToTypeIdentifier("public.file-url"))
        let dragged: NSURL = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                if let object = object as? NSURL { continuation.resume(returning: object) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        precondition(dragged as URL == app, "Drag must carry the exact installed application")
        precondition(PermissionDragPayload.provider(appURL: app, enabled: false).registeredTypeIdentifiers.isEmpty)
        precondition(PermissionDragPayload.provider(appURL: URL(string: "https://example.com/DayDream.app")!, enabled: true).registeredTypeIdentifiers.isEmpty)
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
                precondition(size.width == 660 && size.height > 250 && size.height < 600, "Keep the dialog compact")
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
        precondition(bounds.values.allSatisfy { sizes in
            sizes[0] == sizes[3] && sizes[1] == sizes[4] && sizes[2] == sizes[5]
                && abs(sizes[0].height - sizes[1].height) <= 20 && sizes[2].height <= min(sizes[0].height, sizes[1].height)
        }, "Permission results must not jump the layout")
        print("PASS: 12 light/dark permission renders with compact recovery disclosure; light and dark match, missing states within one line, allowed never taller")
    }
}
