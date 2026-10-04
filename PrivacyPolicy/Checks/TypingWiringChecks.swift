import Foundation
import PrivacyPolicy

/// typing-all W0: the terminal prompt latch wired into TypingSession, the
/// window title (`FocusProof.place`) carried to the commit, and Esc in a
/// search panel. Synthetic: fake clock and fake focus (TypingHarness). The
/// capture gate admits only Notes and TextEdit today, so TextEdit stands in
/// for a terminal through `promptLatchApps`.
enum TypingWiringChecks {
    static var passed = 0
    static func pass(_ ok: Bool, _ label: String) { require(ok, "wiring: " + label); passed += 1; print("PASS wiring: " + label) }
    static let terminal = TypingHarness.Field(bundle: "com.apple.TextEdit", window: "term", id: "tty1", role: "AXTextArea", place: "sam — zsh — 80×24")
    static func terminalHarness() -> TypingHarness {
        let h = TypingHarness(promptLatchApps: { $0 == "com.apple.TextEdit" }); h.focus = terminal; return h
    }
    static func line(_ h: TypingHarness, _ text: String) { h.type(text); h.press(TypingChecks.ret) }

    /// What `TerminalPromptLatch.wired` claims, observed: after a privileged
    /// command, the password line is never read and never saved.
    static func sessionDropsPromptKeys() -> Bool {
        let h = terminalHarness()
        line(h, "sudo apt update")
        let reads = h.reads
        line(h, "hunter2")
        line(h, "echo done")
        h.advance(TypingChecks.long)
        return h.reads == reads + "echo done".count && h.texts == ["sudo apt update", "echo done"]
    }

