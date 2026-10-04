"""Read-only DMG layout checks. Mounts images read-only; never launches or installs.

Two-image mode (package.sh/polish-dmg.sh flow, default):
    check_dmg_layout.py [UNSIGNED.dmg LAYOUT.dmg]        names under dist/
Single-image mode (developer-id-release.py flow: layout happens before signing, so there
is no separate unsigned image; the reference is the signed/stapled app):
    check_dmg_layout.py --app SIGNED/DayDream.app PATH/Daydream-x.dmg
"""
from pathlib import Path
import hashlib, os, plistlib, struct, subprocess, tempfile, sys
ROOT=Path(__file__).resolve().parents[1]
def run(*args): return subprocess.run(args,check=True,capture_output=True,text=True).stdout
def inventory(app):
    return {str(p.relative_to(app)):('link',os.readlink(p)) if p.is_symlink() else ('file',hashlib.sha256(p.read_bytes()).hexdigest()) for p in app.rglob('*') if p.is_symlink() or p.is_file()}
def entries(data):
    offset=4100
    _,count=struct.unpack_from('>II',data,offset); offset+=8
    out={}
    for _ in range(count):
        size=struct.unpack_from('>I',data,offset)[0]; offset+=4
        name=data[offset:offset+size*2].decode('utf-16be'); offset+=size*2
        code=data[offset:offset+4].decode(); kind=data[offset+4:offset+8]; offset+=8
        if kind==b'blob':
            length=struct.unpack_from('>I',data,offset)[0]; offset+=4
            value=data[offset:offset+length]; offset+=length
        else: value=data[offset:offset+4]; offset+=4
        out[name,code]=value
    return out
def check_items(mount):
    assert {p.name for p in mount.iterdir() if not p.name.startswith('.')}=={'DayDream.app','Applications'}
    assert os.readlink(mount/'Applications')=='/Applications'
def check_layout(mount):
    e=entries((mount/'.DS_Store').read_bytes())
    p=plistlib.loads(e['.','icvp']); bounds=plistlib.loads(e['.','bwsp'])
    assert p['iconSize']==128 and p['arrangeBy']=='none'
    assert not bounds['ShowToolbar'] and not bounds['ShowSidebar']
    assert bounds['WindowBounds']=='{{200, 160}, {640, 400}}'
    assert struct.unpack('>IIII',e['DayDream.app','Iloc'])[:2]==(170,170)
    assert struct.unpack('>IIII',e['Applications','Iloc'])[:2]==(470,170)
    assert e['.','icvl']==b'icnv'
    assert p['backgroundType']==2 and p['backgroundImageAlias']
    assert (mount/'.background.tiff').is_file()
def check_volume(mount):
    """Visible items and Finder layout of one mounted final image."""
    check_items(mount); check_layout(mount)
def two_image(names):
    with tempfile.TemporaryDirectory(prefix='macmem-layout-check-') as folder:
        mount=Path(folder)/'mount'; mount.mkdir()
        inventories=[]
        assert len(names)==2 and all(Path(n).name==n and n.endswith('.dmg') for n in names)
        for name in names:
            artifact=ROOT/'dist'/name
            run('hdiutil','verify',str(artifact))
            run('hdiutil','attach','-readonly','-nobrowse','-mountpoint',str(mount),str(artifact))
            try:
                inventories.append(inventory(mount/'DayDream.app'))
                check_items(mount)
                if 'layout' in name: check_layout(mount)
            finally: run('hdiutil','detach',str(mount))
            print(name,hashlib.sha256(artifact.read_bytes()).hexdigest())
        assert inventories[0]==inventories[1]
        print('PASS: every app file and symlink unchanged; CLI/MCP/Sparkle payload identical')
        print('PASS: image visible items, icon coordinates, sizes, view, window bounds and hidden background')
def single_image(app, artifact):
    assert app.name=='DayDream.app' and artifact.name.endswith('.dmg')
    with tempfile.TemporaryDirectory(prefix='macmem-layout-check-') as folder:
        mount=Path(folder)/'mount'; mount.mkdir()
        run('hdiutil','verify',str(artifact))
        run('hdiutil','attach','-readonly','-nobrowse','-mountpoint',str(mount),str(artifact))
        try:
            check_volume(mount)
            assert inventory(mount/'DayDream.app')==inventory(app), 'app in image differs from reference app'
        finally: run('hdiutil','detach',str(mount))
    print(artifact.name,hashlib.sha256(artifact.read_bytes()).hexdigest())
    print('PASS: app in image is byte-identical to the reference app (files and symlinks)')
    print('PASS: image visible items, icon coordinates, sizes, view, window bounds and hidden background')
if __name__=='__main__':
    args=sys.argv[1:]
    if args[:1]==['--app']:
        assert len(args)==3, 'usage: check_dmg_layout.py --app DayDream.app PATH.dmg'
        single_image(Path(args[1]).absolute(),Path(args[2]).absolute())
    else:
        two_image(args or ['Daydream-GUI-Trial-unsigned.dmg','Daydream-GUI-Trial-layout-unsigned.dmg'])
