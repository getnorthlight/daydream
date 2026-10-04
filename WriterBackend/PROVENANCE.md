# Local summary model and runtime pins

Where the model and runtime used for [local summaries](../docs/summaries.md) come from, the exact bytes the app accepts, and how to check them. The pins are compiled into `Sources/WriterBackend/ManagedInstaller.swift` (`WriterCandidates`), `Sources/WriterBackend/CompatibleInstallation.swift` and `Sources/WriterBackend/MacOS15Runtime.swift`. A file whose size or SHA-256 does not match is rejected; the pins are never updated to match a file without review.

The full licence texts are in `WriterBackend/Notices/`. The repository's `THIRD-PARTY-NOTICES.md` summarizes the licences of all third-party components.

## Model

| | |
| --- | --- |
| Upstream model | [Qwen/Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) at revision `851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a` |
| Upstream licence | Apache License 2.0 ([licence at that revision](https://huggingface.co/Qwen/Qwen3.5-4B/blob/851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a/LICENSE)) |
| Quantized file | `Qwen3.5-4B-Q4_K_M.gguf` from [unsloth/Qwen3.5-4B-GGUF](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/tree/720bb031aae5488eae5d6a78768e6d826662b2ae) at revision `720bb031aae5488eae5d6a78768e6d826662b2ae` |
| Size | 2,740,937,888 bytes |
| SHA-256 | `00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4` |

The Unsloth model card declares Apache-2.0 and names `Qwen/Qwen3.5-4B` as the base model. This is a community quantization, not one published by Qwen, and it has not been independently rebuilt from the upstream weights. The model is downloaded by the user during setup and is never shipped with the app. The licence text is in `Notices/Qwen-APACHE-2.0.txt`.

## Runtime

Both runtimes are built from llama.cpp tag [b9723](https://github.com/ggml-org/llama.cpp/releases/tag/b9723), commit `b14e3fb90ca8c760f4254ddc9aa7845ebbdb2edf`. llama.cpp is MIT licensed, copyright The ggml authors. The licence text is in `Notices/llama-MIT.txt` (SHA-256 `94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d`, identical to the licence at that commit).

### Official release (development builds)

| | |
| --- | --- |
| File | [`llama-b9723-bin-macos-arm64.tar.gz`](https://github.com/ggml-org/llama.cpp/releases/download/b9723/llama-b9723-bin-macos-arm64.tar.gz) |
| Size | 10,943,910 bytes |
| SHA-256 | `2cd552419b84b7b16598b95e9dd14572c86ecc13c96789cf06b7025d2dca815f` (matches the digest GitHub publishes) |

Setup extracts only the seven libraries the app needs, each with its own pinned size and hash (`CompatibleInstallation.runtimeFiles`). No command-line tools from the archive are extracted. These libraries require macOS 26.0 or later (`LC_BUILD_VERSION` minimum 26.0), so development builds refuse local setup on older systems.

### macOS 15 rebuild (signed builds)

Signed builds never download a runtime. They bundle the same commit rebuilt for macOS 15. The signed copies are committed in `packaging/WriterRuntime/<ID>/` (distribution `daydream-qwen35-b9723-macos15-v2`), and `developer-id-release.py stage` copies them into every release unchanged. See [RELEASE.md](../RELEASE.md#writer-runtime) and [summaries](../docs/summaries.md#on-this-mac).

- Source: `https://codeload.github.com/ggml-org/llama.cpp/tar.gz/b14e3fb90ca8c760f4254ddc9aa7845ebbdb2edf`, SHA-256 `55d57e59cccd163526290a3d369356e2818343febb83fe39d6731056a15a5cb4`, unmodified. Its `llama.h`, `ggml*.h`, `gguf.h` and `LICENSE` are byte-identical to the copies in `Sources/CLlamaBridge/vendor/`.
- Tools: CMake 3.31.6 from Kitware's official macOS release (`cmake-3.31.6-macos-universal.tar.gz`, 78,374,480 bytes, SHA-256 `330b9514f5112e5ed4fb08b8b05803b776fd9b539a6ae12927d14dcc0ee2ba8d`), and Apple clang 21.0.0 (clang-2100.1.1.101) from the Command Line Tools with the macOS 26.5 SDK. Nothing else is downloaded or installed.
- Result: seven arm64 libraries with a minimum of macOS 15.0, `@loader_path` as the only search path, and no build-folder paths inside. They are pinned in `MacOS15Runtime.files`:

| File | Bytes | SHA-256 |
| --- | --- | --- |
| `libllama.0.dylib` | 2,469,424 | `ae33ee5d7acc95a58fa9bad0fc908db42059a8943c29e344b3fe70fd0532902d` |
| `libggml.0.dylib` | 59,872 | `b8742eaf98f2a33c7c7f953b7d6ace16e0ef47438b94650d7a87d4b86da1dde7` |
| `libggml-base.0.dylib` | 710,040 | `6db3ed93964340d9319f9f19ad196cf914b6886fcbc09d7776b2fb21ccc5623b` |
| `libggml-cpu.0.dylib` | 917,424 | `21dd443b21e656a8a041e2cd66174f67da454fa42977bfd106c0d1a6ee79f0de` |
| `libggml-metal.0.dylib` | 832,504 | `32a8f0f4cd9a145aa040402c5b22968c984a17930cbafd7de471067fece81b72` |
| `libggml-blas.0.dylib` | 58,776 | `4a694d43d1babd66ca473335120a3221b422f8924a4e86ec8fc0e8939d56d031` |
| `libggml-rpc.0.dylib` | 133,392 | `37236a0aa3e46cc577ed19c41c3f10645a1ad3d130f4eae234162b516ae2912f` |

- Archive: `MacOS15Runtime.archiveSHA256` is `714bdf726e3c9c6c81f346dc87c1188c8c4e5ae4bdb93a1ec690f4a73252672d` (5,191,680 bytes). It is the SHA-256 of `runtime.tar`, an uncompressed POSIX ustar archive of exactly eight files: `runtime/` with the seven libraries above and `runtime-LICENSE` (the MIT licence below). Every entry has mtime 0, uid and gid 0, no owner names, and mode 0755 (0644 for the licence); the order is `runtime/`, `runtime-LICENSE`, then the libraries by name. `macos15_runtime_archive.py` defines it. It depends only on those eight files, so the same libraries always give the same hash. This replaces the September 14 archive (`d893b81b…`, a tar.gz whose metadata could not be repeated).

Build, from the repository root (paths must not contain spaces):

```sh
python3 WriterBackend/build_macos15_runtime.py \
  --cmake <cmake-3.31.6-macos-universal>/CMake.app/Contents/bin/cmake \
  --source <folder>/llama.cpp-b14e3fb90ca8c760f4254ddc9aa7845ebbdb2edf <fresh output folder>
```

It checks the source headers against `vendor/` and the CMake version, then runs, in a fixed environment (`PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `LC_ALL=C`, `ZERO_AR_DATE=1`, no inherited compiler flags):

```sh
cmake -S <source> -B <out>/build \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_INSTALL_RPATH=@loader_path \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_RPC=ON -DGGML_NATIVE=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF \
  -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_APP=OFF \
  -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF \
  -DLLAMA_BUILD_NUMBER=9723 -DLLAMA_BUILD_COMMIT=b14e3fb90ca8c760f4254ddc9aa7845ebbdb2edf \
  "-DCMAKE_C_FLAGS=-Werror=unguarded-availability-new -ffile-prefix-map=<source>=llama.cpp -ffile-prefix-map=<out>/build=build" \
  "-DCMAKE_CXX_FLAGS=-Werror=unguarded-availability-new -ffile-prefix-map=<source>=llama.cpp -ffile-prefix-map=<out>/build=build"
cmake --build <out>/build --config Release -j 4
```

It then copies the seven libraries to `<out>/runtime/`, the licence to `<out>/runtime-LICENSE`, and writes `<out>/runtime.tar`, `<out>/build.log` and `<out>/build-info.json` with every hash.

`-Werror=unguarded-availability-new` turns any unguarded use of an API newer than macOS 15 into a build error. `-ffile-prefix-map` replaces the source and build folders in `__FILE__` strings with `llama.cpp` and `build`, so the bytes do not depend on where the build ran. Metal shaders are embedded and compiled at run time.

Reproducible: on 2026-09-26 the build ran twice, from two separate extractions of the source into two different folders, with `-j 4` and `-j 8` and with two different Python versions. All seven libraries, the licence and `runtime.tar` were byte-identical. Other compiler or SDK versions will likely give different bytes; these pins are for Apple clang 21.0.0 with the macOS 26.5 SDK.

To check a build, run `python3 WriterBackend/audit_macos15_runtime.py <out>`. It checks that every compiled file used the macOS 15 target, the availability error flag and the source prefix map; that the build log has no errors; that every library matches its pin, is arm64 with a macOS 15.0 minimum, links only its siblings and system libraries, and holds no local folder paths; and that the canonical archive of `runtime/` and `runtime-LICENSE` (and `runtime.tar`, if present) has the pinned hash.

To make the copies for signing, run `python3 scripts/prepare_writer_macos15.py <out>/runtime.tar <fresh folder>`. It only runs `install_name_tool`: each library's id and sibling references become `@loader_path/<name>`. It signs nothing and writes `signing-inputs.json` with the hash of each copy. The fresh folder can be anywhere its parent is a real folder owned by you (or root) that others cannot write to, so the copies can be kept.

Real model trial, 2026-09-26, on an Apple M4 Pro with 48 GB and macOS 26.5.2 (not macOS 15), unsigned libraries, no app:

```sh
swift run --package-path WriterBackend ModelTrial --macos15 <out>/runtime <Qwen3.5-4B-Q4_K_M.gguf>
```

- All 33 of 33 layers ran on the GPU. Cold load took 27.5 s.
- 18 of 18 sample notes passed validation, and none made a forbidden claim. 11 passed on the first answer; 7 needed the one repair turn. 13 of 18 mentioned everything the curated check looks for.
- Time per note: median 6.0 s, fastest 3.7 s, slowest 17.4 s, mean 7.3 s.
- Cancelling during generation returned in 0.004 s, and a new load and answer afterwards worked.
- Memory, from `/usr/bin/time -l` around the built `ModelTrial` binary: peak memory footprint 2.78 GB; maximum resident size 5.98 GB, which also counts the memory-mapped model file.

Running it on a Mac with macOS 15 is still to be verified.

For a signed release, the libraries must also be signed once with the app's Developer ID (identifiers `com.getnorthlight.daydream.writer.<name>`, hardened runtime, no entitlements). Their v2 manifest (`runtime_distribution.py manifest-v2`) must also be pinned in `SignedRuntimePolicy.swift`. `WriterBackend/audit_signed_runtime.py` audits a signed set. See [RELEASE.md](../RELEASE.md#writer-runtime).

## Headers

`Sources/CLlamaBridge/WriterLlama.cpp` compiles against llama.cpp's public headers, copied unchanged from tag b9723 into `Sources/CLlamaBridge/vendor/`, with the matching `LICENSE`. The library itself is loaded at run time, never linked at build time.

```
94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d  LICENSE
94e4cd069b9313b2ceb35dacec901981e0bb478d8bb31035b7126be091998c23  ggml-alloc.h
a620e815b43a44cc72d5f216629a3a91980335b61bc37eb6b2d0813368c3704f  ggml-backend.h
1aafe97e576ea38c0da57517fb2492955d0b69c1a799842481fc069d6d9d28ef  ggml-cpu.h
3586de1bc8a934b5c72339e2b6937b0641e8f149b512231e666f67de0736eea2  ggml-opt.h
98c5fcf96279e16c09d42dcba482be1b03434839db723bba4b65518e424ba181  ggml.h
2ddb276a5bece743433160ad863279473431c9d4c171d468bf860a3cda3fbf3f  gguf.h
56b0a7b4de7a20a07e0faf8a5a8c7b85b86fa3a1367385dc98cafe1a6dc7ad46  llama.h
```

## Checking the pins yourself

Without downloading the model:

- Hugging Face metadata: `https://huggingface.co/api/models/unsloth/Qwen3.5-4B-GGUF/revision/720bb031aae5488eae5d6a78768e6d826662b2ae?blobs=true` lists the file size and LFS SHA-256.
- `curl -I` on the exact file URL (`https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/720bb031aae5488eae5d6a78768e6d826662b2ae/Qwen3.5-4B-Q4_K_M.gguf`) returns `x-repo-commit`, `x-linked-size` and `x-linked-etag`.
- GitHub: `https://api.github.com/repos/ggml-org/llama.cpp/git/ref/tags/b9723` resolves the tag to its commit, and `https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/b9723` lists the release assets and their digests.

With files you already have, compare `shasum -a 256 <file>` against the tables above.
