// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.

import Foundation
import Darwin

/// Settings › Setup › Uninstall DayDream (docs/uninstall.md).
///
/// The plan is built from a fixed list of paths (`UninstallLocations.allowedPaths`). Nothing
/// outside that list is ever touched, whatever is on disk. Every path is checked with `lstat`,
/// so a symlink is never followed, and it is checked again right before it is removed.
/// The app parts that need macOS services (the login item, preferences, quitting) live in
/// `Sources/MacMemApp/UninstallService.swift`.
public enum UninstallChoice: String, CaseIterable, Sendable {
    /// Removes the app, its login item and caches. The history folder and settings stay.
    case keepHistory
    /// Also removes the history folders (DayDream and a leftover Mac Mem) and the settings.
    case removeEverything
}

/// Every path an uninstall may touch, for one person's home folder.
public struct UninstallLocations: Equatable, Sendable {
    public let home: URL
    /// `/Applications`. The checks pass a scratch folder instead.
    public let systemApplications: URL

    /// Both names DayDream has had in Finder. On a case-insensitive disk they are the same path.
    public static let appNames = [DaydreamIdentity.appName, "Daydream.app"]
    /// Both app IDs, plus the two helpers inside the app, which can own preferences of their own.
    public static let preferenceDomains = [DaydreamIdentity.bundleID, DaydreamIdentity.legacyBundleID,
                                           DaydreamIdentity.bundleID + ".mac-mem", DaydreamIdentity.bundleID + ".mac-mem-backup"]
    /// A DayDream folder the one-time move set aside and could not empty (DataHomeMigration).
    public static let leftoverPrefix = DaydreamIdentity.dataFolder + ".before-move-"

    public init(home: URL, systemApplications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)) {
        self.home = home.standardizedFileURL
        self.systemApplications = systemApplications.standardizedFileURL
    }
    public static func live() -> UninstallLocations { UninstallLocations(home: FileManager.default.homeDirectoryForCurrentUser) }

    var library: URL { home.appendingPathComponent("Library", isDirectory: true) }
    public var applicationSupport: URL { library.appendingPathComponent("Application Support", isDirectory: true) }
    public var userApplications: URL { home.appendingPathComponent("Applications", isDirectory: true) }
    public var historyFolder: URL { applicationSupport.appendingPathComponent(DaydreamIdentity.dataFolder, isDirectory: true) }
    public var legacyHistoryFolder: URL { applicationSupport.appendingPathComponent(DaydreamIdentity.legacyDataFolder, isDirectory: true) }
    /// "Daydream": an older spelling. The same folder as DayDream on a case-insensitive disk.
    public var oldSpellingFolder: URL { applicationSupport.appendingPathComponent("Daydream", isDirectory: true) }
    /// Files that show a folder holds a DayDream history: the database, or the rename move's marker.
    public static let historyMarkers = ["memory.sqlite", "migrated-from-mac-mem.json"]

    /// Where DayDream.app may be: /Applications and ~/Applications, under either name.
    public var appCandidates: [URL] {
        [systemApplications, userApplications].flatMap { folder in Self.appNames.map { folder.appendingPathComponent($0, isDirectory: true) } }
    }
    public func preferencesFile(_ domain: String) -> URL { library.appendingPathComponent("Preferences/\(domain).plist") }
    public func launchAgent(_ label: String) -> URL { library.appendingPathComponent("LaunchAgents/\(label).plist") }
    /// Caches macOS and the updater keep per app. They hold no history of their own.
    public func appCaches(_ id: String) -> [URL] {
        [library.appendingPathComponent("Caches/\(id)", isDirectory: true),
         library.appendingPathComponent("HTTPStorages/\(id)", isDirectory: true),
         library.appendingPathComponent("HTTPStorages/\(id).binarycookies"),
         library.appendingPathComponent("Saved Application State/\(id).savedState", isDirectory: true)]
    }
    /// Login items DayDream could have: a LaunchAgent named after either app ID.
    public static let loginLabels = [DaydreamIdentity.bundleID, DaydreamIdentity.legacyBundleID]

    /// The complete list. `isAllowed` also accepts `DayDream.before-move-<digits>` in Application Support.
    public var allowedPaths: [String] {
        var paths = appCandidates.map(\.path)
        paths += [historyFolder.path, legacyHistoryFolder.path, oldSpellingFolder.path]
        paths += Self.preferenceDomains.map { preferencesFile($0).path }
        paths += Self.loginLabels.map { launchAgent($0).path }
        paths += DaydreamIdentity.ownBundleIDs.sorted().flatMap { appCaches($0).map(\.path) }
        return paths
    }
    public func isAllowed(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if allowedPaths.contains(path) { return true }
        return url.deletingLastPathComponent().standardizedFileURL.path == applicationSupport.path && Self.isLeftoverName(url.lastPathComponent)
    }
    public static func isLeftoverName(_ name: String) -> Bool {
        guard name.hasPrefix(leftoverPrefix) else { return false }
        let digits = name.dropFirst(leftoverPrefix.count)
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// What `lstat` says about one path. Symlinks are reported as symlinks, never followed.
public struct UninstallEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case directory, file, symlink, other }
    public let kind: Kind
    public let owner: uid_t
    public let device: dev_t
    public let inode: ino_t
    public init(kind: Kind, owner: uid_t, device: dev_t, inode: ino_t) { self.kind = kind; self.owner = owner; self.device = device; self.inode = inode }
}

