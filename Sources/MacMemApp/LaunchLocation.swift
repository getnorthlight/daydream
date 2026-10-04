import Foundation

// The download-window warning (SPEC 6.3 R3). A DayDream opened straight from its disk image, or one
// macOS runs from a translocated copy (App Translocation: a downloaded app opened where it landed),
// changes path on every launch. macOS then ties Accessibility and Input Monitoring to a copy that goes
// away, so DayDream asks the person to move it to Applications first and records nothing until then.
// Foundation only: scripts/recording-wake-checks.swift compiles this file on its own.

enum LaunchLocation: Equatable, Sendable {
    /// In /Applications or ~/Applications (or a folder inside either).
    case applications
    /// Anywhere else on a writable disk (a development build, an external drive). Recording is allowed.
    case elsewhere
    /// On a mounted, read-only disk image: the download window.
    case diskImage
    /// A translocated copy macOS made because the app was opened where it was downloaded.
    case translocated
    /// Not an .app bundle (the command-line checks and development runs).
    case notAnApp

    /// The warning, exactly as the person sees it.
    static let warning = "Move DayDream to Applications first."
    /// Quit comes first: the copy in the download window keeps the recorder lock while it runs, so a second copy
    /// opened from Applications could not open the history.
    static let detail = "DayDream is running from the download window. Quit DayDream, drag it into your Applications folder, then open it from there. It won't record until you do."
    static let quitTitle = "Quit DayDream"
    /// The model's resume-blocker value for this (RecordingCopy maps it to `warning`).
    static let blockerValue = "Move DayDream to Applications first"
    static let applicationsFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)

    /// Only the download window and a translocated copy block recording.
    var blocksRecording: Bool { self == .diskImage || self == .translocated }

    /// Classifies a bundle path. `readOnlyVolume`: the volume holding it is mounted read-only
    /// (a downloaded disk image is; an external drive usually isn't).
    static func classify(bundlePath raw: String, readOnlyVolume: Bool) -> LaunchLocation {
        var path = (raw as NSString).standardizingPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        guard path.lowercased().hasSuffix(".app") else { return .notAnApp }
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Volumes/") && readOnlyVolume { return .diskImage }
        let parts = path.split(separator: "/").map(String.init)
        if parts.dropLast().contains("Applications") && !path.hasPrefix("/Volumes/") { return .applications }
        return .elsewhere
    }

    /// Where this process runs from. Reads the bundle path and whether its volume is read-only.
    static func read(bundleURL: URL = Bundle.main.bundleURL) -> LaunchLocation {
        let readOnly = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return classify(bundlePath: bundleURL.path, readOnlyVolume: readOnly)
    }
}
