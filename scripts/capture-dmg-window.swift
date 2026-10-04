import AppKit
import CoreGraphics
import ScreenCaptureKit
guard CGPreflightScreenCaptureAccess() else { fatalError("Screen capture unavailable; no permission requested") }
let windows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
guard let target=windows.first(where:{ ($0[kCGWindowOwnerName as String] as? String) == "Finder" && ($0[kCGWindowName as String] as? String) == "DayDream" }),
      let id=target[kCGWindowNumber as String] as? UInt32 else { fatalError("Owned DMG Finder window not found") }
let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
guard let window=content.windows.first(where:{$0.windowID == id}) else { fatalError("DMG window not shareable") }
let config=SCStreamConfiguration(); config.width=Int(window.frame.width)*2; config.height=Int(window.frame.height)*2
config.showsCursor=false
let shot:CGImage=try await withCheckedThrowingContinuation { continuation in
    SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:window),configuration:config) { image,error in
        if let image { continuation.resume(returning:image) }
        else { continuation.resume(throwing:error ?? NSError(domain:"DMG capture",code:1)) }
    }
}
try NSBitmapImageRep(cgImage:shot).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
print("Captured Finder DMG window \(id), bounds \(window.frame)")
