import Foundation

/// fix/model-download: why one transfer ended early. Every case but `status` of a 4xx is worth another try.
public enum DownloadInterruption: Error, Equatable, Sendable {
    /// The server answered with this status (a refused redirect surfaces as its 3xx). `retryAfter` from the header.
    case status(Int, retryAfter: TimeInterval?)
    /// Asked to resume at `offset`, the server sent the whole file (200): the partial file starts over.
    case rangeIgnored
    /// A 206 whose Content-Range isn't the one asked for.
    case wrongRange
    /// The body ended before the whole file arrived.
    case shortBody
}

public enum AssetDownload {
    static func responseAllowed(status:Int, contentRange:String?, offset:Int64, total:Int64?) -> Bool {
        if offset == 0 {return status == 200}
        guard let total, offset > 0, offset < total else {return false}
        return status == 206 && contentRange == "bytes \(offset)-\(total-1)/\(total)"
    }
    /// Why a response that `responseAllowed` refused was refused.
    static func interruption(status:Int, offset:Int64, retryAfter:String?) -> DownloadInterruption {
        if offset > 0 && status == 200 {return .rangeIgnored}
        if status == 206 {return .wrongRange}
        return .status(status, retryAfter: retryAfter.flatMap {TimeInterval($0.trimmingCharacters(in:.whitespaces))})
    }
    /// Exact public artifact and reviewed delivery hosts only. Integrity remains byte/hash pinned.
    /// fix/model-download: Hugging Face hands the model to a regional CDN host (this Mac got `us.aws.cdn.hf.co`; other
    /// regions and its Xet bridge use other hosts under `hf.co`). A refused redirect stopped every download at once, so
    /// any HTTPS host of Hugging Face's own domains is allowed: the bytes are still checked for exact size and SHA-256.
    public static func redirectAllowed(from source: URL, to target: URL) -> Bool {
        guard target.scheme == "https", target.user == nil, target.password == nil,
              target.port == nil || target.port == 443 else {return false}
        if source == WriterCandidates.recommended?.asset.url {return target.host == "us.aws.cdn.hf.co" || huggingFaceHost(target.host)}
        if source == WriterCandidates.llamaARM64.url {return target.host == "release-assets.githubusercontent.com"}
        return false
    }
    static func huggingFaceHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty, !host.hasSuffix(".") else {return false}
        return host == "huggingface.co" || host == "hf.co" || host.hasSuffix(".hf.co") || host.hasSuffix(".huggingface.co")
    }
    /// fix/model-download: a failure that another try can get past: the network dropped or changed, the Mac slept, the
    /// server was busy (408, 425, 429, 5xx), a stall, or a body cut short. A 4xx, a refused redirect, a full disk and a
    /// wrong hash are not.
    public static func isTransient(_ error: Error) -> Bool {
        switch error {
        case let interruption as DownloadInterruption:
            switch interruption {
            case .status(let code, _): return code == 408 || code == 425 || code == 429 || (500...599).contains(code)
            case .rangeIgnored, .wrongRange, .shortBody: return true
            }
        case let url as URLError:
            let permanent: Set<URLError.Code> = [.badURL, .unsupportedURL, .userAuthenticationRequired, .userCancelledAuthentication,
                .fileDoesNotExist, .fileIsDirectory, .noPermissionsToReadFile, .dataLengthExceedsMaximum, .appTransportSecurityRequiresSecureConnection,
                .httpTooManyRedirects, .redirectToNonExistentLocation]
            return !permanent.contains(url.code)
        default:
            let ns = error as NSError
            // CFNetwork and socket errors that reach us unwrapped (a reset, a closed pipe, a dropped route).
            if ns.domain == kCFErrorDomainCFNetwork as String {return true}
            if ns.domain == NSPOSIXErrorDomain {
                return [ECONNRESET, ECONNABORTED, ENETDOWN, ENETUNREACH, ENETRESET, EHOSTDOWN, EHOSTUNREACH, ETIMEDOUT, EPIPE, ENOTCONN].map(Int.init).contains(ns.code)
            }
            return false
        }
    }
    /// The largest piece handed on at a time (PersistentModelCache writes each one).
    public static let chunkBytes = 1_048_576
    /// fix/sx-engine-battery: the body arrives through a data delegate in the pieces URLSession already has (no per-byte
    /// iteration and no actor hop per byte) and is handed on in pieces of at most 1 MB. There is no whole-transfer time
    /// limit (a slow 2.7 GB download used to stop at 30 minutes); a stall of 60 seconds ends this transfer, and
    /// PersistentModelCache tries again from the partial file (fix/model-download).
    public static func chunks(from url: URL, offset: Int64 = 0) async throws -> AsyncThrowingStream<Data, Error> {
        guard url.scheme == "https", url.user == nil, url.password == nil else {throw WriterFailure.denied}
        let total = url == WriterCandidates.recommended?.asset.url ? WriterCandidates.recommended?.asset.bytes : nil
        return try await transfer(from:url, offset:offset, total:total, stall:60)
    }
    /// One transfer. Checks reach it with a loopback `http` server and a short stall (fix/model-download); the app only
    /// through `chunks`, which requires HTTPS.
    static func transfer(from url: URL, offset: Int64, total: Int64?, stall: TimeInterval) async throws -> AsyncThrowingStream<Data, Error> {
        guard offset >= 0 else {throw WriterFailure.integrity}
        let config=URLSessionConfiguration.ephemeral
        config.urlCache=nil;config.httpCookieStorage=nil;config.urlCredentialStorage=nil
        config.timeoutIntervalForRequest=stall;config.timeoutIntervalForResource=7*24*3600
        config.waitsForConnectivity=false
        var request = URLRequest(url:url)
        request.setValue("identity", forHTTPHeaderField:"Accept-Encoding")
        if offset > 0 {request.setValue("bytes=\(offset)-", forHTTPHeaderField:"Range")}
        let pump = ChunkPump(source:url, offset:offset, total:total)
        let session = URLSession(configuration:config, delegate:pump, delegateQueue:pump.queue)
        let task = session.dataTask(with:request)
        return try await withTaskCancellationHandler(operation: {
            try await pump.start(task:task, session:session)
        }, onCancel: { task.cancel(); session.invalidateAndCancel() })
    }
}

