"""Read-only artifact/build audit. Does not establish macOS 15 runtime execution."""
import hashlib, json, pathlib, re, subprocess, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from macos15_runtime_archive import archive_from_folder

root = pathlib.Path(sys.argv[1]).resolve()
source = pathlib.Path(__file__).parent / "Sources/WriterBackend/MacOS15Runtime.swift"
pins = re.findall(r'\("([^"]+\.dylib)",(\d+),"([a-f0-9]{64})"\)', source.read_text())
assert len(pins) == 7
archive_pin = re.findall(r'archiveSHA256 = "([a-f0-9]{64})"', source.read_text())
assert len(archive_pin) == 1
commands = json.loads((root / "build/compile_commands.json").read_text())
compiled = [r for r in commands if pathlib.Path(r["file"]).suffix in (".c", ".cpp", ".m")]
assert compiled and any(r["file"].endswith("ggml-metal-device.m") for r in compiled)
for row in compiled:
    assert "-mmacosx-version-min=15.0" in row["command"]
    assert "-Werror=unguarded-availability-new" in row["command"]
    assert re.search(r"-ffile-prefix-map=\S+=llama\.cpp(\s|$)", row["command"])  # no build folder in the bytes
assert "error:" not in (root / "build.log").read_text()
names = {name for name, _, _ in pins}
assert {p.name for p in (root / "runtime").iterdir()} == names
# The pinned archive hash is the canonical archive of these exact files (macos15_runtime_archive.py).
archive = archive_from_folder(root)
assert hashlib.sha256(archive).hexdigest() == archive_pin[0]
if (root / "runtime.tar").exists():
    assert not (root / "runtime.tar").is_symlink() and (root / "runtime.tar").read_bytes() == archive
report = {"compiled_translation_units": len(compiled), "archive_sha256": archive_pin[0], "libraries": [], "physical_macos15_execution": False}
for name, size, sha in pins:
    p = root / "runtime" / name
    assert not p.is_symlink() and p.stat().st_size == int(size)
    assert hashlib.sha256(p.read_bytes()).hexdigest() == sha
    assert not any(marker in p.read_bytes() for marker in (str(root).encode(), b"/Users/", b"/Volumes/", b"/private/"))
    arch = subprocess.check_output(["lipo", "-archs", str(p)], text=True).strip()
    assert arch == "arm64"
    load = subprocess.check_output(["otool", "-l", str(p)], text=True)
    assert re.findall(r"\bminos (\S+)", load) == ["15.0"]
    rpaths = re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (\S+)", load)
    assert rpaths == ["@loader_path"]
    deps = [line.strip().split(" (", 1)[0] for line in subprocess.check_output(["otool", "-L", str(p)], text=True).splitlines()[1:]]
    assert all(d.startswith(("/usr/lib/", "/System/Library/Frameworks/")) or (d.startswith("@rpath/") and d[7:] in names) for d in deps)
    imports = subprocess.check_output(["nm", "-u", str(p)], text=True).splitlines()
    report["libraries"].append(dict(name=name, bytes=int(size), sha256=sha, arch=arch, minos="15.0", dependencies=deps, imports=imports))
print(json.dumps(report, indent=2))
