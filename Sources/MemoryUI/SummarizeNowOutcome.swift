import Foundation

// claude/summary-fail-1003 (owner 10/3, installed 20261003140001): a Summarize Now click that waited a minute for the
// background writer (rewriting the day after a version bump) failed, and the card said "Couldn't summarize. Check
// Summaries in Settings." while Settings said summaries were fine and the writer kept writing. A one-off never points at
// Settings: the card keeps "Summary pending" (or "What you wrote") and its Summarize Now, says one quiet line, and tries
// again once by itself. Only summaries that are really off or broken point at Settings, and then they say what is wrong.

/// Why one Summarize Now wrote nothing. The writer throws it; anything else it throws counts as `.once`.
public enum SummarizeNowFailure: Error, Equatable, Sendable {
    /// Summaries are really off or broken; `reason` says exactly what ("Summaries are off.").
    case setup(String)
    /// Only this moment, only this time: the writer was busy with other notes, still starting, the moment changed or the
    /// Mac was too hot. `reason` is for checks and logs; the card never shows it.
    case once(String)
}

public enum SummarizeNowNotice {
    /// The card's quiet line after a one-off, beside its Summarize Now.
    public static let quietLine = "Couldn't summarize this one. Try again."
    /// A one-off is tried again once by itself, this long after it failed.
    public static let retryDelay: TimeInterval = 120
    public static let summariesOff = "Summaries are off. Turn them on in Settings."

    /// The banner for a failed Summarize Now, or nil for a one-off (the card keeps its Summarize Now and `quietLine`).
    /// Settings is named only when summaries are off or broken, with what is wrong: a failed phase says its problem
    /// ("The model couldn't start."); a download or the model check in progress is not broken.
    public static func banner(for error: Error, summaries: SummaryAvailability) -> String? {
        if case .setup(let reason)? = error as? SummarizeNowFailure { return setupLine(reason) }
        switch summaries.shown {
        case .off: return summariesOff
        case .failed(let problem): return setupLine(problem.line)
        case .on, .downloading, .checking: return nil
        }
    }

    /// "Summaries are off." → the off line; any other reason → "<reason> Fix it in Summaries in Settings."
    static func setupLine(_ reason: String) -> String {
        let reason = reason.trimmingCharacters(in: .whitespaces)
        if reason.isEmpty || reason == "Summaries are off." { return summariesOff }
        return reason + (reason.hasSuffix(".") ? "" : ".") + " Fix it in Summaries in Settings."
    }
}

// MARK: The card's Summarize Now (owner-approved summary-v2, 10/3)

/// One card's summary column around Summarize Now:
/// - `pending`: "Summary pending" (violet) or "What you wrote" over the italic quotes; Summarize Now enabled;
/// - `working`: the label reads "Summarizing…", one slow violet sweep crosses the whole quote block (Reduce Motion: no
///   sweep, muted quotes), Summarize Now and Copy Summary greyed out and unclickable;
/// - `done`: "Summary" in grey, the bullets fade in, Copy Summary enabled, no Summarize Now;
/// - `failed`: back to the pending label and an enabled Summarize Now, with the quiet "Couldn't summarize this one. Try
///   again." line beside it; never the Settings banner.
public enum CardSummaryState: Equatable, Sendable {
    case pending, working, done, failed

    /// The state the card draws from what it reads: a written summary is `done`; a Summarize Now running on a member is
    /// `working`; a member whose last Summarize Now was a one-off failure is `failed`; else `pending`.
    public static func of(bullets: Bool, running: Bool, missed: Bool) -> CardSummaryState {
        if bullets { return .done }
        if running { return .working }
        return missed ? .failed : .pending
    }

    /// The column's label: `header` is the left column's own (`FocusAppCard.leftColumn`); while working, a pending or
    /// "What you wrote" label reads "Summarizing…".
    public func label(_ header: String?) -> String? {
        switch self {
        case .done: return "Summary"
        case .working: return header == "Summary pending" || header == "What you wrote" ? FocusAppCard.summarizingTitle : header
        case .pending, .failed: return header
        }
    }
    /// Labels drawn in the model's violet (the rest are grey).
    public static func violet(_ label: String?) -> Bool { label == "Summary pending" || label == FocusAppCard.summarizingTitle }
    /// Summarize Now can be clicked (it is shown, greyed out, while working; gone once done).
    public var summarizeEnabled: Bool { self == .pending || self == .failed }
    /// Copy Summary can be clicked: only over a summary.
    public var copyEnabled: Bool { self == .done }
    /// The quote block's one sweep runs (Reduce Motion: the quotes are muted instead).
    public var sweeps: Bool { self == .working }
    /// The quiet line beside Summarize Now.
    public var quietLine: String? { self == .failed ? SummarizeNowNotice.quietLine : nil }
}

/// The transitions, as a value (checks drive it; the card derives the same states with `CardSummaryState.of`):
/// pending → working (click) → done (a note was written) or failed (a one-off) → working (click again).
public struct CardSummaryFlow: Equatable, Sendable {
    public private(set) var state: CardSummaryState
    public init(_ state: CardSummaryState = .pending) { self.state = state }
    /// A click on Summarize Now: runs only from pending or failed (greyed out otherwise). true when it ran.
    @discardableResult public mutating func click() -> Bool {
        guard state.summarizeEnabled else { return false }
        state = .working
        return true
    }
    /// The writer returned: a note was written, or not (a one-off).
    public mutating func finish(wrote: Bool) {
        guard state == .working else { return }
        state = wrote ? .done : .failed
    }
}

/// The sweep: one band over the whole quote block, one phase for every line, about 4.5 s a pass, ease-in-out, looping.
public enum SummarySweep {
    public static let period: TimeInterval = 4.5
    /// perf2-1005: the band crosses at most this many times (about 36 s), then rests: nothing in the UI animates forever.
    public static let passes = 8
    /// The band's gradient stops across a strip three times the block's width (summary-v2's `.sweeping`: 35% / 50% / 65%).
    public static let stops: [Double] = [0.35, 0.5, 0.65]
    /// The strip's offset, in block widths, at a phase from 0 to 1: the band enters from the left and leaves on the right.
    public static func offset(phase: Double) -> Double { -2 + 2 * min(max(phase, 0), 1) }
}
