import Foundation
import PrivacyPolicy

/// summaries/v3 (intent lines spec §3, §4; checks K4 and K5): the key map's send chords, and the SendRules decision
/// table over surface x field x seal. Synthetic metadata only; no typed words except the To-field name rule's fixtures.
enum SendRulesChecks {
    static var passed=0
    static func pass(_ ok:Bool,_ label:String) {if !ok {fatalError("Send rules check failed: "+label)};passed+=1}

    static func run() {
        keyMap();table();surfaces();verifiedSearchContexts();places();memories();messages1003()
        print("PASS summaries/v3 send rules: \(passed) synthetic cases (K4 table, K5 key map, places, recipient and paste memory).")
    }

    /// K5: Command-Return -> submitChord, Control-Return -> submitChord, Command-Shift-D -> mailSend,
    /// Command-D -> shortcut, Shift/Option-Return -> a new line, plain Return -> submit.
    static func keyMap() {
        func intent(_ k:KeyStroke)->KeyIntent {var m=TypingKeyMap();return m.intent(k,pressAndHold:false)}
        pass(intent(KeyStroke(keyCode:36,command:true)) == .leave(.submitChord,marker:true),"K5: Command-Return is submitChord")
        pass(intent(KeyStroke(keyCode:76,command:true)) == .leave(.submitChord,marker:true),"K5: Command-Enter (keypad) is submitChord")
        pass(intent(KeyStroke(keyCode:36,control:true)) == .leave(.submitChord,marker:true),"K5: Control-Return is submitChord")
        pass(intent(KeyStroke(keyCode:36,command:true,control:true)) == .leave(.shortcut,marker:true),"K5: Command-Control-Return stays a shortcut")
        pass(intent(KeyStroke(keyCode:2,command:true,shift:true)) == .leave(.mailSend,marker:true),"K5: Command-Shift-D is mailSend")
        pass(intent(KeyStroke(keyCode:2,command:true)) == .leave(.shortcut,marker:true),"K5: Command-D alone stays a shortcut")
        pass(intent(KeyStroke(keyCode:2,command:true,option:true,shift:true)) == .leave(.shortcut,marker:true),"K5: Command-Option-Shift-D is a shortcut")
        pass(intent(KeyStroke(keyCode:2,control:true)) == .edit(.deleteForward(.character)),"K5: Control-D still deletes forward")
        pass(intent(KeyStroke(keyCode:36,shift:true)) == .insertText("\n") && intent(KeyStroke(keyCode:36,option:true)) == .insertText("\n"),"K5: Shift- and Option-Return are new lines")
        pass(intent(KeyStroke(keyCode:36)) == .submit,"K5: plain Return is submit")
        pass(SealReason.submitChord.mayChangeApp && SealReason.mailSend.mayChangeApp && SealReason.shortcut.mayChangeApp && !SealReason.submit.mayChangeApp && !SealReason.submitChord.endsValue && !SealReason.mailSend.endsValue,
             "the send chords behave like shortcut for focus and value ends")
        pass(SealReason(rawValue:"submitChord") == .submitChord && SealReason(rawValue:"mailSend") == .mailSend,"stored seal reasons round-trip")
    }

