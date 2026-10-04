"""Bounded backup containers and isolated restore. No live adoption or discovery."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import time
from dataclasses import dataclass
from typing import Protocol


class Rejected(Exception):
    pass


@dataclass(frozen=True)
class Limits:
    bytes: int = 128 * 1024 * 1024
    files: int = 1024
    seconds: float = 10
    reserve: int = 8 * 1024 * 1024


class Budget:
    def __init__(self, limits: Limits):
        self.limits = limits
        self.end = time.monotonic() + limits.seconds

    def check(self):
        if time.monotonic() >= self.end:
            raise Rejected("deadline")


class Core(Protocol):
    # All hooks are trusted injected core code, bounded and cancellation-aware.
    # No default production schema adapter exists until core owner supplies it.
    def export(self, snapshot: sqlite3.Connection, clean: sqlite3.Connection, budget: Budget) -> dict[str, bytes]: ...
    def inspect(self, clean: sqlite3.Connection, budget: Budget) -> dict: ...
    def reconcile(self, isolated: sqlite3.Connection, budget: Budget) -> dict: ...


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise Rejected("duplicate field")
        value[key] = item
    return value


def directory(path):
    """Pin every ancestor using directory descriptors, rejecting symlinks."""
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise Rejected("absolute non-traversing path required")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def reserve(path, budget):
    path = Path(path)
    if path.name in ("", ".", ".."):
        raise Rejected("new destination required")
    parent = directory(path.parent)
    try:
        budget.check()
        info = os.fstatvfs(parent)
        if info.f_bavail * info.f_frsize < budget.limits.bytes + budget.limits.reserve:
            raise Rejected("insufficient free space")
        os.mkdir(path.name, mode=0o700, dir_fd=parent)  # exclusive, never overwrite
        os.fsync(parent)
        return os.open(path.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    finally:
        os.close(parent)


def write(fd, name, data, budget):
    budget.check()
    if len(data) > budget.limits.bytes:
        raise Rejected("size bound")
    file = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
    try:
        view = memoryview(data)
        while view:
            budget.check()
            count = os.write(file, view[:65536])
            if not count:
                raise Rejected("short write")
            view = view[count:]
        os.fsync(file)
    finally:
        os.close(file)


def read(fd, name, limit, budget):
    file = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    try:
        before = os.fstat(file)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > limit:
            raise Rejected("unsupported entry")
        data = bytearray()
        while True:
            budget.check()
            block = os.read(file, min(65536, limit + 1 - len(data)))
            if not block:
                break
            data.extend(block)
            if len(data) > limit:
                raise Rejected("size bound")
        after = os.fstat(file)
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise Rejected("entry changed")
        return bytes(data)
    finally:
        os.close(file)


def database(budget):
    db = sqlite3.connect(":memory:")
    db.execute("PRAGMA trusted_schema=OFF")
    db.execute("PRAGMA temp_store=MEMORY")
    db.set_progress_handler(lambda: int(time.monotonic() >= budget.end), 1000)
    return db


def inspect(core, db, budget):
    budget.check()
    if db.execute("PRAGMA integrity_check").fetchall() != [("ok",)] or db.execute("PRAGMA foreign_key_check").fetchall():
        raise Rejected("invalid database")
    info = core.inspect(db, budget)
    # This audit is an explicit core contract, not inferred from table names.
    if set(info) != {"schema", "build", "version", "counts", "policyRevision", "deletionRevision", "correctionRevision", "assets", "privacy"}:
        raise Rejected("incomplete core audit")
    if any(not isinstance(info[k], str) or not info[k] or len(info[k]) > 256 for k in ("schema", "build", "version", "policyRevision", "deletionRevision", "correctionRevision")):
        raise Rejected("invalid core revisions")
    if info["privacy"] != {"credentials": False, "grants": False, "capture": False, "deviceAuthorizations": False, "remote": False, "cloud": False}:
        raise Rejected("unsafe privacy state")
    if not isinstance(info["counts"], dict) or len(info["counts"]) > 128 or any(type(v) is not int or v < 0 for v in info["counts"].values()):
        raise Rejected("invalid counts")
    if not isinstance(info["assets"], list) or len(info["assets"]) > budget.limits.files or len(set(info["assets"])) != len(info["assets"]) or any(not re.fullmatch(r"[a-f0-9]{64}", x) for x in info["assets"]):
        raise Rejected("invalid asset references")
    budget.check()
    return info


def export_backup(source: sqlite3.Connection, destination, core: Core, limits=Limits()):
    """Caller supplies its authorized SQLite connection; online backup includes WAL.
    Raw pages remain only in memory. Core projects approved content to a fresh DB.
    """
    budget = Budget(limits)
    fd = reserve(destination, budget)
    snapshot, clean = database(budget), database(budget)
    try:
        page_size = source.execute("PRAGMA page_size").fetchone()[0]
        def progress(status, remaining, total):
            budget.check()
            if total * page_size > limits.bytes:
                raise Rejected("snapshot too large")
        source.backup(snapshot, pages=64, progress=progress, sleep=0.01)
        snapshot.execute("PRAGMA query_only=ON")
        assets = core.export(snapshot, clean, budget)
        clean.commit()
        info = inspect(core, clean, budget)
        if set(assets) != set(info["assets"]):
            raise Rejected("missing or extra assets")
        # Serialize only the fresh allowlisted projection, never raw source pages.
        content = {"database.sqlite": clean.serialize()}
        for name, data in assets.items():
            if not isinstance(data, bytes) or digest(data) != name:
                raise Rejected("asset hash mismatch")
            content["asset-" + name] = data
        if len(content) > limits.files or sum(map(len, content.values())) > limits.bytes:
            raise Rejected("container bounds")
        entries = {}
        for name, data in content.items():
            write(fd, name, data, budget)
            entries[name] = {"bytes": len(data), "sha256": digest(data)}
        manifest = {"format": "mac-mem.backup.v1", "encrypted": False, "core": info, "files": entries}
        raw = encoded(manifest)
        if len(raw) > 262144:
            raise Rejected("manifest bounds")
        # Completion marker written last; interrupted destinations stay incomplete.
        write(fd, "manifest.json", raw, budget)
        os.fsync(fd)
        return {"manifestSHA256": digest(raw), "manifest": manifest}
    finally:
        snapshot.close()
        clean.close()
        os.close(fd)


def restore_preview(backup, destination, expected_manifest_sha256, core: Core, limits=Limits()):
    """Never adopts. Pin manifest to owner's selected backup/preview receipt.
    Reconciliation must use CURRENT deletion/policy/correction authority, not backup.
    """
    budget = Budget(limits)
    source = directory(backup)
    clean = database(budget)
    target = None
    try:
        raw = read(source, "manifest.json", 262144, budget)
        if digest(raw) != expected_manifest_sha256:
            raise Rejected("manifest hash mismatch")
        manifest = json.loads(raw, object_pairs_hook=unique_object)
        if set(manifest) != {"format", "encrypted", "core", "files"} or manifest["format"] != "mac-mem.backup.v1" or manifest["encrypted"] is not False:
            raise Rejected("incompatible container")
        entries = manifest["files"]
        if not isinstance(entries, dict) or not 1 <= len(entries) <= limits.files or "database.sqlite" not in entries:
            raise Rejected("invalid entries")
        content, total = {}, 0
        for name, meta in entries.items():
            if name != "database.sqlite" and not re.fullmatch(r"asset-[a-f0-9]{64}", name):
                raise Rejected("unsafe entry name")
            if set(meta) != {"bytes", "sha256"} or type(meta["bytes"]) is not int or meta["bytes"] < 0:
                raise Rejected("invalid entry metadata")
            total += meta["bytes"]
            if total > limits.bytes:
                raise Rejected("container bounds")
            data = read(source, name, meta["bytes"], budget)
            if len(data) != meta["bytes"] or digest(data) != meta["sha256"] or (name.startswith("asset-") and digest(data) != name[6:]):
                raise Rejected("entry checksum mismatch")
            content[name] = data
        if set(os.listdir(source)) != set(entries) | {"manifest.json"}:
            raise Rejected("unlisted entry")
        clean.deserialize(content["database.sqlite"])
        clean.execute("PRAGMA trusted_schema=OFF")
        clean.execute("PRAGMA query_only=ON")
        before = inspect(core, clean, budget)
        if before != manifest["core"] or set(before["assets"]) != {n[6:] for n in entries if n.startswith("asset-")}:
            raise Rejected("core audit mismatch")
        clean.execute("PRAGMA query_only=OFF")
        receipt = core.reconcile(clean, budget)
        if not isinstance(receipt, dict) or set(receipt) != {"authorityRevision", "conflicts", "originalsVerified"} or not isinstance(receipt["authorityRevision"], str) or not receipt["authorityRevision"] or len(receipt["authorityRevision"]) > 256 or receipt["originalsVerified"] is not True or not isinstance(receipt["conflicts"], list):
            raise Rejected("current reconciliation required")
        clean.commit()
        after = inspect(core, clean, budget)
        if not set(after["assets"]).issubset(before["assets"]):
            raise Rejected("unavailable reconciled assets")
        clean.execute("VACUUM")  # do not preserve deleted evidence in free pages
        data = clean.serialize()
        if len(data) > limits.bytes:
            raise Rejected("restored size bound")
        target = reserve(destination, budget)
        write(target, "database.sqlite", data, budget)
        for name in after["assets"]:
            write(target, "asset-" + name, content["asset-" + name], budget)
        preview = {"status": "isolated-preview-only", "adoptable": False, "manifestSHA256": digest(raw),
                   "databaseSHA256": digest(data), "before": before, "after": after, "reconciliation": receipt}
        write(target, "preview.json", encoded(preview), budget)
        os.fsync(target)
        return preview
    finally:
        clean.close()
        os.close(source)
        if target is not None:
            os.close(target)
