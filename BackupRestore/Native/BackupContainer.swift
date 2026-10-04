import Foundation
import CryptoKit
import Darwin
import MemoryCore

public enum BackupFailure: Error { case invalid, limit, cancelled, busy, worker }

/// The whole history fits (gold G29: these were 128 MiB and 30 seconds, about two weeks of use).
public struct BackupLimits {
    public var bytes = CanonicalBackupBounds.fileBytes
    public var files = 1024
    public var seconds: Double = CanonicalBackupBounds.seconds
    public init() {}
}

/// Cooperative checks complement the process supervisor's hard deadline.
public final class BackupBudget {
    let limits: BackupLimits
    let deadline: Double
    let cancelled: () -> Bool
    var used = 0
    public init(limits: BackupLimits = BackupLimits(), cancelled: @escaping () -> Bool = { false }) {
        self.limits = limits; self.cancelled = cancelled
        deadline = ProcessInfo.processInfo.systemUptime + limits.seconds
    }
    func check(_ bytes: Int = 0) throws {
        if cancelled() { throw BackupFailure.cancelled }
        used += bytes
        guard used <= limits.bytes, ProcessInfo.processInfo.systemUptime < deadline else { throw BackupFailure.limit }
    }
}

/// A descriptor pins every ancestor. Never follow a linked archive component.
final class BackupDirectory {
    let fd: Int32
    let url: URL
    init(_ url: URL, create: Bool = false) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else { throw BackupFailure.invalid }
        self.url = url
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw BackupFailure.invalid }
        do {
            let parts = url.pathComponents.filter { $0 != "/" }
            guard !parts.isEmpty else { throw BackupFailure.invalid }
            for (index, part) in parts.enumerated() {
                guard part != ".", part != "..", !part.contains("\0") else { throw BackupFailure.invalid }
                if create && index == parts.count - 1 {
                    guard mkdirat(current, part, 0o700) == 0 else { throw BackupFailure.invalid }
                }
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw BackupFailure.invalid }
                close(current); current = next
            }
            var info = stat()
            guard fstat(current, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw BackupFailure.invalid }
            fd = current
        } catch { close(current); throw error }
    }
    deinit { close(fd) }
    static func valid(_ name: String) -> Bool {
        name == "memory.sqlite" || name == "manifest.json" || name.range(of: "^asset-[a-f0-9]{64}$", options: .regularExpression) != nil
    }
    /// Hands the file's bytes to `each` a piece at a time, never holding the whole file (a backup of a long history
    /// is far larger than memory should hold twice). Same checks as ever: a single-link regular file, at most `maximum`.
    func stream(_ name: String, maximum: Int, budget: BackupBudget, _ each: (UnsafeRawBufferPointer) throws -> Void) throws -> Int {
        guard Self.valid(name) else { throw BackupFailure.invalid }
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw BackupFailure.invalid }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= maximum else { throw BackupFailure.invalid }
        var total = 0, buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            try budget.check()
            let n = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, min($0.count, maximum - total + 1)) }
            guard n >= 0 else { throw BackupFailure.invalid }
            if n == 0 { break }
            guard total + n <= maximum else { throw BackupFailure.limit }
            try buffer.withUnsafeBytes { try each(UnsafeRawBufferPointer(rebasing: $0.prefix(n))) }
            total += n
        }
        guard total == info.st_size else { throw BackupFailure.invalid }
        return total
    }
    func read(_ name: String, maximum: Int, budget: BackupBudget) throws -> Data {
        var result = Data()
        _ = try stream(name, maximum: maximum, budget: budget) { result.append(contentsOf: $0) }
        return result
    }
    /// Size and SHA-256 of a file, streamed.
    func digest(_ name: String, maximum: Int, budget: BackupBudget) throws -> (bytes: Int, sha256: String) {
        var hash = SHA256()
        let bytes = try stream(name, maximum: maximum, budget: budget) { hash.update(bufferPointer: $0) }
        return (bytes, NativeBackup.hex(hash.finalize()))
    }
    /// Copies a file into `target` (a new file there), hashing the very bytes it copies.
    func copy(_ name: String, maximum: Int, to target: BackupDirectory, budget: BackupBudget) throws -> (bytes: Int, sha256: String) {
        var hash = SHA256()
        var bytes = 0
        try target.create(name, budget: budget) { write in
            bytes = try stream(name, maximum: maximum, budget: budget) { piece in hash.update(bufferPointer: piece); try write(piece) }
        }
        return (bytes, NativeBackup.hex(hash.finalize()))
    }
    func write(_ name: String, data: Data, budget: BackupBudget) throws {
        try create(name, budget: budget) { write in try data.withUnsafeBytes { try write($0) } }
    }
    /// A new private file (never an existing one or a link), filled by `fill`, then synced with its folder.
    private func create(_ name: String, budget: BackupBudget, _ fill: ((UnsafeRawBufferPointer) throws -> Void) throws -> Void) throws {
        guard Self.valid(name) else { throw BackupFailure.invalid }
        let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw BackupFailure.invalid }
        defer { close(file) }
        try fill { bytes in
            var offset = 0
            while offset < bytes.count {
                try budget.check()
                let n = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), min(1 << 20, bytes.count - offset))
                guard n > 0 else { throw BackupFailure.invalid }; offset += n
            }
        }
        guard fsync(file) == 0, fsync(fd) == 0 else { throw BackupFailure.invalid }
    }
    /// Removes this folder, which this run made, and what this run put in it (the backup's own names and SQLite's
    /// sidecars): a failed export leaves nothing half-made, so trying again with the same name works. Anything else
    /// found in it keeps the folder as it is.
    func removeMade() {
        guard let names = try? names() else { return }
        let ours = names.filter { Self.valid($0) || ["memory.sqlite-journal", "memory.sqlite-wal", "memory.sqlite-shm"].contains($0) }
        guard ours.count == names.count else { return }
        for name in ours { unlinkat(fd, name, 0) }
        guard let parent = try? BackupDirectory(url.deletingLastPathComponent()), (try? checkPath()) != nil else { return }
        unlinkat(parent.fd, url.lastPathComponent, AT_REMOVEDIR)
    }
    func names() throws -> Set<String> {
        let copy = dup(fd)
        guard let stream = fdopendir(copy) else { close(copy); throw BackupFailure.invalid }
        defer { closedir(stream) }
        rewinddir(stream)
        var names = Set<String>()
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.insert(name) }
            guard names.count <= 1026 else { throw BackupFailure.limit }
        }
        return names
    }
    /// SQLite only gets private staging paths, after the descriptor-loaded bytes
    /// are validated. Check the pinned directory has not been renamed/replaced.
    func checkPath() throws {
        let fresh = try BackupDirectory(url)
        var a = stat(), b = stat()
        guard fstat(fd, &a) == 0, fstat(fresh.fd, &b) == 0, a.st_ino == b.st_ino, a.st_dev == b.st_dev else { throw BackupFailure.invalid }
    }
}

