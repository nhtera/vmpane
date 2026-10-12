// swift-tools-version:6.1
// The integration tests' stand-in for the app's policy controls (Sources/main.swift). Never shipped.

import PackageDescription

let package = Package(
    name: "VMPaneItestPolicy",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../Packages/VMPaneKit")],
    targets: [
        .executableTarget(
            name: "vmpane-itest-policy", dependencies: [.product(name: "VMPaneCore", package: "VMPaneKit")], path: "Sources")
    ]
)
