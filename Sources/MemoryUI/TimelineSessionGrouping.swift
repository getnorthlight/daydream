import Foundation
import CoreGraphics

/// A display container, not a conversation, post, or saved activity identity.
/// Legacy app/site eligibility comes from recorded metadata. Per-bracket app containers
/// retain recorded conversation names on their original members; saved conversations never merge.
public enum TimelineSessionChannel: String, Equatable {
    case x, instagram, messages, systemSettings

    public var label: String {
        switch self { case .x: return "X"; case .instagram: return "Instagram"; case .messages: return "Texts"; case .systemSettings: return "System Settings" }
    }

    public static func recorded(sites: [String], bundles: [String],
                                browserBundles: Set<String> = ["com.google.Chrome"]) -> Self? {
        let hosts = Set(sites.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(host))
        if !hosts.isEmpty {
            let recordedBundles = Set(bundles.filter { !$0.isEmpty })
            guard !recordedBundles.isEmpty, recordedBundles.isSubset(of: browserBundles) else { return nil }
            let channels = hosts.compactMap { h -> Self? in
                switch h {
                case "x.com", "twitter.com", "mobile.twitter.com": return .x
                case "instagram.com": return .instagram
                default: return nil
                }
            }
            // A multi-site moment stays separate rather than choosing its first site.
            guard channels.count == hosts.count, Set(channels.map(\.rawValue)).count == 1 else { return nil }
            return channels.first
        }
        switch Set(bundles.filter { !$0.isEmpty }) {
        case ["com.apple.MobileSMS"]: return .messages
        case ["com.apple.systempreferences"]: return .systemSettings
        default: return nil
        }
    }

