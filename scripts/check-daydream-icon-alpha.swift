import AppKit
import Foundation
let root=URL(fileURLWithPath:CommandLine.arguments[1])
for size in [16,32,128,256,512] {for scale in [1,2] {
 let side=size*scale,suffix=scale==2 ? "@2x":""
 let file=root.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
 let rep=NSBitmapImageRep(data:try Data(contentsOf:file))!
 precondition(rep.pixelsWide==side && rep.pixelsHigh==side && rep.hasAlpha)
 for (x,y) in [(0,0),(side-1,0),(0,side-1),(side-1,side-1)] {precondition(rep.colorAt(x:x,y:y)!.alphaComponent==0)}
 precondition(rep.colorAt(x:side/2,y:side/2)!.alphaComponent==1)
 print("PASS \(file.lastPathComponent): exact dimensions, transparent corners, opaque interior")
}}
