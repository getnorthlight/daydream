// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// Portions of this file are derived from open-codex-computer-history
// (https://github.com/hqhq1025/open-codex-computer-history),
// Copyright (c) 2026 Open Codex Computer History contributors, used under the
// MIT License. The full MIT notice is in THIRD-PARTY-NOTICES.md.

import Foundation

/// The reason an event must be *dropped* — never written to disk. Note what is
/// NOT here: secure input. A password field does not drop the event; it drops
/// the *characters* (at capture time, in `TextBuffer`) while still letting the
/// metadata-only event be persisted. Dropping vs. redacting is the whole point.
public enum SuppressionReason: String, Codable, Sendable {
    case applicationPolicy = "application_policy"
    case urlPolicy = "url_policy"
    case privateBrowsing = "private_browsing"
}

/// Allow/block rules plus the private-browsing and secure-field detectors. This
/// type is pure and deterministic so every guarantee below is a unit test.
public struct ObservationPolicy: Codable, Equatable, Sendable {
    public enum DefaultBehavior: String, Codable, Sendable {
        case observe
        case doNotObserve = "do_not_observe"
    }

    public enum RuleScope: String, Codable, Sendable {
        case application
        case url
    }

    public struct Rule: Codable, Equatable, Hashable, Sendable {
        public let scope: RuleScope
        public let bundleID: String?
        public let urlDomain: String?

        public init(scope: RuleScope, bundleID: String? = nil, urlDomain: String? = nil) {
            self.scope = scope
            self.bundleID = bundleID
            self.urlDomain = urlDomain
        }
    }

    public var defaultApplicationBehavior: DefaultBehavior
    public var defaultURLBehavior: DefaultBehavior
    public var allowlist: [Rule]
    public var blocklist: [Rule]

    public init(
        defaultApplicationBehavior: DefaultBehavior = .observe,
        defaultURLBehavior: DefaultBehavior = .observe,
        allowlist: [Rule] = [],
        blocklist: [Rule] = []
    ) {
        self.defaultApplicationBehavior = defaultApplicationBehavior
        self.defaultURLBehavior = defaultURLBehavior
        self.allowlist = allowlist
        self.blocklist = blocklist
    }

    // Every field is optional-on-decode so an older/partial config.json still loads.
    private enum CodingKeys: String, CodingKey {
        case defaultApplicationBehavior, defaultURLBehavior, allowlist, blocklist
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultApplicationBehavior = try c.decodeIfPresent(DefaultBehavior.self, forKey: .defaultApplicationBehavior) ?? .observe
        defaultURLBehavior = try c.decodeIfPresent(DefaultBehavior.self, forKey: .defaultURLBehavior) ?? .observe
        allowlist = try c.decodeIfPresent([Rule].self, forKey: .allowlist) ?? []
        blocklist = try c.decodeIfPresent([Rule].self, forKey: .blocklist) ?? []
    }

    // MARK: - Application / URL gates

    public func allowsApplication(_ bundleIdentifier: String) -> Bool {
        if matchesApplication(bundleIdentifier, in: blocklist) { return false }
        if matchesApplication(bundleIdentifier, in: allowlist) { return true }
        return defaultApplicationBehavior == .observe
    }

    public func allowsDomain(_ domain: String?) -> Bool {
        guard let normalized = Self.normalizedDomain(domain) else {
            return defaultURLBehavior == .observe
        }
        if matchesDomain(normalized, in: blocklist) { return false }
        if matchesDomain(normalized, in: allowlist) { return true }
        return defaultURLBehavior == .observe
    }

    /// The single decision the store consults: should this event be dropped?
    /// Returns the reason, or nil to persist. Blocklist wins over allowlist;
    /// private browsing is checked last but is unconditional for browsers.
    public func dropReason(
        bundleIdentifier: String,
        windowTitle: String?,
        urlDomain: String?
    ) -> SuppressionReason? {
        if !allowsApplication(bundleIdentifier) { return .applicationPolicy }
        if !allowsDomain(urlDomain) { return .urlPolicy }
        if Self.isPrivateBrowsing(bundleIdentifier: bundleIdentifier, title: windowTitle) {
            return .privateBrowsing
        }
        return nil
    }

