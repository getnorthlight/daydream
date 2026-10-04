import SwiftUI
import AppKit
import MemoryCore

private struct ExclusionButton:NSViewRepresentable {
    let label:String; let checked:Bool; let enabled:Bool; let action:()->Void
    final class Coordinator:NSObject {
        var action:()->Void
        init(_ action:@escaping()->Void) { self.action=action }
        @objc func press() { action() }
    }
    func makeCoordinator()->Coordinator { Coordinator(action) }
    func makeNSView(context:Context)->NSButton {
        let button=AppSelectionButton(title:"",target:context.coordinator,action:#selector(Coordinator.press))
        button.isBordered=false; button.focusRingType = .exterior
        return button
    }
    func updateNSView(_ button:NSButton,context:Context) {
        context.coordinator.action=action; button.isEnabled=enabled
        button.setAccessibilityLabel(label)
        button.setAccessibilityValue(checked ? "Selected" : "Not selected")
        button.setAccessibilityHelp(enabled ? "Toggle exclusion" : "Exclusion changes unavailable or required for safety")
    }
}

public struct LocalApp:Identifiable,Equatable {
    public let id:String, name:String, path:String
    public init(id:String,name:String,path:String="") { self.id=id; self.name=name; self.path=path }
    public var icon:NSImage {
        // Resolve only the icon named by bundle metadata. Never enumerate a
        // bundle's contents. This also works when iconservices is unavailable.
        if let bundle=Bundle(path:path),let declared=bundle.object(forInfoDictionaryKey:"CFBundleIconFile") as? String,
           !declared.contains("/"),!declared.contains(".."),let resources=bundle.resourceURL {
            let name=(declared as NSString).pathExtension.isEmpty ? declared+".icns":declared
            if let image=NSImage(contentsOf:resources.appendingPathComponent(name)) {return image}
        }
        return NSWorkspace.shared.icon(forFile:path)
    }
    public static func catalog(roots:[URL]?=nil) -> [LocalApp] {
        // Metadata of installed app bundles only. Never traverse a bundle,
        // Library, private configurations or recordings. Bound folder depth.
        let fm=FileManager.default
        var found=[String:LocalApp]()
        var visited=0
        func scan(_ folder:URL,_ depth:Int) {
            guard depth <= 16,visited < 4096 else {return}
            visited += 1
            guard let children=try? fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles]) else {return}
            for url in children.sorted(by:{$0.path < $1.path}) {
                guard let values=try? url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]), values.isSymbolicLink != true else { continue }
                if url.pathExtension.lowercased() == "app" {
                    guard let bundle=Bundle(url:url), let id=bundle.bundleIdentifier, !id.isEmpty else { continue }
                    let name=(bundle.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String) ?? (bundle.object(forInfoDictionaryKey:"CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
                    if found[id] == nil {
                        found[id]=LocalApp(id:id,name:name,path:url.path)
                        // Off the main thread (callers detach): the browser test reads each Info.plist once here.
                        _ = BrowserLookalike.opensWebLinks(appAt:url)
                    }
                } else if values.isDirectory == true { scan(url,depth+1) }
            }
        }
        for root in roots ?? [URL(fileURLWithPath:"/Applications"),URL(fileURLWithPath:"/System/Applications"),fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] { scan(root,0) }
        return found.values.sorted { ($0.name,$0.id) < ($1.name,$1.id) }
    }
    public static func includingMissing(_ apps:[LocalApp],excluded:Set<String>) -> [LocalApp] {
        let known=Set(apps.map(\.id))
        return apps + excluded.subtracting(known).sorted().map { LocalApp(id:$0,name:"Unavailable app") }
    }
    public static func ranked(_ apps:[LocalApp],usage:[MemoryItem],running:Set<String>) -> [LocalApp] {
        // Only the host's already-loaded, policy-filtered local observations.
        // Counts are observations, not measured time spent or global usage.
        let grouped=Dictionary(grouping:usage.filter{ !$0.evidence.bundle.isEmpty },by:{$0.evidence.bundle})
        return apps.sorted { a,b in
            let ac=grouped[a.id]?.count ?? 0, bc=grouped[b.id]?.count ?? 0
            if ac != bc { return ac > bc }
            let at=grouped[a.id]?.compactMap{timestamp($0.evidence.at)}.max() ?? .distantPast
            let bt=grouped[b.id]?.compactMap{timestamp($0.evidence.at)}.max() ?? .distantPast
            if at != bt { return at > bt }
            if running.contains(a.id) != running.contains(b.id) { return running.contains(a.id) }
            let comparison=a.name.localizedStandardCompare(b.name)
            return comparison == .orderedSame ? a.id < b.id : comparison == .orderedAscending
        }
    }
}