    private static func host(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let url = URL(string: value.contains("://") ? value : "https://" + value)
        guard var host = url?.host else { return "" }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

/// The complete original detail remains attached to its original ID.
public struct TimelineSessionMember<Detail> {
    public let id: String, dayKey: String
    public let start: Date, end: Date
    public let channel: TimelineSessionChannel?
    /// A bracket's app display container only; never a saved conversation identity.
    public let displayAppID: String?
    public let displayAppName: String?
    /// Recorded conversation identity only, never generated prose or typed words.
    public let conversation: String?
    public let allowsGenericAlias: Bool
    public let latestObserved: Date
    public let detail: Detail

    public init(id: String, dayKey: String, start: Date, end: Date,
                channel: TimelineSessionChannel?, detail: Detail,
                conversation: String? = nil, latestObserved: Date? = nil, allowsGenericAlias: Bool = true,
                displayAppID: String? = nil, displayAppName: String? = nil) {
        self.id = id; self.dayKey = dayKey; self.start = start; self.end = end
        self.channel = channel; self.detail = detail
        self.displayAppID = displayAppID; self.displayAppName = displayAppName
        self.conversation = conversation
        self.allowsGenericAlias = allowsGenericAlias
        self.latestObserved = latestObserved ?? end
    }
}

public struct TimelineSession<Detail>: Identifiable {
    public let channel: TimelineSessionChannel?
    /// Members retain their IDs and complete details; section cards order them by saved activity.
    public let members: [TimelineSessionMember<Detail>]
    public var presentationID: String? = nil
    public var conversation: String? = nil
    public var displayAppID: String? = nil
    public var displayAppName: String? = nil
    public var isGrouped: Bool { (channel != nil || displayAppID != nil) && members.count > 1 }
    public var id: String {
        if let presentationID { return presentationID }
        guard isGrouped, let channel else { return members[0].id }
        let anchor = members.min { ($0.start, $0.id) < ($1.start, $1.id) }!
        return "timeline-session:" + anchor.dayKey + ":" + channel.rawValue + ":" + anchor.id
    }
    /// The observed range is NOT focused time and must not be added as a duration statistic.
    public var start: Date { members.map(\.start).min()! }
    public var end: Date { members.map(\.end).max()! }
    public var latestObserved: Date { members.map(\.latestObserved).max()! }
    public var label: String { displayAppName ?? conversation.map { "Texts with " + $0 } ?? channel?.label ?? "Activity" }
}

/// Pure geometry rule shared by the timeline and console checks. A selected/expanded child
/// already on screen takes priority; an offscreen child never drags the viewport to its position.
public enum TimelineVisibleAnchor {
    public static func select(frames: [String: CGRect], visible: CGRect, preferredIDs: [String],
                              previousID: String? = nil, examined: ((Int) -> Void)? = nil) -> (id: String, offset: CGFloat)? {
        guard visible.minY > 0.5 else { return nil }
        func onScreen(_ frame: CGRect) -> Bool { frame.maxY > visible.minY + 0.5 && frame.minY < visible.maxY }
        var visits = 0
        for id in preferredIDs {
            visits += 1
            if let frame = frames[id], onScreen(frame) { examined?(visits); return (id, frame.minY - visible.minY) }
        }
        // Scroll notifications usually move a few pixels. Any still-visible anchor preserves the
        // viewport, so keep it until it leaves rather than scanning every eagerly laid-out row per tick.
        if let id = previousID {
            visits += 1
            if let frame = frames[id], onScreen(frame) { examined?(visits); return (id, frame.minY - visible.minY) }
        }
        // Eligible singletons carry both their original child frame and a stable presentation
        // frame. Prefer the latter at the same position so a later collapsed group keeps the anchor.
        func rank(_ id: String) -> Int { id.hasPrefix("timeline-section:") ? 0 : 1 }
        var best: (id: String, frame: CGRect)?
        for (id, frame) in frames {
            visits += 1
            guard onScreen(frame) else { continue }
            if best.map({ (frame.minY, rank(id), id) < ($0.frame.minY, rank($0.id), $0.id) }) ?? true { best = (id, frame) }
        }
        examined?(visits)
        return best.map { ($0.id, $0.frame.minY - visible.minY) }
    }
}

/// Cache only the presentation plan, never old summaries or typed details. Hover, selection and
/// writer callbacks can reuse membership/order while each result hydrates the current saved child.
public final class TimelineSessionLayoutCache<Detail> {
    private struct Input: Equatable {
        let id: String, day: String
        let start: Date, end: Date, latest: Date
        let channel: TimelineSessionChannel?
        let displayAppID: String?, displayAppName: String?
        let conversation: String?
        let alias: Bool
    }
    private struct Plan {
        let channel: TimelineSessionChannel?
        let id: String?, conversation: String?
        let displayAppID: String?, displayAppName: String?
        let memberIDs: [String]
    }
    private var previous: [Input] = []
    private var section: String?
    private var plans: [Plan] = []
    /// Counts describe work only; no private content is logged by this cache.
    public private(set) var builds = 0
    public private(set) var hits = 0
    public init() {}

    public func sessions(_ members: [TimelineSessionMember<Detail>], sectionID: String) -> [TimelineSession<Detail>] {
        let inputs = members.map { Input(id: $0.id, day: $0.dayKey, start: $0.start, end: $0.end,
                                        latest: $0.latestObserved, channel: $0.channel,
                                        displayAppID: $0.displayAppID, displayAppName: $0.displayAppName,
                                        conversation: $0.conversation, alias: $0.allowsGenericAlias) }
        if section != sectionID || inputs != previous {
            plans = TimelineSessionGrouping.group(members, withinSection: true, sectionID: sectionID).map {
                Plan(channel: $0.channel, id: $0.presentationID, conversation: $0.conversation,
                     displayAppID: $0.displayAppID, displayAppName: $0.displayAppName, memberIDs: $0.members.map(\.id))
            }
            previous = inputs; section = sectionID; builds += 1
        } else { hits += 1 }
        let current = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return plans.map { plan in
            TimelineSession(channel: plan.channel, members: plan.memberIDs.compactMap { current[$0] },
                            presentationID: plan.id, conversation: plan.conversation,
                            displayAppID: plan.displayAppID, displayAppName: plan.displayAppName)
        }
    }
}

public enum TimelineSessionGrouping {
    /// Five minutes is a conservative display heuristic, not a measured ideal session cutoff.
    /// A de-identified fixture derived from observed interval relationships groups identically at 1, 5, and 30 minutes.
    public static let nearbyGap: TimeInterval = 5 * 60

    /// No saved records, summaries, identities, or source order are rewritten. The caller should
    /// invoke this within one existing timeline section so groups cannot cross section boundaries.
    public static func group<Detail>(_ members: [TimelineSessionMember<Detail>],
                                     maximumGap: TimeInterval = nearbyGap,
                                     withinSection: Bool = false, sectionID: String = "") -> [TimelineSession<Detail>] {
        if withinSection { return sectionGroups(members, sectionID: sectionID) }
        let gap = maximumGap.isFinite ? max(0, maximumGap) : nearbyGap
        var buckets: [String: [Int]] = [:]
        var runs: [[Int]] = []
        for (index, member) in members.enumerated() {
            guard let channel = member.channel, member.end >= member.start else {
                runs.append([index]); continue
            }
            buckets[member.dayKey + "\u{0}" + channel.rawValue, default: []].append(index)
        }
        for indices in buckets.values {
            let ordered = indices.sorted {
                (members[$0].start, members[$0].end, $0) < (members[$1].start, members[$1].end, $1)
            }
            var run: [Int] = []
            var observedEnd: Date?
            for index in ordered {
                let member = members[index]
                if let end = observedEnd, member.start.timeIntervalSince(end) > gap {
                    runs.append(run); run = []; observedEnd = nil
                }
                run.append(index)
                observedEnd = max(observedEnd ?? member.end, member.end)
            }
            if !run.isEmpty { runs.append(run) }
        }
        // Position each container where its newest/input-first member was; preserve child order.
        return runs.sorted { $0.min()! < $1.min()! }.map { indices in
            let originals = indices.sorted().map { members[$0] }
            return TimelineSession(channel: originals[0].channel, members: originals)
        }
    }

    /// The caller supplies one existing block/loose section. Exact identity, not proximity or a
    /// summary topic, determines its cards. App containers preserve conversation identity on children;
    /// legacy channel-only callers retain the narrow Messages alias rule.
    private static func sectionGroups<Detail>(_ members: [TimelineSessionMember<Detail>], sectionID: String) -> [TimelineSession<Detail>] {
        func identity(_ member: TimelineSessionMember<Detail>) -> String? {
            guard member.channel == .messages, let name = member.conversation?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            return name.lowercased()
        }
        var names: [String: [String: String]] = [:]
        for member in members {
            if let key = identity(member), let name = member.conversation {
                // Choose a deterministic display spelling, independent of input/callback order.
                names[member.dayKey, default: [:]][key] = min(names[member.dayKey]?[key] ?? name, name)
            }
        }
        func token(_ text: String) -> String { "\(text.utf8.count):" + text }
        var buckets: [String: [TimelineSessionMember<Detail>]] = [:]
        var labels: [String: String] = [:]
        var appIDs: [String: String] = [:], appNames: [String: String] = [:]
        for member in members {
            if let appID = member.displayAppID, !appID.isEmpty, member.end >= member.start {
                // Fold the app's display rows inside this one bracket. Every original
                // conversation, draft, source action and full detail remains its own child.
                let key = "timeline-section:app:" + token(sectionID) + token(member.dayKey) + token(appID)
                buckets[key, default: []].append(member); appIDs[key] = appID
                if let name = member.displayAppName, !name.isEmpty {
                    appNames[key] = min(appNames[key] ?? name, name)
                }
                continue
            }
            guard let channel = member.channel, member.end >= member.start,
                  channel != .messages || identity(member) != nil || member.allowsGenericAlias else {
                buckets["original:" + token(member.id)] = [member]; continue
            }
            let known = names[member.dayKey] ?? [:]
            let person = channel == .messages ? (identity(member) ?? (known.count == 1 ? known.keys.first : nil)) : nil
            let key = "timeline-section:" + token(sectionID) + token(member.dayKey) + token(channel.rawValue) + token(person ?? "")
            buckets[key, default: []].append(member)
            labels[key] = person.flatMap { known[$0] }
        }
        return buckets.map { key, children in
            let ordered = children.sorted { ($0.latestObserved, $0.start, $0.id) > ($1.latestObserved, $1.start, $1.id) }
            return TimelineSession(channel: appIDs[key] == nil ? ordered[0].channel : nil, members: ordered,
                                   presentationID: key, conversation: labels[key],
                                   displayAppID: appIDs[key], displayAppName: appNames[key])
        }.sorted { ($0.latestObserved, $0.id) > ($1.latestObserved, $1.id) }
    }
}