/// Read-only questions the planner asks the disk. The checks use the live one over a scratch home.
public struct UninstallProbe {
    public var entry: (String) -> UninstallEntry?
    public var infoPlist: (URL) -> [String: Any]?
    public var contents: (URL) -> [String]
    public var uid: uid_t
    public init(entry: @escaping (String) -> UninstallEntry?, infoPlist: @escaping (URL) -> [String: Any]?, contents: @escaping (URL) -> [String], uid: uid_t) {
        self.entry = entry; self.infoPlist = infoPlist; self.contents = contents; self.uid = uid
    }
    public static let live = UninstallProbe(entry: { path in
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let kind: UninstallEntry.Kind
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .file
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        return UninstallEntry(kind: kind, owner: info.st_uid, device: dev_t(info.st_dev), inode: info.st_ino)
    }, infoPlist: { app in
        let plist = app.appendingPathComponent("Contents/Info.plist")
        var info = stat()
        // Never read through a link: Contents and Info.plist must be what they claim to be.
        guard lstat(app.appendingPathComponent("Contents").path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              lstat(plist.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size < 1_000_000,
              let data = FileManager.default.contents(atPath: plist.path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }, contents: { folder in
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }, uid: getuid())

    /// True when no part of the path, from `/` down, is a symlink.
    public func noLinks(_ url: URL) -> Bool {
        var path = ""
        for part in url.standardizedFileURL.pathComponents where part != "/" {
            path += "/" + part
            guard let found = entry(path) else { return true } // the rest does not exist
            if found.kind == .symlink { return false }
        }
        return true
    }
}

/// One thing the uninstall removes.
public struct UninstallItem: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case runningApp, otherApp, loginItem, appCache, preferences, history, legacyHistory, leftoverHistory
    }
    public enum Removal: Equatable, Sendable { case trash, delete }
    public let kind: Kind
    public let url: URL
    public let removal: Removal
    /// What `lstat` found when the plan was made. Checked again just before removal.
    public let entry: UninstallEntry

    /// Plain words for the list the person sees.
    public var label: String {
        switch kind {
        case .runningApp: return "This app (\(url.path))"
        case .otherApp: return "Another copy of DayDream (\(url.path))"
        case .loginItem: return "Login item (\(url.lastPathComponent))"
        case .appCache: return "App cache (\(url.lastPathComponent))"
        case .preferences: return "Settings (\(url.lastPathComponent))"
        case .history: return "Your history (\(url.path))"
        case .legacyHistory: return "History from before the rename (\(url.path))"
        case .leftoverHistory: return "Folder left by the rename move (\(url.path))"
        }
    }
}

/// A path that exists but is left in place, and why.
public struct UninstallSkip: Equatable, Sendable {
    public let url: URL
    public let reason: String
}

public struct UninstallPlan: Equatable, Sendable {
    public let choice: UninstallChoice
    /// In the order they are removed. The running app is always first: if it can't be moved to
    /// the Trash, nothing else is touched.
    public let items: [UninstallItem]
    public let skipped: [UninstallSkip]
    /// History folders that stay ("Keep my history").
    public let kept: [URL]
    /// Preference domains to clear through macOS ("Remove everything"). Both app IDs, always.
    public let preferenceDomains: [String]
    public var removesHistory: Bool { choice == .removeEverything }
}

public struct UninstallRefusal: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// The app that is asking to be uninstalled.
public struct UninstallRequester {
    public let bundleURL: URL
    public let bundleID: String?
    /// `Bundle.main.infoDictionary`.
    public let info: [String: Any]
    /// `MAC_MEM_HOME`, when set. A custom history folder means a development or test setup.
    public let environmentHome: String?
    public init(bundleURL: URL, bundleID: String?, info: [String: Any] = [:], environmentHome: String?) {
        self.bundleURL = bundleURL; self.bundleID = bundleID; self.info = info; self.environmentHome = environmentHome
    }
}

public enum UninstallPlanner {
    /// Info.plist keys that mark a development or trial copy of DayDream.
    public static let developmentKeys = ["DaydreamDevelopmentTrial", "DaydreamRecordingTrial", "DaydreamFunctionalTrial"]

