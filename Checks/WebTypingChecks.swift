#if DAYDREAM_CHROME_TYPING
// Chrome typing build only (private and owner builds; compiled out of the
// public build). Website typing (typing-all SPEC-LATER 4.2, owner decision 3):
// the host-to-category rules with Chrome page history's block list, the
// website focus gate, and the rebuilt burst on TypingSession, driven through
// the real join against a fake Chrome (FakeChromeWorld). Synthetic only: no
// Apple Event, Accessibility call, event tap, Chrome launch or permission request.
import Foundation
import MemoryCore
import PrivacyPolicy

func runWebTypingChecks() throws {
    try checkSiteRules()
    try checkWebGate()
    try checkWebBurst()
    try checkWebRealLatency()
    try checkWebXComposer()
    try checkWebRejoinLoop()
    try checkWebComposeSignals()
    try checkWebComposeWiring()
    #if DAYDREAM_OWNER_TYPING
    try checkWebSearchCapture()
    #endif
    try checkWebSendGrace()
    try checkWebWokenComposers()
    try checkWebLeave()
    try checkWebLightKeys()
    try checkWebUnmarkedBoxes()
    try checkWebXDeepPage()
    try checkWebRefusedKeysCost()
    try checkWebFrameOrder()
    try checkWebFieldHold()
    try checkWebLateKeyKeepsChecked()
    // Review 10:35 (Codex QF-1, test 1): the whole field-hold suite again with boundary recovery on. On the synchronous
    // route it must change nothing: every assertion above holds unchanged.
    WebRig.recoverBracketedBoundaries = true
    defer { WebRig.recoverBracketedBoundaries = false }
    try checkWebFieldHold()   // any failed assertion throws here
    try check(!BrowserTypingBurst().recoversBracketedQuiet, "QF-1 (review 10:35, test 1): the 9de7d09 field-hold suite passes unchanged with recoverBracketedBoundaries on the synchronous route")
    try checkAppCoverageSites()
}

private func checkSiteRules() throws {
    // The host-to-category table, with Chrome page history's common hosts.
    let rules: [(String, TypingSiteRule)] = [
        ("https://www.google.com/search?q=x", .category(.searchAndAI)), ("https://www.google.co.uk/", .category(.searchAndAI)),
        ("https://duckduckgo.com/?q=x", .category(.searchAndAI)), ("https://yandex.com/", .category(.searchAndAI)),
        ("https://chatgpt.com/", .category(.searchAndAI)), ("https://claude.ai/new", .category(.searchAndAI)),
        ("https://gemini.google.com/app", .category(.searchAndAI)), ("https://huggingface.co/chat/", .category(.searchAndAI)),
        ("https://mail.google.com/mail/u/0/", .category(.messagesAndEmail)), ("https://mail.yandex.com/", .category(.messagesAndEmail)),
        ("https://outlook.live.com/mail/", .category(.messagesAndEmail)), ("https://web.whatsapp.com/", .category(.messagesAndEmail)),
        ("https://www.linkedin.com/messaging/thread/1", .category(.messagesAndEmail)), ("https://x.com/messages", .category(.messagesAndEmail)),
        ("https://www.notion.so/workspace", .category(.writing)), ("https://shop.example/search?q=boots", .category(.searchAndAI)),
        // Review F1 (typingfix) and the public-typing review: a messaging site is Messages and email on
        // every page (Messenger on facebook.com/, LinkedIn's overlay on /feed, X's drawer on /home), and
        // the social chat sites (BrowserTypingSites.socialChatHosts) are all among them.
        ("https://example.org/notes", .other), ("https://www.linkedin.com/feed", .category(.messagesAndEmail)), ("https://notclaude.ai/", .other),
        ("https://notfacebook.com/", .other), ("https://box.com/files", .other), ("https://news.ycombinator.com/item?id=1", .other),
        ("https://www.facebook.com/", .category(.messagesAndEmail)),
        ("https://x.com/home", .category(.messagesAndEmail)), ("https://twitter.com/someone", .category(.messagesAndEmail)),
        ("https://www.instagram.com/", .category(.messagesAndEmail)), ("https://www.reddit.com/r/swift/", .category(.messagesAndEmail)),
        ("https://m.facebook.com/search/top?q=x", .category(.messagesAndEmail)), ("https://notlinkedin.com/", .other),
        ("https://docs.google.com/document/d/1/edit", .never), ("ftp://example.org/", .never),
    ]
    for (url, rule) in rules {
        try check(BrowserTypingSites.rule(url: url) == rule, "website typing: \(url) is \(rule)")
    }
    // Review F1: messaging sites, every page, in the full-address rule and the host rule.
    let messaging = ["https://www.facebook.com/", "https://facebook.com/marketplace/item/1", "https://www.facebook.com/search/top?q=boots",
                     "https://www.messenger.com/t/1", "https://www.linkedin.com/feed/", "https://www.linkedin.com/in/someone",
                     "https://x.com/home", "https://twitter.com/home", "https://x.com/search?q=boots", "https://voice.google.com/u/0/messages",
                     "https://voice.google.com/", "https://www.instagram.com/", "https://www.threads.net/", "https://web.snapchat.com/",
                     "https://web.wechat.com/", "https://wx.qq.com/", "https://web.whatsapp.com/", "https://www.whatsapp.com/",
                     "https://discord.com/channels/@me", "https://app.slack.com/client/T1/C1", "https://acme.slack.com/archives/C1",
                     "https://teams.microsoft.com/v2/", "https://teams.live.com/", "https://web.telegram.org/k/", "https://chat.google.com/",
                     "https://messages.google.com/web/conversations", "https://meet.google.com/abc-defg-hij", "https://www.reddit.com/r/swift/",
                     "https://www.twitch.tv/somechannel", "https://bsky.app/", "https://app.element.io/"]
    for url in messaging {
        let host = BrowserTypingSites.host(of: url) ?? ""
        try check(BrowserTypingSites.rule(url: url) == .category(.messagesAndEmail) && BrowserTypingSites.rule(host: host) == .category(.messagesAndEmail),
                  "website typing (review F1): \(url) is Messages and email, by address and by host")
    }
    // The public-typing review's social chat sites are all messaging sites (every page, by host).
    for host in BrowserTypingSites.socialChatHosts {
        try check(BrowserTypingSites.messagingSite(host: host) && BrowserTypingSites.messagingSite(host: "www." + host)
                  && BrowserTypingSites.rule(host: host) == .category(.messagesAndEmail),
                  "website typing: the social chat site \(host) is a messaging site, Messages and email on every page")
    }
    try check(BrowserTypingSites.rule(url: "https://www.facebook.com/login/") == .never && BrowserTypingSites.rule(url: "https://x.com/i/flow/login") == .never,
              "website typing (review F1): a sign-in page on a messaging site stays never")
    let everything = TypedCategoryChoices(searchAndAI: true, writing: true, code: true, messagesAndEmail: true, otherWebsites: true)
    let open = BrowserTypingSiteRules(choices: everything, expanded: true)
    // Blocked sites: every page history default, whatever the choices.
    var refused = 0
    for host in BrowserSiteList.pageDefaults {
        if !open.permits(url: "https://" + host + "/") && !open.permits(url: "https://www." + host + "/notes") && !open.permits(host: host) { refused += 1 }
    }
    try check(refused == BrowserSiteList.pageDefaults.count && refused > 150,
              "website typing: every one of the \(BrowserSiteList.pageDefaults.count) Chrome page history default sites is refused with every switch on")
    for url in ["https://www.plannedparenthood.org/", "https://accounts.google.com/", "https://secure.chase.com/overview", "https://shell.cloud.google.com/",
                "https://example.org/login", "https://example.org/checkout/cart", "https://example.org/#/sign-in", "https://1password.com/",
                "chrome://settings", "file:///Users/x/notes.txt"] {
        try check(!open.permits(url: url), "website typing: refused with every switch on: \(url)")
    }
    for url in ["https://example.org/notes", "https://mail.google.com/mail/u/0/", "https://www.google.com/search?q=boots", "https://claude.ai/new"] {
        try check(open.permits(url: url), "website typing: allowed with every switch on: \(url)")
    }
    // Search, email and chat follow their category switch; Other websites its own.
    // fix/typing-e2e L1: every category starts on, Messages and email included; the checks below turn that switch off.
    let defaults = BrowserTypingSiteRules(choices: TypedCategoryChoices(), expanded: true)
    try check(["https://example.org/notes", "https://www.google.com/search?q=boots", "https://mail.google.com/mail/u/0/", "https://web.whatsapp.com/",
               "https://www.linkedin.com/messaging/thread/1", "https://x.com/home", "https://app.slack.com/client/T1/C1"].allSatisfy { defaults.permits(url: $0) },
              "website typing defaults: every switch starts on (unknown sites, search, email, chat and social sites)")
    let messagesOff = BrowserTypingSiteRules(choices: TypedCategoryChoices(messagesAndEmail: false), expanded: true)
    try check(messagesOff.permits(url: "https://example.org/notes") && messagesOff.permits(url: "https://www.google.com/search?q=boots")
              && !messagesOff.permits(url: "https://mail.google.com/mail/u/0/") && !messagesOff.permits(url: "https://web.whatsapp.com/")
              && !messagesOff.permits(url: "https://www.linkedin.com/messaging/thread/1"),
              "website typing, Messages and email off: unknown sites and search on, email and chat off")
    try check(!messagesOff.permits(url: "https://www.linkedin.com/feed/") && !messagesOff.permits(url: "https://www.facebook.com/")
              && !messagesOff.permits(url: "https://x.com/home") && !messagesOff.permits(host: "linkedin.com")
              && BrowserTypingSiteRules(choices: TypedCategoryChoices(messagesAndEmail: true), expanded: true).permits(url: "https://www.linkedin.com/feed/"),
              "website typing, Messages and email off: a chat pop-up over the LinkedIn, Facebook or X feed stays off with Messages and email off, and follows that switch")
    // Review F1: Messages and email off holds on messaging sites, whatever the page: the
    // full address, the host (the website gate and the store) and a key's field.
    for url in ["https://www.facebook.com/", "https://www.linkedin.com/feed/", "https://x.com/home", "https://voice.google.com/u/0/messages",
                "https://voice.google.com/", "https://twitter.com/home", "https://www.instagram.com/", "https://discord.com/channels/@me"] {
        let host = BrowserTypingSites.host(of: url) ?? ""
        try check(!messagesOff.permits(url: url) && !messagesOff.permits(host: host)
                  && !messagesOff.permits(url: url, field: BrowserTypingFieldLabels(texts: ["Search"], identifiers: [])),
                  "website typing, Messages and email off (review F1): Messages and email off refuses \(url) and its host")
        try check(open.permits(url: url) && open.permits(host: host), "website typing (review F1): Messages and email on allows \(url)")
    }
    // Review F1: message composers on sites outside the categories, by label, placeholder, id or class.
    let composers: [BrowserTypingFieldLabels] = [
        BrowserTypingFieldLabels(texts: ["Type a message"], identifiers: []), BrowserTypingFieldLabels(texts: ["Write a message…"], identifiers: []),
        BrowserTypingFieldLabels(texts: ["Message"], identifiers: []), BrowserTypingFieldLabels(texts: ["", "Aa"], identifiers: []),
        BrowserTypingFieldLabels(texts: ["Message #general"], identifiers: []), BrowserTypingFieldLabels(texts: ["Reply to Sam"], identifiers: []),
        BrowserTypingFieldLabels(texts: ["Start a new message"], identifiers: []), BrowserTypingFieldLabels(texts: ["Compose your message..."], identifiers: []),
        BrowserTypingFieldLabels(texts: ["Post your reply"], identifiers: []), BrowserTypingFieldLabels(texts: ["Type\u{200b} a message"], identifiers: []),
        BrowserTypingFieldLabels(texts: [], identifiers: ["msg-form__contenteditable"]), BrowserTypingFieldLabels(texts: [], identifiers: ["chat-input"]),
        BrowserTypingFieldLabels(texts: [], identifiers: ["dmComposerTextInput"]), BrowserTypingFieldLabels(texts: ["Ask"], identifiers: ["support", "chatbox"])]
    let plain: [BrowserTypingFieldLabels] = [
        BrowserTypingFieldLabels(texts: ["Notes"], identifiers: ["pad"]), BrowserTypingFieldLabels(texts: ["Search"], identifiers: ["q"]),
        BrowserTypingFieldLabels(texts: ["Title"], identifiers: ["post-title"]), BrowserTypingFieldLabels(texts: ["Ask anything"], identifiers: []),
        BrowserTypingFieldLabels(texts: ["Add a comment"], identifiers: ["comment-body"]), BrowserTypingFieldLabels(texts: [], identifiers: [])]
    for field in composers {
        try check(BrowserTypingComposerRules.composer(field) && !messagesOff.permits(url: "https://shop.example.org/help", field: field)
                  && open.permits(url: "https://shop.example.org/help", field: field),
                  "website typing (review F1): a message composer on an Other websites page follows Messages and email: \(field.texts + field.identifiers)")
    }
    for field in plain {
        try check(!BrowserTypingComposerRules.composer(field) && messagesOff.permits(url: "https://shop.example.org/help", field: field),
                  "website typing (review F1): an ordinary field on an Other websites page is not a composer: \(field.texts + field.identifiers)")
    }
    // A Search and AI site keeps its own boxes ("Message ChatGPT" is an AI prompt, Search and AI).
    let prompt = BrowserTypingFieldLabels(texts: ["Message ChatGPT"], identifiers: ["prompt-textarea"])
    try check(messagesOff.permits(url: "https://chatgpt.com/", field: prompt) && !messagesOff.permits(url: "https://www.facebook.com/", field: prompt),
              "website typing (review F1): a composer label never changes a Search and AI site")
    // Nor a page whose address has one (an AI chat path on an ordinary host).
    let chatPage = BrowserTypingFieldLabels(texts: ["Message HuggingChat"], identifiers: ["chat-input"])
    try check(BrowserTypingComposerRules.composer(chatPage) && messagesOff.permits(url: "https://huggingface.co/chat/", field: chatPage)
              && !messagesOff.permits(url: "https://huggingface.co/support", field: chatPage),
              "website typing (review F1): a composer label never changes a page whose address has a category")
    try checkComposerFollowUps(messagesOff: messagesOff, open: open)
    try checkMessagingNeverWidens()
    let noSearch = BrowserTypingSiteRules(choices: TypedCategoryChoices(searchAndAI: false), expanded: true)
    try check(!noSearch.permits(url: "https://www.google.com/search?q=boots") && !noSearch.permits(url: "https://chatgpt.com/")
              && !noSearch.permits(url: "https://shop.example/search?q=boots") && noSearch.permits(url: "https://example.org/notes"),
              "website typing: search and AI off stops search and AI chat pages, not other sites")
    let noOther = BrowserTypingSiteRules(choices: TypedCategoryChoices(otherWebsites: false), expanded: true)
    try check(!noOther.permits(url: "https://example.org/notes") && !noOther.permits(url: "https://www.linkedin.com/messaging/thread/1")
              && noOther.permits(url: "https://claude.ai/new"),
              "website typing: Other websites off stops every site outside the categories (a known page on an unknown site too)")
    // The owner's own list ("Don't record this site" adds to it).
    let mine = BrowserTypingSiteRules(choices: everything, alwaysBlocked: PrivacySettings.sensitiveDomains + ["example.org"], expanded: true)
    try check(!mine.permits(url: "https://example.org/notes") && !mine.permits(url: "https://docs.example.org/") && mine.permits(url: "https://example.net/"),
              "website typing: a site on the owner's list, and its subdomains, are refused")
    // The public gate: nothing, whatever the choices.
    let closed = BrowserTypingSiteRules(choices: everything, expanded: false)
    try check(!closed.permits(url: "https://example.org/notes") && !closed.permits(url: "https://claude.ai/new"),
              "website typing: the closed release gate permits no website")
}

/// typingfix review follow-ups to F1: the composer rule, webmail and the localized labels.
private func checkComposerFollowUps(messagesOff: BrowserTypingSiteRules, open: BrowserTypingSiteRules) throws {
    func field(_ texts: [String], _ ids: [String] = []) -> BrowserTypingFieldLabels { BrowserTypingFieldLabels(texts: texts, identifiers: ids) }
    let composer = field(["Type a message"]), ordinary = field(["Notes"], ["pad"])
    // A search-style query parameter (?q=, ?p=, ?s=, ?st=, ?text=) never turns the composer rule off on an Other websites page.
    for url in ["https://support.example.com/inbox?p=2", "https://support.example.com/inbox?s=open", "https://support.example.com/?q=refund",
                "https://www.upwork.com/ab/messages/rooms/room_1?text=hi", "https://nextdoor.com/messages/?st=1", "https://shop.example.org/results?q=bike"] {
        try check(BrowserTypingSites.rule(url: url) == .category(.searchAndAI) && BrowserTypingSites.rule(url: url, search: false) == .other
                  && !messagesOff.permits(url: url, field: composer) && messagesOff.permits(url: url, field: ordinary) && open.permits(url: url, field: composer),
                  "website typing (review follow-up): a search-style query leaves the composer rule on: \(url)")
    }
    // Webmail and chat that the category table files elsewhere, or doesn't list: Messages and email.
    let mail = ["https://mail.notion.so/inbox", "https://mail.zoho.in/zm/", "https://mail.zoho.com.au/zm/", "https://mail.163.com/",
                "https://mail.126.com/", "https://exmail.qq.com/", "https://webmail.example.org/", "https://mail.example.com/owa/",
                "https://owa.example.com/", "https://email.t-online.de/", "https://outlook.office365.us/mail/", "https://groups.google.com/g/x",
                "https://app.ringcentral.com/messages", "https://app.shortwave.com/", "https://messenger.yandex.ru/", "https://messenger.yandex.com/"]
    for url in mail {
        let host = BrowserTypingSites.host(of: url) ?? ""
        try check(BrowserTypingSites.rule(url: url) == .category(.messagesAndEmail) && BrowserTypingSites.rule(host: host) == .category(.messagesAndEmail)
                  && BrowserTypingSites.messagingSite(host: host),
                  "website typing (review follow-up): \(url) is Messages and email, by address and by host")
        for labels in [field(["To"]), field(["Subject"]), field(["Type a message"], ["message-composer"]), ordinary] {
            try check(!messagesOff.permits(url: url, field: labels), "website typing (review follow-up): Messages and email off refuses \(url): \(labels.texts)")
        }
        try check(!messagesOff.permits(url: url) && !messagesOff.permits(host: host) && open.permits(url: url) && open.permits(host: host),
                  "website typing (review follow-up): \(url) follows Messages and email (on by default, off here)")
    }
    // A webmail app's path on any host, and Yandex Messenger on yandex.ru (a Search and AI host).
    for url in ["https://example.com/owa/", "https://example.org/roundcube/?_task=mail", "https://example.org/SOGo/so/", "https://example.org/webmail/",
                "https://yandex.ru/chat", "https://yandex.ru/chat/#/chats/1", "https://yandex.com/chat"] {
        try check(BrowserTypingSites.rule(url: url) == .category(.messagesAndEmail) && !messagesOff.permits(url: url) && open.permits(url: url),
                  "website typing (review follow-up): a webmail or message page follows Messages and email: \(url)")
    }
    try check(messagesOff.permits(url: "https://example.com/owners/") && messagesOff.permits(url: "https://yandex.ru/search/?text=x")
              && BrowserTypingSites.rule(host: "notmail.example.com") == .other && BrowserTypingSites.rule(host: "mailchimp.com") == .other,
              "website typing (review follow-up): only a whole mail label or path segment is webmail")
    // Writing pages (notion.so) follow the composer rule too; Writing on does not open Notion Mail.
    let writingOnly = BrowserTypingSiteRules(choices: TypedCategoryChoices(searchAndAI: false, writing: true, code: false, messagesAndEmail: false, otherWebsites: false), expanded: true)
    try check(BrowserTypingSites.rule(url: "https://www.notion.so/workspace") == .category(.writing)
              && writingOnly.permits(url: "https://www.notion.so/workspace", field: ordinary) && !writingOnly.permits(url: "https://www.notion.so/workspace", field: field(["Reply…"]))
              && !writingOnly.permits(url: "https://mail.notion.so/inbox") && !writingOnly.permits(url: "https://mail.notion.so/inbox", field: field(["Subject"])),
              "website typing (review follow-up): a message box on a Writing page, and Notion Mail, follow Messages and email")
    // Recipients, subject lines and localized message boxes are composers.
    let more: [BrowserTypingFieldLabels] = [
        field(["Subject"]), field(["Add a subject"]), field(["Bcc"]), field(["To recipients"]), field(["Add recipients"]),
        field(["Type message here"]), field(["Enter message"]), field(["Send an encrypted message…"]), field(["Start a conversation"]),
        field(["Escribe un mensaje"]), field(["Nachricht schreiben"]), field(["Écrire un message"]), field(["Scrivi un messaggio"]),
        field(["Escreva uma mensagem"]), field(["Написать сообщение"]), field(["Typ een bericht"]), field(["メッセージを入力"]), field(["输入消息"]),
        field(["메시지 입력"]), field([], ["message-input"]), field([], ["messageInput"]), field([], ["messagebox"]), field([], ["composebody"])]
    for labels in more {
        try check(BrowserTypingComposerRules.composer(labels) && !messagesOff.permits(url: "https://shop.example.org/help", field: labels)
                  && open.permits(url: "https://shop.example.org/help", field: labels),
                  "website typing (review follow-up): a composer: \(labels.texts + labels.identifiers)")
    }
    // Whole words only: a phrase inside another word is not a composer.
    for labels in [field(["Customer data message"]), field(["Error message"]), field(["Coupon code"], ["promo"]), field(["Dataset name"]),
                   field(["Commit summary"], ["commit-title"]), field(["Formula"])] {
        try check(!BrowserTypingComposerRules.composer(labels) && messagesOff.permits(url: "https://shop.example.org/help", field: labels),
                  "website typing (review follow-up): not a composer (whole words only): \(labels.texts + labels.identifiers)")
    }
}

