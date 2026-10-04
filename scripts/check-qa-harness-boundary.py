"""No app execution/build/sign/input: explicit stage choice and QA source boundary controls."""
import importlib.util,sys,unittest
from pathlib import Path
S=Path(__file__).resolve().parent;sys.path.insert(0,str(S))
spec=importlib.util.spec_from_file_location('qa_release',S/'developer-id-release.py');dr=importlib.util.module_from_spec(spec);spec.loader.exec_module(dr)
class QABoundary(unittest.TestCase):
 def test_cli_flag_defaults_and_opt_in(self):
  base=['stage','--out','/private/tmp/unused-stage','--build','20261001090000','--first-build']
  normal=dr.build_parser().parse_args(base)
  owner=dr.build_parser().parse_args(base+['--owner-build','--updates','off'])
  private=dr.build_parser().parse_args(base+['--owner-build','--updates','off','--qa-harness'])
  self.assertFalse(normal.qa_harness);self.assertFalse(owner.qa_harness);self.assertTrue(private.qa_harness)
  self.assertNotIn('-DDAYDREAM_QA_HARNESS',dr.stage_swift_flags(owner.owner_build,owner.updates,owner.qa_harness))
  self.assertIn('-DDAYDREAM_QA_HARNESS',dr.stage_swift_flags(private.owner_build,private.updates,private.qa_harness))
 def test_normal_public_flags_unchanged(self):self.assertEqual(dr.stage_swift_flags(False,'configured'),dr.OWNER_SWIFT_FLAGS)
 def test_normal_owner_flags_unchanged(self):self.assertEqual(dr.stage_swift_flags(True,'off'),dr.OWNER_SWIFT_FLAGS)
 def test_explicit_private_flags(self):self.assertEqual(dr.stage_swift_flags(True,'off',True),dr.OWNER_SWIFT_FLAGS+dr.QA_SWIFT_FLAGS)
 def test_public_qa_refuses(self):
  with self.assertRaises(dr.ReleaseError):dr.stage_swift_flags(False,'off',True)
 def test_qa_updates_refuse(self):
  with self.assertRaises(dr.ReleaseError):dr.stage_swift_flags(True,'configured',True)
 def test_normal_package_clean(self):self.assertEqual(dr.qa_harness_problems({},b'WebTypingRoute'),[])
 def test_normal_owner_package_clean(self):self.assertEqual(dr.qa_harness_problems({'MacMemOwnerTyping':True},b'WebTypingRoute'),[])
 def test_normal_marker_any_value_refuses(self):
  for v in [True,False,None]:self.assertTrue(dr.qa_harness_problems({dr.QA_PLIST_KEY:v},b''))
 def test_normal_route_or_window_refuses(self):
  for b in dr.QA_BINARY_MARKS:self.assertTrue(dr.qa_harness_problems({},b))
 def test_private_exact_package(self):self.assertEqual(dr.qa_harness_problems({dr.QA_PLIST_KEY:True,'MacMemOwnerTyping':True},b'--capture-fixture-trial',True),[])
 def test_private_missing_flag_refuses(self):self.assertTrue(dr.qa_harness_problems({dr.QA_PLIST_KEY:True,'MacMemOwnerTyping':True},b'',True))
 def test_private_missing_identity_refuses(self):
  for info in [{},{dr.QA_PLIST_KEY:True},{'MacMemOwnerTyping':True}]:self.assertTrue(dr.qa_harness_problems(info,b'--capture-fixture-trial',True))
 def test_all_known_helpers_guarded(self):
  root=S.parent/'Sources/MacMemApp'
  names=['CaptureFixtureTrial.swift','CaptureBrowserFixtureTrial.swift','BrowserFixtureEmptyGate.swift','CaptureChromeFrontInspection.swift','CaptureChromeAutomationRequest.swift','CaptureChromeAutomationRequestUI.swift','ChromeAutomationRequestControls.swift','ChromeFrontInspectionControls.swift','ChromeNormalMainProbe.swift']
  for n in names:self.assertIn('#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING',(root/n).read_text())
 def test_normal_entry_has_no_fixture_route(self):
  s=(S.parent/'Sources/MacMemApp/CaptureFixtureTrial.swift').read_text();entry=s[s.index('@main enum DaydreamApplicationEntry'):]
  self.assertIn('#else\n        MacMemApplication.main()\n        #endif',entry)
  self.assertIn('#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING\nenum CaptureFixtureLaunch',s)
 def test_private_self_auth_requires_package_marker(self):self.assertIn('Bundle.main.object(forInfoDictionaryKey: "DaydreamQAHarness") as? Bool == true',(S.parent/'Sources/MacMemApp/CaptureFixtureTrial.swift').read_text())
