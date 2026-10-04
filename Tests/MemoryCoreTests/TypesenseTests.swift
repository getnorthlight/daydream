#if canImport(XCTest)
import XCTest
#endif
import Foundation
import Darwin
import CryptoKit
@testable import MemoryCore

private final class FakeTypesense: TypesenseTransport {
    var docs=[String:SearchDocument](); var exists=false; var offline=false; var failImport=false
    var afterImport:(() throws -> Void)?; var afterSearch:(() throws -> Void)?
    func request(_ method:String,_ path:String,query:[URLQueryItem],body:Data?,deadline:Date) throws -> TypesenseResponse {
        if offline { throw SearchFailure.unavailable }
        func response(_ status:Int,_ object:Any) throws -> TypesenseResponse { TypesenseResponse(status:status,data:try JSONSerialization.data(withJSONObject:object)) }
        if path == "/collections" { exists=true; return try response(201,[:]) }
        if path.hasSuffix("/documents/import") {
            let rows=String(decoding:body!,as:UTF8.self).split(separator:"\n")
            for row in rows { let doc=try JSONDecoder().decode(SearchDocument.self,from:Data(row.utf8)); docs[doc.id]=doc }
            try afterImport?()
            return TypesenseResponse(status:200,data:Data(rows.map { _ in failImport ? "{\"success\":false}" : "{\"success\":true}" }.joined(separator:"\n").utf8))
        }
        if path.hasSuffix("/documents/search") {
            try afterSearch?()
            return try response(200,["found":docs.count,"hits":docs.values.map { ["document":["source_id":$0.source_id,"revision":$0.revision,"summary":"UNTRUSTED_INDEX_SNIPPET"]] }])
        }
        if path.contains("/documents/") { docs.removeValue(forKey:String(path.split(separator:"/").last!)); return try response(200,[:]) }
        if method == "DELETE" { exists=false; docs=[:]; return try response(200,[:]) }
        return try response(exists ? 200 : 404,[:])
    }
}

