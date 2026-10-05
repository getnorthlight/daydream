"""fix/welcome-prompt: the setup check an AI app reads, through the real `mac-mem mcp`, against an isolated history.

After Connect, the AI app gets the starter prompt ("Explain what DayDream does ... Check that DayDream is connected and
ready to use ... give me three example questions"). It answers from DayDream's `status` tool, so this starts the built
mac-mem the way an AI app does (a copy in a scratch DayDream.app, a fresh --home, a key from `grant`) and reads:
the server instructions (status for questions about DayDream itself, no unasked recap), the tool list (names unchanged,
status says what it checks), and status itself on an empty new install (ready to set up, never a failure), with a key
that doesn't work (not ready, and how to fix it) and after sample activity. Status carries no titles, typed words or
web addresses.

Env: DAYDREAM_TEST_CLI = a built mac-mem. DAYDREAM_READINESS_SAMPLES = a folder to save the status replies to
(metadata only), optional. Nothing touches the real home folder, a real AI app, the network or the Keychain; the
freshen request is renamed so no running DayDream is ever woken.
"""
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

CLI = os.environ.get('DAYDREAM_TEST_CLI', '')
SAMPLES = os.environ.get('DAYDREAM_READINESS_SAMPLES', '')
FIELDS = ['setup', 'connected', 'recording', 'typing', 'typing_verified', 'chrome_pages', 'summaries', 'examples']
# Every title, typed text and address the sample activity (`mac-mem demo`) holds.
DEMO_CONTENT = ['Please build a standalone memory app', 'I finished the proposed implementation', 'example.org', 'Swift%20SQLite', 'Swift SQLite']


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class Server:
    def __init__(self, exe, home, env):
        self.p = subprocess.Popen([str(exe), '--home', str(home), '--client', 'claude-desktop', '--recipient', 'daydream-connect', 'mcp'],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
        self.n = 0

    def ask(self, method, params=None):
        self.n += 1
        self.p.stdin.write((json.dumps({'jsonrpc': '2.0', 'id': self.n, 'method': method, 'params': params or {}}) + '\n').encode())
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def status(self):
        # claude/mcp-prompts-1003: the fields are read from the detailed (JSON) form; concise is checked on its own.
        reply = self.ask('tools/call', {'name': 'status', 'arguments': {'response_format': 'detailed'}})
        return json.loads(reply['result']['content'][0]['text'])

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=20)
        self.p.stdout.close()


