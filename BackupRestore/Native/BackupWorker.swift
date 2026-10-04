import Foundation
import Darwin
import MemoryCore

/// App creates one supervisor for its canonical store. The lease is retained
/// until waitUntilExit proves the child is gone, including after cancellation.
public final class BackupWorker {
    private let lock = NSLock()
    private var occupied = false
    public init() {}
    /// `seconds` is the hard deadline; the default is long enough for a backup of the whole history (it was 30 s).
    public func run(executable: URL, request: Data, seconds: Double = CanonicalBackupBounds.seconds,
                    cancelled: @escaping () -> Bool = { false }) throws -> Data {
        lock.lock()
        guard !occupied else { lock.unlock(); throw BackupFailure.busy }
        occupied = true; lock.unlock()
        defer { lock.lock(); occupied = false; lock.unlock() }
        guard request.count <= CanonicalBackupBounds.messageBytes, seconds > 0, seconds <= CanonicalBackupBounds.seconds else { throw BackupFailure.limit }
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = executable; child.arguments = []
        child.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        try child.run()
        let flags = fcntl(input.fileHandleForWriting.fileDescriptor, F_GETFL)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(output.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
        defer { try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var result = Data(), offset = 0, closed = false, failure: Error?
        var bytes = [UInt8](repeating: 0, count: 65536)
        repeat {
            if cancelled() { failure = BackupFailure.cancelled }
            if ProcessInfo.processInfo.systemUptime >= deadline { failure = BackupFailure.limit }
            if failure != nil { kill(child.processIdentifier, SIGKILL); break }
            if offset < request.count {
                let n = request.withUnsafeBytes { Darwin.write(input.fileHandleForWriting.fileDescriptor, $0.baseAddress!.advanced(by: offset), min(8192, request.count-offset)) }
                if n > 0 { offset += n }
                else if errno != EAGAIN && errno != EINTR { failure = BackupFailure.worker }
            } else if !closed { try? input.fileHandleForWriting.close(); closed = true }
            let n = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if n > 0 { result.append(contentsOf: bytes.prefix(n)) }
            if result.count > CanonicalBackupBounds.messageBytes { failure = BackupFailure.limit }
            if !child.isRunning && n <= 0 { break }
            Thread.sleep(forTimeInterval: 0.005)
        } while true
        if failure != nil && child.isRunning { kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
        if let failure { throw failure }
        guard child.terminationStatus == 0 else { throw BackupFailure.worker }
        return result
    }
}
