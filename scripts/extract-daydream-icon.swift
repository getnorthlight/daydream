import AppKit
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 3 else { fatalError("Usage: extract.swift original.png new-output.png") }
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let bytes = try Data(contentsOf: input)
let sha = SHA256.hash(data: bytes).map { String(format:"%02x",$0) }.joined()
guard sha == "9b28b6b7b7690106f1ec85f9c5a742ed64fe212a8a1ca4a90a63d9b66deb2060",
      let source = NSBitmapImageRep(data: bytes), source.pixelsWide == 1254,
      source.pixelsHigh == 1254, source.bitsPerSample == 8, source.samplesPerPixel == 3,
      !FileManager.default.fileExists(atPath:output.path)
else { fatalError("Unexpected source or output already exists; no changes made") }
let side = source.pixelsWide
let result = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:side,pixelsHigh:side,
    bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
    colorSpaceName:source.colorSpaceName,bitmapFormat:.alphaNonpremultiplied,
    bytesPerRow:0,bitsPerPixel:0)!
// Trace inside the original tile edge. Preserve framing and every RGB value.
// These measured coordinates apply ONLY to the pinned original artwork above.
let left=83.0, top=80.0, right=1170.0, bottom=1154.0, radius=300.0
let cx=(left+right)/2, cy=(top+bottom)/2
let hx=(right-left)/2, hy=(bottom-top)/2
var before=[UInt](repeating:0,count:3),after=[UInt](repeating:0,count:4)
var edgeCount=0, clearCount=0, opaqueCount=0
for y in 0..<side { for x in 0..<side {
    source.getPixel(&before,atX:x,y:y)
    let qx=abs(Double(x)+0.5-cx)-(hx-radius)
    let qy=abs(Double(y)+0.5-cy)-(hy-radius)
    let distance=hypot(max(qx,0),max(qy,0))+min(max(qx,qy),0)-radius
    let alpha=UInt((max(0,min(1,0.5-distance))*255).rounded())
    after=[before[0],before[1],before[2],alpha]
    result.setPixel(&after,atX:x,y:y)
    if alpha==0 {clearCount+=1} else if alpha==255 {opaqueCount+=1} else {edgeCount+=1}
}}
try result.representation(using:.png,properties:[:])!.write(to:output)
guard let saved=NSBitmapImageRep(data:try Data(contentsOf:output)),saved.hasAlpha else {fatalError("Missing alpha")}
var actual=[UInt](repeating:0,count:4)
for y in 0..<side {for x in 0..<side {
    source.getPixel(&before,atX:x,y:y);saved.getPixel(&actual,atX:x,y:y)
    precondition(Array(actual.prefix(3)) == before,"Original RGB changed")
}}
for (x,y) in [(0,0),(side-1,0),(0,side-1),(side-1,side-1)] {
    saved.getPixel(&actual,atX:x,y:y);precondition(actual[3]==0)
}
print("PASS: all 1,572,516 original RGB pixels unchanged; true transparent corners")
print("opaque=\(opaqueCount), antialiased=\(edgeCount), transparent=\(clearCount)")

// Inspection sheet; these composites are not shipped as icon assets.
let sheet=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1080,pixelsHigh:520,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:sheet)
let icon=NSImage(contentsOf:output)!
for (i,color) in [NSColor.white,NSColor(calibratedWhite:0.12,alpha:1),NSColor(calibratedRed:0.48,green:0.53,blue:0.31,alpha:1)].enumerated() {
    let base=CGFloat(i*360);color.setFill();NSRect(x:base,y:0,width:360,height:520).fill()
    icon.draw(in:NSRect(x:base+20,y:165,width:320,height:320),from:.zero,operation:.sourceOver,fraction:1)
    for (j,size) in [24,48,96].enumerated() {icon.draw(in:NSRect(x:base+20+CGFloat(j*100),y:40,width:CGFloat(size),height:CGFloat(size)),from:.zero,operation:.sourceOver,fraction:1)}
}
NSGraphicsContext.restoreGraphicsState()
try sheet.representation(using:.png,properties:[:])!.write(to:output.deletingLastPathComponent().appendingPathComponent("edge-review.png"))
