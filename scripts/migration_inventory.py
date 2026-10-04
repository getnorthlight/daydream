"""Count-only first phase for ONE explicitly approved source. Never exports records.

No defaults, discovery, source writes, network, models or destination creation.
Counts do not approve deletion history, policy eligibility or import completeness.
"""
import argparse
import json
import io
from pathlib import Path
import sqlite3
import time
from contextlib import closing
from migration_export import MigrationError, read_exact, MAX_ROWS


def inventory(fmt, path, metadata=None):
    source = Path(path)
    if not source.is_absolute() or source.resolve(strict=True) != source or not source.is_file():
        raise MigrationError("exact nonlinked source required")
    if fmt == "horizon-activity-sqlite-v1":
        deadline = time.monotonic() + 2
        with closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True, timeout=1)) as db:
            try:
                db.execute("PRAGMA query_only=ON")
                db.execute("PRAGMA trusted_schema=OFF")
                db.set_progress_handler(lambda: int(time.monotonic() >= deadline), 1000)
                db.execute("BEGIN")
                objects = dict(db.execute("SELECT name,type FROM sqlite_master WHERE name IN ('document','derived')"))
                if objects.get("document") != "table" or objects.get("derived", "table") != "table":
                    raise MigrationError("unsupported schema")
                columns = {r[1] for r in db.execute("PRAGMA table_info(document)")}
                required = {"doc_id", "source", "source_id", "kind", "ts", "title", "body", "uri", "extra"}
                known = required | {"year", "thread_id", "direction", "author_handle", "author_person_id", "participants", "body_chars", "attachment_count"}
                if not required <= columns or columns - known:
                    raise MigrationError("unmapped document schema")
                # Aggregate only. No body, title, timestamp, identity or extra selected.
                count = db.execute("SELECT count(*) FROM (SELECT 1 FROM document WHERE source='activity' LIMIT ?)", (MAX_ROWS + 1,)).fetchone()[0]
                derived = False
                if "derived" in objects:
                    derived = bool(db.execute("SELECT EXISTS(SELECT 1 FROM derived WHERE subject_id IN (SELECT doc_id FROM document WHERE source='activity'))").fetchone()[0])
                attachments = False
                if "attachment_count" in columns:
                    attachments = bool(db.execute("SELECT EXISTS(SELECT 1 FROM document WHERE source='activity' AND attachment_count>0)").fetchone()[0])
                return {"format":fmt, "activityRows":min(count, MAX_ROWS), "countClipped":count>MAX_ROWS,
                        "unmappedDerived":derived, "unmappedAttachments":attachments,
                        "scope":"schema_counts_only", "contentValidated":False, "imported":False}
            finally:
                db.rollback()
    if fmt not in ("history-segment-v1", "horizon-episodes-v1"):
        raise MigrationError("unsupported format")
    data = read_exact(source)
    count = 0
    for line in io.BytesIO(data):
        count += bool(line.strip())
        if count > MAX_ROWS:
            raise MigrationError("count exceeds explicit batch bound")
    result = {"format":fmt,"nonemptyLines":count,"bytes":len(data),"scope":"counts_only",
              "contentValidated":False,"imported":False}
    if fmt == "history-segment-v1":
        if not metadata or Path(metadata).resolve(strict=True) != Path(metadata):
            raise MigrationError("exact nonlinked metadata required")
        meta = json.loads(read_exact(metadata))
        if not isinstance(meta, dict) or not meta.get("endedAt") or not meta.get("sessionID") or not meta.get("segmentID") or type(meta.get("eventCount")) is not int or meta.get("eventCount") != count:
            raise MigrationError("closed segment count not established")
        result["closedSegmentCountMatches"] = True
        suppressed = meta.get("suppressedEventCount", 0)
        if type(suppressed) is not int or suppressed < 0:
            raise MigrationError("invalid suppressed count")
        result["suppressedEvents"] = suppressed
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--format", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--metadata")
    args = parser.parse_args()
    try:
        print(json.dumps(inventory(args.format, args.source, args.metadata)))
        return 0
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, sqlite3.Error, MigrationError):
        print(json.dumps({"status":"blocked","scope":"schema_counts_only","imported":False}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
