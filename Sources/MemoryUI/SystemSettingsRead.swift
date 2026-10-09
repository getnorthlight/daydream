import AppKit
import ApplicationServices

/// rc-018 RC3 (package A): what DayDream's own restart and its hand-back to setup read about System Settings. Reads
/// only: nothing here clicks, types, moves or asks anything, except `quit`, which runs only from the person's own press
/// (setup's "Quit" beside "Quit System Settings and open it again."). Accessibility is read only once it is allowed
/// (`SettingsWindowAX`); before that a sheet can't be seen and `sheetUp` says so (nil).
public enum SystemSettingsRead {
    /// System Settings (and System Preferences before it).
    public static let bundle = PermissionWindowFloat.systemSettingsBundle

    /// System Settings is the app in front.
    public static func frontmost() -> Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle }

    /// System Settings runs.
    public static func running() -> Bool { SettingsWindowAX.running() != nil }

    /// A sheet is over one of System Settings' windows: macOS's "Quit & Reopen / Later" after Input Monitoring is turned
    /// on, or a password sheet. false when System Settings doesn't run or shows no sheet; nil when it can't be read
    /// (Accessibility isn't allowed yet).
    /// rc-018 RC3 review: the window server's alert (`alertOnScreen`) counts first, so a sheet System Settings' own
    /// windows don't hold (its privacy extension's) still reads as up, Accessibility or not.
    public static func sheetUp() -> Bool? {
        if alertOnScreen() { return true }
        guard AXIsProcessTrusted() else { return nil }  // never an Accessibility call without it (permission-prompt-checks)
        guard let app = SettingsWindowAX.running() else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        let windows = (SettingsWindowAX.attribute(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for window in windows.prefix(8) {
            AXUIElementSetMessagingTimeout(window, 0.3)
            let role = SettingsWindowAX.attribute(window, kAXRoleAttribute) as? String
            let subrole = SettingsWindowAX.attribute(window, kAXSubroleAttribute) as? String
            if role == "AXSheet" || subrole == "AXDialog" || subrole == "AXSystemDialog" { return true }
            if SettingsWindowAX.hasSheet(window) { return true }
        }
        return false
    }

    /// rc-018 RC3 review: macOS's "Quit & Reopen / Later" alert as the window server lists it (no permission needed):
    /// an on-screen window of System Settings, or of one of its extensions (SecurityPrivacyExtension owns that alert),
    /// alert-sized and not System Settings' main window. A popover counted by mistake only holds DayDream's restart up to
    /// its 10 s limit.
    public static func alertOnScreen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return alert(in: list, settingsPID: SettingsWindowAX.running()?.processIdentifier, ownPID: ProcessInfo.processInfo.processIdentifier)
    }
    /// `alertOnScreen` on a given window list (the checks pin it). `bundleOf`: a window owner's bundle ID.
    public static func alert(in list: [[String: Any]], settingsPID: pid_t?, ownPID: pid_t,
                             bundleOf: (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }) -> Bool {
        struct Entry { let pid: pid_t; let owner: String; let layer: Int; let rect: CGRect }
        let entries: [Entry] = list.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init), pid != ownPID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return Entry(pid: pid, owner: info[kCGWindowOwnerName as String] as? String ?? "", layer: info[kCGWindowLayer as String] as? Int ?? 0, rect: rect)
        }
        // System Settings' main window: its largest normal window (as `SettingsWindowAX.server`).
        let main = entries.filter { $0.pid == settingsPID && $0.layer == 0 && $0.rect.width >= 200 && $0.rect.height > 200 }
            .max { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?.rect
        return entries.contains { e in
            guard (0..<24).contains(e.layer), e.rect != main, (180...640).contains(e.rect.width), (80...560).contains(e.rect.height) else { return false }
            if e.pid == settingsPID || e.owner.contains("SecurityPrivacy") || e.owner.contains("PrivacySecurity") { return true }
            let bundle = bundleOf(e.pid) ?? ""
            return bundle.hasPrefix("com.apple.settings.") || bundle.hasPrefix("com.apple.systempreferences")
        }
    }

    /// A password or Touch ID window is on screen (the window server's list; needs no permission).
    public static func authOnScreen() -> Bool { SettingsWindowAX.server(pid: nil).auth }

    /// When the running System Settings opened; nil when it doesn't run (or macOS doesn't say).
    public static func launchDate() -> Date? { SettingsWindowAX.running()?.launchDate }

    /// Quits System Settings. Only from the person's press; false when it doesn't run or refused.
    @discardableResult public static func quit() -> Bool { SettingsWindowAX.running()?.terminate() ?? false }
}