/// typingfix review follow-up to F1: the messaging rule only ever refuses more. For every choice
/// of the five switches, an address is allowed only when its table rule (the rule before messaging
/// sites) allows it, so turning Messages and email on never opens a page another switch closed.
private func checkMessagingNeverWidens() throws {
    let urls = ["https://www.facebook.com/", "https://www.reddit.com/r/x/comments/1/", "https://www.linkedin.com/feed/", "https://x.com/search?q=secret",
                "https://www.pinterest.com/search/pins/?q=secret", "https://www.tiktok.com/search?q=secret", "https://www.twitch.tv/directory",
                "https://www.reddit.com/search/?q=secret", "https://voice.google.com/", "https://mail.notion.so/inbox", "https://yandex.ru/chat",
                "https://mail.example.com/owa/", "https://www.facebook.com/messages/t/1", "https://mail.google.com/mail/u/0/",
                "https://example.org/notes", "https://www.notion.so/x", "https://www.google.com/search?q=x", "https://claude.ai/new"]
    for url in urls {
        let host = BrowserTypingSites.host(of: url) ?? ""
        let messaging = BrowserTypingSites.rule(url: url) == .category(.messagesAndEmail) || BrowserTypingSites.rule(host: host) == .category(.messagesAndEmail)
        var wider = [Int](), exact = [Int](), allowed = 0
        for mask in 0..<32 {
            let c = TypedCategoryChoices(searchAndAI: mask & 1 != 0, writing: mask & 2 != 0, code: mask & 4 != 0, messagesAndEmail: mask & 8 != 0,
                                         otherWebsites: mask & 16 != 0)
            let rules = BrowserTypingSiteRules(choices: c, expanded: true)
            func on(_ r: TypingSiteRule) -> Bool {
                switch r { case .never: return false; case .category(let x): return c.isOn(x); case .other: return c.otherWebsites }
            }
            let before = on(BrowserTypingSites.tableRule(url: url)) && on(BrowserTypingSites.tableRule(host: host))
            if (rules.permits(url: url) && !before) || (rules.permits(host: host) && !on(BrowserTypingSites.tableRule(host: host))) { wider.append(mask) }
            if rules.permits(url: url) != (before && (!messaging || c.messagesAndEmail)) { exact.append(mask) }
            if rules.permits(url: url) { allowed += 1 }
        }
        try check(wider.isEmpty && exact.isEmpty && allowed > 0,
                  "website typing (review follow-up): with all 32 choices, never wider than the table rule, and a messaging page needs Messages and email on top of it: \(url) \(wider) \(exact)")
    }
    // The reported case: Messages and email on, Other websites or Search and AI off.
    let messagesNoOther = BrowserTypingSiteRules(choices: TypedCategoryChoices(searchAndAI: true, writing: false, code: false, messagesAndEmail: true, otherWebsites: false), expanded: true)
    let messagesNoSearch = BrowserTypingSiteRules(choices: TypedCategoryChoices(searchAndAI: false, writing: false, code: false, messagesAndEmail: true, otherWebsites: true), expanded: true)
    let post = BrowserTypingFieldLabels(texts: ["Create a post"], identifiers: [])
    for url in ["https://www.facebook.com/", "https://www.reddit.com/r/x/comments/1/", "https://www.linkedin.com/feed/", "https://www.twitch.tv/directory"] {
        let host = BrowserTypingSites.host(of: url) ?? ""
        try check(!messagesNoOther.permits(url: url) && !messagesNoOther.permits(host: host) && !messagesNoOther.permits(url: url, field: post),
                  "website typing (review follow-up): Messages and email on, Other websites off: \(url) stays refused")
    }
    for url in ["https://x.com/search?q=secret", "https://www.pinterest.com/search/pins/?q=secret", "https://www.tiktok.com/search?q=secret",
                "https://www.reddit.com/search/?q=secret"] {
        try check(!messagesNoSearch.permits(url: url) && !messagesNoSearch.permits(url: url, field: post),
                  "website typing (review follow-up): Messages and email on, Search and AI off: \(url) stays refused")
    }
    let both = BrowserTypingSiteRules(choices: TypedCategoryChoices(searchAndAI: true, writing: false, code: false, messagesAndEmail: true, otherWebsites: true), expanded: true)
    try check(both.permits(url: "https://www.facebook.com/") && both.permits(url: "https://x.com/search?q=secret") && messagesNoOther.permits(url: "https://mail.google.com/mail/u/0/"),
              "website typing (review follow-up): with both switches on a messaging site types; email hosts need Messages and email only")
}

private func webProof(_ bundle: String = WebTypingGate.bundle, url: String = "https://example.org", role: String = "AXTextArea", subrole: String = "",
                      checkedAt: UInt64 = 1_000) -> FocusProof {
    var p = FocusProof()
    p.bundle = bundle; p.surface = .browser; p.windowID = "101"; p.focusID = UUID().uuidString; p.tabID = "7"
    p.documentID = UUID().uuidString; p.frameID = "windows-1"; p.role = role; p.subrole = subrole; p.url = url; p.checkedAt = checkedAt; p.policyVersion = CapturePolicy().version
    p.secureInput = .no; p.privateMode = .no; p.verified = true; p.fieldStateVerified = true; p.frameAccessible = true; p.navigationStable = true
    return p
}

private func checkWebGate() throws {
    var policy = CapturePolicy(); policy.typedText = true
    let yes: (String) -> Bool = { _ in true }
    let gate = { (p: FocusProof, expanded: Bool, site: (String) -> Bool) in WebTypingGate.typing(p, policy: policy, generation: 0, now: 1_000, expanded: expanded, site: site) }
    try check(gate(webProof(), true, yes).outcome == .allowed, "website gate: a proven Chrome text field on an allowed site passes")
    try check(gate(webProof(), false, yes).reason == .browserTypingOff, "website gate: the closed release gate refuses every website")
    try check(CaptureGate.typing(webProof(), policy: policy, generation: 0, now: 1_000).reason == .browserTypingOff,
              "website gate: the native typing gate still refuses every browser")
    try check(gate(webProof("com.apple.Notes"), true, yes).outcome != .allowed && gate(webProof("com.google.Chrome.canary"), true, yes).outcome != .allowed,
              "website gate: only Google Chrome stable")
    try check(gate(webProof(url: "https://example.org/notes"), true, yes).outcome != .allowed && gate(webProof(url: "https://example.org?q=1"), true, yes).outcome != .allowed,
              "website gate: only an origin, never a path or query")
    try check(gate(webProof(subrole: "AXSecureTextField"), true, yes).outcome != .allowed && gate(webProof(role: "AXButton"), true, yes).outcome != .allowed,
              "website gate: password fields and non-text roles are refused")
    // fix/web-textbox: an editable combo box (search box) the join proved passes; secure and other kinds don't.
    try check(gate(webProof(role: "AXComboBox"), true, yes).outcome == .allowed && gate(webProof(role: "AXTextField"), true, yes).outcome == .allowed,
              "website gate: a proven text field or editable combo box (search box) passes")
    // A password `<input role=combobox>` reports AXComboBox with no secure subrole in Chromium main: the guard
    // is macOS secure input, which Chrome turns on for any password input (the join refuses it, and so does the
    // gate). A combo box that does report the secure subrole is refused too, but that is not the guard.
    var secureCombo = webProof(role: "AXComboBox"); secureCombo.secureInput = .yes
    var unknownSecure = webProof(role: "AXComboBox"); unknownSecure.secureInput = .unknown
    try check(gate(secureCombo, true, yes).outcome != .allowed && gate(unknownSecure, true, yes).outcome != .allowed,
              "website gate: a password <input role=combobox> (AXComboBox, no secure subrole) under macOS secure input, or with secure input unproven, is refused")
    try check(gate(webProof(role: "AXComboBox", subrole: "AXSecureTextField"), true, yes).outcome != .allowed
              && gate(webProof(role: "AXSecureTextField"), true, yes).outcome != .allowed && gate(webProof(role: "AXGroup"), true, yes).outcome != .allowed
              && gate(webProof(role: "AXWebArea"), true, yes).outcome != .allowed && gate(webProof(role: ""), true, yes).outcome != .allowed,
              "website gate: a combo box reporting a secure subrole (not the guard) and unknown kinds of focus are refused")
    try check(gate(webProof(), true, { _ in false }).reason == .excludedSite, "website gate: a site the person doesn't allow is refused")
    var off = policy; off.typedText = false
    try check(WebTypingGate.typing(webProof(), policy: off, generation: 0, now: 1_000, expanded: true, site: yes).reason == .typingOff,
              "website gate: typing off refuses")
    var privateProof = webProof(); privateProof.privateMode = .yes
    try check(gate(privateProof, true, yes).outcome != .allowed, "website gate: a private context is refused")
}

/// A website typing rig: the rebuilt burst, the real join, a fake Chrome.
private final class WebRig {
    /// Review 10:35 (QF-1 test 1): run a suite with boundary recovery on (the synchronous route must ignore it).
    static var recoverBracketedBoundaries = false
    let w = FakeChromeWorld()
    let join = BrowserTypingJoin<FakeAXNode>()
    let sites: BrowserTypingSiteRules
    let burst: BrowserTypingBurst
    var policy = CapturePolicy()
    var reads = 0, joins = 0, lights = 0, holdChecks = 0
    /// Review G51: keys of an open burst ask the light per-key check first.
    var useLight = false
    var rows: [(text: String, url: String, role: String)] = []
    init(choices: TypedCategoryChoices = TypedCategoryChoices(), url: String = "https://notes.example.org/pad/7?view=1") {
        sites = BrowserTypingSiteRules(choices: choices, expanded: true)
        burst = BrowserTypingBurst(sites: sites)
        burst.recoverBracketedBoundaries = Self.recoverBracketedBoundaries
        policy.typedText = true; policy.version = 3
        // A notes box (the fake world's default field is Gmail's "Message Body").
        w.field.labels = BrowserTypingFieldLabels(texts: ["Notes"], identifiers: ["pad"])
        page(url)
    }
    func page(_ url: String) { w.windows[0].url = url; w.web.url = url }
    func result() -> BrowserTypingJoinResult {
        joins += 1
        return join.join(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: sites.blockList,
                         alwaysBlocked: sites.alwaysBlocked, sites: sites.permits(url:), field: sites.permits(url:field:))
    }
    /// The click join (`anyFocus`), as at a click, a chorded Return or the settle.
    func pageResult() -> BrowserTypingJoinResult {
        joins += 1
        return join.join(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: sites.blockList,
                         alwaysBlocked: sites.alwaysBlocked, sites: sites.permits(url:), anyFocus: true)
    }
    func lightResult() -> BrowserTypingJoinResult? {
        guard useLight else { return nil }
        lights += 1
        return join.light(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: sites.blockList,
                          alwaysBlocked: sites.alwaysBlocked, sites: sites.permits(url:), field: sites.permits(url:field:))
    }
    /// Codex 07:10 (field hold): the route's `fieldHeld` (the witness's `holdsRefusedBox`).
    func heldResult() -> Bool? {
        holdChecks += 1
        return join.holdsRefusedBox(accessibility: w.access)
    }
    /// The route's settle (review G12, round 1): the full join first; the
    /// click join only right after a full join denied `.field`. `failPage`:
    /// that click join meets an Apple Event that times out.
    @discardableResult func settle(secure: Bool = false, failPage: Bool = false) -> TypingOutcome? {
        let full = secure ? nil : result()
        var page: BrowserTypingJoinResult?
        if !secure, burst.wantsPageJoin(full, now: w.clock) {
            if failPage { w.failing = ["bounds"] }
            page = pageResult()
            w.failing = []
        }
        return burst.resolveParked(full, page: page, secureInput: secure, now: w.clock, policy: policy, write: write)
    }
    var commits: [TypingCommit] = []
    func write(_ c: TypingCommit) -> Bool { rows.append((c.text, c.proof.url, c.proof.role)); commits.append(c); return true }
    /// fix/chrome-x: simulated main-thread time spent inside the burst (joins, light checks, holds), and keys.
    var mainNs: UInt64 = 0, keys = 0
    @discardableResult func key(_ intent: KeyIntent, _ text: String = "") -> BrowserTypingStep {
        let typed = w.clock; w.clock += 2_000_000
        let before = w.clock; defer { mainNs += w.clock - before; keys += 1 }
        return burst.key(intent, join: result, light: lightResult, held: heldResult, typedAt: typed, now: { self.w.clock }, policy: policy,
                         read: { self.reads += 1; return text }, write: write)
    }
    func type(_ s: String) { for c in s { key(.insert(nil), String(c)); w.clock += 80_000_000 } }
    var words: [String] { rows.map(\.text) }
}

/// fix/chrome-root (2026-10-02, live test of build 20261002150428: 34 keys in Google's search box, 0 rows): website
/// typing end to end at the Apple Event latency measured on the owner's Mac (12.5 ms median, 20 ms slow tenth), with
/// three Chrome windows and the light per-key check, as the shipped route runs it. Before the fix every join was
/// refused, so nothing was read or saved.
private func checkWebRealLatency() throws {
    for tick: UInt64 in [12_500_000, 20_000_000] {
        let r = WebRig(url: "https://www.google.com/"); r.useLight = true; r.w.tick = tick
        r.w.windows[0].name = "Google"; r.w.window.title = "Google - Google Chrome"
        r.w.field.role = "AXTextArea"; r.w.field.labels = BrowserTypingFieldLabels(texts: ["Search"], identifiers: ["APjFqb", "gLFyf"])
        r.w.addWindow("31", mode: "normal", front: false, bounds: ChromeBounds(left: 100, top: 80, right: 900, bottom: 700), name: "Other", url: "https://example.org/")
        r.w.addWindow("32", mode: "normal", front: false, bounds: ChromeBounds(left: 140, top: 120, right: 940, bottom: 740), name: "Docs", url: "https://example.org/d")
        r.type("weather tomorrow in austin")
        _ = r.key(.submit)
        try check(r.words == ["weather tomorrow in austin"] && r.rows.first?.url == "https://www.google.com" && r.lights > 0,
                  "website typing (fix/chrome-root): Google search at \(tick / 1_000_000) ms per Apple Event, three windows: saved with the site only (\(r.words), lights \(r.lights))")
    }
    // Negative control: a Chrome slower than the budget still saves nothing and reads no key.
    let slow = WebRig(url: "https://www.google.com/"); slow.w.tick = 40_000_000
    slow.type("never kept"); _ = slow.key(.submit)
    try check(slow.rows.isEmpty && slow.reads == 0, "website typing (fix/chrome-root): 40 ms Apple Events (joins over budget): nothing read or saved")
}


/// fix/chrome-x (live test 10-03 of build 20261002220001: a reply typed and posted on x.com, `join.window` from the first
/// key, nothing saved). Chrome's Accessibility window title is the active tab's accessible label, which adds the tab's
/// state after the page title (" - Audio playing", " - Pinned", " - High memory usage - 1.2 GB"...); the Apple Events
/// window name never has it, so the join matched no window. Fixtures: an X reply on a status page and in the reply
/// modal (a route change while typing), an unread count that changes while typing, the same states on Reddit, Outlook
/// and ChatGPT, and the controls that keep the match strict.
private func checkWebXComposer() throws {
    func rig(_ url: String, name: String, title: String, label: String) -> WebRig {
        let r = WebRig(url: url); r.useLight = true
        r.w.windows[0].name = name; r.w.window.title = title
        r.w.field.role = "AXTextArea"; r.w.field.labels = BrowserTypingFieldLabels(texts: [label], identifiers: [])
        return r
    }
    let post = "Ada on X: \"launch day notes\" / X"
    // Each tab state Chrome adds to the window's accessible title, one at a time and two together.
    for state in [" - Audio playing", " - Video playing in picture-in-picture mode", " - Pinned", " - High memory usage - 1.2 GB",
                  " - Memory usage - 312 MB", " - Audio muted - Pinned", ""] {
        let r = rig("https://x.com/ada/status/1839", name: post, title: post + state + " - Google Chrome - Sam", label: "Post your reply")
        r.type("great point thanks"); _ = r.key(.submit)
        try check(r.words == ["great point thanks"] && r.rows.first?.url == "https://x.com",
                  "website typing (fix/chrome-x): an X reply on a status page is saved when Chrome's window title carries the tab state '\(state)' (\(r.words))")
    }
    // The root cause seen on the owner's Chrome (harness titlewatch, 10-03): while the tab plays sound, Chrome's Apple
    // Events window name ends with " \u{1F50A}" and the Accessibility title doesn't (or carries " - Audio playing").
    for (name, title) in [(post + " \u{1F50A}", post + " - Google Chrome - Sam"), (post + " \u{1F50A}", post + " - Audio playing - Google Chrome - Sam"),
                          (post + " \u{1F507}", post + " - Audio muted - Google Chrome")] {
        let r = rig("https://x.com/ada/status/1839", name: name, title: title, label: "Post your reply")
        r.type("great point thanks"); _ = r.key(.submit)
        try check(r.words == ["great point thanks"] && r.rows.first?.url == "https://x.com",
                  "website typing (fix/chrome-x): an X reply on a post playing sound (Chrome's speaker in the window name) is saved (\(r.words))")
    }
    for name in [post + " \u{1F50A}\u{1F50A}", post + "\u{1F50A}", post + " \u{1F600}"] {
        try check(!ChromeWindowMatching.titleMatches(axTitle: post + " - Google Chrome", aeName: name),
                  "website typing (fix/chrome-x): only one spaced media indicator is set aside from a window name")
    }
    try check(WebTypingTitle.clean(post + " \u{1F50A}", url: "https://x.com/ada/status/1839", origin: "https://x.com") == post,
              "website typing (fix/chrome-x): the speaker never reaches the row's place")
    // Strict controls: anything else between the name and " - Google Chrome", or a title that isn't the name, matches no window.
    // claude/typing-1004 (owner laptop 10/04, public 0.1.4: every X reply and Google search box join refused `window`):
    // the title decides only among several windows with the focused window's bounds. With one, its bounds bind it and
    // the reply is saved, site only; with a same-bounds window elsewhere, nothing is saved, as before.
    for title in [post + " - Something else - Google Chrome", post + " - Audio playing", post + " - Audio playing extra - Google Chrome",
                  post + " - Memory usage - lots - Google Chrome", "Ada on X: \"launch day\" / X - Audio playing - Google Chrome"] {
        try check(!ChromeWindowMatching.titleMatches(axTitle: title, aeName: post), "website typing (fix/chrome-x): a window title that is not the name plus Chrome's own states matches no name")
        let r = rig("https://x.com/ada/status/1839", name: post, title: title, label: "Post your reply")
        r.type("kept on its bounds"); _ = r.key(.submit)
        try check(r.words == ["kept on its bounds"] && r.rows.allSatisfy { $0.url == "https://x.com" },
                  "website typing (claude/typing-1004): one window with those bounds, a title of a shape the rule doesn't know: the X reply is saved, site only (\(r.words))")
        let twin = rig("https://x.com/ada/status/1839", name: post, title: title, label: "Post your reply")
        twin.w.addWindow("202", mode: "normal", front: false, bounds: FakeChromeWorld.bounds, name: "Elsewhere", url: "https://other.example.org/", onThisSpace: false)
        twin.type("never kept"); _ = twin.key(.submit)
        try check(twin.rows.isEmpty && twin.result().denial == .window, "website typing (fix/chrome-x): with a same-bounds window elsewhere, the title still decides: nothing saved")
    }
    try check(!ChromeWindowMatching.titleMatches(axTitle: post + " - Audio playing - Audio playing - Audio playing - Audio playing - Audio playing - Google Chrome", aeName: post),
              "website typing (fix/chrome-x): at most four tab states are skipped")
    // The reply modal: Reply opens /compose/post and retitles the tab, then the reply is typed there.
    var r = rig("https://x.com/ada/status/1839", name: post, title: post + " - Audio playing - Google Chrome - Sam", label: "Post your reply")
    r.page("https://x.com/compose/post"); r.w.windows[0].name = "Compose new post / X"; r.w.window.title = "Compose new post / X - Audio playing - Google Chrome - Sam"
    r.type("replying in the modal"); _ = r.key(.submit)
    try check(r.words == ["replying in the modal"] && r.rows.first?.url == "https://x.com",
              "website typing (fix/chrome-x): an X reply typed in the reply modal (/compose/post) is saved, site only (\(r.words))")
    // The route changes WHILE typing: the unfinished words of the old page are never saved under the new one (the burst
    // fails closed: the old unit and the key that met the change are dropped), and typing on in the modal is saved.
    r = rig("https://x.com/ada/status/1839", name: post, title: post + " - Audio playing - Google Chrome - Sam", label: "Post your reply")
    r.type("first half ")
    r.page("https://x.com/compose/post"); r.w.windows[0].name = "Compose new post / X"; r.w.window.title = "Compose new post / X - Audio playing - Google Chrome - Sam"
    r.w.clock += BrowserTypingTiming.quietNanoseconds
    r.type("second half"); _ = r.key(.submit)
    try check(!r.words.joined().contains("first") && r.words.joined().contains("cond half") && r.rows.allSatisfy { $0.url == "https://x.com" },
              "website typing (fix/chrome-x): a route change while typing: words after it are saved on x.com, none from before it (\(r.words))")
    // An unread count that changes while typing ("(3) Home / X" -> "(4) Home / X", both reads at once): the burst's
    // light per-key check reads no title, so every word is saved.
    r = rig("https://x.com/home", name: "(3) Home / X", title: "(3) Home / X - Google Chrome - Sam", label: "Post text")
    r.type("count moves ")
    r.w.windows[0].name = "(4) Home / X"; r.w.window.title = "(4) Home / X - Google Chrome - Sam"
    r.type("while i type"); _ = r.key(.submit)
    try check(r.words == ["count moves while i type"] && r.rows.first?.url == "https://x.com",
              "website typing (fix/chrome-x): an X unread count that changes while typing loses nothing (\(r.words))")
    // Accessibility one count behind the Apple Events name at a burst's first key: that full join matches no window
    // (the key is dropped, fail closed); once they agree the next burst is saved.
    // claude/typing-1004: with a same-bounds window elsewhere the title decides (one window: its bounds bind it, below).
    r = rig("https://x.com/home", name: "(5) Home / X", title: "(4) Home / X - Google Chrome - Sam", label: "Post text")
    r.w.addWindow("202", mode: "normal", front: false, bounds: FakeChromeWorld.bounds, name: "Elsewhere", url: "https://other.example.org/", onThisSpace: false)
    r.type("x")
    try check(r.rows.isEmpty && r.result().denial == .window, "website typing (fix/chrome-x): an Accessibility title one unread count behind matches no window")
    r.w.window.title = "(5) Home / X - Google Chrome - Sam"
    r.w.clock += BrowserTypingTiming.quietNanoseconds
    r.type("and after"); _ = r.key(.submit)
    try check(r.words == ["and after"] && r.rows.first?.url == "https://x.com",
              "website typing (fix/chrome-x): once the counts agree the typing is saved (\(r.words))")
    let lagging = rig("https://x.com/home", name: "(5) Home / X", title: "(4) Home / X - Google Chrome - Sam", label: "Post text")
    lagging.type("one window"); _ = lagging.key(.submit)
    try check(lagging.words == ["one window"] && lagging.rows.first?.url == "https://x.com",
              "website typing (claude/typing-1004): one window, an Accessibility title one unread count behind: saved on its bounds, site only (\(lagging.words))")
    // The same tab states on Reddit, Outlook and ChatGPT composers.
    for (url, name, label, origin) in [("https://www.reddit.com/r/test/comments/1/t/", "t : r/test", "Join the conversation", "https://www.reddit.com"),
                                       ("https://outlook.office.com/mail/deeplink/compose", "Mail - Ada - Outlook", "Message body", "https://outlook.office.com"),
                                       ("https://chatgpt.com/", "ChatGPT", "Ask ChatGPT", "https://chatgpt.com")] {
        for state in [" - Audio playing", " - High memory usage - 2.1 GB", ""] {
            let c = rig(url, name: name, title: name + state + " - Google Chrome - Sam", label: label)
            c.type("hello there friend"); _ = c.key(.submit)
            try check(c.words == ["hello there friend"] && c.rows.first?.url == origin,
                      "website typing (fix/chrome-x): \(origin) composer saved with the tab state '\(state)' (\(c.words))")
        }
    }
}


