import SwiftUI
import AppKit
import MemoryCore

/// Settings › Advanced (declutter): what was left of "Recording requirements" once its copies of the
/// Permissions page, the Apps page, Connections and Report a Problem were cut. The rename move's notice and
/// the recorder replacement card show only when they apply; then the page's links (`links`), a retention
/// line when history expires (`retention`), and Uninstall DayDream… as one row. The type keeps its name
/// for the UIRender screens.
public struct MacMemSetupView: View {
    /// The rename page, linked from the move notice (a URL, never a repo path).
    public static let renameURL = URL(string: "https://github.com/getnorthlight/daydream/blob/main/docs/rename.md")!
    public static let moveNoticeTitle = "Your history hasn't moved to the DayDream folder yet"
    public static let replacementDetail = "Your history and settings stay. You can roll back."
    public static let uninstallTitle = "Uninstall DayDream…"
    @State private var legacy: LegacyFootprint?
    @State private var showReplacement = false
    @State private var uninstalling = false
    /// The rename move's notice (U4) stays hidden once dismissed, until a different reason appears.
    @AppStorage("DayDreamMoveNoticeHidden") private var hiddenMoveNotice = ""
    let reviewLegacy: () -> LegacyFootprint
    let replacementInProgress: Bool
    let pause: () -> Void
    let replacement: AnyView
    let canUninstall: () -> Bool
    let uninstaller: (any UninstallPerforming)?
    let legacyMove: DataHomeMigration.Outcome
    let links: AnyView
    let retention: String?
    /// `uninstaller`: nil in previews, where the Uninstall sheet explains that nothing can be removed.
    /// `legacyMove`: the outcome of the one-time move from Mac Mem (DaydreamLaunchSession.legacyMove).
    /// `links`: the page's link rows. `retention`: `AdvancedText.retention(days:)`, nil when history is kept.
    public init(pause: @escaping () -> Void, replacement: AnyView = AnyView(EmptyView()), canUninstall: @escaping () -> Bool = { true }, replacementInProgress:Bool=false,
                reviewLegacy:@escaping()->LegacyFootprint = { InstallationReview.legacy(at:FileManager.default.homeDirectoryForCurrentUser) },
                uninstaller: (any UninstallPerforming)? = nil, legacyMove: DataHomeMigration.Outcome = .notNeeded,
                links: AnyView = AnyView(EmptyView()), retention: String? = nil) {
        self.pause = pause; self.replacement = replacement; self.canUninstall = canUninstall; self.replacementInProgress=replacementInProgress; self.reviewLegacy=reviewLegacy
        self.uninstaller = uninstaller; self.legacyMove = legacyMove; self.links = links; self.retention = retention
    }
    public var body: some View {
        SettingsSurface("Advanced") {
            if case .deferred(let reason) = legacyMove, hiddenMoveNotice != reason {
                SettingsCard { moveNotice(reason) }
            }
            if legacy?.requiresMigration == true || replacementInProgress || showReplacement {
              SettingsCard {
                header("Recorder replacement",detail:"Review the existing recorder before enabling recording.")
                VStack(alignment:.leading,spacing:0) {
                    Divider()
                    DisclosureGroup("Guided replacement",isExpanded:$showReplacement) {
                        Text(Self.replacementDetail).font(DaydreamType.detail).foregroundStyle(.secondary)
                        replacement
                    }.padding(.vertical,3)
                }
              }
            }
            links
            if let retention {
                Label(retention, systemImage: "clock.arrow.circlepath").font(DaydreamType.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true).padding(.horizontal,4)
            }
            SettingsListCard {
                UninstallRow { uninstalling = true }
                #if DAYDREAM_LEGACY_COLLECTOR_PROBE
                // A private migration build only (InstallationReview): shipped builds never probe for an earlier recorder.
                LinkRow("Review a custom recorder installation", area: .permissions) { showReplacement = true }
                #endif
            }
        }
        .task { legacy=reviewLegacy() }
        .sheet(isPresented:$uninstalling) {
            UninstallSheet(uninstaller:uninstaller,canUninstall:canUninstall,pause:pause,close:{ uninstalling = false })
        }
    }
    private func header(_ title:String,detail:String)->some View {
        VStack(alignment:.leading,spacing:4) {
            Text(title).font(DaydreamType.itemTitle)
            Text(detail).font(DaydreamType.detail).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(.top,4)
    }
    /// U4: the one-time move from the "Mac Mem" folder waited. Says why (each reason says what to do) and links
    /// the rename page; OK hides it until a different reason appears. No Show in Finder or "checks again" line
    /// (declutter): DayDream retries on its own each time it opens, and no reason needs Finder to act on.
    private func moveNotice(_ reason:String)->some View {
        VStack(alignment:.leading,spacing:10) {
            header(Self.moveNoticeTitle,detail:reason)
            HStack {
                Link("About the move",destination:Self.renameURL).font(DaydreamType.detail)
                Spacer()
                Button("OK") { hiddenMoveNotice = reason }
            }
        }
    }
}

/// Settings › Advanced's retention line: said only when history expires. The app has no expiry control
/// (the `mac-mem` tool sets one), so with none set the page says nothing and PRIVACY.md's "until you
/// delete it" holds.
public enum AdvancedText {
    public static func retention(days: Int?) -> String? {
        guard let days, days > 0 else { return nil }
        return "History is deleted after \(days) \(days == 1 ? "day" : "days")."
    }
}

/// Uninstall DayDream… as one row, drawn in red: the sheet explains the choice.
private struct UninstallRow: View {
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "trash").font(.system(size: 12, weight: .semibold)).foregroundStyle(.red)
                    .frame(width: 24, height: 24)
                Text(MacMemSetupView.uninstallTitle).font(.system(size: 13)).foregroundStyle(.red).lineLimit(1)
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 10).frame(height: 36)
        }
        .buttonStyle(KitRowButtonStyle(radius: 8, hovered: hovered))
        .onHover { hovered = $0 }
        .accessibilityLabel(MacMemSetupView.uninstallTitle)
    }
}

