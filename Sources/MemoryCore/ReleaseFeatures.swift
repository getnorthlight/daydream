// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.

// RELEASE SWITCHES: what a release build ships with.
//
// chromePageHistory: "Web pages in Chrome" (Chrome page history).
//
//   true  (default) Chrome page history ships, off until the person turns it on
//         in Settings > Apps to remember > Web pages in Chrome.
//   false Chrome page history is left out of the release:
//         - the "Web pages in Chrome" card is hidden;
//         - `PrivacySettings.browserPagesOn` is false everywhere, whatever was
//           saved, so no Chrome page row can be written or started;
//         - `ChromeEventSender`, the only Apple Event sender in the app, refuses
//           every call: no event is sent and macOS is never asked about Chrome;
//         - onboarding, Settings, the recording status and the text AI apps
//           read stop mentioning Chrome pages;
//         - the release must be signed WITHOUT `--apple-events`.
//           `python3 scripts/honesty-release-switch-checks.py --flag` prints the
//           flag to pass (`--apple-events` or nothing).
//
// To turn Chrome page history off for a release:
//   1. Change `chromePageHistory` below to `false`. Change nothing else.
//   2. Run the full check suite. `honesty-switch-off` builds the app with the
//      switch off and proves no Apple Event path runs; `honesty-release-switch-py`
//      checks the signing flag.
//   3. Sign with the flag that `--flag` prints (no `--apple-events` when off).
// Saved choices are kept: turning the switch back on in a later release shows
// the person's earlier "Web pages in Chrome" choice again.
//
// docs/browser-capture.md explains the same switch for readers of the code.

/// Build-time switches for features that a release can leave out. Each one is a
/// single constant so a release can be changed in one line.
public enum ReleaseFeatures {
    /// Chrome page history ("Web pages in Chrome"). See the notes at the top of this file.
    public static let chromePageHistory = true
}
