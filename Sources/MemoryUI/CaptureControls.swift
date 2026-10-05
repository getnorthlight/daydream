import SwiftUI

public struct CapturePresentation {
    public var title:String, issue:String?
    public var recording:Bool, canResume:Bool, canStop:Bool
    /// The four-state model the redesigned surfaces draw from. The legacy init derives it from
    /// the legacy fields; `init(state:…)` and `init(inputs:…)` set it exactly.
    public var state:RecordingState
    /// Last permission reads, for the Needs Permission rows. nil = not read.
    public var permissions:PermissionSnapshot?
    /// The menu bar's "Browser history on" line (Chrome page history). Off unless the host sets it.
    public var browserHistory:BrowserHistoryLine = .off
    /// chromeask-1005: Chrome access was refused, so the Chrome line's button is Ask again (else Fix).
    public var chromeAskAgain:Bool = false
    public init(title:String,issue:String?=nil,recording:Bool=false,canResume:Bool=false,canStop:Bool=false) {
        self.title=title; self.issue=issue; self.recording=recording; self.canResume=canResume; self.canStop=canStop
        self.state=CapturePresentation.legacyState(title:title,issue:issue,recording:recording); self.permissions=nil
    }
}
/// The one line the menu bar card shows under the state title while Chrome page history is on.
public enum BrowserHistoryLine:Equatable,Sendable {
    case off, on, needsAccess
    /// This copy of Chrome can't be verified: no page is saved until it can be (review G30).
    case paused
    /// Two of the person's own Chrome processes run: nothing is saved until one quits.
    case twoCopies
    /// Recording with "Web pages in Chrome" on: `.needsAccess` while Chrome access is off (not allowed yet,
    /// or turned off in System Settings), `.paused` while Chrome can't be verified, else `.on`. Anything
    /// else, and while Google Chrome itself is excluded (nothing is saved then): `.off`. `access` is the
    /// last answer, not `.checking` (the line never flips while a check runs), and macOS's last answer while
    /// Chrome is closed (chromeask-1005: a refusal still shows then).
    public static func make(recording:Bool,pagesOn:Bool,access:ChromeAccessState,chromeExcluded:Bool=false) -> BrowserHistoryLine {
        guard recording, pagesOn, !chromeExcluded else { return .off }
        if access == .unverified { return .paused }
        if access == .twoCopies { return .twoCopies }
        return access.accessOff ? .needsAccess : .on
    }
    public var text:String? {
        switch self {
        case .off: return nil
        case .on: return "Browser history on (Google Chrome)"
        case .needsAccess: return ChromeAccessNotice.line
        case .paused: return "Browser history paused: Chrome not verified"
        case .twoCopies: return "Browser history paused: two Chromes open"
        }
    }
    public static let symbol="globe"
}
public struct CaptureActions {
    public var pause:(Int)->Void, resume:()->Void, stop:()->Void, settings:()->Void
    public init(pause:@escaping(Int)->Void={_ in},resume:@escaping()->Void={},stop:@escaping()->Void={},settings:@escaping()->Void={}) {
        self.pause=pause; self.resume=resume; self.stop=stop; self.settings=settings
    }
    /// Allow Permissions (Needs Permission): the app shows DayDream's drag cards, where each card's button opens
    /// System Settings at its pane. The missing permission is passed when exactly one is known. Never prompts.
    public var openSystemSettings:(PermissionKind?)->Void = { _ in }
    /// Re-reads permissions without prompting ("Check Again").
    public var checkPermissions:()->Void = {}
    /// Opens a settings section by its legacy section string.
    public var openSettingsSection:(String)->Void = { _ in }
    public var openMain:()->Void = {}
    public var openRecall:()->Void = {}
    public var quit:()->Void = {}
    /// Report a Problem…: opens an email to support in the person's mail app (nil: the menu doesn't offer it).
    public var reportProblem:(()->Void)? = nil
    /// Opens the Applications folder while DayDream runs from the download window (nil: not offered).
    public var openApplications:(()->Void)? = nil
    /// Try Again beside an orange line whose fix is to run the job again (`RecordingCopy.retriedIssues`: the history
    /// upkeep, a deletion). Never starts, pauses or stops recording.
    public var retryIssue:()->Void = {}
    /// chromeask-1005: Fix beside "Chrome pages aren't being saved." Refused: Privacy & Security › Automation; not asked
    /// yet: setup's Chrome row (the app decides). Never a macOS question from here.
    public var fixChrome:()->Void = {}
}

