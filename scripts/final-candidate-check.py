"""Actual extracted app/CLI/helpers acceptance in marked synthetic homes only."""
import argparse,hashlib,json,os,subprocess,tempfile
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('dmg',type=Path);parser.add_argument('sha256');parser.add_argument('writer_preparer',type=Path)
args=parser.parse_args();project=Path(__file__).resolve().parents[1]
root=Path(tempfile.mkdtemp(prefix='daydream-trial-final-',dir='/private/tmp'))
report={'artifact':str(args.dmg),'sha256':hashlib.sha256(args.dmg.read_bytes()).hexdigest(),'root':str(root),'checks':{}}
assert report['sha256']==args.sha256
env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','TMPDIR':str(root),'CFFIXED_USER_HOME':str(root/'user'),'MAC_MEM_HOME':str(root/'memory')}
for name in ['user','memory','writer-memory']:(root/name).mkdir()
for name in ['memory','writer-memory']:(root/name/'TRIAL-ONLY').write_text('synthetic-only\n')
def save():(root/'receipt.json').write_text(json.dumps(report,indent=2))
def run(name,argv,expected=0,timeout=60,environment=None,stdin=None):
    p=subprocess.run([str(x) for x in argv],env=environment or env,cwd=project,input=stdin,text=True,capture_output=True,timeout=timeout)
    (root/(name+'.log')).write_text(p.stdout+p.stderr)
    report['checks'][name]={'exit':p.returncode,'log':str(root/(name+'.log'))};save()
    assert p.returncode==expected,(name,p.stderr[-1000:]);print('PASS '+name,flush=True);return p.stdout
mount=root/'mount';mount.mkdir();mounted=False
try:
    run('image',['hdiutil','verify',args.dmg]);run('mount',['hdiutil','attach','-readonly','-nobrowse','-mountpoint',mount,args.dmg]);mounted=True
    run('extract',['ditto',mount/'DayDream.app',root/'DayDream.app']);run('detach',['hdiutil','detach',mount]);mounted=False
    app=root/'DayDream.app';binary=app/'Contents/MacOS';cli=binary/'mac-mem'
    report['executionGate']='pending';save()
    try:
        run('outer-seal',['/usr/bin/codesign','--verify','--deep','--strict',app])
        run('distribution-trust',['/usr/sbin/spctl','--assess','--type','execute','--verbose=4',app])
    except Exception:
        report['executionGate']='blocked';report['packagedBehavior']='NOT TESTED';save()
        raise
    report['executionGate']='accepted';save()
    signature=run('identity',['codesign','-d','--verbose=4',app]) # identity emitted to log stderr
    assert 'Signature=adhoc' in (root/'identity.log').read_text(),'Upstream writer fixture forbidden in non-ad-hoc app'
    run('companions',['/usr/bin/python3','-B',project/'scripts/verify-app-companions.py',app])
    run('demo',[cli,'--home',root/'memory','--local','demo'])
    for n in [1,2]:
        run('app-'+str(n),[binary/'MacMem','--synthetic-trial-check'],timeout=90)
        result=json.loads((root/'memory/trial-receipt.json').read_text());report['checks']['ui-'+str(n)]=result;save();assert result['passed'],result
    run('writer-assets',[args.writer_preparer,root/'writer-memory','/private/tmp/macmem-qwen-trial.bFHQFN/model.gguf','/private/tmp/macmem-qwen-trial.bFHQFN/runtime.tar.gz'])
    writer_env={**env,'MAC_MEM_HOME':str(root/'writer-memory')}
    for flag,file in [('synthetic-writer-check','writer-receipt.json'),('synthetic-writer-restart-check','writer-restart-receipt.json')]:
        run(flag,[binary/'MacMem','--'+flag],environment=writer_env,timeout=150)
        result=json.loads((root/'writer-memory'/file).read_text());report['checks'][flag+'-result']=result;save();assert result['passed'],result
    result=json.loads(run('mcp',[cli,'--home',root/'memory','--local','mcp'],stdin=json.dumps({'jsonrpc':'2.0','id':1,'method':'initialize','params':{}})+'\n'))
    # Candidates built before the DayDream display-name change report 'Daydream'.
    assert result['result']['serverInfo']['name'] in ('DayDream','Daydream')
    run('final-seal',['codesign','--verify','--deep','--strict',app])
    report['completed']=True
finally:
    if mounted:subprocess.run(['hdiutil','detach',str(mount)],capture_output=True)
    save();print('RECEIPT '+str(root/'receipt.json'),flush=True)
