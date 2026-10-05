import SwiftUI
import AppKit
import MemoryCore

// Settings ▸ Apps to remember ▸ "Web pages in Chrome" (Chrome page history, SPEC §11.1). Values only:
// the host (MacMemApp's `DaydreamAppSettings`) passes the saved switch, the access state and the
// owner's sites, and gets the person's choices back through closures. Nothing here reads Chrome,
// asks macOS for anything or saves: Allow calls `allow` and Ask again `askAgain`, which the app routes to
// the one place that may ask (setup's Allow path).

/// Whether DayDream may read Google Chrome's page in front (macOS Privacy & Security › Automation).
/// Read without a prompt when the card appears, after Allow and when the app becomes active.
public enum ChromeAccessState: Equatable, Sendable {
    case unknown, checking, allowed, notAsked, denied, chromeNotRunning, unverified
    /// Two of the person's own Chrome processes run (a second profile folder with its own windows). A headless or
    /// automation Chrome never counts (`ChromeProcesses`). The one in front was checked; nothing is read meanwhile.
    case twoCopies
    /// Allow… came back refused at once, with no question from macOS (it asks only once per app, and a reset or a
    /// dismissed question leaves nothing to answer). The way on is System Settings › Privacy & Security › Automation.
    case askFailed

    /// The button the access row offers, if any.
    public enum Action: Equatable, Sendable { case allow, openSystemSettings, tryAgain }

    /// Maps a macOS Automation status: noErr allowed, −1744 not asked yet,
    /// −1743 not permitted, −600 Chrome not running; anything else is unknown.
    public static func from(status: Int32) -> ChromeAccessState {
        switch status {
        case 0: return .allowed
        case -1744: return .notAsked
        case -1743: return .denied
        case -600: return .chromeNotRunning
        default: return .unknown
        }
    }

    public var value: String {
        switch self {
        case .checking: return "Checking…"
        case .allowed: return "Allowed"
        case .notAsked: return "Not allowed yet"
        case .denied: return "Not allowed"
        case .chromeNotRunning: return "Open Google Chrome to check"
        case .unverified: return "Can't verify this copy of Chrome"
        case .twoCopies: return "Two copies of Chrome are open"
        case .askFailed: return "Not allowed"
        case .unknown: return "Couldn't check"
        }
    }

    public var action: Action? {
        switch self {
        case .notAsked, .chromeNotRunning, .denied, .askFailed: return .allow
        case .unknown, .unverified: return .tryAgain
        case .checking, .allowed, .twoCopies: return nil
        }
    }

    /// A refused request still offers Allow…, with the system pane as another recovery path.
    public var offersSystemSettings: Bool { self == .denied || self == .askFailed }

    public var buttonTitle: String? {
        switch action {
        case .allow: return "Allow…"
        case .openSystemSettings: return "Open System Settings"
        case .tryAgain: return "Try Again"
        case nil: return nil
        }
    }

    public var helper: String? {
        switch self {
        case .notAsked:
            // The full-typing build's join also reads where Chrome's windows are, to match the field you type in.
            return TypingSettingsText.ownerBuild
                ? "macOS will ask to let DayDream control Google Chrome. DayDream only reads the page title, the address, where Chrome's windows are and whether a window is Incognito."
                : "macOS will ask to let DayDream control Google Chrome. DayDream only reads the page title, the address and whether a window is Incognito."
        case .denied: return "Chrome access isn’t permitted. Check DayDream in Privacy & Security › Automation."
        case .chromeNotRunning: return "Open Google Chrome, then press Allow."
        case .unverified: return "DayDream couldn't confirm this Chrome is from Google, so its pages aren't saved. Quit and reopen Chrome, then press Try Again."
        case .askFailed: return "Chrome access is off. Press Allow…, or turn on Google Chrome for DayDream in Automation."
        case .twoCopies: return "DayDream checked the Chrome in front. Pages are saved again once only one copy of Chrome is open."
        case .unknown, .checking, .allowed: return nil
        }
    }