/// fix/chrome-x (perf evidence 10-03: during the refused X reply MacMem ran 28 full joins in 18 s, ~80-135 ms each on
/// the main thread). A page refusal that stays true holds the episode: no new join while the same window, field and
/// window title keep focus, at most `episodeHoldNanoseconds`; any change joins at once. Plus the benchmark: simulated
/// main-thread time per key at the owner's Apple Event latency (12.5 ms each, 0.1 ms per Accessibility read).
/// fix/chrome-x (compose signals for claude/messages-1003): a Chrome composer's gesture, value at submit, reply,
/// @handle and reply context, and what a re-read after the gesture confirms. Nothing of the address but its compose
/// kind, and nothing of the labels but the reply phrases.
private func checkWebComposeSignals() throws {
    func proof(_ url: String, name: String, label: [String], role: String = "AXTextArea") -> (WebRig, BrowserTypingJoinProof?) {
        let r = WebRig(url: url)
        r.w.windows[0].name = name; r.w.window.title = name + " - Google Chrome"
        r.w.field.role = role; r.w.field.labels = BrowserTypingFieldLabels(texts: label, identifiers: [])
        return (r, r.result().proof)
    }
    let post = "Ada on X: \"Small tools beat big frameworks every time\" / X"
    // A reply on a post's page, by the Reply button.
    var (r, p) = proof("https://x.com/ada/status/1839", name: "(3) " + post, label: ["Post your reply", "Write something nice"])
    try check(p?.composeRoute == "/ada/status/_" && p?.replyLabels == ["Post your reply"],
              "compose signals (fix/chrome-x): an X post page's route is kept as its kind only (no ID, no query) and only the reply label is kept")
    try check(BrowserComposeRoute.path(url: "https://x.com/ada/status/1839/photo/1?s=20#top") == "/ada/status/_"
              && BrowserComposeRoute.path(url: "https://x.com/i/status/1839") == "" && BrowserComposeRoute.path(url: "https://mail.google.com/mail/u/0/#inbox") == "",
              "compose signals (fix/chrome-x): a route keeps its compose kind only")
    var s = p.flatMap { BrowserComposeSignals.submit(proof: $0, gesture: "button", control: "reply", valueAtSubmit: "agreed") }
    try check(s?.service == "X" && s?.reply == true && s?.handle == "ada" && s?.contextAuthor == "Ada"
              && s?.contextExcerpt == "Small tools beat big frameworks every time" && s?.gesture == "button" && s?.control == "reply"
              && s?.valueAtSubmit == "agreed" && s?.path == "/ada/status/_",
              "compose signals (fix/chrome-x): an X reply: the Reply click, the value at submit, the @handle, and the post's author and text from the title (\(String(describing: s)))")
    // The compose modal: "Replying to @h" in the composer's labels names the handle; the timeline's title is no context.
    (r, p) = proof("https://x.com/compose/post", name: "Home / X", label: ["Post your reply", "Replying to @grace_h"])
    s = p.flatMap { BrowserComposeSignals.submit(proof: $0, gesture: "commandReturn") }
    try check(s?.reply == true && s?.handle == "grace_h" && s?.contextAuthor == nil && s?.contextExcerpt == nil && s?.path == "/compose/post" && s?.control == nil,
              "compose signals (fix/chrome-x): X's reply modal: a reply to @grace_h, Command-Return, no context from the timeline's title")
    // A new post from Home: not a reply, no handle, no context.
    (r, p) = proof("https://x.com/home", name: "Home / X", label: ["Post text"])
    s = p.flatMap { BrowserComposeSignals.submit(proof: $0, gesture: "button", control: "post") }
    try check(s?.reply == false && s?.handle == nil && s?.contextExcerpt == nil && s?.path == "/home",
              "compose signals (fix/chrome-x): a new X post from Home is not a reply")
    // Reddit: the community and the post's title.
    (r, p) = proof("https://www.reddit.com/r/swift/comments/1abc/why_async_let/?utm=x", name: "Why does async let copy? : r/swift", label: ["Add a comment"])
    s = p.flatMap { BrowserComposeSignals.submit(proof: $0, gesture: "return") }
    try check(p?.composeRoute == "/r/swift/comments/_" && s?.service == "Reddit" && s?.community == "swift" && s?.reply == true
              && s?.contextExcerpt == "Why does async let copy?",
              "compose signals (fix/chrome-x): a Reddit comment: r/swift and the post's title (\(String(describing: s)))")
    // Webmail replies: the subject (the sender is not in the title or the composer's labels).
    (r, p) = proof("https://mail.google.com/mail/u/0/#inbox/FMfcgz", name: "Re: Pricing - sam@example.com - Gmail", label: ["Message Body"])
    s = p.flatMap { BrowserComposeSignals.submit(proof: $0, gesture: "commandReturn") }
    try check(s?.service == "Gmail" && s?.subject == "Re: Pricing" && s?.reply == true && s?.contextExcerpt == "Re: Pricing" && s?.contextAuthor == nil,
              "compose signals (fix/chrome-x): a Gmail reply: the subject where the page title gives it (\(String(describing: s)))")
    (r, p) = proof("https://outlook.live.com/mail/0/inbox/id/AQMk", name: "Re: Budget - Sam - Outlook", label: ["Message body"])
    s = p.flatMap { BrowserComposeSignals.submit(proof: $0, gesture: "commandReturn") }
    try check(s?.service == "Outlook" && s?.subject == "Re: Budget" && s?.reply == true && s?.contextAuthor == nil, "compose signals (fix/chrome-x): an Outlook reply: its subject, never a sender (\(String(describing: s)))")
    // A gesture the compose model doesn't know, or a click with no proven control: nothing.
    (r, p) = proof("https://x.com/home", name: "Home / X", label: ["Post text"])
    try check(p.flatMap { BrowserComposeSignals.submit(proof: $0, gesture: "click") } == nil && p.flatMap { BrowserComposeSignals.submit(proof: $0, gesture: "button") } == nil,
              "compose signals (fix/chrome-x): only Return, Command-Return and a proven Post/Reply click are gestures")
    // Confirmation after the gesture: Accessibility only (no Apple Event), the route by its compose kind.
    func confirm(_ url: String, after: (WebRig) -> Void, value: String? = "") throws -> String? {
        let (r, p) = proof(url, name: "Home / X", label: ["Post your reply"])
        guard p != nil, let before = r.join.composeSnapshot(accessibility: r.w.access, value: { _ in "agreed" }) else { return "no proof" }
        after(r)
        let events = r.w.log.count
        guard let now = r.join.composeSnapshot(accessibility: r.w.access, value: { _ in value }) else { return "no snapshot" }
        guard !r.w.log[events...].contains(where: { $0.hasPrefix("ae:") }) else { return "apple event" }
        return BrowserComposeSignals.confirmation(atSubmit: before, now: now)
    }
    try check(try confirm("https://x.com/compose/post", after: { $0.page("https://x.com/ada/status/1839") }) == "routeChanged",
              "compose signals (fix/chrome-x): the reply modal's route left after the click: routeChanged")
    try check(try confirm("https://x.com/home", after: { $0.w.field.parent = nil }) == "composerClosed",
              "compose signals (fix/chrome-x): the composer gone from the page: composerClosed")
    try check(try confirm("https://x.com/home", after: { _ in }) == "fieldCleared",
              "compose signals (fix/chrome-x): the composer emptied in place: fieldCleared")
    try check(try confirm("https://x.com/home", after: { _ in }, value: "agreed") == nil && confirm("https://x.com/home", after: { _ in }, value: nil) == nil,
              "compose signals (fix/chrome-x): a composer that still holds the words, or can't be read, confirms nothing")
    try check(try confirm("https://x.com/home", after: { $0.page("https://x.com/home") }) == "fieldCleared",
              "compose signals (fix/chrome-x): the same route is not a route change")
    _ = r
}

/// claude/int-1003: the compose signals wired into compose-send/v1 (`WebTypingRoute.write` stores the identity,
/// `confirmComposerSend` re-reads and calls `markComposerSent`): the identity a row stores, which gestures are re-read,
/// when, and what each re-read confirms per surface.
private func checkWebComposeWiring() throws {
    func proof(_ url: String, name: String, label: [String]) -> BrowserTypingJoinProof? {
        let r = WebRig(url: url)
        r.w.windows[0].name = name; r.w.window.title = name + " - Google Chrome"
        r.w.field.role = "AXTextArea"; r.w.field.labels = BrowserTypingFieldLabels(texts: label, identifiers: [])
        return r.result().proof
    }
    let post = "Ada on X: \"Small tools beat big frameworks every time\" / X"
    let x = proof("https://x.com/ada/status/1839", name: post, label: ["Post your reply"]).flatMap { BrowserComposeSignals.submit(proof: $0, gesture: "commandReturn") }
    let xID = x?.identity(surface: "social")
    try check(xID?.0.handle == "ada" && xID?.0.service == "X" && xID?.1 == ComposeContext(author: "Ada", excerpt: "Small tools beat big frameworks every time"),
              "compose wiring: an X reply stores the @handle and the replied-to post's author and excerpt (\(String(describing: xID)))")
    var unit = TypedUnitProvenance(runID: "r", part: 0, sealReason: "submitChord", startedAt: "2026-10-03T12:00:00Z", keys: 3, edits: 0, withheld: 0)
    if let xID { unit.apply(destination: xID.0, context: xID.1) }
    let line = ComposeSend.line(ComposeSend.outcome(surface: "social", field: "textArea", send: "detected", sendBy: "commandReturn",
                                                    destination: { var d = unit.composeDestination; d.service = "X"; return d }(), context: unit.composeContext))
    try check(line == "Replied to Ada's post on X" && ComposeSend.contextLine(unit.composeContext) == "on: \u{201C}Small tools beat big frameworks every time\u{201D}",
              "compose wiring: the stored facts read back as the card's line and its muted context (\(line))")
    let reddit = proof("https://www.reddit.com/r/swift/comments/1abc/why/", name: "Why does async let copy? : r/swift", label: ["Add a comment"])
        .flatMap { BrowserComposeSignals.submit(proof: $0, gesture: "commandReturn") }?.identity(surface: "social")
    try check(reddit?.0.community == "swift" && reddit?.1.excerpt == "Why does async let copy?", "compose wiring: a Reddit comment stores r/swift and the post's title")
    let gmail = proof("https://mail.google.com/mail/u/0/#inbox/FMfcgz", name: "Re: Pricing - sam@example.com - Gmail", label: ["Message Body"])
        .flatMap { BrowserComposeSignals.submit(proof: $0, gesture: "commandReturn") }?.identity(surface: "email", recipient: "Sam")
    try check(gmail?.0.name == "Sam" && gmail?.0.subject == "Pricing" && gmail?.1.excerpt == "Pricing" && gmail?.1.author == nil,
              "compose wiring: a Gmail reply through email-compose/v1: the To-field rule's name, the bare subject, answering it (\(String(describing: gmail)))")
    let home = proof("https://x.com/home", name: "Home / X", label: ["Post text"]).flatMap { BrowserComposeSignals.submit(proof: $0, gesture: "commandReturn") }?.identity(surface: "social")
    try check(home?.0.handle == nil && home?.1.isEmpty == true, "compose wiring: a new X post stores no handle and no context")
    try check(proof("https://example.com/form", name: "Form", label: ["Notes"]).flatMap { BrowserComposeSignals.submit(proof: $0, gesture: "return") }?.identity(surface: "other") == nil,
              "compose wiring: another site stores no identity")
    // Which gestures are re-read.
    try check(BrowserComposeSignals.gesture(seal: "submit") == .returnKey && BrowserComposeSignals.gesture(seal: "submitChord") == .commandReturn
              && BrowserComposeSignals.gesture(seal: "pointer") == nil && BrowserComposeSignals.gesture(seal: "idle") == nil,
              "compose wiring: only Return and Command-Return seals are gestures here (a Post click is the Post check's)")
    try check(BrowserComposeSignals.confirms(surface: "social", field: "textArea", gesture: .commandReturn)
              && !BrowserComposeSignals.confirms(surface: "social", field: "textArea", gesture: .returnKey)
              && BrowserComposeSignals.confirms(surface: "email", field: "body", gesture: .commandReturn)
              && !BrowserComposeSignals.confirms(surface: "email", field: "body", gesture: .returnKey)
              && BrowserComposeSignals.confirms(surface: "chat", field: "message", gesture: .returnKey)
              && !BrowserComposeSignals.confirms(surface: "social", field: "search", gesture: .commandReturn)
              && !BrowserComposeSignals.confirms(surface: "search", field: "search", gesture: .returnKey),
              "compose wiring: Return on a social site or in webmail is a new line (never re-read); a search box never")
    try check(BrowserComposeSignals.checks(surface: "social") == [0.12, 0.35, 0.8] && BrowserComposeSignals.checks(surface: "email") == EmailComposeAdapter.closeChecks,
              "compose wiring: re-reads at 0.12, 0.35 and 0.8 s; webmail until the compose's close window")
    // What a re-read confirms, per surface.
    func snap(present: Bool = true, empty: Bool? = false, path: String = "/home") -> BrowserComposeSnapshot {
        BrowserComposeSnapshot(fieldPresent: present, fieldFocused: present, valueEmpty: present ? empty : nil, origin: "https://x.com", path: path, urlRead: true)
    }
    let before = snap()
    try check(BrowserComposeSignals.confirm(surface: "social", gesture: .commandReturn, before: before, after: snap(empty: true), elapsed: 0.12) == .fieldCleared
              && BrowserComposeSignals.confirm(surface: "social", gesture: .commandReturn, before: before, after: snap(present: false), elapsed: 0.35) == .composerClosed
              && BrowserComposeSignals.confirm(surface: "social", gesture: .commandReturn, before: before, after: snap(path: "/ada/status/_"), elapsed: 0.8) == .routeChanged
              && BrowserComposeSignals.confirm(surface: "social", gesture: .commandReturn, before: before, after: snap(), elapsed: 0.8) == nil
              && BrowserComposeSignals.confirm(surface: "social", gesture: .commandReturn, before: before, after: snap(empty: true), elapsed: 2.0) == nil,
              "compose wiring: X/Reddit: cleared, closed or the route left within 0.8 s confirms; words still there or a late read never")
    try check(BrowserComposeSignals.confirm(surface: "email", gesture: .commandReturn, before: before, after: snap(empty: true), elapsed: 0.15) == nil
              && BrowserComposeSignals.confirm(surface: "email", gesture: .commandReturn, before: before, after: snap(present: false), elapsed: 0.9) == .composerClosed
              && BrowserComposeSignals.confirm(surface: "email", gesture: .commandReturn, before: before, after: snap(present: false), elapsed: 2.5) == nil
              && BrowserComposeSignals.confirm(surface: "email", gesture: .returnKey, before: before, after: snap(present: false), elapsed: 0.4) == nil,
              "compose wiring: webmail: only the compose closing within its window confirms Command-Return; an emptied body proves nothing")
    let reader = BrowserEmailComposeReader(title: "Re: Pricing")
    try check(reader.composeStillOpen() && reader.composeSnapshot()?.title == "Re: Pricing" && reader.composeSnapshot()?.fields.isEmpty == true
              && !BrowserEmailComposeReader(title: "", open: { false }).composeStillOpen(),
              "compose wiring: the webmail reader reads the page title only (no fields); an unread compose counts as open")
}

