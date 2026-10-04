import SwiftUI
import MemoryCore

// Forget a time range (Preview 4, owner: "you should be able to delete a time range"). One sheet, opened from
// Moment ▸ Forget a Time Range…, a Today row's context menu and Settings ▸ Advanced: three quick choices and a custom
// start–end, the question with the count, and a red Forget. The preview and the commit run off the main thread
// (`ActivityBrowser.previewRangeDelete` / `confirmRangeDelete`); the commit reads the range again and refuses if it
// changed. The range is half open (start <= t < end, MemoryActionScope): moments that cross an edge keep what's
// outside it.

/// The quick choices, then Custom.
public enum ForgetRangeChoice: String, CaseIterable, Identifiable, Sendable {
    case last15, lastHour, today, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .last15: return "Last 15 minutes"
        case .lastHour: return "Last hour"
        case .today: return "Today"
        case .custom: return "Custom"
        }
    }
    /// The range this choice names at `now`: a quick choice ends now; Today starts at local midnight.
    public func range(now: Date, calendar: Calendar, customStart: Date, customEnd: Date) -> DateInterval? {
        switch self {
        case .last15: return DateInterval(start: now.addingTimeInterval(-15 * 60), end: now)
        case .lastHour: return DateInterval(start: now.addingTimeInterval(-3600), end: now)
        case .today:
            let start = calendar.startOfDay(for: now)
            return start < now ? DateInterval(start: start, end: now) : nil
        case .custom: return customStart < customEnd ? DateInterval(start: customStart, end: customEnd) : nil
        }
    }
}

public enum ForgetRangeText {
    public static let title = "Forget a Time Range"
    public static let menuTitle = "Forget a Time Range…"
    public static let confirm = "Forget"
    public static let badRange = "Choose an end after the start."
    public static let unavailable = "Preview unavailable. Nothing deleted."
    public static let changed = "Something was saved in the range meanwhile. Review it again."
    public static let failed = "Nothing confirmed deleted. Review the range again."

    /// "2:05 PM to 3:05 PM" on today; "Sep 26, 11:30 PM to Sep 27, 12:30 AM" otherwise.
    public static func span(_ start: Date, _ end: Date, timeZone: TimeZone, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let today = calendar.isDate(start, inSameDayAs: now) && calendar.isDate(end.addingTimeInterval(-0.001), inSameDayAs: now)
        func text(_ d: Date) -> String {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone
            f.dateFormat = today ? "h:mm a" : "MMM d, h:mm a"
            return f.string(from: d)
        }
        return text(start) + " to " + text(end)
    }
    /// "Forget 12 moments from 2:05 PM to 3:05 PM?" (actions when no moment holds them, or the range is too long to
    /// count moments in).
    public static func question(_ preview: DeletionPreview, start: Date, end: Date, timeZone: TimeZone, now: Date) -> String {
        let n: String
        if preview.actionCount == 0, let summaries = preview.summaryCount, summaries > 0 {
            // Only frozen summaries of expired days are left in the range.
            n = DaydreamFormat.count(summaries) + (summaries == 1 ? " written summary" : " written summaries")
        } else if let moments = preview.momentCount, moments > 0 { n = DaydreamFormat.count(moments) + (moments == 1 ? " moment" : " moments") }
        else { n = DaydreamFormat.count(preview.actionCount) + (preview.actionCount == 1 ? " action" : " actions") }
        return "Forget \(n) from \(span(start, end, timeZone: timeZone, now: now))?"
    }
    public static func nothing(start: Date, end: Date, timeZone: TimeZone, now: Date) -> String {
        "Nothing saved from \(span(start, end, timeZone: timeZone, now: now))."
    }
}