    public static func isDevelopment(_ info: [String: Any]) -> Bool {
        developmentKeys.contains { info[$0] as? Bool == true || (info[$0] as? String).map { ["1", "true", "yes"].contains($0.lowercased()) } == true }
    }

    public static func plan(_ choice: UninstallChoice, requester: UninstallRequester, locations: UninstallLocations,
                            probe: UninstallProbe) -> Result<UninstallPlan, UninstallRefusal> {
        guard requester.bundleID == DaydreamIdentity.bundleID else {
            return .failure(UninstallRefusal("Only DayDream can uninstall itself, and this app isn't DayDream. Nothing was removed."))
        }
        if let home = requester.environmentHome, !home.isEmpty {
            return .failure(UninstallRefusal("This DayDream uses a custom history folder (MAC_MEM_HOME), so Uninstall is off. Nothing was removed. See docs/uninstall.md to remove it by hand."))
        }
        guard !isDevelopment(requester.info) else {
            return .failure(UninstallRefusal("This is a development copy of DayDream, so Uninstall is off. Nothing was removed."))
        }
        let running = requester.bundleURL.standardizedFileURL
        guard probe.noLinks(running) else {
            return .failure(UninstallRefusal("DayDream was opened through a link. Open it from the Applications folder and try again. Nothing was removed."))
        }
        let matches = locations.appCandidates.filter { candidate in
            probe.noLinks(candidate) && probe.entry(candidate.path).map { same($0, probe.entry(running.path)) } == true }
        guard let runningEntry = probe.entry(running.path), runningEntry.kind == .directory,
              let runningURL = matches.first(where: { $0.path == running.path }) ?? matches.first.map({ onDisk($0, locations: locations, probe: probe) }) else {
            return .failure(UninstallRefusal("Uninstall works only for DayDream in the Applications folder. To remove this copy, quit DayDream and drag it to the Trash. Nothing was removed."))
        }
        guard let diskInfo = probe.infoPlist(runningURL), diskInfo["CFBundleIdentifier"] as? String == DaydreamIdentity.bundleID else {
            return .failure(UninstallRefusal("This copy of DayDream doesn't look complete, so Uninstall is off. Nothing was removed."))
        }
        guard !isDevelopment(diskInfo) else {
            return .failure(UninstallRefusal("This is a development copy of DayDream, so Uninstall is off. Nothing was removed."))
        }

        var items = [UninstallItem(kind: .runningApp, url: runningURL, removal: .trash, entry: runningEntry)]
        var skipped: [UninstallSkip] = []
        var seen = [runningEntry]
        func skip(_ url: URL, _ reason: String) { skipped.append(UninstallSkip(url: url, reason: reason)) }
        func add(_ kind: UninstallItem.Kind, _ listed: URL, _ removal: UninstallItem.Removal, expect: UninstallEntry.Kind) {
            guard let found = probe.entry(listed.path), !seen.contains(where: { same($0, found) }) else { return }
            seen.append(found)
            let url = onDisk(listed, locations: locations, probe: probe)
            guard probe.noLinks(url), found.kind != .symlink else { return skip(url, "It's a link. It was left in place, and what it points to wasn't touched.") }
            guard found.kind == expect else { return skip(url, "It isn't what DayDream expects there, so it was left in place.") }
            guard found.owner == probe.uid else { return skip(url, "It belongs to another user, so it was left in place.") }
            if kind == .otherApp {
                let info = probe.infoPlist(url) ?? [:]
                guard let id = info["CFBundleIdentifier"] as? String, DaydreamIdentity.ownBundleIDs.contains(id) else { return skip(url, "It isn't DayDream, so it was left in place.") }
                guard !isDevelopment(info) else { return skip(url, "It's a development copy, so it was left in place.") }
            }
            items.append(UninstallItem(kind: kind, url: url, removal: removal, entry: found))
        }

        // Other copies of DayDream, under either name and either app ID.
        for candidate in locations.appCandidates { add(.otherApp, candidate, .trash, expect: .directory) }
        for label in UninstallLocations.loginLabels { add(.loginItem, locations.launchAgent(label), .delete, expect: .file) }
        for id in DaydreamIdentity.ownBundleIDs.sorted() {
            for cache in locations.appCaches(id) { add(.appCache, cache, .delete, expect: cache.pathExtension == "binarycookies" ? .file : .directory) }
        }

        var kept: [URL] = []
        switch choice {
        case .keepHistory:
            var keptEntries: [UninstallEntry] = []
            for folder in [locations.historyFolder, locations.legacyHistoryFolder, locations.oldSpellingFolder] {
                guard let found = probe.entry(folder.path), !keptEntries.contains(where: { same($0, found) }) else { continue }
                // A separate "Daydream" folder (case-sensitive disk) is listed only when it holds a DayDream history.
                if folder == locations.oldSpellingFolder && !probe.contents(folder).contains(where: { UninstallLocations.historyMarkers.contains($0) }) { continue }
                keptEntries.append(found); kept.append(onDisk(folder, locations: locations, probe: probe))
            }
        case .removeEverything:
            for domain in UninstallLocations.preferenceDomains { add(.preferences, locations.preferencesFile(domain), .delete, expect: .file) }
            add(.history, locations.historyFolder, .delete, expect: .directory)
            add(.legacyHistory, locations.legacyHistoryFolder, .delete, expect: .directory)
            // On a case-sensitive disk "Daydream" is its own folder, and another app could own it: it is
            // removed only when it holds a DayDream history (the same folder as DayDream is skipped as seen).
            let oldSpelling = locations.oldSpellingFolder
            if let found = probe.entry(oldSpelling.path), found.kind == .directory, !seen.contains(where: { same($0, found) }),
               !probe.contents(oldSpelling).contains(where: { UninstallLocations.historyMarkers.contains($0) }) {
                skip(onDisk(oldSpelling, locations: locations, probe: probe), "It doesn't hold a DayDream history, so it was left in place.")
            } else {
                add(.legacyHistory, oldSpelling, .delete, expect: .directory)
            }
            for name in probe.contents(locations.applicationSupport).sorted() where UninstallLocations.isLeftoverName(name) {
                add(.leftoverHistory, locations.applicationSupport.appendingPathComponent(name, isDirectory: true), .delete, expect: .directory)
            }
        }
        guard items.allSatisfy({ locations.isAllowed($0.url) }) else {
            return .failure(UninstallRefusal("Uninstall found an unexpected path, so it stopped. Nothing was removed."))
        }
        return .success(UninstallPlan(choice: choice, items: items, skipped: skipped, kept: kept,
                                      preferenceDomains: choice == .removeEverything ? [DaydreamIdentity.bundleID, DaydreamIdentity.legacyBundleID] : []))
    }

