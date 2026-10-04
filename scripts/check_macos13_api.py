"""macOS 13 API lint (plan section 2 rule 5, section 5 I3, amendments I3). Read-only; no app launch.

The deployment target is macOS 13 and the build uses SDK 26.5, so any API newer than macOS 13 must sit behind an
availability check that covers its version, with a macOS 13 path beside it. Over the code of every Swift file in
every macOS 13 target of the package (`FOLDERS` plus `EXTRA_FILES`: Sources, the UIRender and Checks harnesses,
BackupRestore, adapters, the MemoryCoreTests test target, scripts/core-production-checks.swift and the local
packages the app links), with comments and string literal text blanked so prose and copy never match:

1. SwiftUI and AppKit APIs introduced after macOS 13 (the section 2.5 list plus the amendments' additions: the
   macOS 14 `onChange` overloads, `.animation(_:body:)`, `withAnimation` completion, the scroll, symbol and
   container modifiers, `@Observable`, `SettingsLink`, `WindowDragGesture`, `glassEffect` and the other Liquid
   Glass APIs, ...) appear only where an availability check protects them:
   - inside the block of `if #available(macOS N, *)` (also `else if` and multi-clause conditions);
   - after `guard #available(macOS N, *) else { ... }`, up to the end of the enclosing scope;
   - inside the body of a declaration marked `@available(macOS N, *)`;
   - inside the `else` block of `if #unavailable(macOS N)`;
   where N is at least the API's own macOS version (a `macOS 14` check does not cover a macOS 26 API).
   This replaces section 6's line-window heuristic with brace matching, so a check a few lines above an
   unrelated block cannot excuse it.
2. SF Symbols names newer than macOS 13.0 (SF Symbols 5 and later, and the 4.x names that shipped in 13.1-13.3)
   appear only under the same protection, so the macOS 13 path names a symbol that draws there. Availability
   comes from this Mac's CoreGlyphs `name_availability.plist`; symbol-name literals are those passed to
   `systemName:`, `systemImage:` or `systemSymbolName:` and any dotted literal that is a symbol name. If the
   plist cannot be read, a LIMIT line says so and the symbol check does not run.

0. Every Swift target that the root Package.swift declares lies inside that scope, so a target added later
   cannot escape the lint.

The compiler already rejects unguarded calls into newer SDK APIs in the targets it builds; this lint also covers
code under `#if` flags the product build skips, targets built only on request (tests), and symbol names, which
only fail at run time (they draw nothing).

Out of scope on purpose: the other files in `scripts/` (the dd-* and legacy check harnesses). run-checks.sh
compiles them with plain `swiftc` for this Mac, not as macOS 13 package targets; the product sources they include
are scanned under `Sources`.
"""
import plistlib
import re
import sys
from pathlib import Path

from check_state_vocabulary import ROOT, line_of, matching_braces, scan

# Every folder holding a target of the MacMem package or a local package it links; all declare macOS 13.
# Tests/HistoryCoreTests is left out: Package.swift declares no target for it (upstream Swift Testing files kept
# on disk; the toolchain can't import Testing), so it is never compiled.
FOLDERS = ('Sources', 'UIRender', 'Checks', 'BackupRestore', 'adapters', 'Tests/MemoryCoreTests',
           'WriterBackend', 'PrivacyPolicy', 'BrowserBridge')
# Single files of a package target whose folder also holds files outside the package (the ProductionBindingChecks
# target is `path: "scripts", sources: ["core-production-checks.swift"]`).
EXTRA_FILES = ('scripts/core-production-checks.swift',)
TARGET_DECL = re.compile(r'\.(target|executableTarget|testTarget)\s*\(')
SKIPPED_PARTS = {'.build', 'vendor', 'Vendor'}
GLYPHS = Path('/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist')
DEPLOYMENT = (13, 0)

