import AppKit
import ServiceManagement

/// DayDream's login item (`SMAppService.mainApp`), behind one seam: the app uses `live`, and every check build gets
/// `inert` (MemoryViewModel.loginItem), so no check ever registers a login item or reads this Mac's.
///
/// Owner decision (test 5): DayDream opens at login, so recording that was on starts again after a restart
/// (`LaunchResume`). It is turned on once when setup finishes (or at the first launch of this version, if setup had
/// finished before), and Settings › Advanced has the one switch that turns it off and on. Uninstall removes it
/// (UninstallService).
struct LoginItemControl {
    enum Status: Equatable, Sendable {
        case enabled
        /// Registered, but macOS wants the person to allow it in System Settings › General › Login Items.
        case requiresApproval
        case off
    }
    var status: () -> Status
    var register: () throws -> Void
    var unregister: () throws -> Void
    /// System Settings › General › Login Items (the only place macOS lets the person allow it).
    var openSettings: () -> Void

    static let live = LoginItemControl(
        status: {
            switch SMAppService.mainApp.status {
            case .enabled: return .enabled
            case .requiresApproval: return .requiresApproval
            default: return .off
            }
        },
        register: { try SMAppService.mainApp.register() },
        unregister: { try SMAppService.mainApp.unregister() },
        openSettings: { SMAppService.openSystemSettingsLoginItems() })

    /// Registers nothing and reads nothing (check builds).
    static let inert = LoginItemControl(status: { .off }, register: {}, unregister: {}, openSettings: {})
}
