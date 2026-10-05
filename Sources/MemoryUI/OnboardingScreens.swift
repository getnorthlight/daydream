import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics
import MemoryCore
import PrivacyPolicy

public enum DaydreamSummaryChoice: String, CaseIterable, Identifiable {
    case local, cloud, later
    public var id: String { rawValue }
}

/// Setup's wording that must stay true (honesty items 21-24). One place, so the checks and the
/// Settings pages say exactly the same thing.
public enum DaydreamSetupText {
    /// The history file is plain SQLite on disk: FileVault is what protects it. Shown only while FileVault is off
    /// (`FileVaultStatus`), so it is never said on a Mac where it isn't true.
    public static let fileVault = "Your history isn't encrypted yet. Turn on FileVault."
    /// Legal §11.4, in the words the README and PRIVACY.md use: never pitched or used as a way to watch someone else.
    public static let ownMac = "Use DayDream only to record yourself, on your own Mac account."
    /// Common password managers are skipped; the list can't be complete.
    public static let passwordManagers = "Common password managers are skipped. Add others in Settings."
    /// Summaries on this Mac need the runtime inside the app. Every release carries it; only a test build
    /// staged with --without-writer-runtime-for-tests lacks it. It's the runtime, not the model, that's missing (writer/v2).
    public static let localUnavailable = "Not in this version. This copy of DayDream can't write summaries on this Mac."
    /// Settings › Summaries' form of `localUnavailable` (the second sentence only repeated the first).
    public static let localUnavailableShort = "Not in this version."
    /// What cloud summaries send, and to whom (item 21): the one line under the "Cloud summaries" switch in setup and
    /// Settings (`CloudSummariesText.line`). No consent sheet: the switch and this line are the question.
    public static let cloudShort = CloudSummariesText.line
}

public struct DaydreamOnboardingShell<Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let appURL: URL
    private let back: (() -> Void)?
    private let continueTitle: String
    private let canContinue: Bool
    private let working: Bool
    private let secondaryTitle: String?
    private let secondary: (() -> Void)?
    private let continueAction: () -> Void
    private let content: Content
    private let height: CGFloat
    private let showsIcon: Bool

    /// `showsIcon`: the 56 pt app icon over the title. Setup's later steps pass false: it repeats on every
    /// step and its height pushed controls below the fold. Those steps also show the scroll indicator
    /// when their content overflows, so a control below the fold is never missed.
    public init(title: String, subtitle: String? = nil, appURL: URL = Bundle.main.bundleURL,
                back: (() -> Void)? = nil, continueTitle: String = "Continue",
                canContinue: Bool = true, working: Bool = false,
                secondaryTitle: String? = nil, secondary: (() -> Void)? = nil,
                height: CGFloat = 600, showsIcon: Bool = true,
                continueAction: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.appURL = appURL
        self.back = back
        self.continueTitle = continueTitle
        self.canContinue = canContinue
        self.working = working
        self.secondaryTitle = secondaryTitle
        self.secondary = secondary
        self.continueAction = continueAction
        self.content = content()
        self.height = height
        self.showsIcon = showsIcon
    }

    public var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 9) {
                if showsIcon {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable().interpolation(.high).frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                }
                Text(title).font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                ScrollView(showsIndicators: !showsIcon) {
                    VStack(alignment: .leading, spacing: 12) {
                        content
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }
                .scrollIndicators(showsIcon ? .hidden : .automatic)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            HStack(spacing: 12) {
                if let back {
                    Button(action: back) {
                        Label("Back", systemImage: "chevron.left")
                    }.buttonStyle(DaydreamOnboardingBackStyle()).disabled(working)
                    .settingsElement("setup.back", "Back")
                } else {
                    Color.clear.frame(width: 74, height: 36).accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                if let secondaryTitle, let secondary {
                    Button(secondaryTitle, action: secondary).buttonStyle(.link)
                        .font(.system(size: 12)).disabled(working)
                }
                Spacer(minLength: 0)
                Button(action: continueAction) {
                    HStack(spacing: 7) {
                        if working { ProgressView().controlSize(.small).tint(.white) }
                        Text(continueTitle).lineLimit(1)
                    }.frame(minWidth: 96)
                }
                .buttonStyle(DaydreamOnboardingPrimaryStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue || working)
            }.frame(height: 36)
        }
        .padding(.horizontal, 36).padding(.top, 26).padding(.bottom, 30)
        .frame(width: 660, height: height)
        .background(DaydreamOnboardingTheme.window)
        .scrollIndicators(.hidden)
    }
}

