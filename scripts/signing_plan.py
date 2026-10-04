"""Read-only signing preparation. No execution, credential discovery or network mode.

The codesign steps come from scripts/developer-id-release.py (SIGNING_TABLE/sign_steps), so
this plan and the executor share one source of truth. The executor runs them; this only
prints them, with placeholders unless an explicit certificate SHA-1 / profile is given.
"""
import argparse
import hashlib
import importlib.util
import json
import plistlib
import sys
from pathlib import Path
import release
import functional_payload
import search_payload


def _load_pipeline():
    name = 'developer_id_release'
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name('developer-id-release.py'))
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


pipeline = _load_pipeline()

# Main app: no entitlements, or only com.apple.security.automation.apple-events when Chrome page
# history ships (ReleaseFeatures.chromePageHistory; --apple-events follows it). It is the only
# key the signed writer tolerates (WriterBackend/Sources/WriterBackend/SignedRuntimePolicy.swift:57).
MAIN_ENTITLEMENTS = {}
MAIN_APPLE_EVENTS_ENTITLEMENTS = pipeline.ENTITLEMENT_FILES['main-apple-events.entitlements']
EMPTY_ENTITLEMENTS = {}
IDENTITY_PLACEHOLDER = 'DEVELOPER_ID_SHA1'
NOTARY_PLACEHOLDER = 'NOTARY_PROFILE'


