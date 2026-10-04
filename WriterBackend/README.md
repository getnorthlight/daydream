# WriterBackend

This Swift package writes DayDream's optional activity and day summaries, either on this Mac with llama.cpp or through OpenRouter. How summaries work, what the writer sees and how notes are checked is described in [docs/summaries.md](../docs/summaries.md).

- [PROVENANCE.md](PROVENANCE.md) lists the pinned model and runtime, their hashes and licences, and how to check or rebuild them.
- `Notices/` holds the full licence texts for llama.cpp and the Qwen model.
- `Sources/CLlamaBridge/` is the small C++ bridge to llama.cpp, with the llama.cpp headers it compiles against in `vendor/`.
- `Sources/WriterBackend/` holds the writers, the installer that downloads and verifies the model and runtime, and the signed-runtime checks.

## Checks

Run from the repository root. None of these download a model or contact a cloud provider:

```sh
swift run --package-path WriterBackend WriterChecks
swift run --package-path WriterBackend InstallationChecks   # synthetic checks only
swift run --package-path WriterBackend CloudActivationChecks
swift run --package-path WriterBackend AdapterChecks
```

See [docs/summaries.md](../docs/summaries.md#development-checks) for the checks that need a real model or a debug build of the app.
