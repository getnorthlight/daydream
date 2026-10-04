"""Stage a local DayDream UI update. Never build, install, launch, or use a key."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess


SOURCE = Path(__file__).resolve().parents[1]
WORKSPACE = SOURCE.parent


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inventory(app):
    result = {}
    for path in sorted(app.rglob("*")):
        name = str(path.relative_to(app))
        if path.is_symlink():
            result[name] = "symlink:" + os.readlink(path)
        elif path.is_file():
            result[name] = digest(path)
    return result


def run(*arguments):
    subprocess.run([str(value) for value in arguments], check=True)


def stage(args):
    base = args.base.expanduser().resolve(strict=True)
    binary = args.binary.expanduser().resolve(strict=True)
    output = args.output.expanduser().absolute()
    require(output.parent.resolve() == output.parent, "Output parent must be a real directory")
    require(output.is_relative_to(WORKSPACE) or output.is_relative_to(Path("/private/tmp")),
            "Stage only inside this workspace or /private/tmp")
    require(not output.exists() and not output.is_relative_to(base), "A fresh staging directory is required")
    require(binary.is_file() and os.access(binary, os.X_OK), "A compiled executable is required")
    require(b"--capture-fixture-trial" not in binary.read_bytes(), "A QA fixture executable cannot replace a normal installed app")
    require(base.name == "DayDream.app", "Expected the normal DayDream.app baseline")
    require(not (base / "Contents/Resources/FunctionalTrial.json").exists(),
            "A Developer ID functional payload cannot use this local ad-hoc helper")
    info = plistlib.loads((base / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") in ("com.getnorthlight.daydream", "com.getnorthlight.daydream.adhoc"),
            "Normal bundle identity is required")
    require("DaydreamQAHarness" not in info, "Do not install a private QA harness as a normal UI update")
    require(not info.get("DaydreamDevelopmentTrial"), "Do not repurpose a development trial")
    require(all(info.get(key) is False for key in
                ("SUAllowsAutomaticUpdates", "SUAutomaticallyUpdate", "SUEnableAutomaticChecks")),
            "Expected disabled updater flags")
    require(args.build.isdecimal() and int(args.build) > int(info["CFBundleVersion"]),
            "The build must be a positive integer newer than the baseline")
    signature = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", str(base)],
                               check=True, text=True, capture_output=True).stderr
    require("Signature=adhoc" in signature and "TeamIdentifier=not set" in signature,
            "This helper only updates an existing local ad-hoc app")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", base)
    run("python3", "-B", SOURCE / "scripts/verify-app-companions.py", base)
    before = inventory(base)
    source_hash = digest(binary)

    output.mkdir(mode=0o700)
    app = output / "DayDream.app"
    run("/usr/bin/ditto", base, app)
    require(inventory(app) == before, "The baseline changed while copying")
    main = app / "Contents/MacOS/MacMem"
    shutil.copy2(binary, main)
    require(digest(main) == source_hash and digest(binary) == source_hash,
            "The compiled executable changed during staging")
    info["CFBundleVersion"] = args.build
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    companions_path = app / "Contents/Resources/Companions.json"
    companions = json.loads(companions_path.read_text())
    companions["build"] = args.build
    companions_path.write_text(json.dumps(companions, sort_keys=True) + "\n")
    run("bash", SOURCE / "scripts/seal-local-app.sh", app)
    run("python3", "-B", SOURCE / "scripts/verify-app-companions.py", app)

    after = inventory(app)
    allowed = {"Contents/MacOS/MacMem", "Contents/Info.plist",
               "Contents/Resources/Companions.json", "Contents/_CodeSignature/CodeResources"}
    changed = {name for name in before.keys() | after.keys() if before.get(name) != after.get(name)}
    require(changed <= allowed, "Unexpected changed package entries: " + str(sorted(changed - allowed)))
    require(inventory(base) == before, "The baseline changed during staging")
    verified_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    # perm-1004: the ad-hoc seal gives the copy its own .adhoc bundle ID (seal-local-app.sh); nothing else changes.
    if not info["CFBundleIdentifier"].endswith(".adhoc"):
        info["CFBundleIdentifier"] += ".adhoc"
    require(verified_info == info, "App metadata changed during sealing")
    receipt = {"app": str(app), "baseline": str(base), "build": args.build,
               "bundleIdentifier": info["CFBundleIdentifier"], "signature": "local ad-hoc",
               "inputExecutableSHA256": source_hash, "sealedExecutableSHA256": digest(main),
               "changedEntries": sorted(changed), "baselineInventory": before,
               "stagedInventory": after, "installed": False, "launched": False}
    (output / "staging-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("Verified local app:", app)
    print("Receipt:", output / "staging-receipt.json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, default=Path.home() / "Applications/DayDream.app")
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        stage(arguments)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, "Staging stopped: " + str(error) + "\n")
