import Foundation

public struct OriginalSourceCheck {
    public var url:String
    public var exists:Bool
    public var readOnly:Bool
    public init(url:String,exists:Bool,readOnly:Bool) { self.url=url; self.exists=exists; self.readOnly=readOnly }
}
public protocol OriginalSourceVerifier {
    /// Caller-owned safe existence check. No navigation or resolver is supplied
    /// by core. Exact URL must be checked, never inferred from a page title.
    func verify(url:String,deadline:Date) throws -> OriginalSourceCheck
}
public struct OriginalSourceLink:Codable {
    public var actionID:String
    public var url:String?
    public var status:String
    public var sourceRevision:String
    public var verifiedAt:String?
}
extension MemoryStore {
    public func originalSourceLink(actionID:String,verifier:(any OriginalSourceVerifier)?=nil,now:Date=Date()) throws -> OriginalSourceLink {
        let epoch=try actionReadEpoch()
        guard let original=try permittedOriginal(actionID,now:now), let action=try action(actionID,now:now) else { throw MemError.denied }
        func unavailable(_ status:String) -> OriginalSourceLink { OriginalSourceLink(actionID:actionID,url:nil,status:status,sourceRevision:action.revision,verifiedAt:nil) }
        // fix/show-all: a Chrome page opens its own link (kept on this Mac, `Evidence.page`) when it has one on the row's
        // site, else the site; either passes every check below. page-links-1003: the link may carry what
        // `BrowserSites.pageLink` keeps (a YouTube video's v, t and list; a plain section anchor), nothing else.
        let site=URLComponents(string:original.url)?.host?.lowercased()
        let link=original.page.flatMap { BrowserSites.pageLink($0) }.flatMap { URLComponents(string:$0)?.host?.lowercased() == site && site != nil ? $0 : nil }
        let target=link ?? original.url
        guard let url=URLComponents(string:target), ["https","http"].contains(url.scheme?.lowercased() ?? ""),
              let host=url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil || link != nil,
              url.path.range(of:"(?i)(^|/)(send|delete|remove|logout|approve|publish|invite|unsubscribe)(/|$)",options:.regularExpression) == nil,
              target != original.url || !Privacy.secret(target), !PreCapturePrivacy.websiteDenied(target,settings:try policy()) else { return unavailable("original_source_link_unavailable_or_unsafe") }
        guard let verifier else { return unavailable("original_url_needs_existence_verification") }
        let deadline=Date().addingTimeInterval(2)
        let result=try verifier.verify(url:target,deadline:deadline)
        guard Date() <= deadline, result.url == target, result.exists, result.readOnly else { return unavailable("original_source_not_verified") }
        guard try epoch == actionReadEpoch(), try self.action(actionID,now:now)?.revision == action.revision else { throw MemError.invalid("Original source changed during verification") }
        return OriginalSourceLink(actionID:actionID,url:target,status:"verified_read_only_source",sourceRevision:action.revision,verifiedAt:iso(now))
    }
}
