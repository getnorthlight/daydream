import Foundation

/// Conservative, same-item source coverage for a bounded quality repair.
/// Token retention is not a claim of semantic equivalence. No titles or other runs supply facts.
extension CanonicalGrounding {
    struct SourceDetail {
        enum Kind { case absence, availability, negated, request, question }
        let kind:Kind
        let targets:Set<String>
        let verbs:Set<String>
        let phrase:String
    }
    static let detailVerbs="look over|point out|check|confirm|mark|flag|add|update|locate|suggest|review|inspect"
    static let detailFunction:Set<String>=qualityFunctionWords.union(["still","any","some","its","it","one","you","your","please","could","can","would","will","may","is","are","was","were","does","do","did","not","no","never","has","have","had"])
    static let detailVerbForms:[String:String] = {
        var forms:[String:String]=[:]
        for root in ["review","inspect","check","point","identify","flag","confirm","verify","mark","highlight","add","include","update","refresh","locate","find","suggest","propose","look"] {
            forms[root]=root;forms[root+"s"]=root
            if root=="flag" {forms["flagged"]=root;forms["flagging"]=root}
            else if root=="identify" || root=="verify" {forms[String(root.dropLast())+"ied"]=root;forms[root+"ing"]=root}
            else if root.hasSuffix("e") {forms[root+"d"]=root;forms[String(root.dropLast())+"ing"]=root}
            else {forms[root+"ed"]=root;forms[root+"ing"]=root}
        }
        forms["found"]="find"
        return forms
    }()
    static func detailVerb(_ word:String)->String {detailVerbForms[word] ?? qualityStem(word)}
    static func detailWords(_ text:String)->Set<String> {Set(guardWords(text).filter {!detailFunction.contains($0)}.map(qualityStem))}
    static func detailMatches(_ pattern:String,_ text:String)->[[String]] {
        guard let rx=try? NSRegularExpression(pattern:pattern,options:.caseInsensitive) else {return []}
        return rx.matches(in:text,range:NSRange(text.startIndex...,in:text)).map {m in
            (1..<m.numberOfRanges).map {i in Range(m.range(at:i),in:text).map {String(text[$0])} ?? ""}
        }
    }
    static func sourceDetails(_ item:ModelItem)->[SourceDetail] {
        guard summaryRecipient(item) != nil,let source=item.text,source.count<=400 else {return []}
        let shown=ModelView.shown(source,ModelView.typedQuoteChars)
        guard !shown.hidden,!source.contains("…"),!source.contains("..."),!source.contains("[withheld]") else {return []}
        var facts:[SourceDetail]=[]
        let cleaned=source.replacingOccurrences(of:#"(?i)^I noticed that\s+"#,with:"",options:.regularExpression)
        let absence=detailMatches(#"^(?:the|this|that|my|our|a|an)\s+([\p{L}'’-]+(?:\s+[\p{L}'’-]+){0,4}?)\s+(?:still\s+)?(?:lacks?|(?:is|are|was|were)\s+(?:still\s+)?missing)\s+([^.;!?]+)"#,cleaned)
        if let a=absence.first,a.count==2,!sourceNegation.search(a.joined(separator:" ")) {
            let targets=detailWords(a.joined(separator:" "))
            if !targets.isEmpty,targets.count<=10 {facts.append(SourceDetail(kind:.absence,targets:targets,verbs:[],phrase:a.joined(separator:" — ")))}
        }
        let negative=detailMatches(#"^(?:the|this|that|my|our|a|an)\s+([\p{L}'’-]+(?:\s+[\p{L}'’-]+){0,4}?)\s+(?:is|are|was|were)\s+(unavailable|not\s+[\p{L}]+)\b"#,cleaned)
        if let n=negative.first,n.count==2 {
            let targets=detailWords(n[0]),availability=n[1].lowercased().contains("available")
            if !targets.isEmpty {facts.append(SourceDetail(kind:availability ? .availability:.negated,targets:targets,verbs:availability ? []:detailWords(n[1]),phrase:n.joined(separator:" — ")))}
        }
        let questions=detailMatches(#"(?:^|[.;!?]\s*)(?:is|are)\s+there\s+([^.;!?]+)\?"#,source)
        for q in questions where q.count==1 {
            guard !guardWords(q[0]).contains(where:{["no","not","never"].contains($0)}) else {continue}
            let targets=detailWords(q[0])
            if !targets.isEmpty,targets.count<=6 {facts.append(SourceDetail(kind:.question,targets:targets,verbs:[],phrase:"inquiry: "+q[0]))}
        }
        let availabilityQuestions=detailMatches(#"(?:^|[.;!?]\s*)(?:is|are)\s+((?:the|this|that)\s+[^.;!?]+?)\s+(open|available)\s+([^.;!?]*)\?"#,source)
        for q in availabilityQuestions where q.count==3 {
            let targets=detailWords(q.joined(separator:" "))
            if !targets.isEmpty,targets.count<=6 {facts.append(SourceDetail(kind:.question,targets:targets,verbs:[],phrase:"inquiry: "+q.joined(separator:" ")))}
        }
        let requests=detailMatches("(?:^|[.;!?]\\s*|,\\s*)(?:please\\s+|(?:could|can|would|will)\\s+you\\s+)("+detailVerbs+")\\s+([^.;!?]+)",source)
        for request in requests where request.count==2 {
            let parts=request[1].replacingOccurrences(of:"\\s+and\\s+(?=(?:"+detailVerbs+")\\s+)",with:"|",options:.regularExpression).components(separatedBy:"|")
            for (index,part) in parts.enumerated() {
                let target:String,verb:String
                if index==0 {target=part;verb=request[0]}
                else {
                    guard let m=detailMatches("^("+detailVerbs+")\\s+(.+)$",part).first,m.count==2 else {continue}
                    verb=m[0];target=m[1]
                }
                guard !embeddedClause.search(target) else {continue}
                let nouns=detailWords(target)
                guard nouns.count<=6 else {continue}
                let equivalent:[String:Set<String>]=[
                    "look over":["look","review","inspect","check"],"point out":["point","identify","flag"],
                    "check":["check","inspect","review"],"confirm":["confirm","verify"],
                    "mark":["mark","flag","highlight"],"flag":["flag","mark","highlight"],
                    "add":["add","include"],"update":["update","refresh"],"locate":["locate","find"],
                    "suggest":["suggest","propose"],"review":["review","inspect","check"],"inspect":["inspect","check","review"]]
                facts.append(SourceDetail(kind:.request,targets:nouns,verbs:Set((equivalent[verb.lowercased()] ?? [verb.lowercased()]).map(qualityStem)),phrase:verb+" "+target))
            }
        }
        return facts.count<=8 ? facts:[]
    }
    /// Conjunctions and punctuation separate relations. Only a coordinated request
    /// verb can inherit its preceding inquiry; another assertion cannot borrow it.
    static func detailClauses(_ text:String)->[String] {
        text.replacingOccurrences(of:#"(?i)[,;.!?]+|\s+\b(?:and|but|while|whereas|because|since)\b\s+"#,with:"|",options:.regularExpression)
            .components(separatedBy:"|").map {$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter {!$0.isEmpty}
    }
    static func detailInquiry(_ text:String)->Bool {
        questionClause.search(text) || text.range(of:#"(?i)\brequest(?:ed|ing)?\b"#,options:.regularExpression) != nil
    }
    static func detailRequestScopes(_ text:String)->[(String,Bool,Bool)] {
        var scopes:[(String,Bool,Bool)]=[],priorInquiry=false,priorNegative=false
        for clause in detailClauses(text) {
            let direct=detailInquiry(clause)
            let first=guardWords(clause).first ?? ""
            let coordinated=detailVerbForms[first] != nil
            let inquiry=direct || (coordinated && priorInquiry)
            let negative=sourceNegation.search(clause) || (coordinated && priorInquiry && priorNegative)
            // An explicit inquiry marker owns only the words that follow it.
            let scoped:String
            if let marker=clause.range(of:#"(?i)\b(?:ask(?:ed|ing)?|request(?:ed|ing)?|inquir\w*|whether|how|when|why|if)\b"#,options:.regularExpression) {
                scoped=String(clause[marker.lowerBound...])
            } else {scoped=clause}
            scopes.append((scoped,inquiry,negative))
            priorInquiry=inquiry;priorNegative=negative
        }
        return scopes
    }
    static func detailRequestVerbs(_ part:String)->Set<String> {
        let words=guardWords(part)
        var verbs=Set(words.map(detailVerb))
        // A nominal suggestion is an ask-to-suggest only in the request's own
        // grammar. An explicit different action over a suggestion remains that action.
        if !words.contains(where:{detailVerbForms[$0] != nil}) {
            let nominal=part.range(of:#"(?i)^(?:asked|asking|requested|requesting)\s+(?:for\s+)?(?:(?:a|an|the)\s+)?(?:[^.;!?]{1,100}\s+suggestions?|suggestions?\s+for\s+[^.;!?]{1,100})$"#,options:.regularExpression) != nil
            if nominal {verbs.insert("suggest")}
        }
        return verbs
    }
    static func detailStatements(_ text:String,_ items:[ModelItem])->[(Set<String>,String)] {
        var result:[(Set<String>,String)]=[]
        for original in detailClauses(text) where !detailInquiry(original) {
            var clause=original
            if let lead=items.flatMap({$0.leadPhrases()}).filter({clause.lowercased().hasPrefix($0.lowercased())}).max(by:{$0.count<$1.count}) {
                clause=String(clause.dropFirst(lead.count)).trimmingCharacters(in:.whitespacesAndNewlines)
            }
            let matches=detailMatches(#"(?:^|\bthat\s+)(?:(?:the|this|that|my|our|a|an)\s+)?([\p{L}'’-]+(?:\s+[\p{L}'’-]+){0,4}?)\s+(?:is|are|was|were)\s+(.+)$"#,clause)
            for match in matches where match.count==2 {result.append((detailWords(match[0]),match[1]))}
        }
        return result
    }
    static func detailNegativePredicate(_ predicate:String,_ fact:SourceDetail)->Bool {
        if fact.kind == .availability {
            return predicate.range(of:#"(?i)^(?:still\s+)?(?:unavailable|not\s+(?:currently\s+)?available)\b"#,options:.regularExpression) != nil
        }
        let finite:[String:String]=["finish":"unfinished","complete":"incomplete","readable":"unreadable","reserv":"unreserved","empty":"nonempty","accessible":"inaccessible"]
        let words=Set(guardWords(predicate).map(qualityStem))
        let explicit=predicate.range(of:#"(?i)^(?:still\s+)?not\s+"#,options:.regularExpression) != nil && fact.verbs.isSubset(of:words)
        let lexical=fact.verbs.count==1 && fact.verbs.first.flatMap {finite[$0]}.map {guardWords(predicate).first==$0} == true
        return explicit || lexical
    }
    static func detailAbsenceNegated(_ text:String,_ fact:SourceDetail,_ items:[ModelItem])->Bool {
        let subject=detailWords(fact.phrase.components(separatedBy:" — ").first ?? "")
        return detailClauses(text).contains {original in
            guard !detailInquiry(original) else {return false}
            var clause=original
            if let lead=items.flatMap({$0.leadPhrases()}).filter({clause.lowercased().hasPrefix($0.lowercased())}).max(by:{$0.count<$1.count}) {
                clause=String(clause.dropFirst(lead.count)).trimmingCharacters(in:.whitespacesAndNewlines)
            }
            let matches=detailMatches(#"(?:^|\bthat\s+)(?:(?:the|this|that|my|our|a|an)\s+)?([\p{L}'’-]+(?:\s+[\p{L}'’-]+){0,4}?)\s+((?:(?:does\s+not|doesn['’]t|no\s+longer|never|not)\s+)?(?:still\s+)?lacks?\b.*|(?:is|are|was|were)\s+(?:still\s+)?(?:(?:not|no\s+longer|never)\s+)?missing\b.*)$"#,clause)
            return matches.contains {match in
                match.count==2 && detailWords(match[0])==subject && fact.targets.isSubset(of:detailWords(match.joined(separator:" "))) &&
                match[1].range(of:#"(?i)\b(?:does\s+not|doesn['’]t|no\s+longer|never|not)\s+(?:still\s+)?(?:lacks?|missing)\b"#,options:.regularExpression) != nil
            }
        }
    }
    static func missingDetails(_ text:String,_ items:[ModelItem])->[SourceDetail] {
        let clauses=detailClauses(text),scopes=detailRequestScopes(text),statements=detailStatements(text,items)
        return items.flatMap(sourceDetails).filter {fact in
            switch fact.kind {
            case .absence:
                return detailAbsenceNegated(text,fact,items) || !clauses.contains {part in !detailInquiry(part) && !sourceNegation.search(part) && absenceParaphrase.search(part) && fact.targets.isSubset(of:detailWords(part))}
            case .availability,.negated:
                return !statements.contains {subject,predicate in subject==fact.targets && detailNegativePredicate(predicate,fact)}
            case .question:
                return !scopes.contains {part,inquiry,_ in inquiry && fact.targets.isSubset(of:detailWords(part))}
            case .request:
                return !scopes.contains {part,inquiry,negative in
                    inquiry && !negative && !fact.verbs.isDisjoint(with:detailRequestVerbs(part)) && fact.targets.isSubset(of:detailWords(part))
                }
            }
        }
    }
    /// A correct negative elsewhere cannot rescue a contradictory assertion, and
    /// an unrelated inquiry cannot turn a confirmed assertion into a question.
    static func changedNegativeStatement(_ text:String,_ items:[ModelItem])->Bool {
        let statements=detailStatements(text,items)
        return items.flatMap(sourceDetails).contains {fact in
            switch fact.kind {
            case .availability,.negated:
                return statements.contains {subject,predicate in subject==fact.targets && !detailNegativePredicate(predicate,fact)}
            case .question:
                return detailClauses(text).contains {part in
                    !detailInquiry(part) && fact.targets.isSubset(of:detailWords(part)) &&
                    part.range(of:#"(?i)\b(?:is|are|was|were)\b"#,options:.regularExpression) != nil
                }
            case .absence:return detailAbsenceNegated(text,fact,items)
            default:return false
            }
        }
    }
    /// Preserve all original content tokens, with two finite predicate forms
    /// canonicalized only when the same captured clause is covered in both texts.
    /// This changes neither shared copy admission nor disclosure/retention policy.
    static func keepsSourceQualityContent(_ original:String,_ replacement:String,_ items:[ModelItem])->Bool {
        if keepsQualityContent(original,replacement,items) {return true}
        guard !changedNegativeStatement(original,items),!changedNegativeStatement(replacement,items) else {return false}
        let oldMissing=missingDetails(original,items),newMissing=missingDetails(replacement,items)
        let covered=items.flatMap(sourceDetails).filter {fact in
            !oldMissing.contains {$0.kind==fact.kind && $0.phrase==fact.phrase} &&
            !newMissing.contains {$0.kind==fact.kind && $0.phrase==fact.phrase}
        }
        let absence=covered.contains {$0.kind == .absence}
        let unfinished=covered.contains {$0.kind == .negated && $0.verbs == ["finish"]}
        guard absence || unfinished else {return false}
        func normalized(_ text:String)->Set<String> {
            var tokens=Set<String>()
            for word in qualityContent(text,items) {
                let stem=qualityStem(word)
                if absence && ["miss","lack"].contains(stem) {tokens.insert("absence-predicate")}
                else if unfinished && word=="unfinished" {tokens.formUnion(["not","finish"])}
                else {tokens.insert(stem)}
            }
            return tokens
        }
        return normalized(original).isSubset(of:normalized(replacement))
    }
    static func detailRepairProblem(_ text:String,_ items:[ModelItem],all:Bool=false)->String? {
        let missing=all ? items.flatMap(sourceDetails):missingDetails(text,items)
        guard !missing.isEmpty else {return nil}
        let phrases=missing.map(\.phrase).joined(separator:"; ")
        return "Preserve every separately captured statement and request from its cited item. Missing source clauses: "+String(phrases.prefix(700))+". Keep each request's verb associated with its own target, every negative statement, timing and uncertainty. Do not infer a cause or replace a negative statement with an unobserved affirmative outcome. Preserve every meaningful original content word; add the omitted clauses instead of replacing existing detail. Break long copied source phrases with different surrounding sentence grammar while retaining source object names and qualifiers. Do not copy the source sentence."
    }
}
