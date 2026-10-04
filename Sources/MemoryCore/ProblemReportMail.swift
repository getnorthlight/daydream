import Foundation

// Report a Problem… (Help, and the menu bar menu above Quit DayDream) opens a new email in the person's own mail app: a
// mailto: link to `ProblemReportMail.supportAddress`. The person reads it and presses Send there. DayDream has no network
// code for this and sends nothing itself; with no mail app set up, the same text goes on the clipboard instead
// (MacMemApp's ReportProblem.swift).
//
// The email is a "What happened?" section for the person to fill in, then a short block of states. Every value in the
// block is a number, a fixed word, or a name from DayDream's own lists: the version and build, macOS, the Accessibility,
// Input Monitoring and Chrome automation states, whether recording is on, the summary mode, the connected AI apps (names
// in `AIAppConnect.apps` only), the last few error codes (`ProblemReportErrors`: an error type's and case's names, never
// its message or values) and a few counts. No input takes free text through: a typed word, a window or page title, a web
// address, a site, a contact name, a path or a key has nowhere to go. Checks/ProblemReportChecks.swift poisons every
// input and checks that none of it reaches the subject, the body or the link.

/// The states the email may say. Each is checked again as the email is written (`ProblemReportMail`), so a value that
/// isn't a plain version, number, fixed word or known name is left out.
public struct ProblemReportFacts: Equatable, Sendable {
    public enum Switch: String, Equatable, Sendable { case on, off, unknown }
    public enum Recording: String, Equatable, Sendable { case on, paused, off, needsPermission = "needs permission", unknown }
    public enum Summaries: String, Equatable, Sendable { case thisMac = "This Mac", cloud, off, unknown }

    /// CFBundleShortVersionString ("0.1.4", "0.1.0 Beta"); anything else is written "unknown".
    public var version: String
    /// CFBundleVersion ("12", "1.2"); anything else is written "unknown".
    public var build: String
    /// "26.0.1": digits and dots only.
    public var macOS: String
    public var accessibility: Switch
    public var inputMonitoring: Switch
    public var chromeAutomation: Switch
    public var recording: Recording
    public var summaries: Summaries
    /// Connected AI apps. Only names in `AIAppConnect.apps` are written.
    public var connectedApps: [String]
    /// The last few error codes, oldest first (`ProblemReportErrors.recent`). Only code-shaped ones are written.
    public var errors: [ProblemReportErrors.Entry]
    /// Error codes recorded this run.
    public var errorCount: Int
    /// Moments remembered today; nil when not read.
    public var momentsToday: Int?
    /// Moments waiting for a summary; nil when not read.
    public var summariesWaiting: Int?

    public init(version: String, build: String, macOS: String, accessibility: Switch = .unknown, inputMonitoring: Switch = .unknown,
                chromeAutomation: Switch = .unknown, recording: Recording = .unknown, summaries: Summaries = .unknown,
                connectedApps: [String] = [], errors: [ProblemReportErrors.Entry] = [], errorCount: Int = 0,
                momentsToday: Int? = nil, summariesWaiting: Int? = nil) {
        self.version = version; self.build = build; self.macOS = macOS
        self.accessibility = accessibility; self.inputMonitoring = inputMonitoring; self.chromeAutomation = chromeAutomation
        self.recording = recording; self.summaries = summaries; self.connectedApps = connectedApps
        self.errors = errors; self.errorCount = errorCount; self.momentsToday = momentsToday; self.summariesWaiting = summariesWaiting
    }
}

public enum ProblemReportMail {
    /// Where reports go. The owner forwards it; no personal address is ever in the app.
    public static let supportAddress = "support@getdaydream.app"
    /// The body stays under this, so every mail app takes the whole link.
    public static let maxBodyLength = 1500
    /// The heading the person writes under.
    public static let prompt = "What happened?"
    /// The line over the states: what DayDream added, and what it never adds.
    public static let statesHeading = "Added by DayDream (no history, typed words, titles, web addresses, names or keys):"

    /// "DayDream problem report (0.1.4 build 12)".
    public static func subject(_ facts: ProblemReportFacts) -> String {
        "DayDream problem report (\(version(facts.version)) build \(build(facts.build)))"
    }

