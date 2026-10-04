// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// Portions of this file are derived from open-codex-computer-history
// (https://github.com/hqhq1025/open-codex-computer-history),
// Copyright (c) 2026 Open Codex Computer History contributors, used under the
// MIT License. The full MIT notice is in THIRD-PARTY-NOTICES.md.

import Foundation

/// The kinds of interaction the recorder observes. The string raw values are
/// stored with each captured item in the local database, so renaming one is a
/// data migration, not a refactor.
public enum HistoryEventKind: String, Codable, CaseIterable, Sendable {
    case sessionStarted = "session.started"
    case sessionEnded = "session.ended"
    case appActivated = "app.activated"
    case windowChanged = "window.changed"
    case textInput = "keyboard.text_input"
    case shortcut = "keyboard.shortcut"
    case submit = "keyboard.submit"
    case selectionChanged = "selection.changed"
    case terminalValueChanged = "terminal.value_changed"
    case mouseClick = "mouse.click"
    case mouseContextMenu = "mouse.context_menu"
    case debugError = "debug.error"
}

public struct AppInfo: Codable, Equatable, Sendable {
    public let name: String?
    public let bundleIdentifier: String?
    /// True when the focused element was a secure field. It rides along so a
    /// consumer can *see that* a password was being typed without ever seeing
    /// *what* — the characters were dropped at capture time, not here.
    public let secureInput: Bool

    public init(name: String?, bundleIdentifier: String?, secureInput: Bool = false) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.secureInput = secureInput
    }
}

public struct WindowInfo: Codable, Equatable, Sendable {
    public let title: String?
    public let url: String?
    public let windowID: UInt32?

    public init(title: String?, url: String?, windowID: UInt32? = nil) {
        self.title = title
        self.url = url
        self.windowID = windowID
    }
}

/// A minimal projection of the focused accessibility element. `value` is the one
/// text-bearing field here and is redacted like every other text field.
public struct ElementInfo: Codable, Equatable, Sendable {
    public let role: String?
    public let subrole: String?
    public let title: String?
    public let value: String?
    public let identifier: String?

    public init(
        role: String?,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        identifier: String? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.identifier = identifier
    }
}

/// Keyboard payload. `text` is set for coalesced typing bursts and terminal
/// output; `keyEquivalent`/`modifiers` describe shortcuts and Return.
public struct KeyInfo: Codable, Equatable, Sendable {
    public let text: String?
    public let keyEquivalent: String?
    public let modifiers: [String]

    public init(text: String? = nil, keyEquivalent: String? = nil, modifiers: [String] = []) {
        self.text = text
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
    }
}

public struct SelectionInfo: Codable, Equatable, Sendable {
    public let selectedText: String?
    public let location: Int?
    public let length: Int?

    public init(selectedText: String?, location: Int? = nil, length: Int? = nil) {
        self.selectedText = selectedText
        self.location = location
        self.length = length
    }
}

public struct MouseInfo: Codable, Equatable, Sendable {
    public let button: String
    public let clickCount: Int
    public let modifiers: [String]

    public init(button: String, clickCount: Int, modifiers: [String] = []) {
        self.button = button
        self.clickCount = clickCount
        self.modifiers = modifiers
    }
}

public struct Diagnostic: Codable, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

/// One recorded interaction. Everything after `kind` is optional and only the
/// fields relevant to that kind are populated — a submit has `key`, a window
/// change has `window`, and so on.
public struct HistoryEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let timestamp: Date
    public let kind: HistoryEventKind
    public let app: AppInfo?
    public let window: WindowInfo?
    public let element: ElementInfo?
    public let key: KeyInfo?
    public let selection: SelectionInfo?
    public let mouse: MouseInfo?
    public let diagnostic: Diagnostic?
    /// Set to true only on copies whose text was stripped by `redactingText()`.
    /// Absent (nil) on original events, which keep whatever text policy allowed.
    public let textRedacted: Bool?

    public init(
        id: Int,
        timestamp: Date,
        kind: HistoryEventKind,
        app: AppInfo? = nil,
        window: WindowInfo? = nil,
        element: ElementInfo? = nil,
        key: KeyInfo? = nil,
        selection: SelectionInfo? = nil,
        mouse: MouseInfo? = nil,
        diagnostic: Diagnostic? = nil,
        textRedacted: Bool? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.app = app
        self.window = window
        self.element = element
        self.key = key
        self.selection = selection
        self.mouse = mouse
        self.diagnostic = diagnostic
        self.textRedacted = textRedacted
    }

    /// The free-text fields a consumer might not be allowed to see. Kept in one
    /// place so redaction and search agree on exactly what counts as "text".
    public var textFields: [String] {
        [key?.text, selection?.selectedText, element?.value].compactMap { $0 }
    }

    /// A copy with every text-bearing field cleared and `textRedacted` flagged.
    /// The original event is never mutated.
    public func redactingText() -> HistoryEvent {
        HistoryEvent(
            id: id,
            timestamp: timestamp,
            kind: kind,
            app: app,
            window: window,
            element: element.map {
                ElementInfo(role: $0.role, subrole: $0.subrole, title: $0.title, value: nil, identifier: $0.identifier)
            },
            key: key.map { KeyInfo(text: nil, keyEquivalent: $0.keyEquivalent, modifiers: $0.modifiers) },
            selection: selection.map {
                SelectionInfo(selectedText: nil, location: $0.location, length: $0.length)
            },
            mouse: mouse,
            diagnostic: diagnostic,
            textRedacted: true
        )
    }
}
