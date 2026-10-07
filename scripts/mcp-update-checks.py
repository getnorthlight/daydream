"""An AI app's `mac-mem mcp` keeps working across a DayDream update, with the real command-line tool.

An AI app (Claude Desktop, Claude Code, Cursor) starts `mac-mem mcp` once and keeps it for its whole session. After
DayDream is updated, that process must carry on as the updated copy: every later request answered, by the new code,
without restarting the AI app, and never by the old code once the bundle has changed.

Env: DAYDREAM_TEST_CLI = a built mac-mem. Everything is in a scratch folder: a fake DayDream.app holding a copy of that
mac-mem and its Companions.json, and a fresh history (--home). Updates are simulated by rewriting the manifest (as
release.py does for every build) or by swapping the whole bundle (as Sparkle and the Finder do). Nothing touches the
real home folder, a real AI app, the network or the Keychain.
"""
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

CLI = os.environ.get('DAYDREAM_TEST_CLI', '')
# The tree the CLI was built from (for the one source rule below): DAYDREAM_SRC, else the working folder.
SRC = Path(os.environ.get('DAYDREAM_SRC') or os.getcwd())
UPDATING = 'DayDream is being updated. Try again in a moment.'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class Server:
    """Stands in for an AI app: starts the configured command once and keeps its pipes open."""

    def __init__(self, exe, home, env):
        self.p = subprocess.Popen([str(exe), '--home', str(home), '--client', 'claude-desktop', '--recipient', 'daydream-connect', 'mcp'],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
        self.n = 0
        self.notifications = []

    def line(self):
        """The next reply; notifications the server sends on its own (no id) are kept aside, as an AI app does."""
        while True:
            message = json.loads(self.p.stdout.readline())
            if 'id' in message:
                return message
            self.notifications.append(message.get('method'))

    def send(self, *requests):
        lines = []
        for method, params in requests:
            self.n += 1
            lines.append(json.dumps({'jsonrpc': '2.0', 'id': self.n, 'method': method, 'params': params or {}}) + '\n')
        self.p.stdin.write(''.join(lines).encode())   # one write: pipelined, the way hosts may send them
        self.p.stdin.flush()
        return [self.line() for _ in requests]

    def ask(self, method, params=None):
        return self.send((method, params))[0]

    def version(self):
        reply = self.ask('initialize', {'protocolVersion': '2025-06-18'})
        return reply.get('result', {}).get('serverInfo', {}).get('version') or 'ERROR: ' + json.dumps(reply.get('error'))

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=20)
        return self.p.returncode


