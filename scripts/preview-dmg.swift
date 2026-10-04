import AppKit
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let background=NSImage(contentsOf:root.appendingPathComponent(".background.tiff"))!
print("TIFF representations:",background.representations.map { "\($0.pixelsWide)x\($0.pixelsHigh) at \($0.size)" })
for scale in [1,2] {
    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:640*scale,pixelsHigh:400*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
    NSGraphicsContext.current!.cgContext.scaleBy(x:CGFloat(scale),y:CGFloat(scale))
    background.draw(in:NSRect(x:0,y:0,width:640,height:400))
    let icon=NSImage(contentsOf:root.appendingPathComponent("DayDream.app/Contents/Resources/Daydream.icns"))!
    for (label,x,image) in [("DayDream",170.0,icon),("Applications",470.0,NSWorkspace.shared.icon(forFile:"/Applications"))] {
        image.draw(in:NSRect(x:x-64,y:166,width:128,height:128))
        let text=label as NSString
        let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.black]
        let size=text.size(withAttributes:attributes)
        text.draw(at:NSPoint(x:x-size.width/2,y:142),withAttributes:attributes)
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[2]+"-\(scale)x.png"))
}
print("Generated layout preview only; not a Finder screenshot")
