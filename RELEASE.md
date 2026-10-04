# DayDream release runbook

This runbook makes a public DayDream release:

- `DayDream-<version>.dmg`, for Apple silicon Macs on macOS 15 or later, signed with the Developer ID Application certificate of team **L76C3ZC66J**, notarized and stapled;
- `DayDream-<version>.dmg.sha256`, taken **after** stapling;
- the release notes, from `docs/release-notes-template.md`;
- `DayDream-<version>.zip` and `appcast.xml`, the signed update that installed copies find through Sparkle. The appcast is published at `https://getdaydream.app/appcast.xml` (with the website); the zip is a release asset.

Everything is built from a clean `git archive` of one commit. Nothing is taken from an installed app or from another Mac. The commit is recorded in the app (`Contents/Resources/Companions.json`, `source_commit`), in `stage-receipt.json` and in the release notes.

The version shown to people is `x.y.z Beta` (About box, DMG window, release notes). File names and the tag use the number only: `DayDream-0.1.0.dmg`, tag `v0.1.0`.

Nothing here pushes, tags or uploads to GitHub. The owner does that by hand in §4.

## Tools

`scripts/developer-id-release.py`:

| Subcommand | What it does | Needs the signing key or Apple? |
|---|---|---|
| `stage` | Refuses unless the checkout is clean (no uncommitted or untracked files) and `--commit` is HEAD. Runs `git archive` of that commit into `<out>/source`, adds the pinned Sparkle, builds `MacMem`, `mac-mem` and `mac-mem-backup` with `swift build -c release` and the full-typing flags (see [Typing in every release](#typing-in-every-release)), and assembles an unsigned `DayDream.app` from those builds and the files of that commit. Writes the release Info.plist (`x.y.z Beta`, Sparkle settings from `packaging/updates.json`) and records the commit. `--out` must be a new folder outside the repository. Needs `--previous-build`, the build of the last copy anyone installed (a release or a test build): `--build` must be higher. Only the very first build passes `--first-build` instead. | no, offline |
| `sign --identity <SHA-1>` | Signs a copy, inside-out, with explicit per-item flags (table below), then runs `verify`. `--identity -` is an ad-hoc dry run that still uses `--options runtime`. | signing key and Apple's timestamp server |
| `verify --expect developer-id` | `codesign --verify --strict --deep`, then per item: runtime flag, secure timestamp, no `get-task-allow`, exact entitlements, identifiers, team `L76C3ZC66J`, one leaf certificate. Also the companion hashes, the designated requirement, the update settings and, once stapled, the ticket. | no |
| `dmg` | Builds `DayDream-<version>.dmg` from the stapled app and signs the image. The name must match the app's version. The window background shows `DayDream <version> Beta`. A test build gets its own name instead: `--name "DayDream - <words>.dmg"`, on a volume of the same name (or `--volume-name`). | signing key |
| `notarize` | Prints its commands only. Runs them only with `--execute --keychain-profile daydream-notary`. Re-verifies before uploading. `--resume` waits on a saved submission instead of uploading again. | Apple upload |
| `staple` | Prints its commands only. Runs them only with `--execute --notary-dir <notarize --out>`. Needs the `Accepted` receipt whose CDHash matches. For a DMG it then writes `<dmg>.sha256`, because stapling changes the file. | Apple CDN |
| `checksum` | Rewrites `<dmg>.sha256` for a stapled DMG. Refuses an image that is not stapled. | no |
| `notes` | Fills `docs/release-notes-template.md`: version, build, commit, macOS minimum, download name and the post-staple SHA-256. | no |

`scripts/release.py`:

| Action | What it does |
|---|---|
| `make-key` | Makes the update key once, as a file (§1). Never the Keychain. Refuses to replace an existing key. |
| `public-key` / `set-public-key` | Prints the public half / writes it into `packaging/updates.json`. |
| `validate` | Checks `packaging/updates.json`. No network, no key. |
| `prepare` | From the signed, stapled app: `DayDream-<version>.zip`, the notes as `DayDream-<version>.md`, and `appcast.xml` signed by `generate_appcast --ed-key-file`. Checks the result with DayDream's own verifier and `sign_update --verify`. Uploads nothing. |
| `appcast` | The same from the signed, notarized, stapled `DayDream-<version>.dmg` (`--dmg`) or a `.zip` of the stapled app (`--zip`), with plain-text notes (`--notes notes.txt`). `--download-url-prefix` names where the zip will be uploaded (default: the GitHub release `v<version>`). Uploads and publishes nothing. |

`scripts/signing_plan.py --app <staged app> --staging <new dir>` prints every command below, in order, as JSON. It runs nothing.

### Signing order

Every signing command is `codesign --force --sign <SHA-1> --timestamp --options runtime`, never `--deep`.

| # | Item | Extra flags | Entitlements |
|---|---|---|---|
| 1 | `Sparkle.framework/Versions/B/XPCServices/Installer.xpc` | – | none |
| 2 | `…/XPCServices/Downloader.xpc` | `--preserve-metadata=entitlements` | preserved (`{}` in Sparkle 2.9.6) |
| 3 | `…/Versions/B/Autoupdate` | – | none; this drops `com.apple.application-identifier` ([Sparkle](https://sparkle-project.org/documentation/sandboxing/), [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)) |
| 4 | `…/Versions/B/Updater.app` | – | none |
| 5 | `Sparkle.framework` | – | none |
| 6 | `MacOS/mac-mem` | `--identifier com.getnorthlight.daydream.mac-mem` | none |
| 7 | `MacOS/mac-mem-backup` | `--identifier com.getnorthlight.daydream.mac-mem-backup` | none |
| 8 | `release.py manifest` | hashes the signed helpers into `Companions.json` (keeps `source_commit`) | – |
| 9 | `DayDream.app` (`com.getnorthlight.daydream`) | – | `main-apple-events.entitlements` when Chrome page history ships, otherwise none |

### The Chrome switch and `--apple-events`

Chrome page history ships (off until the person turns it on). One switch decides it: `ReleaseFeatures.chromePageHistory` in `Sources/MemoryCore/ReleaseFeatures.swift`.

- `--apple-events` follows that switch by default in `sign`, `verify`, `notarize`, `staple` and `signing_plan.py`. Leave it out.
- Passing `--apple-events` or `--no-apple-events` that disagrees with the switch is refused.
- With the switch off, `stage` also drops `NSAppleEventsUsageDescription` from the Info.plist.
- Never add another main-app entitlement.

### Typing in every release

Since the owner's decision of 2026-09-25, `stage` always builds the full-typing app. It passes the two typing defines (`OWNER_SWIFT_FLAGS` in `scripts/developer-id-release.py`) to every `swift build`, so the release can record typing in the apps on the typing list and on websites in Google Chrome. Both stay off until the person turns typed text on, and websites also need Web pages in Chrome. `stage` refuses an app whose `MacMem` doesn't carry the website typing code.

- **A public stage** is the normal case: no extra flag. It refuses to run while the owner switch is set in the environment, and refuses an app that carries the owner's Info.plist mark.
- **`--owner-build`** is only for the owner's own private copy of that same app. `stage` marks its Info.plist (`MacMemOwnerTyping`) and needs `--updates off`, so it never reads the public update feed. Pass `--owner-build` to `stage`, `dmg` and `notarize`; `dmg` names it `DayDream-<version>-owner.dmg`. `notes` and `release.py prepare` refuse it, so it never gets release notes or goes into the appcast. Never publish it.
- `--owner-build` doesn't change what typing does. The public release and the owner's copy record the same things.

---

## 1. Owner: make the update key (once, ever)

Installed copies of DayDream trust exactly one update key. Its public half is built into every release. **If the private key is lost, no installed copy can ever be updated again**; people would have to download a new version by hand. If it leaks, someone else could sign updates. So make it once, back it up twice, and never commit it.

Sparkle's own `generate_keys` always puts the key in the login Keychain, so DayDream makes it as a plain file instead:

```sh
cd <repo>
python3 scripts/release.py make-key
```

This writes:

- `~/DayDream-keys/sparkle-ed25519.key`: the private key (folder `chmod 700`, file `chmod 600`). Only its owner can read it.
- `~/DayDream-keys/sparkle-ed25519.pub`: the public key. Safe to share.

It refuses if the key already exists. Never delete it to make a new one.

Then put the public key in the repo and commit it:

```sh
python3 scripts/release.py set-public-key      # writes packaging/updates.json
python3 scripts/release.py validate
git add packaging/updates.json && git commit -m "Set the update public key"
```

**Back it up now, to two separate offline places you control** (for example an encrypted external drive and a password manager).

To restore it on another Mac: create `~/DayDream-keys`, put the line back in `sparkle-ed25519.key`, then `chmod 700 ~/DayDream-keys` and `chmod 600 ~/DayDream-keys/sparkle-ed25519.key`. `python3 scripts/release.py public-key` must print the same public key as `packaging/updates.json`.

Rules:

- Never commit the key, paste it in a chat, email it or put it in the Keychain. `release.py` refuses a key inside the repository, in a Keychain or from standard input, and a key file whose permissions are looser than 600/700.
- The release tools only ever read it with `--ed-key-file`. Nothing uses `--account` or the Keychain.
- None of the release scripts make, read or copy the real key. Tests use a throwaway key in a temp folder.

## 2. Owner: signing setup (once per Mac that signs)

Do these at the signing Mac itself, in a normal logged-in session (a local Terminal window, not SSH). None of the release scripts run `security`, read the Keychain or handle a password.

1. **Check the signing certificate.** Keychain Access → **login** → **My Certificates** must show **Developer ID Application: \<your name\> (L76C3ZC66J)** with a private key under it. Double-click it → **Details** → **Fingerprints**:
   - The enrolled certificate's **SHA-256** is `4B 87 CD 4E 80 28 0E B7 A2 FC 8D EE 7D 50 BF 5F B5 34 F6 F7 3F 17 23 43 BC 16 DC FE 36 A1 A9 AF`. Use it. Every release carries the "On this Mac" runtime, signed with this certificate ([Writer runtime](#writer-runtime)), and `sign` and `verify` refuse a release app signed with another one. Only a test build staged with `--without-writer-runtime-for-tests` may use a different Developer ID Application certificate from team L76C3ZC66J; `verify` prints a NOTE.
   - Note the **SHA-1** (40 hex characters, not secret) and pass it to `sign`. `sign` accepts only a SHA-1, so the exact certificate is used.
2. **Make an app-specific password** at [account.apple.com](https://account.apple.com) → Sign-In and Security → App-Specific Passwords. Name it `daydream-notary` ([Apple support](https://support.apple.com/en-us/102654)).
3. **Store the notary profile**, in a local Terminal window:
   ```sh
   xcrun notarytool store-credentials daydream-notary --apple-id <your Apple ID email> --team-id L76C3ZC66J
   ```
4. **Stay at the Mac for the first signing run.** The first `codesign` asks to use the key. Enter the login password and click **Always Allow**. Keep the screen unlocked; `codesign` gives up after 15 minutes.
5. **Give three separate approvals:** (a) sign with `<SHA-1>`; (b) upload the app to Apple for notarization; (c) upload the DMG to Apple for notarization.

---

## 3. Build the release

`OUT` must be a new folder outside the repository and not under `/private/tmp`. Signing and notarizing (steps 3–5) need the login Keychain and the network, so they run in the owner's logged-in session, outside any command sandbox. A timestamp or Keychain error there is an environment problem: never drop `--timestamp` to get past it.

```sh
REPO=<release checkout, clean, at the commit to release>
ID=<40-hex SHA-1 from §2>
VERSION=0.1.0                                  # numeric; "Beta" is added to what people see
BUILD=$(date +%Y%m%d%H%M%S)                    # must exceed every earlier release
PREVIOUS=<CFBundleVersion of the last copy anyone installed, release or test>   # the very first build: --first-build instead
OUT="$HOME/DaydreamReleases/$BUILD"            # new folder
TS_INPUTS=<folder with the pinned Typesense runtime.tar.gz and typesense-server>   # see "Typesense" below
TS_KIT=<path to typesense-30.2-complete-source.tar.gz>                            # its source, attached in §4
P=(python3 -B "$REPO/scripts/developer-id-release.py")

# 1. Get the pinned Sparkle (checks the archive and every file; writes nothing else).
python3 "$REPO/scripts/bootstrap-sparkle.py"
python3 "$REPO/scripts/release.py" validate

# 2. Stage from a clean archive of HEAD (offline). Refuses uncommitted or untracked files, a commit
#    without the signed "On this Mac" runtime ("writer runtime not signed yet", see Writer runtime below),
#    and a Typesense source kit whose SHA-256 is not the one scripts/search_payload.py records.
"${P[@]}" stage --out "$OUT/stage" --build "$BUILD" --previous-build "$PREVIOUS" --version "$VERSION" \
    --typesense-inputs "$TS_INPUTS" --typesense-source-kit "$TS_KIT"
cat "$OUT/stage/stage-receipt.json"            # source_commit = the commit you meant; writer_runtime = its ID;
                                               # typesense_source_kit = the kit to attach in §4

# 3. Sign (approval a). Also runs verify --expect developer-id.
"${P[@]}" sign --app "$OUT/stage/DayDream.app" --out "$OUT/signed" --identity "$ID"
A="$OUT/signed/DayDream.app"

# 4. Notarize and staple the app (approval b).
"${P[@]}" notarize --artifact "$A" --out "$OUT/notary" --keychain-profile daydream-notary --execute
"${P[@]}" staple --artifact "$A" --notary-dir "$OUT/notary" --execute

# 5. DMG from the stapled app, then notarize and staple it (approval c).
#    Staple writes DayDream-$VERSION.dmg.sha256 after stapling.
D="$OUT/DayDream-$VERSION.dmg"
"${P[@]}" dmg --app "$A" --out "$D" --identity "$ID"
"${P[@]}" notarize --artifact "$D" --out "$OUT/notary" --keychain-profile daydream-notary --execute
"${P[@]}" staple --artifact "$D" --notary-dir "$OUT/notary" --execute
cat "$D.sha256"

# 6. Read-only checks. check_dmg.py never launches the app unless --launch-isolated is passed.
python3 -B "$REPO/scripts/check_dmg.py" "$D" --expect-developer-id
python3 -B "$REPO/scripts/check_dmg_layout.py" --app "$A" "$D"
TMPDIR="$OUT" DAYDREAM_EXPECT_TEAM=L76C3ZC66J DAYDREAM_EXPECT_STAPLED=1 bash "$REPO/scripts/verify-dmg-seal.sh" "$D"

# 7. Release notes. Fill in "What's new" and "Known problems" (every [ ] line) by hand.
"${P[@]}" notes --app "$A" --dmg "$D" --out "$OUT/DayDream-$VERSION.md"
open -e "$OUT/DayDream-$VERSION.md"

# 8. The signed update (reads ~/DayDream-keys/sparkle-ed25519.key; refuses notes with a [ left in).
python3 -B "$REPO/scripts/release.py" prepare --app "$A" --notes "$OUT/DayDream-$VERSION.md" \
    --output "$OUT/update" --previous-build "$PREVIOUS" --confirm-redistribution-rights
```

`--confirm-redistribution-rights` means: you checked `THIRD-PARTY-NOTICES.md` for this release, and you will attach the Typesense source kit to the GitHub release (§4).

### Typesense

Every build bundles Typesense 30.2 (GPL-3.0), the unmodified official darwin-arm64 build, as
`Contents/Helpers/typesense-server` (owner decision 2026-10-03, "Ship typesense."). It is public: its record
(`packaging/TypesenseRuntime/local-typesense-v30.2.json`) says so and names its Complete Corresponding Source kit,
`typesense-30.2-complete-source.tar.gz`, by SHA-256 (`bf6a5eaa126c42dde00fc0a3e9256485e7b524683ff6989464f3ccb43aac4ae5`,
624,901,777 bytes). GPLv3 section 6(d) is met by attaching that exact file to every GitHub release next to the DMG (§4),
for as long as the release is offered.

- `TS_INPUTS`: the vendor archive `https://dl.typesense.org/releases/30.2/typesense-server-30.2-darwin-arm64.tar.gz`
  as `runtime.tar.gz`, and the `typesense-server` extracted from it unchanged. `stage` checks both by SHA-256.
- `TS_KIT`: the kit built on 2026-10-03 (`launch-candidate/typesense-source-30.2/`). Keep that exact file. Never rebuild
  it in place: a rebuilt archive has a different SHA-256, and `stage` refuses it.
- A public stage (updates configured) refuses without the matching kit, and refuses if the commit's record is not the
  cleared public one. An owner stage (`--updates off`) needs no kit.
- The snowball library's commit in the vendor binary is a best determination (the kit's README explains it). If
  Typesense confirms another commit, add that commit's source to a new kit, record the new SHA-256 in
  `scripts/search_payload.py` and the record, and use the new kit from then on.

Rules:

- Never run `polish-dmg.sh` on a signed or notarized image. It refuses one, because rebuilding drops the signature and ticket.
- Never take the checksum yourself before stapling. `staple` and `checksum` write it; `notes` refuses a checksum that doesn't match the file.
- If notarization returns `Invalid`, read `$OUT/notary/notary-*-log-*.json` and fix the cause ([common issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)). Never broaden entitlements to get past a failure.

### A test build

A test build gets a DMG file and volume name of its own, so it never looks like the release or an earlier test. Stage it after the last test build (`<last test build>`), with a higher `--version` too, so Settings and the update window can tell the two apart:

```sh
"${P[@]}" stage --out "$OUT/stage" --build "$BUILD" --previous-build <last test build> --version "$VERSION"
# steps 3 and 4 as above, then:
D="$OUT/DayDream - Test N.dmg"
"${P[@]}" dmg --app "$A" --out "$OUT" --name "DayDream - Test N.dmg" --identity "$ID"
```

The volume is `DayDream - Test N`; `--volume-name "DayDream <words>"` sets another. Notarize, staple and check `"$D"` as in steps 5 and 6. `notes` refuses a test image, so skip steps 7 and 8.

### A test build with no updates

Before the update key exists (§1), or for a copy that must never update, build with updates off. Add `--updates off` to `stage`, `sign`, `verify`, `notarize` and `staple`, and to the check:

```sh
python3 -B "$REPO/scripts/check_dmg.py" "$D" --expect-developer-id --updates off
```

Such a build has no update feed and no update key, so it never checks for updates. Skip step 8: `release.py prepare` makes the signed update, which needs the key. Don't publish it as a release.

### Writer runtime

Every release carries the "On this Mac" runtime:
- seven llama.cpp libraries (about 5.2 MB) and their manifest;
- committed, already signed, in `packaging/WriterRuntime/daydream-qwen35-b9723-macos15-v2/` (the `.gitignore` lets these dylibs in).

The model (2.74 GB) is never bundled: the app downloads it only when someone chooses On this Mac.

`stage` checks the set before it copies anything:
- the manifest's SHA-256 equals the pin compiled into this commit's `SignedRuntimePolicy.swift`;
- the folder holds exactly the manifest and the seven libraries;
- each library's bytes equal the manifest and pass the loader's Mach-O rule (`@loader_path` only);
- each library has a strict Developer ID signature from team L76C3ZC66J with the manifest's identifier, the hardened runtime, no entitlements and the enrolled leaf certificate (§2).

Then it copies the files unchanged:
- the manifest to `Contents/Resources/WriterRuntime/<ID>.json`;
- the libraries to `Contents/Frameworks/WriterRuntime/<ID>/`;
- and it sets `DaydreamWriterRuntimeDistribution` in `Info.plist`.

`sign` verifies the libraries and never re-signs them; the app is signed last. `verify`, `dmg`, `release.py prepare` and `verify-app-companions.py` check that the set is present and unchanged.

Without the signed set, `stage` stops with `writer runtime not signed yet`. `--without-writer-runtime-for-tests` stages a test app without it:
- On this Mac is greyed out in that app;
- its receipt says `test_only_without_writer_runtime: true`;
- `release.py prepare` and a Developer ID `dmg` refuse it.

**Signing the set** happens once, and again only after a certificate renewal or a llama.cpp update. It runs at the signing Mac, like §3:

1. Build the libraries and prepare them for signing, as `WriterBackend/PROVENANCE.md` describes (`WriterBackend/build_macos15_runtime.py`, then `scripts/prepare_writer_macos15.py`). Check the result with `python3 WriterBackend/runtime_distribution.py check-prepared <prepared>`.
2. Sign each library once, with no entitlements:
   ```sh
   codesign --force --sign <SHA-1> --timestamp --options runtime --identifier com.getnorthlight.daydream.writer.<name> <library>
   ```
   (`python3 WriterBackend/runtime_distribution.py identifiers` lists the seven identifiers.)
3. Write the manifest with `python3 WriterBackend/runtime_distribution.py manifest-v2 <signed dir> <leaf SHA-256> --prepared <prepared> --out <ID>.json`. It prints the manifest's SHA-256.
4. Audit the set with `python3 WriterBackend/audit_signed_runtime.py <dir with the manifest and libraries> <prepared> --not-pinned-yet`.
5. Pin and commit:
   - replace the single entry in `SignedRuntimePolicy.approvedManifestSHA256` with `"<ID>": "<SHA-256>"`;
   - commit the eight files under `packaging/WriterRuntime/<ID>/`;
   - run the audit again without `--not-pinned-yet`, plus `scripts/check_developer_id_release.py`.

### If a step fails

Every step refuses to overwrite its own output.

| Step | Left behind | What to do |
|---|---|---|
| `stage` refuses | nothing | Commit or remove the changes it names, then re-run. `writer runtime not signed yet`: see [Writer runtime](#writer-runtime). |
| `stage` fails while building | `$OUT/stage` | Delete `$OUT/stage` and re-run. Nothing was signed. |
| `sign` | `$OUT/signed` | Delete `$OUT/signed` and re-run. A 15-minute timeout means the Keychain prompt was not answered. |
| `notarize` stopped while waiting | `$OUT/notary/notary-<app\|dmg>.json` | Re-run the same command with `--resume`. It never uploads again. |
| `notarize` with no saved id | receipt with status `uploading` | Run `xcrun notarytool history --keychain-profile daydream-notary`. If Apple has it, save `{"id": "<id>"}` as `$OUT/notary/notary-<kind>.json` and use `--resume`; otherwise move `$OUT/notary` aside and notarize again. |
| `notarize` returned `Invalid` | the log | Fix it, then start again with a new `BUILD` and `OUT`. |
| `staple` | nothing, or a stapled artifact | Re-run. A ticket download error means Apple's CDN is not ready yet; wait a few minutes. |
| `dmg` | nothing at `--out` | Re-run. If an image is still attached, `hdiutil detach` it first. |
| `prepare` | `$OUT/update` (partial) | Read the error, delete `$OUT/update`, re-run. Nothing was uploaded. |

---

## 4. Owner: publish on GitHub

Do this by hand on github.com/getnorthlight/daydream. Upload only files from `$OUT` that the steps above made.

1. Push the release commit (the `source_commit` in `stage-receipt.json`) to `main`.
2. **Releases → Draft a new release.**
   - Tag: `v<version>` (for example `v0.1.0`), on that commit.
   - Title: `DayDream <version> Beta`.
   - Description: paste `$OUT/DayDream-<version>.md`.
3. Attach these files:
   - `DayDream-<version>.dmg`
   - `DayDream-<version>.dmg.sha256`
   - `update/DayDream-<version>.zip`
   - `update/appcast.xml` (for 0.1.3 copies, which read the latest release's appcast)
   - `typesense-30.2-complete-source.tar.gz` and `typesense-30.2-complete-source.tar.gz.sha256`: the Typesense
     source (GPLv3 6(d)). Every release that ships Typesense needs it, the same file each time. The repository and
     its releases must be public for this to count.
4. **Do not tick "Set as a pre-release".** Tick **"Set as the latest release"**. GitHub's "latest" skips pre-releases. The word Beta is already in the version.
5. Publish. Then copy `update/appcast.xml` into the website as `appcast.xml` (served at `https://getdaydream.app/appcast.xml`) and deploy the site. 0.1.4 and later read only that file. Then check, from any Mac:
   ```sh
   curl -s https://getdaydream.app/appcast.xml | grep -E 'sparkle:version|shortVersionString|enclosure'
   curl -sL https://github.com/getnorthlight/daydream/releases/latest/download/appcast.xml | grep -E 'sparkle:version|shortVersionString|enclosure'
   curl -sL -o /tmp/d.dmg https://github.com/getnorthlight/daydream/releases/download/v<version>/DayDream-<version>.dmg && shasum -a 256 /tmp/d.dmg
   ```
   The build and version must be the new ones, and the SHA-256 must equal the `.sha256` file.
6. Keep `$OUT` and every earlier release on GitHub. Never delete or replace an asset of a published release; make a new release instead.

## 5. Test an update between two versions

Do this before telling people about updates, and again after any change to Sparkle, signing or the update settings.

1. Install release A (for example `0.1.0`) on a test Mac as in §6, and launch it once.
2. Build release B the same way, with a higher `--version` or at least a higher `BUILD`.
3. Publish B as in §4, as the latest release.
4. In A: **Settings › App updates › Check Now**. Nothing pops up; within a minute the status line says `DayDream <B> is ready.`, and the menu bar menu shows **Restart to Update** above Quit. (A copy older than 0.1.4 asks in Sparkle's window instead.)
5. Start recording in A, then choose **Restart to Update**. Recording stops, B opens, and recording starts again by itself. Also try the other path once: let B download, quit A, open DayDream again: it is B.
6. Check:
   - **About** shows B's version.
   - History, settings and the Accessibility and Input Monitoring grants are still there.
   - `spctl -a -vvv /Applications/DayDream.app` says `Notarized Developer ID`.
7. Nothing interrupts: no window, notification or Dock bounce appears while B downloads and waits. With **Update automatically** off, Check Now still finds B, and nothing downloads until it is pressed.

If the update fails, Console.app (filter "Sparkle" or "DayDream") shows why. Common causes: the app's public key doesn't match the key file, the build number is not higher, or the release is marked as a pre-release.

---

## 6. Owner: install on a test Mac

1. **Check the Mac.**
   ```sh
   uname -m        # arm64
   sw_vers         # ProductVersion 15.0 or later
   ```
2. **Download** `DayDream-<version>.dmg` from the release page in a browser. Check it:
   ```sh
   shasum -a 256 ~/Downloads/DayDream-<version>.dmg        # equals the .sha256 file and the notes
   spctl -a -vvv -t open --context context:primary-signature ~/Downloads/DayDream-<version>.dmg   # source=Notarized Developer ID
   ```
3. **Install.** Open the DMG. Its window shows `DayDream <version> Beta`. Drag **DayDream** onto **Applications** and eject. Keep exactly one `DayDream.app`.
4. **First launch.** Open `/Applications/DayDream.app` and confirm the "downloaded from the Internet" dialog. Turn on DayDream in **System Settings → Privacy & Security → Accessibility** and **Input Monitoring**. If macOS asks, quit and reopen. Press **Start**.
5. **Confirm**, read-only:
   ```sh
   codesign -dv --verbose=2 /Applications/DayDream.app 2>&1 | grep -E 'Authority=Developer ID Application|TeamIdentifier|flags'
   codesign -d -r- /Applications/DayDream.app      # … leaf[subject.OU] = L76C3ZC66J
   spctl -a -vvv /Applications/DayDream.app        # accepted, source=Notarized Developer ID
   defaults read /Applications/DayDream.app/Contents/Info.plist CFBundleShortVersionString   # x.y.z Beta
   defaults read /Applications/DayDream.app/Contents/Info.plist SUFeedURL                    # https://getdaydream.app/appcast.xml
   ```
   **DayDream → About** must say `x.y.z Beta`. **Settings › Advanced › App updates** must show "Update automatically" on.
6. **Later versions** arrive by themselves and install at the next quit or at Restart to Update (§5). A manual install also works: quit DayDream, drag the new app to Applications and choose **Replace**. Grants stay, because the bundle ID and team are unchanged.

### Claude Code MCP on a test Mac

The CLI and MCP server are inside the app. After DayDream has been launched once, use **Settings › Connections › Claude Code › Connect…**, or the same step in Terminal:

```sh
MAC_MEM=/Applications/DayDream.app/Contents/MacOS/mac-mem
"$MAC_MEM" connect claude-code      # shows the entry and the settings file, asks, keeps a backup, then writes it
"$MAC_MEM" connections             # Claude Code should say Connected
```

The key is written straight into Claude Code's settings file and never printed. Don't pass `--home`: the tool finds the history folder itself, including before the one-time move from the old Mac Mem folder.

Use the `/Applications/…` path. After an update the MCP server asks to be restarted once, because the app's helpers changed.

---

## 7. Known limits

1. **Every release carries Typesense** (public since 0.1.4, owner decision 2026-10-03): the unmodified official 30.2 build under GPL-3.0, with its license and notice in `Contents/Resources` and its source kit attached to the release ([Typesense](#typesense)). It makes the update archive about 58 MB, so the archive goes on the GitHub release, not on Cloudflare Pages (25 MB file limit). The legacy functional-trial payload stays private. Every release, public or owner, also carries the "On this Mac" runtime (about 5 MB, [Writer runtime](#writer-runtime)). The 2.74 GB model is downloaded only if someone chooses On this Mac, and it needs Apple silicon, macOS 15 or later and 8 GB of memory. The app goes online for it only on a click: the model download, and a check with Apple about the signing certificate when the certificate status macOS saved has run out. After a restart, On this Mac turns back on with the checks already on the Mac, never by going online.
2. **A certificate renewal** means signing the runtime libraries again ([Writer runtime](#writer-runtime)), with a new pin and a new `LEAF_SHA256`, before the next release. Until then `stage` refuses to build a release. Installed copies keep working. Permission grants, notarization and updates don't depend on the certificate; updates depend only on the update key.
3. **Losing the update key** ends updates for every installed copy (§1). There is no recovery except a manual download of a release signed with a new key.
