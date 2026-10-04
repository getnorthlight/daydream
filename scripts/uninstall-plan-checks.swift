// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// Checks Settings › Setup › Uninstall DayDream (Sources/MemoryCore/Uninstall.swift, docs/uninstall.md).
// Synthetic only: every home folder and "/Applications" is a fresh scratch folder under TMPDIR.
// Apps are fake bundles (a folder with an Info.plist). "Trash" is a scratch folder too, so
// nothing reaches the real Trash. No app launch, no real user data, no Keychain, no launchctl.
import Foundation
import Darwin
@testable import MemoryCore

@main struct UninstallPlanChecks {
    static var count = 0
    static func check(_ value: Bool, _ name: String) { precondition(value, "FAIL " + name); count += 1; print("PASS " + name) }
    static let fm = FileManager.default

    // MARK: scratch tree

    static func write(_ url: URL, _ text: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    static func app(_ url: URL, id: String, extra: [String: Any] = [:]) throws {
        var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": "DayDream"]
        info.merge(extra) { $1 }
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        try write(url.appendingPathComponent("Contents/MacOS/MacMem"), "binary")
    }
    static func link(_ at: URL, to target: URL) throws {
        try fm.createDirectory(at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: at, withDestinationURL: target)
    }

    /// Every path under `root` (not following links), with the file contents or the link target.
    static func snapshot(_ root: URL) -> [String: String] {
        var result: [String: String] = [:]
        func walk(_ url: URL) {
            let path = url.path
            var info = stat()
            guard lstat(path, &info) == 0 else { return }
            let rel = String(path.dropFirst(root.path.count))
            switch info.st_mode & S_IFMT {
            case S_IFLNK: result[rel] = "link:" + ((try? fm.destinationOfSymbolicLink(atPath: path)) ?? "?")
            case S_IFREG: result[rel] = "file:" + ((try? String(contentsOf: url, encoding: .utf8)) ?? "?")
            case S_IFDIR:
                result[rel] = "dir"
                for name in ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted() { walk(url.appendingPathComponent(name)) }
            default: result[rel] = "other"
            }
        }
        walk(root)
        return result
    }

    struct World {
        let root: URL, home: URL, system: URL, trash: URL, outside: URL
        var locations: UninstallLocations { UninstallLocations(home: home, systemApplications: system) }
        var support: URL { home.appendingPathComponent("Library/Application Support") }
        var running: URL { system.appendingPathComponent("DayDream.app") }
        func requester(_ bundle: URL? = nil, id: String? = DaydreamIdentity.bundleID, info: [String: Any] = [:], env: String? = nil) -> UninstallRequester {
            UninstallRequester(bundleURL: bundle ?? running, bundleID: id, info: info, environmentHome: env)
        }
    }

    /// A home folder with both names present, plus decoys that must never be touched.
    static func world(_ parent: URL, _ name: String) throws -> World {
        let root = parent.appendingPathComponent(name, isDirectory: true)
        let w = World(root: root, home: root.appendingPathComponent("home"), system: root.appendingPathComponent("Applications"),
                      trash: root.appendingPathComponent("Trash"), outside: root.appendingPathComponent("outside"))
        try fm.createDirectory(at: w.trash, withIntermediateDirectories: true)
        // The running app, in "/Applications", and an older copy (old name, old ID) in ~/Applications.
        try app(w.running, id: DaydreamIdentity.bundleID)
        try app(w.home.appendingPathComponent("Applications/Daydream.app"), id: DaydreamIdentity.legacyBundleID)
        // Decoys next to them.
        try app(w.system.appendingPathComponent("DayDream Helper.app"), id: "com.example.helper")
        try app(w.system.appendingPathComponent("Mac Mem.app"), id: DaydreamIdentity.legacyBundleID)
        try app(w.system.appendingPathComponent("Notes.app"), id: "com.apple.Notes")
        // History under both names, a folder the rename move left, and look-alikes.
        try write(w.support.appendingPathComponent("DayDream/memory.sqlite"), "new history")
        try write(w.support.appendingPathComponent("DayDream/Models/model.gguf"), "model")
        try write(w.support.appendingPathComponent("Mac Mem/memory.sqlite"), "old history")
        try write(w.support.appendingPathComponent("Mac Mem/capture.lock"), "")
        try write(w.support.appendingPathComponent("DayDream.before-move-1790000000/notes.txt"), "set aside")
        try write(w.support.appendingPathComponent("DayDream.before-move-abc/keep.txt"), "not DayDream's pattern")
        try write(w.support.appendingPathComponent("DayDream.before-move-/keep.txt"), "empty digits")
        try write(w.support.appendingPathComponent("DayDream Backup/keep.txt"), "a backup folder the person named")
        try write(w.support.appendingPathComponent("Mac Mem 2/keep.txt"), "look-alike")
        try write(w.support.appendingPathComponent("Another App/data.db"), "another app")
        // Settings of both IDs and the helpers; others stay.
        for domain in UninstallLocations.preferenceDomains.prefix(3) { try write(w.home.appendingPathComponent("Library/Preferences/\(domain).plist"), domain) }
        try write(w.home.appendingPathComponent("Library/Preferences/com.getnorthlight.daydream.development.plist"), "dev app settings")
        try write(w.home.appendingPathComponent("Library/Preferences/com.apple.finder.plist"), "finder")
        // Login items, caches.
        try write(w.home.appendingPathComponent("Library/LaunchAgents/com.getnorthlight.daydream.plist"), "agent")
        try write(w.home.appendingPathComponent("Library/LaunchAgents/com.macmem.app.plist"), "old agent")
        try write(w.home.appendingPathComponent("Library/LaunchAgents/com.example.agent.plist"), "someone else's agent")
        try write(w.home.appendingPathComponent("Library/Caches/com.getnorthlight.daydream/org.sparkle-project.Sparkle/update.zip"), "update")
        try write(w.home.appendingPathComponent("Library/Caches/com.macmem.app/cache.db"), "cache")
        try write(w.home.appendingPathComponent("Library/Caches/com.example.other/cache.db"), "other cache")
        try write(w.home.appendingPathComponent("Library/HTTPStorages/com.getnorthlight.daydream.binarycookies"), "cookies")
        try write(w.home.appendingPathComponent("Library/Saved Application State/com.getnorthlight.daydream.savedState/window.data"), "state")
        try write(w.home.appendingPathComponent("Documents/DayDream Backup/manifest.json"), "backup the person saved")
        try write(w.outside.appendingPathComponent("precious.txt"), "never touched")
        return w
    }

    /// Operations that record every call; "Trash" is a scratch folder.
    final class Recorder {
        var calls: [String] = []
        var failTrash: Set<String> = []
        func operations(_ w: World) -> UninstallOperations {
            UninstallOperations(trash: { url in
                self.calls.append("trash " + url.path)
                if self.failTrash.contains(url.path) { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: url, to: w.trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
            }, delete: { url in
                self.calls.append("delete " + url.path)
                try FileManager.default.removeItem(at: url)
            })
        }
    }

    static func makePlan(_ choice: UninstallChoice, _ w: World, _ requester: UninstallRequester? = nil) -> UninstallPlan? {
        if case .success(let plan) = UninstallPlanner.plan(choice, requester: requester ?? w.requester(), locations: w.locations, probe: .live) { return plan }
        return nil
    }
    static func refusal(_ choice: UninstallChoice, _ w: World, _ requester: UninstallRequester) -> String? {
        if case .failure(let refusal) = UninstallPlanner.plan(choice, requester: requester, locations: w.locations, probe: .live) { return refusal.message }
        return nil
    }
    static func rel(_ w: World, _ url: URL) -> String { String(url.standardizedFileURL.path.dropFirst(w.root.path.count)) }
    /// The snapshot keys a removal of `paths` takes away: each path and everything under it.
    static func under(_ before: [String: String], _ paths: [String]) -> Set<String> {
        Set(before.keys.filter { key in paths.contains { key == $0 || key.hasPrefix($0 + "/") } })
    }

    static func main() throws {
        // TMPDIR (the suite points it at its own work folder); FileManager.temporaryDirectory ignores it.
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? fm.temporaryDirectory
        let scratch = tmp.appendingPathComponent("uninstall-plan-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }
        // The real path (for example /private/var rather than /var), so the scratch folder itself has no links.
        guard let real = realpath(scratch.path, nil) else { check(false, "scratch folder resolves"); return }
        let root = URL(fileURLWithPath: String(cString: real), isDirectory: true).standardizedFileURL
        free(real)
        check(UninstallProbe.live.noLinks(root), "the scratch folder has no links in its path")

        // 1. The fixed list.
        do {
            let w = try world(root, "list")
            let allowed = w.locations.allowedPaths
            check(Set(allowed).count == allowed.count, "allowed list has no duplicates")
            check(allowed.allSatisfy { $0.hasPrefix(w.home.path + "/Library/") || $0.hasPrefix(w.home.path + "/Applications/") || $0.hasPrefix(w.system.path + "/") },
                  "every allowed path is in Applications or the home Library")
            check(allowed.filter { $0.hasSuffix("/DayDream.app") || $0.hasSuffix("/Daydream.app") }.count == 4 && w.locations.appCandidates.count == 4, "apps: DayDream.app and Daydream.app, in /Applications and ~/Applications")
            check(allowed.contains(w.support.appendingPathComponent("DayDream").path) && allowed.contains(w.support.appendingPathComponent("Mac Mem").path),
                  "history folders under both names are on the list")
            for id in [DaydreamIdentity.bundleID, DaydreamIdentity.legacyBundleID] {
                check(allowed.contains(w.home.appendingPathComponent("Library/Preferences/\(id).plist").path), "preferences of \(id) are on the list")
            }
            for bad in [w.home, w.support, w.home.appendingPathComponent("Library"), w.system, w.support.appendingPathComponent("DayDream Backup"),
                        w.support.appendingPathComponent("DayDream.before-move-"), w.support.appendingPathComponent("DayDream.before-move-12x"),
                        w.support.appendingPathComponent("DayDream/../Google"), w.support.appendingPathComponent("DayDream/memory.sqlite"),
                        w.home.appendingPathComponent("Library/Preferences/com.getnorthlight.daydream.development.plist"),
                        w.home.appendingPathComponent("Library/LaunchAgents/com.example.agent.plist"),
                        w.system.appendingPathComponent("Mac Mem.app"), URL(fileURLWithPath: "/Applications/DayDream.app"), URL(fileURLWithPath: "/")] {
                check(!w.locations.isAllowed(bad), "not on the list: \(rel(w, bad))")
            }
            check(w.locations.isAllowed(w.support.appendingPathComponent("DayDream.before-move-1790000000")), "a folder the rename move left is on the list")
            check(UninstallLocations.live().appCandidates.map(\.path).contains("/Applications/DayDream.app"), "the live list uses /Applications")
        }

        // 2. Keep my history: a synthetic plan over a scratch home with both names present.
        do {
            let w = try world(root, "keep")
            let before = snapshot(w.root)
            guard let plan = makePlan(.keepHistory, w) else { check(false, "keep: plan made"); return }
            let removed = plan.items.map { rel(w, $0.url) }
            check(plan.items.first?.kind == .runningApp && plan.items.first?.removal == .trash, "keep: the running app is first, moved to the Trash")
            check(plan.items.filter { $0.kind == .runningApp || $0.kind == .otherApp }.count == 2, "keep: one item per app on disk (DayDream.app and Daydream.app are one folder here)")
            check(removed.contains("/home/Applications/Daydream.app"), "keep: the older copy (old name, old ID) goes too")
            check(Set(plan.items.filter { $0.kind == .loginItem }.map { $0.url.lastPathComponent }) == ["com.getnorthlight.daydream.plist", "com.macmem.app.plist"], "keep: both login agents")
            check(plan.items.filter { $0.kind == .appCache }.count == 4, "keep: caches of both IDs that exist")
            check(!plan.items.contains { [.history, .legacyHistory, .leftoverHistory, .preferences].contains($0.kind) }, "keep: no history and no settings in the plan")
            check(plan.kept.map(\.lastPathComponent) == ["DayDream", "Mac Mem"], "keep: both history folders are listed as kept")
            check(plan.preferenceDomains.isEmpty, "keep: no preference domain is cleared")
            let recorder = Recorder()
            let report = UninstallRunner.run(plan, locations: w.locations, probe: .live, operations: recorder.operations(w))
            check(report.finished && report.failed.isEmpty && report.removed.count == plan.items.count, "keep: every item removed")
            check(recorder.calls.allSatisfy { w.locations.isAllowed(URL(fileURLWithPath: String($0.split(separator: " ", maxSplits: 1)[1]))) }, "keep: every call was on the list")
            var after = snapshot(w.root)
            after = after.filter { !$0.key.hasPrefix("/Trash/") }
            let gone = Set(before.keys).subtracting(after.keys)
            check(gone == under(before, removed), "keep: exactly the planned paths are gone")
            check(after.allSatisfy { before[$0.key] == $0.value }, "keep: nothing else changed, byte for byte")
            check(after["/home/Library/Application Support/DayDream/memory.sqlite"] == "file:new history" && after["/home/Library/Application Support/Mac Mem/memory.sqlite"] == "file:old history", "keep: both histories are still there")
            check(after["/home/Library/Preferences/com.getnorthlight.daydream.plist"] != nil, "keep: settings are still there")
            check(((try? fm.contentsOfDirectory(atPath: w.trash.path)) ?? []).count == 2, "keep: the two apps are in the Trash, not deleted")
        }

        // 3. Remove everything.
        do {
            let w = try world(root, "everything")
            let before = snapshot(w.root)
            guard let plan = makePlan(.removeEverything, w) else { check(false, "everything: plan made"); return }
            let removed = plan.items.map { rel(w, $0.url) }
            for path in ["/home/Library/Application Support/DayDream", "/home/Library/Application Support/Mac Mem",
                         "/home/Library/Application Support/DayDream.before-move-1790000000",
                         "/home/Library/Preferences/com.getnorthlight.daydream.plist", "/home/Library/Preferences/com.macmem.app.plist",
                         "/home/Library/Preferences/com.getnorthlight.daydream.mac-mem.plist"] {
                check(removed.contains(path), "everything: plans \(path)")
            }
            check(plan.items.filter { $0.kind == .history || $0.kind == .legacyHistory }.count == 2, "everything: DayDream and Mac Mem once each (Daydream is the same folder here)")
            check(plan.preferenceDomains == [DaydreamIdentity.bundleID, DaydreamIdentity.legacyBundleID], "everything: both preference domains are cleared")
            check(plan.kept.isEmpty, "everything: nothing listed as kept")
            let recorder = Recorder()
            let report = UninstallRunner.run(plan, locations: w.locations, probe: .live, operations: recorder.operations(w))
            check(report.finished && report.failed.isEmpty, "everything: every item removed")
            check(recorder.calls.first == "trash " + w.running.path, "everything: the running app is removed first")
            check(recorder.calls.filter { $0.hasPrefix("trash ") }.count == 2, "everything: only the apps go to the Trash; the rest is deleted")
            let after = snapshot(w.root).filter { !$0.key.hasPrefix("/Trash/") }
            check(Set(before.keys).subtracting(after.keys) == under(before, removed), "everything: exactly the planned paths are gone")
            check(after.allSatisfy { before[$0.key] == $0.value }, "everything: nothing else changed, byte for byte")
            for kept in ["/home/Library/Application Support/DayDream Backup/keep.txt", "/home/Library/Application Support/DayDream.before-move-abc/keep.txt",
                         "/home/Library/Application Support/DayDream.before-move-/keep.txt", "/home/Library/Application Support/Mac Mem 2/keep.txt",
                         "/home/Library/Application Support/Another App/data.db", "/home/Documents/DayDream Backup/manifest.json",
                         "/home/Library/Preferences/com.getnorthlight.daydream.development.plist", "/home/Library/Preferences/com.apple.finder.plist",
                         "/home/Library/LaunchAgents/com.example.agent.plist", "/home/Library/Caches/com.example.other/cache.db",
                         "/Applications/DayDream Helper.app/Contents/Info.plist", "/Applications/Mac Mem.app/Contents/Info.plist",
                         "/Applications/Notes.app/Contents/Info.plist", "/outside/precious.txt"] {
                check(after[kept] != nil, "everything: left alone \(kept)")
            }
            // Running it twice finds nothing new to do.
            let again = plan.items.filter { $0.kind != .runningApp }
            check(again.allSatisfy { UninstallRunner.recheck($0, locations: w.locations, probe: .live, sameInode: true) == UninstallRunner.gone }, "everything: a second pass finds everything gone")
        }

        // 4. The button refuses other apps, symlinks and development bundles. Nothing is touched.
        do {
            let w = try world(root, "refuse")
            // Fixtures first, then the snapshot, then every refusal.
            let dev = w.root.appendingPathComponent("repo/.build/DayDream.app")
            try app(dev, id: DaydreamIdentity.bundleID)
            let devHome = w.root.appendingPathComponent("devhome")
            try app(devHome.appendingPathComponent("Applications/DayDream.app"), id: DaydreamIdentity.bundleID, extra: ["DaydreamDevelopmentTrial": true])
            let real = w.outside.appendingPathComponent("Real/DayDream.app")
            try app(real, id: DaydreamIdentity.bundleID)
            let linkHome = w.root.appendingPathComponent("linkhome")
            try link(linkHome.appendingPathComponent("Applications/DayDream.app"), to: real)
            let linkedApps = w.root.appendingPathComponent("linkapps")
            try app(w.outside.appendingPathComponent("Apps/DayDream.app"), id: DaydreamIdentity.bundleID)
            try link(linkedApps.appendingPathComponent("Applications"), to: w.outside.appendingPathComponent("Apps"))
            let broken = w.root.appendingPathComponent("broken")
            try fm.createDirectory(at: broken.appendingPathComponent("Applications/DayDream.app/Contents"), withIntermediateDirectories: true)
            let other = w.root.appendingPathComponent("other")
            try app(other.appendingPathComponent("Applications/DayDream.app"), id: "com.example.impostor")
            let plistLink = w.root.appendingPathComponent("plistlink")
            try fm.createDirectory(at: plistLink.appendingPathComponent("Applications/DayDream.app/Contents"), withIntermediateDirectories: true)
            try link(plistLink.appendingPathComponent("Applications/DayDream.app/Contents/Info.plist"), to: w.running.appendingPathComponent("Contents/Info.plist"))
            func homeWorld(_ home: URL) -> World { World(root: w.root, home: home, system: w.root.appendingPathComponent("no-apps"), trash: w.trash, outside: w.outside) }
            let before = snapshot(w.root)

            check(refusal(.removeEverything, w, w.requester(id: "com.example.other")) != nil, "refuses: another app's ID")
            check(refusal(.removeEverything, w, w.requester(id: DaydreamIdentity.legacyBundleID)) != nil, "refuses: the old app ID asking")
            check(refusal(.removeEverything, w, w.requester(id: nil)) != nil, "refuses: no app ID")
            check(refusal(.removeEverything, w, w.requester(id: "com.getnorthlight.daydream.development")) != nil, "refuses: the development app ID")
            check(refusal(.removeEverything, w, w.requester(env: "/tmp/custom")) != nil, "refuses: a custom history folder (MAC_MEM_HOME)")
            check(refusal(.removeEverything, w, w.requester(info: ["DaydreamDevelopmentTrial": true])) != nil, "refuses: a development trial")
            check(refusal(.removeEverything, w, w.requester(info: ["DaydreamRecordingTrial": true])) != nil, "refuses: a recording trial")
            check(refusal(.removeEverything, w, w.requester(info: ["DaydreamFunctionalTrial": "YES"])) != nil, "refuses: a functional trial")
            check(refusal(.removeEverything, w, w.requester(dev)) != nil, "refuses: a development bundle outside Applications")
            let devWorld = homeWorld(devHome)
            check(refusal(.removeEverything, devWorld, devWorld.requester(devHome.appendingPathComponent("Applications/DayDream.app"))) != nil,
                  "refuses: a development bundle in ~/Applications (its Info.plist says so)")
            let linked = homeWorld(linkHome)
            check(refusal(.keepHistory, linked, linked.requester(linkHome.appendingPathComponent("Applications/DayDream.app"))) != nil, "refuses: opened through a symlinked app")
            check(refusal(.keepHistory, linked, linked.requester(real)) != nil, "refuses: the target of a symlinked app")
            let viaFolder = homeWorld(linkedApps)
            check(refusal(.keepHistory, viaFolder, viaFolder.requester(linkedApps.appendingPathComponent("Applications/DayDream.app"))) != nil, "refuses: an Applications folder that is a link")
            check(refusal(.keepHistory, viaFolder, viaFolder.requester(w.outside.appendingPathComponent("Apps/DayDream.app"))) != nil, "refuses: the folder that link points to")
            let brokenWorld = homeWorld(broken)
            check(refusal(.keepHistory, brokenWorld, brokenWorld.requester(broken.appendingPathComponent("Applications/DayDream.app"))) != nil, "refuses: an app with no Info.plist")
            let otherWorld = homeWorld(other)
            check(refusal(.keepHistory, otherWorld, otherWorld.requester(other.appendingPathComponent("Applications/DayDream.app"))) != nil, "refuses: an app in Applications with another ID on disk")
            let plistWorld = homeWorld(plistLink)
            check(refusal(.keepHistory, plistWorld, plistWorld.requester(plistLink.appendingPathComponent("Applications/DayDream.app"))) != nil, "refuses: an Info.plist that is a link")
            check(refusal(.keepHistory, w, w.requester(w.home)) != nil, "refuses: the home folder as the app")
            check(refusal(.keepHistory, w, w.requester(w.system)) != nil, "refuses: the Applications folder as the app")
            check(refusal(.keepHistory, w, w.requester(w.system.appendingPathComponent("Mac Mem.app"))) != nil, "refuses: another app in Applications")
            check(refusal(.keepHistory, w, w.requester()) == nil, "the same world without those problems is accepted")
            check(snapshot(w.root) == before, "refusals touched nothing")
        }

        // 5. Links, other apps and development copies next to a real install are left in place.
        do {
            let w = try world(root, "skips")
            try fm.removeItem(at: w.home.appendingPathComponent("Applications/Daydream.app"))
            try link(w.home.appendingPathComponent("Applications/Daydream.app"), to: w.outside.appendingPathComponent("LinkedApp.app"))
            try app(w.outside.appendingPathComponent("LinkedApp.app"), id: DaydreamIdentity.bundleID)
            try fm.removeItem(at: w.support.appendingPathComponent("Mac Mem"))
            try write(w.outside.appendingPathComponent("Mac Mem target/memory.sqlite"), "somewhere else")
            try link(w.support.appendingPathComponent("Mac Mem"), to: w.outside.appendingPathComponent("Mac Mem target"))
            try fm.removeItem(at: w.home.appendingPathComponent("Library/Preferences/com.macmem.app.plist"))
            try link(w.home.appendingPathComponent("Library/Preferences/com.macmem.app.plist"), to: w.outside.appendingPathComponent("precious.txt"))
            try fm.removeItem(at: w.home.appendingPathComponent("Library/Caches/com.macmem.app"))
            try link(w.home.appendingPathComponent("Library/Caches/com.macmem.app"), to: w.outside)
            try fm.removeItem(at: w.home.appendingPathComponent("Library/LaunchAgents/com.macmem.app.plist"))
            try fm.createDirectory(at: w.home.appendingPathComponent("Library/LaunchAgents/com.macmem.app.plist"), withIntermediateDirectories: false)
            guard let plan = makePlan(.removeEverything, w) else { check(false, "skips: plan made"); return }
            let planned = Set(plan.items.map { rel(w, $0.url) })
            let skipped = Set(plan.skipped.map { rel(w, $0.url) })
            for path in ["/home/Applications/Daydream.app", "/home/Library/Application Support/Mac Mem", "/home/Library/Preferences/com.macmem.app.plist",
                         "/home/Library/Caches/com.macmem.app", "/home/Library/LaunchAgents/com.macmem.app.plist"] {
                check(!planned.contains(path) && skipped.contains(path), "skips: left in place, with a reason: \(path)")
            }
            let before = snapshot(w.root)
            let report = UninstallRunner.run(plan, locations: w.locations, probe: .live, operations: Recorder().operations(w))
            check(report.finished && report.failed.isEmpty, "skips: the rest is removed")
            let after = snapshot(w.root)
            check(after["/outside/LinkedApp.app/Contents/Info.plist"] != nil && after["/outside/Mac Mem target/memory.sqlite"] == "file:somewhere else"
                  && after["/outside/precious.txt"] == "file:never touched", "skips: nothing a link points to was touched")
            check(after["/home/Library/Application Support/Mac Mem"] == before["/home/Library/Application Support/Mac Mem"], "skips: the linked Mac Mem folder is still a link")

            // Another app and a development copy under DayDream's name in ~/Applications.
            let w2 = try world(root, "skips2")
            try fm.removeItem(at: w2.home.appendingPathComponent("Applications/Daydream.app"))
            try app(w2.home.appendingPathComponent("Applications/Daydream.app"), id: "com.example.daydream-clone")
            guard let plan2 = makePlan(.keepHistory, w2) else { check(false, "skips: second plan made"); return }
            check(plan2.skipped.contains { $0.url.lastPathComponent == "Daydream.app" } && !plan2.items.contains { $0.kind == .otherApp },
                  "skips: another app named Daydream.app is left in place")
            let w3 = try world(root, "skips3")
            try fm.removeItem(at: w3.home.appendingPathComponent("Applications/Daydream.app"))
            try app(w3.home.appendingPathComponent("Applications/Daydream.app"), id: DaydreamIdentity.bundleID, extra: ["DaydreamDevelopmentTrial": true])
            guard let plan3 = makePlan(.keepHistory, w3) else { check(false, "skips: third plan made"); return }
            check(plan3.skipped.contains { $0.url.lastPathComponent == "Daydream.app" } && !plan3.items.contains { $0.kind == .otherApp },
                  "skips: a development copy in ~/Applications is left in place")
        }

        // 6. Checked again just before removal.
        do {
            let w = try world(root, "recheck")
            guard let plan = makePlan(.removeEverything, w) else { check(false, "recheck: plan made"); return }
            // After the plan: the history folder becomes a link, and the old one is replaced by a new folder.
            try fm.moveItem(at: w.support.appendingPathComponent("DayDream"), to: w.outside.appendingPathComponent("moved DayDream"))
            try link(w.support.appendingPathComponent("DayDream"), to: w.outside.appendingPathComponent("moved DayDream"))
            try fm.moveItem(at: w.support.appendingPathComponent("Mac Mem"), to: w.outside.appendingPathComponent("moved Mac Mem"))
            try write(w.support.appendingPathComponent("Mac Mem/new.txt"), "new folder, same name")
            let recorder = Recorder()
            let report = UninstallRunner.run(plan, locations: w.locations, probe: .live, operations: recorder.operations(w))
            let failed = Set(report.failed.map { $0.item.url.lastPathComponent })
            check(failed == ["DayDream", "Mac Mem"], "recheck: a folder that became a link or was replaced is not removed")
            check(!recorder.calls.contains { $0.hasSuffix("/DayDream") || $0.hasSuffix("/Mac Mem") }, "recheck: no removal was even tried for them")
            check(fm.fileExists(atPath: w.outside.appendingPathComponent("moved DayDream/memory.sqlite").path)
                  && fm.fileExists(atPath: w.support.appendingPathComponent("Mac Mem/new.txt").path), "recheck: their contents are intact")
            // A forged item outside the list is refused by the runner too.
            let forged = UninstallItem(kind: .history, url: w.outside, removal: .delete, entry: UninstallProbe.live.entry(w.outside.path)!)
            let forgedPlan = UninstallPlan(choice: .removeEverything, items: [plan.items[0], forged], skipped: [], kept: [], preferenceDomains: [])
            let forgedRecorder = Recorder()
            let forgedReport = UninstallRunner.run(forgedPlan, locations: w.locations, probe: .live, operations: forgedRecorder.operations(w))
            check(forgedReport.failed.map(\.item.url) == [w.outside] && !forgedRecorder.calls.contains("delete " + w.outside.path)
                  && fm.fileExists(atPath: w.outside.appendingPathComponent("precious.txt").path), "recheck: a path outside the list is never removed")
        }

        // 7. If the app can't move itself to the Trash, nothing else is touched.
        do {
            let w = try world(root, "stuck")
            let before = snapshot(w.root)
            guard let plan = makePlan(.removeEverything, w) else { check(false, "stuck: plan made"); return }
            let recorder = Recorder()
            recorder.failTrash = [w.running.path]
            let report = UninstallRunner.run(plan, locations: w.locations, probe: .live, operations: recorder.operations(w))
            check(!report.finished && report.stopped?.contains("weren't touched") == true, "stuck: stops with a plain reason")
            check(recorder.calls == ["trash " + w.running.path], "stuck: only the app itself was tried")
            check(snapshot(w.root) == before, "stuck: nothing changed")
        }

        // 8. The last pass as DayDream quits removes what came back, and nothing else.
        do {
            let w = try world(root, "sweep")
            guard let plan = makePlan(.removeEverything, w) else { check(false, "sweep: plan made"); return }
            _ = UninstallRunner.run(plan, locations: w.locations, probe: .live, operations: Recorder().operations(w))
            try write(w.support.appendingPathComponent("DayDream/capture-state.json"), "written on quit")
            try write(w.home.appendingPathComponent("Library/Preferences/com.getnorthlight.daydream.plist"), "written on quit")
            try write(w.home.appendingPathComponent("Library/LaunchAgents/com.getnorthlight.daydream.plist"), "not DayDream's to sweep")
            try app(w.running, id: DaydreamIdentity.bundleID) // a new copy installed meanwhile
            try link(w.support.appendingPathComponent("Mac Mem"), to: w.outside)
            var deleted: [String] = []
            let swept = UninstallRunner.sweep(plan, locations: w.locations, probe: .live, delete: { deleted.append($0.path); try FileManager.default.removeItem(at: $0) })
            check(Set(swept.map { rel(w, $0) }) == ["/home/Library/Application Support/DayDream", "/home/Library/Preferences/com.getnorthlight.daydream.plist"],
                  "sweep: removes the history folder and settings written back on quit")
            check(fm.fileExists(atPath: w.running.path), "sweep: never touches an app")
            check(fm.fileExists(atPath: w.home.appendingPathComponent("Library/LaunchAgents/com.getnorthlight.daydream.plist").path), "sweep: leaves login items to the first pass")
            check(fm.fileExists(atPath: w.outside.appendingPathComponent("precious.txt").path) && !deleted.contains(w.support.appendingPathComponent("Mac Mem").path),
                  "sweep: a link that appeared is not followed or removed")
            let keep = try world(root, "sweep-keep")
            guard let keepPlan = makePlan(.keepHistory, keep) else { check(false, "sweep: keep plan made"); return }
            _ = UninstallRunner.run(keepPlan, locations: keep.locations, probe: .live, operations: Recorder().operations(keep))
            let keptSwept = UninstallRunner.sweep(keepPlan, locations: keep.locations, probe: .live, delete: { try FileManager.default.removeItem(at: $0) })
            check(keptSwept.allSatisfy { !$0.path.contains("Application Support") && !$0.path.contains("Preferences") }
                  && fm.fileExists(atPath: keep.support.appendingPathComponent("DayDream/memory.sqlite").path), "sweep: Keep my history never sweeps history or settings")
        }

        // 9. The order Setup follows: refuse while busy, pause, plan again, remove.
        do {
            final class Fake: UninstallPerforming {
                var log: [String] = []
                var busy: String?
                var result: Result<UninstallPlan, UninstallRefusal>
                var report = UninstallReport()
                init(_ result: Result<UninstallPlan, UninstallRefusal>) { self.result = result }
                func blocker() -> String? { log.append("blocker"); return busy }
                func preview(_ choice: UninstallChoice) -> Result<UninstallPlan, UninstallRefusal> { log.append("preview " + choice.rawValue); return result }
                func perform(_ plan: UninstallPlan) -> UninstallReport { log.append("perform"); return report }
                func quit() { log.append("quit") }
            }
            let w = try world(root, "session")
            guard let plan = makePlan(.keepHistory, w) else { check(false, "session: plan made"); return }
            MainActor.assumeIsolated {
                var paused = 0
                let fake = Fake(.success(plan))
                let outcome = UninstallSession.run(.keepHistory, canUninstall: { true }, pause: { fake.log.append("pause"); paused += 1 }, performer: fake)
                check(fake.log == ["blocker", "pause", "preview keepHistory", "perform"], "session: blocker, then pause, then a fresh plan, then removal")
                check(outcome == .done(plan, UninstallReport()), "session: done with the plan and report")
                let replacing = Fake(.success(plan))
                if case .refused = UninstallSession.run(.removeEverything, canUninstall: { false }, pause: { replacing.log.append("pause") }, performer: replacing) {
                    check(replacing.log.isEmpty, "session: refuses during a replacement, before pausing or planning")
                } else { check(false, "session: refuses during a replacement") }
                let backingUp = Fake(.success(plan)); backingUp.busy = "A backup or restore is in progress."
                if case .refused(let message) = UninstallSession.run(.removeEverything, canUninstall: { true }, pause: { backingUp.log.append("pause") }, performer: backingUp) {
                    check(backingUp.log == ["blocker"] && message == backingUp.busy, "session: refuses during a backup, before pausing")
                } else { check(false, "session: refuses during a backup") }
                let refusing = Fake(.failure(UninstallRefusal("dev")))
                check(UninstallSession.run(.keepHistory, canUninstall: { true }, pause: { refusing.log.append("pause") }, performer: refusing) == .refused("dev")
                      && !refusing.log.contains("perform"), "session: a refused plan removes nothing")
                let stuck = Fake(.success(plan)); stuck.report.stopped = "stuck"
                check(UninstallSession.run(.keepHistory, canUninstall: { true }, pause: {}, performer: stuck) == .refused("stuck"), "session: an app that can't move itself reports it")
                check(paused == 1 && !fake.log.contains("quit"), "session: pauses once and never quits by itself")
            }
        }

        // 10. The steps an app can't do for itself.
        do {
            let steps = UninstallSteps.text(choice: .removeEverything)
            for id in [DaydreamIdentity.bundleID, DaydreamIdentity.legacyBundleID] {
                for service in ["Accessibility", "ListenEvent", "AppleEvents"] {
                    check(steps.contains("tccutil reset \(service) \(id)"), "steps: tccutil reset \(service) \(id)")
                }
            }
            check(steps.contains("security delete-generic-password -s DayDream.Writer.OpenRouter -a owner")
                  && steps.contains("security delete-generic-password -s MacMem.Writer.OpenRouter -a owner"), "steps: both Keychain items")
            let keychain = (try? String(contentsOfFile: "WriterBackend/Sources/WriterBackend/CloudTransport.swift", encoding: .utf8)) ?? ""
            check(keychain.contains("service = \"\(UninstallSteps.keychainServices[0])\"") && keychain.contains("legacyService = \"\(UninstallSteps.keychainServices[1])\""),
                  "steps: the Keychain services match the app's (WriterKeychain)")
            check(steps.contains("docs/uninstall.md") && UninstallSteps.text(choice: .keepHistory).contains("still on this Mac"), "steps: point to docs/uninstall.md and say what stays")
            // Safe typing: the typing key is named in both choices. Remove everything says how to delete it;
            // Keep my history says the kept history needs it (and never tells anyone to delete it).
            let typingKeychain = (try? String(contentsOfFile: "Sources/MacMemApp/TypedTextKeychain.swift", encoding: .utf8)) ?? ""
            check(UninstallSteps.typingKeyService == "DayDream.TypedText" && typingKeychain.contains("static let service = TypedKeychainName.service")
                  && typingKeychain.contains("add[kSecAttrLabel] = TypedKeychainName.label"),
                  "steps: the typing key service matches the app's (KeychainTypedKeyStore)")
            let keep = UninstallSteps.text(choice: .keepHistory)
            check(steps.contains("3. Typing key.") && steps.contains(TypedKeychainName.label) && steps.contains(UninstallSteps.typingKeyCommand)
                  && steps.contains("Keychain Access"), "steps (removeEverything): the typing key and how to delete it")
            check(keep.contains("3. Typing key.") && keep.contains(UninstallSteps.typingKeyService) && keep.contains("Your kept history needs it")
                  && !keep.contains(UninstallSteps.typingKeyCommand), "steps (keepHistory): the typing key is named and kept")
            for choice in [UninstallChoice.removeEverything, .keepHistory] {
                let numbered = UninstallSteps.text(choice: choice).split(separator: "\n").compactMap { line in line.first.flatMap { $0.isNumber ? Int(String($0)) : nil } }
                check(numbered == Array(1...numbered.count), "steps (\(choice.rawValue)): numbered 1 to \(numbered.count) in order (\(numbered))")
            }
            // Connect and Disconnect keep a copy of each AI app's settings file; the steps name every one.
            check(UninstallSteps.aiAppBackups.count == AIAppConnect.apps.count && UninstallSteps.aiAppBackups.allSatisfy { $0.hasSuffix(".daydream-backup") }
                  && ["~/.claude.json.daydream-backup", "~/.cursor/mcp.json.daydream-backup"].allSatisfy(UninstallSteps.aiAppBackups.contains),
                  "steps: the AI app settings backups (\(UninstallSteps.aiAppBackups.joined(separator: ", ")))")
            for choice in [UninstallChoice.removeEverything, .keepHistory] {
                check(UninstallSteps.aiAppBackups.allSatisfy(UninstallSteps.text(choice: choice).contains), "steps (\(choice.rawValue)): every AI app settings backup is listed")
            }
        }
        // 10b. Remove everything deletes the typing key of every history it removes (safe typing): the ids are
        // read from real stores before anything is removed, a linked memory.sqlite is never followed, another
        // home's key stays, both Keychain places are cleared, and the steps say what happened. In-memory keys only.
        do {
            let w = try world(root, "typing-keys")
            for (folder, id) in [("DayDream", "store-new"), ("Mac Mem", "store-old")] {
                let url = w.support.appendingPathComponent(folder)
                try fm.removeItem(at: url.appendingPathComponent("memory.sqlite"))
                let store = try MemoryStore(home: url, writable: true, automaticallySyncSearch: false)
                try store.exec("INSERT OR REPLACE INTO metadata VALUES('core_store_id',?)", [id])
            }
            let outsideStore = w.outside.appendingPathComponent("store")
            do {
                let store = try MemoryStore(home: outsideStore, writable: true, automaticallySyncSearch: false)
                try store.exec("INSERT OR REPLACE INTO metadata VALUES('core_store_id',?)", ["outside-id"])
            }
            try link(w.support.appendingPathComponent("DayDream.before-move-1790000000/memory.sqlite"), to: outsideStore.appendingPathComponent("memory.sqlite"))
            guard case .success(let everything) = UninstallPlanner.plan(.removeEverything, requester: w.requester(), locations: w.locations, probe: .live),
                  case .success(let keep) = UninstallPlanner.plan(.keepHistory, requester: w.requester(), locations: w.locations, probe: .live) else {
                check(false, "typing keys: plans made"); throw CocoaError(.featureUnsupported)
            }
            check(UninstallTypingKeys.readStoreID(w.support.appendingPathComponent("Mac Mem")) == "store-old", "typing keys: a history's core_store_id is read read-only")
            let ids = UninstallTypingKeys.storeIDs(everything, current: "store-new", probe: .live, read: UninstallTypingKeys.readStoreID)
            check(ids == ["store-new", "store-old"], "typing keys: Remove everything takes the running store's and each removed history's key, never through a link (\(ids))")
            check(UninstallTypingKeys.storeIDs(keep, current: "store-new", probe: .live, read: UninstallTypingKeys.readStoreID).isEmpty,
                  "typing keys: Keep my history keeps every key")
            var keys: [String: InMemoryTypedKeyStore] = [:]
            for id in ["store-new", "store-old", "outside-id", "dev-home"] { keys[id] = InMemoryTypedKeyStore(item: Data(id.utf8)) }
            check(UninstallTypingKeys.delete(ids, keys: { keys[$0]! }) == .deleted && keys["store-new"]?.raw == nil && keys["store-old"]?.raw == nil
                  && keys["outside-id"]?.raw != nil && keys["dev-home"]?.raw != nil, "typing keys: only the removed histories' keys are deleted")
            let primary = InMemoryTypedKeyStore(item: Data("new".utf8)), legacy = InMemoryTypedKeyStore(item: Data("old".utf8))
            check(UninstallTypingKeys.delete(["a"], keys: { _ in MigratingTypedKeyStore(primary: primary, legacy: legacy) }) == .deleted
                  && primary.raw == nil && legacy.raw == nil, "typing keys: both the data-protection and the login keychain copy go")
            let noEntitlement = InMemoryTypedKeyStore(); noEntitlement.unsupported = true
            let login = InMemoryTypedKeyStore(item: Data("old".utf8))
            check(UninstallTypingKeys.delete(["a"], keys: { _ in MigratingTypedKeyStore(primary: noEntitlement, legacy: login) }) == .deleted && login.raw == nil,
                  "typing keys: a build without the data-protection keychain still deletes the login keychain copy")
            let locked = InMemoryTypedKeyStore(item: Data("k".utf8)); locked.locked = true
            check(UninstallTypingKeys.delete(["a"], keys: { _ in locked }) == .failed(TypedKeyStoreError.locked.description) && locked.raw != nil,
                  "typing keys: a key that can't be deleted is reported")
            // The steps say what happened, and never claim a key "opens nothing" while backups may hold a copy.
            let deleted = UninstallSteps.text(choice: .removeEverything, typingKey: .deleted)
            let failed = UninstallSteps.text(choice: .removeEverything, typingKey: .failed("The Keychain is locked"))
            check(deleted.contains("DayDream deleted it from this Mac's Keychain") && !deleted.contains(UninstallSteps.typingKeyCommand) && deleted.contains("Time Machine"),
                  "steps (removeEverything, key deleted): say it was deleted and a keychain backup may hold a copy")
            check(failed.contains("couldn't delete it (The Keychain is locked)") && failed.contains(UninstallSteps.typingKeyCommand) && failed.contains("Keychain Access"),
                  "steps (removeEverything, key not deleted): say why and how to delete it by hand")
            for choice in UninstallChoice.allCases {
                for result in [UninstallTypingKeyResult.notAttempted, .deleted, .failed("x")] {
                    let text = UninstallSteps.text(choice: choice, typingKey: result)
                    check(!text.contains("opens nothing"), "steps (\(choice.rawValue), \(result)): never say the key opens nothing")
                    let numbered = text.split(separator: "\n").compactMap { line in line.first.flatMap { $0.isNumber ? Int(String($0)) : nil } }
                    check(numbered == Array(1...numbered.count), "steps (\(choice.rawValue), \(result)): numbered in order")
                    // ux/declutter: the screen after uninstalling shows one plain line per numbered step (no Terminal
                    // commands); Copy Steps still copies `text`.
                    let plain = UninstallSteps.plain(choice: choice, typingKey: result)
                    check(plain.count == numbered.count, "plain steps (\(choice.rawValue), \(result)): one line per numbered step")
                    check(!plain.joined().contains("opens nothing") && !plain.contains { $0.contains("security delete") || $0.contains("rm ") },
                          "plain steps (\(choice.rawValue), \(result)): no Terminal commands, never say the key opens nothing")
                    check(plain.contains { $0.contains("Privacy & Security") } && plain.contains { $0.contains(UninstallSteps.keychainServices[0]) }
                          && plain.contains { $0.contains(AIAppConnect.backupSuffix) } && plain.contains { $0.contains("Login Items") },
                          "plain steps (\(choice.rawValue), \(result)): permissions, the cloud key, AI app settings copies and Login Items")
                    let key: String
                    switch (choice, result) {
                    case (.keepHistory, _): key = "keep the typing key"
                    case (.removeEverything, .deleted): key = "DayDream deleted the typing key. A Time Machine backup"
                    case (.removeEverything, .failed): key = "couldn't delete the typing key"
                    case (.removeEverything, .notAttempted): key = "delete the typing key"
                    }
                    check(plain.contains { $0.contains(key) }, "plain steps (\(choice.rawValue), \(result)): say what happened to the typing key")
                    check((choice == .removeEverything) == plain.contains { $0.contains("Time Machine may still hold copies of your history") },
                          "plain steps (\(choice.rawValue), \(result)): Remove everything says backups may still hold your history")
                }
            }
            func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
            let service = source("Sources/MacMemApp/UninstallService.swift")
            if let ids = service.range(of: "UninstallTypingKeys.storeIDs(plan"), let run = service.range(of: "UninstallRunner.run(plan"),
               let finished = service.range(of: "guard report.finished else { return report }"), let delete = service.range(of: "report.typingKey = UninstallTypingKeys.delete(typingKeyIDs, keys: {") {
                check(ids.lowerBound < run.lowerBound && finished.upperBound < delete.lowerBound && service.contains("if plan.removesHistory {"),
                      "service: reads the key ids before removing, deletes the keys only once the app is in the Trash (the app's key store: typing-wiring-source-checks.py)")
            } else { check(false, "service: Remove everything deletes the typing keys") }
            let keychain = source("Sources/MacMemApp/TypedTextKeychain.swift")
            let forUninstall = keychain.components(separatedBy: "static func forUninstall(_ storeID: String) -> MigratingTypedKeyStore {").dropFirst().first?
                .components(separatedBy: "\n    }").first ?? ""
            check(forUninstall.contains("primary: ") && forUninstall.contains("storeID: storeID, dataProtection: true)")
                  && forUninstall.contains("legacy: ") && forUninstall.contains("storeID: storeID, dataProtection: false)") && !forUninstall.contains("lastMade"),
                  "service: the uninstall key store covers both keychains and isn't the launch store")
            let setupView = source("Sources/MemoryUI/SetupView.swift")
            check(setupView.components(separatedBy: "UninstallSteps.plain(choice:plan.choice,typingKey:report.typingKey)").count == 2
                  && setupView.components(separatedBy: "UninstallSteps.text(choice:plan.choice,typingKey:report.typingKey)").count == 2,
                  "setup: the steps shown (plain) and copied (text) say what happened to the typing key")
            let docs = source("docs/uninstall.md")
            check(docs.contains("| Deleted, see [step 3](#what-no-app-can-do-for-you) |") && docs.contains("DayDream deleted the key from this Mac's Keychain")
                  && !docs.contains("opens nothing"), "docs/uninstall.md: Remove everything deletes the typing key; nothing claims it opens nothing")
        }
        // 12. "Daydream" on a case-sensitive disk is its own folder, and another app could own it. The fake probe
        // makes it a separate folder over the scratch home; the plan is only made, never run.
        do {
            for (name, inside, expected) in [("another app's folder", ["data.db"], false), ("an old DayDream history", ["memory.sqlite"], true),
                                             ("the rename move's marker", ["migrated-from-mac-mem.json"], true)] {
                let w = try world(root, "case-sensitive-" + String(name.filter(\.isLetter)))
                let old = w.locations.oldSpellingFolder
                let live = UninstallProbe.live
                let probe = UninstallProbe(entry: { path in
                    path == old.path ? UninstallEntry(kind: .directory, owner: live.uid, device: 1, inode: 999_999_999) : live.entry(path)
                }, infoPlist: live.infoPlist, contents: { url in
                    if url.path == old.path { return inside }
                    return url.path == w.locations.applicationSupport.path ? live.contents(url) + ["Daydream"] : live.contents(url)
                }, uid: live.uid)
                guard case .success(let plan) = UninstallPlanner.plan(.removeEverything, requester: w.requester(), locations: w.locations, probe: probe),
                      case .success(let keep) = UninstallPlanner.plan(.keepHistory, requester: w.requester(), locations: w.locations, probe: probe) else {
                    check(false, "case-sensitive, \(name): plans made"); continue
                }
                let planned = plan.items.contains { $0.url.path == old.path && $0.kind == .legacyHistory }
                let skipped = plan.skipped.contains { $0.url.path == old.path && $0.reason.contains("doesn't hold a DayDream history") }
                check(planned == expected && skipped == !expected, "case-sensitive, \(name): Daydream is \(expected ? "removed" : "left in place with a reason")")
                check(keep.kept.contains(old) == expected, "case-sensitive, \(name): Keep my history \(expected ? "lists" : "doesn't list") Daydream as kept")
                check(plan.items.contains { $0.kind == .history && $0.url.lastPathComponent == "DayDream" }, "case-sensitive, \(name): the DayDream folder is still removed")
            }
        }
        // 11. The wiring, read from the sources (run from the repository root).
        do {
            func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
            let setup = source("Sources/MemoryUI/SetupView.swift")
            check(!setup.isEmpty && !setup.contains("Horizon") && !setup.contains("SSH"), "setup: no Horizon or SSH wording")
            for text in ["Keep my history", "Remove everything", "It can't be undone.", "UninstallSession.run(", "Copy Steps", "Quit DayDream",
                         "case .deferred(let reason) = legacyMove", "interactiveDismissDisabled"] {
                check(setup.contains(text), "setup: \(text)")
            }
            let settings = source("Sources/MacMemApp/DaydreamSettings.swift")
            // ux/declutter: Uninstall is on Advanced, which the developer preview also shows (the old Recording
            // requirements page was hidden there), so the preview gets no uninstaller.
            check(settings.contains("uninstaller: model.development == nil ? DaydreamUninstaller(model: model) : nil")
                  && settings.contains("legacyMove: DaydreamLaunchSession.legacyMove"),
                  "settings: Advanced gets the app's uninstaller (never in the developer preview) and the rename move's outcome")
            let service = source("Sources/MacMemApp/UninstallService.swift")
            for text in ["UninstallRunner.run(plan, locations: .live(), probe: .live, operations: .live)", "removePersistentDomain(forName: domain)",
                         "atexit {", "UninstallRunner.sweep(", "SMAppService.mainApp", "bootout(label:", "model.backups.busy", "model.replacementBusy", "model.history.busy"] {
                check(service.contains(text), "service: \(text)")
            }
            let docs = source("docs/uninstall.md")
            for text in UninstallSteps.tccutilCommands + UninstallSteps.keychainCommands + [UninstallSteps.typingKeyCommand, "3. **Typing key.**", ".daydream-backup", "Application Support/DayDream\"", "Application Support/Mac Mem\"",
                         "defaults delete com.getnorthlight.daydream", "defaults delete com.macmem.app", "Keep my history", "Remove everything"] {
                check(docs.contains(text), "docs/uninstall.md: \(text)")
            }
        }
        print("\(count) uninstall checks passed. Synthetic scratch homes only; nothing outside them was touched.")
    }
}
