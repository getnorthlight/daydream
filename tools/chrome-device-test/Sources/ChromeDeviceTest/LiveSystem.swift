import AppKit
import ApplicationServices
import Carbon
import Security
import ChromeProbeCore

enum System {
    static let chromeBundle = "com.google.Chrome"

    /// NSWorkspace updates the frontmost app from run-loop notifications, so a
    /// command-line tool has to let the run loop turn before reading it.
    static func pump(_ seconds: TimeInterval = 0) {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: seconds))
    }
    static func sleep(_ seconds: TimeInterval) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end { pump(min(0.02, max(0, end.timeIntervalSinceNow))) }
    }
    static func frontmostPID() -> pid_t? {
        pump()
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    static func bundle(of pid: pid_t) -> String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func chromeApps() -> [NSRunningApplication] {
        pump()
        return NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundle).filter { !$0.isTerminated }
    }

    /// Launch arguments of a process owned by this user (KERN_PROCARGS2).
    /// Only argv is decoded; the environment block is skipped.
    static func arguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return ProfileGate.parseProcArgs2(Array(buffer[0..<size]))
    }

    /// Google's signature on the running Chrome (plan: pattern at AccessibilitySnapshot.swift:71-80).
    static func chromeSignatureOK(pid: pid_t) -> Bool {
        var code: SecCode?, requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, SecCSFlags(rawValue: 0), &code) == errSecSuccess,
              let code, SecRequirementCreateWithString(Harness.chromeRequirement as CFString, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), requirement) == errSecSuccess
    }

    static func version(of app: NSRunningApplication) -> String? {
        guard let url = app.bundleURL else { return nil }
        return Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Bundles in `watch` that own an on-screen window of panel size. Reads
    /// only the owner PID, bounds and alpha: never a window title, and it
    /// needs no Screen Recording permission.
    static func panels(_ watch: Set<String>) -> [String] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out = Set<String>()
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.width >= 300, r.height >= 40,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bundle = bundle(of: pid), watch.contains(bundle) else { continue }
            out.insert(bundle)
        }
        return out.sorted()
    }

    static func focusSample(chromePID: pid_t, ax: LiveAX, watch: Set<String>, since start: UInt64) -> FocusSample {
        let front = frontmostPID()
        let t0 = now()
        let focused = ax.focusedApplicationPID()
        let readMs = milliseconds(now() &- t0)
        return FocusSample(ms: milliseconds(now() &- start), frontIsChrome: front == chromePID, focusedIsChrome: focused == chromePID,
                           focusedBundle: focused.flatMap(bundle(of:)), panels: panels(watch), secureInput: IsSecureEventInputEnabled(),
                           frontBundle: front.flatMap(bundle(of:)), focusReadMs: readMs)
    }

    /// Waits until one of `bundles` is the frontmost app (native-editors step).
    @discardableResult
    static func waitForFront(bundles: Set<String>, settle: TimeInterval, timeout: TimeInterval = 45) -> Bool {
        let end = Date(timeIntervalSinceNow: timeout)
        var announced = false
        while Date() < end {
            if let pid = frontmostPID(), let b = bundle(of: pid), bundles.contains(b) { sleep(settle); return true }
            if !announced { print("    waiting for \(bundles.sorted().joined(separator: " or ")) to come to the front..."); announced = true }
            sleep(0.1)
        }
        print("    none came to the front within \(Int(timeout)) s.")
        return false
    }

    /// "Tink" = go (start doing the action now); "Glass" = step done, come back to Terminal.
    static func go() { play("Tink") }
    static func done() { play("Glass") }
    private static func play(_ name: String) {
        if let s = NSSound(named: NSSound.Name(name)) { s.play() } else { NSSound.beep() }
        pump(0.05)
    }

    /// Waits until Chrome is the frontmost app, then lets the owner settle.
    @discardableResult
    static func waitForChromeFront(pid: pid_t, ax: LiveAX, settle: TimeInterval, timeout: TimeInterval = 45) -> Bool {
        let end = Date(timeIntervalSinceNow: timeout)
        var announced = false
        while Date() < end {
            let front = frontmostPID(), focused = ax.focusedApplicationPID()
            if front == pid || focused == pid {
                if front != pid { print("    note: macOS reports another app as frontmost while Chrome has keyboard focus") }
                sleep(settle)
                return true
            }
            if !announced { print("    waiting for Chrome to come to the front..."); announced = true }
            sleep(0.1)
        }
        print("    Chrome did not come to the front within \(Int(timeout)) s.")
        return false
    }

    static func readLine(prompt: String) -> String {
        print(prompt, terminator: "")
        fflush(stdout)
        return Swift.readLine() ?? ""
    }
}
