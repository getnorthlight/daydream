import AppKit
import ApplicationServices
import Carbon
import Foundation
#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING

enum ClaudeEmptyIssue: String { case late, transport, absent, wrongType, invalidNumber, nonzero }
enum ClaudeGuardRefusal: String { case deadline, readiness, windowUnavailable, editorUnavailable, ownerMismatch, roleUnusable, parentUnavailable, pageNotNew, notEditable, zeroUnverified, areaCount, retainedAreaMismatch, depthLimit, cycle, scopeOrAncestry }
struct ClaudeComposerDiagnostic {
    let refusal: ClaudeGuardRefusal
    let phase: String, lastRead: String, elapsedNanoseconds: UInt64
    let clockWentBackwards: Bool, aggregateExpired: Bool, deadlineCheckRefused: Bool
    let ready: Bool?, windowAvailable: Bool?, editorAvailable: Bool?, ownerMatches: Bool?
    let roleClass: String?, newPage: Bool?, editable: Bool?, typedZero: Bool?
    let parentAvailable: Bool?
    let visitedCount: Int, depthLimitReached: Bool, cycleDetected: Bool
    let areaCount: Int?, retainedAreaMatches: Bool?, emptyIssue: ClaudeEmptyIssue?
}
private final class ClaudeComposerTrace {
    let phase: String, began: UInt64, pid: Int32
    var deadlineCheckRefused=false, backwardsObserved=false
    var parentAvailable: Bool?
    var visitedCount=0, depthLimitReached=false, cycleDetected=false
    var lastRead="none", ready: Bool?, windowAvailable: Bool?, editorAvailable: Bool?, ownerMatches: Bool?
    var roleClass: String?, newPage: Bool?, editable: Bool?, typedZero: Bool?, areaCount: Int?, retainedAreaMatches: Bool?, emptyIssue: ClaudeEmptyIssue?
    init(_ phase: String, _ began: UInt64, _ pid: Int32) { self.phase=phase;self.began=began;self.pid=pid }
    func result(ended: UInt64) -> ClaudeComposerDiagnostic {
        let backwards=ended<began || backwardsObserved, elapsed=ended>=began ? ended-began : 0
        let expired=backwards || elapsed>100_000_000
        let refusal:ClaudeGuardRefusal
        if deadlineCheckRefused {refusal = .deadline}
        else if ready == false {refusal = .readiness}
        else if windowAvailable == false {refusal = .windowUnavailable}
        else if editorAvailable == false {refusal = .editorUnavailable}
        else if ownerMatches == false {refusal = .ownerMismatch}
        else if lastRead == "role" && (roleClass == "unreadable" || roleClass == "secure") {refusal = .roleUnusable}
        else if cycleDetected {refusal = .cycle}
        else if depthLimitReached {refusal = .depthLimit}
        else if parentAvailable == false {refusal = .parentUnavailable}
        else if areaCount != nil && areaCount != 1 {refusal = .areaCount}
        else if retainedAreaMatches == false {refusal = .retainedAreaMismatch}
        else if newPage == false {refusal = .pageNotNew}
        else if editable == false {refusal = .notEditable}
        else if typedZero == false {refusal = .zeroUnverified}
        else {refusal = .scopeOrAncestry}
        return ClaudeComposerDiagnostic(refusal:refusal,phase:phase,lastRead:lastRead,elapsedNanoseconds:elapsed,clockWentBackwards:backwards,
            aggregateExpired:expired,deadlineCheckRefused:deadlineCheckRefused,ready:ready,windowAvailable:windowAvailable,editorAvailable:editorAvailable,
            ownerMatches:ownerMatches,roleClass:roleClass,newPage:newPage,editable:editable,typedZero:typedZero,
            parentAvailable:parentAvailable,visitedCount:visitedCount,depthLimitReached:depthLimitReached,cycleDetected:cycleDetected,areaCount:areaCount,retainedAreaMatches:retainedAreaMatches,emptyIssue:emptyIssue)
    }
    static func role(_ value: String?) -> String {
        guard let value else { return "unreadable" }
        if value.lowercased().contains("secure") { return "secure" }
        switch value { case "AXTextArea":return "text-area";case "AXTextField":return "text-field";case "AXWebArea":return "web-area";case "AXWindow":return "window";default:return "other" }
    }
}

