import Foundation

public enum ActionResources {
    public static func actionURI(_ id:String) -> String {
        "macmem://actions/"+Data(id.utf8).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")+".json"
    }
    public static func dayURI(_ day:String,timezone:String) -> String {
        var url=URLComponents(); url.scheme="macmem"; url.host="days"; url.path="/"+day+".json"; url.queryItems=[URLQueryItem(name:"timezone",value:timezone)]
        return url.string!
    }
    public static func activityURI(_ id:String,day:String,timezone:String) -> String {
        var url=URLComponents(); url.scheme="macmem"; url.host="activities"; url.path="/"+id+".json"; url.queryItems=[URLQueryItem(name:"day",value:day),URLQueryItem(name:"timezone",value:timezone)]
        return url.string!
    }
}
extension MemoryStore {
    /// Logical resources only. No path ever reaches a filesystem operation.
    /// Summary-only for typing by construction: typed actions carry a word
    /// count, never words (those open only through `hydrateTypedText`).
    /// `assistant` (MCP only) adds the day overview AI apps read; CLI and
    /// remote readers keep the original, smaller day resource.
    public func openActionResource(_ uri:String,now:Date=Date(),assistant:Bool=false) throws -> String {
        guard uri.utf8.count <= 8192, let url=URLComponents(string:uri), url.scheme == "macmem", url.user == nil, url.password == nil, url.port == nil, url.fragment == nil else { throw MemError.invalid("Invalid memory resource") }
        let revision=try actionReadEpoch()
        let pairs=url.queryItems ?? []
        guard Set(pairs.map(\.name)).count == pairs.count, Set(pairs.map(\.name)).isSubset(of:["day","timezone","after"]) else { throw MemError.invalid("Unsupported resource arguments") }
        let params=Dictionary(uniqueKeysWithValues:pairs.map { ($0.name,$0.value ?? "") })
        var body:String
        if url.host == "actions" {
            guard pairs.isEmpty, url.path.hasSuffix(".json") else { throw MemError.invalid("Invalid action resource") }
            var token=String(url.path.dropFirst().dropLast(5))
            guard token.range(of:"^[A-Za-z0-9_-]{1,600}$",options:.regularExpression) != nil else { throw MemError.invalid("Invalid action identity") }
            token=token.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
            token += String(repeating:"=",count:(4-token.count%4)%4)
            guard let data=Data(base64Encoded:token), let id=String(data:data,encoding:.utf8), id.count <= 200 else { throw MemError.invalid("Invalid action identity") }
            body=try json(action(id,now:now))
        } else if url.host == "days" || url.host == "activities" {
            guard url.path.hasSuffix(".json") else { throw MemError.invalid("Invalid day resource") }
            // The Mac's own zone when none is given, so AI apps can open
            // macmem://days/today.json without knowing the person's zone.
            let timezone=params["timezone"] ?? TimeZone.current.identifier
            guard let zone=TimeZone(identifier:timezone) else { throw MemError.invalid("Unknown timezone; use an IANA name such as America/Los_Angeles") }
            let name=String(url.path.dropFirst().dropLast(5))
            var day=url.host == "days" ? name : params["day"] ?? ""
            if url.host == "days", ["today","yesterday"].contains(name) {
                var calendar=Calendar(identifier:.gregorian); calendar.timeZone=zone
                let date=name == "today" ? now : calendar.date(byAdding:.day,value:-1,to:now) ?? now
                day=try DayScope.key(date,timezone:timezone)
            }
            let layers=try dayLayers(day:day,timezone:timezone,after:params["after"],limit:20,now:now)
            if url.host == "days" {
                // List activity links, not thousands of repeated membership IDs.
                // The overview (first page only) is what AI apps read: every
                // moment of the day in order, with local times and notes.
                struct DayResource:Codable { var summary:DaySummary; var activities:[String]; var activityCount:Int; var actions:ActionPage; var partial:Bool; var defaultLayer:String; var overview:AssistantDayOverview? }
                let pageIDs=Set(layers.actions.actions.map(\.id))
                let groups=layers.activities.filter { !$0.actionIDs.allSatisfy({!pageIDs.contains($0)}) }
                var summary=layers.summary; summary.activityIDs=groups.map(\.id)
                summary.generated?.actionIDs=layers.actions.actions.map(\.id)
                let overview=assistant && params["after"] == nil ? assistantDayOverview(layers,day:day,timezone:timezone) : nil
                body=try json(DayResource(summary:summary,activities:groups.map { ActionResources.activityURI($0.id,day:day,timezone:timezone) },activityCount:layers.activities.count,actions:layers.actions,partial:layers.partial,defaultLayer:layers.defaultLayer,overview:overview))
            } else {
                guard name.range(of:"^activity_[a-f0-9]{64}$",options:.regularExpression) != nil else { throw MemError.invalid("Invalid activity identity") }
                // Action page uses the same day cursor; empty filtered pages still
                // carry next, so callers can continue without losing actions.
                var group=layers.activities.first { $0.id == name }
                struct ActivityResource:Codable { var activity:ActivityNote?; var actionCount:Int; var actions:ActionPage }
                let members=Set(group?.actionIDs ?? [])
                var page=layers.actions
                var collected=page.actions.filter { members.contains($0.id) }, scanned=page.candidates
                // Keep reading the day's pages (same snapshot and cursor) until this
                // moment fills a page or the day ends. A moment late in the day used
                // to open as an empty page holding only a cursor.
                // Reads 100 at a time (at most 50 reads); when the page fills
                // midway, next resumes right after the last action shown.
                if !members.isEmpty {
                    let interval=try DayScope.interval(day:day,timezone:timezone)
                    while collected.count < 20, let next=page.next, scanned < 5000 {
                        let more=try actions(start:interval.start,end:interval.end,after:next,limit:100,now:now,snapshot:page.snapshot)
                        scanned += more.candidates; page.next=more.next
                        for (index,action) in more.actions.enumerated() where members.contains(action.id) {
                            collected.append(action)
                            guard collected.count == 20 else { continue }
                            if index < more.actions.count-1 {
                                guard let resume=try actionCursor(start:interval.start,end:interval.end,snapshot:page.snapshot,after:action.id) else { throw MemError.invalid("Resource changed; retry") }
                                page.next=resume
                            }
                            break
                        }
                    }
                }
                page.actions=collected; page.candidates=scanned
                let pageIDs=Set(page.actions.map(\.id))
                group?.actionIDs=page.actions.map(\.id)
                group?.generated?.actionIDs=page.actions.map(\.id)
                let clusters:[ObservationCluster]=group?.clusters.compactMap { cluster -> ObservationCluster? in
                    var cluster=cluster; cluster.actionIDs=cluster.actionIDs.filter(pageIDs.contains)
                    return cluster.actionIDs.isEmpty ? nil : cluster
                } ?? []
                group?.clusters=clusters
                body=try json(ActivityResource(activity:group,actionCount:members.count,actions:page))
            }
        } else { throw MemError.invalid("Unknown memory resource") }
        guard body.utf8.count <= 128_000 else { throw MemError.invalid("Resource exceeds read bound; use canonical action pagination") }
        guard try revision == actionReadEpoch() else { throw MemError.invalid("Resource changed; retry") }
        return body
    }
}