# (label, pattern over scanned code, macOS version that introduced it). Patterns match modifiers and types, not
# local names: a leading `.` or `\\.` for members, word boundaries for types.
SIMPLE = [
    # plan section 2.5
    ('onKeyPress', r'\.onKeyPress\b', (14, 0)),
    ('focusable(interactions:)', r'\.focusable\([^()]*\binteractions\s*:', (14, 0)),
    ('focusEffectDisabled', r'\.focusEffectDisabled\b', (14, 0)),
    ('scrollPosition', r'\.scrollPosition\s*\(', (14, 0)),
    ('contentMargins', r'\.contentMargins\s*\(', (14, 0)),
    ('@Observable', r'@Observable\b', (14, 0)),
    ('@Bindable', r'@Bindable\b', (14, 0)),
    ('inspector', r'\.inspector\s*\(|\.inspectorColumnWidth\b', (14, 0)),
    ('SettingsLink', r'\bSettingsLink\b', (14, 0)),
    ('WindowDragGesture', r'\bWindowDragGesture\b', (15, 0)),
    ('glassEffect', r'\.glassEffect(ID|Union|Transition)?\b|\bGlassEffectContainer\b', (26, 0)),
    # amendments I3
    ('containerRelativeFrame', r'\.containerRelativeFrame\s*\(', (14, 0)),
    ('scrollTargetBehavior', r'\.scrollTarget(Behavior|Layout)\s*\(', (14, 0)),
    ('scrollTransition', r'\.scrollTransition\b', (14, 0)),
    ('symbolEffect', r'\.symbolEffect(sRemoved)?\b', (14, 0)),
    ('ContentUnavailableView', r'\bContentUnavailableView\b', (14, 0)),
    ('sensoryFeedback', r'\.sensoryFeedback\s*\(', (14, 0)),
    ('defaultScrollAnchor', r'\.defaultScrollAnchor\s*\(', (14, 0)),
    ('scrollClipDisabled', r'\.scrollClipDisabled\b', (14, 0)),
    ('safeAreaPadding', r'\.safeAreaPadding\b', (14, 0)),
    # other SwiftUI and AppKit additions after macOS 13 that fit this app's surfaces
    ('containerBackground', r'\.containerBackground\s*\(', (14, 0)),
    ('phase and keyframe animators', r'\b(PhaseAnimator|KeyframeAnimator)\b|\.(phaseAnimator|keyframeAnimator)\s*\(', (14, 0)),
    ('geometryGroup', r'\.geometryGroup\s*\(', (14, 0)),
    ('visualEffect', r'\.visualEffect\s*[({]', (14, 0)),
    ('openSettings environment action', r'\\\.openSettings\b', (14, 0)),
    ('dismissWindow environment action', r'\\\.dismissWindow\b', (14, 0)),
    ('toolbar(removing:)', r'\.toolbar\s*\(\s*removing\s*:', (14, 0)),
    ('typesettingLanguage', r'\.typesettingLanguage\s*\(', (14, 0)),
    ('scrollIndicatorsFlash', r'\.scrollIndicatorsFlash\s*\(', (14, 0)),
    ('accessoryBar button style', r'\.buttonStyle\s*\(\s*\.accessoryBar(Action)?\b', (14, 0)),
    ('extraLarge control size', r'\.controlSize\s*\(\s*\.extraLarge\b', (14, 0)),
    ('scrollBounceBehavior', r'\.scrollBounceBehavior\s*\(', (13, 3)),
    ('NSHostingMenu', r'\bNSHostingMenu\b', (14, 4)),
    ('scroll geometry, phase and visibility callbacks', r'\.onScroll(Geometry|Phase|Visibility)Change\b', (15, 0)),
    ('presentationSizing', r'\.presentationSizing\s*\(', (15, 0)),
    ('windowResizeAnchor', r'\.windowResizeAnchor\s*\(', (15, 0)),
    ('pointerStyle', r'\.pointerStyle\s*\(', (15, 0)),
    ('onModifierKeysChanged', r'\.onModifierKeysChanged\b', (15, 0)),
    ('MeshGradient', r'\bMeshGradient\b', (15, 0)),
    ('textRenderer', r'\.textRenderer\s*\(', (15, 0)),
    ('toolbarBackgroundVisibility', r'\.toolbarBackgroundVisibility\s*\(', (15, 0)),
    ('windowLevel', r'\.windowLevel\s*\(', (15, 0)),
    ('UtilityWindow', r'\bUtilityWindow\b', (15, 0)),
    ('Color.mix(with:)', r'\.mix\s*\(\s*with\s*:', (15, 0)),
    ('glass button styles', r'\.buttonStyle\s*\(\s*\.glass(Prominent)?\b', (26, 0)),
    ('ToolbarSpacer', r'\bToolbarSpacer\b', (26, 0)),
    ('sharedBackgroundVisibility', r'\.sharedBackgroundVisibility\s*\(', (26, 0)),
    ('backgroundExtensionEffect', r'\.backgroundExtensionEffect\s*\(', (26, 0)),
    ('scrollEdgeEffectStyle', r'\.scrollEdgeEffectStyle\s*\(', (26, 0)),
    ('safeAreaBar', r'\.safeAreaBar\s*\(', (26, 0)),
]
SIMPLE = [(label, re.compile(pattern), version) for label, pattern, version in SIMPLE]
SYMBOL_ARGUMENT = re.compile(r'\b(systemName|systemImage|systemSymbolName|symbol)\s*:')
SYMBOL_PROPERTY = re.compile(r'\b(?:var|func)\s+\w*[Ss]ymbol\b')
SYMBOL_NAME = re.compile(r'[a-z0-9]+(\.[a-z0-9]+)+')


