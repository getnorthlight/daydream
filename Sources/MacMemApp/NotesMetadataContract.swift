#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
import Foundation

enum NotesMetadataError: String, Error {
    case arguments, path, declaration, ticket, identity, permission, deadline, clock,
         process, proof, window, field, bounds, foreignWindow, multipleWindows, empty,
         title, characters, attribute, changed, closure, receipt
}
enum NotesMetadataContract {
    static let flag = "--inspect-notes-metadata"
    static let declaration = "notes-metadata-only-new-note-v1\n"
    static let prefix = "/private/tmp/daydream-notes-metadata-"
    enum Phase: String { case empty, firstLine = "uuid-first-line" }
    struct Configuration {
        let root: String, nonce: UUID, pid: Int32, seconds: Double, phase: Phase
        var title: String { "DayDream QA Notes " + nonce.uuidString }
        var ticket: String { "cua-created-new-owned-note-v1|" + nonce.uuidString + "|" + phase.rawValue + "\n" }
        static func parse(_ args: [String]) throws -> Configuration {
            guard args.count == 10, args[1] == flag, args.filter({$0 == flag}).count == 1 else {throw NotesMetadataError.arguments}
            var o: [String:String] = [:]
            for i in stride(from:2,to:args.count,by:2) {
                guard ["--work-root","--expected-pid","--seconds","--phase"].contains(args[i]),o[args[i]] == nil else {throw NotesMetadataError.arguments}
                o[args[i]]=args[i+1]
            }
            guard let root=o["--work-root"],root.hasPrefix(prefix),!root.contains("\0"),
                  let nonce=UUID(uuidString:String(root.dropFirst(prefix.count))),
                  root == prefix + nonce.uuidString,
                  let pid=o["--expected-pid"].flatMap(Int32.init),pid>0,
                  let seconds=o["--seconds"].flatMap(Double.init),seconds.isFinite,(30...90).contains(seconds),
                  let phase=o["--phase"].flatMap(Phase.init(rawValue:)) else {throw NotesMetadataError.arguments}
            return Configuration(root:root,nonce:nonce,pid:pid,seconds:seconds,phase:phase)
        }
    }
    struct Frame: Equatable {
        let x: Double, y: Double, width: Double, height: Double
        var valid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && width>0 && height>0 && width<=16384 && height<=16384 }
        func matches(_ b: Frame) -> Bool {valid && b.valid && abs(x-b.x)<=1 && abs(y-b.y)<=1 && abs(width-b.width)<=1 && abs(height-b.height)<=1}
    }
    struct Window { let id: Int, frame: Frame }
    static func ownedWindow(_ frame: Frame, windows: [Window], baseline: Set<Int>) throws -> Int {
        guard frame.valid else {throw NotesMetadataError.bounds}
        let matching=windows.filter{$0.frame.matches(frame)}
        guard matching.count<=1 else {throw NotesMetadataError.multipleWindows}
        guard let row=matching.first,row.id>0,!baseline.contains(row.id) else {throw NotesMetadataError.foreignWindow}
        return row.id
    }
    static func freshTicket(modified: Double, now: Double, armed: Double) -> Bool {
        modified.isFinite && now.isFinite && armed.isFinite && modified>=armed && now>=modified && now-modified<=2
    }
    struct Budget {
        let began: UInt64, limit: UInt64
        func accepts(_ now: UInt64) -> Bool {now>=began && now-began<=limit}
    }
    enum Attribute: Equatable {
        case text(String), unsupported, absent, transport, wrongType, oversized
        var status: String {
            switch self {case .text:return "success";case .unsupported:return "unsupported";case .absent:return "absent";case .transport:return "transport";case .wrongType:return "wrong-type";case .oversized:return "oversized"}
        }
        var text: String? {if case .text(let v)=self{return v};return nil}
        var safeDiagnostic: Bool {self == .unsupported || self == .absent || text != nil}
        var uri: Bool {
            guard let value=text,!value.isEmpty,value.utf8.count<=4096,
                  !value.unicodeScalars.contains(where:CharacterSet.whitespacesAndNewlines.contains),
                  let u=URL(string:value),let scheme=u.scheme,!scheme.isEmpty else{return false}
            return true // Syntax only; NEVER note identity or input authority.
        }
    }
    // The generic native proof also admits AXTextField (e.g. Notes search). This diagnostic does not.
    static func editorRole(_ value:String?) -> Bool { value == "AXTextArea" }
    static func characters(_ value: Int?, phase: Phase, title: String) -> Bool {
        guard let value,value>=0 else{return false}
        return value == (phase == .empty ? 0 : title.utf16.count)
    }
    static func stable(_ a:[Attribute],_ b:[Attribute]) -> Bool {a.count==4 && a==b && a.allSatisfy(\.safeDiagnostic)}
    static func referencesHeld<Node>(window:Node,editor:Node,currentWindow:Node,currentEditor:Node,equal:(Node,Node)->Bool)->Bool {
        equal(window,currentWindow) && equal(editor,currentEditor)
    }
    // Explicitly no method that promotes widget/URI syntax to note identity or typing authority.
}
#endif
