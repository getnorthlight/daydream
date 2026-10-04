import Foundation
import MemoryCore

func runInstallationChecks(home: URL, now: Date) throws {
    var accessed: [String] = []
    let empty = InstallationReview.legacy(at:home) { accessed.append($0); return false }
    // The private collector's launch agent names were removed from public builds (connect track): the probe now
    // looks only for the collector's socket.
    try check(InstallationReview.knownServices.isEmpty,"no private collector service names in public builds")
    try check(!empty.requiresMigration && accessed.count == 1,"legacy preflight checks only the one expected metadata path")
    try check(accessed.allSatisfy { !$0.contains("events.jsonl") && !$0.contains("config.json") },"preflight never opens history or configuration")
    let legacy = InstallationReview.legacy(at:home) { $0.hasSuffix("history.sock") || $0.hasSuffix(".plist") }
    try check(legacy.socketPresent && legacy.services.isEmpty,"synthetic legacy footprint identifies the collector socket and no launch agent")
    try check(InstallationReview.captureBlocker(legacy) != nil,"unverified legacy replacement blocks second recorder")
    try check(InstallationReview.captureBlocker(empty) == nil,"clean default paths have no migration interlock")
    try check(!InstallationReview.removableApp(bundle:home,userHome:home,bundleID:"com.getnorthlight.daydream"),"uninstall refuses broad or development targets")
    try check(!InstallationReview.removableApp(bundle:home.appendingPathComponent("Applications/Mac Mem.app"),userHome:home,bundleID:"other.app"),"uninstall refuses another app identity")
    try runUninstallRuleChecks(home:home)
    let store = try MemoryStore(home:home.appendingPathComponent("context"),writable:true)
    // Fabricated evidence using native schema, in an isolated test store only.
    let source = Evidence(id:"native-schema-fixture",at:iso(now),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Fabricated test note")
    _ = try store.ingest(source,now:now); _ = try store.writePending(now:now)
    try store.setCaptureState("recording",reason:"mock",now:now)
    try check(try store.context(now:now).sourceIDs == [source.id],"fresh native-schema context reaches automatic adapter input")
    let prepared = try store.disclosureRevision()
    try store.setCaptureState("paused",reason:"mock opt-out",now:now)
    try check(try prepared != store.disclosureRevision(),"pause invalidates prepared host evidence")
    try check(try store.context(now:now).sourceIDs.isEmpty,"paused native capture emits status only")
    try check(try store.read(source.id,now:now) != nil,"pause keeps separately authorized historical detail")
    try store.setCaptureState("recording",reason:"mock",now:now)
    try check(try store.context(now:now.addingTimeInterval(6)).sourceIDs.isEmpty,"expired heartbeat suppresses automatic evidence")
    let beforeDelete = try store.disclosureRevision()
    try store.delete(source.id)
    try check(try beforeDelete != store.disclosureRevision(),"deletion invalidates prepared host evidence")
    print("Installation checks use synthetic paths. No legacy service, installer or uninstall was executed.")
}

/// Settings › Setup › Uninstall: the planner's rules over an in-memory disk (no file is read or
/// written). scripts/uninstall-plan-checks.swift runs the same rules over scratch folders on disk.
func runUninstallRuleChecks(home: URL) throws {
    let apps = URL(fileURLWithPath:"/Applications")
    var disk: [String: UninstallEntry] = [:]
    var plists: [String: [String: Any]] = [:]
    var next: ino_t = 10
    func add(_ path: String, _ kind: UninstallEntry.Kind, owner: uid_t = 501) { next += 1; disk[path] = UninstallEntry(kind:kind,owner:owner,device:1,inode:next) }
    for part in ["/Applications", home.path] { var prefix = ""; for c in URL(fileURLWithPath:part).pathComponents where c != "/" { prefix += "/" + c; if disk[prefix] == nil { add(prefix,.directory) } } }
    add("/Applications/DayDream.app",.directory); plists["/Applications/DayDream.app"] = ["CFBundleIdentifier":DaydreamIdentity.bundleID]
    add(home.path + "/Applications",.directory)
    add(home.path + "/Applications/Daydream.app",.directory,owner:0); plists[home.path + "/Applications/Daydream.app"] = ["CFBundleIdentifier":DaydreamIdentity.legacyBundleID]
    add(home.path + "/Library",.directory); add(home.path + "/Library/Application Support",.directory)
    add(home.path + "/Library/Application Support/DayDream",.directory); add(home.path + "/Library/Application Support/Mac Mem",.symlink)
    let probe = UninstallProbe(entry:{ disk[$0] }, infoPlist:{ plists[$0.path] }, contents:{ _ in [] }, uid:501)
    let locations = UninstallLocations(home:home, systemApplications:apps)
    func plan(_ choice: UninstallChoice, _ requester: UninstallRequester) -> UninstallPlan? {
        if case .success(let plan) = UninstallPlanner.plan(choice,requester:requester,locations:locations,probe:probe) { return plan }; return nil
    }
    let running = UninstallRequester(bundleURL:apps.appendingPathComponent("DayDream.app"),bundleID:DaydreamIdentity.bundleID,environmentHome:nil)
    let everything = plan(.removeEverything,running)
    try check(everything?.items.first?.kind == .runningApp && everything?.items.contains { $0.kind == .history } == true,"uninstall plan: the app first, then the DayDream history")
    try check(everything?.skipped.map(\.url.lastPathComponent).sorted() == ["Daydream.app","Mac Mem"],"uninstall plan: another user's app copy and a linked Mac Mem folder are left in place")
    try check(plan(.keepHistory,running)?.items.contains { $0.kind == .history || $0.kind == .preferences } == false,"uninstall plan: Keep my history keeps history and settings")
    try check(plan(.keepHistory,UninstallRequester(bundleURL:home.appendingPathComponent("repo/.build/MacMem.app"),bundleID:DaydreamIdentity.bundleID,environmentHome:nil)) == nil,"uninstall refuses a development bundle")
    try check(plan(.keepHistory,UninstallRequester(bundleURL:running.bundleURL,bundleID:"com.example.other",environmentHome:nil)) == nil,"uninstall refuses another app")
    try check(plan(.keepHistory,UninstallRequester(bundleURL:running.bundleURL,bundleID:DaydreamIdentity.bundleID,environmentHome:"/tmp/x")) == nil,"uninstall refuses a custom history folder")
    try check(everything?.items.allSatisfy { locations.isAllowed($0.url) } == true,"uninstall plan stays on its list")
    let plainHome = URL(fileURLWithPath:"/Users/daydream-check-nobody")
    try check(InstallationReview.removableApp(bundle:plainHome.appendingPathComponent("Applications/Daydream.app"),userHome:plainHome,bundleID:DaydreamIdentity.bundleID),"uninstall accepts the older Finder name")
}
