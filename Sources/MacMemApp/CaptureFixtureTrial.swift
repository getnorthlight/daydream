// App-process owned native Claude fixture. Real production capture, no input posting.
// No tapEventForChecks/handleNativeKey injection, no posted input, no app activation, no Keychain/default home.
import AppKit
import ApplicationServices
import Carbon
import Foundation
import MemoryCore
import PrivacyPolicy
import Security
import CryptoKit
import Darwin

#if DAYDREAM_QA_HARNESS && !DAYDREAM_OWNER_TYPING
#error("DAYDREAM_QA_HARNESS requires the private owner build")
#endif

#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
enum IntakeError: String, Error { case arguments, input, lifecycleSaveRefused, lifecycleCloseRefused, lifecycleNeutralRefused, caretPositionRefused, permissionPost, workflowOpenTimeout, workflowOpenRefused, workflowFocusTimeout, identity, path, receipt, permission, permissionAX, permissionListen, secureInput, frontApp, pidMatch, focusWindow, focusField, focusTitle, focusDocument, focusRole, focusSubrole, claudeOwnedComposer, enabled, scope, proof, tap, store, policy }
/// Metadata only: each closure is the original short-circuit save predicate read.
struct CaptureSavePredicateDiagnostic {
    private(set) var attempts = 0
    private(set) var scopeMatched = false
    private(set) var editedState = "not-read"
    private(set) var fileState = "not-read"
    private(set) var finalScopeState = "not-read"
    private(set) var editedUnavailableCount = 0
    private(set) var fileExactCount = 0
    mutating func check(matches: () -> Bool, edited: () -> Bool?, protectedExact: () -> Bool?) -> Bool {
        attempts += 1
        editedState = "not-read"; fileState = "not-read"
        scopeMatched = matches()
        guard scopeMatched else { return false }
        let state = edited()
        editedState = state.map { $0 ? "true" : "false" } ?? "unavailable"
        if state == nil { editedUnavailableCount += 1 }
        guard state == false else { return false }
        let exact = protectedExact()
        fileState = exact.map { $0 ? "exact" : "mismatch" } ?? "unavailable"
        if exact == true { fileExactCount += 1 }
        return exact == true
    }
    mutating func finish(saved: Bool, matches: () -> Bool) -> Bool {
        guard saved else { return false }
        let exact = matches()
        finalScopeState = exact ? "matched" : "refused"
        return exact
    }
    var metadata: [String: Any] {
        ["phase": "workflow-save-predicates", "saveAttempts": attempts,
         "currentScopeMatches": scopeMatched, "editedState": editedState,
         "protectedFileState": fileState, "finalScopeState": finalScopeState,
         "editedUnavailableCount": editedUnavailableCount, "fileExactCount": fileExactCount,
         "additionalReads": false]
    }
}
/// Separate disk-backed reopen contract; the old AXEdited-required case never calls this.
enum CapturePersistedReopenPredicate {
    static func exact(matches: () -> Bool, protectedExact: () -> Bool?) -> Bool {
        guard matches() else { return false }
        return protectedExact() == true
    }
}
/// Only metadata from the held owned editor, never its text.
enum CaptureCaretRangePredicate {
    static func acceptsScope(rawFixture:String,hasDocument:Bool) -> Bool {
        rawFixture == "textedit" && hasDocument
    }
    static func exact(status:AXError, raw:CFTypeRef?, scopeHeld:Bool, timely:Bool, expected:Int) -> Bool {
        guard scopeHeld,timely,expected>=0,status == .success,let raw,
              CFGetTypeID(raw)==AXValueGetTypeID(),
              AXValueGetType(raw as! AXValue) == .cfRange else {return false}
        var range=CFRange()
        guard AXValueGetValue(raw as! AXValue,.cfRange,&range),range.location>=0,range.length>=0 else {return false}
        return range.location==expected && range.length==0
    }
}
enum CaptureFixtureKind: String {
    case nativeClaude = "native-claude", nativeChatGPT = "native-chatgpt", textEdit = "textedit", textEditWorkflow = "textedit-workflow"
    /// The desktop AI app whose owned, empty composer this fixture binds (Claude, ChatGPT); nil for TextEdit.
    var ownedComposer: OwnedComposerApp? { self == .nativeClaude ? .claude : self == .nativeChatGPT ? .chatGPT : nil }
    var bundle: String { ownedComposer?.bundle ?? "com.apple.TextEdit" }
    var declaration: String {
        switch self {
        case .nativeClaude: return "native-claude-empty-unsent-v1\n"
        case .nativeChatGPT: return "native-chatgpt-empty-unsent-v1\n"
        case .textEditWorkflow: return "textedit-two-owned-documents-v1\n"
        case .textEdit: return "textedit-empty-document-v1\n"
        }
    }
    func accepts(_ proof: FocusProof) -> Bool {
        proof.bundle == bundle && (ownedComposer != nil ? proof.surface == .embeddedWeb : proof.surface == .native)
    }
    func documentName(_ root: URL) -> String {
        "DayDream QA Mini-" + String(root.lastPathComponent.dropFirst("daydream-capture-fixture-".count)) + ".txt"
    }
}
@MainActor private final class OwnedNativeScope {
    let fixture: CaptureFixtureKind
    let expectedTitle: String
    let document: URL?
    let pid: pid_t
    let window: AXUIElement
    let field: AXUIElement
    let claudeComposer: ClaudeOwnedComposer<AXUIElement>?
    init(expectedPID: pid_t, expectedTitle: String, fixture: CaptureFixtureKind, document: URL?) throws {
        self.fixture = fixture; self.expectedTitle = expectedTitle; self.document = document
        guard Thread.isMainThread, AXIsProcessTrusted() else { throw IntakeError.permissionAX }
        guard CGPreflightListenEventAccess() else { throw IntakeError.permissionListen }
        guard !IsSecureEventInputEnabled() else { throw IntakeError.secureInput }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == fixture.bundle else { throw IntakeError.frontApp }
        guard app.processIdentifier == expectedPID else { throw IntakeError.pidMatch }
        pid = app.processIdentifier
        let root = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(root, 0.025) == .success,
              let w = Self.element(root, kAXFocusedWindowAttribute) else { throw IntakeError.focusWindow }
        guard let f = Self.element(root, kAXFocusedUIElementAttribute) else { throw IntakeError.focusField }
        guard Self.string(w, kAXTitleAttribute) == expectedTitle else { throw IntakeError.focusTitle }
        guard Self.matchesDocument(w, document) else { throw IntakeError.focusDocument }
        guard let role = Self.string(f, kAXRoleAttribute), ["AXTextArea", "AXTextField"].contains(role) else { throw IntakeError.focusRole }
        guard let subrole = Self.subrole(f), CaptureFixtureMetadata.nonSecure(role: role, subrole: subrole) else { throw IntakeError.focusSubrole }
        guard Self.enabled(f, fixture: fixture) else { throw IntakeError.enabled }
        window = w; field = f
        if let app = fixture.ownedComposer {
            guard let owned = ClaudeOwnedComposerAX.bind(pid: pid,window: w,editor: f,app: app,diagnostic:CaptureFixtureTrial.claudeDiagnostic) else { throw IntakeError.claudeOwnedComposer }
            claudeComposer = owned
        } else { claudeComposer = nil }
    }
    func matches() -> Bool {
        // Additional refusal only. Default production proof still checks signer, keyboard mode, ancestry and system focus.
        guard Thread.isMainThread, AXIsProcessTrusted(), CGPreflightListenEventAccess(), !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == fixture.bundle, app.processIdentifier == pid else { return false }
        let root = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(root, 0.025) == .success,
              let w = Self.element(root, kAXFocusedWindowAttribute), let f = Self.element(root, kAXFocusedUIElementAttribute) else { return false }
        return CFEqual(w, window) && CFEqual(f, field) &&
            Self.string(w, kAXTitleAttribute) == expectedTitle && Self.matchesDocument(w, document) &&
            CaptureFixtureMetadata.nonSecure(role: Self.string(f, kAXRoleAttribute), subrole: Self.subrole(f)) && Self.enabled(f, fixture: fixture) &&
            (fixture.ownedComposer == nil || claudeComposer?.matches() == true)
    }
    private static func matchesDocument(_ window: AXUIElement, _ expected: URL?) -> Bool {
        guard let expected else { return true }
        guard let raw = attribute(window, kAXDocumentAttribute),
              let actual = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:)),
              actual.isFileURL else { return false }
        return actual.standardizedFileURL.resolvingSymlinksInPath() == expected.standardizedFileURL.resolvingSymlinksInPath()
    }
    func edited() -> Bool? {
        guard matches(),let raw=Self.attribute(window,kAXEditedAttribute),CFGetTypeID(raw)==CFBooleanGetTypeID() else{return nil}
        return CFBooleanGetValue((raw as! CFBoolean))
    }
    func caretAt(_ expected:Int) -> Bool {
        guard CaptureCaretRangePredicate.acceptsScope(rawFixture:fixture.rawValue,hasDocument:document != nil),matches(),
              AXUIElementSetMessagingTimeout(field,0.025) == .success else {return false}
        let began=DispatchTime.now().uptimeNanoseconds
        var raw:CFTypeRef?
        let status=AXUIElementCopyAttributeValue(field,kAXSelectedTextRangeAttribute as CFString,&raw)
        let timely=DispatchTime.now().uptimeNanoseconds-began<=50_000_000
        return CaptureCaretRangePredicate.exact(status:status,raw:raw,scopeHeld:matches(),timely:timely,expected:expected)
    }
    func closed() -> Bool {
        var raw:CFTypeRef?
        return AXUIElementCopyAttributeValue(window,kAXRoleAttribute as CFString,&raw) == .invalidUIElement
    }
    private static func subrole(_ e: AXUIElement) -> String? {
        guard AXUIElementSetMessagingTimeout(e, 0.025) == .success else { return nil }
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(e, kAXSubroleAttribute as CFString, &raw)
        return CaptureFixtureMetadata.subrole(status: status, raw: raw, withinDeadline: true)
    }
    private static func enabled(_ e: AXUIElement, fixture: CaptureFixtureKind) -> Bool {
        guard AXUIElementSetMessagingTimeout(e, 0.025) == .success else { return false }
        let began = DispatchTime.now().uptimeNanoseconds
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(e, kAXEnabledAttribute as CFString, &raw)
        let boolean = raw.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        let enabled = CaptureFixtureMetadata.enabled(status: status, raw: raw,
            withinDeadline: DispatchTime.now().uptimeNanoseconds - began <= 50_000_000,
            textEdit: fixture == .textEdit) {
                // Metadata only: ask whether editing is supported; never acquire or set selected text.
                var settable = DarwinBoolean(false)
                let result = AXUIElementIsAttributeSettable(e, kAXSelectedTextAttribute as CFString, &settable)
                guard result == .success,
                      DispatchTime.now().uptimeNanoseconds - began <= 50_000_000 else { return nil }
                return settable.boolValue
            }
        let timely = DispatchTime.now().uptimeNanoseconds - began <= 50_000_000
        if !enabled || !timely {
            CaptureFixtureTrial.emit(["phase": "scope-enabled-refused", "axError": status.rawValue,
                               "booleanAvailable": boolean, "enabled": false, "allowed": false])
        }
        return enabled && timely
    }
    static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        guard AXUIElementSetMessagingTimeout(e, 0.025) == .success else { return nil }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }
    private static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(e, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement
    }
    private static func string(_ e: AXUIElement, _ name: String) -> String? { attribute(e, name) as? String }
}

