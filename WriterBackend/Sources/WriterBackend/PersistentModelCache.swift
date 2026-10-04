import Foundation
import Darwin
import CryptoKit

public typealias ModelRangeChunks = @Sendable (URL, Int64) async throws -> AsyncThrowingStream<Data, Error>

/// fix/sx-engine-battery: a full-length download whose hash didn't match. Its partial file is already deleted, so
/// Try Again starts over (SummaryProblem.badDownload).
public struct DownloadDamaged: Error, Equatable { public init() {} }

/// fix/sx-engine-battery: the model file is hashed once per activation, not once per load. After a full SHA-256 pass the
/// file's identity (device, inode, size, change and modification times) is kept in memory; a later check of the same
/// path only reads its metadata (one lstat) and hashes again only when that identity moved. The change time can't be set
/// by a program, so a file rewritten in place (even with its old modification time put back) is hashed again.
public enum ModelIdentity {
    struct Identity: Equatable { let device: Int64, inode: UInt64, size: Int64, modified: timespec, changed: timespec
        static func == (a: Identity, b: Identity) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
                && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
        }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var verified: [String: (identity: Identity, hash: String)] = [:]
    nonisolated(unsafe) private static var passes = 0
    /// Full-file SHA-256 passes over pinned model weights in this process (checks and the energy sim read it).
    public static var fullHashes: Int { lock.lock(); defer { lock.unlock() }; return passes }
    static func identity(_ url: URL) throws -> Identity {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw WriterFailure.integrity }
        return Identity(device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size), modified: info.st_mtimespec, changed: info.st_ctimespec)
    }
    /// Whether `url` is, by its metadata alone, the very file that last hashed to `hash`.
    public static func unchanged(_ url: URL, hash: String) -> Bool {
        guard let now = try? identity(url) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let known = verified[url.path] else { return false }
        return known.hash == hash && known.identity == now
    }
    /// Checks `url` is exactly `bytes` long and hashes to `hash`: metadata only when this file was hashed already and
    /// hasn't moved since, else one full pass (recorded on success, forgotten on failure).
    public static func verify(_ url: URL, bytes: Int64, hash: String, checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        let before = try identity(url)
        guard before.size == bytes else { forget(url); throw WriterFailure.integrity }
        if unchanged(url, hash: hash) { return }
        lock.lock(); passes += 1; lock.unlock()
        do { try CompatibleInstallation.verify(url, bytes: bytes, hash: hash, checkCancellation: checkCancellation) }
        catch { forget(url); throw error }
        // Written to while it was read: nothing is recorded, and the next check hashes it again.
        guard (try? identity(url)) == before else { forget(url); throw WriterFailure.integrity }
        lock.lock(); verified[url.path] = (before, hash); lock.unlock()
    }
    public static func forget(_ url: URL) { lock.lock(); verified.removeValue(forKey: url.path); lock.unlock() }
}

/// fix/model-download: how long the model download keeps trying by itself. Waits start at `firstWait` and double up to
/// `maximumWait`; any new byte resets them. It stops only after `giveUpAfter` seconds without a new byte. `now` is the
/// Mac's uptime, which doesn't run while it sleeps, so a closed lid never uses up the patience. Checks pass a fake.
public struct DownloadPatience: Sendable {
    public var firstWait: TimeInterval
    public var maximumWait: TimeInterval
    public var giveUpAfter: TimeInterval
    public var freshStartsAfterDamage: Int
    public var now: @Sendable () -> TimeInterval
    public var sleep: @Sendable (TimeInterval) async throws -> Void
    public init(firstWait: TimeInterval = 1, maximumWait: TimeInterval = 30, giveUpAfter: TimeInterval = 15 * 60, freshStartsAfterDamage: Int = 1,
                now: @escaping @Sendable () -> TimeInterval = {ProcessInfo.processInfo.systemUptime},
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))}) {
        self.firstWait = firstWait; self.maximumWait = maximumWait; self.giveUpAfter = giveUpAfter
        self.freshStartsAfterDamage = freshStartsAfterDamage; self.now = now; self.sleep = sleep
    }
    public static let standard = DownloadPatience()
}