    /// The listed path, spelled as it is on disk ("Daydream.app" rather than "DayDream.app" on a
    /// case-insensitive disk), when that spelling is also on the list. Otherwise the listed path.
    static func onDisk(_ listed: URL, locations: UninstallLocations, probe: UninstallProbe) -> URL {
        let parent = listed.deletingLastPathComponent()
        let names = probe.contents(parent)
        guard !names.contains(listed.lastPathComponent),
              let name = names.first(where: { $0.lowercased() == listed.lastPathComponent.lowercased() }) else { return listed }
        let actual = parent.appendingPathComponent(name, isDirectory: listed.hasDirectoryPath)
        return locations.isAllowed(actual) ? actual : listed
    }

    static func same(_ a: UninstallEntry, _ b: UninstallEntry?) -> Bool { guard let b else { return false }; return a.device == b.device && a.inode == b.inode }
}

/// How the uninstall removes a path. The app moves apps to the Trash and deletes the rest;
/// the checks record calls, or move things into a scratch "Trash".
public struct UninstallOperations {
    public var trash: (URL) throws -> Void
    public var delete: (URL) throws -> Void
    public init(trash: @escaping (URL) throws -> Void, delete: @escaping (URL) throws -> Void) { self.trash = trash; self.delete = delete }
    /// `FileManager.removeItem` deletes a symlink itself, never what it points to.
    public static let live = UninstallOperations(trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                                                 delete: { try FileManager.default.removeItem(at: $0) })
}

public struct UninstallReport: Equatable, Sendable {
    public struct Failure: Equatable, Sendable { public let item: UninstallItem; public let reason: String }
    public var removed: [UninstallItem] = []
    public var failed: [Failure] = []
    /// Set when the app itself couldn't be moved to the Trash. Then nothing else was touched.
    public var stopped: String?
    /// Remove everything: whether the typing key of each removed history was deleted from the Keychain.
    public var typingKey: UninstallTypingKeyResult = .notAttempted
    public var finished: Bool { stopped == nil }
    public init() {}
}

public enum UninstallRunner {
    /// Removes the plan's items in order. Each path is checked again first: still on the list,
    /// no link anywhere in it, and still the same file or folder the plan saw.
    public static func run(_ plan: UninstallPlan, locations: UninstallLocations, probe: UninstallProbe,
                           operations: UninstallOperations) -> UninstallReport {
        var report = UninstallReport()
        for item in plan.items {
            let problem = recheck(item, locations: locations, probe: probe, sameInode: true)
            if problem == nil {
                do {
                    try item.removal == .trash ? operations.trash(item.url) : operations.delete(item.url)
                    report.removed.append(item); continue
                } catch {
                    report.failed.append(.init(item: item, reason: "macOS didn't allow it (\(error.localizedDescription))."))
                }
            } else if let problem, problem != gone {
                report.failed.append(.init(item: item, reason: problem))
            } else {
                report.removed.append(item) // already gone
                continue
            }
            if item.kind == .runningApp {
                report.stopped = "DayDream couldn't move itself to the Trash, so it stopped there. Your history and settings weren't touched. Quit DayDream and drag it from Applications to the Trash; Finder may ask for your password."
                return report
            }
        }
        return report
    }

