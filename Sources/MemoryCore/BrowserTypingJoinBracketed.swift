#if DAYDREAM_CHROME_TYPING
// Compiled only with -DDAYDREAM_CHROME_TYPING: every release build defines it; a plain swift build leaves this file out.
//
// QF-17 PROTOTYPE: the bracketed design's one read (design items B1, M6, M7). One call of
// `BrowserTypingJoin.join` in `.bracketed` is ONE read: every fact observed once or twice, each observation
// timed on the environment's clock, with no second confirming read inside the call. The confirming role moves to
// the bracket (`ChromeBracketEngine`): a key is admitted only between verified reads whose every fact is equal.
//
// Order (asserted by checks and scripts/check_browser_boundary.py):
//  0. consent, target, Automation; Chrome frontmost + system-focused, no secure input      (focusState)
//  1. `ID of every window`                                                                (windowIDs)
//  2. `mode of every window`: as many as IDs, every one exactly "normal" (the mode gate)   (modes)
//  3. AX: focused window geometry, every AX window's subrole and frame                   (axWindows)
//  4. `bounds of every window`: as many as IDs                                            (bounds)
//  5. `ID of every window` again, identical: only then is index pairing valid (M6)        (windowIDs)
//  6. every AX window is a listed window (one to one on bounds)
//  7. names of the bounds-matched candidates only; AX title of the focused window; QF-10 match (name)
//  8. the candidate's active tab ID, then its URL                                         (tab, url)
//  9. AX: the focused element, its role, subrole and ancestry (one AXWebArea)             (focus)
// 10. AX: the web area's AXURL, same document as the AE URL                               (axURL)
// 11. the site rules on both addresses (blocks win; nothing about the field is read on a blocked page)
// 12. AX: secure-focus memory, the field's labels (deny-only), the form scan (QF-11/QF-3), and the person's
//     field choice (M7: every read)                                                       (sensitivity)
// 13. Chrome frontmost + system-focused, no secure input; consent; the same launch        (focusState)
// Window-reorder ABA (M6): a z-order swap and swap-back between steps 1 and 5 is invisible (IDs are unique and
// come back in the same order), so bounds could pair with the wrong ID; the name <-> AX title match (7) and the
// URL <-> AXURL same-document match (10) limit that to another normal window showing the same document.
// The `mode` Chrome reports for a Guest window is UNVERIFIED (anything but "normal" refuses).
import Foundation
import PrivacyPolicy

