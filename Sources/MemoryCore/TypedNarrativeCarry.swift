import Foundation
import PrivacyPolicy

/// One short, already scrubbed prefix of adjacent certified typing parts.
/// Memory only, under MemoryStore.lock. Never opens previous rows or changes provenance.
/// It only supplies the prefix check of the existing finite sig/emoticon rule.
struct TypedNarrativeCarry: CustomStringConvertible, CustomReflectable {
    private struct Identity: Equatable {
        let bundle: String, window: String, focus: String, run: String, field: String
        let capturePolicy: String, typedPolicy: String, epoch: String?, recordingEpoch: String?
        let generation: UInt64
    }
    private let identity: Identity
    private let part: Int
    private let prefix: String
    private let at: Date
    private let acceptedAt: Date
    var description: String { "TypedNarrativeCarry(redacted)" }
    var customMirror: Mirror { Mirror(self, children: [:]) }

    private static func certified(_ e: Evidence, typedPolicy: String, epoch: String?, recordingEpoch: String? = nil, now: Date) -> (Identity, Int, Date)? {
        guard e.kind == "keyboard.text_input", !e.secure, e.browserVerification == nil,
              CaptureGate.nativeApps.contains(e.bundle),
              !e.bundle.isEmpty, e.bundle.utf8.count <= 256,
              let p = e.captureProvenance, p.classifierVersion == UnitClassifier.version,
              !p.windowID.isEmpty, !p.focusID.isEmpty, p.windowID.utf8.count <= 256, p.focusID.utf8.count <= 256,
              !p.policyRevision.isEmpty, p.policyRevision.utf8.count <= 256, p.generation > 0,
              let u = p.unit, u.version == TypedUnitProvenance.sendFactsVersion,
              !u.runID.isEmpty, u.runID.utf8.count <= 128, (1...100_000).contains(u.part),
              u.withheld == 0, u.pasted == false,
              let field = u.field, field != "unknown", SendRules.fields.contains(field),
              let at = timestamp(e.at), let checked = timestamp(p.checkedAt),
              abs(at.timeIntervalSince(checked)) <= 1,
              now.timeIntervalSince(at) >= -1, now.timeIntervalSince(at) <= 1 else { return nil }
        return (Identity(bundle: e.bundle, window: p.windowID, focus: p.focusID, run: u.runID, field: field,
                         capturePolicy: p.policyRevision, typedPolicy: typedPolicy, epoch: epoch, recordingEpoch: recordingEpoch, generation: p.generation), u.part, at)
    }
    func maintenanceAllowed(capturePolicy:String,typedPolicy:String,recordingEpoch:String?,now:Date) -> Bool {
        identity.capturePolicy == capturePolicy && identity.typedPolicy == typedPolicy && identity.recordingEpoch == recordingEpoch &&
            recordingEpoch != nil && now >= acceptedAt && now.timeIntervalSince(acceptedAt) <= 120
    }
    func preceding(_ e: Evidence, typedPolicy: String, epoch: String?, recordingEpoch: String? = nil, now: Date) -> String? {
        guard let (key, nextPart, nextAt) = Self.certified(e, typedPolicy: typedPolicy, epoch: epoch, recordingEpoch: recordingEpoch, now: now),
              key == identity, nextPart == part + 1, nextAt >= at,
              now >= acceptedAt, now.timeIntervalSince(acceptedAt) <= 120 else { return nil }
        return prefix
    }
    static func advancing(_ e: Evidence, sanitized: Evidence, previous: TypedNarrativeCarry?, typedPolicy: String, epoch: String?, recordingEpoch: String? = nil, now: Date) -> Self? {
        guard let (key, part, at) = certified(e, typedPolicy: typedPolicy, epoch: epoch, recordingEpoch: recordingEpoch, now: now),
              let u = e.captureProvenance?.unit, ["idle", "size"].contains(u.sealReason),
              sanitized.captureProvenance?.unit?.withheld == 0,
              !e.text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }), !sanitized.text.isEmpty else { return nil }
        let prior: String
        if part == 1 { prior = "" }
        else {
            guard let text = previous?.preceding(e, typedPolicy: typedPolicy, epoch: epoch, recordingEpoch: recordingEpoch, now: now) else { return nil }
            prior = text
        }
        let prefix = prior + sanitized.text
        guard prefix.count <= 128, prefix.unicodeScalars.allSatisfy({
            CharacterSet.letters.contains($0) || $0 == " " || $0 == "'" || $0 == "\u{2019}"
        }) else { return nil }
        return Self(identity: key, part: part, prefix: prefix, at: at, acceptedAt: now)
    }
}
