# Owned composer empty admission controls

QA-only helper; production capture does not call it. These 14 deterministic controls exercise empty versus nonempty/whitespace/nil/non-string/unsupported values, before/after scope or proof changes, and deadline refusal. They never access live UI or post input.

From the repository root, compile only the helper and controls with `swiftc -target arm64-apple-macosx15.0 -parse-as-library -D DAYDREAM_OWNER_TYPING Sources/MacMemApp/BrowserFixtureEmptyGate.swift tools/capture-fixture-empty/EmptyGateNegativeControls.swift -o /private/tmp/daydream-empty-gate-controls`, then execute that unit-control binary.

A passing unit run is not real browser typing evidence. The actual signed-app fixed-marker fixture additionally calls this gate before any store/tap/input: exact retained owned field and fresh default production proof, one transient AXValue read, then the same scope/proof again. Only a successful CFString with zero length passes; no trim, clearing, value logging/storage/hash/length receipt. Fixed metadata refusal preserves drafts.
