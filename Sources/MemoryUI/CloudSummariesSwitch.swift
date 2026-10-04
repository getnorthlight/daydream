import SwiftUI
import AppKit

/// Cloud summaries' words, fixed here so setup, Settings and the checks say exactly the same thing.
/// Owner, 9/28: no consent sheet. The switch and its one honest line are the whole question: what the cloud writer sends
/// (window titles, page titles and what you type) and to whom, with zero-retention hosts requested. Turning it on records
/// the version-2 notice (`CloudActivation.disclosureVersion`); nothing is sent before that.
public enum CloudSummariesText {
    /// The switch: the one easy alternative to summaries on this Mac (setup and Settings).
    public static let title = "Use an OpenRouter key instead"
    /// The request OpenRouter gets (provider zdr: true, data_collection: deny). The same words as the note's status label.
    public static let zeroRetention = "Zero-retention hosts requested"
    /// The one line under the switch.
    /// fix/sx-all round 1: "from now on": nothing from before the switch is ever sent (the cloud cutoff).
    public static let line = "From now on, window titles, page titles and what you type go to OpenRouter. \(zeroRetention)."
    public static let keyPlaceholder = "OpenRouter API key"
    public static let savedKeyPlaceholder = "Saved key"
    public static let getKey = "Get a key"
    public static let connect = "Connect"
    public static let keyURL = URL(string: "https://openrouter.ai/settings/keys")!
    /// Add Credits (`SummaryProblem.cloudCredits`).
    public static let creditsURL = URL(string: "https://openrouter.ai/settings/credits")!
}

/// The cloud switch with its one line, the key field while it is on and a key is needed, and a problem's one line with its
/// one button under the field. Values only: the host decides what on means (setup at Continue, Settings at once).
public struct CloudSummariesSwitch: View {
    @Binding private var isOn: Bool
    @Binding private var key: String
    private let showsKey: Bool
    private let savedKey: Bool
    private let working: Bool
    private let problem: SummaryProblem?
    private let fix: ((SummaryProblem) -> Void)?
    private let connect: (() -> Void)?
    private let focusRequest: Int
    private let large: Bool
    @FocusState private var keyFocused: Bool

    /// - `showsKey`: draw the key field (while on and a key is needed, or the key was refused).
    /// - `savedKey`: a key is already saved, so an empty field uses it.
    /// - `working`: the key is being checked (Settings' Connect shows a small spinner; setup's Continue has its own).
    /// - `problem`, `fix`: what went wrong and its one button (Change Key, Add Credits or Try Again).
    /// - `connect`: Settings' Connect beside the field and Return in it (setup's Continue does it instead).
    /// - `focusRequest`: a new value puts the cursor in the key field (Change Key).
    /// - `large`: setup's type sizes (Settings uses its own).
    public init(isOn: Binding<Bool>, key: Binding<String>, showsKey: Bool, savedKey: Bool = false, working: Bool = false,
                problem: SummaryProblem? = nil, fix: ((SummaryProblem) -> Void)? = nil, connect: (() -> Void)? = nil,
                focusRequest: Int = 0, large: Bool = false) {
        _isOn = isOn; _key = key
        self.showsKey = showsKey; self.savedKey = savedKey; self.working = working
        self.problem = problem; self.fix = fix; self.connect = connect
        self.focusRequest = focusRequest; self.large = large
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CloudSummariesText.title).font(.system(size: large ? 13 : 14, weight: large ? .semibold : .regular))
                    Text(CloudSummariesText.line).font(.system(size: large ? 11 : 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("cloud-summaries-line")
                }.frame(maxWidth: .infinity, alignment: .leading)
                Toggle(CloudSummariesText.title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel(CloudSummariesText.title)
            }
            .accessibilityElement(children: .combine)
            if showsKey {
                HStack(spacing: 8) {
                    // The label is the placeholder; with a key saved, an empty field uses it.
                    SecureField(savedKey ? CloudSummariesText.savedKeyPlaceholder : CloudSummariesText.keyPlaceholder, text: $key)
                        .textFieldStyle(.roundedBorder).accessibilityLabel(CloudSummariesText.keyPlaceholder)
                        .focused($keyFocused)
                        .onSubmit { if !key.isEmpty { connect?() } }
                    if let connect {
                        Button(action: connect) {
                            HStack(spacing: 6) {
                                if working { ProgressView().controlSize(.mini) }
                                Text(CloudSummariesText.connect)
                            }
                        }.disabled(key.isEmpty || working)
                    }
                    Link(CloudSummariesText.getKey, destination: CloudSummariesText.keyURL).font(.system(size: 11))
                }
            }
            if let problem {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(problem.line).font(.system(size: large ? 11 : 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // fix/sx-all round 1: with the key field showing, a refused key's own Change Key would be a third
                    // button beside Connect and Get a key; the field is the fix.
                    if let fix, !(showsKey && problem == .cloudKey) { Button(problem.button) { fix(problem) }.controlSize(.small) }
                }
                .accessibilityElement(children: .contain)
            }
        }
        .onChange(of: focusRequest) { _ in keyFocused = true }
    }
}
