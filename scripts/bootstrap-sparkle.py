"""Get the pinned Sparkle into Vendor/, or check the copy already there. Never installs an app or makes keys.

Usage: python3 scripts/bootstrap-sparkle.py [--offline]

packaging/sparkle.json pins two things:
  sha256            the official release archive (checked before anything is unpacked)
  inventory_sha256  every file and symlink in the unpacked folder (checked after unpacking,
                    and for a folder that is already there)

A Vendor/Sparkle-<version> folder that is already there is accepted when its files match
inventory_sha256, with or without the .bootstrap-sha256 stamp that scripts/bootstrap.sh
writes. When the stamp is missing, this script writes it, so bootstrap.sh accepts the
checked folder too. A folder whose files differ is refused: delete it and run this again.
--offline never uses the network.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

ROOT=Path(__file__).resolve().parents[1]
PIN=ROOT/'packaging/sparkle.json'
STAMP='.bootstrap-sha256'

def pin():
    return json.loads(PIN.read_text())

def target_for(value, root=ROOT):
    return root/'Vendor'/('Sparkle-'+value['version'])

def inventory_digest(folder):
    """SHA-256 over every file (by content) and symlink (by target) under folder, except the stamp."""
    folder=Path(folder)
    out={}
    for directory,dirs,files in os.walk(folder):
        for name in dirs+files:
            path=Path(directory)/name
            rel=str(path.relative_to(folder))
            if rel==STAMP:
                continue
            if path.is_symlink():
                out[rel]='link:'+os.readlink(path)
            elif path.is_file():
                out[rel]=hashlib.sha256(path.read_bytes()).hexdigest()
    return hashlib.sha256(json.dumps(out,sort_keys=True).encode()).hexdigest()

def folder_problems(folder, value):
    """Why an existing Vendor/Sparkle folder is not the pinned one ([] when it is)."""
    folder=Path(folder)
    if folder.is_symlink() or not folder.is_dir():
        return ['Vendor/%s is missing or not a real folder' % folder.name]
    problems=[]
    if inventory_digest(folder)!=value['inventory_sha256']:
        problems.append("Vendor/%s doesn't match the pinned file list in packaging/sparkle.json" % folder.name)
    stamp=folder/STAMP
    if stamp.exists() and stamp.read_text().strip()!=value['sha256']:
        problems.append('Vendor/%s/%s names a different archive' % (folder.name,STAMP))
    return problems

def check_folder(folder, value):
    problems=folder_problems(folder,value)
    if problems:
        raise SystemExit('; '.join(problems)+'. Delete that folder and run this script again.')
    stamp=Path(folder)/STAMP
    if not stamp.exists():
        # Same content as the pinned archive, so the stamp bootstrap.sh looks for is true.
        stamp.write_text(value['sha256']+'\n')

def unpack(archive, target, value):
    with zipfile.ZipFile(archive) as z:
        if any(Path(n).is_absolute() or '..' in Path(n).parts for n in z.namelist()):
            raise SystemExit('Unsafe archive path')
    target.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='sparkle-',dir=target.parent) as temp:
        stage=Path(temp)/'payload'
        subprocess.run(['ditto','-x','-k',str(archive),str(stage)],check=True)
        if inventory_digest(stage)!=value['inventory_sha256']:
            raise SystemExit("The unpacked archive doesn't match the pinned file list. Nothing was installed.")
        (stage/STAMP).write_text(value['sha256']+'\n')
        stage.rename(target)

def main(argv=None):
    argv=sys.argv[1:] if argv is None else argv
    offline='--offline' in argv
    value=pin()
    target=target_for(value)
    if target.exists() or target.is_symlink():
        check_folder(target,value)
    else:
        archive=ROOT/'.build/dependencies'/('Sparkle-'+value['version']+'.zip')
        archive.parent.mkdir(parents=True,exist_ok=True)
        if not archive.exists():
            if offline:
                raise SystemExit('--offline and no archive at .build/dependencies/%s' % archive.name)
            subprocess.run(['curl','--fail','--location','--proto','=https','--max-time','120','--silent','--show-error','--output',str(archive),value['url']],check=True)
        if hashlib.sha256(archive.read_bytes()).hexdigest()!=value['sha256']:
            raise SystemExit('Sparkle archive checksum mismatch. No extraction performed.')
        unpack(archive,target,value)
    framework=target/'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
    subprocess.run(['codesign','--verify','--deep','--strict',str(framework)],check=True)
    print('Verified Sparkle '+value['version']+' in Vendor/ (pinned file list). No installation or signing changes.')

if __name__=='__main__': main()
