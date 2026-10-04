import Foundation
import PrivacyPolicy

/// Metadata-only OS seam. Production supplies AX objects and CFEqual, never
/// labels, hashes, extension identifiers or page-authored claims.
struct NativeFocusAccess<Node> {
    let now: () -> UInt64
    let ready: () -> Bool
    let identity: () -> String?
    /// PID of the application that receives keystrokes system-wide
    /// (`AXUIElementCreateSystemWide` + `kAXFocusedApplicationAttribute`), or
    /// nil when unknown. Spotlight-style panels take key focus while the app
    /// behind them stays frontmost, so frontmost alone is not proof.
    let focusedApplication: () -> Int32?
    let window: () -> Node?
    let focus: () -> Node?
    let owner: (Node) -> Int32?
    let role: (Node) -> String?
    let subrole: (Node) -> String?
    let parent: (Node) -> Node?
    let equal: (Node, Node) -> Bool
    /// messages-1003: the focused field's labels (description, placeholder, help, identifier; never its value), read
    /// only for apps that classify fields by them (Messages). nil: not read.
    var labels: (Node) -> [String]? = { _ in nil }
    /// messages-1003: whether a new focused element in the same window, process and generation is the same logical
    /// field as the previous one (role, subrole, labels), so it keeps its focus ID. Messages replaces its composer's
    /// Accessibility element while the person types (live 2026-10-03: a message was cut mid-word, "wanna me" |
    /// "et us there?", sealed "focus" with no click or key between). nil: never (every other app).
    var sameField: ((_ old: (role: String, subrole: String, labels: [String]), _ new: (role: String, subrole: String, labels: [String])) -> Bool)? = nil
}

