import Foundation
import MemoryCore

// Value snapshots every surface draws from (Focus List, capsule popover, menu bar, settings,
// Recall grouping). Builders are pure: they read an `ActionDay` the caller already loaded and
// never touch a store, so views and renders take these values instead of reading data in `body`.
//
// Honesty rules (plan §3): only what the core returned. A moment's title is its generated title
// unless generic, else its subject. Summary states follow the writer's real limits: nothing is
// "pending" while summaries are off, over 400 actions is "too long", and a partial day is
// "incomplete". Spans are first-to-last observation, never time spent.

/// Whether and where moments get summaries. `downloadProgress` is the writer's real model
/// download progress (0...1) while one is running; nil hides the indicator.
public struct SummaryAvailability: Equatable, Sendable {
    public enum Provider: String, CaseIterable, Sendable { case off, local, cloud }
    public var provider: Provider
    public var busy: Bool
    public var downloadProgress: Double?
    /// fix/day-card: the one summaries state every surface shows (fix/setup-status wires the writer's real phase).
    /// `.off` until it is wired; `shown` then reads it from `provider` and `downloadProgress`.
    public var phase: SummaryPhase
    /// Cloud summaries write only moments that start at or after this time (the moment the key was turned on); earlier
    /// moments are never written, so they are never pending and have no Summarize Now. nil: no cutoff.
    public var writesFrom: Date?
    /// Moments the running writer gave up on for good (a local note that failed its last try): never pending.
    public var skipped: Set<String>
    public var canGenerate: Bool { provider != .off && !busy }
    /// Fixes a failed phase with its one button (fix/setup-status wires it; nil hides the button).
    /// fix/writing-forever: what the running writer has queued and why it waits (the writer publishes it at every look);
    /// nil before it has looked (and on hand-built values), when a pending moment keeps the old "Writing the summary…".
    public var queue: SummaryQueue?
    public init(provider: Provider, busy: Bool, downloadProgress: Double? = nil, phase: SummaryPhase = .off,
                writesFrom: Date? = nil, skipped: Set<String> = [], queue: SummaryQueue? = nil) {
        self.provider = provider; self.busy = busy; self.downloadProgress = downloadProgress; self.phase = phase
        self.writesFrom = writesFrom; self.skipped = skipped; self.queue = queue
    }
    /// The phase the page shows: `phase` once it is wired, else the provider (and a local download in progress).
    public var shown: SummaryPhase {
        if phase != .off { return phase }
        switch provider {
        case .off: return .off
        case .cloud: return .on(.cloud)
        case .local:
            if let p = downloadProgress, p < 1 {
                let total: Int64 = 2_700_000_000
                return .downloading(received: Int64(Double(total) * max(0, p)), total: total)
            }
            return .on(.local)
        }
    }
    /// What a rebuilt Today snapshot would draw from this value: the provider, the gate for Summarize Now, the phase's
    /// kind and its one line. A download's progress ticks change none of it until the line's words change.
    public var drawn: String {
        let kind: String
        switch shown {
        case .off: kind = "off"
        case .downloading: kind = "downloading"
        case .checking: kind = "checking"
        case .on(let mode): kind = "on:" + mode.rawValue
        case .failed(let problem): kind = "failed:" + problem.rawValue
        }
        return [provider.rawValue, canGenerate ? "1" : "0", kind, shown.line ?? "", writesFrom.map { String($0.timeIntervalSince1970) } ?? "",
                skipped.sorted().joined(separator: ",")].joined(separator: "|")
    }
}

/// fix/writing-forever (owner, launch day): a moment without a note said "Writing the summary…" whenever summaries were on,
/// though the writer writes only CLOSED moments it has queued: the moment still going, a moment the rewrite rule leaves
/// alone, or a queue waiting for power said "Writing…" for good. The running writer's last look, by moment ID:
/// - `writing`: queued, running or retrying (the only moments that say "Writing the summary…");
/// - `open`: still going at that look; local provisional notes refresh about every ten minutes after typing pauses,
///   while cloud notes retain their closing gate; `lookedAt` detects activity after that look;
/// - `wait`: why this Mac's model isn't writing in the background now (nil: it may).
public struct SummaryQueue: Equatable, Sendable {
    public var writing: Set<String>
    public var open: Set<String>
    public var lookedAt: Date
    public var wait: SummaryWait?
    public init(writing: Set<String> = [], open: Set<String> = [], lookedAt: Date, wait: SummaryWait? = nil) {
        self.writing = writing; self.open = open; self.lookedAt = lookedAt; self.wait = wait
    }
    public static let writingLine = "Writing the summary\u{2026}"
    /// claude/messages2-1003 (owner 10/3): a moment still going says nothing about the writer's schedule (the old line
    /// about how often local summaries update was jargon): empty, so no summary line is drawn for it.
    public static let openLine = ""
    public static let cloudOpenLine = "Summarized when this moment ends"
    public static let notYetLine = "No summary yet"
    /// The line for a pending moment (summaries on, no note): writing only while it is queued or running.
    public func line(for m: MomentSlice, phase: SummaryPhase? = nil) -> String {
        if writing.contains(m.id) { return wait?.line ?? Self.writingLine }
        if open.contains(m.id) || m.end > lookedAt { return phase == .on(.cloud) ? Self.cloudOpenLine : Self.openLine }
        return Self.notYetLine
    }
}

/// Why this Mac's model waits to write in the background (`ModelPower.allowsBackground`). Summarize Now still runs.
public enum SummaryWait: String, Equatable, Sendable {
    case lowPower, battery, heat
    public var line: String {
        switch self {
        case .lowPower: return "Waiting for Low Power Mode to end"
        case .battery: return "Waiting for power"
        case .heat: return "Waiting for this Mac to cool down"
        }
    }
}

