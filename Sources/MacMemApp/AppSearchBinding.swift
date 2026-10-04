import Foundation
import MemoryCore

/// Retains exactly one production controller. Development must not construct it.
final class AppSearchBinding {
    private let launch:ProductionSearchLaunch
    init(store:MemoryStore) {launch=ProductionSearchLaunch(store:store)}
    var snapshot:ProductionSearchState {launch.snapshot}
    func begin(bundle:URL,onChange:@escaping(ProductionSearchState)->Void) {
        DispatchQueue.global(qos:.utility).async { [launch] in
            let runtime=try? LocalSearchRuntime.bundled(in:bundle)
            launch.begin(runtime:runtime,callbackQueue:.main,onChange:onChange)
        }
    }
    func search(_ query:MemorySearchQuery) async throws -> MemorySearchResult {
        try await withCheckedThrowingContinuation { continuation in
            launch.search(query) {continuation.resume(with:$0)}
        }
    }
    func stop() {launch.stop()}
    deinit {launch.stop()}
}
