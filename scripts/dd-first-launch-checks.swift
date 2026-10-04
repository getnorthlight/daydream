// DD-RECIPE: APP
// The first launch shows the search field (owner, Preview 3: "The first time I opened my app I didn't see the
// search bar"). Reproduces a first launch in process: fresh defaults (no setup finished, no saved window frame), a
// new preview sample (--preview-reseed, in a scratch temporary folder), the scene's own window content
// (`DaydreamMainWindowContent`) in a window with the scene's unified toolbar, created while launch still says
// "Getting ready…". The memory window's toolbar then arrives in a window already laid out, the path that dropped the
// search (the principal item) before. Then a second launch (the model ready before the window) for comparison.
// Never launches the app, never orders a window on screen, never requests a permission; PNGs in DD_CHECK_OUT.
import AppKit
import SwiftUI
import MemoryCore
import MemoryUI

func fail(_ message: String) -> Never {
    fflush(stdout)
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}
@MainActor func expect(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { fail(message()) } else { print("PASS: \(message())"); fflush(stdout) } }
@MainActor func pump(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
@MainActor @discardableResult func wait(_ timeout: Double, _ done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { pump(0.05) }
    return done()
}

/// A window like the memory scene's: `.windowToolbarStyle(.unified(showsTitle: false))`, 1100×720 (`defaultSize`),
/// its SwiftUI toolbar bridged into the window's NSToolbar.
@MainActor func sceneWindow<V: View>(_ root: V) -> (NSWindow, NSHostingView<V>) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.toolbarStyle = .unified
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: root)
    host.sceneBridgingOptions = [.toolbars, .title]
    window.contentView = host
    return (window, host)
}

/// The search trigger's toolbar item: the window toolbar's centred (principal) item, and its width.
@MainActor func searchItem(_ window: NSWindow) -> NSToolbarItem? {
    guard let toolbar = window.toolbar else { return nil }
    return toolbar.items.first { toolbar.centeredItemIdentifiers.contains($0.itemIdentifier) }
}

@MainActor func render(_ window: NSWindow, _ url: URL) {
    guard let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { fail("no bitmap") }
    frame.cacheDisplay(in: frame.bounds, to: rep)
    do { try rep.representation(using: .png, properties: [:])!.write(to: url) } catch { fail("PNG \(url.lastPathComponent): \(error)") }
}

@main struct FirstLaunchChecks {
    @MainActor static func main() throws {
        guard let out = ProcessInfo.processInfo.environment["DD_CHECK_OUT"], !out.isEmpty else { fail("DD_CHECK_OUT is required") }
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil else { fail("CFFIXED_USER_HOME must point at a scratch folder") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { fail("timed out") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let shots = URL(fileURLWithPath: out).appendingPathComponent("first-launch", isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)

        // Fresh: nothing saved by an earlier launch (setup, the window's frame).
        let defaults = UserDefaults.standard
        expect(defaults.object(forKey: "DaydreamOnboardingCompletedV1") == nil, "fresh defaults: setup never finished")
        expect(defaults.object(forKey: "NSWindow Frame " + WindowConfigurator.autosaveName) == nil, "fresh defaults: no saved window frame")
        // First launch: a new sample (in a scratch temporary folder, never the per-user one an installed preview uses),
        // and the window exists while it is seeded ("Getting ready…"), as the scene makes it.
        let scratch = URL(fileURLWithPath: out).appendingPathComponent("first-launch-temp", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        expect(!FileManager.default.fileExists(atPath: PreviewSample.root(temporaryDirectory: scratch).path), "fresh sample: no preview sample before the first launch")
        let session = DaydreamLaunchSession(arguments: ["DayDream", "--preview-sample", PreviewSample.reseedArgument], previewTemporaryDirectory: scratch)
        expect(session.preparing && session.model == nil, "first launch: the window opens while the sample is made")
        let (first, host) = sceneWindow(DaydreamMainWindowContent(session: session))
        pump(0.5); host.layoutSubtreeIfNeeded()
        if session.preparing {
            expect(searchItem(first) == nil, "first launch: no search while getting ready (no toolbar yet)")
            render(first, shots.appendingPathComponent("first-launch-getting-ready.png"))
        }
        wait(240) { !session.preparing }
        guard session.model != nil else {
            var reason = "a second try made it"
            do { _ = try PreviewLaunch.prepare(temporaryDirectory: scratch, reuse: false) } catch { reason = "a second try: \(error)" }
            fail("first launch: no model (\(session.failure ?? "no failure"); \(reason))")
        }
        expect((ProcessInfo.processInfo.environment["MAC_MEM_HOME"] ?? "").hasPrefix(scratch.path), "the first launch's history is the scratch sample")
        wait(5) { searchItem(first) != nil }
        pump(1.0); host.layoutSubtreeIfNeeded()
        let items = first.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        guard let item = searchItem(first) else { fail("first launch: the toolbar has no search (items: \(items))") }
        let width = item.view?.frame.width ?? 0
        expect(width >= 180, "first launch: the search field is in the toolbar, centred, \(Int(width)) pt wide")
        expect(item.isVisible, "first launch: the search field is visible")
        expect((first.toolbar?.items.count ?? 0) >= 4, "first launch: the day stepper, search, recording control and gear are all there (\(items.count) items)")
        render(first, shots.appendingPathComponent("first-launch.png"))
        // A resize keeps it (the field steps down, never disappears).
        first.setContentSize(NSSize(width: 760, height: 560)); pump(0.6); host.layoutSubtreeIfNeeded()
        expect(searchItem(first) != nil, "first launch: the search stays after a resize")
        first.setContentSize(NSSize(width: 1100, height: 720)); pump(0.6)
        expect((searchItem(first)?.view?.frame.width ?? 0) >= 180, "first launch: the field comes back at full width")
        first.contentView = nil; first.close()

        // Second launch: the model is ready when the window is made (the reused sample).
        let (second, host2) = sceneWindow(DaydreamMainWindowContent(session: session))
        pump(1.0); host2.layoutSubtreeIfNeeded()
        expect((searchItem(second)?.view?.frame.width ?? 0) >= 180, "second launch: the search field is in the toolbar")
        render(second, shots.appendingPathComponent("second-launch.png"))
        second.contentView = nil; second.close()
        try? FileManager.default.removeItem(at: scratch)
        print("First launch checks: offscreen only. No app launched, no permission requested, nothing recorded.")
        exit(0)
    }
}
