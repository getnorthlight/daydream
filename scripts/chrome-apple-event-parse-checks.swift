// Synthetic, in-process check that every object specifier DayDream's Chrome
// reader builds is one Cocoa Scripting can parse, using a Chrome-shaped
// dictionary (scripts/fixtures/chrome-shaped.sdef). Chrome uses Cocoa
// Scripting, so this is the parser that would receive the specifiers.
// Nothing is sent: no Apple Event, no Chrome, no permission.
// Built and run by scripts/chrome-typing-checks.py (needs an embedded
// Info.plist with NSAppleScriptEnabled and the sdef next to the binary).
import AppKit
import MemoryCore

@objc(SyntheticChromeWindow) final class SyntheticChromeWindow: NSObject {}
@objc(SyntheticChromeTab) final class SyntheticChromeTab: NSObject {}

@main enum ChromeAppleEventParseChecks {
    static func check(_ condition: Bool, _ name: String) {
        guard condition else { print("FAILED: " + name); exit(1) }
        print("PASS: " + name)
    }
    static func describe(_ s: NSScriptObjectSpecifier?) -> String {
        guard let s else { return "nil" }
        let me = String(describing: type(of: s)) + "(" + s.key + ")"
        return s.container.map { _ in me + " of " + describe(s.container) } ?? me
    }
    static func main() {
        _ = NSApplication.shared
        check(NSScriptSuiteRegistry.shared().suiteNames.contains("Standard Suite"), "Chrome-shaped dictionary loaded")
        let code = ChromeAppleEvents.code
        func parse(_ d: NSAppleEventDescriptor?) -> String { describe(d.flatMap { NSScriptObjectSpecifier(descriptor: $0) }) }
        // The fixed front-window read (default build).
        check(parse(ChromeAppleEvents.specifier(.frontWindow, property: "ID  ")) == "NSPropertySpecifier(uniqueID) of NSIndexSpecifier(syntheticWindows)",
              "ID of first window parses (absolute ordinal)")
        if let index = ChromeAppleEvents.specifier(.frontWindow, property: "ID  ")
            .flatMap({ NSScriptObjectSpecifier(descriptor: $0)?.container as? NSIndexSpecifier }) {
            check(index.index == 0, "first window is index 0 of the ordered windows")
        } else { check(false, "first window is an index specifier") }
        // The old descriptor, for the record: Cocoa Scripting rejects it.
        let old = NSAppleEventDescriptor.record()
        old.setDescriptor(NSAppleEventDescriptor(typeCode: code("cwin")), forKeyword: code("want"))
        old.setDescriptor(NSAppleEventDescriptor(enumCode: code("indx")), forKeyword: code("form"))
        old.setDescriptor(NSAppleEventDescriptor(enumCode: code("firs")), forKeyword: code("seld"))
        old.setDescriptor(.null(), forKeyword: code("from"))
        check(parse(old.coerce(toDescriptorType: code("obj "))) == "nil", "previous enum 'firs' first-window descriptor is unparseable (reads always failed)")
        // The metadata probe's other reads (default build).
        let expected: [(BrowserTarget, String, String)] = [
            (.window("101"), "mode", "NSPropertySpecifier(mode) of NSUniqueIDSpecifier(syntheticWindows)"),
            (.activeTab("101"), "ID  ", "NSPropertySpecifier(uniqueID) of NSPropertySpecifier(activeTab) of NSUniqueIDSpecifier(syntheticWindows)"),
            (.tab("101", "7"), "pnam", "NSPropertySpecifier(title) of NSUniqueIDSpecifier(tabs) of NSUniqueIDSpecifier(syntheticWindows)"),
            (.tab("101", "7"), "URL ", "NSPropertySpecifier(URL) of NSUniqueIDSpecifier(tabs) of NSUniqueIDSpecifier(syntheticWindows)"),
        ]
        for (target, property, shape) in expected {
            check(parse(ChromeAppleEvents.specifier(target, property: property)) == shape, "\(target) \(property) parses as " + shape)
        }
        // Chrome page history's reads (default build).
        let page: [(ChromePageRequest, String)] = [
            (.windowIDs, "NSPropertySpecifier(uniqueID) of NSPropertySpecifier(syntheticWindows)"),
            (.mode("101"), "NSPropertySpecifier(mode) of NSUniqueIDSpecifier(syntheticWindows)"),
            (.activeTabID("101"), "NSPropertySpecifier(uniqueID) of NSPropertySpecifier(activeTab) of NSUniqueIDSpecifier(syntheticWindows)"),
            (.tabURL("101", "7"), "NSPropertySpecifier(URL) of NSUniqueIDSpecifier(tabs) of NSUniqueIDSpecifier(syntheticWindows)"),
            (.tabTitle("101", "7"), "NSPropertySpecifier(title) of NSUniqueIDSpecifier(tabs) of NSUniqueIDSpecifier(syntheticWindows)"),
        ]
        for (request, shape) in page { check(parse(request.specifier) == shape, "page \(request) parses as " + shape) }
        #if DAYDREAM_CHROME_TYPING
        let join: [(ChromeJoinRequest, String)] = [
            (.windowIDs, "NSPropertySpecifier(uniqueID) of NSPropertySpecifier(syntheticWindows)"),
            (.mode("101"), "NSPropertySpecifier(mode) of NSUniqueIDSpecifier(syntheticWindows)"),
            (.bounds("101"), "NSPropertySpecifier(boundsAsQDRect) of NSUniqueIDSpecifier(syntheticWindows)"),
            (.name("101"), "NSPropertySpecifier(title) of NSUniqueIDSpecifier(syntheticWindows)"),
            (.activeTabID("101"), "NSPropertySpecifier(uniqueID) of NSPropertySpecifier(activeTab) of NSUniqueIDSpecifier(syntheticWindows)"),
            (.tabURL("101", "7"), "NSPropertySpecifier(URL) of NSUniqueIDSpecifier(tabs) of NSUniqueIDSpecifier(syntheticWindows)"),
        ]
        for (request, shape) in join { check(parse(request.specifier) == shape, "join \(request) parses as " + shape) }
        #endif
        print("Chrome Apple Event parse checks: synthetic dictionary, in-process, nothing sent.")
    }
}
