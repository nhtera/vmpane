// swift-tools-version:6.1
// VMPaneKit: all VMPane logic that is under test. Xcode targets keep only entry points, windows and views.

import PackageDescription

let package = Package(
    name: "VMPaneKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VMPaneCore", targets: ["VMPaneCore"]),
        .library(name: "VMPaneControl", targets: ["VMPaneControl"]),
        .library(name: "VMPaneVZ", targets: ["VMPaneVZ"]),
        .library(name: "VMPaneQEMU", targets: ["VMPaneQEMU"]),
        .library(name: "VMPaneHost", targets: ["VMPaneHost"]),
        .library(name: "VMPaneMCP", targets: ["VMPaneMCP"]),
        .library(name: "VMPaneUI", targets: ["VMPaneUI"]),
    ],
    targets: [
        // Bundle, config, storage, snapshots, backend protocol, policy, audit, launch coordination.
        .target(name: "VMPaneCore"),
        // JSON-RPC over Unix sockets, control methods, peer identity, CLI client logic, agent frame codec.
        .target(name: "VMPaneControl", dependencies: ["VMPaneCore"]),
        // Virtualization.framework backend.
        .target(name: "VMPaneVZ", dependencies: ["VMPaneCore"]),
        // QEMU child-process backend.
        .target(name: "VMPaneQEMU", dependencies: ["VMPaneCore"]),
        // Helper-process logic: agent connection, install, networking, import, integrations.
        .target(name: "VMPaneHost", dependencies: ["VMPaneCore", "VMPaneControl", "VMPaneVZ", "VMPaneQEMU"]),
        // MCP server: tool registry, stdio transport, client config.
        .target(name: "VMPaneMCP", dependencies: ["VMPaneCore", "VMPaneControl"]),
        // Shared SwiftUI views and app/helper view models.
        .target(name: "VMPaneUI", dependencies: ["VMPaneCore", "VMPaneControl", "VMPaneHost"]),

        .testTarget(name: "VMPaneCoreTests", dependencies: ["VMPaneCore"]),
        .testTarget(name: "VMPaneControlTests", dependencies: ["VMPaneControl"]),
        .testTarget(name: "VMPaneVZTests", dependencies: ["VMPaneVZ"]),
        .testTarget(name: "VMPaneQEMUTests", dependencies: ["VMPaneQEMU"]),
        .testTarget(name: "VMPaneHostTests", dependencies: ["VMPaneHost"]),
        .testTarget(name: "VMPaneMCPTests", dependencies: ["VMPaneMCP"]),
        .testTarget(name: "VMPaneUIModelTests", dependencies: ["VMPaneUI"]),
    ],
    swiftLanguageModes: [.v6]
)
