// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "BrowserBridge", platforms: [.macOS(.v13)], products: [
    .library(name: "BrowserBridge", targets: ["BrowserBridge"]),
    .library(name: "BrowserDiagnostic", targets: ["BrowserDiagnostic"]),
    .executable(name: "BrowserBridgeDiagnosticHost", targets: ["BrowserBridgeDiagnosticHost"]),
    .executable(name: "BrowserBridgeHost", targets: ["BrowserBridgeHost"]),
    .executable(name: "BrowserBridgeSetup", targets: ["BrowserBridgeSetup"])
], targets: [
    .target(name: "BrowserBridge"),
    .target(name: "BrowserDiagnostic"),
    .executableTarget(name: "BrowserBridgeDiagnosticHost", dependencies: ["BrowserDiagnostic"]),
    .executableTarget(name: "DiagnosticChecks", dependencies: ["BrowserDiagnostic","BrowserBridge"], path:"DiagnosticChecks"),
    .executableTarget(name: "BrowserBridgeHost", dependencies: ["BrowserBridge"]),
    .executableTarget(name: "BrowserBridgeSetup", dependencies: ["BrowserBridge"], path:"Sources/BrowserBridgeSetup"),
    .executableTarget(name: "BrowserBridgeChecks", dependencies: ["BrowserBridge"], path: "Checks"),
    .executableTarget(name: "BrowserMetadataChecks", dependencies: ["BrowserBridge"], path: "MetadataChecks")
])
