# BackupRestore

The backup container and the helper process that creates and restores backups. [docs/backup-restore.md](../docs/backup-restore.md) describes what a backup contains and how restore works from a user's point of view.

## Layout

| Path | Contents |
| --- | --- |
| `Native/BackupContainer.swift` | The `macmem-native-backup-v1` folder format: export, verification, restore preview and confirm. Every path component is opened without following links, and new files are created exclusively, so existing files are never overwritten. |
| `Native/BackupWorker.swift` | Runs the helper as a child process with a deadline, bounded request and reply sizes, and cancellation. The app keeps its lease on the store until the child has exited. |
| `Worker/main.swift` | The `mac-mem-backup` helper. It disables core dumps and sets CPU time and file size limits before doing any work, and never includes paths, history or SQL in its error messages. |
| `Tests/NativeChecks.swift` | Synthetic checks against a real `MemoryCore` store and the built helper. |
| `build-native.sh` | Builds everything above without SwiftPM and runs the checks. |

What is exported and how a restore is merged is decided by `MemoryCore`, in `Sources/MemoryCore/CanonicalBackupBinding.swift`. The Settings screen is `Sources/MacMemApp/BackupSettings.swift`. The app target `MacMemBackup` in the root `Package.swift` builds the same helper for the app bundle.

## Checks

From the repository root:

```sh
sh BackupRestore/build-native.sh
```

Output goes to `BackupRestore/.build/native/`. The checks create temporary stores only.

## Legacy files

`backup_restore.py`, `test_backup_restore.py` and `component-manifest.json` are an earlier Python prototype. They are not used by the app, are not packaged and should not be extended.
