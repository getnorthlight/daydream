"""Local release helpers: the update key, the update settings, the companion manifest and
the Sparkle update archive + appcast. Never publishes, pushes or creates GitHub releases.

  make-key        make the EdDSA update key ONCE, as a file: ~/DayDream-keys/sparkle-ed25519.key
                  (folder chmod 700, file chmod 600). Never the Keychain. Prints the public key.
  public-key      print the public key of a key file
  set-public-key  write that public key into packaging/updates.json (commit it afterwards)
  validate        check packaging/updates.json (the site's appcast feed, real names, the key if set)
  manifest        write Contents/Resources/Companions.json for an app
  prepare         from a signed, notarized, stapled DayDream.app: DayDream-<version>.zip and a
                  signed appcast.xml, signed with --ed-key-file only. Nothing is uploaded.
  appcast         the same from a signed, notarized DayDream-<version>.dmg (or a .zip of the stapled
                  app), with plain-text release notes. Nothing is uploaded or published.

Sparkle's own generate_keys always stores the private key in the login Keychain, so the key
is made here instead: 32 random bytes from the OS (the Ed25519 seed), saved base64-encoded.
That is the key-file format Sparkle's generate_appcast/sign_update --ed-key-file read.
"""
import argparse
import base64
import hashlib
import json
import os
import plistlib
import re
import secrets
import shutil
import stat
import subprocess
from pathlib import Path
import xml.etree.ElementTree as ET
import functional_payload
import search_payload
import writer_payload

ROOT = Path(__file__).resolve().parents[1]
UPDATES_JSON = ROOT / "packaging/updates.json"
KEY_DIR = Path.home() / "DayDream-keys"
KEY_NAME = "sparkle-ed25519.key"
KEY_FILE = KEY_DIR / KEY_NAME
SPARKLE_TOOLS = ROOT / "Vendor/Sparkle-2.9.6/bin"
PLACEHOLDERS = ("owner", "repo", "repository", "example", "placeholder", "replace", "todo", "your-", "your_", "changeme")
# Update check once a day. A found update downloads quietly and installs when DayDream quits, or at once when the
# person chooses Restart to Update; nothing interrupts them (SUAutomaticallyUpdate and SUAllowsAutomaticUpdates true;
# Sources/MemoryCore/UpdatePolicy.swift refuses a copy without them, Sources/MacMemApp/Updates.swift never pops a window).
CHECK_INTERVAL_SECONDS = 86400
APPCAST_NAME = "appcast.xml"
VERSION_RE = r"[0-9]+(?:\.[0-9]+){1,2}"
SPARKLE_NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"

def require(value, message):
    if not value:
        raise ValueError(message)

def apple_team_id():
    """The Apple Developer Team ID from packaging/signing.json, the one place it is set."""
    value = json.loads((ROOT / "packaging/signing.json").read_text()).get("apple_team_id", "")
    require(isinstance(value, str) and re.fullmatch(r"[A-Z0-9]{10}", value), "packaging/signing.json needs a 10-character apple_team_id")
    return value

