import SwiftUI

// Compile the actual launch selector with a sentinel model. No store or app runs.
@MainActor final class MemoryViewModel {
    static var initializations=0
    init(development:DevelopmentTrial?=nil) {Self.initializations+=1}
}
struct DevelopmentTrial {
    static func validate() throws -> Self {throw CocoaError(.fileReadNoSuchFile)}
    func prepare() throws {}
}
@main struct EntryChecks {
    @MainActor static func main() {
        let first=DaydreamLaunchSession(arguments:["Daydream","--isolated-interactive-trial"])
        precondition(first.isolated && first.model==nil && MemoryViewModel.initializations==0)
        let second=DaydreamLaunchSession(arguments:["Daydream","--isolated-interactive-trial"])
        precondition(second.model==nil && MemoryViewModel.initializations==0)
        let denied=DaydreamLaunchSession(arguments:["Daydream","--development-trial"])
        precondition(denied.model==nil && denied.failure != nil && MemoryViewModel.initializations==0)
        let ordinary=DaydreamLaunchSession(arguments:["Daydream"])
        precondition(!ordinary.isolated && ordinary.model != nil && MemoryViewModel.initializations==1)
        print("PASS isolated first launch and relaunch never construct memory model; ordinary launch unchanged")
    }
}
