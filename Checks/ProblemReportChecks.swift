import Foundation
import MemoryCore

/// report-1004 (owner decision 2026-10-03): Report a Problem… opens an email to support@getdaydream.app in the person's
/// own mail app (a mailto: link); DayDream sends nothing. Every input below is poisoned with a fake typed secret, a web
/// address, a window title, a contact name, a /Users/<name> path and a key, and none of it may reach the subject, the
/// body, the link or the clipboard text. Then the mailto encoding and the length cap. Synthetic values only.
func runProblemReportChecks() throws {
    // 1. The poison: made-up values of every kind the email must never hold.
    let secret = "tangerine-4417 swordfish", word = "swordfish"
    let url = "https://private.example.test/board?id=8812&key=abc#minutes"
    let title = "Q3 Board Minutes – Riley Park"
    let path = "/Users/rileypark/Documents/secret-plan.txt"
    let key = "sk-or-v1-0123456789abcdef0123456789abcdef"
    let poison = [secret, word, url, title, path, key]
    // Pieces that must not show up anywhere, even split apart or percent-encoded.
    let needles = ["tangerine", "4417", "swordfish", "private.example", "example.test", "board?id", "8812", "Board Minutes", "Riley",
                   "rileypark", "/Users/", "Documents", "secret-plan", "sk-or", "0123456789abcdef", "minutes"]

    // 2. Error codes: DayDream's own types give their type and case only, never what they carry.
    let errors = ProblemReportErrors()
    errors.record(MemError.invalid(secret + " " + title))
    errors.record(MemError.database("INSERT \(url) \(path) (code 13)"))
    errors.record(MemError.busy("\(key) (code 5)"))
    errors.record(AIAppConnectError.notYours(path))
    errors.record(AIAppConnectError.keptChanging(title, path))
    errors.record(TypedTextError.typingLocked(.locked))
    errors.record(TypedTextError.typingLocked(.locked))
    // Not DayDream's own types: nothing is kept, whatever their case or message says.
    enum Foreign: Error { case swordfish, tangerine(String) }
    errors.record(Foreign.swordfish)
    errors.record(Foreign.tangerine(secret))
    errors.record(NSError(domain: url, code: 4417, userInfo: [NSLocalizedDescriptionKey: secret, NSFilePathErrorKey: path]))
    errors.record(CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path]))
    let codes = errors.recent.map(\.code)
    try check(codes == ["MemError.database:13", "MemError.busy:5", "AIAppConnectError.notYours", "AIAppConnectError.keptChanging",
                        "TypedTextError.typingLocked"], "report: the last five codes, oldest first, type and case only (\(codes))")
    try check(errors.recent.last?.count == 2 && errors.count == 7, "report: a repeat counts on its line; foreign errors are not kept (\(errors.count))")
    try check(ProblemReportErrors.code(MemError.denied) == "MemError.denied" && ProblemReportErrors.code(TypedTextError.notAccepted) == "TypedTextError.notAccepted"
              && ProblemReportErrors.code(AIAppConnectError.changedSinceReview)?.hasPrefix("AIAppConnectError#") == true
              && ProblemReportErrors.code(AIAppConnectError.unknownApp(secret)) == "AIAppConnectError.unknownApp",
              "report: a plain case is its name, or its number when only its message would say it")
    // The shape check is the second fence: a code is made only by `code(_:)` from a type's and case's own names (an
    // `Entry` can't be made outside MemoryCore), so a lone word like "swordfish" never gets to it as a code.
    try check(poison.filter { $0 != word }.allSatisfy { !ProblemReportErrors.isCode($0) } && ProblemReportErrors.isCode("MemError.database:13")
              && ProblemReportErrors.isCode("AIAppConnectError#9") && !ProblemReportErrors.isCode("MemError.invalid swordfish"),
              "report: only code-shaped text passes as a code")

    // 3. Poisoned facts: every text input carries the poison.
    var facts = ProblemReportFacts(version: "0.1.4", build: "12", macOS: "26.0.1", accessibility: .on, inputMonitoring: .off,
                                   chromeAutomation: .on, recording: .on, summaries: .thisMac,
                                   connectedApps: ["Claude Code"] + poison + ["Claude Code", "Cursor"],
                                   errors: errors.recent, errorCount: errors.count, momentsToday: 42, summariesWaiting: 3)
    let clean = ProblemReportMail.body(facts)
    try check(clean.hasPrefix("What happened?\n") && clean.contains("DayDream 0.1.4 (build 12), macOS 26.0.1")
              && clean.contains("Accessibility: on") && clean.contains("Input Monitoring: off") && clean.contains("Chrome automation: on")
              && clean.contains("Recording: on") && clean.contains("Summaries: This Mac") && clean.contains("AI apps connected: Claude Code, Cursor")
              && clean.contains("Moments today: 42") && clean.contains("Summaries waiting: 3") && clean.contains("Errors this run: 7")
              && clean.contains("Recent errors: MemError.database:13, MemError.busy:5, AIAppConnectError.notYours, AIAppConnectError.keptChanging, TypedTextError.typingLocked ×2"),
              "report: the body says the states, the known AI apps once each and the codes\n\(clean)")
    try check(ProblemReportMail.subject(facts) == "DayDream problem report (0.1.4 build 12)", "report: the subject names the version and build")
    for value in poison {
        var bad = facts
        bad.version = value; bad.build = value; bad.macOS = value
        bad.connectedApps = [value, "Claude Desktop " + value, value + "Claude Code"]
        let made = [ProblemReportMail.subject(bad), ProblemReportMail.body(bad), ProblemReportMail.clipboardText(bad),
                    ProblemReportMail.url(bad).absoluteString, ProblemReportMail.url(bad).absoluteString.removingPercentEncoding ?? ""]
        let leaked = needles.filter { needle in made.contains { $0.range(of: needle, options: .caseInsensitive) != nil } }
        try check(leaked.isEmpty, "report: no part of \"\(value.prefix(24))…\" reaches the subject, body, link or clipboard text (\(leaked))")
        try check(ProblemReportMail.subject(bad) == "DayDream problem report (unknown build unknown)"
                  && ProblemReportMail.body(bad).contains("macOS unknown") && ProblemReportMail.body(bad).contains("AI apps connected: none"),
                  "report: a poisoned version, build, macOS or app name is written as unknown or left out")
    }
    // Every poisoned field at once, beside real states.
    facts.version = "0.1.4 " + title; facts.build = "12 " + path
    let all = [ProblemReportMail.subject(facts), ProblemReportMail.body(facts), ProblemReportMail.clipboardText(facts),
               ProblemReportMail.url(facts).absoluteString, ProblemReportMail.url(facts).absoluteString.removingPercentEncoding ?? ""]
    let leaked = needles.filter { needle in all.contains { $0.range(of: needle, options: .caseInsensitive) != nil } }
    try check(leaked.isEmpty, "report: with every input poisoned at once, nothing of it gets through (\(leaked))")
    let sent = all.joined(separator: "\n").matches(of: #/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/#).map { String($0.output) }
    try check(Set(sent) == ["support@getdaydream.app"], "report: the only email address is support@getdaydream.app (\(Set(sent)))")

    // 4. The mailto link.
    facts = ProblemReportFacts(version: "0.1.0 Beta", build: "1.2", macOS: "26.0.1", recording: .paused, summaries: .cloud,
                               connectedApps: ["ChatGPT"], errors: errors.recent, errorCount: errors.count, momentsToday: 0)
    let link = ProblemReportMail.url(facts)
    let text = link.absoluteString
    try check(link.scheme == "mailto" && text.hasPrefix("mailto:support@getdaydream.app?subject="), "mailto: the link goes to support@getdaydream.app (\(text.prefix(60))…)")
    let query = String(text[text.index(after: text.firstIndex(of: "?")!)...])
    let fields = query.components(separatedBy: "&")
    try check(fields.count == 2 && fields[0].hasPrefix("subject=") && fields[1].hasPrefix("body="), "mailto: exactly a subject and a body (\(fields.count) fields)")
    let subject = String(fields[0].dropFirst("subject=".count)), body = String(fields[1].dropFirst("body=".count))
    try check(subject.removingPercentEncoding == ProblemReportMail.subject(facts), "mailto: the subject decodes to the subject")
    try check(body.removingPercentEncoding == ProblemReportMail.body(facts).replacingOccurrences(of: "\n", with: "\r\n"),
              "mailto: the body decodes to the body, line breaks as CRLF")
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~%")
    try check((subject + body).unicodeScalars.allSatisfy(allowed.contains), "mailto: subject and body keep only unreserved characters and %XX")
    try check(body.contains("%0D%0A") && !body.contains("%0A%0A") && subject.contains("%20") && subject.contains("%28") && body.contains("%C3%97"),
              "mailto: line breaks are %0D%0A, spaces %20, ( %28, × as UTF-8")
    let components = URLComponents(url: link, resolvingAgainstBaseURL: false)
    try check(components?.path == ProblemReportMail.supportAddress
              && components?.queryItems?.map(\.name) == ["subject", "body"]
              && components?.queryItems?.first?.value == ProblemReportMail.subject(facts),
              "mailto: a URL parser reads the address, the subject and the body")
    try check(ProblemReportMail.encode("a&b=c?d#e+f g/h\n") == "a%26b%3Dc%3Fd%23e%2Bf%20g%2Fh%0A", "mailto: & = ? # + space / and line breaks are encoded")
    try check(ProblemReportMail.clipboardText(facts) == "To: support@getdaydream.app\nSubject: DayDream problem report (0.1.0 Beta build 1.2)\n\n" + ProblemReportMail.body(facts),
              "clipboard: the same subject and body, with the address")

    // 5. The length cap: the longest body the inputs allow stays under 1500 characters.
    let long = ProblemReportErrors()
    let longest: [Error] = [AIAppConnectError.keptOtherSettingsCheckFailed(path), AIAppConnectError.notEditableTOML(path),
                            AIAppConnectError.unexpectedShape(path), MemError.database("x (code 123456)"), MemError.busy("x (code -123456)"),
                            AIAppConnectError.keptOtherSettingsCheckFailed(path)]
    for error in longest { for _ in 0..<20_000 { long.record(error) } }
    let worst = ProblemReportFacts(version: "1234.1234.1234.1234 Preview", build: "123456.123456.123456", macOS: "100.100.100",
                                   accessibility: .unknown, inputMonitoring: .unknown, chromeAutomation: .unknown,
                                   recording: .needsPermission, summaries: .unknown,
                                   connectedApps: AIAppConnect.apps.map(\.name) + poison, errors: long.recent, errorCount: Int.max,
                                   momentsToday: Int.max, summariesWaiting: -5)
    let worstBody = ProblemReportMail.body(worst)
    try check(worstBody.count < ProblemReportMail.maxBodyLength && worstBody.contains("×9999") && worstBody.contains("Errors this run: 999999")
              && worstBody.contains("Summaries waiting: 0"),
              "length: the longest body is \(worstBody.count) characters, under \(ProblemReportMail.maxBodyLength); counts are capped")
    let worstLink = ProblemReportMail.url(worst).absoluteString
    try check(worstLink.count < 2000, "length: the longest link is \(worstLink.count) characters, under 2000")
    try check(ProblemReportMail.body(ProblemReportFacts(version: "0.1.4", build: "1", macOS: "26.0")).count < 600, "length: a plain report is short")

    // 6. The code: no way to send anything, and no address but support's.
    func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    let code = source("Sources/MemoryCore/ProblemReportMail.swift") + source("Sources/MacMemApp/ReportProblem.swift")
    try check(code.contains("ProblemReportMail") && code.contains("ReportProblemMail"), "source: both report files were read")
    try check(["URLSession", "URLRequest", "NSSharingService", "NSAppleScript", "SMTP", "Process(", "CFNetwork", "import Network", "openURL", "http"]
              .allSatisfy { !code.contains($0) }, "source: the report code has no network, sharing or script call")
    let addresses = code.matches(of: #/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/#).map { String($0.output) }
    try check(Set(addresses) == ["support@getdaydream.app"], "source: the only address in the report code is support@getdaydream.app (\(Set(addresses)))")
    print("PASS report-1004: Report a Problem's email holds states only; poisoned inputs never reach it; mailto encoded; under 1500 characters.")
}
