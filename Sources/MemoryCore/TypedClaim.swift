import Foundation

/// Safe typing H: the one-sentence answer to "isn't this a keylogger?",
/// worded so each phrase is literally true (SPEC section 10).
///
/// - "what you type is encrypted on your Mac": typed words only (B); app
///   names, titles and times are not encrypted, and Settings says so.
/// - "password fields and private browser windows are skipped": password
///   fields and Secure Input are never read; ordinary-looking passwords in
///   normal text boxes can be missed, so the claim names password fields only.
/// - "DayDream deletes the exact words after 7 days unless you choose
///   otherwise": the default period (D), for DayDream's own storage. The
///   words are also hidden the moment the period ends and deleted before any
///   change to a longer period. Time Machine backups of the Mac are the
///   person's own copies: they can hold older encrypted rows (and, while the
///   key is in the login keychain, older keys) until those backups are
///   deleted; Settings says so (`TypedLimitsText.timeMachine`).
/// - "AI apps never get the exact words; cloud summaries do only if you
///   choose them": AI apps you connect run as the CLI or MCP process, which
///   has no typing key, so they get where and about how much was typed only
///   (decision 4). The cloud writer opens typed words only while typing is on
///   and Cloud is the chosen writer (`TypedAccess` `.cloudWriter`); Chrome
///   pages and website typing go with their cleaned page titles and sites
///   (`NoteAudience.cloudView`, `PrivacyPromise.cloudLimit`). Encrypted
///   copies in Time Machine stay on the person's own backup disk, which the
///   Limits lines say.
/// - "open source": only once the repository is public under the MIT License
///   and the shipped build is made from it (`openSourcePublished`).
///
/// `scripts/typed-claim-checks.py` fails on any app string or README line
/// that promises the words never leave the Mac without an "unless" clause,
/// or that claims to skip all passwords rather than password fields.
public enum TypedClaim {
    /// Owner decision 5 (typeall SPEC-LATER): the repository is public under
    /// the MIT License and the shipped build is made from it. The claim check
    /// requires an MIT LICENSE file while this is true.
    public static let openSourcePublished = true

    public static var sentence: String {
        "Only while its switch is on (setup shows the switch, on, and one click turns it off). When on, what you type is encrypted on your Mac, password fields and private browser windows are skipped, DayDream deletes the exact words after \(TypedRetention.default.label) unless you choose otherwise, and AI apps never get the exact words (cloud summaries do only if you choose them)"
            + (openSourcePublished ? ", and it's all open source." : ".")
    }
    /// The short version for Hacker News.
    public static var short: String {
        "Only while its switch is on; encrypted on your Mac; skips password fields and private browser windows; deletes the exact words after \(TypedRetention.default.label); AI apps never get the exact words; cloud summaries do only if you choose them"
            + (openSourcePublished ? "; open source (MIT)." : ".")
    }
}

/// Where the typing key lives. Settings claims the key is kept only on this Mac only for
/// the data-protection keychain (ThisDeviceOnly holds there); the login
/// keychain file is copied by Time Machine and Migration Assistant.
public enum TypedKeyPlace: String, Sendable {
    case dataProtectionKeychain, loginKeychain
}

/// The "Limits" lines under the typing settings (SPEC 9.2), plain words.
/// Every line is literally true; `typed-claim-checks.py` keeps backup claims
/// qualified.
public enum TypedLimitsText {
    public static let inputMethods = "Paste, autocomplete, dictation and other input methods aren't recorded."
    public static let ordinaryPasswords = "Ordinary-looking passwords typed into normal text boxes can't always be recognized, and neither can every recovery code or passphrase."
    public static let incognito = "DayDream can't tell when a chat app is in incognito mode."
    public static let backups = "DayDream's own backups don't include the exact words you typed."
    public static let timeMachine = "Time Machine backups of this Mac can keep older encrypted copies until those backups are deleted."
    public static let history = "Your history isn't encrypted yet, only what you type. Turn on FileVault."
    public static let searchPages = "While search typing is on, search pages keep only the site, not what you searched for."
    /// "kept only on this Mac" only where it holds (never "stays on this Mac": the Saturday honesty rule).
    public static func key(_ place: TypedKeyPlace) -> String {
        switch place {
        case .dataProtectionKeychain: return "The typing key is kept only on this Mac and isn't copied to backups or other Macs."
        case .loginKeychain: return "The typing key is in your login keychain, which Time Machine and Migration Assistant copy."
        }
    }
    public static func all(_ place: TypedKeyPlace) -> [String] {
        [inputMethods, ordinaryPasswords, incognito, backups, timeMachine, key(place), searchPages, history]
    }
}
