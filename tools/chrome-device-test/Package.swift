// swift-tools-version: 5.10
// Standalone, read-only Chrome device-test harness (plan Work table row 0).
// It is NOT part of the DayDream app: the root Package.swift never references
// this folder, so the public app binary is unchanged by anything here.
// No remote dependencies: builds offline.
import PackageDescription

let package = Package(
    name: "ChromeDeviceTest",
    platforms: [.macOS("15.0")],  // PrivacyPolicy (a dependency) needs macOS 15 since d6ce29c
    products: [
        .executable(name: "chrome-device-test", targets: ["ChromeDeviceTest"]),
        .executable(name: "chrome-device-test-selftest", targets: ["ChromeProbeSelfTest"]),
        .executable(name: "chrome-device-test-serve", targets: ["ChromeDeviceTestServe"]),
    ],
    dependencies: [.package(path: "../../PrivacyPolicy")],
    targets: [
        // Pure logic: join protocol, read audit, grading. Foundation only, no
        // Apple Events, no Accessibility, no AppKit. Shared by both executables.
        .target(name: "ChromeProbeCore",
                dependencies: [.product(name: "PrivacyPolicy", package: "PrivacyPolicy")]),
        // The only target that talks to Chrome (Apple Events + Accessibility).
        .executableTarget(name: "ChromeDeviceTest", dependencies: ["ChromeProbeCore"]),
        // Synthetic tests against a fake Chrome. Links no live code.
        .executableTarget(name: "ChromeProbeSelfTest", dependencies: ["ChromeProbeCore"]),
        // Loopback-only server for testpage/ (the MacBook kit has no Python).
        // Talks to no app: no Apple Events, no Accessibility. Never depends
        // on ChromeDeviceTest.
        .executableTarget(name: "ChromeDeviceTestServe", dependencies: ["ChromeProbeCore"]),
    ]
)
