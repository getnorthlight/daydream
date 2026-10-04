import Foundation
import MemoryCore
import PrivacyPolicy

/// Review gap "TypedSecretScrubber robustness": a seeded, synthetic fuzz of the
/// secret shapes typed text can carry, through both layers a typed unit meets:
/// the capture session (`TypingSession`, with the key map: corrections, caret
/// moves, dead keys, paste, input-method composition, unit splits) and the
/// store-side net (`TypedSecretScrubber.scrub`, what `MemoryStore.ingest` saves).
/// Every secret is generated here from a fixed seed; no real key, card or
/// password is used. Output names shapes and counts only, never a value.
/// A failure prints the shape, context index and seed, never the text.

struct SplitMix { var s: UInt64
    mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
    mutating func str(_ alphabet: String, _ n: Int) -> String { let a = Array(alphabet); return String((0..<n).map { _ in a[int(a.count)] }) }
}
let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ", lower = "abcdefghijklmnopqrstuvwxyz", digits = "0123456789", hexL = "0123456789abcdef"
let alnum = upper + lower + digits, url64 = alnum + "_-", b64 = alnum + "+/"

/// A body that mixes kinds the way generated keys do (never all one kind).
func body(_ r: inout SplitMix, _ alphabet: String, _ n: Int) -> String {
    while true { let s = r.str(alphabet, n)
        if s.contains(where: \.isNumber) && s.contains(where: \.isLetter) && (alphabet == hexL || alphabet == digits + upper || (s.contains(where: \.isUppercase) && s.contains(where: \.isLowercase))) { return s } }
}
func luhnComplete(_ prefix: [Int], length: Int, _ r: inout SplitMix) -> String {
    var d = prefix; while d.count < length - 1 { d.append(r.int(10)) }
    var sum = 0
    for (i, x) in d.reversed().enumerated() { if i % 2 == 0 { let y = x * 2; sum += y > 9 ? y - 9 : y } else { sum += x } }
    d.append((10 - sum % 10) % 10); return d.map(String.init).joined()
}
/// `cut`: where the split ways (soft newline, paste, idle split, typo) break the text; the middle when nil.
struct Secret { let shape: String; let text: String; let core: [String]; var cut: Int? = nil }

