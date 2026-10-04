import AppKit
import Carbon

// Code-drawn packaging background, not an app icon or activity record.
// Usage: dmg-background.swift MOUNT ALIAS_OUT [LABEL]. LABEL is the line under the drag hint,
// e.g. "DayDream 0.1.0 Beta" (developer-id-release.py dmg passes the app's version).
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let label=CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""
let file=root.appendingPathComponent(".background.tiff")
let image=NSImage(size:NSSize(width:640,height:400))
for scale in [1,2] {
    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:640*scale,pixelsHigh:400*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    rep.size=NSSize(width:640,height:400)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
    // rep.size supplies the logical-to-pixel transform, including 2×.
    NSColor(calibratedWhite:0.97,alpha:1).setFill(); NSRect(x:0,y:0,width:640,height:400).fill()
    NSColor(calibratedWhite:0.48,alpha:1).setStroke()
    let arrow=NSBezierPath(); arrow.lineWidth=5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to:NSPoint(x:294,y:230)); arrow.line(to:NSPoint(x:346,y:230))
    arrow.move(to:NSPoint(x:332,y:245)); arrow.line(to:NSPoint(x:347,y:230)); arrow.line(to:NSPoint(x:332,y:215)); arrow.stroke()
    let text="Drag DayDream to Applications to install." as NSString
    let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:15),.foregroundColor:NSColor(calibratedWhite:0.34,alpha:1)]
    let size=text.size(withAttributes:attributes)
    text.draw(at:NSPoint(x:(640-size.width)/2,y:88),withAttributes:attributes)
    if !label.isEmpty {
        let line=label as NSString
        let small:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:13),.foregroundColor:NSColor(calibratedWhite:0.45,alpha:1)]
        let lineSize=line.size(withAttributes:small)
        line.draw(at:NSPoint(x:(640-lineSize.width)/2,y:62),withAttributes:small)
    }
    NSGraphicsContext.restoreGraphicsState(); image.addRepresentation(rep)
}
try image.tiffRepresentation!.write(to:file)
// Native file bookmark binds to the background on this mounted image.
let data=try file.bookmarkData(options:.suitableForBookmarkFile,includingResourceValuesForKeys:nil,relativeTo:root)
try data.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
print("Background: 640×400 logical points, 1× and 2× representations")