    /// K4: the §3 table. Only a send key on a surface that sends is `detected`.
    static func table() {
        let notSends:[SealReason]=[.idle,.size,.cursor,.paste,.pointer,.focusKey,.shortcut,.focus,.window,.app,.inputSource,.gap,.suspend,.sensitive]
        let cases:[(bundle:String,host:String?,title:String,field:String,surface:String,sends:[SealReason:String])]=[
            ("com.anthropic.claudefordesktop",nil,"Claude","textArea","ai",[.submit:"return"]),
            ("com.openai.codex",nil,"ChatGPT","textArea","ai",[.submit:"return"]),
            ("com.openai.chat",nil,"ChatGPT","textArea","ai",[.submit:"return"]),
            ("com.google.Chrome","claude.ai","claude.ai","textArea","ai",[.submit:"return"]),
            ("com.google.Chrome","chatgpt.com","chatgpt.com","textArea","ai",[.submit:"return"]),
            ("com.apple.Terminal",nil,"✳ Claude Code — tallybird","textArea","aiTool",[.submit:"return"]),
            ("com.mitchellh.ghostty",nil,"codex — ~/tallybird","textArea","aiTool",[.submit:"return"]),
            // Owner decision 2026-10-02 (RECORDING-MATRIX-1002 rows 1-2): Return in a terminal runs the command.
            ("com.apple.Terminal",nil,"sam@mini — zsh","textArea","code",[.submit:"return"]),
            ("com.mitchellh.ghostty",nil,"~/tallybird","textArea","code",[.submit:"return"]),
            // messages-1003: Return in Messages is never a send by itself (`messagesClearedSend` after the composer empties).
            ("com.apple.MobileSMS",nil,"Mom","textArea","text",[:]),
            ("com.google.Chrome","app.slack.com","app.slack.com","message","chat",[.submit:"return"]),
            ("com.google.Chrome","discord.com","discord.com","message","chat",[.submit:"return"]),
            ("com.google.Chrome","web.whatsapp.com","web.whatsapp.com","message","chat",[.submit:"return"]),
            ("com.google.Chrome","www.snapchat.com","www.snapchat.com","textArea","chat",[.submit:"return"]),
            ("com.apple.mail",nil,"Re: Friday meeting","body","email",[.mailSend:"mailSend"]),
            ("com.apple.mail",nil,"New Message","to","email",[.mailSend:"mailSend"]),
            // claude/int-1003: webmail Command-Return is a draft until the compose closes (`EmailComposeAdapter`).
            ("com.google.Chrome","mail.google.com","mail.google.com","body","email",[:]),
            ("com.google.Chrome","outlook.live.com","outlook.live.com","body","email",[:]),
            ("com.google.Chrome","www.icloud.com","www.icloud.com","body","email",[:]),
            ("com.google.Chrome","www.linkedin.com","www.linkedin.com","message","social",[.submitChord:"commandReturn"]),
            ("com.google.Chrome","x.com","Home / X","textArea","social",[.submitChord:"commandReturn"]),
            ("com.google.Chrome","twitter.com","twitter.com","textArea","social",[.submitChord:"commandReturn"]),
            ("com.google.Chrome","www.threads.net","www.threads.net","textArea","social",[.submitChord:"commandReturn"]),
            ("com.google.Chrome","bsky.app","bsky.app","textArea","social",[.submitChord:"commandReturn"]),
            ("com.google.Chrome","www.reddit.com","www.reddit.com","textArea","social",[.submitChord:"commandReturn"]),
            ("com.google.Chrome","www.google.com","www.google.com","search","search",[.submit:"return"]),
            ("com.apple.Spotlight",nil,"","search","search",[.submit:"return"]),
            ("com.google.Chrome","example.com","example.com","oneLine","form",[:]),
            ("com.google.Chrome","example.com","example.com","search","search",[.submit:"return"]),
            ("com.google.Chrome","example.com","example.com","textArea","other",[:]),
            ("com.apple.dt.Xcode",nil,"ExportView.swift — tallybird","textArea","code",[:]),
            ("com.apple.Notes",nil,"Groceries — Notes","textArea","writing",[:]),
            ("com.apple.TextEdit",nil,"Untitled","textArea","writing",[:]),
        ]
        for c in cases {
            let all:[SealReason]=[.submit,.submitChord,.mailSend]+notSends
            for seal in all {
                let f=SendRules.facts(bundle:c.bundle,host:c.host,title:c.title,field:c.field,seal:seal)
                pass(f.surface == c.surface,"K4: \(c.bundle) \(c.host ?? "") is \(c.surface), got \(f.surface)")
                if let by=c.sends[seal] {
                    pass(f.send == "detected" && f.sendBy == by,"K4: \(c.surface) \(seal) is a detected send by \(by)")
                } else {
                    let expected=["code","writing"].contains(c.surface) ? "none" : "unknown"
                    pass(f.send == expected && f.sendBy == nil,"K4: \(c.surface) \(c.field) \(seal) is \(expected), got \(f.send)")
                }
            }
        }
        // Return in Mail (body or To: a new line or a contact pick) is never a send; neither is Command-Return in Mail.
        for field in ["body","to","subject"] {
            pass(SendRules.facts(bundle:"com.apple.mail",title:"New Message",field:field,seal:.submit).send == "unknown","K4: Return in Mail's \(field) is never a send")
            pass(SendRules.facts(bundle:"com.apple.mail",title:"New Message",field:field,seal:.submitChord).send == "unknown","K4: Command-Return in Mail's \(field) is never a send")
        }
        // Return in Gmail's body is a new line, not a send; Command-Shift-D on the web is not Mail's send.
        pass(SendRules.facts(bundle:"com.google.Chrome",host:"mail.google.com",field:"body",seal:.submit).send == "unknown","K4: Return in Gmail is never a send")
        pass(SendRules.facts(bundle:"com.google.Chrome",host:"mail.google.com",field:"body",seal:.mailSend).send == "unknown","K4: Command-Shift-D on the web is not a send")
        // Slack web: Return in a search or To box is not a message send.
        let slackSearch=SendRules.facts(bundle:"com.google.Chrome",host:"app.slack.com",field:"search",seal:.submit)
        pass(slackSearch.surface == "search" && slackSearch.send == "detected" && slackSearch.sendBy == "return","K4: Return in a verified chat-site search box is a search gesture, never a message")
        // Social sites: Command-Return in a search box is not a post; Return in a post box is a new line.
        pass(SendRules.facts(bundle:"com.google.Chrome",host:"x.com",field:"search",seal:.submitChord).send == "unknown","K4: Command-Return in a social site's search box is not a post")
        pass(SendRules.facts(bundle:"com.google.Chrome",host:"x.com",field:"textArea",seal:.submit).send == "unknown","K4: Return in a social post box is not a send")
        // idle and pointer seals are never detected, anywhere.
        for (bundle,host) in [("com.apple.MobileSMS",nil),("com.anthropic.claudefordesktop",nil),("com.google.Chrome","mail.google.com"),("com.google.Chrome","app.slack.com")] as [(String,String?)] {
            for seal in [SealReason.idle,.pointer,.size,.focusKey] {
                pass(SendRules.facts(bundle:bundle,host:host,field:"message",seal:seal).send != "detected","K4: \(seal) in \(bundle) \(host ?? "") is never a send")
            }
        }
        // fix/chrome-capture: a pointer seal on X stays unknown (the click alone proves nothing); a proven composer
        // control activation is decided by buttonSend, only for a social site's message box.
        let xClick=SendRules.facts(bundle:"com.google.Chrome",host:"x.com",field:"textArea",seal:.pointer)
        pass(xClick.send == "unknown" && xClick.sendBy == nil,"fix/chrome-capture: a click on X (any click) seals a draft: send unknown, no sendBy")
        for field in ["textArea","message","oneLine","unknown","body"] {
            let b=SendRules.buttonSend(surface:"social",field:field)
            pass(b.send == "detected" && b.sendBy == "button","fix/chrome-capture: a proven Post button after a social \(field) box is a detected send by button")
        }
        for field in ["search","to","subject"] {
            let b=SendRules.buttonSend(surface:"social",field:field)
            pass(b.send == "unknown" && b.sendBy == nil,"fix/chrome-capture: a button after a social \(field) box is never a post")
        }
        for surface in ["email","chat","ai","aiTool","text","search","form","other","code","writing",""] {
            let b=SendRules.buttonSend(surface:surface,field:"body")
            pass(b.send == "unknown" && b.sendBy == nil,"fix/chrome-capture: a button on \(surface) is not proven (coverage limit): unknown")
        }
        // Never "sent": the vocabulary is detected/none/unknown.
        pass(Set(cases.flatMap {c in ([.submit,.submitChord,.mailSend]+notSends).map {SendRules.facts(bundle:c.bundle,host:c.host,title:c.title,field:c.field,seal:$0).send}}).isSubset(of:["detected","none","unknown"]),
             "K4: send is detected, none or unknown, never sent")
        // Field class: labels and roles, never contents.
        pass(SendRules.fieldClass(role:"AXTextField",labels:["To:"]) == "to" && SendRules.fieldClass(role:"AXTextField",labels:["Subject"]) == "subject"
             && SendRules.fieldClass(role:"AXTextArea",labels:["Message Body"]) == "body" && SendRules.fieldClass(role:"AXTextArea",labels:["Message #general"],composer:true) == "message"
             && SendRules.fieldClass(role:"AXTextField",labels:["Search"]) == "search" && SendRules.fieldClass(role:"AXTextField",labels:[],search:true) == "search"
             && SendRules.fieldClass(role:"AXTextField") == "oneLine" && SendRules.fieldClass(role:"AXTextArea") == "textArea" && SendRules.fieldClass(role:"AXGroup") == "unknown",
             "field classes from roles and labels")
        pass(SendRules.facts(bundle:"com.google.Chrome",host:"mail.google.com",field:"message",seal:.submitChord).field == "body","an email composer's message box is its body")
        pass(SendRules.facts(bundle:"com.apple.MobileSMS",title:"Mom",field:"textArea",seal:.submit).field == "message","Messages' box is a message field")
        pass(SendRules.facts(bundle:"com.apple.MobileSMS",title:"Mom",field:"nonsense",seal:.submit).field == "unknown","an unknown Messages field remains unknown")
        for field in ["unknown", "oneLine", "to", "subject", "search", "nonsense"] {
            let facts=SendRules.facts(bundle:"com.apple.MobileSMS",title:"New Message",field:field,seal:.submit)
            pass(facts.send == "unknown" && facts.sendBy == nil && facts.to == nil,"Messages Return in \(field) cannot claim a body send or recipient")
        }
    }

