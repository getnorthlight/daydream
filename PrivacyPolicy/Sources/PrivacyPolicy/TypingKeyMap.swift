import Foundation

/// A keyDown as metadata only: key code, modifier flags and the OS autorepeat
/// bit. Never characters: those are read later, after the focus proof.
/// `fn` is the Fn/Globe modifier (the OS also sets it on arrow, navigation
/// and function keys, so it is only used with letters and digits).
public struct KeyStroke: Sendable, Equatable {
    public var keyCode:Int64, command:Bool, control:Bool, option:Bool, shift:Bool, autorepeat:Bool, fn:Bool
    public init(keyCode:Int64,command:Bool=false,control:Bool=false,option:Bool=false,shift:Bool=false,autorepeat:Bool=false,fn:Bool=false) {
        self.keyCode=keyCode;self.command=command;self.control=control;self.option=option;self.shift=shift;self.autorepeat=autorepeat;self.fn=fn
    }
}

/// The five Option dead keys of the US, ABC and British layouts (the only
/// layouts the native typing proof accepts).
public enum DeadKey: Int64, Sendable {
    case grave=50, acute=14, circumflex=34, tilde=45, diaeresis=32
    var combining:String {switch self {case .grave:"\u{300}";case .acute:"\u{301}";case .circumflex:"\u{302}";case .tilde:"\u{303}";case .diaeresis:"\u{308}"}}
    var spacing:String {switch self {case .grave:"`";case .acute:"\u{B4}";case .circumflex:"\u{2C6}";case .tilde:"\u{2DC}";case .diaeresis:"\u{A8}"}}
    /// Accepts either OS behaviour: when the event already carries the
    /// composed letter it is used unchanged; otherwise the letter is composed
    /// the way the layout does, or the spacing accent is kept before it.
    public func compose(_ next:String) -> String {
        if next == " " || next.isEmpty {return spacing}
        guard next.unicodeScalars.allSatisfy({$0.isASCII}) else {return next}
        if next.count == 1,next.first!.isLetter {
            let composed=(next+combining).precomposedStringWithCanonicalMapping
            if composed.unicodeScalars.count == 1 {return composed}
        }
        return spacing+next
    }
}

/// What a key means for the typed unit, decided from key code, modifiers and
/// the autorepeat bit only. Only `.insert` reads characters.
public enum KeyIntent: Equatable, Sendable {
    /// Read characters after the proof; compose a pending dead key.
    case insert(DeadKey?)
    /// Shift/Option-Return: a soft newline. Nothing is read.
    case insertText(String)
    /// Applied to the unit's model. Leaving the run commits it (`cursor`).
    case edit(TypingOp)
    /// The caret moved somewhere unknown in the same field: live commit.
    case split(SealReason)
    /// Focus may move: seal the unit, settle, then judge where focus went.
    case leave(SealReason,marker:Bool)
    /// Return or keypad Enter: live commit plus a keyboard.submit marker.
    case submit
    /// Cmd-V, Ctrl-Y: live commit plus a keyboard.shortcut marker. Pasted
    /// text is never read.
    case paste
    /// Cmd-Z: the app undid text we cannot see, and how much is unknown (a
    /// whole typing run in the text system, a shorter burst in some web
    /// editors). The whole unsaved unit is dropped, so text that may have
    /// left the screen is never saved (review G72; check C7).
    case retract
    /// Cmd-Shift-Z: the app redid text we cannot see: live commit of what
    /// was typed (`cursor`) plus a marker.
    case redo
    /// A digit picked an accent in the press-and-hold popup: the app
    /// replaced the held letter with this character (derived from key codes,
    /// nothing is read). The host deletes one character and inserts it.
    case accent(String)
    /// Dead key armed, press-and-hold repeat, accent popup key.
    case consume
    /// Cmd-C/B/I/U: text and focus unchanged.
    case noop(marker:Bool)
}

