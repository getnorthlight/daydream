import Foundation
import PrivacyPolicy

/// compose-send/v1: the generic compose-and-send model over every surface. Synthetic metadata and fictional text only.
enum ComposeSendChecks {
    static var passed=0
    static func pass(_ ok:Bool,_ label:String) {if !ok {fatalError("Compose send check failed: "+label)};passed+=1;print("PASS compose-send: "+label)}
    static func line(_ surface:String,field:String="message",send:String?="detected",sendBy:String?="return",control:String?=nil,to:String?=nil,
                     _ d:ComposeDestination = .init(),_ c:ComposeContext = .init()) -> String {
        ComposeSend.line(ComposeSend.outcome(surface:surface,field:field,send:send,sendBy:sendBy,sendControl:control,to:to,destination:d,context:c))
    }
    static func run() {
        // Gestures need a confirmation; time alone never confirms.
        pass(ComposeSend.confirmedSend(surface:"text",field:"message",gesture:.returnKey,confirmation:nil) == nil,"a gesture with no confirmation stays a draft")
        pass(ComposeSend.confirmedSend(surface:"text",field:"message",gesture:.returnKey,confirmation:.fieldCleared)! == ("detected","return","fieldCleared"),"Return + cleared field = send")
        pass(ComposeSend.confirmedSend(surface:"social",field:"textArea",gesture:.button,confirmation:.composerClosed)! == ("detected","button","composerClosed"),"a Reply button + closed composer = send")
        pass(ComposeSend.confirmedSend(surface:"social",field:"textArea",gesture:.commandReturn,confirmation:.routeChanged)! == ("detected","commandReturn","routeChanged"),"Cmd-Return + route change = send")
        for f in ["to","subject","search"] {pass(ComposeSend.confirmedSend(surface:"email",field:f,gesture:.returnKey,confirmation:.fieldCleared) == nil,"a \(f) box emptying is never a send")}
        for s in ["code","writing","search"] {pass(!ComposeSend.confirmable(surface:s,field:"textArea",gesture:.returnKey),"\(s) is never confirmed by a read")}
        pass(!ComposeSend.confirmable(surface:"text",field:"oneLine",gesture:.returnKey),"Messages: an unproven box (New Message's To) never confirms (B2)")
        pass(ComposeSend.confirmable(surface:"other",field:"oneLine",gesture:.returnKey),"an unknown composer still gets send detection")
        var keys=TypingKeyMap()
        pass(keys.intent(KeyStroke(keyCode:36,shift:true),pressAndHold:false) == .insertText("\n"),"Shift-Return is a newline, never a gesture")
        // Messages x3: the conversation's name on every send; no name: someone.
        let (jamie,_)=ComposeIdentity.messages(title:"Jamie Lin")
        for _ in 0..<3 {pass(line("text",to:jamie.name) == "Sent to Jamie Lin","Messages send: Sent to Jamie Lin")}
        pass(line("text",send:"unknown",to:"Jamie Lin") == "Draft to Jamie Lin (not sent)","Messages draft: Draft to Jamie Lin (not sent)")
        pass(line("text",to:ComposeIdentity.messages(title:"New Message").0.name) == "Sent to someone","New Message, no To: Sent to someone")
        pass(ComposeIdentity.messages(title:"+1 (555) 010-7788").0.name == nil,"a phone-number title names nobody")
        // X: a reply via the button, and via Cmd-Return, on Ada's status page; the parent post is the context.
        let title="Ada on X: \"Small tools beat big frameworks for most side projects, and they are much easier to keep running for years\" / X"
        let reply=ComposeIdentity.x(pageTitle:title,path:"/ada/status/1234567890",labels:["Post your reply"])
        pass(reply.reply && reply.0.handle == "ada" && reply.1.author == "Ada","X status page: a reply to @ada, author Ada")
        pass((reply.1.excerpt ?? "").count <= ComposeSend.contextLimit && (reply.1.excerpt ?? "").hasPrefix("Small tools beat big frameworks") && (reply.1.excerpt ?? "").hasSuffix("\u{2026}"),"the parent excerpt is clipped to about 80 characters")
        pass(line("social",field:"textArea",sendBy:"button",control:"reply",reply.0,reply.1) == "Replied to Ada's post on X","X reply by button: Replied to Ada's post on X")
        pass(line("social",field:"textArea",sendBy:"commandReturn",reply.0,reply.1) == "Replied to Ada's post on X","X reply by Cmd-Return: Replied to Ada's post on X")
        pass(ComposeSend.contextLine(reply.1)?.hasPrefix("on: \u{201C}Small tools beat big frameworks") == true,"the muted line quotes the parent post")
        let home=ComposeIdentity.x(pageTitle:"Home / X",path:"/home",labels:["Post text"])
        pass(!home.reply && home.1.isEmpty,"X home composer: a new post, no context")
        pass(line("social",field:"textArea",sendBy:"commandReturn",home.0,home.1) == "Posted on X","X post: Posted on X")
        pass(line("social",field:"textArea",send:"unknown",home.0,home.1) == "Draft in X (not sent)","X post discarded: a draft")
        pass(line("social",field:"textArea",sendBy:"button",control:"quote",reply.0,reply.1) == "Quoted Ada's post on X","X quote post")
        // Reddit: a comment on a post; the post's title is the context.
        let r=ComposeIdentity.reddit(pageTitle:"How do I profile SwiftUI redraws? : r/swift",path:"/r/swift/comments/abc123/how_do_i_profile/")
        pass(r.0.community == "swift" && r.1.excerpt == "How do I profile SwiftUI redraws?","Reddit: r/swift and the post title")
        pass(line("social",field:"textArea",sendBy:"button",control:"comment",r.0,r.1) == "Commented on r/swift","Reddit comment: Commented on r/swift")
        let newPost=ComposeIdentity.reddit(pageTitle:"Submit to r/swift",path:"/r/swift/submit")
        pass(newPost.1.isEmpty && line("social",field:"textArea",sendBy:"button",control:"post",newPost.0,newPost.1) == "Posted on Reddit","Reddit new post: Posted on Reddit")
        // Email: Gmail send with a recipient and subject; a reply's context is its subject.
        let g=ComposeIdentity.email(title:"Re: Pricing - me@example.com - Gmail",recipient:"Sam",service:"Gmail")
        pass(g.0.subject == "Pricing" && g.0.name == "Sam" && g.1.excerpt == "Pricing","Gmail: Sam, subject Pricing, a reply")
        pass(line("email",field:"body",sendBy:"commandReturn",g.0,g.1) == "Emailed Sam — Pricing","Gmail send: Emailed Sam — Pricing")
        pass(ComposeIdentity.email(title:"New Message").0.subject == nil,"Mail's New Message window has no subject")
        pass(line("email",field:"body",sendBy:"mailSend") == "Emailed someone","no recipient: Emailed someone")
        // AI asks and chat.
        pass(line("ai",field:"textArea",to:"ChatGPT") == "Asked ChatGPT","AI: Asked ChatGPT")
        pass(ComposeIdentity.aiChat(title:"ChatGPT - Trip planning",service:"ChatGPT").subject == "Trip planning","ChatGPT's chat name")
        pass(line("chat",to:ComposeIdentity.slack(labels:["Message #eng"]).name) == "Messaged #eng","Slack: Messaged #eng")
        // Terminals and an unknown composer.
        pass(line("code",field:"textArea") == "Ran a command","terminal: Ran a command")
        pass(line("other",field:"oneLine") == "Sent","an unknown composer: Sent, no destination")
        pass(line("other",field:"oneLine",send:"unknown") == "Draft (not sent)","an unknown composer's draft")
        pass(ComposeSend.clipContext(String(repeating:"word ",count:40)).count <= ComposeSend.contextLimit,"context is always clipped")
    }
}
