#!/usr/bin/env python3
"""Which builds update (updates-1003). Headless, read-only: no network, no key, no signing, no launch.

  python3 scripts/check_update_builds.py                       the source rules only
  python3 scripts/check_update_builds.py --release-app A --qa-app B --livetest-app C   also staged/signed apps

The source rules:
  - packaging/updates.json: the feed is https://getdaydream.app/appcast.xml and the public key is the owner's key that
    0.1.3 already trusts (a different key would leave every installed copy unable to update);
  - a release stage (no --owner-build, --updates configured) writes the feed, the key and quiet updates into Info.plist;
  - the QA stage (--owner-build --updates off --qa-harness) and every updates-off stage write none of them and nothing
    automatic, and --qa-harness with updates is refused;
  - the Live Test copy (live/build-live-app.sh) starts from packaging/Info.plist, which has no feed and nothing
    automatic, and a QA or Live Test binary refuses an update configuration whatever its Info.plist says.
  - ship-1004 (owner decision 2026-10-03, "Ship typesense."): the bundled Typesense is cleared for public distribution
    (record names the Complete Corresponding Source kit by sha256), so a release Info.plist with it passes.
An app given with --release-app must carry exactly this commit's update settings and no owner or QA marks; if it bundles
Typesense, its record must be the cleared public one and its stage receipt must name the recorded source kit. One given
with --qa-app or --livetest-app must carry no feed, no key and nothing automatic.
"""
import argparse
import importlib.util
import json
import plistlib
import re
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
import release  # noqa: E402
import search_payload  # noqa: E402

spec = importlib.util.spec_from_file_location("developer_id_release", SCRIPTS / "developer-id-release.py")
dr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dr)

FEED = "https://getdaydream.app/appcast.xml"
SITE = "getdaydream.app"
# The owner's update key (commit 7d10875, release.py make-key). 0.1.3 shipped it; every later release must keep it.
OWNER_PUBLIC_KEY = "yJCzogP0s2x3YaR3CVuYJ+WCauu5m5ygHLK/svx3AQc="
AUTOMATIC = ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates")
results = []


def check(ok, name):
    results.append((bool(ok), name))
    print(("PASS " if ok else "FAIL ") + name)


def off_problems(info):
    """What makes an Info.plist anything but 'never updates'."""
    problems = ["has %s" % k for k in dr.UPDATE_KEYS if k in info]
    problems += ["%s is %r" % (k, info.get(k)) for k in AUTOMATIC if info.get(k) is not False]
    return problems


def source_rules():
    data = release.config()
    check(data["feed"] == FEED and data["site"] == SITE, "updates.json: the feed is %s" % FEED)
    check(data["public_key"] == OWNER_PUBLIC_KEY and release.valid_public_key(data["public_key"]),
          "updates.json: the public key is the owner's existing key (0.1.3 trusts only it)")
    template = plistlib.loads((ROOT / "packaging/Info.plist").read_bytes())

    # The release: a public stage with updates configured.
    flags = dr.stage_swift_flags(False, "configured", False)
    check("-DDAYDREAM_QA_HARNESS" not in flags and "-DDAYDREAM_LIVETEST" not in flags,
          "release stage: no QA or Live Test compile flag (%s)" % " ".join(flags))
    info = dr.release_info(template, "20261004000001", "0.1.5", "15.0", writer=None, updates="configured", update_data=data)
    check(info.get("SUFeedURL") == FEED and info.get("SUPublicEDKey") == OWNER_PUBLIC_KEY and info.get("DaydreamUpdateSite") == SITE,
          "release Info.plist: feed %s and the owner's key" % info.get("SUFeedURL"))
    check(all(info.get(k) is True for k in AUTOMATIC) and info.get("SUScheduledCheckInterval") == 86400,
          "release Info.plist: checks once a day, downloads and installs quietly")
    check(info.get("SURequireSignedFeed") is True and info.get("SUVerifyUpdateBeforeExtraction") is True
          and info.get("SUSendProfileInfo") is False, "release Info.plist: signed feed, verified archive, no system profile")
    check(dr.update_policy_problems(info, "configured", data) == [], "release Info.plist passes the configured policy")
    check(dr.update_policy_problems(info, "off", data) != [], "release Info.plist is refused as an updates-off build")
    # ship-1004: the release carries the bundled Typesense with updates on (the website feed, quiet updates).
    record = json.loads((ROOT / search_payload.SOURCE_DIR / "local-typesense-v30.2.json").read_text())
    check(search_payload.public_cleared(record), "Typesense record: public, complete corresponding source, kit sha256 %s"
          % search_payload.SOURCE_KIT_SHA256[:12])
    import tempfile
    with tempfile.TemporaryDirectory(prefix="daydream-update-builds-") as temp:
        plist = Path(temp) / "DayDream.app/Contents/Info.plist"
        plist.parent.mkdir(parents=True)
        plist.write_bytes(plistlib.dumps(info))
        try:
            search_payload.normal_app(plist.parent.parent)
            accepted = True
        except ValueError:
            accepted = False
    check(accepted, "release Info.plist (feed, quiet updates) is accepted for the app bundling Typesense")
    check("pass --updates off; public distribution is not cleared by this commit" in (SCRIPTS / "developer-id-release.py").read_text()
          and "search_payload.public_cleared_app(app)" in (SCRIPTS / "release.py").read_text(),
          "stage and appcast still refuse Typesense with updates on when the record is not the cleared one")

    # The QA copy and every updates-off build (the owner's copy too).
    qa_flags = dr.stage_swift_flags(True, "off", True)
    check("-DDAYDREAM_QA_HARNESS" in qa_flags, "QA stage compiles DAYDREAM_QA_HARNESS")
    for owner, updates in ((True, "configured"), (False, "configured"), (False, "off")):
        try:
            dr.stage_swift_flags(owner, updates, True)
            refused = False
        except Exception:  # ReleaseError
            refused = True
        check(refused, "--qa-harness refused unless --owner-build --updates off (owner=%s, updates=%s)" % (owner, updates))
    off = dr.release_info(template, "20261004000002", "0.1.5", "15.0", writer=None, updates="off")
    check(off_problems(off) == [], "updates-off Info.plist (owner and QA stages): no feed, no key, nothing automatic %s" % off_problems(off))
    check(dr.update_policy_problems(off, "off") == [] and dr.update_policy_problems(off, "configured", data) != [],
          "updates-off Info.plist passes only the off policy")
    stage_source = (SCRIPTS / "developer-id-release.py").read_text()
    check("require(not owner or args.updates == 'off'" in stage_source, "an owner stage (the normal owner copy and QA) must pass --updates off")

    # The Live Test copy: packaging/Info.plist, then -DDAYDREAM_LIVETEST.
    check(off_problems(template) == [], "packaging/Info.plist (development and Live Test builds): nothing automatic, no feed %s" % off_problems(template))
    policy = (ROOT / "Sources/MemoryCore/UpdatePolicy.swift").read_text()
    guard = re.search(r"#if DAYDREAM_QA_HARNESS \|\| DAYDREAM_LIVETEST\n(?:\s*///[^\n]*\n)*\s*public static let compiledOff=true\n\s*#else\n\s*public static let compiledOff=false\n\s*#endif", policy)
    check(guard is not None, "UpdateConfiguration.compiledOff is true in QA and Live Test binaries")
    check("guard !Self.compiledOff," in policy, "UpdateConfiguration refuses first when compiledOff")
    updates = (ROOT / "Sources/MacMemApp/Updates.swift").read_text()
    check(updates.index("guard let config=try? UpdateConfiguration") < updates.index("SPUStandardUpdaterController(startingUpdater:false"),
          "no configuration, no Sparkle (the controller is made only after UpdateConfiguration succeeds)")