/// Pure key -> intent mapping plus the two pieces of input-method state a tap
/// can model on a direct layout: a pending dead key and the press-and-hold
/// accent popup. The host resets it on every seal and privacy boundary.
public struct TypingKeyMap: Sendable {
    private var deadKey:DeadKey?
    /// The held letter (key code, Shift) while its accent popup is open.
    private var accentPopup:(keyCode:Int64,shift:Bool)?
    public init() {}
    /// Command-Tab (the app switcher) and Command-` (the app's next window) never reach the focused field: they only
    /// move focus, so the host ends the unit as an app or window change (`leave`'s `shortcut` otherwise). The terminal
    /// prompt latch counts a shortcut as an unseen change to the line (owner live test 2026-10-02).
    /// Control-U and Control-C: in a terminal they erase or abandon the shell line (`TypingSession.eraseLine`).
    public static func lineErase(_ k:KeyStroke) -> TypingSession.LineErase? {
        guard k.control,!k.command,!k.option else {return nil}
        switch k.keyCode {case 32: return .kill; case 8: return .interrupt; default: return nil}
    }
    public static func switchReason(_ k:KeyStroke) -> SealReason? {
        guard k.command,!k.control,!k.option else {return nil}
        switch k.keyCode {case 48: return .app; case 50: return .window; default: return nil}
    }
    public mutating func reset() {deadKey=nil;accentPopup=nil}

