import AppKit
import Foundation

// perm-1004 (owner 10/3: "about 4 DayDreams everywhere"): the test copies' icon. The public icon, unchanged, with a bold
// orange label along its bottom ("TEST" for the Live Test copy, "QA" for the QA copy), so System Settings' privacy lists,
// the Dock and Finder tell the copies apart at a glance. Only test and QA stages use it; the public app keeps
// packaging/Daydream.icns.
//
// Usage: swift scripts/badge-icon.swift <packaging/Daydream.iconset> <TEXT> <out.iconset>
//        then: iconutil -c icns <out.iconset> -o packaging/Daydream-<TEXT>.icns
guard CommandLine.arguments.count == 4 else { fatalError("Pass the source iconset, the badge text and the output iconset") }
let input = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let text = CommandLine.arguments[2]
let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
guard !text.isEmpty, text.count <= 4, text == text.uppercased() else { fatalError("Badge text: 1-4 capital letters") }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// The badge's orange (bold, readable on the icon's light and dark parts) and its white text.
let orange = NSColor(srgbRed: 1.0, green: 0.45, blue: 0.0, alpha: 1)

func badged(_ source: NSImage, pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let side = CGFloat(pixels)
    NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: side, height: side).fill()
    source.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
    // A pill across the lower part of the artwork: wide enough for the word, a third of the icon tall at small sizes.
    let small = pixels <= 32
    let height = side * (small ? 0.40 : 0.27)
    let font = NSFont.systemFont(ofSize: height * 0.72, weight: .black)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .kern: height * 0.02]
    let word = NSAttributedString(string: text, attributes: attributes)
    let wordSize = word.size()
    let width = min(side * 0.94, max(wordSize.width + height * 0.7, side * (small ? 0.8 : 0.5)))
    let pill = NSRect(x: (side - width) / 2, y: side * (small ? 0.02 : 0.08), width: width, height: height)
    let path = NSBezierPath(roundedRect: pill, xRadius: height * 0.3, yRadius: height * 0.3)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = side * 0.015; shadow.shadowOffset = NSSize(width: 0, height: -side * 0.006); shadow.set()
    orange.setFill(); path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.9).setStroke(); path.lineWidth = max(1, side * 0.012); path.stroke()
    word.draw(at: NSPoint(x: pill.midX - wordSize.width / 2, y: pill.midY - wordSize.height / 2 + font.descender * -0.15))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        guard let source = NSImage(contentsOf: input.appendingPathComponent(name)) else { fatalError("Missing \(name)") }
        try badged(source, pixels: size * scale).representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent(name))
    }
}
print("Badged the public icon with \(text). The public icon itself is unchanged.")
