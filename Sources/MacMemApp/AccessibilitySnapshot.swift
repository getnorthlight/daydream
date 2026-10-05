// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// Portions of this file are derived from open-codex-computer-history
// (https://github.com/hqhq1025/open-codex-computer-history),
// Copyright (c) 2026 Open Codex Computer History contributors, used under the
// MIT License. The full MIT notice is in THIRD-PARTY-NOTICES.md.

import AppKit
import ApplicationServices
import Foundation
import HistoryCore
import Carbon
import MemoryCore
import PrivacyPolicy
import Security

/// A point-in-time read of the focused app/window/element via the Accessibility
/// API. Thin and permission-gated — this is the part that genuinely needs the
/// Accessibility grant and so is *not* unit-tested; the rules it feeds (Policy,
/// TextBuffer, Store) are.
struct AccessibilitySnapshot {
    let focusID: String
    let app: AppInfo
    let window: WindowInfo?
    let element: ElementInfo?
    let secureInput: Bool
    let privateBrowsing: Bool
    let selectedText: String?
    let selectedLocation: Int?
    let selectedLength: Int?
    var browserVerification: BrowserVerification? = nil
}

/// claude/crashguard-015: the one place the app reads Text Input Sources (HIToolbox/TSM), which assert the main QUEUE:
/// macOS 15 traps off it (owner laptop 10/04, `_dispatch_assert_queue_fail`), macOS 26 doesn't. On the main queue the
/// selected source is read live, as before, and kept; anywhere else (website typing's executor, the tap thread, an
/// Accessibility queue, a main-thread `sync` of another queue) the value last read on the main queue is answered and
/// TIS is never called. Capture reads it again on the main queue at every input source change (`refresh`, from the
/// distributed notification `InputSourceListener` hears), so that value is never older than the last change. false
/// until the main queue has read it once: nothing is proven before.
enum KeyboardInputSource {
    /// The direct layouts: each key is the character it types (no input method composes it).
    static let directLayouts: Set<String> = ["com.apple.keylayout.US","com.apple.keylayout.ABC","com.apple.keylayout.British"]
    private static let lock = NSLock()
    private static var lastDirect = false
    static func isDirect() -> Bool {
        guard MainQueue.isCurrent else { lock.lock(); defer { lock.unlock() }; return lastDirect }
        let now = selectedSourceID().map(directLayouts.contains) ?? false
        lock.lock(); lastDirect = now; lock.unlock()
        return now
    }
    /// Reads the selected source again on the main queue (now, or on its next turn when called elsewhere).
    static func refresh() {
        if MainQueue.isCurrent { _ = isDirect() } else { DispatchQueue.main.async { _ = isDirect() } }
    }
    /// The selected keyboard input source's ID. Main queue only: debug and check builds trap elsewhere
    /// (`MainQueue.require`), and a release build answers nil there rather than call TIS.
    private static func selectedSourceID() -> String? {
        MainQueue.require()
        guard MainQueue.isCurrent, let source=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw=TISGetInputSourceProperty(source,kTISPropertyInputSourceID) else {return nil}
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}

enum AccessibilityReader {
    static var status = "No foreground observation yet."
    private static let nativeWitness=NativeFocusWitness<AXUIElement>()
    private static func invalidateWitnesses() {
        nativeWitness.invalidate()
        #if DAYDREAM_OWNER_TYPING
        WebContentAXReader.invalidate()
        #endif
    }
    /// Metadata only. The native proof requests no AX value, title,
    /// identifier, description or selection (the web-content proof, owner
    /// build only, adds the reads listed on `WebContentAXReader`). Unknown
    /// ancestry/focus is a deny, not native proof.
    /// Called at burst start, on every key and at save; each call also requires
    /// the system-wide focused application to be `pid`, so a panel that takes
    /// key focus (Spotlight) fails the proof and the pending burst is dropped.
    static func typingProof(pid frontmost:pid_t,generation:UInt64,policyVersion:UInt64,now:UInt64) -> FocusProof? {
        // All production capture callbacks use the main serial executor.
        guard Thread.isMainThread else {return nil}
        // A launcher panel this build allows (Spotlight) holds key focus while
        // the app behind it stays frontmost: its keys are proved against the
        // panel's own process. Key focus in any other process fails below.
        // perm-1004: trust first; the key target's system-wide focus read is an Accessibility read too.
        guard AXIsProcessTrusted() else {invalidateWitnesses();return nil}
        let pid=NativeTypingRoute.keyTarget(frontmost:frontmost)
        guard AXIsProcessTrusted(),CGPreflightListenEventAccess(),!IsSecureEventInputEnabled(),
              directKeyboardInput(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier==frontmost,
              let running=NSRunningApplication(processIdentifier:pid),let bundle=running.bundleIdentifier,
              CaptureGate.nativeApps.contains(bundle),pid==frontmost || CaptureGate.keyPanelApps.contains(bundle),
              trustedNativeProcess(pid:pid,bundle:bundle) else {invalidateWitnesses();return nil}
        // Keys going to another app's non-activating panel (Spotlight, a
        // password manager's quick access) while Notes stays frontmost: the
        // witness's system-wide focus read fails closed, nothing is read, and
        // the field gets a new identity when focus comes back.
        let app=AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(app,0.025) == .success else {invalidateWitnesses();return nil}
        func owner(_ node:AXUIElement)->Int32? {
            // AX timeouts are per object, not inherited from the application.
            guard AXUIElementSetMessagingTimeout(node,0.025) == .success else {return nil}
            var value:pid_t=0;return AXUIElementGetPid(node,&value) == .success ? value:nil
        }
        func subrole(_ node:AXUIElement)->String? {
            var value:CFTypeRef?
            let result=AXUIElementCopyAttributeValue(node,kAXSubroleAttribute as CFString,&value)
            if result == .attributeUnsupported || result == .noValue {return ""}
            guard result == .success else {return nil};return value as? String
        }
        var access=NativeFocusAccess<AXUIElement>(now:{DispatchTime.now().uptimeNanoseconds},ready:{
                AXIsProcessTrusted() && CGPreflightListenEventAccess() && !IsSecureEventInputEnabled() && directKeyboardInput() && NSWorkspace.shared.frontmostApplication?.processIdentifier==frontmost
            },identity:{
                // Live test (build 7): Messages reopened at login has no launch date (macOS didn't launch it through
                // Launch Services), which refused every key typed there. The kernel's start time stands in: a reused
                // PID still never matches (`ProcessStart`).
                guard let process=NSRunningApplication(processIdentifier:pid),process.bundleIdentifier==bundle,
                      let launched=ProcessStart.seconds(launchDate:process.launchDate,pid:pid),trustedNativeProcess(pid:pid,bundle:bundle) else {return nil}
                return "\(pid):\(launched):\(bundle)"
            },focusedApplication:systemFocusedApplication,window:{element(app,kAXFocusedWindowAttribute)},focus:{element(app,kAXFocusedUIElementAttribute)},
            owner:owner,role:{string($0,kAXRoleAttribute)},subrole:subrole,parent:{element($0,kAXParentAttribute)},equal:{CFEqual($0,$1)})
        if bundle == MessagesComposer.bundle {
            access.labels=MessagesComposer.labels
            access.sameField=MessagesComposer.sameField
        }
        #if DAYDREAM_OWNER_TYPING
        // Apps with web content (owner build only; public builds allow none).
        if CaptureGate.webContentApps.contains(bundle),let web=TypingCategories.app(bundle)?.web {
            return WebContentAXReader.read(app:app,pid:pid,bundle:bundle,web:web,generation:generation,policyVersion:policyVersion,access:access)
        }
        #endif
        return nativeWitness.read(pid:pid,bundle:bundle,generation:generation,policyVersion:policyVersion,access:access)
    }
    private static func directKeyboardInput()->Bool {
        // A CG key tap does not prove committed IME/autofill/paste text. Support
        // only these direct layouts; do not manufacture composition completion.
        // claude/crashguard-015: Text Input Sources are read on the main queue only (`KeyboardInputSource`).
        KeyboardInputSource.isDirect()
    }
    /// The same direct-layout rule for website typing (owner build), which
    /// proves keys with the Chrome join instead of the native proof: a key an
    /// input method composes (Japanese, Chinese, Korean) is never proven.
    static func keyboardInputIsDirect()->Bool {directKeyboardInput()}
    /// The process macOS delivers keystrokes to, from the system-wide
    /// Accessibility element. NSWorkspace's frontmost app is not enough:
    /// Spotlight and similar panels take key focus while the app behind them
    /// stays frontmost. No timeout is set here, because a timeout set on the
    /// system-wide element would change every Accessibility call in this process.
    /// The one system-wide focus read in the app; other witnesses call this.
    /// perm-1004: never while Accessibility is off. An Accessibility read by an untrusted process makes macOS show its own
    /// "would like to control this computer" prompt; this read ran on every status refresh in the owner build (Spotlight
    /// is a key panel there, `TypingModel.keyPanel`), and that was the prompt the owner saw on 10/3.
    static func systemFocusedApplication()->pid_t? {
        guard AXIsProcessTrusted() else {return nil}
        var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),kAXFocusedApplicationAttribute as CFString,&value) == .success,
              let value,CFGetTypeID(value)==AXUIElementGetTypeID() else {return nil}
        var focused:pid_t=0
        guard AXUIElementGetPid(value as! AXUIElement,&focused) == .success,focused>0 else {return nil}
        return focused
    }
    private static func trustedNativeProcess(pid:pid_t,bundle:String)->Bool {
        // A bundle identifier alone can be copied by another app. Each allowed
        // app must carry the signature its table row names
        // (`TypingCategories.signingRequirement`): Apple's for Apple's apps,
        // the App Store's for store copies, the vendor's team for the rest.
        guard CaptureGate.nativeApps.contains(bundle),let row=TypingCategories.app(bundle),
              let text=TypingCategories.signingRequirement(row) else {return false}
        // perf-1002: a key used to run this check up to six times (both proofs, each witness identity read), each a
        // certificate-chain evaluation on the main thread (live sample: ~15% of the key handler). A pass is reused for
        // `SignatureVerdicts.ttl` by the same launch (pid, kernel start time, bundle) and requirement only; a reused
        // PID, another bundle or requirement, a refusal or an unreadable start time always checks again.
        let launch=ProcessStart.kernelSeconds(pid:pid).map {"\(pid):\($0):\(bundle)|"+text}
        let now=DispatchTime.now().uptimeNanoseconds
        if let launch,signatureVerdicts.passed(launch,now:now) {
            // perf-1005: past half its life the pass is checked again off the main thread (the same check, same flags,
            // the compiled requirement); a refusal drops it, so the next key checks here again.
            if signatureVerdicts.refreshDue(launch,now:now),signatureRefreshing.insert(launch).inserted,let requirement=compiledRequirement(text) {
                signatureQueue.async {
                    var code:SecCode?
                    let valid=SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:pid] as CFDictionary,SecCSFlags(rawValue:0),&code)==errSecSuccess
                        && code.map { SecCodeCheckValidity($0,SecCSFlags(rawValue:0),requirement)==errSecSuccess } == true
                    DispatchQueue.main.async {
                        signatureRefreshing.remove(launch)
                        signatureVerdicts.record(launch,valid:valid,now:now)
                    }
                }
            }
            return true
        }
        var code:SecCode?
        guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:pid] as CFDictionary,SecCSFlags(rawValue:0),&code)==errSecSuccess,
              let code,let requirement=compiledRequirement(text) else {return false}
        let valid=SecCodeCheckValidity(code,SecCSFlags(rawValue:0),requirement)==errSecSuccess
        if let launch {signatureVerdicts.record(launch,valid:valid,now:now)}
        return valid
    }
    /// perf2-1005: an allowed native app came to the front (main thread): its signature is checked now, off the main
    /// thread, so its first key finds a pass instead of making the certificate-chain check on main (the first check
    /// after launch, and after each pass ran out). The same check and requirement as `trustedNativeProcess`; a refusal
    /// is recorded the same way, so that key still checks again on main.
    static func prewarmSignature(pid:pid_t,bundle:String) {
        guard Thread.isMainThread,CaptureGate.nativeApps.contains(bundle),let row=TypingCategories.app(bundle),
              let text=TypingCategories.signingRequirement(row),let started=ProcessStart.kernelSeconds(pid:pid) else {return}
        let launch="\(pid):\(started):\(bundle)|"+text
        let now=DispatchTime.now().uptimeNanoseconds
        guard !signatureVerdicts.passed(launch,now:now) || signatureVerdicts.refreshDue(launch,now:now),
              signatureRefreshing.insert(launch).inserted else {return}
        guard let requirement=compiledRequirement(text) else {signatureRefreshing.remove(launch);return}
        signatureQueue.async {
            var code:SecCode?
            let valid=SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:pid] as CFDictionary,SecCSFlags(rawValue:0),&code)==errSecSuccess
                && code.map { SecCodeCheckValidity($0,SecCSFlags(rawValue:0),requirement)==errSecSuccess } == true
            DispatchQueue.main.async {
                signatureRefreshing.remove(launch)
                // A refusal is not cached (`SignatureVerdicts.record` keeps passes only): the key checks again on main.
                if valid {signatureVerdicts.record(launch,valid:true,now:now)}
            }
        }
    }
    /// Main thread only, like every caller.
    private static var signatureVerdicts=SignatureVerdicts()
    /// perf-1005: launches whose pass is being checked again off the main thread (main thread only), and where.
    private static var signatureRefreshing=Set<String>()
    private static let signatureQueue=DispatchQueue(label:"daydream.native-signature",qos:.userInitiated)
    /// Each requirement string is compiled once (main thread only, like every caller).
    private static var requirements:[String:SecRequirement]=[:]
    private static func compiledRequirement(_ text:String)->SecRequirement? {
        if let known=requirements[text] {return known}
        var requirement:SecRequirement?
        guard SecRequirementCreateWithString(text as CFString,SecCSFlags(rawValue:0),&requirement)==errSecSuccess,let requirement else {return nil}
        requirements[text]=requirement;return requirement
    }
    /// Where focus went, for a typed unit whose field was left. Metadata only:
    /// OS secure input, the frontmost bundle, and the focused element's role
    /// and subrole with a 25 ms timeout. Browsers are never AX-read here; no
    /// value, title or selection is requested.
    static func departureState() -> DepartureState {
        var state=DepartureState()
        state.secureInput=IsSecureEventInputEnabled() ? .yes : .no
        guard let front=NSWorkspace.shared.frontmostApplication else {return state}
        // Keyboard focus in another app's non-activating panel: that app is
        // where focus went; only its bundle is used.
        var owner=front
        if Thread.isMainThread,AXIsProcessTrusted(),let keyboard=systemFocusedApplication(),keyboard != front.processIdentifier {
            guard let panel=NSRunningApplication(processIdentifier:keyboard) else {return state}
            owner=panel
        }
        guard let bundle=owner.bundleIdentifier,!bundle.isEmpty else {return state}
        state.bundle=bundle
        if CaptureSession.excludedBrowsers.contains(bundle) || CaptureGate.isBrowser(bundle) {return state}
        guard owner.processIdentifier == front.processIdentifier,Thread.isMainThread,AXIsProcessTrusted() else {return state}
        let app=AXUIElementCreateApplication(front.processIdentifier)
        guard AXUIElementSetMessagingTimeout(app,0.025) == .success,
              let focused=element(app,kAXFocusedUIElementAttribute),
              AXUIElementSetMessagingTimeout(focused,0.025) == .success else {return state}
        func read(_ attribute:String)->String?? {
            var value:CFTypeRef?
            let result=AXUIElementCopyAttributeValue(focused,attribute as CFString,&value)
            if result == .attributeUnsupported || result == .noValue {return .some(nil)}
            guard result == .success else {return nil}
            return .some(value as? String)
        }
        // A failed read stays unknown; unsupported or empty is a real answer.
        guard let role=read(kAXRoleAttribute as String),let subrole=read(kAXSubroleAttribute as String) else {return state}
        state.focusSecure=ObservationPolicy.isSecureRole(role,subrole:subrole) ? .yes : .no
        return state
    }
    /// How long one Accessibility call to the app in front may take for a snapshot (and for registering its
    /// notifications) before it gives up. Ordinary reads take a few milliseconds.
    static let snapshotTimeout: Float = 0.25
    /// A snapshot that has taken longer than this in all gives up (nothing is recorded from it).
    static let snapshotBudgetNanoseconds: UInt64 = 500_000_000
    /// `element`, answering within `snapshotTimeout` (the timeout is per element; a child read from it gets the
    /// default again).
    private static func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, snapshotTimeout)
        return element
    }
    /// Build a snapshot for `pid`. When `point` is given (a mouse event), the
    /// focused element is resolved by hit-testing that point instead of the
    /// app's focused element.
    static func snapshot(pid: pid_t, at point: CGPoint? = nil, captureText: Bool) -> AccessibilitySnapshot? {
        let r = read(pid: pid, at: point, captureText: captureText)
        status = r.status
        return r.snapshot
    }
    /// perf2-1005: the snapshot and the status line it leaves, without touching `status` (main thread only): safe off
    /// the main thread (`EventCapture`'s Accessibility read queue). Every read here is an Accessibility call bounded by
    /// `snapshotTimeout`, a running-application lookup or a pure policy rule.
    static func read(pid: pid_t, at point: CGPoint? = nil, captureText: Bool) -> (snapshot: AccessibilitySnapshot?, status: String) {
        var status = "Content withheld: permissions, secure input or focus unavailable."
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let running = NSRunningApplication(processIdentifier: pid) else { return (nil, status) }
        let bundle=running.bundleIdentifier ?? ""
        // Live test (build 7): a macOS alert or agent in front ("UserNotificationCenter ~4 min" headlined the day) is
        // not an activity. Its time stays with the app behind it, whose rows are the last ones saved.
        if SystemProcesses.excluded(bundle:bundle,regularApp:running.activationPolicy == .regular) {
            return (nil, "System alerts and background agents aren't recorded.")
        }
        if CaptureSession.excludedBrowsers.contains(bundle) {
            // AppleEvents' front window and AX focus do not prove the same
            // window/tab/document, so browser windows are never read through
            // AX. Chrome page history reads the page in front by Apple Events
            // only, on its own path, never here.
            #if DAYDREAM_OWNER_TYPING
            // Owner build: website typing reads Chrome through the join, never here.
            return (nil, WebTypingText.browserStatus)
            #else
            return (nil, "Browser windows aren't read here. What's on web pages and what you type in browsers is never saved.")
            #endif
        }
        // Every element read here answers within `snapshotTimeout` or not at all (the default is six seconds a call,
        // on the main thread and, for a click, inside the input tap), and the read gives up once it has taken
        // `snapshotBudgetNanoseconds`: a frontmost app that has stopped answering can't freeze DayDream.
        let started = DispatchTime.now().uptimeNanoseconds
        let overBudget = { DispatchTime.now().uptimeNanoseconds &- started > snapshotBudgetNanoseconds }
        let appElement = bounded(AXUIElementCreateApplication(pid))
        let windowElement = element(appElement, kAXFocusedWindowAttribute).map(bounded)
        // Security follows keyboard focus, not the element under the mouse.
        guard let focused = element(appElement, kAXFocusedUIElementAttribute).map(bounded), !overBudget() else { return (nil, status) }

        let role = string(focused, kAXRoleAttribute)
        let subrole = string(focused, kAXSubroleAttribute)
        guard let role, !role.isEmpty, !overBudget() else { return (nil, status) }
        let secure = ObservationPolicy.isSecureRole(role, subrole: subrole)
        guard !secure else { return (nil, status) } // Do not read title, value or URL in secure context.
        status="Supported native app observation."

        let windowTitle = string(windowElement, kAXTitleAttribute)
        guard !ObservationPolicy.titleLooksPrivate(windowTitle) else { return (nil, status) }
        let url = webURL(focused: focused, window: windowElement, app: appElement, bundleID: running.bundleIdentifier)
        let browser = ObservationPolicy.browserBundleIdentifiers.contains(running.bundleIdentifier ?? "")
        let privateBrowsing = browser && (
            ObservationPolicy.titleLooksPrivate(windowTitle)
                || windowChromeLooksPrivate(windowElement)
        )

        let elementInfo: ElementInfo = {
            let el = focused
            return ElementInfo(
                role: role,
                subrole: subrole,
                title: string(el, kAXTitleAttribute),
                // Never read the value of a secure field, and honor captureText.
                value: nil, // Typed-only consent never authorizes reading a field or terminal buffer.
                identifier: string(el, kAXIdentifierAttribute)
            )
        }()

        guard !overBudget(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let finalFocus=element(appElement,kAXFocusedUIElementAttribute).map(bounded), CFEqual(focused,finalFocus),
              let finalWindow=element(appElement,kAXFocusedWindowAttribute).map(bounded), let windowElement,
              CFEqual(windowElement,finalWindow), string(finalFocus,kAXRoleAttribute) == role,
              !ObservationPolicy.isSecureRole(role,subrole:string(finalFocus,kAXSubroleAttribute)),
              !IsSecureEventInputEnabled(), AXIsProcessTrusted(), !overBudget() else { return (nil, status) }
        return (AccessibilitySnapshot(
            focusID: "\(pid):\(CFHash(focused)):\(CFHash(windowElement)):\(windowTitle ?? ""):\(url ?? "")",
            app: AppInfo(name: running.localizedName, bundleIdentifier: running.bundleIdentifier, secureInput: secure),
            // AX does not supply a public CG window-number join here. Omit it;
            // duplicate titles/first-window order are not identity evidence.
            window: WindowInfo(title: windowTitle, url: url, windowID: nil),
            element: elementInfo,
            secureInput: secure,
            privateBrowsing: privateBrowsing,
            selectedText: nil,
            selectedLocation: nil,
            selectedLength: nil
        ), status)
    }

    /// Safari and Chrome often leave "Private" / "Incognito" on a toolbar
    /// control instead of the window title. Walk a small slice of the window
    /// chrome only — not the page — so a page that mentions "incognito" is not
    /// treated as a private window.
    private static func windowChromeLooksPrivate(_ window: AXUIElement?) -> Bool {
        guard let window else { return false }
        var queue = [window]
        var n = 0
        while !queue.isEmpty, n < 80 {
            let element = queue.removeFirst()
            n += 1
            let blob = [
                string(element, kAXTitleAttribute),
                string(element, kAXDescriptionAttribute),
                string(element, kAXRoleDescriptionAttribute),
            ].compactMap { $0 }.joined(separator: " ")
            if ObservationPolicy.chromeLooksPrivate(blob) { return true }
            if n < 40 { queue.append(contentsOf: children(element)) }
        }
        return false
    }

    // MARK: - URL resolution

    /// Prefer a direct AXURL/AXDocument on the focused/window element; otherwise
    /// walk a bounded slice of a browser's tree to find the address field.
    private static func webURL(focused: AXUIElement?, window: AXUIElement?, app: AXUIElement, bundleID: String?) -> String? {
        for element in [focused, window, app].compactMap({ $0 }) {
            for attr in ["AXURL", "AXDocument"] {
                if let url = normalizedWebURL(string(element, attr)) { return url }
            }
        }
        guard let bundleID, ObservationPolicy.browserBundleIdentifiers.contains(bundleID), let window else { return nil }
        return browserAddressURL(root: window)
    }

    private static func browserAddressURL(root: AXUIElement) -> String? {
        var queue = [root]
        var visited = Set<CFHashCode>()
        var count = 0
        while !queue.isEmpty, count < 400 {
            let element = queue.removeFirst()
            count += 1
            guard visited.insert(CFHash(element)).inserted else { continue }
            for attr in ["AXURL", "AXDocument"] {
                if let url = normalizedWebURL(string(element, attr)) { return url }
            }
            let label = [string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute), string(element, kAXIdentifierAttribute)]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            if string(element, kAXRoleAttribute) == (kAXTextFieldRole as String),
               label.contains("address") || label.contains("search"),
               let url = normalizedWebURL(string(element, kAXValueAttribute)) {
                return url
            }
            queue.append(contentsOf: children(element))
        }
        return nil
    }

    private static func normalizedWebURL(_ value: String?) -> String? {
        guard let value, let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url.absoluteString
    }

    /// The focused window's title for a typed row's place label and the
    /// terminal prompt latch (`NativeTypingRoute.place`). One AX read with the
    /// same 25 ms timeout as the proof; nil when it can't be read in time.
    /// Only the window's title: never a field's value, title or selection.
    static func focusedWindowTitle(pid:pid_t)->String? {
        guard Thread.isMainThread,pid>0,AXIsProcessTrusted() else {return nil}
        let app=AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(app,0.025) == .success,let window=element(app,kAXFocusedWindowAttribute),
              AXUIElementSetMessagingTimeout(window,0.025) == .success else {return nil}
        return string(window,kAXTitleAttribute)
    }

    // MARK: - AX attribute plumbing

    private static func selectedRange(_ element: AXUIElement?) -> (location: Int, length: Int)? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return (range.location, range.length)
    }

    private static func element(_ element: AXUIElement?, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func elementAtPoint(_ app: AXUIElement, _ point: CGPoint) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }   // perm-1004
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success else { return nil }
        return element
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func string(_ element: AXUIElement?, _ name: String) -> String? {
        guard let value = attribute(element, name) else { return nil }
        if let s = value as? String { return s }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    private static func attribute(_ element: AXUIElement?, _ name: String) -> CFTypeRef? {
        guard let element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

#if DAYDREAM_OWNER_TYPING
/// The "vendor app with web content" proof's live Accessibility reads
/// (`WebContentFocusWitness`). Compiled only into the owner build: the public
/// build reads no web content in any app and never turns on an app's
/// Accessibility tree (`typing-release-gate-checks.py` scans both binaries).
/// Reads, all metadata: `AXManualAccessibility` on the app (set once per
/// process, never `AXEnhancedUserInterface`), whether the node is editable
/// (`AXEditableAncestor`), the web area's own `AXURL` (compared with the
/// vendor's page, never saved), and deny-only field labels (placeholder,
/// description, DOM id and classes), which only ever refuse. Never a value,
/// selection or title.
enum WebContentAXReader {
    static let manualAccessibility="AXManualAccessibility"
    private static let witness=WebContentFocusWitness<AXUIElement>()
    private static let manualSwitch=ManualAccessibilitySwitch()
    static func invalidate() {witness.invalidate()}
    static func read(app:AXUIElement,pid:pid_t,bundle:String,web:TypingWebContent,generation:UInt64,policyVersion:UInt64,
                     access:NativeFocusAccess<AXUIElement>) -> FocusProof? {
        // Electron and Chromium build their tree only once asked. The key that
        // turns it on is not read (the app builds its tree after the call).
        if web.manualAccessibility {
            guard let identity=access.identity(),manualSwitch.ensure(identity:identity,read:{
                var value:CFTypeRef?
                guard AXUIElementCopyAttributeValue(app,manualAccessibility as CFString,&value) == .success else {return nil}
                return (value as? Bool) ?? false
            },unsupported:{
                // The app has no such attribute (ChatGPT): neither readable nor settable. Never a write then.
                var value:CFTypeRef?,settable:DarwinBoolean=false
                return AXUIElementCopyAttributeValue(app,manualAccessibility as CFString,&value) == .attributeUnsupported
                    && AXUIElementIsAttributeSettable(app,manualAccessibility as CFString,&settable) == .attributeUnsupported && !settable.boolValue
            },write:{
                AXUIElementSetAttributeValue(app,manualAccessibility as CFString,kCFBooleanTrue) == .success
            }) else {witness.invalidate();return nil}
        }
        func copy(_ node:AXUIElement,_ name:String)->(AXError,CFTypeRef?) {
            var value:CFTypeRef?;let result=AXUIElementCopyAttributeValue(node,name as CFString,&value);return (result,value)
        }
        return witness.read(pid:pid,bundle:bundle,generation:generation,policyVersion:policyVersion,access:WebContentAccess(base:access,editable:{
            let (result,value)=copy($0,"AXEditableAncestor")
            if result == .attributeUnsupported || result == .noValue {return false}
            guard result == .success,let value else {return nil}
            return CFGetTypeID(value)==AXUIElementGetTypeID()
        },url:{
            let (result,value)=copy($0,"AXURL")
            if result == .attributeUnsupported || result == .noValue {return .some(nil)}
            guard result == .success,let value else {return nil}
            if let url=value as? URL {return .some(url.absoluteString)}
            if let text=value as? String {return .some(text)}
            return nil
        },label:{node in
            // gold/int S2: fail closed. An attribute the field doesn't have (unsupported, no value) adds nothing; any
            // other error, or a value of an unexpected type, makes the whole label unreadable (nil), and the field is
            // refused.
            LabelAttributeRead.join(["AXPlaceholderValue","AXDescription","AXDOMIdentifier","AXDOMClassList"].map { name in
                let (result,value)=copy(node,name)
                if result == .attributeUnsupported || result == .noValue {return .absent}
                guard result == .success else {return .unreadable}
                guard let value else {return .absent}
                if name == "AXDOMClassList" {return (value as? [String]).map {.list($0)} ?? .unreadable}
                return (value as? String).map {.text($0)} ?? .unreadable
            })
        },composerLabels:{node in
            // fix/app-coverage: asked only in Slack and Discord (the witness checks the app's page is a chat host).
            ["AXDescription","AXPlaceholderValue"].compactMap { name in
                let (result,value)=copy(node,name)
                return result == .success ? value as? String : nil
            }
        }))
    }
}
#endif
