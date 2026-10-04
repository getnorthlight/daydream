#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
import Foundation
import MemoryCore

// Pure controls for the metadata-only QA route. Never establishes draft ownership.
enum ChromeFrontInspectionControls {
    /// Owner-declared Google draft diagnostics only. This never grants capture
    /// or posted-input authority on Google.
    static let draftOrigins:Set<String>=["https://google.com","https://www.google.com"]
    static func allowsDraftInspection(origin:String,mode:String?) -> Bool {
        mode == "preflight" && draftOrigins.contains(origin)
    }
    static let mode = "inspect-front"
    static let declaration = "chrome-front-metadata-v1\n"
    struct Request: Equatable {
        let root: String
        let pid: Int32
        let seconds: Double
    }
    static func request(_ options: [String: String]) -> Request? {
        let required: Set<String> = ["--fixture", "--mode", "--work-root", "--expected-pid"]
        let permitted = required.union(["--seconds"])
        let supplied = Set(options.keys)
        guard required.isSubset(of: supplied), supplied.isSubset(of: permitted),
              options["--fixture"] == "chrome", options["--mode"] == mode,
              let root = options["--work-root"], !root.isEmpty, !root.contains("\0"),
              let pidText = options["--expected-pid"], !pidText.isEmpty,
              pidText.utf8.allSatisfy({ (48...57).contains($0) }),
              let pid = Int32(pidText), pid > 0,
              let seconds = Double(options["--seconds"] ?? "3"),
              seconds.isFinite, (1...4).contains(seconds) else { return nil }
        return Request(root: root, pid: pid, seconds: seconds)
    }

    // QA compares AE integer geometry with AX geometry exactly as production does.
    // Retain only fixed metadata; never retain coordinates in a diagnostic record.
    struct GeometryComparison: Equatable {
        let valid: Bool
        let positionEqual: Bool
        let sizeEqual: Bool
        let exactMatch: Bool
        let productionMatch: Bool
    }
    static func compareGeometry(_ ae: ChromeBounds, _ ax: ChromeBounds) -> GeometryComparison {
        let valid = ae.valid && ax.valid
        return GeometryComparison(valid: valid,
            positionEqual: valid && ae.left == ax.left && ae.top == ax.top,
            sizeEqual: valid && ae.right-ae.left == ax.right-ax.left && ae.bottom-ae.top == ax.bottom-ax.top,
            exactMatch: valid && ae == ax,
            productionMatch: valid && ae.matches(ax))
    }
    enum GeometryScan: String { case initial, final }
    enum MatchCardinality: String {
        case zero, one, ambiguous
        init(_ count: Int) { self = count == 0 ? .zero : count == 1 ? .one : .ambiguous }
    }
    enum GeometryRecord {
        case candidate(GeometryScan, Int, GeometryComparison)
        case summary(GeometryScan, Int, Int)
        var receipt: [String: Any] {
            switch self {
            case .candidate(let scan, let ordinal, let comparison):
                return ["phase":"qa-window-geometry", "scan":scan.rawValue, "candidateOrdinal":ordinal,
                        "valid":comparison.valid, "positionEqual":comparison.positionEqual,
                        "sizeEqual":comparison.sizeEqual, "exactMatch":comparison.exactMatch,
                        "productionMatch":comparison.productionMatch]
            case .summary(let scan, let exact, let production):
                return ["phase":"qa-window-mapping", "scan":scan.rawValue,
                        "exactMatchCount":exact, "productionMatchCount":production,
                        "exactCardinality":MatchCardinality(exact).rawValue,
                        "productionCardinality":MatchCardinality(production).rawValue]
            }
        }
    }
    // Two scans of at most 64 windows and two summaries. No logging or closures
    // while scanning; caller emits only after the route exits its read fences.
    final class GeometryBuffer {
        private var records: [GeometryRecord] = []
        private(set) var truncated = false
        init() { records.reserveCapacity(130) }
        func record(_ record: GeometryRecord) {
            guard records.count < 130 else { truncated = true; return }
            records.append(record)
        }
        func drain() -> [GeometryRecord] {
            let result = records
            records.removeAll(keepingCapacity: true)
            return result
        }
    }
    static func uniqueWindowID(_ matches: [String]) -> String? {
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}

#endif