public struct DaydreamPermissionSettings: View {
    @Environment(\.dismiss) private var dismiss
    private let enabled: Bool
    private let appURL: URL
    private let readAccessibility: () -> Bool
    private let readInputMonitoring: () -> Bool
    private let recoveryExpandedInitially: Bool
    private let known: PermissionSnapshot
    private let allowedBefore: Bool
    private let onDone: (() -> Void)?

    /// `known`, `allowedBefore`: what the app last showed of the permissions and whether setup was finished
    /// (`PermissionGrantView`: the cards open on it, and a moment's "not allowed" never draws a button).
    public init(enabled: Bool = true, appURL: URL = Bundle.main.bundleURL,
                readAccessibility: @escaping () -> Bool = { AXIsProcessTrusted() },
                readInputMonitoring: @escaping () -> Bool = { CGPreflightListenEventAccess() },
                recoveryExpandedInitially: Bool = false,
                known: PermissionSnapshot = PermissionSnapshot(), allowedBefore: Bool = false,
                onDone: (() -> Void)? = nil) {
        self.known = known
        self.allowedBefore = allowedBefore
        self.enabled = enabled
        self.appURL = appURL
        self.readAccessibility = readAccessibility
        self.readInputMonitoring = readInputMonitoring
        self.recoveryExpandedInitially = recoveryExpandedInitially
        self.onDone = onDone
    }

    public var body: some View {
        DaydreamOnboardingShell(title: "DayDream permissions",
            appURL: appURL, continueTitle: "Done", height: 500, continueAction: close) {
            PermissionGrantView(enabled: enabled, appURL: appURL,
                readAccessibility: readAccessibility, readInputMonitoring: readInputMonitoring,
                embedded: true, recoveryExpandedInitially: recoveryExpandedInitially,
                known: known, allowedBefore: allowedBefore)
        }
        .onExitCommand(perform: close)
    }

    private func close() {
        if let onDone { onDone() }
        else { dismiss() }
    }
}

/// Setup's summaries page (owner, 9/28): two rows, one state at a time. "Summaries on this Mac" (on by default where the Mac
/// can run the model, with its one line) and "Use an OpenRouter key instead" (its one honest line, and the key field while
/// it is on). Turning one on turns the other off; both off is Off. No consent sheet: the switch and its line are the question.
public struct DaydreamSummariesContent: View {
    @Binding private var choice: DaydreamSummaryChoice
    @Binding private var cloudKey: String
    private let localAvailable: Bool
    private let localLine: String
    private let savedKey: Bool
    private let problem: SummaryProblem?
    private let fix: ((SummaryProblem) -> Void)?
    private let focusRequest: Int

    public static let localTitle = "Summaries on this Mac"
    /// Row 1's line before anything is downloaded: the size, once, and where it runs.
    public static func localLine(size: String) -> String { "Downloads \(size) once. Runs on this Mac." }
    public static let localReadyLine = "Runs on this Mac."

    /// - `localAvailable`: this build can summarize on this Mac (every release; a test build staged without the runtime
    ///   shows only the OpenRouter row).
    /// - `localLine`: row 1's one line (the size before a download, or the download's own state line).
    /// - `savedKey`: a cloud key is already saved; the empty field then says it will use it.
    /// - `problem`, `fix`: the key Continue tried was refused (or the account can't be used): its line and one button.
    public init(choice: Binding<DaydreamSummaryChoice>, cloudKey: Binding<String>, localAvailable: Bool = true,
                localLine: String = DaydreamSummariesContent.localLine(size: "2.7 GB"), savedKey: Bool = false,
                problem: SummaryProblem? = nil, fix: ((SummaryProblem) -> Void)? = nil, focusRequest: Int = 0) {
        _choice = choice
        _cloudKey = cloudKey
        self.localAvailable = localAvailable
        self.localLine = localLine
        self.savedKey = savedKey
        self.problem = problem
        self.fix = fix
        self.focusRequest = focusRequest
    }

