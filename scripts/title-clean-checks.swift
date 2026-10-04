// DD-RECIPE: UI
//
// fix/day-card: TitleClean turns a window or page title into a name a person would say. Every row title without a note,
// every live thread label and every page title a cloud writer reads goes through it. 20 fixtures from real window and
// page titles (the replay days' Gmail, GitHub, Docs, Slack, YouTube, Teams, Messages and Xcode titles). Code only.
import Foundation
import MemoryCore

@main enum TitleCleanChecks {
    static func main() {
        let owner: Set<String> = ["sam@daydream.example"]
        // (raw title, app, site, expected)
        let fixtures: [(String, String, String, String)] = [
            ("Inbox (23) - sam@daydream.example - Gmail", "Chrome", "https://mail.google.com", "Email"),
            ("Re: Pro plan pricing - sam@daydream.example - Gmail", "Chrome", "https://mail.google.com", "Pro plan pricing"),
            ("Launch checklist - sam@daydream.example - Gmail", "Chrome", "https://mail.google.com", "Launch checklist"),
            ("Weekly summaries export by riley · Pull Request #418 · daydream/daydream", "Chrome", "https://github.com", "PR #418: Weekly summaries export"),
            ("Export crash on large days · Issue #77 · daydream/daydream", "Chrome", "https://github.com", "Issue #77: Export crash on large days"),
            ("Q3 investor update - Google Docs", "Chrome", "https://docs.google.com", "Q3 investor update"),
            ("#eng (Channel) - DayDream - Slack", "Slack", "", "#eng"),
            ("Priya (DM) - DayDream - Slack", "Slack", "", "Priya"),
            ("(3) How Linear builds product - YouTube", "Chrome", "https://www.youtube.com", "How Linear builds product"),
            ("Chat | Maya Chen | Microsoft Teams", "Microsoft Teams", "", "Maya Chen"),
            ("Fwd: Re: Friday dinner (4 messages)", "Mail", "", "Friday dinner"),
            ("Sent Mail - sam@daydream.example - Gmail", "Chrome", "https://mail.google.com", "Email"),
            ("ExportWriter.swift — daydream", "Xcode", "", "ExportWriter.swift - daydream"),
            ("WhatsApp (5)", "WhatsApp", "", "WhatsApp"),
            ("Pricing page | Notion", "Notion", "", "Pricing page"),
            ("mail.google.com", "Chrome", "https://mail.google.com", "Email"),
            ("Home / X", "Chrome", "https://x.com", "X"),
            ("Inbox • Sam Rivera • iCloud Mail", "Safari", "https://www.icloud.com", "Email"),
            ("DayDream launch plan – Edited", "Pages", "", "DayDream launch plan"),
            ("A very long page title that keeps going well past the width of any row in the list and then some more words", "Chrome", "https://example.com",
             "A very long page title that keeps going well past the width of any row in the list and…"),
        ]
        var passed = 0
        for (i, f) in fixtures.enumerated() {
            let got = TitleClean.clean(f.0, app: f.1, site: f.2, ownerEmails: owner.union(["sam.rivera@daydream.example"]))
            let ok = got == f.3 && !got.contains("@") && got.range(of: "\\(\\d+\\)", options: .regularExpression) == nil
                && !got.contains(" - Gmail") && !got.contains(" · Pull Request") && !got.contains(" | ")
            if ok { passed += 1; print("PASS \(i + 1) \(f.0) -> \(got)") }
            else { print("FAIL \(i + 1) \(f.0) -> \(got) (want \(f.3))") }
        }
        // Thread labels: "GitHub PR #418: …" reads "PR #418: …".
        let label = TitleClean.label("GitHub PR #418: Weekly summaries export")
        if label == "PR #418: Weekly summaries export" { print("PASS label GitHub PR") } else { print("FAIL label GitHub PR -> \(label)"); passed -= 100 }
        print("title-clean \(max(0, passed))/\(fixtures.count)")
        exit(passed == fixtures.count ? 0 : 1)
    }
}
