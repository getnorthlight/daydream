import Foundation
import AppKit
import Darwin
@main enum NormalMainChromeMetadataChecks {
    static var passes=0
    static func check(_ value:Bool,_ message:String) {precondition(value,message);passes+=1;print("PASS \(message)")}
    static let info:[String:Any] = ["DaydreamQAHarness":true,"MacMemOwnerTyping":true,"CFBundleIdentifier":"com.getnorthlight.daydream"]
    static func fixture() throws -> (URL,[String]) {
        let id=UUID().uuidString.lowercased()
        let root=URL(fileURLWithPath:"/private/tmp/daydream-normal-main-chrome-"+id)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let file=root.appendingPathComponent("request.json")
        try JSONSerialization.data(withJSONObject:["schema":"daydream-qa-normal-main-chrome-metadata-v1","run_id":id,"mode":"passive-only"]).write(to:file)
        chmod(file.path,0o600)
        let marker=root.appendingPathComponent("TRIAL-ONLY");try Data("synthetic-only\n".utf8).write(to:marker);chmod(marker.path,0o600)
        return (root,["owned-fixture","--isolated-interactive-trial",ChromeNormalMainProbeAdmission.flag,file.path])
    }
    @MainActor final class Fake {
        var pid:pid_t?=41;var copies=1;var enabled=true;var verified=true;var answer:Int32 = -1743;var appKitRunning=true
        var identity:String?="launch-a";var statusCalls=0;var verifyCalls=0;var background:[()->Void]=[];var main:[()->Void]=[];var deadlines:[()->Void]=[]
        var immediate=true;var snapshots:[ChromeNormalMainProbeSnapshot]=[];var duringStatus:(()->Void)?;var duringVerify:(()->Void)?;var afterSnapshot:(()->Void)?
        func environment()->ChromeNormalMainProbeEnvironment {
            ChromeNormalMainProbeEnvironment(running:{self.pid},copies:{self.copies},verify:{_ in self.verifyCalls+=1;self.duringVerify?();return self.verified},
                releaseEnabled:{self.enabled},identity:{_ in self.identity},statusSource:"injected-test",status:{_ in self.statusCalls+=1;self.duringStatus?();return self.answer},
                background:{if self.immediate {$0()} else {self.background.append($0)}},main:{if self.immediate {$0()} else {self.main.append($0)}},
                mainSnapshot:{let stable=$0();self.afterSnapshot?();return stable},deadline:{self.deadlines.append($0)},caller:{(777,501,self.appKitRunning)})
        }
        func session(_ r:ChromeNormalMainProbeAdmission.Request)->ChromeNormalMainProbeSession {
            ChromeNormalMainProbeSession(request:r,environment:environment(),persist:{self.snapshots.append($0)})
        }
    }
    @MainActor final class StartupFake {
        var running=true;var starts=0;var stops=0;var phases:[String]=[]
        var next:[()->Void]=[];var deadlines:[()->Void]=[];var refused:String?;var duringRecord:((String)->Void)?
        func lifecycle()->ChromeNormalMainProbeLifecycle {
            ChromeNormalMainProbeLifecycle(running:{self.running},nextMain:{self.next.append($0)},deadline:{self.deadlines.append($0)},
                record:{self.phases.append($0);self.duringRecord?($0);if self.refused==$0 {throw ChromeNormalMainProbeAdmission.Refused.isolation}},
                start:{self.starts+=1},stop:{self.stops+=1})
        }
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let (root,args)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        check(ChromeNormalMainProbeAdmission.shape(args,info:info),"exact paired flags and QA owner identity admitted")
        for invalid in [Array(args.dropLast()),[args[0],args[2],args[3]],args+["--development-trial"],args+["--capture-fixture-trial"],args+["--recording-trial"],args+["--signed-writer-trial"],[args[0],args[2],args[1],args[3]],args+[args[2]]] {
            check(!ChromeNormalMainProbeAdmission.shape(invalid,info:info),"conflicting/missing/reordered/duplicate args refused")
        }
        for key in ["DaydreamQAHarness","MacMemOwnerTyping"] {var bad=info;bad[key]=false;check(!ChromeNormalMainProbeAdmission.shape(args,info:bad),"nonQA/nonowner refused")}
        var badID=info;badID["CFBundleIdentifier"]="com.example.other";check(!ChromeNormalMainProbeAdmission.shape(args,info:badID),"different app identity refused")
        for key in ["DaydreamDevelopmentTrial","DaydreamRecordingTrial","DaydreamFunctionalTrial","DaydreamPreview","DaydreamPreviewSample"] {
            var conflict=info;conflict[key]=false;check(!ChromeNormalMainProbeAdmission.shape(args,info:conflict),"trial plist presence refused even false")
        }
        check(CaptureFixtureLaunch.route(arguments:args,ownerCompiled:true,info:info) == .application,"paired QA route reaches real application entry")
        check(CaptureFixtureLaunch.route(arguments:args,ownerCompiled:false,info:info) == .refused,"route cannot bypass ownerCompiled admission")
        check(CaptureFixtureLaunch.route(arguments:[args[0],args[2],args[3]],ownerCompiled:true,info:info) == .refused,"unpaired probe refused before App construction")
        check(CaptureFixtureLaunch.route(arguments:args+["--capture-fixture-trial"],ownerCompiled:true,info:info) == .refused,"probe and intercepted capture routes cannot mix")
        check(CaptureFixtureLaunch.route(arguments:["fixture"],ownerCompiled:true,info:info) == .application,"ordinary application routing preserved")
        check(CaptureFixtureLaunch.route(arguments:["fixture","--capture-fixture-trial"],ownerCompiled:true,info:info) == .fixture,"existing intercepted QA fixture route preserved")
        check(CaptureFixtureLaunch.route(arguments:["fixture","--capture-fixture-trial"],ownerCompiled:false,info:info) == .refused,"existing fixture nonowner refusal preserved")
        let request=try ChromeNormalMainProbeAdmission.validate(args,info:info)
        check(request.root.path==root.path && request.runID==String(root.lastPathComponent.dropFirst("daydream-normal-main-chrome-".count)),"protected public request admitted with exact run identity")
        func refused(_ name:String) {check((try? ChromeNormalMainProbeAdmission.validate(args,info:info))==nil,name)}
        let file=root.appendingPathComponent("request.json");let saved=try Data(contentsOf:file)
        chmod(root.path,0o755);refused("unprotected directory refused");chmod(root.path,0o700)
        chmod(file.path,0o644);refused("unprotected config refused");chmod(file.path,0o600)
        try Data(repeating:65,count:1025).write(to:file);refused("oversized config refused before bounded read");try saved.write(to:file)
        let hard=root.appendingPathComponent("hard");try FileManager.default.linkItem(at:file,to:hard);refused("multiply linked config refused");try FileManager.default.removeItem(at:hard)
        let moved=root.appendingPathComponent("original");try FileManager.default.moveItem(at:file,to:moved);try FileManager.default.createSymbolicLink(at:file,withDestinationURL:moved);refused("symlink config refused");try FileManager.default.removeItem(at:file);try FileManager.default.moveItem(at:moved,to:file)
        let marker=root.appendingPathComponent("TRIAL-ONLY");try Data("wrong\n".utf8).write(to:marker);refused("non-synthetic marker refused");try Data("synthetic-only\n".utf8).write(to:marker)
        let altered=try JSONSerialization.data(withJSONObject:["schema":"daydream-qa-normal-main-chrome-metadata-v1","run_id":request.runID,"mode":"ask"]);try altered.write(to:file);refused("request mode cannot be enabled");try saved.write(to:file)
        try JSONSerialization.data(withJSONObject:["schema":"daydream-qa-normal-main-chrome-metadata-v1","run_id":request.runID,"mode":"passive-only","secret":"fictional" ]).write(to:file);refused("unknown config fields refused");try saved.write(to:file)
        let dangling=root.appendingPathComponent("result.json");try FileManager.default.createSymbolicLink(at:dangling,withDestinationURL:root.appendingPathComponent("absent"));refused("dangling output symlink refused");try FileManager.default.removeItem(at:dangling)
        let startup=StartupFake();let boot=startup.lifecycle();boot.didFinishLaunching()
        check(startup.starts==1 && startup.phases==["did-finish-launching","appkit-ready"],"delegate starts passive read without any scene/view/task")
        boot.didFinishLaunching();boot.viewTask();startup.deadlines[0]()
        check(startup.starts==1 && startup.stops==0,"delegate/view repetition and late readiness timeout cannot repeat read")
        let earlyTask=StartupFake();let earlyBoot=earlyTask.lifecycle();earlyBoot.viewTask()
        check(earlyTask.starts==0,"view task before genuine didFinish cannot admit permission read")
        earlyBoot.didFinishLaunching();check(earlyTask.starts==1,"genuine didFinish admits the one shared read after early task")
        let notRunning=StartupFake();notRunning.running=false;let delayedBoot=notRunning.lifecycle();delayedBoot.didFinishLaunching()
        check(notRunning.starts==0 && notRunning.next.count==1,"didFinish while AppKit false queues metadata readiness only")
        notRunning.running=true;notRunning.next[0]();delayedBoot.viewTask()
        check(notRunning.starts==1,"deferred main turn reads once only after observed AppKit running")
        let timeout=StartupFake();timeout.running=false;let timeoutBoot=timeout.lifecycle();timeoutBoot.didFinishLaunching();timeout.deadlines[0]();timeout.running=true;timeout.next[0]();timeoutBoot.viewTask()
        check(timeout.starts==0 && timeout.stops==1 && timeout.phases.contains("appkit-readiness-deadline"),"readiness TTL blocks late delegate task and queued main read")
        let shutdown=StartupFake();shutdown.running=false;let shutdownBoot=shutdown.lifecycle();shutdownBoot.didFinishLaunching();shutdownBoot.willTerminate();shutdown.running=true;shutdown.next[0]();shutdown.deadlines[0]()
        check(shutdown.starts==0 && shutdown.stops==1,"termination invalidates pending readiness and late deadlines")
        let closedView=StartupFake();let closedBoot=closedView.lifecycle();closedBoot.viewDisappeared();closedBoot.didFinishLaunching()
        check(closedView.starts==0 && closedView.stops==1,"view closure before launch fences subsequent delegate callback")
        let refusedStart=StartupFake();refusedStart.refused="appkit-ready";refusedStart.lifecycle().didFinishLaunching()
        check(refusedStart.starts==0 && refusedStart.stops==1,"diagnostic failure before read fails closed")
        let duringWrite=StartupFake();duringWrite.duringRecord={if $0=="appkit-ready" {duringWrite.running=false}};duringWrite.lifecycle().didFinishLaunching()
        check(duringWrite.starts==0 && duringWrite.stops==1,"AppKit stopping during readiness write is fenced before start")
        let diagnostics=ChromeNormalMainProbeDiagnostics(request:request)
        try diagnostics.record("main-entered",appKitRunning:false);try diagnostics.record("main-entered",appKitRunning:true)
        let entry=root.appendingPathComponent("phase-main-entered.json");let entryBytes=try Data(contentsOf:entry)
        let entryRow=try JSONSerialization.jsonObject(with:entryBytes) as! [String:Any]
        check(Set(entryRow.keys)==Set(["schema","runID","callerPID","callerEUID","sequence","phase","appKitRunning","acceptedArgumentCount","requestedPermission"]),"startup metadata fields closed and exclude content/argv/path/OS status")
        check(entryRow["appKitRunning"] as? Bool == false && entryRow["acceptedArgumentCount"] as? Int == 4 && entryRow["sequence"] as? Int == 1 && entryBytes.count<=1024,"early-main metadata preserves false AppKit truth and finite accepted shape")
        check(ChromeNormalMainProbeAdmission.owned(entry,directory:false,mode:0o600),"startup metadata owned0600")
        check((try? diagnostics.record("browser-title",appKitRunning:false))==nil && !FileManager.default.fileExists(atPath:root.appendingPathComponent("phase-browser-title.json").path),"unrecognized phase cannot become arbitrary filename or content")
        let replayDiagnostics=ChromeNormalMainProbeDiagnostics(request:request)
        let replayRefused=(try? replayDiagnostics.record("main-entered",appKitRunning:false))==nil
        let replayBytes=try Data(contentsOf:entry)
        check(replayRefused && replayBytes==entryBytes,"new recorder cannot overwrite/replay existing phase receipt")
        let phaseLink=root.appendingPathComponent("phase-scene-created.json");try FileManager.default.createSymbolicLink(at:phaseLink,withDestinationURL:root.appendingPathComponent("absent-phase"))
        check((try? diagnostics.record("scene-created",appKitRunning:false))==nil,"phase dangling symlink refused without following target")
        try FileManager.default.removeItem(at:phaseLink)
        let f=Fake();let session=f.session(request);session.readOnce();session.readOnce()
        check(f.statusCalls==1 && f.verifyCalls==1 && f.snapshots.count==1,"passive query executes once after verification")
        check(session.status == -1743 && f.snapshots[0].permissionStatusSource=="injected-test" && !f.snapshots[0].requestedPermission,"injected denial retains origin; no request claim")
        let appkitOff=Fake();appkitOff.appKitRunning=false;appkitOff.session(request).readOnce()
        check(appkitOff.statusCalls==0 && appkitOff.verifyCalls==0 && appkitOff.snapshots[0].permissionStatus==nil && appkitOff.snapshots[0].phase=="appkit-not-running","session independently refuses early AppKit-false permission read")
        let appkitVerification=Fake();appkitVerification.duringVerify={appkitVerification.appKitRunning=false};appkitVerification.session(request).readOnce()
        check(appkitVerification.statusCalls==0 && appkitVerification.snapshots[0].permissionStatus==nil,"AppKit stops during signature verification: no permission API")
        let appkitDelivery=Fake();appkitDelivery.immediate=false;let appkitDeliverySession=appkitDelivery.session(request);appkitDeliverySession.readOnce();appkitDelivery.background[0]();appkitDelivery.appKitRunning=false;appkitDelivery.main[0]()
        check(appkitDelivery.statusCalls==1 && appkitDelivery.snapshots[0].permissionStatus==nil && !appkitDelivery.snapshots[0].signatureVerified,"AppKit stops before delivery: in-flight status discarded")
        let badDiagnostic=Fake();let noRead=ChromeNormalMainProbeSession(request:request,environment:badDiagnostic.environment(),persist:{badDiagnostic.snapshots.append($0)},diagnostic:{_ in throw ChromeNormalMainProbeAdmission.Refused.isolation});noRead.readOnce()
        check(badDiagnostic.statusCalls==0 && badDiagnostic.verifyCalls==0 && noRead.phase=="diagnostic-write-refused","failed read-start metadata never enters verification or API")
        let off=Fake();off.enabled=false;let offSession=off.session(request);offSession.readOnce()
        check(off.statusCalls==0 && off.verifyCalls==0 && off.snapshots[0].permissionStatus==nil && off.snapshots[0].phase=="release-disabled","release-off never becomes an OS denial")
        let none=Fake();none.pid=nil;none.session(request).readOnce();check(none.statusCalls==0 && none.snapshots[0].phase=="chrome-not-running","missing target never queried")
        let multiple=Fake();multiple.copies=2;multiple.session(request).readOnce();check(multiple.statusCalls==0 && multiple.verifyCalls==0,"multiple targets refused before verification")
        let invalid=Fake();invalid.verified=false;invalid.session(request).readOnce();check(invalid.statusCalls==0 && invalid.snapshots[0].phase=="unverified-target","unverified target never queried")
        let missingID=Fake();missingID.identity=nil;missingID.session(request).readOnce();check(missingID.statusCalls==0 && missingID.snapshots[0].phase=="target-identity-unavailable","missing launch identity refused")
        let changedVerification=Fake();changedVerification.duringVerify={changedVerification.identity="launch-b"};changedVerification.session(request).readOnce();check(changedVerification.statusCalls==0 && changedVerification.snapshots[0].permissionStatus==nil && changedVerification.snapshots[0].phase=="target-changed","launch change during signature verification never enters permission API")
        let disabledVerification=Fake();disabledVerification.duringVerify={disabledVerification.enabled=false};disabledVerification.session(request).readOnce();check(disabledVerification.statusCalls==0 && disabledVerification.snapshots[0].permissionStatus==nil,"release disabled during signature verification never enters permission API")
        let selectedVerification=Fake();selectedVerification.duringVerify={selectedVerification.pid=42};selectedVerification.session(request).readOnce();check(selectedVerification.statusCalls==0 && selectedVerification.snapshots[0].permissionStatus==nil,"selected PID change during signature verification never enters permission API")
        let copiesVerification=Fake();copiesVerification.duringVerify={copiesVerification.copies=2};copiesVerification.session(request).readOnce();check(copiesVerification.statusCalls==0 && copiesVerification.snapshots[0].permissionStatus==nil,"second copy during signature verification never enters permission API")
        let transient=Fake();transient.duringVerify={transient.copies=2};transient.afterSnapshot={transient.copies=1};transient.session(request).readOnce();check(transient.statusCalls==0 && !transient.snapshots[0].signatureVerified && transient.snapshots[0].permissionStatus==nil && transient.snapshots[0].phase=="target-changed","restored selection cannot rehabilitate a rejected pre-query fence")
        let changed=Fake();changed.duringStatus={changed.identity="launch-b"};changed.session(request).readOnce();check(changed.snapshots[0].permissionStatus==nil && !changed.snapshots[0].signatureVerified && changed.snapshots[0].phase=="target-changed","changed launch discards returned status")
        let before=Fake();before.immediate=false;let beforeSession=before.session(request);beforeSession.readOnce();before.identity="launch-b";before.background[0]();before.main[0]();check(before.statusCalls==0 && before.snapshots[0].phase=="target-changed","change before queued query never enters permission API")
        let callback=Fake();callback.immediate=false;let callbackSession=callback.session(request);callbackSession.readOnce();callback.background[0]();callback.pid=42;callback.main[0]();check(callback.snapshots[0].permissionStatus==nil && !callback.snapshots[0].signatureVerified,"selected target change before delivery discards result")
        let copies=Fake();copies.immediate=false;let copiesSession=copies.session(request);copiesSession.readOnce();copies.background[0]();copies.copies=2;copies.main[0]();check(copies.snapshots[0].permissionStatus==nil,"second copy before delivery discards result")
        let late=Fake();late.immediate=false;let lateSession=late.session(request);lateSession.readOnce();late.deadlines[0]();late.background[0]();late.main[0]();check(late.statusCalls==0 && late.snapshots.count==1 && late.snapshots[0].phase=="deadline" && late.snapshots[0].permissionStatusSource=="deadline-in-flight-unknown","deadline fences late result without claiming API never entered")
        let closed=Fake();closed.immediate=false;let closedSession=closed.session(request);closedSession.readOnce();closedSession.stop();closed.background[0]();closed.main[0]();check(closed.statusCalls==0 && closed.snapshots.isEmpty && closedSession.phase=="closed","closing probe fences queued result")
        let disk=Fake();let real=ChromeNormalMainProbeSession(request:request,environment:disk.environment());real.readOnce()
        check(real.phase=="complete" && FileManager.default.fileExists(atPath:request.result.path),"only public metadata receipt written to owned dirfd")
        let diskRow=try JSONDecoder().decode(ChromeNormalMainProbeSnapshot.self,from:Data(contentsOf:request.result))
        check(diskRow.permissionStatusSource=="injected-test" && diskRow.appKitRunning && !diskRow.requestedPermission && NSApp==nil,"injected AppKit-true field explicitly differs from actual nil NSApp")
        check(ChromeNormalMainProbeAdmission.owned(request.result,directory:false,mode:0o600),"receipt remains0600")
        refused("existing output refuses replay/overwrite")
        let overwrite=ChromeNormalMainProbeSession(request:request,environment:disk.environment());overwrite.readOnce();check(overwrite.phase=="receipt-write-refused","result cannot be overwritten")
        let (replaceRoot,replaceArgs)=try fixture();defer {try? FileManager.default.removeItem(at:replaceRoot)}
        let originalRequest=try ChromeNormalMainProbeAdmission.validate(replaceArgs,info:info);let held=replaceRoot.appendingPathExtension("held");try FileManager.default.moveItem(at:replaceRoot,to:held);defer{try? FileManager.default.removeItem(at:held)}
        try FileManager.default.createDirectory(at:replaceRoot,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let replacement=ChromeNormalMainProbeSession(request:originalRequest,environment:disk.environment());replacement.readOnce();check(replacement.phase=="receipt-write-refused" && !FileManager.default.fileExists(atPath:originalRequest.result.path),"replaced root inode cannot receive receipt")
        let replacedDiagnostics=ChromeNormalMainProbeDiagnostics(request:originalRequest)
        check((try? replacedDiagnostics.record("main-entered",appKitRunning:false))==nil && !FileManager.default.fileExists(atPath:replaceRoot.appendingPathComponent("phase-main-entered.json").path),"replaced root inode cannot receive startup metadata")
        check(NSApp == nil,"headless controls did not initialize NSApplication")
        print("NORMAL_MAIN_CHROME_METADATA \(passes) PASS 0 FAIL; synthetic files and injected status only")
    }
}
