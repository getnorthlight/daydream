#!/usr/bin/env python3
"""Run the shipped subject adapter with the compiled MemoryCore parser, no UI/store."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
build = Path(sys.argv[1]).resolve()
rows = (root / 'Sources/MemoryUI/FocusListRows.swift').read_text()
method = rows.split('    public static func recordedConversation(', 1)[1].split('\n    /// The app', 1)[0]
method = '    public static func recordedConversation(' + method
assert 'allowsGenericAlias: ["", "messages", "texts"]' in rows
assert 'withinSection: true, sectionID: sectionID' in rows
assert 'latestObserved: max(m.end, m.clusters.map(\\.upperBound).max() ?? m.end)' in rows
timeline = (root / 'Sources/MemoryUI/CanonicalTimeline.swift').read_text()
assert 'sectionID: section.id' in timeline
assert 'TimelineVisibleAnchor.select(frames: rowFrames' in timeline
assert 'box.preferVisibleAnchor([browser.expandedMomentID, browser.selectedMomentID]' in timeline
assert 'let sessions = layout.sessions(moments, sectionID: sectionID)' in rows
assert 'value: session.isGrouped ? [:] : [session.id:' in rows
assert '_open = State(initialValue: session.members.contains' in rows
assert 'previousID: anchor?.id' in timeline
layout_method = '    public static func sessions(' + rows.split('    public static func sessions(', 1)[1].split('\n    /// Subject', 1)[0]
cache_class = rows.split('private final class FocusListSessionCache {', 1)[1].split('\n/// The existing moment row', 1)[0]
cache_class = 'private final class FocusListSessionCache {' + cache_class
def block(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
baseline = subprocess.check_output(['git', '-C', str(root), 'show',
    '406432f54bfe61721e4852eb6f103f5e24db58db:Sources/MemoryUI/TimelineSessionGrouping.swift'], text=True)
baseline_anchor = block(baseline, 'public enum TimelineVisibleAnchor {').replace('TimelineVisibleAnchor', 'BaselineTimelineVisibleAnchor')
baseline_anchor = baseline_anchor.replace(
    'let onScreen = frames.filter { $0.value.maxY > visible.minY + 0.5 && $0.value.minY < visible.maxY }',
    'let onScreen = frames.filter { item in baselineExamined += 1; return item.value.maxY > visible.minY + 0.5 && item.value.minY < visible.maxY }')
assert 'baselineExamined += 1' in baseline_anchor
code = '''import Foundation
import CoreGraphics
import MemoryCore
struct MomentSlice {
    var id = "", dayKey = "2001-01-01"
    var start = Date(timeIntervalSince1970: 0), end = Date(timeIntervalSince1970: 0)
    let bundles: [String], sites: [String], subject: String
    var title = "", clusters: [ClosedRange<Date>] = []
}
enum KitBrowsers { static let bundles: Set<String> = ["com.google.Chrome"] }
enum FocusListLayout {
''' + method + layout_method + '''
}
''' + cache_class + '''
var baselineExamined = 0
''' + baseline_anchor + '''
var checks = 0
func check(_ condition: Bool, _ reason: String) { precondition(condition, reason); checks += 1 }
func identity(_ subject: String, bundles: [String] = ["com.apple.MobileSMS"], sites: [String] = []) -> String? {
    FocusListLayout.recordedConversation(MomentSlice(bundles: bundles, sites: sites, subject: subject))
}
check(identity("Avery Example") == "Avery Example", "Recorded contact parsed")
check(identity("Texts with Avery Example") == "Avery Example", "Saved code label prefix parsed")
check(identity("Messages with Avery Example") == "Avery Example", "Recorded Messages label prefix parsed")
check(identity("Messages") == nil, "Generic app has no invented contact")
check(identity("Texts") == nil, "Generic Texts does not become Texts with Texts")
check(identity("New Message") == nil, "New compose has no recipient")
check(identity("") == nil, "Blank source has no recipient")
check(identity("Avery Example, Jordan Sample") == "Avery Example, Jordan Sample", "Whole group identity retained")
check(identity("Avery Example", bundles: ["com.apple.MobileSMS", "com.apple.Notes"]) == nil, "Mixed bundles refuse identity")
check(identity("Avery Example", sites: ["x.com"]) == nil, "Mixed website refuses identity")
check(identity("person@example.invalid") == nil, "Address is not inferred contact")
check(identity("123456789") == nil, "Number is not inferred contact")
check(identity("An intentionally long fictional sentence outside any conversation name limit") == nil, "Non-name source refuses alias")
print("PASS \\(checks) recorded-conversation adapter checks with actual MemoryCore; 10 source wiring checks")
private let uiCache = FocusListSessionCache()
var row = MomentSlice(id: "fictional-row", bundles: ["com.apple.MobileSMS"], sites: [], subject: "Avery Example", title: "Old fictional summary")
let initial = uiCache.sessions([row], sectionID: "fictional-block")
row.title = "Fresh fictional summary"
let fresh = uiCache.sessions([row], sectionID: "fictional-block")
check(uiCache.metadataBuilds == 1 && uiCache.layoutBuilds == 1, "Actual UI cache avoids parsing/grouping on summary callback")
check(fresh[0].members[0].detail.title == row.title && fresh[0].id == initial[0].id, "Actual UI cache hydrates current summary and stable ID")
row.end = Date(timeIntervalSince1970: 10)
_ = uiCache.sessions([row], sectionID: "fictional-block")
check(uiCache.metadataBuilds == 1 && uiCache.layoutBuilds == 2, "New activity invalidates layout without reparsing same identity")
_ = uiCache.sessions([], sectionID: "fictional-block")
check(uiCache.layoutBuilds == 3, "Forget/removal clears current plan")
print("PASS 4 extracted UI cache state checks")
'''
if '--profile' in sys.argv:
    code += '''
let count = 1500, callbacks = 200
let fixture: [MomentSlice] = (0..<count).map { index in
    let bundles = index % 4 == 0 ? ["com.apple.MobileSMS"] : index % 4 == 1 ? ["com.apple.systempreferences"] : index % 4 == 2 ? ["com.google.Chrome"] : ["com.apple.Notes"]
    let subject = index % 4 == 0 ? "Fictional Person" : "Fictional surface \\(index)"
    return MomentSlice(id: "synthetic-\\(index)", start: Date(timeIntervalSince1970: Double(index * 2)),
                       end: Date(timeIntervalSince1970: Double(index * 2 + 1)), bundles: bundles,
                       sites: index % 4 == 2 ? ["x.com"] : [], subject: subject, title: "Fictional detail \\(index)")
}
let clock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
var checksum = 0
let baselineStart = clock()
for _ in 0..<callbacks { checksum += FocusListLayout.sessions(fixture, sectionID: "representative-block").count }
let baseline = clock() - baselineStart
private let cached = FocusListSessionCache()
_ = cached.sessions(fixture, sectionID: "representative-block")
let cachedStart = clock()
for _ in 0..<callbacks { checksum += cached.sessions(fixture, sectionID: "representative-block").count }
let optimized = clock() - cachedStart
check(cached.metadataBuilds == count && cached.layoutBuilds == 1, "Measured callbacks perform no extra parsing/sort builds")
print("PROFILE grouping rows=\\(count) callbacks=\\(callbacks) beforeMs=\\(Double(baseline)/1e6) afterMs=\\(Double(optimized)/1e6) baselineMetadataPasses=\\(count*callbacks) cachedMetadataBuilds=\\(cached.metadataBuilds) baselineGroupBuilds=\\(callbacks) cachedGroupBuilds=\\(cached.layoutBuilds) checksum=\\(checksum)")
let frames = Dictionary(uniqueKeysWithValues: (0..<1500).map { index in
    ("frame-\\(index)", CGRect(x: 0, y: CGFloat(index * 52), width: 500, height: 52))
})
let anchorBaselineStart = clock()
for step in 0..<1000 {
    checksum += BaselineTimelineVisibleAnchor.select(frames: frames, visible: CGRect(x: 0, y: CGFloat(100 + step * 2), width: 500, height: 600), preferredIDs: []) == nil ? 0 : 1
}
let anchorBaselineElapsed = clock() - anchorBaselineStart
var retained: String?, examined = 0
let anchorStart = clock()
for step in 0..<1000 {
    retained = TimelineVisibleAnchor.select(frames: frames, visible: CGRect(x: 0, y: CGFloat(100 + step * 2), width: 500, height: 600),
                                           preferredIDs: [], previousID: retained, examined: { examined += $0 })?.id
}
let anchorElapsed = clock() - anchorStart
print("PROFILE anchor frames=1500 ticks=1000 beforeExamined=\\(baselineExamined) actualExamined=\\(examined) beforeMs=\\(Double(anchorBaselineElapsed)/1e6) afterMs=\\(Double(anchorElapsed)/1e6) retainedPresent=\\(retained != nil)")
'''
platform = build / 'arm64-apple-macosx' / 'debug'
objects = [str(p) for target in ['MemoryCore', 'HistoryCore', 'PrivacyPolicy']
           for p in (platform / (target + '.build')).glob('*.o')]
assert objects, 'Compile MemoryUI/MemoryCore first'
with tempfile.TemporaryDirectory(prefix='dd-block-adapter-') as temp:
    path = Path(temp)
    (path / 'main.swift').write_text(code)
    subprocess.run(['swiftc', '-O', str(path / 'main.swift'), str(root / 'Sources/MemoryUI/TimelineSessionGrouping.swift'), '-I', str(platform / 'Modules'),
                    '-I', str(root / 'Sources/CSQLite'), *objects, '-lsqlite3', '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
