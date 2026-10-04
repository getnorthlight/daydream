import SwiftUI
import AppKit
import MemoryUI
import WriterBackend

/// The summary controls setup and Settings use, and the one state they draw (`SummaryPhase`). The app always uses the
/// writer's own; check builds start with `recording` (it only records the calls: nothing downloads, reads the Keychain or
/// goes online) and can stand in a phase (setup-upgrade-checks and the renders).
@MainActor struct SummaryControls {
    var chooseLocal: (WriterIntegration) -> Void
    var chooseCloud: (WriterIntegration, String) async -> SummaryProblem?
    var turnOff: (WriterIntegration) -> Void
    var retry: (WriterIntegration) -> Void

    static let live = SummaryControls(chooseLocal: { $0.chooseLocal() }, chooseCloud: { await $0.chooseCloud(key: $1) },
                                      turnOff: { $0.turnOff() }, retry: { $0.retry() })
    #if DEVELOPMENT_SOURCE_CHECKS
    /// The calls the checks made, in order ("local", "cloud:<key length>", "off", "retry").
    static var calls: [String] = []
    /// What `chooseCloud` answers in the checks.
    static var cloudAnswer: SummaryProblem? = nil
    /// The phase the checks draw; nil reads the writer.
    static var phaseForChecks: SummaryPhase? = nil
    static let recording = SummaryControls(chooseLocal: { _ in calls.append("local") },
                                           chooseCloud: { _, key in calls.append("cloud:\(key.count)"); return cloudAnswer },
                                           turnOff: { _ in calls.append("off") }, retry: { _ in calls.append("retry") })
    static var current = SummaryControls.recording
    static func phase(_ writer: WriterIntegration) -> SummaryPhase { phaseForChecks ?? writer.phase }
    #else
    static let current = SummaryControls.live
    static func phase(_ writer: WriterIntegration) -> SummaryPhase { writer.phase }
    #endif
}

/// Settings › Summarizer (owner, 9/28): one row per way, one state at a time. "Summaries on this Mac" is a switch whose
/// only line is the state's own (Downloading 1.2 of 2.7 GB, Checking the model, or a problem with its one button); the
/// OpenRouter row is a switch with its one honest line and the key field while a key is needed. Turning either on turns
/// the other off; Off stops at once. No On/Off label, no spinner, no Cancel, no Details. The switches are never disabled.
struct WriterPreferences:View {
    @ObservedObject var writer:WriterIntegration
    /// Whether summaries may change now (no import, backup or replacement running). The switches stay usable; a change
    /// that can't happen yet says so in one line.
    var mayChange:()->Bool={true}
    var controlBusy:(Bool)->Void={_ in}
    let available:Bool
    @State private var key=""
    /// The OpenRouter switch is on and a key is needed (none saved, or it was refused): the key field shows.
    @State private var pendingCloud:Bool
    @State private var working=false
    /// The answer to the last key tried here (the phase says it too once the writer has it).
    @State private var cloudProblem:SummaryProblem?
    @State private var focusKey=0
    @State private var note:String?
    /// - `initialMode`: "Cloud" opens with the OpenRouter switch on and the key field shown (renders and checks).
    init(writer:WriterIntegration,mayChange:@escaping()->Bool={true},controlBusy:@escaping(Bool)->Void={_ in},initialMode:String="",available:Bool=true) {
        self.writer=writer;self.mayChange=mayChange;self.controlBusy=controlBusy;self.available=available
        _pendingCloud=State(initialValue:initialMode==Self.cloudMode)
    }
    static let cloudMode="Cloud"
    static let localMode="On this Mac"
    /// Said when an import, a backup or a replacement is running.
    static let waitLine="Summaries can change once the import or backup finishes."

