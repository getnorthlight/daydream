"""Receipt only: source/config hashes, never memory or credentials."""
from pathlib import Path
import hashlib,json,sys
root=Path(__file__).resolve().parents[1]
entries={}
for folder in ['Sources','Checks','UIRender','packaging','scripts','adapters','BackupRestore/Native','BackupRestore/Worker','WriterBackend/Sources','WriterBackend/Notices','PrivacyPolicy/Sources','BrowserBridge/Sources']:
    for p in sorted((root/folder).rglob('*')):
        if p.is_file() and not p.is_symlink() and '__pycache__' not in p.parts:
            entries[str(p.relative_to(root))]=hashlib.sha256(p.read_bytes()).hexdigest()
for name in ['Package.swift','WriterBackend/Package.swift','PrivacyPolicy/Package.swift','BrowserBridge/Package.swift','LICENSE','NOTICE','THIRD-PARTY-NOTICES.md','WriterBackend/PROVENANCE.md']:
    entries[name]=hashlib.sha256((root/name).read_bytes()).hexdigest()
encoded=json.dumps(entries,sort_keys=True,indent=2)+'\n'
target=root/'dist'/sys.argv[1]
assert target.parent==root/'dist' and not target.exists()
target.write_text(encoded)
print(hashlib.sha256(encoded.encode()).hexdigest(),target)
