#!/usr/bin/env python3
"""Scratch copies of Sources/MacMemApp/*.swift for scripts/realism-app-checks.swift: the headless permission seams of
runner-1001/copy-check-source.py, plus two read-only windows the realism checks need. Never edits the tree.

  realism-seams.py SRC_DIR OUT_DIR SOCKET_ROOT

  WriterIntegration.swift   `coreBinding` readable (was private): bug 4 reads the binding WriterIntegration itself
                            built in configure(store:), not only the static it calls.
  DaydreamOnboarding.swift  after each draw, what the last page offers (RealismReview, appended to that copy): its
                            sentence, its Open Settings button and whether its main button is enabled. Bug 12 counts
                            the buttons; the page itself is unchanged.

Each rewrite must match exactly once, or this stops with "realism seam drift" (the source moved; update the seam).
"""
import contextlib
import io
import runpy
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
COPY = HERE.parent / 'runner-1001' / 'copy-check-source.py'

EXTRA = {
    'WriterIntegration.swift': [
        ('    private var coreBinding:CoreWriterBinding?', '    var coreBinding:CoreWriterBinding?'),
    ],
    'DaydreamOnboarding.swift': [
        ('        let _ = Self.drawnPagesForChecks.append(opened ? page : nil)\n',
         '        let _ = Self.drawnPagesForChecks.append(opened ? page : nil)\n'
         '        let _ = RealismReview.drawn = RealismReview(page: opened ? page : nil, button: continueTitle,\n'
         '            message: page == .review ? startBlocker.flatMap { $0.fix == nil ? $0.text : nil } : nil,\n'
         '            openSettings: page == .review && startBlocker?.settings == true, enabled: opened && canContinue, error: error)\n'),
    ],
}


REVIEW_TYPE = """
#if DEVELOPMENT_SOURCE_CHECKS
/// realism-seams.py: what setup's page offered after its last draw (scripts/realism-app-checks.swift, bug 12).
struct RealismReview {
    var page: DaydreamOnboardingPage?
    var button: String
    var message: String?
    var openSettings: Bool
    var enabled: Bool
    var error: String?
    static var drawn: RealismReview?
}
#endif
"""


def headless(path, root):
    """copy-check-source.py's output for `path` (run in this process: one interpreter for every file)."""
    argv, out = sys.argv, io.StringIO()
    try:
        sys.argv = [str(COPY), str(path), root]
        with contextlib.redirect_stdout(out):
            runpy.run_path(str(COPY), run_name='__main__')
    finally:
        sys.argv = argv
    return out.getvalue()


def main():
    if len(sys.argv) != 4:
        raise SystemExit('usage: realism-seams.py SRC_DIR OUT_DIR SOCKET_ROOT')
    src, out, root = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    out.mkdir(parents=True, exist_ok=True)
    files = sorted(src.glob('*.swift'))
    if not files:
        raise SystemExit('realism-seams: no Swift sources in %s' % src)
    for path in files:
        text = headless(path, root)
        for old, new in EXTRA.get(path.name, []):
            if text.count(old) != 1:
                raise SystemExit('realism seam drift: %s (%d matches for %r)' % (path.name, text.count(old), old[:60]))
            text = text.replace(old, new)
        (out / path.name).write_text(text)
    # The type the DaydreamOnboarding seam sets, in the app sources themselves (so a precompiled app module carries it).
    with open(out / 'DaydreamOnboarding.swift', 'a') as f:
        f.write(REVIEW_TYPE)
    missing = [name for name in EXTRA if not (src / name).is_file()]
    if missing:
        raise SystemExit('realism seam drift: %s not in %s' % (', '.join(missing), src))


if __name__ == '__main__':
    main()
