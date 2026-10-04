import AppKit
import ApplicationServices
import ChromeProbeCore

// chrome-device-test: see README.md. Read-only; run only against a throwaway
// Chrome profile. The Automation prompt appears only with --request-permission.

let opts: Options
do {
    opts = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    print("error: \(error)\n")
    print(Options.usage)
    exit(64)
}

switch opts.command {
case .help:
    print(Options.usage)
    exit(0)
case .steps:
    for (i, s) in Steps.all.enumerated() {
        let n = String(i + 1), id = s.id
        print(String(repeating: " ", count: max(0, 2 - n.count)) + n + "  " + id + String(repeating: " ", count: max(1, 22 - id.count))
              + s.title + (s.needsLabels ? "  (needs --probe-labels)" : ""))
        if opts.verbose {
            s.setup.forEach { print("      before: " + $0) }
            s.action.forEach { print("      then:   " + $0) }
        }
    }
    exit(0)
case .access:
    // Read-only: whether macOS lets the app running this command (Terminal)
    // use Accessibility. No Chrome, no Apple Event, no prompt (the kit's
    // run.sh checks this before Chrome is open).
    let trusted = AXIsProcessTrusted()
    print("Accessibility:   \(trusted ? "on" : "OFF") for the app running this command (Terminal)")
    exit(trusted ? 0 : 1)
default:
    break
}

// Connect to the window server so NSWorkspace's frontmost-app notifications
// arrive. No Dock icon, no windows, no activation.
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

print(Harness.version)
let pre = Preflight.run(opts)
guard pre.profileOK else {
    print("\nStopped: nothing was read from Chrome and no permission was requested.")
    exit(2)
}
if opts.command == .preflight {
    print(pre.ready ? "\nPreflight OK." : "\nPreflight not complete: see the lines above.")
    exit(pre.ready ? 0 : 1)
}
guard pre.automation == "granted" else {
    print("\nStopped: Automation is \(pre.automation). Run `chrome-device-test preflight --request-permission` first.")
    exit(1)
}
let session = Session(opts, pre)

switch opts.command {
case .windows:
    session.windows()
    exit(0)
default:
    break
}
guard pre.axTrusted else {
    print("\nStopped: Accessibility is off for Terminal (System Settings > Privacy & Security > Accessibility; README step 5).")
    exit(1)
}
switch opts.command {
case .join:
    session.joins(count: opts.repeatCount)
    exit(session.audit.violations.isEmpty ? 0 : 2)
case .focus:
    session.focus(seconds: opts.seconds)
    exit(0)
case .run:
    exit(session.guided())
default:
    print(Options.usage)
    exit(64)
}
