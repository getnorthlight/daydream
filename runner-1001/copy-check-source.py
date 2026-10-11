#!/usr/bin/env python3
"""Prepare scratch-only check source; never edit source or read OS permissions.
DEVELOPMENT_SOURCE_CHECKS provides fake keys but its permission default is live.
Override only those defaults here. Every fixture can still inject its own values.

  copy-check-source.py FILE ROOT            print FILE with /private/tmp/daydream- moved to ROOT/daydream-
  copy-check-source.py --app DIR ROOT FILES  write each app source FILE into DIR (run-checks.sh appsrc). The app copy
      reads its root at run time (DD_CHECK_SOCKROOT, which run-checks.sh exports as ROOT) instead of a ROOT literal,
      so one precompiled app module (runner-1001/app-module.sh) serves every run; DIR gets DDCheckSocketRoot.swift.
"""
import sys
from pathlib import Path

RUNTIME_ROOT = "\\(DDCheckSocketRoot.path)"
HELPER = '''import Foundation
// runner-1001/copy-check-source.py --app: the folder the runner moved /private/tmp/daydream-* to (DD_CHECK_SOCKROOT),
// read at run time so the precompiled app module (runner-1001/app-module.sh) is the same for every run. Unset, it is a
// path nothing can be under, so a check that lost the variable fails instead of reaching the real /private/tmp.
enum DDCheckSocketRoot {
    static let path: String = ProcessInfo.processInfo.environment["DD_CHECK_SOCKROOT"] ?? "/dev/null/DD_CHECK_SOCKROOT-unset"
}
'''


def convert(path, socket_root):
    text = path.read_text().replace("/private/tmp/daydream-", socket_root + "/daydream-")

    def replace_once(old, new):
        nonlocal text
        if text.count(old) != 1:
            raise SystemExit("Headless seam drift: " + path.name)
        text = text.replace(old, new)
    if path.name == "MacMemApp.swift":
        replace_once("static var startInput:(EventCapture)->Bool = { $0.start() }", "static var startInput:(EventCapture)->Bool = { _ in false }")
        replace_once("static var permissionRead:(()->PermissionSnapshot)?", "static var permissionRead:(()->PermissionSnapshot)? = { PermissionSnapshot(accessibility:false,inputMonitoring:false) }")
        replace_once("static var permissionsGranted:()->Bool = { Coordinator.permitted }", "static var permissionsGranted:()->Bool = { false }")
    if path.name == "Coordinator.swift":
        replace_once("static var permitted: Bool { AXIsProcessTrusted() && CGPreflightListenEventAccess() }", "static var permitted: Bool { false }")
    if path.name == "dd-app-model-checks.swift":
        replace_once("let fresh=PermissionSnapshot(accessibility:AXIsProcessTrusted(),inputMonitoring:CGPreflightListenEventAccess())", "let fresh=MemoryViewModel.permissionRead!()")
    return text


if sys.argv[1] == "--app":
    out, files = Path(sys.argv[2]), sys.argv[4:]
    out.mkdir(parents=True, exist_ok=True)
    for f in files:
        p = Path(f)
        (out / p.name).write_text(convert(p, RUNTIME_ROOT))
    (out / "DDCheckSocketRoot.swift").write_text(HELPER)
else:
    sys.stdout.write(convert(Path(sys.argv[1]), sys.argv[2]))
