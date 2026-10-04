# Repeatable recording tests

Run from the repository root:

```sh
bash scripts/test-recording-replay.sh
```

The command builds the current source in a fresh temporary folder, then replays
the same fabricated session twice, with typed recording on and off. It uses the
real EventCapture, capture binding, filtering, encrypted vault and store with a
fake clock and fake focus metadata. It never starts a live event tap, reads
Accessibility, changes system permissions, reads owner history, or runs a model.

The transcript is `scripts/fixtures/recording-session-synthetic.json`. It
contains every scripted test input before filtering. It covers editing,
duplicate focus notifications, different fields/windows, pending drafts,
password fields, one-time codes, private/unknown focus, secret tokens, recording
settings, pause and resume. Exact saved text is asserted internally. Reports
contain piece names and counts, without typed words or secrets.

Each run prints its output folder and writes a JSONL result for every piece:
characters offered/read/dropped before acquisition, new saved rows, pending
state, visible versus persisted rows, and assertion results. Turning recording
off must hide earlier words without deleting their encrypted records; turning
it back on must not count those records as newly saved.

Change recorder code or the fixture and run the same command again. The fixture's
expected results remain an independent contract. A failure exits nonzero.
For an integrator's already rebuilt, matching public debug objects, `BUILD` may
point to that frozen build directory to skip compilation of the app products.
Do not reuse old objects after changing the recorder or filtering code.

This first replay covers the native TextEdit route. Chrome/Safari browser
metadata, real permissions, OS input delivery, and model summaries need their
separate fixture checks and short live validation. Passing a replay is not
evidence that a browser's real Accessibility tree or timing matches the mock.
