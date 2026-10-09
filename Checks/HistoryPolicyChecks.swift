// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// Portions of this file are derived from open-codex-computer-history
// (https://github.com/hqhq1025/open-codex-computer-history),
// Copyright (c) 2026 Open Codex Computer History contributors, used under the
// MIT License. The full MIT notice is in THIRD-PARTY-NOTICES.md.

import Foundation
import HistoryCore

// The HistoryCore observation policy, typing buffer and message framing. Ported from the swift-testing suites in
// Tests/HistoryCoreTests (FrameTests, PolicyTests, TextBufferTests: 20 tests), which no runner ran because the package
// has no test target; each test is one or more named checks here.
func runHistoryPolicyChecks() throws {
    try runFrameChecks()
    try runObservationPolicyChecks()
    try runTextBufferChecks()
}

private func runFrameChecks() throws {
    let framed = Frame.encode(Data([0xAA, 0xBB, 0xCC]))
    try check(Array(framed.prefix(4)) == [3, 0, 0, 0], "frame: encode writes a little-endian length prefix")
    try check(Array(framed.suffix(3)) == [0xAA, 0xBB, 0xCC], "frame: encode keeps the payload after the prefix")

    var single = Frame.Parser()
    let hello = Data("hello".utf8)
    try check(try single.push(Frame.encode(hello)) == [hello], "frame: the parser round-trips a single frame")

    var multi = Frame.Parser()
    var chunk = Data()
    chunk.append(Frame.encode(Data("one".utf8)))
    chunk.append(Frame.encode(Data("two".utf8)))
    try check(try multi.push(chunk).map { String(decoding: $0, as: UTF8.self) } == ["one", "two"],
              "frame: the parser splits two frames in one chunk")

    var fragmented = Frame.Parser()
    let whole = Frame.encode(Data("fragmented".utf8))
    try check(try fragmented.push(whole.prefix(3)) == [], "frame: part of the length yields nothing")
    try check(try fragmented.push(whole.dropFirst(3).prefix(4)) == [], "frame: part of the body yields nothing")
    try check(try fragmented.push(whole.dropFirst(7)).map { String(decoding: $0, as: UTF8.self) } == ["fragmented"],
              "frame: the remainder completes the fragmented frame")

    var oversize = Frame.Parser()
    var header = Data()
    var big = UInt32(Frame.maxFrameBytes + 1).littleEndian
    withUnsafeBytes(of: &big) { header.append(contentsOf: $0) }
    var threw = false
    do { _ = try oversize.push(header) } catch { threw = true }
    try check(threw, "frame: the parser rejects a frame over maxFrameBytes")
}