@MainActor enum CaptureFixtureTrial {
    // Known harmless fixture marker. Never printed, never inferred from a user's text, never acquired by this harness.
    static let marker = "qa final source amber lantern proof"
    static let baseCaptureSource = "b1cadade3cc8c1fb54bb1b53618f88d240b16a90"
    private static var output: FileHandle?
    private static var captureIdentity: [String: Any]?
    private static var workflowCaseID: String?
    static func enriched(_ receipt: [String: Any]) -> [String: Any] {
        var receipt = receipt
        if let workflowCaseID { receipt["caseID"] = workflowCaseID; receipt["workflowManifestRevision"] = 1 }
        if let captureIdentity {
            receipt["captureIdentity"] = captureIdentity
            receipt["baselineCaptureSource"] = baseCaptureSource
            receipt["axTrusted"] = AXIsProcessTrusted()
            receipt["listenAllowed"] = CGPreflightListenEventAccess()
            receipt["postAllowed"] = CGPreflightPostEventAccess()
            receipt["secureInput"] = IsSecureEventInputEnabled()
        }
        return receipt
    }
    private static var claudeDiagnosticCount=0
    static func claudeDiagnostic(_ d: ClaudeComposerDiagnostic) {
        guard claudeDiagnosticCount<24 else { return };claudeDiagnosticCount+=1
        var receipt:[String:Any]=["phase":"claude-composer-diagnostic","guardPhase":d.phase,"lastRead":d.lastRead,"refusal":d.refusal.rawValue,
            "elapsedNanoseconds":d.elapsedNanoseconds,"clockWentBackwards":d.clockWentBackwards,"aggregateExpired":d.aggregateExpired,"deadlineCheckRefused":d.deadlineCheckRefused,
            "visitedCount":d.visitedCount,"depthLimitReached":d.depthLimitReached,"cycleDetected":d.cycleDetected,
            "allowed":false,"additionalAXReads":false,"productionProofCheckedSeparately":true]
        if let v=d.ready {receipt["ready"]=v};if let v=d.windowAvailable {receipt["windowAvailable"]=v}
        if let v=d.editorAvailable {receipt["editorAvailable"]=v};if let v=d.ownerMatches {receipt["ownerMatches"]=v}
        if let v=d.roleClass {receipt["roleClass"]=v};if let v=d.newPage {receipt["newPage"]=v}
        if let v=d.editable {receipt["editable"]=v};if let v=d.typedZero {receipt["typedZero"]=v}
        if let v=d.parentAvailable {receipt["parentAvailable"]=v}
        if let v=d.areaCount {receipt["areaCount"]=v};if let v=d.retainedAreaMatches {receipt["retainedAreaMatches"]=v}
        if let v=d.emptyIssue {receipt["emptyIssue"]=v.rawValue}
        emit(receipt)
    }
    static func emit(_ receipt: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: enriched(receipt), options: [.sortedKeys]) else { return }
        try? output?.write(contentsOf: data + Data([10])); try? output?.synchronize()
        if let text = String(data: data, encoding: .utf8) { print(text); fflush(stdout) }
    }
    static func options() throws -> [String: String] {
        let args = Array(CommandLine.arguments.dropFirst(2)); guard args.count % 2 == 0 else { throw IntakeError.arguments }
        var out: [String: String] = [:]
        for i in stride(from: 0, to: args.count, by: 2) {
            guard ["--work-root", "--window-title", "--seconds", "--expected-pid", "--mode", "--input", "--fixture", "--scenario", "--lifecycle"].contains(args[i]), out[args[i]] == nil else { throw IntakeError.arguments }
            out[args[i]] = args[i+1]
        }
        return out
    }
    /// No default home, settings, Keychain or updater is constructed by this entry.
    static func authenticate() throws {
        guard Bundle.main.object(forInfoDictionaryKey: "DaydreamQAHarness") as? Bool == true,
              Bundle.main.bundleIdentifier == "com.getnorthlight.daydream",
              Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "MacMem",
              Bundle.main.object(forInfoDictionaryKey: "MacMemOwnerTyping") as? Bool == true,
              Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool == false,
              Bundle.main.object(forInfoDictionaryKey: "SUAutomaticallyUpdate") as? Bool == false,
              Bundle.main.object(forInfoDictionaryKey: "SUAllowsAutomaticUpdates") as? Bool == false,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil,
              let executable = Bundle.main.executableURL,
              executable.lastPathComponent == "MacMem",
              Bundle.main.bundleURL.pathExtension == "app" else { throw IntakeError.identity }
        var code: SecCode?; var staticCode: SecStaticCode?; var requirement: SecRequirement?; var information: CFDictionary?
        let requirementText = "anchor apple generic and identifier \"com.getnorthlight.daydream\" and certificate leaf[subject.OU] = \"L76C3ZC66J\""
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any], let flags = info[kSecCodeInfoFlags as String] as? UInt32,
              flags & 2 == 0,
              let mainExecutable = info[kSecCodeInfoMainExecutable as String] as? URL,
              mainExecutable.standardizedFileURL.resolvingSymlinksInPath() == executable.standardizedFileURL.resolvingSymlinksInPath(),
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first,
              SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map({ String(format: "%02x", $0) }).joined() == "4b87cd4e80280eb7a2fc8dee7d50bf5fb534f6f73f172343bc16dcfe36a1a9af" else { throw IntakeError.identity }
        let bytes = try Data(contentsOf: executable, options: .mappedIfSafe)
        guard bytes.count <= 256 * 1024 * 1024,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { throw IntakeError.identity }
        captureIdentity = ["bundle": "com.getnorthlight.daydream", "selfVerified": true,
                           "executableSHA256": SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined()]
    }
    static func checkedRoot(_ text: String, fixture: CaptureFixtureKind = .nativeClaude) throws -> URL {
        guard text.hasPrefix("/private/tmp/daydream-capture-fixture-"),
              !text.contains("\0"), let physical = realpath(text, nil) else { throw IntakeError.path }
        defer { free(physical) }
        let root = URL(fileURLWithPath: text, isDirectory: true)
        guard root.path == text, root.deletingLastPathComponent().path == "/private/tmp",
              String(cString: physical) == text else { throw IntakeError.path }
        var info = stat()
        guard lstat(text, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw IntakeError.path }
        let fd = open(root.appendingPathComponent("OWNED-FIXTURE").path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw IntakeError.path }; defer { close(fd) }
        let marker = Array(fixture.declaration.utf8)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size == marker.count else { throw IntakeError.path }
        var bytes = [UInt8](repeating: 0, count: marker.count)
        guard bytes.withUnsafeMutableBytes({ read(fd, $0.baseAddress, $0.count) }) == marker.count,
              bytes == marker else { throw IntakeError.path }
        var names: Set<String> = ["OWNED-FIXTURE"]
        if fixture.ownedComposer == nil {
            let documents = fixture == .textEditWorkflow ? CaptureWorkflowContract.names(root) : [fixture.documentName(root)]
            for name in documents {
            names.insert(name)
            let document = root.appendingPathComponent(name)
            guard lstat(document.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
                  info.st_size == 0 else { throw IntakeError.path }
            }
        }
        guard Set(try FileManager.default.contentsOfDirectory(atPath: text)) == names else { throw IntakeError.path }
        return root
    }
    static func reserveOutput(_ root: URL) throws {
        let fd = open(root.appendingPathComponent("capture-fixture-receipt.jsonl").path,
                      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw IntakeError.receipt }
        output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    static func newHome(_ rootText: String) throws -> URL {
        // checkedRoot reserved the exclusive receipt. Refuse an existing store;
        // never reuse or repair any default, previous or user-owned history.
        let home = URL(fileURLWithPath: rootText).appendingPathComponent("memory", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: home.path) else { throw IntakeError.path }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return home
    }
    private static let fixtureKeys: [Character: CGKeyCode] = [
        " ":49, "a":0, "b":11, "c":8, "e":14, "f":3, "i":34, "l":37,
        "g":5, "v":9, "w":13, "x":7, "d":2, "h":4, "y":16, "m":46, "n":45, "o":31, "p":35, "q":12, "r":15, "s":1, "t":17, "u":32]
    static func fixtureKey(_ character: Character) -> CGKeyCode? { fixtureKeys[character] }
    private static func fixedUSKeyboard() -> Bool {
        guard let input = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let inputRaw = TISGetInputSourceProperty(input,kTISPropertyInputSourceID),
              let layoutRaw = TISGetInputSourceProperty(layout,kTISPropertyInputSourceID) else {return false}
        let inputID = Unmanaged<CFString>.fromOpaque(inputRaw).takeUnretainedValue() as String
        let layoutID = Unmanaged<CFString>.fromOpaque(layoutRaw).takeUnretainedValue() as String
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return CaptureWorkflowContract.fixedUSKeyboard(inputID:inputID,layoutID:layoutID,flags:flags)
    }
    private static func postOne(_ character: Character, scope: OwnedNativeScope,
                                live: EventCapture.TypingEnvironment, coordinator: Coordinator, deadline: UInt64) throws {
        let capital=["I","W"].contains(String(character))
        guard let key=fixtureKey(capital ? Character(String(character).lowercased()) : character) else {throw IntakeError.input}
        try postFixtureKey(key,scope:scope,live:live,coordinator:coordinator,deadline:deadline,flags:capital ? .maskShift:[])
    }
    /// Only fixed compiled characters, Backspace, owned Save/Close and the scoped v2 document-end key call this helper.
    private static func postFixtureKey(_ key: CGKeyCode, scope: OwnedNativeScope,
                                live: EventCapture.TypingEnvironment, coordinator: Coordinator, deadline: UInt64, flags:CGEventFlags=[],documentEnd:Bool=false) throws {
        guard flags.isEmpty || flags == .maskShift || (flags == .maskCommand && ([CGKeyCode(1),CGKeyCode(13)].contains(key) || (documentEnd && key==CGKeyCode(kVK_DownArrow) && CaptureCaretRangePredicate.acceptsScope(rawFixture:scope.fixture.rawValue,hasDocument:scope.document != nil)))), DispatchTime.now().uptimeNanoseconds < deadline, CGPreflightPostEventAccess(),
              !IsSecureEventInputEnabled(), scope.matches(), fixedUSKeyboard() else { throw IntakeError.input }
        let context = try coordinator.captureBinding.context()
        guard let proof = live.proof(context.generation, context.policy.version),
              scope.fixture.accepts(proof),
              scope.matches(), CGPreflightPostEventAccess(), !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == scope.pid,
              DispatchTime.now().uptimeNanoseconds < deadline,
              CaptureGate.typing(proof, policy: context.policy, generation: context.generation,
                                 now: DispatchTime.now().uptimeNanoseconds).outcome == .allowed,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false),
              DispatchTime.now().uptimeNanoseconds < deadline, AXIsProcessTrusted(), CGPreflightPostEventAccess(),
              !IsSecureEventInputEnabled(), fixedUSKeyboard(), NSWorkspace.shared.frontmostApplication?.processIdentifier == scope.pid else { throw IntakeError.input }
        down.flags = flags; up.flags = []
        down.post(tap: .cgSessionEventTap); up.post(tap: .cgSessionEventTap)
    }
    static func typedRows(_ store: MemoryStore) throws -> [Evidence] {
        let rows: [Evidence] = try Set(store.actions(limit: 200).actions.flatMap { $0.evidenceIDs }).compactMap {
            guard let e = try store.read($0)?.evidence, e.kind == "keyboard.text_input" else { return nil }
            return e
        }
        return orderedRows(rows)
    }
    static func orderedRows(_ rows: [Evidence]) -> [Evidence] {
        // ISO capture times may share a second across distinct native focus runs.
        // Rank each tied-start run by its first commit, never by a random run UUID.
        // A run-level rank keeps the comparator transitive while preserving parts.
        var firstCommit: [Date:[String:Date]] = [:]
        for row in rows {
            let unit = row.captureProvenance?.unit
            let start = timestamp(unit?.startedAt ?? row.at) ?? timestamp(row.at) ?? .distantFuture
            let run = unit?.runID ?? ""
            let at = timestamp(row.at) ?? .distantFuture
            firstCommit[start, default: [:]][run] = min(firstCommit[start]?[run] ?? .distantFuture, at)
        }
        return rows.sorted {
            let left = $0.captureProvenance?.unit, right = $1.captureProvenance?.unit
            let l = timestamp(left?.startedAt ?? $0.at) ?? timestamp($0.at) ?? .distantFuture
            let r = timestamp(right?.startedAt ?? $1.at) ?? timestamp($1.at) ?? .distantFuture
            if l != r { return l < r }
            let lr = left?.runID ?? "", rr = right?.runID ?? ""
            if lr != rr {
                let lc = firstCommit[l]?[lr] ?? .distantFuture, rc = firstCommit[r]?[rr] ?? .distantFuture
                if lc != rc { return lc < rc }
                return lr < rr
            }
            let lp = left?.part ?? 0, rp = right?.part ?? 0
            if lp != rp { return lp < rp }
            let la = timestamp($0.at) ?? .distantFuture, ra = timestamp($1.at) ?? .distantFuture
            if la != ra { return la < ra }
            return $0.id < $1.id
        }
    }
    static func exact(_ store: MemoryStore, rows: [Evidence]) throws -> Bool {
        try rows.compactMap { try store.hydrateTypedText($0.id, disclosure: .owner) }.joined() == marker
    }
    static func scoped(_ rows: [Evidence], _ identities: Set<String>, bundle: String) -> Bool {
        !rows.isEmpty && rows.allSatisfy {
            $0.bundle == bundle && !$0.secure && !$0.privateWindow && !$0.synthetic &&
            identities.contains(($0.captureProvenance?.windowID ?? "") + "|" + ($0.captureProvenance?.focusID ?? "")) &&
            $0.text.isEmpty && $0.typed != nil
        }
    }
    static func main() {
        defer { try? output?.close(); output = nil }
        do { try run() }
        catch {
            // Errors can carry source content or paths. Emit a fixed code only.
            emit(["phase": "blocked", "code": (error as? IntakeError)?.rawValue ?? "harness-operation", "tapProof": false])
            exit(77)
        }
    }
    static func run() throws {
        try authenticate()
        let o = try options()
        guard let root = o["--work-root"], let title = o["--window-title"],
              let fixture = CaptureFixtureKind(rawValue: o["--fixture"] ?? "native-claude"),
              let expectedPID = o["--expected-pid"].flatMap(Int32.init), expectedPID > 0,
              let mode = o["--mode"], ["preflight", "capture"].contains(mode),
              let seconds = Double(o["--seconds"] ?? "30"), (20...45).contains(seconds) else { throw IntakeError.arguments }
        let inputMode = o["--input"] ?? "operator"
        guard ["operator", "fixed-marker"].contains(inputMode) else { throw IntakeError.arguments }
        if fixture == .textEditWorkflow {
            guard inputMode == "fixed-marker" else { throw IntakeError.input }
            guard let scenario = CaptureWorkflowContract.Scenario(rawValue:o["--scenario"] ?? "native-interrupted-draft-v1") else {throw IntakeError.arguments}
            let lifecycleID=o["--lifecycle"]
            let lifecycle=lifecycleID != nil
            guard lifecycleID == nil || [NativeLifecycleContract.id,NativeLifecycleContract.savedID,NativeLifecycleContract.persistedID,NativeLifecycleContract.persistedV2ID].contains(lifecycleID!),
                  !lifecycle || scenario == .morning else {throw IntakeError.arguments}
            workflowCaseID=lifecycleID ?? scenario.rawValue
            try runWorkflow(root:root,title:title,expectedPID:expectedPID,mode:mode,seconds:seconds,scenario:scenario,
                            lifecycle:lifecycle,crossApplication:lifecycleID == NativeLifecycleContract.id,
                            persistedReopen:[NativeLifecycleContract.persistedID,NativeLifecycleContract.persistedV2ID].contains(lifecycleID ?? ""),
                            explicitCaretEnd:lifecycleID == NativeLifecycleContract.persistedV2ID)
            return
        }
        guard o["--scenario"] == nil,o["--lifecycle"] == nil else {throw IntakeError.arguments}
        let fixtureRoot = try checkedRoot(root, fixture: fixture)
        let document = fixture == .textEdit ? fixtureRoot.appendingPathComponent(fixture.documentName(fixtureRoot)) : nil
        let allowedTitles = document.map { [$0.lastPathComponent, $0.deletingPathExtension().lastPathComponent] } ?? [fixture.ownedComposer?.windowTitle ?? "Claude"]
        guard allowedTitles.contains(title) else { throw IntakeError.arguments }
        try reserveOutput(fixtureRoot)
        let sourceHash = baseCaptureSource
        guard AXIsProcessTrusted() else { throw IntakeError.permissionAX }
        guard CGPreflightListenEventAccess() else { throw IntakeError.permissionListen }
        guard !IsSecureEventInputEnabled() else { throw IntakeError.secureInput }
        if inputMode == "fixed-marker", !CGPreflightPostEventAccess() { throw IntakeError.permissionPost }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == fixture.bundle else { throw IntakeError.frontApp }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID else { throw IntakeError.pidMatch }
        let live = EventCapture.TypingEnvironment()
        // Existing production proof may enable AXManualAccessibility on the signed app.
        // This is ordinary Electron tree setup, never a TCC/consent/privacy/C1 change.
        let firstProof = live.proof(0, 0)
        let proofValid = firstProof.map { $0.bundle == fixture.bundle && fixture.accepts($0) && $0.verified && $0.fieldStateVerified &&
            $0.frameAccessible && $0.navigationStable } ?? false
        emit(["phase": "preflight-stage", "stage": "production-proof", "allowed": proofValid,
              "captureStarted": false, "storeOpened": false, "inputPosted": false])
        // Metadata-only scope diagnostics never substitute for the production proof.
        let scope = try OwnedNativeScope(expectedPID: expectedPID, expectedTitle: title, fixture: fixture, document: document)
        guard scope.matches() else { throw IntakeError.scope }
        guard proofValid else { throw IntakeError.proof }
        guard fixture.ownedComposer == nil || scope.claudeComposer?.initiallyEmpty() == true else { throw IntakeError.claudeOwnedComposer }
        if mode == "preflight" {
            emit(["phase": "preflight", "baselineCaptureSource": sourceHash, "allowed": true,
                  "scopeHeld": true, "fixture": fixture.rawValue, "nativeFixtureScopeHeld": true, "productionNativeFocusProof": true,
                  "ownedNewClaudeComposerVerified": fixture == .nativeClaude, "ownedNewChatGPTComposerVerified": fixture == .nativeChatGPT, "composerInitiallyEmptyVerified": fixture.ownedComposer != nil,
                  "captureStarted": false, "storeOpened": false, "inputPosted": false])
            return
        }
        let home = try newHome(root)
        emit(["phase": "isolated-store-created", "baselineCaptureSource": sourceHash, "seconds": seconds,
              "axPreflight": true, "listenPreflight": true, "nativeScopeBound": true])
        // Store-only setup. No shared settings, default history, Keychain, summary worker or cloud client.
        let keys = InMemoryTypedKeyStore()
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        try store.attachVault(TypedTextVault(keyStore: keys)); try store.setUpTypedVault(); try store.acceptSafeTyping()
        // Configure only this new isolated fixture through the saved switches
        // required by the real binding; no shared/default policy is touched.
        var savedPolicy = try store.policy()
        savedPolicy.captureText = true; savedPolicy.typedConsentVersion = 1
        try store.updatePolicy(savedPolicy)
        try store.setSummaryWriter("off")
        let coordinator = try Coordinator(store: store, permissions: { scope.matches() }) {}
        coordinator.captureText = true
        var typing = live
        var scopedRealProofIdentities: Set<String> = []
        typing.proof = { generation, version in
            guard scope.matches() else { return nil }
            guard let p = live.proof(generation, version), fixture.accepts(p) else { return nil }
            scopedRealProofIdentities.insert(p.windowID + "|" + p.focusID)
            return p
        }
        // Disable only ancillary Chrome page recording for this native-only fixture; the production event intake and native proof stay real.
        var pages = ChromePageEnvironment.live; pages.frontmost = { nil }
        let capture = EventCapture(coordinator: coordinator, typingEnvironment: typing, pageEnvironment: pages)
        var keyEvents = 0, scopeLost = false, typedCommitReceipts = 0
        capture.onKeyInput = { if scope.matches() { keyEvents += 1 } else { scopeLost = true } }
        coordinator.onNativeCommitted = { if $0.path == .typedText { typedCommitReceipts += 1 } }
        try coordinator.start()
        let armedContext = try coordinator.captureBinding.context()
        guard armedContext.policy.typedText else { coordinator.stop(); throw IntakeError.policy }
        guard scope.matches(), let armedProof = live.proof(armedContext.generation, armedContext.policy.version),
              CaptureGate.typing(armedProof, policy: armedContext.policy, generation: armedContext.generation,
                                 now: DispatchTime.now().uptimeNanoseconds).outcome == .allowed else {
            coordinator.stop(); throw IntakeError.proof
        }
        guard fixture.ownedComposer == nil || scope.claudeComposer?.initiallyEmpty() == true else { coordinator.stop(); throw IntakeError.claudeOwnedComposer }
        guard capture.start() else { coordinator.stop(); throw IntakeError.tap }
        defer { capture.stop(reason: "Bounded harness exit"); coordinator.stop() }
        let began = DispatchTime.now().uptimeNanoseconds
        let deadline = began + UInt64(seconds * 1_000_000_000)
        emit(["phase": "armed", "realEventCaptureStart": true, "operatorSendsInput": inputMode == "operator",
              "baselineCaptureSource": sourceHash, "seconds": seconds, "scopeHeld": true, "inputMode": inputMode, "chromeLane": "not-run", "nativeBundle": fixture.bundle, "fixture": fixture.rawValue,
              "ownedNewClaudeComposerVerified": fixture == .nativeClaude, "ownedNewChatGPTComposerVerified": fixture == .nativeChatGPT, "composerInitiallyEmptyVerified": fixture.ownedComposer != nil,
              "isolatedSavedTypingEnabled": true, "effectiveTypingGateEnabled": true, "freshNativeProofAllowedBeforeArm": true])
        // Explicit signed-app self-test input only. This is not an identity proxy
        // for an external helper; absent actual app Post rights remains a refusal.
        let inputDeadline = began + 5_000_000_000
        let characters = Array(marker)
        var posted = 0, inputFailed = false, driverReported = false, nextInputAt = began
        if inputMode == "fixed-marker" { emit(["phase": "driver-started", "keyCount": 0, "submitted": false]) }
        while DispatchTime.now().uptimeNanoseconds < deadline && !capture.isStopped {
            if !scope.matches() { scopeLost = true; inputFailed = inputMode == "fixed-marker"; break }
            if inputMode == "fixed-marker", posted < characters.count,
               DispatchTime.now().uptimeNanoseconds >= nextInputAt {
                do {
                    try postOne(characters[posted], scope: scope, live: live, coordinator: coordinator, deadline: inputDeadline)
                    posted += 1
                    nextInputAt = DispatchTime.now().uptimeNanoseconds + 60_000_000
                } catch { inputFailed = true; break }
            }
            // Deliver the real OS event through the real tap/main run loop.
            // Never call capture handlers directly or change their admission.
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if inputMode == "fixed-marker", posted == 35, !driverReported {
                let held = scope.matches() && CGPreflightPostEventAccess() && !IsSecureEventInputEnabled()
                emit(["phase": held ? "driver-complete" : "driver-blocked", "scopeHeld": held,
                      "markerPostedOnce": held, "keyCount": posted, "submitted": false, "physicalHumanTyping": false])
                driverReported = true
                if !held { inputFailed = true; break }
            }
        }
        if inputMode == "fixed-marker", !driverReported {
            let held = scope.matches()
            let done = !inputFailed && posted == 35 && held
            emit(["phase": done ? "driver-complete" : "driver-blocked", "postAllowed": CGPreflightPostEventAccess(),
                  "scopeHeld": held, "markerPostedOnce": done, "keyCount": posted,
                  "submitted": false, "physicalHumanTyping": false])
            inputFailed = !done
        }
        let heldScope = scope.matches() && !scopeLost
        if heldScope { capture.flushNativeText() }
        capture.stop(reason: "Bounded native OS fixture complete")
        coordinator.stop()
        let rows = try typedRows(store)
        let markerExact = try exact(store, rows: rows)
        let sourceExact = scoped(rows, scopedRealProofIdentities, bundle: fixture.bundle)
        let actions = try store.actions(limit: 200).actions
        let rowIDs = Set(rows.map { $0.id })
        let draftStates = ClaudeComposerMetadata.drafts(rowIDs: rowIDs, actions: actions.map { (Set($0.evidenceIDs), $0.kind, $0.state) })
        let noSend = actions.allSatisfy { $0.state != "sent" && $0.state != "submitted" }
        // A separate database connection proves durable readback; reuse only this process's in-memory fixture key store.
        // This is not an app relaunch or recovery of keys after process exit.
        let reopened = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        try reopened.attachVault(TypedTextVault(keyStore: keys))
        let reopenedRows = try typedRows(reopened)
        let reopenExact = try exact(reopened, rows: reopenedRows)
        let sameRows = Set(rows.map { $0.id }) == Set(reopenedRows.map { $0.id })
        let reopenedActions = try reopened.actions(limit: 200).actions
        let reopenedDraftStates = ClaudeComposerMetadata.drafts(rowIDs: Set(reopenedRows.map { $0.id }), actions: reopenedActions.map { (Set($0.evidenceIDs), $0.kind, $0.state) })
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
        let passed = !inputFailed && heldScope && keyEvents > 0 && typedCommitReceipts > 0 && markerExact && sourceExact && reopenExact && sameRows && noSend && (fixture.ownedComposer == nil || (draftStates && reopenedDraftStates))
        let receipt: [String: Any] = ["phase": "complete", "baselineCaptureSource": sourceHash, "realEventCaptureStart": true,
            "tapKeyEvents": keyEvents, "typedCommitReceipts": typedCommitReceipts, "savedRows": rows.count,
            "expectedMarkerExact": markerExact, "nativeSourceExact": sourceExact, "reopenedMarkerExact": reopenExact,
            "reopenedSameRows": sameRows, "scopeHeld": heldScope, "noSendClaim": noSend,
            "elapsedSeconds": (elapsed * 100).rounded() / 100, "pass": passed,
            "isActualOSInput": keyEvents > 0, "inputOriginVerifiedByOperator": false, "appFixturePostedKeyPairs": posted,
            "inputMode": inputMode, "cgSyntheticAppInput": inputMode == "fixed-marker",
            "physicalHumanTypingVerified": false, "chromeTypingVerified": false, "appRelaunchVerified": false,
            "nativeClaudeTypingVerified": fixture == .nativeClaude && passed, "nativeChatGPTTypingVerified": fixture == .nativeChatGPT && passed, "ownedNewChatGPTComposerVerified": fixture == .nativeChatGPT && heldScope, "draftStatesVerified": draftStates, "reopenedDraftStatesVerified": reopenedDraftStates, "ownedNewClaudeComposerVerified": fixture == .nativeClaude && heldScope, "nativeTextEditTypingVerified": fixture == .textEdit && passed]
        try JSONSerialization.data(withJSONObject: enriched(receipt), options: [.sortedKeys]).write(to: home.appendingPathComponent("receipt.json"), options: .atomic)
        emit(receipt)
        // Preserved test home path is only a CLI artifact location; contains no source content. No cleanup/deletion.
        // Root/owner already knows the exact fixture root; never export a supplied path.
        if !passed { exit(1) }
    }

    /// A bounded QA-only A→B→A visit sequence. Same production capture instance and isolated store.
    static func runWorkflow(root: String, title: String, expectedPID: pid_t, mode: String, seconds: Double,
                            scenario: CaptureWorkflowContract.Scenario,lifecycle:Bool=false,crossApplication:Bool=true,persistedReopen:Bool=false,explicitCaretEnd:Bool=false) throws {
        let homeRoot = try checkedRoot(root, fixture: .textEditWorkflow)
        let documents = CaptureWorkflowContract.names(homeRoot).map { homeRoot.appendingPathComponent($0) }
        let texts=lifecycle ? NativeLifecycleContract.texts : scenario.texts
        let operations=lifecycle ? texts.map {$0.map {CaptureWorkflowContract.Operation.character($0)}} : scenario.operations
        let alpha=texts[0]+texts[2]
        let neutral=lifecycle && crossApplication ? NativeLifecycleNeutralWindow(root:homeRoot) : nil
        defer{neutral?.close()}
        var documentReopenCount=0,crossAppVerified=false

        guard [documents[0].lastPathComponent, documents[0].deletingPathExtension().lastPathComponent].contains(title) else { throw IntakeError.arguments }
        try reserveOutput(homeRoot)
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess(), CGPreflightPostEventAccess(), !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.TextEdit",
              app.processIdentifier == expectedPID, let appURL = app.bundleURL else { throw IntakeError.permission }
        guard fixedUSKeyboard() else {throw IntakeError.input}
        let live = EventCapture.TypingEnvironment()
        func stage(_ name: String) {
            emit(["phase":"workflow-preparation-stage","stage":name,"postsInput":false])
        }
        func openOwned(_ document: URL, stageName: String) throws {
            stage(stageName)
            let config = NSWorkspace.OpenConfiguration(); config.activates = true; config.createsNewApplicationInstance = false
            config.promptsUserIfNeeded = false
            var completed = false, accepted = false
            NSWorkspace.shared.open([document], withApplicationAt: appURL, configuration: config) { opened, error in
                DispatchQueue.main.async { accepted = error == nil && opened?.processIdentifier == expectedPID; completed = true }
            }
            let end = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
            while !completed && DispatchTime.now().uptimeNanoseconds < end { CFRunLoopRunInMode(.defaultMode,0.02,true) }
            if !completed || DispatchTime.now().uptimeNanoseconds > end {throw IntakeError.workflowOpenTimeout}
            guard accepted else {throw IntakeError.workflowOpenRefused}
            emit(["phase":"workflow-open-complete","stage":stageName,"expectedApplication":true,"scopeReady":false])
        }
        func bind(_ index: Int, stageName: String) throws -> OwnedNativeScope {
            stage(stageName)
            let end = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
            var last: IntakeError = .scope
            repeat {
                for candidate in [documents[index].lastPathComponent, documents[index].deletingPathExtension().lastPathComponent] {
                    do {
                        let scope = try OwnedNativeScope(expectedPID: expectedPID, expectedTitle: candidate, fixture: CaptureWorkflowContract.scopeFixture, document: documents[index])
                        guard scope.matches(),DispatchTime.now().uptimeNanoseconds <= end else {last = .scope;continue}
                        emit(["phase":"workflow-scope-ready","stage":stageName,"ownedDocument":index==0 ? "A":"B",
                              "scopeHeld":true,"productionProof":false])
                        return scope
                    } catch let error as IntakeError {
                        last = error
                        guard CaptureWorkflowContract.retryableScopeCode(error.rawValue) else {
                            emit(["phase":"workflow-preparation-refused","stage":stageName,"code":error.rawValue])
                            throw error
                        }
                    }
                }
                CFRunLoopRunInMode(.defaultMode,0.02,true)
            } while DispatchTime.now().uptimeNanoseconds<end
            emit(["phase":"workflow-preparation-refused","stage":stageName,"code":"workflowFocusTimeout","lastScopeCode":last.rawValue])
            throw IntakeError.workflowFocusTimeout
        }
        // Document opening completion is not focus readiness. Rebind exact metadata after bounded settling.
        var scopes: [OwnedNativeScope?] = [nil,nil]
        scopes[0] = try bind(0,stageName:"prepare-A-initial")
        try openOwned(documents[1],stageName:"prepare-open-B")
        scopes[1] = try bind(1,stageName:"prepare-bind-B")
        try openOwned(documents[0],stageName:"prepare-return-A")
        scopes[0] = try bind(0,stageName:"prepare-rebind-A")
        func ownedIndex() -> Int? { scopes.indices.first { scopes[$0]?.matches() == true } }
        guard ownedIndex() == 0, let initial = live.proof(0,0), CaptureFixtureKind.textEdit.accepts(initial),
              initial.verified, initial.fieldStateVerified, initial.frameAccessible, initial.navigationStable else { throw IntakeError.proof }
        emit(["phase":"preflight","allowed":true,"scopeHeld":true,"fixture":"textedit-workflow",
              "twoOwnedDocuments":true,"inputPosted":false,"storeOpened":false,"captureStarted":false])
        if mode == "preflight" { return }
        let home = try newHome(root)
        let keys=InMemoryTypedKeyStore()
        let store = try MemoryStore(home: home,writable: true,automaticallySyncSearch:false)
        try store.attachVault(TypedTextVault(keyStore:keys)); try store.setUpTypedVault();try store.acceptSafeTyping()
        var policy = try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy);try store.setSummaryWriter("off")
        let coordinator = try Coordinator(store:store,permissions:{ownedIndex() != nil || neutral?.focused == true}) {}
        coordinator.captureText=true
        var visit=0, ids=[Set<String>(),Set<String>(),Set<String>()], posted=[0,0,0], observed=[0,0,0], scopeLost=false
        var controlActive=false,controlPosted=0,controlObserved=0
        var caretVerified=false
        var typing=live
        typing.proof={generation,version in
            guard let index=ownedIndex(),
                  let proof=live.proof(generation,version),CaptureFixtureKind.textEdit.accepts(proof),ownedIndex()==index else {return nil}
            let actualVisit = index == 1 ? 1 : (visit == 2 ? 2 : 0)
            ids[actualVisit].insert(proof.windowID+"|"+proof.focusID);return proof
        }
        var pages=ChromePageEnvironment.live;pages.frontmost={nil}
        func makeCapture() -> EventCapture {
            let recorder=EventCapture(coordinator:coordinator,typingEnvironment:typing,pageEnvironment:pages)
            recorder.onKeyInput={
                if controlActive {controlObserved+=1}
                else if ownedIndex()==CaptureWorkflowContract.documents[visit] {observed[visit]+=1}
                else {scopeLost=true}
            }
            return recorder
        }
        let capture=makeCapture()
        try coordinator.start()
        let armedContext=try coordinator.captureBinding.context()
        guard armedContext.policy.typedText,ownedIndex()==0,
              let armedProof=live.proof(armedContext.generation,armedContext.policy.version),
              CaptureGate.typing(armedProof,policy:armedContext.policy,generation:armedContext.generation,
                                 now:DispatchTime.now().uptimeNanoseconds).outcome == .allowed else {coordinator.stop();throw IntakeError.proof}
        guard capture.start() else {coordinator.stop();throw IntakeError.tap}
        defer {capture.stop(reason:"Bounded two-document QA exit");coordinator.stop()}
        emit(["phase":"armed","scopeHeld":true,"realEventCaptureStart":true,"fixture":"textedit-workflow",
              "fixedWorkflow":true,"submitted":false,"continuousCapture":true])
        let began=DispatchTime.now().uptimeNanoseconds, deadline=began+UInt64(seconds*1e9)
        func saveCloseReopen(_ index:Int,final:Bool) throws {
            guard lifecycle,let current=scopes[index],ownedIndex()==index else {throw IntakeError.scope}
            controlActive=true;defer{controlActive=false}
            capture.flushNativeText()
            try postFixtureKey(1,scope:current,live:live,coordinator:coordinator,deadline:deadline,flags:.maskCommand)
            controlPosted+=1
            let end=min(deadline,DispatchTime.now().uptimeNanoseconds+3_000_000_000)
            var saved=false
            var saveDiagnostic=CaptureSavePredicateDiagnostic()
            while DispatchTime.now().uptimeNanoseconds<end {
                CFRunLoopRunInMode(.defaultMode,0.02,true)
                if persistedReopen {
                    // Separately versioned disk-state oracle. No AXEdited claim or dialog interaction.
                    if CapturePersistedReopenPredicate.exact(matches:{current.matches()},protectedExact:{
                        guard let bytes=try? NativeLifecycleFiles.read(documents[index].lastPathComponent,root:homeRoot,maximum:4096) else {return nil}
                        return bytes==Data(NativeLifecycleContract.expectedDocument(index,final:final).utf8)
                    }) {saved=true;break}
                } else if saveDiagnostic.check(matches:{current.matches()},edited:{current.edited()},protectedExact:{
                    guard let bytes=try? NativeLifecycleFiles.read(documents[index].lastPathComponent,root:homeRoot,maximum:4096) else {return nil}
                    return bytes==Data(NativeLifecycleContract.expectedDocument(index,final:final).utf8)
                }) {saved=true;break}
            }
            let saveAccepted=saveDiagnostic.finish(saved:saved,matches:{current.matches()})
            if !persistedReopen {emit(saveDiagnostic.metadata)}
            guard saveAccepted else {throw IntakeError.lifecycleSaveRefused}
            var savedMetadata:[String:Any]=["phase":"workflow-lifecycle-stage","stage":"owned-file-saved","ownedDocument":index==0 ? "A":"B",
                  "protectedSavedBytesExact":true]
            if persistedReopen {
                savedMetadata.merge(["diskBackedReopenOracle":true,"editedStateRequired":false,
                    "saveCommandIssued":true,"saveCommandCausalityVerified":false,"powerLossDurabilityVerified":false]) {_,new in new}
            } else {savedMetadata["documentEdited"]=false}
            emit(savedMetadata)
            try postFixtureKey(13,scope:current,live:live,coordinator:coordinator,deadline:deadline,flags:.maskCommand)
            controlPosted+=1
            let closeEnd=min(deadline,DispatchTime.now().uptimeNanoseconds+2_000_000_000)
            while !current.closed() && DispatchTime.now().uptimeNanoseconds<closeEnd {CFRunLoopRunInMode(.defaultMode,0.02,true)}
            guard current.closed() else {throw IntakeError.lifecycleCloseRefused}
            let bytes=try NativeLifecycleFiles.read(documents[index].lastPathComponent,root:homeRoot,maximum:4096)
            guard bytes==Data(NativeLifecycleContract.expectedDocument(index,final:final).utf8) else {throw IntakeError.lifecycleSaveRefused}
            try openOwned(documents[index],stageName:"owned-file-reopen")
            scopes[index]=try bind(index,stageName:"owned-file-rebind")
            guard ownedIndex()==index,
                  try NativeLifecycleFiles.read(documents[index].lastPathComponent,root:homeRoot,maximum:4096)==bytes else {throw IntakeError.lifecycleCloseRefused}
            documentReopenCount+=1
            emit(["phase":"workflow-lifecycle-stage","stage":"owned-file-reopened","ownedDocument":index==0 ? "A":"B",
                  "freshDocumentScope":true,"savedBytesUnchanged":true,"entireTextEditQuit":false,"ownedWindowClosedVerified":true])
            let settled=min(deadline,DispatchTime.now().uptimeNanoseconds+150_000_000)
            while DispatchTime.now().uptimeNanoseconds<settled {CFRunLoopRunInMode(.defaultMode,0.02,true)}
        }

        for stage in 0..<3 {
            visit=stage
            let documentIndex=CaptureWorkflowContract.documents[stage]
            if stage>0 {try openOwned(documents[documentIndex],stageName:"visit-\(stage)-open")}
            scopes[documentIndex] = try bind(documentIndex,stageName:"visit-\(stage)-bind")
            guard let activeScope=scopes[documentIndex],ownedIndex()==documentIndex,!capture.isStopped else {throw IntakeError.scope}
            let context=try coordinator.captureBinding.context()
            guard let proof=live.proof(context.generation,context.policy.version),
                  CaptureGate.typing(proof,policy:context.policy,generation:context.generation,now:DispatchTime.now().uptimeNanoseconds).outcome == .allowed else {throw IntakeError.proof}
            if explicitCaretEnd && stage==2 {
                guard persistedReopen,documentIndex==0,workflowCaseID == NativeLifecycleContract.persistedV2ID else {throw IntakeError.arguments}
                controlActive=true
                defer {controlActive=false}
                try postFixtureKey(CGKeyCode(kVK_DownArrow),scope:activeScope,live:live,coordinator:coordinator,deadline:deadline,flags:.maskCommand,documentEnd:true)
                controlPosted+=1
                let settle=min(deadline,DispatchTime.now().uptimeNanoseconds+100_000_000)
                while DispatchTime.now().uptimeNanoseconds<settle {CFRunLoopRunInMode(.defaultMode,0.02,true)}
                let fresh=try coordinator.captureBinding.context()
                guard let freshProof=live.proof(fresh.generation,fresh.policy.version),
                      CaptureGate.typing(freshProof,policy:fresh.policy,generation:fresh.generation,now:DispatchTime.now().uptimeNanoseconds).outcome == .allowed,
                      DispatchTime.now().uptimeNanoseconds<deadline,activeScope.caretAt(NativeLifecycleContract.texts[0].utf16.count),
                      ownedIndex()==0 else {throw IntakeError.caretPositionRefused}
                caretVerified=true
                emit(["phase":"workflow-caret-position","visit":2,"ownedDocument":"A","scopeHeld":true,"productionProof":true,
                      "commandDownArrowPosted":true,"selectedRangeLocation":26,"selectedRangeLength":0,"caretPositionVerified":true])
            }
            ids[stage].insert(proof.windowID+"|"+proof.focusID)
            emit(["phase":"workflow-visit","visit":stage,"ownedDocument":documentIndex==0 ? "A":"B","productionProof":true,"scopeHeld":true])
            for operation in operations[stage] {
                switch operation {
                case .character(let character): try postOne(character,scope:activeScope,live:live,coordinator:coordinator,deadline:deadline)
                case .backspace: try postFixtureKey(51,scope:activeScope,live:live,coordinator:coordinator,deadline:deadline)
                }
                posted[stage]+=1
                emit(["phase":"workflow-input-progress","visit":stage,"postedKeyPairs":posted[stage],"submitted":false])
                RunLoop.main.run(until:Date().addingTimeInterval(0.06))
            }
            // Natural run-loop settling, not injected capture handlers or fabricated timestamps.
            let pause=Date().addingTimeInterval(stage==2 ? 4 : 0.4)
            while Date()<pause {
                guard DispatchTime.now().uptimeNanoseconds<deadline,ownedIndex()==documentIndex else {throw IntakeError.scope}
                RunLoop.main.run(until:Date().addingTimeInterval(0.02))
            }
            if lifecycle {
                if crossApplication && stage==0 {
                    guard let neutral else {throw IntakeError.lifecycleNeutralRefused}
                    capture.flushNativeText();try neutral.show()
                    let end=min(deadline,DispatchTime.now().uptimeNanoseconds+2_000_000_000)
                    while !neutral.focused && DispatchTime.now().uptimeNanoseconds<end {CFRunLoopRunInMode(.defaultMode,0.02,true)}
                    emit(neutral.readiness)
                    guard neutral.focused else {throw IntakeError.lifecycleNeutralRefused}
                    let pauseEnd=min(deadline,DispatchTime.now().uptimeNanoseconds+300_000_000)
                    while DispatchTime.now().uptimeNanoseconds<pauseEnd {
                        guard neutral.focused else {throw IntakeError.lifecycleNeutralRefused}
                        CFRunLoopRunInMode(.defaultMode,0.02,true)
                    }
                    try openOwned(documents[0],stageName:"cross-app-return-owned-A")
                    scopes[0]=try bind(0,stageName:"cross-app-fresh-A")
                    guard ownedIndex()==0 else {throw IntakeError.lifecycleNeutralRefused}
                    crossAppVerified=true
                    emit(["phase":"workflow-lifecycle-stage","stage":"cross-application-return","actualAppActivation":true,
                          "ownedNeutralWindow":true,"returnedOwnedDocument":true,"inputPosted":false])
                }
                try saveCloseReopen(documentIndex,final:stage==2)

            }
        }
        guard !scopeLost,ownedIndex()==0 else {throw IntakeError.scope}
        capture.flushNativeText();capture.stop(reason:"Two-document OS workflow complete");coordinator.stop()
        let rows=try typedRows(store)
        let rowIDs=rows.map { ($0.captureProvenance?.windowID ?? "")+"|"+($0.captureProvenance?.focusID ?? "") }
        let unique = ids[0].isDisjoint(with:ids[1]) && ids[2].isDisjoint(with:ids[1])
        var documentTexts=["",""], evidenceByDocument=[Set<String>(),Set<String>()], knownRows=true
        var observedRowShapes=[[String:Any]]()
        for (i,row) in rows.enumerated() {
            guard let text=try store.hydrateTypedText(row.id,disclosure:.owner) else {knownRows=false;continue}
            let documentIndex: Int
            if ids[1].contains(rowIDs[i]) {documentIndex=1;documentTexts[1]+=text;evidenceByDocument[1].insert(row.id)}
            else if ids[0].contains(rowIDs[i]) || ids[2].contains(rowIDs[i]) {documentIndex=0;documentTexts[0]+=text;evidenceByDocument[0].insert(row.id)}
            else {knownRows=false;continue}
            var shape=CaptureWorkflowContract.shape(text,expectedPrefix:texts[documentIndex]).metadata
            shape["ownedDocument"]=documentIndex==0 ? "A":"B";shape["rowOrder"]=i
            observedRowShapes.append(shape)
        }
        let source=knownRows && unique && scoped(rows,ids.reduce(into:Set<String>()) {$0.formUnion($1)},bundle:"com.apple.TextEdit")
        // Counts/booleans only, and only for the exact owned unwithheld production rows.
        // Diagnostics do not change the byte-for-byte pass oracle or infer a failure cause.
        let shapeAvailable=source && rows.allSatisfy {$0.captureProvenance?.unit?.withheld == 0}
        let documentShapes: [[String:Any]] = shapeAvailable ? documentTexts.enumerated().map {index,text in
            var shape=CaptureWorkflowContract.shape(text,expectedPrefix:texts[index]).metadata
            shape["ownedDocument"]=index==0 ? "A":"B";return shape
        } : []
        let aExact=documentTexts[0]==alpha,bExact=documentTexts[1]==texts[1]
        let actions=try store.actions(limit:200).actions
        let noSend=actions.allSatisfy {$0.state != "sent" && $0.state != "submitted"}
        let proofStable = !ids[0].isDisjoint(with:ids[2])
        let typedActions=actions.filter {$0.kind == "keyboard.text_input"}
        let actionIDs=evidenceByDocument.map { evidence in Set(typedActions.filter {!Set($0.evidenceIDs).isDisjoint(with:evidence)}.map(\.id)) }
        let logicalContextKnown=typedActions.allSatisfy { action in
            guard let index=evidenceByDocument.indices.first(where:{!Set(action.evidenceIDs).isDisjoint(with:evidenceByDocument[$0])}) else {return false}
            return [documents[index].lastPathComponent,documents[index].deletingPathExtension().lastPathComponent].contains(action.subject)
        }
        guard let first=rows.first else {throw IntakeError.store}
        let day=try store.dayLayers(day:String(first.at.prefix(10)),timezone:"UTC",limit:200)
        let grouping=CaptureWorkflowContract.grouping(actionIDs:actionIDs,moments:day.activities.map {Set($0.actionIDs)})
        let continuity=logicalContextKnown && grouping.alphaConnected && grouping.betaSeparate
        let draftStates = !typedActions.isEmpty && typedActions.allSatisfy {$0.state == "draft"}
        let second=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false);try second.attachVault(TypedTextVault(keyStore:keys))
        let secondRows=try typedRows(second)
        var secondExact=Set(secondRows.map(\.id))==Set(rows.map(\.id))
        for row in rows {if try second.hydrateTypedText(row.id,disclosure:.owner) != store.hydrateTypedText(row.id,disclosure:.owner) {secondExact=false}}
        let inputExact=posted==operations.map(\.count) && observed==posted
        // Proof UUID reuse is diagnostic only. Logical context/grouping must independently connect A and separate B.
        let capturePass=inputExact && aExact && bExact && source && noSend && draftStates && secondExact
        let lifecyclePass = !lifecycle || (documentReopenCount==3 && (!crossApplication || crossAppVerified))

        emit(["phase":"complete","fixture":"textedit-workflow","capturePass":capturePass,
              "pass":capturePass && continuity && lifecyclePass,"scopeHeld":!scopeLost,"continuousCapture":true,"visits":3,
              "simulatedSuspensionVerified":false,"physicalSystemSleepVerified":false,
              "diskBackedReopenOracle":persistedReopen,"editedStateRequired":!persistedReopen,
              "explicitCaretEndRequired":explicitCaretEnd,"caretPositionVerified":caretVerified,
              "saveCommandCausalityVerified":false,"powerLossDurabilityVerified":false,
              "controlKeyPairsPosted":controlPosted,"controlKeyPairsObserved":controlObserved,
              "expectedAlphaExact":aExact,"expectedBetaExact":bExact,"perContextExact":[aExact,bExact],
              "mismatchShapeAvailable":shapeAvailable,"documentMismatchShapes":documentShapes,
              "rowMismatchShapes":shapeAvailable ? observedRowShapes : [],
              "correctionKeyPairs":scenario.correctionKeyPairs,"actualOSKeyPairs":posted.reduce(0,+),
              "savedDocumentReopenVerified":lifecycle && documentReopenCount==3,"crossApplicationSwitchVerified":crossAppVerified,
              "crossApplicationRequired":lifecycle && crossApplication,"postedPerVisit":posted,"observedPerVisit":observed,
              "provenanceKnown":source,"savedRows":rows.count,"proofIdentityCounts":ids.map(\.count),
              "returnedAlphaProofIdentityStable":proofStable,"logicalContextKnown":logicalContextKnown,
              "alphaConnectedInActualMoment":grouping.alphaConnected,"betaSeparateInActualMoments":grouping.betaSeparate,
              "continuityFailure":!continuity,"draftStatesVerified":draftStates,
              "noSendClaim":noSend,"submitted":false,"draftOutcome":"unsent-text-edits",
              "secondConnectionExact":secondExact,"appRelaunchVerified":false,"physicalHumanTypingVerified":false])
        if !capturePass || !continuity || !lifecyclePass {exit(1)}
    }

}

