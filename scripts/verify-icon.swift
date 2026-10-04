import AppKit
import Foundation
guard CommandLine.arguments.count == 3 else { fatalError("Pass built app and output PNG") }
let app = CommandLine.arguments[1]
guard Bundle(path:app)?.bundleIdentifier == "com.getnorthlight.daydream" else { fatalError("Wrong app") }
// Finder's icon resolution API. Does not launch the app or change Finder/Dock.
let icon = NSWorkspace.shared.icon(forFile:app)
icon.size = NSSize(width:128,height:128)
let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:128,pixelsHigh:128,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
icon.draw(in:NSRect(x:0,y:0,width:128,height:128))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
print("Resolved installed-style bundle icon through NSWorkspace without launching app")