    private var phase:SummaryPhase {SummaryControls.phase(writer)}
    /// fix/sx-all round 2: drawn from what runs. While a key is asked for (or was refused), summaries on this Mac keep
    /// running and their switch stays on; the OpenRouter switch turns on once its key is accepted, and the key field and
    /// its one line show under it meanwhile. Never both on, never one drawn off while it runs.
    /// A saved OpenRouter choice resuming at launch reads `.checking`: that check is the key's, not this Mac's.
    private var cloudChecking:Bool {phase == .checking && writer.cloudIntended}
    private var localOn:Bool {SummaryPhaseReading.localOn(phase) && !cloudChecking}
    private var cloudOn:Bool {SummaryPhaseReading.cloudOn(phase) || cloudChecking || (pendingCloud && !localOn)}
    /// A problem on this Mac: its line is the row's line, its button under it.
    private var localProblem:SummaryProblem? {SummaryPhaseReading.problem(phase).flatMap {SummaryPhaseReading.isCloud($0) ? nil:$0}}
    /// A problem with the key or the account: under the key field.
    private var shownCloudProblem:SummaryProblem? {
        if let problem=SummaryPhaseReading.problem(phase),SummaryPhaseReading.isCloud(problem) {return problem}
        return pendingCloud ? cloudProblem:nil
    }
    /// Try Again on battery: nothing is tried until the Mac is plugged in, and the row says so.
    static let waitsForPowerLine="The model is tried again when your Mac is plugged in."
    private var localLine:String? {localOn ? phase.line ?? (writer.retryWaitsForPower && phase == .on(.local) ? Self.waitsForPowerLine:nil):nil}

    private func allowed()->Bool {
        guard available else {return false}
        guard mayChange() else {note=Self.waitLine;return false}
        note=nil;return true
    }
    private func setLocal(_ on:Bool) {
        guard allowed() else {return}
        pendingCloud=false;key="";cloudProblem=nil
        if on {SummaryControls.current.chooseLocal(writer)} else {SummaryControls.current.turnOff(writer)}
    }
    private func setCloud(_ on:Bool) {
        guard allowed() else {return}
        cloudProblem=nil
        if !on {
            pendingCloud=false;key=""
            if SummaryPhaseReading.cloudOn(phase) {SummaryControls.current.turnOff(writer)}
            return
        }
        // The key field is open under a switch drawn off (summaries on this Mac still run): a second click closes it.
        if pendingCloud && localOn {pendingCloud=false;key="";return}
        // One state at a time: the writer's chooseCloud stops summaries on this Mac, and the saved key (if any) is tried
        // at once; without one, the key field is the question.
        pendingCloud=true
        connect(tryingSaved:true)
    }
    /// Connect, Return in the field, or the switch itself (with an empty field: the saved key, when there is one).
    private func connect(tryingSaved:Bool=false) {
        guard available,!working else {return}
        let value=key
        guard !value.isEmpty || tryingSaved else {return}
        working=true;controlBusy(true)
        Task {
            let problem=await SummaryControls.current.chooseCloud(writer,value)
            working=false;controlBusy(false)
            if problem == nil {pendingCloud=false;key="";cloudProblem=nil;return}
            // No saved key and none pasted yet: the field is the question, not a refusal.
            cloudProblem=(problem == .cloudKey && value.isEmpty) ? nil:problem
            if cloudProblem == .cloudKey {focusKey+=1}
        }
    }
    private func fix(_ problem:SummaryProblem) {
        switch problem {
        case .cloudKey,.noMemory: pendingCloud=true;focusKey+=1
        case .cloudCredits: NSWorkspace.shared.open(CloudSummariesText.creditsURL)
        default: guard allowed() else {return};cloudProblem=nil;SummaryControls.current.retry(writer)
        }
    }

