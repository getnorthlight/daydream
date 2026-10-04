"""Inert tests on a SYNTHETIC enrolled-writer fixture; no runtime/key use.

The private trial (Typesense + FunctionalTrial.json) and the public "On this Mac" runtime are two policies
(owner decision 2026-09-26): writer_payload.py covers the runtime every release carries; functional_payload.py
applies only to an app with the trial's own pieces, and each never claims the other's app.

The original fixture copied the enrolled bytes from
/private/tmp/daydream-functional-release-WM046P, which no longer exists (/private/tmp is
cleared at boot), so setUp failed with FileNotFoundError. The synthetic manifest has the
enrolled shape (the seven named dylibs with signedBytes/signedSHA256/signingIdentifier) and
functional_payload.MANIFEST_HASH is patched to its digest for each test. These checks
therefore exercise the payload POLICY. The byte-exact enrollment itself stays pinned in
functional_payload.MANIFEST_HASH and WriterBackend SignedRuntimePolicy.swift:36-38.
"""
import hashlib
import json
import unittest
from unittest.mock import patch
from check_signing_plan import SigningPlanChecks
import functional_payload as f
import release
import signing_plan
import writer_payload

WRITER_NAMES = ['libllama.0.dylib', 'libggml.0.dylib', 'libggml-base.0.dylib', 'libggml-cpu.0.dylib',
                'libggml-metal.0.dylib', 'libggml-blas.0.dylib', 'libggml-rpc.0.dylib']

class FunctionalChecks(SigningPlanChecks):
    # Only run tests defined here, not inherited legacy fixture tests.
    def setUp(self):
        super().setUp()
        self.root=self.root.resolve()
        self.app=self.app.resolve()
        c=self.app/'Contents'
        self.info.update(CFBundleVersion='1',CFBundleShortVersionString='0.1.0')
        self.save()
        (c/f.LIBROOT).mkdir(parents=True)
        rows=[]
        for name in WRITER_NAMES:
            data=('synthetic signed '+name).encode()
            (c/f.LIBROOT/name).write_bytes(data)
            rows.append({'name':name,'signedBytes':len(data),'signedSHA256':hashlib.sha256(data).hexdigest(),
                         'signingIdentifier':'com.daydream.writer.'+name.split('.')[0]})
        manifest=json.dumps({'schema':'daydream-signed-runtime/macos15-v2','distributionID':f.ID,'files':rows},sort_keys=True).encode()
        (c/f.MANIFEST).parent.mkdir(parents=True)
        (c/f.MANIFEST).write_bytes(manifest)
        patcher=patch.object(f,'MANIFEST_HASH',hashlib.sha256(manifest).hexdigest())
        patcher.start()
        self.addCleanup(patcher.stop)
        (c/'Helpers').mkdir()
        (c/f.SERVER).write_bytes(b'synthetic server')
        for name in f.NOTICES: (c/name).write_text('synthetic')
        (c/'Resources/FunctionalTrial.json').write_text(json.dumps({'scope':'private-same-owner-self-use','publicDistribution':False,'completeCorrespondingSource':False}))
        (c/'Resources/before_turn.py').write_text('synthetic')
        f.refresh(self.app)

    def test_payload_hashes(self):
        release.audit(self.app)
        release.manifest(self.app)
        f.verify_search(self.app)
        (self.app/'Contents'/f.LIBROOT/'libllama.0.dylib').write_bytes(b'tamper')
        with self.assertRaisesRegex(ValueError,'writer bytes changed'): release.audit(self.app)

    def test_unreviewed_manifest_refused(self):
        with patch.object(f,'MANIFEST_HASH','0'*64):
            with self.assertRaisesRegex(ValueError,'unreviewed enrolled writer manifest'): release.audit(self.app)

    def test_exact_allowlist(self):
        (self.app/'Contents/Helpers/unapproved').write_text('x')
        with self.assertRaisesRegex(ValueError,'Unexpected release payload'): release.audit(self.app)

    def test_private_not_public(self):
        with self.assertRaisesRegex(ValueError,'not cleared for public'): release.prepare(self.app,{},None,0,None,False)

    def test_trial_is_not_the_public_runtime(self):
        # The trial app is functional_payload's alone: writer_payload never claims it.
        self.assertFalse(writer_payload.present(self.app))
        self.assertEqual(writer_payload.paths(self.app), set())
        self.assertTrue(f.paths(self.app))

    def test_public_runtime_alone_is_not_the_trial(self):
        # An app with only a writer runtime (what every release carries) is never treated as the private
        # trial: no Typesense, no FunctionalTrial.json, so functional_payload stays out of it.
        c=self.app/'Contents'
        for name in [f.SERVER,f.SEARCH,*f.NOTICES,f.MANIFEST]:
            (c/name).unlink(missing_ok=True)
        (c/'Frameworks/WriterRuntime').rename(c/'Frameworks/Other')
        (c/'Frameworks/WriterRuntime').mkdir()
        (c/'Frameworks/Other').rename(c/writer_payload.LIBROOT)
        self.assertEqual(f.paths(self.app), set())
        self.assertTrue(writer_payload.present(self.app))
        # ...and writer_payload then checks it strictly: this synthetic set is not pinned.
        with self.assertRaisesRegex(ValueError,'Writer runtime needs Info.plist|not pinned|must hold exactly'):
            writer_payload.paths(self.app)

    def test_functional_plan_preserves_writer_sparkle(self):
        original=f.digest
        with patch.object(f,'digest',side_effect=lambda p: '086d498fbf0afb45091f4e28b50e803a3633daac506388a5f71e5ed90407c91f' if str(p).endswith(f.SERVER) else original(p)):
            result=signing_plan.plan(self.app,self.root/'sign-copy')
        commands=[s['argv'] for s in result['steps'] if 'argv' in s]
        signs=[x for x in commands if x[0]=='codesign' and '--sign' in x]
        # RECONCILED with check_signing_plan.py (5 Sparkle signs, inside-out): the old
        # expectation here (4 signs, no Sparkle) predates Sparkle re-signing and contradicted
        # the plan. Functional = 5 Sparkle + typesense + mac-mem + mac-mem-backup + outer.
        self.assertEqual(len(signs),9)
        sparkle=[x for x in signs if '/Sparkle.framework' in x[-1]]
        self.assertEqual(len(sparkle),5)
        self.assertEqual(signs[:5],sparkle)
        # Enrolled writer dylibs are never re-signed; each is verified in place.
        self.assertFalse(any('WriterRuntime' in x[-1] for x in signs))
        verified=[x for x in commands if x[:3]==['codesign','--verify','--strict'] and 'WriterRuntime' in x[-1]]
        self.assertEqual(sorted(x[-1].rsplit('/',1)[-1] for x in verified),sorted(WRITER_NAMES))
        server=next(x for x in signs if x[-1].endswith(f.SERVER))
        self.assertEqual(server[server.index('--identifier')+1],'com.getnorthlight.daydream.typesense-server')
        self.assertNotIn('--entitlements',server)
        self.assertLess(commands.index(verified[-1]),commands.index(server))
        self.assertTrue(signs[-1][-1].endswith('DayDream.app'))

if __name__=='__main__':
    suite=unittest.TestSuite(FunctionalChecks(n) for n in FunctionalChecks.__dict__ if n.startswith('test_'))
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())
