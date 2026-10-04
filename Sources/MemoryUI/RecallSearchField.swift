import SwiftUI
import AppKit
import MemoryCore

// Recall's query field (plan §5 A2, amendments A2). An AppKit text field, so its delegate owns the
// Recall keys (keyboard table §7): ↑/↓ select (or step the detail), Return opens the moment, ⌥↩
// searches more history, Esc backs out one level, ⌃↑/⌃↓ alias ↑/↓. The field keeps first responder
// the whole time Recall is open, including while the Actions menu is open: then ↑/↓/Return and
// typing go to the menu, and Esc closes the menu first.

/// The Recall field. Placeholder `Search your notes and what you've seen`, 22 pt, identifier `recall-field`.
struct RecallSearchField: NSViewRepresentable {
    @ObservedObject var browser: ActivityBrowser
    @ObservedObject var model: RecallModel
    static let placeholder = "Search your notes and what you've seen"

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser, model: model) }

    func makeNSView(context: Context) -> RecallTextField {
        let field = RecallTextField()
        field.recall = model
        field.identifier = NSUserInterfaceItemIdentifier("recall-field")
        field.font = .systemFont(ofSize: 22)
        field.textColor = .labelColor
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderAttributedString = NSAttributedString(string: Self.placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        field.stringValue = browser.query
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search")
        field.setAccessibilityPlaceholderValue(Self.placeholder)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.focusSerial = model.focusSerial
        field.onWindow = { [weak coordinator = context.coordinator, weak field] in
            guard let coordinator, let field else { return }
            coordinator.takeFocus(field, remember: true)
        }
        return field
    }

    func updateNSView(_ field: RecallTextField, context: Context) {
        context.coordinator.browser = browser
        context.coordinator.model = model
        field.recall = model
        // Mirror the query set elsewhere (toolbar, Esc, renders) without disturbing typing.
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if field.stringValue != browser.query && !composing {
            field.stringValue = browser.query
            if let editor = field.currentEditor() { editor.selectedRange = NSRange(location: (browser.query as NSString).length, length: 0) }
        }
        if context.coordinator.focusSerial != model.focusSerial {
            context.coordinator.focusSerial = model.focusSerial
            DispatchQueue.main.async { [weak coordinator = context.coordinator, weak field] in
                guard let coordinator, let field else { return }
                coordinator.takeFocus(field, remember: false)
            }
        }
    }

    static func dismantleNSView(_ field: RecallTextField, coordinator: Coordinator) {
        coordinator.restoreFocus(from: field)
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: ActivityBrowser
        var model: RecallModel
        var focusSerial = 0
        /// The responder that had focus before Recall took it (restored when Recall closes).
        weak var previous: NSResponder?

        init(browser: ActivityBrowser, model: RecallModel) { self.browser = browser; self.model = model }

        /// Makes the field first responder with the caret at the end (never selecting the query, so a
        /// keystroke already on its way never replaces it).
        func takeFocus(_ field: NSTextField, remember: Bool) {
            guard let window = field.window else { return }
            if remember && previous == nil {
                var current = window.firstResponder
                if let text = current as? NSTextView, text.isFieldEditor, let owner = text.delegate as? NSResponder { current = owner }
                if current !== field && current !== window { previous = current }
            }
            if field.currentEditor() == nil { window.makeFirstResponder(field) }
            if let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
            }
        }

        func restoreFocus(from field: NSTextField) {
            guard let window = field.window else { return }
            let owns = field.currentEditor() != nil
            if let previous, (previous as? NSView)?.window === window {
                window.makeFirstResponder(previous)
            } else if owns {
                window.makeFirstResponder(nil)
            }
            previous = nil
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            if browser.query != field.stringValue { browser.query = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            RecallKeys.handle(selector, model: model)
        }
    }
}

/// The field delegate's key map (keyboard table §7).
@MainActor enum RecallKeys {
    static func handle(_ selector: Selector, model: RecallModel) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            if model.rangeMenuOpen { model.rangeMove(-1) } else if model.menuOpen { model.menuMove(-1) } else { model.move(-1) }
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            if model.rangeMenuOpen { model.rangeMove(1) } else if model.menuOpen { model.menuMove(1) } else { model.move(1) }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if model.rangeMenuOpen { model.rangeRun() } else if model.menuOpen { model.menuRun() } else { model.openMoment() }
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if model.rangeMenuOpen { model.rangeRun() } else if model.menuOpen { model.menuRun() } else { model.searchMore() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            model.cancel()
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            guard model.menuOpen else { return false }
            model.menuBackspace()
            return true
        default:
            return false
        }
    }
}

/// The field: while the Actions menu is open, typed text filters the menu instead of the query.
final class RecallTextField: NSTextField {
    weak var recall: RecallModel?
    var onWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let onWindow else { return }
        DispatchQueue.main.async { onWindow() }
    }

    /// NSTextField implements this field-editor delegate method itself (not in its Swift interface), so
    /// with the menu closed the call goes on to NSTextField's own implementation unchanged.
    @objc(textView:shouldChangeTextInRange:replacementString:)
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        if let recall, recall.menuOpen {
            if let text = replacementString, !text.isEmpty { recall.menuType(text) }
            return false
        }
        return Self.superShouldChange(self, textView, range, replacementString)
    }

    private typealias ShouldChange = @convention(c) (AnyObject, Selector, NSTextView, NSRange, NSString?) -> Bool
    private static let shouldChangeSelector = NSSelectorFromString("textView:shouldChangeTextInRange:replacementString:")
    /// NSTextField's implementation, looked up once (nil when a future AppKit drops it: then allow the change).
    private static let superShouldChangeIMP: ShouldChange? = {
        guard let method = class_getInstanceMethod(NSTextField.self, shouldChangeSelector) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: ShouldChange.self)
    }()
    private static func superShouldChange(_ field: NSTextField, _ textView: NSTextView, _ range: NSRange, _ text: String?) -> Bool {
        guard let imp = superShouldChangeIMP else { return true }
        return imp(field, shouldChangeSelector, textView, range, text as NSString?)
    }
}

// MARK: - Legacy filter

/// The inline query filter for legacy and synthetic windows (`!browser.canSearch`): Recall has no
/// search backend there, so the query filters the day list in place (`ActivityBrowser.days`).
/// MemoryShell mounts Recall only when `canSearch`; the toolbar owner places this field otherwise.
public struct RecallLegacyFilterField: View {
    @ObservedObject var browser: ActivityBrowser
    public init(browser: ActivityBrowser) { self.browser = browser }
    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextField("Filter this list", text: $browser.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !browser.query.isEmpty {
                Button { browser.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear Filter")
                .accessibilityLabel("Clear Filter")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(DaydreamStyle.wellFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DaydreamStyle.hairline, lineWidth: DaydreamStyle.hairlineWidth))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter")
    }
}
