import AppKit

/// Puts a rendered view on the README's backdrop: a soft neutral background, a rounded window (or panel) with a
/// hairline edge and a soft shadow, and for windows the three window buttons. Drawn, never captured.
enum Compose {
    enum Frame { case window, panel }

    static func make(_ content: NSBitmapImageRep, frame: Frame, dark: Bool, margin: CGFloat = 44, radius: CGFloat = 12) -> NSBitmapImageRep {
        let w = content.size.width, h = content.size.height
        let canvas = NSSize(width: w + margin * 2, height: h + margin * 2 + 6)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        let gc = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = gc
        let cg = gc.cgContext
        // Backdrop: a quiet vertical gradient, opaque, so the picture looks the same on any page.
        let top = dark ? NSColor(srgbRed: 0.145, green: 0.153, blue: 0.173, alpha: 1) : NSColor(srgbRed: 0.949, green: 0.953, blue: 0.965, alpha: 1)
        let bottom = dark ? NSColor(srgbRed: 0.106, green: 0.114, blue: 0.129, alpha: 1) : NSColor(srgbRed: 0.906, green: 0.914, blue: 0.929, alpha: 1)
        NSGradient(starting: top, ending: bottom)!.draw(in: NSRect(origin: .zero, size: canvas), angle: -90)

        let box = NSRect(x: margin, y: margin + 6, width: w, height: h)
        let shape = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
        // Soft shadow: a wide faint one and a tight one.
        for (blur, y, alpha) in [(34.0, -14.0, dark ? 0.55 : 0.16), (6.0, -2.0, dark ? 0.35 : 0.08)] {
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: y), blur: blur, color: NSColor.black.withAlphaComponent(alpha).cgColor)
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).setFill()
            shape.fill()
            cg.restoreGState()
        }
        cg.saveGState()
        shape.addClip()
        content.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
        cg.restoreGState()
        if frame == .window {
            // The window buttons, where macOS draws them (the toolbar leaves room for them).
            let colors = [NSColor(srgbRed: 1, green: 0.373, blue: 0.341, alpha: 1), NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1),
                          NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1)]
            for (i, c) in colors.enumerated() {
                let r = NSRect(x: box.minX + 20 + CGFloat(i) * 20, y: box.maxY - 29, width: 12, height: 12)
                c.setFill(); NSBezierPath(ovalIn: r).fill()
                NSColor.black.withAlphaComponent(0.12).setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.25, dy: 0.25)); ring.lineWidth = 0.5; ring.stroke()
            }
        }
        // Hairline edge.
        (dark ? NSColor.white.withAlphaComponent(0.13) : NSColor.black.withAlphaComponent(0.10)).setStroke()
        let edge = NSBezierPath(roundedRect: box.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius); edge.lineWidth = 0.5; edge.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Writes an opaque 8-bit RGB PNG (no alpha channel: the backdrop is opaque). Unused by default: `Palette` is smaller.
    static func write(_ rep: NSBitmapImageRep, to url: URL) throws {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: w, height: h))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "png", code: 1) }
    }
}

/// A 256-color palette PNG (median cut over a 5-bit-per-channel histogram, nearest color, no dithering): the README's
/// pictures are flat UI, so this keeps them sharp at a fraction of the size.
enum Palette {
    static func write(_ rep: NSBitmapImageRep, to url: URL, colors: Int = 256) throws {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Histogram over 6 bits per channel (262,144 cells).
        let bits = 6, levels = 1 << bits, shift = 8 - bits
        var hist = [Int](repeating: 0, count: levels * levels * levels)
        func cell(_ i: Int) -> Int { (Int(px[i]) >> shift) << (2 * bits) | (Int(px[i + 1]) >> shift) << bits | (Int(px[i + 2]) >> shift) }
        for i in stride(from: 0, to: px.count, by: 4) { hist[cell(i)] += 1 }
        struct Entry { var c: Int; var n: Int; var r: Int { c >> (12) & 63 }; var g: Int { c >> 6 & 63 }; var b: Int { c & 63 } }
        var entries = [Entry]()
        for (c, n) in hist.enumerated() where n > 0 { entries.append(Entry(c: c, n: n)) }
        var boxes: [[Entry]] = [entries]
        while boxes.count < colors {
            // Split the box with the most pixels times its widest range.
            var best = -1, bestScore = 0.0, bestAxis = 0
            for (i, box) in boxes.enumerated() where box.count > 1 {
                let rs = box.map(\.r), gs = box.map(\.g), bs = box.map(\.b)
                let ranges = [rs.max()! - rs.min()!, gs.max()! - gs.min()!, bs.max()! - bs.min()!]
                let axis = ranges.firstIndex(of: ranges.max()!)!
                let total = box.reduce(0) { $0 + $1.n }
                let score = Double(ranges[axis]) * sqrt(Double(total))
                if score > bestScore { bestScore = score; best = i; bestAxis = axis }
            }
            if best < 0 { break }
            var box = boxes.remove(at: best)
            box.sort { [$0.r, $0.g, $0.b][bestAxis] < [$1.r, $1.g, $1.b][bestAxis] }
            let total = box.reduce(0) { $0 + $1.n }
            var acc = 0, cut = 1
            for (i, e) in box.enumerated() { acc += e.n; if acc * 2 >= total { cut = max(1, min(box.count - 1, i + 1)); break } }
            boxes.append(Array(box[..<cut])); boxes.append(Array(box[cut...]))
        }
        // Palette: each box's pixel-weighted mean, from the full 8-bit values.
        var sums = [[Double]](repeating: [0, 0, 0, 0], count: boxes.count)
        var boxOf = [Int32](repeating: -1, count: hist.count)
        for (i, box) in boxes.enumerated() { for e in box { boxOf[e.c] = Int32(i) } }
        for i in stride(from: 0, to: px.count, by: 4) {
            let b = Int(boxOf[cell(i)])
            sums[b][0] += Double(px[i]); sums[b][1] += Double(px[i + 1]); sums[b][2] += Double(px[i + 2]); sums[b][3] += 1
        }
        var table = [UInt8]()
        for s in sums { for k in 0..<3 { table.append(UInt8(max(0, min(255, (s[k] / max(1, s[3])).rounded())))) } }
        // Nearest palette color per histogram cell (cached), then the index image.
        var nearest = [Int16](repeating: -1, count: hist.count)
        var out = [UInt8](repeating: 0, count: w * h)
        for i in stride(from: 0, to: px.count, by: 4) {
            let c = cell(i)
            if nearest[c] < 0 {
                let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                var bi = 0, bd = Int.max
                for p in 0..<boxes.count {
                    let dr = r - Int(table[p * 3]), dg = g - Int(table[p * 3 + 1]), db = b - Int(table[p * 3 + 2])
                    let d = 3 * dr * dr + 4 * dg * dg + 2 * db * db
                    if d < bd { bd = d; bi = p }
                }
                nearest[c] = Int16(bi)
            }
            out[i / 4] = UInt8(nearest[c])
        }
        let indexed = CGColorSpace(indexedBaseSpace: space, last: boxes.count - 1, colorTable: table)!
        let provider = CGDataProvider(data: Data(out) as CFData)!
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: indexed,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "png", code: 2) }
    }
}
