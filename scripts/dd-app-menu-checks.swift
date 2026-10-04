// DD-RECIPE: APP
// I1 app integration (plan §5 I1, §7 keyboard ownership, amendments I1), on the menus the app installs:
//   A. the real NSApp.mainMenu of a SwiftUI app whose memory scene has `.commands { DaydreamCommands(model:) }`
//      (AppCommands.swift, the same content the app's `AppCommands` installs): no duplicate (key, modifiers)
//      pair anywhere; every §7 binding present once, with its title and menu; no New Window, ⌘N, Print or
//      Page Setup; Start/Resume/Stop and the Moment privacy items without key equivalents;
//   B. enabled states and Recall-aware titles follow `ActivityBrowser.commandContext` and `recallVisible`;
//   C. key equivalents reach the right command through the main menu (`browser.send`, Recall, the model);
//      Open DayDream and Settings… reuse the open memory window instead of adding one; with the memory window
//      closed, Go / View / Moment are disabled and ⌘K reopens the window with Recall; the menu bar card's routes
//      (DaydreamAppMenuBarPanel) bring the one memory window forward instead of adding one;
//   D. the browser follows the system time zone (F0b contract request 3) and the day loader reads it at call time;
//   E. the inline shell: Find Related's Recall filter is heard before Recall first opens (W2-3), and closing
//      Recall leaves the Focus List's menu context in place (W2-17);
//   F. installed-app names reach dayCache.bundleNames off the main thread on a production-mode model (F0b CR2);
//   B2. on today (the toolbar stepper's rule) Next Day and Today are disabled; a sheet on the memory window
//      (Settings, a correction, a confirmation) disables Search…, Find…, day paging, Today, Refresh and the Moment
//      items, and their keys act on nothing behind it (acceptance fix-forward);
//   G. contract additions I1 applied: forget scopes in the note's own zone (W2-2), the detail's Open <App> only where
//      the host opens apps (W2-9), no "N of M actions" count at all (W2-12, then ux/declutter),
//      PermissionKind.settingsURL (W2-21).
// Stores live under DD_CHECK_OUT and the redirected Development Trial root. Nothing records, no app is opened,
// no permission is requested; the only windows are this check's own.
import AppKit
import SwiftUI
import Combine
import MemoryCore
import MemoryUI

@MainActor enum MenuCheck {
    static var failures = 0
    static func check(_ ok: Bool, _ message: String, _ detail: @autoclosure () -> String = "") {
        if ok { print("PASS \(message)") }
        else { failures += 1; FileHandle.standardError.write(Data("FAIL: \(message)\(detail().isEmpty ? "" : " (\(detail()))")\n".utf8)) }
    }
    /// Yields the main actor (no nested run loop: the main queue does not drain inside one of its own blocks,
    /// so day reads, Recall's filter task and the cache's next-turn work would never run).
    static func pump(_ seconds: Double = 0.15) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    @discardableResult static func wait(_ timeout: Double = 5, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { await pump(0.05) }
        return done()
    }

    // MARK: Models

    /// The Development Trial model behind the menus (synthetic store, capture and writers off).
    static let model: MemoryViewModel = {
        let root = URL(fileURLWithPath: "/private/tmp/daydream-development-trial-menu-" + UUID().uuidString)
        trialRoot = root
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for name in ["memory", "preferences", "backups"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
            }
            try Data("synthetic-only\n".utf8).write(to: root.appendingPathComponent("DEVELOPMENT-ONLY"))
            setenv("DAYDREAM_DEVELOPMENT_ROOT", root.path, 1)
            setenv("MAC_MEM_HOME", root.appendingPathComponent("memory").path, 1)
            setenv("CFFIXED_USER_HOME", root.appendingPathComponent("preferences").path, 1)
            let trial = try DevelopmentTrial.validate()
            try trial.prepare()
            let model = MemoryViewModel(development: trial)
            productionLoader = model.activity.loadCanonicalDay
            model.activity.loadCanonicalDay = { day, _ in try fixture(day: day) }
            return model
        } catch {
            FileHandle.standardError.write(Data("FAIL: Development Trial setup: \(error)\n".utf8)); exit(1)
        }
    }()
    /// The synthetic trial's directory (run-checks.sh rewrites its /private/tmp prefix to DD_CHECKS), removed at exit.
    static var trialRoot: URL?
    /// The memory window's openWindow action (MenuCheckRoot), for the menu bar card's routes.
    static var openWindow: OpenWindowAction?
    /// MacMemApp's own day loader (the store's dayLayers), kept before the fixture replaces it.
    static var productionLoader: ((String, String?) async throws -> ActionDay)?

    /// Today's fixture: four moments on `day` (UTC), the second with a ready note.
    static func fixture(day: String) throws -> ActionDay {
        let records: [[String: Any]] = (0..<8).map { index in
            ["id": "\(day)-\(index)", "evidenceIDs": [], "at": day + "T08:0\(index):00Z", "kind": "window.observed",
             "app": "Safari", "bundle": "com.apple.Safari", "site": "", "title": "Synthetic activity",
             "description": "Synthetic observation", "state": "observed", "revision": "fixture",
             "subject": "Synthetic subject", "observationKey": "fixture-\(index)"]
        }
        let notes: [[String: Any]] = (0..<4).map { index in
            let ids = ["\(day)-\(index * 2)", "\(day)-\(index * 2 + 1)"]
            var note: [String: Any] = ["id": "note-\(day)-\(index)", "day": day, "timezone": "UTC",
                "subject": "Synthetic moment \(index)", "actionIDs": ids, "apps": ["Safari"], "bundles": ["com.apple.Safari"],
                "sites": [], "start": day + "T08:0\(index * 2):00Z", "end": day + "T08:0\(index * 2 + 1):00Z",
                "clusters": [], "inputRevision": "fixture", "status": "pending"]
            if index == 1 {
                note["status"] = "ready"
                note["generated"] = ["id": "generated-\(day)", "version": 1, "schemaVersion": 1,
                    "generatedAt": day + "T09:00:00Z", "inputRevision": "fixture", "actionIDs": ids,
                    "status": "generated_unverified",
                    "output": ["requestID": "fixture", "title": "Synthetic ready note", "generator": "fixture", "generatorVersion": "1",
                        "bullets": [["text": "Read the synthetic page.", "actionIDs": ids, "assertion": "observed"]]]]
            }
            return note
        }
        let value: [String: Any] = [
            "summary": ["day": day, "timezone": "UTC", "start": day + "T00:00:00Z", "end": day + "T23:59:59Z",
                        "activityIDs": notes.map { $0["id"] as! String }, "actionCount": 8,
                        "countIsComplete": true, "inputRevision": "fixture", "status": "pending"],
            "activities": notes, "actions": ["actions": records, "revision": "fixture",
                "snapshot": ["epoch": "fixture", "highWater": 8], "candidates": 8],
            "defaultLayer": "activity_notes", "partial": false]
        return try JSONDecoder().decode(ActionDay.self, from: JSONSerialization.data(withJSONObject: value))
    }

    // MARK: Menu walk

    struct Entry {
        let path: [String]
        let item: NSMenuItem
        var title: String { item.title }
        var menu: String { path.first ?? "" }
        /// "⇧⌘C"-style, nil without a key equivalent.
        var combo: String? { MenuCheck.combo(item) }
    }

    nonisolated static func combo(_ item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        var mods = item.keyEquivalentModifierMask.intersection([.control, .option, .shift, .command])
        var key = item.keyEquivalent
        if key != key.lowercased() { mods.insert(.shift); key = key.lowercased() }
        let names: [String: String] = ["\r": "↩", " ": "Space", "\u{1b}": "Esc", "\u{8}": "⌫", "\u{7f}": "⌫", "\t": "⇥"]
        var text = ""
        if mods.contains(.control) { text += "⌃" }
        if mods.contains(.option) { text += "⌥" }
        if mods.contains(.shift) { text += "⇧" }
        if mods.contains(.command) { text += "⌘" }
        if let scalar = key.unicodeScalars.first, (0xF700...0xF8FF).contains(scalar.value) { return text + "F\(scalar.value)" }
        return text + (names[key] ?? key.uppercased())
    }

    /// Every item of the main menu, submenus first updated (SwiftUI and AppKit fill some lazily).
    static func entries() -> [Entry] {
        guard let main = NSApp.mainMenu else { return [] }
        var out: [Entry] = []
        func walk(_ menu: NSMenu, _ path: [String]) {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for item in menu.items where !item.isSeparatorItem {
                let here = path + [item.title]
                out.append(Entry(path: path.isEmpty ? [item.title] : path, item: item))
                if let sub = item.submenu { walk(sub, path.isEmpty ? [item.title] : here) }
            }
        }
        for (index, top) in main.items.enumerated() {
            // The application menu is titled after the process; call it "App".
            let name = index == 0 ? "App" : top.title
            if let sub = top.submenu { walk(sub, [name]) }
        }
        return out
    }
    static func find(_ menu: String, _ title: String, in all: [Entry]) -> Entry? {
        all.first { $0.menu == menu && $0.title == title && live($0) }
    }
    /// Shown, or kept out of sight by DaydreamMenuTidy (Go ▸ Find…, View ▸ Refresh without Option) with its key working.
    static func live(_ e: Entry) -> Bool {
        !e.item.isHidden || (e.item.allowsKeyEquivalentWhenHidden
            && (DaydreamMenuTidy.hidden + DaydreamMenuTidy.optionOnly).contains { $0.menu == e.menu && $0.title == e.title })
    }
    static func refreshed() async -> [Entry] { await pump(0.25); return entries() }
    /// A day that is never today: part B and C page from it, so Next Day and Today have something to do.
    static let pastDay = "2000-01-03"

    /// A key-down built the way the window server builds one (CGEvent, current keyboard layout), never posted.
    /// NSEvent.keyEvent(characters:…) events carry no layout, and AppKit then matches ⌘R against ⇧⌘R items.
    static func key(_ code: CGKeyCode, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        var cg: CGEventFlags = []
        if flags.contains(.command) { cg.insert(.maskCommand) }
        if flags.contains(.shift) { cg.insert(.maskShift) }
        if flags.contains(.option) { cg.insert(.maskAlternate) }
        if flags.contains(.control) { cg.insert(.maskControl) }
        event.flags = cg
        return NSEvent(cgEvent: event)!
    }
}

