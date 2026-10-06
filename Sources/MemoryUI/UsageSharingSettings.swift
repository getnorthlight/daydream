import SwiftUI
import AppKit

/// Settings › Advanced › Share anonymous usage counts: the one switch (on by default), its one line, Copy ID and
/// See what's sent (the last events, queued or sent, exactly as they go). The app's `UsageSender` does the rest.
public enum UsageSharingText {
    public static let title = "Share anonymous usage counts"
    public static let detail = "Counts like how often DayDream is opened or used by AI apps. Never your history, typed words, titles or searches."
    public static let copyID = "Copy ID"
    public static let copied = "Copied"
    public static let seeWhatsSent = "See what's sent"
    public static let nothingYet = "Nothing yet."
    public static let off = "Off. Nothing is sent."
}

/// One event for See what's sent: whether it went yet, and the JSON as sent.
public struct UsageSharingEntry: Identifiable, Equatable {
    public let id: Int
    public let sent: Bool
    public let json: String
    public init(id: Int, sent: Bool, json: String) { self.id = id; self.sent = sent; self.json = json }
}

public struct UsageSharingCard: View {
    @Binding var isOn: Bool
    let installID: String
    let entries: [UsageSharingEntry]
    let refresh: () -> Void
    @State private var copied = false
    @State private var showing: Bool

    /// `refresh`: runs when See what's sent opens (the app reads what AI apps' calls added meanwhile).
    public init(isOn: Binding<Bool>, installID: String, entries: [UsageSharingEntry], showing: Bool = false, refresh: @escaping () -> Void = {}) {
        _isOn = isOn; self.installID = installID; self.entries = entries; self.refresh = refresh
        _showing = State(initialValue: showing)
    }

    public var body: some View {
        SettingsCard {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(UsageSharingText.title).font(.system(size: 13))
                    Text(UsageSharingText.detail).font(DaydreamType.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(ReferenceToggleStyle()).frame(minHeight: 36)
            .accessibilityIdentifier("settings-usage-counts")
            HStack(spacing: 10) {
                Button(copied ? UsageSharingText.copied : UsageSharingText.copyID) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(installID, forType: .string)
                    copied = true
                }
                .help("Copies this Mac's random usage ID, to ask for its counts to be deleted")
                .accessibilityIdentifier("settings-usage-copy-id")
                Button(UsageSharingText.seeWhatsSent) {
                    if !showing { refresh() }
                    showing.toggle()
                }
                .accessibilityIdentifier("settings-usage-see-sent")
                Spacer()
            }
            .font(DaydreamType.detail)
            if showing { sentList }
        }
    }

    @ViewBuilder private var sentList: some View {
        if entries.isEmpty {
            Text(isOn ? UsageSharingText.nothingYet : UsageSharingText.off).font(DaydreamType.detail).foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.sent ? "Sent" : "Waiting to send").font(DaydreamType.caption).foregroundStyle(.secondary)
                            Text(entry.json).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(maxHeight: 240)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
