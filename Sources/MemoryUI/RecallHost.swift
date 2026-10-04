import SwiftUI
import MemoryCore

/// Recall (find-A): MemoryShell mounts it over the day content while `browser.recallVisible && browser.canSearch`.
/// A dim scrim covers the content (click it to close) and the panel floats 8 pt below the content's top,
/// `min(900, width − 40)` × `min(620, height − 40)`. The day underneath stays mounted and takes no clicks.
/// Recall never calls a recording action: `state` and `actions` are accepted for the shell's contract only.
public struct RecallHost: View {
    @ObservedObject var browser: ActivityBrowser
    let state: CapturePresentation
    let actions: CaptureActions

    public init(browser: ActivityBrowser, state: CapturePresentation, actions: CaptureActions) {
        self.browser = browser; self.state = state; self.actions = actions
    }

    public var body: some View {
        RecallHostBody(browser: browser, model: browser.recallModel, today: browser.today)
    }
}

private struct RecallHostBody: View {
    @ObservedObject var browser: ActivityBrowser
    @ObservedObject var model: RecallModel
    @ObservedObject var today: TodayDigest

    var body: some View {
        GeometryReader { g in
            let size = CGSize(width: max(0, min(RecallLayout.panelWidth, g.size.width - 40)),
                              height: max(0, min(RecallLayout.panelHeight, g.size.height - 40)))
            ZStack(alignment: .top) {
                DaydreamStyle.dim
                    .contentShape(Rectangle())
                    .onTapGesture { model.close() }
                    .accessibilityHidden(true)
                RecallPanel(browser: browser, model: model, today: today, size: size)
                    .background(GeometryReader { p in Color.clear.preference(key: RecallPanelFrameKey.self, value: p.frame(in: .global)) })
                    .padding(.top, 8)
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .top)
            .preference(key: RecallPanelSizeKey.self, value: size)
        }
        .onPreferenceChange(RecallPanelSizeKey.self) { size in
            if model.panelSize != size { model.panelSize = size }
        }
        .onPreferenceChange(RecallPanelFrameKey.self) { frame in
            if model.panelFrame != frame { model.panelFrame = frame }
        }
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
        .onChange(of: browser.query) { _ in model.queryChanged() }
        .onReceive(browser.commands) { model.handle($0) }
        .onReceive(today.$snapshot) { _ in model.updateContext() }
    }
}

private struct RecallPanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// The panel as drawn (measured behind it), in the hosting view's space.
private struct RecallPanelFrameKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
