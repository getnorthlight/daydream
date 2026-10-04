import Foundation
import MemoryCore
import PrivacyPolicy

/// email-1003 (owner decision 2026-10-03): DayDream records what happens in email, not just the site name. Webmail page
/// rows keep a cleaned title (folder or subject) while "Save email subjects" is on (default on); Mail's window titles
/// are cleaned the same way; code, password, sign-in, security, verification and bank subjects are never kept; search
/// and chat sites stay site-only. Synthetic data only: every name, address and subject below is made up.
func runEmailChecks(home:URL,now:Date) throws {
    // 1. Webmail title formats (Gmail, Outlook, others).
    let gmail="mail.google.com", outlook="outlook.office.com", live="outlook.live.com"
    let web:[(String,String,String?)]=[
        ("Inbox - riley@example.test - Gmail",gmail,"Inbox"),
        ("Inbox (3) - riley@example.test - Gmail",gmail,"Inbox"),
        ("Inbox (1,204) - riley@example.test - Gmail",gmail,"Inbox"),
        ("(3) Inbox - riley@example.test - Gmail",gmail,"Inbox"),
        ("Sent Mail - riley@example.test - Gmail",gmail,"Sent"),
        ("Drafts (2) - riley@example.test - Gmail",gmail,"Drafts"),
        ("Starred - riley@example.test - Gmail",gmail,"Starred"),
        ("Demo feedback - riley@example.test - Gmail",gmail,"Demo feedback"),
        ("Re: Demo feedback - riley@example.test - Gmail",gmail,"Re: Demo feedback"),
        ("RE: RE: Demo feedback - riley@example.test - Gmail",gmail,"Re: Demo feedback"),
        ("Fw: Offsite agenda - riley@example.test - Gmail",gmail,"Fwd: Offsite agenda"),
        ("Q3 - plan review - riley@example.test - Gmail",gmail,"Q3 - plan review"),
        ("Inbox (5) - riley@example.test - Example Co Mail",gmail,"Inbox"),
        ("Mail - Riley Park - Outlook",outlook,"Mail"),
        ("Inbox - Riley Park - Outlook",outlook,"Inbox"),
        ("Inbox (4) - riley@example.test - Outlook",outlook,"Inbox"),
        ("Sent Items - Riley Park - Outlook",outlook,"Sent"),
        ("Deleted Items - Riley Park - Outlook",outlook,"Trash"),
        ("Re: Demo feedback – Outlook",outlook,"Re: Demo feedback"),
        ("Re: Demo feedback - Riley Park - Outlook",live,"Re: Demo feedback"),
        ("Startup credits question - Riley Park - Outlook",live,"Startup credits question"),
        ("Gmail",gmail,nil),
        ("Outlook",outlook,nil),
        ("riley@example.test - Gmail",gmail,nil),
        ("Loading…",gmail,nil),
    ]
    for (raw,host,want) in web {
        let got=EmailTitle.web(raw,host:host)
        try check(got == want,"email titles: \(host) \"\(raw)\" -> \(want ?? "site only") (got \(got ?? "nil"))")
    }
    // 2. Mail.app window titles.
    let mail:[(String,String?)]=[
        ("Inbox — 1,234 messages, 5 unread","Inbox"),
        ("Inbox – iCloud — 12 messages","Inbox"),
        ("Inbox (3 messages, 1 unread)","Inbox"),
        ("All Inboxes — 40 messages, 2 unread","Inbox"),
        ("Sent — 1 message","Sent"),
        ("Re: Demo feedback","Re: Demo feedback"),
        ("Startup credits question","Startup credits question"),
        ("New Message","New message"),
        ("Your code is 482913",nil),
    ]
    for (raw,want) in mail {
        let got=EmailTitle.mailApp(raw)
        try check(got == want,"email titles: Mail \"\(raw)\" -> \(want ?? "nothing") (got \(got ?? "nil"))")
    }
    // 3. The subject rules (the typed-words scrubber, extended for subjects).
    let sensitive:[(String,TypedSecretScrubber.SubjectReason)]=[
        ("Your code is 123456",.oneTimeCode), ("482913 is your Example verification code",.oneTimeCode),
        ("Your Example sign-in code",.oneTimeCode), ("Example: 739104",.oneTimeCode), ("Your one-time passcode",.oneTimeCode),
        ("Reset your password",.password), ("Password changed",.password), ("Your password was reset",.password),
        ("Sign-in attempt",.signIn), ("New sign-in from Chrome on Mac",.signIn), ("Unusual login attempt",.signIn),
        ("Security alert",.security), ("Suspicious activity on your account",.security),
        ("Verify your email address",.verification), ("Confirm your account",.verification),
        ("Your statement is ready",.bank), ("Purchase alert: card ending 4421",.bank), ("Direct deposit received",.bank),
        ("Magic link for Example",.oneTimeCode), ("Two-factor authentication enabled",.oneTimeCode),
    ]
    for (subject,reason) in sensitive {
        let got=TypedSecretScrubber.sensitiveSubject(subject)
        try check(got != nil,"email subjects: never kept: \"\(subject)\" (\(reason.rawValue), got \(got?.rawValue ?? "kept"))")
        try check(EmailTitle.web(subject+" - riley@example.test - Gmail",host:gmail) == nil,"email subjects: a webmail page keeps its site only: \"\(subject)\"")
    }
    for subject in ["Demo feedback","Re: Demo feedback","Startup credits question","Q3 2026 plan","Lunch Friday?","Offsite agenda","Pricing for the team plan","Design review notes"] {
        try check(TypedSecretScrubber.sensitiveSubject(subject) == nil,"email subjects: kept: \"\(subject)\"")
    }

    // 4. Capture: the Chrome page probe, with a scripted fake (no Apple Event).
    func probe(_ url:String,_ title:String,subjects:Bool,blocked:[String]=[],mode:String="normal") -> (ChromePageResult,Bool) {
        var askedTitle=false
        let r=ChromePageProbe.read(userBlocked:blocked,emailSubjects:subjects) { req in
            switch req {
            case .windowIDs: return .ids(["w1"])
            case .mode: return .text(mode)
            case .activeTabID: return .text("t1")
            case .tabURL: return .text(url)
            case .tabTitle: askedTitle=true; return .text(title)
            }
        }
        return (r,askedTitle)
    }
    func kept(_ r:ChromePageResult) -> String? { if case .page(let p)=r, p.siteOnly, p.link == nil { return p.title }; return nil }
    let inbox="https://mail.google.com/mail/u/0/#inbox", thread="https://mail.google.com/mail/u/0/#inbox/FMfcgzQfake"
    try check(kept(probe(inbox,"Inbox (3) - riley@example.test - Gmail",subjects:true).0) == "Inbox","email capture: Gmail inbox keeps \"Inbox\", no link, no path")
    try check(kept(probe(thread,"Re: Demo feedback - riley@example.test - Gmail",subjects:true).0) == "Re: Demo feedback","email capture: an opened Gmail email keeps its subject")
    try check(kept(probe("https://outlook.office.com/mail/inbox/id/AAQfake","Re: Demo feedback - Riley Park - Outlook",subjects:true).0) == "Re: Demo feedback",
              "email capture: an opened Outlook email keeps its subject")
    let off=probe(thread,"Re: Demo feedback - riley@example.test - Gmail",subjects:false)
    try check(kept(off.0) == "" && !off.1,"email capture: Save email subjects off keeps the site only and never asks for the title")
    try check(kept(probe(thread,"Your code is 123456 - riley@example.test - Gmail",subjects:true).0) == "","email capture: a code subject keeps the site only")
    try check(kept(probe("https://mail.google.com/chat/u/0/#chat/dm/fake","Riley Park - Chat",subjects:true).0) == "","email capture: Gmail's chat stays a chat site (site only)")
    try check(kept(probe("https://outlook.office.com/calendar/view/week","Calendar - Riley Park - Outlook",subjects:true).0) == "","email capture: Outlook's calendar is not mail (site only)")
    try check(kept(probe("https://www.icloud.com/notes/","iCloud Notes",subjects:true).0) == "","email capture: iCloud outside /mail is not mail (site only)")
    for (url,title) in [("https://www.google.com/search?q=weather","weather - Google Search"),("https://chatgpt.com/c/fake","Trip planning"),
                        ("https://app.slack.com/client/T1/C2","#eng (Channel) - Example - Slack"),("https://www.bing.com/search?q=x","x - Search")] {
        let (r,asked)=probe(url,title,subjects:true)
        try check(kept(r) == "" && !asked,"email capture: search and chat sites are unchanged (site only, title never asked): "+url)
    }
    try check(probe(thread,"Re: Demo feedback - riley@example.test - Gmail",subjects:true,mode:"incognito").0 == .skipped(.notNormal),
              "email capture: an Incognito window saves nothing")
    try check(probe(thread,"Re: Demo feedback - riley@example.test - Gmail",subjects:true,blocked:["mail.google.com"]).0 == .skipped(.blocked),
              "email capture: a site the owner blocked saves nothing")
    try check(probe(thread,"Private - Re: Demo feedback",subjects:true).0 == .skipped(.blocked),"email capture: a private-looking title is skipped")

    // 5. Read time (BrowserSafety) and the store.
    let chrome=BrowserSafety.supportedBundle
    func page(_ id:String,_ title:String,_ url:String="https://mail.google.com") -> Evidence {
        var proof=BrowserVerification(mode:"normal",windowID:"1520",tabID:"1733",focusedRole:"",checkedAt:isoPrecise(now),provider:BrowserSafety.pageProvider)
        proof.policyRevision="policy-fixture"
        return Evidence(id:id,at:isoPrecise(now),kind:"window.changed",app:"Google Chrome",bundle:chrome,title:title,url:url,browserVerification:proof)
    }
    try check(BrowserSafety.valid(page("v1","Re: Demo feedback")),"email read: an email page row with a kept subject is valid")
    try check(BrowserSafety.valid(page("v2","Inbox","https://outlook.office.com")),"email read: an Outlook folder is valid")
    try check(!BrowserSafety.valid(page("v3","Inbox - riley@example.test")),"email read: a raw title with an account address is refused")
    try check(!BrowserSafety.valid(page("v4","Reset your password")),"email read: a password subject is refused")
    try check(!BrowserSafety.valid(page("v5","Trip planning","https://chatgpt.com")),"email read: a chat site with a title is still refused")
    try check(!BrowserSafety.valid(page("v6","weather - Google Search","https://www.google.com")),"email read: a search site with a title is still refused")

    let store=try MemoryStore(home:home,writable:true), session=try CaptureSession(store:store)
    var policy=try store.policy()
    try check(policy.emailSubjects,"email setting: Save email subjects is on by default")
    let encoded=String(decoding:try JSONEncoder().encode(policy),as:UTF8.self)
    try check(!encoded.contains("emailSubjects"),"email setting: on is not written (a policy saved before the setting reads as on)")
    var offPolicy=policy; offPolicy.emailSubjects=false
    let offData=try JSONEncoder().encode(offPolicy)
    try check(String(decoding:offData,as:UTF8.self).contains("\"emailSubjects\":false") && !(try JSONDecoder().decode(PrivacySettings.self,from:offData)).emailSubjects,
              "email setting: off is written and read back")
    try session.start(permitted:true,now:now)
    policy.browserPages=true; policy.browserPagesConsentVersion=PrivacySettings.browserPagesConsentCurrent
    try store.updatePolicy(policy,now:now)
    try check(try session.record(page("mail-thread","Re: Demo feedback"),focusedFieldKnown:true,permitted:true,now:now),"email store: an email page row with its subject is saved")
    let row=try store.read("mail-thread",now:now)
    try check(row?.evidence.title == "Re: Demo feedback" && row?.evidence.url == "https://mail.google.com" && row?.evidence.page == nil,
              "email store: the row holds the site and the subject only (no path, no link)")
    let action=try store.action("mail-thread",now:now)
    try check(action?.title == "Re: Demo feedback","email summaries: the writer's action carries the subject")
    if let action {
        try check(NoteAudience.cloudView(action).title == "Demo feedback","email summaries: a cloud writer gets the subject, cleaned")
    }
    try check(try !session.record(page("mail-chat","Trip planning","https://chatgpt.com"),focusedFieldKnown:true,permitted:true,now:now),
              "email store: a chat page with a title is still refused")
    // Setting off: read time keeps the site only, whenever the row was saved.
    policy=try store.policy(); policy.emailSubjects=false
    try store.updatePolicy(policy,now:now)
    try check(try store.read("mail-thread",now:now)?.evidence.title == "","email setting: off shows an email page row with its site only")
    try check(try session.record(page("mail-off","Re: Lunch Friday"),focusedFieldKnown:true,permitted:true,now:now)
              && store.read("mail-off",now:now)?.evidence.title == "","email setting: off saves new email page rows with their site only")
    policy=try store.policy(); policy.emailSubjects=true
    try store.updatePolicy(policy,now:now)
    try check(try store.read("mail-thread",now:now)?.evidence.title == "Re: Demo feedback","email setting: back on shows the subject again")
    // Retention still applies (the read gate every reader uses).
    var short=try store.policy(); short.retention = .days(1)
    try check(Privacy.sanitized(page("kept","Re: Demo feedback"),settings:short,now:now) != nil
              && Privacy.sanitized(page("old","Re: Demo feedback"),settings:short,now:now.addingTimeInterval(3*86_400)) == nil,
              "email retention: an email page row expires like any row")

    // Mail.app windows: cleaned at ingest, sensitive subjects never kept.
    func mailWindow(_ id:String,_ title:String) -> Evidence {
        Evidence(id:id,at:isoPrecise(now),kind:"window.changed",app:"Mail",bundle:"com.apple.mail",title:title,synthetic:true)
    }
    try store.ingest(mailWindow("mail-inbox","Inbox — 1,234 messages, 5 unread"),now:now)
    try check(try store.read("mail-inbox",now:now)?.evidence.title == "Inbox","Mail: the viewer window is saved as its folder")
    try store.ingest(mailWindow("mail-open","Re: Demo feedback"),now:now)
    try check(try store.read("mail-open",now:now)?.evidence.title == "Re: Demo feedback","Mail: an opened email keeps its subject")
    try store.ingest(mailWindow("mail-otp","Your code is 482913"),now:now)
    try check(try store.read("mail-otp",now:now)?.evidence.title == TypedHistoryScrub.omittedTitle,"Mail: a code subject is never kept")
    try store.ingest(mailWindow("mail-reset","Reset your password"),now:now)
    try check(try store.read("mail-reset",now:now)?.evidence.title == TypedHistoryScrub.omittedTitle,"Mail: a password subject is never kept")
    var blockedMail=try store.policy(); blockedMail.blockedApps=["com.apple.mail"]
    try store.updatePolicy(blockedMail,now:now)
    try check(try !store.ingest(mailWindow("mail-excluded","Re: Demo feedback"),now:now) && store.read("mail-open",now:now) == nil,
              "Mail: an excluded Mail saves nothing and hides what it saved")
    blockedMail=try store.policy(); blockedMail.blockedApps=[]
    try store.updatePolicy(blockedMail,now:now)

    // 6. Save email subjects: the preference save (recording stopped first, as the app does).
    try session.stop(now:now)
    let before=try store.policy()
    let saved=try store.savePreferences(MemoryPreferences(blockedApps:before.blockedApps,nativeTyping:before.typingOn,emailSubjects:false),expectedRevision:before.revision)
    try check(saved.changed && !saved.policy.emailSubjects && saved.policy.revision != before.revision,"email setting: turning it off saves a new policy")
    let again=try store.savePreferences(MemoryPreferences(blockedApps:saved.policy.blockedApps,nativeTyping:saved.policy.typingOn,emailSubjects:true),expectedRevision:saved.policy.revision)
    try check(again.changed && again.policy.emailSubjects,"email setting: turning it back on saves (and shares more, so AI apps reconnect)")
    let same=try store.savePreferences(MemoryPreferences(blockedApps:again.policy.blockedApps,nativeTyping:again.policy.typingOn),expectedRevision:again.policy.revision)
    try check(!same.changed && same.policy.emailSubjects,"email setting: a save that doesn't name it keeps it")

    // 7. Compose and send (the email adapter, email-compose/v1).
    let to=EmailComposeField(role:"AXTextField",labels:["To"],tokens:["Sam Lee <sam@example.test>"])
    let subject=EmailComposeField(role:"AXTextField",labels:["Subject"],value:"Startup credits question")
    let body=EmailComposeField(role:"AXWebArea",labels:["Message Body"],value:"never read")
    let newFacts=EmailComposeAdapter.facts(EmailComposeSnapshot(title:"New Message",fields:[to,subject,body]))
    try check(newFacts == EmailComposeFacts(recipients:["Sam Lee"],subject:"Startup credits question",kind:.new),"compose: To display names and the Subject, never the body")
    try check(EmailComposeAdapter.recipientName("sam@example.test") == "sam@example.test" && EmailComposeAdapter.recipientName("\"Lee, Sam\" <sam@example.test>") == "Lee, Sam",
              "compose: an address only when no name is shown")
    let reply=EmailComposeAdapter.facts(EmailComposeSnapshot(title:"Re: Demo feedback",fields:[EmailComposeField(role:"AXTextField",labels:["To"],tokens:["Sam"])]))
    try check(reply.kind == .reply && reply.replyTo == "Sam" && reply.subject == "Re: Demo feedback","compose: a reply (Mail's compose window titled with its subject)")
    let fwd=EmailComposeAdapter.facts(EmailComposeSnapshot(title:"",fields:[EmailComposeField(role:"AXTextField",labels:["To"],tokens:["Dana Reyes"]),
                                                                          EmailComposeField(role:"AXTextField",labels:["Subject"],value:"Fwd: Offsite agenda")]))
    try check(fwd.kind == .forward && fwd.recipients == ["Dana Reyes"],"compose: a forward")
    let gmailReply=EmailComposeAdapter.facts(EmailComposeSnapshot(title:"Demo feedback",fields:[EmailComposeField(role:"AXTextField",labels:["To recipients"],tokens:["Sam Lee, press delete to remove"])],regionLabels:["Reply"]))
    try check(gmailReply.kind == .reply && gmailReply.replyTo == "Sam Lee","compose: Gmail's inline reply (region label, token hint dropped)")
    try check(EmailComposeAdapter.isSendButton(role:"AXButton",labels:["Send ‪(⌘Enter)‬"]) && EmailComposeAdapter.isSendButton(role:"AXButton",labels:["Send"])
              && !EmailComposeAdapter.isSendButton(role:"AXButton",labels:["Send later"]) && !EmailComposeAdapter.isSendButton(role:"AXStaticText",labels:["Send"]),
              "compose: the Send button by role and label")
    let open=[(seconds:0.15,open:true),(seconds:0.4,open:true),(seconds:0.9,open:true),(seconds:2.0,open:true)]
    let closes=[(seconds:0.15,open:true),(seconds:0.4,open:false)]
    try check(EmailComposeAdapter.decide(gesture:.button,mailApp:false,stillOpenAt:closes) == ("detected","button"),"send: Send clicked, then the compose closed")
    try check(EmailComposeAdapter.decide(gesture:.commandReturn,mailApp:false,stillOpenAt:closes) == ("detected","commandReturn"),"send: Command-Return in webmail, then closed")
    try check(EmailComposeAdapter.decide(gesture:.mailSend,mailApp:true,stillOpenAt:closes) == ("detected","mailSend"),"send: Mail's Command-Shift-D, then closed")
    try check(EmailComposeAdapter.decide(gesture:.button,mailApp:true,stillOpenAt:closes) == ("detected","button"),"send: Mail's Send button, then closed")
    try check(EmailComposeAdapter.decide(gesture:.button,mailApp:false,stillOpenAt:open) == ("unknown",nil),"send: a click that leaves the compose open (no recipient) is a draft")
    try check(EmailComposeAdapter.decide(gesture:nil,mailApp:false,stillOpenAt:closes) == ("unknown",nil),"send: a discarded draft (closed with no Send) is never a send")
    try check(EmailComposeAdapter.decide(gesture:.commandReturn,mailApp:true,stillOpenAt:closes) == ("unknown",nil),"send: Command-Return in Mail is nothing")
    try check(EmailComposeAdapter.send(gesture:.button,closedAfter:3.5,mailApp:false) == ("unknown",nil),"send: a close after the window is not a send")
    // claude/int-1003: email-compose/v1 wired into compose-send/v1 (`markComposerSent`, `nativeIdentity`, the Chrome route).
    let replyID=EmailComposeAdapter.identity(reply,service:"Mail")
    try check(replyID.0 == ComposeDestination(name:"Sam",subject:"Demo feedback",service:"Mail") && replyID.1 == ComposeContext(author:"Sam",excerpt:"Demo feedback"),
              "wiring: a reply goes to the person it answers, the bare subject, and answers that subject")
    let titleOnly=EmailComposeAdapter.identity(EmailComposeAdapter.facts(EmailComposeSnapshot(title:"New Message",fields:[])),recipient:"Riley",service:"Mail")
    try check(titleOnly.0 == ComposeDestination(name:"Riley",service:"Mail") && titleOnly.1.isEmpty,"wiring: Mail's New Message window: the To-field rule's name, no subject, no context")
    let fwdID=EmailComposeAdapter.identity(fwd,recipient:"Someone else",service:"Gmail")
    try check(fwdID.0.name == "Dana Reyes" && fwdID.0.subject == "Offsite agenda" && fwdID.1.isEmpty,"wiring: a forward names its To recipient over the rule's name, answers nothing")
    try check(EmailComposeAdapter.gesture(.returnKey) == nil && EmailComposeAdapter.gesture(.commandReturn) == .commandReturn
              && EmailComposeAdapter.gesture(.mailSend) == .mailSend && EmailComposeAdapter.gesture(.button) == .button,"wiring: Return is never an email gesture")
    try check(EmailComposeAdapter.confirmation(gesture:.commandReturn,mailApp:false,closedAfter:0.4) == .composerClosed
              && EmailComposeAdapter.confirmation(gesture:.commandReturn,mailApp:false,closedAfter:nil) == nil
              && EmailComposeAdapter.confirmation(gesture:.commandReturn,mailApp:false,closedAfter:2.5) == nil
              && EmailComposeAdapter.confirmation(gesture:.commandReturn,mailApp:true,closedAfter:0.4) == nil
              && EmailComposeAdapter.confirmation(gesture:.returnKey,mailApp:false,closedAfter:0.4) == nil,
              "wiring: only a compose closed within the window after a real email gesture confirms a send")
    try check(SendRules.facts(bundle:"com.google.Chrome",host:"mail.google.com",field:"body",seal:.submitChord).send == "unknown"
              && SendRules.facts(bundle:"com.google.Chrome",host:"outlook.live.com",field:"body",seal:.submitChord).send == "unknown",
              "wiring: webmail Command-Return is a draft until the compose closes (email-1003's recommendation)")
    try check(SendRules.facts(bundle:"com.apple.mail",title:"Re: Plans",field:"body",seal:.mailSend).send == "detected",
              "wiring: Mail's Command-Shift-D stays a send at the seal (Mail's own Send command)")

    // 8. Lines for cards and summaries.
    try check(EmailLines.read(subject:"Demo feedback",from:"Sam") == "Read 'Demo feedback' from Sam" && EmailLines.read(subject:"Demo feedback") == "Read 'Demo feedback'",
              "lines: Read 'Demo feedback' from Sam")
    try check(EmailLines.sent(title:"New Message",to:"Sam",facts:newFacts) == "Emailed Sam Lee — 'Startup credits question'","lines: Emailed Sam — 'Startup credits question'")
    try check(EmailLines.sent(title:"Re: Demo feedback",to:nil,facts:reply) == "Replied to Sam's email 'Demo feedback'","lines: Replied to Sam's email 'Demo feedback'")
    try check(EmailLines.sent(title:"",to:nil,facts:fwd) == "Forwarded 'Offsite agenda' to Dana Reyes","lines: Forwarded 'Offsite agenda' to Dana Reyes")
    try check(EmailLines.sent(title:"Reset your password",to:"Sam") == "Emailed Sam","lines: a sensitive subject is never named")
    func typed(_ title:String) throws -> CanonicalAction {
        try JSONDecoder().decode(CanonicalAction.self,from:Data(#"{"id":"m1","evidenceIDs":[],"at":"2026-10-03T16:10:00Z","kind":"keyboard.text_input","app":"Mail","bundle":"com.apple.mail","site":"","title":"\#(title)","description":"","state":"observed","revision":"r","subject":"","observationKey":"k"}"#.utf8))
    }
    try check(MemoryStore.sendLine(try typed("Startup credits question"),surface:"email",to:"Sam",label:"Email to Sam") == "Emailed Sam — 'Startup credits question'",
              "cards: a Mail send says who and the subject")
    try check(MemoryStore.sendLine(try typed("Re: Demo feedback"),surface:"email",to:"Sam",label:"Email to Sam") == "Replied to Sam's email 'Demo feedback'",
              "cards: a Mail reply says whose email it answered")
    try check(MemoryStore.sendLine(try typed("Re: Demo feedback"),surface:"email",to:nil,label:"Email") == "Replied to 'Demo feedback'",
              "cards: a reply with no recipient read still names the email")
    try check(MemoryStore.sendLine(try typed("New Message"),surface:"email",to:"Sam",label:"Email to Sam") == "Emailed Sam",
              "cards: a compose window with no subject yet says who only")
}
