import SwiftUI
import AppKit
import MemoryUI

@MainActor @main struct PermissionSettingsChecks {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label)
        checks += 1
    }

    static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: "/private/tmp/daydream-permission-settings-renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let appURL = URL(fileURLWithPath: "/Users/someone/Applications/DayDream.app")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 500),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        defer { window.contentView = nil; window.orderOut(nil) }
        var renders = 0

        for dark in [false, true] { for expanded in [false, true] { for state in 0...3 {
            let enabled = state != 3
            var accessibilityReads = 0
            var inputReads = 0
            var dismissals = 0
            let view = DaydreamPermissionSettings(enabled: enabled, appURL: appURL,
                readAccessibility: { accessibilityReads += 1; return state >= 1 },
                readInputMonitoring: { inputReads += 1; return state >= 2 },
                recoveryExpandedInitially: expanded, onDone: { dismissals += 1 })
            let host = NSHostingView(rootView: view.environment(\.controlActiveState, .active))
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.setContentSize(NSSize(width: 660, height: 500))
            host.frame = NSRect(x: 0, y: 0, width: 660, height: 500)
            try await Task.sleep(nanoseconds: 200_000_000)
            host.layoutSubtreeIfNeeded()
            check(host.fittingSize == NSSize(width: 660, height: 500), "Permission settings keep a compact fixed size")
            check(!window.isVisible && dismissals == 0, "Opening settings neither shows a test window nor advances a flow")
            check(enabled ? accessibilityReads > 0 && accessibilityReads == inputReads : accessibilityReads == 0 && inputReads == 0,
                "Permission settings preserve paired native-reader and disabled-preview behavior")

            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            check(window.performKeyEquivalent(with: enter), "Done remains the keyboard default with granted, missing, and disabled permissions")
            check(dismissals == 1, "Done only calls the dismissal action")

            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Permission settings did not render") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("permissions-\(state)\(expanded ? "-recovery" : "")-\(dark ? "dark" : "light").png"))
            renders += 1
        }}}
        print("PASS: \(checks) permission settings checks and \(renders) hidden light/dark renders; Done dismisses without onboarding, recording, downloads, or preference writes")
    }
}