/// The largest moment the note writer summarizes (CanonicalGrounding.maxChunkedActions: over one call's 400 actions it
/// writes segments of about 150 and merges them, claude/ready-1002); bigger moments stay unsummarized. Within it, a scope with more than 40 distinct items is folded per app first, so it waits
/// as capacity only when more than 40 apps (or 16,000 bytes of titles and typed text) remain after folding.
public enum DaydreamSummaryLimit {
    public static let actions = 2000
}

public enum MomentSummaryState: Equatable, Sendable {
    /// A stored note for the current input. `local`: written on this Mac (`local/` generator).
    case ready(generatedAt: Date?, local: Bool)
    /// Summaries are on and this moment can be summarized; no note yet.
    case pending
    case summariesOff
    /// Over `DaydreamSummaryLimit.actions`: the writer never summarizes it.
    case tooLong
    /// Partial day: the core can't assemble the whole moment, so it is never summarized.
    case incomplete
    /// fix/day-card: the running writer will never write it (cloud summaries before their cutoff, or a local note that
    /// failed for good). Drawn like any moment without a note (its name and line by code), never pending.
    case notWritten

    public var isReady: Bool { if case .ready = self { return true }; return false }
}

public struct MomentBullet: Equatable, Sendable {
    public let text: String
    /// Persisted source ownership only; contains no opened source text.
    public let actionIDs: [String]
    /// The writer marked it as interpretation, not observation ("Interpretation is not fact").
    public let interpretation: Bool
    /// The person's own correction, not observed evidence.
    public let correction: Bool
    public init(text: String, interpretation: Bool = false, correction: Bool = false, actionIDs: [String] = []) {
        self.text = text; self.interpretation = interpretation; self.correction = correction; self.actionIDs = actionIDs
    }
}

/// One moment (`ActivityNote`) as the UI draws it.
public struct MomentSlice: Identifiable, Equatable {
    public let id: String, dayKey: String, start: Date, end: Date
    /// `firstBullet` is the stored note's first bullet only (nil without a ready note), so the row
    /// subtitle falls back to the §3 summary-state copy. `bullets` are the note's bullets followed by
    /// the person's corrections (marked `correction`).
    public let title: String, subject: String, firstBullet: String?, bullets: [MomentBullet]
    /// `apps` are display names, alphabetical. Typed-text evidence names its app by bundle ID
    /// (data-audit fact 8); such an entry is replaced by the app's name when one is known and stays
    /// a bundle ID otherwise. `bundles` are real bundle IDs, most member actions first;
    /// `primaryBundle`/`primaryApp` are the moment's main app.
    public let apps: [String], primaryBundle: String?, bundles: [String], sites: [String]
    public let actionIDs: [String], actionCount: Int, clusters: [ClosedRange<Date>]
    public let summary: MomentSummaryState, hasCorrection: Bool
    /// Display name of `primaryBundle` when one is known, else the only app's name, else nil.
    /// Never a bundle ID: nil hides "Open <App>" and "Exclude <App> from Recording…".
    public let primaryApp: String?
    /// fix/day-card: the note shown is the previous one, kept on screen while a newer one is written (stale-while-updating).
    public var stale: Bool = false
    /// State of the current input revision, separate from a previous note kept for display.
    /// nil on hand-built slices; a stale slice then remains pending, never counted as ready.
    public var currentSummary: MomentSummaryState? = nil
    public var currentSummaryState: MomentSummaryState { currentSummary ?? (stale ? .pending : summary) }
    /// fix/day-card: what the moment is by code (its thread's name, its sends, its focused time); nil on hand-built slices.
    public var live: LiveMoment? = nil
    /// fix/prompt-row: the start of what the person typed to the AI app this moment is in, one line
    /// (`MomentPromptText.clean`), opened on this Mac for this window only (`MomentPromptCache`); nil while typing is off,
    /// for a moment with no ask, and on every slice not drawn by the timeline. Never stored, sent or logged.
    public var prompt: String? = nil
    /// Owner 10/6: on X, the prompt is the newest post or reply code confirmed sent, and this is its lead ("Posted",
    /// "Replied"): the row reads "Replied “…” on X." (`MomentSubtitle.promptText`). nil for an AI ask.
    public var promptLead: String? = nil
    /// When that send was typed (ISO 8601), so a card of several X moments leads with the most recent one.
    public var promptAt: String? = nil
    /// fix/summary-fallback: the note shown was written by code, not a model (the moment writer by code, or code's
    /// fallback note when every model answer failed): it never carries the model's mark (`FocusListExpanded.showsModelMark`).
    public var byCode: Bool = false
    /// Lines by code for a moment without a note: its sends, who only ("Texted Q7", "Asked Claude").
    /// Also for a note with nothing left to say (every line filler): the sends by code stand in.
    public var lines: [String] { summary.isReady && bullets.contains(where: { !$0.correction }) ? [] : (live?.sends ?? []) }
    /// Member action count per bundle (F3 `bundleActionCounts`); nil when the note predates it.
    public let bundleActionCounts: [String: Int]?
    /// The note's own time zone identifier (`ActivityNote.timezone`), the zone `dayKey` is keyed in.
    /// Scopes that name this moment's day (forget, summarize, correct) use it; nil (hand-built slices)
    /// falls back to the caller's calendar zone. Contract request W2-2 / wave-1b #6.
    public let timeZoneID: String?
    public var span: TimeInterval { end.timeIntervalSince(start) }