def version(text):
    return tuple(int(part) for part in (text.split('.') + ['0'])[:2])


def shown(v):
    return f'{v[0]}.{v[1]}' if v[1] else f'{v[0]}'


def close_paren(code, open_index):
    depth = 0
    for k in range(open_index, len(code)):
        if code[k] == '(':
            depth += 1
        elif code[k] == ')':
            depth -= 1
            if depth == 0:
                return k
    return len(code) - 1


def next_block(code, start, pairs):
    """The brace pair of the first `{` at parenthesis depth 0 from `start` (a statement body or a declaration
    body), or None when a `;` or the end of the enclosing scope comes first."""
    depth = 0
    for k in range(start, len(code)):
        c = code[k]
        if c in '([':
            depth += 1
        elif c in ')]':
            depth -= 1
            if depth < 0:
                return None
        elif depth == 0 and c == ';':
            return None
        elif depth == 0 and c == '}':
            return None
        elif depth == 0 and c == '{':
            return (k, pairs[k]) if k in pairs else None
    return None


def enclosing_scope(pairs, offset):
    best = None
    for a, b in pairs.items():
        if a < offset < b and (best is None or a > best[0]):
            best = (a, b)
    return best


def macos_version(arguments):
    m = re.search(r'\bmacOS\s+(\d+(?:\.\d+)*)', arguments) or re.search(r'\bmacOS\b[^)]*\bintroduced\s*:\s*(\d+(?:\.\d+)*)', arguments)
    return version(m.group(1)) if m else None


def protected_ranges(code, pairs):
    """[(start, end, version)] of code an availability check covers."""
    ranges = []
    for m in re.finditer(r'#(available|unavailable)\s*\(', code):
        paren = m.end() - 1
        end = close_paren(code, paren)
        v = macos_version(code[paren:end + 1])
        if v is None:
            continue
        before = code[max(0, m.start() - 200):m.start()]
        keyword = re.search(r'\b(if|guard|while)\b[^{};]*$', before)
        if not keyword:
            continue
        block = next_block(code, end + 1, pairs)
        if block is None:
            continue
        if keyword.group(1) == 'guard':
            if m.group(1) == 'available':
                scope = enclosing_scope(pairs, m.start())
                if scope:
                    ranges.append((block[1], scope[1], v))
        elif m.group(1) == 'available':
            ranges.append((block[0], block[1], v))
        else:   # if #unavailable(...) { fallback } else { newer }
            after = re.match(r'\s*else\s*\{', code[block[1] + 1:])
            if after:
                brace = block[1] + 1 + after.end() - 1
                if brace in pairs:
                    ranges.append((brace, pairs[brace], v))
    for m in re.finditer(r'@available\s*\(', code):
        paren = m.end() - 1
        end = close_paren(code, paren)
        v = macos_version(code[paren:end + 1])
        if v is None:
            continue
        block = next_block(code, end + 1, pairs)
        if block:
            ranges.append((m.start(), block[1], v))
    return ranges


def covered(offset, ranges):
    """The highest macOS version an availability check guarantees at `offset` (13.0 when none does)."""
    return max([v for a, b, v in ranges if a <= offset <= b], default=DEPLOYMENT)


def call_extent(code, paren, pairs):
    """From the `(` of a call to the end of its trailing closures (including labelled ones)."""
    end = close_paren(code, paren)
    while True:
        m = re.match(r'\s*(\w+\s*:\s*)?\{', code[end + 1:])
        if not m or (m.group(1) is None and '\n' in code[end + 1:end + 1 + m.end()]):
            return end
        brace = end + m.end()
        if brace not in pairs:
            return end
        end = pairs[brace]


def closure_arity(body):
    """Parameters a closure body declares (`a, b in`, `(a, b) in`, `_ in`), or uses as `$0`/`$1`."""
    head = re.match(r'\s*(\[[^\]]*\]\s*)?(\(?\s*([\w\s,:<>?\[\]]*?)\s*\)?)\s+in\b', body)
    if head:
        names = [part for part in head.group(3).split(',') if part.strip()]
        return len(names)
    if re.search(r'\$1\b', body):
        return 2
    return 1 if re.search(r'\$0\b', body) else 0


