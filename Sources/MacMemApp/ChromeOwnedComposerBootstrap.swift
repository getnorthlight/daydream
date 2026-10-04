// QA-only bounded focus after native creation. No page text, field value or scripts.
#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING && DAYDREAM_CHROME_TYPING
import AppKit
import ApplicationServices
import Carbon
import Foundation
import MemoryCore

@MainActor enum ChromeOwnedComposerBootstrap {
    enum Failure: String, Error { case arguments, scope, timeout, unreadable, missingField, ambiguousField, focus, productionProof, nonEmpty }
    struct Owned { let windowID: String; let tabID: String; let documentURL: String; let window: AXUIElement; let field: AXUIElement }
    static func createAndFocus(scenario: String, pid: pid_t) throws -> Owned {
        guard let destination = ChromeComposerCaptureRequest.destination(scenario) else { throw Failure.arguments }
        let created = try RedditNativeBootstrap.create(destination, pid: pid)
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        let access = ChromeTypingWitness.access(pid: pid)
        func held() -> AXUIElement? {
            guard Thread.isMainThread, AXIsProcessTrusted(), CGPreflightListenEventAccess(), CGPreflightPostEventAccess(),
                  !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  ChromeEventSender.permissionStatus(pid: pid) == noErr,
                  let facts = ChromeTypingWitness.targetFacts(pid: pid), ChromeTargetPolicy.accepts(facts) else { return nil }
            let s = ChromeModeReader.JoinSession(pid: pid)
            guard case .ids(let ids)? = s.reply(.windowIDs), !ids.isEmpty, Set(ids).count == ids.count, ids.contains(created.windowID) else { return nil }
            for id in ids { guard case .text(let mode)? = s.reply(.mode(id)), mode == "normal" else { return nil } }
            guard case .text(let tab)? = s.reply(.activeTabID(created.windowID)), tab == created.tabID,
                  case .text(let url)? = s.reply(.tabURL(created.windowID, created.tabID)), url == created.documentURL,
                  case .bounds(let bounds)? = s.reply(.bounds(created.windowID)),
                  let window = access.focusedWindow(), access.owner(window) == pid,
                  let axFrame = access.frame(window),
                  ChromeFrontInspectionControls.compareGeometry(bounds, axFrame).productionMatch else { return nil }
            var matches = 0
            for id in ids {
                guard case .bounds(let candidateBounds)? = s.reply(.bounds(id)) else { return nil }
                if ChromeFrontInspectionControls.compareGeometry(candidateBounds, axFrame).productionMatch { matches += 1 }
            }
            return matches == 1 ? window : nil
        }
        guard let initialWindow = held() else { throw Failure.scope }
        func read(_ node: AXUIElement, _ name: String) throws -> CFTypeRef? {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.timeout }
            guard let w = held(), CFEqual(w,initialWindow), access.owner(node) == pid else { throw Failure.scope }
            guard AXUIElementSetMessagingTimeout(node,0.025) == .success else { throw Failure.unreadable }
            var v: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(node,name as CFString,&v)
            guard result == .success || result == .attributeUnsupported || result == .noValue else { throw Failure.unreadable }
            return result == .success ? v : nil
        }
        func string(_ node: AXUIElement, _ name: String) throws -> String? {
            guard let v = try read(node,name), CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
            return v as? String
        }
        func children(_ node: AXUIElement, role: String) throws -> [AXUIElement] {
            guard DispatchTime.now().uptimeNanoseconds < deadline, let w = held(), CFEqual(w,initialWindow), access.owner(node) == pid,
                  AXUIElementSetMessagingTimeout(node,0.025) == .success else { throw Failure.scope }
            var names: CFArray?
            guard AXUIElementCopyAttributeNames(node,&names) == .success, let names, let supported = names as? [String] else { throw Failure.unreadable }
            if !supported.contains(kAXChildrenAttribute) {
                // An opaque container is not an empty subtree. Only explicit known leaves may omit Children.
                guard ChromeComposerCaptureRequest.knownLeafWithoutChildren(role:role,supported:supported) else { throw Failure.unreadable }
                return []
            }
            guard let value = try read(node,kAXChildrenAttribute), CFGetTypeID(value) == CFArrayGetTypeID() else { throw Failure.unreadable }
            let list = value as! CFArray
            let count = CFArrayGetCount(list)
            guard count <= 1200 else { throw Failure.timeout }
            var result: [AXUIElement] = []
            for index in 0..<count {
                guard let raw = CFArrayGetValueAtIndex(list,index) else { throw Failure.unreadable }
                let value = unsafeBitCast(raw,to:CFTypeRef.self)
                guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw Failure.unreadable }
                result.append(value as! AXUIElement)
            }
            return result
        }
        var candidates: [AXUIElement] = []
        var processed = 0
        repeat {
        var queue: [(AXUIElement,Int,Bool)] = [(initialWindow,0,false)]
        while !queue.isEmpty {
            let (node,depth,underWeb) = queue.removeFirst(); processed += 1
            guard processed <= 1200, depth <= 20 else { throw Failure.timeout }
            let role = try string(node,kAXRoleAttribute) ?? ""
            let web = underWeb || role == "AXWebArea"
            if web {
                let subrole = try string(node,kAXSubroleAttribute) ?? ""
                if !subrole.lowercased().contains("secure") {
                    let labels: [String]
                    if scenario == "x-search-v1", ["AXSearchField","AXTextField","AXComboBox"].contains(role) {
                        labels = try [kAXTitleAttribute,kAXDescriptionAttribute,kAXPlaceholderValueAttribute].compactMap { try string(node,$0)?.lowercased() }
                    } else { labels = [] }
                    let eligible = ChromeComposerCaptureRequest.eligible(scenario: scenario, role: role, subrole: subrole, labels: labels)
                    if eligible, !candidates.contains(where: { CFEqual($0,node) }) { candidates.append(node) }
                }
            }
            let completeChildren = try children(node,role:role)
            guard completeChildren.count <= 1200 - processed - queue.count else { throw Failure.timeout }
            queue.append(contentsOf: completeChildren.map { ($0,depth+1,web) })
        }
        if candidates.isEmpty { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.timeout }
        } while candidates.isEmpty
        guard candidates.count == 1 else { throw candidates.isEmpty ? Failure.missingField : Failure.ambiguousField }
        let field = candidates[0]
        guard let before = held(), CFEqual(before,initialWindow), DispatchTime.now().uptimeNanoseconds < deadline,
              AXUIElementSetAttributeValue(field,kAXFocusedAttribute as CFString,kCFBooleanTrue) == .success,
              let after = held(), CFEqual(after,initialWindow), let focused = access.focusedElement(), CFEqual(focused,field) else { throw Failure.focus }
        // Default production join and exact empty-value gate are performed again by capture before its store/tap/input.
        return Owned(windowID: created.windowID, tabID: created.tabID, documentURL: created.documentURL, window: initialWindow, field: field)
    }
}
#endif