/// fix/chrome-x2 (owner, 2026-10-03): a Google search typed in Chrome's address bar saved only the site-only page row.
/// The address bar is a toolbar field with no web page above it (the join refuses it `frame`, as it must: it holds
/// addresses); the search is read instead from the results page's own address by page history.
#if DAYDREAM_OWNER_TYPING
private func checkWebSearchCapture() throws {
    // The query, only from a search engine's results page.
    let cases: [(String, (String, String)?)] = [
        ("https://www.google.com/search?q=red+boots+size+10&oq=red+boots&sourceid=chrome&ie=UTF-8", ("Google", "red boots size 10")),
        ("https://www.google.co.uk/search?q=caf%C3%A9%20near%20me", ("Google", "café near me")),
        ("https://www.bing.com/search?q=swift+async+let", ("Bing", "swift async let")),
        ("https://duckduckgo.com/?q=mf+doom+all+caps&ia=web", ("DuckDuckGo", "mf doom all caps")),
        ("https://search.yahoo.com/search?p=weather+austin", ("Yahoo", "weather austin")),
        ("https://www.google.com/maps?q=coffee", nil), ("https://www.google.com/", nil), ("https://www.google.com/search?tbm=isch", nil),
        ("https://notgoogle.example.com/search?q=x", nil), ("https://www.youtube.com/results?search_query=x", nil),
        ("https://www.google.com/search?q=password%3A+hunter2", nil), ("https://www.google.com/search?q=482913", nil),
        ("https://www.google.com/search?q=sam%40example.com+invoice", nil),
        ("https://www.google.com/search?q=" + String(repeating: "a", count: 300), nil),
    ]
    for (url, want) in cases {
        let got = WebSearchQuery.query(url)
        try check(got?.engine == want?.0 && got?.query == want?.1,
                  "search capture (fix/chrome-x2): \(want == nil ? "no query" : "the query") from a \(URLComponents(string: url)?.host ?? "?") address (\(got?.engine ?? "nil"))")
    }
    // The page read keeps it on the read only when asked; the page row itself (claude/search-1005) carries the search words
    // as its title in every build, so both reads give the same row.
    func read(_ url: String, search: Bool) -> ChromePageResult {
        ChromePageProbe.read(userBlocked: [], searchQuery: search ? { WebSearchQuery.query($0) } : nil) { r in
            switch r {
            case .windowIDs: return .ids(["1"])
            case .mode("1"): return .text("normal")
            case .activeTabID("1"): return .text("7")
            case .tabURL("1", "7"): return .text(url)
            default: return nil
            }
        }
    }
    let url = "https://www.google.com/search?q=red+boots&sca_esv=1"
    guard case .page(let page) = read(url, search: true), case .page(let plain) = read(url, search: false) else { throw MemError.invalid("FAILED: search capture: page read") }
    try check(page.search?.engine == "Google" && page.search?.query == "red boots" && page.siteOnly && page.title == "red boots" && page.link == nil
              && plain.search == nil && page == plain,
              "search capture (fix/chrome-x2, claude/search-1005): the results page is a site-only page row with its search words; the query rides on the read only when asked")
    if case .skipped(.notNormal) = ChromePageProbe.read(userBlocked: [], searchQuery: { WebSearchQuery.query($0) }, { r in
        switch r { case .windowIDs: return .ids(["1", "2"]); case .mode("1"): return .text("normal"); case .mode("2"): return .text("incognito"); default: return .text(url) }
    }) {} else { try check(false, "search capture (fix/chrome-x2): an Incognito window anywhere: no page read, no search") }
    if case .skipped(.blocked) = ChromePageProbe.read(userBlocked: ["google.com"], searchQuery: { WebSearchQuery.query($0) }, { r in
        switch r { case .windowIDs: return .ids(["1"]); case .mode: return .text("normal"); case .activeTabID: return .text("7"); default: return .text(url) }
    }) {} else { try check(false, "search capture (fix/chrome-x2): a blocked search site: no page read, no search") }
    // The row: "Searched Google for '…'" facts, the site only, valid for the store, and still subject to the site choices.
    let row = WebTypedRow.searchEvidence(query: "red boots", engine: "Google", origin: "https://www.google.com", windowID: "1", tabID: "7",
                                         id: "web-search-1", policyRevision: "rev-1", generation: 1, wallTime: Date())
    try check(row != nil && row!.text == "red boots" && row!.title == "www.google.com" && row!.url == "https://www.google.com"
              && row!.captureProvenance?.unit?.surface == "search" && row!.captureProvenance?.unit?.send == "detected"
              && row!.captureProvenance?.unit?.sealReason == "submit" && row!.browserVerification?.provider == WebTypedRow.searchProvider
              && BrowserSafety.valid(row!) && WebTypedRow.valid(row!),
              "search capture (fix/chrome-x2): a search row is a typed search sent with Return on the site only")
    var on = TypedTextPolicy(); on.categories.searchAndAI = true
    var off = TypedTextPolicy(); off.categories.searchAndAI = false
    try check(on.permitsWebsiteRow(row!, settings: PrivacySettings(), expanded: true) && !off.permitsWebsiteRow(row!, settings: PrivacySettings(), expanded: true),
              "search capture (fix/chrome-x2): the store saves it only while Search and AI is on")
    var blocked = PrivacySettings(); blocked.blockedDomains = ["google.com"]
    try check(!on.permitsWebsiteRow(row!, settings: blocked, expanded: true), "search capture (fix/chrome-x2): never on a blocked site")
    try check(WebTypedRow.searchEvidence(query: "x", engine: "Google", origin: "https://www.bing.com", windowID: "1", tabID: "7", id: "w", policyRevision: "r",
                                         generation: 1, wallTime: Date()) == nil
              && WebTypedRow.searchEvidence(query: "a\nb", engine: "Google", origin: "https://www.google.com", windowID: "1", tabID: "7", id: "w", policyRevision: "r",
                                            generation: 1, wallTime: Date()) == nil,
              "search capture (fix/chrome-x2): only the engine's own site, one line")
    var forged = row!; forged.browserVerification?.focusedRole = "AXTextArea"
    var other = row!; other.url = "https://notes.example.org"; other.title = "notes.example.org"
    try check(!WebTypedRow.valid(forged) && !WebTypedRow.valid(other), "search capture (fix/chrome-x2): a search row claims no field and no other site")
}
#endif

/// claude/xtyping-1005 (owner laptop 10/04, public 0.1.4: nothing typed on X was saved). Chrome's accessibility was asleep
/// (no assistive client had asked its application its role), so every join was refused `notFocused`. Website typing now
/// wakes it when Chrome comes to the front (`BrowserTypingJoin.wake`), and a join that finds it asleep wakes it too.
/// End to end through the burst, with synthetic pages shaped like the ones on 127.0.0.1 in the live check: X's home
/// composer, a reply under a post (inline), the reply dialog (role=dialog), and a chat pane shaped like Snapchat's web
/// chat (a contenteditable or textarea, Return sends). Each saves its exact words, and its send is captured.
private func checkWebWokenComposers() throws {
    let pid = FakeChromeWorld.chromePID
    let words = "see you at the synthetic meetup"
    struct Case { let name, url, title, label: String; let role: String; let dialog: Bool; let chordSends: Bool }
    let post = "Synthetic User on X: \"sample post\" / X"
    let cases = [
        Case(name: "X home composer", url: "https://x.com/home", title: "(2) Home / X", label: "Post text", role: "AXTextArea", dialog: false, chordSends: true),
        Case(name: "X reply under a post (inline)", url: "https://x.com/synthetic_user/status/1000000000000000001", title: post, label: "Post your reply",
             role: "AXTextArea", dialog: false, chordSends: true),
        Case(name: "X reply dialog (role=dialog)", url: "https://x.com/compose/post", title: post, label: "Post your reply", role: "AXTextArea", dialog: true, chordSends: true),
        Case(name: "Snapchat-shaped chat (contenteditable)", url: "https://www.snapchat.com/web/00000000-0000-4000-8000-000000000001", title: "Snapchat",
             label: "Send a chat", role: "AXTextArea", dialog: false, chordSends: false),
        Case(name: "Snapchat-shaped chat (one-line textbox)", url: "https://www.snapchat.com/web/00000000-0000-4000-8000-000000000001", title: "Snapchat",
             label: "Send a chat", role: "AXTextField", dialog: false, chordSends: false),
    ]
    func rig(_ c: Case) -> WebRig {
        let r = WebRig(url: c.url); r.useLight = true
        r.w.windows[0].name = c.title; r.w.window.title = c.title + " - Google Chrome"
        r.w.field.role = c.role
        r.w.field.labels = BrowserTypingFieldLabels(texts: [c.label], identifiers: c.chordSends ? ["notranslate", "public-DraftEditor-content"] : [])
        let divs = r.w.deepen(dom: c.chordSends ? 40 : 18)
        if c.dialog { divs[10].subrole = "AXApplicationDialog" } else { divs[2].subrole = "AXLandmarkMain" }
        return r
    }
    func facts(_ r: WebRig) -> SendFacts? {
        r.commits.first.map { c in
            SendRules.facts(bundle: c.proof.bundle, host: BrowserSites.host(of: c.proof.url), title: BrowserSites.host(of: c.proof.url) ?? "",
                            field: c.proof.sendField.isEmpty ? "unknown" : c.proof.sendField,
                            composerPlace: c.proof.sendPlace.isEmpty ? nil : c.proof.sendPlace, seal: c.reason)
        }
    }
    func send(_ r: WebRig, _ c: Case) {
        if c.chordSends {
            // The route's Command-Return: the click save at the key, then the boundary (as in `checkWebSendGrace`).
            let at = r.w.clock; r.w.clock += 2_000_000
            _ = r.burst.pointerDown(r.pageResult(), at: at, now: r.w.clock, policy: r.policy, reason: .submitChord, write: r.write)
            r.burst.boundary(.submitChord, at: at, now: r.w.clock, focusMoved: true)
        } else {
            _ = r.key(.submit)
        }
    }
    for c in cases {
        // Chrome asleep as it comes to the front: website typing wakes it, then the words are typed and sent.
        var r = rig(c); r.w.sleeping = true
        let woke = r.join.wake(environment: r.w.environment, appleEvents: r.w.ae, accessibility: r.w.access)
        r.type(words); send(r, c)
        let f = facts(r)
        try check(woke && r.words == [words] && f?.send == "detected" && f?.sendBy == (c.chordSends ? "commandReturn" : "return")
                  && f?.surface == (c.chordSends ? "social" : "chat"),
                  "woken Chrome, \(c.name): the exact words are saved and the send captured (\(r.words), \(String(describing: f)))")
        // Before the fix (no wake): every key refused, nothing saved.
        r = rig(c); r.w.sleeping = true; r.w.wakes = false
        r.type(words); send(r, c)
        try check(r.rows.isEmpty && r.reads == 0, "asleep Chrome that is never woken, \(c.name): nothing read or saved (the owner's laptop)")
        // No front wake (Chrome asleep with no app switch since): the first key's join wakes Chrome and is refused, and the
        // refusal's quiet period (`quietNanoseconds`, 400 ms) drops the keys inside it unread, as for any refused key; the
        // words after it are saved, never more than was typed. (The front wake is what keeps the first words.)
        r = rig(c); r.w.sleeping = true
        r.type(words); send(r, c)
        let lostAtMost = 2 + Int(BrowserTypingTiming.quietNanoseconds / 82_000_000)
        try check(r.rows.count == 1 && words.hasSuffix(r.words[0]) && !r.words[0].isEmpty && r.words[0].count >= words.count - lostAtMost,
                  "asleep Chrome woken by the first key, \(c.name): the rest of the words are saved (\(r.words))")
    }
    // Typing turned off: the front wake never touches Chrome (no Apple Event, no role read), and nothing is saved.
    let off = rig(cases[3]); off.w.sleeping = true; off.w.enabled = false
    try check(!off.join.wake(environment: off.w.environment, appleEvents: off.w.ae, accessibility: off.w.access) && off.w.aeCount == 0
              && !off.w.log.contains("ax:wake"), "typing off: Chrome is never woken (no Apple Event, no Accessibility read)")
    // Privacy holds on the woken page: an Incognito window open, a password field (secure input), the chat's site switch off.
    var r = rig(cases[3]); r.w.sleeping = true; r.w.addWindow("555", mode: "incognito", front: false)
    try check(!r.join.wake(environment: r.w.environment, appleEvents: r.w.ae, accessibility: r.w.access) && !r.w.log.contains("ax:wake"),
              "an Incognito window open: Chrome is not woken")
    r.type(words); _ = r.key(.submit)
    try check(r.rows.isEmpty, "an Incognito window open: nothing saved from the chat")
    r = rig(cases[3]); r.w.secure = true
    r.type(words); _ = r.key(.submit)
    try check(r.rows.isEmpty, "secure input on (a password field): nothing saved from the chat")
    let messagesOff = WebRig(choices: TypedCategoryChoices(messagesAndEmail: false), url: cases[3].url)
    messagesOff.w.field.labels = BrowserTypingFieldLabels(texts: ["Send a chat"], identifiers: []); messagesOff.w.field.role = "AXTextArea"
    messagesOff.type(words); _ = messagesOff.key(.submit)
    try check(messagesOff.rows.isEmpty, "Messages and email off: nothing saved from a Snapchat-shaped chat")
    _ = pid
}

/// fix/chrome-x2 (owner, 2026-10-03, build 20261003140001: a post on X and a search typed in Google's own box saved no
/// typed words). A send gesture's own join runs after the page may already have reacted to it: X closes its post window
/// and goes back to the timeline, empties the composer or moves focus off it; Google loads the results page. That join
/// (or the Command-Return click join) then can't prove the field again, and the burst dropped every admitted word. Now
/// the words park as a send and the settle saves them to the field of their last admitted key when a fresh join proves the
/// same Chrome, window, tab, site and window list (the address within the site may differ). Privacy refusals still drop.
private func checkWebSendGrace() throws {
    func xRig(_ url: String, title: String, label: String) -> WebRig {
        let r = WebRig(url: url); r.useLight = true
        r.w.windows[0].name = title; r.w.window.title = title + " - Google Chrome - Sam"
        r.w.field.role = "AXTextArea"
        r.w.field.labels = BrowserTypingFieldLabels(texts: [label], identifiers: ["notranslate", "public-DraftEditor-content"])
        return r
    }
    func retitle(_ r: WebRig, _ url: String, _ title: String) { r.page(url); r.w.windows[0].name = title; r.w.window.title = title + " - Google Chrome - Sam" }
    /// The route's Command-Return: the click save at the key (`saveLive` -> `pointerDown`), then the boundary. `react`: what
    /// the page did before the click join read it.
    func commandReturn(_ r: WebRig, react: (WebRig) -> Void = { _ in }) {
        let at = r.w.clock; r.w.clock += 2_000_000
        react(r)
        _ = r.burst.pointerDown(r.pageResult(), at: at, now: r.w.clock, policy: r.policy, reason: .submitChord, write: r.write)
        r.burst.boundary(.submitChord, at: at, now: r.w.clock, focusMoved: true)
    }
    func settle(_ r: WebRig, after ns: UInt64 = 450_000_000, secure: Bool = false) { r.w.clock += ns; r.settle(secure: secure) }
    /// The send facts the route's row gets (`WebTypedRow.evidence` applies these to the unit).
    func unit(_ r: WebRig) -> SendFacts? {
        r.commits.first.map { c in
            SendRules.facts(bundle: c.proof.bundle, host: BrowserSites.host(of: c.proof.url), title: BrowserSites.host(of: c.proof.url) ?? "",
                            field: c.proof.sendField.isEmpty ? "unknown" : c.proof.sendField,
                            composerPlace: c.proof.sendPlace.isEmpty ? nil : c.proof.sendPlace, seal: c.reason)
        }
    }
    /// What the route's write stores as who it went to and what it answered (`BrowserComposeSignals`), from the last
    /// admitted key's proof of the same document (the settle's join is of the page the send moved on to).
    func identity(_ r: WebRig) -> (ComposeDestination, ComposeContext)? {
        guard let c = r.commits.first, let l = r.burst.last, l.documentID == c.proof.documentID, l.windowID == c.proof.windowID, l.tabID == c.proof.tabID,
              let g = BrowserComposeSignals.gesture(seal: c.reason.rawValue) else { return nil }
        return BrowserComposeSignals.submit(proof: l, gesture: g.rawValue)?.identity(surface: unit(r)?.surface ?? "")
    }
    func button(_ r: WebRig) -> FakeAXNode { FakeAXNode("post-button", role: "AXButton", parent: r.w.group, owner: FakeChromeWorld.chromePID) }
    let words = "shipping the launch build today"
    let post = "Ada on X: \"launch day notes\" / X"

    // 1. The home timeline's composer ("What's happening?"). X empties it and moves focus to the Post button before the
    //    click join reads: the click join proves the same page, and the words are saved at once as a post.
    var r = xRig("https://x.com/home", title: "(3) Home / X", label: "Post text")
    r.type(words)
    commandReturn(r) { $0.w.axFocus = button($0) }
    try check(r.words == [words] && r.rows.first?.url == "https://x.com" && unit(r)?.surface == "social" && unit(r)?.send == "detected"
              && unit(r)?.sendBy == "commandReturn" && identity(r).map { $0.0.service == "X" && $0.0.handle == nil && $0.1.isEmpty } == true,
              "send grace (fix/chrome-x2): the home composer: Command-Return as X empties it saves the exact words as a post on X (\(r.words))")
    // The same with the composer gone and the address changed before the click join (X's route moved on): parked as a
    // send, saved at the settle (the settle's full join finds the home composer, same tab and site).
    r = xRig("https://x.com/home", title: "(3) Home / X", label: "Post text")
    r.type(words)
    commandReturn(r) { retitle($0, "https://x.com/home?posted=1", "(3) Home / X") }
    try check(r.rows.isEmpty && r.burst.sendPending(now: r.w.clock), "send grace (fix/chrome-x2): a click join of a changed address parks the words as a send")
    settle(r)
    try check(r.words == [words] && unit(r)?.send == "detected" && unit(r)?.sendBy == "commandReturn",
              "send grace (fix/chrome-x2): ...and the settle saves them as the post (\(r.words))")

    // 2. The /compose/post window (the Post button in the sidebar). Command-Return: X closes it and goes back to /home
    //    before the click join; the settle's full join finds focus on the timeline's own composer (another field and
    //    address of the same tab and site): the exact words are saved as a post.
    r = xRig("https://x.com/compose/post", title: "(3) Home / X", label: "Post text")
    r.type(words)
    commandReturn(r) { retitle($0, "https://x.com/home", "(3) Home / X"); $0.w.field.labels = BrowserTypingFieldLabels(texts: ["Post text", "What’s happening?"], identifiers: []) }
    try check(r.rows.isEmpty, "send grace (fix/chrome-x2): the compose window closed before the click join: nothing saved at the key")
    settle(r)
    try check(r.words == [words] && r.rows.first?.url == "https://x.com" && unit(r)?.send == "detected" && unit(r)?.sendBy == "commandReturn"
              && r.commits.first?.reason == .submitChord && identity(r).map { $0.0.service == "X" && !$0.1.isEmpty } == false,
              "send grace (fix/chrome-x2): /compose/post closed onto the timeline: the exact words are saved as a post at the settle (\(r.words))")
    // ...with focus on the page itself after it closed (the full join refuses `field`): the click join proves the tab.
    r = xRig("https://x.com/compose/post", title: "(3) Home / X", label: "Post text")
    r.type(words)
    commandReturn(r) { retitle($0, "https://x.com/home", "(3) Home / X"); $0.w.axFocus = $0.w.web }
    settle(r)
    try check(r.words == [words] && unit(r)?.sendBy == "commandReturn", "send grace (fix/chrome-x2): /compose/post closed, focus on the page: saved (\(r.words))")
    // ...while Chrome's Accessibility address still lags the tab's (the full join refuses `url` at the settle): the click
    // join can't prove the page either, so the words are dropped (stated cost: a page still loading 0.4 s after a send).
    r = xRig("https://x.com/compose/post", title: "(3) Home / X", label: "Post text")
    r.type(words)
    commandReturn(r) { $0.w.windows[0].url = "https://x.com/home" }
    settle(r)
    try check(r.rows.isEmpty, "send grace (fix/chrome-x2): a page still mid-load at the settle (Apple Events and Accessibility disagree): dropped")

    // 3. The reply window, opened from a post page: /compose/post over the post, the post's title kept. Command-Return
    //    closes it onto the post page: saved as a reply with its context (the post's author and text).
    r = xRig("https://x.com/ada/status/1839", title: post, label: "Post your reply")
    retitle(r, "https://x.com/compose/post", post)
    r.type(words)
    commandReturn(r) { retitle($0, "https://x.com/ada/status/1839", post); $0.w.axFocus = button($0) }
    settle(r)
    let reply = identity(r)
    try check(r.words == [words] && unit(r)?.sendBy == "commandReturn" && reply?.0.service == "X"
              && reply?.1 == ComposeContext(author: "Ada", excerpt: "launch day notes"),
              "send grace (fix/chrome-x2): an X reply in the reply window is saved with its context, the post's author and text (\(r.words), \(String(describing: reply)))")
    // The reply box on the post page itself (X stays there and empties the box): saved at once, with the @handle and context.
    r = xRig("https://x.com/ada/status/1839", title: post, label: "Post your reply")
    r.type(words)
    commandReturn(r)
    let inline = identity(r)
    try check(r.words == [words] && inline?.0.handle == "ada" && inline?.1 == ComposeContext(author: "Ada", excerpt: "launch day notes"),
              "send grace (fix/chrome-x2): an X reply on the post page is saved with @ada and the post's context (\(String(describing: inline)))")

    // 4. Google's own search box: Return, and the results page is loading before the Return's join (`url`): parked,
    //    saved at the settle once the results page is in (focus on the page), as a search sent with Return.
    r = WebRig(url: "https://www.google.com/"); r.useLight = true
    r.w.windows[0].name = "Google"; r.w.window.title = "Google - Google Chrome - Sam"
    r.w.field.role = "AXComboBox"; r.w.field.editableAncestor = r.w.field; r.w.field.labels = BrowserTypingFieldLabels(texts: ["Search"], identifiers: ["APjFqb"])
    r.type("red boots size 10")
    r.w.windows[0].url = "https://www.google.com/search?q=red+boots+size+10"
    _ = r.key(.submit)
    try check(r.rows.isEmpty && r.burst.sendPending(now: r.w.clock), "send grace (fix/chrome-x2): Return in Google's box as the results page loads: parked as a send")
    retitle(r, "https://www.google.com/search?q=red+boots+size+10", "red boots size 10 - Google Search"); r.w.window.title = "red boots size 10 - Google Search - Google Chrome - Sam"
    r.w.axFocus = r.w.web
    settle(r)
    try check(r.words == ["red boots size 10"] && r.rows.first?.url == "https://www.google.com" && unit(r)?.surface == "search" && unit(r)?.send == "detected"
              && unit(r)?.sendBy == "return",
              "send grace (fix/chrome-x2): the Google search typed in the page is saved once the results page is in, as a search (\(r.words))")

    // Privacy refusals at the send still drop everything (and never park).
    for (name, change) in [("an Incognito window", { (r: WebRig) in r.w.windows.append(.init(id: "202", mode: "incognito", bounds: FakeChromeWorld.bounds, name: "x", tab: "1", url: "https://x.com/home")) }),
                           ("a password field next to the box", { (r: WebRig) in let f = FakeAXNode("pw", role: "AXTextField", subrole: "AXSecureTextField", parent: r.w.group, owner: FakeChromeWorld.chromePID); _ = f }),
                           ("typing turned off", { (r: WebRig) in r.w.enabled = false })] {
        let g = xRig("https://x.com/compose/post", title: "(3) Home / X", label: "Post text")
        g.type(words)
        change(g)
        _ = g.key(.submit)
        settle(g)
        try check(g.rows.isEmpty && !g.burst.sendPending(now: g.w.clock), "send grace (fix/chrome-x2): \(name) at the send: nothing parked, nothing saved")
    }
    // A send whose page moved to another site, tab or window list, or secure input at the settle: dropped.
    for (name, change) in [("another site", { (r: WebRig) in retitle(r, "https://example.org/", "Example") }),
                           ("another tab", { (r: WebRig) in r.w.windows[0].tab = "8"; retitle(r, "https://x.com/home", "(3) Home / X") }),
                           ("a new window", { (r: WebRig) in r.w.windows.append(.init(id: "202", mode: "normal", bounds: ChromeBounds(left: 0, top: 25, right: 400, bottom: 400), name: "Other", tab: "1", url: "https://example.org/")) })] {
        let g = xRig("https://x.com/compose/post", title: "(3) Home / X", label: "Post text")
        g.type(words)
        commandReturn(g) { change($0) }
        settle(g)
        try check(g.rows.isEmpty, "send grace (fix/chrome-x2): the send's page moved to \(name): dropped (\(g.words))")
    }
    r = xRig("https://x.com/compose/post", title: "(3) Home / X", label: "Post text")
    r.type(words)
    commandReturn(r) { retitle($0, "https://x.com/home", "(3) Home / X") }
    settle(r, secure: true)
    try check(r.rows.isEmpty, "send grace (fix/chrome-x2): secure input at the settle: dropped")
    // A plain Return that is not a send (a notes box) keeps the old rule when its join is refused: dropped, not parked.
    r = WebRig(); r.type("a note")
    r.w.axFocus = button(r)
    _ = r.key(.split(.cursor))
    try check(r.rows.isEmpty && !r.burst.sendPending(now: r.w.clock), "send grace (fix/chrome-x2): only Return and Command-Return park; a cursor split refused is dropped")
    // Not a page where Return or Command-Return sends (a notes page): the old rule (review G12) holds, another page of the
    // site at the settle drops the text.
    r = WebRig(); r.type("a note")
    commandReturn(r) { $0.page("https://notes.example.org/pad/12") }
    try check(!r.burst.sendPending(now: r.w.clock), "send grace (fix/chrome-x2): Command-Return on a notes page is not a send")
    settle(r)
    try check(r.rows.isEmpty, "send grace (fix/chrome-x2): ...and another page of the site at the settle drops it, as before (\(r.words))")
    // A send judged more than `sendSettleNanoseconds` later is no longer one.
    r = xRig("https://x.com/compose/post", title: "(3) Home / X", label: "Post text")
    r.type(words)
    commandReturn(r) { retitle($0, "https://x.com/home", "(3) Home / X") }
    r.w.clock += BrowserTypingBurst.sendSettleNanoseconds + 1
    try check(!r.burst.sendPending(now: r.w.clock), "send grace (fix/chrome-x2): the send window ends")
}

