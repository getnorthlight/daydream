import Foundation
import AppKit
import Carbon.HIToolbox
import MemoryCore
import PrivacyPolicy

/// The typing pause shortcut: Control-Option-Command plus one letter, T by
/// default ("Don't record typing for 10 minutes", typing only). When another
/// app holds the chord, Settings says so and offers the other letters here.
enum TypingPauseChord: String, CaseIterable, Sendable {
    case t, y, p

    static let `default` = TypingPauseChord.t
    /// Carbon virtual key codes (kVK_ANSI_T, kVK_ANSI_Y, kVK_ANSI_P).
    var keyCode: UInt32 {
        switch self {
        case .t: return UInt32(kVK_ANSI_T)
        case .y: return UInt32(kVK_ANSI_Y)
        case .p: return UInt32(kVK_ANSI_P)
        }
    }
    /// Exactly Control, Option and Command (no Shift).
    static let carbonModifiers = UInt32(controlKey | optionKey | cmdKey)
    /// "⌃⌥⌘T".
    var display: String { "⌃⌥⌘" + rawValue.uppercased() }

    /// The saved choice (a per-Mac convenience; T when nothing or something unknown is saved).
    static let defaultsKey = "DaydreamTypingPauseChordV1"
    static func saved(_ defaults: UserDefaults = .standard) -> TypingPauseChord {
        defaults.string(forKey: defaultsKey).flatMap(TypingPauseChord.init(rawValue:)) ?? .default
    }
    func save(_ defaults: UserDefaults = .standard) {
        if self == .default { defaults.removeObject(forKey: Self.defaultsKey) } else { defaults.set(rawValue, forKey: Self.defaultsKey) }
    }
}

/// Where the global chord stands.
enum TypingHotkeyStatus: Equatable, Sendable {
    /// Nothing registered (development trials, checks, or before launch wiring).
    case notInstalled
    case registered(TypingPauseChord)
    /// Another app holds the chord (`eventHotKeyExistsErr`).
    case taken(TypingPauseChord)
    /// macOS refused it for another reason.
    case failed(TypingPauseChord)

    var chord: TypingPauseChord? {
        switch self {
        case .notInstalled: return nil
        case .registered(let c), .taken(let c), .failed(let c): return c
        }
    }
    /// The shortcut the menu may show next to "Don't record typing": only one that works.
    var activeDisplay: String? { if case .registered(let c) = self { return c.display }; return nil }
}

/// Registers one global hot key. The app uses Carbon; the checks use a fake.
protocol TypingHotkeyRegistrar: AnyObject {
    /// Registers `keyCode` with exactly `modifiers`; `handler` runs on the main queue
    /// each time it is pressed. Replaces any chord registered before.
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> TypingHotkeyRegistration
    func unregister()
}

enum TypingHotkeyRegistration: Equatable, Sendable { case registered, taken, failed }

/// Carbon `RegisterEventHotKey`: a global hot key that needs no permission
/// (no event tap, no Accessibility or Input Monitoring request). Registered
/// with `kEventHotKeyExclusive`, so a chord another app already holds fails
/// with `eventHotKeyExistsErr` instead of firing in both apps.
final class CarbonTypingHotkeyRegistrar: TypingHotkeyRegistrar {
    /// 'DDty'.
    static let signature: OSType = 0x4444_7479
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (() -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> TypingHotkeyRegistration {
        MainQueue.require()   // claude/crashguard-015: Carbon's event target is the main queue's
        unregister()
        self.handler = handler
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            guard let event, let user else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr, id.signature == CarbonTypingHotkeyRegistrar.signature, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let registrar = Unmanaged<CarbonTypingHotkeyRegistrar>.fromOpaque(user).takeUnretainedValue()
            // When the chord was pressed, in the uptime clock key events use (gold/r3-typing), taken by the handler.
            let pressed = GetEventTime(event)
            TypingHotkey.notePress(at: pressed > 0 ? UInt64(pressed * 1_000_000_000) : nil)
            DispatchQueue.main.async { registrar.handler?() }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard installed == noErr else { unregister(); return .failed }
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        guard status == noErr else {
            unregister()
            return status == OSStatus(eventHotKeyExistsErr) ? .taken : .failed
        }
        return .registered
    }

    func unregister() {
        MainQueue.require()
        TypingHotkey.clearPresses()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil; eventHandler = nil; handler = nil
    }
    deinit { unregister() }
}

/// Control-Option-Command-T: "Don't record typing for 10 minutes" (typing
/// only). `install` registers the chord with Carbon `RegisterEventHotKey`
/// (no new permission). EventCapture never writes a `keyboard.shortcut` row
/// for the chord that is in use, so pausing leaves no trace in history.
enum TypingHotkey {
    private static let lock = NSLock()
    private static var _chord = TypingPauseChord.default
    /// When each pause chord not yet handled was pressed (uptime nanoseconds; nil when unknown), oldest first. The
    /// Carbon callback notes the press; the handler, run once per press in order on the main queue, takes it.
    private static var presses: [UInt64?] = []
    static func notePress(at: UInt64?) {
        lock.lock(); defer { lock.unlock() }
        presses.append(at); if presses.count > 8 { presses.removeFirst(presses.count - 8) }
    }
    static func takePress() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return presses.isEmpty ? nil : presses.removeFirst()
    }
    static func clearPresses() { lock.lock(); presses.removeAll(); lock.unlock() }
    /// The chord EventCapture treats as the pause chord (the one chosen).
    static var chord: TypingPauseChord {
        get { lock.lock(); defer { lock.unlock() }; return _chord }
        set { lock.lock(); _chord = newValue; lock.unlock() }
    }