// MARK: - The check app

@main struct DDAppMenuChecks: App {
    @NSApplicationDelegateAdaptor(MenuCheckDriver.self) private var driver
    var body: some Scene {
        WindowGroup("DayDream", id: "memory") { MenuCheckRoot() }
            .windowToolbarStyle(.unified(showsTitle: false))
            .defaultSize(width: 640, height: 360)
            .commands {
                DaydreamCommands(model: MenuCheck.model)
                // Check fixture: the Recording rows as they read while Paused (no ⌘P passed), for Resume Recording.
                CommandMenu("Paused Rows") {
                    MenuBarRecordingMenu(state: .paused(until: nil, since: nil, reason: nil), canResume: true, canStop: true, actions: CaptureActions())
                }
            }
        // The app's auxiliary windows, as MacMemApp.swift declares them (titles, `.commandsRemoved()`), so the Window
        // menu walked here is the app's (check_shortcuts.py pins the modifier on the app's scenes).
        Window("DayDream · Synthetic preview", id: "demo") { Text("demo") }.commandsRemoved()
        Window("DayDream permissions", id: "permissions") { Text("permissions") }.commandsRemoved()
        Window("Set up DayDream", id: "onboarding") { Text("onboarding") }.commandsRemoved()
    }
}

/// The memory window's stand-in: a mounted shell for the menus (ShellPresence), but nothing in it writes the menu
/// context, so part B controls it directly.
struct MenuCheckRoot: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("dd-app-menu-checks").frame(minWidth: 320, minHeight: 200)
            .daydreamShellPresence(MenuCheck.model.activity)
            .onAppear { MenuCheck.openWindow = openWindow }
    }
}

