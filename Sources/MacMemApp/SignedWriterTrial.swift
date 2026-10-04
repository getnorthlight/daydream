#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
import AppKit
import Foundation
import Darwin
import WriterBackend

/// Explicit final-host synthetic acceptance. The launch router must select this
/// BEFORE constructing MemoryViewModel, update services, capture or any store.
@MainActor enum SignedWriterTrial {
    private static var started = false
    static func requested(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains("--signed-writer-acceptance")
    }

    struct Output: Encodable {
        let schema = "daydream-signed-host-trial/v1"
        let passed: Bool
        let captureConstructed = false
        let storeOpened = false
        let providerActivated = false
        let modelDownloaded = false
        let receipt: SignedWriterAcceptance.Receipt?
        let failure: String?
    }

    /// Never creates a home, imports history or searches arbitrary model paths.
    /// Root stages a hash-verified existing model under this private test home.
    static func checkedHome(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        guard let path = environment["MAC_MEM_HOME"],
              path.hasPrefix("/private/tmp/daydream-trial-"),
              !path.contains("\0") else { throw WriterFailure.denied }
        let home = URL(fileURLWithPath: path, isDirectory: true)
        guard let resolved = realpath(path, nil) else { throw WriterFailure.denied }
        defer { free(resolved) }
        // Foundation rewrites /private/tmp to the display alias /tmp on macOS.
        // POSIX realpath checks the physical path without accepting that alias.
        guard home.path == path, home.deletingLastPathComponent().path == "/private/tmp",
              String(cString: resolved) == path else { throw WriterFailure.denied }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw WriterFailure.denied }
        let marker = home.appendingPathComponent("TRIAL-ONLY")
        let fd = open(marker.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw WriterFailure.denied }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, info.st_size == 15 else { throw WriterFailure.denied }
        var bytes = [UInt8](repeating: 0, count: 15)
        let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count == 15, String(decoding: bytes, as: UTF8.self) == "synthetic-only\n" else { throw WriterFailure.denied }
        return home
    }

    static func run() async {
        guard requested(), !started else { return }
        started = true
        defer { NSApp.terminate(nil) }
        do {
            let home = try checkedHome()
            let destination = home.appendingPathComponent("signed-writer-receipt.json")
            // Reserve an exclusive output before inference. Never replace a prior
            // receipt or follow an output symlink after a failed/retried launch.
            let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw WriterFailure.denied }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            let output: Output
            do {
                let modelRoot = home.appendingPathComponent("Models", isDirectory: true)
                let receipt = try await withThrowingTaskGroup(of: SignedWriterAcceptance.Receipt.self) { group in
                    group.addTask { try await SignedWriterAcceptance.run(modelRoot: modelRoot) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 180_000_000_000)
                        throw WriterFailure.unavailable
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else { throw WriterFailure.unavailable }
                    return result
                }
                output = Output(passed: true, receipt: receipt, failure: nil)
            } catch {
                output = Output(passed: false, receipt: nil, failure: String(describing: error))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try handle.write(contentsOf: encoder.encode(output))
            try handle.synchronize()
        } catch {
            // No valid private test home or output means no permission to write a
            // report elsewhere. Emit only the error category, never supplied paths.
            fputs("Signed writer trial rejected: \(String(describing: error))\n", stderr)
        }
    }
}

#endif
