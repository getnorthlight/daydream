import SwiftUI
import AppKit
import WriterBackend
import MemoryUI

actor RenderKeys:WriterSecureKeyStore {
    func readSecret() async throws -> String {throw WriterFailure.unavailable}
    func saveSecret(_ value:String) async throws {throw WriterFailure.unavailable}
    func removeSecret() async throws {throw WriterFailure.unavailable}
}
@main struct SettingsRender {
    @MainActor static func main() throws {
        _=NSApplication.shared;NSApp.setActivationPolicy(.accessory)
        let output=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let fixture=URL(fileURLWithPath:"/private/tmp/macmem-no-store-render-"+UUID().uuidString)
        let writer=WriterIntegration(modelRoot:fixture,keyStore:RenderKeys(),send:{_ in throw WriterFailure.unavailable})
        let history=MemoryFlows(home:fixture),backup=BackupSettingsModel(home:fixture)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:480),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        defer {window.orderOut(nil)}
        for (name,view) in [("writer",AnyView(WriterPreferences(writer:writer))),("cloud",AnyView(WriterPreferences(writer:writer,initialMode:"Cloud"))),("history",AnyView(MemoryHistorySettings(flow:history))),("backup-unavailable",AnyView(BackupSettingsView(model:backup)))] {
            for dark in [false,true] {for (w,h) in [(680,480),(1280,800)] {
                window.appearance=NSAppearance(named:dark ? .darkAqua:.aqua)
                let host=NSHostingView(rootView:view);window.contentView=host;window.setContentSize(NSSize(width:w,height:h));window.makeKeyAndOrderFront(nil)
                host.frame=NSRect(x:0,y:0,width:w,height:h);RunLoop.main.run(until:Date().addingTimeInterval(0.15));host.layoutSubtreeIfNeeded()
                let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds)!;host.cacheDisplay(in:host.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("\(name)-\(w)x\(h)-\(dark ? "dark":"light").png"))
            }}
        }
        print("16 settings renders; inert fake keys/HTTP, no store created")
    }
}
