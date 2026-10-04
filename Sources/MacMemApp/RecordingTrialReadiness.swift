#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
import SwiftUI
import AppKit
import MemoryCore
import MemoryUI

/// This is the normal, real-store trial, not the locked synthetic development path.
struct RecordingTrialReadiness: View {
    @ObservedObject var model: MemoryViewModel
    let browse: () -> Void
    let settings: () -> Void
    @State private var latest: CanonicalAction?
    @State private var proofError = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsSurface("Recording") {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: model.recording ? "record.circle.fill" : "pause.circle")
                            .font(.system(size: 24))
                            .foregroundStyle(model.recording ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.recording ? "Recording on this Mac" : startUnavailable ? "Recording is off" : "Ready to record")
                                .font(.headline)
                            Text(model.captureText ? "App and window activity, with typed text in supported apps." : "App and window activity. Typed text is off.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 10) {
                        if model.recording {
                            Button { model.stopCapture(); refresh() } label: {
                                Label("Stop Recording", systemImage: "stop.fill")
                            }
                            .buttonStyle(ReferenceButtonStyle(primary: true))
                            .disabled(!model.recording)
                        } else {
                            Button { model.startCapture(); refresh() } label: {
                                Label("Start Recording", systemImage: "record.circle")
                            }
                            .buttonStyle(ReferenceButtonStyle(primary: true))
                            .disabled(startUnavailable)
                        }
                        Button(action: browse) {
                            Label("Browse memory", systemImage: "book.closed")
                        }
                    }
                    if let issue = recordingIssue {
                        Label(issue, systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()
                RecordingPermissionSetup(enabled: model.development == nil, onRefresh: refresh)
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Recording preferences").font(.headline)
                    Button(action: settings) {
                        Label("Excluded apps and typed text", systemImage: "slider.horizontal.3")
                    }
                    Text(TypingSettingsText.ownerBuild
                         ? "Browsers DayDream knows aren't recorded, except Chrome page titles, sites and typing if you turn them on. Optional typed text is supported in \(TypingSettingsText.supportedPlaces())."
                         : "Browsers DayDream knows aren't recorded, except Chrome page titles and sites if you turn them on. Optional typed text is supported in TextEdit and Notes.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Latest saved capture").font(.headline)
                        Spacer()
                        Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                            .help("Check for a saved capture")
                            .accessibilityLabel("Check for a saved capture")
                    }
                    if let latest {
                        Text(latest.app + " · " + (timestamp(latest.at)?.formatted(date: .omitted, time: .standard) ?? "Time unavailable"))
                        Text(latest.description).font(.callout).textSelection(.enabled)
                        if let receipt = model.nativeCommitReceipt {
                            DisclosureGroup("Capture details") {
                                Text("Action: \(receipt.actionID)\nSession: \(receipt.captureSessionID)\nSequence: \(receipt.sequence)\nPath: \(receipt.path.rawValue)\nCommitted: \(receipt.committedAt.formatted(date: .omitted, time: .standard))")
                                    .font(.caption).textSelection(.enabled)
                            }
                        }
                    } else {
                        Text(proofError ? "Saved capture could not be checked. Try again." : "No activity saved in this recording trial yet.")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private var startUnavailable: Bool {
        model.development != nil || model.recording || model.resumeUnavailable != nil || model.privacyDirty || model.history.busy || model.backups.busy || model.backups.prepared != nil
    }

    private var recordingIssue: String? {
        if let issue = model.operationalIssue { return issue }
        if model.privacyDirty { return "Save or discard your recording preferences before starting." }
        if model.history.busy || model.backups.busy { return "Wait for the current memory operation to finish before starting." }
        if model.backups.prepared != nil { return "Finish the pending restore before starting." }
        return model.resumeUnavailable
    }

    private func refresh() {
        guard model.development == nil else { latest = nil; return }
        model.refreshCaptureStatus()
        do { latest = try model.trialSavedAction(); proofError = false }
        catch { latest = nil; proofError = true }
    }
}

#endif
