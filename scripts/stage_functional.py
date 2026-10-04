"""Frozen NORMAL app augmentation only; no build, signing, launch or install.

Private same-owner self-use requires explicit --private-self-use. This does not
grant third-party distribution rights or claim complete corresponding source.
"""
import argparse
import json
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path
import functional_payload as payload
import functional_trial as trial
import release

def stage(args):
    trial.require(args.private_self_use, 'Only explicit private same-owner self-use supported; no third-party distribution')
    trial.normal(args.app)
    trial.require(trial.inventory(args.app) == json.loads(args.freeze.read_text()), 'Root final NORMAL app freeze mismatch')
    trial.require(trial.digest(args.writer_manifest) == payload.MANIFEST_HASH, 'Wrong enrolled manifest')
    data = json.loads(args.writer_manifest.read_text())
    trial.require(set(p.name for p in args.writer.iterdir()) == {r['name'] for r in data['files']}, 'Unexpected writer files')
    for row in data['files']:
        path = trial.regular(args.writer/row['name'])
        trial.require(path.stat().st_size == row['signedBytes'] and trial.digest(path) == row['signedSHA256'], 'Signed writer drift')
        subprocess.run(['/usr/bin/codesign','--verify','--strict',str(path)], check=True)
    trial.require(trial.digest(trial.regular(args.server, True)) == trial.SERVER_HASH, 'Wrong Typesense binary')
    trial.require(trial.digest(trial.regular(args.writer_license)) == '94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d', 'Wrong writer license')
    for p in (args.typesense_license, args.typesense_notices): trial.regular(p)
    trial.require('GNU GENERAL PUBLIC LICENSE' in args.typesense_license.read_text(), 'Missing GPL text')
    trial.require(not (args.app/'Contents'/payload.SERVER).exists() and not (args.app/'Contents/Frameworks/WriterRuntime').exists(), 'Base already augmented')
    destination = Path(tempfile.mkdtemp(prefix='daydream-functionalTrial-',dir='/private/tmp'))
    app = destination/'DayDream.app'
    subprocess.run(['/usr/bin/ditto',str(args.app),str(app)],check=True)
    trial.require(trial.inventory(app) == trial.inventory(args.app), 'Copy drift')
    c = app/'Contents'
    seal = c/'_CodeSignature'
    if seal.exists():
        trial.require(not seal.is_symlink(), 'Unsafe seal')
        shutil.rmtree(seal)  # Only this new copy, obsolete outer seal, never original/nested.
    (c/payload.LIBROOT).mkdir(parents=True)
    for row in data['files']: shutil.copy2(args.writer/row['name'], c/payload.LIBROOT/row['name'])
    (c/payload.MANIFEST).parent.mkdir(parents=True)
    (c/'Helpers').mkdir(exist_ok=True)
    for src, name in ((args.writer_manifest,payload.MANIFEST),(args.server,payload.SERVER),
                      (args.writer_license,'Resources/WriterRuntime-LICENSE.txt'),
                      (args.typesense_license,'Resources/Typesense-LICENSE.txt'),
                      (args.typesense_notices,'Resources/Typesense-NOTICES.txt')):
        shutil.copy2(src,c/name)
    info = plistlib.loads((c/'Info.plist').read_bytes())
    info['LSMinimumSystemVersion']='15.0'
    # App owner must already bind distribution ID in frozen normal source/plist.
    (c/'Info.plist').write_bytes(plistlib.dumps(info))
    (c/'Resources/FunctionalTrial.json').write_text(json.dumps({'schema':1,'scope':'private-same-owner-self-use',
        'publicDistribution':False,'completeCorrespondingSource':False,'writerManifestSHA256':payload.MANIFEST_HASH})+'\n')
    release.manifest(app)
    release.audit(app)
    payload.verify_search(app)
    (destination/'assembly-receipt.json').write_text(json.dumps({'originalInventory':trial.inventory(args.app),
        'preparedInventory':trial.inventory(app),'status':'UNSEALED; ROOT SIGNING/TRUST REQUIRED'},indent=2)+'\n')
    print(app)

if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('app','freeze','writer','writer-manifest','server','writer-license','typesense-license','typesense-notices'):
        p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--private-self-use',action='store_true')
    stage(p.parse_args())
