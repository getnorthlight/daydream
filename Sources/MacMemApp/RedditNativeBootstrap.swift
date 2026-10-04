// QA only: native navigation/focus for fresh Reddit test windows. No recorder,
// user history, model, JavaScript, DOM writes, publish, comment or message send.
#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING && DAYDREAM_CHROME_TYPING
import AppKit
import ApplicationServices
import Carbon
import Foundation
import MemoryCore

@MainActor enum RedditNativeBootstrap {
    enum Failure: String, Error {
        case permission, target, privateWindow, input, changed, timeout
        case windowCreation, page, fieldMissing, fieldAmbiguous, fieldNotEmpty, productionProof
    }
    enum Field: String { case search, postTitle, postBody, comment }
    struct Owned {
        let pid: pid_t
        let windowID: String
        let tabID: String
        let documentURL: String
        let window: AXUIElement
        let field: AXUIElement
        let kind: Field
        // This token is not a production capture proof. Call production witness
        // again at arm and every key; no identity is inferred from site title.
    }
    static let fixedURLs = [
        "search": "https://www.reddit.com/",
        "post": "https://www.reddit.com/submit",
        "x-search-home": "https://x.com/home",
        "x-post-compose": "https://x.com/compose/post",
        "chatgpt-new-prompt": "https://chatgpt.com/"
    ]
    static let exactLabels: [Field: Set<String>] = [
        .search: ["search reddit"],
        .postTitle: ["title"],
        .postBody: ["body", "body text", "add body text", "text (optional)"],
        .comment: ["add a comment", "comment", "what are your thoughts?", "write a comment"]
    ]
    private static func timed(_ e: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(e, 0.025) == .success
    }
    private static func value(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        guard timed(e) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &out) == .success else { return nil }
        return out
    }
    private static func string(_ e: AXUIElement, _ name: String) -> String? {
        guard let v = value(e, name), CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
        return v as? String
    }
    private static func allowed(_ pid: pid_t) -> Bool {
        Thread.isMainThread && AXIsProcessTrusted() && CGPreflightListenEventAccess()
            && CGPreflightPostEventAccess() && !IsSecureEventInputEnabled()
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            && ChromeEventSender.permissionStatus(pid: pid) == noErr
    }
    private static func windows(_ pid: pid_t) throws -> [String] {
        guard allowed(pid), let facts = ChromeTypingWitness.targetFacts(pid: pid),
              ChromeTargetPolicy.accepts(facts) else { throw Failure.permission }
        let s = ChromeModeReader.JoinSession(pid: pid)
        guard case .ids(let ids)? = s.reply(.windowIDs), !ids.isEmpty,
              Set(ids).count == ids.count else { throw Failure.target }
        // Every window is checked before any Accessibility reads.
        for id in ids {
            guard case .text(let mode)? = s.reply(.mode(id)), mode == "normal" else { throw Failure.privateWindow }
        }
        return ids
    }
    private static func key(_ code: CGKeyCode, flags: CGEventFlags = [], text: String? = nil,
                            pid: pid_t, deadline: UInt64) throws {
        guard DispatchTime.now().uptimeNanoseconds < deadline, allowed(pid),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw Failure.input }
        down.flags = flags; up.flags = flags
        if let text {
            let chars = Array(text.utf16)
            chars.withUnsafeBufferPointer { b in
                down.keyboardSetUnicodeString(stringLength: b.count, unicodeString: b.baseAddress)
                up.keyboardSetUnicodeString(stringLength: b.count, unicodeString: b.baseAddress)
            }
        }
        // Synthetic CGEvent OS input, not physical human typing or DOM injection.
        down.post(tap: .cgSessionEventTap); up.post(tap: .cgSessionEventTap)
    }
    private static func held(_ pid: pid_t, _ wid: String, _ tid: String, url: String? = nil) throws -> String {
        let ids = try windows(pid)
        guard ids.contains(wid) else { throw Failure.changed }
        let s = ChromeModeReader.JoinSession(pid: pid)
        guard case .text(let active)? = s.reply(.activeTabID(wid)), active == tid,
              case .text(let document)? = s.reply(.tabURL(wid, tid)),
              url == nil || url == document else { throw Failure.changed }
        guard case .bounds(let bounds)? = s.reply(.bounds(wid)) else { throw Failure.changed }
        var sameFrame = 0
        for id in ids {
            guard case .bounds(let frame)? = ChromeModeReader.JoinSession(pid: pid).reply(.bounds(id)) else { throw Failure.changed }
            if frame == bounds { sameFrame += 1 }
        }
        guard sameFrame == 1 else { throw Failure.changed }
        let access = ChromeTypingWitness.access(pid: pid)
        guard let focused = access.focusedWindow(), access.owner(focused) == pid, access.frame(focused) == bounds else { throw Failure.changed }
        return document
    }
    private static func addressBar(_ pid: pid_t, held: AXUIElement? = nil) throws -> AXUIElement {
        let access = ChromeTypingWitness.access(pid: pid)
        guard allowed(pid), let field = access.focusedElement(), access.owner(field) == pid,
              held == nil || CFEqual(held!, field),
              let role = string(field, kAXRoleAttribute),
              ["AXTextField", "AXComboBox"].contains(role) else { throw Failure.input }
        let labels = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { string(field, $0) }
        guard labels.contains(where: { ["address and search bar", "address bar"].contains($0.lowercased()) }) else { throw Failure.input }
        return field
    }
    /// Only fixed public navigation URLs. All bootstrap runs are unarmed.
    /// The caller must already own the GUI lease and authenticate its signed
    /// QA executable. No external URL, recipient, text or command enters this API.
    static func create(_ scenario: String, pid: pid_t) throws -> (windowID: String, tabID: String, documentURL: String) {
        guard let url = fixedURLs[scenario] else { throw Failure.page }
        let deadline = DispatchTime.now().uptimeNanoseconds + 8_000_000_000
        let previous = Set(try windows(pid))
        try key(45, flags: .maskCommand, pid: pid, deadline: deadline) // Cmd+N
        var ownedWindow: String?
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let added = Set(try windows(pid)).subtracting(previous)
            if added.count > 1 { throw Failure.windowCreation }
            if let id = added.first { ownedWindow = id; break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        guard let wid = ownedWindow else { throw Failure.timeout }
        guard case .text(let tid)? = ChromeModeReader.JoinSession(pid: pid).reply(.activeTabID(wid)),
              ChromeAppleEvents.validID(tid),
              try held(pid, wid, tid) == "chrome://newtab/" else { throw Failure.windowCreation }
        try key(37, flags: .maskCommand, pid: pid, deadline: deadline) // Cmd+L
        let address = try addressBar(pid)
        for c in url {
            guard try held(pid, wid, tid) == "chrome://newtab/" else { throw Failure.changed }
            _ = try addressBar(pid, held: address)
            try key(0, text: String(c), pid: pid, deadline: deadline)
            RunLoop.main.run(until: Date().addingTimeInterval(0.015))
        }
        guard try held(pid, wid, tid) == "chrome://newtab/" else { throw Failure.changed }
        _ = try addressBar(pid, held: address)
        try key(36, pid: pid, deadline: deadline) // URL navigation only; recorder unarmed
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let current = try held(pid, wid, tid)
            if current == url || (url.hasSuffix("/") && current == String(url.dropLast())) {
                return (wid, tid, current)
            }
            guard current == "chrome://newtab/" || current == url
                || BrowserSites.origin(current) == BrowserSites.origin(url) else { throw Failure.page }
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
        throw Failure.timeout
    }

    /// Finds a unique native accessible field in this fresh owned window.
    /// Reads metadata and one Boolean emptiness result, never exposes field text.
    /// A new window/tab alone is insufficient; restored drafts fail the empty gate.
    static func focus(pid: pid_t, windowID: String, tabID: String, documentURL: String, kind: Field) throws -> Owned {
        let deadline = DispatchTime.now().uptimeNanoseconds + 8_000_000_000
        _ = try held(pid, windowID, tabID, url: documentURL)
        repeat {
            do { return try focusOnce(pid: pid, windowID: windowID, tabID: tabID, kind: kind,
                                      documentURL: documentURL, deadline: deadline) }
            catch Failure.fieldMissing {
                // URL readiness is not render readiness. Only absent/unreadable
                // field metadata may wait; permission, ownership, privacy,
                // ambiguity, nonempty draft, and proof refusals remain immediate.
                guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.timeout }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        } while DispatchTime.now().uptimeNanoseconds < deadline
        throw Failure.timeout
    }
    private static func focusOnce(pid: pid_t, windowID: String, tabID: String, kind: Field,
                                  documentURL: String, deadline: UInt64) throws -> Owned {
        let url = try held(pid, windowID, tabID, url: documentURL)
        guard let parts = URLComponents(string: url), parts.scheme == "https",
              parts.host == "www.reddit.com" || parts.host == "reddit.com",
              parts.user == nil, parts.password == nil else { throw Failure.page }
        let access = ChromeTypingWitness.access(pid: pid)
        guard let window = access.focusedWindow(),
              case .bounds(let bounds)? = ChromeModeReader.JoinSession(pid: pid).reply(.bounds(windowID)),
              access.owner(window) == pid, access.frame(window) == bounds else { throw Failure.changed }
        var nodes = [window], seen: [AXUIElement] = [], matches: [AXUIElement] = []
        while let node = nodes.popLast() {
            guard DispatchTime.now().uptimeNanoseconds < deadline, seen.count < 1024 else { throw Failure.timeout }
            _ = try held(pid, windowID, tabID, url: url)
            if seen.contains(where: { CFEqual($0, node) }) { continue }
            seen.append(node)
            guard let role = string(node, kAXRoleAttribute), access.owner(node) == pid else { throw Failure.changed }
            if ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role) {
                if string(node, kAXSubroleAttribute) == "AXSecureTextField" { throw Failure.productionProof }
                let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
                    .compactMap { string(node, $0) }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                if labels.contains(where: exactLabels[kind, default: []].contains) {
                    matches.append(node)
                }
            }
            if let children = access.children(node), children.count <= 1024 {
                nodes.append(contentsOf: children)
            } else {
                // Unsupported AXChildren is expected only for a documented leaf
                // role whose supported attribute names explicitly omit children.
                // Failed, oversized, or unreadable container lists still refuse.
                let leaves: Set<String> = ["AXStaticText", "AXImage", "AXButton", "AXLink",
                                           "AXTextField", "AXSearchField", "AXTextArea", "AXComboBox"]
                var names: CFArray?
                guard leaves.contains(role), timed(node),
                      AXUIElementCopyAttributeNames(node, &names) == .success,
                      let attributes = names as? [String],
                      !attributes.contains(kAXChildrenAttribute) else { throw Failure.fieldMissing }
            }
        }
        guard matches.count == 1 else { throw matches.isEmpty ? Failure.fieldMissing : Failure.fieldAmbiguous }
        let field = matches[0]
        _ = try held(pid, windowID, tabID, url: url)
        guard timed(field), AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
              let current = access.focusedElement(), CFEqual(current, field) else { throw Failure.changed }
        let witness = ChromeTypingWitness(design: ChromeJoinDesign.current)
        let proof = witness.read(pid: pid, enabled: { allowed(pid) },
                                 blockList: BrowserTypingBlockList(), alwaysBlocked: BrowserTypingBlockList.pinned)
        guard let p = proof.proof, p.windowID == windowID, p.tabID == tabID,
              p.origin == "https://www.reddit.com" || p.origin == "https://reddit.com" else { throw Failure.productionProof }
        let empty = BrowserFixtureEmptyGate.run(deadline: deadline, now: { DispatchTime.now().uptimeNanoseconds },
            scope: {
                guard let current = access.focusedElement(), CFEqual(current, field),
                      let w = access.focusedWindow(), CFEqual(w, window) else { return false }
                return (try? held(pid, windowID, tabID, url: url)) != nil
            },
            proof: {
                witness.read(pid: pid, enabled: { allowed(pid) }, blockList: BrowserTypingBlockList(),
                             alwaysBlocked: BrowserTypingBlockList.pinned).proof != nil
            },
            read: {
                var out: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &out)
                return (status, out)
            })
        guard empty.allowed else { throw Failure.fieldNotEmpty }
        _ = try held(pid, windowID, tabID, url: url)
        return Owned(pid: pid, windowID: windowID, tabID: tabID, documentURL: url,
                     window: window, field: field, kind: kind)
    }
}
#endif
