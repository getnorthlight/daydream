// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacMem",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "MacMem", targets: ["MacMemApp"]),
        .executable(name: "mac-mem", targets: ["MacMemCLI"]),
        .executable(name: "mac-mem-backup", targets: ["MacMemBackup"]),
    ],
    dependencies: [.package(path:"WriterBackend"),.package(path:"PrivacyPolicy"),.package(path:"BrowserBridge")],
    targets: [
        // Exact official binary release and SHA-256 in packaging/sparkle.json.
        // Run scripts/bootstrap-sparkle.py before the first build.
        .binaryTarget(name:"Sparkle",path:"Vendor/Sparkle-2.9.6/Sparkle.xcframework"),
        .systemLibrary(name: "CSQLite"),
        .target(name: "HistoryCore"),
        .target(name: "MemoryCore", dependencies: ["HistoryCore", "CSQLite", .product(name:"PrivacyPolicy",package:"PrivacyPolicy")]),
        .target(name: "MemoryUI", dependencies: ["MemoryCore"], resources: [.copy("Resources/SiteIcons")]),
        .target(name:"BackupRestore",dependencies:["MemoryCore"],path:"BackupRestore/Native"),
        .executableTarget(name:"MacMemBackup",dependencies:["MemoryCore","BackupRestore"],path:"BackupRestore/Worker"),
        .target(name:"CoreIntegration",dependencies:["MemoryCore",.product(name:"WriterBackend",package:"WriterBackend"),.product(name:"PrivacyPolicy",package:"PrivacyPolicy"),.product(name:"BrowserBridge",package:"BrowserBridge")],path:"adapters",sources:["CoreWriterBinding.swift","CoreCaptureBinding.swift","LevelWriterBinding.swift"]),
        .executableTarget(name:"ProductionBindingChecks",dependencies:["MemoryCore"],path:"scripts",sources:["core-production-checks.swift"]),
        .executableTarget(name: "MacMemApp", dependencies: ["HistoryCore", "MemoryCore", "MemoryUI", "BackupRestore", "CoreIntegration", "Sparkle", .product(name:"WriterBackend",package:"WriterBackend")], linkerSettings:[.unsafeFlags(["-Xlinker","-rpath","-Xlinker","@executable_path/../Frameworks"])]),
        .executableTarget(name: "MacMemUIRender", dependencies: ["MemoryUI", "MemoryCore"], path: "UIRender"),
        .executableTarget(name: "MacMemCLI", dependencies: ["MemoryCore"]),
        .executableTarget(name: "MacMemChecks", dependencies: ["MemoryCore", "HistoryCore", .product(name:"PrivacyPolicy",package:"PrivacyPolicy")], path: "Checks"),
        // Upstream Swift Testing tests remain intact on disk. The installed
        // toolchain cannot import Testing; XCTest ports run below.
        .testTarget(name: "MemoryCoreTests", dependencies: ["MemoryCore", "HistoryCore"]),
    ]
)
