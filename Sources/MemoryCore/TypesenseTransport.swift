import Foundation
import Darwin

public enum SearchFailure: Error, CustomStringConvertible {
    case unavailable, configuration, response, busy, changed
    public var description: String {
        switch self {
        case .unavailable: return "Local search index unavailable or deadline exceeded; SQLite search remains available."
        case .configuration: return "Local search configuration or private key file is invalid."
        case .response: return "Local index rejected a request or returned an invalid acknowledgement; sync remains retryable."
        case .busy: return "Another local index sync is active; try again later."
        case .changed: return "Memory, privacy or search configuration changed during this request; retry with fresh state."
        }
    }
}

/// No hostnames, redirects, proxies, external models, or implicit service startup.
public struct TypesenseConfiguration: Codable, Equatable {
    public var enabled: Bool
    public var port: Int
    public var collection: String
    public var searchKeyFile: String
    public var syncKeyFile: String
    /// Only dedicated disposable preview sessions set this. Missing means the
    /// existing normal-store policy; never enables indexing by itself.
    public var syntheticOnly: Bool? = nil
    public static func collection(for home: URL) -> String {
        "macmem_" + fingerprint(home.standardizedFileURL.resolvingSymlinksInPath().path).prefixString(20) + "_v1"
    }
    public init(home: URL, port: Int, searchKeyFile: String, syncKeyFile: String, enabled: Bool = false) {
        self.enabled = enabled; self.port = port; self.collection = Self.collection(for:home)
        self.searchKeyFile = searchKeyFile; self.syncKeyFile = syncKeyFile
    }
    public static func load(home: URL) throws -> Self? {
        let path = home.appendingPathComponent("search-typesense.json").path
        guard FileManager.default.fileExists(atPath:path) else { return nil }
        let config = try JSONDecoder().decode(Self.self, from:privateFile(path, limit:8192))
        guard config.enabled else { return nil }
        guard (1024...65535).contains(config.port), config.collection == collection(for:home),
              config.searchKeyFile != config.syncKeyFile else { throw SearchFailure.configuration }
        return config
    }
    func key(sync: Bool) throws -> String {
        let key = String(decoding:try Self.privateFile(sync ? syncKeyFile : searchKeyFile,limit:512),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        guard (24...256).contains(key.utf8.count), key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }) else { throw SearchFailure.configuration }
        return key
    }
    static func privateFile(_ path: String, limit: Int) throws -> Data {
        guard path.hasPrefix("/") else { throw SearchFailure.configuration }
        let fd = open(path,O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SearchFailure.configuration }; defer { close(fd) }
        var s = stat()
        guard fstat(fd,&s) == 0, s.st_uid == getuid(), s.st_mode & S_IFMT == S_IFREG,
              s.st_mode & 0o077 == 0, s.st_size >= 0, s.st_size <= limit else { throw SearchFailure.configuration }
        var bytes = [UInt8](repeating:0,count:limit+1)
        let count = Darwin.read(fd,&bytes,bytes.count)
        guard count >= 0, count <= limit else { throw SearchFailure.configuration }
        return Data(bytes.prefix(count))
    }
}

struct TypesenseResponse { let status: Int; let data: Data }
protocol TypesenseTransport {
    func request(_ method: String, _ path: String, query: [URLQueryItem], body: Data?, deadline: Date) throws -> TypesenseResponse
}

/// Blocking only on the search/index utility queue, never the capture or main queue.
final class LocalTypesenseHTTP: TypesenseTransport {
    let config: TypesenseConfiguration
    let sync: Bool
    init(_ config: TypesenseConfiguration, sync: Bool) { self.config=config; self.sync=sync }
    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, deadline: Date) throws -> TypesenseResponse {
        guard deadline.timeIntervalSinceNow > 0, (body?.count ?? 0) <= 512_000 else { throw SearchFailure.unavailable }
        var url = URLComponents(); url.scheme="http"; url.host="127.0.0.1"; url.port=config.port
        url.path=path; url.queryItems=query.isEmpty ? nil : query
        var request=URLRequest(url:url.url!); request.httpMethod=method; request.httpBody=body
        request.setValue(try config.key(sync:sync),forHTTPHeaderField:"X-TYPESENSE-API-KEY")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.timeoutInterval=max(0.01,deadline.timeIntervalSinceNow)
        let delegate=BoundedResponse()
        let options=URLSessionConfiguration.ephemeral
        options.connectionProxyDictionary=[:]; options.httpCookieStorage=nil; options.urlCache=nil
        options.timeoutIntervalForResource=request.timeoutInterval
        let session=URLSession(configuration:options,delegate:delegate,delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        let task=session.dataTask(with:request); task.resume()
        guard delegate.done.wait(timeout:.now()+max(0,deadline.timeIntervalSinceNow)) == .success else { task.cancel(); throw SearchFailure.unavailable }
        guard let response=delegate.result else { throw SearchFailure.unavailable }
        return response
    }
}

private final class BoundedResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let done=DispatchSemaphore(value:0)
    var data=Data(); var status=0; var failed=false; var result: TypesenseResponse?
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { failed=true; completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status=(response as? HTTPURLResponse)?.statusCode ?? 0
        if response.expectedContentLength > 256_000 { failed=true; completionHandler(.cancel) } else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        if data.count + bytes.count > 256_000 { failed=true; dataTask.cancel() } else { data.append(bytes) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error == nil && !failed { result=TypesenseResponse(status:status,data:data) }
        done.signal()
    }
}
