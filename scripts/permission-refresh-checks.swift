import SwiftUI
import AppKit

@MainActor @main struct PermissionRefreshChecks {
    struct Status: Equatable {
        let accessibility: Bool
        let inputMonitoring: Bool
    }

    @MainActor final class Fixture {
        var status = Status(accessibility: false, inputMonitoring: false)
        var accessibilityReads = 0
        var inputReads = 0
        var callbacks: [Status] = []

        func view(enabled: Bool = true) -> PermissionGrantView {
            PermissionGrantView(enabled: enabled,
                appURL: URL(fileURLWithPath: "/Applications/DayDream.app"),
                readAccessibility: {
                    self.accessibilityReads += 1
                    return self.status.accessibility
                },
                readInputMonitoring: {
                    self.inputReads += 1
                    return self.status.inputMonitoring
                },
                onStatusChange: { accessibility, inputMonitoring in
                    self.callbacks.append(Status(accessibility: accessibility, inputMonitoring: inputMonitoring))
                })
        }
    }

    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label)
        checks += 1
        print("PASS " + label)
    }

    static func waitFor(_ label: String, timeout: TimeInterval = 3.5,
                        condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        check(condition(), label)
    }

    static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 440),
            styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.contentView = nil; window.orderOut(nil) }

        // Only hidden fixture views use injected results. No native permission
        // APIs, System Settings controls, or recording operations are called.
        let fixture = Fixture()
        let host = NSHostingView(rootView: fixture.view())
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 660, height: 440)
        host.layoutSubtreeIfNeeded()
        try await waitFor("appearance reads denied permissions") { !fixture.callbacks.isEmpty }
        check(fixture.callbacks.last == fixture.status, "denied values reach the status callback unchanged")

        let states = [
            Status(accessibility: true, inputMonitoring: false),
            Status(accessibility: false, inputMonitoring: true),
            Status(accessibility: true, inputMonitoring: true),
            Status(accessibility: false, inputMonitoring: true),
            Status(accessibility: false, inputMonitoring: false)
        ]
        let labels = ["Accessibility-only grant", "Input Monitoring-only grant", "both grants", "Accessibility revocation", "both revocations"]
        for (state, label) in zip(states, labels) {
            let count = fixture.callbacks.count
            fixture.status = state
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            try await waitFor("activation refresh delivers " + label, timeout: 0.75) {
                fixture.callbacks.count > count && fixture.callbacks.last == state
            }
        }

        let timerCount = fixture.callbacks.count
        fixture.status = Status(accessibility: true, inputMonitoring: true)
        try await waitFor("two-second timer recognizes both grants without app activation") {
            fixture.callbacks.count > timerCount && fixture.callbacks.last == fixture.status
        }
        let revokeCount = fixture.callbacks.count
        fixture.status = Status(accessibility: true, inputMonitoring: false)
        try await waitFor("two-second timer recognizes Input Monitoring revocation") {
            fixture.callbacks.count > revokeCount && fixture.callbacks.last == fixture.status
        }
        check(fixture.accessibilityReads == fixture.inputReads && fixture.inputReads == fixture.callbacks.count,
            "every refresh reads both permissions and emits one matching status pair")

        let disabled = Fixture()
        disabled.status = Status(accessibility: true, inputMonitoring: true)
        let disabledHost = NSHostingView(rootView: disabled.view(enabled: false))
        window.contentView = disabledHost
        disabledHost.frame = host.frame
        disabledHost.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await Task.sleep(nanoseconds: 2_200_000_000)
        check(disabled.accessibilityReads == 0 && disabled.inputReads == 0 && disabled.callbacks.isEmpty,
            "disabled preview neither reads nor reports permissions on appearance, activation, or timer")
        check(!window.isVisible, "test fixture stays hidden and never opens System Settings")
        print("\(checks) injected permission-refresh checks passed. Native macOS grant recognition is not simulated as an end-to-end pass.")
    }
}
