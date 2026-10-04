import Foundation
var count = 0
func check(_ b: Bool, _ reason: String) { guard b else { fatalError(reason) }; count += 1 }
let all = BrowserCaptureScenario.all
check(Set(all.map(\.id)).count == all.count, "unique closed IDs")
check(BrowserCaptureScenario.named("arbitrary-input") == nil, "unknown scenario")
for s in all {
    check(s.text.count <= 35 && !s.text.isEmpty && s.text.allSatisfy { BrowserCaptureScenario.codes[$0] != nil }, "bounded exact keymap")
    if let b = s.pauseAfterKey { check(b > 0 && b < s.text.count && String(s.text.prefix(b)) + String(s.text.dropFirst(b)) == s.text, "nonempty exact interruption parts") }
    check(!s.text.contains("\n") && !s.text.contains("\r") && !s.text.contains("\t"), "no Return or navigation keys")
    let field = s.fields.sorted()[0]
    check(s.storedMetadataMatches(surface:s.surface,field:field,send:"none"), "unsent none")
    check(s.storedMetadataMatches(surface:s.surface,field:field,send:"unknown"), "unsent unknown honest")
    check(!s.storedMetadataMatches(surface:s.surface,field:field,send:"detected"), "submitted false")
    check(!s.storedMetadataMatches(surface:s.surface,field:"unknown",send:"none"), "wrong field")
    check(!s.storedMetadataMatches(surface:nil,field:field,send:"none"), "missing metadata")
}
let x = BrowserCaptureScenario.named("x-search-v1")!
check(x.allows(origin:"https://x.com",documentURL:"https://x.com/home",surface:"search",field:"search"), "real search path")
check(!x.allows(origin:"https://x.com",documentURL:"https://x.com/home",surface:"social",field:"message"), "draft is not search")
check(!x.allows(origin:"https://x.com",documentURL:"https://x.com/settings",surface:"search",field:"search"), "wrong document")
check(!x.allows(origin:"https://x.com",documentURL:"https://user@x.com/home",surface:"search",field:"search"), "credentials refuse")
check(!x.allows(origin:"https://x.com",documentURL:"https://x.com/home#secret",surface:"search",field:"search"), "fragment refuses")
check(!x.allows(origin:"https://x.com",documentURL:"https://x.com:443/home",surface:"search",field:"search"), "alternate port refuses")
let g = BrowserCaptureScenario.named("chatgpt-prompt-draft-v1")!
check(g.allows(origin:"https://chatgpt.com",documentURL:"https://chatgpt.com/c/qa-thread",surface:"ai",field:"message"), "known thread")
check(!g.allows(origin:"https://chatgpt.com",documentURL:"https://chatgpt.com/auth/login",surface:"ai",field:"message"), "root path not wildcard")
let manifest = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
let cases = manifest["cases"] as! [[String:Any]]
check(cases.count == all.count, "manifest count")
for s in all { let c=cases.first { $0["id"] as? String == s.id }!; check(c["text"] as? String == s.text && c["surface"] as? String == s.surface && Set(c["fields"] as! [String]) == s.fields && c["actualRun"] as? String == "not-run", "manifest parity and truthful coverage") }
print("browser-capture-scenario controls PASS \(count); no browser/input")
