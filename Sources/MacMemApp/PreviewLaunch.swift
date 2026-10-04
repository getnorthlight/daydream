import Foundation
import MemoryCore

/// "DayDream Preview" (`--preview-sample`, the DAYDREAM_PREVIEW_SAMPLE=1 environment, or the preview bundle's
/// `DaydreamPreviewSample` Info.plist key): a made-up week in a scratch folder in the temporary directory, opened through
/// the Development Trial's model (no Coordinator, no capture, no typing key, no search service, no writer, no updates,
/// no setup). Decided before anything opens MemPaths.home(): MAC_MEM_HOME points at the preview folder first.
enum PreviewLaunch {
    static func requested(arguments:[String]=CommandLine.arguments,environment:[String:String]=ProcessInfo.processInfo.environment,
                          infoValue:Any?=Bundle.main.object(forInfoDictionaryKey:"DaydreamPreviewSample"))->Bool {
        arguments.contains(PreviewSample.launchArgument) || environment[PreviewSample.environmentKey]=="1" || infoValue as? Bool == true
    }
    /// The preview's memory folder (`<temporary directory>/DayDream Preview Sample/memory`). MAC_MEM_HOME points here
    /// from the start of a preview launch, before the sample exists, and is never unset.
    static func memory(temporaryDirectory:URL=FileManager.default.temporaryDirectory)->URL {
        PreviewSample.root(temporaryDirectory:temporaryDirectory).appendingPathComponent("memory",isDirectory:true)
    }
    /// Points MAC_MEM_HOME at the preview's memory folder. Reads and writes nothing on disk.
    @discardableResult static func pointHome(temporaryDirectory:URL=FileManager.default.temporaryDirectory)->URL {
        let memory=memory(temporaryDirectory:temporaryDirectory)
        setenv("MAC_MEM_HOME",memory.path,1)
        return memory
    }
    /// Makes the preview folder again (or reuses today's), seeds it, points MAC_MEM_HOME at it and returns the isolated model's trial value.
    /// `mcpCommand`: this app's `mac-mem`, for the preview's own MCP entry (mcp-server.json in the folder).
    static func prepare(now:Date=Date(),temporaryDirectory:URL=FileManager.default.temporaryDirectory,
                        reuse:Bool = !CommandLine.arguments.contains(PreviewSample.reseedArgument),
                        mcpCommand:URL?=Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("mac-mem")) throws -> DevelopmentTrial {
        let root=PreviewSample.root(temporaryDirectory:temporaryDirectory)
        let memory=try PreviewSample.prepare(root:root,now:now,temporaryDirectory:temporaryDirectory,reuse:reuse).memory
        setenv("MAC_MEM_HOME",memory.path,1)
        // Everything after this opens MemPaths.home(): it must be the preview folder, or nothing opens.
        guard MemPaths.home().standardizedFileURL.path==memory.standardizedFileURL.path,PreviewSample.allowed(memory,temporaryDirectory:temporaryDirectory) else {throw MemError.denied}
        if let mcpCommand,FileManager.default.isExecutableFile(atPath:mcpCommand.path) {
            _=try? PreviewSample.writeMCPEntry(root:root,memory:memory,command:mcpCommand)
        }
        return DevelopmentTrial(root:root,memory:memory,preview:true)
    }
}
