"""Cached local dev build/publish-to-disk only; never SSH, install or Developer ID."""
from pathlib import Path
import datetime,hashlib,json,plistlib,subprocess,tempfile,time
root=Path(__file__).resolve().parents[1]
cache=Path('/private/tmp/daydream-development-1924-build')
start=time.monotonic()
subprocess.run(['swift','build','--scratch-path',str(cache),'--product','MacMem'],cwd=root,check=True)
seconds=time.monotonic()-start
version=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d-%H%M%S')
stage=Path(tempfile.mkdtemp(prefix='daydream-development-trial-loop-',dir='/private/tmp'))
app=stage/'Daydream Dev.app'
base=root/'dist/Daydream-Development-Trial-20260913-1937-ADHOC.zip'
assert hashlib.sha256(base.read_bytes()).hexdigest()=='811c496624ec67ae9a838dc018998473051df62d19e43959b64671d8242480ba'
subprocess.run(['ditto','-x','-k',str(base),str(stage/'base')],check=True)
subprocess.run(['ditto',str(stage/'base/Daydream Development Trial/Daydream Development Trial.app'),str(app)],check=True)
subprocess.run(['install','-m','755',str(cache/'arm64-apple-macosx/debug/MacMem'),str(app/'Contents/MacOS/MacMem')],check=True)
info_path=app/'Contents/Info.plist';info=plistlib.loads(info_path.read_bytes())
subprocess.run(['ditto',str(cache/'arm64-apple-macosx/debug/MacMem_MemoryUI.bundle'),str(app/'Contents/Resources/MacMem_MemoryUI.bundle')],check=True)
info.update(CFBundleName='DayDream Dev',CFBundleDisplayName='DayDream Dev',CFBundleIdentifier='com.getnorthlight.daydream.development',DaydreamDevelopmentTrial=True)
info_path.write_bytes(plistlib.dumps(info))
# Refresh artwork from source, not the historical trial seed. Do this before
# sealing so strict bundle verification covers the icon actually shipped.
icon=root/'packaging/Daydream.icns'
assert info.get('CFBundleIconFile') in ('Daydream','Daydream.icns')
assert icon.read_bytes()[:4]==b'icns'
subprocess.run(['install','-m','644',str(icon),str(app/'Contents/Resources/Daydream.icns')],check=True)
subprocess.run(['bash',str(root/'scripts/seal-local-app.sh'),str(app)],check=True)
out=root/'dist/dev-loop';out.mkdir(exist_ok=True)
archive=out/('Daydream-Dev-'+version+'.zip');assert not archive.exists()
subprocess.run(['ditto','-c','-k','--keepParent',str(app),str(archive)],check=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
subprocess.run(['ditto','-x','-k',str(archive),str(stage/'verify')],check=True)
extracted=stage/'verify/Daydream Dev.app'
subprocess.run(['codesign','--verify','--deep','--strict',str(extracted)],check=True)
assert sha(extracted/'Contents/MacOS/MacMem')==sha(app/'Contents/MacOS/MacMem')
assert sha(extracted/'Contents/Resources/Daydream.icns')==sha(icon)
receipt={'version':version,'archiveSHA256':sha(archive),'executableSHA256':sha(app/'Contents/MacOS/MacMem'),'iconSHA256':sha(icon),'bundleIdentifier':info['CFBundleIdentifier'],'incrementalBuildSeconds':seconds,'signature':'ad-hoc only','app':str(app)}
(out/(version+'-inputs.json')).write_text(json.dumps({str(p.relative_to(root)):sha(p) for p in [*sorted((root/'Sources/MacMemApp').glob('*.swift')),root/'scripts/build-dev-loop.py',root/'scripts/daydream-dev-refresh.command',icon,root/'packaging/Daydream-transparent.png']},indent=2)+'\n')
(out/(version+'.plist')).write_bytes(plistlib.dumps(receipt))
temporary=out/('latest-'+version+'.tmp');temporary.write_bytes(plistlib.dumps(receipt));temporary.replace(out/'latest.plist')
print(json.dumps(receipt,indent=2));print('Archive:',archive)
