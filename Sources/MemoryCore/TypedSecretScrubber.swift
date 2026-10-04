import Foundation
import PrivacyPolicy

/// Safe typing C, the store-side net. It runs inside `MemoryStore.ingest` on
/// every typed unit (`keyboard.text_input`) before the words are sealed, and
/// on build 4 rows the legacy migration seals. It is the third layer: password
/// fields and Secure Input are never read, and the capture-side
/// `TextClassifier`/`UnitClassifier` has already run.
///
/// Pure: no store, no clock, no logging. The result is the text with each
/// secret replaced by `[withheld]`, or a decision to drop the whole unit.
/// Reasons are codes only; nothing it returns, prints or describes ever
/// contains the matched text.
public enum TypedSecretScrubber {
    public static let version = "typed-scrub/v1"
    /// The same marker the capture side uses for a withheld token.
    public static let marker = "[withheld]"
    /// Longer input is cut at a word boundary first (the store keeps at most
    /// 2000 characters of a typed unit anyway).
    static let maxCharacters = 4096

    public enum Reason: String, CaseIterable, Codable, Sendable {
        case privateKey, providerToken, highEntropy, paymentCard, longNumber, ssn, oneTimeCode, connectionString,
             assignment, cliSecretFlag, authHeader, privilegedCommand, afterPrivilegedCommand, passwordLabel,
             recoveryCode, recoveryPhrase
    }

