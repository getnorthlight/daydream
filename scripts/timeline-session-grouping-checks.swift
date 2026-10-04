import Foundation

@main enum TimelineSessionGroupingChecks {
    struct Row: Decodable, Equatable {
        let id: String, channel: String
        let startOffsetSeconds: Double, endOffsetSeconds: Double
        let actionCount: Int
        let sites: [String], bundles: [String]
    }
    struct Fixture: Decodable { let source: String, testEpoch: String; let members: [Row] }
    static func main() throws {
        let fixturePath = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1])
            : URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/derived-session-interval-pattern.json")
        let data = try Data(contentsOf: fixturePath)
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ s: String) -> Date { fractional.date(from:s) ?? plain.date(from:s)! }
        let epoch = date(fixture.testEpoch)
        let members = fixture.members.map {
            TimelineSessionMember(id:$0.id, dayKey:"2001-01-01", start:epoch.addingTimeInterval($0.startOffsetSeconds), end:epoch.addingTimeInterval($0.endOffsetSeconds),
                                  channel:TimelineSessionChannel.recorded(sites:$0.sites,bundles:$0.bundles), detail:$0)
        }
        var checks = 0
        func require(_ value: Bool, _ why: String) {
            precondition(value, why); checks += 1
        }
        require(members.allSatisfy { $0.channel?.rawValue == $0.detail.channel }, "Derived recorded-pattern metadata routes every selected member without title guesses")
        var reports: [[String:Any]] = []
        for gap in [60.0, 300.0, 1800.0] {
            let groups = TimelineSessionGrouping.group(members, maximumGap:gap)
            require(groups.count == 4, "Derived interval pattern must make X + Instagram + two Texts containers")
            require(groups.filter { $0.channel == .x }.map { $0.members.count } == [3], "X overlapping Home interval retains both post records")
            require(groups.filter { $0.channel == .instagram }.map { $0.members.count } == [2], "Instagram labels 3.118 sec apart join")
            require(groups.filter { $0.channel == .messages }.map { $0.members.count } == [3,4], "Texts separate at 75m22s gap")
            let flattened = groups.flatMap(\.members)
            require(flattened.count == members.count && Set(flattened.map(\.id)) == Set(members.map(\.id)), "Every anonymous member ID retained exactly once")
            require(flattened.allSatisfy { child in members.first { $0.id == child.id }?.detail == child.detail }, "Complete fixture detail retained")
            require(flattened.reduce(0) { $0 + $1.detail.actionCount } == members.reduce(0) { $0 + $1.detail.actionCount }, "All source action counts retained, no synthetic summary")
            require(groups.allSatisfy { group in group.members.map(\.id) == members.filter { x in group.members.contains { $0.id == x.id } }.map(\.id) }, "Fixture child display order retained")
            let twice = TimelineSessionGrouping.group(flattened,maximumGap:gap)
            require(twice.map(\.id) == groups.map(\.id) && twice.map { $0.members.map(\.id) } == groups.map { $0.members.map(\.id) }, "Idempotent display grouping")
            reports.append(["gapSeconds":gap,"inputChildren":members.count,"containers":groups.map { ["channel":$0.channel!.rawValue,"children":$0.members.count,"sourceActions":$0.members.reduce(0) { $0+$1.detail.actionCount }] }])
        }
        require(TimelineSessionChannel.recorded(sites:["www.instagram.com"],bundles:["com.google.Chrome"]) == .instagram,"Recorded www host normalizes")
        require(TimelineSessionChannel.recorded(sites:["https://www.instagram.com/"],bundles:["com.google.Chrome"]) == .instagram,"Recorded URL normalizes")
        require(TimelineSessionChannel.recorded(sites:["x.com","twitter.com"],bundles:["com.google.Chrome"]) == .x,"Known X aliases share display channel")
        require(TimelineSessionChannel.recorded(sites:["x.com","instagram.com"],bundles:["com.google.Chrome"]) == nil,"Derived two-site pattern must not choose first site")
        require(TimelineSessionChannel.recorded(sites:[],bundles:["com.apple.MobileSMS"]) == .messages,"Texts channel needs exact app identity")
        require(TimelineSessionChannel.recorded(sites:[],bundles:["com.apple.MobileSMS","com.google.Chrome"]) == nil,"Mixed-app record does not infer one conversation")
        let output:[String:Any] = ["result":"PASS","checks":checks,"source":fixture.source,"replay":reports,"limitations":"Display-only intervals. No recipient identities, typed words, delivery evidence, live recorder, or UI activation tested. Range is never focused duration."]
        print(String(data:try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    }
}
