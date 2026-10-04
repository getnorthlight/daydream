// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.

import Foundation
import Darwin

/// Build 4 plain-text typed words in a Mac Mem history that DayDream doesn't use.
///
/// When both the Mac Mem and the DayDream folder hold a history, the one-time move
/// (`DataHomeMigration`) leaves the Mac Mem folder as it is and DayDream uses its own. Launch
/// then never opens the Mac Mem history, so the build 4 rule "words are never kept in plain
/// text past the first launch of this build" (`settleLegacyTypedText`) never reached it.
/// This does that part for it, at launch: the plain-text words are deleted and stubs stay
/// (how many words, never which). It needs no key, and it seals nothing (that history has no
/// key in this app). Nothing else in that history changes, and it is opened for writing only
/// when it holds such words, while the old app isn't running and no recorder holds its lock.
public enum LegacyTypedScrub {
    public enum Outcome: Equatable, Sendable {
        /// Not the both-histories case, or nothing in plain text: the folder wasn't opened for writing.
        case notNeeded
        /// The old app or another recorder is using the folder; tried again at the next launch.
        case waiting
        /// This many plain-text rows became stubs.
        case stubbed(Int)
        case failed(String)
    }

    static let plainTextRows = "SELECT count(*) FROM records WHERE json_extract(body,'$.kind')='keyboard.text_input' AND coalesce(json_extract(body,'$.text'),'')<>'' AND json_extract(body,'$.typed') IS NULL"

    public static func run(applicationSupport: URL, legacyAppRunning: Bool, now: Date = Date()) -> Outcome {
        let legacy = applicationSupport.appendingPathComponent(DaydreamIdentity.legacyDataFolder, isDirectory: true)
        let current = applicationSupport.appendingPathComponent(DaydreamIdentity.dataFolder, isDirectory: true)
        // Only the case the move leaves alone for good: two plain folders you own, both with a history.
        guard DataHomeMigration.kind(legacy.path) == .ownedDirectory, DataHomeMigration.kind(current.path) == .ownedDirectory,
              DataHomeMigration.kind(legacy.appendingPathComponent("memory.sqlite").path) == .ownedFile,
              DataHomeMigration.kind(current.appendingPathComponent("memory.sqlite").path) != nil else { return .notNeeded }
        do {
            let reader = try MemoryStore(home: legacy, writable: false, automaticallySyncSearch: false)
            guard Int(try reader.rows(plainTextRows).first?.first ?? "0") ?? 0 > 0 else { return .notNeeded }
        } catch { return .notNeeded } // not a DayDream history this build can read: left as it is
        if legacyAppRunning { return .waiting }
        let lockPath = legacy.appendingPathComponent("capture.lock").path
        var lock: Int32 = -1
        if DataHomeMigration.kind(lockPath) != nil {
            lock = open(lockPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                if lock >= 0 { close(lock) }
                return .waiting
            }
        }
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }
        do {
            let store = try MemoryStore(home: legacy, writable: true, automaticallySyncSearch: false)
            return .stubbed(try store.migrateLegacyTypedText(seal: false, now: now))
        } catch {
            return .failed(String(describing: error))
        }
    }
}
