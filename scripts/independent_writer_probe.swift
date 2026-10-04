// Diagnostic only: one prompt4 prompt (ITEMS view + prefill) through the exact compiled C bridge.
// Explicit pinned synthetic assets, no download/provider/core/UI mutation.
import Foundation
import WriterBackend
import CLlamaBridge

@main struct IndependentWriterProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let model=URL(fileURLWithPath:CommandLine.arguments[1])
        let directory=URL(fileURLWithPath:CommandLine.arguments[2])
        let files=try CompatibleInstallation.validate(model:model,runtimeDirectory:directory)
        let fixture=[("window.changed","Synthetic API proposal","Observed Synthetic API proposal in Pages; reading is not established.","observed"),
                     ("keyboard.text_input","","Typed a draft in Pages. please review the synthetic API proposal","draft"),
                     ("conversation.assistant","","Assistant reported: \"All synthetic tests passed.\" (not independently verified).","reported")]
        let actions=fixture.enumerated().map { offset,item in
            NoteAction(id:"case0-a\(offset)",at:"2026-09-12T00:00:0\(offset)Z",kind:item.0,app:offset==2 ? "ChatGPT":"Pages",site:"",title:item.1,description:item.2,state:item.3,revision:"r1")
        }
        let request=try JSONDecoder().decode(CanonicalNoteRequest.self,from:JSONSerialization.data(withJSONObject:["id":"probe","schemaVersion":1,"targetKind":"activity","targetID":"probe","day":"2026-09-12","timezone":"UTC","inputRevision":"r1","policyRevision":"p1","expiresAt":"2099-01-01T00:00:00Z","actions":JSONSerialization.jsonObject(with:JSONEncoder().encode(actions)),"actionCount":actions.count]))
        let view=try ModelView(request:request,actions:actions)
        let prompt=try QwenNoThinkingTemplate.render(instruction:CanonicalGrounding.instruction,evidence:view.text,prefill:CanonicalGrounding.prefill)
        guard let runtime=wr_create() else { exit(3) }
        defer { wr_destroy(runtime) }
        let loaded=wr_load(runtime,files.library.path,files.model.path)
        print("load_status=\(loaded)"); fflush(stdout)
        guard loaded == 0 else { exit(4) }
        var output:UnsafeMutablePointer<CChar>?
        let status=wr_generate(runtime,prompt,Int32(CanonicalGrounding.maxTokens),&output)
        defer { wr_release(output) }
        print("generate_status=\(status) phase=\(wr_execution_phase(runtime)) output_bytes=\(output.map{strlen($0)} ?? 0)"); fflush(stdout)
        // A numeric bridge status is diagnostic, never a successful model claim.
        if status != 0 { exit(1) }
    }
}
