"""Read-only presentation/compatibility regression; no app launch or store access."""
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
def read(path):
    return (root / path).read_text()

app = read('Sources/MacMemApp/MacMemApp.swift')
# The memory scene's title ternary: Development Trial, Isolated preview, else plain "DayDream" (plan §5 I1).
# summaries line: the DayDream Preview bundle's own name comes first, only when session.preview (a preview launch).
assert re.search(r'WindowGroup\(\s*session\.preview\s*\?.*?"DayDream Preview"\s*:\s*session\.development\s*\?\s*"DayDream · Development Trial"\s*:\s*session\.isolated\s*\?\s*"DayDream · Isolated preview"\s*:\s*"DayDream"\s*,\s*id:\s*"memory"\s*\)', app)
# The menu bar extra is A4's panel with the mark-A label (amendments I1); Quit lives in the panel, the brand in the label's VoiceOver text.
assert 'MenuBarExtra {' in app and 'DaydreamMenuBarLabel(model:' in app and '.menuBarExtraStyle(.window)' in app
assert 'title: "Quit DayDream"' in read('Sources/MemoryUI/MenuBarMenu.swift')
assert 'return "DayDream: " + title' in read('Sources/MemoryUI/DaydreamCaptureState.swift')
cli = read('Sources/MacMemCLI/main.swift')
assert '"serverInfo":["name":"DayDream"' in cli
assert 'mac-mem [--home DIR]' in cli
assert 'macmem://' in cli
# Rename (sat/v1, docs/rename.md): user-visible names are DayDream. The old "Mac Mem" folder, bundle ID and
# Keychain service are named only in DaydreamIdentity (to find and move an older install) and the model cache.
identity = read('Sources/MemoryCore/DaydreamIdentity.swift')
assert 'bundleID = "com.getnorthlight.daydream"' in identity and 'legacyBundleID = "com.macmem.app"' in identity
assert 'dataFolder = "DayDream"' in identity and 'legacyDataFolder = "Mac Mem"' in identity
assert 'DaydreamIdentity.dataFolder' in read('Sources/MemoryCore/Models.swift')
assert 'Library/Application Support/Mac Mem' not in read('Sources/MemoryCore/Models.swift')
assert 'DaydreamIdentity.dataFolder' in read('Sources/MacMemApp/WriterIntegration.swift')
assert 'service = "DayDream.Writer.OpenRouter"' in read('WriterBackend/Sources/WriterBackend/CloudTransport.swift')
import plistlib
info = plistlib.loads((root / 'packaging/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'com.getnorthlight.daydream', info['CFBundleIdentifier']
assert info.get('CFBundleName', 'DayDream') == 'DayDream' and info.get('CFBundleDisplayName', 'DayDream') == 'DayDream'
# The release image is on the volume 'DayDream'; a test build's own volume name (dmg --volume-name, golden test 5)
# still starts with 'DayDream '.
assert "RELEASE_VOLUME_NAME = 'DayDream'" in read('scripts/developer-id-release.py')
assert "'-volname', volume," in read('scripts/developer-id-release.py')
assert "VOLUME_NAME_RE = r'DayDream(?: " in read('scripts/developer-id-release.py')
assert "APP_NAME = 'DayDream.app'" in read('scripts/developer-id-release.py')
assert 'Stop automatic notes for this session' not in read('Sources/MacMemApp/WriterPreferences.swift')
assert read('README.md').startswith('# DayDream\n')
# Dropped (amendments I1): docs/DAYDREAM-SETUP.md exists on no branch (`git log --all -- docs/` is empty), so the
# former assertion that it starts with '# DayDream setup' could never pass.
for folder in ['Sources/MemoryUI', 'Sources/MacMemApp', 'Sources/MacMemCLI', 'UIRender']:  # no old names at all
    for path in (root / folder).glob('*.swift'):
        for line in path.read_text().splitlines():
            if line.lstrip().startswith('//'):
                continue  # comments may explain the rename; code and strings may not use the old names
            if 'Mac Mem' in line or 'com.macmem.app' in line or 'MacMem.Writer.OpenRouter' in line:
                raise AssertionError((path, line))
for path in (root / 'Sources/MemoryCore').glob('*.swift'):
    if path.name == 'DaydreamIdentity.swift':
        continue
    for line in path.read_text().splitlines():
        if 'Mac Mem' in line and not line.lstrip().startswith('///') and not line.lstrip().startswith('//'):
            raise AssertionError((path, line))
        assert 'com.macmem.app' not in line, (path, line)
print('PASS DayDream display names, DayDream data folder/bundle ID/Keychain service, compatibility routes, persistent-OFF wording')
