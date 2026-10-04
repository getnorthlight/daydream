import Foundation
import WriterBackend

// Compiled public API recipe. Main does not install, load a model or read keys.
struct IntegrationRecipe {
    let installer=CompatibleInstallation()
    func install(root:URL,progress:@escaping @Sendable (InstallState)->Void) async throws -> CompatibleWriterFiles {
        try await installer.install(in:root,progress:progress)
    }
    func cancelInstall() async {await installer.cancel()}
    func local(root:URL,core:CoreWriterPort,policy:@escaping CanonicalPolicyCheck) async throws -> CoreWriterAdapter {
        let files=try await CompatibleInstallation.restore(in:root)
        let writer=CanonicalLocalWriter(runtime:LlamaInference(files:files),policy:policy)
        return CoreWriterAdapter(core:core,generate:{try await writer.generate($0,completeActions:$1)})
    }
    func cloud(activation:CloudActivation,core:CoreWriterPort,policy:@escaping CanonicalPolicyCheck,send:@escaping CloudSender) async -> CoreWriterAdapter {
        let bindings=await activation.bindings()
        let writer=CanonicalCloudWriter(consent:bindings.consent,key:bindings.key,policy:{request,actions in
            guard await bindings.permits(request,actions) else {return false}
            return await policy(request,actions)
        },send:send)
        return CoreWriterAdapter(core:core,generate:{try await writer.generate($0,completeActions:$1)})
    }
}
@main struct Consumer {
    static func main() {print("PASS external local-package consumer and public async lifecycle compile; no install/inference/cloud invoked")}
}
