"""Install an already verified local UI build, with the app closed and rollback."""

import argparse
import json
from pathlib import Path
import runpy
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    args = parser.parse_args()
    receipt_path = args.receipt.resolve(strict=True)
    receipt = json.loads(receipt_path.read_text())
    helpers = runpy.run_path(str(Path(__file__).with_name("stage-local-ui-update.py")))
    inventory, require, run = (helpers[name] for name in ("inventory", "require", "run"))
    app = Path(receipt["app"])
    target = Path(receipt["baseline"])
    build = receipt["build"]
    require(build.isdecimal(), "Unexpected build identifier")
    require(target == Path.home() / "Applications/DayDream.app", "Unexpected installation target")
    require(app.parent == receipt_path.parent and not app.is_symlink(), "Unexpected staged app")
    require(receipt["signature"] == "local ad-hoc", "Unexpected signing mode")
    require(inventory(app) == receipt["stagedInventory"], "Staged app changed after verification")
    require(inventory(target) == receipt["baselineInventory"], "Installed app changed after staging")
    processes = subprocess.check_output(["/bin/ps", "-axo", "comm="], text=True).splitlines()
    require(str(target / "Contents/MacOS/MacMem") not in (line.strip() for line in processes),
            "Quit DayDream before replacing its app bundle")
    pending = target.with_name(".Daydream-update-" + build + ".app")
    backup = target.with_name(".Daydream-before-" + build + ".app")
    require(not pending.exists() and not backup.exists(), "Installation paths are already in use")
    run("/usr/bin/ditto", app, pending)
    require(inventory(pending) == receipt["stagedInventory"], "Installation copy differs from staged app")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", pending)
    target.rename(backup)
    try:
        pending.rename(target)
        require(inventory(target) == receipt["stagedInventory"], "Installed app verification failed")
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", target)
    except BaseException:
        if target.exists():
            target.rename(pending)
        backup.rename(target)
        raise
    result = {"app": str(target), "build": build, "backup": str(backup),
              "installed": True, "launched": False,
              "sealedExecutableSHA256": receipt["sealedExecutableSHA256"]}
    (receipt_path.parent / "installation-receipt.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
