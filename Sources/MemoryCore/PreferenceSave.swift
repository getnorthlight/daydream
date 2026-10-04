import Foundation

/// Excludes retention, grants and capture activation.
public struct MemoryPreferences: Equatable {
    public var blockedApps: [String]
    public var nativeTyping: Bool
    /// The owner's "Sites not recorded", in BrowserSites.siteEntry form. nil keeps the saved list.
    public var blockedDomains: [String]?
    /// "Web pages in Chrome". nil keeps the saved switch.
    public var browserPages: Bool?
    /// fix/typing-e2e (L3): the save came from a surface that showed the typing switch (setup's apps page). Only such
    /// a save, or one that changes the typing switch, answers the first setup's typing question
    /// (`native-typing-choice-pending-v1`); any other save (an app excluded in Settings) keeps it pending.
    public var typingChoiceShown: Bool
    /// "Save email subjects" (email-1003). nil keeps the saved choice.
    public var emailSubjects: Bool?
    public init(blockedApps: [String], nativeTyping: Bool, blockedDomains: [String]? = nil, browserPages: Bool? = nil,
                typingChoiceShown: Bool = false, emailSubjects: Bool? = nil) {
        self.blockedApps = blockedApps; self.nativeTyping = nativeTyping
        self.blockedDomains = blockedDomains; self.browserPages = browserPages; self.typingChoiceShown = typingChoiceShown
        self.emailSubjects = emailSubjects
    }
}
public enum PreferenceSaveError: Error, Equatable {
    case invalidApps, invalidDomains, revisionConflict, captureMustBeStopped, storageUnavailable
}
public struct PreferenceSaveResult {
    public let policy: PrivacySettings
    public let changed: Bool
    public let revokedGrantCount: Int
}
extension MemoryStore {
    /// The caller must stop the actual capture controller first, and leave it
    /// stopped on any error. A store cannot stop another process's event tap.
    /// A successful save never starts capture or restores a capability grant.
    public func savePreferences(_ preferences: MemoryPreferences, expectedRevision: String) throws -> PreferenceSaveResult {
        guard preferences.blockedApps.count <= 256 else { throw PreferenceSaveError.invalidApps }
        // Entries that break today's rules. Each must already be saved (below): an entry an older build saved
        // is taken back unchanged, so it keeps skipping what it skipped and never blocks an unrelated save.
        let unruledApps = preferences.blockedApps.filter { value in
            !(!value.isEmpty && value.utf8.count <= 256 &&
              value.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil)
        }
        var unruledDomains: [String] = []
        if let domains = preferences.blockedDomains {
            guard domains.count <= 256 else { throw PreferenceSaveError.invalidDomains }
            unruledDomains = domains.filter { BrowserSites.siteEntry($0) != $0 }
        }
        let apps = Array(Set(preferences.blockedApps)).sorted()
        do {
            return try transaction {
                let current = try policy()
                guard Set(unruledApps).isSubset(of: Set(current.blockedApps)) else { throw PreferenceSaveError.invalidApps }
                guard Set(unruledDomains).isSubset(of: Set(current.blockedDomains)) else { throw PreferenceSaveError.invalidDomains }
                guard current.revision == expectedRevision else { throw PreferenceSaveError.revisionConflict }
                // The first setup's answer (the marker still names this policy): its switches start on (opt-out, owner
                // 9/27), so saving them on is the default, not a change that shares more (below).
                let marker = try rows("SELECT body FROM metadata WHERE id='native-typing-choice-pending-v1'").first?.first
                let firstChoice = !current.captureText && current.typedConsentVersion == nil && marker == current.revision
                let currentTyping = current.captureText && current.typedConsentVersion == 1
                // Continuing with Off is an explicit choice even when the capture policy itself does not change.
                // fix/typing-e2e (L3): only a save from a surface that showed the typing switch (or one that changes
                // it) answers the question; an unrelated save keeps it pending (carried to the new revision below).
                let answersTyping = preferences.typingChoiceShown || preferences.nativeTyping != currentTyping
                if answersTyping { try exec("DELETE FROM metadata WHERE id='native-typing-choice-pending-v1'") }
                if Set(current.blockedApps) == Set(apps), currentTyping == preferences.nativeTyping,
                   current.captureText == preferences.nativeTyping,
                   preferences.blockedDomains.map({ Set($0) == Set(current.blockedDomains) }) ?? true,
                   preferences.browserPages.map({ $0 == current.browserPages && $0 == current.browserPagesOn }) ?? true,
                   preferences.emailSubjects.map({ $0 == current.emailSubjects }) ?? true {
                    return PreferenceSaveResult(policy: current, changed: false, revokedGrantCount: 0)
                }
                // Raw persisted state, not an expired heartbeat interpreted as stopped.
                let capture = try rows("SELECT body FROM metadata WHERE id='capture'").first?.first
                let state = try capture.map { try decode([String:String].self, $0)["state"] } ?? "off"
                guard ["off", "paused", "error", "permission_denied"].contains(state ?? "") else {
                    throw PreferenceSaveError.captureMustBeStopped
                }
                var next = current
                next.blockedApps = apps; next.captureText = preferences.nativeTyping
                next.typedConsentVersion = preferences.nativeTyping ? 1 : nil
                // Switch on, switch off, adding or removing a site: all take this
                // path, so recording stops (AI apps stay connected unless the change shares more: below).
                if let domains = preferences.blockedDomains { next.blockedDomains = Array(Set(domains)).sorted() }
                if let pages = preferences.browserPages {
                    next.browserPages = pages; next.browserPagesConsentVersion = pages ? PrivacySettings.browserPagesConsentCurrent : nil
                }
                if let subjects = preferences.emailSubjects { next.emailSubjects = subjects }
                next.revision = UUID().uuidString
                // gold/notes G21: notes bind to `notesRevision`, not to every save. Each note's inputs are its actions,
                // re-read under the new policy, so a save that hides some actions already changes exactly the notes
                // that held them. Turning typing off is the one change that can alter what an earlier writer read
                // without changing the actions (sealed rows read the same), so only it starts a new binding.
                next.notesRevision = current.captureText && !next.captureText ? UUID().uuidString : current.notesBinding
                // A connected AI app agreed to read what DayDream kept when it was connected. A change that only hides
                // more (excluding an app or a site, turning typing or Chrome pages off) stays inside that: its key keeps
                // working, and every read is filtered by the new choices at once. A change that shares more (an app or
                // a site no longer excluded, typing or Chrome pages turned on) turns every key off, so each AI app is
                // connected again for what it can now read. Except the first setup's default-on switches (owner, consent
                // audit 9/28): an AI app connected before Start keeps its key when setup saves typing and Chrome pages
                // on as they started; excluding fewer apps or sites there still shares more.
                let sharesMore = !Set(current.blockedApps).isSubset(of: Set(apps))
                    || (preferences.blockedDomains.map { !Set(current.blockedDomains).isSubset(of: Set($0)) } ?? false)
                    || (!firstChoice && preferences.nativeTyping && !currentTyping)
                    || (!firstChoice && preferences.browserPages == true && !current.browserPagesOn)
                    // email-1003: subjects back on shares more (AI apps would read email titles again).
                    || (preferences.emailSubjects == true && !current.emailSubjects)
                var grants = 0
                try exec("UPDATE metadata SET body=? WHERE id='policy'", [json(next)])
                // A first setup's typing question still waiting stays pending across an unrelated save.
                if !answersTyping, marker == current.revision {
                    try exec("UPDATE metadata SET body=? WHERE id='native-typing-choice-pending-v1'", [next.revision])
                }
                if sharesMore {
                    grants = Int(try rows("SELECT count(*) FROM grants").first![0]) ?? 0
                    // These rows are live bearer authority, not historical receipts.
                    try exec("DELETE FROM grants")
                } else if currentTyping && !preferences.nativeTyping {
                    // Typing off: no AI app keeps exact-word access (or a request for it); its plain key keeps working.
                    try stripTypedExactGrantsWithinTransaction()
                }
                if try hasActionLayers() {
                    try exec("UPDATE note_requests SET state='invalidated' WHERE state<>'invalidated'")
                }
                // Generated notes bind policy into inputRevision. Canonical readers
                // re-filter evidence before summaries/corrections are disclosed.
                // Preserve bodies, relationships, summaries and receipt rows intact.
                try invalidateDisclosure()
                return PreferenceSaveResult(policy: next, changed: true, revokedGrantCount: grants)
            }
        } catch let error as PreferenceSaveError { throw error }
        // Another connection held the file (busy, locked): nothing was written, and the same save can succeed a moment
        // later. Said as it is (a busy MemError, CaptureFault.busy), so the app can try again by itself.
        catch let error as MemError where CaptureFault.busy(error) { throw error }
        catch { throw PreferenceSaveError.storageUnavailable }
    }
}
