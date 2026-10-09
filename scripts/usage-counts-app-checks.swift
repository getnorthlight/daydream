// DD-RECIPE: APP
// Anonymous usage counts (UsageSender, UsageReport, UsageCounts, UsageInbox), on the real app sources built the way every
// check build is (-D DEVELOPMENT_SOURCE_CHECKS). Scratch folders under DD_CHECK_OUT and a private defaults suite; nothing
// is sent (this build may not send, and there is no project key), nothing records. Renders Settings › Advanced with
// the card to DD_CHECK_OUT/usage-renders.
import AppKit
import SwiftUI
import MemoryCore
import MemoryUI
// Collect, then report: a failed check prints FAIL and the run goes on; the process exits 1 at the end if any failed
// (an atexit handler, so every return path of main reports). stdout is line-buffered so FAIL lines survive a crash.
var ddFailures = 0
func ddFail(_ label: String) { ddFailures += 1; print("FAIL " + label) }
func ddReportAtExit() {
    setvbuf(stdout, nil, _IOLBF, 0)
    atexit { if ddFailures > 0 { print("\(ddFailures) failed"); fflush(stdout); _exit(1) } }
}

func fail(_ message: String) -> Never {
    fflush(stdout)
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}
func check(_ condition: Bool, _ message: @autoclosure () -> String) { if condition { print("PASS " + message()) } else { ddFail(message()) } }

