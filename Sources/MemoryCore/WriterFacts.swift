import Foundation

/// fix/sx-all round 2: metadata facts the note writer needs and only core knows. Never words.
extension MemoryStore {
    /// Whether typing in `action`'s app (in Google Chrome: its site) would be recorded now: typing on and accepted, not
    /// paused, the app or site allowed by the person's categories and block lists. The writer says "Read texts with
    /// Mom" only then; where typing is off, a window says only where it was ("Texts with Mom", "#backend on Slack"):
    /// DayDream can't tell reading from writing there. One check per call (the saved choices are read once).
    public func typingRecordableCheck(now: Date = Date()) -> (CanonicalAction) -> Bool {
        guard let saved = try? policy(), let typed = try? typedTextPolicy(), saved.typingOn, typed.consented, !typed.snoozed(now: now) else {
            return { _ in false }
        }
        let blocked = saved.blockedApps
        return { action in
            if blocked.contains(action.bundle) || PrivacySettings.sensitiveApps.contains(action.bundle) { return false }
            if action.bundle == BrowserSafety.supportedBundle {
                // Only the owner build records typing on web pages; every other build never does.
                #if DAYDREAM_OWNER_TYPING
                var host = action.site.lowercased()
                if host.hasPrefix("www.") { host.removeFirst(4) }
                guard !host.isEmpty else { return false }
                guard !BrowserTypingSites.messagingSite(host: host) || typed.categories.messagesAndEmail else { return false }
                return BrowserTypingSiteRules(policy: typed, settings: saved).permits(host: host)
                #else
                return false
                #endif
            }
            return typed.permits(bundle: action.bundle, blockedApps: blocked)
        }
    }

    /// The person's own account names, from the addresses their mail windows show ("Inbox (12) - sam@tallybird.example -
    /// Gmail" -> "sam"): the writer calls a pull request "by sam" theirs ("Checked your PR #418") and never "Reviewed".
    /// Reads at most the `recent` newest records; titles only.
    public func accountHandles(recent: Int = 20000) -> [String] {
        guard let rows = try? rows("SELECT body FROM records WHERE rowid > (SELECT COALESCE(MAX(rowid),0) FROM records) - ? AND body LIKE '%@%'", [String(recent)]) else { return [] }
        var out: [String] = []
        for row in rows {
            guard let body = row.first, let e = try? JSONDecoder().decode(Evidence.self, from: Data(body.utf8)) else { continue }
            let host = (BrowserSites.host(of: e.url) ?? "").lowercased()
            let mail = WriterFacts.mailApps.contains(e.app) || WriterFacts.mailHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
            guard mail else { continue }
            for handle in WriterFacts.handles(inTitle: e.title) where !out.contains(handle) { out.append(handle) }
            if out.count >= 8 { break }
        }
        return out
    }
}

public enum WriterFacts {
    static let mailApps: Set<String> = ["Mail", "Microsoft Outlook", "Outlook", "Spark", "Mimestream", "Airmail"]
    static let mailHosts = ["mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com", "mail.yahoo.com", "app.fastmail.com", "mail.proton.me"]
    static let address = try! NSRegularExpression(pattern: #"([A-Za-z0-9._%+-]+)@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
    /// The local part of every address in a mail window's title, lower case, without a "+tag".
    public static func handles(inTitle title: String) -> [String] {
        let range = NSRange(title.startIndex..., in: title)
        return address.matches(in: title, range: range).compactMap { m in
            guard let r = Range(m.range(at: 1), in: title) else { return nil }
            let local = title[r].lowercased().split(separator: "+").first.map(String.init) ?? ""
            return local.count >= 2 ? local : nil
        }
    }
}
