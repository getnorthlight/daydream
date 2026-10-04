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

    def send(self, *requests):
        lines = []
        for method, params in requests:
            self.n += 1
            lines.append(json.dumps({'jsonrpc': '2.0', 'id': self.n, 'method': method, 'params': params or {}}) + '\n')
        self.p.stdin.write(''.join(lines).encode())   # one write: pipelined, the way hosts may send them
        self.p.stdin.flush()
        return [json.loads(self.p.stdout.readline()) for _ in requests]

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
        self.env = dict(env, MAC_MEM_CAPABILITY=json.loads(grant.stdout)['capability'])
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
        reply = json.loads(server.p.stdout.readline())
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
        server = self.start(env=dict(self.env, DAYDREAM_MCP_RENEWALS='20'))
        self.update_in_place('500', 'sat-test-5')
        reply = server.ask('tools/call', {'name': 'status'})
        self.assertEqual(reply.get('error', {}).get('message'), UPDATING, 'past the cap the old copy still never answers')
        self.assertIsNone(server.p.poll())

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

    def test_old_update_message_is_gone(self):
        data = Path(CLI).read_bytes()
        self.assertFalse(b'Restart the CLI/MCP process' in data, 'no reply tells an AI app to restart DayDream by hand')


if __name__ == '__main__':
    unittest.main(verbosity=2)
