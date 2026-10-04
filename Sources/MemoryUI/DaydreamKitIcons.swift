import SwiftUI
import AppKit

// DayDream visual kit: icons (spec §10.9, §10.10, §11). Real app icons from NSWorkspace with a
// monogram fallback, web monograms with a browser badge, moment icons, and the illustrated
// settings-area art lifted from `settings/shared.swift` (the hand is retired: Permissions is a
// shield with a check). Everything sits on the macOS icon grid: the body is 80.5% of the frame.

/// macOS icon grid: the squircle body is 824/1024 of the frame.
let kitIconBody: CGFloat = 0.805

extension Color {
    init(kitHex hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: 1)
    }
}

// MARK: - Real app icons

/// NSWorkspace icons carry many representations; SwiftUI picks the small 1x rep for small frames,
/// which renders soft. Rasterize the 256 px rep once and let SwiftUI downsample it. The mean
/// luminance of the icon's ink decides whether it is a dark icon (it then gets a light ring in dark mode).
///
/// fix/prompt-row: loaded off the main thread. A view asks for an icon; the first ask starts one load per bundle (the
/// app's URL from LaunchServices, its icon, the 256 px raster) on a utility task, and the view draws its monogram until
/// the icon lands, then every icon view redraws once (loads that land together publish once). An icon is only ever
/// the installed app's own, from its bundle on this Mac: no bundled logos, no favicons, no network.
final class KitIconStore: ObservableObject, @unchecked Sendable {
    struct Entry: @unchecked Sendable { let image: NSImage; let dark: Bool }
    enum State { case loaded(Entry), missing, loading }
    /// Its state is read and written on the main actor only (every method below that touches it is @MainActor).
    static let shared = KitIconStore()
    private var cache: [String: Entry] = [:]
    private var missing: Set<String> = []
    private var loading: Set<String> = []
    private var publishQueued = false

    /// The icon if it is loaded; otherwise nil, and a load starts (once per bundle).
    @MainActor static func entry(bundle: String) -> Entry? {
        if case .loaded(let entry) = shared.state(bundle) { return entry }
        return nil
    }

    /// Loaded, known not installed, or loading (a load starts on the first ask).
    @MainActor func state(_ bundle: String) -> State {
        if let hit = cache[bundle] { return .loaded(hit) }
        if missing.contains(bundle) { return .missing }
        if loading.insert(bundle).inserted {
            Task.detached(priority: .utility) { [weak self] in
                let entry = Self.load(bundle)
                await self?.landed(bundle, entry)
            }
        }
        return .loading
    }

    /// Loads these icons now and waits for them (renders and checks; the app never waits).
    @MainActor func preload(_ bundles: [String]) async {
        for bundle in bundles { _ = state(bundle) }
        while bundles.contains(where: { loading.contains($0) }) { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    @MainActor private func landed(_ bundle: String, _ entry: Entry?) {
        loading.remove(bundle)
        if let entry { cache[bundle] = entry } else { missing.insert(bundle) }
        guard !publishQueued else { return }
        publishQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.publishQueued = false
                self?.objectWillChange.send()
            }
        }
    }

    /// Off the main thread: the installed app's icon, rasterized. nil when no such app is on this Mac.
    static func load(_ bundle: String) -> Entry? {
        let url: URL? = bundle.hasPrefix("/") ? URL(fileURLWithPath: bundle) : NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return rasterize(NSWorkspace.shared.icon(forFile: url.path))
    }

    private static func rasterize(_ source: NSImage) -> Entry? {
        let px = 256
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        ctx.imageInterpolation = .high
        NSGraphicsContext.current = ctx
        source.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: px, height: px))
        image.addRepresentation(rep)
        return Entry(image: image, dark: meanLuminance(rep) < 0.3)
    }

    /// Alpha-weighted mean luminance of a premultiplied RGBA bitmap, 0...1.
    static func meanLuminance(_ rep: NSBitmapImageRep) -> Double {
        guard let data = rep.bitmapData, rep.samplesPerPixel >= 4 else { return 1 }
        let row = rep.bytesPerRow, spp = rep.samplesPerPixel
        var lum = 0.0, alpha = 0.0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                let p = data + y * row + x * spp
                let a = Double(p[3]) / 255
                guard a > 0.05 else { continue }
                lum += (0.2126 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.0722 * Double(p[2])) / 255
                alpha += a
            }
        }
        return alpha > 0 ? lum / alpha : 1
    }
}