/// The secret shapes. `core`: fragments that must not survive (the random part, never a public prefix).
func keyShapes(_ r: inout SplitMix) -> [Secret] {
    func k(_ shape: String, _ prefix: String, _ b: String, _ suffix: String = "") -> Secret {
        let mid = b.index(b.startIndex, offsetBy: b.count / 2 - 5)
        return Secret(shape: shape, text: prefix + b + suffix, core: [String(b[mid..<b.index(mid, offsetBy: 10)])])
    }
    return [
        k("anthropic", "sk-ant-api03-", body(&r, url64, 93), "AA"),
        k("openai-project", "sk-proj-", body(&r, url64, 120)),
        k("openai-legacy", "sk-", body(&r, alnum, 48)),
        k("github-classic", "ghp_", body(&r, alnum, 36)),
        k("github-fine", "github_pat_", body(&r, alnum, 22) + "_" + body(&r, alnum, 59)),
        k("gitlab", "glpat-", body(&r, url64, 20)),
        k("slack-bot", "xoxb-\(r.str(digits, 12))-\(r.str(digits, 13))-", body(&r, alnum, 24)),
        k("aws-id", "AKIA", body(&r, digits + upper, 16)),
        k("aws-secret", "", body(&r, b64, 40)),
        k("google", "AIza", body(&r, url64, 35)),
        k("stripe", "sk_live_", body(&r, alnum, 24)),
        k("npm", "npm_", body(&r, alnum, 36)),
        k("huggingface", "hf_", body(&r, alnum, 34)),
        k("jwt", "eyJhbGciOiJIUzI1NiJ9.", "eyJ" + body(&r, url64, 40) + "." + body(&r, url64, 43)),
        k("sendgrid", "SG.", body(&r, url64, 22) + "." + body(&r, url64, 43)),
        k("hex40", "", body(&r, hexL, 40)),
        k("hex64", "", body(&r, hexL, 64)),
        k("base64-32", "", body(&r, alnum, 32)),
        k("telegram", "\(r.str(digits, 10)):A", body(&r, url64, 34)),
    ]
}
func cardShapes(_ r: inout SplitMix) -> [Secret] {
    let visa = luhnComplete([4], length: 16, &r), mc = luhnComplete([5, 1 + r.int(5)], length: 16, &r)
    let amex = luhnComplete([3, 7], length: 15, &r), diners = luhnComplete([3, 6], length: 14, &r), long = luhnComplete([6, 2], length: 19, &r)
    func g(_ s: String, _ sizes: [Int], _ sep: String) -> String {
        var out: [String] = [], i = s.startIndex
        for n in sizes { let j = s.index(i, offsetBy: n); out.append(String(s[i..<j])); i = j }
        return out.joined(separator: sep)
    }
    func c(_ shape: String, _ text: String, _ digits: String) -> Secret {
        let mid = digits.index(digits.startIndex, offsetBy: digits.count / 2 - 4)
        return Secret(shape: shape, text: text, core: [String(digits[mid..<digits.index(mid, offsetBy: 8)])])
    }
    return [
        c("card-plain", visa, visa), c("card-spaces", g(visa, [4, 4, 4, 4], " "), visa), c("card-dashes", g(mc, [4, 4, 4, 4], "-"), mc),
        c("card-dots", g(visa, [4, 4, 4, 4], "."), visa), c("card-slashes", g(mc, [4, 4, 4, 4], "/"), mc),
        c("card-underscores", g(visa, [4, 4, 4, 4], "_"), visa), c("card-mixed", g(visa, [4, 4], " ") + "-" + g(String(visa.dropFirst(8)), [4, 4], " "), visa),
        c("card-amex", g(amex, [4, 6, 5], " "), amex), c("card-diners", g(diners, [4, 6, 4], " "), diners), c("card-19", long, long),
        c("card-2-8-6", g(mc, [2, 8, 6], " "), mc),
        // Review round 1: any separator that is not a letter or digit, up to four characters of it.
        c("card-commas", g(visa, [4, 4, 4, 4], ","), visa), c("card-comma-space", g(mc, [4, 4, 4, 4], ", "), mc),
        c("card-plus", g(visa, [4, 4, 4, 4], "+"), visa), c("card-colons", g(mc, [4, 4, 4, 4], ":"), mc),
        c("card-pipes", g(visa, [4, 4, 4, 4], "|"), visa), c("card-double-dash", g(mc, [4, 4, 4, 4], " -- "), mc),
        c("card-semicolons", g(visa, [4, 4, 4, 4], "; "), visa), c("card-amex-commas", g(amex, [4, 6, 5], ","), amex),
        c("card-mixed-seps", g(visa, [4, 4], ",") + " - " + g(String(visa.dropFirst(8)), [4, 4], "|"), visa),
        c("card-fullwidth", String(g(visa, [4, 4, 4, 4], " ").map { $0.isNumber ? Character(UnicodeScalar(0xFF10 + UInt32($0.wholeNumberValue!))!) : $0 }), visa),
        c("card-then-expiry", visa + "/0" + String(1 + r.int(9)) + "2" + String(r.int(10)), visa),
        c("card-glued-word", "visa" + visa, visa), c("card-glued-cc", "cc" + g(visa, [4, 4, 4, 4], " "), visa),
    ]
}
func passwordShapes(_ r: inout SplitMix) -> [Secret] {
    let sym = "!@#$%^&*~+=?|"
    var pw = ""
    while !(TypedSecretScrubber.symbolPassword(pw)) { pw = r.str(alnum + sym, 16) }
    let words = "correct horse battery staple".split(separator: " ").map(String.init)
    return [Secret(shape: "symbol-password", text: pw, core: [String(pw.prefix(8)), String(pw.suffix(8))]),
            Secret(shape: "labelled-password", text: "password is " + pw, core: [String(pw.prefix(8))]),
            Secret(shape: "passphrase-label", text: "the passphrase is " + words.joined(separator: " "), core: ["battery staple"])]
            + humanPasswordShapes(&r)
}
/// Review round 1: passwords people make up ("Fluffy123", "Summer2024!", "Blue42Sky99", "hunter22"), which
/// look like words and can only be told by their label, in every way the reviewer typed a label: with or
/// without ":" or "is", before or after the password, and after other words ("Bank login: password: …").
let passwordLabels = ["password: {P}", "password {P}", "pw {P}", "pwd {P}", "pw: {P}", "pw={P}", "pass: {P}", "passcode: {P}",
                      "Password - {P}", "my pass is {P}", "{P} is my password", "{P} is the wifi password", "wifi pw {P}", "gmail pw {P}",
                      "home wifi: {P}", "wifi password {P}", "username sam password {P}", "login sam {P}", "login: sam / {P}",
                      "Bank login: password: {P}", "todo: password: {P}", "Netflix:\npassword: {P}", "Wifi:\npassword: {P}",
                      "password for bank {P}", "Password: {P}"]
