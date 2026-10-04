import Foundation
import AppKit
import SwiftUI
@testable import MemoryCore
@testable import MemoryUI

/// Owner 10/3: setup's and Connections' "Let AI apps read what you typed" switch, and Settings › Apps to remember.
/// Owner decision 2026-10-03 (correcting faec835, which folded the whole page into two one-line rows): the scrolling app list
/// stays in sight; under it "Web pages in Chrome" and "Remember what you type" are each a title row with its switch, and a
/// click on the row (not the switch) opens that row's own settings with a smooth height-and-fade disclosure (none with
/// Reduce Motion), remembered while DayDream runs. Pure rules, source pins and off-window layout sizes; no app, window
/// or defaults of the person.
@main @MainActor enum SettingsCondenseChecks {
    static var checks = 0
    static func require(_ ok: Bool, _ reason: String, _ got: @autoclosure () -> String = "") {
        guard ok else { FileHandle.standardError.write(Data("FAIL: \(reason) \(got())\n".utf8)); exit(1) }
        checks += 1
    }
    static func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    static func main() {
        aiReads()
        disclosure()
        chromeRow()
        typingRow()
        page()
        print("PASS: settings-condense \(checks) checks; private defaults suite, no windows")
    }

    static func aiReads() {
        let suite = "dd-settings-condense-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { require(false, "defaults suite"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        require(AIReadsTypedSetting.key == "aiAppsReadTyped" && AIReadsTypedSetting.defaultValue, "key aiAppsReadTyped, default on")
        require(AIReadsTypedSetting.isOn(defaults), "never set: on")
        AIReadsTypedSetting.set(false, defaults)
        require(!AIReadsTypedSetting.isOn(defaults), "turned off: off")
        AIReadsTypedSetting.set(true, defaults)
        require(AIReadsTypedSetting.isOn(defaults), "turned on again: on")
        require(AIReadsTypedSetting.title == "Let AI apps read what you typed", "title")
        require(AIReadsTypedSetting.line == "ChatGPT, Claude and other connected apps can search and read your typed words. Passwords are never shared.",
                "one short line")
        let cards = source("Sources/MemoryUI/PermissionSetup.swift")
        guard let chrome = cards.range(of: "if let chromeRow { chromeCard(chromeRow) }"),
              let toggle = cards.range(of: "if showsAIReadsToggle { aiReadsCard }") else { require(false, "setup markers"); return }
        require(chrome.upperBound <= toggle.lowerBound && cards[chrome.upperBound..<toggle.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "the toggle is directly under the Google Chrome row")
        require(cards.contains("@AppStorage(AIReadsTypedSetting.key) private var aiReadsTyped = AIReadsTypedSetting.defaultValue")
                && cards.contains("Toggle(\"\", isOn: $aiReadsTyped)"), "setup's toggle is bound to the setting")
        require(source("Sources/MacMemApp/DaydreamOnboarding.swift").contains("chromeRow: chromeRow, showsAIReadsToggle: true,"),
                "setup's Permissions card shows it")
        let connections = source("Sources/MacMemApp/ConnectionSettings.swift")
        require(connections.contains("@AppStorage(AIReadsTypedSetting.key) private var aiReadsTyped = AIReadsTypedSetting.defaultValue")
                && connections.contains("Toggle(\"\", isOn: $aiReadsTyped)") && connections.contains("Text(AIReadsTypedSetting.line)"),
                "Settings › Connections shows the same switch")
    }

    /// A view's laid-out size at Settings' card width, in a hosting view that is never put in a window.
    static func size<V: View>(_ view: V, width: CGFloat = 560) -> NSSize {
        let host = NSHostingView(rootView: view.frame(width: width).environment(\.daydreamStatic, true))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    static func disclosure() {
        require(SettingsDisclosure.animation(reduceMotion: true) == nil && SettingsDisclosure.animation(reduceMotion: false) != nil,
                "a smooth disclosure, none with Reduce Motion")
        // Every launch starts closed; a row opens and closes on its own; nothing else moves with it.
        let fresh = SettingsExpansion()
        require(SettingsExpansion.Row.allCases.allSatisfy { !fresh.isOpen($0) }, "a new session starts with every row closed")
        let chrome = fresh.binding(.chromePages)
        chrome.wrappedValue = true
        require(fresh.isOpen(.chromePages) && !fresh.isOpen(.typing) && chrome.wrappedValue, "opening Web pages in Chrome opens only that row")
        fresh.binding(.typing).wrappedValue = true
        chrome.wrappedValue = false
        require(!fresh.isOpen(.chromePages) && fresh.isOpen(.typing), "each row closes on its own")
        require(SettingsExpansion.session === SettingsExpansion.session && !SettingsExpansion.Row.allCases.contains { SettingsExpansion.session.isOpen($0) },
                "the app's one session memory, closed at launch")
        require(SettingsDisclosure.accessibilityValue(open: true) == "Expanded" && SettingsDisclosure.accessibilityValue(open: false) == "Collapsed",
                "VoiceOver hears Expanded or Collapsed")
        let source = source("Sources/MemoryUI/SettingsDisclosure.swift")
        for saved in ["UserDefaults", "AppStorage", "SceneStorage"] {
            require(!source.contains(saved), "the open rows are kept for this run only, never saved: \(saved)")
        }
        // The disclosure is the row's label only: no switch inside it, so the switch flips without opening the row.
        let label = source.components(separatedBy: "struct SettingsDisclosureLabel").last ?? ""
        require(!label.contains("Toggle(") && label.contains("withAnimation(SettingsDisclosure.animation(reduceMotion: reduceMotion)) { open.wrappedValue.toggle() }")
                && label.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"),
                "a click on the row (not the switch) opens it, animated unless Reduce Motion is on")
        require(source.contains(".asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.06)),")
                && source.contains("reduceMotion ? .identity :") && source.contains(".spring(response: 0.32, dampingFraction: 1)"),
                "height on a spring without overshoot; the details fade in after it starts, out before it ends")
    }

    static func chromeRow() {
        func card(on: Bool = true, access: ChromeAccessState = .allowed, expanded: Bool?, subjects: Bool = false) -> NSSize {
            size(ChromePagesCard(on: .constant(on), savedOn: on, access: access, sites: ["example.com"], enabled: true,
                                 emailSubjects: subjects ? .constant(true) : nil, expanded: expanded.map { .constant($0) },
                                 add: { _ in }, remove: { _ in }, allow: {}, openSystemSettings: {}, checkAccess: {}))
        }
        let off = card(on: false, expanded: false), closed = card(expanded: false), open = card(expanded: true), always = card(expanded: nil)
        require(off.height <= 60 && abs(closed.height - off.height) < 1, "closed, the Chrome row is its title and switch", "\(off.height) \(closed.height)")
        require(open.height > closed.height + 40 && abs(open.height - always.height) < 1, "open, it shows its settings (the sites), as it always did",
                "\(closed.height) \(open.height) \(always.height)")
        require(card(expanded: true, subjects: true).height > open.height + 20 && abs(card(expanded: false, subjects: true).height - closed.height) < 1,
                "Save email subjects is one of the row's settings")
        let asking = card(access: .notAsked, expanded: false)
        require(asking.height > closed.height + 20, "Chrome access that needs a click shows with the row closed", "\(asking.height) \(closed.height)")
        let src = source("Sources/MemoryUI/ChromePagesSettings.swift")
        require(src.contains("if hasDetails && (expanded?.wrappedValue ?? true) {") && src.contains("private var hasDetails: Bool { on || savedOn }")
                && src.contains(".transition(SettingsDisclosure.transition(reduceMotion: reduceMotion))"), "the details are the disclosure; nothing to open while off")
        // int-1003 (3d844d0): the card itself reads access without a prompt, built with its row open or closed.
        let body = src.components(separatedBy: "public var body: some View {").dropFirst().first ?? ""
        let root = body.components(separatedBy: ".daydreamCard()").dropFirst().first ?? ""
        require(root.contains(".onAppear { if savedOn { checkAccess() } }") && root.contains(".onChange(of: savedOn) { now in if now { checkAccess() } }"),
                "the access read is on the card itself, outside the disclosure")
        let header = src.components(separatedBy: "private var header: some View {").dropFirst().first?.components(separatedBy: "private func emailSubjectsRow").first ?? ""
        guard let row = header.range(of: "SettingsDisclosureLabel(open: expanded, hasDetails: hasDetails) {"),
              let toggle = header.range(of: "Toggle(Self.title, isOn: switchBinding)") else { require(false, "Chrome header markers"); return }
        require(row.upperBound < toggle.lowerBound, "the Chrome switch sits outside the row's click")
        require(src.contains(".clipShape(RoundedRectangle(cornerRadius: DaydreamStyle.cardRadius))\n        .daydreamCard()"),
                "the card's edge cuts the details while they move: nothing draws over the card below")
    }

    static func typingRow() {
        var consented = TypedTextPolicy(); consented.consentVersion = TypedTextPolicy.currentConsentVersion; consented.acceptedScope = .current
        func card(_ values: TypingSettingsValues, expanded: Bool?) -> NSSize {
            size(TypingSettingsCard(values: values, actions: .init(), expanded: expanded.map { .constant($0) }))
        }
        let on = TypingSettingsValues(switchOn: true, policy: consented, vault: .ready)
        let intro = card(TypingSettingsValues(switchOn: false, policy: TypedTextPolicy(), vault: .notSetUp), expanded: false)
        let closed = card(on, expanded: false), open = card(on, expanded: true), always = card(on, expanded: nil)
        require(closed.height < 70 && abs(closed.height - intro.height) < 1, "closed, the typing row is its title and switch", "\(closed.height) \(intro.height)")
        require(open.height > closed.height + 40 && abs(open.height - always.height) < 1, "open, it shows its settings, as it always did",
                "\(closed.height) \(open.height) \(always.height)")
        let off = TypingSettingsValues(switchOn: false, policy: consented, vault: .ready)
        require(card(off, expanded: true).height > card(off, expanded: false).height + 20, "typing off: Keep exact words and Forget open from the row")
        let locked = card(TypingSettingsValues(switchOn: true, policy: consented, vault: .locked), expanded: false)
        let lost = card(TypingSettingsValues(switchOn: true, policy: TypedTextPolicy(), vault: .keyLost, keyLost: true), expanded: false)
        require(locked.height > closed.height + 20 && lost.height > closed.height + 20, "a locked Keychain or a lost key shows with the row closed",
                "\(locked.height) \(lost.height) \(closed.height)")
        let taken = TypingSettingsValues.Shortcut(choices: ["⌃⌥⌘T"], selected: 0, message: TypingSettingsText.shortcutTaken)
        require(card(TypingSettingsValues(switchOn: true, policy: consented, vault: .ready, shortcut: taken), expanded: false).height > closed.height + 10,
                "a shortcut macOS refused shows with the row closed")
        let failed = TypingSettingsValues(switchOn: true, policy: consented, vault: .ready, saveFailed: true)
        require(card(failed, expanded: false).height > closed.height + 8, "Not saved shows with the row closed")
        let src = source("Sources/MemoryUI/TypingSettings.swift")
        require(src.contains("if hasDetails && (expanded?.wrappedValue ?? true) {") && src.contains("private var hasDetails: Bool { values.phase == .on || values.phase == .off }")
                && src.contains(".transition(SettingsDisclosure.transition(reduceMotion: reduceMotion))"), "the settings are the disclosure; nothing to open before setup")
        let header = src.components(separatedBy: "    private var header: some View {").dropFirst().first?.components(separatedBy: "private var introProblems").first ?? ""
        guard let row = header.range(of: "SettingsDisclosureLabel(open: expanded, hasDetails: hasDetails) {"),
              let toggle = header.range(of: "Toggle(TypingSettingsText.switchLabel") else { require(false, "typing header markers"); return }
        require(row.upperBound < toggle.lowerBound, "the typing switch sits outside the row's click")
        require(src.contains(".clipShape(RoundedRectangle(cornerRadius: DaydreamStyle.cardRadius))\n        .daydreamCard()"),
                "the card's edge cuts the settings while they move")
    }

    static func page() {
        let page = source("Sources/MacMemApp/DaydreamSettings.swift")
        // The app list is the page's own card again, never folded (faec835's SettingsCollapsibleSection is gone).
        require(!page.contains("SettingsCollapsibleSection") && !FileManager.default.fileExists(atPath: "Sources/MemoryUI/SettingsCollapsibleSection.swift"),
                "Apps to remember's scrolling list stays in sight")
        require(page.contains("browserPages: model.browserPagesSaved, chromePages: ReleaseFeatures.chromePageHistory ? AnyView(chromePages) : nil,")
                && page.contains("typing: AnyView(DaydreamTypingSettings(model: model, expanded: expansion.binding(.typing))),"),
                "under the list: Web pages in Chrome, then Remember what you type")
        require(page.contains("@ObservedObject private var expansion = SettingsExpansion.session")
                && page.contains("expanded: expansion.binding(.chromePages),"), "both rows remember their state for the session")
        require(!page.contains(".onAppear { if model.browserPagesSaved { model.checkChromeAccess() } }") && page.contains("checkAccess: { model.checkChromeAccess() })"),
                "Chrome access is read by the card itself, which is always built (3d844d0's second read beside it is gone)")
        // Setup's Apps page and anything else that builds the cards without a row see every setting, as before.
        let apps = source("Sources/MemoryUI/AppExclusions.swift")
        require(apps.contains("if let chromePages { chromePages }\n            typingSection"), "the Chrome card, then the Typing card, under the list")
    }
}
