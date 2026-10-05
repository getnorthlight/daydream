#if DAYDREAM_CHROME_TYPING
// Compiled only with -DDAYDREAM_CHROME_TYPING: every release build defines it; a plain swift build leaves this file out.
//
// claude/axjoin-1005: the Accessibility-only Incognito/Guest check of the window a key goes to, and the version gate of
// the Accessibility join (`BrowserTypingJoin.read`, `viaAccessibility`). Defense in depth: the join still reads every
// window's mode by Apple Events first (`mode of every window`, every Space, fullscreen included); this check runs after
// that and can only refuse. Two independent signals, either one refuses:
//   1. the window's accessible title carries Chrome's own Incognito/Guest tag (IDS_ACCESSIBLE_INCOGNITO_WINDOW_TITLE_FORMAT,
//      IDS_ACCESSIBLE_GUEST_WINDOW_TITLE_FORMAT, every one of Chrome's 55 UI languages);
//   2. the window's toolbar profile button (Chromium view class AvatarToolbarButton): it must exist (no button is not
//      proven normal: popups, Picture-in-Picture, automation contexts, the profile picker), and its title is Chrome's
//      Incognito/Guest button label in any language. An accessible description (AXCustomContent, read for presence only,
//      never decoded) leaves the window unproven: the full Apple Events join decides.
// Evidence: wd-claude-axurl-research (Chrome 154.0.8037.93, macOS 26.5.2): normal, multi-profile, Incognito (3 profiles),
// Guest, an Incognito popup, Incognito fullscreen, Incognito Document Picture-in-Picture, a DevTools-protocol
// off-the-record context, 11 UI languages live: no Incognito or Guest window passed both signals.
import Foundation

