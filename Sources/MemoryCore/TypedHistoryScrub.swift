import Foundation
import PrivacyPolicy

/// Safe typing C and D, outside the typed row itself: what you type can also
/// show up in other history, in plain text:
/// - a terminal's window title often shows the command line being run
///   ("mysql -pS3cret", "sudo …") and an editor's may show a query;
/// - a search page's address and title carry the search words
///   ("q=divorce lawyer", "divorce lawyer - Google Search"), and an AI chat's
///   title is made from the prompt.
/// So, at ingest, for every kind of record:
/// - titles of Code apps (terminals and editors) go through the same
///   `TypedSecretScrubber` as typed words, always, and so does the place
///   label of every typed row (its window title, `FocusProof.place`);
/// - while search-box typing is on (consent v2 and the Search boxes and AI
///   prompts category), pages of Search & AI sites keep only the site: the
///   address loses its query and fragment and the title is dropped. Those
///   words are the typed words, which are sealed and expire.
/// Pure; the store decides `searchTypingOn`.
public enum TypedHistoryScrub {
    public static let omittedTitle = "[sensitive title omitted]"

    public static func apply(_ e: Evidence, searchTypingOn: Bool) -> Evidence {
        // email-1003 (owner decision 2026-10-03): email subjects are kept, cleaned (Mail's window titles) and never when
        // they read like a code, password, sign-in, security, verification or bank email (`EmailTitle.scrubbed`).
        var out = EmailTitle.scrubbed(e, clean: true)
        if TypingCategories.app(e.bundle)?.category == .code || e.kind == "keyboard.text_input", !out.title.isEmpty, out.title != omittedTitle {
            out.title = TypedSecretScrubber.scrub(out.title).kept ?? omittedTitle
        }
        if searchTypingOn, let parts = URLComponents(string: e.url), let host = parts.host,
           case .category(.searchAndAI) = TypingCategories.site(host: host, path: parts.path.isEmpty ? "/" : parts.path) {
            // fix/chrome-root (live matrix 10-02, row 8b): an address that is already just the site (a Chrome page row
            // is "https://chatgpt.com", its origin, nothing else) stays exactly that. Adding "/" made it
            // "https://chatgpt.com/", which the page row's shape check (`BrowserSafety`: the address is the origin)
            // refuses at read time, so every page row of a Search & AI site (chatgpt.com, claude.ai, gemini, perplexity)
            // was written and then hidden everywhere while search typing was on.
            var siteOnly = URLComponents()
            siteOnly.scheme = parts.scheme; siteOnly.host = parts.host; siteOnly.port = parts.port
            siteOnly.path = parts.percentEncodedPath.isEmpty ? "" : "/"
            out.url = siteOnly.string ?? ""
            out.title = ""
            // page-links-1003: and no page link (the owner's rule: Search & AI sites save the site only).
            out.page = nil
        }
        return out
    }
}
