import Foundation
import CryptoKit
import Darwin

/// Setup state is separate from an enabled flag. A successful authenticated
/// query through the production source-revalidating path is required for ready.
public struct LocalSearchReadiness: Codable, Equatable {
    public var backend: String
    public var state: String
    public var verified: Bool
    public var syntheticOnly: Bool
}
extension MemoryStore {
    /// No network, credential read, process start or indexing. Appropriate for
    /// startup labels; it cannot return verified or claim Typesense is enabled.
    public func searchSetupState() -> LocalSearchReadiness {
        do {
            guard let configuration = try TypesenseConfiguration.load(home: home) else {
                return LocalSearchReadiness(backend: "sqlite", state: "local_runtime_setup_required", verified: false, syntheticOnly: false)
            }
            return LocalSearchReadiness(backend: "sqlite", state: "typesense_configured_unverified", verified: false, syntheticOnly: configuration.syntheticOnly == true)
        } catch {
            return LocalSearchReadiness(backend: "sqlite", state: "invalid_private_configuration", verified: false, syntheticOnly: false)
        }
    }
    /// Run off the UI thread on explicit setup/preview, using this store's same
    /// search path as the app, CLI and MCP. No bootstrap/admin key is used here.
    public func verifySearchSetup() throws -> LocalSearchReadiness {
        let result = try searchResult(MemorySearchQuery("", limit: 1))
        return LocalSearchReadiness(backend: result.backend, state: result.status,
            verified: result.backend == "typesense" && result.status == "ready",
            syntheticOnly: (try? TypesenseConfiguration.load(home: home))?.syntheticOnly == true)
    }
}

