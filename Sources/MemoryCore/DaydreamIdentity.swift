// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.

import Foundation
import Darwin

/// DayDream's names in macOS and on disk, in one place.
///
/// "Mac Mem" was DayDream's working name. The legacy values below exist only to find
/// an older install and move it once (`DataHomeMigration`); nothing new is written
/// under them. See docs/rename.md for why they changed and what the move does.
public enum DaydreamIdentity {
    /// CFBundleIdentifier of the app (packaging/Info.plist). The helpers inside the app
    /// use this prefix: `<bundleID>.mac-mem` and `<bundleID>.mac-mem-backup`.
    public static let bundleID = "com.getnorthlight.daydream"
    /// The bundle identifier of Mac Mem and of DayDream builds up to build 4.
    public static let legacyBundleID = "com.macmem.app"
    /// Both identities are DayDream itself: never recorded, never listed as an app to exclude.
    public static let ownBundleIDs: Set<String> = [bundleID, legacyBundleID]
    /// The app's name in Finder.
    public static let appName = "DayDream.app"
    /// Folder inside ~/Library/Application Support that holds the history.
    public static let dataFolder = "DayDream"
    /// Where Mac Mem and builds up to build 4 kept it.
    public static let legacyDataFolder = "Mac Mem"
    /// UserDefaults key set once the old app's settings have been copied.
    public static let defaultsMigratedKey = "DayDreamDefaultsMigratedFromMacMemV1"

    /// Copies the old app's saved settings into DayDream's own settings, once. Never
    /// overwrites a value DayDream already has, and skips macOS and updater keys.
    /// `legacy` is `UserDefaults.standard.persistentDomain(forName: legacyBundleID)`.
    @discardableResult
    public static func migrateDefaults(legacy: [String: Any]?, into defaults: some DefaultsStore) -> [String] {
        guard !defaults.bool(forKey: defaultsMigratedKey) else { return [] }
        var copied: [String] = []
        for (key, value) in (legacy ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard !key.hasPrefix("NS"), !key.hasPrefix("Apple"), !key.hasPrefix("com.apple."), !key.hasPrefix("SU"),
                  defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
            copied.append(key)
        }
        defaults.set(true, forKey: defaultsMigratedKey)
        return copied
    }
}

/// The part of `UserDefaults` the settings copy uses (so checks can use an in-memory store).
public protocol DefaultsStore {
    func object(forKey defaultName: String) -> Any?
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Any?, forKey defaultName: String)
}
extension UserDefaults: DefaultsStore {}

/// Moves an older install's history folder ("Mac Mem") to the DayDream folder, once.
///
/// It runs only in the app, at launch, before any store is opened and while recording
/// is off. It never deletes, copies or merges history:
/// - the history moves with one atomic rename, on the same disk;
/// - nothing moves while the old app is running or another recorder holds its lock;
/// - nothing moves when both folders already hold a history (DayDream's is used);
/// - a DayDream folder with no history (for example one holding only a downloaded
///   model) is set aside first and its files are moved back in afterwards.
/// When the move is deferred, `MemPaths.home()` keeps using the old folder, so the app,
/// the command-line tool and AI apps never see two different histories.
public enum DataHomeMigration {
    public enum Outcome: Equatable {
        case notNeeded
        case migrated
        case deferred(String)
    }
    public static let marker = "migrated-from-mac-mem.json"

    public static func run(applicationSupport: URL, legacyAppRunning: Bool, now: Date = Date()) -> Outcome {
        let fm = FileManager.default
        let legacy = applicationSupport.appendingPathComponent(DaydreamIdentity.legacyDataFolder, isDirectory: true)
        let current = applicationSupport.appendingPathComponent(DaydreamIdentity.dataFolder, isDirectory: true)
        guard let legacyKind = kind(legacy.path) else { return .notNeeded }
        guard legacyKind == .ownedDirectory else { return .deferred("The Mac Mem folder is not a plain folder owned by you, so it was left as it is.") }
        guard kind(legacy.appendingPathComponent("memory.sqlite").path) == .ownedFile else { return .notNeeded }
        let currentKind = kind(current.path)
        if currentKind != nil {
            guard currentKind == .ownedDirectory else { return .deferred("The DayDream folder is not a plain folder owned by you, so nothing was moved.") }
            if kind(current.appendingPathComponent("memory.sqlite").path) != nil {
                return .deferred("Both the Mac Mem and the DayDream folder hold a history. DayDream uses its own; the Mac Mem folder was left as it is, except that DayDream deletes the words typed in build 4 there once Mac Mem isn't running.")
            }
        }
        if legacyAppRunning { return .deferred("Mac Mem is still running. Quit it, then reopen DayDream to move your history.") }
        // The old recorder holds capture.lock while it records.
        let lockPath = legacy.appendingPathComponent("capture.lock").path
        var lock: Int32 = -1
        if kind(lockPath) != nil {
            lock = open(lockPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                if lock >= 0 { close(lock) }
                return .deferred("Another recorder is using the Mac Mem folder. Stop it, then reopen DayDream.")
            }
        }
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }

        var aside: URL?
        if currentKind != nil {
            let target = applicationSupport.appendingPathComponent(DaydreamIdentity.dataFolder + ".before-move-" + String(Int(now.timeIntervalSince1970)), isDirectory: true)
            guard kind(target.path) == nil, rename(current.path, target.path) == 0 else {
                return .deferred("The DayDream folder could not be set aside, so nothing was moved.")
            }
            aside = target
        }
        guard rename(legacy.path, current.path) == 0 else {
            if let aside { _ = rename(aside.path, current.path) }
            return .deferred("The Mac Mem folder could not be moved, so DayDream keeps using it.")
        }
        if let aside, let names = try? fm.contentsOfDirectory(atPath: aside.path) {
            for name in names where kind(current.appendingPathComponent(name).path) == nil {
                _ = rename(aside.appendingPathComponent(name).path, current.appendingPathComponent(name).path)
            }
            _ = rmdir(aside.path) // only when empty; leftovers stay for the person to look at
        }
        let note = ["from": legacy.path, "to": current.path, "moved_at": ISO8601DateFormatter().string(from: now)]
        if let data = try? JSONSerialization.data(withJSONObject: note, options: [.sortedKeys]) {
            let fd = open(current.appendingPathComponent(marker).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 { _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }; close(fd) }
        }
        return .migrated
    }

    enum Kind { case ownedDirectory, ownedFile, other }
    static func kind(_ path: String) -> Kind? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        guard info.st_uid == getuid() else { return .other }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .ownedDirectory
        case S_IFREG: return .ownedFile
        default: return .other
        }
    }
}
