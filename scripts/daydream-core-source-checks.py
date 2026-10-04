"""Source-only synthetic regressions, explicitly NOT extracted-artifact tests."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

project=Path(__file__).resolve().parents[1]
root=Path(tempfile.mkdtemp(prefix="daydream-core-source-",dir="/private/tmp"))
scratch=Path("/private/tmp/macmem-controls.piliPE")
modules=scratch/"debug/Modules"
report={"kind":"rebuilt-source-not-artifact","root":str(root),"commands":[]}
manifest=json.loads((project/"dist/Daydream-OFF-Trial-20260913-0221-source.json").read_text())
def inventory():
    return {p:hashlib.sha256((project/p).read_bytes()).hexdigest() for p in manifest if (project/p).is_file()}
report["source_before"]=inventory()
report["candidate_mismatches_before"]=[p for p,h in manifest.items() if report["source_before"].get(p)!=h]
env={**os.environ,"CLANG_MODULE_CACHE_PATH":"/private/tmp/macmem-typesense-clang","PYTHONDONTWRITEBYTECODE":"1"}
def run(name,args):
    p=subprocess.run([str(x) for x in args],cwd=project,env=env,text=True,capture_output=True,timeout=60)
    (root/(name+".log")).write_text(p.stdout+p.stderr)
    report["commands"].append({"name":name,"exit":p.returncode,"args":[str(x) for x in args],"log":str(root/(name+".log")),"pass_lines":sum(line.startswith("PASS") for line in p.stdout.splitlines())})
    (root/"receipt.json").write_text(json.dumps(report,indent=2))
    print(name,p.returncode,flush=True)
    assert p.returncode==0,(name,p.stdout[-1500:],p.stderr[-1500:])
def objects(target):return sorted((scratch/"debug"/(target+".build")).glob("*.swift.o"))
try:
    for product in ["MacMem","MacMemChecks","ProductionBindingChecks"]:
        run("build-"+product,["swift","build","--scratch-path",scratch,"--product",product])
    for product in ["MacMemChecks","ProductionBindingChecks"]:
        run(product,[scratch/"debug"/product])
    for name in ["memory-controls","onboarding-staging"]:
        run("compile-"+name,["swiftc","-parse-as-library","-I",modules,"-I","Sources/CSQLite",f"scripts/{name}-checks.swift",*objects("MemoryCore"),*objects("HistoryCore"),*objects("PrivacyPolicy"),"-o",root/name])
        run(name,[root/name])
    # Everything EventCapture/Coordinator reference. ChromeTypingWitness is empty
    # unless -DDAYDREAM_CHROME_TYPING (private build only); WebTypingRoute is
    # empty unless DAYDREAM_OWNER_TYPING is set (owner build only).
    capture=["EventCapture","Coordinator","AccessibilitySnapshot","ChromeModeReader","NativeFocusWitness","NativeCaptureReceipts",
             "BrowserCaptureReceipt","BrowserCaptureTransport","BrowserProviderResolver","ChromeTypingWitness","ChromeEventSender","ChromePageRecorder",
             "NativeTypingRoute","MessagesComposer","TypingHotkey","WebTypingRoute","TerminalToolProcesses"]
    run("compile-production-capture",["swiftc","-parse-as-library","-I",modules,"-I","Sources/CSQLite","-Xcc","-fmodule-map-file="+str(scratch/"debug/CLlamaBridge.build/module.modulemap"),*[f"Sources/MacMemApp/{name}.swift" for name in capture],"scripts/production-event-capture-checks.swift",*[p for t in ["MemoryCore","HistoryCore","CoreIntegration","WriterBackend","PrivacyPolicy","BrowserBridge"] for p in objects(t)],*sorted((scratch/"debug/CLlamaBridge.build").glob("*.o")),"-lc++","-o",root/"production-capture"])
    run("production-capture",[root/"production-capture"])
    report["completed"]=True
finally:
    report["source_after"]=inventory()
    report["changed_during_checks"]=[p for p,h in report["source_before"].items() if report["source_after"].get(p)!=h]
    (root/"receipt.json").write_text(json.dumps(report,indent=2))
    print("RECEIPT",root/"receipt.json",flush=True)
