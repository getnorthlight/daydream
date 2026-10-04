import Foundation
import PrivacyPolicy

extension TypedUnitProvenance {
    /// summaries/v3 (spec §2): stores the code-decided send facts on a unit sealed now, and marks it typed-unit/v3.
    /// `pasted` is stored only when true, so a unit without a paste has no new key beyond the facts.
    public mutating func apply(_ facts:SendFacts,pasted:Bool) {
        surface=facts.surface; field=facts.field; send=facts.send; sendBy=facts.sendBy; to=facts.to
        self.pasted=pasted ? true : nil
        version=Self.sendFactsVersion
    }
}
