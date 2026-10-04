import Foundation
import MemoryCore
import PrivacyPolicy

/// summaries/v3 (intent lines spec §2; check K3 and the seal -> provenance -> state path): send facts on typed units.
/// K3: a typed-unit/v2 row (no send facts) keeps its exact JSON, description, state and revision, so no note is
/// invalidated. A typed-unit/v3 row whose send key was detected is "submitted" (never "sent"); any other is "draft".
func runTypedSendFactsChecks(home: URL) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func row(_ id: String, app: String = "Claude", bundle: String = "com.anthropic.claudefordesktop", title: String = "Claude", seal: String = "submit",
             facts: SendFacts? = nil, pasted: Bool = false, words: Int = 12) -> Evidence {
        var e = Evidence(id: id, at: iso(now), kind: "keyboard.text_input", app: app, bundle: bundle, title: title, text: "", synthetic: true)
        var unit = TypedUnitProvenance(runID: "run-1", part: 1, sealReason: seal, startedAt: iso(now.addingTimeInterval(-20)), keys: 40, edits: 2, withheld: 0)
        if let facts { unit.apply(facts, pasted: pasted) }
        e.captureProvenance = NativeCaptureProvenance(policyRevision: "r", classifierVersion: "sensitive-typing/v2+typed-scrub/v1", windowID: "w", focusID: "f",
                                                      checkedAt: iso(now), generation: 1, unit: unit)
        e.typed = TypedRef(digest: "d", words: words)
        return e
    }
    // K3: pinned bytes of a typed-unit/v2 row, as every build before summaries/v3 wrote and hashed it.
    let pinned = #"{"app":"Claude","at":"2027-01-15T08:00:00Z","bundle":"com.anthropic.claudefordesktop","captureProvenance":{"checkedAt":"2027-01-15T08:00:00Z","classifierVersion":"sensitive-typing/v2+typed-scrub/v1","focusID":"f","generation":1,"policyRevision":"r","unit":{"edits":2,"keys":40,"part":1,"runID":"run-1","sealReason":"submit","startedAt":"2027-01-15T07:59:40Z","version":"typed-unit/v2","withheld":0},"windowID":"w"},"id":"v2-row","kind":"keyboard.text_input","privateWindow":false,"secure":false,"synthetic":true,"text":"","title":"Claude","typed":{"digest":"d","v":1,"words":12},"url":""}"#
    let old = row("v2-row")
    try check(try json(old) == pinned, "K3: a typed-unit/v2 row encodes to the same bytes (no new keys)")
    let decoded = try decode(Evidence.self, pinned)
    try check(try json(decoded) == pinned && decoded.captureProvenance?.unit?.surface == nil && decoded.captureProvenance?.unit?.send == nil,
              "K3: a stored v2 row decodes with nil send facts and re-encodes byte-identical")
    let oldAction = ActionProjection.make(decoded)
    // B2 review: v4 invalidates Messages/search projections; unchanged non-Messages v2 rows keep their v3 revision.
    try check(ActionProjection.version == "canonical-action-v4" && oldAction.revision == fingerprint("canonical-action-v3" + pinned),
              "K3: the projection cache version advances, but an unaffected v2 row's revision is unchanged")
    try check(oldAction.state == "draft" && oldAction.description == "Typed a draft in Claude (a sentence).",
              "K3: a v2 row (even sealed by Return) stays a draft with its old description")

    // v3 rows: the state follows the stored send fact only.
    let asked = row("v3-asked", facts: SendRules.facts(bundle: "com.anthropic.claudefordesktop", title: "Claude", field: "textArea", seal: .submit))
    let a = ActionProjection.make(asked)
    try check(asked.captureProvenance?.unit?.version == "typed-unit/v3" && asked.captureProvenance?.unit?.surface == "ai" && asked.captureProvenance?.unit?.send == "detected"
              && asked.captureProvenance?.unit?.sendBy == "return", "a Return in Claude stores surface ai, send detected by return, typed-unit/v3")
    try check(a.state == "submitted" && a.description == "Typed in Claude, then used its send key (a sentence).", "a detected send is submitted, described without \"sent\"")
    try check(a.description.range(of: "(?i)\\bsent\\b", options: .regularExpression) == nil && a.state != "sent", "submitted is never sent")
    try check(TypedWords.bucket(fromDescription: a.description, app: "Claude") == "a sentence", "the submitted description keeps the word-count bucket AI apps read")
    // fix/chrome-capture: a proven click on the composer's Post button (sendBy "button"): submitted, said as a click on
    // Post, never "sent"; the bucket still parses; a v3 row without the mark keeps its bytes (no sendControl key).
    var clicked = row("v3-post", app: "Google Chrome", bundle: "com.google.Chrome", title: "Home / X", seal: "pointer",
                      facts: SendRules.facts(bundle: "com.google.Chrome", host: "x.com", field: "textArea", seal: .pointer))
    try check(clicked.captureProvenance?.unit?.surface == "social" && clicked.captureProvenance?.unit?.send == "unknown" && ActionProjection.make(clicked).state == "draft",
              "a click alone never marks a post: X's row sealed by a click is a draft with send unknown")
    let draftBytes = try json(clicked)
    try check(!draftBytes.contains("sendControl") && !draftBytes.contains("\"button\""), "an unmarked row carries no sendControl or button")
    clicked.captureProvenance?.unit?.send = "detected"; clicked.captureProvenance?.unit?.sendBy = "button"; clicked.captureProvenance?.unit?.sendControl = "post"
    let posted = ActionProjection.make(clicked)
    try check(posted.state == "submitted" && posted.description == "Typed in Google Chrome, then clicked its Post button (a sentence).",
              "a proven Post click is submitted and described as a click on Post (\(posted.description))")
    try check(posted.description.range(of: "(?i)\\b(sent|published|delivered)\\b", options: .regularExpression) == nil && posted.state != "sent",
              "a Post click is never sent, published or delivered")
    try check(TypedWords.bucket(fromDescription: posted.description, app: "Google Chrome") == "a sentence"
              && TypedWords.bucket(fromDescription: "Typed in Google Chrome, then clicked its Reply button (a few words).", app: "Google Chrome") == "a few words"
              && TypedWords.bucket(fromDescription: "Typed in Google Chrome, then clicked its Post button (pricing page).", app: "Google Chrome") == nil,
              "the Post and Reply descriptions keep the word-count bucket AI apps read, and nothing else parses")
    clicked.captureProvenance?.unit?.sendControl = "delete account"
    try check(ActionProjection.make(clicked).description == "Typed in Google Chrome, then clicked its send button (a sentence).",
              "a control name outside the list is never shown")
    let idle = row("v3-idle", seal: "idle", facts: SendRules.facts(bundle: "com.anthropic.claudefordesktop", title: "Claude", field: "textArea", seal: .idle))
    try check(ActionProjection.make(idle).state == "draft" && idle.captureProvenance?.unit?.send == "unknown", "an idle piece is a draft with send unknown")
    let mailReturn = row("v3-mail", app: "Mail", bundle: "com.apple.mail", title: "Re: Friday meeting", facts: SendRules.facts(bundle: "com.apple.mail", title: "Re: Friday meeting", field: "body", seal: .submit))
    try check(ActionProjection.make(mailReturn).state == "draft", "Return in Mail stays a draft")
    let mailSend = row("v3-mailsend", app: "Mail", bundle: "com.apple.mail", title: "Re: Friday meeting", seal: "mailSend",
                       facts: SendRules.facts(bundle: "com.apple.mail", title: "Re: Friday meeting", field: "body", recipient: "Sam", seal: .mailSend))
    try check(ActionProjection.make(mailSend).state == "submitted" && mailSend.captureProvenance?.unit?.to == "Sam" && mailSend.captureProvenance?.unit?.sendBy == "mailSend",
              "Command-Shift-D in Mail is submitted, with the To name")
    let notes = row("v3-notes", app: "Notes", bundle: "com.apple.Notes", title: "Groceries — Notes", facts: SendRules.facts(bundle: "com.apple.Notes", title: "Groceries", field: "textArea", seal: .submit))
    try check(ActionProjection.make(notes).state == "draft" && notes.captureProvenance?.unit?.send == "none", "Return in Notes is never a send")
    // terminal-1002 (owner decision 2026-10-02, RECORDING-MATRIX-1002 rows 1-2): a terminal line run with Return is a
    // command that ran: submitted, "Ran a command"; a terminal piece sealed any other way, and an editor, stay drafts.
    let ran = row("v3-ran", app: "Ghostty", bundle: "com.mitchellh.ghostty", title: "~/src",
                  facts: SendRules.facts(bundle: "com.mitchellh.ghostty", title: "~/src", field: "textArea", seal: .submit), words: 3)
    let ranAction = ActionProjection.make(ran)
    try check(ran.captureProvenance?.unit?.surface == "code" && ran.captureProvenance?.unit?.send == "detected" && ran.captureProvenance?.unit?.sendBy == "return"
              && ranAction.state == "submitted" && ranAction.description == "Ran a command in Ghostty (a few words).", "Return in a terminal: submitted, Ran a command")
    try check(MemoryStore.sendLine(ranAction, surface: "code", to: nil, label: "Ghostty") == TypedWords.ranCommandLabel && TypedWords.ranCommandLabel == "Ran a command",
              "a run command's card line says Ran a command")
    try check(TypedWords.bucket(fromDescription: ranAction.description, app: "Ghostty") == "a few words", "the run description keeps its word bucket")
    let terminalPiece = row("v3-terminal-app", app: "Terminal", bundle: "com.apple.Terminal", title: "sam — zsh", seal: "app",
                            facts: SendRules.facts(bundle: "com.apple.Terminal", title: "sam — zsh", field: "textArea", seal: .app))
    try check(ActionProjection.make(terminalPiece).state == "draft" && terminalPiece.captureProvenance?.unit?.send == "none", "a terminal piece sealed by an app switch stays a draft")
    let xcode = row("v3-xcode", app: "Xcode", bundle: "com.apple.dt.Xcode", title: "A.swift", facts: SendRules.facts(bundle: "com.apple.dt.Xcode", title: "A.swift", field: "textArea", seal: .submit))
    try check(ActionProjection.make(xcode).state == "draft" && xcode.captureProvenance?.unit?.send == "none", "Return in an editor is never a run")
    let pasted = row("v3-pasted", facts: SendRules.facts(bundle: "com.anthropic.claudefordesktop", field: "textArea", seal: .submit), pasted: true)
    try check(pasted.captureProvenance?.unit?.pasted == true && (try json(asked)).contains("pasted") == false, "pasted is stored only when true")
    try check(try json(asked).contains("\"send\":\"detected\"") && !(try json(asked)).contains(" sent"), "the stored facts are metadata words only")

    // Through the store: a v3 row's canonical action, as AI apps and writers read it.
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    var consent = try store.policy(); consent.captureText = true; consent.typedConsentVersion = 1; try store.updatePolicy(consent)
    try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore())); try store.setUpTypedVault(); try store.acceptSafeTyping()
    for e in [old, asked, idle] {
        // Public builds type in Notes and TextEdit only, so the stored rows carry Notes' bundle with the same facts.
        var s = e; s.id = "store-" + e.id; s.at = iso(Date().addingTimeInterval(-60)); s.typed = nil; s.text = "please make the intro shorter and clearer for new readers"
        s.app = "Notes"; s.bundle = "com.apple.Notes"
        try check(try store.ingest(s), "stored \(s.id)")
    }
    let stored = try ["store-v2-row", "store-v3-asked", "store-v3-idle"].map { try store.action($0) }
    if stored.map({ $0?.state }) != ["draft", "submitted", "draft"] { print("states", stored.map { $0?.state ?? "nil" }) }
    try check(stored.map { $0?.state } == ["draft", "submitted", "draft"], "the store projects draft, submitted, draft")
    let raw = try store.read("store-v3-asked")?.evidence.captureProvenance?.unit
    try check(raw?.surface == "ai" && raw?.send == "detected" && raw?.version == "typed-unit/v3", "the send facts are stored with the record")
    print("PASS summaries/v3 typed send facts: K3 revisions, submitted state, stored facts.")
}
