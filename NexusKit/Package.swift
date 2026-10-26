// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NexusKit",
    platforms: [
        .macOS("27.0"),
    ],
    products: [
        .library(name: "NexusCore", targets: ["NexusCore"]),
    ],
    targets: [
        .target(name: "NexusCore"),
        .testTarget(name: "NexusCoreTests", dependencies: ["NexusCore"]),
    ]
)
