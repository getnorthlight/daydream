// DD-RECIPE: PURE (scripts/harness/Timeline.swift + scripts/harness/Oracles.swift, Foundation only)
// The 0.2.0 oracles' own cases: expectedSamples (one row a minute: front app, seconds since the last input, mic in use)
// and expectedSessionEvents (sleep, lock and pause start/end, closed on quit, never overlapping), the timeline
// validator, and the read-back comparison the 0.2.0 adapter will be held to. Every timeline here is made up in code;
// nothing reads a store, a clock or the Mac.
import Foundation

var passed = 0, failed = 0
func check(_ ok: Bool, _ label: String, _ got: @autoclosure () -> String = "") {
    print(ok ? "PASS [oracle] \(label)" : "FAIL [oracle] \(label) :: \(got())")
    if ok { passed += 1 } else { failed += 1 }
}

/// A timeline from a few lines: (at, op, fields).
func timeline(_ name: String, start: String = "2026-10-06T09:00:00-05:00", zone: String = "America/Chicago",
              _ events: [[String: Any]]) -> Timeline {
    let json: [String: Any] = ["schema": Timeline.schemaV1, "synthetic": true, "name": name, "about": "oracle self-test",
                               "start": start, "timeZone": zone, "events": events]
    return try! JSONDecoder().decode(Timeline.self, from: JSONSerialization.data(withJSONObject: json))
}
func ev(_ at: Double, _ op: String, _ fields: [String: Any] = [:]) -> [String: Any] { fields.merging(["at": at, "op": op]) { $1 } }
let notes = ["app": "Notes", "bundle": "com.apple.Notes"]
let chrome = ["app": "Google Chrome", "bundle": "com.google.Chrome"]
func kinds(_ rows: [SessionEventRow]) -> String { rows.map(\.description).joined(separator: " ") }

