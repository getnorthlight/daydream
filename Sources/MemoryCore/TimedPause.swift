import Foundation

/// In-memory intent only. No timer, persisted resume flag, permission or capture API.
public struct TimedPause {
    public struct Ticket: Equatable, Sendable { public let id:UUID; public let deadline:Date }
    public private(set) var ticket:Ticket?
    public init() {}
    public mutating func cancel() { ticket=nil }
    @discardableResult public mutating func begin(minutes:Int,wasRecording:Bool,now:Date)->Ticket? {
        cancel()
        guard wasRecording, [5,15,30,120].contains(minutes) else { return nil }
        let next=Ticket(id:UUID(),deadline:now.addingTimeInterval(Double(minutes)*60))
        ticket=next; return next
    }
    /// Picks up a timed pause the Mac's sleep, a screen lock or a user switch interrupted, until the same
    /// deadline. nil (and no ticket) once that deadline has passed: the caller starts recording instead.
    @discardableResult public mutating func resume(until deadline:Date,now:Date)->Ticket? {
        cancel()
        guard deadline > now, deadline.timeIntervalSince(now) <= 120*60 else { return nil }
        let next=Ticket(id:UUID(),deadline:deadline)
        ticket=next; return next
    }
    /// The deadline check. true once, at or after the deadline, when recording may start again: the person
    /// asked for a pause of that length, so it ends by itself whichever app is in front (every event is still
    /// filtered as it is recorded, exactly as after Resume) and even if the timer fired late (a busy main
    /// thread, an open menu or App Nap).
    public mutating func expire(_ candidate:Ticket,now:Date,permitted:Bool,replacementSafe:Bool,awake:Bool)->Bool {
        guard candidate == ticket else { return false }
        guard permitted && replacementSafe && awake else { cancel(); return false }
        guard now >= candidate.deadline else { return false }
        cancel() // One opportunity only; a failed start is reported, never retried.
        return true
    }
}