    /// The two switches are one choice: turning one on turns the other off; both off is Off (`later`).
    public static func choice(after current: DaydreamSummaryChoice, set value: DaydreamSummaryChoice, on: Bool) -> DaydreamSummaryChoice {
        on ? value : current == value ? .later : current
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if localAvailable {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.localTitle).font(.system(size: 13, weight: .semibold))
                        Text(localLine).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Toggle(Self.localTitle, isOn: Binding(get: { choice == .local }, set: { choice = Self.choice(after: choice, set: .local, on: $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .accessibilityLabel(Self.localTitle)
                }
                .accessibilityElement(children: .combine)
                Divider().opacity(0.65)
            }
            CloudSummariesSwitch(isOn: Binding(get: { choice == .cloud }, set: { choice = Self.choice(after: choice, set: .cloud, on: $0) }),
                                 key: $cloudKey, showsKey: choice == .cloud, savedKey: savedKey,
                                 problem: choice == .cloud ? problem : nil, fix: fix, focusRequest: focusRequest, large: true)
        }
        .padding(16)
        .background(DaydreamOnboardingTheme.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.07), radius: 7, y: 3)
    }
}

public struct DaydreamAppsContent: View {
    private let apps: [LocalApp]
    private let excluded: Set<String>
    @Binding private var query: String
    @Binding private var typedText: Bool
    private let loaded: Bool
    private let enabled: Bool
    private let allowTyping: Bool
    private let fillsAvailableHeight: Bool
    private let compact: Bool
    private let browserPages: Bool
    /// Setup's "Web pages in Chrome" switch (opt-out); nil where the release has no Chrome page history.
    private let chromePages: Binding<Bool>?
    private let toggle: (String) -> Void
    @State private var focusedApp: String?

    /// The typed-text switch's title and VoiceOver label say where this build records typing (apps only in a
    /// narrow build; apps and websites in Chrome in the full-typing build every release stage makes). Nothing sits
    /// under it (sat5: the switch says on and off); which apps and websites it covers is in the Turn on typing sheet.
    public static var typedTextLabel: String { TypingSettingsText.setupLabel() }
    public static var typedTextTitle: String { TypingSettingsText.setupTitle() }
    /// Setup's typing switch, in one line (owner 9/28). Password fields are never read (`TypedSecretScrubber`, secure input).
    public static let typingSwitchTitle = "Remember what you type (skips password fields)"
    /// Where typing works, under the switch in Settings and first on the setup screen (owner/v1 review
    /// F4). Public text carries no website strings.
    #if DAYDREAM_OWNER_TYPING
    public static var typedTextScope: String { "\(TypingSettingsText.allowedAppsPhrase()), and websites in Google Chrome while Web pages in Chrome is on" }
    public static let websiteTypingBullet: String? = "Also saves what you type on websites in Google Chrome while Web pages in Chrome is on, except blocked sites. Never in Incognito or Guest windows."
    #else
    public static var typedTextScope: String { "\(TypingSettingsText.allowedAppsPhrase()) only" }
    public static let websiteTypingBullet: String? = nil
    #endif
    /// The list's height at the 660x600 setup window; `compactListHeight` while a problem or notice line sits above it.
    /// fix/setup-2switch (owner, 9/28: "2 settings and then also make the apps to remember a little taller"): two
    /// switches under the list, so it takes the Messages and email row's room and the empty space above Back and
    /// Continue: six rows, the seventh half showing that it scrolls (40 pt rows). Back and Continue stay where they were.
    public static let listHeight: CGFloat = 260
    public static let compactListHeight: CGFloat = 200

    /// - `browserPages`: the saved "Web pages in Chrome" switch.
    /// - `chromePages`: setup's own "Web pages in Chrome" switch, shown beside typing (both start on in a first setup).
    ///   Messages and email has no switch here: it follows typing (`DaydreamOnboardingMessages`); Settings has its checkbox.
    /// - `compact`: a problem or notice line is shown above the page, so the list is shorter and the typed-text
    ///   row still fits without scrolling.
    public init(apps: [LocalApp], excluded: Set<String>, query: Binding<String>, browserPages: Bool = false,
                chromePages: Binding<Bool>? = nil, typedText: Binding<Bool>,
                loaded: Bool, enabled: Bool, allowTyping: Bool = true, fillsAvailableHeight: Bool = false,
                compact: Bool = false, toggle: @escaping (String) -> Void) {
        self.apps = apps
        self.browserPages = browserPages
        self.chromePages = chromePages
        self.excluded = excluded
        _query = query
        _typedText = typedText
        self.loaded = loaded
        self.enabled = enabled
        self.allowTyping = allowTyping
        self.fillsAvailableHeight = fillsAvailableHeight
        self.compact = compact
        self.toggle = toggle
    }


