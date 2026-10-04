#!/usr/bin/env python3
"""The recording heartbeat and a summary job's completion on the main thread (golden test 5, perf-store stream).

MemoryViewModel opens its Keychain-backed typing vault when it is made, so its heartbeat is checked here as source
rules (store-main-thread-checks.swift checks TypingModel's part by running it, store-perf-checks.swift the store):
- G5: refreshCaptureStatus (every 0.5 s while recording) reads no history: no store.status() count.
- G14: a summary job's completion reloads nothing on the main thread (no refresh(): 1000 timeline rows).
- G14: Settings > Apps ranks apps from a timeline read off the main thread when it opens (recentUsage).
- G49: refreshCaptureStatus writes a published value only when it changed; permissionsCheckedAt is set once.
- G60: the local search supervisor retries a busy store instead of stopping.
- r2-store-perf: launch prepares the history (a damaged history's repair, the one-time time indexes, the owner build's
  website typing settle) off the main thread before the model exists (DaydreamLaunchSession), shows one calm line
  meanwhile, and the model's open doesn't repair again; launch's first timeline read is off the main thread.
  launch-preparation-checks.swift runs HistoryPreparation itself.
Nothing is built, launched or read from the Keychain here.
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


def read(rel):
    return (ROOT / rel).read_text()


def body(text, signature):
    """The body of the function declared by `signature` (brace matched)."""
    start = text.index(signature)
    open_at = text.index('{', start)
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[open_at + 1:i]
    raise AssertionError('unbalanced ' + signature)


APP = read('Sources/MacMemApp/MacMemApp.swift')


class Heartbeat(unittest.TestCase):
    def test_g5_the_heartbeat_reads_no_history(self):
        tick = body(APP, 'func refreshCaptureStatusBounded()')  # gold r3-store: the body (the wrapper bounds its waits)
        self.assertNotRegex(tick, r'\.status\(\)', 'refreshCaptureStatus counts pending summaries over the whole store every 0.5 s')
        self.assertNotRegex(tick, r'timeline\(', 'refreshCaptureStatus reads the timeline')

    def test_g49_published_values_are_written_only_when_changed(self):
        tick = body(APP, 'func refreshCaptureStatusBounded()')  # gold r3-store: the body (the wrapper bounds its waits)
        lines = [l.strip() for l in tick.splitlines() if not l.strip().startswith('if development != nil')]
        for name in ['recording', 'resumeUnavailable', 'status', 'operationalIssue']:
            for line in lines:
                if line.startswith('//'):
                    continue
                if re.search(r'(^|[;{\s])' + name + r'\s*(=|\+=)(?!=)', line):
                    self.assertRegex(line, r'\bif\b[^{]*\b' + name + r'\s*!=',
                                     'refreshCaptureStatus writes %s on every tick: %s' % (name, line))
        read_permissions = body(APP, 'private func readPermissions()')
        for line in read_permissions.splitlines():
            if re.search(r'permissionsCheckedAt\s*=(?!=)', line):
                self.assertIn('permissionsCheckedAt == nil', line, 'readPermissions stamps a new time on every tick: ' + line.strip())


class SummaryJobs(unittest.TestCase):
    def test_g14_a_finished_summary_job_reloads_nothing_on_main(self):
        job = body(APP, 'private func scheduleLegacySummaries()')
        self.assertIn('writer.schedule', job)
        self.assertNotRegex(job, r'\brefresh\(\)', 'a summary job reloads 1000 timeline rows on the main thread when it ends')
        self.assertIn('summaryJobs -= 1', job)

    def test_g14_settings_apps_reads_recent_use_off_main(self):
        settings = read('Sources/MacMemApp/DaydreamSettings.swift')
        self.assertNotIn('model.activity.items', settings, 'Settings > Apps ranks from the list the summary job no longer reloads')
        self.assertIn('await model.recentUsage()', settings)
        usage = body(APP, 'func recentUsage()')
        self.assertIn('DispatchQueue.global', usage)
        self.assertIn('timeline(limit:1000)', usage)


class LaunchPreparation(unittest.TestCase):
    """r2-store-perf: nothing that takes seconds on a long history runs on the main thread at launch."""
    SESSION = read('Sources/MacMemApp/DaydreamLaunchSession.swift')

    def test_launch_prepares_the_history_off_main_before_the_model(self):
        init = body(self.SESSION, 'init(arguments:[String]=CommandLine.arguments,')
        self.assertNotIn('model=isolated ? nil:MemoryViewModel(', init,
                         'the model (and in it the repair and the index build) is made on the main thread at launch')
        self.assertRegex(init, r'guard Self\.prepares\(home:home\) else \{\s*model=MemoryViewModel\(',
                         'launch makes the model at once only when there is nothing to prepare')
        queued = init[init.index('Self.preparationQueue.async'):]
        self.assertIn('HistoryPreparation.prepare(home:home)', queued, 'the preparation runs on the preparation queue')
        # Review round 1: the preparation's own open builds nothing itself; the preparation then builds what the history
        # lacks, waiting for AI apps' reads (HistoryPreparation.finish).
        self.assertIn('launchWork:.preparation)', queued, "the preparation's open builds the indexes with the 1.5 s limit")
        self.assertIn('DispatchQueue.main.async', queued, 'the model is made back on the main thread')
        self.assertIn('preparing=true', init)
        prepares = body(self.SESSION, 'static func prepares(home:URL)->Bool')
        self.assertIn('HistoryPreparation.needed(home:home)', prepares)
        self.assertIn('!MemoryViewModel.recorderLockHeld(home:home)', prepares, 'a second copy prepares its history from under the one recording')
        made = body(self.SESSION, 'private func prepared(')
        self.assertIn('prepared:outcome', made, 'the model is not told what launch already did')
        self.assertIn('preparing=false', made)
        self.assertRegex(self.SESSION, r'@Published private\(set\) var model:MemoryViewModel\?', 'the scenes never see the model made later')

    def test_the_model_says_the_repair_and_does_not_repair_again(self):
        # gold/int round 2: r2-launch-state moved the open out of init into `openHistory()` (it can run again by itself,
        # ADV-8), so what launch prepared is kept on the model and every open reads it.
        made = body(APP, 'init(development:DevelopmentTrial?=nil,recordingTrial:Bool=false,functionalTrial:Bool=false')
        self.assertIn('launchPrepared=prepared', made, "the model forgets what launch prepared before it opens the history")
        init = body(APP, 'private func openHistory()')
        self.assertIn('let prepared=launchPrepared', init, "the model's open doesn't read what launch prepared")
        self.assertIn('store = try Self.openHistory(MemPaths.home(),repairs:prepared?.prepared != true,kept:{ [backups] in backups.noteHistorySetAside() }) {', init,
                      'the model repairs again on the main thread after launch prepared the history')
        # Review round 1: after launch prepared the history, the model's open (on the main thread) builds nothing; what
        # the preparation couldn't finish waits for the next launch's preparation.
        self.assertIn('try MemoryStore(home:MemPaths.home(),writable:true,automaticallySyncSearch:syncSearch,launchWork:prepared?.prepared == true ? .prepared : .here)', init,
                      "the model's open builds the time indexes on the main thread after launch prepared the history")
        # Review round 1: the repair is said from the new file at the open (MemoryStore.unsaidRepair), never from the
        # preparation's outcome in memory (a quit or a second copy before the model lost it).
        self.assertNotIn('prepared?.repair', init, "the model says the repair from launch's memory")
        self.assertNotIn('sayPreparedRepair', APP)
        opened = body(APP, 'static func openHistory(')
        self.assertIn('if repairs {repair()}', opened)
        self.assertRegex(opened, r'sayRepair\(store,defaults:defaults,kept:kept\)\s*return store', 'the open does not say an unsaid repair')
        said = body(APP, 'static func sayRepair(')
        self.assertIn('guard let unsaid=store.unsaidRepair() else {return}', said)
        self.assertIn('if !unsaid.keptChoices {defaults.set(false,forKey:setupCompletedKey)}', said)
        self.assertRegex(said, r'kept\(\)\s*store\.repairSaid\(\)', 'the repair is cleared before it is said')
        # Review round 1: the owner build's website settle is the preparation's work too, never the model's on main.
        wire = read('Sources/MacMemApp/TypedTextExpiryTimer.swift')
        self.assertIn('let websiteSettled = store.launchWork == .prepared ? nil : try? store.settleWebsiteTypingRows(now: now())', wire,
                      'the model re-reads every record for the website settle on the main thread after launch prepared the history')

    def test_preparing_is_one_calm_line(self):
        scene = APP[APP.index('struct MacMemApplication: App'):]
        # The scene's window content is DaydreamMainWindowContent (outside @main, so dd-first-launch-checks hosts it).
        self.assertIn('DaydreamMainWindowContent(session:session)', scene)
        content = body(APP, 'struct DaydreamMainWindowContent: View')
        self.assertIn('else if session.preparing {DaydreamPreparingWindow()} else {SyntheticWindow()}', content,
                      'the window shows the synthetic preview while launch prepares the history')
        self.assertIn('DaydreamMenuBarIsolatedPanel(line: session.preparing ? MenuBarMenu.preparingLine : MenuBarMenu.isolatedLine)', scene,
                      'the menu bar says "Isolated preview" while launch prepares the history')
        window = body(APP, 'struct DaydreamPreparingWindow:View')
        self.assertEqual(re.findall(r'\bText\(', window), ['Text('], 'the preparing window says more than one line')
        self.assertIn('Text(MenuBarMenu.preparingLine)', window)
        self.assertNotRegex(window, r'Button|Toggle', 'the preparing window has a control')
        menu = read('Sources/MemoryUI/MenuBarMenu.swift')
        line = re.search(r'public static let preparingLine = "([^"]*)"', menu).group(1)
        self.assertLessEqual(len(line), 20, line)
        for word in ['index', 'database', 'SQLite', 'repair', 'quit', 'Quit', 'reopen']:
            self.assertNotIn(word, line)

    def test_launch_reads_the_timeline_off_main(self):
        # gold/int round 2: the first read is where the history opens (`historyOpened`, r2-launch-state), not in init.
        init = body(APP, 'private func historyOpened(')
        self.assertIn('refreshAtLaunch()', init)
        self.assertNotRegex(init, r'(?m)^\s*refresh\(\)\s*$', 'launch reads 1000 timeline rows on the main thread (about 110 ms at six months)')
        launch = body(APP, 'private func refreshAtLaunch()')
        # gold r3-store: launch and every later refresh share one read off the main thread (readTimeline).
        self.assertIn('readTimeline(store)', launch)
        read = body(APP, 'private func readTimeline(')
        self.assertIn('DispatchQueue.global', read)
        self.assertIn('store.timeline(limit:1000)', read.split('DispatchQueue.global', 1)[1])

    def test_r3_every_refresh_reads_the_timeline_off_main(self):
        # gold r3-store (gate item 5): refresh() after a preference save, a deletion, a restore or an import read and
        # decoded 1000 timeline rows on the main thread (115-240 ms). The app reads it off the main thread; only the
        # trials and the Development Trial read at once (refreshNow).
        refresh = body(APP, 'func refresh()')
        self.assertIn('readTimeline(store)', refresh)
        self.assertNotIn('timeline(limit', refresh)
        self.assertRegex(refresh, r'guard development == nil,!recordingTrial,!functionalTrial,let store else \{refreshNow\(\);return\}')
        changed = body(APP, 'private func preferencesChanged()')
        self.assertNotIn('timeline(', changed)
        self.assertNotIn('refreshNow()', changed)

    def test_r3_state_changes_and_retries_wait_at_most_a_moment(self):
        # gold r3-store (gate item 5): a failed save, a pause or a storage retry ran the status refresh (the label's
        # summary setting, the replacement read, typing's three reads) and the retry's start with 1.5 s busy waits a
        # statement on the main thread (4 s in all under a long hold). Each is bounded now.
        self.assertRegex(body(APP, 'func refreshCaptureStatus()'), r'StoreWait\.bounded\(Coordinator\.mainWaitBudget\)\s*\{\s*refreshCaptureStatusBounded\(\)\s*\}')
        self.assertRegex(body(APP, 'private func retryStorage(_ token:Int)'), r'StoreWait\.bounded\(Coordinator\.mainWaitBudget\)\s*\{\s*retryStorageBounded\(token\)\s*\}')
        typing = read('Sources/MacMemApp/TypingModel.swift')
        self.assertIn('StoreWait.bounded(StoreWait.mainBudget) { refreshBounded(frontmostBundle: frontmostBundle) }', body(typing, 'func refresh(frontmostBundle: String)'))
        coordinator = read('Sources/MacMemApp/Coordinator.swift')
        self.assertIn('StoreWait.bounded(Self.mainWaitBudget) { storageFaultBounded(error) }', body(coordinator, 'private func storageFault(_ error: Error)'))
        self.assertIn('StoreWait.bounded(Self.mainWaitBudget)', body(coordinator, 'private func summaryMode()'))

    def test_r3_intake_reads_choices_briefly_and_typing_never_uses_a_copy(self):
        # gold r3-store (gate item 5): intake read the saved choices on the main thread for every click with a 1.5 s
        # busy wait and dropped the click when the read failed. The read waits a moment now; only a read held up that
        # way uses the choices last read. Typing never does: a held-up read refuses it, as a failed read did.
        coordinator = read('Sources/MacMemApp/Coordinator.swift')
        intake = body(coordinator, 'private func policyForIntake()')
        self.assertIn('StoreWait.bounded(Self.mainWaitBudget) { try store.policy() }', intake)
        self.assertRegex(intake, r'case \.failure where read\.heldUp:[\s\S]{0,160}return known')
        self.assertRegex(intake, r'case \.failure:\s*return nil')
        typing = body(coordinator, 'func acceptsTyping(_ snap: AccessibilitySnapshot?) -> Bool')
        self.assertNotIn('policyForIntake', typing)
        self.assertIn('try store.policy()', typing)
        self.assertIn('intakePolicy = nil', body(coordinator, 'func policyChanged()'))

    def test_r3_forget_prepares_and_commits_off_main(self):
        # gold r3-store (gate item 5): the Forget alert's preview after a Correct (467-525 ms) and its commit (it checks
        # the scope again) ran on the main thread. The app gives the alerts both off the main thread.
        self.assertRegex(APP, r'activity\.previewCanonicalDeleteOffMain = \{ scope in[\s\S]{0,200}DispatchQueue\.global[\s\S]{0,200}store\.prepareDeletion\(scope:scope\)')
        self.assertRegex(APP, r'activity\.confirmCanonicalDeleteOffMain = \{ \[weak self\] id in[\s\S]{0,300}DispatchQueue\.global[\s\S]{0,200}store\.executeDeletion\(previewID:id,confirmed:true\)[\s\S]{0,200}self\?\.memoryChanged')
        for rel in ['Sources/MemoryUI/DaydreamKitMoments.swift', 'Sources/MemoryUI/RecallDetail.swift']:
            ui = read(rel)
            self.assertIn('browser.previewCanonicalDeleteOffMain', ui, rel)
            self.assertIn('browser.confirmCanonicalDeleteOffMain', ui, rel)

    def test_r1_writer_level_notes_let_the_main_thread_in(self):
        # fix/r1-writer: the level writer's store work (finding the next level note and saving one) ran on a background
        # thread with 1.5 s busy waits a statement while the main thread could be waiting for the store's lock. Like
        # the summary queue, it gives up and runs again while the main thread waits (StoreWait.lettingMainIn).
        level = read('adapters/LevelWriterBinding.swift')
        calls = re.findall(r'[^\n]*store\.(?:levelWork|commitLevel)\([^\n]*', level)
        self.assertGreaterEqual(len(calls), 3, 'the level writer no longer finds or saves level notes where expected')
        for line in calls:
            self.assertRegex(line, r'StoreWait\.lettingMainIn\s*\(?\s*\{\s*try store\.(?:levelWork|commitLevel)\(', line.strip())


class SearchSupervisor(unittest.TestCase):
    def test_g60_a_busy_store_is_retried(self):
        runtime = read('Sources/MemoryCore/ProductionSearchRuntime.swift')
        loop = runtime[runtime.index('enum LocalSearchSupervisor'):]
        self.assertRegex(loop, r'catch MemError\.busy \{\}', 'a busy store ends the local search supervisor')


if __name__ == '__main__':
    unittest.main()