    /// Runs again as DayDream quits: deletes what the app may have written back after the
    /// first pass (for example a settings file saved on quit). Deletes only history, settings
    /// and cache items of the plan, with the same checks, but by kind rather than by inode.
    public static func sweep(_ plan: UninstallPlan, locations: UninstallLocations, probe: UninstallProbe,
                             delete: (URL) throws -> Void) -> [URL] {
        var removed: [URL] = []
        for item in plan.items where item.removal == .delete && item.kind != .loginItem {
            guard recheck(item, locations: locations, probe: probe, sameInode: false) == nil else { continue }
            if (try? delete(item.url)) != nil { removed.append(item.url) }
        }
        return removed
    }

    static let gone = "It was already gone."
    static func recheck(_ item: UninstallItem, locations: UninstallLocations, probe: UninstallProbe, sameInode: Bool) -> String? {
        guard locations.isAllowed(item.url) else { return "It isn't on DayDream's list, so it was left in place." }
        guard let now = probe.entry(item.url.path) else { return gone }
        guard probe.noLinks(item.url), now.kind != .symlink else { return "It became a link, so it was left in place." }
        guard now.kind == item.entry.kind, now.owner == probe.uid else { return "It changed since you chose Uninstall, so it was left in place." }
        if sameInode && !UninstallPlanner.same(now, item.entry) { return "It changed since you chose Uninstall, so it was left in place." }
        return nil
    }
}

/// What happened to the typing key (safe typing) during an uninstall.
public enum UninstallTypingKeyResult: Equatable, Sendable {
    /// Keep my history (the kept history needs its key), or the steps shown without an uninstall.
    case notAttempted
    /// Remove everything deleted the key of each removed history (none left in this Mac's Keychain).
    case deleted
    /// The key couldn't be deleted, and why. The steps then say how to delete it by hand.
    case failed(String)
}

/// Remove everything deletes the typing key of every history it deletes. Only the app can be sure
/// to: Keychain Access and `security` may not see a data-protection item. Each history has its own
/// key (`TypedKeychainName`: account `keyring-v1:<core_store_id>`), so the ids are read from the
/// histories before they are removed, and keys of other homes (development, trials) are never touched.
public enum UninstallTypingKeys {
    public static let historyKinds: Set<UninstallItem.Kind> = [.history, .legacyHistory, .leftoverHistory]

