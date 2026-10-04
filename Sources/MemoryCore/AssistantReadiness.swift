import Foundation
import PrivacyPolicy

/// fix/welcome-prompt: the setup check an AI app reads in `status` (MCP), so it can answer the connection starter
/// ("Explain what DayDream does ... Check that DayDream is connected and ready to use ... three example questions")
/// truthfully. Read only. Metadata only: it says what is switched on and whether typing was saved lately (a time),
/// never typed words, titles, sites or web addresses. A new install with nothing recorded yet reads as ready.

/// Whether this AI app's connection works: its grant, checked with the key it started the server with.
public enum AssistantAccess: Equatable, Sendable {
    /// Every scope an AI app's connection gets (`assistantScopes`) works with this key.
    case connected
    /// Some scopes work, these don't.
    case partial([String])
    /// A connection is on record for this app, but the key it sent doesn't match it (the connection was renewed,
    /// or the history was replaced).
    case keyStopped
    /// No connection for this app (never connected, disconnected, or turned off by a change that records more).
    case missing
}

extension MemoryStore {
    /// The scopes Connect grants (`AIAppConnect`, `mac-mem grant`).
    public static let assistantScopes = ["context", "search", "detail"]
    /// How long ago saved typing still counts as "typing verified".
    public static let typingVerifiedWindow: TimeInterval = 24 * 3600

    /// Checks each scope the way every other tool call does (`authorize`); throws nothing.
    public func assistantAccess(client: String, recipient: String, capability: String) -> AssistantAccess {
        let failing = Self.assistantScopes.filter { scope in
            (try? authorize(client: client, recipient: recipient, capability: capability, scope: scope)) == nil
        }
        if failing.isEmpty { return .connected }
        if failing.count < Self.assistantScopes.count { return .partial(failing) }
        let onRecord = !client.isEmpty && !recipient.isEmpty
            && ((try? rows("SELECT 1 FROM grants WHERE id=?", [client + "\u{1f}" + recipient]))?.isEmpty == false)
        return onRecord && !capability.isEmpty ? .keyStopped : .missing
    }

    /// When DayDream last saved typing (time only), within `typingVerifiedWindow`, counting only rows every other read
    /// may show (not deleted, not hidden by an exclusion). Bounded by the time index; reads no words.
    func lastSavedTyping(now: Date) throws -> String? {
        let jd = Self.dayTime
        let recent = try rows("SELECT id,json_extract(body,'$.at') FROM records WHERE \(jd)>=julianday(?) AND \(jd)<=julianday(?) AND json_extract(body,'$.kind')='keyboard.text_input' ORDER BY \(jd) DESC LIMIT 20",
                              [iso(now.addingTimeInterval(-Self.typingVerifiedWindow)), iso(now.addingTimeInterval(60))])
        for row in recent where row.count == 2 {
            if try permittedOriginal(row[0], now: now) != nil { return row[1] }
        }
        return nil
    }