    /// The "What happened?" section, then the states. Lines end in "\n"; `url` writes them as CRLF.
    public static func body(_ facts: ProblemReportFacts) -> String {
        func count(_ value: Int?) -> String { value.map { String(min(max($0, 0), 999_999)) } ?? "unknown" }
        let apps = connectedApps(facts.connectedApps)
        var lines = [
            prompt, "", "", "", "",
            statesHeading,
            "DayDream \(version(facts.version)) (build \(build(facts.build))), macOS \(macOS(facts.macOS))",
            "Accessibility: \(facts.accessibility.rawValue)",
            "Input Monitoring: \(facts.inputMonitoring.rawValue)",
            "Chrome automation: \(facts.chromeAutomation.rawValue)",
            "Recording: \(facts.recording.rawValue)",
            "Summaries: \(facts.summaries.rawValue)",
            "AI apps connected: \(apps.isEmpty ? "none" : apps.joined(separator: ", "))",
            "Moments today: \(count(facts.momentsToday))",
            "Summaries waiting: \(count(facts.summariesWaiting))",
            "Errors this run: \(count(facts.errorCount))",
        ]
        let errors = facts.errors.suffix(ProblemReportErrors.reportLimit).compactMap { entry -> String? in
            guard ProblemReportErrors.isCode(entry.code) else { return nil }
            return entry.count > 1 ? "\(entry.code) ×\(min(entry.count, 9_999))" : entry.code
        }
        lines.append("Recent errors: " + (errors.isEmpty ? "none" : errors.joined(separator: ", ")))
        var text = lines.joined(separator: "\n") + "\n"
        // Never reached with the limits above (the checks pin the longest body); kept so a later line can't push it over.
        if text.count > maxBodyLength { text = String(text.prefix(maxBodyLength - 1)) + "\n" }
        return text
    }

    /// The mailto: link: the address, then the subject and body percent-encoded (RFC 6068: line breaks as %0D%0A,
    /// spaces as %20, only unreserved characters left as they are).
    public static func url(_ facts: ProblemReportFacts) -> URL {
        let body = body(facts).replacingOccurrences(of: "\n", with: "\r\n")
        return URL(string: "mailto:\(supportAddress)?subject=\(encode(subject(facts)))&body=\(encode(body))")!
    }

    /// What goes on the clipboard when no mail app opens the link: the address and subject, then the same body.
    public static func clipboardText(_ facts: ProblemReportFacts) -> String {
        "To: \(supportAddress)\nSubject: \(subject(facts))\n\n" + body(facts)
    }

    /// Percent-encodes everything but RFC 3986's unreserved characters.
    public static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: Values