def api_hits(code, pairs):
    """[(offset, label, version)] for every newer-than-13 API use in scanned code."""
    hits = [(m.start(), label, v) for label, pattern, v in SIMPLE for m in pattern.finditer(code)]
    for m in re.finditer(r'\.onChange\s*\(', code):
        paren = m.end() - 1
        end = close_paren(code, paren)
        arguments = code[paren:end + 1]
        if re.search(r'\binitial\s*:', arguments):
            hits.append((m.start(), 'onChange(of:initial:)', (14, 0)))
            continue
        if re.search(r'\bperform\s*:', arguments):
            continue
        closure = re.match(r'\s*\{', code[end + 1:])
        if closure and end + closure.end() in pairs:
            brace = end + closure.end()
            arity = closure_arity(code[brace + 1:pairs[brace]])
            if arity != 1:
                hits.append((m.start(), f'onChange with a {arity}-parameter closure (the macOS 14 overload)', (14, 0)))
    for m in re.finditer(r'\.animation\s*\(', code):
        end = close_paren(code, m.end() - 1)
        if re.match(r'[ \t]*\{', code[end + 1:]):
            hits.append((m.start(), '.animation(_:body:)', (14, 0)))
    for m in re.finditer(r'\bwithAnimation\s*\(', code):
        paren = m.end() - 1
        extent = code[paren:call_extent(code, paren, pairs) + 1]
        top, reduced = None, extent   # closure bodies emptied, so only this call's own labels remain
        while reduced != top:
            top, reduced = reduced, re.sub(r'\{[^{}]*\}', '{}', reduced)
        if re.search(r'\bcompletion(Criteria)?\s*:', top):
            hits.append((m.start(), 'withAnimation completion', (14, 0)))
    return hits


def swift_sources():
    for folder in FOLDERS:
        for path in sorted((ROOT / folder).rglob('*.swift')):
            if not SKIPPED_PARTS.intersection(path.relative_to(ROOT).parts):
                yield path
    for name in EXTRA_FILES:
        yield ROOT / name


def in_scope(rel):
    """Whether a package-relative path (a folder or a file) is scanned."""
    parts = Path(rel).parts
    return rel in EXTRA_FILES or any(parts[:len(Path(f).parts)] == Path(f).parts for f in FOLDERS)


def uncovered_targets():
    """(declared, uncovered): the Swift targets of the root Package.swift, and those whose sources lie outside
    `FOLDERS`/`EXTRA_FILES`. A target's sources are `path` (default Sources/<name>, or Tests/<name> for a test
    target), narrowed to `sources:` when it is given."""
    source = (ROOT / 'Package.swift').read_text()
    code, literals = scan(source)
    declared, uncovered = [], []
    for m in TARGET_DECL.finditer(code):
        end = close_paren(code, m.end() - 1)
        inside = [lit for lit in literals if m.end() <= lit.start < end]

        names = [lit.text for lit in inside if re.search(r'\bname\s*:\s*"$', code[m.end():lit.start + 1])]
        if not names:
            continue
        name = names[0]
        path_lits = [lit.text for lit in inside if re.search(r'\bpath\s*:\s*"$', code[m.end():lit.start + 1])]
        folder = path_lits[0] if path_lits else ('Tests/' if m.group(1) == 'testTarget' else 'Sources/') + name
        src = re.search(r'\bsources\s*:\s*\[', code[m.end():end])
        if src:
            close = code.index(']', m.end() + src.end())
            files = [folder + '/' + lit.text for lit in inside if m.end() + src.end() <= lit.start < close]
        else:
            files = [folder]
        declared.append(name)
        uncovered += [f'{name} ({f})' for f in files if not in_scope(f)]
    return declared, uncovered


def load_symbols():
    try:
        data = plistlib.loads(GLYPHS.read_bytes())
        releases = {year: version(r['macOS']) for year, r in data['year_to_release'].items() if 'macOS' in r}
        return {name: releases[year] for name, year in data['symbols'].items() if year in releases}
    except (OSError, KeyError, ValueError, plistlib.InvalidFileException):
        return None


