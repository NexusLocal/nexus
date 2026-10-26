// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NexusKit",
    platforms: [
        .macOS("27.0"),
    ],
    products: [
        .library(name: "NexusCore", targets: ["NexusCore"]),
        .library(name: "NexusRuntime", targets: ["NexusRuntime"]),
        .library(name: "NexusSupervisor", targets: ["NexusSupervisor"]),
        .library(name: "NexusIPC", targets: ["NexusIPC"]),
        .library(name: "NexusEngine", targets: ["NexusEngine"]),
        .library(name: "NexusCommands", targets: ["NexusCommands"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "NexusCore"),
        .target(name: "NexusRuntime", dependencies: ["NexusCore"]),
        .target(name: "NexusSupervisor", dependencies: ["NexusCore"]),
        .target(name: "NexusIPC", dependencies: ["NexusCore", "NexusRuntime", "NexusSupervisor"]),
        .target(name: "NexusEngine", dependencies: ["NexusCore", "NexusRuntime", "NexusSupervisor", "NexusIPC"]),
        .target(name: "NexusCommands", dependencies: [
            "NexusCore",
            "NexusIPC",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "NexusCoreTests", dependencies: ["NexusCore"]),
        .testTarget(name: "NexusRuntimeTests", dependencies: ["NexusRuntime"]),
        .testTarget(name: "NexusSupervisorTests", dependencies: ["NexusSupervisor"]),
        .testTarget(name: "NexusEngineTests", dependencies: ["NexusEngine"]),
    ]
)
