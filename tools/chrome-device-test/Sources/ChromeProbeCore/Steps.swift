import Foundation

public enum StepKind: String, Codable {
    /// Apple Events only: descriptors and the window table.
    case descriptor
    /// Full joins with a field focused.
    case join
    /// Joins sampled while the owner types made-up text.
    case typing
    /// System-wide focus sampling (Spotlight).
    case focus
    /// Cmd+Shift+N race: how fast a new Incognito window is listed.
    case race
    /// Joins that must end in strict pause.
    case strict
    /// Guest window: asks the owner to confirm first.
    case guest
    /// Joins while an Incognito window closes behind a "Leave site?" dialog.
    case closing
    /// System-wide focus sampling in TextEdit / Notes (no Chrome reads).
    case nativeFocus
}

public struct StepSpec {
    public let id: String
    public let title: String
    public let kind: StepKind
    public let joins: Int
    public let needsLabels: Bool
    /// Do this in Chrome BEFORE pressing Return in Terminal.
    public let setup: [String]
    /// Do this in Chrome AFTER pressing Return. Measuring starts a few
    /// seconds after Chrome comes to the front (or at the "Tink" sound).
    public let action: [String]
}

/// The guided run. Box numbers refer to testpage/index.html.
public enum Steps {
    public static let all: [StepSpec] = [
        StepSpec(id: "descriptor", title: "Window list and descriptors", kind: .descriptor, joins: 0, needsLabels: false,
                 setup: ["Chrome shows ONE normal window with the test page (http://127.0.0.1:8765/)."],
                 action: ["Nothing. Stay in Terminal."]),
        StepSpec(id: "plain-input", title: "Box 1: plain input", kind: .join, joins: 10, needsLabels: false,
                 setup: [], action: ["Click inside box 1 (Plain input). Don't type. Keep still until the Glass sound."]),
        StepSpec(id: "textarea", title: "Box 2: textarea", kind: .join, joins: 5, needsLabels: false,
                 setup: [], action: ["Click inside box 2 (Textarea). Don't type."]),
        StepSpec(id: "contenteditable", title: "Box 3: rich-text editor (contenteditable)", kind: .join, joins: 5, needsLabels: false,
                 setup: [], action: ["Click inside box 3 (Rich-text editor). Don't type."]),
        StepSpec(id: "typing", title: "Typing in box 2 (AX object stability)", kind: .typing, joins: 0, needsLabels: false,
                 setup: [], action: ["Click inside box 2. At the Tink sound, type made-up words non-stop until the Glass sound (10 s),",
                                     "for example: purple lamp sings over quiet hills. The harness never reads what you type."]),
        StepSpec(id: "password-hidden", title: "Box 4: password field, hidden", kind: .join, joins: 3, needsLabels: false,
                 setup: ["Box 4 shows dots (hidden). If it shows text, click \"Hide password\"."],
                 action: ["Click inside box 4 (Dummy password). Don't type."]),
        StepSpec(id: "password-shown", title: "Box 4: password field, shown", kind: .join, joins: 3, needsLabels: false,
                 setup: ["Click \"Show password\" under box 4 so the dummy text is visible."],
                 action: ["Click inside box 4. Don't type."]),
        StepSpec(id: "card", title: "Box 5: card number field", kind: .join, joins: 3, needsLabels: true,
                 setup: [], action: ["Click inside box 5 (Card number). Don't type."]),
        StepSpec(id: "otp", title: "Box 6: one-time code field", kind: .join, joins: 3, needsLabels: true,
                 setup: [], action: ["Click inside box 6 (One-time code). Don't type."]),
        StepSpec(id: "terminal", title: "Box 9: web terminal input (xterm-like)", kind: .join, joins: 3, needsLabels: true,
                 setup: [], action: ["Click inside box 9 (Web terminal). Don't type."]),
        StepSpec(id: "iframe-same", title: "Box 7: input inside a same-origin iframe", kind: .join, joins: 3, needsLabels: false,
                 setup: [], action: ["Click inside the input in box 7 (Same-origin iframe). Don't type."]),
        StepSpec(id: "iframe-cross", title: "Box 8: input inside a cross-site iframe", kind: .join, joins: 3, needsLabels: false,
                 setup: ["Box 8 shows an input (not an error). If it shows an error, type s to skip this step (see troubleshooting)."],
                 action: ["Click inside the input in box 8 (Cross-site iframe). Don't type."]),
        StepSpec(id: "address-bar", title: "Chrome address bar", kind: .join, joins: 3, needsLabels: false,
                 setup: [], action: ["Click an empty part of the test page, then press Cmd+L so the address bar is selected. Don't type."]),
        StepSpec(id: "two-windows-new", title: "Two normal windows: the new one", kind: .join, joins: 5, needsLabels: false,
                 setup: ["Press Cmd+N for a second normal window, open http://127.0.0.1:8765/ in it,",
                         "and place the two windows side by side, not overlapping."],
                 action: ["Click inside box 1 in the NEW (second) window."]),
        StepSpec(id: "two-windows-old", title: "Two normal windows: the old one", kind: .join, joins: 5, needsLabels: false,
                 setup: ["Leave both windows open."], action: ["Click inside box 1 in the OLD (first) window."]),
        StepSpec(id: "two-windows-zoomed", title: "Two normal windows with the same frame (zoomed)", kind: .join, joins: 5, needsLabels: false,
                 setup: ["In EACH of the two windows choose Window > Zoom (on macOS 15 or later, Window > Fill also works),",
                         "so both fill the screen and sit exactly on top of each other. Don't use full screen."],
                 action: ["Click inside box 1 of the window in front."]),
        StepSpec(id: "minimized-window", title: "A minimized normal window next to the one in use", kind: .join, joins: 5, needsLabels: false,
                 setup: ["Un-zoom one window (Window > Zoom again) so the two no longer share a frame,",
                         "then minimize the window NOT showing box 1 in front (Cmd+M in it)."],
                 action: ["Click inside box 1 of the window that is still on screen."]),
        StepSpec(id: "many-windows", title: "Ten normal windows (join time)", kind: .join, joins: 10, needsLabels: false,
                 setup: ["Press Cmd+N until Chrome has 10 windows (the minimized one counts),",
                         "then open http://127.0.0.1:8765/ in the newest window."],
                 action: ["Click inside box 1 of that newest window. Don't type."]),
        StepSpec(id: "spotlight", title: "Spotlight takes the keys while Chrome stays frontmost", kind: .focus, joins: 0, needsLabels: false,
                 setup: ["Close the extra windows (Cmd+Shift+W in each) until two normal windows are left; un-minimize any that is minimized."],
                 action: ["Click inside box 1. At the Tink sound: press Cmd+Space, type made-up words in Spotlight",
                          "(do NOT press Return), wait about 3 seconds, then press Esc. Wait for the Glass sound."]),
        StepSpec(id: "native-editors", title: "TextEdit / Notes: system-wide focus matches the frontmost app", kind: .nativeFocus, joins: 0, needsLabels: false,
                 setup: ["Open TextEdit with a new blank document. Notes is optional: if you use it, make a new note and delete it afterwards."],
                 action: ["Click into the TextEdit document. At the Tink sound type made-up words until the Glass sound (12 s).",
                          "If you opened Notes, switch to the note halfway through and keep typing there."]),
        StepSpec(id: "incognito-race", title: "Incognito window opened (Cmd+Shift+N)", kind: .race, joins: 3, needsLabels: false,
                 setup: ["No Incognito or Guest window is open."],
                 action: ["Click inside box 1 of a normal window. At the Tink sound, press Cmd+Shift+N.",
                          "Leave the new Incognito window open and in front until the Glass sound."]),
        StepSpec(id: "incognito-background", title: "Incognito window open behind a normal window", kind: .strict, joins: 3, needsLabels: false,
                 setup: ["Keep the Incognito window open."],
                 action: ["Click inside box 1 of a NORMAL window, so the Incognito window is behind it."]),
        StepSpec(id: "incognito-closing", title: "Incognito window closing behind a \"Leave site?\" dialog", kind: .closing, joins: 0, needsLabels: false,
                 setup: ["In the Incognito window, open http://127.0.0.1:8765/ and tick box 10 (Ask before leaving)."],
                 action: ["Click an empty part of that Incognito page. At the Tink sound press Cmd+Shift+W (close window).",
                          "Chrome asks \"Leave site?\": leave the dialog open and touch nothing until the Glass sound,",
                          "then answer the question in Terminal, then click Leave in Chrome."]),
        StepSpec(id: "guest", title: "Guest window", kind: .guest, joins: 3, needsLabels: false,
                 setup: ["Make sure the Incognito window is closed (click Leave if the dialog is still open).",
                         "Open a Guest window: click the profile icon at the top right > Guest. Leave it open."],
                 action: ["Nothing in Chrome. Answer the question in Terminal."]),
        // fix/web-textbox: last, so the step numbers above stay the same. Any Guest or Incognito
        // window would deny every join here, so they are closed first.
        StepSpec(id: "combo-input", title: "Box 12: search box with suggestions (input role=combobox, no label)", kind: .join, joins: 5, needsLabels: false,
                 setup: ["Close the Guest window and any Incognito window. In a normal window, reload http://127.0.0.1:8765/ so boxes 12 and 13 show."],
                 action: ["Click inside box 12 (Search box with suggestions). Don't type."]),
        StepSpec(id: "password-combo", title: "Box 13: hidden text with role=combobox (password input, no label)", kind: .join, joins: 3, needsLabels: false,
                 setup: [], action: ["Click inside box 13 (Hidden combo box). Don't type."]),
    ]
    public static func spec(_ id: String) -> StepSpec? { all.first { $0.id == id } }

