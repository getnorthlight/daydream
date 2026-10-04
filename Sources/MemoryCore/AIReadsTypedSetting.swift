import Foundation

/// "Let AI apps read what you typed" (owner 10/3): whether connected AI apps (ChatGPT, Claude, ...) may search and read
/// the person's typed words through DayDream. Passwords are never shared either way. On by default.
///
/// INTEGRATION NOTE: the reader-side setting is being built on claude/summary-1003, which had no key yet when this was
/// written. This tiny file is the fallback the coordinator named ("aiAppsReadTyped", default true); the integrator
/// reconciles it with that branch's key and accessor (keep one).
public enum AIReadsTypedSetting {
    public static let key = "aiAppsReadTyped"
    public static let defaultValue = true
    public static let title = "Let AI apps read what you typed"
    public static let line = "ChatGPT, Claude and other connected apps can search and read your typed words. Passwords are never shared."
    public static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
    public static func set(_ on: Bool, _ defaults: UserDefaults = .standard) { defaults.set(on, forKey: key) }
}