    private var matches: [LocalApp] {
        apps.filter { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search apps", text: $query).textFieldStyle(.plain)
                        .font(.system(size: 13)).accessibilityLabel("Search apps to remember")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Clear search").accessibilityLabel("Clear app search")
                    }
                }.padding(.horizontal, 11).frame(height: 32)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.07)))
                Group {
                    if !loaded {
                        ProgressView("Loading apps").font(.system(size: 12)).frame(maxWidth: .infinity)
                    } else if matches.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(.secondary)
                            Text(query.isEmpty ? "No apps found" : "No matching apps").font(.system(size: 13, weight: .medium))
                        }.frame(maxWidth: .infinity)
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 0) {
                                ForEach(matches) { app in appRow(app) }
                            }
                        }.accessibilityLabel("Apps to remember")
                    }
                }
                // At the 660x600 setup window the two switch rows must fit below the list without
                // scrolling (the scroll indicators are hidden, so a cut-off row is missed); shorter with a line above.
                .frame(minHeight: fillsAvailableHeight ? 80 : listHeight, idealHeight: listHeight,
                    maxHeight: fillsAvailableHeight ? .infinity : listHeight)
                .scrollIndicators(.hidden)
            }
            .padding(12)
            .background(DaydreamOnboardingTheme.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06)))
            .shadow(color: .black.opacity(0.07), radius: 7, y: 3)
            // The own-Mac notice (legal §11.4) is on the review page (`DaydreamSetupText.ownMac`). No footnote under the
            // list (fix/setup-tweaks, owner 9/28): the checkboxes say what is recorded.
            // Typing and Web pages in Chrome (owner, 9/28): one line each, the switch beside it. Both are on unless the
            // person turned one off (SetupChoices); one click turns either off. Only these two (fix/setup-2switch):
            // Messages and email follows typing, so nothing appears or moves when typing is switched.
            VStack(alignment: .leading, spacing: 10) {
                switchRow(Self.typingSwitchTitle, isOn: $typedText, label: Self.typedTextLabel, enabled: enabled && allowTyping)
                if let chromePages {
                    // fix/sx-all round 2: the switch starts on, so its one line says what it saves and who gets it.
                    switchRow(ChromePagesCard.title, isOn: chromePages, label: ChromePagesCard.switchLabel, enabled: enabled && allowTyping,
                              line: ChromePagesCard.setupLine)
                }
            }.padding(.horizontal, 3).padding(.top, 4)
        }
    }

    private var listHeight: CGFloat { compact ? Self.compactListHeight : Self.listHeight }

    private func switchRow(_ title: String, isOn: Binding<Bool>, label: String, enabled: Bool, line: String? = nil) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let line {
                    Text(line).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(!enabled)
                .accessibilityLabel(label)
        }
        .accessibilityElement(children: .combine)
    }

    private func appRow(_ app: LocalApp) -> some View {
        let mandatory = PrivacySettings.sensitiveApps.contains(app.id)
        // No web browser is recorded or offered here: Chrome pages have their own switch in Settings.
        let group = SettingsAppsContent.group(app.id, excluded: excluded, browserPages: browserPages, path: app.path)
        let browser = !mandatory && group == .notRecorded
        let fixed = mandatory || browser
        let included = !fixed && !excluded.contains(app.id)
        let duplicate = apps.contains { $0.id != app.id && $0.name == app.name }
        return HStack(spacing: 12) {
            Group {
                if app.path.isEmpty { Image(systemName: "app.dashed").font(.system(size: 24)).foregroundStyle(.secondary) }
                else { Image(nsImage: app.icon).resizable().interpolation(.high) }
            }.frame(width: 30, height: 30).saturation(browser ? 0 : 1).opacity(browser ? 0.65 : 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // A browser's label on the right says it; Chrome pages are a Settings matter.
                Text(app.name).font(.system(size: 13)).lineLimit(1).foregroundStyle(browser ? .secondary : .primary)
                if let place = Self.distinguisher(app, duplicate: duplicate) {
                    Text(place).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if mandatory {
                Label("Always private", systemImage: "lock.fill")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            } else if browser {
                Text(SettingsAppsContent.browserLabel(app.id)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            } else {
                Image(systemName: included ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18)).foregroundStyle(included ? Color.accentColor : Color.secondary.opacity(0.65))
                    .frame(width: 22, height: 24)
            }
        }
        .frame(height: 40).padding(.horizontal, 3)
        .overlay(alignment: .bottom) { Divider().opacity(0.65) }
        .accessibilityElement(children: fixed ? .combine : .ignore)
        .accessibilityHidden(!fixed)
        .overlay {
            if !fixed {
                DaydreamSelectionTarget(label: "Remember \(app.name)\(Self.distinguisher(app, duplicate: duplicate).map { ", " + $0 } ?? "")",
                    detail: included ? "Included" : "Excluded", selected: included, radio: false, enabled: enabled,
                    onFocus: { focused in focusedApp = focused ? app.id : focusedApp == app.id ? nil : focusedApp },
                    action: { toggle(app.id) })
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(focusedApp == app.id ? Color.accentColor : .clear, lineWidth: 2).allowsHitTesting(false))
        .opacity(enabled || fixed ? 1 : 0.55)
    }

    /// The small line under an app's name, in words a person reads: "Not installed" for a saved app that's
    /// gone, or the folder it's in when two apps share a name. Never a bundle ID.
    public static func distinguisher(_ app: LocalApp, duplicate: Bool) -> String? {
        if app.path.isEmpty { return "Not installed" }
        guard duplicate else { return nil }
        let folder = URL(fileURLWithPath: app.path).deletingLastPathComponent()
        return "In " + FileManager.default.displayName(atPath: folder.path)
    }
}

/// One choice on setup's last page: its name and one value ("Typed text  Off"). A row with `edit` is one click
/// back to the page where that choice is made.
public struct DaydreamReviewRow: Identifiable {
    public let id: String
    public let title: String
    public let value: String
    public let systemImage: String
    /// The value is something to fix (a permission that isn't allowed).
    public let attention: Bool
    public let edit: (() -> Void)?
    /// The row's one fixing button (Add Key, Try Again), drawn after the value instead of the chevron.
    public let button: (title: String, action: () -> Void)?

    public init(id: String, title: String, value: String, systemImage: String, attention: Bool = false, edit: (() -> Void)? = nil,
                button: (title: String, action: () -> Void)? = nil) {
        self.id = id
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.attention = attention
        self.edit = edit
        self.button = button
    }
}

/// Setup's Google Chrome step (owner, 10/1: asked for during setup, like Accessibility and Input Monitoring). One card in
/// the permission cards' style and nothing else: the page's one main button asks macOS (the app's `askChromeAccessInSetup`).
/// This view only draws the state it is given; it never reads Chrome or asks for anything.
public struct DaydreamChromeStepContent: View {
    public static let cardTitle = "Google Chrome"
    /// The page's main button until it was pressed once; then Continue.
    public static let allowTitle = "Allow Chrome"
    private let icon: NSImage?
    private let access: ChromeAccessState
    private let asked: Bool

    public init(icon: NSImage?, access: ChromeAccessState, asked: Bool) {
        self.icon = icon
        self.access = access
        self.asked = asked
    }

    /// The one line under the card: nothing before the press, nothing while macOS asks or once it answered. A press macOS
    /// couldn't answer says why (the copy the state already uses in Settings). Nothing asks later (chromeask-1005).
    public static func line(access: ChromeAccessState, asked: Bool) -> String? {
        guard asked else { return nil }
        switch access {
        case .checking, .allowed, .denied, .askFailed: return nil
        case .unverified, .twoCopies, .chromeNotRunning: return access.helper
        case .unknown, .notAsked: return nil
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Group {
                    if let icon { Image(nsImage: icon).resizable().interpolation(.high) }
                    else { Image(systemName: "globe").font(.system(size: 28)).foregroundStyle(.secondary) }
                }
                .frame(width: 44, height: 44).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.cardTitle).font(.system(size: 15, weight: .semibold))
                    Text(ChromePagesCard.setupLine).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if access == .checking {
                        ProgressView().controlSize(.small)
                    } else if access == .allowed {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(nsColor: .systemGreen))
                            Text(ChromeAccessState.allowed.value).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 74)
            .background(DaydreamOnboardingTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.cardTitle)
            .accessibilityValue(access == .checking ? ChromeAccessState.checking.value : access == .allowed ? ChromeAccessState.allowed.value : "")
            if let line = Self.line(access: access, asked: asked) {
                Text(line).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 3)
            }
        }
    }
}

