import Foundation

/// Ephemeral, owner-only captured text for the local window. Not a generated note,
/// export, search document or Codable payload. Callers must discard on memory,
/// policy or vault changes and at expiresAt; every reload repeats owner hydration.
public struct OwnerSourcePart: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let actionID: String
    public let text: String
    public let state: String
    public var description: String { "OwnerSourcePart(redacted)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct OwnerSourcePreview: Equatable, Sendable, Identifiable, CustomStringConvertible, CustomReflectable {
    public let id: String
    public let actionIDs: [String]
    public let at: String
    /// An observed typing run, never inferred from recipient, title or app overlap.
    public let runID: String?
    public let parts: [OwnerSourcePart]
    /// Observed last part: draft or submitted. Submitted is a gesture, not delivery.
    public let state: String
    public let lead: String
    public let readAt: Date
    /// Re-read after the store disclosure revision changes; never retain stale words.
    public let disclosureRevision: String
    /// Clear at this deadline even before the expiry job deletes sealed text.
    public let expiresAt: Date?
    /// claude/messages2-1003: a Messages text whose last part Return sealed (a whole text, sent or not): never the first
    /// piece of the next one. Metadata only.
    public var sealedByReturn: Bool = false
    public var description: String { "OwnerSourcePreview(redacted)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    /// claude/terminal-details-1003: a metadata-only marker for one typed action whose words are withheld for a privacy
    /// reason (no parts; `lead` holds the short reason, e.g. "Hidden: looked like a password or key"). Never words.
    public static let withheldState = "withheld"
    public var isWithheld: Bool { state == Self.withheldState && parts.isEmpty && actionIDs.count == 1 }
    /// The short, honest reason the detail shows in place of withheld words.
    public var withheldReason: String? { isWithheld ? lead : nil }
}
extension MemoryStore {
    /// Fresh, scoped owner hydration only. Short retained source selections are useful
    /// without a lossy paraphrase. Long, missing-part, unavailable or ambiguous selections
    /// decline this projection; their existing local summaries remain unchanged.
    /// Exact parts stay separate so a formatting separator cannot become source.
    public func ownerSourcePreviews(_ actionIDs: [String], now: Date = Date(), characterLimit: Int = 400) throws -> [OwnerSourcePreview] {
        try ownerSourcePreviews(actionIDs, now: now, characterLimit: characterLimit, bound: 400)
    }
    /// claude/terminal-details-1003: `bound` is 400 for every public caller (summary stand-ins stay short); the owner
    /// moment detail (`ownerSourceMomentPreviewsForActions`) shows a whole prompt, up to `MomentTypedText.blockLimit`.
    func ownerSourcePreviews(_ actionIDs: [String], now: Date, characterLimit: Int, bound: Int) throws -> [OwnerSourcePreview] {
        guard actionIDs.count <= MomentTypedText.rowLimit, characterLimit > 0, characterLimit <= bound, typedVaultState == .ready,
              try policy().captureText else { return [] }
        let revision = try actionReadEpoch(), disclosure = try disclosureRevision()
        let clock = typedClock(now)
        let wanted = Set(actionIDs.filter { !$0.isEmpty })
        guard !wanted.isEmpty, wanted.count <= MomentTypedText.rowLimit else { return [] }
        let metadata = try momentTypedRows(Array(wanted))
        // The caller supplies typed source IDs only. A missing, deleted or secure
        // member invalidates this read; do not quietly quote a partial selection.
        guard Set(metadata.map(\.id)) == wanted else { return [] }
        struct Key: Hashable {
            let run, bundle, host, window, focus, field, recipient, surface, page: String
            let generation: UInt64
        }
        struct Member {
            let row: MomentTypedRow
            let key: Key
            let observedRun: String?
            let part: Int
            let state: String
            let text: String
            let expires: Date?
            let seal: String
        }
        var groups = [Key: [Member]]()
        for row in metadata {
            guard let original = try permittedOriginal(row.id, now: now) else { return [] }
            let provenance = original.captureProvenance
            var unit = provenance?.unit
            guard unit == nil || (["typed-unit/v2", TypedUnitProvenance.sendFactsVersion].contains(unit!.version) && unit!.withheld == 0) else { return [] }
            let field = unit?.field ?? ""
            // A composer header is its own captured field, not a message body.
            guard !["to", "subject", "search"].contains(field) else { continue }
            // Open words under the existing owner grant before using sealed recipient
            // identity. A failed open invalidates the whole selected source read.
            guard let text = try hydrateTypedText(row.id, disclosure: .owner, now: now), !text.isEmpty,
                  // Legacy rows may have no unit to count scrubber omissions.
                  // Even a literal marker declines a purportedly complete quote.
                  !text.contains(TypedSecretScrubber.marker) else { return [] }
            if unit?.surface == "email" { unit?.to = try typedRecipient(row.id, now: now) }
            let verified = unit.map { !$0.runID.isEmpty && $0.part > 0 && !field.isEmpty && ($0.surface != "email" || $0.to?.isEmpty == false) } == true &&
                provenance.map { !$0.windowID.isEmpty && !$0.focusID.isEmpty && $0.generation > 0 } == true
            let run = verified ? unit!.runID : row.id
            let key = Key(run: run, bundle: row.bundle.isEmpty ? row.app : row.bundle, host: row.host,
                          window: verified ? provenance!.windowID : row.id,
                          focus: verified ? provenance!.focusID : row.id, field: field,
                          recipient: unit?.to ?? "", surface: unit?.surface ?? "", page: original.url,
                          generation: verified ? provenance!.generation : 0)
            var deadlines = [Date]()
            if let created = try rows("SELECT created_at FROM typed_text WHERE id=?", [row.id]).first?.first.flatMap(timestamp),
               let cutoff = try typedCutoff(now: clock) {
                deadlines.append(created.addingTimeInterval(clock.timeIntervalSince(cutoff)))
            }
            if let cutoff = try policy().retention.cutoff(now: clock), let at = timestamp(original.at) {
                deadlines.append(at.addingTimeInterval(clock.timeIntervalSince(cutoff)))
            }
            let state = ActionProjection.make(original).state
            guard ["draft", "submitted"].contains(state) else { return [] }
            groups[key, default: []].append(Member(row: row, key: key, observedRun: verified ? run : nil,
                part: verified ? unit!.part : 1, state: state, text: text, expires: deadlines.min(),
                seal: unit?.surface == "text" ? unit?.sealReason ?? "" : ""))
        }
        var result = [OwnerSourcePreview]()
        for members in groups.values {
            let whole = members.sorted { ($0.part, $0.row.at, $0.row.id) < ($1.part, $1.row.at, $1.row.id) }
            guard whole.map(\.part) == Array(1...whole.count) else { continue }
            // claude/messages2-1003 (owner 10/3: "every sent text must appear"): a run whose earlier parts include a send
            // is several messages, each ending at its send; it is no longer dropped whole.
            var segments: [[Member]] = [[]]
            for m in whole {
                segments[segments.count - 1].append(m)
                if m.state == "submitted" { segments.append([]) }
            }
            for ordered in segments where !ordered.isEmpty {
            guard let last = ordered.last, let first = ordered.first,
                  ordered.reduce(0, { $0 + $1.text.count }) <= characterLimit,
                  ordered.compactMap(\.expires).allSatisfy({ $0 > clock }) else { continue }
            let parts = ordered.map { OwnerSourcePart(actionID: $0.row.id, text: $0.text, state: $0.state) }
            let candidate = last.key.recipient.trimmingCharacters(in: .whitespacesAndNewlines)
            let recipient = candidate.count <= 120 && !Privacy.secret(candidate) &&
                !candidate.contains(TypedSecretScrubber.marker) &&
                candidate.rangeOfCharacter(from: .controlCharacters) == nil ? candidate : ""
            let destination = recipient.isEmpty ? "" : " to \(recipient)"
            let lead = last.state == "submitted" ? "Submitted text\(destination) in \(last.row.app)" : "Drafted text\(destination) in \(last.row.app)"
            result.append(OwnerSourcePreview(id: first.row.id, actionIDs: ordered.map { $0.row.id }, at: first.row.at,
                runID: first.observedRun, parts: parts, state: last.state, lead: lead, readAt: clock, disclosureRevision: disclosure,
                expiresAt: ordered.compactMap(\.expires).min(), sealedByReturn: last.seal == "submit"))
            }
        }
        guard try revision == actionReadEpoch(), try disclosure == disclosureRevision(),
              typedVaultState == .ready, try policy().captureText else { return [] }
        return result.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }
}

extension MemoryStore {
    /// Selected detail only: validates every original member before filtering typed
    /// source IDs. A deleted/hidden selection cannot quietly become a partial quote.
    public func ownerSourcePreviewsForActions(_ actionIDs: [String], now: Date = Date()) throws -> [OwnerSourcePreview] {
        guard !actionIDs.isEmpty, actionIDs.count <= MomentTypedText.rowLimit,
              typedVaultState == .ready, try policy().captureText else { return [] }
        let revision = try actionReadEpoch(), disclosure = try disclosureRevision()
        let wanted = Set(actionIDs)
        for id in wanted { guard try permittedOriginal(id, now: now) != nil else { return [] } }
        let typed = try momentTypedRows(Array(wanted))
        let found = try ownerSourcePreviews(typed.map(\.id), now: now)
        guard try revision == actionReadEpoch(), try disclosure == disclosureRevision() else { return [] }
        return found
    }

    /// Metadata-only active-detail revalidation. No text hydration or history scan.
    /// The vault's current state follows the existing owner access contract.
    public func ownerSourcePreviewRevision(expiresAt: Date? = nil, now: Date = Date()) throws -> String? {
        guard typedVaultState == .ready, try policy().captureText,
              expiresAt.map { $0 > typedClock(now) } != false else { return nil }
        return try disclosureRevision()
    }
}
