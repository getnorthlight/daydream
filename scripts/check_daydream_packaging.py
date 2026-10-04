"""Source-only packaging regression checks. No app launch or build claim."""
import hashlib
from pathlib import Path
import plistlib
import struct
import unittest

ROOT = Path(__file__).resolve().parents[1]

class BrandingChecks(unittest.TestCase):
    def test_identity(self):
        info = plistlib.loads((ROOT/'packaging/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'com.getnorthlight.daydream')
        self.assertEqual(info['CFBundleExecutable'], 'MacMem')
        self.assertEqual(info['CFBundleDisplayName'], 'DayDream')
        self.assertEqual(info['CFBundleIconFile'], 'Daydream')
        self.assertFalse(info['SUEnableAutomaticChecks'])
        self.assertFalse(info['SUAutomaticallyUpdate'])
        self.assertNotIn('SUFeedURL', info)

    def test_exact_artwork_and_sizes(self):
        self.assertEqual(hashlib.sha256((ROOT/'packaging/Daydream-source.png').read_bytes()).hexdigest(),
                         '9b28b6b7b7690106f1ec85f9c5a742ed64fe212a8a1ca4a90a63d9b66deb2060')
        for size in [16,32,128,256,512]:
            for scale in [1,2]:
                suffix = '@2x' if scale == 2 else ''
                data = (ROOT/f'packaging/Daydream.iconset/icon_{size}x{size}{suffix}.png').read_bytes()
                self.assertEqual(struct.unpack('>II',data[16:24]), (size*scale,size*scale))
        self.assertEqual((ROOT/'packaging/Daydream.icns').read_bytes()[:4], b'icns')

    def test_helper_and_seal_order(self):
        source = (ROOT/'scripts/package.sh').read_text()
        self.assertIn('--product mac-mem-backup', source)
        self.assertIn('$app/Contents/MacOS/mac-mem-backup', source)
        self.assertLess(source.index('release.py manifest'), source.index('seal-local-app.sh'))
        self.assertLess(source.index('seal-local-app.sh'), source.index('hdiutil create'))
        self.assertIn('verify-dmg-seal.sh', source)
        self.assertIn('DayDream.app', source)
        seal = (ROOT/'scripts/seal-local-app.sh').read_text()
        self.assertIn('--sign - --timestamp=none', seal)
        self.assertNotIn('--deep --sign', seal)

    def test_layout(self):
        source = (ROOT/'scripts/dmg-layout.py').read_text()
        self.assertIn("('DayDream.app',170),('Applications',470)", source)
        self.assertIn('Drag DayDream to Applications', (ROOT/'scripts/dmg-background.swift').read_text())

if __name__ == '__main__':
    unittest.main()