    /// messages-1003: Messages' composer is a single-line AXTextField (live 2026-10-03). Its class comes from its labels or
    /// a conversation title; a send needs Return plus the composer emptying (`messagesClearedSend`).
    static func messages1003() {
        pass(SendRules.messagesField(role:"AXTextField",subrole:"",labels:["iMessage"],title:"Messages") == "message","a labelled iMessage composer is a message field even in a generic window")
        pass(SendRules.messagesField(role:"AXTextField",subrole:"",labels:["Message","Text Message • SMS"],title:"") == "message","Text Message / SMS composer labels")
        pass(SendRules.messagesField(role:"AXTextField",subrole:"",labels:[],title:"Sam") == "message","an unlabelled text box in a named conversation is its composer")
        pass(SendRules.messagesField(role:"AXTextField",subrole:"",labels:[],title:"Messages") == "oneLine","an unlabelled box in a generic window proves nothing (B2)")
        pass(SendRules.messagesField(role:"AXTextField",subrole:"",labels:[],title:"New Message") == "oneLine","New Message: unlabelled proves nothing (B2)")
        pass(SendRules.messagesField(role:"AXTextField",subrole:"",labels:[],title:"+1 (555) 010-7788") == "oneLine","a phone-number title names no conversation")
        pass(SendRules.messagesField(role:"AXTextField",subrole:"AXSearchField",labels:[],title:"Sam") == "search","the sidebar search box (subrole) is search")
        pass(SendRules.messagesField(role:"AXTextField",subrole:"",labels:["Search"],title:"Sam") == "search","the sidebar search box (label) is search")
        pass(SendRules.messagesField(role:"AXTextField",subrole:"",labels:["To:"],title:"New Message") == "to","New Message's To box")
        pass(SendRules.messagesField(role:"AXTextField",subrole:"",labels:["To:"],title:"Sam") == "to","a To label wins over a conversation title")
        let sent=SendRules.facts(bundle:"com.apple.MobileSMS",title:"Sam",field:"message",seal:.submit)
        pass(sent.send == "unknown" && sent.to == "Sam","Return alone: unknown, the conversation named")
        pass(SendRules.messagesClearedSend(surface:sent.surface,field:sent.field,seal:"submit") == ("detected","return"),"Return then an empty composer: a send by Return")
        for field in ["to","search","oneLine","unknown","subject"] {
            pass(SendRules.messagesClearedSend(surface:"text",field:field,seal:"submit").send == "unknown","an emptied \(field) box is never a send")
        }
        for seal in ["idle","focus","pointer","focusKey","submitChord"] {
            pass(SendRules.messagesClearedSend(surface:"text",field:"message",seal:seal).send == "unknown","a \(seal) seal is never a send")
        }
        pass(SendRules.messagesClearedSend(surface:"chat",field:"message",seal:"submit").send == "unknown","only Messages' text surface")
        let newMessage=SendRules.facts(bundle:"com.apple.MobileSMS",title:"New Message",field:"message",seal:.submit)
        pass(newMessage.to == nil,"New Message with an empty To never names anyone")
        // The sent text: the field's value at Return, when it can stand for the keys' text.
        pass(TypingSession.sentValue("Me and my friendr going to ZUX tmrw",typed:"me and my friendsr going to ZUX tmrw") == "Me and my friendr going to ZUX tmrw","autocorrect and capitals: the field's value is the sent text")
        pass(TypingSession.sentValue("Line one\nline two\n",typed:"Line one\nline two") == "Line one\nline two","Shift-Return lines kept; a trailing newline dropped")
        pass(TypingSession.sentValue("",typed:"hello") == nil && TypingSession.sentValue("   ",typed:"hi") == nil,"an already-cleared field: keep the keys' text")
        pass(TypingSession.sentValue("an older draft that was already in the box before this message started",typed:"ok") == nil,"a much longer value is not this unit's text")
        pass(TypingSession.sentValue("see \u{FFFC} this",typed:"see  this") == nil,"an attachment character: keep the keys' text")
    }

