import SwiftUI
import AppKit

/// Main-window chrome for the unified toolbar (plan §5 A3, L1): the toolbar sits on the window colour with no
/// separator, no window tabs, and a saved frame. Applied when the view joins its window.
///
/// The window colour comes from the window itself (`titlebarAppearsTransparent` over `backgroundColor`):
/// macOS 26 ignores `.toolbarBackground` for the window toolbar and draws the band white with a hairline
/// under it; macOS 13-15 honour both.
///
/// It never sets `fullSizeContentView` (content stays below the toolbar, so nothing hides under it) and never
/// `isMovableByWindowBackground` (dragging stays in the title bar and toolbar; content clicks stay clicks).
/// It never changes the toolbar style or the title visibility either: the scene sets those before the toolbar is
/// built, and NSToolbar does not recover its item layout from a later change.
public struct WindowConfigurator: NSViewRepresentable {
    public static let autosaveName = "DayDreamMain"
    /// Whether the frame is saved under `autosaveName`. Off in unbundled processes (checks and render harnesses),
    /// so they never write window frames to preferences.
    public static var savesFrame = Bundle.main.bundleIdentifier != nil

    /// Reports the room the title-bar buttons take before the toolbar's first item (`leadingInset(of:)`).
    var onLeadingInset: ((CGFloat) -> Void)?

    public init() {}
    init(onLeadingInset: @escaping (CGFloat) -> Void) { self.onLeadingInset = onLeadingInset }

    public func makeNSView(context: Context) -> NSView {
        let view = ConfiguratorView()
        view.onLeadingInset = onLeadingInset
        return view
    }
    public func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ConfiguratorView)?.onLeadingInset = onLeadingInset
    }

    /// The window settings, for a window the configurator is attached to (and for the checks).
    public static func configure(_ window: NSWindow, savesFrame: Bool = WindowConfigurator.savesFrame) {
        if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if window.backgroundColor != windowColor { window.backgroundColor = windowColor }
        if window.tabbingMode != .disallowed { window.tabbingMode = .disallowed }
        if savesFrame && window.frameAutosaveName != autosaveName { window.setFrameAutosaveName(autosaveName) }
    }

    /// The toolbar layout's leading inset for `window` (`ToolbarLayout.windowLeadingInset` semantics): the zoom
    /// button's trailing edge plus NSToolbar's 17 pt gap to the first item, less the row's 16 pt padding. Never
    /// below `ToolbarLayout.windowLeadingInset` (macOS 26: zoom ends at 79 pt, the stepper starts at 96 pt), so a
    /// hidden or unplaced zoom button (full screen) keeps the default.
    public static func leadingInset(of window: NSWindow) -> CGFloat {
        guard let zoom = window.standardWindowButton(.zoomButton), zoom.window === window, !zoom.isHidden else {
            return ToolbarLayout.windowLeadingInset
        }
        let end = zoom.convert(zoom.bounds, to: nil).maxX
        return max(ToolbarLayout.windowLeadingInset, ceil(end) + 17 - ToolbarLayout.padding)
    }

    /// `DaydreamStyle.window` (light and dark), behind the toolbar and the content.
    static let windowColor = NSColor(DaydreamStyle.window)

    final class ConfiguratorView: NSView {
        var onLeadingInset: ((CGFloat) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            WindowConfigurator.configure(window)
            if let report = onLeadingInset {
                let inset = WindowConfigurator.leadingInset(of: window)
                // Not during SwiftUI's update pass.
                DispatchQueue.main.async { report(inset) }
            }
        }
        /// Transparent to clicks: it only watches for its window.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