/// Lettered tile on the icon grid, used when an app isn't installed and for web moments.
struct GridMonogram: View {
    let name: String
    let size: CGFloat
    var body: some View {
        let s = size * kitIconBody
        DaydreamMonogram(name: name, size: s)
            .shadow(color: .black.opacity(0.12), radius: max(0.4, s * 0.03), y: max(0.3, s * 0.02))
            .frame(width: size, height: size)
    }
}

/// An app's real icon by bundle ID (or an absolute .app path), crisp at any size. Falls back to a
/// lettered tile on the icon grid. Dark icons get a 0.5 pt white α.18 ring in dark mode.
public struct AppIcon: View {
    let bundle: String?
    let name: String
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    /// fix/prompt-row: redraws once when icons land (they load off the main thread).
    @ObservedObject private var icons = KitIconStore.shared

    public init(bundle: String?, name: String = "", size: CGFloat = 32) {
        self.bundle = bundle; self.name = name; self.size = size
    }

    private var fallbackName: String {
        if !name.isEmpty { return name }
        guard let bundle else { return "?" }
        return bundle.split(separator: ".").last.map(String.init) ?? bundle
    }

    public var body: some View {
        Group {
            if let bundle, let entry = KitIconStore.entry(bundle: bundle) {
                Image(nsImage: entry.image).resizable().interpolation(.high).antialiased(true)
                    .frame(width: size, height: size)
                    .overlay {
                        if scheme == .dark && entry.dark {
                            let vis = size * kitIconBody
                            RoundedRectangle(cornerRadius: vis * 0.225, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                                .frame(width: vis + 1, height: vis + 1)
                        }
                    }
            } else {
                GridMonogram(name: fallbackName, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Web moments

enum KitBrowsers {
    /// Browsers whose moments are really about a page: they draw as the site's monogram with the
    /// browser as a corner badge.
    static let bundles: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "org.mozilla.firefox", "company.thebrowser.Browser", "company.thebrowser.dia", "com.microsoft.edgemac",
        "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen", "com.kagi.kagimacOS",
        "org.chromium.Chromium"
    ]
    static func isBrowser(_ bundle: String?) -> Bool { bundle.map(bundles.contains) ?? false }

    /// "https://www.github.com/x" → "github.com".
    static func host(_ domain: String) -> String {
        var d = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: d), let host = url.host { d = host }
        if d.hasPrefix("www.") { d.removeFirst(4) }
        return d.isEmpty ? domain : d
    }

    /// Two-label public suffixes common enough to matter for a monogram (`bbc.co.uk` → `bbc`).
    private static let secondLevelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "co.jp", "ne.jp", "or.jp", "ac.jp", "com.au", "net.au", "org.au", "edu.au",
        "co.nz", "org.nz", "co.in", "co.kr", "com.br", "com.cn", "com.hk", "com.tw", "com.sg", "com.mx", "com.ar", "com.tr", "co.za",
        "github.io", "gitlab.io", "pages.dev", "vercel.app", "netlify.app", "herokuapp.com", "blogspot.com"
    ]

    /// The site's own name, for its monogram: the registrable-domain label without subdomains or the
    /// public suffix (`docs.google.com` → `google`, `developer.apple.com` → `apple`,
    /// `bbc.co.uk` → `bbc`). Hosts without a dot and IP addresses are returned as they are.
    static func siteName(_ domain: String) -> String {
        let h = host(domain).lowercased()
        let labels = h.split(separator: ".").map(String.init)
        guard labels.count >= 2, !h.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) else { return h }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if labels.count >= 3 && secondLevelSuffixes.contains(lastTwo) { return labels[labels.count - 3] }
        return labels[labels.count - 2]
    }
}

/// fix/prompt-row (owner: "use the actual logo"): sites whose own Mac app draws the web moment's icon when that app is
/// installed here, by bundle ID, most likely first. The icon is always the installed app's own (NSWorkspace); nothing
/// is bundled or fetched. An AI site with none of its apps installed draws the browser's icon instead of a letter.
enum KitSiteApps {
    static let table: [(host: String, bundles: [String], ai: Bool)] = [
        // The ChatGPT app ships as com.openai.chat and, in current versions, com.openai.codex (APP-COVERAGE).
        ("chatgpt.com", ["com.openai.chat", "com.openai.codex"], true), ("chat.openai.com", ["com.openai.chat", "com.openai.codex"], true),
        ("claude.ai", ["com.anthropic.claudefordesktop"], true),
        ("perplexity.ai", ["ai.perplexity.mac"], true),
        ("gemini.google.com", [], true),
        ("app.slack.com", ["com.tinyspeck.slackmacgap"], false), ("discord.com", ["com.hnc.Discord"], false),
        ("web.whatsapp.com", ["net.whatsapp.WhatsApp"], false), ("notion.so", ["notion.id"], false),
        ("figma.com", ["com.figma.Desktop"], false), ("linear.app", ["com.linear"], false),
        ("open.spotify.com", ["com.spotify.client"], false), ("teams.microsoft.com", ["com.microsoft.teams2"], false),
    ]
    /// The table's row for a domain or URL ("https://www.chatgpt.com/c/1" → chatgpt.com), nil for any other site.
    static func row(_ domain: String) -> (host: String, bundles: [String], ai: Bool)? {
        let h = KitBrowsers.host(domain).lowercased()
        return table.first { h == $0.host || h.hasSuffix("." + $0.host) }
    }
    enum Pick: Equatable { case app(String), browser, monogram, waiting }
    /// What a web moment's tile draws: the site's installed app, else (an AI site) the browser, else the monogram.
    /// `waiting` while an app's icon is still loading (the monogram shows meanwhile).
    @MainActor static func pick(_ domain: String, store: KitIconStore = .shared) -> Pick {
        guard let row = row(domain) else { return .monogram }
        for bundle in row.bundles {
            switch store.state(bundle) {
            case .loaded: return .app(bundle)
            case .loading: return .waiting
            case .missing: continue
            }
        }
        return row.ai ? .browser : .monogram
    }
}

/// Official site favicons, bundled once and loaded once per icon (`SiteIconCatalog`). No history URL is fetched.
/// Optional bundle lookup keeps the letter tile available if a resource is missing in a local build.
enum KitSiteFavicons {
    static let bundleName = SiteIconCatalog.bundleName
    /// The bundled icon for a site, by host or URL, with subdomain and alias normalisation
    /// (`m.youtube.com`, `https://www.reddit.com/`, `outlook.cloud.microsoft` all resolve).
    static func resourceName(_ domain: String) -> String? { SiteIconCatalog.iconName(domain) }
    @MainActor static func image(_ domain: String) -> NSImage? { SiteIconCatalog.image(forSite: domain) }
    @MainActor static func connectionImage(_ id:String) -> NSImage? { SiteIconCatalog.image(named: id) }
}

/// Bundled product branding keeps connection rows recognizable when a CLI
/// has no app bundle or its desktop app is not installed on this Mac.
public struct ConnectionProductIcon: View {
    let id:String
    let size:CGFloat
    public init(id:String,size:CGFloat=30) {self.id=id;self.size=size}
    public var body:some View {
        Group {
            if let image=KitSiteFavicons.connectionImage(id) {
                Image(nsImage:image).resizable().interpolation(.high).scaledToFit()
                    .frame(width:size * kitIconBody,height:size * kitIconBody)
                    .clipShape(RoundedRectangle(cornerRadius:size * 0.18,style:.continuous))
                    .frame(width:size,height:size)
            } else {AppIcon(bundle:nil,name:id,size:size)}
        }.accessibilityHidden(true)
    }
}

/// A web moment: the site's monogram on the icon grid (stable hue), with the browser's real icon as a
/// 0.56× corner badge. The letter and hue come from the site's name, so `docs.google.com` is `G`.
/// A site in `SiteIconCatalog` (about 180 popular sites) uses its bundled official favicon (browser badge kept).
/// fix/prompt-row: a site whose Mac app is installed draws that app's icon (browser badge kept: it was the website);
/// an AI site without its app draws the browser's own icon (`KitSiteApps`).
public struct WebMonogramTile: View {
    let domain: String
    let browserBundle: String?
    let size: CGFloat
    @ObservedObject private var icons = KitIconStore.shared
    public init(domain: String, browserBundle: String?, size: CGFloat = 32) {
        self.domain = domain; self.browserBundle = browserBundle; self.size = size
    }
    /// The monogram's letter for a domain or URL: the site name's initial (`docs.google.com` → `G`).
    public static func monogramLetter(_ domain: String) -> String {
        KitBrowsers.siteName(domain).first.map { String($0).uppercased() } ?? "?"
    }
    public var body: some View {
        Group {
            if let image = KitSiteFavicons.image(domain) {
                // A light plate behind the favicon: transparent dark marks (GitHub, NYT, Docker) stay
                // visible in dark mode; full-bleed icons cover it.
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: size * kitIconBody, height: size * kitIconBody)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius:size * 0.18,style:.continuous))
                    .frame(width: size, height: size)
                    .overlay(alignment: .bottomTrailing) { badge }
            } else {
                switch KitSiteApps.pick(domain, store: icons) {
                case .app(let bundle):
                    AppIcon(bundle: bundle, size: size).overlay(alignment: .bottomTrailing) { badge }
                case .browser where browserBundle != nil:
                    AppIcon(bundle: browserBundle, size: size)
                default:
                    GridMonogram(name: KitBrowsers.siteName(domain), size: size).overlay(alignment: .bottomTrailing) { badge }
                }
            }
        }
        .accessibilityHidden(true)
    }
    @ViewBuilder private var badge: some View {
        if let browserBundle {
            AppIcon(bundle: browserBundle, size: size * 0.56)
                .background(Circle().fill(DaydreamStyle.raised).padding(size * 0.06))
                .offset(x: size * 0.10, y: size * 0.10)
        }
    }
}

