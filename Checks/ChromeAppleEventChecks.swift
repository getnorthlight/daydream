import Foundation
import MemoryCore

/// Default build: the Apple Event allowlist and the first-window descriptor fix.
/// Synthetic only; nothing here sends an Apple Event.
func runChromeAppleEventChecks() throws {
    let code=ChromeAppleEvents.code
    try check(ChromeAppleEvents.readableProperties == ["mode","ID  ","pbnd","pnam","URL ","acTa"],"Apple Event allowlist is exactly mode, ID, pbnd, pnam, URL, acTa")
    try check(ChromeAppleEvents.permits(eventClass:"core",eventID:"getd"),"core/getd is permitted")
    for (eventClass,eventID) in [("core","setd"),("core","crel"),("core","delo"),("core","clos"),("aevt","quit"),("aevt","odoc"),("GURL","GURL"),("misc","dosc"),("CrSu","exec"),("core","getd ")] {
        try check(!ChromeAppleEvents.permits(eventClass:eventClass,eventID:eventID),"only core/getd may be sent, not "+eventClass+"/"+eventID)
    }
    // Descriptor fix: AppleScript's "first window" is an absolute ordinal.
    let front=ChromeAppleEvents.specifier(.frontWindow,property:"ID  ")
    let firstSeld=front?.forKeyword(code("from"))?.forKeyword(code("seld"))
    var firs=code("firs")
    try check(firstSeld?.descriptorType == code("abso") && firstSeld?.data == Data(bytes:&firs,count:4),"first window is typeAbsoluteOrdinal 'firs', not enum 'firs'")
    for property in ["mode","pnam","pbnd","URL ","acTa"] {
        try check(ChromeAppleEvents.specifier(.frontWindow,property:property) == nil,"first window is addressed only for its ID: "+property)
    }
    // Every target/property pair: built only when allowlisted, and always audited.
    let expected:[(BrowserTarget,Set<String>)]=[(.frontWindow,["ID  "]),(.window("101"),["mode","ID  ","pbnd","pnam"]),
                                               (.activeTab("101"),["ID  ","pnam","URL "]),(.tab("101","7"),["ID  ","pnam","URL "])]
    let candidates=["mode","ID  ","pbnd","pnam","URL ","acTa","pURL","pidx","GNam","pvis","pmnd","conT","exec","pALL","docu","sele","vers","prfl","pcnt","ptit"]
    for (target,allowed) in expected {
        for property in candidates {
            let built=ChromeAppleEvents.specifier(target,property:property)
            try check((built != nil) == allowed.contains(property),"specifier for \(target) \(property) exists only when allowlisted")
            if let built { try check(ChromeAppleEvents.audit(built),"built specifier passes the audit: \(target) \(property)") }
        }
    }
    for bad in ["","  ",String(repeating:"9",count:81),"1\n2"] {
        try check(ChromeAppleEvents.specifier(.window(bad),property:"mode") == nil,"invalid window ID refused")
        try check(ChromeAppleEvents.specifier(.tab("101",bad),property:"URL ") == nil,"invalid tab ID refused")
    }
    // The audit rejects forged shapes the builder never makes.
    func object(_ want:String,_ form:String,_ seld:NSAppleEventDescriptor,_ from:NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let r=NSAppleEventDescriptor.record()
        r.setDescriptor(NSAppleEventDescriptor(typeCode:code(want)),forKeyword:code("want"))
        r.setDescriptor(NSAppleEventDescriptor(enumCode:code(form)),forKeyword:code("form"))
        r.setDescriptor(seld,forKeyword:code("seld")); r.setDescriptor(from,forKeyword:code("from"))
        return r.coerce(toDescriptorType:code("obj "))!
    }
    func prop(_ name:String,_ of:NSAppleEventDescriptor) -> NSAppleEventDescriptor { object("prop","prop",NSAppleEventDescriptor(typeCode:code(name)),of) }
    let window=object("cwin","ID  ",NSAppleEventDescriptor(string:"101"),.null())
    var all=code("all ")
    let every=object("cwin","indx",NSAppleEventDescriptor(descriptorType:code("abso"),bytes:&all,length:4)!,.null())
    let oldFirst=object("cwin","indx",NSAppleEventDescriptor(enumCode:code("firs")),.null())
    let forged:[(String,NSAppleEventDescriptor)]=[
        ("execute-like property",prop("exec",window)),("page text",prop("conT",window)),("given name",prop("GNam",window)),
        ("old enum first window",prop("ID  ",oldFirst)),("application name",prop("pnam",.null())),
        ("mode of every window",prop("mode",every)),("name of every window",prop("pnam",every)),
        ("URL of a window",prop("URL ",window)),("active tab reference itself",prop("acTa",window)),
        ("tab of first window",prop("URL ",object("CrTb","ID  ",NSAppleEventDescriptor(string:"7"),object("cwin","indx",NSAppleEventDescriptor(descriptorType:code("abso"),bytes:&firs,length:4)!,.null())))),
        ("every tab",prop("URL ",object("CrTb","indx",NSAppleEventDescriptor(descriptorType:code("abso"),bytes:&all,length:4)!,window))),
        ("integer window ID",prop("mode",object("cwin","ID  ",NSAppleEventDescriptor(int32:101),.null()))),
        ("bookmark folder",prop("pnam",object("CrBF","ID  ",NSAppleEventDescriptor(string:"1"),.null()))),
        ("whose clause",prop("mode",object("cwin","test",NSAppleEventDescriptor(string:"x"),.null()))),
        ("mode of active tab",prop("mode",prop("acTa",window))),
        ("plain string",NSAppleEventDescriptor(string:"mode of window 1")),
    ]
    for (name,descriptor) in forged { try check(!ChromeAppleEvents.audit(descriptor),"audit refuses "+name) }
    try check(ChromeAppleEvents.audit(prop("mode",window)) && ChromeAppleEvents.audit(prop("ID  ",every)),"audit accepts the builder's own shapes")
    // Page history's whole vocabulary maps to audited specifiers: every request
    // of a full probe builds one, and the count is exact (no extra reads).
    for (url,expected) in [("https://example.org/notes",9),("https://www.bing.com/search?q=x",8)] {
        var built=0
        let result=ChromePageProbe.read(userBlocked:[]) { request in
            guard let s=request.specifier,ChromeAppleEvents.audit(s) else { return nil }
            built += 1
            switch request {
            case .windowIDs: return .ids(["101"])
            case .mode: return .text("normal")
            case .activeTabID: return .text("7")
            case .tabTitle: return .text("Synthetic")
            case .tabURL: return .text(url)
            }
        }
        if case .page = result {} else { try check(false,"page history: the audited probe reads a page") }
        try check(built == expected,"page history: every request of a \(expected == 9 ? "record" : "site-only") probe is an audited allowlisted specifier (\(expected) requests)")
    }
    let requests:[(ChromePageRequest,BrowserTarget,String)]=[(.mode("101"),.window("101"),"mode"),(.activeTabID("101"),.activeTab("101"),"ID  "),
                                                               (.tabURL("101","7"),.tab("101","7"),"URL "),(.tabTitle("101","7"),.tab("101","7"),"pnam")]
    for (request,target,property) in requests {
        try check(request.specifier == ChromeAppleEvents.specifier(target,property:property),"page history: \(request) is the allowlisted \(property) specifier")
    }
    try check(ChromePageRequest.windowIDs.specifier.map { ChromeAppleEvents.audit($0) } == true,"page history: the window list is the audited ID of every window")
    for bad in ["","1 2",String(repeating:"9",count:81)] {
        try check(ChromePageRequest.mode(bad).specifier == nil && ChromePageRequest.tabURL("101",bad).specifier == nil && ChromePageRequest.tabTitle(bad,"7").specifier == nil,
                  "page history: an invalid window or tab ID builds no request")
    }
}
