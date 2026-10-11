import Foundation

// DayDream recording timeline, schema v1 (scripts/harness/README.md has the full field list).
//
// A timeline is a fabricated stretch of someone's day at the Mac: which app is in front, which window or Chrome tab,
// when they type (with backspaces), click, take a break, pause DayDream, quit and reopen it, when the Mac sleeps or the
// screen locks, how DayDream was launched (by the person, at login, after an update), and whether the microphone is in
// use. Every timeline says `"synthetic": true`; nothing in one comes from a real person's history.
//
// Pure Foundation: compiled into the oracle self-test (no app code) and into the drivers (CaptureDriver, the APP flows).

struct HarnessError: Error, CustomStringConvertible { let description: String; init(_ d: String) { description = d } }

/// One timeline (`scripts/fixtures/flows/*.json`).
struct Timeline: Decodable {
    static let schemaV1 = "daydream-timeline/1"
    /// "daydream-timeline/1".
    let schema: String
    /// Must be true: every timeline is made up.
    let synthetic: Bool
    let name: String
    /// What real flow this replays and why (the owner's QA rule it follows).
    let about: String
    /// Wall time of offset 0, ISO 8601 with its offset ("2026-10-06T09:00:00-05:00").
    let start: String
    /// IANA zone the minute labels are written in ("America/Chicago").
    let timeZone: String
    /// How this history began: a fresh install or an upgrade from an earlier build (bug 13).
    var install: TimelineInstall?
    let events: [TimelineEvent]
    /// What the replay must find in the scratch store (CaptureDriver's checks; optional per field).
    var expect: TimelineExpect?

    /// The wall clock at offset 0.
    var startDate: Date {
        get throws {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
            guard let d = f.date(from: start) else { throw HarnessError("\(name): start \(start) is not ISO 8601 with an offset") }
            return d
        }
    }
    var zone: TimeZone { get throws { guard let z = TimeZone(identifier: timeZone) else { throw HarnessError("\(name): unknown zone \(timeZone)") }; return z } }
    /// The last instant the timeline covers (its last event, after the typing it holds).
    var end: Double { events.map { $0.at + $0.duration }.max() ?? 0 }

    static func load(_ url: URL) throws -> Timeline {
        let t = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: url))
        try t.validate()
        return t
    }

    /// Refuses anything the drivers can't replay faithfully, before a store is made.
    func validate() throws {
        guard schema == Self.schemaV1 else { throw HarnessError("\(name): schema \(schema), want \(Self.schemaV1)") }
        guard synthetic else { throw HarnessError("\(name): only timelines marked synthetic are replayed") }
        _ = try startDate; _ = try zone
        guard let first = events.first, first.op == .launch else { throw HarnessError("\(name): the first event must be a launch") }
        var busyUntil = 0.0, running = false
        for (i, e) in events.enumerated() {
            guard e.at.isFinite, e.at >= 0 else { throw HarnessError("\(name) event \(i): at \(e.at) is not a time") }
            guard e.at >= busyUntil - 1e-9 else {
                throw HarnessError("\(name) event \(i) (\(e.op.rawValue)) at \(e.at) starts before the one before it ends (\(busyUntil))")
            }
            busyUntil = e.at + e.duration
            switch e.op {
            case .launch: guard !running else { throw HarnessError("\(name) event \(i): launch while running") }; running = true
                guard e.how != nil else { throw HarnessError("\(name) event \(i): launch needs how") }
            case .quit: guard running else { throw HarnessError("\(name) event \(i): quit while not running") }; running = false
            default: guard running else { throw HarnessError("\(name) event \(i): \(e.op.rawValue) while DayDream is not running") }
            }
            switch e.op {
            case .front: guard e.app != nil, e.bundle != nil else { throw HarnessError("\(name) event \(i): front needs app and bundle") }
            case .tab: guard e.url != nil, e.title != nil else { throw HarnessError("\(name) event \(i): tab needs url and title") }
            case .type: guard let t = e.text, !t.isEmpty else { throw HarnessError("\(name) event \(i): type needs text") }
            case .backspace: guard (e.count ?? 0) > 0 else { throw HarnessError("\(name) event \(i): backspace needs a count") }
            case .mic: guard e.on != nil else { throw HarnessError("\(name) event \(i): mic needs on") }
            case .hold: guard let s = e.seconds, s > 0, s <= 30 else { throw HarnessError("\(name) event \(i): hold needs seconds (0, 30]") }
            default: break
            }
        }
    }
}