final class TypesenseTests: XCTestCase {
    var home:URL!; var store:MemoryStore!; var config:TypesenseConfiguration!
    let now=Date()
    override func setUpWithError() throws {
        home=FileManager.default.temporaryDirectory.appendingPathComponent("macmem-search-test-"+UUID().uuidString)
        store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
        let review=try store.prepareRetentionChange(.days(30),now:now)
        _=try store.confirmRetentionChange(review.id,confirmed:true,now:now)
        config=TypesenseConfiguration(home:home,port:28108,searchKeyFile:home.appendingPathComponent("search.key").path,syncKeyFile:home.appendingPathComponent("sync.key").path,enabled:true)
        try privateWrite(config.searchKeyFile,Data(UUID().uuidString.utf8)); try privateWrite(config.syncKeyFile,Data(UUID().uuidString.utf8))
    }
    override func tearDownWithError() throws { store=nil; try FileManager.default.removeItem(at:home) }
    func privateWrite(_ path:String,_ data:Data) throws { try data.write(to:URL(fileURLWithPath:path)); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path) }
    func enable() throws { try privateWrite(home.appendingPathComponent("search-typesense.json").path,JSONEncoder().encode(config)) }
    func seed(_ id:String="garden",title:String="Garden sensor calibration",app:String="TextEdit",at:Date?=nil) throws {
        _=try store.ingest(Evidence(id:id,at:iso(at ?? now),kind:"window.changed",app:app,bundle:app,title:title,url:"https://example.org/?q=private-query",text:"never index typed data",synthetic:true),now:now)
    }
    func testDisabledAndOfflineFallback() throws {
        try seed()
        XCTAssertEqual(try store.searchResult(MemorySearchQuery("Garden"),now:now).status,"disabled")
        try enable()
        let start=Date(); let result=try store.searchResult(MemorySearchQuery("Garden"),now:now)
        XCTAssertEqual(result.status,"unavailable_fallback"); XCTAssertEqual(result.items.count,1)
        XCTAssertLessThan(Date().timeIntervalSince(start),2)
    }
    func testNeverRetentionIndexAndReview() throws {
        try enable()
        var policy=try store.policy();policy.retention = .never;try store.updatePolicy(policy,now:now)
        try seed("ancient",at:now.addingTimeInterval(-4000*86400));try seed("current")
        let transport=FakeTypesense()
        XCTAssertEqual(try store.syncSearchIndex(config:config,transport:transport,now:now).upserted,2)
        XCTAssertEqual(try store.indexedSearch(MemorySearchQuery("Garden"),config:config,transport:transport,now:now).items.count,2)
        let review=try store.prepareRetentionChange(.days(30),now:now)
        _=try store.confirmRetentionChange(review.id,confirmed:true,now:now)
        XCTAssertFalse(try store.indexedSearch(MemorySearchQuery("Garden"),config:config,transport:transport,now:now).items.contains{$0.id == "ancient"})
        _=try store.syncSearchIndex(config:config,transport:transport,now:now)
        XCTAssertTrue(transport.docs[fingerprint("ancient")] == nil)
        XCTAssertTrue(transport.docs[fingerprint("current")] != nil)
    }
    func testPrivateConfigAndProjection() throws {
        var consent=try store.policy(); consent.captureText=true; consent.typedConsentVersion=1
        try store.updatePolicy(consent,now:now)
        try seed(); try enable()
        XCTAssertEqual(try store.read("garden",now:now)?.evidence.text,"never index typed data")
        XCTAssertEqual(try TypesenseConfiguration.load(home:home),config)
        let doc=try XCTUnwrap(SearchDocument.make(store.read("garden",now:now)!))
        let encoded=try json(doc)
        XCTAssertFalse(encoded.contains("never index")); XCTAssertFalse(encoded.contains("private-query"))
        XCTAssertEqual(doc.source_id,"garden"); XCTAssertEqual(doc.site,"example.org")
        _=try store.ingest(Evidence(id:"typed-fixture",at:iso(now),kind:"keyboard.text_input",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Permitted draft",text:"unindexed private phrase",synthetic:true),now:now)
        let typed=try XCTUnwrap(SearchDocument.make(store.read("typed-fixture",now:now)!))
        XCTAssertFalse(try json(typed).contains("unindexed private phrase"))
        let local=try store.fallbackSearch(MemorySearchQuery("unindexed private phrase"),now:now,status:"fixture")
        XCTAssertTrue(local.items.isEmpty)
        XCTAssertTrue(local.coverage.contains("Typed bodies unsupported"))
        let before=try XCTUnwrap(store.action("garden",now:now))
        _=try store.correctAction(id:"garden",text:"User clarified: greenhouse planning",expectedRevision:before.revision,now:now)
        let corrected=try XCTUnwrap(SearchDocument.make(store.read("garden",now:now)!))
        XCTAssertTrue(corrected.summary.contains("User correction (not observed)"))
        XCTAssertTrue(corrected.revision != doc.revision)
        let transport=FakeTypesense()
        _=try store.syncSearchIndex(config:config,transport:transport,now:now)
        XCTAssertTrue(transport.docs[fingerprint("garden")]?.summary.contains("greenhouse planning") == true)
        let preview=try store.prepareDeletion(scope:MemoryActionScope(kind:"action",id:"garden"),now:now)
        _=try store.executeDeletion(previewID:preview.id,confirmed:true,now:now)
        let stale=try store.indexedSearch(MemorySearchQuery("greenhouse planning"),config:config,transport:transport,now:now)
        XCTAssertFalse(stale.items.contains{$0.id == "garden"})
        _=try store.syncSearchIndex(config:config,transport:transport,now:now)
        XCTAssertTrue(transport.docs[fingerprint("garden")] == nil)
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:config.searchKeyFile)
        XCTAssertThrowsError(try config.key(sync:false))
        config.collection="another_house"; try enable()
        XCTAssertThrowsError(try TypesenseConfiguration.load(home:home))
    }
    func testIncrementalRestartRebuildAndPartialImport() throws {
        try seed(); try enable(); let transport=FakeTypesense()
        XCTAssertEqual(try store.syncSearchIndex(config:config,transport:transport,now:now).upserted,1)
        store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
        XCTAssertEqual(try store.syncSearchIndex(config:config,transport:transport,now:now).upserted,0)
        XCTAssertEqual(try store.syncSearchIndex(config:config,transport:transport,rebuild:true,now:now).upserted,1)
        try seed("other"); transport.failImport=true
        XCTAssertThrowsError(try store.syncSearchIndex(config:config,transport:transport,now:now))
        transport.failImport=false
        XCTAssertEqual(try store.syncSearchIndex(config:config,transport:transport,now:now).upserted,1)
        XCTAssertEqual(transport.docs.count,2)
    }
    func testDeletionDuringOutageAndDuringImport() throws {
        try seed(); try enable(); let transport=FakeTypesense()
        _=try store.syncSearchIndex(config:config,transport:transport,now:now)
        transport.offline=true; try store.delete("garden")
        XCTAssertThrowsError(try store.syncSearchIndex(config:config,transport:transport,now:now))
        transport.offline=false
        XCTAssertTrue(try store.indexedSearch(MemorySearchQuery(""),config:config,transport:transport,now:now).items.isEmpty)
        XCTAssertEqual(try store.syncSearchIndex(config:config,transport:transport,now:now).deleted,1)
        try seed("racing")
        transport.afterImport={ try self.store.delete("racing") }
        XCTAssertThrowsError(try store.syncSearchIndex(config:config,transport:transport,now:now))
        transport.afterImport=nil
        XCTAssertEqual(try store.syncSearchIndex(config:config,transport:transport,now:now).deleted,1)
        XCTAssertTrue(transport.docs.isEmpty,"uncertain writes remain tracked for cleanup")
    }
    func testExclusionRetentionAndChangedReadFailClosed() throws {
        try seed(); try enable(); let transport=FakeTypesense()
        _=try store.syncSearchIndex(config:config,transport:transport,now:now)
        var policy=try store.policy(); policy.blockedApps=["TextEdit"]; try store.updatePolicy(policy,now:now)
        XCTAssertTrue(try store.indexedSearch(MemorySearchQuery(""),config:config,transport:transport,now:now).items.isEmpty)
        XCTAssertEqual(try store.syncSearchIndex(config:config,transport:transport,now:now).deleted,1)
        policy.blockedApps=[]; try store.updatePolicy(policy,now:now); try seed("fresh")
        _=try store.syncSearchIndex(config:config,transport:transport,now:now)
        XCTAssertTrue(try store.indexedSearch(MemorySearchQuery(""),config:config,transport:transport,now:now.addingTimeInterval(31*86400)).items.isEmpty)
        transport.afterSearch={ try self.store.delete("fresh") }
        XCTAssertThrowsError(try store.indexedSearch(MemorySearchQuery(""),config:config,transport:transport,now:now))
    }
    func testPageBoundsFiltersAndUntrustedIndexBody() throws {
        for n in 0..<205 { try seed(String(format:"item%03d",n),app:n%2 == 0 ? "A" : "B") }
        try enable(); let transport=FakeTypesense()
        XCTAssertEqual(try store.syncSearchIndex(config:config,transport:transport,now:now).scanned,100)
        XCTAssertEqual(try store.syncSearchIndex(config:config,transport:transport,now:now).scanned,100)
        XCTAssertEqual(try store.syncSearchIndex(config:config,transport:transport,now:now).scanned,5)
        XCTAssertEqual(transport.docs.count,205)
        transport.docs=Dictionary(uniqueKeysWithValues:transport.docs.prefix(20).map { ($0.key,$0.value) })
        let result=try store.indexedSearch(MemorySearchQuery("",app:"A",limit:100),config:config,transport:transport,now:now)
        XCTAssertTrue(result.items.allSatisfy { $0.evidence.app == "A" && !$0.summary.contains("UNTRUSTED") })
        XCTAssertTrue(try store.indexedSearch(MemorySearchQuery("",start:now.addingTimeInterval(60)),config:config,transport:transport,now:now).items.isEmpty)
    }

    func testRecentActionsWithoutIndexOrWriterCatchup() throws {
        try enable(); let transport=FakeTypesense(); transport.exists=true
        try seed("fresh-before-index",title:"Recent unindexed action")
        let start=Date()
        let result=try store.indexedSearch(MemorySearchQuery("Recent"),config:config,transport:transport,now:now)
        XCTAssertEqual(result.items.map(\.id),["fresh-before-index"])
        XCTAssertEqual(result.status,"catching_up")
        XCTAssertEqual(result.items.first?.writer,ActionProjection.version)
        XCTAssertTrue(transport.docs.isEmpty)
        print("ACTION SEARCH recent SQLite merge: \(Int(Date().timeIntervalSince(start)*1000))ms, no writer/index document")
        try store.exec("INSERT OR REPLACE INTO metadata VALUES('search_projection_version','old-summary-projection')")
        _=try store.syncSearchIndex(config:config,transport:transport,now:now)
        XCTAssertEqual(try store.rows("SELECT body FROM metadata WHERE id='search_projection_version'").first?.first,ActionProjection.version)
        try store.delete("fresh-before-index")
        XCTAssertTrue(try store.indexedSearch(MemorySearchQuery("Recent"),config:config,transport:transport,now:now).items.isEmpty)
    }

    func testRealTypesenseLifecycle() throws {
        guard let binary=ProcessInfo.processInfo.environment["MACMEM_TYPESENSE_TEST_BINARY"] else { throw XCTSkip("Set the verified temporary Typesense binary for real HTTP checks") }
        let server=try SyntheticServer(binary:binary,home:home)
        defer { server.stop() }
        config.port=server.port
        try server.start()
        let listeners=try server.listeners()
        XCTAssertFalse(listeners.isEmpty)
        XCTAssertTrue(listeners.allSatisfy { $0.hasPrefix("127.0.0.1:") },"API and peering must both be loopback-only")
        let bootstrap=server.key
        try privateWrite(config.syncKeyFile,Data(bootstrap.utf8))
        let admin=LocalTypesenseHTTP(config,sync:true)
        func mint(_ actions:[String]) throws -> String {
            let body=try JSONSerialization.data(withJSONObject:["description":"synthetic-only","actions":actions,"collections":[config.collection],"expires_at":Int(Date().timeIntervalSince1970)+600] as [String:Any])
            let response=try admin.request("POST","/keys",body:body,deadline:Date().addingTimeInterval(2))
            XCTAssertEqual(response.status,201)
            return try XCTUnwrap((try JSONSerialization.jsonObject(with:response.data) as? [String:Any])?["value"] as? String)
        }
        let searchKey=try mint(["documents:search"])
        let syncKey=try mint(["collections:get","collections:create","collections:delete","documents:import","documents:delete"])
        try privateWrite(config.searchKeyFile,Data(searchKey.utf8)); try privateWrite(config.syncKeyFile,Data(syncKey.utf8))
        try enable()
        XCTAssertEqual(try store.syncSearchIndex().scanned,0)
        XCTAssertTrue(try store.searchResult(MemorySearchQuery(""),now:now).items.isEmpty)
        for n in 0..<125 { try seed(String(format:"filler%03d",n),title:"Recipe notebook \(n)",app:"Notes") }
        try seed("exact",title:"Garden sensor calibration",app:"TextEdit")
        try seed("older",title:"Garden sensor overview",app:"Safari",at:now.addingTimeInterval(-86400))
        let syncStart=Date()
        XCTAssertFalse(try store.syncSearchIndex().cycleComplete)
        XCTAssertTrue(try store.syncSearchIndex().cycleComplete)
        print("TYPESENSE real: indexed 127 synthetic documents in \(Int(Date().timeIntervalSince(syncStart)*1000))ms")
        XCTAssertEqual(try store.syncSearchIndex().upserted,0)
        let start=Date()
        let typo=try store.searchResult(MemorySearchQuery("calibraton"),now:now)
        XCTAssertEqual(typo.backend,"typesense"); XCTAssertEqual(typo.items.first?.id,"exact")
        print("TYPESENSE real: typo query \(Int(Date().timeIntervalSince(start)*1000))ms; expected first result exact")
        XCTAssertEqual(try store.searchResult(MemorySearchQuery("garden sensor calibration"),now:now).items.first?.id,"exact")
        XCTAssertEqual(try store.searchResult(MemorySearchQuery("garden",app:"Safari"),now:now).items.map(\.id),["older"])
        XCTAssertEqual(try store.searchResult(MemorySearchQuery("garden",start:now.addingTimeInterval(-3600),end:now.addingTimeInterval(1)),now:now).items.map(\.id),["exact"])
        let denied=try LocalTypesenseHTTP(config,sync:false).request("DELETE","/collections/"+config.collection,deadline:Date().addingTimeInterval(1))
        XCTAssertEqual(denied.status,401,"search key cannot delete or rebuild")
        server.stop()
        XCTAssertEqual(try store.searchResult(MemorySearchQuery("Garden"),now:now).status,"unavailable_fallback")
        try store.delete("exact")
        try server.start()
        XCTAssertFalse(try store.searchResult(MemorySearchQuery("calibraton"),now:now).items.contains { $0.id == "exact" })
        var removed=0
        for _ in 0..<3 { let r=try store.syncSearchIndex(); removed += r.deleted; if r.cycleComplete { break } }
        XCTAssertEqual(removed,1)
        _=try store.syncSearchIndex(rebuild:true)
        while !(try store.syncSearchIndex().cycleComplete) {}
        XCTAssertEqual(try store.searchResult(MemorySearchQuery("garden"),now:now).items.map(\.id),["older"])
        print("TYPESENSE real: restart, offline deletion, cleanup, rebuild, filters and restricted key passed")
    }

    func testIsolatedPreviewSetup() throws {
        XCTAssertEqual(store.searchSetupState().state,"local_runtime_setup_required")
        XCTAssertFalse(store.searchSetupState().verified)
        XCTAssertEqual(SyntheticTypesensePreview.runtimeState(executable:nil,expectedSHA256:nil),"typesense_runtime_missing")
        guard let binary=ProcessInfo.processInfo.environment["MACMEM_TYPESENSE_TEST_BINARY"] else { throw XCTSkip("Exact temporary Typesense binary required for preview setup") }
        let executable=URL(fileURLWithPath:binary)
        XCTAssertEqual(SyntheticTypesensePreview.runtimeState(executable:executable,expectedSHA256:nil),"typesense_runtime_pin_required")
        XCTAssertThrowsError(try SyntheticTypesensePreview.start(executable:executable,expectedSHA256:String(repeating:"0",count:64)))
        let hash=SHA256.hash(data:try Data(contentsOf:executable)).map{String(format:"%02x",$0)}.joined()
        let began=Date(), preview=try SyntheticTypesensePreview.start(executable:executable,expectedSHA256:hash)
        defer {preview.stop()}
        print("TYPESENSE preview startup and verified five-action index: \(Int(Date().timeIntervalSince(began)*1000))ms")
        XCTAssertTrue(preview.root.path.hasPrefix("/private/tmp/daydream-typesense-preview-"))
        XCTAssertFalse(preview.store.home == home)
        let pid=try XCTUnwrap(preview.testableOwnedPID)
        let listener=Process(), pipe=Pipe();listener.executableURL=URL(fileURLWithPath:"/usr/sbin/lsof")
        listener.arguments=["-nP","-a","-p",String(pid),"-iTCP","-sTCP:LISTEN","-Fn"]
        listener.standardOutput=pipe;listener.standardError=FileHandle.nullDevice
        try listener.run();let raw=pipe.fileHandleForReading.readDataToEndOfFile();listener.waitUntilExit()
        let addresses=String(decoding:raw,as:UTF8.self).split(separator:"\n").filter{$0.hasPrefix("n")}.map{String($0.dropFirst())}
        XCTAssertTrue(addresses.count >= 2)
        XCTAssertTrue(addresses.allSatisfy{$0.hasPrefix("127.0.0.1:")})
        XCTAssertEqual(preview.store.searchSetupState().state,"typesense_configured_unverified")
        XCTAssertFalse(preview.store.searchSetupState().verified)
        XCTAssertTrue(try preview.store.verifySearchSetup().verified)
        XCTAssertTrue(try preview.store.verifySearchSetup().syntheticOnly)
        let installed=try XCTUnwrap(TypesenseConfiguration.load(home:preview.store.home))
        XCTAssertTrue(installed.syntheticOnly == true)
        XCTAssertFalse(try installed.key(sync:true) == installed.key(sync:false))
        XCTAssertEqual(try LocalTypesenseHTTP(installed,sync:false).request("DELETE","/collections/"+installed.collection,deadline:Date().addingTimeInterval(1)).status,401)
        XCTAssertEqual(try LocalTypesenseHTTP(installed,sync:false).request("GET","/collections/unapproved/documents/search",query:[URLQueryItem(name:"q",value:"*")],deadline:Date().addingTimeInterval(1)).status,401)
        XCTAssertEqual(try LocalTypesenseHTTP(installed,sync:false).request("GET","/collections/"+installed.collection+"suffix/documents/search",query:[URLQueryItem(name:"q",value:"*")],deadline:Date().addingTimeInterval(1)).status,401)
        XCTAssertEqual(try LocalTypesenseHTTP(installed,sync:true).request("GET","/collections/"+installed.collection+"/documents/search",query:[URLQueryItem(name:"q",value:"*")],deadline:Date().addingTimeInterval(1)).status,401)
        let typo=try preview.store.searchResult(MemorySearchQuery("calibraton"))
        XCTAssertEqual(typo.backend,"typesense");XCTAssertEqual(typo.items.first?.id,"typesense-preview-0")
        let action=try XCTUnwrap(preview.store.action("typesense-preview-0"))
        _=try preview.store.correctAction(id:action.id,text:"Orchard precision benchmark",expectedRevision:action.revision)
        XCTAssertTrue(try preview.store.searchResult(MemorySearchQuery("calibraton")).items.isEmpty)
        _=try preview.reconcile()
        XCTAssertEqual(try preview.store.searchResult(MemorySearchQuery("benchmrk")).items.first?.id,action.id)
        _=try preview.store.ingest(Evidence(id:"fresh-preview",at:iso(Date()),kind:"window.changed",app:"Fixture",title:"Immediate unindexed comet",synthetic:true))
        XCTAssertEqual(try preview.store.searchResult(MemorySearchQuery("comet")).items.first?.id,"fresh-preview")
        try preview.store.delete(action.id)
        XCTAssertTrue(try preview.store.searchResult(MemorySearchQuery("benchmrk")).items.isEmpty)
        _=try preview.reconcile()
        var policy=try preview.store.policy();policy.blockedApps.append("com.apple.TextEdit");try preview.store.updatePolicy(policy)
        XCTAssertTrue(try preview.store.searchResult(MemorySearchQuery("recipe")).items.isEmpty)
        _=try preview.reconcile()
        // Deliberately false flag on fabricated content tests refusal of mixed
        // stores. This is not real capture or imported personal history.
        _=try preview.store.ingest(Evidence(id:"not-a-preview-event",at:iso(Date()),kind:"window.changed",app:"Fixture",title:"Fabricated nonpreview marker",synthetic:false))
        XCTAssertThrowsError(try preview.reconcile())
        try preview.store.delete("not-a-preview-event")
        _=try preview.reconcile()
        preview.stop();preview.stop()
        XCTAssertTrue(preview.testableOwnedPID == nil)
        let fallback=try preview.store.searchResult(MemorySearchQuery("comet"))
        XCTAssertEqual(fallback.backend,"sqlite");XCTAssertEqual(fallback.status,"unavailable_fallback")
        XCTAssertEqual(fallback.items.first?.id,"fresh-preview")
        XCTAssertFalse(try preview.store.verifySearchSetup().verified)
        XCTAssertThrowsError(try preview.reconcile())
        XCTAssertEqual(try preview.store.status()["capture"],"off")
        XCTAssertFalse(FileManager.default.fileExists(atPath:home.appendingPathComponent("search-typesense.json").path))
        print("TYPESENSE preview: real two-port loopback, scoped keys, typo search, corrections, exclusions, deletion, recent DB merge, mixed-store refusal and stop/fallback passed")
    }
}

