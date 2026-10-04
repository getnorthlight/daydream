// Actual signed-app Chrome fixture: strict v5c ownership + default production browser intake.
// QA entry only; never starts default history/models/updater.
// Only the separately declared permission-request route may ask macOS for Chrome access.
import AppKit
import ApplicationServices
import Carbon
import Foundation
import MemoryCore
import PrivacyPolicy
import Darwin

#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
// Additional fixture restriction only. Production witness/gates remain authoritative.
// No title or label is read. The QA-only empty-composer gate reads the exact owned
// field value transiently for a Boolean, without logging or storage. Owned URL is kept only in memory
// to refuse document navigation; never persisted, printed or disclosed.
@MainActor private final class AppOwnedChromeFixtureScope {
    let pid: pid_t
    let windowID: String
    let tabID: String
    let origin: String
    private let scenario: BrowserCaptureScenario?
    private let documentURL: String
    private let window: AXUIElement
    private let field: AXUIElement
    private let ax: ChromeAXAccess<AXUIElement>
    private let diagnostic: ([String: Any]) -> Void
    private let preflightDiagnostic: Bool
    static let allowedOrigins: Set<String> = Set(["https://x.com", "https://chatgpt.com", "https://reddit.com", "https://www.reddit.com", "https://claude.ai", "https://outlook.cloud.microsoft", "https://docs.google.com", "http://127.0.0.1:19194"]).union(ChromeFrontInspectionControls.draftOrigins)
    enum ScopeError: String, Error { case preflight, target, mode, owned, field, origin }
    static func metadataSession(pid:pid_t, preflightDiagnostic:Bool) -> ChromeModeReader.JoinSession {
        preflightDiagnostic
            ? ChromeModeReader.JoinSession(pid:pid, budget:ChromeEventSender.pageProbeBudget, eventTimeout:ChromeEventSender.pageEventTimeout)
            : ChromeModeReader.JoinSession(pid:pid)
    }
    static func normalOwnedTab(pid: pid_t, windowID: String, tabID: String, preflightDiagnostic:Bool = false, diagnostic: ([String: Any]) -> Void = { _ in }) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              !IsSecureEventInputEnabled(), ChromeEventSender.permissionStatus(pid: pid) == noErr else { return false }
        let s = metadataSession(pid:pid, preflightDiagnostic:preflightDiagnostic)
        guard case .ids(let ids)? = s.reply(.windowIDs), !ids.isEmpty, ids.contains(windowID) else { diagnostic(["stage": "window-list", "allowed": false]); return false }
        diagnostic(["stage": "window-list", "allowed": true])
        for id in ids {
            guard case .text(let mode)? = s.reply(.mode(id)) else { diagnostic(["stage":"window-modes", "allowed":false]); return false }
            guard mode == "normal" else { diagnostic(["stage":"window-modes", "allowed":false, "decodedNonNormal":true]); return false }
        }
        diagnostic(["stage": "window-modes", "allowed": true])
        guard case .text(let active)? = s.reply(.activeTabID(windowID)) else { diagnostic(["stage": "active-tab", "allowed": false]); return false }
        diagnostic(["stage": "active-tab", "allowed": active == tabID])
        return active == tabID
    }
    init(pid: pid_t, windowID: String, tabID: String, origin: String, scenario: BrowserCaptureScenario? = nil, expectedDocumentURL: String? = nil,
         expectedWindow: AXUIElement? = nil, expectedField: AXUIElement? = nil, preflightDiagnostic:Bool = false, diagnostic: @escaping ([String: Any]) -> Void = { _ in }) throws {
        diagnostic(["stage": "permission-front", "mainThread": Thread.isMainThread, "axTrusted": AXIsProcessTrusted(), "listenAllowed": CGPreflightListenEventAccess(), "secureInput": IsSecureEventInputEnabled(), "ownedFront": NSWorkspace.shared.frontmostApplication?.processIdentifier == pid])
        guard Thread.isMainThread, AXIsProcessTrusted(), CGPreflightListenEventAccess(),
              !IsSecureEventInputEnabled(), ChromeAppleEvents.validID(windowID), ChromeAppleEvents.validID(tabID),
              Self.allowedOrigins.contains(origin), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw ScopeError.preflight }
        guard let facts = ChromeTypingWitness.targetFacts(pid: pid), ChromeTargetPolicy.accepts(facts), ChromeEventSender.enabled else { throw ScopeError.target }
        diagnostic(["stage": "target", "allowed": true])
        guard Self.normalOwnedTab(pid: pid, windowID: windowID, tabID: tabID, preflightDiagnostic:preflightDiagnostic, diagnostic: diagnostic) else { throw ScopeError.mode }
        let s = Self.metadataSession(pid:pid, preflightDiagnostic:preflightDiagnostic)
        guard case .text(let url)? = s.reply(.tabURL(windowID, tabID)), BrowserSites.origin(url) == origin,
              case .bounds(let bounds)? = s.reply(.bounds(windowID)) else { throw ScopeError.owned }
        guard expectedDocumentURL == nil || expectedDocumentURL == url else { throw ScopeError.owned }
        diagnostic(["stage": "url-bounds", "allowed": true])
        let access = ChromeTypingWitness.access(pid: pid)
        guard let w = access.focusedWindow() else { diagnostic(["stage": "focused-window", "allowed": false]); throw ScopeError.field }
        guard expectedWindow == nil || CFEqual(expectedWindow!,w) else { throw ScopeError.owned }
        guard let f = access.focusedElement() else { diagnostic(["stage": "focused-field", "allowed": false]); throw ScopeError.field }
        guard expectedWindow == nil || CFEqual(expectedWindow!, w),
              expectedField == nil || CFEqual(expectedField!, f) else { throw ScopeError.owned }
        guard let b = access.frame(w) else { diagnostic(["stage": "window-frame", "allowed": false]); throw ScopeError.field }
        let geometry = ChromeFrontInspectionControls.compareGeometry(bounds, b)
        diagnostic(["stage":"window-frame", "allowed":geometry.productionMatch,
                    "valid":geometry.valid, "positionEqual":geometry.positionEqual,
                    "sizeEqual":geometry.sizeEqual, "exactMatch":geometry.exactMatch,
                    "productionMatch":geometry.productionMatch])
        guard geometry.productionMatch else { throw ScopeError.field }
        guard access.owner(w) == pid, access.owner(f) == pid else { diagnostic(["stage": "field-owner", "allowed": false]); throw ScopeError.field }
        diagnostic(["stage": "owned-ax", "allowed": true])
        self.scenario = scenario
        self.pid = pid; self.windowID = windowID; self.tabID = tabID; self.origin = origin
        window = w; field = f; ax = access; documentURL = url; self.diagnostic = diagnostic; self.preflightDiagnostic = preflightDiagnostic
        guard matches() else { throw ScopeError.owned }
    }
    private func enabled(_ e: AXUIElement) -> Bool {
        let timeoutStatus = AXUIElementSetMessagingTimeout(e, 0.025)
        guard timeoutStatus == .success else { diagnostic(["stage": "field-enabled", "allowed": false, "timeoutAXError": timeoutStatus.rawValue]); return false }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(e, kAXEnabledAttribute as CFString, &value)
        let booleanType = value.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        let allowed = status == .success && booleanType && CFBooleanGetValue(value as! CFBoolean)
        diagnostic(["stage": "field-enabled", "allowed": allowed, "readAXError": status.rawValue, "valuePresent": value != nil, "booleanType": booleanType])
        return allowed
    }
    func matches() -> Bool {
        // ALL mode checks before every wrapper AX read. Production join is separate.
        guard Thread.isMainThread, AXIsProcessTrusted(), CGPreflightListenEventAccess() else { diagnostic(["stage": "held-permission", "allowed": false]); return false }
        guard Self.normalOwnedTab(pid: pid, windowID: windowID, tabID: tabID, preflightDiagnostic:preflightDiagnostic, diagnostic: diagnostic) else { return false }
        guard case .text(let url)? = Self.metadataSession(pid:pid, preflightDiagnostic:preflightDiagnostic).reply(.tabURL(windowID, tabID)), url == documentURL else { diagnostic(["stage": "held-document", "allowed": false]); return false }
        guard let w = ax.focusedWindow() else { diagnostic(["stage": "held-window", "allowed": false]); return false }
        guard let f = ax.focusedElement() else { diagnostic(["stage": "held-field", "allowed": false]); return false }
        guard CFEqual(w, window), CFEqual(f, field) else { diagnostic(["stage": "held-refs", "allowed": false]); return false }
        guard enabled(f) else { return false }
        return true
    }
    func confirmedEmptyComposer() -> BrowserFixtureEmptyGate.Outcome {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        return BrowserFixtureEmptyGate.run(deadline: deadline,
            now: { DispatchTime.now().uptimeNanoseconds },
            scope: { self.matches() },
            proof: { self.verifiedProductionField().proof != nil },
            read: {
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(self.field, kAXValueAttribute as CFString, &value)
                return (status, value)
            })
    }
    func verifiedProductionField() -> BrowserTypingJoinResult {
        guard matches() else { return .denied(.changed) }
        // No opt-in argument: C1 and recovery retain production defaults.
        let witness = ChromeTypingWitness(design: ChromeJoinDesign.current)
        let result = witness.read(pid: pid, enabled: { [weak self] in
            guard let self else { return false }
            // Preflight brackets the unchanged production witness with exact scope reads.
            // Its enabled callback must not inject extra QA Apple Events into the product's 150 ms budget.
            if self.preflightDiagnostic { return self.preflightReady() }
            return self.matches()
        },
                                  blockList: BrowserTypingBlockList(), alwaysBlocked: BrowserTypingBlockList.pinned)
        // Even refusal diagnostics must remain attached to the declared editor.
        if preflightDiagnostic, !matches() { return .denied(.changed) }
        guard let proof = result.proof else { return result }
        guard proof.windowID == windowID, proof.tabID == tabID, proof.origin == origin,
              preflightDiagnostic || matches() else { return .denied(.changed) }
        if let scenario {
            let surface = SendRules.surface(bundle: "com.google.Chrome", host: URL(string: documentURL)?.host, field: proof.sendField)
            guard scenario.allows(origin: origin, documentURL: documentURL, surface: surface, field: proof.sendField) else { return .denied(.field) }
        }
        return result
    }
    private func preflightReady() -> Bool {
        Thread.isMainThread && AXIsProcessTrusted() && CGPreflightListenEventAccess() && !IsSecureEventInputEnabled()
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            && ChromeEventSender.enabled && ChromeEventSender.permissionStatus(pid:pid) == noErr
    }
}

