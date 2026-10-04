import MemoryCore

/// A change to the app choices (Apps to remember, typing, Web pages in Chrome and its sites) that didn't save,
/// said in one sentence, with the one button that fixes it. Settings › Apps to remember and setup's Apps page
/// show it where the choices are made; every Start control routes there while it stands.
struct PreferenceProblem: Equatable {
    enum Fix: Equatable {
        /// Saves the same change again (`MemoryViewModel.savePolicy`).
        case saveAgain
        /// Drops the change that can't save and shows the saved choices (`MemoryViewModel.reloadPreferences`).
        case useSaved
        /// The same as `useSaved`, for a change that can never save.
        case undo
    }
    let text: String
    let fix: Fix
    var buttonTitle: String {
        switch fix {
        case .saveAgain: return "Save again"
        case .useSaved: return "Use saved choices"
        case .undo: return "Undo"
        }
    }

    static let conflict = PreferenceProblem(text: "Your app choices changed in another window, so this change didn't save.", fix: .useSaved)
    static let invalidApp = PreferenceProblem(text: "One of the apps in this change can't be skipped, so it didn't save.", fix: .undo)
    static let invalidSite = PreferenceProblem(text: "One of the sites in this change isn't a web address, so it didn't save.", fix: .undo)
    static let stillRecording = PreferenceProblem(text: "Recording didn't stop, so your app choices didn't save.", fix: .saveAgain)
    static let notSaved = PreferenceProblem(text: "Your app choices didn't save.", fix: .saveAgain)
    /// The saved choices changed while a page showed the old ones (another window, or `mac-mem`), and no save
    /// is waiting.
    static let changedElsewhere = PreferenceProblem(text: "Your saved choices changed while this page was open.", fix: .useSaved)

    /// nil while nothing stands: no failed save and nothing on screen that differs from what is saved. A change
    /// still waiting for its short save delay is not a problem; Start saves it first.
    static func make(error: PreferenceSaveError?, differsFromSaved: Bool, waiting: Bool) -> PreferenceProblem? {
        switch error {
        case .revisionConflict?: return .conflict
        case .invalidApps?: return .invalidApp
        case .invalidDomains?: return .invalidSite
        case .captureMustBeStopped?: return .stillRecording
        case .storageUnavailable?: return .notSaved
        case nil: return differsFromSaved && !waiting ? .changedElsewhere : nil
        }
    }
}
