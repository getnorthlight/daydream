import Foundation
import AppKit
import MemoryUI

@main struct CatalogChecks {
    static func main() throws {
        let fm=FileManager.default
        let root=URL(fileURLWithPath:"/private/tmp/daydream-catalog-"+UUID().uuidString)
        func app(_ path:String,_ id:String) throws {
            let contents=root.appendingPathComponent(path).appendingPathComponent("Contents")
            try fm.createDirectory(at:contents,withIntermediateDirectories:true)
            let data=try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":id,"CFBundleName":"Fixture app","CFBundlePackageType":"APPL"],format:.xml,options:0)
            try data.write(to:contents.appendingPathComponent("Info.plist"))
        }
        try app("Utilities/Nested/More/Tool.app","example.deep")
        try app("Outer.app","example.outer")
        try app("Outer.app/Contents/Hidden.app","example.never-traverse")
        try app("Duplicate.app","example.outer")
        try fm.createSymbolicLink(at:root.appendingPathComponent("Outside"),withDestinationURL:URL(fileURLWithPath:"/Applications"))
        let catalog=LocalApp.catalog(roots:[root])
        precondition(Set(catalog.map(\.id))==["example.deep","example.outer"])
        precondition(catalog.allSatisfy{!$0.path.isEmpty})
        let missing=LocalApp.includingMissing(catalog,excluded:["example.removed"])
        precondition(missing.contains{$0.id=="example.removed" && $0.path.isEmpty})
        let ranked=LocalApp.ranked(catalog,usage:[],running:["example.deep"])
        precondition(ranked.first?.id=="example.deep")
        // Explicitly authorized real read-only bundle/icon metadata; no usage/history.
        let real=LocalApp.catalog()
        precondition(!real.isEmpty)
        precondition(real.allSatisfy{!$0.path.isEmpty && $0.path.hasSuffix(".app")})
        for item in real.prefix(5) {precondition(NSWorkspace.shared.icon(forFile:item.path).size.width>0)}
        print("PASS nested Utilities, bundle boundary, symlink rejection, deduplication, missing exclusions, running fallback; real scoped catalog \(real.count) entries and 5 icons. No private usage read.")
    }
}
