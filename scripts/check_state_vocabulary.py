"""State vocabulary lint (plan section 5 I3, checks.md V2, plan section 2 rule 9, L21). Read-only; no app launch.

Over every string literal in Sources/MemoryUI and Sources/MacMemApp (comments are not literals):
1. Retired vocabulary never appears: `remembering` in any case (so `Start remembering`, `Stop remembering`,
   `Remembering on this Mac`), `Never Remember`, and the capture verbs `Pause capture`, `Resume capture`,
   `Stop capture` in any case. `Tomorrow` never appears in a pause context: TimedPause accepts only
   5/15/30/120 minutes (L9), so there is no "until tomorrow" to offer.
2. `remembered` appears only in a count: after a digit (`\\d[^"]*remembered`), or inside
   `DaydreamFormat.momentsRemembered`, the one helper that builds "12 moments remembered today".
3. The Recording vocabulary exists as exact literals: `Start Recording`, `Stop Recording`, `Resume Recording`,
   `Pause for`, `Needs Permission`, `Open System Settings` and the search placeholder
   `Search your notes and what you've seen` (copy deck sections 8.1, 8.3, 8.7).

One narrow exception mechanism, `LEGACY_UNBUILT`: literals inside a listed view that nothing in Sources builds are
reported as PENDING instead of failing (a hit in a view that the product mounts again fails like any other). It is
empty now: the three pre-redesign capture views it listed were deleted in wave 3b (I2).

The Swift scanner here (`scan`) is shared with scripts/check_macos13_api.py.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


# ---------------------------------------------------------------------------------------------
# Swift source scanner: comments and string literals, with positions.

class Literal:
    """One string literal. `text` has each interpolation replaced by `\\(…)`; `start`/`end` are the offsets of
    its opening and closing delimiters in the source."""

    def __init__(self, start, end, pieces):
        self.start, self.end, self.pieces = start, end, pieces
        self.interpolated = len(pieces) > 1
        self.text = '\\(…)'.join(pieces)


class _Scanner:
    ESCAPES = {'n': '\n', 't': '\t', 'r': '\r', '0': '\0', '"': '"', "'": "'", '\\': '\\'}

    def __init__(self, source):
        self.src, self.n = source, len(source)
        self.out = list(source)
        self.literals = []

    def blank(self, a, b):
        for k in range(a, min(b, self.n)):
            if self.out[k] != '\n':
                self.out[k] = ' '

    def comment(self, i):
        """Blanks a comment at `i` and returns the offset after it, or None when there is none."""
        src = self.src
        if src.startswith('//', i):
            j = src.find('\n', i)
            j = self.n if j < 0 else j
        elif src.startswith('/*', i):
            depth, j = 1, i + 2
            while j < self.n and depth:
                if src.startswith('/*', j):
                    depth, j = depth + 1, j + 2
                elif src.startswith('*/', j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
        else:
            return None
        self.blank(i, j)
        return j

    def code(self, i, in_interpolation=False):
        """Scans code from `i`. Inside an interpolation, stops at its closing `)` and returns that offset."""
        src, depth = self.src, 0
        while i < self.n:
            after = self.comment(i)
            if after is not None:
                i = after
                continue
            c = src[i]
            if c == '"' or (c == '#' and re.match(r'#+"', src[i:i + 12])):
                i = self.string(i)
                continue
            if in_interpolation:
                if c == '(':
                    depth += 1
                elif c == ')':
                    if depth == 0:
                        return i
                    depth -= 1
            i += 1
        return i

    def string(self, i):
        src, start, hashes = self.src, i, 0
        while src[i] == '#':
            hashes, i = hashes + 1, i + 1
        multi = src.startswith('"""', i)
        i += 3 if multi else 1
        close = ('"""' if multi else '"') + '#' * hashes
        escape = '\\' + '#' * hashes
        pieces, run, segment = [], [], i
        while i < self.n:
            if src.startswith(close, i):
                self.blank(segment, i)
                pieces.append(''.join(run))
                self.literals.append(Literal(start, i + len(close), pieces))
                return i + len(close)
            if src.startswith(escape, i) and i + len(escape) < self.n:
                j = i + len(escape)
                if src[j] == '(':
                    self.blank(segment, j)
                    pieces.append(''.join(run))
                    run = []
                    i = self.code(j + 1, in_interpolation=True) + 1
                    segment = i
                    continue
                if src[j] == 'u' and src.startswith('{', j + 1):
                    end = src.find('}', j)
                    try:
                        run.append(chr(int(src[j + 2:end], 16)))
                    except ValueError:
                        pass
                    i = end + 1
                    continue
                if multi and src[j] == '\n':   # line continuation
                    i = j + 1
                    continue
                run.append(self.ESCAPES.get(src[j], src[j]))
                i = j + 1
                continue
            if not multi and src[i] == '\n':
                break   # unterminated single-line literal: stop at the line end
            run.append(src[i])
            i += 1
        self.blank(segment, i)
        pieces.append(''.join(run))
        self.literals.append(Literal(start, i, pieces))
        return i


