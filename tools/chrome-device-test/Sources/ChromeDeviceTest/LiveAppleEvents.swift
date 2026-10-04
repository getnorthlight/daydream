import Foundation
import Carbon
import ChromeProbeCore

/// Read-only Apple Events to the already-running Chrome, addressed by PID so
/// nothing is ever launched. The only event ever built is `core/getd` (get
/// data); the only properties are those in `AEProperty` plus `acTa` as a
/// container. No script, JavaScript, keystroke, `set`, `make` or `close`.
final class LiveAppleEvents: AppleEventPort {
    let pid: pid_t
    let timeout: TimeInterval
    private let target: NSAppleEventDescriptor

    init(pid: pid_t, timeoutMs: Double) {
        self.pid = pid
        self.timeout = timeoutMs / 1000
        self.target = NSAppleEventDescriptor(processIdentifier: pid)
    }

    static func code(_ s: String) -> FourCharCode { s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) } }
    static func name(_ c: FourCharCode) -> String {
        String(bytes: [UInt8(c >> 24 & 0xff), UInt8(c >> 16 & 0xff), UInt8(c >> 8 & 0xff), UInt8(c & 0xff)], encoding: .macOSRoman) ?? "\(c)"
    }
    private func code(_ s: String) -> FourCharCode { Self.code(s) }

    /// A real absolute-ordinal descriptor (`typeAbsoluteOrdinal`), which is
    /// what AppleScript sends for `first`/`every`. Same form as the app's fix
    /// (`Sources/MemoryCore/ChromeAppleEvents.swift:56`, commit 0584e30); the
    /// pre-fix `ChromeModeReader.swift:39` (6f26d15) sent `firs` as typeEnumerated.
    private func absoluteOrdinal(_ ordinal: String) -> NSAppleEventDescriptor? {
        var value = code(ordinal)
        return NSAppleEventDescriptor(descriptorType: code("abso"), bytes: &value, length: MemoryLayout<FourCharCode>.size)
    }

    private func specifier(want: String, form: String, key: NSAppleEventDescriptor?, from container: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        guard let key else { return nil }
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        record.setDescriptor(key, forKeyword: code("seld"))
        record.setDescriptor(container, forKeyword: code("from"))
        return record.coerce(toDescriptorType: code("obj "))
    }

    private func window(_ ref: WindowTarget) -> NSAppleEventDescriptor? {
        let app = NSAppleEventDescriptor.null()
        switch ref {
        case .every: return specifier(want: "cwin", form: "indx", key: absoluteOrdinal("all "), from: app)
        case .firstAbsolute: return specifier(want: "cwin", form: "indx", key: absoluteOrdinal("firs"), from: app)
        // Exactly as the pre-fix ChromeModeReader.swift:39 (6f26d15) built it.
        case .firstLegacyEnum: return specifier(want: "cwin", form: "indx", key: NSAppleEventDescriptor(enumCode: code("firs")), from: app)
        case .index(let i): return specifier(want: "cwin", form: "indx", key: NSAppleEventDescriptor(int32: Int32(i)), from: app)
        case .id(let id): return specifier(want: "cwin", form: "ID  ", key: NSAppleEventDescriptor(string: id), from: app)
        }
    }

    private func property(_ p: String, of container: NSAppleEventDescriptor?) -> NSAppleEventDescriptor? {
        guard let container else { return nil }
        return specifier(want: "prop", form: "prop", key: NSAppleEventDescriptor(typeCode: code(p)), from: container)
    }

    func send(_ q: AEQuery) -> AEReply {
        let spec: NSAppleEventDescriptor?
        switch q {
        case .window(let ref, let p): spec = property(p.rawValue, of: window(ref))
        case .activeTab(let id, let p):
            guard p == .id || p == .url else { return AEReply(value: nil, status: -1, nanos: 0) }
            spec = property(p.rawValue, of: property("acTa", of: window(.id(id))))
        }
        guard let spec else { return AEReply(value: nil, status: -1, nanos: 0) }
        let event = NSAppleEventDescriptor(eventClass: code("core"), eventID: code("getd"), targetDescriptor: target, returnID: -1, transactionID: 0)
        event.setParam(spec, forKeyword: code("----"))
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .neverInteract, .dontRecord], timeout: timeout)
            let nanos = DispatchTime.now().uptimeNanoseconds &- start
            let errn = reply.paramDescriptor(forKeyword: code("errn"))?.int32Value ?? 0
            guard errn == 0, let d = reply.paramDescriptor(forKeyword: code("----")) else {
                return AEReply(value: nil, status: errn != 0 ? errn : -2, nanos: nanos)
            }
            return AEReply(value: convert(d, for: q), status: 0, nanos: nanos, rawType: Self.name(d.descriptorType))
        } catch {
            return AEReply(value: nil, status: Int32(truncatingIfNeeded: (error as NSError).code), nanos: DispatchTime.now().uptimeNanoseconds &- start)
        }
    }

    private func convert(_ d: NSAppleEventDescriptor, for q: AEQuery) -> AEValue? {
        if case .window(_, .bounds) = q { return rect(d).map(AEValue.rect) }
        if d.descriptorType == code("list") {
            guard d.numberOfItems > 0 else { return .list([]) }
            return .list((1...d.numberOfItems).map { d.atIndex($0)?.stringValue ?? "" })
        }
        if case .window(.every, _) = q { return d.stringValue.map { .list([$0]) } }
        return d.stringValue.map(AEValue.text)
    }

    /// Chrome returns bounds as a QuickDraw rect (top, left, bottom, right as
    /// SInt16), or AppleScript-style as a 4-item list (left, top, right, bottom).
    private func rect(_ d: NSAppleEventDescriptor) -> Rect? {
        if d.descriptorType == code("list"), d.numberOfItems == 4 {
            let v = (1...4).map { Int(d.atIndex($0)?.int32Value ?? 0) }
            return Rect.quickDraw(left: v[0], top: v[1], right: v[2], bottom: v[3])
        }
        if d.descriptorType == code("qdrt") || d.descriptorType == code("tdta"), d.data.count == 8 {
            let s = (0..<4).map { i in d.data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)) } }
            return Rect.quickDraw(left: s[1], top: s[0], right: s[3], bottom: s[2])
        }
        if let l = d.coerce(toDescriptorType: code("list")), l.numberOfItems == 4 {
            let v = (1...4).map { Int(l.atIndex($0)?.int32Value ?? 0) }
            return Rect.quickDraw(left: v[0], top: v[1], right: v[2], bottom: v[3])
        }
        return nil
    }
}

/// Automation permission (Terminal -> Google Chrome), checked for `core/getd`.
enum Automation {
    static func describe(_ status: OSStatus) -> String {
        switch status {
        case noErr: return "granted"
        case -1744: return "not decided"          // errAEEventWouldRequireUserConsent
        case -1743: return "denied"               // errAEEventNotPermitted
        case -600: return "Chrome not running"    // procNotFound
        default: return "error \(status)"
        }
    }
    /// Never prompts.
    static func status(pid: pid_t) -> OSStatus {
        determine(pid: pid, ask: false)
    }
    /// The ONLY code path that can show the macOS Automation prompt. Called
    /// only from `main.swift` when --request-permission was given.
    static func requestAutomationPermission(pid: pid_t) -> OSStatus {
        determine(pid: pid, ask: true)
    }
    private static func determine(pid: pid_t, ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, LiveAppleEvents.code("core"), LiveAppleEvents.code("getd"), ask)
    }
}