    /// The store ids whose keys go: the running store's, and each removed history folder's
    /// `memory.sqlite` (a plain file, never a link). Empty for Keep my history.
    public static func storeIDs(_ plan: UninstallPlan, current: String?, probe: UninstallProbe, read: (URL) -> String?) -> [String] {
        guard plan.removesHistory else { return [] }
        var ids: [String] = []
        func add(_ id: String?) { if let id, !id.isEmpty, !ids.contains(id) { ids.append(id) } }
        add(current)
        for item in plan.items where historyKinds.contains(item.kind) {
            let file = item.url.appendingPathComponent("memory.sqlite")
            guard probe.noLinks(file), probe.entry(file.path)?.kind == .file else { continue }
            add(read(item.url))
        }
        return ids
    }

    /// A history folder's `core_store_id`, read-only. nil when there is none.
    public static func readStoreID(_ folder: URL) -> String? {
        guard let store = try? MemoryStore(home: folder, writable: false, automaticallySyncSearch: false) else { return nil }
        return (try? store.coreStoreID()) ?? nil
    }

    /// Deletes each id's key (the app's store deletes both the data-protection and the login copy).
    /// A key that isn't there counts as deleted.
    public static func delete(_ ids: [String], keys: (String) -> TypedKeyStore) -> UninstallTypingKeyResult {
        var failures: [String] = []
        for id in ids {
            do { try keys(id).delete() } catch { failures.append((error as? TypedKeyStoreError)?.description ?? error.localizedDescription) }
        }
        guard let first = failures.first else { return .deleted }
        return .failed(first)
    }
}

/// The steps an app can't do for itself, for both names. Shown after uninstalling and in docs/uninstall.md.
public enum UninstallSteps {
    public static let keychainServices = ["DayDream.Writer.OpenRouter", "MacMem.Writer.OpenRouter"]
    /// Accessibility, Input Monitoring (ListenEvent) and Automation (AppleEvents, for Chrome pages).
    public static let permissionServices = ["Accessibility", "ListenEvent", "AppleEvents"]
    public static var tccutilCommands: [String] {
        [DaydreamIdentity.bundleID, DaydreamIdentity.legacyBundleID].flatMap { id in permissionServices.map { "tccutil reset \($0) \(id)" } }
    }
    public static var keychainCommands: [String] { keychainServices.map { "security delete-generic-password -s \($0) -a owner" } }
    /// The typing key (safe typing): one Keychain item per history, named by `TypedKeychainName`.
    public static let typingKeyService = TypedKeychainName.service
    public static var typingKeyCommand: String { "security delete-generic-password -s \(typingKeyService)" }
    /// Keep my history keeps the key (the kept history needs it). Remove everything deletes it in the app
    /// (`UninstallTypingKeys`); the steps say so, or how to delete it by hand when that failed or when the
    /// steps are read without the app (`.notAttempted`, docs/uninstall.md "by hand").
    public static func typingKeyText(choice: UninstallChoice, result: UninstallTypingKeyResult = .notAttempted) -> [String] {
        let intro = "3. Typing key. If you turned on typing, the Keychain held the \(TypedKeychainName.label) (\(typingKeyService)). It opens the words you typed."
        guard choice == .removeEverything else {
            return ["3. Typing key. If you turned on typing, the Keychain holds the \(TypedKeychainName.label) (\(typingKeyService)). Your kept history needs it: without it, the words you typed can't be read. Leave it unless you delete your history too."]
        }
        let byHand = ["   " + typingKeyCommand,
                      "   Keychain Access and Terminal may not list a key made by a newer DayDream. Until the key is gone, a copy of your history (for example in a Time Machine backup) together with the key can still show the words you typed."]
        switch result {
        case .deleted:
            return [intro + " DayDream deleted it from this Mac's Keychain. A Time Machine backup of your login keychain may still hold a copy, next to copies of your history (step 6)."]
        case .failed(let reason):
            return [intro + " DayDream couldn't delete it (\(reason)). Delete it yourself: open Keychain Access, search for \(typingKeyService), and delete what you find. Or run this until it says the item could not be found:"] + byHand
        case .notAttempted:
            return [intro + " Delete it: open Keychain Access, search for \(typingKeyService), and delete what you find. Or run this until it says the item could not be found:"] + byHand
        }
    }
    /// The copies Connect and Disconnect keep of each AI app's settings file (`AIAppConnect.backupFile`).
    public static var aiAppBackups: [String] { AIAppConnect.apps.map { "~/" + $0.configPath + AIAppConnect.backupSuffix } }

