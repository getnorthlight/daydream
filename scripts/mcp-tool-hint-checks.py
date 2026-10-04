"""claude/recall-1004: every tool DayDream's MCP text names is in that build's tool list.

An AI app on the owner's laptop was told "Next: recall with open set to an open value to zoom in; moment_details for a
moment's real actions" and to use recap, while neither recap nor moment_details was in its tool list (its chat began
on an older build; see mcp-update-checks.py for that half). This check pins the other half: the hint text a build
writes names only tools that build lists.

1. Static: every Swift string that is MCP text for the reading model (each "Next:" line, the instructions, tool
   descriptions, usage hints and notices) names only tools from AssistantCatalog's list: a snake_case word must be a
   tool or one of its argument names, and "<word> with <argument>" must start with a tool.
2. Live: a built mac-mem (DAYDREAM_TEST_CLI) on a `mac-mem demo` scratch history answers tools/list with exactly that
   list, says the list may change (capabilities.tools.listChanged), and every reply's Next line names listed tools only.

Synthetic data only (`mac-mem demo` in a temporary folder). Nothing reads the real home folder or a real AI app.
"""
import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = Path(os.environ.get('DAYDREAM_SRC') or ROOT)
CLI = os.environ.get('DAYDREAM_TEST_CLI') or str(ROOT / '.build/debug/mac-mem')
# Where the MCP text the reading model sees is written.
TEXT_FILES = ['Sources/MemoryCore/AssistantCatalog.swift', 'Sources/MemoryCore/AssistantMarkdown.swift',
              'Sources/MemoryCore/LevelRecall.swift', 'Sources/MemoryCore/AssistantTypedRead.swift',
              'Sources/MemoryCore/AssistantView.swift', 'Sources/MemoryCore/AssistantReadiness.swift',
              'Sources/MacMemCLI/main.swift']
# A tool reference: "<tool> with <argument or article>".
WITH = re.compile(r"\b([a-z][a-z_-]*) with (id|open|query|uri|when|level|after|moment|day)\b")
# Words that may stand before "with <argument>" without being a tool: plain English and recall's level names.
NOT_TOOLS = {'each', 'or', 'and', 'more', 'results', 'times', 'call', 'again', 'it', 'them', 'one', 'block', 'day', 'week',
             'month', 'moment', 'line', 'lines', 'hit', 'hits'}
# Reply fields the text may name (not tools): status's fields and the typed words' field.
FIELDS = {'typing_verified', 'chrome_pages', 'cloud_summaries', 'typed_text', 'last_activity', 'day_overview', 'recording_note',
          'earlier_days_not_shown', 'left_out'}
SNAKE = re.compile(r"\b[a-z]+(?:_[a-z]+)+\b")


def catalog_tools():
    text = (SRC / 'Sources/MemoryCore/AssistantCatalog.swift').read_text()
    return re.findall(r'Tool\(name:"([^"]+)"', text)


def catalog_arguments():
    text = (SRC / 'Sources/MemoryCore/AssistantCatalog.swift').read_text()
    return set(re.findall(r'\("([a-z_]+)","', text)) | {'response_format'}


def swift_strings(text):
    """String literals, triple-quoted blocks included (interpolations may split one; each piece is still text)."""
    out = []
    for block in re.findall(r'"""\n(.*?)"""', text, flags=re.S):
        out.append(block)
    text = re.sub(r'"""\n.*?"""', '', text, flags=re.S)
    for line in text.splitlines():
        if line.strip().startswith('//'):
            continue
        out += re.findall(r'"((?:[^"\\\n]|\\.)*)"', line)
    return out


def model_text(literal):
    """True for MCP text the reading model reads: a Next line, instructions, descriptions, hints, notices (not SQL)."""
    if re.search(r'\b(SELECT|INSERT|UPDATE|DELETE)\b', literal):
        return False
    return 'Next:' in literal or len(literal) > 60 or ' with ' in literal


def references(text, tools, arguments):
    """The tool names text uses that aren't tools."""
    bad = []
    for word in SNAKE.findall(text):
        if word not in tools and word not in arguments and word not in FIELDS:
            bad.append(word)
    for word, _ in WITH.findall(text):
        if word not in tools and word not in arguments and word not in NOT_TOOLS:
            bad.append(word + ' with')
    return bad


