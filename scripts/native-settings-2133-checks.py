"""Read-only UI wiring checks; not runtime capture/provider acceptance."""
from pathlib import Path
import re
import unittest
ROOT=Path(__file__).resolve().parents[1]
class NativeSettingsChecks(unittest.TestCase):
    def text(self,path): return (ROOT/path).read_text()
    def test_memory_shell_is_quiet(self):
        # The window's recording status and settings gear live in the toolbar (DaydreamToolbar.swift, header-A);
        # MemoryShell only mounts the toolbar above the day, never a status control, issue paragraph or corner overlay.
        # Behaviour: dd-status-checks (exactly one memory-settings control; the gear calls settings once and no capture
        # action) and dd-focus-list-checks (the footer is hints only: no Pause, no recording status).
        s=self.text('Sources/MemoryUI/MemoryShell.swift')
        self.assertNotIn('CaptureControls(',s)
        self.assertNotIn('Text(issue)',s)
        self.assertNotIn('.overlay(alignment:.bottomLeading)',s)
        self.assertIn('CanonicalTimeline(browser:',s)
        self.assertLess(s.index('DaydreamToolbarRow('),s.index('CanonicalTimeline('))
        self.assertIn('.daydreamWindowToolbar(',s)
        toolbar=self.text('Sources/MemoryUI/DaydreamToolbar.swift')
        self.assertEqual(toolbar.count('.accessibilityIdentifier("memory-settings")'),1)
        kit=self.text('Sources/MemoryUI/DaydreamKitPrimitives.swift')
        hints=kit.split('public struct KeyHintBar',1)[1].split('\npublic struct',1)[0]
        self.assertRegex(hints,r'\.frame\(height:\s*28\)')
    # test_persistent_sidebar is retired (plan §6): Settings is the grouped overview with pushed pages, not a
    # persistent `List(selection:)` sidebar. Its navigation is covered by settings-hub-checks (every route opens its
    # page, Back returns to the overview, Return is Done from every overview and detail state).
    def test_exclusions_have_one_scroll_owner(self):
        s=self.text('Sources/MemoryUI/AppExclusions.swift')
        self.assertIn('.frame(height:220)',s)
        self.assertIn('PrivacySettings.sensitiveApps',s)
        self.assertIn('.disabled(!allowTyping || !persistenceAvailable)',s)
    def test_no_provider_preselection_or_development_activation(self):
        s=self.text('Sources/MacMemApp/WriterPreferences.swift')
        self.assertIn('initialMode:String=""',s)
        self.assertIn('guard available,!working,mayChange()',s)
        self.assertIn('guard permitted else{return}',s)
        self.assertIn('available && mayChange()',s)
        self.assertIn('CloudSummariesSwitch(isOn:cloudSwitch',s)
        self.assertNotIn('Processed Using ZDR Endpoints',s)
        self.assertIn('acceptedDisclosureVersion:WriterIntegration.cloudDisclosureVersion',s)
        self.assertIn('.onDisappear {awaitingInstall=false;key="";pendingCloud=false}',s)
    def test_app_retains_development_gate(self):
        # The settings pages moved from MacMemApp.swift to DaydreamSettings.swift (plan §6): the Development Trial
        # still can't change summaries, typed text or permissions there. Behaviour: dd-app-model-checks
        # ("development: …": Off with no dates, no open/exclude/generate routes, Start/Pause/Stop stay Off).
        s=self.text('Sources/MacMemApp/DaydreamSettings.swift')
        self.assertIn('available: model.development == nil)',s)
        self.assertIn('allowTyping: model.development == nil',s)
        self.assertIn('PermissionGrantView(enabled: model.development == nil',s)
        self.assertRegex(s,r'mayChange: \{\s*model\.development == nil &&')
        for path in sorted((ROOT/'Sources/MacMemApp').glob('*.swift')):
            self.assertIsNone(re.search(r'fixtures:\s*model\.development\s*==\s*nil\s*\?\s*nil',path.read_text()),path.name)
    def test_menu_width_does_not_follow_error_paragraph(self):
        # The Recording menu rows (MenuBarRecordingMenu) carry no issue text, so an error paragraph can't set a menu's
        # width. Behaviour: dd-menubar-checks (the panel is 320 pt in every state) and MacMemUIRender --whole (every
        # state's rows fit under 320 pt with a long issue, and the native menu does).
        s=self.text('Sources/MemoryUI/MenuBarRecordingMenu.swift')
        self.assertIn('public struct MenuBarRecordingMenu',s)
        self.assertNotIn('Text(issue',s)
        self.assertNotIn('.issue',s)
if __name__=='__main__':unittest.main()
