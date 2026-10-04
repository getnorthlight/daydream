import Foundation
import PrivacyPolicy

/// Safe typing C, terminals: synthetic key sequences through the pure
/// TerminalPromptLatch. No terminal, event tap, AX or real input.
enum TerminalPromptLatchChecks {
    static var passed = 0
    static func pass(_ ok: Bool, _ label: String) { require(ok, "latch: " + label); passed += 1; print("PASS latch: " + label) }

    /// Types `keys` characters then Return with `line`; returns what was recorded.
    static func typeLine(_ latch: inout TerminalPromptLatch, _ line: String, focus: String = "f1") -> [TerminalPromptLatch.Decision] {
        var out = line.map { _ in latch.key(.text, focusID: focus) }
        out.append(latch.key(.submit(line: line), focusID: focus))
        return out
    }

    static func run() {
        var latch = TerminalPromptLatch()
        pass(!latch.armed && String(describing: latch) == "TerminalPromptLatch(idle)", "starts idle")
        pass(typeLine(&latch, "ls -la").allSatisfy { $0 == .record } && !latch.armed, "an ordinary command is recorded and does not arm")
        // sudo: the command itself is recorded (the store scrubber withholds its
        // arguments); the password line after it is dropped, Return included.
        pass(typeLine(&latch, "sudo apt update").allSatisfy { $0 == .record } && latch.arm == .command, "submitting sudo arms the latch")
        pass(String(describing: latch) == "TerminalPromptLatch(command)", "the description names the state only")
        pass(typeLine(&latch, "hunter2").allSatisfy { $0 == .drop } && !latch.armed, "every key of the password line is dropped, then Return disarms")
        pass(typeLine(&latch, "echo done").allSatisfy { $0 == .record }, "keys after the prompt are recorded again")
        // Unknown submitted line never arms.
        pass(latch.key(.submit(line: nil), focusID: "f1") == .record && !latch.armed, "a Return with an unknown line does not arm")
        // Other privileged commands and forms.
        for line in ["ssh admin@10.0.0.5", "su -", "passwd", "docker login -u sam", "gh auth login", "security unlock-keychain", "cd /tmp && sudo make install", "echo x | sudo -S ls", "PGPASSWORD=x psql", "env FOO=1 sudo -E make", "/usr/bin/sudo -i", "mysql -u root -p", "op signin", "kinit sam@EXAMPLE.COM"] {
            var l = TerminalPromptLatch()
            _ = typeLine(&l, line)
            pass(l.arm == .command && l.key(.text, focusID: "f1") == .drop, "arms after a privileged command (\(line.split(separator: " ").first ?? ""))")
        }
        for line in ["ls", "su casa es bonita", "login page redesign ships", "security review", "notes | login redesign", "sudoku", "ssh-keygen -t ed25519", "~/bin/sudo x", "echo sudo"] {
            var l = TerminalPromptLatch()
            _ = typeLine(&l, line)
            pass(!l.armed, "does not arm on an ordinary line (\(line.split(separator: " ").first ?? ""))")
        }
        // No Return: drop until the focus changes.
        latch = TerminalPromptLatch()
        _ = typeLine(&latch, "sudo -v")
        pass((0..<20).allSatisfy { _ in latch.key(.text, focusID: "f1") == .drop }, "without Return, keys stay dropped")
        pass(latch.key(.text, focusID: "f2") == .record && !latch.armed, "a focus change disarms")
        // Interrupt ends the prompt.
        latch = TerminalPromptLatch()
        _ = typeLine(&latch, "sudo -v")
        pass(latch.key(.text, focusID: "f1") == .drop && latch.key(.interrupt, focusID: "f1") == .drop && !latch.armed, "Control-C at the prompt is dropped and disarms")
        pass(latch.key(.text, focusID: "f1") == .record, "keys after an interrupt are recorded")
        latch.focusChanged(to: "f3")
        pass(latch.focusID == "f3" && !latch.armed, "focusChanged records the new focus")

        // Titles.
        latch = TerminalPromptLatch()
        latch.titleObserved("sam — sudo apt update — 80×24", focusID: "t1")
        pass(latch.arm == .title, "a title showing sudo arms")
        pass(typeLine(&latch, "hunter2", focus: "t1").allSatisfy { $0 == .drop } && latch.arm == .title, "while the title shows it, Return does not disarm")
        latch.titleObserved("sam — -zsh — 80×24", focusID: "t1")
        pass(!latch.armed && latch.key(.text, focusID: "t1") == .record, "a title without the process disarms")
        latch.titleObserved("ssh me@host", focusID: "t1")
        pass(typeLine(&latch, "cat /etc/hosts", focus: "t1").allSatisfy { $0 == .drop }, "an ssh session is not recorded at all")
        pass(latch.key(.text, focusID: "t2") == .record && !latch.armed, "the title arm ends with the focus")
        latch.titleObserved("user@box: ~ (ssh)", focusID: "t2")
        pass(latch.arm == .title, "an (ssh) title part arms")
        for title in ["~/src/security — zsh", "Notes — login ideas", "sam — -zsh — 80×24", "Terminal", "sudoku — zsh", "", "sam — login — 80×24"] {
            pass(TerminalPromptLatch.titleProcess(title) == nil, "title without a prompt process: \(title.isEmpty ? "empty" : String(title.prefix(10)))")
        }
        for (title, name) in [("sam — sudo apt update — 80×24", "sudo"), ("ssh me@host", "ssh"), ("gpg --decrypt", "gpg"), ("/usr/bin/sudo -s", "sudo"), ("iTerm2 - docker login", "docker")] {
            pass(TerminalPromptLatch.titleProcess(title) == name, "title process \(name)")
        }
        // typing-all final review: the line the shell runs, not one unit.
        // Idle and size splits keep the line: "sudo apt" + " update" arms.
        latch = TerminalPromptLatch()
        _ = latch.key(.text, focusID: "f1")
        _ = latch.key(.split(typed: "sudo apt", completion: false), focusID: "f1")
        pass(latch.key(.submit(line: " update"), focusID: "f1") == .record && latch.arm == .command, "a line split by an idle commit still arms on its privileged command")
        // History recall, caret jumps, paste: the line is unknown, so Return arms (fail closed).
        latch = TerminalPromptLatch()
        _ = latch.key(.unseen(typed: ""), focusID: "f1")
        pass(latch.key(.submit(line: nil), focusID: "f1") == .record && latch.arm == .command, "Return on a recalled (unseen) line arms")
        pass(latch.key(.text, focusID: "f1") == .drop, "the line after a recalled command is dropped")
        latch = TerminalPromptLatch()
        _ = latch.key(.unseen(typed: "apt update"), focusID: "f1")
        pass(latch.key(.submit(line: "sudo "), focusID: "f1") == .record && latch.arm == .command, "text typed after a caret jump arms although the whole line isn't known")
        // Tab: harmless after a complete, ordinary command word; otherwise unknown.
        latch = TerminalPromptLatch()
        _ = latch.key(.split(typed: "git st", completion: true), focusID: "f1")
        pass(latch.key(.submit(line: nil), focusID: "f1") == .record && !latch.armed, "Tab completing an argument of git doesn't arm")
        latch = TerminalPromptLatch()
        _ = latch.key(.split(typed: "sud", completion: true), focusID: "f1")
        pass(latch.key(.submit(line: " apt update"), focusID: "f1") == .record && latch.arm == .command, "Tab completing the command word arms (sud<Tab>)")
        for (before, keeps) in [("git st", true), ("ls ", true), ("make te", true), ("git ", true), ("sud", false), ("docker lo", false), ("gh auth lo", false),
                                ("sudo apt ins", false), ("make && sud", false), ("env FOO=1 ", false), ("time su", false), ("", false), ("ls && ", false), ("~/bin/x ", false)] {
            pass(TerminalPromptLatch.completionKeepsCommand(before) == keeps, "Tab after \"\(before.split(separator: " ").first ?? "")…\" \(keeps ? "keeps" : "loses") the command")
        }
        // Remote sessions: sticky until the focus changes.
        latch = TerminalPromptLatch()
        _ = typeLine(&latch, "ssh me@server")
        pass(latch.remote && latch.arm == .command, "an ssh command starts a remote session")
        _ = typeLine(&latch, "yes")
        latch.titleObserved("me@server: ~", focusID: "f1")
        pass(typeLine(&latch, "mysql -u root -p").allSatisfy { $0 == .drop } && typeLine(&latch, "dbpass").allSatisfy { $0 == .drop },
             "a remote title without ssh doesn't end the remote session")
        pass(latch.key(.text, focusID: "f2") == .record && !latch.armed, "the remote session ends with the focus")
        latch = TerminalPromptLatch()
        latch.titleObserved("user — ssh me@server — 80×24", focusID: "f1")
        latch.titleObserved("me@server: ~", focusID: "f1")
        pass(latch.arm == nil && latch.remote && latch.key(.text, focusID: "f1") == .drop, "an ssh title starts a remote session that outlives the title")
        latch = TerminalPromptLatch()
        latch.titleObserved("~/src", focusID: "f1")
        _ = latch.key(.unseen(typed: ""), focusID: "f1")
        _ = latch.key(.submit(line: nil), focusID: "f1")
        latch.titleObserved("me@server: ~", focusID: "f1")
        pass(latch.remote, "an unseen line followed by a new title (a recalled ssh) starts a remote session")
        latch = TerminalPromptLatch()
        latch.titleObserved("~/src", focusID: "f1")
        _ = latch.key(.unseen(typed: ""), focusID: "f1")
        _ = latch.key(.submit(line: nil), focusID: "f1")
        latch.titleObserved("~/src", focusID: "f1")
        _ = latch.key(.text, focusID: "f1"); _ = latch.key(.submit(line: "x"), focusID: "f1")
        latch.titleObserved("vim", focusID: "f1")
        pass(!latch.remote && !latch.armed, "the title is compared once, at the first read after the Return")
        for (line, remote) in [("ssh host", true), ("cd x && ssh host", true), ("sshpass -p x ssh host", true), ("telnet 10.0.0.1", true), ("ssh-keygen -t ed25519", false), ("sudo ls", false), ("echo ssh", false)] {
            pass(TerminalPromptLatch.isRemoteCommandLine(line) == remote, "remote command rule (\(line.split(separator: " ").first ?? ""))")
        }
        pass(String(describing: TerminalPromptLatch.Key.split(typed: "hunter2", completion: true)) == "split(completion, redacted)"
             && String(describing: TerminalPromptLatch.Key.unseen(typed: "hunter2")) == "unseen(redacted)", "split and unseen keys are described as redacted")
        // Owner live test 2026-10-02 (RECORDING-MATRIX-1002 rows 1-2): a line that was only interrupted (another app,
        // then a click) arms only when it could be privileged, and a later title change doesn't drop the tab.
        latch = TerminalPromptLatch()
        latch.titleObserved("~/src", focusID: "f1")
        _ = latch.key(.interrupted(typed: "echo cedar"), focusID: "f1")
        _ = latch.key(.interrupted(typed: ""), focusID: "f1")
        pass(latch.key(.submit(line: " maple"), focusID: "f1") == .record && !latch.armed, "an interrupted ordinary line (switch away, back, click, Return) does not arm")
        latch.titleObserved("echo cedar maple", focusID: "f1")
        latch.titleObserved("~/src/app", focusID: "f1")
        pass(typeLine(&latch, "ls").allSatisfy { $0 == .record } && !latch.armed && !latch.remote, "a title change after it doesn't drop the tab")
        for (pieces, label) in [(["apt update", "sudo "], "sudo typed after a click"), (["nit", "ki"], "a command word typed in two pieces, out of order"),
                                (["sudo", " -v"], "sudo split by a switch"), (["cd /tmp && ", "ssh host"], "ssh after a switch"), (["docker", " login"], "a privileged phrase split by a switch")] {
            latch = TerminalPromptLatch()
            for p in pieces.dropLast() { _ = latch.key(.interrupted(typed: p), focusID: "f1") }
            pass(latch.key(.submit(line: pieces.last!), focusID: "f1") == .record && latch.arm == .command, "an interrupted line that could be privileged arms: \(label)")
            pass(typeLine(&latch, "hunter2").allSatisfy { $0 == .drop }, "its password line is dropped: \(label)")
        }
        for (pieces, risky) in [(["echo cedar", " maple"], false), (["git st", "atus"], false), (["", "ls"], false), (["make", " test"], false),
                                (["apt update", "sudo "], true), (["do apt", "su"], true), (["nit", "ki"], true), (["ls; ", "passwd"], true), (["/usr/bin/sudo", " x"], true)] {
            pass(TerminalPromptLatch.piecesCouldBePrivileged(pieces) == risky, "pieces rule: \(risky ? "could be" : "can't be") privileged (\(pieces.count) pieces)")
        }
        // After a Return on a line changed unseen: a title change is a remote session only with a sensitive process or
        // a new user@host; the command arm drops one line and its Return disarms; the next fully seen line is kept.
        latch = TerminalPromptLatch()
        latch.titleObserved("~/src", focusID: "f1")
        _ = latch.key(.unseen(typed: ""), focusID: "f1")
        _ = latch.key(.submit(line: nil), focusID: "f1")
        latch.titleObserved("make test", focusID: "f1")
        pass(!latch.remote && latch.arm == .command, "after an unseen Return, a plain title change is not a remote session")
        pass(typeLine(&latch, "hunter2").allSatisfy { $0 == .drop } && !latch.armed, "the next line is still dropped, and its Return disarms")
        pass(typeLine(&latch, "echo back").allSatisfy { $0 == .record } && !latch.armed, "the next fully seen line is recorded")
        latch = TerminalPromptLatch()
        latch.titleObserved("sam@mac: ~", focusID: "f1")
        _ = latch.key(.unseen(typed: ""), focusID: "f1")
        _ = latch.key(.submit(line: nil), focusID: "f1")
        latch.titleObserved("sam@mac: ~/src", focusID: "f1")
        pass(!latch.remote, "the same user@host in a new title (cd) is not a remote session")
        latch = TerminalPromptLatch()
        latch.titleObserved("sam@mac: ~", focusID: "f1")
        _ = latch.key(.unseen(typed: ""), focusID: "f1")
        _ = latch.key(.submit(line: nil), focusID: "f1")
        latch.titleObserved("root@db1: ~", focusID: "f1")
        pass(latch.remote, "a new user@host after an unseen Return is a remote session")
        latch = TerminalPromptLatch()
        latch.titleObserved("sam — zsh — 80×24", focusID: "f1")
        _ = latch.key(.interrupted(typed: "make"), focusID: "f1")
        _ = latch.key(.submit(line: " deploy"), focusID: "f1")
        latch.titleObserved("sam — sudo make deploy — 80×24", focusID: "f1")
        pass(latch.arm == .title && latch.key(.text, focusID: "f1") == .drop, "a title showing sudo still drops keys after an interrupted line")
        latch.titleObserved("sam — zsh — 80×24", focusID: "f1")
        pass(!latch.armed && latch.key(.text, focusID: "f1") == .record, "and the plain title records again")
        pass(String(describing: TerminalPromptLatch.Key.interrupted(typed: "hunter2")) == "interrupted(redacted)", "an interrupted key is described as redacted")
        // Descriptions never carry text.
        pass(String(describing: TerminalPromptLatch.Key.submit(line: "hunter2")) == "submit(redacted)", "a submitted line is described as redacted")
        var dumped = ""; dump(latch, to: &dumped)
        pass(!dumped.contains("ssh") && !dumped.contains("me@host"), "dump shows no title or text")
        print("PASS terminal prompt latch checks: \(passed) synthetic sequences (no terminal, no input values logged).")
    }
}
