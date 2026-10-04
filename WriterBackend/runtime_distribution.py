"""Read-only transformation/enrollment preparation. Never signs or enrolls hashes.

  plan / candidate      the 2026-09-13 upstream (macOS 26) runtime: v1 manifests.
  identifiers           the code-signing identifier of each of the seven macOS 15 libraries.
  check-prepared DIR    a prepare_writer_macos15.py output folder, before the owner signs it.
  manifest-v2 DIR CERT  the v2 manifest for the seven SIGNED macOS 15 libraries in DIR (what
                        SignedRuntimeLoader reads), written with fixed formatting so its SHA-256 can be
                        compiled into SignedRuntimePolicy.swift. --prepared checks each file really
                        changed from its prepared copy (was signed); --dry-run-unsigned accepts the
                        prepared copies themselves to test the flow, and marks the output not for pinning.
"""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys

BASE = pathlib.Path(__file__).resolve().parent
# Apple Developer Team ID that signs the writer runtime libraries. It is set
# once, in packaging/signing.json; forks substitute their own team there.
TEAM = json.loads((BASE.parent / "packaging/signing.json").read_text())["apple_team_id"]
sys.path.insert(0, str(BASE.parent / "scripts"))
import writer_payload  # noqa: E402

def digest(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()

def pins():
    source = (BASE / "Sources/WriterBackend/CompatibleInstallation.swift").read_text()
    rows = re.findall(r'RuntimeFile\("([^"]+)", "([^"]+)", (\d+), "([0-9a-f]{64})"\)', source)
    if len(rows) != 7:
        raise ValueError("expected exactly seven source pins")
    return {stem + ".0.dylib": (int(size), sha) for stem, version, size, sha in rows}

def regular(path):
    if path.is_symlink() or path.resolve() != path or not path.is_file():
        raise ValueError("regular unlinked absolute path required")

def dependencies(path):
    output = subprocess.run(["/usr/bin/otool", "-L", str(path)], check=True, capture_output=True, text=True, timeout=10).stdout
    return [line.strip().split(" (", 1)[0] for line in output.splitlines()[1:] if line.strip()]

def plan(source, destination):
    expected = pins()
    if destination.exists() or source == destination or source in destination.parents:
        raise ValueError("fresh separate staging directory required")
    if set(p.name for p in source.iterdir()) != set(expected):
        raise ValueError("unexpected upstream files")
    entries = []
    for name, (size, sha) in expected.items():
        original = source / name; regular(original)
        if original.stat().st_size != size or digest(original) != sha:
            raise ValueError("upstream pin mismatch")
        commands = [["/bin/cp", str(original), str(destination / name)],
                    ["/usr/bin/install_name_tool", "-id", "@loader_path/" + name, str(destination / name)]]
        for dep in dependencies(original)[1:]:
            if dep.startswith("@rpath/") and dep[7:] in expected:
                commands.append(["/usr/bin/install_name_tool", "-change", dep, "@loader_path/" + dep[7:], str(destination / name)])
            elif not dep.startswith(("/usr/lib/", "/System/Library/Frameworks/")):
                raise ValueError("unreviewed dependency")
        entries.append({"name": name, "upstreamSHA256": sha, "upstreamBytes": size, "commands": commands})
    return {"schema": "writer-transform-plan/v1", "executed": False, "teamID": TEAM,
            "mkdir": ["/bin/mkdir", "-m", "700", str(destination)], "files": entries,
            "next": "Execute only in fresh staging with approval. Retain transformed hashes. Authorized signing owner signs each dylib with empty entitlements and hardened runtime, then generates candidate manifest. No R5 mutation."}

def candidate(directory, release, certificate):
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,96}", release) or not re.fullmatch(r"[0-9a-f]{64}", certificate):
        raise ValueError("explicit release ID and leaf DER SHA256 required")
    expected = pins()
    if set(p.name for p in directory.iterdir()) != set(expected): raise ValueError("unexpected distribution files")
    files=[]
    for name, (_, upstream) in expected.items():
        path=directory/name; regular(path)
        for dep in dependencies(path):
            if not ((dep.startswith("@loader_path/") and dep[13:] in expected) or dep.startswith(("/usr/lib/", "/System/Library/Frameworks/"))):
                raise ValueError("untransformed dependency")
        signed=digest(path)
        if signed == upstream: raise ValueError("unchanged upstream artifact")
        files.append({"name":name,"upstreamSHA256":upstream,"signedSHA256":signed,"signedBytes":path.stat().st_size,
                      "signingIdentifier":"com.daydream.writer." + name.removesuffix(".dylib")})
    return {"schema":"daydream-signed-runtime/v1","distributionID":release,
            "upstreamArchiveSHA256":"2cd552419b84b7b16598b95e9dd14572c86ecc13c96789cf06b7025d2dca815f",
            "teamID":TEAM,"certificateSHA256":certificate,"files":files}

# ---------------------------------------------------------------- macOS 15 signed distribution (v2)
def macos15_pins():
    return writer_payload.runtime_pins((BASE / "Sources/WriterBackend/MacOS15Runtime.swift").read_text())

def identifiers():
    return {name: writer_payload.signing_identifier(name) for name in sorted(macos15_pins()["files"])}

def seven(directory, names):
    directory = pathlib.Path(directory)
    if directory.is_symlink() or not directory.is_dir() or set(p.name for p in directory.iterdir()) != set(names):
        raise ValueError("%s must hold exactly the seven libraries" % directory)
    for name in names:
        regular((directory / name).absolute())
    return directory

