import AppKit
import MemoryCore

/// Anonymous usage counts, sent to PostHog (Settings › Advanced › "Share anonymous usage counts", on by default).
///
/// - What: only the events and properties in `UsageCounts` (MemoryCore), checked again by `UsageCounts.allowed` before
///   anything is queued. Never a title, typed word, site, search, path, name or anything else from the history.
/// - Who: a random install ID (`installID`, a UUID made once and kept in DayDream's preferences), never derived from
///   the Mac, the user name or an account. It is PostHog's `distinct_id`.
/// - When: about once an hour, in batches, with no cookies, cache or redirects. A failure is silent and tried again an
///   hour later; the queue keeps at most `queueCap` events, dropping the oldest. Not at quit (a request then would
///   hold up quitting); what is still queued goes at the next launch.
/// - Off: turning the switch off cancels a send in flight, drops the queue and removes the MCP helper's inbox.
/// - Never from a test or development build (`buildMaySend`), and never without a project key (`projectKey`).
@MainActor final class UsageSender: ObservableObject {
    static let shared = UsageSender()
    static let enabledKey = "DaydreamUsageSharing"
    static let installIDKey = "DaydreamUsageInstallID"
    static let endpoint = URL(string: "https://us.i.posthog.com/batch/")!
    static let queueCap = 500
    static let batchMax = 100
    static let recentCap = 20
    static let sendEvery: TimeInterval = 3600
    static let firstSendAfter: TimeInterval = 120
    nonisolated static let queueFile = "usage-queue.json"

    /// The PostHog project API key (`phc_…`): packaging/Info.plist's `DDPostHogKey`. Empty: nothing is ever sent
    /// (events still queue for "See what's sent").
    nonisolated static var projectKey: String {
        ((Bundle.main.object(forInfoDictionaryKey: "DDPostHogKey") as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Test and development builds never send: debug builds, the source checks, the QA harness and the live tests, and
    /// any copy that isn't the released app (another bundle id, or a development trial).
    nonisolated static var buildMaySend: Bool {
        #if DEBUG || DEVELOPMENT_SOURCE_CHECKS || DAYDREAM_QA_HARNESS || DAYDREAM_LIVETEST
        return false
        #else
        return Bundle.main.bundleIdentifier == DaydreamIdentity.bundleID
            && Bundle.main.object(forInfoDictionaryKey: "DaydreamDevelopmentTrial") as? Bool != true
        #endif
    }
    nonisolated static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
    }

    struct Recent: Codable, Equatable { var event: UsageEvent; var sent: Bool }
    private struct Saved: Codable { var pending: [UsageEvent]; var recent: [Recent] }

    @Published private(set) var enabled: Bool
    /// The last `recentCap` events, newest first, queued or sent ("See what's sent").
    @Published private(set) var recent: [Recent] = []
    private var pending: [UsageEvent] = []
    private(set) var home: URL?
    private var timer: Timer?
    private var inFlight: URLSessionDataTask?
    private let defaults: UserDefaults
    private let saveQueue = DispatchQueue(label: "DayDream.usage-save", qos: .utility)
    private var saveScheduled = false
    private var quitObserver: NSObjectProtocol?
    /// Waiting to be sent, and whether a send is in flight (the checks read these).
    var queuedCount: Int { pending.count }
    var sending: Bool { inFlight != nil }
    /// Runs each hour, before a send (`UsageReport`: the daily check and the MCP helper's inbox).
    var beforeSend: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// The random install ID, made the first time it is asked for. `made`: it was made now.
    var installID: String { ensureInstallID().id }
    @discardableResult func ensureInstallID() -> (id: String, made: Bool) {
        if let id = defaults.string(forKey: Self.installIDKey), UUID(uuidString: id) != nil { return (id, false) }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Self.installIDKey)
        return (id, true)
    }

    /// The app's history folder is open: read what was queued, and send about once an hour.
    func start(home: URL) {
        guard self.home == nil else { return }
        self.home = home
        if let data = try? Data(contentsOf: home.appendingPathComponent(Self.queueFile)), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            pending = Array(saved.pending.filter(UsageCounts.allowed).suffix(Self.queueCap)); recent = Array(saved.recent.prefix(Self.recentCap))
        }
        if enabled { UsageInbox.create(home: home) } else { UsageInbox.remove(home: home); pending = []; save() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstSendAfter) { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        timer = Timer.scheduledTimer(withTimeInterval: Self.sendEvery, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.write(wait: true) }
        }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        if on {
            if let home { UsageInbox.create(home: home) }
        } else {
            inFlight?.cancel(); inFlight = nil
            pending = []
            recent.removeAll { !$0.sent }
            if let home { UsageInbox.remove(home: home) }
        }
        save()
    }

