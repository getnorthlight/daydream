import Foundation

public struct DownloadTimeEstimate: Equatable, Sendable {
    private enum Phase: Equatable, Sendable { case idle, preparing, downloading, verifying, complete, cancelled, failed }
    private struct Sample: Equatable, Sendable {
        let time: TimeInterval
        let bytes: Int64
    }
    private var phase = Phase.idle
    private var samples: [Sample] = []
    private var received: Int64 = 0
    private var total: Int64 = 0
    private var lastAdvance: TimeInterval = 0
    private var lastUpdate: TimeInterval = 0

    public init() {}

    public mutating func begin() {
        self = Self()
        phase = .preparing
    }

    public mutating func record(received: Int64, total: Int64, at time: TimeInterval) {
        guard received >= 0, time.isFinite else { return }
        // A resumed file's existing bytes are not new network throughput. Each
        // file, retry, and return from verification starts a fresh sample window.
        if phase != .downloading || total != self.total || received < self.received || time < lastUpdate
            || (received > self.received && time - lastAdvance >= 10) {
            samples = [Sample(time: time, bytes: received)]
            lastAdvance = time
        } else {
            if received > self.received { lastAdvance = time }
            if let last = samples.last, time - last.time >= 1 {
                samples.append(Sample(time: time, bytes: received))
            }
            while samples.count > 2 && samples[1].time < time - 12 { samples.removeFirst() }
        }
        self.received = received
        self.total = total
        lastUpdate = time
        phase = total > 0 && received >= total ? .verifying : .downloading
    }

    public mutating func verifying() { phase = .verifying; samples = [] }
    public mutating func complete() { phase = .complete; samples = [] }
    public mutating func cancel() { phase = .cancelled; samples = [] }
    public mutating func fail() { phase = .failed; samples = [] }

    public var isActive: Bool { phase == .preparing || phase == .downloading || phase == .verifying }

    public func remainingSeconds(at time: TimeInterval) -> TimeInterval? {
        guard phase == .downloading, total > received, time.isFinite, time >= lastUpdate,
              time - lastAdvance < 10, let first = samples.first,
              lastUpdate - first.time >= 3, received > first.bytes else { return nil }
        // Include pauses in elapsed time. A clock tick never pretends that bytes
        // arrived, so an unchanged transfer cannot count down to completion.
        let rate = Double(received - first.bytes) / (time - first.time)
        let remaining = Double(total - received) / rate
        return remaining.isFinite && remaining > 0 ? remaining : nil
    }

    public func text(at time: TimeInterval) -> String? {
        switch phase {
        case .idle: return nil
        case .preparing: return "Preparing download..."
        case .verifying: return "Verifying downloaded files..."
        case .complete: return "Local files ready"
        case .cancelled: return "Download canceled"
        case .failed: return "Download failed. Try again."
        case .downloading:
            if time.isFinite && time - lastAdvance >= 10 { return "Waiting for download data..." }
            if total <= 0 { return "Time remaining unavailable" }
            guard let seconds = remainingSeconds(at: time) else { return "Calculating time remaining..." }
            if seconds < 60 { return "Less than a minute remaining" }
            if seconds >= 86_400 { return "More than a day remaining" }
            let minutes = Int(ceil(seconds / 60))
            if minutes < 60 { return "About \(minutes) \(minutes == 1 ? "minute" : "minutes") remaining" }
            let hours = minutes / 60, remainder = minutes % 60
            let hourText = "\(hours) \(hours == 1 ? "hour" : "hours")"
            if remainder == 0 { return "About \(hourText) remaining" }
            return "About \(hourText) \(remainder) \(remainder == 1 ? "minute" : "minutes") remaining"
        }
    }
}
