"""`mac-mem connect` / `disconnect` / `connections` end to end, with the real command-line tool.

Env: DAYDREAM_TEST_CLI = a built mac-mem. Everything is in a scratch folder: a fresh history (--home) and a fake
home folder for the AI apps' settings files (--user-home). The check then starts `mac-mem mcp` exactly as the
written entry says (command, args, env) and asks it for status and a search, the way an AI app would. It never
touches the real home folder, a real AI app, the network, or the Keychain.
"""
import json
import os
import subprocess
import tempfile
import unittest
try:
    import tomllib
except ImportError:
    tomllib = None
from pathlib import Path

CLI = os.environ.get('DAYDREAM_TEST_CLI', '')


class ConnectCLI(unittest.TestCase):
    def setUp(self):
        if not CLI or not os.access(CLI, os.X_OK):
            self.fail('DAYDREAM_TEST_CLI must name a built mac-mem')
        self.root = Path(tempfile.mkdtemp(prefix='daydream-connect-cli-'))
        self.home = self.root / 'history'
        self.user = self.root / 'user'
        self.user.mkdir()
        init = self.run_cli('--local', 'migration-init')
        self.assertEqual(init.returncode, 0, init.stderr)
        self.outputs = []

    def tearDown(self):
        subprocess.run(['rm', '-rf', str(self.root)], check=False)

    def run_cli(self, *args, stdin=subprocess.DEVNULL):
        env = {'PATH': '/usr/bin:/bin', 'HOME': str(self.root / 'not-home'), 'TMPDIR': os.environ.get('TMPDIR', '/tmp')}
        result = subprocess.run([CLI, '--home', str(self.home), '--user-home', str(self.user), *args],
                                capture_output=True, text=True, stdin=stdin, env=env, timeout=60)
        if hasattr(self, 'outputs'):
            self.outputs.append(result.stdout + result.stderr)
        return result

    def config(self):
        return self.user / '.cursor' / 'mcp.json'

    def entry(self):
        return json.loads(self.config().read_text())['mcpServers']['daydream']

    def mcp(self, entry, *requests):
        """Starts the server exactly as an AI app would, from the written entry."""
        lines = ''.join(json.dumps(r) + '\n' for r in requests)
        env = {'PATH': '/usr/bin:/bin', 'HOME': str(self.user), **entry.get('env', {})}
        result = subprocess.run([entry['command'], *entry['args']], input=lines, capture_output=True, text=True, env=env, timeout=60)
        return [json.loads(line) for line in result.stdout.splitlines() if line.strip()]

    def test_connections_list(self):
        (self.user / '.cursor').mkdir()
        (self.user / '.codex').mkdir()
        listing = self.run_cli('connections', '--json')
        self.assertEqual(listing.returncode, 0, listing.stderr)
        states = {row['app']: row['state'] for row in json.loads(listing.stdout)['apps']}
        self.assertEqual(states, {'chatgpt': 'Not connected', 'claude-desktop': 'Not on this Mac', 'claude-code': 'Not on this Mac', 'cursor': 'Not connected',
                                  'windsurf': 'Not on this Mac'})
        files = {row['app']: row['file'] for row in json.loads(listing.stdout)['apps']}
        self.assertEqual(files['cursor'], '~/.cursor/mcp.json')
        self.assertEqual(files['chatgpt'], '~/.codex/config.toml')

    def test_connect_review_write_mcp_disconnect(self):
        (self.user / '.cursor').mkdir()
        (self.config()).write_text('{"mcpServers": {"other": {"command": "/bin/echo"}}, "keep": [1, 2]}')
        original = json.loads(self.config().read_text())

        # Review only: nothing written.
        review = self.run_cli('connect', 'cursor', '--dry-run', '--json')
        self.assertEqual(review.returncode, 0, review.stderr)
        plan = json.loads(review.stdout)
        self.assertEqual((plan['outcome'], plan['file'], plan['backup']), ('add', '~/.cursor/mcp.json', '~/.cursor/mcp.json.daydream-backup'))
        self.assertIn('<private key, made when you connect>', plan['entry'])
        self.assertEqual(json.loads(self.config().read_text()), original)

        # Without --yes and without a terminal: shows the review, writes nothing.
        shown = self.run_cli('connect', 'cursor')
        self.assertEqual(shown.returncode, 2)
        self.assertIn('It writes:', shown.stdout)
        self.assertIn('Nothing was written', shown.stdout)
        self.assertFalse((self.user / '.cursor' / 'mcp.json.daydream-backup').exists())

        # A review of an older file is refused.
        stale = self.run_cli('connect', 'cursor', '--yes', '--json', '--expect-sha256', '0' * 64)
        self.assertEqual(stale.returncode, 1)
        self.assertIn('changed after you reviewed it', stale.stderr)

        # Connect.
        done = self.run_cli('connect', 'cursor', '--yes', '--json', '--expect-sha256', plan['reviewedSHA256'])
        self.assertEqual(done.returncode, 0, done.stderr)
        result = json.loads(done.stdout)
        self.assertEqual((result['wrote'], result['outcome'], result['backup']), (True, 'add', '~/.cursor/mcp.json.daydream-backup'))
        self.assertIn('Quit and reopen Cursor', result['message'])
        entry = self.entry()
        self.assertEqual(entry['command'], os.path.realpath(CLI))
        self.assertEqual(entry['args'], ['--home', str(self.home), '--client', 'cursor', '--recipient', 'daydream-connect', 'mcp'])
        key = entry['env']['MAC_MEM_CAPABILITY']
        self.assertEqual(len(key), 72)
        after = json.loads(self.config().read_text())
        self.assertEqual(after['keep'], [1, 2])
        self.assertEqual(after['mcpServers']['other'], {'command': '/bin/echo'})
        self.assertEqual(json.loads((self.user / '.cursor' / 'mcp.json.daydream-backup').read_text()), original)

        # The AI app's view: the server answers with the written key.
        replies = self.mcp(entry, {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {}},
                           {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': 'status', 'arguments': {}}},
                           {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'search', 'arguments': {'query': 'notes'}}})
        self.assertEqual(replies[0]['result']['serverInfo']['name'], 'DayDream')
        self.assertIn('result', replies[1])
        self.assertIn('result', replies[2], replies[2])

        # Twice: nothing changes.
        before = self.config().read_bytes()
        again = self.run_cli('connect', 'cursor', '--yes', '--json')
        self.assertEqual(json.loads(again.stdout)['outcome'], 'alreadyConnected')
        self.assertEqual(self.config().read_bytes(), before)
        listing = {row['app']: row['state'] for row in json.loads(self.run_cli('connections', '--json').stdout)['apps']}
        self.assertEqual(listing['cursor'], 'Connected')

        # Disconnect: entry gone, key off, other settings back as they were.
        gone = self.run_cli('disconnect', 'cursor', '--yes', '--json')
        self.assertEqual(gone.returncode, 0, gone.stderr)
        self.assertTrue(json.loads(gone.stdout)['wrote'])
        self.assertEqual(json.loads(self.config().read_text()), original)
        denied = self.mcp(entry, {'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call', 'params': {'name': 'search', 'arguments': {'query': 'notes'}}})
        # claude/mcp-prompts-1003: a refused tool call is an isError tool result (the model reads why), not a protocol error.
        self.assertTrue(denied[0].get('result', {}).get('isError'), denied[0])
        again = self.run_cli('disconnect', 'cursor', '--yes', '--json')
        self.assertEqual((again.returncode, json.loads(again.stdout)['wrote']), (0, False))

        # The key was never printed.
        for text in self.outputs:
            self.assertNotIn(key, text)

    @unittest.skipIf(tomllib is None, 'independent TOML check requires Python 3.11+')
    def test_chatgpt_toml_review_connect_mcp_disconnect(self):
        folder = self.user / '.codex'
        folder.mkdir()
        config = folder / 'config.toml'
        original = '# Synthetic settings\n[mcp_servers.other]\ncommand = "/fixture/other" # kept\nargs = ["--stdio"]\n'
        config.write_text(original)
        review = self.run_cli('connect', 'chatgpt', '--dry-run', '--json')
        self.assertEqual(review.returncode, 0, review.stderr)
        plan = json.loads(review.stdout)
        self.assertIn('[mcp_servers.daydream]', plan['entry'])
        self.assertIn('<private key, made when you connect>', plan['entry'])
        self.assertEqual(config.read_text(), original)
        shown = self.run_cli('connect', 'chatgpt')
        self.assertEqual(shown.returncode, 2)
        self.assertEqual(config.read_text(), original)
        done = self.run_cli('connect', 'chatgpt', '--yes', '--json', '--expect-sha256', plan['reviewedSHA256'])
        self.assertEqual(done.returncode, 0, done.stderr)
        # Independent parser validates generated TOML and the transport arguments.
        parsed = tomllib.loads(config.read_text())
        entry = parsed['mcp_servers']['daydream']
        self.assertEqual(entry['command'], os.path.realpath(CLI))
        self.assertEqual(entry['args'], ['--home', str(self.home), '--client', 'chatgpt', '--recipient', 'daydream-connect', 'mcp'])
        self.assertEqual(parsed['mcp_servers']['other'], tomllib.loads(original)['mcp_servers']['other'])
        key = entry['env']['MAC_MEM_CAPABILITY']
        replies = self.mcp(entry, {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {}},
                           {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': 'status', 'arguments': {}}})
        self.assertEqual(replies[0]['result']['serverInfo']['name'], 'DayDream')
        self.assertIn('result', replies[1])
        self.assertEqual(json.loads(self.run_cli('connect', 'chatgpt', '--yes', '--json').stdout)['outcome'], 'alreadyConnected')
        gone = self.run_cli('disconnect', 'chatgpt', '--yes', '--json')
        self.assertEqual(gone.returncode, 0, gone.stderr)
        self.assertEqual(config.read_text(), original)
        denied = self.mcp(entry, {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'search', 'arguments': {'query': 'fixture'}}})
        self.assertTrue(denied[0].get('result', {}).get('isError'), denied[0])
        for text in self.outputs:
            self.assertNotIn(key, text)

    def test_refusals(self):
        unknown = self.run_cli('connect', 'chatbot', '--yes')
        self.assertEqual(unknown.returncode, 1)
        self.assertIn('Known apps: chatgpt, claude-desktop, claude-code, cursor, windsurf', unknown.stderr)
        missing = self.run_cli('connect', 'windsurf', '--yes')
        self.assertEqual(missing.returncode, 1)
        self.assertIn("isn't on this Mac", missing.stderr)
        (self.user / '.cursor').mkdir()
        self.config().write_text('{\n  // comment\n  "mcpServers": {}\n}')
        commented = self.run_cli('connect', 'cursor', '--yes')
        self.assertEqual(commented.returncode, 1)
        self.assertIn("isn't plain JSON", commented.stderr)
        self.assertEqual(self.config().read_text(), '{\n  // comment\n  "mcpServers": {}\n}')
        usage = self.run_cli('connect')
        self.assertEqual(usage.returncode, 1)
        self.assertIn('Use: mac-mem connect <app>', usage.stderr)

    def test_claude_code_large_file_exact(self):
        """claude/connect-fix-1003, the live bug: `mac-mem connect claude-code --yes` refused ~/.claude.json with
        "couldn't prove that the rest of the file would stay the same". A synthetic file of the same shape (made up
        here): large, nested projects, raw and escaped unicode, \\/, 1.0, and costs Foundation can't print back."""
        costs = [0.022845, 0.082605, 0.09819900000000001, 0.055491, 0.1234567890123456789, 1.0, 2.5]
        projects = {}
        for p in range(200):
            projects[f'/Users/synthetic/work/proj-{p}/ünïcödé'] = {
                'allowedTools': [], 'history': [{'display': f'fix the café build {p}-{h} 東京 ✓ 🚀', 'pastedContents': {}} for h in range(8)],
                'mcpServers': {}, 'hasTrustDialogAccepted': p % 2 == 0, 'lastCost': costs[p % len(costs)],
                'lastModelUsage': {'claude-synthetic': {'inputTokens': p * 37, 'costUSD': costs[(p + 3) % len(costs)]}}}
        shaped = {'numStartups': 412, 'installMethod': 'native', 'autoUpdates': False, 'projects': projects,
                  'cachedFeatures': {'ratio': 1.0, 'big': 12345678901234567890}, 'lastReleaseNotesSeen': '2.1.288'}
        text = json.dumps(shaped, indent=2, ensure_ascii=False)
        # Escapes a JSON writer may use: \u escapes and \/ (kept byte for byte).
        text = text.replace('"installMethod": "native"', '"installMethod": "na\\u0074ive \\/ \\u00e9"') + '\n'
        (self.user / '.claude').mkdir()
        claude = self.user / '.claude.json'
        claude.write_bytes(text.encode())
        original = claude.read_bytes()
        self.assertGreater(len(original), 200_000)
        done = self.run_cli('connect', 'claude-code', '--yes')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn('Claude Code is connected', done.stdout)
        connected = claude.read_bytes()
        prefix = 0
        while prefix < len(original) and original[prefix] == connected[prefix]:
            prefix += 1
        self.assertTrue(connected[:prefix] == original[:prefix] and connected.endswith(original[prefix:]),
                        'connect only inserts bytes; every other byte of ~/.claude.json is unchanged')
        after = json.loads(connected)
        entry = after['mcpServers'].pop('daydream')
        after.pop('mcpServers')
        self.assertEqual(after, json.loads(original))
        self.assertEqual((entry['type'], entry['args'][-1]), ('stdio', 'mcp'))
        key = entry['env']['MAC_MEM_CAPABILITY']
        self.assertNotIn(key, done.stdout + done.stderr)
        listing = self.run_cli('connections', '--json')
        states = {row['app']: row['state'] for row in json.loads(listing.stdout)['apps']}
        self.assertEqual(states['claude-code'], 'Connected')
        status = self.mcp(entry, {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'claude-code', 'version': '0'}}})
        self.assertEqual(status[0].get('id'), 1, status)
        off = self.run_cli('disconnect', 'claude-code', '--yes')
        self.assertEqual(off.returncode, 0, off.stderr)
        self.assertEqual(claude.read_bytes(), original, 'disconnect gives ~/.claude.json back byte for byte')
        for output in self.outputs:
            self.assertNotIn(key, output)

    def test_no_history_yet(self):
        (self.user / '.cursor').mkdir()
        empty = self.root / 'no-history'
        env = {'PATH': '/usr/bin:/bin', 'HOME': str(self.user), 'TMPDIR': os.environ.get('TMPDIR', '/tmp')}
        result = subprocess.run([CLI, '--home', str(empty), '--user-home', str(self.user), 'connect', 'cursor', '--yes'],
                                capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(result.returncode, 1)
        self.assertIn('Open DayDream and finish setup first', result.stderr)
        self.assertFalse(self.config().exists())
        self.assertFalse(empty.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
