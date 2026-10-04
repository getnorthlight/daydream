// Website typing (typing-all SPEC-LATER 4.2, owner decision 3): the host
// table's "Other websites" switch, in every build. The Chrome typing build
// adds the site rules and the rebuilt burst (Checks/WebTypingChecks.swift).
// Synthetic only: no Apple Event, Accessibility call, event tap, Chrome
// launch or permission request.
import Foundation
import MemoryCore
import PrivacyPolicy

func runTypingSitesChecks() throws {
    let all: (TypingCategory) -> Bool = { _ in true }
    let none: (TypingCategory) -> Bool = { _ in false }
    // Every build: the table's "Other websites" is its own switch.
    try check(TypingCategories.permitsSite(host: "example.org", on: none, other: true, expanded: true)
              && !TypingCategories.permitsSite(host: "example.org", on: all, other: false, expanded: true),
              "sites, gate open: other websites follow their own switch, not the categories")
    try check(!TypingCategories.permitsSite(host: "docs.google.com", path: "/document/d/1/edit", on: all, other: true, expanded: true)
              && !TypingCategories.permitsSite(host: "chase.com", on: all, other: true, expanded: true)
              && !TypingCategories.permitsSite(host: "accounts.google.com", on: all, other: true, expanded: true),
              "sites, gate open: never pages stay off with every switch on")
    try check(TypingCategories.permitsSite(host: "claude.ai", path: "/new", on: { $0 == .searchAndAI }, other: false, expanded: true)
              && !TypingCategories.permitsSite(host: "claude.ai", path: "/new", on: { $0 != .searchAndAI }, other: true, expanded: true),
              "sites, gate open: a known category follows its switch, not Other websites")
    try check(!TypingCategories.permitsSite(host: "example.org", on: all, other: true, expanded: false),
              "sites: nothing is permitted with the gate closed, Other websites on or not")
    let owner = TypedTextPolicy()
    try check(owner.permitsSite(host: "example.org", expanded: true) && owner.categories.otherWebsites,
              "sites: the saved default permits other websites once the gate is open (owner decision 3)")
    var otherOff = TypedTextPolicy(); otherOff.categories.otherWebsites = false
    try check(!otherOff.permitsSite(host: "example.org", expanded: true) && otherOff.permitsSite(host: "claude.ai", path: "/new", expanded: true),
              "sites: Other websites off stops unknown sites only")
}
