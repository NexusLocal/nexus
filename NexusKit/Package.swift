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
        .library(name: "NexusDNS", targets: ["NexusDNS"]),
        .library(name: "NexusTLS", targets: ["NexusTLS"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-certificates", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-asn1", from: "1.7.0"),
    ],
    targets: [
        .target(name: "NexusCore"),
        .target(name: "NexusDNS", dependencies: ["NexusCore"]),
        .target(name: "NexusConfig", dependencies: ["NexusCore"]),
        .target(name: "NexusTLS", dependencies: [
            "NexusCore",
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "SwiftASN1", package: "swift-asn1"),
        ]),
        .target(name: "NexusRuntime", dependencies: ["NexusCore", "NexusSupervisor"]),
        .target(name: "NexusSupervisor", dependencies: ["NexusCore"]),
        .target(name: "NexusIPC", dependencies: ["NexusCore", "NexusRuntime", "NexusSupervisor"]),
        .target(name: "NexusLaravel", dependencies: ["NexusCore", "NexusSupervisor"]),
        .target(name: "NexusWorkspaces", dependencies: ["NexusCore", "NexusSupervisor"]),
        .target(name: "NexusEngine", dependencies: ["NexusCore", "NexusRuntime", "NexusSupervisor", "NexusIPC", "NexusDNS", "NexusTLS", "NexusConfig", "NexusLaravel", "NexusWorkspaces"]),
        .target(name: "NexusCommands", dependencies: [
            "NexusCore",
            "NexusIPC",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "NexusCoreTests", dependencies: ["NexusCore"]),
        .testTarget(name: "NexusRuntimeTests", dependencies: ["NexusRuntime"]),
        .testTarget(name: "NexusSupervisorTests", dependencies: ["NexusSupervisor"]),
        .testTarget(name: "NexusEngineTests", dependencies: ["NexusEngine", "NexusDNS", "NexusTLS", "NexusTestSupport"]),
        .testTarget(name: "NexusDNSTests", dependencies: ["NexusDNS", "NexusTestSupport"]),
        .testTarget(name: "NexusConfigTests", dependencies: ["NexusConfig"]),
        .testTarget(name: "NexusLaravelTests", dependencies: ["NexusLaravel", "NexusCore"]),
        .testTarget(name: "NexusWorkspacesTests", dependencies: ["NexusWorkspaces", "NexusCore"]),
        .testTarget(name: "NexusIPCTests", dependencies: ["NexusIPC", "NexusSupervisor"]),
        .testTarget(name: "NexusCommandsTests", dependencies: [
            "NexusCommands",
            "NexusCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "NexusTLSTests", dependencies: [
            "NexusTLS",
            "NexusTestSupport",
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .target(name: "NexusTestSupport", dependencies: ["NexusTLS", "NexusIPC", "NexusDNS"], path: "Tests/NexusTestSupport"),
    ]
)
