// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// Checks the one-time move from the pre-rename "Mac Mem" install (docs/rename.md).
// Synthetic only: every folder is a fresh scratch folder standing in for
// ~/Library/Application Support. No app launch, no real user data, no Keychain.
import Foundation
import Darwin
@testable import MemoryCore

final class MemoryDefaults: DefaultsStore {
    var values: [String: Any] = [:]
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

@main struct DataHomeMigrationChecks {
    static var count = 0
    static func check(_ value: Bool, _ name: String) { precondition(value, name); count += 1; print("PASS " + name) }
    static let fm = FileManager.default

    static func scratch(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    static func write(_ url: URL, _ text: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    static func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }
    static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
    static func deferred(_ outcome: DataHomeMigration.Outcome) -> Bool { if case .deferred = outcome { return true }; return false }

    static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("data-home-migration-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        check(DaydreamIdentity.bundleID == "com.getnorthlight.daydream" && DaydreamIdentity.legacyBundleID == "com.macmem.app",
              "bundle IDs: new DayDream ID, old Mac Mem ID kept only to find an older install")
        check(DaydreamIdentity.dataFolder == "DayDream" && DaydreamIdentity.legacyDataFolder == "Mac Mem", "data folders: DayDream, old Mac Mem")
        check(DaydreamIdentity.ownBundleIDs == [DaydreamIdentity.bundleID, DaydreamIdentity.legacyBundleID], "both IDs count as DayDream itself")

        // 1. Fresh install: nothing to move, the new folder is the home.
        do {
            let support = try scratch(root, "fresh")
            check(DataHomeMigration.run(applicationSupport: support, legacyAppRunning: false, now: now) == .notNeeded, "fresh install: nothing to move")
            check(MemPaths.resolvedHome(applicationSupport: support).lastPathComponent == "DayDream", "fresh install: home is the DayDream folder")
            check(!exists(support.appendingPathComponent("DayDream")), "fresh install: the move creates no folder")
        }
        // 2. Old install only: the whole folder moves in one rename and a marker is written.
        do {
            let support = try scratch(root, "legacy-only")
            let legacy = support.appendingPathComponent("Mac Mem")
            try write(legacy.appendingPathComponent("memory.sqlite"), "history")
            try write(legacy.appendingPathComponent("Models/model.gguf"), "model")
            try write(legacy.appendingPathComponent("capture.lock"), "")
            chmod(legacy.path, 0o700)
            check(MemPaths.resolvedHome(applicationSupport: support).lastPathComponent == "Mac Mem", "before the move, the app and the CLI read the old folder")
            var before = stat(); lstat(legacy.appendingPathComponent("memory.sqlite").path, &before)
            check(DataHomeMigration.run(applicationSupport: support, legacyAppRunning: false, now: now) == .migrated, "old install only: history moves")
            let current = support.appendingPathComponent("DayDream")
            var after = stat(); lstat(current.appendingPathComponent("memory.sqlite").path, &after)
            check(!exists(legacy), "old folder is gone after the move (renamed, not copied)")
            check(read(current.appendingPathComponent("memory.sqlite")) == "history" && before.st_ino == after.st_ino, "history is the same file, moved not copied")
            check(read(current.appendingPathComponent("Models/model.gguf")) == "model", "downloaded model moves with it")
            var mode = stat(); lstat(current.path, &mode)
            check(mode.st_mode & 0o777 == 0o700, "folder keeps its owner-only permissions")
            let marker = current.appendingPathComponent(DataHomeMigration.marker)
            let note = (try? JSONSerialization.jsonObject(with: Data(contentsOf: marker))) as? [String: String]
            check(note?["to"] == current.path && note?["from"] == legacy.path && note?["moved_at"] != nil, "marker records the move")
            check(MemPaths.resolvedHome(applicationSupport: support).path == current.path, "after the move, home is the DayDream folder")
            check(DataHomeMigration.run(applicationSupport: support, legacyAppRunning: false, now: now) == .notNeeded, "second launch: nothing to move")
        }
        // 3. Old app still running: nothing moves, the old folder stays the home.
        do {
            let support = try scratch(root, "running")
            let legacy = support.appendingPathComponent("Mac Mem")
            try write(legacy.appendingPathComponent("memory.sqlite"), "history")
            check(deferred(DataHomeMigration.run(applicationSupport: support, legacyAppRunning: true, now: now)), "old app running: move waits")
            check(exists(legacy.appendingPathComponent("memory.sqlite")) && !exists(support.appendingPathComponent("DayDream")), "old app running: nothing moved")
            check(MemPaths.resolvedHome(applicationSupport: support).path == legacy.path, "old app running: home stays the old folder, so there is one history")
        }
        // 4. Another recorder holds capture.lock: nothing moves.
        do {
            let support = try scratch(root, "locked")
            let legacy = support.appendingPathComponent("Mac Mem")
            try write(legacy.appendingPathComponent("memory.sqlite"), "history")
            let fd = open(legacy.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR, 0o600)
            check(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0, "fixture holds the recorder lock")
            check(deferred(DataHomeMigration.run(applicationSupport: support, legacyAppRunning: false, now: now)), "lock held: move waits")
            check(exists(legacy.appendingPathComponent("memory.sqlite")), "lock held: nothing moved")
            flock(fd, LOCK_UN); close(fd)
            check(DataHomeMigration.run(applicationSupport: support, legacyAppRunning: false, now: now) == .migrated, "lock released: move happens")
        }
        // 5. Both folders hold a history: never merged, DayDream's is used, the old one is left alone.
        do {
            let support = try scratch(root, "both")
            let legacy = support.appendingPathComponent("Mac Mem"), current = support.appendingPathComponent("DayDream")
            try write(legacy.appendingPathComponent("memory.sqlite"), "old")
            try write(current.appendingPathComponent("memory.sqlite"), "new")
            check(deferred(DataHomeMigration.run(applicationSupport: support, legacyAppRunning: false, now: now)), "both histories: nothing moves")
            check(read(legacy.appendingPathComponent("memory.sqlite")) == "old" && read(current.appendingPathComponent("memory.sqlite")) == "new", "both histories: neither is changed")
            check(MemPaths.resolvedHome(applicationSupport: support).path == current.path, "both histories: DayDream's is used")
        }
        // 6. DayDream folder with only a downloaded model: set aside, history moves, the model comes back.
        do {
            let support = try scratch(root, "models-only")
            let legacy = support.appendingPathComponent("Mac Mem"), current = support.appendingPathComponent("DayDream")
            try write(legacy.appendingPathComponent("memory.sqlite"), "history")
            try write(current.appendingPathComponent("Models/new.gguf"), "new model")
            check(DataHomeMigration.run(applicationSupport: support, legacyAppRunning: false, now: now) == .migrated, "DayDream folder without history: move happens")
            check(read(current.appendingPathComponent("memory.sqlite")) == "history", "history arrives")
            check(read(current.appendingPathComponent("Models/new.gguf")) == "new model", "the DayDream folder's model is kept")
            let leftovers = try fm.contentsOfDirectory(atPath: support.path).filter { $0.hasPrefix("DayDream.before-move-") }
            check(leftovers.isEmpty, "the set-aside folder is removed once empty")
        }
        // 7. Same name in both folders: the old install's file wins, the other is kept aside, not deleted.
        do {
            let support = try scratch(root, "clash")
            let legacy = support.appendingPathComponent("Mac Mem"), current = support.appendingPathComponent("DayDream")
            try write(legacy.appendingPathComponent("memory.sqlite"), "history")
            try write(legacy.appendingPathComponent("Models/m.gguf"), "old model")
            try write(current.appendingPathComponent("Models/m.gguf"), "new model")
            check(DataHomeMigration.run(applicationSupport: support, legacyAppRunning: false, now: now) == .migrated, "name clash: move happens")
            let aside = support.appendingPathComponent("DayDream.before-move-1790000000")
            check(read(aside.appendingPathComponent("Models/m.gguf")) == "new model", "name clash: nothing is deleted, the other copy stays aside")
        }
        // 8. Symlinked or foreign folders are never followed or moved.
        do {
            let support = try scratch(root, "symlink")
            let elsewhere = try scratch(root, "elsewhere")
            try write(elsewhere.appendingPathComponent("memory.sqlite"), "other")
            try fm.createSymbolicLink(at: support.appendingPathComponent("Mac Mem"), withDestinationURL: elsewhere)
            check(deferred(DataHomeMigration.run(applicationSupport: support, legacyAppRunning: false, now: now)), "symlinked old folder: not moved")
            check(!exists(support.appendingPathComponent("DayDream")) && read(elsewhere.appendingPathComponent("memory.sqlite")) == "other", "symlinked old folder: target untouched")
            let support2 = try scratch(root, "symlink-current")
            try write(support2.appendingPathComponent("Mac Mem/memory.sqlite"), "history")
            let target = try scratch(root, "elsewhere2")
            try fm.createSymbolicLink(at: support2.appendingPathComponent("DayDream"), withDestinationURL: target)
            check(deferred(DataHomeMigration.run(applicationSupport: support2, legacyAppRunning: false, now: now)), "symlinked DayDream folder: nothing moves")
            check(exists(support2.appendingPathComponent("Mac Mem/memory.sqlite")), "symlinked DayDream folder: history stays")
            let support3 = try scratch(root, "symlink-db")
            try fm.createDirectory(at: support3.appendingPathComponent("Mac Mem"), withIntermediateDirectories: false)
            try fm.createSymbolicLink(at: support3.appendingPathComponent("Mac Mem/memory.sqlite"), withDestinationURL: elsewhere.appendingPathComponent("memory.sqlite"))
            check(DataHomeMigration.run(applicationSupport: support3, legacyAppRunning: false, now: now) == .notNeeded, "symlinked history file: not treated as a history")
        }
        // 9. Old folder without a history (for example only models): no move.
        do {
            let support = try scratch(root, "legacy-models-only")
            try write(support.appendingPathComponent("Mac Mem/Models/m.gguf"), "model")
            check(DataHomeMigration.run(applicationSupport: support, legacyAppRunning: false, now: now) == .notNeeded, "old folder without history: not moved")
            check(MemPaths.resolvedHome(applicationSupport: support).lastPathComponent == "DayDream", "old folder without history: home is DayDream")
        }
        // 10. Settings are copied once, never overwrite, and skip macOS and updater keys.
        do {
            let defaults = MemoryDefaults()
            defaults.set("mine", forKey: "kept")
            let legacy: [String: Any] = ["kept": "old", "copied": 7, "NSWindow Frame main": "x", "AppleLanguages": ["en"], "SUEnableAutomaticChecks": true, "com.apple.x": 1]
            let copied = DaydreamIdentity.migrateDefaults(legacy: legacy, into: defaults)
            check(copied == ["copied"], "settings: only missing app keys are copied")
            check(defaults.object(forKey: "kept") as? String == "mine" && defaults.object(forKey: "copied") as? Int == 7, "settings: existing values are never overwritten")
            check(defaults.object(forKey: "SUEnableAutomaticChecks") == nil && defaults.object(forKey: "NSWindow Frame main") == nil && defaults.object(forKey: "AppleLanguages") == nil, "settings: macOS and updater keys are not copied")
            defaults.set(nil, forKey: "copied")
            check(DaydreamIdentity.migrateDefaults(legacy: legacy, into: defaults).isEmpty && defaults.object(forKey: "copied") == nil, "settings: copied only once")
            check(DaydreamIdentity.migrateDefaults(legacy: nil, into: MemoryDefaults()).isEmpty, "settings: no old settings is fine")
        }
        // 11. Safe typing (owner/v1 merge): the sealed typed words move with the history, in the same file, and
        // still open with the same key. The key is named by the store's own id (account keyring-v1:<core_store_id>),
        // so the move never renames, copies or reads a Keychain item. In-memory keys only; no Keychain here.
        do {
            let support = try scratch(root, "typed")
            let legacy = support.appendingPathComponent("Mac Mem")
            let keys = InMemoryTypedKeyStore()
            let words = "harbour plan with otterlilac"
            var sealedBefore: [[String]] = [], storeID: String?
            do {
                let store = try MemoryStore(home: legacy, writable: true, automaticallySyncSearch: false)
                var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try store.updatePolicy(policy, now: now)
                try store.attachVault(TypedTextVault(keyStore: keys), now: now); try store.setUpTypedVault(now: now); try store.acceptSafeTyping(now: now)
                let draft = Evidence(id: "moved-draft", at: iso(now), kind: "keyboard.text_input", app: "TextEdit", bundle: "com.apple.TextEdit", title: "plan", text: words, synthetic: true)
                check(try store.ingest(draft, now: now), "typed fixture: a draft is sealed in the old folder")
                sealedBefore = try store.rows("SELECT id,epoch,sealed FROM typed_text ORDER BY id")
                storeID = try store.coreStoreID()
            }
            let keyring = keys.raw
            check(sealedBefore.count == 1 && storeID != nil && keyring != nil, "typed fixture: one sealed row, a store id and a keyring")
            check(DataHomeMigration.run(applicationSupport: support, legacyAppRunning: false, now: now) == .migrated, "typed history: the folder moves")
            let current = support.appendingPathComponent("DayDream")
            let moved = try MemoryStore(home: current, writable: true, automaticallySyncSearch: false)
            check(try moved.rows("SELECT id,epoch,sealed FROM typed_text ORDER BY id") == sealedBefore, "typed history: the sealed rows arrive unchanged")
            check(try moved.coreStoreID() == storeID, "typed history: the store id (and so the Keychain account keyring-v1:<id>) is unchanged")
            check(keys.raw == keyring, "typed history: the move never touches the keyring")
            try moved.attachVault(TypedTextVault(keyStore: keys), now: now)
            check(try moved.hydrateTypedText("moved-draft", disclosure: .owner, now: now) == words, "typed history: the words still open with the same key after the move")
            let source = (try? String(contentsOfFile: "Sources/MemoryCore/DaydreamIdentity.swift", encoding: .utf8)) ?? ""
            let move = source.components(separatedBy: "enum DataHomeMigration").dropFirst().joined()
            check(!move.isEmpty && !["SecItem", "kSecClass", "Keychain", "TypedKeychainName", "TypedText", "typed_text"].contains(where: move.contains),
                  "typed history: the move's code names no Keychain item and no typed table (it renames the folder only)")
        }
        // Both folders hold a history and the old one has build 4 plain-text typed words: the move leaves the folder,
        // DayDream never opens it, so launch deletes those words there (stubs stay) and changes nothing else.
        do {
            let support = try scratch(root, "both-typed")
            let legacy = support.appendingPathComponent("Mac Mem"), current = support.appendingPathComponent("DayDream")
            let words = "oldbuildfour plain words about the harbour"
            do {
                let old = try MemoryStore(home: legacy, writable: true, automaticallySyncSearch: false)
                let typed = Evidence(id: "b4-typed", at: iso(now.addingTimeInterval(-3_600)), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes", title: "Trip", text: words, synthetic: true)
                let other = Evidence(id: "b4-window", at: iso(now.addingTimeInterval(-3_000)), kind: "app.activate", app: "Notes", bundle: "com.apple.Notes", title: "Trip", text: "", synthetic: true)
                for e in [typed, other] { let body = try json(e); try old.exec("INSERT INTO records VALUES(?,?,?)", [e.id, body, fingerprint(body)]) }
                _ = try MemoryStore(home: current, writable: true, automaticallySyncSearch: false)
            }
            func raw() throws -> String { try MemoryStore(home: legacy, writable: false, automaticallySyncSearch: false).rows("SELECT body FROM records").flatMap { $0 }.joined(separator: "\n") }
            func window() throws -> [[String]] { try MemoryStore(home: legacy, writable: false, automaticallySyncSearch: false).rows("SELECT body,revision FROM records WHERE id='b4-window'") }
            let windowBefore = try window()
            let currentBefore = try Data(contentsOf: current.appendingPathComponent("memory.sqlite"))
            check(deferred(DataHomeMigration.run(applicationSupport: support, legacyAppRunning: false, now: now)), "both histories, build 4 words: nothing moves")
            check(try LegacyTypedScrub.run(applicationSupport: support, legacyAppRunning: true, now: now) == .waiting && raw().contains(words),
                  "both histories, build 4 words: while Mac Mem runs, its folder isn't opened for writing")
            let lockFD = open(legacy.appendingPathComponent("capture.lock").path, O_RDWR | O_CREAT, 0o600)
            flock(lockFD, LOCK_EX)
            check(try LegacyTypedScrub.run(applicationSupport: support, legacyAppRunning: false, now: now) == .waiting && raw().contains(words),
                  "both histories, build 4 words: while a recorder holds the lock, nothing changes")
            flock(lockFD, LOCK_UN); close(lockFD)
            check(LegacyTypedScrub.run(applicationSupport: support, legacyAppRunning: false, now: now) == .stubbed(1), "both histories, build 4 words: the plain-text row becomes a stub")
            let old = try MemoryStore(home: legacy, writable: false, automaticallySyncSearch: false)
            check(try !raw().contains("oldbuildfour") && old.typedAfter("b4-typed")?.source == "stub", "both histories, build 4 words: no word is left in plain text; a stub stays")
            check(try window() == windowBefore, "both histories, build 4 words: the rest of the old history is unchanged")
            check(try Data(contentsOf: current.appendingPathComponent("memory.sqlite")) == currentBefore, "both histories, build 4 words: DayDream's own history isn't touched")
            let legacyFile = legacy.appendingPathComponent("memory.sqlite")
            let settled = try Data(contentsOf: legacyFile)
            check(try LegacyTypedScrub.run(applicationSupport: support, legacyAppRunning: false, now: now) == .notNeeded && Data(contentsOf: legacyFile) == settled,
                  "both histories, nothing in plain text: the old folder isn't opened for writing again")
            // Only the both-histories case: an old history alone moves (and launch settles it in the DayDream folder).
            let alone = try scratch(root, "legacy-typed-alone")
            do {
                let store = try MemoryStore(home: alone.appendingPathComponent("Mac Mem"), writable: true, automaticallySyncSearch: false)
                let e = Evidence(id: "b4-alone", at: iso(now), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes", title: "Trip", text: words, synthetic: true)
                let body = try json(e); try store.exec("INSERT INTO records VALUES(?,?,?)", [e.id, body, fingerprint(body)])
            }
            check(LegacyTypedScrub.run(applicationSupport: alone, legacyAppRunning: false, now: now) == .notNeeded, "old history alone: left for the move and the launch rule")
            let launch = (try? String(contentsOfFile: "Sources/MacMemApp/DaydreamLaunchSession.swift", encoding: .utf8)) ?? ""
            // Review gap "Legacy typed-text scrub at launch": the scan (2.7 s cold on a 280 MiB history) runs off the main thread.
            if let move = launch.range(of: "legacyMove = DataHomeMigration.run(applicationSupport:support, legacyAppRunning:running)"),
               let queue = launch.range(of: "legacyTypedScrubQueue.async {\n            let outcome = LegacyTypedScrub.run(applicationSupport:support, legacyAppRunning:running)\n            Task { @MainActor in legacyTypedScrub = outcome }"),
               launch.contains("private static let legacyTypedScrubQueue = DispatchQueue(label: \"DayDream.legacy-typed-scrub\", qos: .utility)") {
                check(move.upperBound < queue.lowerBound, "launch: the old folder's build 4 words are settled right after the move, off the main thread")
                check(launch.components(separatedBy: "LegacyTypedScrub.run(").count == 2, "launch: the scrub is started once, only from the background queue")
            } else { check(false, "launch: the old folder's build 4 words are settled right after the move, off the main thread") }
        }
        print("PASS data home migration checks: \(count)")
    }
}
