// Source-selected QA input only. No arbitrary text, URL navigation or submission APIs.
import Foundation
#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
struct BrowserCaptureScenario: Equatable {
    let id: String
    let text: String
    let origins: Set<String>
    let surface: String
    let fields: Set<String>
    let paths: [String]
    var pauseAfterKey: Int? = nil
    func allows(origin: String, documentURL: String, surface: String, field: String) -> Bool {
        guard origins.contains(origin), self.surface == surface, fields.contains(field),
              let u = URLComponents(string: documentURL), u.user == nil, u.password == nil, u.fragment == nil,
              let host = u.host, origin == "https://" + host, u.scheme == "https", u.port == nil else { return false }
        return paths.contains { prefix in u.path == prefix || (prefix != "/" && prefix.hasSuffix("/") && u.path.hasPrefix(prefix)) }
    }
    func storedMetadataMatches(surface: String?, field: String?, send: String?) -> Bool {
        surface == self.surface && fields.contains(field ?? "") && ["none", "unknown"].contains(send ?? "")
    }
    static let all: [BrowserCaptureScenario] = [
        .init(id:"x-search-v1", text:"chess club service event ideas", origins:["https://x.com"], surface:"search", fields:["search"], paths:["/home","/explore","/search"]),
        .init(id:"x-post-draft-v1", text:"thanks for the chess club support", origins:["https://x.com"], surface:"social", fields:["message","textArea"], paths:["/home","/compose/post"]),
        .init(id:"chatgpt-prompt-draft-v1", text:"help plan my morning study time", origins:["https://chatgpt.com"], surface:"ai", fields:["message","textArea","body"], paths:["/","/c/"]),
        .init(id:"x-post-interrupted-v1", text:"thanks for the chess club support", origins:["https://x.com"], surface:"social", fields:["message","textArea"], paths:["/home","/compose/post"], pauseAfterKey:15),
        .init(id:"chatgpt-prompt-interrupted-v1", text:"help plan my morning study time", origins:["https://chatgpt.com"], surface:"ai", fields:["message","textArea","body"], paths:["/","/c/"], pauseAfterKey:13),
        .init(id:"reddit-search-v1", text:"chess club service event ideas", origins:["https://www.reddit.com","https://reddit.com"], surface:"search", fields:["search"], paths:["/","/search/","/search"]),
        .init(id:"reddit-post-title-v1", text:"chess club service event", origins:["https://www.reddit.com","https://reddit.com"], surface:"social", fields:["oneLine","textArea"], paths:["/submit","/submit/"])
    ]
    static func named(_ id: String) -> BrowserCaptureScenario? { all.first { $0.id == id } }
    static let codes: [Character: UInt16] = [" ":49,"a":0,"b":11,"c":8,"d":2,"e":14,"f":3,"g":5,"h":4,"i":34,"j":38,"k":40,"l":37,"m":46,"n":45,"o":31,"p":35,"q":12,"r":15,"s":1,"t":17,"u":32,"v":9,"w":13,"x":7,"y":16,"z":6]
}
#endif
