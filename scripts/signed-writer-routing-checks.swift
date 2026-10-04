import Foundation
import SwiftUI

// Compile the actual launch router with inert dependencies. No stores, keys,
// model inference or capture are available in this executable.
@MainActor final class MemoryViewModel {
    static var constructions=0
    init(development:DevelopmentTrial?=nil,recordingTrial:Bool=false,functionalTrial:Bool=false) {Self.constructions+=1}
}
struct DevelopmentTrial {
    static func validate()throws->Self {Self()}
    func prepare()throws {fatalError("Signed entry must precede development preparation")}
}
@MainActor enum SignedWriterTrial {
    static func requested(arguments:[String])->Bool {arguments.contains("--signed-writer-acceptance")}
}
@main struct RoutingChecks {
    @MainActor static func main() {
        let acceptance=DaydreamLaunchSession(arguments:["test","--signed-writer-acceptance"])
        precondition(acceptance.signedWriterAcceptance && acceptance.model == nil && acceptance.failure == nil)
        let mixed=DaydreamLaunchSession(arguments:["test","--signed-writer-acceptance","--development-trial"])
        precondition(!mixed.signedWriterAcceptance && mixed.model == nil && mixed.failure != nil)
        let recording=DaydreamLaunchSession(arguments:["test","--signed-writer-acceptance","--recording-trial","--functional-trial"])
        precondition(recording.signedWriterAcceptance && recording.model == nil)
        let isolated=DaydreamLaunchSession(arguments:["test","--isolated-interactive-trial"])
        precondition(isolated.model == nil && !isolated.signedWriterAcceptance)
        precondition(MemoryViewModel.constructions == 0)
        let normal=DaydreamLaunchSession(arguments:["test"])
        precondition(normal.model != nil && !normal.signedWriterAcceptance && MemoryViewModel.constructions == 1)
        print("PASS 6 actual launch-router checks with inert model dependencies; no inference or stores")
    }
}