extension CapturePresentation {
    /// Presentation from the redesign state. Title and `recording` follow the state.
    public init(state:RecordingState,issue:String?=nil,canResume:Bool=false,canStop:Bool=false,permissions:PermissionSnapshot?=nil) {
        self.init(title:state.title,issue:issue,recording:state.kind == .recording,canResume:canResume,canStop:canStop)
        self.state=state; self.permissions=permissions
    }
    /// Presentation straight from the app's capture fields: `state = RecordingState.derive(inputs)` and
    /// `issue = operationalIssue ?? resumeUnavailable`, as today's `MacMemModel.presentation`.
    public init(inputs:RecordingStateInputs,permissions:PermissionSnapshot?=nil) {
        self.init(state:RecordingState.derive(inputs),issue:inputs.issue,
                  canResume:inputs.resumeUnavailable == nil && !inputs.development,
                  canStop:inputs.recording || inputs.pauseUntil != nil || !inputs.stopped,
                  permissions:permissions)
    }
    /// The orange attention line: the mapped issue when it says something the state detail doesn't.
    public func attentionLine(now:Date,timeZone:TimeZone = .current) -> String? {
        state.attentionLine(issue:issue,now:now,timeZone:timeZone)
    }
    /// Best-effort state for callers still on the legacy init (titles such as "Paused until 4:36 PM",
    /// "Setup required", "Development Trial · OFF"). Dates and missing permissions are unknown here.
    /// `issue` is `operationalIssue ?? resumeUnavailable`, so only a blocker the copy table knows
    /// explains why recording is off; any other issue (writer, input, deletion) leaves the Off
    /// detail alone and shows as the attention line. `shortState` titles every resume blocker
    /// "Setup required", so that title keeps its blocker line when an operational issue hides it.
    static func legacyState(title:String,issue:String?,recording:Bool) -> RecordingState {
        if recording { return .recording(since:nil) }
        if title.hasPrefix("Development Trial") { return .off(since:nil,reason:RecordingCopy.developmentTrial) }
        if title.hasPrefix("Paused") { return .paused(until:nil,since:nil,reason:nil) }
        if let issue, issue.contains("ermission") { return .needsPermission(missing:[]) }
        if let blocker = RecordingCopy.knownBlocker(issue) { return .off(since:nil,reason:blocker) }
        if title == "Setup required" { return .off(since:nil,reason:RecordingCopy.blocker(title)) }
        return .off(since:nil,reason:nil)
    }
}

extension CaptureActions {
    /// Runs a state's action. Start and resume share the explicit resume path.
    public func perform(_ action:RecordingAction) {
        switch action {
        case .start, .resume: resume()
        case .stop: stop()
        case .pause(let minutes): pause(minutes)
        case .openSystemSettings: openSystemSettings(nil)
        case .checkAgain: checkPermissions()
        }
    }
}
/// Settings ▸ Advanced ▸ Recording: the one capture control in Settings. The window draws `StatusCapsule` and
/// `RecordingControls` (DaydreamToolbar.swift, StatusPopover.swift); the menus, `MenuBarRecordingMenu`.
public struct RecordingMasterControl:View {
    let state:CapturePresentation;let actions:CaptureActions
    public init(state:CapturePresentation,actions:CaptureActions) {self.state=state;self.actions=actions}
    public var body:some View {
        Toggle(isOn:Binding(get:{state.recording},set:{requested in
            if requested {if state.canResume {actions.resume()}}
            else if state.recording {actions.pause(0)}
        })) {
            VStack(alignment:.leading,spacing:3) {
                Text("Recording")
                if let line=Self.subtitle(state.state) {Text(line).foregroundStyle(.secondary)}
            }
        }.toggleStyle(ReferenceToggleStyle()).font(.system(size:14)).frame(minHeight:state.recording ? 36:52)
            .disabled(!state.recording && !state.canResume).help(state.issue.map(RecordingCopy.issue) ?? "Pause or resume recording")
    }
    /// The line under the toggle while it is off, in the four-state vocabulary (never the legacy `shortState`
    /// titles "Stopped", "Setup required", "… · OFF" or a locale-formatted pause end):
    /// Paused → `Paused · nothing is recorded`; Off → `Off · nothing is recorded`, or the blocker that keeps it off;
    /// Needs Permission → `Needs Permission · Input Monitoring is off` (the missing one, when the reads name it).
    public static func subtitle(_ state:RecordingState) -> String? {
        switch state {
        case .recording: return nil
        case .paused: return "Paused · nothing is recorded"
        case .off(_,let reason): return reason ?? "Off · nothing is recorded"
        case .needsPermission(let missing):
            // perm-1004: `Turn on Accessibility · Input Monitoring is off too` names every missing permission.
            guard let next = PermissionKind.next(missing) else { return "Needs Permission" }
            let others = PermissionKind.allCases.filter { missing.contains($0) && $0 != next }
            return others.isEmpty ? next.turnOnTitle : next.turnOnTitle + " · " + others.map(\.title).joined(separator: " and ") + " is off too"
        }
    }
}