    /// The setup fields `assistantStatus` adds. `access` is nil where no AI app's key is at hand (then nothing is said
    /// about a connection).
    public func assistantReadiness(access: AssistantAccess?, now: Date = Date()) throws -> [String:String] {
        let zone = TimeZone.current
        let state = try captureStatus(now: now)["state"] ?? "off"
        let saved = try policy(), typed = try typedTextPolicy()
        let empty = try latestActionAt(now: now) == nil
        var result: [String:String] = [:]

        // Connection.
        var connectionProblem: String?
        switch access {
        case nil: break
        case .connected?:
            result["connected"] = "yes: this AI app's DayDream connection works, so it can use every DayDream tool."
        case .partial(let missing)?:
            connectionProblem = "this AI app's DayDream connection is missing access (\(missing.joined(separator: ", "))). Reconnecting it in DayDream Settings › Connections fixes it."
        case .keyStopped?:
            connectionProblem = "this AI app's DayDream key no longer works (for example after a change in Apps to remember, or after the history was replaced). Reconnecting it in DayDream Settings › Connections gives it a new one; until then only status works."
        case .missing?:
            connectionProblem = "this AI app isn't connected to DayDream (or its connection was turned off). Connecting it in DayDream Settings › Connections fixes it; until then only status works."
        }
        if let connectionProblem { result["connected"] = "no: " + connectionProblem }

        // Typing: switched on is not the same as working; only a saved typing row verifies it.
        var verified = false
        if !saved.typingOn {
            result["typing"] = "off: DayDream isn't saving typing. The person can turn typed text on in DayDream Settings › Apps to remember."
        } else if !typed.consented {
            result["typing"] = "switched on but not active yet: the person needs to finish turning typed text on in DayDream (Settings › Apps to remember)."
        } else if typed.snoozed(now: now) {
            let until = timestamp(typed.snoozeUntil).map { " until " + AssistantView.when(iso($0), zone: zone) } ?? ""
            result["typing"] = "paused\(until): typing isn't saved until then; other activity still is."
        } else if let last = try lastSavedTyping(now: now) {
            verified = true
            result["typing"] = "on and working: DayDream last saved typing \(AssistantView.when(last, zone: zone)) (AI apps get where and about how much, never the words)."
        } else {
            result["typing"] = "switched on, not confirmed yet: DayDream hasn't saved any typing in the last 24 hours. It's confirmed once the person types in an app where typed text is recorded while recording is on."
        }
        result["typing_verified"] = verified ? "yes" : "no"

        // Chrome pages.
        if !ReleaseFeatures.chromePageHistory {
            result["chrome_pages"] = "not in this version: web browsers aren't recorded."
        } else if saved.browserPagesOn {
            result["chrome_pages"] = "on: DayDream saves the title and site of pages in Google Chrome (no other browser). If none show up, the person can press Allow… under Web pages in Chrome in DayDream Settings › Apps to remember."
        } else {
            result["chrome_pages"] = "off: web pages aren't recorded. The person can turn on Web pages in Chrome in DayDream Settings › Apps to remember."
        }

        // Summaries (the app's last reported setting).
        let writer = try summaryWriter()?.mode
        switch writer {
        case "local": result["summaries"] = "on this Mac: DayDream writes short notes about each moment on this Mac; nothing is sent to write them."
        case "cloud": result["summaries"] = "cloud: DayDream sends activity through OpenRouter to write short notes about each moment (see cloud_summaries)."
        case "off": result["summaries"] = "off: no notes are written; moments still show apps, windows and times. The person can turn summaries on in DayDream Settings › Summarizer."
        default: result["summaries"] = "unknown: DayDream hasn't reported its summary setting yet."
        }

        // The one line to read first.
        let nothingYet = " Nothing has been recorded yet, which is normal right after setup: activity appears as the person uses the Mac."
        let lead = access == nil ? "" : "Connected, but "
        if let connectionProblem {
            result["setup"] = "Not ready: " + connectionProblem
        } else {
            switch state {
            case "recording":
                result["setup"] = (access == nil ? "Ready: DayDream is recording." : "Ready: DayDream is connected and recording.") + (empty ? nothingYet : "")
            case "paused":
                result["setup"] = lead + (lead.isEmpty ? "R" : "r") + "ecording is paused: nothing new is saved until the person chooses Resume Now from DayDream in the menu bar. Earlier activity can still be read."
            case "unavailable":
                result["setup"] = lead + (lead.isEmpty ? "D" : "d") + "ayDream's recorder isn't responding (DayDream may be closed, or the Mac was asleep). Opening DayDream starts recording again if it was on."
            case "permission_denied":
                result["setup"] = lead + (lead.isEmpty ? "R" : "r") + "ecording is off because a macOS permission is missing. The person can choose Turn on Accessibility or Turn on Input Monitoring from DayDream in the menu bar."
            case "error":
                result["setup"] = lead + (lead.isEmpty ? "R" : "r") + "ecording stopped after a storage problem. DayDream in the menu bar says what to do."
            default:
                result["setup"] = lead + (lead.isEmpty ? "R" : "r") + "ecording is off. The person can turn DayDream on in the menu bar."
            }
            if state != "recording" && empty { result["setup"]! += " Nothing has been recorded yet." }
        }

        // Example questions that fit what is on now, each answered by a tool that exists.
        let notesOn = writer == "local" || writer == "cloud"
        var examples = ["What did I work on yesterday?", "Where did I leave off on [a project or file]?", "When did I last have [a document] open?",
                        "Draft my standup from yesterday."]
        if ReleaseFeatures.chromePageHistory && saved.browserPagesOn { examples.append("What was that page I had open in Chrome about [a topic]?") }
        if notesOn { examples.append("What did I do this week?") }
        if notesOn && saved.typingOn { examples.append("What did I ask an AI app about [a topic]?") }
        result["examples"] = examples.joined(separator: " | ") + (empty ? " (These work once there is some activity.)" : "")
        return result
    }
}