/// One active native focus, not a cross-app registry or persistent document ID.
/// No read of characters, values, titles, URLs, selection or browser state.
/// A failed read returns nil and keeps the previous identity: IDs are reused
/// only for the exact same process, generation and AX objects, so one AX
/// timeout does not turn the same field into a "new" one. Key focus in another
/// process invalidates here; callers invalidate on other privacy and readiness failures.
final class NativeFocusWitness<Node> {
    private var previous: (identity:String, generation:UInt64, window:Node, focus:Node, windowID:String, focusID:String, role:String, subrole:String, labels:[String]?)?
    func invalidate() { previous=nil }
    func read(pid:Int32,bundle:String,generation:UInt64,policyVersion:UInt64,
              excluded:Set<String>=[],access a:NativeFocusAccess<Node>) -> FocusProof? {
        guard CaptureGate.nativeApps.contains(bundle),!excluded.contains(bundle),a.ready() else {return nil}
        // Key focus in another process (a Spotlight-style panel) is a boundary:
        // the next proof in this app starts a new identity.
        guard let keyPID=a.focusedApplication() else {return nil}
        guard keyPID==pid else {invalidate();return nil}
        guard let identity=a.identity(),!identity.isEmpty else {return nil}
        let began=a.now()
        guard let window=a.window(),let focus=a.focus(),a.owner(window)==pid,a.owner(focus)==pid,
              a.role(window)=="AXWindow",let role=a.role(focus),["AXTextArea","AXTextField"].contains(role),
              let subrole=a.subrole(focus),!subrole.lowercased().contains("secure") else {return nil}
        var cursor:Node?=focus,reached=false,visited:[Node]=[]
        for _ in 0..<32 {
            guard let node=cursor,a.owner(node)==pid,let r=a.role(node),let s=a.subrole(node),
                  r != "AXWebArea",!r.lowercased().contains("secure"),!s.lowercased().contains("secure"),
                  !visited.contains(where:{a.equal($0,node)}) else {return nil}
            visited.append(node)
            if a.equal(node,window) {reached=true;break}
            cursor=a.parent(node)
        }
        guard reached,let finalWindow=a.window(),let finalFocus=a.focus(),
              a.equal(window,finalWindow),a.equal(focus,finalFocus),
              a.owner(finalWindow)==pid,a.owner(finalFocus)==pid,
              a.role(finalWindow)=="AXWindow",a.role(finalFocus)==role,a.subrole(finalFocus)==subrole else {return nil}
        // A reused native text element can be reparented into embedded web UI.
        // Recheck the exact ancestry as well as endpoint equality.
        var finalCursor:Node?=finalFocus
        for original in visited {
            guard let node=finalCursor,a.equal(original,node),a.owner(node)==pid,
                  let r=a.role(node),let s=a.subrole(node),r != "AXWebArea",
                  !r.lowercased().contains("secure"),!s.lowercased().contains("secure") else {return nil}
            if !a.equal(node,finalWindow) {finalCursor=a.parent(node)}
        }
        // Keys must still go to this process when the observation ends.
        guard a.identity()==identity,a.ready() else {return nil}
        guard let finalKeyPID=a.focusedApplication() else {return nil}
        guard finalKeyPID==pid else {invalidate();return nil}
        let ended=a.now()
        guard ended>=began,ended-began<=CaptureGate.ttlNanoseconds else {return nil}
        // UUIDs name exact retained AX objects, not guessed OS/browser IDs.
        let same=previous.map{$0.identity==identity && $0.generation==generation && a.equal($0.window,window)} ?? false
        let windowID=same ? previous!.windowID : UUID().uuidString
        let sameElement=same && a.equal(previous!.focus,focus)
        // Labels are read once per element (cached while focus stays on it).
        let labels=sameElement && previous!.role==role && previous!.subrole==subrole ? previous!.labels : a.labels(focus)
        var focusID=sameElement ? previous!.focusID : UUID().uuidString
        if same,!sameElement,let rule=a.sameField,let old=previous,let oldLabels=old.labels,let newLabels=labels,
           rule((old.role,old.subrole,oldLabels),(role,subrole,newLabels)) {focusID=old.focusID}
        previous=(identity,generation,window,focus,windowID,focusID,role,subrole,labels)
        var p=FocusProof();p.generation=generation;p.policyVersion=policyVersion;p.checkedAt=began
        p.bundle=bundle;p.windowID=windowID;p.focusID=focusID;p.role=role;p.subrole=subrole
        p.nativeLabels=labels ?? []
        p.surface = .native;p.secureInput = .no;p.privateMode = .no
        p.verified=true;p.fieldStateVerified=true;p.frameAccessible=true;p.navigationStable=true
        return p
    }
}

// MARK: - Vendor app with web content (typesafe SPEC 6.3, 12.2 item 4)

/// One deny-only label attribute as read (gold/int S2). `absent`: the field doesn't have it (unsupported, or no
/// value). `unreadable`: an Accessibility error, or a value of an unexpected type.
enum LabelAttributeRead: Equatable { case absent, text(String), list([String]), unreadable
    /// The field's label: every attribute read, joined; nil (refuse the field) when any couldn't be read.
    static func join(_ reads: [LabelAttributeRead]) -> String? {
        var parts: [String] = []
        for read in reads {
            switch read {
            case .absent: continue
            case .text(let text): parts.append(text)
            case .list(let items): parts.append(contentsOf: items)
            case .unreadable: return nil
            }
        }
        return parts.joined(separator: " ")
    }
}

/// The web-content proof's OS seam: the native seam plus three metadata
/// reads. Never a value, selection, title or text of the field.
struct WebContentAccess<Node> {
    let base: NativeFocusAccess<Node>
    /// Whether the node is editable web content (`AXEditableAncestor` is
    /// present). nil when the read failed.
    let editable: (Node) -> Bool?
    /// The web area's own `AXURL`: `.some(nil)` when it has none, nil when the
    /// read failed. Used to tell the vendor's own page from any other page.
    let url: (Node) -> String??
    /// Deny-only field labels (placeholder, description, DOM id and classes),
    /// joined. They only ever refuse (`CaptureGate.sensitiveField`). nil when
    /// any of them couldn't be read (an Accessibility error): the field is
    /// refused (gold/int S2: an unreadable label is never a clean one).
    let label: (Node) -> String?
    /// fix/app-coverage: a chat app's composer labels (description and placeholder, never its title or value), read only in an app whose
    /// own page is a chat host (Slack, Discord) and only to name the channel or person ("Message #general" ->
    /// "#general", `SendRules.composerPlace`), as the Chrome join does on those sites. Never the field's value; it
    /// neither allows nor refuses anything. nil when unread.
    var composerLabels: (Node) -> [String]? = { _ in nil }
}