public enum ChromePrivateWindow {
    /// Chrome's Incognito and Guest window-title tags (the format with its "$1" removed), every UI language of Chrome
    /// 154 (`locale.pak` resources 11443 and 11444 of 154.0.8037.58 and 154.0.8037.93). A title ending in one is private.
    public static let titleTags: [String] = [
        "(Anonimno)", "(Anonymní režim)", "(Bisita)", "(Gas)", "(Gast)", "(Gizli mod)", "(Gost)", "(Guest)", "(Hali fiche)", "(In incognito)",
        "(Incognito)", "(Incògnit)", "(Incógnito)", "(Inkognito režīms)", "(Inkognito)", "(Inkognitó mód)", "(Khách)", "(Külaline)",
        "(Mgeni)", "(Misafir)", "(Modo anônimo)", "(Navegação anónima)", "(Navigation privée)", "(Ospite)", "(Samaran)", "(Tamu)", "(Tetamu)",
        "(anonimni način)", "(anonym)", "(convidado)", "(convidat)", "(gast)", "(gjest)", "(gost)", "(gość)", "(gäst)", "(gæst)", "(host)",
        "(hosť)", "(incógnito)", "(invitado)", "(invitat)", "(invité)", "(svečias)", "(vendég)", "(vieras)", "(viesa režīms)", "(visitante)",
        "(Ανώνυμη περιήγηση)", "(Επισκέπτης)", "(Анонімний перегляд)", "(Инкогнито)",
        "(без архивирања)", "(гост)", "(гость)", "(гість)", "(инкогнито)", "(אורח)", "(גלישה בסתר)",
        "(التصفح المتخفي)", "(مهمان)", "(مہمان)", "(ناشناس)", "(وضع الضيف)", "(پوشیدگی)",
        "(अतिथी)", "(गुप्त)", "(मेहमान)", "(অতিথি)", "(ছদ্মবেশী)", "(અતિથિ)",
        "(છૂપી)", "(கெஸ்ட்)", "(மறைநிலை)", "(అజ్ఞాతంగా)", "(గెస్ట్)",
        "(ಅತಿಥಿ)", "(ಅದೃಶ್ಯ)", "(അതിഥി)", "(ആള്‍മാറാട്ടം)",
        "(ผู้มาเยือน)", "(โหมดไม่ระบุตัวตน)", "(ማንነትን የማያሳውቅ)",
        "(እንግዳ)", "(Ẩn danh)", "(無痕模式)", "(訪客)", "(게스트)", "(시크릿 모드)", "（ゲスト）",
        "（シークレット モード）", "（无痕）", "（访客）"
    ]
    /// Chrome's Incognito and Guest profile-button labels (resources 2403 and 2400, every plural form, every UI
    /// language; "#" stands for any number).
    public static let buttonLabels: Set<String> = [
        "# окна в режиме инкогнито", "# окно в режиме инкогнито",
        "# окон в режиме инкогнито", "# نافذة للتصفُّح المتخفي",
        "# نوافذ للتصفُّح المتخفي", "Anonimni način", "Anonimni način (#)", "Anonimno", "Anonimno (#)", "Anonymní",
        "Anonymní (#)", "Anônima", "Anônima (#)", "Anônimas (#)", "Bisita", "Bisita (#)", "Convidado", "Convidado (#)", "Convidat",
        "Convidat (#)", "Dirisha fiche", "Gas", "Gas (#)", "Gast", "Gast (#)", "Gizli mod", "Gizli mod (#)", "Gjest", "Gjest (#)", "Gost",
        "Gost (#)", "Gość", "Gość (#)", "Guest", "Guest (#)", "Gäst", "Gäst (#)", "Gäste (#)", "Gæst", "Gæst (#)", "Host", "Host (#)",
        "Hosť", "Hosť (#)", "In incognito", "In incognito (#)", "Incognito", "Incognito (#)", "Incògnit", "Incògnit (#)", "Incógnito",
        "Incógnito (#)", "Inkognito", "Inkognito (#)", "Inkognito režimas", "Inkognito režimas (#)", "Inkognito (#)", "Inkognitó",
        "Inkognitó (#)", "Invitado", "Invitado (#)", "Invitat", "Invitați (#)", "Invité", "Invité (#)", "Khách", "Khách (#)", "Külaline",
        "Külaline (#)", "Madirisha fiche (#)", "Mgeni", "Mgeni (#)", "Misafir", "Misafir (#)", "Navegação anónima", "Navegação anónima (#)",
        "Navigation privée", "Navigation privée (#)", "Ospite", "Ospite (#)", "Samaran", "Samaran (#)", "Svečias", "Svečias (#)", "Tamu",
        "Tamu (#)", "Tetamu", "Tetamu (#)", "Vendég", "Vendég (#)", "Vieras", "Vieras (#)", "Viesis", "Viesi (#)", "Visitante", "Visitante (#)",
        "Visitantes (#)", "Ανώνυμη περιήγηση", "Ανώνυμη περιήγηση (#)", "Επισκέπτης",
        "Επισκέπτης (#)", "Без архивирања", "Без архивирања (#)",
        "Вікна в режимі анонімного перегляду (#)",
        "Вікно в режимі анонімного перегляду", "Гост", "Гост (#)", "Гость", "Гость (#)",
        "Гість", "Гість (#)", "Окно в режиме инкогнито", "אנונימי", "אנונימי (#)", "מצב אורח",
        "מצב אורח (#)", "حالت ناشناس", "حالت ناشناس (#)", "مهمان", "مهمان (#)", "مہمان", "مہمان (#)",
        "نافذة ضيف", "نافذة ضيف (#)", "نافذة واحدة للتصفُّح المتخفي",
        "نافذتان للتصفُّح المتخفي (#)", "پوشیدگی", "پوشیدگی (#)", "अतिथी", "अतिथी (#)",
        "गुप्त", "गुप्त (#)", "मेहमान", "मेहमान (#)", "গেস্ট", "গেস্ট (#)",
        "ছদ্মবেশী মোড", "ছদ্মবেশী মোড (#)", "અતિથિ", "અતિથિ (#)",
        "છૂપો મોડ", "છૂપો મોડ (#)", "மறைநிலைச் சாளரங்கள் (#)",
        "மறைநிலைச் சாளரம்", "விருந்தினர்", "விருந்தினர் (#)",
        "అజ్ఞాతం", "అజ్ఞాతం (#)", "గెస్ట్", "గెస్ట్ (#)", "ಅಜ್ಞಾತ",
        "ಅಜ್ಞಾತ (#)", "ಅತಿಥಿ", "ಅತಿಥಿಗಳು (#)", "അതിഥി", "അതിഥി (#)",
        "അദൃശ്യ മോഡ്", "അദൃശ്യ മോഡ് (#)", "ผู้มาเยือน",
        "ผู้มาเยือน (#)", "ไม่ระบุตัวตน", "ไม่ระบุตัวตน (#)",
        "ማንነት የማያሳውቅ", "ማንነት የማያሳውቅ (#)", "እንግዳ", "እንግዳ (#)", "Ẩn danh", "Ẩn danh (#)",
        "„Инкогнито“", "„Инкогнито“ (#)", "ゲスト", "ゲスト（#）", "シークレット",
        "シークレット（#）", "无痕模式", "无痕模式（已打开 # 个窗口）", "無痕視窗", "無痕視窗 (#)", "訪客",
        "訪客 (#)", "访客", "访客 (#)", "게스트", "게스트(#)", "시크릿 모드", "시크릿 모드(창 #개)"
    ]
    /// The Chromium view classes the profile button search walks through: the browser frame down to the toolbar, and
    /// the overlay that holds the toolbar in fullscreen. Nothing else is entered (never a web area, the tab strip or the
    /// page's own views), so a page's own `class` attribute can't stand in for Chrome's button.
    public static let buttonClass = "AvatarToolbarButton", toolbarClass = "ToolbarView"
    static let pathClasses: Set<String> = ["BrowserRootView", "NonClientView", "BrowserFrameView", "BrowserView", "TopContainerView",
                                           "ToolbarView", "RootView", "TopContainerOverlayView"]
    static let containerRoles: Set<String> = ["AXGroup", "AXToolbar"]
    /// Bounds of the profile-button search: elements looked at, and depth below the window.
    public static let maxNodes = 160, maxDepth = 9

