#if DAYDREAM_CHROME_TYPING
// Compiled only with -DDAYDREAM_CHROME_TYPING: every release build defines it; a plain swift build leaves this file out.
//
// fix/chrome-capture: the Post gesture. Website typing saves a post's words
// at the mouse-down on X's Post button (the click that would otherwise move
// focus away) or after a pause, both as drafts (`SendRules.send` never calls a
// click a send). This file proves, separately and after the words are saved,
// that the click was a plain left click on the Post (or Reply) button of the
// very composer the words were typed in, and that it was released on that
// button; only then are those rows marked submitted (`sendBy` "button").
//
// What does not count: X's navigation "Post" (a link, and outside the
// composer), a disabled button, any other button or element, a press that
// is dragged off, held too long or cancelled, a click on a page that changed
// (another page, tab or window, or a composer that is gone), any key or other
// click in between, a click more than two minutes after the words were saved,
// a Return (a new line in X's composer), and a row that already has a send
// gesture (Command-Return). A proven click is a send gesture, never a
// delivery: nothing here says a post was published.
import Foundation
import PrivacyPolicy

/// The text field the last allowed full join proved: its page identity and
/// the retained Accessibility objects from the field up to its window.
struct BrowserFieldTrail<Node> {
    let targetIdentity: String
    let windowID: String
    let tabID: String
    let documentID: String
    let focusID: String
    let focus: Node
    /// The field first, then each parent up to and including the window.
    let chain: [Node]
    let webArea: Node
    let checkedAt: UInt64
}

public enum BrowserSubmitTiming {
    /// All reads of one Post check, after the click join.
    public static let budgetNanoseconds: UInt64 = 100_000_000
    /// The button must come up within this of going down (a long press is not a click here).
    public static let releaseNanoseconds: UInt64 = 3_000_000_000
    /// The pointer may move at most this far (points) between down and up; the up must be inside the button too.
    public static let maxMove: Double = 6
    /// Rows saved longer ago than this are never marked by a click.
    public static let rowAgeNanoseconds: UInt64 = 120_000_000_000
    /// From the element under the pointer up to its button (an icon or label inside the button).
    public static let buttonHops = 4
    /// Hops from the button, and from the field, up to the composer they share.
    public static let maxButtonDepth = 24
    public static let maxFieldDepth = 48
    /// Rows kept for one composer.
    public static let maxRows = 32
}

