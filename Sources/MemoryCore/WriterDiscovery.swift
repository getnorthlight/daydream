import Foundation

/// Scheduling metadata only. No source bodies, provider authority or completion
/// claims are saved here. Canonical note targets remain the queue's source.
private struct WriterDiscoveryCursor: Codable {
    var version=1
    var timezone:String
    var policyRevision:String
    var epoch:String
    var before:Date
    var after:String?
    var poll:UInt64=0
    var cycle:UInt64=0
}
public struct WriterDiscoveryWindow {
    public let today:String
    public let historicalDay:String?
    public let currentRotation:UInt64
    public let historyRotation:UInt64
    public let candidatesExamined:Int
    public let scanning:Bool
}
extension MemoryStore {
    /// One bounded canonical page per poll, never one query per empty calendar
    /// day. A durable cursor resumes after app restart. Excluded-only pages make
    /// progress without exposing them as targets. Later insertions are revisited
    /// on the next sweep; append-only capture does not invalidate pagination.
    public func nextWriterDiscoveryWindow(now:Date=Date(),timezone:String=TimeZone.current.identifier) throws -> WriterDiscoveryWindow {
        guard TimeZone(identifier:timezone) != nil else {throw MemError.invalid("Invalid writer timezone")}
        // gold/notes G18: the page is read outside any write transaction (it scans the records table), and the
        // checkpoint is saved after, only if nothing moved it meanwhile. A change mid-read reads again once.
        do { return try discoveryWindowOnce(now:now,timezone:timezone) }
        catch MemError.invalid(let message) where message.hasPrefix("Stale or invalid action cursor") || message.hasPrefix("Actions changed") || message.hasPrefix("Snapshot invalidated") {
            return try discoveryWindowOnce(now:now,timezone:timezone)
        }
    }
    private func discoveryWindowOnce(now:Date,timezone:String) throws -> WriterDiscoveryWindow {
            let today=try DayScope.key(now,timezone:timezone)
            let todayStart=try DayScope.interval(day:today,timezone:timezone).start
            let policy=try policy(),epoch=try actionReadEpoch()
            let raw=try rows("SELECT body FROM metadata WHERE id='writer-discovery-v1'").first?.first
            var cursor=try raw.map{try decode(WriterDiscoveryCursor.self,$0)} ?? WriterDiscoveryCursor(timezone:timezone,policyRevision:policy.revision,epoch:epoch,before:todayStart)
            guard cursor.version==1,cursor.before.timeIntervalSince1970.isFinite,
                  cursor.after.map({$0.utf8.count<4096}) ?? true else {throw MemError.invalid("Invalid writer discovery checkpoint")}
            if cursor.timezone != timezone || cursor.policyRevision != policy.revision {
                cursor=WriterDiscoveryCursor(timezone:timezone,policyRevision:policy.revision,epoch:epoch,before:todayStart)
            }
            // Deletion/correction revokes a page snapshot, not the already
            // traversed calendar range. Never retain stale source references.
            if cursor.epoch != epoch || cursor.before>todayStart {
                cursor.epoch=epoch;cursor.after=nil;cursor.before=min(cursor.before,todayStart)
            }
            let cutoff=try policy.retention.cutoff(now:now)
            if let cutoff,cursor.before<=cutoff {
                cursor.before=todayStart;cursor.after=nil;cursor.cycle &+= 1
            }
            let rotation=cursor.cycle,poll=cursor.poll
            let page=try actions(end:cursor.before,after:cursor.after,limit:128,now:now,descending:true)
            var historical:String?
            if let action=page.actions.first,let at=timestamp(action.at) {
                historical=try DayScope.key(at,timezone:timezone)
                cursor.before=try DayScope.interval(day:historical!,timezone:timezone).start
                cursor.after=nil
            } else if let after=page.next {
                cursor.after=after
            } else {
                cursor.before=todayStart;cursor.after=nil;cursor.cycle &+= 1
            }
            cursor.poll &+= 1
            try transaction {
                guard try rows("SELECT body FROM metadata WHERE id='writer-discovery-v1'").first?.first == raw,
                      try self.policy().revision == policy.revision, try actionReadEpoch() == epoch else { return }
                try exec("INSERT OR REPLACE INTO metadata VALUES('writer-discovery-v1',?)",[json(cursor)])
            }
            return WriterDiscoveryWindow(today:today,historicalDay:historical,currentRotation:poll,historyRotation:rotation,candidatesExamined:page.candidates,scanning:historical==nil && page.next != nil)
    }
}