    static func surfaces() {
        pass(SendRules.aiToolTitle("✳ Claude Code") && SendRules.aiToolTitle("codex — ~/app") && !SendRules.aiToolTitle("claudette.txt — zsh") && !SendRules.aiToolTitle("zsh"),
             "Claude Code and Codex are recognised by whole words in the terminal title")
        pass(SendRules.surface(bundle:"com.anthropic.claudefordesktop",host:"claude.ai") == "ai","the Claude app showing claude.ai is an AI app")
        pass(SendRules.surface(bundle:"com.google.Chrome",host:"https://mail.google.com/mail/u/0") == "email" && SendRules.surface(bundle:"com.google.Chrome",host:"www.google.com",field:"search") == "search",
             "mail.google.com is email although google.com is search")
        pass(SendRules.surface(bundle:"com.tinyspeck.slackmacgap") == "chat" && SendRules.surface(bundle:"com.apple.mail") == "email" && SendRules.surface(bundle:"com.example.unknown") == "other",
             "desktop chat, Mail and unknown apps")
    }

    /// Same harmless phrase ("greenhouse workshop supplies") in each fixture. Typed words are deliberately
    /// not a SendRules input: classification uses only already-verified source/field metadata.
    static func verifiedSearchContexts() {
        let chrome="com.google.Chrome"
        let cases:[(host:String,role:String,labels:[String],composer:Bool,search:Bool,field:String,surface:String)]=[
            ("x.com","AXSearchField",["Search"],false,false,"search","search"),
            ("x.com","AXTextArea",["What is happening?!"],true,false,"message","social"),
            ("x.com","AXTextArea",["Post your reply"],true,false,"message","social"),
            ("x.com","AXTextArea",["Start a new message"],true,false,"message","social"),
            ("chatgpt.com","AXTextArea",["Message ChatGPT"],true,false,"message","ai"),
            ("claude.ai","AXTextArea",[],true,false,"message","ai"),
            ("mail.google.com","AXTextField",["Search mail"],false,false,"search","search"),
            ("app.slack.com","AXTextField",["Search workspace"],false,false,"search","search"),
            ("chatgpt.com","AXTextField",["Search chats"],false,false,"search","search"),
            ("google.com","AXTextField",[],false,true,"search","search"),
            ("google.com","AXComboBox",["Address and search bar"],false,false,"oneLine","form"),
            ("x.com","AXComboBox",["Address and search bar"],false,false,"oneLine","social"),
            ("example.com","AXTextField",[],false,false,"oneLine","form"),
            ("example.com","AXGroup",[],false,false,"unknown","other"),
        ]
        for c in cases {
            let field=SendRules.fieldClass(role:c.role,labels:c.labels,composer:c.composer,search:c.search)
            pass(field == c.field,"verified field metadata on \(c.host) classifies as \(c.field)")
            for seal in [SealReason.submit,.submitChord,.pointer,.idle,.focus] {
                let facts=SendRules.facts(bundle:chrome,host:c.host,field:field,seal:seal)
                pass(facts.surface == c.surface && facts.field == c.field,"field context precedes host category on \(c.host)")
                if c.surface == "search" {
                    pass(facts.send == (seal == .submit ? "detected" : "unknown") && facts.sendBy == (seal == .submit ? "return" : nil),"verified search detects only plain Return, never a post chord or pointer")
                    pass(facts.to == nil,"search does not fabricate an AI recipient, chat target or email recipient")
                    let button=SendRules.buttonSend(surface:facts.surface,field:facts.field)
                    pass(button.send == "unknown" && button.sendBy == nil,"search never inherits a social Post control activation")
                }
                pass(facts.send != "sent" && facts.send != "delivered","classification never proves submission receipt or delivery")
            }
        }
        for host in ["google.com","bing.com","duckduckgo.com"] {
            for field in ["unknown","textArea","nonsense"] {
                let f=SendRules.facts(bundle:chrome,host:host,field:field,seal:.submit)
                pass(f.surface == "other" && f.send == "unknown" && f.sendBy == nil,"search-engine host without a verified search field cannot claim search submission")
            }
        }
        pass(SendRules.fieldClass(role:"AXSearchField",labels:["To:"]) == "search" && SendRules.fieldClass(role:"AXTextField",labels:["Subject"],search:true) == "search","verified search role/flag wins over incidental email labels")
        for host in ["x.com","chatgpt.com","google.com"] {
            let field=SendRules.fieldClass(role:"AXComboBox",labels:["Address and search bar"])
            let f=SendRules.facts(bundle:chrome,host:host,field:field,seal:.submit)
            pass(f.field == "oneLine" && f.surface != "search","address-bar metadata does not establish a web search")
            if host != "chatgpt.com" { pass(f.send == "unknown","navigation-like metadata on X or a search engine does not establish submission") }
            // An AI host retains its coarse existing send table. Actual omnibox input must fail the route's
            // WebContentAXReader page-ownership proof before SendRules receives any website context.
        }
        for key in [KeyStroke(keyCode:36,shift:true),KeyStroke(keyCode:36,option:true)] {
            var map=TypingKeyMap()
            pass(map.intent(key,pressAndHold:false) == .insertText("\n"),"newline modifiers do not become search or send gestures")
        }
        // These inputs prove a composer but not its social subtype or recipient. No content/title guess fills the gap.
        for label in ["What is happening?!","Post your reply","Start a new message"] {
            pass(SendRules.fieldClass(role:"AXTextArea",labels:[label],composer:true) == "message","existing verified composer class is preserved without inventing a subtype")
            pass(SendRules.composerPlace(labels:[label,"Message Sam"],host:"x.com") == nil,"social composer labels do not fabricate a DM recipient")
        }
    }

