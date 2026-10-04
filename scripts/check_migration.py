"""Synthetic snapshots only. Never resolves a default user history path."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from contextlib import closing

spec=importlib.util.spec_from_file_location("migration_export",Path(__file__).with_name("migration_export.py"))
exporter=importlib.util.module_from_spec(spec); spec.loader.exec_module(exporter)
CLI=os.environ["MACMEM_TEST_CLI"]


class MigrationTests(unittest.TestCase):
    def test_stamp_all_fraction_widths_and_pre_epoch(self):
        for digits in ("1", "12", "123", "1234", "12345", "123456", "1234567", "12345678", "123456789"):
            at="1970-01-01T05:45:00."+digits+"+05:45"
            self.assertEqual(exporter.stamp(at),(str(int(digits.ljust(9,"0"))),"+05:45"))
        self.assertEqual(exporter.stamp("1969-12-31T23:59:59.999999999Z"),("-1","Z"))

    def prepare_stage(self,out,sha,name="stage"):
        return self.cli("migration-stage-prepare","--snapshot",str(out/"snapshot.json"),"--snapshot-sha256",sha,"--staging-home",str(self.root/name))

    def stage_call(self,command,ident,*args,ok=True):
        return self.cli(command,"--import-id",ident,*args,ok=ok)

    def test_staged_cli_rich_copy_acceptance_repeat_search_and_cancel(self):
        self.events()
        episode={"source_id":"historical-note","start":self.at,"end":self.at,"primary_app":"TextEdit","apps":["TextEdit"],"summary":"Historical overview, not observed actions."}
        path=self.write("rich-note.jsonl",episode)
        self.plan["sources"].append({"format":"horizon-episodes-v1","path":str(path)})
        out,sha=self.snapshot(); self.initialize()
        original_bytes=(self.root/"events").read_bytes()
        view=self.prepare_stage(out,sha); ident=view["id"]
        self.stage_call("migration-stage-step",ident,ok=False)
        for expected in (2,4,6):
            result=self.stage_call("migration-stage-step",ident,"--confirm-import","--batch-limit","2")
            self.assertEqual(result["progress"]["next"],expected)
            self.assertEqual(self.count("records"),0,"staging never writes destination actions")
        self.assertEqual(self.stage_call("migration-stage-status",ident)["status"],"staged")
        review=self.stage_call("migration-adoption-review",ident)["adoption"]
        self.assertEqual((len(review["actionIDs"]),len(review["historicalSummaryIDs"]),review["originalCount"]),(5,1,6))
        self.stage_call("migration-adoption-confirm",ident,ok=False)
        first=self.stage_call("migration-adoption-confirm",ident,"--confirm-import")
        self.assertEqual(first,self.stage_call("migration-adoption-confirm",ident,"--confirm-import"))
        self.assertEqual(self.count("records"),5)
        result=self.cli("search","Distinct","--search-report")
        self.assertEqual(result["backend"],"sqlite")
        self.assertEqual(len(result["hits"]),5)
        self.assertEqual(len(self.period()["historicalSummaries"]),1)
        self.cli("delete",first["actionIDs"][0],ok=False)
        self.assertEqual(self.count("records"),5,"overlapping unreferenced summary requires its own exact deletion review")
        self.assertEqual(original_bytes,(self.root/"events").read_bytes())
        self.stage_call("migration-stage-cancel",ident,ok=False)
        repeated=self.prepare_stage(out,sha,"repeat-stage")["id"]
        self.stage_call("migration-stage-step",repeated,"--confirm-import")
        self.assertEqual(self.stage_call("migration-adoption-review",repeated)["adoption"]["actionIDs"],[])
        self.stage_call("migration-stage-cancel",repeated)
        self.assertEqual(self.stage_call("migration-stage-status",repeated)["status"],"cancelled")
        self.assertEqual(self.count("records"),5)
        self.stage_call("migration-adoption-confirm",repeated,"--confirm-import",ok=False)
        self.assertTrue((self.root/"repeat-stage"/"memory.sqlite").exists())

    def test_staged_cli_revision_change_blocks_adoption_without_erasure(self):
        self.events(); out,sha=self.snapshot(); self.initialize()
        ident=self.prepare_stage(out,sha)["id"]
        self.stage_call("migration-stage-step",ident,"--confirm-import")
        self.stage_call("migration-adoption-review",ident)
        # Separate fixture mutation through the existing canonical importer.
        dry=self.dry(out,sha); self.apply(out,sha,dry["policySHA256"])
        self.stage_call("migration-adoption-confirm",ident,"--confirm-import",ok=False)
        self.assertEqual(self.count("records"),5)
        self.stage_call("migration-stage-cancel",ident)
        self.assertEqual(self.count("records"),5)

    def test_export_rejects_parent_links_and_sqlite_views(self):
        self.events(); linked=self.root/"linked"; linked.symlink_to(self.root,target_is_directory=True)
        with self.assertRaises(exporter.MigrationError): exporter.read_exact(linked/"events")
        db=self.root/"view.sqlite"
        with closing(sqlite3.connect(db)) as conn, conn:
            conn.execute("CREATE TABLE originals(doc_id,source,source_id,kind,ts,title,body,uri,extra)")
            conn.execute("CREATE VIEW document AS SELECT * FROM originals")
        self.plan["sources"]=[{"format":"horizon-activity-sqlite-v1","path":str(db)}]
        with self.assertRaisesRegex(exporter.MigrationError,"not views"): self.snapshot()

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix="macmem-migration-test-")
        self.root=Path(self.temp.name).resolve(); self.dest=self.root/"destination"
        self.at=datetime.now(timezone.utc).replace(microsecond=123456).isoformat()
        self.plan={"version":1,"namespace":"fabricated-laptop","deletionsReviewed":True,"deletions":{"noneConfirmed":True},"sources":[]}
        self.batch=0

    def tearDown(self):
        self.temp.cleanup()

    def write(self,name,value):
        path=self.root/name; path.write_text(json.dumps(value)); return path

    def events(self, rows=None, filename="events"):
        rows=rows if rows is not None else [{"id":n,"timestamp":self.at,"kind":"mouse.click","app":{"name":"TextEdit","bundleIdentifier":"com.apple.TextEdit","secureInput":False},"window":{"title":f"Distinct action {n}"},"mouse":{"button":"left","clickCount":1,"modifiers":[]}} for n in range(5)]
        path=self.root/filename; path.write_bytes(b"\n".join(json.dumps(row).encode() for row in rows))
        meta=self.write(filename+".metadata",{"sessionID":"session-a","segmentID":"segment-a","startedAt":self.at,"endedAt":self.at,"eventCount":len(rows),"suppressedEventCount":0})
        self.plan["sources"].append({"format":"history-segment-v1","path":str(path),"metadata":str(meta)})
        return rows

    def snapshot(self):
        self.batch+=1
        path=self.write(f"plan-{self.batch}.json",self.plan)
        out=self.root/f"snapshot-{self.batch}"
        result=exporter.export(path,out)
        return out,result["snapshotSHA256"]

    def cli(self,*args,ok=True):
        result=subprocess.run([CLI,"--home",str(self.dest),"--local",*args],capture_output=True,text=True,timeout=15)
        if ok:
            self.assertEqual(result.returncode,0,result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode,0)
        return result

    def initialize(self,**changes):
        policy={"blockedApps":[],"blockedDomains":[],"retentionDays":30,"captureText":False,"revision":"synthetic-policy",**changes}
        return self.cli("--policy-file",str(self.write("policy.json",policy)),"migration-init")

    def dry(self,out,sha):
        return self.cli("--snapshot",str(out/"snapshot.json"),"--snapshot-sha256",sha,"migration-dry-run")

    def apply(self,out,sha,policy,limit=100,accept=False,ok=True):
        args=["--snapshot",str(out/"snapshot.json"),"--snapshot-sha256",sha,"--policy-sha256",policy,"--batch-limit",str(limit)]
        if accept: args.append("--accept-exclusions")
        return self.cli(*args,"migration-import",ok=ok)

    def period(self,after=None,limit=100):
        now=datetime.now(timezone.utc)
        args=["--start",(now-timedelta(days=1)).isoformat(),"--end",(now+timedelta(days=1)).isoformat(),"--batch-limit",str(limit)]
        if after: args += ["--after",after]
        return self.cli(*args,"migration-period")

    def count(self,table):
        with closing(sqlite3.connect(self.dest/"memory.sqlite")) as db, db:
            return db.execute(f"SELECT count(*) FROM {table}").fetchone()[0]

    def test_five_actions_resume_repeat_and_exact_originals(self):
        self.events(); out,sha=self.snapshot(); self.initialize()
        before=hashlib.sha256((self.root/"events").read_bytes()).hexdigest()
        dry=self.dry(out,sha); self.assertFalse(dry["blocked"]); self.assertEqual(dry["counts"],{"accepted":5})
        self.assertEqual(self.count("records"),0,"dry run is read-only")
        self.assertEqual(self.apply(out,sha,dry["policySHA256"],2)["next"],2)
        self.assertEqual(self.apply(out,sha,dry["policySHA256"],2)["next"],4)
        self.assertTrue(self.apply(out,sha,dry["policySHA256"],2)["complete"])
        self.assertTrue(self.apply(out,sha,dry["policySHA256"])["complete"])
        self.assertEqual(self.count("records"),5)
        ids=[]; cursor=None
        while True:
            page=self.period(cursor,2); ids += [x["id"] for x in page["actions"]]
            cursor=page.get("next")
            if cursor is None: break
        self.assertEqual(len(set(ids)),5)
        original=self.cli("migration-original",ids[0])
        self.assertEqual(hashlib.sha256(original["raw"].encode()).hexdigest(),original["rawSHA256"])
        self.assertEqual(before,hashlib.sha256((self.root/"events").read_bytes()).hexdigest())

    def test_duplicate_identity_and_richer_alternate_block(self):
        rows=self.events(); self.events(rows,filename="duplicate")
        out,sha=self.snapshot(); self.initialize(); dry=self.dry(out,sha)
        self.assertEqual(dry["counts"],{"accepted":5,"duplicate_same_source":5})
        self.apply(out,sha,dry["policySHA256"]); self.assertEqual(self.count("records"),5)
        rows[0]["window"]["title"]="Richer alternate original"
        self.events(rows,filename="alternate")
        out,sha=self.snapshot(); dry=self.dry(out,sha)
        self.assertTrue(dry["blocked"])
        self.apply(out,sha,dry["policySHA256"],ok=False)
        self.assertEqual(self.count("records"),5)

    def test_chunk_failure_rolls_back_checkpoint_and_records(self):
        self.events(); out,sha=self.snapshot(); self.initialize(); dry=self.dry(out,sha)
        with closing(sqlite3.connect(self.dest/"memory.sqlite")) as db, db:
            db.execute("CREATE TRIGGER synthetic_failure BEFORE INSERT ON records WHEN json_extract(NEW.body,'$.title')='Distinct action 3' BEGIN SELECT RAISE(ABORT,'synthetic'); END")
        self.apply(out,sha,dry["policySHA256"],ok=False)
        self.assertEqual(self.count("records"),0); self.assertEqual(self.count("migration_batches"),0)
        with closing(sqlite3.connect(self.dest/"memory.sqlite")) as db, db: db.execute("DROP TRIGGER synthetic_failure")
        self.apply(out,sha,dry["policySHA256"]); self.assertEqual(self.count("records"),5)

    def test_summary_only_not_fabricated_event(self):
        row={"source_id":"episode-only","start":self.at,"end":self.at,"primary_app":"TextEdit","apps":["TextEdit"],"summary":"Historical summary reported five actions; originals unavailable."}
        path=self.write("episodes.jsonl",row)
        self.plan["sources"]=[{"format":"horizon-episodes-v1","path":str(path)}]
        out,sha=self.snapshot(); self.initialize(); dry=self.dry(out,sha)
        self.apply(out,sha,dry["policySHA256"])
        self.assertEqual(self.count("records"),0)
        result=self.period()
        self.assertEqual(result["actions"],[]); self.assertEqual(result["historicalSummaries"][0]["text"],row["summary"])

    def test_nanoseconds_offset_preserved(self):
        rows=self.events()
        value=datetime.now(timezone(timedelta(hours=5,minutes=45))).strftime("%Y-%m-%dT%H:%M:%S")+".123456789+05:45"
        for row in rows: row["timestamp"]=value
        (self.root/"events").write_text("\n".join(json.dumps(row) for row in rows))
        out,sha=self.snapshot(); self.initialize(); dry=self.dry(out,sha)
        self.apply(out,sha,dry["policySHA256"])
        original=self.cli("migration-original",dry["decisions"][0]["id"])
        self.assertEqual(original["at"],value); self.assertEqual(original["timezone"],"+05:45")
        self.assertTrue(original["epochNanos"].endswith("123456789"))

    def test_missing_attachment_and_approved_reference(self):
        self.events(); artifact=self.root/"fabricated.txt"; artifact.write_text("synthetic attachment")
        sha_file=hashlib.sha256(artifact.read_bytes()).hexdigest()
        self.plan["attachments"]=[{"approved":True,"sourceID":"session-a/segment-a/0","path":str(artifact),"sha256":sha_file}]
        out,sha=self.snapshot(); self.initialize()
        data=(out/"attachments"/sha_file).read_bytes(); (out/"attachments"/sha_file).unlink()
        self.assertTrue(self.dry(out,sha)["blocked"])
        (out/"attachments"/sha_file).write_bytes(data)
        dry=self.dry(out,sha); self.apply(out,sha,dry["policySHA256"])
        self.assertEqual((self.dest/"migration-attachments"/sha_file).read_bytes(),data)
        ident=next(e["id"] for e in json.loads((out/"snapshot.json").read_text())["entries"] if e["attachments"])
        self.cli("delete",ident)
        self.assertIsNone(self.cli("migration-original",ident))
        self.assertFalse((self.dest/"migration-attachments"/sha_file).exists())
        self.assertEqual((out/"attachments"/sha_file).read_bytes(),data,"retained raw export is not deleted")

    def test_new_source_tombstone_removes_previously_imported_original(self):
        self.events(); out,sha=self.snapshot(); self.initialize(); dry=self.dry(out,sha)
        self.apply(out,sha,dry["policySHA256"])
        ledger=self.write("later-dropped.jsonl",{"id":"session-a/segment-a/0"})
        self.plan["deletions"]={"path":str(ledger)}
        out2,sha2=self.snapshot(); dry2=self.dry(out2,sha2)
        self.apply(out2,sha2,dry2["policySHA256"],accept=True)
        self.assertEqual(self.count("records"),4); self.assertEqual(self.count("migration_originals"),4)
        self.assertEqual(len(self.period()["actions"]),4)
        self.apply(out,sha,dry["policySHA256"],accept=True)
        self.assertEqual(self.count("records"),4,"older snapshot never resurrects deleted source")

    def test_linked_attachment_destination_rejected_without_external_write(self):
        self.events(); artifact=self.root/"fabricated.txt"; artifact.write_text("synthetic attachment")
        sha_file=hashlib.sha256(artifact.read_bytes()).hexdigest()
        self.plan["attachments"]=[{"approved":True,"sourceID":"session-a/segment-a/0","path":str(artifact),"sha256":sha_file}]
        out,sha=self.snapshot(); self.initialize(); dry=self.dry(out,sha)
        outside=self.root/"unrelated"; outside.mkdir()
        (self.dest/"migration-attachments").symlink_to(outside,target_is_directory=True)
        self.apply(out,sha,dry["policySHA256"],ok=False)
        self.assertEqual(list(outside.iterdir()),[])
        self.assertEqual(self.count("records"),0)

    def test_current_app_exclusion_and_expiry_purge_originals(self):
        self.events(); out,sha=self.snapshot(); self.initialize(blockedApps=["com.apple.TextEdit"])
        dry=self.dry(out,sha)
        self.assertEqual(dry["counts"],{"excluded_privacy_or_unverified_browser":5})
        # A separate explicitly initialized fixture exercises retention maintenance.
        self.dest=self.root/"expiry-destination"; self.initialize()
        dry=self.dry(out,sha); self.apply(out,sha,dry["policySHA256"])
        expired=(datetime.now(timezone.utc)-timedelta(days=60)).isoformat()
        with closing(sqlite3.connect(self.dest/"memory.sqlite")) as db, db:
            for ident,body in db.execute("SELECT id,body FROM migration_originals").fetchall():
                value=json.loads(body); value["at"]=expired
                db.execute("UPDATE migration_originals SET body=? WHERE id=?",(json.dumps(value),ident))
        self.cli("writer")
        self.assertEqual(self.count("records"),0); self.assertEqual(self.count("migration_originals"),0)

    def test_policy_exclusions_and_source_tombstones_explicit(self):
        rows=self.events(); rows[1]["app"]["secureInput"]=True
        rows[2]["timestamp"]=(datetime.now(timezone.utc)-timedelta(days=60)).isoformat()
        rows[3]["kind"]="keyboard.text_input"; rows[3]["key"]={"text":"fabricated private draft","modifiers":[]}
        (self.root/"events").write_text("\n".join(json.dumps(row) for row in rows))
        ledger=self.write("dropped.jsonl",{"id":"session-a/segment-a/0"})
        self.plan["deletions"]={"path":str(ledger)}
        out,sha=self.snapshot(); self.initialize(); dry=self.dry(out,sha)
        self.assertEqual(dry["counts"]["accepted"],1); self.assertEqual(dry["counts"]["excluded_deleted"],1)
        self.apply(out,sha,dry["policySHA256"],ok=False)
        self.apply(out,sha,dry["policySHA256"],accept=True)
        self.assertEqual(self.count("records"),1); self.assertEqual(self.count("tombstones"),1)

    def test_hash_policy_drift_and_not_unused_destination(self):
        self.events(); out,sha=self.snapshot(); self.initialize(); dry=self.dry(out,sha)
        self.cli("migration-init",ok=False)
        self.apply(out,sha,"0"*64,ok=False)
        self.cli("--snapshot",str(out/"snapshot.json"),"--snapshot-sha256","0"*64,"migration-dry-run",ok=False)
        with closing(sqlite3.connect(self.dest/"memory.sqlite")) as db, db:
            db.execute("INSERT INTO metadata VALUES('capture',?)",(json.dumps({"state":"off"}),))
        self.apply(out,sha,dry["policySHA256"],ok=False)

    def test_typed_consent_does_not_authorize_selection_or_unknown_field(self):
        rows=self.events()
        rows[0]["kind"]="selection.changed"; rows[0]["selection"]={"selectedText":"fabricated selected content"}
        rows[1]["kind"]="keyboard.text_input"; rows[1]["key"]={"text":"fabricated typed draft","modifiers":[]}
        rows[2]["kind"]="keyboard.text_input"; rows[2]["key"]={"text":"fabricated safe draft","modifiers":[]}; rows[2]["element"]={"role":"AXTextArea"}
        (self.root/"events").write_text("\n".join(json.dumps(row) for row in rows))
        out,sha=self.snapshot(); self.initialize(captureText=True,typedConsentVersion=1)
        dry=self.dry(out,sha)
        self.assertEqual(dry["counts"],{"accepted":3,"excluded_legacy_text_scope_unverified":2})

    def test_schema_mismatch_missing_deletion_review_and_open_segment(self):
        self.events()
        self.plan["deletionsReviewed"]=False
        with self.assertRaises(exporter.MigrationError): self.snapshot()
        self.plan["deletionsReviewed"]=True
        meta=json.loads((self.root/"events.metadata").read_text()); meta["endedAt"]=None
        self.write("events.metadata",meta)
        with self.assertRaises(exporter.MigrationError): self.snapshot()
        db=self.root/"wrong.sqlite"
        with closing(sqlite3.connect(db)) as conn, conn: conn.execute("CREATE TABLE document(id TEXT)")
        self.plan["sources"]=[{"format":"horizon-activity-sqlite-v1","path":str(db)}]
        with self.assertRaises(exporter.MigrationError): self.snapshot()

    def test_wal_activity_export_is_scoped_and_consistent(self):
        db=self.root/"archive.sqlite"; writer=sqlite3.connect(db)
        try:
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("CREATE TABLE document(doc_id TEXT,source TEXT,source_id TEXT,kind TEXT,ts TEXT,title TEXT,body TEXT,uri TEXT,extra TEXT)")
            def row(i,source="activity"):
                return (str(i),source,"episode"+str(i),"activity",self.at,"Fabricated","Historical summary","",json.dumps({"primary_app":"TextEdit","apps":["TextEdit"],"end":self.at}))
            writer.execute("INSERT INTO document VALUES(?,?,?,?,?,?,?,?,?)",row(1)); writer.execute("INSERT INTO document VALUES(?,?,?,?,?,?,?,?,?)",row(2,"gmail")); writer.commit()
            self.assertTrue(Path(str(db)+"-wal").exists())
            self.plan["sources"]=[{"format":"horizon-activity-sqlite-v1","path":str(db)}]
            original_connect=exporter.sqlite3.connect
            class SnapshotConnection(sqlite3.Connection):
                def execute(inner,sql,*args):
                    cursor=super().execute(sql,*args)
                    if sql.startswith("SELECT * FROM document"):
                        writer.execute("INSERT INTO document VALUES(?,?,?,?,?,?,?,?,?)",row(3)); writer.commit()
                    return cursor
            exporter.sqlite3.connect=lambda *a,**kw: original_connect(*a,**kw,factory=SnapshotConnection)
            try: out,sha=self.snapshot()
            finally: exporter.sqlite3.connect=original_connect
            snapshot=json.loads((out/"snapshot.json").read_text())
            self.assertEqual(len(snapshot["entries"]),1,"WAL commit visible at transaction start; later commit excluded")
            self.assertNotIn('"source":"gmail"',(out/"raw/source-0").read_text())
            self.initialize(); dry=self.dry(out,sha); self.apply(out,sha,dry["policySHA256"])
            self.assertEqual(len(self.period()["historicalSummaries"]),1)
            writer.execute("CREATE TABLE derived(subject_id TEXT, body TEXT)")
            writer.execute("INSERT INTO derived VALUES('1','synthetic unmapped historical analysis')"); writer.commit()
            with self.assertRaisesRegex(exporter.MigrationError,"explicit export mapping"):
                self.snapshot()
        finally:
            writer.close()


if __name__ == "__main__": unittest.main()
