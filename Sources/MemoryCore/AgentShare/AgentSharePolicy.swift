import Foundation
import PrivacyPolicy

// agent-tools v2, WP-A (plan §3; owner decisions 10/04).
//
// The one share policy for AI apps, and the one function that turns stored typed text into agent text.
// - Typed words go to AI apps by default, with secrets redacted. The Settings switch turns them off; then every tool
//   omits typed actions (it does not describe them).
// - `shareable` is the only way typed text becomes agent text. The app's bridge applies it before any word leaves the
//   app (`MemoryStore.agentTypedText`), and `AssistantTypedText.shareable` forwards to it.
// - `statusLines()` is generated from the same value, so `status` can't drift from what is enforced.
// - Never a send state: `sendStateShown` is false, and `status` only says so.
//
// Pure: no store, no socket, no clock. Nothing here logs or prints typed text.

extension AgentSharePolicy {
    /// The policy as the running app states it (bridge op `policy`). No answer: typed words are off, "DayDream is closed".
    public static func current(bridge: AgentTypedSource) -> AgentSharePolicy { from(bridge.policy()) }

    /// One `policy` answer as a policy. Words are on only while the app answers, its setting is on and typing is unlocked.
    public static func from(_ answer: AgentBridgePolicy) -> AgentSharePolicy {
        guard answer.reachable else { return AgentSharePolicy(typedWords: false, typedWordsOff: .appClosed) }
        guard answer.typedWords else { return AgentSharePolicy(typedWords: false, typedWordsOff: .settingOff) }
        guard answer.vault == .ready else { return AgentSharePolicy(typedWords: false, typedWordsOff: .locked) }
        return AgentSharePolicy(typedWords: true)
    }

    /// The text of one typed unit an AI app may see, or nil to share nothing for it (typed words off, or nothing left
    /// once secrets are removed). Every redaction always runs: `redactions` is what `status` lists and can't weaken it.
    public func shareable(_ raw: String) -> String? {
        guard typedWords else { return nil }
        return AgentRedactor.redact(raw)
    }

    /// `shareable` for a stored row: a row from a secure field shares nothing (such rows are never stored either).
    public func shareable(_ raw: String, secure: Bool) -> String? {
        secure ? nil : shareable(raw)
    }

    /// The send-state line, said without the words an agent must never be told about a message ("was sent", "delivered").
    public static let sendStateLine = "Never shown: whether a message went out; DayDream can't tell."

    /// The `status` "shared" lines: what AI apps get of typed words, and that send states are never shown.
    public func statusLines() -> [String] {
        var lines = [typedWordsLine]
        if !sendStateShown { lines.append(Self.sendStateLine) }
        return lines
    }

    /// The first status line, also the end of the setup check's typing line (`assistantReadiness`).
    public var typedWordsLine: String {
        if typedWords {
            let minus = redactions.map(\.plain)
            return minus.isEmpty ? "Typed words: shared with AI apps you connect."
                : "Typed words: shared with AI apps you connect, minus " + minus.joined(separator: "; ") + "."
        }
        switch typedWordsOff ?? .appClosed {
        case .settingOff: return "Typed words: off (Settings › Connections)."
        case .appClosed: return "Typed words: unavailable while DayDream is closed."
        case .locked: return "Typed words: unavailable until typing is unlocked in DayDream."
        }
    }
}

extension AgentSharePolicy.Redaction {
    /// Plain words for `status`.
    public var plain: String {
        switch self {
        case .secureFields: return "passwords and secure fields"
        case .oneTimeCodes: return "one-time and 2FA codes"
        case .apiKeysAndTokens: return "API keys and tokens"
        case .privateKeys: return "private keys"
        case .cardNumbers: return "card numbers"
        case .governmentIDs: return "government ID and bank account numbers"
        case .urlCredentials: return "logins and query strings in web addresses"
        }
    }
}