/// Weights only. No runtime URLs, extraction, enrollment or activation.
public enum PersistentModelCache {
    public static let version = "qwen3.5-4b-q4km-720bb031-v1"
    public static func knownRoots(applicationSupport: URL) -> [URL] {
        // DayDream's own folder first (new downloads go there), then the pre-rename
        // "Mac Mem" folder. "Daydream" is the same folder on a case-insensitive disk.
        ["DayDream/Models", "Mac Mem/Models", "Daydream/Models"].map { applicationSupport.appendingPathComponent($0) }
    }
    public static func searchRoots(for root: URL) -> [URL] {
        let known = knownRoots(applicationSupport:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0])
        return known.contains(root) ? [root] + known.filter {$0 != root} : [root]
    }
    public static func discover(in roots: [URL]) async throws -> URL? {
        guard let asset = WriterCandidates.recommended?.asset else { throw WriterFailure.incompatible }
        return try await discover(asset: asset, roots: roots)
    }
    static func discover(asset: PinnedAsset, roots: [URL]) async throws -> URL? {
        for root in roots {
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            try directory(root)
            let file = root.appendingPathComponent(asset.sha256 + ".model")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            // A corrupt known candidate is not permission to silently download another copy.
            close(try regular(file))   // owner, one link, not writable by others
            try ModelIdentity.verify(file, bytes: asset.bytes, hash: asset.sha256)
            return file
        }
        return nil
    }
    public static func acquire(in root: URL, priorRoots: [URL], chunks: ModelRangeChunks = {try await AssetDownload.chunks(from:$0,offset:$1)},
        patience: DownloadPatience = .standard, progress: @escaping @Sendable (InstallState) -> Void = {_ in}) async throws -> URL {
        guard let plan = WriterCandidates.recommended else { throw WriterFailure.incompatible }
        let known = knownRoots(applicationSupport: FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0])
        let sharedRoot = known.contains(root) ? known[0] : root
        return try await acquire(asset: plan.asset, root: sharedRoot, priorRoots: [root] + priorRoots,
            minimumMemory: plan.minimumMemory, chunks: chunks, patience: patience, progress: progress)
    }
    static func acquire(asset: PinnedAsset, root: URL, priorRoots: [URL], minimumMemory: UInt64 = 0,
        chunks: ModelRangeChunks, patience: DownloadPatience = .standard, progress: @escaping @Sendable (InstallState) -> Void = {_ in}) async throws -> URL {
        try Task.checkCancellation()
        guard asset.bytes > 0, asset.sha256.count == 64, asset.sha256.allSatisfy({$0.isHexDigit}) else {throw WriterFailure.integrity}
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try directory(root)
        let lock = try regular(root.appendingPathComponent("model-cache.lock"), create: true)
        defer {close(lock)}
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {throw WriterFailure.busy}
        defer {flock(lock, LOCK_UN)}
        if let cached = try await discover(asset: asset, roots: [root] + priorRoots.filter {$0 != root}) {progress(.ready);return cached}
        let capacity = try WriterCapacity.read(at: root)
        guard capacity.memory >= minimumMemory else {throw WriterFailure.capacity}
        let partial = root.appendingPathComponent(asset.sha256 + ".partial")
        var fd = try regular(partial, create: true)
        var info = stat();guard fstat(fd, &info) == 0 else {close(fd);throw WriterFailure.integrity}
        // A partial longer than the model can't be resumed: start it over.
        if Int64(info.st_size) > asset.bytes {
            close(fd);unlink(partial.path)
            fd = try regular(partial, create: true)
            guard fstat(fd, &info) == 0 else {close(fd);throw WriterFailure.integrity}
        }
        var handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {try? handle.close()}
        var received = Int64(info.st_size)
        guard capacity.freeBytes >= asset.bytes - received + 1_048_576 else {throw WriterFailure.capacity}
        try handle.seekToEnd()
        // fix/model-download: a dropped network, a Wi-Fi change, sleep, a stall or a busy server never stops the download
        // by itself. The same partial file is resumed (Range) after a short wait that grows, for as long as `patience`
        // allows without a single new byte; only then, or at once for a 4xx, a full disk or a refused redirect, does it
        // stop. A whole file with the wrong hash is downloaded once more from the start before it's called damaged.
        var waits = 0, freshStarts = 0
        var lastProgress = patience.now()
        do {
            while true {
                do {
                    if received < asset.bytes {
                        progress(.downloading(received, asset.bytes))
                        do {
                            for try await chunk in try await chunks(asset.url, received) {
                                try Task.checkCancellation()
                                guard chunk.count <= 1_048_576, Int64(chunk.count) <= asset.bytes - received else {throw WriterFailure.integrity}
                                do { try handle.write(contentsOf: chunk) } catch { throw Self.writeFailure(error) }
                                received += Int64(chunk.count)
                                if waits > 0 {waits = 0}
                                lastProgress = patience.now()
                                progress(.downloading(received, asset.bytes))
                            }
                        } catch DownloadInterruption.rangeIgnored {
                            // The server can't resume: the partial file starts over, at once.
                            try handle.truncate(atOffset: 0);received = 0
                            progress(.downloading(0, asset.bytes))
                            continue
                        }
                        try Task.checkCancellation()
                        guard received == asset.bytes else {throw DownloadInterruption.shortBody}
                    }
                    try Task.checkCancellation();try handle.synchronize()
                    do { try verify(partial, asset: asset) }
                    catch WriterFailure.integrity {
                        // fix/sx-engine-battery: the whole file arrived and its hash is wrong. Resuming it can never help, so
                        // it is deleted. fix/model-download: one more download from the start, then Try Again starts over.
                        var current = stat()
                        if lstat(partial.path, &current) == 0, current.st_ino == info.st_ino, current.st_dev == info.st_dev { unlink(partial.path) }
                        guard freshStarts < patience.freshStartsAfterDamage else {throw DownloadDamaged()}
                        freshStarts += 1
                        try? handle.close()
                        fd = try regular(partial, create: true)
                        guard fstat(fd, &info) == 0 else {close(fd);throw WriterFailure.integrity}
                        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                        received = 0;waits = 0;lastProgress = patience.now()
                        progress(.downloading(0, asset.bytes))
                        continue
                    }
                    break
                } catch {
                    if error is CancellationError || Task.isCancelled {throw CancellationError()}
                    guard AssetDownload.isTransient(error) else {throw error}
                    let waited = patience.now() - lastProgress
                    guard waited < patience.giveUpAfter else {throw error}
                    var delay = min(patience.maximumWait, patience.firstWait * pow(2, Double(waits)))
                    if case DownloadInterruption.status(_, let retryAfter?) = error {delay = max(delay, min(retryAfter, 120))}
                    delay = min(delay, max(0, patience.giveUpAfter - waited))
                    waits += 1
                    // A partial that may still be good is written out before the wait; the next try resumes it.
                    try? handle.synchronize()
                    try await patience.sleep(delay)
                    try Task.checkCancellation()
                }
            }
            try Task.checkCancellation()
            var current = stat()
            guard lstat(partial.path, &current) == 0, current.st_ino == info.st_ino, current.st_dev == info.st_dev else {throw WriterFailure.integrity}
            let final = root.appendingPathComponent(asset.sha256 + ".model")
            // Same-volume atomic, exclusive commit. Never replace an existing model.
            guard renamex_np(partial.path, final.path, UInt32(RENAME_EXCL)) == 0 else {throw WriterFailure.integrity}
            let directoryFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else {throw WriterFailure.integrity}
            defer {close(directoryFD)}
            guard fsync(directoryFD) == 0 else {throw WriterFailure.integrity}
            progress(.ready);return final
        } catch {
            try? handle.synchronize()
            progress(error is CancellationError ? .cancelled : .failed)
            throw error // A partial that may still be good is kept for Try Again (resumed), never loaded.
        }
    }
    /// fix/model-download: a write the disk refused because it's full is the no-space problem, not a stopped download.
    static func writeFailure(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError {return WriterFailure.capacity}
        if let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError) ?? (ns.domain == NSPOSIXErrorDomain ? ns : nil),
           posix.domain == NSPOSIXErrorDomain, posix.code == Int(ENOSPC) || posix.code == Int(EDQUOT) {return WriterFailure.capacity}
        return error
    }
    static func directory(_ root: URL) throws {
        try CompatibleInstallation.privateDirectory(root)
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {throw WriterFailure.denied}
    }
    static func regular(_ url: URL, create: Bool = false) throws -> Int32 {
        let fd = open(url.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (create ? O_CREAT : 0), 0o600)
        guard fd >= 0 else {throw WriterFailure.integrity}
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o022 == 0 else {close(fd);throw WriterFailure.denied}
        return fd
    }
    static func verify(_ url: URL, asset: PinnedAsset) throws {
        let fd = try regular(url)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true);defer {try? handle.close()}
        var info = stat();guard fstat(fd, &info) == 0, info.st_size == asset.bytes else {throw WriterFailure.integrity}
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation();digest.update(data: data)
        }
        guard digest.finalize().map({String(format:"%02x",$0)}).joined() == asset.sha256 else {throw WriterFailure.integrity}
    }
}
