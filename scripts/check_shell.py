"""Source wiring checks complement fake-clock and native-view tests. No capture."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class ShellChecks(unittest.TestCase):
    def test_resume_callback_gates(self):
        source=(ROOT/'Sources/MacMemApp/MacMemApp.swift').read_text()
        callback=source.split('private func armTimedPause(',1)[1].split('func stopCapture',1)[0]
        # gold/save-path (G33): the deadline's permission read is settled like recording's own (one false read is not a loss);
        # gold/lifecycle: with no recorder it falls back to the checks' substitutable read.
        for term in ['self.timedPause.ticket == ticket','self.resumeBlocker() == nil','permitted:self.coordinator?.permittedSettled() ?? Self.permissionsGranted()','self.cancelTimedPause()']:
            self.assertIn(term,callback)
        # gold/int final review (G33): the resume goes through automaticStart (startCapture, holding for a moment's
        # "not allowed"), after the ticket is cancelled.
        self.assertLess(callback.index('self.cancelTimedPause()'),callback.index('self.timedPauseEnded()'))
        self.assertIn('automaticStart(again:{ [weak self] in self?.timedPauseEnded() })',callback)
        # Saturday test issue 11: the pause ends by itself whichever app is in front (events are filtered as
        # they are recorded, as after Resume), and an open menu doesn't hold the timer back.
        self.assertNotIn('safeForTimedResume',callback)
        self.assertNotIn('safeFocus',callback)
        self.assertIn('RunLoop.main.add(timer,forMode:.common)',callback)
        self.assertNotIn('Timer.scheduledTimer',callback)
    def test_cancellation_paths(self):
        source=(ROOT/'Sources/MacMemApp/MacMemApp.swift').read_text()
        # Owner decision 6 (SPEC 6.3 R1): sleep, screen lock and a user switch pause through the wake rules
        # (WakeResume.swift); waking, unlocking and switching back resume only what was on. Quitting pauses.
        for event,call in [('willSleepNotification','self?.suspend(.sleep)'),('didWakeNotification','self?.unsuspend(.sleep)'),
                           ('sessionDidResignActiveNotification','self?.suspend(.userSwitch)'),('sessionDidBecomeActiveNotification','self?.unsuspend(.userSwitch)'),
                           ('willTerminateNotification','pauseCapture(')]:
            handler=source.split(event,1)[1].split('})',1)[0]
            self.assertIn(call,handler)
        # fix/lock-resume: the lock and unlock come through ScreenLockObserver, delivered immediately (the block
        # observers' default suspension behavior held them while DayDream was in the background).
        lock=source.split('lockObserver=ScreenLockObserver(',1)[1].split('observers.append',1)[0]
        self.assertIn('self?.suspend(.screenLock)',lock.split('locked:',1)[1].split('unlocked:',1)[0])
        self.assertIn('self?.unsuspend(.screenLock)',lock.split('unlocked:',1)[1])
        self.assertNotIn('addObserver(forName:WakeSystem.screen',source)
        wake=(ROOT/'Sources/MacMemApp/WakeSystem.swift').read_text()
        self.assertEqual(wake.count('suspensionBehavior: .deliverImmediately'),2)
        suspend=source.split('func suspend(_ suspension:WakeSuspension)',1)[1].split('func unsuspend',1)[0]
        self.assertIn('wake.begin(',suspend)
        run=source.split('private func runWake(',1)[1].split('private func wakeSettled',1)[0]
        self.assertIn('withStopIntent(.suspension) { pauseCapture(suspension.pauseReason,commitTyping:true) }',run)
        self.assertIn('cancelTimedPause()',source.split('func startCapture()',1)[1].split('func pauseCapture',1)[0])
        self.assertIn('cancelTimedPause()',source.split('func stopCapture()',1)[1].split('func startCapture',1)[0])
        self.assertIn('model.cancelTimedPause()',(ROOT/'Sources/MacMemApp/ReplacementControls.swift').read_text())
    def test_no_real_demo_import_or_fixed_sheet(self):
        source=(ROOT/'Sources/MacMemApp/MacMemApp.swift').read_text()
        self.assertNotIn('SyntheticActivity.records()',source)
        self.assertIn('struct SyntheticWindow',source)
        # Settings is the one sheet (plan §6 L5: no Settings window or scene). ux/perms: 720 wide, at most 540 tall and
        # never taller than its window (DaydreamSettingsLayout).
        self.assertEqual(source.count('.sheet('),1)
        self.assertIn('.sheet(isPresented:$model.settingsPresented)',source)
        self.assertNotIn('Window("Settings"',source)
        self.assertIn('MemorySettings(model:model,height:DaydreamSettingsLayout.height(windowContentHeight:contentHeight))',source)
        self.assertNotIn('650,height:650',(ROOT/'Sources/MemoryUI/SetupView.swift').read_text())
    def test_timed_resume_uses_existing_privacy_filter(self):
        # The resume starts through startCapture, the same path as Resume; every event it records then passes
        # CaptureSession.accepts in Coordinator.record, so no separate focus check gates the resume.
        source=(ROOT/'Sources/MacMemApp/Coordinator.swift').read_text()
        self.assertNotIn('func safeForTimedResume',source)
        record=source.split('func record(kind: HistoryEventKind',1)[1].split('\n    }\n',1)[0]
        self.assertIn('accepts(snapshot)',record)
        self.assertIn('CaptureSession.accepts',source.split('func accepts(_ snap: AccessibilitySnapshot?)',1)[1].split('func acceptsTyping',1)[0])
if __name__=='__main__': unittest.main()
