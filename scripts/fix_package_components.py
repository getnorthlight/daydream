"""Keep every pkg component in its staged path, especially embedded Sparkle helpers."""
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
components = plistlib.loads(path.read_bytes())
def fixed(component):
    component["BundleIsRelocatable"] = False
    for child in component.get("ChildBundles", []):
        fixed(child)
for component in components:
    fixed(component)
path.write_bytes(plistlib.dumps(components))