    /// A strict step (incognito-background) measures joins while an Incognito
    /// window is open. When every listed window reports "normal" there is no
    /// such window (for example `--only incognito-background` in a new Chrome,
    /// or step 21 skipped), so the step measures nothing: it is not run, and
    /// A2 is NOT RUN rather than FAIL. A window whose mode is anything else
    /// (incognito, empty, unknown) keeps the step running, so a Chrome that
    /// misreports a mode is still graded. A new Incognito window that reports
    /// "normal" is caught by incognito-race (A2 needs both steps to pass).
    public static func strictPrecondition(modes: [String]) -> String? {
        guard modes.allSatisfy({ $0 == "normal" }) else { return nil }
        return "no Incognito window is open (\(modes.count) window(s), all normal), so this step measured nothing."
            + " Press Cmd+Shift+N first, or re-run it together with incognito-race."
    }
}

/// What one guided step produced. No titles, full URLs, labels or typed text.
public struct StepResult: Codable {
    public var id: String
    public var ran = false
    public var skippedReason: String?
    public var joins: [JoinReport] = []
    public var lightMs: [Double] = []
    public var lightOK = 0
    /// Typing step: whether the focused element stayed CFEqual between samples.
    public var elementStable: [Bool] = []
    /// Plain-input step: time from the first Accessibility read until a web area showed up.
    public var warmupMs: Double?
    public var focus: FocusSummary?
    public var race: RaceResult?
    public var closing: ClosingResult?
    public var descriptor: DescriptorResult?
    public var windows: [WindowEntry]?
    public var guestConfirmed: Bool?
    public var notes: [String] = []
    public init(id: String) { self.id = id }
}