    /// The same steps as `text`, one plain line each and without Terminal commands, for the screen
    /// after uninstalling (Copy Steps copies `text`). One line per numbered step of `text`, in order.
    public static func plain(choice: UninstallChoice, typingKey: UninstallTypingKeyResult = .notAttempted) -> [String] {
        var steps = ["Remove DayDream from Accessibility, Input Monitoring and Automation in System Settings › Privacy & Security.",
                     "If you added a cloud summary key, delete it in Keychain Access (search for \(keychainServices[0]))."]
        switch (choice, typingKey) {
        case (.keepHistory, _):
            steps.append("If you turned on typing, keep the typing key in Keychain Access: your kept history needs it to show what you typed.")
        case (.removeEverything, .deleted):
            steps.append("DayDream deleted the typing key. A Time Machine backup of your keychain may still hold a copy.")
        case (.removeEverything, .failed):
            steps.append("DayDream couldn't delete the typing key. Delete it in Keychain Access (search for \(typingKeyService)); it opens the words you typed.")
        case (.removeEverything, .notAttempted):
            steps.append("If you turned on typing, delete the typing key in Keychain Access (search for \(typingKeyService)); it opens the words you typed.")
        }
        steps.append("Remove DayDream from any AI app you connected, and delete its settings copies ending in \(AIAppConnect.backupSuffix): they can hold keys for other tools.")
        steps.append("If DayDream is still in System Settings › General › Login Items, remove it.")
        if choice == .removeEverything {
            steps.append("Your own backups and Time Machine may still hold copies of your history. Delete those yourself.")
        }
        return steps
    }

