import Foundation

/// Refuses to touch a Chrome that is not running on a throwaway profile.
public enum ProfileGate {
    public enum Verdict: Equatable {
        case throwaway(String)
        case notRunning
        case multipleChrome(Int)
        case defaultProfile
        case missingUserDataDir
        case argumentsUnreadable
        public var ok: Bool { if case .throwaway = self { return true }; return false }
        public var message: String {
            switch self {
            case .throwaway(let p): return "Chrome is using a throwaway profile folder: \(p)"
            case .notRunning: return "Chrome is not running. Launch the throwaway Chrome first (README step 4). The harness never launches Chrome."
            case .multipleChrome(let n): return "\(n) Chrome instances are running. Quit your real Chrome (Cmd+Q) so only the throwaway one is left."
            case .defaultProfile: return "Chrome is using your real profile folder. Quit it (Cmd+Q) and relaunch with --user-data-dir (README step 4)."
            case .missingUserDataDir: return "Chrome was not launched with --user-data-dir, so it is your real profile. Quit it (Cmd+Q) and relaunch per README step 4."
            case .argumentsUnreadable: return "Could not read Chrome's launch arguments to confirm the throwaway profile. Re-run with --skip-profile-check only if you are sure."
            }
        }
    }

    /// Parses the KERN_PROCARGS2 buffer: argc, exec path, padding, argv.
    /// Stops after argv: the environment block is never decoded.
    public static func parseProcArgs2(_ b: [UInt8]) -> [String]? {
        guard b.count >= 4 else { return nil }
        let argc = Int(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
        guard argc > 0, argc < 4096 else { return nil }
        var i = 4
        while i < b.count && b[i] != 0 { i += 1 }
        while i < b.count && b[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc && i < b.count {
            let start = i
            while i < b.count && b[i] != 0 { i += 1 }
            args.append(String(decoding: b[start..<i], as: UTF8.self))
            i += 1
        }
        return args.count == argc ? args : nil
    }

    public static func userDataDir(_ args: [String]) -> String? {
        for (i, a) in args.enumerated() {
            if a.hasPrefix("--user-data-dir=") { return String(a.dropFirst("--user-data-dir=".count)) }
            if a == "--user-data-dir", i + 1 < args.count { return args[i + 1] }
        }
        return nil
    }

    public static func evaluate(chromeCount: Int, args: [String]?, home: String) -> Verdict {
        guard chromeCount > 0 else { return .notRunning }
        guard chromeCount == 1 else { return .multipleChrome(chromeCount) }
        guard let args else { return .argumentsUnreadable }
        guard let dir = userDataDir(args), !dir.isEmpty else { return .missingUserDataDir }
        let norm = { (s: String) in (s as NSString).expandingTildeInPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() }
        let realDefaults = ["Library/Application Support/Google/Chrome", "Library/Application Support/Google/Chrome Beta",
                            "Library/Application Support/Google/Chrome Canary", "Library/Application Support/Google/Chrome Dev"]
        if realDefaults.contains(where: { norm(home + "/" + $0) == norm(dir) }) { return .defaultProfile }
        return .throwaway(dir)
    }
}

/// Command-line options. Parsed here (pure) so the selftest can prove that the
/// Automation prompt is never requested unless --request-permission is given.
public struct Options: Equatable {
    public enum Command: String, CaseIterable { case preflight, windows, join, focus, run, steps, access, help }
    public var command: Command = .help
    /// The ONLY way the harness asks macOS for the Automation permission.
    public var requestPermission = false
    public var probeLabels = false
    public var verbose = false
    public var skipProfileCheck = false
    public var repeatCount = 5
    public var seconds = 12.0
    public var settleSeconds = 3.0
    public var aeTimeoutMs = 1000.0
    public var axTimeoutMs = 250.0
    public var reportPath: String?
    public var only: [String] = []
    /// Launcher and password-manager panels that can take the keys while
    /// Chrome stays frontmost (review I7). Bundle IDs other than Spotlight's
    /// are UNCONFIRMED on this Mac; --panel-bundles replaces the list.
    public var panelBundles: [String] = ["com.apple.Spotlight", "com.raycast.macos", "com.runningwithcrayons.Alfred", "com.1password.1password"]
    public var waitForChrome = true

    public init() {}

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknown(String), missingValue(String), badValue(String)
        public var description: String {
            switch self {
            case .unknown(let s): return "unknown argument \(s)"
            case .missingValue(let s): return "\(s) needs a value"
            case .badValue(let s): return "bad value for \(s)"
            }
        }
    }

    public static func parse(_ argv: [String]) throws -> Options {
        var o = Options()
        var rest = argv[...]
        if let first = rest.first, !first.hasPrefix("-") {
            guard let c = Command(rawValue: first) else { throw ParseError.unknown(first) }
            o.command = c
            rest = rest.dropFirst()
        }
        func value(_ flag: String) throws -> String {
            guard let v = rest.first else { throw ParseError.missingValue(flag) }
            rest = rest.dropFirst()
            return v
        }
        func number(_ flag: String) throws -> Double {
            guard let d = Double(try value(flag)), d >= 0, d < 100_000 else { throw ParseError.badValue(flag) }
            return d
        }
        while let a = rest.first {
            rest = rest.dropFirst()
            switch a {
            case "--request-permission": o.requestPermission = true
            case "--probe-labels": o.probeLabels = true
            case "--verbose", "-v": o.verbose = true
            case "--skip-profile-check": o.skipProfileCheck = true
            case "--no-wait": o.waitForChrome = false
            case "--repeat": o.repeatCount = max(1, Int(try number(a)))
            case "--seconds": o.seconds = try number(a)
            case "--settle": o.settleSeconds = try number(a)
            case "--ae-timeout-ms": o.aeTimeoutMs = max(1, try number(a))
            case "--ax-timeout-ms": o.axTimeoutMs = max(1, try number(a))
            case "--report": o.reportPath = try value(a)
            case "--only": o.only = try value(a).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            case "--panel-bundles": o.panelBundles = try value(a).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            case "--help", "-h": o.command = .help
            default: throw ParseError.unknown(a)
            }
        }
        return o
    }

    public static let usage = """
    chrome-device-test: read-only Chrome device test (DayDream plan, Work row 0)

    Run it ONLY against a throwaway Chrome profile (see README.md). It never
    launches Chrome, never runs scripts in it, never changes it, and never reads
    what you type, field values or selected text.

    USAGE
      chrome-device-test preflight [--request-permission]
          Checks Chrome (one instance, throwaway profile, signature, version) and
          permissions. With --request-permission, and only then, asks macOS for
          the Automation permission ("control Google Chrome").
      chrome-device-test windows
          Lists every Chrome window: id, mode, bounds, and names only when every
          window is normal.
      chrome-device-test join [--repeat N] [--probe-labels]
          Waits for Chrome to come to the front, then runs the full join N times.
      chrome-device-test focus [--seconds S] [--panel-bundles a,b]
          Samples who has keyboard focus (the Spotlight check).
      chrome-device-test run [--probe-labels] [--report FILE] [--only a,b]
          The guided test (about 25 minutes). Ends with the PASS/FAIL table.
      chrome-device-test steps [--verbose]
          Lists the guided steps (with --verbose, what to do in each).
      chrome-device-test access
          Says whether the app running this command (Terminal) has
          Accessibility. Needs no Chrome, reads nothing from it, and never
          shows a prompt. Exit 0 = on, 1 = off.

    OPTIONS
      --request-permission   ask macOS for Automation permission (never implied)
      --probe-labels         read the focused field's label/id/placeholder to
                             test the card/OTP deny rules; prints only which
                             deny rule matched, never the text
      --report FILE          also write a JSON report (origins only, no titles)
      --verbose              print every read with its time
      --settle S             seconds to wait after Chrome comes to the front (3)
      --ae-timeout-ms N      Apple Event timeout while measuring (1000)
      --ax-timeout-ms N      Accessibility timeout while measuring (250)
      --no-wait              don't wait for Chrome to come to the front
      --skip-profile-check   only if Chrome's arguments can't be read
    """
}
