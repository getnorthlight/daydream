# DayDream documentation

These pages explain how DayDream works. They describe the current code; where a feature is incomplete or not in the download, the page says so.

For everyone:

- [Guide](guide.md): what DayDream records and sends, permissions, summaries, AI apps, network connections and known limits.
- [Install](install.md): download, setup and first recording, with pictures.
- [Privacy and security FAQ](faq.md): short answers, such as "Is this a keylogger?" and "What leaves my Mac?".
- [Privacy policy](../PRIVACY.md): what DayDream keeps, what can leave your Mac, and how to reach us.
- [Uninstall](uninstall.md): remove DayDream, with or without your history.
- [From Mac Mem to DayDream](rename.md): what changed if you used a build from before the rename.

How it works:

- [Privacy model](privacy-model.md): what is recorded, what is refused, where history is stored and what can leave your Mac.
- [Browser capture](browser-capture.md): what DayDream does with web browsers, how Chrome page history works, and the one switch that leaves it out of a release.
- [Summaries](summaries.md): how moment and day notes are written and checked.
- [Backup and restore](backup-restore.md): what a backup contains and how restore merges it.

For maintainers:

- [RELEASE.md](../RELEASE.md): how a signed release is built, notarized and published.
- [Bad build plan](bad-build-plan.md): what to do in the first hours after a bad release.

Module notes for developers:

- [PrivacyPolicy/README.md](../PrivacyPolicy/README.md): the typed-text gate and secret classifier.
- [WriterBackend/README.md](../WriterBackend/README.md) and [PROVENANCE.md](../WriterBackend/PROVENANCE.md): the summary writer, and the pinned model and runtime sources.
- [BackupRestore/README.md](../BackupRestore/README.md): the backup container and helper.
- [BrowserBridge/README.md](../BrowserBridge/README.md): browser extension code that the app doesn't use in this version.

## Earlier name

DayDream was previously called Mac Mem. The earlier name still appears in some internal identifiers: the `mac-mem` command-line tool, the `MacMem` Swift package and target names, the `macmem://` links AI apps use, the `MAC_MEM_HOME` variable, and the backup format `macmem-native-backup-v1`. The data folder, bundle ID and Keychain service changed to DayDream names; [rename.md](rename.md) explains the one-time move from an older install.
