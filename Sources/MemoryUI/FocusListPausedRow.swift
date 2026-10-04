import SwiftUI

// The live pause at the top of Today's list (spec §3.8, plan L11 and §5 A1). Live only: the store
// keeps no pause history, so a past pause is never drawn. Off and Needs Permission get no row here
// (the toolbar's status capsule owns them). `Resume` is the one explicit control and calls
// `resume` only when pressed.

public struct FocusListPausedRow: View {
    let until: Date?
    let now: Date
    let timeZone: TimeZone
    let canResume: Bool
    let resume: () -> Void

    /// - `until`: the timed pause's end; nil (or already past) reads `Paused · Resume`.
    public init(until: Date?, now: Date, timeZone: TimeZone, canResume: Bool, resume: @escaping () -> Void) {
        self.until = until; self.now = now; self.timeZone = timeZone; self.canResume = canResume; self.resume = resume
    }

    /// The row for a recording state: only while paused, timed or open-ended. nil for every other state.
    public static func pause(in state: RecordingState?) -> (until: Date?, since: Date?)? {
        guard case .paused(let until, let since, _)? = state else { return nil }
        return (until, since)
    }

    /// `Paused until 4:36 PM` or `Paused` (the title before the inline `· Resume`).
    public static func title(until: Date?, now: Date, timeZone: TimeZone) -> String {
        guard let until, until > now else { return "Paused" }
        return "Paused until " + DaydreamFormat.time(until, timeZone)
    }

    public var body: some View {
        let title = Self.title(until: until, now: now, timeZone: timeZone)
        // Inside the rows card (inset 6): glyph at 12…44, title at 54 and the band ending 14 from the card
        // edge, the same columns as `DDRow`.
        return HStack(spacing: 10) {
            KitPauseBars(color: DaydreamStyle.paused, h: 11)
                .frame(width: 32, height: 20)
                .accessibilityHidden(true)
            // One line: "Paused" says it (no line explaining what paused means, no end-cap band: the row's
            // hatch and the ribbon's already draw it).
            HStack(spacing: 0) {
                Text(title + " · ").font(.system(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
                Button("Resume", action: resume)
                    .buttonStyle(FocusLinkButtonStyle())
                    .font(.system(size: 13, weight: .semibold))
                    .disabled(!canResume)
                    .help(canResume ? "Resume Recording" : "Recording can't resume right now")
                    .accessibilityLabel("Resume Recording")
            }
            Spacer(minLength: 8)
        }
        .padding(.leading, 6).padding(.trailing, 8)
        .frame(height: 44)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            ZStack {
                DaydreamStyle.paused.opacity(0.05)
                Hatch(spacing: 6).stroke(DaydreamStyle.paused.opacity(0.35), lineWidth: 1)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(DaydreamStyle.paused.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
