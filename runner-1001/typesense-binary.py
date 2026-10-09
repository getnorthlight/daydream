#!/usr/bin/env python3
"""usage: typesense-binary.py PATH -- PASS when PATH (TYPESENSE_BINARY) is the pinned typesense-server.
The pin is packaging/TypesenseRuntime/local-typesense-v30.2.json's inputServerSHA256. Reads the file; runs nothing."""
import hashlib, json, sys
want = json.load(open("packaging/TypesenseRuntime/local-typesense-v30.2.json"))["inputServerSHA256"]
path = sys.argv[1] if len(sys.argv) > 1 else ""
if not path:
    print("FAIL TYPESENSE_BINARY is not set: point it at the pinned typesense-server (a copy on the internal disk)")
    sys.exit(1)
got = hashlib.sha256(open(path, "rb").read()).hexdigest()
print(("PASS" if got == want else "FAIL") + " TYPESENSE_BINARY is the pinned server (%s)" % got[:16])
sys.exit(0 if got == want else 1)