    public init(id: String, dayKey: String, start: Date, end: Date,
                title: String, subject: String, firstBullet: String?, bullets: [MomentBullet],
                apps: [String], primaryBundle: String?, bundles: [String], sites: [String],
                actionIDs: [String], actionCount: Int, clusters: [ClosedRange<Date>],
                summary: MomentSummaryState, hasCorrection: Bool,
                primaryApp: String? = nil, bundleActionCounts: [String: Int]? = nil, timeZoneID: String? = nil,
                stale: Bool = false, live: LiveMoment? = nil) {
        self.stale = stale; self.live = live
        self.id = id; self.dayKey = dayKey; self.start = start; self.end = end
        self.title = title; self.subject = subject; self.firstBullet = firstBullet; self.bullets = bullets
        self.apps = apps; self.primaryBundle = primaryBundle; self.bundles = bundles; self.sites = sites
        self.actionIDs = actionIDs; self.actionCount = actionCount; self.clusters = clusters
        self.summary = summary; self.hasCorrection = hasCorrection
        self.primaryApp = primaryApp; self.bundleActionCounts = bundleActionCounts
        self.timeZoneID = timeZoneID.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The zone this moment's `dayKey` is keyed in: the note's own, else `fallback` (the caller's calendar).
    public func scopeTimeZoneID(fallback: TimeZone) -> String { timeZoneID ?? fallback.identifier }

    /// A real summary to copy: a stored note or the person's correction.
    public var hasSummary: Bool { summary.isReady || hasCorrection }

    /// A companion to retained bullets, never a replacement for them. Queue membership proves an update is queued,
    /// not that the model is currently writing. Without a queue look, do not invent that progress.
    /// claude/messages2-1003 (owner 10/3): a previous summary just shows its bullets, with at most this quiet note while
    /// a rewrite is due (the moment is pending and summaries are on); never a "previous summary" label and the writer's
    /// schedule. nil otherwise.
    public func previousSummaryStatus(phase: SummaryPhase?, queue: SummaryQueue?) -> String? {
        guard stale, case .pending = currentSummaryState else { return nil }
        switch phase {
        case .off?, .failed?: return nil
        default: return Self.updatingLine
        }
    }
    public static let updatingLine = "Updating\u{2026}"

    /// Builds the slice and applies the §3 gating.
    /// - `nameToBundle`: display name → bundle, e.g. from the day's loaded actions (`TodaySnapshot.make` adds them).
    /// - `pageActions`: the day's loaded action page: app names for bundles, and the primary app when
    ///   the note has no bundles.
    /// - `bundleNames`: bundle → display name catalog (installed apps, e.g. `LocalApp.catalog()` or
    ///   NSWorkspace), used when the loaded actions give a bundle no name.
    public static func make(note: ActivityNote, dayPartial: Bool, summaries: SummaryAvailability, calendar: Calendar,
                            nameToBundle: [String: String] = [:], pageActions: [CanonicalAction] = [],
                            bundleNames: [String: String] = [:], live: LiveMoment? = nil) -> MomentSlice {
        let directory = DaydreamAppDirectory(actions: pageActions, notes: [note], overrides: nameToBundle, catalog: bundleNames)
        return make(note: note, dayPartial: dayPartial, summaries: summaries, pageActions: pageActions, directory: directory, live: live)
    }

    /// Title, in order (fix/day-card): the note's title, the previous note's (while a newer one is written), the moment's
    /// name by code (`LiveMoment.label`: "Texts with Q7", "PR #418: Weekly summaries export"), the cleaned window title.
    /// Never filler, never a raw title. A moment the writer will never write is drawn like any moment without a note.
    static func make(note: ActivityNote, dayPartial: Bool, summaries: SummaryAvailability,
                     pageActions: [CanonicalAction], directory day: DaydreamAppDirectory, live: LiveMoment? = nil) -> MomentSlice {
        let clusters = note.clusters.compactMap { cluster -> ClosedRange<Date>? in
            guard let a = timestamp(cluster.firstObservedAt), let b = timestamp(cluster.lastObservedAt) else { return nil }
            return min(a, b)...max(a, b)
        }
        let dayStart = (try? DayScope.interval(day: note.day, timezone: note.timezone).start) ?? Date(timeIntervalSince1970: 0)
        let start = timestamp(note.start) ?? clusters.first?.lowerBound ?? dayStart
        let end = max(start, timestamp(note.end) ?? clusters.last?.upperBound ?? start)

        let ready = note.status == "ready" ? note.generated : nil
        // Stale-while-updating: the previous note stays until the newer one is stored (never one a Forget took: core
        // deletes every note citing a forgotten action, and keeps a previous note only while the moment holds all it cites).
        let generated = ready ?? note.previous
        let stale = ready == nil && generated != nil
        // Current status drives counts and the retained-note label; display status keeps the previous bullets visible.
        let currentSummary: MomentSummaryState
        if let ready {
            currentSummary = .ready(generatedAt: timestamp(ready.generatedAt), local: DaydreamNotes.isLocal(ready))
        } else if dayPartial || note.status == "incomplete" {
            currentSummary = .incomplete
        } else if note.actionIDs.count > DaydreamSummaryLimit.actions {
            currentSummary = .tooLong
        } else if summaries.provider == .off {
            currentSummary = .summariesOff
        } else if (summaries.skipped.contains(note.id) && summaries.queue?.writing.contains(note.id) != true)
                    || (summaries.provider == .cloud && summaries.writesFrom.map { start < $0 } == true) {
            currentSummary = .notWritten
        } else {
            currentSummary = .pending
        }
        let summary: MomentSummaryState = generated.map {
            .ready(generatedAt: timestamp($0.generatedAt), local: DaydreamNotes.isLocal($0))
        } ?? currentSummary

        let corrections = DaydreamNotes.corrections(note.corrections, kind: "activity", preferring: note.id)
        let directory = day.adding(note)
        // Typed-text evidence names its app by bundle ID: show the app's name when one is known.
        func label(_ name: String) -> String { directory.displayName(forApp: name) ?? name }
        let subject = note.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawApps = note.apps.filter { !$0.isEmpty }, sites = note.sites.filter { !$0.isEmpty }
        let mainApp = rawApps.first.map(label) ?? ""
        let cleanedSubject = subject.isEmpty ? "" : TitleClean.clean(label(subject), app: mainApp, site: sites.first ?? "")
        let codeName = live.map(\.label).flatMap { $0.isEmpty ? nil : $0 }
        let fallbackTitle = codeName ?? (!cleanedSubject.isEmpty ? cleanedSubject : sites.first.map { TitleClean.clean($0, site: $0) } ?? (mainApp.isEmpty ? "Away" : mainApp))
        // sat5: one name per app ("Notes", never "Notes app"), and no line that only names the app ("Worked in Notes."):
        // such a title gives way to the window title, and such a bullet is left out.
        let appNames = DaydreamNotes.unique(rawApps.map(label) + rawApps)
        // fix/summary-fallback: code's fallback note (every model answer failed) shows its own place-only lines; the filler
        // rule still drops every other line that names only an app or place.
        let codeFallback = generated.map { CodeFallbackNote.isFallback($0.output) } ?? false
        let generatedBullets = DaydreamNotes.sendsFirst((generated.map(DaydreamNotes.bullets) ?? []).compactMap { bullet -> MomentBullet? in
            let text = DaydreamNotes.tidy(bullet.text, apps: appNames)
            let fallbackLine = codeFallback && CodeFallbackNote.isFallbackLine(bullet.text)
            // claude/dayeval-1005: never "draft" on screen (`DisplayWords.undraft`), after the filler rules read the stored words.
            return DaydreamNotes.isFiller(text, apps: appNames) && !fallbackLine ? nil
                : MomentBullet(text: DisplayWords.undraft(text), interpretation: bullet.interpretation, actionIDs: bullet.actionIDs)
        })
        // claude/summary-1003 (owner): code's place-only lines only when no line says more; each line once.
        let bullets = SummaryLines.tidy(DaydreamNotes.distinctBullets(generatedBullets), cap: .max) { $0.text } + corrections
        let generatedTitle = DaydreamNotes.title(generated, generic: "Activity note")
            .map { DisplayWords.undraft(TitleClean.clean(DaydreamNotes.tidy($0, apps: appNames), app: mainApp, site: sites.first ?? "")) }

        let members = Set(note.actionIDs)
        let memberActions = pageActions.filter { members.contains($0.id) }
        let bundles: [String]
        if let known = note.bundles, !known.isEmpty {
            bundles = known
        } else {
            // No F3 bundles (older JSON) or none recorded: count the loaded member actions, then map names.
            let counts = Dictionary(memberActions.map(\.bundle).filter { !$0.isEmpty }.map { ($0, 1) }, uniquingKeysWith: +)
            let counted = counts.keys.sorted { (-counts[$0]!, $0) < (-counts[$1]!, $1) }
            let named = rawApps.compactMap { directory.bundle(forApp: $0) }.filter { !counts.keys.contains($0) }
            bundles = DaydreamNotes.unique(counted + named)
        }
        let primaryBundle = bundles.first
        // A name the moment itself pairs with the bundle, else any known name for it. Never the bundle ID.
        let primaryApp = primaryBundle.flatMap { bundle in
            rawApps.first { directory.pairedBundle(forName: $0) == bundle } ?? directory.name(forBundle: bundle)
        } ?? (rawApps.count == 1 ? directory.displayName(forApp: rawApps[0]) : nil)

        var slice = MomentSlice(id: note.id, dayKey: note.day, start: start, end: end,
                           title: generatedTitle.flatMap { DaydreamNotes.isFiller($0, apps: appNames) || $0.isEmpty ? nil : $0 } ?? fallbackTitle,
                           subject: note.subject, firstBullet: generatedBullets.first?.text, bullets: bullets,
                           apps: DaydreamNotes.unique(rawApps.map(label)).sorted(), primaryBundle: primaryBundle,
                           bundles: bundles, sites: sites,
                           actionIDs: note.actionIDs, actionCount: note.actionIDs.count, clusters: clusters,
                           summary: summary, hasCorrection: !corrections.isEmpty,
                           primaryApp: primaryApp, bundleActionCounts: note.bundleActionCounts,
                           timeZoneID: note.timezone, stale: stale, live: live)
        slice.currentSummary = currentSummary
        slice.byCode = generated?.output.generator.hasPrefix("code/") ?? false
        return slice
    }

    /// Only idle rows (no app, no name): not a row. Its time folds into the gap between the rows around it.
    static func idleOnly(_ note: ActivityNote, live: LiveMoment?) -> Bool {
        if let live { return live.idle }
        return note.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && note.apps.allSatisfy(\.isEmpty)
    }
}

/// An app's share of a day. `actions` is set only when F3 bundle counts cover every action of
/// the day (ranked by actions); otherwise tallies count moment membership and `actions` is nil.
public struct AppTally: Identifiable, Equatable, Sendable {
    public let id: String
    public let bundle: String?
    /// The app's display name. When `nameResolved` is false no name is known and this is only
    /// the bundle ID: show `DaydreamMonogram` and don't present it as a name.
    public let name: String
    public let moments: Int
    public let actions: Int?
    public let nameResolved: Bool
    public init(id: String, bundle: String?, name: String, moments: Int, actions: Int?, nameResolved: Bool = true) {
        self.id = id; self.bundle = bundle; self.name = name; self.moments = moments; self.actions = actions
        self.nameResolved = nameResolved
    }
}

public struct TodaySnapshot: Equatable {
    public let dayKey: String, loadedAt: Date
    /// `momentCount` is exact only when `!partial`; `actionCount` is a lower bound when `!countComplete`.
    public let momentCount: Int, actionCount: Int, countComplete: Bool, partial: Bool
    public let moments: [MomentSlice]                   // chronological
    /// Ready, non-generic day note only. Generated bullets come only with a headline;
    /// the person's corrections to the day are always included (marked `correction`).
    public let headline: String?, headlineBullets: [MomentBullet], headlineGeneratedAt: Date?, headlineLocal: Bool?
    public let firstObserved: Date?, lastObserved: Date?
    public let topApps: [AppTally]                      // by actions (F3) else moments; max 7
    public let latest: MomentSlice?
    public let summaries: SummaryAvailability
    /// `pendingCount` counts only moments that can still be summarized; `tooLongCount` is separate.
    public let readyCount: Int, pendingCount: Int, tooLongCount: Int
    /// Distinct apps across the day (names resolved to bundles where known, so a typed-text
    /// bundle ID and its display name count once).
    public let appCount: Int
    /// summaries/v3 levels: the day note, blocks and week note, from the same day read (`ActionDay.levels`).
    public var levels: DayLevelSlice? = nil
    /// fix/day-card: the day's threads by code (`DayLevels.live`): the headline and lines while no day note fits.
    public var live: LiveDay? = nil
    /// claude/day-review-1003: the day review's facts, clauses and (in the app) quotes (`DayLevels.review`).
    public var review: DayReviewFacts? = nil

    public init(dayKey: String, loadedAt: Date, momentCount: Int, actionCount: Int, countComplete: Bool, partial: Bool,
                moments: [MomentSlice], headline: String?, headlineBullets: [MomentBullet], headlineGeneratedAt: Date?,
                headlineLocal: Bool?, firstObserved: Date?, lastObserved: Date?, topApps: [AppTally], latest: MomentSlice?,
                summaries: SummaryAvailability, readyCount: Int, pendingCount: Int, tooLongCount: Int, appCount: Int) {
        self.dayKey = dayKey; self.loadedAt = loadedAt
        self.momentCount = momentCount; self.actionCount = actionCount; self.countComplete = countComplete; self.partial = partial
        self.moments = moments
        self.headline = headline; self.headlineBullets = headlineBullets; self.headlineGeneratedAt = headlineGeneratedAt; self.headlineLocal = headlineLocal
        self.firstObserved = firstObserved; self.lastObserved = lastObserved
        self.topApps = topApps; self.latest = latest; self.summaries = summaries
        self.readyCount = readyCount; self.pendingCount = pendingCount; self.tooLongCount = tooLongCount
        self.appCount = appCount
    }

    /// True when `topApps` are ranked by action counts (F3) rather than moment membership.
    public var appsRankedByActions: Bool { topApps.first?.actions != nil }

    /// fix/prompt-row: the same snapshot with each moment's prompt from `prompts` (moment ID → one line). No rebuild:
    /// only the moments are copied, and a snapshot whose prompts already match comes back as it is.
    public func withPrompts(_ prompts: [String: String]) -> TodaySnapshot {
        // Owner 10/6: a confirmed X send's value carries its lead (`MomentPromptText.sent`); split here.
        let split = prompts.mapValues(MomentPromptText.split)
        func differs(_ m: MomentSlice) -> Bool { m.prompt != split[m.id]?.words || m.promptLead != split[m.id]?.lead || m.promptAt != split[m.id]?.at }
        guard moments.contains(where: differs) || (latest.map(differs) ?? false) else { return self }
        func apply(_ m: MomentSlice) -> MomentSlice { var copy = m; copy.prompt = split[m.id]?.words; copy.promptLead = split[m.id]?.lead
            copy.promptAt = split[m.id]?.at; return copy }
        var next = TodaySnapshot(dayKey: dayKey, loadedAt: loadedAt, momentCount: momentCount, actionCount: actionCount,
                                 countComplete: countComplete, partial: partial, moments: moments.map(apply), headline: headline,
                                 headlineBullets: headlineBullets, headlineGeneratedAt: headlineGeneratedAt, headlineLocal: headlineLocal,
                                 firstObserved: firstObserved, lastObserved: lastObserved, topApps: topApps, latest: latest.map(apply),
                                 summaries: summaries, readyCount: readyCount, pendingCount: pendingCount, tooLongCount: tooLongCount,
                                 appCount: appCount)
        next.levels = levels
        next.live = live
        next.review = review
        return next
    }

    /// - `nameToBundle`: extra display name → bundle pairs; the day's loaded actions supply the rest.
    /// - `bundleNames`: bundle → display name catalog (installed apps), used when the loaded actions
    ///   give a bundle no name.
    public static func make(day: ActionDay, summaries: SummaryAvailability, calendar: Calendar, now: Date,
                            nameToBundle: [String: String] = [:], bundleNames: [String: String] = [:]) -> TodaySnapshot {
        let directory = DaydreamAppDirectory(actions: day.actions.actions, notes: day.activities,
                                             overrides: nameToBundle, catalog: bundleNames)
        let live = day.levels?.live
        let moments = day.activities
            .filter { !MomentSlice.idleOnly($0, live: live?.moments[$0.id]) }
            .map { MomentSlice.make(note: $0, dayPartial: day.partial, summaries: summaries,
                                    pageActions: day.actions.actions, directory: directory, live: live?.moments[$0.id]) }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }

        // Stale-while-updating: the previous day note while a newer one is written.
        let generated = day.summary.status == "ready" ? day.summary.generated : day.summary.previous
        let headline = DaydreamNotes.title(generated, generic: "Day summary").map(DisplayWords.undraft)
        let dayCorrections = DaydreamNotes.corrections(day.summary.corrections, kind: "day", preferring: nil)
        let bullets = (headline == nil ? [] : (generated.map(DaydreamNotes.bullets) ?? []).map {
            MomentBullet(text: DisplayWords.undraft($0.text), interpretation: $0.interpretation, correction: $0.correction, actionIDs: $0.actionIDs) }) + dayCorrections

        var ready = 0, pending = 0, tooLong = 0
        for moment in moments {
            switch moment.currentSummaryState {
            case .ready: ready += 1
            case .pending: pending += 1
            case .tooLong: tooLong += 1
            case .summariesOff, .incomplete, .notWritten: break
            }
        }
        let latest = moments.max { ($0.end, $0.start, $0.id) < ($1.end, $1.start, $1.id) }
        var snapshot = TodaySnapshot(dayKey: day.summary.day, loadedAt: now,
                             momentCount: day.activities.count, actionCount: day.summary.actionCount,
                             countComplete: day.summary.countIsComplete, partial: day.partial,
                             moments: moments, headline: headline, headlineBullets: bullets,
                             headlineGeneratedAt: headline == nil ? nil : generated.flatMap { timestamp($0.generatedAt) },
                             headlineLocal: headline == nil ? nil : generated.map(DaydreamNotes.isLocal),
                             firstObserved: moments.map(\.start).min(), lastObserved: moments.map(\.end).max(),
                             topApps: Array(DaydreamNotes.tally(day.activities, directory: directory).prefix(7)), latest: latest,
                             summaries: summaries, readyCount: ready, pendingCount: pending, tooLongCount: tooLong,
                             appCount: DaydreamNotes.appCount(day.activities, directory: directory))
        snapshot.levels = DayLevelSlice.make(day.levels, calendar: calendar)
        snapshot.live = live
        snapshot.review = day.levels?.review
        return snapshot
    }
}

/// A cached day's totals (day chips, week bars, app-usage bars).
public struct DayDigest: Equatable {
    public let dayKey: String, date: Date, momentCount: Int, actionCount: Int
    /// false when the day is partial: counts are lower bounds.
    public let complete: Bool
    /// Every app of the day, ranked as `TodaySnapshot.topApps` (by actions with F3, else moments).
    public let apps: [AppTally]
    public var topApp: AppTally? { apps.first }

