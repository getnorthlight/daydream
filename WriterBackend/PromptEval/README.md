# Writer prompt evaluation (prompt6 / validator8)

The files keep their prompt4 names (`final/prompt4.txt`, `final/prompt4.py`); their content is prompt6 and validator8 (sat5: typing runs and stated durations on top of prompt5 and validator7).

These are the evaluation cases and harness for DayDream's note writer: the model that turns a moment's or a day's
recorded actions into a title and a few bullets. It uses only the Python 3 standard library. It never downloads
anything and never calls a cloud API.

## The one command

Once the app's model file is on disk, run this from the repository root:

```sh
python3 WriterBackend/PromptEval/final/prompt4.py run --model /path/to/Qwen3.5-4B-Q4_K_M.gguf --with-baseline
```

The command:

- Runs every case in `cases.json` (17 cases) through the shipping prompt5 writer, the same way the app does. The
  model reads the ITEMS view, the answer starts with the `{"title":"` prefill, output is limited to 640 tokens, and
  a rejected answer gets one repair turn and then salvage.
- Checks each answer with validator7, `check()`, a port of core's commit gate and the case's own checks.
- Runs the previous prompt3/validator5 writer on the same cases for comparison (`--with-baseline`). Its
  instruction is frozen in `variants/prompt3-validator5.txt`.

Results go to `WriterBackend/PromptEval/runs/prompt4-final-<timestamp>/`, which is gitignored:

| File | What it holds |
|---|---|
| `summary.md` | The table to read first: per variant, how many notes were publishable, grounded and clean, their quality, and timings. It ends with prompt4's first-pass, after-repair and salvaged counts. |
| `review.md` | Every note, next to its case, for a person to read. |
| `results.jsonl` | Raw answers, repair turns and scores. |
| `run.json` | The settings used for the run, including the `llama-server --version` output. |

To run the Chrome typing case (E18) as well, repeat the command with
`--cases WriterBackend/PromptEval/final/cases-chrome.json`.

Requirements:

- **llama.cpp's `llama-server`.** It is looked for in `/opt/homebrew/bin`; pass `--llama-bin DIR` if it is somewhere
  else. The harness only uses what is already installed. The app itself uses llama.cpp b9723, and evidence run 3 was
  made with b9870.
- **The app's exact model file.** Its size and SHA-256 are checked against `ManagedInstaller.swift`.
  `--allow-proxy-model` runs another file for a smoke test only, and the summary then says the results do not
  count.

## Commands that need no model

| Command | What it checks |
|---|---|
| `python3 final/prompt4.py selftest --mock-run` | The view (including folding, hidden idle time and masked health, money and AI-addressed text), 82 answers that must be rejected, accept and normalize probes, `check()`, the instruction's worked example, salvage, that the goldens are current, and the whole `run` path against a mock server. |
| `python3 final/prompt4.py expected [-v]` | The hand-written expected answers in `final/expected-prompt4.json`. For E18 add `--cases final/cases-chrome.json --expected final/expected-chrome.json`. |
| `python3 final/prompt4.py great` | The GREAT reference answers, re-cited as items. This is a false-rejection check. |
| `python3 final/prompt4.py goldens [--check]` | Writes, or with `--check` verifies, `final/goldens-prompt4.json`. |
| `python3 final/prompt4.py render --case E01 [--view-only]` | Prints the exact prompt the app sends. |
| `cd WriterBackend && swift run --disable-automatic-resolution PromptChecks` | The Swift writer (`CanonicalNotes.swift`, `ModelView.swift`) against the goldens, byte for byte, plus the design's guarantees one by one. |

Run the `python3` commands from `WriterBackend/PromptEval`.

## Files

| Path | What it is |
|---|---|
| `cases.json` | The eval set: 17 synthetic cases (E01–E17). Each has a request, GREAT reference bullets and checks (`mustMention`, `mustNotSay`, `maxBullets`). `build_cases.py` generates it. |
| `final/cases-chrome.json` | E18: Chrome typing in Google Docs and Gmail. |
| `final/prompt4.txt` | The shipping instruction. `CanonicalGrounding.instruction` must equal it, and PromptChecks enforces that. |
| `final/prompt4.py` | The executable spec: the view, validator7, salvage, `check()` and the harness. |
| `final/goldens-prompt4.json` | What `prompt4.py` does with every case, probe and salvage input. The Swift checks compare against it. Regenerate it after any change to the spec. |
| `final/evidence/` | Run 3 on the real 4B model. |
| `eval_writer.py`, `variants/` | The prompt3/validator5 harness and baseline. `final/prompt4.py` imports it. |
| `reader_first/`, `small_first/` | The design proposals that prompt4 was built from. Kept for reference. |

## Changing the prompt

1. Edit `final/prompt4.txt` and make the same change to `CanonicalGrounding.instruction` in
   `Sources/WriterBackend/CanonicalNotes.swift`.
2. If the validator changes, change `final/prompt4.py` first and then port it to Swift.
3. Run `python3 final/prompt4.py goldens`, then `selftest --mock-run`, then `swift run PromptChecks`.
4. Bump both `generatorVersion` strings (`CanonicalGrounding.localVersion` and `cloudVersion`, and `VERSION` in
   `prompt4.py`).
5. Run the one command above on the real model before shipping.