    static func run() {
        // The latch, wired.
        pass(sessionDropsPromptKeys(), "after sudo, the password line is dropped before any read; the next line is kept")
        pass(TerminalPromptLatch.wired == sessionDropsPromptKeys(), "TerminalPromptLatch.wired is true only while the session drops the keys at a prompt")
        pass(TypingSession.tablePromptLatch("com.apple.Terminal") && TypingSession.tablePromptLatch("com.mitchellh.ghostty")
             && TypingSession.tablePromptLatch("com.microsoft.VSCode") && !TypingSession.tablePromptLatch("com.apple.Notes"),
             "by default the latch covers the table's terminals and editors with a terminal, not Notes")
        let armed = terminalHarness()
        line(armed, "ssh admin@example.test")
        armed.type("pw")
        pass(armed.s.promptArmed(armed.proof()!), "armed while the prompt waits for its Return")
        armed.press(TypingChecks.ret)
        pass(!armed.s.promptArmed(armed.proof()!), "Return at the prompt disarms")
        // Title arm: keys are dropped while the title shows a privileged process.
        let title = terminalHarness()
        title.focus.place = "sam — sudo apt update — 80×24"
        title.type("s3cretpass"); title.press(TypingChecks.ret)
        let dropped = title.reads
        title.focus.place = "sam — zsh — 80×24"
        line(title, "ls")
        title.advance(TypingChecks.long)
        pass(dropped == 0 && title.texts == ["ls"], "a title showing sudo drops every key; a plain title records again")
        // A focus change (another tab or field) ends the prompt.
        let moved = terminalHarness()
        line(moved, "sudo -v")
        moved.click(to: TypingHarness.Field(bundle: "com.apple.TextEdit", window: "term", id: "tty2", role: "AXTextArea", place: "sam — zsh — 80×24"))
        moved.advance(1)
        line(moved, "make test")
        moved.advance(TypingChecks.long)
        pass(moved.texts == ["sudo -v", "make test"], "moving to another field ends the prompt arm")
        // The line is the last line of the unit.
        let multi = terminalHarness()
        multi.type("cd /tmp"); multi.key(KeyStroke(keyCode: 36, shift: true)); multi.type("sudo make install"); multi.press(TypingChecks.ret)
        pass(multi.s.promptArmed(multi.proof()!), "the submitted line is the unit's last line")
        // typing-all final review: the latch sees the line the shell runs.
        // Each case: a privileged command whose line the unit alone doesn't
        // show, then a password line that must never be read or saved.
        func password(_ h: TypingHarness) -> Bool {
            let before = h.reads
            line(h, "hunter2")
            let dropped = h.reads == before
            line(h, "echo done"); line(h, "echo again")
            h.advance(TypingChecks.long)
            return dropped && !h.texts.contains { $0.contains("hunter2") } && h.texts.contains("echo again")
        }
        let tmux = terminalHarness(); tmux.focus.place = "user — tmux — 80×24"
        tmux.type("sudo systemctl rest"); tmux.press(TypingChecks.tab); tmux.type("art nginx"); tmux.press(TypingChecks.ret)
        pass(password(tmux), "Tab-completed sudo line (tmux title): the password line is dropped")
        let recalled = terminalHarness()
        recalled.press(TypingChecks.up); recalled.press(TypingChecks.ret)
        pass(password(recalled), "history-recalled line (Up, Return): the next line is dropped")
        let reverse = TypingHarness(promptLatchApps: { $0 == "com.apple.TextEdit" }); reverse.focus = terminal
        reverse.press(15, ctrl: true); reverse.type("sud"); reverse.press(TypingChecks.ret)
        pass(password(reverse), "Ctrl-R history search: the next line is dropped")
        let idled = terminalHarness()
        idled.type("sudo apt update"); idled.advance(TypingChecks.long); idled.press(TypingChecks.ret)
        pass(password(idled), "a sudo line committed by the idle timer before Return: the next line is dropped")
        let unread = terminalHarness()
        unread.type("sudo apt update"); unread.proofReadable = false; unread.press(TypingChecks.ret); unread.proofReadable = true
        pass(password(unread), "Return whose proof can't be read: the next line is dropped")
        let prefixed = terminalHarness()
        prefixed.type("apt update"); prefixed.press(0, ctrl: true); prefixed.type("sudo "); prefixed.press(TypingChecks.ret)
        pass(password(prefixed), "Ctrl-A then sudo typed in front: the next line is dropped")
        let pasted = terminalHarness()
        pasted.press(9, cmd: true); pasted.press(TypingChecks.ret)
        pass(password(pasted), "a pasted command: the next line is dropped")
        let completedWord = terminalHarness()
        completedWord.type("sud"); completedWord.press(TypingChecks.tab); completedWord.type(" apt update"); completedWord.press(TypingChecks.ret)
        pass(password(completedWord), "Tab completing the command word (sud<Tab>): the next line is dropped")
        let harmless = terminalHarness()
        harmless.type("git st"); harmless.press(TypingChecks.tab); harmless.press(TypingChecks.ret)
        line(harmless, "ls -la"); harmless.advance(TypingChecks.long)
        pass(harmless.texts.contains("ls -la"), "control: Tab completing an argument of git keeps the next line")
        // Remote sessions: a remote title without ssh doesn't end them.
        let remote = terminalHarness()
        line(remote, "ssh me@server")
        remote.focus.place = "me@server: ~"
        let remoteReads = remote.reads
        line(remote, "mysql -u root -p"); line(remote, "dbpassword"); line(remote, "export DB_PASS=abc")
        remote.advance(TypingChecks.long)
        pass(remote.reads == remoteReads && remote.texts == ["ssh me@server"] && remote.s.remoteSession(remote.proof()!),
             "after ssh, a remote shell's own title doesn't resume recording")
        remote.click(to: TypingHarness.Field(bundle: "com.apple.TextEdit", window: "term", id: "tty2", role: "AXTextArea", place: "sam — zsh — 80×24"))
        remote.advance(1)
        line(remote, "echo local"); remote.advance(TypingChecks.long)
        pass(remote.texts == ["ssh me@server", "echo local"], "another tab records again")
        let titled = terminalHarness()
        titled.focus.place = "ssh me@server"
        titled.type("x"); titled.focus.place = "me@server: ~"
        line(titled, "export DB_PASS=abc"); titled.advance(TypingChecks.long)
        pass(titled.texts.isEmpty, "an ssh title starts a remote session that outlives the title")
        let recalledSSH = terminalHarness(); recalledSSH.focus.place = "~/src"
        recalledSSH.press(TypingChecks.up); recalledSSH.press(TypingChecks.ret)
        recalledSSH.focus.place = "me@server: ~"
        line(recalledSSH, "yes"); line(recalledSSH, "mysql -u root -p"); line(recalledSSH, "dbpassword")
        recalledSSH.advance(TypingChecks.long)
        pass(recalledSSH.texts.isEmpty && recalledSSH.s.remoteSession(recalledSSH.proof()!),
             "a recalled line after which the title changed (a recalled ssh) ends recording in that tab")
        let recalledLs = terminalHarness(); recalledLs.focus.place = "~/src"
        recalledLs.press(TypingChecks.up); recalledLs.press(TypingChecks.ret)
        line(recalledLs, "skipped"); line(recalledLs, "make test"); recalledLs.advance(TypingChecks.long)
        pass(recalledLs.texts == ["make test"], "control: a recalled line with the title unchanged drops only the next line")
        // Owner live test 2026-10-02 (RECORDING-MATRIX-1002 rows 1-2): P1, Cmd-Tab away, back, a click, P2, Return,
        // then the window title changes. The tab keeps recording; a line that could be privileged still arms.
        let away = TypingHarness.Field(bundle: "com.apple.Notes", window: "n", id: "n1", role: "AXTextArea")
        let interrupted = terminalHarness()
        interrupted.type("echo cedar"); interrupted.switchApp(to: away); interrupted.advance(3)
        interrupted.switchApp(to: terminal); interrupted.click(); interrupted.type(" maple"); interrupted.press(TypingChecks.ret)
        interrupted.focus.place = "echo cedar maple"; interrupted.advance(1)
        interrupted.focus.place = "sam — zsh — 80×24"
        line(interrupted, "ls -la"); line(interrupted, "make test"); interrupted.advance(TypingChecks.long)
        pass(interrupted.texts.contains("ls -la") && interrupted.texts.contains("make test") && !interrupted.s.remoteSession(interrupted.proof()!)
             && !interrupted.s.promptArmed(interrupted.proof()!), "switch away mid-line, click back, Return, title change: the next lines are kept")
        let cmdTab = terminalHarness()
        cmdTab.type("echo one"); cmdTab.switchApp(to: away); cmdTab.switchApp(to: terminal); cmdTab.type(" two"); cmdTab.press(TypingChecks.ret)
        line(cmdTab, "echo three"); cmdTab.advance(TypingChecks.long)
        pass(cmdTab.texts.contains("echo three"), "Cmd-Tab away and back mid-line: the next line is kept")
        let interruptedSudo = terminalHarness()
        interruptedSudo.type("apt update"); interruptedSudo.switchApp(to: away); interruptedSudo.switchApp(to: terminal); interruptedSudo.click()
        interruptedSudo.type("sudo "); interruptedSudo.press(TypingChecks.ret)
        pass(password(interruptedSudo), "an interrupted line with sudo typed after a click: the password line is dropped")
        let switchedSudo = terminalHarness()
        switchedSudo.type("sudo apt"); switchedSudo.switchApp(to: away); switchedSudo.switchApp(to: terminal); switchedSudo.type(" update"); switchedSudo.press(TypingChecks.ret)
        pass(password(switchedSudo), "sudo split by Cmd-Tab: the password line is dropped")
        let menuPaste = terminalHarness()
        line(menuPaste, "echo first"); menuPaste.click(); menuPaste.s.pointerMayEdit(); menuPaste.press(TypingChecks.ret)
        pass(password(menuPaste), "a right-click (a context-menu Paste) then Return: the next line is dropped")
        let unseenTitle = terminalHarness(); unseenTitle.focus.place = "~/src"
        unseenTitle.press(TypingChecks.up); unseenTitle.press(TypingChecks.ret)
        unseenTitle.focus.place = "make watch"
        line(unseenTitle, "skipped"); line(unseenTitle, "echo kept"); unseenTitle.advance(TypingChecks.long)
        pass(unseenTitle.texts == ["echo kept"] && !unseenTitle.s.remoteSession(unseenTitle.proof()!),
             "a recalled line, then a title without a sensitive process: one line dropped, then recording resumes in the tab")
        // A line erased with Ctrl-U, or abandoned with Ctrl-C, is never saved.
        let erased = terminalHarness()
        line(erased, "echo kept"); erased.type("rm -rf build"); erased.press(32, ctrl: true); erased.advance(TypingChecks.long)
        pass(erased.texts == ["echo kept"], "a line erased with Ctrl-U is never saved")
        let cancelled = terminalHarness()
        line(cancelled, "echo kept"); cancelled.type("rm -rf build"); cancelled.press(8, ctrl: true); cancelled.advance(TypingChecks.long)
        pass(cancelled.texts == ["echo kept"], "a line abandoned with Ctrl-C is never saved")
        let paused = terminalHarness()
        paused.type("rm -rf bu"); paused.advance(TypingChecks.long); paused.type("ild"); paused.press(32, ctrl: true); paused.advance(TypingChecks.long)
        pass(paused.rows.allSatisfy { $0.reason != .submit } && !paused.texts.contains("ild"), "Ctrl-U drops the live part of the line (a part already saved by a pause stays a draft)")
        let killAtPrompt = terminalHarness()
        line(killAtPrompt, "sudo -v"); killAtPrompt.type("wrongpass"); killAtPrompt.press(32, ctrl: true)
        pass(killAtPrompt.s.promptArmed(killAtPrompt.proof()!), "Ctrl-U at a password prompt keeps the arm")
        killAtPrompt.type("hunter2"); killAtPrompt.press(TypingChecks.ret); line(killAtPrompt, "echo after"); killAtPrompt.advance(TypingChecks.long)
        pass(killAtPrompt.texts == ["sudo -v", "echo after"], "the retyped password is dropped too; the line after the prompt is kept")
        let interruptPrompt = terminalHarness()
        line(interruptPrompt, "sudo -v"); interruptPrompt.type("hunt"); interruptPrompt.press(8, ctrl: true)
        pass(!interruptPrompt.s.promptArmed(interruptPrompt.proof()!), "Ctrl-C at a password prompt ends the arm (sudo was interrupted)")
        line(interruptPrompt, "echo after"); interruptPrompt.advance(TypingChecks.long)
        pass(interruptPrompt.texts == ["sudo -v", "echo after"], "nothing typed at the interrupted prompt is saved")
        let erasedNotes = TypingHarness(promptLatchApps: { $0 == "com.apple.TextEdit" })
        erasedNotes.type("a note line"); erasedNotes.press(32, ctrl: true); erasedNotes.advance(TypingChecks.long)
        pass(erasedNotes.texts == ["a note line"], "control: Ctrl-U outside a terminal parks and saves as before")
        // Apps outside the latch are unchanged.
        let notes = TypingHarness(promptLatchApps: { $0 == "com.apple.TextEdit" })
        line(notes, "sudo is a word in a note"); line(notes, "and this line too")
        notes.advance(TypingChecks.long)
        pass(notes.texts == ["sudo is a word in a note", "and this line too"], "apps without the latch record every line")
        // The place label reaches the commit.
        let placed = TypingHarness(); placed.focus.place = "Pricing plan"
        placed.type("ship on Friday."); placed.advance(TypingChecks.idle)
        pass(placed.rows.map(\.proof.place) == ["Pricing plan"], "the commit carries the window title from the proof")

        // Esc in a search panel discards; elsewhere it parks and commits.
        let search = TypingHarness(); search.focus.subrole = "AXSearchField"; search.focus.role = "AXTextField"
        search.type("divorce lawyer"); search.press(TypingChecks.esc); search.advance(TypingChecks.long)
        pass(search.rows.isEmpty, "Esc in a search field: the search is discarded, never saved")
        let field = TypingHarness()
        field.type("a normal draft"); field.press(TypingChecks.esc); field.advance(TypingChecks.long)
        pass(field.texts == ["a normal draft"] && field.rows.first?.reason == .focusKey, "control: Esc in an ordinary field parks and commits as before")
        let searchSubmit = TypingHarness(); searchSubmit.focus.subrole = "AXSearchField"; searchSubmit.focus.role = "AXTextField"
        searchSubmit.type("weekly report"); searchSubmit.press(TypingChecks.ret); searchSubmit.advance(TypingChecks.long)
        pass(searchSubmit.texts == ["weekly report"], "control: Return in a search field saves the search")
        var spotlight = FocusProof(); spotlight.bundle = "com.apple.Spotlight"
        var raycast = FocusProof(); raycast.bundle = "com.raycast.macos"
        pass(TypingSession.isSearchPanel(spotlight) && TypingSession.isSearchPanel(raycast) && !TypingSession.isSearchPanel(TypingHarness().proof()!),
             "Spotlight and Raycast are search panels; a Notes text area is not")
        print("PASS typing wiring checks: \(passed) synthetic cases.")
    }
}
