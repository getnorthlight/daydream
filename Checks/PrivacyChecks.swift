import Foundation
import MemoryCore

func runPrivacyChecks(home:URL,now:Date) throws {
    var policy=PrivacySettings()
    try check(!policy.captureText,"new policy defaults typed text OFF")
    func allowed(_ bundle:String="com.apple.TextEdit",_ role:String="AXTextArea",_ url:String="",_ secure:Bool=false) -> Bool {
        PreCapturePrivacy.nativeTypingAllowed(bundle:bundle,role:role,url:url,secure:secure,settings:policy)
    }
    try check(!allowed(),"typing OFF rejects before characters")
    policy.captureText=true
    try check(!allowed(),"legacy default-true policy is not typed-only consent")
    policy.typedConsentVersion=1
    try check(allowed(),"explicit native typing consent with known nonsecure focus")
    for bundle in ["com.google.Chrome","com.apple.Safari","unknown.browser","com.apple.Passwords","com.bitwarden.desktop"] {
        try check(!allowed(bundle),"unsupported/browser/password-manager text withheld: "+bundle)
    }
    for role in ["AXSecureTextField","AXWebArea","AXGroup",""] { try check(!allowed("com.apple.TextEdit",role),"unknown or secure focus withheld: "+role) }
    try check(!allowed("com.apple.TextEdit","AXTextArea","",true),"secure input overrides typing consent")
    for url in ["https://chase.com/","https://accounts.example.org/login","https://shop.example.org/checkout","https://x.example.org/%70assword","https://bank.example.org/","https://example.org/oauth","https://user:pass@example.org/","not a url"] {
        try check(PreCapturePrivacy.websiteDenied(url,settings:policy),"sensitive/unknown website metadata denied: "+url)
    }
    try check(!allowed("com.apple.TextEdit","AXTextArea","https://example.org/"),"embedded page typing withheld even if local classifier would allow URL")
    policy.blockedDomains=["example.org"]
    try check(PreCapturePrivacy.websiteDenied("https://sub.example.org/research",settings:policy),"user website exclusion overrides ordinary page")
    policy.blockedApps=["com.apple.TextEdit"]
    try check(!allowed(),"app exclusion overrides typed-text consent")
    // Chrome page history: every window's mode is read twice, and a window
    // that turns Incognito between the reads discards the page.
    var modeReads=0
    let changed=ChromePageProbe.read(userBlocked:[]) { request in
        switch request {
        case .windowIDs: return .ids(["w"])
        case .mode: modeReads += 1; return .text(modeReads == 1 ? "normal" : "incognito")
        case .activeTabID: return .text("t")
        case .tabTitle: return .text("Synthetic")
        case .tabURL: return .text("https://example.org")
        }
    }
    try check(changed == .skipped(.notNormal) && modeReads == 2,"page history: private transition during a Chrome read is rejected by the re-check of every mode")
    var burst=CaptureBurst()
    for reason in ["navigation","redirect","mixed-window","focus-race","delayed-metadata","private-window","app-excluded","typing-off"] {
        burst.append("synthetic unsaved draft",context:"page-a",safe:true)
        try check(burst.drain(context:"page-b",safe:false) == nil,"buffer withheld on "+reason)
        try check(burst.drain(context:"page-a",safe:true) == nil,"discarded burst never reappears after "+reason)
    }
    let store=try MemoryStore(home:home,writable:true)
    _ = try attachTestVault(store)
    policy=PrivacySettings(); policy.captureText=true
    try store.updatePolicy(policy,now:now)
    let e=Evidence(id:"privacy-fixture",at:iso(now),kind:"keyboard.text_input",app:"TextEdit",bundle:"com.apple.TextEdit",text:"Please compare two garden sensors",synthetic:true)
    try check(try store.ingest(e,now:now),"privacy fixture persisted with explicit consent")
    _=try store.writePending(now:now)
    policy.blockedApps=[e.bundle]; try store.updatePolicy(policy,now:now)
    try check(try store.writePending(now:now) == 0 && store.read(e.id,now:now) == nil,"excluded original never reaches summary writer or detail")
    try check(try store.legacyPage(includeText:true,now:now).events.isEmpty && store.context(now:now).sourceIDs.isEmpty,"excluded source absent from host reader and context")
    policy.blockedApps=[]; try store.updatePolicy(policy,now:now)
    try check(try store.read(e.id,now:now) != nil && store.hydrateTypedText(e.id,disclosure:.owner,now:now) == e.text,"unexclude restores retained source: exclusion is not deletion")
    policy.captureText=false; try store.updatePolicy(policy,now:now)
    try check(try store.read(e.id,now:now)?.evidence.text == "" && store.hydrateTypedText(e.id,disclosure:.owner,now:now) == nil,"typing OFF withholds retained text from reads")
    var bad=policy; bad.retentionDays=0
    var failed=false; do { try store.updatePolicy(bad,now:now) } catch { failed=true }
    try check(failed && (try store.policy()).retention == policy.retention,"failed save leaves committed policy intact")
    try store.delete(e.id); policy.captureText=true; try store.updatePolicy(policy,now:now)
    try check(try store.read(e.id,now:now) == nil && !store.ingest(e,now:now),"explicit deletion cannot be undone by unexclude or typing toggle")
}