/// The icon of a moment: a web monogram for browser moments with a site, otherwise the primary
/// app's icon with the second app as a 0.56× corner badge ringed in the surface colour.
public struct MomentIcon: View {
    public typealias AppRef = (bundle: String?, name: String)
    let apps: [AppRef]
    let site: String?
    let size: CGFloat
    let ring: Color?

    public init(apps: [AppRef], site: String?, size: CGFloat = 32, ring: Color? = nil) {
        self.apps = apps; self.site = site; self.size = size; self.ring = ring
    }

    /// From a Focus List moment: the primary app, the next bundle by actions, the first site.
    public init(moment m: MomentSlice, size: CGFloat = 32, ring: Color? = nil) {
        var refs: [AppRef] = []
        let primary = m.primaryBundle ?? m.bundles.first
        if primary != nil || m.primaryApp != nil || !m.apps.isEmpty {
            refs.append((primary, m.primaryApp ?? (primary == nil ? m.apps.first ?? "" : "")))
        }
        if let second = m.bundles.first(where: { $0 != primary }) { refs.append((second, "")) }
        self.init(apps: refs, site: m.sites.first, size: size, ring: ring)
    }

    public var body: some View {
        Group {
            if let site, apps.isEmpty || KitBrowsers.isBrowser(apps[0].bundle) {
                WebMonogramTile(domain: site, browserBundle: apps.first?.bundle, size: size)
            } else if let first = apps.first {
                AppIcon(bundle: first.bundle, name: first.name, size: size)
                    .overlay(alignment: .bottomTrailing) {
                        if apps.count > 1 { badge(apps[1]) }
                    }
            } else {
                GridMonogram(name: "?", size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func badge(_ app: AppRef) -> some View {
        let b = size * 0.56
        return ZStack {
            RoundedRectangle(cornerRadius: b * kitIconBody * 0.26, style: .continuous).fill(ring ?? DaydreamStyle.raised)
                .frame(width: b * kitIconBody + 3, height: b * kitIconBody + 3)
            AppIcon(bundle: app.bundle, name: app.name, size: b)
        }
        .frame(width: b, height: b)
        .offset(x: size * 0.14, y: size * 0.12)
    }
}

/// Two app icons fanned, for detail heroes. The second is smaller, tilted and behind.
public struct AppFan: View {
    let apps: [MomentIcon.AppRef]
    let size: CGFloat
    public init(apps: [MomentIcon.AppRef], size: CGFloat = 52) { self.apps = apps; self.size = size }
    public var body: some View {
        ZStack(alignment: .topLeading) {
            if apps.count > 1 {
                AppIcon(bundle: apps[1].bundle, name: apps[1].name, size: size * 0.8)
                    .rotationEffect(.degrees(8))
                    .offset(x: size * 0.66, y: size * 0.2)
            }
            if let first = apps.first {
                AppIcon(bundle: first.bundle, name: first.name, size: size)
                    .rotationEffect(.degrees(-4))
                    .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
            }
        }
        .frame(width: size * (apps.count > 1 ? 1.46 : 1), height: size * 1.04, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// Row accessory: a second app ("+ Safari").
public struct AppChip: View {
    let bundle: String?
    let name: String
    let plus: Bool
    public init(bundle: String?, name: String, plus: Bool = true) { self.bundle = bundle; self.name = name; self.plus = plus }
    public var body: some View {
        HStack(spacing: 4) {
            if plus { Image(systemName: "plus").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.tertiary) }
            AppIcon(bundle: bundle, name: name, size: 15)
            Text(name).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.leading, plus ? 7 : 4).padding(.trailing, 8).frame(height: 22)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(plus ? "Also " + name : name)
    }
}

/// Row accessory: the moment's main site.
public struct SiteChip: View {
    let site: String
    public init(site: String) { self.site = site }
    public var body: some View {
        let host = KitBrowsers.host(site)
        HStack(spacing: 5) {
            DaydreamMonogram(name: KitBrowsers.siteName(site), size: 14)
            Text(host).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.leading, 4).padding(.trailing, 8).frame(height: 22)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(host)
    }
}

// MARK: - Icon base and shapes (settings/shared.swift)

/// Big Sur / Tahoe icon grammar: top-lit gradient, 22% sheen to centre, inner rim, soft drop.
struct IconBase<Glyph: View>: View {
    let colors: [Color]
    let size: CGFloat
    let glyph: Glyph
    @Environment(\.colorScheme) private var scheme
    init(colors: [Color], size: CGFloat, @ViewBuilder glyph: () -> Glyph) {
        self.colors = colors; self.size = size; self.glyph = glyph()
    }
    var body: some View {
        let s = size * kitIconBody
        let shape = RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            shape.fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0)], startPoint: .top, endPoint: .center))
            glyph
        }
        .frame(width: s, height: s)
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: max(0.5, s / 90)))
        // Dark appearance: a full 0.5 pt light rim so dark bases don't melt into dark cards.
        .overlay(shape.strokeBorder(Color.white.opacity(scheme == .dark ? 0.16 : 0), lineWidth: 0.5))
        .overlay(shape.stroke(Color.black.opacity(scheme == .dark ? 0.35 : 0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: max(0.6, s * 0.03), y: max(0.4, s * 0.02))
        .frame(width: size, height: size)
    }
}

/// Heater shield.
struct Shield: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height, x = r.minX, y = r.minY
        p.move(to: CGPoint(x: x + w / 2, y: y))
        p.addCurve(to: CGPoint(x: x + w, y: y + h * 0.17), control1: CGPoint(x: x + w * 0.70, y: y + h * 0.11), control2: CGPoint(x: x + w * 0.86, y: y + h * 0.15))
        p.addCurve(to: CGPoint(x: x + w / 2, y: y + h), control1: CGPoint(x: x + w * 1.0, y: y + h * 0.64), control2: CGPoint(x: x + w * 0.80, y: y + h * 0.88))
        p.addCurve(to: CGPoint(x: x, y: y + h * 0.17), control1: CGPoint(x: x + w * 0.20, y: y + h * 0.88), control2: CGPoint(x: x, y: y + h * 0.64))
        p.addCurve(to: CGPoint(x: x + w / 2, y: y), control1: CGPoint(x: x + w * 0.14, y: y + h * 0.15), control2: CGPoint(x: x + w * 0.30, y: y + h * 0.11))
        p.closeSubpath()
        return p
    }
}

