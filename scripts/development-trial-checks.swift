import Foundation
import MemoryCore
import Darwin

func physicalDirectory(_ url:URL) throws -> URL {
    guard let p=realpath(url.path,nil) else {throw MemError.denied};defer{free(p)}
    return URL(fileURLWithPath:String(cString:p),isDirectory:true)
}
@main struct DevelopmentChecks {
    static func main() throws {
        let root=URL(fileURLWithPath:"/private/tmp/daydream-development-trial-check-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        for name in ["memory","preferences","backups"] {try FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
        try Data("synthetic-only\n".utf8).write(to:root.appendingPathComponent("DEVELOPMENT-ONLY"))
        let env=["DAYDREAM_DEVELOPMENT_ROOT":root.path,"MAC_MEM_HOME":root.appendingPathComponent("memory").path,"CFFIXED_USER_HOME":root.appendingPathComponent("preferences").path]
        let trial=try DevelopmentTrial.validate(environment:env);try trial.prepare()
        let store=try MemoryStore(home:trial.memory,writable:true,automaticallySyncSearch:false)
        let initial=try store.timeline(limit:20);precondition(initial.count==5)
        let first=try store.searchResult(MemorySearchQuery("research"));precondition(first.items.count==5)
        let id=first.items[0].id
        let action=try store.action(id)!
        _=try store.correctAction(id:id,text:"Development correction",expectedRevision:action.revision)
        try store.delete(first.items[1].id)
        try trial.prepare()
        let remaining=try store.timeline(limit:20);precondition(remaining.count==4)
        let corrected=try store.action(id)!;precondition(corrected.description.contains("Development correction"))
        precondition(trial.allowsBackup(root.appendingPathComponent("backups/test.macmembackup")))
        precondition(!trial.allowsBackup(URL(fileURLWithPath:"/private/tmp/not-this-trial")))
        var wrong=env;wrong["CFFIXED_USER_HOME"]="/private/tmp"
        do {_=try DevelopmentTrial.validate(environment:wrong);fatalError("accepted wrong preferences")}catch{}
        try Data("{}".utf8).write(to:trial.memory.appendingPathComponent("search-typesense.json"))
        do {_=try DevelopmentTrial.validate(environment:env);fatalError("accepted external index config")}catch{}
        print("PASS actual development validation, five-action local search, correction/delete retention on restart, backup scope, wrong preferences and external-index rejection")
        print("Synthetic fixture retained: "+root.path)
    }
}