public struct AppExclusionSettings:View {
    @Binding var typing:Bool; @Binding var excluded:String
    let dirty:Bool; let status:String; let save:()->Void; let review:()->Void
    @State private var apps:[LocalApp]; @State private var loaded:Bool
    @State private var query=""
    @State private var expanded=false
    let usage:[MemoryItem]
    let allowTyping:Bool
    let persistenceAvailable:Bool
    let recordingControl:AnyView
    public init(typing:Binding<Bool>,excluded:Binding<String>,dirty:Bool,status:String,fixtures:[LocalApp]?=nil,usage:[MemoryItem]=[],allowTyping:Bool=true,persistenceAvailable:Bool=false,expandedInitially:Bool=false,recordingControl:AnyView=AnyView(EmptyView()),save:@escaping()->Void,review:@escaping()->Void) {
        _typing=typing; _excluded=excluded; self.dirty=dirty; self.status=status; self.save=save; self.review=review
        self.usage=usage
        self.allowTyping=allowTyping
        self.persistenceAvailable=persistenceAvailable
        self.recordingControl=recordingControl;_expanded=State(initialValue:expandedInitially)
        let selected=Set(excluded.wrappedValue.split(separator:",").map{$0.trimmingCharacters(in:.whitespaces)})
        _apps=State(initialValue:fixtures.map{LocalApp.includingMissing($0,excluded:selected)} ?? []); _loaded=State(initialValue:fixtures != nil)
    }
    private var selected:Set<String> { Set(excluded.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }) }
    private var rows:[LocalApp] { apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) } }
    public var body:some View {
        SettingsSurface("Recording") {
            SettingsCard {
                recordingControl
                Button {expanded.toggle()} label:{
                    SettingsRow("Excluded apps") {
                        HStack(spacing:6) {
                            HStack(spacing:-4) {ForEach(Array(apps.filter{selected.contains($0.id)}.prefix(4))) {app in Image(nsImage:app.icon).resizable().frame(width:16,height:16)}}
                            Text("\(selected.count) excluded");Image(systemName:expanded ? "chevron.up":"chevron.down").font(.system(size:9))
                        }.foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain).accessibilityLabel("Excluded apps, \(selected.count), \(expanded ? "expanded":"collapsed")")
                if expanded {
                TextField("Search installed apps",text:$query).textFieldStyle(ReferenceInputStyle()).accessibilityLabel("Search apps to exclude")
                if !loaded { ProgressView("Loading installed apps") }
                else if rows.isEmpty { Text(query.isEmpty ? "No installed apps found. Saved exclusions are still enforced." : "No matching apps.").foregroundStyle(.secondary) }
                ScrollView {LazyVStack(spacing:0) {
                    ForEach(rows) { app in appButton(app) }
                }}.frame(height:220).padding(.trailing,8).accessibilityLabel("Apps to exclude")
                }
            }
            SettingsCard {
                SettingsRow("Typed text in browsers") {Text("Not recorded in this version").foregroundStyle(.secondary)}.opacity(0.4)
                Toggle("Typed text in other apps",isOn:$typing).toggleStyle(ReferenceToggleStyle()).frame(minHeight:36).disabled(!allowTyping || !persistenceAvailable)
                DisclosureGroup("Privacy details") {
                    Text("Typed text is currently supported in TextEdit and Notes only.").foregroundStyle(.secondary)
                    Text("Without typing, new activity keeps permitted app/window metadata. Selections and field contents are never collected. Exclusions hide retained history; deletion is separate.").font(.system(size:14)).foregroundStyle(.secondary)
                    Button("Recording requirements",action:review)
                }
            }
            if !persistenceAvailable {Text("Settings changes unavailable until safe saving is ready.").font(.system(size:14)).foregroundStyle(.secondary)}
            else if !status.isEmpty {Text(status).font(.system(size:14)).foregroundStyle(.secondary).accessibilityLabel(status)}
        }.task {
            if !loaded {
                let snapshot=usage, exclusions=selected
                let running=Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
                let catalog=await Task.detached(priority:.utility) { LocalApp.catalog() }.value
                apps=LocalApp.ranked(LocalApp.includingMissing(catalog,excluded:exclusions),usage:snapshot,running:running)
                loaded=true // Frozen for this view lifetime, including check/uncheck and search.
            }
        }
    }
    private func appButton(_ app:LocalApp) -> some View {
        let mandatory=PrivacySettings.sensitiveApps.contains(app.id)
        let checked=selected.contains(app.id) || mandatory
        let duplicate=apps.filter { $0.name == app.name }.count > 1
        // Web browsers aren't recorded (Chrome pages have their own switch on the Apps to remember page).
        let state=mandatory ? "Always private" : checked ? "Excluded by you"
            : SettingsAppsContent.isBrowser(app.id,path:app.path) ? SettingsAppsContent.notRecordedLabel : "Included"
        let toggle = {
            var next=selected
            if next.contains(app.id) { next.remove(app.id) } else { next.insert(app.id) }
            excluded=next.sorted().joined(separator:", ")
        }
        return HStack(spacing:10) {
                Group {
                    if app.path.isEmpty { Image(systemName:"app.dashed").font(.system(size:14)).frame(width:16,height:16) }
                    else { Image(nsImage:app.icon).resizable().frame(width:16,height:16) }
                }.saturation(checked ? 0:1).opacity(checked ? 0.7:1)
                VStack(alignment:.leading,spacing:3) {
                    Text(app.name).lineLimit(2).foregroundStyle(.primary)
                    Text(state).font(.system(size:14)).foregroundStyle(.secondary)
                    if app.path.isEmpty || duplicate { Text(app.id).font(.system(size:14)).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength:0)
                Image(systemName:checked ? "checkmark.circle.fill" : "circle").foregroundStyle(checked ? Color.accentColor : Color.secondary)
            }.padding(.horizontal,4).frame(minHeight:48).frame(maxWidth:.infinity,alignment:.leading)
          .overlay(alignment:.bottom) { Divider() }
          .accessibilityHidden(true)
          .overlay(ExclusionButton(label:"\(app.name)\(duplicate || app.path.isEmpty ? ", " + app.id : ""), \(state)",checked:checked,enabled:!mandatory && persistenceAvailable,action:toggle))
          .help(app.path.isEmpty ? "Not currently installed: \(app.id). Exclusion is retained." : app.path)
    }
}

// MARK: - Settings ▸ Apps to remember (spec §6.4)

/// The Apps to remember page: search, then one list in the order Excluded by you, Always private,
/// Web browsers, Included in recording, drawn without group headers, counts, a footnote or Chrome's
/// "Page titles and sites" line (fix/apps-declutter, owner 9/29: too cluttered); a row's end says its
/// group: a checkbox, a lock (always private) or a browser's label. Web browsers are listed by what really happens: Google
/// Chrome saves page titles and sites only while "Web pages in Chrome" is on (it is then Included in
/// recording); every other browser, and Chrome in a release without page history
/// (`ReleaseFeatures.chromePageHistory`), reads "Not recorded in this version". A browser DayDream
/// doesn't know by name is found by its Info.plist (`BrowserLookalike`: it opens web links) and is
/// listed with the others. Apps that are not recorded show greyscale icons; always-private apps and
/// browsers can't be changed here. DayDream itself is not listed (plan §3: always private means
/// `sensitiveApps` minus DayDream, the same set the overview counts). Without `chromePages` the list is
/// the page's only scroll view and the typed-text choices sit in their own grouped card under it. With
/// it (Chrome page history), the "Web pages in Chrome" card and the typed-text card share a second
/// scroll view under the list: the card's explanation is always shown and does not fit beside the list
/// at 600×500.
public struct SettingsAppsContent: View {
    private let apps: [LocalApp]
    private let excluded: Set<String>
    @Binding private var query: String
    @Binding private var typedText: Bool
    private let loaded: Bool
    private let enabled: Bool
    private let allowTyping: Bool
    private let browserPages: Bool
    private let chromePages: AnyView?
    private let typing: AnyView?
    private let toggle: (String) -> Void

    /// - `browserPages`: the saved "Web pages in Chrome" switch; Google Chrome is then Included in recording.
    /// - `chromePages`: the `ChromePagesCard`, drawn above the typed-text card; nil draws the page without it.
    /// - `typing`: the Typing card (`TypingSettingsCard`), drawn next to "Web pages in Chrome" in place of
    ///   the older typed-text switch card; nil keeps that card.
    public init(apps: [LocalApp], excluded: Set<String>, query: Binding<String>, typedText: Binding<Bool>,
                loaded: Bool, enabled: Bool, allowTyping: Bool = true, browserPages: Bool = false,
                chromePages: AnyView? = nil, typing: AnyView? = nil, toggle: @escaping (String) -> Void) {
        self.apps = apps; self.excluded = excluded; _query = query; _typedText = typedText
        self.loaded = loaded; self.enabled = enabled; self.allowTyping = allowTyping
        self.browserPages = browserPages; self.chromePages = chromePages; self.typing = typing; self.toggle = toggle
    }

    /// The bottom fade over the app list.
    public static let fadeHeight: CGFloat = 12
    /// The app list's height in Settings: about eight rows.
    public static let listHeight: CGFloat = 340

    public enum AppGroup: String, CaseIterable {
        case excludedByYou = "Excluded by you", alwaysPrivate = "Always private", notRecorded = "Web browsers"
        case included = "Included in recording"
    }

    /// Google Chrome, the one browser page history can record.
    public static let chromeBundle = "com.google.Chrome"
    /// The Chrome row's subtitle while its page titles and sites are recorded.
    public static let chromeSubtitle = "Page titles and sites"
    /// The Chrome row's subtitle while "Web pages in Chrome" is off.
    public static let chromeOffSubtitle = "Page titles and sites, only when Web pages in Chrome is on"
    /// The label of a browser that is not recorded in this build.
    public static let notRecordedLabel = "Not recorded in this version"
    /// The label of Google Chrome while "Web pages in Chrome" is off.
    public static let chromeOffLabel = "Off"

    /// A web browser, known by name or found by its Info.plist (`path`, when the app is installed).
    public static func isBrowser(_ id: String, path: String = "") -> Bool {
        BrowserLookalike.skips(id, appURL: path.isEmpty ? nil : URL(fileURLWithPath: path))
    }

    /// The app's group: built-in private apps first, then the person's exclusions, then web browsers,
    /// which aren't recorded except Google Chrome while "Web pages in Chrome" is on.
    public static func group(_ id: String, excluded: Set<String>, browserPages: Bool = false, path: String = "") -> AppGroup {
        if PrivacySettings.sensitiveApps.contains(id) { return .alwaysPrivate }
        if excluded.contains(id) { return .excludedByYou }
        if isBrowser(id, path: path) && !(id == chromeBundle && browserPages && ReleaseFeatures.chromePageHistory) { return .notRecorded }
        return .included
    }

    /// The listed apps by group, in page order, without DayDream itself; `query` filters by name or ID.
    public static func grouped(_ apps: [LocalApp], excluded: Set<String>, query: String = "",
                               browserPages: Bool = false) -> [(group: AppGroup, apps: [LocalApp])] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let listed = apps.filter { !DaydreamNotes.ownBundles.contains($0.id)
            && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q)) }
        return AppGroup.allCases.compactMap { group in
            let members = listed.filter { Self.group($0.id, excluded: excluded, browserPages: browserPages, path: $0.path) == group }
            return members.isEmpty ? nil : (group, members)
        }
    }

    /// The line under an app's name. Google Chrome: `Page titles and sites` while its pages are recorded,
    /// `Page titles and sites, only when Web pages in Chrome is on` while the switch is off. nil otherwise,
    /// and always nil for Chrome in a release without page history.
    public static func subtitle(_ id: String, group: AppGroup) -> String? {
        guard id == chromeBundle, ReleaseFeatures.chromePageHistory else { return nil }
        switch group {
        case .included: return chromeSubtitle
        case .notRecorded: return chromeOffSubtitle
        default: return nil
        }
    }

    /// The label at the end of a Web browsers row: `Off` for Google Chrome while its switch is off,
    /// `Not recorded in this version` for every other browser.
    public static func browserLabel(_ id: String) -> String {
        id == chromeBundle && ReleaseFeatures.chromePageHistory ? chromeOffLabel : notRecordedLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                }
                .padding(.horizontal, 11).frame(height: 32)
                .daydreamField()
                // A fixed height of about eight rows: the page scrolls as a whole (Settings wraps it in
                // DaydreamSettingsScroll), so the list never shrinks to a few rows on a short window.
                list.frame(height: Self.listHeight)
            }
            .padding(12)
            .daydreamCard()
            if let chromePages { chromePages }
            typingSection
        }
    }

    @ViewBuilder private var typingSection: some View {
        if let typing { typing } else { typingCard }
    }

    private var typingCard: some View {
        SettingsListCard {
            // Where this build records typing ("Notes and TextEdit only" in a narrow build; apps and
            // websites in Chrome in the full-typing build).
            typingChoice("keyboard", tint: DaydreamStyle.model, DaydreamAppsContent.typedTextTitle, detail: DaydreamAppsContent.typedTextScope,
                         label: DaydreamAppsContent.typedTextLabel) {
                Toggle(DaydreamAppsContent.typedTextTitle, isOn: $typedText).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!(enabled && allowTyping)).accessibilityLabel(DaydreamAppsContent.typedTextLabel)
            }
            // Owner builds type websites through the typing categories ("Other websites").
            if !TypingSettingsText.ownerBuild { websitesChoice }
        }
    }

    private var websitesChoice: some View {
        Group {
            Rectangle().fill(DaydreamStyle.hairline).frame(height: 1).padding(.leading, 56).padding(.trailing, 10)
                .accessibilityHidden(true)
            typingChoice("globe", tint: Color(nsColor: .systemBlue), "Typed text on websites", detail: "In web browsers",
                         label: "Typed text on websites, not recorded in this version") {
                HStack(spacing: 10) {
                    Text("Not recorded in this version").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                    Toggle("Typed text on websites", isOn: .constant(false)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(true).accessibilityLabel("Typed text on websites, not recorded in this version")
                }
            }
        }
    }

    @ViewBuilder private var list: some View {
        let groups = Self.grouped(apps, excluded: excluded, query: query, browserPages: browserPages)
        if !loaded {
            ProgressView("Loading apps").font(.system(size: 12)).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(.secondary)
                Text(query.isEmpty ? "No apps found" : "No matching apps").font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // One list in group order, no group headers or counts (fix/apps-declutter, owner 9/29): each row's
                    // end says it (a checkbox, a lock, or a browser's label).
                    ForEach(groups, id: \.group) { entry in
                        ForEach(entry.apps) { app in row(app, group: entry.group) }
                    }
                }
                // The last row clears the fade once the list is scrolled to its end.
                .padding(.bottom, Self.fadeHeight)
            }
            .scrollIndicators(.hidden)
            // The same short fade as the Settings pages (`DaydreamSettingsScroll`), in the card's colour: the list
            // continues below the card's edge instead of stopping at a hard cut.
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [DaydreamStyle.card.opacity(0), DaydreamStyle.card], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.fadeHeight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel("Apps to remember")
        }
    }

    private func row(_ app: LocalApp, group: AppGroup) -> some View {
        let recorded = group == .included
        let fixed = group == .alwaysPrivate || group == .notRecorded
        let duplicate = apps.contains { $0.id != app.id && $0.name == app.name }
        return HStack(spacing: 12) {
            Group {
                if app.path.isEmpty { Image(systemName: "app.dashed").font(.system(size: 22)).foregroundStyle(.secondary) }
                else { Image(nsImage: app.icon).resizable().interpolation(.high) }
            }
            .frame(width: 28, height: 28)
            .saturation(recorded ? 1 : 0).opacity(recorded ? 1 : 0.65)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.system(size: 13)).lineLimit(1).foregroundStyle(recorded ? .primary : .secondary)
                if duplicate || app.path.isEmpty {
                    Text(app.id).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch group {
            case .alwaysPrivate:
                Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 24).help("Always private").accessibilityLabel("Always private")
            case .notRecorded:
                Text(Self.browserLabel(app.id)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            case .excludedByYou, .included:
                Image(systemName: recorded ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17)).foregroundStyle(recorded ? Color.accentColor : Color.secondary.opacity(0.65))
                    .frame(width: 22, height: 24)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 40).padding(.horizontal, 3)
        .overlay(alignment: .bottom) { Rectangle().fill(DaydreamStyle.hairline).frame(height: 1).padding(.leading, 43) }
        .accessibilityElement(children: fixed ? .combine : .ignore)
        .overlay {
            if !fixed {
                ExclusionButton(label: "Include \(app.name) in recording\(duplicate || app.path.isEmpty ? ", " + app.id : "")",
                                checked: recorded, enabled: enabled, action: { toggle(app.id) })
            }
        }
        .opacity(enabled || fixed ? 1 : 0.55)
        .help(app.path.isEmpty ? "Not currently installed. Saved exclusion is retained: \(app.id)" : app.path)
    }

    /// One 52 pt typed-text row: a tinted symbol tile, the title and detail, then its control.
    private func typingChoice<Control: View>(_ symbol: String, tint: Color, _ title: String, detail: String, label: String,
                                             @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            control()
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
    }
}
