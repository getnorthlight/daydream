import Foundation
import CLlamaBridge

/// One token per load call. Cancellation never clears or affects a later call.
final class LoadAttempt: @unchecked Sendable {
    let ticket = wr_load_ticket_create()!
    var preflight: (() throws -> Void)?
    var failure: Error?
    deinit { wr_load_ticket_destroy(ticket) }
    func cancel() { wr_load_ticket_cancel(ticket) }
    func check() throws { if wr_load_ticket_cancelled(ticket) != 0 { throw CancellationError() } }
    static let callback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { pointer in
        guard let pointer else { return 1 }
        let attempt = Unmanaged<LoadAttempt>.fromOpaque(pointer).takeUnretainedValue()
        do { try attempt.check(); try attempt.preflight?(); try attempt.check(); return 0 }
        catch { attempt.failure = error; return 1 }
    }
}
