import Foundation

/// Opt-in reader shape kept for existing legacy-collector grouping/now consumers.
/// Original IDs remain strings, not invented collector sequence numbers.
public struct LegacyEvent: Codable {
    public var id: String
    public var timestamp: String
    public var kind: String
    public var app: [String:String]
    public var window: [String:String]
    public var key: [String:String]
    public var source_id: String
}
public struct LegacyPage: Codable {
    public var events: [LegacyEvent]
    public var next: String?
    public var revision: String
    public var capture: String
}
extension MemoryStore {
    public func legacyPage(after: String? = nil, includeText: Bool = false, now: Date = Date()) throws -> LegacyPage {
        let revision = try disclosureRevision()
        var at = "", id = ""
        if let after {
            guard after.count < 2048, let data = Data(base64Encoded:after), let cursor = try? JSONDecoder().decode([String].self,from:data), cursor.count == 2 else { throw MemError.invalid("Invalid event cursor") }
            at = cursor[0]; id = cursor[1]
        }
        let rows = try rows("SELECT body FROM records WHERE json_extract(body,'$.at')>? OR (json_extract(body,'$.at')=? AND id>?) ORDER BY json_extract(body,'$.at'),id LIMIT 200",[at,at,id])
        var events: [LegacyEvent] = []
        var last: Evidence?
        for row in rows {
            let raw = try decode(Evidence.self,row[0]); last = raw
            guard let clean = Privacy.sanitized(raw,settings:try policy(),now:now) else { continue }
            // Typed rows: a word-count line only, never the words (sealed rows
            // have none in the body; build 4 plain text is not passed on).
            let key=includeText && clean.kind == "keyboard.text_input" ? ["typed":Self.typedReaderLine(clean,status:try typedStatuses([clean.id],now:now)[clean.id])] : [String:String]()
            events.append(LegacyEvent(id:clean.id,timestamp:clean.at,kind:clean.kind,app:["name":clean.app,"bundleIdentifier":clean.bundle],window:["title":clean.title,"url":clean.url],key:key,source_id:clean.id))
        }
        guard try revision == disclosureRevision() else { throw MemError.invalid("Evidence changed; retry from first page") }
        let next = rows.count == 200 ? try last.map { Data(try json([$0.at,$0.id]).utf8).base64EncodedString() } : nil
        return LegacyPage(events:events,next:next,revision:revision,capture:try captureStatus(now:now)["state"] ?? "off")
    }
}