def scan(source):
    """Returns (code, literals). `code` is `source` with every comment and every literal's text replaced by
    spaces (newlines kept, so offsets and line numbers still match); the delimiters and the expressions of
    `\\( … )` interpolations stay. Handles `//`, nested `/* */`, `"…"`, `\"\"\"…\"\"\"` and raw `#"…"#`."""
    s = _Scanner(source)
    s.code(0)
    s.literals.sort(key=lambda lit: lit.start)
    return ''.join(s.out), s.literals


def line_of(text, offset):
    return text.count('\n', 0, offset) + 1


def matching_braces(code):
    """{open offset: close offset} for every brace pair in scanned code (comments and literal text blanked)."""
    pairs, stack = {}, []
    for k, c in enumerate(code):
        if c == '{':
            stack.append(k)
        elif c == '}' and stack:
            pairs[stack.pop()] = k
    return pairs


def swift_files(*folders, recursive=False):
    for folder in folders:
        base = ROOT / folder
        yield from sorted(base.rglob('*.swift') if recursive else base.glob('*.swift'))


# ---------------------------------------------------------------------------------------------
# The lint

SCOPE = ('Sources/MemoryUI', 'Sources/MacMemApp')

# (pattern, why). Matched against the literal's text, interpolations included as `\(…)`.
RETIRED = [
    (re.compile(r'remembering', re.I), '"Remembering" is retired; say Recording (L21)'),
    (re.compile(r'never\s+remember', re.I), '"Never Remember" is retired; the action is Exclude <App> from Recording… (L14)'),
    (re.compile(r'\b(pause|resume|stop|start)\s+capture\b', re.I), 'capture verbs are retired; say Pause for / Resume Recording / Stop Recording / Start Recording'),
]
TOMORROW = re.compile(r'tomorrow', re.I)
PAUSE_CONTEXT = re.compile(r'paus|resume|until', re.I)
COUNT = re.compile(r'\d[^"]*remembered')
COUNT_HELPER = re.compile(r'\bfunc\s+momentsRemembered\b')
REQUIRED = ['Start Recording', 'Stop Recording', 'Resume Recording', 'Pause for', 'Needs Permission',
            'Open System Settings', "Search your notes and what you've seen"]
# (file, view type, who removes it). Empty: the three legacy capture views it listed (PauseCaptureMenu,
# CaptureControls and CaptureMenuRows in CaptureControls.swift) were deleted by I2 in wave 3b, so every literal in
# Sources is checked with no allowance. The mechanism stays for a future unbuilt view.
LEGACY_UNBUILT = []

failures = []
passes = 0


def ok(condition, message, detail=''):
    global passes
    if condition:
        passes += 1
        print('PASS ' + message)
    else:
        failures.append(message + (f' ({detail})' if detail else ''))


def helper_ranges(code, pairs):
    """Offsets covered by the body of `momentsRemembered`."""
    ranges = []
    for m in COUNT_HELPER.finditer(code):
        brace = code.find('{', m.end())
        if brace >= 0 and brace in pairs:
            ranges.append((brace, pairs[brace]))
    return ranges


def declaration_ranges(code, pairs, name):
    """Body ranges of `struct|class|enum <name>` in scanned code."""
    ranges = []
    for m in re.finditer(r'\b(?:struct|class|enum)\s+' + re.escape(name) + r'\b', code):
        brace = code.find('{', m.end())
        if brace in pairs:
            ranges.append((brace, pairs[brace]))
    return ranges


