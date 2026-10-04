import Foundation

public struct LegacyFootprint: Equatable {
    public let socketPresent: Bool
    public let services: [String]
    public var requiresMigration: Bool { socketPresent || !services.isEmpty }
    public init(socketPresent: Bool, services: [String]) { self.socketPresent = socketPresent; self.services = services }
}

/// Scoped presence checks only. Does not read recordings, configuration values,
/// plist environments, process lists, logs, or connect to a live collector.
///
/// The probe for an earlier collector is off in public builds: `legacy(at:)`
/// reports no footprint and touches nothing on disk, so it never blocks
/// recording. A private migration build turns it on with
/// `swift build -Xswiftc -DDAYDREAM_LEGACY_COLLECTOR_PROBE`. Checks call
/// `legacy(at:exists:)` with their own `exists` to exercise the matching rules.
public enum InstallationReview {
    /// Launch agents of an earlier collector. None ship in public builds (the private collector's names were removed).
    public static let knownServices: [String] = []
    public static func legacy(at userHome: URL) -> LegacyFootprint {
        #if DAYDREAM_LEGACY_COLLECTOR_PROBE
        return legacy(at: userHome, exists: { FileManager.default.fileExists(atPath: $0) })
        #else
        return LegacyFootprint(socketPresent: false, services: [])
        #endif
    }
    public static func legacy(at userHome: URL, exists: (String) -> Bool) -> LegacyFootprint {
        let services = knownServices.filter { exists(userHome.appendingPathComponent("Library/LaunchAgents/\($0).plist").path) }
        return LegacyFootprint(socketPresent:exists(userHome.appendingPathComponent(".open-codex-computer-history/IPC/history.sock").path),services:services)
    }
    /// A quick path test. Settings › Setup › Uninstall uses the full rules in `UninstallPlanner`.
    public static func removableApp(bundle: URL, userHome: URL, bundleID: String?) -> Bool {
        guard bundleID == DaydreamIdentity.bundleID else { return false }
        let candidates = UninstallLocations(home: userHome).appCandidates
        // Do not follow an application symlink into an unrelated project.
        return candidates.contains { $0.standardizedFileURL.path == bundle.standardizedFileURL.path && $0.resolvingSymlinksInPath().path == bundle.standardizedFileURL.path }
    }
    public static func captureBlocker(_ legacy: LegacyFootprint) -> String? {
        legacy.requiresMigration ? "Legacy collector footprint detected. Recording is blocked until a verified replacement preserves its consumers. Nothing was stopped or imported." : nil
    }
}
