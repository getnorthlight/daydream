import Foundation
import Darwin
import WriterBackend
@main struct PreparePackagedWriter {
    static func main() throws {
        guard CommandLine.arguments.count==4,let plan=WriterCandidates.recommended else {throw WriterFailure.invalidInput}
        guard let resolved=realpath(CommandLine.arguments[1],nil) else {throw WriterFailure.denied}
        let home=URL(fileURLWithPath:String(cString:resolved));free(resolved)
        guard home.path.hasPrefix("/private/tmp/daydream-trial-"),
              try String(contentsOf:home.appendingPathComponent("TRIAL-ONLY"),encoding:.utf8)=="synthetic-only\n" else {throw WriterFailure.denied}
        let models=home.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at:models,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        guard clonefile(CommandLine.arguments[2],models.appendingPathComponent(plan.asset.sha256+".model").path,0)==0 else {throw WriterFailure.unavailable}
        _=try CompatibleInstallation.extractRuntime(archive:URL(fileURLWithPath:CommandLine.arguments[3]),root:models)
        print("Synthetic model clone and pinned upstream runtime staged; no inference or activation")
    }
}
