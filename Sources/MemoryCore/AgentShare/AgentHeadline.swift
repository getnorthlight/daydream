import Foundation

// agent-tools v2, integrator: the day headline `timeline` prints ("Day note: …"), read-only.
//
// The day-summary agent's planned `dayReviewHeadline` accessor didn't land for 0.1.5, so this is the nearest equivalent:
// the stored day note (L4, `level_notes`) the app's day card shows as its headline (`DayLevelSlice.dayTitle`). Nothing
// is written and no model runs. A day with no stored day note (or a note saved plain) has no headline, and `timeline`
// omits the line. The headline goes through the same read-time filter as every note line (`AgentItems.noteLine`: no
// send state, no "draft", no filler).
extension MemoryStore: DayReviewHeadlineSource {
    public func dayReviewHeadline(day: String, timezone: String) throws -> String? {
        try dayReviewHeadline(day: day, timezone: timezone, typedWords: true)
    }

    public func dayReviewHeadline(day: String, timezone: String, typedWords: Bool) throws -> String? {
        let notes = try levelNotes(level: .day, periods: [day])
        guard let note = notes.first(where: { $0.timezone == timezone }) ?? notes.first else { return nil }
        // Written from typed rows: shown only while typed words are shared (its words never repeat a typed row's).
        if note.typedDerived, !typedWords { return nil }
        // Saved plain ("Document"): says less than the day's items, so none.
        if DayLevels.savedPlain(note) { return nil }
        var title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // A model title that only says what was open gives way to the note's main thread (the day card's rule).
        if NoteFiller.isFiller(title, apps: []) || title.lowercased().hasPrefix("day summary") {
            guard let main = note.threads?.first?.label, !main.isEmpty else { return nil }
            title = main
        }
        return AgentItems.noteLine(title, itemName: "")
    }
}
