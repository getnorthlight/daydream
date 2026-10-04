import Foundation

/// The JSON report written with --report. It is built only from the Codable
/// step results, which hold no page titles, full URLs, field labels or typed
/// text; window names are reduced to their length.
public struct RunReport: Codable {
    public var harness = Harness.version
    public var createdAt: String
    public var macOS: String
    public var facts: RunFacts
    public var steps: [StepResult]
    public var criteria: [CriterionResult]
    public var overall: String

    public init(macOS: String, facts: RunFacts, steps: [StepResult], now: Date = Date()) {
        let f = ISO8601DateFormatter()
        createdAt = f.string(from: now)
        self.macOS = macOS
        self.facts = facts
        self.steps = steps.map(RunReport.scrub)
        let byID = Dictionary(steps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        criteria = Criteria.grade(byID, facts)
        overall = Criteria.overall(criteria)
    }

    static func scrub(_ s: StepResult) -> StepResult {
        var s = s
        s.windows = s.windows?.map { w in
            var w = w
            w.name = w.name.map { "(\($0.count) characters)" }
            return w
        }
        return s
    }

    public func json() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}

public enum Table {
    /// Fixed-width PASS/FAIL table for the terminal.
    public static func render(_ c: [CriterionResult], width: Int = 100) -> String {
        var lines: [String] = []
        let head = pad("ID", 4) + pad("Kind", 8) + pad("Result", 8) + "Criterion"
        lines.append(head)
        lines.append(String(repeating: "-", count: min(width, 100)))
        for r in c {
            lines.append(pad(r.id, 4) + pad(r.severity.rawValue, 8) + pad(r.grade.rawValue, 8) + r.title)
            lines.append(String(repeating: " ", count: 20) + "- " + r.evidence)
        }
        return lines.joined(separator: "\n")
    }
    static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count) }
}
