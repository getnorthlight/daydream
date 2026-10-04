import Foundation

/// One focus sample. No Chrome content: only who is frontmost, who really has
/// keyboard focus (system-wide AXFocusedApplication), and whether a launcher
/// panel window (by owner bundle and size, never its title) is on screen.
public struct FocusSample: Codable {
    public var ms: Double
    public var frontIsChrome: Bool
    public var focusedIsChrome: Bool
    public var focusedBundle: String?
    public var panels: [String]
    public var secureInput: Bool
    /// Bundle of the frontmost app (native-editors step).
    public var frontBundle: String?
    /// How long the system-wide focused-app read took (review C10).
    public var focusReadMs: Double?
    public init(ms: Double, frontIsChrome: Bool, focusedIsChrome: Bool, focusedBundle: String?, panels: [String], secureInput: Bool,
                frontBundle: String? = nil, focusReadMs: Double? = nil) {
        self.ms = ms; self.frontIsChrome = frontIsChrome; self.focusedIsChrome = focusedIsChrome
        self.focusedBundle = focusedBundle; self.panels = panels; self.secureInput = secureInput
        self.frontBundle = frontBundle; self.focusReadMs = focusReadMs
    }
}

public struct FocusSummary: Codable {
    public var samples = 0
    public var chromeFront = 0
    /// Chrome frontmost but another app has keyboard focus: the Spotlight case, detected.
    public var focusElsewhereWhileChromeFront = 0
    /// Chrome frontmost with a launcher panel steadily on screen (ground truth).
    public var panelWhileChromeFront = 0
    /// ...of which the system-wide check still said "Chrome": a leak.
    public var leaks = 0
    public var focusedBundles: [String: Int] = [:]
    public var panelBundlesSeen: [String] = []
    /// Review C10: samples with TextEdit or Notes frontmost, and of those, how
    /// many had the system-wide focused app equal to the frontmost app.
    public var nativeFront = 0
    public var nativeAgree = 0
    public var nativeFrontBundles: [String] = []
    public var focusReadStats: Stats?

    /// A panel sample counts only when the panel is on screen in the samples
    /// before and after too, so open/close animations don't count.
    public static func of(_ s: [FocusSample]) -> FocusSummary {
        var f = FocusSummary()
        f.samples = s.count
        var seen = Set<String>()
        var native = Set<String>()
        for (i, x) in s.enumerated() {
            if let b = x.focusedBundle { f.focusedBundles[b, default: 0] += 1 }
            seen.formUnion(x.panels)
            if let front = x.frontBundle, Harness.nativeEditors.contains(front) {
                f.nativeFront += 1
                native.insert(front)
                if x.focusedBundle == front { f.nativeAgree += 1 }
            }
            guard x.frontIsChrome else { continue }
            f.chromeFront += 1
            if !x.focusedIsChrome { f.focusElsewhereWhileChromeFront += 1 }
            let steady = i > 0 && i + 1 < s.count && !x.panels.isEmpty
                && !Set(x.panels).isDisjoint(with: s[i - 1].panels) && !Set(x.panels).isDisjoint(with: s[i + 1].panels)
            if steady {
                f.panelWhileChromeFront += 1
                if x.focusedIsChrome { f.leaks += 1 }
            }
        }
        f.panelBundlesSeen = seen.sorted()
        f.nativeFrontBundles = native.sorted()
        f.focusReadStats = Stats.of(s.compactMap(\.focusReadMs))
        return f
    }
}

/// One sample of the Cmd+Shift+N race: window counts on both sides. Geometry
/// and subroles only; nothing is read from the new window.
public struct RaceSample: Codable {
    public var ms: Double
    /// Windows in the Apple Events list at this sample.
    public var aeListed: Int
    /// Standard windows in Chrome's AXWindows (nil: unreadable, which the join denies).
    public var axStandard: Int?
    /// Focus had moved off the old window.
    public var focusMoved: Bool
    /// The new window was in the Apple Events list.
    public var newListed: Bool
    /// The focused window was one of the AXWindows elements.
    public var focusedInAXList: Bool?
    public init(ms: Double, aeListed: Int, axStandard: Int?, focusMoved: Bool, newListed: Bool, focusedInAXList: Bool?) {
        self.ms = ms; self.aeListed = aeListed; self.axStandard = axStandard; self.focusMoved = focusMoved
        self.newListed = newListed; self.focusedInAXList = focusedInAXList
    }
    /// Keys would go to a window Apple Events has not listed.
    public var dangerous: Bool { focusMoved && !newListed }
    /// The join's window count (review I1) would deny: an AX standard window
    /// more than listed, or AXWindows unreadable.
    public var caught: Bool { axStandard.map { $0 > aeListed } ?? true }
}

/// How long after an Incognito window takes focus it shows up in Chrome's
/// Apple Events window list with its mode, and whether the join's window
/// count covers the gap.
public struct RaceResult: Codable {
    public var axChangedMs: Double?
    public var aeListedMs: Double?
    public var newWindowMode: String?
    public var timedOut: Bool
    public var samples: [RaceSample]
    public var lagMs: Double? {
        guard let a = axChangedMs, let e = aeListedMs else { return nil }
        return max(0, e - a)
    }
    public var dangerousSamples: Int { samples.filter(\.dangerous).count }
    public var uncaughtSamples: Int { samples.filter { $0.dangerous && !$0.caught }.count }
    public init(axChangedMs: Double?, aeListedMs: Double?, newWindowMode: String?, timedOut: Bool, samples: [RaceSample] = []) {
        self.axChangedMs = axChangedMs; self.aeListedMs = aeListedMs; self.newWindowMode = newWindowMode; self.timedOut = timedOut
        self.samples = samples
    }
}

/// Closing an Incognito window whose page asks "Leave site?" (review I1).
public struct ClosingResult: Codable {
    /// When the Incognito window left the Apple Events list (nil: it never did).
    public var aeDroppedMs: Double?
    /// For each join, whether the Incognito window was listed just before it.
    public var incognitoListed: [Bool]
    /// The owner confirmed the dialog stayed open until the Glass sound.
    public var dialogConfirmed: Bool?
    public init(aeDroppedMs: Double?, incognitoListed: [Bool], dialogConfirmed: Bool?) {
        self.aeDroppedMs = aeDroppedMs; self.incognitoListed = incognitoListed; self.dialogConfirmed = dialogConfirmed
    }
}
