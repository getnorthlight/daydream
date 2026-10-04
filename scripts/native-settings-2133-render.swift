import SwiftUI
import AppKit
import MemoryUI
import WriterBackend
actor DisabledRenderKeys:WriterSecureKeyStore {
    func readSecret() async throws -> String {throw WriterFailure.denied}
    func saveSecret(_ value:String) async throws {throw WriterFailure.denied}
    func removeSecret() async throws {throw WriterFailure.denied}
}
@main struct NativeSettingsRender {
    @MainActor static func main() throws {
        guard (2...3).contains(CommandLine.arguments.count) else {fatalError("Explicit temporary output path required")}
        let output=URL(fileURLWithPath:CommandLine.arguments[1]);precondition(output.path.hasPrefix("/private/tmp/"))
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        _=NSApplication.shared;NSApp.setActivationPolicy(.accessory)
        let writer=WriterIntegration(modelRoot:output.appendingPathComponent("unused-models"),keyStore:DisabledRenderKeys(),send:{_ in throw WriterFailure.denied})
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:600),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        defer{window.orderOut(nil)}
        let catalog=CommandLine.arguments.last == "--installed-apps" ? LocalApp.catalog() : (0..<16).map{LocalApp(id:"com.example.app\($0)",name:"Sample app \($0+1)")}
        for section in ["Recording","Memory","Shell"] {for dark in [false,true] {for size in [(680,480),(900,600),(1280,800)] {
            let content=Group {
              if section=="Shell" {MemoryShell(browser:ActivityBrowser(phase:.ready),state:CapturePresentation(title:"Stopped"),actions:CaptureActions())}
              else {SettingsFrame(selection:.constant(section)) {_ in
                if section=="Recording" {AppExclusionSettings(typing:.constant(false),excluded:.constant("com.example.excluded"),dirty:false,status:"Development Trial · recording unavailable",fixtures:catalog,allowTyping:false,expandedInitially:true,recordingControl:AnyView(RecordingMasterControl(state:CapturePresentation(title:"Development Trial · OFF"),actions:CaptureActions())),save:{},review:{})}
                else {WriterPreferences(writer:writer,initialMode:"On this Mac",available:false)}
              }}
            }.frame(width:CGFloat(size.0),height:CGFloat(size.1)).transaction {$0.disablesAnimations=true}
            let host=NSHostingView(rootView:content);window.contentView=host
            window.appearance=NSAppearance(named:dark ? .darkAqua:.aqua);window.setContentSize(NSSize(width:size.0,height:size.1));window.makeKeyAndOrderFront(nil)
            host.frame=NSRect(x:0,y:0,width:size.0,height:size.1);RunLoop.main.run(until:Date().addingTimeInterval(0.2));host.layoutSubtreeIfNeeded()
            guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {fatalError("No bitmap")};host.cacheDisplay(in:host.bounds,to:bitmap)
            precondition(bitmap.pixelsWide>=size.0 && bitmap.pixelsHigh>=size.1,"Reject collapsed/non-whole Settings render")
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("\(section)-\(size.0)-\(dark ? "dark":"light").png"))
        }}}
        precondition(!writer.busy && !writer.ready && writer.provider=="off" && !writer.cloudEnabled)
        precondition(!FileManager.default.fileExists(atPath:output.appendingPathComponent("unused-models").path))
        print("PASS 18 native Settings/shell renders, animations disabled; no writer setup, model directory, keys or HTTP.")
    }
}
