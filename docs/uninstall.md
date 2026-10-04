# Uninstall DayDream

You can remove DayDream from inside the app, or by hand. Both ways cover the current name (DayDream, `com.getnorthlight.daydream`) and the name builds up to build 4 used (Mac Mem, `com.macmem.app`). [rename.md](rename.md) explains the two names.

## From inside DayDream

1. Open DayDream's Settings and choose **Advanced**.
2. At the bottom, click **Uninstall DayDream…**.
3. Pick one:
   - **Keep my history.** Removes the app. Your history and settings stay on this Mac, so DayDream picks up where you left off if you install it again.
   - **Remove everything.** Removes the app, your history and your settings, including the Mac Mem folder from before the rename if you have one. DayDream asks once more, because this can't be undone.
4. Anything DayDream will leave in place is listed with the reason. **Details** lists exactly what will be removed before you confirm.

DayDream then pauses recording, moves itself to the Trash and shows what is left for you to do, one line per step. Click **Copy Steps** to keep the full list, with its Terminal commands, then **Quit DayDream**.

### What each choice removes

| | Keep my history | Remove everything |
| --- | --- | --- |
| `DayDream.app` or `Daydream.app` in `/Applications` or `~/Applications` (moved to the Trash) | Yes | Yes |
| A DayDream login item | Yes | Yes |
| App caches: `~/Library/Caches`, `~/Library/HTTPStorages` and `~/Library/Saved Application State` entries for both app IDs | Yes | Yes |
| `~/Library/Application Support/DayDream` (history, downloaded models, AI app connection files) | No | Deleted |
| `~/Library/Application Support/Mac Mem` (history from before the rename) | No | Deleted |
| `~/Library/Application Support/DayDream.before-move-<number>` (left by the rename move, if any) | No | Deleted |
| `~/Library/Application Support/Daydream`, only on a case-sensitive disk and only if it holds a DayDream history (`memory.sqlite`) or the rename move's marker (`migrated-from-mac-mem.json`) | No | Deleted |
| Settings of both app IDs (`~/Library/Preferences/com.getnorthlight.daydream*.plist`, `com.macmem.app.plist`) | No | Deleted |
| The DayDream typing key in the Keychain (`DayDream.TypedText`), if you turned on typing | No | Deleted, see [step 3](#what-no-app-can-do-for-you) |

Deleted means deleted, not moved to the Trash. Only the apps go to the Trash.

DayDream never touches anything outside that list. It leaves a path in place, and tells you why, when:

- it is a link (alias) rather than the real file or folder. What the link points to isn't touched either;
- it belongs to another user;
- it isn't DayDream, for example another app named `Daydream.app`, or a development copy;
- it is a separate `Daydream` folder (on a case-sensitive disk) that holds no DayDream history.

### When the Uninstall button is off

- **DayDream isn't in Applications.** Uninstall works only for DayDream in `/Applications` or `~/Applications`. Quit DayDream and drag it to the Trash, then follow the steps below.
- **DayDream was opened through a link.** Open it from the Applications folder instead.
- **It's a development copy**, or it uses a custom history folder (`MAC_MEM_HOME`). Remove it by hand.
- **A backup, restore, history import or recorder replacement is running.** Wait for it to finish, then try again.

If DayDream can't move itself to the Trash (for example when it was installed by an administrator), it stops right there and removes nothing else. Quit DayDream, drag it from Applications to the Trash (Finder may ask for your password), then follow the steps below.

## What no app can do for you

An app can't remove these, except the typing key: Remove everything deletes it (step 3). The in-app list and the steps below include them.

1. **Permissions.** Open System Settings > Privacy & Security. In **Accessibility**, **Input Monitoring** and **Automation**, select DayDream (and Daydream or Mac Mem, if listed) and click the minus button. Or run this in Terminal:

   ```sh
   tccutil reset Accessibility com.getnorthlight.daydream
   tccutil reset ListenEvent com.getnorthlight.daydream
   tccutil reset AppleEvents com.getnorthlight.daydream
   tccutil reset Accessibility com.macmem.app
   tccutil reset ListenEvent com.macmem.app
   tccutil reset AppleEvents com.macmem.app
   ```

   `ListenEvent` is Input Monitoring. `AppleEvents` is Automation, which DayDream uses only for Chrome pages.

2. **Cloud summary key.** If you added an OpenRouter key, open Keychain Access, search for `DayDream.Writer.OpenRouter` and `MacMem.Writer.OpenRouter`, and delete what you find. Or run:

   ```sh
   security delete-generic-password -s DayDream.Writer.OpenRouter -a owner
   security delete-generic-password -s MacMem.Writer.OpenRouter -a owner
   ```

   "The specified item could not be found" means there was nothing to delete.

3. **Typing key.** If you turned on typing, the Keychain holds the DayDream typing key (`DayDream.TypedText`). It opens the words you typed, which are in your history.
   - If you kept your history, leave the key: without it, the words you typed can't be read.
   - If you chose **Remove everything**, DayDream deleted the key from this Mac's Keychain. If it couldn't, the list it shows says so and why. A Time Machine backup of your login keychain may still hold a copy of the key, next to copies of your history (step 6).
   - If you removed DayDream by hand, or DayDream couldn't delete the key, delete it yourself. Open Keychain Access, search for `DayDream.TypedText`, and delete what you find. Or run this until it says the item could not be found:

   ```sh
   security delete-generic-password -s DayDream.TypedText
   ```

   Keychain Access and Terminal may not list a key made by a newer DayDream. Until the key is gone, a copy of your history (for example in a Time Machine backup) together with the key can still show the words you typed.

4. **AI apps.** If you connected an AI app to DayDream, remove DayDream from that app's settings. Otherwise it keeps trying to start a tool that is gone. When DayDream connected or disconnected an app, it saved a copy of that app's settings file next to it, with `.daydream-backup` added to the name. The copy can hold keys for the app's other tools. Delete any you find:

   ```sh
   rm -f "$HOME/Library/Application Support/Claude/claude_desktop_config.json.daydream-backup"
   rm -f "$HOME/.claude.json.daydream-backup" "$HOME/.cursor/mcp.json.daydream-backup"
   rm -f "$HOME/.codeium/windsurf/mcp_config.json.daydream-backup"
   ```

5. **Login items.** DayDream opens at login. The uninstaller removes that; if System Settings > General > Login Items still lists DayDream, remove it there.

6. **Copies of your history elsewhere.** Backups you saved yourself, Time Machine backups and APFS local snapshots may still hold copies of your history. DayDream doesn't touch them. Delete backups in Finder, and Time Machine copies in Time Machine, or wait for them to expire.

## Remove everything by hand

Use this when the Uninstall button is off, or if you prefer Terminal.

1. In DayDream, stop recording, then quit it from the menu bar.
2. Drag DayDream to the Trash. Look in both `/Applications` and `~/Applications`, and remove `Daydream.app` too if you have an older copy.
3. Delete your history, downloaded models and the folder from before the rename:

   ```sh
   rm -rf "$HOME/Library/Application Support/DayDream"
   rm -rf "$HOME/Library/Application Support/Mac Mem"
   rm -rf "$HOME/Library/Application Support/DayDream.before-move-"[0-9]*
   ```

   The last line may say "no matches found". That means there was no such folder.

4. Delete DayDream's settings and caches:

   ```sh
   defaults delete com.getnorthlight.daydream
   defaults delete com.macmem.app
   rm -rf "$HOME/Library/Caches/com.getnorthlight.daydream" "$HOME/Library/Caches/com.macmem.app"
   rm -rf "$HOME/Library/HTTPStorages/com.getnorthlight.daydream" "$HOME/Library/HTTPStorages/com.macmem.app"
   rm -f "$HOME/Library/HTTPStorages/com.getnorthlight.daydream.binarycookies" "$HOME/Library/HTTPStorages/com.macmem.app.binarycookies"
   rm -rf "$HOME/Library/Saved Application State/com.getnorthlight.daydream.savedState" "$HOME/Library/Saved Application State/com.macmem.app.savedState"
   ```

   `defaults delete` may say the domain doesn't exist. That means there was nothing to delete.

5. Follow [What no app can do for you](#what-no-app-can-do-for-you) above: permissions, the cloud summary key, the typing key, AI apps (and their `.daydream-backup` copies) and backups.

## For developers

The rules live in `Sources/MemoryCore/Uninstall.swift`: a fixed list of paths, `lstat` checks so no link is followed, and a second check of every path just before it is removed. `Sources/MacMemApp/UninstallService.swift` adds the parts that need the running app: its busy states, the login item, the settings domains, and a last pass as DayDream quits (the app saves a little on the way out, and that pass deletes it again). `scripts/uninstall-plan-checks.swift` runs the rules over scratch home folders with both names present.
