import Foundation
import Darwin
import CryptoKit
import MemoryCore

private final class Events {
    let lock=NSLock()
    var values=[SearchLaunchSnapshot]()
    let ready=DispatchSemaphore(value:0), fallback=DispatchSemaphore(value:0)
    func accept(_ value: SearchLaunchSnapshot) {
        lock.lock();values.append(value);lock.unlock()
        if value.phase == .ready {ready.signal()}
        if value.phase == .fallback {fallback.signal()}
    }
    func copy() -> [SearchLaunchSnapshot] {lock.lock();defer{lock.unlock()};return values}
}
@main struct SearchLaunchChecks {
    static var checks=0
    static func check(_ condition: @autoclosure () throws -> Bool,_ label:String) throws {
        guard try condition() else {throw NSError(domain:label,code:1)}
        checks += 1;print("PASS "+label)
    }
    static func query(_ launch:SyntheticSearchLaunch,_ text:String) throws -> MemorySearchResult {
        let done=DispatchSemaphore(value:0);var value:Result<MemorySearchResult,Error>?
        launch.search(MemorySearchQuery(text)) {value=$0;done.signal()}
        guard done.wait(timeout:.now()+3) == .success,let value else {throw SearchFailure.unavailable}
        return try value.get()
    }
    static func main() throws {
        // Bounded unresponsive executable fixture, never the real browser/app.
        if CommandLine.arguments.contains("--data-dir") {sleep(10);return}
        guard CommandLine.arguments.count == 2 else {fatalError("TEMP_TYPESENSE_BINARY required")}
        let binary=URL(fileURLWithPath:CommandLine.arguments[1])
        let hash=SHA256.hash(data:try Data(contentsOf:binary)).map{String(format:"%02x",$0)}.joined()
        let callbacks=DispatchQueue(label:"synthetic-test-events")
        let missing=try SyntheticSearchLaunch(),missingEvents=Events()
        try check(!missing.snapshot.canShowResults,"before launch results gate closed")
        let started=Date()
        try check(missing.begin(executable:nil,expectedSHA256:nil,callbackQueue:callbacks,onChange:missingEvents.accept),"missing runtime processed once")
        try check(Date().timeIntervalSince(started)<0.1,"begin does not block UI")
        try check(missing.snapshot.phase == .fallback && missing.snapshot.canShowResults,"missing runtime opens SQLite fallback immediately")
        try check(missing.snapshot.indexingLine == nil,"no indexing line for missing runtime")
        try check(try query(missing,"Garden").items.count==1,"fallback source data available without runtime")
        try check(!missing.begin(executable:binary,expectedSHA256:hash,callbackQueue:callbacks,onChange:{_ in}),"repeat begin cannot create duplicate child")
        missing.stop()

        let timeout=try SyntheticSearchLaunch(), timeoutEvents=Events()
        let own=URL(fileURLWithPath:CommandLine.arguments[0])
        let ownHash=SHA256.hash(data:try Data(contentsOf:own)).map{String(format:"%02x",$0)}.joined()
        let timeoutStart=Date()
        _=timeout.begin(executable:own,expectedSHA256:ownHash,budget:0.15,callbackQueue:callbacks,onChange:timeoutEvents.accept)
        try check(timeoutEvents.fallback.wait(timeout:.now()+1) == .success,"watchdog resolves unresponsive runtime within budget")
        try check(Date().timeIntervalSince(timeoutStart)<1,"no indefinite wait for child health")
        try check(timeout.snapshot.canShowResults && timeout.snapshot.indexingLine == nil,"timeout clears loading and indexing UI")
        try check(try query(timeout,"Garden").backend=="sqlite","timeout bypasses repeated index HTTP attempts")
        Thread.sleep(forTimeInterval:0.25)
        try check(!timeoutEvents.copy().contains{$0.phase == .ready},"late child cannot promote expired launch to ready")
        timeout.stop()

        let launch=try SyntheticSearchLaunch(),events=Events()
        for n in 0..<125 {
            _=try launch.preview.store.ingest(Evidence(id:"launch-\(n)",at:iso(Date()),kind:"window.changed",app:"Fixture",title:"Recent launch comet \(n)",synthetic:true))
        }
        let begin=Date()
        _=launch.begin(executable:binary,expectedSHA256:hash,budget:12,callbackQueue:callbacks,onChange:events.accept)
        try check(Date().timeIntervalSince(begin)<0.1,"real server startup is off UI thread")
        let recent=try query(launch,"comet")
        try check(recent.backend=="sqlite" && !recent.items.isEmpty,"recent actions searchable while initial runtime/index unavailable")
        try check(events.ready.wait(timeout:.now()+14) == .success,"bounded real launch completes authenticated indexing")
        let history=events.copy()
        try check(history.contains{$0.phase == .checking && !$0.canShowResults},"launch reports bounded health-check gate")
        try check(history.contains{$0.phase == .indexing && $0.canShowResults && $0.indexingLine == "Indexing…"},"initial multi-page index shows only small Indexing line")
        try check(launch.snapshot.phase == .ready && launch.snapshot.indexingLine == nil,"completed index hides initial line")
        let typo=try query(launch,"calibraton")
        try check(typo.backend=="typesense" && typo.items.first?.id=="typesense-preview-0","ready queries use actual Typesense typo ranking")
        try check(try launch.preview.store.status()["capture"]=="off","startup never enables recording")
        launch.preview.stop() // only our owned synthetic server
        try check(try query(launch,"comet").backend=="sqlite","disconnect recovers to source search")
        try check(launch.snapshot.phase == .fallback && launch.snapshot.indexingLine == nil,"disconnect has quiet fallback not permanent Indexing")
        launch.stop();launch.stop()
        callbacks.sync{}
        try check(launch.snapshot.phase == .stopped,"stop and repeated stop keep terminal status")
        var refused=false;do {_=try query(launch,"comet")}catch{refused=true}
        try check(refused,"closed preview cannot return late source results")
        try check(!launch.begin(executable:binary,expectedSHA256:hash,callbackQueue:callbacks,onChange:{_ in}),"stopped controller cannot silently relaunch")
        print("\(checks) launch checks passed; synthetic stores/owned loopback child only")
    }
}