def symbol_literals(code, literals, pairs):
    """Literals that name SF Symbols: every literal in a `systemName:`/`systemImage:`/`systemSymbolName:`/`symbol:`
    argument or in the body of a `var`/`func` named `…symbol` (such as `accessibilitySymbol`), plus dotted
    literals anywhere (checked against the plist by the caller)."""
    chosen = {}
    for m in SYMBOL_PROPERTY.finditer(code):
        block = next_block(code, m.end(), pairs)
        if block:
            for lit in literals:
                if block[0] < lit.start < block[1] and not lit.interpolated:
                    chosen[lit.start] = (lit, True)
    for m in SYMBOL_ARGUMENT.finditer(code):
        if re.search(r'\b(let|var|case)\s+$', code[max(0, m.start() - 40):m.start()]):
            continue   # a declaration such as `let symbol: String`, not an argument
        depth, k = 0, m.end()
        while k < len(code):   # the argument ends at a top-level `,`, a closing bracket, or a closure
            c = code[k]
            if depth == 0 and c in ',)]}{':
                break
            if c in '([{':
                depth += 1
            elif c in ')]}':
                depth -= 1
            k += 1
        for lit in literals:
            if m.end() <= lit.start < k and not lit.interpolated:
                chosen[lit.start] = (lit, True)
    for lit in literals:
        if not lit.interpolated and SYMBOL_NAME.fullmatch(lit.text):
            chosen.setdefault(lit.start, (lit, False))
    return [value for _, value in sorted(chosen.items())]


passes, failures = 0, []


def ok(condition, message, detail=''):
    global passes
    if condition:
        passes += 1
        print('PASS ' + message)
    else:
        failures.append(message + (f': {detail}' if detail else ''))


def main():
    symbols = load_symbols()
    files = api_uses = symbol_uses = 0
    unprotected, guarded, newer_symbols, guarded_symbols, unknown = [], [], [], [], []
    for path in swift_sources():
        rel = str(path.relative_to(ROOT))
        source = path.read_text()
        code, literals = scan(source)
        pairs = matching_braces(code)
        ranges = protected_ranges(code, pairs)
        files += 1
        for offset, label, needed in sorted(api_hits(code, pairs)):
            api_uses += 1
            have = covered(offset, ranges)
            where = f'{rel}:{line_of(source, offset)} {label} (macOS {shown(needed)}'
            if have >= needed:
                guarded.append(where + f', guarded by #available macOS {shown(have)})')
            else:
                unprotected.append(where + (f'; the nearest check covers only macOS {shown(have)}' if have > DEPLOYMENT
                                            else '; no #available check covers it') + ')')
        if symbols is None:
            continue
        for lit, in_argument in symbol_literals(code, literals, pairs):
            needed = symbols.get(lit.text)
            if needed is None:
                if in_argument:
                    unknown.append(f'{rel}:{line_of(source, lit.start)} "{lit.text}"')
                continue
            symbol_uses += 1
            if needed <= DEPLOYMENT:
                continue
            have = covered(lit.start, ranges)
            where = f'{rel}:{line_of(source, lit.start)} "{lit.text}" (macOS {shown(needed)}'
            if have >= needed:
                guarded_symbols.append(where + f', guarded by #available macOS {shown(have)})')
            else:
                newer_symbols.append(where + '; no fallback check covers it)')
    declared, uncovered = uncovered_targets()
    ok(len(declared) >= 10 and not uncovered, 'every Swift target of Package.swift lies inside the scanned folders',
       f'{len(declared)} targets; outside: ' + ', '.join(uncovered))
    ok(files >= 200, f'scanned the code of every Swift file in {", ".join(FOLDERS + EXTRA_FILES)}', f'{files} files')
    ok(not unprotected, 'every API newer than macOS 13 sits under an #available check that covers its version',
       '; '.join(unprotected))
    if symbols is None:
        print(f'LIMIT SF Symbols availability not checked: {GLYPHS} could not be read')
    else:
        ok(len(symbols) > 5000 and symbol_uses >= 50, 'read SF Symbols availability from CoreGlyphs and found the symbol literals',
           f'{len(symbols)} symbols, {symbol_uses} literals')
        ok(not newer_symbols, 'every SF Symbols name newer than macOS 13.0 has a macOS 13 fallback under #available',
           '; '.join(newer_symbols))
        for line in unknown:
            print('NOTE symbol argument is not an SF Symbols name on this Mac (custom or aliased?): ' + line)
    for line in guarded + guarded_symbols:
        print('GUARDED ' + line)
    for message in failures:
        print('FAIL: ' + message, file=sys.stderr)
    print(f'{"FAIL" if failures else "PASS"} check_macos13_api: {passes} passed, {len(failures)} failed '
          f'({api_uses} newer API uses, {symbol_uses} symbol literals)')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