    public init(dayKey: String, date: Date, momentCount: Int, actionCount: Int, complete: Bool, apps: [AppTally]) {
        self.dayKey = dayKey; self.date = date; self.momentCount = momentCount; self.actionCount = actionCount
        self.complete = complete; self.apps = apps
    }

    /// `nameToBundle` and `bundleNames` as in `TodaySnapshot.make`.
    public static func make(day: ActionDay, calendar: Calendar, nameToBundle: [String: String] = [:],
                            bundleNames: [String: String] = [:]) -> DayDigest {
        let directory = DaydreamAppDirectory(actions: day.actions.actions, notes: day.activities,
                                             overrides: nameToBundle, catalog: bundleNames)
        let date = (try? DayScope.interval(day: day.summary.day, timezone: day.summary.timezone).start)
            ?? timestamp(day.summary.start) ?? calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        return DayDigest(dayKey: day.summary.day, date: date, momentCount: day.activities.count,
                         actionCount: day.summary.actionCount, complete: day.summary.countIsComplete && !day.partial,
                         apps: DaydreamNotes.tally(day.activities, directory: directory))
    }
}

/// Bundle IDs. Always private = `PrivacySettings.sensitiveApps` (minus DayDream itself) that are
/// installed; excluded by you = `blockedApps` minus the always-private set.
public struct ExclusionSummary: Equatable, Sendable {
    public var alwaysPrivate: [String]
    public var excludedByYou: [String]
    public init(alwaysPrivate: [String], excludedByYou: [String]) {
        self.alwaysPrivate = alwaysPrivate; self.excludedByYou = excludedByYou
    }