@main @MainActor struct UsageCountsAppChecks {
    static func main() async throws {
        ddReportAtExit()
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

        // rel-018: app_updated, once per update.
        let launchSuite = suite + "-launch"
        let launch = UserDefaults(suiteName: launchSuite)!
        defer { launch.removePersistentDomain(forName: launchSuite) }
        check(UsageLaunch.version(short: "0.1.8", build: "12") == "0.1.8 (12)" && UsageLaunch.version(short: "0.1.8", build: nil) == "unknown"
              && UsageLaunch.version(short: "Sam's build", build: "1") == "unknown", "a version is \"0.1.8 (12)\" or \"unknown\", never free text")
        check(UsageLaunch.takeUpdate(launch, current: "0.1.8 (12)", newInstall: true) == nil, "a first launch on a Mac sends no app_updated (installed covers it)")
        check(launch.string(forKey: UsageLaunch.lastRunKey) == "0.1.8 (12)", "the version it ran is kept in the app's preferences")
        check(UsageLaunch.takeUpdate(launch, current: "0.1.8 (12)", newInstall: false) == nil, "the same build again (a relaunch) sends nothing")
        let update = UsageLaunch.takeUpdate(launch, current: "0.1.9 (13)", newInstall: false)
        check(update?.from == "0.1.8 (12)" && update?.to == "0.1.9 (13)", "a new version sends app_updated from and to")
        check(UsageLaunch.takeUpdate(launch, current: "0.1.9 (13)", newInstall: false) == nil,
              "the update counts once: Quit & Reopen or the automatic Input Monitoring restart after it sends nothing")
        check(UsageLaunch.takeUpdate(launch, current: "0.1.9 (14)", newInstall: false)?.from == "0.1.9 (13)", "a new build of the same version counts too")
        launch.removeObject(forKey: UsageLaunch.lastRunKey)
        let legacy = UsageLaunch.takeUpdate(launch, current: "0.1.8 (12)", newInstall: false)
        check(legacy?.from == "unknown" && legacy?.to == "0.1.8 (12)", "a copy that ran before 0.1.8 (an install ID, no version kept) counts as updated from unknown")
        launch.set("hand-edited", forKey: UsageLaunch.lastRunKey)
        check(UsageLaunch.takeUpdate(launch, current: "0.1.8 (12)", newInstall: false)?.from == "unknown", "a kept value of another shape is sent as unknown")
        let updated = UsageEvent("app_updated", ["from_version": .text("0.1.8 (12)"), "to_version": .text("0.1.9 (13)")])
        check(UsageCounts.allowed(updated) && UsageCounts.allowed(UsageEvent("app_updated", ["from_version": .text("unknown"), "to_version": .text("0.1.9 (13)")])),
              "app_updated with from_version and to_version is allowed")
        check(!UsageCounts.allowed(UsageEvent("app_updated", ["from_version": .text("/Users/someone/DayDream.app")]))
              && !UsageCounts.allowed(UsageEvent("app_updated", ["to_version": .text("0.1.9")])) && !UsageCounts.allowed(UsageEvent("app_updated", ["path": .text("0.1.9 (13)")])),
              "app_updated holds versions of that shape only")
        // Release builds: developer-id-release.py stamps "x.y.z Beta" and RELEASE.md a 14-digit date build (the installed
        // 0.1.7 reads "0.1.7 Beta" / 20261006231255). These must not fall to "unknown".
        let real8 = UsageLaunch.version(short: "0.1.8 Beta", build: "20261008120000")
        check(real8 == "0.1.8 Beta (20261008120000)" && UsageLaunch.version(short: "0.1.7 Beta", build: "20261006231255") == "0.1.7 Beta (20261006231255)"
              && UsageLaunch.version(short: "0.1.8", build: "20261008120000") == "0.1.8 (20261008120000)"
              && UsageLaunch.version(short: "0.1.8 Beta", build: "18446744073709551615") == "0.1.8 Beta (18446744073709551615)",
              "a release build's version (\"0.1.8 Beta\", a date build of up to 20 digits) is kept as it is")
        check(UsageLaunch.version(short: "0.1.8 beta", build: "1") == "unknown" && UsageLaunch.version(short: "0.1.8 Beta ", build: "1") == "unknown"
              && UsageLaunch.version(short: "0.1.8 Alpha", build: "1") == "unknown" && UsageLaunch.version(short: "0.1.8 Beta", build: "123456789012345678901") == "unknown"
              && UsageLaunch.version(short: "0.1.8 Beta", build: "2026-10-08") == "unknown",
              "only \" Beta\" may follow the number, and the build stays digits")
        launch.removeObject(forKey: UsageLaunch.lastRunKey)
        check(UsageLaunch.takeUpdate(launch, current: real8, newInstall: false).map { [$0.from, $0.to] } == ["unknown", real8],
              "a 0.1.7 copy's first 0.1.8 launch counts from unknown to the real 0.1.8 version")
        check(UsageLaunch.takeUpdate(launch, current: real8, newInstall: false) == nil, "the same release build again sends nothing")
        let real9 = UsageLaunch.version(short: "0.1.9 Beta", build: "20261015090000")
        let realUpdate = UsageLaunch.takeUpdate(launch, current: real9, newInstall: false)
        check(realUpdate?.from == real8 && realUpdate?.to == "0.1.9 Beta (20261015090000)", "the next release update counts from and to the real versions")
        check(UsageCounts.allowed(UsageEvent("app_updated", ["from_version": .text(real8), "to_version": .text(real9)]))
              && UsageCounts.allowed(UsageEvent("app_updated", ["from_version": .text("unknown"), "to_version": .text(real8)])),
              "app_updated with release-shaped versions is allowed")
        check(!UsageCounts.allowed(UsageEvent("app_updated", ["to_version": .text("0.1.9 Beta")]))
              && !UsageCounts.allowed(UsageEvent("app_updated", ["to_version": .text("0.1.9 Beta (x)")])),
              "a release-shaped version still needs its build")
        let updateSender = UsageSender(defaults: launch)
        updateSender.start(home: home)
        updateSender.record("app_updated", ["from_version": .text("0.1.8 (12)"), "to_version": .text("0.1.9 (13)")])
        check(updateSender.queuedCount >= 1 && updateSender.recent.first?.event.name == "app_updated" && updateSender.recent.first?.event.properties == updated.properties,
              "the sender queues app_updated")
        let updateWire = UsageSender.wire(updated, id: updateSender.installID)
        check(updateWire["distinct_id"] as? String == updateSender.installID && Set((updateWire["properties"] as? [String: Any] ?? [:]).keys).subtracting(UsageCounts.commonKeys) == ["from_version", "to_version"],
              "app_updated goes with the install ID and only its two versions")

        // rel-018: a launch at login is not an open.
        func openEvent(_ prop: AEKeyword?) -> NSAppleEventDescriptor {
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
                                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            if let prop { event.setParam(NSAppleEventDescriptor(enumCode: OSType(prop)), forKeyword: AEKeyword(keyAEPropData)) }
            return event
        }
        let reopenEvent = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication), targetDescriptor: nil,
                                                 returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        check(DaydreamAppDelegate.launchKind(openEvent(keyAELaunchedAsLogInItem)) == .atLogin, "the login item's open event (keyAELaunchedAsLogInItem) reads as a launch at login")
        check(DaydreamAppDelegate.launchKind(openEvent(nil)) == .opened, "Finder, Launchpad, the Dock or Spotlight's open event reads as opened")
        check(DaydreamAppDelegate.launchKind(openEvent(keyAELaunchedAsServiceItem)) == .noOpenEvent, "a Services-menu launch is not an open")
        check(DaydreamAppDelegate.launchKind(nil) == .noOpenEvent && DaydreamAppDelegate.launchKind(reopenEvent) == .noOpenEvent, "no open event reads as no open event")
        check(UsageLaunch.launchOpen(.opened, selfRelaunch: false) == "other", "a launch the person asked for counts as app_opened (other)")
        check(UsageLaunch.launchOpen(.atLogin, selfRelaunch: false) == nil, "a launch at login counts nothing")
        check(UsageLaunch.launchOpen(.noOpenEvent, selfRelaunch: false) == nil, "a launch without macOS's open event counts nothing")
        let now = Date()
        UsageLaunch.markSelfRelaunch(launch, now: now)
        check(UsageLaunch.takeSelfRelaunch(launch, now: now.addingTimeInterval(8)) && UsageLaunch.launchOpen(.opened, selfRelaunch: true) == nil,
              "DayDream's own restart (Quit & Reopen, the automatic restart, Sparkle's relaunch) counts nothing")
        check(!UsageLaunch.takeSelfRelaunch(launch, now: now.addingTimeInterval(9)), "the restart mark is used once")
        UsageLaunch.markSelfRelaunch(launch, now: now)
        check(!UsageLaunch.takeSelfRelaunch(launch, now: now.addingTimeInterval(UsageLaunch.selfRelaunchWindow + 1)), "an old restart mark (a restart that didn't happen) doesn't hide a real open")
        UsageLaunch.markSelfRelaunch(launch, now: now); UsageLaunch.clearSelfRelaunch(launch)
        check(!UsageLaunch.takeSelfRelaunch(launch, now: now), "a relaunch Sparkle gave up on leaves no mark")
        let report = try String(contentsOfFile: "Sources/MacMemApp/UsageReport.swift", encoding: .utf8)
        let requestsSource = try String(contentsOfFile: "Sources/MacMemApp/PermissionRequests.swift", encoding: .utf8)
        let updatesSource = try String(contentsOfFile: "Sources/MacMemApp/Updates.swift", encoding: .utf8)
        check(report.contains("func applicationDidFinishLaunching(_ notification: Notification) {\n        MainActor.assumeIsolated { UsageReport.launched(Self.launchKind()) }")
              && !report.contains("func applicationWillFinishLaunching"),
              "the launch is read in applicationDidFinishLaunching, where macOS's open event is current (it isn't yet in willFinishLaunching)")
        check(report.contains("func applicationShouldHandleReopen(") && report.contains("UsageReport.opened(\"dock\")"), "reopening the running app still counts (dock)")
        check(requestsSource.contains("UsageLaunch.markSelfRelaunch(.standard)") && updatesSource.contains("UsageLaunch.markSelfRelaunch(defaults,now:now)")
              && updatesSource.contains("UsageLaunch.clearSelfRelaunch(defaults)"), "Quit & Reopen and Sparkle's relaunch leave the restart mark")
        check(report.contains("UsageLaunch.takeUpdate(.standard, current: currentVersion, newInstall: made)") && report.components(separatedBy: "record(\"app_updated\"").count == 2,
              "app_updated is recorded in one place, at start, after the version is compared and replaced")

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
              && !UsageCounts.allowed(UsageEvent("installed", ["macos_version": .text("Sam's MacBook")])), "macos_version is a version number only")

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
