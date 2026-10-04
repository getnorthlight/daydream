from pathlib import Path
import re
import unittest

root=Path(__file__).resolve().parents[1]
app=(root/'Sources/MacMemApp/MacMemApp.swift').read_text()
launch=(root/'Sources/MacMemApp/DaydreamLaunchSession.swift').read_text()
ui=(root/'Sources/MacMemApp/RecordingTrialReadiness.swift').read_text()
permissions=(root/'Sources/MemoryUI/PermissionSetup.swift').read_text()
class Wiring(unittest.TestCase):
    def test_dev_precedes_normal(self):
        self.assertLess(launch.index('if development {'),launch.index('let recordingTrial='))
        self.assertIn('self.recordingTrial=recordingTrial && development == nil',app)
    def test_off_before_start(self):
        self.assertIn('@Published var recording = false',app)
        self.assertIn('if development != nil || recordingTrial {',app)
        self.assertIn('automaticallySyncSearch:development == nil && !recordingTrial',app)
        self.assertIn('guard development == nil,!recordingTrial else {return}',app)
        self.assertIn('development == nil,!recordingTrial,backups.prepared == nil',app)
    def test_real_coexistence_retained(self):
        self.assertIn('InstallationReview.legacy(at:FileManager.default.homeDirectoryForCurrentUser)',app)
        self.assertIn('guard try replacement?.permitsStart() == true',app)
    def test_explicit_permission_only(self):
        self.assertNotIn('AXIsProcessTrustedWithOptions',ui)
        self.assertNotIn('CGRequestListenEventAccess',ui)
        # The trial mounts the shared permission card; granting happens only in System Settings (plan section 6).
        self.assertIn('RecordingPermissionSetup(enabled: model.development == nil, onRefresh: refresh)',ui)
        self.assertNotIn('AXIsProcessTrustedWithOptions',permissions)
        self.assertNotIn('CGRequestListenEventAccess',permissions)
        # Each missing card's button opens its own pane (ux/perms: the label is OpenSystemSettingsLabel).
        self.assertIn('Button { open(permission) } label: { OpenSystemSettingsLabel() }',permissions)
        self.assertIn('Text("Open System Settings")',permissions)
        self.assertIn('granted = AXIsProcessTrusted() && CGPreflightListenEventAccess()',permissions)
    def test_proof_no_seed_or_summary(self):
        self.assertNotIn('SyntheticActivity',ui)
        self.assertIn('latest.description',ui)
        self.assertIn('coordinator.nativeReceipts.validated(store:store,now:now)',app)
        self.assertIn('latest = try model.trialSavedAction()',ui)
        self.assertIn('No activity saved in this recording trial yet.',ui)
    def test_no_launch_start(self):
        self.assertNotIn('startCapture()',launch)
        self.assertRegex(ui,r'Button\s*\{\s*model\.startCapture\(\);\s*refresh\(\)\s*\}\s*label:\s*\{\s*Label\("Start Recording"')
        self.assertEqual(len(re.findall(r'model\.startCapture\(\)',ui)),1)
        self.assertIn('guard !privacyDirty',app)
unittest.main()