class LegacyQABoundary(unittest.TestCase):
 def test_normal_legacy_plist_any_value_refuses(self):
  for key in ['DaydreamRecordingTrial','DaydreamFunctionalTrial']:
   for v in [True,False,None,'yes',0]:self.assertTrue(dr.qa_harness_problems({key:v},b''))
 def test_normal_legacy_routes_are_independently_rejected(self):
  for marker in [b'--synthetic-trial-check',b'--synthetic-writer-check',b'--synthetic-writer-restart-check',b'--recording-trial',b'--functional-trial',b'Back to recording trial']:
   self.assertTrue(dr.qa_harness_problems({},b'prefix '+marker+b' suffix'))
 def test_guarded_legacy_helpers(self):
  root=S.parent/'Sources/MacMemApp'
  for name in ['PackagedHistoryChecks.swift','RecordingTrialReadiness.swift','RecordingTrialProof.swift','SignedWriterTrial.swift']:
   text=(root/name).read_text();self.assertTrue(text.startswith('#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING\n'));self.assertTrue(text.rstrip().endswith('#endif'))
  text=(root/'PackagedTrial.swift').read_text()
  self.assertLess(text.index('actor TrialForbiddenKeys'),text.index('#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING'))
  self.assertGreater(text.index('@MainActor enum PackagedTrial'),text.index('#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING'))
 def test_normal_launch_cannot_select_recording_or_functional(self):
  text=(S.parent/'Sources/MacMemApp/DaydreamLaunchSession.swift').read_text()
  self.assertIn('#else\n            let recordingTrial=false,functionalTrial=false\n            #endif',text)
 def test_product_preview_and_secure_key_denial_are_retained(self):
  root=S.parent/'Sources/MacMemApp'
  self.assertIn('preview=PreviewLaunch.requested',(root/'DaydreamLaunchSession.swift').read_text())
  self.assertIn('if development != nil {\n            noteWriter=WriterIntegration', (root/'MacMemApp.swift').read_text())
  self.assertIn('func readSecret() async throws -> String {throw WriterFailure.denied}',(root/'PackagedTrial.swift').read_text())
class SignedWriterQABoundary(unittest.TestCase):
 def test_signed_trial_normal_markers_refuse(self):
  for marker in [b'--signed-writer-acceptance','Signed writer acceptance · Recording OFF'.encode('utf-8')]:
   self.assertTrue(dr.qa_harness_problems({},marker))
 def test_signed_trial_normal_selector_disabled(self):
  text=(S.parent/'Sources/MacMemApp/DaydreamLaunchSession.swift').read_text()
  self.assertIn('#else\n        signedWriterAcceptance=false\n        #endif',text)
class SyntheticFallbackQABoundary(unittest.TestCase):
 def test_normal_no_model_uses_existing_preparing_view(self):
  text=(S.parent/'Sources/MacMemApp/MacMemApp.swift').read_text()
  self.assertIn('else {DaydreamPreparingWindow()}\n        #endif',text)
  self.assertIn('#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING\nstruct SyntheticWindow:View',text)
 def test_normal_isolated_selector_is_false(self):
  text=(S.parent/'Sources/MacMemApp/DaydreamLaunchSession.swift').read_text()
  self.assertIn('#else\n        isolated=false\n        #endif',text)
class ActualCodeMarkers(unittest.TestCase):
 def test_debug_filenames_are_not_runtime_routes(self):
  filenames=b'\0'.join(b'/Sources/MacMemApp/'+x+b'.swift' for x in dr.QA_SYMBOL_MARKS)
  self.assertEqual(dr.qa_harness_problems({},filenames),[])
  self.assertEqual(dr.qa_code_symbol_problems(filenames),[])
 def test_every_known_actual_symbol_fails_normal(self):
  for name in dr.QA_SYMBOL_MARKS:
   symbols=b'normal.o:\n_$s9MacMemApp'+name+b'V12runIfAskedyyF\n'
   self.assertTrue(dr.qa_code_symbol_problems(symbols))
   self.assertEqual(dr.qa_code_symbol_problems(symbols,True),[])
 def test_nm_headings_do_not_impersonate_symbols(self):
  for name in dr.QA_SYMBOL_MARKS:
   self.assertEqual(dr.qa_code_symbol_problems(b'/objects/'+name+b'.o:\n_sNormalProductionType\n'),[])
 def test_synthetic_routes_refuse_normal(self):
  for x in [b'--isolated-interactive-trial',b'Synthetic preview',b'Open synthetic preview']:
   self.assertTrue(dr.qa_harness_problems({},x))
class PrivateUIReviewRecipe(unittest.TestCase):
 def test_private_render_recipe_explicitly_opts_into_qa_owner(self):
  text=(S/'check-ui-revision.sh').read_text()
  commands=[line for line in text.splitlines() if line.startswith('swiftc ')]
  self.assertEqual(len(commands),2)
  for command in commands:
   for flag in ['DAYDREAM_QA_HARNESS','DAYDREAM_OWNER_TYPING','DAYDREAM_CHROME_TYPING']:
    self.assertIn('-D '+flag,command)
if __name__=='__main__':unittest.main()
