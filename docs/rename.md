# From Mac Mem to DayDream

DayDream was called Mac Mem while it was being built. Builds up to build 4 (September 2026) still used that name in a few places macOS shows or stores. From version 0.1.0 on, they use DayDream names:

| | Before | Now |
| --- | --- | --- |
| App in Finder | `Daydream.app` | `DayDream.app` |
| Bundle ID | `com.macmem.app` | `com.getnorthlight.daydream` |
| History folder | `~/Library/Application Support/Mac Mem/` | `~/Library/Application Support/DayDream/` |
| Settings | `com.macmem.app` preferences | `com.getnorthlight.daydream` preferences |
| Cloud summary key in Keychain | service `MacMem.Writer.OpenRouter` | service `DayDream.Writer.OpenRouter` |

The command-line tool keeps its name, `mac-mem`, and AI apps still see `macmem://` links.

## What happens the first time you open the new version

- **Your history moves.** If the old `Mac Mem` folder holds a history and the `DayDream` folder doesn't, DayDream moves the whole folder in one step. Nothing is copied or deleted. It writes `migrated-from-mac-mem.json` in the folder to record the move.
- **It waits if it isn't safe.** The folder doesn't move while the old app is running, while another recorder is using it. Until it moves, DayDream, the command-line tool and AI apps keep using the old folder, so nothing is split.
- **Two histories are never merged.** When both folders already hold a history, nothing moves and DayDream uses its own. Words typed in build 4 are kept in plain text in the old folder's history, so DayDream deletes those words there (a note of how many words stays) once the old app isn't running, and changes nothing else in that folder.
- **Your settings are copied once** from the old preferences, without overwriting anything.
- **Paste your cloud summary key again.** The old key belongs to the old app, and macOS would ask for your password to let the new app read it, so DayDream doesn't touch it. You can remove it with `security delete-generic-password -s MacMem.Writer.OpenRouter -a owner`.
- **Turn the permissions on again.** macOS ties Accessibility and Input Monitoring to the bundle ID, so the new app asks for them once. Remove the old entries in System Settings > Privacy & Security, or with `tccutil reset Accessibility com.macmem.app` and `tccutil reset ListenEvent com.macmem.app`.
- **Reconnect AI apps** whose configuration points at the old app or the old folder.

The code is in `Sources/MemoryCore/DaydreamIdentity.swift`, and `scripts/data-home-migration-checks.swift` checks it.