/// The desktop AI app an owned-composer fixture binds (QA only). Claude: its new-chat page. ChatGPT (`com.openai.codex`,
/// the Electron app installed as ChatGPT.app): its bundled UI page (never an https page), which must stay the exact page
/// the composer was bound on; that it is a new, empty chat is the operator's prepared declaration plus the empty check.
enum OwnedComposerApp: String {
    case claude, chatGPT
    var bundle: String { self == .claude ? "com.anthropic.claudefordesktop" : "com.openai.codex" }
    var windowTitle: String { self == .claude ? "Claude" : "ChatGPT" }
    /// A fresh page rule per binding. Pure; the page URL is kept in memory only and never reported.
    func pageRule() -> (String?) -> Bool {
        switch self {
        case .claude: return ClaudeComposerMetadata.newURL
        case .chatGPT:
            var bound: String?
            return { url in
                guard let url, ChatGPTComposerMetadata.bundledPage(url) else { return false }
                if let bound { return bound == url }
                bound = url; return true
            }
        }
    }
}
enum ChatGPTComposerMetadata {
    /// The app's own UI (bundled files), never a web page on another host (`TypingCategories`: `.electron`, no hosts).
    static func bundledPage(_ text: String) -> Bool {
        guard text.utf8.count <= 2048, let scheme = URL(string: text)?.scheme?.lowercased() else { return false }
        return !["http", "https", "data", "javascript", "about", "blob"].contains(scheme)
    }
}
/// QA-only ownership constraint. Never supplies production capture/privacy authority.
enum ClaudeComposerMetadata {
    static func drafts(rowIDs: Set<String>, actions: [(ids: Set<String>, kind: String, state: String)]) -> Bool {
        guard !rowIDs.isEmpty else { return false }
        let relevant = actions.filter { !$0.ids.isDisjoint(with: rowIDs) }
        return !relevant.isEmpty && relevant.reduce(into: Set<String>()) { $0.formUnion($1.ids) }.isSuperset(of: rowIDs) &&
            relevant.allSatisfy { $0.kind == "keyboard.text_input" && $0.state == "draft" }
    }
    static func newURL(_ text: String?) -> Bool { text == "https://claude.ai/new" }
    static func empty(status: AXError, raw: CFTypeRef?, timely: Bool) -> Bool {
        emptyResult(status:status,raw:raw,timely:timely).zero
    }
    static func emptyResult(status: AXError, raw: CFTypeRef?, timely: Bool) -> (zero: Bool, issue: ClaudeEmptyIssue?) {
        guard timely else { return (false,.late) }
        guard status == .success else { return (false,status == .attributeUnsupported || status == .noValue ? .absent : .transport) }
        guard let raw else { return (false,.absent) }
        guard CFGetTypeID(raw) == CFNumberGetTypeID() else { return (false,.wrongType) }
        var count = Double.nan
        guard CFNumberGetValue((raw as! CFNumber), .doubleType, &count), count.isFinite else { return (false,.invalidNumber) }
        return count == 0 ? (true,nil) : (false,.nonzero)
    }
}
struct ClaudeComposerAccess<Node> {
    let now: () -> UInt64
    let ready: () -> Bool
    let window: () -> Node?
    let editor: () -> Node?
    let owner: (Node) -> Int32?
    let role: (Node) -> String?
    let parent: (Node) -> Node?
    let equal: (Node, Node) -> Bool
    let url: (Node) -> String?
    let editable: (Node) -> Bool
    let empty: (Node) -> Bool
    var emptyIssue: () -> ClaudeEmptyIssue? = { nil }
    var diagnostic: (ClaudeComposerDiagnostic) -> Void = { _ in }
    /// The bound page's rule (`OwnedComposerApp.pageRule`); Claude's new-chat URL by default.
    var page: (String?) -> Bool = ClaudeComposerMetadata.newURL
    /// Records only results of the guard's existing reads. No new AX reads or admission authority.
    fileprivate func traced(_ t: ClaudeComposerTrace) -> ClaudeComposerAccess<Node> {
        ClaudeComposerAccess(now:{let v=self.now();if v<t.began {t.backwardsObserved=true;t.deadlineCheckRefused=true}else if v-t.began>100_000_000 {t.deadlineCheckRefused=true};return v},ready:{t.lastRead="readiness";let v=self.ready();t.ready=v;return v},
            window:{t.lastRead="window";let v=self.window();t.windowAvailable=v != nil;return v},
            editor:{t.lastRead="editor";let v=self.editor();t.editorAvailable=v != nil;return v},
            owner:{t.lastRead="owner";let v=self.owner($0);t.ownerMatches=v==t.pid;return v},
            role:{t.lastRead="role";let v=self.role($0);t.roleClass=ClaudeComposerTrace.role(v);return v},
            parent:{t.lastRead="parent";let v=self.parent($0);t.parentAvailable=v != nil;return v},equal:equal,
            url:{t.lastRead="page";let v=self.url($0);t.newPage=self.page(v);return v},
            editable:{t.lastRead="editable";let v=self.editable($0);t.editable=v;return v},
            empty:{t.lastRead="empty";let v=self.empty($0);t.typedZero=v;t.emptyIssue=v ? nil : self.emptyIssue();return v},
            emptyIssue:emptyIssue,diagnostic:diagnostic,page:page)
    }
}
/// The exact retained editor, ancestry, web area and window are checked afresh.
final class ClaudeOwnedComposer<Node> {
    static var budget: UInt64 { 100_000_000 }
    // Match the production embedded-web witness depth; time and per-call bounds stay unchanged.
    static var maxDepth: Int { 64 }
    let pid: Int32, window: Node, editor: Node, area: Node, path: [Node]
    private let access: ClaudeComposerAccess<Node>
    private init(pid: Int32, window: Node, editor: Node, area: Node, path: [Node], access: ClaudeComposerAccess<Node>) {
        self.pid = pid; self.window = window; self.editor = editor; self.area = area; self.path = path; self.access = access
    }
    static func bind(pid: Int32, window: Node, editor: Node, access original: ClaudeComposerAccess<Node>) -> ClaudeOwnedComposer? {
        let began = original.now()
        let trace=ClaudeComposerTrace("bind",began,pid)
        let a=original.traced(trace)
        var complete=false
        defer { if !complete { original.diagnostic(trace.result(ended:original.now())) } }
        guard pid > 0, a.ready(), let path = walk(pid: pid, window: window, editor: editor, access: a, began: began, trace: trace) else { return nil }
        var areas: [Node] = []
        for node in path { guard timely(a,began), let role = a.role(node) else { return nil }; if role == "AXWebArea" { areas.append(node) } }
        trace.areaCount=areas.count
        guard areas.count == 1, let area = areas.first, timely(a, began), original.page(a.url(area)),
              timely(a, began), a.editable(editor), timely(a, began), a.empty(editor), timely(a, began) else { return nil }
        let bound = ClaudeOwnedComposer(pid: pid, window: window, editor: editor, area: area, path: path, access: original)
        complete=true // Nested retained-match refusal reports its own trace once.
        guard bound.matches(began: began) else { return nil }
        return bound
    }
    func matches() -> Bool { matches(began: access.now()) }
    func initiallyEmpty() -> Bool {
        let began = access.now()
        guard matches(began:began) else { return false }
        let trace=ClaudeComposerTrace("initial-empty",began,pid), a=access.traced(trace)
        let result=Self.timely(a,began) && a.empty(editor) && Self.timely(a,began) && a.ready()
        if !result { access.diagnostic(trace.result(ended:access.now())) }
        return result
    }
    private func matches(began: UInt64) -> Bool {
        let trace=ClaudeComposerTrace("retained-match",began,pid)
        let observed=access.traced(trace)
        return matchObserved(began:began,access:observed,trace:trace)
    }
    private func matchObserved(began: UInt64, access a: ClaudeComposerAccess<Node>, trace: ClaudeComposerTrace) -> Bool {
        var complete=false
        defer { if !complete { access.diagnostic(trace.result(ended:access.now())) } }
        guard Self.timely(a, began), a.ready(), Self.timely(a,began), let w = a.window(), Self.timely(a,began), let f = a.editor(), a.equal(w, window), a.equal(f, editor),
              let current = Self.walk(pid: pid, window: w, editor: f, access: a, began: began, trace: trace), current.count == path.count,
              zip(current,path).allSatisfy({ a.equal($0,$1) }), Self.singleArea(current, equals: area, access: a, began: began, trace:trace),
              Self.timely(a, began), access.page(a.url(area)),
              Self.timely(a, began), a.editable(editor), Self.timely(a, began),
              let endWindow = a.window(), Self.timely(a,began), let endEditor = a.editor(), a.equal(endWindow,window), a.equal(endEditor,editor),
              Self.timely(a, began), access.page(a.url(area)), Self.timely(a, began), a.ready() else { return false }
        complete=true
        return true
    }
    private static func singleArea(_ path: [Node], equals retained: Node, access a: ClaudeComposerAccess<Node>, began: UInt64, trace: ClaudeComposerTrace) -> Bool {
        var areas: [Node] = []
        for node in path {
            guard timely(a,began), let role = a.role(node) else { return false }
            if role == "AXWebArea" { areas.append(node) }
        }
        trace.areaCount=areas.count
        guard areas.count == 1 else { return false }
        let same=a.equal(areas[0],retained);trace.retainedAreaMatches=same
        return same && timely(a,began)
    }
    private static func timely(_ a: ClaudeComposerAccess<Node>, _ began: UInt64) -> Bool {
        let now = a.now(); return now >= began && now - began <= budget
    }
    private static func walk(pid: Int32, window: Node, editor: Node, access a: ClaudeComposerAccess<Node>, began: UInt64, trace: ClaudeComposerTrace) -> [Node]? {
        guard timely(a,began), let editorRole = a.role(editor), ["AXTextArea","AXTextField"].contains(editorRole) else { return nil }
        var next: Node? = editor, path: [Node] = []
        for _ in 0..<maxDepth {
            guard timely(a,began), let node = next, a.owner(node) == pid, timely(a,began), let role = a.role(node),
                  !role.lowercased().contains("secure") else { return nil }
            if path.contains(where: { a.equal($0,node) }) {trace.cycleDetected=true;return nil}
            path.append(node);trace.visitedCount=path.count
            if a.equal(node,window) { return role == "AXWindow" && timely(a,began) ? path : nil }
            guard timely(a,began) else { return nil }; next = a.parent(node)
        }
        trace.depthLimitReached=next != nil
        return nil
    }
}

