"""Verify final companion bytes without running any packaged executable."""
import hashlib
import json
from pathlib import Path
import sys
import functional_payload
import search_payload
import writer_payload

contents = (Path(sys.argv[1]) / "Contents").resolve()
functional_payload.verify_search(contents.parent)
search_payload.paths(contents.parent)
manifest = json.loads((contents / "Resources/Companions.json").read_text())
if not manifest.get("sha256"):
    raise SystemExit("Missing companion hashes")
if not {"MacOS/mac-mem", "MacOS/mac-mem-backup", "Resources/before_turn.py"} <= manifest["sha256"].keys():
    raise SystemExit("Missing required companion hash")
if not functional_payload.paths(contents.parent) <= manifest['sha256'].keys():
    raise SystemExit('Missing functional companion hash')
if not search_payload.paths(contents.parent) <= manifest['sha256'].keys():
    raise SystemExit('Missing local search companion hash')
if not writer_payload.paths(contents.parent) <= manifest['sha256'].keys():
    raise SystemExit('Missing writer runtime companion hash')
for name, expected in manifest["sha256"].items():
    path = (contents / name).resolve()
    if not path.is_relative_to(contents):
        raise SystemExit("Companion escapes bundle: " + name)
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit("Companion mismatch: " + name)
print("Companion hashes match")