import Foundation
import ApplicationServices
enum CaptureWorkflowContract {
    struct MismatchShape: Equatable {
        let characters: Int, utf8Bytes: Int, expectedPrefixOccurrences: Int
        let leadingASCIISpace: Bool, trailingASCIISpace: Bool, prefixCaseExact: Bool, prefixCaseOnly: Bool
        var metadata: [String:Any] {
            ["characters":characters,"utf8Bytes":utf8Bytes,"leadingASCIISpace":leadingASCIISpace,
             "trailingASCIISpace":trailingASCIISpace,"prefixCaseExact":prefixCaseExact,
             "prefixCaseOnly":prefixCaseOnly,"expectedPrefixOccurrences":expectedPrefixOccurrences,
             "duplicateExpectedPrefix":expectedPrefixOccurrences>1]
        }
    }
    static func shape(_ text: String, expectedPrefix: String) -> MismatchShape {
        let prefix=String(text.prefix(expectedPrefix.count))
        let exact = !expectedPrefix.isEmpty && prefix == expectedPrefix
        let caseOnly = !expectedPrefix.isEmpty && !exact && prefix.lowercased()==expectedPrefix.lowercased()
        let occurrences = expectedPrefix.isEmpty ? 0 : text.lowercased().components(separatedBy:expectedPrefix.lowercased()).count-1
        return MismatchShape(characters:text.count,utf8Bytes:text.utf8.count,expectedPrefixOccurrences:occurrences,
            leadingASCIISpace:text.first==" ",trailingASCIISpace:text.last==" ",prefixCaseExact:exact,prefixCaseOnly:caseOnly)
    }
    enum Operation: Equatable { case character(Character), backspace }
    /// Closed compiled table. The CLI chooses a case ID; it can never supply typing text.
    enum Scenario: String, CaseIterable {
        case interrupted = "native-interrupted-draft-v1"
        case morning = "native-morning-chess-club-v1"
        case correctedMorning = "native-corrected-morning-v1"
        var texts: [String] {
            if self == .interrupted {return CaptureWorkflowContract.texts}
            return ["i started a chess club note","write the morning plan"," about the vote and support"]
        }
        var alpha: String {texts[0]+texts[2]}
        var operations: [[Operation]] {
            texts.enumerated().map {index,text in
                var operations=text.map {Operation.character($0)}
                if self == .correctedMorning && index != 1 {operations += [.character("x"),.backspace]}
                return operations
            }
        }
        var correctionKeyPairs: Int {self == .correctedMorning ? 2 : 0}
    }
    static func fixedUSKeyboard(inputID: String, layoutID: String, flags: CGEventFlags) -> Bool {
        let modifiers: CGEventFlags = [.maskAlphaShift,.maskShift,.maskControl,.maskAlternate,.maskCommand]
        return inputID == "com.apple.keylayout.US" && layoutID == "com.apple.keylayout.US" &&
            flags.intersection(modifiers).isEmpty
    }
    static let scopeFixture = CaptureFixtureKind.textEdit
    static func retryableScopeCode(_ code: String) -> Bool {
        ["scope","focusWindow","focusField","focusTitle","focusDocument","focusRole","focusSubrole","enabled","frontApp"].contains(code)
    }
    static let texts = ["alpha draft starts", "beta draft stays separate", " and finishes here"]
    static let documents = [0,1,0]
    static var alpha: String { texts[0]+texts[2] }
    static func grouping(actionIDs: [Set<String>], moments: [Set<String>]) -> (alphaConnected: Bool, betaSeparate: Bool) {
        guard actionIDs.count == 2,!actionIDs[0].isEmpty,!actionIDs[1].isEmpty,
              actionIDs[0].isDisjoint(with:actionIDs[1]) else {return (false,false)}
        let alpha=moments.filter {!$0.isDisjoint(with:actionIDs[0])}
        let beta=moments.filter {!$0.isDisjoint(with:actionIDs[1])}
        return (alpha.count == 1 && alpha[0].isSuperset(of:actionIDs[0]),
                !beta.isEmpty && alpha.allSatisfy {$0.isDisjoint(with:actionIDs[1])} && beta.allSatisfy {$0.isDisjoint(with:actionIDs[0])})
    }
    static func names(_ root: URL) -> [String] {
        let base = CaptureFixtureKind.textEdit.documentName(root).dropLast(4)
        return [String(base)+"-A.txt", String(base)+"-B.txt"]
    }
}
// Mirrors production subrole absence: absence is explicit; transport/type/late reads refuse.
enum CaptureFixtureMetadata {
    /// Unsupported enabled metadata may be replaced only by positive editability metadata
    /// for the exactly owned TextEdit document. Explicit disabled, malformed and failed reads refuse.
    static func enabled(status: AXError, raw: CFTypeRef?, withinDeadline: Bool,
                        textEdit: Bool, editable: () -> Bool?) -> Bool {
        guard withinDeadline else { return false }
        if status == .success {
            guard let raw, CFGetTypeID(raw) == CFBooleanGetTypeID() else { return false }
            return CFBooleanGetValue((raw as! CFBoolean))
        }
        guard textEdit, status == .attributeUnsupported, raw == nil else { return false }
        return editable() == true
    }