class MCPReadiness(unittest.TestCase):
    def setUp(self):
        if not CLI or not os.access(CLI, os.X_OK):
            self.fail('DAYDREAM_TEST_CLI must name a built mac-mem')
        self.root = Path(tempfile.mkdtemp(prefix='daydream-mcp-readiness-'))
        app = self.root / 'Applications/DayDream.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Resources').mkdir(parents=True)
        self.exe = app / 'Contents/MacOS/mac-mem'
        shutil.copy(CLI, self.exe)
        manifest = {'schema': 1, 'build': '1', 'version': 'readiness-test', 'sha256': {'MacOS/mac-mem': sha(self.exe)}}
        (app / 'Contents/Resources/Companions.json').write_text(json.dumps(manifest, sort_keys=True) + '\n')
        self.home = self.root / 'history'
        self.env = {'PATH': '/usr/bin:/bin', 'HOME': str(self.root / 'not-home'), 'TMPDIR': os.environ.get('TMPDIR', '/tmp'),
                    'DAYDREAM_TEST_FRESHEN_REQUEST': 'com.getnorthlight.daydream.test.readiness.' + self.root.name}
        grant = self.cli('grant')
        self.key = json.loads(grant)['capability']
        self.servers = []

    def tearDown(self):
        for server in self.servers:
            try:
                server.close()
            except Exception:
                server.p.kill()
        shutil.rmtree(self.root, ignore_errors=True)

    def cli(self, *args):
        run = subprocess.run([str(self.exe), '--home', str(self.home), '--client', 'claude-desktop', '--recipient', 'daydream-connect', *args],
                             capture_output=True, text=True, env=self.env, timeout=120)
        self.assertEqual(run.returncode, 0, run.stderr)
        return run.stdout

    def server(self, key, toolset='legacy'):
        # agent-tools v2: the tests below pin the 0.1.4 status (DAYDREAM_MCP_TOOLSET=legacy); test_v2_status reads the v2 one.
        server = Server(self.exe, self.home, dict(self.env, MAC_MEM_CAPABILITY=key, DAYDREAM_MCP_TOOLSET=toolset))
        self.servers.append(server)
        return server

    def save(self, name, status):
        if SAMPLES:
            Path(SAMPLES).mkdir(parents=True, exist_ok=True)
            (Path(SAMPLES) / f'{name}.json').write_text(json.dumps(status, indent=2, sort_keys=True, ensure_ascii=False) + '\n')

    def test_instructions_and_tools_point_setup_questions_at_status(self):
        server = self.server(self.key)
        init = server.ask('initialize', {'protocolVersion': '2025-06-18'})['result']
        instructions = init['instructions']
        self.assertIn("DayDream itself (what it does, is it set up, what to ask) or empty results: call status", instructions)
        self.assertIn("Don't recap activity unless asked.", instructions)
        self.assertLessEqual(len(instructions), 2200)
        tools = server.ask('tools/list')['result']['tools']
        # claude/summary-1003 (owner decision 2026-10-03): moment_details added (typed words gated in the app).
        self.assertEqual([t['name'] for t in tools], ['status', 'context', 'search', 'read', 'open', 'recall', 'current-context', 'recap', 'moment_details'])
        self.assertTrue(all(t['annotations']['readOnlyHint'] for t in tools))
        # claude/mcp-prompts-1003: DayDream is reached for unprompted, and every tool but context offers response_format.
        self.assertIn('refers to something they did, saw, wrote or sent', instructions)
        for t in tools:
            fmt = t['inputSchema']['properties'].get('response_format')
            self.assertEqual(fmt and fmt['enum'], None if t['name'] == 'context' else ['concise', 'detailed'], t['name'])
        concise = server.ask('tools/call', {'name': 'status'})['result']['content'][0]['text']
        self.assertTrue(concise.startswith('**DayDream status**: '))
        self.assertIn('Next:', concise)
        status = next(t for t in tools if t['name'] == 'status')['description']
        for word in ['connected', 'recording', 'typing_verified', 'chrome_pages', 'summaries', 'examples', 'new install is ready, not a failure',
                     'no titles, typed words or web addresses']:
            self.assertIn(word, status)

    def test_new_install_reads_ready_to_start_not_failed(self):
        server = self.server(self.key)
        status = server.status()
        self.save('1-new-install-connected', status)
        for field in FIELDS:
            self.assertIn(field, status)
        self.assertTrue(status['connected'].startswith('yes:'))
        self.assertEqual(status['last_activity'], 'Nothing recorded yet.')
        self.assertEqual(status['recording'], 'off')
        self.assertEqual(status['setup'], 'Connected, but recording is off. The person can turn DayDream on in the menu bar. Nothing has been recorded yet.')
        self.assertTrue(status['typing'].startswith('off:'))
        self.assertEqual(status['typing_verified'], 'no')
        self.assertTrue(status['summaries'].startswith('unknown'))
        self.assertTrue(status['examples'].endswith('(These work once there is some activity.)'))
        for word in ['fail', 'error', 'broken']:
            self.assertNotIn(word, status['setup'].lower())
        # The resource reads the same check.
        resource = server.ask('resources/read', {'uri': 'macmem://status'})['result']['contents'][0]
        self.assertEqual(json.loads(resource['text'])['setup'], status['setup'])
        # An empty day is an empty answer, not an error.
        day = server.ask('tools/call', {'name': 'open', 'arguments': {'uri': 'macmem://days/today.json'}})
        self.assertIn('result', day)

    def test_a_key_that_does_not_work_reads_not_ready_with_the_fix(self):
        server = self.server('not-the-key')
        status = server.status()
        self.save('2-wrong-key', status)
        self.assertTrue(status['connected'].startswith("no: this AI app's DayDream key no longer works"))
        self.assertTrue(status['setup'].startswith('Not ready:'))
        self.assertIn('Settings › Connections', status['setup'])
        search = server.ask('tools/call', {'name': 'search', 'arguments': {'query': 'SQLite'}})
        # claude/mcp-prompts-1003: refused as an isError tool result, with what the person can do.
        self.assertTrue(search['result']['isError'])
        self.assertIn('access for this AI app is missing', search['result']['content'][0]['text'])
        self.assertIn('Settings › Connections', search['result']['content'][0]['text'])
        self.cli('revoke')
        status = self.server(self.key).status()
        self.save('3-grant-missing', status)
        self.assertTrue(status['connected'].startswith("no: this AI app isn't connected to DayDream"))

    def test_after_activity_status_holds_no_content(self):
        self.cli('demo')
        status = self.server(self.key).status()
        self.save('4-after-sample-activity', status)
        self.assertNotEqual(status['last_activity'], 'Nothing recorded yet.')
        self.assertNotIn('once there is some activity', status['examples'])
        text = json.dumps(status, ensure_ascii=False)
        for content in DEMO_CONTENT:
            self.assertNotIn(content, text)
        self.assertNotIn('macmem://activities', text)
        self.assertNotIn('http', text)

    def test_v2_status_says_setup_first(self):
        # agent-tools v2: the default tool list; status starts with the same setup check, in plain text.
        def v2_status(server):
            reply = server.ask('tools/call', {'name': 'status', 'arguments': {}})['result']
            self.assertFalse(reply.get('isError', False))
            return reply['content'][0]['text']
        server = self.server(self.key, toolset='v2')
        init = server.ask('initialize', {'protocolVersion': '2025-06-18'})['result']
        self.assertIn('DayDream itself or an empty result: status', init['instructions'])
        self.assertLessEqual(len(init['instructions']), 2200)
        tools = server.ask('tools/list')['result']['tools']
        self.assertEqual([t['name'] for t in tools], ['timeline', 'search', 'details', 'status'])
        self.assertTrue(all(t['annotations']['readOnlyHint'] for t in tools))
        text = v2_status(server)
        self.save('5-v2-new-install', {'text': text})
        lines = text.splitlines()
        self.assertTrue(lines[0].startswith('DayDream \u00b7 ') and 'nothing recorded yet' in lines[0])
        self.assertEqual(lines[1], 'Setup: Connected, but recording is off. The person can turn DayDream on in the menu bar. Nothing has been recorded yet.')
        self.assertIn('Connection: connected', text)
        self.assertIn('Typing: off:', text)
        for word in ['fail', 'error', 'broken']:
            self.assertNotIn(word, lines[1].lower())
        wrong = v2_status(self.server('not-the-key', toolset='v2'))
        self.save('6-v2-wrong-key', {'text': wrong})
        self.assertTrue(wrong.splitlines()[1].startswith('Setup: Not ready:'))
        self.assertIn('Settings › Connections', wrong.splitlines()[1])
        search = self.server('not-the-key', toolset='v2').ask('tools/call', {'name': 'search', 'arguments': {'query': 'SQLite'}})['result']
        self.assertTrue(search['isError'])
        self.assertIn('Settings › Connections', search['content'][0]['text'])
        self.cli('demo')
        after = v2_status(self.server(self.key, toolset='v2'))
        self.save('7-v2-after-sample-activity', {'text': after})
        self.assertIn('last activity', after)
        for content in DEMO_CONTENT:
            self.assertNotIn(content, after)
        self.assertNotIn('macmem://', after)
        self.assertNotIn('http', after)


if __name__ == '__main__':
    unittest.main(verbosity=2)