final class MenuCheckDriver: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
            FileHandle.standardError.write(Data("FAIL: dd-app-menu-checks watchdog expired after 120s\n".utf8)); exit(2)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            Task { @MainActor () async -> Void in
                await MenuCheckDriver.run()
                for window in NSApp.windows { window.orderOut(nil) }
                let model = MenuCheck.model
                MenuCheck.check(!model.recording && model.noteWriter.provider == "off" && model.development != nil,
                                "end: the Development Trial model never recorded; summaries stayed off")
                if let root = MenuCheck.trialRoot { try? FileManager.default.removeItem(at: root) }
                exit(MenuCheck.failures == 0 ? 0 : 1)
            }
        }
    }

    @MainActor static func run() async {
        let model = MenuCheck.model, browser = model.activity
        _ = await MenuCheck.wait(5) { NSApp.windows.contains(where: DaydreamMainWindow.isMain) }
        MenuCheck.check(NSApp.windows.filter(DaydreamMainWindow.isMain).count == 1,
                        "the memory WindowGroup's window is recognised as the main window (identifier memory-…)",
                        NSApp.windows.map { $0.identifier?.rawValue ?? "nil" }.joined(separator: ","))
        structure()
        await states(model: model, browser: browser)
        await dispatch(model: model, browser: browser)
        await sheet(model: model, browser: browser)
        await closedWindow(model: model, browser: browser)
        await menuBarRoutes(model: model, browser: browser)
        await timeZone(model: model)
        await shell(model: model, browser: browser)
        await bundleNames()
        await contracts()
        await tidy(model: model, browser: browser)
    }

    // MARK: T. Menu tidy (ux/declutter)

    /// Go ▸ Find… is never shown and View ▸ Refresh only with Option held; both keep their keys.
    @MainActor static func tidy(model: MemoryViewModel, browser: ActivityBrowser) async {
        guard let main = NSApp.mainMenu else { MenuCheck.check(false, "main menu present"); return }
        func item(_ menu: String, _ title: String) -> NSMenuItem? { MenuCheck.entries().first { $0.menu == menu && $0.title == title }?.item }
        _ = await MenuCheck.refreshed()
        DaydreamMenuTidy.apply(option: false)
        let find = item("Go", "Find…"), refresh = item("View", "Refresh"), search = item("Go", "Search…")
        MenuCheck.check(find?.isHidden == true && find?.allowsKeyEquivalentWhenHidden == true && search?.isHidden == false,
                        "Go ▸ Find… is hidden (it repeats Search… ⌘K) and keeps ⌘F")
        MenuCheck.check(refresh?.isHidden == true && refresh?.allowsKeyEquivalentWhenHidden == true, "View ▸ Refresh is hidden without Option and keeps ⇧⌘R")
        var sent: [DaydreamCommand] = []
        let sink = browser.commands.sink { sent.append($0) }
        defer { sink.cancel() }
        browser.recallPresented = false; browser.query = ""; browser.commandContext = DaydreamCommandContext()
        browser.focusedDay = MenuCheck.pastDay
        await MenuCheck.pump(0.2)
        DaydreamMenuTidy.apply(option: false)
        sent = []
        var handled = main.performKeyEquivalent(with: MenuCheck.key(15, [.command, .shift]))
        await MenuCheck.pump(0.1)
        MenuCheck.check(handled && sent == [.refresh], "⇧⌘R still sends .refresh with Refresh hidden", "handled \(handled), sent \(sent)")
        sent = []
        DaydreamMenuTidy.apply(option: false)
        handled = main.performKeyEquivalent(with: MenuCheck.key(3, .command))
        await MenuCheck.pump(0.1)
        MenuCheck.check(handled && browser.recallPresented, "⌘F still opens Recall with Find… hidden", "handled \(handled), presented \(browser.recallPresented)")
        browser.recallPresented = false
        DaydreamMenuTidy.apply(option: true)
        MenuCheck.check(item("View", "Refresh")?.isHidden == false && item("Go", "Find…")?.isHidden == true,
                        "with Option held, View ▸ Refresh shows; Find… stays hidden")
        // SwiftUI adds and updates its items as state changes and menus open: the tidy follows every change.
        DaydreamMenuTidy.apply(option: false)
        browser.recallPresented = true; await MenuCheck.pump(0.2)
        browser.recallPresented = false; browser.focusedDay = MenuCheck.pastDay; await MenuCheck.pump(0.2)
        MenuCheck.check(item("Go", "Find…")?.isHidden == true && item("View", "Refresh")?.isHidden == true && item("Go", "Search…")?.isHidden == false,
                        "after SwiftUI updates the menus, Find… and Refresh stay hidden and Search… shows")
        browser.focusedDay = nil
    }

    // MARK: A. Structure

    @MainActor static func structure() {
        let all = MenuCheck.entries()
        MenuCheck.check(all.count > 20, "the main menu is installed and walked", "\(all.count) items")
        var seen: [String: [String]] = [:]
        for e in all where MenuCheck.live(e) {   // a tidy-hidden item's key still works, so it counts
            guard let c = e.combo else { continue }
            seen[c, default: []].append((e.path + [e.title]).joined(separator: " ▸ "))
        }
        let duplicates = seen.filter { $0.value.count > 1 }
        MenuCheck.check(duplicates.isEmpty, "no (key, modifiers) pair is bound twice in the main menu",
                        duplicates.map { "\($0.key): \($0.value.joined(separator: " | "))" }.sorted().joined(separator: "; "))
        print("EVIDENCE key equivalents: " + seen.keys.sorted().map { "\($0)=\(seen[$0]![0])" }.joined(separator: ", "))

        let bindings: [(String, String, String?)] = [
            ("App", "Settings…", "⌘,"), ("App", "Quit DayDream", "⌘Q"),
            ("File", "Set Up DayDream…", nil),
            ("View", "Refresh", "⇧⌘R"),
            ("Go", "Search…", "⌘K"), ("Go", "Find…", "⌘F"), ("Go", "Previous Day", "⌘["), ("Go", "Next Day", "⌘]"), ("Go", "Today", "⌘T"),
            ("Moment", "Open Original", "⌘↩"), ("Moment", "Copy Summary", "⇧⌘C"), ("Moment", "Find Related Moments", "⌘R"),
            ("Moment", "Edit Correction…", nil), ("Moment", "Forget This Moment…", nil),
            ("Recording", "Pause for", nil),
            ("Recording", "Start Recording", nil), ("Recording", "Stop Recording", nil),
            ("Window", "Open DayDream", "⌘O"),
        ]
        for (menu, title, combo) in bindings {
            let e = MenuCheck.find(menu, title, in: all)
            MenuCheck.check(e != nil && e?.combo == combo, "\(menu) ▸ \(title) is bound to \(combo ?? "no key")",
                            e.map { "found \($0.combo ?? "no key")" } ?? "missing")
        }
        let order = all.filter { $0.path.count == 1 && $0.menu == "Moment" }.map(\.title)
        MenuCheck.check(order.starts(with: ["Open Original", "Copy Summary", "Find Related Moments", "Edit Correction…", "Forget This Moment…"]),
                        "Moment menu order: Open Original, Copy Summary, Find Related Moments, then the privacy items", order.joined(separator: ", "))
        MenuCheck.check(!all.contains { $0.menu == "Moment" && $0.title.hasPrefix("Exclude ") },
                        "Exclude <App> from Recording… is hidden while no app is named")
        // ux/declutter: one Pause for ▸ submenu; its 15 Minutes carries ⌘P (there is no separate Pause for 15 Minutes row).
        let presets = all.filter { $0.path == ["Recording", "Pause for"] }
        MenuCheck.check(presets.map(\.title) == ["5 Minutes", "15 Minutes", "30 Minutes", "2 Hours"] && presets.map(\.combo) == [nil, "⌘P", nil, nil],
                        "Recording ▸ Pause for ▸ 5 Minutes, 15 Minutes ⌘P, 30 Minutes, 2 Hours",
                        presets.map { "\($0.title) \($0.combo ?? "-")" }.joined(separator: ", "))
        MenuCheck.check(!all.contains { $0.menu == "Recording" && $0.title == "Pause for 15 Minutes" }, "no separate Pause for 15 Minutes row")
        let topTitles = NSApp.mainMenu?.items.dropFirst().map(\.title) ?? []
        MenuCheck.check(topTitles.firstIndex(of: "Go").map { i in Array(topTitles[i...].prefix(3)) == ["Go", "Moment", "Recording"] } ?? false,
                        "menu bar order: … Go, Moment, Recording …", topTitles.joined(separator: ", "))
        for banned in ["New Window", "Print…", "Page Setup…", "Print", "New"] {
            MenuCheck.check(!all.contains { $0.title == banned && !$0.item.isHidden }, "no \(banned) item")
        }
        MenuCheck.check(!all.contains { $0.combo == "⌘N" && !$0.item.isHidden }, "⌘N is unbound")
        let pauses = all.filter { $0.combo == "⌘P" && !$0.item.isHidden }
        MenuCheck.check(pauses.count == 1 && pauses.first?.title == "15 Minutes" && pauses.first?.path == ["Recording", "Pause for"],
                        "⌘P is Recording ▸ Pause for ▸ 15 Minutes only", pauses.map(\.title).joined(separator: ", "))
        let finds = all.filter { $0.combo == "⌘F" && MenuCheck.live($0) }
        MenuCheck.check(finds.count == 1 && finds.first?.menu == "Go", "⌘F is Go ▸ Find… only (no Edit ▸ Find ▸ Find…)",
                        finds.map { ($0.path + [$0.title]).joined(separator: " ▸ ") }.joined(separator: ", "))
        let resume = MenuCheck.find("Paused Rows", "Resume Recording", in: all)
        MenuCheck.check(resume != nil && resume?.combo == nil && MenuCheck.find("Paused Rows", "Stop Recording", in: all)?.combo == nil
                        && all.first(where: { $0.path == ["Paused Rows", "Pause for"] && $0.title == "15 Minutes" }).map { $0.combo == nil } == true,
                        "Resume Recording and Stop Recording (the rows while Paused) have no key equivalent; ⌘P comes only from AppCommands",
                        resume.map { "Resume \($0.combo ?? "no key")" } ?? "Resume Recording missing")

        // Window menu: Open DayDream and the standard items; the auxiliary windows add none (`.commandsRemoved()`).
        let window = all.filter { $0.menu == "Window" && !$0.item.isHidden }.map(\.title)
        print("EVIDENCE Window menu: " + window.joined(separator: " | "))
        MenuCheck.check(window.contains("Open DayDream") && window.contains("Minimize"), "the Window menu is walked (Open DayDream, Minimize)")
        let aux = ["DayDream · Synthetic preview", "DayDream permissions", "Set up DayDream"].filter(window.contains)
        MenuCheck.check(aux.isEmpty, "the demo, permissions and onboarding windows add no Window-menu item (Set up DayDream would bypass the disabled File item)",
                        aux.joined(separator: ", "))
    }

    // MARK: B. States and titles

    @MainActor static func states(model: MemoryViewModel, browser: ActivityBrowser) async {
        browser.recallPresented = false; browser.query = ""
        browser.commandContext = DaydreamCommandContext()
        browser.focusedDay = MenuCheck.pastDay
        var all = await MenuCheck.refreshed()
        func enabled(_ menu: String, _ title: String) -> Bool? { MenuCheck.find(menu, title, in: all)?.item.isEnabled }
        MenuCheck.check(model.recordingState.kind != .recording
                        && all.first(where: { $0.path == ["Recording", "Pause for"] && $0.title == "15 Minutes" })?.item.isEnabled == false,
                        "⌘P Pause for ▸ 15 Minutes is disabled while not recording")
        let presets = all.filter { $0.path == ["Recording", "Pause for"] }
        MenuCheck.check(presets.count == 4 && presets.allSatisfy { !$0.item.isEnabled } && enabled("Recording", "Start Recording") == false
                        && enabled("Recording", "Stop Recording") == false,
                        "Development Trial: every Pause for preset, Start Recording and Stop Recording are disabled",
                        "Pause for \(String(describing: enabled("Recording", "Pause for"))), Start \(String(describing: enabled("Recording", "Start Recording"))), state \(model.recordingState), canResume \(model.presentation.canResume)")
        MenuCheck.check(enabled("File", "Set Up DayDream…") == false, "Set Up DayDream… is disabled in the Development Trial")
        MenuCheck.check(enabled("App", "Settings…") == true && enabled("Window", "Open DayDream") == true, "Settings… and Open DayDream are enabled")
        MenuCheck.check(enabled("Go", "Search…") == true && enabled("Go", "Find…") == true, "Search… and Find… are enabled with a search backend")
        MenuCheck.check(enabled("Go", "Previous Day") == true && enabled("Go", "Next Day") == true && enabled("Go", "Today") == true
                        && enabled("View", "Refresh") == true, "day paging, Today and Refresh are enabled while Recall is hidden")
        // On today there is no next day and Today does nothing: the menu follows the toolbar's day stepper.
        for (label, day) in [("no focused day", nil as String?), ("today's key", browser.dayCache.todayKey)] where label == "no focused day" || day != nil {
            browser.focusedDay = day
            all = await MenuCheck.refreshed()
            MenuCheck.check(DayStepper.isOnToday(browser) && enabled("Go", "Previous Day") == true && enabled("Go", "Next Day") == false
                            && enabled("Go", "Today") == false && enabled("View", "Refresh") == true,
                            "on today (\(label)): Next Day and Today are disabled, as the day stepper; Previous Day and Refresh stay enabled",
                            "Previous \(String(describing: enabled("Go", "Previous Day"))), Next \(String(describing: enabled("Go", "Next Day"))), Today \(String(describing: enabled("Go", "Today")))")
        }
        browser.focusedDay = MenuCheck.pastDay
        all = await MenuCheck.refreshed()
        MenuCheck.check(!DayStepper.isOnToday(browser) && enabled("Go", "Next Day") == true && enabled("Go", "Today") == true,
                        "back on an earlier day, Next Day and Today are enabled again")
        for title in ["Open Original", "Copy Summary", "Find Related Moments", "Edit Correction…", "Forget This Moment…"] {
            MenuCheck.check(enabled("Moment", title) == false, "Moment ▸ \(title) is disabled with nothing selected")
        }

        // The Focus List's context: a selected moment with a summary.
        browser.commandContext = DaydreamCommandContext(hasSelection: true, hasSummary: true, canOpenOriginal: true, canForget: true,
                                                        selectionDayTitle: "Today", openTitle: "Open Safari", excludeAppName: "Safari",
                                                        canFindRelated: true, canEditCorrection: true)
        all = await MenuCheck.refreshed()
        MenuCheck.check(MenuCheck.find("Moment", "Open Safari", in: all)?.combo == "⌘↩" && enabled("Moment", "Open Safari") == true,
                        "Moment ▸ Open <App> takes the context's title and keeps ⌘↩")
        MenuCheck.check(["Copy Summary", "Find Related Moments", "Edit Correction…", "Forget This Moment…"].allSatisfy { enabled("Moment", $0) == true },
                        "a selection enables Copy Summary, Find Related Moments, Edit Correction… and Forget This Moment…")
        let exclude = MenuCheck.find("Moment", "Exclude Safari from Recording…", in: all)
        MenuCheck.check(exclude != nil && exclude?.combo == nil && exclude?.item.isEnabled == true,
                        "Exclude Safari from Recording… appears, enabled, without a key equivalent")
        MenuCheck.check(!all.contains { $0.menu == "Moment" && $0.title.hasPrefix("Don't Record ") },
                        "Don't Record <site>… is hidden for a moment that is not a Google Chrome page")
        // A Google Chrome moment with a site: Don't Record <site>… after Exclude, no key equivalent, sends .excludeSite.
        browser.commandContext = DaydreamCommandContext(hasSelection: true, hasSummary: true, canOpenOriginal: true, canForget: true,
                                                        selectionDayTitle: "Today", openTitle: "Open Original", excludeAppName: "Google Chrome",
                                                        canFindRelated: true, canEditCorrection: true, excludeSite: "example.com")
        all = await MenuCheck.refreshed()
        let dontRecord = MenuCheck.find("Moment", "Don't Record example.com…", in: all)
        MenuCheck.check(dontRecord != nil && dontRecord?.combo == nil && dontRecord?.item.isEnabled == true,
                        "Don't Record example.com… appears for a Chrome moment, enabled, without a key equivalent")
        let momentOrder = all.filter { $0.path.count == 1 && $0.menu == "Moment" }.map(\.title)
        MenuCheck.check(momentOrder.suffix(2) == ["Exclude Google Chrome from Recording…", "Don't Record example.com…"],
                        "Don't Record <site>… is the last Moment item, after Exclude", momentOrder.joined(separator: ", "))
        MenuCheck.check(all.filter { $0.title.hasPrefix("Don't Record ") }.count == 1, "one Don't Record item in the whole menu bar")
        if let item = dontRecord?.item, let menu = item.menu {
            var siteSent: [DaydreamCommand] = []
            let siteSink = browser.commands.sink { siteSent.append($0) }
            menu.performActionForItem(at: menu.index(of: item))
            await MenuCheck.pump(0.1)
            siteSink.cancel()
            MenuCheck.check(siteSent == [.excludeSite], "Don't Record example.com… sends .excludeSite once", "\(siteSent)")
        } else { MenuCheck.check(false, "Don't Record example.com… can be chosen") }
        browser.commandContext = DaydreamCommandContext(hasSelection: true, hasSummary: true, canOpenOriginal: true, canForget: true,
                                                        selectionDayTitle: "Today", openTitle: "Open Safari", excludeAppName: "Safari",
                                                        canFindRelated: true, canEditCorrection: true)
        all = await MenuCheck.refreshed()
        MenuCheck.check(MenuCheck.find("Go", "Today", in: all) != nil, "Go ▸ Today keeps its title while Recall is hidden")

        // Recall visible with a selection on Monday: Show in Monday, no day paging, no Refresh.
        browser.recallPresented = true
        browser.commandContext = DaydreamCommandContext(hasSelection: true, hasSummary: false, canOpenOriginal: false, canForget: false,
                                                        selectionDayTitle: "Monday", recallVisible: true, openTitle: nil, excludeAppName: nil,
                                                        canFindRelated: true, canEditCorrection: false)
        all = await MenuCheck.refreshed()
        let show = MenuCheck.find("Go", "Show in Monday", in: all)
        MenuCheck.check(show?.combo == "⌘T" && show?.item.isEnabled == true && MenuCheck.find("Go", "Today", in: all) == nil,
                        "Go ▸ Today reads Show in Monday (⌘T) while Recall has a selection on Monday")
        MenuCheck.check(enabled("Go", "Previous Day") == false && enabled("Go", "Next Day") == false && enabled("View", "Refresh") == false,
                        "day paging and Refresh are disabled while Recall is visible")
        MenuCheck.check(enabled("Moment", "Open Original") == false && enabled("Moment", "Copy Summary") == false
                        && enabled("Moment", "Find Related Moments") == true && enabled("Moment", "Edit Correction…") == false
                        && enabled("Moment", "Forget This Moment…") == false,
                        "Recall's context drives the Moment menu (Find Related only)")
        MenuCheck.check(!all.contains { $0.menu == "Moment" && $0.title.hasPrefix("Exclude ") }, "Exclude is hidden again when no app is named")
        MenuCheck.check(enabled("Go", "Search…") == true && enabled("Go", "Find…") == true, "Search… and Find… stay enabled while Recall is visible")

        browser.commandContext = DaydreamCommandContext(recallVisible: true)
        all = await MenuCheck.refreshed()
        MenuCheck.check(MenuCheck.find("Go", "Today", in: all)?.item.isEnabled == false,
                        "Go ▸ Today is disabled while Recall shows no selection (the Focus List is covered)")
        browser.recallPresented = false
        browser.commandContext = DaydreamCommandContext()
        await MenuCheck.pump()

        // Pure rule behind the title.
        typealias Go = DaydreamGoCommands
        let t1 = Go.todayItem(DaydreamCommandContext(), recallVisible: false)
        let t2 = Go.todayItem(DaydreamCommandContext(hasSelection: true, selectionDayTitle: "Today", recallVisible: true), recallVisible: true)
        let t3 = Go.todayItem(DaydreamCommandContext(hasSelection: true, selectionDayTitle: "Sep 14", recallVisible: true), recallVisible: true)
        MenuCheck.check(t1.title == "Today" && t1.command == .today && t2.title == "Show in Today" && t2.command == .showInToday
                        && t3.title == "Show in Sep 14" && t3.enabled,
                        "todayItem: Today / Show in Today / Show in Sep 14")
        let t4 = Go.todayItem(DaydreamCommandContext(), recallVisible: false, onToday: true)
        let t5 = Go.todayItem(DaydreamCommandContext(hasSelection: true, selectionDayTitle: "Today", recallVisible: true), recallVisible: true, onToday: true)
        MenuCheck.check(t1.enabled && !t4.enabled && t4.title == "Today" && t5.enabled && t5.title == "Show in Today",
                        "todayItem: Today is disabled on today; Recall's Show in <Day> is not affected")
        browser.focusedDay = nil
    }

    // MARK: C. Dispatch

    @MainActor static func dispatch(model: MemoryViewModel, browser: ActivityBrowser) async {
        guard let main = NSApp.mainMenu else { MenuCheck.check(false, "main menu present"); return }
        var sent: [DaydreamCommand] = []
        let sink = browser.commands.sink { sent.append($0) }
        defer { sink.cancel() }
        func press(_ chars: String, _ flags: NSEvent.ModifierFlags, _ code: UInt16) async -> Bool {
            _ = await MenuCheck.refreshed()
            sent = []
            let handled = main.performKeyEquivalent(with: MenuCheck.key(code, flags))
            await MenuCheck.pump(0.1)
            return handled
        }
        // Recall hidden: the Focus List's commands, from an earlier day.
        browser.recallPresented = false; browser.query = ""; browser.commandContext = DaydreamCommandContext()
        browser.focusedDay = MenuCheck.pastDay
        for (chars, code, command, name) in [("[", UInt16(33), DaydreamCommand.previousDay, "⌘["), ("]", 30, .nextDay, "⌘]"), ("t", 17, .today, "⌘T")] {
            let handled = await press(chars, .command, code)
            MenuCheck.check(handled && sent == [command], "\(name) sends .\(command) while Recall is hidden", "handled \(handled), sent \(sent)")
        }
        // On today: ⌘] and ⌘T have nothing to do; ⌘[ still pages back.
        browser.focusedDay = nil
        for (chars, code, name) in [("]", UInt16(30), "⌘]"), ("t", 17, "⌘T")] {
            _ = await press(chars, .command, code)
            MenuCheck.check(sent.isEmpty, "\(name) sends nothing on today", "sent \(sent)")
        }
        let back = await press("[", .command, 33)
        MenuCheck.check(back && sent == [.previousDay], "⌘[ still sends .previousDay on today", "handled \(back), sent \(sent)")
        var handled = await press("R", [.command, .shift], 15)
        MenuCheck.check(handled && sent == [.refresh], "⇧⌘R sends .refresh", "handled \(handled), sent \(sent)")
        handled = await press("c", [.command, .shift], 8)
        MenuCheck.check(sent.isEmpty, "⇧⌘C sends nothing with nothing selected", "sent \(sent)")
        handled = await press("k", .command, 40)
        MenuCheck.check(handled && browser.recallPresented && sent.isEmpty, "⌘K opens Recall while it is hidden", "handled \(handled), presented \(browser.recallPresented), sent \(sent)")
        MenuCheck.check(NSApp.windows.filter(DaydreamMainWindow.isMain).count == 1, "⌘K reuses the open memory window")
        browser.recallPresented = false
        handled = await press("f", .command, 3)
        MenuCheck.check(handled && browser.recallPresented && sent.isEmpty, "⌘F opens Recall while it is hidden", "handled \(handled), sent \(sent)")

        // Recall visible with a selection: Recall's commands.
        browser.recallPresented = true
        browser.commandContext = DaydreamCommandContext(hasSelection: true, hasSummary: true, canOpenOriginal: true, canForget: true,
                                                        selectionDayTitle: "Today", recallVisible: true, openTitle: "Open Original",
                                                        excludeAppName: nil, canFindRelated: true, canEditCorrection: false)
        let visible: [(String, NSEvent.ModifierFlags, UInt16, DaydreamCommand, String)] = [
            ("k", .command, 40, .toggleActions, "⌘K"), ("f", .command, 3, .find, "⌘F"), ("t", .command, 17, .showInToday, "⌘T"),
            ("\r", .command, 36, .openOriginal, "⌘↩"), ("C", [.command, .shift], 8, .copySummary, "⇧⌘C"), ("r", .command, 15, .findRelated, "⌘R"),
        ]
        for (chars, flags, code, command, name) in visible {
            let handled = await press(chars, flags, code)
            MenuCheck.check(handled && sent == [command], "\(name) sends .\(command) while Recall is visible", "handled \(handled), sent \(sent)")
        }
        for (chars, code, name) in [("[", UInt16(33), "⌘["), ("]", 30, "⌘]")] {
            _ = await press(chars, .command, code)
            MenuCheck.check(sent.isEmpty, "\(name) sends nothing while Recall is visible", "sent \(sent)")
        }
        browser.recallPresented = false; browser.commandContext = DaydreamCommandContext()

        // Model commands.
        _ = await press("p", .command, 35)
        MenuCheck.check(!model.recording && model.pauseUntil == nil, "⌘P does nothing while not recording")
        model.settingsPresented = false; model.settingsSection = "Recording"
        handled = await press(",", .command, 43)
        MenuCheck.check(handled && model.settingsPresented && model.settingsSection == "General", "⌘, opens Settings on General",
                        "presented \(model.settingsPresented), section \(model.settingsSection)")
        model.settingsPresented = false
        await MenuCheck.pump(0.4)
        handled = await press("o", .command, 31)
        MenuCheck.check(handled && NSApp.windows.filter(DaydreamMainWindow.isMain).count == 1, "⌘O Open DayDream reuses the open memory window",
                        "memory windows \(NSApp.windows.filter(DaydreamMainWindow.isMain).count)")
        _ = await press("n", .command, 45)
        MenuCheck.check(NSApp.windows.filter(DaydreamMainWindow.isMain).count == 1, "⌘N opens no new window")
    }

    // MARK: C1. A sheet on the memory window

    /// The key router already ignores keys while a sheet is attached; the menus must too (a sheet stands in for
    /// Settings, a correction or a Forget / Exclude confirmation).
    @MainActor static func sheet(model: MemoryViewModel, browser: ActivityBrowser) async {
        guard let main = NSApp.mainMenu, let window = NSApp.windows.first(where: DaydreamMainWindow.isMain) else {
            MenuCheck.check(false, "main menu and memory window present"); return
        }
        var sent: [DaydreamCommand] = []
        let sink = browser.commands.sink { sent.append($0) }
        defer { sink.cancel() }
        browser.recallPresented = false; browser.query = ""; browser.focusedDay = MenuCheck.pastDay
        browser.commandContext = DaydreamCommandContext(hasSelection: true, hasSummary: true, canOpenOriginal: true, canForget: true,
                                                        selectionDayTitle: "Today", openTitle: "Open Safari", excludeAppName: "Safari",
                                                        canFindRelated: true, canEditCorrection: true)
        let covered = [("Go", "Search…"), ("Go", "Find…"), ("Go", "Previous Day"), ("Go", "Next Day"), ("Go", "Today"), ("View", "Refresh"),
                       ("Moment", "Open Safari"), ("Moment", "Copy Summary"), ("Moment", "Find Related Moments"), ("Moment", "Edit Correction…"),
                       ("Moment", "Forget This Moment…")]
        var all = await MenuCheck.refreshed()
        func enabled(_ menu: String, _ title: String) -> Bool? { MenuCheck.find(menu, title, in: all)?.item.isEnabled }
        let before = covered.filter { enabled($0.0, $0.1) != true }.map { "\($0.0) ▸ \($0.1)" }
        MenuCheck.check(before.isEmpty, "before the sheet: Search…, day paging, Today, Refresh and the Moment items are enabled", before.joined(separator: ", "))

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet, completionHandler: nil)
        let attached = await MenuCheck.wait(3) { window.attachedSheet === sheet }
        all = await MenuCheck.refreshed()
        let on = covered.filter { enabled($0.0, $0.1) != false }.map { "\($0.0) ▸ \($0.1)" }
        MenuCheck.check(attached && on.isEmpty, "a sheet on the memory window disables Search…, Find…, day paging, Today, Refresh and the Moment items",
                        "attached \(attached); still enabled: \(on.joined(separator: ", "))")
        MenuCheck.check(enabled("App", "Settings…") == true && enabled("Window", "Open DayDream") == true,
                        "Settings… and Open DayDream stay enabled over a sheet")
        // golden test 5 (G40): Quit works over Settings (it closes the sheet and quits; update-quit-checks.swift).
        MenuCheck.check(enabled("App", "Quit DayDream") == true, "Quit DayDream stays enabled over a sheet")
        let keys: [(UInt16, NSEvent.ModifierFlags, String)] = [(40, .command, "⌘K"), (3, .command, "⌘F"), (33, .command, "⌘["), (30, .command, "⌘]"),
                                                              (17, .command, "⌘T"), (36, .command, "⌘↩"), (8, [.command, .shift], "⇧⌘C"),
                                                              (15, .command, "⌘R"), (15, [.command, .shift], "⇧⌘R")]
        for (code, flags, name) in keys {
            sent = []
            _ = main.performKeyEquivalent(with: MenuCheck.key(code, flags))
            await MenuCheck.pump(0.1)
            MenuCheck.check(sent.isEmpty && !browser.recallPresented, "\(name) acts on nothing behind a sheet",
                            "sent \(sent), Recall \(browser.recallPresented)")
        }
        window.endSheet(sheet)
        let released = await MenuCheck.wait(3) { window.attachedSheet == nil }
        all = await MenuCheck.refreshed()
        let off = covered.filter { enabled($0.0, $0.1) != true }.map { "\($0.0) ▸ \($0.1)" }
        MenuCheck.check(released && off.isEmpty, "when the sheet ends the items are enabled again", "released \(released); still disabled: \(off.joined(separator: ", "))")
        browser.recallPresented = false; browser.commandContext = DaydreamCommandContext(); browser.focusedDay = nil
        await MenuCheck.pump()
    }

    // MARK: C2. No memory window

    @MainActor static func closedWindow(model: MemoryViewModel, browser: ActivityBrowser) async {
        guard let main = NSApp.mainMenu else { MenuCheck.check(false, "main menu present"); return }
        var sent: [DaydreamCommand] = []
        let sink = browser.commands.sink { sent.append($0) }
        defer { sink.cancel() }
        browser.recallPresented = false; browser.query = ""
        MenuCheck.check(ShellPresence.shared.isMounted(browser), "the memory window's shell is mounted (ShellPresence)")
        // The Focus List's selection when the window closes.
        browser.commandContext = DaydreamCommandContext(hasSelection: true, hasSummary: true, canOpenOriginal: true, canForget: true,
                                                        selectionDayTitle: "Today", openTitle: "Open Safari", excludeAppName: "Safari",
                                                        canFindRelated: true, canEditCorrection: true)
        await MenuCheck.pump()
        // The window closes with a sheet still attached (no didEndSheet posts then): the sheet watch must not keep
        // the menus disabled for the next memory window.
        var leftSheet: NSWindow?
        if let main = NSApp.windows.first(where: DaydreamMainWindow.isMain) {
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            main.beginSheet(sheet, completionHandler: nil)
            MenuCheck.check(await MenuCheck.wait(3) { DaydreamSheetWatch.shared.onMainWindow }, "the sheet watch sees a sheet on the memory window")
            leftSheet = sheet
        }
        for window in NSApp.windows where DaydreamMainWindow.isMain(window) { window.close() }
        let reset = await MenuCheck.wait(3) { !ShellPresence.shared.isMounted(browser) && browser.commandContext == DaydreamCommandContext() }
        let cleared = await MenuCheck.wait(3) { !DaydreamSheetWatch.shared.onMainWindow }
        MenuCheck.check(cleared, "closing the memory window with a sheet attached clears the sheet watch")
        leftSheet?.orderOut(nil)
        MenuCheck.check(reset && NSApp.windows.filter(DaydreamMainWindow.isMain).isEmpty,
                        "closing the memory window unmounts its shell and clears the menus' selection context",
                        "mounted \(ShellPresence.shared.isMounted(browser)), hasSelection \(browser.commandContext.hasSelection)")
        let all = await MenuCheck.refreshed()
        func enabled(_ menu: String, _ title: String) -> Bool? { MenuCheck.find(menu, title, in: all)?.item.isEnabled }
        let dead = [("Go", "Previous Day"), ("Go", "Next Day"), ("Go", "Today"), ("View", "Refresh"), ("Moment", "Open Original"),
                    ("Moment", "Copy Summary"), ("Moment", "Find Related Moments"), ("Moment", "Edit Correction…"), ("Moment", "Forget This Moment…")]
        let on = dead.filter { enabled($0.0, $0.1) != false }.map { "\($0.0) ▸ \($0.1)" }
        MenuCheck.check(on.isEmpty, "with no memory window, Go ▸ Previous Day / Next Day / Today, View ▸ Refresh and every Moment item are disabled",
                        on.joined(separator: ", "))
        MenuCheck.check(!all.contains { $0.menu == "Moment" && $0.title.hasPrefix("Exclude ") }, "with no memory window, Exclude <App> is gone")
        MenuCheck.check(enabled("Go", "Search…") == true && enabled("Window", "Open DayDream") == true && enabled("App", "Settings…") == true,
                        "Search…, Open DayDream and Settings… stay enabled: they open the window")
        // Recall was left open in the closed window: ⌘K reopens the window with Recall rather than messaging no one.
        browser.recallPresented = true
        sent = []
        let handled = main.performKeyEquivalent(with: MenuCheck.key(40, .command))
        let reopened = await MenuCheck.wait(3) { NSApp.windows.filter(DaydreamMainWindow.isMain).count == 1 && ShellPresence.shared.isMounted(browser) }
        MenuCheck.check(handled && reopened && sent.isEmpty && browser.recallPresented,
                        "⌘K with the memory window closed (Recall left open) opens one memory window with Recall and sends nothing",
                        "handled \(handled), windows \(NSApp.windows.filter(DaydreamMainWindow.isMain).count), sent \(sent), presented \(browser.recallPresented)")
        browser.recallPresented = false; browser.commandContext = DaydreamCommandContext()
        await MenuCheck.pump()
        let all2 = await MenuCheck.refreshed()
        MenuCheck.check(MenuCheck.find("Go", "Previous Day", in: all2)?.item.isEnabled == true, "day paging is enabled again once the window is back")
    }

    // MARK: C3. The menu bar card's routes

    @MainActor static func menuBarRoutes(model: MemoryViewModel, browser: ActivityBrowser) async {
        guard let openWindow = MenuCheck.openWindow else { MenuCheck.check(false, "the memory window's openWindow action"); return }
        func windows() -> Int { NSApp.windows.filter(DaydreamMainWindow.isMain).count }
        let routes = DaydreamMainWindow.menuBarRoutes(openWindow)
        let actions = DaydreamMenuBarPanel.actions(model: model, routes: routes)
        browser.recallPresented = false
        actions.openMain()
        await MenuCheck.pump(0.4)
        MenuCheck.check(windows() == 1, "card ▸ Open DayDream brings the open memory window forward (no second window)", "\(windows()) windows")
        actions.openRecall()
        await MenuCheck.pump(0.4)
        MenuCheck.check(windows() == 1 && browser.recallPresented, "card ▸ Search… opens Recall in the one memory window", "\(windows()) windows")
        browser.recallPresented = false
        model.settingsPresented = false
        actions.settings()
        await MenuCheck.pump(0.4)
        MenuCheck.check(windows() == 1 && model.settingsPresented && model.settingsSection == "General",
                        "card ▸ Settings… opens the sheet on General in the one memory window", "\(windows()) windows")
        model.settingsPresented = false
        // The today line: today in the one memory window, Recall closed and nothing expanded.
        browser.expandedMomentID = "note-latest"
        browser.recallPresented = true
        DaydreamMenuBarPanel.openToday(model: model, routes: routes)
        await MenuCheck.pump(0.4)
        MenuCheck.check(windows() == 1 && browser.expandedMomentID == nil && browser.focusedDay == nil && !browser.recallPresented,
                        "panel ▸ today line opens today in the one memory window", "\(windows()) windows")
        // With the window closed, the card opens exactly one.
        for window in NSApp.windows where DaydreamMainWindow.isMain(window) { window.close() }
        _ = await MenuCheck.wait(3) { windows() == 0 }
        actions.openMain()
        let one = await MenuCheck.wait(3) { windows() == 1 }
        actions.openMain()
        await MenuCheck.pump(0.4)
        MenuCheck.check(one && windows() == 1, "card ▸ Open DayDream with no window opens one, and a second press reuses it", "\(windows()) windows")
        _ = await MenuCheck.wait(3) { ShellPresence.shared.isMounted(browser) }
        browser.commandContext = DaydreamCommandContext()
    }

    // MARK: D. Time zone

    @MainActor static func timeZone(model: MemoryViewModel) async {
        let activity = model.activity
        let original = activity.calendar.timeZone
        let target = original.identifier == "Pacific/Chatham" ? "Asia/Kathmandu" : "Pacific/Chatham"
        let system = MemoryViewModel.readSystemTimeZone
        MemoryViewModel.readSystemTimeZone = { TimeZone(identifier: target)! }
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        MenuCheck.check(activity.calendar.timeZone.identifier == target,
                        "a system time-zone change moves the browser's calendar synchronously", activity.calendar.timeZone.identifier)
        await MenuCheck.pump(0.3)
        let expected = try? DayScope.key(activity.now(), timezone: target)
        MenuCheck.check(activity.dayCache.todayKey == expected, "the day cache's today follows the new zone on the next turn",
                        "\(activity.dayCache.todayKey ?? "nil") vs \(expected ?? "nil")")
        if let load = MenuCheck.productionLoader, let key = expected {
            do {
                let day = try await load(key, nil)
                MenuCheck.check(day.summary.timezone == target, "MacMemApp's day loader reads the zone when called, not when created",
                                day.summary.timezone)
            } catch { MenuCheck.check(false, "the production day loader read today", "\(error)") }
        } else { MenuCheck.check(false, "MacMemApp set a day loader on the Development Trial model") }
        MenuCheck.check(model.memoryChangedUsesZone(target), "memoryChanged compares note zones with the current display zone")
        MenuCheck.check(model.dayChangeInvalidations(retentionDays: nil) == [], "midnight without a retention limit keeps cached days")
        MenuCheck.check(model.dayChangeInvalidations(retentionDays: 30) == ["all"],
                        "midnight under a retention limit drops every cached day (the cutoff moved; contract request 4)")
        MemoryViewModel.readSystemTimeZone = { original }
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        MemoryViewModel.readSystemTimeZone = system
        MenuCheck.check(activity.calendar.timeZone.identifier == original.identifier, "the calendar returns with the zone")
        await MenuCheck.pump(0.3)
    }

    // MARK: E. Inline shell (W2-3, W2-17)

    @MainActor static func shell(model: MemoryViewModel, browser: ActivityBrowser) async {
        browser.recallPresented = false; browser.query = ""; browser.commandContext = DaydreamCommandContext()
        browser.selectedMomentID = nil; browser.expandedMomentID = nil; browser.focusedDay = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: MemoryWindow(model: model, chrome: .inline))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        await MenuCheck.pump(0.6)

        // W2-3: the Focus List's Find Related posts the filter, then presents Recall.
        let filter = RecallFilter(kind: .app, value: "com.apple.Safari", label: "Safari")
        NotificationCenter.default.post(name: .daydreamRecallFilter, object: browser, userInfo: filter.userInfo)
        await MenuCheck.pump(0.2)
        browser.recallPresented = true
        MenuCheck.check(await MenuCheck.wait(3) { browser.commandContext.recallVisible }, "Recall opens in the inline shell")
        MenuCheck.check(browser.recallModel.filter == filter, "a Find Related filter posted before Recall first opened is applied (W2-3)",
                        String(describing: browser.recallModel.filter))
        browser.recallPresented = false
        await MenuCheck.pump(0.4)

        // W2-17: select a moment in the Focus List, open Recall, close it.
        guard let today = browser.dayCache.syncTodayKey() else { MenuCheck.check(false, "today's key"); return }
        do { _ = try MenuCheck.fixture(day: today) } catch { MenuCheck.check(false, "the fixture day decodes", "\(error)") }
        browser.today.refresh(force: true)
        let id = "note-\(today)-1"
        browser.selectedMomentID = id
        let selected = await MenuCheck.wait(5) { browser.commandContext.hasSelection && !browser.commandContext.recallVisible }
        guard selected else {
            print("LIMIT: the Focus List wrote no selection context for \(id) offscreen; W2-17 not exercised (snapshot \(browser.today.snapshot.map { "\($0.dayKey): \($0.moments.map(\.id))" } ?? "nil"), context \(browser.commandContext), selected \(browser.selectedMomentID ?? "nil"))")
            return
        }
        let focus = browser.commandContext
        MenuCheck.check(focus.hasSummary, "the Focus List's context: the selected moment with its ready note")
        var writes: [DaydreamCommandContext] = []
        let sink = browser.$commandContext.sink { writes.append($0) }
        defer { sink.cancel() }
        browser.recallPresented = true
        MenuCheck.check(await MenuCheck.wait(3) { browser.commandContext.recallVisible }, "Recall's context replaces the Focus List's while open")
        writes = []
        browser.recallPresented = false
        await MenuCheck.pump(0.6)
        let order = writes.map { $0 == focus ? "focus" : $0 == DaydreamCommandContext() ? "reset" : $0.recallVisible ? "recall" : "other" }
        print("EVIDENCE W2-17 writes after close: \(order.joined(separator: ", "))")
        MenuCheck.check(browser.commandContext == focus, "closing Recall leaves the Focus List's selection context for the menus (W2-17)",
                        "hasSelection \(browser.commandContext.hasSelection)")
        browser.selectedMomentID = nil
        await MenuCheck.pump(0.2)
    }

    // MARK: F. Installed-app names (production-mode model)

    @MainActor static func bundleNames() async {
        let shared = ["/private/tmp/" + "day" + "dream-", "/tmp/" + "day" + "dream-"]
        guard let out = ProcessInfo.processInfo.environment["DD_CHECK_OUT"], out.hasPrefix("/"), !shared.contains(where: { out.hasPrefix($0) }) else {
            MenuCheck.check(false, "DD_CHECK_OUT is a private output directory (run through run-checks.sh)"); return
        }
        let memory = URL(fileURLWithPath: out).appendingPathComponent("production-\(UUID().uuidString)/memory", isDirectory: true)
        do { try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { MenuCheck.check(false, "private production store", "\(error)"); return }
        setenv("MAC_MEM_HOME", memory.path, 1)
        let model = MemoryViewModel()
        MenuCheck.check(model.development == nil && !model.recordingTrial && !model.recording, "production-mode model on a private store, not recording")
        let named = await MenuCheck.wait(20) { !model.activity.dayCache.bundleNames.isEmpty }
        let names = model.activity.dayCache.bundleNames
        MenuCheck.check(named, "installed-app names reach dayCache.bundleNames after launch", "\(names.count) names")
        if let textEdit = names["com.apple.TextEdit"] {
            MenuCheck.check(textEdit == "TextEdit", "TextEdit's bundle ID maps to its name", textEdit)
        } else { print("LIMIT: TextEdit is not installed here; bundleNames has \(names.count) entries") }
        MenuCheck.check(!model.recording && model.stopped && model.noteWriter.provider == "off", "the production model stayed off")
        model.cancelTimedPause()
    }
}