# ---------------------------------------------------------------- Ed25519 public key (RFC 8032 5.1.5)
# Only derives the public key from a seed, locally. Signing is done by Sparkle's tools.
_P = 2 ** 255 - 19
_D = -121665 * pow(121666, _P - 2, _P) % _P
_SQRT_M1 = pow(2, (_P - 1) // 4, _P)

def _add(a, b):
    x = (a[1] - a[0]) * (b[1] - b[0]) % _P
    y = (a[1] + a[0]) * (b[1] + b[0]) % _P
    z = 2 * a[3] * b[3] * _D % _P
    w = 2 * a[2] * b[2] % _P
    e, f, g, h = y - x, w - z, w + z, y + x
    return (e * f, g * h, f * g, e * h)

def _base():
    y = 4 * pow(5, _P - 2, _P) % _P
    x2 = (y * y - 1) * pow(_D * y * y + 1, _P - 2, _P)
    x = pow(x2, (_P + 3) // 8, _P)
    if (x * x - x2) % _P:
        x = x * _SQRT_M1 % _P
    if x & 1:
        x = _P - x
    return (x, y, 1, x * y % _P)

def ed25519_public_key(seed):
    require(isinstance(seed, bytes) and len(seed) == 32, "An Ed25519 seed is 32 bytes")
    digest = hashlib.sha512(seed).digest()
    scalar = int.from_bytes(digest[:32], "little")
    scalar &= (1 << 254) - 8
    scalar |= 1 << 254
    point, result = _base(), (0, 1, 1, 0)
    while scalar:
        if scalar & 1:
            result = _add(result, point)
        point = _add(point, point)
        scalar >>= 1
    zinv = pow(result[2], _P - 2, _P)
    x, y = result[0] * zinv % _P, result[1] * zinv % _P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")

# ---------------------------------------------------------------- the update key file
def _inside(path, folder):
    try:
        return Path(path).resolve().is_relative_to(Path(folder).resolve())
    except OSError:
        return False

def key_location_problems(path):
    """Where the key may live: a plain file, never the Keychain, stdin or the repository."""
    text = str(path)
    problems = []
    if text == "-":
        problems.append("the key must be a file, not standard input")
    lowered = text.lower()
    if lowered.endswith((".keychain", ".keychain-db")) or _inside(path, Path.home() / "Library/Keychains") or "/keychains/" in lowered:
        problems.append("the update key never goes in a Keychain")
    if _inside(path, ROOT):
        problems.append("the update key never goes inside the repository")
    return problems

def key_file_problems(path):
    path = Path(path).expanduser()
    problems = key_location_problems(path)
    if problems:
        return problems
    if path.is_symlink() or not path.is_file():
        return ["no key file at %s (make it once with `release.py make-key`)" % path]
    info, folder = path.stat(), path.parent.stat()
    if info.st_uid != os.getuid():
        problems.append("the key file must belong to you")
    if stat.S_IMODE(info.st_mode) != 0o600:
        problems.append("the key file must be chmod 600 (it is %o)" % stat.S_IMODE(info.st_mode))
    if stat.S_IMODE(folder.st_mode) & 0o077:
        problems.append("the key folder must be chmod 700 (it is %o)" % stat.S_IMODE(folder.st_mode))
    try:
        seed = base64.b64decode(path.read_text().strip(), validate=True)
    except ValueError:
        seed = b""
    if len(seed) != 32:
        problems.append("the key file must hold one base64 Ed25519 seed (32 bytes)")
    return problems

def public_key_of(path):
    path = Path(path).expanduser()
    problems = key_file_problems(path)
    require(not problems, "Update key file refused: " + "; ".join(problems))
    return base64.b64encode(ed25519_public_key(base64.b64decode(path.read_text().strip()))).decode()

def make_key(directory=KEY_DIR, name=KEY_NAME):
    """Make the update key once. Refuses to overwrite: users of the old key could never update again."""
    directory = Path(directory).expanduser()
    path = directory / name
    problems = key_location_problems(path)
    require(not problems, "; ".join(problems))
    require(not directory.is_symlink(), "The key folder must not be a symlink")
    directory.mkdir(mode=0o700, parents=False, exist_ok=True)
    require(directory.stat().st_uid == os.getuid(), "The key folder must belong to you")
    os.chmod(directory, 0o700)
    require(not path.exists() and not path.is_symlink(),
            "%s already exists. Never replace the update key: installed copies trust only it. Back it up instead." % path)
    seed = secrets.token_bytes(32)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, base64.b64encode(seed))
    finally:
        os.close(fd)
    public = base64.b64encode(ed25519_public_key(seed)).decode()
    (directory / (Path(name).stem + ".pub")).write_text(public + "\n")
    return path, public

# ---------------------------------------------------------------- update settings
SITE_RE = r"(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}"

def feed_url(site):
    """The only feed a release reads: appcast.xml at the root of DayDream's website."""
    return "https://%s/%s" % (site, APPCAST_NAME)

def real_site(value):
    return (isinstance(value, str) and re.fullmatch(SITE_RE, value) is not None
            and not any(word in value for word in PLACEHOLDERS + ("invalid", "localhost", "github.io")))

def archive_url_problems(url, data):
    """Where an update archive may live (the app's UpdateConfiguration.permitsArchive is the same rule): an https
    asset of a GitHub release of owner/repository, or a .zip on the site or one of its subdomains. Never a query,
    a port, a login or a '..'. The archive's EdDSA signature is what makes it trusted; this only narrows the hosts."""
    from urllib.parse import urlsplit
    parts = urlsplit(url)
    problems = []
    if parts.scheme != "https" or parts.username or parts.password or parts.port or parts.query or parts.fragment:
        problems.append("must be a plain https URL")
    host, segments = (parts.hostname or ""), parts.path.split("/")
    if not parts.path.endswith(".zip") or any(s in ("", ".", "..") for s in segments[1:]):
        problems.append("must name a .zip with no empty or dot path parts")
    if host == "github.com":
        if not (len(segments) == 7 and segments[1:5] == [data["owner"], data["repository"], "releases", "download"]):
            problems.append("a GitHub archive must be a release asset of %s/%s" % (data["owner"], data["repository"]))
    elif host != data["site"] and not host.endswith("." + data["site"]):
        problems.append("host %r is neither github.com nor %s (or a subdomain)" % (host, data["site"]))
    return problems

def version_core(short_version):
    """'0.1.0 Beta' -> '0.1.0'. The file names and the release tag use the numeric part."""
    match = re.fullmatch(r"(%s)(?: Beta)?" % VERSION_RE, str(short_version))
    require(match, "Version must be x.y or x.y.z, optionally followed by ' Beta': %r" % short_version)
    return match.group(1)

def release_tag(short_version):
    return "v" + version_core(short_version)

def download_prefix(data, short_version):
    return "https://github.com/%s/%s/releases/download/%s/" % (data["owner"], data["repository"], release_tag(short_version))

def valid_public_key(value):
    try:
        key = base64.b64decode(value or "", validate=True)
    except ValueError:
        return False
    return len(key) == 32 and len(set(key)) > 1

def config(path=UPDATES_JSON, require_key=True):
    data = json.loads(Path(path).read_text())
    for field in ("owner", "repository"):
        value = data.get(field, "")
        require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value)
                and not any(word in value.lower() for word in PLACEHOLDERS), "Missing or placeholder " + field)
    require(real_site(data.get("site")), "Missing or placeholder site (DayDream's website host, e.g. getdaydream.app)")
    require(data.get("feed") == feed_url(data["site"]),
            "The feed must be the website's appcast: " + feed_url(data["site"]))
    if require_key or data.get("public_key"):
        require(valid_public_key(data.get("public_key")),
                "No valid update public key in %s. The owner makes the key once (RELEASE.md, section 1)." % Path(path).name)
    return data

