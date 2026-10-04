import Foundation
import WriterBackend

var passed=0, failed=0
func check(_ ok:Bool,_ label:String) {
    if ok {passed += 1; print("PASS "+label)} else {failed += 1; print("FAIL "+label)}
}
@main struct ExistingHistoryNoteChecks {
    static func main() throws {
        let fixturePath = CommandLine.arguments.count > 1 ? URL(fileURLWithPath:CommandLine.arguments[1])
            : URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("fixtures/derived-history-page-pattern.json")
        let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:fixturePath)) as! [String:Any]
        let rows=fixture["actions"] as! [[String:Any]]
        let epoch=ISO8601DateFormatter().date(from:fixture["testEpoch"] as! String)!
        let formatter=ISO8601DateFormatter(); formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        for (i,fixtureRow) in rows.enumerated() {
            var row=fixtureRow
            row["at"]=formatter.string(from:epoch.addingTimeInterval(fixtureRow["fixtureOffsetSeconds"] as! Double))
            row.removeValue(forKey:"fixtureOffsetSeconds")
            let body:[String:Any] = ["id":"history-replay-\(i)","schemaVersion":1,"targetKind":"activity","targetID":"history-replay-\(i)","day":"2001-01-01","timezone":"UTC","inputRevision":"observed-title-replay","policyRevision":"replay","expiresAt":"2099-01-01T00:00:00Z","actions":[row],"actionCount":1]
            let request=try JSONDecoder().decode(CanonicalNoteRequest.self,from:JSONSerialization.data(withJSONObject:body))
            let view=try ModelView(request:request,actions:request.actions)
            let note=try CanonicalGrounding.codeNote(request,view:view)
            let prose=note.bullets.map(\.text).joined(separator:" ")
            let site=row["site"] as! String
            check(note.bullets.allSatisfy {$0.assertion=="observed"},"derived page \(i): observation attribution retained")
            check(note.bullets.allSatisfy {$0.text.count<=240},"derived page \(i): bounded output")
            check(Set(note.bullets.flatMap(\.actionIDs)) == [row["id"] as! String],"derived page \(i): original evidence retained")
            if site=="x.com" {
                let title=row["title"] as! String
                let expected=title.hasPrefix("Example Author") ? "paper lantern" : "blue ceramic cup"
                check(prose.contains(expected),"derived X page \(i): saved topic retained")
                check(prose.contains("titled") && prose.contains("…"),"derived X page \(i): explicitly a title excerpt")
            } else {
                check(prose.lowercased().contains(site),"derived embedded page \(i): site preserved")
                check(!prose.contains("ChatGPT chat") && !prose.hasPrefix("Read"),"derived embedded page \(i): no AI-chat reading claim")
            }
            check(try CanonicalGrounding.check(note,request:request,view:view)==note,"derived page \(i): writer accepts exact code note")
            print("NOTE \(i): "+prose)
        }
        // Template unit coverage only: invented tokens, not additional user-history claims.
        for (i, sample) in [("Messages", "Sample Person", "Viewed texts with"),
                            ("Mail", "Sample agenda", "Viewed email:"),
                            ("Slack", "#sample | Example Workspace", "Viewed #sample on")].enumerated() {
            let action:[String:Any] = ["id":"template-action-\(i)","at":"2001-01-01T00:00:00Z",
                "kind":"window.changed","app":sample.0,"site":"","title":sample.1,
                "description":"Observed surface; reading and attention not established.","state":"observed","revision":"fixture-policy","typing":"on"]
            let body:[String:Any] = ["id":"template-note-\(i)","schemaVersion":1,"targetKind":"activity","targetID":"template-note-\(i)",
                "day":"2001-01-01","timezone":"UTC","inputRevision":"fixture-input","policyRevision":"fixture-policy",
                "expiresAt":"2099-01-01T00:00:00Z","actions":[action],"actionCount":1]
            let request=try JSONDecoder().decode(CanonicalNoteRequest.self,from:JSONSerialization.data(withJSONObject:body))
            let view=try ModelView(request:request,actions:request.actions)
            let note=try CanonicalGrounding.codeNote(request,view:view)
            check(note.bullets.first?.text.hasPrefix(sample.2)==true,"passive template \(i): viewed surface, no reading claim")
            check(note.bullets.allSatisfy {$0.assertion=="observed" && !$0.text.hasPrefix("Read") && !$0.text.contains("Went through")},"passive template \(i): observed attribution only")
            check(try CanonicalGrounding.check(note,request:request,view:view)==note,"passive template \(i): exact code note accepted")
        }
        print("derived-history-notes: \(passed) passed, \(failed) failed")
        if failed>0 {exit(1)}
    }
}
