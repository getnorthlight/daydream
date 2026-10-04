import Foundation

@main struct DownloadTimeChecks {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func near(_ actual: Double?, _ expected: Double) -> Bool {
            actual.map { abs($0 - expected) < 0.001 } ?? false
        }
        var estimate = DownloadTimeEstimate()
        check(estimate.text(at: 0) == nil && !estimate.isActive, "Idle has no stale estimate")
        estimate.begin()
        check(estimate.text(at: 0) == "Preparing download...", "No estimate before receiving bytes")
        estimate.record(received: 0, total: 10_000, at: 0)
        estimate.record(received: 200, total: 10_000, at: 2)
        check(estimate.remainingSeconds(at: 2) == nil, "Initial samples must cover three seconds")
        check(estimate.text(at: 2) == "Calculating time remaining...", "Initial calculation is explicit")
        estimate.record(received: 400, total: 10_000, at: 4)
        check(near(estimate.remainingSeconds(at: 4), 96), "Uses bytes per second for remaining bytes")
        check(estimate.text(at: 4) == "About 2 minutes remaining", "Coarse approximate time avoids a false countdown")
        check(near(estimate.remainingSeconds(at: 6), 144), "A timer tick without bytes lengthens rather than decrements the estimate")
        check(estimate.text(at: 14) == "Waiting for download data...", "Silent transfer becomes waiting after ten seconds")
        check(estimate.remainingSeconds(at: 14) == nil, "Stalled estimate is hidden")
        estimate.record(received: 500, total: 10_000, at: 20)
        check(estimate.remainingSeconds(at: 20) == nil, "Recovery after a stall measures fresh throughput")
        estimate.record(received: 900, total: 10_000, at: 24)
        check(near(estimate.remainingSeconds(at: 24), 91), "Resumed data produces a new real estimate")

        estimate.begin()
        estimate.record(received: 8_000, total: 10_000, at: 100)
        estimate.record(received: 8_400, total: 10_000, at: 104)
        check(near(estimate.remainingSeconds(at: 104), 16), "Cached bytes are not counted as freshly downloaded")
        check(estimate.text(at: 104) == "Less than a minute remaining", "Short estimates remain approximate")
        estimate.record(received: 0, total: 1_000, at: 105)
        check(estimate.remainingSeconds(at: 105) == nil, "Runtime file starts its own measurement")
        estimate.record(received: 400, total: 1_000, at: 109)
        check(near(estimate.remainingSeconds(at: 109), 6), "Runtime ETA uses the runtime's own remaining bytes")
        estimate.record(received: 1_000, total: 1_000, at: 110)
        check(estimate.remainingSeconds(at: 110) == nil, "Last byte does not imply install complete")
        check(estimate.text(at: 110) == "Verifying downloaded files...", "Verification replaces transfer ETA")
        estimate.complete()
        check(estimate.text(at: 500) == "Local files ready" && !estimate.isActive, "Completion clears active estimate")

        estimate.begin()
        estimate.record(received: 0, total: 0, at: 0)
        estimate.record(received: 400, total: 0, at: 4)
        check(estimate.text(at: 4) == "Time remaining unavailable", "Unknown size never fabricates an ETA")
        estimate.fail()
        check(estimate.text(at: 4) == "Download failed. Try again." && !estimate.isActive, "Failure clears estimate")
        estimate.begin()
        check(estimate.text(at: 5) == "Preparing download...", "Retry discards failure and old rate")
        estimate.record(received: 200, total: 10_000, at: 5)
        estimate.cancel()
        check(estimate.text(at: 500) == "Download canceled" && estimate.remainingSeconds(at: 500) == nil, "Cancel clears estimate")
        estimate.begin()
        estimate.record(received: 500, total: 10_000, at: 0)
        estimate.record(received: 900, total: 10_000, at: 4)
        estimate.record(received: 100, total: 10_000, at: 5)
        check(estimate.remainingSeconds(at: 5) == nil, "A restarted transfer with the same size resets samples")
        estimate.record(received: 500, total: 10_000, at: 9)
        check(near(estimate.remainingSeconds(at: 9), 95), "Same-file retry ignores stale previous rate")
        estimate.verifying()
        check(estimate.text(at: 50) == "Verifying downloaded files...", "Cached-file verification never looks stalled")

        estimate.begin()
        estimate.record(received: 0, total: 100_000, at: 0)
        for time in 1...20 { estimate.record(received: Int64(time * 100), total: 100_000, at: Double(time)) }
        for time in 21...36 { estimate.record(received: Int64(2_000 + (time - 20) * 200), total: 100_000, at: Double(time)) }
        check(near(estimate.remainingSeconds(at: 36), 474), "Recent window adapts to a faster network")
        check(estimate.text(at: 36) == "About 8 minutes remaining", "Updated throughput changes displayed minutes")
        check(estimate.remainingSeconds(at: .nan) == nil && estimate.remainingSeconds(at: 35) == nil, "Invalid or earlier clocks cannot produce an estimate")
        let unchanged = estimate
        estimate.record(received: -1, total: 100_000, at: 37)
        estimate.record(received: 6_000, total: 100_000, at: .infinity)
        check(estimate == unchanged, "Invalid samples are ignored")

        estimate.begin()
        estimate.record(received: 0, total: 360_400, at: 0)
        estimate.record(received: 400, total: 360_400, at: 4)
        check(estimate.text(at: 4) == "About 1 hour remaining", "Hour estimate formats naturally")
        estimate.begin()
        estimate.record(received: 0, total: Int64.max, at: 0)
        estimate.record(received: 1, total: Int64.max, at: 4)
        check(estimate.text(at: 4) == "More than a day remaining", "Very slow transfers format without integer overflow")
        print("PASS: \(checks) download ETA checks; synthetic byte samples only")
    }
}
