// swift-tools-version:6.1
// VMPaneSpice: the SPICE display client of Windows VMs, used by the helper app only. CocoaSpice is vendored
// (scripts/vendor-cocoaspice.sh) and compiles against SpiceSDK/ (headers of the libraries we ship, generated
// by qemu/scripts/spice-sdk.sh). Nothing here links them: the helper weak-links SpiceSDK/stubs and embeds the
// libraries from the QEMU bundle, so it still builds and runs without them (VZ VMs).

import PackageDescription

let sdk = "../../SpiceSDK"

let package = Package(
    name: "VMPaneSpice",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VMPaneSpice", targets: ["VMPaneSpice"])
    ],
    dependencies: [.package(path: "../VMPaneKit")],
    targets: [
        // Vendored from utmapp/CocoaSpice (Apache-2.0), patched (patches/).
        .target(name: "CocoaSpiceRenderer", exclude: ["CSShaders.metal"]),
        .target(
            name: "CocoaSpice", dependencies: ["CocoaSpiceRenderer"], exclude: ["LICENSE"],
            cSettings: [
                .headerSearchPath("\(sdk)/include"), .headerSearchPath("\(sdk)/include/glib-2.0"),
                .headerSearchPath("\(sdk)/lib/glib-2.0/include"), .headerSearchPath("\(sdk)/include/spice-1"),
                .headerSearchPath("\(sdk)/include/spice-client-glib-2.0"),
            ]),
        // The helper's SPICE display: session, view, keyboard/mouse, clipboard.
        .target(
            name: "VMPaneSpice",
            dependencies: [
                "CocoaSpice", "CocoaSpiceRenderer", .product(name: "VMPaneCore", package: "VMPaneKit"),
                .product(name: "VMPaneQEMU", package: "VMPaneKit"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
