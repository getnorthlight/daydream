import Foundation
import MemoryCore
import Darwin

/// Never constructed by tests. Called only by explicit setup controls.
struct LaunchctlControl: LauncherControl {
    private var domain:String { "gui/\(getuid())" }
    private func run(_ args:[String]) throws -> (Int32,String) {
        let process=Process(); process.executableURL=URL(fileURLWithPath:"/bin/launchctl"); process.arguments=args
        let pipe=Pipe(); process.standardOutput=pipe; process.standardError=FileHandle.nullDevice
        try process.run()
        // Bounded local inspection. Do not wait indefinitely for launchd.
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd,F_SETFL,O_NONBLOCK)
        var data = Data(), buffer = [UInt8](repeating:0,count:4096)
        let deadline = Date().addingTimeInterval(3)
        while true {
            let count = Darwin.read(fd,&buffer,buffer.count)
            if count > 0 { data.append(contentsOf:buffer.prefix(count)) }
            if count == 0 && !process.isRunning { break }
            if data.count > 65536 || Date() > deadline {
                if process.isRunning { kill(process.processIdentifier,SIGKILL) }
                throw MemError.invalid("Launcher inspection timed out or exceeded its output bound")
            }
            usleep(10000)
        }
        process.waitUntilExit()
        return (process.terminationStatus,String(decoding:data,as:UTF8.self))
    }
    func inspect(_ launcher:LegacyLauncher) throws -> LauncherState {
        let disabled=try run(["print-disabled",domain])
        guard disabled.0 == 0 else { throw MemError.invalid("Cannot inspect launchd user domain") }
        let name=NSRegularExpression.escapedPattern(for:launcher.label)
        let isDisabled=disabled.1.range(of:"\""+name+"\"\\s*=>\\s*true",options:.regularExpression) != nil
        let loaded=try run(["print",domain+"/"+launcher.label])
        guard loaded.0 == 0 || loaded.0 == 113 else { throw MemError.invalid("Unknown launchd inspection result") }
        return LauncherState(loaded:loaded.0 == 0,disabled:isDisabled)
    }
    func stopAndDisable(_ launcher:LegacyLauncher) throws {
        guard try run(["disable",domain+"/"+launcher.label]).0 == 0 else { throw MemError.invalid("Disable failed") }
        if try inspect(launcher).loaded {
            guard try run(["bootout",domain+"/"+launcher.label]).0 == 0 else { throw MemError.invalid("Stop failed") }
        }
    }
    func restore(_ launcher:LegacyLauncher, previous:LauncherState) throws {
        let target=domain+"/"+launcher.label
        if previous.loaded, !(try inspect(launcher).loaded) {
            guard try run(["enable",target]).0 == 0, try run(["bootstrap",domain,launcher.plist]).0 == 0 else { throw MemError.invalid("Restore failed") }
        }
        if !previous.loaded, try inspect(launcher).loaded { _ = try run(["bootout",target]) }
        guard try run([previous.disabled ? "disable" : "enable",target]).0 == 0 else { throw MemError.invalid("Restore disabled state failed") }
    }
    /// Uninstall: stops a DayDream login agent, by its exact label only. "Not loaded" is fine.
    func bootout(label:String) {
        guard UninstallLocations.loginLabels.contains(label) else { return }
        _ = try? run(["bootout",domain+"/"+label])
    }
}
