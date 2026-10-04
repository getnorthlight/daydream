import SwiftUI
import MemoryCore

// Owner 10/3: the old "Captured wording · <time> / Wrote: …" views (OwnerSourceDetailSection, OwnerSourceStandIn) are
// gone. Before a summary, the details page and the card both show `FocusAppCard.leftColumn`: "Summary pending" (violet) or
// "What you wrote" over the stitched messages, quoted (`CapturedStitch`).

/// Own-window lifecycle identity only. It never reads another app or its text.
struct OwnerSourceDetailWindowReader: NSViewRepresentable {
    let changed: (Int?) -> Void
    func makeNSView(context: Context) -> Reader { let v=Reader();v.changed=changed;return v }
    func updateNSView(_ view: Reader, context: Context) { view.changed=changed }
    final class Reader: NSView {
        var changed: ((Int?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let id=window?.windowNumber
            DispatchQueue.main.async { [weak self] in self?.changed?(id) }
        }
    }
}


// A short source account replaces only the same fully cited action.
// Unknown/mixed ownership never suppresses a local model bullet.
public enum OwnerSourceSummaryProjection {
    public static func previews(_ previews: [OwnerSourcePreview], bullets: [MomentBullet]) -> [OwnerSourcePreview] {
        let generated = bullets.filter { !$0.correction }
        guard !generated.contains(where: { $0.actionIDs.isEmpty }) else { return [] }
        return previews.filter { preview in
            let own = Set(preview.actionIDs)
            return preview.runID != nil && !own.isEmpty && generated.allSatisfy { bullet in
                let cited = Set(bullet.actionIDs)
                return cited.isDisjoint(with: own) || cited.isSubset(of: own)
            }
        }
    }
    public static func remaining(_ bullets: [MomentBullet], previews: [OwnerSourcePreview]) -> [MomentBullet] {
        let covered = Set(previews.flatMap(\.actionIDs))
        return bullets.filter { bullet in
            bullet.correction || bullet.actionIDs.isEmpty || !Set(bullet.actionIDs).isSubset(of: covered)
        }
    }
}

/// Shared section ordering for the expanded card and full selected detail.
struct MomentSummaryAndHistory<Summary: View, History: View>: View {
    let summary: Summary
    let history: History
    init(@ViewBuilder summary: () -> Summary, @ViewBuilder history: () -> History) {
        self.summary = summary(); self.history = history()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(OwnerSourceMomentProjection.sectionOrder, id: \.self) { section in
                switch section {
                case .summary: summary
                case .whatHappened: history
                }
            }
        }
    }
}
