import AppKit
import Foundation

// Resize the complete supplied artwork. No crop, clipping or redesign.
guard CommandLine.arguments.count == 3 else { fatalError("Pass artwork screenshot and output directory") }
let input = URL(fileURLWithPath:CommandLine.arguments[1])
let output = URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
guard let source = NSImage(contentsOf:input), let cg = source.cgImage(forProposedRect:nil,context:nil,hints:nil), cg.width == cg.height else { fatalError("Expected supplied square PNG artwork") }
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
let artwork = NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height))
func render(_ pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    let context = NSGraphicsContext(bitmapImageRep:rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    NSColor.clear.setFill(); NSRect(x:0,y:0,width:pixels,height:pixels).fill()
    let side = CGFloat(pixels)
    let rect = NSRect(x:0,y:0,width:side,height:side)
    context.imageInterpolation = .high
    artwork.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
let sizes = [16,32,128,256,512]
for size in sizes {
    for scale in [1,2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(size*scale).representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
print("Resized supplied Daydream artwork only. No crop, mask or redesign.")
