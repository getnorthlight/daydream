#!/usr/bin/env python3
"""Focused Foundation-only checks of shipped summary status/gating snippets.

Does not import AppKit, launch an app, access a store, or build the product. Core
note fields are small fixtures; the gating, label and count code comes verbatim
from TodayData. This is not a substitute for MemoryUI compilation or visual QA.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
data = (root / 'Sources/MemoryUI/DaydreamTodayData.swift').read_text()
phase = (root / 'Sources/MemoryUI/SummaryPhase.swift').read_text()

def between(start, end):
    return data[data.index(start):data.index(end, data.index(start))]

queue = between('public struct SummaryQueue:', '/// The largest scope')
state = between('public enum MomentSummaryState:', 'public struct MomentBullet:')
label = between('    public func previousSummaryStatus(', '    /// Builds the slice')
gating = between('        let currentSummary: MomentSummaryState\n', '        let corrections =')
counts = between('        var ready = 0, pending = 0, tooLong = 0', '        let latest =')
current = next(line for line in data.splitlines() if 'public var currentSummaryState:' in line)
swift = '''import Foundation
enum CloudSummariesText { static let title = "Cloud" }
''' + phase + state + queue + '''
public struct MomentSlice {
    var id = "m"
    var end = Date(timeIntervalSince1970: 10)
    var stale = true
    var summary: MomentSummaryState = .ready(generatedAt: nil, local: true)
    var currentSummary: MomentSummaryState? = nil
''' + current + '\n' + label + '''}
struct Generated { var generatedAt = "" }
struct Note {
    var status = "pending"
    var generated: Generated? = nil
    var previous: Generated? = Generated()
    var actionIDs = Array(repeating: "a", count: 249)
    var id = "m"
}
struct Availability {
    enum Provider { case off, local, cloud }
    var provider = Provider.local
    var skipped: Set<String> = []
    var writesFrom: Date? = nil
    var queue: SummaryQueue? = nil
}
enum DaydreamSummaryLimit { static let actions = 400 }
enum DaydreamNotes { static func isLocal(_ generated: Generated) -> Bool { true } }
func timestamp(_ string: String) -> Date? { nil }
func make(_ note: Note = Note(), dayPartial: Bool = false, summaries: Availability = Availability()) -> MomentSlice {
    let start = Date(timeIntervalSince1970: 0)
    let ready = note.status == "ready" ? note.generated : nil
    let generated = ready ?? note.previous
    let stale = ready == nil && generated != nil
''' + gating + '''
    return MomentSlice(stale: stale, summary: summary, currentSummary: currentSummary)
}
func totals(_ moments: [MomentSlice]) -> [Int] {
''' + counts + '''
    return [ready, pending, tooLong]
}
var tests = 0
func check(_ ok: Bool, _ name: String) {
    guard ok else { print("FAIL " + name); exit(1) }
    tests += 1; print("PASS " + name)
}
func expected(_ line: String) -> String { "Previous summary · " + line }
let stale = make()
check(stale.stale && stale.summary.isReady && stale.currentSummaryState == .pending, "249-action previous note remains displayed but current revision pending")
var currentNote = Note(); currentNote.status = "ready"; currentNote.generated = Generated()
let ready = make(currentNote)
check(!ready.stale && ready.currentSummaryState.isReady, "matching current note ready")
check(totals([stale, ready]) == [1, 1, 0], "prior note excluded from ready total")
check(ready.previousSummaryStatus(phase: .on(.local), queue: nil) == nil, "current note has no prior label")
check(stale.previousSummaryStatus(phase: .on(.local), queue: nil) == expected("No updated summary yet"), "unknown queue does not invent writing")
let looked = Date(timeIntervalSince1970: 20)
check(stale.previousSummaryStatus(phase: .on(.local), queue: SummaryQueue(writing: ["m"], lookedAt: looked)) == expected("Summary update queued"), "queue admission reported without claiming model execution")
check(stale.previousSummaryStatus(phase: .on(.local), queue: SummaryQueue(open: ["m"], lookedAt: looked)) == expected("Updates when this moment ends"), "open moment waits for end")
check(stale.previousSummaryStatus(phase: .on(.local), queue: SummaryQueue(lookedAt: Date(timeIntervalSince1970: 0))) == expected("Updates when this moment ends"), "growth after queue look remains open")
check(stale.previousSummaryStatus(phase: .on(.local), queue: SummaryQueue(lookedAt: looked)) == expected("Update not queued"), "closed unqueued moment reported honestly")
for wait in [SummaryWait.lowPower, .battery, .heat] {
    check(stale.previousSummaryStatus(phase: .on(.local), queue: SummaryQueue(writing: ["m"], lookedAt: looked, wait: wait)) == expected(wait.line), "queued power wait " + wait.rawValue)
}
check(stale.previousSummaryStatus(phase: .checking, queue: nil) == expected("Checking the model"), "checking phase retained")
check(stale.previousSummaryStatus(phase: .failed(.cloudOffline), queue: nil) == expected("Can't reach OpenRouter."), "failure phase retained")
check(stale.previousSummaryStatus(phase: .off, queue: nil) == expected("Summaries are off"), "explicit off phase truthful")
var off = Availability(); off.provider = .off
let offMoment = make(summaries: off)
check(offMoment.currentSummaryState == .summariesOff && offMoment.summary.isReady, "summaries off preserves previous note without pending count")
check(totals([offMoment]) == [0, 0, 0], "off prior note not ready or pending")
var skipped = Availability(); skipped.skipped = ["m"]
check(make(summaries: skipped).currentSummaryState == .notWritten, "skipped prior note not scheduled")
skipped.queue = SummaryQueue(writing: ["m"], lookedAt: looked)
let recovering = make(summaries: skipped)
check(recovering.currentSummaryState == .pending && totals([recovering]) == [0, 1, 0], "actual recovery queue overrides an older skipped mark")
check(recovering.previousSummaryStatus(phase: .on(.local), queue: skipped.queue) == expected("Summary update queued"), "recovery keeps prior bullets with truthful progress")
skipped.queue = SummaryQueue(lookedAt: looked)
check(make(summaries: skipped).currentSummaryState == .notWritten, "unqueued final skip remains unscheduled")
var cloud = Availability(); cloud.provider = .cloud; cloud.writesFrom = looked
check(make(summaries: cloud).currentSummaryState == .notWritten, "cloud cutoff prior note not scheduled")
check(make(dayPartial: true).currentSummaryState == .incomplete, "partial revision not pending")
var longNote = Note(); longNote.actionIDs = Array(repeating: "a", count: 401)
let long = make(longNote)
check(long.summary.isReady && long.currentSummaryState == .tooLong && totals([long]) == [0, 0, 1], "oversized revision retains prior note with honest limit totals")
check(long.previousSummaryStatus(phase: .on(.local), queue: nil) == expected("Too long to summarize"), "oversized prior label")
longNote.actionIDs = Array(repeating: "a", count: 400)
check(make(longNote).currentSummaryState == .pending, "400-action boundary eligible")
var noPrevious = Note(); noPrevious.previous = nil
let empty = make(noPrevious)
check(!empty.stale && empty.summary == .pending && empty.previousSummaryStatus(phase: .on(.local), queue: nil) == nil, "no note retains ordinary pending behavior")
var handBuilt = MomentSlice()
check(handBuilt.currentSummaryState == .pending && totals([handBuilt]) == [0, 1, 0], "hand-built stale note never counts ready")
handBuilt.stale = false
check(handBuilt.currentSummaryState.isReady, "hand-built current ready remains compatible")
print("PASS: " + String(tests) + " Foundation-only extracted status/gating/count checks; full module and visual QA not exercised")
'''
with tempfile.TemporaryDirectory(prefix='dd-previous-summary-') as temp:
    path = Path(temp)
    (path / 'main.swift').write_text(swift)
    subprocess.run(['swiftc', str(path / 'main.swift'), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