/// An explicit, disposable DEV PREVIEW, not a production install or personal
/// indexing permission. Always creates a NEW private temporary store and server.
/// Never attaches to an existing endpoint or changes DevelopmentTrial guards.
/// App retains the session while previewing, and stops it when the preview closes.
public final class SyntheticTypesensePreview {
    public let root: URL
    public let store: MemoryStore
    public let port: Int
    public let peerPort: Int
    private var process: Process?
    private let lock = NSLock()
    private var stopped = false
    var testableOwnedPID: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    public static func runtimeState(executable: URL?, expectedSHA256: String?) -> String {
        guard let executable else { return "typesense_runtime_missing" }
        guard let expectedSHA256 else { return "typesense_runtime_pin_required" }
        return (try? validateRuntime(executable, hash: expectedSHA256)) != nil ? "typesense_runtime_available_not_started" : "typesense_runtime_invalid"
    }
    private static func validateRuntime(_ executable: URL, hash: String) throws {
        let attr = try FileManager.default.attributesOfItem(atPath: executable.path)
        guard let size = attr[.size] as? NSNumber, (1...180_000_000).contains(size.intValue),
              attr[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isExecutableFile(atPath: executable.path),
              SHA256.hash(data: try Data(contentsOf: executable)).map({String(format:"%02x", $0)}).joined() == hash else { throw SearchFailure.configuration }
    }
    /// Fixed sample data only. The runtime is supplied by the build/test owner,
    /// never downloaded, discovered from personal PATH or installed by this API.
    public static func start(executable: URL, expectedSHA256: String) throws -> SyntheticTypesensePreview {
        let session = try SyntheticTypesensePreview()
        do {
            try session.activate(executable:executable, expectedSHA256:expectedSHA256,
                                 deadline:Date().addingTimeInterval(20), cancelled:{false}, indexing:{})
            return session
        }
        catch { session.stop(); throw error }
    }
    /// Prepares only a new synthetic SQLite store. No runtime/config/keys or
    /// network yet, so fallback/recent reads exist before initial indexing.
    public static func prepare() throws -> SyntheticTypesensePreview { try SyntheticTypesensePreview() }
    private init() throws {
        root = URL(fileURLWithPath: "/private/tmp/daydream-typesense-preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        store = try MemoryStore(home: root.appendingPathComponent("memory"), writable: true, automaticallySyncSearch: false)
        port = try Self.freePort()
        var peer = try Self.freePort(); while peer == port { peer = try Self.freePort() }; peerPort = peer
        for (i,title) in ["Garden sensor calibration", "Recipe notebook", "Research comparison", "Trip packing checklist", "Draft planning notes"].enumerated() {
            _ = try store.ingest(Evidence(id:"typesense-preview-\(i)",at:iso(Date().addingTimeInterval(-60)),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:title,synthetic:true))
        }
    }
    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw SearchFailure.unavailable }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw SearchFailure.unavailable }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }) == 0 else { throw SearchFailure.unavailable }
        return Int(UInt16(bigEndian: address.sin_port))
    }
    private func privateWrite(_ path: URL, _ data: Data) throws {
        // All files are new, inside this object's random owner-only directory.
        let fd = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SearchFailure.configuration }; defer { close(fd) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(fd) == 0 else { throw SearchFailure.configuration }
    }
    func activate(executable: URL, expectedSHA256: String, deadline: Date,
                  cancelled: () -> Bool, indexing: () -> Void) throws {
        func check() throws {
            guard !cancelled(), Date() < deadline else { throw SearchFailure.unavailable }
        }
        try check()
        try Self.validateRuntime(executable,hash:expectedSHA256)
        try check()
        let data = root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        let bootstrap = UUID().uuidString + UUID().uuidString
        let keyFile = root.appendingPathComponent("bootstrap.key")
        try privateWrite(keyFile, Data(bootstrap.utf8))
        let child = Process(); child.executableURL = executable
        child.arguments = ["--data-dir",data.path,"--api-address","127.0.0.1","--api-port",String(port),
            "--peering-address","127.0.0.1","--peering-port",String(peerPort),
            "--enable-cors=false","--enable-search-analytics=false","--enable-access-logging=false",
            "--enable-search-logging=false","--log-slow-searches-time-ms=-1","--log-slow-requests-time-ms=-1"]
        child.environment = ["PATH":"/usr/bin:/bin", "TYPESENSE_API_KEY":bootstrap]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice; child.standardInput = FileHandle.nullDevice
        lock.lock()
        do {
            guard !stopped, process == nil else { throw SearchFailure.unavailable }
            try check(); try child.run(); process = child; lock.unlock()
        } catch { lock.unlock(); throw error }
        let bootstrapConfig = TypesenseConfiguration(home:store.home,port:port,searchKeyFile:keyFile.path,syncKeyFile:keyFile.path)
        let admin = LocalTypesenseHTTP(bootstrapConfig, sync:true)
        var healthy = false
        while Date() < deadline && child.isRunning {
            try check()
            if let result = try? admin.request("GET", "/health", deadline:min(deadline,Date().addingTimeInterval(0.2))), result.status == 200 { healthy = true; break }
            Thread.sleep(forTimeInterval:0.05)
        }
        guard healthy, child.isRunning else { throw SearchFailure.unavailable }
        let searchFile=root.appendingPathComponent("search.key"), syncFile=root.appendingPathComponent("sync.key")
        var config=TypesenseConfiguration(home:store.home,port:port,searchKeyFile:searchFile.path,syncKeyFile:syncFile.path,enabled:true)
        config.syntheticOnly = true
        func mint(_ actions: [String]) throws -> String {
            try check()
            let payload:[String:Any] = ["description":"daydream synthetic preview only", "actions":actions,
                "collections":["^"+config.collection+"$"],"expires_at":Int(Date().timeIntervalSince1970)+3600]
            let response=try admin.request("POST","/keys",body:JSONSerialization.data(withJSONObject:payload),deadline:min(deadline,Date().addingTimeInterval(2)))
            guard response.status == 201, let value=(try JSONSerialization.jsonObject(with:response.data) as? [String:Any])?["value"] as? String,
                  (24...256).contains(value.utf8.count) else { throw SearchFailure.response }
            return value
        }
        // Successful mint also proves authentication to this fresh keyed child;
        // an unrelated pre-existing server cannot satisfy the bootstrap request.
        try privateWrite(searchFile, Data(try mint(["documents:search"]).utf8))
        try privateWrite(syncFile, Data(try mint(["collections:get","collections:create","collections:delete","documents:import","documents:delete"]).utf8))
        try check()
        try privateWrite(store.home.appendingPathComponent("search-typesense.json"), JSONEncoder().encode(config))
        indexing()
        repeat {
            try check()
            let page = try store.syncSearchIndex()
            if page.cycleComplete { break }
        } while true
        try check()
        guard try store.verifySearchSetup().verified else { throw SearchFailure.response }
        try check()
    }
    /// One bounded page, on a utility queue. Existing capture/index scheduling is
    /// untouched; a preview UI calls this after fixture corrections/deletions.
    @discardableResult public func reconcile() throws -> SearchSyncResult {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, process?.isRunning == true else { throw SearchFailure.unavailable }
        return try store.syncSearchIndex()
    }
    /// Stops only our owned child. Keeps disposable data for debugging; no broad
    /// cleanup, persistent service, launch agent, or other collector is touched.
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }; stopped=true
        guard let child=process else { return }
        if child.isRunning { child.terminate() }
        let until=Date().addingTimeInterval(2)
        while child.isRunning && Date() < until { Thread.sleep(forTimeInterval:0.02) }
        if child.isRunning { kill(child.processIdentifier,SIGKILL) }
        process=nil
    }
    deinit { stop() }
}
