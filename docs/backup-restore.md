# Backup and restore

DayDream can save your history to a backup folder and merge a backup back into your current history. Both are started from Settings › Advanced › Backup and restore. This page explains what a backup contains and how restore protects the history you already have.

The code is in `BackupRestore/` (container format and worker), `Sources/MemoryCore/CanonicalBackupBinding.swift` (what is exported and merged) and `Sources/MacMemApp/BackupSettings.swift` (the Settings screen).

## Before you start

Stop recording and turn summaries off first. Settings will not start a backup or restore while either is running.

The work happens in a separate helper, `mac-mem-backup`, inside the app bundle. It runs with a CPU time limit, a file size limit and core dumps disabled. The app waits for it to exit, and cancelling stops it.

## What a backup contains

A backup is a new folder (by default `DayDream Backup`) readable only by your user account. It holds:

- `memory.sqlite`: a fresh database built for the backup, not a copy of the live file;
- `asset-<sha256>` files: attachments that came with history imported from an earlier version;
- `manifest.json`: the format (`macmem-native-backup-v1`), app version, record counts, and the size and SHA-256 of every file.

The database includes your actions, your corrections and activity names, summaries and generated notes, a record of deleted actions, history imported from an earlier version and your privacy settings. Actions that are deleted, or that your current privacy settings would exclude, are left out.

It does not include AI app grants, receipts, search indexes, pending summary work, your cloud API key (which stays in the Keychain) or the local model files.

**Backups are not encrypted.** Anyone who can read the folder can read the history in it. If you save it to a synced folder such as iCloud Drive, it is synced too. The SHA-256 values detect damaged files; they do not prove who made the backup.

An existing folder is never overwritten. If a backup fails partway, the incomplete folder may remain. It is not a valid backup; delete it and try again.

## Restoring

Restore never replaces your current history. It only adds to it.

1. **Choose a backup folder.** The helper checks the manifest, every file's size and SHA-256, and rejects symbolic links, hard links and unexpected files before it opens the database. It then checks the database structure and relationships.
2. **Review.** The app shows exactly which actions would be added. Nothing has changed yet. Your current privacy settings apply: backed-up actions they would exclude are not offered. The preview is valid for five minutes.
3. **Confirm.** The new actions are added in a single database transaction, with their activity names and any imported originals. Existing actions are kept as they are. Deletions recorded in the backup are applied, so an action deleted before the backup was made stays deleted. Settings, notes and summaries saved in the backup are not applied.

After a restore:

- recording stays off;
- every connected AI app loses its grant and must be connected again;
- existing notes are marked out of date and are written again once you turn [summaries](summaries.md) back on.

If the app quits between review and confirm, it remembers the pending review and asks you to look at it again. Nothing is restored automatically.

## Limits

A backup holds your whole history, up to 4 GB and 1,024 files. Backing up or restoring months of history can take a few minutes. A history larger than that cannot be backed up: the backup stops with an error rather than saving part of your history.

## Development checks

From the repository root:

```sh
sh BackupRestore/build-native.sh
```

This compiles `MemoryCore`, `HistoryCore`, the container, the helper and the command-line tool into `BackupRestore/.build/native/`, then runs the synthetic checks in `BackupRestore/Tests/NativeChecks.swift` against the built helper. It uses temporary stores only.
