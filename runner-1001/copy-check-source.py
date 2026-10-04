#!/usr/bin/env python3
"""Prepare scratch-only check source; never edit source or read OS permissions.
DEVELOPMENT_SOURCE_CHECKS provides fake keys but its permission default is live.
Override only those defaults here. Every fixture can still inject its own values.
"""
import sys
from pathlib import Path
path=Path(sys.argv[1]); socket_root=sys.argv[2]
text=path.read_text().replace("/private/tmp/daydream-",socket_root+"/daydream-")
def replace_once(old,new):
    global text
    if text.count(old)!=1:
        raise SystemExit("Headless seam drift: "+path.name)
    text=text.replace(old,new)
if path.name=="MacMemApp.swift":
    replace_once("static var startInput:(EventCapture)->Bool = { $0.start() }", "static var startInput:(EventCapture)->Bool = { _ in false }")
    replace_once("static var permissionRead:(()->PermissionSnapshot)?", "static var permissionRead:(()->PermissionSnapshot)? = { PermissionSnapshot(accessibility:false,inputMonitoring:false) }")
    replace_once("static var permissionsGranted:()->Bool = { Coordinator.permitted }", "static var permissionsGranted:()->Bool = { false }")
if path.name=="Coordinator.swift":
    replace_once("static var permitted: Bool { AXIsProcessTrusted() && CGPreflightListenEventAccess() }", "static var permitted: Bool { false }")
if path.name=="dd-app-model-checks.swift":
    replace_once("let fresh=PermissionSnapshot(accessibility:AXIsProcessTrusted(),inputMonitoring:CGPreflightListenEventAccess())", "let fresh=MemoryViewModel.permissionRead!()")
sys.stdout.write(text)
