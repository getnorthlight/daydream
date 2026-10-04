import SwiftUI
import MemoryCore
import MemoryUI

/// Settings › Connections: one row per AI app on this Mac with its status and one button. Connect is one click (it
/// restarts a running app and brings up a starter prompt); Disconnect is one click. Each button's help tag names the
/// file it changes. Nothing on the page needs scrolling to reach.
struct ConnectionSettings: View {
    @ObservedObject var model: ConnectionSettingsModel
    /// Owner 10/3: the same "Let AI apps read what you typed" switch as setup's Permissions card.
    @AppStorage(AIReadsTypedSetting.key) private var aiReadsTyped = AIReadsTypedSetting.defaultValue

    static let intro = "Connected AI apps can read your history and may send it to their own online service."
    static let noApps = "None of the AI apps DayDream connects to are on this Mac."

    var body: some View {
        SettingsSurface("Connections") {
            Text(Self.intro).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let unavailable = model.unavailable {
                Label { Text(unavailable).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("connections-unavailable")
            }
            SettingsCard {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AIReadsTypedSetting.title).font(.system(size: 13))
                        Text(AIReadsTypedSetting.line).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("", isOn: $aiReadsTyped).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(AIReadsTypedSetting.title)
                }
                .accessibilityIdentifier("connections-ai-reads-typed")
            }
            if model.loaded && model.visibleRows.isEmpty {
                Text(Self.noApps).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                SettingsCard {
                    ForEach(Array((model.loaded ? model.visibleRows : model.rows).enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        AIAppRow(row: row, model: model)
                    }
                }
            }
        }
        .connectionFrame("viewport")
        .onAppear { model.pageAppeared() }
        .onDisappear { model.pageDisappeared() }
        .alert(model.pendingReplace.map(model.replaceTitle) ?? "",
               isPresented: Binding(get: { model.pendingReplace != nil }, set: { if !$0 { model.cancelReplace() } }),
               presenting: model.pendingReplace) { pending in
            Button("Cancel", role: .cancel) { model.cancelReplace() }
            Button(model.replaceButton(pending)) { Task { await model.replace(pending) } }
        } message: { pending in
            Text(model.replaceMessage(pending))
        }
        // Cancel is the default: the app was asking something, and what's unsaved in it would be lost.
        .alert(model.pendingForceQuit.map(model.forceQuitTitle) ?? "",
               isPresented: Binding(get: { model.pendingForceQuit != nil }, set: { if !$0 { model.cancelForceQuit() } }),
               presenting: model.pendingForceQuit) { app in
            Button("Cancel", role: .cancel) { model.cancelForceQuit() }.keyboardShortcut(.defaultAction)
            Button("Force Quit", role: .destructive) { Task { await model.confirmForceQuit(app) } }
        } message: { app in
            Text(model.forceQuitMessage(app))
        }
    }
}

private struct AIAppRow: View {
    let row: ConnectionSettingsModel.Row
    @ObservedObject var model: ConnectionSettingsModel

    var body: some View {
        let shown = model.presentation(row)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                AIAppIcon(row: row).opacity(shown.dimmed ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.app.name).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(shown.dimmed ? Color.secondary : Color.primary)
                    if let statusHelp { StatusLine(shown: shown).help(statusHelp) } else { StatusLine(shown: shown) }
                }
                Spacer(minLength: 8)
                if let control = shown.button {
                    Button(control.title) { Task { await model.perform(control.action, row.app) } }
                        .disabled(!model.enabled(control.action))
                        .help(help(control.action))
                        .accessibilityLabel("\(control.title) \(row.app.name)")
                        .connectionFrame("button.\(row.id)")
                }
            }
            if let detail = shown.detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.leading, AIAppIcon.size + 12)
            }
            if model.promptApp == row.id {
                Label(model.promptNote(row.app), systemImage: "doc.on.clipboard")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.leading, AIAppIcon.size + 12)
                    .connectionFrame("prompt.\(row.id)")
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .contain)
    }

    private var statusHelp: String? {
        switch row.state {
        case .needsAttention(.keyStopped):
            return "\(row.app.name)'s DayDream key no longer works, for example after a change in Apps to remember. Reconnect gives it a new one."
        case .needsAttention(.otherCopy):
            return "\(row.app.name) starts a different copy of DayDream. Reconnect points it at this one."
        default: return nil
        }
    }

    private func help(_ action: ConnectionSettingsModel.RowPresentation.Action) -> String {
        let restarts = row.running != nil ? " \(row.app.name) quits and opens again." : ""
        switch action {
        case .connect:
            // What happens after: the app opens on a new chat with the question typed in, or the question is copied.
            let prompt = row.newChat != nil
                ? (row.running != nil ? " \(row.app.name) quits and opens again on a new chat with a first question typed in."
                                      : " \(row.app.name) opens on a new chat with a first question typed in.")
                : restarts + " Copies a first question to ask it."
            return "Adds DayDream to \(model.settingsFile(row.app)).\(prompt)"
        case .disconnect: return "Removes DayDream from \(model.settingsFile(row.app)) and turns its access off.\(restarts)"
        case .restart: return "\(row.app.name) quits and opens again, so it loads DayDream."
        case .forceRestart: return "Asks first, then force quits \(row.app.name) and opens it again."
        }
    }
}

private struct StatusLine: View {
    let shown: ConnectionSettingsModel.RowPresentation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if shown.working {
                ProgressView().controlSize(.mini).frame(width: 12, height: 12).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            } else {
                Image(systemName: shown.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            }
            Text(shown.status).font(.system(size: 12))
                .foregroundStyle(shown.tone == .failure ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch shown.tone {
        case .quiet: return .secondary
        case .good: return .green
        case .attention: return .orange
        case .failure: return .red
        }
    }
}

/// Installed app icons, with bundled product branding for CLI and missing apps.
private struct AIAppIcon: View {
    static let size: CGFloat = 30
    let row: ConnectionSettingsModel.Row

    var body: some View {
        if let location = row.location {
            AppIcon(bundle: location.path, name: row.app.name, size: Self.size)
        } else if ["claude-code","cursor"].contains(row.app.id) {
            ConnectionProductIcon(id:row.app.id,size:Self.size)
        } else {
            AppIcon(bundle: nil, name: row.app.name, size: Self.size)
        }
    }
}

/// Frames of the page's viewport, row buttons and starter prompts, for the checks that assert nothing needs scrolling.
struct ConnectionFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func connectionFrame(_ key: String) -> some View {
        background(GeometryReader { proxy in Color.clear.preference(key: ConnectionFrames.self, value: [key: proxy.frame(in: .global)]) })
    }
}