def update_info(data):
    """Info.plist keys of a release with updates: checks once a day, downloads a found update quietly and installs it
    when DayDream quits or the person chooses Restart to Update. Signed feed, signed archive, verified before unpacking."""
    return {"MacMemGitHubOwner": data["owner"], "MacMemGitHubRepository": data["repository"],
            "DaydreamUpdateSite": data["site"],
            "SUFeedURL": data["feed"], "SUPublicEDKey": data["public_key"],
            "SUEnableAutomaticChecks": True, "SUScheduledCheckInterval": CHECK_INTERVAL_SECONDS,
            "SUAutomaticallyUpdate": True, "SUAllowsAutomaticUpdates": True, "SUSendProfileInfo": False,
            "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True}

def set_public_key(public_key, path=UPDATES_JSON):
    require(valid_public_key(public_key), "Not a valid Ed25519 public key")
    data = json.loads(Path(path).read_text())
    data["public_key"] = public_key
    Path(path).write_text(json.dumps(data, indent=2) + "\n")
    config(path)

# ---------------------------------------------------------------- app manifest and audit
def manifest(app, source_commit=None):
    contents = app / "Contents"
    functional_payload.refresh(app)
    search_payload.refresh(app)
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    path = contents / "Resources/Companions.json"
    if source_commit is None and path.exists():
        source_commit = json.loads(path.read_text()).get("source_commit")
    hashes = {name: hashlib.sha256((contents / name).read_bytes()).hexdigest() for name in (
        "MacOS/mac-mem", "MacOS/mac-mem-backup", "Resources/before_turn.py")}
    connection = contents / "Resources/ConnectionAvailability.json"
    if connection.exists():
        hashes["Resources/ConnectionAvailability.json"] = hashlib.sha256(connection.read_bytes()).hexdigest()
    for name in functional_payload.paths(app) | writer_payload.paths(app) | search_payload.paths(app):
        hashes[name] = functional_payload.digest(contents / name)
    result = {"schema": 1, "build": info["CFBundleVersion"], "version": info["CFBundleShortVersionString"], "sha256": hashes}
    if source_commit:
        require(re.fullmatch(r"[0-9a-f]{40}", source_commit), "source_commit must be a full commit hash")
        result["source_commit"] = source_commit
    path.write_text(json.dumps(result, sort_keys=True) + "\n")

SITE_ICONS = ROOT / "Sources/MemoryUI/Resources/SiteIcons"

def site_icon_paths():
    """The bundled website and product icons, by exact name from this commit's reviewed folder
    (provenance in tools/site-icons/sources.tsv); nothing else may sit in SiteIcons."""
    names = sorted(p.name for p in SITE_ICONS.glob("*.png"))
    require(names and all(re.fullmatch(r"[a-z0-9-]+\.png", n) for n in names), "Unexpected site icon names")
    return {"Resources/MacMem_MemoryUI.bundle/SiteIcons/" + n for n in names}

def audit(app):
    require(app.name == "DayDream.app" and not app.is_symlink(), "Expected a real DayDream.app staging bundle")
    allowed = {"Info.plist", "MacOS/MacMem", "MacOS/mac-mem", "MacOS/mac-mem-backup", "Resources/Daydream.icns",
               "Resources/LICENSE.txt", "Resources/NOTICE.txt", "Resources/THIRD-PARTY-NOTICES.md",
               "Resources/llama-MIT.txt", "Resources/Qwen-APACHE-2.0.txt", "Resources/Sparkle-LICENSE.txt",
               "Resources/before_turn.py", "Resources/Companions.json", "Resources/launcher.example.json",
               # Notarization ticket written by `xcrun stapler staple` into a stapled app.
               "CodeResources",
               "Resources/MacMem_MemoryUI.bundle/Info.plist"}
    allowed.update(site_icon_paths())
    allowed.update(functional_payload.paths(app))
    allowed.update(search_payload.paths(app))
    # The "On this Mac" runtime: the pinned manifest and the seven signed libraries (writer_payload.py).
    allowed.update(writer_payload.paths(app))
    for path in (app / "Contents").rglob("*"):
        relative = path.relative_to(app / "Contents").as_posix()
        require(path.resolve().is_relative_to(app.resolve()), "Bundle link escapes app")
        if path.is_file():
            require(relative in allowed or relative.startswith("Frameworks/Sparkle.framework/") or relative.startswith("_CodeSignature/"), "Unexpected release payload: " + relative)
        if path.is_symlink():
            require(relative.startswith("Frameworks/Sparkle.framework/"), "Unexpected bundle symlink")

# ---------------------------------------------------------------- update archive and appcast
def appcast_argv(key_file, prefix, directory, tools=SPARKLE_TOOLS):
    """generate_appcast with the key FILE. Never --account: that reads the Keychain."""
    return [str(Path(tools) / "generate_appcast"), "--ed-key-file", str(key_file), "--maximum-deltas", "0",
            "--embed-release-notes", "--download-url-prefix", prefix, str(directory)]

def feed_verify_argv(key_file, feed, tools=SPARKLE_TOOLS):
    return [str(Path(tools) / "sign_update"), "--ed-key-file", str(key_file), "--verify", str(feed)]

def check_appcast(feed, prefix, archive_name, build, short_version):
    """The appcast has exactly the new item, with the expected URL, version and a signature."""
    root = ET.parse(feed).getroot()
    items = root.findall("./channel/item")
    require(len(items) == 1, "Expected exactly one item in the new appcast, found %d" % len(items))
    item = items[0]
    enclosure = item.find("enclosure")
    require(enclosure is not None and enclosure.attrib.get("url") == prefix + archive_name,
            "Unexpected archive URL: %s" % (enclosure.attrib.get("url") if enclosure is not None else None))
    version = item.findtext(SPARKLE_NS + "version") or enclosure.attrib.get(SPARKLE_NS + "version")
    require(version == str(build), "Appcast build %r != app build %s" % (version, build))
    short = item.findtext(SPARKLE_NS + "shortVersionString") or enclosure.attrib.get(SPARKLE_NS + "shortVersionString")
    require(short == short_version, "Appcast version %r != app version %r" % (short, short_version))
    signature = enclosure.attrib.get(SPARKLE_NS + "edSignature", "")
    require(signature, "No EdDSA signature on the archive; DO NOT publish this output")
    require("sparkle-signatures:" in Path(feed).read_text(), "The appcast itself is not signed; DO NOT publish this output")
    return signature

def _release_inputs(key_file, rights_confirmed, updates_path):
    """The owner's confirmation, the key file and packaging/updates.json, before anything is read from the app."""
    # The owner confirms after checking THIRD-PARTY-NOTICES.md for this release.
    require(rights_confirmed, "Redistribution rights not confirmed (pass --confirm-redistribution-rights after checking THIRD-PARTY-NOTICES.md)")
    key_file = Path(key_file).expanduser()
    problems = key_file_problems(key_file)
    require(not problems, "Update key file refused: " + "; ".join(problems))
    data = config(updates_path)
    require(public_key_of(key_file) == data["public_key"], "The key file does not match the public key in packaging/updates.json")
    return key_file, data

def _payload_gates(app):
    """What may never be released at all, checked first."""
    # Typesense (GPL-3.0) is cleared for the public by its distribution record (owner decision 2026-10-03), which
    # must be exactly this commit's record naming the Complete Corresponding Source kit by sha256; a private,
    # forged or mismatched record is still refused. Attach that kit to the GitHub release next to the DMG.
    require(not search_payload.present(app) or search_payload.public_cleared_app(app),
            "Local Typesense payload is not cleared for public distribution")
    require(not functional_payload.paths(app), "Private functional trial is not cleared for public release preparation")
    # Every release carries "On this Mac" (owner decision 2026-09-26). An app staged with
    # --without-writer-runtime-for-tests is a test build and never goes into the appcast.
    require(writer_payload.paths(app), "No On this Mac runtime inside (a --without-writer-runtime-for-tests stage). "
            "Test builds never go into the appcast; stage from a commit with the signed runtime.")
    require(search_payload.TEST_ONLY_KEY not in plistlib.loads((app / "Contents/Info.plist").read_bytes()), "Test-only missing-search build cannot be released")

def _release_app_facts(app, data, previous_build):
    """Everything about the app that needs no tool: a public, full-typing release of this commit's update settings.
    Returns (info, companions, build, short version)."""
    _payload_gates(app)
    audit(app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require('DaydreamQAHarness' not in info, 'PRIVATE QA HARNESS: never a public release')
    # The owner's private test copy (developer-id-release.py stage --owner-build) never goes into the appcast.
    # Every release carries website typing (the owner's decision of 2026-09-25); only the key marks the copy.
    require("MacMemOwnerTyping" not in info,
            "OWNER BUILD: the owner's private test copy (updates off). It is not a public release and never goes into the appcast.")
    # ...and the app is that full-typing build: a narrow app would contradict the published typing claims and
    # narrow typing for everyone who updates (developer-id-release.py typing_app).
    macmem = app / "Contents/MacOS/MacMem"
    require(macmem.is_file() and b"--capture-fixture-trial" not in macmem.read_bytes(),
            "PRIVATE QA HARNESS: fixture executable is not a public release")
    require(macmem.is_file() and b"WebTypingRoute" in macmem.read_bytes(),
            "Not the full-typing build: MacOS/MacMem has no website typing code. Stage it with developer-id-release.py stage.")
    companions = json.loads((app / "Contents/Resources/Companions.json").read_text())
    require(companions.get("build") == info["CFBundleVersion"] and companions.get("version") == info["CFBundleShortVersionString"], "Companion version mismatch")
    for name in ("MacOS/mac-mem", "MacOS/mac-mem-backup", "Resources/before_turn.py"):
        require(companions.get("sha256", {}).get(name) == hashlib.sha256((app / "Contents" / name).read_bytes()).hexdigest(), "Companion hash mismatch")
    require(info.get("CFBundleIdentifier") == "com.getnorthlight.daydream", "Wrong bundle identity")
    # The release reads this commit's feed and key and updates quietly (an updates-off build never goes in a feed).
    for field, value in update_info(data).items():
        require(info.get(field) == value, "Signed app config mismatch: " + field)
    build = str(info["CFBundleVersion"])
    require(re.fullmatch(r"[1-9][0-9]*", build) and int(build) > previous_build >= 1, "Build must exceed the verified prior installed build")
    return info, companions, build, info["CFBundleShortVersionString"]

def _verify_signed_app(app, runner):
    """Gatekeeper, Developer ID and stapled notarization must all agree. No signing identities changed."""
    runner(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    signature = runner(["codesign", "-dv", "--verbose=4", str(app)], capture_output=True, text=True, check=True).stderr
    require("Authority=Developer ID Application:" in signature and "Signature=adhoc" not in signature, "Developer ID Application signature required")
    require("TeamIdentifier=" + apple_team_id() in signature.splitlines(), "Signature team does not match packaging/signing.json")
    require(re.search(r"flags=0x[0-9a-f]+\([^)]*runtime", signature), "Hardened runtime flag required")
    runner(["spctl", "--assess", "--type", "execute", str(app)], check=True)
    runner(["xcrun", "stapler", "validate", str(app)], check=True)

def _archive_prefix(data, short, prefix):
    """Where the archive will be downloaded from: the GitHub release v<version> by default."""
    prefix = prefix or download_prefix(data, short)
    problems = archive_url_problems(prefix + "DayDream-%s.zip" % version_core(short), data)
    require(prefix.endswith("/") and not problems, "Download prefix refused (%s): %s" % (prefix, "; ".join(problems) or "must end with /"))
    return prefix

def _sign_feed(app, output, archive, key_file, data, prefix, build, short, companions, runner, source):
    """generate_appcast signs the archive and the feed with the key FILE; both are checked before anything is reported."""
    runner(appcast_argv(key_file, prefix, output), check=True)
    feed = output / APPCAST_NAME
    signature = check_appcast(feed, prefix, archive.name, build, short)
    runner([str(app / "Contents/MacOS/mac-mem"), "verify-update-signature", str(archive), signature, data["public_key"]], check=True)
    runner(feed_verify_argv(key_file, feed), check=True)
    (output / "RELEASE-VERIFIED.json").write_text(json.dumps({
        "build": build, "version": short, "tag": release_tag(short), "archive": archive.name,
        "archive_url": prefix + archive.name, "feed_url": data["feed"], "source": source,
        "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "feed_sha256": hashlib.sha256(feed.read_bytes()).hexdigest(),
        "source_commit": companions.get("source_commit"), "published": False}, indent=2) + "\n")
    print("Signed update archive and appcast prepared in %s. NOT published." % output)
    print("Upload %s to %s, then publish %s as %s (UPDATES-1003.md, 'Publish')." % (archive.name, prefix, APPCAST_NAME, data["feed"]))

def prepare(app, output, key_file, previous_build, notes, rights_confirmed, updates_path=UPDATES_JSON, runner=subprocess.run,
            download_url_prefix=None):
    _payload_gates(app)
    key_file, data = _release_inputs(key_file, rights_confirmed, updates_path)
    require(notes and Path(notes).is_file(), "Release notes file required (developer-id-release.py notes)")
    require("[" not in Path(notes).read_text(), "The release notes still have a [placeholder]. Fill it in first.")
    info, companions, build, short = _release_app_facts(app, data, previous_build)
    core = version_core(short)
    prefix = _archive_prefix(data, short, download_url_prefix)
    _verify_signed_app(app, runner)
    require(not output.exists(), "Output must be a new directory; existing release never overwritten")
    output.mkdir(parents=True)
    archive = output / ("DayDream-%s.zip" % core)
    runner(["ditto", "-c", "-k", "--keepParent", str(app), str(archive)], check=True)
    shutil.copyfile(notes, output / ("DayDream-%s.md" % core))
    _sign_feed(app, output, archive, key_file, data, prefix, build, short, companions, runner, "app")

def plain_notes_problems(text):
    """Release notes for the appcast: plain text people read in Sparkle's window, nothing to fill in."""
    problems = []
    if not text.strip():
        problems.append("empty")
    if len(text) > 4000:
        problems.append("longer than 4000 characters")
    if re.search(r"\[ ?\]|\[(?:one line|placeholder|todo|tbd|fill)", text, re.I) or re.search(r"\b(?:TODO|TBD|XXX)\b", text):
        problems.append("a [placeholder] or TODO is left")
    if re.search(r"<\s*/?\s*[A-Za-z!]", text):
        problems.append("looks like HTML (plain text only)")
    if "\x00" in text:
        problems.append("binary content")
    return problems

def appcast(output, key_file, previous_build, notes, rights_confirmed, dmg=None, zip_file=None, updates_path=UPDATES_JSON,
            runner=subprocess.run, download_url_prefix=None):
    """The owner's step after signing and notarizing: from DayDream-<version>.dmg (or a .zip of the stapled app),
    DayDream-<version>.zip, the plain-text notes as DayDream-<version>.txt and a one-item appcast.xml, all signed with
    the key FILE. The app inside is checked exactly as prepare checks it. Nothing is uploaded or published."""
    import tempfile
    require((dmg is None) != (zip_file is None), "Give exactly one of --dmg or --zip")
    source = Path(dmg or zip_file).expanduser().absolute()
    require(source.is_file() and not source.is_symlink() and source.suffix == (".dmg" if dmg else ".zip"),
            "Expected a signed, notarized %s file: %s" % (".dmg" if dmg else ".zip", source))
    key_file, data = _release_inputs(key_file, rights_confirmed, updates_path)
    require(notes and Path(notes).is_file() and Path(notes).suffix == ".txt", "Release notes: a plain-text .txt file is required")
    text = Path(notes).read_text(encoding="utf-8")
    problems = plain_notes_problems(text)
    require(not problems, "Release notes refused: " + "; ".join(problems))
    output = Path(output).absolute()
    require(not output.exists(), "Output must be a new directory; existing release never overwritten")
    work = Path(tempfile.mkdtemp(prefix="daydream-appcast."))
    mounted = None
    try:
        if dmg:
            # The image itself: Developer ID signed and its notarization stapled.
            runner(["codesign", "--verify", "--strict", str(source)], check=True)
            runner(["xcrun", "stapler", "validate", str(source)], check=True)
            mounted = work / "mount"
            mounted.mkdir()
            runner(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", str(mounted), str(source)], check=True)
            app = mounted / "DayDream.app"
        else:
            unpacked = work / "unpacked"
            unpacked.mkdir()
            runner(["ditto", "-x", "-k", str(source), str(unpacked)], check=True)
            names = sorted(p.name for p in unpacked.iterdir() if p.name != "__MACOSX")
            require(names == ["DayDream.app"], "The zip must hold exactly DayDream.app (found %s)" % names)
            app = unpacked / "DayDream.app"
        require(app.is_dir() and not app.is_symlink(), "No DayDream.app inside %s" % source.name)
        info, companions, build, short = _release_app_facts(app, data, previous_build)
        core = version_core(short)
        prefix = _archive_prefix(data, short, download_url_prefix)
        _verify_signed_app(app, runner)
        output.mkdir(parents=True)
        archive = output / ("DayDream-%s.zip" % core)
        if dmg:
            runner(["ditto", "-c", "-k", "--keepParent", str(app), str(archive)], check=True)
        else:
            shutil.copyfile(source, archive)
        (output / ("DayDream-%s.txt" % core)).write_text(text.strip() + "\n", encoding="utf-8")
        _sign_feed(app, output, archive, key_file, data, prefix, build, short, companions, runner, source.name)
    finally:
        if mounted is not None and any(mounted.iterdir()):
            runner(["hdiutil", "detach", str(mounted)], check=False)
        shutil.rmtree(work, ignore_errors=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["make-key", "public-key", "set-public-key", "validate", "manifest", "prepare", "appcast"])
    parser.add_argument("--key-file", type=Path, default=KEY_FILE)
    parser.add_argument("--key-dir", type=Path, help="make-key only: folder for the key (default ~/DayDream-keys)")
    parser.add_argument("--public-key", help="set-public-key: the base64 public key (default: derived from --key-file)")
    parser.add_argument("--app", type=Path)
    parser.add_argument("--dmg", type=Path, help="appcast: the signed, notarized, stapled DayDream-<version>.dmg")
    parser.add_argument("--zip", type=Path, help="appcast: instead of --dmg, a .zip holding the stapled DayDream.app")
    parser.add_argument("--notes", type=Path, help="prepare: the filled-in release notes (developer-id-release.py notes); "
                                                   "appcast: plain-text notes (.txt) shown in the update window")
    parser.add_argument("--download-url-prefix", help="prepare/appcast: where the archive will be uploaded "
                                                      "(default: the GitHub release https://github.com/<owner>/<repo>/releases/download/v<version>/)")
    parser.add_argument("--previous-build", type=int, default=0)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--confirm-redistribution-rights", action="store_true")
    args = parser.parse_args()
    if args.action == "make-key":
        path, public = make_key(args.key_dir or KEY_DIR)
        print("Made the update key: %s (chmod 600, folder chmod 700). Back it up now (RELEASE.md, section 1)." % path)
        print("Public key (safe to share): %s" % public)
    elif args.action == "public-key":
        print(public_key_of(args.key_file))
    elif args.action == "set-public-key":
        set_public_key(args.public_key or public_key_of(args.key_file))
        print("Wrote the public key to packaging/updates.json. Commit that file.")
    elif args.action == "manifest":
        manifest(args.app)
    elif args.action == "validate":
        data = config(require_key=False)
        print("packaging/updates.json is valid: feed %s. No network or key access." % data["feed"])
        if not data.get("public_key"):
            print("The update public key is not set yet, so a release stage refuses. Make it once: RELEASE.md, section 1.")
    elif args.action == "appcast":
        require(args.output, "--output is required")
        appcast(args.output, args.key_file, args.previous_build, args.notes, args.confirm_redistribution_rights,
                dmg=args.dmg, zip_file=args.zip, download_url_prefix=args.download_url_prefix)
    else:
        prepare(args.app, args.output, args.key_file, args.previous_build, args.notes, args.confirm_redistribution_rights,
                download_url_prefix=args.download_url_prefix)

if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
