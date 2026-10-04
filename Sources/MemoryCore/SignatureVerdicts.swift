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
    /// perf-1005: a pass past half its `ttl` (and not yet expired): the caller checks again OFF the main thread, so the
    /// next key finds a fresh pass instead of evaluating the certificate chain on the main thread every 2 s (owner laptop
    /// 10/4: `SecTrustEvaluateIfNecessary` on the main thread up to 42 times a minute, "should not be called on the main
    /// thread"). The rule is unchanged: a pass is used at most `ttl` after the check that produced it.
    public func refreshDue(_ key: String, now: UInt64) -> Bool {
        guard let at = passes[key], now >= at else { return false }
        return now - at > Self.ttl / 2 && now - at <= Self.ttl
    }
    public mutating func record(_ key: String, valid: Bool, now: UInt64) {
        guard valid else { passes[key] = nil; return }
        if passes.count >= Self.capacity { passes = passes.filter { now >= $0.value && now - $0.value <= Self.ttl } }
        if passes.count >= Self.capacity { passes.removeAll() }
        // A background check that started before a newer one never makes the pass older.
        passes[key] = max(passes[key] ?? 0, now)
    }
    public var count: Int { passes.count }
}
