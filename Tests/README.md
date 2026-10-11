# Tests/

The package has **no test target**, on purpose, and `swift test` runs nothing. This page explains why, and where each
file under `Tests/` runs instead.

## Why there is no testTarget

The machines that build and check DayDream (the MacBook and the Mac mini) have only the Command Line Tools
(`xcode-select -p` prints `/Library/Developer/CommandLineTools`). The Command Line Tools ship **no XCTest**:

```
$ xcrun --find xctest
xcrun: error: unable to find utility "xctest", not a developer tool or in PATH
```

They do ship Swift Testing (`Library/Developer/Frameworks/Testing.framework`), but no file here uses it. A
`.testTarget` that imports XCTest would therefore fail to build with the Command Line Tools, and `swift build` (which
also builds test targets with `--build-tests`) would turn red on every runner. `Package.swift` says the same in its
comment under `targets`. (Measured 10/08 on the MacBook, Swift 6.3.2, macOS 26.)

## Where each file runs

| File | Step (scripts/checks-manifest.tsv) | How |
|---|---|---|
| `Tests/MemoryCoreTests/TypesenseTests.swift` | `typesense-tests` (lane storage, owner objects) | Compiled together with `scripts/search-test-runner.swift`, a small stand-in for XCTest (`XCTestCase`, `XCTAssert*`, `XCTSkip`, `XCTUnwrap`, only when XCTest is absent). It runs the same test bodies against a real `typesense-server` (`TYPESENSE_BINARY`). Each test prints PASS or FAIL. |

The recording flows (`scripts/harness/`, `scripts/flow-*-checks.swift`) are runner steps, not XCTest cases. See
`scripts/harness/README.md`.

## Keeping this true

The step `tests-status` (lane flows; `scripts/harness/tests-status.py`) fails when any of these stops being true:

- `Package.swift` declares no `.testTarget`. If one is added, update this page and that check.
- Every file under `Tests/` (this page aside) is a `file` of a manifest row, so the suite runs it.
- This page names each of those files and the step that runs it.

To add a test file, give it a runner step and a manifest row (as `typesense-tests` has), then list it in the table
above.
