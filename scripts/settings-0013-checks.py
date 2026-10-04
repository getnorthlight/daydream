from pathlib import Path
import unittest
r=Path(__file__).resolve().parents[1]
def read(p): return (r/p).read_text()
class Checks(unittest.TestCase):
    def test_sheet_not_window(self):
        s=read('Sources/MacMemApp/MacMemApp.swift')
        self.assertIn('.sheet(isPresented:$model.settingsPresented)',s)
        self.assertNotIn('Window("Settings",id:"settings")',s)
        # Esc and Return now close the sheet from its frame (plan §6), not a Cancel button in MacMemApp: the sheet mounts
        # MemorySettings, whose DaydreamSettingsFrame takes Esc as onExitCommand and Return as Done. Behaviour:
        # settings-hub-checks ("Done dismisses from every overview and detail state"; Return) and
        # dd-status-surfaces-safety-checks (Return closes once; Esc calls nothing else). SwiftUI's onExitCommand does
        # not fire offscreen, so this source pin is the Esc guarantee until on-screen QA.
        self.assertIn('MemorySettings(model:model,height:',s.split('.sheet(isPresented:$model.settingsPresented)',1)[1].split('}',1)[0])
        self.assertIn('DaydreamSettingsFrame(',read('Sources/MacMemApp/DaydreamSettings.swift'))
        frame=read('Sources/MemoryUI/SettingsHub.swift').split('public struct DaydreamSettingsFrame',1)[1].split('\n}\n',1)[0]
        # sat5: Esc closes Settings from every page (Back keeps ⌘[), and a click on the window behind closes it too.
        self.assertIn('.onExitCommand(perform: close)',frame)
        self.assertNotIn('back ?? close',frame)
        self.assertIn('.background(SettingsSheetOutsideClick(close: close))',frame)
        self.assertIn('if let back { SettingsBackButton(action: back)',frame)
        self.assertIn('Button("Done", action: close)',frame)
        self.assertIn('.keyboardShortcut(.defaultAction)',frame.split('Button("Done", action: close)',1)[1].split('}',1)[0])
    # test_dimensions is retired (plan §6): it pinned the retired 460 pt MemoryShell card (`frame(width:460`,
    # `padding(30)`). Window geometry is covered by check-main-layout and window-viewport-checks.
    def test_toggle_real_result(self):
        s=read('Sources/MemoryUI/CaptureControls.swift')
        self.assertIn('get:{state.recording}',s)
        self.assertIn('if state.canResume {actions.resume()}',s)
        self.assertIn('else if state.recording {actions.pause(0)}',s)
    def test_persistence_block_is_explicit(self):
        s=read('Sources/MemoryUI/AppExclusions.swift')
        self.assertIn('persistenceAvailable:Bool=false',s)
        self.assertIn('enabled:!mandatory && persistenceAvailable',s)
        self.assertNotIn('Button("Save',s)
        self.assertIn('frame(height:220)',s)
        # sat/v1: website typing isn't in this build; the rows say so plainly, never "not yet".
        self.assertIn('Not recorded in this version',s)
        self.assertNotIn('Not yet available',s)
        self.assertNotIn('not yet available',s)
    def test_chrome_pages_names(self):
        # Chrome page history: the Settings card and the setup header say "Web pages in Chrome"; the legacy
        # persistence block above says "Not recorded in this version".
        self.assertIn('public static let title = "Web pages in Chrome"',read('Sources/MemoryUI/ChromePagesSettings.swift'))
        setup=read('Sources/MemoryUI/SetupView.swift')
        # ux/declutter: Settings › Advanced (SetupView) no longer repeats the browsers card; the name is said once,
        # on Settings › Apps to remember.
        self.assertNotIn('browsersTitle',setup)
        self.assertNotIn('Web pages in Chrome',setup)
        self.assertNotIn('Browser capture unavailable',setup)
        self.assertIn('Not recorded in this version',read('Sources/MemoryUI/AppExclusions.swift'))
    def test_controls_semantics(self):
        s=read('Sources/MemoryUI/ReferenceControls.swift')
        for token in ['frame(width:26,height:16)','frame(width:40,height:32)','accessibilityRepresentation','accessibilityReduceMotion','focused($focused)']:
            self.assertIn(token,s)
    def test_no_example_size_or_key_blur_activation(self):
        s=read('Sources/MacMemApp/WriterPreferences.swift')
        # fix/setup-status: the size is setup's and Settings' shared line (DaydreamOnboarding.modelSize), and the cloud
        # disclosure is accepted inside WriterIntegration.chooseCloud (the switch's one honest line).
        onboarding=read('Sources/MacMemApp/DaydreamOnboarding.swift')
        integration=read('Sources/MacMemApp/WriterIntegration.swift')
        self.assertIn('static var modelSize: String { SummaryPhaseReading.gigabytes(WriterCandidates.recommended?.asset.bytes',onboarding)
        for text in (s,onboarding):
            self.assertNotIn('2.1 GB',text)
            self.assertNotIn('"Connected"',text)
        self.assertIn('enableCloud(acceptedDisclosureVersion:Self.cloudDisclosureVersion)',integration)
        self.assertNotIn('.onSubmit',s)
unittest.main()
