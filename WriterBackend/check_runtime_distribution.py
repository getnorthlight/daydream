import json
import pathlib
import runpy
import tempfile
from unittest.mock import patch

module = runpy.run_path(str(pathlib.Path(__file__).with_name("runtime_distribution.py")), run_name="test")
with tempfile.TemporaryDirectory(prefix="writer-plan-", dir="/private/tmp") as tmp:
    source=pathlib.Path(tmp)/"source";source.mkdir()
    path=source/"libllama.0.dylib";path.write_bytes(b"synthetic")
    pin=module["digest"](path)
    globals_=module["plan"].__globals__
    with patch.dict(globals_, pins=lambda:{path.name:(9,pin)}, dependencies=lambda _: ["@rpath/libllama.0.dylib"]):
        value=module["plan"](source,pathlib.Path(tmp)/"stage")
        team=json.loads((pathlib.Path(__file__).resolve().parents[1]/"packaging/signing.json").read_text())["apple_team_id"]
        assert value["executed"] is False and value["teamID"] == module["TEAM"] == team and len(team) == 10
        assert not (pathlib.Path(tmp)/"stage").exists()
        try: module["plan"](source,source)
        except ValueError: pass
        else: raise AssertionError("existing stage accepted")
        path.write_bytes(b"tampered!")
        try: module["plan"](source,pathlib.Path(tmp)/"stage")
        except ValueError: pass
        else: raise AssertionError("tamper accepted")
    try: module["candidate"](source,"../escape","x")
    except ValueError: pass
    else: raise AssertionError("invalid candidate metadata")
print("PASS synthetic plan/nonexecution/tamper/staging/metadata checks. Not signed-artifact verification.")