def plan(app, staging, updates='configured', apple_events=None, identity=None, notary_profile=None):
    app = Path(app).absolute()
    staging = Path(staging).resolve()
    release.audit(app)
    app = app.resolve()
    functional = functional_payload.paths(app)
    if functional or search_payload.present(app):
        release.require(functional_payload.digest(app/'Contents'/functional_payload.SERVER) == '086d498fbf0afb45091f4e28b50e803a3633daac506388a5f71e5ed90407c91f', 'Unreviewed unsigned Typesense input')
    release.require(not staging.exists(), 'Staging must not exist')
    release.require(staging != app and not staging.is_relative_to(app) and not app.is_relative_to(staging), 'Separate staging required')
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    release.require(info.get('CFBundleIdentifier') == 'com.getnorthlight.daydream', 'Wrong identity')
    apple_events = pipeline.resolve_apple_events(apple_events)
    # 'configured' (the release): checks on, never installs by itself (and Sparkle never offers to), the GitHub Releases feed and
    # key of packaging/updates.json. 'off': no feed and nothing automatic. Same rule as the executor.
    problems = pipeline.update_policy_problems(info, updates)
    release.require(not problems, ('updates=off build: ' if updates == 'off' else 'updates=configured build: ') + '; '.join(problems))
    nested = [row['path'] for row in pipeline.SIGNING_TABLE if row['mode'] == 'sign' and row['path'] and not row['optional']]
    for name in nested:
        release.require((app/name).exists(), 'Missing nested code: '+name)
    identity = identity or IDENTITY_PLACEHOLDER
    if identity != IDENTITY_PLACEHOLDER:
        release.require(pipeline.identity_kind(identity) == 'developer-id', 'Plan identity must be a certificate SHA-1')
    profile = notary_profile or NOTARY_PLACEHOLDER
    target = staging/'DayDream.app'
    executor = str(Path(__file__).with_name('developer-id-release.py'))
    events = ['--apple-events'] if apple_events else []
    steps = [{'gate':'Fresh scoped approval for named certificate/private-key use; rights and runtime review complete'},
             {'gate':'Verify full source_files/source_symlinks inventory and strict source signatures immediately before copying and again on the copy; any drift stops signing'},
             {'argv':['ditto', str(app), str(target)]},
             {'entitlements_files':{name:str(pipeline.ENTITLEMENTS_DIR/name) for name in sorted(pipeline.ENTITLEMENT_FILES)},
              'gate':'plutil -lint and exact reviewed dicts for every entitlements file; items signed without --entitlements carry none'},
             {'gate':'Pre-sign on the copy: refuse extended attributes other than com.apple.provenance; remove the obsolete outer _CodeSignature/CodeResources; Info.plist policy; every Mach-O covered by the signing table; linkage only /usr/lib, /System/Library and (MacMem) @rpath Sparkle; no toolchain LC_RPATH (stage removes it); Sparkle equals its Vendor pin; no Node runtime or remote bridge'},
             {'gate':'Sparkle inside-out per https://sparkle-project.org/documentation/sandboxing/: Autoupdate is signed with NO entitlements, dropping com.apple.application-identifier (restricted; no Developer ID profile can authorize it, TN3125); Downloader keeps its own via --preserve-metadata=entitlements (pinned {}); Installer, Updater and the framework carry none. Before publishing, test a real two-version update (RELEASE.md section 5)'}]
    # The "On this Mac" runtime (every release, writer_payload.py) or the private trial's writer set:
    # verified in place, never re-signed.
    writer_libs = pipeline.writer_libraries(app)
    for step in pipeline.sign_steps(target, identity, apple_events=apple_events, present=lambda rel: (app/rel).exists(), writer_libs=writer_libs):
        if step['action'] == 'manifest':
            steps.append({'argv':['python3',str(Path(__file__).with_name('release.py')),'manifest','--app',str(target)]})
            continue
        steps.append({'argv':step['argv']})
    if writer_libs:
        steps.append({'gate':'Seven "On this Mac" libraries: never re-signed. Each keeps its enrolled bytes, Developer ID signature, Team '+release.apple_team_id()+', leaf SHA256 '+pipeline.LEAF_SHA256+', hardened runtime and empty entitlements, as the pinned manifest records; any mismatch stops'})
    if functional:
        steps[1] = {'gate':'Verify full frozen source inventory before/after copying. Source outer app is intentionally unsealed; verify every existing nested signature and exact enrolled writer bytes. No packaged execution.'}
        steps.append({'gate':'Private self-use only. Preserve enrolled seven writer signatures/hash exactly; verify Team '+release.apple_team_id()+', leaf SHA256, hardened runtime and empty entitlements against pinned manifest; any mismatch stops'})
    dmg = staging/pipeline.dmg_name(info.get('CFBundleShortVersionString', '0.0.0'))
    steps += [{'argv':['codesign','--verify','--deep','--strict',str(target)]},
              {'argv':['python3',executor,'verify','--app',str(target),'--expect','developer-id']+events,
               'gate':'Developer ID authority, TeamIdentifier '+release.apple_team_id()+' (packaging/signing.json), one leaf certificate (writer builds: the enrolled leaf SHA-256), secure timestamp, runtime flag and exact entitlements for EVERY nested code item; companion hashes'},
              {'gate':'Original source inventory must remain unchanged'},
              {'argv':['ditto','-c','-k','--keepParent',str(target),str(staging/'notary-input.zip')]},
              {'gate':'Separate approval to upload this exact archive/hash to Apple using the named existing notarytool Keychain profile'},
              {'argv':['xcrun','notarytool','submit',str(staging/'notary-input.zip'),'--keychain-profile',profile,'--wait','--timeout',pipeline.NOTARY_WAIT,'--output-format','json']},
              {'gate':'Require JSON status Accepted, preserve submission ID and complete log; Invalid, In Progress, timeout or missing response stops here'},
              {'argv':['xcrun','stapler','staple',str(target)]},
              {'argv':['xcrun','stapler','validate',str(target)]},
              {'argv':['spctl','--assess','--type','execute','--verbose=4',str(target)]},
              {'gate':'After trust acceptance only: exact signed-copy writer OFF/runtime tests; failure stops release, never broadens entitlements automatically'},
              {'argv':['python3',executor,'dmg','--app',str(target),'--out',str(dmg),'--identity',identity],
               'gate':'NEW final-layout DMG from the stapled app, laid out before signing; never polish-dmg.sh a signed or notarized image'},
              {'argv':['xcrun','notarytool','submit',str(dmg),'--keychain-profile',profile,'--wait','--timeout',pipeline.NOTARY_WAIT,'--output-format','json'],
               'gate':'Separate approval; require Accepted and a clean log'},
              {'argv':['xcrun','stapler','staple',str(dmg)]},
              {'argv':['xcrun','stapler','validate',str(dmg)]},
              {'argv':['spctl','--assess','--type','open','--context','context:primary-signature','--verbose=4',str(dmg)]},
              {'argv':['python3',executor,'checksum','--dmg',str(dmg)],
               'gate':'SHA-256 of the download, taken only AFTER the DMG is stapled (stapling changes the file); written to '+dmg.name+'.sha256'},
              {'argv':['python3',executor,'notes','--app',str(target),'--dmg',str(dmg),'--out',str(staging/'release-notes.md')],
               'gate':'Release notes from docs/release-notes-template.md with the post-staple SHA-256; the owner fills every [bracketed] line'},
              {'argv':['python3',str(Path(__file__).with_name('release.py')),'prepare','--app',str(target),'--notes',str(staging/'release-notes.md'),
                       '--key-file',str(release.KEY_FILE),'--output',str(staging/'updates'),'--previous-build','PREVIOUS_BUILD','--confirm-redistribution-rights'],
               'gate':'Sparkle archive DayDream-<version>.zip and a signed appcast.xml, signed with the key FILE (--ed-key-file), never --account or the Keychain'},
              {'gate':'Verify extracted app seal/TeamID/companions, transferred quarantine launch, OFF restart and signed-runtime checks before distribution'}]
    files = {str(p.relative_to(app)):hashlib.sha256(p.read_bytes()).hexdigest()
             for p in app.rglob('*') if p.is_file() and not p.is_symlink()}
    return {'execution_supported':False, 'credentials_accessed':False, 'source_app':str(app),
            'executor':executor, 'updates':updates,
            'main_entitlements':MAIN_APPLE_EVENTS_ENTITLEMENTS if apple_events else MAIN_ENTITLEMENTS,
            'runtime_acceptance':'NOT TESTED', 'notary_acceptance':'NOT TESTED',
            'planner_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'release_helper_sha256':hashlib.sha256(Path(release.__file__).read_bytes()).hexdigest(),
            'executor_sha256':hashlib.sha256(Path(executor).read_bytes()).hexdigest(),
            'source_symlinks':{str(p.relative_to(app)):str(p.readlink()) for p in app.rglob('*') if p.is_symlink()},
            'source_files':files, 'requires':['Developer ID Application certificate SHA-1 for Team %s (writer builds: its leaf DER SHA-256 must be %s)' % (pipeline.TEAM_ID, pipeline.LEAF_SHA256),
            'existing notarytool Keychain profile name (RELEASE.md uses %s)' % pipeline.DEFAULT_NOTARY_PROFILE, 'separate signing and Apple-upload approvals',
            'collector/application/artwork redistribution rights', 'same-team signed writer runtime and pinned manifest'],
            'steps':steps}

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--staging',type=Path,required=True)
    parser.add_argument('--updates',choices=['configured','off'],default='configured')
    parser.add_argument('--apple-events',action=argparse.BooleanOptionalAction,default=None,help='default: follow ReleaseFeatures.chromePageHistory')
    parser.add_argument('--identity-sha1',help='print with this certificate SHA-1 instead of the placeholder')
    parser.add_argument('--notary-profile',help='print with this notarytool profile instead of the placeholder')
    args=parser.parse_args()
    print(json.dumps(plan(args.app,args.staging,args.updates,args.apple_events,args.identity_sha1,args.notary_profile),indent=2))