    /// "0.1.4", "0.1.0 Beta": up to four numbers and an optional Beta or Preview; else "unknown".
    public static func version(_ text: String) -> String {
        matches(text, #"^[0-9]{1,4}(\.[0-9]{1,4}){0,3}( (Beta|beta|Preview|preview))?$"#) ? text : "unknown"
    }
    /// "12", "1.2": up to three numbers; else "unknown".
    public static func build(_ text: String) -> String {
        matches(text, #"^[0-9]{1,6}(\.[0-9]{1,6}){0,2}$"#) ? text : "unknown"
    }
    /// "26.0.1": up to three numbers; else "unknown".
    public static func macOS(_ text: String) -> String {
        matches(text, #"^[0-9]{1,3}(\.[0-9]{1,3}){0,2}$"#) ? text : "unknown"
    }
    /// Known AI app names only, once each, in `AIAppConnect.apps` order.
    public static func connectedApps(_ names: [String]) -> [String] {
        let given = Set(names)
        return AIAppConnect.apps.map(\.name).filter(given.contains)
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

/// The last few error codes from DayDream's own error types, for Report a Problem. Kept in memory for this run only.
/// A code is the error's type and case ("MemError.busy", "TypedTextError.typingLocked"), the SQLite code for a storage
/// error ("MemError.database:13"), or the type and Swift's case number when the case's name can't be read without its
/// message ("AIAppConnectError#9"). Never the error's message, values, or anything it carries.
public final class ProblemReportErrors: @unchecked Sendable {
    public static let shared = ProblemReportErrors()
    /// How many codes the email lists.
    public static let reportLimit = 5
    /// Modules whose error types are DayDream's own. Errors of any other type (the system's, a library's) are not kept.
    public static let ownModules: Set<String> = ["MemoryCore", "MemoryUI", "HistoryCore", "MacMemApp", "MacMemCLI", "BackupRestore",
                                                 "CoreIntegration", "WriterBackend", "BrowserBridge", "PrivacyPolicy"]

    /// One code, and how many times in a row it came. Made only here (`record`), so every code came from `code(_:)`.
    public struct Entry: Equatable, Sendable {
        public let code: String
        public let count: Int
        init(code: String, count: Int) { self.code = code; self.count = count }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var total = 0
    public init() {}

    /// Notes the error's code. An error that isn't one of DayDream's own types is not kept.
    public func record(_ error: Error) {
        guard let code = Self.code(error) else { return }
        lock.lock(); defer { lock.unlock() }
        total += 1
        if let last = entries.last, last.code == code {
            entries[entries.count - 1] = Entry(code: code, count: last.count + 1)
        } else {
            entries.append(Entry(code: code, count: 1))
            if entries.count > Self.reportLimit { entries.removeFirst(entries.count - Self.reportLimit) }
        }
    }

    /// The last few codes, oldest first.
    public var recent: [Entry] { lock.lock(); defer { lock.unlock() }; return entries }
    /// Codes recorded this run.
    public var count: Int { lock.lock(); defer { lock.unlock() }; return total }

    /// The error's code, or nil when its type isn't DayDream's own.
    public static func code(_ error: Error) -> String? {
        let parts = String(reflecting: type(of: error)).split(separator: ".").map(String.init)
        guard let module = parts.first, ownModules.contains(module), let type = parts.last, isName(type) else { return nil }
        let code: String
        switch error {
        case let mem as MemError:
            switch mem {
            case .busy: code = "MemError.busy" + (mem.sqliteCode.map { ":\($0)" } ?? "")
            case .database: code = "MemError.database" + (mem.sqliteCode.map { ":\($0)" } ?? "")
            case .invalid: code = "MemError.invalid"
            case .denied: code = "MemError.denied"
            case .missing: code = "MemError.missing"
            }
        case let typed as TypedTextError:
            switch typed {
            case .typingLocked: code = "TypedTextError.typingLocked"
            case .cannotSetUp: code = "TypedTextError.cannotSetUp"
            case .openFailed: code = "TypedTextError.openFailed"
            case .notAccepted: code = "TypedTextError.notAccepted"
            }
        default:
            code = type + caseName(error)
        }
        return isCode(code) ? code : nil
    }

    /// ".caseName" read from the type itself (a case with values names itself in its mirror; a plain case is its own
    /// description), "#N" (Swift's case number) when only a message would say it, or "" for a struct or class.
    static func caseName(_ error: Error) -> String {
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum else { return "" }
        if let label = mirror.children.first?.label { return isName(label) ? "." + label : "" }
        if !(error is CustomStringConvertible), !(error is CustomDebugStringConvertible) {
            let plain = String(describing: error)
            if isName(plain) { return "." + plain }
        }
        let number = (error as NSError).code
        return (0...9_999).contains(number) ? "#\(number)" : ""
    }

    /// A Swift name: a letter, then letters and digits, at most 48.
    static func isName(_ text: String) -> Bool { ProblemReportMail.matches(text, #"^[A-Za-z][A-Za-z0-9_]{0,47}$"#) }
    /// "Type", "Type.case", "Type#3", with an optional ":<number>".
    public static func isCode(_ text: String) -> Bool {
        ProblemReportMail.matches(text, #"^[A-Za-z][A-Za-z0-9_]{0,47}(\.[A-Za-z][A-Za-z0-9_]{0,47}|#[0-9]{1,4})?(:-?[0-9]{1,6})?$"#)
    }
}
