import Foundation
import CryptoKit
import Darwin

/// Supplied by the release owner from its pinned bundle manifest. This API never
/// downloads a runtime, searches PATH, or inspects an existing service/config.
public struct LocalSearchRuntime: Codable, Equatable {
    public var version:Int=1
    public var server:URL
    public var serverSHA256:String
    public var supervisor:URL
    public var supervisorSHA256:String
    public init(server:URL,serverSHA256:String,supervisor:URL,supervisorSHA256:String) {
        self.server=server;self.serverSHA256=serverSHA256;self.supervisor=supervisor;self.supervisorSHA256=supervisorSHA256
    }
    /// Reads only this exact release-owned manifest. Nil means not provisioned.
    /// No downloads, PATH discovery, personal configuration or key reads.
    public static func bundled(in appBundle:URL)throws->LocalSearchRuntime? {
        let manifest=appBundle.appendingPathComponent("Contents/Resources/typesense-runtime-v1.json")
        guard FileManager.default.fileExists(atPath:manifest.path) else{return nil}
        guard manifest.standardizedFileURL==manifest.resolvingSymlinksInPath() else{throw SearchFailure.configuration}
        let fd=open(manifest.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else{throw SearchFailure.configuration};defer{close(fd)}
        var st=stat();guard fstat(fd,&st)==0,st.st_mode&S_IFMT==S_IFREG,st.st_mode&0o022==0,(1...8192).contains(st.st_size) else{throw SearchFailure.configuration}
        var bytes=[UInt8](repeating:0,count:8193);let n=Darwin.read(fd,&bytes,bytes.count)
        guard n==st.st_size else{throw SearchFailure.configuration}
        struct Manifest:Decodable{var version:Int;var serverSHA256:String;var supervisorSHA256:String}
        let pin=try JSONDecoder().decode(Manifest.self,from:Data(bytes.prefix(n)))
        guard pin.version==1 else{throw SearchFailure.configuration}
        return LocalSearchRuntime(server:appBundle.appendingPathComponent("Contents/Helpers/typesense-server"),serverSHA256:pin.serverSHA256,
            supervisor:appBundle.appendingPathComponent("Contents/MacOS/mac-mem"),supervisorSHA256:pin.supervisorSHA256)
    }
    public func validate() throws {
        guard version==1 else {throw SearchFailure.configuration}
        try Self.validateExecutable(server,hash:serverSHA256)
        try Self.validateExecutable(supervisor,hash:supervisorSHA256)
    }
    static func validateExecutable(_ file:URL,hash:String) throws {
        guard file.isFileURL,file.standardizedFileURL==file.resolvingSymlinksInPath(),
              hash.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else {throw SearchFailure.configuration}
        let fd=open(file.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else {throw SearchFailure.configuration};defer{close(fd)}
        var st=stat();guard fstat(fd,&st)==0,st.st_mode&S_IFMT==S_IFREG,st.st_mode&0o022==0,
            (1...180_000_000).contains(st.st_size),access(file.path,X_OK)==0 else {throw SearchFailure.configuration}
        var digest=SHA256(),buffer=[UInt8](repeating:0,count:65536)
        while true {let n=Darwin.read(fd,&buffer,buffer.count);guard n>=0 else{throw SearchFailure.configuration};if n==0{break};digest.update(data:Data(buffer.prefix(n)))}
        var after=stat();guard fstat(fd,&after)==0,st.st_size==after.st_size,st.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,
              st.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,digest.finalize().map({String(format:"%02x",$0)}).joined()==hash else {throw SearchFailure.configuration}
    }
}

struct ManagedSearchBinding:Codable {
    var version:Int=1
    var storeID:String
    var peerPort:Int
    var config:TypesenseConfiguration
}
struct SearchWorkerEvent:Codable {var phase:String;var reason:String}
private final class SearchStopSignal {
    private let lock=NSLock();private var stopped=false
    func stop(){lock.lock();stopped=true;lock.unlock()}
    var value:Bool{lock.lock();defer{lock.unlock()};return stopped}
}

/// claude/perf2-1003: the supervisor's page pacing. While indexing, a page every 0.1 s. Once ready, a page that changed
/// nothing waits `cleanPace` (one that changed something, 1 s), and a whole sweep that changed nothing rests
/// `restAfterCleanSweep` before the next, unless the store turns dirty (a disclosure or policy change), which ends the rest
/// at once. The app and the CLI index their own writes as they make them (LocalSearchIndexer.schedule) and every search
/// hit is checked against SQLite, so ready sweeps only catch expiry and missed work; they ran nonstop at a page a second.
struct SearchSweepPacing {
    static let cleanPace:TimeInterval=2
    static let restAfterCleanSweep:TimeInterval=60
    private var sweepChanged=false
    private(set) var restUntil=Date.distantPast
    static func pace(ready:Bool,changed:Bool) -> TimeInterval {!ready ? 0.1 : changed ? 1 : cleanPace}
    /// Whether to skip this turn (a clean sweep's rest). A dirty store, or a phase that isn't ready, ends the rest.
    mutating func resting(ready:Bool,dirty:Bool,now:Date) -> Bool {
        if ready && !dirty && now<restUntil {return true}
        restUntil=Date.distantPast
        return false
    }
    /// After one page: the pause before the next.
    mutating func page(_ result:SearchSyncResult,ready:Bool,dirty:Bool,now:Date) -> TimeInterval {
        let changed=result.upserted>0 || result.deleted>0
        sweepChanged=sweepChanged || changed
        if result.cycleComplete {
            if ready && !sweepChanged && !dirty {restUntil=now.addingTimeInterval(Self.restAfterCleanSweep)}
            sweepChanged=false
        }
        return Self.pace(ready:ready,changed:changed)
    }
}

/// Native companion entry point. Parent owns stdin's writer. App exit (including
/// SIGKILL) closes it; this process then stops only its own server and releases
/// the per-store lock. No launch agent, shell, Python or PID-based adoption.
public enum LocalSearchSupervisor {
    private static func directory(_ url:URL,create:Bool=false)throws {
        guard url.isFileURL,url.standardizedFileURL==url.resolvingSymlinksInPath() else{throw SearchFailure.configuration}
        if create && !FileManager.default.fileExists(atPath:url.path) {
            try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        }
        let fd=open(url.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else{throw SearchFailure.configuration};defer{close(fd)}
        var st=stat();guard fstat(fd,&st)==0,st.st_uid==getuid(),st.st_mode&0o077==0 else{throw SearchFailure.configuration}
    }
    private static func write(_ url:URL,_ data:Data)throws {
        if FileManager.default.fileExists(atPath:url.path) {_=try TypesenseConfiguration.privateFile(url.path,limit:8192)}
        let temp=url.deletingLastPathComponent().appendingPathComponent(".search-"+UUID().uuidString)
        let fd=open(temp.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else{throw SearchFailure.configuration}
        defer{close(fd);unlink(temp.path)}
        guard data.withUnsafeBytes({Darwin.write(fd,$0.baseAddress,$0.count)})==data.count,fsync(fd)==0,
              rename(temp.path,url.path)==0 else{throw SearchFailure.configuration}
    }
    private static func port()throws->Int {
        let fd=socket(AF_INET,SOCK_STREAM,0);guard fd>=0 else{throw SearchFailure.unavailable};defer{close(fd)}
        var a=sockaddr_in();a.sin_family=sa_family_t(AF_INET);a.sin_addr.s_addr=inet_addr("127.0.0.1")
        guard withUnsafePointer(to:&a,{$0.withMemoryRebound(to:sockaddr.self,capacity:1){bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}})==0 else{throw SearchFailure.unavailable}
        var size=socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to:&a,{$0.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(fd,$0,&size)}})==0 else{throw SearchFailure.unavailable}
        return Int(UInt16(bigEndian:a.sin_port))
    }
    private static func emit(_ phase:String,_ reason:String) {
        guard let data=try? JSONEncoder().encode(SearchWorkerEvent(phase:phase,reason:reason)) else{return}
        // Parent may have exited. Ignore EPIPE, never print source/key/error text.
        let line=data+Data([10]);line.withUnsafeBytes{_ = Darwin.write(STDOUT_FILENO,$0.baseAddress,$0.count)}
    }
    /// A binding this supervisor wrote for this same store in a folder that has since moved: version 1, the store's
    /// id, sane ports, not a synthetic preview, its key files in that folder's `local-search-v1` (the same layout), and
    /// its collection the one that folder's path gives. Never true for the current folder's own binding.
    static func movedWithFolder(_ old:ManagedSearchBinding,storeID:String,home:URL,search:URL,sync:URL) -> Bool {
        guard old.version==1,old.storeID==storeID,old.config.syntheticOnly != true,
              (1024...65535).contains(old.config.port),(1024...65535).contains(old.peerPort),old.peerPort != old.config.port else {return false}
        let searchFile=URL(fileURLWithPath:old.config.searchKeyFile),syncFile=URL(fileURLWithPath:old.config.syncKeyFile)
        let oldRoot=searchFile.deletingLastPathComponent()
        guard old.config.searchKeyFile.hasPrefix("/"),old.config.syncKeyFile.hasPrefix("/"),
              searchFile.lastPathComponent==search.lastPathComponent,syncFile.lastPathComponent==sync.lastPathComponent,
              syncFile.deletingLastPathComponent()==oldRoot,oldRoot.lastPathComponent=="local-search-v1" else {return false}
        let oldHome=oldRoot.deletingLastPathComponent()
        // The collection was named from the old folder's resolved path while it existed (Foundation drops a leading
        // /private then); the folder is gone now, so its path is compared as written and without that prefix.
        let oldPath=oldHome.standardizedFileURL.path
        let named=Set([oldPath]+(oldPath.hasPrefix("/private/") ? [String(oldPath.dropFirst("/private".count))] : [])).map {
            "macmem_"+fingerprint($0).prefixString(20)+"_v1"
        }
        guard oldPath != home.standardizedFileURL.path,named.contains(old.config.collection) || old.config.collection==TypesenseConfiguration.collection(for:oldHome) else {return false}
        return old.config.collection != TypesenseConfiguration.collection(for:home)
    }
    public static func run(home:URL,server:URL,sha256:String,startupBudget:TimeInterval=8) -> Int32 {
        signal(SIGPIPE,SIG_IGN)
        let stop=SearchStopSignal()
        DispatchQueue.global(qos:.utility).async {
            var byte:UInt8=0
            // Any input or EOF is cancellation. There are no executable commands.
            _=Darwin.read(STDIN_FILENO,&byte,1);stop.stop()
        }
        do {try serve(home:home,server:server,sha256:sha256,budget:startupBudget,stop:stop);emit("stopped","stopped");return 0}
        catch SearchFailure.busy {emit("fallback","local_index_in_use");return 2}
        catch SearchFailure.configuration {emit("fallback","runtime_or_private_configuration_invalid");return 3}
        catch {emit("fallback",stop.value ? "stopped" : "local_index_unavailable");return 4}
    }
    private static func serve(home:URL,server:URL,sha256:String,budget:TimeInterval,stop:SearchStopSignal)throws {
        try directory(home);try LocalSearchRuntime.validateExecutable(server,hash:sha256)
        guard !stop.value else{throw SearchFailure.unavailable}
        // Read-only validation before opening an existing canonical store writable.
        let source=try MemoryStore(home:home);_=try source.policy()
        let root=home.appendingPathComponent("local-search-v1");try directory(root,create:true)
        let lease=open(root.appendingPathComponent("owner.lock").path,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard lease>=0 else{throw SearchFailure.configuration};defer{close(lease)}
        var leaseStat=stat();guard fstat(lease,&leaseStat)==0,leaseStat.st_uid==getuid(),leaseStat.st_mode&S_IFMT==S_IFREG,leaseStat.st_mode&0o077==0 else{throw SearchFailure.configuration}
        guard flock(lease,LOCK_EX|LOCK_NB)==0 else{throw SearchFailure.busy};defer{flock(lease,LOCK_UN)}
        let configURL=home.appendingPathComponent("search-typesense.json"), bindingURL=root.appendingPathComponent("binding.json")
        let search=root.appendingPathComponent("search.key"),sync=root.appendingPathComponent("sync.key"),bootstrap=root.appendingPathComponent("bootstrap.key")
        let storeID=try source.coreSnapshotFence().storeID
        let binding:ManagedSearchBinding
        // claude/catchup-1003: this folder's own index, made before the history folder moved (Mac Mem -> DayDream, one
        // rename). Its binding still names the old folder's paths and collection, so every launch since then refused it
        // as foreign and search ran on the SQLite fallback for good. Same store, same managed layout: nothing is
        // deleted. The old binding, keys, index and config are moved aside, as they are, into one folder in
        // `local-search-v1`, and the index is built again for this folder. Anything else still refuses.
        if FileManager.default.fileExists(atPath:bindingURL.path),
           let old=try? JSONDecoder().decode(ManagedSearchBinding.self,from:TypesenseConfiguration.privateFile(bindingURL.path,limit:8192)),
           Self.movedWithFolder(old,storeID:storeID,home:home,search:search,sync:sync) {
            var savedAside=false
            if FileManager.default.fileExists(atPath:configURL.path) {
                let saved=try JSONDecoder().decode(TypesenseConfiguration.self,from:TypesenseConfiguration.privateFile(configURL.path,limit:8192))
                var on=saved;on.enabled=true
                guard on==old.config else{throw SearchFailure.configuration}
                guard saved.enabled else{emit("fallback","explicitly_disabled");return}
                savedAside=true
            }
            let aside=root.appendingPathComponent("moved-"+String(Int(Date().timeIntervalSince1970)))
            guard !FileManager.default.fileExists(atPath:aside.path) else{throw SearchFailure.busy}
            try directory(aside,create:true)
            // The config first (left behind, it alone would refuse every later start), the binding last (left behind, the
            // next start moves the rest aside again).
            let moves=(savedAside ? [(configURL,"search-typesense.json")] : [])+[(root.appendingPathComponent("index"),"index"),
                (search,"search.key"),(sync,"sync.key"),(bootstrap,"bootstrap.key"),(bindingURL,"binding.json")]
            for (from,name) in moves where FileManager.default.fileExists(atPath:from.path) {
                guard rename(from.path,aside.appendingPathComponent(name).path)==0 else{throw SearchFailure.configuration}
            }
        }
        if FileManager.default.fileExists(atPath:bindingURL.path) {
            binding=try JSONDecoder().decode(ManagedSearchBinding.self,from:TypesenseConfiguration.privateFile(bindingURL.path,limit:8192))
            guard binding.version==1,binding.storeID==storeID,binding.config.collection==TypesenseConfiguration.collection(for:home),
                binding.config.searchKeyFile==search.path,binding.config.syncKeyFile==sync.path,
                (1024...65535).contains(binding.config.port),(1024...65535).contains(binding.peerPort),binding.peerPort != binding.config.port,
                binding.config.syntheticOnly != true else{throw SearchFailure.configuration}
            if FileManager.default.fileExists(atPath:configURL.path) {
                let saved=try JSONDecoder().decode(TypesenseConfiguration.self,from:TypesenseConfiguration.privateFile(configURL.path,limit:8192))
                guard saved.enabled else{emit("fallback","explicitly_disabled");return}
                guard saved==binding.config else{throw SearchFailure.configuration}
            }
        } else {
            // Never attach to, replace or borrow an existing user/shared index.
            guard !FileManager.default.fileExists(atPath:configURL.path) else{throw SearchFailure.configuration}
            guard try FileManager.default.contentsOfDirectory(atPath:root.path).allSatisfy({$0=="owner.lock" || $0.hasPrefix(".search-") || $0.hasPrefix("moved-")}) else{throw SearchFailure.configuration}
            let api=try port();var peer=try port();while api==peer{peer=try port()}
            binding=ManagedSearchBinding(storeID:storeID,peerPort:peer,config:TypesenseConfiguration(home:home,port:api,searchKeyFile:search.path,syncKeyFile:sync.path,enabled:true))
            try write(bindingURL,JSONEncoder().encode(binding))
        }
        let config=binding.config,index=root.appendingPathComponent("index");try directory(index,create:true)
        // Rotate bootstrap on every owned startup. It never appears in argv or logs.
        let adminKey=UUID().uuidString+UUID().uuidString;try write(bootstrap,Data(adminKey.utf8))
        let child=Process();child.executableURL=server
        child.arguments=["--data-dir",index.path,"--api-address","127.0.0.1","--api-port",String(config.port),
            "--peering-address","127.0.0.1","--peering-port",String(binding.peerPort),"--enable-cors=false",
            "--enable-search-analytics=false","--enable-access-logging=false","--enable-search-logging=false",
            "--log-slow-searches-time-ms=-1","--log-slow-requests-time-ms=-1","--thread-pool-size=4"]
        child.environment=["PATH":"/usr/bin:/bin","TYPESENSE_API_KEY":adminKey]
        child.standardInput=FileHandle.nullDevice;child.standardOutput=FileHandle.nullDevice;child.standardError=FileHandle.nullDevice
        guard !stop.value else{throw SearchFailure.unavailable};try child.run()
        defer {
            if child.isRunning{child.terminate()}
            let until=Date().addingTimeInterval(2)
            while child.isRunning && Date()<until{Thread.sleep(forTimeInterval:0.02)}
            if child.isRunning{kill(child.processIdentifier,SIGKILL)}
            child.waitUntilExit()
        }
        let deadline=Date().addingTimeInterval(budget.isFinite ? max(0.05,min(20,budget)) : 8)
        let adminConfig=TypesenseConfiguration(home:home,port:config.port,searchKeyFile:bootstrap.path,syncKeyFile:bootstrap.path)
        let admin=LocalTypesenseHTTP(adminConfig,sync:true)
        var healthy=false
        while !stop.value && child.isRunning && Date()<deadline {
            if let reply=try? admin.request("GET","/health",deadline:min(deadline,Date().addingTimeInterval(0.25))),reply.status==200 {healthy=true;break}
            Thread.sleep(forTimeInterval:0.05)
        }
        guard healthy,!stop.value,child.isRunning else{throw SearchFailure.unavailable}
        func mint(_ actions:[String],until:Date)throws->String {
            guard !stop.value else{throw SearchFailure.unavailable}
            let body:[String:Any]=["description":"DayDream private local search","actions":actions,"collections":["^"+config.collection+"$"],"expires_at":Int(Date().timeIntervalSince1970)+86400]
            let reply=try admin.request("POST","/keys",body:JSONSerialization.data(withJSONObject:body),deadline:min(until,Date().addingTimeInterval(2)))
            guard reply.status==201,let key=(try JSONSerialization.jsonObject(with:reply.data) as? [String:Any])?["value"] as? String,(24...256).contains(key.utf8.count) else{throw SearchFailure.response}
            return key
        }
        // Authenticated key mint proves this is our child, not a port occupant.
        func renew(until:Date)throws {
            try write(search,Data(try mint(["documents:search"],until:until).utf8))
            try write(sync,Data(try mint(["collections:get","collections:create","collections:delete","documents:import","documents:delete"],until:until).utf8))
        }
        try renew(until:deadline)
        try write(configURL,JSONEncoder().encode(config))
        let store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
        emit("indexing","canonical_index_catching_up")
        var lastPhase="indexing",lastHealth=Date.distantPast
        var pacing=SearchSweepPacing()
        var renewAt=Date().addingTimeInterval(12*3600)
        while !stop.value && child.isRunning {
            guard try TypesenseConfiguration.load(home:home)==config else{throw SearchFailure.changed}
            if Date()>=renewAt{try renew(until:Date().addingTimeInterval(5));renewAt=Date().addingTimeInterval(12*3600)}
            if Date().timeIntervalSince(lastHealth)>5 {
                let response=try admin.request("GET","/health",deadline:Date().addingTimeInterval(0.4))
                guard response.status==200 else{throw SearchFailure.unavailable};lastHealth=Date()
            }
            var pause=SearchSweepPacing.pace(ready:lastPhase=="ready",changed:true)
            do {
                let dirty=try store.rows("SELECT body FROM metadata WHERE id='search_complete_revision'").first?.first != store.disclosureRevision()
                if dirty && lastPhase != "indexing"{emit("indexing","canonical_index_catching_up");lastPhase="indexing"}
                if pacing.resting(ready:lastPhase=="ready",dirty:dirty,now:Date()) {
                    let until=Date().addingTimeInterval(1) // look for a dirty store once a second while resting
                    while !stop.value && Date()<until{Thread.sleep(forTimeInterval:0.025)}
                    continue
                }
                // Periodic full sweeps also discover expiry without a new event.
                let result=try store.syncSearchIndex()
                var ready=lastPhase=="ready" // this page's phase, or the phase its finished sweep verified
                if result.cycleComplete {
                    let verified=try store.searchResult(MemorySearchQuery("",limit:1))
                    let final=verified.backend=="typesense" && verified.status=="ready" ? "ready" : "indexing"
                    if final != lastPhase{emit(final,final == "ready" ? "verified_local_index" : "canonical_index_catching_up");lastPhase=final}
                    ready=final=="ready"
                }
                pause=pacing.page(result,ready:ready,dirty:dirty,now:Date())
            } catch SearchFailure.busy {} catch SearchFailure.changed {} // retry bounded page, never replay user actions
            catch MemError.busy {} // another connection held the file past the busy timeout: the same page, a moment later
            let until=Date().addingTimeInterval(pause)
            while !stop.value && Date()<until{Thread.sleep(forTimeInterval:0.025)}
        }
        if !stop.value{throw SearchFailure.unavailable}
    }
}
