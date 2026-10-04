"""Minimal fixed, single-leaf Finder layout. No third-party dependencies.
Format references: sindresorhus/DSStore and dmgbuild/dmgbuild (see report).
Only writes metadata for this two-item image, not a general DS_Store editor.
"""
from pathlib import Path
import plistlib
import struct
import sys

root=Path(sys.argv[1]); alias=Path(sys.argv[2]).read_bytes()
u=lambda *n: struct.pack('>'+len(n)*'I',*n)
def record(name,key,kind,value):
    encoded=name.encode('utf-16be')
    return u(len(encoded)//2)+encoded+key.encode()+kind.encode()+value
def blob(name,key,data): return record(name,key,'blob',u(len(data))+data)
def plist(key,value): return blob('.',key,plistlib.dumps(value,fmt=plistlib.FMT_BINARY))
entries=[
    ('.','bwsp',plist('bwsp',dict(WindowBounds='{{200, 160}, {640, 400}}',ShowToolbar=False,ShowSidebar=False,ContainerShowSidebar=False,ShowStatusBar=False,ShowPathbar=False,ShowTabView=False,PreviewPaneVisibility=False,SidebarWidth=0))),
    ('.','icvp',plist('icvp',dict(viewOptionsVersion=1,backgroundType=2,backgroundImageAlias=alias,iconSize=128.0,textSize=14.0,gridSpacing=100.0,gridOffsetX=0.0,gridOffsetY=0.0,arrangeBy='none',showIconPreview=True,showItemInfo=False,labelOnBottom=True,scrollPositionX=0.0,scrollPositionY=0.0))),
    ('.','icvl',record('.','icvl','type',b'icnv')),
    ('.','vSrn',record('.','vSrn','long',u(1))),
]
for name,x in [('DayDream.app',170),('Applications',470)]:
    entries.append((name,'Iloc',blob(name,'Iloc',u(x,170,0xffffffff,0xffff0000))))
leaf=u(0,len(entries))+b''.join(e[2] for e in sorted(entries,key=lambda e:(e[0].lower(),e[1])))
assert len(leaf)<4096
# Reserved header [0,32), DSDB [32,64), leaf [4096,8192), allocator [8192,12288).
data=bytearray(12292)
data[:36]=u(1)+b'Bud1'+u(8192,4096,8192)+bytes(16)
data[36:56]=u(2,0,len(entries),1,4096)
data[4100:4100+len(leaf)]=leaf
allocator=u(3,0)+u(8192|12,32|5,4096|12)+bytes(253*4)+u(1)+b'\x04DSDB'+u(1)
for power in range(32):
    free=[1<<power] if 6<=power<12 else []
    allocator+=u(len(free))+u(*free)
assert len(allocator)<4096
data[8196:8196+len(allocator)]=allocator
(root/'.DS_Store').write_bytes(data)
print('Finder layout: 640×400; 128-point icons at (170,170) and (470,170)')
