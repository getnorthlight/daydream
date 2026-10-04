import Foundation

/// fix/sx-all round 2: the one filler list (source of truth: the writer's `CanonicalGrounding.fillerPatterns`,
/// `fillerApps`, `fillerAIs`, `fillerAppPatterns` and `sharedFiller`, which MemoryCore can't import; notes-quality checks
/// the two are the same). The day card (MemoryUI `DaydreamNotes`) and recall (`LevelRecall`) drop exactly the lines the
/// writer refuses: a line that names no one and nothing ("Wrote a message in Messages", "Texted.", "Drafted a text",
/// "Wrote something on x.com", "Had Chrome open"). Never a line that says what about (" about ") or to whom (" to Dana").
public enum NoteFiller {
    public static let patterns:[String]=[
        "^(also )?had (the |a |an )?.+ open\\b.*$",
        "^had an? ([^ ]+ )?(chat|conversation) with .+$",
        "^.* window (was )?open$",
        "^(wrote|drafted|typed|sent) (a |an )?(message|email|reply|text|draft|note|post)( (in|on) [^ #@][^ ]*( in [^ ]+)?)?$",
        "^wrote something( (in|on) [^ ]+( in [^ ]+)?)?$",
        "^typ(ed|ing)( a draft| text| something| a message)? (in|on) [^ ]+( in [^ ]+)?$",
        "^(texted|emailed|messaged|replied|told|posted|asked|drafted|wrote|typed)( someone)?$",
        // claude/messages-1003: who-less lines that only seem to name someone ("Drafted a message to someone", "Texted unknown").
        "^(texted|emailed|messaged|wrote|drafted|typed|sent)( (a |an )?(message|email|reply|text|draft|note|post))? (to )?(someone|somebody|unknown|an unknown [a-z]+)$",
        "^(also )?(was )?(using|used|in use)$",
        "^untitled( moment| window)?$",
        "^(an? )?activity (in|on) .+$",
        "^(about|around|under|over|nearly|almost|just under|just over) [^.]*(minute|minutes|hour|hours)$",
        // fix/bugs7 (merged at build/launch-sx): lines that name no app, person or thing at all ("You used your Mac.",
        // "Worked in apps."); fix/resummarize: how long alone ("5 minutes", "Less than a minute").
        "^(you )?(used|were using|was using|worked on|were working on|was working on) (your |the |this |a )?(mac|macbook|computer|laptop)$",
        "^(you )?(worked|were working|was working|spent time) (in|on|with|across|between) (various |several |some |many |multiple |different |a few |a couple of |your |the )?(apps|applications|programs|tools|windows|tasks)$",
        "^(you )?(used|opened|switched between|moved between|browsed) (various |several |some |many |multiple |different |a few |a couple of |your )?(apps|applications|programs|windows|tabs)$",
        "^(general |some )?(computer|mac) (use|usage|activity|time)$",
        "^(under|less than|about|around|over|nearly|almost)? ?(a|an|one|half an|a few|\\d+) (minute|minutes|min|mins|hour|hours)$",
        // fix/sx-all round 3: code's placeholder for a moment it can say nothing about ("In Cursor.", "In ChatGPT."): the
        // place only, which the row's title and time already say.
        "^in [^ ].*$",
    ]
    public static let knownApps:[String]=["Messages","Mail","Slack","Chrome","Google Chrome","Safari","ChatGPT","Claude","Xcode","Terminal","Notes",
                                           "Zoom","WhatsApp","Discord","Gmail","Google Docs","Codex","Cursor","YouTube","GitHub","X","Outlook","Teams",
                                           "Microsoft Teams","iTerm2","VS Code","LinkedIn"]
    public static let ais:[String]=["claude","claude code","chatgpt","codex","gemini","perplexity","copilot"]
    public static func appPatterns(_ name:String)->[String] {[
        "^(worked|working|was working|activity|time|spent time) (in|on|with) (the )?"+name+"( app)?( with .+)?$",
        "^(wrote|drafted|typed|sent) (a |an )?(message|email|reply|text|draft|note|post|something) (in|on|to) (the )?"+name+"( app)?$",
        "^wrote (to|in) (the )?"+name+"( app)?$",
        "^(used|using|opened|was using) (the )?"+name+"( app)?$",
        "^(the )?"+name+"( app)? (window )?(was )?open( and in use)?$",
        "^(the )?"+name+"( app)?$",
    ]}
    /// True for a line (or title) that names no one and nothing: the writer's `sharedFiller`, line for line.
    public static func isFiller(_ text:String,apps:[String])->Bool {
        let trimmed=text.trimmingCharacters(in:.whitespacesAndNewlines).trimmingCharacters(in:CharacterSet(charactersIn:"."))
        let t=trimmed.lowercased()
        if t.isEmpty {return true}
        if t.contains(" about ") {return false}
        // An AI app is who a message went to ("Drafted a message to Claude"): it names someone.
        if ais.contains(where:{t.hasSuffix(" to "+$0) || t.hasSuffix(" to the "+$0)}) {return false}
        var seen=Set<String>()
        for app in (apps+knownApps) where !app.isEmpty && seen.insert(app.lowercased()).inserted {
            let name=NSRegularExpression.escapedPattern(for:app.lowercased())
            if appPatterns(name).contains(where:{t.range(of:$0,options:.regularExpression) != nil}) {return true}
        }
        if trimmed.range(of:#" to [A-Z#@]"#,options:.regularExpression) != nil {return false}
        return patterns.contains {t.range(of:$0,options:.regularExpression) != nil}
    }
}
