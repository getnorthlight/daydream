"""Actual shell switching with disposable fake downloads; never SSH or app launch."""
from pathlib import Path
import tempfile,subprocess,plistlib,hashlib,unittest,os
SCRIPT=Path(__file__).with_name('daydream-dev-refresh.command')
class RefreshChecks(unittest.TestCase):
 def setUp(self):
  self.root=Path(tempfile.mkdtemp(prefix='daydream-dev-refresh-check-',dir='/private/tmp'));self.base=self.root/'owned';self.remote=self.root/'remote';self.remote.mkdir()
  self.make('20260913-010101')
 def make(self,version,identity='com.getnorthlight.daydream.development'):
  stage=self.root/version;app=stage/'Daydream Dev.app';(app/'Contents/MacOS').mkdir(parents=True)
  (app/'Contents/MacOS/MacMem').write_bytes(b'synthetic executable, never run '+version.encode())
  (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':identity,'DaydreamDevelopmentTrial':True,'SUAutomaticallyUpdate':False,'SUEnableAutomaticChecks':False}))
  zip=self.remote/('Daydream-Dev-'+version+'.zip');subprocess.run(['ditto','-c','-k','--keepParent',str(app),str(zip)],check=True)
  sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
  (self.remote/'latest.plist').write_bytes(plistlib.dumps({'version':version,'archiveSHA256':sha(zip),'executableSHA256':sha(app/'Contents/MacOS/MacMem')}))
 def run_refresh(self,mode='refresh',failure=''):
  # Only transport, signature and process operations are mocked. Identity,
  # hashing, ZIP extraction and actual pointer/rollback logic are production.
  code='source "$1"\nfetch(){ cp "$4/$1" "$2"; }\n'
  code='source "$1"\nfixture="$3"\nfetch(){ cp "$fixture/$1" "$2"; }\nverify_seal(){ :; }\nquit_dev(){ printf "%s\\n" "$1" >> "$fixture/quit.log"; }\nopen_dev(){ :; }\n'
  if failure=='offline':code+='fetch(){ return 8; }\n'
  if failure=='open':code+='open_dev(){ return 9; }\n'
  code+='refresh "$2" "$4"\n'
  return subprocess.run(['/bin/bash','-c',code,'fixture',str(SCRIPT),str(self.base),str(self.remote),mode],capture_output=True,text=True)
 def current(self):return (self.base/'current').read_text().strip()
 def test_success_and_rollback(self):
  self.assertEqual(self.run_refresh().returncode,0);self.make('20260913-020202');self.assertEqual(self.run_refresh().returncode,0)
  self.assertEqual(self.current(),'20260913-020202');self.assertEqual(self.run_refresh('--rollback').returncode,0);self.assertEqual(self.current(),'20260913-010101')
  self.assertTrue((self.base/'versions/20260913-020202/Daydream Dev.app').exists())
 def test_unavailable_mini(self):
  self.assertEqual(self.run_refresh().returncode,0);self.assertNotEqual(self.run_refresh(failure='offline').returncode,0);self.assertEqual(self.current(),'20260913-010101')
 def test_corrupt_incomplete_download(self):
  self.assertEqual(self.run_refresh().returncode,0);self.make('20260913-020202');(self.remote/'Daydream-Dev-20260913-020202.zip').write_bytes(b'partial')
  self.assertNotEqual(self.run_refresh().returncode,0);self.assertEqual(self.current(),'20260913-010101')
 def test_production_identity_rejected(self):
  self.assertEqual(self.run_refresh().returncode,0);self.make('20260913-020202','com.getnorthlight.daydream')
  self.assertNotEqual(self.run_refresh().returncode,0);self.assertEqual(self.current(),'20260913-010101')
 def test_open_failure_restores_pointer(self):
  self.assertEqual(self.run_refresh().returncode,0);self.make('20260913-020202')
  self.assertNotEqual(self.run_refresh(failure='open').returncode,0);self.assertEqual(self.current(),'20260913-010101')
 def test_unowned_destination(self):
  self.base.mkdir();(self.base/'personal').write_text('keep')
  self.assertNotEqual(self.run_refresh().returncode,0);self.assertEqual((self.base/'personal').read_text(),'keep')
 def test_production_quit_never_targeted(self):
  self.assertEqual(self.run_refresh().returncode,0);self.assertEqual(self.run_refresh().returncode,0)
  targets=(self.remote/'quit.log').read_text().splitlines();self.assertTrue(all(t.startswith(str(self.base/'versions')) and t.endswith('/Daydream Dev.app') for t in targets))
if __name__=='__main__':unittest.main()