def legacy_allowance():
    """{rel: [(start, end, type, owner)]} for LEGACY_UNBUILT views that nothing in Sources builds, and the list of
    allowances that matched no declaration (to remove) or are void because something builds the view."""
    scanned = {}
    for path in swift_files('Sources', recursive=True):
        code, _ = scan(path.read_text())
        scanned[str(path.relative_to(ROOT))] = (code, matching_braces(code))
    legacy_bodies = {}
    for rel, name, owner in LEGACY_UNBUILT:
        if rel in scanned:
            code, pairs = scanned[rel]
            legacy_bodies[(rel, name)] = declaration_ranges(code, pairs, name)
    allowed, notes = {}, []
    for rel, name, owner in LEGACY_UNBUILT:
        bodies = legacy_bodies.get((rel, name), [])
        if not bodies:
            notes.append(f'NOTE legacy allowance unused: {name} is gone from {rel}; remove it from LEGACY_UNBUILT')
            continue
        callers = []
        for other, (code, _) in scanned.items():
            inside = [r for (f, _), rs in legacy_bodies.items() if f == other for r in rs]
            for m in re.finditer(r'(?<![\w.])' + re.escape(name) + r'\s*\(', code):
                if not any(a < m.start() < b for a, b in inside):
                    callers.append(f'{other}:{line_of(code, m.start())}')
        if callers:
            notes.append(f'NOTE legacy allowance void: {name} is built at {", ".join(callers)}, so its literals are checked')
            continue
        for a, b in bodies:
            allowed.setdefault(rel, []).append((a, b, name, owner))
    return allowed, notes


def main():
    retired, pending, tomorrow, remembered = [], [], [], []
    exact = {text: [] for text in REQUIRED}
    files = literal_count = 0
    allowed, notes = legacy_allowance()
    for path in (p for folder in SCOPE for p in swift_files(folder)):
        rel = str(path.relative_to(ROOT))
        source = path.read_text()
        code, literals = scan(source)
        pairs = matching_braces(code)
        helpers = helper_ranges(code, pairs)
        lines = source.splitlines()
        files += 1
        literal_count += len(literals)
        for lit in literals:
            where = f'{rel}:{line_of(source, lit.start)}'
            legacy = next((f'{name}, removed by {owner}' for a, b, name, owner in allowed.get(rel, []) if a < lit.start < b), None)
            for pattern, why in RETIRED:
                if pattern.search(lit.text):
                    (pending if legacy else retired).append(f'{where} "{lit.text}"' + (f' (unbuilt legacy view {legacy})' if legacy else f': {why}'))
            if TOMORROW.search(lit.text):
                ln = line_of(source, lit.start)
                context = ' '.join(lines[max(0, ln - 3):ln + 2])
                if PAUSE_CONTEXT.search(context):
                    tomorrow.append(f'{where} "{lit.text}"')
            if re.search(r'remembered', lit.text, re.I) and not COUNT.search(lit.text) \
                    and not any(a < lit.start < b for a, b in helpers):
                remembered.append(f'{where} "{lit.text}"')
            if lit.text in exact:
                exact[lit.text].append(where)
    ok(files >= 60 and literal_count >= 2000, 'scanned the string literals of Sources/MemoryUI and Sources/MacMemApp',
       f'{files} files, {literal_count} literals')
    ok(not retired, 'no retired vocabulary in literals: remembering, Never Remember, Pause/Resume/Stop/Start capture',
       '; '.join(retired))
    ok(not tomorrow, 'no Tomorrow in a pause context (pause presets are 5/15/30/120 minutes only)', '; '.join(tomorrow))
    ok(not remembered, '"remembered" appears only in counts (after a digit, or in DaydreamFormat.momentsRemembered)',
       '; '.join(remembered))
    for text in REQUIRED:
        ok(bool(exact[text]), f'the literal "{text}" exists', 'missing')
    for line in pending:
        print('PENDING ' + line)
    for line in notes:
        print(line)
    for message in failures:
        print('FAIL: ' + message, file=sys.stderr)
    print(f'{"FAIL" if failures else "PASS"} check_state_vocabulary: {passes} passed, {len(failures)} failed')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