    static let letters:Set<Int64>=[0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6]
    static let accentLetters:Set<Int64>=[0,8,14,34,37,45,31,1,32,16,6] // a c e i l n o s u y z
    static let digits1to9:[Int64]=[18,19,20,21,23,22,26,28,25]
    static let digit0:Int64=29
    /// The press-and-hold popup of the US, ABC and British layouts, in the
    /// order its number keys pick. Shift-s (no ß, so a different order) is not
    /// mapped: the held letter is kept.
    static let popup:[Int64:[String]]=[
        0:["à","á","â","ä","æ","ã","å","ā"], 8:["ç","ć","č"], 14:["è","é","ê","ë","ē","ė","ę"],
        34:["î","ï","í","ī","į","ì"], 37:["ł"], 45:["ñ","ń"], 31:["ô","ö","ò","ó","œ","ø","ō","õ"],
        1:["ß","ś","š"], 32:["û","ü","ù","ú","ū"], 16:["ÿ"], 6:["ž","ź","ż"]]
    static func accent(_ letter:Int64,shift:Bool,index:Int) -> String? {
        guard let list=popup[letter],index<list.count,!(shift && letter == 1) else {return nil}
        return shift ? list[index].uppercased() : list[index]
    }
    static let navigation:Set<Int64>=[115,119,116,121,114,71]          // Home End PgUp PgDn Help Clear
    static let functionKeys:Set<Int64>=[122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
    static let notText:Set<Int64>=[36,76,48,53,51,117,123,124,125,126]

    public mutating func intent(_ k:KeyStroke,pressAndHold:Bool) -> KeyIntent {
        let chord=k.command || k.control
        if let held=accentPopup {
            // Keys that pick or dismiss an accent in the press-and-hold popup.
            if !chord,let index=Self.digits1to9.firstIndex(of:k.keyCode) {
                accentPopup=nil
                return Self.accent(held.keyCode,shift:held.shift,index:index).map {.accent($0)} ?? .consume
            }
            // Return picks the highlighted accent, which the arrows moved: unknown.
            if !chord,[36,76,53].contains(k.keyCode) {accentPopup=nil;return .consume}
            if !chord,[123,124].contains(k.keyCode) || (k.autorepeat && Self.letters.contains(k.keyCode)) {return .consume}
            accentPopup=nil
        }
        // Fn/Globe with a letter or digit: emoji picker, Dock, Control
        // Centre, Notification Centre, Quick Note, full screen. Focus may move.
        if k.fn,!chord,Self.letters.contains(k.keyCode) || Self.digits1to9.contains(k.keyCode) || k.keyCode == Self.digit0 {
            deadKey=nil;return .leave(.shortcut,marker:true)
        }
        if let pending=deadKey {
            deadKey=nil
            if !chord,k.keyCode == 51 {return .consume} // Backspace removes the marked accent only
            if !chord,!Self.notText.contains(k.keyCode),!Self.navigation.contains(k.keyCode),!Self.functionKeys.contains(k.keyCode) {return .insert(pending)}
        }
        switch k.keyCode {
        case 36,76:
            // summaries/v3: Command- or Control-Return (not both) is the web mail send chord; SendRules decides if it sent.
            if chord {return .leave(k.command != k.control ? .submitChord : .shortcut,marker:true)}
            return k.shift || k.option ? .insertText("\n") : .submit
        case 48,53: return .leave(chord ? .shortcut : .focusKey,marker:chord) // Tab always parks
        case 51:
            if k.command && !k.control {return .edit(.deleteBackward(.line))}
            return .edit(.deleteBackward(k.option && !k.control ? .word : .character))
        case 117:
            if chord {return .leave(.shortcut,marker:true)}
            return .edit(.deleteForward(k.option ? .word : .character))
        case 123,124:
            if k.control {return .leave(.shortcut,marker:true)} // Spaces / Mission Control
            if k.command {return .split(.cursor)}
            let unit:TypingOp.Unit = k.option ? .word : .character
            return .edit(k.keyCode == 123 ? .moveBackward(unit,extend:k.shift) : .moveForward(unit,extend:k.shift))
        case 125,126:
            return k.control ? .leave(.shortcut,marker:true) : .split(.cursor)
        case _ where Self.navigation.contains(k.keyCode) || Self.functionKeys.contains(k.keyCode):
            return chord ? .leave(.shortcut,marker:true) : .split(.cursor)
        default: break
        }
        if k.control && !k.command {
            switch k.keyCode {
            case 4: return .edit(.deleteBackward(.character))                   // Ctrl-H
            case 2: return .edit(.deleteForward(.character))                    // Ctrl-D
            case 40: return .edit(.deleteForward(.line))                        // Ctrl-K
            case 11: return .edit(.moveBackward(.character,extend:k.shift))     // Ctrl-B
            case 3: return .edit(.moveForward(.character,extend:k.shift))       // Ctrl-F
            case 0,14,45,35,31,17,37,9: return .split(.cursor)                  // Ctrl-A E N P O T L V
            case 16: return .paste                                              // Ctrl-Y yank
            case 49: return .leave(.inputSource,marker:true)                    // Ctrl-Space
            default: return .leave(.shortcut,marker:true)
            }
        }
        if k.command {
            let plain = !k.control && !k.option && !k.shift
            switch k.keyCode {
            case 6: return k.shift ? .redo : .retract                   // Cmd-Shift-Z, Cmd-Z
            case 9: return .paste                                       // Cmd-V and paste-and-match-style
            case 7: return plain ? .edit(.cutSelection) : .leave(.shortcut,marker:true)
            case 0: return plain ? .split(.cursor) : .leave(.shortcut,marker:true)
            case 8,11,34,32: return plain ? .noop(marker:true) : .leave(.shortcut,marker:true)
            // summaries/v3: Command-Shift-D is Mail's Send; Command-D alone stays a shortcut.
            case 2: return k.shift && !k.control && !k.option ? .leave(.mailSend,marker:true) : .leave(.shortcut,marker:true)
            default: return .leave(.shortcut,marker:true)
            }
        }
        if k.option && !k.shift,let dead=DeadKey(rawValue:k.keyCode) {deadKey=dead;return .consume}
        if k.autorepeat && pressAndHold && Self.letters.contains(k.keyCode) {
            if Self.accentLetters.contains(k.keyCode) {accentPopup=(k.keyCode,k.shift)}
            return .consume
        }
        return .insert(nil)
    }
}