/// Which sites' submit controls are known, and their names. A site not listed
/// here gets no Post gesture (its rows stay drafts); a name not listed is not
/// its submit control. English names only: X in another language is not
/// matched (a coverage limit, never a wrong claim).
public enum BrowserSubmitControls {
    public static let table: [(domain: String, names: Set<String>)] = [
        ("x.com", ["post", "reply", "post all"]),
        ("twitter.com", ["post", "reply", "post all"]),
    ]
    /// The control names of the site at `origin`, or nil when it has none.
    public static func names(origin: String) -> Set<String>? {
        guard let host = BrowserSites.host(of: origin) else { return nil }
        return table.first(where: { BrowserSites.matches(host: host, domain: $0.domain) })?.names
    }
    public static func normalize(_ raw: String) -> String {
        raw.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    /// The control, when every name the button has is one of `allowed` (at least one name, all the same).
    public static func control(_ names: [String], allowed: Set<String>) -> String? {
        let clean = Set(names.map(normalize).filter { !$0.isEmpty })
        guard clean.count == 1, let name = clean.first, allowed.contains(name) else { return nil }
        return name
    }
    /// A container a composer never spans: a landmark (navigation, banner, main, complementary, region, form, search),
    /// a dialog or an article (a post in the timeline).
    public static func boundary(subrole: String) -> Bool {
        subrole.hasPrefix("AXLandmark") || ["AXApplicationDialog", "AXApplicationAlertDialog", "AXDocumentArticle", "AXTabPanel"].contains(subrole)
    }
}

/// Why a click was not proven a Post. Diagnostics name these; nothing else is kept.
public enum BrowserSubmitDenial: String, Error, Sendable, CaseIterable {
    case noField, typingOff, notFocused, nothingAt, notButton, link, disabledButton, name, outsideButton, frame, fieldGone,
         unrelated, landmark, far, timeout
    /// claude/livefix-1004: the click landed in the very text box the rows were typed in (to move the caret): not a
    /// Post, and not a reason to forget the rows (the route keeps them for the Post click that follows).
    case inField
}

/// A press proven on a submit control: the control's normalized name and frame.
public struct BrowserSubmitPress: Equatable, Sendable {
    public let control: String
    public let frame: ChromeBounds
    public let checkedAt: UInt64
    public let documentID: String
    public let focusID: String
}

extension ChromeBounds {
    public func contains(x: Double, y: Double) -> Bool { x >= left && x <= right && y >= top && y <= bottom }
}

extension BrowserTypingJoin {
    /// The Post check, for a plain left press at (`x`, `y`) right after a click join `page` (anyFocus) allowed the
    /// page the rows were typed in. `focusID` is the field of those rows; `names` the site's control names
    /// (`BrowserSubmitControls`). In this order, within `BrowserSubmitTiming.budget`:
    /// 1. the field the last allowed full join proved is that field, on the page the click join proved;
    /// 2. consent is on, and Chrome is frontmost and focused with no secure input;
    /// 3. the element under the pointer is Chrome's, and it or one of its first ancestors is a button (a link, a
    ///    text box, the page or the window first is not);
    /// 4. the button is enabled, its names are all one of the site's control names, and its frame holds the point;
    /// 5. the field is still in the page with the same ancestry it was typed in (a composer that is gone is stale);
    /// 6. the button and the field meet below the page's web area (the button first reaches the field's ancestry
    ///    within `maxButtonDepth`, the field within `maxFieldDepth`, with no other web area on the way), and no
    ///    landmark, dialog or article lies between either of them and where they meet: the composer's own control;
    /// 7. consent, focus and secure input are asked again.
    /// Reads metadata only: roles, subroles, parents, frames, AXEnabled and the button's own names (compared with
    /// the list, never kept). Never the field, its value or its labels.
    public func submitControl(at x: Double, _ y: Double, pid: Int32, page: BrowserTypingJoinProof, focusID: String, names: Set<String>,
                              environment e: ChromeJoinEnvironment, accessibility ax: ChromeAXAccess<Node>) -> Result<BrowserSubmitPress, BrowserSubmitDenial> {
        let began = e.now()
        let deadline = began &+ BrowserSubmitTiming.budgetNanoseconds
        func late() -> Bool { e.now() > deadline }
        guard !page.light, let t = fieldTrail, t.focusID == focusID, t.documentID == page.documentID, t.windowID == page.windowID,
              t.tabID == page.tabID, t.targetIdentity == page.targetIdentity else { return .failure(.noField) }
        guard e.enabled() else { return .failure(.typingOff) }
        func focused() -> Bool { ax.frontmostPID() == pid && ax.systemFocusedPID() == pid && !ax.secureInput() }
        guard focused() else { return .failure(.notFocused) }
        // 3. The button under the pointer.
        guard let hit = ax.elementAt(x, y), ax.owner(hit) == pid else { return .failure(.nothingAt) }
        var node = hit, found: Node?, hops = 0
        while found == nil {
            guard let role = ax.role(node), !role.lowercased().contains("secure") else { return .failure(.notButton) }
            if role == "AXButton" { found = node; break }
            if role == "AXLink" { return .failure(.link) }
            if ax.textBox(node, role: role) { return .failure(ax.equal(node, t.focus) ? .inField : .notButton) }
            if ["AXWebArea", "AXWindow", "AXApplication"].contains(role) { return .failure(.notButton) }
            hops += 1
            guard hops <= BrowserSubmitTiming.buttonHops, let up = ax.parent(node), ax.owner(up) == pid else { return .failure(.notButton) }
            node = up
        }
        guard let button = found else { return .failure(.notButton) }
        // 4. Enabled, named as the site's control, under the pointer.
        guard ax.enabled(button) == true else { return .failure(.disabledButton) }
        guard let read = ax.controlNames(button), let control = BrowserSubmitControls.control(read, allowed: names) else { return .failure(.name) }
        guard let frame = ax.frame(button), frame.valid, frame.contains(x: x, y: y) else { return .failure(.outsideButton) }
        guard !late() else { return .failure(.timeout) }
        // 5. The field is still where it was typed: each parent read now is the one read at the join, up to the web area.
        guard let top = t.chain.firstIndex(where: { ax.equal($0, t.webArea) }), top > 0, ax.owner(t.focus) == pid else { return .failure(.fieldGone) }
        let fieldChain = Array(t.chain[0...top])
        for i in 0..<top {
            guard !late() else { return .failure(.timeout) }
            guard let up = ax.parent(fieldChain[i]), ax.equal(up, fieldChain[i + 1]) else { return .failure(.fieldGone) }
        }
        // 6. Where the button meets the field's ancestry.
        var buttonChain: [Node] = [button], meet: (button: Int, field: Int)?
        while meet == nil {
            guard !late() else { return .failure(.timeout) }
            let current = buttonChain[buttonChain.count - 1]
            if let f = fieldChain.firstIndex(where: { ax.equal($0, current) }) { meet = (buttonChain.count - 1, f); break }
            guard buttonChain.count <= BrowserSubmitTiming.maxButtonDepth else { return .failure(.far) }
            guard let up = ax.parent(current), ax.owner(up) == pid, let role = ax.role(up), !role.lowercased().contains("secure") else { return .failure(.frame) }
            if role == "AXWebArea", !ax.equal(up, t.webArea) { return .failure(.frame) }
            buttonChain.append(up)
        }
        guard let m = meet else { return .failure(.unrelated) }
        guard m.field < top else { return .failure(.unrelated) }
        guard m.button <= BrowserSubmitTiming.maxButtonDepth, m.field <= BrowserSubmitTiming.maxFieldDepth else { return .failure(.far) }
        for between in buttonChain[1..<m.button] + fieldChain[1..<max(1, m.field)] {
            guard !late() else { return .failure(.timeout) }
            guard let subrole = ax.subrole(between) else { return .failure(.frame) }
            if BrowserSubmitControls.boundary(subrole: subrole) { return .failure(.landmark) }
        }
        // 7. Still consented and focused, within the budget.
        guard e.enabled() else { return .failure(.typingOff) }
        guard focused() else { return .failure(.notFocused) }
        let ended = e.now()
        guard ended >= began, ended - began <= BrowserSubmitTiming.budgetNanoseconds else { return .failure(.timeout) }
        return .success(BrowserSubmitPress(control: control, frame: frame, checkedAt: began, documentID: page.documentID, focusID: focusID))
    }
}

/// The rows a Post click may mark, and a press proven on a Post button until
/// its release. Pure; the owner build's website route holds one.
public final class BrowserSubmitTracker {
    /// A website typing row just saved (metadata only).
    public struct Row: Equatable, Sendable {
        public let id: String, runID: String, origin: String, windowID: String, tabID: String, documentID: String, focusID: String
        public let surface: String, field: String, sealReason: String, writtenAt: UInt64
        public init(id: String, runID: String, origin: String, windowID: String, tabID: String, documentID: String, focusID: String,
                    surface: String, field: String, sealReason: String, writtenAt: UInt64) {
            self.id = id; self.runID = runID; self.origin = origin; self.windowID = windowID; self.tabID = tabID
            self.documentID = documentID; self.focusID = focusID; self.surface = surface; self.field = field
            self.sealReason = sealReason; self.writtenAt = writtenAt
        }
        /// The same page: site, window, tab and document.
        public func samePage(_ o: Row) -> Bool { origin == o.origin && windowID == o.windowID && tabID == o.tabID && documentID == o.documentID }
    }
    public struct Press: Equatable, Sendable {
        public let rows: [Row]
        public let control: String
        public let frame: ChromeBounds
        public let downAt: UInt64
        public let x: Double, y: Double
        public let revision: String
        public let generation: UInt64
        public init(rows: [Row], control: String, frame: ChromeBounds, downAt: UInt64, x: Double, y: Double, revision: String, generation: UInt64) {
            self.rows = rows; self.control = control; self.frame = frame; self.downAt = downAt; self.x = x; self.y = y
            self.revision = revision; self.generation = generation
        }
    }
    /// How a piece of a post may have ended and still be the post: a pause, a size split, a Return (a new line in
    /// X's composer), a paste, the click itself, and (claude/livefix-1004) a caret move or the box being re-created
    /// under the same page (`focus`: X redraws its composer mid-draft). Anything that may have moved focus elsewhere
    /// (Tab, a shortcut, a switch of window or app) leaves no rows to mark.
    public static let sealReasons: Set<String> = [SealReason.idle, .size, .submit, .paste, .pointer, .cursor, .focus].map(\.rawValue).reduce(into: []) { $0.insert($1) }
    public private(set) var rows: [Row] = []
    public private(set) var press: Press?
    public init() {}

