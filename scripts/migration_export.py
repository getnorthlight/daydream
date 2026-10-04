"""Explicit, read-only legacy snapshot export. No default/private source paths.

The plan enumerates exact files. Only closed segment files are accepted. SQLite
activity export holds a read transaction across all rows, including WAL content.
No collector connections, model calls, shell commands or network.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import sys
import time
from datetime import datetime, timezone

MAX_BYTES = 64 * 1024 * 1024
MAX_ROWS = 100_000


class MigrationError(Exception):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()


def read_exact(path):
    path = Path(path)
    if not path.is_absolute() or path != path.resolve():
        raise MigrationError("source must be an exact absolute regular file")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_BYTES:
            raise MigrationError("source file unsupported or over 64 MiB; split an approved snapshot")
        with os.fdopen(os.dup(fd), "rb") as stream:
            data = stream.read(MAX_BYTES + 1)
        after = os.fstat(fd)
        if len(data) > MAX_BYTES or (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
            raise MigrationError("source changed while reading; provide a stable snapshot")
        return data
    finally:
        os.close(fd)


def stamp(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?(?:Z|[+-]\d\d:\d\d)", value):
        raise MigrationError("timestamp needs explicit offset and at most nanosecond precision")
    # Python 3.9 (macOS developer tools) rejects some fractional widths,
    # including nine digits. Parse whole seconds only; preserve all original
    # fractional digits in the integer nanosecond calculation below.
    parsed = datetime.fromisoformat(re.sub(r"\.\d+", "", value).replace("Z", "+00:00"))
    fraction = re.search(r"\.(\d+)", value)
    epoch = int((parsed.replace(microsecond=0) - datetime(1970, 1, 1, tzinfo=timezone.utc)).total_seconds())
    return str(epoch * 1_000_000_000 + int((fraction.group(1) if fraction else "").ljust(9, "0"))), value[-6:] if not value.endswith("Z") else "Z"


def lines(data):
    for line in data.splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if not isinstance(row, dict):
            raise MigrationError("record must be a JSON object")
        yield row, line


def export(plan_path, output):
    plan_bytes = read_exact(plan_path)
    plan = json.loads(plan_bytes)
    if plan.get("version") != 1 or not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", plan.get("namespace", "")):
        raise MigrationError("plan version/namespace invalid")
    if not plan.get("deletionsReviewed") or not plan.get("sources"):
        raise MigrationError("exact sources and deletion review required")
    deletion = plan.get("deletions", {})
    if bool(deletion.get("path")) == bool(deletion.get("noneConfirmed")):
        raise MigrationError("provide dropped ledger or explicitly confirm none; absence is not proof")
    dropped = set()
    raw_files = []
    ledger_bytes = b""
    if deletion.get("path"):
        data = read_exact(deletion["path"])
        ledger_bytes = data
        raw_files.append(("deletions", data))
        for row, _ in lines(data):
            ident = row.get("id") or row.get("source_id")
            if not isinstance(ident, str) or not ident:
                raise MigrationError("invalid deletion record")
            dropped.add(ident)
    families={"collector-event" if s.get("format")=="history-segment-v1" else "activity-summary" for s in plan["sources"]}
    deletion_family=deletion.get("family") or (next(iter(families)) if len(families)==1 else None)
    if dropped and deletion_family not in ("collector-event","activity-summary"):
        raise MigrationError("mixed sources require an explicit deletion family")
    if len(dropped)>10000 or any(len(x.encode())>500 for x in dropped):
        raise MigrationError("deletion review exceeds identity bounds")
    entries = []
    source_manifest = []
    suppressed_count = 0

    def append(family, source_id, at, raw, fmt, evidence=None, summary=None, end=None):
        ns, zone = stamp(at)
        if not isinstance(source_id, str) or not source_id or len(source_id) > 500:
            raise MigrationError("missing or oversized immutable source identity")
        if end:
            end_ns, _ = stamp(end)
            if int(end_ns) < int(ns):
                raise MigrationError("reversed summary interval")
        ident = "legacy_" + digest(encoded([plan["namespace"], family, source_id]))
        if evidence is not None:
            evidence["id"] = ident
        entries.append(dict(id=ident, sourceID=source_id, family=family, format=fmt, at=at,
                            epochNanos=ns, timezone=zone, raw=raw.decode("utf-8"), rawSHA256=digest(raw),
                            deleted=family==deletion_family and source_id in dropped, evidence=evidence, summary=summary, end=end,
                            attachments=[]))
        if len(entries) > MAX_ROWS:
            raise MigrationError("snapshot exceeds 100000 records; split exact source list")

    for number, source in enumerate(plan["sources"]):
        fmt = source.get("format")
        path = source.get("path")
        if fmt == "history-segment-v1":
            metadata_bytes = read_exact(source["metadata"])
            meta = json.loads(metadata_bytes)
            if not meta.get("endedAt") or not meta.get("sessionID") or not meta.get("segmentID"):
                raise MigrationError("open/unidentified segment requires owner-provided closed snapshot")
            data = read_exact(path)
            rows = list(lines(data))
            if len(rows) != meta.get("eventCount"):
                raise MigrationError("segment metadata count mismatch")
            suppressed = meta.get("suppressedEventCount", 0)
            if not isinstance(suppressed, int) or isinstance(suppressed, bool) or suppressed < 0:
                raise MigrationError("invalid suppressed event count")
            suppressed_count += suppressed
            raw_files.append((f"source-{number}-metadata", metadata_bytes))
            for row, raw in rows:
                allowed = {"id", "timestamp", "kind", "app", "window", "element", "key", "selection", "mouse", "diagnostic", "textRedacted"}
                if set(row) - allowed or not isinstance(row.get("id"), int) or isinstance(row.get("id"), bool):
                    raise MigrationError("unmapped segment fields or identity")
                nested = {"app":{"name","bundleIdentifier","secureInput"}, "window":{"title","url","windowID"},
                          "element":{"role","subrole","title","value","identifier"}, "key":{"text","keyEquivalent","modifiers"},
                          "selection":{"selectedText","location","length"}, "mouse":{"button","clickCount","modifiers"}, "diagnostic":{"message"}}
                for field, allowed_fields in nested.items():
                    if row.get(field) is not None and (not isinstance(row[field],dict) or set(row[field])-allowed_fields):
                        raise MigrationError("unmapped nested event fields")
                app, window = row.get("app") or {}, row.get("window") or {}
                text = (row.get("key") or {}).get("text") or (row.get("selection") or {}).get("selectedText") or (row.get("element") or {}).get("value") or ""
                evidence = dict(id="", at=row["timestamp"], kind=row["kind"], app=app.get("name") or "", bundle=app.get("bundleIdentifier") or "",
                                title=window.get("title") or "", url=window.get("url") or "", text=text,
                                secure=app.get("secureInput", False), privateWindow=False, synthetic=False)
                append("collector-event", f'{meta["sessionID"]}/{meta["segmentID"]}/{row["id"]}', row["timestamp"], raw, fmt, evidence=evidence)
        elif fmt == "horizon-episodes-v1":
            data = read_exact(path)
            for row, raw in lines(data):
                allowed = {"source_id", "start", "end", "duration_sec", "primary_app", "apps", "title", "stem", "domain", "titles", "urls", "typed_chars", "clicks", "parts", "summary", "typed_text", "copied_text", "copied_chars"}
                if set(row) - allowed:
                    raise MigrationError("unmapped episode fields")
                append("activity-summary", row.get("source_id"), row.get("start"), raw, fmt,
                       summary=row.get("summary") or "", end=row.get("end"))
        elif fmt == "horizon-activity-sqlite-v1":
            # Explicit source only. Read-only URI sees committed WAL; no blind db copy.
            db_path = Path(path)
            if not db_path.is_absolute() or db_path != db_path.resolve() or not db_path.is_file():
                raise MigrationError("exact SQLite source required")
            connection = sqlite3.connect(db_path.as_uri()+"?mode=ro", uri=True, timeout=1)
            try:
                deadline = time.monotonic() + 5
                connection.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
                connection.execute("PRAGMA query_only=ON")
                connection.execute("PRAGMA trusted_schema=OFF")
                connection.execute("BEGIN")
                objects = dict(connection.execute("SELECT name,type FROM sqlite_master WHERE name IN ('document','derived')"))
                if objects.get("document") != "table" or objects.get("derived", "table") != "table":
                    raise MigrationError("activity export requires supported tables, not views")
                columns = {r[1] for r in connection.execute("PRAGMA table_info(document)")}
                required = {"doc_id", "source", "source_id", "kind", "ts", "title", "body", "uri", "extra"}
                if not required <= columns:
                    raise MigrationError("unsupported SQLite document schema")
                known = required | {"year","thread_id","direction","author_handle","author_person_id","participants","body_chars","attachment_count"}
                if columns - known:
                    raise MigrationError("unmapped document columns; extend the activity export first")
                tables = {r[0] for r in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                if "derived" in tables:
                    count = connection.execute("SELECT count(*) FROM derived WHERE subject_id IN (SELECT doc_id FROM document WHERE source='activity')").fetchone()[0]
                    if count:
                        raise MigrationError("separate derived activity records need an explicit export mapping")
                connection.row_factory = sqlite3.Row
                rows = connection.execute("SELECT * FROM document WHERE source='activity' ORDER BY doc_id")
                exported = []; exported_bytes = 0
                for row in rows:
                    record = dict(row)
                    if record["kind"] != "activity":
                        raise MigrationError("unexpected activity document kind")
                    extra = json.loads(record["extra"] or "{}")
                    if not isinstance(extra, dict):
                        raise MigrationError("unsupported activity extra")
                    if set(extra)-{"primary_app","apps","urls","titles","duration_sec","end","typed_chars","copied_chars","clicks","domain","stem","parts"}:
                        raise MigrationError("unmapped activity extra fields")
                    if record.get("attachment_count",0):
                        raise MigrationError("activity document attachments need an explicit reference mapping")
                    raw = encoded(record); exported.append(raw); exported_bytes += len(raw)
                    if exported_bytes > MAX_BYTES:
                        raise MigrationError("activity export exceeds snapshot bound")
                    append("activity-summary", record["source_id"], record["ts"], raw, fmt,
                           summary=record["body"], end=extra.get("end"))
                data = b"\n".join(exported)
                connection.rollback()
            finally:
                connection.close()
        else:
            raise MigrationError("unsupported source format; nothing imported")
        if len(data) > MAX_BYTES:
            raise MigrationError("source snapshot too large")
        raw_files.append((f"source-{number}", data))
        source_manifest.append(dict(format=fmt, path=path, sha256=digest(data), bytes=len(data)))

    # Attachments are exact separately approved files, never discovered recursively.
    attachment_files = {}
    for attachment in plan.get("attachments", []):
        if attachment.get("approved") is not True:
            raise MigrationError("attachment needs explicit path approval")
        data = read_exact(attachment["path"])
        sha = digest(data)
        if sha != attachment.get("sha256"):
            raise MigrationError("attachment hash mismatch")
        matches = [e for e in entries if e["sourceID"] == attachment.get("sourceID")]
        if not matches:
            raise MigrationError("attachment has no source record")
        for entry in matches:
            entry["attachments"].append(dict(path="attachments/"+sha, sha256=sha, bytes=len(data)))
        attachment_files[sha] = data
    source_deletions=[dict(family=deletion_family,sourceID=ident,id="legacy_"+digest(encoded([plan["namespace"],deletion_family,ident]))) for ident in sorted(dropped)]
    payload = encoded(dict(version=2, namespace=plan["namespace"], entries=entries,sourceDeletions=source_deletions,deletionLedgerSHA256=digest(ledger_bytes)))
    if len(payload) > MAX_BYTES:
        raise MigrationError("normalized snapshot too large; split approved source list")
    output = Path(output)
    if not output.is_absolute() or output != output.resolve() or output.exists():
        raise MigrationError("output must be a new exact absolute directory")
    output.mkdir(mode=0o700)
    def write(relative, data):
        path = output / relative
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with path.open("xb") as stream:
            os.chmod(path, 0o600); stream.write(data); stream.flush(); os.fsync(stream.fileno())
    write("snapshot.json", payload)
    for name, data in raw_files:
        write("raw/"+name, data)
    for sha, data in attachment_files.items():
        write("attachments/"+sha, data)
    manifest = dict(version=1, snapshotSHA256=digest(payload), planSHA256=digest(plan_bytes), records=len(entries),
                    sources=source_manifest, sourceDeleted=sum(e["deleted"] for e in entries),
                    sourceSuppressedEvents=suppressed_count,
                    unmatchedDeletionRecords=len(dropped-{e["sourceID"] for e in entries if e["family"]==deletion_family}),
                    reviewedSourceDeletions=len(source_deletions),deletionLedgerSHA256=digest(ledger_bytes),
                    rawFiles=[dict(path="raw/"+name,sha256=digest(data),bytes=len(data)) for name,data in raw_files],
                    attachments=[dict(path="attachments/"+sha,sha256=sha,bytes=len(data)) for sha,data in attachment_files.items()],
                    types={kind:sum(e["family"] == kind for e in entries) for kind in sorted({e["family"] for e in entries})},
                    earliest=min((e["at"] for e in entries), key=lambda t:int(stamp(t)[0]), default=None),
                    latest=max((e["at"] for e in entries), key=lambda t:int(stamp(t)[0]), default=None))
    write("manifest.json", encoded(manifest))
    return {"records":len(entries), "snapshotSHA256":digest(payload), "sourceDeleted":manifest["sourceDeleted"], "status":"snapshot_only_not_imported"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(export(args.plan,args.output)))
    except MigrationError as error:
        print(json.dumps({"status":"blocked", "reason":str(error)}))
        return 1
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error):
        # No source text, SQL values or private filenames in console exceptions.
        print(json.dumps({"status":"blocked", "reason":"invalid, changing, missing, unsupported or unapproved source; no import performed"}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