/// Setup's last page: the choices, one value each, then the own-Mac line, and the FileVault line only while
/// FileVault is off. `message` is a reason recording can't start that the page's button doesn't already say.
public struct DaydreamReviewContent: View {
    private let rows: [DaydreamReviewRow]
    private let message: String?
    private let fileVaultOff: Bool

    public init(rows: [DaydreamReviewRow], message: String? = nil, fileVaultOff: Bool = false) {
        self.rows = rows
        self.message = message
        self.fileVaultOff = fileVaultOff
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    DaydreamReviewRowView(row: row)
                    if row.id != rows.last?.id { Divider() }
                }
            }.padding(.horizontal, 8)
            .background(DaydreamOnboardingTheme.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06)))
            .shadow(color: .black.opacity(0.07), radius: 7, y: 3)
            VStack(alignment: .leading, spacing: 6) {
                if fileVaultOff { notice("lock.open", DaydreamSetupText.fileVault) }
                notice("person", DaydreamSetupText.ownMac)
            }
            .padding(.horizontal, 3)
            if let message, !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 3)
            }
        }
    }

    private func notice(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A review row: the whole row is the button when it can be changed (a chevron says so).
private struct DaydreamReviewRowView: View {
    let row: DaydreamReviewRow
    @State private var hovered = false

    var body: some View {
        if let button = row.button {
            HStack(spacing: 14) {
                Image(systemName: row.systemImage).font(.system(size: 17))
                    .foregroundStyle(.secondary).frame(width: 26, height: 26).accessibilityHidden(true)
                Text(row.title).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 12)
                Text(row.value).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                Button(button.title, action: button.action).controlSize(.small)
            }
            .padding(.horizontal, 10).frame(height: 48)
            .accessibilityElement(children: .contain)
        } else if let edit = row.edit {
            Button(action: edit) { content(chevron: true) }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .accessibilityLabel(row.title)
                .accessibilityValue(row.value)
                .accessibilityHint("Change " + row.title.lowercased())
        } else {
            content(chevron: false).accessibilityElement(children: .combine)
        }
    }

    private func content(chevron: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: row.systemImage).font(.system(size: 17))
                .foregroundStyle(.secondary).frame(width: 26, height: 26).accessibilityHidden(true)
            Text(row.title).font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 12)
            Text(row.value).font(.system(size: 13))
                .foregroundStyle(row.attention ? Color.orange : Color.secondary).lineLimit(1)
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10).frame(height: 48)
        .background(Color.primary.opacity(hovered ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

private struct DaydreamSelectionTarget: NSViewRepresentable {
    @Environment(\.isEnabled) private var environmentEnabled
    let label: String
    let detail: String
    let selected: Bool
    let radio: Bool
    let enabled: Bool
    let onFocus: (Bool) -> Void
    let action: () -> Void

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func press() { action() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = AppSelectionButton(title: "", target: context.coordinator, action: #selector(Coordinator.press))
        button.isBordered = false
        button.focusRingType = .none
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        (button as? AppSelectionButton)?.focusChanged = onFocus
        button.isEnabled = enabled && environmentEnabled
        button.setAccessibilityRole(radio ? .radioButton : .checkBox)
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp(detail)
        button.setAccessibilityValue(selected ? 1 : 0)
    }
}

enum DaydreamOnboardingTheme {
    static let window = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.14, alpha: 1)
            : NSColor(srgbRed: 0.92, green: 0.93, blue: 0.945, alpha: 1)
    })
    static let card = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.21, alpha: 1)
            : NSColor(srgbRed: 0.95, green: 0.96, blue: 0.975, alpha: 1)
    })
    static let selected = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.17, green: 0.22, blue: 0.29, alpha: 1)
            : NSColor(srgbRed: 0.925, green: 0.95, blue: 0.98, alpha: 1)
    })
}

struct DaydreamOnboardingPrimaryStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 17).frame(height: 36)
            .background(enabled ? Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1) : Color.gray.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
            .shadow(color: .black.opacity(enabled ? 0.1 : 0), radius: 3, y: 2)
    }
}

/// Setup's Back. The whole 36 pt rounded box is the button (`contentShape`): a clear background alone isn't
/// clickable, so before this only the chevron and the word responded.
struct DaydreamOnboardingBackStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14)).foregroundStyle(.primary)
            .padding(.horizontal, 10).frame(minWidth: 74).frame(height: 36)
            .background(Color.primary.opacity(configuration.isPressed ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.45)
    }
}