    /// A row was saved. Rows of one page (the same window, tab, document and site) collect; a row of another page,
    /// one that can't be a post, one a send gesture already ended, or one sealed by something that may have moved
    /// focus starts over. claude/livefix-1004: another field of the same page no longer starts over (X re-creates its
    /// post box mid-draft, a new focus ID); the Post check still proves the button belongs to the box in use now,
    /// and the store checks each row against its own field.
    public func wrote(_ r: Row, send: String?) {
        press = nil
        guard send != "detected", Self.sealReasons.contains(r.sealReason),
              SendRules.buttonSend(surface: r.surface, field: r.field).send == "detected" else { rows = []; return }
        if let f = rows.first, !f.samePage(r) { rows = [] }
        rows.append(r)
        if rows.count > BrowserSubmitTiming.maxRows { rows.removeFirst(rows.count - BrowserSubmitTiming.maxRows) }
    }
    /// Rows a click at `now` may mark: saved within `rowAge`.
    public func candidates(now: UInt64) -> [Row] {
        rows.filter { now >= $0.writtenAt && now - $0.writtenAt <= BrowserSubmitTiming.rowAgeNanoseconds }
    }
    public var pending: Bool { !rows.isEmpty || press != nil }
    public func clear() { rows = []; press = nil }
    /// claude/livefix-1004: Command-Return sent `r` (a chord row): the earlier pieces of the same page still waiting
    /// (typed before a click or a caret move in the box) are that post too. Taken here; nothing is left to mark.
    public func chordSent(_ r: Row, now: UInt64) -> [Row] {
        defer { rows = []; press = nil }
        return candidates(now: now).filter { $0.samePage(r) && $0.id != r.id }
    }
    public func arm(_ p: Press) { press = p }
    public func cancelPress() { press = nil }
    /// The press, if this release completes it as a click on its button; the press ends either way.
    public func release(at upAt: UInt64, x: Double, y: Double, left: Bool) -> Press? {
        defer { press = nil }
        guard left, let p = press, upAt >= p.downAt, upAt - p.downAt <= BrowserSubmitTiming.releaseNanoseconds,
              ((x - p.x) * (x - p.x) + (y - p.y) * (y - p.y)).squareRoot() <= BrowserSubmitTiming.maxMove,
              p.frame.contains(x: x, y: y) else { return nil }
        return p
    }
}

#if DAYDREAM_OWNER_TYPING
extension MemoryStore {
    /// Owner build: marks website typing rows a proven Post click ended (`sendBy` "button", `send` "detected", the
    /// control's name). Each row must still be a valid join row of that page and field (`WebTypedRow.valid`, the same
    /// document and focus IDs), saved within `rowAge`, sealed by a pause, split, Return, paste or the click, with no
    /// send gesture yet, on a site and field where a click can be a post (`SendRules.buttonSend`), and still allowed
    /// by the typing pause and site rules, while recording under the same policy revision. The words are not touched
    /// (they stay sealed); the row's body and revision change, its summary is dropped so it is written again, and
    /// AI apps' cached reads are invalidated, as a re-ingest does. Rows are never inserted or duplicated. Returns the
    /// rows marked; any refusal just leaves a row a draft.
    /// claude/livefix-1004: `chord` marks the earlier pieces of a post Command-Return just sent (`sendBy` "commandReturn",
    /// no control), on a site with known submit controls, under the same checks.
    @discardableResult public func markWebTypingSubmitted(ids: [String], documentID: String, focusID: String, control: String,
                                                          expectedPolicyRevision: String, chord: Bool = false, now: Date = Date()) throws -> [String] {
        guard !ids.isEmpty, ids.count <= BrowserSubmitTiming.maxRows,
              chord || BrowserSubmitControls.table.contains(where: { $0.names.contains(control) }) else { return [] }
        return try transaction {
            guard try policy().revision == expectedPolicyRevision, try captureStatus(now: now)["state"] == "recording" else { return [] }
            var marked: [String] = []
            for id in Set(ids).sorted() {
                guard try rows("SELECT id FROM tombstones WHERE id=?", [id]).isEmpty,
                      let row = try rows("SELECT body, revision FROM records WHERE id=?", [id]).first, row.count == 2 else { continue }
                var e = try decode(Evidence.self, row[0])
                guard WebTypedRow.valid(e), e.browserVerification?.documentID == documentID, e.browserVerification?.focusID == focusID,
                      let unit = e.captureProvenance?.unit, unit.version == TypedUnitProvenance.sendFactsVersion, unit.send != "detected",
                      BrowserSubmitTracker.sealReasons.contains(unit.sealReason),
                      SendRules.buttonSend(surface: unit.surface ?? "", field: unit.field ?? "").send == "detected",
                      let at = timestamp(e.at), now.timeIntervalSince(at) >= -1,
                      now.timeIntervalSince(at) <= Double(BrowserSubmitTiming.rowAgeNanoseconds) / 1_000_000_000,
                      let names = BrowserSubmitControls.names(origin: e.url), chord || names.contains(control),
                      try typedIngestPermitted(e, now: now) else { continue }
                e.captureProvenance?.unit?.send = "detected"
                e.captureProvenance?.unit?.sendBy = chord ? "commandReturn" : "button"
                e.captureProvenance?.unit?.sendControl = chord ? nil : control
                let body = try json(e), revision = fingerprint(body)
                try exec("UPDATE records SET body=?, revision=? WHERE id=? AND revision=?", [body, revision, id, row[1]])
                guard try rows("SELECT revision FROM records WHERE id=?", [id]).first?.first == revision else { continue }
                try exec("DELETE FROM summaries WHERE id=? AND revision<>?", [id, revision])
                marked.append(id)
            }
            if !marked.isEmpty { try invalidateDisclosure(invalidateSnapshots: true) }
            return marked
        }
    }
}
#endif
#endif