private enum BrowserFixtureError: String, Error {
    case arguments, path, permissionPost, scope, proof, policy, tap, input, composerNotEmptyOrUnproved
    case wholeDraftOwnership = "whole-draft-ownership-unverified"
}

@MainActor enum CaptureBrowserFixtureTrial {
    static let marker = "qa final source amber lantern proof"
    static let declaration = "chrome-empty-unsent-v1\n"
    private static var selectedScenarioID: String?
    private static func emit(_ receipt: [String: Any]) {
        var enriched = receipt
        if let id = selectedScenarioID { enriched["caseID"] = id; enriched["workflowManifestRevision"] = 1 }
        CaptureFixtureTrial.emit(enriched)
    }
    private static func options() throws -> [String: String] {
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard args.count % 2 == 0 else { throw BrowserFixtureError.arguments }
        var out: [String: String] = [:]
        for i in stride(from: 0, to: args.count, by: 2) {
            guard ["--fixture", "--work-root", "--expected-pid", "--window-id", "--tab-id", "--origin", "--seconds", "--mode", "--input", "--scenario"].contains(args[i]),
                  out[args[i]] == nil else { throw BrowserFixtureError.arguments }
            out[args[i]] = args[i+1]
        }
        return out
    }
    // Distinct metadata and capture declarations cannot authorize one another.
    // No private field value is read to infer emptiness. Capture scope is checked separately.
    private static func checkedRoot(_ text: String, expectedDeclaration: String) throws -> URL {
        guard text.hasPrefix("/private/tmp/daydream-capture-fixture-"), !text.contains("\0"),
              let physical = realpath(text, nil) else { throw BrowserFixtureError.path }
        defer { free(physical) }
        let root = URL(fileURLWithPath: text, isDirectory: true)
        guard root.path == text, root.deletingLastPathComponent().path == "/private/tmp",
              String(cString: physical) == text else { throw BrowserFixtureError.path }
        var info = stat()
        guard lstat(text, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else { throw BrowserFixtureError.path }
        let fd = open(root.appendingPathComponent("OWNED-FIXTURE").path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw BrowserFixtureError.path }; defer { close(fd) }
        let bytes = Array(expectedDeclaration.utf8)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size == bytes.count else { throw BrowserFixtureError.path }
        var actual = [UInt8](repeating: 0, count: bytes.count)
        guard actual.withUnsafeMutableBytes({ read(fd, $0.baseAddress, $0.count) }) == bytes.count, actual == bytes,
              Set(try FileManager.default.contentsOfDirectory(atPath: text)) == ["OWNED-FIXTURE"] else { throw BrowserFixtureError.path }
        return root
    }
    private static func typedRows(_ store: MemoryStore) throws -> [Evidence] {
        let rows: [Evidence] = try Set(store.actions(limit: 200).actions.flatMap { $0.evidenceIDs }).compactMap {
            guard let e = try store.read($0)?.evidence, e.kind == "keyboard.text_input" else { return nil }
            return e
        }
        return rows.sorted {
            let a = $0.captureProvenance?.unit, b = $1.captureProvenance?.unit
            let aStart = a?.startedAt ?? $0.at, bStart = b?.startedAt ?? $1.at
            if aStart != bStart { return aStart < bStart }
            if let a, let b, a.runID != b.runID { return a.runID < b.runID }
            if let a, let b, a.part != b.part { return a.part < b.part }
            if $0.at != $1.at { return $0.at < $1.at }
            return $0.id < $1.id
        }
    }
    private static func exact(_ store: MemoryStore, rows: [Evidence], expected: String) throws -> Bool {
        try rows.compactMap { try store.hydrateTypedText($0.id, disclosure: .owner) }.joined() == expected
    }
    private static func scoped(_ rows: [Evidence], _ scope: AppOwnedChromeFixtureScope) -> Bool {
        !rows.isEmpty && rows.allSatisfy {
            WebTypedRow.valid($0) && $0.bundle == "com.google.Chrome" && !$0.synthetic && $0.text.isEmpty && $0.typed != nil &&
            $0.url == scope.origin && $0.browserVerification?.windowID == scope.windowID && $0.browserVerification?.tabID == scope.tabID
        }
    }
    private static func postOne(_ character: Character, scope: AppOwnedChromeFixtureScope,
                                coordinator: Coordinator, deadline: UInt64) throws {
        guard DispatchTime.now().uptimeNanoseconds < deadline, CGPreflightPostEventAccess(),
              coordinator.isRunning, scope.matches(), scope.verifiedProductionField().proof != nil,
              let code = BrowserCaptureScenario.codes[character], let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw BrowserFixtureError.input }
        // Fresh strict ownership and Post gate immediately before each actual OS key pair.
        guard DispatchTime.now().uptimeNanoseconds < deadline, scope.matches(), AXIsProcessTrusted(), CGPreflightPostEventAccess(),
              !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == scope.pid else { throw BrowserFixtureError.input }
        down.flags = []; up.flags = []
        down.post(tap: .cgSessionEventTap); up.post(tap: .cgSessionEventTap)
    }
    static func main() {
        do { try run() }
        catch {
            emit(["phase": "blocked", "code": (error as? BrowserFixtureError)?.rawValue ?? (error as? CaptureChromeFrontInspection.Refusal)?.rawValue ?? (error as? CaptureChromeAutomationRequest.Refusal)?.rawValue ?? (error as? CaptureChromeAutomationRequestUI.Refusal)?.rawValue ?? "harness-operation",
                  "scopeCategory": (error as? AppOwnedChromeFixtureScope.ScopeError)?.rawValue ?? "none", "tapProof": false])
            exit(77)
        }
    }
    private static func run() throws {
        try CaptureFixtureTrial.authenticate()
        var o = try options()
        var bootstrapRoot: URL?
        var expectedDocumentURL: String?
        var bootstrapWindow: AXUIElement?
        var bootstrapField: AXUIElement?
        if o["--mode"] == "site-capture" {
            guard let request = ChromeComposerCaptureRequest.parse(o) else { throw BrowserFixtureError.arguments }
            selectedScenarioID = request.caseID
            guard ChromeComposerCaptureRequest.bootstrapCaptureSupported(request.caseID) else { throw BrowserFixtureError.wholeDraftOwnership }
            let reserved = try checkedRoot(request.root, expectedDeclaration: "chrome-owned-bootstrap-capture-v1\n")
            try CaptureFixtureTrial.reserveOutput(reserved)
            emit(["phase": "bootstrap-started", "captureStarted": false, "storeOpened": false, "composerInputPosted": false])
            do {
                let owned = try ChromeOwnedComposerBootstrap.createAndFocus(scenario: request.caseID, pid: request.pid)
                guard let origin = BrowserSites.origin(owned.documentURL) else { throw BrowserFixtureError.scope }
                bootstrapRoot = reserved; expectedDocumentURL = owned.documentURL; bootstrapField = owned.field; bootstrapWindow = owned.window
                o["--window-id"] = owned.windowID; o["--tab-id"] = owned.tabID; o["--origin"] = origin; o["--mode"] = "capture"
                emit(["phase": "bootstrap-ready", "windowID": owned.windowID, "tabID": owned.tabID,
                      "navigationInputPosted": true, "selectedFieldFocused": true, "ownedSelectedFieldEmpty": false,
                      "productionFieldProofGranted": false, "captureStarted": false, "storeOpened": false, "composerInputPosted": false,
                      "liveCapturePassed": false])
            } catch {
                emit(["phase": "blocked", "code": (error as? ChromeOwnedComposerBootstrap.Failure)?.rawValue ?? (error as? RedditNativeBootstrap.Failure)?.rawValue ?? "bootstrap-operation",
                      "captureStarted": false, "storeOpened": false, "composerInputPosted": false])
                throw error
            }
        }
        // Closed search-only end-to-end path. Title capture remains blocked:
        // an empty Title is not proof the whole restored post draft is empty.
        if o["--mode"] == "reddit-capture" {
            guard let request = RedditCombinedCaptureRequest.parse(o) else { throw BrowserFixtureError.arguments }
            let root = request.root, pid = request.pid
            let reserved = try checkedRoot(root, expectedDeclaration: "reddit-owned-bootstrap-capture-v1\n")
            try CaptureFixtureTrial.reserveOutput(reserved)
            emit(["phase": "bootstrap-started", "scenario": "reddit-search-v1",
                  "captureStarted": false, "storeOpened": false, "composerInputPosted": false])
            do {
                let created = try RedditNativeBootstrap.create("search", pid: pid)
                let owned = try RedditNativeBootstrap.focus(pid: pid, windowID: created.windowID, tabID: created.tabID,
                                                           documentURL: created.documentURL, kind: .search)
                guard let origin = BrowserSites.origin(owned.documentURL) else { throw BrowserFixtureError.scope }
                bootstrapRoot = reserved
                expectedDocumentURL = owned.documentURL // In memory only; never log or serialize.
                bootstrapWindow = owned.window; bootstrapField = owned.field
                o["--window-id"] = owned.windowID; o["--tab-id"] = owned.tabID; o["--origin"] = origin
                o["--mode"] = "capture"
                emit(["phase": "bootstrap-ready", "scenario": "reddit-search-v1",
                      "windowID": owned.windowID, "tabID": owned.tabID, "observedPID": pid,
                      "ownedSelectedFieldEmpty": true, "captureStarted": false, "storeOpened": false,
                      "composerInputPosted": false, "navigationInputPosted": true, "liveCapturePassed": false])
            } catch {
                emit(["phase": "blocked", "scenario": "reddit-search-v1",
                      "code": (error as? RedditNativeBootstrap.Failure)?.rawValue ?? "bootstrap-operation",
                      "captureStarted": false, "storeOpened": false, "composerInputPosted": false])
                throw error
            }
        }
        let scenario = o["--scenario"].flatMap(BrowserCaptureScenario.named)
        guard o["--scenario"] == nil || scenario != nil else { throw BrowserFixtureError.arguments }
        guard scenario == nil || ["preflight", "capture"].contains(o["--mode"] ?? "") else { throw BrowserFixtureError.arguments }
        selectedScenarioID = scenario?.id
        let expectedText = scenario?.text ?? marker
        if o["--mode"] == ChromeAutomationRequestControls.uiMode {
            try CaptureChromeAutomationRequestUI.run(o) {
                try checkedRoot($0, expectedDeclaration: ChromeAutomationRequestControls.uiDeclaration)
            }
            return
        }
        if o["--mode"] == ChromeAutomationRequestControls.mode {
            try CaptureChromeAutomationRequest.run(o) {
                try checkedRoot($0, expectedDeclaration: ChromeAutomationRequestControls.declaration)
            }
            return
        }
        if o["--mode"] == ChromeFrontInspectionControls.mode {
            try CaptureChromeFrontInspection.run(o) {
                try checkedRoot($0, expectedDeclaration: ChromeFrontInspectionControls.declaration)
            }
            return
        }
        guard o["--fixture"] == "chrome", let root = o["--work-root"],
              let pid = o["--expected-pid"].flatMap(Int32.init), pid > 0,
              let wid = o["--window-id"], let tid = o["--tab-id"], let origin = o["--origin"],
              ((scenario?.origins.contains(origin) ?? ["https://x.com", "https://chatgpt.com"].contains(origin)) || ChromeFrontInspectionControls.allowsDraftInspection(origin:origin,mode:o["--mode"])),
              let mode = o["--mode"], ["preflight", "capture"].contains(mode),
              let seconds = Double(o["--seconds"] ?? "30"), (20...45).contains(seconds) else { throw BrowserFixtureError.arguments }
        let inputMode = o["--input"] ?? "operator"
        guard ["operator", "fixed-marker"].contains(inputMode), scenario == nil || inputMode == "fixed-marker" else { throw BrowserFixtureError.arguments }
        let fixtureRoot: URL
        if let reserved = bootstrapRoot { fixtureRoot = reserved }
        else {
            fixtureRoot = try checkedRoot(root, expectedDeclaration: declaration)
            try CaptureFixtureTrial.reserveOutput(fixtureRoot)
        }
        let transportOutcomes = ChromeEventSender.QAOutcomeBuffer()
        if mode == "preflight" { ChromeEventSender.observeQA { transportOutcomes.record($0) } }
        defer {
            ChromeEventSender.observeQA(nil)
            for outcome in transportOutcomes.drain() { emit(["phase":"qa-transport", "outcome":outcome.rawValue]) }
        }
        if inputMode == "fixed-marker", !CGPreflightPostEventAccess() { throw BrowserFixtureError.permissionPost }
        let diagnostic: ([String: Any]) -> Void = { item in
            if mode == "preflight" { var safe = item; safe["phase"] = "preflight-stage"; emit(safe) }
        }
        let scope = try AppOwnedChromeFixtureScope(pid: pid, windowID: wid, tabID: tid, origin: origin, scenario: scenario, expectedDocumentURL: expectedDocumentURL,
                                                    expectedWindow: bootstrapWindow, expectedField: bootstrapField, preflightDiagnostic:mode == "preflight", diagnostic: diagnostic)
        let verified = scope.verifiedProductionField()
        guard verified.proof != nil else {
            emit(["phase": "blocked", "code": "production-browser-field-refused", "refusal": verified.denial?.rawValue ?? "unknown"])
            throw BrowserFixtureError.proof
        }
        if inputMode == "fixed-marker" {
            let empty = scope.confirmedEmptyComposer()
            var receipt: [String: Any] = ["phase": "preflight-stage", "stage": "owned-composer-empty",
                "allowed": empty.allowed, "result": empty.result.rawValue,
                "captureStarted": false, "storeOpened": false, "inputPosted": false]
            if let error = empty.axError { receipt["readAXError"] = error }
            emit(receipt)
            guard empty.allowed else { throw BrowserFixtureError.composerNotEmptyOrUnproved }
        }
        if mode == "preflight" {
            emit(["phase": "preflight", "allowed": true, "scopeHeld": true, "fixture": "chrome",
                  "productionProofAllowed": true, "captureStarted": false, "storeOpened": false, "inputPosted": false])
            return
        }
        let home = try CaptureFixtureTrial.newHome(root)
        emit(["phase": "isolated-store-created", "seconds": seconds, "axPreflight": true, "listenPreflight": true, "chromeScopeBound": true])
        let keys = InMemoryTypedKeyStore()
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        try store.attachVault(TypedTextVault(keyStore: keys)); try store.setUpTypedVault(); try store.acceptSafeTyping()
        var savedPolicy = try store.policy()
        savedPolicy.captureText = true; savedPolicy.typedConsentVersion = 1
        savedPolicy.browserPages = true; savedPolicy.browserPagesConsentVersion = PrivacySettings.browserPagesConsentCurrent
        try store.updatePolicy(savedPolicy); try store.setSummaryWriter("off")
        let coordinator = try Coordinator(store: store, permissions: { scope.matches() }) {}
        coordinator.captureText = true
        var pages = ChromePageEnvironment.live; pages.frontmost = { nil }
        // No typingEnvironment or web-route substitution: production defaults remain authoritative.
        let capture = EventCapture(coordinator: coordinator, pageEnvironment: pages)
        CaptureDiagnostics.shared.setEnabled(true)
        var keyEvents = 0, scopeLost = false, typedCommitReceipts = 0
        capture.onKeyInput = { if scope.matches() { keyEvents += 1 } else { scopeLost = true } }
        coordinator.onNativeCommitted = { if $0.path == .typedText { typedCommitReceipts += 1 } }
        try coordinator.start()
        let armedContext = try coordinator.captureBinding.context()
        guard armedContext.policy.typedText else { coordinator.stop(); throw BrowserFixtureError.policy }
        guard scope.matches(), coordinator.allowsApp("com.google.Chrome"), scope.verifiedProductionField().proof != nil else {
            coordinator.stop(); throw BrowserFixtureError.proof
        }
        guard capture.start() else { coordinator.stop(); throw BrowserFixtureError.tap }
        defer { capture.stop(reason: "Bounded browser app fixture exit"); coordinator.stop() }
        let began = DispatchTime.now().uptimeNanoseconds
        let deadline = began + UInt64(seconds * 1_000_000_000)
        // Root-approved browser-specific overall input budget. Per-proof deadlines stay unchanged.
        let inputDeadline = began + 12_000_000_000
        let characters = Array(expectedText)
        var posted = 0, inputFailed = false, driverReported = false, nextInputAt = began
        var interruptionCompleted = false, firstPartSaved = false
        emit(["phase": "armed", "realEventCaptureStart": true, "operatorSendsInput": inputMode == "operator",
              "seconds": seconds, "scopeHeld": true, "inputMode": inputMode, "fixture": "chrome", "chromeLane": "production-default",
              "isolatedSavedTypingEnabled": true, "effectiveTypingGateEnabled": true, "freshProductionBrowserProofAllowedBeforeArm": true])
        if inputMode == "fixed-marker" { emit(["phase": "driver-started", "keyCount": 0, "submitted": false, "inputDeadlineSeconds": 12]) }
        while DispatchTime.now().uptimeNanoseconds < deadline && !capture.isStopped {
            if !scope.matches() { scopeLost = true; inputFailed = inputMode == "fixed-marker"; break }
            if let boundary = scenario?.pauseAfterKey, posted == boundary, !interruptionCompleted {
                let expectedPrefix = String(expectedText.prefix(boundary))
                let prefixSavedBeforeIdle = try exact(store, rows: typedRows(store), expected: expectedPrefix)
                // Real idle: do not force a partial flush or substitute a scheduler.
                let pauseDeadline = DispatchTime.now().uptimeNanoseconds + 4_500_000_000
                while DispatchTime.now().uptimeNanoseconds < pauseDeadline {
                    guard scope.matches() else { scopeLost = true; break }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                guard !scopeLost, scope.verifiedProductionField().proof != nil else { inputFailed = true; break }
                let prefixSavedAfterIdle = try exact(store, rows: typedRows(store), expected: expectedPrefix)
                firstPartSaved = !prefixSavedBeforeIdle && prefixSavedAfterIdle
                emit(["phase": "workflow-part-saved", "part": 0, "postedKeyPairs": posted,
                      "partialTextExact": firstPartSaved, "savedDuringRealPauseVerified": firstPartSaved, "naturalIdleSealVerified": false,
                      "fixtureForcedPartialFlush": false, "prefixSavedBeforeIdle": prefixSavedBeforeIdle, "scopeHeld": true, "contextSwitchVerified": false, "submitted": false])
                guard firstPartSaved else { inputFailed = true; break }
                interruptionCompleted = true
                nextInputAt = DispatchTime.now().uptimeNanoseconds
                emit(["phase": "workflow-part-resumed", "part": 1, "scopeHeld": true, "contextSwitchVerified": false, "submitted": false])
            }
            if inputMode == "fixed-marker", posted < characters.count, DispatchTime.now().uptimeNanoseconds >= nextInputAt {
                do { try postOne(characters[posted], scope: scope, coordinator: coordinator, deadline: inputDeadline) }
                catch { inputFailed = true; break }
                posted += 1; nextInputAt = DispatchTime.now().uptimeNanoseconds + 80_000_000
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if inputMode == "fixed-marker", posted == characters.count, !driverReported {
                let held = scope.matches() && CGPreflightPostEventAccess() && !IsSecureEventInputEnabled()
                emit(["phase": held ? "driver-complete" : "driver-blocked", "scopeHeld": held,
                      "markerPostedOnce": held, "keyCount": posted, "submitted": false, "physicalHumanTyping": false,
                      "inputElapsedSeconds": Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000])
                driverReported = true
                if !held { inputFailed = true; break }
            }
        }
        if inputMode == "fixed-marker", !driverReported {
            let held = scope.matches(), done = !inputFailed && posted == characters.count && scope.matches()
            emit(["phase": done ? "driver-complete" : "driver-blocked", "scopeHeld": held,
                  "markerPostedOnce": done, "keyCount": posted, "submitted": false, "physicalHumanTyping": false,
                  "inputElapsedSeconds": Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000])
            inputFailed = !done
        }
        var heldScope = scope.matches() && !scopeLost
        if heldScope {
            var finished = false
            capture.finishPendingTyping { finished = true }
            let drainDeadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            while !finished && DispatchTime.now().uptimeNanoseconds < drainDeadline {
                if !scope.matches() { scopeLost = true; break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            if !finished { scopeLost = true }
        }
        heldScope = heldScope && scope.matches() && !scopeLost
        capture.stop(reason: "Bounded Chrome app fixture complete"); coordinator.stop()
        let rows = try typedRows(store), markerExact = try exact(store, rows: rows, expected: expectedText), sourceExact = scoped(rows, scope)
        let actions = try store.actions(limit: 200).actions
        let rowIDs = Set(rows.map { $0.id })
        let typedActions = actions.filter { !Set($0.evidenceIDs).isDisjoint(with: rowIDs) }
        let draftStates = !typedActions.isEmpty && Set(typedActions.flatMap { $0.evidenceIDs }).isSuperset(of: rowIDs) && typedActions.allSatisfy { $0.kind == "keyboard.text_input" && $0.state == "draft" }
        let metadataExact = scenario.map { selected in !rows.isEmpty && rows.allSatisfy {
            selected.storedMetadataMatches(surface: $0.captureProvenance?.unit?.surface, field: $0.captureProvenance?.unit?.field, send: $0.captureProvenance?.unit?.send)
        } } ?? true
        let noSend = actions.allSatisfy { $0.state != "sent" && $0.state != "submitted" }
        let reopened = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        try reopened.attachVault(TypedTextVault(keyStore: keys))
        let reopenedRows = try typedRows(reopened), reopenExact = try exact(reopened, rows: reopenedRows, expected: expectedText)
        let sameRows = Set(rows.map { $0.id }) == Set(reopenedRows.map { $0.id })
        let passed = !inputFailed && heldScope && !scopeLost && keyEvents > 0 && !rows.isEmpty && markerExact && sourceExact && reopenExact && sameRows && noSend && draftStates && metadataExact && (scenario?.pauseAfterKey == nil || (interruptionCompleted && firstPartSaved))
        var receipt: [String: Any] = ["phase": "complete", "realEventCaptureStart": true,
            "tapKeyEvents": keyEvents, "nativeTypedCommitReceipts": typedCommitReceipts, "typedSavedRows": rows.count, "savedRows": rows.count,
            "expectedMarkerExact": markerExact, "expectedScenarioTextExact": markerExact, "draftStatesVerified": draftStates, "storedSurfaceFieldExact": metadataExact, "submitted": false, "sourceExact": sourceExact, "browserSourceExact": sourceExact,
            "reopenedMarkerExact": reopenExact, "reopenedSameRows": sameRows, "scopeHeld": heldScope, "noSendClaim": noSend,
            "elapsedSeconds": Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000, "pass": passed, "capturePass": passed, "sourceSelectedInput": scenario != nil, "interruptedInputVerified": interruptionCompleted && firstPartSaved, "savedDuringRealPauseVerified": interruptionCompleted && firstPartSaved, "naturalIdleSealVerified": false, "fixtureForcedPartialFlush": false, "contextSwitchVerified": false, "searchQueryDraftOnly": scenario?.surface == "search", "searchSubmittedVerified": false,
            "isActualOSInput": keyEvents > 0, "inputOriginVerifiedByOperator": false, "appFixturePostedKeyPairs": posted,
            "inputMode": inputMode, "cgSyntheticAppInput": inputMode == "fixed-marker", "expectedInputKeyPairs": characters.count, "physicalHumanTypingVerified": false,
            "chromeTypingVerified": passed, "appRelaunchVerified": false, "diagnostics": CaptureDiagnostics.shared.snapshot(),
            "fixtureAdmissionScopeGuard": true, "prearmBrowserReadsPerformed": true, "coldFirstKeyVerified": false,
            "formSearchRecoveryEnabledByHarness": false, "bracketedBoundaryRecoveryEnabledByHarness": false]
        if let id = selectedScenarioID { receipt["caseID"] = id; receipt["workflowManifestRevision"] = 1 }
        try JSONSerialization.data(withJSONObject: CaptureFixtureTrial.enriched(receipt), options: [.sortedKeys]).write(to: home.appendingPathComponent("receipt.json"), options: .atomic)
        emit(receipt)
        if !passed { exit(1) }
    }
}
#endif