private func runObservationPolicyChecks() throws {
    let policy = ObservationPolicy()
    try check(policy.dropReason(bundleIdentifier: "com.google.Chrome", windowTitle: "New Incognito Tab", urlDomain: nil) == .privateBrowsing,
              "policy: a Chrome Incognito tab is private browsing")
    try check(policy.dropReason(bundleIdentifier: "com.apple.Safari", windowTitle: "Private Browsing", urlDomain: nil) == .privateBrowsing,
              "policy: a Safari Private Browsing window is private browsing")
    try check(policy.dropReason(bundleIdentifier: "com.apple.Safari", windowTitle: "Private — YouTube", urlDomain: "youtube.com") == .privateBrowsing,
              "policy: a Safari private page title is private browsing")
    try check(policy.dropReason(bundleIdentifier: "com.google.Chrome", windowTitle: "Incognito", urlDomain: nil) == .privateBrowsing,
              "policy: a Chrome Incognito window is private browsing")
    try check(policy.dropReason(bundleIdentifier: "com.apple.Safari", windowTitle: "Personal — YouTube", urlDomain: "youtube.com") == nil,
              "policy: a Safari profile named Personal is not private browsing")

    for title in ["新的无痕式标签页 - Google Chrome（无痕）", "Navigation privée", "シークレット モード", "Nueva pestaña de incógnito", "InPrivate"] {
        try check(policy.dropReason(bundleIdentifier: "com.google.Chrome", windowTitle: title, urlDomain: "example.com") == .privateBrowsing,
                  "policy: the localized private marker \(title) is private browsing")
    }

    // A text editor with a window literally titled "incognito" is not a browser.
    try check(policy.dropReason(bundleIdentifier: "com.apple.TextEdit", windowTitle: "incognito.md", urlDomain: nil) == nil,
              "policy: a private marker outside a browser is not private browsing")

    // Secure fields strip characters at capture time; they do NOT drop the event.
    try check(ObservationPolicy.isSecureRole("AXSecureTextField", subrole: nil), "policy: the secure text field role is secure")
    try check(ObservationPolicy.isSecureRole(nil, subrole: "AXSecureTextField"), "policy: the secure text field subrole is secure")
    try check(!ObservationPolicy.isSecureRole("AXTextField", subrole: nil), "policy: a plain text field is not secure")
    try check(policy.dropReason(bundleIdentifier: "com.apple.Safari", windowTitle: "Login", urlDomain: "example.com") == nil,
              "policy: a login page is not a drop reason")

    let both = ObservationPolicy(allowlist: [.init(scope: .application, bundleID: "com.example.app")],
                                 blocklist: [.init(scope: .application, bundleID: "com.example.app")])
    try check(!both.allowsApplication("com.example.app"), "policy: the app blocklist wins over the allowlist")
    try check(both.dropReason(bundleIdentifier: "com.example.app", windowTitle: nil, urlDomain: nil) == .applicationPolicy,
              "policy: a blocked app's drop reason is the application policy")

    let allowOnly = ObservationPolicy(defaultApplicationBehavior: .doNotObserve,
                                      allowlist: [.init(scope: .application, bundleID: "com.example.allowed")])
    try check(allowOnly.allowsApplication("com.example.allowed"), "policy: do-not-observe keeps an allowed app")
    try check(!allowOnly.allowsApplication("com.example.other"), "policy: do-not-observe drops an unlisted app")

    let domains = ObservationPolicy(defaultURLBehavior: .doNotObserve, allowlist: [.init(scope: .url, urlDomain: "example.com")])
    try check(domains.allowsDomain("docs.example.com"), "policy: a subdomain matches the allowed domain")
    try check(domains.allowsDomain("https://www.example.com/path"), "policy: a full address matches the allowed domain")
    try check(!domains.allowsDomain("example.org"), "policy: another domain does not match")
    try check(!domains.allowsDomain("notexample.com"), "policy: a domain match is dot-anchored")

    let blockedURL = ObservationPolicy(blocklist: [.init(scope: .url, urlDomain: "secret.internal")])
    try check(blockedURL.dropReason(bundleIdentifier: "com.apple.Safari", windowTitle: "Docs", urlDomain: "app.secret.internal") == .urlPolicy,
              "policy: a blocked domain drops by the URL policy")

    try check(policy.route(bundleIdentifier: "com.apple.Safari", windowTitle: "Inbox", urlDomain: "mail.example.com", isBoundary: false) == .persist,
              "policy: a normal event persists")
    try check(policy.route(bundleIdentifier: "com.google.Chrome", windowTitle: "Incognito", urlDomain: nil, isBoundary: false) == .dropCounted(.privateBrowsing),
              "policy: a private non-boundary event is only counted")
    try check(policy.route(bundleIdentifier: "com.google.Chrome", windowTitle: "Incognito", urlDomain: nil, isBoundary: true) == .persistStrippedBoundary(.privateBrowsing),
              "policy: a private boundary keeps its marker without context")

    let blockedApp = ObservationPolicy(blocklist: [.init(scope: .application, bundleID: "com.blocked.app")])
    try check(blockedApp.route(bundleIdentifier: "com.blocked.app", windowTitle: "x", urlDomain: nil, isBoundary: false) == .dropCounted(.applicationPolicy),
              "policy: a blocked app's event is only counted")

    let decoded = try JSONDecoder().decode(ObservationPolicy.self, from: Data(#"{"blocklist":[{"scope":"application","bundleID":"com.x"}]}"#.utf8))
    try check(decoded.defaultApplicationBehavior == .observe, "policy: partial JSON keeps the default observe behavior")
    try check(!decoded.allowsApplication("com.x"), "policy: partial JSON keeps its blocklist")
}

/// The secure-field guarantee, at its source: characters typed into a secure element must never become retained text,
/// though the fact of typing survives.
private func runTextBufferChecks() throws {
    var normal = TextBuffer()
    normal.append(characters: "he", secureInput: false, captureText: true)
    normal.append(characters: "llo", secureInput: false, captureText: true)
    let kept = normal.drain()
    try check(kept.text == "hello" && kept.hadInput, "text buffer: normal typing is retained")

    var secure = TextBuffer()
    secure.append(characters: "hunter2", secureInput: true, captureText: true)
    let secureOut = secure.drain()
    try check(secureOut.text == nil, "text buffer: secure characters are never retained as text")
    try check(secureOut.hadInput, "text buffer: the fact of secure typing is still observable")

    var off = TextBuffer()
    off.append(characters: "secret note", secureInput: false, captureText: false)
    let offOut = off.drain()
    try check(offOut.text == nil && offOut.hadInput, "text buffer: capture off drops characters but keeps the burst")

    var reset = TextBuffer()
    reset.append(characters: "x", secureInput: false, captureText: true)
    _ = reset.drain()
    try check(reset.isEmpty, "text buffer: drain empties the buffer")
    let again = reset.drain()
    try check(again.text == nil && !again.hadInput, "text buffer: a second drain has nothing")
}
