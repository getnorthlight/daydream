#!/usr/bin/env python3
"""Focused console checks of verbatim C1 core and adapter-name read methods.

Foundation-only fake nodes/clock; no Chrome, AX, application/window, event tap,
store or permissions. The real adapter name-read method is extracted with its
node type substituted; optionalString is a clocked fake. This does not satisfy
C-8 live hidden/datalist/timing evidence or substitute for app compilation.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--negative-control', choices=['secure', 'deadline'])
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
core = (root / 'Sources/MemoryCore/BrowserTypingJoin.swift').read_text()
witness = (root / 'Sources/MacMemApp/ChromeTypingWitness.swift').read_text()

def method(source, start):
    a = source.index(start)
    brace = source.index('{', a)
    depth, b = 1, brace + 1
    while depth:
        depth += (source[b] == '{') - (source[b] == '}')
        b += 1
    return source[a:b]

access = core[core.index('public enum BrowserFormSearch:'):core.index('public struct ChromeJoinEnvironment {')]
scan = core[core.index('public enum BrowserFormScanResult:'):core.index('/// What one key did')]
name_reads = method(witness, '    private static func formControlNames(').replace('AXUIElement', 'Node')
assert 'access.formControlNames = { node, late in Self.formControlNames(node, late: late) }' in witness
# fix/chrome-large-pages (owner-approved 2026-10-02): recovery is ON in production and QA.
assert 'public var formSearchRecoveryEnabled = true' in access
assert 'formSearchRecoveryEnabled: Bool = true' in witness
assert 'let names = ax.controlNamesForForm(node, late: late)\n                if late() { return .late }' in scan
assert 'let names = ax.controlNamesForForm(node, late: late)\n                if late() { return .late }' in scan[scan.index('private static func walk'):]
if args.negative_control == 'secure':
    start = scan.index('                // C-7 applies')
    end = scan.index('                guard searchControls.contains(role)', start)
    # Restore the old reveal-result omission in extracted code only.
    scan = scan[:start] + scan[end:]
elif args.negative_control == 'deadline':
    # Restore the old second-read omission without changing the product.
    name_reads = name_reads.replace('guard !late(), let description', 'guard let description')

swift = '''import Foundation
public struct ChromeBounds {}
public struct BrowserTypingFieldLabels {}
''' + access + scan + '''
final class Node {
    let id: String
    var role: String, subrole: String? = "", pid: Int32 = 42
    var ancestor: Node?, kids: [Node] = []
    var title: String? = "Password help", description: String? = "Plain control"
    init(_ id: String, _ role: String) { self.id = id; self.role = role }
}
enum Names {
    enum Attribute { case title, description }
    static var clock = 0, titleCost = 0, descriptionCost = 0
    static var reads: [Attribute] = []
    static func reset(title: Int = 0, description: Int = 0, clock start: Int = 0) {
        clock = start; titleCost = title; descriptionCost = description; reads = []
    }
    static func optionalString(_ node: Node, _ attribute: Attribute) -> String? {
        reads.append(attribute)
        switch attribute {
        case .title: clock += titleCost; return node.title
        case .description: clock += descriptionCost; return node.description
        }
    }
''' + name_reads + '''
    static func read(_ node: Node, late: () -> Bool) -> [String]? { formControlNames(node, late: late) }
}
let field = Node("focused", "AXTextArea"), group = Node("group", "AXGroup"), page = Node("page", "AXWebArea"), window = Node("window", "AXWindow")
let control = Node("control", "AXButton")
let chain = [field, group, page, window]
group.kids = [field]; page.kids = [group]
var queries = 0
var fields = [field], controls = [control]
var ax = ChromeAXAccess<Node>(frontmostPID: { 42 }, systemFocusedPID: { 42 }, secureInput: { false },
    focusedWindow: { window }, windows: { [window] }, focusedElement: { field }, owner: { $0.pid },
    role: { $0.role }, subrole: { $0.subrole }, parent: { _ in nil }, frame: { _ in nil }, minimized: { _ in false },
    title: { _ in nil }, url: { _ in nil }, fieldLabels: { _ in nil }, equal: { $0 === $1 }, editableAncestor: { $0.ancestor },
    controlNames: { [$0.title ?? "", $0.description ?? ""] }, children: { $0.kids }, formSearch: { root, predicate, limit in
        precondition(root === page && limit == 65)
        queries += 1
        switch predicate { case .textFields: return fields; case .revealControls: return controls }
    })
ax.formControlNames = { node, late in Names.read(node, late: late) }
var checks = 0
func check(_ ok: Bool, _ label: String) {
    guard ok else { print("FAIL " + label); exit(1) }
    checks += 1; print("PASS " + label)
}
func search() -> BrowserFormScanResult { BrowserFormScan.search(chain: chain, ax: ax, late: { Names.clock > 100 }) }
Names.reset()
check(search() == .clear, "normal sentinel and benign control positive")
check(queries == 5 && Names.reads.count == 8, "one field plus four fixed control predicates")
for role in ["AXButton", "AXCheckBox", "AXLink", "AXMenuButton", "AXPopUpButton", "AXMenuItem", "AXStaticText", "AXGroup"] {
    control.role = role; control.subrole = "AXSecureTextField"; Names.reset()
    check(search() == .password && Names.reads.isEmpty, "secure reveal-result subrole refuses before names under " + role)
}
control.role = "AXButton"; control.subrole = nil; Names.reset()
check(search() == .unreadable && Names.reads.isEmpty, "unreadable reveal subrole refuses before names")
control.subrole = ""; control.role = "AXUnknownSecure"; Names.reset()
check(search() == .password, "secure reveal role remains strongest refusal")
control.role = "AXPopUpButton"; Names.reset()
check(search() == .unreadable, "nonsecure unsupported control role remains refusal")
control.role = "AXButton"; control.title = "Show password"; Names.reset()
check(search() == .reveal, "ordinary reveal positive remains sensitive")
control.title = "Password help"; Names.reset(title: 101)
check(search() == .late, "title consuming remaining budget classifies timeout")
check(Names.reads == [.title], "expired title forbids description AX read")
Names.reset(clock: 100)
check(search() == .clear && Names.reads.count == 8, "inclusive exact deadline with zero-cost metadata reads retains normal control")
Names.reset(title: 99, description: 2)
check(search() == .late && Names.reads == [.title, .description], "description started in budget but completed late refuses")
Names.reset(clock: 101)
check(search() == .late && Names.reads.isEmpty, "already expired search performs no name reads")
Names.reset(); control.title = nil
check(search() == .unreadable && Names.reads == [.title], "failed title preserves unreadable refusal")
control.title = "Password help"; control.description = nil; Names.reset()
check(search() == .unreadable && Names.reads == [.title, .description], "failed description preserves unreadable refusal")
control.description = "Plain control"; fields = []; Names.reset()
check(search() == .unreadable && Names.reads.isEmpty, "missing identity sentinel never reaches names")
fields = [field]; control.pid = 43; Names.reset()
check(search() == .unreadable && Names.reads.isEmpty, "wrong-owner control remains refused")
control.pid = 42; controls = Array(repeating: control, count: 65); Names.reset()
check(search() == .unreadable, "65 control results remain a truncated refusal")
controls = [control]; page.kids = [group] + (0..<100).map { Node("static-\\($0)", "AXStaticText") }; queries = 0; Names.reset()
check(ax.formSearchRecoveryEnabled, "production recovery default is ON (fix/chrome-large-pages)")
ax.formSearchRecoveryEnabled = false
check(BrowserFormScan.scan(chain: chain, ax: ax, late: { false }) == .exhausted && queries == 0, "negative control: recovery OFF (the old default) refuses the large page without search work")
ax.formSearchRecoveryEnabled = true; Names.reset()
check(BrowserFormScan.scan(chain: chain, ax: ax, late: { Names.clock > 100 }) == .clear, "default recovery answers the complete benign large page")
Names.reset(title: 101)
check(BrowserFormScan.scan(chain: chain, ax: ax, late: { Names.clock > 100 }) == .late && Names.reads == [.title], "recovery scan preserves deadline refusal after exhausted walk")
group.kids = [field, control]; page.kids = [group]; Names.reset(title: 101)
check(BrowserFormScan.scan(chain: chain, ax: ax, late: { Names.clock > 100 }) == .late && Names.reads == [.title], "strict walk uses deadline seam too")
Names.reset(); group.kids = [field]; page.kids = [group]; controls = [control]
check(search() == .clear, "normal positive restored after privacy and timeout negatives")
print("PASS " + String(checks) + " focused extracted C1 contract checks; no OS/Chrome/UI/store calls")
'''
assert 'AXUIElementCopy' not in swift and 'NSApplication' not in swift
with tempfile.TemporaryDirectory(prefix='dd-c1-contract-') as temp:
    path = Path(temp)
    (path / 'main.swift').write_text(swift)
    subprocess.run(['swiftc', str(path / 'main.swift'), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
