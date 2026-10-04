#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
import Foundation

enum NotesActivationError: String, Error {
    case arguments, path, declaration, identity, process, signature, permission,
         secureInput, deadline, foreground, activation, menu, ambiguous, command,
         reference, disabled, action, transport, type
}
enum NotesActivationContract {
    static let flag = "--prepare-notes-new"
    static let prefix = "/private/tmp/daydream-notes-activation-"
    static let appPath = "/System/Applications/Notes.app"
    static let executablePath = appPath + "/Contents/MacOS/Notes"
    static let bundle = "com.apple.Notes"
    // English-only, fixed top-level position; never search arbitrary titles.
    static let filePosition = 2
    static let newPosition = 0
    enum Action: String { case activate, newNote = "new-note", inspectMenu = "inspect-menu" }
    struct Configuration {
        let root: String, pid: Int32, start: Double, seconds: Double, action: Action
        var declaration: String { "notes-activation-fixed-command-v1|" + action.rawValue + "\n" }
        static func parse(_ a: [String]) throws -> Self {
            guard a.count == 12, a[1] == flag else { throw NotesActivationError.arguments }
            var o: [String:String] = [:]
            for i in stride(from:2,to:a.count,by:2) {
                guard ["--work-root","--expected-pid","--expected-start","--seconds","--action"].contains(a[i]),o[a[i]] == nil else {throw NotesActivationError.arguments}
                o[a[i]] = a[i+1]
            }
            guard let root=o["--work-root"],root.hasPrefix(prefix),let nonce=UUID(uuidString:String(root.dropFirst(prefix.count))),root == prefix+nonce.uuidString,
                  let pid=o["--expected-pid"].flatMap(Int32.init),pid>0,
                  let start=o["--expected-start"].flatMap(Double.init),start.isFinite,start>0,
                  let seconds=o["--seconds"].flatMap(Double.init),seconds.isFinite,(2...10).contains(seconds),
                  let action=o["--action"].flatMap(Action.init(rawValue:)) else {throw NotesActivationError.arguments}
            return Self(root:root,pid:pid,start:start,seconds:seconds,action:action)
        }
    }
    static func identity(pid:Int32,start:Double,path:String?,bundle:String?,currentPID:Int32,currentStart:Double?) -> Bool {
        pid>0 && start.isFinite && start>0 && currentPID==pid && currentStart==start && path==executablePath && bundle==self.bundle
    }
    static func foreground(expected:Int32,actual:Int32?) -> Bool {expected>0 && actual==expected}
    static func focused(expected:Int32,workspace:Int32?,system:Int32?) -> Bool {foreground(expected:expected,actual:workspace) && foreground(expected:expected,actual:system)}
    static func candidatePosition(_ i:Int) -> Bool {i == newPosition}
    static func references<Node>(_ original:[Node],_ current:[Node],equal:(Node,Node)->Bool) -> Bool {original.count==4 && current.count==4 && zip(original,current).allSatisfy(equal)}
    static func command(character:String?,modifiers:Int?) -> Bool {character == "n" && modifiers == 0}
    static func unique(_ candidates:[Int]) throws -> Int {
        guard candidates.count==1,let first=candidates.first else {throw NotesActivationError.ambiguous};return first
    }
    static func staticFile(role:String?,title:String?,position:Int) -> Bool {position==filePosition && role=="AXMenuBarItem" && title=="File"}
    static func staticNew(role:String?,title:String?,character:String?,modifiers:Int?,enabled:Bool,press:Bool) -> Bool {
        role=="AXMenuItem" && title=="New Note" && command(character:character,modifiers:modifiers) && enabled && press
    }
    // Fixed metadata only. No raw command character, modifier, title or node identifier.
    enum MenuScan: String { case first, second }
    enum CandidateCount: String { case zero = "0", one = "1", many }
    enum MenuFailure: String { case owner, role }
    struct CommandBuckets {
        private(set) var upperCommand=0,lowerOtherModifiers=0
        mutating func observe(character:String?,modifiers:Int?) {
            if character == "N" && modifiers == 0 {upperCommand += 1}
            // Documented Shift/Option/Control/NoCommand mask combinations only.
            if character == "n", let modifiers, (1...15).contains(modifiers) {lowerOtherModifiers += 1}
        }
    }
    struct MenuObservation {
        let scan: MenuScan
        private(set) var candidateCount: CandidateCount?
        var failure: MenuFailure?
        private(set) var commandBuckets: CommandBuckets?
        mutating func countedCommands(_ buckets:CommandBuckets) {commandBuckets=buckets}
        mutating func counted(_ count: Int) {
            precondition(count >= 0)
            candidateCount = count == 0 ? .zero : (count == 1 ? .one : .many)
        }
        var fields: [String:String] {
            var result = ["menuScan":scan.rawValue]
            if let candidateCount { result["candidateCountBucket"] = candidateCount.rawValue }
            if let commandBuckets {
                func bucket(_ value:Int) -> String {value == 0 ? "0" : (value == 1 ? "1" : "many")}
                result["upperNCommandBucket"]=bucket(commandBuckets.upperCommand)
                result["lowerNOtherModifiersBucket"]=bucket(commandBuckets.lowerOtherModifiers)
            }
            if let failure { result["menuFailure"] = failure.rawValue }
            return result
        }
    }
    struct Deadline {
        let began:UInt64,limit:UInt64
        func accepts(_ now:UInt64) -> Bool {now>=began && now-began<=limit}
    }
}
#endif
