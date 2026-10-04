import Foundation
import Darwin

public struct LegacyLauncher: Codable, Equatable {
    public var label: String
    public var plist: String
    public var executable: String
    public var historyHome: String
    public init(label:String,plist:String,executable:String,historyHome:String) { self.label=label; self.plist=plist; self.executable=executable; self.historyHome=historyHome }
    public func validate(macMemHome: URL) throws {
        let oldHome = URL(fileURLWithPath:historyHome).resolvingSymlinksInPath().standardizedFileURL.path
        let newHome = macMemHome.resolvingSymlinksInPath().standardizedFileURL.path
        guard label.range(of:"^[A-Za-z0-9][A-Za-z0-9._-]+$",options:.regularExpression) != nil,
              [plist,executable,historyHome].allSatisfy({ $0.hasPrefix("/") }),
              oldHome != newHome, !oldHome.hasPrefix(newHome+"/"), !newHome.hasPrefix(oldHome+"/"),
              let size = try FileManager.default.attributesOfItem(atPath:plist)[.size] as? NSNumber, size.intValue <= 65536 else { throw MemError.invalid("Explicit, separate launcher and memory paths required") }
        let data = try Data(contentsOf:URL(fileURLWithPath:plist))
        guard data.count <= 65536, let manifest = try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],
              manifest["Label"] as? String == label,
              ((manifest["Program"] as? String) ?? (manifest["ProgramArguments"] as? [String])?.first) == executable else { throw MemError.invalid("Launcher manifest does not match explicit configuration") }
    }
}
public struct LauncherState: Codable, Equatable {
    public var loaded: Bool
    public var disabled: Bool
    public init(loaded:Bool,disabled:Bool) { self.loaded=loaded; self.disabled=disabled }
}
public protocol LauncherControl {
    func inspect(_ launcher: LegacyLauncher) throws -> LauncherState
    func stopAndDisable(_ launcher: LegacyLauncher) throws
    func restore(_ launcher: LegacyLauncher, previous: LauncherState) throws
}
public struct SwitchRecord: Codable {
    public var launcher: LegacyLauncher
    public var previous: LauncherState
    public var phase: String
    public var beganAt: String
    public var consumerReceipts:[ConsumerVerificationReceipt]? = nil
}

/// Two explicit actions: prepare replacement stops ONLY the configured legacy
/// service; the app's separate Start button enables new capture. Commit requires
/// a new observation. Interrupted transitions never auto-start either recorder.
public final class Switchover {
    private let store: MemoryStore
    private let control: LauncherControl
    private let probes:[any ReplacementConsumerProbe]
    private let requiredConsumers:[String]
    public init(store:MemoryStore,control:LauncherControl,probes:[any ReplacementConsumerProbe]=[],requiredConsumers:[String]=[]) {
        self.store=store; self.control=control; self.probes=probes; self.requiredConsumers=requiredConsumers
    }
    public func record() throws -> SwitchRecord? {
        try store.rows("SELECT body FROM metadata WHERE id='switchover'").first?.first.map { try decode(SwitchRecord.self,$0) }
    }
    private func save(_ record:SwitchRecord) throws { try store.exec("INSERT OR REPLACE INTO metadata VALUES('switchover',?)",[json(record)]) }
    private func lockOperation() throws -> Int32 {
        let fd = open(store.home.appendingPathComponent("switchover.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw MemError.invalid("Cannot lock replacement") }
        guard flock(fd,LOCK_EX|LOCK_NB) == 0 else { close(fd); throw MemError.invalid("Replacement already in progress") }
        return fd
    }
    public func prepare(_ launcher:LegacyLauncher, approved:Bool, compatibilityReady:Bool, now:Date=Date()) throws {
        guard approved, compatibilityReady else { throw MemError.denied }
        let fd = try lockOperation(); defer { flock(fd,LOCK_UN); close(fd) }
        try launcher.validate(macMemHome:store.home)
        guard try record().map({ ["rolled_back"].contains($0.phase) }) ?? true else { throw MemError.invalid("Resolve existing switchover first") }
        let receipts=try store.verifyReplacementConsumers(probes,required:requiredConsumers,now:now)
        let previous = try control.inspect(launcher)
        var next = SwitchRecord(launcher:launcher,previous:previous,phase:"stopping_legacy",beganAt:iso(now))
        next.consumerReceipts=receipts
        try save(next) // Durable intent BEFORE changing a service.
        do {
            try control.stopAndDisable(launcher)
            let stopped = try control.inspect(launcher)
            guard !stopped.loaded, stopped.disabled else { throw MemError.invalid("Legacy stop not verified") }
            next.phase="awaiting_explicit_start"; try save(next)
        } catch {
            do {
                try control.restore(launcher,previous:previous)
                guard try control.inspect(launcher) == previous else { throw MemError.invalid("Rollback not verified") }
                next.phase="rolled_back"; try save(next)
            }
            catch { next.phase="rollback_required"; try? save(next) }
            throw MemError.invalid("Switch failed; inspect rollback state before proceeding")
        }
    }
    public func permitsStart() throws -> Bool {
        guard let state=try record(), ["awaiting_explicit_start","committed"].contains(state.phase) else { return false }
        try state.launcher.validate(macMemHome:store.home)
        let legacy=try control.inspect(state.launcher)
        return !legacy.loaded && legacy.disabled
    }
    public func commit(now:Date=Date()) throws {
        let fd = try lockOperation(); defer { flock(fd,LOCK_UN); close(fd) }
        guard var state=try record(), state.phase == "awaiting_explicit_start", try permitsStart() else { throw MemError.denied }
        let health=try store.status()
        guard health["capture"] == "recording", let observed=timestamp(health["observed_at"] ?? ""),
              observed >= (timestamp(state.beganAt) ?? now), (0...30).contains(now.timeIntervalSince(observed)) else { throw MemError.invalid("Await a new accepted observation before commit") }
        guard Set(state.consumerReceipts?.map(\.identity) ?? []) == Set(requiredConsumers) else { throw MemError.invalid("Configured consumer routes changed; reverify replacement") }
        state.consumerReceipts=try store.verifyReplacementConsumers(probes,required:requiredConsumers,now:now)
        state.phase="committed"; try save(state)
    }
    public func rollback(approved:Bool, stopNew:() throws -> Void, newIsStopped:() throws -> Bool) throws {
        let fd = try lockOperation(); defer { flock(fd,LOCK_UN); close(fd) }
        guard approved, var state=try record() else { throw MemError.denied }
        if state.phase == "rolled_back" { return }
        try stopNew()
        guard try newIsStopped() else { throw MemError.invalid("New recorder still active; legacy will not be restarted") }
        state.phase="restoring_legacy"; try save(state)
        do {
            try control.restore(state.launcher,previous:state.previous)
            guard try control.inspect(state.launcher) == state.previous else { throw MemError.invalid("Rollback health mismatch") }
            state.phase="rolled_back"; try save(state)
        } catch { state.phase="rollback_required"; try? save(state); throw error }
    }
}