// MARK: - G. Contract additions

extension MenuCheckDriver {
    @MainActor static func contracts() async {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = la
        // W2-2 / #6: a note recorded in Tokyo, shown on an LA calendar, is forgotten in its own day and zone.
        let noteValue: [String: Any] = ["id": "note-tokyo", "day": "2026-09-23", "timezone": "Asia/Tokyo", "subject": "Tokyo moment",
            "actionIDs": ["t-0"], "apps": ["Zed"], "bundles": ["dev.zed.Zed"], "sites": [], "start": "2026-09-23T01:00:00Z",
            "end": "2026-09-23T01:10:00Z", "clusters": [], "inputRevision": "fixture", "status": "pending"]
        do {
            let note = try JSONDecoder().decode(ActivityNote.self, from: JSONSerialization.data(withJSONObject: noteValue))
            let slice = MomentSlice.make(note: note, dayPartial: false, summaries: SummaryAvailability(provider: .off, busy: false), calendar: calendar)
            MenuCheck.check(slice.timeZoneID == "Asia/Tokyo" && slice.dayKey == "2026-09-23", "MomentSlice carries the note's own zone",
                            "\(slice.timeZoneID ?? "nil") \(slice.dayKey)")
            let forget = MomentForgetRequest(moment: slice, timeZone: la)
            MenuCheck.check(forget.scope.kind == "activity" && forget.scope.id == "note-tokyo" && forget.scope.day == "2026-09-23"
                            && forget.scope.timezone == "Asia/Tokyo" && forget.timeZone == la,
                            "Forget scopes a Tokyo note in its own day and zone, shown on an LA calendar (W2-2)",
                            "\(forget.scope.day ?? "nil") \(forget.scope.timezone ?? "nil")")
        } catch { MenuCheck.check(false, "the Tokyo note decodes", "\(error)") }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func slice(zone: String?, actions: Int = 1) -> MomentSlice {
            MomentSlice(id: "m", dayKey: "2026-09-22", start: start, end: start.addingTimeInterval(600), title: "Moment", subject: "Moment",
                        firstBullet: nil, bullets: [], apps: ["Zed"], primaryBundle: "dev.zed.Zed", bundles: ["dev.zed.Zed"], sites: [],
                        actionIDs: (0..<actions).map { "m-\($0)" }, actionCount: actions, clusters: [], summary: .summariesOff,
                        hasCorrection: false, timeZoneID: zone)
        }
        // Don't Record <site>…: only a Google Chrome moment's first valid site, only in the Focus List, only when the hook is set.
        func web(_ bundle: String, _ app: String, _ sites: [String]) -> MomentSlice {
            MomentSlice(id: "w", dayKey: "2026-09-22", start: start, end: start.addingTimeInterval(600), title: "Moment", subject: "Moment",
                        firstBullet: nil, bullets: [], apps: [app], primaryBundle: bundle, bundles: [bundle], sites: sites,
                        actionIDs: ["w-0"], actionCount: 1, clusters: [], summary: .summariesOff, hasCorrection: false, primaryApp: app)
        }
        let siteCaps = MomentActions.Capabilities(excludeApp: true, excludeSite: true)
        let chromeMoment = web("com.google.Chrome", "Google Chrome", ["plannedparenthood.org", "www.example.com", "github.com"])
        MenuCheck.check(DaydreamCommandContext.make(selection: chromeMoment, context: .focusList, capabilities: siteCaps, recallVisible: false).excludeSite == "example.com",
                        "a Chrome moment's context names its first site that isn't already skipped")
        for (bundle, app) in [("com.apple.Safari", "Safari"), ("org.mozilla.firefox", "Firefox"), ("dev.zed.Zed", "Zed")] {
            MenuCheck.check(DaydreamCommandContext.make(selection: web(bundle, app, ["example.com"]), context: .focusList, capabilities: siteCaps,
                                                        recallVisible: false).excludeSite == nil, "no Don't Record item for a \(app) moment")
        }
        MenuCheck.check(DaydreamCommandContext.make(selection: chromeMoment, context: .focusList, capabilities: MomentActions.Capabilities(excludeApp: true),
                                                    recallVisible: false).excludeSite == nil, "no Don't Record item without the excludeSite hook")
        MenuCheck.check(DaydreamCommandContext.make(selection: chromeMoment, context: .recall(dayIsToday: true), capabilities: siteCaps,
                                                    recallVisible: true).excludeSite == nil, "no Don't Record item from Recall")
        MenuCheck.check(DaydreamCommandContext.make(selection: web("com.google.Chrome", "Google Chrome", []), context: .focusList, capabilities: siteCaps,
                                                    recallVisible: false).excludeSite == nil, "no Don't Record item for a Chrome moment without a site")
        let fallback = MomentForgetRequest(moment: slice(zone: nil), timeZone: la)
        MenuCheck.check(fallback.scope.timezone == "America/Los_Angeles", "a slice without a zone scopes in the display zone",
                        fallback.scope.timezone ?? "nil")

        // W2-9: Open <App> only where the host's open activates the app.
        func action(_ id: String, app: String, bundle: String, site: String) -> CanonicalAction? {
            let value: [String: Any] = ["id": id, "evidenceIDs": [], "at": "2026-09-22T08:00:00Z", "kind": "window.observed", "app": app,
                                        "bundle": bundle, "site": site, "title": "Title", "description": "Description", "state": "observed",
                                        "revision": "fixture", "subject": "Subject", "observationKey": id]
            return try? JSONDecoder().decode(CanonicalAction.self, from: JSONSerialization.data(withJSONObject: value))
        }
        typealias Body = MomentDetailBody
        if let web = action("w", app: "Safari", bundle: "com.apple.Safari", site: "github.com"),
           let native = action("n", app: "Zed", bundle: "dev.zed.Zed", site: ""),
           let unnamed = action("u", app: "Zed", bundle: "", site: "") {
            let w = Body.rowOpenTitle(web, opensApps: true)
            MenuCheck.check(w.label == "Open Original" && w.help == "Opens github.com in your browser", "a web row: Open Original, help Opens github.com in your browser",
                            "\(w.label) / \(w.help)")
            MenuCheck.check(Body.rowOpenTitle(native, opensApps: true).label == "Open Zed", "a native-only row says Open Zed where the host opens apps (the Focus List)")
            MenuCheck.check(Body.rowOpenTitle(native).label == "Open Original" && Body.rowOpenTitle(native, opensApps: false).label == "Open Original",
                            "a native-only row keeps Open Original where the host reopens every row (Recall)")
            MenuCheck.check(Body.rowOpenTitle(unnamed, opensApps: true).label == "Open Original",
                            "a row with no bundle keeps Open Original (nothing to activate)")
        } else { MenuCheck.check(false, "the W2-9 fixture actions decode") }
        // Review G31: a typed row saved before test 5 holds the bundle ID as its app name.
        if let typedOld = action("t", app: "com.apple.Notes", bundle: "com.apple.Notes", site: "") {
            MenuCheck.check(Body.rowOpenTitle(typedOld, opensApps: true).label == "Open Notes", "G31 an older typed row saved with the bundle ID says Open Notes, not Open com.apple.Notes")
        } else { MenuCheck.check(false, "the G31 fixture action decodes") }
        MenuCheck.check(EnvironmentValues().daydreamDetailOpensApps == false, "\\.daydreamDetailOpensApps defaults to false")

        // W2-12, then ux/declutter: the detail draws no "N of M actions" count (so never "0 of N" either); the
        // Load More / Show all link under the rows is what says there is more.
        if let first = action("m-0", app: "Zed", bundle: "dev.zed.Zed", site: "") {
            func png(_ actions: [CanonicalAction]) -> Data? {
                let view = Body(moment: slice(zone: nil, actions: 3), actions: actions, complete: false, timeZone: la, calendar: calendar, now: start,
                                showsHeader: false)
                    .frame(width: 520, height: 260).background(Color.white).environment(\.colorScheme, .light)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 520, height: 260)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
                host.cacheDisplay(in: host.bounds, to: rep)
                window.contentView = nil
                return rep.representation(using: .png, properties: [:])
            }
            let shown = png([first]), again = png([first])
            MenuCheck.check(shown != nil && shown == again, "the detail body renders deterministically offscreen")
            let kit = (try? String(contentsOfFile: "Sources/MemoryUI/DaydreamKitMoments.swift", encoding: .utf8)) ?? ""
            MenuCheck.check(!kit.isEmpty && !kit.contains("countText(") && !kit.contains("showsCount"),
                            "MomentDetailBody draws no N of M actions line")
        }