    static func subrole(status: AXError, raw: CFTypeRef?, withinDeadline: Bool) -> String? {
        guard withinDeadline else { return nil }
        switch status {
        case .attributeUnsupported, .noValue: return ""
        case .success:
            guard let raw, CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
            return raw as? String
        default: return nil
        }
    }
    static func nonSecure(role: String?, subrole: String?) -> Bool {
        guard let role, let subrole, ["AXTextArea", "AXTextField"].contains(role),
              !role.lowercased().contains("secure"), !subrole.lowercased().contains("secure") else { return false }
        return true
    }
}

#endif

/// Private QA only: intercept before normal application construction.
#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
enum CaptureFixtureLaunch {
    enum Route { case application, fixture, refused }
    static func route(arguments: [String], ownerCompiled: Bool, info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> Route {
        if ChromeNormalMainProbeAdmission.requested(arguments) {
            return ownerCompiled && ChromeNormalMainProbeAdmission.shape(arguments, info: info) ? .application : .refused
        }
        guard arguments.contains("--capture-fixture-trial") else { return .application }
        guard ownerCompiled, arguments.count > 1, arguments[1] == "--capture-fixture-trial",
              arguments.filter({ $0 == "--capture-fixture-trial" }).count == 1 else { return .refused }
        return .fixture
    }
    static func messagesFixture(arguments: [String]) -> Bool {
        let positions = arguments.indices.filter { arguments[$0] == "--fixture" }
        guard positions.count == 1, let index = positions.first, index + 1 < arguments.count else { return false }
        return arguments[index + 1] == MessagesOwnedComposerContract.fixture
    }
    static func browserFixture(arguments: [String]) -> Bool {
        let positions = arguments.indices.filter { arguments[$0] == "--fixture" }
        guard positions.count == 1, let index = positions.first, index + 1 < arguments.count else { return false }
        return arguments[index + 1] == "chrome"
    }
}
#endif
#if !DEVELOPMENT_SOURCE_CHECKS
@main enum DaydreamApplicationEntry {
    @MainActor static func main() {
        #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
        if CommandLine.arguments.contains(NotesActivationContract.flag) {
            CaptureNotesActivation.main();return
        }
        if CommandLine.arguments.contains(NotesMetadataContract.flag) {
            CaptureNotesMetadataInspector.main();return
        }
        let route = CaptureFixtureLaunch.route(arguments: CommandLine.arguments, ownerCompiled: true)
        switch route {
        case .application: MacMemApplication.main()
        case .refused: fputs("Capture fixture rejected: unavailable or invalid route\n", stderr); exit(77)
        case .fixture:
            if CaptureFixtureLaunch.browserFixture(arguments: CommandLine.arguments) {
                CaptureBrowserFixtureTrial.main()
            } else if CaptureFixtureLaunch.messagesFixture(arguments: CommandLine.arguments) {
                CaptureMessagesFixtureTrial.main()
            } else {
                CaptureFixtureTrial.main()
            }
        }
        #else
        MacMemApplication.main()
        #endif
    }
}
#endif