    /// Builds the summary from saved `blockedApps`. `installed` answers whether a bundle is on this Mac
    /// (the app passes an NSWorkspace lookup; nothing here reads the system).
    public static func make(blockedApps: [String], installed: (String) -> Bool) -> ExclusionSummary {
        let sensitive = Set(PrivacySettings.sensitiveApps)
        return ExclusionSummary(
            alwaysPrivate: PrivacySettings.sensitiveApps.filter { !DaydreamNotes.ownBundles.contains($0) && installed($0) },
            excludedByYou: DaydreamNotes.unique(blockedApps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !sensitive.contains($0) }))
    }

    /// A bundle the person can't exclude: built-in private apps and DayDream itself.
    public func isAlwaysPrivate(_ bundle: String) -> Bool {
        alwaysPrivate.contains(bundle) || PrivacySettings.sensitiveApps.contains(bundle)
    }
    public func isExcluded(_ bundle: String) -> Bool { isAlwaysPrivate(bundle) || excludedByYou.contains(bundle) }
}

/// Last permission reads (`AXIsProcessTrusted`, `CGPreflightListenEventAccess`, never a prompt). nil = not read.
public struct PermissionSnapshot: Equatable, Sendable {
    public var accessibility: Bool?
    public var inputMonitoring: Bool?
    public init(accessibility: Bool? = nil, inputMonitoring: Bool? = nil) {
        self.accessibility = accessibility; self.inputMonitoring = inputMonitoring
    }
    /// Kinds read as not granted. Unknown reads are not included.
    public var missing: Set<PermissionKind> {
        var missing = Set<PermissionKind>()
        if accessibility == false { missing.insert(.accessibility) }
        if inputMonitoring == false { missing.insert(.inputMonitoring) }
        return missing
    }
    /// true only when both reads say granted; nil while either is unknown.
    public var allGranted: Bool? {
        guard let accessibility, let inputMonitoring else { return nil }
        return accessibility && inputMonitoring
    }
}

