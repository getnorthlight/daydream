// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.

/// perf-1002: a signature check's pass, remembered briefly for one launch. The typing proof checked the signature of
/// the app in front up to six times per key (both proofs, each witness identity read), each a certificate-chain
/// evaluation on the main thread. `key` names the launch (pid, kernel start time, bundle) and the requirement, so a
/// reused PID, another bundle or another requirement never matches. Only a pass is kept, for `ttl` from the check
/// that produced it; a refusal is never remembered, and an expired or unknown key checks again.
public struct SignatureVerdicts: Sendable {
    public static let ttl: UInt64 = 2_000_000_000
    public static let capacity = 32
    private var passes: [String: UInt64] = [:]
    public init() {}
    /// A pass for `key` checked at most `ttl` before `now` (uptime nanoseconds).
    public func passed(_ key: String, now: UInt64) -> Bool {
        guard let at = passes[key] else { return false }
        return now >= at && now - at <= Self.ttl
    }
    public mutating func record(_ key: String, valid: Bool, now: UInt64) {
        guard valid else { passes[key] = nil; return }
        if passes.count >= Self.capacity { passes = passes.filter { now >= $0.value && now - $0.value <= Self.ttl } }
        if passes.count >= Self.capacity { passes.removeAll() }
        passes[key] = now
    }
    public var count: Int { passes.count }
}