    /// What the recorder does with an event, so the "private windows are never
    /// persisted" rule lives in one pure, tested place rather than inline in the
    /// capture wiring.
    public enum Routing: Equatable, Sendable {
        /// Normal event — write it, stream it.
        case persist
        /// Dropped context on a non-boundary event: count it, never write it.
        case dropCounted(SuppressionReason)
        /// Session start/end inside a dropped context: keep the marker, but strip
        /// the sensitive app/window/element details before persisting.
        case persistStrippedBoundary(SuppressionReason)
    }

    public func route(
        bundleIdentifier: String,
        windowTitle: String?,
        urlDomain: String?,
        isBoundary: Bool
    ) -> Routing {
        guard let reason = dropReason(bundleIdentifier: bundleIdentifier, windowTitle: windowTitle, urlDomain: urlDomain) else {
            return .persist
        }
        return isBoundary ? .persistStrippedBoundary(reason) : .dropCounted(reason)
    }

    // MARK: - Detectors (static: capture layer uses them before an event exists)

    /// Reduce a URL or bare host to a comparable registrable-ish host: strip the
    /// scheme, lowercase, drop a leading `www.`. Not a public-suffix parser —
    /// suffix matching in `matchesDomain` is dot-anchored to avoid `evil-x.com`
    /// matching `x.com`.
    public static func normalizedDomain(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        if let url = URL(string: value.contains("://") ? value : "https://\(value)"), let host = url.host {
            value = host
        }
        return value.hasPrefix("www.") ? String(value.dropFirst(4)) : value
    }

    /// Private/incognito requires BOTH a known browser bundle id AND a title
    /// marker — a normal window titled "incognito" in a text editor is not a
    /// browser and is not treated as private.
    public static func isPrivateBrowsing(bundleIdentifier: String, title: String?) -> Bool {
        guard browserBundleIdentifiers.contains(bundleIdentifier) else { return false }
        return titleLooksPrivate(title)
    }

    /// Window title, AX chrome, or a first segment of "Private" / "Incognito".
    public static func titleLooksPrivate(_ title: String?) -> Bool {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return false
        }
        let folded = title.lowercased()
        if privateBrowsingMarkers.contains(where: { folded.contains($0) }) { return true }
        let seps = CharacterSet(charactersIn: "—–-|·")
        let first = folded
            .components(separatedBy: seps)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return first == "private" || first == "incognito" || first == "inprivate"
    }

    public static func chromeLooksPrivate(_ blob: String) -> Bool {
        let folded = blob.lowercased()
        return privateBrowsingMarkers.contains(where: { folded.contains($0) })
            || folded.split(whereSeparator: { "—–-|·".contains($0) }).first.map { String($0).trimmingCharacters(in: .whitespaces) } == "private"
    }

    /// A field is secure if its role or subrole names a password / secure text
    /// field. Used by the capture layer to refuse to buffer the characters.
    public static func isSecureRole(_ role: String?, subrole: String?) -> Bool {
        [role, subrole].compactMap { $0?.lowercased() }.contains {
            $0.contains("securetextfield") || $0.contains("password") || $0.contains("secure input")
        }
    }

    // MARK: - Matching

    private func matchesApplication(_ bundleIdentifier: String, in rules: [Rule]) -> Bool {
        rules.contains { $0.scope == .application && $0.bundleID == bundleIdentifier }
    }

    private func matchesDomain(_ domain: String, in rules: [Rule]) -> Bool {
        rules.contains {
            guard $0.scope == .url, let ruleDomain = Self.normalizedDomain($0.urlDomain) else { return false }
            return domain == ruleDomain || domain.hasSuffix("." + ruleDomain)
        }
    }

    /// Bundle ids we recognise as browsers: the shared `KnownBrowsers` list,
    /// with prefix matching for browser families, channels and web apps.
    /// Private-browsing title detection is scoped to these. Other apps are not
    /// treated as browsers here, so an unlisted browser must be added to
    /// `KnownBrowsers`, never to a separate list.
    public static let browserBundleIdentifiers: BrowserBundleList = KnownBrowsers.list

    /// Title substrings that mark a private/incognito window, across the locales
    /// the major browsers actually ship. Matched case-folded and as substrings.
    private static let privateBrowsingMarkers: [String] = [
        "private browsing", "private window", "incognito", "in incognito", "inprivate", "inkognito",
        "navigation privée", "navigazione in incognito", "navegación privada", "incógnito",
        "navegação privada", "modo de navegación privada",
        "无痕", "無痕", "私密浏览", "私密瀏覽", "シークレット", "プライベート", "시크릿", "프라이빗",
        "инкогнито", "приватный просмотр",
    ]
}