/// Shared rules for notes, corrections and app tallies.
enum DaydreamNotes {
    /// DayDream itself, under its current and its pre-rename bundle identifier.
    static let ownBundles = DaydreamIdentity.ownBundleIDs

    /// The generated title unless it is empty or the writer's generic fallback.
    static func title(_ note: GeneratedNote?, generic: String) -> String? {
        guard let title = note?.output.title.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let genericTitles: Set<String> = ["activity note", "day summary", generic.lowercased()]
        return genericTitles.contains(title.lowercased()) ? nil : title
    }
    /// fix/sx-all round 2: the one shared filler list (MemoryCore `NoteFiller`, the writer's own rule): a line that names
    /// no one and nothing ("Had ChatGPT open and in use.", "Wrote a message in Messages", "Texted.", "Untitled moment") is
    /// left out; "Wrote an email to Dana about the offsite" never is.
    static func isFiller(_ text: String, apps: [String]) -> Bool { NoteFiller.isFiller(text, apps: apps) }
    /// Sends and conversations first (a line that texted, emailed, messaged, asked or posted), then the rest in order.
    static func sendsFirst(_ bullets: [MomentBullet]) -> [MomentBullet] {
        let leads = LevelWords.sentLeads
        let isSend: (MomentBullet) -> Bool = { b in leads.contains { b.text.hasPrefix($0 + " ") } }
        return bullets.filter(isSend) + bullets.filter { !isSend($0) }
    }
    /// App names as the moment names them: "the Notes app" and "Notes app" become "Notes".
    static func tidy(_ text: String, apps: [String]) -> String {
        var out = text
        for app in apps where !app.isEmpty {
            let name = NSRegularExpression.escapedPattern(for: app), with = NSRegularExpression.escapedTemplate(for: app)
            out = out.replacingOccurrences(of: "(?i)\\bthe " + name + " app\\b", with: with, options: .regularExpression)
            out = out.replacingOccurrences(of: "(?i)\\b" + name + " app\\b", with: with, options: .regularExpression)
        }
        return out
    }
    /// Written on this Mac: by the local model, or by code ("code/…", no model at all). Only the cloud key's notes aren't.
    static func isLocal(_ note: GeneratedNote) -> Bool { note.output.generator.hasPrefix("local/") || note.output.generator.hasPrefix("code/") }
    static func bullets(_ note: GeneratedNote) -> [MomentBullet] {
        distinctBullets(note.output.bullets.compactMap { bullet in
            let text = bullet.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : MomentBullet(text: text, interpretation: bullet.assertion == "interpretation", actionIDs: bullet.actionIDs)
        })
    }
    /// Display identical generated prose once while retaining every cited action.
    /// An interpretation marker survives if any duplicate requires it. Corrections
    /// remain separately attributed to their author and saved notes are untouched.
    static func distinctBullets(_ bullets: [MomentBullet]) -> [MomentBullet] {
        var result: [MomentBullet] = []
        var positions: [String: Int] = [:]
        for bullet in bullets {
            let key = (bullet.correction ? "correction:" : "generated:")
                + bullet.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if let index = positions[key], result[index].correction == bullet.correction {
                let first = result[index]
                result[index] = MomentBullet(text: first.text,
                    interpretation: first.interpretation || bullet.interpretation,
                    correction: first.correction, actionIDs: unique(first.actionIDs + bullet.actionIDs))
            } else {
                positions[key] = result.count
                result.append(bullet)
            }
        }
        return result
    }
    /// Latest corrections of one target kind, the scope's own target first.
    static func corrections(_ list: [UserCorrection]?, kind: String, preferring target: String?) -> [MomentBullet] {
        (list ?? []).filter { $0.targetKind == kind }
            .sorted { ($0.targetID == target ? 0 : 1, $1.authoredAt) < ($1.targetID == target ? 0 : 1, $0.authoredAt) }
            .compactMap { correction in
                guard let text = correction.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return MomentBullet(text: text, correction: true)
            }
    }
    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
    /// Distinct apps, an app's name and its bundle ID counting once.
    static func appCount(_ notes: [ActivityNote], directory: DaydreamAppDirectory) -> Int {
        Set(notes.flatMap { note -> [String] in
            let names = directory.adding(note)
            return note.apps.filter { !$0.isEmpty }.map { names.bundle(forApp: $0) ?? $0 }
        }).count
    }
    /// Ranks by member actions per bundle when F3 counts cover every action of every note, so no
    /// app drops out (imported evidence has no bundle); otherwise by moment membership per app.
    /// The two units never mix.
    static func tally(_ notes: [ActivityNote], directory: DaydreamAppDirectory) -> [AppTally] {
        let byActions = notes.contains { !($0.bundleActionCounts ?? [:]).isEmpty } && notes.allSatisfy { note in
            guard let counts = note.bundleActionCounts else { return false }
            return counts.values.reduce(0, +) == note.actionIDs.count
        }
        if byActions {
            var actions = [String: Int](), moments = [String: Int]()
            for note in notes {
                for (bundle, count) in note.bundleActionCounts ?? [:] where count > 0 {
                    actions[bundle, default: 0] += count; moments[bundle, default: 0] += 1
                }
            }
            let known = notes.reduce(directory) { $0.adding($1) }
            return actions.keys.map { bundle in
                let name = known.name(forBundle: bundle)
                return AppTally(id: bundle, bundle: bundle, name: name ?? bundle, moments: moments[bundle] ?? 0,
                                actions: actions[bundle], nameResolved: name != nil)
            }.sorted { (-($0.actions ?? 0), -$0.moments, $0.name, $0.id) < (-($1.actions ?? 0), -$1.moments, $1.name, $1.id) }
        }
        var moments = [String: Int](), label = [String: String](), bundleOf = [String: String]()
        var known = directory
        for note in notes {
            // An app's name and its bundle ID (typed-text evidence) are one app; a real name labels it.
            let names = directory.adding(note)
            known = known.adding(note)
            let apps = note.apps.filter { !$0.isEmpty }
            for key in Set(apps.map { names.bundle(forApp: $0) ?? $0 }) { moments[key, default: 0] += 1 }
            for app in apps {
                let bundle = names.bundle(forApp: app), key = bundle ?? app
                if let bundle { bundleOf[key] = bundle }
                if !names.isBundleID(app), label[key].map({ app < $0 }) ?? true { label[key] = app }
            }
        }
        return moments.keys.map { key -> AppTally in
            let bundle = bundleOf[key]
            let name = label[key] ?? bundle.flatMap(known.name(forBundle:))
            return AppTally(id: bundle ?? "name:" + key, bundle: bundle, name: name ?? key, moments: moments[key] ?? 0,
                            actions: nil, nameResolved: name != nil)
        }.sorted { (-$0.moments, $0.name, $0.id) < (-$1.moments, $1.name, $1.id) }
    }
}