    /// Access is off: the person has not allowed it yet, or turned it off.
    public var accessOff: Bool { self == .denied || self == .notAsked || self == .askFailed }

    /// Privacy & Security › Automation. Opening it never changes a setting.
    public static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    /// Settings ▸ Diagnostics, "Web pages in Chrome". Never a page, a site or a window's mode.
    public static func diagnostics(on: Bool, access: ChromeAccessState, chromeExcluded: Bool = false) -> String {
        guard on else { return "Off" }
        if chromeExcluded { return "On, but Google Chrome is excluded" }
        switch access {
        case .denied, .notAsked, .askFailed: return "On, but Chrome access is off"
        case .unverified: return "On, but this copy of Chrome can't be verified"
        case .twoCopies: return "On, but two copies of Chrome are open"
        case .chromeNotRunning: return "On. Open Google Chrome to check access."
        case .allowed, .checking, .unknown: return "On"
        }
    }
}

/// The owner's own site list: what "Add" and "Don't Record <site>…" can say back.
public struct ChromeSiteMessage: Error, Equatable, CustomStringConvertible {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var description: String { text }

    public static let invalid = ChromeSiteMessage("Type a site like example.com.")
    public static let alreadyListed = ChromeSiteMessage("That site is already on your list.")
    public static let alreadySkipped = ChromeSiteMessage("That site is already skipped.")
    public static let full = ChromeSiteMessage("You can add up to 256 sites.")
}

/// "Web pages in Chrome": the title and the switch, nothing under the title (fix/apps-declutter, owner 9/29: the line
/// and Learn more went; the only line left is `excludedDetail`, a problem). The switch turns on at once (owner 9/28: no
/// second question). Chrome access shows only while the saved switch is on and access isn't allowed; the site field
/// and the owner's sites only while the switch is on. The strings below (`explanation`, `setupLine`, …) stay for the
/// consent version, diagnostics and docs; the card no longer draws them.
public struct ChromePagesCard: View {
    public static let title = "Web pages in Chrome"
    public static let offDetail = "Off. Saves the title and site of the Chrome pages you look at."
    public static let onDetail = "On. Saves the title and site of the Chrome page in front."
    public static let switchLabel = "Save web pages in Google Chrome"
    /// Setup's one line under the switch (opt-out, owner 9/27): what it saves, what it skips, where the pages go.
    /// fix/sx-all round 3: one line. Who gets the pages (connected AI apps, cloud summaries) is in Learn more (`explanation`).
    public static let setupLine = "Saves the title and site of the Chrome tab in front. Skips Incognito."
    /// Consent text version `PrivacySettings.browserPagesConsentCurrent` (1 in public builds): a material change bumps it.
    #if DAYDREAM_OWNER_TYPING
    /// Owner build, version 2: website typing exists here, so the card says what it saves (as the recording
    /// reason and the browser status line do).
    public static let explanation = [
        "When on, DayDream saves the title, site and link of the page in front in Google Chrome, and when. Links keep no search terms and stay on this Mac. It never saves what's on the page or your clicks.",
        WebTypingText.chromeCard] + sharedExplanation(siteOnly: siteOnlyLine)
    /// fix/sx-all round 2: typing in webmail keeps the open email's subject (`BrowserTypingSites`), so the site-only line
    /// says so where website typing exists.
    public static let siteOnlyLine = "Search engines save what you searched for, never the rest of the address. Common chat sites save the site only. Email sites save the folder or the open email's subject while Save email subjects is on (never codes, passwords, sign-ins or bank mail), and typing in webmail keeps the open email's subject."
    #else
    public static let explanation = [
        "When on, DayDream saves the title, site and link of the page in front in Google Chrome, and when. Links keep no search terms and stay on this Mac. It never saves what's on the page, what you type, or your clicks.",
    ] + sharedExplanation(siteOnly: siteOnlyLine)
    public static let siteOnlyLine = "Search engines save what you searched for, never the rest of the address. Common chat sites save the site only. Email sites save the folder or the open email's subject while Save email subjects is on (never codes, passwords, sign-ins or bank mail)."
    #endif
    static func sharedExplanation(siteOnly: String) -> [String] { [
        "While any Incognito or Guest window is open, DayDream saves nothing from Chrome.",
        siteOnly,
        "Common banking, password, sign-in, payment, health and government sites are skipped. You can add your own below.",
        "Page titles can include other people's words, like email subjects or chat names.",
        "Work and personal Chrome profiles are both saved. Pages are kept on this Mac, unencrypted. AI apps you connect can read them, and what they read goes to their AI provider. Cloud summaries, when you turn them on, get their titles and sites.",
        "Other browsers, including Chrome Beta and Canary, aren't recorded in this version. A browser DayDream doesn't know by name is skipped too if it opens web links.",
        "Turning this on or removing a site disconnects the AI apps you connected until you reconnect them. If recording was off, it stays off.",
    ] }
    /// email-1003 (owner decision 2026-10-03, default on): the email-subjects switch, shown while the card's switch is on.
    public static let emailSubjectsLabel = "Save email subjects"
    public static let accessLabel = "Chrome access"
    public static let sitesHeader = "Sites not recorded"
    public static let fieldPlaceholder = "Add a site, like example.com"
    public static let fieldLabel = "Site to stop recording"
    public static let emptySites = "No sites added yet."
    public static let defaultsLine = "Also skipped: common banking, password, sign-in, payment, health and government sites."
    public static let showList = "Show the list"
    public static let learnMore = "Learn more"
    public static let showLess = "Show less"
    public static let unavailable = "Settings changes unavailable until safe saving is ready."
    public static func removeLabel(_ host: String) -> String { "Record \(host) again" }
    public static let excludedDetail = "On, but Google Chrome is excluded, so nothing is saved."
    public static func detail(on: Bool, chromeExcluded: Bool = false) -> String { on ? (chromeExcluded ? excludedDetail : onDetail) : setupLine }
    /// The text under the field for an error `add` threw.
    public static func message(_ error: Error) -> String {
        if let site = error as? ChromeSiteMessage { return site.text }
        if case MemError.invalid(let text) = error, !text.isEmpty { return text }
        return "Not saved. Try again."
    }