/// The "vendor app with web content" proof for Electron, Chromium and WebKit
/// apps in the table (`TypingApp.web`): all of the native proof's process and
/// focus rules, plus
/// - the field sits in exactly one web area (a frame inside the page, like an
///   embedded third-party widget, is refused), and that web area is the
///   vendor's own page (`TypingWebContent.admits(url:)`: its bundled files or
///   its own https hosts; a built-in browser or link preview is refused);
/// - the field is editable web content (or, in Mail, the editable message
///   body itself), never a secure or password field.
/// A field outside any web area (Mail's To and Subject) gets the native rules.
///
/// Cheap by design: no timer and no tree scan. The ancestry is walked (twice,
/// like the native proof) only for a new field, window, process or generation,
/// or when the last walk is older than `fullWalkNanoseconds`; every other key
/// re-reads only the field, its parent and the page's URL.
final class WebContentFocusWitness<Node> {
    static var maxDepth: Int { 64 }
    static var fullWalkNanoseconds: UInt64 { 2_000_000_000 }
    private struct Verified {
        let identity: String, generation: UInt64, window: Node, focus: Node, parent: Node?, area: Node?
        let url: String?, role: String, subrole: String, label: String, surface: AppSurface
        let windowID: String, focusID: String, walkedAt: UInt64
    }
    private var last: Verified?
    /// Full ancestry walks so far (the synthetic benchmark reads it).
    private(set) var fullWalks = 0
    func invalidate() { last = nil }
    /// A joined label longer than this is refused outright (gold/int S2: an oversized attribute is never judged in part).
    static var labelReadLimit: Int { 4096 }
    /// Labels are clipped to the gate's 256-byte metadata limit, on a character boundary, for storage only: the
    /// full label is judged first (`FocusProof.fieldLabelDenied`).
    static func clip(_ text: String) -> String {
        var out = "", bytes = 0
        for c in text { let n = String(c).utf8.count; if bytes + n > 256 { break }; out.append(c); bytes += n }
        return out
    }
    static func secure(_ role: String, _ subrole: String) -> Bool {
        role.lowercased().contains("secure") || subrole.lowercased().contains("secure")
    }
    func read(pid: Int32, bundle: String, generation: UInt64, policyVersion: UInt64,
              allowed: Set<String> = CaptureGate.webContentApps, excluded: Set<String> = [],
              access w: WebContentAccess<Node>) -> FocusProof? {
        let a = w.base
        guard allowed.contains(bundle), let web = TypingCategories.app(bundle)?.web, !excluded.contains(bundle), a.ready() else { return nil }
        guard a.focusedApplication() == pid else { invalidate(); return nil }
        guard let identity = a.identity(), !identity.isEmpty else { return nil }
        let began = a.now()
        guard let window = a.window(), let focus = a.focus(), a.owner(focus) == pid,
              let role = a.role(focus), let subrole = a.subrole(focus), !Self.secure(role, subrole) else { return nil }
        var area: Node?, parent: Node?, label = "", walked = began
        if let v = last, v.identity == identity, v.generation == generation, a.equal(v.window, window), a.equal(v.focus, focus),
           v.role == role, v.subrole == subrole, began >= v.walkedAt, began - v.walkedAt <= Self.fullWalkNanoseconds {
            // The same retained field: its parent and its page are unchanged.
            if let p = v.parent {
                guard let now = a.parent(focus), a.equal(now, p) else { return nil }
            }
            area = v.area; parent = v.parent; walked = v.walkedAt
        } else {
            guard a.owner(window) == pid, a.role(window) == "AXWindow", let path = walk(from: focus, to: window, pid: pid, a) else { return nil }
            let areas = path.filter { a.role($0) == "AXWebArea" }
            guard areas.count <= 1 else { return nil }
            area = areas.first; parent = path.count > 1 ? path[1] : nil
            // Walk again: a field reparented during the read is refused.
            guard let again = walk(from: focus, to: window, pid: pid, a), again.count == path.count,
                  zip(again, path).allSatisfy({ a.equal($0, $1) }) else { return nil }
            fullWalks += 1
        }
        // gold/int S2: the deny-only label is read for every proof (never reused from an earlier key: a page can
        // change a field's placeholder or classes in place) and judged in full before it is clipped for storage.
        // Narrow on purpose: only a field inside web content (`area`) needs the label to read without error and fit
        // `labelReadLimit`; there a failed read skips this key only (the next key reads again) and says nothing. A
        // native field (Mail's To and Subject) keeps its rules: an unreadable label is empty, as before.
        let labelRead = w.label(focus)
        if area != nil { guard let read = labelRead, read.utf8.count <= Self.labelReadLimit else { return nil } }
        let fullLabel = labelRead ?? ""
        label = Self.clip(fullLabel)
        let fieldRoles = ["AXTextArea", "AXTextField"]
        var surface = AppSurface.native, url: String?
        if let area {
            guard fieldRoles.contains(role) || (web.webAreaEditor && role == "AXWebArea" && a.equal(area, focus)),
                  w.editable(focus) == true, let read = w.url(area), web.admits(url: read) else { return nil }
            surface = .embeddedWeb; url = read
        } else {
            guard fieldRoles.contains(role) else { return nil }
        }
        guard let finalWindow = a.window(), let finalFocus = a.focus(), a.equal(window, finalWindow), a.equal(focus, finalFocus),
              a.owner(finalFocus) == pid, a.role(finalFocus) == role, a.subrole(finalFocus) == subrole else { return nil }
        // The page did not navigate during the read.
        if let area { guard let again = w.url(area), again == url else { return nil } }
        guard a.identity() == identity, a.ready() else { return nil }
        guard a.focusedApplication() == pid else { invalidate(); return nil }
        let ended = a.now()
        guard ended >= began, ended - began <= CaptureGate.ttlNanoseconds else { return nil }
        let same = last.map { $0.identity == identity && $0.generation == generation && a.equal($0.window, window) } ?? false
        let windowID = same ? last!.windowID : UUID().uuidString
        // A vendor app can reuse one AX composer across different conversations.
        // Keep its admitted, twice-read URL only in the existing in-memory witness;
        // rotate the opaque field identity on a document boundary, never persist
        // that URL (including its query or fragment) in the proof.
        let sameArea: Bool
        if let previousArea = last?.area, let area {
            sameArea = a.equal(previousArea, area)
        } else {
            sameArea = last?.area == nil && area == nil
        }
        let sameDocument = same && sameArea && last!.surface == surface && last!.url == url
        let focusID = sameDocument && a.equal(last!.focus, focus) ? last!.focusID : UUID().uuidString
        last = Verified(identity: identity, generation: generation, window: window, focus: focus, parent: parent, area: area, url: url,
                        role: role, subrole: subrole, label: label, surface: surface, windowID: windowID, focusID: focusID, walkedAt: walked)
        var p = FocusProof(); p.generation = generation; p.policyVersion = policyVersion; p.checkedAt = began
        p.bundle = bundle; p.windowID = windowID; p.focusID = focusID; p.role = role; p.subrole = subrole
        p.surface = surface; p.secureInput = .no; p.privateMode = .no; p.fieldLabel = label
        p.fieldLabelDenied = CaptureGate.deniesFieldLabel(fullLabel, embeddedWeb: surface == .embeddedWeb)
        p.verified = true; p.fieldStateVerified = true; p.frameAccessible = true; p.navigationStable = true
        // fix/app-coverage: the channel or person a desktop chat app's composer names, for the unit's send facts only.
        if surface == .embeddedWeb, !p.fieldLabelDenied, let host = web.hosts.sorted().first(where: SendRules.chatHosts.contains),
           let labels = w.composerLabels(focus) {
            p.sendPlace = SendRules.composerPlace(labels: labels, host: host) ?? ""
        }
        return p
    }
    /// Focus up to its window: every node in this process, readable, never
    /// secure, no cycle, and the window reached within `maxDepth`.
    private func walk(from focus: Node, to window: Node, pid: Int32, _ a: NativeFocusAccess<Node>) -> [Node]? {
        var cursor: Node? = focus, visited: [Node] = []
        for _ in 0..<Self.maxDepth {
            guard let node = cursor, a.owner(node) == pid, let r = a.role(node), let s = a.subrole(node), !Self.secure(r, s),
                  !visited.contains(where: { a.equal($0, node) }) else { return nil }
            visited.append(node)
            if a.equal(node, window) { return visited }
            cursor = a.parent(node)
        }
        return nil
    }
}