    /// Carbon for the app bundle only. A bare executable (the check programs
    /// that build a production model) registers no system-wide shortcut.
    static func appRegistrar(bundle: Bundle = .main) -> TypingHotkeyRegistrar? {
        bundle.bundleURL.pathExtension == "app" ? CarbonTypingHotkeyRegistrar() : nil
    }

    /// True for the chosen chord itself: its letter with exactly Control,
    /// Option and Command. The default is `TypingPauseShortcut` (⌃⌥⌘T).
    static func isPauseChord(_ stroke: KeyStroke) -> Bool {
        let chord = self.chord
        guard stroke.keyCode >= 0, stroke.keyCode <= Int64(UInt32.max) else { return false }
        if chord == .default {
            return TypingPauseShortcut.matches(keyCode: UInt32(stroke.keyCode), control: stroke.control, option: stroke.option,
                                               command: stroke.command, shift: stroke.shift)
        }
        return UInt32(stroke.keyCode) == chord.keyCode && stroke.control && stroke.option && stroke.command && !stroke.shift
    }

    /// Registers the chord (T unless another was chosen). Returns true only
    /// when macOS registered it.
    @discardableResult static func install(onPause: @escaping () -> Void, chord: TypingPauseChord = .default,
                                           registrar: TypingHotkeyRegistrar) -> Bool {
        register(chord, registrar: registrar, onPause: onPause) == .registered(chord)
    }

    static func register(_ chord: TypingPauseChord, registrar: TypingHotkeyRegistrar, onPause: @escaping () -> Void) -> TypingHotkeyStatus {
        self.chord = chord
        switch registrar.register(keyCode: chord.keyCode, modifiers: TypingPauseChord.carbonModifiers, handler: onPause) {
        case .registered: return .registered(chord)
        case .taken: return .taken(chord)
        case .failed: return .failed(chord)
        }
    }
}

/// The 2-second confirmation after the shortcut: "Typing paused for 10
/// minutes". A small borderless panel under the menu bar that never takes
/// focus or clicks; the app stays in the background.
@MainActor enum TypingToast {
    private static var panel: NSPanel?
    private static var hide: DispatchWorkItem?
    static let seconds: TimeInterval = 2

    static func show(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.setAccessibilityLabel(text)
        let size = label.fittingSize
        let frame = NSRect(x: 0, y: 0, width: ceil(size.width) + 32, height: ceil(size.height) + 18)
        let effect = NSVisualEffectView(frame: frame)
        effect.material = .hudWindow; effect.state = .active; effect.blendingMode = .behindWindow
        effect.wantsLayer = true; effect.layer?.cornerRadius = 10; effect.layer?.masksToBounds = true
        label.frame = NSRect(x: 16, y: 9, width: ceil(size.width), height: ceil(size.height))
        effect.addSubview(label)
        let window = panel ?? NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isFloatingPanel = true; window.level = .statusBar; window.hasShadow = true
        window.isOpaque = false; window.backgroundColor = .clear; window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        window.contentView = effect
        window.setContentSize(frame.size)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 16, y: visible.maxY - frame.height - 8))
        }
        window.orderFrontRegardless()
        NSAccessibility.post(element: label, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        panel = window
        hide?.cancel()
        let work = DispatchWorkItem { panel?.orderOut(nil) }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
