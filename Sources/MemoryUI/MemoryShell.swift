import SwiftUI
import AppKit

/// Where the window's controls live. `.inline` draws `DaydreamToolbarRow` above the content (renders, trials, checks);
/// `.windowToolbar` hands the same controls to the window's toolbar through `.daydreamWindowToolbar`.
public enum ShellChrome { case inline, windowToolbar }

/// Production whole-window composition, also rendered with isolated fixture data.
/// Structure only (plan §4.7): the toolbar (DaydreamToolbar.swift), the day content and Recall (RecallHost.swift) own their looks.
public struct MemoryShell:View {
    @ObservedObject var browser:ActivityBrowser
    let state:CapturePresentation; let actions:CaptureActions
    let retry:()->Void; let delete:(String)->Void; let demo:Bool
    let indexingLine:String?; let chrome:ShellChrome
    /// `.inline` only: room kept at the row's leading edge for window controls drawn over it (the renders' stand-in
    /// traffic lights). 0 under a normal title bar.
    let toolbarLeadingInset:CGFloat
    /// Window width for the toolbar's compact layouts; 0 until the first layout pass.
    @State private var width:CGFloat=0
    @State private var contexts=ShellCommandContexts()
    public init(browser:ActivityBrowser,state:CapturePresentation,actions:CaptureActions,retry:@escaping()->Void={},delete:@escaping(String)->Void={_ in},demo:Bool=false,indexingLine:String?=nil,chrome:ShellChrome = .inline,toolbarLeadingInset:CGFloat=0) {
        self.browser=browser; self.state=state; self.actions=actions; self.retry=retry; self.delete=delete; self.demo=demo;self.indexingLine=indexingLine; self.chrome=chrome
        self.toolbarLeadingInset=toolbarLeadingInset
    }
    /// The synthetic preview's one honesty line.
    public static let sampleCaption="Sample data, not your memory."
    /// Gutter around the legacy timeline and today's canonical timeline (20pt sides, 14pt below the header).
    static let gutter=EdgeInsets(top:14,leading:20,bottom:0,trailing:20)
    /// A non-empty query or a summoned Recall covers the day; without a search backend there is nothing to present.
    private var recallShown:Bool { browser.recallVisible && browser.canSearch }
    /// The legacy list's filter (W2-13): only without a search backend, over the loaded legacy list (not the Focus
    /// List, a load failure, an empty list or a detail). A typed filter keeps it, so a filter matching nothing can be cleared.
    private var legacyFilterShown:Bool {
        guard !browser.canSearch,browser.loadCanonicalDay == nil,case .ready=browser.phase,browser.scope == nil else {return false}
        return !browser.items.isEmpty || !browser.query.isEmpty
    }
    public var body:some View {
        VStack(alignment:.leading,spacing:0) {
            // Above the content, so control shadows fall over Recall's backdrop exactly as over the day.
            if chrome == .inline {
                DaydreamToolbarRow(browser:browser,state:state,actions:actions,width:width,leadingInset:toolbarLeadingInset).zIndex(1)
                    .onAppear { ShellChromeCensus.inlineRows += 1 }.onDisappear { ShellChromeCensus.inlineRows -= 1 }
            }
            // The synthetic preview says once, for the whole window, that it isn't your memory. (`indexingLine`
            // isn't drawn: it offered nothing to do, and search says itself when results may be incomplete.)
            if demo {
                Text(Self.sampleCaption)
                    .font(DaydreamType.caption).foregroundStyle(.secondary).padding(.horizontal,20).padding(.top,10)
            }
            // No search backend (the synthetic preview, a storage failure): Recall can't open, so an inline filter of
            // the loaded list stands in (amendment A2, contract request W2-13). Only over a list there is to filter.
            if legacyFilterShown {
                RecallLegacyFilterField(browser:browser).frame(maxWidth:340).padding(.horizontal,20).padding(.top,10)
            }
            content
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
            .background(GeometryReader { Color.clear.preference(key:ShellWidthKey.self,value:$0.size.width) })
            .background(ShellChromeProbe(chrome:chrome).frame(width:0,height:0).accessibilityHidden(true))
            .onPreferenceChange(ShellWidthKey.self) { width=$0 }
            .daydreamWindowToolbar(enabled:chrome == .windowToolbar,browser:browser,state:state,actions:actions)
            // Recall's model exists before Recall first opens, so a Find Related the Focus List posts
            // (`.daydreamRecallFilter`, then `recallPresented`) is heard (contract request W2-3).
            .onAppear { if browser.canSearch { _ = browser.recallModel } }
            .onAppear { if chrome == .windowToolbar { ShellChromeCensus.windowToolbars += 1 } }
            .onDisappear { if chrome == .windowToolbar { ShellChromeCensus.windowToolbars -= 1 } }
            .daydreamShellPresence(browser)
            // No blue focus ring on whatever control takes focus first (owner, Preview 2: "always surrounded by blue").
            // Rows keep their own selection fill for the keyboard; Search's field draws no ring either.
            .daydreamNoInitialFocusRing()
            .onReceive(browser.$commandContext) { contexts.written($0) }
            .background(DaydreamStyle.window)
            // .never, not .hidden: scroll chrome stays off even with "Always show scroll bars" (check-main-layout.sh check-indicators).
            .scrollIndicators(.never)
    }
    /// The day, below the toolbar and caption. Recall covers only this region, so the inline toolbar stays usable;
    /// the day stays mounted (scroll and selection kept) but takes no clicks and is hidden from VoiceOver meanwhile.
    private var content:some View {
        Group {
            if browser.loadCanonicalDay != nil {
                // perf (claude/perf-1002 pattern): the window observes the whole app model; the timeline redraws only when
                // what it reads from it changes (the recording state), not on every heartbeat, search line or permission read.
                ShellTimeline(browser: browser, state: state, actions: actions).equatable().padding(CanonicalTimeline.shellInsets)
                    // The Focus List's detail activates a native-only action's app through `openApp` (FocusListDetail
                    // `open(_:)`), so its rows may say `Open <App>` (plan L15, W2-9) when that route exists.
                    .environment(\.daydreamDetailOpensApps, browser.openApp != nil)
            }
            else { ActivityTimelineView(browser:browser,onRetry:retry,onDelete:delete).padding(Self.gutter) }
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
            .buttonStyle(ShellButtonStyle())
            .allowsHitTesting(!recallShown).accessibilityHidden(recallShown)
            .overlay {
                if recallShown {
                    RecallHost(browser:browser,state:state,actions:actions)
                        // Recall's detail reopens every row through `reopenCanonical`: its rows keep `Open Original`.
                        .environment(\.daydreamDetailOpensApps, false)
                        .onDisappear { contexts.recallClosed(browser) }
                }
            }
    }
}
/// The shell's padding around a content view. Content that owns its column padding (the Focus List) declares
/// `static var shellInsets:EdgeInsets { EdgeInsets() }` in its own file; everything else keeps the shell gutter.
protocol ShellContentLayout { static var shellInsets:EdgeInsets { get } }
extension ShellContentLayout { static var shellInsets:EdgeInsets { MemoryShell.gutter } }
extension CanonicalTimeline:ShellContentLayout {}
private struct ShellWidthKey:PreferenceKey {
    static var defaultValue:CGFloat { 0 }
    static func reduce(value:inout CGFloat,nextValue:()->CGFloat) { value=max(value,nextValue()) }
}
/// Onboarding pill for stock buttons in the day content, Recall and their sheets/popovers; a Return-key default (Save, Jump) stays the blue primary.
/// Content only: the toolbar and kit components set their own styles.
struct ShellButtonStyle:PrimitiveButtonStyle {
    @Environment(\.keyboardShortcut) private var shortcut
    func makeBody(configuration:Configuration)->some View {
        Button(configuration).buttonStyle(DaydreamPillButtonStyle(prominent:shortcut == .defaultAction))
    }
}

/// How many toolbar hosts are on screen: inline rows (each holds the one recording capsule and the one settings
/// gear, DaydreamToolbar.swift) and shells handing the controls to the window toolbar. The offscreen
/// checks read it where SwiftUI exposes no accessibility tree (window-viewport-checks, PackagedTrial).
@MainActor public enum ShellChromeCensus {
    /// Process-wide: every window's shells, the app's own memory window included.
    public internal(set) static var inlineRows=0
    public internal(set) static var windowToolbars=0
    /// The shells mounted under `host` (a hosting view or a window's content view), by chrome. A check counts
    /// its own host this way, whatever other windows (the app's memory window) hold.
    public static func shells(under host:NSView) -> (inlineRows:Int,windowToolbars:Int) {
        let here=probes.allObjects.filter { $0.window != nil && $0.isDescendant(of:host) }
        return (here.filter { $0.chrome == .inline }.count,here.filter { $0.chrome == .windowToolbar }.count)
    }
    static let probes=NSHashTable<ShellChromeProbe.Marker>.weakObjects()
}
/// A zero-size marker view in each mounted shell, so the census can tell which host holds it. Draws nothing,
/// takes no events and is not an accessibility element.
struct ShellChromeProbe:NSViewRepresentable {
    let chrome:ShellChrome
    func makeNSView(context:Context)->Marker {
        let view=Marker(frame:.zero); view.chrome=chrome
        ShellChromeCensus.probes.add(view)
        return view
    }
    func updateNSView(_ view:Marker,context:Context) { view.chrome=chrome }
    final class Marker:NSView {
        var chrome:ShellChrome = .inline
        override func hitTest(_ point:NSPoint)->NSView? { nil }
        override func isAccessibilityElement()->Bool { false }
    }
}

/// Memory shells on screen, per browser. The app's Go, View and Moment menus act on a mounted shell's content
/// (`ActivityBrowser.send` has no other receiver), so they are disabled while none is mounted, and ⌘K / ⌘F open
/// the window rather than message a closed one.
@MainActor public final class ShellPresence:ObservableObject {
    public static let shared=ShellPresence()
    @Published private var counts:[ObjectIdentifier:Int]=[:]
    public func isMounted(_ browser:ActivityBrowser)->Bool { (counts[ObjectIdentifier(browser)] ?? 0) > 0 }
    fileprivate func appeared(_ browser:ActivityBrowser) { counts[ObjectIdentifier(browser),default:0] += 1 }
    fileprivate func disappeared(_ browser:ActivityBrowser) {
        let id=ObjectIdentifier(browser)
        let left=max(0,(counts[id] ?? 0) - 1)
        counts[id]=left == 0 ? nil:left
        guard left == 0 else {return}
        // The menus' selection context was the shell's surfaces'; with none mounted nothing can act on it. Next turn,
        // after the closing surfaces' own writes.
        DispatchQueue.main.async { [weak self,weak browser] in
            guard let self,let browser,!self.isMounted(browser),browser.commandContext != DaydreamCommandContext() else {return}
            browser.commandContext=DaydreamCommandContext()
        }
    }
}
public extension View {
    /// Counts this view as a mounted shell of `browser` while it is on screen (`ShellPresence`). MemoryShell applies
    /// it; a check's stand-in for the memory window may too.
    func daydreamShellPresence(_ browser:ActivityBrowser)->some View {
        onAppear { ShellPresence.shared.appeared(browser) }.onDisappear { ShellPresence.shared.disappeared(browser) }
    }
}

/// Keeps the menus' `commandContext` the Focus List's once Recall closes (contract request W2-17).
/// Closing Recall runs two writers in one update: the Focus List's `.onChange(of: recallVisible)` writes its
/// selection's context, and Recall's `onDisappear` resets the context to "nothing selected". When the reset
/// lands last, the Focus List's value is the write just before it; it is put back on the next turn.
@MainActor final class ShellCommandContexts {
    private var previous:DaydreamCommandContext?
    private var latest:DaydreamCommandContext?
    /// Every write, in order (`$commandContext` publishes before each set).
    func written(_ context:DaydreamCommandContext) {
        guard context != latest else {return}
        previous=latest; latest=context
    }
    func recallClosed(_ browser:ActivityBrowser) {
        DispatchQueue.main.async { [weak self, weak browser] in
            guard let self,let browser,!browser.recallVisible,browser.commandContext == DaydreamCommandContext(),
                  let focus=self.previous,!focus.recallVisible,focus != DaydreamCommandContext() else {return}
            browser.commandContext=focus
        }
    }
}

/// The day as the shell hosts it, deduplicated on what it reads from the app model: the recording state (the live
/// paused row, the ribbon's live state) and whether Resume can run. `actions` are closures over the app model, so a
/// newer copy acts the same; the browser is the same object (the timeline observes it on its own).
struct ShellTimeline: View, Equatable {
    let browser: ActivityBrowser
    let state: CapturePresentation
    let actions: CaptureActions
    var body: some View { CanonicalTimeline(browser: browser, state: state, actions: actions) }
    static func == (a: Self, b: Self) -> Bool {
        a.browser === b.browser && a.state.state == b.state.state && a.state.canResume == b.state.canResume
    }
}
