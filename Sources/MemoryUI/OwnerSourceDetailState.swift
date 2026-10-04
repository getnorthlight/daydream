import Foundation
import Combine
import MemoryCore

/// Plaintext lives only in a selected detail's @State. No row/global cache,
/// persistence or serialization. Lifecycle events invalidate in-flight reads too.
public struct OwnerSourceDetailState {
    public private(set) var previews: [OwnerSourcePreview] = []
    public private(set) var ticket = 0
    public private(set) var active = false
    public private(set) var actionIDs: Set<String> = []
    public private(set) var scope = ""

    public init() {}
    public static func closesOwnWindow(own: Int?, closing: Int) -> Bool {
        own == nil || own == closing
    }
    @discardableResult public mutating func begin(scope: String, actionIDs: [String]) -> Int {
        clear(); self.scope = scope; self.actionIDs = Set(actionIDs); active = true
        return ticket
    }
    public mutating func clear() {
        ticket += 1; previews = []; actionIDs = []; scope = ""; active = false
    }
    /// Only known verified runs supplement the summary. Unknown legacy sources
    /// retain the existing local summary path even when owner access can open them.
    @discardableResult public mutating func accept(_ found: [OwnerSourcePreview], ticket: Int,
                                                    revision: String?, now: Date) -> Bool {
        guard active, self.ticket == ticket else { return false }
        guard let revision, found.allSatisfy({ p in
            p.disclosureRevision == revision && Set(p.actionIDs).isSubset(of: actionIDs) &&
            // claude/terminal-details-1003: a withheld marker (one action, no parts, a privacy reason) carries no words.
            (p.parts.map(\.actionID) == p.actionIDs || p.isWithheld) &&
            p.expiresAt.map { $0 > max(now, p.readAt) } != false
        }) else { clear(); return false }
        previews = found.filter { $0.runID != nil }
        return true
    }
    /// An unavailable or changed disclosure clears everything, never salvages a
    /// previously open quote. The host may start a new scoped owner read.
    @discardableResult public mutating func revalidate(_ revision: String?, now: Date) -> Bool {
        guard active, let revision,
              previews.allSatisfy({ p in p.disclosureRevision == revision &&
                  p.expiresAt.map { $0 > max(now, p.readAt) } != false }) else {
            clear(); return false
        }
        return true
    }
    public var deadline: Date? { previews.compactMap(\.expiresAt).min() }
}


/// The actual selected-detail async owner lifecycle, testable without a window.
/// No source text is passed to a global model/index/cache. Metadata polling is
/// 500ms plus reader latency; explicit host/lifecycle notifications close at once.
@MainActor public final class OwnerSourceDetailSession: ObservableObject {
    @Published public private(set) var state = OwnerSourceDetailState()
    private var loadTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    public nonisolated init() {}

    public func close() {
        loadTask?.cancel(); loadTask = nil
        expiryTask?.cancel(); expiryTask = nil
        state.clear()
    }
    public func open(scope: String, actionIDs: [String],
                     load: @escaping ([String]) async -> [OwnerSourcePreview],
                     revision: @escaping (Date?) async -> String?,
                     now: @escaping () -> Date = Date.init) {
        close()
        let ticket = state.begin(scope: scope, actionIDs: actionIDs)
        loadTask = Task { @MainActor [weak self] in
            do {
                let found = await load(actionIDs)
                guard !Task.isCancelled, self?.state.ticket == ticket else { return }
                let access = await revision(found.compactMap(\.expiresAt).min())
                guard !Task.isCancelled, let self, self.state.ticket == ticket else { return }
                guard self.state.accept(found, ticket: ticket, revision: access, now: now()),
                      !self.state.previews.isEmpty else { return }
                self.armExpiry(ticket: ticket, now: now)
            } // Release temporary hydrated words before the metadata-only watch.
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard self?.state.active == true, self?.state.ticket == ticket else { return }
                let access = await revision(self?.state.deadline)
                guard !Task.isCancelled, let self, self.state.ticket == ticket else { return }
                if !self.state.revalidate(access, now: now()) {
                    self.open(scope: scope, actionIDs: actionIDs, load: load, revision: revision, now: now)
                    return
                }
            }
        }
    }
    /// Independent of the metadata reader: a slow/stalled revision check cannot
    /// keep a quote on screen after its existing retention deadline.
    private func armExpiry(ticket: Int, now: @escaping () -> Date) {
        expiryTask?.cancel()
        guard let deadline = state.deadline else { return }
        let delay = max(0, deadline.timeIntervalSince(now()))
        expiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(min(delay, 1_000_000_000) * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled, let self, self.state.ticket == ticket else { return }
            self.close()
        }
    }
    deinit { loadTask?.cancel(); expiryTask?.cancel() }
}
