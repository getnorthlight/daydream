import Foundation

/// fix/sx-engine-battery: one model load per batch of notes. Every writer (moment notes through CanonicalLocalWriter,
/// level notes through LevelWriterBinding) shares one BatchRuntime, and each still calls `load()` before it writes and
/// `unload()` after, as before. Here `load()` is a no-op while the model is warm, and `unload()` only lets go: the
/// model is unloaded 90 seconds after the last writer let go and the batch ended, unless another batch starts first.
/// `unloadNow()` (turning summaries off) unloads at once. Loads, unloads and failed loads are counted for checks.
public actor BatchRuntime: LocalInference {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    private let base: any LocalInference
    private let idleUnload: TimeInterval
    private let now: @Sendable () -> Date
    private let sleep: Sleep
    private var loaded = false
    private var users = 0
    private var batches = 0
    private var loading: Task<Void, Error>?
    private var unloadTimer: Task<Void, Never>?
    /// When the model was last let go with no batch open (the deferred unload counts from here).
    private var idleSince: Date?
    public private(set) var loads = 0
    public private(set) var unloads = 0
    /// Loads in a row that failed (not cancelled). A load that works sets it back to 0.
    public private(set) var failedLoads = 0

    public init(_ base: any LocalInference, idleUnload: TimeInterval = 90, now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }) {
        self.base = base; self.idleUnload = idleUnload; self.now = now; self.sleep = sleep
    }

    /// A batch holds the model between its notes. Batches nest (an agent's request during a scheduled batch).
    public func beginBatch() async {
        cancelTimer()
        await unloadIfOverdue()
        batches += 1
    }
    public func endBatch() {
        batches = max(0, batches - 1)
        if batches == 0 && users == 0 { letGo() }
    }
    public var isLoaded: Bool { loaded }
    /// Try Again: the loads that failed before no longer count; only a new failed load says the model can't start.
    public func resetFailedLoads() { failedLoads = 0 }

    public func load() async throws {
        cancelTimer()
        await unloadIfOverdue()
        if !loaded {
            if let loading {
                try await loading.value
            } else {
                let task = Task { try await base.load() }
                loading = task
                do {
                    try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                } catch {
                    loading = nil
                    if !(error is CancellationError) && !Task.isCancelled { failedLoads += 1 }
                    // A failed load may have left a half-loaded model: let it go now.
                    await base.unload()
                    throw error
                }
                loading = nil; loaded = true; loads += 1; failedLoads = 0
            }
        }
        users += 1; idleSince = nil
    }

    public func generate(instruction: String, evidence: String, maxTokens: Int) async throws -> Data {
        try await base.generate(instruction: instruction, evidence: evidence, maxTokens: maxTokens)
    }
    public func generate(instruction: String, evidence: String, maxTokens: Int, prefill: String) async throws -> Data {
        try await base.generate(instruction: instruction, evidence: evidence, maxTokens: maxTokens, prefill: prefill)
    }

    public func generate(instruction: String, evidence: String, maxTokens: Int, prefill: String, expiresAt: Date) async throws -> Data {
        try await base.generate(instruction: instruction, evidence: evidence, maxTokens: maxTokens, prefill: prefill, expiresAt: expiresAt)
    }

    /// A writer is done with the model. It stays loaded for the rest of the batch.
    public func unload() async {
        users = max(0, users - 1)
        if users == 0 && batches == 0 { letGo() }
    }

    /// Summaries turned off, or the runtime is being replaced: unload now and forget every batch.
    public func unloadNow() async {
        cancelTimer(); batches = 0; users = 0
        loading?.cancel(); loading = nil
        await unloadModel()
    }

    /// An idle model whose deferred unload is overdue (a clock that jumped over a sleep, or a timer that never ran)
    /// is unloaded before the next batch or load, as it would have been by the timer.
    private func unloadIfOverdue() async {
        if loaded, users == 0, batches == 0, let idle = idleSince, now().timeIntervalSince(idle) >= idleUnload {
            await unloadModel()
        }
    }
    private func letGo() {
        idleSince = now()
        guard loaded else { return }
        cancelTimer()
        let delay = idleUnload, sleep = self.sleep
        unloadTimer = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            await self?.timerFired()
        }
    }
    private func timerFired() async {
        unloadTimer = nil
        guard users == 0, batches == 0 else { return }
        await unloadModel()
    }
    private func unloadModel() async {
        guard loaded else { return }
        loaded = false; unloads += 1; idleSince = nil
        await base.unload()
    }
    private func cancelTimer() { unloadTimer?.cancel(); unloadTimer = nil }
}
