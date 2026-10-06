import Foundation

/// "Let AI apps see your typed words" (owner 10/3; agent-tools v2, owner 10/4): whether connected AI apps (ChatGPT,
/// Claude, ...) may search and read the person's typed words through DayDream, with passwords, codes and other secrets
/// removed (`AgentSharePolicy.shareable`). On by default; off, AI apps get no typed actions at all.
///
/// INTEGRATION NOTE: the reader-side setting is being built on claude/summary-1003, which had no key yet when this was
/// written. This tiny file is the fallback the coordinator named ("aiAppsReadTyped", default true); the integrator
/// reconciles it with that branch's key and accessor (keep one).
public enum AIReadsTypedSetting {
    public static let key = "aiAppsReadTyped"
    public static let defaultValue = true
    public static let title = "Let AI apps see your typed words"
    /// The setup and Settings sentence (owner decision 10/04).
    public static let line = "AI apps you connect can see what you type, minus passwords and codes."
    public static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
    public static func set(_ on: Bool, _ defaults: UserDefaults = .standard) { defaults.set(on, forKey: key) }
}