private func checkWebRejoinLoop() throws {
    let post = "Ada on X: \"launch day notes\" / X"
    func rig(title: String) -> WebRig {
        let r = WebRig(url: "https://x.com/ada/status/1839"); r.useLight = true
        r.w.tick = 12_500_000; r.w.axTick = 100_000
        r.w.windows[0].name = post; r.w.window.title = title
        r.w.field.role = "AXTextArea"; r.w.field.labels = BrowserTypingFieldLabels(texts: ["Post your reply"], identifiers: [])
        // claude/typing-1004: a title decides only among same-bounds windows, so the refused page has one elsewhere.
        r.w.addWindow("202", mode: "normal", front: false, bounds: FakeChromeWorld.bounds, name: "Elsewhere", url: "https://other.example.org/", onThisSpace: false)
        return r
    }
    let refused = post + " - Not a Chrome state - Google Chrome"
    // 2.4 s of typing (30 keys at 80 ms) into a page whose window can't be matched.
    func refusedBurst(hold: Bool) -> WebRig {
        BrowserTypingBurst.episodeHoldEnabled = hold; defer { BrowserTypingBurst.episodeHoldEnabled = true }
        let r = rig(title: refused)
        r.type(String(repeating: "a", count: 30))
        return r
    }
    let before = refusedBurst(hold: false), after = refusedBurst(hold: true)
    try check(before.rows.isEmpty && after.rows.isEmpty, "website typing (fix/chrome-x): a refused episode saves nothing, held or not")
    try check(after.joins == 1 && before.joins >= 4,
              "website typing (fix/chrome-x): a refused X reply joins once per episode, not every quiet period (before \(before.joins) joins, after \(after.joins))")
    // The hold ends on a material change: the window's title (the page or its state changed), at once.
    let r = rig(title: refused)
    r.type("aaaa")
    r.w.window.title = post + " - Google Chrome - Sam"
    r.w.clock += BrowserTypingTiming.quietNanoseconds
    r.type("now it matches"); _ = r.key(.submit)
    try check(r.words == ["now it matches"], "website typing (fix/chrome-x): a title change ends the held episode at the next key (\(r.words))")
    // Focus moving to another field ends it too.
    let f = rig(title: refused)
    f.type("aaaa")
    let other = FakeAXNode("other-box", role: "AXTextArea", parent: f.w.group, owner: FakeChromeWorld.chromePID); other.labels = f.w.field.labels
    f.w.axFocus = other
    let joinsBefore = f.joins
    f.w.clock += BrowserTypingTiming.quietNanoseconds
    f.type("b")
    try check(f.joins == joinsBefore + 1, "website typing (fix/chrome-x): focus on another field ends the held episode (a new join)")
    // The hold is bounded: a refusal still true after `episodeHoldNanoseconds` is joined again once.
    let long = rig(title: refused)
    long.type(String(repeating: "a", count: 50))   // 4 s
    try check(long.joins == 2, "website typing (fix/chrome-x): a held episode joins again after \(BrowserTypingTiming.episodeHoldNanoseconds / 1_000_000_000) s (\(long.joins) joins in 4 s)")
    // Benchmark: main-thread time per key.
    func perKey(_ r: WebRig) -> Double { Double(r.mainNs) / Double(max(1, r.keys)) / 1e6 }
    let ok = rig(title: post + " - Google Chrome - Sam")
    ok.type("a normal reply typed at about twelve keys a second"); _ = ok.key(.submit)
    print(String(format: "BENCH website typing main-thread ms/key at 12.5 ms per Apple Event: refused X episode before %.1f, after %.1f; allowed burst %.1f (%d keys, %d joins, %d light)",
                 perKey(before), perKey(after), perKey(ok), ok.keys, ok.joins, ok.lights))
    try check(perKey(after) * 3 < perKey(before), "website typing (fix/chrome-x): the held episode cuts main-thread time per key at least threefold (\(perKey(before)) -> \(perKey(after)) ms)")
}