/// App names and bundle IDs known for a day or a moment. Typed-text evidence stores the bundle ID
/// as the app name (data-audit fact 8), so a name that is a bundle ID is never used as a display
/// name: it resolves to a name the loaded actions pair with that bundle, else to the caller's
/// catalog (installed apps), else stays unresolved.
struct DaydreamAppDirectory {
    /// Display name → bundle ID, real names only.
    private var toBundle: [String: String]
    /// Bundle ID → the alphabetically first real name paired with it.
    private var fromBundle: [String: String]
    /// Every bundle ID seen in the actions, notes and pairs.
    private var bundleIDs: Set<String>
    /// Bundle ID → display name from the caller.
    private let catalog: [String: String]

    init(actions: [CanonicalAction], notes: [ActivityNote], overrides: [String: String], catalog: [String: String]) {
        var ids = Set(actions.map(\.bundle).filter { !$0.isEmpty })
        for note in notes {
            ids.formUnion((note.bundles ?? []).filter { !$0.isEmpty })
            ids.formUnion((note.bundleActionCounts ?? [:]).keys.filter { !$0.isEmpty })
        }
        var pairs = [String: String]()
        for action in actions where !action.app.isEmpty && !action.bundle.isEmpty && pairs[action.app] == nil {
            pairs[action.app] = action.bundle
        }
        for (name, bundle) in overrides where !name.isEmpty && !bundle.isEmpty { pairs[name] = bundle }
        ids.formUnion(pairs.values)
        // A "name" that is itself a bundle ID (typed-text evidence) pairs with nothing.
        toBundle = pairs.filter { $0.key != $0.value && !ids.contains($0.key) && !Self.looksLikeBundleID($0.key) }
        fromBundle = [:]
        bundleIDs = ids
        self.catalog = catalog.filter { name in
            let trimmed = name.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed != name.key
        }
        for (name, bundle) in toBundle where fromBundle[bundle].map({ name < $0 }) ?? true { fromBundle[bundle] = name }
    }

