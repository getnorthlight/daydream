"""Copy-only functional-trial prerequisites. Never builds, signs, launches or installs.

prepare requires a root-frozen NORMAL app with the writer already assembled.
refresh runs AFTER root signs nested code and BEFORE root seals the outer app.
verify is read-only and must also run against the final extracted artifact.
This is not runtime admission, notarization, or distribution approval.
"""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

SERVER = "Helpers/typesense-server"
RUNTIME = "Resources/typesense-runtime-v1.json"
ARCHIVE_HASH = "7d8d6d0c33930ad20ea23dd184250547b16615944be891b2078e8a075152fa7e"
SERVER_HASH = "086d498fbf0afb45091f4e28b50e803a3633daac506388a5f71e5ed90407c91f"
NOTICES = ("Resources/Typesense-LICENSE.txt", "Resources/Typesense-NOTICES.txt")

def require(ok, message):
    if not ok:
        raise ValueError(message)

def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def regular(path, executable=False):
    require(path.is_file() and not path.is_symlink(), "Missing/unsafe file: " + str(path))
    require(path.resolve() == path.absolute(), "Symlink ancestor: " + str(path))
    require(not path.stat().st_mode & 0o022, "Writable by others: " + str(path))
    require(not executable or path.stat().st_mode & 0o111, "Not executable: " + str(path))
    return path

def contained(root, name):
    require(isinstance(name, str) and name and not Path(name).is_absolute()
            and ".." not in Path(name).parts, "Unsafe relative path")
    path = root / name
    require(path.resolve().is_relative_to(root.resolve()), "Path escapes bundle")
    return path

def normal(app):
    info = plistlib.loads(regular(app / "Contents/Info.plist").read_bytes())
    require(app.name == "DayDream.app" and info.get("CFBundleIdentifier") == "com.getnorthlight.daydream",
            "Requires NORMAL DayDream.app, never a development/synthetic app")
    require(not info.get("DaydreamDevelopmentTrial"), "Development OFF guard must not be repurposed")
    for name in ("MacMem", "mac-mem", "mac-mem-backup"):
        regular(app / "Contents/MacOS" / name, executable=True)

def writer(app, receipt):
    require(receipt is not None, "Missing Phone/root writer runtime handoff (--writer-receipt)")
    data = json.loads(regular(receipt).read_text())
    # This receipt is a packaging handoff, not the native loader's approval table.
    require(data.get("schema") == "daydream-functional-writer-handoff/v1"
            and data.get("targetOS") == "15.7.2" and data.get("architecture") == "arm64",
            "Missing compatible writer handoff for ARM64 macOS 15.7.2")
    require(data.get("files") and data.get("admissionEvidence") and data.get("modelDelivery"),
            "Writer handoff needs files, admission evidence and model delivery plan")
    for name, expected in data["files"].items():
        require(digest(regular(contained(app / "Contents", name))) == expected,
                "Writer handoff hash mismatch: " + name)
    return data

def runtime_manifest(app):
    c = app / "Contents"
    return {"version": 1, "serverSHA256": digest(regular(c / SERVER, True)),
            "supervisorSHA256": digest(regular(c / "MacOS/mac-mem", True))}

def inventory(app):
    return {str(p.relative_to(app)): ("symlink:" + str(p.readlink()) if p.is_symlink() else digest(p))
            for p in sorted(app.rglob("*")) if p.is_file() or p.is_symlink()}

def distribution_review(path, license_path, notices_path):
    review = json.loads(regular(path).read_text())
    require(review.get("schema") == "daydream-typesense-distribution-review/v1"
            and review.get("completeCorrespondingSource") is True
            and review.get("reviewedBy") and review.get("deliveryPlan")
            and review.get("correspondingSourceSHA256"), "Incomplete Typesense corresponding-source/distribution review")
    require(review.get("serverSHA256") == SERVER_HASH
            and review.get("licenseSHA256") == digest(license_path)
            and review.get("noticesSHA256") == digest(notices_path), "Distribution review does not bind these materials")

