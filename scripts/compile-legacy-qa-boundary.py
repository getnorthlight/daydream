"""Headless full-app module/object compilation only; never link, launch or stage an app."""
import argparse,hashlib,json,os,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--canonical-build',required=True);p.add_argument('--canonical-source',required=True);p.add_argument('--out',required=True);a=p.parse_args()
root=Path(__file__).resolve().parent.parent;build=Path(a.canonical_build).resolve();stage=Path(a.canonical_source).resolve();out=Path(a.out)
assert not out.exists();out.mkdir(mode=0o700)
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def git(*args):return subprocess.check_output(['git','-C',str(root),*args]).decode().strip()
description=build/'description.json';d=json.loads(description.read_text());v=d['swiftCommands']['C.MacMemApp-arm64-apple-macosx-release.module']
assert len(v['sources'])==80
assert git('rev-parse','HEAD')==git('rev-parse','5d436b01e2675b0d5caadd830083441975b6f919') or git('merge-base','HEAD','5d436b01e2675b0d5caadd830083441975b6f919')=='5d436b01e2675b0d5caadd830083441975b6f919'
stage_receipt=stage.parent/'stage-receipt.json';stage_meta=json.loads(stage_receipt.read_text());assert stage_meta['source_commit']=='5d436b01e2675b0d5caadd830083441975b6f919'
assert stage_meta['qa_harness'] is True and stage_meta['swift_flags']==['-Xswiftc','-DDAYDREAM_OWNER_TYPING','-Xswiftc','-DDAYDREAM_CHROME_TYPING','-Xswiftc','-DDAYDREAM_QA_HARNESS']
source=[root/Path(x).relative_to(stage) for x in v['sources']];assert all(x.is_file() for x in source)
pins={str(x):sha(x) for x in source};pins[str(Path(__file__))]=sha(Path(__file__));pins[str(description)]=sha(description);pins[str(stage_receipt)]=sha(stage_receipt)
# Verify exact canonical source/module provenance for every target, including unchanged MemoryUI.
for command in d['swiftCommands'].values():
 if command.get('moduleName')=='MacMemApp':continue
 for x in command['sources']:
  x=Path(x)
  if x.is_relative_to(stage):
   owned=root/x.relative_to(stage);assert owned.is_file() and sha(owned)==sha(x),(owned,'canonical source drift')
   assert hashlib.sha256(subprocess.check_output(['git','-C',str(root),'show','5d436b01e2675b0d5caadd830083441975b6f919:'+str(x.relative_to(stage))])).hexdigest()==sha(x)
   assert 'DAYDREAM_QA_HARNESS' not in owned.read_text(),(owned,'dependency has configuration-sensitive QA code')
   pins[str(owned)]=sha(owned);pins[str(x)]=sha(x)
 for x in command['outputs']:
  q=Path(x['name'] if isinstance(x,dict) else x)
  if q.is_file():pins[str(q)]=sha(q)
# Include imported module interfaces and fixed C module map/header inputs.
for x in (build/'Modules').glob('*'):
 if x.is_file() and not x.name.startswith('MacMemApp.'):pins[str(x)]=sha(x)
for x in [stage/'Sources/CSQLite/module.modulemap',build/'CLlamaBridge.build/module.modulemap',stage/'WriterBackend/Sources/CLlamaBridge/include/WriterLlama.h']:
 assert x.is_file();pins[str(x)]=sha(x)
other=[];args=v['otherArguments'];i=0
while i<len(args):
 token=args[i]
 if token in ['-num-threads','-module-cache-path']:
  other += [token,'1' if token=='-num-threads' else str(out/'ModuleCache')];i+=2
 elif token.startswith('-j'):other+=['-j2'];i+=1
 elif token=='-DDAYDREAM_QA_HARNESS' or token=='-parseable-output':i+=1
 else:other+=[token];i+=1
receipt={'schema':'daydream-legacy-qa-boundary-compile/v1','head':git('rev-parse','HEAD'),'canonicalSource':str(stage),'canonicalBuild':str(build),'inputs':pins,'appSourceCount':len(source),'commands':[],'executedApp':False,'linkedApp':False,'staged':False}
try:
 for name,qa in [('normal',False),('privateQA',True)]:
  folder=out/name;folder.mkdir(mode=0o700)
  objects=folder/'objects';objects.mkdir(mode=0o700);object_files=[objects/(x.stem+'.o') for x in source]
  output_map=folder/'output-file-map.json';output_map.write_text(json.dumps({str(src):{'object':str(obj)} for src,obj in zip(source,object_files)}))
  cmd=[v['executable'],'-module-name','MacMemApp','-emit-module','-emit-module-path',str(folder/'MacMemApp.swiftmodule'),'-emit-object','-output-file-map',str(output_map),'-I',v['importPath']]+[str(x) for x in source]+other+(['-DDAYDREAM_QA_HARNESS'] if qa else [])
  started=time.time()
  with (folder/'compile.log').open('wb') as log:run=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,timeout=600,cwd=folder)
  row={'configuration':name,'argv':cmd,'returncode':run.returncode,'elapsed':time.time()-started,'logSHA':sha(folder/'compile.log')};receipt['commands'].append(row)
  assert run.returncode==0,(name,'compile failed: inspect protected compile.log')
  assert all(x.is_file() for x in object_files)
  data=b''.join(x.read_bytes() for x in object_files);symbols=subprocess.check_output(['/usr/bin/nm','-j',*[str(x) for x in object_files]]);symbols=b'\n'.join(line for line in symbols.splitlines() if line.startswith(b'_'));(folder/'symbols.txt').write_bytes(symbols)
  marks=[b'--synthetic-trial-check',b'--synthetic-writer-check',b'--synthetic-writer-restart-check',b'--recording-trial',b'--functional-trial',b'--signed-writer-acceptance',b'--isolated-interactive-trial',b'Open synthetic preview',b'Synthetic preview',b'Back to recording trial','Signed writer acceptance · Recording OFF'.encode('utf-8')]
  row.update(objects={str(x):sha(x) for x in object_files},moduleSHA=sha(folder/'MacMemApp.swiftmodule'),symbolSHA=sha(folder/'symbols.txt'),routeMarkers={x.decode('utf-8'):x in data for x in marks},legacyTypeSymbols={x:x.encode() in symbols for x in ['PackagedTrial','PackagedHistoryChecks','RecordingTrialReadiness','RecordingTrialProof','SignedWriterTrial','SyntheticWindow']},packagingTypeRawMarkers={x:x.encode() in data for x in ['PackagedTrial','RecordingTrialReadiness','SignedWriterTrial','CaptureFixtureTrial','CaptureChromeAutomationRequestUI']})
  assert all(found==qa for found in row['routeMarkers'].values()),(name,'route marker mismatch')
  # RecordingTrialProof is dead and unused even in QA; reject it normal, no fabricated QA-presence claim.
  assert all(found==qa for key,found in row['legacyTypeSymbols'].items() if key!='RecordingTrialProof'),(name,'type symbol mismatch')
  if not qa:assert not row['legacyTypeSymbols']['RecordingTrialProof']
finally:
 receipt['changedInputs']=[x for x,h in pins.items() if not Path(x).is_file() or sha(x)!=h]
 receipt['outputs']={str(x):sha(x) for x in out.rglob('*') if x.is_file() and x.name!='receipt.json'}
 (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 assert not receipt['changedInputs']
print(json.dumps({'out':str(out),'receiptSHA':sha(out/'receipt.json'),'compiles':[x['returncode'] for x in receipt['commands']],'changedInputs':receipt['changedInputs']}))