private func checkWebBurst() throws {
    // Unknown site, defaults: typed, Return saves the words with the origin only.
    var r = WebRig()
    r.type("ship the pricing page friday")
    try check(r.reads == 28 && r.burst.session.hasLive, "website typing: each key is read after its join, on an unknown site with the defaults")
    if case .committed(.committed) = r.key(.submit) {} else { try check(false, "website typing: Return commits") }
    try check(r.words == ["ship the pricing page friday"] && r.rows.first?.url == "https://notes.example.org" && r.rows.first?.role == "AXTextArea",
              "website typing: Return saves the words with the origin only (no path or query)")
    // Keys in the quiet period right after Return are dropped unread.
    let quietReads = r.reads
    r.type("ab")
    try check(r.reads == quietReads && !r.burst.session.hasLive, "website typing: keys in the quiet period after Return are not read")
    // A pause: the idle save needs a fresh join of the same burst.
    r.w.clock += BrowserTypingTiming.quietNanoseconds
    r.type("second draft")
    r.w.clock += 5_000_000_000
    let before = r.rows.count
    let idle = r.burst.commit(r.result(), typedAt: nil, processedAt: r.w.clock, reason: .idle, policy: r.policy, write: r.write)
    try check(idle == .committed(withheld: 0) && r.rows.count == before + 1 && r.words.last == "second draft", "website typing: a pause saves with a fresh join")
    // Other websites off: nothing is read or typed, and the join refuses the page.
    r = WebRig(choices: TypedCategoryChoices(otherWebsites: false))
    r.type("hidden words"); r.key(.submit)
    try check(r.reads == 0 && r.rows.isEmpty && r.joins > 0 && r.result().denial == .blockedSite,
              "website typing: Other websites off means nothing is typed on an unknown site")
    // Categories: email on by default (fix/typing-e2e L1), off when switched off; search off stops search pages.
    let messagesOff = TypedCategoryChoices(messagesAndEmail: false)
    r = WebRig(url: "https://mail.google.com/mail/u/0/?compose=new#inbox")
    r.type("dear team"); r.key(.submit)
    try check(r.words == ["dear team"] && r.rows.first?.url == "https://mail.google.com", "website typing: email is on by default: Gmail is typed")
    r = WebRig(choices: messagesOff, url: "https://mail.google.com/mail/u/0/?compose=new#inbox")
    r.type("dear team"); r.key(.submit)
    try check(r.reads == 0 && r.rows.isEmpty, "website typing: email off: nothing typed in Gmail")
    r = WebRig(choices: TypedCategoryChoices(messagesAndEmail: true), url: "https://mail.google.com/mail/u/0/?compose=new#inbox")
    r.type("dear team"); r.key(.submit)
    try check(r.words == ["dear team"] && r.rows.first?.url == "https://mail.google.com", "website typing: email on: Gmail is typed")
    // Review F1: Messages and email off holds on messaging sites, on every page.
    for url in ["https://www.facebook.com/", "https://www.linkedin.com/feed/", "https://x.com/home", "https://voice.google.com/u/0/messages"] {
        r = WebRig(choices: messagesOff, url: url)
        r.type("see you at eight"); r.key(.submit)
        try check(r.reads == 0 && r.rows.isEmpty && r.result().denial == .blockedSite,
                  "website typing: Messages and email off: nothing typed on \(url)")
    }
    r = WebRig(choices: TypedCategoryChoices(messagesAndEmail: true), url: "https://www.facebook.com/")
    r.type("see you at eight"); r.key(.submit)
    try check(r.words == ["see you at eight"] && r.rows.first?.url == "https://www.facebook.com", "website typing: Messages and email on: a message on facebook.com is typed, with its site only")
    // Review F1: a message composer on an Other websites page (a support chat box).
    r = WebRig(choices: messagesOff, url: "https://shop.example.org/help")
    r.w.field.labels = BrowserTypingFieldLabels(texts: ["Type a message"], identifiers: ["chat-input"])
    r.type("where is my order"); r.key(.submit)
    try check(r.reads == 0 && r.rows.isEmpty && r.result().denial == .blockedSite,
              "website typing: Messages and email off: nothing typed in a message composer on an Other websites page")
    r = WebRig(choices: messagesOff, url: "https://shop.example.org/help")
    r.type("gift note"); r.key(.submit)
    try check(r.words == ["gift note"], "website typing: an ordinary field on the same page is typed (Other websites)")
    r.w.clock += 1_000_000_000
    r.type("draft")
    r.w.field.labels = BrowserTypingFieldLabels(texts: ["Write a message…"], identifiers: [])
    r.type(" more"); r.key(.submit)
    try check(r.words == ["gift note"] && !r.burst.session.hasLive && r.burst.session.parkedCount == 0,
              "website typing: the field turns into a message composer: nothing more is typed and the unsaved words are dropped")
    r = WebRig(choices: TypedCategoryChoices(messagesAndEmail: true), url: "https://shop.example.org/help")
    r.w.field.labels = BrowserTypingFieldLabels(texts: ["Type a message"], identifiers: [])
    r.type("where is my order"); r.key(.submit)
    try check(r.words == ["where is my order"], "website typing: Messages and email on: a message composer on an Other websites page is typed")
    r = WebRig(choices: TypedCategoryChoices(searchAndAI: false), url: "https://www.google.com/search?q=boots")
    r.type("red boots"); r.key(.submit)
    try check(r.reads == 0 && r.rows.isEmpty, "website typing: search and AI off: nothing typed on a search page")
    r = WebRig(url: "https://chatgpt.com/")
    r.type("plan my week"); r.key(.submit)
    try check(r.words == ["plan my week"], "website typing: an AI chat page follows Search and AI (on by default)")
    // Blocked sites: a page history default and a typing-only block.
    for url in ["https://www.plannedparenthood.org/appointments", "https://secure.chase.com/overview", "https://shell.cloud.google.com/"] {
        r = WebRig(choices: TypedCategoryChoices(searchAndAI: true, writing: true, code: true, messagesAndEmail: true, otherWebsites: true), url: url)
        r.type("words"); r.key(.submit)
        try check(r.reads == 0 && r.rows.isEmpty, "website typing: a blocked site types nothing with every switch on: \(url)")
    }
    // Incognito: any such window open means nothing, and drops what was pending.
    r = WebRig()
    r.type("before private")
    r.w.addWindow("202", mode: "incognito", front: false)
    let readsBefore = r.reads
    r.type("while private"); r.key(.submit)
    try check(r.reads == readsBefore && r.rows.isEmpty && !r.burst.session.hasLive && r.burst.session.parkedCount == 0,
              "website typing: an Incognito window open: nothing typed, and the unsaved words before it are dropped")
    r.w.removeWindow("202"); r.w.clock += 1_000_000_000
    r.type("after"); r.key(.submit)
    try check(r.words == ["after"], "website typing: after the Incognito window closes, typing starts fresh (nothing from before)")
    // Guest (and any mode that is not "normal", or unreadable): nothing.
    for mode in ["guest", nil] as [String?] {
        r = WebRig(); r.w.addWindow("303", mode: mode, front: true)
        r.type("guest words"); r.key(.submit)
        try check(r.reads == 0 && r.rows.isEmpty, "website typing: a window whose mode is \(mode ?? "unreadable") means nothing is typed")
    }
    // Password field: the join refuses it, and the unsaved words are dropped.
    r = WebRig()
    r.type("user name")
    r.w.field.subrole = "AXSecureTextField"
    let atPassword = r.reads
    r.type("hunter2"); r.key(.submit)
    try check(r.reads == atPassword && r.rows.isEmpty && !r.burst.session.hasLive, "website typing: a password field reads nothing and drops the unsaved words")
    // A sensitive field (labels): refused, words dropped.
    r = WebRig()
    r.type("gift note")
    r.w.field.labels = BrowserTypingFieldLabels(texts: ["Card number"], identifiers: [])
    r.type("4111"); r.key(.submit)
    try check(r.rows.isEmpty && !r.burst.session.hasLive, "website typing: a card number field is refused and the draft before it dropped")
    // The scrubber and classifier still apply to saved words.
    r = WebRig()
    r.type("my card is 4111 1111 1111 1111 ok"); r.key(.submit)
    try check(!r.words.joined().contains("4111 1111"), "website typing: a card number is never saved (classifier and scrubber apply)")
    // "Don't record this site": the owner's list stops typing and drops the draft.
    r = WebRig()
    r.type("half a thought")
    r.sites.alwaysBlocked.append("example.org")
    let atBlock = r.reads
    r.type(" more"); r.key(.submit)
    try check(r.reads == atBlock && r.rows.isEmpty && !r.burst.session.hasLive, "website typing: \"Don't record this site\" stops typing on it at once and drops the draft")
    // A different field: the draft is not moved into it; a parked draft is
    // saved only if the settle finds the same field again.
    r = WebRig()
    r.type("first field")
    r.burst.boundary(.pointer, at: r.w.clock, now: r.w.clock, focusMoved: true)
    r.w.clock += 500_000_000
    _ = r.burst.resolveParked(r.result(), secureInput: false, now: r.w.clock, policy: r.policy, write: r.write)
    try check(r.words == ["first field"], "website typing: a click in the same field: the parked draft is saved after the settle")
    r.type("second")
    r.burst.boundary(.pointer, at: r.w.clock, now: r.w.clock, focusMoved: true)
    let otherField = FakeAXNode("other-field", role: "AXTextField", parent: r.w.group, owner: FakeChromeWorld.chromePID)
    otherField.labels = BrowserTypingFieldLabels(texts: ["Title"], identifiers: [])   // QF-4: a labelled one-line box
    r.w.axFocus = otherField
    r.w.clock += 500_000_000
    _ = r.burst.resolveParked(r.result(), secureInput: false, now: r.w.clock, policy: r.policy, write: r.write)
    // Review G12: focus in another text field of the same page that the full join allowed (its labels,
    // site and every window checked) is a safe destination, as in native typing.
    try check(r.words == ["first field", "second"] && r.burst.session.parkedCount == 0,
              "website typing (G12): focus in another allowed field of the same page: the parked draft is saved to its own field")
    r.type("third")
    r.burst.boundary(.pointer, at: r.w.clock, now: r.w.clock, focusMoved: true)
    r.w.axFocus = FakeAXNode("elsewhere", role: "AXTextField", parent: r.w.group, owner: FakeChromeWorld.chromePID)
    r.page("https://notes.example.org/pad/8")
    r.w.clock += 500_000_000
    r.settle()
    try check(r.words == ["first field", "second"] && r.burst.session.parkedCount == 0, "website typing (G12): focus on another page: the parked draft is dropped")
    // QF-4 (option a): focus moves to an unlabelled one-line box (a card number or a code, as far as anyone can prove):
    // the box refuses its own keys (field), and the draft typed before is still saved as it leaves.
    do {
        let r = WebRig()
        r.type("notes before the card")
        r.burst.boundary(.pointer, at: r.w.clock, now: r.w.clock, focusMoved: true)
        let card = FakeAXNode("x1", role: "AXTextField", parent: r.w.group, owner: FakeChromeWorld.chromePID)
        card.labels = BrowserTypingFieldLabels(texts: [], identifiers: ["x1"])
        r.w.axFocus = card
        r.w.clock += 500_000_000
        r.settle()
        try check(r.words == ["notes before the card"] && r.burst.session.parkedCount == 0,
                  "QF-4: focus moves to an unlabelled one-line box: the draft before it is saved (\(r.words))")
        r.type("4111111111111111")
        r.w.clock += 5_000_000_000; r.settle()
        try check(r.words == ["notes before the card"] && r.result().denial == .field, "QF-4: the unlabelled box's own keys: refused (field), nothing saved")
    }
    // Review C2: a draft in a composer (a text area), then focus in a one-line search box on a big page
    // whose scan can't finish (more than 64 nodes, or a container of more than 256): the box refuses its own keys
    // (`field`), and the composer draft is still saved as it leaves.
    for rows in [100, 300] {
        let r = WebRig()
        r.type("composer words")
        r.burst.boundary(.pointer, at: r.w.clock, now: r.w.clock, focusMoved: true)
        let bar = FakeAXNode("search-bar", role: "AXGroup", parent: r.w.group.parent, owner: FakeChromeWorld.chromePID)
        let search = FakeAXNode("search", role: "AXComboBox", parent: bar, owner: FakeChromeWorld.chromePID)
        search.editableAncestor = search; search.labels = BrowserTypingFieldLabels(texts: ["Search query"], identifiers: [])
        for i in 0..<rows { _ = FakeAXNode("trend\(i)", role: "AXLink", parent: bar, owner: FakeChromeWorld.chromePID) }
        r.w.axFocus = search
        r.w.clock += 500_000_000
        r.settle()
        try check(r.words == ["composer words"] && r.burst.session.parkedCount == 0,
                  "C2: composer, then a search box on a big page (\(rows) rows): the draft is saved (\(r.words))")
        try check(r.result().denial == .field, "C2: the search box itself (\(rows) rows): refused (field)")
    }
    // Esc in a search field abandons the search.
    r = WebRig(url: "https://example.org/")
    r.w.field.role = "AXTextField"; r.w.field.subrole = "AXSearchField"
    r.type("half typed search")
    r.burst.escape(at: r.w.clock, now: r.w.clock)
    r.w.clock += 5_000_000_000
    _ = r.burst.resolveParked(r.result(), secureInput: false, now: r.w.clock, policy: r.policy, force: true, write: r.write)
    try check(r.rows.isEmpty && !r.burst.session.hasLive, "website typing: Esc in a search field discards the search")
    // Typing off (policy) refuses before any read.
    r = WebRig(); r.policy.typedText = false
    r.type("off"); r.key(.submit)
    try check(r.reads == 0 && r.rows.isEmpty, "website typing: typing off reads nothing")
    // A late key is dropped unread.
    r = WebRig()
    let typed = r.w.clock; r.w.clock += BrowserTypingTiming.maxKeyLagNanoseconds + 10_000_000
    _ = r.burst.key(.insert(nil), join: r.result, typedAt: typed, now: { r.w.clock }, policy: r.policy, read: { r.reads += 1; return "x" }, write: r.write)
    try check(r.reads == 0, "website typing: a key processed too late is not read")
    // A shortcut takes no join and reads nothing.
    r = WebRig()
    let joinsBefore = r.joins
    r.key(.consume); r.key(.noop(marker: true))
    try check(r.joins == joinsBefore && r.reads == 0, "website typing: dead keys and copy shortcuts start no join and read nothing")
}
/// Review G12: Tab, a chorded Return and focus leaving for a button no longer
/// lose the unfinished website words, and still never save them next to a
/// password field, an Incognito window or another page.
private func checkWebLeave() throws {
    let pid = FakeChromeWorld.chromePID
    func tabNoSettle(_ r: WebRig, to focus: FakeAXNode?) {
        r.burst.boundary(.focusKey, at: r.w.clock, now: r.w.clock, focusMoved: true)
        r.w.axFocus = focus
        r.w.clock += 450_000_000
    }
    func tab(_ r: WebRig, to focus: FakeAXNode?) { tabNoSettle(r, to: focus); r.settle() }
    // Tab to the next field of a form: saved once, to the field it was typed in.
    var r = WebRig()
    r.type("first name")
    tab(r, to: FakeAXNode("last-name", role: "AXTextField", parent: r.w.group, owner: pid))
    try check(r.words == ["first name"] && r.rows.first?.role == "AXTextArea" && r.burst.session.parkedCount == 0,
              "website typing (G12): Tab to the next field saves the words, to the field they were typed in")
    r.w.clock += 5_000_000_000; r.settle()
    try check(r.words == ["first name"], "website typing (G12): saved once")
    // Tab to a button (not a text field, not secure): the click join proves the page.
    r = WebRig()
    r.type("see you friday")
    tab(r, to: FakeAXNode("send", role: "AXButton", parent: r.w.group, owner: pid))
    try check(r.words == ["see you friday"], "website typing (G12): Tab to a Send button saves the words")
    // Tab into a password field: dropped (a secure subrole, or secure input on).
    r = WebRig()
    r.type("user name")
    tab(r, to: FakeAXNode("password", role: "AXTextField", subrole: "AXSecureTextField", parent: r.w.group, owner: pid))
    try check(r.rows.isEmpty && !r.burst.session.hasLive && r.burst.session.parkedCount == 0,
              "website typing (G12): Tab into a password field drops the words typed before it")
    r = WebRig()
    r.type("user name")
    r.burst.boundary(.focusKey, at: r.w.clock, now: r.w.clock, focusMoved: true)
    r.w.axFocus = FakeAXNode("pin", role: "AXTextField", parent: r.w.group, owner: pid)
    r.w.secure = true; r.w.clock += 450_000_000
    r.settle(secure: true)
    try check(r.rows.isEmpty && r.burst.session.parkedCount == 0, "website typing (G12): Tab while secure input is on drops the words")
    // Tab into a field whose labels say it is sensitive: dropped, with everything unsaved.
    r = WebRig()
    r.type("gift note")
    let card = FakeAXNode("card", role: "AXTextField", parent: r.w.group, owner: pid)
    card.labels = BrowserTypingFieldLabels(texts: ["Card number"], identifiers: [])
    tab(r, to: card)
    try check(r.rows.isEmpty && r.burst.session.parkedCount == 0, "website typing (G12): Tab into a card number field drops the words")
    // A subrole that can't be read is never taken as "not secure".
    r = WebRig()
    r.type("hello there")
    let unreadable = FakeAXNode("mystery", role: "AXButton", parent: r.w.group, owner: pid)
    var access = r.w.access
    let subrole = access.subrole
    access.subrole = { $0 === unreadable ? nil : subrole($0) }
    r.burst.boundary(.focusKey, at: r.w.clock, now: r.w.clock, focusMoved: true)
    r.w.axFocus = unreadable; r.w.clock += 450_000_000
    let page = r.join.join(environment: r.w.environment, appleEvents: r.w.ae, accessibility: access, blockList: r.sites.blockList,
                           alwaysBlocked: r.sites.alwaysBlocked, sites: r.sites.permits(url:), anyFocus: true)
    try check(page.denial == .field, "website typing (G12): a click join refuses focus whose subrole can't be read")
    _ = r.burst.resolveParked(r.result(), page: page, secureInput: false, now: r.w.clock, policy: r.policy, write: r.write)
    try check(r.rows.isEmpty, "website typing (G12): so Tab to it saves nothing")
    // An Incognito window open at the settle: dropped, as always.
    r = WebRig()
    r.type("before private")
    r.w.addWindow("404", mode: "incognito", front: false)
    tab(r, to: FakeAXNode("next", role: "AXTextField", parent: r.w.group, owner: pid))
    try check(r.rows.isEmpty && r.burst.session.parkedCount == 0 && !r.burst.session.hasLive,
              "website typing (G12): an Incognito window open at the settle drops the words")
    // Focus in the address bar (outside the page): nothing proves the page, so nothing is saved.
    r = WebRig()
    r.type("toolbar words")
    let toolbar = FakeAXNode("toolbar", role: "AXToolbar", parent: r.w.window, owner: pid)
    tab(r, to: FakeAXNode("omnibox", role: "AXTextField", parent: toolbar, owner: pid))
    try check(r.rows.isEmpty, "website typing (G12): focus in the address bar saves nothing")
    // Command-Return: saved at once with a click join (focus has moved to Send), like a click.
    r = WebRig()
    r.type("ship it")
    r.w.axFocus = FakeAXNode("send", role: "AXButton", parent: r.w.group, owner: pid)
    let at = r.w.clock; r.w.clock += 3_000_000
    let saved = r.burst.pointerDown(r.pageResult(), at: at, now: r.w.clock, policy: r.policy, reason: .shortcut, write: r.write)
    try check(saved == .committed(withheld: 0) && r.words == ["ship it"] && !r.burst.session.hasLive,
              "website typing (G12): Command-Return saves the words at once, with a click join of the same page")
    r.burst.boundary(.shortcut, at: at, now: r.w.clock, focusMoved: true)
    r.w.clock += 5_000_000_000; r.settle()
    try check(r.words == ["ship it"], "website typing (G12): Command-Return: saved once")
    // Review G12, round 1: a shortcut that keeps focus in the field parks the words; the settle's full
    // join proves the field, and a click join (which could fail and make the join forget the page) is
    // never taken, so the words are saved, as before the Tab fix.
    r = WebRig()
    r.type("draft for the launch notes")
    r.burst.boundary(.shortcut, at: r.w.clock, now: r.w.clock, focusMoved: true)
    r.w.clock += 450_000_000
    var joinsBefore = r.joins
    r.settle(failPage: true)
    try check(r.words == ["draft for the launch notes"] && r.joins == joinsBefore + 1,
              "website typing (G12): a shortcut that keeps focus: saved after the settle with one full join and no click join")
    // Tab to a button with a click join that fails: nothing proves the page, nothing is saved.
    r = WebRig()
    r.type("unproven")
    tabNoSettle(r, to: FakeAXNode("send", role: "AXButton", parent: r.w.group, owner: pid))
    joinsBefore = r.joins
    r.settle(failPage: true)
    try check(r.rows.isEmpty && r.joins == joinsBefore + 2 && r.burst.session.parkedCount == 0,
              "website typing (G12): Tab to a button with a click join that fails: nothing is saved")
    // The page a `.field` denial forgot is kept for the next join only, and only for a click join.
    r = WebRig()
    r.type("abc")
    guard let typedIn = r.result().proof else { try check(false, "website typing (G12): a full join of the field"); return }
    let button = FakeAXNode("send", role: "AXButton", parent: r.w.group, owner: pid)
    r.w.axFocus = button
    try check(r.result().denial == .field && r.pageResult().proof?.documentID == typedIn.documentID,
              "website typing (G12): a click join right after a full join denied .field proves the page from before the denial")
    _ = r.result()
    r.w.axFocus = r.w.field
    let fullAfter = r.result().proof
    try check(fullAfter != nil && fullAfter?.documentID != typedIn.documentID,
              "website typing (G12): a full join after a .field denial is a new page (only a click join may use the page from before)")
    r.w.axFocus = button
    _ = r.result()
    r.w.failing = ["bounds"]; _ = r.pageResult(); r.w.failing = []
    let clickAfter = r.pageResult().proof
    try check(clickAfter != nil && clickAfter?.documentID != fullAfter?.documentID,
              "website typing (G12): a denied click join forgets the page a .field denial kept")
    r.w.axFocus = button
    _ = r.result(); r.join.invalidate()
    try check(r.pageResult().proof.map { $0.documentID != clickAfter?.documentID } == true,
              "website typing (G12): invalidate forgets the page a .field denial kept")
    // gold/r2-typing (golden 5 G12): a click join refused for anything but privacy (a timeout: Command-Return
    // with focus kept in the field) leaves the page the last full join proved, so the settle's full join of the
    // same field names the same page. Refused for privacy, it forgets the page, as before.
    r = WebRig()
    r.type("kept page")
    guard let proven = r.result().proof else { try check(false, "website typing (G12): a full join of the field"); return }
    r.w.failing = ["bounds"]; let timedOut = r.pageResult(); r.w.failing = []
    try check(timedOut.proof == nil && r.result().proof?.documentID == proven.documentID,
              "website typing (G12): a click join refused by a timeout leaves the page: the next full join of the same field is the same page (was: a new page)")
    let typedURL = r.w.windows[0].url
    let refusals: [(String, (WebRig) -> Void, (WebRig) -> Void)] = [
        ("an Incognito window", { $0.w.addWindow("606", mode: "incognito", front: false) }, { $0.w.removeWindow("606") }),
        ("a Guest window", { $0.w.addWindow("607", mode: "guest", front: false) }, { $0.w.removeWindow("607") }),
        ("a blocked site", { $0.page("https://www.chase.com/") }, { $0.page(typedURL) }),
        ("typing off", { $0.w.enabled = false }, { $0.w.enabled = true }),
        ("a password field", { $0.w.axFocus = FakeAXNode("password", role: "AXTextField", subrole: "AXSecureTextField", parent: $0.w.group, owner: pid) },
         // fix/chrome-capture (QF-11): the password field leaves the page too (a password field beside the field refuses it).
         { $0.w.axFocus?.parent = nil; $0.w.axFocus = $0.w.field })]
    for (name, setUp, undo) in refusals {
        r = WebRig(); r.type("private page")
        guard let before = r.result().proof else { try check(false, "website typing (G12): a full join of the field"); return }
        setUp(r); let refused = r.pageResult(); undo(r)
        try check(refused.proof == nil && r.result().proof.map { $0.documentID != before.documentID } == true,
                  "website typing (G12): a click join refused for \(name) forgets the page")
    }
    // The route's order at a chorded Return with focus kept in the field: the click join (timed out: nothing is
    // saved at once), the boundary, then the settle's full join. Saved, as before the chorded Return took a click
    // join; every privacy refusal at the settle still drops the words.
    func chord(_ text: String) throws -> WebRig {
        let r = WebRig()
        r.type(text)
        let at = r.w.clock; r.w.clock += 3_000_000
        r.w.failing = ["bounds"]
        let atOnce = r.burst.pointerDown(r.pageResult(), at: at, now: r.w.clock, policy: r.policy, reason: .shortcut, write: r.write)
        r.w.failing = []
        try check(atOnce == nil && r.rows.isEmpty && r.burst.session.hasLive, "website typing (G12): setup: a click join that times out saves nothing at once")
        r.burst.boundary(.shortcut, at: at, now: r.w.clock, focusMoved: true)
        r.w.clock += 450_000_000
        return r
    }
    r = try chord("send when the join times out"); r.settle()
    try check(r.words == ["send when the join times out"] && r.burst.session.parkedCount == 0 && !r.burst.session.hasLive,
              "website typing (G12): Command-Return, focus kept, its click join timed out: the settle's full join saves the words (was: dropped)")
    r.w.clock += 5_000_000_000; r.settle()
    try check(r.words == ["send when the join times out"], "website typing (G12): saved once")
    r = try chord("chord then private"); r.w.addWindow("608", mode: "incognito", front: false); r.settle()
    try check(r.rows.isEmpty && r.burst.session.parkedCount == 0 && !r.burst.session.hasLive,
              "website typing (G12): the same with an Incognito window open at the settle: dropped")
    r = try chord("chord then guest"); r.w.addWindow("609", mode: "guest", front: false); r.settle()
    try check(r.rows.isEmpty && r.burst.session.parkedCount == 0, "website typing (G12): the same with a Guest window open at the settle: dropped")
    r = try chord("chord then blocked"); r.page("https://www.chase.com/"); r.settle()
    try check(r.rows.isEmpty && r.burst.session.parkedCount == 0, "website typing (G12): the same on a blocked site at the settle: dropped")
    r = try chord("chord then card"); r.w.field.labels = BrowserTypingFieldLabels(texts: ["Card number"], identifiers: ["cc-number"]); r.settle()
    try check(r.rows.isEmpty && r.burst.session.parkedCount == 0, "website typing (G12): the same in a card number field at the settle: dropped")
    r = try chord("chord then pin"); r.w.field.labels = BrowserTypingFieldLabels(texts: ["Enter your PIN"], identifiers: ["pin"]); r.settle()
    try check(r.rows.isEmpty && r.burst.session.parkedCount == 0, "website typing (G12): the same in a PIN field at the settle: dropped")
    r = try chord("chord then secure field"); r.w.field.subrole = "AXSecureTextField"; r.settle()
    try check(r.rows.isEmpty && r.burst.session.parkedCount == 0, "website typing (G12): the same in a password field at the settle: dropped")
    r = try chord("chord then secure input"); r.w.secure = true; r.settle(secure: true)
    try check(r.rows.isEmpty && r.burst.session.parkedCount == 0, "website typing (G12): the same with secure input on at the settle: dropped")
    r = try chord("chord then another page"); r.page("https://notes.example.org/pad/8"); r.settle()
    try check(r.rows.isEmpty && r.burst.session.parkedCount == 0, "website typing (G12): the same on another page at the settle: dropped")
    // A light check never proves a click or a save.
    r = WebRig(); r.useLight = true
    r.type("light")
    guard let lightProof = r.lightResult()?.proof, lightProof.light else { try check(false, "website typing (G51): a light proof for the open burst"); return }
    try check(r.burst.pointerDown(.allowed(lightProof), at: lightProof.checkedAt, now: r.w.clock, policy: r.policy, write: r.write) == nil
              && r.burst.save(.allowed(lightProof), typedAt: nil, processedAt: r.w.clock) == nil,
              "website typing (G51): a light proof never saves and never proves a click")
}

/// Review G51: between full joins, keys of an open burst are admitted by the
/// light per-key check (a few reads instead of a full double-read join), and
/// every privacy rule still holds.
private func checkWebLightKeys() throws {
    func burst(_ r: WebRig, _ text: String) -> (joins: Int, lights: Int, ae: Int) {
        let j = r.joins, l = r.lights, a = r.w.aeCount
        r.type(text)
        return (r.joins - j, r.lights - l, r.w.aeCount - a)
    }
    // Steady typing: one full join starts the burst; the other keys take the light check.
    var r = WebRig(); r.useLight = true
    let full = WebRig()
    let fullCost = burst(full, "abcd")
    let cost = burst(r, "ship the pricing")
    try check(cost.joins == 2 && cost.lights == 15, "website typing (G51): 16 keys: a full join starts the burst, the light check admits the others until its proof is a second old, then a full join again (\(cost))")
    try check(cost.ae * 3 < fullCost.ae * 4, "website typing (G51): 16 keys send under a third of the Apple Events of a full join per key (\(cost.ae) vs \(fullCost.ae * 4))")
    r.key(.submit)
    try check(r.words == ["ship the pricing"] && r.reads == 16, "website typing (G51): every key is read once and Return saves the words (with a full join)")
    // Privacy: every change a full join would refuse also stops the light check, and the full join then drops.
    let pid = FakeChromeWorld.chromePID
    let cases: [(String, (WebRig) -> Void)] = [
        ("an Incognito window opens", { $0.w.addWindow("505", mode: "incognito", front: false) }),
        ("a window whose mode can't be read opens", { $0.w.addWindow("506", mode: nil, front: false) }),
        ("the field turns into a password field", { $0.w.field.subrole = "AXSecureTextField" }),
        ("the field's label turns into Card number", { $0.w.field.labels = BrowserTypingFieldLabels(texts: ["Card number"], identifiers: []) }),
        ("the field becomes a message composer (Messages and email off)", { $0.w.field.labels = BrowserTypingFieldLabels(texts: ["Type a message"], identifiers: []) }),
        ("the site is blocked", { $0.sites.alwaysBlocked.append("example.org") }),
        ("typing is turned off", { $0.w.enabled = false }),
        ("secure input turns on", { $0.w.secure = true }),
        ("Spotlight takes the keys", { $0.w.systemFocused = 999 }),
        ("focus moves to another field", { $0.w.axFocus = FakeAXNode("other", role: "AXTextField", parent: $0.w.group, owner: pid) }),
        ("the page changes", { $0.w.web.url = "https://notes.example.org/pad/9"; $0.w.windows[0].url = "https://notes.example.org/pad/9" }),
        ("Chrome relaunches", { $0.w.facts = ChromeTargetFacts(pid: pid, bundleID: "com.google.Chrome", launchIdentity: "4242:1790000999:com.google.Chrome",
                                                               signatureValid: true, bundleVersion: "153.0.8010.54", frameworkVersions: ["153.0.8010.54"], instances: 1) }),
    ]
    for (name, change) in cases {
        // fix/typing-e2e L1: Messages and email is on by default, so the composer case turns it off first.
        r = name.contains("Messages and email off") ? WebRig(choices: TypedCategoryChoices(messagesAndEmail: false)) : WebRig(); r.useLight = true
        r.type("half a")
        change(r)
        let lightsBefore = r.lights
        let light = r.lightResult()
        r.type(" thought"); r.key(.submit)
        try check(light == nil && r.lights > lightsBefore && !r.words.contains { $0.contains("half a") },
                  "website typing (G51): \(name): the light check refuses and the unsaved words are never saved together with later ones")
    }
    // A light check never starts a burst: after Return (and after any denial) the next key takes a full join.
    r = WebRig(); r.useLight = true
    r.type("one"); r.key(.submit)
    r.w.clock += BrowserTypingTiming.quietNanoseconds
    let joinsBefore = r.joins
    r.type("t")
    try check(r.joins == joinsBefore + 1, "website typing (G51): the first key after Return takes a full join")
    // A click join clears what the light check compares with.
    r = WebRig(); r.useLight = true
    r.type("ab")
    _ = r.pageResult()
    try check(r.lightResult() == nil, "website typing (G51): after a click join the next key takes a full join")
    // Too slow: the light check gives way to the full join.
    r = WebRig(); r.useLight = true
    r.type("ab")
    r.w.tick = 50_000_000   // fix/chrome-root: the light budget is 120 ms (3 events of 50 ms run over it)
    try check(r.lightResult() == nil, "website typing (G51): a light check over its budget has no proof")
}
/// fix/x-typing (the owner, test 7: "X is not recording keystrokes"): X's post
/// box sits about 60 parent steps below its window (`FakeChromeWorld.deepen`),
/// past the join's old 48-step walk, so every key was refused (`.frame`) and
/// nothing typed on x.com was kept. Typed at a normal pace or fast, with the
/// light per-key check, emoji, deletes and a replaced selection, it saves now;
/// secure and sensitive boxes on the same deep page still save nothing and
/// read no key.
private func checkWebXDeepPage() throws {
    func xRig(_ choices: TypedCategoryChoices = TypedCategoryChoices(), light: Bool = false) -> WebRig {
        let r = WebRig(choices: choices, url: "https://x.com/home"); r.w.xPage(); r.w.deepen(dom: 48); r.useLight = light; return r
    }
    var r = xRig()
    r.type("gm everyone"); r.key(.submit)
    try check(r.words == ["gm everyone"] && r.rows.first?.url == "https://x.com" && r.rows.first?.role == "AXTextArea",
              "website typing (fix/x-typing): X's post box 61 steps down saves its words with the site only (\(r.words))")
    for light in [false, true] {
        r = xRig(light: light)
        func fast(_ intent: KeyIntent, _ text: String = "") { r.key(intent, text); r.w.clock += 10_000_000 }
        for c in "shipping today " { fast(.insert(nil), String(c)) }
        fast(.insert(nil), "😀"); fast(.insert(nil), "☕️")
        fast(.edit(.deleteBackward(.character)))
        fast(.edit(.moveBackward(.character, extend: true)))
        fast(.insert(nil), "🚀")
        r.key(.submit)
        try check(r.words == ["shipping today 🚀"] && (!light || r.lights > 0),
                  "website typing (fix/x-typing): fast keys on X (10 ms apart\(light ? ", light check" : "")), emoji, a delete and a replaced selection save what is in the box (\(r.words))")
    }
    // A joined emoji read from a key: the session keeps no format characters (the joiner), so its parts are kept.
    r = xRig(); r.type("family "); r.key(.insert(nil), "👩‍👩‍👧"); r.key(.submit)
    try check(r.words == ["family 👩👩👧"], "website typing (fix/x-typing): a joined emoji on X is kept as its parts, nothing lost around it (\(r.words))")
    // The search box on /explore, as deep.
    r = xRig(); r.page("https://x.com/explore"); r.w.field.role = "AXComboBox"; r.w.field.editableAncestor = r.w.field
    r.w.field.labels = BrowserTypingFieldLabels(texts: ["Search query", "Search"], identifiers: [])
    r.type("release notes 2.3"); r.key(.submit)
    try check(r.words == ["release notes 2.3"] && r.rows.first?.role == "AXComboBox", "website typing (fix/x-typing): X's search box 61 steps down saves its words (\(r.words))")
    // Refusals at X's depth: nothing saved, no key read.
    r = xRig(TypedCategoryChoices(messagesAndEmail: false)); r.type("gm everyone"); r.key(.submit)
    try check(r.reads == 0 && r.rows.isEmpty, "website typing (fix/x-typing): X 61 steps down with Messages and email off: nothing read or saved")
    r = xRig(); r.w.field.role = "AXTextField"; r.w.field.subrole = "AXSecureTextField"; r.type("hunter2 pass"); r.key(.submit)
    try check(r.reads == 0 && r.rows.isEmpty, "website typing (fix/x-typing): a password field 61 steps down: nothing read or saved")
    r = xRig(); r.w.field.labels = BrowserTypingFieldLabels(texts: ["Verification code"], identifiers: []); r.type("482913"); r.key(.submit)
    try check(r.reads == 0 && r.rows.isEmpty, "website typing (fix/x-typing): a verification code box 61 steps down: nothing read or saved")
    r = xRig(); r.w.secure = true; r.type("hunter2 pass"); r.key(.submit)
    try check(r.reads == 0 && r.rows.isEmpty, "website typing (fix/x-typing): macOS secure input on X: nothing read or saved")
    r = xRig(); r.page("https://x.com/i/flow/login"); r.type("someone@example.org"); r.key(.submit)
    try check(r.reads == 0 && r.rows.isEmpty, "website typing (fix/x-typing): X's sign-in page: nothing read or saved")
}