def prepare(args):
    normal(args.app)
    writer_data = writer(args.app, args.writer_receipt)
    require(args.freeze is not None, "Missing root source freeze inventory")
    require(inventory(args.app) == json.loads(regular(args.freeze).read_text()), "Frozen app drift")
    for value, label in ((args.server, "Typesense runtime"), (args.archive, "Typesense archive"),
                         (args.license, "GPL license"), (args.notices, "notices"),
                         (args.distribution_review, "corresponding-source/distribution review")):
        require(value is not None, "Missing " + label)
        regular(value)
    require(digest(args.server) == SERVER_HASH and digest(args.archive) == ARCHIVE_HASH,
            "Unreviewed Typesense bytes/archive")
    require("GNU GENERAL PUBLIC LICENSE" in args.license.read_text(), "Missing GPL license text")
    require(args.notices.stat().st_size > 0 and args.distribution_review.stat().st_size > 0,
            "Empty notices/distribution review")
    distribution_review(args.distribution_review, args.license, args.notices)
    require(not (args.app / "Contents" / SERVER).exists(), "Source already has Typesense; new reviewed freeze required")
    # Structural compatibility only; never execute the server.
    machine = subprocess.check_output(["/usr/bin/file", str(args.server)], text=True)
    build = subprocess.check_output(["/usr/bin/vtool", "-show-build", str(args.server)], text=True)
    require("arm64" in machine and "platform MACOS" in build and "minos 13.1" in build,
            "Unexpected Typesense platform/minimum OS")
    stage = Path(tempfile.mkdtemp(prefix="daydream-functionalTrial-", dir="/private/tmp"))
    app = stage / "DayDream.app"
    subprocess.run(["/usr/bin/ditto", str(args.app), str(app)], check=True)
    require(inventory(app) == inventory(args.app), "Copy differs from frozen app")
    # Only the fresh copy's obsolete OUTER seal is removed, never a nested signature.
    seal = app / "Contents/_CodeSignature"
    if seal.exists():
        require(not seal.is_symlink(), "Unsafe outer seal")
        shutil.rmtree(seal)
    c = app / "Contents"
    (c / "Helpers").mkdir(exist_ok=True)
    shutil.copyfile(args.server, c / SERVER)
    (c / SERVER).chmod(0o755)
    for source, target in ((args.license, NOTICES[0]), (args.notices, NOTICES[1])):
        shutil.copyfile(source, c / target)
        (c / target).chmod(0o644)
    companions_path = c / "Resources/Companions.json"
    companions = json.loads(regular(companions_path).read_text())
    companions["sha256"].update(writer_data["files"])
    companions_path.write_text(json.dumps(companions, sort_keys=True) + "\n")
    receipt = {"schema": 1, "sourceInventory": inventory(args.app),
               "archiveSHA256": ARCHIVE_HASH, "upstreamServerSHA256": SERVER_HASH,
               "distributionReviewSHA256": digest(args.distribution_review),
               "writerReceiptSHA256": digest(args.writer_receipt), "status": "UNSEALED, NOT RUNTIME ACCEPTED"}
    (stage / "preparation.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(str(app))
    print("Root must sign nested code, refresh manifests, then outer-seal and verify extracted copy.")

def manifests(app, refresh):
    normal(app)
    c = app / "Contents"
    expected = runtime_manifest(app)
    for name in NOTICES:
        regular(c / name)
    companion_path = regular(c / "Resources/Companions.json")
    companions = json.loads(companion_path.read_text())
    hashes = companions["sha256"]
    require({"MacOS/mac-mem", "MacOS/mac-mem-backup", "Resources/before_turn.py"} <= hashes.keys(),
            "Missing base companion entries")
    if refresh:
        require(str(app.absolute()).startswith("/private/tmp/daydream-functionalTrial-")
                and not (c / "_CodeSignature").exists(), "Refresh only fresh UNSEALED functional staging copy")
        (c / RUNTIME).write_text(json.dumps(expected, sort_keys=True) + "\n")
        # All existing companions, including writer handoff entries, follow final bytes.
        for name in set(hashes) | {SERVER, RUNTIME, *NOTICES}:
            hashes[name] = digest(regular(contained(c, name)))
        companion_path.write_text(json.dumps(companions, sort_keys=True) + "\n")
    else:
        require(json.loads(regular(c / RUNTIME).read_text()) == expected, "Stale search runtime hashes")
        require({SERVER, RUNTIME, *NOTICES} <= hashes.keys(), "Missing search companion entries")
        for name, value in hashes.items():
            require(digest(regular(contained(c, name))) == value, "Stale companion: " + name)
    print("Final-byte manifests refreshed; outer seal still required" if refresh else "Final-byte manifests match; trust not assessed")

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("action", choices=["prepare", "refresh", "verify"])
    p.add_argument("--app", required=True, type=Path)
    for name in ("writer-receipt", "freeze", "server", "archive", "license", "notices", "distribution-review"):
        p.add_argument("--" + name, type=Path)
    args = p.parse_args()
    try:
        if args.action == "prepare":
            prepare(args)
        else:
            manifests(args.app, args.action == "refresh")
            if args.action == "verify":
                for target in (args.app / "Contents" / SERVER,
                               args.app / "Contents/MacOS/mac-mem",
                               args.app / "Contents/MacOS/mac-mem-backup",
                               args.app / "Contents/Frameworks/Sparkle.framework", args.app):
                    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(target)], check=True)
                print("Strict structural seals passed. Developer ID/notarization/runtime acceptance remain separate.")
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        p.exit(2, "Functional trial refused: " + str(error) + "\n")

if __name__ == "__main__":
    main()