    /// Reverse-DNS with at least three parts and no spaces ("com.apple.Notes"): an app name never
    /// looks like this, so such a name is a bundle ID even when no action or note lists it.
    static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        }
    }

    func isBundleID(_ name: String) -> Bool { bundleIDs.contains(name) || Self.looksLikeBundleID(name) }
    /// The bundle a real display name is paired with.
    func pairedBundle(forName name: String) -> String? { toBundle[name] }
    /// The bundle for an app entry: its paired bundle, or the entry itself when it is a bundle ID.
    func bundle(forApp app: String) -> String? { toBundle[app] ?? (isBundleID(app) ? app : nil) }
    /// A display name for a bundle ID, or nil when none is known. Never the bundle ID itself.
    func name(forBundle bundle: String) -> String? { fromBundle[bundle] ?? catalog[bundle] }
    /// A display name for an app entry: the entry itself unless it is a bundle ID.
    func displayName(forApp app: String) -> String? { isBundleID(app) ? name(forBundle: app) : app }

    /// Adds the one sure pairing a note gives on its own: a single app name with a single bundle.
    func adding(_ note: ActivityNote) -> DaydreamAppDirectory {
        let apps = note.apps.filter { !$0.isEmpty }
        guard apps.count == 1, let bundles = note.bundles, bundles.count == 1, !bundles[0].isEmpty,
              toBundle[apps[0]] == nil, apps[0] != bundles[0], !isBundleID(apps[0]) else { return self }
        var copy = self
        copy.toBundle[apps[0]] = bundles[0]
        copy.bundleIDs.insert(bundles[0])
        if copy.fromBundle[bundles[0]].map({ apps[0] < $0 }) ?? true { copy.fromBundle[bundles[0]] = apps[0] }
        return copy
    }
}