/// fix/web-textbox (the owner, 2026-09-28: "some of the things we are typing
/// on X and other websites are being thrown away"): an unmarked text box
/// saves its words; X's post box (Draft.js) saves with Messages and email on;
/// secure and sensitive boxes still save nothing.
private func checkWebUnmarkedBoxes() throws {
    let none = BrowserTypingFieldLabels(texts: [], identifiers: [])
    let draft = BrowserTypingFieldLabels(texts: ["Post text"], identifiers: ["notranslate", "public-DraftEditor-content"])
    // Codex 06:10: a box with no label, description or placeholder saves nothing (field), a stated loss.
    var r = WebRig(); r.w.field.labels = none
    r.type("an unmarked box"); r.key(.submit)
    try check(r.rows.isEmpty && r.result().denial == .field, "website typing (Codex 06:10): a box with no label, placeholder, id or class saves nothing")
    r = WebRig(); r.w.field.labels = BrowserTypingFieldLabels(texts: [], identifiers: ["notranslate", "public-DraftEditor-content"])
    r.type("a draft js box"); r.key(.submit)
    try check(r.rows.isEmpty, "website typing (Codex 06:10): an unlabelled Draft.js editor saves nothing")
    r = WebRig(); r.w.field.labels = BrowserTypingFieldLabels(texts: ["Post text"], identifiers: ["notranslate", "public-DraftEditor-content"])
    r.type("a draft js box"); r.key(.submit)
    try check(r.words == ["a draft js box"], "website typing (fix/web-textbox): a labelled Draft.js editor on an Other websites page saves its words")
    r = WebRig(choices: TypedCategoryChoices(messagesAndEmail: false), url: "https://x.com/home"); r.w.field.labels = draft
    r.type("gm everyone"); r.key(.submit)
    try check(r.reads == 0 && r.rows.isEmpty && r.result().denial == .blockedSite,
              "website typing (fix/web-textbox): X with Messages and email turned off: nothing typed")
    // Codex 06:10: X's box without its label is refused (field).
    r = WebRig(choices: TypedCategoryChoices(messagesAndEmail: true), url: "https://x.com/home"); r.w.field.labels = none
    r.type("gm everyone"); r.key(.submit)
    try check(r.rows.isEmpty && r.result().denial == .field, "website typing (Codex 06:10): X's post box with no label saves nothing (field)")
    for labels in [draft] {
        r = WebRig(choices: TypedCategoryChoices(messagesAndEmail: true), url: "https://x.com/home"); r.w.field.labels = labels
        r.type("gm everyone"); r.key(.submit)
        try check(r.words == ["gm everyone"] && r.rows.first?.url == "https://x.com" && r.rows.first?.role == "AXTextArea",
                  "website typing (fix/web-textbox): X's post box \(labels.texts + labels.identifiers) with Messages and email on saves its words, with the site only")
    }
    // An editable combo box (a search box with suggestions), with its label or placeholder.
    r = WebRig(url: "https://shop.example.org/search")
    r.w.field.role = "AXComboBox"; r.w.field.subrole = ""; r.w.field.labels = BrowserTypingFieldLabels(texts: ["Search"], identifiers: [])
    r.w.field.editableAncestor = r.w.field
    r.type("red boots"); r.key(.submit)
    try check(r.words == ["red boots"] && r.rows.first?.role == "AXComboBox", "website typing (fix/web-textbox): a search combo box saves its words")
    // QF-4 (option a), a stated loss: the same box with no label, description or placeholder is refused (field).
    r = WebRig(url: "https://shop.example.org/search")
    r.w.field.role = "AXComboBox"; r.w.field.subrole = ""; r.w.field.labels = none; r.w.field.editableAncestor = r.w.field
    r.type("red boots"); r.key(.submit)
    try check(r.rows.isEmpty && r.result().denial == .field, "website typing (QF-4): an unlabelled combo box saves nothing (field)")
    r = WebRig(url: "https://shop.example.org/search")
    r.w.field.role = "AXComboBox"; r.w.field.subrole = ""; r.w.field.labels = none; r.w.field.editableAncestor = nil
    r.type("size nine"); r.key(.submit)
    try check(r.reads == 0 && r.rows.isEmpty, "website typing (fix/web-textbox): a combo box that isn't its own editable root: nothing typed")
    // Secure and sensitive boxes, unmarked or named: nothing is read or saved.
    let refusals: [(String, (WebRig) -> Void)] = [
        ("an unmarked password field", { $0.w.field.role = "AXTextField"; $0.w.field.subrole = "AXSecureTextField"; $0.w.field.labels = none }),
        ("a password <input role=combobox> as Chromium reports it (AXComboBox, no secure subrole, secure input on)", {
            $0.w.field.role = "AXComboBox"; $0.w.field.subrole = ""; $0.w.field.labels = none; $0.w.field.editableAncestor = $0.w.field; $0.w.secure = true }),
        ("a combo box reporting a secure subrole (not the guard)", { $0.w.field.role = "AXComboBox"; $0.w.field.subrole = "AXSecureTextField"
                                                            $0.w.field.labels = none; $0.w.field.editableAncestor = $0.w.field }),
        ("an unmarked box under macOS secure input", { $0.w.field.labels = none; $0.w.secure = true }),
        ("a box labelled password", { $0.w.field.labels = BrowserTypingFieldLabels(texts: ["Enter your password"], identifiers: []) }),
        ("a cc-number box", { $0.w.field.labels = BrowserTypingFieldLabels(texts: [], identifiers: ["cc-number"]) }),
        ("a one-time-code box", { $0.w.field.labels = BrowserTypingFieldLabels(texts: [], identifiers: ["one-time-code"]) }),
        ("an unmarked box with an Incognito window open", { $0.w.field.labels = none; $0.w.addWindow("666", mode: "incognito", front: false) }),
        ("an unmarked box on a blocked site", { $0.w.field.labels = none; $0.sites.alwaysBlocked.append("example.org") }),
    ]
    for (name, setup) in refusals {
        r = WebRig(); setup(r)
        r.type("hunter2 secret"); r.key(.submit)
        try check(r.reads == 0 && r.rows.isEmpty, "website typing (fix/web-textbox): \(name): nothing read or saved")
    }
}
/// fix/web-textbox (battery; the owner, 2026-09-28: "it is just burning
/// battery life"): a key the burst rules drop whatever a join says takes no
/// join. Before, every key on a refused page (X, Reddit, Gmail and every other
/// Messages and email site with that switch off, the default; blocked sites;
/// Incognito open) ran a full join of about 16 Apple Events plus the
/// Accessibility walk, and every key in the quiet period ran one too.
private func checkWebRefusedKeysCost() throws {
    let pid = FakeChromeWorld.chromePID
    func cost(_ r: WebRig, _ body: () -> Void) -> (joins: Int, ae: Int, ax: Int) {
        let j = r.joins, a = r.w.aeCount, l = r.w.log.count
        body()
        return (r.joins - j, r.w.aeCount - a, r.w.log[l...].filter { $0.hasPrefix("ae:") || $0.hasPrefix("ax:") }.count)
    }
    // 1. Keys typed in the quiet period after Return: no join, no Apple Event, no Accessibility read.
    var r = WebRig()
    r.type("first"); r.key(.submit)
    var c = cost(r) { r.type("ab") }
    try check(c == (0, 0, 0) && r.reads == 5 && !r.burst.session.hasLive,
              "website typing (battery): keys in the quiet period after Return take no join and log no ae: or ax: read (\(c))")
    // ...and typing straight on (no pause) resumes once the quiet period ends, as before.
    r = WebRig()
    r.type("first"); r.key(.submit)
    r.type("and then the rest"); r.key(.submit)
    try check(r.words.count == 2 && r.words[0] == "first" && !r.words[1].isEmpty && "and then the rest".hasSuffix(r.words[1]),
              "website typing (battery): continuous typing after Return is kept from the end of the quiet period (\(r.words))")
    // 2. X with Messages and email turned off: 20 keys cost at most a full join per second, not one per key.
    r = WebRig(choices: TypedCategoryChoices(messagesAndEmail: false), url: "https://x.com/home")
    r.w.field.labels = BrowserTypingFieldLabels(texts: ["Post text"], identifiers: ["notranslate", "public-DraftEditor-content"])
    c = cost(r) { r.type("gm everyone, ship it") }
    try check(c.joins == 2 && r.reads == 0 && r.rows.isEmpty,
              "website typing (battery): 20 keys on X with Messages and email off take 2 full joins, not 20, and read nothing (\(c))")
    // The hold ends at a click (a new join, still refused here) ...
    r.burst.boundary(.pointer, at: r.w.clock, now: r.w.clock, focusMoved: true)
    r.w.clock += BrowserTypingTiming.quietNanoseconds
    c = cost(r) { r.key(.insert(nil), "x") }
    try check(c.joins == 1 && r.reads == 0, "website typing (battery): after a click the next key takes a fresh join (\(c))")
    // ... and at a policy change: turning on Messages and email types on X at once.
    r.sites.choices = TypedCategoryChoices(messagesAndEmail: true)
    r.burst.invalidate(.policy)
    r.w.clock += BrowserTypingTiming.quietNanoseconds
    r.type("gm"); r.key(.submit)
    try check(r.words == ["gm"], "website typing (battery): Messages and email turned on: the next keys on X are typed")
    // ... and by itself after refusedHoldNanoseconds (the page may have changed with no input).
    r = WebRig(choices: TypedCategoryChoices(messagesAndEmail: false), url: "https://x.com/home")
    r.type("a")
    r.page("https://notes.example.org/pad/7")
    r.w.clock += BrowserTypingTiming.refusedHoldNanoseconds
    r.type("notes"); r.key(.submit)
    try check(r.words == ["notes"], "website typing (battery): a second after a refusal the next key takes a fresh join again")
    // 3. An Incognito window or a sensitive field: the same hold; nothing is read either way.
    for (name, change) in [("an Incognito window opens", { (r: WebRig) in r.w.addWindow("707", mode: "incognito", front: false) }),
                           ("the field is a card number", { (r: WebRig) in r.w.field.labels = BrowserTypingFieldLabels(texts: ["Card number"], identifiers: []) })] {
        r = WebRig()
        r.type("half")
        change(r)
        c = cost(r) { r.type("4111 1111") }
        r.key(.submit)
        try check(c.joins == 1 && r.reads == 4 && r.rows.isEmpty && !r.burst.session.hasLive,
                  "website typing (battery): \(name): 9 keys in under a second take one refused join, the rest are dropped unread, and the draft before it is dropped (\(c))")
    }
    // 4. Focus off any text box (`.field`) is not held: a site's own shortcut ("/" on YouTube, "n" on X) can
    //    move focus into a box with no click, and the typing that follows is kept after the quiet period.
    r = WebRig(url: "https://shop.example.org/")
    r.w.axFocus = FakeAXNode("page-button", role: "AXButton", parent: r.w.group, owner: pid)
    r.key(.insert(nil), "/")
    try check(r.burst.heldUntil == nil, "website typing (battery): focus on a button (.field) starts no hold")
    r.w.axFocus = r.w.field
    r.w.clock += BrowserTypingTiming.quietNanoseconds
    r.type("red boots"); r.key(.submit)
    try check(r.words == ["red boots"], "website typing (battery): a site shortcut moves focus into the box: the words after the quiet period are kept")
    // 5. Saves still take their own fresh join: Return on a held page is refused, never saved.
    r = WebRig(choices: TypedCategoryChoices(messagesAndEmail: false), url: "https://x.com/home")
    r.type("gm"); c = cost(r) { r.key(.submit) }
    try check(c.joins == 1 && r.rows.isEmpty, "website typing (battery): Return during a hold still takes a full join, which refuses")
}

/// Review Q6-1: frames are scanned after the page, so a page's password field behind an early frame still refuses the
/// field focus moves to (`sensitiveField`), and the draft parked by the move is discarded; `exhausted` (`field`) there
/// would have saved it.
private func checkWebFrameOrder() throws {
    let pid = FakeChromeWorld.chromePID
    for password in [true, false] {
        let r = WebRig()
        r.type("draft words")
        // The page grows a login form with a 40-node frame before it; focus moves (Tab) to its Email box.
        let frame = FakeAXNode("frame-web", role: "AXWebArea", parent: r.w.web, owner: pid)
        for i in 0..<40 { _ = FakeAXNode("frame-row\(i)", role: "AXStaticText", parent: frame, owner: pid) }
        let pwBox = FakeAXNode("pw-box", role: "AXGroup", parent: r.w.web, owner: pid)
        for i in 0..<30 { _ = FakeAXNode("page-row\(i)", role: "AXStaticText", parent: r.w.web, owner: pid) }
        if password { _ = FakeAXNode("page-pw", role: "AXTextField", subrole: "AXSecureTextField", parent: pwBox, owner: pid) }
        let email = FakeAXNode("email", role: "AXTextField", parent: FakeAXNode("login", role: "AXGroup", parent: r.w.web, owner: pid), owner: pid)
        email.labels = BrowserTypingFieldLabels(texts: ["Email"], identifiers: [])
        r.burst.boundary(.focusKey, at: r.w.clock, now: r.w.clock, focusMoved: true)
        r.w.axFocus = email
        r.w.clock += 450_000_000
        r.settle()
        if password {
            try check(r.rows.isEmpty && r.burst.session.parkedCount == 0,
                      "Q6-1: Tab to an Email box whose page has a password field behind a 40-node frame: sensitiveField, the parked draft is discarded")
        } else {
            try check(r.words == ["draft words"],
                      "Q6-1 control: the same page without the password field: the frames exhaust the scan (field), and the parked draft is saved")
        }
    }
}