struct TimelineInstall: Decodable {
    /// "fresh": a new history (setup's defaults). "upgrade": a history an earlier build saved, with `choices`.
    let kind: String
    /// The earlier build's version ("0.1.7 Beta (20261001120000)"), for an upgrade.
    var from: String?
    /// The person's own choices on record before the upgrade (nil: never chose; the build's defaults apply).
    var messagesAndEmail: Bool?
    var typing: Bool?
}

/// One thing that happens. `at` is seconds after `start`; typing takes `duration` seconds from `at`.
struct TimelineEvent: Decodable {
    enum Op: String, Decodable {
        case launch, quit, record, front, window, tab, focus, type, backspace, key, input, mic
        case sleep, wake, lock, unlock, pause, resume, writer, hold
    }
    let at: Double
    let op: Op
    /// launch: "opened" (Finder, Dock, Spotlight), "login" (a login item), "no-open-event" (no Apple event read),
    /// "self-relaunch" (Quit & Reopen, the Input Monitoring restart), "update-relaunch" (Sparkle's relaunch).
    var how: String?
    /// launch: this build's version ("0.1.8 Beta (20261008120000)").
    var version: String?
    /// front: the app in front.
    var app: String?
    var bundle: String?
    /// front/window/tab: the window (an id the fixture makes up), its title.
    var window: String?
    var title: String?
    /// tab: Chrome's tab id and the page address.
    var tab: String?
    var url: String?
    /// focus: the focused field (an id the fixture makes up), and a Messages conversation name.
    var field: String?
    var place: String?
    /// type: the characters typed, one key each at `cps` keys a second (default 8).
    var text: String?
    var cps: Double?
    /// backspace: how many.
    var count: Int?
    /// key: "return" or "tab" (never a send: the flows type no message they send).
    var key: String?
    /// mic: in use or not. input: "click" or "move".
    var on: Bool?
    var kind: String?
    /// pause: a timed pause's length in seconds (nil: until resumed). hold: how long the Mac holds DayDream's main
    /// thread (App Nap while the display sleeps, a busy disk): no timer and no heartbeat runs for `seconds` (at most
    /// 30), and the replay waits that long in real time, since the store's 5 s heartbeat limit is real time.
    var seconds: Double?

    static let defaultCPS = 8.0
    var keys: Int {
        switch op {
        case .type: return text?.count ?? 0
        case .backspace: return count ?? 0
        case .key: return 1
        default: return 0
        }
    }
    /// Seconds the event takes: its own keys (the first key lands at `at`), or a hold.
    var duration: Double {
        if op == .hold { return seconds ?? 0 }
        return keys > 1 ? Double(keys - 1) / (cps ?? Self.defaultCPS) : 0
    }
    /// When each key lands.
    var keyTimes: [Double] { (0..<keys).map { at + Double($0) / (cps ?? Self.defaultCPS) } }
}

/// What a replay must find. Every field is optional; the flow check says which it checked.
struct TimelineExpect: Decodable {
    /// The typed rows, in order: the app's bundle and the exact words a person sees.
    var typed: [ExpectedTyped]?
    /// The Chrome page rows' titles, in order.
    var pages: [String]?
    /// Words that must never be saved anywhere (a backspaced typo, a secret).
    var never: [String]?
    /// usage counts the launches made (app_opened "how" values, app_updated from/to).
    var opened: [String]?
    var updated: [[String]]?
    /// Whether recording is on when the timeline ends.
    var recordingAtEnd: Bool?
}
struct ExpectedTyped: Decodable, Equatable {
    let bundle: String
    let words: String
}