/// A check mark drawn as an open polyline in a unit box (stroke it).
struct CheckStroke: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.55))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.37, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

// MARK: - Settings-area art

/// A settings area, drawn as illustrated art on the icon grid.
public enum Area: Hashable, Sendable {
    case permissions, summaries, apps, connections, advanced
    case module(ModuleKind)
}

/// Advanced's small modules.
public enum ModuleKind: String, CaseIterable, Hashable, Sendable {
    case retention, backup, updates, diagnostics, advanced
    var symbol: String {
        switch self {
        case .retention: return "clock.arrow.circlepath"
        case .backup: return "externaldrive.fill"
        case .updates: return "arrow.down"
        case .diagnostics: return "stethoscope"
        case .advanced: return "gearshape.fill"
        }
    }
    var colors: [Color] {
        switch self {
        case .retention: return [Color(kitHex: 0xA08CFF), Color(kitHex: 0x6446E6)]
        case .backup: return [Color(kitHex: 0x6FB7FF), Color(kitHex: 0x2E7BE0)]
        case .updates: return [Color(kitHex: 0x4FD6C4), Color(kitHex: 0x14A08E)]
        case .diagnostics, .advanced: return [Color(kitHex: 0xA4A8B1), Color(kitHex: 0x62666F)]
        }
    }
}