public struct BackupManifest: Codable {
    public var format: String
    public var build: String
    public var version: String
    public var encrypted: Bool
    public var audit: CanonicalBackupAudit
    public var files: [Entry]
    public struct Entry: Codable { public var name: String; public var bytes: Int; public var sha256: String }
}
public struct BackupSeal: Codable { public var manifestSHA256: String; public var manifest: BackupManifest }
public struct BackupPrepared: Codable {
    public var staging: String
    public var databaseSHA256: String
    public var preview: CanonicalRestorePreview
}

public enum NativeBackup {
    public static func hash(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    static func asset(_ hash: String) throws -> String {
        guard hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw BackupFailure.invalid }
        return "asset-" + hash
    }
    public static func export(source: MemoryStore, destination: URL, build: String, version: String,
                              budget: BackupBudget = BackupBudget()) throws -> BackupSeal {
        try budget.check()
        let output = try BackupDirectory(destination, create: true)
        do { return try export(source: source, output: output, build: build, version: version, budget: budget) }
        catch { output.removeMade(); throw error }
    }
    private static func export(source: MemoryStore, output: BackupDirectory, build: String, version: String, budget: BackupBudget) throws -> BackupSeal {
        let destination = output.url
        // One moment for the whole export: the projection is checked against the same retention cut-off it was made
        // with, and the core remembers each record's privacy answer for it instead of working it out again.
        let now = Date()
        // Core writes its allowlisted projection, never a raw live-file copy.
        let audit: CanonicalBackupAudit = try {
            let projected = try MemoryStore(home: destination, writable: true, automaticallySyncSearch: false)
            let exported = try source.exportCanonicalSnapshot(to: projected, now: now)
            var inspected = try projected.inspectCanonicalSnapshot(now: now)
            inspected.sourceFence = exported.sourceFence
            inspected.excluded = exported.excluded
            return inspected
        }() // closes projection before reading its SQLite file
        try output.checkPath()
        guard try output.names() == ["memory.sqlite"], let fence = audit.sourceFence else { throw BackupFailure.invalid }
        var entries = [BackupManifest.Entry]()
        let database = try output.digest("memory.sqlite", maximum: budget.limits.bytes, budget: budget)
        try budget.check(database.bytes)
        entries.append(.init(name: "memory.sqlite", bytes: database.bytes, sha256: database.sha256))
        guard audit.assets.count + 1 <= budget.limits.files else { throw BackupFailure.limit }
        // Every asset from one pass over the history, exactly the projection's list, in its order (no pass without any).
        var written = [String]()
        if !audit.assets.isEmpty { try source.canonicalBackupAssets(expected: fence, now: now) { digest, data in
            try budget.check()
            guard audit.assets.contains(digest), hash(data) == digest else { throw BackupFailure.invalid }
            try budget.check(data.count)
            let name = try asset(digest)
            try output.write(name, data: data, budget: budget)
            entries.append(.init(name: name, bytes: data.count, sha256: digest))
            written.append(digest)
        } }
        guard written == audit.assets else { throw BackupFailure.invalid }
        var verified = audit; verified.assetsVerified = true
        let manifest = BackupManifest(format: "macmem-native-backup-v1", build: build, version: version, encrypted: false, audit: verified, files: entries)
        let bytes = try encoded(manifest)
        guard bytes.count <= 256 * 1024 else { throw BackupFailure.limit }
        // Seal while the same core fence is held, including policy/deletions.
        try source.withSnapshotCoordination { current in
            guard current == fence else { throw BackupFailure.invalid }
            try output.write("manifest.json", data: bytes, budget: budget)
        }
        return BackupSeal(manifestSHA256: hash(bytes), manifest: manifest)
    }
    /// Checks the manifest, every name, size and hash (streamed, nothing held), then copies each file into `staging`,
    /// checking the hash of the very bytes copied again. Nothing is created before every check has passed once.
    static func load(_ backup: URL, pin: String, staging: URL, budget: BackupBudget) throws -> (BackupManifest, BackupDirectory) {
        let directory = try BackupDirectory(backup)
        let bytes = try directory.read("manifest.json", maximum: 256 * 1024, budget: budget)
        guard hash(bytes) == pin else { throw BackupFailure.invalid }
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: bytes)
        // Canonical encoding rejects duplicate/unknown keys and ambiguous JSON.
        guard try encoded(manifest) == bytes, manifest.format == "macmem-native-backup-v1", !manifest.encrypted,
              !manifest.build.isEmpty, !manifest.version.isEmpty, manifest.audit.schema == "macmem-canonical-v1",
              manifest.audit.capture == "off", manifest.audit.assetsVerified,
              manifest.files.count <= budget.limits.files else { throw BackupFailure.invalid }
        let names = Set(manifest.files.map(\.name))
        let expected = Set(try manifest.audit.assets.map { try asset($0) }).union(["memory.sqlite"])
        guard names == expected, names.count == manifest.files.count,
              Set(manifest.audit.assets).count == manifest.audit.assets.count,
              try directory.names() == names.union(["manifest.json"]) else { throw BackupFailure.invalid }
        for entry in manifest.files {
            guard entry.bytes >= 0, entry.bytes <= budget.limits.bytes else { throw BackupFailure.limit }
            try budget.check(entry.bytes)
            let file = try directory.digest(entry.name, maximum: entry.bytes, budget: budget)
            guard file.bytes == entry.bytes, file.sha256 == entry.sha256,
                  entry.name == "memory.sqlite" || entry.name == "asset-" + entry.sha256 else { throw BackupFailure.invalid }
        }
        let target = try BackupDirectory(staging, create: true)
        for entry in manifest.files {
            let file = try directory.copy(entry.name, maximum: entry.bytes, to: target, budget: budget)
            guard file.bytes == entry.bytes, file.sha256 == entry.sha256 else { throw BackupFailure.invalid }
        }
        return (manifest, target)
    }
    public static func prepare(source: MemoryStore, backup: URL, manifestSHA256: String, staging: URL,
                               budget: BackupBudget = BackupBudget()) throws -> BackupPrepared {
        // All bytes, names, sizes and hashes pass before any untrusted SQLite open.
        let (manifest, directory) = try load(backup, pin: manifestSHA256, staging: staging, budget: budget)
        try directory.checkPath()
        // Read-only semantic inspection before writable core initialization. One moment for inspecting and reconciling
        // (the core remembers each record's privacy answer for it); the preview's own expiry still starts when it is made.
        let now = Date()
        let inspected = try MemoryStore(home: staging, automaticallySyncSearch: false).inspectCanonicalSnapshot(now: now)
        guard inspected.fence == manifest.audit.fence, inspected.counts == manifest.audit.counts,
              inspected.assets == manifest.audit.assets else { throw BackupFailure.invalid }
        try budget.check()
        let preview: CanonicalRestorePreview = try {
            let candidate = try MemoryStore(home: staging, writable: true, automaticallySyncSearch: false)
            _ = try source.reconcileCanonicalSnapshot(candidate, expected: source.coreSnapshotFence(), now: now)
            try budget.check()
            return try source.prepareCanonicalRestore(candidate)
        }()
        let digest = try directory.digest("memory.sqlite", maximum: budget.limits.bytes, budget: budget).sha256
        return BackupPrepared(staging: staging.path, databaseSHA256: digest, preview: preview)
    }
    public static func confirm(source: MemoryStore, prepared: BackupPrepared, confirmed: Bool,
                               budget: BackupBudget = BackupBudget()) throws -> CanonicalRestoreReceipt {
        guard confirmed else { throw BackupFailure.invalid }
        let staging = URL(fileURLWithPath: prepared.staging)
        let directory = try BackupDirectory(staging)
        guard try directory.names().allSatisfy({ $0 == "memory.sqlite" || $0.range(of: "^asset-[a-f0-9]{64}$", options: .regularExpression) != nil }) else { throw BackupFailure.invalid }
        guard try directory.digest("memory.sqlite", maximum: budget.limits.bytes, budget: budget).sha256 == prepared.databaseSHA256 else { throw BackupFailure.invalid }
        try directory.checkPath()
        let candidate = try MemoryStore(home: staging, automaticallySyncSearch: false)
        // One moment for the whole confirmation (the time the person confirmed): inspection and the core's own checks.
        let now = Date()
        let audit = try candidate.inspectCanonicalSnapshot(now: now)
        try budget.check()
        if try source.coreSnapshotFence() != prepared.preview.authority {
            // Core returns an existing receipt on a lost-reply retry. Without a
            // receipt its fresh-revision check rejects before any merge.
            return try source.confirmCanonicalRestore(candidate, previewID: prepared.preview.id, confirmed: true, now: now)
        }
        // Current revision is fenced while installing exact hash-addressed assets
        // and committing. A failure can leave inert assets, never restored rows.
        return try source.withRestoreCoordination(expected: prepared.preview.authority) {
            // Core confirmation owns its transaction, so cannot nest it here.
            guard audit.fence == prepared.preview.candidate else { throw BackupFailure.invalid }
            return try stageAssets(source: source, directory: directory, audit: audit, budget: budget)
        }.then {
            try budget.check()
            return try source.confirmCanonicalRestore(candidate, previewID: prepared.preview.id, confirmed: true, now: now)
        }
    }
    private static func stageAssets(source: MemoryStore, directory: BackupDirectory, audit: CanonicalBackupAudit, budget: BackupBudget) throws -> Staged {
        let home = try BackupDirectory(source.home)
        if mkdirat(home.fd, "migration-attachments", 0o700) != 0 && errno != EEXIST { throw BackupFailure.invalid }
        let assets = try BackupDirectory(source.home.appendingPathComponent("migration-attachments"))
        for digest in audit.assets {
            let bytes = try directory.read(try asset(digest), maximum: 64 * 1024 * 1024, budget: budget)
            try budget.check(bytes.count)
            guard hash(bytes) == digest else { throw BackupFailure.invalid }
            // Publish only complete bytes. Existing owned content is preserved.
            let temporary = ".backup-" + UUID().uuidString
            let fd = openat(assets.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw BackupFailure.invalid }
            defer { close(fd); unlinkat(assets.fd, temporary, 0) }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    try budget.check()
                    let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), min(65536, buffer.count-offset))
                    guard n > 0 else { throw BackupFailure.invalid }; offset += n
                }
            }
            guard fsync(fd) == 0 else { throw BackupFailure.invalid }
            if linkat(assets.fd, temporary, assets.fd, digest, 0) != 0 && errno != EEXIST { throw BackupFailure.invalid }
            guard fsync(assets.fd) == 0 else { throw BackupFailure.invalid }
        }
        return Staged()
    }
    private struct Staged { func then<T>(_ work: () throws -> T) rethrows -> T { try work() } }
}
