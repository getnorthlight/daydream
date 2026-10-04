import Foundation
import PrivacyPolicy

// Shared interface, byte-identical on fix/typing-e2e and fix/setup-status.

/// Explicit choices for switches the person actually saw (setup's apps page, or the switch in Settings).
/// nil means never chosen: setup and what's-new then show the switch ON.
public struct SetupChoices: Codable, Equatable, Sendable {
    public enum Choice: String, Codable, Sendable { case on, off }
    public var typing: Choice?
    public var chromePages: Choice?
    public var messagesAndEmail: Choice?
    public var at: String
    /// fix/sx-all round 2: every typing category checkbox the person set in Settings, by `TypingCategory` raw value, and
    /// "otherWebsites". nil (an older save) or a missing key: never chosen.
    public var categories: [String: Choice]?
    public init(typing: Choice? = nil, chromePages: Choice? = nil, messagesAndEmail: Choice? = nil, at: String = "", categories: [String: Choice]? = nil) {
        self.typing = typing; self.chromePages = chromePages; self.messagesAndEmail = messagesAndEmail; self.at = at; self.categories = categories
    }
    public var typingSeed: Bool { typing != .off }
    public var chromePagesSeed: Bool { chromePages != .off }
    public var messagesSeed: Bool { messagesAndEmail != .off && categories?[TypingCategory.messagesAndEmail.rawValue] != .off }
    public static let otherWebsitesKey = "otherWebsites"
    /// Whether turning typing on turns this category on: yes unless the person turned it off.
    public func categorySeed(_ category: TypingCategory) -> Bool {
        category == .messagesAndEmail ? messagesSeed : categories?[category.rawValue] != .off
    }
    public var otherWebsitesSeed: Bool { categories?[Self.otherWebsitesKey] != .off }
}

extension MemoryStore {
    static let setupChoicesID = "setup-choices-v2"
    public func setupChoices() throws -> SetupChoices {
        guard let raw = try rows("SELECT body FROM metadata WHERE id=?", [Self.setupChoicesID]).first?.first else { return SetupChoices() }
        return (try? decode(SetupChoices.self, raw)) ?? SetupChoices()
    }
    public func saveSetupChoices(_ value: SetupChoices) throws {
        lock.lock(); defer { lock.unlock() }
        guard writable else { throw MemError.denied }
        let body = try json(value)
        try transaction { try exec("INSERT OR REPLACE INTO metadata VALUES(?,?)", [Self.setupChoicesID, body]) }
    }
}
