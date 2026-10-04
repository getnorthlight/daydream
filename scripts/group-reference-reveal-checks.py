#!/usr/bin/env python3
"""Console checks of shipped group reveal predicates and deferred-scroll geometry.

Uses verbatim source methods with small Foundation/CoreGraphics view/scroll fixtures.
No NSApplication, window, store, browser, privacy permission, or live recorder.
Source-wiring assertions are separate from executable state checks. Full UI
layout and AppKit lifecycle still require the foreground QA lane.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
rows = (root / 'Sources/MemoryUI/FocusListRows.swift').read_text()
timeline = (root / 'Sources/MemoryUI/CanonicalTimeline.swift').read_text()

def method(source, start):
    a = source.index(start)
    brace = source.index('{', a)
    depth = 1
    b = brace + 1
    while depth:
        depth += (source[b] == '{') - (source[b] == '}')
        b += 1
    return source[a:b]

# Owner 10/2: one card per app in a bracket; no fold to open. A referenced member tints its card, and every member's
# ID registers the card's frame, so a reference or selection scrolls to the card that holds it.
session = rows[rows.index('struct FocusAppCardItem:'):rows.index('struct FocusAppCardHeader:')]

wiring = [
    ('referenced member tints its card', 'let isReferenced = referenced.map { ids in members.contains { ids.contains($0.id) } } ?? false' in session
        and '.background(isReferenced ? ReferenceStyle.tint : Color.clear)' in session),
    ('card mirrors reference dimming', '.opacity(referenced.map { _ in isReferenced ? 1 : ReferenceStyle.dimmed } ?? 1)' in session),
    ('every member registers the card frame', '([session.id] + members.map(\\.id)).map { ($0, frame) }' in session),
    ('an expanded member opens its card', 'let open = members.first { $0.id == context.expandedID }' in session),
    ('resolved references observe delayed reads', '.onChange(of: referenceIDs)' in timeline and 'let referenceIDs = referenced(key: key, snap: snap)' in timeline),
    ('deferred reference reveal', 'if let first = ids?.first { box.reveal(first, animated: motion != nil) }' in timeline),
    ('initial reference waits for frames', 'if let first = referenceIDs?.first { box.reveal(first, animated: false) }' in timeline),
    ('keyboard reveal waits for frames', 'box.reveal(target, animated: false)' in timeline and 'proxy.scrollTo' not in timeline),
    ('reference clearing cancels pending reveal', 'else { box.cancelReveal(unless: browser.expandedMomentID) }' in timeline),
    ('late scroll probe replays reveal', 'if !unsettled && consistent { applyReveal() }' in method(timeline, '    func attach(')),
]
for label, ok in wiring:
    assert ok, label
    print('PASS source wiring: ' + label, flush=True)

scrolling = '\n'.join(method(timeline, s) for s in [
    '    func reveal(', '    func cancelReveal(', '    private func applyReveal()'])

swift = '''import Foundation
import CoreGraphics
final class Clip { var bounds = CGRect(x: 0, y: 0, width: 400, height: 100) }
final class Scroll { var contentView = Clip() }
final class DeferredScrollFixture {
    var scrollView: Scroll?
    var rowFrames: [String: CGRect] = [:]
    var unsettled = false, consistent = true
    private var revealing: (id: String, bottom: Bool, animated: Bool, requested: Date, applied: Date?)?
    var requests: [(CGFloat, Bool)] = []
    private func scroll(to target: CGFloat, animated: Bool = false) {
        requests.append((target, animated)); scrollView?.contentView.bounds.origin.y = target
    }
    private func takeAnchor() {}
    func layout(_ frames: [String: CGRect]) { rowFrames = frames; applyReveal() }
    func attach() { scrollView = Scroll(); if !unsettled && consistent { applyReveal() } }
    func oldRequest() { revealing?.requested = Date().addingTimeInterval(-6) }
''' + scrolling + '''
}
var checks = 0
func check(_ ok: Bool, _ label: String) {
    guard ok else { print("FAIL " + label); exit(1) }
    checks += 1; print("PASS " + label)
}
let frame = CGRect(x: 0, y: 300, width: 400, height: 52)
let scroll = DeferredScrollFixture(); scroll.attach()
scroll.reveal("x-2", animated: true)
check(scroll.requests.isEmpty, "collapsed child without frame never produces a scroll")
scroll.layout(["unrelated": frame])
check(scroll.requests.isEmpty, "unrelated layout cannot satisfy original child request")
scroll.layout(["x-2": frame])
check(scroll.requests.count == 1 && scroll.requests[0].0 == 252 && scroll.requests[0].1, "first child layout reveals original row with requested animation")
scroll.layout(["x-2": CGRect(x: 0, y: 500, width: 400, height: 52)])
check(scroll.requests.count == 2 && scroll.requests[1].0 == 452, "reveal follows row while document layout settles")
let lateProbe = DeferredScrollFixture()
lateProbe.layout(["x-2": frame]); lateProbe.reveal("x-2", animated: false)
check(lateProbe.requests.isEmpty, "request before scroll-probe attachment does not guess offset")
lateProbe.attach()
check(lateProbe.requests.count == 1 && !lateProbe.requests[0].1, "late probe attachment replays pending initial reference")
let cancelled = DeferredScrollFixture(); cancelled.attach(); cancelled.reveal("x-1", animated: false)
cancelled.cancelReveal(unless: nil); cancelled.layout(["x-1": frame])
check(cancelled.requests.isEmpty, "cleared reference cannot scroll after delayed layout")
let replaced = DeferredScrollFixture(); replaced.attach(); replaced.reveal("x-1", animated: false); replaced.reveal("x-2", animated: false)
replaced.layout(["x-1": frame])
check(replaced.requests.isEmpty, "new request invalidates delayed previous child")
replaced.layout(["x-2": frame])
check(replaced.requests.count == 1, "latest original child request alone resolves")
let expired = DeferredScrollFixture(); expired.attach(); expired.reveal("x-1", animated: false); expired.oldRequest(); expired.layout(["x-1": frame])
check(expired.requests.isEmpty, "bounded missing-frame request expires")
print("PASS " + String(checks) + " extracted state/geometry checks; no SwiftUI or AppKit execution")
'''
assert 'NSApplication' not in swift and 'NSApp.' not in swift
with tempfile.TemporaryDirectory(prefix='dd-group-reference-') as temp:
    path = Path(temp)
    (path / 'main.swift').write_text(swift)
    subprocess.run(['swiftc', str(path / 'main.swift'), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
print('PASS ' + str(len(wiring)) + ' source wiring assertions; MemoryUI compilation and live UI remain separate')
