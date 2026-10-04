# BrowserBridge

**Not shipped.** This package holds the planned browser extension path for recording minimal browsing metadata: the site origin and how long a tab stayed in the foreground, never titles, full addresses, page text or typing. Packaged builds leave it switched off. [docs/browser-capture.md](../docs/browser-capture.md) explains what it records, how it works and why it is off.

## Layout

| Path | Contents |
| --- | --- |
| `extension/` | Chrome Manifest V3 extension: background worker, focus classification (never reads field values or text), key storage, enrolment and setup page |
| `safari/` | Safari web extension handler and manifest (the app does not accept Safari events yet) |
| `Sources/BrowserBridge/` | Signed version 3 frames (`AuthenticatedMetadata.swift`), enrolment and registration, the app key in the Keychain, the local Unix socket relay, native message framing (at most 4 KB per frame) |
| `Sources/BrowserBridgeHost/` | Chrome native messaging host. Relays frames between Chrome and the running app; trusts neither side without signatures |
| `Sources/BrowserBridgeSetup/` | Interactive command-line tool to check status and enrol an extension's key in a relay directory |
| `Sources/BrowserDiagnostic/`, `Sources/BrowserBridgeDiagnosticHost/` | A separate, short-lived diagnostic protocol used to test the connection |
| `native-host.template.json` | Unconfigured native host manifest with no allowed extensions |
| `configure-chrome.mjs`, `stage-delivery.mjs` | Helpers that fill in the native host manifest and stage extension files for a configured build |
| `Checks/`, `MetadataChecks/`, `DiagnosticChecks/`, `fixtures/` | Swift and Node checks |

The app side is in `Sources/MacMemApp/BrowserCaptureTransport.swift` and `Sources/MacMemApp/BrowserProviderResolver.swift`. The store's final check is `Sources/MemoryCore/BrowserSafety.swift`, and the privacy gate is `PrivacyPolicy/Sources/PrivacyPolicy/BrowserMetadataGate.swift`.

## Checks

From this directory:

```sh
swift build
.build/debug/BrowserBridgeChecks
.build/debug/BrowserMetadataChecks
.build/debug/DiagnosticChecks --checks
node --test fixtures/extension-checks.mjs fixtures/key-store-checks.mjs fixtures/native-coverage-checks.mjs
node fixtures/native-wire.mjs .build/debug
node fixtures/authenticated-checks.mjs .build/debug/BrowserMetadataChecks
node fixtures/diagnostic-transport-checks.mjs .build/debug/DiagnosticChecks .build/debug/BrowserBridgeDiagnosticHost
```

From the repository root, `sh BrowserBridge/fixtures/run-core-checks.sh` checks ingestion into the real store. Everything uses synthetic data and mocked browser APIs; nothing opens a browser, installs the extension or registers the native host.

## Before this can ship

- A published, signed extension with a fixed ID, and a native host manifest that allows only that ID.
- An app screen for enrolling the extension, and packaging that sets the four `DaydreamBrowser…` keys in `Info.plist`.
- Testing on a real Mac with a real browser profile: permission removal, private windows, redirects, frames and disconnects.
- For Safari, a containing app and shared container.

This extension path never records typing. Typing on websites in Google Chrome is a separate path in the app, off until the person turns on typed text and Web pages in Chrome (see [docs/browser-capture.md](../docs/browser-capture.md)).
