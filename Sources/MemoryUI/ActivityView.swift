import SwiftUI
import AppKit
import MemoryCore

/// Reserved action slots reveal on hover or keyboard focus without reflow.
struct MemoryNoteHeading: View {
    let title:String
    let open:()->Void
    let edit:()->Void
    let delete:()->Void
    @State private var hovering=false
    @State private var actionFocused=false
    @FocusState private var focused:Int?
    var body:some View {
        HStack(alignment:.firstTextBaseline,spacing:8) {
            Button(title,action:open).buttonStyle(.plain).font(DaydreamType.itemTitle).focused($focused,equals:0)
            titleAction("Edit activity",symbol:"pencil",action:edit)
            titleAction("Delete activity",symbol:"trash",action:delete)
            Spacer(minLength:0)
        }.onHover {hovering=$0}
    }
    private func titleAction(_ label:String,symbol:String,action:@escaping()->Void)->some View {
        NativeAppButton(app:ActivityApp(name:label,bundle:""),label:label+": "+title,focusRequested:false,active:true,onFocus:{actionFocused=$0},action:action)
            .frame(width:24,height:24)
            .overlay {Image(systemName:symbol).font(.system(size:12)).foregroundStyle(.secondary).allowsHitTesting(false).accessibilityHidden(true)}
            .opacity(hovering || focused != nil || actionFocused ? 1 : 0)
            .help(label)
    }
}