@MainActor
public final class ForgetRangeModel: ObservableObject {
    public enum Phase: Equatable {
        case idle, loading, empty
        case ready(DeletionPreview)
        case failed(String)
        case forgetting, done
        public static func == (a: Phase, b: Phase) -> Bool {
            switch (a, b) {
            case (.idle, .idle), (.loading, .loading), (.empty, .empty), (.forgetting, .forgetting), (.done, .done): return true
            case let (.ready(x), .ready(y)): return x.id == y.id
            case let (.failed(x), .failed(y)): return x == y
            default: return false
            }
        }
    }
    @Published public var choice: ForgetRangeChoice { didSet { if choice != oldValue { refresh() } } }
    @Published public var customStart: Date { didSet { if choice == .custom && customStart != oldValue { refresh() } } }
    @Published public var customEnd: Date { didSet { if choice == .custom && customEnd != oldValue { refresh() } } }
    @Published public private(set) var phase: Phase = .idle
    /// The range the current phase is about.
    @Published public private(set) var range: DateInterval?
    /// A line over the question after a refused commit.
    @Published public private(set) var notice: String?

    public let calendar: Calendar
    private let now: () -> Date
    private let prepare: (MemoryActionScope) async throws -> DeletionPreview
    private let commit: (String) async throws -> Void
    private let release: (String) -> Void
    private var generation = 0
    private var retried = false

    public init(calendar: Calendar, now: @escaping () -> Date = Date.init, choice: ForgetRangeChoice = .last15,
                prepare: @escaping (MemoryActionScope) async throws -> DeletionPreview,
                commit: @escaping (String) async throws -> Void,
                release: @escaping (String) -> Void) {
        self.calendar = calendar; self.now = now; self.prepare = prepare; self.commit = commit; self.release = release
        let at = now()
        self.choice = choice
        customEnd = at; customStart = at.addingTimeInterval(-3600)
    }

    /// The sheet's model, wired to the browser's range closures (a preview that can't run says so).
    public convenience init(browser: ActivityBrowser, choice: ForgetRangeChoice = .last15) {
        let cancel = browser.cancelCanonicalDelete
        self.init(calendar: browser.calendar, now: { [weak browser] in browser?.now() ?? Date() }, choice: choice,
                  prepare: browser.previewRangeDelete ?? { _ in throw MemError.missing },
                  commit: browser.confirmRangeDelete ?? { _ in throw MemError.missing },
                  release: { try? cancel?($0) })
    }

    /// A made-up phase for renders.
    public func show(_ phase: Phase, range: DateInterval?) { generation += 1; self.phase = phase; self.range = range }

    public var preview: DeletionPreview? { if case .ready(let p) = phase { return p }; return nil }

    /// Releases the shown preview and prepares one for the current choice.
    public func refresh() {
        releaseShown()
        generation += 1
        let mine = generation, at = now()
        guard let interval = choice.range(now: at, calendar: calendar, customStart: customStart, customEnd: customEnd) else {
            range = nil; phase = .failed(ForgetRangeText.badRange); return
        }
        range = interval; phase = .loading
        let scope = MemoryActionScope.range(start: interval.start, end: interval.end, timezone: calendar.timeZone.identifier)
        Task { @MainActor in
            do {
                let p = try await prepare(scope)
                guard mine == generation else { release(p.id); return }
                phase = .ready(p)
                // A fresh question: a later refused Forget is prepared again once more (the sheet never sticks).
                retried = false
            } catch {
                guard mine == generation else { return }
                if case MemError.invalid(let why) = error, why == DeletionPreview.nothingInRange { phase = .empty }
                else { phase = .failed(ForgetRangeText.unavailable) }
            }
        }
    }

    /// Commits the shown preview. A refused commit (the range changed or the preview expired) is prepared again once
    /// and asked again; `done` runs after a commit.
    public func forget(done: @escaping () -> Void) {
        guard case .ready(let p) = phase else { return }
        generation += 1
        let mine = generation
        phase = .forgetting
        Task { @MainActor in
            do {
                try await commit(p.id)
                guard mine == generation else { return }
                phase = .done; notice = nil
                done()
            } catch {
                guard mine == generation else { return }
                if !retried { retried = true; notice = ForgetRangeText.changed; refresh() }
                else { phase = .failed(ForgetRangeText.failed) }
            }
        }
    }

    /// Cancel: the shown preview is released; nothing is deleted. Not while a Forget is committing (it can't be
    /// stopped, so Cancel is off then; r1 forget-range).
    public func dismiss() { guard phase != .forgetting else { return }; releaseShown(); generation += 1 }
    /// Cancel can be pressed (not while a Forget commits).
    public var canCancel: Bool { phase != .forgetting }
    /// After a failure the confirm button asks again instead of sitting disabled.
    public var canRetry: Bool { if case .failed = phase { return true }; return false }