/// The redaction passes behind `AgentSharePolicy.shareable`, in order:
/// 1. ID shapes the store-side scrubber doesn't know: IBAN (mod-97), UK National Insurance, an ID number after its
///    label; then web addresses lose their login part, query string and fragment;
/// 2. `TypedSecretScrubber` (private keys, provider tokens and JWTs, cards, SSNs, one-time codes, connection strings,
///    auth headers, password labels, high-entropy tokens), which may drop the whole unit;
/// 3. web addresses once more (the scrubber's markers can leave a login part behind);
/// 4. `name=value` pairs that carry a token outside a web address;
/// 5. a token pass with `Privacy.secret`, less the shapes ordinary writing uses;
/// 6. a 6- or 8-digit number in a unit of four words or fewer (a code read off a phone).
/// Idempotent: redacting a result again changes nothing.
enum AgentRedactor {
    /// Characters of one typed text an AI app gets.
    static let maxCharacters = 1600
    static let marker = TypedSecretScrubber.marker

    static func redact(_ raw: String) -> String? {
        var text = TypedSecretScrubber.normalized(raw)
        // Web addresses first, so a query string's secret takes only the query with it, not the whole address.
        text = webAddresses(idNumbers(text))
        guard let kept = TypedSecretScrubber.scrub(text).kept else { return nil }
        text = webAddresses(kept)
        text = queryPairs(text)
        text = tokens(text)
        text = shortCodes(text)
        // A unit that is only withheld markers says nothing.
        let rest = text.replacingOccurrences(of: marker, with: " ")
        guard rest.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
        if text.count > maxCharacters { text = String(text.prefix(maxCharacters - 1)) + "\u{2026}" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Helpers

    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
    static func whole(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
    /// Replaces capture `group` (0: the whole match) of every match `accept` takes with what `with` returns.
    static func replace(_ text: String, _ re: NSRegularExpression, group: Int = 0,
                        accept: (NSString, NSTextCheckingResult) -> Bool = { _, _ in true },
                        with: (String) -> String = { _ in AgentRedactor.marker }) -> String {
        let ns = text as NSString
        let out = NSMutableString(string: text)
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let r = m.range(at: group)
            guard r.location != NSNotFound, accept(ns, m) else { continue }
            out.replaceCharacters(in: r, with: with(ns.substring(with: r)))
        }
        return out as String
    }

    // MARK: 1. ID numbers

    /// IBAN: country, check digits, then letters and digits in groups of four (or not); only when mod-97 holds.
    static let iban = regex(#"(?<![A-Za-z0-9])[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?(?![A-Za-z0-9])"#)
    /// UK National Insurance number ("AB 12 34 56 C"), less the prefixes HMRC never issues.
    static let niNumber = regex(#"(?<![A-Za-z0-9])(?!BG|GB|KN|NK|NT|TN|ZZ)[A-CEGHJ-PR-TW-Z][A-CEGHJ-NPR-TW-Z] ?\d{2} ?\d{2} ?\d{2} ?[A-D](?![A-Za-z0-9])"#)
    /// An ID number after its label: "passport X12345678", "driver's license no. D1234567", "NHS number 943 476 5919".
    static let idLabel = #"(?:passport|driver'?s?\s+licen[cs]e|driving\s+licen[cs]e|licen[cs]e\s+(?:no\.?|number|#)|national\s+(?:id|identity|insurance)(?:\s+card)?|id\s+(?:card|no\.?|number|#)|identity\s+(?:card|number)|tax\s+(?:id|identification|number|reference)|nhs\s+(?:no\.?|number)|medicare(?:\s+(?:card|no\.?|number))?|social\s+insurance(?:\s+number)?|personal\s+(?:id|identity)\s+(?:no\.?|number)|aadhaar|personnummer|resident\s+(?:card|permit)|green\s+card)"#
    static let idFiller = #"(?:\s*(?:no\.?|number|num|#|is|was|:|-)(?![A-Za-z]))*\s*:?\s*"#
    static let idValueGroup = #"([A-Za-z0-9](?:[A-Za-z0-9 -]{3,22}[A-Za-z0-9])?)"#
    static let labelledID = regex(#"\b"# + idLabel + #"\b"# + idFiller + idValueGroup, [.caseInsensitive])
    /// The same after an acronym label, case-sensitive ("SIN 046 454 286", "TIN 12-3456789").
    static let acronymID = regex(#"\b(?:SIN|TIN|ITIN|EIN|NINO|NI|SSN|DL|PPS|BSN|CPF|NIF|NIE|DNI)\b"# + idFiller + idValueGroup)
    static let dateOrYear = regex(#"^(?:\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}|(?:19|20)\d{2})$"#)

    static func mod97(_ compact: String) -> Bool {
        let chars = Array(compact)
        guard (15...34).contains(chars.count) else { return false }
        var remainder = 0
        for c in chars[4...] + chars[..<4] {
            if c.isASCII, let d = c.wholeNumberValue { remainder = (remainder * 10 + d) % 97 }
            else if let a = c.asciiValue, (65...90).contains(a) { remainder = (remainder * 100 + Int(a) - 55) % 97 }
            else { return false }
        }
        return remainder == 1
    }
    /// The part of a labelled value that is the number: up to the first plain word, at least five digits, not a date.
    static func idValue(_ raw: String) -> String? {
        var kept: [Substring] = []
        for word in raw.split(separator: " ") {
            if word.count > 3, word.allSatisfy({ $0.isLetter && $0.isLowercase }) { break }
            kept.append(word)
        }
        let value = kept.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        guard value.filter(\.isNumber).count >= 5, !whole(dateOrYear, value) else { return nil }
        return value
    }
    static func idNumbers(_ text: String) -> String {
        var out = replace(text, iban, accept: { ns, m in mod97(ns.substring(with: m.range).replacingOccurrences(of: " ", with: "")) })
        out = replace(out, niNumber)
        for re in [labelledID, acronymID] {
            out = replace(out, re, group: 1, accept: { ns, m in idValue(ns.substring(with: m.range(at: 1))) != nil }) { value in
                guard let id = idValue(value), let r = value.range(of: id) else { return value }
                return value.replacingCharacters(in: r, with: marker)
            }
        }
        return out
    }

    // MARK: 3. Web addresses

    /// A web address: with a scheme, starting "www.", or a host name followed by a path, query or fragment.
    static let webAddress = regex(#"(?:\b[a-z][a-z0-9+.-]{1,30}://|\bwww\.|(?<![\w@.-])(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,24}(?::\d{2,5})?(?=[/?#]))[^\s<>"'`]*"#, [.caseInsensitive])
    /// "user:password@host" with no scheme.
    static let bareLogin = regex(#"(?<![^\s(<"'])[^\s:/@()<>"']+:[^\s@/()<>"']+@(?=(?:[a-z0-9-]+\.)+[a-z]{2,})"#, [.caseInsensitive])
    static let trailing = Set(".,;:!?)]}'\"\u{2019}\u{201D}")

    /// One web address without its login, query string or fragment; sentence punctuation after it is kept.
    static func bareAddress(_ address: String) -> String {
        var core = Substring(address), tail = ""
        while let last = core.last, trailing.contains(last) { tail = String(last) + tail; core = core.dropLast() }
        var s = String(core)
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }
        // The login sits between "://" (or the start) and the host: up to the last "@" before the path.
        let hostStart = s.range(of: "://").map(\.upperBound) ?? s.startIndex
        let pathStart = s[hostStart...].firstIndex(of: "/") ?? s.endIndex
        if let at = s[hostStart..<pathStart].lastIndex(of: "@") { s.removeSubrange(hostStart...at) }
        return s + tail
    }
    static func webAddresses(_ text: String) -> String {
        replace(replace(text, bareLogin, with: { _ in "" }), webAddress, with: bareAddress)
    }

    // MARK: 4. Token pairs outside a web address

    static let secretPair = regex(#"(?<![A-Za-z0-9_])((?:access_|id_|refresh_|auth_|session_|csrf_)?token|api_?key|apikey|key|sig|signature|code|auth|password|passwd|pass|pwd|secret|client_secret|session|sessionid|sid|jwt|otp)=([^\s&#]+)"#, [.caseInsensitive])
    static func queryPairs(_ text: String) -> String {
        replace(text, secretPair, group: 2, accept: { ns, m in ns.substring(with: m.range(at: 2)) != marker })
    }

    // MARK: 5. Token pass

    static let tokenRe = regex(#"\S+"#)
    /// Quotes, brackets and sentence punctuation around a word.
    static let edge = CharacterSet(charactersIn: "\"'`()[]{}<>.,;:\u{201C}\u{201D}\u{2018}\u{2019}\u{00AB}\u{00BB}")
    static let time = regex(#"^\d{1,2}(?:[:.]\d{2}){0,2}(?:am|pm|a\.m|p\.m)?(?:[-–]\d{1,2}(?:[:.]\d{2})?(?:am|pm)?)?$"#, [.caseInsensitive])
    static let date = regex(#"^\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}$"#)
    static let version = regex(#"^v?\d+(?:\.\d+){1,3}(?:-?(?:alpha|beta|rc|b)\d*)?$"#, [.caseInsensitive])
    static let tag = regex(#"^[#@][A-Za-z][A-Za-z0-9_]{0,38}$"#)
    static let acronymNumber = regex(#"^[A-Z]{1,6}-\d{1,4}$"#)
    static let fileName = regex(#"^[\p{L}\p{N}_ -]{1,80}\.(?:pdf|docx?|xlsx?|pptx?|txt|md|csv|json|png|jpe?g|gif|heic|mov|mp4|zip|swift|py|js|ts|html|css|key|numbers|pages)$"#, [.caseInsensitive])

    /// Shapes ordinary writing uses that `Privacy.secret`'s three-kinds-of-character rule would take for a password:
    /// "Wouldn't", "Co-Founder", "10:30am", "2026-10-04", "v2.3.1", "COVID-19", "GPT-4o", "#launch", "Q3_plan.pdf".
    static func ordinary(_ core: String) -> Bool {
        if core.contains("://") || core.lowercased().hasPrefix("www.") || ContactShape.email(core) { return true }
        if !core.contains(where: \.isNumber), core.allSatisfy({ $0.isLetter || "-'\u{2019}.&/".contains($0) }) { return true }
        if [time, date, version, tag, acronymNumber, fileName].contains(where: { whole($0, core) }) { return true }
        // Compounds of words, short numbers and versions: COVID-19, GPT-4o-mini, Claude-3.5, x86-64.
        let parts = core.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { p in
            !p.isEmpty && (p.allSatisfy(\.isLetter) || (p.allSatisfy(\.isNumber) && p.count <= 2) || whole(version, String(p))
                           || (p.count <= 3 && p.allSatisfy { $0.isLetter || $0.isNumber }))
        }
    }
    static func tokens(_ text: String) -> String {
        replace(text, tokenRe, accept: { ns, m in
            let raw = ns.substring(with: m.range)
            guard !raw.contains(marker) else { return false }
            let core = raw.trimmingCharacters(in: edge).trimmingCharacters(in: CharacterSet(charactersIn: "!?"))
            // Plain numbers are judged by the scrubber's code and card rules, which read the words around them.
            guard !core.isEmpty, !core.allSatisfy({ $0.isNumber }), !ordinary(core) else { return false }
            return Privacy.secret(core)
        }) { raw in
            // The word goes with any "!" or "?" inside its quotes; the quotes and sentence punctuation stay.
            let inner = raw.trimmingCharacters(in: edge)
            guard !inner.isEmpty, let r = raw.range(of: inner) else { return marker }
            return raw.replacingCharacters(in: r, with: marker)
        }
    }

    // MARK: 6. A code read off a phone

    static let shortCode = regex(#"(?<![\w.,/:#$€£-])(?:\d{3}[ -]?\d{3}|\d{8})(?![\w/-]|[.,:]\d)"#)
    static func shortCodes(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).count <= 4 ? replace(text, shortCode) : text
    }
}
