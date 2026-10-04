// Maintainer tool (not shipped): rasterize one downloaded favicon (ICO, PNG, SVG, WebP…) to a square
// PNG of at most 128 px. Usage: rasterize <in> <out.png>. Prints "<pixels>" on success.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let data = FileManager.default.contents(atPath: args[1]), let image = NSImage(data: data) else {
    FileHandle.standardError.write("unreadable\n".data(using: .utf8)!); exit(1)
}
let reps = image.representations
let isVector = reps.contains { $0.pixelsWide == 0 || String(describing: type(of: $0)).contains("SVG") || $0 is NSPDFImageRep }
let largest = reps.max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
let native = isVector ? 128 : min(largest?.pixelsWide ?? 0, largest?.pixelsHigh ?? 0)
guard native >= 16 else { FileHandle.standardError.write("too small\n".data(using: .utf8)!); exit(1) }
let px = min(128, native)
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = NSSize(width: px, height: px)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
let source: NSImageRep = isVector ? (reps.first!) : largest!
let w = CGFloat(isVector ? image.size.width : CGFloat(source.pixelsWide)), h = CGFloat(isVector ? image.size.height : CGFloat(source.pixelsHigh))
// Aspect-fit into the square.
let scale = CGFloat(px) / max(w, h)
let dw = w * scale, dh = h * scale
source.draw(in: NSRect(x: (CGFloat(px) - dw) / 2, y: (CGFloat(px) - dh) / 2, width: dw, height: dh), from: .zero, operation: .copy,
            fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
NSGraphicsContext.restoreGraphicsState()
// Reject an all-transparent render (a failed SVG).
var ink = 0
for y in 0..<px { for x in 0..<px where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { ink += 1 } }
guard ink > px * px / 50 else { FileHandle.standardError.write("blank render\n".data(using: .utf8)!); exit(1) }
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: args[2]))
print(px)