    /// Queues one event, with nothing but allowed keys and words (anything else is dropped here).
    func record(_ name: String, _ properties: [String: UsageValue] = [:], at date: Date = Date()) {
        add([UsageEvent(name, at: date, properties)])
    }
    func add(_ events: [UsageEvent]) {
        let events = events.filter(UsageCounts.allowed)
        guard enabled, home != nil, !events.isEmpty else { return }
        pending.append(contentsOf: events)
        if pending.count > Self.queueCap { pending.removeFirst(pending.count - Self.queueCap) }
        recent = Array((events.reversed().map { Recent(event: $0, sent: false) } + recent).prefix(Self.recentCap))
        save()
    }

    private func tick() {
        beforeSend?()
        send()
    }

    /// One batch: the oldest `batchMax` queued events. Sent ones leave the queue; on any failure they stay for the next hour.
    func send() {
        let key = Self.projectKey
        guard enabled, Self.buildMaySend, !key.isEmpty, inFlight == nil, !pending.isEmpty else { return }
        let batch = Array(pending.prefix(Self.batchMax))
        guard let body = try? JSONSerialization.data(withJSONObject: Self.payload(key: key, id: installID, events: batch)) else { return }
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 35
        let session = URLSession(configuration: config, delegate: UsageNoRedirects(), delegateQueue: nil)
        let task = session.dataTask(with: request) { [weak self] _, response, error in
            let ok = error == nil && ((response as? HTTPURLResponse)?.statusCode).map { (200..<300).contains($0) } == true
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.sent(batch, ok: ok) } }
        }
        inFlight = task
        task.resume()
    }

    private func sent(_ batch: [UsageEvent], ok: Bool) {
        inFlight = nil
        guard ok, enabled else { return }
        // The queue changed meanwhile (sharing turned off and on, or the cap dropped the oldest): remove what was sent.
        if pending.starts(with: batch) { pending.removeFirst(batch.count) } else { pending.removeAll { batch.contains($0) } }
        for index in recent.indices where batch.contains(recent[index].event) { recent[index].sent = true }
        save()
    }

    /// PostHog's batch body. Each event: its name, the install ID, its time and its properties, plus the properties every
    /// event carries: no GeoIP lookup, no IP, the library name and DayDream's version.
    nonisolated static func payload(key: String, id: String, events: [UsageEvent]) -> [String: Any] {
        ["api_key": key, "historical_migration": false, "batch": events.map { wire($0, id: id) }]
    }
    nonisolated static func wire(_ event: UsageEvent, id: String) -> [String: Any] {
        var properties = event.properties.mapValues(\.json)
        properties["$geoip_disable"] = true
        properties["$ip"] = NSNull()
        properties["$lib"] = "daydream"
        properties["app_version"] = appVersion
        return ["event": event.name, "distinct_id": id, "timestamp": event.at, "properties": properties]
    }
    /// "See what's sent": one entry as it is (or will be) sent, as pretty JSON.
    func json(_ entry: Recent) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: Self.wire(entry.event, id: installID), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Saves once per turn of the main queue, however many events arrived, off the main thread; at quit, at once.
    private func save() {
        guard home != nil, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.write(wait: false) } }
    }
    private func write(wait: Bool) {
        saveScheduled = false
        guard let home else { return }
        let saved = Saved(pending: pending, recent: recent)
        let work = {
            guard let data = try? JSONEncoder().encode(saved) else { return }
            try? data.write(to: home.appendingPathComponent(Self.queueFile), options: [.atomic])
        }
        if wait { saveQueue.sync(execute: work) } else { saveQueue.async(execute: work) }
    }
}

private final class UsageNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