func humanPasswordShapes(_ r: inout SplitMix) -> [Secret] {
    let names = ["Summer", "Fluffy", "Tiger", "Maple", "River", "Sunny", "Coffee", "Charlie", "Hunter", "Winter", "Orange", "Buster"]
    func made() -> String {
        switch r.int(4) {
        case 0: return r.pick(names) + r.str(digits, 2 + r.int(3)) + r.pick(["", "!", "#", "?"])
        case 1: return r.pick(names).lowercased() + r.str(digits, 2 + r.int(2))
        case 2: return r.pick(names) + r.str(digits, 2) + r.pick(names) + r.str(digits, 2)
        default: return r.pick(["P@ss", "Tr0ub", "C0ff33", "S3cure"]) + r.str(lower, 2) + r.str(digits, 2) + r.pick(["", "&", "$"])
        }
    }
    return passwordLabels.enumerated().map { i, label in
        let p = made()
        // The core is the password without a symbol at its end (sentence punctuation may follow it).
        // The split ways break the text where a person stops: between the label and the password
        // (a pause, a paste, a line break), not inside the word "password". A password typed
        // before its label ("{P} is my password") is cut before it: typed first and cut off
        // from its label by a pause or a paste, it is judged alone (NOTES: review round 1).
        let cut = label.distance(from: label.startIndex, to: label.range(of: "{P}")!.lowerBound)
        return Secret(shape: "pw-label-\(i)", text: label.replacingOccurrences(of: "{P}", with: p),
                      core: [p.trimmingCharacters(in: CharacterSet(charactersIn: "!#?&$"))], cut: cut)
    }
}
/// Where the secret sits in the typed text. The prose has no digits, so a card fragment can only come from the card.
let contexts = ["{S}", "here is the key {S} for staging", "use {S}.", "({S})", "\"{S}\"", "`{S}`", "'{S}';", "[{S}]", "<{S}>", "key:{S}", "{S}, thanks",
                "export API_TOKEN={S}", "token={S}&next=one", "curl -H 'Authorization: Bearer {S}' example", "please save {S}!", "{S}?", "{S}\nthat one",
                "my card is {S} thanks", "pay with {S} ok"]

