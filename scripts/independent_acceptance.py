"""Independent release QA. Source copies and synthetic stores only; never installs.

Run with python3 scripts/independent_acceptance.py. Exit 1 means a failed
check OR an incomplete replacement gate. JSON records exact input hashes,
commands, logs, and pass/fail/not-tested separately. No real provider is used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time


SOURCE_DIRS = ("Sources", "Checks", "Tests", "UIRender", "Vendor", "scripts",
               "packaging", "adapters", "WriterBackend", "PrivacyPolicy", "BackupRestore", "BrowserBridge")
EXTENSIONS = {".swift", ".py", ".sh", ".json", ".plist", ".h", ".cpp", ".c", ".modulemap", ".md", ".mts", ".ts", ".mjs", ".js"}


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def inventory(root):
    paths = [root / "Package.swift"]
    for directory in SOURCE_DIRS:
        paths.extend(p for p in (root / directory).rglob("*")
                     if p.is_file() and (p.suffix in EXTENSIONS or directory == "Vendor")
                     and not any(x in p.parts for x in (".build", "__pycache__", ".git")))
    return {str(p.relative_to(root)): digest(p) for p in sorted(set(paths))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--artifact", type=Path, help="Explicit supplied release artifact; hash only, no mount/launch")
    parser.add_argument("--report-dir", type=Path)
    args = parser.parse_args()
    source = args.source.resolve()
    work = Path(tempfile.mkdtemp(prefix="macmem-independent-qa-"))
    report = args.report_dir.resolve() if args.report_dir else work / "report"
    report.mkdir(parents=True, exist_ok=True)
    copy = work / "source"
    copy.mkdir()
    before = inventory(source)
    shutil.copy2(source / "Package.swift", copy / "Package.swift")
    for directory in SOURCE_DIRS:
        if (source / directory).is_dir():
            shutil.copytree(source / directory, copy / directory, symlinks=True,
                            ignore=shutil.ignore_patterns(".build", "__pycache__", ".git", "*.sqlite*"))
    copied = inventory(copy)
    env = {k: os.environ[k] for k in ("PATH", "DEVELOPER_DIR", "SDKROOT") if k in os.environ}
    env.update(TMPDIR=str(work),
               CLANG_MODULE_CACHE_PATH=str(work / "clang-cache"),
               SWIFT_MODULECACHE_PATH=str(work / "swift-cache"),
               PYTHONDONTWRITEBYTECODE="1")
    rows = []

    def result(name, status, detail, **extra):
        rows.append(dict(name=name, status=status, detail=detail, **extra))
        print(f"{status}: {name}: {detail}", flush=True)

    def run(name, command, timeout=240):
        start = time.monotonic()
        try:
            p = subprocess.run(command, cwd=copy, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, timeout=timeout)
            output, code = p.stdout, p.returncode
        except subprocess.TimeoutExpired as error:
            output = str(error.stdout or "") + "\nTIMEOUT"; code = 124
        except OSError as error:
            output = str(error); code = 127
        log = report / (name + ".log")
        log.write_text(output)
        blocked = name == "check_search_interfaces" and "PermissionError: [Errno 1] Operation not permitted" in output and "socket.bind" in output
        result(name, "not-tested" if blocked else "pass" if code == 0 else "fail", "Loopback fixture bind denied; see " + log.name if blocked else "see " + log.name,
               command=command, exit_code=code, seconds=round(time.monotonic()-start, 3),
               log_sha256=digest(log))
        return code == 0

    result("source-copy", "pass" if before == copied else "fail",
           "All inventoried source bytes match isolated copy" if before == copied else "Source changed during copy; rerun")
    built = run("clean-integrated-build", ["swift", "build", "--disable-sandbox", "--scratch-path", str(work / "build")], 300)
    binaries = {}
    if built:
        for name in ("mac-mem", "MacMem", "MacMemChecks", "ProductionBindingChecks"):
            path = work / "build/debug" / name
            if path.is_file(): binaries[name] = {"path":str(path), "sha256":digest(path)}
        cli = work / "build/debug/mac-mem"
        env["MACMEM_TEST_CLI"] = str(cli)
        run("core-synthetic-checks", [str(work / "build/debug/MacMemChecks")])
        if "ProductionBindingChecks" in binaries:
            run("native-core-production-bindings", [binaries["ProductionBindingChecks"]["path"]])
        else:
            result("native-core-production-bindings", "not-tested", "No built production-binding check target; no substitute used")
        # Link the canonical API suite to the exact same core objects as the CLI.
        objects = sorted(str(p) for module in ("MemoryCore", "HistoryCore")
                         for p in (work / "build/debug" / (module + ".build")).glob("*.o"))
        action_binary = work / "action-checks"
        action_command = ["swiftc", "-parse-as-library", "-I", str(work / "build/debug/Modules"),
                          "-I", str(copy / "Sources/CSQLite"),
                          str(copy / "scripts/action-architecture-checks.swift"),
                          *objects, "-o", str(action_binary)]
        if run("canonical-api-checks-build", action_command):
            binaries["action-checks"] = {"path":str(action_binary), "sha256":digest(action_binary)}
            run("canonical-api-checks", [str(action_binary)])
        controls = copy / "scripts/memory-controls-checks.swift"
        if controls.is_file():
            controls_binary = work / "memory-controls-checks"
            command = ["swiftc", "-parse-as-library", "-I", str(work / "build/debug/Modules"),
                       "-I", str(copy / "Sources/CSQLite"), str(controls), *objects, "-o", str(controls_binary)]
            if run("memory-controls-build", command):
                binaries["memory-controls-checks"] = {"path":str(controls_binary), "sha256":digest(controls_binary)}
                run("memory-controls", [str(controls_binary)])
        for suite in ("check_action_resources.py", "check_migration.py", "check_search_interfaces.py", "independent_recall_checks.py"):
            run(suite.removesuffix(".py"), ["python3", str(copy / "scripts" / suite)])
        # Existing interface suite hardcodes .build; override its module global,
        # without changing production code or consulting a shared cached binary.
        runner = ("import runpy,unittest; n=runpy.run_path('scripts/check_interfaces.py'); "
                  f"n['Interfaces'].setUp.__globals__['CLI']={str(cli)!r}; "
                  "r=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(n['Interfaces'])); "
                  "raise SystemExit(not r.wasSuccessful())")
        run("legacy-host-interfaces", ["python3", "-c", runner])
    else:
        for name in ("core-synthetic-checks", "native-core-production-bindings", "canonical-api-checks", "memory-controls", "check_action_resources", "check_migration", "check_search_interfaces", "independent_recall_checks", "legacy-host-interfaces"):
            result(name, "not-tested", "Blocked by clean integrated build; no old binary substituted")

    if (copy / "BackupRestore/test_backup_restore.py").is_file():
        run("backup-container-component", ["python3", "-m", "unittest", "discover", "-s", "BackupRestore", "-p", "test_backup_restore.py", "-v"])

    ui = "\n".join(p.read_text() for d in ("Sources/MemoryUI", "Sources/MacMemApp") for p in (copy/d).glob("*.swift"))
    canonical = "dayLayers(" in ui and "loadCanonicalDay" in ui and "CanonicalTimeline(browser:" in ui.replace(" ", "")
    result("canonical-ui-adoption", "not-tested" if canonical else "fail",
           "Canonical loader and mounted view present; runtime UI acceptance still required" if canonical else "Canonical day loader and mounted CanonicalTimeline not both present; standalone view/scaffold is not acceptance")
    plist = plistlib.loads((copy / "packaging/Info.plist").read_bytes())
    updates = (copy / "Sources/MacMemApp/Updates.swift").read_text()
    off = not plist.get("SUFeedURL") and not plist.get("SUPublicEDKey") and not plist.get("SUEnableAutomaticChecks") and not plist.get("SUAutomaticallyUpdate")
    guarded = "guard let config=" in updates and "let controller=SPUStandardUpdaterController" in updates and updates.index("guard let config=") < updates.index("let controller=SPUStandardUpdaterController")
    result("unconfigured-updater-source", "pass" if off and guarded else "fail",
           "Static plist and construction guard only; no network or updater launched")
    for name, reason in (
        ("native-browser-device-coverage", "Synthetic checks cannot certify actual capture/privacy; device work excluded"),
        ("recent-ten-second-capture-to-recall", "CLI fixture tests cover persisted records only; capture-to-ingest latency needs device acceptance"),
        ("notes-provider-ui-integration", "Canonical API checks do not certify the provider runner and actual UI together"),
        ("backup-restore", "Need product backup/restore round trip with policy, tombstones and derived invalidation"),
        ("actual-typesense-failover", "HTTP fixture tests are not a running Typesense server acceptance"),
        ("actual-local-model-benchmark", "Not exercised by this source harness; use the pinned real runtime/model against the candidate's writer binding"),
        ("atomic-schema-upgrade-rollback", "Need old/new artifacts, schema compatibility and interruption tests; policy checks alone insufficient"),
        ("signed-hosted-release", "Signing, notarization, hosted feed and install safety prerequisites separate from unsigned OFF trial"),
        ("unsigned-off-trial", "No artifact supplied by build owner tested here; no install/launch authorized"),
    ):
        result(name, "not-tested", reason)
    artifact = None
    if args.artifact:
        artifact = {"path": str(args.artifact.resolve()), "sha256": digest(args.artifact), "tested":False}
    result("artifact-test-binding", "not-tested", "Hash-only artifact is not a tested build" if artifact else "Awaiting exact App interface artifact; source build is separate")
    current = inventory(source)
    result("source-stability", "pass" if current == before else "fail", "Working source unchanged" if current == before else "Source changed during run; results apply only to copied manifest")
    manifest = dict(schema=1, replacement_ready=False, source=str(source), workspace=str(work),
                    source_files=copied, binaries=binaries, artifact=artifact, checks=rows,
                    restrictions="synthetic only; no real capture, keys, services, install, SSH, publish or Update")
    (report / "manifest.json").write_text(json.dumps(manifest, indent=2)+"\n")
    print("MANIFEST: " + str(report / "manifest.json"), flush=True)
    return 1 if any(r["status"] != "pass" for r in rows) else 0


if __name__ == "__main__":
    raise SystemExit(main())
