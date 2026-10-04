import Foundation
import Darwin
import BrowserBridge
import CoreIntegration
import AppKit
import Carbon

struct BrowserNativeEnvironment {
    var frontmost:()->String = {NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""}
    var secureInputOff:()->Bool = {!IsSecureEventInputEnabled()}
    var now:()->UInt64 = {DispatchTime.now().uptimeNanoseconds}
}

/// Supplied only by a separately reviewed provider setup. No wire/config boolean
/// creates pins or release/device validation. No default endpoint or key creation.
struct BrowserCaptureProvider {
    let directory:URL
    let connection:(CoreCaptureBinding)->CoreBrowserConnection
    var validate:()->Bool = {false}
}

/// Chrome's persistent host connection. Safari's containing extension and shared
/// container are not shipped, so Safari is deliberately not admitted here.
final class BrowserCaptureTransport {
    private let provider:BrowserCaptureProvider
    private weak var coordinator:Coordinator?
    private let lock=NSLock()
    private var stopped=false,started=false,peer:Int32 = -1
    init(provider:BrowserCaptureProvider,coordinator:Coordinator) {self.provider=provider;self.coordinator=coordinator}
    func start() {
        lock.lock();guard !started,!stopped else {lock.unlock();return};started=true;lock.unlock()
        DispatchQueue.global(qos:.utility).async { [self] in run() }
    }
    private var active:Bool {lock.lock();defer{lock.unlock()};return !stopped}
    func stop() {
        lock.lock();stopped=true
        if peer>=0 {_ = shutdown(peer,SHUT_RDWR)} // owner worker closes; no fd-reuse race
        lock.unlock()
    }
    private func run() {
        defer {stop()}
        guard active else {return}
        do {
            let listener=try MetadataLocalListener(directory:provider.directory)
            defer {listener.close()}
            while active {
                let fd:Int32
                do {fd=try listener.accept(deadline:DispatchTime.now().uptimeNanoseconds+200_000_000)}
                catch MetadataRelayError.deadline {continue}
                lock.lock();peer=fd;let permitted = !stopped;lock.unlock()
                if permitted {serve(fd)}
                lock.lock();peer = -1;Darwin.close(fd);lock.unlock()
            }
        } catch {
            DispatchQueue.main.async { [weak self] in guard let self else {return};coordinator?.browserTransportFailed(self) }
        }
    }
    private func serve(_ fd:Int32) {
        var connection:CoreBrowserConnection?
        defer {DispatchQueue.main.sync {connection?.close()}}
        do {
            let hello=try MetadataRelay.readFrame(fd,deadline:DispatchTime.now().uptimeNanoseconds+1_000_000_000)
            guard MetadataHello.decode(hello)?.browser == .chrome else {return}
            connection=DispatchQueue.main.sync {
                guard active,provider.validate(),let coordinator,coordinator.isRunning else {return nil}
                let candidate=provider.connection(coordinator.captureBinding)
                return candidate.acceptHello(hello) ? candidate : nil
            }
            guard let connection else {return}
            while active {
                let request:Data?=try DispatchQueue.main.sync {
                    guard active,provider.validate(),let coordinator,coordinator.isRunning else {return nil}
                    return try coordinator.browserRequest(connection)
                }
                guard let request else {return}
                try MetadataRelay.writeFrame(request,to:fd,deadline:DispatchTime.now().uptimeNanoseconds+500_000_000)
                let response=try MetadataRelay.readFrame(fd,deadline:DispatchTime.now().uptimeNanoseconds+900_000_000)
                let committed=try DispatchQueue.main.sync {
                    guard active,provider.validate(),let coordinator,coordinator.isRunning else {return false}
                    return try coordinator.browserResponse(connection,request:request,response:response)
                }
                guard committed else {return}
                Thread.sleep(forTimeInterval:0.15) // actual cadence, never future proof timestamps
            }
        } catch {
            // Includes storage errors: close the channel, expose a short failure,
            // never replay signed bytes or manufacture a native AX fallback.
            DispatchQueue.main.async { [weak self] in guard let self else {return};coordinator?.browserTransportFailed(self) }
        }
    }
    deinit {stop()}
}