    /// Plain text to copy: what is left to do by hand.
    public static func text(choice: UninstallChoice, typingKey: UninstallTypingKeyResult = .notAttempted) -> String {
        var lines = ["Finish removing DayDream", "",
                     "1. Permissions. Open System Settings > Privacy & Security. In Accessibility, Input Monitoring and Automation, select DayDream (and Daydream or \(DaydreamIdentity.legacyDataFolder), if listed) and click the minus button. Or run these in Terminal:"]
        lines += tccutilCommands.map { "   " + $0 }
        lines += ["", "2. Cloud summary key. If you added one, open Keychain Access, search for \(keychainServices.joined(separator: " and ")), and delete what you find. Or run:"]
        lines += keychainCommands.map { "   " + $0 }
        lines += [""] + typingKeyText(choice: choice, result: typingKey)
        lines += ["", "4. AI apps. If you connected an AI app to DayDream, remove DayDream from that app's settings. When DayDream connected or disconnected an app, it saved a copy of that app's settings file next to it, ending in \(AIAppConnect.backupSuffix). The copy can hold keys for the app's other tools. Delete any you find:"]
        lines += aiAppBackups.map { "   " + $0 }
        lines += ["", "5. Login items. If DayDream still appears in System Settings > General > Login Items, remove it."]
        if choice == .removeEverything {
            lines += ["", "6. Backups. Backups you saved yourself, Time Machine backups and local snapshots may still hold copies of your history. DayDream doesn't touch them."]
        } else {
            lines += ["", "Your history and settings are still on this Mac. To remove them later, follow the steps in docs/uninstall.md."]
        }
        lines += ["", "Full steps: https://github.com/getnorthlight/daydream/blob/main/docs/uninstall.md"]
        return lines.joined(separator: "\n")
    }
}

/// What Settings › Setup needs from the app to uninstall. The app's is `DaydreamUninstaller`
/// (Sources/MacMemApp/UninstallService.swift); previews and checks use fakes.
@MainActor public protocol UninstallPerforming: AnyObject {
    /// Why uninstalling must wait (a replacement, backup, restore or import is running), or nil.
    func blocker() -> String?
    func preview(_ choice: UninstallChoice) -> Result<UninstallPlan, UninstallRefusal>
    /// Removes the plan's items and the login item. Recording is already paused.
    func perform(_ plan: UninstallPlan) -> UninstallReport
    /// Quits DayDream. What the app writes back while quitting is removed on the way out.
    func quit()
}

public enum UninstallOutcome: Equatable {
    /// Nothing was removed, and why.
    case refused(String)
    /// Something was removed (always the app itself, first).
    case done(UninstallPlan, UninstallReport)
}

/// The order Setup's Uninstall button follows. Checked by scripts/uninstall-plan-checks.swift.
public enum UninstallSession {
    /// 1. Refuse while a replacement, backup, restore or import is running.
    /// 2. Pause recording.
    /// 3. Plan again, so the list matches the disk right now.
    /// 4. Remove.
    @MainActor public static func run(_ choice: UninstallChoice, canUninstall: () -> Bool, pause: () -> Void,
                                      performer: any UninstallPerforming) -> UninstallOutcome {
        guard canUninstall() else {
            return .refused("Finish or roll back the recorder replacement first. Nothing was removed.")
        }
        if let blocker = performer.blocker() { return .refused(blocker) }
        pause()
        switch performer.preview(choice) {
        case .failure(let refusal): return .refused(refusal.message)
        case .success(let plan):
            let report = performer.perform(plan)
            if let stopped = report.stopped { return .refused(stopped) }
            return .done(plan, report)
        }
    }
}
