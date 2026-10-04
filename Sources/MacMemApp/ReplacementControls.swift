import SwiftUI
import MemoryCore

/// All service mutations are behind a separate, explicit confirmation.
/// Merely opening setup never inspects launchd, chooses a launcher or starts capture.
struct ReplacementControls: View {
    @ObservedObject var model: MemoryViewModel
    @State private var launcher: LegacyLauncher?
    @State private var ready = false
    @State private var message = "No launcher configured. Choose an explicit JSON configuration; no service name is guessed."
    @State private var confirmation = ""
    @State private var confirming = false
    @State private var busy = false
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Button("Choose launcher configuration…") { choose() }
            if let launcher {
                Text("Service: \(launcher.label)\nManifest: \(launcher.plist)\nExecutable: \(launcher.executable)\nPreserved history: \(launcher.historyHome)").font(.caption).textSelection(.enabled)
            }
            Toggle("I verified every downstream consumer uses the opt-in DayDream reader and no other recorder is active",isOn:$ready)
            Text("Prepare stops and disables only the reviewed service. It does not start DayDream. Start recording separately, then commit after a new observation. Rollback first stops DayDream and restores the prior service state.").font(.caption)
            HStack {
                Button("Prepare replacement…") { confirm("prepare") }.disabled(launcher == nil || !ready || model.recording)
                Button("Commit healthy replacement…") { confirm("commit") }
                Button("Rollback…") { confirm("rollback") }
            }
            Text(message).font(.caption).textSelection(.enabled)
        }.disabled(busy)
        .onAppear { if let state = try? model.replacement?.record() { message = "Replacement state: " + state.phase } }
        .alert(Self.confirmText(confirmation).title,isPresented:$confirming) {
            Button(Self.confirmText(confirmation).button) { perform() }
            Button("Cancel",role:.cancel) {}
        } message: { Text("Your history and settings aren't changed." + (confirmation == "prepare" ? " Preparing doesn't start recording." : "")) }
    }
    /// The confirmation in plain words, per step (never "Confirm prepare?").
    static func confirmText(_ action:String)->(title:String,button:String) {
        switch action {
        case "prepare": return ("Get the new recorder ready?","Get Ready")
        case "commit": return ("Keep the new recorder?","Keep It")
        case "rollback": return ("Go back to the old recorder?","Go Back")
        default: return ("Continue?","Continue")
        }
    }
    private func confirm(_ action:String) { confirmation=action; confirming=true }
    private func choose() {
        let panel=NSOpenPanel(); panel.canChooseDirectories=false; panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK, let url=panel.url else { return }
        do {
            let values=try url.resourceValues(forKeys:[.fileSizeKey])
            guard (values.fileSize ?? Int.max) <= 8192 else { throw MemError.invalid("Configuration too large") }
            let decoded=try JSONDecoder().decode(LegacyLauncher.self,from:Data(contentsOf:url))
            try decoded.validate(macMemHome:MemPaths.home())
            launcher=decoded; ready=false; message="Manifest matches. No service changed."
        } catch { launcher=nil; ready=false; message="Configuration or manifest could not be verified." }
    }
    private func perform() {
        guard let flow=model.replacement else { message="Storage unavailable"; return }
        model.replacementBusy=true
        model.cancelTimedPause()
        // Stop and release the new collector before any legacy rollback action.
        if confirmation == "rollback" { model.pauseCapture("Paused for explicit rollback") }
        let newStopped = !model.recording, selected=launcher, action=confirmation, consumerReady=ready
        busy=true
        DispatchQueue.global(qos:.userInitiated).async {
            let result: String
            do {
                switch action {
                case "prepare":
                    guard let selected else { throw MemError.denied }
                    try flow.prepare(selected,approved:true,compatibilityReady:consumerReady)
                case "commit": try flow.commit()
                case "rollback": try flow.rollback(approved:true,stopNew:{},newIsStopped:{newStopped})
                default: throw MemError.denied
                }
                result="Replacement state: " + (try flow.record()?.phase ?? "none")
            } catch { result="Action did not complete. " + String(describing:error) + ". Inspect the persisted replacement state before retrying." }
            DispatchQueue.main.async { message=result; busy=false; model.replacementBusy=false }
        }
    }
}
