import Foundation
import IOKit.ps

/// fix/sx-engine-battery, fix/battery-summaries (owner 9/28: "it should write summaries when I am on battery"): when the
/// model on this Mac may run.
/// - Background work (moment notes, levels, catch-up): on power or on battery, in the same batches, unless Low Power
///   Mode is on, the battery is under 20%, or the Mac is hot (thermal serious or worse).
/// - An AI app's request (on demand): unless Low Power Mode is on or the battery is under 20% (it may run while the Mac
///   is warm, not while it is critical).
/// While background work waits, level notes are written by code instead, and what waited is written once it may run
/// again: plugged in, Low Power Mode off, the battery back to 20% or the Mac cooler (`Observation` reports the change).
struct ModelPower: Equatable, Sendable {
    var onPower:Bool
    var lowPowerMode:Bool
    /// ProcessInfo.ThermalState raw value (0 nominal ... 3 critical).
    var thermal:Int
    /// Battery charge in percent; nil without a battery.
    var battery:Int?
    static let ac=ModelPower(onPower:true,lowPowerMode:false,thermal:0,battery:nil)
    static let battery=ModelPower(onPower:false,lowPowerMode:false,thermal:0,battery:80)
    var allowsBackground:Bool {!lowPowerMode && (onPower || (battery ?? 100) >= 20) && thermal < ProcessInfo.ThermalState.serious.rawValue}
    var allowsOnDemand:Bool {!lowPowerMode && (onPower || (battery ?? 100) >= 20) && thermal < ProcessInfo.ThermalState.critical.rawValue}
    /// fix/perf7: what the writer's choices depend on (not the exact battery percent).
    var decision:ModelPower {ModelPower(onPower:onPower,lowPowerMode:lowPowerMode,thermal:thermal,battery:battery.map {$0 >= 20 ? 100 : 0})}

    static func current() -> ModelPower {
        var power=ModelPower(onPower:true,lowPowerMode:ProcessInfo.processInfo.isLowPowerModeEnabled,
                             thermal:ProcessInfo.processInfo.thermalState.rawValue,battery:nil)
        guard let info=IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {return power}
        if let type=IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {power.onPower = type == kIOPMACPowerKey}
        if let list=IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let description=IOPSGetPowerSourceDescription(info,source)?.takeUnretainedValue() as? [String:Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let charge=description[kIOPSCurrentCapacityKey] as? Int,let full=description[kIOPSMaxCapacityKey] as? Int,full>0 else {continue}
                power.battery=charge*100/full
            }
        }
        return power
    }

    /// Calls `changed` on the main thread when the power source, Low Power Mode or the thermal state changes. The calls
    /// stop when the observation is released.
    final class Observation {
        private var source:CFRunLoopSource?
        private var observers:[NSObjectProtocol]=[]
        private let changed:() -> Void
        init(_ changed:@escaping () -> Void) {
            self.changed=changed
            let context=Unmanaged.passUnretained(self).toOpaque()
            if let made=IOPSNotificationCreateRunLoopSource({ context in
                guard let context else {return}
                Unmanaged<Observation>.fromOpaque(context).takeUnretainedValue().changed()
            },context)?.takeRetainedValue() {
                source=made;CFRunLoopAddSource(CFRunLoopGetMain(),made,.defaultMode)
            }
            for name in [Notification.Name.NSProcessInfoPowerStateDidChange,ProcessInfo.thermalStateDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.changed() })
            }
        }
        deinit {
            if let source {CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.defaultMode)}
            for observer in observers {NotificationCenter.default.removeObserver(observer)}
        }
    }
}

/// The earlier name, kept for callers: level notes use the model only when background work may.
enum LevelPower {
    static func onPower() -> Bool {ModelPower.current().onPower}
    static func allowsModel() -> Bool {ModelPower.current().allowsBackground}
}