private final class SyntheticServer {
    let binary:String; let home:URL; let port:Int; let peer:Int; let key=UUID().uuidString
    var process:Process?
    init(binary:String,home:URL) throws {
        self.binary=binary; self.home=home; port=try Self.freePort(); peer=try Self.freePort()
        try FileManager.default.createDirectory(at:home.appendingPathComponent("typesense"),withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    }
    static func freePort() throws -> Int {
        let fd=socket(AF_INET,SOCK_STREAM,0); guard fd >= 0 else { throw SearchFailure.unavailable }; defer { close(fd) }
        var address=sockaddr_in(); address.sin_family=sa_family_t(AF_INET); address.sin_addr.s_addr=inet_addr("127.0.0.1")
        let bound=withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw SearchFailure.unavailable }
        var size=socklen_t(MemoryLayout<sockaddr_in>.size)
        _=withUnsafeMutablePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(fd,$0,&size) } }
        return Int(UInt16(bigEndian:address.sin_port))
    }
    func start() throws {
        let p=Process(); p.executableURL=URL(fileURLWithPath:binary)
        p.arguments=["--data-dir",home.appendingPathComponent("typesense").path,"--api-address","127.0.0.1","--api-port",String(port),"--peering-address","127.0.0.1","--peering-port",String(peer),"--enable-cors=false","--enable-search-analytics=false","--enable-access-logging=false","--enable-search-logging=false","--log-slow-searches-time-ms=-1","--log-slow-requests-time-ms=-1"]
        p.environment=["PATH":"/usr/bin:/bin","TYPESENSE_API_KEY":key]
        p.standardOutput=FileHandle.nullDevice; p.standardError=FileHandle.nullDevice
        try p.run(); process=p
        let keyFile=home.appendingPathComponent("health.key")
        try Data(key.utf8).write(to:keyFile); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:keyFile.path)
        let config=TypesenseConfiguration(home:home,port:port,searchKeyFile:keyFile.path,syncKeyFile:keyFile.path,enabled:true)
        let client=LocalTypesenseHTTP(config,sync:true), deadline=Date().addingTimeInterval(20)
        while Date() < deadline, p.isRunning {
            if let r=try? client.request("GET","/health",deadline:Date().addingTimeInterval(0.2)), r.status == 200 { return }
            Thread.sleep(forTimeInterval:0.1)
        }
        stop(); throw SearchFailure.unavailable
    }
    func stop() {
        guard let p=process else { return }
        if p.isRunning { p.terminate() }
        let deadline=Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval:0.05) }
        if p.isRunning { kill(p.processIdentifier,SIGKILL) }
        p.waitUntilExit(); process=nil
    }
    func listeners() throws -> [String] {
        guard let process else { throw SearchFailure.unavailable }
        let probe=Process(), pipe=Pipe()
        probe.executableURL=URL(fileURLWithPath:"/usr/sbin/lsof")
        probe.arguments=["-nP","-a","-p",String(process.processIdentifier),"-iTCP","-sTCP:LISTEN","-Fn"]
        probe.standardOutput=pipe; probe.standardError=FileHandle.nullDevice
        try probe.run()
        let output=pipe.fileHandleForReading.readDataToEndOfFile(); probe.waitUntilExit()
        return String(decoding:output,as:UTF8.self).split(separator:"\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }
}