/// Settings › Advanced › Uninstall DayDream. Two choices; "Remove everything" asks once more.
struct UninstallSheet: View {
    let uninstaller: (any UninstallPerforming)?
    let canUninstall: () -> Bool
    let pause: () -> Void
    let close: () -> Void
    @State private var choice: UninstallChoice = .keepHistory
    @State private var preview: Result<UninstallPlan, UninstallRefusal>?
    @State private var confirmEverything = false
    @State private var refused: String?
    @State private var finished: (UninstallPlan, UninstallReport)?
    @State private var copied = false
    @State private var details = false

    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            if let finished { done(finished.0,finished.1) } else { choose }
        }
        .padding(22).frame(width:520).font(DaydreamType.body)
        .interactiveDismissDisabled(finished != nil)
        .onAppear { refresh() }
        .onChange(of:choice) { _ in refused=nil; refresh() }
        .alert("Remove everything?",isPresented:$confirmEverything) {
            Button("Remove Everything",role:.destructive) { run() }
            Button("Cancel",role:.cancel) {}
        } message: { Text("This deletes your DayDream history and settings from this Mac. It can't be undone.") }
    }

    private var choose: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Uninstall DayDream").font(DaydreamType.sectionTitle)
            Text("DayDream moves itself to the Trash.").foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Picker("",selection:$choice) {
                option("Keep my history","Removes the app. Your history and settings stay on this Mac, so DayDream picks up where you left off if you install it again.").tag(UninstallChoice.keepHistory)
                option("Remove everything",Self.everythingDetail(legacyFolder:legacyFolder)).tag(UninstallChoice.removeEverything)
            }.pickerStyle(.radioGroup).labelsHidden()
            Divider()
            list
            if let message = refused ?? blocked { Text(message).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
            HStack {
                Spacer()
                Button("Cancel",action:close).keyboardShortcut(.cancelAction)
                Button(choice == .removeEverything ? "Remove Everything…" : "Uninstall",role:.destructive) {
                    if choice == .removeEverything { confirmEverything = true } else { run() }
                }.disabled(blocked != nil)
            }
        }
    }

    private func option(_ title:String,_ detail:String)->some View {
        VStack(alignment:.leading,spacing:2) {
            Text(title).font(DaydreamType.rowTitle)
            Text(detail).font(DaydreamType.detail).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(.vertical,3)
    }

    /// "Remove everything"'s line. The folder from before the rename is named only when there is one
    /// that this uninstall removes (or, with Keep my history picked, keeps): it can hold an older history.
    static func everythingDetail(legacyFolder: Bool) -> String {
        "Removes the app, your history and your settings" + (legacyFolder ? ", including the \(DaydreamIdentity.legacyDataFolder) folder from before the rename." : ".")
    }

    /// The previewed plan names a history folder from before the rename.
    private var legacyFolder: Bool {
        guard case .success(let plan)? = preview else { return false }
        return plan.items.contains { $0.kind == .legacyHistory } || plan.kept.contains { $0.lastPathComponent != DaydreamIdentity.dataFolder }
    }

    /// Why the Uninstall button is off right now, or nil. Before you've tried, a blocker doesn't say
    /// "Nothing was removed." (nothing was tried); a refusal after a real attempt (`refused`) does.
    private var blocked: String? {
        guard let uninstaller else { return "Uninstall isn't available in this preview. Nothing can be removed here." }
        if !canUninstall() { return "Finish or roll back the recorder replacement first." }
        if let blocker = uninstaller.blocker() { return blocker.replacingOccurrences(of: " Nothing was removed.", with: "") }
        if case .failure(let refusal)? = preview { return refusal.message }
        return nil
    }

    @ViewBuilder private var list: some View {
        if case .success(let plan)? = preview {
            VStack(alignment:.leading,spacing:6) {
                // Exceptions stay in view: what this choice would remove but leaves, and why.
                ForEach(plan.skipped.indices,id:\.self) { index in
                    Label(Self.leftInPlace(plan.skipped[index]),systemImage:"exclamationmark.circle")
                        .font(DaydreamType.detail).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                Text(Self.leftoverNote(removesHistory:plan.removesHistory)).font(DaydreamType.detail).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                // The full list, with paths, for anyone who wants to check it.
                DisclosureGroup("Details",isExpanded:$details) {
                    ScrollView {
                        VStack(alignment:.leading,spacing:4) {
                            ForEach(plan.items.indices,id:\.self) { index in
                                Label(plan.items[index].label,systemImage:"minus.circle").font(DaydreamType.detail).textSelection(.enabled)
                            }
                            ForEach(plan.kept,id:\.path) { url in
                                Label("Kept: \(url.path)",systemImage:"checkmark.circle").font(DaydreamType.detail).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }.frame(maxHeight:140)
                }.font(DaydreamType.detail)
            }
        }
    }

    /// A path this choice leaves in place, in plain words: the folder's name and the reason.
    static func leftInPlace(_ skip: UninstallSkip) -> String { "\(skip.url.lastPathComponent) won't be removed. \(skip.reason)" }

    /// What an app can't remove, said before you choose. Remove everything also names the typing key it deletes.
    static func leftoverNote(removesHistory: Bool) -> String {
        (removesHistory ? "DayDream deletes its typing key from the Keychain, if you turned on typing. " : "") + "Permissions and other Keychain items stay. The steps appear next."
    }

    private func done(_ plan:UninstallPlan,_ report:UninstallReport)->some View {
        VStack(alignment:.leading,spacing:12) {
            Text("DayDream is uninstalled").font(DaydreamType.sectionTitle)
            Text(plan.removesHistory ? "The app is in the Trash, and your history and settings are deleted. Quit DayDream to finish." : "The app is in the Trash. Your history and settings are still on this Mac. Quit DayDream to finish.")
                .fixedSize(horizontal:false,vertical:true)
            if !report.failed.isEmpty {
                VStack(alignment:.leading,spacing:4) {
                    Text("Not removed").font(DaydreamType.rowTitle)
                    ForEach(report.failed.indices,id:\.self) { index in
                        Text("\(report.failed[index].item.url.path): \(report.failed[index].reason)").font(DaydreamType.detail).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            Text("Left for you to do").font(DaydreamType.rowTitle)
            // One plain line per step; Copy Steps copies the full text with its Terminal commands.
            ScrollView {
                VStack(alignment:.leading,spacing:6) {
                    ForEach(Array(UninstallSteps.plain(choice:plan.choice,typingKey:report.typingKey).enumerated()),id:\.offset) { index,step in
                        HStack(alignment:.firstTextBaseline,spacing:6) {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(step).fixedSize(horizontal:false,vertical:true)
                        }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.frame(maxHeight:220)
            HStack {
                Button(copied ? "Copied" : "Copy Steps") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(UninstallSteps.text(choice:plan.choice,typingKey:report.typingKey),forType:.string)
                    copied = true
                }
                Spacer()
                Button("Quit DayDream") { uninstaller?.quit() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func refresh() { preview = uninstaller?.preview(choice) }

    private func run() {
        guard let uninstaller else { return }
        switch UninstallSession.run(choice,canUninstall:canUninstall,pause:pause,performer:uninstaller) {
        case .refused(let message): refused = message; refresh()
        case .done(let plan,let report): finished = (plan,report)
        }
    }
}