extension BrowserTypingJoin {
    func bracketedAttempt(environment e: ChromeJoinEnvironment, appleEvents ae: (ChromeJoinRequest) -> ChromeJoinReply?,
                          accessibility ax: ChromeAXAccess<Node>, blockList: BrowserTypingBlockList, alwaysBlocked: [String],
                          sites: (String) -> Bool, field: (String, BrowserTypingFieldLabels) -> Bool,
                          anyFocus: Bool) -> BrowserTypingJoinResult {
        let began = e.now()
        let deadline = began &+ ChromeBracketTiming.readBudgetNanoseconds
        let clock = ChromeFactClock(now: e.now)
        func late() -> Bool { e.now() > deadline }
        func ask(_ f: ChromeFact, _ r: ChromeJoinRequest) -> ChromeJoinReply? { clock.events += 1; return clock.observe(f) { ae(r) } }
        // 0. Once per read, before any Apple Event: consent, the signed target, Automation already granted.
        //    All inside the first `focusState` observation, so its span covers them (review part B, check 1 note).
        guard e.enabled() else { return .denied(.disabled) }
        let opened: Result<ChromeTargetFacts, BrowserTypingDenial> = clock.observe(.focusState) {
            guard let target = e.target(), ChromeTargetPolicy.accepts(target) else { return .failure(.untrustedTarget) }
            guard e.automationPermitted(target.pid) else { return .failure(.noPermission) }
            guard focused(ax, target.pid) else { return .failure(.notFocused) }
            return .success(target)
        }
        guard case .success(let target) = opened else { if case .failure(let d) = opened { return .denied(d) }; return .denied(.notFocused) }
        // QF-17 feasibility prototype (`ChromeReadShape.lean`, NOT reviewed): only `mode` and `bounds` of every window
        // are asked of Chrome (2 Apple Events); the window binding is by bounds alone, the page by its AXURL alone.
        let lean = ChromeReadShape.current == .lean
        // 1. Window identities only.
        var ids: [String] = []
        if !lean {
            guard case .ids(let got)? = ask(.windowIDs, .windowIDs), !got.isEmpty, got.count <= BrowserTypingTiming.maxWindows,
                  Set(got).count == got.count, got.allSatisfy(ChromeAppleEvents.validID) else { return .denied(.windowList) }
            ids = got
        }
        // 2. Strict mode, one event: every window answers exactly "normal", as many answers as windows.
        guard case .texts(let modes)? = ask(.modes, .modes), lean || modes.count == ids.count, !modes.isEmpty,
              modes.count <= BrowserTypingTiming.maxWindows, modes.allSatisfy({ $0 == "normal" })
        else { return .denied(.notNormal) }
        if lean { ids = modes.indices.map { "w\($0)" } }
        // 3. Accessibility geometry: the focused window and every AX window (subrole and frame only).
        typealias Geometry = (window: Node, frame: ChromeBounds, all: [Node], axFrames: [ChromeBounds])
        let geometry: Result<Geometry, BrowserTypingDenial> = clock.observe(.axWindows) {
            guard let window = ax.focusedWindow(), ax.owner(window) == target.pid, ax.role(window) == "AXWindow",
                  ax.subrole(window) == "AXStandardWindow", ax.minimized(window) == false,
                  let frame = ax.frame(window), frame.valid else { return .failure(.window) }
            guard let all = ax.windows(), all.count <= BrowserTypingTiming.maxWindows,
                  all.contains(where: { ax.equal($0, window) }) else { return .failure(.unlistedWindow) }
            var axFrames: [ChromeBounds] = []
            for w in all {
                guard let sub = ax.subrole(w) else { return .failure(.unlistedWindow) }
                guard sub == "AXStandardWindow" else { continue }
                guard let f = ax.frame(w), f.valid else { return .failure(.unlistedWindow) }
                axFrames.append(f)
            }
            return .success((window, frame, all, axFrames))
        }
        guard case .success(let g) = geometry else { if case .failure(let d) = geometry { return .denied(d) }; return .denied(.window) }
        guard g.axFrames.count <= ids.count else { return .denied(.unlistedWindow) }
        guard g.axFrames.filter({ $0.matches(g.frame) }).count == 1 else { return .denied(.ambiguousWindow) }
        guard !late() else { return .denied(.timeout) }
        // 4. Bounds of every window, one event.
        guard case .boundsList(let bounds)? = ask(.bounds, .allBounds), bounds.count == ids.count, bounds.allSatisfy(\.valid)
        else { return .denied(.window) }
        // 5. The window list again: pairing by index is valid only if it is identical.
        guard lean || ask(.windowIDs, .windowIDs) == .ids(ids) else { return .denied(.changed) }
        // 6. Every AX window is a listed window, one to one on bounds, before any name, tab or URL is read.
        guard ChromeWindowMatching.coversAll(g.axFrames, bounds) else { return .denied(.unlistedWindow) }
        // 7. Names only of the listed windows with the focused window's bounds; the AE <-> AX match.
        let candidates = ids.indices.filter { bounds[$0].matches(g.frame) }
        guard !candidates.isEmpty else { return .denied(.window) }
        let named: Result<(names: [String], title: String, windowID: String, pageName: String), BrowserTypingDenial> = clock.observe(.name) {
            if lean {
                // Bounds alone bind the focused AX window to a listed window: exactly one candidate.
                guard let title = ax.title(g.window) else { return .failure(.window) }
                guard candidates.count == 1 else { return .failure(.ambiguousWindow) }
                var name = title
                for dash in [" - Google Chrome", " \u{2013} Google Chrome"] { if let r = name.range(of: dash) { name = String(name[..<r.lowerBound]) } }
                return .success(([], title, ids[candidates[0]], name))
            }
            var names: [String] = []
            for i in candidates {
                clock.events += 1
                guard case .text(let n)? = ae(.name(ids[i])), n.utf8.count <= 4096 else { return .failure(.window) }
                names.append(n)
            }
            guard let title = ax.title(g.window) else { return .failure(.window) }
            // QF-10 (fix/chrome-capture): the same title match as the synchronous join (the name, or the name plus
            // Chrome's suffix and profile tail; several matches refuse).
            let matches = candidates.indices.filter { ChromeWindowMatching.titleMatches(axTitle: title, aeName: names[$0]) }
            guard !matches.isEmpty else { return .failure(.window) }
            guard matches.count == 1 else { return .failure(.ambiguousWindow) }
            return .success((names, title, ids[candidates[matches[0]]], names[matches[0]]))
        }
        guard case .success(let n) = named else { if case .failure(let d) = named { return .denied(d) }; return .denied(.window) }
        // 8. The window's active tab and its URL.
        var tabID = "lean", url = ""
        if !lean {
            guard case .text(let t)? = ask(.tab, .activeTabID(n.windowID)), ChromeAppleEvents.validID(t) else { return .denied(.url) }
            guard case .text(let u)? = ask(.url, .tabURL(n.windowID, t)), u.utf8.count <= 8192 else { return .denied(.url) }
            tabID = t; url = u
        }
        guard !late() else { return .denied(.timeout) }
        // 9. The focused element and its ancestry: a text role (any focus for a click join), never secure, exactly
        //    one AXWebArea above it, reaching the window.
        typealias Focus = (focus: Node, role: String, subrole: String, chain: [Node], roles: [String], webArea: Node)
        let focusRead: Result<Focus, BrowserTypingDenial> = clock.observe(.focus) {
            guard let focus = ax.focusedElement(), ax.owner(focus) == target.pid, let role = ax.role(focus),
                  anyFocus || ax.textBox(focus, role: role), !role.lowercased().contains("secure"), let subrole = ax.subrole(focus),
                  !subrole.lowercased().contains("secure") else { noteSecureFocus(ax); return .failure(.field) }
            // RB2: every ancestor's role is read here, once, inside the timed `focus` observation; the digest is built
            // from these. An unreadable role fails the read (no placeholder).
            var cursor: Node? = focus, chain: [Node] = [], roles: [String] = [], webAreas: [Node] = [], reached = false
            for _ in 0..<BrowserTypingTiming.maxAncestors {
                guard !late() else { return .failure(.timeout) }
                guard let node = cursor, ax.owner(node) == target.pid, let r = ax.role(node), !r.lowercased().contains("secure"),
                      !chain.contains(where: { ax.equal($0, node) }) else { return .failure(.frame) }
                chain.append(node); roles.append(r)
                if r == "AXWebArea" { webAreas.append(node) }
                if ax.equal(node, g.window) { reached = true; break }
                cursor = ax.parent(node)
            }
            guard reached, webAreas.count == 1 else { return .failure(.frame) }
            return .success((focus, role, subrole, chain, roles, webAreas[0]))
        }
        guard case .success(let fr) = focusRead else { if case .failure(let d) = focusRead { return .denied(d) }; return .denied(.field) }
        // 10. Same page on both sides: http(s), same origin, same path and query.
        guard let axURL = clock.observe(.axURL, { ax.url(fr.webArea) }), axURL.utf8.count <= 8192 else { return .denied(.url) }
        if lean { url = axURL }
        guard let o1 = BrowserTypingSites.origin(url),
              let o2 = BrowserTypingSites.origin(axURL), o1 == o2, BrowserTypingSites.sameDocument(url, axURL) else { return .denied(.url) }
        // 11. Blocks win, before anything about the field is read.
        guard case .allowed(let origin) = BrowserTypingSites.evaluate(url, blockList: blockList, alwaysBlocked: alwaysBlocked),
              BrowserTypingSites.evaluate(axURL, blockList: blockList, alwaysBlocked: alwaysBlocked) == .allowed(origin: origin),
              sites(url), sites(axURL) else { return .denied(.blockedSite) }
        // 12. M7: the field's sensitivity, in every read. Deny-only; the labels are hashed and dropped. A click join
        //     reads none (nothing typed is attributed to what it finds focused) and never enters a bracket.
        var sendField = "", sendPlace = "", labelDigest: UInt64 = 0
        if !anyFocus {
            let judged: Result<(String, String, UInt64), BrowserTypingDenial> = clock.observe(.sensitivity) {
                // QF-11 (fix/chrome-capture): a field that was a password field when a read last saw it, now text.
                guard !secureFocus.contains(where: { ax.equal($0, fr.focus) }) else { return .failure(.sensitiveField) }
                guard let labels = ax.fieldLabels(fr.focus) else { return .failure(.field) }
                guard !BrowserTypingFieldRules.denies(labels) else { return .failure(.sensitiveField) }
                // QF-11, QF-3 (fix/chrome-capture): the form scan, in every read (M7): a password field of the same
                // form or a show-password control near the field refuses it.
                // RB1 (fix/chrome-capture 50c6a45, review C2/C3): a scan that can't finish (the node budget ran out, a
                // container of more than 256 children, a role or children read failed) can't show there is no password
                // neighbour: the read fails closed as `field`, whatever the box. The scan runs around every kind of box,
                // from this read's own focused element and ancestry (`fr`, read in this read's `focus` observation).
                switch BrowserFormScan.scan(chain: fr.chain, ax: ax, late: late) {
                case .clear: break
                case .password, .reveal: return .failure(.sensitiveField)
                // Codex 07:10 (field hold), as in the synchronous read: a completed scan that can't prove the box
                // records it (`boxRefusal`; the join keeps it as `heldBox`). Never on a timeout (`late`).
                case .exhausted, .unreadable: boxRefusal = (target.pid, g.window, fr.focus); return .failure(.field)
                case .late: return .failure(.timeout)
                }
                // QF-4 option (a) (fix/chrome-capture 89058ee; every role since c68da12, Codex 06:10), in every read,
                // from this read's own role and subrole: an unlabelled box of any kind (one-line, search, combo, text
                // area or contenteditable) can't be proven not to be a card number, a one-time code or a password shown
                // as text: `field`, after the scan (a password neighbour is the stronger `sensitiveField`).
                guard !BrowserTypingFieldRules.unlabelled(role: fr.role, subrole: fr.subrole, labels: labels) else {
                    boxRefusal = (target.pid, g.window, fr.focus); return .failure(.field)   // Codex 07:10 (field hold)
                }
                guard field(url, labels) else { return .failure(.blockedSite) }
                let search = SendRules.surface(bundle: "", host: BrowserTypingSites.host(of: url)) == "search"
                let sf = SendRules.fieldClass(role: fr.role, labels: labels.texts, composer: BrowserTypingComposerRules.composer(labels), search: search)
                let sp = SendRules.composerPlace(labels: labels.texts, host: BrowserTypingSites.host(of: url)) ?? ""
                return .success((sf, sp, ChromeFactDigest.of(labels.texts + ["|"] + labels.identifiers)))
            }
            guard case .success(let j) = judged else { if case .failure(let d) = judged { return .denied(d) }; return .denied(.field) }
            (sendField, sendPlace, labelDigest) = j
        }
        // 13. The end of the read: still frontmost and focused, no secure input, consent, the same launch.
        let closing: BrowserTypingDenial? = clock.observe(.focusState) {
            guard focused(ax, target.pid) else { return .notFocused }
            guard e.enabled() else { return .disabled }
            guard e.launchIdentity(target.pid) == target.launchIdentity else { return .changed }
            return nil
        }
        if let closing { return .denied(closing) }
        let ended = e.now()
        guard ended >= began, ended - began <= ChromeBracketTiming.readBudgetNanoseconds else { return .denied(.timeout) }

        // The page and focus IDs, as the synchronous design names them (one instance: M4).
        var hasher = Hasher(); hasher.combine(n.windowID); hasher.combine(tabID); hasher.combine(url.split(separator: "#", maxSplits: 1).first.map(String.init) ?? "")
        let document = hasher.finalize()
        let same = previous.map { $0.target == target.launchIdentity && $0.windowID == n.windowID && $0.tabID == tabID
            && $0.document == document && ax.equal($0.window, g.window) && ax.equal($0.webArea, fr.webArea) } ?? false
        let documentID = same ? previous!.documentID : UUID().uuidString
        let focusID = same && ax.equal(previous!.focus, fr.focus) ? previous!.focusID : UUID().uuidString
        previous = (target.launchIdentity, n.windowID, tabID, document, g.window, fr.webArea, fr.focus, documentID, focusID)
        anchor = nil
        var proof = BrowserTypingJoinProof(origin: origin, windowID: n.windowID, tabID: tabID, windowList: ids,
            documentID: documentID, focusID: focusID, targetIdentity: target.launchIdentity, role: fr.role,
            subrole: fr.subrole, checkedAt: began)
        proof.sendField = sendField; proof.sendPlace = sendPlace
        proof.pageTitle = WebTypingTitle.clean(n.pageName, url: url, origin: origin)
        proof.titleObservedAt = clock.times[.name]?.first?.sent
        proof.axURLObservedAt = clock.times[.axURL]?.first?.sent
        proof.leanRead = lean
        guard !anyFocus else { return .allowed(proof) }
        // The facts, as digests (B1: every one must be equal across a bracket). Content is dropped here.
        var digest: [ChromeFact: UInt64] = [
            .focusState: 1,
            .windowIDs: ChromeFactDigest.of(ids),
            .modes: ChromeFactDigest.of(modes),
            .axWindows: ChromeFactDigest.of(g.axFrames + [g.frame]) &+ UInt64(g.all.count),
            .bounds: ChromeFactDigest.of(bounds),
            .name: ChromeFactDigest.of(n.names + ["|", n.title, n.windowID]),
            .tab: ChromeFactDigest.of([tabID]),
            .url: ChromeFactDigest.of([url]),
            .focus: ChromeFactDigest.of([fr.role, fr.subrole, String(fr.chain.count)] + fr.roles),
            .axURL: ChromeFactDigest.of([axURL]),
            .sensitivity: ChromeFactDigest.of([sendField, sendPlace, String(labelDigest)]),
        ]
        if lean { digest[.windowIDs] = nil; digest[.tab] = nil; digest[.url] = nil }
        let window = g.window, focus = fr.focus
        let record = ChromeReadRecord(pid: target.pid, launch: target.launchIdentity, start: began, end: max(ended, began), digest: digest,
                                      times: clock.times,
                                      window: ChromeRef(window as AnyObject, same: { ($0 as? Node).map { ax.equal(window, $0) } ?? false }),
                                      focus: ChromeRef(focus as AnyObject, same: { ($0 as? Node).map { ax.equal(focus, $0) } ?? false }),
                                      chain: fr.chain.map { node in ChromeRef(node as AnyObject, same: { ($0 as? Node).map { ax.equal(node, $0) } ?? false }) })
        record.appleEvents = clock.events
        proof.bracket = record
        return .allowed(proof)
    }
}
extension BrowserTypingJoin {
    /// QF-17 bracketed field hold (Codex 07:10, `holdsRefusedBox` in the synchronous design): the box the last full
    /// read refused as `field` after a completed scan (`heldBox`), as refs compared the way this join compares nodes.
    /// Called on the join's own queue right after that read (M4); nil when there is none. Refs only: no role, label,
    /// address or value.
    public func refusedBoxRefs(accessibility ax: ChromeAXAccess<Node>) -> (window: ChromeRef, focus: ChromeRef)? {
        guard let h = heldBox else { return nil }
        let window = h.window, focus = h.focus
        return (ChromeRef(window as AnyObject, same: { ($0 as? Node).map { ax.equal(window, $0) } ?? false }),
                ChromeRef(focus as AnyObject, same: { ($0 as? Node).map { ax.equal(focus, $0) } ?? false }))
    }
}
#endif