var failures = 0, checks = 0, totalA = 0, totalB = 0
func survived(_ saved: String?, _ s: Secret) -> Bool {
    guard let saved else { return false }
    let digitsOnly = String(saved.filter(\.isNumber).compactMap { $0.wholeNumberValue.map { Character(String($0)) } })
    return s.core.contains { core in saved.contains(core) || (core.allSatisfy(\.isNumber) && digitsOnly.contains(core)) }
}
func expect(_ ok: Bool, _ label: String) { checks += 1; if !ok { failures += 1; print("FAIL \(label)") } }

// MARK: Part A: the store-side net on every shape in every context.
func partA() {
    var survivorsA: [String: Int] = [:]
    for seed in UInt64(1)...40 {
        var r = SplitMix(s: seed &* 7919)
        for s in keyShapes(&r) + cardShapes(&r) + passwordShapes(&r) {
            for (i, c) in contexts.enumerated() {
                let text = c.replacingOccurrences(of: "{S}", with: s.text)
                totalA += 1
                if survived(TypedSecretScrubber.scrub(text).kept, s) { survivorsA[s.shape, default: 0] += 1; if survivorsA[s.shape] == 1 { print("  survivor: \(s.shape) context \(i) seed \(seed)") } }
            }
        }
    }
    expect(survivorsA.isEmpty, "A: \(totalA) typed units, every secret shape withheld or dropped by the store-side net (survivors: \(survivorsA.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")))")
}

