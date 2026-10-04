import Foundation

/// Local transient inspection. Returns only a fixed code, never text or matches.
/// This is a deny classifier, not a password oracle. UnitClassifier decides
/// which of these rules reject a whole typed unit and which withhold one token.
public enum TextClassifier {
    public static let maxBytes=4096
    /// Rules that match a span and stay matched as text is appended.
    private static let rules:[(PrivacyReason,String)] = [
        (.privateKey,#"-----\s*BEGIN\s+(?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY\s*-----"#),
        (.credentialPattern,#"\b(?:sk-(?:proj-)?[a-z0-9_-]{12,}|sk_live_[a-z0-9]{8,}|github_pat_[a-z0-9_]{12,}|gh[pousr]_[a-z0-9]{12,}|xox[baprs]-[a-z0-9-]{8,}|(?:akia|asia)[a-z0-9]{16}|aiza[a-z0-9_-]{20,})\b"#),
        (.credentialPattern,#"\bBearer\s+[a-z0-9._~+/=-]{6,}|\beyJ[a-z0-9_-]+\.[a-z0-9_-]+\.[a-z0-9_-]+"#),
        (.identityIdentifier,#"\b\d{3}[- ]\d{2}[- ]\d{4}\b"#),
        // IBAN: country, check digits, then either one compact run or groups
        // of four in which every group after the first has a digit. (The old
        // shape allowed a space before every character, so "FY24 budget
        // stays" or "CS50 last spring" matched.)
        (.paymentIdentifier,#"\b[a-z]{2}\d{2}(?:[a-z0-9]{11,30}|(?: [a-z0-9]{4})(?: (?=[a-z]{0,3}\d)[a-z0-9]{4}){1,6}(?: [a-z0-9]{1,4})?)\b"#),
        (.sensitiveContext,#"(?:password|passphrase|passcode|passwd|pwd|api[ _-]?key|access[ _-]?token|otp|verification[ _-]?code|account[ _-]?(?:number|no)|routing[ _-]?(?:number|no)|social[ _-]?security|\bssn|\biban|passport|contraseña|mot de passe|kennwort|passwort|验证码|驗證碼|密码|密碼|パスワード|رمز المرور)\s*[:=：]\s*\S+"#),
        // "secret" is also an ordinary word: "The secret: always salt the
        // water" is prose (see `finalRules`). Per key only a first word with
        // a digit or symbol matches, a subset of the finished-text rule.
        (.sensitiveContext,#"secret\s*[:=：]\s*[a-z]*[^a-z\s,;]"#),
        (.sensitiveContext,#"\b(?:otp|verification code|security code|one.time code|account number|routing number|passport number)\b.{0,24}\d{3,}"#)
    ]
    /// Finished text only. A value after "secret:" that starts with two
    /// plain words is prose; one word, a digit or a symbol is a secret.
    /// Until the second word is typed a prefix cannot tell, so this is never
    /// applied per key or per chunk.
    private static let finalRules:[(PrivacyReason,String)] = [
        (.sensitiveContext,#"secret\s*[:=：]\s*(?![a-z]+[ ,;]+[a-z]+\b)\S+"#)
    ]
    private static let compiled=rules.map {($0.0,try! NSRegularExpression(pattern:$0.1,options:[.caseInsensitive]))}
    private static let finalCompiled=finalRules.map {($0.0,try! NSRegularExpression(pattern:$0.1,options:[.caseInsensitive]))}
    static func normalized(_ text:String) -> String {
        let normalized=text.precomposedStringWithCompatibilityMapping
        return String(String.UnicodeScalarView(normalized.unicodeScalars.filter { ![0x200b,0x200c,0x200d,0xfeff,0x2060].contains($0.value) }))
    }
    public static func sensitiveLabel(_ label:String) -> Bool {
        let s=normalized(label).lowercased()
        return ["password","passcode","passphrase","otp","one-time","verification","credit card","card number","cvv","cvc","iban","routing","account number","social security","passport","api key","secret","contraseña","mot de passe","passwort","验证码","驗證碼","密码","密碼","パスワード","رمز المرور"].contains(where:s.contains)
    }
    /// Whole-text verdict (unchanged behaviour): substring rules, then the
    /// rules about the whole trimmed text being one number or one token.
    public static func sensitiveReason(_ text:String) -> PrivacyReason? {
        substringReason(text) ?? anchoredReason(text)
    }
    /// Rules that match a span inside the text. A match on a prefix stays a
    /// match as text is appended, so these are safe per keystroke, over a
    /// window, and across the seam with a previous typed unit. `final`:
    /// the text is finished (a whole unit, a line, the log), so the
    /// "secret:" rule applies too.
    public static func substringReason(_ text:String,final:Bool=true) -> PrivacyReason? {
        guard text.utf8.count <= maxBytes else {return .oversizedBurst}
        return spanReason(text,final:final)
    }
    /// The substring rules with no size limit, for the typing log (bounded
    /// by TypingLimits.typedLogBytes, 8 KB). One linear pass.
    static func spanReason(_ text:String,final:Bool=true) -> PrivacyReason? {
        let s=normalized(text), ns=s as NSString, range=NSRange(location:0,length:ns.length)
        for (reason,regex) in compiled+(final ? finalCompiled : []) where regex.firstMatch(in:s,range:range) != nil {return reason}
        // Conservative card/account-length digit runs, regardless of checksum.
        if s.range(of:#"(?<!\d)(?:\d[ -]?){13,19}(?!\d)"#,options:.regularExpression) != nil {return .paymentIdentifier}
        return nil
    }
    /// Rules about the WHOLE trimmed text being one number or one opaque token.
    /// Meaningless on a prefix ("2026" of "2026 plans"), so never per keystroke.
    public static func anchoredReason(_ text:String) -> PrivacyReason? {
        let v=normalized(text).trimmingCharacters(in:.whitespacesAndNewlines)
        if v.range(of:#"^\d{4,12}$"#,options:.regularExpression) != nil {return .ambiguousNumeric}
        if ContactShape.email(v) || ContactShape.phone(v) {return nil}
        if (8...128).contains(v.count),!v.contains(where:{$0.isWhitespace}),!v.contains("://") {
            let classes=[#"[a-z]"#,#"[A-Z]"#,#"\d"#,#"[^a-zA-Z\d]"#].filter {v.range(of:$0,options:.regularExpression) != nil}.count
            if classes>=3 {return .suspiciousOpaque}
        }
        return nil
    }
    /// Typing-only rules, deliberately not part of `rules` so the gate, URL
    /// checks ("pinterest.com/pin/123") and fixture statistics are
    /// unchanged: typed prose that states a secret without a colon ("my
    /// password is x", "my pin is 4921") and short numeric secrets named by
    /// their label ("PIN 4921", "cvv: 123", "2fa code 482913"). A
    /// password-family value that is a place or state word ("the password is
    /// on the fridge", "was the same") is prose; PIN and code values must be
    /// digits, so "the pin is on the map" and "dress code: casual" are prose.
    /// `final`: the text is finished. Per key ("password is o" may become
    /// "password is on the fridge") the password-family value must be a
    /// complete word, which keeps every per-key match a match of the final
    /// text.
    public static func proseReason(_ text:String,final:Bool=true) -> PrivacyReason? {
        let s=normalized(text),range=NSRange(location:0,length:(s as NSString).length)
        return (final ? prose[...] : prose.dropFirst()).contains(where:{$0.firstMatch(in:s,range:range) != nil}) ? .sensitiveContext : nil
    }
    private static let passwordProse=#"\b(?:password|passphrase|passcode|passwd|pwd)\s+(?:is|was)\s*:?\s+(?!(?:on|in|at|under|behind|inside|taped|written|saved|stored|kept|somewhere|below|above|attached|the|a|an|same|still|not|no|also|too|here|there|wrong|incorrect|expired|changed|reset|required|missing|different)\b)\S+"#
    /// The first rule is the finished-text form of the second.
    private static let prose=[
        passwordProse,
        passwordProse+#"\s"#,
        // (Two patterns: one alternation with the look-behind inside cost
        // about 1 ms per 512 characters in ICU.)
        #"\b(?:pin|pin code|cvv|cvc|passcode|(?:2fa|mfa|auth|login|security|verification|one[ -]?time|backup|recovery|sms|access|door|gate|alarm|safe|lock)\s*code)\s+(?:is|was)\s*:?\s*\d{3,}"#,
        #"(?<!zip |area |postal |post |country |status |error |exit |http |response |promo |discount |coupon |dress |source |qr |bar |morse )\bcode\s+(?:is|was)\s*:?\s*\d{3,}"#,
        #"\b(?:pins?|pin code|cvv2?|cvc2?|csc|passcode|ssn|(?:2fa|mfa|auth|authentication|login|security|verification|one[ -]?time|backup|recovery|sms|access|confirmation|door|gate|alarm|safe|lock)\s*codes?)\b\W{0,3}\d{3,}"#,
        #"(?<!zip |area |postal |post |country |status |error |exit |http |response |promo |discount |coupon |dress |source |qr |bar |morse )\bcodes?\s*[:=：]\s*\d{3,}"#
    ].map {try! NSRegularExpression(pattern:$0,options:[.caseInsensitive])}
    /// Text ending in a label that is still waiting for its value
    /// ("password:", "pin is", "api key ="). Such a tail is never "closed".
    public static func pendingLabel(_ text:String) -> Bool {pendingLabelText(text) != nil}
    /// The label itself ("Password:", "pin is"), for a unit that is rejected
    /// as a whole: the next unit is still judged as the label's value.
    static func pendingLabelText(_ text:String) -> String? {
        let s=normalized(String(text.suffix(64))),ns=s as NSString
        guard let m=pending.firstMatch(in:s,range:NSRange(location:0,length:ns.length)) else {return nil}
        return ns.substring(with:m.range)
    }
    private static let pending=try! NSRegularExpression(pattern:#"(?<![a-z])(?:password|passphrase|passcode|passwd|pwd|pin|code|api[ _-]?key|access[ _-]?token|token|secret|otp|account[ _-]?(?:number|no)|routing[ _-]?(?:number|no)|social[ _-]?security|ssn|passport|iban|cvv|cvc|contraseña|mot de passe|kennwort|passwort|验证码|驗證碼|密码|密碼|パスワード|رمز المرور)\s*(?:[:=：]|\s(?:is|was)\s*:?)\s*$"#,options:[.caseInsensitive])
    /// Text ending in a word that names a password with no ":" or "is", and
    /// at most two words after it ("pw", "Password -", "wifi password",
    /// "login sam", "login: sam /", "password for bank"): the next unit's
    /// first word is its value when it could be a made-up password
    /// (`passwordLike`). Review round 1: "pw " and a pause, then "Fluffy123".
    public static func bareLabel(_ text:String) -> Bool {
        let s=normalized(String(text.suffix(64))),ns=s as NSString
        return bare.firstMatch(in:s,range:NSRange(location:0,length:ns.length)) != nil
    }
    private static let bare=try! NSRegularExpression(pattern:#"(?<![\p{L}\p{N}_/.@#?&-])(?:password|passwd|passphrase|passcode|pwd|pw|pass|contraseña|passwort|kennwort|mot de passe|log-?in|log in|sign-?in|sign in|creds|credentials|wi-?fi)(?:[ \t:=/|>–—-]+[^\s.;:]+){0,2}[ \t:=/|>–—-]*$"#,options:[.caseInsensitive])
    /// A word that could be a password someone made up: 6-64 characters,
    /// letters and at least one digit or symbol, and not a link, path,
    /// address, time or version ("Fluffy123", "hunter22", "P@ssword").
    public static func passwordLike(_ token:Substring) -> Bool {
        let v=normalized(String(token)).trimmingCharacters(in:edgePunctuation)
        guard (6...64).contains(v.count),!v.contains("[withheld]"),!exemptShape(v, original:String(token)),v.contains(where:\.isLetter) else {return false}
        let c=classes(v)
        guard c.digit || c.other else {return false}
        return v.range(of:#"^(?:\d{1,2}[:.]\d{2}(?:am|pm)?|v?\d+(?:\.\d+)+[a-z]?)$"#,options:[.regularExpression,.caseInsensitive]) == nil
    }
    /// Digit groups of three or more joined by one to four characters that are
    /// not letters, digits, spaces or dots: one token of a card typed
    /// "4111,1111", "1111|1111" or "4111:1111:" (review round 1). Clock times,
    /// amounts ("4,500"), dates, IP addresses and versions are not.
    public static func joinedDigits(_ token:Substring) -> Bool {
        let v=normalized(String(token)).trimmingCharacters(in:edgePunctuation)
        return !dateShape(v) && v.range(of:#"^\d{3,}(?:[^\p{L}\p{N}\s.]{1,4}\d{3,})+[^\p{L}\p{N}\s.]{0,4}$"#,options:.regularExpression) != nil
    }
    /// One to four characters that are neither letters nor digits ("--", "|", "+"):
    /// a separator typed between digit groups with spaces around it.
    public static func separatorToken(_ token:Substring) -> Bool {
        (1...4).contains(token.count) && token.allSatisfy { !$0.isLetter && !$0.isNumber }
    }
    static let edgePunctuation=CharacterSet(charactersIn:"\"'()[]{}<>.,;:!?\u{201C}\u{201D}\u{2018}\u{2019}\u{00AB}\u{00BB}")
    /// One token inside prose that looks like a credential: 8-256 characters
    /// with all four classes, or 24+ characters with three. Edge punctuation is
    /// trimmed first. URLs, email addresses and paths are exempt (the substring
    /// rules still see them).
    public static func opaqueToken(_ token:Substring) -> Bool {
        let v=normalized(String(token)).trimmingCharacters(in:edgePunctuation)
        guard (8...256).contains(v.count),!v.contains(where:{$0.isWhitespace}) else {return false}
        // Same classes as the anchored rule, without a regex per class.
        var lower=false,upper=false,digit=false,other=false
        for u in v.unicodeScalars {
            switch u.value {
            case 0x61...0x7A: lower=true
            case 0x41...0x5A: upper=true
            default: if CharacterSet.decimalDigits.contains(u) {digit=true} else {other=true}
            }
        }
        let classes=[lower,upper,digit,other].filter {$0}.count
        guard classes == 4 || (classes >= 3 && v.count >= 24) else {return false}
        return !exemptShape(v, original:String(token))
    }
    /// Letter case, digit and symbol classes of an edge-trimmed token.
    /// Apostrophes and hyphens inside words ("O'Brien", "Mary-Jane") are not
    /// symbols here.
    static func classes(_ v:String) -> (lower:Bool,upper:Bool,digit:Bool,other:Bool,transitions:Int) {
        var lower=false,upper=false,digit=false,other=false,transitions=0,last:Int?=nil
        for u in v.unicodeScalars {
            let kind:Int
            switch u.value {
            case 0x61...0x7A: lower=true;kind=0
            case 0x41...0x5A: upper=true;kind=0
            default:
                if CharacterSet.decimalDigits.contains(u) {digit=true;kind=1}
                else if CharacterSet.letters.contains(u) {kind=0}
                else {if !"-'\u{2019}".unicodeScalars.contains(u) {other=true};kind=2}
            }
            if kind != 2 {if let l=last,l != kind {transitions+=1};last=kind}
        }
        return (lower,upper,digit,other,transitions)
    }
    static func exemptShape(_ v:String, original:String?=nil) -> Bool {
        v.contains("://") || v.hasPrefix("/") || v.hasPrefix("~/") || v.hasPrefix("./") || v.hasPrefix("../") ||
            ContactShape.tokenEmail(original ?? v)
    }
    static let credentialPrefixes=["sk-","sk_live_","sk_test_","rk_live_","ghp_","gho_","ghu_","ghs_","ghr_","github_pat_","xoxb-","xoxa-","xoxp-","xoxr-","xoxs-","AKIA","ASIA","AIza","eyJ"]
    static func dateShape(_ v:String) -> Bool {
        v.range(of:#"^(?:\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4})$"#,options:.regularExpression) != nil
    }
    /// A number typed as one group of a longer number: digits, optionally
    /// joined by dashes ("4111", "123-45-"). Dates are not groups.
    public static func digitGroup(_ token:Substring) -> Bool {
        let v=normalized(String(token)).trimmingCharacters(in:edgePunctuation)
        guard v.count>=2,!dateShape(v) else {return false}
        return v.range(of:#"^\d+(?:-\d+)*-?$"#,options:.regularExpression) != nil
    }
    /// A token cut off by the end of a unit (no whitespace after it) that may
    /// be the first part of a secret, so it is withheld rather than stored on
    /// its own: a known credential prefix, three or more character classes
    /// ("Xk9#mQ", "Tr0ub"), letters and digits alternating at least twice
    /// ("tr0ub"), or five or more digits that are not a date. Plain words,
    /// "3pm", "COVID19", years and words with edge punctuation ("buy:",
    /// "(tomorrow)", "there.\"") are not suspicious.
    public static func suspiciousPartial(_ token:Substring) -> Bool {
        let v=normalized(String(token)).trimmingCharacters(in:edgePunctuation)
        guard v.count>=3,!exemptShape(v, original:String(token)),!ContactShape.phone(v) else {return false}
        if credentialPrefixes.contains(where:{v.hasPrefix($0)}),v.count>=4 {return true}
        guard v.count>=4 else {return false}
        let c=classes(v)
        let digits=v.filter(\.isNumber).count
        // Digits joined by anything that is not a letter: a card typed "4111_1111_", "4111,1111," or
        // "4111|1111" and cut by a paste or a pause (secret fuzz; review round 1: not one separator at a time).
        if !c.lower && !c.upper && digits>=5 && !dateShape(v) && v.allSatisfy({$0.isNumber || !$0.isLetter}) {return true}
        if [c.lower,c.upper,c.digit,c.other].filter({$0}).count>=3 {return true}
        return (c.lower || c.upper) && c.digit && c.transitions>=2 && v.count>=5
    }
    public static func evaluate(_ text:String,proof:FocusProof,policy:CapturePolicy,generation:UInt64,now:UInt64,compositionFinal:Bool=true,additionalDeny:Bool=false) -> PrivacyDecision {
        let first=CaptureGate.typing(proof,policy:policy,generation:generation,now:now)
        guard first.outcome == .allowed else {return first}
        guard compositionFinal else {return CaptureGate.result(.unknown,.compositionPending,proof)}
        if let reason=sensitiveReason(text) {return CaptureGate.result(.blocked,reason,proof)}
        if additionalDeny {return CaptureGate.result(.blocked,.classifierDeny,proof)}
        return first
    }
}