final class AppSelectionButton: NSButton {
    var focusChanged:((Bool)->Void)?
    override func becomeFirstResponder()->Bool {let accepted=super.becomeFirstResponder();if accepted {DispatchQueue.main.async {[weak self] in self?.focusChanged?(true)}};return accepted}
    override func resignFirstResponder()->Bool {let accepted=super.resignFirstResponder();if accepted {DispatchQueue.main.async {[weak self] in self?.focusChanged?(false)}};return accepted}
    override var acceptsFirstResponder: Bool { true }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil); return true
    }
    override func keyDown(with event: NSEvent) {
        if isEnabled && (event.keyCode == 49 || event.keyCode == 36) { performClick(nil) }
        else { super.keyDown(with:event) }
    }
}
/// Visible tooltips come from SwiftUI `.help` at the call site; an AppKit
/// `toolTip` here outlives the window and floats over unrelated windows.
struct NativeAppButton: NSViewRepresentable {
    @Environment(\.isEnabled) private var environmentEnabled
    let app: ActivityApp
    let label: String
    let focusRequested: Bool
    let active: Bool
    var onFocus: (Bool)->Void = {_ in}
    let action: () -> Void
    final class Coordinator: NSObject {
        var action: () -> Void
        var wantsFocus = false
        var appliedFocus = false
        var active = true
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func press() { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> NSButton {
        let button = AppSelectionButton(title:"",target:context.coordinator,action:#selector(Coordinator.press))
        button.isBordered = false
        button.font = .systemFont(ofSize:11); button.focusRingType = .exterior
        button.cell?.wraps = true
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp(label)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        (button as? AppSelectionButton)?.focusChanged=onFocus
        context.coordinator.action = action
        let coordinator = context.coordinator
        coordinator.active = active && environmentEnabled; coordinator.wantsFocus = focusRequested
        if !focusRequested { coordinator.appliedFocus = false }
        // First-responder changes can invalidate SwiftUI layout. Apply them
        // after this update, and only once for each explicit return request.
        DispatchQueue.main.async {
            if button.isEnabled != coordinator.active { button.isEnabled = coordinator.active }
            if !coordinator.active, button.window?.firstResponder === button { button.window?.makeFirstResponder(nil) }
            if coordinator.active && coordinator.wantsFocus && !coordinator.appliedFocus {
                coordinator.appliedFocus = button.window?.makeFirstResponder(button) ?? false
            }
        }
    }
}

struct AppIdentityIcon: View {
    let app: ActivityApp
    var size:CGFloat = 32
    private var icon: NSImage? {
        guard !app.bundle.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier:app.bundle) else { return nil }
        return NSWorkspace.shared.icon(forFile:url.path)
    }
    var body: some View {
        Group {
            if let icon { Image(nsImage:icon).resizable().interpolation(.high) }
            // App icon artwork fills about 80% of its canvas; match that inset.
            else { DaydreamMonogram(name:app.name,size:(size*0.8).rounded()) }
        }.frame(width:size,height:size).accessibilityHidden(true)
    }
}

public struct ActivityTimelineView: View {
    @ObservedObject var browser: ActivityBrowser
    var onRetry: () -> Void
    var onDelete: (String) -> Void
    @State private var focusedApp: String?
    @State private var deleteID: String?
    public init(browser: ActivityBrowser, onRetry: @escaping () -> Void = {}, onDelete: @escaping (String) -> Void = { _ in }) {
        self.browser = browser; self.onRetry = onRetry; self.onDelete = onDelete
    }
    public var body: some View {
        GeometryReader { geometry in ZStack {
            timeline(compact:geometry.size.width < 650).opacity(browser.scope == nil ? 1 : 0)
                .allowsHitTesting(browser.scope == nil).accessibilityHidden(browser.scope != nil)
            if let scope = browser.scope { appDetail(scope) }
        } }.background(DaydreamStyle.window).font(DaydreamType.body)
        .alert("Delete this supporting source?",isPresented:Binding(get:{deleteID != nil},set:{if !$0 {deleteID = nil}})) {
            Button("Delete",role:.destructive) { if let id = deleteID { onDelete(id) }; deleteID = nil }
            Button("Cancel",role:.cancel) { deleteID = nil }
        } message: { Text("Its summary is removed too. Copies already shared aren't deleted.") }
    }
    @ViewBuilder private func timeline(compact:Bool) -> some View {
        switch browser.phase {
        case .loading:
            VStack(spacing:12) { ProgressView(); Text("Loading local activity…").font(DaydreamType.body).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,maxHeight:.infinity).accessibilityElement(children:.combine)
        case .failed, .held:
            // Drawn from `stateContent` only, so what the checks read is what shows.
            if let content=Self.stateContent(browser.phase) {
                VStack(spacing:0) {
                    if let title=content.title {
                        stateTile("exclamationmark",tint:DaydreamStyle.attention)
                        Text(title).font(DaydreamType.sectionTitle).padding(.top,14)
                    }
                    Text(content.line).font(content.title == nil ? DaydreamType.body : DaydreamType.detail).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true).frame(maxWidth:380).padding(.top,content.title == nil ? 0 : 6)
                    if content.retry {Button("Try again",action:onRetry).buttonStyle(DaydreamPillButtonStyle()).padding(.top,16)}
                }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        case .ready:
            if browser.days.isEmpty {
                VStack(spacing:0) {
                    stateTile("clock",tint:.secondary)
                    Text(browser.query.isEmpty ? "No activity yet" : "No matching activity").font(DaydreamType.sectionTitle).padding(.top,14)
                    Text(browser.query.isEmpty ? "No local observations to display yet." : "Try another title, app or phrase.").font(DaydreamType.detail).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top,6)
                }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ScrollView(showsIndicators:false) {
                    VStack(alignment:.leading,spacing:16) {
                        ForEach(browser.days) { day in dayView(day,compact:compact) }
                    }.padding(.horizontal,8).padding(.top,2).padding(.bottom,16)
                }.scrollIndicators(.never).padding(.horizontal,-8).accessibilityIdentifier("activity-timeline")
            }
        }
    }
    /// What the timeline shows in place of the day: a title, one line, and whether it offers Try again. A read that
    /// failed has all three (Try again reads again). Another DayDream holding the history is only its one line: Try
    /// again could not change it, and it clears by itself (gold r2 review 1). nil: the day, or loading.
    public struct StateContent: Equatable {
        public let title:String?
        public let line:String
        public let retry:Bool
        public init(title:String?,line:String,retry:Bool) {self.title=title;self.line=line;self.retry=retry}
    }
    public static func stateContent(_ phase:ActivityPhase) -> StateContent? {
        switch phase {
        case .failed(let error): return StateContent(title:"Activity could not be loaded",line:error,retry:true)
        case .held(let line): return StateContent(title:nil,line:line,retry:false)
        case .loading,.ready: return nil
        }
    }
    private func stateTile(_ symbol:String,tint:Color) -> some View {
        Image(systemName:symbol).font(.system(size:22,weight:.semibold)).foregroundStyle(tint)
            .frame(width:48,height:48)
            .background(tint.opacity(0.12),in:RoundedRectangle(cornerRadius:DaydreamStyle.tileRadius))
            .overlay(RoundedRectangle(cornerRadius:DaydreamStyle.tileRadius).stroke(DaydreamStyle.cardStroke,lineWidth:1))
    }
    private func dayView(_ day: ActivityDay,compact:Bool) -> some View {
        let collapsed = browser.collapsedDays.contains(day.date)
        return VStack(alignment:.leading,spacing:0) {
            Button {
                if browser.collapsedDays.contains(day.date) { browser.collapsedDays.remove(day.date) }
                else { browser.collapsedDays.insert(day.date) }
            } label: {
                HStack(alignment:.firstTextBaseline,spacing:8) {
                    Text(ActivityWords.day(day.date,calendar:browser.calendar)).font(DaydreamType.sectionTitle)
                    Image(systemName:collapsed ? "chevron.right" : "chevron.down").font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary).frame(width:14)
                    Spacer(minLength:8)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal,20).padding(.vertical,16)
             .accessibilityLabel(ActivityWords.day(day.date,calendar:browser.calendar))
             .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
             .accessibilityHint("Show or hide this day's activity")
             .accessibilityIdentifier("day-"+String(day.date.timeIntervalSince1970))
            if !collapsed {
                VStack(alignment:.leading,spacing:16) {
                    ForEach(day.activities) { activity in
                        if activity.id != day.activities.first?.id { Divider() }
                        activityView(activity,compact:compact)
                    }
                }.padding(.horizontal,20).padding(.top,2).padding(.bottom,20)
            }
        }.frame(maxWidth:.infinity,alignment:.leading).daydreamCard()
    }
    private func activityView(_ activity: ActivityGroup,compact:Bool) -> some View {
        // One container across the breakpoint keeps app buttons (and their focus) alive.
        let layout = compact ? AnyLayout(VStackLayout(alignment:.leading,spacing:4)) : AnyLayout(HStackLayout(alignment:.firstTextBaseline,spacing:16))
        return layout {
            Text(ActivityWords.time(activity.start,calendar:browser.calendar)).font(DaydreamType.meta).foregroundStyle(.secondary)
                .frame(width:compact ? nil : 72,alignment:compact ? .leading : .trailing)
            activityBody(activity)
        }.id(activity.id)
    }
    private func activityBody(_ activity: ActivityGroup) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(activity.title).font(DaydreamType.itemTitle).foregroundStyle(.primary).fixedSize(horizontal:false,vertical:true)
            Text(ActivityWords.narrative(activity.items)).font(DaydreamType.body).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
            if activity.pending { Label("Summary pending for some observations",systemImage:"clock").font(DaydreamType.caption).foregroundStyle(.secondary) }
            HStack(spacing:12) {
                // The extra leading pull lines icon artwork, inset in its button slot, up with the text edge.
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(alignment:.top,spacing:10) {
                        ForEach(activity.apps) { app in appButton(app,activity:activity) }
                    }.padding(3)
                }.scrollIndicators(.never).frame(height:34).padding(.leading,-7).padding(.trailing,-3)
                // No per-row "Synthetic example": the preview's caption says it once for the window.
            }
        }.frame(maxWidth:760,alignment:.leading).frame(maxWidth:.infinity,alignment:.leading)
    }
    private func appButton(_ app: ActivityApp, activity: ActivityGroup) -> some View {
        let focusID = activity.id + app.id
        let label = app.name + ", " + activity.title
        let identifier = "app-" + activity.id + "-" + app.id
        return NativeAppButton(app:app,label:label,focusRequested:focusedApp == focusID && browser.scope == nil,active:browser.scope == nil) {
            focusedApp = nil; browser.select(app,in:activity)
        }.frame(width:28,height:28).overlay {
            AppIdentityIcon(app:app,size:24).allowsHitTesting(false).accessibilityHidden(true)
        }.help(label).accessibilityIdentifier(identifier)
    }
    private func appDetail(_ scope: AppScope) -> some View {
        let items = browser.scopedItems
        // A single timed observation is already dated by the header period.
        let single = items.count == 1 && timestamp(items[0].evidence.at) != nil
        return ScrollView(showsIndicators:false) { VStack(alignment:.leading,spacing:14) {
            Button {
                let returnID = scope.activityID+scope.app.id
                browser.back()
                DispatchQueue.main.async { focusedApp = returnID }
            } label: { Label("Back to activity",systemImage:"chevron.left") }
            .buttonStyle(DaydreamOnboardingBackStyle()).keyboardShortcut(.escape,modifiers:[]).padding(.leading,-7)
            VStack(alignment:.leading,spacing:0) {
                HStack(spacing:14) {
                    AppIdentityIcon(app:scope.app,size:40).padding(.leading,-4)
                    VStack(alignment:.leading,spacing:4) {
                        Text(scope.app.name).font(DaydreamType.sectionTitle).fixedSize(horizontal:false,vertical:true)
                        Text(ActivityWords.period(items,calendar:browser.calendar) + (scope.wholeDay ? " · Across the day" : "" )).font(DaydreamType.meta).foregroundStyle(.secondary)
                    }
                    Spacer(minLength:8)
                }.padding(.horizontal,20).padding(.vertical,18)
                Divider()
                VStack(alignment:.leading,spacing:14) {
                    if browser.dayLoading && scope.wholeDay {
                        HStack(spacing:8) { ProgressView().controlSize(.small); Text("Loading this app's day…").font(DaydreamType.detail).foregroundStyle(.secondary) }.accessibilityElement(children:.combine)
                    }
                    if let error = browser.dayError, scope.wholeDay {
                        Text(error).font(DaydreamType.detail).foregroundStyle(.secondary)
                        Button("Retry day summary") { browser.showDay() }.buttonStyle(DaydreamPillButtonStyle())
                    }
                    if !browser.dayLoading && browser.dayError == nil {
                        if items.isEmpty { Text("No recorded detail available.").font(DaydreamType.body).foregroundStyle(.secondary) }
                    }
                    if items.contains(where:{$0.generatedAt.isEmpty}) { Label("Summary pending for some observations",systemImage:"clock").font(DaydreamType.caption).foregroundStyle(.secondary) }
                    LazyVStack(alignment:.leading,spacing:14) {
                        ForEach(items,id:\.id) { item in
                            if item.id != items.first?.id { Divider() }
                            VStack(alignment:.leading,spacing:5) {
                                let host = URL(string:item.evidence.url)?.host
                                if !single || host != nil {
                                    HStack(alignment:.firstTextBaseline,spacing:8) {
                                        if !single { Text(timestamp(item.evidence.at).map { ActivityWords.time($0,calendar:browser.calendar) } ?? "Time unavailable").font(DaydreamType.meta).foregroundStyle(.secondary) }
                                        if let host { Text(host).font(DaydreamType.caption).foregroundStyle(.secondary) }
                                    }
                                }
                                Text(ActivityWords.narrative([item])).font(DaydreamType.body).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                                // Original evidence remains in the restricted store, not the ordinary action UI.
                            }.frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("action-"+item.id)
                        }
                    }
                }.padding(.horizontal,20).padding(.vertical,18)
            }.daydreamCard()
            if scope.wholeDay {
                Button("Return to selected activity") { browser.showActivity() }.buttonStyle(DaydreamPillButtonStyle())
            } else {
                DisclosureGroup {
                    Button("View this app across the day") { browser.showDay() }.buttonStyle(DaydreamPillButtonStyle()).padding(.top,8)
                } label: { Text("More history").font(DaydreamType.detail) }
            }
        }.padding(.horizontal,8).padding(.top,2).padding(.bottom,16).frame(maxWidth:916,alignment:.leading).frame(maxWidth:.infinity,alignment:.top) }
         .scrollIndicators(.never).padding(.horizontal,-8)
         .accessibilityIdentifier("app-activity-detail")
    }
}
