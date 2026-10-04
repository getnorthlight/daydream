import Foundation
import MemoryCore

/// Validated before any MemoryViewModel or remembered connection is constructed.
struct DevelopmentTrial {
    let root:URL
    let memory:URL
    /// "DayDream Preview" (`--preview-sample`, PreviewSample): the same isolated, never-recording model over a made-up
    /// week in the temporary folder, with its own words ("Preview: sample data, not recording").
    var preview=false
    static func validate(environment:[String:String]=ProcessInfo.processInfo.environment) throws -> Self {
        guard let value=environment["DAYDREAM_DEVELOPMENT_ROOT"] else {throw MemError.denied}
        let root=URL(fileURLWithPath:value,isDirectory:true)
        guard root.path.hasPrefix("/private/tmp/daydream-development-trial-"),
              try physicalDirectory(root)==root,
              environment["MAC_MEM_HOME"]==root.appendingPathComponent("memory").path,
              environment["CFFIXED_USER_HOME"]==root.appendingPathComponent("preferences").path,
              try String(contentsOf:root.appendingPathComponent("DEVELOPMENT-ONLY"),encoding:.utf8)=="synthetic-only\n" else {throw MemError.denied}
        for name in ["memory","preferences","backups"] {
            let child=root.appendingPathComponent(name)
            guard try physicalDirectory(child)==child else {throw MemError.denied}
        }
        guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("memory/search-typesense.json").path) else {throw MemError.denied}
        let attributes=try FileManager.default.attributesOfItem(atPath:root.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value==getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {throw MemError.denied}
        return Self(root:root,memory:root.appendingPathComponent("memory"),preview:false)
    }
    func prepare() throws {
        let store=try MemoryStore(home:memory,writable:true,automaticallySyncSearch:false)
        guard try store.timeline(limit:100000).allSatisfy(\.evidence.synthetic) else {throw MemError.denied}
        let marker=root.appendingPathComponent("SEEDED")
        guard !FileManager.default.fileExists(atPath:marker.path) else {return}
        for i in 0..<5 {
            _=try store.ingest(Evidence(id:"development-action-\(i)",at:iso(Date().addingTimeInterval(Double(i-5)*60)),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Development trial research step \(i+1)",synthetic:true))
        }
        try Data("five synthetic actions\n".utf8).write(to:marker,options:.atomic)
    }
    func allowsBackup(_ path:URL)->Bool {
        let parent=path.deletingLastPathComponent()
        guard let resolved=try? physicalDirectory(parent),resolved==root.appendingPathComponent("backups") else {return false}
        if FileManager.default.fileExists(atPath:path.path) {return (try? physicalDirectory(path).path)==path.path}
        return true
    }
}
