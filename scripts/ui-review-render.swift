import SwiftUI
import AppKit
import MemoryCore
import MemoryUI

@main struct UIReviewRender {
    @MainActor static func main() throws {
        let output=URL(fileURLWithPath:CommandLine.arguments[1])
        precondition(output.path.hasPrefix("/private/tmp/"))
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let root=URL(fileURLWithPath:"/private/tmp/daydream-development-trial-ui-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        for name in ["memory","preferences","backups"] {try FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:false)}
        try Data("synthetic-only\n".utf8).write(to:root.appendingPathComponent("DEVELOPMENT-ONLY"))
        setenv("DAYDREAM_DEVELOPMENT_ROOT",root.path,1)
        setenv("MAC_MEM_HOME",root.appendingPathComponent("memory").path,1)
        setenv("CFFIXED_USER_HOME",root.appendingPathComponent("preferences").path,1)
        let trial=try DevelopmentTrial.validate();try trial.prepare()
        _=NSApplication.shared;NSApp.setActivationPolicy(.accessory)
        let model=MemoryViewModel(development:trial)
        let fixtures=(0..<12).map {LocalApp(id:"com.example.\($0)",name:"Sample app \($0+1)")}
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:600),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        defer {window.orderOut(nil)}
        for dark in [false,true] {for size in [(680,480),(760,600)] {for screen in ["connections","excluded-collapsed","excluded-expanded","permissions"] {
            let view:AnyView
            if screen=="permissions" {
                view=AnyView(RecordingTrialReadiness(model:model,browse:{},settings:{}))
            } else if screen.hasPrefix("connections") {
                view=AnyView(SettingsFrame(selection:.constant("Connections"),close:{}) {_ in
                    ConnectionSettings(model:ConnectionSettingsModel(environment:AIAppConnectEnvironment(userHome:root,applicationFolders:[]),home:root.appendingPathComponent("memory"),pinnedHome:nil,control:InertAIAppControl()))
                })
            } else {
                view=AnyView(SettingsFrame(selection:.constant("Recording"),close:{}) {_ in
                    AppExclusionSettings(typing:.constant(false),excluded:.constant("com.example.1"),dirty:false,status:"",fixtures:fixtures,persistenceAvailable:true,expandedInitially:screen=="excluded-expanded",save:{},review:{})
                })
            }
            window.appearance=NSAppearance(named:dark ? .darkAqua:.aqua)
            let host=NSHostingView(rootView:view.transaction {$0.disablesAnimations=true})
            window.contentView=host;window.setContentSize(NSSize(width:size.0,height:size.1));window.makeKeyAndOrderFront(nil)
            host.frame=NSRect(x:0,y:0,width:size.0,height:size.1)
            RunLoop.main.run(until:Date().addingTimeInterval(0.2));host.layoutSubtreeIfNeeded()
            guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {fatalError("Empty settings view")}
            host.cacheDisplay(in:host.bounds,to:bitmap)
            precondition(bitmap.pixelsWide>=size.0 && bitmap.pixelsHigh>=size.1)
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("\(screen)-\(size.0)-\(dark ? "dark":"light").png"))
        }}}
        precondition(!model.recording && model.development != nil)
        print("PASS: 20 compact/standard settings renders in light/dark; isolated sample memory, recording off.")
    }
}

/// Connections as an empty scratch Mac sees it: no AI app is found, running or opened, and nothing is copied.
private struct InertAIAppControl: AIAppControlling {
    func location(_ app: AIApp, env: AIAppConnectEnvironment) -> URL? { nil }
    @MainActor func running(_ app: AIApp) -> RunningAIApp? { nil }
    func handler(for url: URL) -> String? { nil }
    func lastChange(_ app: AIApp) -> Date? { nil }
    func recordChange(_ app: AIApp, at date: Date) {}
    @MainActor func quit(_ running: RunningAIApp, force: Bool, timeout: TimeInterval) async -> Bool { false }
    @MainActor func reopen(_ url: URL) async -> Bool { false }
    @MainActor func open(_ url: URL) -> Bool { false }
    @MainActor func copy(_ text: String) {}
    @MainActor func observe(_ changed: @escaping @MainActor () -> Void) -> [NSObjectProtocol] { [] }
    @MainActor func stopObserving(_ tokens: [NSObjectProtocol]) {}
}
