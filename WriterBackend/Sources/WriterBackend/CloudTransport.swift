import Foundation
import Security
import LocalAuthentication

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public enum CloudTransport {
    /// Only invoked by a separately enabled CloudWriter. Never used by local mode.
    public static func send(_ request: URLRequest) async throws -> CloudHTTPResponse {
        guard request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions", request.httpMethod == "POST" else { throw WriterFailure.denied }
        let config=URLSessionConfiguration.ephemeral
        config.urlCache=nil;config.httpCookieStorage=nil;config.urlCredentialStorage=nil
        config.timeoutIntervalForRequest=30;config.timeoutIntervalForResource=35
        let session=URLSession(configuration:config,delegate:NoRedirects(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        // fix/sx-engine-battery: one read of the whole (small) reply instead of a loop per byte. A reply over 128 KB is
        // refused, as before.
        let (data,response)=try await session.data(for:request)
        guard let http=response as? HTTPURLResponse else { throw WriterFailure.unavailable }
        guard data.count <= 131072 else { throw WriterFailure.invalidOutput }
        return CloudHTTPResponse(status:http.statusCode,body:data)
    }
}
/// No read occurs at construction. No enumerating accounts or persisted JSON key.
public struct WriterKeychain: Sendable {
    /// Keychain service of the OpenRouter key. Builds up to build 4 used "MacMem.Writer.OpenRouter";
    /// that item is not read or copied (it belongs to the old app, and reading it would ask for
    /// your password), so after the rename the key is pasted once more.
    public static let service = "DayDream.Writer.OpenRouter"
    public static let legacyService = "MacMem.Writer.OpenRouter"
    public init() {}
    public func read() throws -> String {
        var result: CFTypeRef?
        let context=LAContext();context.interactionNotAllowed=true
        let status=SecItemCopyMatching([kSecClass:kSecClassGenericPassword,kSecAttrService:WriterKeychain.service,kSecAttrAccount:"owner",kSecReturnData:true,kSecMatchLimit:kSecMatchLimitOne,kSecUseAuthenticationContext:context] as CFDictionary,&result)
        guard status == errSecSuccess, let data=result as? Data, let key=String(data:data,encoding:.utf8) else { throw WriterFailure.unavailable }
        return key
    }
}
