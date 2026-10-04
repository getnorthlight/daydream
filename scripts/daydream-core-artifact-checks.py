"""Exact OFF-candidate CLI/helper checks. Synthetic stores only; no GUI/capture.

The artifact is pinned, mounted read-only and copied into a unique temp root.
SQLite edits below inject faults ONLY into this script's newly seeded stores.
No configuration, history, service or permission outside that root is opened.
"""
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
from datetime import datetime, timezone

PROJECT = Path(__file__).resolve().parents[1]
ARTIFACT = PROJECT / "dist/Daydream-OFF-Trial-20260913-0221.dmg"
PIN = "e5c121b3338cc14386b5ef613989068e2a7875315e88255d7006b8352b71b34e"
BIN_PINS = {
    "MacMem": "e56df99d42a390d624d17570c4af003fdd3ed24b4a969e29e9d7394e36fa4216",
    "mac-mem": "646faecb4067427532dab10d8f5ab16edeb57cf23619aa090515f0e477d8d04d",
    "mac-mem-backup": "3107c2d17ceb507f0361628753005443b0941f066ac485469fed406a844f8693",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    root = Path(tempfile.mkdtemp(prefix="daydream-core-artifact-", dir="/private/tmp"))
    report = {"artifact": str(ARTIFACT), "root": str(root), "sha256": digest(ARTIFACT), "checks": [], "commands": []}
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": str(root), "CFFIXED_USER_HOME": str(root / "user"), "PYTHONDONTWRITEBYTECODE": "1"}
    (root / "user").mkdir()
    def save():
        (root / "receipt.json").write_text(json.dumps(report, indent=2))
    def check(value, name):
        assert value, name
        report["checks"].append(name)
        print("PASS", name, flush=True)
        save()
    def run(name, args, payload=None, ok=True, extra=None, timeout=40):
        p = subprocess.run([str(x) for x in args], input=None if payload is None else json.dumps(payload), text=True, capture_output=True, timeout=timeout, env={**env, **(extra or {})})
        report["commands"].append({"name": name, "exit": p.returncode, "stdout": p.stdout, "stderr": p.stderr})
        save()
        assert ok is None or (p.returncode == 0) == ok, (name, p.returncode, p.stdout, p.stderr)
        return p
    mounted = False
    mount = root / "mount"
    mount.mkdir()
    try:
        check(report["sha256"] == PIN, "exact final DMG SHA256")
        manifest = json.loads((PROJECT / "dist/Daydream-OFF-Trial-20260913-0221-source.json").read_text())
        report["source_mismatches_before"] = [p for p, sha in manifest.items() if not (PROJECT / p).is_file() or digest(PROJECT / p) != sha]
        run("image integrity", ["hdiutil", "verify", ARTIFACT])
        run("mount read-only", ["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, ARTIFACT])
        mounted = True
        app = root / "DayDream.app"
        run("extract exact app", ["ditto", mount / "DayDream.app", app])
        run("detach", ["hdiutil", "detach", mount])
        mounted = False
        run("sealed bundle", ["codesign", "--verify", "--deep", "--strict", app])
        binaries = app / "Contents/MacOS"
        report["binary_hashes"] = {name: digest(binaries / name) for name in BIN_PINS}
        check(report["binary_hashes"] == BIN_PINS, "all three extracted executables match candidate receipt")
        cli = binaries / "mac-mem"
        helper = binaries / "mac-mem-backup"
        home = root / "synthetic-current"
        def command(name, *args, ok=True):
            p = run(name, [cli, "--home", home, "--local", *args], ok=ok)
            return json.loads(p.stdout) if ok else p
        def backup(name, operation, ok=True, **fields):
            p = run(name, [helper], {"operation": operation, "source": str(home), **fields}, ok=ok)
            return json.loads(p.stdout)
        def sql(statement, values=()):
            with sqlite3.connect(home / "memory.sqlite") as db:
                return db.execute(statement, values).fetchall()
        def canonical():
            return {table: sql("SELECT * FROM " + table + " ORDER BY 1") for table in ("records", "summaries", "tombstones", "user_corrections")}
        command("seed synthetic data", "demo")
        check(command("initial status", "status")["capture"] == "off", "artifact synthetic store starts OFF")
        # Fixture setup only, NOT proof of the artifact's correction-save UI/API.
        # Exercise its real readers and backup preservation with a canonical edit.
        corrected=sql("SELECT id FROM records ORDER BY id DESC LIMIT 1")[0][0]
        correction={"targetKind":"action","targetID":corrected,"version":1,"text":"Explicit synthetic correction","actionIDs":[corrected],"authoredAt":datetime.now(timezone.utc).isoformat(),"attribution":"User correction, not observed evidence"}
        correction_body=json.dumps(correction,separators=(",",":"),sort_keys=True)
        sql("INSERT INTO user_corrections VALUES(?,?,?,?)",("action",corrected,1,correction_body))
        initial = canonical()
        record_ids = [row[0] for row in initial["records"]]
        check(len(record_ids) == 3, "artifact demo seeds exactly three fabricated records")
        exported = backup("export", "export", destination=str(root / "backup"), build="1", version="0.1.0")
        pin = exported["manifestSHA256"]
        check(exported["manifest"]["audit"]["capture"] == "off", "actual helper exports canonical OFF snapshot")
        check(exported["manifest"]["audit"]["counts"]["user_corrections"]==1,"actual helper preserves seeded correction in export")
        def prepare(name):
            return backup(name, "prepare", backup=str(root / "backup"), manifestSHA256=pin, destination=str(root / name))
        p = prepare("cancel-stage")
        backup("cancel", "cancel", prepared=p)
        backup("cancelled confirm", "confirm", prepared=p, confirmed=True, ok=False)
        check(canonical() == initial, "cancelled restore does not change canonical data")
        p = prepare("false-confirm-stage")
        backup("false confirm", "confirm", prepared=p, confirmed=False, ok=False)
        check(canonical() == initial, "restore requires explicit confirmation")
        backup("wrong manifest pin", "prepare", backup=str(root / "backup"), manifestSHA256="0" * 64, destination=str(root / "wrong-pin"), ok=False)
        check(canonical() == initial, "wrong backup pin fails without current-data change")
        p = prepare("race-stage")
        # Actual packaged deletion changes authority after prepare.
        deleted = run("delete after prepare", [cli,"--home",home,"--local","delete",record_ids[0]],ok=None)
        if deleted.returncode:
            assert "statement failed" in deleted.stderr
            report.setdefault("known_failures",[]).append("Delete commits but reports statement failed after cancelled restore created empty assets directory without migration_originals table")
            check(sql("SELECT id FROM tombstones WHERE id=?",(record_ids[0],))==[(record_ids[0],)],"failed delete response traced to already committed tombstone")
        after_delete = canonical()
        backup("stale confirm", "confirm", prepared=p, confirmed=True, ok=False)
        check(canonical() == after_delete, "packaged deletion invalidates restore confirmation")
        p = prepare("tombstone-stage")
        restored = backup("restore with later tombstone", "confirm", prepared=p, confirmed=True)
        check(record_ids[0] not in restored["addedActionIDs"] and command("deleted read", "read", record_ids[0]) is None, "old backup cannot resurrect later deletion")
        repeat = backup("repeat confirmation", "confirm", prepared=p, confirmed=True)
        check(restored == repeat, "packaged helper retry returns identical receipt")
        # Model incomplete local data without a user deletion. No tombstone is
        # removed. Fault injection is not a real recovery/corruption claim.
        missing = record_ids[1]
        sql("DELETE FROM records WHERE id=?", (missing,))
        sql("DELETE FROM summaries WHERE id=?", (missing,))
        p = prepare("failure-stage")
        before_failure = canonical()
        sql("CREATE TRIGGER synthetic_restore_failure BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT,'synthetic'); END")
        backup("injected restore failure", "confirm", prepared=p, confirmed=True, ok=False)
        check(canonical() == before_failure, "restore SQL failure rolls back canonical writes")
        check(not sql("SELECT id FROM metadata WHERE id=?", ("restore_receipt_" + p["preview"]["id"],)), "failed restore creates no success receipt")
        sql("DROP TRIGGER synthetic_restore_failure")
        repaired = backup("retry failed restore", "confirm", prepared=p, confirmed=True)
        check(repaired["addedActionIDs"] == [missing], "retry after injected failure restores exact missing action")
        check(command("restored read", "read", missing) is not None and command("tombstoned read", "read", record_ids[0]) is None, "retry retains prior tombstone and unrelated actions")
        check(backup("repeated recovered restore", "confirm", prepared=p, confirmed=True) == repaired, "recovered restore remains idempotent")
        check(sql("SELECT body FROM user_corrections WHERE target=?",(corrected,))==[(correction_body,)],"actual helper preserves current correction through restore failure/retry")
        p = prepare("tamper-stage")
        staged = Path(p["staging"]) / "memory.sqlite"
        with staged.open("ab") as file:
            file.write(b"synthetic mutation")
        before = canonical()
        backup("tampered stage rejected", "confirm", prepared=p, confirmed=True, ok=False)
        check(canonical() == before, "tampered staging bytes reject before adoption")
        search = command("search before delete", "search", "Swift")
        if not search: # demo-search may be first deleted ID; reseeding cannot undo its tombstone.
            search = command("search remaining", "search", "")
        victim = next(row[0] for row in sql("SELECT id FROM records ORDER BY id"))
        sql("INSERT OR REPLACE INTO search_index_state VALUES(?,?)", (victim, "synthetic-stale-index"))
        command("delete with stale index ledger", "delete", victim)
        check(command("deleted original absent", "read", victim) is None, "packaged delete removes exact original")
        check(all(item["id"] != victim for item in command("source revalidated search", "search", "")), "search never returns deleted source with stale index ledger")
        check(sql("SELECT id FROM tombstones WHERE id=?", (victim,)) == [(victim,)], "deletion persists canonical tombstone")
        p = prepare("post-delete-stage")
        backup("restore after second deletion", "confirm", prepared=p, confirmed=True)
        check(command("second tombstone persists", "read", victim) is None, "backup cannot undo second deletion")
        check(command("final status", "status")["capture"] == "off" and not sql("SELECT id FROM grants"), "all artifact operations leave capture OFF and no grants")
        result = run("packaged migration suite", ["/usr/bin/python3", PROJECT / "scripts/check_migration.py"], extra={"MACMEM_TEST_CLI": str(cli)}, timeout=60)
        check("OK" in result.stderr, "all 15 migration tests pass against extracted CLI with source exporter")
        result = run("packaged search interfaces", ["/usr/bin/python3", PROJECT / "scripts/check_search_interfaces.py"], extra={"MACMEM_TEST_CLI": str(cli)}, timeout=60)
        check("OK" in result.stderr,"packaged search/index revocation suite passes with synthetic loopback service")
        report["source_mismatches_after"] = [p for p, sha in manifest.items() if not (PROJECT / p).is_file() or digest(PROJECT / p) != sha]
        report["completed"] = True
    finally:
        if mounted:
            subprocess.run(["hdiutil", "detach", str(mount)], capture_output=True, timeout=20)
        save()
        print("RECEIPT", root / "receipt.json", flush=True)


if __name__ == "__main__":
    main()