    @Binding private var on: Bool
    /// Settings' disclosure (owner decision 2026-10-03): open shows the card's settings under the title row. nil: always
    /// shown (renders and checks that predate the disclosure).
    private let expanded: Binding<Bool>?
    /// "Save email subjects" (the draft; the host saves it). nil: the row isn't drawn (renders and checks that predate it).
    private let emailSubjects: Binding<Bool>?
    private let savedOn: Bool
    private let access: ChromeAccessState
    private let chromeExcluded: Bool
    private let sites: [String]
    private let enabled: Bool
    private let unavailableNote: Bool
    private let add: (String) throws -> Void
    private let remove: (String) throws -> Void
    private let allow: () -> Void
    private let openSystemSettings: () -> Void
    /// Refused: the app's Ask again (`askChromeAgain`). nil keeps Open System Settings (renders that predate it).
    private let askAgain: (() -> Void)?
    private let checkAccess: () -> Void
    @State private var draft = ""
    @State private var error: String?

    /// - `on`: the switch (the draft; the host saves it). `savedOn`: the saved switch, which alone shows
    ///   the Chrome access row.
    /// - `sites`: the owner's own entries (sorted, `BrowserSites.siteEntry` form).
    /// - `enabled`: false while preferences can't be saved; the switch, field and Remove buttons are off.
    /// - `unavailableNote`: false where the page around the card already says why nothing can change (Settings ›
    ///   Apps to remember shows the one-sentence problem line), so the card doesn't add a second reason.
    /// - `checkAccess`: reads access without a prompt; called when the card appears while the saved switch
    ///   is on, and when the saved switch turns on. `allow` is called only by the access row's Allow (the app routes it
    ///   to setup's Allow path), `askAgain` only by its Ask again.
    /// - `expanded`: Settings' open/closed row (owner decision 2026-10-03). A click on the title row (not the switch) shows or
    ///   hides "Save email subjects" and the sites; Chrome access, while it needs a click, shows either way. nil: always open.
    public init(on: Binding<Bool>, savedOn: Bool, access: ChromeAccessState, chromeExcluded: Bool = false, sites: [String], enabled: Bool,
                unavailableNote: Bool = true, emailSubjects: Binding<Bool>? = nil, expanded: Binding<Bool>? = nil,
                add: @escaping (String) throws -> Void, remove: @escaping (String) throws -> Void,
                allow: @escaping () -> Void, openSystemSettings: @escaping () -> Void, askAgain: (() -> Void)? = nil,
                checkAccess: @escaping () -> Void) {
        _on = on; self.expanded = expanded; self.emailSubjects = emailSubjects; self.savedOn = savedOn; self.access = access; self.chromeExcluded = chromeExcluded; self.sites = sites; self.enabled = enabled
        self.unavailableNote = unavailableNote
        self.add = add; self.remove = remove; self.allow = allow; self.openSystemSettings = openSystemSettings
        self.askAgain = askAgain; self.checkAccess = checkAccess
    }