    var body:some View {
        SettingsSurface("Summarizer") {
            SettingsCard {
                // Public downloads always carry the runtime; a test build staged without it shows only the OpenRouter row.
                if writer.localOffered {
                    VStack(alignment:.leading,spacing:6) {
                        HStack(alignment:.top,spacing:12) {
                            VStack(alignment:.leading,spacing:2) {
                                Text(DaydreamSummariesContent.localTitle).font(.system(size:14))
                                // fix/sx-all round 3: the line's one-line slot is kept in every state, so the OpenRouter
                                // switch below never moves when "Checking the model" or "Downloading..." comes and goes.
                                Text(localLine ?? " ").font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                    .opacity(localLine == nil ? 0 : 1).accessibilityHidden(localLine == nil)
                                    .accessibilityIdentifier("summaries-local-line")
                            }.frame(maxWidth:.infinity,alignment:.leading)
                            // fix/sx-all round 2: the fixing button sits on the row, beside the switch, so the rows below
                            // never move when a problem shows.
                            if let localProblem {Button(localProblem.button) {fix(localProblem)}.controlSize(.small)}
                            Toggle(DaydreamSummariesContent.localTitle,isOn:Binding(get:{localOn},set:{setLocal($0)}))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                                .accessibilityLabel(DaydreamSummariesContent.localTitle)
                        }
                    }.padding(.vertical,6)
                    Divider()
                }
                CloudSummariesSwitch(isOn:Binding(get:{cloudOn},set:{setCloud($0)}),key:$key,
                                     showsKey:pendingCloud || shownCloudProblem == .cloudKey,working:working,
                                     problem:shownCloudProblem,fix:{fix($0)},connect:{connect()},focusRequest:focusKey)
                    .padding(.vertical,6)
                if let note {Text(note).font(.system(size:12)).foregroundStyle(.secondary)}
            }
        }
        // The writer settled the key (on, or a problem it names): the field closes or says why.
        .onChange(of:phase) {value in if case .on(.cloud)=value {pendingCloud=false;key="";cloudProblem=nil}}
        .onDisappear {key="";pendingCloud=false;cloudProblem=nil}
    }
}

/// The summary writer's statuses in plain words, for the writer's own checks (notes-writer-checks). No surface shows these
/// any more: setup, Settings and the Today card show `SummaryPhase`. The writer's own strings stay as they are.
/// nil: nothing worth saying (the resting default, routine progress, a saved note, a model that is ready).
enum WriterStatusText {
    static func plain(_ status: String) -> String? {
        let s = status
        if s.isEmpty || s.hasPrefix("Local model not set up") || s.hasPrefix("Generated note saved") { return nil }
        if s.hasPrefix("Summaries on this Mac aren't set up") || s.hasPrefix("Checking the model") || s.hasPrefix("Ready. Summaries are off") { return nil }
        if s.hasPrefix("Model checked") || s.hasPrefix("Local writer ready") || s.contains("verified. Automatic notes are OFF") || s.hasPrefix("Local files verified") { return nil }
        if s.hasPrefix("Stopped. Waiting notes need Retry") { return "Stopped. Waiting notes stay until you retry." }
        if s.hasPrefix("Cloud key deleted") { return "Key deleted. Cloud summaries are off." }
        if s.hasPrefix("Key saved securely") { return "Key saved. Cloud summaries stay off until you turn them on." }
        if s.hasPrefix("Cloud enabled for new permitted actions only") { return "Cloud summaries are on, for new activity only." }
        if s.hasPrefix("Automatic notes off") { return "Summaries are off." }
        if s.hasPrefix("Writer cancelled") || s.hasPrefix("Setup cancelled") { return "Stopped. Waiting notes stay until you retry." }
        if s.hasPrefix("Writer stopped here, but saving") { return "Summaries stopped, but DayDream couldn't save that. Check your disk, then try again." }
        if s.hasPrefix("Writer queue full") { return "Too many summaries are waiting, so new moments wait too. Your activity is kept." }
        if s.hasPrefix("Note pending") || s.hasPrefix("Local note pending") || s.hasPrefix("Writer pending") { return "Some notes are waiting. Your activity is kept." }
        if s.hasPrefix("Optional local model not installed") { return nil }
        if s.hasPrefix("Local file verification failed") { return "The downloaded files are damaged. Report a problem, or use another choice." }
        if s.hasPrefix("Another setup is using the model cache") { return "Another setup is running. Try again when it finishes." }
        if s.hasPrefix("Runtime trust verification") || s.hasPrefix("Writer setup unavailable") { return "Summaries on this Mac can't start right now. Try again later." }
        // Anything else (a download step, a new failure) is shown as written, so a failure is never hidden.
        return s
    }
}
