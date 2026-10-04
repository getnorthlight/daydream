"""Explicit separate development launch through macOS, never a trust bypass."""
import argparse, hashlib, os, plistlib, subprocess, tempfile
from pathlib import Path

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--app',required=True,type=Path)
    p.add_argument('--executable-sha256',required=True)
    p.add_argument('--resume',type=Path)
    p.add_argument('--prepare-only',action='store_true')
    args=p.parse_args();app=args.app.absolute()
    if not str(app).startswith('/private/tmp/daydream-development-trial-') or app.is_symlink():
        raise SystemExit('Use only the exact separately approved development app path.')
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    if info.get('DaydreamDevelopmentTrial') is not True:raise SystemExit('Not a development-only app. No launch.')
    binary=app/'Contents/MacOS/MacMem'
    if hashlib.sha256(binary.read_bytes()).hexdigest()!=args.executable_sha256:raise SystemExit('Executable pin mismatch')
    # All launch remains through LaunchServices. No direct executable, xattr,
    # ad-hoc signing, policy override or alternate launch on refusal.
    if not args.prepare_only:
        result=subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)])
        if result.returncode:raise SystemExit('Invalid signature. Root must prepare this exact development app: '+str(app))
    root=args.resume or Path(tempfile.mkdtemp(prefix='daydream-development-trial-',dir='/private/tmp'))
    if args.resume:
        if root.resolve()!=root or not str(root).startswith('/private/tmp/daydream-development-trial-') or (root/'DEVELOPMENT-ONLY').read_text()!='synthetic-only\n':raise SystemExit('Invalid trial root')
    else:
        root.chmod(0o700)
        for name in ['memory','preferences','backups']:(root/name).mkdir(mode=0o700)
        (root/'DEVELOPMENT-ONLY').write_text('synthetic-only\n')
    command=['/usr/bin/open','-n','--env','DAYDREAM_DEVELOPMENT_ROOT='+str(root),'--env','MAC_MEM_HOME='+str(root/'memory'),'--env','CFFIXED_USER_HOME='+str(root/'preferences'),str(app),'--args','--development-trial']
    print('Development app:',app);print('Synthetic trial root:',root);print('Backups:',root/'backups')
    if args.prepare_only:print('Prepared only. No application executed.');return
    result=subprocess.run(command)
    if result.returncode:raise SystemExit('macOS did not open '+str(app)+'. Ask for user-specific Open Anyway for this exact app; do not bypass Gatekeeper.')
    print('Launch requested through macOS, not proof of successful UI launch. If blocked, use only this app’s user-specific Open Anyway approval.')
if __name__=='__main__':main()
