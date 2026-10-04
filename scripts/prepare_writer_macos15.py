"""Prepare exact macOS15 writer copies for root signing review. No key use/load.

Only install_name_tool runs on new copies. Original pins remain immutable.
The output is NOT a signed manifest and cannot enroll itself in the loader.

The archive is the canonical runtime.tar that WriterBackend/build_macos15_runtime.py
writes (see WriterBackend/macos15_runtime_archive.py). The destination is any fresh
absolute folder in a private parent, so the prepared copies can be kept.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "WriterBackend"))
sys.path.insert(0, str(ROOT / "scripts"))
from macos15_runtime_archive import canonical_archive  # noqa: E402
from writer_payload import ID as DISTRIBUTION_ID, signing_identifier  # noqa: E402

ARCHIVE = "714bdf726e3c9c6c81f346dc87c1188c8c4e5ae4bdb93a1ec690f4a73252672d"
PROFILE = "9e3f9d493961b8f0456dcd13e8ccabc45773ed8aec2523a69abe8987e74509ee"
LICENSE = "94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d"

def sha(data):
    return hashlib.sha256(data).hexdigest()

def require(ok, message):
    if not ok:
        raise ValueError(message)

def pins():
    data = (ROOT / "WriterBackend/Sources/WriterBackend/MacOS15Runtime.swift").read_bytes()
    require(sha(data) == PROFILE, "Writer profile drift; new root review required")
    rows = re.findall(r'\("([^"/]+\.dylib)",(\d+),"([a-f0-9]{64})"\)', data.decode())
    require(len(rows) == 7, "Expected exact seven pins")
    return {name: (int(size), digest) for name, size, digest in rows}

def read_archive(path, expected):
    require(not path.is_symlink() and path.is_file(), "Archive must be a regular file")
    raw = path.read_bytes()
    require(sha(raw) == ARCHIVE, "Archive pin mismatch")
    with tarfile.open(path, "r:") as archive:
        members = archive.getmembers()
        names = [m.name.rstrip("/") for m in members]
        require(len(names) == len(set(names)), "Duplicate archive entries")
        require(set(names) == {"runtime", "runtime-LICENSE", *("runtime/" + n for n in expected)}, "Unexpected archive layout")
        result = {}
        for m in members:
            if m.name.rstrip("/") == "runtime":
                require(m.isdir(), "Runtime must be directory")
                continue
            require(m.isfile(), "Links/special members refused")
            data = archive.extractfile(m).read()
            if m.name == "runtime-LICENSE":
                require(sha(data) == LICENSE, "License pin mismatch")
            else:
                size, digest = expected[m.name.split("/")[1]]
                require(len(data) == size and sha(data) == digest, "Runtime file pin mismatch")
            result[m.name] = data
    require(canonical_archive({name.removeprefix("runtime/"): data for name, data in result.items()}) == raw,
            "Archive is not the canonical runtime archive")
    return result

def deps(path):
    output = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True)
    return [line.strip().split(" (", 1)[0] for line in output.splitlines()[1:] if line.strip()]

def dependency_changes(dependencies, expected):
    changes = []
    for dep in dependencies:
        if dep.startswith("@rpath/") and dep[7:] in expected:
            changes.append((dep, "@loader_path/" + dep[7:]))
        elif dep.startswith("@loader_path/") and dep[13:] in expected:
            pass
        else:
            require(".." not in dep and dep.startswith(("/usr/lib/", "/System/Library/Frameworks/")), "Unreviewed dependency: " + dep)
    return changes

def private_parent(parent):
    """The destination's parent: a real directory owned by this user or root, not writable by
    others unless sticky (like /private/tmp), so nobody else can swap the prepared copies."""
    try:
        info = parent.lstat()
    except OSError:
        return False
    return (stat.S_ISDIR(info.st_mode) and info.st_uid in (os.getuid(), 0)
            and (not info.st_mode & (stat.S_IWGRP | stat.S_IWOTH) or info.st_mode & stat.S_ISVTX))

def check_destination(destination):
    require(destination.is_absolute() and not destination.exists() and not destination.is_symlink()
            and destination.parent.resolve() == destination.parent and private_parent(destination.parent),
            "Fresh absolute destination in a private folder required")

def prepare(archive, destination):
    expected = pins()
    files = read_archive(archive, expected)
    check_destination(destination)
    destination.mkdir(mode=0o700)
    runtime = destination / "runtime"
    runtime.mkdir(mode=0o700)
    (destination / "runtime-LICENSE").write_bytes(files["runtime-LICENSE"])
    entries = []
    for name, (size, upstream) in expected.items():
        path = runtime / name
        path.write_bytes(files["runtime/" + name])
        path.chmod(0o755)
        build = subprocess.check_output(["/usr/bin/vtool", "-show-build", str(path)], text=True)
        require("platform MACOS" in build and "minos 15.0" in build, "Wrong runtime minimum OS")
        architecture = subprocess.check_output(["/usr/bin/lipo", "-archs", str(path)], text=True).strip()
        require(architecture == "arm64", "Wrong architecture")
        changes = dependency_changes(deps(path)[1:], expected)
        commands = [["/usr/bin/install_name_tool", "-id", "@loader_path/" + name, str(path)]]
        commands += [["/usr/bin/install_name_tool", "-change", old, new, str(path)] for old, new in changes]
        for command in commands:
            subprocess.run(command, check=True)
        require(not dependency_changes(deps(path), expected), "Untransformed references remain")
        entries.append({"name": name, "upstreamSHA256": upstream, "upstreamBytes": size,
                        "transformedSHA256": sha(path.read_bytes()), "transformedBytes": path.stat().st_size,
                        "signingIdentifier": signing_identifier(name),
                        "entitlements": {}, "hardenedRuntime": True, "transformationCommands": commands})
    result = {"schema": "daydream-writer-signing-inputs/macos15-v2", "signed": False,
              "admissionGranted": False, "targetManifestSchema": "daydream-signed-runtime/macos15-v2",
              "upstreamArchiveSHA256": ARCHIVE, "profileSHA256": PROFILE, "licenseSHA256": LICENSE,
              "sourceCommit": "b14e3fb90ca8c760f4254ddc9aa7845ebbdb2edf", "distributionID": DISTRIBUTION_ID,
              "files": entries,
              "remaining": ["Root reviews transformed bytes and named identity/certificate", "Root signs all seven copies with hardened runtime and empty entitlements",
                            "Verify signatures, dependencies and final signed hashes; generate bounded v2 manifest", "Reviewed compiled manifest hash enrollment and normal app freeze", "Final host/nested trust and macOS15.7.2 synthetic runtime tests"]}
    (destination / "signing-inputs.json").write_text(json.dumps(result, indent=2) + "\n")
    print(destination / "signing-inputs.json")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    prepare(args.archive, args.destination)
