# Bad build plan

A one-page card for the first hours after a release goes wrong. Keep it short and honest. [RELEASE.md](../RELEASE.md) has the full release steps.

## How updates reach people

- From 0.1.4, the app checks `https://getdaydream.app/appcast.xml` once a day. That file, published with the website, is the only list of versions those copies read; its download links point at the release's `.zip`.
- 0.1.3 copies check `https://github.com/getnorthlight/daydream/releases/latest/download/appcast.xml` instead (the `appcast.xml` attached to the newest release that is **not** a draft or a pre-release).
- A found update downloads quietly and installs the next time DayDream quits (log out and restart count), or when the person chooses Restart to Update. 0.1.3 copies ask first.
- Sparkle never installs an older version. People who already have the bad build stay on it until a newer build ships.

## 1. Decide (first 15 minutes)

It's a bad build if it does any of these:

- records something DayDream says it never records, or records while recording is off;
- loses or damages history;
- won't open, or crashes on launch for many people;
- sends data anywhere not listed in the README;
- fails a signature or notarization check.

If in doubt, pull it. Pulling a build costs little; leaving a privacy bug out costs a lot.

## 2. Stop the spread (next 15 minutes)

1. Put the last good `appcast.xml` back on the website (the copy you kept in that release's `$OUT/update`) and deploy the site. Never edit a signed appcast by hand: copies refuse it. Check:

   ```sh
   curl -s https://getdaydream.app/appcast.xml | grep -E 'sparkle:version|shortVersionString'
   ```
2. For 0.1.3 copies: on the bad release's GitHub page, choose **Edit** and tick **Set as a pre-release** (or `gh release edit v<bad version> --prerelease`), then check that `releases/latest` points to the last good release:

   ```sh
   curl -sIL https://github.com/getnorthlight/daydream/releases/latest/download/appcast.xml | grep -i '^location'
   ```

   GitHub and the website's cache can take a few minutes to catch up. A copy that already downloaded the bad build installs it at its next quit; only a newer build fixes that.
3. Put a warning at the top of the bad release's notes: "Don't install this build. [What's wrong, in one sentence.] Use [good version] instead." Its DMG stays downloadable; the warning is what stops people.
4. Don't delete the release or its tag. People need the notes, and the checksums have to stay checkable.

Now people on older versions aren't offered the bad build. People who already installed it still have it.

## 3. Tell people (within the first hour)

Say what happened, who is affected, what to do, and when the fix is coming. Don't guess at causes.

- **Pinned GitHub issue**, titled "[version] has a problem: [one line]". Keep it updated.
- **README**: one line under the title, linking to the issue.
- **X**: one post, linking to the issue.
- **Show HN, Reddit and Product Hunt threads**: reply once in each, with the same text.

Template:

> DayDream [version] has a bug: [what it does, in plain words]. [Who is affected.] If you installed it, [what to do now, e.g. stop recording / quit DayDream]. We've pulled it from updates. A fixed version is coming [today / by date]. Details: [issue link].

If history may have been recorded that shouldn't have been, say so plainly and tell people how to find and forget it.

## 4. Ship the fix (aim for 2 hours)

1. Fix on a branch, with a check that fails before the fix and passes after.
2. Raise the **build number** (`CFBundleVersion`) above the bad build. Sparkle compares build numbers, and people on the bad build are only offered a higher one.
3. Run the full check suite until every step exits 0.
4. Build, sign, notarize, staple and check exactly as [RELEASE.md](../RELEASE.md) says. Don't skip steps to save time.
5. Publish the new release as the latest, with its SHA-256 and a note: "Fixes [issue]. Everyone on [bad version] should update."
6. Check the feed now lists the new build, then update on a test Mac from the bad build.
7. If the bug is serious enough that people shouldn't wait, mark the update as critical in the appcast, if the Sparkle tools you use support it (check `generate_appcast --help`).
8. Close the loop: update the pinned issue, the README line, and each thread.

## If a signing key leaks

- **Update key (EdDSA private key in `~/DayDream-keys/`).** Someone could sign a fake update, although it would still need to be served from this repository's releases. Stop publishing, read Sparkle's documentation on changing keys before doing anything, and ship a build with a new key the way it describes. Tell people.
- **Developer ID certificate.** Revoke it in the Apple Developer account and contact Apple. Apps signed with it may stop opening. Ship a build signed with a new certificate, and tell people why.
- **GitHub account.** Change the password, revoke tokens and sessions, check recent releases and tags for anything you didn't make.

## Afterwards (within a week)

Write a short, public postmortem: what broke, who was affected, how long, how it was found, what changed so it can't happen the same way again. No blame, no spin. Link it from the issue.

## Not yet rehearsed

This plan hasn't been practised on a real release, because that needs a signed build. Rehearse it once before the first public release, in a separate test repository: publish two releases, mark the newer one as a pre-release, and check what `releases/latest` returns.