/// Turns an Electron or Chromium app's Accessibility tree on with
/// `AXManualAccessibility`, once per process (the attribute is written only by
/// `WebContentAXReader`, compiled into the owner build alone). Never `AXEnhancedUserInterface`
/// (it also changes how the app's windows behave). Event-driven: called only
/// from a typing proof in an allowed web-content app, never on a timer. A
/// process that already had its tree on (a screen reader, another tool) is
/// left alone. The key that turns it on is not read: the app builds its tree
/// after the call, so that proof fails closed.
final class ManualAccessibilitySwitch {
    /// `none`: the app has no such switch (live test, build 7: ChatGPT, `com.openai.codex`, answers
    /// "attribute unsupported" to AXManualAccessibility). Nothing is written; its own tree decides, and the proof
    /// reads it under every usual rule (no tree, no field: the proof fails closed).
    enum State: Equatable { case ours, theirs, none, failed }
    static var limit: Int { 32 }
    private(set) var states: [String: State] = [:]
    /// Attribute writes so far (the synthetic benchmark reads it).
    private(set) var writes = 0
    /// - identity: the signed process (`pid:launch:bundle`), so a reused PID starts over.
    /// - read: the attribute now (nil when it can't be read).
    /// - unsupported: the app doesn't have the attribute at all (read and write both unsupported).
    /// - write: sets it to true; false when the app refused.
    /// Returns whether the tree is on and the proof may read.
    func ensure(identity: String, read: () -> Bool?, unsupported: () -> Bool = { false }, write: () -> Bool) -> Bool {
        if let state = states[identity] { return state != .failed }
        if states.count >= Self.limit { states = states.filter { $0.value == .ours } }
        if states.count >= Self.limit { states.removeAll() }
        let now = read()
        if now == true { states[identity] = .theirs; return true }
        // Before this fix the write was tried and refused, which marked the app failed for as long as it ran, so no
        // key typed in ChatGPT was ever read.
        if now == nil, unsupported() { states[identity] = State.none; return true }
        writes += 1
        states[identity] = write() ? .ours : .failed
        return false
    }
}

/// Which process a key goes to: the frontmost app, or a launcher panel
/// (Spotlight) that holds key focus while the app behind it stays frontmost.
/// Only a panel the build allows (`CaptureGate.keyPanelApps`) is followed;
/// key focus in any other process leaves the frontmost PID, whose proof then
/// fails (focus is elsewhere), exactly as before.
enum KeyPanelRoute {
    static func target(frontmost: Int32, keyFocus: Int32?, bundle: (Int32) -> String?,
                       panels: Set<String> = CaptureGate.keyPanelApps) -> Int32 {
        guard let keyFocus, keyFocus > 0, keyFocus != frontmost, !panels.isEmpty,
              let owner = bundle(keyFocus), panels.contains(owner) else { return frontmost }
        return keyFocus
    }
}
