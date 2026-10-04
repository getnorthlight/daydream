import AppKit
import SwiftUI
import MemoryCore
import MemoryUI

@main struct WindowViewportChecks {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/daydream-development-trial-window-" + UUID().uuidString)
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
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 35) {
            FileHandle.standardError.write(Data("FAIL: full-window layout watchdog expired\n".utf8))
            exit(2)
        }
        let model = MemoryViewModel(development: trial)
        model.activity.loadCanonicalDay = { day, _ in try fixture(day: day) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        var maximum = 0.0
        // `.inline`: a bare NSHostingView has no scene toolbar style (the app's scene puts the controls in the window toolbar).
        for (name, view) in [("normal", AnyView(MemoryWindow(model: model, chrome: .inline))), ("synthetic", AnyView(SyntheticWindow(chrome: .inline)))] {
            let host = NSHostingView(rootView: view)
            precondition(host.sizingOptions == [.minSize, .intrinsicContentSize, .maxSize])
            window.contentView = host
            window.setContentSize(NSSize(width: 900, height: 600))
            window.makeKeyAndOrderFront(nil)
            func tick() {
                RunLoop.main.run(until: Date().addingTimeInterval(0.04))
                host.layoutSubtreeIfNeeded()
            }
            tick()
            for step in 0..<12 {
                let started = Date()
                let size = [NSSize(width: 560, height: 340), NSSize(width: 887, height: 490), NSSize(width: 1280, height: 800)][step % 3]
                window.setContentSize(size)
                if name == "normal" {
                    model.activity.query = step % 4 == 0 ? "sample" : ""
                    // Recall summoned (⌘K) at 560x340 on steps 0 and 6, closed otherwise.
                    model.activity.recallPresented = step % 6 == 0
                }
                tick()
                let intrinsic = host.intrinsicContentSize
                let fitting = host.fittingSize
                FileHandle.standardOutput.write(Data("SIZE \(name) \(step): requested \(size), actual \(host.bounds.size), intrinsic \(intrinsic), fitting \(fitting), window \(window.frame), content \(window.contentLayoutRect), min \(window.contentMinSize), max \(window.contentMaxSize), resizing \(host.autoresizingMask.rawValue)\n".utf8))
                precondition([intrinsic.width, intrinsic.height, fitting.width, fitting.height].allSatisfy { $0.isFinite && $0 < 10_000 })
                precondition(host.bounds.width >= 560 && host.bounds.height >= 340)
                precondition(abs(host.bounds.width - size.width) < 1 && abs(host.bounds.height - size.height) < 1)
                maximum = max(maximum, Date().timeIntervalSince(started))
            }
            FileHandle.standardOutput.write(Data("PASS: \(name) full window, default intrinsic sizing, 12 resize/search cycles\n".utf8))
            // One recording control and one settings control, in both windows (the toolbar row draws inline here), with
            // the app's own memory window open beside it as in the packaged trial: MemoryWindow's default chrome hands
            // its controls to the window toolbar, and that shell must not count against this host.
            let appWindow = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            appWindow.contentView = NSHostingView(rootView: MemoryWindow(model: model))
            appWindow.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<5 { tick() }
            let census = PackagedTrial.countsByCensus(host)
            let here = ShellChromeCensus.shells(under: host)
            guard ShellChromeCensus.windowToolbars >= 1 else {
                FileHandle.standardError.write(Data("FAIL: \(name): the app-style memory window mounted no window-toolbar shell (window toolbars \(ShellChromeCensus.windowToolbars))\n".utf8)); exit(1)
            }
            guard PackagedTrial.controlsOnce(host) else {
                FileHandle.standardError.write(Data("FAIL: \(name) window does not show capture-state and memory-settings exactly once (\(census ? "no accessibility tree; census of this host" : "accessibility tree"): inline rows \(here.inlineRows), window toolbars \(here.windowToolbars); process-wide \(ShellChromeCensus.inlineRows)/\(ShellChromeCensus.windowToolbars))\n".utf8)); exit(1)
            }
            appWindow.orderOut(nil); appWindow.contentView = nil
            for _ in 0..<2 { tick() }
            if census {
                print("LIMIT: SwiftUI exposes no accessibility tree offscreen here; toolbar rows counted per host instead of the two identifiers (a source lint in check_shortcuts.py keeps each identifier on one control)")
                FileHandle.standardOutput.write(Data("PASS: \(name) window mounts one inline toolbar row (its one recording capsule and settings gear) and no window-toolbar shell, beside an app window whose shell uses the window toolbar\n".utf8))
            } else {
                FileHandle.standardOutput.write(Data("PASS: \(name) window shows capture-state and memory-settings exactly once, beside an app window whose shell uses the window toolbar\n".utf8))
            }
            if name == "normal" {
                // Recall open at the minimum size: the window keeps its bounds and Recall is mounted over the day.
                model.activity.query = ""
                model.activity.recallPresented = true
                window.setContentSize(NSSize(width: 560, height: 340))
                for _ in 0..<5 { tick() }
                precondition(model.activity.recallVisible && model.activity.canSearch)
                precondition(abs(host.bounds.width - 560) < 1 && abs(host.bounds.height - 340) < 1 && host.fittingSize.width.isFinite && host.fittingSize.height.isFinite)
                // Only a mounted Recall writes a context with recallVisible (RecallModel.appeared → updateContext).
                guard model.activity.commandContext.recallVisible else {
                    FileHandle.standardError.write(Data("FAIL: Recall is presented at 560x340 but not mounted over the day\n".utf8)); exit(1)
                }
                model.activity.recallPresented = false
                for _ in 0..<3 { tick() }
                guard !model.activity.commandContext.recallVisible else {
                    FileHandle.standardError.write(Data("FAIL: Recall closed but its menu context remains\n".utf8)); exit(1)
                }
                FileHandle.standardOutput.write(Data("PASS: normal window keeps 560x340 with Recall open (mounted over the day), then closes it\n".utf8))
            }
        }
        precondition(!model.recording && model.noteWriter.provider == "off" && model.development != nil)
        print(String(format: "PASS: finite windows, minimum 560x340; slowest cycle %.3fs; isolated memory only", maximum))
    }

    static func fixture(day: String) throws -> ActionDay {
        let records: [[String: Any]] = (0..<200).map { index in
            ["id": "\(day)-\(index)", "evidenceIDs": [], "at": day + "T08:00:00Z", "kind": "window.observed",
             "app": "Synthetic app", "bundle": "", "site": "", "title": "Synthetic activity",
             "description": "Synthetic observation", "state": "observed", "revision": "fixture",
             "subject": "Synthetic subject", "observationKey": "fixture-\(index)"]
        }
        let notes: [[String: Any]] = (0..<4).map { index in
            let ids = index == 0 ? (0..<597).map { "\(day)-\($0)" } : ["\(day)-\(index)"]
            var note: [String: Any] = ["id": "note-\(day)-\(index)", "day": day, "timezone": "UTC",
                "subject": String(repeating: "Synthetic note. ", count: index + 1), "actionIDs": ids,
                "apps": ["Synthetic app"], "sites": [], "start": day + "T08:00:00Z", "end": day + "T08:01:00Z",
                "clusters": [], "inputRevision": "fixture", "status": "pending"]
            if index == 1 {
                note["generated"] = ["id": "generated-\(day)", "version": 1, "schemaVersion": 1,
                    "generatedAt": day + "T09:00:00Z", "inputRevision": "fixture", "actionIDs": ids,
                    "status": "generated_unverified", "generator": "fixture", "generatorVersion": "1",
                    "output": ["requestID": "fixture", "title": "Synthetic multiline note",
                        "bullets": (0..<10).map { ["text": String(repeating: "Synthetic bullet. ", count: $0 % 4 + 1), "actionIDs": ids, "assertion": "observed"] }]]
            }
            return note
        }
        let value: [String: Any] = [
            "summary": ["day": day, "timezone": "UTC", "start": day + "T00:00:00Z", "end": day + "T23:59:59Z",
                        "activityIDs": notes.map { $0["id"] as! String }, "actionCount": 597,
                        "countIsComplete": true, "inputRevision": "fixture", "status": "pending"],
            "activities": notes, "actions": ["actions": records, "revision": "fixture",
                "snapshot": ["epoch": "fixture", "highWater": 597], "candidates": 597],
            "defaultLayer": "activity_notes", "partial": false]
        return try JSONDecoder().decode(ActionDay.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
