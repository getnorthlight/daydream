// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// Portions of this file are derived from open-codex-computer-history
// (https://github.com/hqhq1025/open-codex-computer-history),
// Copyright (c) 2026 Open Codex Computer History contributors, used under the
// MIT License. The full MIT notice is in THIRD-PARTY-NOTICES.md.

import Testing
import Foundation
@testable import HistoryCore

@Suite struct PolicyTests {
    @Test func privateBrowsingIsAlwaysDroppedForKnownBrowsers() {
        let policy = ObservationPolicy()
        #expect(policy.dropReason(bundleIdentifier: "com.google.Chrome", windowTitle: "New Incognito Tab", urlDomain: nil) == .privateBrowsing)
        #expect(policy.dropReason(bundleIdentifier: "com.apple.Safari", windowTitle: "Private Browsing", urlDomain: nil) == .privateBrowsing)
        #expect(policy.dropReason(bundleIdentifier: "com.apple.Safari", windowTitle: "Private — YouTube", urlDomain: "youtube.com") == .privateBrowsing)
        #expect(policy.dropReason(bundleIdentifier: "com.google.Chrome", windowTitle: "Incognito", urlDomain: nil) == .privateBrowsing)
        #expect(policy.dropReason(bundleIdentifier: "com.apple.Safari", windowTitle: "Personal — YouTube", urlDomain: "youtube.com") == nil)
    }

    @Test func localizedPrivateMarkersAreDetected() {
        let policy = ObservationPolicy()
        for title in ["新的无痕式标签页 - Google Chrome（无痕）", "Navigation privée", "シークレット モード", "Nueva pestaña de incógnito", "InPrivate"] {
            #expect(
                policy.dropReason(bundleIdentifier: "com.google.Chrome", windowTitle: title, urlDomain: "example.com") == .privateBrowsing,
                "expected private-browsing drop for title \(title)"
            )
        }
    }

    @Test func privateMarkerInNonBrowserIsNotPrivateBrowsing() {
        // A text editor with a window literally titled "incognito" is not a browser.
        let policy = ObservationPolicy()
        #expect(policy.dropReason(bundleIdentifier: "com.apple.TextEdit", windowTitle: "incognito.md", urlDomain: nil) == nil)
    }

    @Test func secureRoleIsDetectedButIsNotADropReason() {
        // Secure fields strip characters at capture time; they do NOT drop the event.
        #expect(ObservationPolicy.isSecureRole("AXSecureTextField", subrole: nil))
        #expect(ObservationPolicy.isSecureRole(nil, subrole: "AXSecureTextField"))
        #expect(!ObservationPolicy.isSecureRole("AXTextField", subrole: nil))
        #expect(ObservationPolicy().dropReason(bundleIdentifier: "com.apple.Safari", windowTitle: "Login", urlDomain: "example.com") == nil)
    }

    @Test func applicationBlocklistWinsOverAllowlist() {
        let policy = ObservationPolicy(
            allowlist: [.init(scope: .application, bundleID: "com.example.app")],
            blocklist: [.init(scope: .application, bundleID: "com.example.app")]
        )
        #expect(!policy.allowsApplication("com.example.app"))
        #expect(policy.dropReason(bundleIdentifier: "com.example.app", windowTitle: nil, urlDomain: nil) == .applicationPolicy)
    }

    @Test func defaultDoNotObserveDropsUnlistedApps() {
        let policy = ObservationPolicy(
            defaultApplicationBehavior: .doNotObserve,
            allowlist: [.init(scope: .application, bundleID: "com.example.allowed")]
        )
        #expect(policy.allowsApplication("com.example.allowed"))
        #expect(!policy.allowsApplication("com.example.other"))
    }

    @Test func urlSuffixMatchIsDotAnchored() {
        let policy = ObservationPolicy(
            defaultURLBehavior: .doNotObserve,
            allowlist: [.init(scope: .url, urlDomain: "example.com")]
        )
        #expect(policy.allowsDomain("docs.example.com"))
        #expect(policy.allowsDomain("https://www.example.com/path"))
        #expect(!policy.allowsDomain("example.org"))
        #expect(!policy.allowsDomain("notexample.com"), "must not match a non-dot-anchored suffix")
    }

    @Test func urlBlocklistDrops() {
        let policy = ObservationPolicy(blocklist: [.init(scope: .url, urlDomain: "secret.internal")])
        #expect(policy.dropReason(bundleIdentifier: "com.apple.Safari", windowTitle: "Docs", urlDomain: "app.secret.internal") == .urlPolicy)
    }

    @Test func routingDropsPrivateBrowsingButKeepsStrippedBoundary() {
        let policy = ObservationPolicy()
        // A normal event persists.
        #expect(policy.route(bundleIdentifier: "com.apple.Safari", windowTitle: "Inbox", urlDomain: "mail.example.com", isBoundary: false) == .persist)
        // A private-window non-boundary event is counted only — never persisted.
        #expect(policy.route(bundleIdentifier: "com.google.Chrome", windowTitle: "Incognito", urlDomain: nil, isBoundary: false) == .dropCounted(.privateBrowsing))
        // A boundary in a private context keeps its marker but stripped of context.
        #expect(policy.route(bundleIdentifier: "com.google.Chrome", windowTitle: "Incognito", urlDomain: nil, isBoundary: true) == .persistStrippedBoundary(.privateBrowsing))
    }

    @Test func routingDropsBlockedApp() {
        let policy = ObservationPolicy(blocklist: [.init(scope: .application, bundleID: "com.blocked.app")])
        #expect(policy.route(bundleIdentifier: "com.blocked.app", windowTitle: "x", urlDomain: nil, isBoundary: false) == .dropCounted(.applicationPolicy))
    }

    @Test func policyDecodesFromPartialJSON() throws {
        let json = Data(#"{"blocklist":[{"scope":"application","bundleID":"com.x"}]}"#.utf8)
        let policy = try JSONDecoder().decode(ObservationPolicy.self, from: json)
        #expect(policy.defaultApplicationBehavior == .observe)
        #expect(!policy.allowsApplication("com.x"))
    }
}
