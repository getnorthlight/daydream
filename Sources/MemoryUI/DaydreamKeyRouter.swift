import AppKit
import MemoryCore
import SwiftUI

/// Keys a list surface handles without a focused control (plan §4.8, §7): ↑ ↓ Return Esc and ⌘C.
public enum DaydreamKey: Equatable { case up, down, returnKey, escape, copy }

extension View {
    /// Routes ↑ ↓ Return Esc ⌘C to `handle` while this view is in the key window. macOS 13 has no `onKeyPress`,
    /// so a local key-down monitor stands in. It never takes a key from typing: not while a text field, text view,
    /// list/table, picker, slider or stepper has focus, not while an input method is composing, not while a sheet
    /// is attached and not when disabled. A key is consumed only when `handle` returns true.
    public func daydreamKeyRouter(enabled: Bool, handle: @escaping (DaydreamKey) -> Bool) -> some View {
        background(DaydreamKeyRouterHost(enabled: enabled, handle: handle).accessibilityHidden(true))
    }
}

private struct DaydreamKeyRouterHost: NSViewRepresentable {
    let enabled: Bool; let handle: (DaydreamKey) -> Bool
    func makeNSView(context: Context) -> DaydreamKeyRouterView {
        let view = DaydreamKeyRouterView(); view.enabled = enabled; view.handle = handle; return view
    }
    func updateNSView(_ view: DaydreamKeyRouterView, context: Context) { view.enabled = enabled; view.handle = handle }
    static func dismantleNSView(_ view: DaydreamKeyRouterView, coordinator: ()) { view.stop() }
}

/// Monitors key-downs only while it is in a window. Invisible to clicks and VoiceOver.
final class DaydreamKeyRouterView: NSView {
    var enabled = false
    var handle: (DaydreamKey) -> Bool = { _ in false }
    private var monitor: Any?
    /// Responders that own these keys themselves (typing, selection, value changes).
    private static let keyOwners: [AnyClass] = [NSText.self, NSTextField.self, NSTableView.self, NSCollectionView.self,
                                                 NSBrowser.self, NSDatePicker.self, NSSlider.self, NSStepper.self]

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if self.swallowsToolbarSpace(event) { return true }
                guard let key = self.route(event) else { return false }
                return self.handle(key)
            }
            return consumed ? nil : event
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    /// Space while a control in this window's toolbar holds keyboard focus: dropped, never a press (owner 10/2: after a
    /// click on Previous Day, Space stepped back again). Toolbar buttons don't take focus (`toolbarButtonNoFocus`); this
    /// covers a system that hands them focus anyway. Typing, the content's own controls and other windows are untouched.
    func swallowsToolbarSpace(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, event.keyCode == 49,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock]).isEmpty,
              let responder = window.firstResponder as? NSView else { return false }
        return Self.isToolbarControl(responder, in: window)
    }
    /// A view that sits in the window's toolbar (outside its content view) and is no text input.
    static func isToolbarControl(_ view: NSView, in window: NSWindow) -> Bool {
        if keyOwners.contains(where: { view.isKind(of: $0) }) { return false }
        guard let content = window.contentView, view !== content, !view.isDescendant(of: content) else { return false }
        return view.window === window
    }

    /// The key this event means here, or nil when it belongs to someone else. Only in the key window: a key typed in
    /// another app's window never reaches a local monitor, and a DayDream window that isn't key gets none.
    func route(_ event: NSEvent) -> DaydreamKey? {
        MainQueue.require()   // claude/crashguard-015: the key's characters below go through TSM
        guard enabled, let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
              !isHiddenOrHasHiddenAncestor else { return nil }
        if let responder = window.firstResponder {
            if Self.keyOwners.contains(where: { responder.isKind(of: $0) }) { return nil }
            if let client = responder as? NSTextInputClient, client.hasMarkedText() { return nil }
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        if modifiers == .command {
            // ⌘C by character, or by the C key position when the layout types no ASCII letters.
            let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let ascii = characters.unicodeScalars.allSatisfy(\.isASCII)
            return characters == "c" || (!ascii && event.keyCode == 8) ? .copy : nil
        }
        guard modifiers.isEmpty else { return nil }
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 36, 76: return .returnKey
        case 53: return .escape
        default: return nil
        }
    }
}
