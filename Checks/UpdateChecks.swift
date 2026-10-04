import Foundation
import MemoryCore

func runUpdateChecks(home:URL) throws {
    // CHANGED (sat/updates, owner decision 7): Sparkle updates ship. The old compile-time
    // interlock is replaced by: no Info.plist keys => no Sparkle at all (dev builds), a signed
    // GitHub Releases feed, verify-before-extraction, an increasing build, no update while an
    // older install is half replaced; the quit (never the install) pauses and saves typed text.
    try check((try? UpdateConfiguration(info:[:])) == nil,"no update keys (every development build) means no updater")
    var calendar=Calendar(identifier:.gregorian); calendar.timeZone=TimeZone(identifier:"America/New_York")!
    let nightly=NightlyUpdatePolicy(calendar:calendar)
    func at(_ value:String)->Date { ISO8601DateFormatter().date(from:value)! }
    let three=at("2026-09-12T07:00:00Z"), daytime=at("2026-09-11T17:00:00Z")
    try check(nightly.mayCheck(now:three,lastNight:nil,enabled:true,configured:true,launchOrWake:false),"nightly checks at local 03:00")
    try check(!nightly.mayCheck(now:three,lastNight:nightly.token(three),enabled:true,configured:true,launchOrWake:true),"nightly once-per-night across wake")
    try check(nightly.mayCheck(now:daytime,lastNight:nil,enabled:true,configured:true,launchOrWake:true),"missed night checks on wake")
    try check(!nightly.mayInstall(now:daytime,stagedAt:daytime,lastAttempt:nil,enabled:true,configured:true,criticalWrites:false,prepared:true),"daytime staging never restarts")
    try check(nightly.mayInstall(now:three,stagedAt:daytime,lastAttempt:nil,enabled:true,configured:true,criticalWrites:false,prepared:true),"staged update waits for next overnight window")
    for blocked in [true,false] {
        try check(!nightly.mayInstall(now:three,stagedAt:daytime,lastAttempt:nil,enabled:true,configured:true,criticalWrites:blocked,prepared:blocked),"critical writes or missing flush prevent restart")
    }
    try check(!nightly.mayInstall(now:three,stagedAt:daytime,lastAttempt:nightly.token(three),enabled:true,configured:true,criticalWrites:false,prepared:true),"failed attempt cannot loop same night")
    try check(!nightly.mayCheck(now:three,lastNight:nil,enabled:true,configured:false,launchOrWake:false),"missing signed configuration blocks schedule")
    try check(!nightly.mayCheck(now:three,lastNight:nil,enabled:false,configured:true,launchOrWake:false),"user disable blocks schedule")
    for value in ["2026-03-08T08:00:00Z","2026-11-01T08:00:00Z"] {
        let date=at(value)
        try check(calendar.component(.hour,from:nightly.night(date)!) == 3,"DST night uses local calendar hour")
        try check(nightly.nextNight(after:date)! > date,"DST next night strictly later")
    }
    // RFC 8032 test vector 1: public key/signature only. No private key or key generation.
    func hex(_ text:String)->Data { Data(stride(from:0,to:text.count,by:2).map { offset in UInt8(String(text.dropFirst(offset).prefix(2)),radix:16)! }) }
    let key=hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
    let sig=hex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
    try check(UpdateConfiguration.verifies(data:Data(),signature:sig,publicKey:key),"known public Ed25519 signature verifies")
    try check(!UpdateConfiguration.verifies(data:Data([1]),signature:sig,publicKey:key),"tampered bytes reject")
    var bad=sig; bad[0] ^= 1
    try check(!UpdateConfiguration.verifies(data:Data(),signature:bad,publicKey:key),"tampered signature rejects")
    try check(!UpdateConfiguration.verifies(data:Data(),signature:sig,publicKey:Data(repeating:0,count:32)),"wrong signing key rejects")
    try check(UpdateConfiguration.newer("2",than:"1"),"increasing update build accepted")
    for value in ["0","1","1.2","garbage","-1"] { try check(!UpdateConfiguration.newer(value,than:"1"),"downgrade/equal/invalid build rejects: " + value) }
    // updates-1003: the feed is appcast.xml on the website (DaydreamUpdateSite); archives are GitHub release assets of
    // owner/repository or .zip files on the site or a subdomain. Quiet updates: SUAutomaticallyUpdate and
    // SUAllowsAutomaticUpdates true, or no updater at all.
    var info:[String:Any]=["MacMemGitHubOwner":"fixture-team","MacMemGitHubRepository":"mac-mem","DaydreamUpdateSite":"fixture-site.app","SUFeedURL":"https://fixture-site.app/appcast.xml","SUPublicEDKey":key.base64EncodedString(),"SUVerifyUpdateBeforeExtraction":true,"SURequireSignedFeed":true,"SUAllowsAutomaticUpdates":true,"SUAutomaticallyUpdate":true]
    if UpdateConfiguration.compiledOff {
        // A QA or Live Test binary: never an updater, whatever its Info.plist says.
        try check((try? UpdateConfiguration(info:info)) == nil,"QA/Live Test binary refuses even a complete update configuration")
        return
    }
    let config=try UpdateConfiguration(info:info)
    try check(config.permitsArchive(URL(string:"https://github.com/fixture-team/mac-mem/releases/download/v0.2/MacMem-2.zip")),"configured GitHub archive accepted without network")
    try check(config.permitsArchive(URL(string:"https://fixture-site.app/releases/v0.2/DayDream-0.2.zip")),"archive on the site accepted")
    try check(config.permitsArchive(URL(string:"https://downloads.fixture-site.app/v0.2/DayDream-0.2.zip")),"archive on a subdomain of the site accepted")
    for value in ["http://github.com/fixture-team/mac-mem/releases/download/v2/MacMem.zip","https://github.com/another/mac-mem/releases/download/v2/MacMem.zip","https://github.com/fixture-team/mac-mem/releases/download/../../MacMem.zip","https://github.com/fixture-team/mac-mem/releases/download/v2/MacMem.zip?token=x",
                  "https://evilfixture-site.app/DayDream.zip","https://fixture-site.app.evil.example/DayDream.zip","http://fixture-site.app/DayDream.zip","https://fixture-site.app:8443/DayDream.zip",
                  "https://user@fixture-site.app/DayDream.zip","https://fixture-site.app/a/../DayDream.zip","https://fixture-site.app/DayDream.dmg","https://fixture-site.app//DayDream.zip"] {
        try check(!config.permitsArchive(URL(string:value)),"foreign/insecure archive rejected: " + value)
    }
    for field in Array(info.keys) { var missing=info; missing.removeValue(forKey:field); try check((try? UpdateConfiguration(info:missing)) == nil,"missing config refuses: " + field) }
    try check(config.feed.absoluteString == UpdateConfiguration.feedURL(site:"fixture-site.app") && config.feed.absoluteString == "https://fixture-site.app/appcast.xml","feed is the website's appcast.xml")
    for feed in ["https://fixture-team.github.io/mac-mem/appcast.xml","http://fixture-site.app/appcast.xml","https://github.com/fixture-team/mac-mem/releases/latest/download/appcast.xml",
                 "https://other-site.app/appcast.xml","https://fixture-site.app/appcast.xml?x=1","https://fixture-site.app/feed/appcast.xml","https://www.fixture-site.app/appcast.xml"] {
        var other=info; other["SUFeedURL"]=feed
        try check((try? UpdateConfiguration(info:other)) == nil,"feed other than the website's appcast refuses: " + feed)
    }
    for site in ["fixture-site","example.com","localhost","FIXTURE.APP","fixture-team.github.io","your-site.app"] {
        var other=info; other["DaydreamUpdateSite"]=site; other["SUFeedURL"]="https://\(site)/appcast.xml"
        try check((try? UpdateConfiguration(info:other)) == nil,"placeholder or foreign update site refuses: " + site)
    }
    for flag in ["SUVerifyUpdateBeforeExtraction","SURequireSignedFeed"] {
        var off=info; off[flag]=false
        try check((try? UpdateConfiguration(info:off)) == nil,"update config refuses \(flag)=false")
    }
    // updates-1003 (owner, 10/03): updates download quietly and install at the quit or at Restart to Update. A copy
    // that would make Sparkle ask in its own window (automatic downloads not allowed, or off) runs no updater at all.
    for flag in ["SUAllowsAutomaticUpdates","SUAutomaticallyUpdate"] {
        var asks=info; asks[flag]=false
        try check((try? UpdateConfiguration(info:asks)) == nil,"update config refuses \(flag)=false")
    }
    var weak=info; weak["SUPublicEDKey"]=Data(repeating:7,count:32).base64EncodedString()
    try check((try? UpdateConfiguration(info:weak)) == nil,"degenerate public key refuses")
    try check(config.permitsArchive(URL(string:"https://github.com/fixture-team/mac-mem/releases/download/v0.1.1/DayDream-0.1.1.zip")),"release asset archive accepted")
    try check(!config.permitsArchive(URL(string:"https://github.com/fixture-team/mac-mem/releases/download/v0.1.1/DayDream-0.1.1.dmg")),"only .zip update archives")
    for text in UpdateText.all + [UpdateText.available("0.1.1 Beta"),UpdateText.versionTitle("0.1.1 Beta"),UpdateText.ready("0.1.1 Beta")] {
        try check(!text.isEmpty && text.count < 200,"update text is short: " + text)
        try check(text.components(separatedBy:"DayDream").count == text.lowercased().components(separatedBy:"daydream").count,"DayDream spelled exactly: " + text)
        for word in ["Mac Mem","Sparkle","appcast","EdDSA","feed"] { try check(!text.contains(word),"update text avoids jargon '\(word)': " + text) }
    }
    // declutter: the install note ("Off at first…") is gone; the switch itself shows its off state.
    try check(UpdateText.sourceNote == "A check sends DayDream's website your IP address and app version.","the update check's network fact stays")
    try check(UpdateText.switchTitle == "Update automatically","one switch: checking and quiet downloading")
    // A waiting update: one action, one status line, never shown by itself.
    let ready=UpdateWaiting.restart(version:"0.1.5 Beta"), review=UpdateWaiting.review(version:"0.1.5 Beta")
    try check(ready.title == "Restart to Update" && ready.statusLine == "DayDream 0.1.5 Beta is ready.","a downloaded update: Restart to Update")
    try check(review.title == "Update DayDream…" && review.statusLine == UpdateText.available("0.1.5 Beta"),"an update Sparkle can't install by itself: Update DayDream…")
    // sat5: a failed check is a short, plain status, never Sparkle's own text.
    let sparkle="SUSparkleErrorDomain",now0=Date(timeIntervalSince1970:1_790_000_000)
    // G53 (golden test 5): an update page that was reached but isn't a readable list of versions (a copy whose page
    // isn't published yet: GitHub answers "not found") is not "Couldn't reach the update server".
    for code in [1000,1002,1004] {
        try check(UpdateText.failure(domain:sparkle,code:code,underlyingDomain:nil) == UpdateText.checkFailed,"unreadable update page \(code): couldn't check")
        try check(UpdateText.failure(domain:sparkle,code:code,underlyingDomain:sparkle) == UpdateText.checkFailed,"unreadable update page \(code) after a download error: couldn't check")
    }
    try check(UpdateText.failure(domain:sparkle,code:1002,underlyingDomain:NSURLErrorDomain) == "Couldn't reach the update server. Try again later.","appcast not reached (offline): server unreachable")
    try check(UpdateText.failure(domain:sparkle,code:2001,underlyingDomain:nil) == UpdateText.unreachable,"download failure: server unreachable")
    try check(UpdateText.failure(domain:"x",code:1,underlyingDomain:NSURLErrorDomain) == UpdateText.unreachable,"network failure: server unreachable")
    try check(UpdateText.failure(domain:sparkle,code:3001,underlyingDomain:nil) == UpdateText.installFailed,"signature failure: couldn't install")
    try check(UpdateText.failure(domain:sparkle,code:1003,underlyingDomain:nil) == UpdateText.moveToApplications,"disk image: move to Applications")
    try check(UpdateText.failure(domain:"MemError",code:0,underlyingDomain:nil) == UpdateText.checkFailed,"other failure: couldn't check")
    try check(UpdateText.lastChecked(nil,now:now0) == nil && UpdateText.lastChecked(now0,now:now0) == "Checked just now.","last check line")
    // G53, G76 (golden test 5): the status line after a check or install stopped. Check Now is answered whatever the
    // answer; a scheduled check that couldn't read or reach the update page leaves the line alone (nil), so a copy
    // whose page isn't published yet never shows an error for good; a cancelled install is no failure at all.
    let offline=NSURLErrorDomain
    try check(UpdateText.failureLine(asked:false,domain:sparkle,code:1002,underlyingDomain:sparkle) == nil,"scheduled check, page not published: nothing shown")
    try check(UpdateText.failureLine(asked:false,domain:sparkle,code:1002,underlyingDomain:offline) == nil,"scheduled check, offline: nothing shown")
    try check(UpdateText.failureLine(asked:false,domain:"MemError",code:0,underlyingDomain:nil) == nil,"scheduled check, other failure: nothing shown")
    try check(UpdateText.failureLine(asked:true,domain:sparkle,code:1002,underlyingDomain:sparkle) == UpdateText.checkFailed,"Check Now, page not published: couldn't check")
    try check(UpdateText.failureLine(asked:true,domain:sparkle,code:1002,underlyingDomain:offline) == UpdateText.unreachable,"Check Now, offline: server unreachable")
    for asked in [false,true] {
        for code in [4007,4008] { try check(UpdateText.failureLine(asked:asked,domain:sparkle,code:code,underlyingDomain:nil) == nil,"cancelled install \(code) is no failure") }
        try check(UpdateText.failureLine(asked:asked,domain:sparkle,code:3001,underlyingDomain:nil) == UpdateText.installFailed,"an install that failed says so")
        try check(UpdateText.failureLine(asked:asked,domain:sparkle,code:1003,underlyingDomain:nil) == UpdateText.moveToApplications,"move to Applications says so")
    }
    // Resume after an update relaunch: a recent marker, read once.
    var stored:[String:Any]?
    func consume(_ at:Date)->Bool { UpdateResume.consume(read:{ stored },remove:{ stored=nil },now:at) }
    try check(!consume(now0),"no marker: recording stays off")
    stored=UpdateResume.marker(build:"41",at:now0)
    try check(consume(now0.addingTimeInterval(20)),"a fresh marker resumes recording")
    try check(!consume(now0.addingTimeInterval(20)),"the marker is used once")
    stored=UpdateResume.marker(build:"41",at:now0)
    try check(!consume(now0.addingTimeInterval(UpdateResume.window+1)) && stored == nil,"a stale marker never starts recording and is removed")
    try check(!UpdateResume.shouldResume(marker:["at":now0.timeIntervalSince1970],now:now0),"a marker without a build is ignored")
    info["MacMemGitHubOwner"]="your-owner"
    try check((try? UpdateConfiguration(info:info)) == nil,"placeholder owner rejects")
    for phase in ["awaiting_explicit_start","rollback_required","restoring_legacy","stopping_legacy"] { try check(!UpdateConfiguration.replacementAllowsUpdate(phase:phase,busy:false),"unfinished replacement blocks update: " + phase) }
    try check(UpdateConfiguration.replacementAllowsUpdate(phase:"committed",busy:false),"completed replacement allows update")
    try check(!UpdateConfiguration.replacementAllowsUpdate(phase:nil,busy:true),"busy replacement blocks update")
    let resources=home.appendingPathComponent("Mac Mem.app/Contents/Resources")
    try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
    let manifest=resources.appendingPathComponent("Companions.json")
    try Data("{\"schema\":1,\"build\":\"1\"}".utf8).write(to:manifest)
    let identity=try CompanionIdentity(executable:home.appendingPathComponent("Mac Mem.app/Contents/MacOS/mac-mem"))
    try identity.validate()
    try Data("{\"schema\":1,\"build\":\"2\"}".utf8).write(to:manifest)
    var rejected=false; do { try identity.validate() } catch { rejected=true }
    try check(rejected,"running companion rejects replaced bundle manifest")
    let store=try MemoryStore(home:home.appendingPathComponent("memory"),writable:true)
    let now=Date()
    let capture=try CaptureSession(store:store)
    try capture.start(permitted:true,now:now)
    for evidence in SyntheticActivity.records(now:now) { _ = try store.ingest(evidence,now:now) }
    let savedPolicy=try store.policy()
    try capture.pause("Paused for update",now:now)
    _ = try CaptureSession(store:store)
    try check(try store.captureStatus()["state"] == "off","restart after update pause remains OFF")
    try check(try store.policy().revision == savedPolicy.revision,"update restart preserves privacy policy")
    try check(try store.read("demo-request",now:now) != nil,"update restart preserves original memory")
}
