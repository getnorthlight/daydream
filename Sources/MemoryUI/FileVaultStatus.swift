import Foundation

/// Whether FileVault is on, read with `/usr/bin/fdesetup isactive` (exit 0: on, 1: off). No prompt and no
/// administrator rights. Setup shows `DaydreamSetupText.fileVault` only when this reads off, so the line is never
/// shown on a Mac where it isn't true. Blocking: run it off the main thread (`current()`).
public enum FileVaultStatus {
    public static let tool = "/usr/bin/fdesetup"

    /// true: on, false: off, nil: unknown (the tool is missing or said something else).
    public static func read(tool: String = tool) -> Bool? {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["isactive"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        return reading(exitStatus: process.terminationStatus)
    }

    /// `fdesetup isactive`'s exit status as a reading.
    public static func reading(exitStatus: Int32) -> Bool? {
        switch exitStatus {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    /// `read()` off the main thread.
    public static func current() async -> Bool? {
        await Task.detached(priority: .utility) { read() }.value
    }
}
