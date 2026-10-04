import SwiftUI

// The Recording commands as native menu rows (plan §5 A4, copy deck §8.8): the app's
// `CommandMenu("Recording")` and the WholeWindow NSHostingMenu check both host this view.
// The issue text is not here: it shows only in the menu bar card, so it can never widen a menu.

/// Native `Button` and `Menu` rows for recording:
/// - `Pause for` ▸ `5 Minutes`, `15 Minutes`, `30 Minutes`, `2 Hours` (enabled only while Recording; the host may
///   attach ⌘P to `15 Minutes` through `pauseShortcut`). One submenu (declutter): 15 minutes is offered once.
/// - `Start Recording`, or `Resume Recording` while Paused (enabled only when Off or Paused and resumable)
/// - `Stop Recording` (enabled only while Recording or Paused, when the recorder can stop)
/// Start, Resume and Stop have no key equivalents.
public struct MenuBarRecordingMenu: View {
    /// One row, as data (the checks read the same list the view draws).
    public struct Item: Equatable, Sendable {
        public let title: String
        public let enabled: Bool
        /// nil for the `Pause for` submenu itself.
        public let action: RecordingAction?
        public let children: [Item]
    }

    let state: RecordingState
    let canResume: Bool
    let canStop: Bool
    let actions: CaptureActions
    let pauseShortcut: KeyboardShortcut?

    public init(state: RecordingState, canResume: Bool, canStop: Bool, actions: CaptureActions,
                pauseShortcut: KeyboardShortcut? = nil) {
        self.state = state; self.canResume = canResume; self.canStop = canStop; self.actions = actions
        self.pauseShortcut = pauseShortcut
    }

    public init(presentation p: CapturePresentation, actions: CaptureActions, pauseShortcut: KeyboardShortcut? = nil) {
        self.init(state: p.state, canResume: p.canResume, canStop: p.canStop, actions: actions, pauseShortcut: pauseShortcut)
    }

    /// `5 Minutes`, `15 Minutes`, `30 Minutes`, `2 Hours`.
    public static func presetTitle(_ minutes: Int) -> String {
        if minutes % 60 == 0 { let h = minutes / 60; return "\(h) " + (h == 1 ? "Hour" : "Hours") }
        return "\(minutes) " + (minutes == 1 ? "Minute" : "Minutes")
    }

    /// The preset that carries the host's ⌘P.
    public static let shortcutMinutes = 15

    /// The rows for a state, in menu order.
    public static func items(state: RecordingState, canResume: Bool, canStop: Bool) -> [Item] {
        let recording = state.kind == .recording
        let paused = state.kind == .paused
        let presets = RecordingState.pausePresets.map {
            Item(title: presetTitle($0), enabled: recording, action: .pause(minutes: $0), children: [])
        }
        let start = paused ? "Resume Recording" : "Start Recording"
        let startEnabled = (paused || state.kind == .off) && canResume
        return [
            Item(title: "Pause for", enabled: recording, action: nil, children: presets),
            Item(title: start, enabled: startEnabled, action: paused ? .resume : .start, children: []),
            // Never in Off or Needs Permission: nothing is recording or paused then (the popover and the menu bar agree).
            Item(title: "Stop Recording", enabled: canStop && (recording || paused), action: .stop, children: []),
        ]
    }

    private var model: [Item] { Self.items(state: state, canResume: canResume, canStop: canStop) }

    public var body: some View {
        let rows = model
        Menu(rows[0].title) {
            ForEach(rows[0].children, id: \.title) { item in
                Button(item.title) { run(item) }
                    .keyboardShortcut(item.action == .pause(minutes: Self.shortcutMinutes) ? pauseShortcut : nil)
                    .disabled(!item.enabled)
            }
        }
        .disabled(!rows[0].enabled)
        Divider()
        Button(rows[1].title) { run(rows[1]) }.disabled(!rows[1].enabled)
        Button(rows[2].title) { run(rows[2]) }.disabled(!rows[2].enabled)
    }

    private func run(_ item: Item) {
        guard item.enabled, let action = item.action else { return }
        actions.perform(action)
    }
}