/// Codex 07:10 (field hold): after a key's full join refuses a text box as `field` once its form scan returned (no
/// label, or a scan that can't finish), plain keys in the same box, in the same burst, with no
/// disruptive input, are dropped unread with no join. The hold only keeps the refusal.
private func checkWebFieldHold() throws {
    let pid = FakeChromeWorld.chromePID
    let none = BrowserTypingFieldLabels(texts: [], identifiers: [])
    func cost(_ r: WebRig, _ body: () -> Void) -> (joins: Int, ae: Int, labels: Int) {
        let j = r.joins, a = r.w.aeCount, l = r.w.log.count
        body()
        return (r.joins - j, r.w.aeCount - a, r.w.log[l...].filter { $0.hasPrefix("ax:labels:") || $0.hasPrefix("ax:children:") }.count)
    }
    /// A rig with focus in an unlabelled box whose first key was refused, past the quiet period.
    func held(_ refuse: (WebRig) -> Void = { $0.w.field.labels = BrowserTypingFieldLabels(texts: [], identifiers: []) }) -> WebRig {
        let r = WebRig(); refuse(r)
        r.type("ab")            // "a": refused (field); "b": in the quiet period
        r.w.clock += 300_000_000
        return r
    }
    // 1. No re-join during the hold, for each box refusal: no label, a form scan that can't finish, unreadable labels.
    let refusals: [(String, (WebRig) -> Void)] = [
        ("an unlabelled box", { $0.w.field.labels = none }),
        ("a punctuation-only label", { $0.w.field.labels = BrowserTypingFieldLabels(texts: ["*"], identifiers: []) }),
        ("a box beside 100 links (scan exhausted)", { r in for i in 0..<100 { _ = FakeAXNode("feed\(i)", role: "AXLink", parent: r.w.group, owner: pid) } }),
    ]
    for (name, refuse) in refusals {
        let r = held(refuse)
        try check(r.joins == 1 && r.burst.fieldHeld, "field hold: \(name): the first key's full join refuses it (field) and starts the hold")
        let c = cost(r) { r.type("hunter2 secret words") }
        try check(c == (0, 0, 0) && r.reads == 0 && !r.burst.session.hasLive && (1..<20).contains(r.holdChecks),
                  "field hold: \(name): 20 keys in the same box take no join, no Apple Event, no label or scan read, and are not read; each held drop starts the quiet period again, so fewer focus checks (\(c), \(r.holdChecks) checks)")
        r.key(.submit)
        r.w.clock += 5_000_000_000; r.settle()
        try check(r.rows.isEmpty, "field hold: \(name): nothing typed during the hold is saved (Return, the settle)")
    }
    // Focus on a button (`.field`, not a box) records no box: after the quiet period every key takes the full join.
    do {
        let r = WebRig(url: "https://shop.example.org/")
        r.w.axFocus = FakeAXNode("page-button", role: "AXButton", parent: r.w.group, owner: pid)
        r.key(.insert(nil), "/")
        r.w.clock += BrowserTypingTiming.quietNanoseconds
        let c = cost(r) { for k in ["x", "y", "z"] { r.key(.insert(nil), k); r.w.clock += BrowserTypingTiming.quietNanoseconds } }
        try check(c.joins == 3 && r.holdChecks == 3, "field hold: focus on a button records no box; each later key takes the full join (\(c))")
        r.w.axFocus = r.w.field
        r.w.clock += BrowserTypingTiming.quietNanoseconds
        r.type("red boots"); r.key(.submit)
        try check(r.words == ["red boots"], "field hold: a site shortcut moves focus from a button into a labelled box: typed")
    }
    // 2. Every boundary ends the hold: the next key takes the full join, and a labelled box after it is typed.
    let labelled = BrowserTypingFieldLabels(texts: ["Notes"], identifiers: [])
    let boundaries: [(String, (WebRig) -> Void)] = [
        // (Review FH-1: the first key after a focus move with no input is dropped, then the quiet period.)
        ("focus moves to another box (no input)", { r in
            let other = FakeAXNode("notes-2", role: "AXTextArea", parent: r.w.group, owner: pid); other.labels = labelled; r.w.axFocus = other
            r.w.clock += BrowserTypingTiming.quietNanoseconds; _ = r.key(.insert(nil), "q"); r.w.clock += BrowserTypingTiming.quietNanoseconds }),
        ("a click", { r in r.burst.boundary(.pointer, at: r.w.clock, now: r.w.clock, focusMoved: true)
            r.w.clock += BrowserTypingTiming.quietNanoseconds; r.w.field.labels = labelled }),
        ("Tab", { r in r.key(.leave(.focusKey, marker: false)); r.w.clock += BrowserTypingTiming.quietNanoseconds; r.w.field.labels = labelled }),
        // (Return takes its own full join: the label is there by then.)
        ("Return", { r in r.w.field.labels = labelled; r.key(.submit); r.w.clock += BrowserTypingTiming.quietNanoseconds }),
        ("an input-source change", { r in r.burst.endHolds(); r.w.clock += BrowserTypingTiming.quietNanoseconds; r.w.field.labels = labelled }),
        ("a window change", { r in
            let other = FakeAXNode("window-202", role: "AXWindow", subrole: "AXStandardWindow", owner: pid)
            r.w.axWindow = other; r.w.clock += BrowserTypingTiming.quietNanoseconds; _ = r.key(.insert(nil), "q")
            r.w.axWindow = r.w.window; r.w.clock += BrowserTypingTiming.quietNanoseconds; r.w.field.labels = labelled }),
        ("a key in another app (Chrome not frontmost)", { r in
            r.w.frontmost = 99; r.w.clock += BrowserTypingTiming.quietNanoseconds; _ = r.key(.insert(nil), "q")
            r.w.frontmost = pid; r.w.clock += BrowserTypingTiming.quietNanoseconds; r.w.field.labels = labelled }),
        ("a pause of a second", { r in r.w.clock += BrowserTypingTiming.refusedHoldNanoseconds; r.w.field.labels = labelled }),
        ("a privacy boundary", { r in r.burst.invalidate(.policy); r.w.clock += BrowserTypingTiming.quietNanoseconds; r.w.field.labels = labelled }),
        // Review FH-3: secure input turns on mid-hold (a password field anywhere on the Mac): the next key is dropped
        // unread and the hold ends; the join after the quiet period refuses while it is on.
        ("secure input on and off", { r in
            r.w.secure = true; r.w.clock += BrowserTypingTiming.quietNanoseconds
            let before = (r.joins, r.reads)
            _ = r.key(.insert(nil), "q")
            r.w.clock += BrowserTypingTiming.quietNanoseconds; _ = r.key(.insert(nil), "q")
            if r.joins != before.0 + 1 || r.reads != before.1 || r.burst.fieldHeld { r.rows.append(("FH-3 broken", "", "")) }
            r.w.secure = false; r.w.clock += BrowserTypingTiming.quietNanoseconds; r.w.field.labels = labelled }),
    ]
    for (name, end) in boundaries {
        let r = held()
        _ = cost(r) { r.type("zz") }
        end(r)
        let c = cost(r) { r.type("after the boundary") }
        r.key(.submit)
        try check(c.joins >= 1 && r.words == ["after the boundary"],
                  "field hold: after \(name) the next key takes the full join and a labelled box is typed (\(c), \(r.words))")
    }
    // A boundary into the same unlabelled box: the full join refuses again (one join), and the hold starts again.
    do {
        let r = held()
        r.burst.boundary(.pointer, at: r.w.clock, now: r.w.clock, focusMoved: true)
        r.w.clock += BrowserTypingTiming.quietNanoseconds
        let c = cost(r) { r.type("still unlabelled") }
        try check(c.joins == 1 && r.burst.fieldHeld && r.reads == 0, "field hold: a click back into the same unlabelled box: one refused join, then held (\(c))")
    }
    // 3. STATED COST: a box that gets a label mid-burst stays refused until the burst ends (no boundary, no pause).
    do {
        let r = held()
        r.w.field.labels = labelled
        let c = cost(r) { r.type("late label") }
        r.key(.submit)
        try check(c.joins == 0 && r.rows.isEmpty, "field hold STATED COST: a box labelled mid-burst stays refused until a boundary or a pause (\(c))")
        r.w.clock += BrowserTypingTiming.quietNanoseconds
        r.type("then kept"); r.key(.submit)
        try check(r.words == ["then kept"], "field hold STATED COST: after Return (a boundary) the labelled box is typed")
    }
    // 4. The hold never allows: a password or card box with focus while the hold is on is still refused by a join
    //    (the hold drops keys; any change of focus takes the full join).
    do {
        let r = held()
        let card = FakeAXNode("card", role: "AXTextField", parent: r.w.group, owner: pid)
        card.labels = BrowserTypingFieldLabels(texts: ["Card number"], identifiers: [])
        r.w.axFocus = card
        let c = cost(r) { r.type("4111"); r.w.clock += BrowserTypingTiming.quietNanoseconds; r.type("1") }
        try check(c.joins == 1 && r.reads == 0 && r.rows.isEmpty && !r.burst.fieldHeld,
                  "field hold: focus moves to a card box: the first key is dropped (FH-1), then the full join refuses it (sensitiveField), nothing read (\(c))")
    }
    // Review FH-1: more than 400 ms into a hold, a script moves focus from the refused box X to a labelled box B with
    // no input. The next key (it may have been typed in X) is dropped unread with no join and no row; B is typed after
    // the quiet period.
    do {
        let r = held()
        r.type("zz")
        r.w.clock += BrowserTypingTiming.quietNanoseconds
        let b = FakeAXNode("box-b", role: "AXTextArea", parent: r.w.group, owner: pid); b.labels = labelled
        r.w.axFocus = b
        let c = cost(r) { r.key(.insert(nil), "9") }
        try check(c == (0, 0, 0) && r.reads == 0 && r.rows.isEmpty && !r.burst.session.hasLive && !r.burst.fieldHeld,
                  "FH-1: a scripted focus move out of the held box: the next key is dropped unread (no join, no read, no row) and the hold ends (\(c))")
        r.w.clock += 100_000_000
        let q = cost(r) { r.key(.insert(nil), "8") }
        try check(q.joins == 0 && r.reads == 0, "FH-1: keys in the quiet period after it are dropped too (\(q))")
        r.w.clock += BrowserTypingTiming.quietNanoseconds
        r.type("in box b"); r.key(.submit)
        try check(r.words == ["in box b"], "FH-1: after the quiet period box B is typed (\(r.words))")
    }
    // Review (08:44) 1: the hold is set on `field` only after the form scan returned. Labels that can't be read
    // (`field` before any scan) and a timeout never hold: each later key takes the full join.
    do {
        let r = WebRig(); r.w.field.labels = nil
        r.key(.insert(nil), "a")
        r.w.clock += BrowserTypingTiming.quietNanoseconds
        let c = cost(r) { for k in ["b", "c", "d"] { r.key(.insert(nil), k); r.w.clock += BrowserTypingTiming.quietNanoseconds } }
        try check(c.joins == 3 && r.reads == 0, "field hold (1): labels that can't be read (field before the scan): no hold, each key joins (\(c))")
    }
    // A timeout (the scan ran out of time) discards the parked draft, as before, and starts no hold.
    func tabToSlowBox(_ r: WebRig) -> FakeAXNode {
        let slow = FakeAXNode("slow-box", role: "AXTextField", parent: FakeAXNode("slow-form", role: "AXGroup", parent: r.w.web, owner: pid), owner: pid)
        slow.labels = labelled
        r.w.childrenTick = BrowserTypingTiming.joinBudgetNanoseconds
        r.burst.boundary(.focusKey, at: r.w.clock, now: r.w.clock, focusMoved: true)
        r.w.axFocus = slow
        r.w.clock += 450_000_000
        r.settle()
        return slow
    }
    do {
        let r = WebRig()
        r.type("draft before the slow box")
        let slow = tabToSlowBox(r)
        try check(r.rows.isEmpty && r.burst.session.parkedCount == 0 && !r.burst.fieldHeld,
                  "field hold (1): Tab to a box whose scan times out: the parked draft is discarded and no hold starts")
        r.w.clock += BrowserTypingTiming.quietNanoseconds
        let c = cost(r) { for k in ["x", "y", "z"] { r.key(.insert(nil), k); r.w.clock += BrowserTypingTiming.quietNanoseconds } }
        try check(c.joins == 3 && r.holdChecks == 0, "field hold (1): after a timeout every key takes the full join (no hold) (\(c))")
        // Review (08:44) 2: the hold never brings back a discarded draft. The box then loses its label (field: held),
        // a click ends the hold, it gets its label back: only the words typed after are saved.
        r.w.childrenTick = 0
        slow.labels = none
        r.w.clock += BrowserTypingTiming.quietNanoseconds
        r.type("held keys")
        try check(r.burst.fieldHeld && r.rows.isEmpty, "field hold (2): the box refused as field after the timeout: held, nothing saved")
        r.burst.boundary(.pointer, at: r.w.clock, now: r.w.clock, focusMoved: true)
        r.w.clock += BrowserTypingTiming.quietNanoseconds
        slow.labels = labelled
        r.type("fresh words"); r.key(.submit)
        r.w.clock += 5_000_000_000; r.settle()
        try check(r.words == ["fresh words"], "field hold (2): a draft a timeout discarded never comes back (\(r.words))")
    }
    do {
        // The same after sensitiveField (a password field beside the box the draft left for).
        let r = WebRig()
        r.type("draft before the login form")
        let form = FakeAXNode("login", role: "AXGroup", parent: r.w.web, owner: pid)
        let email = FakeAXNode("email", role: "AXTextField", parent: form, owner: pid); email.labels = labelled
        let pw = FakeAXNode("pw", role: "AXTextField", subrole: "AXSecureTextField", parent: form, owner: pid)
        r.burst.boundary(.focusKey, at: r.w.clock, now: r.w.clock, focusMoved: true)
        r.w.axFocus = email
        r.w.clock += 450_000_000
        r.settle()
        try check(r.rows.isEmpty && r.burst.session.parkedCount == 0 && !r.burst.fieldHeld,
                  "field hold (2): Tab to a box beside a password field: sensitiveField discards the draft, no field hold")
        form.kids.removeAll { $0 === pw }; email.labels = none
        r.w.clock += BrowserTypingTiming.refusedHoldNanoseconds
        r.type("held keys")
        try check(r.burst.fieldHeld && r.rows.isEmpty, "field hold (2): the password field gone, the box unlabelled: held")
        r.burst.boundary(.pointer, at: r.w.clock, now: r.w.clock, focusMoved: true)
        r.w.clock += BrowserTypingTiming.quietNanoseconds
        email.labels = labelled
        r.type("fresh words"); r.key(.submit)
        r.w.clock += 5_000_000_000; r.settle()
        try check(r.words == ["fresh words"], "field hold (2): a draft sensitiveField discarded never comes back (\(r.words))")
    }
    // Review (08:44) 3: the scan is unchanged under the hold: page first, then frames. A page password behind an early
    // 40-node frame is still sensitiveField (the privacy hold, no field hold); frames that exhaust the budget with no
    // password are `field` after the scan returned (held).
    for password in [true, false] {
        let r = WebRig()
        let frame = FakeAXNode("frame-web", role: "AXWebArea", parent: r.w.web, owner: pid)
        for i in 0..<40 { _ = FakeAXNode("frame-row\(i)", role: "AXStaticText", parent: frame, owner: pid) }
        let pwBox = FakeAXNode("pw-box", role: "AXGroup", parent: r.w.web, owner: pid)
        for i in 0..<30 { _ = FakeAXNode("page-row\(i)", role: "AXStaticText", parent: r.w.web, owner: pid) }
        if password { _ = FakeAXNode("page-pw", role: "AXTextField", subrole: "AXSecureTextField", parent: pwBox, owner: pid) }
        r.type("ab")
        if password {
            try check(!r.burst.fieldHeld && r.burst.heldUntil != nil && !r.w.log.contains("ax:children:frame-web"),
                      "field hold (3): a page password behind an early frame: sensitiveField (privacy hold), the frame never opened, no field hold")
        } else {
            try check(r.burst.fieldHeld && r.w.log.contains("ax:children:frame-web"),
                      "field hold (3): frames that spend the budget (no password): field once the scan returned: held")
        }
    }
}

/// fix/app-coverage: the Chrome rows of the launch app matrix (APP-COVERAGE.md; the native rows are
/// Checks/AppCoverageChecks.swift): each launch site through the site rules with the default switches, and a Chrome text
/// box on each typed host through the website gate.
private func checkAppCoverageSites() throws {
    let choices = TypedCategoryChoices()
    var policy = CapturePolicy(); policy.typedText = true
    func proof(_ bundle: String, surface: AppSurface = .native, role: String = "AXTextArea") -> FocusProof {
        var p = webProof(bundle, url: "", role: role); p.surface = surface; return p
    }
    // Chrome: (address, typed with the default switches in build 7?).
    let rules = BrowserTypingSiteRules(choices: choices, expanded: true)
    let sites: [(url: String, typed: Bool, why: String)] = [
        ("https://mail.google.com/mail/u/0/", true, "Gmail"),
        ("https://docs.google.com/document/d/abc/edit", false, "Google Docs (canvas plus a hidden input frame)"),
        ("https://docs.google.com/spreadsheets/d/abc/edit", false, "Google Sheets (canvas)"),
        ("https://docs.google.com/presentation/d/abc/edit", false, "Google Slides (canvas)"),
        ("https://www.notion.so/Team-plan-abc", true, "Notion web"),
        ("https://x.com/home", true, "X"),
        ("https://www.linkedin.com/feed/", true, "LinkedIn"),
        ("https://www.reddit.com/r/swift/", true, "Reddit"),
        ("https://www.youtube.com/watch?v=abc", true, "YouTube comments and search"),
        ("https://app.slack.com/client/T1/C1", true, "Slack web"),
        ("https://discord.com/channels/1/2", true, "Discord web"),
        ("https://web.whatsapp.com/", true, "WhatsApp Web"),
        ("https://chatgpt.com/c/abc", true, "ChatGPT web"),
        ("https://claude.ai/new", true, "Claude web"),
        ("https://gemini.google.com/app", true, "Gemini"),
        ("https://www.perplexity.ai/", true, "Perplexity web"),
        ("https://github.com/acme/app/pull/418", true, "GitHub PR comments"),
        ("https://github.com/acme/app/issues/new", true, "GitHub issue boxes"),
        ("https://linear.app/acme/issue/ENG-12", true, "Linear"),
        ("https://www.figma.com/design/abc/Launch", true, "Figma comments"),
        ("https://www.google.com/search?q=boots", true, "Google search"),
        ("https://accounts.google.com/", false, "Google sign-in"),
        ("https://secure.chase.com/overview", false, "a bank"),
        ("https://1password.com/", false, "a password manager's site"),
    ]
    for s in sites {
        try check(rules.permits(url: s.url) == s.typed, "app coverage, Chrome: \(s.why) is \(s.typed ? "typed" : "never typed") with the default switches")
    }
    // Chrome's AX shape on each typed host: a text area (a contenteditable root), a text field, or an editable combo
    // box (search), through the website gate with the host rule the gate and the store read.
    for s in sites where s.typed {
        guard let origin = BrowserTypingSites.origin(s.url) else { throw MemError.invalid("no origin: " + s.url) }
        for role in ["AXTextArea", "AXTextField", "AXComboBox"] {
            var p = proof(WebTypingGate.bundle, surface: .browser, role: role)
            p.tabID = "7"; p.documentID = UUID().uuidString; p.frameID = "windows-1"; p.url = origin
            let d = WebTypingGate.typing(p, policy: policy, generation: 0, now: 1_000, expanded: true, site: { rules.permits(host: $0) })
            try check(d.outcome == .allowed, "app coverage, Chrome: a \(role) on \(s.why) passes the website gate (\(d.reason))")
        }
    }
    var docs = proof(WebTypingGate.bundle, surface: .browser)
    docs.tabID = "7"; docs.documentID = UUID().uuidString; docs.frameID = "windows-1"; docs.url = "https://docs.google.com"
    try check(WebTypingGate.typing(docs, policy: policy, generation: 0, now: 1_000, expanded: true, site: { rules.permits(host: $0) }).reason == .excludedSite,
              "app coverage, Chrome: Google Docs is refused at the website gate too")
}

/// claude/axjoin-1005 (owner decision 10/04: a late key cost the whole X reply on a busy laptop). A key whose allowed
/// join started more than `maxKeyLag` after it was typed is dropped unread (review I2), with the quiet period; the text
/// admitted before it is parked at the gap, saved only when the settle's fresh joins prove its field again, and dropped
/// by any refusal before that. Other drops still retract the unit.
private func checkWebLateKeyKeepsChecked() throws {
    func late(_ r: WebRig) -> BrowserTypingStep {
        let typed = r.w.clock; r.w.clock += BrowserTypingTiming.maxKeyLagNanoseconds + 50_000_000
        return r.burst.key(.insert(nil), join: r.result, light: r.lightResult, held: r.heldResult, typedAt: typed, now: { r.w.clock },
                           policy: r.policy, read: { r.reads += 1; return "#" }, write: r.write)
    }
    for light in [false, true] {
        // A late key mid-unit: the checked part saves as one row, the late key is dropped unread, the next keys are a new row.
        let r = WebRig(); r.useLight = light
        r.type("hello wor")
        let reads = r.reads
        let step = late(r)
        guard case .dropped = step else { throw MemError.invalid("FAILED: late key: dropped (\(step))") }
        try check(r.reads == reads && r.burst.dropReason == .late && !r.burst.session.hasLive && r.burst.session.parkedCount == 1,
                  "late key (light \(light)): dropped unread, the checked part parked at the gap")
        r.type("ld")
        try check(r.reads == reads, "late key (light \(light)): keys in its quiet period are dropped unread too")
        r.w.clock += 500_000_000; r.settle()
        r.type("next words"); r.key(.submit)
        try check(r.words == ["hello wor", "next words"] && !r.words.joined().contains("#"),
                  "late key (light \(light)): the checked part saves as one row, the next keys as a new one (\(r.words))")
    }
    // A late key, then an Incognito window: nothing after it is saved (the parked part neither).
    do {
        let r = WebRig()
        r.type("before the switch")
        _ = late(r)
        r.w.addWindow("666", mode: "incognito")
        r.w.clock += 500_000_000; r.settle()
        r.type("private words"); r.key(.submit)
        try check(r.rows.isEmpty && r.burst.session.parkedCount == 0 && !r.burst.session.hasLive,
                  "late key, then Incognito: nothing saved (\(r.words))")
    }
    // A late key in a unit whose end-of-unit check refuses: nothing is saved.
    let refusals: [(String, (WebRig) -> Void)] = [
        ("the field turns sensitive", { $0.w.field.labels = BrowserTypingFieldLabels(texts: ["Card number"], identifiers: []) }),
        ("a password field", { $0.w.field.subrole = "AXSecureTextField" }),
        ("a blocked site", { $0.sites.alwaysBlocked.append("example.org") }),
        ("another page", { $0.page("https://other.example.net/x") }),
        ("the window list changed", { $0.w.addWindow("404", mode: "normal", front: false) }),
        ("secure input", { $0.w.secure = true }),
    ]
    for (what, change) in refusals {
        let r = WebRig()
        r.type("draft words")
        _ = late(r)
        change(r)
        r.w.clock += 500_000_000; r.settle(secure: what == "secure input")
        try check(r.rows.isEmpty, "late key, then \(what) before the settle: nothing saved (\(r.words))")
    }
    // Every other drop still retracts the unit: a key admitted by another burst's proof (focus moved to another
    // field with no click or key the route saw; a parked unit would be saved there, G12).
    do {
        let r = WebRig()
        r.type("abc")
        let other = FakeAXNode("other-field", role: "AXTextField", parent: r.w.group, owner: FakeChromeWorld.chromePID)
        other.labels = BrowserTypingFieldLabels(texts: ["Title"], identifiers: [])
        r.w.axFocus = other
        r.type("d")
        try check(r.burst.dropReason == .otherBurst || r.burst.dropReason == nil, "another burst's key: dropped as another burst")
        r.w.clock += 500_000_000; r.settle()
        try check(!r.words.contains("abc"), "another burst's key: the unit is retracted, as before (\(r.words))")
    }
}
#endif