/// Illustrated icon for a settings area. At 24 pt and below the art switches to hinted variants
/// (a heavier check for Permissions).
public struct AreaIcon: View {
    let area: Area
    let size: CGFloat
    public init(_ area: Area, size: CGFloat = 28) { self.area = area; self.size = size }
    public var body: some View {
        Group {
            switch area {
            case .permissions: PermissionsArt(size: size)
            case .summaries: SummariesArt(size: size)
            case .apps: AppsArt(size: size)
            case .connections: ConnectionsArt(size: size)
            case .advanced: AdvancedArt(size: size)
            case .module(.advanced): AdvancedArt(size: size)
            case .module(let kind): ModuleArt(symbol: kind.symbol, colors: kind.colors, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Permissions: a white shield with a blue check. Replaces the retired hand.
struct PermissionsArt: View {
    let size: CGFloat
    var body: some View {
        let s = size * kitIconBody
        let small = size <= 24
        let checkColors = [Color(kitHex: 0x4A9BFF), Color(kitHex: 0x1D5FE0)]
        IconBase(colors: [Color(kitHex: 0x5AA8FF), Color(kitHex: 0x1F66F0)], size: size) {
            ZStack {
                Shield().fill(LinearGradient(colors: [.white, Color(kitHex: 0xDCEAFF)], startPoint: .top, endPoint: .bottom))
                    .frame(width: s * (small ? 0.62 : 0.58), height: s * (small ? 0.72 : 0.68))
                    .shadow(color: Color(kitHex: 0x0B3C9C).opacity(small ? 0.25 : 0.35), radius: s * 0.03, y: s * 0.02)
                CheckStroke()
                    .stroke(LinearGradient(colors: checkColors, startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: max(small ? 1.6 : 1.2, s * (small ? 0.1 : 0.075)), lineCap: .round, lineJoin: .round))
                    .frame(width: s * (small ? 0.28 : 0.25), height: s * (small ? 0.2 : 0.18))
                    .offset(y: -s * 0.02)
            }.offset(y: s * 0.01)
        }
    }
}

/// Summaries: a plain white `text.alignleft` on the dream gradient, as DreamGlyph (no AI sparkle anywhere, r2).
struct SummariesArt: View {
    let size: CGFloat
    var body: some View {
        ModuleArt(symbol: "text.alignleft", colors: [KitPalette.dreamBlue, KitPalette.dreamViolet], size: size)
    }
}

struct IsoLayer: View {
    let colors: [Color]
    let side: CGFloat
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.2, style: .continuous)
        ZStack {
            ZStack { shape.fill(colors.last ?? .blue); shape.fill(Color.black.opacity(0.22)) }
                .frame(width: side, height: side).rotationEffect(.degrees(45)).scaleEffect(x: 1, y: 0.56).offset(y: side * 0.10)
            shape.fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(.white.opacity(0.45), lineWidth: max(0.5, side * 0.02)))
                .frame(width: side, height: side).rotationEffect(.degrees(45)).scaleEffect(x: 1, y: 0.56)
        }
    }
}

struct AppsArt: View {
    let size: CGFloat
    var body: some View {
        let s = size * kitIconBody
        IconBase(colors: [Color(kitHex: 0x3A4190), Color(kitHex: 0x1B1E4A)], size: size) {
            ZStack {
                IsoLayer(colors: [Color(kitHex: 0xFF8DC7), Color(kitHex: 0xE0457F)], side: s * 0.46).offset(y: s * 0.17)
                    .shadow(color: .black.opacity(0.3), radius: s * 0.02, y: s * 0.02)
                IsoLayer(colors: [Color(kitHex: 0xB79BFF), Color(kitHex: 0x7B55F0)], side: s * 0.46).offset(y: s * 0.02)
                    .shadow(color: .black.opacity(0.3), radius: s * 0.02, y: s * 0.02)
                IsoLayer(colors: [Color(kitHex: 0x7CC4FF), Color(kitHex: 0x2F7BF6)], side: s * 0.46).offset(y: -s * 0.13)
                    .shadow(color: .black.opacity(0.3), radius: s * 0.02, y: s * 0.02)
            }.offset(y: -s * 0.01)
        }
    }
}

struct ConnectionsArt: View {
    let size: CGFloat
    var body: some View {
        let s = size * kitIconBody
        IconBase(colors: [Color(kitHex: 0x3EDBA0), Color(kitHex: 0x0E9F6E)], size: size) {
            ZStack {
                ring(s).offset(x: -s * 0.115, y: s * 0.115)
                ring(s).offset(x: s * 0.115, y: -s * 0.115)
                ring(s).offset(x: -s * 0.115, y: s * 0.115)
                    .mask(Rectangle().frame(width: s * 0.2, height: s * 0.2).offset(x: s * 0.06, y: s * 0.02))
            }
        }
    }
    private func ring(_ s: CGFloat) -> some View {
        Capsule()
            .stroke(LinearGradient(colors: [.white, Color(kitHex: 0xDDFBEF)], startPoint: .top, endPoint: .bottom), lineWidth: max(1, s * 0.085))
            .frame(width: s * 0.44, height: s * 0.23)
            .rotationEffect(.degrees(-45))
            .shadow(color: Color(kitHex: 0x05603F).opacity(0.35), radius: s * 0.02, y: s * 0.015)
    }
}

/// Small-module art: white SF Symbol on the icon base.
struct ModuleArt: View {
    let symbol: String
    let colors: [Color]
    let size: CGFloat
    var body: some View {
        let s = size * kitIconBody
        IconBase(colors: colors, size: size) {
            Image(systemName: symbol).font(.system(size: s * 0.5, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.white, Color(kitHex: 0xE4E7EE)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.22), radius: s * 0.03, y: s * 0.02)
        }
    }
}

struct AdvancedArt: View {
    let size: CGFloat
    var body: some View {
        let s = size * kitIconBody
        IconBase(colors: ModuleKind.advanced.colors, size: size) {
            ZStack {
                Image(systemName: "gearshape.fill").font(.system(size: s * 0.62, weight: .regular))
                    .foregroundStyle(LinearGradient(colors: [.white, Color(kitHex: 0xDADDE3)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.25), radius: s * 0.025, y: s * 0.02)
                Circle().fill(LinearGradient(colors: [Color(kitHex: 0x8C9099), Color(kitHex: 0x6A6E77)], startPoint: .top, endPoint: .bottom))
                    .frame(width: s * 0.2, height: s * 0.2)
            }
        }
    }
}

/// "Exclude from Recording": `eye.slash` on a grey icon base (replaces the retired hand).
public struct ExcludeIcon: View {
    let size: CGFloat
    public init(size: CGFloat = 22) { self.size = size }
    public var body: some View {
        ModuleArt(symbol: "eye.slash.fill", colors: [Color(kitHex: 0xA4A8B1), Color(kitHex: 0x62666F)], size: size)
            .accessibilityHidden(true)
    }
}

/// System Settings pane icon for a permission: SF `accessibility` on blue, `keyboard` on grey.
public struct PermissionPaneIcon: View {
    let kind: PermissionKind
    let size: CGFloat
    public init(_ kind: PermissionKind, size: CGFloat = 28) { self.kind = kind; self.size = size }

    /// `accessibility` is SF Symbols 5 (macOS 14) and draws nothing on macOS 13, which gets
    /// `figure.arms.open` (SF Symbols 4) instead.
    public static var accessibilitySymbol: String {
        if #available(macOS 14.0, *) { return "accessibility" }  // SF Symbols 5, gated
        return "figure.arms.open"
    }

    public var body: some View {
        let s = size * kitIconBody
        IconBase(colors: kind == .accessibility ? [Color(kitHex: 0x5AA8FF), Color(kitHex: 0x1F66F0)]
                                               : [Color(kitHex: 0x8E939E), Color(kitHex: 0x4E525C)], size: size) {
            Image(systemName: kind == .accessibility ? Self.accessibilitySymbol : "keyboard")
                .font(.system(size: s * (kind == .accessibility ? 0.58 : 0.5), weight: .medium))
                .foregroundStyle(LinearGradient(colors: [.white, Color(kitHex: 0xE4E7EE)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.2), radius: s * 0.03, y: s * 0.02)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Area state badges (settings/shared.swift:487-509)

/// A settings area's state: needs you (orange !), pending (grey clock), off (grey dash).
public enum BadgeKind: String, CaseIterable, Sendable {
    case attention, pending, off
    public var accessibilityLabel: String {
        switch self {
        case .attention: return "Needs attention"
        case .pending: return "Pending"
        case .off: return "Off"
        }
    }
}

struct AreaStateBadge: View {
    let kind: BadgeKind
    let iconSize: CGFloat
    let ring: Color
    var body: some View {
        let d = max(11, iconSize * 0.34)
        let line = max(1.5, d * 0.12)
        ZStack {
            switch kind {
            case .attention:
                Circle().fill(KitPalette.orange)
                Image(systemName: "exclamationmark").font(.system(size: d * 0.56, weight: .heavy)).foregroundStyle(.white)
            case .pending:
                Circle().fill(Color(nsColor: .systemGray))
                Image(systemName: "clock.fill").font(.system(size: d * 0.62, weight: .semibold)).foregroundStyle(.white)
            case .off:
                Circle().fill(Color(nsColor: .systemGray))
                Capsule().fill(.white).frame(width: d * 0.46, height: max(1.5, d * 0.14))
            }
        }
        .frame(width: d, height: d)
        .overlay(Circle().strokeBorder(ring, lineWidth: line).padding(-line))
        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
    }
}

extension View {
    /// Corner state badge on the squircle body of an icon of `iconSize`. nil draws nothing.
    /// The ring defaults to the window colour; pass the surface colour when the icon sits on a card.
    public func stateBadge(_ kind: BadgeKind?, iconSize: CGFloat = 28, ring: Color? = nil) -> some View {
        overlay(alignment: .topTrailing) {
            if let kind {
                AreaStateBadge(kind: kind, iconSize: iconSize, ring: ring ?? DaydreamStyle.window)
                    .offset(x: -iconSize * 0.02, y: iconSize * 0.02)
                    .accessibilityLabel(kind.accessibilityLabel)
            }
        }
    }
}
