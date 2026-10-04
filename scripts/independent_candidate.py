"""Inspect one owner-named DMG and source manifest. Never installs or launches.

The manifest must provide source_files (relative path -> SHA256). Artifact hash
is supplied separately by the build owner. All gates include this exact pair.
Runtime/GUI checks stay NOT TESTED until separately exercised on this candidate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


def sha(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for part in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(part)
    return value.hexdigest()


def source_files(root, manifest):
    mapping = manifest.get("source_files", manifest.get("files", manifest if "Package.swift" in manifest else None))
    if not isinstance(mapping, dict) or not mapping or "Package.swift" not in mapping:
        raise ValueError("Manifest needs source_files mapping including Package.swift")
    for name, expected in mapping.items():
        path = Path(name)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("Manifest path escapes source")
        target = (root / path).resolve()
        if not target.is_relative_to(root):
            raise ValueError("Source symlink escapes frozen source")
        expected = expected.get("sha256") if isinstance(expected, dict) else expected
        if not isinstance(expected, str) or not re.fullmatch("[a-fA-F0-9]{64}", expected) or sha(target) != expected.lower():
            raise ValueError("Source hash mismatch: " + name)
    return mapping


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--artifact", type=Path, required=True)
    p.add_argument("--sha256", required=True)
    p.add_argument("--source", type=Path, required=True)
    p.add_argument("--source-manifest", type=Path, required=True)
    args = p.parse_args()
    root = args.source.resolve()
    artifact = args.artifact.resolve()
    work = Path(tempfile.mkdtemp(prefix="macmem-candidate-qa-")).resolve()
    rows = []
    logs = {}
    supplied = args.source_manifest.read_bytes()
    binding = {"artifact":str(artifact), "candidate_sha256":sha(artifact),
               "source_manifest":str(args.source_manifest.resolve()),
               "source_manifest_sha256":hashlib.sha256(supplied).hexdigest()}
    report = {"schema":1, **binding, "recording_off_trial":"NOT TESTED",
              "full_replacement":"NOT TESTED", "checks":rows, "logs":logs, "workspace":str(work)}

    def record(name, status, detail):
        rows.append(dict(name=name, status=status, detail=detail))
        print(status + ": " + name + ": " + detail, flush=True)

    def command(name, argv, check=True):
        result = subprocess.run(argv, capture_output=True, text=True, timeout=90)
        logs[name] = {"argv":argv, "returncode":result.returncode,
                      "stdout":result.stdout, "stderr":result.stderr}
        if check and result.returncode:
            raise RuntimeError(name + " exited " + str(result.returncode))
        return result

    mount = work / "volume"
    mounted = False
    try:
        if binding["candidate_sha256"] != args.sha256.lower():
            raise ValueError("Candidate hash differs from owner's expected hash")
        manifest = json.loads(supplied)
        source_matched = False
        try:
            source_files(root, manifest)
            source_matched = True
            record("owner-artifact-source-binding", "PASS", "Expected DMG hash and supplied frozen source hashes match; build-owner provenance")
        except (ValueError, OSError) as error:
            record("owner-artifact-source-binding", "FAIL", str(error))
            # Hash-pinned artifact bytes remain independently inspectable. This
            # does not transfer source test results to an unbound candidate.
        command("image-verify", ["hdiutil", "verify", str(artifact)])
        mount.mkdir()
        command("image-attach", ["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(artifact)])
        mounted = True
        if {x.name for x in mount.iterdir() if not x.name.startswith(".")} != {"Mac Mem.app", "Applications"}:
            raise ValueError("Image must expose only Mac Mem.app and Applications")
        if not (mount / "Applications").is_symlink() or os.readlink(mount / "Applications") != "/Applications":
            raise ValueError("Applications shortcut is not /Applications")
        record("dmg-layout", "PASS", "App plus Applications shortcut; hidden layout resources retained")
        app = work / "Mac Mem.app"
        command("isolated-copy", ["ditto", str(mount / "Mac Mem.app"), str(app)])
        contents = app / "Contents"
        info = plistlib.loads((contents / "Info.plist").read_bytes())
        companions = json.loads((contents / "Resources/Companions.json").read_text())
        if info.get("CFBundleIdentifier") != "com.getnorthlight.daydream" or companions.get("version") != info.get("CFBundleShortVersionString") or companions.get("build") != info.get("CFBundleVersion"):
            raise ValueError("Bundle/companion identity mismatch")
        for name in ("MacMem", "mac-mem"):
            if not os.access(contents / "MacOS" / name, os.X_OK):
                raise ValueError("Missing executable " + name)
        for name in ("before_turn.py", "MacMem.icns", "Sparkle-LICENSE.txt"):
            if not (contents / "Resources" / name).is_file():
                raise ValueError("Missing bundled resource " + name)
        if not companions.get("sha256"):
            raise ValueError("Missing companion hashes")
        for name, expected in companions["sha256"].items():
            file = (contents / name).resolve()
            if not file.is_relative_to(contents) or sha(file) != expected:
                raise ValueError("Companion hash mismatch/escape: " + name)
        report["bundle_info"] = {k:info.get(k) for k in ("CFBundleVersion", "CFBundleShortVersionString", "LSMinimumSystemVersion", "LSArchitecturePriority")}
        report["companions"] = companions
        record("bundle-and-companions", "PASS", "App/CLI identity, resources and declared companion hashes match")
        if any(info.get(k) for k in ("SUFeedURL", "SUPublicEDKey", "SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates")):
            raise ValueError("Unsigned OFF trial unexpectedly configures/enables updates")
        record("unconfigured-updater", "PASS", "Candidate plist has no feed/key or enabled automatic checks/install; runtime not launched")
        seen = set()
        for file in app.rglob("*"):
            if file.is_symlink() and not file.resolve().is_relative_to(app):
                raise ValueError("Bundle symlink escapes: " + str(file.relative_to(app)))
            if file.name in {"memory.sqlite", "events.jsonl", "LaunchAgents", "LaunchDaemons", "postinstall", "preinstall"}:
                raise ValueError("Forbidden packaged data/service: " + file.name)
            if not file.is_file() or file.resolve() in seen:
                continue
            seen.add(file.resolve())
            with file.open("rb") as f:
                magic = f.read(4)
            if magic not in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf"):
                continue
            name = str(file.relative_to(app))
            link = command("links:"+name, ["otool", "-L", str(file)]).stdout
            load = command("load:"+name, ["otool", "-l", str(file)]).stdout
            for row in link.splitlines():
                if " (compatibility version" not in row:
                    continue
                dependency = row.strip().split(" (compatibility version",1)[0]
                if dependency.startswith("/") and not dependency.startswith(("/System/Library/", "/usr/lib/")):
                    raise ValueError("Non-system absolute dependency: " + dependency)
                if not dependency.startswith(("/System/Library/", "/usr/lib/", "@rpath/", "@loader_path/", "@executable_path/")):
                    raise ValueError("Unresolved dependency: " + dependency)
            for value in re.findall(r"\bpath (.*?) \(offset", load):
                if value.startswith(("/Users/", "/private/tmp/", "/tmp/", "/var/folders/", "/private/var/folders/", "/opt/homebrew/")):
                    raise ValueError("Developer-only rpath: " + value)
            if name == "Contents/MacOS/MacMem" and "@executable_path/../Frameworks" not in load:
                raise ValueError("App lacks bundled Frameworks rpath")
        record("bundle-linkage", "PASS", "All Mach-O dependencies/rpaths checked for developer paths; bundled launch still required to prove resolution")
        signature = command("bundle-signature-verify", ["codesign", "--verify", "--deep", "--strict", "--verbose=4", str(app)], check=False)
        command("bundle-signature-description", ["codesign", "-d", "--verbose=4", str(app)], check=False)
        report["bundle_resource_seal_present"] = (contents / "_CodeSignature/CodeResources").is_file()
        record("bundle-signature", "PASS" if signature.returncode == 0 else "FAIL",
               "Strict bundle signature verification exited " + str(signature.returncode) + "; no signature modified")
        gate = command("gatekeeper", ["spctl", "--assess", "--type", "execute", "--verbose=4", str(app)], check=False)
        record("clean-off-launch", "NOT TESTED", "Gatekeeper refused; no bypass or launch" if gate.returncode else "Gatekeeper accepted; isolated launch/UI exercise still required")
        if source_matched:
            source_files(root, manifest)
        if sha(artifact) != binding["candidate_sha256"]:
            raise ValueError("DMG changed during inspection")
        record("frozen-inputs-after-inspection", "PASS" if source_matched else "NOT TESTED", "DMG unchanged; source " + ("hashes still match" if source_matched else "binding remains failed"))
    except Exception as error:
        record("candidate-inspection", "FAIL", str(error))
    finally:
        if mounted:
            try:
                command("image-detach", ["hdiutil", "detach", str(mount)])
            except Exception as error:
                record("image-detach", "FAIL", str(error))
        for name in ("no-grants-login-items-network-capture-on-launch", "package-ui-narrow-wide-detail-settings",
                     "canonical-layers-edit-regenerate-delete-cancel", "real-import-skip-backup-restore-bindings",
                     "real-writer-fabricated-actions", "pending-errors-cold-restart", "macos26-arm64-disclosure-and-rejection",
                     "real-typesense-failover", "capture-device-ssh-signed-update"):
            record(name, "NOT TESTED", "Requires separate evidence bound to this exact candidate")
        if any(row["status"] == "FAIL" for row in rows):
            report["recording_off_trial"] = "FAIL"
        report_path = work / "candidate-report.json"
        report_path.write_text(json.dumps(report, indent=2)+"\n")
        print("REPORT: " + str(report_path), flush=True)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