    /// The switch goes straight to the host both ways (owner 9/28: no second question). Saving the switch on records
    /// the consent version (the host's save).
    private var switchBinding: Binding<Bool> {
        Binding(get: { on }, set: { new in on = new })
    }

    private static let tint = Color(nsColor: .systemBlue)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The settings under the title row exist only while the switch is on.
    private var hasDetails: Bool { on || savedOn }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // fix/apps-declutter (owner 9/29, "too cluttered"): no line under the title, no Learn more. chromeask-1005
            // (owner 10/5): Chrome access, in the same states as setup's row and the menu bar: Allow, "Chrome pages aren't
            // being saved." with Ask again, or Allowed. While it needs a click it shows with the row closed too (the one
            // way to make the switch work); Allowed and a read in progress only with the row open.
            if savedOn, (access != .allowed && access != .checking) || (expanded?.wrappedValue ?? true) {
                rule
                accessRow.padding(.horizontal, 12).padding(.vertical, 10)
            }
            // The site field only while the switch is on, and in Settings only while the row is open.
            if hasDetails && (expanded?.wrappedValue ?? true) {
                VStack(alignment: .leading, spacing: 0) {
                    if let emailSubjects {
                        rule
                        emailSubjectsRow(emailSubjects).padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    rule
                    sitesSection.padding(.horizontal, 12).padding(.vertical, 10)
                }
                .transition(SettingsDisclosure.transition(reduceMotion: reduceMotion))
            }
            if !enabled && unavailableNote {
                Text(Self.unavailable).font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        // The card's edge cuts the details while its height moves, so they never draw over the card below.
        .clipShape(RoundedRectangle(cornerRadius: DaydreamStyle.cardRadius))
        .daydreamCard()
        // The card is built with its row open or closed, so it reads access itself, without a prompt (int-1003, 3d844d0).
        .onAppear { if savedOn { checkAccess() } }
        .onChange(of: savedOn) { now in if now { checkAccess() } }
    }

    private var rule: some View {
        Rectangle().fill(DaydreamStyle.hairline).frame(height: 1).padding(.horizontal, 10).accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 12) {
            // The row, not the switch, opens and closes the settings under it.
            SettingsDisclosureLabel(open: expanded, hasDetails: hasDetails) {
                HStack(spacing: 12) {
                    Image(systemName: "globe").font(.system(size: 14, weight: .semibold)).foregroundStyle(Self.tint)
                        .frame(width: 32, height: 32)
                        .background(Self.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.title).font(.system(size: 13, weight: .semibold))
                            .accessibilityElement(children: .combine)
                        // Only a line that says something is wrong: on, but Google Chrome is excluded.
                        if on && chromeExcluded && on == savedOn {
                            Text(Self.excludedDetail).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Toggle(Self.title, isOn: switchBinding).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .disabled(!enabled).accessibilityLabel(Self.switchLabel)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 52)
    }

    /// email-1003: one switch, no line under it (owner: fewer elements, less text).
    private func emailSubjectsRow(_ binding: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Text(Self.emailSubjectsLabel).font(.system(size: 13))
            Spacer(minLength: 8)
            Toggle(Self.emailSubjectsLabel, isOn: binding).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .disabled(!enabled).accessibilityLabel(Self.emailSubjectsLabel)
        }
        .frame(minHeight: 28)
    }

    /// chromeask-1005: the access row's one button, as setup's row and the menu bar offer it.
    public enum AccessButton: Equatable, Sendable { case allow, askAgain, tryAgain }
    public static func accessButton(_ access: ChromeAccessState) -> AccessButton? {
        switch access {
        case .notAsked, .chromeNotRunning: return .allow
        case .denied, .askFailed: return .askAgain
        case .unknown, .unverified: return .tryAgain
        case .checking, .allowed, .twoCopies: return nil
        }
    }
    public static func accessButtonTitle(_ button: AccessButton) -> String {
        switch button {
        case .allow: return PermissionChromeRow.allowTitle
        case .askAgain: return ChromeAccessNotice.askAgainTitle
        case .tryAgain: return "Try Again"
        }
    }
    /// The row's words: Chrome pages aren't being saved while access is off (never asked or refused), else "Chrome
    /// access" beside its state (Allowed, a spinner, or what's wrong).
    public static func accessText(_ access: ChromeAccessState) -> String {
        access.accessOff || access == .chromeNotRunning ? ChromeAccessNotice.line : accessLabel
    }
    /// The line under it: before macOS asks, the primer setup's row uses (with Chrome closed, that Allow opens it in the
    /// background to ask); a Chrome that can't be read, why. Nothing once refused (Ask again says it) or allowed.
    public static func accessHelper(_ access: ChromeAccessState) -> String? {
        switch access {
        case .notAsked: return PermissionChromeRow.primerTypingOff
        case .chromeNotRunning: return PermissionChromeRow.primerTypingOff + " " + PermissionChromeRow.opensChromeLine
        case .unverified, .twoCopies: return access.helper
        case .unknown, .checking, .allowed, .denied, .askFailed: return nil
        }
    }

    private var accessRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(Self.accessText(access)).font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                switch access {
                case .checking:
                    ProgressView().controlSize(.small).accessibilityLabel(ChromeAccessState.checking.value)
                case .allowed:
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(nsColor: .systemGreen)).accessibilityHidden(true)
                        Text(ChromeAccessState.allowed.value).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                case .unknown, .unverified, .twoCopies:
                    Text(access.value).font(.system(size: 12)).foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
                if let button = Self.accessButton(access) {
                    if button == .askAgain, askAgain == nil {
                        Button("Open System Settings", action: openSystemSettings).controlSize(.small)
                    } else {
                        Button(Self.accessButtonTitle(button)) {
                            switch button {
                            case .allow: allow()
                            case .askAgain: askAgain?()
                            case .tryAgain: checkAccess()
                            }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .accessibilityHint(button == .askAgain ? ChromeAccessNotice.askAgainHint : "")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            if let helper = Self.accessHelper(access) {
                Text(helper).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sitesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.sitesHeader).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                TextField(Self.fieldPlaceholder, text: $draft).textFieldStyle(.plain).font(.system(size: 13))
                    .padding(.horizontal, 9).frame(height: 28).daydreamField()
                    .accessibilityLabel(Self.fieldLabel)
                    .onSubmit(submit)
                Button("Add", action: submit).controlSize(.small)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(!enabled)
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(DaydreamStyle.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !sites.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sites, id: \.self) { host in
                        HStack(spacing: 8) {
                            Text(host).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button("Remove") { removeSite(host) }.controlSize(.small)
                                .disabled(!enabled).accessibilityLabel(Self.removeLabel(host))
                        }
                        .frame(minHeight: 28)
                    }
                }
            }
        }
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !text.isEmpty else { return }
        do { try add(text); draft = ""; error = nil } catch { self.error = Self.message(error) }
    }

    private func removeSite(_ host: String) {
        guard enabled else { return }
        do { try remove(host); error = nil } catch { self.error = Self.message(error) }
    }
}
