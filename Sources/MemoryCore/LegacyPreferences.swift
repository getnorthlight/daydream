import Foundation
import HistoryCore

/// What `settleLegacyPreferences` changed in the saved choices. Every change records less, never more:
/// nothing is ever turned on, and no site or app that could still match anything stops being skipped.
public struct LegacyPreferenceSettlement: Equatable, Sendable {
    /// The typed-text switch was saved on without this build's consent, so typing was already off.
    /// It is now saved off, the way it behaves.
    public var typingTurnedOff = false
    /// "Web pages in Chrome" was saved on with another text's consent, so it was already off.
    /// It is now saved off, the way it behaves.
    public var chromePagesTurnedOff = false
    /// Saved sites rewritten to the form the site rule keeps ("www.Example.com" becomes "example.com"),
    /// which skips the same site and every subdomain, so at least as much as before. The old entries.
    /// No site is ever removed: an entry the site rule doesn't take is kept exactly as saved, because the
    /// matcher that decides what is stored (`ObservationPolicy`) may still use it ("me@example.org" skips
    /// example.org there).
    public var sitesRewritten: [String] = []
    public init() {}
    /// Whether the saved policy was rewritten.
    public var changed: Bool { typingTurnedOff || chromePagesTurnedOff || !sitesRewritten.isEmpty }
}

extension MemoryStore {
    /// Brings choices an older build saved in line with this build's rules, once, at launch, while this app
    /// holds the recorder lock and nothing records. Older builds could leave the saved policy in a state no
    /// current screen can produce: the typed-text switch on without typed-text consent, "Web pages in Chrome"
    /// on with another text's consent, or a site written in a form the site rule no longer takes. Those rows
    /// behaved as off (or matched less) already, yet the app compared the raw values with what it shows and
    /// treated them as an unsaved change, which blocked recording.
    ///
    /// Fail closed: switches without current consent are saved off, and a site is rewritten only to a form that
    /// every site matcher (`ObservationPolicy`, `BrowserSites`, `PreCapturePrivacy`) covers at least as much
    /// with. Any other site entry, and every app entry, is kept exactly as saved (saving takes an old entry back
    /// unchanged, so it never blocks an unrelated save). No AI app is disconnected: nothing is shared that
    /// wasn't before. Pending note requests and disclosures are invalidated, as any policy change does.
    public func settleLegacyPreferences() throws -> LegacyPreferenceSettlement {
        guard writable else { return LegacyPreferenceSettlement() }
        return try transaction {
            let current = try policy()
            var next = current
            var result = LegacyPreferenceSettlement()
            if current.captureText && !current.typingOn {
                next.captureText = false; next.typedConsentVersion = nil
                result.typingTurnedOff = true
            }
            // A release without Chrome page history keeps the saved switch for a later release (ReleaseFeatures).
            if ReleaseFeatures.chromePageHistory && current.browserPages && !current.browserPagesOn {
                next.browserPages = false; next.browserPagesConsentVersion = nil
                result.chromePagesTurnedOff = true
            }
            var sites: [String] = []
            for entry in current.blockedDomains {
                if let fixed = BrowserSites.siteEntry(entry), fixed != entry, Self.covers(fixed, entry) {
                    sites.append(fixed); result.sitesRewritten.append(entry)
                } else {
                    // Already in the rule's form, or a form the rule doesn't take ("me@example.org", "intranet_host",
                    // "foo bar"): kept exactly as saved, so every matcher skips what it skipped before.
                    sites.append(entry)
                }
            }
            if !result.sitesRewritten.isEmpty { next.blockedDomains = Array(Set(sites)).sorted() }
            guard result.changed else { return result }
            next.revision = UUID().uuidString
            // gold/notes G21: as a Settings save (PreferenceSave), only typing turned off starts a new notes binding.
            next.notesRevision = result.typingTurnedOff ? UUID().uuidString : current.notesBinding
            try exec("UPDATE metadata SET body=? WHERE id='policy'", [json(next)])
            // A brand-new store's first typing answer stays pending across the rewrite.
            if try rows("SELECT body FROM metadata WHERE id='native-typing-choice-pending-v1'").first?.first == current.revision {
                try exec("UPDATE metadata SET body=? WHERE id='native-typing-choice-pending-v1'", [next.revision])
            }
            if try hasActionLayers() {
                try exec("UPDATE note_requests SET state='invalidated' WHERE state<>'invalidated'")
            }
            try invalidateDisclosure()
            return result
        }
    }

    /// Whether the site-rule form `fixed` skips everything the saved `entry` skipped, for each matcher: the host
    /// `ObservationPolicy` reads from the entry (what is stored and shown; nil when it reads none) and the form
    /// `PreCapturePrivacy` and Chrome pages compare hosts with (`domainForm`, the raw entry when it isn't a host).
    static func covers(_ fixed: String, _ entry: String) -> Bool {
        func inside(_ host: String?) -> Bool { host.map { $0 == fixed || $0.hasSuffix("." + fixed) } ?? true }
        return inside(ObservationPolicy.normalizedDomain(entry)) && inside(PreCapturePrivacy.domainForm(entry))
    }
}