@main enum FlowOracleChecks {
    static func main() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        // 1. Recording never turned on: no samples, no session rows.
        do {
            let t = timeline("off", [ev(0, "launch", ["how": "opened"]), ev(5, "front", notes), ev(10, "type", ["text": "hello"]), ev(300, "front", chrome)])
            check(try RecordingOracle.expectedSamples(t).isEmpty && RecordingOracle.expectedSessionEvents(t).isEmpty,
                  "recording off: no sample and no session row")
        }
        // 2. Three minutes of recording from 09:00:00: a row at 09:00, 09:01, 09:02, 09:03 (the start minute counts).
        do {
            let t = timeline("basic", [ev(0, "launch", ["how": "opened"]), ev(0, "record"), ev(5, "front", notes),
                                       ev(70, "type", ["text": "cedar"]), ev(180, "input", ["kind": "click"])])
            let s = try RecordingOracle.expectedSamples(t)
            check(s.map(\.minute) == ["2026-10-06T09:00-05:00", "2026-10-06T09:01-05:00", "2026-10-06T09:02-05:00", "2026-10-06T09:03-05:00"],
                  "one sample row a minute, labelled in the timeline's zone", s.map(\.minute).joined(separator: ","))
            check(s[0].bundle == nil && s[1].bundle == "com.apple.Notes", "the front app is the one in front at that minute", "\(s)")
            // Notes came forward at 5 s (an input); the last key of "cedar" lands at 70.5 s.
            check(s.map(\.secondsSinceInput) == [nil, 55, 49, 0], "seconds since the last input, keys and switches included", "\(s.map(\.secondsSinceInput))")
        }
        // 3. Input counted per key: typing at 8 keys a second, the last key's time counts.
        do {
            let t = timeline("keys", [ev(0, "launch", ["how": "opened"]), ev(0, "record"), ev(1, "front", notes),
                                      ev(50, "type", ["text": String(repeating: "a", count: 81)])])  // 50 s .. 60 s
            let s = try RecordingOracle.expectedSamples(t)
            check(s.last?.secondsSinceInput == 0 && t.events.last!.duration == 10, "a key at the minute itself counts (0 s since input)", "\(s)")
        }
        // 4. Midnight: rows continue across it, the label's day changes, 60 s apart.
        do {
            let t = timeline("midnight", start: "2026-10-06T23:58:30-05:00", [ev(0, "launch", ["how": "opened"]), ev(0, "record"),
                                                                                 ev(1, "front", notes), ev(240, "input", ["kind": "move"])])
            let s = try RecordingOracle.expectedSamples(t)
            check(s.map(\.minute) == ["2026-10-06T23:59-05:00", "2026-10-07T00:00-05:00", "2026-10-07T00:01-05:00", "2026-10-07T00:02-05:00"],
                  "a midnight crossing keeps one row a minute and moves the day", s.map(\.minute).joined(separator: ","))
            check(zip(s, s.dropFirst()).allSatisfy { $1.at - $0.at == 60 }, "rows across midnight are 60 s apart")
        }
        // 5. DST spring forward (America/Chicago, 2026-03-08 02:00 -> 03:00): no gap in real time, the labels skip the hour.
        do {
            let t = timeline("spring", start: "2026-03-08T01:58:00-06:00", [ev(0, "launch", ["how": "opened"]), ev(0, "record"),
                                                                           ev(1, "front", notes), ev(300, "input", ["kind": "move"])])
            let s = try RecordingOracle.expectedSamples(t)
            check(s.count == 6 && s.map(\.minute) == ["2026-03-08T01:58-06:00", "2026-03-08T01:59-06:00", "2026-03-08T03:00-05:00",
                                                      "2026-03-08T03:01-05:00", "2026-03-08T03:02-05:00", "2026-03-08T03:03-05:00"],
                  "DST spring forward: 6 rows for 5 real minutes, 01:59 then 03:00", s.map(\.minute).joined(separator: ","))
        }
        // 6. DST fall back (2026-11-01 02:00 -> 01:00): the 01:xx labels repeat with the other offset; one row per real minute.
        do {
            let t = timeline("fall", start: "2026-11-01T01:59:00-05:00", [ev(0, "launch", ["how": "opened"]), ev(0, "record"),
                                                                         ev(1, "front", notes), ev(120, "input", ["kind": "move"])])
            let s = try RecordingOracle.expectedSamples(t)
            check(s.map(\.minute) == ["2026-11-01T01:59-05:00", "2026-11-01T01:00-06:00", "2026-11-01T01:01-06:00"],
                  "DST fall back: the hour repeats with its own offset, no row dropped or doubled", s.map(\.minute).joined(separator: ","))
            check(Set(s.map(\.minute)).count == s.count, "fall-back labels stay unique with their offsets")
        }
        // 7. Sleep across a minute boundary: no row while asleep; the first row after waking.
        do {
            let t = timeline("sleep-boundary", [ev(0, "launch", ["how": "opened"]), ev(0, "record"), ev(1, "front", notes),
                                                ev(50, "sleep"), ev(130, "wake"), ev(150, "input", ["kind": "click"]), ev(200, "input", ["kind": "click"])])
            let s = try RecordingOracle.expectedSamples(t)
            check(s.map(\.at) == [0, 180], "sleep from 0:50 to 2:10 drops the 1:00 and 2:00 rows", "\(s.map(\.at))")
            let e = try RecordingOracle.expectedSessionEvents(t)
            check(e == [SessionEventRow(kind: .sleep, start: 50, end: 130, endedBy: "wake")], "a sleep is one row, ended by the wake", kinds(e))
        }
        // 8. Events exactly on the minute take effect first: a sleep at 60 drops that row; a wake at 120 keeps its row.
        do {
            let t = timeline("on-boundary", [ev(0, "launch", ["how": "opened"]), ev(0, "record"), ev(1, "front", notes),
                                             ev(60, "sleep"), ev(120, "wake"), ev(125, "input", ["kind": "move"])])
            check(try RecordingOracle.expectedSamples(t).map(\.at) == [0, 120], "a sleep or wake at the minute itself decides that row")
        }
        // 9. Lock during a pause: the pause is cut where the lock starts and picks up again after the unlock.
        do {
            let t = timeline("lock-in-pause", [ev(0, "launch", ["how": "opened"]), ev(0, "record"), ev(1, "front", notes), ev(10, "pause"),
                                               ev(20, "lock"), ev(30, "unlock"), ev(40, "resume"), ev(100, "input", ["kind": "move"])])
            let e = try RecordingOracle.expectedSessionEvents(t)
            check(e == [SessionEventRow(kind: .pause, start: 10, end: 20, endedBy: "lock"), SessionEventRow(kind: .lock, start: 20, end: 30, endedBy: "unlock"),
                        SessionEventRow(kind: .pause, start: 30, end: 40, endedBy: "resume")],
                  "lock during a pause: pause, lock, pause, never two open at once", kinds(e))
            check(try RecordingOracle.expectedSamples(t).map(\.at) == [0, 60], "no sample while paused or locked")
        }
        // 10. Quit while locked: the lock row closes at the quit; reopened behind the lock, a new lock row until the unlock.
        do {
            let t = timeline("quit-locked", [ev(0, "launch", ["how": "opened"]), ev(0, "record"), ev(1, "front", notes), ev(30, "lock"),
                                             ev(45, "quit"), ev(90, "launch", ["how": "login"]), ev(150, "unlock"), ev(200, "input", ["kind": "move"])])
            let e = try RecordingOracle.expectedSessionEvents(t)
            check(e == [SessionEventRow(kind: .lock, start: 30, end: 45, endedBy: "quit"), SessionEventRow(kind: .lock, start: 90, end: 150, endedBy: "unlock")],
                  "quit while locked closes the lock row; a launch behind the lock opens another", kinds(e))
            check(try RecordingOracle.expectedSamples(t).map(\.at) == [0, 180], "no sample while quit or locked")
        }
        // 11. Mic in use across a sleep: on before, nothing during, still on after (the call goes on).
        do {
            let t = timeline("mic-sleep", [ev(0, "launch", ["how": "opened"]), ev(0, "record"), ev(1, "front", notes), ev(2, "mic", ["on": true]),
                                           ev(70, "sleep"), ev(170, "wake"), ev(200, "mic", ["on": false]), ev(250, "input", ["kind": "move"])])
            let s = try RecordingOracle.expectedSamples(t)
            check(s.map(\.at) == [0, 60, 180, 240] && s.map(\.micInUse) == [false, true, true, false], "mic in use is kept across a sleep",
                  "\(s.map { "\($0.at):\($0.micInUse)" })")
        }
        // 12. Lock, then the Mac sleeps behind the lock, wakes to the lock screen, unlock: lock, sleep, lock.
        do {
            let t = timeline("lock-sleep", [ev(0, "launch", ["how": "opened"]), ev(0, "record"), ev(1, "front", notes), ev(10, "lock"),
                                            ev(40, "sleep"), ev(400, "wake"), ev(420, "unlock")])
            let e = try RecordingOracle.expectedSessionEvents(t)
            check(e.map(\.kind) == [.lock, .sleep, .lock] && e.map(\.endedBy) == ["sleep", "wake", "unlock"] && RecordingOracle.overlaps(e).isEmpty,
                  "a sleep behind the lock hides it and the lock shows again after the wake", kinds(e))
        }
        // 13. A timed pause ends by itself at its time.
        do {
            let t = timeline("timed-pause", [ev(0, "launch", ["how": "opened"]), ev(0, "record"), ev(1, "front", notes),
                                             ev(30, "pause", ["seconds": 900]), ev(1000, "input", ["kind": "move"])])
            let e = try RecordingOracle.expectedSessionEvents(t)
            check(e == [SessionEventRow(kind: .pause, start: 30, end: 930, endedBy: "timed-pause-end")], "a 15-minute pause ends by itself", kinds(e))
            check(try RecordingOracle.expectedSamples(t).map(\.at) == [0, 960], "no sample during the timed pause")
        }
        // 14. A pause kept across Quit and reopen (the launch intent): closed at quit, open again at the launch.
        do {
            let t = timeline("pause-quit", [ev(0, "launch", ["how": "opened"]), ev(0, "record"), ev(1, "front", notes), ev(20, "pause"),
                                            ev(40, "quit"), ev(50, "launch", ["how": "opened"]), ev(80, "resume")])
            let e = try RecordingOracle.expectedSessionEvents(t)
            check(e == [SessionEventRow(kind: .pause, start: 20, end: 40, endedBy: "quit"), SessionEventRow(kind: .pause, start: 50, end: 80, endedBy: "resume")],
                  "a pause is closed on quit and open again at the next launch", kinds(e))
        }
        // 15. Still open at the end of the timeline: one open row, last.
        do {
            let t = timeline("open-end", [ev(0, "launch", ["how": "opened"]), ev(0, "record"), ev(1, "front", notes), ev(20, "lock")])
            let e = try RecordingOracle.expectedSessionEvents(t)
            check(e == [SessionEventRow(kind: .lock, start: 20, end: nil, endedBy: nil)], "an interval still open at the end is the last row, open", kinds(e))
        }
        // 16. Recording turned off ends what was open; no row while off.
        do {
            let t = timeline("record-off", [ev(0, "launch", ["how": "opened"]), ev(0, "record"), ev(1, "front", notes), ev(10, "pause"),
                                            ev(20, "record", ["on": false]), ev(30, "lock"), ev(40, "unlock")])
            let e = try RecordingOracle.expectedSessionEvents(t)
            check(e == [SessionEventRow(kind: .pause, start: 10, end: 20, endedBy: "recording-off")], "recording off closes the open row and opens none", kinds(e))
        }
        // 17. A lock and a sleep at the same instant: one sleep row, no zero-length lock row.
        do {
            let t = timeline("same-instant", [ev(0, "launch", ["how": "opened"]), ev(0, "record"), ev(1, "front", notes), ev(30, "lock"), ev(30, "sleep"),
                                              ev(90, "wake"), ev(95, "unlock")])
            let e = try RecordingOracle.expectedSessionEvents(t)
            check(e.map(\.kind) == [.sleep, .lock] && e[0].start == 30 && e[1].start == 90, "events at one instant make one decision", kinds(e))
        }
        // 18. Never overlapping, over a long made-up mix (a fixed pseudo-random sequence of the owner's flows).
        do {
            var g = UInt64(0x5eed), at = 2.0
            func next(_ n: UInt64) -> UInt64 { g = g &* 6364136223846793005 &+ 1442695040888963407; return (g >> 33) % n }
            var evs: [[String: Any]] = [ev(0, "launch", ["how": "opened"]), ev(0, "record"), ev(1, "front", notes)]
            var asleep = false, locked = false, paused = false, running = true
            for _ in 0..<400 {
                at += Double(1 + next(400))
                let choice = next(9)
                if !running { evs.append(ev(at, "launch", ["how": next(2) == 0 ? "login" : "opened"])); running = true; continue }
                switch choice {
                case 0 where !asleep: evs.append(ev(at, "sleep")); asleep = true
                case 1 where asleep: evs.append(ev(at, "wake")); asleep = false
                case 2 where !locked && !asleep: evs.append(ev(at, "lock")); locked = true
                case 3 where locked && !asleep: evs.append(ev(at, "unlock")); locked = false
                case 4 where !paused && !asleep: evs.append(ev(at, "pause")); paused = true
                case 5 where paused && !asleep && !locked: evs.append(ev(at, "resume")); paused = false
                case 6 where !asleep: evs.append(ev(at, "quit")); running = false
                case 7 where !asleep && !locked: evs.append(ev(at, "mic", ["on": next(2) == 0]))
                default: if !asleep && !locked { evs.append(ev(at, "input", ["kind": "click"])) }
                }
            }
            let t = timeline("mix", evs)
            try t.validate()
            let e = try RecordingOracle.expectedSessionEvents(t)
            let s = try RecordingOracle.expectedSamples(t)
            check(e.count > 50 && RecordingOracle.overlaps(e).isEmpty, "\(e.count) rows over a long mix never overlap or run backwards",
                  RecordingOracle.overlaps(e).prefix(3).joined(separator: "; "))
            let inside = s.filter { row in e.contains { $0.start <= row.at && row.at < ($0.end ?? .infinity) } }
            check(inside.isEmpty && !s.isEmpty, "no sample falls inside a sleep, lock or pause row (\(s.count) samples)", "\(inside.prefix(3))")
        }
        // 19. The validator refuses what can't be replayed faithfully.
        do {
            func refused(_ events: [[String: Any]], synthetic: Bool = true, schema: String = Timeline.schemaV1) -> Bool {
                let json: [String: Any] = ["schema": schema, "synthetic": synthetic, "name": "bad", "about": "", "start": "2026-10-06T09:00:00-05:00",
                                           "timeZone": "America/Chicago", "events": events]
                guard let t = try? JSONDecoder().decode(Timeline.self, from: JSONSerialization.data(withJSONObject: json)) else { return true }
                return (try? t.validate()) == nil
            }
            let ok: [[String: Any]] = [ev(0, "launch", ["how": "opened"]), ev(1, "front", notes)]
            check(!refused(ok), "a plain timeline is accepted")
            check(refused(ok, synthetic: false), "a timeline not marked synthetic is refused")
            check(refused(ok, schema: "daydream-timeline/2"), "another schema version is refused")
            check(refused([ev(0, "launch", ["how": "opened"]), ev(5, "type", ["text": "abcdefghijklmnop"]), ev(6, "front", notes)]),
                  "an event that starts before the typing before it ends is refused")
            check(refused([ev(0, "launch", ["how": "opened"]), ev(5, "quit"), ev(6, "front", notes)]), "anything while DayDream is quit is refused")
            check(refused([ev(0, "front", notes)]), "a timeline that doesn't start with a launch is refused")
            check(refused([ev(0, "launch", ["how": "opened"]), ev(1, "teleport")]), "an unknown op is refused")
        }
        // 20. The read-back comparison the 0.2.0 adapter is held to.
        do {
            let t = timeline("compare", [ev(0, "launch", ["how": "opened"]), ev(0, "record"), ev(1, "front", notes), ev(30, "mic", ["on": true]),
                                         ev(100, "lock"), ev(160, "unlock"), ev(200, "input", ["kind": "click"])])
            let s = try RecordingOracle.expectedSamples(t), e = try RecordingOracle.expectedSessionEvents(t)
            let late = s.map { SampleRow(at: $0.at + 1, minute: $0.minute, bundle: $0.bundle, app: $0.app, secondsSinceInput: $0.secondsSinceInput.map { $0 + 1 }, micInUse: $0.micInUse) }
            check(RecordingRowsComparison.samples(expected: s, actual: late).isEmpty && RecordingRowsComparison.sessionEvents(expected: e, actual: e).isEmpty,
                  "rows a timer writes a second late still match")
            var wrong = s; wrong[1] = SampleRow(at: s[1].at, minute: s[1].minute, bundle: "com.example.other", app: "Other", secondsSinceInput: s[1].secondsSinceInput, micInUse: false)
            check(RecordingRowsComparison.samples(expected: s, actual: wrong).count == 2, "a wrong front app and mic are each reported")
            let overlapping = [SessionEventRow(kind: .lock, start: 100, end: 170, endedBy: "unlock"), SessionEventRow(kind: .pause, start: 160, end: 180, endedBy: "resume")]
            check(!RecordingRowsComparison.sessionEvents(expected: e, actual: overlapping).filter { $0.contains("overlap") }.isEmpty, "overlapping read-back rows are reported")
            let none = NoRecordingRowsYet()
            check(try !none.writesRows && none.sampleRows(timelineStart: Date()).isEmpty, "0.1.8 writes no sample or session rows yet (NoRecordingRowsYet)")
        }
        // 21. The shipped flow fixtures all load and their oracles hold the invariants.
        if CommandLine.arguments.count > 1 {
            let dir = URL(fileURLWithPath: CommandLine.arguments[1])
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
            var bad: [String] = []
            for f in files {
                do {
                    let t = try Timeline.load(f)
                    let e = try RecordingOracle.expectedSessionEvents(t)
                    if !RecordingOracle.overlaps(e).isEmpty { bad.append(f.lastPathComponent + ": overlapping rows") }
                    let s = try RecordingOracle.expectedSamples(t)
                    print("ORACLE \(t.name): \(s.count) samples, \(e.count) session rows \(kinds(e))")
                } catch { bad.append(f.lastPathComponent + ": \(error)") }
            }
            check(files.count >= 12 && bad.isEmpty, "\(files.count) flow fixtures load and their session rows never overlap", bad.joined(separator: "; "))
        }
        print("flow-oracle: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