    /// §4 test-6 rows: who or where, only from what code read.
    static func places() {
        pass(SendRules.facts(bundle:"com.apple.MobileSMS",title:"Mom",field:"message",seal:.submit).to == "Mom","Messages: the window title names the conversation")
        pass(SendRules.facts(bundle:"com.apple.MobileSMS",title:"Family",field:"message",seal:.submit).to == "Family","Messages: a group name is used as is")
        pass(SendRules.facts(bundle:"com.apple.MobileSMS",title:"Messages",field:"message",seal:.submit).to == nil,"Messages: the app's own title names nobody")
        pass(SendRules.messagesPlace(title:"+1 (555) 010-7788") == nil && SendRules.messagesPlace(title:"sam@example.com") == nil,"Messages: a phone number or address title is never kept")
        pass(SendRules.messagesPlace(title:"Mom — Messages") == "Mom","Messages: the app suffix is dropped")
        // claude/messages2-1003: a conversation known only by its number or address is named by it, formatted (fictional).
        pass(SendRules.messagesHandle("+15550100142") == "+1 (555) 010-0142" && SendRules.messagesHandle("(555) 010-0142") == "(555) 010-0142"
             && SendRules.messagesHandle("5550100142") == "(555) 010-0142" && SendRules.messagesHandle("+1 (555) 010-0142 — Messages") == "+1 (555) 010-0142",
             "Messages handle: US numbers formatted, the app suffix dropped")
        pass(SendRules.messagesHandle("+44 20 7946 0958") == "+44 20 7946 0958" && SendRules.messagesHandle("sam@example.com") == "sam@example.com",
             "Messages handle: other numbers as written; an address as is")
        pass(SendRules.messagesHandle("Sam") == nil && SendRules.messagesHandle("New Message") == nil && SendRules.messagesHandle("12345") == nil
             && SendRules.messagesHandle("call 555 010 0142 now") == nil && SendRules.messagesHandle("+1 555+0100142") == nil,
             "Messages handle: names, short codes and mixed text are not handles")
        pass(SendRules.messagesConversation("Sam") == "Sam" && SendRules.messagesConversation("+15550100142") == "+1 (555) 010-0142",
             "Messages conversation: the name, else the handle")
        pass(SendRules.composerPlace(labels:["Message #general"],host:"app.slack.com") == "#general","Slack web: Message #general is the channel")
        pass(SendRules.composerPlace(labels:["Message @sam"],host:"discord.com") == "sam","Discord web: Message @sam is the person")
        pass(SendRules.composerPlace(labels:["","Reply to Sam…"],host:"app.slack.com") == "Sam","Slack web: Reply to Sam is the person (never \"Replied\" in test 6)")
        pass(SendRules.composerPlace(labels:["Message ChatGPT"],host:"chatgpt.com") == nil,"a composer label names nobody outside chat hosts")
        pass(SendRules.composerPlace(labels:["Message #general"],host:"example.com") == nil,"only chat hosts")
        pass(SendRules.composerPlace(labels:["Message"],host:"app.slack.com") == nil && SendRules.composerPlace(labels:["Message 555 0101"],host:"app.slack.com") == nil,
             "a bare label or one with a number names nobody")
        pass(SendRules.facts(bundle:"com.google.Chrome",host:"app.slack.com",field:"message",composerPlace:"#launch",seal:.submit).to == "#launch","chat: the composer place is stored")
        pass(SendRules.facts(bundle:"com.google.Chrome",host:"web.whatsapp.com",field:"message",composerPlace:nil,seal:.submit).to == nil,"WhatsApp web names nobody")
        pass(SendRules.facts(bundle:"com.anthropic.claudefordesktop",title:"Claude",field:"textArea",composerPlace:"#x",recipient:"Sam",seal:.submit).to == "Claude","AI apps store the AI as the recipient, never a composer place or a remembered person")
        pass(SendRules.facts(bundle:"com.openai.codex",title:"ChatGPT",field:"textArea",seal:.submit).to == "ChatGPT"
             && SendRules.facts(bundle:"com.google.Chrome",host:"claude.ai",field:"textArea",seal:.submit).to == "Claude"
             && SendRules.facts(bundle:"com.apple.Terminal",title:"✳ Claude Code — tallybird",field:"textArea",seal:.submit).to == "Claude Code",
             "an ask names the AI by app, site or terminal title")
        pass(SendRules.facts(bundle:"com.apple.mail",title:"New Message",field:"body",recipient:"Sam",seal:.mailSend).to == "Sam","Mail: the remembered To name is stored")
    }