class ToolHints(unittest.TestCase):
    def test_static_text_names_listed_tools_only(self):
        tools, arguments = set(catalog_tools()), catalog_arguments()
        self.assertIn('recap', tools)
        self.assertIn('moment_details', tools)
        problems = []
        for name in TEXT_FILES:
            path = SRC / name
            if not path.exists():
                continue
            for literal in swift_strings(path.read_text()):
                if not model_text(literal):
                    continue
                for bad in references(literal, tools, arguments):
                    problems.append(f'{name}: "{bad}" in {literal[:100]!r}')
        self.assertEqual(problems, [], 'MCP text names a tool this build does not list:\n' + '\n'.join(problems))

    def test_checker_catches_a_missing_tool(self):
        """The rule itself: a hint naming a tool that isn't listed is caught (a dropped tool, or a stale name)."""
        tools = set(catalog_tools()) - {'moment_details'}
        bad = references("Next: recall with open set to an open value to zoom in; moment_details for a moment's real actions.", tools, catalog_arguments())
        self.assertEqual(bad, ['moment_details'])
        self.assertEqual(references('Next: recap_days with when today.', set(catalog_tools()), catalog_arguments()), ['recap_days', 'recap_days with'])
        self.assertEqual(references('Next: summarize with when today.', set(catalog_tools()), catalog_arguments()), ['summarize with'])


class LiveToolList(unittest.TestCase):
    def setUp(self):
        if not CLI or not os.access(CLI, os.X_OK):
            self.fail('DAYDREAM_TEST_CLI must name a built mac-mem')
        self.temp = tempfile.TemporaryDirectory(prefix='daydream-tool-hints-')
        self.base = [CLI, '--home', self.temp.name]
        self.env = {'PATH': '/usr/bin:/bin', 'HOME': str(Path(self.temp.name) / 'not-home'), 'TMPDIR': os.environ.get('TMPDIR', '/tmp'),
                    'DAYDREAM_TEST_FRESHEN_REQUEST': 'com.example.tool-hint-check'}
        subprocess.run(self.base + ['demo'], check=True, capture_output=True, env=self.env, timeout=120)
        grant = subprocess.run(self.base + ['--client', 'claude-desktop', '--recipient', 'daydream-connect', 'grant'],
                               check=True, capture_output=True, text=True, env=self.env, timeout=60)
        self.env['MAC_MEM_CAPABILITY'] = json.loads(grant.stdout)['capability']

    def tearDown(self):
        self.temp.cleanup()

    def mcp(self, requests):
        lines = [json.dumps({'jsonrpc': '2.0', 'id': i, 'method': m, 'params': p}) for i, (m, p) in enumerate(requests)]
        out = subprocess.run(self.base + ['--client', 'claude-desktop', '--recipient', 'daydream-connect', 'mcp'],
                             input='\n'.join(lines) + '\n', capture_output=True, text=True, env=self.env, timeout=120)
        return [json.loads(line) for line in out.stdout.splitlines()]

    def test_list_and_every_next_line(self):
        calls = [('status', {}), ('search', {'query': 'SQLite'}), ('recall', {'level': 'day', 'when': 'today'}),
                 ('recall', {'query': 'email'}), ('recap', {'when': 'today'}), ('open', {'uri': 'macmem://days/today.json'}),
                 ('current-context', {}), ('read', {'id': 'demo-request'}), ('read', {'id': 'nothing-here'}),
                 ('moment_details', {'id': 'nothing-here'}), ('recall', {'level': 'day', 'when': 'not a time'})]
        rows = self.mcp([('initialize', {'protocolVersion': '2025-06-18'}), ('tools/list', {})] +
                        [('tools/call', {'name': name, 'arguments': args}) for name, args in calls])
        self.assertTrue(rows[0]['result']['capabilities']['tools'].get('listChanged'), 'the server says its tool list may change')
        listed = [t['name'] for t in rows[1]['result']['tools']]
        self.assertEqual(listed, catalog_tools(), 'tools/list is exactly the catalog, in order')
        self.assertIn('recap', listed)
        self.assertIn('moment_details', listed)
        arguments = {key for t in rows[1]['result']['tools'] for key in t['inputSchema']['properties']}
        problems = []
        for (name, args), row in zip(calls, rows[2:]):
            self.assertIn('result', row, f'{name} {args}: {row}')
            text = '\n'.join(c['text'] for c in row['result']['content'])
            self.assertNotIn('DayDream was updated while this chat was open', text, 'a fresh server never says its list is stale')
            for line in text.splitlines():
                if line.startswith('Next:'):
                    problems += [f'{name}: {bad} in {line!r}' for bad in references(line, set(listed), arguments)]
        self.assertEqual(problems, [], '\n'.join(problems))


if __name__ == '__main__':
    unittest.main(verbosity=2)