class MCPUpdate(unittest.TestCase):
    def setUp(self):
        if not CLI or not os.access(CLI, os.X_OK):
            self.fail('DAYDREAM_TEST_CLI must name a built mac-mem')
        self.root = Path(tempfile.mkdtemp(prefix='daydream-mcp-update-'))
        self.apps = self.root / 'Applications'
        self.app = self.apps / 'DayDream.app'
        self.home = self.root / 'history'
        self.make_bundle(self.app, '400', 'sat-test-4')
        self.exe = self.app / 'Contents/MacOS/mac-mem'
        env = {'PATH': '/usr/bin:/bin', 'HOME': str(self.root / 'not-home'), 'TMPDIR': os.environ.get('TMPDIR', '/tmp')}
        grant = subprocess.run([str(self.exe), '--home', str(self.home), '--client', 'claude-desktop', '--recipient', 'daydream-connect', 'grant'],
                               capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(grant.returncode, 0, grant.stderr)
        # agent-tools v2: these checks pin the 0.1.4 tools' replies (DAYDREAM_MCP_TOOLSET=legacy); the v2 update note is
        # test_v2_carried_on_from_the_0_1_4_list.
        self.env = dict(env, MAC_MEM_CAPABILITY=json.loads(grant.stdout)['capability'], DAYDREAM_MCP_TOOLSET='legacy')
        self.servers = []

    def tearDown(self):
        for server in self.servers:
            if server.p.poll() is None:
                server.p.kill()
            server.p.wait(timeout=20)
            for pipe in (server.p.stdin, server.p.stdout):
                try:
                    pipe.close()
                except OSError:
                    pass
        shutil.rmtree(self.root, ignore_errors=True)

    def make_bundle(self, path, build, version, binary_hash=None):
        shutil.rmtree(path, ignore_errors=True)
        (path / 'Contents/MacOS').mkdir(parents=True)
        (path / 'Contents/Resources').mkdir(parents=True)
        shutil.copy(CLI, path / 'Contents/MacOS/mac-mem')
        # release.py writes the build, the version and every companion's hash: each build's manifest differs.
        manifest = {'schema': 1, 'build': build, 'version': version,
                    'sha256': {'MacOS/mac-mem': binary_hash or sha(path / 'Contents/MacOS/mac-mem')}}
        (path / 'Contents/Resources/Companions.json').write_text(json.dumps(manifest, sort_keys=True) + '\n')

    def update_in_place(self, build, version, binary_hash=None):
        staged = self.root / 'staged.app'
        self.make_bundle(staged, build, version, binary_hash)
        shutil.copy(staged / 'Contents/Resources/Companions.json', self.app / 'Contents/Resources/Companions.json')
        shutil.rmtree(staged)

    def start(self, env=None):
        server = Server(self.exe, self.home, env or self.env)
        self.servers.append(server)
        self.assertEqual(server.version(), 'sat-test-4')
        self.assertIn('result', server.ask('tools/call', {'name': 'status'}))
        return server

    def history_opens(self, pid):
        out = subprocess.run(['/usr/sbin/lsof', '-p', str(pid)], capture_output=True, text=True).stdout
        return sum(1 for line in out.splitlines() if line.rstrip().endswith('memory.sqlite'))

    def test_idle_server_carries_on_as_the_update(self):
        server = self.start()
        pid = server.p.pid
        self.update_in_place('500', 'sat-test-5')
        time.sleep(3)   # the server is idle, as an AI app's usually is when DayDream updates
        for name in ('status', 'context', 'search'):
            reply = server.ask('tools/call', {'name': name, 'arguments': {'query': 'x'}})
            self.assertIn('result', reply, f'{name} after the update: {reply}')
        self.assertIn('result', server.ask('ping'))
        self.assertIn('result', server.ask('tools/list'))
        self.assertEqual(server.version(), 'sat-test-5', 'the updated copy answers, not the old code')
        self.assertEqual(server.p.pid, pid, 'the same process carries on (the AI app keeps its connection)')
        self.assertIsNone(server.p.poll())
        self.assertLessEqual(self.history_opens(pid), 1, 'the history file the old copy had open is closed, not leaked')
        self.assertEqual(server.close(), 0)

    def test_freshen_never_holds_every_call(self):
        """fix/sx-all round 1: summaries on but nobody answers (DayDream quit without saying so, or a long batch): the
        first covered call waits at most about 5 seconds, and the calls after it answer at once for 5 minutes."""
        import sqlite3
        name = 'com.getnorthlight.daydream.test.freshen.%d' % os.getpid()
        server = self.start(env=dict(self.env, DAYDREAM_TEST_FRESHEN_REQUEST=name))
        db = sqlite3.connect(str(self.home / 'memory.sqlite'))
        db.execute("INSERT OR REPLACE INTO metadata VALUES('summary_writer',?)", (json.dumps({'mode': 'local', 'at': '2026-09-29T06:00:00Z'}),))
        db.commit(); db.close()
        started = time.time()
        self.assertIn('result', server.ask('tools/call', {'name': 'current-context'}))
        first = time.time() - started
        self.assertGreater(first, 3, 'the first covered call does ask the app and wait for it')
        self.assertLess(first, 8, f'the wait is at most about 5 seconds, not 20 ({first:.1f}s)')
        started = time.time()
        for _ in range(3):
            self.assertIn('result', server.ask('tools/call', {'name': 'current-context'}))
        self.assertLess(time.time() - started, 3, 'after an unanswered ask, later calls never wait again')
        self.assertEqual(server.close(), 0)

    def test_request_right_after_the_update(self):
        server = self.start()
        self.update_in_place('500', 'sat-test-5')
        reply = server.ask('tools/call', {'name': 'status'})   # no idle time: the waiting request itself triggers it
        self.assertIn('result', reply, reply)
        self.assertEqual(server.version(), 'sat-test-5')

    def test_pipelined_requests_are_not_lost(self):
        server = self.start()
        self.update_in_place('500', 'sat-test-5')
        replies = server.send(('tools/call', {'name': 'status'}), ('ping', {}), ('tools/list', {}),
                              ('initialize', {'protocolVersion': '2025-06-18'}))
        self.assertEqual([r['id'] for r in replies], [3, 4, 5, 6], 'every pipelined request is answered, in order')
        self.assertTrue(all('result' in r for r in replies), replies)
        self.assertEqual(replies[-1]['result']['serverInfo']['version'], 'sat-test-5')

    def test_bundle_swap_like_sparkle(self):
        server = self.start()
        (self.root / 'Trash').mkdir()
        os.rename(self.app, self.root / 'Trash/DayDream.app')
        staged = self.root / 'staged-DayDream.app'
        self.make_bundle(staged, '500', 'sat-test-5')
        # A request lands while the old bundle is gone; the new one arrives a second later.
        server.p.stdin.write((json.dumps({'jsonrpc': '2.0', 'id': 99, 'method': 'tools/call', 'params': {'name': 'status'}}) + '\n').encode())
        server.p.stdin.flush()
        time.sleep(1)
        os.rename(staged, self.app)
        reply = server.line()
        self.assertEqual(reply['id'], 99)
        self.assertIn('result', reply, f'a request during the swap waits for it, then the new copy answers: {reply}')
        self.assertEqual(server.version(), 'sat-test-5')

    def test_bundle_gone_says_updating_without_paths_then_recovers(self):
        server = self.start()
        os.rename(self.app, self.root / 'away.app')
        started = time.time()
        reply = server.ask('tools/call', {'name': 'status'})
        self.assertLess(time.time() - started, 20)
        self.assertEqual(reply.get('error', {}).get('message'), UPDATING, reply)
        self.assertNotIn(str(self.root), json.dumps(reply), 'no path reaches the AI app')
        self.make_bundle(self.app, '500', 'sat-test-5')
        self.assertIn('result', server.ask('tools/call', {'name': 'status'}), 'once DayDream is back, the next request works')
        self.assertEqual(server.version(), 'sat-test-5')

    def test_half_copied_binary_is_never_started(self):
        server = self.start()
        self.update_in_place('500', 'sat-test-5', binary_hash='0' * 64)   # manifest in place, mac-mem not yet
        reply = server.ask('tools/call', {'name': 'status'})
        self.assertEqual(reply.get('error', {}).get('message'), UPDATING, 'the old code does not answer, and nothing half-copied starts')
        self.assertIsNone(server.p.poll())
        self.update_in_place('501', 'sat-test-5')   # the copy finishes
        self.assertIn('result', server.ask('tools/call', {'name': 'status'}))
        self.assertEqual(server.version(), 'sat-test-5')

    def test_same_build_reinstall_changes_nothing(self):
        server = self.start()
        manifest = (self.app / 'Contents/Resources/Companions.json').read_bytes()
        os.rename(self.app, self.root / 'old.app')
        self.make_bundle(self.app, '400', 'sat-test-4')
        self.assertEqual((self.app / 'Contents/Resources/Companions.json').read_bytes(), manifest)
        self.assertIn('result', server.ask('tools/call', {'name': 'status'}))
        self.assertEqual(server.version(), 'sat-test-4')

    def test_many_updates_in_one_session(self):
        server = self.start()
        for n in range(5):
            self.update_in_place(str(500 + n), f'sat-test-5.{n}')
            self.assertIn('result', server.ask('tools/call', {'name': 'status'}))
            self.assertEqual(server.version(), f'sat-test-5.{n}')
        self.assertLessEqual(self.history_opens(server.p.pid), 1)

    def test_renewals_are_capped(self):
        # claude/rel-017c: the cap is on renewals in a row (each within ten minutes of the one before).
        server = self.start(env=dict(self.env, DAYDREAM_MCP_RENEWALS='20', DAYDREAM_MCP_RENEWED_AT=str(int(time.time()) - 60)))
        self.update_in_place('500', 'sat-test-5')
        reply = server.ask('tools/call', {'name': 'status'})
        self.assertEqual(reply.get('error', {}).get('message'), UPDATING, 'past the cap the old copy still never answers')
        self.assertIsNone(server.p.poll())

    def test_renewals_far_apart_are_never_capped(self):
        # claude/rel-017c: an AI app kept open across many ordinary updates (ChatGPT's helpers on the owner's Mac had
        # renewed 8-10 times in four days) keeps working: the count starts again after ten quiet minutes, and a session
        # an older copy started (a count, no time) renews too. The same process carries on: the AI app never disconnects.
        for extra in ({'DAYDREAM_MCP_RENEWED_AT': str(int(time.time()) - 3600)}, {}):
            with self.subTest(extra=extra):
                server = self.start(env=dict(self.env, DAYDREAM_MCP_RENEWALS='20', **extra))
                pid = server.p.pid
                self.update_in_place('500', 'sat-test-5')
                reply = server.ask('tools/call', {'name': 'status'})
                self.assertIn('result', reply, f'past the old cap, an ordinary update still answers: {reply}')
                self.assertEqual(server.version(), 'sat-test-5', 'the updated copy answers')
                self.assertEqual(server.p.pid, pid, 'the same process carries on (no disconnect)')
                self.assertIsNone(server.p.poll())
                self.assertEqual(server.close(), 0)
                self.update_in_place('400', 'sat-test-4')   # back to the first copy for the next case

    def test_time_zone_is_read_for_each_request(self):
        # A server lives as long as its AI app session, across a trip or a daylight-saving change. Its "today" and "now"
        # must follow the Mac's time zone as it is when each request comes, not as it was when the server started.
        # (Changing the Mac's time zone is a system setting, so this is checked in the source: the reset is inside
        # the request loop, before the request is handled.)
        source = (SRC / 'Sources/MacMemCLI/main.swift').read_text()
        loop = source[source.index('func mcp('):]
        loop = loop[:loop.index('switch method')]
        self.assertIn('while true', loop)
        self.assertIn('NSTimeZone.resetSystemTimeZone()', loop.split('while true', 1)[1], 'the time zone is read again for each request')

    def test_a_history_set_aside_is_not_read_again(self):
        # DayDream repaired a damaged history at launch: a new file with every row it could read took the old one's
        # place in one rename, and the damaged file was kept beside it (StoreIntegrity, G45). A server an AI app started
        # before that reads the repaired history from its next request, never the old file.
        server = self.start()
        status = lambda: json.loads(server.ask('tools/call', {'name': 'status', 'arguments': {'response_format': 'detailed'}})['result']['content'][0]['text'])
        self.assertEqual(status().get('last_activity'), 'Nothing recorded yet.')
        fresh = self.root / 'new-history'
        fresh.mkdir()
        shutil.copy(self.home / 'memory.sqlite', fresh / 'memory.sqlite')   # the new history keeps the AI app's key here
        demo = subprocess.run([str(self.exe), '--home', str(fresh), 'demo'], capture_output=True, text=True,
                              env={k: v for k, v in self.env.items() if k != 'MAC_MEM_CAPABILITY'}, timeout=60)
        self.assertEqual(demo.returncode, 0, demo.stderr)
        aside = self.home / 'Damaged history'
        aside.mkdir()
        os.link(self.home / 'memory.sqlite', aside / 'memory.sqlite')
        os.rename(fresh / 'memory.sqlite', self.home / 'memory.sqlite')
        self.assertNotEqual(status().get('last_activity'), 'Nothing recorded yet.', 'the server reads the new history, not the file set aside')
        self.assertLessEqual(self.history_opens(server.p.pid), 1, 'the file set aside is closed, not kept open')

    # claude/recall-1004: an AI app keeps the tool list it was given when its chat started. After the server carries on
    # as an update whose list differs, the server says so (notifications/tools/list_changed) and, until the AI app
    # fetches the list again, starts every tool reply with a note naming the tools the AI app lacks.
    STALE = 'DayDream was updated while this chat was open'
    OLDER = 'status,context,search,read,open,recall,current-context'

    def text(self, reply):
        return '\n'.join(c['text'] for c in reply['result']['content'])

    def carried_on(self, **env):
        """A server as an earlier copy hands it over: started by a renewal, with what that copy recorded."""
        server = Server(self.exe, self.home, dict(self.env, DAYDREAM_MCP_RENEWALS='1', **env))
        self.servers.append(server)
        return server

    def test_carried_on_from_an_older_tool_list(self):
        server = self.carried_on(DAYDREAM_MCP_PROTOCOL='2025-06-18', DAYDREAM_MCP_LISTED='0123456789abcdef:' + self.OLDER)
        status = server.ask('tools/call', {'name': 'status'})
        self.assertEqual(server.notifications, ['notifications/tools/list_changed'], 'the AI app is told once that the list changed')
        first = status['result']['content'][0]['text']
        self.assertTrue(first.startswith('Note: ' + self.STALE), first)
        self.assertIn('without recap, moment_details', first, 'the note names the tools the AI app lacks')
        self.assertIn('quit Claude Desktop and open it again', first, 'and how to get them')
        detailed = server.ask('tools/call', {'name': 'status', 'arguments': {'response_format': 'detailed'}})
        self.assertIn('structuredContent', detailed['result'], 'the revision agreed before the renewal still holds')
        failed = server.ask('tools/call', {'name': 'moment_details', 'arguments': {'id': 'nothing-here'}})
        self.assertTrue(failed['result'].get('isError') and self.STALE in self.text(failed), 'a failed call carries the note too')
        self.assertIn('moment_details', [t['name'] for t in server.ask('tools/list')['result']['tools']])
        self.assertNotIn(self.STALE, self.text(server.ask('tools/call', {'name': 'status'})), 'once the AI app has the new list, no note')
        self.assertEqual(server.notifications, ['notifications/tools/list_changed'], 'never told twice')

    def test_carried_on_from_a_copy_that_kept_no_list(self):
        # A copy from before this change records nothing: what the AI app has isn't known, so the note lists this copy's tools.
        server = self.carried_on()
        first = self.text(server.ask('tools/call', {'name': 'status'}))
        self.assertEqual(server.notifications, ['notifications/tools/list_changed'])
        self.assertIn('may be out of date', first)
        self.assertIn('recap, moment_details', first)

    def test_v2_carried_on_from_the_0_1_4_list(self):
        # agent-tools v2: a chat begun on 0.1.4 carries on as 0.1.5. Its old tools keep answering (unlisted) with no send
        # state; the note names the new tools it lacks, without pointing at Next lines.
        env = {k: v for k, v in self.env.items() if k != 'DAYDREAM_MCP_TOOLSET'}
        server = Server(self.exe, self.home, dict(env, DAYDREAM_MCP_RENEWALS='1', DAYDREAM_MCP_PROTOCOL='2025-06-18',
                                                   DAYDREAM_MCP_LISTED='0123456789abcdef:' + self.OLDER + ',recap,moment_details'))
        self.servers.append(server)
        first = self.text(server.ask('tools/call', {'name': 'status'}))
        self.assertEqual(server.notifications, ['notifications/tools/list_changed'])
        self.assertTrue(first.startswith('Note: ' + self.STALE), first)
        self.assertIn('without timeline, details', first)
        self.assertIn('still work', first)
        self.assertNotIn('Next line', first.splitlines()[0])
        old = server.ask('tools/call', {'name': 'recap', 'arguments': {'when': 'today'}})
        self.assertIn('result', old)
        self.assertNotIn('not sent', self.text(old))
        self.assertEqual([t['name'] for t in server.ask('tools/list')['result']['tools']], ['timeline', 'search', 'details', 'status'])
        self.assertNotIn(self.STALE, self.text(server.ask('tools/call', {'name': 'timeline'})), 'once the AI app has the new list, no note')

    def test_carried_on_with_the_same_list_says_nothing(self):
        server = self.start()
        self.assertIn('result', server.ask('tools/list'))
        self.assertTrue(server.ask('initialize', {'protocolVersion': '2025-06-18'})['result']['capabilities']['tools'].get('listChanged'))
        self.update_in_place('500', 'sat-test-5')   # the same mac-mem: the same tools
        reply = server.ask('tools/call', {'name': 'status', 'arguments': {'response_format': 'detailed'}})
        self.assertEqual(server.version(), 'sat-test-5')
        self.assertEqual(server.notifications, [], 'no list_changed when the list is the same')
        self.assertNotIn(self.STALE, self.text(reply))
        self.assertIn('structuredContent', reply['result'], 'the agreed revision carries over a real renewal')

    def test_carried_on_before_any_list_says_nothing(self):
        server = self.start()   # initialize and status only: the AI app hasn't asked for the list yet
        self.update_in_place('500', 'sat-test-5')
        self.assertNotIn(self.STALE, self.text(server.ask('tools/call', {'name': 'status'})))
        self.assertEqual(server.notifications, [])

    def test_old_update_message_is_gone(self):
        data = Path(CLI).read_bytes()
        self.assertFalse(b'Restart the CLI/MCP process' in data, 'no reply tells an AI app to restart DayDream by hand')


if __name__ == '__main__':
    unittest.main(verbosity=2)