@MainActor enum ClaudeOwnedComposerAX {
    static func bind(pid: pid_t, window: AXUIElement, editor: AXUIElement, app: OwnedComposerApp = .claude,
                     diagnostic: @escaping (ClaudeComposerDiagnostic) -> Void = { _ in }) -> ClaudeOwnedComposer<AXUIElement>? {
        guard AXIsProcessTrusted() else { return nil }   // perm-1004: never an Accessibility read while untrusted
        let root = AXUIElementCreateApplication(pid)
        var emptyIssue:ClaudeEmptyIssue?
        let a = ClaudeComposerAccess<AXUIElement>(now: { DispatchTime.now().uptimeNanoseconds }, ready: {
            Thread.isMainThread && AXIsProcessTrusted() && CGPreflightListenEventAccess() && !IsSecureEventInputEnabled() &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid &&
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app.bundle
        }, window: { element(root,kAXFocusedWindowAttribute) }, editor: { element(root,kAXFocusedUIElementAttribute) }, owner: {
            guard AXUIElementSetMessagingTimeout($0,0.025) == .success else { return nil }
            var actual: pid_t = 0; return AXUIElementGetPid($0,&actual) == .success ? actual : nil
        }, role: { string($0,kAXRoleAttribute) }, parent: { element($0,kAXParentAttribute) }, equal: { CFEqual($0,$1) }, url: {
            guard let raw = read($0,"AXURL").1 else { return nil }
            return (raw as? String) ?? (raw as? URL)?.absoluteString
        }, editable: {
            guard AXUIElementSetMessagingTimeout($0,0.025) == .success else { return false }
            var canEdit = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable($0,kAXSelectedTextAttribute as CFString,&canEdit) == .success && canEdit.boolValue
        }, empty: {
            let began = DispatchTime.now().uptimeNanoseconds
            let (status,raw) = read($0,kAXNumberOfCharactersAttribute)
            let result=ClaudeComposerMetadata.emptyResult(status:status,raw:raw,timely:DispatchTime.now().uptimeNanoseconds - began <= 25_000_000)
            emptyIssue=result.issue;return result.zero
        },emptyIssue:{emptyIssue},diagnostic:diagnostic,page:app.pageRule())
        return ClaudeOwnedComposer.bind(pid: pid,window: window,editor: editor,access: a)
    }
    private static func read(_ node: AXUIElement, _ name: String) -> (AXError,CFTypeRef?) {
        guard AXUIElementSetMessagingTimeout(node,0.025) == .success else { return (.cannotComplete,nil) }
        var raw: CFTypeRef?; let status = AXUIElementCopyAttributeValue(node,name as CFString,&raw)
        return (status, status == .success ? raw : nil)
    }
    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let raw = read(node,name).1, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }
    private static func string(_ node: AXUIElement, _ name: String) -> String? { read(node,name).1 as? String }
}
#endif