// MARK: Part B: typed through the capture session, then the store-side net.
/// A slim copy of the PrivacyChecks TypingHarness: a fake clock and one Notes field.
final class Typist {
    let s: TypingSession; var clock: UInt64 = 1_000_000_000_000; var keyMap = TypingKeyMap(); var policy = CapturePolicy()
    var rows: [String] = []; var composing = false
    init(limits: TypingLimits = TypingLimits()) { s = TypingSession(limits: limits); policy.typedText = true }
    func proof() -> FocusProof {
        var p = FocusProof(); p.bundle = "com.apple.Notes"; p.windowID = "w1"; p.focusID = "f1"; p.role = "AXTextArea"
        p.surface = .native; p.secureInput = .no; p.privateMode = .no; p.verified = true; p.fieldStateVerified = true; p.frameAccessible = true; p.navigationStable = true
        p.generation = s.generation; p.policyVersion = policy.version; p.checkedAt = clock; return p
    }
    func write(_ c: TypingCommit) -> Bool { rows.append(c.text); return true }
    func advance(_ seconds: Double) {
        let target = clock + UInt64(seconds * 1e9)
        while let n = [s.idleDeadline, s.nextParkedDeadline, s.housekeepingDeadline].compactMap({ $0 }).min(), n <= target {
            clock = max(clock, n)
            if let p = s.nextParkedDeadline, p <= clock { while let _ = s.resolveParked(destination: TypingDestination(proof: proof(), departure: DepartureState(secureInput: .no, bundle: "com.apple.Notes", focusSecure: .no)), secureInput: false, policy: policy, now: clock, write: write) {} }
            else if let i = s.idleDeadline, i <= clock { live(.idle) } else { s.expire(now: clock) }
        }
        clock = target
    }
    func live(_ reason: SealReason) { _ = s.commitLive(fresh: proof(), reason: reason, policy: policy, now: clock, write: write) }
    func key(_ k: KeyStroke, _ characters: String = "") {
        switch keyMap.intent(k, pressAndHold: true) {
        case .consume: return
        case .noop: return
        case .retract: s.retract()
        case .redo: live(.cursor)
        case .accent(let letter):
            let step = s.apply(.deleteBackward(.character), proof: proof(), policy: policy, eventAt: clock, now: clock)
            guard step.commit == nil else { live(step.commit!); return }
            insert(letter)
        case .leave(let r, _): s.seal(r, now: clock, focusMoved: true); keyMap.reset()
        case .split(let r): live(r)
        case .submit: live(.submit)
        case .paste: live(.paste)
        case .edit(let op): if let c = s.apply(op, proof: proof(), policy: policy, eventAt: clock, now: clock).commit { live(c) }
        case .insertText(let t): insert(t)
        case .insert(let dead): insert(dead.map { $0.compose(characters) } ?? characters)
        }
    }
    func insert(_ t: String) {
        if s.admit(proof(), now: clock) != nil { return }
        if let c = s.insert(t, proof: proof(), policy: policy, eventAt: clock, now: clock, compositionFinal: !composing).commit { live(c) }
    }
    func type(_ text: String) { for c in text { advance(0.09); if c == "\n" { key(KeyStroke(keyCode: 36, shift: true)) } else { key(KeyStroke(keyCode: 0), String(c)) } } }
    func press(_ code: Int64, _ times: Int = 1, cmd: Bool = false, opt: Bool = false) { for _ in 0..<times { advance(0.09); key(KeyStroke(keyCode: code, command: cmd, option: opt)) } }
    func finish() -> [String] { advance(61); live(.suspend); advance(3); return rows }
}
enum Way: String, CaseIterable { case straight, typoFixed, caretFixed, softNewline, deadKeyAccent, pastedMiddle, composing, idleSplit, retypedAfterUndo }
/// fix/public-web-typing: website typing's own soft split (`WebTypingRoute.limits`, Sources/MacMemApp/WebTypingRoute.swift):
/// a 2 s pause after a natural stop and 4 s after anything else, so a website field is split much sooner than a native one,
/// and a 90 s latch, so a secret cut by that pause stays withheld across a long pause (a 30 s latch saved the rest of it).
/// Part B runs every way again with these limits, the idle split pausing 5 s (just past the website split) and 61 s.
let webLimits: TypingLimits = { var l = TypingLimits(); l.idleClosed = 2_000_000_000; l.idleWord = 4_000_000_000; l.idleOpen = 4_000_000_000; l.idleSendFloor = 0; l.latchExpiry = 90_000_000_000; return l }()
func webLimitsPinned() -> Bool {
    guard let src = try? String(contentsOfFile: "Sources/MacMemApp/WebTypingRoute.swift", encoding: .utf8) else { return false }
    return src.contains("l.idleClosed = 2_000_000_000\n        l.idleWord = 4_000_000_000\n        l.idleOpen = 4_000_000_000\n        l.idleSendFloor = 0\n")
        && src.contains("l.latchExpiry = 90_000_000_000\n        return l")
}
func partB(web: Bool = false, pause: Double = 61) {
    var survivorsB: [String: Int] = [:]
    let lane = web ? "website \(Int(pause)) s " : ""
    for seed in UInt64(1)...12 {
        var r = SplitMix(s: seed &* 104_729)
        for s in keyShapes(&r) + cardShapes(&r).filter({ $0.shape != "card-fullwidth" }) + passwordShapes(&r) {
            for way in Way.allCases {
                let t = web ? Typist(limits: webLimits) : Typist(), secret = s.text, half = secret.index(secret.startIndex, offsetBy: s.cut ?? secret.count / 2)
                t.type("note: ")
                switch way {
                case .straight: t.type(secret)
                case .typoFixed: t.type(String(secret[..<half]) + "q"); t.press(51); t.type(String(secret[half...]))
                case .caretFixed:
                    // The middle character is left out, then put back with the arrows.
                    let rest = secret.index(after: half)
                    t.type(String(secret[..<half]) + String(secret[rest...])); let back = secret.distance(from: rest, to: secret.endIndex)
                    t.press(123, back); t.type(String(secret[half])); t.press(124, back)
                case .softNewline: t.type(String(secret[..<half]) + "\n" + String(secret[half...]))
                case .deadKeyAccent: t.type("caf"); t.press(14, opt: true); t.type("e " + secret)
                case .pastedMiddle: t.type(String(secret[..<half])); t.press(9, cmd: true); t.type(String(secret[half...]))
                case .composing: t.composing = true; t.type(secret); t.composing = false; t.type(" ok")
                case .idleSplit: t.type(String(secret[..<half])); t.advance(pause); t.type(String(secret[half...]))
                case .retypedAfterUndo: t.type(secret); t.press(6, cmd: true); t.type(secret)
                }
                t.type(" done.")
                totalB += 1
                let saved = t.finish().compactMap { TypedSecretScrubber.scrub($0).kept }.joined(separator: "\n")
                // A paste, a split or an undo cuts the secret: each piece left must be withheld on its own.
                if survived(saved, s) { survivorsB["\(s.shape)/\(way.rawValue)", default: 0] += 1; if survivorsB["\(s.shape)/\(way.rawValue)"] == 1 { print("  survivor: \(lane)\(s.shape) typed \(way.rawValue) seed \(seed)") } }
            }
        }
    }
    expect(survivorsB.isEmpty, "B\(web ? " (website limits, \(Int(pause)) s pause)" : ""): \(totalB) typing runs (corrections, caret, soft newline, dead key, paste, input method, idle split, undo): no secret fragment saved (survivors: \(survivorsB.keys.sorted().joined(separator: ", ")))")
}