/// One transfer: checks the response, then yields the body in pieces of at most `AssetDownload.chunkBytes`. Every
/// delegate call runs on the pump's own serial queue.
private final class ChunkPump: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.qualityOfService = .utility; return q }()
    private let source: URL, offset: Int64, total: Int64?
    private var redirects = 0
    private var buffer = Data()
    private var opened: CheckedContinuation<AsyncThrowingStream<Data, Error>, Error>?
    private var stream: AsyncThrowingStream<Data, Error>.Continuation?
    init(source: URL, offset: Int64, total: Int64?) { self.source = source; self.offset = offset; self.total = total }

    func start(task: URLSessionDataTask, session: URLSession) async throws -> AsyncThrowingStream<Data, Error> {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                self.opened = continuation
                task.resume()
            }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 3, let target = request.url, AssetDownload.redirectAllowed(from: source, to: target) else { completionHandler(nil); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse,
              AssetDownload.responseAllowed(status: http.statusCode, contentRange: http.value(forHTTPHeaderField: "Content-Range"), offset: offset, total: total) else {
            completionHandler(.cancel)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            opened?.resume(throwing: AssetDownload.interruption(status: status, offset: offset,
                retryAfter: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"))); opened = nil
            session.invalidateAndCancel()
            return
        }
        var made: AsyncThrowingStream<Data, Error>.Continuation?
        let body = AsyncThrowingStream<Data, Error>(bufferingPolicy: .unbounded) { made = $0 }
        guard let continuation = made else { completionHandler(.cancel); return }
        continuation.onTermination = { [weak session] reason in
            if case .cancelled = reason { dataTask.cancel(); session?.invalidateAndCancel() }
        }
        stream = continuation
        completionHandler(.allow)
        opened?.resume(returning: body); opened = nil
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while buffer.count >= AssetDownload.chunkBytes {
            stream?.yield(Data(buffer.prefix(AssetDownload.chunkBytes)))
            buffer = Data(buffer.dropFirst(AssetDownload.chunkBytes))
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let opened { opened.resume(throwing: error ?? WriterFailure.unavailable); self.opened = nil }
        if !buffer.isEmpty { stream?.yield(buffer); buffer = Data() }
        if let error { stream?.finish(throwing: error) } else { stream?.finish() }
        stream = nil
        session.finishTasksAndInvalidate()
    }
}
