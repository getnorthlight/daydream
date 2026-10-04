import SwiftUI

public struct DownloadTimeRemaining: View {
    private let estimate: DownloadTimeEstimate

    public init(estimate: DownloadTimeEstimate) { self.estimate = estimate }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let text = estimate.text(at: ProcessInfo.processInfo.systemUptime) {
                Text(text).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
