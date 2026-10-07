# Contributing to DayDream

Thanks for helping. DayDream is a small beta project, so a short issue before a large change saves everyone time.

## Build

You need an Apple silicon Mac with Xcode or the Xcode Command Line Tools (Swift 5.10 or later).

```sh
scripts/bootstrap.sh   # fetches Sparkle 2.9.6 into Vendor/ and checks its SHA-256
swift build
```

`scripts/bootstrap.sh` is safe to run again, and `--offline` keeps it off the network. The [README](docs/README-details.md#build-from-source) says what a plain build leaves out, and why there's no public app recipe yet.

## Checks

The checks are meant to use made-up data in temporary folders, and never to start recording, request permissions or open your real history. If you find one that does, please report it.

- **Core checks:** `swift run MacMemChecks` (in `Checks/`) covers capture, privacy, browser, timed-pause, update and installation rules. `swift run ProductionBindingChecks` covers the storage snapshot and backup bindings.
- **Package checks:** each package in the repository has its own runner, for example `swift run --package-path PrivacyPolicy PrivacyChecks`, `swift run --package-path WriterBackend WriterChecks` and `swift run --package-path BrowserBridge BrowserBridgeChecks`.
- **Unit tests:** `swift test` runs `Tests/MemoryCoreTests`. It needs the full Xcode, because the Command Line Tools don't include XCTest.
- **Full suite:** `bash runner-1001/run-headless.sh [label]` builds the package and runs every headless check, including the `scripts/*-checks.swift` files, with made-up data in `.build/checks`. It needs the pinned Sparkle and Node 22; on-screen checks are skipped. `ONLY=<regex>` reruns chosen steps. See [runner-1001/README.md](runner-1001/README.md).
- **Docs checks:** `python3 scripts/docs-claims-checks.py -v` checks that the README, PRIVACY.md, the FAQ, SECURITY.md and the GitHub templates keep their promises and have no blanks.

Run the checks that cover what you changed, and say in the PR which ones you ran.

## Keep DayDream's privacy promises

The [README](docs/README-details.md#what-daydream-records) is a promise to users about what DayDream records and sends. A change must not quietly break it:

- Recording starts only because the user asked for it. After a quit, a restart, an update, sleep, a screen lock or a user switch it starts again only if it was recording before (never after the user's own Pause or Stop), and DayDream says so when it can't.
- New kinds of capture, and anything that sends data off the Mac, are opt-in and explained in the README.
- Skip rules (password fields, secure input, excluded apps, browsers, Incognito and Guest windows, blocked sites, secret redaction) are never weakened without discussion in an issue first.
- If behavior changes, update the README, [PRIVACY.md](PRIVACY.md), the [FAQ](docs/faq.md) and [SECURITY.md](SECURITY.md) in the same PR. `scripts/docs-claims-checks.py` checks some of the promises they make.

## Never share captured history

Issues, pull requests, tests and fixtures are public and copied permanently. **Never** put real captured history in them: no window titles, web addresses, typed text, generated notes, database or backup files, or screenshots of a real timeline, whether yours or anyone else's. Use made-up data, or create a throwaway history with `mac-mem --home <empty folder> demo`.

Pictures in the docs are drawn from DayDream's own views with sample data by `scripts/docs-install-render.swift`, never taken from a running app.

Security problems go to [private vulnerability reporting](SECURITY.md), not to issues.

## Sign your commits off (DCO)

DayDream uses the [Developer Certificate of Origin](https://developercertificate.org/) instead of a contributor license agreement. By signing off a commit you confirm that you wrote it, or otherwise have the right to submit it under the project's license. Sign off every commit with `-s`:

```sh
git commit -s -m "Explain what changed"
```

This adds a `Signed-off-by: Your Name <you@example.com>` line. To keep your personal email address out of the public history, you can use your GitHub noreply address.

Contributions are licensed under the [MIT License](LICENSE), the same license as the project.

## Style

Match the code around your change, keep pull requests focused on one thing, and write commit messages that say what changed and why. Use "DayDream" for the product name in anything a user can see.