def check_prepared(folder):
    """A prepare_writer_macos15.py folder: its seven copies are the ones it recorded, from the pinned upstream
    bytes, rewritten to @loader_path, with the identifiers this repository signs with."""
    folder = pathlib.Path(folder).absolute()
    pins = macos15_pins()
    inputs = json.loads((folder / "signing-inputs.json").read_text())
    if inputs.get("schema") != "daydream-writer-signing-inputs/macos15-v2" or inputs.get("signed") is not False \
            or inputs.get("upstreamArchiveSHA256") != pins["archive"]:
        raise ValueError("signing-inputs.json is not an unsigned macos15-v2 preparation of the pinned archive")
    rows = {row["name"]: row for row in inputs["files"]}
    runtime = seven(folder / "runtime", pins["files"])
    if set(rows) != set(pins["files"]):
        raise ValueError("signing-inputs.json does not list the seven pinned libraries")
    for name, (_, upstream) in pins["files"].items():
        data = (runtime / name).read_bytes()
        row = rows[name]
        if row["upstreamSHA256"] != upstream or row["transformedSHA256"] != hashlib.sha256(data).hexdigest() \
                or row["transformedBytes"] != len(data):
            raise ValueError("%s differs from signing-inputs.json or the upstream pin" % name)
        if row["signingIdentifier"] != writer_payload.signing_identifier(name):
            raise ValueError("%s: signing-inputs.json says %r but this repository signs it as %r; re-run "
                             "scripts/prepare_writer_macos15.py" % (name, row["signingIdentifier"], writer_payload.signing_identifier(name)))
        bad = writer_payload.macho_problems(data, set(pins["files"]))
        if bad:
            raise ValueError("%s would be refused by the loader: %s" % (name, "; ".join(bad)))
    return {"prepared": str(folder), "identifiers": identifiers(),
            "transformedSHA256": {name: rows[name]["transformedSHA256"] for name in sorted(rows)}}

def manifest_v2(directory, certificate, release=writer_payload.ID, prepared=None, dry_run=False):
    """(bytes, SHA-256) of the v2 manifest for the seven signed libraries in `directory`."""
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,96}", release) or not re.fullmatch(r"[0-9a-f]{64}", certificate):
        raise ValueError("explicit release ID and leaf DER SHA256 required")
    if certificate != writer_payload.LEAF_SHA256:
        raise ValueError("leaf certificate %s is not the enrolled %s (developer-id-release.py LEAF_SHA256)" % (certificate, writer_payload.LEAF_SHA256))
    if TEAM != writer_payload.TEAM_ID:
        raise ValueError("packaging/signing.json team %s != %s" % (TEAM, writer_payload.TEAM_ID))
    pins = macos15_pins()
    names = set(pins["files"])
    directory = seven(directory, names)
    before = check_prepared(prepared)["transformedSHA256"] if prepared else {}
    files = []
    for name in sorted(names):
        data = (directory / name).read_bytes()
        signed = hashlib.sha256(data).hexdigest()
        bad = writer_payload.macho_problems(data, names)
        if bad:
            raise ValueError("%s would be refused by the loader: %s" % (name, "; ".join(bad)))
        if signed == pins["files"][name][1]:
            raise ValueError("%s is the unchanged upstream library" % name)
        if before and (signed == before[name]) != dry_run:
            raise ValueError("%s %s its prepared copy" % (name, "is unchanged from (not signed?)" if not dry_run else "differs from (dry run takes the prepared copies)"))
        files.append({"name": name, "upstreamSHA256": pins["files"][name][1], "signedSHA256": signed,
                      "signedBytes": len(data), "signingIdentifier": writer_payload.signing_identifier(name)})
    manifest = {"schema": pins["schema"], "distributionID": release, "upstreamArchiveSHA256": pins["archive"],
                "teamID": TEAM, "certificateSHA256": certificate, "files": files}
    raw = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    digest_ = hashlib.sha256(raw).hexdigest()
    problems = writer_payload.manifest_problems(raw, {**pins, "approved": {release: digest_}}, release)
    if problems:
        raise ValueError("generated manifest fails the pipeline's own check: " + "; ".join(problems))
    return raw, digest_

def main():
    parser=argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub=parser.add_subparsers(dest="command",required=True)
    p=sub.add_parser("plan");p.add_argument("source",type=pathlib.Path);p.add_argument("destination",type=pathlib.Path)
    p=sub.add_parser("candidate");p.add_argument("directory",type=pathlib.Path);p.add_argument("release");p.add_argument("certificate_sha256")
    sub.add_parser("identifiers")
    p=sub.add_parser("check-prepared");p.add_argument("folder",type=pathlib.Path)
    p=sub.add_parser("manifest-v2");p.add_argument("directory",type=pathlib.Path);p.add_argument("certificate_sha256")
    p.add_argument("--release",default=writer_payload.ID);p.add_argument("--prepared",type=pathlib.Path)
    p.add_argument("--out",type=pathlib.Path,required=True,help="new file for the manifest bytes");p.add_argument("--dry-run-unsigned",action="store_true")
    args=parser.parse_args()
    if args.command == "identifiers":
        for name, identifier in identifiers().items(): print(name, identifier)
        return
    if args.command == "check-prepared":
        print(json.dumps(check_prepared(args.folder),sort_keys=True,indent=2)); return
    if args.command == "manifest-v2":
        if args.out.exists() or args.out.is_symlink(): raise SystemExit("--out must be a new file")
        raw, digest_ = manifest_v2(args.directory,args.certificate_sha256,args.release,args.prepared,args.dry_run_unsigned)
        args.out.write_bytes(raw)
        print(("DRY RUN, NOT FOR PINNING: " if args.dry_run_unsigned else "") + "manifest SHA-256 " + digest_ + "  " + str(args.out))
        return
    result=plan(args.source,args.destination) if args.command == "plan" else candidate(args.directory,args.release,args.certificate_sha256)
    print(json.dumps(result,sort_keys=True,indent=2))
if __name__ == "__main__": main()
