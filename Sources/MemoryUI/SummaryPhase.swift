import Foundation

// Shared interface, byte-identical on fix/engine-battery, fix/day-card and fix/setup-status.

/// The one summaries state every surface shows (setup, Settings, Today card).
public enum SummaryPhase: Equatable, Sendable {
    case off
    case downloading(received: Int64, total: Int64)
    case checking
    case on(SummaryMode)
    case failed(SummaryProblem)
}

public enum SummaryMode: String, Equatable, Sendable { case local, cloud }

public enum SummaryProblem: String, Equatable, Sendable {
    case downloadStopped, noSpace, noMemory, badDownload, appleCheck, modelWontStart, moveApp
    case cloudKey, cloudCredits, cloudHost, cloudOffline
}

public extension SummaryPhase {
    /// The one status line; nil when nothing needs saying.
    var line: String? {
        switch self {
        case .off, .on: return nil
        case .downloading(let received, let total):
            return "Downloading \(SummaryPhase.gigabytes(received)) of \(SummaryPhase.gigabytes(total)) GB"
        case .checking: return "Checking the model"
        case .failed(let problem): return problem.line
        }
    }
    static func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f", Double(max(0, bytes)) / 1_000_000_000) }
}

public extension SummaryProblem {
    var line: String {
        switch self {
        case .downloadStopped: return "The download stopped."
        case .noSpace: return "Summaries on this Mac need about 2.8 GB of free space."
        case .noMemory: return "Summaries on this Mac need 8 GB of memory."
        case .badDownload: return "The download was damaged."
        case .appleCheck: return "DayDream couldn't check its signature with Apple."
        case .modelWontStart: return "The model couldn't start."
        case .moveApp: return "Move DayDream to Applications to use summaries on this Mac."
        case .cloudKey: return "OpenRouter didn't accept this key."
        case .cloudCredits: return "Your OpenRouter account is out of credits."
        case .cloudHost: return "OpenRouter has no zero-retention host for this model right now."
        case .cloudOffline: return "Can't reach OpenRouter."
        }
    }
    /// The one fixing button.
    var button: String {
        switch self {
        case .cloudKey: return "Change Key"
        case .cloudCredits: return "Add Credits"
        // fix/sx-all round 1: Try Again can never add memory; the button turns on the key switch instead.
        case .noMemory: return CloudSummariesText.title
        default: return "Try Again"
        }
    }
}