    /// `keep`: the text to save and one reason per withheld span.
    /// `drop`: save nothing for this unit.
    public enum Result: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
        case keep(String, redactions: [Reason])
        case drop(Reason)
        public var description: String {
            switch self {
            case .keep(_, let r): return "TypedSecretScrubber.keep(redacted, redactions:[\(r.map(\.rawValue).joined(separator: ","))])"
            case .drop(let r): return "TypedSecretScrubber.drop(\(r.rawValue))"
            }
        }
        public var customMirror: Mirror { Mirror(self, children: [:]) }
        public var reasons: [Reason] {
            switch self { case .keep(_, let r): return r; case .drop(let r): return [r] }
        }
        public var kept: String? {
            if case .keep(let t, _) = self { return t }; return nil
        }
    }

    // MARK: - Entry point

    public static func scrub(_ input: String) -> Result {
        scrub(input, narrativePrefix: nil)
    }

    private static func scrub(_ input: String, narrativePrefix: String?) -> Result {
        let text = normalized(input)
        // 1. Whole-unit drops.
        if matches(privateKeyRules, text) { return .drop(.privateKey) }
        if loneNumber(text) { return .drop(.oneTimeCode) }
        if loneAppPassword(text) { return .drop(.recoveryCode) }
        // 2. Line rules: privileged commands, the line after one, and the
        //    line after a label that waits for a password.
        var reasons: [Reason] = []
        let lined = lineRules(text, reasons: &reasons)
        // 3. Span rules, then high-entropy tokens outside those spans.
        var spans: [Span] = []
        for rule in spanRules { spans += ruleSpans(rule, lined, narrativePrefix: narrativePrefix.map { $0 + (input.first == " " ? " " : "") }) }
        spans += numberSpans(lined)
        spans += cardTails(lined, after: spans)
        spans += tokenSpans(lined, avoiding: spans)
        // Last, and the weakest reason: a token the rules above also withhold keeps their reason.
        spans += labelSpans(lined)
        let merged = merge(spans)
        let out = NSMutableString(string: lined)
        for s in merged.reversed() { out.replaceCharacters(in: s.range, with: marker) }
        reasons += merged.map(\.reason)
        let result = out as String
        // 4. A unit that was only secrets is dropped, not saved as markers.
        if !reasons.isEmpty {
            let rest = result.replacingOccurrences(of: marker, with: " ")
            if !rest.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) { return .drop(reasons[0]) }
        }
        return .keep(result, redactions: reasons)
    }

    /// For `MemoryStore.ingest`: nil drops the unit. Appends the scrubber
    /// version to the capture provenance and, when something was withheld,
    /// counts it and clears the key and edit counts (with the saved text
    /// they would give the withheld length), as the capture side does.
    static func scrubbed(_ e: Evidence, narrativePrefix: String? = nil) -> Evidence? {
        guard case .keep(let text, let redactions) = scrub(e.text, narrativePrefix: narrativePrefix) else { return nil }
        var out = e
        out.text = text
        if var p = out.captureProvenance {
            if !p.classifierVersion.hasSuffix("+" + version) { p.classifierVersion += "+" + version }
            if !redactions.isEmpty, var unit = p.unit { unit.withheld += redactions.count; unit.keys = nil; unit.edits = nil; p.unit = unit }
            out.captureProvenance = p
        }
        return out
    }

    /// Keep safe captured piece boundaries without changing security canonicalisation.
    /// Called only after scrubbed(), Privacy.sanitized and TypedHistoryScrub; all
    /// secret decisions and span offsets therefore still use their canonical text.
    /// Legacy, withheld or incomplete units keep the existing normalisation.
    static func restoringOuterSpaces(from original: Evidence, sanitized: Evidence) -> Evidence {
        guard original.kind == "keyboard.text_input", sanitized.kind == "keyboard.text_input",
              !sanitized.text.isEmpty, !sanitized.text.contains(marker),
              let p = sanitized.captureProvenance,
              p.classifierVersion.hasSuffix("+" + version),
              !p.windowID.isEmpty, !p.focusID.isEmpty, p.generation > 0,
              let unit = p.unit,
              ["typed-unit/v2", TypedUnitProvenance.sendFactsVersion].contains(unit.version),
              unit.withheld == 0, !unit.runID.isEmpty, unit.part > 0,
              let field = unit.field, SendRules.fields.contains(field), field != "unknown" else { return sanitized }
        // Only literal ASCII spaces are restored. Unicode, controls, line breaks
        // and interior whitespace keep the existing sanitisation. Bound both
        // scans and the final text by Privacy.clean's existing 2,000-character cap.
        let leading = String(original.text.prefix(2001).prefix(while: { $0 == " " }))
        let trailing = String(original.text.reversed().prefix(2001).prefix(while: { $0 == " " }))
        guard leading.count + sanitized.text.count + trailing.count <= 2000 else { return sanitized }
        var out = sanitized
        out.text = leading + sanitized.text + trailing
        return out
    }

    // MARK: - Normalising

    /// NFKC (so NBSP and full-width forms become plain), zero-width and
    /// control characters removed, line breaks unified, runs of spaces and
    /// tabs made one space, each line trimmed.
    static func normalized(_ input: String) -> String {
        var s = input.replacingOccurrences(of: "\r\n", with: "\n").precomposedStringWithCompatibilityMapping
        if s.count > maxCharacters {
            s = String(s.prefix(maxCharacters))
            // Drop the token the cut went through: its first part may be a secret.
            if let last = s.lastIndex(where: { $0.isWhitespace }) { s = String(s[..<last]) } else { s = "" }
        }
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x00AD: continue
            case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: scalars.append("\n")
            default:
                if u.properties.isWhitespace { scalars.append(" ") }
                else if CharacterSet.controlCharacters.contains(u) { continue }
                else { scalars.append(u) }
            }
        }
        return String(scalars).components(separatedBy: "\n")
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
            .joined(separator: "\n")
    }

    // MARK: - Privileged commands (kept identical to TerminalPromptLatch)

    /// Commands that ask for a password or carry one on their line. Kept equal
    /// to `TerminalPromptLatch.privilegedCommands` (a check compares them).
    public static let privilegedCommands = ["sudo", "su", "doas", "ssh", "scp", "sftp", "sshpass", "passwd", "login", "security", "gpg", "ssh-add", "kinit", "mysql", "mysqldump", "mysqladmin", "mariadb", "psql", "pinentry", "redis-cli", "mongosh", "htpasswd", "ftp", "telnet"]
    /// Two- and three-word starts that log in.
    public static let privilegedPhrases = [["docker", "login"], ["podman", "login"], ["npm", "login"], ["npm", "adduser"], ["gh", "auth", "login"], ["op", "signin"], ["vault", "login"], ["security", "unlock-keychain"]]
    /// Command words that are also ordinary words ("su casa", "login page",
    /// "security review"): lowercase, and shaped like a command.
    static let proseAmbiguous: Set<String> = ["su", "login", "security"]
    static let securitySubcommands: Set<String> = ["unlock-keychain", "find-generic-password", "find-internet-password", "add-generic-password", "add-internet-password", "delete-generic-password", "delete-internet-password", "dump-keychain", "create-keychain", "set-keychain-password", "import", "export"]
    static let wrappers: Set<String> = ["$", "%", ">", "env", "time", "nohup", "exec", "command", "builtin", "noglob", "caffeinate"]
    static let trustedBinDirs = ["/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/", "/usr/local/bin/", "/opt/homebrew/bin/"]

    static func isAssignmentWord(_ w: Substring) -> Bool {
        w.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil
    }
    static func commandName(_ w: Substring) -> String {
        if w.contains("/") {
            guard let dir = trustedBinDirs.first(where: { w.hasPrefix($0) }) else { return "" }
            return String(w.dropFirst(dir.count))
        }
        return String(w)
    }
    /// Where the privileged command starts in one shell segment's words and
    /// how many words name it, or nil. `chained`: the segment follows `&&`,
    /// `;` or `|`; an ambiguous word there needs an option or nothing after
    /// it ("notes | login redesign" is prose).
    static func privilegedCommand(_ words: [Substring], chained: Bool = false) -> (start: Int, length: Int)? {
        var i = 0, afterEnv = false
        while i < words.count {
            let w = words[i]
            if wrappers.contains(String(w)) { afterEnv = afterEnv || w == "env"; i += 1; continue }
            if isAssignmentWord(w) || (afterEnv && w.hasPrefix("-")) { i += 1; continue }
            break
        }
        guard i < words.count else { return nil }
        let name = commandName(words[i]), lower = name.lowercased()
        guard !name.isEmpty else { return nil }
        for phrase in privilegedPhrases where phrase[0] == lower && words.count >= i + phrase.count {
            if zip(phrase.dropFirst(), words[(i + 1)...]).allSatisfy({ $0.0 == $0.1.lowercased() }) { return (i, phrase.count) }
        }
        guard privilegedCommands.contains(lower) else { return nil }
        if proseAmbiguous.contains(lower) {
            guard name == lower else { return nil }
            let rest = words[(i + 1)...]
            if lower == "security" {
                guard let sub = rest.first, securitySubcommands.contains(String(sub)) else { return nil }
            } else if chained {
                guard rest.isEmpty || rest.first!.hasPrefix("-") else { return nil }
            } else {
                guard rest.count <= 2, rest.allSatisfy({ $0.hasPrefix("-") || $0.range(of: "^[a-z_][a-z0-9_.@-]*$", options: .regularExpression) != nil }) else { return nil }
            }
        }
        return (i, 1)
    }
    /// One line split at `&&`, `||`, `;` and `|`: (separator before, words).
    static func segments(_ line: String) -> [(sep: String, words: [Substring])] {
        let ns = line as NSString
        var out: [(String, [Substring])] = [], start = 0, sep = ""
        for m in separatorRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            out.append((sep, ns.substring(with: NSRange(location: start, length: m.range.location - start)).split(separator: " ")))
            sep = ns.substring(with: m.range(at: 1)); start = m.range.location + m.range.length
        }
        out.append((sep, ns.substring(from: start).split(separator: " ")))
        return out
    }
    static let separatorRegex = try! NSRegularExpression(pattern: #"\s*(&&|\|\||;|\|)\s*"#)
    /// True when any shell segment of the line starts with a privileged command.
    public static func isPrivilegedCommandLine(_ line: String) -> Bool {
        segments(normalized(line).replacingOccurrences(of: "\n", with: " ")).enumerated().contains { privilegedCommand($0.element.words, chained: $0.offset > 0) != nil }
    }

    // MARK: - Line rules

    static let pendingLabel = try! NSRegularExpression(pattern: #"(?:(?<![a-z])(?:password|passphrase|passcode|passwd|pwd|pin|otp|one[- ]?time code|verification code|security code|2fa code|mfa code|api[ _-]?key|access[ _-]?token|token|secret|contraseña|mot de passe|passwort|kennwort)\s*(?:[:=]|\s(?:is|was)\s*:?)|^(?:enter |new |retype |current |old )?(?:password|passphrase|pin)\b.{0,80}:)\s*$"#, options: [.caseInsensitive])

    /// Privileged command lines keep the command and lose the rest; the next
    /// non-empty line after one, or after a label waiting for a password
    /// ("Password:"), is withheld whole.
    static func lineRules(_ text: String, reasons: inout [Reason]) -> String {
        var lines = text.components(separatedBy: "\n")
        var pending: Reason? = nil
        for k in lines.indices {
            let line = lines[k]
            if line.isEmpty { continue }
            if let why = pending {
                lines[k] = marker; reasons.append(why); pending = nil
                // A withheld line that was itself a command still arms the next.
                if isPrivilegedCommandLine(line) { pending = .afterPrivilegedCommand }
                continue
            }
            let parts = segments(line)
            var handled = false
            for (j, part) in parts.enumerated() {
                guard let cmd = privilegedCommand(part.words, chained: j > 0) else { continue }
                handled = true
                if j > 0 && part.sep == "|" {
                    // "echo … | sudo -S": the secret is before the command.
                    lines[k] = marker; reasons.append(.privilegedCommand)
                } else {
                    var kept = parts[..<j].map { p in (p.sep.isEmpty ? "" : p.sep + " ") + p.words.joined(separator: " ") }
                    var words: [String] = part.words[..<cmd.start].map { isAssignmentWord($0) ? marker : String($0) }
                    words += part.words[cmd.start..<(cmd.start + cmd.length)].map(String.init)
                    let restOfLine = part.words.count > cmd.start + cmd.length || j < parts.count - 1
                    if restOfLine { words.append(marker) }
                    kept.append((part.sep.isEmpty ? "" : part.sep + " ") + words.joined(separator: " "))
                    lines[k] = kept.joined(separator: " ")
                    if restOfLine || words.contains(marker) { reasons.append(.privilegedCommand) }
                }
                pending = .afterPrivilegedCommand
                break
            }
            if !handled, pendingLabel.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                pending = .passwordLabel
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Span rules

    struct Span { var range: NSRange; var reason: Reason; var priority: Int }
    struct Rule {
        let reason: Reason, regex: NSRegularExpression, group: Int, priority: Int
        let accept: (NSString, NSTextCheckingResult) -> Bool
    }
    static func rule(_ reason: Reason, _ pattern: String, group: Int = 0, caseInsensitive: Bool = false, priority: Int, accept: @escaping (NSString, NSTextCheckingResult) -> Bool = { _, _ in true }) -> Rule {
        Rule(reason: reason, regex: try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []), group: group, priority: priority, accept: accept)
    }

    /// A rule's accepted spans. After a match the rule turns down, the scan
    /// goes on from that match's value, not from its end (review round 1: in
    /// "Bank login: password: Summer2024!", "todo: password: …" or
    /// "Netflix:\npassword: …" the ordinary pair "login: password:" used up
    /// the label, so the secret pair after it was never looked at). Bounds are
    /// transparent and not anchoring, so a scan that goes on matches exactly
    /// as the same regex over the whole text would.
    static func ruleSpans(_ rule: Rule, _ text: String, narrativePrefix: String? = nil) -> [Span] {
        let ns = text as NSString, length = ns.length
        var out: [Span] = [], location = 0
        while location < length, let m = rule.regex.firstMatch(in: text, options: [.withTransparentBounds, .withoutAnchoringBounds],
                                                                  range: NSRange(location: location, length: length - location)) {
            let r = rule.group < m.numberOfRanges ? m.range(at: rule.group) : m.range
            let end = max(m.range.location + m.range.length, m.range.location + 1)
            let carriedEmoticon = rule.reason == .assignment && rule.group == 4 && narrativePrefix.map {
                narrativeSigEmoticon(ns, m, priorPrefix: $0)
            } == true
            if r.location != NSNotFound, r.length > 0, rule.accept(ns, m), !carriedEmoticon {
                out.append(Span(range: r, reason: rule.reason, priority: rule.priority))
                location = end
            } else if rule.group > 0, r.location != NSNotFound, r.location > m.range.location {
                location = r.location
            } else {
                location = end
            }
        }
        return out
    }

    static let privateKeyRules: [NSRegularExpression] = [
        #"-----\s?BEGIN[ A-Z0-9_-]{0,100}PRIVATE KEY(?: BLOCK)?\s?-----"#,
        #"PuTTY-User-Key-File-\d"#,
        #"b3BlbnNzaC1rZXktdjE"#,
        #"AGE-SECRET-KEY-1[0-9A-Z]{20,}"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    static func matches(_ rules: [NSRegularExpression], _ text: String) -> Bool {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return rules.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    /// Token formats from about 20 providers. Case-sensitive, bounded so a
    /// fixed-length token inside a longer word does not match.
    static let providerPatterns: [String] = [
        #"sk-ant-(?:api|admin|oat|sid)\d{2}-[A-Za-z0-9_-]{20,}"#,              // Anthropic
        #"sk-(?:proj|svcacct|admin|None|service)-[A-Za-z0-9_-]{20,}"#,        // OpenAI project/service keys
        #"sk-[A-Za-z0-9_-]{32,}"#,                                          // OpenAI legacy, OpenRouter sk-or-v1-
        #"gh[pousr]_[A-Za-z0-9]{36,255}"#, #"github_pat_[A-Za-z0-9_]{22,255}"#, // GitHub
        #"gl(?:pat|dt|rt|ptt|ft|soat|cbt|imt|oas)-[A-Za-z0-9_-]{20,}"#,         // GitLab
        #"xox[abeoprs]-(?:\d+-)?[A-Za-z0-9-]{10,}"#, #"xapp-\d-[A-Za-z0-9-]{10,}"#, // Slack
        #"https://hooks\.slack\.com/(?:services|workflows|triggers)/[A-Za-z0-9/_-]{20,}"#,
        #"(?:sk|rk)_(?:test|live|prod)_[A-Za-z0-9]{10,}"#, #"whsec_[A-Za-z0-9+/=]{20,}"#, // Stripe
        #"(?:AKIA|ASIA|ABIA|ACCA|A3T[A-Z0-9])[A-Z0-9]{16}"#,                   // AWS access key id
        #"AIza[A-Za-z0-9_-]{35}"#, #"ya29\.[A-Za-z0-9_-]{20,}"#, #"GOCSPX-[A-Za-z0-9_-]{20,}"#, #"1//0[A-Za-z0-9_-]{30,}"#, // Google
        #"npm_[A-Za-z0-9]{36}"#,                                             // npm
        #"pypi-AgE[A-Za-z0-9_-]{50,}"#,                                      // PyPI
        #"hf_[A-Za-z0-9]{30,}"#,                                             // Hugging Face
        #"SG\.[A-Za-z0-9_-]{16,32}\.[A-Za-z0-9_-]{16,64}"#,                   // SendGrid
        #"SK[0-9a-fA-F]{32}"#,                                               // Twilio
        #"do[opr]_v1_[a-f0-9]{64}"#,                                         // DigitalOcean
        #"shp(?:at|ss|ca|pa)_[a-fA-F0-9]{32}"#,                              // Shopify
        #"\d{5,16}:A[A-Za-z0-9_-]{34}"#,                                     // Telegram bot
        #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"#,         // JWT
        #"[MNO][A-Za-z0-9_-]{23,27}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,40}"#, // Discord bot
        #"key-[0-9a-f]{32}"#, #"[0-9a-f]{32}-us\d{1,2}"#,                    // Mailgun, Mailchimp
        #"sq0(?:atp|csp|idp)-[A-Za-z0-9_-]{22,}"#, #"EAAA[A-Za-z0-9_-]{60}"#, // Square
        #"lin_(?:api|oauth)_[A-Za-z0-9]{40}"#,                               // Linear
        #"(?:secret|ntn)_[A-Za-z0-9]{40,}"#,                                 // Notion
        #"ATATT3[A-Za-z0-9_=-]{50,}"#,                                       // Atlassian
        #"dp\.(?:pt|st|sa|ct|scim|audit)\.[A-Za-z0-9]{40,}"#,               // Doppler
        #"dapi[a-f0-9]{32}(?:-\d)?"#,                                        // Databricks
        #"gsk_[A-Za-z0-9]{40,}"#,                                            // Groq
        #"r8_[A-Za-z0-9]{37}"#,                                              // Replicate
        #"ops_eyJ[A-Za-z0-9_-]{20,}"#,                                       // 1Password service account
        #"sbp_[a-f0-9]{40}"#,                                                // Supabase
        #"PMAK-[a-f0-9]{24}-[a-f0-9]{34}"#,                                  // Postman
    ]

    /// Values: a quoted string, or a run up to whitespace or a separator. An
    /// "&" ends the value only before the next `name=` of a query (secret
    /// fuzz: "pw:Ab1&Cd2@…" kept everything after the "&").
    static let value = #"("[^"\n]*"|'[^'\n]*'|[^\s,;&]+(?:&(?![A-Za-z_][A-Za-z0-9_.-]*=)[^\s,;&]*)*)"#
    static let proseStops = "on|in|at|under|behind|inside|taped|written|saved|stored|kept|somewhere|below|above|attached|the|a|an|same|still|not|no|also|too|here|there|wrong|incorrect|expired|changed|reset|required|missing|different|my|your|our|their|his|her|its"

    static let spanRules: [Rule] = {
        var r: [Rule] = providerPatterns.map { rule(.providerToken, #"(?<![A-Za-z0-9_])"# + $0 + #"(?![A-Za-z0-9_])"#, priority: 0) }
        // Connection strings: scheme://user:password@host, the password part.
        r.append(rule(.connectionString, #"\b[a-z][a-z0-9+.-]{1,30}://[^\s:/?#@]*:([^\s@/]+)@"#, group: 1, caseInsensitive: true, priority: 1))
        // Auth headers.
        r.append(rule(.authHeader, #"\b(?:proxy-)?authorization\s*[:=]\s*(?:basic|bearer|token|digest|negotiate|ntlm|hmac|aws4-hmac-sha256|sso-key)\s+([^\n]+)"#, group: 1, caseInsensitive: true, priority: 1))
        r.append(rule(.authHeader, #"\bbearer\s+([A-Za-z0-9._~+/=-]{8,})"#, group: 1, caseInsensitive: true, priority: 1) { ns, m in
            let v = ns.substring(with: m.range(at: 1))
            return v.count >= 20 || v.unicodeScalars.contains { !CharacterSet.letters.contains($0) }
        })
        r.append(rule(.authHeader, #"\b(?:x-api-key|x-auth-token|x-access-token|api-key|x-goog-api-key|private-token|ocp-apim-subscription-key)\s*:\s*([^\n]+)"#, group: 1, caseInsensitive: true, priority: 1))
        r.append(rule(.authHeader, #"\b(?:set-)?cookie\s*:\s*([^\n]*=[^\n]*)"#, group: 1, caseInsensitive: true, priority: 1))
        // CLI flags.
        r.append(rule(.cliSecretFlag, #"(?<![\w-])--?(?:password|passwd|passphrase|pass|pwd|token|api-?key|api_key|secret|client-secret|auth-token|access-token|key-password|keypass|storepass|otp)(?:=|\s+)"# + value, group: 1, caseInsensitive: true, priority: 2))
        r.append(rule(.cliSecretFlag, #"(?<![\w-])-pass(?:in|out)?\s+(\S+)"#, group: 1, priority: 2))
        r.append(rule(.cliSecretFlag, #"(?<![\w-])(?:mysql|mysqldump|mysqladmin|mariadb|sshpass)\b[^\n]*?(?<!\S)-p(\S+)"#, group: 1, priority: 2))
        r.append(rule(.cliSecretFlag, #"(?<![\w-])redis-cli\b[^\n]*?(?<!\S)-a\s+(\S+)"#, group: 1, priority: 2))
        r.append(rule(.cliSecretFlag, #"(?<![\w-])(?:-u|--user|--proxy-user)\s+["']?[^\s:"']+:([^\s"']+)"#, group: 1, priority: 2))
        // KEY=value and "password: x" assignments (the value only).
        r.append(rule(.assignment, #"(?<![A-Za-z0-9_])(["']?)([A-Za-z][A-Za-z0-9_.-]{0,63})\1\s*(:=|=>|=|:)\s*"# + value, group: 4, priority: 3) { ns, m in
            if narrativeSigEmoticon(ns, m) { return false }
            return assignmentIsSecret(name: ns.substring(with: m.range(at: 2)), separator: ns.substring(with: m.range(at: 3)),
                                      value: ns.substring(with: m.range(at: 4)), after: ns.substring(from: m.range.location + m.range.length))
        })
        // Password labels in prose: "the wifi password is hunter2", "my pin is 4921".
        // The rest of the sentence: a passphrase is several words ("correct
        // horse battery staple").
        r.append(rule(.passwordLabel, #"\b(?:password|passphrase|passcode|passwd|pwd|pw)(?:\s+for\s+\S+(?:\s+\S+)?)?\s+(?:is|was)\s*:?\s+(?!(?:"# + proseStops + #")\b)([^\n]+?)(?=[.!?;,](?:\s|$)|\n|$)"#, group: 1, caseInsensitive: true, priority: 2))
        r.append(rule(.passwordLabel, #"\b(?:pins?|pin code|passcode|(?:door|gate|alarm|safe|lock|garage|wifi|wi-fi|voicemail|atm)\s*(?:code|pin))\b(?:\s+(?:is|was|=))?\W{0,3}(\d{3,})"#, group: 1, caseInsensitive: true, priority: 2))
        // Card extras: an expiry or a CVV next to card words.
        r.append(rule(.paymentCard, #"\b(?:cvv2?|cvc2?|csc|cid|card security code)\b(?:\s+(?:is|was))?\W{0,3}(\d{3,4})\b"#, group: 1, caseInsensitive: true, priority: 3))
        r.append(rule(.paymentCard, #"\b(?:exp(?:iry|iration|ires)?|valid thru|good thru|expiration date)\b\W{0,3}(\d{1,2}\s?/\s?\d{2,4})\b"#, group: 1, caseInsensitive: true, priority: 3))
        r.append(rule(.paymentCard, #"\bcard\b[^\n]{0,40}?(?<![\d/])(\d{2}\s?/\s?\d{2}(?:\d{2})?)(?![\d/])"#, group: 1, caseInsensitive: true, priority: 3))
        // A code-style secret name, a space and a long value, with no "=":
        // "aws_secret_access_key wJalr…".
        r.append(rule(.assignment, #"(?<![A-Za-z0-9_])([A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)+)[ \t]+(\S{16,})"#, group: 2, priority: 3) { ns, m in
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            return ["secret", "token", "password", "passwd", "api_key", "apikey", "access_key", "private_key", "credential"].contains(where: name.contains)
        })
        // A key prefix is a secret by itself: a key cut by a unit split
        // ("sk-ant-api03-PtY"), or typed in chunks with spaces between them.
        r.append(rule(.providerToken, #"(?<![A-Za-z0-9_])(?:sk-ant-|sk-(?:proj|svcacct|admin|or-v1)-|github_pat_|glpat-|(?:sk|rk)_(?:live|test)_|whsec_|pypi-AgE|gh[pousr]_(?=[A-Za-z0-9]{4})|xox[abeoprs]-(?=\d)|AIza(?=[A-Za-z0-9_-]{6}))[A-Za-z0-9_-]*(?:[ \t]+(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{4,}(?![^\s]))*"#, priority: 0))
        // Account recovery secrets in dashed groups: 1Password Secret Key,
        // Apple recovery key, product keys ("A3-BJ3J4W-J99IBA-…").
        r.append(rule(.recoveryCode, #"(?<![A-Za-z0-9-])[A-Za-z0-9]{1,8}(?:-[A-Za-z0-9]{4,8}){4,}(?![A-Za-z0-9-])"#, priority: 1) { ns, m in
            let t = ns.substring(with: m.range)
            return t.contains(where: \.isNumber) && t.contains(where: \.isLetter)
                && uuid.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) == nil
        })
        // GitHub recovery codes ("fb008-f86be").
        r.append(rule(.recoveryCode, #"(?<![\w-])[0-9a-f]{5}-[0-9a-f]{5}(?![\w-])"#, priority: 1) { ns, m in
            let t = ns.substring(with: m.range)
            return t.contains(where: \.isNumber) && t.contains(where: \.isLetter)
        })
        // App passwords (Google: four groups of four letters) after their label.
        r.append(rule(.recoveryCode, #"\b(?:app(?:lication)?[- ]?(?:specific[- ])?password)\b[^\n]{0,24}?\b([a-z]{4} ?[a-z]{4} ?[a-z]{4} ?[a-z]{4})\b"#, group: 1, caseInsensitive: true, priority: 1))
        // A wallet recovery phrase: a line of exactly 12, 15, 18, 21 or 24
        // short lowercase words and none of the little words prose needs.
        r.append(Rule(reason: .recoveryPhrase, regex: try! NSRegularExpression(pattern: #"^(?:[a-z]{3,8} ){11,23}[a-z]{3,8}$"#, options: [.anchorsMatchLines]), group: 0, priority: 1) { ns, m in
            let words = ns.substring(with: m.range).split(separator: " ").map(String.init)
            return [12, 15, 18, 21, 24].contains(words.count) && !words.contains(where: proseWords.contains)
        })
        // The same phrase after its label, with other words around it (review round 1:
        // "seed: abandon ability … accident" in a note was kept).
        r.append(rule(.recoveryPhrase, #"\b(?:seed(?: phrase| words)?|(?:secret )?recovery (?:phrase|words)|mnemonic(?: phrase)?|backup (?:phrase|words)|wallet words)\b\W{0,3}((?:[a-z]{3,8}[ ,]+){11,23}[a-z]{3,8})\b"#, group: 1, caseInsensitive: true, priority: 1) { ns, m in
            !ns.substring(with: m.range(at: 1)).lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).contains(where: { proseWords.contains(String($0)) })
        })
        // Passwords Apple's password manager makes: three groups of six joined by dashes,
        // with a digit and both cases ("vimxy4-joqqep-Wyxfak").
        r.append(rule(.highEntropy, #"(?<![A-Za-z0-9_-])[A-Za-z0-9]{6}-[A-Za-z0-9]{6}-[A-Za-z0-9]{6}(?![A-Za-z0-9_-])"#, priority: 1) { ns, m in
            let t = ns.substring(with: m.range)
            return t.contains(where: \.isNumber) && t.contains(where: \.isUppercase) && t.contains(where: \.isLowercase)
        })
        return r
    }()
    /// Words ordinary sentences use that are not in the BIP39 word list.
    static let proseWords: Set<String> = ["the", "and", "for", "that", "this", "with", "you", "your", "are", "was", "were", "but", "not", "have", "has", "had",
                                          "from", "they", "them", "their", "there", "then", "than", "what", "when", "where", "which", "who", "would", "could",
                                          "should", "our", "his", "her", "its", "into", "been", "does", "did"]

    /// Name words that make `name = value` a secret. Substrings are
    /// distinctive ("PGPASSWORD", "GITHUB_TOKEN"); components must be whole
    /// parts of the name ("api_key", "apiKey", "auth"), so "turkey",
    /// "monkey" and "author" are not names of secrets.
    static let secretSubstrings = ["password", "passwd", "passphrase", "secret", "token", "credential", "apikey", "privatekey", "accesskey", "authorization", "signature", "sessionid", "cookie"]
    static let secretComponents: Set<String> = ["key", "auth", "pass", "pwd", "pw", "pin", "otp", "sig", "sas", "dsn", "salt"]
    static let strongNames = ["password", "passwd", "passphrase", "pwd", "pw", "pass", "secret", "pin", "otp", "contraseña", "passwort", "kennwort"]
    static func nameComponents(_ name: String) -> [String] {
        var parts: [String] = [], cur = ""
        var prevLower = false
        for ch in name {
            if ch == "_" || ch == "." || ch == "-" { if !cur.isEmpty { parts.append(cur) }; cur = ""; prevLower = false; continue }
            if ch.isUppercase && prevLower { parts.append(cur); cur = "" }
            cur.append(ch); prevLower = ch.isLowercase || ch.isNumber
        }
        if !cur.isEmpty { parts.append(cur) }
        return parts.map { $0.lowercased() }
    }
    static let typeNames: Set<String> = ["String", "Substring", "Int", "Bool", "Data", "Double", "Float", "URL", "Any", "AnyObject", "Character", "UUID", "Date",
                                         "str", "string", "bytes", "number", "boolean", "int", "char", "bool", "any", "unknown", "object",
                                         "SecretStr", "SecretString", "SecureString", "Password", "Secret", "Token", "Key", "SymmetricKey", "Credential", "Credentials"]
    static let codeLiterals: Set<String> = ["nil", "null", "none", "true", "false", "undefined", "self", "this", "nil;", "null;", "none,", "true;", "false;"]
    static func plainWord(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0.isLetter && $0.isLowercase } }
    /// The colon in a complete emoticon can follow ordinary prose "sig".
    /// Never exempts a strong label, quoted/code assignment, attached value,
    /// or anything beyond this finite set of short complete emoticons.
    static func narrativeSigEmoticon(_ text: NSString, _ match: NSTextCheckingResult, priorPrefix: String? = nil) -> Bool {
        guard text.substring(with: match.range(at: 2)) == "sig",
              match.range(at: 1).length == 0,
              text.substring(with: match.range(at: 3)) == ":",
              match.range(at: 4).location == match.range(at: 3).location + match.range(at: 3).length,
              ["(", "-(", ")", "-)", "/", "\\", "|", "'(", "["].contains(text.substring(with: match.range(at: 4))) else { return false }
        let nameEnd = match.range(at: 2).location + match.range(at: 2).length
        guard match.range(at: 3).location > nameEnd else { return false }
        let local = text.substring(to: match.range.location)
        // A new line starts its own narrative; prior parts never supply its subject.
        let prefix = local.contains("\n") ? (local.components(separatedBy: "\n").last ?? "") : (priorPrefix ?? "") + local
        let words = prefix.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 2, let first = words.first,
              ["i", "we", "you", "he", "she", "they"].contains(first.lowercased()) else { return false }
        return prefix.unicodeScalars.allSatisfy {
            CharacterSet.letters.contains($0) || CharacterSet.whitespaces.contains($0) || $0 == "'" || $0 == "\u{2019}"
        }
    }
    static func assignmentIsSecret(name: String, separator: String, value rawValue: String, after: String) -> Bool {
        let lower = name.lowercased(), parts = nameComponents(name)
        guard secretSubstrings.contains(where: lower.contains) || parts.contains(where: secretComponents.contains) else { return false }
        var v = rawValue, quoted = false
        if v.count >= 2, let f = v.first, f == "\"" || f == "'", v.last == f { v = String(v.dropFirst().dropLast()); quoted = true }
        // "a == b", "x => y" are comparisons and arrows, not values.
        guard !v.isEmpty, v != marker, quoted || !(v.hasPrefix("=") || v.hasPrefix(">")) else { return false }
        let strong = strongNames.contains(lower) || strongNames.contains(where: { parts.last == $0 }) || lower.contains("password") || lower.contains("secret")
        if separator != ":" {
            // .env and shell (FOO_TOKEN=…) and string literals are values.
            if quoted || name == name.uppercased() { return true }
            // Code that names another variable or a call is not a value:
            // "let tokenCount = tokens.count", "password = form.password".
            if codeLiterals.contains(v.lowercased()) { return false }
            if v.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*|\[[^\]]*\]|\(.*\))+[;,)]?$"#, options: .regularExpression) != nil { return false }
            if !strong, v.range(of: #"^[A-Za-z_][A-Za-z_]*[;,)]?$"#, options: .regularExpression) != nil { return false }
            return true
        }
        // A type annotation is code, not a value: "password: String)".
        let bare = v.trimmingCharacters(in: CharacterSet(charactersIn: "?!),;{}[]|"))
        if typeNames.contains(bare) { return false }
        let nextWord = after.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        if strong {
            // "Password: on the fridge", "secret: always salt the water" are prose.
            return !(plainWord(v) && plainWord(nextWord.trimmingCharacters(in: .punctuationCharacters)) && !after.hasPrefix("\n"))
        }
        // "Key: ship Friday" is prose; "Token: 9f8e…" is not.
        return v.count >= 16 || v.unicodeScalars.contains { !CharacterSet.letters.contains($0) } || v.dropFirst().contains { $0.isUppercase }
    }

    // MARK: - Password labels in any form (review round 1)

    /// A word that names a password, or the account or network it opens,
    /// right before it: "pw Fluffy123", "Password - Summer2024!", "wifi pw …",
    /// "home wifi: Blue42Sky99", "login sam hunter22", after any other words
    /// ("Bank login: password: …"). Whole words only: "passwords", "bypass"
    /// and "passwordless" are not labels, and neither is a part of a link,
    /// path or address ("/login?next=…", "pw.example.com").
    static let credentialLabel = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_/.@#?&-])(?:password|passwd|passphrase|passcode|pwd|pw|pass|contraseña|passwort|kennwort|mot de passe|log-?in|log in|sign-?in|sign in|creds|credentials|wi-?fi)(?=$|[\s:=,;!)"'\]>-])"#, options: [.caseInsensitive])
    /// The same labels after the password: "Fluffy123 is my password",
    /// "Blue42Sky99 is the wifi password".
    static let labelAfter = try! NSRegularExpression(pattern: #"(?<!\S)(\S+)[ \t]+(?:is|was|=)[ \t]+(?:(?:my|the|our|your|his|her|their|a|an|new|old|current)[ \t]+){0,2}(?:[\p{L}-]+[ \t]+){0,2}?(?:password|passwd|passphrase|passcode|pwd|pw|pass)(?![\p{L}\p{N}_])"#, options: [.caseInsensitive])
    /// Tokens between a label and its value that are not words: "Password - x", "login: sam / x".
    static let labelFiller: Set<String> = ["-", "–", "—", ":", "=", "/", "|", ">", "->", "=>", "is", "was", "is:", "was:"]
    static let clockOrVersion = try! NSRegularExpression(pattern: #"^(?:\d{1,2}[:.]\d{2}(?:am|pm)?|v?\d+(?:\.\d+)+[a-z]?)$"#, options: [.caseInsensitive])
    /// A word that could be a password someone made up: 6-64 characters,
    /// letters and at least one digit or password symbol, and not a link,
    /// path, address, UUID, time or version. "Fluffy123", "Summer2024!",
    /// "hunter22", "P@ssword"; not "manager", "2026", "v2" or "10:30am".
    static func passwordLike(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: edge)
        guard (6...64).contains(t.count), !t.contains(marker), !exempt(t), t.contains(where: \.isLetter),
              t.contains(where: \.isNumber) || t.unicodeScalars.contains(where: { passwordSymbols.contains($0) }) else { return false }
        return clockOrVersion.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) == nil
    }
    /// The token's range without the punctuation around it ("!" and "?" stay: passwords use them).
    static func looseRange(_ ns: NSString, _ token: NSRange) -> NSRange? {
        let raw = ns.substring(with: token), loose = raw.trimmingCharacters(in: looseEdge)
        guard !loose.isEmpty, let inner = raw.range(of: loose) else { return nil }
        let r = NSRange(inner, in: raw)
        return NSRange(location: token.location + r.location, length: r.length)
    }
    /// After a label, the first password-like word among the next three words
    /// (on its line and the next: "password⏎Fluffy123") is withheld; before
    /// "is my password", the word before it. A word that is not password-like
    /// is prose and is kept: "password reset link sent", "login page
    /// redesign", "the wifi is down". The weakest reason (priority 5): a
    /// token another rule also withholds keeps that rule's reason.
    static func labelSpans(_ text: String) -> [Span] {
        let ns = text as NSString, all = NSRange(location: 0, length: ns.length)
        func lineEnd(_ from: Int) -> Int {
            let newline = ns.range(of: "\n", options: [], range: NSRange(location: from, length: ns.length - from)).location
            return newline == NSNotFound ? ns.length : newline
        }
        var out: [Span] = []
        for label in credentialLabel.matches(in: text, range: all) {
            let start = label.range.location + label.range.length
            // The label's line and the next one: "password⏎Fluffy123", "login sam⏎hunter22".
            var end = lineEnd(start)
            if end < ns.length { end = lineEnd(end + 1) }
            var words = 0
            for token in tokenRegex.matches(in: text, range: NSRange(location: start, length: end - start)) {
                let raw = ns.substring(with: token.range)
                if labelFiller.contains(raw.lowercased()) { continue }
                if passwordLike(raw), let r = looseRange(ns, token.range) {
                    out.append(Span(range: r, reason: .passwordLabel, priority: 5)); break
                }
                words += 1
                if words == 3 || raw.hasSuffix(".") || raw.hasSuffix(";") { break }
            }
        }
        for m in labelAfter.matches(in: text, range: all) {
            let value = m.range(at: 1)
            guard value.location != NSNotFound, passwordLike(ns.substring(with: value)), let r = looseRange(ns, value) else { continue }
            out.append(Span(range: r, reason: .passwordLabel, priority: 5))
        }
        return out
    }

    // MARK: - Numbers: cards, long numbers, SSNs, one-time codes

    /// Not glued to letters: "a716-446655440000" inside a UUID is not a card.
    /// Not followed by "/": "4111… 08/27" is a card and then an expiry, not
    /// an 18-digit number that fails Luhn.
    static let cardRegex = try! NSRegularExpression(pattern: #"(?<![\dA-Za-z_-])(?:\d[ -]?){12,18}\d(?![\dA-Za-z_/])"#)
    /// Cards written with dots ("4111.1111.1111.1111").
    static let dottedCard = try! NSRegularExpression(pattern: #"(?<![\dA-Za-z_.-])\d{4}(?:\.\d{4}){3}(?:\.\d{1,3})?(?![\dA-Za-z_]|\.\d)"#)
    /// A card split over two lines; counts only when it passes Luhn with an issuer prefix.
    static let splitCard = try! NSRegularExpression(pattern: #"(?<![\dA-Za-z_-])(?:\d[ -]?){3,17}\d\n(?:\d[ -]?){0,15}\d(?![\dA-Za-z_])"#)
    /// Right after a card: an expiry and a CVV with no label ("4111… 08/27 123").
    static let cardTail = try! NSRegularExpression(pattern: #"^(?:[ ]?/[ ]?\d{2,4})?(?:[ ,]+\d{1,2}[ ]?/[ ]?\d{2,4})?(?:[ ,]+\d{3,4})?(?!\d)"#)
    static let longDigits = try! NSRegularExpression(pattern: #"\d{20,}"#)
    static let ssnRegex = try! NSRegularExpression(pattern: #"(?<![\d.-])\d{3}([- .])\d{2}\1\d{4}(?![\d-]|\.\d)"#)
    static let nineDigits = try! NSRegularExpression(pattern: #"(?<![\d-])\d{9}(?![\d-])"#)
    static let ssnContext = try! NSRegularExpression(pattern: #"\b(?:ssn|ssns|social|social security|tax id|tin|itin)\b"#, options: [.caseInsensitive])
    static let otpToken = try! NSRegularExpression(pattern: #"(?<![\w.,/:-])(?:[A-Z]-)?\d{4,8}(?![\w/-]|[.,:]\d)|(?<![\w.,/:-])\d{3}[- ]\d{3}(?![\w/-]|[.,:]\d)"#)
    static let otpContext = try! NSRegularExpression(pattern: #"\b(?:codes?|otp|2fa|mfa|verification|verify|passcode|pin|one[- ]?time|security code|sign[- ]?in|log[- ]?in)\b"#, options: [.caseInsensitive])
    /// "code" after these words is not a secret code.
    static let notSecretCode = try! NSRegularExpression(pattern: #"\b(?:zip|area|postal|post|country|status|error|exit|http|response|promo|discount|coupon|dress|source|qr|bar|morse|return|color|colour|tax|station|airport|product|sku|course|class|reference|ref|tracking|order|invoice|room)\s*$"#, options: [.caseInsensitive])

    static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (i, d) in digits.reversed().enumerated() { if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d } }
        return sum % 10 == 0
    }
    /// Luhn plus an issuer prefix only name the reason; every 13-19 digit
    /// run is withheld either way.
    public static func looksLikeCard(_ digits: String) -> Bool {
        let d = digits.compactMap(\.wholeNumberValue)
        guard (13...19).contains(d.count), let first = d.first, (2...6).contains(first) else { return false }
        return luhn(d)
    }

    static func numberSpans(_ text: String) -> [Span] {
        let ns = text as NSString, all = NSRange(location: 0, length: ns.length)
        var out: [Span] = []
        for m in cardRegex.matches(in: text, range: all) {
            out.append(Span(range: m.range, reason: looksLikeCard(ns.substring(with: m.range)) ? .paymentCard : .longNumber, priority: 1))
        }
        for m in dottedCard.matches(in: text, range: all) {
            out.append(Span(range: m.range, reason: looksLikeCard(ns.substring(with: m.range)) ? .paymentCard : .longNumber, priority: 1))
        }
        for m in splitCard.matches(in: text, range: all) where looksLikeCard(ns.substring(with: m.range)) {
            out.append(Span(range: m.range, reason: .paymentCard, priority: 1))
        }
        out += cardRuns(text)
        for m in longDigits.matches(in: text, range: all) { out.append(Span(range: m.range, reason: .longNumber, priority: 1)) }
        for m in ssnRegex.matches(in: text, range: all) { out.append(Span(range: m.range, reason: .ssn, priority: 1)) }
        let ssnWords = ssnContext.matches(in: text, range: all).map(\.range)
        for m in nineDigits.matches(in: text, range: all) where ssnWords.contains(where: { near($0, m.range, within: 24) }) {
            out.append(Span(range: m.range, reason: .ssn, priority: 1))
        }
        let codeWords = otpContext.matches(in: text, range: all).map(\.range).filter { r in
            let word = ns.substring(with: r).lowercased()
            guard word.hasPrefix("code") else { return true }
            return notSecretCode.firstMatch(in: ns.substring(to: r.location), range: NSRange(location: 0, length: r.location)) == nil
        }
        for m in otpToken.matches(in: text, range: all) {
            let token = ns.substring(with: m.range)
            let digits = token.filter(\.isNumber)
            // A year is a code only right after its label ("pin 1987").
            let year = digits.count == 4 && token.count == 4 && (1900...2099).contains(Int(digits) ?? 0)
            let hit = codeWords.contains { w in
                year ? (w.location + w.length <= m.range.location && m.range.location - (w.location + w.length) <= 12) : near(w, m.range, within: 40)
            }
            if hit { out.append(Span(range: m.range, reason: .oneTimeCode, priority: 3)) }
        }
        return out
    }
    /// Digit groups joined by one to four characters that are neither letters
    /// nor digits (plus a line break, which doesn't count), wherever they sit:
    /// glued to a word ("visa4111…"), slashed ("4111/1111/…"), an expiry glued
    /// on ("4111…/0827"), split over two lines ("4111.1111.\n1111.1111"), or
    /// joined by commas, "+", ":", "|" or " -- " (review round 1: the
    /// separators were listed one shape at a time, so every other one was
    /// kept). Any stretch of whole groups holding 13-19 digits that passes
    /// Luhn with an issuer prefix is withheld as a card (`cardGrouping` keeps
    /// number lists). The Luhn test keeps dates and version numbers.
    static let digitRun = try! NSRegularExpression(pattern: #"\d+(?:(?:[^\p{L}\p{N}\n]{1,4}|[^\p{L}\p{N}\n]{0,4}\n[^\p{L}\p{N}\n]{0,4})\d+)*"#)
    static let digitGroup = try! NSRegularExpression(pattern: #"\d+"#)
    /// Separators a card number is written with anyway, and number lists rarely are.
    static let plainSeparator = try! NSRegularExpression(pattern: #"^[ ./_\n-]{1,3}$"#)
    /// A stretch joined only by `plainSeparator` counts on Luhn and prefix
    /// alone. Any other separator ("," "+" ":" "|" " -- ") counts only in a
    /// card's own grouping (fours, up to 19 digits; Amex 4-6-5; Diners 4-6-4)
    /// that isn't four years, so lists ("45, 67, 89, …", "20:30, 21:45, …",
    /// "2023, 2024, 2025, 2026", "555-123-4567, 555-987-6543") are kept.
    static func cardGrouping(_ ns: NSString, _ groups: ArraySlice<NSRange>) -> Bool {
        let separators = zip(groups, groups.dropFirst()).map { a, b in
            ns.substring(with: NSRange(location: a.location + a.length, length: b.location - a.location - a.length))
        }
        if separators.allSatisfy({ plainSeparator.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }) { return true }
        // A line break alone inside a group is a wrap, not a separator ("3782,822⏎463,10005").
        var lengths: [Int] = []
        for (k, group) in groups.enumerated() {
            if k > 0, separators[k - 1] == "\n", let last = lengths.popLast() { lengths.append(last + group.length) } else { lengths.append(group.length) }
        }
        let fours = lengths.count >= 4 && lengths.dropLast().allSatisfy { $0 == 4 } && (1...4).contains(lengths.last!)
        guard fours || lengths == [4, 6, 5] || lengths == [4, 6, 4] else { return false }
        return !groups.allSatisfy { $0.length == 4 && (1900...2099).contains(Int(ns.substring(with: $0)) ?? 0) }
    }
    static func cardRuns(_ text: String) -> [Span] {
        let ns = text as NSString
        var out: [Span] = []
        for run in digitRun.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let groups = digitGroup.matches(in: text, range: run.range).map(\.range)
            var i = 0
            while i < groups.count {
                var digits = 0, found: (range: NSRange, end: Int)?
                for j in i..<groups.count {
                    digits += groups[j].length
                    if digits > 19 { break }
                    let range = NSRange(location: groups[i].location, length: groups[j].location + groups[j].length - groups[i].location)
                    if digits >= 13, looksLikeCard(ns.substring(with: range)), cardGrouping(ns, groups[i...j]) { found = (range, j) }
                }
                if let found { out.append(Span(range: found.range, reason: .paymentCard, priority: 1)); i = found.end + 1 } else { i += 1 }
            }
        }
        return out
    }
    /// The expiry and CVV typed right after a card (or a long number), with no label.
    static func cardTails(_ text: String, after spans: [Span]) -> [Span] {
        let ns = text as NSString
        var out: [Span] = []
        for span in spans where span.reason == .paymentCard || span.reason == .longNumber {
            let start = span.range.location + span.range.length
            guard start < ns.length else { continue }
            let rest = NSRange(location: start, length: min(24, ns.length - start))
            if let m = cardTail.firstMatch(in: text, options: [.anchored], range: rest), m.range.length > 0,
               ns.substring(with: m.range).contains(where: \.isNumber) {
                out.append(Span(range: m.range, reason: .paymentCard, priority: 1))
            }
        }
        return out
    }
    static func near(_ a: NSRange, _ b: NSRange, within n: Int) -> Bool {
        let gap = a.location >= b.location + b.length ? a.location - (b.location + b.length) : b.location - (a.location + a.length)
        return gap <= n
    }
    /// A unit that is just a number of 4-12 digits (with optional spaces or
    /// dashes, or a "G-" style prefix) is a code or a PIN: dropped. A complete\n    /// formatted phone is the narrow exception; labels and secret rules still run.
    static func loneNumber(_ text: String) -> Bool {
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ContactShape.phone(v), v.range(of: #"^(?:[A-Z]-)?\d[\d -]*\d$"#, options: .regularExpression) != nil else { return false }
        return (4...12).contains(v.filter(\.isNumber).count)
    }

    /// A unit that is only an app password: four groups of four lowercase
    /// letters where a group has no vowel ("bgcg ofdk tbda serd"). Four
    /// ordinary four-letter words are kept.
    static func loneAppPassword(_ text: String) -> Bool {
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.range(of: #"^[a-z]{4}( ?)[a-z]{4}\1[a-z]{4}\1[a-z]{4}$"#, options: .regularExpression) != nil else { return false }
        let letters = Array(v.filter { $0 != " " })
        let groups = stride(from: 0, to: 16, by: 4).map { String(letters[$0..<$0 + 4]) }
        return groups.contains { !$0.contains(where: "aeiouy".contains) }
    }

    // MARK: - High-entropy tokens

    static let tokenRegex = try! NSRegularExpression(pattern: #"\S+"#)
    static let edge = CharacterSet(charactersIn: "\"'`()[]{}<>.,;:!?\u{201C}\u{201D}\u{2018}\u{2019}\u{00AB}\u{00BB}")
    /// `edge` without "!" and "?", which passwords use.
    static let looseEdge = CharacterSet(charactersIn: "\"'`()[]{}<>.,;:\u{201C}\u{201D}\u{2018}\u{2019}\u{00AB}\u{00BB}")
    /// The rest of a token the capture side withheld before a soft line break:
    /// three kinds of character, or letters and digits over 8 characters.
    static func continuation(_ t: String) -> Bool {
        let v = t.trimmingCharacters(in: edge)
        guard v.count >= 6, !v.contains(marker) else { return false }
        let kinds = [v.contains(where: \.isLowercase), v.contains(where: \.isUppercase), v.contains(where: \.isNumber),
                     v.unicodeScalars.contains { !CharacterSet.alphanumerics.contains($0) }].filter { $0 }.count
        return kinds >= 3 || (kinds == 2 && v.contains(where: \.isNumber) && v.count >= 8)
    }
    static let uuid = try! NSRegularExpression(pattern: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#)

    /// A token typed across a soft line break ("Ab1!Cd2@\nEf3#Gh4$"), judged whole.
    static let wrappedToken = try! NSRegularExpression(pattern: #"\S+(?:\n\S+)+"#)
    static func tokenSpans(_ text: String, avoiding taken: [Span]) -> [Span] {
        let ns = text as NSString
        var out: [Span] = []
        for m in wrappedToken.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard !taken.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) else { continue }
            let lines = ns.substring(with: m.range).components(separatedBy: "\n")
            // Each neighbouring pair of lines is judged as one token (secret fuzz).
            var start = m.range.location
            for k in 0..<(lines.count - 1) {
                let a = (lines[k] as NSString).length, b = (lines[k + 1] as NSString).length
                let joined = (lines[k] + lines[k + 1]).trimmingCharacters(in: edge)
                if lines[k] != marker, lines[k + 1] != marker, !exempt(joined), symbolPassword(joined) || highEntropy(joined) {
                    out.append(Span(range: NSRange(location: start, length: a + 1 + b), reason: .highEntropy, priority: 4))
                } else if lines[k].hasSuffix(marker), continuation(lines[k + 1]) {
                    // The capture side withheld the first part: the rest after the line break goes too.
                    out.append(Span(range: NSRange(location: start + a + 1, length: b), reason: .highEntropy, priority: 4))
                } else if lines[k + 1].hasPrefix(marker), continuation(lines[k]) {
                    out.append(Span(range: NSRange(location: start, length: a), reason: .highEntropy, priority: 4))
                }
                start += a + 1
            }
        }
        for m in tokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard !taken.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) else { continue }
            let raw = ns.substring(with: m.range)
            let trimmed = raw.trimmingCharacters(in: edge)
            // A generated password may start or end with "!" or "?", which trimming
            // takes for punctuation ("!v44hf7raPHEVcL="): judged with them too (secret fuzz).
            let loose = raw.trimmingCharacters(in: looseEdge)
            if loose != trimmed, symbolPassword(loose), let inner = raw.range(of: loose) {
                let r = NSRange(inner, in: raw)
                out.append(Span(range: NSRange(location: m.range.location + r.location, length: r.length), reason: .highEntropy, priority: 4)); continue
            }
            // Review round 1: the capture side's opaque rule, so a short made-up password with
            // all four kinds of character ("Tr0ub4dor&3", "Xk9.mP2,qL7:vR4!") is withheld here too.
            if fourKinds(trimmed), !exempt(trimmed), let inner = raw.range(of: trimmed) {
                let r = NSRange(inner, in: raw)
                out.append(Span(range: NSRange(location: m.range.location + r.location, length: r.length), reason: .highEntropy, priority: 4)); continue
            }
            guard trimmed.count >= 12, trimmed != marker, let inner = raw.range(of: trimmed) else { continue }
            let r = NSRange(inner, in: raw)
            let range = NSRange(location: m.range.location + r.location, length: r.length)
            if exempt(trimmed) { continue }
            if symbolPassword(trimmed) { out.append(Span(range: range, reason: .highEntropy, priority: 4)); continue }
            // A password glued to a label ("note:Ab1!…", "pw=Ab1!…"): judged after the label (secret fuzz).
            if trimmed.split(whereSeparator: { $0 == ":" || $0 == "=" }).count > 1,
               trimmed.split(whereSeparator: { $0 == ":" || $0 == "=" }).contains(where: { symbolPassword(String($0)) }) {
                out.append(Span(range: range, reason: .highEntropy, priority: 4)); continue
            }
            guard trimmed.count >= 20 else { continue }
            // Tokens joined by dots or colons ("a.b.c") are judged part by part.
            let parts = trimmed.split(whereSeparator: { ".:@".contains($0) }).map(String.init)
            if parts.contains(where: highEntropy) { out.append(Span(range: range, reason: .highEntropy, priority: 4)) }
        }
        return out
    }
    static func exempt(_ t: String) -> Bool {
        t.contains("://") || t.hasPrefix("/") || t.hasPrefix("~/") || t.hasPrefix("./") || t.hasPrefix("../") ||
            ContactShape.email(t) ||
            uuid.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil
    }
    static func shannon(_ s: String) -> Double {
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0) { let p = Double($1) / n; return $0 - p * log2(p) }
    }
    /// 32+ hex characters with at least 3 bits per character (hashes and git
    /// SHAs are withheld: accepted), or 20+ base64-like characters that look
    /// random: letters and digits, frequent switches between lower case,
    /// upper case and digits, and entropy close to the maximum for the
    /// length. (A flat 4.5 bits is out of reach below 23 characters, since
    /// n characters carry at most log2(n) bits each.)
    public static func highEntropy(_ t: String) -> Bool {
        let n = t.count
        guard (20...512).contains(n) else { return false }
        if n >= 32, t.allSatisfy(\.isHexDigit) {
            return t.contains(where: \.isNumber) && t.contains(where: \.isLetter) && shannon(t) >= 3.0
        }
        guard t.range(of: #"^[A-Za-z0-9+/=_-]+$"#, options: .regularExpression) != nil,
              t.contains(where: \.isNumber), t.contains(where: \.isLetter) else { return false }
        var transitions = 0, last = -1, counted = 0
        for c in t {
            let k = c.isNumber ? 0 : c.isUppercase ? 1 : c.isLowercase ? 2 : -1
            guard k >= 0 else { continue }
            if last >= 0 { counted += 1; if k != last { transitions += 1 } }
            last = k
        }
        guard counted > 0, Double(transitions) / Double(counted) >= 0.4 else { return false }
        return shannon(t) >= min(4.5, 0.8 * log2(Double(n)))
    }

    /// 8-64 characters with a lowercase and an uppercase letter, a digit and
    /// a password symbol or ",", ":" or ";" inside: the capture side's
    /// `TextClassifier.opaqueToken`, less file names and versions ("_", "."
    /// and "-" don't count: "IMG_20260924_123456.jpg", "Swift6.2").
    static let fourKindSymbols = passwordSymbols.union(CharacterSet(charactersIn: ",:;"))
    static func fourKinds(_ t: String) -> Bool {
        guard (8...64).contains(t.count), !t.contains(marker), !queryString(t) else { return false }
        var lower = false, upper = false, digit = false, other = false
        for u in t.unicodeScalars {
            switch u.value {
            case 0x61...0x7A: lower = true
            case 0x41...0x5A: upper = true
            default:
                if CharacterSet.decimalDigits.contains(u) { digit = true } else if fourKindSymbols.contains(u) { other = true }
            }
        }
        return lower && upper && digit && other
    }
    /// Symbols password generators use (not "-" or "_", which names and dates use).
    static let passwordSymbols = CharacterSet(charactersIn: "!@#$%^&*~+=?|")
    /// A generated password with symbols ("Us*d^MlH%UvTC&*#QCyEZDz%"): 12+
    /// printable characters, at least two password symbols, three kinds of
    /// character, frequent switches between kinds, and near-random spread.
    /// No brackets, quotes, slashes or sentence punctuation inside (code and prose).
    public static func symbolPassword(_ t: String) -> Bool {
        let n = t.count
        guard (12...128).contains(n), t.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }),
              t.rangeOfCharacter(from: CharacterSet(charactersIn: "()[]{}<>;,.:\"'`/\\")) == nil,
              t.unicodeScalars.filter({ passwordSymbols.contains($0) }).count >= 2,
              !queryString(t) else { return false }
        func kind(_ c: Character) -> Int { c.isNumber ? 0 : c.isUppercase ? 1 : c.isLowercase ? 2 : 3 }
        guard Set(t.map(kind)).count >= 3 else { return false }
        var transitions = 0, last = -1
        for c in t { let k = kind(c); if last >= 0, k != last { transitions += 1 }; last = k }
        guard Double(transitions) / Double(n - 1) >= 0.4 else { return false }
        return shannon(t) >= min(4.0, 0.8 * log2(Double(n)))
    }

    /// "user_id=4821&page=3": name=value pairs joined by "&" are a link's
    /// query, not a password (secret values in them are caught by name).
    static func queryString(_ t: String) -> Bool {
        t.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]*=[^&=]*(&[A-Za-z_][A-Za-z0-9_.-]*=[^&=]*)*$"#, options: .regularExpression) != nil
    }

    // MARK: - Merging

    static func merge(_ spans: [Span]) -> [Span] {
        var out: [Span] = []
        for s in spans.sorted(by: { $0.range.location < $1.range.location || ($0.range.location == $1.range.location && $0.priority < $1.priority) }) {
            if var last = out.last, s.range.location <= last.range.location + last.range.length {
                let end = max(last.range.location + last.range.length, s.range.location + s.range.length)
                if s.priority < last.priority { last.reason = s.reason; last.priority = s.priority }
                last.range.length = end - last.range.location
                out[out.count - 1] = last
            } else { out.append(s) }
        }
        return out
    }
}

// MARK: - Email subjects (email-1003)

/// email-1003 (owner decision 2026-10-03): DayDream keeps email subjects (webmail page titles, Mail's window titles, a
/// compose form's Subject). A subject is dropped whole, never partly kept, when the typed-words scrubber would withhold
/// anything in it (`scrub`: a one-time code next to its label, a card, a token, a password label), when `Privacy.secret`
/// flags it, or when it reads like one-time-code, password, sign-in, security, verification or bank mail
/// (`subjectRules`): "Your code is 123456", "Reset your password", "Sign-in attempt", "Verify your email",
/// "Your statement is ready". Codes only; nothing returned names the matched words.
extension TypedSecretScrubber {
    public enum SubjectReason: String, CaseIterable, Sendable {
        case secret, oneTimeCode, password, signIn, security, verification, bank
    }
    /// The subject rules, checked after the typed-words rules. Case-insensitive, whole words.
    static let subjectRules: [(SubjectReason, NSRegularExpression)] = ([
        (.oneTimeCode, #"\b(?:your|the|a|new)\s+(?:\w+\s+)?(?:code|pin|passcode|otp)\b"#),
        (.oneTimeCode, #"\b(?:verification|security|confirmation|sign[- ]?in|log[- ]?in|login|one[- ]?time|access|authentication|auth|2fa|mfa|otp|single[- ]?use|temporary)\s+(?:code|pin|passcode|password|number|link)s?\b"#),
        (.oneTimeCode, #"\bcode\s*(?:is|:)|\bis your (?:\w+\s+)?code\b|\bpasscode\b|\botp\b|\b2fa\b|\bmfa\b|\btwo[- ]?(?:factor|step)\b|\bmulti[- ]?factor\b"#),
        (.oneTimeCode, #"\b(?:magic|login|log[- ]?in|sign[- ]?in)\s+link\b"#),
        (.password, #"\bpass(?:word|phrase|key)s?\b|\bpasswd\b"#),
        (.signIn, #"\bsign(?:ed)?[- ]?(?:in|on)\b|\blog(?:ged)?[- ]?in\b|\blogin\b|\bnew (?:device|browser|location)\b"#),
        (.security, #"\bsecurity (?:alert|notice|notification|code|check|warning|update|key|question|info|information)s?\b|\bsuspicious\b|\bunusual (?:activity|sign|login|access|attempt)|\baccount (?:recovery|locked|lock|access|security|alert|compromised|suspended|verification)\b|\bunauthori[sz]ed\b|\bfraud\b"#),
        (.verification, #"\bverif(?:y|ied|ication)\b|\bconfirm (?:your|the|this|it'?s)\s+(?:email|e-mail|account|identity|address|sign|device|phone|number)\b|\bauthenticat"#),
        (.bank, #"\bbank(?:ing)?\b|\b(?:account|card|bank) statement\b|\bstatement (?:is )?(?:ready|available)\b|\byour statement\b|\b(?:card|account) ending\b|\bending in \d{2,4}\b|\b(?:transaction|purchase|payment|deposit|withdrawal|transfer|wire|charge) (?:alert|notice|received|confirmation|declined|made|posted|sent|approved)\b|\bdirect deposit\b|\boverdraft\b|\b(?:low|available|account) balance\b|\bwire transfer\b|\b1099\b|\bw-?2\b"#),
    ] as [(SubjectReason, String)]).map { ($0.0, try! NSRegularExpression(pattern: $0.1, options: [.caseInsensitive])) }

    /// Why a subject must not be kept, or nil when it may be.
    public static func sensitiveSubject(_ subject: String) -> SubjectReason? {
        let t = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        switch scrub(t) {
        case .drop: return .secret
        case .keep(_, let redactions) where !redactions.isEmpty: return redactions.contains(.oneTimeCode) ? .oneTimeCode : .secret
        default: break
        }
        if Privacy.secret(t) { return .secret }
        let ns = t as NSString, all = NSRange(location: 0, length: ns.length)
        for (reason, rule) in subjectRules where rule.firstMatch(in: t, range: all) != nil { return reason }
        // A bare 4-8 digit number anywhere in a short subject ("123456 is your Acme code" is caught above; "Acme: 482913").
        if t.count <= 80, t.range(of: #"(?<![\w.,/:-])\d{4,8}(?![\w/-]|[.,:]\d)"#, options: .regularExpression) != nil,
           t.range(of: #"(?<!\w)(?:19|20)\d{2}(?!\w)"#, options: .regularExpression) == nil { return .oneTimeCode }
        return nil
    }
}
