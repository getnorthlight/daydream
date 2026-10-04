import Foundation
import MemoryCore

/// No redirects, cookies, credentials or non-HTTPS execution, and no URL query beyond what a page link keeps
/// (page-links-1003: `BrowserSites.pageLink`, a YouTube video's v, t and list). Called only by explicit Open original,
/// never by display or search. A fragment is never sent: the answer is compared with the address without it.
final class OriginalHEADVerifier:NSObject,OriginalSourceVerifier,URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {completionHandler(nil)}
    func urlSession(_ session:URLSession,task:URLSessionTask,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {completionHandler(.performDefaultHandling,nil)}
        else {completionHandler(.cancelAuthenticationChallenge,nil)}
    }
    func verify(url:String,deadline:Date) throws -> OriginalSourceCheck {
        guard let parts=URLComponents(string:url),parts.scheme=="https",parts.query==nil || BrowserSites.pageLink(url) == url,parts.port==nil,
              let host=parts.host,host.contains("."),!host.hasSuffix(".local"),!host.hasSuffix(".localhost"),
              host.range(of:"^[0-9.:]+$",options:.regularExpression)==nil,
              let target=Self.withoutFragment(parts).url else {return OriginalSourceCheck(url:url,exists:false,readOnly:true)}
        let asked=target.absoluteString
        let config=URLSessionConfiguration.ephemeral;config.httpCookieStorage=nil;config.urlCredentialStorage=nil;config.urlCache=nil
        config.timeoutIntervalForRequest=max(0.1,min(1.5,deadline.timeIntervalSinceNow));config.timeoutIntervalForResource=1.5
        let session=URLSession(configuration:config,delegate:self,delegateQueue:nil)
        defer {session.invalidateAndCancel()}
        var request=URLRequest(url:target,cachePolicy:.reloadIgnoringLocalCacheData);request.httpMethod="HEAD"
        let gate=DispatchSemaphore(value:0),lock=NSLock();var verified=false
        let task=session.dataTask(with:request) {_,response,error in
            lock.lock();defer {lock.unlock();gate.signal()}
            // fix/show-all (owner, test 7: "Couldn't open the original." on an x.com page): the answer is for this address
            // (a bare "https://x.com" answers as "https://x.com/"), and a site that answers a cookieless HEAD with a redirect
            // it isn't followed to, or with "sign in", "not this method" or "slow down", has the page; only no answer, a
            // server error or "not found" / "gone" keeps it closed.
            if let response=response as? HTTPURLResponse {
                verified=error==nil && Self.sameAddress(response.url?.absoluteString,asked) && Self.exists(response.statusCode)
            }
        }
        task.resume();let completed=gate.wait(timeout:.now()+max(0,min(1.6,deadline.timeIntervalSinceNow))) == .success
        task.cancel();lock.lock();defer {lock.unlock()}
        return OriginalSourceCheck(url:url,exists:completed && verified,readOnly:true)
    }
    static func sameAddress(_ answered:String?,_ asked:String) -> Bool {
        guard let answered else {return false}
        func bare(_ s:String) -> String {s.hasSuffix("/") ? String(s.dropLast()) : s}
        return answered == asked || bare(answered) == bare(asked)
    }
    static func withoutFragment(_ parts:URLComponents) -> URLComponents { var bare=parts;bare.fragment=nil;return bare }
    static func exists(_ status:Int) -> Bool {(200..<400).contains(status) || [401,403,405,429].contains(status)}
}
