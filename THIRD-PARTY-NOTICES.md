# Third-party notices

DayDream is Copyright (c) 2026 The DayDream Authors and is licensed under the MIT
License (see `LICENSE` and `NOTICE`). It contains, is built with or downloads the
third-party components listed below. Each one stays under its own license; the
MIT License covers DayDream's own code only.

This file is in the root of the source repository. Packaged builds include it,
with `LICENSE.txt` and `NOTICE.txt`, in the app bundle's `Contents/Resources`
folder.

| Component | What DayDream uses it for | License | How it reaches you |
| --- | --- | --- | --- |
| [open-codex-computer-history](https://github.com/hqhq1025/open-codex-computer-history) | Parts of the activity recorder | MIT | Adapted source code, compiled into the app |
| [Sparkle](https://github.com/sparkle-project/Sparkle) 2.9.6 | Checking for and installing app updates | MIT, plus the notices listed below | Framework bundled in the app |
| [llama.cpp / ggml](https://github.com/ggml-org/llama.cpp) b9723 | Running the local summary model | MIT | Headers in the source tree; seven runtime libraries built from source and bundled inside the app (`Contents/Frameworks/WriterRuntime/`) |
| [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B), GGUF quantization by [Unsloth](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF) | The local summary model | Apache-2.0 | Downloaded when you choose to install local summaries; never bundled |
| [Typesense](https://github.com/typesense/typesense) 30.2 | The local search index (a separate program on the Mac) | GPL-3.0 | The unmodified official darwin-arm64 build, bundled as `Contents/Helpers/typesense-server`; its source is attached to every release |

## open-codex-computer-history (MIT)

Parts of DayDream's activity recorder are derived from open-codex-computer-history,
as published at commit `e756da5b` (August 2026):
<https://github.com/hqhq1025/open-codex-computer-history>.

DayDream reached this code through an earlier helper project by the DayDream
authors. The derived portions have since been modified. They are:

- `Event.swift`, `Frame.swift`, `Policy.swift` and `TextBuffer.swift` in
  `Sources/HistoryCore/` (event model, observation policy, typing buffer and
  message framing), and
- portions of `Sources/MacMemApp/EventCapture.swift`,
  `Sources/MacMemApp/AccessibilitySnapshot.swift` and
  `Sources/MacMemApp/Coordinator.swift` (for example the browser address
  lookup, terminal capture, and key and mouse naming), and
- test cases in `Tests/HistoryCoreTests/` (`PolicyTests.swift`,
  `TextBufferTests.swift` and `FrameTests.swift`).

Each of these files has a header that points to this notice.
DayDream's changes to the derived code are licensed under the MIT License. The
original code remains under this license:

```text
MIT License

Copyright (c) 2026 Open Codex Computer History contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

DayDream is an independent project. It is not affiliated with or endorsed by
OpenAI or by the authors of open-codex-computer-history.

## Sparkle (MIT and others)

Sparkle 2.9.6 is fetched from its official release by
`scripts/bootstrap-sparkle.py` (pinned in `packaging/sparkle.json`) and bundled
inside the app as `Contents/Frameworks/Sparkle.framework`. It is not committed
to this repository.

Sparkle's license file ships unchanged in every build as
`Contents/Resources/Sparkle-LICENSE.txt` in the app bundle, and is also in the
Sparkle release archive. It contains:

- Sparkle itself: MIT License. Copyright (c) 2006-2013 Andy Matuschak;
  2009-2013 Elgato Systems GmbH; 2011-2014 Kornel Lesiński; 2015-2017 Mayur
  Pawashe; 2014 C.W. Betts; 2014 Petroules Corporation; 2014 Big Nerd Ranch.
- bspatch.c and bsdiff.c from bsdiff 4.3: BSD 2-clause license. Copyright
  2003-2005 Colin Percival.
- sais.c and sais.h from sais-lite (2010/08/07): MIT License. Copyright (c)
  2008-2010 Yuta Mori.
- Portable C implementation of Ed25519 (orlp/ed25519): zlib license.
  Copyright (c) 2015 Orson Peters.
- SUSignatureVerifier.m: BSD 2-clause license. Copyright (c) 2011 Mark Hamlin.

## llama.cpp and ggml (MIT)

DayDream's local summaries use llama.cpp release `b9723`
(commit `b14e3fb90ca8c760f4254ddc9aa7845ebbdb2edf`). The C headers DayDream
compiles against are in `WriterBackend/Sources/CLlamaBridge/vendor/`, next to
their license. Release builds bundle seven runtime libraries (`libllama` and
six `libggml` libraries, about 5.2 MB) in
`Contents/Frameworks/WriterRuntime/`. They are built from that commit's source
for macOS 15 on Apple silicon, with the recipe and pins in
`WriterBackend/PROVENANCE.md`, and signed with DayDream's Developer ID. The
signed copies are committed in `packaging/WriterRuntime/`. Development builds
instead download the official `llama-b9723-bin-macos-arm64.tar.gz` release
and check it against a pinned SHA-256. Packaged builds also include this
license as `Contents/Resources/llama-MIT.txt` in the app bundle.

```text
MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Qwen3.5-4B (Apache-2.0)

The local summary model is Qwen3.5-4B by the Qwen team at Alibaba Cloud
(Copyright 2026 Alibaba Cloud), in the Q4_K_M GGUF quantization published by
Unsloth. Both are licensed under the Apache License, Version 2.0, whose full
text is in this repository's `WriterBackend/Notices/Qwen-APACHE-2.0.txt` file.
DayDream never bundles the model.
It downloads the pinned file from Hugging Face only when you choose to install
local summaries, and checks its SHA-256 (see `WriterBackend/PROVENANCE.md`).
Packaged builds include the Qwen license as
`Contents/Resources/Qwen-APACHE-2.0.txt` in the app bundle.

## Typesense (GPL-3.0)

DayDream bundles Typesense 30.2 (Copyright (C) Typesense, Inc. and the Typesense
contributors), a search server, as `Contents/Helpers/typesense-server`. It is a
separate program: DayDream starts it and talks to it only over HTTP on a loopback
port on the Mac. It keeps the search index of window titles, app names and
sites; typed words and notes are never added to it.

Typesense is licensed under the GNU General Public License, version 3. Packaged
builds include the full license as `Contents/Resources/Typesense-LICENSE.txt`
and the notice as `Contents/Resources/Typesense-NOTICES.txt`. Typesense comes
WITHOUT ANY WARRANTY, to the extent permitted by law; see the license.

The bundled copy is the official `typesense-server-30.2-darwin-arm64.tar.gz`
build from `dl.typesense.org` (archive SHA-256
`7d8d6d0c33930ad20ea23dd184250547b16615944be891b2078e8a075152fa7e`), unmodified.
DayDream did not patch or rebuild it. The only change is that its ad-hoc code
signature is replaced with DayDream's Developer ID signature, so macOS runs it
inside the notarized app; the program's code is unchanged.

**Source.** Its Complete Corresponding Source is the file
`typesense-30.2-complete-source.tar.gz` (SHA-256
`bf6a5eaa126c42dde00fc0a3e9256485e7b524683ff6989464f3ccb43aac4ae5`), attached to
every DayDream release next to the DMG at
<https://github.com/getnorthlight/daydream/releases>. It holds Typesense tag
`v30.2` (commit `d45d46baf3996d1de8bf96a87f375cfb43691560`), the source of
every library the tag's Bazel `WORKSPACE` builds into the server at its pinned
version, the libraries those builds fetch, the tag's patches and build scripts,
and a README with the build command and each library's version and license.
Typesense's build pins one library, the snowball stemmer (BSD-3-Clause), to a
branch rather than a commit; the README names the best-determined commit and the
archive also contains snowball's full history.

## Not included

DayDream does not include Node.js.

DayDream uses the SQLite library and Swift runtime that come with macOS. It does
not bundle copies of them.

## DayDream's own code and artwork

- The app icon (`packaging/Daydream-source.png` and the icon files made from it)
  was created by the DayDream authors with an AI image generator. Its embedded
  C2PA metadata records this. The icon is not licensed under the MIT License; see
  `TRADEMARKS.md`.
- DayDream's own code and artwork are by the DayDream authors. Third-party
  code is listed above under its own license.

## Website favicons

The X and Instagram favicons in `Sources/MemoryUI/Resources/SiteIcons/` identify
recorded website activity. They are unchanged bytes from the official websites,
retrieved September 30, 2026: `https://x.com/favicon.ico` and the Instagram
homepage's declared shortcut icon,
`https://static.cdninstagram.com/rsrc.php/y4/r/QaBlI0OZiks.ico`.
Both responses contain PNG images. These marks belong to their respective owners;
the source-code license does not grant rights to these marks. No separate asset
license was provided by those responses. Their inclusion implies no affiliation
or endorsement. No favicon request is made when displaying recorded activity.

The other website icons in `Sources/MemoryUI/Resources/SiteIcons/` (about 180
popular sites: YouTube, Reddit, Gmail, Outlook, Microsoft, GitHub, ChatGPT,
Canvas and so on) were retrieved October 3, 2026 from each site's own declared
favicon or touch icon (a few from the same company's static host, or from the
Internet Archive's copy when the site refused scripted requests) and resized to
at most 128 px. `tools/site-icons/sources.tsv` lists each icon's source URL and
the SHA-256 of the downloaded bytes; `tools/site-icons/fetch.py` is the
maintainer tool that retrieved them. These marks belong to their respective
owners; the source-code license does not grant rights to them, and their
inclusion implies no affiliation or endorsement. The app only matches a recorded
site's host against a built-in table and draws the bundled file: no favicon
request is made and no visited site leaves the Mac.