// MARK: Part C: the net still keeps ordinary words (a fuzz that withheld everything would pass A and B).
@main enum TypedSecretFuzz {
    static func main() {
        partA(); partB()
        expect(webLimitsPinned(), "B (website limits): the fuzz's website pauses match WebTypingRoute.limits")
        let nativeRuns = totalB; totalB = 0; partB(web: true, pause: 5); let web5 = totalB; totalB = 0; partB(web: true, pause: 61); totalB += nativeRuns + web5
        let plain = ["meet at the cafe on 5th street at 7", "order 1234 shipped", "call me at 555-0100 tomorrow", "the build is 1.2.3 and version 2026",
                     "email alex@example.com about the offsite", "see https://example.com/docs/setup for the steps", "invoice number 88213 is paid",
                     "ticket ABC-1234 is fixed", "room 4012 at noon", "the year 1987 was fun", "session id 3f2a-b1 is fine",
             // Shapes the new rules look at: slashed and dotted numbers, "&", "!", "?", and soft line breaks.
             "on 2026/09/26 at 10:30", "macOS 15.6.1 and Xcode 26.0", "the server is 192.168.1.10", "pi is about 3.14159",
             "call +1 415 555 0100 today", "Tom & Jerry at 8!", "salt & pepper?", "Really?! That's great!", "is it 50/50 or 60/40?",
             "Dear Sam,\nThanks for the notes!\nBest,\nAlex", "Q3 revenue was $4.2M\nup 12% on Q2", "step 1/3 done\nstep 2/3 next",
             "file_name_2026_09_26.txt is ready", "see page 12/14 of the deck",
             // Review round 1: near misses for the widened card separators and the password labels.
             "sales 2023, 2024, 2025, 2026 grew", "slots 20:30, 21:45, 22:15, 23:20 work", "call 555-123-4567, 555-987-6543",
             "scores 45, 67, 89, 23, 56, 78, 90", "totals 4,500, 3,200, 6,100, 2,900", "pass the salt please", "password reset link sent",
             "the wifi is down again", "boarding pass is in my bag", "my password manager is great", "use a strong password please",
             "sign in with Google tomorrow", "pw reset at noon", "login page redesign ships next week", "wifi at the office is slow",
             "Password: on the fridge", "the pass was closed for snow", "log in and check the dashboard"]
        for p in plain { expect(TypedSecretScrubber.scrub(p).kept == p, "C: ordinary words kept: \(p.count) characters") }

        print(failures == 0 ? "PASS typed secret fuzz: \(checks) checks (\(totalA) store units, \(totalB) typing runs, \(plain.count) ordinary lines)" : "FAIL typed secret fuzz: \(failures) of \(checks) checks")
        exit(failures == 0 ? 0 : 1)
    }
}