    public enum Verdict: Equatable, Sendable {
        case normal
        /// Signal 1 or 2 said Incognito or Guest.
        case privateWindow
        /// The button could not be found or read: not proven normal.
        case unproven
    }

    /// The window title's tag (signal 1). Pure.
    public static func titleTagged(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return titleTags.contains { t.hasSuffix($0) }
    }
    /// A profile-button label, any number written as "#".
    public static func privateLabel(_ label: String) -> Bool {
        var out = "", inDigits = false
        for s in label.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if s.properties.numericType == .decimal { if !inDigits { out += "#" }; inDigits = true } else { out.unicodeScalars.append(s); inDigits = false }
        }
        return buttonLabels.contains(out)
    }

    /// Both signals for one window, whose title was already read (`title`). Reads only roles, view classes, children,
    /// the button's parent, title and whether it has a description. nil from any read, or `late()`, is `unproven`.
    public static func check<Node>(window: Node, title: String, ax: ChromeAXAccess<Node>, cached: Node? = nil,
                                   late: () -> Bool) -> (verdict: Verdict, button: Node?) {
        if titleTagged(title) { return (.privateWindow, nil) }
        guard let classes = ax.viewClasses, let described = ax.described else { return (.unproven, nil) }
        var buttons: [Node] = []
        if let cached, ax.parent(cached).map({ classes($0)?.contains(toolbarClass) == true }) == true,
           classes(cached)?.contains(buttonClass) == true {
            buttons = [cached]
        } else {
            // Breadth-first from the window through containers only: a child is looked at (role and classes), and
            // entered only when it is a container on the frame's path (an unnamed group only right below the window,
            // where fullscreen hosts the toolbar overlay).
            var queue: [(Node, Int)] = [(window, 0)], looked = 0
            while !queue.isEmpty {
                if late() { return (.unproven, nil) }
                let (node, depth) = queue.removeFirst()
                guard let kids = ax.children(node) else { return (.unproven, nil) }
                for kid in kids {
                    looked += 1
                    guard looked <= maxNodes, let cls = classes(kid), let role = ax.role(kid) else { return (.unproven, nil) }
                    if cls.contains(buttonClass) {
                        if !buttons.contains(where: { ax.equal($0, kid) }) { buttons.append(kid) }
                        continue
                    }
                    guard depth + 1 < maxDepth, containerRoles.contains(role) else { continue }
                    if !pathClasses.isDisjoint(with: cls) || (cls.isEmpty && depth == 0) { queue.append((kid, depth + 1)) }
                }
            }
        }
        guard !buttons.isEmpty else { return (.unproven, nil) }
        var label: String?, anyDescribed = false
        for b in buttons {
            if late() { return (.unproven, nil) }
            guard let p = ax.parent(b), classes(p)?.contains(toolbarClass) == true else { return (.unproven, nil) }
            guard let t = ax.title(b) else { return (.unproven, nil) }
            if privateLabel(t) { return (.privateWindow, nil) }
            guard let d = described(b) else { return (.unproven, nil) }
            // A description is not proof of a private window: a normal window's button carries one for a few seconds
            // after Chrome starts (live, Chrome 154). With a normal title and label it leaves the window unproven,
            // so the join is the full Apple Events join, whose mode read decides.
            if d { anyDescribed = true }
            if let l = label, l != t { return (.unproven, nil) }
            label = t
        }
        if anyDescribed { return (.unproven, nil) }
        return (.normal, buttons[0])
    }
}

/// claude/axjoin-1005: which Chrome builds the Accessibility join is validated on. Any other build takes the full Apple
/// Events join, unchanged. A new Chrome major is added only after the private-window matrix passes on it.
public enum ChromeAXJoinPolicy {
    public static let validatedMajors: Set<Int> = [154]
    /// Process switch for checks and the device benchmark (true in production).
    public static var enabled = true
    public static func validated(_ facts: ChromeTargetFacts) -> Bool {
        guard enabled, let v = facts.bundleVersion, let major = ChromeTargetPolicy.majorVersion(v), validatedMajors.contains(major) else { return false }
        return facts.frameworkVersions.allSatisfy { ChromeTargetPolicy.majorVersion($0).map(validatedMajors.contains) == true }
    }
}
#endif