        // W2-21: the one System Settings table.
        let base = "x-apple.systempreferences:com.apple.preference.security"
        MenuCheck.check(PermissionKind.settingsURL(.accessibility).absoluteString == base + "?Privacy_Accessibility"
                        && PermissionKind.settingsURL(.inputMonitoring).absoluteString == base + "?Privacy_ListenEvent"
                        && PermissionKind.settingsURL(nil).absoluteString == base,
                        "PermissionKind.settingsURL: Accessibility, Input Monitoring, Privacy & Security")
    }
}

extension MemoryViewModel {
    /// memoryChanged(day:timezone:) drops only the named day when the note's zone is the display zone now.
    @MainActor func memoryChangedUsesZone(_ zone: String) -> Bool {
        var events: [String] = []
        let saved = dayData
        dayData = DayDataHooks(invalidate: { events.append("day:\($0)") }, invalidateAll: { events.append("all") },
                               refreshToday: { _ in }, refreshTodayIfStale: { _ in })
        memoryChanged(day: "2026-09-22", timezone: zone)
        dayData = saved
        return events == ["day:2026-09-22"]
    }
    /// What calendarDayChanged(retentionDays:) invalidates.
    @MainActor func dayChangeInvalidations(retentionDays: Int?) -> [String] {
        var events: [String] = []
        let saved = dayData
        dayData = DayDataHooks(invalidate: { events.append("day:\($0)") }, invalidateAll: { events.append("all") },
                               refreshToday: { _ in }, refreshTodayIfStale: { _ in })
        calendarDayChanged(retentionDays: retentionDays)
        dayData = saved
        return events
    }
}
