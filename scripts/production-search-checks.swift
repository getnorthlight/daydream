// Real production launcher + native companion + loopback Typesense. All data
// and credentials are newly fabricated under one disposable temporary root.
import Foundation
import Darwin
import CryptoKit
@testable import MemoryCore

@main struct ProductionSearchChecks {
    static var count=0
    static func check(_ value:@autoclosure () throws->Bool,_ label:String)throws {
        guard try value() else{throw MemError.invalid("FAIL: "+label)};count += 1;print("PASS: "+label)
    }
    static func wait(_ label:String,seconds:Double=15,_ predicate:()->Bool)throws {
        let until=Date().addingTimeInterval(seconds)
        while Date()<until{if predicate(){return};Thread.sleep(forTimeInterval:0.025)}
        throw MemError.invalid("TIMEOUT: "+label)
    }
    static func query(_ launch:ProductionSearchLaunch,_ text:String)throws->MemorySearchResult {
        let done=DispatchSemaphore(value:0);var result:Result<MemorySearchResult,Error>?
        launch.search(MemorySearchQuery(text)){result=$0;done.signal()}
        guard done.wait(timeout:.now()+3) == .success else{throw SearchFailure.unavailable}
        return try result!.get()
    }
    static func main()throws {
        setbuf(stdout,nil)
        guard let server=ProcessInfo.processInfo.environment["MACMEM_TYPESENSE_TEST_BINARY"],let helper=ProcessInfo.processInfo.environment["MACMEM_TEST_CLI"] else{throw MemError.invalid("Explicit temporary test executables required")}
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--hold" {
            let owned=try MemoryStore(home:URL(fileURLWithPath:CommandLine.arguments[2]),writable:true,automaticallySyncSearch:false)
            func digest(_ path:String)throws->String{SHA256.hash(data:try Data(contentsOf:URL(fileURLWithPath:path))).map{String(format:"%02x",$0)}.joined()}
            let pins=LocalSearchRuntime(server:URL(fileURLWithPath:server).resolvingSymlinksInPath(),serverSHA256:try digest(server),supervisor:URL(fileURLWithPath:helper).resolvingSymlinksInPath(),supervisorSHA256:try digest(helper))
            let app=ProductionSearchLaunch(store:owned);_=app.begin(runtime:pins,callbackQueue:.global(),onChange:{_ in})
            Thread.sleep(forTimeInterval:60);app.stop();return
        }
        let root=URL(fileURLWithPath:"/private/tmp/production-search-check-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        // Keep only this disposable directory until all owned children release.
        defer{try? FileManager.default.removeItem(at:root)}
        func hash(_ path:String)throws->String{SHA256.hash(data:try Data(contentsOf:URL(fileURLWithPath:path))).map{String(format:"%02x",$0)}.joined()}
        let runtime:LocalSearchRuntime
        if let app=ProcessInfo.processInfo.environment["MACMEM_TEST_APP"] {
            guard let bundled=try LocalSearchRuntime.bundled(in:URL(fileURLWithPath:app).resolvingSymlinksInPath()) else { throw MemError.invalid("Explicit fixture app has no runtime manifest") }
            try bundled.validate();runtime=bundled
            try check(runtime.server.resolvingSymlinksInPath().path==URL(fileURLWithPath:server).resolvingSymlinksInPath().path && runtime.supervisor.resolvingSymlinksInPath().path==URL(fileURLWithPath:helper).resolvingSymlinksInPath().path,"actual staged bundle manifest pins the explicit test executables")
        } else {
            runtime=LocalSearchRuntime(server:URL(fileURLWithPath:server).resolvingSymlinksInPath(),serverSHA256:try hash(server),supervisor:URL(fileURLWithPath:helper).resolvingSymlinksInPath(),supervisorSHA256:try hash(helper))
        }
        try check(try LocalSearchRuntime.bundled(in:root)==nil,"missing release manifest returns not provisioned without network")
        let resources=root.appendingPathComponent("Fixture.app/Contents/Resources")
        try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
        let manifest=resources.appendingPathComponent("typesense-runtime-v1.json")
        try JSONSerialization.data(withJSONObject:["version":1,"serverSHA256":runtime.serverSHA256,"supervisorSHA256":runtime.supervisorSHA256]).write(to:manifest)
        let bundled=try LocalSearchRuntime.bundled(in:root.appendingPathComponent("Fixture.app"))!
        try check(bundled.server.lastPathComponent=="typesense-server" && bundled.supervisor.path.hasSuffix("Contents/MacOS/mac-mem"),"release manifest resolves only fixed bundle executable paths")
        do{try bundled.validate();throw MemError.invalid("FAIL missing bundle files accepted")}
        catch{try check(!String(describing:error).contains("FAIL"),"manifest alone cannot claim provisioned executables")}
        let store=try MemoryStore(home:root.appendingPathComponent("memory"),writable:true,automaticallySyncSearch:false)
        func seed(_ id:String,_ title:String="Garden sensor calibration",days:Double=0)throws {
            _=try store.ingest(Evidence(id:id,at:iso(Date().addingTimeInterval(-days*86400)),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:title,synthetic:true))
        }
        try seed("first",days:5000)
        let missing=ProductionSearchLaunch(store:store)
        try check(try query(missing,"Garden").items.count==1,"database search works before begin")
        _=missing.begin(runtime:nil,onChange:{_ in})
        try check(missing.snapshot.advancedReason=="runtime_missing" && missing.snapshot.canShowResults,"missing runtime gives immediate visible fallback")
        let bad=ProductionSearchLaunch(store:store);var broken=runtime;broken.serverSHA256=String(repeating:"0",count:64)
        _=bad.begin(runtime:broken,callbackQueue:.global(),onChange:{_ in})
        try wait("bad runtime"){bad.snapshot.phase=="fallback"}
        try check(!FileManager.default.fileExists(atPath:store.home.appendingPathComponent("local-search-v1").path),"wrong pin starts no index and creates no credentials")
        let failedStore=try MemoryStore(home:root.appendingPathComponent("failed"),writable:true,automaticallySyncSearch:false)
        let failed=ProductionSearchLaunch(store:failedStore);var failRuntime=runtime
        failRuntime.server=URL(fileURLWithPath:"/usr/bin/false");failRuntime.serverSHA256=try hash("/usr/bin/false")
        _=failed.begin(runtime:failRuntime,callbackQueue:.global(),onChange:{_ in})
        try wait("failed server"){failed.snapshot.phase=="fallback"}
        try check(try query(failed,"").backend=="sqlite","server execution failure preserves SQLite search")
        let timeoutStore=try MemoryStore(home:root.appendingPathComponent("timeout"),writable:true,automaticallySyncSearch:false)
        let timed=ProductionSearchLaunch(store:timeoutStore);let timeoutStart=Date()
        _=timed.begin(runtime:runtime,startupBudget:0.05,callbackQueue:.global(),onChange:{_ in})
        try wait("bounded deadline",seconds:2){timed.snapshot.phase=="fallback"}
        try check(Date().timeIntervalSince(timeoutStart)<2 && timed.snapshot.canShowResults,"startup deadline never gates the search UI")
        let launch=ProductionSearchLaunch(store:store);defer{launch.stop()}
        let start=Date();_=launch.begin(runtime:runtime,callbackQueue:.global(),onChange:{_ in})
        try check(!launch.begin(runtime:runtime,onChange:{_ in}),"repeated begin does not spawn a second supervisor")
        try check(try query(launch,"Garden").items.count==1,"database search remains available during startup")
        try wait("ready: \(launch.snapshot.advancedReason)"){launch.snapshot.phase=="ready"}
        print("MEASURE production startup + first canonical index: \(Int(Date().timeIntervalSince(start)*1000))ms")
        try check(try query(launch,"grden sensor").backend=="typesense","real typo query uses Typesense")
        try check(try query(launch,"grden sensor").items.first?.id=="first","Never-retained ancient action indexed from canonical source")
        let config=try TypesenseConfiguration.load(home:store.home)!
        try check(config.syntheticOnly != true && config.searchKeyFile != config.syncKeyFile,"production mode has separate scoped credentials, not synthetic-only launch")
        let http=LocalTypesenseHTTP(config,sync:false)
        let denied=try http.request("POST","/collections",body:Data("{}".utf8),deadline:Date().addingTimeInterval(1))
        try check(denied.status==401,"search credential cannot mutate collections")
        let duplicate=ProductionSearchLaunch(store:store);_=duplicate.begin(runtime:runtime,callbackQueue:.global(),onChange:{_ in})
        try wait("duplicate rejected"){duplicate.snapshot.phase=="fallback"}
        try check(duplicate.snapshot.advancedReason=="local_index_in_use" && launch.snapshot.phase=="ready","second controller cannot replace the live owner")
        try seed("recent","Fresh orchard action")
        try check(try query(launch,"Fresh orchard").items.contains{$0.id=="recent"},"recent database merge does not wait for initial/incremental index")
        try store.delete("first")
        try check(try query(launch,"grden sensor").items.allSatisfy{$0.id != "first"},"deletion immediately rejects old index hit before cleanup")
        try wait("deletion reconciled"){(try? query(launch,"Fresh orchard").status)=="ready"}
        let before=try store.action("recent")!
        _=try store.correctAction(id:"recent",text:"Apricot planning",expectedRevision:before.revision)
        try wait("correction indexed"){(try? query(launch,"apricot").items.contains{$0.id=="recent"})==true}
        try check(try query(launch,"apricot").items.first?.summary.contains("User correction")==true,"corrected action presentation remains explicitly user-authored")
        let lockURL=store.home.appendingPathComponent("local-search-v1/owner.lock")
        func released()->Bool {
            let fd=open(lockURL.path,O_RDWR);if fd<0{return false};defer{close(fd)}
            if flock(fd,LOCK_EX|LOCK_NB)==0{flock(fd,LOCK_UN);return true};return false
        }
        launch.stop();try wait("owned shutdown releases lock"){released()}
        try check(try query(launch,"apricot").backend=="sqlite","stop gives direct SQLite fallback")
        try seed("while-off","Imported papaya action",days:45)
        let restart=ProductionSearchLaunch(store:store);defer{restart.stop()}
        _=restart.begin(runtime:runtime,callbackQueue:.global(),onChange:{_ in})
        try wait("restart ready"){restart.snapshot.phase=="ready"}
        try check(try query(restart,"papya").items.contains{$0.id=="while-off"},"restart reuses private index and discovers offline canonical additions")
        try check(try query(restart,"grden sensor").items.isEmpty,"restart does not resurrect deleted index data")
        // Invoke actual migration APIs against the same owned canonical store.
        // Destination initialization is allowed only on isolated empty stores,
        // so use the already-authorized staging contract in a separate fixture.
        let imported=try MemoryStore(home:root.appendingPathComponent("imported"),writable:true,automaticallySyncSearch:false)
        try imported.initializeMigrationDestination()
        var entry=MigrationEntry(id:"",sourceID:"import-fixture",family:"collector-event",format:"fixture",at:iso(Date().addingTimeInterval(-40*86400)),epochNanos:"1",timezone:"UTC",raw:"{}",rawSHA256:fingerprint("{}"),deleted:false,evidence:nil,summary:nil,end:nil,attachments:[])
        entry.id=try LegacyMigration.stableID(entry,namespace:"production-search")
        entry.evidence=Evidence(id:entry.id,at:entry.at,kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Migration kumquat orchard")
        let snap=MigrationSnapshot(version:1,namespace:"production-search",entries:[entry]),snapHash=fingerprint(try json(entry))
        let plan=try imported.migrationDryRun(snapshot:snap,hash:snapHash,root:root)
        _=try imported.importMigration(snapshot:snap,hash:snapHash,policyHash:plan.policySHA256,root:root)
        let importLaunch=ProductionSearchLaunch(store:imported);defer{importLaunch.stop()}
        _=importLaunch.begin(runtime:runtime,callbackQueue:.global(),onChange:{_ in})
        try wait("import index"){importLaunch.snapshot.phase=="ready"}
        try check(try query(importLaunch,"kumqat").items.contains{$0.id==entry.id},"actual import original feeds production Typesense action index")
        importLaunch.stop()
        var policy=try store.policy();policy.blockedApps=["com.apple.TextEdit"];try store.updatePolicy(policy)
        try check(try query(restart,"papya").items.isEmpty,"policy revision immediately withholds excluded index content")
        restart.stop();try wait("restart shutdown"){released()}
        var dropped:ProductionSearchLaunch?=ProductionSearchLaunch(store:store)
        _=dropped!.begin(runtime:runtime,callbackQueue:.global(),onChange:{_ in})
        try wait("deinit test ready"){dropped!.snapshot.phase=="ready"}
        dropped=nil;try wait("deinit control EOF shutdown"){released()}
        try check(released(),"dropping app binding closes pipe and stops owned child")
        var disabled=try TypesenseConfiguration.load(home:store.home)!;disabled.enabled=false
        let disabledFile=store.home.appendingPathComponent("search-typesense.json")
        try JSONEncoder().encode(disabled).write(to:disabledFile)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:disabledFile.path)
        let off=ProductionSearchLaunch(store:store);_=off.begin(runtime:runtime,callbackQueue:.global(),onChange:{_ in})
        try wait("explicit off"){off.snapshot.phase=="fallback"}
        try check(off.snapshot.advancedReason=="explicitly_disabled" && (try TypesenseConfiguration.load(home:store.home))==nil,"explicit stored off is not silently enabled at launch")
        let foreign=try MemoryStore(home:root.appendingPathComponent("foreign"),writable:true,automaticallySyncSearch:false)
        let existing=TypesenseConfiguration(home:foreign.home,port:28222,searchKeyFile:"/not/read/search",syncKeyFile:"/not/read/sync",enabled:true)
        let configFile=foreign.home.appendingPathComponent("search-typesense.json")
        try JSONEncoder().encode(existing).write(to:configFile);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configFile.path)
        let foreignLaunch=ProductionSearchLaunch(store:foreign);_=foreignLaunch.begin(runtime:runtime,callbackQueue:.global(),onChange:{_ in})
        try wait("foreign config refused"){foreignLaunch.snapshot.phase=="fallback"}
        try check(try TypesenseConfiguration.load(home:foreign.home)==existing,"pre-existing separate/shared config is neither borrowed nor replaced")
        // claude/catchup-1003: the history folder moved (Mac Mem -> DayDream, one rename) after its index was made. The
        // index's own binding is recognized, set aside (nothing deleted) and built again for the new folder.
        let movedFrom=root.appendingPathComponent("Mac Mem"),movedTo=root.appendingPathComponent("DayDream")
        do {
            let before=try MemoryStore(home:movedFrom,writable:true,automaticallySyncSearch:false)
            _=try before.ingest(Evidence(id:"moved-row",at:iso(Date()),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Quince harvest plan",synthetic:true))
            let first=ProductionSearchLaunch(store:before);_=first.begin(runtime:runtime,callbackQueue:.global(),onChange:{_ in})
            try wait("moved fixture ready"){first.snapshot.phase=="ready"}
            first.stop()
            try wait("moved fixture shutdown"){
                let fd=open(movedFrom.appendingPathComponent("local-search-v1/owner.lock").path,O_RDWR);if fd<0{return false};defer{close(fd)}
                if flock(fd,LOCK_EX|LOCK_NB)==0{flock(fd,LOCK_UN);return true};return false
            }
        }
        guard rename(movedFrom.path,movedTo.path)==0 else{throw MemError.invalid("fixture rename failed")}
        let after=try MemoryStore(home:movedTo,writable:true,automaticallySyncSearch:false)
        let stale=ProductionSearchLaunch(store:after);defer{stale.stop()}
        _=stale.begin(runtime:runtime,callbackQueue:.global(),onChange:{_ in})
        try wait("moved folder ready: \(stale.snapshot.advancedReason)"){stale.snapshot.phase=="ready"}
        try check(try query(stale,"quince harvst").backend=="typesense" && query(stale,"quince harvst").items.first?.id=="moved-row","a history folder that moved gets its index back (rebuilt for the new folder)")
        let aside=try FileManager.default.contentsOfDirectory(atPath:movedTo.appendingPathComponent("local-search-v1").path).filter{$0.hasPrefix("moved-")}
        try check(aside.count==1 && FileManager.default.fileExists(atPath:movedTo.appendingPathComponent("local-search-v1/"+aside[0]+"/binding.json").path),"the moved folder's old binding is set aside, not deleted")
        stale.stop()
        try check(try store.captureStatus()["state"]=="off" && store.policy().captureText==false,"search lifecycle leaves capture and typing OFF")
        let crashStore=try MemoryStore(home:root.appendingPathComponent("crash"),writable:true,automaticallySyncSearch:false)
        let holder=Process();holder.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath()
        holder.arguments=["--hold",crashStore.home.path];holder.environment=["PATH":"/usr/bin:/bin","MACMEM_TYPESENSE_TEST_BINARY":server,"MACMEM_TEST_CLI":helper]
        holder.standardInput=FileHandle.nullDevice;holder.standardOutput=FileHandle.nullDevice;holder.standardError=FileHandle.nullDevice
        try holder.run();defer{if holder.isRunning{holder.terminate()}}
        try wait("crash fixture ready"){(try? crashStore.verifySearchSetup().verified)==true}
        let crashConfig=try TypesenseConfiguration.load(home:crashStore.home)!
        kill(holder.processIdentifier,SIGKILL);holder.waitUntilExit()
        try wait("app death stops supervisor-owned server"){
            let fd=open(crashStore.home.appendingPathComponent("local-search-v1/owner.lock").path,O_RDWR)
            if fd<0{return false};defer{close(fd)}
            guard flock(fd,LOCK_EX|LOCK_NB)==0 else{return false};flock(fd,LOCK_UN);return true
        }
        let unavailable=try? LocalTypesenseHTTP(crashConfig,sync:false).request("GET","/health",deadline:Date().addingTimeInterval(0.25))
        try check(unavailable==nil,"actual app SIGKILL closes pipe and leaves no server listening")
        print("PASS \(count) production search checks; only disposable synthetic memory used")
    }
}