def app_info(app):
    app = Path(app)
    return plistlib.loads((app / "Contents/Info.plist").read_bytes())


def receipt_of(app):
    path = Path(app).parent / "stage-receipt.json"
    return json.loads(path.read_text()) if path.is_file() else None


def release_app(app):
    info, data = app_info(app), release.config()
    wanted = release.update_info(data)
    wrong = {k: info.get(k) for k, v in wanted.items() if info.get(k) != v}
    check(not wrong, "%s: release update settings (feed %s) %s" % (app, info.get("SUFeedURL"), wrong or ""))
    check(info.get("CFBundleIdentifier") == "com.getnorthlight.daydream", "%s: the DayDream bundle ID" % app)
    marks = [k for k in ("DaydreamQAHarness", "MacMemOwnerTyping") if k in info]
    check(not marks, "%s: no QA or owner marker %s" % (app, marks))
    receipt = receipt_of(app)
    if receipt is not None:
        check(receipt.get("updates") == "configured" and not receipt.get("owner_build") and not receipt.get("qa_harness"),
              "%s: stage receipt says updates configured, not owner, not QA" % app)
    if search_payload.present(app):
        try:
            cleared = search_payload.public_cleared_app(app)
        except ValueError as error:
            cleared = False
            print("  %s" % error)
        check(cleared, "%s: bundled Typesense has the cleared public record (source kit %s)" % (app, search_payload.SOURCE_KIT_SHA256[:12]))
        if receipt is not None:
            kit = receipt.get("typesense_source_kit") or {}
            check(kit.get("sha256") == search_payload.SOURCE_KIT_SHA256 and kit.get("name") == search_payload.SOURCE_KIT_NAME,
                  "%s: stage receipt names the recorded Typesense source kit" % app)


def off_app(app, kind):
    info = app_info(app)
    check(off_problems(info) == [], "%s: %s copy never updates %s" % (app, kind, off_problems(info)))
    if kind == "QA":
        check(info.get("DaydreamQAHarness") is True, "%s: is the QA copy (DaydreamQAHarness)" % app)
        receipt = receipt_of(app)
        if receipt is not None:
            check(receipt.get("updates") == "off" and receipt.get("qa_harness") is True, "%s: stage receipt says updates off, QA" % app)
    else:
        check(str(info.get("CFBundleIdentifier", "")).endswith(".livetest"), "%s: is the Live Test copy (.livetest bundle ID)" % app)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--release-app", action="append", default=[])
    parser.add_argument("--qa-app", action="append", default=[])
    parser.add_argument("--livetest-app", action="append", default=[])
    parser.add_argument("-v", action="store_true", help="accepted for the runner; output is always verbose")
    args = parser.parse_args()
    source_rules()
    for app in args.release_app:
        release_app(app)
    for app in args.qa_app:
        off_app(app, "QA")
    for app in args.livetest_app:
        off_app(app, "Live Test")
    failed = [name for ok, name in results if not ok]
    print("%s: %d passed, %d failed" % ("FAILED" if failed else "OK", len(results) - len(failed), len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