    static func memories() {
        let m=RecipientMemory()
        pass(m.observe(window:"w",field:"to",text:"Sam,",seal:.focusKey,now:1) == nil,"the To unit itself names nobody")
        pass(m.observe(window:"w",field:"body",text:"hi",seal:.idle,now:2) == "Sam","a later body unit in the same window gets the To name")
        pass(m.observe(window:"other",field:"body",text:"hi",seal:.idle,now:3) == nil,"another window gets nothing")
        pass(m.observe(window:"w",field:"body",text:"hi",seal:.idle,now:2+RecipientMemory.lifetime+1) == nil,"the name is forgotten after 30 minutes")
        pass(RecipientMemory.name(fromToField:"sa",seal:.submit) == nil && RecipientMemory.name(fromToField:"Sam",seal:.submit) == nil,"a prefix picked with Return names nobody")
        pass(RecipientMemory.name(fromToField:"sa",seal:.focusKey) == nil && RecipientMemory.name(fromToField:"sam@example.com",seal:.focusKey) == nil
             && RecipientMemory.name(fromToField:"Sam 2",seal:.focusKey) == nil && RecipientMemory.name(fromToField:"Priya Shah",seal:.focusKey) == "Priya Shah",
             "only a whole name of 3+ letters, at most two words, no @ or digits")
        let p=PasteMemory()
        pass(!p.observe(field:"f",seal:.idle),"no paste, not pasted")
        pass(p.observe(field:"f",seal:.paste),"the unit a paste sealed is pasted")
        pass(p.observe(field:"f",seal:.submit),"the next unit in the same field is part of the pasted message")
        pass(!p.observe(field:"f",seal:.submit),"and the one after that is not")
        _=p.observe(field:"f",seal:.paste)
        pass(!p.observe(field:"g",seal:.submit),"another field is not")
    }
}