    private func releaseShown() {
        if case .ready(let p) = phase { release(p.id) }
    }
}

/// The sheet: the choices, the custom range when chosen, the question and Cancel / Forget.
public struct ForgetRangeSheet: View {
    @ObservedObject var model: ForgetRangeModel
    let close: () -> Void
    let now: Date

    /// `now` is only the reference for how times are written (today's times alone, other days with the date).
    public init(model: ForgetRangeModel, now: Date = Date(), close: @escaping () -> Void) {
        self.model = model; self.now = now; self.close = close
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ForgetRangeText.title).font(.system(size: 15, weight: .semibold))
            Picker("", selection: $model.choice) {
                ForEach(ForgetRangeChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityIdentifier("forget-range-choice")
            if model.choice == .custom {
                HStack(spacing: 12) {
                    DatePicker("From", selection: $model.customStart, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("To", selection: $model.customEnd, displayedComponents: [.date, .hourAndMinute])
                }
                .datePickerStyle(.compact).font(.system(size: 12))
                .environment(\.timeZone, model.calendar.timeZone)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                if let notice = model.notice { Text(notice).font(.system(size: 12)).foregroundStyle(KitPalette.orange) }
                Text(headline).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("forget-range-question")
                if let warning = model.preview?.warning {
                    Text(warning).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.dismiss(); close() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!model.canCancel)
                Button(model.canRetry ? "Try Again" : ForgetRangeText.confirm, role: .destructive) {
                    if model.canRetry { model.refresh() } else { model.forget(done: close) }
                }
                    .buttonStyle(ForgetRangeButtonStyle())
                    .disabled(model.preview == nil && !model.canRetry)
                    .accessibilityIdentifier("forget-range-confirm")
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { if model.phase == .idle { model.refresh() } }
    }

    private var headline: String {
        let zone = model.calendar.timeZone
        switch model.phase {
        case .ready(let p):
            let s = p.rangeStart.flatMap(timestamp) ?? model.range?.start ?? now, e = p.rangeEnd.flatMap(timestamp) ?? model.range?.end ?? now
            return ForgetRangeText.question(p, start: s, end: e, timeZone: zone, now: now)
        case .empty:
            guard let r = model.range else { return "" }
            return ForgetRangeText.nothing(start: r.start, end: r.end, timeZone: zone, now: now)
        case .failed(let why): return why
        case .loading, .idle: return " "
        case .forgetting: return "Forgetting…"
        case .done: return ""
        }
    }
}

/// The red Forget: filled in the key window and out of it alike (a sheet's default button tint follows the window).
private struct ForgetRangeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(KitPalette.red.opacity(configuration.isPressed ? 0.8 : 1)))
            .opacity(enabled ? 1 : 0.4)
    }
}

extension View {
    /// Presents the range sheet while `isPresented`, built from the browser's closures (nothing when they are nil).
    public func forgetRangeSheet(browser: ActivityBrowser, isPresented: Binding<Bool>, onForgotten: @escaping () -> Void = {}) -> some View {
        sheet(isPresented: isPresented) {
            ForgetRangeHost(browser: browser, close: { isPresented.wrappedValue = false; onForgotten() },
                            cancel: { isPresented.wrappedValue = false })
        }
    }
}

/// Makes the model once per presentation.
private struct ForgetRangeHost: View {
    let now: Date
    let close: () -> Void
    let cancel: () -> Void
    @StateObject private var model: ForgetRangeModel
    init(browser: ActivityBrowser, close: @escaping () -> Void, cancel: @escaping () -> Void) {
        now = browser.now(); self.close = close; self.cancel = cancel
        _model = StateObject(wrappedValue: ForgetRangeModel(browser: browser))
    }
    var body: some View {
        ForgetRangeSheet(model: model, now: now, close: { if model.phase == .done { close() } else { cancel() } })
            .interactiveDismissDisabled(!model.canCancel)
    }
}
