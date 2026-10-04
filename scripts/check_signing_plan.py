import base64
import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import signing_plan
import release

# RFC 8032 test vector 1 public key: a fixture, never a real update key.
FIXTURE_KEY=base64.b64encode(bytes.fromhex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')).decode()
FIXTURE_UPDATES={'owner':'getnorthlight','repository':'daydream','site':'getdaydream.app','feed':release.feed_url('getdaydream.app'),'public_key':FIXTURE_KEY}

class SigningPlanChecks(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='daydream-sign-plan-')
        self.addCleanup(self.temp.cleanup)
        config=patch.object(release,'config',return_value=dict(FIXTURE_UPDATES))
        config.start();self.addCleanup(config.stop)
        self.switch(False)
        self.root=Path(self.temp.name);self.app=self.root/'DayDream.app'
        contents=self.app/'Contents';contents.mkdir(parents=True)
        # CHANGED (updates-1003): a release has Sparkle configured (checks on, quiet download and install at the quit
        # or Restart to Update, the website's feed and key from packaging/updates.json), so that is the fixture.
        self.info={'CFBundleIdentifier':'com.getnorthlight.daydream','CFBundleShortVersionString':'0.1.0 Beta',
                   **self.off_keys(),**release.update_info(FIXTURE_UPDATES)}
        self.save()
        for p in ['Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc','Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc','Frameworks/Sparkle.framework/Versions/B/Updater.app']:(contents/p).mkdir(parents=True)
        for p in ['Frameworks/Sparkle.framework/Versions/B/Autoupdate','MacOS/mac-mem','MacOS/mac-mem-backup']:
            f=contents/p;f.parent.mkdir(exist_ok=True,parents=True);f.write_bytes(b'synthetic')
    def switch(self,value):
        """ReleaseFeatures.chromePageHistory for this test."""
        if getattr(self,'_switch',None):self._switch.stop()
        self._switch=patch.object(signing_plan.pipeline,'chrome_page_history_switch',return_value=value)
        self._switch.start();self.addCleanup(lambda:self._switch.stop() if self._switch else None)
    def off_keys(self):
        return {'SUEnableAutomaticChecks':False,'SUAutomaticallyUpdate':False,'SUAllowsAutomaticUpdates':False,
                'SURequireSignedFeed':True,'SUVerifyUpdateBeforeExtraction':True}
    def save(self):(self.app/'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
    def signs(self,value):
        return [s['argv'] for s in value['steps'] if s.get('argv',[''])[0]=='codesign' and '--sign' in s['argv']]
    def test_no_execution_and_order(self):
        with patch('subprocess.run') as run:
            value=signing_plan.plan(self.app,self.root/'new')
            run.assert_not_called()
        self.assertFalse(value['execution_supported'])
        signs=self.signs(value)
        self.assertEqual(len(signs),8)
        self.assertTrue(signs[-1][-1].endswith('DayDream.app'))
        for cmd in signs:self.assertNotIn('--deep',cmd);self.assertIn('--timestamp',cmd);self.assertIn('runtime',cmd)
        # The main app carries NO entitlements when Chrome page history is switched off
        # (ReleaseFeatures.chromePageHistory = false). apple-events is the only key the
        # signed writer tolerates (SignedRuntimePolicy.swift:57).
        self.assertEqual(signing_plan.MAIN_ENTITLEMENTS,{})
        self.assertEqual(signing_plan.MAIN_APPLE_EVENTS_ENTITLEMENTS,{'com.apple.security.automation.apple-events':True})
        self.assertNotIn('--entitlements',signs[-1])
        self.assertEqual(signing_plan.EMPTY_ENTITLEMENTS,{})
        # CHANGED: Autoupdate no longer keeps com.apple.application-identifier. Sparkle's
        # documented signing (https://sparkle-project.org/documentation/sandboxing/) passes no
        # entitlements for Autoupdate, and that restricted entitlement cannot be authorized by
        # a Developer ID profile (TN3125). Downloader preserves its own entitlements.
        self.assertFalse(hasattr(signing_plan,'AUTOUPDATE_ENTITLEMENTS'))
        autoupdate=next(c for c in signs if c[-1].endswith('/Versions/B/Autoupdate'))
        self.assertNotIn('--entitlements',autoupdate)
        self.assertFalse(any(a.startswith('--preserve-metadata') for a in autoupdate))
        downloader=next(c for c in signs if c[-1].endswith('/Downloader.xpc'))
        self.assertIn('--preserve-metadata=entitlements',downloader)
        self.assertNotIn('--entitlements',downloader)
        self.assertFalse((self.root/'new').exists())
    def test_functional_sparkle_signed_inside_out_writer_preserved(self):
        writer = signing_plan.functional_payload.LIBROOT + '/fixture.dylib'
        with patch.object(signing_plan.functional_payload, 'paths', return_value=[writer]), patch.object(signing_plan.functional_payload, 'digest', return_value='086d498fbf0afb45091f4e28b50e803a3633daac506388a5f71e5ed90407c91f'), patch('subprocess.run') as run:
            value = signing_plan.plan(self.app, self.root/'new')
            run.assert_not_called()
        commands = [s['argv'] for s in value['steps'] if 'argv' in s]
        signs = [c for c in commands if c[0] == 'codesign' and '--sign' in c]
        sparkle = [c for c in signs if '/Sparkle.framework' in c[-1]]
        self.assertEqual(len(sparkle), 5)
        self.assertTrue(sparkle[0][-1].endswith('/Installer.xpc'))
        self.assertTrue(sparkle[-1][-1].endswith('/Sparkle.framework'))
        for c in sparkle:
            self.assertTrue(c[-1].startswith(str(self.root.resolve()/'new/DayDream.app')+'/'))
            self.assertNotIn('--deep', c)
        self.assertFalse(any(c[-1].endswith('fixture.dylib') for c in signs))
        self.assertTrue(any(c[0] == 'codesign' and '--verify' in c and c[-1].endswith('fixture.dylib') for c in commands))
        self.assertFalse((self.root/'new').exists())

    def test_quiet_updates_only_in_a_release(self):
        # CHANGED (updates-1003, owner 10/03): a release downloads quietly (SUAutomaticallyUpdate and
        # SUAllowsAutomaticUpdates true); an updates-off build (owner, QA) has both false. Each mode refuses the other.
        for mode,info,wrong in (('configured',dict(self.info),False),('off',self.off_keys(),True)):
            for key in ('SUAutomaticallyUpdate','SUAllowsAutomaticUpdates'):
                self.info={**info,'CFBundleIdentifier':'com.getnorthlight.daydream',key:wrong};self.save()
                with self.assertRaisesRegex(ValueError,key):signing_plan.plan(self.app,self.root/'new',updates=mode)
    def test_configured_updates_mode(self):
        value=signing_plan.plan(self.app,self.root/'new')
        self.assertEqual(value['updates'],'configured')
        good=dict(self.info)
        for key,bad in (('SUFeedURL','https://getnorthlight.github.io/daydream/appcast.xml'),
                        ('SUFeedURL','https://github.com/getnorthlight/daydream/releases/latest/download/appcast.xml'),
                        ('DaydreamUpdateSite','example.com'),
                        ('SUPublicEDKey',base64.b64encode(bytes(range(32))).decode()),
                        ('SUEnableAutomaticChecks',False),('SUScheduledCheckInterval',3600),
                        ('SURequireSignedFeed',False),('SUVerifyUpdateBeforeExtraction',False),
                        ('MacMemGitHubOwner','someone-else'),('SUSendProfileInfo',True)):
            self.info={**good,key:bad};self.save()
            with self.assertRaisesRegex(ValueError,key):signing_plan.plan(self.app,self.root/'new')
        for key in ('SUFeedURL','SUPublicEDKey','MacMemGitHubOwner','MacMemGitHubRepository','DaydreamUpdateSite'):
            self.info={k:v for k,v in good.items() if k!=key};self.save()
            with self.assertRaisesRegex(ValueError,key):signing_plan.plan(self.app,self.root/'new')
        # A configured app is not an updates=off build, and the reverse.
        self.info=good;self.save()
        with self.assertRaisesRegex(ValueError,'updates=off'):signing_plan.plan(self.app,self.root/'new',updates='off')
        self.info={'CFBundleIdentifier':'com.getnorthlight.daydream',**self.off_keys()};self.save()
        signing_plan.plan(self.app,self.root/'new',updates='off')
        with self.assertRaisesRegex(ValueError,'updates=configured'):signing_plan.plan(self.app,self.root/'new')
    def test_configured_mode_needs_the_real_key(self):
        with patch.object(release,'config',side_effect=ValueError('No valid update public key')):
            with self.assertRaisesRegex(ValueError,'public key'):signing_plan.plan(self.app,self.root/'new')

    def test_apple_events_follow_the_release_switch(self):
        # CHANGED (sat/updates): --apple-events follows ReleaseFeatures.chromePageHistory; an
        # explicit value that disagrees with the switch is refused (honesty track H7).
        self.switch(True)
        value=signing_plan.plan(self.app,self.root/'new')
        outer=self.signs(value)[-1]
        self.assertTrue(outer[-1].endswith('/DayDream.app'))
        self.assertEqual(Path(outer[outer.index('--entitlements')+1]).name,'main-apple-events.entitlements')
        self.assertEqual(value['main_entitlements'],{'com.apple.security.automation.apple-events':True})
        self.assertEqual(signing_plan.plan(self.app,self.root/'new',apple_events=True)['main_entitlements'],{'com.apple.security.automation.apple-events':True})
        with self.assertRaisesRegex(Exception,'disagrees'):signing_plan.plan(self.app,self.root/'new',apple_events=False)
        self.switch(False)
        self.assertEqual(signing_plan.plan(self.app,self.root/'new')['main_entitlements'],{})
        with self.assertRaisesRegex(Exception,'disagrees'):signing_plan.plan(self.app,self.root/'new',apple_events=True)

    def test_plan_shares_executor_table(self):
        value=signing_plan.plan(self.app,self.root/'new')
        signs=self.signs(value)
        target=self.root.resolve()/'new/DayDream.app'
        shared=[s['argv'] for s in signing_plan.pipeline.sign_steps(target,'DEVELOPER_ID_SHA1',present=lambda rel:(self.app/rel).exists(),writer_libs=[]) if s['action']=='sign']
        self.assertEqual(signs,shared)
        ids={c[-1].rsplit('/',1)[-1]:c[c.index('--identifier')+1] for c in signs if '--identifier' in c}
        self.assertEqual(ids,{'mac-mem':'com.getnorthlight.daydream.mac-mem','mac-mem-backup':'com.getnorthlight.daydream.mac-mem-backup'})

    def test_presign_gates_and_leaf_pin_verification(self):
        value=signing_plan.plan(self.app,self.root/'new')
        steps=value['steps']
        first_sign=next(i for i,s in enumerate(steps) if '--sign' in s.get('argv',[]))
        presign=next(i for i,s in enumerate(steps) if 'LC_RPATH' in s.get('gate',''))
        self.assertLess(presign,first_sign)
        outer=max(i for i,s in enumerate(steps) if '--sign' in s.get('argv',[]))
        verify=next(i for i,s in enumerate(steps) if s.get('argv',[''])[0]=='python3' and 'verify' in s['argv'])
        self.assertLess(outer,verify)
        self.assertIn('developer-id',steps[verify]['argv'])
        notary=next(i for i,s in enumerate(steps) if 'notarytool' in s.get('argv',[]))
        self.assertLess(verify,notary)
        self.assertTrue(any('4b87cd4e80280eb7a2fc8dee7d50bf5fb534f6f73f172343bc16dcfe36a1a9af' in r for r in value['requires']))
        dmg=next(s['argv'] for s in steps if s.get('argv',[''])[0]=='python3' and 'dmg' in s['argv'])
        self.assertLess(steps.index(next(s for s in steps if s.get('argv')==['xcrun','stapler','staple',str(self.root.resolve()/'new/DayDream.app')])),
                        steps.index(next(s for s in steps if s.get('argv')==dmg)))

    def test_download_name_and_checksum_after_staple(self):
        # Item 31: the download is DayDream-<version>.dmg and its SHA-256 is taken only after
        # the DMG is stapled (stapling changes the file).
        steps=signing_plan.plan(self.app,self.root/'new')['steps']
        dmg=str(self.root.resolve()/'new/DayDream-0.1.0.dmg')
        argvs=[s.get('argv',[]) for s in steps]
        build=next(i for i,a in enumerate(argvs) if a[:1]==['python3'] and 'dmg' in a)
        self.assertEqual(argvs[build][argvs[build].index('--out')+1],dmg)
        staple=argvs.index(['xcrun','stapler','staple',dmg])
        validate=argvs.index(['xcrun','stapler','validate',dmg])
        checksum=next(i for i,a in enumerate(argvs) if 'checksum' in a)
        notes=next(i for i,a in enumerate(argvs) if 'notes' in a)
        self.assertLess(staple,validate);self.assertLess(validate,checksum);self.assertLess(checksum,notes)
        self.assertEqual(argvs[checksum][-1],dmg)
        self.assertFalse(any('shasum' in ' '.join(a) for a in argvs[:staple]))
    def test_update_archive_signed_with_key_file_never_keychain(self):
        argvs=[s.get('argv',[]) for s in signing_plan.plan(self.app,self.root/'new')['steps']]
        prepare=next(a for a in argvs if 'prepare' in a)
        self.assertIn('--key-file',prepare)
        self.assertEqual(Path(prepare[prepare.index('--key-file')+1]),release.KEY_FILE)
        self.assertEqual(release.KEY_FILE,Path.home()/'DayDream-keys/sparkle-ed25519.key')
        self.assertFalse(any('keychain' in x.lower() for x in prepare),prepare)
        for a in argvs:
            self.assertNotIn('--account',a)
            self.assertNotEqual(a[:1],['security'])

    def test_no_overwrite_or_nested_stage(self):
        for stage in [self.root,self.app,self.app/'new']:
            with self.assertRaises(ValueError):signing_plan.plan(self.app,stage)
    def test_private_payload_rejected(self):
        p=self.app/'Contents/Resources';p.mkdir();(p/'history.sqlite').write_bytes(b'fixture')
        with self.assertRaises(ValueError):signing_plan.plan(self.app,self.root/'new')
    def test_missing_helper_rejected(self):
        (self.app/'Contents/MacOS/mac-mem-backup').unlink()
        with self.assertRaises(ValueError):signing_plan.plan(self.app,self.root/'new')

    def test_bundled_node_or_remote_bridge_rejected(self):
        # The public build bundles neither a Node runtime nor the remote bridge.
        # The release audit rejects each one before any signing step is planned.
        contents=self.app/'Contents'
        for relative in ['MacOS/daydream-node','Resources/Node-LICENSE.txt','Resources/RemoteBridge/component-manifest.json',
                         'Resources/ConnectionAvailability.json','Resources/horizon-host.example.json','Resources/PROVENANCE.md']:
            path=contents/relative;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(b'synthetic')
            with self.assertRaisesRegex(ValueError,'Unexpected release payload'):
                signing_plan.plan(self.app,self.root/'new')
            path.unlink()
        self.assertFalse((self.root/'new').exists())

    def test_symlink_stage_alias_rejected(self):
        alias=self.root/'alias';alias.symlink_to(self.app,target_is_directory=True)
        with self.assertRaises(ValueError):signing_plan.plan(self.app,alias/'new')

if __name__=='__main__':unittest.main()
