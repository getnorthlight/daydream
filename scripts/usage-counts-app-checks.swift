// DD-RECIPE: APP
// Anonymous usage counts (UsageSender, UsageReport, UsageCounts, UsageInbox), on the real app sources built the way every
// check build is (-D DEVELOPMENT_SOURCE_CHECKS). Scratch folders under DD_CHECK_OUT and a private defaults suite; nothing
// is sent (this build may not send, and there is no project key), nothing records. Renders Settings › Advanced with
// the card to DD_CHECK_OUT/usage-renders.
import AppKit
import SwiftUI
import MemoryCore
import MemoryUI

func fail(_ message: String) -> Never {
    fflush(stdout)
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}
func check(_ condition: Bool, _ message: @autoclosure () -> String) { if condition { print("PASS " + message()) } else { fail(message()) } }

@main @MainActor struct UsageCountsAppChecks {
    static func main() async throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DD_CHECK_OUT"] ?? NSTemporaryDirectory())
        let home = out.appendingPathComponent("usage-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let suite = "usage-counts-checks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Test and development builds never send.
        check(!UsageSender.buildMaySend, "a check build (DEVELOPMENT_SOURCE_CHECKS) may not send")
        check(UsageSender.projectKey.isEmpty, "no project key in a check build: nothing can be sent")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["DD_SRC_ROOT"] ?? FileManager.default.currentDirectoryPath).appendingPathComponent("packaging/Info.plist")), format: nil) as? [String: Any]
        let key = plist?["DDPostHogKey"] as? String
        check(key != nil && (key!.isEmpty || key!.hasPrefix("phc_")), "Info.plist's DDPostHogKey is empty or a phc_ project key")

        let sender = UsageSender(defaults: defaults)
        check(sender.enabled, "usage counts are on by default")
        let id = sender.installID
        check(UUID(uuidString: id) != nil && sender.installID == id, "the install ID is a random UUID, made once and kept")
        check(!id.lowercased().contains(NSUserName().lowercased()) && !id.contains(Host.current().localizedName ?? "\u{0}"), "the install ID isn't made from the user or computer name")
        check(UsageSender(defaults: UserDefaults(suiteName: suite + "-other")!).installID != id, "another install gets another ID")
        UserDefaults().removePersistentDomain(forName: suite + "-other")

        sender.start(home: home)
        check(FileManager.default.fileExists(atPath: UsageInbox.url(home).path), "sharing on: the MCP helper's inbox exists")
        sender.record("app_opened", ["how": .text("menu_bar")])
        sender.record("app_search", ["result_count": .int(3)])
        sender.record("app_search", ["query": .text("secret words")])
        sender.record("app_opened", ["how": .text("https://example.com")])
        sender.record("made_up_event")
        check(sender.queuedCount == 2 && sender.recent.count == 2, "only allowed events with allowed keys and words are queued")
        sender.send()
        check(!sender.sending && sender.queuedCount == 2 && sender.recent.allSatisfy { !$0.sent }, "send() starts nothing in a check build")

        // The wire format.
        let wire = UsageSender.wire(UsageEvent("app_search", ["result_count": .int(3)]), id: id)
        let properties = wire["properties"] as? [String: Any] ?? [:]
        check(Set(wire.keys) == ["event", "distinct_id", "timestamp", "properties"] && wire["distinct_id"] as? String == id, "each event: name, install ID, time, properties")
        check(properties["$geoip_disable"] as? Bool == true && properties["$ip"] is NSNull && properties["$lib"] as? String == "daydream" && properties["app_version"] is String,
              "every event says no GeoIP, no IP, $lib daydream and the app version")
        check(Set(properties.keys).subtracting(UsageCounts.commonKeys) == ["result_count"], "the sender adds only the common keys")
        let payload = UsageSender.payload(key: "phc_test", id: id, events: [UsageEvent("app_opened", ["how": .text("dock")])])
        check(Set(payload.keys) == ["api_key", "historical_migration", "batch"] && (payload["batch"] as? [Any])?.count == 1, "PostHog's batch body")
        check((try? JSONSerialization.data(withJSONObject: payload)) != nil, "the batch body is valid JSON")
        check(sender.json(sender.recent[0]).contains("\"$geoip_disable\" : true"), "See what's sent shows the JSON as sent")

        // The MCP helper's inbox.
        check(UsageInbox.appendAIUse(home: home, aiApp: "claude", tool: "current-context", resultCount: 0, latencyMs: 42), "the helper appends while the inbox exists")
        check(UsageInbox.appendAIUse(home: home, aiApp: "cursor", tool: "search", resultCount: 7, latencyMs: 9), "a second line")
        let tampered = try FileHandle(forWritingTo: UsageInbox.url(home))
        tampered.seekToEndOfFile(); tampered.write(Data(#"{"name":"ai_used","at":"2026-10-06T00:00:00Z","properties":{"tool":"search","query":"secret"}}"#.utf8 + [0x0A])); try tampered.close()
        UsageInbox.create(home: home)
        let drained = UsageInbox.drain(home: home)
        check(drained.count == 2 && drained[0].properties["tool"] == .text("current_context") && drained[0].properties["empty"] == .bool(true),
              "the app reads the helper's counts and drops a line with anything else in it")
        check(FileManager.default.fileExists(atPath: UsageInbox.url(home).path) && UsageInbox.drain(home: home).isEmpty, "reading empties the inbox and keeps it")
        sender.add(drained)
        check(sender.queuedCount == 4, "AI apps' counts join the queue")

        // Off: stops at once, drops the queue, the helper can't write.
        sender.setEnabled(false)
        check(!sender.enabled && sender.queuedCount == 0 && sender.recent.isEmpty, "turning sharing off drops the queue")
        check(!FileManager.default.fileExists(atPath: UsageInbox.url(home).path), "turning sharing off removes the inbox")
        check(!UsageInbox.appendAIUse(home: home, aiApp: "claude", tool: "search", resultCount: 1, latencyMs: 1) && !FileManager.default.fileExists(atPath: UsageInbox.url(home).path),
              "with sharing off the helper writes nothing and makes no file")
        sender.record("app_opened", ["how": .text("dock")])
        check(sender.queuedCount == 0, "nothing is queued while off")
        check(UsageSender(defaults: defaults).enabled == false, "the switch is kept")
        sender.setEnabled(true)
        check(FileManager.default.fileExists(atPath: UsageInbox.url(home).path), "turning it back on makes the inbox again")

        // The cap.
        for _ in 0..<(UsageSender.queueCap + 40) { sender.record("app_search", ["result_count": .int(1)]) }
        check(sender.queuedCount == UsageSender.queueCap && sender.recent.count == UsageSender.recentCap, "the queue keeps at most \(UsageSender.queueCap), See what's sent the last \(UsageSender.recentCap)")
        try? await Task.sleep(nanoseconds: 300_000_000)
        let reloaded = UsageSender(defaults: defaults)
        reloaded.start(home: home)
        check(reloaded.queuedCount == UsageSender.queueCap, "the queue survives a relaunch")
        let full = try Data(contentsOf: UsageInbox.url(home))
        check(full.isEmpty, "the inbox starts empty")
        for _ in 0..<2000 { UsageInbox.appendAIUse(home: home, aiApp: "claude", tool: "search", resultCount: 1, latencyMs: 1) }
        check(((try? FileManager.default.attributesOfItem(atPath: UsageInbox.url(home).path)[.size] as? Int) ?? .max) <= UsageInbox.maxBytes, "the inbox is capped")

        // Vocabulary.
        check(UsageCounts.aiApp(clientName: "claude-ai", connection: nil) == "claude" && UsageCounts.aiApp(clientName: "claude-code", connection: nil) == "claude_code"
              && UsageCounts.aiApp(clientName: "cursor-vscode", connection: nil) == "cursor" && UsageCounts.aiApp(clientName: "codex-mcp-client", connection: nil) == "chatgpt"
              && UsageCounts.aiApp(clientName: "Windsurf", connection: nil) == "windsurf" && UsageCounts.aiApp(clientName: "Some Editor", connection: nil) == "other"
              && UsageCounts.aiApp(clientName: nil, connection: "claude-desktop") == "claude", "AI app ids")
        check([0, 1, 3599, 3600, 3 * 3600, 6 * 3600].map { UsageCounts.hoursBucket(seconds: $0) } == ["0", "lt1", "lt1", "1_3", "3_6", "6plus"], "hour buckets")
        check(UsageCounts.tool("moment_details") == "moment_details" && UsageCounts.tool("anything") == "other", "tool names")
        check(UsageReport.summaries("cloud") == "openrouter" && UsageReport.recording(.needsPermission) == "off", "settings words")
        check(UsageCounts.allowed(UsageEvent("daily_check", ["connected_ai_apps": .list(["claude", "cursor"]), "hours_recorded_bucket": .text("1_3")]))
              && !UsageCounts.allowed(UsageEvent("daily_check", ["connected_ai_apps": .list(["My App"])])), "lists hold only AI app ids")
        check(UsageCounts.allowed(UsageEvent("installed", ["macos_version": .text("15.6.1"), "chip": .text("apple_silicon")]))
              && !UsageCounts.allowed(UsageEvent("installed", ["macos_version": .text("Nick's MacBook")])), "macos_version is a version number only")

        // Settings › Advanced, rendered (light and dark).
        let renders = out.appendingPathComponent("usage-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: true)
        let sample = UsageSender(defaults: defaults)
        sample.start(home: home)
        sample.setEnabled(false); sample.setEnabled(true)
        sample.record("daily_check", ["recording": .text("on"), "accessibility_ok": .bool(true), "input_monitoring_ok": .bool(true), "hours_recorded_bucket": .text("3_6"),
                                      "summaries": .text("local"), "connected_ai_apps": .list(["claude", "claude_code"]), "chrome_pages": .bool(true)])
        sample.add([UsageEvent("ai_used", ["ai_app": .text("claude"), "tool": .text("search"), "result_count": .int(4), "empty": .bool(false), "latency_ms": .int(180)])])
        let entries = sample.recent.enumerated().map { UsageSharingEntry(id: $0.offset, sent: $0.element.sent, json: sample.json($0.element)) }
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 720, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        for (name, showing) in [("advanced", false), ("advanced-see-whats-sent", true)] {
            for dark in [false, true] {
                let page = DaydreamSettingsFrame(title: "Advanced", back: {}, close: {}) {
                    MacMemSetupView(pause: {}, reviewLegacy: { InstallationReview.legacy(at: home) }, links: AnyView(VStack(alignment: .leading, spacing: 14) {
                        SettingsCard {
                            Toggle(isOn: .constant(true)) { Text(MemorySettings.openAtLoginTitle).font(.system(size: 13)) }
                                .toggleStyle(ReferenceToggleStyle()).frame(minHeight: 36)
                        }
                        UsageSharingCard(isOn: .constant(true), installID: sample.installID, entries: entries, showing: showing)
                        SettingsListCard { LinkRow(ForgetRangeText.menuTitle, area: .module(.retention)) {} }
                        SettingsListCard {
                            LinkRow(MemorySettings.importHistoryTitle, area: .summaries) {}
                            LinkRow(DaydreamSettingsPage.backup.title, area: .module(.backup)) {}
                            LinkRow(DaydreamSettingsPage.updates.title, area: .module(.updates)) {}
                        }
                    }))
                }
                .frame(width: 720, height: showing ? 900 : 640)
                .environment(\.daydreamStatic, true).transaction { $0.disablesAnimations = true }
                let host = NSHostingView(rootView: AnyView(page))
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                let size = NSSize(width: 720, height: showing ? 900 : 640)
                window.setContentSize(size); host.frame = NSRect(origin: .zero, size: size)
                try await Task.sleep(nanoseconds: 500_000_000)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fail("Advanced did not render") }
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: renders.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        window.contentView = nil
        check(sample.queuedCount > 0 && !sample.sending, "rendering sends nothing")
        print("PASS usage counts: renders in \(renders.path)")
        exit(0)
    }
}
