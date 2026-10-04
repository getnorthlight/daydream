#!/usr/bin/env python3
"""Execute the real serial-observer and reveal methods against a Foundation/CoreGraphics viewport.

This checks source wiring and deferred/repeated reveal state, not AppKit rendering.
No NSApplication, windows, private history, or owner files are accessed.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[1]
source = (repo / 'Sources/MemoryUI/CanonicalTimeline.swift').read_text()

def body_after(marker):
    start = source.index(marker) + len(marker)
    depth = 1
    for end in range(start, len(source)):
        if source[end] == '{': depth += 1
        elif source[end] == '}':
            depth -= 1
            if depth == 0: return source[start:end]
    raise ValueError('unclosed source body: ' + marker)

handler = body_after('.onChange(of: browser.contextRevealSerial) { _ in')
reveal = body_after('func reveal(_ id: String, bottom: Bool = false, animated: Bool) {')
apply = body_after('private func applyReveal() {')
# The source is compiled unchanged inside an adapter. Fake clip state substitutes only
# the AppKit objects and final scroll/anchor effects; the actual target calculation runs.
swift = r'''
import Foundation
import CoreGraphics
final class Clip { var bounds = CGRect(x: 0, y: 900, width: 600, height: 300) }
final class Scroll { let contentView = Clip() }
final class Box {
    let scrollView: Scroll? = Scroll()
    var rowFrames: [String: CGRect] = [:]
    var unsettled = false
    var consistent = true
    var revealing: (id: String, bottom: Bool, animated: Bool, requested: Date, applied: Date?)?
    var anchorTakes = 0
    func takeAnchor() { anchorTakes += 1 }
    func scroll(to target: CGFloat, animated: Bool) { scrollView!.contentView.bounds.origin.y = target }
    func reveal(_ id: String, bottom: Bool = false, animated: Bool) { REVEAL }
    func applyReveal() { APPLY }
}
final class Browser {
    var focusedDay = "2026-09-21"
    var expandedMomentID: String? = "original-child"
    var selectedMomentID: String? = "original-child"
    var referenceIDs = ["original-child"]
}
let browser = Browser(), box = Box()
var detailID: String? = "original-child", contextWrites = 0
func popDetail() { detailID = nil }
func writeContext() { contextWrites += 1 }
func requestContext() { HANDLER }
var checks = 0
func check(_ value: Bool, _ name: String) {
    if !value { fputs("FAIL " + name + "\n", stderr); exit(1) }
    checks += 1; print("PASS " + name)
}
let day = browser.focusedDay, reference = browser.referenceIDs
requestContext()
check(detailID == nil && contextWrites == 1, "explicit request dismisses detail and refreshes actions")
check(box.revealing?.id == "original-child" && box.revealing?.applied == nil,
      "unchanged selected/reference ids still queue the original child before its frame exists")
check(box.scrollView!.contentView.bounds.origin.y == 900, "missing frame does not scroll to a guessed position")
box.rowFrames["original-child"] = CGRect(x: 0, y: 100, width: 600, height: 50)
box.applyReveal()
check(box.scrollView!.contentView.bounds.origin.y == 100, "deferred original child frame reveals on layout arrival")
// The person scrolls away after reveal following ends. IDs and the reference remain equal.
box.revealing = nil; box.scrollView!.contentView.bounds.origin.y = 900; detailID = "original-child"
requestContext()
check(box.scrollView!.contentView.bounds.origin.y == 100 && box.anchorTakes == 2,
      "repeat same-id context request returns the viewport to the original child")
check(browser.focusedDay == day && browser.referenceIDs == reference
      && browser.selectedMomentID == "original-child" && browser.expandedMomentID == "original-child",
      "repeat reveal preserves the original day, selection, expansion, and reference")
browser.expandedMomentID = nil; box.revealing = nil; box.scrollView!.contentView.bounds.origin.y = 900
requestContext()
check(box.revealing?.id == "original-child", "selected original child is the fallback when no expansion exists")
browser.expandedMomentID = "expanded-child"
box.rowFrames["expanded-child"] = CGRect(x: 0, y: 70, width: 600, height: 50)
requestContext()
check(box.revealing?.id == "expanded-child", "expanded child takes precedence over selected child")
browser.expandedMomentID = nil; browser.selectedMomentID = nil; box.revealing = nil
requestContext()
check(box.revealing == nil, "missing child identity queues no arbitrary row")
print("PASS \(checks) repeat-context source-adapter checks")
'''.replace('HANDLER', handler).replace('REVEAL', reveal).replace('APPLY', apply)

out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(tempfile.mkdtemp(prefix='context-repeat-'))
out.mkdir(parents=True, exist_ok=True)
(out / 'adapter.swift').write_text(swift)
subprocess.run(['swiftc', str(out / 'adapter.swift'), '-o', str(out / 'adapter')], check=True)
positive = subprocess.run([str(out / 'adapter')], text=True, capture_output=True)
(out / 'checks.log').write_text(positive.stdout + positive.stderr)
print(positive.stdout, end='')
if positive.returncode: print(positive.stderr, end=''); sys.exit(positive.returncode)
# A regression control must fail on the old observer while retaining exactly the
# same fixtures and real reveal methods. This protects against a vacuous state test.
old = swift.replace(handler, ' popDetail(); writeContext() ')
(out / 'adapter-old-observer.swift').write_text(old)
subprocess.run(['swiftc', str(out / 'adapter-old-observer.swift'), '-o', str(out / 'adapter-old-observer')], check=True)
negative = subprocess.run([str(out / 'adapter-old-observer')], text=True, capture_output=True)
(out / 'old-observer.log').write_text(negative.stdout + negative.stderr)
if negative.returncode != 1 or 'unchanged selected/reference ids still queue' not in negative.stderr:
    sys.exit('FAIL old observer did not reproduce the missing reveal')
print('PASS old observer negative control reproduces missing reveal')
(out / 'RESULT.json').write_text(json.dumps({
    'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
    'harness_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    'adapter_sha256': hashlib.sha256(swift.encode()).hexdigest(),
    'positive_exit': positive.returncode, 'old_observer_exit': negative.returncode,
    'scope': 'Foundation source adapter; no AppKit runtime proof',
}, indent=2) + '\n')
