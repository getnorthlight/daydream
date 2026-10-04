import hashlib,json,os,pathlib,plistlib,subprocess,tempfile
P=pathlib.Path
source=P(__file__).resolve().parents[1]
artifact=source/'dist/Daydream-OFF-Trial-20260913-0221.dmg'
expected='e5c121b3338cc14386b5ef613989068e2a7875315e88255d7006b8352b71b34e'
root=P(tempfile.mkdtemp(prefix='daydream-trial-independent-',dir='/private/tmp'))
report={'artifact':str(artifact),'sha256':hashlib.sha256(artifact.read_bytes()).hexdigest(),'root':str(root),'checks':{}}
assert report['sha256']==expected
env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','TMPDIR':str(root),'CFFIXED_USER_HOME':str(root/'user'),'MAC_MEM_HOME':str(root/'memory')}
(root/'user').mkdir();(root/'memory').mkdir();(root/'memory/TRIAL-ONLY').write_text('synthetic-only\n')
def run(name,args,input=None,allowed=(0,),timeout=40):
    p=subprocess.run([str(x) for x in args],input=input,text=True,capture_output=True,env=env,timeout=timeout)
    report['checks'][name]={'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
    (root/'receipt.json').write_text(json.dumps(report,indent=2))
    print(name,p.returncode,flush=True)
    assert p.returncode in allowed,(name,p.stderr)
    return p.stdout
mount=root/'mounted';mount.mkdir()
try:
    manifest=json.loads((source/'dist/Daydream-OFF-Trial-20260913-0221-source.json').read_text())
    report['source_mismatches']=[n for n,h in manifest.items() if not (source/n).is_file() or hashlib.sha256((source/n).read_bytes()).hexdigest()!=h]
    run('image_verify',['hdiutil','verify',artifact])
    run('mount',['hdiutil','attach','-readonly','-nobrowse','-mountpoint',mount,artifact])
    report['layout']=sorted(x.name for x in mount.iterdir())
    assert (mount/'Applications').is_symlink() and os.readlink(mount/'Applications')=='/Applications'
    run('extract',['ditto',mount/'DayDream.app',root/'DayDream.app'])
    run('unmount',['hdiutil','detach',mount])
    app=root/'DayDream.app';contents=app/'Contents';binary=contents/'MacOS'
    run('signature',['codesign','--verify','--deep','--strict','--verbose=2',app])
    run('signature_identity',['codesign','-d','--verbose=4',app])
    run('companions',['/usr/bin/python3',source/'scripts/verify-app-companions.py',app])
    info=plistlib.loads((contents/'Info.plist').read_bytes());report['info']=info
    assert not info.get('SUFeedURL') and not info.get('SUEnableAutomaticChecks',False)
    report['inventory']={str(p.relative_to(contents)):hashlib.sha256(p.read_bytes()).hexdigest() for p in binary.iterdir() if p.is_file()}
    for p in binary.iterdir():
        if p.is_file():
            linked=run('linkage_'+p.name,['otool','-L',p]);run('rpaths_'+p.name,['otool','-l',p])
            assert not any('/private/tmp/' in line or '/Users/' in line for line in linked.splitlines()[1:])
    cli=binary/'mac-mem';base=[cli,'--home',root/'memory','--local']
    run('version',[cli,'version'])
    run('seed',base+['demo'])
    for i in (1,2):
        receipt=root/'memory/trial-receipt.json'
        if receipt.exists(): receipt.unlink()
        run('launch_'+str(i),[binary/'MacMem','--synthetic-trial-check'],timeout=45)
        result=json.loads(receipt.read_text());report['checks']['app_'+str(i)]=result
        assert result['passed'],result
        status=json.loads(run('status_'+str(i),base+['status']))
        assert status['capture']=='off' and status.get('cloud') in ('unknown','off')
    found=json.loads(run('search',base+['search','Swift']));assert found
    run('drilldown',base+['read',found[0]['id']])
    mcp=json.loads(run('mcp',base+['mcp'],json.dumps({'jsonrpc':'2.0','id':1,'method':'initialize','params':{}})+'\n'))
    assert mcp['result']['serverInfo']['name']=='Daydream'
    backup=json.loads(run('backup_export',[binary/'mac-mem-backup'],json.dumps({'operation':'export','source':str(root/'memory'),'destination':str(root/'synthetic.backup'),'build':'1','version':'0.1.0'})))
    assert backup['manifest']['audit']['capture']=='off'
    run('gatekeeper',['spctl','--assess','--type','execute','--verbose=2',app],allowed=(0,3))
    report['completed']=True
finally:
    (root/'receipt.json').write_text(json.dumps(report,indent=2))
    print('RECEIPT',root/'receipt.json',flush=True)
