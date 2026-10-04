import Foundation
import PrivacyPolicy

/// Messages has a conversation list beside a new composer. An app/title
/// fallback is not proof that words belong to the selected conversation.
enum MessagesMomentIdentity {
    static func applies(_ action: CanonicalAction) -> Bool {
        applies(bundle: action.bundle, app: action.app)
    }
    static func applies(bundle: String, app: String) -> Bool {
        bundle == "com.apple.MobileSMS" || (bundle.isEmpty && app == "Messages")
    }
    static func recipient(_ unit: TypedUnitProvenance?) -> String? {
        recipient(surface: unit?.surface, field: unit?.field, to: unit?.to)
    }
    static func recipient(surface: String?, field: String?, to: String?) -> String? {
        guard surface == "text", ["message", "body", "textArea"].contains(field ?? "") else { return nil }
        return to.flatMap(SendRules.conversationName)
    }
    /// claude/messages2-1003 (owner 10/3): who a typed Messages unit went to, for cards, What happened and summaries:
    /// its own code-read recipient (`recipient`), else, for a proven message box only, the phone number or email address
    /// its own window title showed at the key (`SendRules.messagesHandle`: capture keeps no number in `to`, rule 7).
    /// The same proof as `recipient`: never a nearby row's title, never a New Message or search box.
    static func conversation(_ unit: TypedUnitProvenance?, title: String) -> String? {
        if let named = recipient(unit) { return named }
        guard unit?.surface == "text", ["message", "body", "textArea"].contains(unit?.field ?? "") else { return nil }
        return SendRules.messagesHandle(title)
    }
    static func name(_ action: CanonicalAction, recipient: String? = nil) -> String? {
        guard applies(action) else { return nil }
        // Typed rows use only their own code-read recipient fact. A title on
        // an unclassified recipient/search field cannot establish a chat.
        if action.kind == "keyboard.text_input" { return recipient.flatMap(SendRules.conversationName) }
        // Other observations/markers may use their own window metadata. They
        // contain no draft words, and cannot lend that identity to typed rows.
        return SendRules.conversationName(MemoryStore.windowTitle(action))
    }
    static func key(_ name: String) -> String {
        name.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
