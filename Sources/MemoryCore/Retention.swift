import Foundation

/// Calendar-independent retention duration. Never is a tagged value, not zero,
/// a huge duration or an invalid date. Future/secret/source rules stay separate.
public enum MemoryRetention: Equatable, Codable {
    case never
    case days(Int)
    private enum Keys: String, CodingKey { case kind, days }
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:Keys.self)
        switch try c.decode(String.self,forKey:.kind) {
        case "never":
            guard !c.contains(.days) else {throw MemError.invalid("Never cannot contain a day count")}
            self = .never
        case "days": self = .days(try c.decode(Int.self,forKey:.days))
        default: throw MemError.invalid("Unknown retention policy")
        }
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate();var c=encoder.container(keyedBy:Keys.self)
        switch self {
        case .never: try c.encode("never",forKey:.kind)
        case .days(let days): try c.encode("days",forKey:.kind);try c.encode(days,forKey:.days)
        }
    }
    public func validate() throws {
        if case .days(let n)=self, !(1...365).contains(n) {throw MemError.invalid("Retention must be Never or 1 through 365 days")}
    }
    public func cutoff(now: Date) throws -> Date? {
        try validate()
        if case .days(let n)=self {return now.addingTimeInterval(-Double(n)*86400)}
        return nil
    }
    public func permits(_ at: Date, now: Date) -> Bool {
        do {return try cutoff(now:now).map{at >= $0} ?? true} catch {return false}
    }
    public func isShorter(than old: MemoryRetention) -> Bool {
        switch (self,old) {
        case (.days,.never):return true
        case (.days(let a),.days(let b)):return a<b
        default:return false
        }
    }
}

public struct RetentionReview: Codable {
    public let id: String
    public let proposed: MemoryRetention
    public let policyRevision: String
    public let sourceRevision: String
    public let expiresAt: String
    public let affectedActionCount: Int
    public let affectedOriginalCount: Int
    public let affectedScopeHash: String
}
extension MemoryStore {
    private func retentionScope(_ proposed: MemoryRetention,now:Date) throws -> (actions:Int, originals:Int, hash:String) {
        let sourceRows=try rows("SELECT id,body FROM records LIMIT 100001")
        let hasOriginals = !(try rows("SELECT name FROM sqlite_master WHERE type='table' AND name='migration_originals'")).isEmpty
        let originalRows = hasOriginals ? try rows("SELECT id,body FROM migration_originals LIMIT 100001") : []
        guard sourceRows.count + originalRows.count <= 100000 else {throw MemError.invalid("Retention review needs paginated large-store support")}
        let cutoff=try proposed.cutoff(now:now)
        var scope=[String](),actions=0,originals=0
        for row in sourceRows {
            let source=try decode(Evidence.self,row[1])
            guard let at=timestamp(source.at) else {throw MemError.invalid("Invalid source time; retention review withheld")}
            if let cutoff,at<cutoff {scope.append("action:"+row[0]);actions += 1}
        }
        for row in originalRows {
            let original=try decode(MigrationEntry.self,row[1])
            guard let at=timestamp(original.at) else {throw MemError.invalid("Invalid original time; retention review withheld")}
            if let cutoff,at<cutoff {scope.append("original:"+row[0]);originals += 1}
        }
        return (actions,originals,fingerprint(try json(scope.sorted())))
    }
    /// No expiry or writes to original evidence. Bounded exact review; larger
    /// stores require a paged reviewer rather than an invented affected count.
    public func prepareRetentionChange(_ proposed: MemoryRetention, now: Date=Date()) throws -> RetentionReview {
        try proposed.validate()
        return try transaction {
            let current=try policy(), revision=try disclosureRevision()
            let scope=try retentionScope(proposed,now:now)
            let review=RetentionReview(id:UUID().uuidString,proposed:proposed,policyRevision:current.revision,
                sourceRevision:revision,expiresAt:iso(now.addingTimeInterval(300)),affectedActionCount:scope.actions,
                affectedOriginalCount:scope.originals,affectedScopeHash:scope.hash)
            try exec("INSERT INTO metadata VALUES(?,?)",["retention-review:"+review.id,json(review)])
            return review
        }
    }
    public func cancelRetentionChange(_ id: String) throws {
        try exec("DELETE FROM metadata WHERE id=?",["retention-review:"+id])
    }
    public func confirmRetentionChange(_ id: String, confirmed: Bool, now: Date=Date()) throws -> PrivacySettings {
        guard confirmed else {throw MemError.denied}
        let result = try transaction {
            guard let raw=try rows("SELECT body FROM metadata WHERE id=?",["retention-review:"+id]).first?.first else {throw MemError.denied}
            let review=try decode(RetentionReview.self,raw)
            var current=try policy()
            guard review.policyRevision==current.revision,review.sourceRevision == (try disclosureRevision()),
                  timestamp(review.expiresAt).map({$0>=now})==true else {throw MemError.invalid("Retention review expired or changed; review again")}
            guard try retentionScope(review.proposed,now:now).hash == review.affectedScopeHash else {
                throw MemError.invalid("Expiry scope changed with time; review again")
            }
            current.retention=review.proposed;try current.retention.validate();current.revision=UUID().uuidString
            try exec("UPDATE metadata SET body=? WHERE id='policy'",[json(current)])
            try invalidateAllNotes();try exec("DELETE FROM receipts");try invalidateDisclosure()
            try exec("DELETE FROM metadata WHERE id=?",["retention-review:"+id])
            // Policy affects visibility immediately. Existing maintenance owns
            // eventual expiry; this confirmation never runs cleanup itself.
            return current
        }
        scheduleSearchRefresh()
        return result
    }
}
